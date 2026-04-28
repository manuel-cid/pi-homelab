# Prowlarr

## Descripción

Despliegue de **Prowlarr** ([imagen `lscr.io/linuxserver/prowlarr`](https://docs.linuxserver.io/images/docker-prowlarr/)) como **hub centralizado de indexadores** del *arr stack del homelab. Es la segunda pieza de la **Fase 10 — Gestión de Descargas** y **el cerebro de búsqueda** del flujo: en Prowlarr se configuran **una sola vez** todos los indexadores (públicos y privados, torrent y Usenet), y desde ahí se **sincronizan automáticamente** ([feature *Sync App*](https://wiki.servarr.com/prowlarr/connect-your-apps)) con **Sonarr** ([`./03-sonarr.md`](./03-sonarr.md)) y **Radarr** ([`./04-radarr.md`](./04-radarr.md)). Sin Prowlarr, cada uno de Sonarr y Radarr tendría que mantener su propia lista duplicada de indexadores, sus propias cookies/credenciales, sus propios límites de queries y su propia rotación de definiciones (cuando un tracker cambia su HTML/JSON). Prowlarr concentra todo eso en un único punto.

Este doc cubre, en orden:

1. **Por qué Prowlarr** y no Jackett/NZBHydra2, qué se asume y qué se descarta.
2. **Plan de variables y archivos**: `.env.example` versionable, `.env` real con la `API key` (autogenerada por Prowlarr en el primer arranque) en `/mnt/hd2t/services/prowlarr/.env` (chmod 600), layout de directorios bajo `/mnt/hd2t/services/prowlarr/`.
3. **`docker-compose.yml`** con bind mount de `/config` (respaldable), `networks: [homelab]`, **sin** publicar el puerto `9696` (Caddy llega por DNS interno).
4. **Despliegue, onboarding inicial** (recoger la `API key` de `config.xml`, configurar `Authentication = Forms`, password fuerte).
5. **Integración con Caddy** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3): bloque `prowlarr.{$LAN_DOMAIN}` con `forward_auth` a Authelia (`prowlarr.{$LAN_DOMAIN}` ya está reservado en [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §4 — política `two_factor`, `group:admin`).
6. **Configuración del proceso**: añadir indexadores (públicos como 1337x, RARBG-mirror, TheRARBG; privados según las cuentas del operador), sincronización con Sonarr/Radarr (Apps → Sync), gestión de categorías por app, *test* de cada indexador, *user-agent* y *query response time limit*.
7. **Backup**: `/config/prowlarr.db` + `/config/config.xml` (la API key vive ahí) + `/config/Backups/` propios de Prowlarr; el resto (`logs/`, `MediaCover/`) excluido por regenerable. Política coherente con [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8.
8. **Operaciones cotidianas**: añadir un indexador nuevo, actualizar definiciones (Prowlarr lo hace solo cada 24 h), depurar un indexador roto, ver el log de búsquedas, gestionar cookies de trackers privados.
9. **Variantes opt-in**: **FlareSolverr** sidecar para indexadores tras Cloudflare (1337x, TorrentGalaxy, etc.), Usenet (Newznab) si el operador tiene cuenta, *Indexer Proxy* vía Tailscale Exit Node, notificaciones a Telegram cuando un indexador falla, *Custom Tags* para limitar los indexadores que cada app sincroniza.

> **Alcance de red**: la **UI web** (9696) **solo se accede vía Caddy** sobre `https://prowlarr.lan` (LAN) o `https://prowlarr.${TS_DOMAIN}` (Tailscale). **No hay puerto publicado al host.** Prowlarr **no necesita conexiones entrantes** desde internet — solo hace **salientes** a los indexadores (HTTPS hacia los trackers/Usenet). Es el más "tranquilo" del *arr stack en cuanto a red.

> **Diferencia con Transmission**: en [`./01-transmission.md`](./01-transmission.md) tuvimos que abrir `51413/tcp+udp` en el router para BitTorrent P2P. **Prowlarr no abre nada**: solo HTTPS saliente. Si el operador eliminó incluso ese único port forward (ver §12.1 de Transmission), Prowlarr funciona igual.

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), grupo `homelab` (GID 1000), `/mnt/hd2t/` montado, directorio `/mnt/hd2t/services/prowlarr/` ya creado por el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4 (loop "Fase 10 — Descargas").
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` creada, convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5 — bind mounts; §4.3 — red compartida; §5.2 — `PUID=1000`/`PGID=1000` para acceso a `/config`).
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) con `lan_internal_tls` operativo y la red `homelab` accesible. Sin Caddy no hay HTTPS para la UI de Prowlarr y el `forward_auth` de Authelia no aplica.
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con la posibilidad de añadir registros A locales (`prowlarr.lan` → IP de la Pi).
- **Authelia desplegado** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)) con el dominio `prowlarr.{$LAN_DOMAIN}` ya registrado en `access_control.rules` (política `two_factor`, `subject: group:admin`). En el `Caddyfile` el bloque de Prowlarr usa `forward_auth http://authelia:9091`.
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Prowlarr lleva la etiqueta `com.centurylinklabs.watchtower.enable: "true"` por política — la imagen LSIO publica `latest` con cambios menores y la BD SQLite de Prowlarr (`/config/prowlarr.db`) es **forward-compatible** entre versiones (Prowlarr corre migraciones automáticamente al subir; un downgrade puede romper, pero no se hace nunca).
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) para que `/mnt/hd2t/services/prowlarr/config/` sea archivado. Prowlarr cae en la sección **§13.3 (servicios SQLite simples)** del doc de Borgmatic y el patrón de [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8 (uso de `sqlite3 .backup` para evitar copia inconsistente).
- **Disco hd2t libre**: ~50 MB para `/mnt/hd2t/services/prowlarr/config/`. La BD de Prowlarr crece **muy poco** (definiciones de indexadores: ~10 MB; historial de búsquedas: ~1 KB por entrada; logs: ~5 MB rotados por LSIO).
- **Cuentas en trackers privados** (opcional, si el operador las tiene): credenciales o API key de cada uno. Prowlarr las almacena en `prowlarr.db` cifradas con la `app secret` de `config.xml`. **No** las metemos en `.env`: las introduce el operador directamente en la UI.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Hub de indexadores | **Prowlarr** | Reemplaza a Jackett en el *arr stack moderno. Mantenido por el equipo *arr (mismo lenguaje y filosofía que Sonarr/Radarr/Lidarr), tiene **sync automático** a las apps, soporta torrent **y** Usenet en el mismo backend, y consolida la auth de cada indexador. Jackett funciona pero está en mantenimiento mínimo y no tiene sync — habría que duplicar la URL del indexador en cada *arr. NZBHydra2 es la alternativa Java, mejor para Usenet puro pero peor integrado con Sonarr/Radarr. Prowlarr es la elección por defecto consolidada en la documentación oficial Servarr (https://wiki.servarr.com/prowlarr). |
| Imagen | **`lscr.io/linuxserver/prowlarr`** | LSIO publica el binario empaquetado con `s6-overlay`, healthchecks integrados y soporte de `PUID/PGID`. Hay imagen oficial `prowlarr/prowlarr` (de `hotio.dev` en realidad), pero LSIO es la que se usa de forma consistente en el resto del homelab (Transmission, Sonarr, Radarr, Jellyfin…). Cambiar entre LSIO/hotio significa renumerar UID interno y romper permisos del bind mount. |
| Tag de imagen | **`1.21.2.4649-ls116`** (no `latest`, no `develop`) | LSIO publica tags semánticos `<upstream>-<lsio_revision>` desde el branch `master` de Prowlarr. Pinear el patch fuerza al operador a leer https://github.com/linuxserver/docker-prowlarr/releases antes de actualizar. Watchtower está habilitado pero respeta el tag fijo (compara digest del mismo tag, ver [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §3); para subir de minor el operador edita `.env` y hace `docker compose pull`. |
| Arquitectura | `linux/arm64` (Pi 5) | Manifest multi-arch oficial. La Pi 5 es nativa 64-bit. |
| Red Docker | **`homelab`** (bridge, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.3). **Sin** `9696` publicado. | Caddy llega a la UI por nombre (`http://prowlarr:9696`). Sonarr/Radarr llegan a la API por nombre (`http://prowlarr:9696/api/v1/...`). Sin tráfico entrante desde internet, no hay justificación para publicar el puerto al host. |
| Modelo de almacenamiento | **Bind mount** `/mnt/hd2t/services/prowlarr/config:/config` | Patrón estándar del homelab. Bind mount → backup directo con Borg, ruta predecible y portabilidad. |
| Bibliotecas / descargas | **No se montan** | Prowlarr **no descarga** ni **toca ficheros multimedia**. Solo busca metadatos en indexadores y los reenvía a Sonarr/Radarr (que a su vez empujan el `.torrent` a Transmission). No tiene `/downloads`, no tiene `/media`, no tiene `/watch`. Esto es coherente con que su único bind mount sea `/config`. |
| Usuario dentro del contenedor | **`PUID=1000` (homelab) + `PGID=1000` (homelab)** | Coherente con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.2. Prowlarr **no** necesita el grupo `media` (no escribe en `/mnt/hd2t/downloads/` ni en `/mnt/hd2t/media/`); por eso `PGID=1000`, no `1100`. |
| Auth de la UI | **Authelia delante** (Caddy `forward_auth`) **+** auth nativa Forms | Doble defensa. Prowlarr **siempre** usa auth nativa (Forms o Basic) porque desde la `1.0` rechaza arrancar sin auth en redes no-loopback. Authelia añade SSO + 2FA TOTP delante. La API (`X-Api-Key`) **no pasa por Caddy** — Sonarr/Radarr la usan directamente por la red interna `homelab`. |
| `Authentication Method` (Settings → General) | **`Forms (Login Page)`** | `Basic` rompe Authelia (doble basic auth simultáneo confunde al navegador). `External` es para entornos donde Authelia/SSO ya gestiona TODO — no es nuestro caso, queremos defensa en profundidad. |
| `Authentication Required` | **`Disabled for Local Addresses`** | Esto desactiva la auth de Forms para peticiones provenientes de la subred `homelab` Docker (172.20.0.0/24) — exactamente la subred desde la que llegan Sonarr/Radarr. Significa: Authelia delante para humanos vía Caddy, API por la red interna sin auth nativa adicional pero **sí** con `X-Api-Key`. |
| `URL Base` | **vacío** (`/`) | Caddy reenvía `/` directamente a `http://prowlarr:9696/`. No hay path-based routing necesario — cada *arr tiene su propio subdominio (`sonarr.lan`, `radarr.lan`, `prowlarr.lan`). |
| `API Key` | **autogenerada al primer arranque**, expuesta por `.env` después | Prowlarr genera la API key en `/config/config.xml` al primer `docker compose up -d`. La leemos con `xmllint` o `grep`, la metemos en el `.env` real y la consumen Sonarr/Radarr (por la sync app: ver §7.5). El `.env` queda chmod 600. |
| `Log Level` | **`info`** | Default. `debug` solo bajo demanda — los logs los rota LSIO en `/config/logs/`. |
| `Backup Folder` | **`/config/Backups`** (default) | Prowlarr hace backups internos `.zip` con `prowlarr.db` + `config.xml` cada cierto tiempo. Esto **se incluye** en Borg además del backup externo. |
| Sync App | **Habilitado** para Sonarr y Radarr (cuando se desplieguen) | El feature core de Prowlarr. Cualquier indexador añadido aquí aparece automáticamente en los dos *arr en ~1 minuto, mapeando categorías por defecto. |
| FlareSolverr | **Opt-in** (§12.1) | Solo necesario si el operador usa indexadores tras Cloudflare (1337x, TorrentGalaxy, BTDigg). Añade un sidecar Java + headless Chrome (~250 MB de RAM extra) y un punto de fallo más. |
| Backup | **Solo `/config`** vía Borgmatic | Patrón [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8: SQLite con `sqlite3 .backup` (no `cp` directo). |
| Watchtower | **`com.centurylinklabs.watchtower.enable: "true"`** | Por política ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2, sección "stateless o de lectura ligera"): Prowlarr no muta esquema BD entre patches, los upgrades minor son seguros, y un nightly defectuoso (poco probable: LSIO no publica nightly de Prowlarr) sería re-arrancado por `restart: unless-stopped` y alertado por Uptime Kuma. |
| Reverse proxy | **Caddy con `forward_auth` a Authelia** | Doble capa: TLS interno + SSO/2FA. La API para Sonarr/Radarr **no pasa por Caddy** sino por la red interna (`http://prowlarr:9696/api/v1/...` con `X-Api-Key`); por tanto Authelia no estorba a la sync. |
| Acceso remoto | **Vía Tailscale** ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) — `prowlarr.${TS_DOMAIN}` con `tls /data/tailscale-certs/prowlarr.crt /data/tailscale-certs/prowlarr.key` | Sin port forwarding HTTP ni DDNS para la UI. El homelab no necesita exponer Prowlarr a internet. |

---

## 1. Resumen de la arquitectura

```
                            Internet (HTTPS saliente, sin entrante)
                              ▲
                              │ búsquedas a indexadores:
                              │   1337x.to, nyaa.si, etc.
                              │ (HTTPS, user-agent rotado)
                              │
                  ┌───────────┴────────────────────┐
                  │   Pi 5 (host)  192.168.1.x     │
                  │   sin puertos publicados       │
                  └────────────────┬───────────────┘
                                   │
                                   ▼ docker network: homelab (172.20.0.0/24)
                  ┌────────────────────────────────────┐
                  │            Prowlarr                │
                  │   (este doc, :9696 INTERNO)        │
                  │                                    │
                  │  /config (RW) ─► /mnt/hd2t/services/prowlarr/config/
                  │     ├── prowlarr.db   (SQLite)
                  │     ├── config.xml    (API key)
                  │     ├── Backups/      (zips internos)
                  │     └── logs/
                  └─┬───────────────────────┬──────────┘
                    │                       │
                    │ http://prowlarr:9696  │ http://prowlarr:9696/api/v1/...
                    │   (UI)                │   (API, X-Api-Key)
                    ▼                       ▼
            ┌──────────────┐          ┌──────────────┐
            │    Caddy     │          │ Sonarr/Radarr│
            │ prowlarr.lan │          │ (sync app)   │
            │      ▲       │          └──────────────┘
            │      │       │
            │  forward_auth│
            │      │       │
            │      ▼       │
            │   Authelia   │   (../04-seguridad/01-authelia.md)
            └──────────────┘
                    ▲
                    │
              Operador (web)
              ─► https://prowlarr.lan
                 [Authelia OTP]
                 [Prowlarr Forms login (cacheado)]
```

Lo crítico de este diagrama:

1. **Tres rutas distintas, tres niveles de auth distintos.**
   - **Operador → UI**: pasa por Caddy → Authelia (cookie SSO + 2FA TOTP) → Prowlarr (Forms login, cacheado en el navegador).
   - **Sonarr/Radarr → API**: van por la red interna `homelab` directamente al puerto `9696` del contenedor — Caddy no la ve, Authelia no la ve. Su credencial es el `X-Api-Key` de Prowlarr.
   - **Prowlarr → Internet (indexadores)**: HTTPS saliente, sin Authelia ni Caddy en medio. Cada indexador tiene su propia auth (API key, cookie, login form), gestionada en el propio Prowlarr.
2. **Sin puerto entrante.** Prowlarr es el primer servicio del homelab que no necesita ninguna excepción a la regla "no `ports:` publicados al host". Las búsquedas a indexadores son **outbound** (HTTPS 443 hacia internet, gestionado por la NAT del router como cualquier conexión saliente).
3. **API key separada de la sesión Forms.** El flujo humano (Forms cacheado) y el flujo máquina (`X-Api-Key`) son **completamente independientes**. Cambiar la password del usuario `homelab` no invalida la API key, y rotar la API key (§10.5) no echa al operador de la UI.
4. **El backup interno y el externo no se duplican.** Prowlarr genera `.zip` en `/config/Backups/` cada 7 días por defecto; ese mismo directorio lo respalda Borg como parte de `/config/`. Es redundancia barata: si el operador necesita recuperar de hace 6 días pero Borg solo tiene la de hoy, los `.zip` internos son una segunda red.

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/prowlarr/.env.example`:

```env
# ~/homelab/stacks/prowlarr/.env.example
# Versión control: ~/homelab/stacks/prowlarr/.env.example
# Valores reales en /mnt/hd2t/services/prowlarr/.env (chmod 600).
# La PROWLARR_API_KEY se rellena DESPUÉS del primer arranque, leyéndola de
# /mnt/hd2t/services/prowlarr/config/config.xml (§5.3).

# --- Comunes del homelab ---
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
TZ=Europe/Madrid

# --- Dominios internos (consistentes con dns/.env y proxy/.env) ---
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Prowlarr ---
# https://github.com/linuxserver/docker-prowlarr/releases
# Lista de cambios upstream: https://github.com/Prowlarr/Prowlarr/releases
PROWLARR_IMAGE_TAG=1.21.2.4649-ls116

# Hostname público (sin esquema). Usado en Caddyfile y en Prowlarr → URL Base.
PROWLARR_HOSTNAME=prowlarr
PROWLARR_LAN_HOST=prowlarr.lan
PROWLARR_TS_HOST=prowlarr.tailnet.ts.net

# API key — autogenerada por Prowlarr al primer arranque.
# Se rellena tras leer /mnt/hd2t/services/prowlarr/config/config.xml.
# Sonarr/Radarr la consumen por la sync app (../10-descargas/03-sonarr.md §7.X).
PROWLARR_API_KEY=__rellenar_tras_primer_arranque__

# Subred de la red `homelab` (../02-docker/02-estructura-compose.md §4.1).
# Prowlarr necesita confiar en esta subred para "Disabled for Local Addresses".
HOMELAB_SUBNET=172.20.0.0/24
```

### 2.2. `.env` real (`/mnt/hd2t/services/prowlarr/.env`)

Primera versión (sin `PROWLARR_API_KEY` aún — la rellenamos en §5.3):

```bash
# Crear el directorio del servicio si no existe (lo crea el bootstrap
# de ../01-sistema/04-estructura-directorios.md §4, paso "Fase 10").
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/prowlarr

# Crear el .env con permisos correctos.
sudo install -o homelab -g homelab -m 600 /dev/null \
  /mnt/hd2t/services/prowlarr/.env

# Volcar contenido inicial (la API key vendrá tras el primer up).
sudo -u homelab tee /mnt/hd2t/services/prowlarr/.env > /dev/null <<'EOF'
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
TZ=Europe/Madrid
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net
PROWLARR_IMAGE_TAG=1.21.2.4649-ls116
PROWLARR_HOSTNAME=prowlarr
PROWLARR_LAN_HOST=prowlarr.lan
PROWLARR_TS_HOST=prowlarr.tailnet.ts.net
PROWLARR_API_KEY=
HOMELAB_SUBNET=172.20.0.0/24
EOF

# Verificar.
ls -l /mnt/hd2t/services/prowlarr/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` (§4) declara `env_file: /mnt/hd2t/services/prowlarr/.env`. Compose carga el fichero **a la hora de interpolar `${...}` en el YAML** y **además** lo expone al proceso del contenedor. Las variables que la imagen LSIO **lee directamente** son:

- `PUID`, `PGID`, `TZ`, `UMASK_SET` (LSIO universal).
- **Nada específico de Prowlarr.** A diferencia de Transmission (que tenía `USER`/`PASS`/`PEERPORT`), la imagen LSIO de Prowlarr no inyecta nada de configuración runtime: todo se gestiona desde la UI o editando `config.xml` a mano. Por eso `PROWLARR_API_KEY` se usa **fuera** del contenedor (en Caddyfile, en `.env` de Sonarr/Radarr) pero **no** dentro de éste.

El resto (`PROWLARR_HOSTNAME`, `PROWLARR_LAN_HOST`, `LAN_DOMAIN`, …) solo se usa **fuera** del contenedor: en el `Caddyfile` y en este `docker-compose.yml`.

> **Por qué `PROWLARR_API_KEY` sí va en `.env`** (a diferencia de la password de Authelia, que es secreto en `/run/secrets/`): es **la única credencial** que Sonarr/Radarr/Homepage necesitan para hablar con Prowlarr. Compartirla por `.env` (chmod 600) es coherente con cómo `TRANSMISSION_RPC_PASSWORD` vive en el `.env` de Transmission. El modelo de amenaza es el mismo: usuario `root` o `homelab` sí ven el secreto, pero ningún otro proceso del sistema lo hace.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
mkdir -p ~/homelab/stacks/prowlarr
cd ~/homelab/stacks/prowlarr
```

### 3.2. Crear el árbol de datos persistentes del servicio

```bash
# /mnt/hd2t/services/prowlarr/  (homelab:homelab 750)
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/prowlarr
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/prowlarr/config
```

LSIO crea el resto de subdirectorios (`logs/`, `Backups/`, `Definitions/`, …) en su entrypoint.

### 3.3. Tabla resumen de permisos

| Ruta | Owner:Group | Modo | Notas |
|---|---|---|---|
| `/mnt/hd2t/services/prowlarr/` | `homelab:homelab` | `750` | Directorio raíz del servicio. Solo `homelab`. |
| `/mnt/hd2t/services/prowlarr/.env` | `homelab:homelab` | `600` | Contiene `PROWLARR_API_KEY`. Solo legible por `homelab` (y `root`). |
| `/mnt/hd2t/services/prowlarr/config/` | `homelab:homelab` | `750` | Datos de Prowlarr: `prowlarr.db`, `config.xml`, `Backups/`, `Definitions/`, `logs/`. Respaldable con `sqlite3 .backup`. |
| `/mnt/hd2t/services/prowlarr/config/prowlarr.db` | `homelab:homelab` | `644` (default LSIO) | BD SQLite con indexadores, apps sincronizadas, history. Backup vía `sqlite3 .backup`, no `cp` ([`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8). |
| `/mnt/hd2t/services/prowlarr/config/config.xml` | `homelab:homelab` | `644` | API key, port, URL base, log level. Texto plano XML. |

### 3.4. Permisos para el proceso del contenedor

LSIO ejecuta el entrypoint como `root` y dentro hace `chown -R abc:abc /config` con `abc` mapeado al `PUID:PGID` del env. Por tanto, **dentro del contenedor** el proceso `Prowlarr` corre como UID 1000, GID 1000.

El primer arranque hará un `chown -R 1000:1000` sobre `/config`. Como Prowlarr no toca grandes volúmenes (solo `~/config`, que tiene ~50 MB), el `chown` tarda ~1 segundo. El `start_period` del healthcheck (60s) lo cubre con sobra.

---

## 4. `docker-compose.yml`

`~/homelab/stacks/prowlarr/docker-compose.yml`:

```yaml
# ~/homelab/stacks/prowlarr/docker-compose.yml
# Stack: prowlarr (hub de indexadores del *arr stack, Fase 10).
# Datos en /mnt/hd2t/services/prowlarr/config/.
# No tiene bibliotecas ni descargas — solo /config.

name: prowlarr

services:
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:${PROWLARR_IMAGE_TAG}
    container_name: prowlarr
    hostname: prowlarr
    restart: unless-stopped
    env_file: /mnt/hd2t/services/prowlarr/.env

    environment:
      # PUID 1000 (homelab), PGID 1000 (homelab). Prowlarr no necesita
      # el grupo `media` (no escribe en /mnt/hd2t/downloads/ ni media/).
      PUID: ${HOMELAB_UID}
      PGID: ${HOMELAB_GID}
      TZ: ${TZ}
      # umask 022 → ficheros 0644, dirs 0755. La BD y config.xml quedan
      # legibles por `homelab` y nadie más (modo 0644 + dir 0755 + chmod 750
      # del padre). Estándar LSIO.
      UMASK_SET: "022"

    volumes:
      # Config respaldable: prowlarr.db (SQLite), config.xml (API key),
      # Backups/, Definitions/ (cache), logs/.
      - /mnt/hd2t/services/prowlarr/config:/config
      # TZ y reloj sincronizados con el host (timestamps en logs).
      - /etc/localtime:/etc/localtime:ro

    # NO PUBLICAR PUERTOS. Caddy llega por DNS interno (http://prowlarr:9696).
    # Sonarr/Radarr llegan por la API por la red `homelab`.
    # Si alguien añade `ports: - "9696:9696"`, romperá el modelo de seguridad
    # (Authelia bypassable saltándose Caddy con curl al host:9696).

    networks:
      - homelab

    # Recursos: Prowlarr arranca con ~150 MB (mono runtime + .NET 6 + sqlite).
    # En reposo se estabiliza en 200-300 MB. Picos durante una sync masiva
    # (40+ indexadores) hasta 500 MB.
    mem_limit: 768m
    mem_reservation: 128m

    # Healthcheck: GET /ping devuelve 200 con `Pong` cuando Prowlarr está vivo.
    # Antes de la 1.20 era /api/v1/system/status (requería API key); en 1.20+
    # /ping es público y suficiente.
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:9696/ping || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 60s

    security_opt:
      - no-new-privileges:true

    labels:
      # Watchtower: actualizar automáticamente.
      # Política: ../02-docker/04-watchtower.md §4.2.
      com.centurylinklabs.watchtower.enable: "true"
      # Para Dozzle: agrupar logs del *arr stack.
      dev.dozzle.group: "arr"

networks:
  homelab:
    external: true
```

### 4.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `name: prowlarr` | Nombre del proyecto Compose. Cada servicio del *arr stack tiene su propio stack folder — un `down` afecta solo a Prowlarr y no para Sonarr/Radarr/Transmission. |
| `image: lscr.io/linuxserver/prowlarr:${PROWLARR_IMAGE_TAG}` | Tag pinned vía `.env`. Vive en LinuxServer Container Registry. |
| `container_name: prowlarr` / `hostname: prowlarr` | Nombre estable para que Caddy llegue por DNS (`reverse_proxy http://prowlarr:9696`) y para que Sonarr/Radarr usen `prowlarr` como host del indexer sync. Sin esto, Compose le pone un nombre tipo `prowlarr-prowlarr-1` y rompe el DNS interno. |
| `env_file: /mnt/hd2t/services/prowlarr/.env` | Carga de variables — patrón estándar del homelab. |
| `environment.PUID` / `PGID` | UID 1000, GID 1000 (escribe en `/config`). **Sin** GID 1100: Prowlarr no toca `/mnt/hd2t/downloads/` ni `/mnt/hd2t/media/`. |
| `environment.TZ` | Prowlarr loguea timestamps en zona local. |
| `environment.UMASK_SET: "022"` | Ficheros nuevos `0644`, directorios `0755`. Prowlarr no comparte fichero con otros UIDs (a diferencia de Transmission/Sonarr/Radarr con grupo `media`). |
| `volumes: /mnt/hd2t/services/prowlarr/config:/config` | Bind mount canónico de la BD. Sin `:Z`/`:z` (no SELinux en Pi OS). |
| `volumes: /etc/localtime:ro` | Sincroniza la zona del host con el contenedor — backup ante un usuario que olvide poner `TZ` en `.env`. |
| **Sin `ports:`** | Patrón canónico del homelab. Caddy llega por DNS interno; el operador no necesita `curl http://localhost:9696` desde el host (puede hacer `docker exec prowlarr curl http://localhost:9696/ping` para debug). |
| `networks: [homelab]` | Solo la red compartida. Caddy ya está ahí; Sonarr/Radarr/Transmission también. |
| `mem_limit: 768m` | Prowlarr ronda 200-300 MB; picos al hacer sync hasta 500 MB. 768 MB de tope deja margen sin pegarse con el resto del homelab. La Pi 5 (8 GB) tiene ~6 GB libres tras descontar el SO; Prowlarr ocupa el ~5%. |
| `mem_reservation: 128m` | Garantía mínima en presión de memoria. |
| `healthcheck` con `curl` a `/ping` | Endpoint público desde Prowlarr 1.20. Devuelve `{"status":"OK","app":"Prowlarr","version":"1.21.2.4649"}` con HTTP 200. Cualquier `5xx` o `Connection refused` marca el contenedor `unhealthy`. `start_period: 60s` cubre el primer arranque (Prowlarr aplica migraciones de BD y carga las definiciones de indexadores; en una Pi 5 tarda ~30s la primera vez). |
| `security_opt: no-new-privileges:true` | Patrón base ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §0). |
| `com.centurylinklabs.watchtower.enable: "true"` | Watchtower opt-in ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2). Prowlarr está en la lista de "stateless o de lectura ligera" porque su BD (40 MB max) tiene migraciones reversibles y la imagen LSIO valida arranque antes de marcar el `latest`. |
| `dev.dozzle.group: "arr"` | Cuando Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)) levante, agrupa Prowlarr, Sonarr, Radarr y Transmission bajo el mismo grupo "arr". |
| `networks.homelab.external: true` | Patrón de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.4: la red se crea **una vez** durante el bootstrap. |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/prowlarr
docker compose --env-file /mnt/hd2t/services/prowlarr/.env config
```

Esperado: salida YAML resuelta sin warnings. Verificar especialmente:

- `image: lscr.io/linuxserver/prowlarr:1.21.2.4649-ls116` (el tag interpolado).
- `PUID: "1000"`, `PGID: "1000"`.
- `networks: [homelab]`.
- **No** debe aparecer ningún `ports:` (si aparece, alguien lo añadió por error).

Si Compose se queja de `version` en el YAML: la spec moderna no necesita `version: "3.x"`; está omitido a propósito.

---

## 5. Despliegue

### 5.1. Levantar el stack

```bash
cd ~/homelab/stacks/prowlarr

