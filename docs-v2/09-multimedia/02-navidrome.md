# Navidrome

## Descripción

Despliegue de **Navidrome** ([imagen oficial `deluan/navidrome`](https://hub.docker.com/r/deluan/navidrome)) como **servidor de música** del homelab. Navidrome indexa la biblioteca en `/mnt/hd2t/media/music/` (alimentada manualmente por el operador vía rsync/Syncthing — Sonarr/Radarr no la tocan, ver [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6) y la sirve por dos vías:

1. **Web UI propia** (PWA basada en React) servida en `:4533`, con reproducción HTML5 directa.
2. **API Subsonic** (compatible con `subsonic-api/1.16`, [`OpenSubsonic`](https://opensubsonic.netlify.app/)) que consumen las apps nativas: **DSub**, **Symfonium**, **Tempo**, **Substreamer**, **play:Sub**, **Sublime Music**, **Feishin**, **Supersonic**, **Jamstash**.

Este doc cubre, en orden:

1. **Por qué Navidrome** y no Jellyfin Music, Funkwhale, Airsonic-Advanced, mpd o Plexamp, qué se asume y qué se descarta.
2. **Plan de variables y archivos**: `.env.example` versionable, `.env` real con secretos en `/mnt/hd2t/services/navidrome/.env`, layout de directorios bajo `/mnt/hd2t/services/navidrome/`.
3. **Estructura de la biblioteca**: solo `/mnt/hd2t/media/music/` (los audiolibros y podcasts son [Audiobookshelf](./03-audiobookshelf.md), las películas [Jellyfin](./01-jellyfin.md)). Tags ID3v2 / Vorbis Comments como fuente de verdad — Navidrome **no escribe** en los ficheros.
4. **`docker-compose.yml`** con bind mount de la biblioteca en **read-only**, separación entre `data/` (BD + config + playlists, respaldable) y `cache/` (transcodes regenerables, **excluido** del backup según [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6).
5. **Despliegue, onboarding inicial** (creación del admin en el primer acceso a `/`).
6. **Integración con Caddy** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3): bloque `navidrome.{$LAN_DOMAIN}` (no existe placeholder en `Caddyfile`; se añade en §6.1), DNS local en Pi-hole, websockets para "Now Playing" y eventos en tiempo real.
7. **Por qué Authelia delante de Navidrome rompe los clientes Subsonic**: las apps nativas envían credenciales como query params (`?u=&t=&s=` o `?u=&p=`), no como cookie SSO. Un `forward_auth` rechazaría la conexión antes de que la cabecera llegara al backend. Navidrome ya tiene auth propia y soporta JWT + 2FA opcional vía proxy header.
8. **Transcoding bajo demanda**: a diferencia de Jellyfin, Navidrome usa `ffmpeg` para audio en vez de vídeo — el coste en Pi 5 es despreciable (transcodear FLAC → MP3@192 kbps consume ~15 % de un core). **Activado por defecto** porque cubre dispositivos móviles con buffer pequeño y datos limitados.
9. **Backup**: solo `data/` (~50–500 MB con biblioteca grande); `cache/` se regenera tras la primera reproducción de cada track.
10. **Operaciones cotidianas**: upgrade vía Watchtower (Navidrome es **opt-in** según [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2), forzar re-escaneo, gestión de usuarios, scrobbling Last.fm/ListenBrainz.
11. **Variantes opt-in**: Tailscale para acceso remoto, ListenBrainz scrobbling, smart playlists (NSP), proxy auth header (Authelia con bypass de la API Subsonic), extracción de metadatos avanzada (`ffmpeg` + `ReplayGain`).

> **Alcance de red**: Navidrome **solo se accede vía Caddy** sobre `https://navidrome.lan` (LAN) o `https://navidrome.${TS_DOMAIN}` (Tailscale). El puerto 4533 del contenedor **no se publica al host** (regla del homelab para todos los servicios web, [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §0). Las apps Subsonic conectan por la URL completa: `https://navidrome.lan` en LAN, `https://navidrome.tailnet.ts.net` en remoto.

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), grupo `media` (GID 1100) con `homelab` como miembro, `/mnt/hd2t/` montado, `/mnt/hd2t/media/music/` creado con `homelab:media 2775` ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §3, §6).
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` creada, convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5 — bind mounts; §4.3 — red compartida; §5.2 — `PGID=1100` para multimedia).
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) con `lan_internal_tls` operativo y la red `homelab` accesible. Sin Caddy no hay HTTPS y los clientes Subsonic modernos rechazan conexiones HTTP en redes no privadas.
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con la posibilidad de añadir registros A locales (`navidrome.lan` → IP de la Pi).
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Navidrome lleva la etiqueta `com.centurylinklabs.watchtower.enable: "true"` por política — los upgrades son **automáticos** porque Navidrome migra el schema de SQLite de forma idempotente y conserva backwards-compat de la API Subsonic con celo (es su feature número uno).
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) para que `/mnt/hd2t/services/navidrome/data/` sea archivado y `/mnt/hd2t/services/navidrome/cache/` quede **excluido** según las reglas de §13.6 de ese doc.
- **Biblioteca de música presente** en `/mnt/hd2t/media/music/`: Navidrome se puede levantar con biblioteca vacía y **no** dará error — escaneará 0 ítems y esperará. El primer lleno se hace por rsync/Syncthing tras el deploy. Estructura recomendada: `Artista/Álbum/NN - Título.{mp3,flac,ogg,opus,m4a,wav}`. Navidrome confía en los **tags ID3v2 / Vorbis Comments**, no en la jerarquía de carpetas; cualquier estructura lo soporta siempre que los tags estén bien.
- **Disco hd2t libre**: ≥ 2 GB para `/mnt/hd2t/services/navidrome/` (BD ~50 MB por cada 5000 tracks; cache ~1 GB en pico tras varias semanas de transcoding bajo demanda). El espacio para los **propios contenidos** musicales se planifica aparte ([`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md) §6).

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Servidor de música | **Navidrome** (FOSS, GPL-3.0) | Funkwhale es Federated/ActivityPub, demasiado para uso doméstico y exige PostgreSQL + Redis + workers Celery. Airsonic-Advanced está en mantenimiento (último release 2023). Plexamp requiere Plex Pass (paywall) y cuenta plex.tv. mpd no tiene API HTTP estable y los clientes son escasos. Jellyfin "Music" funciona pero rinde mal con bibliotecas grandes (>20k tracks): el motor de Jellyfin está optimizado para vídeo. Navidrome es nativo Go, single-binary, una BD SQLite, escalado a >100k tracks con búsqueda full-text instantánea. |
| Imagen | **`deluan/navidrome`** (oficial) | Mantenida por el autor del proyecto. La alternativa `lscr.io/linuxserver/navidrome` añade s6-overlay y no aporta nada — Navidrome ya respeta `PUID`/`PGID` nativamente. |
| Tag de imagen | **`0.55.2`** (no `latest`, no `0.55`) | Navidrome sigue SemVer estricto. Pinear el patch obliga a confirmar el upgrade leyendo https://www.navidrome.org/blog/, especialmente cuando hay cambios en `OpenSubsonic` (raros pero los hay). Watchtower respeta tags `MAJOR.MINOR.PATCH` exactos vía `image: deluan/navidrome:${NAVIDROME_IMAGE_TAG}` — al cambiar el `.env` y reiniciar, se actualiza; sin cambio, no. |
| Arquitectura | `linux/arm64` (Pi 5) | Manifest multi-arch oficial. La imagen pesa ~30 MB (Go binary + Alpine). |
| Red Docker | **`homelab`** (bridge, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.3). **Sin** `ports:` al host. | Caddy llega a Navidrome por nombre (`http://navidrome:4533`) sobre la red compartida. No publicar `4533` al host elimina el riesgo de que la UI sea accesible **sin** TLS. |
| Modelo de almacenamiento | **Bind mount** `/mnt/hd2t/services/navidrome/data:/data` + **Bind mount** `/mnt/hd2t/media/music:/music:ro` | Patrón estándar del homelab. La separación `data` (BD, config, playlists) / `cache` (transcodes regenerables) permite hacer backup solo de `data/` y excluir `cache/` en Borgmatic. Navidrome guarda el cache **dentro de** `/data/cache/` por defecto; lo separamos a un bind mount propio (§4) para excluirlo limpiamente. |
| Biblioteca como **read-only** dentro del contenedor | `/mnt/hd2t/media/music:/music:ro` | Navidrome **no escribe** en la biblioteca: extrae metadatos (`ffprobe`) y los guarda en `/data/navidrome.db`. La etiqueta "starred" / "rating" / playlists viven en la BD propia, no en los tags ID3 del fichero. Esto es **deliberado**: protege los ficheros de origen y permite que `rsync` o Syncthing los manipulen sin pisarse con Navidrome. Si el operador quiere persistir ratings en los tags (compatibilidad con foobar2000, MusicBee), ver §12.5. |
| BD de Navidrome | **SQLite** en `/data/navidrome.db` | Navidrome no soporta otros backends. Para ≤ 200k tracks no hay problema; el equipo de Navidrome rinde benchmarks sobre 1M tracks en SQLite — fuera del alcance del homelab. |
| Usuario dentro del contenedor | **`PUID=1000` (homelab) + `PGID=1100` (media)** vía `user: "${PUID}:${PGID}"` | Coherente con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.2. Navidrome puede leer la biblioteca porque pertenece al grupo `media` (GID 1100). Escritura solo necesaria en `/data` y `/cache`, ambos owned por `homelab:homelab` (GID 1000). |
| Transcoding | **Activado por defecto** (`mp3@192` para clientes con `maxBitRate` < bitrate origen) | Navidrome usa `ffmpeg` (incluido en la imagen). Transcodear FLAC → MP3 a 192 kbps consume ~15 % de un core en Pi 5. Permite a las apps móviles (DSub, Symfonium) bajar el bitrate sobre 4G/5G. Sin coste ni riesgo. |
| Backup | **Solo `/data`** vía Borgmatic | El resto se regenera. Política en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6 (`/mnt/hd2t/services/navidrome/cache` excluido). Restore: instalar Navidrome virgen, restaurar `/data`, **rescanear** biblioteca (Navidrome re-popula índices y deja la BD intacta porque el album/song id es estable). |
| Watchtower | **`com.centurylinklabs.watchtower.enable: "true"`** | Por política ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2). Navidrome migra schema con `golang-migrate` de forma idempotente y conserva backwards-compat OpenSubsonic. Distinto de Jellyfin (manual). |
| Reverse proxy | **Caddy sin `forward_auth`** | Navidrome tiene auth nativa (`/auth/login` + JWT) **y** API Subsonic con `?u=&p=` o `?u=&t=&s=` (token + salt MD5). Aplicar Authelia con `forward_auth` rompería las apps Subsonic (no envían cookie de sesión). El paywall SSO **no aporta** nada sobre la auth nativa. Variante con bypass de `/rest/*` en §12.4 — desaconsejada. |
| `ND_REVERSEPROXYWHITELIST` / `ND_REVERSEPROXYUSERHEADER` | **Vacío por defecto** (auth nativa) | Si el operador quiere SSO via Authelia para la **UI web** (no la API), activar header proxy en §12.4. Por defecto **no** se activa porque expone un vector de spoofing si Caddy se cae mal configurado. |
| Acceso remoto | **Vía Tailscale** ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) — `navidrome.${TS_DOMAIN}` con `tls /data/tailscale-certs/navidrome.crt /data/tailscale-certs/navidrome.key` | Sin port forwarding ni DDNS. Las apps Subsonic aceptan **una** URL — el operador la cambia manualmente entre LAN y remoto, **o** registra dos servidores en la app y selecciona el correcto. Tailscale + MagicDNS hace que `navidrome.tailnet.ts.net` resuelva igual desde cualquier sitio. |
| Onboarding del primer usuario | **Por la UI web** | El primer acceso a `/` muestra el formulario "Create Admin User". **No** hay CLI para crear el primer admin; está hardcodeado en `server/initial_setup.go` del proyecto. |
| Scrobbling | **Last.fm + ListenBrainz vía UI**, opt-in por usuario | Navidrome no envía nada hasta que el usuario configura su API key en "Personal > Last.fm" o "Personal > ListenBrainz". No hay telemetría implícita. |

