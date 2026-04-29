# Navidrome

## Descripción

Con `01-jellyfin.md` aplicado, el homelab ya sabe servir vídeo y, como subproducto, también música: Jellyfin (en adelante, JF) indexa `/mnt/hd2t/media/music/` y la reproduce desde el navegador o sus apps oficiales. El problema es que **el cliente nativo de música de JF está pensado como un extra del servidor de vídeo**: la UI vive como una pestaña de la UI principal, las apps móviles oficiales tratan al "audio" como contenido de segunda, y los clientes que el operador quiere usar en el día a día —**DSub** y **Symfonium** en Android, **play:Sub** o **Amperfy** en iOS, **Sonixd**/**Feishin** en escritorio— no hablan el dialecto de JF: hablan **Subsonic API**.

Subsonic es un protocolo HTTP de los 2000 que se convirtió en el lingua franca de la música self-hosted: hay docenas de clientes maduros, gratuitos o de pago, todos consumiendo el mismo conjunto de endpoints (`/rest/getMusicDirectory`, `/rest/stream`, `/rest/scrobble`, `/rest/createBookmark`...). Quien quiera tener música en el coche con CarPlay o en una smartwatch Garmin usa un cliente Subsonic; quien quiera scrobbling fino a Last.fm/ListenBrainz desde el móvil con sleep timers, ecualizador y caché offline, usa un cliente Subsonic. JF tiene un endpoint Subsonic incipiente, pero parcial (no implementa todos los métodos, suele cojear con bookmarks y con jukebox).

**Navidrome** (en adelante, ND) es un servidor de música self-hosted, escrito en Go, con dos virtudes que encajan con el homelab:

1. **Implementación Subsonic API completa y estable** (incluye OpenSubsonic, una extensión moderna del protocolo): cualquier cliente Subsonic conecta a la primera, sin matices.
2. **Ligero**: un binario único, BBDD SQLite local, sin dependencias externas. En la Pi 5 consume ~50 MiB de RAM y prácticamente nada de CPU salvo durante el escaneo o un transcoding bajo demanda.

Su rol concreto en el homelab:

1. **Catalogar y servir la biblioteca de música** que vive en `/mnt/hd2t/media/music/` (FLACs, MP3s, OGG, OPUS, ALAC, WAV). Lee tags ID3/Vorbis/MP4, descarga metadatos y carátulas opcionales, e indexa en una BBDD SQLite local (`navidrome.db`).
2. **Servir esa biblioteca** vía:
   - **UI web propia** (single-page React app) accesible en `https://navidrome.${DOMAIN_LAN}/` y `https://navidrome.${DOMAIN_TS}/`.
   - **Subsonic API** (`/rest/...`), consumible por DSub, Symfonium, play:Sub, Substreamer, Amperfy, Sonixd, Feishin y compañía. Es el cliente principal en el homelab.
3. **Transcodificar bajo demanda** cuando el cliente lo pide (FLAC → MP3 320 kbps en datos móviles, p. ej.) usando el `ffmpeg` empaquetado en la imagen. El transcoding de audio en una Pi 5 es trivial (~1× tiempo real con un solo núcleo) — al contrario que el de vídeo, no hay debate de hardware acceleration.
4. **Scrobble a Last.fm y ListenBrainz** (opcional). El operador típico ya tiene cuenta en al menos uno de ellos; la integración se configura por variables de entorno y queda visible en cada cliente.
5. **Compartir pistas** vía URLs `share` (token con caducidad), si alguna vez se quiere mandar un álbum a alguien sin cuenta.

Lo que este documento **no** decide:

- **Qué cliente Subsonic instalar en cada dispositivo del hogar**: depende del usuario. Se recomiendan abajo (Sección "Clientes compatibles") DSub/Symfonium en Android, Amperfy/play:Sub en iOS, Feishin/Sonixd en escritorio, pero no se entra en cómo configurar cada uno (sus docs lo cubren).
- **Si JF también indexa `/mnt/hd2t/media/music/`**: sí, lo seguimos manteniendo (decisión heredada de `01-jellyfin.md`). La biblioteca queda **doblemente indexada**, ND y JF, ambas como **read-only** sobre el mismo árbol. Cada uno tiene su propia BBDD; no hay sincronización entre ellos. El cliente principal de música es ND vía Subsonic; JF queda como "fallback web" para reproducción ocasional desde el navegador donde ya estás logueado.
- **Audiolibros, podcasts, radios online**: ND **no** cubre eso bien. Los audiolibros van en Audiobookshelf (`03-audiobookshelf.md`); los podcasts también. Las radios online son posibles vía la "Internet Radio" de Subsonic, pero no se priorizan. ND **no** monta `/mnt/hd2t/media/audiobooks/`.
- **Sincronización de letras (lyrics)**: ND lee `.lrc` sincronizadas locales y muestra letras en clientes que las soportan (Symfonium, Substreamer, la propia UI web). La generación automática de `.lrc` (vía LRClib u otros) no se cubre aquí; reabrible.
- **Multi-tenant**: ND soporta múltiples usuarios con contraseñas independientes, listas de reproducción privadas y favoritos por usuario. Se documenta la creación, pero no el modelo "familia con perfiles infantiles" complejo.
- **Authelia delante de ND**: descartado por las mismas razones que JF y HA. Los clientes Subsonic se autentican con `username + password|token` contra `/rest/...`; Authelia rompería ese flujo.

Cuando este documento se haya aplicado, el operador puede:

- Abrir `https://navidrome.${DOMAIN_LAN}/` desde la LAN (con CA interna instalada) o `https://navidrome.${DOMAIN_TS}/` desde el tailnet, completar el setup inicial (crear admin) y ver su biblioteca de música indexada.
- Configurar **al menos un cliente Subsonic** (DSub o Symfonium en el móvil) apuntando a `https://navidrome.${DOMAIN_LAN}/`, hacer login con un usuario no-admin, y reproducir un álbum.
- Confirmar que ND lee `/mnt/hd2t/media/music/` en `:ro`, que `/mnt/hd2t/apps/navidrome/data/` contiene `navidrome.db`, que `docker compose down && up -d` no pierde nada (catálogo, favoritos, listas).
- Tener la biblioteca de música cubierta para `03-audiobookshelf.md` (que solo se ocupa de audiolibros y podcasts) y para Stash (`05-stash.md`) sin que se pisen rutas ni ficheros.

> **Recordatorio de alcance**: ND es **solo LAN + tailnet**. Las apps móviles Subsonic se conectan vía Tailscale cuando el usuario está fuera de casa; no se abre puerto en el router, no hay DDNS. La caché offline de los clientes (DSub/Symfonium guardan los álbumes descargados localmente) compensa cuando no hay tailnet disponible.

---

## Requisitos Previos

- **Fase 1** completa (sistema base, hostname `pi5`, zona horaria `Europe/Madrid`, **grupo `media` con GID 1100** y `homelab` miembro de él, ver `01-sistema/04-estructura-directorios.md`).
- **Fase 2** completa (Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convención `stacks/<svc>/`; `.env` global con `TZ`, `PUID=1000`, `PGID=1000`, `DOMAIN_LAN`, `DOMAIN_TS` si aplica).
- **Fase 3** completa, en particular:
  - Pi-hole con `address=/lan/192.168.1.10` (cubre `navidrome.${DOMAIN_LAN}` automáticamente).
  - Caddy desplegado y los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` en `Caddyfile`.
  - Tailscale operativo y, si se quiere `navidrome.${DOMAIN_TS}`, `tailscale cert` activo (`03-red/05-tailscale.md`).
- **Fase 4** completa: Authelia desplegado (aunque ND queda en `bypass` por las razones descritas, ver "Decisión: autenticación").
- **Fase 7** opcional pero recomendable: Borgmatic operativo, para incluir `/mnt/hd2t/apps/navidrome/data/` en T1.
- **Documento `01-jellyfin.md` aplicado** (orden lógico de la Fase): no es un bloqueante técnico, ND no depende de JF, pero las decisiones comunes (estructura `apps/`, política de bind mounts `:ro` sobre `/media/`, política de bypass en Authelia, Caddy drop-ins por servicio) ya están tomadas allí y aquí solo se aplican.
- Disco `hd2t` montado en `/mnt/hd2t` con `/mnt/hd2t/media/music/` ya creado por `01-sistema/04-estructura-directorios.md` con owner `homelab:media` y modo `2770` (setgid). Espacio: la BBDD y la caché de transcoding son pequeños (típicamente <500 MiB cada una para bibliotecas medianas).
- Operador con la **CA interna instalada** en navegador y, si se va a usar la app móvil, en el dispositivo (Android/iOS).

Comprobaciones rápidas:

```bash
# La red Docker compartida y Caddy
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok
docker ps --filter name=caddy --format '{{.Names}} {{.Status}}'

# DNS interno resuelve navidrome.lan
dig +short navidrome.lan @192.168.1.2
# 192.168.1.10

# Estructura music/ correcta
getent group media
# media:x:1100:homelab
stat -c '%a %U:%G' /mnt/hd2t/media/music
# 2770 homelab:media

# Que hay música ahí (al menos una pista)
find /mnt/hd2t/media/music -type f \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.ogg' -o -iname '*.m4a' -o -iname '*.opus' \) | head -3
```

---

## Decisión: imagen — `deluan/navidrome` (upstream)

Navidrome **no tiene imagen LinuxServer.io oficial**. Las opciones son:

| Imagen | Mantenedor | Tag de referencia | Pros | Contras |
|---|---|---|---|---|
| `deluan/navidrome` | Equipo upstream (`navidrome.org`) | `:0.53.3` (multi-arch amd64/arm64/armv7) | Imagen oficial, publicada por el creador del proyecto. Multi-arch nativo. Binario Go estático con `ffmpeg` empaquetado. Releases ágiles. | UID/GID por defecto `1000:1000` (cambiable por `ND_DATAFOLDER` permisos + `user:` directiva del compose). |
| Forks no oficiales (varios en Docker Hub) | Comunidad | varios | A veces traen plugins extra (cover art scrapers exóticos). | Menos confiables; abandonos frecuentes. |

**Decisión**: `deluan/navidrome:0.53.3`.

Razones:

- Es la imagen que el proyecto recomienda en su documentación de despliegue. Cualquier issue se reporta limpio sin "es que estoy con el fork X".
- Multi-arch nativo: en la Pi 5 (arm64) se obtiene un binario nativo, no emulado.
- Pin a versión completa (`0.53.3`), no a `latest` ni a `0.53` (los bumps de patch deberían ser benignos pero ND ha tenido en el pasado migraciones de schema entre minores que conviene aplicar deliberadamente).
- **No** se elige LSIO porque no existe; intentar fabricarse uno propio sería sobreingeniería.

Actualizaciones: `docker compose pull && up -d` después de leer release notes. Watchtower etiqueta el contenedor con `homelab.role: "music-server"` y, **dado que el tag es completo**, no hace pull automático.

> **Sobre `:latest`**: ND está en serie 0.x y los autores publican varias releases al mes. Pin estricto evita sorpresas (en 2024 una migración 0.49 → 0.50 cambió la disposición de la BBDD de un fichero único a múltiples; arrancar con `:latest` sin advertirlo dejó a varios homelabs con la BBDD a medio migrar).

---

## Decisión: networking — bridge `homelab` (sin `ports:`)

Igual que Jellyfin (`01-jellyfin.md`):

- ND escucha en `:4533/tcp` dentro del contenedor.
- **Sin `ports:`** publicados al host: Caddy hace `reverse_proxy http://navidrome:4533` resolviendo el nombre por DNS interno del bridge.
- Subsonic API y UI web viajan ambas por el mismo puerto, así que una sola entrada de Caddy cubre todo (la API es `/rest/...` y la UI es `/`, `/app/...`, `/share/...`).
- **WebSockets**: ND usa SSE (Server-Sent Events) para "now playing" y eventos en tiempo real; Caddy v2 los proxypasa sin configuración extra.
- **mDNS/Bonjour para auto-discovery de clientes Subsonic**: opcional. La mayoría de clientes piden la URL a mano; el descubrimiento mDNS no es necesario y no se intenta. Reabrible con `network_mode: host` si surgen casos de uso.

---

## Decisión: dónde viven los datos y permisos

Tres tipos de datos:

| Tipo | Dónde | Owner:Group | Modo | Observaciones |
|---|---|---|---|---|
| **Datos del servicio** (`data/`): BBDD SQLite (`navidrome.db`), caché de carátulas, ficheros de configuración, logs internos. | `/mnt/hd2t/apps/navidrome/data/` | `homelab:homelab` (`1000:1000`) | `0750` | El "alma" de ND. Catálogo, usuarios, favoritos, listas, scrobbles pendientes. Crítico para backup. |
| **Caché de transcoding** (`cache/`): segmentos transcodificados (FLAC→MP3, etc.) que ND reutiliza si el mismo cliente vuelve a pedir el mismo bitrate. | `/mnt/hd2t/apps/navidrome/cache/` | `homelab:homelab` | `0750` | Regenerable. Excluido del backup. Limita su tamaño con `ND_TRANSCODINGCACHESIZE`. |
| **Biblioteca de música** (`/music/...`): los ficheros reales (FLAC/MP3/etc.). | `/mnt/hd2t/media/music/` | `homelab:media` (`1000:1100`) | `2770` (setgid) | Compartido con Jellyfin (`01-jellyfin.md`) y, eventualmente, con cualquier organizador externo. ND lo monta **read-only** (`:ro`): no escribe nunca en la biblioteca. |

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| Volumen Docker nombrado para `data/` | Menos pelea con permisos. | Datos en `/var/lib/docker/volumes/...` (microSD). Aceptable por tamaño (BBDD <500 MiB), pero rompe la convención del homelab. | Descartado. |
| Bind mount con `PUID=0` | Ninguna ventaja real. | Innecesario; ND respeta el `user:` del compose. | Descartado. |
| **Bind mount `homelab:homelab` con `user: "1000:1000"` y `group_add: [1100]`** | UI legible, ACLs simples, biblioteca accesible de lectura sin convertir a ND en propietario. | Ninguno relevante. | **Aceptado**. |

Resultado: bind mounts a `/mnt/hd2t/apps/navidrome/{data,cache}` con `user: "1000:1000"`, `group_add: [1100]` para acceso al árbol `media/`. Biblioteca montada **read-only**.

> **Por qué `:ro` en `/music`**: ND no necesita escritura para hacer su trabajo. Tags, carátulas embebidas, letras `.lrc` se leen, no se escriben. Las carátulas externas (`cover.jpg` junto al álbum) tampoco se generan por ND. La caché de carátulas escaladas vive en `data/cache/`. Montar `:ro` es defensa en profundidad: ningún bug puede borrar la biblioteca.

> **Por qué `data/` y no volumen Docker**: `data/` y la BBDD SQLite hacen escrituras frecuentes (cada scrobble, cada cambio de favorito). Acabar en microSD = degradación. Va en `hd2t`.

---

## Decisión: autenticación — ND nativa, **no** Authelia

ND tiene autenticación nativa con cuentas locales y contraseñas. Meterlo detrás del `forward_auth` de Authelia es contraindicado, por razones gemelas a las de Jellyfin:

| Razón | Impacto |
|---|---|
| **Subsonic API** (`/rest/...`) | Los clientes Subsonic mandan `username` + `token` (`md5(password+salt)`) o `password` plano en cada petición HTTP. **No mantienen cookies**; cada request es independiente. Authelia, que es cookie-based, los ve como "no autenticados" y los redirige al portal. **Resultado**: ningún cliente Subsonic funciona. |
| **Streaming de audio** (`/rest/stream`, `/rest/download`) | URLs autenticadas con `?u=...&t=...&s=...` no llevan cookie de Authelia. |
| **Carátulas** (`/rest/getCoverArt`) | Se piden por URL pública directa con auth en query string. Authelia rompe. |
| **Compartidos** (`/share/<token>`) | Las URLs públicas para compartir pistas con terceros sin cuenta dejarían de funcionar (la idea es justamente "sin cuenta"). |
| **UI web (`/app/`)** | Esta sí podría meterse detrás de Authelia, pero es **incoherente**: tendrías que hacer un split por path, manteniendo `/rest/`, `/share/`, `/auth/login` (login propio de ND) sin Authelia y `/app/` con Authelia. Frágil. |

La política sana: **ND gestiona su propia autenticación**. Compensaciones:

- ND **no** sale de la LAN/tailnet. Quien quiera atacar el endpoint Subsonic necesita ya estar dentro.
- Tras N intentos fallidos ND no aplica lockout nativo (a diferencia de JF), pero **`fail2ban` (Fase 4) puede añadir un jail para `Navidrome`** parseando `data/navidrome.log`. Reabrible.
- **Contraseñas fuertes obligatorias**: ND no tiene política de complejidad; el operador es responsable. Mínimo 16 caracteres por usuario, gestionado en gestor de contraseñas.
- **Cuenta admin separada** del uso diario.

Reflejo en Caddy: `Caddyfile` para ND importa **solo** `lan_tls`, `security_headers`, `healthcheck`; **no** `authelia_two_factor`. En Authelia, `navidrome.${DOMAIN_LAN}` queda en `bypass`:

```yaml
# stacks/authelia/conf.d/09-navidrome-bypass.yml
- domain: "navidrome.{$DOMAIN_LAN}"
  policy: bypass
- domain: "navidrome.{$DOMAIN_TS}"
  policy: bypass
```

> **Si un día se quiere SSO real**: ND tiene desde 0.51 soporte experimental para reverse-proxy auth (`ND_REVERSEPROXYUSERHEADER`, `ND_REVERSEPROXYWHITELIST`). Eso permite, **solo para la UI web**, delegar el login a Authelia y que ND confíe en la cabecera `Remote-User`. La API Subsonic sigue requiriendo auth nativa. Reabrible con configuración cuidadosa.

---

## Stack: `stacks/navidrome/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/navidrome/docker-compose.yml` | microSD (git) | Stack (servicio `navidrome`). |
| `stacks/navidrome/.env.example` | microSD (git) | Plantilla con variables específicas del stack (Last.fm/ListenBrainz opcionales). |
| `stacks/caddy/conf.d/09-navidrome.caddy` | microSD (git) | Drop-in del bloque LAN+tailnet para `navidrome.${DOMAIN_LAN}` y `navidrome.${DOMAIN_TS}`. |
| `stacks/authelia/conf.d/09-navidrome-bypass.yml` | microSD (git) | Fragmento de access_control para añadir bypass de `navidrome.*`. |
| `/mnt/hd2t/apps/navidrome/data/` | hd2t | BBDD SQLite, configuración, caché de carátulas. Owner `homelab:homelab`, modo `0750`. |
| `/mnt/hd2t/apps/navidrome/cache/` | hd2t | Caché de transcoding. Owner `homelab:homelab`, modo `0750`. |
| `/mnt/hd2t/media/music/` | hd2t | **Read-only** desde ND. Owner `homelab:media`, modo `2770`. Compartido con Jellyfin. |

### `stacks/navidrome/docker-compose.yml`

```yaml
# Navidrome — servidor de música del homelab.
# Documentado en docs/09-multimedia/02-navidrome.md.
#
# Networking: bridge homelab. Caddy hace reverse proxy hacia navidrome:4533.
# La biblioteca /mnt/hd2t/media/music/ se monta read-only.

name: navidrome

networks:
  homelab:
    external: true

services:
  navidrome:
    image: deluan/navidrome:0.53.3
    container_name: navidrome
    hostname: navidrome
    restart: unless-stopped

    # ND respeta el user del compose. Coincidir con homelab:homelab (1000:1000)
    # y añadir el grupo media (1100) para abrir /mnt/hd2t/media/music/.
    user: "1000:1000"
    group_add:
      - "1100"   # media (creado en 01-sistema/04-estructura-directorios.md)

    networks:
      - homelab

    # NO se publican puertos al host: el acceso humano va por Caddy
    # (https://navidrome.lan). Subsonic API y UI web comparten el mismo puerto.

    environment:
      TZ: ${TZ}
      # --- Identidad y datos ---------------------------------------------
      ND_DATAFOLDER: "/data"
      ND_MUSICFOLDER: "/music"
      ND_CACHEFOLDER: "/cache"
      ND_LOGLEVEL: "info"
      # --- Comportamiento del escaneo -----------------------------------
      ND_SCANSCHEDULE: "@every 6h"      # full scan cada 6 horas (la biblioteca cambia poco)
      ND_SCANNER_GROUPALBUMRELEASES: "true"   # une re-releases del mismo álbum
      ND_ENABLEEXTERNALSERVICES: "true" # permite scraping opcional (Last.fm artist info, etc.)
      # --- URL canónica detrás del reverse proxy -------------------------
      ND_BASEURL: ""                    # vacío: no servimos en /navidrome sino en raíz del subdominio
      # --- Reverse proxy / TLS -------------------------------------------
      ND_REVERSEPROXYWHITELIST: "172.30.10.0/24"  # solo Caddy del bridge homelab
      # --- Transcoding ---------------------------------------------------
      ND_TRANSCODINGCACHESIZE: "1GiB"   # límite de la caché de transcoding
      ND_DEFAULTDOWNSAMPLINGFORMAT: "opus"
      # --- Reproducción y UI ---------------------------------------------
      ND_AUTOIMPORTPLAYLISTS: "true"    # importa .m3u en /music a listas
      ND_DEFAULTTHEME: "Dark"
      ND_ENABLESHARING: "true"          # permite generar URLs /share/<token>
      ND_DEFAULTDOWNLOADABLESHARE: "false"
      # --- Integraciones (opcionales; se rellenan en .env) ---------------
      ND_LASTFM_ENABLED: "${ND_LASTFM_ENABLED:-false}"
      ND_LASTFM_APIKEY: "${ND_LASTFM_APIKEY:-}"
      ND_LASTFM_SECRET: "${ND_LASTFM_SECRET:-}"
      ND_LASTFM_LANGUAGE: "es"
      ND_LISTENBRAINZ_ENABLED: "${ND_LISTENBRAINZ_ENABLED:-false}"
      ND_LISTENBRAINZ_BASEURL: "https://api.listenbrainz.org/1/"
      # --- Métricas Prometheus (Fase 5) ---------------------------------
      ND_PROMETHEUS_ENABLED: "true"
      ND_PROMETHEUS_METRICSPATH: "/metrics"

    volumes:
      - /mnt/hd2t/apps/navidrome/data:/data
      - /mnt/hd2t/apps/navidrome/cache:/cache
      # Biblioteca: read-only por política (ND no necesita escribir aquí).
      - /mnt/hd2t/media/music:/music:ro
      - /etc/localtime:/etc/localtime:ro

    healthcheck:
      # /ping responde 200 con {"status":"OK"} cuando ND tiene la BBDD abierta.
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:4533/ping"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 60s

    labels:
      homelab.role: "music-server"
      homelab.backup: "true"
      # Watchtower NO actualiza automáticamente: el tag es completo y los
      # bumps de minor de ND a veces requieren atención (migraciones).
      com.centurylinklabs.watchtower.enable: "false"
```

> **Sobre `ND_SCANSCHEDULE`**: ND tiene **scan watcher** automático (vía inotify) y **scan periódico**. El watcher cubre el caso "cae un fichero nuevo, ND lo detecta en segundos"; el periódico hace una pasada completa que corrige inconsistencias. `@every 6h` es un compromiso: una biblioteca de música cambia poco, no necesita escaneos cada hora. Si los `*arr` (Fase 10) descargan música a esta carpeta, el watcher se activa solo y aún así una pasada completa cada 6 h limpia desincronizaciones.

> **Sobre `ND_REVERSEPROXYWHITELIST`**: aunque NO usamos `ND_REVERSEPROXYUSERHEADER` (no delegamos auth al proxy), declarar la whitelist evita que ND honre cabeceras `X-Forwarded-*` desde IPs no confiables. Solo Caddy en `172.30.10.0/24` puede setearlas.

> **Sobre `wget` en el healthcheck**: la imagen `deluan/navidrome` está basada en Alpine y trae `wget`. No incluye `curl`. Si en algún momento upstream cambia la base, sustituir por lo que esté disponible.

> **Sobre `ND_DEFAULTDOWNSAMPLINGFORMAT: opus`**: cuando un cliente pide bitrate menor al original, ND transcodifica al formato configurado. **Opus** ofrece la mejor calidad/tasa para audio (mejor que MP3 a igualdad de kbps). Casi todos los clientes Subsonic modernos lo decodifican; los pocos que no (DSub muy antiguo) caerán a MP3 si se cambia a `mp3`. Reabrible.

### `stacks/navidrome/.env.example`

```bash
# stacks/navidrome/.env.example
# Variables específicas del stack Navidrome. Las generales (TZ, PUID, PGID,
# DOMAIN_LAN, DOMAIN_TS) vienen del .env GLOBAL del homelab.
#
# Last.fm scrobbling (opcional). Para activarlo:
#   1) Crear cuenta en https://www.last.fm/ y obtener API key + secret en
#      https://www.last.fm/api/account/create
#   2) Rellenar abajo y poner ND_LASTFM_ENABLED=true.
#   3) Cada usuario de ND vincula su cuenta personal desde Settings.
ND_LASTFM_ENABLED=false
ND_LASTFM_APIKEY=
ND_LASTFM_SECRET=

# ListenBrainz scrobbling (opcional, alternativa abierta a Last.fm).
# No requiere API key del operador del homelab; cada usuario pega su propio
# token personal desde la UI de ND tras activar este flag.
ND_LISTENBRAINZ_ENABLED=false
```

### Drop-in de Caddy: `stacks/caddy/conf.d/09-navidrome.caddy`

```caddy
# /etc/caddy/conf.d/09-navidrome.caddy — bloques de Navidrome.
# Documentado en docs/09-multimedia/02-navidrome.md.
#
# IMPORTANTE: NO se importa authelia_two_factor (decisión documentada en
# "Decisión: autenticación"). ND gestiona su propio login y la API Subsonic
# usa tokens propios.

# ---- Acceso LAN ------------------------------------------------------------
navidrome.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    reverse_proxy http://navidrome:4533 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # Streams de audio pueden ser largos; subir el read_timeout aunque
        # rara vez se acerca al límite (un álbum de 70 min en FLAC).
        transport http {
            read_timeout 4h
            write_timeout 4h
        }
    }

    # Subir el límite de body para uploads de carátulas grandes desde la UI
    # (subir cover.jpg manualmente a un álbum) y para imports de playlists.
    request_body {
        max_size 25MB
    }
}

# ---- Acceso Tailscale ------------------------------------------------------
# Solo se materializa si DOMAIN_TS está definido (tailnet con tailscale cert).
navidrome.{$DOMAIN_TS} {
    tls {
        get_certificate tailscale
    }
    import security_headers
    import healthcheck

    reverse_proxy http://navidrome:4533 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        transport http {
            read_timeout 4h
            write_timeout 4h
        }
    }

    request_body {
        max_size 25MB
    }
}
```

> **Sobre `read_timeout 4h`**: las conexiones Subsonic son típicamente "una pista, una request". Un álbum entero se puede transmitir en una sola sesión HTTP/2 multiplexada que dure toda la escucha; 4 h es holgadamente suficiente y mucho más bajo que el de JF (videos largos no aplican aquí).

### Fragmento de Authelia: `stacks/authelia/conf.d/09-navidrome-bypass.yml`

```yaml
# stacks/authelia/conf.d/09-navidrome-bypass.yml
# Excluir Navidrome del control de acceso de Authelia.
# Se incluye desde stacks/authelia/configuration.yml mediante el mecanismo
# de merge documentado en 04-seguridad/01-authelia.md.

- domain: "navidrome.{$DOMAIN_LAN}"
  policy: bypass
- domain: "navidrome.{$DOMAIN_TS}"
  policy: bypass
```

### Crear directorios y desplegar

```bash
# Cargar variables globales en el shell (ver quirk Compose v2 en 02-estructura-compose.md)
cd /home/homelab/homelab
set -a; source .env; set +a

# 1) Verificar prerequisitos de estructura (Fase 1).
getent group media | grep -q '^media:x:1100:' || {
    echo "ERROR: grupo media (GID 1100) no existe. Aplicar 01-sistema/04-estructura-directorios.md."
    exit 1
}
[ -d /mnt/hd2t/media/music ] || {
    echo "ERROR: /mnt/hd2t/media/music no existe. Aplicar 01-sistema/04-estructura-directorios.md."
    exit 1
}

# 2) Crear directorios persistentes del servicio (idempotente).
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/navidrome
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/navidrome/data
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/navidrome/cache

# 3) Materializar Caddy drop-in y fragmento de Authelia.
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/09-navidrome.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/09-navidrome.caddy

install -o homelab -g homelab -m 0644 \
    stacks/authelia/conf.d/09-navidrome-bypass.yml \
    /mnt/hd2t/apps/authelia/etc/conf.d/09-navidrome-bypass.yml

# 4) .env del stack: copiar la plantilla y, si se quiere Last.fm, rellenar.
cp stacks/navidrome/.env.example stacks/navidrome/.env
chmod 0600 stacks/navidrome/.env
# editar stacks/navidrome/.env si se desea activar Last.fm/ListenBrainz.

# 5) Levantar el stack.
docker compose \
    -f stacks/navidrome/docker-compose.yml \
    --env-file stacks/navidrome/.env \
    up -d

# 6) Recargar Caddy y Authelia para tomar drop-ins.
docker exec caddy caddy validate --config /etc/caddy/Caddyfile && \
    docker kill --signal=SIGUSR1 caddy
docker exec authelia kill -HUP 1 || \
    docker compose -f stacks/authelia/docker-compose.yml restart authelia
```

Tras `up -d`:

```bash
docker ps --filter name=navidrome
# CONTAINER ID  IMAGE                       STATUS
# ...           deluan/navidrome:0.53.3     Up 1 minute (healthy)

docker logs navidrome --tail 30
# ... INFO Starting Navidrome version=0.53.3 ...
# ... INFO Loading configuration ConfigFile= ...
# ... INFO Opening DataBase path=/data/navidrome.db ...
# ... INFO Server starting address=0.0.0.0:4533 ...

# Confirmar puertos NO publicados al host
ss -tlnp | grep ':4533' || echo "OK: navidrome NO publica puertos al host"
# OK: navidrome NO publica puertos al host

# Probar el endpoint vía Caddy
curl -ksI https://navidrome.lan/ping
# HTTP/2 200
```

---

## Configuración

### 1) Setup inicial

Desde un cliente de la LAN con la CA interna instalada:

```text
1. Abrir https://navidrome.lan/
2. ND muestra el formulario "Create your administrator account":
   - Username: admin
   - Password: gestor de contraseñas; mínimo 16 caracteres
   - Confirm Password: igual
3. Submit. Redirige al login → introducir admin / <password>.
4. Aparece la UI vacía: "No tracks found". Esto es normal: ND aún no ha
   escaneado /music.
```

> **Si el formulario no aparece**: ya hay configuración previa (`/mnt/hd2t/apps/navidrome/data/navidrome.db` existe). Si no es la deseada, parar el contenedor, **borrar el contenido de `data/`** (perderás usuarios y stats) y volver a levantar.

### 2) Forzar el primer escaneo

`Settings (icono perfil arriba derecha) → Settings → "Force Full Scan"` o desde la línea de comandos:

```bash
# Vía Subsonic API (usuario admin, password en query)
curl -ks "https://navidrome.lan/rest/startScan.view?u=admin&p=<password>&v=1.16.1&c=homelab&f=json"
# {"subsonic-response":{"status":"ok",...}}
```

El primer escaneo de una biblioteca razonable (5000–15000 pistas) tarda **5–20 minutos** en una Pi 5 con `hd2t` USB 3.0; depende del estado de los tags y de si hay carátulas externas grandes. ND lee tags en streaming, no carga ficheros enteros, y el tiempo se domina por IOPS del disco.

Verificar progreso:

```bash
docker logs -f navidrome | grep -i scan
# ... INFO Scanner: Starting full scan ...
# ... INFO Scanner: Processed 1234 files (12.34%) ...
# ... INFO Scanner: Finished. Added=4567 Updated=12 Removed=0 Errors=3 Time=8m12s
```

### 3) Crear los usuarios del hogar

`Settings → Users → Add User`:

```text
- Username: <nombre del miembro>
- Password: gestor de contraseñas
- IsAdmin: OFF (solo el admin original es admin)
```

Cada usuario hereda acceso a **toda** la biblioteca: ND no tiene bibliotecas separadas por usuario (sí "favoritos" privados, "playlists" privadas, "recently played" personal). Si se quiere segmentación de catálogo (ej. niños no ven explicit lyrics), no es la herramienta correcta; mejor usar perfiles a nivel cliente o filtrar en Sonarr/Lidarr al descargar.

> **Sobre la cuenta admin**: usar `admin` solo para administración (gestión de usuarios, escaneos forzados, ajustes). Para escuchar música en el día a día, crear un usuario propio sin permisos de admin.

### 4) Vincular Last.fm / ListenBrainz por usuario

Si en `.env` se activó `ND_LASTFM_ENABLED=true` o `ND_LISTENBRAINZ_ENABLED=true`, **cada usuario** debe vincular su cuenta personal desde su perfil:

```text
Settings (icono usuario) → Personal → Last.fm:
   "Link"  → abre last.fm/api/auth, autorizar.
Settings → Personal → ListenBrainz:
   "Link"  → pegar token personal de https://listenbrainz.org/profile/
```

Una vez vinculado, cada reproducción se scrobblea automáticamente a la cuenta del usuario.

### 5) Configurar clientes Subsonic en los dispositivos

#### Android: DSub o Symfonium

| Cliente | Repo / Tienda | Características | Comentario |
|---|---|---|---|
| **DSub** | F-Droid (`com.thejoshwa.ultrasonic.androidapp`) — mantenido por la comunidad | Clásico, gratis, funcional, UI 2010s. Caché offline robusta. | Recomendado si "solo quiero que suene". |
| **Symfonium** | Play Store (de pago, ~9 €) | UI moderna Material 3, ecualizador, sleep timer, lyrics, ChromeOS, Android Auto, escenas. | Recomendado si te tomas la música en serio. |
| **Substreamer** | Play Store (free + IAP) | Buen Android Auto, lyrics LRC. | Alternativa intermedia. |

Configuración (cualquiera de los anteriores):

```text
Server URL:  https://navidrome.lan
              (o https://navidrome.<ts-tailnet>.ts.net si fuera de casa)
Username:    <usuario no-admin>
Password:    <password>
SSL:         Trust all certs = NO si CA interna instalada en el sistema;
                              = YES como atajo (peor higiene).
```

> **CA interna en Android**: a partir de Android 7, los certificados instalados como "user CA" no son confiados por las apps salvo que su `network_security_config` los permita. La mayoría de clientes Subsonic populares **sí** lo permiten (DSub, Symfonium). Si la app no acepta el cert, alternativas: (a) usar Tailscale, que trae cert legítimo en `navidrome.<ts-tailnet>.ts.net`; (b) marcar "Trust all certs" en la app (solo aceptable en LAN, no en tailnet).

#### iOS: Amperfy o play:Sub

| Cliente | Tienda | Características |
|---|---|---|
| **Amperfy** | App Store (gratis, código abierto) | UI nativa iOS, buena integración con CarPlay, Siri Shortcuts. |
| **play:Sub** | App Store (de pago) | Veterano, robusto, muy configurable. |
| **Substreamer** | App Store (free + IAP) | Misma codebase que en Android. |

Configuración análoga.

#### Escritorio: Feishin o Sonixd

| Cliente | Plataforma | Comentario |
|---|---|---|
| **Feishin** | Linux/macOS/Win, Electron | Sucesor mantenido de Sonixd. UI moderna. |
| **Sonixd** | Linux/macOS/Win, Electron | Original, sin mantenimiento activo. |
| Cliente web propio de ND | Cualquier navegador | Si no quieres instalar nada. |

### 6) Compartir álbumes con terceros (opcional)

Con `ND_ENABLESHARING=true`, desde la UI:

```text
1. Buscar el álbum o pista.
2. Click en "..." → "Share".
3. Configurar:
   - Description: opcional
   - Expiration: 1 hora / 1 día / 1 semana / nunca
   - Downloadable: NO (default; recomendado: stream-only)
4. Copiar la URL: https://navidrome.lan/share/<token>
5. Mandar a quien quieras. Cualquiera con la URL escucha sin cuenta.
```

> **Aviso**: las URLs `/share/...` también son `bypass` en Authelia (queda dentro de `navidrome.${DOMAIN_LAN}`, todo el subdominio está exonerado). El control de acceso lo hace ND con el token. Si el destinatario está fuera del homelab, necesitará que la URL sea **navidrome.<ts-tailnet>.ts.net** y que el destinatario esté en el tailnet, **o bien** abrir tunnel ad-hoc (Tailscale Funnel, fuera de alcance del homelab actual).

### 7) Plugins y extensiones — no aplica

ND no tiene sistema de plugins (a diferencia de JF). Lo que aporta lo aporta de fábrica. Las únicas "extensiones" son:

- Integraciones externas vía variables de entorno (Last.fm, ListenBrainz, ya cubiertas).
- Scrobbling vía Subsonic (clientes Subsonic envían `/rest/scrobble` y ND retransmite a Last.fm/LB si está vinculado).

### 8) Operación diaria

| Acción | Comando |
|---|---|
| Ver el log activo | `docker logs navidrome -f` |
| Reescaneo manual | UI: Settings → "Force Full Scan", o `curl -ks "https://navidrome.lan/rest/startScan.view?u=admin&p=...&v=1.16.1&c=cli&f=json"` |
| Reiniciar ND | `docker compose -f stacks/navidrome/docker-compose.yml restart navidrome` |
| Backup manual del data | `sudo tar czf /mnt/hd2t/backups/nd-snapshot-$(date +%F).tgz -C /mnt/hd2t/apps/navidrome data` |
| Tamaño actual de la BBDD | `du -sh /mnt/hd2t/apps/navidrome/data/navidrome.db` |
| Limpiar caché transcoding | `docker exec navidrome rm -rf /cache/audio` (con ND parado), o esperar al GC automático (`ND_TRANSCODINGCACHESIZE` lo limita) |
| Listar usuarios activos | UI: Settings → Users; o consulta SQLite `sqlite3 /mnt/hd2t/apps/navidrome/data/navidrome.db 'SELECT user_name FROM "user";'` |
| Ver pistas reproducidas hoy | UI: Home → "Recently Played" |

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/navidrome/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/navidrome/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/navidrome/.env` | microSD | `homelab:homelab` | `0600` | Secretos (Last.fm API key/secret si aplica). |
| `/home/homelab/homelab/stacks/caddy/conf.d/09-navidrome.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy. |
| `/home/homelab/homelab/stacks/authelia/conf.d/09-navidrome-bypass.yml` | microSD | `homelab:homelab` | `0644` | Fragmento de bypass. |
| `/mnt/hd2t/apps/navidrome/data/` | hd2t | `homelab:homelab` | `0750` | Datos del servicio. **Crítico**, se respalda. |
| `/mnt/hd2t/apps/navidrome/data/navidrome.db` | hd2t | `homelab:homelab` | `0640` | BBDD principal (catálogo, usuarios, favoritos, listas). |
| `/mnt/hd2t/apps/navidrome/data/cache/` | hd2t | `homelab:homelab` | `0750` | Caché de carátulas escaladas. **No se respalda** (regenerable). |
| `/mnt/hd2t/apps/navidrome/cache/` | hd2t | `homelab:homelab` | `0750` | Caché de transcoding. **No se respalda**. |
| `/mnt/hd2t/media/music/` | hd2t | `homelab:media` | `2770` | **No se respalda** desde ND (compartido con JF; misma política que en `01-jellyfin.md`). Bind mount `:ro`. |

> **Tamaño esperado**. Para una biblioteca de ~10000 pistas, `data/navidrome.db` se estabiliza en torno a **50–200 MiB**. La caché de carátulas (`data/cache/`) puede crecer hasta unos cientos de MiB según resoluciones generadas. La caché de transcoding (`/cache/`) está limitada por `ND_TRANSCODINGCACHESIZE=1GiB` (configurable). Reservar **2 GiB** es holgado.

> **Por qué no microSD**. Como en JF: SQLite + escrituras frecuentes (cada scrobble, cada favorito, cada actualización del watcher) en microSD = cuenta atrás para corrupción.

> **Sobre `data/cache/`**. ND mantiene una caché interna de imágenes escaladas (carátulas a 200×200, 600×600, etc.) dentro de `data/`. Es regenerable pero pesada en IOPS al regenerar. Se incluye implícitamente en el respaldo del subárbol `data/` para evitar 1–2 horas de regeneración tras restore; si el espacio Borg molesta, se puede excluir.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/navidrome/docker-compose.yml`, `.env.example` | Versionados. |
| `stacks/navidrome/.env` | **NO** versionado (secretos Last.fm). En `.gitignore`. |
| `stacks/caddy/conf.d/09-navidrome.caddy` | Versionado. |
| `stacks/authelia/conf.d/09-navidrome-bypass.yml` | Versionado. |
| Decisiones (imagen upstream, bridge, sin Authelia, biblioteca `:ro`) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Tier (`07-backups/01-estrategia-backup.md`) | Por qué |
|---|---|---|---|
| `/mnt/hd2t/apps/navidrome/data/navidrome.db` | Sí. | T1 | Catálogo, usuarios, contraseñas hashed (bcrypt), favoritos, listas, scrobbles pendientes. **Pérdida = re-escaneo + re-creación manual de listas y favoritos**. |
| `/mnt/hd2t/apps/navidrome/data/navidrome.toml` | Sí (si existe). | T1 | Config persistente que ND escribe. |
| `/mnt/hd2t/apps/navidrome/data/cache/` | Sí (T3) o excluido. | T3 | Carátulas escaladas. Regenerable pero ahorra tiempo tras restore. |
| `/mnt/hd2t/apps/navidrome/cache/` | **No.** | T4 | Transcoding cache, regenerable bajo demanda. |
| `/mnt/hd2t/media/music/` | **No.** | T5 | **Política del homelab**: la biblioteca multimedia es voluminosa y reconstituible desde la fuente externa (rips propios, compras digitales). No se respalda desde ND (la decisión y matices están en `01-jellyfin.md` y en `07-backups/01-estrategia-backup.md`). |

Entrada en `borgmatic.yaml` (parche relativo al patrón de `07-backups/02-borgmatic.md`):

```yaml
source_directories:
  # ...
  - /mnt/hd2t/apps/navidrome/data

# Excluir lo regenerable (la transcoding cache vive fuera de data/, así que
# no necesita exclusión explícita; solo refinamos la cache de carátulas).
patterns:
  # ...
  # Si se quiere ahorrar espacio en Borg a costa de regeneración tras restore:
  # - '!/mnt/hd2t/apps/navidrome/data/cache'

# Hooks: snapshot consistente de SQLite antes del backup.
before_backup:
  - 'docker exec navidrome sqlite3 /data/navidrome.db ".backup ''/data/navidrome.db.borg''"'
after_backup:
  - 'docker exec navidrome rm -f /data/navidrome.db.borg'
```

> **Política sobre la BBDD**. Snapshot consistente con `.backup` de SQLite (atómico). Para una BBDD de ~100 MiB, el snapshot tarda <1 s.

> **Política sobre `/mnt/hd2t/media/music/`**. Excluida del backup, igual que el resto de `media/`. Si la biblioteca contiene grabaciones únicas (ensayos personales, demos) que no se pueden recuperar, separarlas a `/mnt/hd2t/personal/music/` (fuera de `media/`) y respaldarlas como archivos personales.

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/navidrome/docker-compose.yml up -d --force-recreate
# ND reusa /mnt/hd2t/apps/navidrome/data: arranque normal en ~10 s,
# todos los usuarios, favoritos, listas siguen ahí.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear Fases 1 → 7.
2. `borgmatic extract --archive latest --path mnt/hd2t/apps/navidrome`.
3. Verificar permisos: `sudo chown -R homelab:homelab /mnt/hd2t/apps/navidrome && sudo chmod 0750 /mnt/hd2t/apps/navidrome/data`.
4. Confirmar/recrear `/mnt/hd2t/media/music` (vacío al inicio; reabsorber contenido por separado).
5. `docker compose -f stacks/navidrome/docker-compose.yml up -d`.
6. `https://navidrome.lan` → login con credenciales pre-existentes; cuando se vuelva a poblar `/music`, ND re-escanea y la BBDD restaurada re-asocia (los IDs internos son hashes de path + tags).

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `https://navidrome.lan` da `502 Bad Gateway` | Caddy no resuelve `navidrome` (contenedor caído o no en la red `homelab`). | `docker ps --filter name=navidrome`. Si está caído, `docker logs navidrome --tail 100`. Si está vivo: `docker network inspect homelab` debe listarlo. |
| UI carga pero "No tracks found" tras primer escaneo | ND no encuentra ficheros en `/music`, o no tiene permisos. | `docker exec navidrome ls /music | head`. Si vacío: revisar bind mount; si "Permission denied": `group_add: ["1100"]` y permisos `2770` en el árbol. |
| Logs ND: `error reading directory: permission denied` | El usuario interno (1000) no es miembro del grupo `media` (1100). | Confirmar `group_add` del compose. `docker exec navidrome id` debe listar `1100`. |
| Cliente Subsonic responde "Wrong username or password" pero web sí entra | El cliente está enviando token con salt MD5; ND lo soporta. Más probable: el cliente está apuntando a una URL distinta (`http://...:4533` directo en lugar de `https://navidrome.lan`). | Apuntar el cliente a `https://navidrome.lan` (puerto implícito 443). Confirmar que el dispositivo tiene CA interna o usar tailnet. |
| Cliente Subsonic: "Network error" / "Connection failed" en LAN | El móvil usa DNS distinto (CGNAT del operador) que no resuelve `navidrome.lan`. | Forzar el móvil a usar Pi-hole (DHCP del router → Primary DNS = 192.168.1.2) o añadir `navidrome.lan -> 192.168.1.10` al DNS del dispositivo. |
| Reproducción se corta cada N segundos | Caché de transcoding lleno (`ND_TRANSCODINGCACHESIZE` muy bajo) o disco saturado. | `df -h /mnt/hd2t`; subir `ND_TRANSCODINGCACHESIZE` o cambiar a Direct Play (cliente que no fuerce transcoding). |
| Carátulas no aparecen en cliente Subsonic | El cliente no soporta carátulas embebidas en tags y la biblioteca no tiene `cover.jpg` por carpeta. | Embeber carátula con `metaflac --import-picture-from=...` (FLAC) o `eyeD3 --add-image=...` (MP3); o crear `cover.jpg` por carpeta. ND prefiere carátulas externas si existen. |
| Last.fm scrobbling no funciona aunque está activo en `.env` | Cada usuario debe vincular **su** cuenta personal desde su perfil. El flag global solo "habilita la opción". | Settings → Personal → Last.fm → Link. |
| Al cambiar `ND_BASEURL` ND se queda en bucle de redirect | Caddy y `ND_BASEURL` discrepan sobre subpath. | Mantener `ND_BASEURL=""` y servir en raíz del subdominio (recomendado en este homelab). |
| Logs ND: "Error scanning file: invalid metadata" en algunas pistas | Tags corruptos o codificaciones extrañas (Win1252 en MP3 viejos). | Re-tagging con MusicBrainz Picard. ND continúa con el resto; la pista problemática queda fuera del catálogo. |
| Tras `docker compose pull`, ND no arranca: "database migration failed" | Bump de minor con migración fallida (raro). | Restore `data/navidrome.db` desde el snapshot Borg de la noche anterior. Reportar issue upstream con el log de migración. |
| Symfonium / DSub: "TLS handshake failed" en `https://navidrome.lan` | El móvil no tiene la CA interna instalada o la app no la confía. | Instalar la CA en el sistema, o usar tailnet (`navidrome.<ts-tailnet>.ts.net` con cert legítimo). |
| Symfonium reporta "transcoding format not supported" | El cliente pidió un formato que ND no transcodifica (caso muy raro). | Bajar el bitrate desde la app o cambiar `ND_DEFAULTDOWNSAMPLINGFORMAT` a `mp3`. |
| `Authelia` interfiere a pesar del bypass | El fragmento `09-navidrome-bypass.yml` no se cargó en `configuration.yml`. | `docker logs authelia | grep navidrome`; revisar la inclusión del fragmento; reiniciar Authelia. |
| `https://navidrome.lan` muestra cert "no confiable" tras instalar la CA | Caddy no recargó el `Caddyfile` (drop-in nuevo). | `docker exec caddy caddy validate --config /etc/caddy/Caddyfile && docker kill --signal=SIGUSR1 caddy`. |
| Listas .m3u no se importan automáticamente | Deshabilitado, o las rutas dentro del .m3u son absolutas del host (no `/music/...`). | Activar `ND_AUTOIMPORTPLAYLISTS=true`; reescribir las .m3u con rutas relativas a `/music/` o absolutas dentro del contenedor. |

---

## Decisiones que **no** se toman en este documento

- **Authelia delante de ND**: descartado por compatibilidad con clientes Subsonic. Reabrible con `ND_REVERSEPROXYUSERHEADER` solo para la UI web.
- **Reverse-proxy auth (`ND_REVERSEPROXYUSERHEADER`)**: reabrible cuando el homelab tenga LDAP/SSO sólido y se pueda federar.
- **Lidarr / `*arr` para descarga automática de música**: pertenece a Fase 10. ND se despliega aquí *consumiendo* `/mnt/hd2t/media/music/`; quién y cómo escribe ahí es problema de Fase 10.
- **Migración a Subsonic, Airsonic-Advanced, Gonic, LMS**: hay alternativas pero ND es el actualmente más activo y mejor soportado en clientes. Reabrible si el proyecto se estanca.
- **Indexación de podcasts en ND**: ND tiene soporte nominal de podcasts en su roadmap, pero no maduro. Audiobookshelf (`03-audiobookshelf.md`) los cubre mejor; ND **no** los gestiona.
- **Generación automática de letras `.lrc`**: requiere un servicio externo (LRClib, Musixmatch). Reabrible.
- **Backups del catálogo de música**: política deliberada de no respaldar `/mnt/hd2t/media/music/` desde ND (igual que JF). Documentada arriba.
- **Streaming jukebox** (control remoto del audio del servidor): ND lo expone vía Subsonic API (`/rest/jukeboxControl`), pero la Pi 5 no tiene salida de audio cableada al sistema de sonido del salón. Reabrible si se conecta un DAC USB.

---

## Verificación Final

Antes de pasar a `03-audiobookshelf.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/navidrome/docker-compose.yml ps` | `navidrome ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect navidrome --format '{{.Config.Image}}'` | `deluan/navidrome:0.53.3` |
| Conectado a la red homelab y NO a host | `docker inspect navidrome --format '{{.HostConfig.NetworkMode}}'` | `default` o `homelab` (no `host`) |
| Sin puertos publicados al host | `docker port navidrome` | salida vacía |
| `navidrome.lan` resuelve al IP de la Pi | `dig +short navidrome.lan @192.168.1.2` | `192.168.1.10` |
| Caddy sirve `navidrome.lan` con cert de la CA interna | `echo \| openssl s_client -connect navidrome.lan:443 -servername navidrome.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| Health endpoint responde | `curl -ksS https://navidrome.lan/ping` | `{"status":"OK","version":"0.53.3"}` |
| Usuario interno con grupos correctos | `docker exec navidrome id` | `uid=1000 gid=1000 groups=1000,1100` |
| `/music` montado read-only | `docker exec navidrome sh -c 'touch /music/.write_test 2>&1 \| head -1'` | `touch: ... Read-only file system` |
| Subsonic API responde a un usuario válido | `curl -ks "https://navidrome.lan/rest/ping.view?u=admin&p=<pass>&v=1.16.1&c=cli&f=json"` | `{"subsonic-response":{"status":"ok",...}}` |
| Catálogo poblado tras escaneo | UI: pantalla principal con álbumes; o `curl ".../rest/getArtists.view?..."` | lista no vacía |
| Login funciona desde navegador | navegador con CA instalada | UI carga el dashboard tras login |
| Cliente Subsonic real funciona | DSub/Symfonium en móvil | reproducción de un álbum sin errores |
| Owner correcto del data | `stat -c '%u:%g %a' /mnt/hd2t/apps/navidrome/data` | `1000:1000 750` |
| Authelia bypass para `navidrome.lan` | `curl -ksI https://navidrome.lan/app/` | sin `Location` apuntando a `auth.lan` |
| Métricas Prometheus accesibles desde Caddy | `docker exec prometheus wget -qO- http://navidrome:4533/metrics \| head` | salida con `navidrome_*` series (Fase 5 las consume) |
| Sin warnings críticos en logs | `docker logs navidrome 2>&1 \| grep -iE 'error\|fail' \| head` | salida razonable (no errores recurrentes de permisos o BBDD) |

---

## Referencias

- Documentación oficial Navidrome — https://www.navidrome.org/docs/
- Configuration options — https://www.navidrome.org/docs/usage/configuration-options/
- Reverse proxy con Caddy/Nginx — https://www.navidrome.org/docs/installation/reverse-proxies/
- Subsonic API reference — http://www.subsonic.org/pages/api.jsp
- OpenSubsonic (extensiones modernas) — https://opensubsonic.netlify.app/
- Imagen Docker oficial — https://hub.docker.com/r/deluan/navidrome
- Repo del proyecto — https://github.com/navidrome/navidrome
- Clientes Subsonic compatibles — https://www.navidrome.org/docs/overview/#apps
- DSub (Android) — https://f-droid.org/packages/github.daneren2005.dsub/
- Symfonium (Android) — https://symfonium.app/
- Amperfy (iOS) — https://github.com/BLeeEZ/amperfy
- Feishin (escritorio) — https://github.com/jeffvli/feishin
- ListenBrainz — https://listenbrainz.org/
- Last.fm API — https://www.last.fm/api
- Documentos hermanos: `01-jellyfin.md`, `03-audiobookshelf.md`, `04-calibre-web.md`, `05-stash.md`.
- Documentos referenciados: `01-sistema/04-estructura-directorios.md`, `02-docker/02-estructura-compose.md`, `03-red/02-pihole.md`, `03-red/04-caddy.md`, `03-red/05-tailscale.md`, `04-seguridad/01-authelia.md`, `07-backups/01-estrategia-backup.md`, `07-backups/02-borgmatic.md`.
