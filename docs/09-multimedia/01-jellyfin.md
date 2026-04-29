# Jellyfin

## Descripción

Cerradas las Fases 0–8, el homelab tiene sistema base, Docker, red local resuelta por Pi-hole, reverse proxy con TLS interno (Caddy), VPN mesh (Tailscale), SSO opcional (Authelia), monitorización (Prometheus + Grafana), almacenamiento personal (Nextcloud + Samba + Syncthing + MinIO), copias de seguridad (Borgmatic) y domótica (Home Assistant + Mosquitto + Zigbee2MQTT + Node-RED). Lo que falta —y es la motivación de la Fase 9— es **transformar el catálogo de ficheros multimedia que vive en `/mnt/hd2t/media/` en una experiencia de salón**: poner play en una smart TV, en el móvil tirado en el sofá o en un Chromecast, y olvidarse de qué carpeta y qué reproductor abrir.

Este documento despliega **Jellyfin** (en adelante, JF), el servidor multimedia del homelab. Su rol concreto:

1. **Catalogar y servir vídeo y música**: recorre `/mnt/hd2t/media/movies/`, `/mnt/hd2t/media/tv/`, `/mnt/hd2t/media/music/` y `/mnt/hd2t/media/photos/`, descarga metadatos (título, sinopsis, carátula, año, géneros, intérpretes) desde TMDb, TheTVDB, MusicBrainz y Fanart.tv y construye una UI navegable por web y por las apps oficiales.
2. **Reproducir en cualquier cliente**: navegador (LAN/tailnet), apps oficiales (Android, Android TV, iOS, Apple TV, LG webOS, Samsung Tizen, Roku, Kodi), Chromecast, DLNA. La política por defecto del homelab favorece **Direct Play** (el cliente decodifica el fichero original) sobre **transcoding** (la Pi 5 reescribe el fichero en otro formato): los TVs modernos hacen H.264 y HEVC nativos sin pestañear, y la Pi 5 *puede* transcodificar pero no debe ser su trabajo principal.
3. **Sincronizar el progreso de reproducción** entre clientes: empezar una serie en el TV del salón y continuarla en el móvil sin perder el minuto.
4. **Cubrir el papel de "Plex" en el homelab** sin Plex: software libre, sin telemetría, sin cuenta en la nube, sin pasarelas externas.

Lo que este documento **no** decide:

- **Música**: Jellyfin reproduce música, pero el homelab incluye **Navidrome** (`02-navidrome.md`) específicamente para audio porque hablan el dialecto Subsonic que muchos clientes (DSub, Symfonium, play:Sub, Substreamer) consumen mejor que el cliente nativo de JF. JF *también* indexará `/mnt/hd2t/media/music/` en este documento como respaldo y para reproducción ocasional desde la web; el cliente principal de música queda en Navidrome.
- **Audiolibros y podcasts**: aunque JF tiene "audiobooks" como tipo de biblioteca, el homelab usa **Audiobookshelf** (`03-audiobookshelf.md`) para esto (mejor seguimiento de progreso por capítulo, sincronización de bookmarks, soporte nativo de podcasts). En JF **no** se monta `/mnt/hd2t/media/audiobooks/`.
- **Ebooks**: ídem. **Calibre-Web** (`04-calibre-web.md`) gestiona `/mnt/hd2t/media/ebooks/`.
- **Catálogo "adulto" / multimedia especializado de Stash**: vive en `/mnt/hd5t/stash/`, lo gestiona **Stash** (`05-stash.md`). JF **no** monta `/mnt/hd5t/`.
- **Live TV, DVR, IPTV (xTeVe/threadfin/tvheadend)**: requiere capturadoras hardware o suscripción IPTV; reabrible si se compra una y se identifica un caso de uso.
- **Detección de intros, créditos, bumpers** vía plugins (`Skip Intro Plus`, `Chapter Marker`): se documenta la activación nominal; el procesamiento es pesado en CPU y se programa fuera de horas de uso.
- **Descarga automatizada (`*arr` stack)**: Sonarr, Radarr, Prowlarr, Transmission viven en la **Fase 10** (`docs/10-descargas/`). JF se despliega aquí *consumiendo* `/mnt/hd2t/media/`; quién y cómo escribe ahí es problema de Fase 10.
- **HDR tone-mapping en hardware en Pi 5**: ver decisión específica abajo. El soporte v4l2-request del SoC BCM2712 lo permite en versiones recientes de Jellyfin (10.9+) pero con limitaciones; la política por defecto es **Direct Play** y mantener el HDR original.
- **Authelia delante de Jellyfin**: se descarta por las mismas razones que Home Assistant (clientes nativos, Chromecast, WebSockets, DLNA). JF mantiene su autenticación nativa.

Cuando este documento se haya aplicado, el operador puede:

- Abrir `https://jellyfin.${DOMAIN_LAN}/` desde la LAN (con CA interna instalada) o `https://jellyfin.${DOMAIN_TS}/` desde el tailnet y completar el wizard inicial.
- Crear el usuario admin y los usuarios del hogar.
- Tener al menos tres bibliotecas activas: **Películas** (`/media/movies`), **Series** (`/media/tv`) y **Música** (`/media/music`), todas con metadatos descargados.
- Reproducir desde el navegador (Chrome/Firefox), una app oficial de móvil y un Chromecast / Android TV sin warnings de "transcoding fallido" ni "buffering".
- Confirmar que el contenido reside en `/mnt/hd2t/media/`, que la configuración persistente vive en `/mnt/hd2t/apps/jellyfin/config` y que un `docker compose down && up -d` no pierde nada (estado, vistos, listas de favoritos).
- Tener la base lista para que `02-navidrome.md`–`05-stash.md` y la **Fase 10** añadan servicios sin tocar este stack.

> **Recordatorio de alcance**: JF es **solo LAN + tailnet**. Las apps oficiales se conectan vía Tailscale cuando el cliente está fuera de casa; nada de DDNS, ni Jellyfin remote access cloud, ni puertos abiertos en el router. El **Chromecast** funciona dentro de la LAN porque comparte broadcast group con el cliente (móvil o tablet) que lanza la reproducción; fuera de casa no se castea, se reproduce localmente en el móvil sobre tailnet.

---

## Requisitos Previos

- **Fase 1** completa (sistema base, hostname `pi5`, zona horaria `Europe/Madrid`, locale, swap en hd2t, **grupo `media` con GID 1100** y `homelab` miembro de él, ver `01-sistema/04-estructura-directorios.md`).
- **Fase 2** completa (Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `DOMAIN_LAN=lan`, `DOMAIN_TS` si aplica).
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre `jellyfin.${DOMAIN_LAN}` automáticamente).
  - Caddy desplegado y los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` en `Caddyfile`.
  - Tailscale operativo y, si se quiere acceso por `jellyfin.${DOMAIN_TS}`, `tailscale cert` ya emitiendo (`03-red/05-tailscale.md`).
- **Fase 4** completa: Authelia desplegado (aunque JF **no se protege con `forward_auth`**, Authelia sigue activa para el resto del homelab y JF queda añadido al *bypass*; las reglas concretas se incluyen abajo).
- **Fase 7** opcional pero recomendable: Borgmatic operativo, para añadir `/mnt/hd2t/apps/jellyfin/config` al inventario de fuentes (la biblioteca multimedia se **excluye** explícitamente del backup, ver "Backup").
- Disco `hd2t` montado en `/mnt/hd2t` con espacio suficiente para la biblioteca (variable, normalmente decenas o cientos de GiB) y al menos **20 GiB libres reservados** para metadatos, miniaturas y caché de transcoding (`config` ~1–5 GiB, `cache` ~1–20 GiB según uso).
- Operador con la **CA interna instalada** en navegador y, si se va a usar la app móvil, en el dispositivo (Android: certificado de usuario; iOS: perfil de configuración; Android TV/Apple TV: ver troubleshooting, allí la CA local es ingrata y muchas veces se opta por HTTP plano dentro de la LAN o por Tailscale con `tailscale cert`).
- Estructura de directorios `/mnt/hd2t/media/{movies,tv,music,photos}` ya creada por `01-sistema/04-estructura-directorios.md` con owner `homelab:media`, modo `2770` (setgid).

Comprobaciones rápidas:

```bash
# La red Docker compartida existe y Caddy está sano
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok
docker ps --filter name=caddy --format '{{.Names}} {{.Status}}'
# caddy   Up 5 days (healthy)

# jellyfin.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short jellyfin.lan @192.168.1.2
# 192.168.1.10

# Estructura media/ correcta y operador con permisos
getent group media
# media:x:1100:homelab
stat -c '%a %U:%G' /mnt/hd2t/media /mnt/hd2t/media/movies
# 2750 homelab:media
# 2770 homelab:media

# Espacio en hd2t
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'
# 1.5T libres