---

## 1. Resumen de la arquitectura

```
                 ┌────────────────── LAN ──────────────────┐
                 │                                         │
   App Subsonic  │  DSub │ Symfonium │ Substreamer │ Web   │
        │        │   │   │     │     │      │      │  │    │
        └────────┴───┴───┴─────┴─────┴──────┴──────┴──┴────┘
                                                    │
                                                    ▼
                                           https://navidrome.lan
                                                    │
                                                    ▼ (TLS de Caddy)
                                            ┌───────────────┐
                                            │     Caddy     │  (../03-red/04-caddy.md)
                                            │ navidrome.lan │
                                            │     :443      │
                                            └───────┬───────┘
                                                    │ reverse_proxy (red homelab)
                                                    │ http://navidrome:4533
                                                    ▼
                                          ┌────────────────────┐
                                          │     Navidrome      │
                                          │ (este doc, :4533)  │
                                          │                    │
                                          │  /data  (RW)       │ ─► /mnt/hd2t/services/navidrome/data/
                                          │  /cache (RW)       │ ─► /mnt/hd2t/services/navidrome/cache/
                                          │  /music (RO)       │ ─► /mnt/hd2t/media/music/
                                          └────────┬───────────┘
                                                   │
                                                   ▼ inotify watcher
                                          ┌────────────────────┐
                                          │  /mnt/hd2t/media/  │  alimentado por
                                          │  music/            │  Operador (rsync, Syncthing)
                                          │                    │
                                          └────────────────────┘
```

Lo crítico de este diagrama:

1. **Una única vía de entrada**: navegador, app Subsonic → Caddy → Navidrome. El puerto 4533 no existe para clientes externos al stack.
2. **Biblioteca en read-only**: Navidrome **lee** `/mnt/hd2t/media/music/`, no escribe ahí. El operador es el dueño de ese árbol vía rsync/Syncthing — coincide con la fila `music/` de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6.
3. **Sin discovery**: en bridge no hay multicast. Las apps Subsonic **siempre** se configuran con URL.
4. **Cache local separado**: `/mnt/hd2t/services/navidrome/cache/` contiene transcodes (`ffmpeg`) y portadas extraídas. Excluido del backup.
5. **Sin GPU passthrough**: las transcodificaciones son CPU-only (audio, sin coste). El contenedor **no** monta `/dev/dri`.

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/navidrome/.env.example`:

```env
# ~/homelab/stacks/navidrome/.env.example
# Versión control: ~/homelab/stacks/navidrome/.env.example
# Valores reales en /mnt/hd2t/services/navidrome/.env (chmod 600).
# Este fichero NO contiene secretos; las credenciales de los usuarios
# Navidrome viven dentro de /data/navidrome.db (hash bcrypt) y se
# respaldan vía Borgmatic.

# --- Comunes del homelab ---
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
MEDIA_GID=1100
TZ=Europe/Madrid

# --- Dominios internos (consistentes con dns/.env y proxy/.env) ---
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Navidrome ---
# https://hub.docker.com/r/deluan/navidrome/tags
# Lista de cambios: https://www.navidrome.org/blog/
NAVIDROME_IMAGE_TAG=0.55.2

# Hostnames públicos (sin esquema). Usados en Caddyfile.
NAVIDROME_LAN_HOST=navidrome.lan
NAVIDROME_TS_HOST=navidrome.tailnet.ts.net

# URL pública usada por Navidrome para construir links absolutos
# (cover art, share links, OpenGraph). Si no se fija, Navidrome la
# deduce del primer Host header — frágil con varios hosts.
ND_BASEURL=

# Programación del scan: cron string ("@every 1h" / "0 */6 * * *").
# El default de Navidrome es @every 1m, demasiado agresivo para una
# biblioteca grande. Aquí lo bajamos a 1 h y confiamos en inotify
# (ND_AUTOIMPORTPLAYLISTS=true + watcher interno) para detectar
# cambios en tiempo real.
ND_SCANSCHEDULE=@every 1h

# Loglevel: "error", "warn", "info", "debug", "trace".
# "info" es suficiente; "debug" llena el log rápido con cada request.
ND_LOGLEVEL=info

# Servicios externos opcionales (Last.fm/Spotify para artwork, biografías).
# Si están vacías, los lookups se desactivan silenciosamente.
ND_ENABLEEXTERNALSERVICES=true
```

### 2.2. `.env` real (`/mnt/hd2t/services/navidrome/.env`)

```bash
# Crear el .env con permisos correctos.
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/navidrome
sudo install -o homelab -g homelab -m 600 /dev/null \
  /mnt/hd2t/services/navidrome/.env

# Volcar contenido (editar valores reales).
sudo -u homelab tee /mnt/hd2t/services/navidrome/.env > /dev/null <<'EOF'
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
MEDIA_GID=1100
TZ=Europe/Madrid
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net
NAVIDROME_IMAGE_TAG=0.55.2
NAVIDROME_LAN_HOST=navidrome.lan
NAVIDROME_TS_HOST=navidrome.tailnet.ts.net
ND_BASEURL=
ND_SCANSCHEDULE=@every 1h
ND_LOGLEVEL=info
ND_ENABLEEXTERNALSERVICES=true
EOF