# Pull explícito antes del up: separa errores de imagen de errores de runtime.
docker compose --env-file /mnt/hd2t/services/prowlarr/.env pull
docker compose --env-file /mnt/hd2t/services/prowlarr/.env up -d

docker compose ps
# prowlarr   running (starting → healthy ~30s después)
```

### 5.2. Estado del contenedor

```bash
docker inspect prowlarr \
  --format '{{.State.Status}} | {{.State.Health.Status}}'
# running | healthy

docker logs prowlarr --tail 50
```

Logs típicos del primer arranque:

```
[migrations] started
[migrations] no migrations found
─────────────────────────────────────
       _         ()
      | |        |||
   _  | | __  __ ||| ___    LinuxServer.io
  | |_| | \  \/  /  / __|   image  by   :
  | __ | / /\  \ / / __ \   linuxserver.io
  |_| | \____\____\\____\
─────────────────────────────────────
GID/UID
─────────────────────────────────────
User uid:    1000
User gid:    1000
─────────────────────────────────────
[Info] Bootstrap: Starting Prowlarr - /app/prowlarr/bin/Prowlarr.exe
[Info] Bootstrap: Prowlarr X64 v1.21.2.4649 master
[Info] AppFolderInfo: Data folder: /config
[Info] MigrationController: *** Migrating data source=/config/prowlarr.db ***
[Info] MigrationController: *** 1: InitialSetup migrating ***
[Info] MigrationController: *** 2-99: ... migrating ***
[Info] OwinHostController: Listening on http://0.0.0.0:9696
[Info] OwinHostController: Started Prowlarr.
```

Si en lugar de `Listening on http://0.0.0.0:9696` aparece un stack trace de SQLite con `database is locked`, otro proceso está abriendo `prowlarr.db` simultáneamente — generalmente porque hay un Prowlarr antiguo no parado del todo. Solución: `docker compose down`, esperar 5s, `docker compose up -d`.