# Hardware de aceleración disponible (Pi 5: VideoCore VII)
ls -l /dev/video1[0-9] /dev/dri 2>/dev/null
# crw-rw---- root:video /dev/video10
# crw-rw---- root:video /dev/video11
# crw-rw---- root:video /dev/video12
# /dev/dri:  card1  renderD128
```

> **Sobre el grupo `video`**: las imágenes LinuxServer.io añaden el contenedor al grupo `video` del host *si* se le pasa `group_add: ["video"]` (GID variable según distribución; en Raspberry Pi OS suele ser `44`). Sin esto, el contenedor no abre `/dev/video10`–`/dev/video12` aunque estén montados. Se aplica abajo.

---

## Decisión: variante de imagen — LinuxServer.io vs oficial

Jellyfin se publica en dos imágenes principales:

| Imagen | Mantenedor | Tag de referencia | Pros | Contras |
|---|---|---|---|---|
| `jellyfin/jellyfin` | Equipo upstream de Jellyfin | `:10.9.11` (multi-arch amd64/arm64) | Es la imagen "oficial". Cambios de comportamiento llegan antes. | UID/GID fijos a `1000:1000` sin posibilidad de cambiar (ok aquí), pero **no incluye** los grupos auxiliares `video`/`render` por defecto: hay que añadirlos explícitamente. ffmpeg incluido es el `jellyfin-ffmpeg` correcto. |
| `lscr.io/linuxserver/jellyfin` | LinuxServer.io | `:10.9.11` (multi-arch incluyendo arm64) | UID/GID configurables (`PUID`/`PGID`), patrón homogéneo con el resto de `*arr`/Audiobookshelf/Calibre-Web del homelab, soporta `group_add` para `video`/`render` cómodamente, scripts de inicio ajustan permisos al arrancar. | Una capa más entre upstream y el operador (s6-overlay, scripts LSIO). Las versiones llegan con 1–3 días de desfase. |

**Decisión**: `lscr.io/linuxserver/jellyfin:10.9.11`.

Razones:

- **Coherencia con Fase 9 entera**: Audiobookshelf (`03-audiobookshelf.md`), Calibre-Web (`04-calibre-web.md`) y Stash (`05-stash.md`), así como Sonarr/Radarr/Prowlarr/Transmission de la Fase 10, son todas **LSIO**. Tener todas las imágenes multimedia con la misma forma (PUID/PGID/UMASK, mismas variables, mismo modelo de timezone, mismo arranque) es un alivio operativo enorme.
- **Permisos**: el grupo `media` (GID 1100) creado en `01-sistema/04-estructura-directorios.md` se inyecta al contenedor con `group_add: ["1100"]` directamente. Con la imagen oficial habría que recompilarla o pelear con `getent group` desde dentro.
- **Acceso a `/dev/video10–12`** y `/dev/dri/renderD128`: LSIO acepta `group_add: ["video"]` y resuelve el GID dinámicamente; con la oficial hay que pasarlo numérico (`group_add: ["44"]`) y eso varía por distro.
- **Política de tags**: pin a una versión completa (`10.9.11`), no a `latest` ni a `10.9` (que se mueve dentro del minor con bumps de patch que deberían ser benignos pero no siempre lo son).

Actualizaciones: `docker compose pull && up -d`. Watchtower etiquetará el contenedor como `homelab.role: "media-server"` y, **dado que el tag es completo**, no hará pull automático: las versiones se suben deliberadamente leyendo release notes (Jellyfin a veces deprecate plugins o cambia rutas API).

> **Por qué no `:latest`**: cada release menor de Jellyfin (10.8 → 10.9, 10.9 → 10.10) ha traído al menos un cambio de configuración o de plugin que requirió revisión manual. Pin estricto evita sorpresas de madrugada cuando Watchtower decide actualizar.

---

## Decisión: networking — bridge `homelab` (no `host`, no macvlan)

Jellyfin podría desplegarse en tres modos:

| Modo | Cómo se ve | Pros | Contras | Veredicto |
|---|---|---|---|---|
| **Bridge `homelab`** (sin `ports:`) | JF en `172.30.10.X`, accesible solo dentro del bridge. Caddy hace `reverse_proxy http://jellyfin:8096`. | Limpio, encaja con el patrón del homelab. Sin colisiones de puertos. | Sin descubrimiento DLNA: el contenedor no recibe multicast del LAN. Chromecast desde el navegador (LAN del cliente) sigue funcionando porque el cast nace en el cliente, no en JF. | **Aceptado**. |
| **`network_mode: host`** | JF comparte la pila de red de la Pi: `:8096`/`:8920` quedan en `192.168.1.10`. mDNS, DLNA, autodiscovery funcionan. | DLNA y Chromecast Audio si se quiere. | Rompe la convención del bridge, complica `Caddyfile` (`host.docker.internal`), expone los puertos directamente al host (firewall debe cubrirlos). El beneficio extra (DLNA) es marginal: la mayoría de clientes hoy son apps + Chromecast; DLNA es legacy. | Descartado. |
| **Macvlan dedicada** | JF con su propia IP en LAN (`192.168.1.20`). | DLNA y multicast plenos. | Una IP más al plan de DNS local, complica Caddyfile, exige reservar otro slot en el router. Sobreingeniería. | Descartado. |

Resultado: **bridge `homelab`**. Implicaciones:

1. **Sin `ports:`** publicados al host: el `:8096/tcp` y `:8920/tcp` quedan **solo** dentro del bridge. Si el operador quiere lanzar el cliente nativo de Kodi o LG webOS apuntando a `192.168.1.10:8096` directamente (saltándose Caddy), tiene dos opciones: añadir `ports: ["8096:8096"]` (no recomendado: evita HTTPS) o usar `https://jellyfin.lan` (recomendado, todos los clientes modernos lo soportan).
2. **Caddy** llega a JF con `reverse_proxy http://jellyfin:8096` resolviendo el nombre vía DNS interno del bridge. WebSockets (`/socket`, transmisión de eventos en tiempo real) funcionan automáticamente con Caddy v2 sin configuración extra.
3. **Chromecast desde el cliente web**: se inicia en el navegador (Chrome) corriendo en la LAN. El navegador hace el cast directamente al Chromecast pasando la URL `https://jellyfin.lan/Items/<id>/Download...`. Si el Chromecast no tiene la CA interna instalada (no se puede), la URL **debe** ser HTTP plano o el Chromecast la rechazará. **Decisión**: para casteo se publica adicionalmente un endpoint HTTP plano `:8096` solo al **bridge** y se enruta por Caddy en HTTP en una variante alternativa (ver "Casting con Chromecast", sección de Configuración).
4. **DLNA**: desactivado por defecto en JF y no se intenta hacer funcionar. Reabrible cambiando a `network_mode: host`; documentado solo como nota.
5. **Otros contenedores** que necesiten hablar con JF (p. ej. Jellyseerr en una Fase futura) usan `http://jellyfin:8096` directamente desde el bridge.

---

## Decisión: transcodificación por hardware en Pi 5 (limitaciones ARM)

La Raspberry Pi 5 lleva el SoC **Broadcom BCM2712** con la GPU **VideoCore VII**. Sus capacidades multimedia relevantes:

| Capacidad | Pi 4 | Pi 5 | Notas |
|---|---|---|---|
| Decodificación H.264 | Hardware | Hardware (v4l2-request) | Hasta 1080p60. |
| Decodificación HEVC (H.265) | Hardware (4K30 8-bit) | Hardware (4K60 8-bit, 4K30 10-bit con stride limit) | Mejorado pero con caveats: streams `Main10` con cabeceras peculiares fallan. |
| Decodificación AV1 | No | **No (decodificador AV1 no presente en VideoCore VII)** | AV1 se decodifica en **software** (CPU). 4K AV1 es **inviable** en Pi 5. |
| Decodificación VC1, MPEG2, MPEG4 | Parcial | No | Software. Películas viejas en MPEG2 (DVD rip) van por CPU; tolerable. |
| Codificación H.264 | Hardware (limitada) | **Hardware sí, pero**: el encoder v4l2 de Pi 5 está disponible pero es de calidad inferior al SW (x264 medium); recomendado **solo** cuando se necesita transcodificar tiempo real, no para preprocesado offline. |
| Codificación HEVC, AV1 | No | No | Software o nada. |
| Tone-mapping HDR→SDR en hardware | No | **Parcial** vía `v4l2_request` y EGL; en JF 10.9 hay soporte experimental. Estable solo para HEVC 10-bit BT.2020 → H.264 BT.709. | Para Dolby Vision: **no soportado** en hardware; tone-map en CPU (~25% en 1080p, ~80% en 4K → cuello). |

Implicaciones para el homelab:

