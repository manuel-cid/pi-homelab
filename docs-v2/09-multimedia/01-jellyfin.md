# Jellyfin

## Descripción

Despliegue de **Jellyfin** ([imagen oficial `jellyfin/jellyfin`](https://hub.docker.com/r/jellyfin/jellyfin)) como **servidor multimedia** para películas y series en el homelab. Jellyfin escanea las bibliotecas materializadas en `/mnt/hd2t/media/{movies,tv}/` (alimentadas manualmente y por Sonarr/Radarr en la Fase 10) y las sirve a navegadores, apps móviles (Android/iOS), Smart TVs (LG webOS, Samsung Tizen, Android TV / Google TV), Roku, Chromecast y clientes de escritorio (Jellyfin Media Player, Jellyfin Vue, Finamp).

Este doc cubre, en orden:

1. **Por qué Jellyfin** y no Plex/Emby/Kodi standalone, qué se asume y qué se descarta.
2. **Plan de variables y archivos**: `.env.example` versionable, `.env` real con secretos en `/mnt/hd2t/services/jellyfin/.env`, layout de directorios bajo `/mnt/hd2t/services/jellyfin/`.
3. **Estructura de bibliotecas**: solo `movies/` y `tv/` (la música la sirve [Navidrome](./02-navidrome.md), los audiolibros [Audiobookshelf](./03-audiobookshelf.md), los libros [Calibre-Web](./04-calibre-web.md)). Jellyfin **no** ve `audiobooks/`, `podcasts/`, `books/`.
4. **`docker-compose.yml`** con bind mounts de bibliotecas en **read-only**, separación entre `config/` (respaldable) y `cache/` + `metadata/library/` + `transcodes/` (regenerables, **excluidos** del backup según [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6).
5. **Despliegue, onboarding inicial** (wizard "Welcome", creación del usuario `Owner` desde la UI).
6. **Integración con Caddy** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3): bloque `jellyfin.{$LAN_DOMAIN}` (placeholder ya existente), registro DNS local en Pi-hole, websockets para apps y Chromecast.
7. **Por qué Authelia delante de Jellyfin no es la opción por defecto**: rompería autenticación de clientes nativos (apps móviles, Roku, TVs) que no entienden cookie SSO. Jellyfin tiene su propio modelo multi-usuario con políticas de acceso granular y 2FA TOTP nativo.
8. **Hardware transcoding en Raspberry Pi 5**: análisis honesto del estado del soporte (V4L2 m2m experimental, no oficialmente soportado por Jellyfin), recomendación de **direct play** como estrategia principal, con perfiles de cliente para minimizar transcodes. Variante opt-in en §12.1.
9. **Backup**: solo `config/` (~50 MB tras el primer mes); `metadata/library/`, `cache/`, `transcodes/` se regeneran tras un escaneo de biblioteca, [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6.
10. **Operaciones cotidianas**: upgrade manual leyendo el changelog (Jellyfin sigue SemVer y pinea `10.10.x`), forzar re-escaneo de biblioteca, limpieza de transcodes, gestión de usuarios.
11. **Variantes opt-in**: V4L2 m2m para HEVC decode, Tailscale para acceso remoto, IPv6 mDNS, plugin de "Skip Intro" / OPENSUBTITLES, `network_mode: host` para DLNA.

> **Alcance de red**: Jellyfin **solo se accede vía Caddy** sobre `https://jellyfin.lan` (LAN) o `https://jellyfin.${TS_DOMAIN}` (Tailscale). Los puertos 8096/8920 del contenedor **no se publican al host** (regla del homelab para todos los servicios web, [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §0). Las apps oficiales de Jellyfin se conectan por la URL completa: en LAN `https://jellyfin.lan`, en remoto vía Tailscale `https://jellyfin.tailnet.ts.net`. **No** se usa el puerto 7359/UDP de auto-discovery (la app pide la URL al añadir el servidor por primera vez; tras eso ya no necesita discovery).

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), grupo `media` (GID 1100) con `homelab` como miembro, `/mnt/hd2t/` montado, estructura de `/mnt/hd2t/media/{movies,tv,music,audiobooks,podcasts,books}/` creada con `homelab:media 2775` ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §3, §6).
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` creada, convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5 — bind mounts; §4.3 — red compartida; §5.2 — `PGID=1100` para multimedia).
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) con `lan_internal_tls` operativo y la red `homelab` accesible. Sin Caddy no hay HTTPS y los clientes Chromecast / Smart TV requieren TLS válido.
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con la posibilidad de añadir registros A locales (`jellyfin.lan` → IP de la Pi).
- **(Opcional) Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Jellyfin lleva la etiqueta `com.centurylinklabs.watchtower.enable: "false"` por política — los upgrades son **siempre manuales** tras leer el changelog (los cambios de schema de la BD son frecuentes en *minor* releases).
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) para que `/mnt/hd2t/services/jellyfin/config/` sea archivado y `/mnt/hd2t/services/jellyfin/{cache,transcodes,metadata/library}/` queden **excluidos** según las reglas de §13.6 de ese doc.
- **(Opcional) Sonarr/Radarr** ([`../10-descargas/03-sonarr.md`](../10-descargas/03-sonarr.md), [`../10-descargas/04-radarr.md`](../10-descargas/04-radarr.md)) para llenar `/mnt/hd2t/media/tv/` y `/mnt/hd2t/media/movies/`. Jellyfin se puede levantar antes — escaneará bibliotecas vacías sin error y las indexará a medida que aparezcan ficheros (notificación inotify, §7.5).
- **Disco hd2t libre**: ≥ 10 GB para `/mnt/hd2t/services/jellyfin/` (config ~50 MB; metadata + thumbnails de una biblioteca de ~500 películas ocupan 1–3 GB; cache + transcodes + chapter images ~5 GB en pico). El espacio para los **propios contenidos** multimedia se planifica aparte ([`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md) §6).
- **Decisión sobre transcoding**: el homelab usa **direct play como estrategia primaria** (§7.4, §8.2). El hardware transcoding por V4L2 m2m en Pi 5 es **opt-in** (§12.1) y **no es compatible con todos los códecs** (solo H.264 decode estable; HEVC decode experimental; **sin** encode acelerado). Si el operador quiere reproducir HEVC 4K a clientes que no lo soportan nativamente (TVs antiguas, Roku Stick), la solución correcta es **pre-transcodificar el contenido a H.264 1080p** (vía `tdarr`, `unmanic` u offline con `ffmpeg`), no apoyarse en transcoding live de la Pi.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Servidor multimedia | **Jellyfin** (FOSS, AGPL-3.0) | Plex requiere cuenta en plex.tv y telemetría no opt-out; Emby es freemium con paywall en transcoding por hardware; Kodi es cliente, no servidor. Jellyfin es el único 100% FOSS con apps oficiales para todas las plataformas relevantes. |
| Imagen | **`jellyfin/jellyfin:10.10.3`** (oficial, pinned) | La imagen oficial publica `arm64` en su manifest multi-arch. La alternativa `lscr.io/linuxserver/jellyfin` añade `s6-overlay` y rebajas de UID/GID, pero también cambia paths internos respecto a la documentación upstream — molesto al hacer troubleshooting con foros oficiales. |
| Tag de imagen | **`10.10.3`** (no `latest`, no `10`, no `stable`) | Jellyfin sigue SemVer relajado: `10.x.y` cambia schema de BD ocasionalmente y descontinúa plugins (`Open Subtitles`, `IMDb`, etc.). Pinear el patch fuerza al operador a leer https://jellyfin.org/docs/general/server/release-notes/ antes de upgrader. |
| Arquitectura | `linux/arm64` (Pi 5) | Manifest multi-arch oficial. **No** se usa `linux/arm/v7` aunque se publique — la Pi 5 es nativa 64-bit. |
| Red Docker | **`homelab`** (bridge, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.3). **Sin** `ports:` al host. | Caddy llega a Jellyfin por nombre (`http://jellyfin:8096`) sobre la red compartida. No publicar `8096` al host elimina el riesgo de que la UI sea accesible **sin** TLS. Coste: **se pierde DLNA y auto-discovery LAN** (la red bridge no propaga multicast 239.255.255.250 al host). Para DLNA, §12.4. Auto-discovery no es necesario: las apps piden URL al añadir servidor. |
| Modelo de almacenamiento | **Bind mount** `/mnt/hd2t/services/jellyfin/config:/config` + **Bind mount** `/mnt/hd2t/services/jellyfin/cache:/cache` + bibliotecas RO | Patrón estándar del homelab. La separación `config` / `cache` permite hacer backup solo de `config/` y excluir el resto en Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6). |
| Bibliotecas como **read-only** dentro del contenedor | `/mnt/hd2t/media/movies:/media/movies:ro` y `/mnt/hd2t/media/tv:/media/tv:ro` | Jellyfin **no escribe** en las bibliotecas de origen: extrae metadatos, los guarda en su BD interna (`/config/data/library.db`) y en `/cache/metadata/`. Si se permite "Save metadata into media folders" o "Allow embedded metadata extraction" con NFO + thumbnails inline en cada película, se debe revertir el `ro` (§12.5). El homelab **no** lo hace por defecto — los metadatos viven en la BD propia, donde son backupable de forma compacta. |
| Bibliotecas servidas | **`movies/` y `tv/` solamente** | Música → Navidrome ([`./02-navidrome.md`](./02-navidrome.md)). Audiolibros/podcasts → Audiobookshelf ([`./03-audiobookshelf.md`](./03-audiobookshelf.md)). Libros → Calibre-Web ([`./04-calibre-web.md`](./04-calibre-web.md)). Cargar todas en Jellyfin lo convertiría en un mediocre superset; cada doc justifica por qué hay un servidor especializado. |
| BD de Jellyfin | **SQLite por defecto**, `/config/data/library.db` | Jellyfin no soporta otros backends. Para una biblioteca ≤ 5000 ítems no hay problema; arriba de 50000 puede haber latencia de "Refresh library" — fuera del alcance del homelab. |
| Usuario dentro del contenedor | **`PUID=1000` (homelab) + `PGID=1100` (media)** vía `user: "${PUID}:${PGID}"` | Coherente con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.2. Jellyfin puede leer las bibliotecas porque pertenece al grupo `media` (GID 1100). Escritura solo necesaria en `/config` y `/cache`, ambos owned por `homelab:homelab` (GID 1000). |
| Hardware transcoding | **Desactivado por defecto**; direct play primero (§7.4) | El soporte oficial de Jellyfin para Raspberry Pi 5 es **inexistente** según https://jellyfin.org/docs/general/administration/hardware-acceleration/ (el "Raspberry Pi 4" listado solo cubre H.264 decode hasta 1080p y no se ha actualizado para Pi 5). El V4L2 m2m del VideoCore VII funciona en `ffmpeg` pero **no** está integrado en `jellyfin-ffmpeg` upstream — usar `--enable-v4l2-m2m` rompe encode HEVC. Estrategia: ofrecer contenido en formato compatible con los clientes (§7.4) y delegar transcodes pesados a herramientas offline. |
| Backup | **Solo `/config`** vía Borgmatic | El resto se regenera. Política en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6. Restore: instalar Jellyfin virgen, restaurar `/config`, **rescanear** bibliotecas (Jellyfin re-popula `metadata/library/` desde la BD). |
| Watchtower | **`com.centurylinklabs.watchtower.enable: "false"`** | Por política ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6, §52): un upgrade automático de Jellyfin puede romper plugins (los plugins se atan al *exact target framework version* del server) y migrar la BD sin posibilidad de rollback. Upgrade siempre manual con backup previo. |
| Reverse proxy | **Caddy sin `forward_auth`** | Jellyfin tiene auth nativa multi-usuario + 2FA TOTP (plugin oficial); aplicar Authelia con `forward_auth` rompería las apps móviles y los Smart TV (no envían cookie de sesión, usan `Authorization: MediaBrowser Token=...`). El paywall SSO **no aporta** nada sobre la auth nativa. Variante con bypass exhaustivo de rutas en §12.3 — desaconsejada para uso normal. |
| `KnownProxies` / trusted proxies | **Subred 172.20.0.0/24** (red `homelab`) en `network.xml` | Sin esto, Jellyfin loguea siempre la IP del contenedor Caddy en `Jellyfin.log`, no la del cliente real. La config se aplica desde la UI en §7.6 o por edición directa de `/config/network.xml`. |
| Acceso remoto | **Vía Tailscale** ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) — `jellyfin.${TS_DOMAIN}` con `tls /data/tailscale-certs/jellyfin.crt /data/tailscale-certs/jellyfin.key` | Sin port forwarding ni DDNS. Las apps de Jellyfin aceptan dos URLs ("Local" y "Remote") y eligen automáticamente; configurar la "Remote" como `https://jellyfin.tailnet.ts.net` cubre el caso. |
| Onboarding del primer usuario | **Por la UI web** | Jellyfin ejecuta el wizard "Welcome" en el primer acceso a `/web/index.html`, donde se crean el admin y se configuran las bibliotecas. **No** hay CLI para crear el primer admin; es inherente al diseño. |

