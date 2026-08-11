#!/bin/bash
# setup-fail2ban.sh — instala/actualiza fail2ban desde los templates del repo.
# Replicable: cualquier VM nueva queda con la misma política de baneo.
# Uso: ./scripts/setup-fail2ban.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== 1/4 Instalar fail2ban (si falta) ==="
if ! command -v fail2ban-client >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo apt-get install -y -qq fail2ban
fi

echo "=== 2/4 Copiar config desde templates ==="
sudo mkdir -p /etc/fail2ban/filter.d
sudo cp "${REPO}/configs/fail2ban/jail.local" /etc/fail2ban/jail.local
sudo cp "${REPO}/configs/fail2ban/filter.d/traefik-auth.conf" /etc/fail2ban/filter.d/traefik-auth.conf

echo "=== 3/4 Habilitar y recargar ==="
sudo systemctl enable --now fail2ban >/dev/null 2>&1 || sudo systemctl restart fail2ban
sudo fail2ban-client reload >/dev/null

echo "=== 4/4 Verificar ==="
sudo fail2ban-client status
echo "DONE — política de baneo replicada."
