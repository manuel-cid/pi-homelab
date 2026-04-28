# Audiobookshelf

## Descripción

Despliegue de **Audiobookshelf** ([imagen oficial `ghcr.io/advplyr/audiobookshelf`](https://github.com/advplyr/audiobookshelf/pkgs/container/audiobookshelf)) como **servidor de audiolibros y podcasts** del homelab. Audiobookshelf indexa dos bibliotecas en `/mnt/hd2t/media/`:

1. **`audiobooks/`** — alimentada por el operador vía rsync/Syncthing (mismo patrón que la música de Navidrome). Audiobookshelf solo lee (`:ro` en el bind mount).
2. **`podcasts/`** — Audiobookshelf **es el productor**: descarga episodios desde feeds RSS y los guarda como `.mp3`/`.m4a` en disco. Bind mount **rw**.

Sirve la biblioteca por dos vías:

1. **Web UI propia** (PWA basada en SvelteKit, server-side rendering en Node.js) servida en `:80` dentro del contenedor, con reproducción HTML5 directa y soporte HLS para iOS Safari (transcoding `ffmpeg` integrado en la imagen).
2. **API REST y WebSocket propias** que consumen las apps oficiales de **Audiobookshelf** (iOS, Android), los clientes de terceros como **Plappa**, **Voiceful**, **Audiobook Player by Henry Soares**, y la PWA del navegador (instalable). **No es API Subsonic** — Navidrome y ABS son servidores distintos para usos distintos; un cliente Subsonic no se conecta a ABS y viceversa.

Este doc cubre, en orden:

1. **Por qué Audiobookshelf** y no Booksonic, Lazy Librarian, Plex audiobooks, AudioBookBay scripts o tracker manual de progreso, qué se asume y qué se descarta.
2. **Plan de variables y archivos**: `.env.example` versionable, `.env` real con valores en `/mnt/hd2t/services/audiobookshelf/.env`, layout de directorios bajo `/mnt/hd2t/services/audiobookshelf/`.
3. **Estructura de las bibliotecas**: `audiobooks/` (read-only) y `podcasts/` (read-write). Audiolibros con tags ID3v2 / chapters embebidos como fuente de verdad — Audiobookshelf **no escribe** en los ficheros de audiolibros (sí en los de podcasts, porque los descarga). Podcasts con metadatos del feed RSS.
4. **`docker-compose.yml`** con bind mount de `audiobooks/` en read-only y `podcasts/` en read-write, separación entre `config/` (BD SQLite, respaldable), `metadata/` (covers + items + auto-backups internos, respaldable) y `cache/` (transcodes HLS + caché de imágenes redimensionadas, **excluido** del backup según [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6).
5. **Despliegue, onboarding inicial** (creación del admin en el primer acceso a `/login`).
6. **Integración con Caddy** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3): bloque `audiobookshelf.{$LAN_DOMAIN}` (no existe placeholder en `Caddyfile`; se añade en §6.1), DNS local en Pi-hole, websockets para sincronización de progreso entre dispositivos en tiempo real.
7. **Auth nativa de Audiobookshelf** (multi-usuario, hasheo bcrypt, JWT en cookies + Bearer en API) y por qué Authelia delante **rompe** las apps móviles oficiales (envían `Authorization: Bearer <jwt>` directamente, no cookie SSO). Variante opt-in con OIDC en §12.4 — Audiobookshelf v2.7+ soporta OIDC nativamente, lo que **sí** funciona con apps porque el flujo OAuth corre en webview.
8. **Transcoding bajo demanda**: ABS usa `ffmpeg` para HLS cuando el cliente no soporta el codec original (común con iOS Safari y `.m4b` con AAC; Chrome reproduce direct). El coste en Pi 5 es bajo (~10 % de un core para audio HLS).
9. **Backup**: `config/` (~50 MB) + `metadata/` sin `metadata/cache/` (~50–500 MB con biblioteca grande, dominado por las portadas); `cache/` se regenera tras la primera reproducción de cada track y la primera vista de cada portada en cada cliente.
10. **Operaciones cotidianas**: upgrade vía Watchtower (Audiobookshelf es **opt-in** según [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2), forzar re-escaneo de bibliotecas, programación de descargas de podcasts, gestión de usuarios.
11. **Variantes opt-in**: Tailscale para acceso remoto, OIDC con Authelia, sincronización Audible (importar libros desde Audible — opt-in), backup automático interno de la BD.

> **Alcance de red**: Audiobookshelf **solo se accede vía Caddy** sobre `https://audiobookshelf.lan` (LAN) o `https://audiobookshelf.${TS_DOMAIN}` (Tailscale). El puerto 80 del contenedor **no se publica al host** (regla del homelab para todos los servicios web, [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §0). Las apps oficiales de ABS conectan con la URL completa: `https://audiobookshelf.lan` en LAN, `https://audiobookshelf.tailnet.ts.net` en remoto.

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), grupo `media` (GID 1100) con `homelab` como miembro, `/mnt/hd2t/` montado, `/mnt/hd2t/media/audiobooks/` y `/mnt/hd2t/media/podcasts/` creados con `homelab:media 2775` ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §3, §6).
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` creada, convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5 — bind mounts; §4.3 — red compartida; §5.2 — `PGID=1100` para multimedia).
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) con `lan_internal_tls` operativo y la red `homelab` accesible. Sin Caddy no hay HTTPS y las apps de ABS rechazan conexiones HTTP en redes no privadas (chequeo de App Transport Security en iOS).
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con la posibilidad de añadir registros A locales (`audiobookshelf.lan` → IP de la Pi).
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Audiobookshelf lleva la etiqueta `com.centurylinklabs.watchtower.enable: "true"` por política — los upgrades son **automáticos** porque ABS migra el schema de SQLite vía `sequelize-cli` de forma idempotente y publica releases con changelog estable.
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) para que `/mnt/hd2t/services/audiobookshelf/{config,metadata}/` sean archivados y `/mnt/hd2t/services/audiobookshelf/cache/` quede **excluido** según las reglas de §13.6 de ese doc.
- **Bibliotecas presentes** en `/mnt/hd2t/media/audiobooks/` y `/mnt/hd2t/media/podcasts/`: ABS se puede levantar con bibliotecas vacías y **no** dará error — escaneará 0 ítems y esperará. Los audiolibros se llenan por rsync/Syncthing tras el deploy. Estructura recomendada para audiolibros:
    - `Autor/Saga (Año)/Título/cover.jpg + audio.m4b` (un único `.m4b` por libro con chapters embebidos), **o**
    - `Autor/Título/01 - Capítulo.mp3, 02 - ...` (multi-fichero con chapters por track).
  ABS soporta ambas. **No** confía en la jerarquía de carpetas: extrae metadatos de tags ID3v2 / Vorbis Comments / m4b chapters; cualquier estructura sirve si los tags están bien.
- **Disco hd2t libre**: ≥ 2 GB para `/mnt/hd2t/services/audiobookshelf/` (BD ~50 MB con 500 libros; metadata + covers ~300 MB con 500 libros; cache ~1 GB en pico tras varias semanas de transcoding HLS bajo demanda). El espacio para los **propios contenidos** (audiolibros + podcasts descargados) se planifica aparte ([`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md) §6).

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Servidor de audiolibros + podcasts | **Audiobookshelf** (FOSS, [GPL-3.0](https://github.com/advplyr/audiobookshelf/blob/master/LICENSE)) | Booksonic-Air (fork de Subsonic) está sin actualizaciones desde 2023 y depende de un Subsonic con auth-debilitada. Plex Audiobooks requiere Plex Pass + cuenta plex.tv. LazyLibrarian es gestor de descargas, no servidor. AudioBookshelf es nativo Node.js, una BD SQLite, mantiene progreso por usuario y por dispositivo, soporta multi-usuario, multi-biblioteca, podcasts con descarga RSS y apps oficiales activas en iOS/Android. |
| Imagen | **`ghcr.io/advplyr/audiobookshelf`** (oficial) | Mantenida por el autor del proyecto en GHCR. La alternativa `lscr.io/linuxserver/audiobookshelf` añade s6-overlay y va una versión por detrás casi siempre — no aporta nada porque la imagen oficial ya respeta `PUID`/`PGID` nativamente. |
| Tag de imagen | **`2.17.4`** (no `latest`, no `2.17`) | ABS sigue SemVer estricto. Pinear el patch obliga a confirmar el upgrade leyendo https://github.com/advplyr/audiobookshelf/releases, especialmente cuando hay migrations en la BD (las hay regularmente — la migración JSON→SQLite en v2.3 fue grande, y siguen llegando). Watchtower respeta tags exactos vía `image: ghcr.io/advplyr/audiobookshelf:${ABS_IMAGE_TAG}` — al cambiar el `.env` y reiniciar, se actualiza; sin cambio, no. |
| Arquitectura | `linux/arm64` (Pi 5) | Manifest multi-arch oficial. La imagen pesa ~280 MB (Node.js + ffmpeg + dependencias npm). |
| Red Docker | **`homelab`** (bridge, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.3). **Sin** `ports:` al host. | Caddy llega a Audiobookshelf por nombre (`http://audiobookshelf:80`) sobre la red compartida. No publicar `80` al host elimina el riesgo de que la UI sea accesible **sin** TLS. |
| Modelo de almacenamiento | **Bind mount** `/mnt/hd2t/services/audiobookshelf/{config,metadata,cache}:/{config,metadata,metadata/cache}` + **Bind mounts** de bibliotecas | Patrón estándar del homelab. La separación `config` (DB SQLite, único fichero crítico) / `metadata` (items + covers + backups internos, importante) / `cache` (HLS transcoding + image rescale, regenerable) permite una política de backup quirúrgica: `config + metadata` sí, `cache` no. ABS guarda el cache **dentro de** `/metadata/cache/` por defecto; lo separamos con un bind mount sobre `/metadata/cache` para excluirlo limpiamente sin tocar el código de ABS. |
| Biblioteca de audiolibros como **read-only** dentro del contenedor | `/mnt/hd2t/media/audiobooks:/audiobooks:ro` | ABS **no escribe** en la biblioteca de audiolibros: extrae metadatos (`ffprobe`) y los guarda en `/config/absdatabase.sqlite` y en `/metadata/items/`. La etiqueta "in progress" / "starred" / progreso por usuario viven en la BD propia, no en los ficheros. Esto es **deliberado**: protege los ficheros de origen y permite que `rsync` o Syncthing los manipulen sin pisarse con ABS. Si el operador quiere persistir metadatos editados desde la UI en los tags ID3 (compat con foobar2000, MusicBee), ver §12.5. |
| Biblioteca de podcasts como **read-write** | `/mnt/hd2t/media/podcasts:/podcasts` | ABS **es el productor** de los podcasts: descarga episodios del feed RSS configurado y los guarda en disco. Sin RW, "Add Podcast" falla con `EACCES`. |
| BD de Audiobookshelf | **SQLite** en `/config/absdatabase.sqlite` | ABS no soporta otros backends. Para ≤ 5000 libros y ≤ 200 podcasts no hay problema; benchmarks del proyecto muestran que el coste dominante es el escaneo de audio (`ffprobe`), no la BD. |
| Usuario dentro del contenedor | **`PUID=1000` (homelab) + `PGID=1100` (media)** vía variables de entorno (la imagen oficial las respeta) | Coherente con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.2. ABS puede leer la biblioteca de audiolibros porque pertenece al grupo `media` (GID 1100). Escritura en `/config`, `/metadata`, `/podcasts` necesita escritura en disco — `/config` y `/metadata` son `homelab:homelab`, `/podcasts` es `homelab:media` con `setgid` (`2775`) heredado de `/mnt/hd2t/media/`. |
| Transcoding | **Activado por defecto** (HLS para clientes que lo necesitan) | ABS usa `ffmpeg` (incluido en la imagen). Transcodear `.m4b` AAC → HLS AAC consume ~10 % de un core en Pi 5. Permite a las apps móviles (oficial iOS, oficial Android) y a iOS Safari reproducir formatos que el navegador no soporta nativamente. Sin coste relevante. |
| Backup | **`/config/` + `/metadata/` (sin `cache/`)** vía Borgmatic | El resto se regenera (transcodes HLS, image rescaling). Política en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6 (`/mnt/hd2t/services/audiobookshelf/cache` excluido). Restore: instalar ABS virgen, restaurar `/config + /metadata`, **rescanear** bibliotecas (ABS re-popula índices y deja la BD intacta porque el itemId es estable). |
| Watchtower | **`com.centurylinklabs.watchtower.enable: "true"`** | Por política ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2). ABS migra schema con `sequelize` de forma idempotente y publica releases con changelog. Distinto de Jellyfin (manual) y de Authelia (manual): para ABS el riesgo es bajo y la frecuencia de releases alta. |
| Reverse proxy | **Caddy sin `forward_auth`** | ABS tiene auth nativa (`/login` + JWT). Las apps móviles oficiales (iOS, Android) se autentican con `POST /login` → reciben JWT → usan `Authorization: Bearer <jwt>` en cada request. Aplicar Authelia con `forward_auth` rompería las apps móviles (no envían cookie de sesión). El paywall SSO **no aporta** nada sobre la auth nativa ya multiusuario. Variante con OIDC nativo de ABS en §12.4 — **sí** compatible con apps porque ABS gestiona el flujo OAuth en su propio webview. |
| Acceso remoto | **Vía Tailscale** ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) — `audiobookshelf.${TS_DOMAIN}` con `tls /data/tailscale-certs/audiobookshelf.crt /data/tailscale-certs/audiobookshelf.key` | Sin port forwarding ni DDNS. Las apps oficiales aceptan **una** URL — el operador la cambia manualmente entre LAN y remoto (Settings > Server). Tailscale + MagicDNS hace que `audiobookshelf.tailnet.ts.net` resuelva igual desde cualquier sitio. |
| Onboarding del primer usuario | **Por la UI web** | El primer acceso a `/login` muestra el formulario "Initial setup": crea el primer admin. **No** hay CLI para crear el primer admin; está hardcodeado en `server/managers/UserManager.js` del proyecto. |
| Descarga de podcasts | **Activada, intervalo 4 h por feed** | ABS busca nuevos episodios de cada podcast con la frecuencia que el operador configure (Settings > Podcasts > "Check for new episodes"). 4 h es un buen balance: detecta episodios nuevos en pocas horas sin saturar al servidor RSS. |
| Limpieza automática de podcasts | **Manual** | ABS **no** borra episodios automáticamente. El operador decide retención (mantener todos vs los últimos N). En §10.3 se explican las opciones. |

