# to-do-list-api

API para gestionar tareas pendientes. Corre en una EC2 y guarda las tareas en RDS PostgreSQL. Toda la infraestructura sale de Terraform, se prueba y despliega con GitHub Actions, y se monitorea con CloudWatch.

![Arquitectura](docs/arquitectura.png)

## Endpoints

| Método | Ruta       | Descripción |
|--------|------------|-------------|
| GET    | `/tasks`   | Lista las tareas registradas |
| POST   | `/tasks`   | Crea una tarea. Body: `{"title": "texto", "done": false}` (`done` es opcional) |
| GET    | `/version` | Versión desplegada, leída de la variable de ambiente `APP_VERSION` |
| GET    | `/health`  | Conexión a la BD (`OK`/`FAIL`), versión y timestamp del servidor. Responde 200 si la BD está bien y 503 si no |

```bash
curl -X POST http://<ip-de-tu-ec2>:8000/tasks \
  -H "Content-Type: application/json" \
  -d '{"title": "estudiar para el examen de desarrollo en la nube", "done": false}'

curl http://<ip-de-tu-ec2>:8000/tasks
curl http://<ip-de-tu-ec2>:8000/version
curl http://<ip-de-tu-ec2>:8000/health
```

## Estructura

```text
to-do-list-api/
├── src/
│   ├── main.py               # API + métricas de CloudWatch
│   └── requirements.txt
├── tests/
│   └── test_main.py          # pruebas unitarias (pytest)
├── terraform/
│   ├── main.tf               # EC2, SG, Key Pair, RDS, Secrets Manager, IAM, SNS, alarmas, dashboard
│   ├── variables.tf
│   ├── outputs.tf
│   └── user_data.sh.tftpl    # clona el repo, instala dependencias y levanta la app
├── alerting/
│   ├── alarms.json           # configuración de las 3 alarmas
│   └── cloudwatch-dashboard.json
├── scripts/
│   ├── deploy.sh             # instala una versión en la EC2 (lo usan user_data y Deploy)
│   └── set-aws-secrets.sh    # actualiza los secrets de AWS con un sandbox nuevo
├── .github/workflows/
│   ├── provision.yml   destroy.yml   health-check.yml
│   └── ci.yml          release.yml   deploy.yml
└── docs/arquitectura.dot     # fuente del diagrama
```

## Correr local

```bash
pip install -r src/requirements.txt -r requirements-dev.txt
python -m pytest -v                       # pruebas unitarias
APP_VERSION=local python src/main.py      # sin DB_SECRET_ID guarda en memoria
```

## Configuración (una sola vez)

1. Genera la llave SSH que usará la EC2:
   ```bash
   ssh-keygen -t ed25519 -N "" -C to-do-list-api -f ~/.ssh/todo-list-key
   ```
2. Crea estos secrets en **Settings → Secrets and variables → Actions**:

   | Secret | Valor | Cuándo cambia |
   |---|---|---|
   | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Learner Lab → AWS Details → AWS CLI | Con cada sandbox nuevo (`./scripts/set-aws-secrets.sh`) |
   | `EC2_SSH_KEY` | `gh secret set EC2_SSH_KEY < ~/.ssh/todo-list-key` | Nunca |
   | `ALERT_EMAIL` | Correo que recibe las alarmas | Nunca |
   | `EC2_HOST` | IP pública de la EC2 | Después de cada **Provision** |
   | `GH_PAT` (opcional) | Token *fine-grained* con permiso *Secrets: Read and write* | Si existe, **Provision** actualiza `EC2_HOST` sola |

3. Protege `main`: **Settings → Rules → Rulesets → New branch ruleset**, en estado *Active*, con target *Default branch*, marcando *Require a pull request before merging* y *Require status checks to pass* con el check **`tests`**.

## Crear y destruir la infraestructura

- **Crear:** Actions → **Provision** → *Run workflow*. Tarda de 10 a 15 minutos.
  - Crea el bucket del tfstate si no existe y corre `terraform apply`.
  - Al final, el resumen muestra la IP, las URLs y el link al dashboard.
  - Después guarda la IP en `EC2_HOST` y **confirma la suscripción de SNS** en tu correo. Cada sandbox nuevo crea un tópico nuevo.
- **Destruir:** Actions → **Destroy** → *Run workflow*, escribiendo `destroy` para confirmar.

El tfstate vive en S3, en `s3://tfstate-to-do-list-api-<ACCOUNT_ID>/to-do-list-api/terraform.tfstate`, con versionado y bloqueo (`use_lockfile`). Nunca se sube al repositorio.