### 5.3. Recoger la API key autogenerada

Prowlarr genera la API key al arrancar y la escribe en `/config/config.xml`. La leemos y la metemos en el `.env`:

```bash
# Leer la API key generada.
PROWLARR_API_KEY=$(sudo grep '<ApiKey>' /mnt/hd2t/services/prowlarr/config/config.xml \
  | sed -E 's,.*<ApiKey>([^<]+)</ApiKey>.*,\1,')
echo "API key: $PROWLARR_API_KEY"
# Esperado: 32 chars hex, p. ej. a1b2c3d4e5f60718293a4b5c6d7e8f90

# Apuntarla en el password manager bajo "Homelab → Prowlarr API key"
# (la necesitarás al configurar Sonarr/Radarr).

# Inyectarla en el .env (preservando el resto del fichero).
sudo sed -i \
  -e "s|^PROWLARR_API_KEY=.*|PROWLARR_API_KEY=${PROWLARR_API_KEY}|" \
  /mnt/hd2t/services/prowlarr/.env

# Verificar.
sudo grep '^PROWLARR_API_KEY=' /mnt/hd2t/services/prowlarr/.env
```

> **Por qué no la generamos nosotros antes**: Prowlarr **siempre** regenera la API key si encuentra `<ApiKey></ApiKey>` vacío en `config.xml`. Pre-poblar la key en el `.env` no la inyecta automáticamente — habría que editarla manualmente en `config.xml`, parar el contenedor (porque Prowlarr lee `config.xml` solo al arrancar) y volverlo a levantar. Es más simple dejarla autogenerar y leerla.

