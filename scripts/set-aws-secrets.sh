#!/usr/bin/env bash
# Actualiza los secrets de AWS del repo con las credenciales de un sandbox nuevo.
#
# Requisitos: GitHub CLI (gh) con sesion iniciada (gh auth login).
# Uso, desde la carpeta del repo:
#   ./scripts/set-aws-secrets.sh
#   -> pega el bloque de "AWS Details > AWS CLI: Show" del Learner Lab
#   -> presiona Ctrl+D (Mac/Linux) o Ctrl+Z y Enter (Git Bash en Windows)
set -euo pipefail

echo "Pega las credenciales del Learner Lab y termina con Ctrl+D:"
CREDS="$(cat)"

get() {
  printf '%s\n' "$CREDS" | tr -d '\r' \
    | sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" | head -n1
}

for key in aws_access_key_id aws_secret_access_key aws_session_token; do
  value="$(get "$key")"
  if [ -z "$value" ]; then
    echo "No encontre $key en lo que pegaste" >&2
    exit 1
  fi
  name="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  printf '%s' "$value" | gh secret set "$name"
  echo "OK  $name"
done
