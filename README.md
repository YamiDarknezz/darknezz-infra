# darknezz-infra

**Infrastructure as code** for a self-hosted stack running on **Oracle Cloud (Always Free)** — a Traefik reverse proxy + Docker Compose services deployed to production. Everything is reproducible from this repo: plain YAML, shell scripts and GitHub Actions. No panels, no magic.

## Repository layout

```
darknezz-infra/
├── docker-compose.yml           # Traefik + PostgreSQL + Prometheus + Grafana
├── .env.example                 # Secrets template (copy to .env, never commit)
├── traefik/
│   ├── traefik.yml              # Main config (entrypoints, metrics, certs)
│   └── dynamic/
│       ├── middlewares.yml      # Rate limiting + BasicAuth
│       └── postgres-ssl.yml     # TCP router for PostgreSQL (port 5432)
├── services/
│   ├── postgres/                # PostgreSQL 18 with SSL (Let's Encrypt)
│   ├── prometheus/              # prometheus.yml (scrape de traefik)
│   └── grafana/                 # provisioning/ (datasource + dashboard Traefik)
├── configs/
│   └── fail2ban/               # jail.local + filter traefik-auth (templates replicables)
├── scripts/
│   ├── setup.sh                # First boot (network, acme, permissions, up)
│   ├── deploy.sh               # git pull + compose up + optional prune
│   ├── backup.sh               # Weekly: acme.json + .env + secrets + Hermes → data/backups
│   └── setup-fail2ban.sh       # Instala fail2ban desde configs/ (replicable)
└── docs/                        # Documentación técnica (POSTGRES_TCP_ROUTING.md, RECOVERY.md, etc.)
```

## Subdomain convention

One project = one prefixed subdomain under a wildcard DNS record (`*.darknezz.dev` already points to the VM):

| Subdomain | Purpose |
|---|---|
| `www.darknezz.dev` | **Main site** — portfolio |
| `postgresql.darknezz.dev` | PostgreSQL 18 (SSL, port 5432) |
| `traefik.darknezz.dev` | Traefik dashboard (BasicAuth-protected) |
| `grafana.darknezz.dev` | Grafana dashboards (login propio) |
| `prometheus.darknezz.dev` | Prometheus UI (BasicAuth del dashboard) |

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
| `JWT_SECRET` | JWT signing (futuros servicios) |
| `POSTGRES_HOST` / `POSTGRES_PORT` | PostgreSQL host and port |
| `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` | PostgreSQL credentials |
| `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` | Grafana admin (first login) |

The `.env` lives ONLY on the VM at `$HOME/data/docker/.env` (backed up to `data/backups/env.compose.backup` by `backup.sh`). This repo only has `.env.example` with placeholders. The Prometheus scrape password lives in `$HOME/data/secrets/traefik-metrics.password` (chmod 640, outside the repo).

## PostgreSQL

PostgreSQL 18 runs as a Docker container with SSL enabled via Let's Encrypt.

### Connection

```bash
# Local connection (from VPS)
PGPASSWORD=<password> psql -h 127.0.0.1 -p 5432 -U yamidarknezz -d darknezz

# Remote connection (via domain)
PGPASSWORD=<password> psql -h postgresql.darknezz.dev -p 5432 -U yamidarknezz -d darknezz
```

### SSL Configuration

- Certificates: Let's Encrypt via certbot + Cloudflare DNS
- Domain: `postgresql.darknezz.dev`
- Expiry: Auto-renewed via cron (daily check)
- Renewal script: `/etc/dokploy/renew-postgres-cert.sh`

### Backup

PostgreSQL data is stored in `/home/yami/data/volumes/postgres/data` and backed up via `backup.sh`.

## Request flow

```
client → DNS (wildcard) → Traefik (80/443)
   → router by Host() from container labels → internal service (proxy network)
   → wildcard TLS via Cloudflare dnsChallenge (acme.json)

PostgreSQL:
client → DNS (postgresql.darknezz.dev) → Traefik (5432, TCP passthrough)
   → HostSNI routing → PostgreSQL (SSL termination at PG level)
```