1. **Política de bibliotecas: Direct Play en lo posible**. Mantener fuentes en H.264 1080p o HEVC 1080p 8-bit para que cualquier TV moderno reproduzca sin reescritura. 4K HEVC 10-bit casi siempre direct-plays en TVs ≥2018; 4K AV1 no direct-plays en gran parte del parque de TVs y la Pi **no puede** decodificar para transcodificarlo. Recomendación: los `*arr` (Fase 10) descargan `1080p HEVC 8-bit` por defecto.
2. **Activar HW decode** para H.264 y HEVC (vía v4l2-request). Está soportado por `jellyfin-ffmpeg7` que LSIO incluye. Se activa en Settings → Playback → Transcoding tras el wizard.
3. **Activar HW encode H.264** solo si el catálogo tiene fuentes que rara vez direct-playan. El encoder v4l2 de Pi 5 produce ficheros aceptables para visión, no para guardado. Para móviles con conexión limitada se puede activar a 720p.
4. **Tone-mapping**: dejar en software (`auto`/`opencl` no aplica, `vulkan` tampoco — la Pi no tiene driver Vulkan completo para ello). Si el cliente es un TV HDR-capaz, JF hace **passthrough HDR** y el TV se encarga (Direct Play); el tone-mapping solo entra cuando el cliente no soporta HDR (móvil viejo, navegador), y ahí se acepta el coste de CPU.
5. **Concurrencia**: la Pi 5 con cuatro Cortex-A76 a 2.4 GHz puede transcodificar **un** stream 1080p H.264→H.264 en software, **dos** con HW. Más simultáneos = buffering. Política: **un stream concurrente** en nuestra unidad familiar; si se necesitan dos, planificar Direct Play estricto en uno.

> **AV1**: si los `*arr` de Fase 10 empiezan a meter AV1 en la biblioteca por buscar mejor compresión, los TVs antiguos pedirán transcoding a H.264 que la Pi no puede entregar. **Política**: vetar AV1 en los perfiles de calidad de Sonarr/Radarr hasta que el parque de TVs domésticos sea AV1-capaz.

> **Dolby Vision** (DV): muchos rips en 4K traen capa DV (Profile 5/7/8). Reproducción correcta en TV LG/Sony/Samsung con DV requiere passthrough. JF **no preserva la capa DV** durante transcoding; se pierde y queda HDR10. Política: catalogar fuentes DV solo si el TV es DV-capaz y se puede Direct Play; si no, aceptar la conversión a HDR10 o filtrar DV en los perfiles de calidad.

Configuración aplicada en `docker-compose.yml`:

```yaml
devices:
  - /dev/dri:/dev/dri          # render node (V3D, EGL)
  - /dev/video10:/dev/video10  # encoder H.264
  - /dev/video11:/dev/video11  # decoder
  - /dev/video12:/dev/video12  # ISP / scaler
group_add:
  - "44"    # video (GID típico en Raspberry Pi OS)
  - "104"   # render (GID típico en Raspberry Pi OS para /dev/dri/renderD128)
  - "1100"  # media (acceso a /mnt/hd2t/media/)
```

> **GIDs `44` y `104`**: confirmar con `getent group video render` antes de aplicar; en algunas versiones de Raspberry Pi OS son `44`/`105`. Si no coinciden, ajustar el `group_add` y reiniciar.

---

## Decisión: dónde viven los datos y permisos

Tres tipos de datos:

| Tipo | Dónde | Owner:Group | Modo | Observaciones |
|---|---|---|---|---|
| **Configuración + estado** (`config/`): BBDD SQLite de la biblioteca, ajustes de usuarios, plugins, metadatos descargados, miniaturas. | `/mnt/hd2t/apps/jellyfin/config/` | `homelab:homelab` (`1000:1000`) | `0750` | LSIO escribe como `PUID:PGID`. La BBDD `library.db` es el "alma" de JF: contiene el catálogo y los marcadores de visto. Crítico para backup. |
| **Caché transcoding + logs activos** (`cache/`): segmentos HLS, ffmpeg temp, miniaturas escaladas, lo que JF llama `transcodes` + `metadata cache`. | `/mnt/hd2t/apps/jellyfin/cache/` | `homelab:homelab` | `0750` | **Excluido del backup**: regenerable, pesado en IOPS. Considerable para tmpfs si el catálogo es grande (ver más abajo). |
| **Biblioteca multimedia** (`/media/...`): los ficheros reales de vídeo y música. | `/mnt/hd2t/media/{movies,tv,music,photos}/` | `homelab:media` (`1000:1100`) | `2770` (setgid) | Compartido con Audiobookshelf, Calibre-Web, Navidrome, los `*arr`. JF lo monta **read-only** (`:ro`): no escribe nunca en la biblioteca. |

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| Volumen Docker nombrado para `config/` | Menos pelea con permisos. | Datos en `/var/lib/docker/volumes/...` (microSD). 5 GiB de metadatos en microSD = inaceptable. | Descartado. |
| Bind mount con `PUID=0` (`root`) | Compatibilidad con hipotéticos `chown` internos. | Innecesario; LSIO está pensado para `PUID=1000`. | Descartado. |
| **Bind mount `homelab:homelab` con `PUID=1000, PGID=1000` y `group_add: [1100]`** | UI legible, ACLs simples, la biblioteca queda accesible de lectura sin convertir a JF en propietario. | Ninguno relevante. | **Aceptado**. |
| Caché en tmpfs (`/dev/shm`) | IOPS infinitas, no desgasta hd2t, no se respalda implícitamente. | Limitado por RAM (Pi 5: 8 GiB compartidos con todo). Tras reinicio se pierde y debe regenerarse. | Reabrible si el caché crece a >5 GiB y el resto de servicios tolera 1–2 GiB menos de RAM. Por defecto: caché en `hd2t`. |

Resultado: bind mounts a `/mnt/hd2t/apps/jellyfin/{config,cache}` con `PUID=1000, PGID=1000`, `group_add: [44, 104, 1100]` para acceso a vídeo/render/media. Biblioteca montada **read-only**.

> **Por qué `:ro` en `/media`**: JF no necesita escritura para hacer su trabajo (la BBDD vive en `config/`, las miniaturas en `cache/`, los ficheros `.nfo` y carátulas locales no se generan por JF salvo si el operador activa "Save artwork into media folders" — desactivado por defecto). Montar `:ro` es defensa en profundidad: ningún plugin malicioso ni bug puede borrar la biblioteca.

> **`UMASK=022`**: heredado del `.env` global. Los pocos ficheros que JF escriba (logs, snapshots de plugins) quedan `0644`/`0755`. La política `2770` setgid de `/media/` no aplica porque JF no escribe ahí.

---

## Decisión: autenticación — JF nativa, **no** Authelia

Jellyfin tiene su propio sistema de autenticación con cuentas locales, contraseñas, **claves Quick Connect** y soporte (vía plugins) para LDAP/SSO. Meterlo detrás del `forward_auth` de Authelia es técnicamente posible **pero contraindicado**, por razones idénticas a las de Home Assistant:

| Razón | Impacto |
|---|---|
| **Apps oficiales** (Android, iOS, Apple TV, Android TV, LG webOS, Samsung Tizen) | Ninguna de estas apps soporta el flujo cookie-based de Authelia. Login se hace dentro de la app contra `/Users/AuthenticateByName`. Authelia interceptaría el handshake. |
| **Quick Connect** | Flujo de "abre la web, mete el código, autoriza el TV". Authelia rompe la página `/quickconnect/login`. |
| **Reproducción directa via URL** (`/Videos/<id>/stream`) | Las URLs autenticadas con `?api_key=...` no llevan cookie de Authelia; el stream cae. |
| **Chromecast desde el navegador** | El cast envía URL+token al Chromecast; Authelia bloquea cualquier petición sin cookie. |
| **Plugins de subtítulos, metadatos, gestores** | Algunos hacen llamadas externas o internas que asumen autenticación basada en token API. |
| **WebSockets** (`/socket`) | Eventos de progreso de reproducción. Romperlos = no se actualiza el "minuto en el que estás" entre clientes. |

Cada exoneración deja agujeros y hace inestable el sistema. La política sana: **JF gestiona su propia autenticación**, con contraseñas fuertes, **cuentas separadas por usuario del hogar** (un usuario por persona, sin compartir admin), `Allow remote connections` desactivado para usuarios infantiles, y opcionalmente el plugin **LDAP Authentication** apuntando al servidor LDAP que algún día se monte (no en esta Fase).

Compensaciones:

- JF **no** sale de la LAN/tailnet. Quien quiera atacar el endpoint de login necesita ya estar dentro.
- El log de accesos (`http://.../web/index.html#!/dashboard.html` → "Activity Log") deja trazabilidad.
- Tras N intentos fallidos JF aplica un lockout temporal nativo (configurable en Settings → Users → Default).
- `fail2ban` (Fase 4) puede añadir un jail para `JellyfinSecurity` parseando el log si se ven ataques de fuerza bruta. Reabrible.

