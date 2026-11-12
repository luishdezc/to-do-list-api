#!/usr/bin/env python3
"""to-do-list-api

Endpoints:
  GET  /tasks    -> lista de tareas
  POST /tasks    -> crea una tarea. Body: {"title": "texto", "done": false}
  GET  /version  -> version desplegada (variable de ambiente APP_VERSION)
  GET  /health   -> conexion a la BD (OK/FAIL), version y timestamp del servidor

Almacenamiento:
  - Con DB_SECRET_ID definido, las tareas viven en RDS PostgreSQL y las
    credenciales se leen de Secrets Manager en tiempo de ejecucion.
  - Sin DB_SECRET_ID, viven en memoria (pruebas y desarrollo local).

Metricas propias en CloudWatch (put_metric_data), con METRICS_ENABLED=true:
  - DatabaseErrors: errores al leer o escribir en RDS.
  - TasksCreated:   tareas creadas con exito.
"""

import json
import os
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATABASE_ERRORS = "DatabaseErrors"
TASKS_CREATED = "TasksCreated"


def get_version():
    """La version la escribe el deploy en la variable de ambiente APP_VERSION."""
    return os.environ.get("APP_VERSION", "dev")


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def get_region():
    return os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION", "us-east-1")


# ---------------------------------------------------------------------------
# Metricas
# ---------------------------------------------------------------------------
class Metrics:
    """Cuenta eventos y los manda a CloudWatch con put_metric_data.

    Los contadores se acumulan en memoria y se envian en una sola llamada cada
    `interval` segundos. Se reportan todas las metricas aunque valgan 0, asi
    las graficas del dashboard no tienen huecos. Sin `client` (pruebas o local)
    solo cuenta y no envia nada.
    """

    NAMES = (DATABASE_ERRORS, TASKS_CREATED)

    def __init__(self, client=None, namespace="ToDoListApi", interval=60):
        self._client = client
        self._namespace = namespace
        self._interval = interval
        self._lock = threading.Lock()
        self._counts = self._zeros()
        self._stop = threading.Event()
        self._thread = None

    def _zeros(self):
        return {name: 0 for name in self.NAMES}

    def incr(self, name, value=1):
        with self._lock:
            self._counts[name] = self._counts.get(name, 0) + value

    def snapshot(self):
        with self._lock:
            return dict(self._counts)

    def flush(self):
        """Envia los contadores acumulados y los regresa a cero."""
        with self._lock:
            counts, self._counts = self._counts, self._zeros()
        if self._client is None:
            return counts
        timestamp = datetime.now(timezone.utc)
        try:
            self._client.put_metric_data(
                Namespace=self._namespace,
                MetricData=[
                    {"MetricName": name, "Value": float(value), "Unit": "Count", "Timestamp": timestamp}
                    for name, value in sorted(counts.items())
                ],
            )
        except Exception as exc:  # noqa: BLE001 - nunca tumbar la app por las metricas
            print("No se pudieron enviar las metricas a CloudWatch: %r" % (exc,), flush=True)
        return counts

    def start(self):
        if self._client is None or self._thread is not None:
            return
        self._thread = threading.Thread(target=self._loop, name="metrics", daemon=True)
        self._thread.start()

    def _loop(self):
        while not self._stop.wait(self._interval):
            self.flush()

    def stop(self):
        self._stop.set()
        if self._client is not None:
            self.flush()


def create_metrics():
    if os.environ.get("METRICS_ENABLED", "false").lower() != "true":
        return Metrics()
    import boto3

    client = boto3.client("cloudwatch", region_name=get_region())
    namespace = os.environ.get("METRICS_NAMESPACE", "ToDoListApi")
    interval = int(os.environ.get("METRICS_INTERVAL", "60"))
    print("Metricas activas en CloudWatch, namespace %s" % namespace, flush=True)
    return Metrics(client=client, namespace=namespace, interval=interval)


# ---------------------------------------------------------------------------
# Almacenamiento
# ---------------------------------------------------------------------------
class MemoryTaskStore:
    """Tareas en memoria (pruebas y desarrollo local)."""

    def __init__(self):
        self._tasks = []
        self._lock = threading.Lock()

    def init(self):
        pass

    def ping(self):
        pass

    def list_tasks(self):
        with self._lock:
            return [dict(task) for task in self._tasks]

    def add_task(self, title, done=False):
        with self._lock:
            task = {
                "id": len(self._tasks) + 1,
                "title": title,
                "done": done,
                "created_at": utc_now(),
            }
            self._tasks.append(task)
            return dict(task)