---

## 1. Resumen de la arquitectura

```
                 ┌────────────────── LAN ──────────────────┐
                 │                                         │
   App ABS       │  iOS │ Android │ Web PWA │ Plappa       │
        │        │   │  │    │    │    │    │    │         │
        └────────┴───┴──┴────┴────┴────┴────┴────┴─────────┘
                                                    │
                                                    ▼
                                       https://audiobookshelf.lan
                                                    │
                                                    ▼ (TLS de Caddy)
                                         ┌────────────────────┐
                                         │       Caddy        │  (../03-red/04-caddy.md)
                                         │ audiobookshelf.lan │
                                         │       :443         │
                                         └─────────┬──────────┘
                                                   │ reverse_proxy (red homelab)
                                                   │ http://audiobookshelf:80
                                                   ▼
                                       ┌──────────────────────────┐
                                       │     Audiobookshelf       │
                                       │   (este doc, :80)        │
                                       │                          │
                                       │  /config         (RW)    │ ─► /mnt/hd2t/services/audiobookshelf/config/
                                       │  /metadata       (RW)    │ ─► /mnt/hd2t/services/audiobookshelf/metadata/
                                       │  /metadata/cache (RW)    │ ─► /mnt/hd2t/services/audiobookshelf/cache/
                                       │  /audiobooks     (RO)    │ ─► /mnt/hd2t/media/audiobooks/
                                       │  /podcasts       (RW)    │ ─► /mnt/hd2t/media/podcasts/
                                       └─────────┬────────────────┘
                                                 │
                          ┌──────────────────────┼──────────────────────┐
                          ▼ inotify watcher       ▼ HTTP GET RSS         ▼ HLS via ffmpeg
                ┌──────────────────────┐ ┌──────────────────────┐ ┌──────────────────────┐
                │ /mnt/hd2t/media/     │ │  Internet (vía       │ │ /metadata/cache/     │
                │ audiobooks/          │ │  Pi-hole DNS):       │ │ streams/<sessionId>/ │
                │  alimentado por      │ │   feed RSS de        │ │  segments.ts +       │
                │  Operador (rsync,    │ │   cada podcast       │ │  playlist.m3u8       │
                │  Syncthing)          │ │   suscrito           │ │                      │
                └──────────────────────┘ └──────────┬───────────┘ └──────────────────────┘
                                                    │
                                                    ▼ (descarga de episodios)
                                         ┌──────────────────────┐
                                         │ /mnt/hd2t/media/     │
                                         │ podcasts/<podcast>/  │
                                         │   ep1.mp3, ep2.mp3   │
                                         └──────────────────────┘
```

Lo crítico de este diagrama:

1. **Una única vía de entrada para clientes**: navegador, app oficial → Caddy → Audiobookshelf. El puerto 80 no existe para clientes externos al stack.
2. **Audiolibros en read-only**: ABS **lee** `/mnt/hd2t/media/audiobooks/`, no escribe ahí. El operador es el dueño de ese árbol vía rsync/Syncthing — coincide con la fila `audiobooks/` de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6.
3. **Podcasts en read-write**: ABS descarga RSS al disco. La fila `podcasts/` de §6 indica explícitamente que ABS es el productor.
4. **Sin discovery**: en bridge no hay multicast. Las apps **siempre** se configuran con URL.
5. **Cache local separado**: `/mnt/hd2t/services/audiobookshelf/cache/` contiene transcodes HLS (`ffmpeg`) e image rescaling. Excluido del backup.
6. **Sin GPU passthrough**: las transcodificaciones HLS son CPU-only (audio). El contenedor **no** monta `/dev/dri`.

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/audiobookshelf/.env.example`:

```env
# ~/homelab/stacks/audiobookshelf/.env.example
# Versión control: ~/homelab/stacks/audiobookshelf/.env.example
# Valores reales en /mnt/hd2t/services/audiobookshelf/.env (chmod 600).
# Este fichero NO contiene secretos; las credenciales de los usuarios
# Audiobookshelf viven dentro de /config/absdatabase.sqlite (hash bcrypt)
# y se respaldan vía Borgmatic.

# --- Comunes del homelab ---
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
MEDIA_GID=1100
TZ=Europe/Madrid

# --- Dominios internos (consistentes con dns/.env y proxy/.env) ---
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Audiobookshelf ---
# https://github.com/advplyr/audiobookshelf/pkgs/container/audiobookshelf
# Lista de cambios: https://github.com/advplyr/audiobookshelf/releases
ABS_IMAGE_TAG=2.17.4

# Hostnames públicos (sin esquema). Usados en Caddyfile.
ABS_LAN_HOST=audiobookshelf.lan
ABS_TS_HOST=audiobookshelf.tailnet.ts.net

# Token JWT firmado por ABS para sesiones. Si está vacío, ABS genera
# uno aleatorio en el primer arranque y lo guarda en la BD; vale para
# cualquier despliegue normal. Solo fijarlo si se quiere control
# determinista (p. ej. invalidar todas las sesiones rotándolo).
TOKEN_SECRET=

# Loglevel: 0=trace, 1=debug, 2=info, 3=warn, 4=error.
# 2 (info) es suficiente; 1 (debug) llena el log rápido con cada request.
LOGLEVEL=2
```

### 2.2. `.env` real (`/mnt/hd2t/services/audiobookshelf/.env`)

```bash
# Crear el .env con permisos correctos.
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/audiobookshelf
sudo install -o homelab -g homelab -m 600 /dev/null \
  /mnt/hd2t/services/audiobookshelf/.env

# Volcar contenido (editar valores reales).
sudo -u homelab tee /mnt/hd2t/services/audiobookshelf/.env > /dev/null <<'EOF'
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
MEDIA_GID=1100
TZ=Europe/Madrid
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net
ABS_IMAGE_TAG=2.17.4
ABS_LAN_HOST=audiobookshelf.lan
ABS_TS_HOST=audiobookshelf.tailnet.ts.net
TOKEN_SECRET=
LOGLEVEL=2
EOF