# Verificar.
ls -l /mnt/hd2t/services/navidrome/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` (§4) declara `env_file: /mnt/hd2t/services/navidrome/.env`. Compose carga el fichero **a la hora de interpolar `${...}` en el YAML** (para tags, hostnames, `user:`, `PGID`…) y **además** lo expone al proceso del contenedor. Navidrome lee variables `ND_*` directamente de su entorno ([referencia oficial](https://www.navidrome.org/docs/usage/configuration-options/)) — equivale a tener un `navidrome.toml` con esas claves. El homelab prefiere `env_file` por dos razones:

1. **Trazabilidad**: una sola fuente de verdad (`.env`) en lugar de dos ficheros (`.env` + `navidrome.toml`).
2. **Backup compacto**: `data/navidrome.db` ya respalda usuarios, playlists y starred items; el `.env` es texto plano que se versiona en git **sin** valores reales (solo `.env.example`). No se duplica config en el backup.

> **Por qué no hay secretos en `.env`**: Navidrome no lee credenciales de variables de entorno. El password del admin se establece desde la UI en el primer acceso a `/` y vive cifrado (bcrypt cost 10) en `/data/navidrome.db` (tabla `user`, columna `password`). Los API keys de Last.fm / ListenBrainz son **opcionales** y se configuran vía la UI por usuario.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
sudo install -d -o homelab -g homelab -m 750 ~/homelab/stacks/navidrome
```

### 3.2. Crear el árbol de datos persistentes

```bash
# Datos vivos del contenedor.
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/navidrome

# Subdirectorios respaldables (data) y regenerables (cache).
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/navidrome/data \
  /mnt/hd2t/services/navidrome/cache
```

### 3.3. Verificar que la biblioteca está lista

La carpeta `/mnt/hd2t/media/music/` debe existir con permisos `homelab:media 2775` desde [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6:

```bash
ls -ld /mnt/hd2t/media /mnt/hd2t/media/music
# Esperado:
# drwxrwsr-x ... homelab media ... /mnt/hd2t/media
# drwxrwsr-x ... homelab media ... /mnt/hd2t/media/music

# El usuario homelab pertenece al grupo media.
id homelab | tr ',' '\n' | grep media
# Esperado: ...,1100(media),...
```

Si `/mnt/hd2t/media/music/` **no existe**, ejecutar el bootstrap del doc de estructura de directorios antes de seguir:

```bash
sudo install -d -o homelab -g media -m 2775 /mnt/hd2t/media
sudo install -d -o homelab -g media -m 2775 /mnt/hd2t/media/music
```

### 3.4. Tabla resumen de permisos

| Ruta | Modo | Owner | Quién escribe | Por qué |
|---|---|---|---|---|
| `/mnt/hd2t/services/navidrome/` | `750 homelab:homelab` | homelab (Compose) | Solo el operador desde el host | Patrón canónico. Solo `homelab` ve el contenido. |
| `/mnt/hd2t/services/navidrome/data/` | `750 homelab:homelab` (preexiste, lo rellena Navidrome) | Proceso Navidrome (PUID 1000) | Materializa `navidrome.db`, `navidrome.db-shm`, `navidrome.db-wal`, `backup/` (snapshots automáticos), `playlists/` si se usan smart playlists. **Respaldable** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6). |
| `/mnt/hd2t/services/navidrome/cache/` | `750 homelab:homelab` | Proceso Navidrome (PUID 1000) | Transcodes `ffmpeg`, cover art extraído, image cache de Last.fm/Spotify. **Excluido** del backup. |
| `/mnt/hd2t/media/music/` | `2775 homelab:media` | Operador (rsync, Syncthing) | Navidrome solo **lee** (`:ro` en el bind). |

### 3.5. Permisos para el proceso del contenedor

La imagen `deluan/navidrome` corre por defecto como `root` dentro del contenedor; al fijar `user: "${HOMELAB_UID}:${MEDIA_GID}"` (1000:1100) en el Compose (§4), el proceso baja a UID 1000, GID 1100. Esto:

- Garantiza que los ficheros bajo `/data` y `/cache` aparezcan como `homelab:media` en el host.
- Permite leer la biblioteca montada como `:ro` porque el GID 1100 está en el ACL implícito del directorio padre.
- Mantiene la coherencia con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.2 ("Servicios multimedia añaden `PGID=1100`").

> **Atención**: si Navidrome se levantó alguna vez sin `user:` (ejecuciones de prueba), `data/navidrome.db` puede haber quedado como `root:root`. Corrección: `sudo chown -R 1000:1000 /mnt/hd2t/services/navidrome/{data,cache}` antes del primer `up` formal.

---

## 4. `docker-compose.yml`

`~/homelab/stacks/navidrome/docker-compose.yml`:

```yaml
# ~/homelab/stacks/navidrome/docker-compose.yml
# Stack: navidrome (servidor de música, Fase 9).
# Datos en /mnt/hd2t/services/navidrome/.
# Biblioteca (read-only) en /mnt/hd2t/media/music/.

name: navidrome

services:
  navidrome:
    image: deluan/navidrome:${NAVIDROME_IMAGE_TAG}
    container_name: navidrome
    hostname: navidrome
    restart: unless-stopped
    env_file: /mnt/hd2t/services/navidrome/.env

    # PUID 1000 (homelab), PGID 1100 (media). Necesario para leer
    # /mnt/hd2t/media/music (owned por homelab:media 2775).
    user: "${HOMELAB_UID}:${MEDIA_GID}"

    environment:
      TZ: ${TZ}
      # Loglevel y schedule del scanner (§2.1).
      ND_LOGLEVEL: ${ND_LOGLEVEL}
      ND_SCANSCHEDULE: ${ND_SCANSCHEDULE}
      ND_ENABLEEXTERNALSERVICES: ${ND_ENABLEEXTERNALSERVICES}
      # Carpetas dentro del contenedor.
      ND_DATAFOLDER: /data
      ND_MUSICFOLDER: /music
      ND_CACHEFOLDER: /cache
      # Si ND_BASEURL está vacío, Navidrome usa el primer Host header recibido.
      # Con Caddy delante y dos hosts (LAN + TS), conviene dejarlo vacío y
      # que cada cliente vea su propio host. Fijarlo solo si surge un bug
      # de "links absolutos rotos".
      ND_BASEURL: ${ND_BASEURL}
      # Auth: nativa por defecto. ND_REVERSEPROXYWHITELIST vacía =
      # rechaza cualquier intento de spoofing X-Forwarded-User.
      # (§12.4 muestra cómo activar reverse-proxy auth con Authelia.)
      ND_REVERSEPROXYWHITELIST: ""
      ND_REVERSEPROXYUSERHEADER: ""
      # ID3v2 fallback: si el tag está mal codificado (Latin1 vs UTF-8),
      # intenta detectar UTF-8 antes de mostrar mojibake.
      ND_DEFAULTLANGUAGE: ""
      # Smart playlists: importar .nsp desde /data/playlists.
      ND_AUTOIMPORTPLAYLISTS: "true"
      # Subsonic API: aceptar tokens MD5 (la mayoría de clientes los usan).
      # Sin esto, los clientes que solo soportan password en claro fallan.
      ND_SUBSONIC_LEGACYCLIENTS: "true"

    volumes:
      # BD + config + playlists. Respaldable.
      - /mnt/hd2t/services/navidrome/data:/data
      # Cache de transcodes y artwork. NO respaldable.
      - /mnt/hd2t/services/navidrome/cache:/cache
      # Biblioteca: read-only desde Navidrome. El operador es el dueño.
      - /mnt/hd2t/media/music:/music:ro
      # TZ y reloj sincronizados con el host.
      - /etc/localtime:/etc/localtime:ro

    # Sin `ports:` — Navidrome solo es accesible vía Caddy por la red `homelab`.
    networks:
      - homelab

    # Recursos: Navidrome con scan en curso de una biblioteca de 50k
    # tracks puede tocar 400 MB de RAM (ffprobe en paralelo, índices
    # full-text). Limitar evita OOM en el host.
    mem_limit: 1g
    mem_reservation: 128m

    # Healthcheck: GET /ping devuelve 200 si Navidrome respondió al
    # HTTP listener. El primer arranque tarda ~10s (init de la BD SQLite
    # y schema migrations).
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:4533/ping"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

    # security_opt: igual que el resto del homelab (../02-docker/02-estructura-compose.md §0).
    security_opt:
      - no-new-privileges:true

    labels:
      # Watchtower: actualizar automáticamente — Navidrome migra schema
      # de forma idempotente y respeta backwards-compat OpenSubsonic.
      # Política: ../02-docker/04-watchtower.md §4.2.
      com.centurylinklabs.watchtower.enable: "true"
      # Para Dozzle: agrupar logs de servicios multimedia.
      dev.dozzle.group: "media"

networks:
  homelab:
    external: true
```

