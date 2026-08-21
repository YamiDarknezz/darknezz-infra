#!/bin/bash
# backup.sh — resiliencia: refresca los backups del block volume.
# La filosofía: la VM es desechable, /home/yami/data sobrevive a la reclamación de Oracle.
# Ejecutar manualmente o vía cron (junto al prune semanal de los domingos).
# Uso: ./scripts/backup.sh
set -euo pipefail

DATA="${HOME}/data"
BK="${DATA}/backups"
REPO="${DATA}/docker"
STAMP="$(date -Is)"
LOG="${BK}/backup.log"
STATUS="${BK}/backup.status"

mkdir -p "${BK}/hermes"

run_backup() {
  echo "=== backup ${STAMP} ==="

  # 1. Certificados Let's Encrypt (traefik los necesita en DR; re-emitibles pero mejor tenerlos)
  cp -p "${REPO}/traefik/acme.json" "${BK}/acme.json"
  echo "  ✓ acme.json (certificados)"

  # 2. Secrets del compose (.env completo: Cloudflare, JWT, Neon, Grafana, DOMAIN)
  cp -p "${REPO}/.env" "${BK}/env.compose.backup"
  echo "  ✓ .env → env.compose.backup"

  # 3. Password del scrape de Prometheus (password_file)
  if [ -f "${DATA}/secrets/traefik-metrics.password" ]; then
    cp -p "${DATA}/secrets/traefik-metrics.password" "${BK}/traefik-metrics.password"
    echo "  ✓ secrets de scraping Prometheus"
  fi

  # 4. Hermes: config + memorias + skills + state.db (sin binarios reinstalables)
  rsync -a --delete \
    --exclude='hermes-agent' --exclude='venvs' --exclude='node' --exclude='bin' \
    --exclude='lsp' --exclude='cache' --exclude='audio_cache' --exclude='image_cache' \
    --exclude='models_dev_cache.json' --exclude='pending_messages' --exclude='state' \
    --exclude='*.lock' --exclude='*.pid' --exclude='logs' \
    "${HOME}/.hermes/" "${BK}/hermes/"
  echo "  ✓ Hermes (config + memorias + skills + state)"

  # 5. Config de sistema del BOOT (crítico para DR: si el boot se pierde,
  #    estos archivos no existen en ningún otro lado)
  SYS="${BK}/system"
  mkdir -p "${SYS}/ssh" "${SYS}/systemd-user"

  # Docker daemon (data-root + log rotation)
  if [ -f /etc/docker/daemon.json ]; then
    cp -p /etc/docker/daemon.json "${SYS}/daemon.json"
    echo "  ✓ /etc/docker/daemon.json"
  fi

  # fail2ban (solo archivos custom: jail.local + filtro traefik + jail.d)
  mkdir -p "${SYS}/fail2ban/filter.d" "${SYS}/fail2ban/jail.d"
  sudo cp -p /etc/fail2ban/jail.local "${SYS}/fail2ban/jail.local" 2>/dev/null && echo "  ✓ fail2ban jail.local"
  sudo cp -p /etc/fail2ban/filter.d/traefik-auth.conf "${SYS}/fail2ban/filter.d/" 2>/dev/null && echo "  ✓ fail2ban filter traefik-auth"
  sudo cp -p /etc/fail2ban/jail.d/*.conf "${SYS}/fail2ban/jail.d/" 2>/dev/null && echo "  ✓ fail2ban jail.d"

  # crontab del usuario (security-alerts, backup, prune)
  crontab -l > "${SYS}/crontab-yami.txt" 2>/dev/null && echo "  ✓ crontab de yami"

  # SSH: clave privada (GitHub) + authorized_keys + config
  cp -p ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub ~/.ssh/authorized_keys "${SYS}/ssh/" 2>/dev/null && echo "  ✓ claves SSH (privada + authorized)"
  [ -d ~/.ssh/deploy ] && cp -r ~/.ssh/deploy "${SYS}/ssh/" 2>/dev/null && echo "  ✓ ~/.ssh/deploy"
  sudo cp -r /etc/ssh/sshd_config /etc/ssh/sshd_config.d "${SYS}/ssh/" 2>/dev/null && echo "  ✓ config sshd"

  # Unit systemd de Hermes (para que vuelva a arrancar sola)
  cp -r ~/.config/systemd/user "${SYS}/systemd-user/" 2>/dev/null && echo "  ✓ hermes-gateway.service"

  # Misc del sistema
  sudo cp /etc/hosts "${SYS}/hosts" 2>/dev/null && echo "  ✓ /etc/hosts"
  sudo cp /etc/hostname "${SYS}/hostname" 2>/dev/null && echo "  ✓ /etc/hostname"

  # los archivos copiados con sudo quedan como root → devolverlos a yami (o el chmod final falla)
  sudo chown -R yami:yami "${SYS}" 2>/dev/null || true
  echo "  ✓ config de sistema (total: $(du -sh "${SYS}" | cut -f1))"

  chmod -R u+rwX,go-rwx "${BK}"
  echo "=== backup OK (total: $(du -sh "${BK}" | cut -f1)) ==="
}

# Ejecutar backup y capturar exito/fallo
if run_backup >> "${LOG}" 2>&1; then
  echo "OK $(date -Is)" > "${STATUS}"
  echo "backup OK — ver ${LOG}"
else
  echo "FAILED $(date -Is)" > "${STATUS}"
  echo "backup FAILED — ver ${LOG}"
  exit 1
fi