# Verificar.
ls -l /mnt/hd2t/services/audiobookshelf/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` (§4) declara `env_file: /mnt/hd2t/services/audiobookshelf/.env`. Compose carga el fichero **a la hora de interpolar `${...}` en el YAML** (para tags, hostnames, `PUID`, `PGID`…) y **además** lo expone al proceso del contenedor. Audiobookshelf lee variables de entorno como `PUID`, `PGID`, `TZ`, `PORT`, `TOKEN_SECRET` directamente ([referencia oficial](https://www.audiobookshelf.org/docs/install/docker)) — equivale a `docker run -e PUID=1000 ...`. El homelab prefiere `env_file` por dos razones:

1. **Trazabilidad**: una sola fuente de verdad (`.env`) en lugar de varios `-e` esparcidos en el Compose.
2. **Backup compacto**: `config/absdatabase.sqlite` ya respalda usuarios, progreso, bibliotecas y suscripciones a podcasts; el `.env` es texto plano que se versiona en git **sin** valores reales (solo `.env.example`). No se duplica config en el backup.

> **Por qué `TOKEN_SECRET` puede ir vacío**: ABS lo genera la primera vez que arranca y lo guarda en la BD (campo `Settings.tokenSecret`). Solo hay que fijarlo si el operador quiere rotar todos los JWT en circulación a la vez (cambia el valor → todos los logueados deben re-loguear). Para uso normal, dejar vacío.

> **Por qué no hay secretos de usuarios en `.env`**: ABS no lee credenciales de variables de entorno. El password del admin se establece desde la UI en el primer acceso a `/login` (formulario "Initial setup") y vive cifrado (bcrypt cost 8, default de la librería `bcryptjs`) en `/config/absdatabase.sqlite` (tabla `users`, columna `pash`). Las API keys de servicios externos (Audible, librivox, etc.) son **opcionales** y se configuran vía la UI por usuario.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
sudo install -d -o homelab -g homelab -m 750 ~/homelab/stacks/audiobookshelf
```

### 3.2. Crear el árbol de datos persistentes

```bash
# Datos vivos del contenedor.
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/audiobookshelf

# Subdirectorios respaldables (config, metadata) y regenerables (cache).
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/audiobookshelf/config \
  /mnt/hd2t/services/audiobookshelf/metadata \
  /mnt/hd2t/services/audiobookshelf/cache
```

### 3.3. Verificar que las bibliotecas están listas

Las carpetas `/mnt/hd2t/media/audiobooks/` y `/mnt/hd2t/media/podcasts/` deben existir con permisos `homelab:media 2775` desde [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6:

```bash
ls -ld /mnt/hd2t/media /mnt/hd2t/media/audiobooks /mnt/hd2t/media/podcasts
# Esperado:
# drwxrwsr-x ... homelab media ... /mnt/hd2t/media
# drwxrwsr-x ... homelab media ... /mnt/hd2t/media/audiobooks
# drwxrwsr-x ... homelab media ... /mnt/hd2t/media/podcasts

# El usuario homelab pertenece al grupo media.
id homelab | tr ',' '\n' | grep media
# Esperado: ...,1100(media),...
```

Si alguna de las carpetas **no existe**, ejecutar el bootstrap del doc de estructura de directorios antes de seguir:

```bash
sudo install -d -o homelab -g media -m 2775 /mnt/hd2t/media
sudo install -d -o homelab -g media -m 2775 /mnt/hd2t/media/audiobooks
sudo install -d -o homelab -g media -m 2775 /mnt/hd2t/media/podcasts
```

### 3.4. Tabla resumen de permisos

| Ruta | Modo | Owner | Quién escribe | Por qué |
|---|---|---|---|---|
| `/mnt/hd2t/services/audiobookshelf/` | `750 homelab:homelab` | homelab (Compose) | Solo el operador desde el host | Patrón canónico. Solo `homelab` ve el contenido. |
| `/mnt/hd2t/services/audiobookshelf/config/` | `750 homelab:homelab` (preexiste, lo rellena ABS) | Proceso ABS (PUID 1000) | Materializa `absdatabase.sqlite`, `Logs/`, `tokens/`. **Respaldable** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6). |
| `/mnt/hd2t/services/audiobookshelf/metadata/` | `750 homelab:homelab` | Proceso ABS (PUID 1000) | Contiene `items/<itemId>/` (per-item metadata cache, descripciones, chapters resueltos), `authors/`, `covers/<itemId>/cover.jpg`, `backups/` (auto-backups internos diarios), `tools/` (binarios auxiliares de ffprobe-helpers). **Respaldable**. |
| `/mnt/hd2t/services/audiobookshelf/cache/` | `750 homelab:homelab` | Proceso ABS (PUID 1000) | Transcodes HLS (`streams/<sessionId>/segments.ts + playlist.m3u8`), image cache (`images/` con thumbnails redimensionados). **Excluido** del backup. Mapeado a `/metadata/cache` dentro del contenedor (§4). |
| `/mnt/hd2t/media/audiobooks/` | `2775 homelab:media` | Operador (rsync, Syncthing) | ABS solo **lee** (`:ro` en el bind). |
| `/mnt/hd2t/media/podcasts/` | `2775 homelab:media` | Proceso ABS (PUID 1000) descargando RSS | ABS escribe episodios `.mp3`/`.m4a`. El operador puede borrar manualmente si quiere recortar histórico. |

### 3.5. Permisos para el proceso del contenedor

La imagen `ghcr.io/advplyr/audiobookshelf` corre por defecto como `node` dentro del contenedor (UID 1000 internamente). El homelab pasa `PUID=1000` y `PGID=1100` por entorno (la imagen los respeta vía un entrypoint que hace `chown -R` y baja a ese UID/GID). Resultado:

- Garantiza que los ficheros bajo `/config`, `/metadata`, `/podcasts` aparezcan como `homelab:media` en el host (los descargados como `homelab:media`, los administrativos como `homelab:homelab` por el `setgid`).
- Permite leer la biblioteca de audiolibros montada como `:ro` porque el GID 1100 está en el ACL implícito del directorio padre.
- Mantiene la coherencia con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.2 ("Servicios multimedia añaden `PGID=1100`").

> **Atención**: si Audiobookshelf se levantó alguna vez sin `PUID/PGID` (ejecuciones de prueba), `config/absdatabase.sqlite` puede haber quedado como `root:root`. Corrección: `sudo chown -R 1000:1000 /mnt/hd2t/services/audiobookshelf/{config,metadata,cache}` antes del primer `up` formal.

---

## 4. `docker-compose.yml`

`~/homelab/stacks/audiobookshelf/docker-compose.yml`:

