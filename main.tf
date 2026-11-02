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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
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

variable "instance_profile_name" {
  description = <<-EOT
    Vacio = Terraform crea su propio IAM Role + Instance Profile.
    Si usas AWS Academy / Learner Lab (no deja crear roles), pon "LabInstanceProfile".
  EOT
  type        = string
  default     = ""
}

variable "db_name" {
  type    = string
  default = "todo"
}

variable "db_username" {
  type    = string
  default = "todoadmin"
}

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------------------
# AMI: Amazon Linux 2023
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
# Key Pair (igual que en la Parte 1)
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
# Security Groups
#   app: SSH + API abiertos
#   db : PostgreSQL (5432) SOLO desde el SG de la app  -> permiso de RED
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

resource "aws_security_group" "db" {
  name        = "todo-list-db-sg"
  description = "PostgreSQL solo desde la EC2 de la app"

  ingress {
    description     = "PostgreSQL desde la app"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------
# RDS PostgreSQL (privada, sin IP publica)
# ---------------------------------------------------------------------------
resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_db_instance" "todo" {
  identifier             = "todo-list-db"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = var.db_name
  username               = var.db_username
  password               = random_password.db.result
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  # Para clase: que destroy sea rapido y sin snapshot final
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 0
  apply_immediately       = true
}

# ---------------------------------------------------------------------------
# Secrets Manager: aqui viven las credenciales, NO en el codigo
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "db" {
  name_prefix             = "todo-list-db-"
  description             = "Credenciales de RDS para la to-do list API"
  recovery_window_in_days = 0 # se borra de inmediato en destroy
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    host     = aws_db_instance.todo.address
    port     = aws_db_instance.todo.port
    dbname   = var.db_name
    username = var.db_username
    password = random_password.db.result
  })
}

# ---------------------------------------------------------------------------
# IAM: la EC2 asume un Role que SOLO puede leer ese secreto  -> permiso de IAM
# (se omite si usas un instance profile existente, p. ej. LabInstanceProfile)
# ---------------------------------------------------------------------------
locals {
  create_iam = var.instance_profile_name == ""
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  count              = local.create_iam ? 1 : 0
  name_prefix        = "todo-list-app-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy" "read_db_secret" {
  count = local.create_iam ? 1 : 0
  name  = "read-db-secret"
  role  = aws_iam_role.app[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = aws_secretsmanager_secret.db.arn
    }]
  })
}

resource "aws_iam_instance_profile" "app" {
  count       = local.create_iam ? 1 : 0
  name_prefix = "todo-list-app-"
  role        = aws_iam_role.app[0].name
}

locals {
  instance_profile = local.create_iam ? aws_iam_instance_profile.app[0].name : var.instance_profile_name
}

# ---------------------------------------------------------------------------
# EC2
# ---------------------------------------------------------------------------
resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.todo.key_name
  vpc_security_group_ids      = [aws_security_group.app.id]
  associate_public_ip_address = true
  iam_instance_profile        = local.instance_profile
  user_data_replace_on_change = true

  # La instancia se crea cuando la BD y el secreto ya existen
  depends_on = [
    aws_secretsmanager_secret_version.db,
    aws_iam_role_policy.read_db_secret,
  ]

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    dnf install -y git python3-pip
    # Cliente psql para validar la BD desde la instancia
    dnf install -y postgresql16 || dnf install -y postgresql15

    git clone ${var.repo_url} /opt/todo
    python3 -m venv /opt/todo/venv
    /opt/todo/venv/bin/pip install --upgrade pip
    /opt/todo/venv/bin/pip install -r /opt/todo/requirements.txt

    cat > /etc/systemd/system/todo.service <<'UNIT'
    [Unit]
    Description=To-do list API
    After=network-online.target
    Wants=network-online.target

    [Service]
    WorkingDirectory=/opt/todo
    Environment=PORT=5000
    Environment=DB_SECRET_ID=${aws_secretsmanager_secret.db.name}
    Environment=AWS_DEFAULT_REGION=${var.region}
    ExecStart=/opt/todo/venv/bin/python /opt/todo/app.py
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

output "db_endpoint" {
  value = aws_db_instance.todo.address
}

output "db_secret_name" {
  value = aws_secretsmanager_secret.db.name
}
