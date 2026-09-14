# 🛡️ Fail2ban + Traefik — Guía replicable de baneo por fuerza bruta

> Documento generado a partir de la implementación real del VPS **darknezz.dev**.
> Protege contra fuerza bruta en SSH y contra ataques a endpoints HTTPS con autenticación (dashboard de Traefik, Prometheus, APIs con básica auth), con baneo escalonado y reincidentes fuera por 1 año.

---

## 1. Qué se implementa

| Jail | Qué vigila | Max intentos | Ventana | Baneo inicial | Escalado |
|---|---|---|---|---|---|
| `sshd` | Login SSH | 5 | 10 min | 15 min | ×6 por reincidencia, tope **1 año** |
| `http-traefik` | 4xx del access log de Traefik (401/403/404) | 5 | 5 min | 15 min | ×6 por reincidencia, tope **1 año** |
| `recidive` | IPs baneadas repetidamente en otras jails | 3 | 24 h | **1 año** | — |

> `sshd` y `http-traefik` **heredan** la política de `[DEFAULT]` (unificada 2026-08-12): bans progresivos con la misma base (15m), mismo factor (×6) y mismo tope (1 año). `http-traefik` ya NO sobreescribe su propio bantime.

**Cómo funciona el escalado**: cada reincidencia multiplica ×6 el baneo anterior (15m → 1.5h → 9h → 2.25 días → ...), con tope de **1 año** — secuencia idéntica para SSH y HTTP. Si una IP reaparece 3 veces en 24 h, `recidive` la banea **1 año entero** con `iptables-allports` (cae todo el tráfico de esa IP, no solo el puerto).

---

## 2. Requisitos

- Ubuntu/Debian (los comandos asumen `apt`)
- **Traefik v3** sirviendo HTTPS con endpoints protegidos (básica auth, etc.)
- El access log de Traefik en **formato JSON** (crítico, ver sección 4)

---

## 3. Instalar fail2ban

```bash
sudo apt-get update
sudo apt-get install -y fail2ban
```

---

## 4. Configurar Traefik para que loguee en JSON (prerrequisito)

En `traefik.yml`:

```yaml
accessLog:
  filePath: /logs/access.log
  format: json
```

En el `docker-compose.yml` del servicio traefik, el bind mount que crea el archivo visible para fail2ban (el jail lee `/var/log/traefik/access.log` del **host**):

```yaml
services:
  traefik:
    volumes:
      - /var/log/traefik:/logs        # <-- host:contenedor
```

Recargar Traefik y comprobar que el log JSON se escribe:

```bash
docker compose up -d traefik
sudo tail -1 /var/log/traefik/access.log
# debe verse algo como:
# {"ClientHost":"1.2.3.4","ClientPort":"53122","DownstreamStatus":401,"RequestPath":"/dashboard/",...}
```

> ⚠️ **El wiring del log es lo que más se rompe.** Si el mount cambia de ruta, el jail queda ciego. Verificarlo con `sudo fail2ban-client status http-traefik` → campo **"File list"** debe mostrar el archivo.

---

## 5. Configuración de fail2ban

### 5.1. `/etc/fail2ban/jail.local`

```ini
[DEFAULT]
bantime = 15m
findtime = 10m
maxretry = 5
# Bans progresivos: cada reincidencia multiplica x6 el bantime, tope 1 año (31536000s).
# Igual política para SSH y HTTP — heredada por [sshd] y [http-traefik].
bantime.increment = true
bantime.factor = 6
bantime.maxtime = 31536000
# 172.18.0.0/16 = bridge de Docker: el host aparece como ese IP ante Traefik — NUNCA banearlo
# ⚠️ Repo PÚBLICO: aquí solo loopback + bridge de Docker. Las IPs propias (casa/trabajo) y
#    la IP pública del VPS viven en .env y las inyecta setup-fail2ban.sh al instalar
ignoreip = 127.0.0.1/8 172.18.0.0/16

[sshd]
enabled = true

[http-traefik]
enabled = true
port = http,https
filter = traefik-auth
logpath = /var/log/traefik/access.log
backend = polling
maxretry = 5
findtime = 300
# ⚠️ override: REEMPLAZA el de [DEFAULT]; el script inyecta aquí también
ignoreip = 127.0.0.1/8 ::1 172.18.0.0/16

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
backend = polling
maxretry = 3
findtime = 86400
bantime = 31536000
banaction = iptables-allports
```

