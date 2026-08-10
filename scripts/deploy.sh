#!/bin/bash
# deploy.sh — actualiza y redeploya la infra (se ejecuta desde /home/<USER>/docker)
# Uso: ./scripts/deploy.sh [--prune]
#   --prune  → además limpia imágenes/volúmenes/redes no usados (patrón Pauser)
set -e
cd "$(dirname "$0")/.."

echo "=== 1/3 git pull ==="
git pull

echo "=== 2/3 docker compose up -d --build ==="
docker compose up -d --build

if [ "$1" == "--prune" ]; then
  echo "=== 3/3 docker system prune (no usados) ==="
  docker system prune -f --volumes
else
  echo "=== 3/3 OK (usa --prune para limpiar imágenes viejas) ==="
fi

echo "DONE"
