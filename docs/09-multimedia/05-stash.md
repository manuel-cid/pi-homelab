# Stash (organizador y reproductor multimedia con scraping)

## Descripción

Despliegue de **Stash** como organizador y reproductor multimedia del homelab: cataloga vídeos e imágenes (galerías), enriquece los metadatos vía **scrapers** de la comunidad (CommunityScrapers), permite etiquetado granular (rendimientos, estudios, _tags_, _scenes_, _markers_, _galleries_, _movies_, _groups_), expone una **web UI** moderna (`https://stash.lan`), una **API GraphQL** completa (`/graphql`), un endpoint **HereSphere/DeoVR** para clientes VR y reproduce en _direct play_ los formatos compatibles con el navegador (H.264/AAC nativos; el resto se transcodifica _on-the-fly_ con `ffmpeg`). La biblioteca multimedia vive **íntegramente** en el disco externo dedicado **hd5t** (`/mnt/hd5t/stash/`) — el único servicio del homelab que usa ese disco — y la BD SQLite (`stash-go.sqlite`) más la carpeta de _metadata_ scrapeada viven en **hd2t** (`/mnt/hd2t/services/stash/`) para entrar en el ciclo normal de Borgmatic.

Este documento **se suma al _stack_ `multimedia`** (`~/homelab/multimedia/`) que estrenó `docs/09-multimedia/01-jellyfin.md` y al que `docs/09-multimedia/02-navidrome.md`, `docs/09-multimedia/03-audiobookshelf.md` y `docs/09-multimedia/04-calibre-web.md` añadieron Navidrome, Audiobookshelf y Calibre-Web respectivamente. No se crea un compose nuevo: se añade un servicio `stash` al `~/homelab/multimedia/docker-compose.yml` ya existente y se completan las variables del `.env` correspondiente. Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone Stash en `https://stash.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), el mismo nombre `stash.lan` resuelve a `192.168.1.3` desde dentro del _tailnet_ gracias al _Split DNS_ delegado a Pi-hole.

> **Alcance**: este documento despliega Stash con su autenticación nativa (usuario + contraseña configurados en el primer arranque, **obligatorios** desde el principio porque la web UI los pide explícitamente — _no_ se deja el modo "abierto"), monta la biblioteca en `/data` (mapeo de `/mnt/hd5t/stash/data/`, **read-only** por defecto — Stash sólo lee los ficheros y guarda los metadatos en su SQLite), separa los directorios mutables del propio Stash (`/generated`, `/cache`) en `hd5t` para no saturar `hd2t`, deja el SQLite (`stash-go.sqlite`) y la carpeta de metadata scrapeada en `hd2t` para que entren en Borgmatic, configura el _hook_ Borgmatic listo para hacer dump _online_ del SQLite, y deja documentadas (pero **no** activadas por defecto) la sincronización con CommunityScrapers, la activación de plugins y el endpoint **HereSphere/DeoVR** para VR. **No** delega autenticación a Authelia vía `forward_auth` (rompería la API GraphQL, los clientes VR HereSphere/DeoVR y los _scripts_ que usan _API key_; ver **Decisiones de diseño**). **No** activa Watchtower: Stash es **opt-out** explícito (`docs/02-docker/04-watchtower.md`, sección de servicios con _opt-out_) por las migraciones de _schema_ frecuentes entre versiones. **No** habilita el _file rename / organize_ (`Files → Organize`): mantener la biblioteca en `:ro` evita errores irreversibles. **No** instala _stash-box_ (un servicio aparte de catálogo distribuido); fuera de alcance. **No** importa contenido automáticamente: la biblioteca se rellena por SMB (`docs/06-almacenamiento/02-samba.md`, _share_ `stash` opcional `:ro`), por SFTP / `rsync` directo del operador, o se conecta un disco externo y se copia.

> **Recordatorio de red**: Stash **no se publica al host**. Caddy lo alcanza por DNS interno de Docker (`stash:9999` en la red `homelab`). Pi-hole resuelve `stash.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`). El operador entra siempre por `https://stash.lan/` (LAN) o por el mismo nombre desde el _tailnet_.

> **Categoría de backup (definitiva, escrita aquí)**: la biblioteca de `/mnt/hd5t/stash/data/` es **Categoría D, opción "no respaldar"** (ver `docs/07-backups/01-estrategia-backup.md`, sección _Categoría D_). El operador es consciente del coste de un fallo del disco hd5t — el catálogo SQLite se restaura desde Borg, pero los ficheros físicos se vuelven a ingestar desde la fuente original. El SQLite de Stash y la metadata scrapeada (en `/mnt/hd2t/services/stash/`) **sí** son Categoría A (respaldo diario completo).

---

## Requisitos previos

