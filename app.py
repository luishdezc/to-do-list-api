#!/usr/bin/env python3

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("HOST", "0.0.0.0")
PORT = int(os.environ.get("PORT", "5000"))

# "Base de datos" en memoria
tasks = []


class TodoHandler(BaseHTTPRequestHandler):
    server_version = "TodoList/1.0"

    def _send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _path(self):
        return self.path.split("?")[0].rstrip("/") or "/"

    def do_GET(self):
        path = self._path()
        if path == "/tasks":
            self._send_json(200, {"tasks": tasks})
        elif path in ("/", "/health"):
            self._send_json(200, {"status": "ok", "total": len(tasks)})
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
            self._send_json(400, {"error": "el body no es JSON válido"})
            return

        tarea = data.get("tarea") if isinstance(data, dict) else None
        if not isinstance(tarea, str) or not tarea.strip():
            self._send_json(400, {"error": "falta el campo 'tarea'"})
            return

        tasks.append(tarea.strip())
        self._send_json(201, {"tarea": tarea.strip(), "total": len(tasks)})

    def log_message(self, fmt, *args):
        # Log en una sola línea, útil cuando corre con nohup/systemd
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


def main():
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
