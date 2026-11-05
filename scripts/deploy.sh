#!/usr/bin/env bash
# Despliega una version de la to-do list API en la EC2 y reinicia el servicio.
#
# Uso (como root):  deploy.sh <owner/repo> <tag|rama>
#   deploy.sh lh140534/to-do-list-api v1.2.0   -> descarga el zip del release
#   deploy.sh lh140534/to-do-list-api main     -> descarga el codigo de la rama
#
# Lo usan el user_data (primer arranque) y el workflow Deploy (por SSH).
set -euo pipefail

REPO="${1:?Uso: deploy.sh <owner/repo> <tag|rama>}"
REF="${2:?Uso: deploy.sh <owner/repo> <tag|rama>}"
BASE=/opt/todo
APP_PORT="${APP_PORT:-5000}"

if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "Repositorio invalido: $REPO" >&2; exit 1
fi
if [[ ! "$REF" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Version invalida: $REF" >&2; exit 1
fi

if [[ "$REF" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  URL="https://github.com/$REPO/releases/download/$REF/to-do-list-api-$REF.zip"
else
  URL="https://github.com/$REPO/archive/refs/heads/$REF.zip"
fi

DEST="$BASE/releases/$REF"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo ">> Descargando $URL"
curl -fsSL --retry 5 --retry-delay 3 -o "$TMP/app.zip" "$URL"
mkdir -p "$TMP/src"
unzip -q -o "$TMP/app.zip" -d "$TMP/src"

# El zip de una rama trae una carpeta raiz (repo-main/); el del release no
FOUND="$(find "$TMP/src" -maxdepth 2 -name app.py | head -n1)"
if [ -z "$FOUND" ]; then
  echo "El paquete no trae app.py" >&2; exit 1
fi
SRC="$(dirname "$FOUND")"

echo ">> Instalando en $DEST"
mkdir -p "$BASE/releases"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$SRC/." "$DEST/"

PY="$(command -v python3.11 || command -v python3)"
"$PY" -m venv "$DEST/venv"
"$DEST/venv/bin/pip" install -q --upgrade pip
"$DEST/venv/bin/pip" install -q -r "$DEST/requirements.txt"

# Guardamos la version anterior por si hay que regresar
PREV="$(readlink -f "$BASE/current" 2>/dev/null || true)"
PREV_VERSION="$(cat "$BASE/version.env" 2>/dev/null || true)"

echo ">> Activando $REF"
echo "APP_VERSION=$REF" > "$BASE/version.env"
ln -sfn "$DEST" "$BASE/current"
systemctl restart todo

for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 "http://127.0.0.1:$APP_PORT/health" >/dev/null 2>&1; then
    echo ">> $REF desplegada correctamente"
    # Conserva solo las 3 versiones mas recientes (los nombres ya se validaron arriba)
    # shellcheck disable=SC2012
    ls -1dt "$BASE"/releases/*/ | tail -n +4 | xargs -r rm -rf
    exit 0
  fi
  sleep 2
done

echo "!! $REF no respondio en /health" >&2
journalctl -u todo -n 30 --no-pager >&2 || true

if [ -n "$PREV" ] && [ -d "$PREV" ] && [ "$PREV" != "$DEST" ]; then
  echo "!! Regresando a la version anterior: $PREV" >&2
  ln -sfn "$PREV" "$BASE/current"
  printf '%s\n' "$PREV_VERSION" > "$BASE/version.env"
  systemctl restart todo
fi
exit 1