### 5.4. Onboarding inicial (UI)

A partir de aquí la UI está accesible **internamente** en `http://prowlarr:9696/` desde la red `homelab`. No es accesible desde el host hasta que Caddy esté configurado (§6). Smoke-check sin Caddy:

```bash
# Ping interno (desde otro contenedor en la red homelab).
docker run --rm --network homelab curlimages/curl:latest \
  http://prowlarr:9696/ping
# {"status":"OK","app":"Prowlarr","version":"1.21.2.4649"}

# API authenticada (status del sistema).
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${PROWLARR_API_KEY}" \
  http://prowlarr:9696/api/v1/system/status
# {"appName":"Prowlarr","instanceName":"Prowlarr","version":"1.21.2.4649",...}
```

### 5.5. Crear el primer usuario (Authentication = Forms)

En la UI Prowlarr **fuerza** crear un usuario admin la primera vez que se accede sin auth. Como queremos hacerlo *antes* de que Caddy enrute (para no tener que pasar por Authelia en este paso de bootstrap), hacemos un port-forward temporal al host:

```bash
# Túnel SSH: localhost:9696 → contenedor prowlarr:9696
# (suponiendo que estás trabajando en remoto; en local, ssh -L 9696 desde tu laptop).
ssh -L 9696:172.20.0.X:9696 homelab@pi   # X = IP del contenedor en la red homelab
# Obtener la IP del contenedor:
#   docker inspect prowlarr --format '{{.NetworkSettings.Networks.homelab.IPAddress}}'
```

Abrir `http://localhost:9696/` en el navegador → Prowlarr pide:

- **Authentication Method**: Forms (Login Page).
- **Username**: `homelab` (mismo usuario que Authelia, por consistencia).
- **Password**: el del password manager bajo "Homelab → Prowlarr UI" (32 chars urlsafe).
- **Authentication Required**: **Disabled for Local Addresses** (clave para que Sonarr/Radarr puedan usar la API por la red interna sin pasar por el formulario de login).

Tras guardar, Prowlarr persiste la config en `prowlarr.db` y `config.xml`. Cerrar el túnel SSH:

```bash
# Ctrl+C en la terminal del túnel.
```

> Alternativa sin túnel SSH: configurar Caddy primero (§6), añadir el bloque `prowlarr.lan` **sin** Authelia (comentar el `forward_auth`), hacer el primer login, y luego añadir Authelia y recargar. Es más pasos pero evita el túnel.

---

## 6. Integración con Caddy

### 6.1. Añadir el bloque `prowlarr.{$LAN_DOMAIN}` al `Caddyfile`

`~/homelab/stacks/proxy/Caddyfile`, sección de bloques de host (siguiendo el patrón de §4.3 de [`../03-red/04-caddy.md`](../03-red/04-caddy.md)):

```caddy
# ----- Prowlarr (../10-descargas/02-prowlarr.md) -----
prowlarr.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Authelia delante: 2FA TOTP obligatorio (group:admin), ../04-seguridad/01-authelia.md §4.
    forward_auth http://authelia:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }

    reverse_proxy http://prowlarr:9696 {
        # Prowlarr no necesita rewrite — sirve la UI en /.
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
    }
}
```

Recargar Caddy:

```bash
docker exec proxy caddy reload --config /etc/caddy/Caddyfile
```

### 6.2. Trusted proxies en Prowlarr

Prowlarr soporta `Settings → General → Reverse Proxy → Trusted Proxies`. **No es estrictamente necesario** porque la red `homelab` es interna y Prowlarr no toma decisiones de seguridad basadas en `X-Forwarded-For` (a diferencia de Authelia, que sí lo hace). Pero por higiene, añadir `172.20.0.0/24` evita warnings en `logs/prowlarr.txt`:

UI → Settings → General → Security → **Trusted Proxies**: `172.20.0.0/24`. Save.

### 6.3. Registro DNS local en Pi-hole

`https://pihole.lan/admin/` → **Local DNS → DNS Records**:

| Domain | IP Address |
|---|---|
| `prowlarr.lan` | `192.168.1.x` (IP fija de la Pi) |

Verificar:

```bash
dig +short prowlarr.lan @192.168.1.2
# 192.168.1.x   (IP de la Pi)
```

### 6.4. Probar el acceso

Desde un equipo de la LAN con la CA interna confiada (paso 6.5 de [`../03-red/04-caddy.md`](../03-red/04-caddy.md)):

```
https://prowlarr.lan
```

Flujo esperado:

1. **Authelia** redirige a `https://auth.lan/?rd=https://prowlarr.lan/`.
2. Login con usuario `homelab` (con grupo `admin`).
3. **2FA TOTP** (configurado en el primer login a Authelia, [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)).
4. Tras OK, Caddy reenvía a `http://prowlarr:9696/` y **Prowlarr no vuelve a pedir login** porque la cookie de Forms está cacheada (si es el primer login: la pide una vez y luego ya queda).