### 4.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `name: navidrome` | Nombre del proyecto Compose. Aunque [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §1.1 agrupa Navidrome bajo el stack `media`, en la práctica cada servicio multimedia tiene su propio stack folder (igual que Jellyfin) — un `down` afecta solo a Navidrome. |
| `image: deluan/navidrome:${NAVIDROME_IMAGE_TAG}` | Tag pinned vía `.env`. La imagen oficial vive en Docker Hub. |
| `container_name: navidrome` / `hostname: navidrome` | Nombre estable para que Caddy llegue por DNS (`reverse_proxy http://navidrome:4533`). Sin esto, Compose le pone un nombre tipo `navidrome-navidrome-1` y rompe el DNS interno. |
| `env_file: /mnt/hd2t/services/navidrome/.env` | Carga de variables — patrón estándar del homelab. |
| `user: "${HOMELAB_UID}:${MEDIA_GID}"` | UID 1000 (escribe en `/data`, `/cache`), GID 1100 (lee en `/music`). |
| `environment.TZ` | Navidrome loguea timestamps en zona local. El YAML interno no tiene equivalente; `TZ` es la única vía. |
| `environment.ND_DATAFOLDER` / `ND_MUSICFOLDER` / `ND_CACHEFOLDER` | Paths absolutos dentro del contenedor. Hacerlos explícitos evita que un futuro cambio del default de la imagen rompa el deploy. |
| `environment.ND_BASEURL` (vacío) | Sin esto, Navidrome construye links absolutos según el `Host` header recibido. Vacío = "usa el host del request". Funciona bien con Caddy + dos hosts (LAN + TS) sin tocar nada. |
| `environment.ND_REVERSEPROXYWHITELIST` (vacío) | **Crítico**: vacío significa "ignora cualquier `X-Forwarded-User` que llegue". Sin esto, un atacante con acceso al bridge `homelab` (otro contenedor comprometido) podría enviar `X-Forwarded-User: admin` y entrar como admin. Solo se activa con bypass exhaustivo en §12.4. |
| `environment.ND_AUTOIMPORTPLAYLISTS: "true"` | Importa `.m3u` y `.nsp` (smart playlists) desde `/data/playlists/` o `/music/**` automáticamente al detectar cambios. |
| `environment.ND_SUBSONIC_LEGACYCLIENTS: "true"` | Acepta clientes Subsonic antiguos que envían `?p=enc:HEX` en lugar del token+salt MD5. La mayoría (DSub, Substreamer) ya usan token; algunos (Music Player Go, Symfonium en config "legacy") aún no. Activarlo es backwards-compat sin perder seguridad sobre TLS. |
| `volumes: /mnt/hd2t/services/navidrome/data:/data` | Bind mount canónico. Sin `:Z`/`:z` (no SELinux en Pi OS). |
| `volumes: /mnt/hd2t/services/navidrome/cache:/cache` | Separado para que Borgmatic lo excluya por path. La política de [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6 lista `/mnt/hd2t/services/navidrome/cache` como exclusión. |
| `volumes: /mnt/hd2t/media/music:/music:ro` | **Read-only** desde Navidrome. El operador es el dueño. |
| `volumes: /etc/localtime:ro` | Sincroniza la zona del host con el contenedor — backup ante un usuario que olvide poner `TZ` en `.env`. |
| `networks: [homelab]` | Solo la red compartida. Caddy ya está ahí. |
| `mem_limit: 1g` | Navidrome con escaneo en paralelo de una biblioteca de 50k tracks puede consumir 400 MB. 1 GB de tope deja margen sin pegarse con el resto. |
| `mem_reservation: 128m` | Garantía mínima en presión de memoria. Navidrome arranca con ~50 MB. |
| `healthcheck` con `/ping` | Endpoint canónico de Navidrome. Devuelve `200 OK` con `{"subsonic-response":{"status":"failed",...}}` cuando la API responde (status `failed` porque no enviamos credenciales — el HTTP 200 es lo que validamos). `start_period: 30s` cubre la inicialización del schema SQLite. |
| `security_opt: no-new-privileges:true` | Patrón base ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §0). |
| `com.centurylinklabs.watchtower.enable: "true"` | Watchtower opt-in en el homelab ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2). Navidrome está en la lista de servicios "stateless o de lectura ligera" que se actualizan auto. |
| `dev.dozzle.group: "media"` | Cuando Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)) levante, agrupa Jellyfin, Navidrome, Audiobookshelf y Calibre-Web bajo el mismo grupo "media". |
| `networks.homelab.external: true` | Patrón de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.4: la red se crea **una vez** durante el bootstrap. |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/navidrome
docker compose --env-file /mnt/hd2t/services/navidrome/.env config

# Esperado: salida YAML resuelta sin warnings.
# - El `image` debe estar plenamente cualificado: deluan/navidrome:0.55.2
# - `user: "1000:1100"` (no comillas vacías ni `null`).
# - Sin warning "variable X not set".
# - `volumes` con paths absolutos.
# - El bind de /music con `read_only: true`.
```

---

## 5. Despliegue

### 5.1. Levantar el stack

```bash
cd ~/homelab/stacks/navidrome
docker compose --env-file /mnt/hd2t/services/navidrome/.env up -d
```

El primer `up` tarda **~30 segundos**:

1. Descarga la imagen (~30 MB en arm64).
2. Inicializa el schema SQLite en `/data/navidrome.db` (migrations vía `golang-migrate`).
3. Crea config por defecto en memoria (Navidrome no escribe `navidrome.toml` por defecto; todo va en BD + env).
4. Levanta el HTTP listener en `:4533`.

### 5.2. Estado de los contenedores

```bash
docker compose --env-file /mnt/hd2t/services/navidrome/.env ps

# Esperado, tras ~30 segundos:
# NAME         IMAGE                       STATUS                 PORTS
# navidrome    deluan/navidrome:0.55.2     Up X (healthy)
```

Si tras 2 minutos el estado sigue siendo `(starting)`:

```bash
docker compose --env-file /mnt/hd2t/services/navidrome/.env logs --tail=200 navidrome

# Buscar líneas tipo:
# - "Navidrome v0.55.2 (compiled with go1.x)": arranque normal.
# - "Server is starting up at http://0.0.0.0:4533": HTTP listo.
# - "Permission denied accessing /data/navidrome.db": revisar PUID/PGID y permisos del bind mount.
# - "no such file or directory: /music": revisar que /mnt/hd2t/media/music existe.
```

### 5.3. Onboarding inicial (creación del admin)

Navidrome expone su UI en `http://navidrome:4533` (red `homelab`). Caddy aún no lo enruta hasta §6. Para el primer onboarding, dos opciones:

**Opción A — Vía Caddy (preferida)**: completar §6 antes de lanzar el formulario. Abrir `https://navidrome.lan` desde un navegador del LAN.

**Opción B — `docker exec` para validar**:

```bash
# Verificar que Navidrome responde dentro del contenedor.
docker exec navidrome wget -qO- http://localhost:4533/ping
# Esperado:
# {"subsonic-response":{"status":"failed","version":"1.16.1","type":"navidrome","serverVersion":"0.55.2","openSubsonic":true,"error":{"code":40,"message":"Wrong username or password"}}}
# (status:"failed" porque no enviamos credenciales — el HTTP 200 es lo que validamos)
```

> En la práctica el flujo recomendado es **Opción A**: completar §6, abrir `https://navidrome.lan`, completar el formulario.

El primer acceso a `/` muestra **una sola pantalla**:

1. **Crear usuario admin**: nombre + password. Esta cuenta tiene **todos** los privilegios (gestión de usuarios, transcoding profiles, logs); el password se guarda hasheado (bcrypt cost 10) en `/data/navidrome.db` (tabla `user`). **Anotar el password**: no hay "olvidé contraseña" sin acceso al filesystem.

Tras "Create Admin", Navidrome lanza el primer scan en background (visible en "About > Activity"). Para una biblioteca de ~10k tracks tarda ~5 minutos en Pi 5; 50k tracks ~30 minutos. Se puede usar la UI mientras escanea.

---

## 6. Integración con Caddy

### 6.1. Añadir el bloque `navidrome.{$LAN_DOMAIN}` al `Caddyfile`

A diferencia de Jellyfin/Pi-hole, el `Caddyfile` del homelab ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3) **no incluye placeholder** para Navidrome. Editar `~/homelab/stacks/proxy/Caddyfile` y añadir:

```caddy
# Navidrome (../09-multimedia/02-navidrome.md) — música
navidrome.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Subida de cover art de gran tamaño desde la UI (admin panel).
    # 50 MB cubre cualquier portada legítima.
    request_body {
        max_size 50MB
    }

    # Websockets: Navidrome usa long-polling, no WS. La directiva no
    # rompe nada aunque sobre. Caddy reenvía Upgrade/Connection
    # transparentemente.
    reverse_proxy http://navidrome:4533 {
        header_up Host {host}
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
        # Streaming de audio: flush_interval -1 evita buffering en Caddy
        # (un FLAC de 80 MB sin flush latencia el primer byte ~3s).
        flush_interval -1
    }
}
```