- `docs/00-hardware/03-preparacion-discos.md` completado: `hd5t` (5 TB) montado en `/mnt/hd5t` con `noatime`, etiqueta `hd5t`, SMART vigilado por `smartd`. **Este es el doc que justifica disco dedicado para Stash**: `hd5t` es de uso único — un fallo o saturación de la biblioteca de Stash no puede arrastrar al resto del homelab.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/stash/{config,metadata}/` y `/mnt/hd5t/stash/{data,generated}/` ya existen con ownership `1000:1000` y modo `0755`. Sólo añadiremos las subramas `cache/` y `blobs/` que aquí se reservan (ambos en `/mnt/hd2t/services/stash/` por simetría con el resto del árbol).
- `docs/09-multimedia/01-jellyfin.md`, `docs/09-multimedia/02-navidrome.md`, `docs/09-multimedia/03-audiobookshelf.md` y `docs/09-multimedia/04-calibre-web.md` completados: el _stack_ `multimedia` (`~/homelab/multimedia/`) ya existe con `docker-compose.yml`, `.env`, `.env.example` y `.gitignore`. La red `homelab` está creada como externa, las variables globales `TZ`, `PUID`, `PGID`, `MEDIA_GID` están rellenas en `~/homelab/.env`, y el _Makefile_ de operación expone `make up STACK=multimedia`.
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada y por defecto desactivada. Stash será **opt-out** explícito (ver **Decisiones de diseño**), coherente con la lista de servicios que se mantienen en _opt-out_ de aquel doc.
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `stash.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile` y la CA local firma `*.lan`. El _snippet_ de `security-headers` denega cámara/micro/geo por defecto; en este documento se sobreescribe `Permissions-Policy` para permitir `picture-in-picture` en el bloque `stash.lan` (la web UI de Stash usa PiP cuando el cliente lo soporta).
- `docs/04-seguridad/01-authelia.md` completado **opcionalmente**: si Authelia ya está montada, en este documento se decide explícitamente **no** poner Stash detrás de `forward_auth`. La lista `two_factor` del `access_control.rules` de Authelia **no incluye** `stash.lan` (ni siquiera comentado).
- `docs/06-almacenamiento/02-samba.md` completado o pendiente: si el operador activa `SAMBA_ENABLE_STASH_SHARE=true` (variable preparada en aquel doc), Samba expone `/mnt/hd5t/stash/data/` como _share_ `stash` en modo `:ro` para `homelab`. Esto permite al operador inspeccionar y rellenar la biblioteca desde un cliente SMB sin pasar por la UI de Stash. La _share_ es opcional; si el operador prefiere SFTP / `rsync` directo, no hay que tocar nada.
- `docs/07-backups/01-estrategia-backup.md` y `docs/07-backups/02-borgmatic.md` completados: el `source_directories` de Borgmatic incluye `/mnt/hd2t/services/stash/{config,metadata}` (preparado de antemano en aquel doc); `/mnt/hd5t/` queda **fuera** del repo Borg por completo (Categoría D, no respaldar la biblioteca).
- `docs/07-backups/03-backup-docker-volumes.md` completado: el bloque del _hook_ `dump-databases.sh` para Stash ya está preparado y comentado. Este doc termina **descomentando** ese bloque.
- Conectividad saliente para descargar la imagen (sólo la primera vez):

  ```bash
  docker pull --platform linux/arm64 stashapp/stash:v0.27.2 >/dev/null && echo OK
  ```

- Que el host **no** tenga ya un servicio escuchando en `:9999` localmente (sólo aplica si en algún _troubleshoot_ se publicara el puerto):

  ```bash
  sudo ss -tulpn '( sport = :9999 )'
  ```

  Salida esperada: vacía. Stash no publica `:9999` al host (Caddy lo alcanza por DNS interno).

- Espacio en `/mnt/hd5t`: la biblioteca propiamente dicha (`/data/`) la dimensiona el operador. **Stash genera además contenido derivado** (sprites, previews, transcodes, _phashes_) en `/generated/`, que puede llegar a ser **5–15 % del tamaño de la biblioteca** si se activan _scene previews_ y _sprites_ a alta resolución. Reservar espacio en consecuencia.

  ```bash
  df -h /mnt/hd5t
  ```

- Espacio en `/mnt/hd2t`: como mínimo **500 MB libres** para `stash-go.sqlite` + `metadata/` scrapeada. Una biblioteca de varios miles de _scenes_ con metadata enriquecida y _performers_ rara vez supera **300 MB** de SQLite + **100 MB** de metadata.

  ```bash
  df -h /mnt/hd2t
  ```

---

## Decisiones de diseño

### Por qué Stash (y no Jellyfin con plugins, MediaPress, Whisparr, ni nada custom)

El homelab necesita un organizador especializado en **catalogar vídeo/imágenes con metadatos enriquecidos** (intérpretes, estudios, fechas, _tags_, _markers_ de tiempo, _scenes_ por _galleries_, _movies_ que agrupan _scenes_…). Cuatro alternativas y por qué se descartan:

| Candidato                  | Por qué se descarta                                                                                                                                                                                                                                                                                                                          |
|----------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Jellyfin** (con plugins) | Excelente para cine/TV/música pero su modelo de _media items_ no encaja: Jellyfin organiza por `Movie` / `Show / Season / Episode`, mientras Stash modela `Scene / Performer / Studio / Tag / Gallery / Marker`. Forzar uno como el otro pierde toda la utilidad del scraping y los _tags_ jerárquicos. Ya hay un Jellyfin desplegado para cine/TV en `docs/09-multimedia/01-jellyfin.md`; Stash es complementario, no sustituto. |
| **MediaPress / WordPress** | Excesivo para uso doméstico y sin _scrapers_ específicos del dominio.                                                                                                                                                                                                                                                                       |
| **Whisparr / Stash-DB-arr**| _Whisparr_ es un fork de Sonarr/Radarr para descarga automática del nicho. Cumpliría la función de _descarga_ pero **no** la de _catalogar y reproducir_ (Whisparr no tiene reproductor ni UI de exploración). Si en una iteración futura se quiere automatizar descargas, Whisparr es el complemento natural — fuera de alcance hoy.   |
| **CherryDB / EroPHP / scripts custom** | Mantenimiento artesanal que no escala. Sin scrapers comunitarios, sin web UI moderna, sin app móvil/VR.                                                                                                                                                                                                                |

Stash gana por:

- **100 % gratis y libre** (AGPL-3.0): web UI moderna (React + GraphQL), administración por usuarios con permisos (desde 0.27 hay sistema multi-usuario), control granular por _tag_/_studio_.
- **Modelo de datos rico**: `Scene` (la unidad básica) ↔ `Performers` ↔ `Studios` ↔ `Tags` (jerárquicos) ↔ `Markers` (puntos de interés en el tiempo) ↔ `Galleries` ↔ `Groups`/`Movies` (colecciones). Permite consultas complejas vía la UI o vía GraphQL.
- **Scrapers comunitarios** (CommunityScrapers): repositorio de _scrapers_ Python/YAML para más de 200 sitios, mantenido en GitHub. Stash lo descubre vía la página _Settings → Metadata Providers_; activar uno es marcar una casilla.
- **Reproductor _on-the-fly_**: el navegador reproduce H.264/H.265/AV1 en _direct play_ cuando el códec es compatible; Stash transcodifica con `ffmpeg` para los demás (pesado en la Pi 5; ver _Transcodificación_ más abajo).
- **API GraphQL completa**: <https://docs.stashapp.cc/in-app-manual/configuration/graphql-api/>. Permite Homepage / Homarr (`docs/12-dashboards/`), bots de Telegram, scripts de mantenimiento, etc.
- **Imagen Docker oficial multi-arch ARM64**: `stashapp/stash`. Multi-arch por defecto. Releases _semver-like_ (`v0.27.0`, `v0.27.1`, `v0.27.2`…). Sin imagen LSIO (sería redundante: la oficial ya integra `ffmpeg` y `s6-overlay`-style entrypoint).
- **Footprint razonable**: ~150–250 MB de RAM idle, Go + SQLite + ffmpeg. Más que Calibre-Web pero comparable a Audiobookshelf. Conviven los cinco servicios del stack `multimedia` en la Pi 5 sin problemas — siempre que **no** se transcodifiquen vídeos pesados de forma simultánea.
- **HereSphere / DeoVR**: Stash habla los protocolos VR de los _headsets_ Oculus/Quest/Vive de forma nativa; los clientes VR descubren el servidor con un par de URLs.

### Imagen y _tag_

- **`stashapp/stash:v0.27.2`** — imagen oficial del proyecto, _tag_ pinneado a una **versión patch concreta** (no major.minor), siguiendo la convención del homelab (`docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`). Multi-arch (`linux/arm64`). Stash publica _tags_ semver-like pero **no** mantiene _tags_ móviles tipo `:v0.27` (a diferencia de Jellyfin, ABS o Calibre-Web). Pinear al patch exacto es la forma natural de mantener control.
- **Por qué no `:latest`**: ese _tag_ se mueve cada vez que sale una _release_; un `docker compose pull` accidental podría introducir una migración irreversible de _schema_ en `stash-go.sqlite` (Stash hace _schema migrations_ con cada _minor_ nuevo).
- **Por qué no `:development`**: ese _tag_ sigue la rama `develop` del proyecto; está construido sobre cada _commit_ y, aunque en general estable, ha tenido regresiones que rompen la BD. No para producción doméstica.
- **Por qué no `:latest-pi`**: ese _tag_ existió en versiones antiguas como variante para Raspberry Pi con `ffmpeg` minimalista; desde `v0.20+` la imagen multi-arch principal incluye `ffmpeg` ARM64 y `:latest-pi` está deprecada.
- **Por qué imagen oficial y no LSIO**: el proyecto Stash mantiene la imagen oficial activamente y el _entrypoint_ es directo (`stash` binario nativo Go). LSIO no publica una imagen alternativa; la oficial es la canónica.

> **Convenio de versionado de Stash**: el proyecto usa _semver_ con _minor bumps_ frecuentes (cada 2–4 meses) que típicamente traen migraciones de _schema_. Vigilar las _release notes_ de cada versión: <https://github.com/stashapp/stash/releases>.

#### Watchtower **opt-out**

Razones (coherentes con la lista de _opt-out_ de `docs/02-docker/04-watchtower.md`):

- **_Schema migrations_ frecuentes**: cada _minor_ (`v0.26 → v0.27`) ejecuta migraciones en `stash-go.sqlite`. Algunas son irreversibles. Un `docker compose pull` automático sin backup previo es _exactamente_ lo que `docs/07-backups/01-estrategia-backup.md` pide evitar.
- **Cambios de comportamiento de scrapers**: cuando un _minor_ cambia el formato de los _scrapers_ Python/YAML, los scrapers comunitarios pueden quedar incompatibles hasta que sus mantenedores los actualicen. Mejor controlar _cuándo_ actualiza el operador.
- **Tag pinneado a patch**: como el _tag_ es `v0.27.2` (no `v0.27`), Watchtower **ni aunque estuviera activo** detectaría una nueva _patch release_ del _tag_ exacto. La actualización es siempre manual.

Etiquetar el contenedor con `com.centurylinklabs.watchtower.enable: "false"` (explícito, no implícito). Coherente con la lista global de `docs/02-docker/04-watchtower.md` y con el criterio aplicado a Nextcloud, MariaDB, Postgres, Home Assistant y Vaultwarden.

> **Bumps de patch o de minor** (`v0.27.2 → v0.27.3` o `v0.27 → v0.28`): se hacen **a mano**, fuera de Watchtower. Cambiar `STASH_IMAGE_TAG=v0.27.3` (o `v0.28.0`) en `~/homelab/multimedia/.env`, leer las _release notes_ del proyecto en GitHub, hacer backup de `stash-go.sqlite` (Borgmatic + dump SQLite) y aplicar `make pull STACK=multimedia && make up STACK=multimedia`. Ver **Actualización**.

### Modo de red: `bridge` (red `homelab`), no `host`

Mismo razonamiento que en Jellyfin, Navidrome, ABS y Calibre-Web: Stash corre en la red `homelab` (`bridge`, `172.20.10.0/24`), Caddy lo alcanza por nombre interno (`stash:9999`), no se publica ningún puerto al host. No hay descubrimiento _multicast_ que necesite atravesar el bridge: los clientes (web, HereSphere, DeoVR) se configuran a mano con `https://stash.lan/` la primera vez y la recuerdan.

### Volumen de la biblioteca: `:ro` (deliberado, distinto de Calibre-Web)

A diferencia de Calibre-Web (donde la biblioteca se monta `:rw` porque la web UI sube y edita ebooks), Stash **no necesita escribir** en la biblioteca:

```yaml
volumes:
  - /mnt/hd5t/stash/data:/data:ro
```

Razones:

- **Stash guarda metadata en SQLite**, no en los ficheros de vídeo/imagen. Los ficheros se quedan _intactos_; lo que se etiqueta, _scrappea_ y se anota va a `stash-go.sqlite` y a la rama `metadata/`.
- **El operador rellena la biblioteca por SMB / SFTP / rsync** desde fuera. Stash sólo lee. Mantenerlo `:ro` evita errores irreversibles (un _bug_ de Stash o un _plugin_ malicioso no puede borrar ni renombrar ficheros).
- **La _feature_ `Files → Organize` queda deshabilitada implícitamente**: esa función pretende renombrar los ficheros según un _template_ (`{performers}/{studio} - {title}.{ext}`). En `:ro` la operación falla con un _error_ explícito en la UI, lo cual es preferible a aceptar y propagar cambios irreversibles.

> **Si el operador quisiera "Organize"**: cambiar el bind mount a `:rw` y aceptar el riesgo. La recomendación operativa es `:ro` por defecto y, si en algún momento se quiere reorganizar la biblioteca, hacerlo a mano por SMB / shell desde el host (más seguro, _undoable_ con `mv` inverso).

### `/generated/` y `/cache/` en `hd5t`, no en `hd2t`

Stash genera **contenido derivado** de la biblioteca:

- **Sprites de _scenes_** (mosaicos para el _scrubber_ del reproductor): ~50–500 KB por _scene_.
- **Previews** (clips MP4 cortos, ~5 s, para _hover preview_): ~100–500 KB por _scene_.
- **Phashes** (hashes perceptuales para detectar duplicados): pocos bytes por _scene_.
- **Transcodes** (cuando una _scene_ no es _direct play_, se transcodifica al vuelo y se cachea): puede llegar a **gigabytes** por _scene_ si el formato origen no es compatible con el navegador.

Para una biblioteca de 1000 _scenes_, `/generated/` puede ocupar **5–50 GB**. Para 10 000 _scenes_, fácilmente **100–500 GB**. Es **_regenerable_ pero costoso** (cada _generated_ asset requiere `ffmpeg` sobre el fichero origen — horas en una Pi 5 para una biblioteca grande).

Decisión: `/generated/` se monta sobre `/mnt/hd5t/stash/generated/` (mismo disco que la biblioteca). Razones:

- **No saturar `hd2t`**: `hd2t` (2 TB) tiene que albergar todos los servicios; meter 100+ GB de _generated_ ahí robaría espacio crítico a Nextcloud, BD, backups…
- **Localidad de I/O**: Stash escribe `/generated/` justo después de leer un fichero de `/data/`; en el mismo disco (hd5t) la I/O es más eficiente que cruzando dos discos USB.
- **Categoría C en Borgmatic**: aunque hd5t no entra en Borg en absoluto (Categoría D no respaldar), si en algún momento se quisiera backup parcial, `/generated/` se excluye porque es regenerable.

`/cache/` es similar pero más pequeño (~tens of MB) y se usa para datos de sesión y previews de la UI. Va junto con `/generated/` en hd5t por simetría.

`/blobs/` (covers, posters scrapeados, imágenes de _performers_): se queda en **hd2t** (`/mnt/hd2t/services/stash/blobs/`). Es **categoría B** (regenerable re-scrapeando, pero tedioso); mantenerlo en hd2t lo mete automáticamente en Borg.

| Ruta en el host                                | Contenido                                                            | Disco | Backup                                 |
|------------------------------------------------|----------------------------------------------------------------------|-------|----------------------------------------|
| `/mnt/hd2t/services/stash/config/`             | `config.yml` + `stash-go.sqlite` (BD del catálogo)                   | hd2t  | **Sí** (Categoría A: filesystem + dump)|
| `/mnt/hd2t/services/stash/metadata/`           | Metadata scrapeada exportable (JSON, YAML)                            | hd2t  | **Sí** (Categoría A)                   |
| `/mnt/hd2t/services/stash/blobs/`              | Covers, posters, imágenes de performers                               | hd2t  | **Sí** (Categoría B)                   |
| `/mnt/hd5t/stash/data/`                        | Biblioteca multimedia (vídeo, imagen)                                 | hd5t  | **NO** (Categoría D, "no respaldar")   |
| `/mnt/hd5t/stash/generated/`                   | Sprites, previews, transcodes, phashes                                | hd5t  | **NO** (Categoría C, regenerable)      |
| `/mnt/hd5t/stash/cache/`                       | Cache de sesión y UI                                                  | hd5t  | **NO** (Categoría E, efímero)          |

### `forward_auth` con Authelia: **NO** para Stash

Tentación natural una vez Authelia está montada: añadir `import authelia` al bloque `stash.lan` del `Caddyfile`. **No se hace**, exactamente por las mismas razones que Jellyfin, Navidrome, ABS y Calibre-Web, con dos agravantes específicos:

- **La API GraphQL** (`/graphql`): el endpoint principal de Stash. Toda la web UI lo consume; bots, scripts, Homepage/Homarr y plugins también. Authentica con **API key** (header `ApiKey: <token>`) o cookie de sesión. Si Caddy intercepta y devuelve `302 Location: https://auth.lan/?rd=...`, el cliente GraphQL recibe HTML en lugar de JSON y rompe el _parser_.
- **HereSphere / DeoVR** (clientes VR): los _headsets_ VR (Oculus Quest, HTC Vive, Valve Index con plugins) se configuran con la URL `https://stash.lan/heresphere` o `https://stash.lan/deovr`. Esos clientes envían _GET_ que esperan JSON con la lista de _scenes_; un _challenge_ HTML de Authelia rompe la integración. Y los _headsets_ VR no tienen _browser_ en condiciones para resolver TOTP de Authelia: el operador queda expulsado.
- **API key** para integraciones (_StashApp scripts_, _r34db_, etc.): mismas razones que ABS y Calibre-Web — esos scripts esperan una respuesta JSON o GraphQL, no HTML de Authelia.
- **Reproductor de vídeo en navegador**: Stash sirve los streams en `/scene/<id>/stream` con `Range` requests para _seeking_. Authelia delante con _session refresh_ desincroniza el _Range_ y el _player_ pierde la conexión a media reproducción.