> **Por qué doble auth visible solo el primer día**: el navegador cachea la cookie de Forms `Prowlarr` por 30 días, así que tras el primer login solo se ve Authelia. Si el operador limpia cookies o cambia de navegador, ve los dos formularios consecutivos. La password de Forms se rota desde la UI (Settings → General → Security → Password) y la API key con la regeneración de §10.5.

### 6.5. Por qué Authelia delante de Prowlarr por defecto

Igual que Transmission y por las mismas razones (§6.5 de [`./01-transmission.md`](./01-transmission.md)), Prowlarr solo se usa por **navegador** del operador para administrar indexadores. No hay apps móviles oficiales de Prowlarr (la flota Sonarr/Radarr ya cubre el caso de "ver qué se ha encontrado" desde el móvil). Por tanto:

- **Authelia delante**: el ataque "alguien en mi LAN encontró `prowlarr.lan` y ataca el login de Forms" se queda en la pantalla de Authelia con 2FA.
- **No interfiere con Sonarr/Radarr**: ellos hablan al puerto interno 9696 con `X-Api-Key`, **sin** pasar por Caddy ni Authelia.
- **No interfiere con búsquedas externas**: Prowlarr expone también un endpoint Newznab/Torznab por indexador (`/9/api?...`) que Sonarr/Radarr llaman directamente — esos van por la red interna, sin Caddy.

### 6.6. Acceso vía Tailscale (preparado)

Cuando Tailscale esté operativo ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)), añadir al `Caddyfile`:

```caddy
prowlarr.{$TS_DOMAIN} {
    import tailscale_tls prowlarr
    import security_headers

    # Authelia también delante en Tailscale (no es un "remoto de confianza").
    forward_auth http://authelia:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }

    reverse_proxy http://prowlarr:9696 {
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
    }
}
```

---

## 7. Configuración post-despliegue

La mayoría de la configuración va por la UI (Prowlarr no expone variables de entorno para indexadores ni apps; es BD-driven).

### 7.1. Settings → General

| Sección | Campo | Valor recomendado | Notas |
|---|---|---|---|
| Host | `Bind Address` | `*` | Default. Bind a todas las interfaces (dentro del contenedor solo escucha el `lo` y la IP del bridge `homelab`, así que `*` no implica exposición real). |
| Host | `Port Number` | `9696` | Default. **No cambiar** — coincide con el `EXPOSE` de la imagen LSIO y con `http://prowlarr:9696` del Caddyfile y la sync app. |
| Host | `URL Base` | (vacío) | Caddy reenvía `/` directamente. |
| Host | `Enable SSL` | `Off` | TLS lo gestiona Caddy. Activarlo aquí significaría doble TLS (innecesario y rompe la red interna). |
| Security | `Authentication Method` | `Forms (Login Page)` | (ver §5.5). |
| Security | `Authentication Required` | `Disabled for Local Addresses` | Permite que Sonarr/Radarr pasen sin form-auth (siguen necesitando `X-Api-Key`). |
| Security | `Trusted Proxies` | `172.20.0.0/24` | (ver §6.2). |
| Logging | `Log Level` | `Info` | Default. `Debug` solo bajo demanda. |
| Updates | `Branch` | `master` | Default. **No** seleccionar `develop` — el `latest` de LSIO ya empaqueta `master`. |
| Updates | `Automatic` | `On` (vía Watchtower) | Watchtower hace el upgrade del contenedor; la opción "Automatic" interna de Prowlarr (que *desempaqueta* updates dentro del contenedor) **no es relevante** en imágenes Docker — lo gestiona el ciclo de re-pull de imagen. Dejar en off para evitar confusión. |
| Updates | `Mechanism` | `Docker` | Etiqueta solo descriptiva en imágenes Docker. |
| Backup | `Folder` | `/config/Backups` | Default. Borg lo respaldará dentro de `/config`. |
| Backup | `Interval` | `7 days` | Default. Generación de `.zip` interno cada semana. |
| Backup | `Retention` | `28 days` | Default. ~4 zips guardados. |

### 7.2. Settings → Indexers — añadir indexadores

Prowlarr permite añadir indexadores **públicos** (sin login) y **privados** (con cuenta y API key/cookie).

#### 7.2.1. Indexadores públicos (ejemplo)

```
Settings → Indexers → Add Indexer ([+])

Por nombre:
- 1337x          (Cloudflare-protected → requiere FlareSolverr, §12.1)
- Nyaa           (anime, sin Cloudflare)
- TheRARBG       (mirror RARBG, recomendado tras el cierre del original)
- TorrentGalaxy  (Cloudflare → FlareSolverr)
- LimeTorrents   (público, sin Cloudflare)
- BitSearch      (meta-buscador)
```

Por cada indexador:

1. Click en el nombre.
2. Tab **Settings** → revisar `Categories` (Prowlarr ya pre-mapea correctamente Movies/TV/Anime/Books/Music).
3. Tab **General** → Tags: añadir tag `public` para diferenciarlos en la sync (§7.5).
4. **Test** → debe devolver "Test successful".
5. **Save**.

#### 7.2.2. Indexadores privados (ejemplo)

Si el operador tiene cuenta en un tracker privado:

```
Settings → Indexers → Add Indexer ([+]) → "<nombre del tracker>"

Settings:
- API Key (o Username + Password, según el tracker)
- Categories (heredadas de la definición; ajustar si el tracker tiene
  categorías custom)
- Tags: privado, según preferencia

Test → Save.
```

> **Cookies**: algunos trackers privados (RED, Orpheus) requieren capturar la cookie del navegador. Prowlarr tiene un campo "Cookie" en cada indexador; pegar el valor del header `Cookie` capturado en DevTools del navegador. La cookie caduca al desconectarse: anotar la fecha de captura y rotar cuando deje de funcionar (Prowlarr alertará con "Indexer X is unavailable" en Notifications).

### 7.3. Settings → Indexers — testing masivo

```
Settings → Indexers → Test All Indexers (botón en la barra superior)
```

Resultado esperado: cada indexador en verde. Si alguno falla:

- **Cloudflare challenge**: necesita FlareSolverr (§12.1).
- **Authentication failed**: rotar cookie/API key.
- **Indexer is dead**: el dominio del tracker está caído. Prowlarr **no** lo desactiva solo — hay que ir a la UI y desactivar manualmente para que no rompa búsquedas.

### 7.4. Settings → Apps — registrar Sonarr/Radarr (cuando se desplieguen)

Esta sección **se aplica después** de desplegar Sonarr ([`./03-sonarr.md`](./03-sonarr.md)) y Radarr ([`./04-radarr.md`](./04-radarr.md)). Aquí la dejamos documentada para que sirva de referencia desde sus docs respectivos.

```
Settings → Apps → Add Application ([+]) → Sonarr

Name:           Sonarr
Sync Level:     Add and Remove Only      ← recomendado
Tags:           (vacío o "tv-sonarr")
Prowlarr Server: http://prowlarr:9696
Sonarr Server:   http://sonarr:8989
ApiKey:          <api key de Sonarr — se obtiene del .env de Sonarr>

Test → Save.
```

Con `Sync Level: Add and Remove Only`, Prowlarr **solo añade y quita indexadores** en Sonarr; los ajustes locales que el operador haga en Sonarr (categorías custom, prioridades) se respetan. Alternativa más agresiva: `Full Sync` (sobrescribe todo en Sonarr).

Idéntico para Radarr, con `Radarr Server: http://radarr:7878`.

### 7.5. Tags — limitar qué indexadores se sincronizan a qué app

Por defecto Prowlarr sincroniza **todos los indexadores** a **todas las apps**. Si el operador quiere "1337x solo a Sonarr" o "MAM solo a Radarr para libros", se usan tags:

1. Indexador → Tags: `tv-sonarr`.
2. App (Sonarr) → Sync Tags: `tv-sonarr`.

Solo los indexadores con el tag `tv-sonarr` se sincronizan a Sonarr.

Patrón recomendado para empezar:

| Tag | Aplica a | Significado |
|---|---|---|
| `public` | indexadores públicos (1337x, Nyaa, …) | Sirven para localizar contenido genérico de TV/cine. |
| `private-general` | tracker privado generalista | Sin filtro de tipo. |
| `anime` | Nyaa, AnimeTosho, … | Solo se sincroniza a Sonarr (no a Radarr). |

Sonarr → Sync Tags: `public, private-general, anime`. Radarr → Sync Tags: `public, private-general` (sin anime).

### 7.6. Notifications

Prowlarr tiene su propio sistema de notificaciones (Telegram, Email, Discord, ntfy, …) que se dispara en eventos de "Indexer Failed". Configurar al menos uno:

```
Settings → Notifications → Add Connection → Telegram
- Bot Token: <token>
- Chat Id:   <chat>
- Notification Triggers:
  ☑ On Health Issue
  ☑ On Health Issue Resolved
  ☑ On Application Update
  ☐ On Grab           (genera mucho ruido si Sonarr/Radarr buscan a saco)
```

Los `Health Issue` cubren "Indexer X is unavailable" — es la alerta crítica para detectar trackers caídos antes de que rompan Sonarr/Radarr.

### 7.7. Aplicar y verificar

```bash
# Verificar que Prowlarr ha persistido las apps:
sudo sqlite3 /mnt/hd2t/services/prowlarr/config/prowlarr.db \
  "SELECT Name, ApiKey, BaseUrl FROM Applications;"
# Sonarr|<sonarr_api_key>|http://sonarr:8989
# Radarr|<radarr_api_key>|http://radarr:7878
```

> **Cuidado al hacer queries directas a `prowlarr.db`**: hacer `sqlite3 ... write` con el contenedor corriendo puede corromper la BD. Para read-only basta con `sudo sqlite3 prowlarr.db ".dump"`.