---

## 1. Resumen de la arquitectura

```
                ┌─────────────────────────── LAN ────────────────────────────┐
                │                                                            │
   App Jellyfin │  Smart TV  │  Roku  │  Chromecast  │  Navegador            │
        │       │     │      │   │    │      │       │      │                │
        └───────┴─────┴──────┴───┴────┴──────┴───────┴──────┴────────────────┘
                                                          │
                                                          ▼
                                                  https://jellyfin.lan
                                                          │
                                                          ▼ (TLS de Caddy)
                                                  ┌───────────────┐
                                                  │     Caddy     │  (../03-red/04-caddy.md)
                                                  │ jellyfin.lan  │
                                                  │     :443      │
                                                  └───────┬───────┘
                                                          │ reverse_proxy (red homelab)
                                                          │ http://jellyfin:8096
                                                          ▼
                                                ┌────────────────────┐
                                                │     Jellyfin       │
                                                │ (este doc, :8096)  │
                                                │                    │
                                                │  /config (RW)      │ ─► /mnt/hd2t/services/jellyfin/config/
                                                │  /cache  (RW)      │ ─► /mnt/hd2t/services/jellyfin/cache/
                                                │  /media/movies (RO)│ ─► /mnt/hd2t/media/movies/
                                                │  /media/tv     (RO)│ ─► /mnt/hd2t/media/tv/
                                                └────────┬───────────┘
                                                         │
                                                         ▼ inotify watcher
                                                ┌────────────────────┐
                                                │  /mnt/hd2t/media/  │  alimentado por
                                                │  movies/, tv/      │  Sonarr (../10-descargas/03-sonarr.md)
                                                │                    │  Radarr (../10-descargas/04-radarr.md)
                                                │                    │  Operador (rsync, smb)
                                                └────────────────────┘
```

Lo crítico de este diagrama:

