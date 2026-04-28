# Linkding

## Descripción

Despliegue de **Linkding** ([imagen `sissbruecker/linkding`](https://github.com/sissbruecker/linkding)) como **gestor de marcadores web** del homelab. Linkding es una aplicación Django (Python 3.12, SQLite por defecto) minimalista pero completa: archivado de URLs, etiquetas jerárquicas, búsqueda full-text, lectura "later", snapshots de páginas (opcional vía `singlefile`), feeds RSS por etiqueta, REST API con tokens y **extensiones oficiales** para Firefox y Chromium. Es el **sustituto self-hosted del bookmarking nativo del navegador** y el complemento natural de Bookstack ([`./02-bookstack.md`](./02-bookstack.md)) y FreshRSS ([`./07-freshrss.md`](./07-freshrss.md)) en la Fase 11 — Productividad: Bookstack guarda **conocimiento estructurado**, FreshRSS canaliza la **lectura periódica** y Linkding es el **buffer de URLs sueltas** ("esto lo leo luego", "este artículo me sirvió", "este vídeo lo refiero a un familiar").

Por qué exactamente esta arquitectura, y no otra:

1. **Linkding, no Wallabag, no Shaarli, no Hoarder, no Raindrop.** Linkding apuesta por un **modelo de datos plano** (un marcador = URL + título + descripción + notas + etiquetas) y deliberadamente **no** intenta ser un read-it-later completo (no hace OCR, no extrae artículo limpio sin imágenes, no sincroniza posición de lectura). Las alternativas pecan en alguno de estos ejes: (a) **Wallabag** apunta a "guardar el artículo entero offline" — su valor está en el extractor de contenido y eso requiere PHP-FPM + PostgreSQL/MariaDB + RabbitMQ opcional, demasiado para un buffer de marcadores; (b) **Shaarli** es ligero (PHP + ficheros planos) pero su UI ha envejecido, no tiene REST API estable y no hay extensión moderna para los navegadores actuales; (c) **Hoarder** (recientemente renombrado a Karakeep) es prometedor pero requiere PostgreSQL + Redis + Meilisearch + workers separados — un homelab Pi 5 puede sostenerlo pero la matriz de upgrades cuadruplica la superficie; (d) **Raindrop** es excelente, pero el self-host **no existe** (es SaaS). Linkding es la talla justa: un único contenedor, SQLite, ~150 MB de RAM en uso normal, multi-arch, extensión oficial mantenida por el autor.
2. **Imagen `sissbruecker/linkding:<version>` upstream, no LinuxServer.io.** A diferencia de Bookstack (donde [`./02-bookstack.md`](./02-bookstack.md) §0 punto 2 elige LSIO porque bundlea Apache + PHP-FPM), la imagen upstream de Linkding ya **es** monolítica: bundlea Python 3.12 + uWSGI + nginx mínimo + supervisord en un único contenedor multi-arch (`linux/amd64`, `linux/arm64`, `linux/arm/v7`). LSIO no publica `linkding`. La imagen upstream está mantenida por el autor del proyecto (`sissbruecker`), publica tags semver puntuales en cada release, y es la que recomienda la propia documentación.
3. **SQLite, no PostgreSQL.** Linkding soporta nominalmente PostgreSQL (`LD_DB_ENGINE=postgres`) **pero su CI primario, su documentación y el grueso de los issues de GitHub se prueban contra SQLite** — el motor recomendado por el autor para deploys de 1–10 usuarios y <100k marcadores. SQLite elimina un contenedor (no hay `postgres-linkding` aparte), un volumen, una red interna, un secret de password y un backend más en Borgmatic. La línea ya está escrita anticipadamente en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6, líneas 545–546 (`sqlite_databases: - name: linkding, path: /mnt/hd2t/services/linkding/data/db.sqlite3`). PostgreSQL queda como variante opt-in (§12.2) para el operador con >5 usuarios humanos sincronizando muchos marcadores en paralelo.
4. **Detrás de Caddy con CA interna, **sin** Authelia delante.** Coherente con la lógica de [`./01-vaultwarden.md`](./01-vaultwarden.md) §0 punto 3: Linkding tiene **clientes API** (la extensión oficial de navegador, los clientes móviles tipo "LinkDing for Android", `bookmark-cli`) que se autentican con un **token de API** vía cabecera `Authorization: Token <token>`. Authelia en `forward_auth` interceptaría todas las requests a `/api/*` redirigiendo a `https://auth.lan/?rd=...` — la extensión recibiría HTML en lugar de JSON, y dejaría de funcionar. Linkding se sirve **directamente** detrás de Caddy con su propia capa de auth (Django, sessions firmadas, password con PBKDF2-SHA256). Por eso la línea `linkding.{{ env "LAN_DOMAIN" }}` **no** aparece en `access_control.rules` de Authelia (a diferencia de Bookstack, que sí está en línea 421 — Bookstack es UI-only y sí tolera `forward_auth`). La variante con Authelia + bypass selectivo de `/api/*` queda en §12.3 para el operador que quiera forzar 2FA en el login web aceptando que tendrá que sortear `/api/*` con `bypass`.
5. **Datos persistentes en `hd2t`, en `/mnt/hd2t/services/linkding/data/`.** Coherente con [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.1 (loop "Fase 11 — Productividad", línea `for svc in vaultwarden bookstack linkding paperless-ngx mealie stirling-pdf freshrss`) y con el path ya prometido en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6 (línea 546). El árbol que se materializa en §3:
   - `/mnt/hd2t/services/linkding/.env` — configuración del stack (chmod 600).
   - `/mnt/hd2t/services/linkding/data/` — bind mount de `/etc/linkding/data` del contenedor: `db.sqlite3` (SQLite con WAL), `favicons/` (caché de favicons), `previews/` (snapshots opcionales), `uploads/`.
   - `/mnt/hd2t/services/linkding/secrets/superuser_password` — password inicial del superusuario, custodiada (`chmod 600 root:homelab`).
6. **Imagen `sissbruecker/linkding:<version>` pinned a release puntual.** Igual que el resto del homelab: nunca `latest`, nunca un tag rolling. Misma regla que [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1. **Watchtower SÍ actualiza Linkding** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 línea 466, fila explícita `Linkding`): es una app Django con migraciones gestionadas automáticamente al arranque (`python manage.py migrate --noinput`), su modelo de datos crece despacio y un rollback es trivial (`docker compose pull` con el tag anterior + restaurar `db.sqlite3` del último Borg). El operador acepta que Watchtower puede subir una versión nueva durante la madrugada; si rompiera algo, el `pre-update` opt-in de §12.6 hace dump SQLite antes de cada upgrade.
7. **UID `33:33` (`www-data`) para el proceso del contenedor.** La imagen upstream **no** soporta variables `PUID`/`PGID` al estilo LSIO; arranca como root, hace `chown -R www-data:www-data /etc/linkding/data` y ejecuta uWSGI como `www-data` (UID/GID 33). El homelab acepta esa convención del propio proyecto y monta el bind mount con owner `33:33`. La línea ya está escrita anticipadamente en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8 (tabla, línea 592: `Linkding | data/db.sqlite3 | 33:33 (www-data)`). El operador (UID 1000) no necesita leer estos ficheros desde el host: Borgmatic corre como root (vía `systemd` unit, [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §4) y los lee sin problema; cualquier inspección manual usa `sudo`.
8. **`LD_CSRF_TRUSTED_ORIGINS` con `https://linkding.${LAN_DOMAIN}` y `https://linkding.${TS_DOMAIN}`.** Django/Linkding aplica protección CSRF a todos los formularios POST (login, alta de marcador, edición de etiqueta, generación de token API). Cuando la app se sirve detrás de un reverse proxy con TLS terminado (caso típico del homelab: Caddy hace HTTPS hacia el navegador, HTTP plano hacia Linkding), Django **no** detecta el HTTPS por sí solo; necesita que `CSRF_TRUSTED_ORIGINS` liste explícitamente los orígenes esperados, **incluido el scheme `https://`**. Si falta, todo POST devuelve `403 Forbidden — CSRF verification failed. Origin checking failed`. La variable acepta una lista separada por comas y se materializa con ambos hosts (LAN canónico + alias Tailscale) desde el día 1, aunque el bloque Tailscale del Caddyfile se descomente más adelante.
9. **Sin SMTP por defecto.** El homelab no tiene MTA ([`./01-vaultwarden.md`](./01-vaultwarden.md) §0 punto 4 y [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §0 punto 7). Linkding usa email **solo** para reset de password (Django `password_reset`). Sin SMTP: el reset se hace desde la consola con `docker compose exec linkding python manage.py changepassword <username>`, y las invitaciones a usuarios nuevos se materializan creando la cuenta directamente desde la admin de Django (§7.5). Variante con SMTP relay en §12.1.
10. **Superusuario inicial creado por env vars `LD_SUPERUSER_NAME` y `LD_SUPERUSER_PASSWORD`, **luego rotado**.** La imagen oficial detecta esas variables al primer arranque y crea el usuario admin si no existe. El homelab las usa **una sola vez** para bootstrap, y **rota la password desde la UI inmediatamente después** (§7.1) — aunque ambas variables están en el `.env` con `chmod 600`, la práctica del homelab es no dejar passwords plaintext rotables en disco más allá del primer arranque. Tras la rotación, las variables siguen en el `.env` por si alguna vez se reinstala el stack sobre datos vacíos, pero la password real de la cuenta admin solo vive cifrada en la BD.

> **Alcance de red**: la UI de Linkding **no** publica puertos al host. Se accede únicamente vía `https://linkding.${LAN_DOMAIN}` (Caddy + CA interna) y, una vez completada la fase Tailscale, vía `https://linkding.${TS_DOMAIN}`. El homelab opera en LAN + Tailscale, sin exposición a internet, sin Let's Encrypt público, sin port forwarding.

> **Alcance de auth**: Authelia **no** cubre Linkding (justificado en §0 punto 4). La defensa es: (a) Caddy + CA interna (TLS local), (b) login Django con PBKDF2-SHA256, (c) tokens API revocables desde la UI, (d) Pi-hole resolviendo `linkding.lan` solo en la LAN, (e) sin exposición externa. Variante con Authelia + bypass de `/api/*` en §12.3.

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), `/mnt/hd2t/` montado, directorio `/mnt/hd2t/services/linkding/` ya creado por el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.1 (loop "Fase 11 — Productividad", línea 241: `for svc in vaultwarden bookstack linkding paperless-ngx mealie stirling-pdf freshrss`).
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` creada (`172.20.0.0/24`, `external: true`), convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3 y §5).
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) con `lan_internal_tls` y `security_headers` operativos.
- **CA interna de Caddy** instalada en al menos un dispositivo del operador (navegador) y en el navegador donde se quiera instalar la extensión de Linkding (típicamente el mismo). Procedimiento §6.5 de Caddy. Sin la CA confiada, la extensión arranca pero el handshake TLS falla con "untrusted certificate" y el sync no avanza.
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con la posibilidad de añadir un registro DNS local: `linkding.${LAN_DOMAIN}` → IP del host donde escucha Caddy.
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) con el bloque `sqlite_databases` ya configurado para `linkding` (líneas 545–546 de Borgmatic, ya presentes). El hook se ejecuta cada noche y produce un dump consistente con `sqlite3 ... .backup` antes del snapshot Borg.
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Linkding **no** lleva la etiqueta `com.centurylinklabs.watchtower.enable: "false"` (justificado en §0 punto 6 y en Watchtower §4.2, línea 466: Linkding está en la lista de servicios con auto-update).
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No se añaden reglas: Linkding no publica puertos al host; el tráfico entra por Caddy.
- **Vaultwarden desplegado** ([`./01-vaultwarden.md`](./01-vaultwarden.md)). No es bloqueante para arrancar Linkding (los secretos pueden custodiarse provisionalmente en KeePassXC), pero la convención del homelab es que el operador ya tenga Vaultwarden activo cuando empieza la Fase 11; cualquier credencial nueva (password del superusuario, token API de la extensión) se anota allí.
- **Espacio libre en `hd2t`** ≥ 200 MB es más que suficiente para el primer año. La BD SQLite de Linkding crece muy lento (<5 MB para varios miles de marcadores); los `favicons/` crecen con el número de hosts únicos guardados (~5 KB por favicon, total ~10 MB para 2000 dominios distintos); los `previews/` son opt-in y solo se usan si el operador habilita el snapshot HTML por marcador.
- **Comprobaciones rápidas**:
  ```bash
  # Red homelab existe:
  docker network inspect homelab --format '{{(index .IPAM.Config 0).Subnet}}'
  # Esperado: 172.20.0.0/24

  # Caddy está sano:
  docker inspect caddy --format '{{.Name}}: {{.State.Health.Status}}'
  # Esperado: caddy: healthy

  # Pi-hole resuelve linkding.lan al host (preparar antes en su UI):
  dig +short @192.168.1.241 linkding.lan
  # Esperado: 192.168.1.10  (si no, añadir el registro en Pi-hole y volver)

  # Estructura de directorios y propietario:
  ls -ld /mnt/hd2t/services/linkding
  # Esperado: drwxr-x--- homelab homelab ...

  # Borgmatic ya conoce el dump SQLite (líneas 545–546):
  grep -A1 'name: linkding' /mnt/hd2t/services/backups/borgmatic/config.yaml
  # Esperado: las dos líneas (name + path).
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Gestor de marcadores | **Linkding** | Justificado en §0 punto 1. Talla "S/M" para 1–4 humanos. |
| Imagen Docker | **`sissbruecker/linkding`** (upstream) | Justificado en §0 punto 2. Multi-arch incluyendo `linux/arm64`. Bundle Python + uWSGI + nginx + supervisord. |
| Tag de imagen | **`1.36.0`** (no `latest`, no `1` rolling) | Misma regla del homelab. Cada minor de Linkding puede traer migraciones Django. Pinning fuerza al operador a leer release notes antes de subir. Watchtower actualizará a versiones puntuales nuevas (subiendo el tag tracker). |
| Backend de BD | **SQLite** (`LD_DB_ENGINE=sqlite` por defecto) | Justificado en §0 punto 3. PostgreSQL como variante opt-in (§12.2). |
| Política de Watchtower | **`enable: "true"`** (etiqueta sin sobreescribir el default) | Justificado en §0 punto 6 y en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2, línea 466. Hook `pre-update` opt-in en §12.6 si el operador prefiere dump previo automatizado. |
| Arquitectura | `linux/arm64` (Pi 5) | Manifest multi-arch oficial de la imagen. |
| Redes Docker | **`homelab`** (bridge externa) | Una sola red. No hay BD lateral que aislar. |
| Modelo de almacenamiento | **Bind mount** sobre `/mnt/hd2t/services/linkding/data/` → `/etc/linkding/data` | Patrón estándar del homelab. Bind mount, no named volume — facilita backup directo, ruta predecible. |
| Reverse proxy | **Caddy** con `lan_internal_tls` + `security_headers`, **sin** `authelia_proxy` | Justificado en §0 punto 4. La extensión usa tokens API; Authelia en `forward_auth` rompería `/api/*`. |
| Hostname interno | **`linkding`** (`container_name`) | Caddy llama `http://linkding:9090`. |
| Puerto interno | **`9090`** (default de la imagen) | uWSGI escucha en `9090/tcp` por configuración interna del bundle. **No** se publica al host. |
| Subdominio LAN | **`linkding.${LAN_DOMAIN}`** (típicamente `linkding.lan`) | Convención del homelab. Subdominio dedicado. |
| Subdominio Tailscale | **`linkding.${TS_DOMAIN}`** (preparado, descomentar tras [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) | Mismo patrón que el resto del homelab. |
| `LD_CSRF_TRUSTED_ORIGINS` | **`https://linkding.${LAN_DOMAIN},https://linkding.${TS_DOMAIN}`** | Justificado en §0 punto 8. Ambos orígenes se declaran desde el día 1; el alias Tailscale empieza a funcionar cuando Caddy active su bloque. |
| `LD_LOG_X_FORWARDED_FOR` | **`True`** | Linkding registra la IP real (de la cabecera `X-Forwarded-For` que Caddy inyecta) en lugar de la IP de Caddy. Útil para auditar logins desde la admin de Django. |
| `LD_REQUEST_TIMEOUT` | **`30`** (segundos) | Default razonable para "guardar marcador" (Linkding hace HEAD/GET al añadir, para extraer título). En Pi 5 con conexión doméstica, 30 s cubre el 99 % de los casos sin colgar la UI. |
| `LD_DISABLE_BACKGROUND_VALIDATION` | **`False`** (default) | Linkding revalida URLs cada 24 h en background. Detecta link-rot. Tarea cron interna del contenedor. |
| `LD_DISABLE_URL_VALIDATION` | **`False`** (default) | Linkding rechaza URLs malformadas al guardar. Útil para evitar typos. |
| `LD_FAVICON_PROVIDER` | **`google`** (default) | Linkding usa el servicio de favicons de Google (`https://www.google.com/s2/favicons?domain=...`) como fallback. Implica tráfico saliente a Google por cada nuevo dominio guardado. Variante self-hosted (`duckduckgo`) o `disabled` documentada en §12.7. |
| `LD_ENABLE_AUTH_PROXY` | **`False`** (default) | Auth nativa de Linkding. Cambiar a `True` solo en la variante §12.5 con Authelia delante (rompe la extensión, ver §0 punto 4). |
| `LD_SUPERUSER_NAME` | `admin` | Bootstrap del primer usuario al primer arranque. Se renombra en §7.1. |
| `LD_SUPERUSER_PASSWORD` | **Generada** con `openssl rand -base64 32` y custodiada en `secrets/superuser_password` | Justificado en §0 punto 10. Rotada desde la UI tras el primer login. |
| Healthcheck del contenedor | **`wget -qO- http://127.0.0.1:9090/health`** | Endpoint canónico de Linkding 1.27+. Devuelve `200 OK` con texto `OK`. Sin auth. |
| `cap_drop: ALL` + `no-new-privileges` | Patrón estándar del homelab ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6) | Linkding no necesita ningún capability. uWSGI corre como `www-data` sin privilegios. |
| Stack name (Compose) | **`linkding`** | Coherente con `~/homelab/stacks/linkding/`. Aparece como project name en `docker compose ls`. |

---

## 1. Resumen de la arquitectura

Resumen visual (la flecha indica la dirección del tráfico):

```
                 ┌──────────────────────────────────────────────────┐
                 │  Cliente (navegador del operador, móvil, ext.)   │
                 │  https://linkding.lan/  ó  https://linkding.ts/  │
                 └──────────────────────────────────────────────────┘
                                       │  HTTPS (TLS interno Caddy)
                                       ▼
                 ┌──────────────────────────────────────────────────┐
                 │  Caddy  (stack proxy, host)                      │
                 │  - lan_internal_tls + security_headers           │
                 │  - reverse_proxy http://linkding:9090            │
                 │  - X-Forwarded-* automáticos                     │
                 │  (sin authelia_proxy — ver §0 punto 4)           │
                 └──────────────────────────────────────────────────┘
                                       │  HTTP plano (red Docker)
                                       ▼
   red Docker  ┌──────────────────────────────────────────────────┐
   `homelab`   │  linkding  (sissbruecker/linkding:1.36.0)        │
   (bridge)    │  - uWSGI :9090 (Django app)                      │
               │  - cron interno: revalidación URLs               │
               │  - SQLite con WAL (db.sqlite3)                   │
               │  - user www-data (UID 33:33)                     │
               └──────────────────────────────────────────────────┘
                                       │  bind mount
                                       ▼
                 ┌──────────────────────────────────────────────────┐
                 │  /mnt/hd2t/services/linkding/                    │
                 │  ├── .env             (chmod 600 root:homelab)   │
                 │  ├── data/                                       │
                 │  │   ├── db.sqlite3       (33:33, 0640)          │
                 │  │   ├── db.sqlite3-wal                          │
                 │  │   ├── db.sqlite3-shm                          │
                 │  │   ├── favicons/        (33:33, 0750)          │
                 │  │   └── previews/        (33:33, 0750)          │
                 │  └── secrets/                                    │
                 │      └── superuser_password  (root:homelab 600)  │
                 └──────────────────────────────────────────────────┘
                                       │
                                       ▼  Borgmatic (root, systemd)
                 ┌──────────────────────────────────────────────────┐
                 │  Repo Borg en /mnt/hd2t/backups/                 │
                 │  + offsite (Backblaze B2, definido en Fase 7)    │
                 │  Hook sqlite_databases.linkding ya escrito:      │
                 │  borgmatic/config.yaml líneas 545–546.           │
                 └──────────────────────────────────────────────────┘
```

Componentes:

- **Stack directory**: `~/homelab/stacks/linkding/` (versionado en git: `docker-compose.yml`, `.env.example`, `README.md` corto).
- **Datos**: `/mnt/hd2t/services/linkding/` (NO versionado, con `.env` real, secretos y datos persistentes).
- **Contenedores**: solo uno (`linkding`).
- **Red**: solo `homelab` (bridge externa, declarada en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3).
- **Backup**: Borgmatic ya configurado vía `sqlite_databases` ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6, líneas 545–546). Más detalles en §9 de este documento.
- **Caddy**: bloque `linkding.{$LAN_DOMAIN}` + (futuro) `linkding.{$TS_DOMAIN}` en `~/homelab/stacks/proxy/Caddyfile`.

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/linkding/.env.example`:

```dotenv
# ─── Imagen ─────────────────────────────────────────────────────────────────
LINKDING_IMAGE=sissbruecker/linkding:1.36.0

# ─── Identidad / TZ ─────────────────────────────────────────────────────────
TZ=Europe/Madrid

# ─── Dominios (deben coincidir con el bloque de Caddy) ─────────────────────
LAN_DOMAIN=lan
TS_DOMAIN=tail-XXXXX.ts.net

# ─── Paths ──────────────────────────────────────────────────────────────────
DATA_PATH=/mnt/hd2t/services/linkding/data

# ─── Linkding (LD_*) ────────────────────────────────────────────────────────
# Orígenes confiables para CSRF (ver §0 punto 8). MUY IMPORTANTE.
LD_CSRF_TRUSTED_ORIGINS=https://linkding.lan,https://linkding.tail-XXXXX.ts.net

# Logs IP real del cliente (cabecera X-Forwarded-For inyectada por Caddy).
LD_LOG_X_FORWARDED_FOR=True

# Timeout de las requests salientes de Linkding (al añadir un marcador,
# Linkding hace HEAD/GET para extraer título).
LD_REQUEST_TIMEOUT=30

# Validación periódica de URLs (background, una vez al día por marcador).
LD_DISABLE_BACKGROUND_VALIDATION=False

# Validación al guardar (rechaza URLs malformadas).
LD_DISABLE_URL_VALIDATION=False

# Provider de favicons. 'google' usa el servicio de Google
# (tráfico saliente a www.google.com por cada nuevo dominio).
# Alternativas: 'duckduckgo', 'disabled'. Ver §12.7.
LD_FAVICON_PROVIDER=google

# Auth proxy (Authelia, etc). 'False' = login nativo Django.
# 'True' = la cabecera 'Remote-User' del proxy define al usuario.
# Cambiar SOLO en la variante §12.5.
LD_ENABLE_AUTH_PROXY=False

# Bootstrap del primer superusuario. Solo se aplica si la BD aún no tiene
# usuarios. Tras el primer arranque la password se rota desde la UI (§7.1)
# y este valor queda como histórico (no afecta a la cuenta ya creada).
LD_SUPERUSER_NAME=admin
LD_SUPERUSER_PASSWORD=__GENERATE_AND_REPLACE__

# ─── Resource limits (opcional, valores por defecto razonables en Pi 5) ───
LINKDING_MEMORY_LIMIT=512m
LINKDING_CPU_LIMIT=1.5
```

> **`__GENERATE_AND_REPLACE__`**: marcador placeholder. La password real se genera en §3.3 con `openssl rand -base64 32`, se persiste en `/mnt/hd2t/services/linkding/secrets/superuser_password` y se inyecta vía `sed` en el `.env` real. Nunca se commitea al repo.

### 2.2. `.env` real (`/mnt/hd2t/services/linkding/.env`)

El `.env` real es **una copia** del `.env.example` con los valores rellenos:

- `TS_DOMAIN`: el alias asignado por Tailscale (`tail-XXXXX.ts.net`) — el operador ya lo conoce de [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) §3 (preparación), aunque el bloque del Caddyfile siga comentado.
- `LD_CSRF_TRUSTED_ORIGINS`: ambos orígenes con `https://`, sin trailing slash, separados por coma.
- `LD_SUPERUSER_PASSWORD`: el plaintext generado en §3.3 (sí, en plaintext en el `.env` con `chmod 600`; al primer arranque Linkding lo lee, crea el usuario en BD con hash PBKDF2-SHA256, y a partir de §7.1 la fuente de verdad pasa a ser la BD; el `.env` queda como referencia histórica).

`chmod 600 root:homelab` para que solo `root` y el usuario `homelab` puedan leerlo (Docker corre como root y consume el `env_file` antes del arranque del contenedor).

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` (§4) usa **dos** mecanismos:

1. **`env_file: /mnt/hd2t/services/linkding/.env`** — Compose carga el `.env` y todas las `LD_*` se exportan al entorno del contenedor automáticamente. La imagen upstream las lee en su `entrypoint.sh` y configura Django.
2. **`environment:`** — re-declara variables clave (`TZ`, `LD_CSRF_TRUSTED_ORIGINS`, etc.) **explícitamente**, por dos motivos: (a) `docker compose config` muestra siempre la lista efectiva interpolada, útil para debugging; (b) el contrato del stack queda visible en el YAML sin abrir el `.env`.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
mkdir -p ~/homelab/stacks/linkding
cd ~/homelab/stacks/linkding
# Aquí vivirá: docker-compose.yml, .env.example, README.md.
# Versionable en git. NO commitear el .env real.
```

### 3.2. Crear el árbol de datos persistentes del servicio

```bash
# El path /mnt/hd2t/services/linkding ya existe (creado por bootstrap §4.1
# de 01-sistema/04-estructura-directorios.md). Verificar:
ls -ld /mnt/hd2t/services/linkding
# Esperado: drwxr-x--- 2 homelab homelab ...

# Subdirectorios:
sudo install -d -o 33 -g 33 -m 0750 /mnt/hd2t/services/linkding/data
sudo install -d -o root -g homelab -m 0750 /mnt/hd2t/services/linkding/secrets

# Verificación final:
ls -ln /mnt/hd2t/services/linkding/
# Esperado:
#   drwxr-x---  ... 33 33     ... data
#   drwxr-x---  ... 0  1000   ... secrets
```

> **Por qué `data/` con UID/GID 33** y no `1000`: la imagen oficial de Linkding **no** soporta `PUID`/`PGID` (justificado en §0 punto 7). El proceso uWSGI corre como `www-data` (UID 33) y necesita escribir en `/etc/linkding/data`. Si el directorio se crea con UID 1000, al primer arranque la imagen hace `chown -R 33:33 /etc/linkding/data` (visible en los logs como `entrypoint.sh: setting permissions...`), lo cual funciona pero genera un cambio de propiedad masivo en el bind mount **cada vez** que se reinicia el contenedor — costoso si la BD crece. Crear el directorio ya con `33:33` desde el principio elimina ese ciclo.

> **Por qué `secrets/` con `root:homelab` 0750**: lo escribe Borgmatic (root) y lo lee Compose vía `env_file` (que requiere que el usuario `homelab` pueda al menos atravesar el directorio; el fichero individual queda 600 root:homelab y solo lo abre Docker como root al arrancar el stack).

### 3.3. Generar la password del superusuario

```bash
# Generar y persistir:
sudo install -m 600 -o root -g homelab /dev/null \
  /mnt/hd2t/services/linkding/secrets/superuser_password

openssl rand -base64 32 | sudo tee \
  /mnt/hd2t/services/linkding/secrets/superuser_password >/dev/null

# Verificar permisos:
ls -l /mnt/hd2t/services/linkding/secrets/superuser_password
# Esperado: -rw------- 1 root homelab 45 ... superuser_password

# Anotar el plaintext en KeePassXC + Vaultwarden (entrada
# "Linkding — superusuario admin (bootstrap)"):
sudo cat /mnt/hd2t/services/linkding/secrets/superuser_password
# (copiar a KeePassXC/Vaultwarden y al gestor de passwords del operador).
```

### 3.4. Materializar el `.env` real

```bash
# Copiar plantilla:
sudo install -m 600 -o root -g homelab \
  ~/homelab/stacks/linkding/.env.example \
  /mnt/hd2t/services/linkding/.env

# Editar valores específicos del homelab (LAN_DOMAIN/TS_DOMAIN ya están
# en sus convenciones por defecto, solo sustituir TS_DOMAIN si difiere):
sudo $EDITOR /mnt/hd2t/services/linkding/.env

# Sustituir el placeholder de la password del superusuario:
SUPERUSER_PW="$(sudo cat /mnt/hd2t/services/linkding/secrets/superuser_password)"
sudo sed -i \
  "s|^LD_SUPERUSER_PASSWORD=.*|LD_SUPERUSER_PASSWORD=${SUPERUSER_PW}|" \
  /mnt/hd2t/services/linkding/.env

# Verificar (sin leer el plaintext en pantalla):
sudo grep -c '^LD_SUPERUSER_PASSWORD=__GENERATE_AND_REPLACE__$' \
  /mnt/hd2t/services/linkding/.env
# Esperado: 0  (el placeholder ya no está)

sudo grep -c '^LD_SUPERUSER_PASSWORD=.\+$' \
  /mnt/hd2t/services/linkding/.env
# Esperado: 1
```

### 3.5. Tabla resumen de permisos

| Path | Owner | Modo | Quién escribe | Quién lee |
|---|---|---|---|---|
| `/mnt/hd2t/services/linkding/.env` | `root:homelab` | `0600` | operador (vía `sudo`) | Docker daemon (root) al arrancar el stack |
| `/mnt/hd2t/services/linkding/data/` | `33:33` | `0750` | proceso uWSGI dentro del contenedor | uWSGI; Borgmatic (root) para el dump SQLite |
| `/mnt/hd2t/services/linkding/data/db.sqlite3` | `33:33` | `0640` | uWSGI | uWSGI; Borgmatic (root) |
| `/mnt/hd2t/services/linkding/data/favicons/` | `33:33` | `0750` | uWSGI | uWSGI; Borgmatic |
| `/mnt/hd2t/services/linkding/secrets/` | `root:homelab` | `0750` | operador (vía `sudo`) | Compose (root) |
| `/mnt/hd2t/services/linkding/secrets/superuser_password` | `root:homelab` | `0600` | operador (`tee`) | Compose (root) al primer arranque |

### 3.6. Permisos para el proceso del contenedor

El proceso uWSGI **no necesita root**. La imagen hace `setpriv` a `www-data` (UID 33) tras el bootstrap. La regla de oro: **el operador del homelab (UID 1000) no debe necesitar leer `/mnt/hd2t/services/linkding/data/` directamente**. Cualquier inspección manual usa `sudo`. Si en algún momento se quisiera permitir al usuario `homelab` leerlos sin `sudo` (caso raro), bastaría con `sudo chgrp -R homelab /mnt/hd2t/services/linkding/data && sudo chmod -R g+rX ...`, pero el patrón estándar del homelab no lo requiere.

---

## 4. `docker-compose.yml`

`~/homelab/stacks/linkding/docker-compose.yml`:

```yaml
# ~/homelab/stacks/linkding/docker-compose.yml
# Stack: productivity (../02-docker/02-estructura-compose.md §1.1, fila
# 'productivity' línea 79). Datos en /mnt/hd2t/services/linkding/.

name: linkding

services:
  linkding:
    image: ${LINKDING_IMAGE}
    container_name: linkding
    hostname: linkding
    restart: unless-stopped

    env_file:
      - /mnt/hd2t/services/linkding/.env
    environment:
      TZ: ${TZ}
      LD_CSRF_TRUSTED_ORIGINS: ${LD_CSRF_TRUSTED_ORIGINS}
      LD_LOG_X_FORWARDED_FOR: ${LD_LOG_X_FORWARDED_FOR}
      LD_REQUEST_TIMEOUT: ${LD_REQUEST_TIMEOUT}
      LD_DISABLE_BACKGROUND_VALIDATION: ${LD_DISABLE_BACKGROUND_VALIDATION}
      LD_DISABLE_URL_VALIDATION: ${LD_DISABLE_URL_VALIDATION}
      LD_FAVICON_PROVIDER: ${LD_FAVICON_PROVIDER}
      LD_ENABLE_AUTH_PROXY: ${LD_ENABLE_AUTH_PROXY}
      LD_SUPERUSER_NAME: ${LD_SUPERUSER_NAME}
      LD_SUPERUSER_PASSWORD: ${LD_SUPERUSER_PASSWORD}

    volumes:
      - ${DATA_PATH}:/etc/linkding/data:rw

    networks:
      - homelab

    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true

    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:9090/health >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s

    deploy:
      resources:
        limits:
          memory: ${LINKDING_MEMORY_LIMIT}
          cpus: '${LINKDING_CPU_LIMIT}'

    # Watchtower habilitado por default (ver ../02-docker/04-watchtower.md
    # §4.2 línea 466 — Linkding está en la lista de servicios con
    # auto-update). NO se pone enable: "false".

networks:
  homelab:
    external: true
```

### 4.1. Por qué cada bloque

| Línea | Por qué |
|---|---|
| `name: linkding` | Hace el `compose project name` explícito en lugar de inferirlo del directorio. Aparece en `docker compose ls`. |
| `image: ${LINKDING_IMAGE}` | Tag completo desde `.env`. Cualquier upgrade es grep-able y `git diff`-able. |
| `container_name: linkding` | DNS interno: Caddy llama `http://linkding:9090`. Sin `container_name` Compose le pondría `linkding-linkding-1`. |
| `hostname: linkding` | Alineado con `container_name`. Algunos logs de Django imprimen el hostname; mantenerlos iguales evita confusión. |
| `restart: unless-stopped` | Auto-arranque tras reboot. `unless-stopped` (no `always`) permite parar manualmente para mantenimiento sin que Docker lo levante a la fuerza. |
| **No** `user:` | La imagen upstream gestiona internamente el cambio a `www-data` (UID 33). Forzar `user: "1000:1000"` rompería los permisos esperados por uWSGI (que necesita escribir `db.sqlite3-wal` con propietario coherente). Justificado en §0 punto 7. |
| `env_file:` | Path absoluto, fuera del repo. Justificado en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.1. |
| `environment:` (re-declaración explícita) | Aunque `env_file` ya carga las vars, declararlas aquí **explícitamente** sirve de contrato: `docker compose config` muestra siempre la lista efectiva interpolada. |
| `volumes: - ${DATA_PATH}:/etc/linkding/data:rw` | Único bind mount. `/etc/linkding/data` es el path interno que la imagen oficial espera (`LD_DATA_FOLDER`). |
| `networks: [homelab]` | Sin red interna lateral — Linkding no tiene BD aparte (SQLite en el mismo contenedor). |
| `cap_drop: ALL` | Patrón estándar del homelab. Linkding no necesita ningún capability (uWSGI corre como `www-data`, no abre puertos privilegiados, no toca raw sockets). |
| `security_opt: no-new-privileges:true` | Bloquea `setuid`/`setgid` dentro del contenedor. Aunque la imagen no lo necesita para arrancar, es defensa en profundidad. |
| `healthcheck: /health` | Endpoint canónico de Linkding 1.27+ (sin auth, devuelve `200 OK` con texto `OK`). |
| `start_period: 60s` | Linkding tarda ~10–20 s en arrancar tras la primera vez (corre `python manage.py migrate` en cada arranque). 60 s deja margen sin marcar `unhealthy` falso, especialmente tras un upgrade que añada migraciones nuevas. |
| `deploy.resources.limits` | 512 MB de RAM y 1.5 CPUs. Linkding consume ~150 MB en uso normal; 512 MB cubre picos durante migraciones y validación periódica. La Pi 5 (8 GB) no lo nota. |
| Sin `labels: watchtower.enable: "false"` | Linkding **sí** está en el grupo de auto-update (justificado en §0 punto 6). El default global de Watchtower aplica. |
| `networks.homelab.external: true` | Convención §4.3 de estructura-compose. |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/linkding
docker compose --env-file /mnt/hd2t/services/linkding/.env config
```

La salida debe mostrar:

- `image: sissbruecker/linkding:1.36.0`,
- el bloque `environment` totalmente interpolado (sin `${...}`),
- `LD_CSRF_TRUSTED_ORIGINS: https://linkding.lan,https://linkding.tail-XXXXX.ts.net`,
- `LD_SUPERUSER_PASSWORD: <plaintext largo>` (validar que está, **no** copiar a logs),
- `volumes: - /mnt/hd2t/services/linkding/data:/etc/linkding/data:rw`,
- `networks: homelab` con `external: true`,
- ningún `ports:` publicado (no habrá línea `ports:`),
- ningún `user:` (queda implícito).

Si alguna `LD_*` aparece como `${LD_*}` literal, falta `--env-file`. Si `LD_SUPERUSER_PASSWORD` aparece como `__GENERATE_AND_REPLACE__`, no se ejecutó §3.4 correctamente.

---

## 5. Despliegue

### 5.1. Levantar el stack

```bash
cd ~/homelab/stacks/linkding
docker compose --env-file /mnt/hd2t/services/linkding/.env up -d
```

Esperar ~30 s y verificar:

```bash
docker compose --env-file /mnt/hd2t/services/linkding/.env ps
# Esperado:
#   NAME       IMAGE                          STATUS
#   linkding   sissbruecker/linkding:1.36.0   Up X seconds (health: starting)
```

### 5.2. Estado del contenedor

```bash
# Tras ~60 s, healthy:
docker inspect linkding --format '{{.State.Health.Status}}'
# Esperado: healthy

# Logs del primer arranque:
docker logs linkding 2>&1 | head -50
```

Líneas de interés en los logs (varían entre versiones):

```
[entrypoint] Running database migrations...
Operations to perform:
  Apply all migrations: admin, auth, bookmarks, contenttypes, sessions, users
Running migrations:
  Applying contenttypes.0001_initial... OK
  ...
[entrypoint] Database migrations completed.
[entrypoint] Creating superuser 'admin'...
Superuser 'admin' created successfully.
[entrypoint] Starting uWSGI...
*** uWSGI is running in multiple interpreter mode ***
spawned uWSGI master process (pid: 1)
spawned uWSGI worker 1 (pid: 8, cores: 1)
[uwsgi-cron] running cron jobs
```

> **Si NO aparece "Superuser 'admin' created successfully"** y en su lugar dice `Superuser 'admin' already exists, skipping creation`: la BD ya tenía un usuario (no es un primer arranque limpio). En ese caso la password en el `.env` **no** se aplica; la fuente de verdad es la BD existente. El operador entra con la password antigua o la resetea con `docker compose exec linkding python manage.py changepassword admin`.

### 5.3. Verificar ficheros físicos

```bash
sudo ls -la /mnt/hd2t/services/linkding/data/
# Esperado:
#   -rw-r-----  1  33  33  ...  db.sqlite3
#   -rw-r-----  1  33  33  ...  db.sqlite3-shm
#   -rw-r-----  1  33  33  ...  db.sqlite3-wal
#   drwxr-x---  2  33  33  ...  favicons
#   drwxr-x---  2  33  33  ...  previews    (si existe; algunas versiones lo crean lazy)

# Tamaño inicial:
sudo du -sh /mnt/hd2t/services/linkding/data/
# Esperado: ~5 MB (SQLite vacía + estructura).
```

### 5.4. Smoke check antes de publicar por Caddy

```bash
# Health endpoint accesible desde la red Docker:
docker exec caddy wget -qO- http://linkding:9090/health
# Esperado: OK

# Login form HTML accesible:
docker exec caddy wget -qO- http://linkding:9090/login/ | grep -c '<form'
# Esperado: ≥ 1

# La app responde con HTML válido (status 200):
docker exec caddy wget -S -qO /dev/null http://linkding:9090/login/ 2>&1 \
  | grep 'HTTP/'
# Esperado: HTTP/1.1 200 OK
```

### 5.5. Backup inicial del estado virgen

Antes de añadir un solo marcador, snapshot del estado limpio:

```bash
# Forzar un run de Borgmatic (incluye el dump SQLite de Linkding):
sudo systemctl start borgmatic.service
sudo journalctl -u borgmatic.service --since '5 min ago' | grep -i linkding
# Esperado: línea "Dumping linkding (sqlite)" o similar.

# Listar el archivo más reciente y verificar que el dump está dentro:
sudo borg list /mnt/hd2t/backups/borg --last 1 --short
# Toma el nombre del último archivo, p. ej. homelab-2025-XX-XX_XX-XX-XX:
LATEST=$(sudo borg list /mnt/hd2t/backups/borg --last 1 --short)
sudo borg list "/mnt/hd2t/backups/borg::$LATEST" \
  | grep linkding
# Esperado: una línea con .../linkding/db.sqlite3 (dump consistente).
```

> **Importante**: si Borgmatic aún no estaba configurado al desplegar Linkding (orden de fases), saltar este paso y volver tras completar [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md). El siguiente run nocturno cogerá la BD vacía.

---

## 6. Integración con Caddy

### 6.1. Añadir el bloque `linkding.{$LAN_DOMAIN}` al `Caddyfile`

Editar `~/homelab/stacks/proxy/Caddyfile` y añadir (después de los bloques ya existentes, antes del `# Tailscale` comentado):

```caddy
# Linkding (../11-productividad/03-linkding.md)
linkding.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    reverse_proxy http://linkding:9090 {
        # Linkding lee X-Forwarded-For (LD_LOG_X_FORWARDED_FOR=True en el .env)
        # para registrar la IP real del cliente en la admin de Django.
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
        header_up Host {host}
    }
}
```

| Línea | Por qué |
|---|---|
| `import lan_internal_tls` | TLS con CA interna ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.2). |
| `import security_headers` | HSTS + X-Frame-Options + X-Content-Type-Options + Referrer-Policy. Linkding sirve sus propias páginas en HTML; ningún iframe externo legítimo. |
| **NO** `import authelia_proxy` | Justificado en §0 punto 4. La extensión usa tokens API; Authelia rompería `/api/*`. |
| `reverse_proxy http://linkding:9090` | Caddy llega por la red `homelab` al contenedor `linkding`. HTTP plano dentro de Docker (Caddy ya hace TLS terminator hacia el navegador). El scheme original (HTTPS) viaja en `X-Forwarded-Proto`. |
| `header_up Host {host}` | Linkding usa el `Host:` para validar `LD_CSRF_TRUSTED_ORIGINS` y para construir URLs absolutas (feeds RSS, exports). Forzarlo evita que Caddy lo reescriba. |

### 6.2. Recargar Caddy

```bash
cd ~/homelab/stacks/proxy
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
# Esperado: "Valid configuration".

docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
# Esperado: sin output (éxito).
```

Verificación en logs de Caddy:

```bash
docker logs --tail 50 caddy 2>&1 | grep -E 'linkding|reload'
# Esperado: la nueva ruta aparece y un log "reloaded successfully" o
# "certificate obtained successfully" para linkding.lan.
```

### 6.3. Registro DNS local en Pi-hole

En la UI de Pi-hole (`https://pihole.${LAN_DOMAIN}/admin`):
- **Local DNS Records** → **Add a new domain/IP combination**.
- Domain: `linkding.lan`
- IP: la IP del host donde escucha Caddy (`192.168.1.10` por convención del homelab; ver [`../03-red/02-pihole.md`](../03-red/02-pihole.md)).
- **Add**.

Validación:

```bash
dig +short @192.168.1.241 linkding.lan
# Esperado: 192.168.1.10  (la IP de Caddy/Pi).
```

### 6.4. Probar el acceso desde el navegador

```bash
# Desde un cliente con la CA de Caddy ya instalada (§6.5 de Caddy):
curl -v --resolve linkding.lan:443:192.168.1.10 https://linkding.lan/health
# Esperado: HTTP/2 200, body: "OK"

curl -v --resolve linkding.lan:443:192.168.1.10 https://linkding.lan/login/ \
  | grep -c '<form'
# Esperado: ≥ 1
```

Desde el navegador: `https://linkding.lan` → debería redirigir a `/login/` y mostrar el **formulario de login de Linkding** (logo de Linkding, campos "Username"/"Password"). Si aparece un warning de cert, el `root.crt` de Caddy no está instalado en el navegador — volver a [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §6.5.

### 6.5. Acceso vía Tailscale (preparado, no activo)

Mismo patrón que el resto del homelab: cuando Tailscale esté desplegado ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) se añade un segundo bloque en el `Caddyfile`:

```caddy
# Linkding vía Tailscale (descomentar tras 03-red/05-tailscale.md).
# linkding.{$TS_DOMAIN} {
#     import tailscale_tls linkding
#     import security_headers
#     reverse_proxy http://linkding:9090 {
#         header_up X-Real-IP {remote_host}
#         header_up X-Forwarded-Proto {scheme}
#         header_up X-Forwarded-For {remote_host}
#         header_up Host {host}
#     }
# }
```

`LD_CSRF_TRUSTED_ORIGINS` ya incluye `https://linkding.${TS_DOMAIN}` desde el día 1 (§2.1), así que el bloque funciona sin reiniciar el contenedor — basta con recargar Caddy.

Hasta entonces, el acceso fuera de casa pasa por Tailscale al hostname `pi.${TS_DOMAIN}` y desde ahí a `linkding.lan` vía el resolver DNS local de Tailscale.

---

## 7. Configuración post-despliegue

### 7.1. Login del operador y rotación de la password del superusuario

1. Abrir `https://linkding.lan/login/` desde el navegador del operador (con la CA de Caddy instalada).
2. Login con:
   - **Username**: `admin` (el `LD_SUPERUSER_NAME` del `.env`).
   - **Password**: el plaintext custodiado en `/mnt/hd2t/services/linkding/secrets/superuser_password` (también en KeePassXC + Vaultwarden tras §3.3).
3. Click en **Settings** (icono engranaje, esquina superior derecha) → **General**.
4. Sección **Profile**: rellenar el **Display Name** del operador. El campo "Email" puede quedar vacío (no hay SMTP, no se usará).
5. Sección **Password**: introducir la password actual + una **nueva** password fuerte (≥ 16 caracteres, alta entropía). **Save**.
6. Anotar la nueva password en KeePassXC + Vaultwarden con la entrada "Linkding — admin operador" (el plaintext del `.env` queda obsoleto desde este momento; la fuente de verdad es la BD).
7. Cerrar sesión y volver a entrar con la nueva password (validación end-to-end).

> **NO se renombra el username** `admin`: Django/Linkding permite cambiar el `username` solo desde la admin (`/admin/auth/user/`), pero hacerlo invalida la entrada en `secrets/superuser_password` como fallback de bootstrap. La práctica del homelab es mantener `admin` como username y rotar solo la password.

### 7.2. Configurar settings del sitio

**Settings** → **General**:

- **Items per page**: 30 (default razonable).
- **Theme**: gusto del operador. **Auto** (sigue el sistema) suele funcionar bien.

**Settings** → **Bookmarks**:

- **Display URL**: **ON** — útil para ver de un vistazo de qué dominio es cada marcador.
- **Permanent notes**: **ON** si el operador planea anotar contexto largo en cada marcador (las notas se renderizan en Markdown).

**Settings** → **Integrations**:

- **Enable web archive snapshot integration**: **OFF** (default). Si se activa, Linkding hace requests a Wayback Machine al guardar cada marcador, generando tráfico saliente y latencia.
- **Enable single-file snapshot integration**: **OFF** por ahora. Activarlo requiere un servicio adicional (singlefile binario o contenedor) que el homelab no despliega de serie. Variante en §12.4.

### 7.3. Generar el token API para la extensión del navegador

1. **Settings** → **Integrations** → **REST API**.
2. Click en **Show token** (Linkding genera el token al primer click — antes solo muestra el placeholder).
3. Copiar el token (formato: 40 caracteres alfanuméricos).
4. Anotar en KeePassXC + Vaultwarden con la entrada "Linkding — API token operador" + el navegador donde se va a usar (un token por dispositivo si el operador quiere granularidad).

> **Rotación**: si se sospecha compromiso del token, **Settings → REST API → Reset token**. La extensión deja de funcionar hasta que se actualice con el token nuevo. Linkding **no** soporta múltiples tokens por usuario en la versión actual; solo uno. Si se necesitan tokens separados por dispositivo, crear usuarios distintos (uno por dispositivo) en §7.5.

### 7.4. Instalar la extensión del navegador

**Firefox**: [Linkding extension en addons.mozilla.org](https://addons.mozilla.org/en-US/firefox/addon/linkding-extension/).
**Chromium/Chrome/Edge**: [Linkding extension en Chrome Web Store](https://chrome.google.com/webstore/detail/linkding-extension/beakmhbijpdhipnjhnclmhgjlddhidpe).

Configurar tras la instalación:

1. Click en el icono de la extensión → **Options**.
2. **Linkding base URL**: `https://linkding.lan` (sin trailing slash, scheme HTTPS).
3. **API Token**: pegar el token de §7.3.
4. **Test connection** → debería mostrar "Connection successful" + el username del operador. Si falla:
   - "Untrusted certificate": la CA de Caddy no está instalada en el navegador. Volver a [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §6.5.
   - "401 Unauthorized": el token está mal copiado.
   - "Network error": Pi-hole no resuelve `linkding.lan` o el firewall del cliente bloquea. Verificar `dig +short @<pihole-ip> linkding.lan`.
   - "CORS / Origin checking failed": `LD_CSRF_TRUSTED_ORIGINS` mal configurado. Releer §0 punto 8 y §2.

5. Probar guardar la primera URL (icono de la extensión en cualquier página) — debería aparecer en la UI tras refrescar.

### 7.5. Crear cuentas para familiares (opcional)

Linkding soporta multi-usuario. Para añadir un usuario:

1. **Settings** (esquina superior derecha) → **Users** → **+ Add user**.
2. **Username** + **Password** inicial (anotar en Vaultwarden, compartir con el familiar por canal seguro).
3. **Save**.
4. El familiar entra con esas credenciales y, **al primer login**, debería rotar la password desde **Settings → General → Password**.

> Linkding **no** comparte marcadores entre usuarios por defecto (cada usuario tiene su propia colección, aislada). Si se quiere compartir un marcador concreto, marcarlo como **Shared** al guardarlo — solo entonces los demás usuarios lo ven. Útil para "esto le interesa a la pareja".

### 7.6. Verificación post-despliegue

- [ ] `linkding.lan` carga el formulario de login (sin pasar por Authelia — eso es **lo correcto** aquí).
- [ ] Login con la nueva password del operador funciona.
- [ ] La password antigua del `.env` **ya no** funciona.
- [ ] La extensión del navegador conecta y guarda marcadores OK.
- [ ] Al guardar un marcador desde la extensión, aparece en `https://linkding.lan` tras refrescar.
- [ ] Los favicons de los dominios guardados se descargan (esperar 30 s tras el primer marcador y refrescar).
- [ ] **Settings → REST API** muestra el token correcto.
- [ ] **Settings → General** muestra el display name configurado.

---

## 8. Verificación

### 8.1. Contenedor sano y permisos correctos

```bash
docker inspect linkding --format '{{.State.Health.Status}}'
# Esperado: healthy

docker inspect linkding --format '{{.State.StartedAt}}'
# Esperado: timestamp reciente.

# Permisos del bind mount:
sudo ls -ln /mnt/hd2t/services/linkding/data/db.sqlite3
# Esperado: -rw-r----- 1 33 33 ... db.sqlite3

# Tamaño tras unos días de uso:
sudo du -sh /mnt/hd2t/services/linkding/data/
# Esperado: < 50 MB para uso normal con cientos de marcadores.
```

### 8.2. Linkding no escucha al host

```bash
sudo ss -tlnp | grep ':9090'
# Esperado: vacío (el contenedor escucha en 9090 pero solo dentro de la red Docker).

# Confirmación: el puerto sí lo abre el proceso uwsgi DENTRO del contenedor:
docker exec linkding ss -tlnp 2>/dev/null | grep ':9090' || \
  docker exec linkding netstat -tlnp 2>/dev/null | grep ':9090'
# Esperado: 0.0.0.0:9090 LISTEN PID/uwsgi
```

### 8.3. UI accesible vía Caddy

```bash
curl -sI --resolve linkding.lan:443:192.168.1.10 https://linkding.lan/
# Esperado:
#   HTTP/2 302
#   location: /login/
#   strict-transport-security: max-age=...
#   x-content-type-options: nosniff

curl -sI --resolve linkding.lan:443:192.168.1.10 https://linkding.lan/health
# Esperado: HTTP/2 200
```

### 8.4. API accesible con token

```bash
TOKEN="<el token del operador>"
curl -sH "Authorization: Token ${TOKEN}" \
  --resolve linkding.lan:443:192.168.1.10 \
  https://linkding.lan/api/bookmarks/?limit=1 \
  | jq '.count'
# Esperado: número entero (count total de marcadores; puede ser 0).
```

> Si la respuesta es HTML en lugar de JSON, alguna capa intermedia está interceptando: lo más probable es que se haya añadido `import authelia_proxy` por error al bloque Caddy (releer §6.1). Sin token o con token mal: `{"detail":"Authentication credentials were not provided."}` o `401 Unauthorized`.

### 8.5. Persistencia tras reboot

```bash
# Forzar un reinicio del stack:
cd ~/homelab/stacks/linkding
docker compose --env-file /mnt/hd2t/services/linkding/.env down
docker compose --env-file /mnt/hd2t/services/linkding/.env up -d

# Esperar ~60 s y verificar:
docker inspect linkding --format '{{.State.Health.Status}}'
# Esperado: healthy

# Login + marcadores siguen ahí (la BD persiste en el bind mount).
curl -sH "Authorization: Token ${TOKEN}" \
  --resolve linkding.lan:443:192.168.1.10 \
  https://linkding.lan/api/bookmarks/?limit=1 \
  | jq '.count'
# Esperado: el mismo número que antes del reboot.
```

### 8.6. Backup hooks Borgmatic ejecutándose

```bash
# Último run de Borgmatic:
sudo journalctl -u borgmatic.service --since 'yesterday' \
  | grep -iE 'linkding|sqlite_databases'
# Esperado: línea como "Dumping linkding (sqlite)" sin errores adyacentes.

# Listar el archivo Borg más reciente y confirmar que linkding está dentro:
LATEST=$(sudo borg list /mnt/hd2t/backups/borg --last 1 --short)
sudo borg list "/mnt/hd2t/backups/borg::$LATEST" \
  | grep -E 'linkding/db\.sqlite3|borgmatic.*linkding'
# Esperado: línea(s) con el dump SQLite consistente.
```

### 8.7. Lista de verificación

- [ ] `docker compose ps` muestra `linkding` `Up X (healthy)`.
- [ ] `db.sqlite3` con propietario `33:33`, modo `0640`.
- [ ] `linkding.lan` resuelve a la IP de Caddy desde Pi-hole.
- [ ] `https://linkding.lan/health` devuelve `200 OK`.
- [ ] `https://linkding.lan/login/` muestra el formulario de login HTTPS sin warnings de cert.
- [ ] La extensión del navegador conecta y guarda al menos un marcador.
- [ ] El último Borg incluye `linkding/db.sqlite3` (dump consistente).
- [ ] `LD_SUPERUSER_PASSWORD` del `.env` **ya no** sirve para login (rotada en §7.1).
- [ ] El puerto 9090 **no** está abierto en el host (`ss -tlnp | grep 9090` vacío).

---

## 9. Backup

### 9.1. Qué se respalda y qué no

| Categoría | Path | ¿Se respalda? | Cómo |
|---|---|---|---|
| Base de datos | `/mnt/hd2t/services/linkding/data/db.sqlite3` (+ `-wal`, `-shm`) | **Sí**, vía dump consistente | Borgmatic `sqlite_databases.linkding` (líneas 545–546 de `borgmatic/config.yaml`). El hook usa `sqlite3 ... .backup`, que es seguro frente a writers concurrentes. |
| Favicons | `/mnt/hd2t/services/linkding/data/favicons/` | **No** (regenerable) | Linkding los redescarga del provider configurado (`LD_FAVICON_PROVIDER`) cuando se accede a un marcador y no hay favicon cacheado. |
| Previews / single-file snapshots | `/mnt/hd2t/services/linkding/data/previews/` | **Opcional** | Si el operador activa snapshots (variante §12.4), añadir el path al `source_directories` de Borgmatic. Por defecto, vacío. |
| `.env` | `/mnt/hd2t/services/linkding/.env` | **No** (custodiado en KeePassXC + Vaultwarden) | Contiene la password de bootstrap (ya rotada) y el `LD_CSRF_TRUSTED_ORIGINS`. Reproducible desde el `.env.example` versionado en git. |
| Token API | (vive en `db.sqlite3`, tabla `authtoken_token`) | **Sí**, indirectamente vía dump | Tras restore, el token original sigue siendo válido. La extensión sigue funcionando sin reconfiguración. |
| Logs de uWSGI | (stdout del contenedor, capturados por Docker) | **No** | Rotación gestionada por Docker (`json-file` driver, default config en `daemon.json`). Para retención larga, configurar un sink centralizado (Loki/Promtail en Fase 5+). |

### 9.2. Patrón Borgmatic — respaldo SQLite

Ya escrito anticipadamente en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6 (líneas 537–548). Resumen:

```yaml
sqlite_databases:
  - name: linkding
    path: /mnt/hd2t/services/linkding/data/db.sqlite3
```

Borgmatic ejecuta `sqlite3 /mnt/hd2t/services/linkding/data/db.sqlite3 ".backup '<dump path>'"` antes del snapshot Borg. El dump es **consistente** incluso si Linkding está escribiendo (SQLite usa el WAL para la lectura snapshot). El dump aterriza en `/root/.borgmatic/sqlite_databases/<host>/linkding/db.sqlite3` y se incluye en el archivo Borg automáticamente. Tras el upload a Borg, el dump local se borra (`borgmatic` lo gestiona).

### 9.3. Restore (resumen)

Procedimiento detallado en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8 (patrón unificado para servicios SQLite simples). Resumen para Linkding:

```bash
# 1. Parar el stack:
cd ~/homelab/stacks/linkding
docker compose --env-file /mnt/hd2t/services/linkding/.env down

# 2. Identificar el archivo Borg deseado:
sudo borg list /mnt/hd2t/backups/borg --short | tail -10

# 3. Extraer el dump SQLite del archivo:
LATEST=homelab-2025-XX-XX_XX-XX-XX
sudo mkdir -p /tmp/restore-linkding
cd /tmp/restore-linkding
sudo borg extract \
  "/mnt/hd2t/backups/borg::$LATEST" \
  root/.borgmatic/sqlite_databases

# 4. Sustituir db.sqlite3 (con backup defensivo del actual):
sudo cp /mnt/hd2t/services/linkding/data/db.sqlite3 \
        /mnt/hd2t/services/linkding/data/db.sqlite3.bak-$(date +%s)
sudo cp /tmp/restore-linkding/root/.borgmatic/sqlite_databases/*/linkding/db.sqlite3 \
        /mnt/hd2t/services/linkding/data/db.sqlite3
sudo chown 33:33 /mnt/hd2t/services/linkding/data/db.sqlite3
sudo chmod 0640 /mnt/hd2t/services/linkding/data/db.sqlite3

# 5. Borrar los ficheros WAL/SHM (huérfanos tras el restore):
sudo rm -f /mnt/hd2t/services/linkding/data/db.sqlite3-wal
sudo rm -f /mnt/hd2t/services/linkding/data/db.sqlite3-shm

# 6. Levantar el stack y verificar:
cd ~/homelab/stacks/linkding
docker compose --env-file /mnt/hd2t/services/linkding/.env up -d
sleep 30
docker inspect linkding --format '{{.State.Health.Status}}'
# Esperado: healthy

# 7. Limpiar el restore temporal:
sudo rm -rf /tmp/restore-linkding
```

### 9.4. Smoke test mensual

Un domingo al mes (alineado con el smoke test global de [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §8):

1. Listar el último archivo Borg.
2. Extraer **solo** el dump de `linkding/db.sqlite3` a `/tmp`.
3. Abrirlo con `sqlite3 /tmp/.../db.sqlite3` y ejecutar:
   ```sql
   SELECT COUNT(*) FROM bookmarks_bookmark;
   SELECT COUNT(*) FROM auth_user;
   ```
4. Comparar con el conteo en producción (`docker exec linkding python manage.py shell -c "from bookmarks.models import Bookmark; print(Bookmark.objects.count())"`).
5. Diferencia esperada: 0 o ≤ N (donde N son los marcadores guardados desde el último backup nocturno).

---

## 10. Operaciones cotidianas

### 10.1. Upgrade (Watchtower habilitado)

Linkding está en el grupo de auto-update de Watchtower ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 línea 466). Watchtower hace `docker pull` cada noche a las 04:00 y, si hay imagen nueva, hace `down` + `up -d` automáticamente. Las migraciones Django se ejecutan en el `entrypoint.sh` del nuevo contenedor.

Si el operador prefiere un ritmo manual (variante §12.6 con hook `pre-update`), el procedimiento es:

```bash
# 1. Leer release notes:
# https://github.com/sissbruecker/linkding/releases

# 2. Backup defensivo previo:
sudo systemctl start borgmatic.service

# 3. Actualizar el tag en el .env:
sudo $EDITOR ~/homelab/stacks/linkding/.env.example  # actualizar y commit
sudo $EDITOR /mnt/hd2t/services/linkding/.env

# 4. Pull + up:
cd ~/homelab/stacks/linkding
docker compose --env-file /mnt/hd2t/services/linkding/.env pull
docker compose --env-file /mnt/hd2t/services/linkding/.env up -d

# 5. Verificar migraciones y health:
docker logs --tail 50 linkding
docker inspect linkding --format '{{.State.Health.Status}}'

# 6. Smoke test UI: login + ver lista de marcadores + guardar uno nuevo.
```

> **Rollback** (si el upgrade rompe algo):
> 1. Volver el tag al anterior en el `.env`.
> 2. `docker compose pull && docker compose up -d`.
> 3. Si la migración es **forward-only** (raro pero posible — Django suele ser tolerante), restaurar `db.sqlite3` del último Borg pre-upgrade (§9.3).

### 10.2. Añadir un usuario nuevo

```bash
# Vía UI (recomendado): Settings → Users → + Add user. Ver §7.5.

# Vía CLI (si la UI no responde):
docker compose exec linkding python manage.py createsuperuser
# Pide username, email (vacío OK), password.
```

### 10.3. Reset de password (sin SMTP)

```bash
# Reset de la password del usuario admin (o cualquier otro):
docker compose exec linkding python manage.py changepassword admin
# Pide la nueva password dos veces (oculta).

# Anotar la nueva en KeePassXC + Vaultwarden.
```

### 10.4. Rotar el token API

1. **Settings → Integrations → REST API → Reset token**.
2. Copiar el token nuevo.
3. Actualizarlo en cada cliente (extensión de navegador, scripts CLI, etc.).
4. Anotar el nuevo en KeePassXC + Vaultwarden, marcar el viejo como invalidado.

### 10.5. Importar / exportar marcadores

**Importar** (Netscape HTML, formato estándar de bookmarks de navegador):

1. **Settings → General → Import**.
2. Seleccionar el `.html` exportado de Firefox/Chromium (o de otro Linkding/Wallabag/Shaarli).
3. Linkding parsea, deduplica por URL y crea los marcadores. Las etiquetas del HTML (carpetas) se mapean a tags de Linkding.

**Exportar** (Netscape HTML, idem):

1. **Settings → General → Export**.
2. Linkding genera y descarga `bookmarks.html` con todos los marcadores del usuario.
3. Útil para backup adicional independiente de Borg, o para migrar a otro gestor.

### 10.6. Logs y observabilidad

```bash
# Logs en vivo:
docker logs -f linkding

# Últimas 200 líneas:
docker logs --tail 200 linkding

# Filtrar errores:
docker logs linkding 2>&1 | grep -iE 'error|warning|critical'

# Estado del cron interno (revalidación de URLs):
docker logs linkding 2>&1 | grep -i 'cron\|tasks'
```

Linkding tiene además una **admin de Django** en `/admin/` (no enlazada desde la UI principal). Útil para inspeccionar tablas, sesiones activas, tokens emitidos:

- URL: `https://linkding.lan/admin/`.
- Login con el superusuario.
- Tablas relevantes: `Bookmarks > Bookmark`, `Bookmarks > Tag`, `Authentication and Authorization > Users`, `Auth Token > Tokens`.

> **Cuidado con `/admin/`**: borrar registros desde ahí es **inmediato** y no hay papelera. Para operaciones destructivas, hacer Borg run defensivo previo.

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Solución |
|---|---|---|
| Navegador muestra "CSRF verification failed. Origin checking failed" al hacer login | `LD_CSRF_TRUSTED_ORIGINS` no incluye `https://linkding.lan` o no incluye el scheme. | Releer §0 punto 8 y §2.1. Verificar con `docker exec linkding env \| grep CSRF`. Si falta, editar el `.env`, `docker compose up -d` (recreará el contenedor). |
| La extensión devuelve "Network error" o "Failed to fetch" | DNS interno no resuelve `linkding.lan` o la CA de Caddy no está confiada en el navegador donde corre la extensión. | `dig +short @<pihole> linkding.lan` debe dar la IP de Caddy. Probar `curl https://linkding.lan/health` desde el cliente: si dice "untrusted certificate", instalar `root.crt` ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §6.5). |
| La extensión devuelve `401 Unauthorized` aun con token correcto | Token rotado desde la UI sin actualizar la extensión. | **Settings → REST API → Show token** en la UI, copiar el actual y pegarlo en las opciones de la extensión. |
| `docker logs linkding` muestra `OperationalError: database is locked` repetidamente | SQLite con WAL pero múltiples writers concurrentes (raro en single-user; ocurre con scripts paralelos). | Reducir concurrencia (no lanzar varios `bookmark-cli` a la vez). En última instancia, considerar PostgreSQL (variante §12.2). |
| Tras restore: login falla con la password correcta | El restore mezcló `db.sqlite3` nuevo con `db.sqlite3-wal` viejo. | Borrar `*-wal` y `*-shm` tras restaurar `db.sqlite3` (paso 5 de §9.3) y reiniciar el contenedor. |
| Los favicons no aparecen | `LD_FAVICON_PROVIDER=google` y la red saliente está bloqueada (firewall, Pi-hole bloquea Google). | Cambiar a `LD_FAVICON_PROVIDER=duckduckgo` (variante §12.7) o `disabled` (sin favicons). |
| Watchtower acaba de actualizar y Linkding entra en `unhealthy` | Migración Django nueva tarda más de `start_period: 60s`. | Esperar 2–3 minutos. Si persiste, `docker logs linkding` para ver el output de `manage.py migrate`. Si la migración falla por motivos legítimos (versión incompatible), rollback (§10.1). |
| Se ven URLs `http://localhost:8000` o `http://linkding:9090` en feeds RSS exportados | `Host:` no llega correctamente al backend. | Verificar que el bloque Caddy tiene `header_up Host {host}` (§6.1). |
| Pi-hole no resuelve `linkding.lan` | Falta el registro DNS local en Pi-hole. | UI de Pi-hole → "Local DNS Records" → añadir `linkding.lan → 192.168.1.10` (§6.3). |
| `502 Bad Gateway` desde Caddy | El contenedor `linkding` está parado, en `unhealthy`, o no está en la red `homelab`. | `docker inspect linkding --format '{{.State.Status}} {{json .NetworkSettings.Networks}}'`. Si la red no es `homelab`, releer §4 (`networks: [homelab]` con `external: true`). |

---

## 12. Variantes opt-in

### 12.1. SMTP para emails (reset password, notificaciones)

Linkding/Django soporta SMTP estándar. Si el operador despliega un MTA (Postfix relay) o usa un proveedor externo (Sendgrid, Mailgun, AWS SES), añadir al `.env`:

```dotenv
LD_DJANGO_EMAIL_HOST=smtp.example.com
LD_DJANGO_EMAIL_PORT=587
LD_DJANGO_EMAIL_HOST_USER=linkding@example.com
LD_DJANGO_EMAIL_HOST_PASSWORD=<password>
LD_DJANGO_EMAIL_USE_TLS=True
LD_DJANGO_DEFAULT_FROM_EMAIL=Linkding <linkding@example.com>
```

Las cabeceras `LD_DJANGO_EMAIL_*` corresponden 1:1 con `EMAIL_*` de Django settings. Tras añadirlas, recrear el contenedor (`docker compose up -d`) y probar reset desde **/login/?next=/** → **Forgot password?**.

### 12.2. PostgreSQL en lugar de SQLite

Para >5 usuarios humanos sincronizando muchos marcadores en paralelo (raro en homelab), o si el operador quiere unificar el motor con Paperless-ngx ([`./04-paperless-ngx.md`](./04-paperless-ngx.md), que usa PostgreSQL):

1. Añadir un servicio `postgres-linkding` al `docker-compose.yml` con su propia red interna (`linkding_internal`), patrón idéntico al de Bookstack ([`./02-bookstack.md`](./02-bookstack.md) §0 punto 7).
2. Variables en el `.env`:
   ```dotenv
   LD_DB_ENGINE=postgres
   LD_DB_HOST=postgres-linkding
   LD_DB_PORT=5432
   LD_DB_DATABASE=linkding
   LD_DB_USER=linkding
   LD_DB_PASSWORD=<password>
   ```
3. Migración del estado existente: `docker compose exec linkding python manage.py dumpdata --natural-foreign --natural-primary > /tmp/dump.json` con SQLite, luego `loaddata` con PostgreSQL.
4. Actualizar Borgmatic: mover de `sqlite_databases` a `postgresql_databases` ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6).

> **Recomendación**: no migrar a PostgreSQL salvo necesidad real. SQLite cubre el 99% de los homelabs.

### 12.3. Authelia delante con bypass para `/api/*`

Si el operador prefiere forzar 2FA en el login web aceptando que `/api/*` queda sin Authelia (la extensión sigue funcionando con su token):

1. Añadir `linkding.{{ env "LAN_DOMAIN" }}` a `access_control.rules` de Authelia ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §5):
   ```yaml
   - domain: "linkding.{{ env "LAN_DOMAIN" }}"
     resources:
       - "^/api(/.*)?$"
     policy: bypass
   - domain: "linkding.{{ env "LAN_DOMAIN" }}"
     policy: two_factor
     subject:
       - "group:admin"
   ```
2. En el bloque Caddy de §6.1, añadir `import authelia_proxy` antes del `reverse_proxy`.
3. Recargar Authelia (`docker compose exec authelia kill -SIGHUP 1`) y Caddy.
4. Verificar: `https://linkding.lan/` redirige a Authelia; `https://linkding.lan/api/bookmarks/?limit=1` con token devuelve JSON sin pasar por Authelia.

> **Trade-off**: el operador acepta dos logins en la web (Authelia + Linkding) a cambio de 2FA en el borde. La extensión sigue funcionando sin cambios.

### 12.4. Snapshots single-file (archivado HTML)

Linkding soporta archivar cada marcador como HTML offline usando [singlefile](https://github.com/gildas-lormeau/SingleFile). Útil para evitar link-rot. Coste: cada snapshot ocupa ~500 KB – 5 MB; la BD crece despacio pero el filesystem sí.

1. Desplegar un sidecar con la imagen `singlefile-cli` o usar la integración con un servicio externo.
2. **Settings → Integrations → Single-file snapshot integration** → ON.
3. Configurar el path/URL del binario singlefile.
4. Añadir `/mnt/hd2t/services/linkding/data/previews/` al `source_directories` de Borgmatic.

### 12.5. Auth proxy (Authelia con SSO transparente)

Variante avanzada de §12.3: en lugar de doble login, Linkding **acepta** la cabecera `Remote-User` de Authelia como identidad ya autenticada:

1. En el `.env`:
   ```dotenv
   LD_ENABLE_AUTH_PROXY=True
   LD_AUTH_PROXY_USERNAME_HEADER=Remote-User
   LD_AUTH_PROXY_LOGOUT_URL=https://auth.lan/logout
   ```
2. Caddy debe inyectar la cabecera `Remote-User` con el username devuelto por Authelia (configurar `copy_headers Remote-User` en el snippet `authelia_proxy`).
3. Linkding crea automáticamente el usuario al primer login si no existe.
4. La extensión sigue funcionando con `/api/*` en bypass (§12.3 paso 1).

> **Riesgo**: si el operador pierde el control de Caddy (por error de configuración) y `Remote-User` viene con valor arbitrario, **cualquiera** se loguea como cualquier usuario. Usar solo si Caddy + Authelia están maduros y bien testados en el homelab.

### 12.6. Watchtower con `pre-update` hook (dump SQLite previo)

Para el operador que quiere auto-update pero con dump defensivo en cada ciclo:

1. Crear `~/homelab/stacks/linkding/scripts/pre-update.sh`:
   ```bash
   #!/bin/sh
   set -e
   sqlite3 /etc/linkding/data/db.sqlite3 \
     ".backup '/etc/linkding/data/db.sqlite3.preupdate-$(date +%s)'"
   # Mantener solo los 5 últimos:
   ls -1t /etc/linkding/data/db.sqlite3.preupdate-* 2>/dev/null \
     | tail -n +6 | xargs -r rm -f
   ```
2. Bind-mount el script en `/etc/linkding/data/scripts/pre-update.sh` y añadir las labels:
   ```yaml
   labels:
     com.centurylinklabs.watchtower.lifecycle.pre-update: /etc/linkding/data/scripts/pre-update.sh
     com.centurylinklabs.watchtower.lifecycle.pre-update-timeout: "60"
   ```
3. Watchtower ejecuta el script **dentro** del contenedor antes del `down`, dejando un dump consistente en el bind mount.

> **Coste**: ~5 MB extra por dump, máximo 5 dumps = 25 MB. Despreciable.

### 12.7. Cambiar el provider de favicons

Si el operador quiere evitar tráfico saliente a Google:

```dotenv
LD_FAVICON_PROVIDER=duckduckgo   # alternativa: 'disabled' (sin favicons)
```

DuckDuckGo no rastrea, pero sigue siendo un servicio externo. La opción más privada es `disabled` (sin favicons; la UI muestra un icono genérico).

### 12.8. Acceso solo Tailscale (sin LAN)

Si el operador quiere que `linkding.lan` **no** funcione fuera de Tailscale (caso raro: ya estamos en LAN-only, pero algunos operadores prefieren forzar el flujo Tailscale incluso en casa):

1. **Eliminar** el bloque `linkding.{$LAN_DOMAIN}` del `Caddyfile`.
2. **Activar** solo el bloque `linkding.{$TS_DOMAIN}` (descomentar de §6.5).
3. **Eliminar** el registro DNS local `linkding.lan` de Pi-hole.

Tras esto, el acceso solo funciona desde dispositivos en la tailnet. La extensión del navegador apunta a `https://linkding.${TS_DOMAIN}` y el `LD_CSRF_TRUSTED_ORIGINS` queda con un solo origen (el de Tailscale).

---

## 13. Referencias

- [Linkding — repositorio oficial (GitHub)](https://github.com/sissbruecker/linkding)
- [Linkding — documentación de la imagen Docker](https://github.com/sissbruecker/linkding/blob/master/docs/Install.md)
- [Linkding — variables de entorno (`LD_*`)](https://github.com/sissbruecker/linkding/blob/master/docs/Options.md)
- [Linkding — REST API reference](https://github.com/sissbruecker/linkding/blob/master/docs/API.md)
- [Linkding — extensión Firefox (addons.mozilla.org)](https://addons.mozilla.org/en-US/firefox/addon/linkding-extension/)
- [Linkding — extensión Chrome/Chromium](https://chrome.google.com/webstore/detail/linkding-extension/beakmhbijpdhipnjhnclmhgjlddhidpe)
- [Linkding — releases (release notes para upgrades)](https://github.com/sissbruecker/linkding/releases)
- [Django — `CSRF_TRUSTED_ORIGINS`](https://docs.djangoproject.com/en/stable/ref/settings/#csrf-trusted-origins)
- [Django — `manage.py changepassword`](https://docs.djangoproject.com/en/stable/ref/django-admin/#changepassword)
- [SQLite — Online Backup API (`.backup`)](https://www.sqlite.org/backup.html)
- Documentos relacionados del homelab:
  - [`./01-vaultwarden.md`](./01-vaultwarden.md) — Patrón de servicio sin Authelia delante (clientes API).
  - [`./02-bookstack.md`](./02-bookstack.md) — Patrón de servicio detrás de Authelia (UI-only, contraste con Linkding).
  - [`../03-red/04-caddy.md`](../03-red/04-caddy.md) — Reverse proxy y CA interna.
  - [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) — Por qué Linkding **no** está en `access_control.rules`.
  - [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6 (líneas 545–546) — Hook SQLite ya escrito.
  - [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8 — Patrón de restore para SQLite.
  - [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 (línea 466) — Linkding en el grupo de auto-update.
