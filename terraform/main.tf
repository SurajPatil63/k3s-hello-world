terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# --- Upload your local public key to AWS, no manual key pair creation needed ---
resource "aws_key_pair" "k3s_key" {
  key_name   = "k3s-challenge-key"
  public_key = file(var.public_key_path)
}

# --- Security group: SSH + API restricted to your IP, NodePort open to the world ---
resource "aws_security_group" "k3s_sg" {
  name        = "k3s-challenge-sg"
  description = "Allow SSH, k8s API, and application traffic"

  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  ingress {
    description = "Kubernetes API from my IP"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  ingress {
    description = "Nginx Web App - open to everyone"
    from_port   = 30080
    to_port     = 30080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- Elastic IP allocated FIRST, so we know the public IP before boot ---
# This lets us bake it into k3s's --tls-san flag so kubectl works from
# outside the box (your laptop, GitHub Actions) without cert errors.
resource "aws_eip" "k3s_eip" {
  domain = "vpc"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "k3s_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.k3s_key.key_name
  vpc_security_group_ids = [aws_security_group.k3s_sg.id]

  root_block_device {
    volume_size = 16
    volume_type = "gp3"
  }

  user_data = <<-EOF
              #!/bin/bash
              set -e
              apt-get update -y
              apt-get install -y curl open-iscsi

              # 1GB RAM is tight for k3s -- add swap so it doesn't OOM
              fallocate -l 1G /swapfile
              chmod 600 /swapfile
              mkswap /swapfile
              swapon /swapfile
              echo '/swapfile swap swap defaults 0 0' >> /etc/fstab

              curl -sfL https://get.k3s.io | \
                INSTALL_K3S_CHANNEL=stable \
                INSTALL_K3S_EXEC="server --write-kubeconfig-mode 0644 --tls-san ${aws_eip.k3s_eip.public_ip}" \
                sh -

              # Wait for node to actually be Ready before we consider boot done
              for i in $(seq 1 30); do
                if k3s kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -q Ready; then
                  break
                fi
                sleep 5
              done
              EOF

  tags = {
    Name = "k3s-single-node-server"
  }
}

# --- Attach the pre-allocated Elastic IP to the instance ---
resource "aws_eip_association" "k3s_eip_assoc" {
  instance_id   = aws_instance.k3s_server.id
  allocation_id = aws_eip.k3s_eip.id
}

# --- Wait for SSH to actually be reachable, then pull the kubeconfig down ---
resource "null_resource" "get_kubeconfig" {
  depends_on = [aws_eip_association.k3s_eip_assoc]

  connection {
    type        = "ssh"
    host        = aws_eip.k3s_eip.public_ip
    user        = "ubuntu"
    private_key = file(var.private_key_path)
    timeout     = "5m"
  }

  # Blocks here until SSH is actually up -- replaces the fragile `sleep 60`
  provisioner "remote-exec" {
    inline = [
      "echo 'SSH is ready, waiting for k3s to finish installing...'",
      "timeout 180 bash -c 'until sudo test -f /etc/rancher/k3s/k3s.yaml; do sleep 5; done'",
      "sudo chmod 644 /etc/rancher/k3s/k3s.yaml"
    ]
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      scp -o StrictHostKeyChecking=no -i ${var.private_key_path} ubuntu@${aws_eip.k3s_eip.public_ip}:/etc/rancher/k3s/k3s.yaml ./kubeconfig
      sed -i.bak "s/127.0.0.1/${aws_eip.k3s_eip.public_ip}/g" ./kubeconfig
      rm -f ./kubeconfig.bak
    EOT
  }
}

output "ec2_public_ip" {
  value       = aws_eip.k3s_eip.public_ip
  description = "The public IP of your EC2 instance -- hit this in the browser on port 30080"
}

output "ssh_command" {
  value       = "ssh -i ${var.private_key_path} ubuntu@${aws_eip.k3s_eip.public_ip}"
  description = "SSH into the node"
}

output "app_url" {
  value       = "http://${aws_eip.k3s_eip.public_ip}:30080"
  description = "URL for the Hello World app once deployed"
}