Reflejo en Caddy: el `Caddyfile` para JF importa **solo** `lan_tls`, `security_headers` y `healthcheck`; **no** `authelia_two_factor`. Y en la configuración de Authelia, `jellyfin.${DOMAIN_LAN}` queda en `bypass`:

```yaml
# stacks/authelia/configuration.yml — extracto
access_control:
  default_policy: deny
  rules:
    # ... reglas existentes ...
    - domain: "jellyfin.{$DOMAIN_LAN}"
      policy: bypass
    - domain: "jellyfin.{$DOMAIN_TS}"
      policy: bypass
```

> **Si un día se quiere SSO real**: el plugin oficial **LDAP Authentication** (`Jellyfin.Plugin.LDAP-Auth`) se conecta a un servidor LDAP/AD; con Authelia 4.38+ haciendo de OIDC + LLDAP como backend de directorio, se puede federar. Reabrible cuando el homelab tenga LDAP.

---

## Stack: `stacks/jellyfin/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/jellyfin/docker-compose.yml` | microSD (git) | Stack (servicio `jellyfin`). |
| `stacks/jellyfin/.env.example` | microSD (git) | Plantilla específica del stack (vacía: hereda del `.env` global). |
| `stacks/caddy/conf.d/09-jellyfin.caddy` | microSD (git) | Drop-in del bloque LAN+tailnet para `jellyfin.${DOMAIN_LAN}` y `jellyfin.${DOMAIN_TS}`. |
| `stacks/authelia/conf.d/09-jellyfin-bypass.yml` | microSD (git) | Fragmento de access_control para añadir bypass de `jellyfin.*`. |
| `/mnt/hd2t/apps/jellyfin/config/` | hd2t | Configuración + BBDD `library.db`, plugins, metadatos. Owner `homelab:homelab`, modo `0750`. |
| `/mnt/hd2t/apps/jellyfin/cache/` | hd2t | Caché de transcoding y miniaturas. Owner `homelab:homelab`, modo `0750`. |
| `/mnt/hd2t/media/movies/` | hd2t | **Read-only** desde JF. Owner `homelab:media`, modo `2770`. |
| `/mnt/hd2t/media/tv/` | hd2t | Idem. |
| `/mnt/hd2t/media/music/` | hd2t | Idem. Compartido con Navidrome (`02-navidrome.md`). |
| `/mnt/hd2t/media/photos/` | hd2t | Idem (opcional, biblioteca tipo "Home Videos & Photos"). |

### `stacks/jellyfin/docker-compose.yml`

```yaml
# Jellyfin — servidor multimedia del homelab.
# Documentado en docs/09-multimedia/01-jellyfin.md.
#
# Networking: bridge homelab. Caddy hace reverse proxy hacia jellyfin:8096.
# Hardware acceleration: Pi 5 v4l2-request (H.264/HEVC). Activar en UI tras wizard.

name: jellyfin

networks:
  homelab:
    external: true

services:
  jellyfin:
    image: lscr.io/linuxserver/jellyfin:10.9.11
    container_name: jellyfin
    hostname: jellyfin
    restart: unless-stopped

    networks:
      - homelab

    # NO se publican puertos al host: el acceso humano va por Caddy
    # (https://jellyfin.lan). Si se quiere acceso directo p. ej. desde
    # Kodi en LAN sin pasar por HTTPS, descomentar y añadir:
    # ports:
    #   - "8096:8096"   # HTTP plano (no recomendado si hay alternativa HTTPS)

    environment:
      TZ: ${TZ}
      PUID: ${PUID}        # 1000 (homelab)
      PGID: ${PGID}        # 1000 (homelab)
      UMASK: "022"
      # JELLYFIN_PublishedServerUrl ayuda a apps cliente a "saber" la URL
      # canónica para reescribir URLs en respuestas (Chromecast, DLNA si se
      # activase). Apunta al dominio LAN: dentro del tailnet, tailscale cert
      # cubre el otro dominio y el cliente reusa la propia URL del navegador.
      JELLYFIN_PublishedServerUrl: "https://jellyfin.${DOMAIN_LAN}"

    # Acceso al hardware del SoC para HW transcoding.
    devices:
      - /dev/dri:/dev/dri          # render node (V3D, EGL)
      - /dev/video10:/dev/video10  # H.264 encoder (v4l2_m2m)
      - /dev/video11:/dev/video11  # decoder
      - /dev/video12:/dev/video12  # ISP/scaler

    # Grupos suplementarios para abrir los devices anteriores y para leer
    # /mnt/hd2t/media/. Confirmar GIDs reales en el host con
    #   getent group video render media
    # antes del primer up; ajustar si difieren.
    group_add:
      - "44"     # video    (Raspberry Pi OS: 44)
      - "104"    # render   (Raspberry Pi OS: 104; en algunas builds: 105)
      - "1100"   # media    (creado en 01-sistema/04-estructura-directorios.md)

    volumes:
      - /mnt/hd2t/apps/jellyfin/config:/config
      - /mnt/hd2t/apps/jellyfin/cache:/cache
      # Bibliotecas: read-only por política (JF no necesita escribir aquí).
      - /mnt/hd2t/media/movies:/media/movies:ro
      - /mnt/hd2t/media/tv:/media/tv:ro
      - /mnt/hd2t/media/music:/media/music:ro
      - /mnt/hd2t/media/photos:/media/photos:ro
      # /mnt/hd2t/media/audiobooks NO se monta: se gestiona en Audiobookshelf.
      # /mnt/hd2t/media/ebooks NO se monta: se gestiona en Calibre-Web.
      # /mnt/hd5t NO se monta: pertenece exclusivamente a Stash.
      - /etc/localtime:/etc/localtime:ro

    healthcheck:
      # /health responde 200 con "Healthy" cuando JF tiene la BBDD abierta.
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8096/health"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 120s   # primer arranque crea schemas SQLite, ~60–90s

    labels:
      homelab.role: "media-server"
      homelab.backup: "true"
      # Watchtower NO actualiza automáticamente: el tag es completo (10.9.11)
      # y los bumps de minor de JF requieren leer release notes. Para activar
      # cambiar a un tag flotante (no recomendado) o lanzar el update a mano.
      com.centurylinklabs.watchtower.enable: "false"
```

> **Sobre `JELLYFIN_PublishedServerUrl`**: si no se pasa, JF anuncia URLs internas (`http://172.30.10.X:8096`) en respuestas API que algunos clientes (Chromecast, DLNA) toman tal cual y luego no resuelven. Fijarlo a la URL canónica del reverse proxy es lo que recomienda la documentación oficial cuando hay reverse proxy.

> **Sobre `curl` en el healthcheck**: la imagen LSIO incluye `curl` por defecto. Si en algún momento se cambia a la imagen oficial, sustituir por `wget -q --spider`.

### `stacks/jellyfin/.env.example`

```bash
# stacks/jellyfin/.env.example
# Variables específicas del stack Jellyfin. Las generales (TZ, PUID, PGID,
# DOMAIN_LAN, DOMAIN_TS) vienen del .env GLOBAL del homelab.
#
# (Vacío en esta fase: JF se configura desde la UI; no hay secretos en
# variables de entorno.)
```

### Drop-in de Caddy: `stacks/caddy/conf.d/09-jellyfin.caddy`

```caddy
# /etc/caddy/conf.d/09-jellyfin.caddy — bloques de Jellyfin.
# Documentado en docs/09-multimedia/01-jellyfin.md.
#
# IMPORTANTE: NO se importa authelia_two_factor (decisión documentada en
# "Decisión: autenticación"). JF gestiona su propio login.

# ---- Acceso LAN ------------------------------------------------------------
jellyfin.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Streams pueden ser largos (películas, series). read_timeout amplio.
    reverse_proxy http://jellyfin:8096 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # Caddy v2 detecta y pasa WebSockets (/socket) automáticamente.

        transport http {
            read_timeout 24h     # streams largos no se cortan
            write_timeout 24h
        }
    }

    # Subir el límite de body para uploads de plugins/imágenes/subtítulos
    # (los .ass de algunos episodios largos pasan de 1 MiB).
    request_body {
        max_size 100MB
    }
}

# ---- Acceso Tailscale ------------------------------------------------------
# Solo se materializa si DOMAIN_TS está definido (tailnet con tailscale cert).
# La red tailnet trae HTTPS legítimo; no necesita la CA interna.
jellyfin.{$DOMAIN_TS} {
    tls {
        get_certificate tailscale
    }
    import security_headers
    import healthcheck

    reverse_proxy http://jellyfin:8096 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        transport http {
            read_timeout 24h
            write_timeout 24h
        }
    }

    request_body {
        max_size 100MB
    }
}
```

> **Sobre `read_timeout 24h`**: los streams HLS de JF mantienen la conexión abierta durante toda la reproducción. El default de Caddy (~30 s) no llega; durante una película de 2 h el reverse proxy cortaría y el cliente reintentaría sin contexto. 24 h cubre maratones de 10 episodios.