1. **Una única vía de entrada**: navegador, app, Smart TV, Roku, Chromecast → Caddy → Jellyfin. El puerto 8096 no existe para clientes externos al stack.
2. **Bibliotecas en read-only**: Jellyfin **lee** `/mnt/hd2t/media/`, no escribe ahí. Sonarr y Radarr son los **dueños** de ese árbol. Coherente con la fila "Acceso a `[media]` para usuario `homelab`" de [`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md).
3. **Sin DLNA / Bonjour**: en red bridge no se propaga multicast. Las TVs y Chromecasts encuentran a Jellyfin **siempre vía URL**: o por la app oficial (con la URL configurada manualmente) o por la web (`https://jellyfin.lan` desde un navegador del propio TV/Chromecast).
4. **Cache, transcodes y metadata locales** están separados del config. El backup solo cubre `config/`; un `restore` regenera `cache/`, `transcodes/`, `metadata/library/` con un único re-scan ejecutado en §9.3.
5. **Sin GPU passthrough**: el contenedor **no monta** `/dev/dri` ni `/dev/video10..23` por defecto. Variante con HW transcoding en §12.1.

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/jellyfin/.env.example`:

```env
# ~/homelab/stacks/jellyfin/.env.example
# Versión control: ~/homelab/stacks/jellyfin/.env.example
# Valores reales en /mnt/hd2t/services/jellyfin/.env (chmod 600).
# Este fichero NO contiene secretos; las credenciales de Jellyfin
# (admin, API keys, plugins) viven dentro de /config y se respaldan
# vía Borgmatic.

# --- Comunes del homelab ---
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
MEDIA_GID=1100
TZ=Europe/Madrid

# --- Dominios internos (consistentes con dns/.env y proxy/.env) ---
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Jellyfin ---
# https://hub.docker.com/r/jellyfin/jellyfin/tags
# Lista de cambios: https://jellyfin.org/docs/general/server/release-notes/
JELLYFIN_IMAGE_TAG=10.10.3

# Hostname público (sin esquema). Usado en Caddyfile.
JELLYFIN_HOSTNAME=jellyfin
JELLYFIN_LAN_HOST=jellyfin.lan
JELLYFIN_TS_HOST=jellyfin.tailnet.ts.net

# URL pública que Jellyfin usa para construir links absolutos
# (descargas, posters, thumbnails). Con esto, las apps oficiales
# que muestran la URL del servidor en "Settings > Server" la
# muestran tal cual aquí, no la IP del contenedor.
JELLYFIN_PUBLISHED_SERVER_URL=https://jellyfin.lan

# Subred de la red `homelab` (../02-docker/02-estructura-compose.md §4.1).
# Se usa para configurar `KnownProxies` en network.xml (§7.6).
HOMELAB_SUBNET=172.20.0.0/24
```

### 2.2. `.env` real (`/mnt/hd2t/services/jellyfin/.env`)

```bash
# Crear el .env con permisos correctos.
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/jellyfin
sudo install -o homelab -g homelab -m 600 /dev/null \
  /mnt/hd2t/services/jellyfin/.env

# Volcar contenido (editar valores reales).
sudo -u homelab tee /mnt/hd2t/services/jellyfin/.env > /dev/null <<'EOF'
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
MEDIA_GID=1100
TZ=Europe/Madrid
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net
JELLYFIN_IMAGE_TAG=10.10.3
JELLYFIN_HOSTNAME=jellyfin
JELLYFIN_LAN_HOST=jellyfin.lan
JELLYFIN_TS_HOST=jellyfin.tailnet.ts.net
JELLYFIN_PUBLISHED_SERVER_URL=https://jellyfin.lan
HOMELAB_SUBNET=172.20.0.0/24
EOF

# Verificar.
ls -l /mnt/hd2t/services/jellyfin/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` (§4) declara `env_file: /mnt/hd2t/services/jellyfin/.env`. Compose carga el fichero **a la hora de interpolar `${...}` en el YAML** (para tags, hostnames, `user:`, `PGID`…) y **además** lo expone al proceso del contenedor (Jellyfin lee `TZ`, `JELLYFIN_PublishedServerUrl` y `JELLYFIN_PUBLISHED_SERVER_URL` directamente; el resto solo se usa fuera del contenedor — en Caddyfile y en este `docker-compose.yml`).

> **Por qué no hay secretos en `.env`**: Jellyfin no lee credenciales de variables de entorno. El password del admin se establece desde la UI en el wizard `/web/index.html#!/wizardstart.html` y vive cifrado en `/config/data/jellyfin.db` (tabla `Users`). Las API keys (Sonarr/Radarr → Jellyfin para forzar refresh) se generan en "Dashboard > API Keys" y viven en `/config/data/jellyfin.db` (tabla `ApiKeys`). Esos ficheros se respaldan vía Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6).

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
sudo install -d -o homelab -g homelab -m 750 ~/homelab/stacks/jellyfin
```

### 3.2. Crear el árbol de datos persistentes

```bash
# Datos vivos del contenedor.
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/jellyfin

# Subdirectorios respaldables (config) y regenerables (cache, transcodes).
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/jellyfin/config \
  /mnt/hd2t/services/jellyfin/cache \
  /mnt/hd2t/services/jellyfin/transcodes \
  /mnt/hd2t/services/jellyfin/metadata
```

### 3.3. Verificar que las bibliotecas están listas

Las carpetas `/mnt/hd2t/media/movies/` y `/mnt/hd2t/media/tv/` deben existir con permisos `homelab:media 2775` desde [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6:

```bash
ls -ld /mnt/hd2t/media /mnt/hd2t/media/movies /mnt/hd2t/media/tv
# Esperado:
# drwxrwsr-x ... homelab media ... /mnt/hd2t/media
# drwxrwsr-x ... homelab media ... /mnt/hd2t/media/movies
# drwxrwsr-x ... homelab media ... /mnt/hd2t/media/tv

# El usuario homelab pertenece al grupo media.
id homelab | tr ',' '\n' | grep media
# Esperado: ...,1100(media),...
```

Si `/mnt/hd2t/media/{movies,tv}/` **no existe**, ejecutar el bootstrap del doc de estructura de directorios antes de seguir:

```bash
sudo install -d -o homelab -g media -m 2775 /mnt/hd2t/media
for sub in movies tv; do
  sudo install -d -o homelab -g media -m 2775 "/mnt/hd2t/media/${sub}"
done
```

### 3.4. Tabla resumen de permisos

| Ruta | Modo | Owner | Quién escribe | Por qué |
|---|---|---|---|---|
| `/mnt/hd2t/services/jellyfin/` | `750 homelab:homelab` | homelab (Compose) | Solo el operador desde el host | Patrón canónico. Solo `homelab` ve el contenido. |
| `/mnt/hd2t/services/jellyfin/config/` | `750 homelab:homelab` (preexiste, lo rellena Jellyfin) | Proceso Jellyfin (PUID 1000) | Materializa `data/jellyfin.db`, `data/library.db`, `config/system.xml`, `config/network.xml`, `plugins/`, `log/jellyfin*.log`. **Respaldable** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6). |
| `/mnt/hd2t/services/jellyfin/cache/` | `750 homelab:homelab` | Proceso Jellyfin (PUID 1000) | Subtítulos descargados, frame cache, image cache. **Excluido** del backup. |
| `/mnt/hd2t/services/jellyfin/transcodes/` | `750 homelab:homelab` | Proceso Jellyfin (PUID 1000) | Salida temporal de FFmpeg para clientes que no soportan direct play. **Excluido** del backup. Limpieza automática tras desconectar el cliente. |
| `/mnt/hd2t/services/jellyfin/metadata/` | `750 homelab:homelab` | Proceso Jellyfin (PUID 1000) | NFOs, posters, fanart descargados de TheMovieDB y TheTVDB. `metadata/library/` es regenerable (re-scan). **Excluido** del backup según [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6. |
| `/mnt/hd2t/media/movies/` | `2775 homelab:media` | Sonarr/Radarr (en grupo `media`), operador | Jellyfin solo **lee** (`:ro` en el bind). |
| `/mnt/hd2t/media/tv/` | `2775 homelab:media` | Sonarr (en grupo `media`), operador | Jellyfin solo **lee** (`:ro` en el bind). |

### 3.5. Permisos para el proceso del contenedor

Jellyfin Container corre por defecto como `root` dentro del contenedor; al fijar `user: "${HOMELAB_UID}:${MEDIA_GID}"` (1000:1100) en el Compose (§4), el proceso baja a UID 1000, GID 1100. Esto:

- Garantiza que los ficheros bajo `/config` y `/cache` aparezcan como `homelab:media` en el host (no `root:root`).
- Permite leer las bibliotecas montadas como `:ro` porque el GID 1100 está en el ACL implícito del directorio padre.
- Mantiene la coherencia con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.2 ("Servicios multimedia añaden `PGID=1100`").

> **No** se intenta hacer `chown` masivo a `homelab:homelab` después: rompería el primer `up` siguiente, porque Jellyfin reescribiría como `homelab:media` y volvería al estado correcto. Si el operador ve `metadata/library/` con grupo `media` en lugar de `homelab`, **es lo esperado**.

---

## 4. `docker-compose.yml`

`~/homelab/stacks/jellyfin/docker-compose.yml`:

```yaml
# ~/homelab/stacks/jellyfin/docker-compose.yml
# Stack: jellyfin (servidor multimedia, Fase 9).
# Datos en /mnt/hd2t/services/jellyfin/.
# Bibliotecas (read-only) en /mnt/hd2t/media/{movies,tv}/.

name: jellyfin

services:
  jellyfin:
    image: jellyfin/jellyfin:${JELLYFIN_IMAGE_TAG}
    container_name: jellyfin
    hostname: jellyfin
    restart: unless-stopped
    env_file: /mnt/hd2t/services/jellyfin/.env

    # PUID 1000 (homelab), PGID 1100 (media). Necesario para leer
    # /mnt/hd2t/media/{movies,tv} (owned por homelab:media 2775).
    user: "${HOMELAB_UID}:${MEDIA_GID}"

    environment:
      TZ: ${TZ}
      # URL pública usada por Jellyfin para enlaces absolutos
      # (apps móviles, descargas, manifests HLS). Si no se fija,
      # Jellyfin la deduce del primer Host header recibido —
      # frágil con varios hosts (jellyfin.lan vs jellyfin.tailnet.ts.net).
      JELLYFIN_PublishedServerUrl: ${JELLYFIN_PUBLISHED_SERVER_URL}

    volumes:
      # Configuración + BD + plugins. Respaldable.
      - /mnt/hd2t/services/jellyfin/config:/config
      # Cache, transcodes, metadata descargada. NO respaldable.
      - /mnt/hd2t/services/jellyfin/cache:/cache
      - /mnt/hd2t/services/jellyfin/transcodes:/transcodes
      - /mnt/hd2t/services/jellyfin/metadata:/metadata
      # Bibliotecas: read-only desde Jellyfin. Sonarr/Radarr son los dueños.
      - /mnt/hd2t/media/movies:/media/movies:ro
      - /mnt/hd2t/media/tv:/media/tv:ro
      # TZ y reloj sincronizados con el host.
      - /etc/localtime:/etc/localtime:ro

    # Sin `ports:` — Jellyfin solo es accesible vía Caddy por la red `homelab`.
    # Si el operador necesita DLNA, ver §12.4 (network_mode: host).
    networks:
      - homelab

    # Recursos: Jellyfin con scan en curso de una biblioteca grande puede
    # tocar 1.5 GB de RAM (FFprobe en paralelo + cache de imágenes).
    # Limitar evita OOM en el host (8 GB compartidos con todo).
    mem_limit: 2g
    mem_reservation: 512m

    # Healthcheck: GET /health devuelve 200 si Jellyfin respondió al
    # HTTP listener. El primer arranque tarda ~30s (init de la BD SQLite).
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8096/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

    # security_opt: igual que el resto del homelab (../02-docker/02-estructura-compose.md §0).
    security_opt:
      - no-new-privileges:true

    labels:
      # Watchtower: NO actualizar automáticamente — política, ../02-docker/04-watchtower.md §6.
      com.centurylinklabs.watchtower.enable: "false"
      # Para Dozzle: agrupar logs de servicios multimedia.
      dev.dozzle.group: "media"

networks:
  homelab:
    external: true
```

### 4.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `name: jellyfin` | Nombre del proyecto Compose. Cada servicio multimedia tiene su propio stack folder, aunque [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3 los agrupa conceptualmente bajo "media". Así un `docker compose -f ~/homelab/stacks/jellyfin/docker-compose.yml down` solo afecta a Jellyfin. |
| `image: jellyfin/jellyfin:${JELLYFIN_IMAGE_TAG}` | Tag pinned vía `.env`. La imagen oficial vive en Docker Hub. La alternativa `lscr.io/linuxserver/jellyfin` cambia paths y usa s6-overlay (ver fila "Imagen" de la tabla §0). |
| `container_name: jellyfin` / `hostname: jellyfin` | Nombre estable para que Caddy llegue por DNS (`reverse_proxy http://jellyfin:8096`). Sin esto, Compose le pone un nombre tipo `jellyfin-jellyfin-1` y rompe el DNS interno. |
| `env_file: /mnt/hd2t/services/jellyfin/.env` | Carga de variables — patrón estándar del homelab. |
| `user: "${HOMELAB_UID}:${MEDIA_GID}"` | UID 1000 (escribe en `/config`, `/cache`), GID 1100 (lee en `/media/{movies,tv}`). Sin esto, Jellyfin correría como `root` dentro y los ficheros aparecerían como `root:root` en el host — incompatible con el patrón del homelab. |
| `environment.TZ` | Jellyfin loguea timestamps en zona local (los logs son `Jellyfin.{date}.log` en `/config/log/`). El YAML del propio Jellyfin no tiene equivalente; `TZ` es la única vía. |
| `environment.JELLYFIN_PublishedServerUrl` | Sin esto, los enlaces absolutos generados por Jellyfin (descargas de subtítulos, manifests HLS, posters en API) usan el primer `Host` header que recibieron — frágil cuando hay tres hosts (`jellyfin.lan`, `jellyfin.tailnet.ts.net`, IP). Fijarlo a `https://jellyfin.lan` es la opción más robusta para el cliente local; las apps externas ven la URL pública (Tailscale) cuando reciben el manifest porque Jellyfin no rescribe URLs absolutas en HLS si vienen del cliente. Valoración: usar **siempre** la URL LAN aquí; las apps remotas resuelven el TS host directamente vía MagicDNS. |
| `volumes: /mnt/hd2t/services/jellyfin/config:/config` | Bind mount canónico. Sin `:Z`/`:z` (no SELinux en Pi OS). |
| `volumes: /mnt/hd2t/services/jellyfin/{cache,transcodes,metadata}:...` | Cada uno separado para que Borgmatic los pueda excluir individualmente. La política de [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6 lista exactamente esos paths como exclusiones. |
| `volumes: /mnt/hd2t/media/movies:/media/movies:ro` | **Read-only** desde Jellyfin. Sonarr/Radarr son los dueños del árbol de medios; Jellyfin solo lee. |
| `volumes: /etc/localtime:ro` | Sincroniza la zona del host con el contenedor. Backup ante un usuario que olvide poner `TZ` en `.env`. |
| `networks: [homelab]` | Solo la red compartida. Caddy ya está ahí; Sonarr/Radarr se enchufan también a `homelab` (Fase 10) y emiten webhooks "Library Refresh" a Jellyfin por DNS Docker (`http://jellyfin:8096`). |
| `mem_limit: 2g` | Jellyfin con escaneo en paralelo de 200 películas (FFprobe + extracción de chapter images) puede consumir 1.5 GB. 2 GB de tope deja margen y evita que un leak baje toda la Pi. |
| `mem_reservation: 512m` | Garantía mínima en presión de memoria. Jellyfin arranca con ~250 MB; 512 MB asegura un arranque limpio incluso con el host saturado. |
| `healthcheck` con `/health` | Endpoint introducido en Jellyfin 10.8+. Devuelve `200 OK` cuando el HTTP listener arrancó (no garantiza que la BD esté lista, pero sí que el proceso responde). `start_period: 60s` cubre la inicialización del schema SQLite la primera vez. |
| `security_opt: no-new-privileges:true` | Patrón base ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §0). Jellyfin no necesita `setuid`, así que no rompe nada. |
| `com.centurylinklabs.watchtower.enable: "false"` | Watchtower por opt-in en el homelab ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §0). Jellyfin está explícitamente excluido por la política de upgrades manuales. |
| `dev.dozzle.group: "media"` | Cuando Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)) levante, agrupa Jellyfin, Navidrome, Audiobookshelf y Calibre-Web bajo el mismo grupo "media". |
| `networks.homelab.external: true` | Patrón de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.4: la red se crea **una vez** durante el bootstrap; aquí solo se consume. |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/jellyfin
docker compose --env-file /mnt/hd2t/services/jellyfin/.env config

