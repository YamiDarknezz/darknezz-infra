# darknezz-infra

**Infrastructure as code** for a self-hosted stack running on **Oracle Cloud (Always Free)** — a Traefik reverse proxy + Docker Compose services deployed to production. Everything is reproducible from this repo: plain YAML, shell scripts and GitHub Actions. No panels, no magic.

## Repository layout

```
darknezz-infra/
├── docker-compose.yml           # Traefik + services
├── .env.example                 # Secrets template (copy to .env, never commit)
├── traefik/
│   ├── traefik.yml              # Main config (entrypoints, providers, certs)
│   └── dynamic/
│       └── middlewares.yml      # Dashboard BasicAuth
├── services/
│   └── inventory-api/           # Dockerfile (multi-stage, builds the jar)
└── scripts/
    ├── setup.sh                 # First boot (network, acme, permissions, up)
    └── deploy.sh                # git pull + compose up + optional prune
```

## Subdomain convention

One project = one prefixed subdomain under a wildcard DNS record (`*.example.dev` already points to the VM):

| Subdomain | Purpose |
|---|---|
| `www.example.dev` / `api.example.dev` | **Main site** — reserved for the primary project |
| `api-inventory.example.dev` | inventory-api (Spring Boot) |
| `traefik.example.dev` | Traefik dashboard (BasicAuth-protected) |
| `zeroclaw.example.dev`, `hermes.example.dev` | Future services (wildcard covers them) |

Rule: every project gets a descriptive prefix (`api-`, `app-`, `ui-`). Generic subdomains stay reserved. The base domain is configurable via the `DOMAIN` variable in `.env`.

## Quick start (on the VM)

```bash
# 1. First-time setup (docker network + acme.json + permissions + bring up)
cd $HOME/docker && ./scripts/setup.sh

# 2. Later deploys (update code + rebuild)
./scripts/deploy.sh              # normal
./scripts/deploy.sh --prune      # also prune unused images/volumes
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

The `.env` lives ONLY on the VM at `$HOME/docker/.env`. This repo only has `.env.example` with placeholders.

## Request flow

```
client → DNS (wildcard) → Traefik (80/443)
   → router by Host() from container labels → internal service (proxy network)
   → wildcard TLS via Cloudflare dnsChallenge (acme.json)
```

- `exposedByDefault: false` — nothing is exposed without explicit labels
- Global HTTP→HTTPS redirect on the `web` entrypoint
- Traefik dashboard protected with BasicAuth

## Auto-deploy pipeline

Push to `main` on the application repo → GitHub Actions:

1. **Build** — package the jar
2. **Test** — run the test suite with coverage gates
3. **Deploy** — SSH into the VM: `git pull` + `docker compose up -d --build`

The exact commit SHA is passed as a Docker build argument (`INVENTORY_SHA`), so Docker's layer cache is invalidated on real code changes and **the exact tested commit is shipped**. Only the changed service is recreated — Traefik keeps serving during updates.

## Related

- [inventory-api](https://github.com/YamiDarknezz/inventory-api) — the Spring Boot API deployed with this stack
- [playwright-test-automation-demo](https://github.com/YamiDarknezz/playwright-test-automation-demo) — the test suite covering it
