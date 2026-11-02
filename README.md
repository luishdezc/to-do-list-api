# to-do-list-api

API sencilla de to-do list con dos endpoints, desplegada en AWS EC2 con Terraform.

| Método | Ruta     | Descripción                                  |
|--------|----------|----------------------------------------------|
| GET    | `/tasks` | Lista las tareas                             |
| POST   | `/tasks` | Agrega una tarea. Body: `{"tarea": "texto"}` |

## Despliegue

1. Edita `repo_url` en `main.tf` con la URL de este repositorio.
2. Corre:

```bash
terraform init
terraform plan
terraform apply
```

3. Espera 1–2 minutos y prueba la API:

```bash
curl http://<public_ip>:5000/tasks
curl -X POST http://<public_ip>:5000/tasks \
  -H "Content-Type: application/json" \
  -d '{"tarea": "Aprender Terraform"}'
```

`user_data` clona este repo en la instancia y arranca la app como servicio systemd.

## Destruir

```bash
terraform destroy
```