> **Sobre el bloque tailnet**: si `DOMAIN_TS` no está definido en el `.env` global, este bloque se ignora silenciosamente porque `jellyfin.` no resuelve a nada. Para activarlo, ver `03-red/05-tailscale.md` (`tailscale cert pi.tailnet.ts.net`) y `03-red/04-caddy.md` (configuración de `get_certificate tailscale`).

### Fragmento de Authelia: `stacks/authelia/conf.d/09-jellyfin-bypass.yml`

```yaml
# stacks/authelia/conf.d/09-jellyfin-bypass.yml
# Excluir Jellyfin del control de acceso de Authelia.
# Se incluye desde stacks/authelia/configuration.yml mediante
# `access_control.rules` con un mecanismo de merge documentado en 04-seguridad/01-authelia.md.

- domain: "jellyfin.{$DOMAIN_LAN}"
  policy: bypass
- domain: "jellyfin.{$DOMAIN_TS}"
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
[ -d /mnt/hd2t/media/movies ] || {
    echo "ERROR: /mnt/hd2t/media/* no existe. Aplicar 01-sistema/04-estructura-directorios.md."
    exit 1
}

# 2) Crear directorios persistentes del servicio (idempotente).
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/jellyfin
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/jellyfin/config
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/jellyfin/cache

# 3) Confirmar GIDs reales de video y render en este host.
getent group video render
# video:x:44:
# render:x:104:
# (Si los GIDs difieren, AJUSTAR group_add en docker-compose.yml antes de up.)

# 4) Materializar Caddy drop-in y fragmento de Authelia.
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/09-jellyfin.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/09-jellyfin.caddy

# Authelia se reconfigura con el merge documentado en su doc; aquí basta
# con dejar el fragmento en su sitio para que el siguiente reload lo recoja.
install -o homelab -g homelab -m 0644 \
    stacks/authelia/conf.d/09-jellyfin-bypass.yml \
    /mnt/hd2t/apps/authelia/etc/conf.d/09-jellyfin-bypass.yml

# 5) .env del stack (vacío en esta fase pero lo creamos para coherencia).
cp stacks/jellyfin/.env.example stacks/jellyfin/.env
chmod 0600 stacks/jellyfin/.env

# 6) Levantar el stack.
docker compose \
    -f stacks/jellyfin/docker-compose.yml \
    --env-file stacks/jellyfin/.env \
    up -d

# 7) Recargar Caddy y Authelia para tomar drop-ins.
docker exec caddy caddy validate --config /etc/caddy/Caddyfile && \
    docker kill --signal=SIGUSR1 caddy
docker exec authelia kill -HUP 1 || \
    docker compose -f stacks/authelia/docker-compose.yml restart authelia
```

Tras `up -d`:

```bash
docker ps --filter name=jellyfin
# CONTAINER ID  IMAGE                                   STATUS
# ...           lscr.io/linuxserver/jellyfin:10.9.11    Up 2 minutes (healthy)

docker logs jellyfin --tail 30
# ... [INF] Jellyfin version: 10.9.11
# ... [INF] Operating system: Linux 6.6.x #1 SMP PREEMPT_DYNAMIC aarch64
# ... [INF] Kestrel started; listening on 0.0.0.0:8096
# ... [INF] Startup complete: 47.92 seconds

# Confirmar puertos NO publicados al host (debe estar vacío)
ss -tlnp | grep -E ':809[06]' || echo "OK: jellyfin NO publica puertos al host"
# OK: jellyfin NO publica puertos al host

# Probar el endpoint vía Caddy
curl -ksI https://jellyfin.lan/health
# HTTP/2 200
# content-type: text/plain; charset=utf-8
```

---

## Configuración

### 1) Wizard inicial

Desde un cliente de la LAN con la CA interna instalada:

```text
1. Abrir https://jellyfin.lan/
2. JF muestra el wizard:
   a. Preferred display language: Spanish (España)
   b. Create your administrator account:
       - Username: admin
       - Password: gestor de contraseñas; mínimo 16 caracteres
   c. "Set up your media libraries":  -> SKIP por ahora (se hace en el paso 2).
   d. "Preferred metadata language":
       - Metadata language: Spanish (Spain)
       - Country/Region: Spain
   e. "Configure Remote Access":
       - "Allow remote connections to this server": DESACTIVAR.
         (El acceso remoto se hace por Tailscale, no por UPnP del router.)
       - "Enable automatic port mapping": DESACTIVAR.
   f. "Done".
3. Login con admin/<password>. Aparece el dashboard vacío.
```

> **Si el wizard no aparece**: ya hay configuración previa (`/mnt/hd2t/apps/jellyfin/config/data/jellyfin.db` existe). Si no es la deseada, parar el contenedor, borrar `config/` y volver a levantar. **Esto borra usuarios y biblioteca**.

### 2) Crear las bibliotecas

`Dashboard → Libraries → Add Media Library` (uno por uno):

| Library | Content Type | Folder dentro del contenedor | Display name | Notas |
|---|---|---|---|---|
| Películas | Movies | `/media/movies` | Películas | Metadata: TheMovieDb (TMDb). Imágenes: Fanart, TMDb. Subtítulos: ES, EN. |
| Series | Shows | `/media/tv` | Series | Metadata: TheTVDb + TMDb. Activar "Save artwork into media folders" **NO** (la biblioteca está `:ro`). |
| Música | Music | `/media/music` | Música | Metadata: MusicBrainz + Last.fm. Album art: MusicBrainz, Fanart. |
| Vídeos personales | Home Videos & Photos | `/media/photos` | Personal | Sin descarga de metadatos externos. Opcional. |

> **Importante**: en cada biblioteca, en "Advanced", **desactivar** "Save artwork into media folders" y "Save trickplay images into media folders". El bind mount es `:ro` y JF generaría errores de escritura cada noche durante el escaneo. Las miniaturas viven en `cache/`.

> **Por qué NO una biblioteca "Audiolibros"**: se gestiona en `03-audiobookshelf.md`. Si JF la creara, duplicaría índice y los clientes ven dos catálogos del mismo contenido.

> **Por qué NO una biblioteca "Libros"**: se gestiona en `04-calibre-web.md`.

Tras crear todas, `Dashboard → Scheduled Tasks → Scan All Libraries → Run Now`. El primer escaneo de una biblioteca razonable (1000 películas, 200 series) tarda **30–90 minutos** en una Pi 5 con `hd2t` USB 3.0; el escaneo es secuencial y depende sobre todo del rate limit de TMDb (se puede acelerar generando una API key personal en TMDb y metiéndola en `Dashboard → Plugins → TheMovieDb`).

### 3) Activar transcodificación por hardware (Pi 5)

`Dashboard → Playback → Transcoding`:

```text
- Hardware acceleration:        Video4Linux2 (V4L2)
- V4L2 Request API:             ON  (requisito en Pi 5; Pi 4 lo permite vía OpenMAX)
- Enable hardware decoding for: H264, HEVC
                                (NO marcar AV1: Pi 5 no decodifica AV1.)
                                (NO marcar VP9: Pi 5 lo decodifica pero la implementación
                                 es inestable y a menudo es mejor SW.)
- Enable hardware encoding:     ON  (solo H.264; no hay HEVC encoder)
- Enable VBR encoding:          OFF (CBR rinde mejor en v4l2_m2m)
- Enable hardware decoding for HEVC 10-bit: ON  (con caveats; ver decisiones)
- Enable Tone mapping:          OFF (CPU para casos puntuales)
- Throttle transcodes:          ON
- Transcoding temporary path:   /cache/transcodes
- Maximum concurrent transcodes: 1
```

Reiniciar JF (`docker compose -f stacks/jellyfin/docker-compose.yml restart jellyfin`) y probar:

```text
1. Reproducir desde el navegador una película H.264 1080p.
2. Click en el icono de "Reproducción" arriba a la derecha → "Información de reproducción".
3. Confirmar que dice:
     Reproducción directa     <-- IDEAL: el cliente decodifica nativamente.
   o, si el cliente fuerza transcoding:
     Transcodificando vídeo (V4L2)   <-- HW activo
4. Si dice "Transcodificando vídeo (libx264)", ffmpeg está usando software:
   revisar device permissions, group_add, y logs de jellyfin.
```

### 4) Crear usuarios del hogar

`Dashboard → Users → Add User`:

```text
- Username: <nombre del miembro>
- Password: gestor de contraseñas
- Library access: tickear las bibliotecas que puede ver
- Enable parental control: si aplica (ej. niños -> filtrar por rating)
- Allow remote connections: ON (necesario para Tailscale; "remote" significa
                                 cualquier IP que no sea localhost)
- Allow this user to manage the server: OFF (solo admin)
- Sync play: ON (si se quieren sesiones SyncPlay sincronizadas entre TVs)
```

