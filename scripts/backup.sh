#!/bin/bash
# backup.sh — resiliencia: refresca los backups del block volume.
# La filosofía: la VM es desechable, /home/yami/data sobrevive a la reclamación de Oracle.
# Ejecutar manualmente o vía cron (junto al prune semanal de los domingos).
# Uso: ./scripts/backup.sh
#
# REGLA DE ORO DE ESTE SCRIPT: un paso crítico NUNCA degrada a warning silencioso.
# Si algo que el DR necesita no se pudo copiar, el run termina en FAILED (exit 1) y
# lista exactamente qué falta. Un kit incompleto que dice "OK" es peor que un error:
# te enterás el día que intentás restaurar.
#
# NOTA docs/: los .md técnicos de infra viven en git (repo público, sanitizados) y el
# clon del paso 2 del README de DR los recupera. NO se copian acá a propósito:
# duplicarlos en el kit crearía dos fuentes de verdad que se desincronizan solas.
set -euo pipefail

DATA="${HOME}/data"
BK="${DATA}/backups"
INFRA="${HOME}/data/repos/darknezz-infra"
STAMP="$(date -Is)"
LOG="${BK}/backup.log"
STATUS="${BK}/backup.status"

# Cargar secrets de .env (POSTGRES_USER/DB alimentan el dump). Sin esto el kit no puede
# respaldar la base: mejor fallar al inicio con un mensaje claro que a mitad del run.
if [ ! -r "${INFRA}/.env" ]; then
  echo "✗ ${INFRA}/.env ilegible — sin secrets no hay backup válido" >&2
  echo "FAILED $(date -Is) (env ilegible)" > "${STATUS}"
  exit 1
fi
source "${INFRA}/.env"

mkdir -p "${BK}/hermes"

FAILS=0
FAILED_STEPS=()

note_fail() {
  echo "  ✗ $1"
  FAILS=$((FAILS + 1))
  FAILED_STEPS+=("$1")
}

# copy_req <etiqueta> <destino> <origen...>
# Copia un origen REQUERIDO para el DR. Intenta como usuario y cae a `sudo -n` cuando el
# archivo es de root (acme.json, /etc/*, crontab). NUNCA degrada a warning: si no puede
# copiar, lo registra y el run termina en FAILED.
copy_req() {
  local label="$1" dst="$2"; shift 2
  local src err
  for src in "$@"; do
    if [ -r "$src" ]; then
      if [ -d "$src" ]; then
        err="$(cp -rp "$src" "$dst" 2>&1)" || { note_fail "${label} — ${src}: ${err:-cp -r falló}"; return 0; }
      else
        err="$(cp -p "$src" "$dst" 2>&1)" || { note_fail "${label} — ${src}: ${err:-cp falló}"; return 0; }
      fi
    else
      if [ -d "$src" ]; then
        err="$(sudo -n cp -rp "$src" "$dst" 2>&1)" || { note_fail "${label} — ${src}: ${err:-sudo cp -r falló}"; return 0; }
      else
        err="$(sudo -n cp -p "$src" "$dst" 2>&1)" || { note_fail "${label} — ${src}: ${err:-sudo cp falló}"; return 0; }
      fi
    fi
  done
  echo "  ✓ ${label}"
}

# rsync_req <etiqueta> <args...>  — tolera rc=24 (archivos que cambian durante la copia,
# normal con state.db/wal vivos) y trata cualquier otro código como fallo.
rsync_req() {
  local label="$1"; shift
  local rc=0
  rsync "$@" || rc=$?
  if [ "$rc" = 0 ]; then
    echo "  ✓ ${label}"
  elif [ "$rc" = 24 ]; then
    echo "  ✓ ${label} (rc=24: archivos modificados durante la copia)"
  else
    note_fail "${label} (rsync rc=${rc})"
  fi
}