```yaml
# ~/homelab/stacks/audiobookshelf/docker-compose.yml
# Stack: audiobookshelf (servidor de audiolibros y podcasts, Fase 9).
# Datos en /mnt/hd2t/services/audiobookshelf/.
# Bibliotecas en /mnt/hd2t/media/audiobooks/ (RO) y /mnt/hd2t/media/podcasts/ (RW).

name: audiobookshelf

services:
  audiobookshelf:
    image: ghcr.io/advplyr/audiobookshelf:${ABS_IMAGE_TAG}
    container_name: audiobookshelf
    hostname: audiobookshelf
    restart: unless-stopped
    env_file: /mnt/hd2t/services/audiobookshelf/.env

    environment:
      # PUID 1000 (homelab), PGID 1100 (media). La imagen oficial respeta
      # estas variables y baja el proceso a ese UID/GID en el entrypoint.
      PUID: ${HOMELAB_UID}
      PGID: ${MEDIA_GID}
      TZ: ${TZ}
      # Puerto interno del listener (default 80; lo dejamos explícito).
      PORT: 80
      # Loglevel y secret JWT (§2.1).
      LOGLEVEL: ${LOGLEVEL}
      TOKEN_SECRET: ${TOKEN_SECRET}
      # Origen confiable para CORS (Caddy). Sin esto, la app PWA puede
      # ver errores de CORS al servir desde un host distinto del Origin
      # esperado por defecto.
      SOURCE: "docker"

    volumes:
      # BD + config. Respaldable.
      - /mnt/hd2t/services/audiobookshelf/config:/config
      # Metadata (covers, items, auto-backups internos). Respaldable.
      - /mnt/hd2t/services/audiobookshelf/metadata:/metadata
      # Cache de transcodes HLS y image rescaling. NO respaldable.
      # Se monta sobre /metadata/cache para "secuestrar" el subdir que
      # ABS escribiría dentro de /metadata.
      - /mnt/hd2t/services/audiobookshelf/cache:/metadata/cache
      # Biblioteca de audiolibros: read-only desde ABS. El operador es el dueño.
      - /mnt/hd2t/media/audiobooks:/audiobooks:ro
      # Biblioteca de podcasts: read-write. ABS descarga episodios RSS aquí.
      - /mnt/hd2t/media/podcasts:/podcasts
      # TZ y reloj sincronizados con el host.
      - /etc/localtime:/etc/localtime:ro

    # Sin `ports:` — Audiobookshelf solo es accesible vía Caddy por la red `homelab`.
    networks:
      - homelab

    # Recursos: ABS con escaneo en curso de una biblioteca de 500 libros
    # puede tocar 600 MB de RAM (Node.js + ffprobe en paralelo + cache
    # de items en memoria). Limitar evita OOM en el host.
    mem_limit: 1500m
    mem_reservation: 256m

    # Healthcheck: GET / devuelve 200 si el listener HTTP está vivo.
    # ABS arranca en ~10s (init de la BD SQLite y migrations).
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost/healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

    # security_opt: igual que el resto del homelab (../02-docker/02-estructura-compose.md §0).
    security_opt:
      - no-new-privileges:true

    labels:
      # Watchtower: actualizar automáticamente — ABS migra schema con
      # sequelize de forma idempotente y publica releases con changelog.
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
| `name: audiobookshelf` | Nombre del proyecto Compose. Aunque [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §1.1 agrupa Audiobookshelf bajo el stack `media`, en la práctica cada servicio multimedia tiene su propio stack folder (igual que Jellyfin, Navidrome) — un `down` afecta solo a ABS. |
| `image: ghcr.io/advplyr/audiobookshelf:${ABS_IMAGE_TAG}` | Tag pinned vía `.env`. La imagen oficial vive en GitHub Container Registry. |
| `container_name: audiobookshelf` / `hostname: audiobookshelf` | Nombre estable para que Caddy llegue por DNS (`reverse_proxy http://audiobookshelf:80`). Sin esto, Compose le pone un nombre tipo `audiobookshelf-audiobookshelf-1` y rompe el DNS interno. |
| `env_file: /mnt/hd2t/services/audiobookshelf/.env` | Carga de variables — patrón estándar del homelab. |
| `environment.PUID` / `PGID` | UID 1000 (escribe en `/config`, `/metadata`, `/podcasts`), GID 1100 (lee en `/audiobooks`, escribe en `/podcasts` con `setgid` heredado). |
| `environment.TZ` | ABS loguea timestamps en zona local. |
| `environment.PORT: 80` | Listener interno. La imagen ya escucha en `:80` por defecto, pero lo hacemos explícito por consistencia con futuros cambios de default. |
| `environment.LOGLEVEL: 2` | `info` por defecto. Para debugging puntual, subir a `1` (debug) editando `.env` y reiniciando. |
| `environment.TOKEN_SECRET` (vacío) | ABS genera el secret en el primer arranque y lo persiste en la BD. Solo se fuerza si se quiere control determinista (rotar JWTs). |
| `environment.SOURCE: "docker"` | ABS lo usa internamente para decidir paths default y mostrar el badge de instalación en `Settings > About`. Cosmético + diagnóstico. |
| `volumes: /mnt/hd2t/services/audiobookshelf/config:/config` | Bind mount canónico de la BD. Sin `:Z`/`:z` (no SELinux en Pi OS). |
| `volumes: /mnt/hd2t/services/audiobookshelf/metadata:/metadata` | Bind mount del árbol de metadata (covers, items, auto-backups internos). |
| `volumes: /mnt/hd2t/services/audiobookshelf/cache:/metadata/cache` | **Truco clave**: ABS escribe transcodes HLS en `/metadata/cache/streams/` y image cache en `/metadata/cache/images/`. Al montar un bind sobre `/metadata/cache` "secuestramos" el subdirectorio para excluirlo del backup sin tocar el código de ABS. La política de [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6 lista `/mnt/hd2t/services/audiobookshelf/cache` como exclusión. |
| `volumes: /mnt/hd2t/media/audiobooks:/audiobooks:ro` | **Read-only** desde ABS. El operador es el dueño. |
| `volumes: /mnt/hd2t/media/podcasts:/podcasts` | **Read-write** porque ABS descarga episodios RSS. Sin `:ro` la operación "Add Podcast" funciona; con `:ro` falla con `EACCES`. |
| `volumes: /etc/localtime:ro` | Sincroniza la zona del host con el contenedor — backup ante un usuario que olvide poner `TZ` en `.env`. |
| `networks: [homelab]` | Solo la red compartida. Caddy ya está ahí. |
| `mem_limit: 1500m` | ABS con escaneo en paralelo de una biblioteca grande puede consumir 600–800 MB (Node.js + ffprobe + cache de items + streaming HLS). 1.5 GB de tope deja margen sin pegarse con el resto. |
| `mem_reservation: 256m` | Garantía mínima en presión de memoria. ABS arranca con ~150 MB. |
| `healthcheck` con `/healthcheck` | Endpoint canónico de Audiobookshelf desde v2.4 ([`server/Server.js`](https://github.com/advplyr/audiobookshelf/blob/master/server/Server.js)). Devuelve `200 OK` plano si el listener HTTP está vivo y la BD está abierta. `start_period: 30s` cubre la inicialización del schema SQLite y migrations. |
| `security_opt: no-new-privileges:true` | Patrón base ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §0). |
| `com.centurylinklabs.watchtower.enable: "true"` | Watchtower opt-in en el homelab ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2). ABS está en la lista de servicios "stateless o de lectura ligera" que se actualizan auto. |
| `dev.dozzle.group: "media"` | Cuando Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)) levante, agrupa Jellyfin, Navidrome, Audiobookshelf y Calibre-Web bajo el mismo grupo "media". |
| `networks.homelab.external: true` | Patrón de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.4: la red se crea **una vez** durante el bootstrap. |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/audiobookshelf
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env config

# Esperado: salida YAML resuelta sin warnings.
# - El `image` debe estar plenamente cualificado: ghcr.io/advplyr/audiobookshelf:2.17.4
# - PUID=1000, PGID=1100 (no comillas vacías ni `null`).
# - Sin warning "variable X not set".
# - `volumes` con paths absolutos.
# - El bind de /audiobooks con `read_only: true`.
# - El bind de /podcasts SIN `read_only: true`.
# - El bind /metadata/cache montado por encima de /metadata (orden correcto).
```

---

## 5. Despliegue

### 5.1. Levantar el stack

```bash
cd ~/homelab/stacks/audiobookshelf
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env up -d
```

El primer `up` tarda **~30 segundos**:

1. Descarga la imagen (~280 MB en arm64 — más pesada que Navidrome).
2. El entrypoint `chown -R` ajusta UID/GID en `/config`, `/metadata`, `/metadata/cache` (puede tardar 5–10 s adicionales si hay datos preexistentes).
3. Inicializa el schema SQLite en `/config/absdatabase.sqlite` (migrations vía `sequelize`).
4. Levanta el HTTP listener en `:80`.

### 5.2. Estado de los contenedores

```bash
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env ps

# Esperado, tras ~30 segundos:
# NAME              IMAGE                                       STATUS                 PORTS
# audiobookshelf    ghcr.io/advplyr/audiobookshelf:2.17.4       Up X (healthy)
```

Si tras 2 minutos el estado sigue siendo `(starting)`:

```bash
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env logs --tail=200 audiobookshelf

# Buscar líneas tipo:
# - "[Server] Initializing": arranque normal.
# - "[Server] Listening on port 80": HTTP listo.
# - "[Database] Database initialized": BD lista.
# - "EACCES: permission denied, open '/config/absdatabase.sqlite'": revisar PUID/PGID y permisos del bind mount.
# - "ENOENT: no such file or directory, scandir '/audiobooks'": revisar que /mnt/hd2t/media/audiobooks existe.
```

### 5.3. Onboarding inicial (creación del admin)

Audiobookshelf expone su UI en `http://audiobookshelf:80` (red `homelab`). Caddy aún no lo enruta hasta §6. Para el primer onboarding, dos opciones:

**Opción A — Vía Caddy (preferida)**: completar §6 antes de lanzar el formulario. Abrir `https://audiobookshelf.lan` desde un navegador del LAN.

**Opción B — `docker exec` para validar**:

```bash
# Verificar que ABS responde dentro del contenedor.
docker exec audiobookshelf wget -qO- http://localhost/healthcheck
# Esperado: vacío + exit 0 (el endpoint devuelve 200 sin body).

# Confirmar la versión.
docker exec audiobookshelf wget -qO- http://localhost/status | head -c 200
# Esperado: JSON con {"app":"audiobookshelf","serverVersion":"2.17.4","isInit":false,...}
# isInit:false significa "todavía no se ha creado el admin".
```

> En la práctica el flujo recomendado es **Opción A**: completar §6, abrir `https://audiobookshelf.lan`, completar el formulario.

El primer acceso a `/login` muestra **una sola pantalla**:

1. **Crear cuenta de admin (Initial setup)**: nombre + password. Esta cuenta tiene **todos** los privilegios (gestión de usuarios, gestión de bibliotecas, configuración del servidor, logs); el password se guarda hasheado (bcrypt cost 8) en `/config/absdatabase.sqlite` (tabla `users`, columna `pash`). **Anotar el password**: hay procedimiento de reset (§10.5) pero requiere acceso al filesystem.

Tras "Submit", ABS lleva al dashboard vacío. Las bibliotecas se añaden en §7.1.

---

## 6. Integración con Caddy

### 6.1. Añadir el bloque `audiobookshelf.{$LAN_DOMAIN}` al `Caddyfile`

A diferencia de Jellyfin/Pi-hole, el `Caddyfile` del homelab ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3) **no incluye placeholder** para Audiobookshelf. Editar `~/homelab/stacks/proxy/Caddyfile` y añadir:

```caddy
# Audiobookshelf (../09-multimedia/03-audiobookshelf.md) — audiolibros y podcasts
audiobookshelf.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Subida de portadas y backups manuales (admin > Tools > Backup).
    # Un backup interno típico ronda 50–200 MB; 500 MB cubre el caso
    # de bibliotecas grandes con muchas portadas.
    request_body {
        max_size 500MB
    }

    # Streaming de audio + WebSocket de progreso. flush_interval -1
    # evita buffering en Caddy (un .m4b de 200 MB sin flush latencia
    # el primer byte ~5s y rompe el seek de las apps).
    reverse_proxy http://audiobookshelf:80 {
        header_up Host {host}
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
        flush_interval -1
    }
}
```

> **WebSocket**: ABS usa Socket.IO sobre WebSocket para sincronizar progreso entre dispositivos en vivo (paras un capítulo en el móvil → la web del salón actualiza el slider en < 1 s). Caddy reenvía el upgrade `Connection: upgrade / Upgrade: websocket` automáticamente con `reverse_proxy` — no hay que añadir directivas extra.

Y el bloque Tailscale gemelo (comentado hasta tener cert vía `tailscale cert`):

```caddy
# audiobookshelf.{$TS_DOMAIN} {
#     import tailscale_tls audiobookshelf
#     import security_headers
#     request_body {
#         max_size 500MB
#     }
#     reverse_proxy http://audiobookshelf:80 {
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

### 6.2. Trusted proxies en Audiobookshelf

ABS confía en `X-Forwarded-For` **automáticamente** si la conexión TCP viene de una IP privada (RFC1918). Por tanto, no hay que tocar nada extra cuando Caddy y Audiobookshelf comparten la red `homelab` (172.20.0.0/24).

Verificación tras un login en `https://audiobookshelf.lan` desde `192.168.1.50`:

```bash
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env logs --tail=100 audiobookshelf | grep -i login
# Esperado:
# ... [Auth] User logged in: admin (192.168.1.50)
# (NO 172.20.0.X)
```

### 6.3. Registro DNS local en Pi-hole

Pi-hole resuelve `audiobookshelf.lan` → IP de la Pi. Esto ya estaba descrito conceptualmente en [`../03-red/02-pihole.md`](../03-red/02-pihole.md) §7.

