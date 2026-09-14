#!/bin/bash
# security-alerts.sh — alertas de seguridad a Telegram
# 1) IPs baneadas por fail2ban (eventos nuevos, por offset de bytes)
# 2) Logins SSH con clave NO autorizada (fingerprint fuera de allowlist)
# Cron: cada 5 minutos. Silencioso si no hay nada nuevo (patrón watchdog).
#
# REGLA DE ESTE SCRIPT: su silencio debe significar "no hay nada que reportar",
# NUNCA "me faltó config y no avisé". Si falta .env, falta una variable, el estado no
# se puede escribir o Telegram rechaza el envío → deja constancia en ERRLOG (y avisa
# por Telegram cuando el token aún sirve) en vez de morir en silencio.
set -uo pipefail

ENV_FILE=/home/yami/data/repos/darknezz-infra/.env
STATE=/home/yami/data/secrets/security-alerts.state
ERRLOG=/home/yami/data/secrets/security-alerts.errors.log
FAIL2BAN_LOG=/var/log/fail2ban.log

# die <mensaje>: falla visible. Intenta avisar por Telegram si el token está disponible
# (si el problema es justamente el .env, queda al menos en ERRLOG y en stderr).
die() {
  local msg
  msg="$(date -Is) ERROR: $1"
  echo "${msg}" >&2
  echo "${msg}" >> "${ERRLOG}" 2>/dev/null
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -s -o /dev/null --max-time 10 -X POST \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=⚠️ security-alerts.sh: $1" 2>/dev/null
  fi
  exit 1
}

# Leer secrets de .env. Nota: los valores con espacios DEBEN ir entre comillas en el
# .env — sin comillas, bash ejecuta el 2do token como comando y la variable queda
# VACÍA sin ningún error (así estuvo ALLOWED_KEYS/ALLOWED_IPS: allowlist a ciegas).
[ -r "${ENV_FILE}" ] || die "no puedo leer ${ENV_FILE} — sin secrets no hay alertas"
# shellcheck disable=SC1090
source "${ENV_FILE}"

[ -n "${TELEGRAM_BOT_TOKEN:-}" ] || die ".env sin TELEGRAM_BOT_TOKEN"
[ -n "${TELEGRAM_CHAT_ID:-}" ]   || die ".env sin TELEGRAM_CHAT_ID"
[ -n "${ALLOWED_KEYS:-}" ]       || die "ALLOWED_KEYS vacío en .env (¿valores con espacios sin comillas?) — el chequeo SSH quedaría a ciegas"
[ -n "${ALLOWED_IPS:-}" ]        || die "ALLOWED_IPS vacío en .env (¿valores con espacios sin comillas?) — el chequeo SSH quedaría a ciegas"

TOKEN="${TELEGRAM_BOT_TOKEN}"
CHAT="${TELEGRAM_CHAT_ID}"

# send <texto>: envía y deja rastro si Telegram no aceptó (un alerta perdida en silencio
# es el peor modo de fallo de un watchdog).
send() {
  local out
  if ! out=$(curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${CHAT}" \
      --data-urlencode "parse_mode=HTML" \
      --data-urlencode "text=$1" 2>&1); then
    echo "$(date -Is) AVISO: envío a Telegram falló (curl): ${out}" >> "${ERRLOG}" 2>/dev/null
    echo "$(date -Is) AVISO: envío a Telegram falló (curl)" >&2
    return 0
  fi
  case "${out}" in
    *'"ok":true'*) : ;;
    *) echo "$(date -Is) AVISO: Telegram respondió sin ok: ${out}" >> "${ERRLOG}" 2>/dev/null
       echo "${out}" >&2 ;;
  esac
}

# ---------- 1) Bans nuevos de fail2ban ----------
OFFSET=$(cat "${STATE}" 2>/dev/null || echo 0)
SIZE=$(stat -c%s "${FAIL2BAN_LOG}" 2>/dev/null || echo 0)

# Rotación del log: si encogió, el offset viejo ya no aplica. Sin este chequeo el bloque
# de bans queda salteado en silencio hasta que el log vuelva a superar el offset viejo
# (podés perderte días de baneos sin que nada lo diga).
if [ "${SIZE}" -lt "${OFFSET}" ]; then
  echo "$(date -Is) AVISO: ${FAIL2BAN_LOG} rotó (offset ${OFFSET} > tamaño ${SIZE}); reinicio el offset" \
    >> "${ERRLOG}" 2>/dev/null
  OFFSET="${SIZE}"
fi

if [ "${SIZE}" -gt "${OFFSET}" ]; then
  # Solo líneas de ban reales (fail2ban.actions): " Ban " también matchea
  # "Increase Ban" (bantime.increment), duplicando notificaciones por baneo.
  NEW=$(tail -c +$((OFFSET+1)) "${FAIL2BAN_LOG}" 2>/dev/null | grep -E '\] Ban ' || true)

  if [ -n "${NEW}" ]; then
    MSG="🚫 <b>fail2ban baneó IP nueva</b>"
    while IFS= read -r line; do
      # El primer corchete es el PID de fail2ban ([827]); el nombre real de la
      # jail va tras NOTICE:  ...NOTICE [http-traefik] Ban <ip>
      jail=$(echo "$line" | grep -oP 'NOTICE\s*\[\K[^\]]+' | head -1)
      ip=$(echo "$line" | grep -oP 'Ban \K\S+')
      ts=$(echo "$line" | grep -oP '^\S+ \S+')
      MSG="${MSG}"$'\n'"• ${ip} (jail: ${jail}) — ${ts}"
    done <<< "${NEW}"
    send "${MSG}"
  fi
fi

# Guardar el offset: si esto falla, las alertas de bans se duplican o se pierden.
if ! echo "${SIZE}" > "${STATE}" 2>/dev/null; then
  die "no puedo escribir ${STATE} (¿owner/permisos rotos?) — sin offset las alertas de fail2ban no son confiables"
fi

# ---------- 2) Logins SSH con clave no autorizada ----------
# ALLOWED_KEYS e ALLOWED_IPS se leen de .env (validados arriba: nunca vacíos).
while IFS= read -r line; do
  fp=$(echo "$line" | grep -oP 'SHA256:[A-Za-z0-9+/]+' | head -1)
  fp=${fp#SHA256:}   # normalizar: quitar prefijo para comparar con allowlist
  ip=$(echo "$line" | grep -oP 'from \K\S+' | head -1)
  user=$(echo "$line" | grep -oP 'for \K\S+' | head -1)
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
