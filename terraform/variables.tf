variable "region" {
  description = "Region de AWS (Learner Lab: us-east-1 o us-west-2)"
  type        = string
  default     = "us-east-1"
}

variable "github_repo" {
  description = "Repositorio publico en formato owner/nombre. Los workflows lo pasan solos."
  type        = string
  default     = "luishdezc/to-do-list-api"
}

variable "ssh_public_key" {
  description = "Llave publica SSH. Los workflows la sacan del secret EC2_SSH_KEY."
  type        = string
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "app_port" {
  description = "Puerto donde escucha la API"
  type        = number
  default     = 8000
}

variable "ssh_cidr" {
  description = "Desde donde se permite SSH. GitHub Actions entra por SSH a desplegar."
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

variable "alert_email" {
  description = "Correo que recibe las alarmas (SNS). Hay que confirmar la suscripcion en el correo."
  type        = string
  default     = ""
}

variable "metrics_namespace" {
  description = "Namespace de las metricas propias en CloudWatch"
  type        = string
  default     = "ToDoListApi"
}