```bash
# Vía la UI de Pi-hole (preferido):
# 1. Abrir https://pihole.lan/admin/
# 2. "Local DNS > DNS Records"
# 3. Domain: audiobookshelf.lan
#    IP:     192.168.1.10  (la IP estática de la Pi en LAN)
# 4. "Add"
```

Verificar:

```bash
dig +short @192.168.1.2 audiobookshelf.lan
# Esperado: 192.168.1.10
```

### 6.4. Probar el acceso

```bash
# Desde el host (red homelab interna):
docker exec caddy wget -qO- -S http://audiobookshelf:80/healthcheck 2>&1 | head -10
# Esperado: HTTP 200 (sin body).

# Desde la LAN (validar TLS):
curl -fsS https://audiobookshelf.lan/healthcheck -o /dev/null -w "%{http_code}\n"
# Esperado: 200
# El cert es de la CA interna de Caddy ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §3.4);
# el navegador puede protestar. Solución: instalar el root cert de Caddy.

# Desde el navegador:
# https://audiobookshelf.lan → formulario "Initial setup" (§5.3).
```

### 6.5. (No por defecto) Proteger con Authelia

**El homelab no pone Authelia delante de Audiobookshelf por defecto** — explicado en §0 fila "Reverse proxy" y desarrollado en §12.4. La razón en una línea: las apps oficiales de iOS/Android envían `Authorization: Bearer <jwt>` directamente, sin cookie SSO; un `forward_auth` con Authelia las rechazaría con 401 antes de que el header llegara al backend.

La vía correcta para SSO **manteniendo apps móviles** es **OIDC nativo de ABS** (v2.7+, sin `forward_auth` en Caddy) — ABS gestiona el flujo OAuth en su propio webview/redirect, las apps lo soportan, ver §12.4.

---

## 7. Configuración post-despliegue

### 7.1. Crear las bibliotecas

Tras el primer login, ABS muestra un asistente para crear la primera biblioteca; saltarlo y usar **Settings > Libraries** (icono de carpeta arriba a la izquierda) para tener control completo.

**Biblioteca 1 — Audiolibros**:

| Campo | Valor |
|---|---|
| Name | `Audiolibros` |
| Icon | `book-1` (o el preferido) |
| Media Type | `Books` |
| Folders | `/audiobooks` (autocompleta — ABS lista los binds) |
| Provider for new items | `Audnexus.aud` (gratis, sin API key) o `Audible` con cuenta opcional |
| Disable Watcher | **No** (por defecto) — usa inotify para detectar ficheros nuevos sin esperar al scan periódico |
| Skip matching books | **No** — siempre intentar matchear con metadatos online |

**Biblioteca 2 — Podcasts**:

| Campo | Valor |
|---|---|
| Name | `Podcasts` |
| Icon | `microphone-1` |
| Media Type | `Podcasts` |
| Folders | `/podcasts` |
| Provider for new items | (no aplica — los podcasts se añaden por URL del feed RSS) |

> ABS arranca un escaneo automático tras crear cada biblioteca. Para una biblioteca de 200 audiolibros tarda ~5 minutos en Pi 5 (extracción de chapters por libro vía `ffprobe`); 1000 libros ~25 minutos.

### 7.2. Crear los usuarios secundarios (familia)

**Settings > Users > +**:

| Usuario | Tipo | Notas |
|---|---|---|
| `admin` (creado en §5.3) | Admin | Acceso completo. |
| `family` | User | Puede crear "playlists" (collections), marcar progreso, suscribirse a podcasts. **No** ve "Settings > Server". |
| `kids` (opcional) | User | Bibliotecas restringidas: solo "Audiolibros" filtrado por collection "Infantil". Sin permiso para añadir podcasts. |

**Permisos por usuario** (ABS soporta granularidad por biblioteca y por collection):

- **Settings > Users > `<user>` > Permissions**:
    - `Can download`: opcional, default `Yes`. Permite descargar los ficheros originales (útil para la app oficial cuando se va a estar sin red).
    - `Can update`: por defecto `Yes` para admins, `No` para users. Si está en `No`, el user no puede editar metadatos.
    - `Allow uploads`: por defecto `No`. Activarlo permite subir audiolibros por la web (no recomendado — el rsync es más eficiente).
    - `Library access`: marcar las bibliotecas accesibles. Para `kids`, solo "Audiolibros".

### 7.3. Configurar el escaneo periódico

ABS escanea cada biblioteca según dos vías que **se complementan**:

1. **Watcher inotify**: detecta cambios en tiempo real (ficheros nuevos, renombrados, borrados). **Activado por defecto** salvo que se marque "Disable Watcher" en la biblioteca.
2. **Scan programado**: cron interno configurable en **Settings > Server > Schedule library scans**. Default: nunca (porque el watcher cubre el 99 % de los casos). Útil si la biblioteca vive en un mount de red flaky donde inotify no funciona.

| Opción | Default | Cambiar a | Por qué |
|---|---|---|---|
| Library watcher | **Activado** | Mantener activado | Detecta cambios en `/audiobooks` y `/podcasts` al instante. |
| Schedule library scans | (vacío) | (opcional) `0 4 * * *` (4 AM diario) | Plan B si inotify falla puntualmente (p. ej. tras un `umount`/`mount` del disco). Coste despreciable. |
| Schedule podcast episode checks | **`0 */4 * * *` (cada 4 h)** | Mantener | Frecuencia razonable para detectar episodios nuevos sin saturar el servidor RSS. |

### 7.4. Configurar el primer podcast

Tras tener al menos una biblioteca de podcasts:

1. **Library `Podcasts` > Add Podcast** (icono `+` flotante).
2. Pegar la URL del feed RSS (ej. `https://feeds.megaphone.fm/lateralcast`).
3. ABS hace un GET al feed, parsea el XML y muestra:
    - Título del podcast.
    - Imagen del podcast (descargada al `/metadata/items/<podcastId>/cover.jpg`).
    - Lista de episodios con fecha y duración.
4. **Auto-download new episodes**: opcional. Si se activa, ABS descarga automáticamente los nuevos episodios al detectar updates en el feed (cada 4 h por default, §7.3). Si no, el operador descarga manualmente desde la UI.
5. **Max old episodes to download**: opcional, default `0` (no descargar episodios viejos automáticamente). Útil para evitar saturar el disco con un podcast con 500 episodios viejos.

Tras "Submit", ABS añade el podcast a la biblioteca y queda visible en `/library/<libraryId>/podcast`.

### 7.5. Transcoding y reproducción

ABS decide automáticamente entre **direct play** y **transcode HLS** según el cliente:

| Cliente | Codec original | Comportamiento |
|---|---|---|
| Chrome / Firefox / Edge | `.mp3`, `.m4a`/AAC, `.ogg`/Vorbis, `.opus` | Direct play |
| Safari macOS / iOS | `.mp3`, `.m4a`/AAC | Direct play |
| Safari iOS | `.flac`, `.opus`, `.ogg` | **Transcode HLS** a AAC (Safari iOS no soporta) |
| App oficial iOS / Android | Cualquiera | Direct play (las apps llevan codec nativo) |
| Plappa / Voiceful | Cualquiera | Direct play |

**Verificar transcoding activo**:

```bash
docker exec audiobookshelf sh -c 'pgrep -a ffmpeg && echo "transcoding en curso" || echo "sin transcode"'
# Si hay transcode activo: pid + path del fichero.
# Si no: "sin transcode".
```

### 7.6. Backups internos automáticos

ABS tiene un sistema de backup interno **independiente** de Borgmatic: Settings > Server > Backups.

| Opción | Default | Recomendado | Por qué |
|---|---|---|---|
| Daily backup | **Activado** | Mantener | ABS hace un dump de `/config/absdatabase.sqlite` + `/metadata/items/` + `/metadata/authors/` y lo guarda en `/metadata/backups/` (`audiobookshelf-backup-2025-04-27.zip`). |
| Number of backups | 2 | **7** | Una semana de histórico ABS-interno; los archivos más viejos los rota Borgmatic. |
| Backup time | `0 1 * * *` | Mantener (1 AM) | Antes del backup Borgmatic externo (`0 3 * * *` por defecto en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) — así Borg recoge un backup ABS-interno fresco. |

> **Por qué dos sistemas de backup superpuestos**: el backup interno de ABS es **rápido de restaurar** desde la propia UI ("Settings > Backups > Restore"). Borgmatic es la red de seguridad externa con histórico de meses y deduplicación. Ambos cubren `/config + /metadata` pero el flujo de restore es muy diferente.

---

## 8. Verificación

### 8.1. Contenedor sano

```bash
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env ps
# Esperado: Up X (healthy)

docker inspect audiobookshelf --format '{{.State.Health.Status}}'
# Esperado: healthy
```

### 8.2. Direct play funciona

Reproducir un MP3 desde el navegador y verificar que **NO** está corriendo `ffmpeg`:

```bash
docker exec audiobookshelf sh -c 'pgrep ffmpeg && echo "transcode" || echo "direct play OK"'
# Esperado en Chrome con .mp3: "direct play OK"
```

### 8.3. Audiobookshelf escucha solo dentro de la red `homelab`

```bash
# Desde el host: el puerto 80 del contenedor NO debe responder.
ss -tlnp | grep ":80 "
# Esperado: vacío (Caddy escucha en :443, no en :80; el :80 de ABS es interno).

# Desde dentro de la red homelab sí debe responder.
docker exec caddy wget -qO- http://audiobookshelf:80/healthcheck -O - -S 2>&1 | head -5
# Esperado: HTTP/1.1 200 OK
```

### 8.4. Bibliotecas montadas y leídas

```bash
docker exec audiobookshelf ls -la /audiobooks | head
# Esperado: ficheros/carpetas visibles si los hay; permisos como en host.

docker exec audiobookshelf ls -la /podcasts | head
# Esperado: ficheros/carpetas visibles si hay podcasts ya descargados.

# Test escritura en /audiobooks (debería FALLAR — `:ro`):
docker exec audiobookshelf sh -c 'touch /audiobooks/test_write 2>&1'
# Esperado: "Read-only file system"

# Test escritura en /podcasts (debería FUNCIONAR):
docker exec audiobookshelf sh -c 'touch /podcasts/.test_write && rm /podcasts/.test_write && echo OK'
# Esperado: OK
```

