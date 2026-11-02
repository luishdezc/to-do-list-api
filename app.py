#!/usr/bin/env python3

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import boto3
import psycopg2
import psycopg2.extras

HOST = os.environ.get("HOST", "0.0.0.0")
PORT = int(os.environ.get("PORT", "5000"))

# Nombre del secreto en Secrets Manager (lo pone Terraform en el servicio systemd)
SECRET_ID = os.environ["DB_SECRET_ID"]
REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION", "us-east-1")


def load_db_params():
    """Lee las credenciales de RDS desde Secrets Manager.
    boto3 usa automáticamente el IAM Role de la instancia: no hay llaves en el código."""
    client = boto3.client("secretsmanager", region_name=REGION)
    secret = json.loads(client.get_secret_value(SecretId=SECRET_ID)["SecretString"])
    return {
        "host": secret["host"],
        "port": int(secret.get("port", 5432)),
        "dbname": secret["dbname"],
        "user": secret["username"],
        "password": secret["password"],
        "connect_timeout": 5,
    }


DB_PARAMS = load_db_params()


def run_query(sql, params=(), fetch=None):
    """Abre una conexión por petición (simple y seguro con ThreadingHTTPServer)."""
    conn = psycopg2.connect(**DB_PARAMS)
    try:
        with conn:  # commit si todo sale bien, rollback si hay excepción
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute(sql, params)
                if fetch == "all":
                    return cur.fetchall()
                if fetch == "one":
                    return cur.fetchone()
                return None
    finally:
        conn.close()


def init_db():
    run_query(
        """
        CREATE TABLE IF NOT EXISTS tasks (
            id     SERIAL PRIMARY KEY,
            tarea  TEXT NOT NULL,
            creada TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """
    )


class TodoHandler(BaseHTTPRequestHandler):
    server_version = "TodoList/2.0"

    def _send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _path(self):
        return self.path.split("?")[0].rstrip("/") or "/"

    def do_GET(self):
        path = self._path()
        try:
            if path == "/tasks":
                rows = run_query(
                    "SELECT id, tarea, creada FROM tasks ORDER BY id", fetch="all"
                )
                self._send_json(200, {"tasks": rows})
            elif path in ("/", "/health"):
                row = run_query("SELECT COUNT(*) AS total FROM tasks", fetch="one")
                self._send_json(200, {"status": "ok", "total": row["total"]})
            else:
                self._send_json(404, {"error": "recurso no encontrado"})
        except psycopg2.Error as exc:
            print(f"Error de base de datos: {exc}", flush=True)
            self._send_json(500, {"error": "error de base de datos"})

    def do_POST(self):
        if self._path() != "/tasks":
            self._send_json(404, {"error": "recurso no encontrado"})
            return

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""

        try:
            data = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._send_json(400, {"error": "el body no es JSON válido"})
            return

        tarea = data.get("tarea") if isinstance(data, dict) else None
        if not isinstance(tarea, str) or not tarea.strip():
            self._send_json(400, {"error": "falta el campo 'tarea'"})
            return

        try:
            row = run_query(
                "INSERT INTO tasks (tarea) VALUES (%s) RETURNING id, tarea, creada",
                (tarea.strip(),),
                fetch="one",
            )
            self._send_json(201, row)
        except psycopg2.Error as exc:
            print(f"Error de base de datos: {exc}", flush=True)
            self._send_json(500, {"error": "error de base de datos"})

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


def main():
    # Si la BD aún no responde, el proceso falla y systemd lo reinicia en 5 s
    init_db()
    server = ThreadingHTTPServer((HOST, PORT), TodoHandler)
    print(f"Escuchando en http://{HOST}:{PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nDeteniendo servidor...", flush=True)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
