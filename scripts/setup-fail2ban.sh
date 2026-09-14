#!/bin/bash
# setup-fail2ban.sh — instala/actualiza fail2ban desde los templates del repo.
# Replicable: cualquier VM nueva queda con la misma política de baneo.
# Uso: ./scripts/setup-fail2ban.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${REPO}/.env"

strip_quotes() { sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }
env_get() {
  [ -f "${ENV_FILE}" ] || { printf ''; return 0; }
  { grep -E "^$1=" "${ENV_FILE}" | head -1 | cut -d= -f2- | strip_quotes; } || true
}

echo "=== 1/5 Instalar fail2ban (si falta) ==="
if ! command -v fail2ban-client >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo apt-get install -y -qq fail2ban
fi

echo "=== 2/5 Renderizar jail.local (template + IPs propias desde .env) ==="
# El template del repo solo trae loopback + bridge de Docker: este repo es PÚBLICO y las
# IPs propias no se versionan. Se inyectan aquí desde .env, que no está en git.
# Orden = el de la copia viva conocida: VPS primero, luego las propias.
OWN_IPS="$(env_get VPS_PUBLIC_IP) $(env_get ALLOWED_IPS)"
TMP="$(mktemp)"; trap 'rm -f "${TMP}"' EXIT
cp "${REPO}/configs/fail2ban/jail.local" "${TMP}"

count_ip_lines() { awk -v ip="$1" '/^ignoreip = / && index($0, ip) {n++} END {print n+0}' "${TMP}"; }
for ip in ${OWN_IPS}; do
  [ -n "${ip}" ] || continue
  [ "$(count_ip_lines "${ip}")" -gt 0 ] || sed -i "s|^\(ignoreip = .*\)$|\1 ${ip}|" "${TMP}"
done

JLINES="$(grep -c '^ignoreip' "${TMP}" || true)"
[ "${JLINES}" -gt 0 ] || { echo "ERROR: el template no tiene líneas ignoreip" >&2; exit 1; }
INJECTED=0
for ip in ${OWN_IPS}; do
  [ -n "${ip}" ] || continue
  if [ "$(count_ip_lines "${ip}")" -ne "${JLINES}" ]; then
    echo "ERROR: ${ip} no quedó en las ${JLINES} líneas ignoreip — abortado SIN instalar" >&2
    exit 1
  fi
  INJECTED=$((INJECTED+1))
done
if [ "${INJECTED}" -eq 0 ]; then
  echo "  ⚠ .env sin VPS_PUBLIC_IP/ALLOWED_IPS: se instala solo loopback + bridge (más estricto)"
else
  echo "  ✓ ${INJECTED} IPs propias desde .env, presentes en las ${JLINES} líneas ignoreip"
fi

echo "=== 3/5 Copiar config a /etc ==="
sudo mkdir -p /etc/fail2ban/filter.d
sudo install -m 644 -o root -g root "${TMP}" /etc/fail2ban/jail.local
sudo install -m 644 -o root -g root "${REPO}/configs/fail2ban/filter.d/traefik-auth.conf" /etc/fail2ban/filter.d/traefik-auth.conf

echo "=== 4/5 Habilitar y recargar ==="
sudo systemctl enable --now fail2ban >/dev/null 2>&1 || sudo systemctl restart fail2ban
sudo fail2ban-client reload >/dev/null

echo "=== 5/5 Verificar en RUNTIME (no leyendo el archivo) ==="
sudo fail2ban-client status
for j in sshd http-traefik recidive; do
  echo "  --- ${j} ignoreip:"
  sudo fail2ban-client get "${j}" ignoreip 2>/dev/null | tail -n +2 | sed 's/^/      /'
done
echo "DONE — política de baneo replicada."