### 8.5. API REST operativa

Tras crear el admin (`admin` / `<password>`):

```bash
# Login y obtener JWT.
TOKEN=$(curl -fsS -X POST https://audiobookshelf.lan/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"<password>"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["user"]["token"])')

# Listar bibliotecas con el JWT.
curl -fsS https://audiobookshelf.lan/api/libraries \
  -H "Authorization: Bearer $TOKEN" | head -c 500
# Esperado: JSON con la lista de bibliotecas creadas en §7.1.

# Estado del scan en una biblioteca.
LIB_ID=$(curl -fsS https://audiobookshelf.lan/api/libraries \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["libraries"][0]["id"])')
curl -fsS "https://audiobookshelf.lan/api/libraries/$LIB_ID" \
  -H "Authorization: Bearer $TOKEN" | head -c 500
```

### 8.6. WebSocket de progreso

Reproducir un audiolibro en una pestaña, abrir otra pestaña con el mismo libro: el progreso debe sincronizarse en tiempo real (< 2 s de latencia).

```bash
# Verificar que Caddy ha hecho upgrade a websocket:
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env logs --tail=50 audiobookshelf | grep -i socket
# Esperado:
# ... [Socket.io] Socket connected: <id> (admin)
```

### 8.7. Smoke test desde el navegador

1. `https://audiobookshelf.lan` carga la UI.
2. Login con `admin` exitoso.
3. La biblioteca "Audiolibros" muestra al menos un libro (si hay biblioteca) o "No items found" sin error.
4. Reproducir un track arbitrario: empieza < 3 s.
5. Pausar a la mitad, cerrar pestaña, abrir de nuevo: persiste el progreso.
6. Si hay podcasts: el feed se ha parseado y los episodios listados aparecen con duración correcta.

### 8.8. Persistencia tras reboot

```bash
sudo reboot
# Esperar ~2 min.
ssh homelab@pi.lan
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env -f ~/homelab/stacks/audiobookshelf/docker-compose.yml ps
# Esperado: audiobookshelf Up X (healthy) — restart: unless-stopped lo trae solo.
```

### 8.9. Lista de verificación

- [ ] `docker compose ... ps` muestra `Up X (healthy)`.
- [ ] `docker inspect audiobookshelf --format '{{.State.Health.Status}}'` = `healthy`.
- [ ] `ss -tlnp | grep ":80 "` no devuelve nada del contenedor (no hay puerto publicado).
- [ ] `curl -fsS https://audiobookshelf.lan/healthcheck` devuelve HTTP 200.
- [ ] `docker exec audiobookshelf touch /audiobooks/test_write` falla con `Read-only file system`.
- [ ] `docker exec audiobookshelf sh -c 'touch /podcasts/.test_write && rm /podcasts/.test_write'` funciona.
- [ ] Login en `https://audiobookshelf.lan` con cuenta admin OK.
- [ ] API REST responde a `POST /login` devolviendo un JWT y `GET /api/libraries` con `Authorization: Bearer <jwt>` lista bibliotecas.
- [ ] Reproducción de un MP3 sin `ffmpeg` activo (direct play en Chrome).
- [ ] Reproducción de un FLAC en Safari iOS dispara `ffmpeg` (transcode HLS).
- [ ] `docker compose logs audiobookshelf | grep "User logged in"` muestra la IP real del cliente (no `172.20.0.X`).
- [ ] Tras `sudo reboot`, ABS vuelve a estar `(healthy)` en menos de 2 minutos.
- [ ] Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6) lista `/mnt/hd2t/services/audiobookshelf/{config,metadata}/` en el archivo y **no** lista `cache/`.

---

## 9. Backup

### 9.1. Qué se respalda y qué no

| Ruta | Backup | Justificación |
|---|---|---|
| `/mnt/hd2t/services/audiobookshelf/config/` | **Sí** (Borgmatic, [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6) | Contiene `absdatabase.sqlite` (usuarios, progreso por usuario y libro, collections, suscripciones a podcasts, configuración del servidor, JWT secret), `Logs/`. ~50–100 MB. |
| `/mnt/hd2t/services/audiobookshelf/metadata/` | **Sí** | Contiene `items/<itemId>/` (chapters resueltos, descripciones, links externos), `authors/` (biografías + fotos), `covers/<itemId>/` (portadas descargadas — regenerables pero costosas en tiempo) y `backups/` (auto-backups internos, §7.6). ~50–500 MB con biblioteca grande. |
| `/mnt/hd2t/services/audiobookshelf/cache/` | **No** | Transcodes HLS (`streams/<sessionId>/segments.ts`), image rescaling (`images/`). Regenerable en cuestión de segundos por sesión. Puede crecer a 1 GB+. |
| `/mnt/hd2t/media/audiobooks/` | **Política aparte** ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §6) | El **contenido** de audiolibros es **irreplazable** (rips propios de CDs, descargas de Audible vía AAXtoMP3, etc.) — debe entrar en backup, pero como repo separado o volumen del repo principal según el espacio. |
| `/mnt/hd2t/media/podcasts/` | **Política aparte** | Los episodios descargados se pueden volver a descargar del feed RSS si el podcast sigue activo, **pero** muchos podcasts borran episodios viejos al cabo de meses. El operador decide si los considera replazables. Por defecto **no** entran en Borg (ahorra espacio); con `BORGMATIC_INCLUDE_PODCASTS=true` sí ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §X). |

### 9.2. Política Borgmatic

`~/homelab/stacks/backup/config/borgmatic.d/audiobookshelf.yaml` (extendiendo el doc principal):

```yaml
# Cubierto en ../07-backups/02-borgmatic.md §13.6 — solo aquí como referencia.
source_directories:
  - /mnt/hd2t/services/audiobookshelf/config
  - /mnt/hd2t/services/audiobookshelf/metadata

# Hook para hacer un dump consistente de SQLite (evita races con WAL).
before_backup:
  - sqlite3 /mnt/hd2t/services/audiobookshelf/config/absdatabase.sqlite "VACUUM INTO '/mnt/hd2t/services/audiobookshelf/config/absdatabase.bak'"
```

> **Por qué `VACUUM INTO`**: ABS escribe en WAL mode; un copiado directo del `.sqlite` sin checkpoint puede dar una BD inconsistente. `VACUUM INTO` es el método canónico de SQLite para hacer un snapshot consistente. El snapshot queda en `config/absdatabase.bak` que entra en el archivo Borg natural.

### 9.3. Restore (resumen)

```bash
# 0. Asumiendo Pi recién instalada y borg/borgmatic operativo.
# 1. Recrear el árbol de directorios (§3.2).
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/audiobookshelf \
  /mnt/hd2t/services/audiobookshelf/config \
  /mnt/hd2t/services/audiobookshelf/metadata \
  /mnt/hd2t/services/audiobookshelf/cache

# 2. Listar archivos disponibles.
sudo borgmatic list

# 3. Extraer SOLO los datos de Audiobookshelf del último archivo.
sudo borgmatic extract \
  --archive latest \
  --path mnt/hd2t/services/audiobookshelf/config \
  --destination /
sudo borgmatic extract \
  --archive latest \
  --path mnt/hd2t/services/audiobookshelf/metadata \
  --destination /

# 4. Verificar permisos.
sudo chown -R 1000:1000 /mnt/hd2t/services/audiobookshelf/{config,metadata}

# 5. Levantar Audiobookshelf.
cd ~/homelab/stacks/audiobookshelf
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env up -d

# 6. Forzar re-scan de bibliotecas (regenera índices que dependen de
# /audiobooks y /podcasts; los items y covers ya se restauraron).
# Vía UI: Settings > Libraries > <library> > "Force Re-Scan".
# Vía API:
TOKEN=$(curl -fsS -X POST https://audiobookshelf.lan/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"<password>"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["user"]["token"])')
LIB_ID=$(curl -fsS https://audiobookshelf.lan/api/libraries \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["libraries"][0]["id"])')
curl -fsS -X POST "https://audiobookshelf.lan/api/libraries/$LIB_ID/scan?force=1" \
  -H "Authorization: Bearer $TOKEN"

# 7. Validar:
# - Usuarios existentes en Settings > Users.
# - Bibliotecas y collections en Library > Filter.
# - Progreso de cada usuario por libro.
# - Suscripciones a podcasts con sus URLs intactas.
```

### 9.4. Smoke test mensual de restore