> **Sobre la cuenta admin**: usar `admin` solo para administración. Para uso diario, crear un usuario propio sin permisos de admin. Esto evita borrados accidentales de bibliotecas.

### 5) Acceso desde clientes

| Cliente | URL (LAN) | URL (Tailscale) | Notas |
|---|---|---|---|
| Navegador (Chrome/Firefox) | `https://jellyfin.lan` | `https://jellyfin.<ts-tailnet>.ts.net` | Requiere CA interna en el dispositivo para LAN. Tailscale tiene cert legítimo. |
| Jellyfin Mobile (Android/iOS) | `https://jellyfin.lan` | `https://jellyfin.<ts-tailnet>.ts.net` | Idem. La app oficial alterna entre dos servidores guardados. |
| Jellyfin Android TV / Apple TV | `https://jellyfin.lan` o `http://192.168.1.10:<port>` (ver casteo) | `https://jellyfin.<ts-tailnet>.ts.net` | El TV no acepta CA local fácilmente. Opciones: (a) ignorar HTTPS local y publicar `:8096` por bridge, (b) instalar el cert manualmente con un sideload, (c) usar Tailscale en el TV (Apple TV soporta Tailscale; Android TV vía sideload). |
| Kodi (con plugin Jellyfin for Kodi) | `https://jellyfin.lan` (si CA instalada) o `http://...` | Idem | El plugin pinta el catálogo en la UI nativa de Kodi. |
| LG webOS / Samsung Tizen (apps oficiales) | `https://jellyfin.lan` (si CA instalada) o `http://...` | No (TVs no se conectan a Tailscale fácilmente) | Apps oficiales mantenidas por el equipo de Jellyfin. |
| Chromecast (lanzado desde móvil) | URL pasada por la app que castea | Idem | El Chromecast recibe la URL del fichero; tiene que poder resolver y aceptar el cert (ver más abajo). |

### 6) Casting con Chromecast

El Chromecast recibe del cliente la URL del stream. Si la URL es `https://jellyfin.lan/...` y el Chromecast no tiene la CA interna instalada (no se puede), **falla**. Opciones:

| Opción | Cómo | Pros | Contras |
|---|---|---|---|
| **A) Publicar `:8096` HTTP plano al host, casteo solo por LAN** | Añadir `ports: ["8096:8096"]` al `docker-compose.yml`. La app móvil castea `http://192.168.1.10:8096/...`. | Funciona out-of-the-box. | Tráfico HTTP en LAN; aceptable porque ya estás en LAN, pero pierde la regla "todo HTTPS". |
| **B) Caddy publica también en HTTP plano por un dominio dedicado** | `cast.lan` (HTTP, sin TLS) → `reverse_proxy http://jellyfin:8096`. La app móvil usa esa URL para castear. | Caddy controla el ingreso. | Configuración extra. |
| **C) Usar Cast Connect con la app oficial de JF en Chromecast con Google TV** | El Chromecast con Google TV (4ª gen) corre apps Android TV, incluyendo la oficial de JF. La app instalada en el dongle hace login HTTPS sin necesidad de pasar URLs entre dispositivos. | Sin HTTP plano. | Requiere Chromecast con Google TV (no los antiguos solo "cast"). |

Decisión por defecto en este documento: **A) cuando hay Chromecast antiguo en la red**. Si el parque es solo Chromecast con Google TV o solo TVs con app nativa, omitir el `ports:` y dejar todo HTTPS.

Si se elige A:

```yaml
# stacks/jellyfin/docker-compose.yml — DELTA si se usa Chromecast antiguo:
services:
  jellyfin:
    # ...
    ports:
      - "192.168.1.10:8096:8096"   # HTTP plano, bind solo al IP de la Pi
```

> **¿Por qué bind explícito a `192.168.1.10` y no `0.0.0.0`**: el firewall del host (Fase 1) ya filtra por interfaz, pero ser explícito en Docker evita exposición accidental por si en algún momento la Pi se conecta a otra red (ej. WiFi de invitados).

### 7) Configuración del Recorder de visualizaciones

Por defecto JF guarda histórico de visualización en su BBDD `library.db`. Decisiones aplicadas:

```text
Dashboard → Server → General:
  - "Display missing episodes within seasons": OFF (ruidoso si los *arr no traen todo)
Dashboard → Plugins → Activity Log:
  - "Mantener entradas de logs durante": 90 días
Dashboard → Server → Playback:
  - "Recordatorio de reproducción interrumpida": ON
Dashboard → Server → Network:
  - "Local network addresses": 172.30.10.0/24, 192.168.1.0/24, 100.64.0.0/10
    (incluir el bridge homelab, la LAN local y el rango de Tailscale).
  - "Allow connections from these subnets only": 172.30.10.0/24, 192.168.1.0/24, 100.64.0.0/10
  - "Known proxies": 172.30.10.X (IP del contenedor caddy en homelab; sale de
                                  docker network inspect homelab).
```

> **Por qué el rango de Tailscale (`100.64.0.0/10`)**: cuando Tailscale enruta la conexión al stream desde un dispositivo del tailnet hacia Caddy y a JF, el contenedor JF ve la conexión como originada del bridge homelab (NAT), pero el header `X-Forwarded-For` lleva la IP tailnet del cliente. Si JF no reconoce ese rango como "local network", aplica políticas de "remote" (que están más restringidas si se decide endurecerlas).

### 8) Plugins recomendados

`Dashboard → Plugins → Catalog`:

| Plugin | Para qué |
|---|---|
| **TMDb Box Sets** | Agrupa películas en colecciones (Star Wars, MCU…). Ya viene activado de serie en 10.9. |
| **Trakt** | Sincronización de visualizado con trakt.tv (opcional, requiere cuenta). Útil si el operador ya usa Trakt. |
| **Skip Intro Plus** | Detecta intros y créditos en series; muestra botón "Saltar intro" en clientes compatibles. **Pesado**: la primera ejecución sobre 200 series toma horas. Programar para horario nocturno (`Dashboard → Scheduled Tasks`). |
| **Open Subtitles** | Descarga automática de subtítulos. Requiere cuenta gratuita en opensubtitles.com (ratelimit). |
| **Subtitle Extract** | Extrae subtítulos embebidos en MKVs a ficheros `.srt`/`.ass` para acceso rápido. |

Plugins **descartados** por defecto:

- **Bookshelf**, **Audiobookshelf integration**, **Calibre integration** — los servicios dedicados los manejan mejor.
- **DLNA** — desactivado por la decisión de networking.
- **LDAP Authentication** — reabrible cuando exista LDAP.

### 9) Operación diaria

| Acción | Comando |
|---|---|
| Ver el log activo | `https://jellyfin.lan/web/index.html#!/dashboard/logs/` o `docker logs jellyfin -f` |
| Reescaneo manual de bibliotecas | UI: Dashboard → Scheduled Tasks → Scan Media Library → Run Now |
| Reiniciar JF | UI: Dashboard → General → Restart, o `docker compose -f stacks/jellyfin/docker-compose.yml restart jellyfin` |
| Backup manual del config | `sudo tar czf /mnt/hd2t/backups/jf-snapshot-$(date +%F).tgz -C /mnt/hd2t/apps/jellyfin config` |
| Tamaño actual de la BBDD | `du -sh /mnt/hd2t/apps/jellyfin/config/data/jellyfin.db` |
| Limpiar caché transcoding | UI: Dashboard → Scheduled Tasks → Clean Transcode Directory, o `rm -rf /mnt/hd2t/apps/jellyfin/cache/transcodes/*` con JF parado |
| Verificar HW transcoding activo | UI: Dashboard → Playback → ffmpeg test (botón) |

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/jellyfin/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/jellyfin/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/caddy/conf.d/09-jellyfin.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy. |
| `/home/homelab/homelab/stacks/authelia/conf.d/09-jellyfin-bypass.yml` | microSD | `homelab:homelab` | `0644` | Fragmento de bypass. |
| `/mnt/hd2t/apps/jellyfin/config/` | hd2t | `homelab:homelab` | `0750` | Configuración + BBDD + plugins. **Crítico**, se respalda. |
| `/mnt/hd2t/apps/jellyfin/config/data/jellyfin.db` | hd2t | `homelab:homelab` | `0640` | BBDD principal (catálogo, historial). |
| `/mnt/hd2t/apps/jellyfin/config/data/library.db` | hd2t | `homelab:homelab` | `0640` | Catálogo de items. |
| `/mnt/hd2t/apps/jellyfin/config/metadata/` | hd2t | `homelab:homelab` | `0750` | Metadatos descargados (NFOs internos, no en `/media`). |
| `/mnt/hd2t/apps/jellyfin/config/plugins/` | hd2t | `homelab:homelab` | `0750` | Plugins instalados. |
| `/mnt/hd2t/apps/jellyfin/config/log/` | hd2t | `homelab:homelab` | `0750` | Logs (rotados). **No se respalda**. |
| `/mnt/hd2t/apps/jellyfin/cache/` | hd2t | `homelab:homelab` | `0750` | Caché de transcoding y miniaturas. **No se respalda**. |
| `/mnt/hd2t/apps/jellyfin/cache/transcodes/` | hd2t | `homelab:homelab` | `0750` | Segmentos HLS temporales. Limpieza automática 1×día. |
| `/mnt/hd2t/media/movies/` | hd2t | `homelab:media` | `2770` | **No se respalda** (ver "Backup"). Bind mount `:ro`. |
| `/mnt/hd2t/media/tv/` | hd2t | `homelab:media` | `2770` | Idem. |
| `/mnt/hd2t/media/music/` | hd2t | `homelab:media` | `2770` | Idem. Compartido con Navidrome. |
| `/mnt/hd2t/media/photos/` | hd2t | `homelab:media` | `2770` | Idem. |

