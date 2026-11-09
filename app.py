#!/usr/bin/env python3
"""To-do list API.

Endpoints:
  GET  /tasks    -> lista de tareas
  POST /tasks    -> agrega una tarea. Body: {"tarea": "texto"}
  GET  /version  -> version desplegada (variable de ambiente APP_VERSION)
  GET  /health   -> estado de la app

Si existe la variable DB_SECRET_ID, las tareas se guardan en RDS PostgreSQL
(credenciales en Secrets Manager). Si no, se guardan en memoria: asi corren
las pruebas y la app en tu compu sin base de datos.
"""

import json
import os
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def get_version():
    """La version la pone el deploy en la variable de ambiente APP_VERSION."""
    return os.environ.get("APP_VERSION", "dev")


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

    def list_tasks(self):
        with self._lock:
            return [dict(task) for task in self._tasks]

    def add_task(self, tarea):
        with self._lock:
            task = {
                "id": len(self._tasks) + 1,
                "tarea": tarea,
                "creada": datetime.now(timezone.utc).isoformat(),
            }
            self._tasks.append(task)
            return dict(task)


class PostgresTaskStore:
    """Tareas en RDS PostgreSQL.

    Las credenciales se leen de Secrets Manager; boto3 usa el IAM Role de la
    instancia, asi que no hay contrasenas en el codigo.
    """

    def __init__(self, secret_id, region):
        # Se importan aqui para que las pruebas no dependan de boto3 ni psycopg2
        import boto3
        import psycopg2
        import psycopg2.extras

        self._psycopg2 = psycopg2
        self._cursor_factory = psycopg2.extras.RealDictCursor

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
        # Una conexion por peticion: simple y segura con ThreadingHTTPServer
        conn = self._psycopg2.connect(**self._params)
        try:
            with conn:  # commit si todo sale bien, rollback si hay excepcion
                with conn.cursor(cursor_factory=self._cursor_factory) as cur:
                    cur.execute(sql, params)
                    if fetch == "all":
                        return cur.fetchall()
                    if fetch == "one":
                        return cur.fetchone()
                    return None
        finally:
            conn.close()

    def init(self):
        self._query(
            """
            CREATE TABLE IF NOT EXISTS tasks (
                id     SERIAL PRIMARY KEY,
                tarea  TEXT NOT NULL,
                creada TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """
        )

    def list_tasks(self):
        return self._query("SELECT id, tarea, creada FROM tasks ORDER BY id", fetch="all")

    def add_task(self, tarea):
        return self._query(
            "INSERT INTO tasks (tarea) VALUES (%s) RETURNING id, tarea, creada",
            (tarea,),
            fetch="one",
        )


def create_store():
    secret_id = os.environ.get("DB_SECRET_ID")
    if not secret_id:
        print("DB_SECRET_ID no esta definido: las tareas se guardan en memoria", flush=True)
        return MemoryTaskStore()
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    return PostgresTaskStore(secret_id, region)


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
class TodoHandler(BaseHTTPRequestHandler):
    server_version = "TodoList/3.0"

    @property
    def store(self):
        return self.server.store

    def _send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _server_error(self, exc):
        print("Error al acceder a las tareas: %r" % (exc,), flush=True)
        self._send_json(500, {"error": "error interno"})

    def _path(self):
        return self.path.split("?")[0].rstrip("/") or "/"

    def do_GET(self):
        path = self._path()
        if path == "/version":
            self._send_json(200, {"version": get_version()})
        elif path in ("/", "/health"):
            self._send_json(200, {"status": "ok", "version": get_version()})
        elif path == "/tasks":
            try:
                self._send_json(200, {"tasks": self.store.list_tasks()})
            except Exception as exc:  # noqa: BLE001
                self._server_error(exc)
        else:
            self._send_json(404, {"error": "recurso no encontrado"})

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

        tarea = data.get("tarea") if isinstance(data, dict) else None
        if not isinstance(tarea, str) or not tarea.strip():
            self._send_json(400, {"error": "falta el campo 'tarea'"})
            return

        try:
            self._send_json(201, self.store.add_task(tarea.strip()))
        except Exception as exc:  # noqa: BLE001
            self._server_error(exc)

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


def create_server(store, host="0.0.0.0", port=5000):
    """Crea el servidor con el almacenamiento indicado (las pruebas usan memoria)."""
    store.init()
    server = ThreadingHTTPServer((host, port), TodoHandler)
    server.daemon_threads = True
    server.store = store
    return server


def main():
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "5000"))
    # Si la BD aun no responde, el proceso falla y systemd lo reinicia en 5 s
    server = create_server(create_store(), host, port)
    print("Version %s escuchando en http://%s:%s" % (get_version(), host, port), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nDeteniendo servidor...", flush=True)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
