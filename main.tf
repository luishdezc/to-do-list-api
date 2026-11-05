terraform {
  # use_lockfile (candado del state en S3 sin DynamoDB) requiere Terraform >= 1.10
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # El tfstate vive en S3, no en la compu ni en el runner de GitHub.
  # El bucket se pasa al hacer init (los workflows lo crean si no existe):
  #   terraform init -backend-config="bucket=tfstate-to-do-list-api-<ACCOUNT_ID>"
  backend "s3" {
    key          = "to-do-list-api/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "region" {
  description = "Region de AWS (Learner Lab: us-east-1 o us-west-2)"
  type        = string
  default     = "us-east-1"
}

variable "github_repo" {
  description = "Repositorio publico en formato owner/nombre. Los workflows lo pasan solos."
  type        = string
  default     = "TU_USUARIO/to-do-list-api"
}

variable "ssh_public_key" {
  description = "Llave publica SSH (contenido de todo-list-key.pub). Los workflows la sacan del secret EC2_SSH_KEY."
  type        = string
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "ssh_cidr" {
  description = "Desde donde se permite SSH. GitHub Actions necesita entrar para desplegar."
  type        = string
  default     = "0.0.0.0/0"
}

variable "instance_profile_name" {
  description = <<-EOT
    Vacio = Terraform crea su propio IAM Role + Instance Profile.
    En AWS Academy / Learner Lab (no deja crear roles) usa "LabInstanceProfile".
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
# Key Pair: la llave se genera una sola vez en tu compu (ssh-keygen) y la
# privada vive en el secret EC2_SSH_KEY. Asi sobrevive a cada sandbox nuevo
# y GitHub Actions puede entrar por SSH a desplegar.
# ---------------------------------------------------------------------------
resource "aws_key_pair" "todo" {
  key_name   = "todo-list-key"
  public_key = var.ssh_public_key
}

# ---------------------------------------------------------------------------
# Security Groups
#   app: SSH + API
#   db : PostgreSQL (5432) SOLO desde el SG de la app
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
# RDS PostgreSQL (privada)
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

  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 0
  apply_immediately       = true
}

# ---------------------------------------------------------------------------
# Secrets Manager: credenciales de la BD fuera del codigo
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "db" {
  name_prefix             = "todo-list-db-"
  description             = "Credenciales de RDS para la to-do list API"
  recovery_window_in_days = 0
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
# IAM: Role con permiso SOLO para leer ese secreto
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
# EC2: user_data prepara la instancia y despliega el ultimo release
# (o la rama main si todavia no hay releases)
# ---------------------------------------------------------------------------
resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.todo.key_name
  vpc_security_group_ids      = [aws_security_group.app.id]
  associate_public_ip_address = true
  iam_instance_profile        = local.instance_profile
  user_data_replace_on_change = true

  depends_on = [
    aws_secretsmanager_secret_version.db,
    aws_iam_role_policy.read_db_secret,
  ]

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    github_repo  = var.github_repo
    db_secret_id = aws_secretsmanager_secret.db.name
    region       = var.region
  })

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

output "version_url" {
  value = "http://${aws_instance.app.public_ip}:5000/version"
}

output "ssh" {
  value = "ssh -i ~/.ssh/todo-list-key ec2-user@${aws_instance.app.public_ip}"
}

output "db_endpoint" {
  value = aws_db_instance.todo.address
}

output "db_secret_name" {
  value = aws_secretsmanager_secret.db.name
}