> **Tamaño esperado**. Para una casa con ~1000 películas y ~200 series, `config/` se estabiliza en torno a **1–3 GiB** (BBDD + miniaturas + metadatos). El `cache/` puede crecer hasta el límite de transcoding (`Dashboard → Playback → "Transcoding cache size"`, default sin límite); ponerlo a `5 GiB` es razonable. Las **20 GiB** reservadas son holgadas.

> **Por qué no microSD**. La BBDD de JF hace cientos de escrituras por escaneo y por reproducción. Es el típico patrón de SQLite que mata microSD a meses.

> **Sobre `metadata/`**. Contiene los NFOs internos que JF descarga de TMDb/TheTVDb. Si se borrara, JF lo regeneraría tras un escaneo (lento pero recuperable). No es crítico de respaldar, aunque se incluye porque es pequeño y evita 1–2 horas de re-escaneo.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/jellyfin/docker-compose.yml`, `.env.example` | Versionados. |
| `stacks/caddy/conf.d/09-jellyfin.caddy` | Versionado. |
| `stacks/authelia/conf.d/09-jellyfin-bypass.yml` | Versionado. |
| Decisiones (LSIO, network bridge, HW transcoding ARM, sin Authelia) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Tier (`07-backups/01-estrategia-backup.md`) | Por qué |
|---|---|---|---|
| `/mnt/hd2t/apps/jellyfin/config/data/jellyfin.db`, `library.db`, `playback_reporting.db`* | Sí. | T1 | Catálogo, usuarios, contraseñas hashed, historial de visto. **Pérdida = re-escaneo + re-marcaje manual de visto**. |
| `/mnt/hd2t/apps/jellyfin/config/users/` | Sí. | T1 | Definiciones de usuarios (políticas, parental). |
| `/mnt/hd2t/apps/jellyfin/config/plugins/` | Sí. | T2 | Plugins instalados con sus configuraciones. Reinstalables, pero conviene preservar config (claves API de TMDb, de Open Subtitles…). |
| `/mnt/hd2t/apps/jellyfin/config/metadata/` | Sí. | T3 | Regenerable por re-escaneo, pero pequeño y ahorra horas. |
| `/mnt/hd2t/apps/jellyfin/config/log/` | **No.** | T4 | Rotado, regenerable, voluminoso en pico. |
| `/mnt/hd2t/apps/jellyfin/cache/` | **No.** | T4 | Caché por definición. Regenerable. |
| `/mnt/hd2t/media/movies/`, `tv/`, `music/`, `photos/` | **No.** | T5 | **Política del homelab**: la biblioteca multimedia es **voluminosa y reconstituible** desde la fuente externa (compras, rips propios, descargas). Respaldarla en Borg multiplicaría por dos el tamaño del repo. La única salvaguarda es tener los originales (o un script que sepa volver a obtenerlos) en un soporte distinto. Documentado en `07-backups/01-estrategia-backup.md`. |

*`playback_reporting.db` aparece si se instala el plugin `Playback Reporting`; si no, no existe.

Entrada en `borgmatic.yaml` (parche relativo al patrón de `07-backups/02-borgmatic.md`):

```yaml
source_directories:
  # ...
  - /mnt/hd2t/apps/jellyfin/config

# Excluir lo regenerable
patterns:
  # ...
  - '!/mnt/hd2t/apps/jellyfin/config/log'
  - '!/mnt/hd2t/apps/jellyfin/config/cache'    # por si LSIO crea algún subdir aquí
  - '!/mnt/hd2t/apps/jellyfin/config/data/*.db.bak'

# Hooks: snapshot consistente de SQLite antes del backup
before_backup:
  - 'docker exec jellyfin sqlite3 /config/data/jellyfin.db ".backup ''/config/data/jellyfin.db.borg''"'
  - 'docker exec jellyfin sqlite3 /config/data/library.db   ".backup ''/config/data/library.db.borg''"'
after_backup:
  - 'docker exec jellyfin rm -f /config/data/jellyfin.db.borg /config/data/library.db.borg'
```

> **Política sobre las BBDD**. Igual que en HA: snapshot consistente con `.backup` de SQLite (atómico), no copia en caliente del fichero activo. Para una BBDD de ~500 MiB, el snapshot tarda 2–5 s.

> **Política sobre `/mnt/hd2t/media/`**. Excluida del backup. Si la biblioteca tiene valor irreemplazable (ej. fotos personales en `media/photos/`), **separar la carpeta** a `/mnt/hd2t/personal/photos/` (fuera del subárbol `media/`) y respaldarla específicamente. El operador es responsable de identificar qué es "biblioteca regenerable" y qué es "personal único".

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/jellyfin/docker-compose.yml up -d --force-recreate
# JF reusa /mnt/hd2t/apps/jellyfin/config: arranque normal en ~60 s,
# todas las bibliotecas, usuarios, marcadores de visto siguen ahí.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear Fases 1 → 7.
2. `borgmatic extract --archive latest --path mnt/hd2t/apps/jellyfin`.
3. Verificar permisos: `sudo chown -R homelab:homelab /mnt/hd2t/apps/jellyfin && sudo chmod 0750 /mnt/hd2t/apps/jellyfin/config`.
4. Confirmar/recrear `/mnt/hd2t/media/{movies,tv,music,photos}` (vacíos al inicio; reabsorber contenido por separado).
5. `docker compose -f stacks/jellyfin/docker-compose.yml up -d`.
6. `https://jellyfin.lan` → login con credenciales pre-existentes; las bibliotecas apuntan a paths que existen aunque estén vacíos. Cuando se vuelva a poblar `/media/...`, JF re-detecta los ficheros y la BBDD restaurada los re-asocia (los IDs internos son hashes del path, no del fichero).

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `https://jellyfin.lan` da `502 Bad Gateway` | Caddy no resuelve `jellyfin` (contenedor caído o no en la red `homelab`). | `docker ps --filter name=jellyfin`. Si está caído, `docker logs jellyfin --tail 100`. Si está vivo: `docker network inspect homelab` debe listarlo. |
| UI carga pero un vídeo no reproduce ("Error de reproducción") | Codec/contenedor no soportado por el cliente y JF no transcodifica (HW desactivado, o `cache/` lleno). | Dashboard → Playback → habilitar HW; comprobar `df -h /mnt/hd2t`; ver `docker logs jellyfin` durante la reproducción. |
| `Transcodificando vídeo (libx264)` aunque V4L2 está activo | El contenedor no tiene acceso a `/dev/video10–12` o a los grupos `video`/`render`. | `docker exec jellyfin ls -l /dev/video10`. Si falta, revisar `devices:` y `group_add:`; confirmar GIDs con `getent group video render`. |
| Logs JF: `Failed to open V4L2 device /dev/video11: Permission denied` | El usuario interno (LSIO `abc`, UID 1000) no es miembro de `video`. | Añadir GID correcto a `group_add`. Reiniciar contenedor. |
| Reproducción 4K HEVC HDR cae a CPU al tocar pausa | `/cache/transcodes` lleno: ffmpeg detiene el segment writer. | Aumentar capacidad o limpiar (`Scheduled Tasks → Clean Transcode Directory`). Considerar tmpfs para `cache/`. |
| El cliente Android dice "Servidor no encontrado" en LAN pero sí en tailnet | El móvil usa DNS distinto (CGNAT del operador) que no resuelve `jellyfin.lan`. | Forzar el móvil a usar Pi-hole (DHCP del router → Primary DNS = 192.168.1.2). O añadir `jellyfin.lan -> 192.168.1.10` en el `/etc/hosts` del móvil. |
| Chromecast: "Unable to load video" | El Chromecast no puede aceptar el cert de la CA interna. | Activar la opción A de "Casting" (publicar `:8096` HTTP plano), o usar Chromecast con Google TV con la app oficial (opción C). |
| Apple TV: "No se puede conectar al servidor" | El Apple TV no acepta la CA interna por interfaz. | Usar Tailscale en el Apple TV (compatible) → `https://jellyfin.<ts-tailnet>.ts.net` con cert legítimo. |
| Escaneo de bibliotecas se atasca al 30 % | Rate limit de TMDb (40 req/10 s sin API key, mucho más con API key personal). | Crear API key gratis en `https://www.themoviedb.org/settings/api` y meterla en `Plugins → TheMovieDb → API key`. |
| Logs JF: `Skia.SkiaSharp` o `libSkiaSharp` errores en arm64 | Conflicto entre la imagen y dependencias de imágenes en arm64 (raro hoy en 10.9.x, frecuente en 10.7). | Actualizar al tag actual `10.9.11`. Si persiste, sustituir el image processor: `Dashboard → Playback → Image extraction → ImageMagick` (más lento pero estable). |
| AV1: "Reproducción incompatible con tu dispositivo" | Pi 5 no decodifica AV1 (no hay HW), CPU no llega a 4K AV1. | Re-codificar la fuente a HEVC 8/10-bit con un PC, o filtrar AV1 en perfiles de calidad de Sonarr/Radarr (Fase 10). |
| Dolby Vision 4K cae a 480p al transcodificar | Tone-map en software a 4K es inviable. | Direct Play (TV DV-capaz, app DV-capaz) o eliminar la capa DV con `dovi_tool` antes de añadir a la biblioteca. |
| Tras `docker compose pull`, JF arranca y dice "Database upgrade failed" | El bump de minor (10.8 → 10.9) corrompió la migración (raro). | Restore la BBDD desde el snapshot Borg de la noche anterior. Reportar issue upstream. |
| `Authelia` interfiere a pesar del bypass | El fragmento `09-jellyfin-bypass.yml` no se cargó (Authelia no lo merge automáticamente; depende del mecanismo de `04-seguridad/01-authelia.md`). | `docker logs authelia | grep jellyfin`; revisar la inclusión del fragmento en `configuration.yml`; reiniciar Authelia. |
| `https://jellyfin.lan` muestra cert "no confiable" tras instalar la CA | Caddy no recargó el `Caddyfile` (drop-in nuevo). | `docker exec caddy caddy validate --config /etc/caddy/Caddyfile && docker kill --signal=SIGUSR1 caddy`. |
| Permisos: JF no ve un fichero recién depositado en `/mnt/hd2t/media/movies/` | El fichero no es del grupo `media` (lo creó otro proceso con `umask` distinto). | `sudo chgrp -R media /mnt/hd2t/media/movies && sudo chmod -R g+rX /mnt/hd2t/media/movies`. Revisar el origen (Sonarr/Radarr de Fase 10 ya escriben con `PGID=1100`, otros procesos manuales pueden no hacerlo). |

