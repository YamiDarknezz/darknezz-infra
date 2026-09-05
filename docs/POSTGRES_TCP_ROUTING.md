# 🐘 PostgreSQL 18 en VPS darknezz — Documentación Completa

## Escenario

PostgreSQL 18 corre como contenedor Docker en un VPS (Oracle Cloud Always Free) con Traefik v3.7.10 como reverse proxy. PostgreSQL se expone a través de Traefik en el puerto 5432, con SSL habilitado vía certificados Let's Encrypt.

## Proceso de instalación completo

### Paso 1: Crear directorios y credenciales

```bash
# Directorios para datos y configuración
mkdir -p ~/data/volumes/postgres/data
mkdir -p ~/data/volumes/postgres/config

# Generar contraseña segura (sin caracteres problemáticos para URLs)
PG_PASS="${POSTGRES_PASSWORD}"
echo "$PG_PASS" > ~/data/secrets/postgres-password.txt
chmod 600 ~/data/secrets/postgres-password.txt
```

### Paso 2: Instalar certbot y plugin Cloudflare

```bash
# Matar procesos apt atascados si existen
sudo kill $(pgrep -f "apt upgrade") 2>/dev/null
sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
sudo dpkg --configure -a

# Instalar certbot
sudo apt-get update -qq && sudo apt-get install -y -qq certbot python3-certbot-dns-cloudflare

# Credenciales de Cloudflare para certbot
sudo mkdir -p /etc/letsencrypt
echo "dns_cloudflare_api_token = <CLOUDFLARE_TOKEN>" | sudo tee /etc/letsencrypt/cloudflare.ini
sudo chmod 600 /etc/letsencrypt/cloudflare.ini
```

### Paso 3: Solicitar certificado SSL

```bash
sudo certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  -d postgresql.darknezz.dev \
  --non-interactive --agree-tos \
  --email yami@darknezz.dev
```

Certificados guardados en:
- `/etc/letsencrypt/live/postgresql.darknezz.dev/fullchain.pem`
- `/etc/letsencrypt/live/postgresql.darknezz.dev/privkey.pem`

### Paso 4: Crear docker-compose de PostgreSQL

Archivo: `services/postgres/docker-compose.yml`

```yaml
services:
  postgres:
    image: postgres:18
    container_name: postgres
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - proxy
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password
      - POSTGRES_DB=darknezz
      - PGDATA=/var/lib/postgresql/data/pgdata
    volumes:
      - /home/yami/data/volumes/postgres/data:/var/lib/postgresql/data
      - /home/yami/data/secrets/postgres-password.txt:/run/secrets/postgres_password:ro
    secrets:
      - postgres_password
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

secrets:
  postgres_password:
    file: /home/yami/data/secrets/postgres-password.txt

networks:
  proxy:
    external: true
```

**Importante**: No hay `ports:` — PostgreSQL NO expone puertos al host. Solo accesible via red proxy y Traefik.

### Paso 5: Iniciar PostgreSQL

```bash
cd ~/data/repos/darknezz-infra/services/postgres && docker compose up -d
```

### Paso 6: Habilitar SSL en PostgreSQL

```bash
# Copiar certificados al contenedor
PGID=$(docker ps -q --filter name=postgres)

sudo cat /etc/letsencrypt/live/postgresql.darknezz.dev/fullchain.pem | \
  docker exec -i $PGID sh -c "cat > /var/lib/postgresql/data/pgdata/server.crt"

sudo cat /etc/letsencrypt/live/postgresql.darknezz.dev/privkey.pem | \
  docker exec -i $PGID sh -c "cat > /var/lib/postgresql/data/pgdata/server.key"

docker exec $PGID chmod 600 /var/lib/postgresql/data/pgdata/server.crt /var/lib/postgresql/data/pgdata/server.key
docker exec $PGID chown postgres:postgres /var/lib/postgresql/data/pgdata/server.crt /var/lib/postgresql/data/pgdata/server.key

# Habilitar SSL en postgresql.conf
docker exec $PGID sed -i "s/^#ssl = off/ssl = on/" /var/lib/postgresql/data/pgdata/postgresql.conf
docker exec $PGID sed -i "s/^#ssl_cert_file = .*/ssl_cert_file = 'server.crt'/" /var/lib/postgresql/data/pgdata/postgresql.conf
docker exec $PGID sed -i "s/^#ssl_key_file = .*/ssl_key_file = 'server.key'/" /var/lib/postgresql/data/pgdata/postgresql.conf

# Reiniciar PostgreSQL
docker restart $PGID
```

### Paso 7: Crear usuario y permisos

```bash
docker exec postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "
ALTER USER ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASSWORD}';
GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_USER};
ALTER USER ${POSTGRES_USER} CREATEDB;
"
```

