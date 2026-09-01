# 🖥️ VPS Darknezz — Setup completo y progreso

Documentación viva de todo lo configurado en el VPS de Oracle Cloud **`darknezz`** (<VPS_IP>). Actualizado: 2026-08-10 (rev 2 — volumen 150 GB, Hermes, purga automática).

> **Objetivo**: que cualquier persona (o tú mismo en 6 meses) pueda recrear o entender TODA la infraestructura leyendo este archivo + el repo.

> 📎 **Docs relacionados (todos en `docs/`, solo local):** [`FAIL2BAN.md`](FAIL2BAN.md) — política de baneo completa, filtro de Traefik y lecciones. El resto del stack está documentado en el README del repo.

---

## 1. 📋 Resumen ejecutivo

| Pieza | Valor |
|---|---|
| Proveedor | Oracle Cloud **Always Free** (cuenta PAYG) |
| Región | `sa-santiago-1` (Santiago, Chile) — la más cercana a Perú |
| Shape | `VM.Standard.A1.Flex` — **2 OCPU / 12 GB RAM** (máx. Always Free) |
| Disco | Boot volume 46.6 GB + **Block volume 150 GB montado** (pool Always Free: 200 GB) |
| SO | Ubuntu 24.04.4 LTS (aarch64) |
| Hostname | `darknezz` |
| Usuario | `<USER>` (el default `ubuntu` fue **eliminado**) |
| IP pública | `<VPS_IP>` |
| Dominio | `darknezz.dev` (DNS en Cloudflare) — wildcard `*.darknezz.dev` → IP |
| Servicios | Traefik (proxy) + PostgreSQL + Hermes (agente IA) |

## 1b. 🧠 Filosofía de arquitectura (por qué está así)

1. **La VM es desechable**: si Oracle la reclama, se recrea en ~15 min (sección 12). Nada importante vive solo en ella
2. **Datos afuera**: Neon (DB), Cloudflare (DNS), GitHub (código) — sobreviven a todo
3. **Infra como código**: `darknezz-infra` = compose + scripts + docs; el VPS solo ejecuta el repo
4. **Espacio separado por riesgo**: disco sistema (apps, 45 GB, reclamable) vs **volumen data** (datos, 150 GB, inmune a reclamación)
5. **Un solo punto de entrada**: Traefik reparte por subdominios; los contenedores internos no publican puertos

### Mapa del servidor

```
Internet → Cloudflare DNS (*.darknezz.dev) → <VPS_IP>
        → TRAEFIK (único con 80/443, red interna "proxy")
            ├── traefik.darknezz.dev        → dashboard (BasicAuth)
            └── (futuro) vault./hermes./zeroclaw. → sus contenedores

/home/<USER>/
├── docker/                  ← SYMLINK → data/repos/darknezz-infra (repo infra)
├── data/                    ← 📦 VOLUMEN 150 GB (sobrevive a la reclamación de la VM)
│   ├── docker/              ← repo darknezz-infra (compose, traefik/, .env, services/)
│   ├── docker-data/         ← data-root del engine Docker (/etc/docker/daemon.json)
│   ├── containerd/          ← imágenes Docker (/etc/containerd/config.toml → root)
│   ├── prometheus-data/     ← TSDB de Prometheus
│   ├── grafana-data/        ← DB de Grafana (dashboards, usuarios)
│   ├── secrets/             ← password_file de Prometheus (chmod 640 yami:nogroup)
│   └── backups/             ← acme.json + .env + hermes + vault (ver backups/README.md)
└── .hermes/                 ← 🧠 Hermes Agent (boot volume; respaldado en data/backups/hermes)
```

### Dónde vive cada dato (supervivencia)

| Dato | Lugar | Sobrevive si la VM muere |
|---|---|---|
| Código (API, infra) | GitHub (darknezz-infra) | ✅ |
| Base de datos | Neon (serverless, fuera de la VM) | ✅ |
| DNS + certificados | Cloudflare + acme.json (backup en data/backups) | ✅ |
| Secrets | `.env` VPS + copia en data/backups + gestor | ✅ |
| Métricas monitoreo | data/prometheus-data + data/grafana-data | ✅ (reenviado en data) |
| Hermes | ~/.hermes (boot) + respaldo data/backups/hermes | ✅ (respaldo en data) |

---

## 2. 🔑 Acceso SSH

