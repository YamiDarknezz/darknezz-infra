# darknezz-infra

**Infrastructure as code** for a self-hosted stack running on **Oracle Cloud (Always Free)** — a Traefik reverse proxy + Docker Compose services deployed to production. Everything is reproducible from this repo: plain YAML, shell scripts and GitHub Actions. No panels, no magic.

## Repository layout

```
darknezz-infra/
├── docker-compose.yml           # Traefik + Prometheus + Grafana + AlertManager + Dozzle
├── .env.example                 # Secrets template (copy to .env, never commit)
├── traefik/
│   ├── traefik.yml              # Main config (entrypoints, metrics, certs)
│   └── dynamic/
│       ├── middlewares.yml      # Rate limiting + BasicAuth
│       └── postgres-ssl.yml     # TCP router for PostgreSQL (port 5432)
├── services/
│   ├── postgres/                # PostgreSQL 18 with SSL (Let's Encrypt)
│   ├── prometheus/              # prometheus.yml (scrape de traefik)
│   ├── grafana/                 # provisioning/ (datasource + dashboard Traefik)
│   └── alertmanager/            # (config via secrets/)
├── configs/
│   └── fail2ban/               # jail.local + filter traefik-auth (templates replicables)
├── scripts/
│   ├── setup.sh                # First boot (network, acme, permissions, up)
│   ├── deploy.sh               # git pull + compose up + optional prune
│   ├── backup.sh               # Weekly: acme.json + .env + secrets + Hermes → data/backups
│   └── setup-fail2ban.sh       # Instala fail2ban desde configs/ (replicable)
└── docs/                        # Documentación técnica (VPS_SETUP.md, POSTGRES_TCP_ROUTING.md, etc.)
```

> **Proyectos y Servicios Desplegados (CI/CD)**:
> Proyectos como Impresos Trujillo, ERP Base y Portfolio se gestionan en sus propios repositorios y se despliegan automáticamente al VPS.
> Toda la arquitectura, separación de carpetas (`repos/`, `deploy/`, `volumes/`), redes de Traefik y flujos de GitHub Actions están detallados en [**`docs/CI_CD_DEPLOYMENTS.md`**](docs/CI_CD_DEPLOYMENTS.md).

## Subdomain convention

| Subdomain | Purpose |
|---|---|
| `darknezz.dev` | Portfolio (DarknezzDev) |
| `api-inventory.darknezz.dev` | inventory-api (dado de baja / solo demo local) |
| `postgresql.darknezz.dev` | PostgreSQL 18 (SSL, port 5432) |
| `traefik.darknezz.dev` | Traefik dashboard (BasicAuth-protected) |
| `grafana.darknezz.dev` | Grafana dashboards (en pausa por recursos - ver [MONITORING_STACK.md](docs/MONITORING_STACK.md)) |
| `prometheus.darknezz.dev` | Prometheus UI (en pausa por recursos - ver [MONITORING_STACK.md](docs/MONITORING_STACK.md)) |
| `dozzle.darknezz.dev` | Dozzle container logs (login propio) |

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
| `POSTGRES_HOST` / `POSTGRES_PORT` | PostgreSQL host and port |
| `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` | PostgreSQL credentials |
| `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` | Grafana admin (first login) |
| `DOZZLE_AUTH_PROVIDER` | `simple` enables Dozzle's own login |
| `DOZZLE_AUTH_TTL` | Session lifetime (`session` or a duration) |
| `DOZZLE_HOSTNAME` | Label shown in the Dozzle header |

The `.env` lives ONLY on the VM at `$HOME/data/docker/.env` (backed up to `data/backups/env.compose.backup` by `backup.sh`). This repo only has `.env.example` with placeholders.

## PostgreSQL

PostgreSQL 18 runs as a Docker container with SSL enabled via Let's Encrypt.

### Connection

```bash
# Local connection (from VPS)
PGPASSWORD=$POSTGRES_PASSWORD psql -h 127.0.0.1 -p 5432 -U $POSTGRES_USER -d $POSTGRES_DB

# Remote connection (via domain)
PGPASSWORD=$POSTGRES_PASSWORD psql -h postgresql.darknezz.dev -p 5432 -U $POSTGRES_USER -d $POSTGRES_DB
```

### SSL Configuration

- Certificates: Let's Encrypt via certbot + Cloudflare DNS
- Domain: `postgresql.darknezz.dev`
- Expiry: Auto-renewed via cron (daily check)
- Renewal script: `/etc/dokploy/renew-postgres-cert.sh`

### Backup

PostgreSQL data is stored in `/home/yami/data/volumes/postgres/data` and backed up via `backup.sh`.

## Dozzle (container logs)

Real-time container logs in the browser at `dozzle.darknezz.dev`, replacing
`docker logs -f` over SSH.

Dozzle authenticates itself, so it does **not** sit behind the dashboard's
BasicAuth. Accounts are managed inside Dozzle and stored in the data volume —
nothing credential-related lives in this repo.

### Creating an account

Users live in `/data/users.yml`, which Dozzle owns. Two ways to create one:

**From the UI** — open Dozzle and use *Settings → Security* to add a user with a
password. This is the simplest path.

**From the CLI** — the `generate` subcommand writes the entry with a bcrypt hash,
so hashes are never typed by hand:

```bash
docker run --rm amir20/dozzle generate <username> --password <password> \
  > $HOME/data/volumes/dozzle/users.yml
```

Optional per-user fields: `filter` limits which containers that user sees
(for example `"label=com.docker.compose.project=<app>"`), and `roles` limits
what they can do (`none`, `download`, `all`).

### Access control

Container actions and shell access are **off** — there is no
`DOZZLE_ENABLE_ACTIONS` and no `DOZZLE_ENABLE_SHELL` in the compose file, so the
UI cannot stop, start or exec into anything.

> Mounting `docker.sock` as read-only does **not** restrict the Docker API. The
> flag only marks the socket file as unwritable on disk; create/delete/update
> calls still go through. The real protections here are Dozzle's own login and
> keeping actions disabled. If actions were ever needed, the way to restrict the
> socket properly is a socket proxy such as `tecnativa/docker-socket-proxy`.

### Setup wizard

A fresh install whose `/data` is empty shows a setup wizard. Its login step is
only editable during the first 15 minutes when no auth provider is set — which
is why `DOZZLE_AUTH_PROVIDER` is set in `.env`: with login on from the start,
that window never applies and accounts are managed from *Settings → Security*
instead.

## Request flow

```
client → DNS (wildcard) → Traefik (80/443)
   → router by Host() from container labels → internal service (proxy network)
   → wildcard TLS via Cloudflare dnsChallenge (acme.json)

PostgreSQL:
client → DNS (postgresql.darknezz.dev) → Traefik (5432, TCP passthrough)
   → HostSNI routing → PostgreSQL (SSL termination at PG level)
```
