# to-do-list-api

API sencilla de to-do list con dos endpoints. Corre en AWS EC2 y guarda las tareas en RDS PostgreSQL. Toda la infraestructura sale de Terraform.

| Método | Ruta     | Descripción                                  |
|--------|----------|----------------------------------------------|
| GET    | `/tasks` | Lista las tareas                             |
| POST   | `/tasks` | Agrega una tarea. Body: `{"tarea": "texto"}` |

## Arquitectura

- **EC2** (Amazon Linux 2023). `user_data` clona el repo, instala `requirements.txt` en un venv y arranca la app con systemd.
- **RDS PostgreSQL**, privada. Su Security Group solo acepta el puerto 5432 desde el Security Group de la EC2.
- **Secrets Manager** guarda host, usuario y password. La app los lee con `boto3`, así que no hay credenciales en el código.
- **IAM Role + Instance Profile**: la EC2 tiene permiso de leer **solo** ese secreto.

## Despliegue

1. Edita `repo_url` en `main.tf` con la URL de este repositorio.
2. Corre:

```bash
terraform init
terraform plan
terraform apply
```

En AWS Academy / Learner Lab no se pueden crear IAM Roles. Ahí usa el perfil del laboratorio:

```bash
terraform apply -var 'instance_profile_name=LabInstanceProfile'
```

## Ver los datos en la BD (desde la EC2)

La BD es privada, así que la consulta se hace desde la instancia:

```bash
aws secretsmanager get-secret-value --region us-east-1 \
  --secret-id <db_secret_name> --query SecretString --output text

psql "host=<db_endpoint> dbname=todo user=todoadmin sslmode=require"
```

```sql
SELECT * FROM tasks;
```

## Destruir

```bash
terraform destroy
```
