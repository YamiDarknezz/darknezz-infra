# darknezz-infra

**Infrastructure as code** for a self-hosted stack running on **Oracle Cloud (Always Free)** — a Traefik reverse proxy + Docker Compose services deployed to production. Everything is reproducible from this repo: plain YAML, shell scripts and GitHub Actions. No panels, no magic.

## Repository layout

```
darknezz-infra/
├── docker-compose.yml           # Traefik + inventory-api + Prometheus + Grafana
├── .env.example                 # Secrets template (copy to .env, never commit)
├── traefik/
│   ├── traefik.yml              # Main config (entrypoints, metrics, certs)
│   └── dynamic/
│       └── middlewares.yml      # Dashboard BasicAuth
├── services/
│   ├── inventory-api/           # Dockerfile (multi-stage, builds the jar)
│   ├── prometheus/              # prometheus.yml (scrape de traefik)
│   └── grafana/                 # provisioning/ (datasource + dashboard Traefik)
├── configs/
│   └── fail2ban/               # jail.local + filter traefik-auth (templates replicables)
├── scripts/
│   ├── setup.sh                # First boot (network, acme, permissions, up)
│   ├── deploy.sh               # git pull + compose up + optional prune
│   ├── backup.sh               # Weekly: acme.json + .env + secrets + Hermes → data/backups
│   └── setup-fail2ban.sh       # Instala fail2ban desde configs/ (replicable)
└── docs/                        # VPS_SETUP.md + FAIL2BAN.md — SOLO LOCAL en el VPS (gitignored, detalles de infra)
```

## Subdomain convention

One project = one prefixed subdomain under a wildcard DNS record (`*.example.dev` already points to the VM):

| Subdomain | Purpose |
|---|---|
| `www.example.dev` / `api.example.dev` | **Main site** — reserved for the primary project |
| `api-inventory.example.dev` | inventory-api (Spring Boot) |
| `traefik.example.dev` | Traefik dashboard (BasicAuth-protected) |
| `grafana.example.dev` | Grafana dashboards (login propio) |
| `prometheus.example.dev` | Prometheus UI (BasicAuth del dashboard) |
| `zeroclaw.example.dev`, `hermes.example.dev` | Future services (wildcard covers them) |

Rule: every project gets a descriptive prefix (`api-`, `app-`, `ui-`). Generic subdomains stay reserved. The base domain is configurable via the `DOMAIN` variable in `.env`.

## Quick start (on the VM)

```bash
# 1. First-time setup (docker network + acme.json + permissions + bring up)
cd $HOME/data/docker && ./scripts/setup.sh

# 2. Later deploys (update code + rebuild)
./scripts/deploy.sh              # normal
./scripts/deploy.sh --prune      # also prune unused images/volumes

# 3. Backup manual (also runs weekly via cron, Sundays 03:30)
./scripts/backup.sh
```

## Secrets (never in git)

Copy `.env.example` → `.env` with real values:

| Variable | Used for |
|---|---|
| `CLOUDFLARE_TOKEN` | Let's Encrypt dnsChallenge (wildcard cert) |
| `DOMAIN` | Base domain interpolated into Traefik router labels |
| `ACME_EMAIL` | Let's Encrypt account email |
| `DASHBOARD_HASH` | Traefik dashboard BasicAuth (`openssl passwd -apr1`) |
| `JWT_SECRET` | inventory-api JWT signing |
| `DB_URL` / `DB_USER` / `DB_PASSWORD` | PostgreSQL (Neon) |
| `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` | Grafana admin (first login) |

The `.env` lives ONLY on the VM at `$HOME/data/docker/.env` (backed up to `data/backups/env.compose.backup` by `backup.sh`). This repo only has `.env.example` with placeholders. The Prometheus scrape password lives in `$HOME/data/secrets/traefik-metrics.password` (chmod 640, outside the repo).

## Request flow

```
client → DNS (wildcard) → Traefik (80/443)
   → router by Host() from container labels → internal service (proxy network)
   → wildcard TLS via Cloudflare dnsChallenge (acme.json)
```

- `exposedByDefault: false` — nothing is exposed without explicit labels
- Global HTTP→HTTPS redirect on the `web` entrypoint
- Traefik dashboard protected with BasicAuth (users: dashboard + metrics)
- **fail2ban**: 3 jails (sshd, http-traefik sobre el access log JSON, recidive 1 año) — replicable con `./scripts/setup-fail2ban.sh` (config en `configs/fail2ban/`)

## Auto-deploy pipeline

Push to `main` on the application repo → GitHub Actions:

1. **Build** — package the jar
2. **Test** — run the test suite with coverage gates
3. **Deploy** — SSH into the VM: `cd $HOME/data/docker` + `git pull --ff-only origin main` + `docker compose up -d --build` (script con `set -e`)

The exact commit SHA is passed as a Docker build argument (`INVENTORY_SHA`), so Docker's layer cache is invalidated on real code changes and **the exact tested commit is shipped**. Only the changed service is recreated — Traefik keeps serving during updates.

## Monitoring stack

- **Prometheus** — scrapes `https://traefik.${DOMAIN}/metrics` every 30s (BasicAuth via `password_file`), stores in `data/prometheus-data`. UI: `prometheus.${DOMAIN}` (BasicAuth del dashboard).
- **Grafana** — dashboard "Traefik — darknezz.dev" provisionado (requests/s, latencia p50/p95/p99, códigos HTTP, tráfico, conexiones, días de cert TLS). UI: `grafana.${DOMAIN}` (login propio).
- Acceso a las métricas crudas: `https://traefik.${DOMAIN}/metrics` (BasicAuth).

## Backups (el volumen de 150 GB sobrevive a la VM)

| Qué | Dónde | Cómo |
|---|---|---|
| Certs (acme.json) | `data/backups/acme.json` | `backup.sh` (cron dom 03:30) |
| `.env` completo | `data/backups/env.compose.backup` | `backup.sh` |
| Password scrape | `data/backups/traefik-metrics.password` | `backup.sh` |
| Hermes (config+memorias+skills+state) | `data/backups/hermes/` | `backup.sh` |
| Vault de credenciales (DR) | `data/backups/env.credentials.backup` | manual ✍️ |
| Mapa de restauración | `data/backups/README.md` | — |

## Disaster recovery (~15 min)

Si Oracle reclama la VM: el **block volume 150 GB queda intacto**. Para reconstruir:

1. Recrear instancia (2 OCPU/12 GB, Ubuntu 24.04 aarch64, ssh key)
2. **Re-adjuntar el block volume** (consola Oracle → Attach, mismo UUID) → `sudo mount -a` (fstab `nofail`)
3. Clonar: `git clone https://github.com/YamiDarknezz/darknezz-infra $HOME/data/docker`
4. Restaurar desde `data/backups/` (ver `backups/README.md`): `env.compose.backup` → `.env`, `acme.json`, `traefik-metrics.password`, `hermes/` → `~/.hermes/`
5. `./scripts/setup.sh` — red, acme, htpasswd, up
6. Si cambió la IP: actualizar records A en Cloudflare
7. `docker compose ps` + healthchecks

Detalle completo en `docs/VPS_SETUP.md` — **solo local en el VPS** (no está en git: detalla infraestructura real, no debe exponerse).

## Related

- [inventory-api](https://github.com/YamiDarknezz/inventory-api) — the Spring Boot API deployed with this stack
- [playwright-test-automation-demo](https://github.com/YamiDarknezz/playwright-test-automation-demo) — the test suite covering it