---

## 8. Verificación

### 8.1. Contenedor sano

```bash
docker compose ps
# prowlarr   running (healthy)
docker inspect prowlarr --format '{{.State.Health.Status}}'
# healthy
```

### 8.2. Prowlarr no escucha al host (solo dentro de la red `homelab`)

```bash
# Desde dentro del contenedor: sí escucha 9696.
docker exec prowlarr ss -tnlp | grep ':9696'
# tcp   LISTEN  0  100  *:9696   *:*   users:(("Prowlarr",pid=...,fd=...))

# Desde el host: 9696 NO publicado.
ss -tnlp | grep ':9696'   # vacío (correcto)
```

Si `ss -tnlp | grep ':9696'` en el host devuelve algo, alguien añadió `ports: - "9696:9696"` al compose. Quitarlo y `docker compose up -d`.

### 8.3. UI accesible vía Caddy

```bash
curl -ks https://prowlarr.lan/ -o /dev/null -w '%{http_code}\n'
# 302    (redirect a Authelia)

# Forzando un user-agent que pasa el filtro (Authelia hace forward_auth a /api/authz/forward-auth):
curl -ks -L -c /tmp/jar https://prowlarr.lan/ | head -5
# Esperado: HTML del login de Authelia.
```

Desde un navegador con la CA interna confiada:

1. `https://prowlarr.lan` → redirect a Authelia.
2. Login + TOTP → redirect a Prowlarr.
3. La UI de Prowlarr carga.

### 8.4. API operativa (autenticada)

```bash
# Desde otro contenedor de la red `homelab`:
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${PROWLARR_API_KEY}" \
  http://prowlarr:9696/api/v1/system/status \
  | jq '.version, .branch, .runtimeVersion'
# "1.21.2.4649"
# "master"
# "6.0.36"   (.NET 6 runtime)
```

Sin API key:

```bash
docker run --rm --network homelab curlimages/curl:latest \
  http://prowlarr:9696/api/v1/system/status -o /dev/null -w '%{http_code}\n'
# 401   (correcto: la API exige X-Api-Key incluso con "Disabled for Local Addresses",
#        que solo desactiva el form-auth; X-Api-Key sigue siendo obligatorio).
```

### 8.5. Búsqueda de prueba (sin Sonarr/Radarr aún)

Una vez añadido al menos un indexador (§7.2):

```bash
# Buscar "Big Buck Bunny" (legal, dominio público).
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${PROWLARR_API_KEY}" \
  "http://prowlarr:9696/api/v1/search?query=Big+Buck+Bunny&type=search" \
  | jq '.[] | {title: .title, indexer: .indexer, size: .size, seeders: .seeders}' \
  | head -40
# Resultados de los indexadores activos.
```

### 8.6. Sync con Sonarr/Radarr (cuando estén desplegados)

```bash
# Desde Prowlarr → forzar un sync manual:
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${PROWLARR_API_KEY}" \
  -X POST http://prowlarr:9696/api/v1/applications/applicationsync
# (HTTP 202)

# Verificar en Sonarr (cuando exista):
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${SONARR_API_KEY}" \
  http://sonarr:8989/api/v3/indexer | jq '.[].name'
# Lista de indexadores propagados desde Prowlarr.
```

### 8.7. Persistencia tras reboot

```bash
sudo reboot
# (esperar)
ssh homelab@pi
docker compose -f ~/homelab/stacks/prowlarr/docker-compose.yml ps
# prowlarr   running (healthy)

# Indexadores siguen activos:
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${PROWLARR_API_KEY}" \
  http://prowlarr:9696/api/v1/indexer | jq '.[] | .name'
```

### 8.8. Lista de verificación

- [ ] Contenedor `prowlarr` está `running (healthy)`.
- [ ] Puerto `9696` **no** está publicado en el host (`ss -tnlp | grep 9696` vacío).
- [ ] `https://prowlarr.lan` redirige a Authelia, login con TOTP funciona, UI de Prowlarr carga.
- [ ] API responde `200` con `X-Api-Key` correcta y `401` sin ella.
- [ ] Al menos un indexador añadido y "Test" en verde.
- [ ] Notifications configurado (Telegram o equivalente).
- [ ] `PROWLARR_API_KEY` está en `/mnt/hd2t/services/prowlarr/.env` (chmod 600).
- [ ] Tras reboot, Prowlarr arranca solo y los indexadores siguen activos.

---

## 9. Backup

### 9.1. Qué se respalda y qué no

| Ruta | Backup | Por qué |
|---|---|---|
| `/mnt/hd2t/services/prowlarr/config/prowlarr.db` | **Sí** (vía `sqlite3 .backup`) | BD principal: indexadores, apps, history, tags. Sin esto se pierde toda la configuración, hay que re-añadir los ~10 indexadores y re-vincular Sonarr/Radarr. |
| `/mnt/hd2t/services/prowlarr/config/prowlarr.db-shm` / `-wal` | No (parte del backup atómico) | Ficheros de WAL de SQLite. `sqlite3 .backup` consolida WAL en `.db` antes de copiar; los `-shm`/`-wal` actuales no necesitan respaldarse aparte. |
| `/mnt/hd2t/services/prowlarr/config/config.xml` | **Sí** | API key, port, log level, branch. Recuperarlo permite que Sonarr/Radarr sigan funcionando con la **misma** API key tras restore. Sin esto, hay que rotarla en los tres clientes. |
| `/mnt/hd2t/services/prowlarr/config/Backups/*.zip` | **Sí** (regenerable, pero barato) | Backups internos de Prowlarr. Borg los deduplica entre runs. ~5 MB cada uno × 4 = 20 MB. Gratis incluirlos. |
| `/mnt/hd2t/services/prowlarr/config/Definitions/` | No (regenerable) | Cache de definiciones de indexadores (HTML scrapers, plantillas Newznab). Prowlarr las redescarga al arrancar si faltan. |
| `/mnt/hd2t/services/prowlarr/config/logs/` | No (regenerable) | Logs operacionales. No tienen valor histórico fuera de debug puntual. |
| `/mnt/hd2t/services/prowlarr/config/MediaCover/` | No (regenerable) | Posters/thumbnails de indexadores. Prowlarr los redescarga al detectar falta. |
| `/mnt/hd2t/services/prowlarr/.env` | **Sí** (vía `/mnt/hd2t/backups/configs/`) | Contiene `PROWLARR_API_KEY`. Sin esto, hay que rotarla y reconfigurar Sonarr/Radarr al restore. |

### 9.2. Patrón Borgmatic — respaldo SQLite

Coherente con [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8 ("Servicios SQLite simples"). El hook pre-backup hace `sqlite3 prowlarr.db ".backup '/tmp/prowlarr.bak'"` para evitar copia inconsistente:

`~/homelab/stacks/borgmatic/borgmatic.d/prowlarr.yaml` (o sección dentro del config global de Borgmatic):

```yaml
# Sección dentro del config global. Coherente con ../07-backups/03-backup-docker-volumes.md §4.8.

before_backup:
  - sudo -u homelab docker exec prowlarr sh -c \
      'sqlite3 /config/prowlarr.db ".backup /config/Backups/prowlarr-prebackup.db"'

source_directories:
  # ... otras rutas ...
  - /mnt/hd2t/services/prowlarr/config

# La BD viva (con WAL en uso) sigue siendo respaldada por el include genérico,
# pero Borg deduplica frente a la copia consistente de Backups/prowlarr-prebackup.db.

exclude_patterns:
  - /mnt/hd2t/services/prowlarr/config/logs
  - /mnt/hd2t/services/prowlarr/config/MediaCover
  - /mnt/hd2t/services/prowlarr/config/Definitions
```

### 9.3. Restore (resumen)

```bash
# 1. Parar el contenedor.
docker compose -f ~/homelab/stacks/prowlarr/docker-compose.yml stop

# 2. Mover el config actual a un lado (por seguridad).
sudo mv /mnt/hd2t/services/prowlarr/config /mnt/hd2t/services/prowlarr/config.old

# 3. Restaurar /mnt/hd2t/services/prowlarr/config/ desde Borg.
borgmatic extract --archive latest \
  --path /mnt/hd2t/services/prowlarr/config \
  --destination /

# 4. Restaurar el .env.
borgmatic extract --archive latest \
  --path /mnt/hd2t/services/prowlarr/.env \
  --destination /

# 5. Si la BD viva quedó corrupta tras el `mv`, restaurar la consistente:
sudo cp /mnt/hd2t/services/prowlarr/config/Backups/prowlarr-prebackup.db \
        /mnt/hd2t/services/prowlarr/config/prowlarr.db

# 6. Levantar de nuevo.
docker compose -f ~/homelab/stacks/prowlarr/docker-compose.yml up -d

# 7. Verificar.
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${PROWLARR_API_KEY}" \
  http://prowlarr:9696/api/v1/indexer | jq '.[] | .name'
# Lista esperada de indexadores.

# 8. Borrar el config.old si todo OK.
sudo rm -rf /mnt/hd2t/services/prowlarr/config.old
```

### 9.4. Smoke test mensual de restore

```bash
sudo rm -rf /tmp/restore_test
mkdir -p /tmp/restore_test
borgmatic extract --archive latest \
  --path /mnt/hd2t/services/prowlarr/config \
  --destination /tmp/restore_test

# Verificar que prowlarr.db es válida sin levantarla en producción:
sqlite3 /tmp/restore_test/mnt/hd2t/services/prowlarr/config/prowlarr.db \
  "SELECT count(*) FROM Indexers;"
# > 0   (al menos un indexador)

sqlite3 /tmp/restore_test/mnt/hd2t/services/prowlarr/config/prowlarr.db \
  "SELECT count(*) FROM Applications;"
# 2   (Sonarr + Radarr, una vez existan)

# Verificar config.xml:
grep '<ApiKey>' /tmp/restore_test/mnt/hd2t/services/prowlarr/config/config.xml
# <ApiKey>...</ApiKey>

sudo rm -rf /tmp/restore_test
```

---

## 10. Operaciones cotidianas

### 10.1. Upgrade automático (Watchtower)

Política en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md): Watchtower revisa `lscr.io/linuxserver/prowlarr:1.21.2.4649-ls116` cada noche, compara digest de ese tag exacto y actualiza si LSIO ha re-publicado el tag (típicamente cuando hay un patch de seguridad del *base image*). Si el operador quiere saltar a `1.22.0.4700-ls120`, edita `PROWLARR_IMAGE_TAG` en `.env`, hace `docker compose pull && docker compose up -d` y revisa logs por si hubiera migración. Prowlarr 1.x es compatible hacia delante; el `prowlarr.db` no rompe.

