# Jellyfin (servidor multimedia)

## Descripción

Despliegue de **Jellyfin** como servidor multimedia del homelab: catálogo, metadatos, playback _in-place_ (cuando el cliente soporta el códec original) y _direct stream / direct play_ desde clientes web, Android, iOS, Android TV, Kodi y reproductores compatibles con _Cast_. Toda la configuración persistente (`/config`) y la BD SQLite del catálogo viven en el disco externo **hd2t** (`/mnt/hd2t/services/jellyfin/`), y la biblioteca multimedia compartida ocupa `/mnt/hd2t/services/shared/media/` (preparada en `docs/01-sistema/04-estructura-directorios.md` con bit `setgid` y grupo `homelab-media`, lectura compartida con Samba/Sonarr/Radarr).

Este documento **estrena el _stack_ `multimedia`** (`~/homelab/multimedia/`) descrito en `docs/02-docker/02-estructura-compose.md` (tabla de stacks, fila `multimedia`, fase `docs/09-multimedia/`). El _stack_ alojará en fases siguientes a Navidrome (`02-navidrome.md`), Audiobookshelf (`03-audiobookshelf.md`), Calibre-Web (`04-calibre-web.md`) y Stash (`05-stash.md`); aquí se materializa **únicamente** el contenedor `jellyfin` y las _piezas_ que necesita para arrancar limpio (_bind mounts_, bloque del `Caddyfile`, hook de Borgmatic).

Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone Jellyfin en `https://jellyfin.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), MagicDNS resuelve `pi.<tailnet>.ts.net` y desde ahí se llega al mismo backend; Jellyfin aprende la IP de origen real porque _trusted proxies_ está configurado vía `network.xml` (sección **Decisiones de diseño**).

> **Alcance**: este documento despliega Jellyfin con su autenticación nativa (usuarios + contraseña + opción de TOTP cuando el plugin `LDAP-Auth`/`Multi-Factor` esté maduro), configura la biblioteca multimedia leyendo `/mnt/hd2t/services/shared/media/` en modo `:ro`, deja **deshabilitada por defecto la transcodificación por hardware** (las limitaciones del Pi 5 hacen que VAAPI no sea aún utilizable de forma consistente para H.264/HEVC; se documenta cómo activarla cuando el _firmware_/`mesa` lo permitan) y entrega un _hook_ Borgmatic listo para hacer dump de la SQLite del catálogo. **No** delega autenticación a Authelia vía `forward_auth` (rompería las apps móviles, las apps de TV y los _SyncPlay_; ver **Decisiones de diseño**). **No** instala Navidrome (`docs/09-multimedia/02-navidrome.md`), **no** instala Audiobookshelf (`docs/09-multimedia/03-audiobookshelf.md`), **no** instala Calibre-Web (`docs/09-multimedia/04-calibre-web.md`), **no** instala Stash (`docs/09-multimedia/05-stash.md`). **No** activa _DLNA_ (la red `bridge` no propaga _multicast_ por defecto; activarlo requiere `host` networking — fuera de alcance, ver **Decisiones de diseño**). **No** configura el _intro skipper_ ni el _credit skipper_: son plugins de comunidad que se documentarán aparte si llega el caso.

> **Recordatorio de red**: Jellyfin **no se publica al host** salvo el puerto opcional `:7359/udp` para descubrimiento de clientes en la LAN (también queda **deshabilitado** por defecto, los clientes se configuran a mano por `https://jellyfin.lan`). Caddy lo alcanza por DNS interno de Docker (`jellyfin:8096` en la red `homelab`). Pi-hole resuelve `jellyfin.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`). El operador entra siempre por `https://jellyfin.lan/` (LAN) o por el nombre _MagicDNS_ del nodo Tailscale.

---

## Requisitos previos

- `docs/02-docker/02-estructura-compose.md` completado: la tabla de _stacks_ reserva el _slot_ `multimedia` que aquí se estrena, la red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) externa está creada, `~/homelab/.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `MEDIA_GID=<gid real>`, `HOMELAB_DOMAIN=lan` está rellenado, y el _Makefile_ de operación expone `make up STACK=<stack>`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/jellyfin/{config,cache,transcodes}` ya existen con ownership `1000:1000` (paso 7 de aquel doc, "Reasignar ownership de los servicios LinuxServer.io" — Jellyfin se reasigna a `1000:1000` aunque vayamos a usar la imagen oficial, porque es el UID del operador y el de los demás servicios multimedia que comparten la biblioteca). El árbol `/mnt/hd2t/services/shared/media/` existe con `root:homelab-media 2775` para que Jellyfin lo lea.
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada y por defecto desactivada. Jellyfin será **opt-in** explícito (ver **Decisiones de diseño**), coherente con la lista de "candidatos a _opt-in_ desde el principio" de aquel doc.
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `jellyfin.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile` y la CA local firma `*.lan`. El _snippet_ de `security-headers` denega cámara/micro/geo por defecto; en este documento se sobreescribe `Permissions-Policy` para permitir `picture-in-picture` en el bloque `jellyfin.lan` (la _web UI_ usa PiP cuando el cliente lo solicita).
- `docs/04-seguridad/01-authelia.md` completado **opcionalmente**: si Authelia ya está montado, en este documento se decide explícitamente **no** poner Jellyfin detrás de `forward_auth`. Si Authelia aún no está montado, no pasa nada — Jellyfin trae su propia autenticación. La lista de servicios `two_factor` del `access_control.rules` de Authelia **no incluye** `jellyfin.lan` (a diferencia de Vaultwarden / Nextcloud / Home Assistant que sí aparecen comentados como _slots_): Jellyfin no entra ahí, ni siquiera comentado.
- `docs/06-almacenamiento/02-samba.md` completado o pendiente: la _share_ `media` de Samba escribe en `/mnt/hd2t/services/shared/media/` con `force user = homelab` y `force group = homelab-media`, exactamente lo que Jellyfin escanea. Si Samba aún no está montado, la biblioteca se rellena por SFTP / `rsync` directo o por Sonarr/Radarr (cuando llegue la fase de descargas).
- `docs/07-backups/02-borgmatic.md` y `docs/07-backups/03-backup-docker-volumes.md` completados (recomendado): el `source_directories: /mnt/hd2t/services` ya engloba `jellyfin/config/` y excluye `cache/` + `transcodes/`. El _hook_ `dump-databases.sh` tiene el bloque comentado para SQLite del catálogo. Este doc termina **descomentando** ese bloque.
- Conectividad saliente para descargar la imagen (sólo la primera vez):

  ```bash
  docker pull --platform linux/arm64 jellyfin/jellyfin:10.10 >/dev/null && echo OK
  ```

- Que el host **no** tenga ya un servicio escuchando en `:8096`:

  ```bash
  sudo ss -tulpn '( sport = :8096 or sport = :8920 or sport = :7359 or sport = :1900 )'
  ```

  Salida esperada: vacía. Jellyfin no publica `:8096` al host (Caddy lo alcanza por DNS interno), pero conviene confirmar que ningún binario residual lo ocupa por si más adelante el operador, durante un _troubleshoot_, añadiese un `ports: ["8096:8096"]` improvisado.

- Espacio en `/mnt/hd2t`: como mínimo **2 GB libres** para que Jellyfin arranque cómodo (BD del catálogo + metadatos + `cache/` con _images_ y _trickplay_). La cuota real la dictan el catálogo (en torno a **10 MB por cada 1000 episodios** en la BD SQLite + **1–3 GB de imágenes/posters/fanart** en `cache/`) y los _trickplay_ generados (cubren `/mnt/hd2t/services/jellyfin/cache/trickplay/` y son los que más crecen — ~10 MB por hora de vídeo procesada). En estado estable, el árbol `/mnt/hd2t/services/jellyfin/` se mantiene típicamente entre **5 y 20 GB** según el tamaño de la biblioteca.

  ```bash
  df -h /mnt/hd2t
  ```

---

## Decisiones de diseño

### Por qué Jellyfin (y no Plex / Emby / Kodi headless)

El homelab necesita un **servidor multimedia** que indexe vídeo (películas + series), sirva _streaming_ a los clientes de la familia desde la LAN y desde Tailscale, mantenga el progreso de visionado entre dispositivos y no dependa de cuentas en la nube ni servicios SaaS. Tres alternativas descartadas y por qué:

| Candidato        | Por qué se descarta                                                                                                                                                                                                                                                                                              |
|------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Plex**         | Requiere _account_ en `plex.tv` y _claim_ del servidor por internet incluso para uso 100 % LAN. Funciones críticas (catálogo, _watch progress_) atraviesan los servidores de Plex incluso sin _Plex Pass_; un fallo de Plex o un cambio de _ToS_ rompe el homelab. Filosofía contraria al homelab "todo local + Tailscale". |
| **Emby**         | Origen común con Jellyfin (Jellyfin es _fork_ libre de Emby 3.5.2). Modelo _freemium_: las apps móviles pagan, _hardware transcoding_ pago, _LiveTV/DVR_ pago. Sin razón para no usar Jellyfin si lo único que se busca es self-hosted libre.                                                                       |
| **Kodi headless**| Kodi brilla como _frontend_ en TV pero su modo "_server_" (Kodi+MariaDB compartida) no separa _backend_ y _frontend_: cada cliente Kodi necesita acceso directo a la BD, no hay _streaming HTTP_ canónico, no hay app móvil "oficial" para esa BD. Resuelve un problema distinto.                                |

