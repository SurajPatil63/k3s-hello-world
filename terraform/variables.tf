variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "Free-tier eligible EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "public_key_path" {
  description = "Path to your local SSH public key. Terraform does NOT expand '~' -- pass a full path, e.g. on Windows/Git Bash: /c/Users/<you>/.ssh/k3s-key.pub"
  type        = string
}

variable "private_key_path" {
  description = "Path to your local SSH private key. Full path required, e.g. /c/Users/<you>/.ssh/k3s-key"
  type        = string
}

variable "my_ip" {
  description = "Your public IP in CIDR form, e.g. 49.207.12.34/32"
  type        = string
}