```bash
# Lista de upgrades aplicados por Watchtower:
docker logs watchtower 2>&1 | grep -i prowlarr | tail -20
```

### 10.2. Añadir un indexador nuevo

UI: `Settings → Indexers → [+] → "<nombre>" → llenar credenciales → Test → Save`.

A los pocos segundos, Sonarr/Radarr lo verán por la sync app sin intervención del operador. Verificar:

```bash
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${SONARR_API_KEY}" \
  http://sonarr:8989/api/v3/indexer | jq '.[].name'
# Debe aparecer el nuevo indexador en la lista.
```

### 10.3. Actualizar definiciones de indexadores

Prowlarr actualiza las definiciones automáticamente cada 24 h. Para forzar manualmente:

```bash
# Desde la UI: System → Definitions → Update Definitions.
# O por API:
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${PROWLARR_API_KEY}" \
  -X POST http://prowlarr:9696/api/v1/command \
  -H 'Content-Type: application/json' \
  -d '{"name":"ApplicationCheckUpdate"}'
```

### 10.4. Depurar un indexador que falla

```bash
# 1. Test desde la UI (Settings → Indexers → click → Test).
# 2. Logs específicos del indexador:
docker exec prowlarr cat /config/logs/prowlarr.txt | grep -i '<nombre>' | tail -50

# 3. Si el indexador está bloqueado por Cloudflare:
#    el log mostrará 'cloudflare challenge' o 'cf_clearance' fallido.
#    Solución: añadir FlareSolverr (§12.1).

# 4. Si la API key del tracker está mal:
#    HTTP 401 o 403 en el log. Re-introducir en la UI y test.

# 5. Si el dominio del tracker está caído:
#    "Connection timeout" o "DNS resolution failed".
#    Esperar a que el tracker vuelva, o desactivarlo (no eliminar) en la UI.
```

### 10.5. Rotar la API key

Cuando el operador sospeche compromiso (commit accidental al repo público, fuga de `.env`):

```
UI → Settings → General → Security → API Key → [Reset] → Save → Reload (botón)
```

Tras esto:

1. Sonarr/Radarr **fallarán** al sincronizar hasta que el operador actualice su `Prowlarr → Settings → Apps`.
2. Leer la nueva key del `config.xml` (mismo procedimiento que §5.3) y actualizar el `.env`:

```bash
NEW_KEY=$(sudo grep '<ApiKey>' /mnt/hd2t/services/prowlarr/config/config.xml \
  | sed -E 's,.*<ApiKey>([^<]+)</ApiKey>.*,\1,')
sudo sed -i \
  -e "s|^PROWLARR_API_KEY=.*|PROWLARR_API_KEY=${NEW_KEY}|" \
  /mnt/hd2t/services/prowlarr/.env
```

3. Actualizar Sonarr/Radarr → `Settings → Indexers → Prowlarr → ApiKey` con `NEW_KEY`. (En realidad el sync va de Prowlarr → Sonarr/Radarr, así que el campo a tocar está en Prowlarr → Apps, pero el de origen — el `X-Api-Key` con que Sonarr llega a `prowlarr:9696/api/v1/...` — sí cambia y vive en Sonarr).
4. Reiniciar Sonarr y Radarr para descartar caches.

### 10.6. Ver el log de búsquedas

```bash
# Las últimas 50 búsquedas (con tracker, query, resultados):
docker exec prowlarr tail -100 /config/logs/prowlarr.txt | grep -i 'search\|grab' | tail -50

# O por API (history):
docker run --rm --network homelab curlimages/curl:latest \
  -H "X-Api-Key: ${PROWLARR_API_KEY}" \
  "http://prowlarr:9696/api/v1/history?pageSize=20" | jq
```

### 10.7. Logs

```bash
# En vivo:
docker logs -f prowlarr

# Logs persistidos en /config/logs/:
docker exec prowlarr ls -lh /config/logs/
# prowlarr.txt           (log actual)
# prowlarr.txt.0         (último rotado)
# update.txt             (log de upgrades internos, irrelevante en Docker)
```

LSIO redirige los logs internos al stdout del contenedor, donde Docker los captura y Dozzle los muestra. No hace falta tocar `/config/logs/` salvo para grep histórico.

### 10.8. Comportamiento durante mantenimiento

- **Pi-hole caído**: Prowlarr no resuelve los dominios de los indexadores (DNS interno apunta a Pi-hole), las búsquedas fallan con "DNS resolution failed". **No corrompe nada**: las búsquedas vuelven al recuperar Pi-hole.
- **Caddy caído**: la UI no es accesible, pero **Sonarr/Radarr siguen funcionando**: ellos van por la red interna `homelab`, no por Caddy.
- **Prowlarr caído (OOM, crash)**: Sonarr/Radarr fallarán al buscar nuevos episodios/películas con "Indexer X is unavailable". El `restart: unless-stopped` lo levanta solo. Uptime Kuma alertará.
- **`prowlarr.db` corrupta** (raro pero posible si el host pierde corriente sin parar limpio): Prowlarr se niega a arrancar con `Malformed database`. Restaurar desde `/config/Backups/prowlarr-prebackup.db` (§9.3 paso 5).

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Diagnóstico / Fix |
|---|---|---|
| `https://prowlarr.lan` muestra "502 Bad Gateway" en Caddy | Contenedor Prowlarr caído o `unhealthy`. | `docker compose ps`, `docker logs prowlarr`. |
| Authelia no aparece al ir a `prowlarr.lan`; va directo al login de Forms | El bloque `forward_auth` no está en el `Caddyfile`, o Caddy no se recargó. | Verificar `~/homelab/stacks/proxy/Caddyfile` §6.1, recargar `docker exec proxy caddy reload --config /etc/caddy/Caddyfile`. |
| Tras login Authelia, la UI de Prowlarr pide login de Forms | La cookie de Forms no se ha establecido aún. Hacer login una vez y luego la cachea 30 días. | Normal en el primer acceso. Si persiste tras hacer login y el navegador no envía cookie: comprobar que el dominio del cookie es `prowlarr.lan` (y no `lan` u otro), y que el navegador acepta cookies third-party. |
| Sonarr/Radarr no pueden conectar a Prowlarr ("Unable to connect to Prowlarr") | API key mal configurada en la sync app, o `Trusted Proxies` no incluye `172.20.0.0/24`. | `docker exec sonarr curl -H "X-Api-Key: $PROWLARR_API_KEY" http://prowlarr:9696/api/v1/system/status`. Si devuelve 200, la conexión es OK; si 401, la key está mal. |
| "Test" de un indexador falla con "Cloudflare challenge" | El indexador está tras Cloudflare y necesita FlareSolverr. | Desplegar FlareSolverr (§12.1), añadir el indexer-proxy en Prowlarr y asignarlo al indexador. |
| "Test" de un indexador falla con "Login failed (HTTP 403)" | Cookie de tracker privado caducada, o IP de la Pi en blacklist del tracker. | Re-capturar la cookie del navegador. Si el tracker prohíbe IPs residenciales rotativas, considerar usar Tailscale Exit Node (§12.3). |
| Búsqueda devuelve `429 Too Many Requests` | El tracker tiene rate limit y Prowlarr lo excedió. | UI → Indexer → Settings → "Query Limit" (poner un valor más bajo, p.ej. 60/h). Algunos trackers privados ratean por API key, otros por IP. |
| Sonarr/Radarr ven los indexadores duplicados (cada uno aparece 2 veces) | Sync App fue ejecutado dos veces sin limpiar. | UI Sonarr/Radarr → Settings → Indexers → eliminar duplicados manualmente. Volver a hacer `Sync` desde Prowlarr (no debería duplicar más). |
| Tras un `docker compose down && up`, los indexadores aparecen pero sin datos | El bind mount de `/config` no es correcto o el `chown` del entrypoint LSIO no terminó antes del crash. | Verificar `docker exec prowlarr ls -la /config/` que muestra `prowlarr.db` con owner `abc:abc` (UID 1000). Si está como `root:root`, el contenedor no tuvo permisos para `chown` (revisar el bind `/mnt/hd2t/services/prowlarr/config/` en el host: debe ser `homelab:homelab 750`). |
| `docker logs prowlarr` muestra `database is locked` | Otro proceso (un prowlarr antiguo, o un `sqlite3` interactivo abierto) tiene la BD abierta. | `docker compose down`, `lsof /mnt/hd2t/services/prowlarr/config/prowlarr.db` para ver quién la abre, matar ese proceso, `docker compose up -d`. |
| "Health Issue: Unable to connect to indexer X" persiste tras volver el tracker | Prowlarr cachea el estado por 30 min. | Forzar re-test: UI → Indexer → Test. O reiniciar el contenedor. |
| Búsquedas devuelven 0 resultados aunque el tracker tiene contenido | Categorías mal mapeadas: el indexador devuelve cat `5070` (Anime) pero Sonarr filtra por cat `5000` (TV). | UI → Indexer → Categories: añadir manualmente las cats que el tracker usa. O Sonarr → Indexer → Categories: relajar el filtro. |
| `config.xml` tiene `<ApiKey></ApiKey>` vacío tras un restore | El restore vino de un backup antes del primer arranque. | Levantar Prowlarr (regenera la API key). Leer la nueva, actualizar `.env`. Si Sonarr/Radarr ya estaban configurados con la antigua, rotar también allí. |
| Prowlarr ocupa > 1 GB de RAM | Bug ocasional de mono runtime con muchos indexadores activos (50+). | `docker compose restart prowlarr`. Si recurre, subir `mem_limit` a `1024m` y abrir issue en LSIO. |

