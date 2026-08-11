#!/bin/bash
# deploy.sh — actualiza y redeploya la infra (se ejecuta desde /home/<USER>/docker)
# Uso: ./scripts/deploy.sh [--prune]      (INVENTORY_SHA env = commit a desplegar)
#   --prune  → además limpia imágenes/volúmenes/redes no usados (patrón Pauser)
set -e
cd "$(dirname "$0")/.."

echo "=== 1/4 git pull ==="
git pull

echo "=== 2/4 gen alertmanager config (token) ==="
./scripts/gen-alertmanager-config.sh

echo "=== 3/4 docker compose up -d --build ==="
docker compose up -d --build

if [ "$1" == "--prune" ]; then
  echo "=== 4/4 docker system prune (no usados) ==="
  docker system prune -f --volumes
else
  echo "=== 4/4 OK (usa --prune para limpiar imágenes viejas) ==="
fi

echo "DONE"
