"""Pruebas unitarias de la API.

Levantan el servidor real en un puerto libre con las tareas en memoria y
metricas sin enviar, asi que no necesitan AWS ni base de datos.
Correr con:  python -m pytest -v
"""

import json
import threading
import urllib.error
import urllib.request

import pytest

from main import DATABASE_ERRORS, TASKS_CREATED, MemoryTaskStore, Metrics, create_server

# Sin proxy: las peticiones van directo a 127.0.0.1
_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class BrokenStore:
    """Simula una BD caida (por ejemplo, la instancia de RDS detenida)."""

    def init(self):
        raise ConnectionError("RDS detenida")

    def ping(self):
        raise ConnectionError("RDS detenida")

    def list_tasks(self):
        raise ConnectionError("RDS detenida")

    def add_task(self, title, done=False):
        raise ConnectionError("RDS detenida")


def _start(store):
    metrics = Metrics()  # sin cliente: cuenta pero no envia a CloudWatch
    server = create_server(store, metrics, host="127.0.0.1", port=0)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, metrics, "http://127.0.0.1:%d" % server.server_address[1]


@pytest.fixture
def api():
    server, metrics, url = _start(MemoryTaskStore())
    yield url, metrics
    server.shutdown()
    server.server_close()


@pytest.fixture
def broken_api():
    server, metrics, url = _start(BrokenStore())
    yield url, metrics
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


# --- /tasks -----------------------------------------------------------------
def test_get_tasks_empieza_vacio(api):
    url, _ = api
    status, body = call("GET", url + "/tasks")

    assert status == 200
    assert body == {"tasks": []}


def test_post_tasks_crea_la_tarea_y_aparece_en_get(api):
    url, metrics = api
    status, created = call(
        "POST", url + "/tasks", {"title": "  estudiar para el examen  ", "done": False}
    )

    assert status == 201
    assert created["id"] == 1
    assert created["title"] == "estudiar para el examen"  # se quitan los espacios
    assert created["done"] is False
    assert "created_at" in created
    assert metrics.snapshot()[TASKS_CREATED] == 1

    status, body = call("GET", url + "/tasks")
    assert status == 200
    assert [t["title"] for t in body["tasks"]] == ["estudiar para el examen"]


def test_post_tasks_done_es_opcional(api):
    url, _ = api
    status, created = call("POST", url + "/tasks", {"title": "sin done"})

    assert status == 201
    assert created["done"] is False


@pytest.mark.parametrize(
    "payload",
    [{}, {"title": ""}, {"title": "   "}, {"title": 123}, {"title": "x", "done": "si"}, []],
)
def test_post_tasks_invalido_regresa_400_y_no_guarda(api, payload):
    url, metrics = api
    status, body = call("POST", url + "/tasks", payload)

    assert status == 400
    assert "error" in body
    assert metrics.snapshot()[TASKS_CREATED] == 0
    _, listing = call("GET", url + "/tasks")
    assert listing["tasks"] == []


# --- /version y /health -----------------------------------------------------
def test_version_lee_la_variable_de_ambiente(api, monkeypatch):
    url, _ = api
    monkeypatch.setenv("APP_VERSION", "v9.9.9")

    status, body = call("GET", url + "/version")

    assert status == 200
    assert body == {"version": "v9.9.9"}


def test_health_ok_con_version_y_timestamp(api, monkeypatch):
    url, _ = api
    monkeypatch.setenv("APP_VERSION", "v1.2.3")

    status, body = call("GET", url + "/health")

    assert status == 200
    assert body["database"] == "OK"
    assert body["version"] == "v1.2.3"
    assert body["timestamp"]


# --- BD caida: errores y metrica DatabaseErrors -----------------------------
def test_bd_caida_health_fail_y_cuenta_errores(broken_api):
    url, metrics = broken_api
    errores_al_arrancar = metrics.snapshot()[DATABASE_ERRORS]  # init() fallo

    status, body = call("GET", url + "/health")
    assert status == 503
    assert body["database"] == "FAIL"

    status, _ = call("GET", url + "/tasks")
    assert status == 500

    status, _ = call("POST", url + "/tasks", {"title": "no se guarda"})
    assert status == 500

    assert metrics.snapshot()[DATABASE_ERRORS] == errores_al_arrancar + 3
    assert metrics.snapshot()[TASKS_CREATED] == 0


def test_metrics_flush_envia_todas_las_metricas_y_reinicia():
    class FakeCloudWatch:
        def __init__(self):
            self.calls = []

        def put_metric_data(self, **kwargs):
            self.calls.append(kwargs)

    client = FakeCloudWatch()
    metrics = Metrics(client=client, namespace="Pruebas")
    metrics.incr(DATABASE_ERRORS, 2)

    metrics.flush()

    assert len(client.calls) == 1
    call_args = client.calls[0]
    assert call_args["Namespace"] == "Pruebas"
    values = {m["MetricName"]: m["Value"] for m in call_args["MetricData"]}
    assert values == {DATABASE_ERRORS: 2.0, TASKS_CREATED: 0.0}  # tambien manda ceros
    assert metrics.snapshot() == {DATABASE_ERRORS: 0, TASKS_CREATED: 0}