[`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §10 fija un drill mensual de restore. Para Audiobookshelf:

```bash
# En un directorio temporal (NO sobre la instalación viva):
mkdir -p /tmp/abs-restore-test
cd /tmp/abs-restore-test

sudo borgmatic extract \
  --archive latest \
  --path mnt/hd2t/services/audiobookshelf/config/absdatabase.sqlite \
  --destination .

# Verificar que la BD es válida y tiene usuarios.
sudo apt-get install -y sqlite3  # si no está
sqlite3 ./mnt/hd2t/services/audiobookshelf/config/absdatabase.sqlite \
  'SELECT username, type FROM users;'
# Esperado: lista con admin, family, kids (los creados en §7.2).

sqlite3 ./mnt/hd2t/services/audiobookshelf/config/absdatabase.sqlite \
  'SELECT COUNT(*) FROM libraryItems;'
# Esperado: número entero (cantidad de libros + podcasts indexados).

rm -rf /tmp/abs-restore-test
```

---

## 10. Operaciones cotidianas

### 10.1. Upgrade automático (Watchtower)

Audiobookshelf lleva `com.centurylinklabs.watchtower.enable: "true"` (§4). Watchtower comprueba a diario; cuando hay un nuevo digest del tag pinned, hace `pull` + `up -d`. **Pero**: como el tag está pinned a `2.17.4`, Watchtower no actualiza versiones nuevas a no ser que el operador edite `.env`.

**Upgrade manual de versión** (cambio de tag, p. ej. 2.17.4 → 2.18.0):

```bash
# 1. Leer las release notes: https://github.com/advplyr/audiobookshelf/releases.
#    Buscar "Breaking changes" y "Database migrations".

# 2. Editar /mnt/hd2t/services/audiobookshelf/.env:
sed -i 's/^ABS_IMAGE_TAG=.*/ABS_IMAGE_TAG=2.18.0/' \
  /mnt/hd2t/services/audiobookshelf/.env

# 3. Backup ad-hoc del config + metadata ANTES.
sudo borgmatic create --verbosity 1

# 4. Pull + recrear.
cd ~/homelab/stacks/audiobookshelf
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env pull audiobookshelf
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env up -d

# 5. Vigilar el primer arranque tras upgrade (la BD migra schema).
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env logs -f audiobookshelf

# Esperado:
# - "Audiobookshelf v2.18.0"
# - "[Database] Running migration: <name>" si toca migrar schema.
# - "[Server] Listening on port 80"

# 6. Smoke test: login + reproducir un libro + descargar un episodio nuevo de podcast.

# 7. Si algo se rompe: rollback.
sed -i 's/^ABS_IMAGE_TAG=.*/ABS_IMAGE_TAG=2.17.4/' \
  /mnt/hd2t/services/audiobookshelf/.env
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env up -d
# Si la BD ya migró a un schema más nuevo, restaurar config/ desde Borg.
```

### 10.2. Forzar re-escaneo de las bibliotecas

Tras un movimiento manual (rsync de un disco externo) o un cambio masivo de tags:

```bash
# Vía UI: Settings > Libraries > <library> > "Force Re-Scan".
# Vía API: ver §9.3 paso 6.
```

### 10.3. Limpieza de podcasts viejos

ABS **no** rota episodios automáticamente. Opciones:

```bash
# Vía UI: abrir el podcast, marcar episodios viejos, "Delete from disk".

# Vía API (borrar episodios > N días):
# Listar episodios:
TOKEN=$(...)
curl -fsS "https://audiobookshelf.lan/api/podcasts/<podcastId>/episodes" \
  -H "Authorization: Bearer $TOKEN"
# Cada episodio tiene `id` y `publishedAt` (epoch ms).
# Para borrar:
curl -fsS -X DELETE "https://audiobookshelf.lan/api/podcasts/<podcastId>/episode/<episodeId>?hard=1" \
  -H "Authorization: Bearer $TOKEN"
# `?hard=1` borra del disco; sin él, solo de la BD.

# Vía script con find sobre el filesystem (si el operador prefiere):
find /mnt/hd2t/media/podcasts -name '*.mp3' -mtime +180 -print
# Inspeccionar y borrar manualmente. Tras borrar, en la UI:
# Settings > Libraries > Podcasts > "Force Re-Scan" para que ABS limpie referencias huérfanas.
```

### 10.4. Limpieza de cache

```bash
# Con ABS corriendo es seguro — ABS regenera lo necesario:
sudo find /mnt/hd2t/services/audiobookshelf/cache -mindepth 1 -delete

# O reiniciar el contenedor primero para liberar locks (no estrictamente necesario):
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env stop audiobookshelf
sudo find /mnt/hd2t/services/audiobookshelf/cache -mindepth 1 -delete
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env start audiobookshelf
```

### 10.5. Reset password de admin (perdido el control)

ABS **no** tiene "olvidé contraseña" sin acceso al filesystem. Si se pierde el password del admin:

```bash
# Generar un hash bcrypt nuevo desde el host.
sudo apt-get install -y python3-bcrypt   # si no está
python3 -c 'import bcrypt; print(bcrypt.hashpw(b"NUEVO_PASSWORD", bcrypt.gensalt(8)).decode())'
# Salida: $2b$08$...

# Detener Audiobookshelf.
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env stop audiobookshelf

# Actualizar la BD. Nota: la columna se llama `pash` (sic, no `pass`).
sudo sqlite3 /mnt/hd2t/services/audiobookshelf/config/absdatabase.sqlite \
  "UPDATE users SET pash='<HASH>' WHERE username='admin';"

# Levantar y entrar con el nuevo password.
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env up -d
```

> **Cost factor**: ABS usa bcrypt con cost factor 8 (default de `bcryptjs`, no 10 como Navidrome). Si se genera el hash con cost 10, **igual funciona** — bcrypt comparara correctamente; solo es más lento al loguear (~120 ms vs ~30 ms en Pi 5, irrelevante).

### 10.6. Logs

```bash
# Stream en vivo (vía Dozzle o `docker compose logs`).
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env logs -f audiobookshelf

# Errores recientes:
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env logs --tail=500 audiobookshelf \
  | grep -E "ERROR|WARN" | tail -30

# Logs internos persistentes en /config/Logs/:
docker exec audiobookshelf ls -la /config/Logs
# audiobookshelf-error-2025-04-27.log, audiobookshelf-info-2025-04-27.log
```

Subir el loglevel a `debug` puntualmente:

```bash
sed -i 's/^LOGLEVEL=.*/LOGLEVEL=1/' /mnt/hd2t/services/audiobookshelf/.env
docker compose --env-file /mnt/hd2t/services/audiobookshelf/.env up -d
# (recordar volver a 2 = info tras la sesión de debug)
```

### 10.7. Comportamiento durante mantenimiento

| Situación | Resultado | Mitigación |
|---|---|---|
| `docker compose stop audiobookshelf` (planificado) | Apps muestran "Server unreachable". Streams activos se cortan al instante. | Avisar 1 min antes (escuchar audiolibros no es crítico — diferencia con Jellyfin). |
| Caddy reload | Las requests reciben `502` momentáneo (~1 segundo); las apps reintentan transparentemente. WebSocket de progreso se reconecta solo. | Sin acción. |
| Pi-hole caído | `audiobookshelf.lan` no resuelve dentro del LAN. | Fallback DNS en clientes ([`../03-red/02-pihole.md`](../03-red/02-pihole.md) §10) o IP directa. |
| Disco hd2t saturado | ABS no puede escribir cache ni descargar nuevos episodios; direct play sigue funcionando. | Monitorización ([`../05-monitorizacion/02-grafana.md`](../05-monitorizacion/02-grafana.md), Node Exporter). Limpiar cache (§10.4) o podcasts viejos (§10.3). |

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Cómo diagnosticar | Remedio |
|---|---|---|---|
| `Read-only file system` al ejecutar `touch /audiobooks/test` desde dentro del contenedor | El bind mount es `:ro` (correcto) | — | **Esperado**. ABS no escribe en `/audiobooks`. |
| `EACCES: permission denied` al intentar añadir un podcast | `/podcasts` montado como `:ro` por error | `docker inspect audiobookshelf \| grep -A2 podcasts` | Quitar `:ro` del bind de `/podcasts` en `docker-compose.yml`, recrear. |
| Login OK pero "Server unreachable" en app móvil | URL del servidor mal en la app | App > Settings > Server URL | Cambiar a `https://audiobookshelf.lan` o `https://audiobookshelf.tailnet.ts.net`, no IP. |
| App móvil oficial: "Connection failed: certificate" | El cert de Caddy es de la CA local; la app móvil no la confía | — | Instalar el root cert de Caddy en el dispositivo (Settings > General > VPN & Device Management en iOS; Security > Encryption en Android). **O** usar `audiobookshelf.tailnet.ts.net` (cert Let's Encrypt vía Tailscale, §12.1). |
| Tracks no aparecen tras añadir ficheros | Watcher inotify no llega a propagarse, o `mtime` no cambió (rsync con `--no-times`) | "Settings > Libraries > <library>" muestra `lastScan` antiguo | Forzar scan manual (§10.2) o `docker compose restart audiobookshelf`. |
| Mojibake en títulos (acentos, caracteres asiáticos) | Tags ID3v1 con encoding Latin1 mal etiquetado como UTF-8 | `mediainfo "<fichero>.mp3" \| grep -i unicode` | Re-tagear con `mid3v2` o `mp3tag` a ID3v2.4 + UTF-8 antes de subir. |
| Direct play falla en Safari iOS con `.flac` | Safari iOS no soporta FLAC nativamente | Settings > Listening Sessions > "Stream: Transcode" | Aceptar el transcode HLS (CPU bajo). Si pasa con `.opus`: idem (Safari iOS tampoco lo soporta). |
| `User logged in: admin (172.20.0.X)` (no la IP del cliente) | Caddy no está enviando `X-Forwarded-For` | Verificar el bloque `header_up X-Real-IP {remote_host}` (§6.1) | Añadir `header_up X-Forwarded-For {remote_host}` si falta. Reload Caddy. |
| Podcast no descarga episodios nuevos | Feed RSS rotado a otra URL, o feed devuelve 404 | Settings > Libraries > Podcasts > <podcast>: revisar URL del feed | Actualizar URL en "Podcast Settings" o eliminar y volver a añadir. Para diagnosticar: `docker exec audiobookshelf wget --spider <feedURL>`. |
| Auto-backup interno crece a >5 GB | Bibliotecas grandes con muchas portadas + retención alta | `du -sh /mnt/hd2t/services/audiobookshelf/metadata/backups` | Reducir "Number of backups" en Settings > Server > Backups (§7.6) — Borgmatic ya cubre histórico largo. |
| Authentication failure repetido en log | Brute-force (raro en LAN) o cliente con credenciales obsoletas | `docker compose logs audiobookshelf \| grep -i "failed login"` | Banear IP via Fail2ban del host ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md), jail `audiobookshelf` opt-in). Forzar logout del cliente desde Settings > Users > Sessions. |
| Migración de schema falla tras upgrade | Cambio incompatible entre versiones (raro) | `docker compose logs audiobookshelf \| grep -i migration` | Rollback de tag (§10.1 paso 7) + restaurar `config/` desde Borg. Reportar a https://github.com/advplyr/audiobookshelf/issues. |
| Biblioteca de >2000 libros tarda >30 min en escanear la primera vez | Normal (`ffprobe` por libro + parseo de chapters m4b + lookup metadatos online) | Settings > Libraries > <library> > scan progress | Esperar. Sucesivos scans son rápidos (solo files con `mtime` cambiado). |
| Cover art no se descarga | Provider mal configurado o Pi-hole bloquea Audnexus/Audible | `docker compose logs audiobookshelf \| grep -i cover` | Cambiar provider en Settings > Libraries o whitelist `audnex.us` en Pi-hole. |
| WebSocket de progreso no sincroniza | Caddy no hace upgrade `Connection: upgrade / Upgrade: websocket` | `docker compose logs audiobookshelf \| grep -i socket` | Verificar bloque `reverse_proxy http://audiobookshelf:80` sin override de headers que rompa el upgrade (§6.1). |

---

## 12. Variantes opt-in

