#!/bin/bash
# security-alerts.sh — alertas de seguridad a Telegram
# 1) IPs baneadas por fail2ban (eventos nuevos, por offset de bytes)
# 2) Logins SSH con clave NO autorizada (fingerprint fuera de allowlist)
# Cron: cada 5 minutos. Silencioso si no hay nada nuevo (patrón watchdog).
set -uo pipefail

TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' /home/yami/data/docker/.env | head -1 | cut -d= -f2-)
CHAT=5069336124
STATE=/home/yami/data/secrets/security-alerts.state
FAIL2BAN_LOG=/var/log/fail2ban.log

send() {
  curl -s -o /dev/null --max-time 10 -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=$1"
}

# ---------- 1) Bans nuevos de fail2ban ----------
OFFSET=$(cat "${STATE}" 2>/dev/null || echo 0)
SIZE=$(stat -c%s "${FAIL2BAN_LOG}" 2>/dev/null || echo 0)

if [ "${SIZE}" -ge "${OFFSET}" ] && [ "${SIZE}" -gt 0 ]; then
  NEW=$(tail -c +$((OFFSET+1)) "${FAIL2BAN_LOG}" 2>/dev/null | grep " Ban " || true)
  if [ -n "${NEW}" ]; then
    MSG="🚫 <b>fail2ban baneó IP nueva</b>"
    while IFS= read -r line; do
      jail=$(echo "$line" | grep -oP '\[\K\w+(?=\])' | head -1)
      ip=$(echo "$line" | grep -oP 'Ban \K\S+')
      ts=$(echo "$line" | grep -oP '^\S+ \S+' | tr -d ' ')
      MSG="${MSG}"$'\n'"• ${ip} (jail: ${jail}) — ${ts}"
    done <<< "${NEW}"
    send "${MSG}"
  fi
fi
echo "${SIZE}" > "${STATE}"

# ---------- 2) Logins SSH con clave no autorizada ----------
# Claves autorizadas (fingerprints SIN prefijo SHA256:) — yami@darknezz + github-actions-deploy
ALLOWED_KEYS="NbKbXBans3lk4AFjI6Sm2Sb+ORsBh47vm+9eJYDsLdE uRGyiCvZ5Ef8S0QytaM5yOqrqoHgUfLAbP2LByyLyqo"
# IPs silenciadas (trabajo y casa de Gerardo) — capa extra; la clave sigue siendo la autoridad
ALLOWED_IPS="38.25.50.50 179.6.26.196"

while IFS= read -r line; do
  fp=$(echo "$line" | grep -oP 'SHA256:[A-Za-z0-9+/]+' | head -1)
  fp=${fp#SHA256:}   # normalizar: quitar prefijo para comparar con allowlist
  ip=$(echo "$line" | grep -oP 'from \K\S+')
  user=$(echo "$line" | grep -oP 'for \K\S+')
  [ -z "${fp}" ] && continue
  known=0
  for a in ${ALLOWED_KEYS}; do
    [ "${fp}" = "${a}" ] && known=1
  done
  for i in ${ALLOWED_IPS}; do
    [ "${ip}" = "${i}" ] && known=1
  done
  if [ "${known}" = 0 ]; then
    send "🚨 <b>LOGIN SSH con clave NO autorizada</b>"$'\n'"IP: ${ip} | usuario: ${user}"$'\n'"Fingerprint: SHA256:${fp}"
  fi
done < <(journalctl -u ssh --since "6 minutes ago" --no-pager 2>/dev/null | grep "Accepted")

exit 0