class PostgresTaskStore:
    """Tareas en RDS PostgreSQL.

    Las credenciales se leen de Secrets Manager con el IAM Role de la
    instancia: no hay contrasenas en el codigo ni en el repositorio.
    """

    SCHEMA = """
        CREATE TABLE IF NOT EXISTS tasks (
            id         SERIAL PRIMARY KEY,
            title      TEXT        NOT NULL,
            done       BOOLEAN     NOT NULL DEFAULT FALSE,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
    """

    def __init__(self, secret_id, region):
        # Se importan aqui para que las pruebas no dependan de boto3 ni psycopg2
        import boto3
        import psycopg2
        import psycopg2.extras

        self._psycopg2 = psycopg2
        self._cursor_factory = psycopg2.extras.RealDictCursor
        self._schema_ready = False

        client = boto3.client("secretsmanager", region_name=region)
        secret = json.loads(client.get_secret_value(SecretId=secret_id)["SecretString"])
        self._params = {
            "host": secret["host"],
            "port": int(secret.get("port", 5432)),
            "dbname": secret["dbname"],
            "user": secret["username"],
            "password": secret["password"],
            "connect_timeout": 5,
        }

    def _query(self, sql, params=(), fetch=None):
        # Una conexion por peticion: simple y segura con ThreadingHTTPServer.
        # Si la BD no responde, psycopg2 lanza una excepcion y el handler la cuenta.
        conn = self._psycopg2.connect(**self._params)
        try:
            with conn:  # commit si todo sale bien, rollback si hay excepcion
                with conn.cursor(cursor_factory=self._cursor_factory) as cur:
                    if not self._schema_ready:
                        cur.execute(self.SCHEMA)
                        self._schema_ready = True
                    cur.execute(sql, params)
                    if fetch == "all":
                        return cur.fetchall()
                    if fetch == "one":
                        return cur.fetchone()
                    return None
        finally:
            conn.close()

    def init(self):
        self._query("SELECT 1")

    def ping(self):
        self._query("SELECT 1", fetch="one")

    def list_tasks(self):
        return self._query(
            "SELECT id, title, done, created_at FROM tasks ORDER BY id", fetch="all"
        )

    def add_task(self, title, done=False):
        return self._query(
            "INSERT INTO tasks (title, done) VALUES (%s, %s) "
            "RETURNING id, title, done, created_at",
            (title, done),
            fetch="one",
        )


def create_store():
    secret_id = os.environ.get("DB_SECRET_ID")
    if not secret_id:
        print("DB_SECRET_ID no esta definido: las tareas se guardan en memoria", flush=True)
        return MemoryTaskStore()
    return PostgresTaskStore(secret_id, get_region())


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
class TodoHandler(BaseHTTPRequestHandler):
    server_version = "TodoList/4.0"

    @property
    def store(self):
        return self.server.store

    @property
    def metrics(self):
        return self.server.metrics

    def _send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _database_error(self, operation, exc):
        """Toda falla al leer o escribir en la BD suma 1 a DatabaseErrors."""
        self.metrics.incr(DATABASE_ERRORS)
        print("Error de base de datos en %s: %r" % (operation, exc), flush=True)

    def _path(self):
        return self.path.split("?")[0].rstrip("/") or "/"

    def do_GET(self):
        path = self._path()
        if path == "/version":
            self._send_json(200, {"version": get_version()})
        elif path in ("/", "/health"):
            self._health()
        elif path == "/tasks":
            try:
                tasks = self.store.list_tasks()
            except Exception as exc:  # noqa: BLE001
                self._database_error("GET /tasks", exc)
                self._send_json(500, {"error": "no se pudieron leer las tareas"})
                return
            self._send_json(200, {"tasks": tasks})
        else:
            self._send_json(404, {"error": "recurso no encontrado"})

    def _health(self):
        try:
            self.store.ping()
            database = "OK"
        except Exception as exc:  # noqa: BLE001
            self._database_error("GET /health", exc)
            database = "FAIL"
        self._send_json(
            200 if database == "OK" else 503,
            {"database": database, "version": get_version(), "timestamp": utc_now()},
        )

    def do_POST(self):
        if self._path() != "/tasks":
            self._send_json(404, {"error": "recurso no encontrado"})
            return

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""

        try:
            data = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._send_json(400, {"error": "el body no es JSON valido"})
            return
        if not isinstance(data, dict):
            self._send_json(400, {"error": "el body debe ser un objeto JSON"})
            return

        title = data.get("title")
        if not isinstance(title, str) or not title.strip():
            self._send_json(400, {"error": "falta el campo 'title'"})
            return
        done = data.get("done", False)
        if not isinstance(done, bool):
            self._send_json(400, {"error": "'done' debe ser true o false"})
            return

        try:
            task = self.store.add_task(title.strip(), done)
        except Exception as exc:  # noqa: BLE001
            self._database_error("POST /tasks", exc)
            self._send_json(500, {"error": "no se pudo guardar la tarea"})
            return
        self.metrics.incr(TASKS_CREATED)
        self._send_json(201, task)

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


def create_server(store, metrics=None, host="0.0.0.0", port=8000):
    """Crea el servidor. Si la BD no responde al arrancar, la app sigue viva
    (y cuenta el error) para que /health y las metricas lo reporten."""
    metrics = metrics or Metrics()
    try:
        store.init()
    except Exception as exc:  # noqa: BLE001
        metrics.incr(DATABASE_ERRORS)
        print("La BD no respondio al arrancar: %r" % (exc,), flush=True)
    server = ThreadingHTTPServer((host, port), TodoHandler)
    server.daemon_threads = True
    server.store = store
    server.metrics = metrics
    return server


def main():
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8000"))
    metrics = create_metrics()
    server = create_server(create_store(), metrics, host, port)
    metrics.start()
    print("Version %s escuchando en http://%s:%s" % (get_version(), host, port), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nDeteniendo servidor...", flush=True)
    finally:
        metrics.stop()
        server.server_close()


if __name__ == "__main__":
    main()
