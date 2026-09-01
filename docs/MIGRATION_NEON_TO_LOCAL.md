# 🔄 Migración: Neon PostgreSQL → PostgreSQL Local

## Historial

### Opción original: Neon (Serverless PostgreSQL)

El inventory-api original usaba **Neon** como base de datos PostgreSQL serverless.

**Configuración Neon:**
```env
DB_URL=jdbc:postgresql://ep-solitary-dew-ax8r0mnu-pooler.c-4.us-east-2.aws.neon.tech/inventory?sslmode=require
DB_USER=neondb_owner
DB_PASSWORD=npg_xxxxx
```

**Ventajas de Neon:**
- Serverless: escala a 0 cuando no hay tráfico
- Backups automáticos
- Sin mantenimiento

**Problema:**
- Plan free: 100 compute-hours/mes
- El API corriendo 24/7 consumía ~3.7 horas/día
- Después de ~27 días se agotaba la cuota
- Resultado: API caída con "compute time quota exceeded"

### Solución: PostgreSQL Local en VPS

Migración a PostgreSQL 18 corriendo como contenedor Docker en el VPS.

**Configuración actual:**
```env
DB_URL=jdbc:postgresql://postgres:5432/darknezz?sslmode=disable
DB_USER=yamidarknezz
DB_PASSWORD=REDACTED_DB_PASSWORD
```

**Ventajas:**
- Sin límites de compute
- Sin costo adicional
- Rendimiento mejor (misma máquina)
- SSL habilitado vía Let's Encrypt
- Acceso externo vía postgresql.darknezz.dev

## Migración

### Paso 1: Exportar datos de Neon

```bash
# Desde el VPS con acceso a Neon
pg_dump "postgresql://neondb_owner:npg_xxxxx@ep-xxx.pooler.us-east-1.aws.neon.tech/inventory?sslmode=require" > neon_backup.sql
```

### Paso 2: Importar a PostgreSQL local

```bash
# Copiar backup al contenedor
cat neon_backup.sql | docker exec -i postgres psql -U yamidarknezz -d darknezz
```

### Paso 3: Actualizar .env

```bash
# Cambiar de Neon a local
DB_URL=jdbc:postgresql://postgres:5432/darknezz?sslmode=disable
DB_USER=yamidarknezz
DB_PASSWORD=REDACTED_DB_PASSWORD
```

### Paso 4: Reconstruir y deploy

```bash
cd ~/data/repos/darknezz-infra/services/inventory-api
docker compose up -d --build
```

## Neon: Opción válida para otros casos

Neon sigue siendo una buena opción para:
- Proyectos con tráfico bajo/esporádico
- Desarrollo/pruebas
- Cuando no se quiere mantener un servidor

**Para volver a Neon:**
1. Crear cuenta en neon.tech
2. Crear proyecto y base de datos
3. Actualizar .env con credenciales Neon
4. Asegurar que el plan tenga suficientes compute-hours

## Referencias

- Neon: https://neon.tech
- PostgreSQL 18: https://www.postgresql.org/docs/18/
- Documentación TCP Routing: POSTGRES_TCP_ROUTING.md

---
*Documentado: 2026-09-01*