> ⚠️ **Cambio clave (2026-08-12)**: `http-traefik` ya NO define `bantime` propio (antes: 300s con tope 2h). La política vive en `[DEFAULT]` y las jails la heredan — escalado idéntico SSH+HTTP. Fuente de verdad: `configs/fail2ban/jail.local` del repo (instala `setup-fail2ban.sh`).

> 🔑 **Lista blanca de IPs (2026-09-14)** — `ignoreip` cubre 4 categorías: loopback, el bridge de Docker (`172.18.0.0/16`), **la IP pública del propio VPS** y las **IPs propias** (casa/trabajo). Van en `[DEFAULT]` (las heredan `sshd` y `recidive`) **y** en `[http-traefik]`, que sobreescribe `ignoreip`: un override reemplaza al default, no se fusiona con él.
>
> **Dónde viven los valores**: en el `.env` (`VPS_PUBLIC_IP` + `ALLOWED_IPS`), que NO está en git. Este repo es **público**, así que el template versionado solo lleva loopback + bridge y `setup-fail2ban.sh` inyecta el resto al instalar (valida que queden en TODAS las líneas `ignoreip` y aborta si no: así una copia del template nunca instala una lista blanca incompleta sin avisar).
>
> Motivos: (a) el VPS se auto-baneó 4 veces (11 ago, 21 ago, 4 sep, 13 sep) porque su propio tráfico hacia sus dominios públicos vuelve con **su IP pública** como origen — Prometheus scrapeando `https://traefik.<dominio>/metrics`, verificaciones que esperan un 404 — y el rango del bridge no lo cubría; (b) una IP propia fue baneada 15 min por 8 intentos de login en filebrowser.
>
> Dos límites: `ignoreip` solo evita el ban — el tráfico sigue en el log y sigue alertando; y `ALLOWED_IPS` del `.env` (watchdog SSH) es una lista **independiente**: hay que mantenerlas espejadas. Verificación real (no leyendo el archivo): `sudo fail2ban-client get <jail> ignoreip`.

### 5.2. Filtro custom: `/etc/fail2ban/filter.d/traefik-auth.conf`

```ini
# Filtro para el access log JSON de Traefik v3
# El log es JSON: {...,"ClientHost":"<ip>",...,"DownstreamStatus":401,...}
# 40[0-9] matchea cualquier 4xx (401 auth, 403, 404). Para solo intentos de auth: 401|403
[Definition]
failregex = ^\{.*"ClientHost":"<HOST>".*"DownstreamStatus":40[0-9].*\}$
ignoreregex =
```

> 💡 **Decisión de diseño**: `40[0-9]` cuenta cualquier 4xx (incluye 404 de escáneres que rastrean URLs muertas). Si solo quieres fuerza bruta de auth, cambia a `"DownstreamStatus":(401|403)`.

### 5.3. Script de instalación replicable (opcional pero recomendado)

`setup-fail2ban.sh` — copia los templates y recarga:

```bash
#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== 1/4 Instalar fail2ban (si falta) ==="
if ! command -v fail2ban-client >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo apt-get install -y -qq fail2ban
fi

echo "=== 2/4 Copiar config desde templates ==="
sudo mkdir -p /etc/fail2ban/filter.d
sudo cp "${REPO}/configs/fail2ban/jail.local" /etc/fail2ban/jail.local
sudo cp "${REPO}/configs/fail2ban/filter.d/traefik-auth.conf" /etc/fail2ban/filter.d/traefik-auth.conf

echo "=== 3/4 Habilitar y recargar ==="
sudo systemctl enable --now fail2ban >/dev/null 2>&1 || sudo systemctl restart fail2ban
sudo fail2ban-client reload >/dev/null

echo "=== 4/4 Verificar ==="
sudo fail2ban-client status
echo "DONE — política de baneo replicada."
```

---

## 6. 🧪 Testeo: simular un ataque de fuerza bruta y verificar el ban