### 12.1. Acceso remoto vía Tailscale

Tras desplegar Tailscale en el host ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) y emitir el cert:

```bash
# 1. Generar cert de Tailscale para el host audiobookshelf.
tailscale cert audiobookshelf.tailnet.ts.net

# 2. Mover los .crt y .key al bind mount de Caddy.
sudo mv audiobookshelf.tailnet.ts.net.crt \
  /mnt/hd2t/services/caddy/tailscale-certs/audiobookshelf.crt
sudo mv audiobookshelf.tailnet.ts.net.key \
  /mnt/hd2t/services/caddy/tailscale-certs/audiobookshelf.key

# 3. Descomentar el bloque audiobookshelf.{$TS_DOMAIN} en el Caddyfile (§6.1).

# 4. Recargar Caddy.
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

En las apps oficiales, **el operador puede registrar dos servidores** ("Casa LAN" y "Casa remoto") con sus URLs respectivas y cambiar manualmente. **No** hay auto-switch en la app — la app no sabe si está en LAN o vía Tailscale.

### 12.2. Importar Audible (libros propios)

Audiobookshelf soporta importar libros desde una cuenta de Audible si el operador los tiene en formato `.aax` desencriptados (con `AAXtoMP3` o el plugin `inAudible-NG/audible-cli`). El flujo es:

1. Desencriptar `.aax` → `.m4b` con chapters embebidos.
2. Mover a `/mnt/hd2t/media/audiobooks/<Autor>/<Título>/`.
3. ABS detecta vía watcher inotify y los matchea con Audnexus.

ABS **no** integra directamente con Audible para descarga (limitación legal; Audible cifra los `.aax` con un activation bytes propio). El plugin `audible-cli` lo cubre fuera de banda.

### 12.3. Múltiples bibliotecas de audiolibros (idiomas)

Para separar idiomas o categorías (p. ej. "Audiolibros ES" e "Audiolibros EN"):

1. Crear subcarpetas: `/mnt/hd2t/media/audiobooks/es/`, `/mnt/hd2t/media/audiobooks/en/`.
2. En ABS: Settings > Libraries > "Add Library" → "Audiolibros ES" con folder `/audiobooks/es`.
3. Otra: "Audiolibros EN" con folder `/audiobooks/en`.

Cada biblioteca tiene su propia configuración de provider (Audnexus tiene parámetro `region`, ej. `us`, `uk`, `de` — para "ES" usar `us` o `uk` y aceptar mismatches manuales; no hay región Audnexus española actualmente).

### 12.4. (Opt-in recomendado) SSO con Authelia vía OIDC nativo de ABS

Audiobookshelf v2.7+ soporta OIDC como provider de auth nativo — **sin** `forward_auth` en Caddy. El flujo es:

1. ABS muestra un botón "Sign in with SSO" en `/login` además del formulario de password.
2. Click → ABS redirige al `authorize_endpoint` de Authelia.
3. El usuario se autentica en Authelia (con 2FA si está activado).
4. Authelia redirige de vuelta a ABS con el `code`.
5. ABS hace el token exchange → recibe el JWT de Authelia → crea/asocia el usuario interno → emite su propio JWT y devuelve al cliente.

**Compatibilidad con apps móviles**: las apps oficiales gestionan el redirect en un webview embebido; **funciona**.

Configuración:

```yaml
# Patch al docker-compose.yml.
services:
  audiobookshelf:
    environment:
      # Activar OIDC.
      OPENID_AUTH_ENABLED: "true"
      OPENID_AUTH_CLIENT_ID: audiobookshelf
      OPENID_AUTH_CLIENT_SECRET: ${OIDC_CLIENT_SECRET}
      OPENID_AUTH_ISSUER: https://auth.lan
      OPENID_AUTH_AUTHORIZATION_URL: https://auth.lan/api/oidc/authorization
      OPENID_AUTH_TOKEN_URL: https://auth.lan/api/oidc/token
      OPENID_AUTH_USERINFO_URL: https://auth.lan/api/oidc/userinfo
      OPENID_AUTH_JWKS_URL: https://auth.lan/jwks.json
      OPENID_AUTH_LOGOUT_URL: https://auth.lan/logout
      OPENID_AUTH_BUTTON_TEXT: "Sign in with Authelia"
      # Permite mantener login local + SSO (no es exclusivo).
      OPENID_AUTH_AUTO_LAUNCH: "false"
      OPENID_AUTH_AUTO_REGISTER: "true"
```

Y en `/mnt/hd2t/services/audiobookshelf/.env`:

```env
OIDC_CLIENT_SECRET=<un secret aleatorio largo, p.ej. openssl rand -hex 32>
```

Y en Authelia (`configuration.yml`):

```yaml
identity_providers:
  oidc:
    clients:
      - id: audiobookshelf
        description: Audiobookshelf
        secret: '$pbkdf2-sha512$310000$...'  # hash del secret
        public: false
        authorization_policy: two_factor
        redirect_uris:
          - https://audiobookshelf.lan/auth/openid/callback
          - https://audiobookshelf.tailnet.ts.net/auth/openid/callback
        scopes:
          - openid
          - profile
          - email
        userinfo_signing_algorithm: none
```

> **Por qué SÍ es compatible con apps móviles**: el flujo OIDC corre en un browser/webview que sí entiende cookies y redirects. La app oficial de ABS detecta el redirect a `/auth/openid/callback` y captura el JWT que ABS le devuelve **al final**. A partir de ahí, la app usa `Authorization: Bearer <abs-jwt>` igual que con auth nativa — Authelia ya no se vuelve a consultar hasta que el JWT expire.

### 12.5. Persistir metadatos editados en los tags ID3 (no recomendado)

Por defecto, los metadatos editados desde la UI de ABS viven en `/config/absdatabase.sqlite` y `/metadata/items/`. Si el operador quiere que se escriban en los tags ID3 del fichero original (compat con foobar2000, Smart Audiobook Player):

1. Quitar `:ro` del bind mount de `/audiobooks`:

   ```yaml
   - /mnt/hd2t/media/audiobooks:/audiobooks
   ```

2. **Settings > Libraries > <library> > Settings > "Save metadata to file"**: ACTIVAR (en versiones recientes; el nombre exacto puede variar — verificar release notes).

**Coste**:

- Pierde la barrera "ABS no puede escribir en bibliotecas".
- Cada escritura es una mutación I/O sobre el fichero original (riesgo de corrupción si el proceso muere a media operación).
- Imposible compartir biblioteca con otro servidor sin sincronizar también la BD de ABS.

> **El homelab no recomienda esta variante**. La BD de ABS se respalda diariamente; perder metadatos editados es perder un Borg snapshot, no perder datos definitivamente.

### 12.6. ePub viewer (lectura de libros, no audiolibros)

ABS soporta también ePub y PDF (lectura, no audio). Se sale del alcance principal del homelab — para eso está [`./04-calibre-web.md`](./04-calibre-web.md), especializado en biblioteca de ebooks. Pero si el operador quiere **una sola UI** para audiolibros + ebooks puede mezclar tipos en una biblioteca:

```
Library type: Books
Folders:
  - /audiobooks    (ya configurada)
```

Y poner ePubs en `/mnt/hd2t/media/audiobooks/<Autor>/<Título>/libro.epub`. ABS los reconoce. **Inconveniente**: la biblioteca mezcla ambos tipos y el filtro "Audio only" se vuelve obligatorio para escuchar — añade fricción. La separación en dos servicios (ABS para audio, Calibre-Web para ebooks) es la decisión por defecto del homelab.

---

## Referencias

- **Documentación oficial**: https://www.audiobookshelf.org/docs/
- **Imagen Docker**: https://github.com/advplyr/audiobookshelf/pkgs/container/audiobookshelf
- **Release notes**: https://github.com/advplyr/audiobookshelf/releases
- **Configuration options**: https://www.audiobookshelf.org/docs/install/docker
- **API REST**: https://api.audiobookshelf.org/
- **OIDC integration**: https://www.audiobookshelf.org/guides/oidc_authentication/
- **Repositorio**: https://github.com/advplyr/audiobookshelf
- **Foro de la comunidad**: https://github.com/advplyr/audiobookshelf/discussions
- **Subreddit**: https://www.reddit.com/r/audiobookshelf/
- **App oficial iOS**: https://apps.apple.com/app/audiobookshelf/id1610485830
- **App oficial Android**: https://play.google.com/store/apps/details?id=com.audiobookshelf.app

**Documentos del homelab relacionados**:

- [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) — UID/GID, layout de `/mnt/hd2t/media/audiobooks/` y `/mnt/hd2t/media/podcasts/`.
- [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) — convenciones de `docker-compose.yml`, red `homelab`, `PGID=1100`.
- [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 — Audiobookshelf incluido en upgrades automáticos.
- [`../03-red/02-pihole.md`](../03-red/02-pihole.md) — DNS local `audiobookshelf.lan`.
- [`../03-red/04-caddy.md`](../03-red/04-caddy.md) — reverse proxy, snippets `lan_internal_tls`, `security_headers`, `tailscale_tls`.
- [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) — acceso remoto sin port forwarding.
- [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) — SSO/2FA opcional vía OIDC nativo de ABS (recomendado, §12.4).
- [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) — jail opt-in para Audiobookshelf.
- [`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md) — agrupación de logs por `dev.dozzle.group: "media"`.
- [`../06-almacenamiento/03-syncthing.md`](../06-almacenamiento/03-syncthing.md) — vía recomendada para sincronizar la biblioteca de audiolibros desde otros equipos al directorio `/mnt/hd2t/media/audiobooks/`.
- [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) — política 3-2-1.
- [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6 — exclusión específica de Audiobookshelf (`cache`).
- [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) — patrón general de backup de bind mounts.
- [`./01-jellyfin.md`](./01-jellyfin.md) — el servidor multimedia hermano para vídeo.
- [`./02-navidrome.md`](./02-navidrome.md) — el servidor de música hermano; Navidrome y Audiobookshelf comparten patrón (RO library, BD SQLite, Caddy delante) pero divergen en producción de contenido (Navidrome solo lee; ABS también descarga RSS) y en API (Subsonic vs propia REST).
- [`./04-calibre-web.md`](./04-calibre-web.md) — biblioteca de ebooks, separación deliberada de responsabilidades (ABS = audio; Calibre-Web = texto).
