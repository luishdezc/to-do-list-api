"""Pruebas unitarias de la API.

Levantan el servidor real en un puerto libre, con las tareas en memoria,
asi que no necesitan AWS ni base de datos.
Correr con:  python -m pytest -v
"""

import json
import threading
import urllib.error
import urllib.request

import pytest

from app import MemoryTaskStore, create_server

# Sin proxy: las peticiones van directo a 127.0.0.1
_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


@pytest.fixture
def base_url():
    server = create_server(MemoryTaskStore(), host="127.0.0.1", port=0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield "http://127.0.0.1:%d" % server.server_address[1]
    server.shutdown()
    server.server_close()


def call(method, url, body=None):
    """Hace una peticion y regresa (status, json)."""
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, method=method, headers={"Content-Type": "application/json"}
    )
    try:
        with _opener.open(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read())


def test_get_tasks_empieza_vacio(base_url):
    status, body = call("GET", base_url + "/tasks")

    assert status == 200
    assert body == {"tasks": []}


def test_post_tasks_crea_la_tarea_y_aparece_en_get(base_url):
    status, created = call("POST", base_url + "/tasks", {"tarea": "  Aprender CI/CD  "})

    assert status == 201
    assert created["id"] == 1
    assert created["tarea"] == "Aprender CI/CD"  # se quitan los espacios

    status, body = call("GET", base_url + "/tasks")
    assert status == 200
    assert [t["tarea"] for t in body["tasks"]] == ["Aprender CI/CD"]


@pytest.mark.parametrize("payload", [{}, {"tarea": ""}, {"tarea": "   "}, {"tarea": 123}])
def test_post_tasks_sin_tarea_valida_regresa_400(base_url, payload):
    status, body = call("POST", base_url + "/tasks", payload)

    assert status == 400
    assert "error" in body

    # No se guardo nada
    _, listing = call("GET", base_url + "/tasks")
    assert listing["tasks"] == []


def test_version_lee_la_variable_de_ambiente(base_url, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "v9.9.9")

    status, body = call("GET", base_url + "/version")

    assert status == 200
    assert body == {"version": "v9.9.9"}