---

## Decisiones que **no** se toman en este documento

- **Authelia delante de JF**: descartado por compatibilidad con clientes nativos. Reabrible con OIDC + plugin LDAP cuando el homelab tenga LDAP.
- **Hardware más pesado** (Pi con GPU dedicada, mini-PC con Intel QuickSync): fuera del alcance del homelab, que es Pi 5 por diseño. Reabrible cuando el operador pase a x86.
- **Jellyseerr** (frontend de "pedir películas/series" para usuarios no-admin que dispara peticiones a Sonarr/Radarr): pertenece a Fase 10 cuando los `*arr` estén operativos.
- **Live TV / DVR** (HDHomeRun, IPTV, EPG): requiere hardware o servicio externo.
- **Trickplay** (preview en thumbnails al hacer scrub en la barra de tiempo): reabrible una vez la biblioteca está poblada y el operador tolera 1–2 horas de procesamiento por cada 100 películas.
- **AV1 en biblioteca**: vetado por defecto. Reabrible cuando todos los TVs domésticos sean AV1-capaces.
- **DLNA**: descartado por la decisión de networking (bridge no soporta multicast). Reabrible con `network_mode: host`.
- **Migración a Plex**: explícitamente descartada (telemetría, cuenta cloud, modelo de licencia).
- **Migración a Emby**: comparte ascendencia con Jellyfin pero modelo "Premiere" de pago. Descartada.
- **Backups del catálogo multimedia**: política deliberada de no respaldar `/mnt/hd2t/media/`. Documentada arriba.

---

## Verificación Final

Antes de pasar a `02-navidrome.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/jellyfin/docker-compose.yml ps` | `jellyfin ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect jellyfin --format '{{.Config.Image}}'` | `lscr.io/linuxserver/jellyfin:10.9.11` |
| Conectado a la red homelab y NO a host | `docker inspect jellyfin --format '{{.HostConfig.NetworkMode}}'` | `default` o `homelab` (no `host`) |
| Sin puertos publicados al host (excepto si Chromecast antiguo) | `docker port jellyfin` | salida vacía, o `8096/tcp -> 192.168.1.10:8096` si se aplicó la opción A |
| `jellyfin.lan` resuelve al IP de la Pi | `dig +short jellyfin.lan @192.168.1.2` | `192.168.1.10` |
| Caddy sirve `jellyfin.lan` con cert de la CA interna | `echo \| openssl s_client -connect jellyfin.lan:443 -servername jellyfin.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| Health endpoint responde | `curl -ksS https://jellyfin.lan/health` | `Healthy` |
| El contenedor abre `/dev/video11` | `docker exec jellyfin sh -c 'ls -l /dev/video10 /dev/video11 /dev/video12 /dev/dri'` | `crw-rw---- ... root video` para los `/dev/video1*`, `crw-rw---- ... root render` para `/dev/dri/renderD128` |
| Grupos suplementarios correctos en el contenedor | `docker exec jellyfin id abc` | `groups=...,44(video),104(render),1100(media)` |
| Login funciona desde navegador | navegador con CA instalada | UI carga el dashboard tras login |
| Bibliotecas presentes y escaneadas | UI: Dashboard → Libraries | Películas, Series, Música listadas con conteo > 0 |
| Reproducción Direct Play funciona | UI: reproducir un .mkv H.264 1080p | "Reproducción directa" en el panel info |
| HW transcoding funciona | UI: forzar transcoding (limitar bitrate del cliente) sobre H.264 1080p | "Transcodificando vídeo (V4L2)" en el panel info |
| WebSocket activo | DevTools del navegador → Network → ws | conexión `jellyfin.lan/socket` en estado `101 Switching Protocols` |
| Owner correcto del config | `stat -c '%u:%g %a' /mnt/hd2t/apps/jellyfin/config` | `1000:1000 750` |
| Bibliotecas en `/mnt/hd2t/media/` con grupo media | `stat -c '%a %U:%G' /mnt/hd2t/media/movies` | `2770 homelab:media` |
| `/media/*` montado read-only en el contenedor | `docker exec jellyfin sh -c 'touch /media/movies/.write_test 2>&1 \| head -1'` | `touch: cannot touch ...: Read-only file system` |
| Authelia bypass para `jellyfin.lan` | `curl -ksI https://jellyfin.lan/web/index.html` | sin `Location` apuntando a `auth.lan` |
| Sin warnings críticos en logs | `docker logs jellyfin 2>&1 \| grep -iE 'error\|fail' \| head` | salida razonable (no errores recurrentes de permisos o BBDD) |

---

## Referencias

- Documentación oficial Jellyfin — https://jellyfin.org/docs/
- Hardware Acceleration on Raspberry Pi — https://jellyfin.org/docs/general/administration/hardware-acceleration/rpi/
- jellyfin-ffmpeg7 — https://github.com/jellyfin/jellyfin-ffmpeg
- Imagen Docker LinuxServer.io — https://docs.linuxserver.io/images/docker-jellyfin/ ; https://github.com/linuxserver/docker-jellyfin
- Imagen Docker upstream — https://hub.docker.com/r/jellyfin/jellyfin
- Reverse proxy con Caddy (oficial) — https://jellyfin.org/docs/general/networking/caddy
- Network configuration — https://jellyfin.org/docs/general/networking/
- Pi 5 / VideoCore VII — https://www.raspberrypi.com/documentation/computers/raspberry-pi-5.html
- Apps oficiales — https://jellyfin.org/clients/
- Plugin TMDb — https://github.com/jellyfin/jellyfin-plugin-tmdb
- Skip Intro Plus — https://github.com/jumoog/intro-skipper
- Open Subtitles plugin — https://github.com/jellyfin/jellyfin-plugin-opensubtitles
- Documentos hermanos: `02-navidrome.md`, `03-audiobookshelf.md`, `04-calibre-web.md`, `05-stash.md`.
- Documentos referenciados: `01-sistema/04-estructura-directorios.md`, `02-docker/02-estructura-compose.md`, `03-red/02-pihole.md`, `03-red/04-caddy.md`, `03-red/05-tailscale.md`, `04-seguridad/01-authelia.md`, `07-backups/01-estrategia-backup.md`, `07-backups/02-borgmatic.md`.