### Paso 8: Configurar Traefik

**traefik/traefik.yml** — agregar entryPoint:

```yaml
entryPoints:
  postgres:
    address: ":5432"
```

**traefik/dynamic/postgres-ssl.yml** — TCP router:

```yaml
tcp:
  routers:
    postgres-direct:
      rule: "HostSNI(`*`)"
      entryPoints:
        - "postgres"
      service: "postgres-service"
  services:
    postgres-service:
      loadBalancer:
        servers:
          - address: "postgres:5432"
```

**docker-compose.yml** — agregar puerto a Traefik:

```yaml
ports:
  - "80:80"
  - "443:443"
  - "5432:5432"
```

### Paso 9: Reiniciar Traefik

```bash
cd ~/data/repos/darknezz-infra && docker compose up -d traefik --force-recreate
```

### Paso 10: Abrir puerto en Oracle Cloud

Oracle Cloud Console → Networking → VCN → Security Lists → Add Ingress Rule:
- **Source CIDR**: `0.0.0.0/0` (o IP específica)
- **Destination Port**: `5432`
- **Protocol**: TCP

### Paso 11: Verificar conexión

```bash
# Con SSL
PGPASSWORD=${POSTGRES_PASSWORD} psql "host=postgresql.darknezz.dev port=5432 user=${POSTGRES_USER} dbname=${POSTGRES_DB} sslmode=require" -c "SELECT 1;"

# Verificar SSL
PGPASSWORD=${POSTGRES_PASSWORD} psql "host=postgresql.darknezz.dev port=5432 user=${POSTGRES_USER} dbname=${POSTGRES_DB} sslmode=require" -c "SHOW ssl;"
```

### Paso 12: Actualizar .env

```bash
# Agregar al .env
POSTGRES_HOST=postgresql.darknezz.dev
POSTGRES_PORT=5432
POSTGRES_DB=darknezz
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
```

### Paso 13: Commit al repo

```bash
cd ~/data/repos/darknezz-infra
git add .
git commit -m "feat: PostgreSQL 18 with SSL via Traefik TCP routing"
```

---

## TCP Routing via Traefik

## Arquitectura Final

```
psql / pgAdmin / Power BI
       │
       │  host=postgresql.darknezz.dev:5432
       │  sslmode=require
       ▼
   Traefik (0.0.0.0:5432, TCP passthrough)
       │  HostSNI(`*`) — enruta TODO el tráfico TCP
       │  No toca TLS, solo proxy TCP puro
       ▼
   PostgreSQL 18 (172.18.0.3:5432, SSL = on)
       │  Certificados Let's Encrypt
       ▼
   Base de datos darknezz
```

## Diferencias con la guía Dokploy

La guía original (Guia SSL PostgreSQL Dokploy.md) usa Dokploy + Docker Swarm. Nuestro setup es Traefik directo + Docker Compose. Las diferencias clave:

| Aspecto | Guía Dokploy | Nuestro setup |
|---------|-------------|---------------|
| **TCP Router** | `HostSNI(\`postgres.pauserdistribucionessac.com\`)` con `tls: passthrough: true` | `HostSNI(\`*\`)` sin TLS passthrough |
| **Puerto** | 5430 (porque 5432 estaba ocupado) | 5432 (estándar, libre) |
| **Orquestador** | Docker Swarm via Dokploy | Docker Compose directo |
| **Traefik config** | Vía API Dokploy (`updateTraefikPorts`) | Archivos YAML manuales |
| **Certificados** | certbot + Cloudflare DNS (igual) | certbot + Cloudflare DNS (igual) |
| **PostgreSQL** | Servicio Swarm con volumen Dokploy | Contenedor Docker con volumen local |

### ¿Por qué la guía Dokploy usa HostSNI con el dominio?

En la guía, el router TCP está configurado así:

```yaml
tcp:
  routers:
    postgres-secure:
      rule: "HostSNI(`postgres.pauserdistribucionessac.com`)"
      tls:
        passthrough: true
```

Esto **asume** que el cliente envía un TLS ClientHello como primeros bytes (con SNI incluido). Sin embargo, el protocolo PostgreSQL **no funciona así**:

### El problema del protocolo PostgreSQL

El flujo de conexión PostgreSQL con SSL es:

```
1. Cliente → Servidor:  PostgreSQL SSLRequest (8 bytes, código 80877103)
2. Servidor → Cliente:  'S' (acepta SSL) o 'N' (rechaza)
3. Cliente → Servidor:  TLS ClientHello (CON SNI)
4. Servidor → Cliente:  TLS ServerHello + certificado
5. [TLS establecido, continúa protocolo PostgreSQL]
```

