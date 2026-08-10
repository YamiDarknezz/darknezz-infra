# 🔀 darknezz-infra

Infraestructura del VPS `darknezz` (Oracle Cloud Always Free, <VPS_IP>) como código. Traefik + servicios Docker Compose, con la convención **un proyecto = un subdominio** bajo `*.example.dev`.

## 📁 Estructura

```
darknezz-infra/
├── docker-compose.yml           # Traefik + todos los servicios
├── .env.example                 # Plantilla de secrets (copiar a .env)
├── traefik/
│   ├── traefik.yml              # Config principal (entrypoints, providers, certs)
│   └── dynamic/
│       └── middlewares.yml      # BasicAuth del dashboard
├── services/
│   └── inventory-api/           # Dockerfile (multi-stage, compila el jar)
└── scripts/
    ├── setup.sh                 # Primer boot del VPS (red, acme, permisos, up)
    └── deploy.sh                # git pull + compose up + prune opcional
```

## 🌐 Convención de subdominios

| Subdominio | Uso | Estado |
|---|---|---|
| `www.example.dev` / `api.example.dev` | **Main site** (brand/root project) | Reservados — no usar para proyectos |
| `api-inventory.example.dev` | inventory-api | ✅ Activo |
| `traefik.example.dev` | Dashboard Traefik (BasicAuth) | ✅ Activo |
| `zeroclaw.example.dev`, `hermes.example.dev` | Futuros proyectos | Wildcard `*.example.dev` ya cubre |

Regla: **cada proyecto usa un subdominio con prefijo descriptivo** (`api-`, `app-`, `ui-`). Los subdominios genéricos son exclusivos de la marca.

## 🚀 Deploy (en el VPS)

```bash
# 1. Primer setup (red docker + acme.json + permisos + levantar todo)
cd /home/<USER>/docker && ./scripts/setup.sh

# 2. Deploys posteriores (actualizar código + reconstruir)
./scripts/deploy.sh            # normal
./scripts/deploy.sh --prune    # + limpieza de imágenes/volúmenes no usados
```

## 🔐 Secrets (nunca en git)

Copiar `.env.example` → `.env` con valores reales:

| Variable | Para qué |
|---|---|
| `CLOUDFLARE_TOKEN` | dnsChallenge de Let's Encrypt (wildcard cert) |
| `DASHBOARD_HASH` | BasicAuth del dashboard (`openssl passwd -apr1`) |
| `JWT_SECRET` | Firma de tokens JWT de inventory-api |
| `DB_URL` / `DB_USER` / `DB_PASSWORD` | PostgreSQL (Neon) de inventory-api |

El `.env` vive SOLO en `/home/<USER>/docker/.env` del VPS. El repositorio solo tiene `.env.example` con placeholders.

## 🔄 Flujo de una petición

```
cliente → Cloudflare DNS (wildcard) → Traefik (80/443)
   → router por Host() en labels → servicio interno (red proxy)
   → cert Let's Encrypt wildcard (dnsChallenge Cloudflare, acme.json)
```

- `exposedByDefault: false` — ningún contenedor se expone sin querer
- Redirect HTTP→HTTPS global en el entryPoint web
- Dashboard Traefik protegido con BasicAuth (a diferencia de Pauser)