### Config local (`~/.ssh/config`)

```
Host oracle
    HostName <VPS_IP>
    User <USER>
    IdentityFile ~/.ssh/oracle_<USER>
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

- Llave: `~/.ssh/oracle_<USER>` (ed25519) — generada para `<USER>`
- Llave obsoleta: `oracle_vm` (era de `ubuntu`) — **borrada**
- Acceso: **solo llave** (PasswordAuthentication no)

### Conectar

```bash
ssh oracle
```

---

## 3. 🛡️ Hardening aplicado

| Medida | Detalle |
|---|---|
| SSH solo-llave | `/etc/ssh/sshd_config.d/60-hardening.conf`: `PasswordAuthentication no`, `MaxAuthTries 3`, `PermitRootLogin prohibit-password` |
| UFW | Solo `22/tcp` y `443/tcp` (el 80 también se puede cerrar si el redirect global no se usa; se dejó para http→https) |
| fail2ban | 3 jails: `sshd` + `http-traefik` (filtro sobre access log JSON) + `recidive` (1 año). Detalle completo en [FAIL2BAN.md](FAIL2BAN.md) — replicable vía `./scripts/setup-fail2ban.sh` |
| Swap | 4 GB (`/swapfile`, persistente en fstab) |
| unattended-upgrades | Parches de seguridad automáticos, activo |
| Usuario | `<USER>` con sudo NOPASSWD (`/etc/sudoers.d/<USER>`) y grupos `sudo,adm,docker` |
| Docker | `docker` sin sudo (grupo `docker`) |
| fail2ban + UFW | Ambos activos y verificados post-eliminación de `ubuntu` |

---

## 4. 🌐 Cloudflare (DNS + certificados)

- **Zona**: `darknezz.dev` (ID `b4ed0c8f235d8088a3f7b82e21480e19`)
- **API Token**: `Edit zone DNS` para `darknezz.dev` (guardado en el `.env` del VPS) — se usa para el `dnsChallenge` de Let's Encrypt
- **Records A** (DNS only, proxied=false):
  - `@` → `<VPS_IP>`
  - `*` → `<VPS_IP>` (wildcard: cualquier subdominio apunta al VPS)
- **Records existentes que NO se tocan**: MX (route1/2/3), TXT DKIM, TXT SPF (Email Routing)

### Convención de subdominios

| Subdominio | Uso |
|---|---|
| `www.darknezz.dev` / `api.darknezz.dev` | **Solo la marca** (reservados, NO usar para proyectos) |
| `traefik.darknezz.dev` | Dashboard Traefik (BasicAuth) |
| `zeroclaw.*`, `hermes.*` | Futuros proyectos (wildcard ya cubre) |

Regla: **1 proyecto = 1 subdominio con prefijo descriptivo** (`api-`, `app-`, `ui-`).

---

## 5. 🔀 Traefik

### Estructura de archivos (bind mounts al contenedor)

```
/home/<USER>/docker/
├── docker-compose.yml          # Traefik + services (labels)
├── .env                        # SECRETS (nunca en git) — chmod 600
├── traefik/
│   ├── traefik.yml             # config principal
│   ├── acme.json               # certificados Let's Encrypt (chmod 600)
│   └── dynamic/
│       ├── middlewares.yml     # BasicAuth del dashboard (usersFile .htpasswd)
│       └── .htpasswd           # user:hash del dashboard (generado por setup.sh)
```

### Config principal (`traefik.yml`) — decisiones

- **entryPoints**: `web :80` (redirect→https permanente, global en entryPoint) + `websecure :443` con **`certResolver: letsencrypt` a nivel de entryPoint** (patrón Pauser — así TODOS los routers websecure tienen TLS automático, incluido el dashboard)
- **providers**: `docker` (`exposedByDefault: false`, red `proxy`) + `file` (`/dynamic`)
- **certificatesResolvers**: `letsencrypt` con `dnsChallenge: cloudflare` (cert wildcard) — usa `CF_DNS_API_TOKEN` del `.env`
- **Red docker**: `proxy` (externa, creada con `docker network create proxy`)

### Exposición de servicios (labels en compose)

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.api.rule=Host(`api-inventory.darknezz.dev`)"
  - "traefik.http.routers.api.entrypoints=websecure"
  - "traefik.http.routers.api.tls.certresolver=letsencrypt"   # opcional (ya es global)
  - "traefik.http.services.api.loadbalancer.server.port=8080"
```