Desde tu compu, con las credenciales del lab configuradas:
```bash
cd terraform
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
terraform init -backend-config="bucket=tfstate-to-do-list-api-$ACCOUNT_ID"
terraform plan \
  -var "ssh_public_key=$(cat ~/.ssh/todo-list-key.pub)" \
  -var "instance_profile_name=LabInstanceProfile" \
  -var "alert_email=tu@correo.com"
```

Al arrancar, la EC2 ejecuta `user_data`. Clona este repositorio, se pone en el último release (o en `main` si no hay ninguno), instala las dependencias en un venv y levanta la app como servicio `systemd`. No hace falta SSH ni `scp`.

## CI/CD

| Workflow | Disparador | Qué hace |
|---|---|---|
| **CI** | Pull Request hacia `main` (y push a `main`) | Corre las pruebas; con la regla de `main`, el PR no se integra si fallan |
| **Release** | Push de una etiqueta `v#.#.#` | Corre las pruebas, crea el release con el repositorio en `to-do-list-api-v#.#.#.zip` y llama a Deploy |
| **Deploy** | Release nuevo (llamado por Release, publicado a mano o manual) | Entra por SSH a la EC2, descarga el zip del release, reinicia la app y comprueba `GET /version` |
| **Health check** | Cada 5 minutos | `GET /health`; falla si la app no responde o la BD está en `FAIL` |

```bash
git checkout main && git pull
git tag v2.0.0
git push origin v2.0.0
curl http://<ip>:8000/version     # {"version": "v2.0.0"}
```

> Un release creado con el `GITHUB_TOKEN` no dispara el evento `release` en otros workflows. Por eso Release llama a Deploy directamente (`workflow_call`). Deploy también escucha `release: published`, para los releases que se publican a mano.

## Observabilidad (CloudWatch)

| Métrica | Tipo | Alarma | Por qué |
|---|---|---|---|
| `AWS/EC2 CPUUtilization` | Nativa de AWS | Promedio > 80% en 3 periodos seguidos de 5 min | Una saturación sostenida de la t3.micro vuelve lenta la API; un pico corto no es problema |
| `ToDoListApi/DatabaseErrors` | Propia (`put_metric_data`) | Suma ≥ 1 en 5 min | Con la BD sana vale 0. El health check corre cada 5 min, así que una caída se detecta aunque no haya usuarios |
| `ToDoListApi/TasksCreated` | Propia (`put_metric_data`) | Suma > 100 en 5 min | Mide el uso real de la app. Un pico anormal indica un bot o un abuso del API, que no tiene autenticación |

- La app acumula los contadores en memoria y los manda cada 60 segundos en una sola llamada a `put_metric_data`, incluyendo los ceros para que las gráficas no tengan huecos.
- Las 3 alarmas avisan por correo a través del tópico SNS `to-do-list-api-alertas`, tanto al entrar en alarma como al recuperarse.
- La configuración está en [`alerting/alarms.json`](alerting/alarms.json) y [`alerting/cloudwatch-dashboard.json`](alerting/cloudwatch-dashboard.json). Terraform las lee de esos archivos.

### Probar la alarma de errores de RDS

```bash
aws rds stop-db-instance --db-instance-identifier todo-list-db    # tarda unos minutos
for i in $(seq 1 5); do curl -s http://<ip>:8000/tasks; echo; done # 500 + DatabaseErrors
curl http://<ip>:8000/health                                       # {"database": "FAIL", ...} HTTP 503
# En 5-10 min la alarma pasa a ALARM y llega el correo
aws rds start-db-instance --db-instance-identifier todo-list-db
```

### Probar la alarma de tareas

```bash
for i in $(seq 1 120); do
  curl -s -X POST http://<ip>:8000/tasks -H "Content-Type: application/json" \
    -d "{\"title\": \"tarea $i\"}" > /dev/null
done
```

## Diagnóstico en la EC2

```bash
ssh -i ~/.ssh/todo-list-key ec2-user@<ip>
sudo systemctl status todo
sudo journalctl -u todo -n 50
sudo cat /var/log/cloud-init-output.log       # salida del user_data
```

Para consultar los datos en la BD, desde la EC2:
```bash
aws secretsmanager get-secret-value --secret-id <db_secret_name> --query SecretString --output text
psql "host=<db_endpoint> dbname=todo user=todoadmin sslmode=require" -c "SELECT * FROM tasks;"
```
