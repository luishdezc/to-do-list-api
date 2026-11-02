terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "region" {
  description = "Region de AWS"
  type        = string
  default     = "us-east-1"
}

variable "repo_url" {
  description = "URL publica de tu repo en GitHub (CAMBIA TU_USUARIO)"
  type        = string
  default     = "https://github.com/TU_USUARIO/to-do-list-api.git"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "ssh_cidr" {
  description = "Desde donde se permite SSH. Idealmente tu IP: x.x.x.x/32"
  type        = string
  default     = "0.0.0.0/0"
}

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------------------
# AMI: Amazon Linux 2023 (trae python3 instalado)
# ---------------------------------------------------------------------------
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ---------------------------------------------------------------------------
# Key Pair: Terraform genera la llave y guarda la privada en todo-list-key.pem
# (la llave privada queda en el tfstate: otra razon para NO subirlo a git)
# ---------------------------------------------------------------------------
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "todo" {
  key_name   = "todo-list-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.module}/todo-list-key.pem"
  file_permission = "0400"
}

# ---------------------------------------------------------------------------
# Security Group: SSH (22) y la API (5000)
# ---------------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "todo-list-app-sg"
  description = "SSH y puerto de la API"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  ingress {
    description = "API to-do list"
    from_port   = 5000
    to_port     = 5000
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

# ---------------------------------------------------------------------------
# EC2: user_data clona el repo y deja la app corriendo como servicio systemd
# ---------------------------------------------------------------------------
resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.todo.key_name
  vpc_security_group_ids      = [aws_security_group.app.id]
  associate_public_ip_address = true

  # Si cambias el script, Terraform recrea la instancia para que se vuelva a ejecutar
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    dnf install -y git
    git clone ${var.repo_url} /opt/todo

    cat > /etc/systemd/system/todo.service <<'UNIT'
    [Unit]
    Description=To-do list API
    After=network-online.target
    Wants=network-online.target

    [Service]
    WorkingDirectory=/opt/todo
    Environment=PORT=5000
    ExecStart=/usr/bin/python3 /opt/todo/app.py
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable --now todo.service
  EOF

  tags = {
    Name = "todo-list-api"
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "public_ip" {
  value = aws_instance.app.public_ip
}

output "api_url" {
  value = "http://${aws_instance.app.public_ip}:5000/tasks"
}

output "ssh" {
  value = "ssh -i todo-list-key.pem ec2-user@${aws_instance.app.public_ip}"
}