**El problema**: Traefik con `HostSNI()` necesita leer el SNI del TLS ClientHello para enrutar. Pero los primeros bytes que llegan son el **SSLRequest de PostgreSQL** (no TLS), así que Traefik **no puede extraer el SNI**.

### ¿Entonces cómo funciona en Dokploy?

Es posible que:
1. El guide fue probado con un cliente que envía TLS directo (no el protocolo PG)
2. O Dokploy tiene una configuración especial de Traefik que maneja esto
3. O simplemente no fue probado con `psql` estándar

**Nuestra solución**: Usar `HostSNI(\`*\`)` que acepta **cualquier conexión** en el puerto, sin intentar leer SNI. Traefik actúa como proxy TCP puro y PostgreSQL maneja SSL internamente.

### Ventajas de nuestra solución

1. **Compatible con cualquier cliente** — psql, pgAdmin, Power BI, aplicaciones
2. **SSL lo maneja PostgreSQL** — certificados Let's Encrypt instalados directamente en PG
3. **Simple** — sin dependencia de SNI o TLS passthrough
4. **Traefik solo enruta** — proxy TCP sin tocar el tráfico

## Errores encontrados y soluciones

### Error 1: `router has no rule`

**Síntoma**: Traefik rechaza el router TCP porque no tiene regla.

```
ERR error="router has no rule" entryPointName=postgres routerName=postgres-direct@file
```

**Causa**: Traefik v3 requiere una regla (`rule`) en todos los routers TCP. No se puede tener un router sin regla.

**Solución**: Agregar `rule: "HostSNI(\`*\`)"` que acepta cualquier conexión.

### Error 2: `SSL SYSCALL error: EOF detected`

**Síntoma**: `psql` con `sslmode=require` falla después del handshake TLS.

```
psql: error: connection to server at "127.0.0.1", port 5432 failed: SSL SYSCALL error: EOF detected
```