Y el bloque Tailscale gemelo (comentado hasta tener cert vía `tailscale cert`):

```caddy
# navidrome.{$TS_DOMAIN} {
#     import tailscale_tls navidrome
#     import security_headers
#     request_body {
#         max_size 50MB
#     }
#     reverse_proxy http://navidrome:4533 {
#         header_up Host {host}
#         header_up X-Forwarded-Proto https
#         header_up X-Real-IP {remote_host}
#         flush_interval -1
#     }
# }
```

Recargar Caddy:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
# Esperado: 2025/.../INFO   admin   admin endpoint started   {"address": "localhost:2019"}
# Si hay error, mira el lineno: el bloque que acabas de añadir.
```

### 6.2. Trusted proxies en Navidrome

Navidrome confía en `X-Forwarded-For` **automáticamente** si la conexión TCP viene de una IP privada (RFC1918). Por tanto, no hay que tocar nada extra cuando Caddy y Navidrome comparten la red `homelab` (172.20.0.0/24).

> **Solo hay que intervenir** si el operador activa `ND_REVERSEPROXYWHITELIST` (§12.4): ahí se pone explícitamente `172.20.0.0/24` para aceptar `X-Forwarded-User`. Para el caso por defecto (auth nativa), nada que hacer.

Verificación tras un login en `https://navidrome.lan` desde `192.168.1.50`:

```bash
docker compose --env-file /mnt/hd2t/services/navidrome/.env logs --tail=50 navidrome | grep -i login
# Esperado:
# ... msg=Successful login user=admin ip=192.168.1.50 userAgent="Mozilla/5.0 ..."
# (NO 172.20.0.X)
```

### 6.3. Registro DNS local en Pi-hole

Pi-hole resuelve `navidrome.lan` → IP de la Pi. Esto ya estaba descrito conceptualmente en [`../03-red/02-pihole.md`](../03-red/02-pihole.md) §7.

```bash
# Vía la UI de Pi-hole (preferido):
# 1. Abrir https://pihole.lan/admin/
# 2. "Local DNS > DNS Records"
# 3. Domain: navidrome.lan
#    IP:     192.168.1.10  (la IP estática de la Pi en LAN)
# 4. "Add"
```

Verificar:

```bash
dig +short @192.168.1.2 navidrome.lan
# Esperado: 192.168.1.10
```

### 6.4. Probar el acceso

```bash
# Desde el host (red homelab interna):
docker exec caddy wget -qO- -S http://navidrome:4533/ping 2>&1 | head -20
# Esperado: HTTP 200 + JSON.

# Desde la LAN (validar TLS):
curl -fsS https://navidrome.lan/ping
# Esperado: JSON con "status":"failed" (sin credenciales) y HTTP 200.
# El cert es de la CA interna de Caddy ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §3.4);
# el navegador puede protestar. Solución: instalar el root cert de Caddy.

# Desde el navegador:
# https://navidrome.lan → formulario "Create Admin User" (§5.3).
```

### 6.5. (No por defecto) Proteger con Authelia

**El homelab no pone Authelia delante de Navidrome por defecto** — explicado en §0 fila "Reverse proxy" y desarrollado en §12.4. La razón en una línea: las apps Subsonic envían credenciales en query params (`/rest/ping?u=admin&t=<md5>&s=<salt>&v=1.16.1&c=DSub&f=json`) — no envían cookie SSO; un `forward_auth` las rechazaría con 401 antes de que la query llegara al backend.

Si aun así se quiere SSO **solo para la UI web** (no la API Subsonic), ver §12.4.

---

## 7. Configuración post-despliegue

### 7.1. Configurar el primer scan completo

Tras crear el admin, Navidrome lanza un scan automático. Puede forzarse desde la UI o por API:

```bash
# Vía UI: "Settings > Activity > Scan Library Now".

# Vía API Subsonic (necesita credenciales del admin):
curl -fsS -G "https://navidrome.lan/rest/startScan" \
  --data-urlencode "u=admin" \
  --data-urlencode "p=<password>" \
  --data-urlencode "v=1.16.1" \
  --data-urlencode "c=cli" \
  --data-urlencode "f=json"
# Esperado: {"subsonic-response":{"status":"ok","version":"1.16.1",...,"scanStatus":{"scanning":true,...}}}
```

Progreso:

```bash
curl -fsS -G "https://navidrome.lan/rest/getScanStatus" \
  --data-urlencode "u=admin" \
  --data-urlencode "p=<password>" \
  --data-urlencode "v=1.16.1" \
  --data-urlencode "c=cli" \
  --data-urlencode "f=json"
# Esperado durante scan:
# {"...","scanStatus":{"scanning":true,"folderCount":150,"count":4523,"lastScan":"..."}}
```

### 7.2. Crear los usuarios secundarios (familia)

**Settings > Users > +**:

| Usuario | Rol | Notas |
|---|---|---|
| `admin` (creado en §5.3) | Admin | Acceso completo. |
| `family` | User estándar | Puede crear playlists privadas, scrobblear, marcar starred. **No** ve "Settings". |
| `kids` (opcional) | User estándar | Playlists curadas por el admin. Sin scrobbling externo. |

Para cada usuario, el operador puede limitar:

- **Personal > Last.fm / ListenBrainz**: opcional, opt-in.
- **Personal > Transcode max bitrate**: si la app Subsonic respeta `maxBitRate`, capa el throttle (útil para `kids` con tarifa móvil limitada).
- **Personal > Now playing**: visibilidad opcional al admin de qué escucha cada user.

### 7.3. Configurar el escaneo periódico

Ya configurado vía `ND_SCANSCHEDULE=@every 1h` (§2.1). Adicional:

| Opción | Default | Cambiar a | Por qué |
|---|---|---|---|
| `ND_SCANSCHEDULE` | `@every 1m` | **`@every 1h`** (ya en §2.1) | Cada minuto es excesivo para una biblioteca grande. El watcher inotify ya detecta cambios en tiempo real; el scan periódico es plan B. |
| `ND_SCAN_GROUPALBUMRELEASES` | `false` | **Mantener `false`** | `true` agrupa "Album Deluxe Edition" y "Album Standard Edition" como un único álbum — mata la flexibilidad si tienes ambos releases. |
| `ND_SCAN_SCHEDULE_FULL` | (no existe) | — | Navidrome v0.55+ no diferencia "scan full" de "scan rápido" (`mtime`-based); siempre re-evalúa lo que ha cambiado. |

### 7.4. Transcoding profiles

**Settings > Transcoding** (admin only):

Navidrome viene con dos profiles por defecto:

| Player profile | Transcoding | Bitrate |
|---|---|---|
| `mp3` | `ffmpeg -i %s -ss %t -map 0:0 -b:a %bk -v 0 -f mp3 -` | 192 kbps |
| `opus` | `ffmpeg -i %s -ss %t -map 0:0 -b:a %bk -v 0 -f opus -` | 128 kbps |

**Caso típico**:

- Cliente DSub conectado en LAN sobre WiFi: streaming **direct play** del fichero original (FLAC sin transcode). Confirmable en "Settings > Activity > Sessions".
- Cliente Symfonium en 4G fuera de casa (vía Tailscale): el cliente fuerza `maxBitRate=192` → Navidrome transcodea **a MP3 192 kbps en tiempo real** (CPU ~15 % de un core en Pi 5). Buffer pequeño, latencia baja.

**Verificar transcoding activo**:

```bash
docker exec navidrome sh -c 'pgrep ffmpeg && echo "transcoding en curso"'
# Si no hay transcode activo: vacío.
# Durante un transcode: pid + path del fichero.
```

### 7.5. Webhooks / scrobbling

Navidrome **no necesita** webhooks externos para detectar cambios en la biblioteca: el watcher inotify interno ya lo hace. Pero puede **emitir** webhooks para eventos:

- **Last.fm scrobbling** (Personal > Last.fm): cada usuario asocia su propia cuenta. Navidrome envía `track.scrobble` tras 50 % de reproducción o 4 minutos (lo que ocurra antes). API key del operador en `https://www.last.fm/api/account/create`.
- **ListenBrainz** (Personal > ListenBrainz): cuenta por usuario, token desde `https://listenbrainz.org/profile/`. Idéntico flujo.
- **Webhook genérico** (vía plugin externo, [Discord/ntfy bot](https://github.com/navidrome/awesome-navidrome)): Navidrome **no tiene** webhook nativo más allá de scrobbling. Si el operador quiere notificaciones "nueva canción", scriptearlo con `inotifywait` sobre `/mnt/hd2t/media/music/` es la vía más simple.

### 7.6. Smart playlists (`.nsp`)

Navidrome soporta **Smart Playlists** definidas en JSON con extensión `.nsp`. Se colocan en `/data/playlists/` y se importan automáticamente con `ND_AUTOIMPORTPLAYLISTS=true` (§4).

Ejemplo `/mnt/hd2t/services/navidrome/data/playlists/recently_added.nsp`:

```json
{
  "name": "Recently Added",
  "comment": "Tracks añadidos en los últimos 30 días",
  "all": [
    {"recently_added": {"value": 30}}
  ],
  "sort": "added",
  "order": "desc",
  "limit": 100
}
```

Documentación completa de la sintaxis: https://www.navidrome.org/docs/usage/smartplaylists/.

### 7.7. Preferencias clave de la UI

**Settings > General** (admin):

| Opción | Valor recomendado | Por qué |
|---|---|---|
| Welcome message | (vacío) | Sin nada por defecto. |
| Recently added albums | 30 | Coincidir con la smart playlist de §7.6. |
| Default theme | "Dark" | Preferencia personal. |
| Disable downloads | **No** | El operador puede querer descargar un álbum entero a otro dispositivo. |

---

## 8. Verificación

### 8.1. Contenedor sano

```bash
docker compose --env-file /mnt/hd2t/services/navidrome/.env ps
# Esperado: Up X (healthy)

docker inspect navidrome --format '{{.State.Health.Status}}'
# Esperado: healthy
```

### 8.2. Direct play funciona

Reproducir un MP3 desde el navegador y verificar que **NO** está corriendo `ffmpeg`:

```bash
docker exec navidrome sh -c 'pgrep ffmpeg && echo "transcode" || echo "direct play OK"'
# Esperado en LAN sin maxBitRate forzado: "direct play OK"
```

### 8.3. Navidrome escucha solo dentro de la red `homelab`

```bash
# Desde el host: el puerto 4533 NO debe responder.
ss -tlnp | grep 4533
# Esperado: vacío (sin línea).

curl -fsS -m 3 http://localhost:4533/ping
# Esperado: error de conexión (Connection refused).

# Desde dentro de la red homelab sí debe responder.
docker exec caddy wget -qO- http://navidrome:4533/ping | head -c 200
# Esperado: JSON con "status":"failed" (sin credenciales) y HTTP 200.
```

### 8.4. Biblioteca montada y leída

```bash
docker exec navidrome ls -la /music | head
# Esperado: ficheros/carpetas visibles si los hay; permisos como en host.

# Test escritura (debería FALLAR — `:ro`):
docker exec navidrome touch /music/test_write
# Esperado: "Read-only file system"
```

### 8.5. API Subsonic operativa

Tras crear el admin (`admin` / `<password>`):

```bash
curl -fsS -G "https://navidrome.lan/rest/ping" \
  --data-urlencode "u=admin" \
  --data-urlencode "p=<password>" \
  --data-urlencode "v=1.16.1" \
  --data-urlencode "c=cli" \
  --data-urlencode "f=json"
# Esperado:
# {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome",...}}

# Listar artistas:
curl -fsS -G "https://navidrome.lan/rest/getArtists" \
  --data-urlencode "u=admin" \
  --data-urlencode "p=<password>" \
  --data-urlencode "v=1.16.1" \
  --data-urlencode "c=cli" \
  --data-urlencode "f=json" | head -c 500
# Esperado: JSON con índices por letra y la lista de artistas.
```

### 8.6. Smoke test desde el navegador

1. `https://navidrome.lan` carga la UI.
2. Login con `admin` exitoso.
3. La sección "Albums" muestra al menos un álbum (si hay biblioteca) o "No albums found" sin error.
4. Reproducir un track arbitrario: empieza < 3s.
5. Cerrar sesión y volver a entrar: persiste el progreso de "Recently Played".

### 8.7. Persistencia tras reboot

```bash
sudo reboot
# Esperar ~2 min.
ssh homelab@pi.lan
docker compose --env-file /mnt/hd2t/services/navidrome/.env -f ~/homelab/stacks/navidrome/docker-compose.yml ps
# Esperado: navidrome Up X (healthy) — restart: unless-stopped lo trae solo.
```

### 8.8. Lista de verificación

- [ ] `docker compose ... ps` muestra `Up X (healthy)`.
- [ ] `docker inspect navidrome --format '{{.State.Health.Status}}'` = `healthy`.
- [ ] `ss -tlnp | grep 4533` no devuelve nada (no hay puerto publicado).
- [ ] `curl -fsS https://navidrome.lan/ping` devuelve JSON con `"status":"failed"` (sin credenciales) y HTTP 200.
- [ ] `docker exec navidrome touch /music/test_write` falla con `Read-only file system`.
- [ ] Login en `https://navidrome.lan` con cuenta admin OK.
- [ ] API Subsonic responde con `"status":"ok"` para `/rest/ping?u=admin&p=...`.
- [ ] Reproducción de un MP3 sin `ffmpeg` activo (direct play).
- [ ] `docker compose logs navidrome | grep "Successful login"` muestra la IP real del cliente (no `172.20.0.X`).
- [ ] Tras `sudo reboot`, Navidrome vuelve a estar `(healthy)` en menos de 2 minutos.
- [ ] Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6) lista `/mnt/hd2t/services/navidrome/data/` en el archivo y **no** lista `cache/`.

---

## 9. Backup

### 9.1. Qué se respalda y qué no

| Ruta | Backup | Justificación |
|---|---|---|
| `/mnt/hd2t/services/navidrome/data/` | **Sí** (Borgmatic, [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6) | Contiene `navidrome.db` (usuarios, playlists, starred items, ratings, scrobble history), `playlists/*.nsp` (smart playlists), `backup/` (snapshots automáticos diarios que la propia Navidrome crea, opcional). ~50–500 MB según tamaño de biblioteca. |
| `/mnt/hd2t/services/navidrome/cache/` | **No** | Transcodes `ffmpeg`, image cache de Last.fm. Regenerable. Puede crecer a 1 GB+. |
| `/mnt/hd2t/media/music/` | **Política aparte** ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §6) | El **contenido** musical es **irreplazable** (rips propios, descargas, compras Bandcamp) — debe entrar en backup, pero como repo separado o volumen del repo principal según el espacio. |

### 9.2. Política Borgmatic

`~/homelab/stacks/backup/config/borgmatic.d/navidrome.yaml` (extendiendo el doc principal):

```yaml
# Cubierto en ../07-backups/02-borgmatic.md §13.6 — solo aquí como referencia.
source_directories:
  - /mnt/hd2t/services/navidrome/data

# Hook para hacer un dump consistente de SQLite (evita races con WAL).
before_backup:
  - sqlite3 /mnt/hd2t/services/navidrome/data/navidrome.db "VACUUM INTO '/mnt/hd2t/services/navidrome/data/backup/navidrome.db.bak'"
```

> **Por qué `VACUUM INTO`**: Navidrome escribe en WAL mode; un copiado directo del `.db` sin checkpoint puede dar una BD inconsistente. `VACUUM INTO` es el método canónico de SQLite para hacer un snapshot consistente. El snapshot queda en `data/backup/navidrome.db.bak` que entra en el archivo Borg natural.

### 9.3. Restore (resumen)

```bash
# 0. Asumiendo Pi recién instalada y borg/borgmatic operativo.
# 1. Recrear el árbol de directorios (§3.2).
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/navidrome \
  /mnt/hd2t/services/navidrome/data \
  /mnt/hd2t/services/navidrome/cache

# 2. Listar archivos disponibles.
sudo borgmatic list

# 3. Extraer SOLO el data de Navidrome del último archivo.
sudo borgmatic extract \
  --archive latest \
  --path mnt/hd2t/services/navidrome/data \
  --destination /

# 4. Verificar permisos del data.
sudo chown -R 1000:1000 /mnt/hd2t/services/navidrome/data

# 5. Levantar Navidrome.
cd ~/homelab/stacks/navidrome
docker compose --env-file /mnt/hd2t/services/navidrome/.env up -d

# 6. Forzar re-scan de la biblioteca (regenera índices).
curl -fsS -G "https://navidrome.lan/rest/startScan" \
  --data-urlencode "u=admin" \
  --data-urlencode "p=<password>" \
  --data-urlencode "v=1.16.1" \
  --data-urlencode "c=cli" \
  --data-urlencode "f=json"

# 7. Validar:
# - Usuarios existentes en Settings > Users.
# - Playlists existentes en Library > Playlists.
# - Starred items y scrobble history visibles.
```

### 9.4. Smoke test mensual de restore

[`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §10 fija un drill mensual de restore. Para Navidrome:

```bash
# En un directorio temporal (NO sobre la instalación viva):
mkdir -p /tmp/nd-restore-test
cd /tmp/nd-restore-test

sudo borgmatic extract \
  --archive latest \
  --path mnt/hd2t/services/navidrome/data/navidrome.db \
  --destination .

# Verificar que la BD es válida y tiene usuarios.
sudo apt-get install -y sqlite3  # si no está
sqlite3 ./mnt/hd2t/services/navidrome/data/navidrome.db \
  'SELECT user_name, is_admin FROM user;'
# Esperado: lista con admin, family, kids (los creados en §7.2).

sqlite3 ./mnt/hd2t/services/navidrome/data/navidrome.db \
  'SELECT COUNT(*) FROM media_file;'
# Esperado: número entero (cantidad de tracks indexados).

rm -rf /tmp/nd-restore-test
```

---

## 10. Operaciones cotidianas

### 10.1. Upgrade automático (Watchtower)

Navidrome lleva `com.centurylinklabs.watchtower.enable: "true"` (§4). Watchtower comprueba a diario; cuando hay un nuevo digest del tag pinned, hace `pull` + `up -d`. **Pero**: como el tag está pinned a `0.55.2`, Watchtower no actualiza versiones nuevas a no ser que el operador edite `.env`.

**Upgrade manual de versión** (cambio de tag, p. ej. 0.55.2 → 0.56.0):

```bash
# 1. Leer el changelog: https://www.navidrome.org/blog/.
#    Buscar "Breaking changes" (raros pero los hay).

# 2. Editar /mnt/hd2t/services/navidrome/.env:
sed -i 's/^NAVIDROME_IMAGE_TAG=.*/NAVIDROME_IMAGE_TAG=0.56.0/' \
  /mnt/hd2t/services/navidrome/.env

# 3. Backup ad-hoc del data ANTES.
sudo borgmatic create --verbosity 1

# 4. Pull + recrear.
cd ~/homelab/stacks/navidrome
docker compose --env-file /mnt/hd2t/services/navidrome/.env pull navidrome
docker compose --env-file /mnt/hd2t/services/navidrome/.env up -d

# 5. Vigilar el primer arranque tras upgrade (la BD migra schema).
docker compose --env-file /mnt/hd2t/services/navidrome/.env logs -f navidrome

# Esperado:
# - "Navidrome v0.56.0"
# - "Migration completed" si toca migrar schema (la mensajería exacta varía).
# - "Server is starting up at http://0.0.0.0:4533"

# 6. Smoke test: login + reproducir un track.

# 7. Si algo se rompe: rollback.
sed -i 's/^NAVIDROME_IMAGE_TAG=.*/NAVIDROME_IMAGE_TAG=0.55.2/' \
  /mnt/hd2t/services/navidrome/.env
docker compose --env-file /mnt/hd2t/services/navidrome/.env up -d
# Si la BD ya migró a un schema más nuevo, restaurar data/ desde Borg.
```

### 10.2. Forzar re-escaneo de la biblioteca

Tras un movimiento manual (rsync de un disco externo) o un cambio masivo de tags:

```bash
# Vía API (ver §7.1).
# O vía UI: Settings > Activity > "Scan Library Now".
```

### 10.3. Limpieza de cache

```bash
# Vía sistema (con Navidrome corriendo es seguro — Navidrome regenera lo necesario):
sudo find /mnt/hd2t/services/navidrome/cache -mindepth 1 -delete

# O reiniciar el contenedor primero para liberar locks (no estrictamente necesario):
docker compose --env-file /mnt/hd2t/services/navidrome/.env stop navidrome
sudo find /mnt/hd2t/services/navidrome/cache -mindepth 1 -delete
docker compose --env-file /mnt/hd2t/services/navidrome/.env start navidrome
```

### 10.4. Logs

```bash
# Stream en vivo (vía Dozzle o `docker compose logs`).
docker compose --env-file /mnt/hd2t/services/navidrome/.env logs -f navidrome

# Errores recientes:
docker compose --env-file /mnt/hd2t/services/navidrome/.env logs --tail=500 navidrome \
  | grep -E "level=error|level=warn" | tail -30
```

Subir el loglevel a `debug` puntualmente (sin reiniciar):

```bash
# No hay endpoint para cambiar loglevel en runtime.
# La vía es editar .env y reiniciar:
sed -i 's/^ND_LOGLEVEL=.*/ND_LOGLEVEL=debug/' /mnt/hd2t/services/navidrome/.env
docker compose --env-file /mnt/hd2t/services/navidrome/.env up -d
# (recordar volver a info tras la sesión de debug)
```

### 10.5. Gestión de usuarios

Vía UI (no hay CLI):

- **Añadir**: Settings > Users > +.
- **Eliminar**: Settings > Users > <user> > Delete (la watch history y favoritos del usuario se borran; los items de la biblioteca, no).
- **Cambiar password (lo olvidó el user)**: Settings > Users > <user> > "Change password" → enviarle el nuevo.
- **Reset password de admin (perdido el control)**: editar `/data/navidrome.db` (tabla `user`, columna `password`). Hashes bcrypt — la forma práctica:

```bash
# Generar un hash bcrypt nuevo desde el host.
sudo apt-get install -y python3-bcrypt   # si no está
python3 -c 'import bcrypt; print(bcrypt.hashpw(b"NUEVO_PASSWORD", bcrypt.gensalt(10)).decode())'
# Salida: $2b$10$....
# Detener Navidrome.
docker compose --env-file /mnt/hd2t/services/navidrome/.env stop navidrome
# Actualizar la BD.
sudo sqlite3 /mnt/hd2t/services/navidrome/data/navidrome.db \
  "UPDATE user SET password='<HASH>' WHERE user_name='admin';"
# Levantar y entrar con el nuevo password.
docker compose --env-file /mnt/hd2t/services/navidrome/.env up -d
```

### 10.6. Comportamiento durante mantenimiento

| Situación | Resultado | Mitigación |
|---|---|---|
| `docker compose stop navidrome` (planificado) | Apps Subsonic muestran "Server unreachable". Streams activos se cortan al instante. | Avisar 1 min antes (escuchar música no es crítico — diferencia con Jellyfin). |
| Caddy reload | Las requests reciben `502` momentáneo (~1 segundo); las apps reintentan transparentemente. | Sin acción. |
| Pi-hole caído | `navidrome.lan` no resuelve dentro del LAN. | Fallback DNS en clientes ([`../03-red/02-pihole.md`](../03-red/02-pihole.md) §10) o IP directa. |
| Disco hd2t saturado | Navidrome no puede escribir cache; transcodes fallan; direct play sigue funcionando. | Monitorización ([`../05-monitorizacion/02-grafana.md`](../05-monitorizacion/02-grafana.md), Node Exporter). Limpiar cache (§10.3). |

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Cómo diagnosticar | Remedio |
|---|---|---|---|
| `Read-only file system` al ejecutar `touch /music/test` desde dentro del contenedor | El bind mount es `:ro` (correcto) | — | **Esperado**. Navidrome no escribe en `/music`. |
| Login OK pero "Server unreachable" en app móvil | URL del servidor mal en la app | App settings → Server URL | Cambiar a `https://navidrome.lan` o `https://navidrome.tailnet.ts.net`, no IP. |
| Tracks no aparecen tras añadir ficheros | El watcher inotify no llega a propagarse, o `mtime` no cambió (rsync con `--no-times`) | "Settings > Activity" muestra `lastScan` antiguo | Forzar scan manual (§7.1) o `docker compose restart navidrome`. |
| Mojibake en títulos (acentos, caracteres asiáticos) | Tags ID3v1 con encoding Latin1 mal etiquetado como UTF-8 | `mediainfo "<fichero>.mp3" \| grep -i unicode` | Re-tagear con `mid3v2` o `mp3tag` a ID3v2.4 + UTF-8. |
| Direct play falla en navegador con `Codec not supported` | El fichero es Opus o WMA (Chrome no soporta WMA) | Settings > Activity > Sessions → "Stream: Transcoding" | Aceptar el transcode (CPU bajo). Si pasa con Opus en Safari: bug de Safari, usar Chrome/Firefox. |
| `Successful login user=admin ip=172.20.0.X` (no la IP del cliente) | Caddy no está enviando `X-Forwarded-For` | Verificar el bloque `header_up X-Real-IP {remote_host}` (§6.1) | Añadir `header_up X-Forwarded-For {remote_host}` si falta. Reload Caddy. |
| Authentication failure repetido en log | Brute-force (raro en LAN) o cliente con credenciales obsoletas | `docker compose logs navidrome \| grep "Authentication failed"` | Banear IP via Fail2ban del host ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md), jail `navidrome` opt-in). Forzar logout del cliente desde Settings > Users. |
| Last.fm scrobble falla con 401 | Token expirado o API key revocada | `docker compose logs navidrome \| grep -i lastfm` | Re-autenticar en Personal > Last.fm. |
| Biblioteca de 50k+ tracks tarda >30 min en escanear la primera vez | Normal (`ffprobe` en cada fichero + cálculo MusicBrainz IDs) | Settings > Activity > "scanStatus.count" sube monotónicamente | Esperar. Sucesivos scans son rápidos (solo files con `mtime` cambiado). |
| Smart playlist `.nsp` no aparece | Sintaxis JSON inválida o `ND_AUTOIMPORTPLAYLISTS=false` | `docker compose logs navidrome \| grep -i "smart playlist"` | Validar JSON con `jq . file.nsp`. Reiniciar. |
| Cover art no se descarga | `ND_ENABLEEXTERNALSERVICES=false` o sin red exterior (Pi-hole bloquea Last.fm) | `docker compose logs navidrome \| grep -i artwork` | Activar el flag o whitelist Last.fm/Spotify en Pi-hole. |