Jellyfin gana por:

- **100 % gratis y libre** (GPLv2): código, plugins oficiales, apps móviles oficiales (Android, iOS, Android TV, Roku, Apple TV).
- **Sin cuenta externa, sin _phone home_**: arranca aislado, no contacta con servicios de terceros salvo cuando el operador instala plugins de _scrapers_ (TheMovieDB, TheTVDB, etc.) que sólo consultan al hacer match de metadatos.
- **Imagen Docker oficial multi-arch ARM64** publicada por el equipo de Jellyfin en Docker Hub (`jellyfin/jellyfin`), sin recurrir a forks de comunidad ni _builds_ de terceros.
- **API HTTP estable** documentada en OpenAPI/Swagger, lo que facilita integraciones futuras (Sonarr/Radarr la consumen para refrescar bibliotecas, Homepage/Homarr la consumen para el dashboard).
- **`Direct Stream` y `Direct Play` por defecto**: si el cliente soporta el códec original (la mayoría de TVs/móviles modernos reproducen H.264 + AAC sin tocar nada), el servidor sólo entrega bytes; cero CPU. La transcodificación es la excepción, no la norma.

### Imagen y _tag_

- **`jellyfin/jellyfin:10.10`** — imagen oficial del proyecto, _tag_ "major.minor" siguiendo la convención del homelab (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`, "Tag mayor o LTS"). Multi-arch (`linux/arm64`). El _tag_ `10.10` sigue la línea estable de 2025-2026; los _bumps_ de patch (`10.10.7 → 10.10.8`) llegan cada pocas semanas con _bug fixes_ y _security patches_, sin _breaking changes_.
- **Por qué no `:latest`**: ese _tag_ se mueve cada vez que sale una nueva versión _major_ (`10.10 → 11.x`); un `docker compose pull` accidental durante una _major_ podría introducir cambios de _schema_ en la BD del catálogo que no se pueden revertir.
- **Por qué no `:unstable`**: la línea _unstable_ se publica diariamente desde `master`; instalarla en un homelab que da servicio a personas reales no aporta valor.
- **Por qué la imagen oficial y no `linuxserver/jellyfin`**: `docs/02-docker/02-estructura-compose.md` fija como ejemplo `jellyfin/jellyfin:10.10` ("Tag mayor o LTS, nunca `latest`") y como política "Imágenes oficiales preferidas a forks comunitarios". La imagen LSIO añade `s6-overlay`, gestiona `PUID`/`PGID` por _entrypoint_ y suele llevar 1-3 días de retraso respecto a la oficial; la oficial corre como root y se baja a un usuario no-root vía `user:` en el compose, exactamente igual de seguro y un poco más simple.

#### Watchtower **opt-in**

Razones:

- **Patches frecuentes sin _breaking changes_**: la línea `10.10.x` recibe _patch releases_ casi mensuales con _security fixes_ del propio Jellyfin y de sus dependencias (FFmpeg, .NET runtime). Mantenerse al día sin tocar a mano es deseable.
- **Schema de BD estable dentro de una `minor`**: el `library.db` (SQLite) sólo cambia de _schema_ cuando salta de `10.10` a `10.11`; dentro de `10.10.x` los _patches_ son intercambiables. Watchtower puede reciclar el contenedor con seguridad.
- **Sin estado en RAM**: Jellyfin lo persiste todo en `/config` antes de recibir la señal de `SIGTERM`. Reciclar el contenedor durante la madrugada (la ventana de Watchtower es domingo a las 04:00 UTC, ver `docs/02-docker/04-watchtower.md`) no rompe sesiones — los clientes se reconectan en un par de segundos.

Etiquetar el contenedor con `com.centurylinklabs.watchtower.enable: "true"`. Coherente con la lista global de `docs/02-docker/04-watchtower.md` (sección _candidatos a opt-in desde el principio_, donde Jellyfin aparece nominalmente).

> **Bumps de _major_** (`10.10 → 10.11`, `10.x → 11.x`): se hacen **a mano**, fuera de Watchtower. Cambiar `JELLYFIN_IMAGE_TAG=10.11` en `~/homelab/multimedia/.env`, leer las _release notes_ del proyecto en GitHub, hacer backup del `/config` previo (Borgmatic + dump SQLite), y aplicar `make pull STACK=multimedia && make up STACK=multimedia`. Watchtower con _tag_ `10.10` no salta a `10.11` automáticamente porque mira el _digest_ del _tag_ exacto que está pinneado.

### Modo de red: `bridge` (red `homelab`), no `host`

Decisión opinada y la más debatida de este documento. Las dos opciones razonables:

| Opción                              | Ventajas                                                                                                                                                           | Inconvenientes                                                                                                                                                                                                                                                          |
|-------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **`network_mode: host`**            | Auto-discovery por SSDP/DLNA (`:1900/udp`) y por _broadcast_ propio de Jellyfin (`:7359/udp`) funciona _out-of-the-box_. La app de TV/móvil que escanee la WiFi encuentra el servidor sin escribir la URL. | Rompe el patrón "Caddy delante de cada servicio" — Jellyfin escucharía en `192.168.1.3:8096` directamente. Caddy puede _reverse-proxy_ a esa IP, pero hay que mantener la IP estática y abrir un agujero en `nftables` para `:8096`. Además, expone Jellyfin al host: cualquier proceso local puede pinchar la API sin Caddy. |
| **`bridge` en red `homelab`** ✅    | Coherente con todos los demás servicios (Caddy, Pi-hole, Authelia, Nextcloud, Home Assistant…): Jellyfin se alcanza por DNS interno (`jellyfin:8096`), no expone puertos al host, Caddy es el _único_ camino al servicio. Aislamiento limpio. | Auto-discovery SSDP/DLNA **no** atraviesa el `bridge`. Las apps "encuentran solas" Jellyfin no funcionan; el operador escribe `https://jellyfin.lan` la primera vez y la app lo recuerda.                                                                                  |

Se elige `bridge`. La pérdida del auto-discovery es asumible: en un homelab con 3-5 dispositivos cliente, escribir la URL una vez por dispositivo no es fricción real. Para los casos donde DLNA sea estrictamente necesario (un televisor antiguo sin app de Jellyfin que sólo soporte DLNA/UPnP), la solución _idiomática_ es desplegar un _puente_ DLNA aparte (p. ej. `minidlna` con `network_mode: host`) que sirva de la misma biblioteca compartida — fuera de alcance de este doc.

> **Cuándo NO basta el bridge**: TVs y reproductores _legacy_ que sólo descubren servidores por SSDP/UPnP (no tienen app de Jellyfin). Si esa es una requerimiento del primer día, releer esta sección y considerar `host` o un _bridge DLNA_ aparte.

> **Puerto `:7359/udp`**: es el _Jellyfin auto-discovery_ propio (no SSDP). Las apps de Jellyfin envían un _broadcast_ a esa IP/puerto y el primer servidor que responde aparece como sugerido. En `bridge` no llega: las apps se configuran a mano. **No** se publica.

### Volumen de la biblioteca multimedia: `/services/shared/media:/media:ro`

La biblioteca multimedia se monta **read-only** dentro del contenedor:

```yaml
volumes:
  - /mnt/hd2t/services/shared/media:/media:ro
```

Razones:

- **Jellyfin no debería escribir en la biblioteca**. El servidor _indexa_, _refresca metadatos_ (poster, fanart, descripciones) y guarda el _watch progress_ en su BD interna (`/config/data/jellyfin.db`), no en la carpeta de los ficheros. Algunos plugins (intro skipper) sí pueden generar _sidecars_ junto a los `.mkv`, pero esos plugins están explícitamente **fuera de alcance** y, si se quieren más adelante, se les abrirá un volumen `:rw` específico.
- **Sonarr/Radarr son los que escriben** (en la fase 10, `docs/10-descargas/`). Jellyfin escanea, ellos rellenan.
- **Samba** (`docs/06-almacenamiento/02-samba.md`) también escribe en la misma carpeta cuando el operador deja un MKV manualmente — montaje `:rw` en _ese_ contenedor, no en Jellyfin.
- **`:ro` mata por construcción** la mayoría de _data loss_ accidentales: un bug en Jellyfin no podrá nunca borrar la biblioteca, ni un ataque a la API podrá `DELETE /Items/...` borrando ficheros del disco (sólo desindexaría de la BD interna, recuperable con un re-scan).

> **Esta convención está alineada con `docs/02-docker/02-estructura-compose.md`** (sección **Volúmenes**, regla `:ro` explícito): "La biblioteca multimedia compartida (`services/shared/media`) **se monta `:ro` en Jellyfin** (sólo lee) y **`rw` en Sonarr/Radarr** (mueven y renombran ficheros)."

### Transcodificación: **deshabilitada** por defecto en Pi 5

El elefante en la habitación de _Jellyfin sobre Raspberry Pi 5_. Resumen de la situación a fecha de este documento (Q2 2026):

- **El SoC BCM2712 de la Pi 5 incluye una VideoCore VII con motor de _decode_ H.264 / HEVC funcional**. En `/dev/dri/renderD128` aparece un _DRM render node_ que `vainfo` lista correctamente.
- **El _encode_ por hardware**, sin embargo, **no está implementado** en `mesa` ni en el _firmware_ propietario de Broadcom para Pi 5. Esto significa que VAAPI puede **decodificar** un H.264 pero **no puede re-codificar** la salida — y Jellyfin necesita _ambos_ pasos para hacer transcoding (decode + encode + mux).
- **Software transcoding (CPU)** sigue siendo la única opción funcional. Un solo _stream_ 1080p → 720p H.264 satura **el 100 % de los 4 cores ARM A76** de la Pi 5 (FFmpeg sin aceleración HW). Más de un _stream_ simultáneo a transcodificar = _stuttering_ en todos los clientes.

Conclusión operativa: **la única estrategia viable es Direct Play / Direct Stream**. Eso significa:

- Mantener la biblioteca con códecs que la mayoría de clientes pueden reproducir nativamente: **H.264 + AAC en `.mkv`/`.mp4`** para vídeo; **MP3, FLAC, AAC** para audio. Las TVs/móviles modernos lo aceptan sin transcodificar.
- Evitar **HEVC 10-bit** salvo que el cliente principal sea un Apple TV / Shield que lo soportan: las apps en TVs LG / Samsung / TCL / Hisense de gama media _no_ lo decodifican y caerían en _transcode_, que la Pi no puede sostener.
- Configurar en Jellyfin **`Hardware acceleration: None`** y **`Allow encoding in HEVC format: false`**.

> **Cuándo se reactivará**: cuando `mesa` (rama `main`) anuncie soporte VAAPI _encode_ para Pi 5 — se sigue en <https://gitlab.freedesktop.org/mesa/mesa/-/issues/?label_name%5B%5D=Raspberry+Pi+5> — o cuando Broadcom abra el _encoder_ vía `v4l2-request`. Hasta entonces, los _flags_ `--device /dev/dri:/dev/dri` y `group_add: video,render` no aportan valor y se mantienen **comentados** en el compose.

### `forward_auth` con Authelia: **NO** para Jellyfin

Tentación natural una vez Authelia está montada: añadir `import authelia` al bloque `jellyfin.lan` del `Caddyfile`. **No se hace**, exactamente por las mismas razones que Nextcloud y Home Assistant:

- **Las apps móviles oficiales y de TV** (Android, iOS, Android TV, Apple TV, Roku, Kodi+JellyCon, Findroid, Jellyfin Media Player) hablan con Jellyfin por la **API HTTP nativa** usando un **Bearer Token** (`X-Emby-Token` / `Authorization: MediaBrowser Token=...`) que se obtiene tras un `POST /Users/AuthenticateByName`. **No** saben redirigirse a un portal _web_, no resuelven un _challenge_ OIDC, no rellenan un formulario HTML. Si Caddy intercepta el _request_ y devuelve `302 Location: https://auth.lan/?rd=...`, la app falla en bucle.
- **El `/web` (cliente web del navegador)** usa también Bearer Token tras un login HTML, pero el endpoint `/Users/AuthenticateByName` es un POST JSON puro: si Authelia se interpone, el navegador recibe el HTML de la _login page_ de Authelia en lugar del JSON con el token, y el cliente web rompe.
- **Chromecast / DLNA renderers** (cuando se _cast_ee desde el móvil al televisor): la app móvil le pasa al Chromecast una URL firmada de Jellyfin; el Chromecast la pide directamente al servidor, sin contexto de _cookies_ ni _OIDC_. Authelia delante = el Chromecast recibe HTML y no reproduce nada.
- **SyncPlay** (varios clientes sincronizados viendo lo mismo): WebSocket persistente con autenticación Bearer. Misma incompatibilidad que las apps.

Solución correcta: **Jellyfin autentica con su sistema nativo** (usuario + contraseña por usuario, opcional bloqueo de IP tras N intentos fallidos en `network.xml`). El operador puede activar **2FA TOTP** vía el plugin `Multi-Factor` (cuando el plugin esté maduro y empaquetado oficialmente; hoy en `10.10` aún está en el _community plugin catalog_ y requiere validación manual del _commit_ — fuera de alcance). Para SSO con Authelia más adelante, hay un trabajo en curso (`jellyfin-plugin-sso` en GitHub) que implementa OIDC contra Authelia/Authentik; esa migración se documentará aparte si se valora necesaria, pero **el cliente móvil seguirá usando Bearer Tokens nativos**.

> **Resumen operativo**: el bloque `jellyfin.lan` del `Caddyfile` lleva `import security-headers` y `import logging`, pero **no** `import authelia`. Caddy actúa como _reverse proxy_ "tonto" que termina TLS, propaga `X-Forwarded-*` y, **sólo en este bloque**, sobreescribe `Permissions-Policy` para permitir `picture-in-picture` y `fullscreen` (que el _snippet_ global denega).

### Catálogo en SQLite (no MariaDB/Postgres)

Jellyfin **no soporta** MariaDB/Postgres como _backend_ del catálogo a fecha de este documento. La BD es SQLite (`/config/data/jellyfin.db`) y punto. Esta decisión la toma el proyecto _upstream_, no el homelab. Implicaciones:

- **Footprint mínimo**: la BD vive en `/config/data/` sin contenedor extra. Para una biblioteca de 500 películas + 5000 episodios, el `jellyfin.db` ronda los **80–150 MB**.
- **Backups con Patrón S** (`docs/07-backups/03-backup-docker-volumes.md`): la imagen oficial de Jellyfin **incluye `sqlite3` en el _PATH_** (parte del _.NET runtime tooling_), así que se puede ejecutar `sqlite3 .backup` _online_ sin parar el contenedor. Si por alguna razón no estuviera, el _hook_ cae automáticamente a Patrón S-fría (parar contenedor, copiar fichero, arrancar) — downtime ~10 s.
- **Cuando crece "demasiado"**: si la biblioteca llega a decenas de miles de ítems, el cuello de botella suele ser el _scan_ inicial en frío (FFprobe + scrapers) más que la BD en sí. Mitigación: ejecutar el primer _scan completo_ en una ventana sin uso (madrugada) y dejar que Jellyfin haga _scan incremental_ a partir de ahí.

### Almacenamiento

| Ruta en el host                                            | Contenido                                                            | Versionable           | Backup                              |
|------------------------------------------------------------|----------------------------------------------------------------------|-----------------------|-------------------------------------|
| `~/homelab/multimedia/docker-compose.yml`                  | Definición del _stack_                                               | git                   | git                                 |
| `~/homelab/multimedia/.env`                                | Imágenes pinneadas + variables del _stack_                           | **NO** (`.gitignore`) | git aparte (nota local)             |
| `~/homelab/multimedia/.env.example`                        | Plantilla con nombres de variables, sin valores                      | git                   | git                                 |
| `/mnt/hd2t/services/jellyfin/config/`                      | `jellyfin.db` + `system.xml` + `network.xml` + `users.xml` + `metadata/` + `plugins/` | **NO** versionable    | **Sí** (Borgmatic)                  |
| `/mnt/hd2t/services/jellyfin/config/data/jellyfin.db`      | BD SQLite del catálogo (estados, _watch progress_, _resume points_)  | **NO**                | **Sí** (Borgmatic vía dump)         |
| `/mnt/hd2t/services/jellyfin/config/log/`                  | Logs rotados de Jellyfin                                             | **NO**                | **NO** — excluidos por `exclude_patterns` |
| `/mnt/hd2t/services/jellyfin/cache/`                       | Imágenes redimensionadas, _trickplay_, _subtitles cache_             | **NO**                | **NO** — regenerable                |
| `/mnt/hd2t/services/jellyfin/transcodes/`                  | Salidas de FFmpeg en transcodificación activa                        | **NO**                | **NO** — efímero (tmpfs en runtime) |
| `/mnt/hd2t/services/shared/media/`                         | Biblioteca multimedia (películas + series), montada `:ro` en Jellyfin | **NO**                | **NO** — Categoría C, regenerable (re-importación)  |

> **`config/log/` y `cache/` excluidos**: el `cache/` ya está cubierto por el _exclude pattern_ global `*/cache/*` de `docs/07-backups/02-borgmatic.md`. Los logs de Jellyfin (`/mnt/hd2t/services/jellyfin/config/log/*.log`) se añaden explícitamente al `config.yaml` de Borgmatic en la sección **Backup** de este doc.

> **`transcodes/` excluido**: ya aparece nominalmente en `docs/07-backups/01-estrategia-backup.md` como "tmpfs en runtime" y en el `exclude_patterns` global de `02-borgmatic.md` (`*/transcodes/*`). No hay nada que añadir.

> **Biblioteca compartida en `/services/shared/media/`**: política Categoría C de `docs/07-backups/01-estrategia-backup.md` — _no entra en Borg_. La BD del catálogo de Jellyfin (que sí entra) describe qué hay y dónde, pero los `.mkv` mismos no se respaldan. Si se pierde el disco hd2t, la biblioteca multimedia se restaura **re-descargándola** o desde la copia que el operador tenga en otro sitio.

---

## Estructura del _stack_ `multimedia` tras este documento

```
~/homelab/multimedia/
├── docker-compose.yml        # ← nuevo
├── .env                      # ← nuevo (NO versionado)
├── .env.example              # ← nuevo (versionado)
└── .gitignore                # ← nuevo (excluye .env)
```

Y en los discos externos, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/jellyfin/
├── config/      (vacío al empezar; el primer arranque lo puebla)
├── cache/       (vacío al empezar)
└── transcodes/  (vacío; sólo se llena durante transcoding activo)
```

Crear el subdirectorio del _stack_ y los _stubs_ de gitignore:

```bash
mkdir -p ~/homelab/multimedia
chmod 0750 ~/homelab/multimedia

cat > ~/homelab/multimedia/.gitignore <<'EOF'
# Secretos del stack — NUNCA commitear
.env
EOF
```

> **Ownership de `/mnt/hd2t/services/jellyfin/`**: ya está fijado por `docs/01-sistema/04-estructura-directorios.md` paso 7 a `1000:1000`. El contenedor corre como `${PUID}:${PGID}` (= `1000:1000`) gracias al `user:` del compose, así que escribe sin fricciones. **No** hay que pre-`chown`-ear nada de nuevo.

> **Ownership de `/mnt/hd2t/services/shared/media/`**: `root:homelab-media 2775` (bit `setgid` activo). Jellyfin sólo lee (`:ro`), así que el GID del contenedor da igual a efectos de escritura. Para _lectura_, el GID `1000` (`PGID`) **no** es el de `homelab-media`, así que el contenedor lee gracias al bit `o+rx` del `2775`. Funciona, pero es subóptimo: si en algún momento un fichero de la biblioteca queda con permisos `2750` (sin `o+r`), Jellyfin no lo verá. Para asegurar lectura por GID en lugar de "otros", añadir `MEDIA_GID` al contenedor como **grupo suplementario**:
>
> ```yaml
> group_add:
>   - "${MEDIA_GID}"     # del .env global; getent group homelab-media | cut -d: -f3
> ```
>
> Esto se incluye en el compose más abajo y elimina la dependencia del bit `o+r`.

---

## Variables de entorno

Crear `~/homelab/multimedia/.env.example` (versionado en git, sin valores reales ni secretos):

```bash
# --- Imágenes pinneadas -----------------------------------------------------
# Patches automáticos vía Watchtower. Bumps de minor/major a mano leyendo
# https://github.com/jellyfin/jellyfin/releases.
JELLYFIN_IMAGE_TAG=10.10

# --- Jellyfin ---------------------------------------------------------------
# URL pública canónica del servicio. Coincide con el bloque del Caddyfile y
# con el wildcard *.lan que Pi-hole resuelve a 192.168.1.3. Jellyfin la usa
# para construir URLs absolutas en respuestas a clientes (poster art, etc.).
JELLYFIN_PUBLISHED_SERVER_URL=https://jellyfin.lan

# Subnet de la red Docker 'homelab' (creada en docs/02-docker/02-estructura-compose.md).
# Fijada ahí en 172.20.10.0/24. Va a network.xml -> KnownProxies para que Jellyfin
# acepte X-Forwarded-For desde Caddy y muestre IPs reales en el log de auditoría.
JELLYFIN_TRUSTED_PROXY_SUBNET=172.20.10.0/24
```

Copiar a `.env` y mantener los valores reales:

```bash
cp ~/homelab/multimedia/.env.example ~/homelab/multimedia/.env
chmod 0600 ~/homelab/multimedia/.env
```

> **`.env` aquí no contiene secretos** (Jellyfin gestiona los suyos en `/config/`). Aun así, se mantiene `0600` y fuera de git por consistencia con el resto de _stacks_ y por si futuros servicios del propio _stack_ (Stash con _passphrase_, p. ej.) lo necesitan.

> **No commitear `.env` jamás**. El `.gitignore` del _stack_ ya lo excluye explícitamente.

---

## `~/homelab/multimedia/docker-compose.yml`

```yaml
---
# Stack: multimedia — Jellyfin
# Documentación: docs/09-multimedia/01-jellyfin.md
# (Navidrome, Audiobookshelf, Calibre-Web y Stash se añaden en docs siguientes.)

services:

  # ---------------------------------------------------------------------------
  # Jellyfin — servidor multimedia (vídeo + música + fotos secundarias).
  # En 'homelab' (Caddy la alcanza por nombre); sin red privada de stack porque
  # de momento es el único servicio del stack. Se añadirá una red privada
  # 'multimedia-internal' si en el futuro un servicio del stack necesita una
  # BD compartida entre varios (no es el caso por ahora).
  # ---------------------------------------------------------------------------
  jellyfin:
    image: jellyfin/jellyfin:${JELLYFIN_IMAGE_TAG}
    container_name: jellyfin
    hostname: jellyfin
    restart: unless-stopped
    user: "${PUID}:${PGID}"
    group_add:
      # Permite a Jellyfin LEER /mnt/hd2t/services/shared/media/ por GID en
      # lugar de depender del bit 'o+r'. MEDIA_GID viene del .env global
      # (getent group homelab-media | cut -d: -f3), ver
      # docs/01-sistema/04-estructura-directorios.md.
      - "${MEDIA_GID}"
      # Cuando se reactive transcoding HW (ver Decisiones de diseño), añadir
      # los GIDs reales del host para 'video' y 'render' (típicamente 44 y 109).
      # Fuera de alcance hoy.
      # - "44"      # video
      # - "109"     # render
    environment:
      TZ: ${TZ}
      # Construye URLs absolutas (poster art, capítulos, etc.) con esta base.
      JELLYFIN_PublishedServerUrl: ${JELLYFIN_PUBLISHED_SERVER_URL}
    volumes:
      - /mnt/hd2t/services/jellyfin/config:/config
      - /mnt/hd2t/services/jellyfin/cache:/cache
      # Biblioteca multimedia compartida — read-only (Sonarr/Radarr la escriben).
      - /mnt/hd2t/services/shared/media:/media:ro
      # Hora del host (Jellyfin escribe timestamps; coincidencia clave).
      - /etc/localtime:/etc/localtime:ro
    # /dev/dri: descomentar SOLO cuando mesa/firmware soporten VAAPI encode
    # en Pi 5. Hoy decodifica pero no encoda — inútil para Jellyfin transcode.
    # Ver docs/09-multimedia/01-jellyfin.md, sección "Decisiones de diseño".
    # devices:
    #   - /dev/dri:/dev/dri
    networks:
      homelab:
        aliases:
          - jellyfin     # Caddy resuelve 'jellyfin:8096' por este alias
    labels:
      homelab.stack: "multimedia"
      homelab.backup: "true"   # /mnt/hd2t/services/jellyfin/config entra en Borgmatic
      # Opt-in: patches dentro de 10.10.x son seguros (sin breaking changes).
      com.centurylinklabs.watchtower.enable: "true"
    healthcheck:
      # /health es público (no requiere autenticación) y devuelve "Healthy"
      # cuando Jellyfin ha terminado de inicializar el catálogo y la API HTTP.
      test:
        - CMD-SHELL
        - "wget -qO- --tries=1 --timeout=5 http://localhost:8096/health | grep -q Healthy || exit 1"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s   # primer arranque: inicializa BD vacía, ~60 s
    # Sin 'ports:'. Caddy alcanza Jellyfin por DNS interno.
    # El puerto 7359/udp (auto-discovery propio) y 1900/udp (DLNA/SSDP) no
    # se publican: la red 'bridge' no propaga multicast y los clientes se
    # configuran a mano por https://jellyfin.lan.

# ---------------------------------------------------------------------------
# Redes
# ---------------------------------------------------------------------------
networks:
  homelab:
    external: true               # creada en docs/02-docker/02-estructura-compose.md
```

Notas de diseño:

- **`user: "${PUID}:${PGID}"`**: la imagen oficial de Jellyfin corre como `root` por defecto. Bajarla a `1000:1000` cumple la convención del homelab (el `/mnt/hd2t/services/jellyfin/` ya es `1000:1000` por `docs/01-sistema/04-estructura-directorios.md` paso 7). Equivalente al `PUID`/`PGID` que usan las imágenes LSIO, sólo que aquí se hace por la directiva `user:` de Compose en lugar de variables de entorno.
- **`group_add: ["${MEDIA_GID}"]`**: añade el GID del grupo `homelab-media` como _grupo suplementario_ del proceso. Permite a Jellyfin leer `/mnt/hd2t/services/shared/media/` (que es `root:homelab-media 2775`) por _ownership_ y no sólo por bit `o+r`. Robusto frente a ficheros que pudieran quedar sin permiso `o+r`.
- **`/media:ro`**: explícito y deliberado. Ver **Decisiones de diseño** → _Volumen de la biblioteca multimedia_.
- **Sin `ports:`**. Caddy alcanza Jellyfin por DNS interno (`jellyfin:8096`). Si el operador necesita acceder sin pasar por Caddy durante un _troubleshooting_, puede `docker exec -it jellyfin wget -qO- http://localhost:8096/health` desde dentro del propio contenedor.
- **`/etc/localtime:/etc/localtime:ro`**: además de `TZ`, montar `/etc/localtime` cubre algunos componentes (FFmpeg, .NET runtime) que leen la _zoneinfo_ por _glibc_ en lugar de por la variable de entorno. Ambas a la vez es la receta segura.
- **`start_period: 90s`** en `jellyfin`: el _primer_ arranque tarda ~60 s (Jellyfin inicializa la BD SQLite vacía, copia los _defaults_ de _branding_ y _web client_, arranca el _.NET host_). Con un `start_period` corto, el _healthcheck_ daría `unhealthy` espuriamente y Compose intentaría reiniciar el contenedor en plena instalación.
- **`/health` como _liveness probe_**: es público (sin autenticación) y devuelve la cadena `Healthy` cuando Jellyfin ha terminado de inicializar la API HTTP. No requiere token, ideal para `wget -qO-`.
- **Watchtower opt-in**: razones explicadas en **Decisiones de diseño** → _Imagen y tag_.
- **No `mem_limit`**: en idle (sin escaneo activo, sin transcoding) Jellyfin consume ~300–500 MB. Durante un _full library scan_ sube a ~1 GB. La política por defecto (sin límite) está bien para el _bootstrap_; cuando el _stack_ entero compita con Stash/Nextcloud, se ajustarán los límites desde `docs/13-operaciones/03-rendimiento-pi5.md`.
- **`devices: - /dev/dri:/dev/dri`** comentado: deliberadamente inactivo. Ver **Decisiones de diseño** → _Transcodificación_. Cuando `mesa` soporte VAAPI _encode_ en Pi 5, descomentar y añadir los GIDs reales de `video` y `render` al `group_add` (típicamente `44` y `109`, comprobar con `getent group video render`).

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/multimedia
docker compose --env-file ../.env --env-file .env config | head -40   # validar sintaxis
docker compose --env-file ../.env --env-file .env up -d
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=multimedia
```

Vigilar el primer arranque (tarda ~60 s):

```bash
docker compose -f ~/homelab/multimedia/docker-compose.yml logs -f jellyfin
# ...
# jellyfin  | [INF] [1] Main: Jellyfin version: 10.10.x
# jellyfin  | [INF] [1] Main: Operating system: Linux 6.6.x ARM64
# jellyfin  | [INF] [1] Emby.Server.Implementations.ApplicationHost: Application directory: /config
# jellyfin  | [INF] [1] Main: Startup complete 38.21s
```

Verificar que el contenedor está `(healthy)`:

```bash
docker compose -f ~/homelab/multimedia/docker-compose.yml ps
# NAME      STATUS                   PORTS
# jellyfin  Up X seconds (healthy)
```

> El `(healthy)` lo otorga el _healthcheck_ que confirma que `/health` devuelve `Healthy`. Si tras 3 minutos sigue `starting`, ir a **Troubleshooting** → primer arranque.

### Caddy: bloque `jellyfin.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque:

```caddy
jellyfin.lan {
    tls internal
    import security-headers
    import logging

    # Sobreescribir Permissions-Policy del snippet global: la web UI usa
    # picture-in-picture, fullscreen y autoplay para el reproductor.
    # camera/microphone/geolocation siguen denegados.
    header Permissions-Policy "camera=(), microphone=(), geolocation=(), picture-in-picture=(self), fullscreen=(self), autoplay=(self)"

    # WebSocket — Jellyfin lo usa para SyncPlay y para notificaciones del
    # "now playing". reverse_proxy de Caddy v2 soporta WS de forma transparente.

    reverse_proxy jellyfin:8096 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # Subidas de adjuntos y posters subidos a mano: el default de Caddy
        # (sin límite explícito en reverse_proxy) ya cubre. Si en el futuro
        # se sube un fanart 4K, no hace falta tocar nada.
    }
}
```

Validar y recargar Caddy:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Probar (la CA local debe estar importada en el navegador, ver `docs/03-red/04-caddy.md`):

```bash
curl -k --resolve jellyfin.lan:443:192.168.1.3 \
     https://jellyfin.lan/health
# Healthy

curl -k --resolve jellyfin.lan:443:192.168.1.3 \
     -s https://jellyfin.lan/System/Info/Public | python3 -m json.tool | head -20
# {
#     "LocalAddress": "http://172.20.10.x:8096",
#     "ServerName": "jellyfin",
#     "Version": "10.10.x",
#     ...
# }
```

Y desde el navegador: `https://jellyfin.lan/` → pantalla del **wizard de onboarding** de Jellyfin (idioma, primer usuario admin, _media library_, _metadata language_, _remote access_).

---

## Configuración tras primer arranque

### Onboarding

Login interactivo en `https://jellyfin.lan/`. La primera vez Jellyfin presenta:

1. **Idioma de la interfaz** — seleccionar (ej. español).
2. **Crear primer usuario** — usuario administrador. _username_ y _password_ robusta. **Usar un username distinto de `admin`/`administrator`** (objetivo trivial de _credential stuffing_). Esta cuenta tiene rol `Administrator` y permisos para crear más usuarios.
3. **Configurar bibliotecas** — añadir al menos una biblioteca:
   - **Tipo**: _Movies_ y/o _TV Shows_ (uno por carpeta).
   - **Carpeta**: `/media/movies` para películas, `/media/series` para series (las rutas dentro del contenedor son `/media/<subdir>` porque montamos `/mnt/hd2t/services/shared/media` en `/media`).
   - **Idioma de metadatos preferido**: `es` (o el que corresponda).
   - **Idiomas alternativos**: `en` como _fallback_.
   - **Country**: España (o el que corresponda).
   - **Real-time monitoring**: ON. Jellyfin detecta nuevos `.mkv` en cuanto se _drop_-een por SMB/Sonarr.
   - Saltar configuraciones avanzadas en el _wizard_; se ajustan más adelante en _Dashboard → Libraries_.
4. **Metadata language preferences** — coherente con la biblioteca (Spanish, fallback English).
5. **Remote access** — **deshabilitar el _UPnP/port forwarding_ automático**: el homelab no expone Jellyfin a internet, sólo a la LAN y a Tailscale. Marcar:
   - **Allow remote connections to this server**: ON (Tailscale es "remoto" desde la perspectiva de Jellyfin).
   - **Enable automatic port mapping**: **OFF**. Jellyfin no debe abrir puertos en el router; el operador no abre puertos en absoluto.

Al terminar, Jellyfin aterriza en el dashboard administrativo. Las bibliotecas configuradas empiezan a escanear; el primer _scan_ tarda en función del tamaño (5 minutos para 100 películas, 1-2 horas para 5000 episodios con metadata).

### Configuración de red interna (`network.xml`)

Tras el _wizard_, ajustar el fichero `network.xml` para que Jellyfin aprenda a confiar en Caddy y no se queje del _reverse proxy_. Editar desde el host:

```bash
sudoedit /mnt/hd2t/services/jellyfin/config/network.xml
```

Localizar (o añadir) los siguientes campos:

```xml
<NetworkConfiguration>
  <!-- ... otros campos ... -->

  <!-- Jellyfin escucha sólo HTTP en :8096; Caddy termina TLS. -->
  <RequireHttps>false</RequireHttps>
  <PublicHttpPort>80</PublicHttpPort>
  <PublicHttpsPort>443</PublicHttpsPort>
  <HttpServerPortNumber>8096</HttpServerPortNumber>
  <HttpsPortNumber>8920</HttpsPortNumber>
  <EnableHttps>false</EnableHttps>

  <!-- IPs/subnets desde las que Jellyfin acepta X-Forwarded-For y muestra
       la IP real del cliente en el log de auditoría. La subnet de la red
       Docker 'homelab' incluye al contenedor de Caddy. -->
  <KnownProxies>
    <string>172.20.10.0/24</string>
  </KnownProxies>

  <!-- Subnets que se consideran "LAN" (sin transcoding bandwidth limits
       por defecto). 192.168.1.0/24 es la LAN doméstica; 100.64.0.0/10 es
       el rango de Tailscale (CGNAT) para que dispositivos en la VPN se
       traten como red local en términos de bandwidth. -->
  <LocalNetworkSubnets>
    <string>192.168.1.0/24</string>
    <string>100.64.0.0/10</string>
    <string>172.20.10.0/24</string>
  </LocalNetworkSubnets>

  <!-- Auto-discovery deshabilitado: la red 'bridge' no propaga multicast. -->
  <AutoDiscovery>false</AutoDiscovery>

  <!-- DLNA deshabilitado: ver Decisiones de diseño. -->
  <EnableUPnP>false</EnableUPnP>
</NetworkConfiguration>
```

Reiniciar el contenedor para aplicar:

```bash
docker compose -f ~/homelab/multimedia/docker-compose.yml restart jellyfin
```

> **Por qué `RequireHttps=false` y `EnableHttps=false`**: TLS lo termina Caddy. Jellyfin habla HTTP plano dentro de la red `homelab` (que es de confianza, sólo accesible por contenedores y por procesos del host). Si activáramos HTTPS en Jellyfin, habría una capa de TLS innecesaria entre Caddy y Jellyfin, y Caddy tendría que validar (o ignorar) el cert auto-firmado de Jellyfin — frágil.

### Deshabilitar transcoding por hardware (explícitamente)

En **Dashboard → Playback → Transcoding**:

- **Hardware acceleration**: `None`.
- **Allow hardware encoding**: OFF.
- **Allow encoding in HEVC format**: OFF.
- **Throttle transcodes**: ON (límite por defecto). Reduce el coste si por error un cliente fuerza transcoding.

Y en **Dashboard → Playback** (general):

- **Transcoding temporary path**: `/cache/transcodes` (mapeado a `/mnt/hd2t/services/jellyfin/transcodes/`). Por _default_ Jellyfin escribe ahí; verificar.
- **Direct play and direct stream limits → Maximum streaming bitrate**: dejar el _default_ ("Unlimited" para LAN). Tailscale opera por encima del rate al que la WiFi del operador llega; no hace falta limitar.

> **Si en algún momento un cliente fuerza transcoding** (porque le llega un `.mkv` con HEVC y el cliente sólo soporta H.264), Jellyfin lo intentará por software, saturará la Pi y el cliente verá _stuttering_. Mejor solución: en el cliente, configurar "Direct play original" y aceptar que ese fichero concreto no se puede ver desde ese dispositivo. Mejor solución _todavía_: re-codificar el fichero a H.264 antes de meterlo en la biblioteca (Sonarr/Radarr puede automatizar esto en su fase).

### Crear usuarios adicionales (familia)

En **Dashboard → Users → Add User**:

- **Name**: nombre (ej. "pareja", "kid1", "kid2").
- **Password**: distinta del owner. Se la pone el usuario en su primer login si la dejas vacía y marcas "User must change password on first login".
- **Library access**: marcar las bibliotecas a las que tiene acceso. Por defecto se asume "todas".
- **Remote access**: ON si va a usar la app desde fuera de casa por Tailscale; OFF si sólo accede desde la WiFi de casa.
- **Parental controls**: opcional; restringe contenido por _Rating_ (ej. PG-13, R) si la biblioteca tiene metadatos completos.

> **2FA TOTP en Jellyfin**: a fecha de este documento, Jellyfin **no tiene** 2FA nativo en el _core_. El plugin `Multi-Factor Authentication` está en el _community plugin catalog_, pero su madurez es desigual y sus _releases_ no siempre coinciden con los _bumps_ de minor de Jellyfin. **Por ahora, 2FA queda fuera de alcance**. La mitigación es: contraseñas robustas (gestor + Vaultwarden cuando llegue) + el `LoginAttemptsBeforeLockout` de Jellyfin (ver siguiente sección).

### Endurecer el login (intentos máximos)

En **Dashboard → Users → seleccionar usuario → Failed Login Attempts**:

- **Maximum failed login attempts**: `5` para usuarios estándar, `3` para el administrador.

Tras superar el límite, Jellyfin desactiva al usuario hasta que el administrador lo reactiva manualmente. Mitiga _credential stuffing_ y ataques de fuerza bruta.

> **Por qué no usar `fail2ban` con un jail Jellyfin**: `docs/04-seguridad/02-fail2ban.md` planteó la posibilidad de un jail genérico para servicios HTTP. Para Jellyfin, el _lockout_ nativo del propio servidor es suficiente (es una mecanismo de _user-level_, no de _IP-level_, lo que evita falsos positivos con NAT). Si en el futuro hace falta también ban por IP, se puede añadir el jail en `02-fail2ban.md` mirando los logs de `/mnt/hd2t/services/jellyfin/config/log/jellyfin*.log`.

---

## Bibliotecas y escaneo

### Estructura recomendada de la biblioteca

Dentro de `/mnt/hd2t/services/shared/media/`, organizar:

```
/mnt/hd2t/services/shared/media/
├── movies/
│   ├── Inception (2010)/
│   │   └── Inception (2010).mkv
│   └── The Matrix (1999)/
│       └── The Matrix (1999).mkv
└── series/
    └── The Office/
        ├── Season 01/
        │   ├── The Office S01E01.mkv
        │   └── The Office S01E02.mkv
        └── Season 02/
            └── ...
```

Convención _Plex/Jellyfin standard_: `Name (Year)/Name (Year).ext` para películas, `Series/Season N/Series SxxExx.ext` para series. Sonarr/Radarr generan exactamente esto cuando llegue su fase (`docs/10-descargas/`).

### Forzar un re-scan

Útil tras añadir ficheros manualmente por SMB:

- **UI**: _Dashboard → Libraries → seleccionar biblioteca → Scan Library_.
- **API** (con un token):

  ```bash
  TOKEN=<API key del usuario admin>
  curl -k --resolve jellyfin.lan:443:192.168.1.3 \
    -X POST \
    -H "Authorization: MediaBrowser Token=$TOKEN" \
    https://jellyfin.lan/Library/Refresh
  ```

> **Real-time monitoring** (configurado en el _wizard_) detecta nuevos ficheros automáticamente vía `inotify`. El _re-scan_ manual es para cuando el bit `inotify` no fue (raro pero ocurre con _watch directories_ con muchos miles de ficheros y `fs.inotify.max_user_watches` bajo).

---

## Almacenamiento

Tras el primer arranque, el árbol `/mnt/hd2t/services/jellyfin/` queda con los siguientes ficheros relevantes:

```
/mnt/hd2t/services/jellyfin/
├── config/
│   ├── system.xml                  # configuración general
│   ├── network.xml                 # configuración de red (editado a mano arriba)
│   ├── encoding.xml                # transcoding settings
│   ├── users.xml                   # users metadata (no passwords)
│   ├── data/
│   │   ├── jellyfin.db             # BD SQLite (catálogo + watch progress)
│   │   ├── jellyfin.db-wal         # WAL de SQLite (presente mientras escribe)
│   │   ├── jellyfin.db-shm         # shared memory de SQLite
│   │   └── library.db              # legacy, alias del mismo
│   ├── log/
│   │   ├── jellyfin*.log           # logs activos del proceso
│   │   └── jellyfin*.log.archive*  # logs rotados
│   ├── metadata/
│   │   ├── library/                # JSON descriptors por item
│   │   └── People/                 # actores, directores con bio
│   ├── plugins/
│   │   └── (vacío inicialmente)
│   └── root/
│       └── default/                # default user homeDir
├── cache/
│   ├── images/                     # posters/fanart redimensionados
│   ├── trickplay/                  # thumbnails de scrubbing (~10 MB/h vídeo)
│   └── subtitles/
└── transcodes/                     # vacío salvo durante transcoding activo
```

| Ruta                                                          | Permisos        | Contenido                                                       |
|---------------------------------------------------------------|-----------------|------------------------------------------------------------------|
| `/mnt/hd2t/services/jellyfin/`                                | `1000:1000 0755` | Raíz del bind mount                                              |
| `/mnt/hd2t/services/jellyfin/config/`                         | `1000:1000 0755` | Configuración persistente                                        |
| `/mnt/hd2t/services/jellyfin/config/data/jellyfin.db`         | `1000:1000 0644` | BD SQLite del catálogo                                           |
| `/mnt/hd2t/services/jellyfin/config/log/`                     | `1000:1000 0755` | Logs                                                             |
| `/mnt/hd2t/services/jellyfin/cache/`                          | `1000:1000 0755` | Caches regenerables                                              |
| `/mnt/hd2t/services/jellyfin/transcodes/`                     | `1000:1000 0755` | Transcoding output efímero                                       |
| `/mnt/hd2t/services/shared/media/` (sólo lectura)             | `root:homelab-media 2775` | Biblioteca multimedia, montada `:ro` en el contenedor   |

> **Sobre `cache/trickplay/`**: Jellyfin genera _thumbnails_ a intervalos regulares de cada vídeo (cada ~10 segundos por defecto) para que el _scrubbing_ del reproductor muestre miniaturas. Eso es lo que más espacio crece dentro de `cache/`. Se puede deshabilitar en _Dashboard → Libraries → seleccionar biblioteca → Trickplay Images: Off_ si el espacio aprieta — pero el _UX_ de _scrubbing_ se degrada notablemente.

---

## Backup

Patrón S (online, vía `sqlite3 .backup`) sobre la BD del catálogo, más Patrón F (filesystem-only) sobre el resto del árbol. Resultado: respaldo coherente de todo `/config` sin parar Jellyfin.

### 1. Descomentar el bloque de Jellyfin en `dump-databases.sh`

Editar `~/homelab/backups/borgmatic/hooks/dump-databases.sh` y descomentar la línea que `docs/07-backups/03-backup-docker-volumes.md` dejó preparada:

```diff
 # --- Jellyfin (SQLite — config + library) — docs/09-multimedia/01-jellyfin.md
 # La BD vive en /mnt/hd2t/services/jellyfin/config/data/jellyfin.db
 # y se respalda con Patrón S si la imagen tiene sqlite3, o vía cold copy:
-# dump_sqlite jellyfin jellyfin /config/data/jellyfin.db
+dump_sqlite jellyfin jellyfin /config/data/jellyfin.db
```

> **¿La imagen oficial de Jellyfin trae `sqlite3`?**: sí, viene como parte del runtime .NET y de las herramientas de soporte; `docker exec jellyfin which sqlite3` devuelve `/usr/bin/sqlite3`. Por eso usamos `dump_sqlite` (Patrón S, online) y no `dump_sqlite_cold` (Patrón S-fría, con downtime). Si en algún _bump_ futuro de imagen se eliminase, el _hook_ falla con un error claro y se conmuta a `dump_sqlite_cold` (10 s de downtime, aceptable de madrugada).

Re-instalar:

```bash
~/homelab/backups/borgmatic/install.sh
sudo /usr/bin/borgmatic --dry-run --verbosity 2 | grep -A2 jellyfin
# debe listar el dump previsto
```

Smoke-test del hook ejecutándolo a mano:

```bash
sudo /etc/borgmatic.d/hooks/dump-databases.sh
ls -la /mnt/hd2t/backups/dumps/jellyfin-*.sqlite.gz
# jellyfin-2026-04-26.sqlite.gz   42M
```

Confirmar que el dump abre como SQLite válido:

```bash
sudo zcat /mnt/hd2t/backups/dumps/jellyfin-*.sqlite.gz \
  | file -
# /dev/stdin: SQLite 3.x database, ...
```

### 2. Añadir el _exclude_ específico al `config.yaml` de Borgmatic

Editar `~/homelab/backups/borgmatic/config.yaml` (la fuente de verdad versionada en git) y añadir las exclusiones específicas de Jellyfin al bloque `exclude_patterns:`:

```yaml
exclude_patterns:
  # ... entradas existentes ...

  # Jellyfin — logs (los activos los cubre el ciclo de rotación interno)
  - /mnt/hd2t/services/jellyfin/config/log

  # Jellyfin — cache de imágenes/trickplay (regenerable, ya cubierto por
  # */cache/* global, se mantiene aquí explícito por claridad).
  - /mnt/hd2t/services/jellyfin/cache
  - /mnt/hd2t/services/jellyfin/transcodes
```

Aplicar:

```bash
~/homelab/backups/borgmatic/install.sh
sudo /usr/bin/borgmatic --dry-run --verbosity 2 \
  | grep -E 'jellyfin|exclude' | head -20
```

### 3. Confirmar que Jellyfin está cubierto por `source_directories`

`source_directories: /mnt/hd2t/services` ya incluye `jellyfin/config/` por inercia (ver `docs/07-backups/02-borgmatic.md`, sección _Por qué incluir el directorio padre y filtrar_). Tras el siguiente _run_ programado (madrugada), Jellyfin aparece en la lista de archives:

```bash
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list --short "$BORG_REPO_LOCAL" | tail -1
'
# pi-2026-04-26T03:30:30

sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL::pi-2026-04-26T03:30:30" \
    | grep jellyfin | head -10
'
# -rw-r--r-- 1000   1000   1234 Apr 26 02:00 mnt/hd2t/services/jellyfin/config/system.xml
# -rw-r----- root   root  44.0M Apr 26 03:30 mnt/hd2t/backups/dumps/jellyfin-2026-04-26.sqlite.gz
# ...
```

### Restauración

El procedimiento es idéntico al **Patrón de restauración común** documentado en `docs/07-backups/03-backup-docker-volumes.md`. En resumen:

1. `docker compose -f ~/homelab/multimedia/docker-compose.yml stop jellyfin`.
2. Mover `/mnt/hd2t/services/jellyfin/config/` a `config.broken-<ts>` (no borrar — preservar 24-48 h por si la restauración tampoco arranca).
3. `borg extract` del archive elegido a `/tmp/restore-$$/`, mover en sitio.
4. Restaurar la SQLite desde el dump del Patrón S si la del archive estuviera dañada (raro):

   ```bash
   sudo gunzip -c /mnt/hd2t/backups/dumps/jellyfin-YYYY-MM-DD.sqlite.gz \
     > /mnt/hd2t/services/jellyfin/config/data/jellyfin.db
   sudo chown 1000:1000 /mnt/hd2t/services/jellyfin/config/data/jellyfin.db
   ```

5. `docker compose -f ~/homelab/multimedia/docker-compose.yml up -d jellyfin`.
6. Esperar al `(healthy)` (puede tardar hasta 3 min si la SQLite es grande y arranca con _index rebuild_).
7. Comprobar dashboard: las bibliotecas, los usuarios y el _watch progress_ deben recuperarse. Si la biblioteca aparece vacía, hacer un _Scan All Libraries_ para repoblar la BD desde los ficheros físicos (la BD se reconstruye conservando metadatos descargados anteriormente).

> **La biblioteca multimedia en `/mnt/hd2t/services/shared/media/` no se respalda** (Categoría C). Si se pierde el disco hd2t, hay que volver a llenar la biblioteca desde la fuente original (descargas, copia en otro NAS, etc.). La BD de Jellyfin restaurada conoce los nombres y metadatos, pero los `.mkv` físicos no están — al primer scan, Jellyfin los marcará como "missing" hasta que reaparezcan.

---

## Verificación

Antes de dar por cerrado este documento:

- [ ] `~/homelab/multimedia/docker-compose.yml` y `~/homelab/multimedia/.env.example` versionados en git; `~/homelab/multimedia/.env` **no** versionado (`.gitignore` activo).
- [ ] `docker compose -f ~/homelab/multimedia/docker-compose.yml ps` muestra `jellyfin` como `(healthy)`.
- [ ] `docker exec jellyfin wget -qO- http://localhost:8096/health` devuelve `Healthy`.
- [ ] `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` acepta el bloque `jellyfin.lan` añadido.
- [ ] `curl -k --resolve jellyfin.lan:443:192.168.1.3 -I https://jellyfin.lan/web/` devuelve `200` directo (Jellyfin sirve el `index.html` del _web client_; sin Authelia delante, no hay redirect a `auth.lan`).
- [ ] `curl -k --resolve jellyfin.lan:443:192.168.1.3 -s https://jellyfin.lan/System/Info/Public | python3 -m json.tool` devuelve el JSON con `"ServerName": "jellyfin"` y `"Version": "10.10.x"`.
- [ ] Login interactivo desde el navegador con la cuenta administrador funciona; tras login se ve el dashboard.
- [ ] Las bibliotecas configuradas escanean: _Dashboard → Libraries_ muestra al menos un ítem reconocido tras dejar un `.mkv` de prueba en `/mnt/hd2t/services/shared/media/movies/`.
- [ ] El log de Jellyfin (`docker logs jellyfin 2>&1 | grep -i 'KnownProxies\|trusted'`) muestra que la cabecera `X-Forwarded-For` se procesa: una petición desde el navegador del PC LAN aparece logueada con la IP del PC, no con `172.20.10.x`.
- [ ] App móvil oficial conectada: `Dashboard → Devices` muestra al menos un dispositivo con _last seen_ reciente.
- [ ] _Hardware acceleration_ está en `None`: `Dashboard → Playback → Transcoding → Hardware acceleration: None` y _Allow encoding in HEVC: OFF_.
- [ ] Dump SQLite generado por `dump-databases.sh`: `sudo ls -la /mnt/hd2t/backups/dumps/jellyfin-$(date +%F).sqlite.gz` existe y `file -` lo identifica como `gzip compressed data` con SQLite dentro.
- [ ] El `Caddyfile` para `jellyfin.lan` lleva `import security-headers`, `import logging` y la cabecera `Permissions-Policy` sobreescrita; **no** lleva `import authelia`.
- [ ] La lista `two_factor` del `access_control.rules` de Authelia **no** menciona `jellyfin.lan` (ni siquiera comentado).
- [ ] Watchtower vigila el contenedor: `docker logs watchtower --tail 50 | grep jellyfin` muestra al menos un check (label `enable: "true"` activo).
- [ ] `stat -c '%U:%G' /mnt/hd2t/services/jellyfin /mnt/hd2t/services/jellyfin/config /mnt/hd2t/services/jellyfin/cache` devuelve `1000:1000` en los tres.
- [ ] `docker exec jellyfin id` muestra `uid=1000 gid=1000 groups=1000,${MEDIA_GID}` (o el GID real de `homelab-media`).

---

## Troubleshooting

### Primer arranque: el contenedor se queda en `starting` indefinidamente

```bash
docker logs jellyfin --tail 50
```

Causas comunes:

- **Permisos del bind mount**: si por error se hizo un `chown -R root:root /mnt/hd2t/services/jellyfin`, el proceso (que corre como `1000:1000`) falla con `Access denied` al intentar crear `data/jellyfin.db`. Restaurar:

  ```bash
  sudo chown -R 1000:1000 /mnt/hd2t/services/jellyfin
  docker compose -f ~/homelab/multimedia/docker-compose.yml restart jellyfin
  ```

- **`/etc/localtime` ausente**: en algunos hosts minimalistas no existe; .NET se queja con `IOException: /etc/localtime not found`. Crear el symlink:

  ```bash
  sudo ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
  ```

- **Imagen mal descargada**: tras un fallo de red durante el `pull`, la imagen puede quedar parcial. `docker rmi jellyfin/jellyfin:10.10 && docker compose -f ~/homelab/multimedia/docker-compose.yml pull jellyfin`.

### "X-Forwarded-For ignorado" / IPs reales no aparecen en el log

Jellyfin loguea `172.20.10.x` (la IP del contenedor de Caddy) en lugar de la IP del cliente. Causa: `KnownProxies` en `network.xml` no incluye la subnet correcta. Comprobar:

```bash
sudo grep -A2 'KnownProxies' /mnt/hd2t/services/jellyfin/config/network.xml
# <KnownProxies>
#   <string>172.20.10.0/24</string>
# </KnownProxies>
```

Si difiere, actualizar `JELLYFIN_TRUSTED_PROXY_SUBNET` en `.env`, editar `network.xml` consecuentemente, y reiniciar Jellyfin.

Si la subnet de la red `homelab` cambió en `docs/02-docker/02-estructura-compose.md` (raro), comprobar:

```bash
docker network inspect homelab --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

### La app móvil dice "Unable to verify the certificate"

La CA local no está importada en el _trust store_ del móvil. Procedimiento en `docs/03-red/04-caddy.md`, sección _Acceso desde móvil_. **No** desactivar la verificación del certificado en la app — eso permite cualquier MITM dentro de la WiFi.

> **Findroid / Jellyfin Mobile** desde Android 7+ requieren el certificado raíz instalado a nivel de "user CA" Y el `network_security_config.xml` de la app que confíe en user CAs. Las versiones recientes de la app oficial de Jellyfin (10.10+) lo configuran correctamente. Si la app es muy antigua, actualizarla.

### "El cliente reproduce con _stuttering_ / vídeo se entrecorta"

Causas, en orden de probabilidad:

1. **Transcoding activo no deseado**. Comprobar en _Dashboard → Playback_: si el indicador muestra _Transcoding_ en lugar de _Direct play_, la Pi 5 no aguanta. Soluciones:
   - Forzar _Direct play_ en el cliente (en la mayoría de apps, _Settings → Playback → Force Direct Play_).
   - Re-codificar el fichero a H.264 + AAC fuera de Jellyfin (`ffmpeg -c:v libx264 ...` en otra máquina).
   - Cambiar de cliente a uno que soporte el códec original (Kodi soporta casi todo nativamente).
2. **Disco USB saturado**. Si `iostat -x 5` muestra `%util` > 90 % en `sd[ab]` (los discos hd2t/hd5t), hay contención. Suele coincidir con un backup de Borgmatic en curso o un `du -sh` sobre la biblioteca. Esperar.
3. **Red WiFi del cliente débil**. El _direct stream_ a 1080p H.264 ronda 5-15 Mbps. Por debajo de eso, _stuttering_. Cambiar el cliente a Ethernet o acercarlo al router.

### "FFmpeg failed to start transcoding" en el log

Causa: Jellyfin intenta transcodificar pero FFmpeg sale con error. Subcausas:

- **Transcoding HW activado por error**: el operador habilitó _VAAPI_ en _Dashboard → Playback → Transcoding_ pensando que la Pi 5 lo soporta. **Volver a `Hardware acceleration: None`** (ver **Decisiones de diseño** → _Transcodificación_).
- **Espacio en disco lleno**: `df -h /mnt/hd2t` muestra `100%`. Liberar `cache/trickplay/` (regenerable) o ampliar `purge_keep_days` de algún servicio.
- **Códec no soportado por FFmpeg de la imagen**: muy raro; la imagen oficial trae FFmpeg con todos los códecs estándar. Sólo aparecería con ficheros muy raros (ej. AV1 en ARM64 con FFmpeg sin `libdav1d`).

### `KnownProxies` ignorado pese a estar en `network.xml`

Síntoma: `network.xml` declara `<KnownProxies><string>172.20.10.0/24</string></KnownProxies>` pero el log sigue marcando IPs internas. Causa típica: Jellyfin esperaba un valor concreto (una IP individual, no una subnet) y el parser silenciosamente lo descarta. Workaround:

```xml
<KnownProxies>
  <string>172.20.10.2</string>     <!-- IP del contenedor de Caddy hoy -->
</KnownProxies>
```

Pinear la IP es frágil (Docker la cambia en cada `up -d`). Mejor solución: mantener la subnet (hay reportes de que `10.10.x` la acepta) y, si no, configurar IP estática para Caddy en su compose con `ipv4_address: 172.20.10.10` (entonces aquí pinear esa IP).

### `Permissions-Policy` rompe la PiP / fullscreen del web client

Síntoma: el botón de _picture-in-picture_ está deshabilitado en el reproductor del navegador. Causa: el bloque `jellyfin.lan` del `Caddyfile` no sobreescribió el `Permissions-Policy` del _snippet_ global (que denega `picture-in-picture`).

Comprobar la cabecera servida:

```bash
curl -k --resolve jellyfin.lan:443:192.168.1.3 \
     -I https://jellyfin.lan/ | grep -i permissions-policy
# Permissions-Policy: camera=(), microphone=(), geolocation=(), picture-in-picture=(self), fullscreen=(self), autoplay=(self)
```

Si falta la sobreescritura, revisar el bloque `jellyfin.lan` y asegurarse de que `header Permissions-Policy "..."` está presente _después_ de `import security-headers`. El último `header` gana.

### El catálogo crece a tamaños desorbitados (`jellyfin.db` > 1 GB)

Causas:

- **Demasiados `IsFolder=0` por carpetas con miles de ficheros pequeños** (raro en una biblioteca de cine; común en _photos library_ con 50 000 fotos). Mitigación: dividir la biblioteca en sub-bibliotecas más pequeñas en _Dashboard → Libraries_.
- **Histórico de _PlaybackSessions_ desproporcionado**. Jellyfin guarda cada sesión de reproducción. Forzar limpieza:

  ```bash
  docker exec -u 1000:1000 jellyfin sqlite3 /config/data/jellyfin.db \
    "DELETE FROM PlaybackSessions WHERE EndTime < datetime('now','-365 days'); VACUUM;"
  ```

- **`metadata/library/` enorme** (cientos de miles de JSON sidecars): cada item de la biblioteca genera un fichero. `find /mnt/hd2t/services/jellyfin/config/metadata -type f | wc -l` da una idea. Si crece sin control, considerar deshabilitar _Save metadata as `.nfo`_ en _Dashboard → Libraries → Display_.

---

## Actualización

### Patches de la línea `10.10.x` (vía Watchtower, automático)

Watchtower opt-in está activo. Cada domingo a las 04:00 UTC, Watchtower comprueba el _digest_ del _tag_ `10.10`; si hay uno nuevo, hace `pull` + `recreate` del contenedor Jellyfin. Sin acción del operador.

Verificar tras un domingo:

```bash
docker logs watchtower --tail 50 | grep jellyfin
# time=... msg="Found new jellyfin/jellyfin:10.10 image"
# time=... msg="Stopping /jellyfin"
# time=... msg="Creating /jellyfin"
```

Si tras la recreación el `(healthy)` no llega en 3 minutos, ir a **Troubleshooting**.

### Bumps de minor (`10.10 → 10.11`, manual)

```bash
# 1. Leer las release notes
xdg-open https://github.com/jellyfin/jellyfin/releases/tag/v10.11.0
# Buscar "Breaking changes" — si toca alguna integración activa,
# planificar el cambio antes del bump.

# 2. Backup completo previo
sudo /usr/bin/borgmatic --verbosity 1
# Verificar que el último archive tiene fecha de hoy:
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list --short "$BORG_REPO_LOCAL" | tail -1
'

# 3. Cambiar el tag y aplicar
$EDITOR ~/homelab/multimedia/.env
# JELLYFIN_IMAGE_TAG=10.11
cd ~/homelab
make pull STACK=multimedia
make up STACK=multimedia

# 4. Vigilar el log durante la migración del schema
docker compose -f ~/homelab/multimedia/docker-compose.yml logs -f jellyfin
# Buscar:
#   [INF] [1] Emby.Server.Implementations.Library: Migrating ...
#   [INF] [1] Emby.Server.Implementations.Library: Migration complete
# Si el log muestra ERROR o el contenedor entra en restart loop, ir a Troubleshooting.

# 5. Validar el dashboard, las bibliotecas y la app móvil
```

### Bumps de _major_ (`10.x → 11.x`)

- Suelen incluir cambios de _schema_ relevantes; planificar la actualización en una ventana de mantenimiento.
- Considerar saltar a `11.0.4` o similar (la versión `.0` a menudo tiene bugs que se arreglan en el primer _patch_).
- Tras el upgrade, ejecutar un _Scan All Libraries_ y comprobar que el _watch progress_ se conserva.

---

## Referencias

- Documentación oficial — Jellyfin Docker: <https://jellyfin.org/docs/general/installation/container/>
- Documentación oficial — `jellyfin/jellyfin` Docker image: <https://hub.docker.com/r/jellyfin/jellyfin>
- Reverse proxy con Jellyfin — `KnownProxies` y `LocalNetworkSubnets`: <https://jellyfin.org/docs/general/networking/index.html>
- Reverse proxy con Caddy — Jellyfin sample: <https://jellyfin.org/docs/general/networking/caddy/>
- Hardware acceleration — estado actual en Pi 5 (issue): <https://github.com/jellyfin/jellyfin/issues/9566>
- Releases del proyecto: <https://github.com/jellyfin/jellyfin/releases>
- Caddy v2 — `reverse_proxy` con WebSocket: <https://caddyserver.com/docs/caddyfile/directives/reverse_proxy>
- Documentos relacionados del homelab:
  - `docs/02-docker/02-estructura-compose.md` — convenciones de stacks, red `homelab`, regla `:ro` en biblioteca multimedia.
  - `docs/03-red/04-caddy.md` — Caddy, CA local, _snippets_ `security-headers` y `logging`.
  - `docs/03-red/02-pihole.md` — DNS local `*.lan`.
  - `docs/04-seguridad/01-authelia.md` — por qué Jellyfin **no** entra en `forward_auth`.
  - `docs/06-almacenamiento/02-samba.md` — _share_ `media` que escribe en la misma carpeta que Jellyfin lee.
  - `docs/07-backups/01-estrategia-backup.md` — biblioteca multimedia como Categoría C (no entra en Borg).
  - `docs/07-backups/02-borgmatic.md` — `source_directories`, `exclude_patterns` global.
  - `docs/07-backups/03-backup-docker-volumes.md` — Patrón S, _hook_ `dump_sqlite jellyfin`.
  - `docs/09-multimedia/02-navidrome.md` (siguiente fase) — servidor de música del mismo stack.
  - `docs/10-descargas/03-sonarr.md` y `docs/10-descargas/04-radarr.md` (siguiente fase) — quién escribe en `services/shared/media/`.