> ⚠️ **Hazlo contra un endpoint con básica auth** (p.ej. tu dashboard de Traefik) y desde una IP que puedas desbanear (tu propia IP o la del servidor de pruebas). No te banees tú mismo sin saber desbanear (sección 7).

**1. Verifica que el jail ve el log:**

```bash
sudo fail2ban-client status http-traefik
# El campo "File list" debe listar /var/log/traefik/access.log
```

**2. Dispara intentos fallidos** (8 intentos con contraseña incorrecta > maxretry=5):

```bash
for i in $(seq 1 8); do
  curl -s -o /dev/null -u admin:password_incorrecta \
    https://tu-dominio.com/dashboard/
done
```

**3. Confirma que llegaron como 401 al access log:**

```bash
sudo tail -8 /var/log/traefik/access.log | grep 401
```

**4. Revisa el estado del jail (espera ~30s):**

```bash
sudo fail2ban-client status http-traefik
```

Debes ver:
```
|- Currently banned: 1
`- Banned IP list:  <TU_IP>
```

**5. Verifica que el tráfico de esa IP ya cae (bloqueado):**

```bash
curl -s -o /dev/null -w "%{http_code}" https://tu-dominio.com/dashboard/
# Timeout / error de conexión (bloqueado a nivel de firewall, no llega a Traefik)
```

**6. Prueba el escalado (opcional):** repite el ataque tras el ban y verás que el `bantime` crece (15m → 1.5h → 9h → ...). Repite 3 veces en 24h y la IP cae en `recidive` con 1 año.

**7. Desbanear al terminar la prueba:**

```bash
sudo fail2ban-client set http-traefik unbanip <TU_IP>
```

---

## 7. Operación diaria

```bash
sudo fail2ban-client status                      # jails activas
sudo fail2ban-client status http-traefik         # baneados actuales + contadores
sudo fail2ban-client status recidive
sudo fail2ban-client set <jail> unbanip <ip>     # desbanear manual
sudo fail2ban-client reload                      # aplicar cambios de config sin reiniciar
sudo tail -f /var/log/fail2ban.log               # actividad en vivo (causa de cada ban)
```

### Troubleshooting

| Síntoma | Causa probable | Fix |
|---|---|---|
| Jail no banea nada | El log no llega (File list vacío) | Verificar mount `/var/log/traefik:/logs` y `accessLog.format: json` en traefik.yml |
| El propio servidor baneado | `ignoreip` no cubre el bridge de Docker (172.18.0.0/16) **ni la IP pública del VPS** | Añadir ambos: el host aparece como IP del bridge por tráfico del bridge, y como **su IP pública** cuando su tráfico sale y vuelve por el dominio público (Prometheus → `/metrics`, curls que esperan 404) |
| Banea por 404s de escáneres | El regex cuenta todos los 4xx | Cambiar a `"DownstreamStatus":(401\|403)` en el filter |
| No aplican cambios | Config editada en `/etc/fail2ban/` sin recargar | `sudo fail2ban-client reload` |

---

## 8. Notas del despliegue original (darknezz.dev)

- Los templates viven versionados en el repo de infra: `configs/fail2ban/` (jail.local + filter) y se instalan con `./scripts/setup-fail2ban.sh` → **cualquier VM nueva queda con la misma política**.
- **Política unificada SSH+HTTP (2026-08-12)**: `[DEFAULT]` lleva `bantime.increment/factor/maxtime` (15m, ×6, 1 año); `sshd` y `http-traefik` heredan sin overrides. Verificar en producción: `sudo fail2ban-client get sshd bantime.maxtime` y `sudo fail2ban-client get http-traefik bantime.maxtime` → ambos deben devolver `31536000`.
- Resultado real en producción (primeras horas): 23 baneos en `http-traefik`, 12 en `sshd`, 6 IPs reincidentes en `recidive` (1 año). Los escáneres de internet (fuerza bruta SSH, bots probando credenciales) son ruido constante en cualquier VPS expuesto — con esta config se contienen solos.
- El bridge de Docker en tu servidor de trabajo puede tener otra subred (verificar con `docker network inspect proxy | grep Subnet` o `ip addr show docker0`). Ajustar `ignoreip` si difiere de `172.18.0.0/16`.
