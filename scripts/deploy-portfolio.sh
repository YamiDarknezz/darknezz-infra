#!/bin/bash
# deploy-portfolio.sh — construye el portfolio (DarknezzDev) por SHA exacto y lo publica.
# El repo es PRIVADO → se clona con la SSH key del host (yami), NO dentro del Dockerfile.
# Uso: PORTFOLIO_SHA=<commit> ./scripts/deploy-portfolio.sh
#   PORTFOLIO_SHA = commit a desplegar (default: main)
set -euo pipefail
cd "$(dirname "$0")/.."

SHA="${PORTFOLIO_SHA:-main}"
SRC_DIR="$HOME/data/portfolio-src"
DIST_DIR="$HOME/data/portfolio-dist"
REPO_URL="git@github.com:YamiDarknezz/DarknezzDev.git"

echo "=== 1/5 clonar/fetch DarknezzDev @ ${SHA} ==="
if [ ! -d "$SRC_DIR/.git" ]; then
  git clone --filter=blob:none "$REPO_URL" "$SRC_DIR"
fi
cd "$SRC_DIR"
git fetch --depth 1 origin "$SHA"
git checkout -q FETCH_HEAD
COMMIT_DESC=$(git log -1 --format='%h %s')

echo "=== 2/5 instalar dependencias (pnpm) ==="
export PATH="$HOME/.local/bin:$HOME/.hermes/node/bin:$PATH"
corepack enable >/dev/null 2>&1 || true
pnpm install --frozen-lockfile

echo "=== 3/5 build producción ==="
pnpm build

echo "=== 4/5 publicar dist → ${DIST_DIR} ==="
mkdir -p "$DIST_DIR"
rsync -a --delete dist/darknezzdev-portfolio/browser/ "$DIST_DIR/"

echo "=== 5/5 levantar/actualizar contenedor portfolio ==="
cd "$HOME/data/docker"
docker compose up -d portfolio
docker compose ps portfolio

echo "DONE — desplegado: ${COMMIT_DESC}"