run_backup() {
  echo "=== backup ${STAMP} ==="

  # 1. Certificados Let's Encrypt (traefik los necesita en DR; re-emitibles pero mejor tenerlos)
  # El store lo escribe Traefik como root: si no es legible por yami, sudo -n lo rescata.
  if [ -r "${INFRA}/traefik/acme.json" ]; then
    cp -p "${INFRA}/traefik/acme.json" "${BK}/acme.json"
  else
    sudo -n cp -p "${INFRA}/traefik/acme.json" "${BK}/acme.json"
    sudo -n chown "$(id -u):$(id -g)" "${BK}/acme.json"
  fi
  if [ -s "${BK}/acme.json" ]; then
    chmod 600 "${BK}/acme.json"
    echo "  ✓ acme.json (certificados, $(du -h "${BK}/acme.json" | cut -f1))"
  else
    note_fail "acme.json vacío o ilegible — sin certificados no hay TLS en DR"
  fi

  # 2. Secrets del compose (.env completo: Cloudflare, JWT, Grafana, DOMAIN)
  copy_req ".env → env.compose.backup (secrets del compose)" "${BK}/env.compose.backup" "${INFRA}/.env"
  [ -f "${BK}/env.compose.backup" ] && chmod 600 "${BK}/env.compose.backup"

  # 3. Password del scrape de Prometheus (password_file)
  copy_req "secrets de scraping Prometheus" "${BK}/traefik-metrics.password" "${DATA}/secrets/traefik-metrics.password"

  # 4. PostgreSQL dump (backup de la base de datos)
  if docker exec postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; then
    dump_err="$(docker exec postgres pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Fc > "${BK}/postgres-darknezz.dump" 2>&1)" || true
    if [ -s "${BK}/postgres-darknezz.dump" ]; then
      echo "  ✓ PostgreSQL dump (postgres-darknezz.dump, $(du -sh "${BK}/postgres-darknezz.dump" | cut -f1))"
    else
      note_fail "PostgreSQL dump vacío — la base NO quedó respaldada (${dump_err:-pg_dump sin salida})"
    fi
  else
    note_fail "PostgreSQL no responde a pg_isready — dump imposible"
  fi

  # 5. Hermes: config + memorias + skills + state.db (sin binarios reinstalables)
  rsync_req "Hermes (config + memorias + skills + state)" -a --delete \
    --exclude='hermes-agent' --exclude='venvs' --exclude='node' --exclude='bin' \
    --exclude='lsp' --exclude='cache' --exclude='audio_cache' --exclude='image_cache' \
    --exclude='models_dev_cache.json' --exclude='pending_messages' --exclude='state' \
    --exclude='*.lock' --exclude='*.pid' --exclude='logs' \
    "${HOME}/.hermes/" "${BK}/hermes/"

  # 6. Deploys de PROYECTOS: compose + conf.d + .env de cada app.
  # No viven en git (son artefactos del VPS), así que sin esto no se pueden rearmar.
  # Se excluye el subdirectorio dist/ de cada app: es el build, regenerable por CI.
  # Se excluye por POSICIÓN (dist/ dentro de la carpeta del proyecto), no por
  # sufijo del nombre: así la regla no depende de cómo se llame cada carpeta.
  if [ -d "${DATA}/deploy" ]; then
    rsync_req "deploys de proyectos (compose + conf.d + .env, sin dist/)" \
      -a --delete --exclude='*/dist/' "${DATA}/deploy/" "${BK}/deploy/"
  else
    note_fail "${DATA}/deploy no existe — los composes de proyectos no se respaldaron"
  fi

  # 7. Config de sistema del BOOT (crítico para DR)
  SYS="${BK}/system"
  mkdir -p "${SYS}/ssh" "${SYS}/systemd-user"

  # Docker daemon (data-root + log rotation) — ya legible, así que va directo
  copy_req "/etc/docker/daemon.json" "${SYS}/daemon.json" /etc/docker/daemon.json

  # fail2ban (solo archivos custom)
  mkdir -p "${SYS}/fail2ban/filter.d" "${SYS}/fail2ban/jail.d"
  copy_req "fail2ban jail.local" "${SYS}/fail2ban/jail.local" /etc/fail2ban/jail.local
  copy_req "fail2ban filter traefik-auth" "${SYS}/fail2ban/filter.d/" /etc/fail2ban/filter.d/traefik-auth.conf
  copy_req "fail2ban jail.d" "${SYS}/fail2ban/jail.d/" /etc/fail2ban/jail.d/*.conf

  # crontab del usuario (no es un archivo: crontab -l lo vuelca; si falla, es un fallo real)
  crontab -l > "${SYS}/crontab-yami.txt" 2>/dev/null && echo "  ✓ crontab de yami" \
    || note_fail "crontab -l falló — el cron del VPS no quedaría respaldado"

  # SSH: clave privada (GitHub) + authorized_keys + config
  copy_req "claves SSH (privada + authorized)" "${SYS}/ssh/" \
    "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/authorized_keys"
  if [ -d "${HOME}/.ssh/deploy" ]; then
    copy_req "~/.ssh/deploy (llave del CI)" "${SYS}/ssh/" "${HOME}/.ssh/deploy"
  else
    note_fail "~/.ssh/deploy no existe — sin eso el CI no puede re-desplegar tras un DR"
  fi
  copy_req "config sshd" "${SYS}/ssh/" /etc/ssh/sshd_config
  copy_req "config sshd.d" "${SYS}/ssh/" /etc/ssh/sshd_config.d

  # Unit systemd de Hermes
  copy_req "hermes-gateway.service" "${SYS}/systemd-user/" "${HOME}/.config/systemd/user"

  # Misc del sistema
  copy_req "/etc/hosts" "${SYS}/hosts" /etc/hosts
  copy_req "/etc/hostname" "${SYS}/hostname" /etc/hostname

  # devolver ownership (si falla, el chmod del final aborta y el run queda FAILED)
  sudo -n chown -R "$(id -u):$(id -g)" "${SYS}" 2>/dev/null \
    || note_fail "chown de ${SYS} falló (archivos de root en el kit)"
  echo "  ✓ config de sistema (total: $(du -sh "${SYS}" | cut -f1))"

  chmod -R u+rwX,go-rwx "${BK}"

  if [ "${FAILS}" -gt 0 ]; then
    echo "=== backup INCOMPLETO — ${FAILS} paso(s) crítico(s) fallaron: ==="
    for s in "${FAILED_STEPS[@]}"; do echo "    - ${s}"; done
    echo "=== kit INCOMPLETO: no alcanza para un DR hasta arreglar lo de arriba ==="
    return 1
  fi
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
