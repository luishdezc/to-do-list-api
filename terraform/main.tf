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

  # El tfstate vive en S3: nunca en el repositorio ni en el runner de GitHub.
  # El bucket se pasa al hacer init (el workflow Provision lo crea si no existe):
  #   terraform init -backend-config="bucket=tfstate-to-do-list-api-<ACCOUNT_ID>"
  backend "s3" {
    key          = "to-do-list-api/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
}

locals {
  name = "to-do-list-api"
}

# ===========================================================================
# Red y acceso
# ===========================================================================
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

# La llave se genera una vez con ssh-keygen; la privada vive en el secret EC2_SSH_KEY
resource "aws_key_pair" "todo" {
  key_name   = "todo-list-key"
  public_key = var.ssh_public_key
}

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
    from_port   = var.app_port
    to_port     = var.app_port
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

# ===========================================================================
# Base de datos: RDS PostgreSQL + credenciales en Secrets Manager
# ===========================================================================
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

# ===========================================================================
# IAM: la EC2 puede leer SOLO su secreto y publicar metricas en su namespace
# (se omite si usas un instance profile existente, p. ej. LabInstanceProfile)
# ===========================================================================
locals {
  create_iam       = var.instance_profile_name == ""
  instance_profile = local.create_iam ? aws_iam_instance_profile.app[0].name : var.instance_profile_name
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

resource "aws_iam_role_policy" "app" {
  count = local.create_iam ? 1 : 0
  name  = "todo-list-app"
  role  = aws_iam_role.app[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = aws_secretsmanager_secret.db.arn
      },
      {
        Effect   = "Allow"
        Action   = "cloudwatch:PutMetricData"
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = var.metrics_namespace }
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "app" {
  count       = local.create_iam ? 1 : 0
  name_prefix = "todo-list-app-"
  role        = aws_iam_role.app[0].name
}

# ===========================================================================
# EC2: user_data clona el repo, instala dependencias y levanta la app
# ===========================================================================
resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.todo.key_name
  vpc_security_group_ids      = [aws_security_group.app.id]
  associate_public_ip_address = true
  iam_instance_profile        = local.instance_profile
  user_data_replace_on_change = true

  # La app arranca cuando la BD y el secreto ya existen
  depends_on = [
    aws_secretsmanager_secret_version.db,
    aws_iam_role_policy.app,
  ]

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    github_repo       = var.github_repo
    db_secret_id      = aws_secretsmanager_secret.db.name
    region            = var.region
    app_port          = var.app_port
    metrics_namespace = var.metrics_namespace
  })

  tags = {
    Name = local.name
  }
}

# ===========================================================================
# Observabilidad: SNS (correo), alarmas y dashboard de CloudWatch.
# La configuracion vive en ../alerting para poder revisarla como JSON.
# ===========================================================================
resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alertas"
}

# AWS manda un correo de confirmacion: hay que darle "Confirm subscription"
resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  alarms = { for alarm in jsondecode(file("${path.module}/../alerting/alarms.json")) : alarm.AlarmName => alarm }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = each.value.AlarmName
  alarm_description   = each.value.AlarmDescription
  namespace           = replace(each.value.Namespace, "$${metrics_namespace}", var.metrics_namespace)
  metric_name         = each.value.MetricName
  statistic           = each.value.Statistic
  period              = each.value.Period
  evaluation_periods  = each.value.EvaluationPeriods
  datapoints_to_alarm = each.value.DatapointsToAlarm
  threshold           = each.value.Threshold
  comparison_operator = each.value.ComparisonOperator
  treat_missing_data  = each.value.TreatMissingData

  # "${instance_id}" en el JSON se reemplaza por el id real de la EC2
  dimensions = {
    for d in try(each.value.Dimensions, []) :
    d.Name => replace(d.Value, "$${instance_id}", aws_instance.app.id)
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_dashboard" "todo" {
  dashboard_name = local.name
  dashboard_body = templatefile("${path.module}/../alerting/cloudwatch-dashboard.json", {
    instance_id       = aws_instance.app.id
    region            = var.region
    metrics_namespace = var.metrics_namespace
  })
}