Dashboard: `traefik.darknezz.dev` → `api@internal` + middleware `dashboard-auth` (BasicAuth con `.htpasswd`).

---

## 6. 🐳 Servicios Docker (estado 2026-08-10)

| Contenedor | Imagen | Estado | Notas |
|---|---|---|---|
| `traefik` | `traefik:latest` | Up | Único punto de entrada 80/443. **No usar `v3.5`** (incompatible con Docker 29: API 1.24 vs mín. 1.40). Métricas Prometheus en `/metrics` (basicauth) |
| `prometheus` | `prom/prometheus` | Up | Scrapea traefik.${DOMAIN}/metrics con password_file en data/secrets/ |
| `grafana` | `grafana/grafana` | Up | Dashboard Traefik provisionado (services/grafana/provisioning/) |

### Uso de recursos

- Disco: 7.0 GB / 45 GB (16%) — 2.7 GB recuperados con prune
- RAM: ~620 MB de 11 GB (Java 348 MB, dockerd 175 MB, traefik 94 MB)
- Swap: 0 usado

---

## 6b. 🤖 Hermes (agente IA de Telegram) + TTS local Piper

**Hermes NO corre en Docker** — es un servicio systemd de usuario (`hermes-gateway.service`, linger activado). Restaurar: ver `RECOVERY.md` paso 5.

### TTS local Piper (desde 2026-08-14)

El TTS de Hermes usa **Piper** (motor neuronal VITS 100% local, sin API keys ni servicios externos):

- Paquete: `piper-tts` instalado en el venv de Hermes:
  `uv pip install --python ~/.hermes/hermes-agent/venv/bin/python piper-tts`
- Config en `~/.hermes/config.yaml`:
  ```yaml
  tts:
    use_gateway: false
    provider: piper
    piper:
      voice: es_ES-davefx-medium
  ```
- Voces descargadas (auto-download en primer uso, ~60 MB c/u) en `~/.hermes/cache/piper-voices/`:
  - `es_ES-davefx-medium` ← **única voz instalada (las demás se purgaron 2026-08-14; se re-descargan solas si se necesitan)**
- Catálogo completo de voces: `https://huggingface.co/rhasspy/piper-voices/tree/main` (44 idiomas)
- ⚠️ La voz se configura en `tts.piper.voice` (NO `tts.voice` — esa clave no la lee el tool)
- Prueba rápida: generar un audio desde Telegram y verificar que aparece el archivo .ogg en `~/.hermes/cache/audio/`

### STT (transcripción de audios que manda Gerardo)

- `stt.language: es` (corregido 2026-08-14 — estaba forzado a `en`, por eso los audios en español se transcribían como inglés)
- Provider local: faster-whisper `base`; fallback OpenAI whisper-1
- Si un audio se transcribe mal: verificar `hermes config get stt.language` (debe ser `es`)

### Voice cloning (opción futura, NO implementada)

- Gerardo decidió no clonar su voz por ahora. Propuesta documentada (XTTS v2, pasos, alternativas): `/home/yami/data/proyectos/voice-cloning/README.md`

---

## 7. 🗄️ Neon (PostgreSQL serverless)

- Proyecto: `inventory` (región us-east-2)
- Bases: `inventory` (la API) + `neondb` (sandbox para testeos/futuros proyectos)
- Conexión: **pooler** (`...-pooler.c-4.us-east-2.aws.neon.tech`) con `sslmode=require`
- **LEARNED (bug resuelto)**: el driver JDBC de Postgres **no parsea bien credenciales embebidas** `user:pass@host` en la URL cuando el host tiene el formato de Neon → usar `DB_USER`/`DB_PASSWORD` separados + URL sin credenciales. También el prefijo debe ser `jdbc:postgresql://` (no `postgresql://`).
- Datos: admin de producción creado en `users` (ver abajo)

---

## 8. 🚀 Pipeline de deploy automático (GitHub Actions)

**Repos involucrados**:
- `inventory-api` — contiene el workflow `ci.yml` con el job Deploy
- `darknezz-infra` — el compose + scripts que se ejecutan en el VPS

**Flujo**: push a `main` de inventory-api → Build (`mvnw package`) → Test (`mvnw verify` con gates JaCoCo ≥90% líneas / ≥70% ramas) → **Deploy** (SSH con `appleboy/ssh-action` + secret `DEPLOY_KEY`):