**Causa**: Traefik con `HostSNI(\`postgresql.darknezz.dev\`)` y `tls: passthrough: Traefik intenta leer SNI pero recibe el SSLRequest de PostgreSQL (8 bytes que no son TLS). No puede enrutar → cierra la conexión.

**Solución**: Cambiar a `HostSNI(\`*\`)` sin TLS passthrough. Traefik enruta todo el tráfico TCP del puerto 5432 a PostgreSQL sin intentar interpretarlo.

### Error 3: `TRAEFIK DEFAULT CERT` en openssl s_client

**Síntoma**: Al conectar con `openssl s_client` sin SNI, Traefik responde con su certificado default auto-firmado.

```
depth=0 CN = TRAEFIK DEFAULT CERT
verify error:num=18:self-signed certificate
```

**Causa**: Sin SNI, Traefik no sabe qué certificado usar y responde con el default.

**Solución**: Con `HostSNI(\`*\`)`, Traefik no intercepta TLS — solo proxy TCP. El certificado lo maneja PostgreSQL.

### Error 4: Conflicto de puerto 5432

**Síntoma**: PostgreSQL y Traefik ambos intentan usar el puerto 5432 del host.

```
Bind for 0.0.0.0:5432 failed: port is already allocated
```

**Causa**: El docker-compose de PostgreSQL tenía `ports: - "127.0.0.1:5432:5432"` y Traefik también necesitaba el puerto 5432.

**Solución**: Quitar el port binding de PostgreSQL. Solo Traefik expone el puerto 5432 al host. PostgreSQL solo es accesible via la red Docker `proxy`.

### Error 5: Certificados SSL perdidos al recrear contenedor

**Síntoma**: Después de recrear el contenedor PostgreSQL, los certificados server.crt/server.key desaparecieron.

**Causa**: Los certificados se copiaron al data directory del contenedor, pero al recrearlo se pierden si el volumen no persiste correctamente.

**Solución**: Los certificados SÍ persisten en el volumen montado (`/home/yami/data/volumes/postgres/data`). Verificar que el volumen esté correctamente montado después de cada recreación.

## Configuración de archivos

### traefik/traefik.yml (entryPoint postgres)

```yaml
entryPoints:
  postgres:
    address: ":5432"
```

### traefik/dynamic/postgres-ssl.yml (TCP router)

```yaml
tcp:
  routers:
    postgres-direct:
      rule: "HostSNI(`*`)"
      entryPoints:
        - "postgres"
      service: "postgres-service"
  services:
    postgres-service:
      loadBalancer:
        servers:
          - address: "postgres:5432"
```

### services/postgres/docker-compose.yml

```yaml
services:
  postgres:
    image: postgres:18
    container_name: postgres
    restart: unless-stopped
    networks:
      - proxy
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password
      - POSTGRES_DB=darknezz
    volumes:
      - /home/yami/data/volumes/postgres/data:/var/lib/postgresql/data
      - /home/yami/data/secrets/postgres-password.txt:/run/secrets/postgres_password:ro
    secrets:
      - postgres_password

networks:
  proxy:
    external: true
```

**Nota**: No hay `ports:` — PostgreSQL NO expone puertos al host. Solo es accesible via la red proxy y Traefik.

## Conexión

```bash
# Con SSL (recomendado)
PGPASSWORD=xxx psql "host=127.0.0.1 port=5432 user=${POSTGRES_USER} dbname=${POSTGRES_DB} sslmode=require"

# Sin SSL
PGPASSWORD=xxx psql "host=127.0.0.1 port=5432 user=${POSTGRES_USER} dbname=${POSTGRES_DB} sslmode=disable"

# Verificar SSL
PGPASSWORD=xxx psql "host=127.0.0.1 port=5432 user=${POSTGRES_USER} dbname=${POSTGRES_DB} sslmode=require" -c "SHOW ssl;"
```

## Acceso externo

### ¿Es necesario abrir el puerto 5432 en el firewall?

**Sí, es necesario.** El dominio `postgresql.darknezz.dev` resuelve a la IP pública del VPS, pero el firewall de Oracle Cloud bloquea el puerto 5432 por defecto.

Flujo de una conexión externa:

```
Cliente → DNS (postgresql.darknezz.dev → IP pública)
         → Oracle Cloud Firewall (puerto 5432 → ¿abierto?)
         → Traefik (0.0.0.0:5432)
         → PostgreSQL (172.18.0.3:5432)
```

Sin abrir el puerto 5432 en Oracle Cloud Security List, la conexión se pierde en el firewall y nunca llega a Traefik.

### Para abrir el puerto

1. Oracle Cloud Console → Networking → Virtual Cloud Networks
2. Seleccionar la VCN → Security Lists
3. Agregar Ingress Rule:
   - **Source CIDR**: `0.0.0.0/0` (o IP específica para más seguridad)
   - **Destination Port**: `5432`
   - **Protocol**: TCP

### Recomendación de seguridad

Para producción, limitar el acceso por IP:
- **Source CIDR**: Solo la IP de tu oficina/casa
- O usar VPN para acceder al VPS

## Certificados SSL

### Ubicación

- Certificados: `/etc/letsencrypt/live/postgresql.darknezz.dev/`
- En PostgreSQL: `/var/lib/postgresql/data/pgdata/server.crt` y `server.key`
- Dominio CN: `postgresql.darknezz.dev`
- Expira: cada 90 días (renovación automática via certbot)

### Renovación

```bash
# Renovar certificado
sudo certbot renew --cert-name postgresql.darknezz.dev

# Copiar a PostgreSQL
PGID=$(docker ps -q --filter name=postgres)
sudo cat /etc/letsencrypt/live/postgresql.darknezz.dev/fullchain.pem | \
  docker exec -i $PGID sh -c "cat > /var/lib/postgresql/data/pgdata/server.crt"
sudo cat /etc/letsencrypt/live/postgresql.darknezz.dev/privkey.pem | \
  docker exec -i $PGID sh -c "cat > /var/lib/postgresql/data/pgdata/server.key"
docker exec $PGID chmod 600 /var/lib/postgresql/data/pgdata/server.crt /var/lib/postgresql/data/pgdata/server.key
docker exec $PGID chown postgres:postgres /var/lib/postgresql/data/pgdata/server.crt /var/lib/postgresql/data/pgdata/server.key
docker exec $PGID psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "SELECT pg_reload_conf();"
```

## Credenciales

| Campo | Valor |
|-------|-------|
| Usuario | `yamidarknezz` |
| Contraseña | Ver `~/data/secrets/postgres-password.txt` |
| Dominio | `postgresql.darknezz.dev` |
| Puerto | `5432` |
| DB | `darknezz` |

## Troubleshooting

### PostgreSQL no acepta conexiones
```bash
docker logs postgres --tail 20
docker exec postgres pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}
```

### Traefik no enruta TCP
```bash
docker logs traefik 2>&1 | grep -i "tcp\|postgres\|error"
docker exec traefik cat /dynamic/postgres-ssl.yml
```

### SSL no funciona
```bash
docker exec postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "SHOW ssl;"
docker exec postgres openssl x509 -in /var/lib/postgresql/data/pgdata/server.crt -noout -subject -dates
```

### Conexión timeout externa
```bash
# Verificar firewall
nc -zv postgresql.darknezz.dev 5432
# Si falla → abrir puerto 5432 en Oracle Cloud Security List
```

---
*Documentado: 2026-08-31*
*PostgreSQL: 18.6 | Traefik: 3.7.10 | SSL: Let's Encrypt*
