# to-do-list-api

API de to-do list en AWS EC2 con las tareas guardadas en RDS PostgreSQL. La infraestructura sale de Terraform y se crea, prueba, publica y despliega con GitHub Actions.

| Método | Ruta       | Descripción                                  |
|--------|------------|----------------------------------------------|
| GET    | `/tasks`   | Lista las tareas                             |
| POST   | `/tasks`   | Agrega una tarea. Body: `{"tarea": "texto"}` |
| GET    | `/version` | Versión desplegada (variable `APP_VERSION`)  |
| GET    | `/health`  | Estado de la app                             |

## Workflows

| Workflow | Cuándo corre | Qué hace |
|---|---|---|
| **Infra - apply** | Manual | Crea el bucket del tfstate si no existe y corre `terraform apply` |
| **Infra - destroy** | Manual (hay que escribir `destroy`) | Corre `terraform destroy` |
| **CI** | Cada PR hacia `main` | Corre las pruebas; si fallan, el PR no se puede integrar |
| **Release** | Al empujar una etiqueta `v#.#.#` | Corre las pruebas, crea el release con el repo en zip y llama a Deploy |
| **Deploy** | Al final de Release, o manual | Por SSH, descarga el zip en la EC2, reinicia la app y verifica `/version` |

## GitHub Secrets

| Secret | Cuándo se actualiza |
|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Con cada sandbox nuevo (`./scripts/set-aws-secrets.sh`) |
| `EC2_SSH_KEY` | Una sola vez: llave privada de `ssh-keygen` |
| `EC2_HOST` | Después de cada **Infra - apply** (la IP sale en el resumen del workflow) |
| `GH_PAT` (opcional) | Si existe, **Infra - apply** actualiza `EC2_HOST` automáticamente |

## tfstate

Se guarda en S3, en `tfstate-to-do-list-api-<ACCOUNT_ID>/to-do-list-api/terraform.tfstate`, con versionado y bloqueo (`use_lockfile`). Para usarlo desde tu compu:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
terraform init -backend-config="bucket=tfstate-to-do-list-api-$ACCOUNT_ID"
terraform plan \
  -var "ssh_public_key=$(cat ~/.ssh/todo-list-key.pub)" \
  -var "github_repo=TU_USUARIO/to-do-list-api" \
  -var "instance_profile_name=LabInstanceProfile"
```

## Publicar una versión

```bash
git checkout main && git pull
git tag v1.0.0
git push origin v1.0.0
```

## Correr local

```bash
pip install -r requirements.txt -r requirements-dev.txt
python -m pytest -v          # pruebas
APP_VERSION=local python app.py   # sin DB_SECRET_ID guarda en memoria
```

## En la EC2

```text
/opt/todo/current       -> symlink a la versión activa
/opt/todo/releases/     -> últimas 3 versiones
/opt/todo/app.env       -> PORT, DB_SECRET_ID, región
/opt/todo/version.env   -> APP_VERSION
```

```bash
sudo systemctl status todo
sudo journalctl -u todo -n 50
sudo cat /var/log/cloud-init-output.log
```