# Esperado: salida YAML resuelta sin warnings.
# - El `image` debe estar plenamente cualificado: jellyfin/jellyfin:10.10.3
# - `user: "1000:1100"` (no comillas vacías ni `null`).
# - Sin warning "variable X not set".
# - `volumes` con paths absolutos.
# - Las dos bibliotecas con `read_only: true`.
```

---

## 5. Despliegue

### 5.1. Levantar el stack

```bash
cd ~/homelab/stacks/jellyfin
docker compose --env-file /mnt/hd2t/services/jellyfin/.env up -d
```

El primer `up` tarda **~1–2 minutos** porque Jellyfin:

1. Descarga la imagen (~400 MB en arm64).
2. Inicializa el schema SQLite en `/config/data/jellyfin.db` y `/config/data/library.db`.
3. Crea `system.xml`, `network.xml` con valores por defecto.
4. Levanta el HTTP listener en `:8096` (el `:8920` HTTPS no se usa — Caddy termina TLS).

### 5.2. Estado de los contenedores

```bash
docker compose --env-file /mnt/hd2t/services/jellyfin/.env ps

# Esperado, tras ~1 minuto:
# NAME       IMAGE                          STATUS                 PORTS
# jellyfin   jellyfin/jellyfin:10.10.3      Up X (healthy)
```

Si tras 3 minutos el estado sigue siendo `(starting)`:

```bash
docker compose --env-file /mnt/hd2t/services/jellyfin/.env logs --tail=200 jellyfin

# Buscar líneas tipo:
# - "Jellyfin Server is now started": arranque normal.
# - "Permission denied accessing /config/data/jellyfin.db": revisar PUID/PGID y permisos del bind mount.
# - "Failed to find FFmpeg at ...": no debería pasar — la imagen oficial trae jellyfin-ffmpeg.
```

### 5.3. Onboarding inicial (wizard "Welcome")

Jellyfin expone su UI en `http://jellyfin:8096` (red `homelab`). Caddy aún no lo enruta hasta §6. Para el primer onboarding, dos opciones:

**Opción A — Vía Caddy (preferida)**: completar §6 antes de lanzar el wizard. Abrir `https://jellyfin.lan` desde un navegador del LAN.

**Opción B — `docker exec` para validar**:

```bash
# Verificar que Jellyfin responde dentro del contenedor.
docker exec jellyfin curl -fsS http://localhost:8096/health
# Esperado: "Healthy"

# Ver primer log de Jellyfin.
docker exec jellyfin sh -c 'tail -50 /config/log/jellyfin*.log'
```

> En la práctica el flujo recomendado es **Opción A**: completar §6, abrir `https://jellyfin.lan`, cumplir el wizard.

El wizard pide:

1. **Idioma** del servidor (`Spanish (Spain)` o el preferido del operador).
2. **Usuario admin**: nombre + password. Esta cuenta tiene **todos** los privilegios; el password se guarda hasheado (PBKDF2-SHA512) en `/config/data/jellyfin.db`. **Anotar el password** porque no hay "olvidé contraseña" sin acceso al filesystem.
3. **Bibliotecas**: añadir las de §7.1.
4. **Detección de país** y unidades.
5. **Acceso remoto**: marcar "Allow remote connections to this server" (Jellyfin escuchará en todas las interfaces — pero solo hay una, la del bridge). **NO** marcar "Enable automatic port mapping"; el homelab no usa UPnP.

> **Si se cierra el wizard a medio**: el estado se guarda en `system.xml` (`<IsStartupWizardCompleted>false</IsStartupWizardCompleted>`). Recargar `https://jellyfin.lan` retoma donde se dejó.

---

## 6. Integración con Caddy

### 6.1. Activar el bloque `jellyfin.{$LAN_DOMAIN}` del `Caddyfile`

El `Caddyfile` del homelab ya incluye un placeholder para Jellyfin ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3, líneas "Jellyfin"). Editar `~/homelab/stacks/proxy/Caddyfile` y descomentar:

```caddy
# Jellyfin (../09-multimedia/01-jellyfin.md) — websockets para chromecast/apps
jellyfin.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Subida de archivos grandes vía API (raros, pero algunos plugins
    # importan poster art de varios MB). Por defecto Caddy permite
    # 10 MiB; Jellyfin no necesita más con uso normal, pero subir el
    # límite no cuesta nada y evita un futuro 413 críptico.
    request_body {
        max_size 100MB
    }

    # Websockets son críticos: las sessions activas (apps móviles,
    # navegador, Chromecast, "Dashboard > Devices") los usan para
    # heartbeat y comandos remotos. Caddy los reenvía transparentemente
    # con `reverse_proxy`; aquí no hace falta directiva especial.
    reverse_proxy http://jellyfin:8096 {
        header_up Host {host}
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
        # Jellyfin maneja stream HLS de hasta varios GB sin transcoding
        # para Direct Play. flush_interval -1 evita buffering en Caddy
        # y reduce latencia de inicio de reproducción.
        flush_interval -1
    }
}
```

Y el bloque Tailscale gemelo (comentado hasta tener cert vía `tailscale cert`):

```caddy
# jellyfin.{$TS_DOMAIN} {
#     import tailscale_tls jellyfin
#     import security_headers
#     request_body {
#         max_size 100MB
#     }
#     reverse_proxy http://jellyfin:8096 {
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
#           2025/.../INFO   tls.cache.maintenance ...
# Si hay error, vuelve a abrir el bloque en el editor: "X-line: ..." apunta al lineno.
```

### 6.2. Trusted proxies en Jellyfin (`network.xml`)

Sin esto, Jellyfin loguea siempre la IP de Caddy (`172.20.0.X`) en `Jellyfin.log`, no la del cliente real. Editar `/mnt/hd2t/services/jellyfin/config/network.xml`:

```xml
<!-- /mnt/hd2t/services/jellyfin/config/network.xml -->
<NetworkConfiguration>
    <BaseUrl />
    <EnableHttps>false</EnableHttps>
    <RequireHttps>false</RequireHttps>
    <InternalHttpPort>8096</InternalHttpPort>
    <InternalHttpsPort>8920</InternalHttpsPort>
    <PublicHttpPort>8096</PublicHttpPort>
    <PublicHttpsPort>8920</PublicHttpsPort>
    <PublishedServerUriBySubnet />
    <!-- Subred del bridge `homelab` (../02-docker/02-estructura-compose.md §4.1).
         Jellyfin confiará en X-Forwarded-For si la conexión TCP viene de aquí. -->
    <KnownProxies>
        <string>172.20.0.0/24</string>
    </KnownProxies>
    <EnableUPnP>false</EnableUPnP>
    <EnableRemoteAccess>true</EnableRemoteAccess>
    <EnableIPv4>true</EnableIPv4>
    <EnableIPv6>false</EnableIPv6>
    <CertificatePath />
    <CertificatePassword />
</NetworkConfiguration>
```

