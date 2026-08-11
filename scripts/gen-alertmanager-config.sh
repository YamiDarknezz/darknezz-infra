#!/bin/bash
# gen-alertmanager-config.sh — genera la config real de Alertmanager con el token
# de Telegram sustituido (el token NUNCA vive en git; la config real va a data/secrets).
# Se ejecuta automáticamente desde deploy.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

TEMPLATE="services/alertmanager/alertmanager.template.yml"
OUT="$HOME/data/secrets/alertmanager.yml"

if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: no existe $TEMPLATE" >&2
  exit 1
fi

# exportar solo las variables necesarias para envsubst
if [ -f .env ]; then
  export TELEGRAM_BOT_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' .env | head -1 | cut -d= -f2-)
else
  echo "ERROR: no existe .env" >&2
  exit 1
fi

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "ERROR: TELEGRAM_BOT_TOKEN vacío en .env" >&2
  exit 1
fi

mkdir -p "$HOME/data/secrets"
chmod 700 "$HOME/data/secrets"
envsubst < "$TEMPLATE" > "$OUT"
# 644: legible por el contenedor (corre como nobody); el dir 700 ya restringe el acceso
chmod 644 "$OUT"
echo "Config Alertmanager generada: $OUT"