---

## 12. Variantes opt-in

### 12.1. FlareSolverr — sortear Cloudflare en indexadores públicos

Indexadores como **1337x**, **TorrentGalaxy**, **BTDigg** y muchos públicos están detrás de Cloudflare con "challenge JS". El scraper de Prowlarr no ejecuta JS y falla. **FlareSolverr** ([https://github.com/FlareSolverr/FlareSolverr](https://github.com/FlareSolverr/FlareSolverr)) es un sidecar con headless Chrome que resuelve el challenge y devuelve la cookie `cf_clearance` válida durante ~30 min.

`~/homelab/stacks/prowlarr/docker-compose.yml`, **añadir** un servicio extra:

```yaml
services:
  prowlarr:
    # ... igual que en §4 ...

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:v3.3.21
    container_name: flaresolverr
    hostname: flaresolverr
    restart: unless-stopped
    environment:
      LOG_LEVEL: info
      LOG_HTML: "false"
      CAPTCHA_SOLVER: none
      TZ: ${TZ}
    networks:
      - homelab
    # No publicar puertos: Prowlarr llega por http://flaresolverr:8191/.
    mem_limit: 512m
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:8191/ || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 60s
    labels:
      com.centurylinklabs.watchtower.enable: "true"
      dev.dozzle.group: "arr"
```

Añadir en Prowlarr:

```
Settings → Indexers → Indexer Proxies → [+] → FlareSolverr

Name:    FlareSolverr
Host:    http://flaresolverr:8191/
Tags:    cloudflare    ← solo los indexadores con este tag usarán FlareSolverr.
Save.
```

Luego en cada indexador Cloudflare-protegido (1337x, TorrentGalaxy):

```
Indexador → Tags: cloudflare
Save.
```

**No es por defecto** porque (a) Chrome headless en ARM64 ocupa ~250 MB de RAM, (b) ralentiza cada query (1-2s extra por challenge), (c) Cloudflare actualiza el challenge ocasionalmente y FlareSolverr puede romperse durante días, (d) muchos operadores se las arreglan con indexadores no-Cloudflare (Nyaa, TheRARBG, LimeTorrents) sin perder cobertura.

### 12.2. Usenet (Newznab) en lugar de torrent

Si el operador tiene cuenta en un proveedor Newznab (NZBgeek, NZBPlanet, Drunkenslug):

```
Prowlarr → Settings → Indexers → [+] → "Newznab" (genérico)
- URL:    https://api.nzbgeek.info/
- API Key: <key del proveedor>
- Categories: TV/Movies (auto-mapped)
```

Y desplegar **SABnzbd** o **NZBGet** (no incluido en este homelab por defecto — es opt-in). El sync app a Sonarr/Radarr funciona igual: ellos verán el indexer Newznab y el download client SABnzbd, y elegirán automáticamente.

Esto convierte el *arr stack en "torrent + Usenet híbrido", con preferencia por Usenet (más rápido, sin port forwarding, sin ratio).

### 12.3. Acceso a indexadores privados desde IP estable (Tailscale Exit Node)

Algunos trackers privados detectan IPs residenciales rotativas (los CGNAT del ISP) y baneans la cuenta. Ruteando el tráfico saliente de Prowlarr por Tailscale Exit Node con IP de un VPS fijo:

```yaml
# Añadir un sidecar tailscale en el compose (alternativa: usar el host).
services:
  prowlarr-vpn:
    image: tailscale/tailscale:stable
    container_name: prowlarr-vpn
    cap_add: [NET_ADMIN, SYS_MODULE]
    devices: [/dev/net/tun]
    environment:
      TS_AUTHKEY: ${TS_AUTHKEY}
      TS_HOSTNAME: prowlarr-vpn
      TS_EXIT_NODE: <ts-id-del-vps>
      TS_USERSPACE: "false"
    volumes:
      - /mnt/hd2t/services/prowlarr/ts:/var/lib/tailscale
    networks:
      - homelab

  prowlarr:
    network_mode: "service:prowlarr-vpn"
    # ... resto igual, pero quitar `networks:` ...
```

**No es por defecto**: requiere VPS en Tailscale con el rol Exit Node, y aumenta la latencia del homelab.

### 12.4. Notificaciones avanzadas a Telegram cuando un indexador falla

Cubierto parcialmente en §7.6. Para granularidad mayor (script propio que filtre solo errores críticos):

`Settings → Connect → Add Connection → Custom Script`:

```bash
sudo tee /mnt/hd2t/services/prowlarr/config/scripts/notify-telegram.sh > /dev/null <<'EOF'
#!/bin/sh
# Variables expuestas por Prowlarr:
#   prowlarr_eventtype, prowlarr_health_issue_type, prowlarr_health_issue_message
case "$prowlarr_eventtype" in
  HealthIssue)
    case "$prowlarr_health_issue_type" in
      IndexerStatusCheck|IndexerJackettAll)
        TG_BOT="${TELEGRAM_BOT_TOKEN}"
        TG_CHAT="${TELEGRAM_CHAT_ID}"
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT}/sendMessage" \
          -d chat_id="${TG_CHAT}" \
          -d text="⚠️ Prowlarr: ${prowlarr_health_issue_message}"
        ;;
    esac
    ;;
esac
EOF
sudo chmod +x /mnt/hd2t/services/prowlarr/config/scripts/notify-telegram.sh
```

Luego en la UI: Connection → Custom Script → `/config/scripts/notify-telegram.sh`. Triggers: `On Health Issue`.

### 12.5. Quitar Authelia para uso solo en LAN cableada confiada

No recomendado. Si el operador insiste:

```caddy
prowlarr.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    # forward_auth http://authelia:9091 ...   ← comentado
    reverse_proxy http://prowlarr:9696
}
```

La auth nativa de Forms queda como única defensa. Tiene rate-limit interno (5 intentos/min), pero carece de 2FA. Por eso Authelia es el default.

### 12.6. Acceso solo desde Tailscale (sin LAN)

Si el operador no quiere `prowlarr.lan` accesible en LAN (modelo "trabajo solo desde Tailscale"), eliminar el bloque `prowlarr.{$LAN_DOMAIN}` del `Caddyfile` y dejar solo el de Tailscale (§6.6). El stack interno sigue funcionando (Sonarr/Radarr lo ven por nombre).

### 12.7. Sincronizar con Lidarr/Readarr/Whisparr (extender el *arr stack)

Si en el futuro el operador añade Lidarr (música) o Readarr (libros), Prowlarr ya está preparado: cada uno se registra en `Settings → Apps → [+]` con su propia API key y URL. Los indexadores con tag `music` o `books` se sincronizarán solo a esas apps respectivas. No requiere cambios en este doc — la integración es genérica.

### 12.8. Definir indexadores custom (Cardigann YAML)

Para trackers que Prowlarr no soporta de fábrica, se pueden añadir definiciones [Cardigann](https://github.com/Cardigann/cardigann) en `/config/Definitions/Custom/`:

```bash
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/prowlarr/config/Definitions/Custom

# Pegar un .yml de definición Cardigann (ejemplo: gtor-net.yml).
# Reiniciar Prowlarr para que lo cargue.
docker compose restart prowlarr
```

Las definiciones custom **no se backupean** (están en `Definitions/`, excluido en §9.2). Mantener una copia versionada en `~/homelab/stacks/prowlarr/definitions-custom/` y bind-mountarla aparte si el operador empieza a depender de ellas.

---

## Referencias

- Documentación oficial Servarr (Prowlarr): https://wiki.servarr.com/prowlarr
- Repositorio Prowlarr: https://github.com/Prowlarr/Prowlarr
- Releases upstream: https://github.com/Prowlarr/Prowlarr/releases
- Imagen LinuxServer.io: https://docs.linuxserver.io/images/docker-prowlarr/
- Releases LSIO: https://github.com/linuxserver/docker-prowlarr/releases
- API v1 (especificación): https://prowlarr.com/docs/api/
- FlareSolverr: https://github.com/FlareSolverr/FlareSolverr
- Cardigann (definiciones custom): https://github.com/Cardigann/cardigann
- Watchtower (política del homelab): [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)
- Caddy (reverse proxy): [`../03-red/04-caddy.md`](../03-red/04-caddy.md)
- Authelia (SSO + 2FA): [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)
- Borgmatic (backup): [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
- Backup Docker volumes (SQLite): [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md)
- Estructura de directorios: [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)
- Transmission (cliente BitTorrent): [`./01-transmission.md`](./01-transmission.md)
- Sonarr (TV): [`./03-sonarr.md`](./03-sonarr.md)
- Radarr (cine): [`./04-radarr.md`](./04-radarr.md)