Reiniciar Jellyfin para que recoja el cambio:

```bash
docker compose --env-file /mnt/hd2t/services/jellyfin/.env restart jellyfin
```

Comprobar que ahora el log refleja la IP del cliente real (no la del bridge):

```bash
# Acceder desde el navegador a https://jellyfin.lan (login).
docker exec jellyfin sh -c 'tail -20 /config/log/jellyfin*.log'

# Buscar la línea con el login:
# [INFO] [...] Authentication request for "admin" has succeeded. RequestRemoteIp=192.168.1.50
# (no 172.20.0.X)
```

> **Alternativa por la UI**: "Dashboard > Networking > Known proxies" → añadir `172.20.0.0/24`. Equivalente al XML anterior.

### 6.3. Registro DNS local en Pi-hole

Pi-hole resuelve `jellyfin.lan` → IP de la Pi. Esto ya estaba descrito conceptualmente en [`../03-red/02-pihole.md`](../03-red/02-pihole.md) §7.

```bash
# Vía la UI de Pi-hole (preferido):
# 1. Abrir https://pihole.lan/admin/
# 2. "Local DNS > DNS Records"
# 3. Domain: jellyfin.lan
#    IP:     192.168.1.10  (la IP estática de la Pi en LAN)
# 4. "Add"

# O vía CLI:
docker exec pihole pihole-FTL dns -A jellyfin.lan 192.168.1.10
# (sintaxis exacta según versión de pihole-FTL; ver doc de Pi-hole)
```

Verificar:

```bash
dig +short @192.168.1.2 jellyfin.lan
# Esperado: 192.168.1.10
```

### 6.4. Probar el acceso

```bash
# Desde el host (red homelab interna):
docker exec caddy curl -fsS -H 'Host: jellyfin.lan' http://jellyfin:8096/health
# Esperado: "Healthy"

# Desde la LAN (validar TLS):
curl -fsS https://jellyfin.lan/health
# Esperado: "Healthy". El cert es de la CA interna de Caddy
# (../03-red/04-caddy.md §3.4); el navegador puede protestar.
# Solución: instalar el root cert de Caddy (../03-red/04-caddy.md §6).

# Desde el navegador:
# https://jellyfin.lan → wizard de Jellyfin (§5.3).
```

### 6.5. (No por defecto) Proteger con Authelia

**El homelab no pone Authelia delante de Jellyfin por defecto** — explicado en §0 fila "Reverse proxy" y desarrollado en §12.3. La razón en una línea: las apps oficiales (Android, iOS, Roku, Smart TV) y los Chromecasts usan `Authorization: MediaBrowser Token=<token>` — no envían cookie SSO; un `forward_auth` los rechazaría con 401 antes de que la cabecera llegara a Jellyfin.

Si aun así se quiere, ver §12.3 para el snippet con bypass exhaustivo de rutas y comprobaciones que el operador asume.

---

## 7. Configuración post-despliegue

### 7.1. Añadir las bibliotecas

Tras crear el usuario admin (§5.3), si el wizard no añadió bibliotecas, añadirlas manualmente:

1. **Dashboard > Libraries > Add Media Library**.
2. **Movies**:
   - **Content type**: `Movies`.
   - **Display name**: `Películas`.
   - **Folders**: `/media/movies`.
   - **Metadata downloaders**: `TheMovieDb` (activado), `Open Movie Database (OMDb)` (opcional).
   - **Image fetchers**: `TheMovieDb` (activado).
   - **Subtitle downloaders**: `OpenSubtitles` (vía plugin, §7.7).
   - **Save metadata into media folders**: **DESACTIVADO** (la fila "Bibliotecas como read-only" de §0).
   - **Enable real time monitoring**: **ACTIVADO** (`inotify` notifica cambios cuando Sonarr/Radarr ingestan).
3. **TV Shows** (igual estructura):
   - **Content type**: `Shows`.
   - **Display name**: `Series`.
   - **Folders**: `/media/tv`.
   - **Metadata downloaders**: `TheTVDB` y `TheMovieDb` (en ese orden).
   - **Image fetchers**: igual.
   - **Save metadata into media folders**: **DESACTIVADO**.
   - **Enable real time monitoring**: **ACTIVADO**.

> **Por qué dos llamadas separadas y no una sola con dos folders**: Jellyfin permite una librería con varias carpetas, pero perderías la posibilidad de aplicar políticas distintas (p. ej. ratings parentales, scrapers preferentes). Por defecto se separan películas y series — coincide con la estructura de `/mnt/hd2t/media/`.

### 7.2. Crear los usuarios secundarios (familia)

**Dashboard > Users > Add User**:

| Usuario | Rol | Bibliotecas | Carpetas con restricción parental |
|---|---|---|---|
| `admin` (creado en wizard) | Admin | Todas | — |
| `family` | User estándar | `Películas`, `Series` | "Block content with rating: PG-13 and below" si aplica |
| `kids` (opcional) | User restringido | `Películas`, `Series` (con filtro de "Max parental rating: PG") | "Hide unrated/unrecognized content" |

Para cada usuario:

- **Profile > Maximum allowed bitrate**: `4 Mbps` para `kids` (3G de visita), ilimitado para `admin`/`family` en LAN.
- **Profile > Allow remote control of other users**: solo `admin`.
- **Password reset PIN**: opcional, recuperación local si se olvida el password.

### 7.3. Configurar el escaneo de bibliotecas

**Dashboard > Scheduled Tasks**:

| Task | Schedule por defecto | Cambiar a | Por qué |
|---|---|---|---|
| `Scan Media Library` | Cada 4 h | **Cada 24 h, 03:30** | Sonarr/Radarr disparan refresh por webhook (§7.5); el scan periódico es solo plan B. Ejecutarlo en la madrugada evita compartir I/O con uso interactivo. |
| `Refresh People` | 1×/sem | **Mantener** | Carga de TheMovieDb. Bajo coste. |
| `Optimize Database` | 1×/sem (domingo 02:00) | **Mantener** | `VACUUM` de SQLite. Útil tras grandes cambios. |
| `Clean Up Cache` | Cada 24 h | **Cada 24 h, 04:00** | Borra `/cache/transcodes/*` huérfanos. |

### 7.4. Direct play como estrategia de transcoding

**Dashboard > Playback > Transcoding**:

- **Transcoding hardware acceleration**: `None` (ver §0 fila "Hardware transcoding").
- **Allow transcoding**: **Sí** (fallback) — pero ver siguiente punto.
- **Transcoding thread count**: `Auto` (la Pi 5 tiene 4 cores; Auto = 3, deja 1 para el resto del homelab).
- **Allow throttling**: `Auto` (Jellyfin pausa el transcode cuando el cliente buffer está lleno).
- **Hardware decoding for**: dejar **vacío** (no marcar nada).
- **Enable hardware encoding**: **DESACTIVADO**.
- **Transcoding temporary path**: `/transcodes` (apunta al bind mount; sin esto, Jellyfin transcodea en `/cache/transcodes/`, mezclando con el cache permanente — incómodo para limpieza).

**Estrategia clave**: configurar los **clientes** para que pidan direct play. En cada cliente:

- **App Android/iOS Jellyfin oficial**: "Settings > Playback > Maximum bitrate" → `Auto` en LAN. La app detecta el codec del fichero y solo pide transcode si el dispositivo no lo soporta nativamente.
- **Smart TV / Roku**: instalar la app de Jellyfin oficial. Configurar el "Bitrate limit" a `Auto`.
- **Navegador**: Chrome/Firefox soportan H.264 + AAC + MP4 nativamente. Si la película es MKV con HEVC + DTS, **se transcodificará** sí o sí en el browser. La solución: o usar la app nativa, o asegurar que el contenido está en formato compatible (Sonarr/Radarr profile que prefiera H.264 1080p).

### 7.5. Webhooks Sonarr/Radarr → Jellyfin

Sin esto, una película descargada por Radarr no aparece en Jellyfin hasta el siguiente scan (§7.3).

**En Jellyfin**:

1. **Dashboard > API Keys > +** → **App name**: `radarr`. Copiar la key.
2. Repetir para `sonarr`.

**En Radarr** ([`../10-descargas/04-radarr.md`](../10-descargas/04-radarr.md) §X — pendiente de redactar):

```yaml
# Settings > Connect > Add (Jellyfin):
Name: Jellyfin
Host: jellyfin
Port: 8096
API Key: <la copiada>
Trigger on: Movie Imported, Movie File Deleted, On Movie Renamed
Update Library: Yes
Use SSL: No
```

**En Sonarr** ([`../10-descargas/03-sonarr.md`](../10-descargas/03-sonarr.md)):

Mismo patrón con la key de `sonarr`. Trigger: `On Episode Imported`, `On Series Renamed`, `On Episode File Delete`.

> **Por qué `host: jellyfin` y no `jellyfin.lan`**: dentro de la red `homelab`, Docker DNS resuelve `jellyfin` → IP del contenedor. Pasar por Caddy (`jellyfin.lan`) implicaría TLS interno innecesario y un *hop* extra. La conexión interna por nombre + puerto 8096 es la canónica en el homelab.

### 7.6. Notificaciones (opcional)

Jellyfin puede notificar errores de scan, fallos de transcode y nuevos usuarios. **Dashboard > Notifications**:

