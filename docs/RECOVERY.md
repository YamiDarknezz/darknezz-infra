# 🔄 RECOVERY — Plan de reconstrucción total (DR)

> Escenario: el boot volume (45GB) se pierde por completo. Solo sobrevive el
> block volume de 150GB montado en `/home/yami/data`. Todo lo necesario para
> reconstruir vive ahí — este documento es el procedimiento.

## Qué se recupera desde data/ (verificado con drill 2026-08-11)

| Componente | Ubicación en data/ | Estado |
|---|---|---|
| Repo docker (compose, configs, scripts) | `docker/` (git) | ✅ completo |
| Certificados TLS (4 dominios + cuenta LE) | `backups/acme.json` | ✅ 4 certs |
| Secrets del compose (.env: Cloudflare, JWT, DB, Grafana) | `backups/env.compose.backup` | ✅ 12 vars |
| Token Telegram + config Hermes | `backups/hermes/.env` | ✅ |
| Claves SSH (privada GitHub + CI deploy) | `backups/system/ssh/` | ✅ PEM válidas |
| Config Docker (daemon.json: data-root + log rot) | `backups/system/daemon.json` | ✅ |
| fail2ban (jail.local + filtro traefik) | `backups/system/fail2ban/` | ✅ |
| Crontab (security-alerts, backup, prune) | `backups/system/crontab-yami.txt` | ✅ |
| Unit systemd de Hermes | `backups/system/systemd-user/` | ✅ |
| Config SSH (sshd + hardening) | `backups/system/ssh/sshd_config*` | ✅ |
| Datos de servicios (Prometheus, Grafana, Alertmanager) | `*-data/` en data | ✅ |
| **Imágenes Docker (~4.7GB)** | `docker-data/` + `containerd/` | ✅ en volumen |

## Plan de reconstrucción (orden)

### 1. Recrear la VM en Oracle Cloud
- Misma región/AD que el volumen (o attach cross-AD si aplica)
- Ubuntu 24.04, Ampere A1 (2 OCPU / 11GB como mínimo)
- Boot 45GB + **attach del block volume 150GB existente** (NO formatear)
- Montar: `sudo mkdir -p /home/yami/data && sudo mount /dev/sdb /home/yami/data`
- Persistir en fstab (UUID: `sudo blkid /dev/sdb`)

### 2. Usuario + acceso
```bash
sudo adduser yami && sudo usermod -aG sudo yami
# restaurar authorized_keys (la de tu laptop/phone):
sudo mkdir -p /home/yami/.ssh && sudo cp /home/yami/data/backups/system/ssh/authorized_keys /home/yami/.ssh/
sudo chown -R yami:yami /home/yami/.ssh && sudo chmod 700 /home/yami/.ssh && sudo chmod 600 /home/yami/.ssh/authorized_keys
```

### 3. Docker + dependencias
```bash
# instalar Docker Engine (docs oficiales), docker compose plugin, fail2ban:
sudo apt-get update && sudo apt-get install -y fail2ban
# daemon.json (data-root apunta al volumen — las imágenes ya están ahí):
sudo cp /home/yami/data/backups/system/daemon.json /etc/docker/daemon.json
# containerd ya apunta a /home/yami/data/containerd via config.toml — reinstalar config si aplica
sudo systemctl restart docker
# verificar que las imágenes aparecen: docker images
```

### 4. Restaurar configs del sistema
```bash
SYS=/home/yami/data/backups/system
sudo cp -r $SYS/fail2ban/* /etc/fail2ban/ && sudo systemctl enable --now fail2ban
sudo cp $SYS/ssh/sshd_config /etc/ssh/sshd_config
sudo cp -r $SYS/ssh/sshd_config.d/* /etc/ssh/sshd_config.d/
sudo cp $SYS/hostname /etc/hostname && sudo cp $SYS/hosts /etc/hosts
# claves SSH (para git/gh como YamiDarknezz):
mkdir -p ~/.ssh && cp $SYS/ssh/id_ed25519* ~/.ssh/ && chmod 600 ~/.ssh/id_ed25519
# crontab:
crontab $SYS/crontab-yami.txt
# red docker:
docker network create proxy
```

### 5. Hermes (el gateway de Telegram)
```bash
# restaurar config/estado/skills (sin binarios — reinstalables):
rsync -a /home/yami/data/backups/hermes/ ~/.hermes/
# reinstalar binarios: ver doc oficial de Hermes (hermes-agent + venv + node)
# TTS local Piper (obligatorio si el config tiene tts.provider=piper):
uv pip install --python ~/.hermes/hermes-agent/venv/bin/python piper-tts
#   las voces .onnx se re-descargan solas al primer uso (en ~/.hermes/cache/piper-voices/)
# restaurar unit systemd:
mkdir -p ~/.config/systemd/user && cp -r $SYS/systemd-user/user/* ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now hermes-gateway
sudo loginctl enable-linger yami
```