```
cd $HOME/data/docker
git pull --ff-only origin main
INVENTORY_SHA=$INVENTORY_SHA ./scripts/deploy.sh
```

> ⚠️ El script del CI lleva `set -e` y usa `git pull --ff-only origin main` explícito (el tracking de upstream no está configurado en el VPS). Lección aprendida 2026-08-10: sin esto, los deploys fallaban **en silencio** (git pull sin tracking fallaba → deploy.sh abortaba → el job quedaba verde igual).


**Anti-cache (crítico)**: el Dockerfile usa `ARG INVENTORY_SHA` + `git fetch --depth 1 origin <sha>` + `checkout FETCH_HEAD` — así cada deploy garantiza el código EXACTO testeado (Docker no cachea por contenido remoto). El SHA lo pasa el workflow con `envs: INVENTORY_SHA` + `${{ github.sha }}`.

**Scripts**:
- `setup.sh` — primer boot: red `proxy`, `acme.json` (600), valida `.env`, genera `.htpasswd` del dashboard (reemplaza `$$`→`$`), `up -d --build`
- `deploy.sh [--prune]` — git pull + up --build (+ prune opcional, patrón Pauser)

---

## 9. 🔐 Secretos — DÓNDE están (nunca escribir valores aquí)

| Secreto | Ubicación |
|---|---|
| `CF_DNS_API_TOKEN` | `/home/<USER>/data/docker/.env` (VPS) |
| `DASHBOARD_HASH` (user `<USER>darknezz`) | `/home/<USER>/data/docker/.env` + `traefik/dynamic/.htpasswd` (VPS) |
| `JWT_SECRET` | `/home/<USER>/data/docker/.env` (VPS) |
| `DB_URL` / `DB_USER` / `DB_PASSWORD` | `/home/<USER>/data/docker/.env` (VPS) |
| `GRAFANA_ADMIN_PASSWORD` | `.env` (VPS) + vault backups/env.credentials.backup |
| Password scrape Prometheus | `/home/<USER>/data/secrets/traefik-metrics.password` (chmod 640 yami:nogroup) |
| Credenciales admin de la API | Gestor de contraseñas personal (fuera del repo) |
| Credenciales Neon | Panel de Neon (console.neon.tech) |

> Los valores reales **no van en este repo**. `.env` y `.htpasswd` están en `.gitignore`.

---

## 10. 🧪 Verificación (checklist post-setup)

```bash
ssh oracle                              # acceso
sudo -n true                            # sudo sin password
docker ps                               # 2 contenedores Up
docker compose -f /home/<USER>/docker/docker-compose.yml ps
curl https://api-inventory.darknezz.dev/actuator/health   # {"status":"UP"}
curl https://api-inventory.darknezz.dev/swagger-ui.html   # 200
curl https://traefik.darknezz.dev/dashboard/ -k           # 404 sin auth / 200 con BasicAuth
```

---

## 11. ⏳ Pendientes / historial de decisiones

### Pendientes
- [ ] **Keepalive anti-reclamación Oracle** — investigación: p95 < 20% CPU/red/memoria por 7 días = reclamación. Un cron de pings NO mueve el p95 (0.03% del tiempo). Opciones evaluadas: Uptime Kuma (red), UptimeRobot externo, job con carga real, o aceptar riesgo + setup reproducible
- [ ] **Uptime Kuma** — monitoreo (diferido por decisión del usuario)
- [ ] **ZeroClaw** (Rust, <10 MB) — subdominio wildcard ya listo
- [ ] **Vaultwarden / FileBrowser / code-server** — evaluados como útiles (ver `../README.md` y cortex Docker), NO instalados aún. Prioridad: Vaultwarden (gestor de contraseñas self-hosted)
- [ ] **Hermes: configurar API key + provider** — instalado (v0.20.0) pero sin `hermes setup` aún (interactivo, requiere key de OpenRouter/Nous Portal/OpenAI). Guía en cortex `10_Projects/Hermes_Agent/`
- [ ] **`hermes gateway`** — opcional (daemon permanente ~100-200 MB RAM; decidir si se quiere 24/7)