- **Webhook generic** apuntando a un canal de Telegram (vía Apprise, [`../05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md) §11), o
- **Plugin "Webhook"** que es más rico pero requiere instalación adicional.

Mínimo recomendable: notificar `User Authentication Failure` (mítico para detectar password brute-force, complementa Fail2ban del host).

### 7.7. Plugins recomendados

**Dashboard > Plugins > Catalog**:

| Plugin | Para qué | Notas |
|---|---|---|
| **OpenSubtitles** | Descarga subtítulos automáticamente al añadir una película/episodio | Requiere cuenta gratuita en opensubtitles.com (rate-limited a 5 descargas/día). API key en el plugin. |
| **Kodi Sync Queue** | Sincroniza progreso de visualización con clientes Kodi | Solo si se usa Kodi como cliente. |
| **Trakt** | Sincroniza historial con trakt.tv | Útil para "ver lo que ha visto la pareja en otro dispositivo". Requiere cuenta. |
| **Skip Intro Detection** | Detecta openings y endings, ofrece botón "Skip" en clientes compatibles | Pesado en CPU al escanear; activar de noche. Requiere `chromaprint` (ya viene en jellyfin-ffmpeg). |
| **TMDb Box Sets** | Agrupa colecciones (Trilogía Star Wars, etc.) automáticamente | Cosmético. |
| **Webhook** | Notificaciones HTTP custom (Discord, Telegram, ntfy) | Más rico que el "Generic Webhook" interno. |

**Plugins desaconsejados en el homelab**:

- `LDAP authentication`: el homelab no tiene LDAP/AD; Jellyfin tiene auth nativa.
- `Reports`: panel de "qué se ha visto"; recolecta data poco útil y consume BD.
- `Anime`: cargado de scrapers exóticos que pueden retornar metadatos contradictorios. Solo si se usa intensivamente.

---

## 8. Verificación

### 8.1. Contenedor sano

```bash
docker compose --env-file /mnt/hd2t/services/jellyfin/.env ps
# Esperado: Up X (healthy)

docker inspect jellyfin --format '{{.State.Health.Status}}'
# Esperado: healthy
```

### 8.2. Direct play funciona

Reproducir una película en H.264 1080p desde el navegador y verificar **Dashboard > Playback > Active**: la columna "Stream" debe decir `Direct Stream` o `Direct Play` (no `Transcoding`).

```bash
# En paralelo, comprobar que ffmpeg NO está corriendo
# (si direct play, no hay transcode):
docker exec jellyfin sh -c 'pgrep ffmpeg && echo "ffmpeg corriendo" || echo "no ffmpeg (direct play OK)"'
# Esperado: "no ffmpeg (direct play OK)"
```

### 8.3. Jellyfin escucha solo dentro de la red `homelab`

```bash
# Desde el host: el puerto 8096 NO debe responder.
ss -tlnp | grep 8096
# Esperado: vacío (sin línea).

curl -fsS -m 3 http://localhost:8096/health
# Esperado: error de conexión (Connection refused).

# Desde dentro de la red homelab sí debe responder.
docker exec caddy curl -fsS http://jellyfin:8096/health
# Esperado: "Healthy"
```

### 8.4. Bibliotecas montadas y leídas

```bash
docker exec jellyfin ls -la /media/movies | head
docker exec jellyfin ls -la /media/tv     | head
# Esperado: ficheros visibles si los hay; permisos como en host.

# Test escritura (debería FALLAR — `:ro`):
docker exec jellyfin touch /media/movies/test_write
# Esperado: "Read-only file system"
```

### 8.5. Trusted proxies activo

Tras hacer login en `https://jellyfin.lan` desde un PC con IP `192.168.1.50`:

```bash
docker exec jellyfin sh -c 'grep "Authentication request" /config/log/jellyfin*.log | tail -3'
# Esperado: ... RequestRemoteIp=192.168.1.50 ...
# (NO 172.20.0.X)
```

### 8.6. Smoke test desde el navegador

1. `https://jellyfin.lan` carga la pantalla de login.
2. Login con `admin` exitoso.
3. La biblioteca **Películas** muestra al menos un poster (si hay contenido) o "Empty library" sin error.
4. Reproducir una película arbitraria: empieza < 5s.
5. Cerrar sesión y volver a entrar: persiste el progreso de reproducción.

### 8.7. Persistencia tras reboot

```bash
sudo reboot
# Esperar ~2 min.
ssh homelab@pi.lan
docker compose --env-file /mnt/hd2t/services/jellyfin/.env -f ~/homelab/stacks/jellyfin/docker-compose.yml ps
# Esperado: jellyfin Up X (healthy) — restart: unless-stopped lo trae solo.
```

### 8.8. Lista de verificación

- [ ] `docker compose ... ps` muestra `Up X (healthy)`.
- [ ] `docker inspect jellyfin --format '{{.State.Health.Status}}'` = `healthy`.
- [ ] `ss -tlnp | grep 8096` no devuelve nada (no hay puerto publicado).
- [ ] `curl -fsS https://jellyfin.lan/health` = `Healthy`.
- [ ] `docker exec jellyfin touch /media/movies/test_write` falla con `Read-only file system`.
- [ ] Login en `https://jellyfin.lan` con cuenta admin OK.
- [ ] `Dashboard > Playback > Active` muestra `Direct Stream` o `Direct Play` para un H.264 1080p en el navegador.
- [ ] `docker exec jellyfin grep "RequestRemoteIp=192.168" /config/log/jellyfin*.log` devuelve líneas con la IP real del cliente (no del bridge).
- [ ] Tras `sudo reboot`, Jellyfin vuelve a estar `(healthy)` en menos de 3 minutos.
- [ ] Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6) lista `/mnt/hd2t/services/jellyfin/config/` en el archivo y **no** lista `cache/`, `transcodes/`, `metadata/library/`.

---

## 9. Backup

### 9.1. Qué se respalda y qué no

| Ruta | Backup | Justificación |
|---|---|---|
| `/mnt/hd2t/services/jellyfin/config/` | **Sí** (Borgmatic, [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6) | Contiene `data/jellyfin.db` (usuarios, watch history, API keys), `data/library.db` (ítems indexados, ratings, fechas), `system.xml`, `network.xml`, `plugins/<plugin>/<conf>`, `log/` (rotado por Jellyfin). ~50 MB tras 1 mes. |
| `/mnt/hd2t/services/jellyfin/cache/` | **No** | Subtítulos descargados, frame thumbnails, image cache. Regenerable. Puede crecer a 5 GB+. |
| `/mnt/hd2t/services/jellyfin/transcodes/` | **No** | Salida temporal de FFmpeg. Borrado por la propia tarea programada `Clean Up Cache`. |
| `/mnt/hd2t/services/jellyfin/metadata/` | **No** (excepto si se migra a "guardar NFO en biblioteca") | Posters, fanart, NFO descargados. Re-scan los regenera en ~30 min para una biblioteca de 500 ítems. |
| `/mnt/hd2t/media/` | **Política aparte** ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §6) | El **contenido** multimedia se respalda según política propia: `tv/` y `movies/` son **re-descargables** desde Sonarr/Radarr → en general **no se incluyen** en el repo de Borg principal. Si el operador quiere preservar copia exacta (rip de Blu-ray sin fuente), excluirlos del default y hacer un repo Borg dedicado. |

### 9.2. Política Borgmatic

`~/homelab/stacks/backup/config/borgmatic.d/jellyfin.yaml` (extendiendo el doc principal):

```yaml
# Cubierto en ../07-backups/02-borgmatic.md §13.6 — solo aquí como referencia.
source_directories:
  - /mnt/hd2t/services/jellyfin/config

exclude_patterns:
  # Logs viejos (Jellyfin ya rota, pero Borg compresión los reduce poco).
  - /mnt/hd2t/services/jellyfin/config/log/jellyfin.log.*
  # transcoding cache temporal (si por error está dentro de config).
  - /mnt/hd2t/services/jellyfin/config/transcoding-temp/
```

> **El doc maestro** [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6 lista explícitamente las **exclusiones** (`/mnt/hd2t/services/jellyfin/cache`, `/mnt/hd2t/services/jellyfin/transcodes`, `/mnt/hd2t/services/jellyfin/metadata/library`). No duplicar la lista aquí; mantenerla en un único sitio.

### 9.3. Restore (resumen)

```bash
# 0. Asumiendo Pi recién instalada y borg/borgmatic operativo.
# 1. Recrear el árbol de directorios (§3.2).
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/jellyfin \
  /mnt/hd2t/services/jellyfin/config \
  /mnt/hd2t/services/jellyfin/cache \
  /mnt/hd2t/services/jellyfin/transcodes \
  /mnt/hd2t/services/jellyfin/metadata

# 2. Listar archivos disponibles.
sudo borgmatic list

# 3. Extraer SOLO el config de Jellyfin del último archivo.
sudo borgmatic extract \
  --archive latest \
  --path mnt/hd2t/services/jellyfin/config \
  --destination /

# 4. Verificar permisos del config.
sudo chown -R 1000:1000 /mnt/hd2t/services/jellyfin/config

# 5. Levantar Jellyfin.
cd ~/homelab/stacks/jellyfin
docker compose --env-file /mnt/hd2t/services/jellyfin/.env up -d

# 6. Forzar re-scan de bibliotecas (regenera metadata/, cache/).
docker exec jellyfin curl -fsS -X POST http://localhost:8096/Library/Refresh \
  -H 'X-Emby-Token: <api-key-admin>'
# (la API key se obtiene tras login con admin → Dashboard > API Keys).

# 7. Validar:
# - Usuarios existentes en /web/index.html#!/userprofile.html
# - Watch history en una serie ya vista
# - Plugins instalados visibles en Dashboard > Plugins.
```

### 9.4. Smoke test mensual de restore

[`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §10 fija un drill mensual de restore. Para Jellyfin:

```bash
# En un directorio temporal (NO sobre la instalación viva):
mkdir -p /tmp/jf-restore-test
cd /tmp/jf-restore-test

sudo borgmatic extract \
  --archive latest \
  --path mnt/hd2t/services/jellyfin/config/data/jellyfin.db \
  --destination .

# Verificar que la BD es válida y tiene usuarios.
sudo apt-get install -y sqlite3  # si no está
sqlite3 ./mnt/hd2t/services/jellyfin/config/data/jellyfin.db \
  'SELECT Username, IsAdministrator FROM Users;'
# Esperado: lista con admin, family, kids (los creados en §7.2).

rm -rf /tmp/jf-restore-test
```

---

## 10. Operaciones cotidianas

### 10.1. Upgrade manual (mensual o tras release)

```bash
# 1. Leer el release blog: https://jellyfin.org/posts/
#    Buscar "Breaking Changes", "Migration notes".

# 2. Editar /mnt/hd2t/services/jellyfin/.env:
sed -i 's/^JELLYFIN_IMAGE_TAG=.*/JELLYFIN_IMAGE_TAG=10.10.4/' \
  /mnt/hd2t/services/jellyfin/.env

# 3. Backup ad-hoc del config ANTES (Borgmatic respalda diariamente
#    pero forzar uno extra cuesta segundos).
sudo borgmatic create --verbosity 1

# 4. Pull de la nueva imagen (manualmente; no Watchtower).
cd ~/homelab/stacks/jellyfin
docker compose --env-file /mnt/hd2t/services/jellyfin/.env pull jellyfin

# 5. Recrear el contenedor.
docker compose --env-file /mnt/hd2t/services/jellyfin/.env up -d

# 6. Vigilar el primer arranque tras upgrade (la BD migra schema).
docker compose --env-file /mnt/hd2t/services/jellyfin/.env logs -f jellyfin

# Esperado:
# - "Jellyfin version: 10.10.4"
# - "Migration completed" si toca migrar schema
# - "Jellyfin Server is now started"

# 7. Smoke test: login + reproducir un episodio.

# 8. Si algo se rompe: rollback.
sed -i 's/^JELLYFIN_IMAGE_TAG=.*/JELLYFIN_IMAGE_TAG=10.10.3/' \
  /mnt/hd2t/services/jellyfin/.env
docker compose --env-file /mnt/hd2t/services/jellyfin/.env up -d
# Si la BD ya migró a un schema más nuevo, restaurar config/ desde Borg.
```

### 10.2. Forzar re-escaneo de bibliotecas

Tras un movimiento manual (rsync de un disco externo) o un cambio de estructura:

```bash
# Vía API (sin abrir UI). Necesita una API key.
JF_TOKEN=$(grep -oP 'AccessToken="\K[^"]+' /mnt/hd2t/services/jellyfin/config/data/jellyfin.db 2>/dev/null \
  || echo "<obtener desde Dashboard > API Keys>")

docker exec jellyfin curl -fsS -X POST http://localhost:8096/Library/Refresh \
  -H "X-Emby-Token: ${JF_TOKEN}"

# O por la UI: Dashboard > Libraries > "Scan All Libraries".
```

### 10.3. Limpieza de transcodes y cache

```bash
# Vía UI: Dashboard > Scheduled Tasks > Clean Up Cache > "Run".

# Vía sistema (last resort, con Jellyfin parado):
docker compose --env-file /mnt/hd2t/services/jellyfin/.env stop jellyfin
sudo find /mnt/hd2t/services/jellyfin/transcodes -mindepth 1 -delete
sudo find /mnt/hd2t/services/jellyfin/cache -mindepth 1 -delete
docker compose --env-file /mnt/hd2t/services/jellyfin/.env start jellyfin
```

### 10.4. Logs

```bash
# Stream en vivo (vía Dozzle o `docker compose logs`).
docker compose --env-file /mnt/hd2t/services/jellyfin/.env logs -f jellyfin

# Logs persistentes de Jellyfin (más detallados que stdout).
docker exec jellyfin sh -c 'ls -lh /config/log/'
docker exec jellyfin sh -c 'tail -200 /config/log/jellyfin*.log'

# Errores recientes:
docker exec jellyfin sh -c 'grep -E "ERR|FATAL" /config/log/jellyfin*.log | tail -50'
```

### 10.5. Gestión de usuarios

Vía UI siempre (no hay CLI ni API trivial para crear usuarios sin admin token):

- **Añadir**: Dashboard > Users > +.
- **Eliminar**: Dashboard > Users > <user> > Delete (la watch history y favoritos se borran; los items de la biblioteca, no).
- **Cambiar password (lo olvidó el user)**: Dashboard > Users > <user> > Password > "Easy Password". Si el user tenía 2FA TOTP también vía PIN local.
- **Reset password de admin (perdido el control)**: editar `/config/data/jellyfin.db` (tabla `Users`, campo `Password`). Hashes PBKDF2 — la forma práctica es restaurar desde Borg un snapshot anterior con la cuenta operativa, o reinstalar el wizard borrando `system.xml`'s `<IsStartupWizardCompleted>`.

### 10.6. Comportamiento durante mantenimiento

| Situación | Resultado | Mitigación |
|---|---|---|
| `docker compose stop jellyfin` (planificado) | Apps de los clientes muestran "Cannot connect to server". Sesiones HLS activas se cortan al instante. | Avisar a la familia 5 min antes. |
| Caddy reload | Las sessions HLS reciben `502` momentáneo (~ 1 segundo); las apps reintentan. | Sin acción. |
| Pi-hole caído | `jellyfin.lan` no resuelve dentro del LAN. | Fallback DNS en clientes ([`../03-red/02-pihole.md`](../03-red/02-pihole.md) §10) o IP directa. |
| Disco hd2t saturado | Jellyfin no puede escribir transcodes ni cache; reproducciones que necesitan transcode fallan; direct play sigue funcionando. | Monitorización ([`../05-monitorizacion/02-grafana.md`](../05-monitorizacion/02-grafana.md), Node Exporter). Limpiar transcodes (§10.3). |

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Cómo diagnosticar | Remedio |
|---|---|---|---|
| `Read-only file system` al añadir biblioteca apuntando a `/media/movies` | El bind mount es `:ro` (correcto) pero el operador marcó "Save metadata into media folders" | Mensaje en `/config/log/jellyfin*.log` con `IOException: Read-only` | Desactivar "Save metadata into media folders" (§7.1). Si **es** el comportamiento querido, ver §12.5. |
| Login OK pero "Cannot connect to server" en app móvil | URL del servidor mal en la app | App settings → Server → URL | Cambiar a `https://jellyfin.lan` o `https://jellyfin.tailnet.ts.net`, no IP. |
| Direct play falla en Chrome con `Codec not supported` | El fichero es HEVC (h.265) o tiene audio DTS/TrueHD | Dashboard > Playback > Active → "Stream: Transcoding" | Pre-transcodificar a H.264 + AAC (vía Sonarr quality profile, o `tdarr` offline). Hardware transcoding no es solución viable en Pi 5. |
| `Authentication request for "X" has failed` repetido en log | Brute-force (raro en LAN) o cliente con credenciales obsoletas | `grep "has failed" /config/log/jellyfin*.log` | Banear IP via Fail2ban del host ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md), jail `jellyfin` opt-in). Forzar logout del cliente desde Dashboard > Devices. |
| Subtítulos no se descargan automáticamente | Plugin OpenSubtitles sin API key, o rate-limit alcanzado (free tier: 5/día) | `Dashboard > Plugins > OpenSubtitles > Settings`; `grep -i opensubt /config/log/jellyfin*.log` | Activar API key personal o subir a tier de pago. Alternativa: descargar subtítulos manualmente con `subliminal`. |
| Biblioteca tarda 30+ min en escanear | Normal en biblioteca de >500 ítems la primera vez (FFprobe + thumbnail extraction) | Dashboard > Scheduled Tasks > Scan Media Library → progress | Esperar. Sucesivos scans son rápidos (solo files nuevos vía mtime). |
| `metadata/library/` crece sin parar | Plugins agresivos (Skip Intro, frame chapter images de cada minuto) | `du -sh /mnt/hd2t/services/jellyfin/metadata/library/` | Limpiar tareas de chapter images en bibliotecas grandes; o aceptar el coste y monitorizar el disco. |
| Apps de Smart TV / Roku no encuentran el servidor en "Add Server" | No hay UDP discovery (intencional, §0 fila "Red Docker") | — | Añadir el servidor manualmente con la URL `https://jellyfin.lan` (o IP si el cliente no soporta hostname custom). |
| `RequestRemoteIp=172.20.0.X` en log (no la IP del cliente) | `KnownProxies` no configurado en `network.xml` | Verificar §6.2 | Añadir `<string>172.20.0.0/24</string>` y reiniciar el contenedor. |

---

## 12. Variantes opt-in

### 12.1. Hardware transcoding V4L2 m2m (experimental, Pi 5)

**Ojo**: el equipo de Jellyfin **no soporta oficialmente** Pi 5 para HW acceleration. El V4L2 m2m del VideoCore VII funciona en `ffmpeg` upstream pero **no** está empaquetado en `jellyfin-ffmpeg`. Forzarlo requiere usar la imagen `lscr.io/linuxserver/jellyfin` que **sí** parchea `jellyfin-ffmpeg` con soporte V4L2 m2m, **o** compilarlo a mano.

Sólo HEVC y H.264 **decode** son estables. Encode acelerado por hardware **no funciona** en Pi 5 a fecha de redacción.

```yaml
# Patch al docker-compose.yml — sustituye la imagen y añade devices.
services:
  jellyfin:
    image: lscr.io/linuxserver/jellyfin:10.10.3   # imagen alternativa con V4L2 m2m

    devices:
      # /dev/dri: VideoCore VII vía DRM (no usado por jellyfin-ffmpeg, mantenido por simetría con V4L2).
      - /dev/dri:/dev/dri
      # V4L2 m2m endpoints del VideoCore (Pi 5 los publica como /dev/video10..23).
      - /dev/video10:/dev/video10   # decoder
      - /dev/video11:/dev/video11   # encoder (no funcional, presente por completitud)
      - /dev/video12:/dev/video12

    group_add:
      # Grupo `video` del host (GID típicamente 44 en Pi OS).
      - "44"
```

**Configuración en Jellyfin** (Dashboard > Playback):

- **Hardware acceleration**: `Video4Linux2 (V4L2)`.
- **V4L2 m2m device**: `/dev/video10`.
- **Hardware decoding for**: marcar **solo** `H.264` y `HEVC` (no AV1, no VP9 — no soportados).
- **Enable hardware encoding**: **DESACTIVAR** (rotura conocida).
- **Enable tone mapping**: **NO** (10-bit → 8-bit no funciona vía V4L2 m2m en Pi 5; saldrá un transcode CPU igualmente).

Smoke test:

```bash
# Forzar transcode reproduciendo un HEVC a un cliente que no lo soporta.
# En Dashboard > Playback > Active, debe aparecer "Stream: Transcoding (HW)".
docker exec jellyfin pgrep -af ffmpeg | head -3
# Esperado: línea con `-c:v h264_v4l2m2m` o `-vcodec hevc_v4l2m2m -decode-only`.
```

> **Cuándo activar**: solo si la mayoría del catálogo es HEVC y los clientes son antiguos. Para una biblioteca H.264-first, **no compensa** la complejidad ni el riesgo.

### 12.2. Acceso remoto vía Tailscale

Tras desplegar Tailscale en el host ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) y emitir el cert:

