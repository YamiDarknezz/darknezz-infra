#!/bin/bash
# setup.sh — primer boot del VPS darknezz
# 1. Crea la red docker 'proxy'  2. acme.json con permisos  3. valida .env  4. levanta todo
set -e
cd "$(dirname "$0")/.."

echo "=== 1/4 Red docker 'proxy' ==="
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy

echo "=== 2/4 acme.json (permisos) ==="
touch traefik/acme.json
chmod 600 traefik/acme.json

echo "=== 3/4 Validar .env ==="
if [ ! -f .env ]; then
  echo "ERROR: .env no existe. Copia .env.example y llena los valores."
  exit 1
fi
grep -q "^CLOUDFLARE_TOKEN=." .env || { echo "ERROR: CLOUDFLARE_TOKEN vacío en .env"; exit 1; }
grep -q "^DASHBOARD_HASH=." .env || { echo "ERROR: DASHBOARD_HASH vacío en .env"; exit 1; }
echo "OK: .env válido"

echo "=== 4/4 Levantar servicios ==="
docker compose up -d --build

echo ""
echo "DONE — verificar:"
echo "  docker compose ps"
echo "  https://traefik.example.dev/dashboard  (BasicAuth)"
echo "  https://api-inventory.example.dev/actuator/health"