### Hecho (historial reciente)
- [x] **2026-08-10 — Migración total al block volume**: Docker data-root → `data/docker-data` (daemon.json), containerd → `data/containerd` (config.toml root), repo infra → `data/repos/darknezz-infra` (symlink `/home/<USER>/docker`). Docker 29 usa containerd image store: mover solo data-root NO mueve imágenes
- [x] **2026-08-10 — Fix deploy silencioso**: el repo no tenía upstream tracking → `git pull` fallaba → deploy.sh abortaba → CI verde sin desplegar. Fix: `git pull --ff-only origin main` + `set -e` en el script del CI
- [x] **2026-08-10 — Monitoreo**: Traefik metrics Prometheus (`prometheus@internal` + `manualRouting`, basicauth) + Prometheus + Grafana (`grafana.${DOMAIN}` / `prometheus.${DOMAIN}`), dashboard Traefik provisionado
- [x] **2026-08-10 — fail2ban**: jail `http-traefik` (filtro traefik-auth sobre access.log JSON en /var/log/traefik) + recidive; bantime incremental
- [x] **2026-08-10 — Backups automáticos**: `scripts/backup.sh` (acme.json + .env + secrets + Hermes) en cron semanal; `backups/README.md` con el mapa de restauración
- [x] **Block volume 150 GB** (`data-extra`, Always Free, AD-1) creado + attachado (PARAVIRTUALIZED) + formateado ext4 + montado en `/home/<USER>/data` + fstab por UUID (`nofail`) — sobrevive a la reclamación de la VM
- [x] **Backups en `/home/<USER>/data/backups/`**: `acme.json` (certs) + `env.credentials.backup` (secrets). Backup de Neon **retirado** (DB demo vacía, innecesario)
- [x] **Crontab (solo purga semanal)**: domingos 03:30 — `journalctl --vacuum-time=7d` + `.gz` viejos + `docker system prune -f`
- [x] **Hermes Agent v0.20.0** instalado (curl install.sh oficial de NousResearch — revisado antes de ejecutar). Disco: 2.2 GB (`~/.hermes`). RAM: 0 en idle (on-demand)
- [x] **Limpieza Docker**: imagen `postgres:18` (671 MB, residuo del backup retirado) eliminada. Imágenes actuales: inventory-api (649 MB) + traefik (229 MB) — 0% reclamable
- [x] **Purga manual**: 13 GB → 12 GB (29% → 27%)

### Decisiones clave (por qué)
- **Sin Dokploy**: infra como código manual (compose + labels + SSH) — más ligero, control total, mismo patrón que Pauser pero sin panel
- **Traefik `latest` no `v3.5`**: incompatibilidad Docker 29 (API client 1.24 vs mín. 1.40)
- **certResolver global en entryPoint websecure**: patrón Pauser, da TLS a todos los routers incl. dashboard
- **`.htpasswd` en `traefik/dynamic/`**: bind mount `:ro` no permite crear archivos dentro; el archivo vive en la carpeta montada y `setup.sh` lo genera
- **`ubuntu` eliminado**: seguridad (usuario default conocido); `<USER>` es el único
- **MySQL/Postgres NO en el VPS**: Neon serverless es suficiente y siempre-free

---

## 12. 🚨 Disaster recovery (si la VM desaparece)

1. **Recrear instancia** (2 OCPU/12 GB, Ubuntu 24.04 aarch64, ssh key `oracle_<USER>`)
2. `ssh-keygen` si se perdió; `ssh oracle` actualizar IP en `~/.ssh/config`
3. **Re-adjuntar el block volume 150 GB** (consola Oracle: instancia → Attach block volume, mismo UUID) — monta solo con `sudo mount -a` (fstab `nofail` por UUID)
4. Clonar: `git clone https://github.com/YamiDarknezz/darknezz-infra /home/<USER>/data/docker`
5. Restaurar secrets desde `data/backups/` (ver `backups/README.md`): `env.compose.backup` → `.env`, `acme.json`, `traefik-metrics.password`, `hermes/` → `~/.hermes/`
6. `./scripts/setup.sh` — red, acme, htpasswd, up
7. Re-verificar DNS (wildcard ya apunta; si la IP cambió, actualizar records A en Cloudflare)
8. `docker compose ps` + healthcheck (incluye prometheus + grafana)

**Tiempo estimado de recuperación: ~15 min.** Los datos NO se pierden: Neon (DB), Cloudflare (DNS), GitHub (código + workflow). Solo los certificados se re-emiten solos (dnsChallenge).
