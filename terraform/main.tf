# 1. AWS Provider and Region Definition
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# 2. Reference Existing Default Network Infrastructure
data "aws_vpc" "default" {
  default = true
}

# Dynamically look up the most recent stable Ubuntu 22.04 AMI ID
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's official AWS Account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# 3. Secure, Minimum-Viable Security Group
resource "aws_security_group" "chat_sg" {
  name        = "chat-app-security-group"
  description = "Minimum viable ports for secure administration and application delivery"
  vpc_id      = data.aws_vpc.default.id

  # Port 22: Administrative SSH access for instance management and assignment evaluation.
  # Open to 0.0.0.0/0 because the self-hosted runner executes locally on the instance
  # and does not require inbound SSH. Restrict to known IP ranges in production.
  ingress {
    description = "SSH administrative entrypoint"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Port 80: Public HTTP entrypoint — traffic is received by the NGINX reverse proxy
  ingress {
    description = "Public Nginx HTTP entrypoint"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Unrestricted outbound so the instance can reach apt, Docker Hub, and GitHub
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 4. Register the SSH public key for EC2 access
resource "aws_key_pair" "deployer_key" {
  key_name   = "chat-assignment-key"
  public_key = file("~/Downloads/chat-assignment-key.pub")
}

# 5. EC2 instance — linked to the AMI lookup, key pair, and security group above
resource "aws_instance" "chat_server" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"

  key_name               = aws_key_pair.deployer_key.key_name
  vpc_security_group_ids = [aws_security_group.chat_sg.id]

  root_block_device {
    volume_size           = 15
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # Bootstrap script: installs Docker on first boot so the instance is
  # deployment-ready without manual preparation after provisioning
  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y docker.io docker-compose
              systemctl start docker
              systemctl enable docker
              usermod -aG docker ubuntu
              EOF

  tags = {
    Name = "chat-staging-server"
  }
}


# 6. Static Elastic IP Allocation & Association
resource "aws_eip" "chat_eip" {
  domain = "vpc"
}

resource "aws_eip_association" "eip_assoc" {
  instance_id   = aws_instance.chat_server.id
  allocation_id = aws_eip.chat_eip.id
}

# 7. Output the public IP immediately after apply
output "staging_public_ip" {
  description = "The static public Elastic IP address assigned to the staging application server"
  value       = aws_eip.chat_eip.public_ip
}
