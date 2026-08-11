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

mkdir -p "${BK}/hermes"

{
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

  chmod -R u+rwX,go-rwx "${BK}"
  echo "=== backup OK (total: $(du -sh "${BK}" | cut -f1)) ==="
} >> "${LOG}" 2>&1

echo "backup OK — ver ${LOG}"