```bash
# 1. Generar cert de Tailscale para el host jellyfin.
tailscale cert jellyfin.tailnet.ts.net

# 2. Mover los .crt y .key al bind mount de Caddy.
sudo mv jellyfin.tailnet.ts.net.crt \
  /mnt/hd2t/services/caddy/tailscale-certs/jellyfin.crt
sudo mv jellyfin.tailnet.ts.net.key \
  /mnt/hd2t/services/caddy/tailscale-certs/jellyfin.key

# 3. Descomentar el bloque jellyfin.{$TS_DOMAIN} en el Caddyfile (§6.1).

# 4. Recargar Caddy.
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

En las apps de Jellyfin de la familia, configurar **dos** URLs:

- "Local" → `https://jellyfin.lan`
- "Remote" → `https://jellyfin.tailnet.ts.net`

La app cambia automáticamente según la conexión (Tailscale activo cuando se sale de casa).

### 12.3. (Desaconsejado) Authelia delante de Jellyfin

Solo para entornos donde se quiere SSO + 2FA delante del **navegador** y se acepta perder las apps nativas. **No recomendado** para uso normal.

```caddy
jellyfin.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Bypass para rutas que las apps necesitan SIN autenticación SSO.
    # Si una de estas rutas se filtra, las apps móviles dejan de funcionar.
    @bypass_auth {
        path /System/Info/Public          # Service discovery
        path /System/Ping
        path /Branding/*                  # Logo / branding
        path /Web/*                       # Recursos estáticos del frontend
        path /web/*
        path /Items/*/Images*             # Posters/thumbnails (clientes embebidos)
        path /Audio/*/stream*             # Audio HLS
        path /Videos/*/stream*            # Video HLS
        path /Videos/*/main.m3u8
        path /Videos/*/master.m3u8
        path /Audio/*/main.m3u8
        path /Subtitles/*
        path /api/*                       # API REST (apps + webhooks)
        path /Sessions*                   # WebSocket sessions (críticas)
        path /socket
        path /artwork/*
        path /Plugins/*/Repositories
    }
    handle @bypass_auth {
        reverse_proxy http://jellyfin:8096 {
            header_up Host {host}
            header_up X-Forwarded-Proto https
            header_up X-Real-IP {remote_host}
            flush_interval -1
        }
    }

    # Resto: aplicar Authelia.
    handle {
        import authelia_proxy
        reverse_proxy http://jellyfin:8096 {
            header_up Host {host}
            header_up X-Forwarded-Proto https
            header_up X-Real-IP {remote_host}
            header_up Remote-User {http.auth.user.username}
            flush_interval -1
        }
    }
}
```