Solución correcta: **Stash autentica con su sistema nativo** (usuario + contraseña, configurado en el primer arranque vía `STASH_USERNAME`/`STASH_PASSWORD` o, mejor, vía la web UI), con **API key generada en _Settings → Security_** para integraciones. Stash **no** soporta TOTP nativo en `v0.27.x` (limitación conocida; el proyecto lo discute en <https://github.com/stashapp/stash/issues/1395>).

> **Resumen operativo**: el bloque `stash.lan` del `Caddyfile` lleva `import security-headers` y `import logging`, pero **no** `import authelia`. Caddy actúa como _reverse proxy_ "tonto" que termina TLS, propaga `X-Forwarded-*` y deja a Stash la autenticación.

> **Si en el futuro Stash añadiese OIDC**: hay un _open issue_ para soporte OIDC nativo. Cuando llegue, este doc se ampliará para apuntar Stash a Authelia como _provider_ OIDC. Mientras tanto, la auth nativa con API key es suficiente para LAN+VPN.

### `stash-go.sqlite` en SQLite (no MariaDB/Postgres)

Stash **sólo soporta** SQLite y PostgreSQL como _backend_. Misma decisión _upstream_ que ABS y Calibre-Web — y aquí se mantiene SQLite por simplicidad (Postgres requeriría desplegar otro contenedor con su propia BD). Implicaciones:

- **Footprint mínimo**: la BD raramente supera los **300–500 MB** incluso para bibliotecas de decenas de miles de _scenes_.
- **Backups con Patrón S** (`docs/07-backups/03-backup-docker-volumes.md`): la imagen oficial de Stash **incluye `sqlite3` en el _PATH_** (`/usr/bin/sqlite3`, instalado desde `apk` durante el build). Verificable con `docker exec stash which sqlite3`.
- **WAL activo por defecto**: Stash habilita WAL en `stash-go.sqlite` desde `v0.20+` para mejorar la concurrencia. La copia "en caliente" con `cp` directo puede quedar inconsistente: por seguridad, **siempre** se usa `sqlite3 .backup`.

### Transcodificación: por software (FFmpeg en CPU), sin VAAPI

Stash transcodifica con `ffmpeg` cuando una _scene_ no es _direct play_. La Pi 5 transcodifica:

- **H.264 → H.264 (remux)**: trivial, ~10 % CPU.
- **H.265/HEVC → H.264**: pesado, ~80–90 % CPU sostenido por _scene_; una sola sesión satura un _core_ y deja al resto del homelab respirando.
- **AV1 → H.264**: imposible en tiempo real en Pi 5 con software puro (el _decoder_ AV1 hardware del Pi 5 funciona, pero `ffmpeg` no lo aprovecha sin un build especial).

Decisión: **transcodificación habilitada por defecto** pero el operador asume que reproducir un H.265 a 4K va a saturar la Pi 5. Las recomendaciones prácticas son:

- **Mantener la biblioteca en H.264/AAC** siempre que sea posible (re-encode externo a la Pi antes de subir).
- **Aceptar transcodes pesados como _opcionales_**: la web UI muestra un indicador de "transcoding" cuando se activa.
- **No habilitar VAAPI / hardware accel** por las mismas razones que Jellyfin (`docs/09-multimedia/01-jellyfin.md`): el _firmware_ del Pi 5 + `mesa` aún no soportan VAAPI _encode_ de forma fiable.

Para clientes que sí soportan H.265 nativamente (Safari macOS/iOS, navegadores con hardware decode), `direct play` funciona y la Pi 5 ni se entera.

### `/data` con bit `setgid` y grupo `homelab-media`

Aunque la biblioteca de Stash vive en `hd5t` (no comparte disco con el resto de servicios), se mantiene la convención del homelab:

- `/mnt/hd5t/stash/data/` es `1000:1000 0755` (creado en `docs/01-sistema/04-estructura-directorios.md`). Stash dentro del contenedor corre como UID `1000` (mapeado por `user: "${PUID}:${PGID}"`).
- Si el operador activa `SAMBA_ENABLE_STASH_SHARE=true` (`docs/06-almacenamiento/02-samba.md`), Samba expone esa carpeta `:ro`. Como Samba dentro del contenedor también corre con `force user = homelab`, la lectura es coherente.
- **No hace falta `setgid` ni `homelab-media`** aquí: Stash es el único servicio que accede a `/mnt/hd5t/`, y sólo lee. Si en el futuro otro servicio quisiera leer también (ej. Jellyfin con algún subset de la biblioteca), entonces sí habría que aplicar `setgid + homelab-media`. Por ahora, simplificación.

---

## Estructura del _stack_ `multimedia` tras este documento

```
~/homelab/multimedia/
├── docker-compose.yml        # ← extendido (servicio stash añadido)
├── .env                      # ← extendido (variables STASH_*)
├── .env.example              # ← extendido (plantilla de STASH_*)
└── .gitignore                # sin cambios
```

Y en los discos externos, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/stash/
├── config/                   # ← creado por el doc de estructura
│   ├── (vacío al empezar; el primer arranque puebla config.yml + stash-go.sqlite)
├── metadata/                 # ← creado por el doc de estructura
│   └── (vacío al empezar)
├── blobs/                    # ← se crea aquí
└── (sin más subramas)

/mnt/hd5t/stash/
├── data/                     # ← creado por el doc de estructura (biblioteca)
├── generated/                # ← creado por el doc de estructura (sprites/previews/transcodes)
└── cache/                    # ← se crea aquí
```

Verificar / crear los directorios nuevos (`blobs/` y `cache/`) y asegurar permisos (los demás ya están del doc de estructura; este paso es defensivo):

```bash
sudo mkdir -p /mnt/hd2t/services/stash/blobs
sudo mkdir -p /mnt/hd5t/stash/cache

sudo chown -R 1000:1000 /mnt/hd2t/services/stash
sudo chmod 0755 /mnt/hd2t/services/stash
sudo chmod 0755 /mnt/hd2t/services/stash/{config,metadata,blobs}

sudo chown -R 1000:1000 /mnt/hd5t/stash
sudo chmod 0755 /mnt/hd5t/stash
sudo chmod 0755 /mnt/hd5t/stash/{data,generated,cache}
```

> **Ownership de `/mnt/hd5t/stash/`**: ya está fijado por `docs/01-sistema/04-estructura-directorios.md` paso 3 a `1000:1000`. Aquel doc lo recuerda especialmente: hacerlo más tarde, una vez la biblioteca esté poblada con cientos de miles de ficheros, puede tardar horas en USB. Verificar que sigue correcto antes de poblar.

> **Ownership de `/mnt/hd2t/services/stash/`**: ya está fijado por el paso 7 del doc de estructura ("Reasignar ownership de los servicios LinuxServer.io"). Stash no es LSIO pero usa el mismo UID/GID 1000/1000 por convención.

---

## Variables de entorno

Añadir las siguientes líneas al `~/homelab/multimedia/.env.example` (debajo de las ya existentes para Jellyfin, Navidrome, Audiobookshelf y Calibre-Web):

```bash
# --- Stash ----------------------------------------------------------------
# https://github.com/stashapp/stash/releases — bumps de patch y minor a mano
# (NUNCA Watchtower automático: schema migrations entre minors).
STASH_IMAGE_TAG=v0.27.2

# URL pública canónica del servicio. Usada por Stash para construir URLs
# absolutas en la web UI, los enlaces de scene preview y los endpoints
# HereSphere / DeoVR.
STASH_BASE_URL=https://stash.lan

# Puerto interno donde Stash escucha. Por defecto 9999. Caddy resuelve
# stash:9999 por el alias de la red 'homelab'.
STASH_PORT=9999
```

Copiar a `.env` (ya creado por el doc de Jellyfin):

```bash
$EDITOR ~/homelab/multimedia/.env
# Añadir los mismos STASH_* con los valores reales.
```

> **`.env` aquí no contiene secretos**: la contraseña del usuario admin de Stash y la API key se gestionan **dentro de la BD** (en `stash-go.sqlite`, hashed con bcrypt). El operador las configura en la web UI tras el primer arranque. Aun así, se mantiene `.env` con `0600` y fuera de git por consistencia con el resto de _stacks_.

---

## `~/homelab/multimedia/docker-compose.yml` (extensión)

Añadir el siguiente servicio al compose ya existente, **a continuación** del bloque `calibre-web:` y **antes** del bloque `networks:` final:

```yaml
  # ---------------------------------------------------------------------------
  # Stash — organizador y reproductor multimedia (cataloga, scrappea, reproduce).
  # Comparte red 'homelab' con jellyfin, navidrome, audiobookshelf y calibre-web.
  # Caddy alcanza los cinco por nombre interno (jellyfin:8096, navidrome:4533,
  # audiobookshelf:80, calibre-web:8083, stash:9999).
  # Único servicio del homelab que usa el disco hd5t (5 TB dedicado).
  # ---------------------------------------------------------------------------
  stash:
    image: stashapp/stash:${STASH_IMAGE_TAG}
    container_name: stash
    hostname: stash
    restart: unless-stopped
    # Stash dentro del contenedor corre como root por defecto. Forzamos UID/GID
    # del operador (= PUID/PGID del .env global, típicamente 1000:1000) para
    # que los ficheros que Stash escriba en /generated, /cache, /blobs y
    # /metadata queden con ownership coherente con el resto de servicios.
    user: "${PUID}:${PGID}"
    environment:
      TZ: ${TZ}
      # Variables específicas de Stash (todas opcionales; sustituyen al
      # config.yml si se prefiere control vía .env). Ver:
      # https://docs.stashapp.cc/getting-started/installation/docker/
      STASH_STASH:     "/data"        # biblioteca multimedia (read-only)
      STASH_GENERATED: "/generated"   # sprites, previews, transcodes (regenerable)
      STASH_METADATA:  "/metadata"    # metadata scrapeada (JSON/YAML, en hd2t)
      STASH_CACHE:     "/cache"       # cache de UI/sesión (regenerable, en hd5t)
      STASH_BLOBS:     "/blobs"       # covers, posters, performer images (en hd2t)
      STASH_PORT:      "${STASH_PORT}"
      # Stash respeta X-Forwarded-* cuando viene detrás de un reverse proxy.
      # Documentado en https://docs.stashapp.cc/networking/reverse-proxies/.
      # No hace falta variable adicional — Stash detecta los headers y los
      # usa para construir URLs absolutas y para registrar la IP real.
    volumes:
      # Configuración + BD SQLite (hd2t — entra en Borgmatic).
      - /mnt/hd2t/services/stash/config:/root/.stash
      # Metadata scrapeada exportable (hd2t — Borg).
      - /mnt/hd2t/services/stash/metadata:/metadata
      # Blobs: covers, posters, performer images (hd2t — Borg).
      - /mnt/hd2t/services/stash/blobs:/blobs
      # Biblioteca multimedia: SOLO LECTURA (Stash no necesita escribir aquí).
      - /mnt/hd5t/stash/data:/data:ro
      # Contenido derivado (sprites, previews, transcodes): hd5t,
      # regenerable, fuera de Borg.
      - /mnt/hd5t/stash/generated:/generated
      # Cache de UI/sesión: hd5t, regenerable, fuera de Borg.
      - /mnt/hd5t/stash/cache:/cache
      # Hora del host (Stash escribe timestamps en stash-go.sqlite).
      - /etc/localtime:/etc/localtime:ro
    networks:
      homelab:
        aliases:
          - stash         # Caddy resuelve 'stash:9999' por este alias
    labels:
      homelab.stack: "multimedia"
      homelab.backup: "true"   # /mnt/hd2t/services/stash entra en Borgmatic
      # Opt-OUT explícito: schema migrations entre minors NUNCA automáticas.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      # Stash expone /healthz desde v0.20+. Devuelve 200 OK con cuerpo "OK"
      # cuando el server está listo y la BD abierta. Antes de eso, devuelve
      # 503 Service Unavailable.
      test:
        - CMD-SHELL
        - "wget -qO- --tries=1 --timeout=5 http://localhost:${STASH_PORT}/healthz | grep -q OK || exit 1"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s   # primer arranque: ~30-60 s (Go bin + ffmpeg + BD init)
    # Sin 'ports:'. Caddy alcanza Stash por DNS interno.
    # Sin mem_limit: Stash idle ~150-250 MB; durante un scan masivo o un
    # transcode de H.265 sube a ~700 MB - 1.5 GB sostenido. Sin tope explícito
    # para no estrangular escaneos largos. Si la Pi 5 entra en thrashing,
    # imponer mem_limit: 2g aquí y revisar tras unos días.
```

Notas de diseño:

- **`user: "${PUID}:${PGID}"`**: a diferencia de las imágenes LSIO (que arrancan como root y _drop_ a `abc`), la imagen oficial de Stash respeta la directiva `user:` directamente. Forzar `1000:1000` asegura que los ficheros nuevos en `/generated`, `/cache`, `/blobs` y `/metadata` queden con ownership coherente para el operador.
- **`/data:ro`**: deliberado y explícito. Ver **Decisiones de diseño** → _Volumen de la biblioteca_.
- **Sin `ports:`**. Caddy alcanza Stash por DNS interno (`stash:9999`). Si el operador necesita acceso directo durante un _troubleshooting_, puede `docker exec -it stash wget -qO- http://localhost:9999/healthz`.
- **`start_period: 90s`**: el primer arranque tarda ~30-60 s (binario Go arrancando, init de SQLite con WAL, comprobaciones de filesystem en `/generated`). Margen holgado.
- **`/healthz` como _liveness probe_**: público (sin autenticación), siempre devuelve `200` cuando el server está listo. Documentado en <https://docs.stashapp.cc/in-app-manual/configuration/healthcheck/>.
- **Watchtower opt-out**: `com.centurylinklabs.watchtower.enable: "false"` explícito. Razones explicadas en **Decisiones de diseño** → _Imagen y tag_.
- **Sin `mem_limit`** por defecto: comentario explica cuándo imponerlo. Ver _Troubleshooting_ si la Pi 5 entra en _thrashing_ durante un scan.

---

## Despliegue

### Levantar el servicio

```bash
cd ~/homelab/multimedia
docker compose --env-file ../.env --env-file .env config | grep -A2 stash   # validar
docker compose --env-file ../.env --env-file .env up -d stash
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=multimedia
```

> `make up` aplica todo el stack; si Jellyfin, Navidrome, ABS y Calibre-Web ya estaban arriba, Compose los deja como estaban y sólo crea/recrea el contenedor `stash`.

Vigilar el primer arranque (tarda ~30-60 s):

```bash
docker compose -f ~/homelab/multimedia/docker-compose.yml logs -f stash
# ...
# stash  | time="..." level=info msg="stash version: v0.27.2 - ..."
# stash  | time="..." level=info msg="using config file: /root/.stash/config.yml"
# stash  | time="..." level=info msg="performing migrations..."
# stash  | time="..." level=info msg="open() initialized DB at /root/.stash/stash-go.sqlite"
# stash  | time="..." level=info msg="HTTP and websocket server running on :9999"
```

Verificar que el contenedor está `(healthy)`:

```bash
docker compose -f ~/homelab/multimedia/docker-compose.yml ps stash
# NAME    STATUS                  PORTS
# stash   Up X seconds (healthy)
```

> El `(healthy)` lo otorga el _healthcheck_ que confirma que `/healthz` responde `200 OK`. Si tras 90 s sigue `starting`, ir a **Troubleshooting** → primer arranque.

### Caddy: bloque `stash.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque (insertar tras `radarr.lan` para mantener orden alfabético, o tras `sonarr.lan` cuando lleguen — por ahora, al final del archivo de bloques `*.lan`):

```caddy
stash.lan {
    tls internal
    import security-headers
    import logging

    # La web UI de Stash usa Picture-in-Picture cuando el cliente lo soporta.
    # El snippet security-headers.caddy denega 'picture-in-picture' por defecto;
    # aquí lo permitimos explícitamente para este host.
    header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=(), picture-in-picture=(self)"

    # Subida de imágenes/blobs grandes desde la web UI: covers de gran
    # resolución, performer images. Subimos el límite a 100 MB (default
    # Caddy es 100 MB pero lo dejamos explícito).
    request_body {
        max_size 100MB
    }

    reverse_proxy stash:9999 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        # WebSocket para la barra de progreso en escaneos / generates en
        # tiempo real. Caddy soporta upgrade automáticamente; documentado
        # explícitamente para futuros mantenedores.
        # Stash usa WebSocket en /graphql (subscriptions) y en /minio (no
        # aplicable aquí — minio es una variable interna del UI, no
        # endpoint).
        transport http {
            keepalive 60s
            # Stream de vídeo con seek (Range requests) puede ser largo.
            response_header_timeout 300s
            # Streams de vídeo grandes: sin tope para read.
            read_buffer 16KB
        }
    }
}
```

Validar y recargar Caddy:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload  --config /etc/caddy/Caddyfile
```

Probar (la CA local debe estar importada en el navegador, ver `docs/03-red/04-caddy.md`):

```bash
curl -k --resolve stash.lan:443:192.168.1.3 \
     -s -o /dev/null -w '%{http_code}\n' https://stash.lan/healthz
# 200

curl -k --resolve stash.lan:443:192.168.1.3 \
     -s -o /dev/null -w '%{http_code}\n' https://stash.lan/
# 200  (la web UI de Stash responde 200 sin auth en la página inicial;
#       la propia UI pide login después en el cliente JS)
```

Y desde el navegador: `https://stash.lan/` → la web UI de Stash muestra la pantalla de **setup wizard** (la primera vez) o el formulario de **login** (en arranques posteriores).

---

## Configuración tras primer arranque

### Setup wizard inicial (paso obligatorio)

Stash arranca **sin usuario admin**. La primera vez, la web UI muestra un wizard que pide:

1. **Welcome screen** → _Next_.
2. **Setup Paths**: Stash propone rutas por defecto. Como ya las hemos configurado vía `STASH_*` en el compose, **dejar los valores tal como aparecen** (Stash los ha leído del entorno):
   - **Stash directories**: `/data` (read-only)
   - **Generated**: `/generated`
   - **Metadata**: `/metadata`
   - **Cache**: `/cache`
   - **Blobs**: `/blobs`
3. **Configuration → Authentication**: pulsar **Yes, set up authentication** (es **obligatorio** porque la UI quedará accesible vía Caddy desde la LAN/Tailscale).
   - **Username**: `admin` (o el nombre preferido).
   - **Password**: una contraseña robusta. Stash la hashea con bcrypt en `stash-go.sqlite`.
   - **Confirm Password**: repetir.
4. **Finish** → la web UI redirige al login.

> **Por qué la auth es **obligatoria** desde el primer arranque**: aunque la red sea LAN+Tailscale, dejar un Stash abierto sin auth significa que cualquier dispositivo de la WiFi (incluido un IoT comprometido) puede leer toda la biblioteca por la API GraphQL. **No saltar este paso**.

### Generar API key (para integraciones)

Para Homepage / Homarr / scripts / clientes VR que no soporten auth interactiva:

1. Login con la cuenta admin.
2. _Settings (icono engranaje) → Security_.
3. **Generate API Key** → copiar la key larga (formato `eyJ...`-style JWT-like).
4. Guardar la key en Vaultwarden (cuando exista; mientras tanto en un papel/llavero).

> **Uso**: la API key se pasa como header `ApiKey: <key>` en cada request a `/graphql` o `/api/...`. Equivale a una cuenta de servicio.

### Activar CommunityScrapers (opcional pero recomendado)

Stash en _vanilla_ trae sólo unos pocos scrapers oficiales. Para enriquecer la metadata, instalar el repositorio comunitario:

1. _Settings → Metadata Providers_.
2. **Available Scrapers** → buscar **CommunityScrapers**.
3. **Install** → Stash descarga el repo desde <https://github.com/stashapp/CommunityScrapers> y lo coloca en `/root/.stash/scrapers/`.
4. Tras la instalación, los scrapers individuales aparecen en la lista de _Scrape With_ de cada _scene_/_performer_.

> **Actualizaciones de scrapers**: el repo se actualiza con frecuencia. Revisar mensualmente _Settings → Metadata Providers → Update_ para refrescar los scrapers a su última versión.

> **Scrapers de pago / privados**: Stash soporta scrapers individuales fuera de CommunityScrapers (ficheros `.yml` en `/root/.stash/scrapers/`). El operador los añade a mano si los necesita; este doc no los lista.

### Configurar la biblioteca y ejecutar el primer scan

1. _Settings → Library → Stashes_.
2. Stash debería ya mostrar `/data` como _stash directory_ (definido en `STASH_STASH`). Si no, **Add stash directory** → `/data`.
3. **Save**.
4. _Settings → Tasks_ → **Scan**.
   - **Generate phashes (perceptual hashes)**: ✓ (para detección de duplicados).
   - **Generate sprites (scrubber thumbnails)**: ✓ (mejora la UX).
   - **Generate previews (hover preview clips)**: opcional, **pesa**.
   - **Scan & generate covers**: ✓.
5. **Run Scan**.

El scan inicial de una biblioteca grande tarda **horas** en una Pi 5 con disco USB:

- **5 000 _scenes_**: ~2-4 horas (sólo scan + phash).
- **5 000 _scenes_ con sprites + previews**: **8-24 horas** (cada preview es un `ffmpeg -ss ... -t 5` por scene).

Vigilar el progreso en _Tasks → Job Queue_ o desde el log:

```bash
docker logs stash --tail 100 -f | grep -i 'scanning\|generating\|complete'
```

> **Recomendación**: ejecutar el scan completo (con previews) **una sola vez**, idealmente de noche. Re-scans futuros (cuando se añade contenido) sólo procesan los nuevos.

### Configurar HereSphere / DeoVR (opcional)

Para un _headset_ VR con app HereSphere o DeoVR:

1. En el headset, abrir la app HereSphere/DeoVR.
2. **Add Server** → URL: `https://stash.lan/heresphere` (o `/deovr`).
3. **Username** + **Password** (las del admin de Stash, o crear un usuario adicional con menos permisos cuando Stash 0.28+ tenga multi-user maduro).
4. Importar la CA local en el headset (Quest 2/3: Settings → System → CA Certs; instrucciones específicas por modelo). Sin esto, el _headset_ rechaza el TLS interno.
5. La app debería listar las _scenes_ etiquetadas con `vr` o que tengan formato compatible.

> **Si el headset no acepta CA local**: como _workaround_, añadir una entrada `stash.tailnet.ts.net` al MagicDNS de Tailscale y usar el certificado de Tailscale (ver `docs/03-red/05-tailscale.md`, sección _tailscale cert_) en lugar de la CA local.

### Configurar plugins (opcional)

Stash soporta plugins en JS/Python para extender funcionalidad:

1. _Settings → Plugins → Available Plugins_.
2. Plugins comunes:
   - **Path Parser**: extrae metadata del nombre del fichero (sin necesidad de scrapear).
   - **DupFinder**: detecta duplicados por phash.
   - **Phoenix Adult**: scraper unificado para sitios de adult.
3. **Install** → Stash los descarga a `/root/.stash/plugins/`.

> **Plugins son código que ejecuta el servidor**: revisar el código antes de instalar plugins de fuentes desconocidas. Los del repo oficial CommunityScrapers están razonablemente revisados.

### Configurar reproducción y transcodificación

_Settings → Interface → Scene Player_:

- **Auto-start video**: opcional (a gusto).
- **Loop scene**: opcional.
- **Show scene scrubber**: ✓ (usa los sprites generados).
- **Always start with subtitles**: opcional.

_Settings → System → FFmpeg_:

- **Transcoding strategy**: `Auto` (Stash decide cuándo transcodificar).
- **Force-transcode codec**: dejar vacío (usa el que Stash detecte).
- **Hardware acceleration**: dejar **deshabilitado** (mismas razones que Jellyfin; ver `docs/09-multimedia/01-jellyfin.md` → _Transcodificación por hardware_).

> **Cómo medir el coste real de un transcode en Pi 5**: con una _scene_ H.265 4K abierta en el navegador, ver `docker stats stash` desde otra terminal. Si la columna `CPU %` se queda sostenidamente por encima de **350 %** (3.5 cores de los 4 disponibles), la Pi 5 está al límite y ningún otro servicio multimedia podrá responder mientras dure el transcode.

### Multi-usuario (opcional, desde v0.27)

Stash 0.27 introdujo soporte multi-usuario (limitado: sin permisos granulares aún). Para añadir un segundo usuario:

1. _Settings → Security → Users_ → **Add User**.
2. **Username** + **Password**.
3. **Role**: por ahora todos son admin equivalentes (limitación 0.27.x; el roadmap habla de roles granulares para 0.28+).

> **Recomendación**: hasta que los roles granulares estén disponibles, mantener un único admin y compartir las credenciales **sólo** con personas de absoluta confianza. Como _workaround_, generar **una API key por consumidor** (ver _Generar API key_) y, si en el futuro hace falta revocar, regenerar la key del admin (rompe todas las integraciones, requiere actualizar Homepage/Homarr).

---

## Bibliotecas y _tags_

### Estructura recomendada de la biblioteca

Stash **no impone estructura**: detecta los ficheros recursivamente bajo `/data/` y los identifica por su _scene file path_ + un hash MD5 + un OS hash. La organización es libre. Patrones razonables:

```
/mnt/hd5t/stash/data/
├── Studio Name/
│   ├── 2024-04-15 - Scene Title.mp4
│   ├── 2024-04-15 - Scene Title.jpg            # cover, opcional
│   └── ...
├── Performer Name/
│   ├── ...
└── _galleries/                                  # imágenes (galleries)
    ├── 2024-04-15 - Photoset Title/
    │   ├── 001.jpg
    │   ├── 002.jpg
    │   └── ...
```

> **Stash escanea recursivamente**: la profundidad no importa. Lo único que importa para el rendimiento es que cada fichero sea identificable por un hash (Stash calcula MD5 al escanear; es la operación más cara — minutos por TB en USB 3.0).

### Formatos soportados

Stash acepta los siguientes formatos:

- **Vídeo**: `.mp4`, `.mkv`, `.avi`, `.wmv`, `.mov`, `.flv`, `.webm`, `.m4v`, `.ts`, `.mts`, `.m2ts`, `.vob`. Direct play en navegador para H.264/AAC y H.265 en Safari.
- **Imagen / gallery**: `.jpg`, `.jpeg`, `.png`, `.webp`, `.gif`. Se agrupan en _galleries_ por carpeta o por archivo `.zip`/`.cbz`.
- **Subtítulos**: `.srt`, `.vtt` (junto al fichero de vídeo, mismo basename: `scene.mp4` + `scene.srt`).

> **Formatos no soportados**: `.iso` (extraer primero), `.divx`/`.xvid` (raros y mal soportados — re-encode a H.264 antes de subir).

### Forzar un re-scan / actualización

Útil tras añadir contenido manualmente por SMB o tras cambiar la metadata desde otra herramienta:

- _Tasks → Scan_ → escanea sólo cambios desde el último scan (rápido).
- _Tasks → Scan → Use file metadata_ → relee phash + sprite (más lento, sólo si se sospecha corrupción).
- _Tasks → Identify_ → re-identifica scenes contra los scrapers (consulta endpoints externos; respetar _rate limits_).

> **Watcher de filesystem**: Stash **no** observa el directorio de la biblioteca con `inotify` por defecto. Si se añade un fichero **manualmente**, no aparece en la web UI hasta que se hace **Scan**. Hay un plugin `Filesystem Watcher` en CommunityScrapers que automatiza esto (opcional).

---

## Almacenamiento

Tras el primer arranque y un scan inicial, los árboles relevantes quedan así:

```
/mnt/hd2t/services/stash/
├── config/
│   ├── config.yml                     # configuración del servidor
│   ├── stash-go.sqlite                # BD del catálogo
│   ├── stash-go.sqlite-wal            # WAL (Write-Ahead Log)
│   ├── stash-go.sqlite-shm            # shared memory de SQLite
│   ├── scrapers/                      # CommunityScrapers, si se instaló
│   ├── plugins/                       # plugins, si se instalaron
│   └── icon-cache/                    # iconos UI
├── metadata/
│   ├── scenes/<hash>.json             # metadata exportable por scene (opcional)
│   ├── performers/<id>.json           # metadata exportable por performer
│   └── ...
└── blobs/
    ├── covers/<hash>.jpg              # cover art
    ├── performers/<id>.jpg            # performer images
    └── ...

/mnt/hd5t/stash/
├── data/                              # ← biblioteca multimedia (read-only desde Stash)
│   └── ...
├── generated/
│   ├── sprites/<hash>.jpg             # sprite del scrubber
│   ├── sprites/<hash>.vtt             # WebVTT con coordenadas del sprite
│   ├── previews/<hash>.mp4            # preview de hover
│   ├── transcodes/<hash>.mp4          # transcodes cacheados
│   ├── markers/<hash>_<frame>.mp4     # clips de marker
│   └── tmp/                           # ficheros temporales de FFmpeg
└── cache/
    └── ...                            # cache de UI, regenerable
```

| Ruta                                              | Permisos     | Contenido                                                           |
|---------------------------------------------------|--------------|---------------------------------------------------------------------|
| `/mnt/hd2t/services/stash/`                       | `1000:1000 0755` | Raíz del bind mount `/root/.stash`                                  |
| `/mnt/hd2t/services/stash/config/`                | `1000:1000 0755` | Config + BD                                                         |
| `/mnt/hd2t/services/stash/config/stash-go.sqlite` | `1000:1000 0664` | BD SQLite del catálogo                                              |
| `/mnt/hd2t/services/stash/metadata/`              | `1000:1000 0755` | Export exportable (Categoría A)                                     |
| `/mnt/hd2t/services/stash/blobs/`                 | `1000:1000 0755` | Covers/posters scrapeados (Categoría B)                             |
| `/mnt/hd5t/stash/data/`                           | `1000:1000 0755` | Biblioteca multimedia (Categoría D, no respaldar)                   |
| `/mnt/hd5t/stash/generated/`                      | `1000:1000 0755` | Sprites, previews, transcodes (Categoría C, regenerable)            |
| `/mnt/hd5t/stash/cache/`                          | `1000:1000 0755` | Cache de UI (Categoría E, efímero)                                  |

> **`stash-go.sqlite-wal` y `-shm`**: ficheros normales del modo WAL de SQLite. Se respaldan junto al `.sqlite` cuando se hace `cp` (no recomendable; ver _Backup_ abajo) o se descartan cuando se hace `sqlite3 .backup` (recomendado, ya que `.backup` consolida WAL antes de copiar).

---

## Backup

Patrón S (online, vía `sqlite3 .backup`) sobre `stash-go.sqlite`, más Patrón F (filesystem-only) sobre `metadata/` y `blobs/`. La biblioteca de `/mnt/hd5t/stash/data/` queda **excluida totalmente** del repo Borg (Categoría D, "no respaldar la biblioteca").

### 1. Descomentar el bloque de Stash en `dump-databases.sh`

Editar `~/homelab/backups/borgmatic/hooks/dump-databases.sh` y descomentar la línea que `docs/07-backups/03-backup-docker-volumes.md` dejó preparada:

```diff
 # --- Stash (SQLite + metadata) — docs/09-multimedia/05-stash.md
-# dump_sqlite stash stash /root/.stash/stash-go.sqlite
-# El árbol /mnt/hd2t/services/stash/{config,metadata}/ entra como source_directory.
+dump_sqlite stash stash /root/.stash/stash-go.sqlite
+# El árbol /mnt/hd2t/services/stash/{config,metadata,blobs}/ entra como
+# source_directory. La biblioteca /mnt/hd5t/stash/ queda fuera (Categoría D).
```

> **¿La imagen oficial de Stash trae `sqlite3`?**: sí; la imagen `stashapp/stash` instala `sqlite3` desde Alpine `apk` en el _Dockerfile_ del proyecto. `docker exec stash which sqlite3` devuelve `/usr/bin/sqlite3`. Si en algún _bump_ futuro se eliminase, el _hook_ falla con un error claro y se conmuta a `dump_sqlite_cold` (5 s de _downtime_, aceptable de madrugada).

Re-instalar:

```bash
~/homelab/backups/borgmatic/install.sh
sudo /usr/bin/borgmatic --dry-run --verbosity 2 | grep -A2 stash
# debe listar el dump previsto (stash-go.sqlite).
```

Smoke-test del hook ejecutándolo a mano:

```bash
sudo /etc/borgmatic.d/hooks/dump-databases.sh
ls -la /mnt/hd2t/backups/dumps/stash-$(date +%F).sqlite.gz
# stash-2026-04-26.sqlite.gz       45M
```

Confirmar que el dump abre como SQLite válido:

```bash
sudo zcat /mnt/hd2t/backups/dumps/stash-$(date +%F).sqlite.gz | file -
# /dev/stdin: SQLite 3.x database, ...
```

### 2. Asegurar que `hd5t` queda fuera del repo Borg

Editar `~/homelab/backups/borgmatic/config.yaml` y verificar que **no** hay ninguna entrada de `source_directories` que apunte a `/mnt/hd5t/`:

```yaml
source_directories:
  - /mnt/hd2t/services
  - /mnt/hd2t/services/stash      # explícito, ya está cubierto por el padre
  # NUNCA añadir aquí /mnt/hd5t/* — Categoría D, no respaldar la biblioteca.
```

Y añadir, **por defensa en profundidad**, una exclusión explícita por si el operador en algún momento expandiese `source_directories`:

```yaml
exclude_patterns:
  # ...patterns existentes...
  - '*/cache/*'
  - '*/log/*'
  # Stash: la biblioteca y los assets generados NO entran en Borg.
  # Aunque /mnt/hd5t/ no está en source_directories, este exclude actúa de
  # red de seguridad si alguien lo añadiera por error.
  - '/mnt/hd5t/**'
  # Si en algún backup futuro se añadiese hd5t, mantener al menos el
  # /generated/ excluido (regenerable):
  - '/mnt/hd5t/stash/generated/**'
  - '/mnt/hd5t/stash/cache/**'
```

> **Por qué un `**` redundante**: la primera línea (`/mnt/hd5t/**`) excluye todo el disco. Las otras dos son explícitas para que, si en el futuro un operador (o un script) elimina la primera, las segundas sigan protegiendo lo realmente regenerable. Defensa en profundidad — el coste es 0.

Validar:

```bash
sudo borgmatic config validate
```

### 3. Confirmar que la rama de hd2t está cubierta

`source_directories: /mnt/hd2t/services` ya incluye `stash/` por inercia (ver `docs/07-backups/02-borgmatic.md`, sección _Por qué incluir el directorio padre y filtrar_). El efecto neto:

- ✅ `/mnt/hd2t/services/stash/config/stash-go.sqlite` — backup del filesystem (la versión "viva") + dump _online_ vía Patrón S.
- ✅ `/mnt/hd2t/services/stash/config/scrapers/` — backup (CommunityScrapers, regenerable pero pequeño).
- ✅ `/mnt/hd2t/services/stash/config/plugins/` — backup (regenerables pero pequeños).
- ✅ `/mnt/hd2t/services/stash/metadata/` — backup (metadata exportable, _Categoría A_).
- ✅ `/mnt/hd2t/services/stash/blobs/` — backup (covers + performer images, _Categoría B_).
- ❌ `/mnt/hd5t/**` — excluido totalmente.

Tras el siguiente _run_ programado (madrugada), Stash aparece en la lista de archives:

```bash
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL::pi-$(date +%F)T03:30:30" \
    | grep -E 'stash' | head -10
'
# -rw-rw-r-- 1000 1000 45M Apr 26 03:30 mnt/hd2t/services/stash/config/stash-go.sqlite
# -rw-r----- root root 45M Apr 26 03:30 mnt/hd2t/backups/dumps/stash-2026-04-26.sqlite.gz
# drwxr-xr-x 1000 1000  0  Apr 26 03:30 mnt/hd2t/services/stash/metadata
# drwxr-xr-x 1000 1000  0  Apr 26 03:30 mnt/hd2t/services/stash/blobs
# ...
```

### Restauración

Procedimiento idéntico al **Patrón de restauración común** documentado en `docs/07-backups/03-backup-docker-volumes.md`. En resumen:

1. `docker compose -f ~/homelab/multimedia/docker-compose.yml stop stash`.
2. Mover `/mnt/hd2t/services/stash/` a `<dir>.broken-<ts>` (preservar 24-48 h).
3. `borg extract` del archive elegido a `/tmp/restore-$$/`, mover en sitio.
4. Restaurar la SQLite desde el dump si la del archive estuviese dañada (raro):

   ```bash
   sudo gunzip -c /mnt/hd2t/backups/dumps/stash-YYYY-MM-DD.sqlite.gz \
     > /mnt/hd2t/services/stash/config/stash-go.sqlite
   sudo chown 1000:1000 /mnt/hd2t/services/stash/config/stash-go.sqlite
   ```

5. **La biblioteca de `/mnt/hd5t/stash/data/` NO se restaura desde Borg** (no está respaldada). Se recupera:
   - **Si el disco hd5t falla físicamente**: el operador re-ingesta desde la fuente original (otro disco externo, _purchases_, _re-downloads_).
   - **Si el disco hd5t sigue intacto** y sólo se ha corrompido la BD: la biblioteca de ficheros sigue ahí; tras restaurar la BD, Stash relee la metadata.

6. `docker compose -f ~/homelab/multimedia/docker-compose.yml up -d stash`.
7. Esperar al `(healthy)` (típicamente <90 s).
8. Comprobar UI: usuarios, _scenes_, _performers_, _tags_, _markers_, _galleries_, _movies_/_groups_ deben recuperarse. Si hay _scenes_ listadas en la BD pero los ficheros en `/data/` faltan (porque hd5t se perdió), Stash las muestra con un icono de "missing file" hasta que reaparezcan.

> **La biblioteca no se respalda por defecto** (Categoría D, opción "no respaldar"). Si se pierde el disco hd5t y no hay copia externa, el catálogo (`stash-go.sqlite`) se restaura pero sin los ficheros físicos. Cada _scene_ queda marcada como "missing file" y el operador re-ingesta desde la fuente original.

> **Si en el futuro el operador cambia de opinión** y quiere replicar la biblioteca a un `hdc` USB rotativo (opción 2 de Categoría D) o a una _Storage Box_ Hetzner (opción 3): documentar el procedimiento aquí y crear un nuevo _stack_ Borg dedicado (NO mezclar con el repo de Categoría A, ver `docs/07-backups/01-estrategia-backup.md`).

---

## Verificación

Antes de dar por cerrado este documento:

- [ ] `~/homelab/multimedia/docker-compose.yml` extendido con el servicio `stash` y versionado en git; `~/homelab/multimedia/.env.example` extendido con `STASH_*`; `~/homelab/multimedia/.env` con valores reales (no versionado).
- [ ] `docker compose -f ~/homelab/multimedia/docker-compose.yml ps` muestra `stash` como `(healthy)`.
- [ ] `docker exec stash wget -qO- http://localhost:9999/healthz` devuelve `OK`.
- [ ] `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` acepta el bloque `stash.lan` añadido.
- [ ] `curl -k --resolve stash.lan:443:192.168.1.3 https://stash.lan/healthz` devuelve `200` y cuerpo `OK` sin redirect (sin Authelia delante).
- [ ] El setup wizard se completa: cuenta admin creada con contraseña robusta (no default), authentication activada en `Settings → Security → Require Authentication`.
- [ ] `stash-go.sqlite` existe en `/mnt/hd2t/services/stash/config/stash-go.sqlite` con permisos `1000:1000 0664`.
- [ ] El _stash directory_ `/data` está configurado en _Settings → Library → Stashes_ y un _Scan_ test sobre una scene de prueba completa con `cover` y `phash` generados.
- [ ] El log de Stash (`docker logs stash 2>&1 | grep -iE 'remote|forwarded'`) muestra que `X-Forwarded-For` se procesa: una petición desde el navegador del PC LAN aparece logueada con la IP del PC, no con `172.20.10.x`.
- [ ] Dump SQLite generado por `dump-databases.sh`: existe `/mnt/hd2t/backups/dumps/stash-$(date +%F).sqlite.gz`, identificable como SQLite por `file -`.
- [ ] El `Caddyfile` para `stash.lan` lleva `import security-headers`, `import logging` y la línea de `Permissions-Policy` con `picture-in-picture=(self)`; **no** lleva `import authelia`.
- [ ] La lista `two_factor` del `access_control.rules` de Authelia **no** menciona `stash.lan` (ni siquiera comentado).
- [ ] El compose tiene `com.centurylinklabs.watchtower.enable: "false"` (opt-out explícito); `docker logs watchtower --tail 50 | grep stash` **no** muestra a Stash en la lista de contenedores vigilados.
- [ ] `stat -c '%U:%G' /mnt/hd2t/services/stash` devuelve `1000:1000`.
- [ ] `stat -c '%U:%G' /mnt/hd5t/stash` devuelve `1000:1000`.
- [ ] `docker exec stash id` muestra `uid=1000 gid=1000`.
- [ ] La biblioteca `/data` se monta `:ro` dentro del contenedor: `docker exec stash touch /data/test.txt 2>&1` falla con `Read-only file system`.
- [ ] Borgmatic `exclude_patterns` incluye `/mnt/hd5t/**`. Validado con `sudo borgmatic config validate`.
- [ ] Borgmatic `source_directories` **NO** incluye ninguna ruta bajo `/mnt/hd5t/`.
- [ ] La categoría D ha sido **anotada explícitamente** en el _checklist_ de `docs/07-backups/01-estrategia-backup.md` (paso "El operador ha elegido opción de Categoría D"): la biblioteca de Stash está en **opción 1 ("no respaldar la biblioteca")**.
- [ ] (Si se activa) API key generada en _Settings → Security_, copiada a Vaultwarden / fichero de secretos del operador.
- [ ] (Si se activa) CommunityScrapers instalado en _Settings → Metadata Providers_; al menos un scrape de prueba sobre una scene devuelve metadata.

---

## Troubleshooting

### Primer arranque: el contenedor se queda en `starting` indefinidamente

```bash
docker logs stash --tail 50
```

Causas comunes:

- **Permisos de los bind mounts**: si por error los directorios están con `root:root`, Stash (corriendo como `1000:1000`) no puede crear `stash-go.sqlite`. Restaurar:

  ```bash
  sudo chown -R 1000:1000 /mnt/hd2t/services/stash
  sudo chown -R 1000:1000 /mnt/hd5t/stash
  docker compose -f ~/homelab/multimedia/docker-compose.yml restart stash
  ```

- **`/etc/localtime` ausente**: en algunos hosts minimalistas no existe; Stash cae a UTC silenciosamente. Crear el symlink:

  ```bash
  sudo ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
  ```

- **`stash-go.sqlite` corrupto en una restauración previa**: si Stash no puede abrir la BD, queda en bucle de log "database is locked" o "database disk image is malformed". Mover el fichero y dejar que Stash cree uno vacío:

  ```bash
  sudo mv /mnt/hd2t/services/stash/config/stash-go.sqlite \
          /mnt/hd2t/services/stash/config/stash-go.sqlite.broken-$(date +%s)
  sudo rm -f /mnt/hd2t/services/stash/config/stash-go.sqlite-{wal,shm}
  docker compose -f ~/homelab/multimedia/docker-compose.yml restart stash
  # En la UI: el setup wizard arranca de nuevo. Tras configurar paths,
  # ejecutar Scan para repoblar el catálogo.
  ```

  > **Restaurar metadata desde el dump**: si hay un dump reciente, restaurar `stash-go.sqlite` desde Patrón S evita re-scrapear. Ver _Restauración_.

- **Imagen mal descargada**: tras un fallo de red durante el `pull`, la imagen puede quedar parcial. `docker rmi stashapp/stash:v0.27.2 && docker compose -f ~/homelab/multimedia/docker-compose.yml pull stash`.

### "Cannot scan: Read-only file system" al ejecutar Organize

Síntoma: en _Files → Organize_, Stash devuelve `Read-only file system`. Causa esperada: `/data` está montado `:ro` deliberadamente. Ver **Decisiones de diseño** → _Volumen de la biblioteca_.

Solución: si el operador realmente quiere usar Organize, cambiar el bind mount en el compose:

```yaml
- /mnt/hd5t/stash/data:/data:rw    # cambiar :ro por :rw
```

y aceptar el riesgo. La recomendación es no hacerlo: usar SMB / shell desde el host si hace falta reorganizar manualmente.

### Scan se queda colgado a mitad

Síntoma: el scan progresa, llega a un fichero concreto y se queda parado.

Causas:

- **Fichero corrupto** (vídeo con _container_ inválido): Stash llama a `ffprobe` y este nunca termina. Identificar el fichero por el último log:

  ```bash
  docker logs stash --tail 200 | grep -i 'scanning\|ffprobe'
  ```

  Mover el fichero corrupto fuera de `/mnt/hd5t/stash/data/` y reanudar el scan.

- **Fichero muy grande con header al final** (algunos `.mkv` mal _muxed_): `ffprobe` necesita leer el _trailer_ del fichero. En USB lento puede llegar a minutos. Esperar.
- **Disco hd5t lento o desconectándose intermitentemente**: revisar `dmesg | tail -50` por errores de USB (`disconnect`/`reset`). Posiblemente cable USB malo o alimentación insuficiente.

### Transcoding agresivo satura la Pi 5

Síntoma: una _scene_ H.265 4K abierta en navegador hace que `htop` muestre 4 cores al 100 % y el resto de servicios responden con latencias altas (Caddy timeouts, Pi-hole tarda en responder DNS, etc.).

Mitigaciones:

- **Cerrar la pestaña de la _scene_**: el transcode termina al cerrar el reproductor (5-10 s de gracia).
- **Usar un cliente que sí soporte H.265 nativamente**: Safari (macOS/iOS) sí, Chrome/Firefox no en muchos sistemas.
- **Imponer `mem_limit: 2g`** y `cpus: 3.0` en el compose para que Stash tenga al menos 1 core libre para el resto del homelab.
- **Re-encode externo** la scene a H.264/AAC fuera de la Pi (otra máquina con `ffmpeg`).
- **Desactivar transcoding por completo**: _Settings → System → FFmpeg_ → **Streaming strategy**: `Direct` only. Los ficheros incompatibles devuelven 415 al navegador en lugar de transcodificar.

### Imágenes / posters no se descargan al scrapear

Síntoma: tras _Scrape_, los campos textuales se rellenan pero el cover queda en blanco.

Causas:

- **Permisos en `/blobs/`**: Stash escribe ahí; si está como `root:root`, falla silenciosamente. `sudo chown -R 1000:1000 /mnt/hd2t/services/stash/blobs`.
- **Sin conectividad saliente**: el contenedor está aislado de internet (firewall del host bloqueando egress). Revisar `docker exec stash wget -qO- https://github.com/stashapp/stash/raw/develop/README.md | head -5`.
- **El scraper no devuelve URL de imagen**: revisar el log: `docker logs stash --tail 100 | grep -i 'scrape\|image\|cover'`. Algunos scrapers comunitarios degradan funcionalidad cuando los sitios cambian su HTML.

### CommunityScrapers se rompe tras un bump de Stash

Síntoma: los scrapers que funcionaban dejan de hacerlo tras `make pull STACK=multimedia`.

Causas:

- **Cambio de _scraper API_ entre minors**: Stash 0.27 introdujo cambios en la API de scrapers Python. Algunos scrapers comunitarios tardan días/semanas en actualizarse.

Solución temporal:

```bash
# Volver al tag anterior:
$EDITOR ~/homelab/multimedia/.env
# STASH_IMAGE_TAG=v0.26.x
cd ~/homelab && make up STACK=multimedia
```

Y esperar a que los scrapers se actualicen en <https://github.com/stashapp/CommunityScrapers/pulls> antes de re-aplicar el bump.

### "Database is locked" durante un scan

Síntoma: log muestra `database is locked` repetidamente durante un scan masivo.

Causa: SQLite con WAL puede contender si _muchas_ goroutines intentan escribir a la vez. Stash tiene un _semaphore_ que limita escrituras, pero un scan agresivo puede saturarlo.

Mitigación: en _Settings → System → Tasks_, reducir _Parallel tasks_ de 4 (default) a 2 o 1. El scan tarda más pero no contende.

### Stash no aparece en Homepage / Homarr (integración por API key falla)

Síntoma: el widget de Homepage devuelve `401 Unauthorized` o `403 Forbidden`.

Causas:

- **API key incorrecta**: regenerar en _Settings → Security → Generate API Key_, copiar la nueva al `.env` de Homepage.
- **Authelia delante interceptando**: NO debería estar (este doc deshabilita `forward_auth` para Stash). Verificar en `~/homelab/red/Caddyfile` que el bloque `stash.lan` **no** lleva `import authelia`.
- **Header incorrecto**: la API key se pasa como header `ApiKey: <key>` (literal, sin `Bearer`). Si el cliente envía `Authorization: Bearer <key>`, Stash devuelve 401.

---

## Actualización

### Patches y minor bumps (manual, fuera de Watchtower)

Stash es **opt-out** de Watchtower deliberadamente. Cualquier actualización es manual.

Workflow estándar para un bump (`v0.27.2 → v0.27.3` o `v0.27 → v0.28`):

```bash
# 1. Leer las release notes
xdg-open https://github.com/stashapp/stash/releases
# Buscar "Breaking changes", "Database migrations" y "Schema changes" — si
# toca alguna integración activa o hay migración irreversible, planificar el
# cambio antes del bump. Las release notes de Stash son explícitas sobre
# migraciones; si dicen "this release migrates the database", ASUMIR
# irreversibilidad y hacer backup completo antes.

# 2. Backup completo previo
sudo /usr/bin/borgmatic --verbosity 1
# Verificar que el último archive tiene fecha de hoy y que el dump está:
sudo ls -la /mnt/hd2t/backups/dumps/stash-$(date +%F).sqlite.gz
# Confirmar que el SQLite del dump abre sin errores:
sudo zcat /mnt/hd2t/backups/dumps/stash-$(date +%F).sqlite.gz | \
  sqlite3 :memory: 'PRAGMA integrity_check;'
# Esperado: "ok"

# 3. Cambiar el tag y aplicar
$EDITOR ~/homelab/multimedia/.env
# STASH_IMAGE_TAG=v0.28.0   (o el patch nuevo: v0.27.3)
cd ~/homelab
make pull STACK=multimedia
make up   STACK=multimedia

# 4. Vigilar el log durante la migración del schema
docker compose -f ~/homelab/multimedia/docker-compose.yml logs -f stash
# Buscar:
#   level=info msg="performing migrations..."
#   level=info msg="migration complete: <N> migrations applied"
# Si el log muestra ERROR o el contenedor entra en restart loop, ir a
# Troubleshooting y restaurar desde el dump del paso 2.

# 5. Validar la web UI, los scrapers, plugins y (si está activo) HereSphere/DeoVR.
#    Especialmente: una scene scrapeada en la versión anterior debe seguir
#    accesible con todos sus tags, performers, markers y studios; los
#    sprites generados deben seguir mostrándose en el scrubber.
```

> **Migraciones irreversibles**: una vez Stash arranca y migra `stash-go.sqlite`, **no hay vuelta atrás** sin restaurar desde backup. Por eso el paso 2 (backup completo previo + verificación de integridad del dump) es obligatorio.

> **Watchtower nunca toca Stash**: incluso si por error alguien cambiase el label a `enable: "true"`, Stash está pinneado a un _tag_ patch (`v0.27.2`); Watchtower sólo actualizaría si el _digest_ de ese tag cambiase, cosa que sólo ocurre si stashapp _re-tageara_ una versión publicada (extremadamente raro). Aun así, mantener el label `enable: "false"` explícito por documentación.

### Bumps de major (`v0.x → v1.0`)

Cuando llegue (no hay fecha): aplicar el mismo workflow pero con **doble cuidado**:

- Leer **todas** las release notes desde la última versión funcional.
- Probar primero en una **copia** de la BD: `cp stash-go.sqlite /tmp/stash-test.sqlite`, arrancar un Stash nuevo en otro contenedor temporal apuntando a esa BD, comprobar que la migración funciona, y sólo entonces aplicar al de producción.

---

## Referencias

- Documentación oficial — Stash: <https://docs.stashapp.cc/>
- Repositorio del proyecto: <https://github.com/stashapp/stash>
- Releases: <https://github.com/stashapp/stash/releases>
- Imagen Docker oficial: <https://hub.docker.com/r/stashapp/stash>
- CommunityScrapers (scrapers comunitarios): <https://github.com/stashapp/CommunityScrapers>
- API GraphQL de Stash: <https://docs.stashapp.cc/in-app-manual/configuration/graphql-api/>
- Healthcheck endpoint (`/healthz`): <https://docs.stashapp.cc/in-app-manual/configuration/healthcheck/>
- Reverse proxy guide: <https://docs.stashapp.cc/networking/reverse-proxies/>
- HereSphere / DeoVR (clientes VR): <https://docs.stashapp.cc/in-app-manual/configuration/interface/#vr>
- Documentos relacionados del homelab:
  - `docs/00-hardware/03-preparacion-discos.md` — disco `hd5t` dedicado a la biblioteca de Stash, justificación de aislamiento por disco.
  - `docs/01-sistema/04-estructura-directorios.md` — preparación de `/mnt/hd2t/services/stash/{config,metadata}` y `/mnt/hd5t/stash/{data,generated}` con ownership `1000:1000`.
  - `docs/02-docker/02-estructura-compose.md` — convenciones de stacks, red `homelab`, regla `:ro` deliberada en biblioteca de Stash.
  - `docs/02-docker/04-watchtower.md` — Stash en la lista de servicios con _opt-out_ (schema migrations entre minors).
  - `docs/03-red/02-pihole.md` — DNS local `*.lan`.
  - `docs/03-red/04-caddy.md` — Caddy, CA local, _snippets_ `security-headers` y `logging`.
  - `docs/04-seguridad/01-authelia.md` — por qué Stash **no** entra en `forward_auth`.
  - `docs/06-almacenamiento/02-samba.md` — _share_ opcional `stash` (`SAMBA_ENABLE_STASH_SHARE`) `:ro` sobre `/mnt/hd5t/stash/data/`.
  - `docs/07-backups/01-estrategia-backup.md` — biblioteca como Categoría D (no respaldar), BD/metadata como Categoría A.
  - `docs/07-backups/02-borgmatic.md` — `source_directories`, exclusión global de `/mnt/hd5t/`.
  - `docs/07-backups/03-backup-docker-volumes.md` — Patrón S, _hook_ `dump_sqlite stash`.
  - `docs/09-multimedia/01-jellyfin.md` — primer servicio del stack `multimedia`, convenciones compartidas, gemelo del razonamiento `forward_auth`.
  - `docs/09-multimedia/02-navidrome.md` — segundo servicio del stack `multimedia`.
  - `docs/09-multimedia/03-audiobookshelf.md` — tercer servicio del stack `multimedia`.
  - `docs/09-multimedia/04-calibre-web.md` — cuarto servicio del stack `multimedia`, contraste `:rw` (Calibre-Web) vs `:ro` (Stash).