---

## 12. Variantes opt-in

### 12.1. Acceso remoto vía Tailscale

Tras desplegar Tailscale en el host ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) y emitir el cert:

```bash
# 1. Generar cert de Tailscale para el host navidrome.
tailscale cert navidrome.tailnet.ts.net

# 2. Mover los .crt y .key al bind mount de Caddy.
sudo mv navidrome.tailnet.ts.net.crt \
  /mnt/hd2t/services/caddy/tailscale-certs/navidrome.crt
sudo mv navidrome.tailnet.ts.net.key \
  /mnt/hd2t/services/caddy/tailscale-certs/navidrome.key

# 3. Descomentar el bloque navidrome.{$TS_DOMAIN} en el Caddyfile (§6.1).

# 4. Recargar Caddy.
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

En las apps Subsonic, **el operador puede registrar dos servidores** ("Casa LAN" y "Casa remoto") con sus URLs respectivas y cambiar manualmente. **No** hay auto-switch en clientes Subsonic — la app no sabe si está en LAN o vía Tailscale.

### 12.2. ListenBrainz como scrobbling primario

ListenBrainz es la alternativa libre a Last.fm. **Personal > ListenBrainz**:

1. Token desde https://listenbrainz.org/profile/ → "User Token".
2. Pegar en el campo + "Save".
3. Probar reproduciendo un track durante > 50 % de su duración → debe aparecer en https://listenbrainz.org/user/<usuario>/.

> **Coexiste con Last.fm** sin conflicto: Navidrome envía a ambos si están configurados.

### 12.3. Smart playlists complejas

Más allá del ejemplo de §7.6, se pueden combinar reglas con `all` (AND) y `any` (OR):

`/mnt/hd2t/services/navidrome/data/playlists/jazz_top_rated.nsp`:

```json
{
  "name": "Jazz Top Rated",
  "comment": "Jazz con rating >= 4 estrellas",
  "all": [
    {"genre": {"value": "Jazz"}},
    {"rating": {"operator": "gte", "value": 4}}
  ],
  "sort": "rating",
  "order": "desc",
  "limit": 50
}
```

Navidrome re-evalúa la playlist en cada acceso (no la materializa). Documentación: https://www.navidrome.org/docs/usage/smartplaylists/.

### 12.4. (Desaconsejado) Authelia delante de Navidrome

Solo para entornos donde se quiere SSO + 2FA delante del **navegador** y se acepta perder las apps Subsonic, **o** se aplica un bypass de la API REST (§6.5).

```caddy
navidrome.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Bypass para la API Subsonic — sin esto las apps móviles dejan de funcionar.
    @subsonic_api {
        path /rest/*
        path /share/*           # Public share links (cuando se activan)
    }
    handle @subsonic_api {
        reverse_proxy http://navidrome:4533 {
            header_up Host {host}
            header_up X-Forwarded-Proto https
            header_up X-Real-IP {remote_host}
            flush_interval -1
        }
    }

    # Resto (UI web): aplicar Authelia.
    handle {
        import authelia_proxy
        reverse_proxy http://navidrome:4533 {
            header_up Host {host}
            header_up X-Forwarded-Proto https
            header_up X-Real-IP {remote_host}
            header_up Remote-User {http.auth.user.username}
            flush_interval -1
        }
    }
}
```

Y en el `.env`:

```env
# Habilitar reverse-proxy auth para la UI web.
# Whitelist de IPs internas que pueden enviar X-Forwarded-User.
ND_REVERSEPROXYWHITELIST=172.20.0.0/24
ND_REVERSEPROXYUSERHEADER=Remote-User
```

**Riesgo conocido**: la lista `@subsonic_api` debe coincidir con todos los endpoints que las apps usan (`/rest/*` cubre el 100 % de la API Subsonic actual). Si Navidrome introduce un nuevo endpoint fuera de `/rest/*` que las apps consuman (improbable, pero no imposible), las apps dejarán de funcionar hasta que el operador lo añada al bypass. Por eso el homelab **no** lo activa.

### 12.5. Persistir ratings en los tags ID3 (no recomendado)

Por defecto, los ratings y starred items viven en `/data/navidrome.db`. Si el operador quiere que se escriban en los tags ID3 del fichero (compatibilidad con foobar2000, MusicBee al hacer rip exportable):

1. Quitar `:ro` del bind mount de `music/`:

   ```yaml
   - /mnt/hd2t/media/music:/music
   ```

2. **Settings > General > Save tags to files**: **ACTIVAR** (no existe en v0.55.x; está en roadmap como "tag writing" — verificar release notes antes de activar; ver https://github.com/navidrome/navidrome/issues/1374).

**Coste**:

- Pierde la barrera "Navidrome no puede escribir en bibliotecas".
- Cada escritura es una mutación I/O sobre el fichero original (riesgo de corrupción si el proceso muere a media operación).
- Imposible compartir biblioteca con otro servidor de música sin sincronizar también la BD de Navidrome.

> **El homelab no recomienda esta variante**. La BD de Navidrome se respalda diariamente; perder ratings es perder un Borg snapshot, no perder datos definitivamente.

### 12.6. Plugin de Subsonic Jukebox (reproducir en altavoz Pi)

Navidrome v0.55+ soporta el modo **Jukebox**: el servidor reproduce audio directamente en su salida (ALSA/PulseAudio) y los clientes solo "controlan" la cola. Útil si la Pi tiene altavoces conectados.

```yaml
# Patch al docker-compose.yml.
services:
  navidrome:
    environment:
      ND_JUKEBOX_ENABLED: "true"
      ND_JUKEBOX_DEVICES: "default"
      ND_JUKEBOX_DEFAULT: "default"
    devices:
      - /dev/snd:/dev/snd
    group_add:
      # Grupo `audio` del host (GID típicamente 29 en Pi OS).
      - "29"
```

**Comprobación**: tras reiniciar, Settings > Server tiene una sección "Jukebox" con el botón "Test playback". Algunos clientes Subsonic tienen UI específica para Jukebox (Sublime Music, DSub).

> Este modo es **experimental** y no se recomienda para uso primario — es una variante para integradores que quieren la Pi como "media center" físico.

---

## Referencias

- **Documentación oficial**: https://www.navidrome.org/docs/
- **Imagen Docker**: https://hub.docker.com/r/deluan/navidrome
- **Release notes (blog)**: https://www.navidrome.org/blog/
- **Configuration options**: https://www.navidrome.org/docs/usage/configuration-options/
- **Smart playlists**: https://www.navidrome.org/docs/usage/smartplaylists/
- **API Subsonic / OpenSubsonic**: https://opensubsonic.netlify.app/
- **Repositorio**: https://github.com/navidrome/navidrome
- **Foro de la comunidad**: https://github.com/navidrome/navidrome/discussions
- **Subreddit**: https://www.reddit.com/r/navidrome/
- **Lista de clientes Subsonic**: https://www.navidrome.org/docs/overview/#apps

**Documentos del homelab relacionados**:

- [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) — UID/GID, layout de `/mnt/hd2t/media/music/`.
- [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) — convenciones de `docker-compose.yml`, red `homelab`, `PGID=1100`.
- [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 — Navidrome incluido en upgrades automáticos.
- [`../03-red/02-pihole.md`](../03-red/02-pihole.md) — DNS local `navidrome.lan`.
- [`../03-red/04-caddy.md`](../03-red/04-caddy.md) — reverse proxy, snippets `lan_internal_tls`, `security_headers`, `tailscale_tls`.
- [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) — acceso remoto sin port forwarding.
- [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) — SSO/2FA opcional (no recomendado para Navidrome, §12.4).
- [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) — jail opt-in para Navidrome.
- [`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md) — agrupación de logs por `dev.dozzle.group: "media"`.
- [`../06-almacenamiento/03-syncthing.md`](../06-almacenamiento/03-syncthing.md) — vía recomendada para sincronizar la biblioteca de música desde otros equipos al directorio `/mnt/hd2t/media/music/`.
- [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) — política 3-2-1.
- [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6 — exclusión específica de Navidrome (`cache`).
- [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) — patrón general de backup de bind mounts.
- [`./01-jellyfin.md`](./01-jellyfin.md) — el servidor multimedia "hermano"; comparte el grupo `media` y el patrón de bibliotecas RO.
- [`./03-audiobookshelf.md`](./03-audiobookshelf.md) — audiolibros y podcasts (no música), separación deliberada de responsabilidades.