**Riesgo conocido**: cualquier endpoint nuevo que Jellyfin introduzca en una `minor` release **no** estará en la lista de bypass y romperá la app nativa hasta que el operador lo añada manualmente. Por eso el homelab **no** lo activa.

### 12.4. DLNA / auto-discovery

Para que la TV o Sonos encuentre a Jellyfin sin URL manual, hace falta multicast — lo que requiere `network_mode: host`:

```yaml
services:
  jellyfin:
    network_mode: host
    # ELIMINAR el bloque `networks:` y `services.networks: [homelab]`.
    # Caddy ya no llega por DNS Docker; debería apuntar a 127.0.0.1:8096
    # en el Caddyfile (NO funcionará sin más cambios — cuidado).
    ports:
      - "1900:1900/udp"     # DLNA discovery
      - "7359:7359/udp"     # Jellyfin client discovery
      - "8096:8096"         # HTTP (queda expuesto al host)
```

**Implicaciones**:

- El puerto 8096 queda expuesto al host (rompe la regla del homelab de "todo por Caddy"). Mitigable con `ufw deny 8096` desde fuera de loopback, pero añade cirugía.
- Caddy sigue siendo el frente HTTPS pero ya no llega por DNS Docker; usar `reverse_proxy http://host.docker.internal:8096` (Linux: `host-gateway`) o IP fija de la Pi.

> **El homelab no recomienda esta variante** — añadir el servidor manualmente en cada cliente cuesta 30 segundos por dispositivo y la URL no cambia con el tiempo.

### 12.5. NFOs y posters guardados dentro de la biblioteca

Si el operador quiere los metadatos junto al fichero (compatibilidad con Kodi standalone, portabilidad a otro server):

1. Quitar `:ro` del bind mount de `movies/` y `tv/`:

   ```yaml
   - /mnt/hd2t/media/movies:/media/movies
   - /mnt/hd2t/media/tv:/media/tv
   ```

2. **Dashboard > Libraries > <library> > Save metadata into media folders**: **ACTIVAR**.

3. Re-scan: Jellyfin escribe `<film>.nfo` y `<film>-poster.jpg` junto a cada fichero.

**Coste**: pierde la barrera "Jellyfin no puede escribir en bibliotecas". Aumenta la presión de I/O (cada poster de 200 KB se escribe en `hd2t/media/`).

### 12.6. Plugin "Skip Intro Detection"

Detecta openings/endings en series y ofrece botón "Skip" en clientes compatibles (web, Android, Roku, Apple TV). Usa `chromaprint` (huellas acústicas) que ya viene en `jellyfin-ffmpeg`.

```
Dashboard > Plugins > Catalog > "Intro Skipper" > Install > Restart.
Dashboard > Plugins > Intro Skipper > "Settings" > marcar las bibliotecas (Series).
Dashboard > Scheduled Tasks > "Detect Intros" > Run.
```

**Coste**: ~10 min por temporada de 10 episodios en una Pi 5. Programar de noche (Schedule: `Daily, 02:00`).

### 12.7. PostgreSQL en lugar de SQLite (no soportado)

Jellyfin **no soporta** PostgreSQL ni MariaDB como backend (issue #2247 abierto en GitHub desde 2020). El homelab no contempla esta variante.

---

## Referencias

- **Documentación oficial**: https://jellyfin.org/docs/
- **Imagen Docker**: https://hub.docker.com/r/jellyfin/jellyfin
- **Release notes**: https://jellyfin.org/posts/ (filtrar por "release")
- **Hardware acceleration matrix**: https://jellyfin.org/docs/general/administration/hardware-acceleration/
- **Plugins oficiales (catálogo)**: https://github.com/jellyfin/jellyfin-meta/discussions/30
- **Foro de la comunidad**: https://forum.jellyfin.org/
- **Subreddit**: https://www.reddit.com/r/jellyfin/
- **Estado del soporte ARM64 + Pi 5**: https://github.com/jellyfin/jellyfin/issues?q=raspberry+pi+5

**Documentos del homelab relacionados**:

- [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) — UID/GID, layout de `/mnt/hd2t/media/`.
- [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) — convenciones de `docker-compose.yml`, red `homelab`, `PGID=1100`.
- [`../03-red/02-pihole.md`](../03-red/02-pihole.md) — DNS local `jellyfin.lan`.
- [`../03-red/04-caddy.md`](../03-red/04-caddy.md) — reverse proxy, snippets `lan_internal_tls`, `security_headers`, `tailscale_tls`.
- [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) — acceso remoto sin port forwarding.
- [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) — SSO/2FA opcional (no recomendado para Jellyfin, §12.3).
- [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) — jail opt-in para Jellyfin.
- [`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md) — agrupación de logs por `dev.dozzle.group: "media"`.
- [`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md) — share `[media]`, conviven con Jellyfin sobre el mismo árbol.
- [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) — política 3-2-1.
- [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6 — exclusiones específicas de Jellyfin (`cache`, `transcodes`, `metadata/library`).
- [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) — patrón general de backup de bind mounts.
- [`../10-descargas/03-sonarr.md`](../10-descargas/03-sonarr.md) — alimenta `/mnt/hd2t/media/tv/`.
- [`../10-descargas/04-radarr.md`](../10-descargas/04-radarr.md) — alimenta `/mnt/hd2t/media/movies/`.
