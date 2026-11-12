#!/usr/bin/env bash
# Instala una version de la to-do list API en la EC2 y reinicia el servicio.
#
# Uso (como root):
#   deploy.sh <owner/repo> <version>              -> descarga el zip del release
#   deploy.sh <owner/repo> <version> <carpeta>    -> usa una copia local del repo
#
# Lo usan el user_data (primer arranque, con el repo ya clonado) y el
# workflow Deploy (por SSH, con el zip del release).
set -euo pipefail

REPO="${1:?Uso: deploy.sh <owner/repo> <version> [carpeta]}"
VERSION="${2:?Uso: deploy.sh <owner/repo> <version> [carpeta]}"
LOCAL_DIR="${3:-}"
BASE=/opt/todo

APP_PORT="$(sed -n 's/^PORT=//p' "$BASE/app.env" 2>/dev/null | head -n1)"
APP_PORT="${APP_PORT:-8000}"

if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "Repositorio invalido: $REPO" >&2; exit 1
fi
if [[ ! "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Version invalida: $VERSION" >&2; exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -n "$LOCAL_DIR" ]; then
  ROOT="$LOCAL_DIR"
else
  URL="https://github.com/$REPO/releases/download/$VERSION/to-do-list-api-$VERSION.zip"
  echo ">> Descargando $URL"
  curl -fsSL --retry 5 --retry-delay 3 -o "$TMP/app.zip" "$URL"
  mkdir -p "$TMP/src"
  unzip -q -o "$TMP/app.zip" -d "$TMP/src"
  ROOT="$TMP/src"
fi

FOUND="$(find "$ROOT" -maxdepth 3 -path '*/src/main.py' | head -n1)"
if [ -z "$FOUND" ]; then
  echo "El paquete no trae src/main.py" >&2; exit 1
fi
SRC="$(dirname "$(dirname "$FOUND")")"

DEST="$BASE/releases/$VERSION"
echo ">> Instalando en $DEST"
mkdir -p "$BASE/releases"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$SRC/." "$DEST/"
rm -rf "$DEST/.git"

PY="$(command -v python3.11 || command -v python3)"
"$PY" -m venv "$DEST/venv"
"$DEST/venv/bin/pip" install -q --upgrade pip
"$DEST/venv/bin/pip" install -q -r "$DEST/src/requirements.txt"

# Guardamos la version anterior por si hay que regresar
PREV="$(readlink -f "$BASE/current" 2>/dev/null || true)"
PREV_VERSION="$(cat "$BASE/version.env" 2>/dev/null || true)"

echo ">> Activando $VERSION"
echo "APP_VERSION=$VERSION" > "$BASE/version.env"
ln -sfn "$DEST" "$BASE/current"
systemctl restart todo

# /version no depende de la BD: confirma que la version nueva quedo arriba
for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 "http://127.0.0.1:$APP_PORT/version" 2>/dev/null | grep -qF "\"$VERSION\""; then
    echo ">> $VERSION desplegada correctamente"
    # Conserva solo las 3 versiones mas recientes (los nombres ya se validaron arriba)
    # shellcheck disable=SC2012
    ls -1dt "$BASE"/releases/*/ | tail -n +4 | xargs -r rm -rf
    exit 0
  fi
  sleep 2
done

echo "!! $VERSION no respondio en /version" >&2
journalctl -u todo -n 30 --no-pager >&2 || true

if [ -n "$PREV" ] && [ -d "$PREV" ] && [ "$PREV" != "$DEST" ]; then
  echo "!! Regresando a la version anterior: $PREV" >&2
  ln -sfn "$PREV" "$BASE/current"
  printf '%s\n' "$PREV_VERSION" > "$BASE/version.env"
  systemctl restart todo
fi
exit 1