### 6. Deploy del stack
```bash
cd /home/yami/data/repos/darknezz-infra
git remote set-url origin git@github.com:YamiDarknezz/darknezz-infra.git  # si hace falta
./scripts/setup-fail2ban.sh        # idempotente
./scripts/gen-alertmanager-config.sh  # regenera config con token
INVENTORY_SHA=main ./scripts/deploy.sh
```

### 6b. Deploys de los proyectos (portfolio, angular-canvas)
Los `docker-compose.yml` + `conf.d/` + `.env` de cada app **no viven en git**: restáuralos del backup.
```bash
cp -a /home/yami/data/backups/deploy/. /home/yami/data/deploy/
cd /home/yami/data/deploy/portfolio      && docker compose up -d
cd /home/yami/data/deploy/angular-canvas && docker compose up -d
```
El subdirectorio `dist/` de cada app NO se respalda: lo regenera el CI del repo con un push (o `gh workflow run ci.yml` en ese repo). Los GitHub Secrets no los devuelve GitHub: re-crear `DEPLOY_KEY` desde `backups/system/ssh/deploy/ci_deploy` y los otros dos desde el vault.

### 7. Verificación post-DR
- `docker ps` → 7 contenedores healthy (traefik, portfolio, postgres, prometheus, grafana, alertmanager, node-exporter)
- `docker exec traefik wget -qO- http://localhost:8080/ping` → OK
- https://darknezz.dev responde (certs restaurados de acme.json, sin re-emitir)
- `docker inspect portfolio` → healthy; curl https://darknezz.dev con el bundle de Angular correcto (grep un hash del build)
- Enviar alerta de prueba a Telegram (POST /api/v2/alerts a Alertmanager)
- `sudo fail2ban-client status` → 3 jails activas
- Hermes responde en Telegram

---

## 🐛 Lecciones aprendidas / bugs conocidos (evitar al reconstruir)

1. **Alertmanager storage**: el contenedor corre como `nobody` (uid 65534) — `data/alertmanager-data` debe ser de 65534 o el maintenance falla cada 15 min. Ya automatizado en `gen-alertmanager-config.sh`.
2. **Alertmanager no expande `${VAR}` en campos numéricos** (chat_id): el token se inyecta con `envsubst` a `data/secrets/alertmanager.yml` (dir 700, archivo 644). Nunca hardcodear el token en git (repo público).
3. **Traefik v3.7**: el ping NO va bajo `api:` (error "field not found") — es bloque raíz `ping: {}` y se sirve en el entrypoint `traefik:8080` (no exponer al host).
4. **Comparación de fingerprints SSH**: normalizar quitando el prefijo `SHA256:` (falso positivo en security-alerts.sh). Allowlist de IPs es solo un silenciador; la clave es la autoridad.
5. **Backup con sudo**: los archivos copiados con `sudo cp` quedan como root y rompen el `chmod` final (set -e aborta) — hacer `sudo chown yami:yami` tras copiar.
6. **Hairpin NAT de Oracle**: desde el VPS no se puede acceder a la IP pública propia (curl da HTTP 000) — usar `Host:` header contra la IP interna del contenedor para probar.
7. **Labels de Traefik**: tras cambiar labels en compose hay que RECREAR el contenedor (`docker compose up -d <svc>`) — solo traefik se auto-recarga.
8. **acme.json**: nunca tocar permisos (600); el backup es `cp -p`. Verificar estructura: `d['letsencrypt']['Certificates']`.
9. **docker compose up -d** puede ser detectado como proceso long-lived por el agente — usar background si aplica.
10. **Rate limits**: paneles 30/s·burst60 (ratelimit-http), API pública 10/s·burst30 (ratelimit-api) — ajustar solo si hay quejas reales.
11. **nginx portfolio**: la imagen nginx:alpine trae `default.conf` propio que GANA por orden alfabético — montar `/dev/null:/etc/nginx/conf.d/default.conf` para neutralizarlo; `listen [::]:80` necesario o el healthcheck por `localhost` falla (resuelve a ::1) y el contenedor queda unhealthy (Traefik deja de enrutar). Healthcheck explícito `wget http://127.0.0.1/`.

## Estado del stack (2026-08-16)
traefik v3.7.10 · prometheus v3.13.2 · grafana 13.1.3 · alertmanager v0.33.1 · node-exporter v1.9.1 · PostgreSQL 18 · **portfolio** nginx:1.27-alpine (DarknezzDev, darknezz.dev)
Redes: `proxy` (external) · Alertas: Telegram al DM (chat 5069336124) · fail2ban: sshd + http-traefik + recidive
