# Navidrome (servidor de música)

## Descripción

Despliegue de **Navidrome** como servidor de música del homelab: indexa la biblioteca compartida (`/mnt/hd2t/services/shared/music/`), expone una **web UI** (`https://music.lan`) y, sobre todo, una **API compatible con Subsonic/OpenSubsonic** que consumen los clientes nativos Android/iOS/desktop (DSub, Symfonium, play:Sub, Sonixd, Feishin…). Toda la configuración persistente y la BD SQLite del catálogo viven en el disco externo **hd2t** (`/mnt/hd2t/services/navidrome/data/`); la biblioteca de música se monta `:ro` desde el árbol compartido pre-creado en `docs/01-sistema/04-estructura-directorios.md` (con bit `setgid` y grupo `homelab-media`, lectura compartida con Samba).

Este documento **se suma al _stack_ `multimedia`** que estrenó `docs/09-multimedia/01-jellyfin.md` (`~/homelab/multimedia/`). No se crea un compose nuevo: se añade un servicio `navidrome` al `~/homelab/multimedia/docker-compose.yml` ya existente y se completan las variables del `.env` correspondiente. Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone Navidrome en `https://music.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), el mismo nombre `music.lan` resuelve a `192.168.1.3` desde dentro del _tailnet_ gracias al _Split DNS_ delegado a Pi-hole.

> **Alcance**: este documento despliega Navidrome con su autenticación nativa (usuarios Subsonic + contraseña, opcional 2FA TOTP **a nivel de la web UI** desde 0.55), configura el escaneo automático con `inotify`, deja la transcodificación _on-the-fly_ activa por defecto (la Pi 5 sí puede transcodificar audio sin sudar, ver **Decisiones de diseño**) y entrega un _hook_ Borgmatic listo para hacer dump _online_ de la SQLite del catálogo. **No** delega autenticación a Authelia vía `forward_auth` (rompería todos los clientes Subsonic, idéntico problema al de Jellyfin — ver **Decisiones de diseño**). **No** activa scrobbling externo (Last.fm / ListenBrainz) por defecto: queda como _opt-in_ documentado en _Configuración_. **No** habilita la _shares_ feature (URLs públicas de canciones) ni la subida de _cover art_ por usuario: ambas requieren _public base URL_ y abren superficie de ataque innecesaria en un servidor LAN+VPN.

> **Recordatorio de red**: Navidrome **no se publica al host**. Caddy lo alcanza por DNS interno de Docker (`navidrome:4533` en la red `homelab`). Pi-hole resuelve `music.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`). El operador entra siempre por `https://music.lan/` (LAN) o por el mismo nombre desde el _tailnet_.

---

## Requisitos previos

- `docs/09-multimedia/01-jellyfin.md` completado: el _stack_ `multimedia` (`~/homelab/multimedia/`) ya existe con `docker-compose.yml`, `.env`, `.env.example` y `.gitignore`. La red `homelab` está creada como externa, las variables globales `TZ`, `PUID`, `PGID`, `MEDIA_GID` están rellenas en `~/homelab/.env`, y el _Makefile_ de operación expone `make up STACK=multimedia`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/navidrome/` ya existe y está reasignado a ownership `1000:1000` (paso 7 de aquel doc, "Reasignar ownership de los servicios LinuxServer.io" — Navidrome se reasigna a `1000:1000` aunque la imagen oficial no sea LSIO, porque es el UID del operador y de los demás servicios multimedia que comparten la biblioteca). El árbol `/mnt/hd2t/services/shared/music/` existe con `root:homelab-media 2775` para que Navidrome lo lea.
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada y por defecto desactivada. Navidrome será **opt-in** explícito (ver **Decisiones de diseño**).
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `music.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile` y la CA local firma `*.lan`.
- `docs/04-seguridad/01-authelia.md` completado **opcionalmente**: si Authelia ya está montado, en este documento se decide explícitamente **no** poner Navidrome detrás de `forward_auth`. La lista `two_factor` del `access_control.rules` de Authelia **no incluye** `music.lan` (ni siquiera comentado).
- `docs/06-almacenamiento/02-samba.md` completado o pendiente: la _share_ `music` de Samba escribe en `/mnt/hd2t/services/shared/music/` con `force user = homelab` y `force group = homelab-media`, exactamente lo que Navidrome escanea. Si Samba aún no está montado, la biblioteca se rellena por SFTP / `rsync` directo.
- `docs/07-backups/02-borgmatic.md` y `docs/07-backups/03-backup-docker-volumes.md` completados (recomendado): el `source_directories: /mnt/hd2t/services` ya engloba `navidrome/`, el bloque del _hook_ `dump-databases.sh` para Navidrome ya está preparado y comentado. Este doc termina **descomentando** ese bloque.
- Conectividad saliente para descargar la imagen (sólo la primera vez):

  ```bash
  docker pull --platform linux/arm64 deluan/navidrome:0.55 >/dev/null && echo OK
  ```

- Que el host **no** tenga ya un servicio escuchando en `:4533`:

  ```bash
  sudo ss -tulpn 'sport = :4533'
  ```

  Salida esperada: vacía. Navidrome no publica `:4533` al host (Caddy lo alcanza por DNS interno), pero conviene confirmar que ningún binario residual lo ocupa.

- Espacio en `/mnt/hd2t`: como mínimo **500 MB libres** para que Navidrome arranque cómodo. La cuota real la dictan la BD del catálogo (~20 MB por cada 10 000 canciones), el _cover art cache_ (`/data/cache/`, redimensionado de portadas, ronda los 100–500 MB) y el _transcoding cache_ (limitado por config a 100 MB por defecto). En estado estable, el árbol `/mnt/hd2t/services/navidrome/` se mantiene por debajo de **1 GB** salvo bibliotecas muy grandes (>100 000 _tracks_).

  ```bash
  df -h /mnt/hd2t
  ```

---

## Decisiones de diseño

### Por qué Navidrome (y no Airsonic-Advanced / Funkwhale / Jellyfin "music")

El homelab necesita un **servidor de música self-hosted** que indexe `/mnt/hd2t/services/shared/music/`, exponga una API que las apps móviles entiendan _out-of-the-box_, conserve el _scrobbling_ y los _now playing_ entre dispositivos, y se mantenga ligero en una Pi 5. Tres alternativas descartadas y por qué:

| Candidato                | Por qué se descarta                                                                                                                                                                                                                                                                          |
|--------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Airsonic-Advanced**    | _Fork_ comunitario sobre Java. Funciona, pero arrastra el _runtime_ JVM (RAM ~500 MB en idle frente a los ~80 MB de Navidrome), el ritmo de releases es lento y el catálogo de plugins es modesto. Para una Pi 5 con varios servicios competing, el _footprint_ importa.                |
| **Funkwhale**            | Federado (ActivityPub), Postgres + Redis + Celery + Nginx + Django. Excelente proyecto, pero la infra para servir _mi_ música _a mí_ es desproporcionada. Además sirve la API de Subsonic sólo parcialmente y los clientes nativos suelen tropezar.                                       |
| **Jellyfin "Music"**     | Jellyfin (`docs/09-multimedia/01-jellyfin.md`) sí indexa música y la sirve, pero su _UX_ de escucha (web client + apps) es un afterthought respecto al vídeo, no soporta _smart playlists_ Subsonic, no tiene _internet radio_ pulida, y los clientes Subsonic puros no se hablan con su API. |

Navidrome gana por:

- **100 % gratis y libre** (GPLv3): código, web UI, binario _single-static_ en Go, multi-arch oficial.
- **Compatible Subsonic + OpenSubsonic**: cualquiera de los ~25 clientes Subsonic existentes (DSub, Symfonium, play:Sub, Substreamer, Sonixd, Feishin, Stmp, Submariner…) funciona sin ajustes especiales.
- **Imagen Docker oficial multi-arch ARM64** (`deluan/navidrome`), publicada por el autor del proyecto.
- **Footprint mínimo**: ~80 MB de RAM idle, binario único en Go (no JVM, no Python, no Node), arranca en <2 s. Ideal para correr junto a Jellyfin, Home Assistant, Nextcloud y compañía sin pelearse por RAM.
- **BD SQLite con WAL**: respaldable _online_ con `sqlite3 .backup` (Patrón S del homelab). Sin _runtime_ extra de Postgres/MariaDB.
- **`inotify` de fábrica**: Navidrome detecta cambios en la biblioteca _live_ sin reescaneos completos. Si Sonarr/Radarr-equivalentes-de-música (Lidarr) o un drop por SMB añade un álbum, aparece en segundos.

### Imagen y _tag_

- **`deluan/navidrome:0.55`** — imagen oficial del proyecto, _tag_ "major.minor" siguiendo la convención del homelab (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`, "Tag mayor o LTS"). Multi-arch (`linux/arm64`). El _tag_ `0.55` sigue la línea estable de 2026; los _bumps_ de patch (`0.55.0 → 0.55.1 → 0.55.2`) llegan con _bug fixes_, _security patches_ y mejoras de _scanner_, sin _breaking changes_ de _schema_.
- **Por qué no `:latest`**: ese _tag_ se mueve cada vez que sale una nueva versión _minor_ (`0.55 → 0.56`); un `docker compose pull` accidental durante un _bump_ de minor podría introducir cambios de _schema_ en la BD del catálogo (Navidrome aplica _migrations_ irreversibles al arrancar con un _binary_ más nuevo).
- **Por qué no `:develop` ni `:edge`**: tags inestables construidos a partir de _master_; no para servicio en producción.

> **Convenio de versionado de Navidrome**: el proyecto trata cada incremento de _minor_ (`0.NN → 0.N(N+1)`) como _major_ a efectos prácticos. El _tag_ `:0.55` apunta al último parche de esa línea (`0.55.x`). Ver _Releases_ del proyecto para confirmar la línea estable vigente cuando se ejecute este documento.

#### Watchtower **opt-in**

Razones:

- **Patches frecuentes sin _breaking changes_**: la línea `0.55.x` recibe _patch releases_ con _security fixes_ del propio Navidrome, de su FFmpeg embebido y del _scanner_. Mantenerse al día sin tocar a mano es deseable.
- **Schema de BD estable dentro de una `minor`**: las _migrations_ irreversibles sólo se disparan al saltar de `0.55` a `0.56`. Dentro de `0.55.x`, los _patches_ son intercambiables. Watchtower puede reciclar el contenedor con seguridad.
- **Sin estado en RAM**: Navidrome persiste todo en `/data/navidrome.db` antes de recibir `SIGTERM`. Reciclar el contenedor durante la madrugada (la ventana de Watchtower es domingo a las 04:00 UTC, ver `docs/02-docker/04-watchtower.md`) no rompe sesiones — los clientes Subsonic se reconectan transparentemente con su _bearer_ (token Subsonic) en cuanto el servidor vuelve.

Etiquetar el contenedor con `com.centurylinklabs.watchtower.enable: "true"`. Coherente con la lista global de `docs/02-docker/04-watchtower.md` (sección _candidatos a opt-in desde el principio_).

> **Bumps de _minor_** (`0.55 → 0.56`): se hacen **a mano**, fuera de Watchtower. Cambiar `NAVIDROME_IMAGE_TAG=0.56` en `~/homelab/multimedia/.env`, leer las _release notes_ del proyecto en GitHub, hacer backup del `/data` previo (Borgmatic + dump SQLite) y aplicar `make pull STACK=multimedia && make up STACK=multimedia`. Watchtower con _tag_ `0.55` no salta a `0.56` automáticamente porque mira el _digest_ del _tag_ exacto que está pinneado.

### Modo de red: `bridge` (red `homelab`), no `host`

Mismo razonamiento que en `docs/09-multimedia/01-jellyfin.md`: Navidrome corre en la red `homelab` (`bridge`, `172.20.10.0/24`), Caddy lo alcanza por nombre interno (`navidrome:4533`), no se publica ningún puerto al host. La pérdida de auto-discovery (Navidrome no implementa SSDP en absoluto, así que no hay nada que perder por estar en `bridge`) no es un problema: los clientes Subsonic se configuran con la URL `https://music.lan/` una vez por dispositivo y la recuerdan.

### Volumen de la biblioteca de música: `/services/shared/music:/music:ro`

La biblioteca de música se monta **read-only** dentro del contenedor:

```yaml
volumes:
  - /mnt/hd2t/services/shared/music:/music:ro
```

Razones:

- **Navidrome no debería escribir en la biblioteca**. El servidor _indexa_, lee tags ID3/Vorbis/etc., guarda metadatos (rating, _play count_, _last played_, _starred_) en su BD SQLite (`/data/navidrome.db`), y deriva _cover art_ a un caché aparte (`/data/cache/`). **No** modifica los ficheros originales: las _tags_ las cambia el operador (con `Picard`, `beets`, `Lollypop`…) en otra máquina o por SMB.
- **Samba** (`docs/06-almacenamiento/02-samba.md`) sí escribe en la misma carpeta cuando el operador arrastra un álbum manualmente — montaje `:rw` en _ese_ contenedor, no en Navidrome.
- **`:ro` mata por construcción** la mayoría de _data loss_ accidentales: un bug en Navidrome no podrá nunca borrar la biblioteca; un ataque a la API podrá _starrear_, _ratear_ o crear _playlists_, pero no `unlink()` ficheros del disco.

> **Esta convención está alineada con `docs/02-docker/02-estructura-compose.md`** (sección **Volúmenes**, regla `:ro` explícito) y con la regla equivalente de Jellyfin sobre `services/shared/media`.

### Transcodificación: **activa** (a diferencia de Jellyfin)

A diferencia del vídeo (donde la Pi 5 no aguanta transcoding por hardware ni por software para más de un _stream_ — ver `docs/09-multimedia/01-jellyfin.md`), el **audio sí se transcodifica sin problema** en una Pi 5:

- Un _stream_ FLAC → MP3 320 kbps consume ~3-5 % de un _core_ ARM A76. Diez _streams_ simultáneos cabrían holgados.
- FFmpeg viene en la imagen oficial de Navidrome (binario embebido, no se necesita `apt`).
- Los _transcoding profiles_ de Navidrome están preparados de fábrica (MP3/Opus/AAC a varios bitrates seleccionables por el cliente).

Conclusión: **se deja la transcodificación habilitada con la configuración por defecto**. Útil para clientes con conexión limitada (móvil con plan de datos justo en zona de cobertura mala) que no quieran descargar FLAC a 1 Mbps.

> **Cuándo desactivarla**: si todos los clientes están siempre en LAN/Tailscale con buena conexión y la biblioteca es 100 % MP3/AAC (sin FLAC ni ALAC), la transcodificación nunca se dispara y el _setting_ es irrelevante. No hay que tocar nada. La _transcoding cache_ (`/data/cache/transcoding/`) se queda vacía.

### `forward_auth` con Authelia: **NO** para Navidrome

Tentación natural una vez Authelia está montada: añadir `import authelia` al bloque `music.lan` del `Caddyfile`. **No se hace**, exactamente por las mismas razones que Jellyfin:

- **Las apps móviles oficiales y de terceros** (DSub, Symfonium, play:Sub, Substreamer, Stmp, Submariner, Sonixd, Feishin) hablan con Navidrome por la **API HTTP de Subsonic** usando un _token_ y un _salt_ (`?u=<usuario>&t=<MD5(password+salt)>&s=<salt>` o, en OpenSubsonic, _bearer_ JWT). **No** saben redirigirse a un portal _web_, no resuelven un _challenge_ OIDC, no rellenan formularios HTML. Si Caddy intercepta el _request_ y devuelve `302 Location: https://auth.lan/?rd=...`, la app falla en bucle.
- **El cliente web del navegador** (`/app`) hace login JSON puro contra `/auth/login` y recibe un JWT. Authelia delante = el navegador recibe el HTML de la _login page_ de Authelia en lugar del JSON con el token, y la web rompe.
- **Scrobbling outbound** (a Last.fm / ListenBrainz, si se activase) lo hace el _backend_ de Navidrome con sus credenciales internas; no afecta a Authelia, pero subraya que el _surface_ entre cliente y servidor es API JSON, no HTML.

Solución correcta: **Navidrome autentica con su sistema nativo** (usuario + contraseña por usuario, gestionado en la web UI). Desde 0.55 incluye **2FA TOTP** opcional para la web UI (ver _Configuración_); los clientes Subsonic siguen usando _password+salt_ porque es la API que entienden.

> **Resumen operativo**: el bloque `music.lan` del `Caddyfile` lleva `import security-headers` y `import logging`, pero **no** `import authelia`. Caddy actúa como _reverse proxy_ "tonto" que termina TLS, propaga `X-Forwarded-*` y deja a Navidrome la autenticación.

### Catálogo en SQLite (no MariaDB/Postgres)

Navidrome **sólo soporta** SQLite como _backend_ del catálogo. Esta decisión la toma el proyecto _upstream_, no el homelab. Implicaciones:

- **Footprint mínimo**: la BD vive en `/data/navidrome.db` sin contenedor extra. Para una biblioteca de 50 000 _tracks_ con _scrobbling_ activo, ronda los **20–80 MB**.
- **Backups con Patrón S** (`docs/07-backups/03-backup-docker-volumes.md`): la imagen oficial de Navidrome **incluye `sqlite3` en el _PATH_**, así que se puede ejecutar `sqlite3 .backup` _online_ sin parar el contenedor. Si por alguna razón no estuviera, el _hook_ cae automáticamente a Patrón S-fría (parar contenedor, copiar fichero, arrancar) — _downtime_ ~5 s.
- **WAL activo**: Navidrome arranca SQLite con `journal_mode=WAL`. Eso significa que `navidrome.db-wal` y `navidrome.db-shm` están presentes durante la ejecución. **Importante**: si se hace una copia "en caliente" del `.db` por `cp` directo sin `sqlite3 .backup`, la copia puede quedar inconsistente. Por eso `dump_sqlite` es la única vía válida.

### Almacenamiento

| Ruta en el host                                            | Contenido                                                            | Versionable           | Backup                              |
|------------------------------------------------------------|----------------------------------------------------------------------|-----------------------|-------------------------------------|
| `~/homelab/multimedia/docker-compose.yml`                  | Definición del _stack_ (compartida con Jellyfin)                     | git                   | git                                 |
| `~/homelab/multimedia/.env`                                | Imágenes pinneadas + variables del _stack_                           | **NO** (`.gitignore`) | git aparte (nota local)             |
| `~/homelab/multimedia/.env.example`                        | Plantilla con nombres de variables, sin valores                      | git                   | git                                 |
| `/mnt/hd2t/services/navidrome/data/`                       | `navidrome.db` + `cache/` + `plugins/`                                | **NO** versionable    | **Sí** (Borgmatic)                  |
| `/mnt/hd2t/services/navidrome/data/navidrome.db`           | BD SQLite del catálogo (estados, _play count_, _starred_, _playlists_) | **NO**                | **Sí** (Borgmatic vía dump)         |
| `/mnt/hd2t/services/navidrome/data/cache/transcoding/`     | Cache de transcoding (regenerable)                                   | **NO**                | **NO** — excluido por `*/cache/*`   |
| `/mnt/hd2t/services/navidrome/data/cache/images/`          | _Cover art_ redimensionado                                           | **NO**                | **NO** — excluido por `*/cache/*`   |
| `/mnt/hd2t/services/shared/music/`                         | Biblioteca de música, montada `:ro` en Navidrome                     | **NO**                | **NO** — Categoría C, regenerable    |

> **`cache/` excluido**: el _exclude pattern_ global `*/cache/*` de `docs/07-backups/02-borgmatic.md` ya lo cubre. Los _cover art_ redimensionados y los _transcoding cache_ se regeneran al primer request.

> **Biblioteca compartida en `/services/shared/music/`**: política Categoría C de `docs/07-backups/01-estrategia-backup.md` — _no entra en Borg_. La BD del catálogo de Navidrome (que sí entra) describe qué hay y dónde, junto con _ratings_, _starred_ y _play count_, pero los `.flac`/`.mp3` mismos no se respaldan. Si se pierde el disco hd2t, la biblioteca de música se restaura **re-importándola** desde la copia que el operador tenga en otro sitio (típicamente el laptop o un disco USB de archivo).

---

## Estructura del _stack_ `multimedia` tras este documento

```
~/homelab/multimedia/
├── docker-compose.yml        # ← extendido (servicio navidrome añadido)
├── .env                      # ← extendido (variables NAVIDROME_*)
├── .env.example              # ← extendido (plantilla de NAVIDROME_*)
└── .gitignore                # sin cambios
```

Y en el disco externo, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/navidrome/
└── data/                     (vacío al empezar; el primer arranque lo puebla)
```

Crear el subdirectorio `data/` (si no existe ya):

```bash
sudo mkdir -p /mnt/hd2t/services/navidrome/data
sudo chown -R 1000:1000 /mnt/hd2t/services/navidrome
```

> **Ownership de `/mnt/hd2t/services/navidrome/`**: ya está fijado por `docs/01-sistema/04-estructura-directorios.md` paso 7 a `1000:1000`. El contenedor corre como `${PUID}:${PGID}` (= `1000:1000`) gracias a la directiva `user:` del compose, así que escribe sin fricciones. La creación del subdirectorio `data/` mantiene el ownership heredado.

> **Ownership de `/mnt/hd2t/services/shared/music/`**: `root:homelab-media 2775` (bit `setgid` activo). Navidrome sólo lee (`:ro`); para garantizar lectura por GID en lugar de "otros", se añade `MEDIA_GID` al contenedor como **grupo suplementario** vía `group_add`, igual que en Jellyfin.

---

## Variables de entorno

Añadir las siguientes líneas al `~/homelab/multimedia/.env.example` (debajo de las ya existentes para Jellyfin):

```bash
# --- Navidrome -------------------------------------------------------------
# https://github.com/navidrome/navidrome/releases — patches automáticos vía
# Watchtower; bumps de minor (0.55 -> 0.56) a mano con dump previo de SQLite.
NAVIDROME_IMAGE_TAG=0.55

# URL pública canónica del servicio. Usada por Navidrome para construir URLs
# absolutas en el feed RSS de podcasts, comparticiones (deshabilitadas) y
# en el .well-known/openid-configuration cuando se active OIDC (fuera de
# alcance hoy).
NAVIDROME_BASE_URL=https://music.lan

# Rango de subnets internas confiables para X-Forwarded-For. Coincide con
# la red Docker 'homelab' creada en docs/02-docker/02-estructura-compose.md.
# Navidrome ignora cabeceras de procedencia distinta y registra la IP
# interna (172.20.10.x) sólo si el origen no está aquí.
NAVIDROME_REVERSE_PROXY_WHITELIST=172.20.10.0/24
```

Copiar a `.env` (ya creado por el doc de Jellyfin):

```bash
$EDITOR ~/homelab/multimedia/.env
# Añadir los mismos NAVIDROME_* con los valores reales.
```

> **`.env` aquí no contiene secretos** (Navidrome gestiona las credenciales de los usuarios en `/data/navidrome.db`, hashed con bcrypt). Aun así, se mantiene `0600` y fuera de git por consistencia con el resto de _stacks_.

---

## `~/homelab/multimedia/docker-compose.yml` (extensión)

Añadir el siguiente servicio al compose ya existente, **a continuación** del bloque `jellyfin:` y **antes** del bloque `networks:` final:

```yaml
  # ---------------------------------------------------------------------------
  # Navidrome — servidor de música (Subsonic/OpenSubsonic API + web UI).
  # Comparte red 'homelab' con jellyfin. Caddy alcanza ambos por nombre
  # interno (jellyfin:8096, navidrome:4533).
  # ---------------------------------------------------------------------------
  navidrome:
    image: deluan/navidrome:${NAVIDROME_IMAGE_TAG}
    container_name: navidrome
    hostname: navidrome
    restart: unless-stopped
    user: "${PUID}:${PGID}"
    group_add:
      # Permite a Navidrome LEER /mnt/hd2t/services/shared/music/ por GID en
      # lugar de depender del bit 'o+r'. MEDIA_GID viene del .env global,
      # ver docs/01-sistema/04-estructura-directorios.md.
      - "${MEDIA_GID}"
    environment:
      TZ: ${TZ}
      # Configuración Navidrome (env vars con prefijo ND_*).
      ND_DATAFOLDER: /data
      ND_MUSICFOLDER: /music
      # URL base usada por Navidrome para construir URLs absolutas (feed RSS,
      # plugin OIDC, etc.). No afecta al routing — eso lo hace Caddy por host.
      ND_BASEURL: ${NAVIDROME_BASE_URL}
      # Reverse proxy: confía en X-Forwarded-* sólo desde la subnet de la
      # red 'homelab' (donde vive Caddy). Sin esto, los logs de Navidrome
      # mostrarían la IP interna 172.20.10.x para todos los clientes.
      ND_REVERSEPROXYWHITELIST: ${NAVIDROME_REVERSE_PROXY_WHITELIST}
      # Escaneo: por defecto Navidrome usa inotify para detectar cambios
      # in-place. SCANSCHEDULE como fallback (full re-scan periódico) cada
      # 12 h por si inotify se pierde un evento (raro pero documentado en
      # bibliotecas con muchas decenas de miles de ficheros).
      ND_SCANSCHEDULE: 12h
      # Logs en formato texto (más legibles); cambiar a 'json' si en algún
      # momento se conectan a Loki/Promtail.
      ND_LOGLEVEL: info
      # Web UI: deshabilitar el registro de usuarios autoservicio. Los crea
      # el admin a mano en /app -> Users.
      ND_ENABLEUSERREGISTRATION: "false"
      # Sharing público: deshabilitado (ver alcance del documento).
      ND_ENABLESHARING: "false"
    volumes:
      - /mnt/hd2t/services/navidrome/data:/data
      # Biblioteca de música compartida — read-only (Samba la escribe).
      - /mnt/hd2t/services/shared/music:/music:ro
      # Hora del host coincidente.
      - /etc/localtime:/etc/localtime:ro
    networks:
      homelab:
        aliases:
          - navidrome     # Caddy resuelve 'navidrome:4533' por este alias
    labels:
      homelab.stack: "multimedia"
      homelab.backup: "true"   # /mnt/hd2t/services/navidrome/data entra en Borgmatic
      # Opt-in: patches dentro de 0.55.x son seguros (sin schema migrations).
      com.centurylinklabs.watchtower.enable: "true"
    healthcheck:
      # /ping es el endpoint canónico de Navidrome (devuelve {"status":"ok"}
      # sin requerir autenticación). Útil para liveness probes.
      test:
        - CMD-SHELL
        - "wget -qO- --tries=1 --timeout=5 http://localhost:4533/ping | grep -q '\"status\":\"ok\"' || exit 1"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s   # primer arranque: ~10 s (binario único Go, BD vacía)
    # Sin 'ports:'. Caddy alcanza Navidrome por DNS interno.
```

Notas de diseño:

- **`user: "${PUID}:${PGID}"`**: la imagen oficial de Navidrome corre como `root` por defecto. Bajarla a `1000:1000` cumple la convención del homelab. El `/mnt/hd2t/services/navidrome/` ya es `1000:1000` por `docs/01-sistema/04-estructura-directorios.md` paso 7.
- **`group_add: ["${MEDIA_GID}"]`**: añade el GID del grupo `homelab-media` como _grupo suplementario_ del proceso. Permite a Navidrome leer `/mnt/hd2t/services/shared/music/` (que es `root:homelab-media 2775`) por _ownership_ y no sólo por bit `o+r`.
- **`/music:ro`**: explícito y deliberado. Ver **Decisiones de diseño** → _Volumen de la biblioteca de música_.
- **Sin `ports:`**. Caddy alcanza Navidrome por DNS interno (`navidrome:4533`). Si el operador necesita acceso directo durante un _troubleshooting_, puede `docker exec -it navidrome wget -qO- http://localhost:4533/ping`.
- **`ND_REVERSEPROXYWHITELIST`**: imprescindible para que los logs muestren la IP real del cliente (`192.168.1.x` o `100.x.y.z` desde Tailscale) en vez de la IP del contenedor de Caddy (`172.20.10.x`). Sin esto, _credential stuffing_ de un atacante interno aparecería como originado por Caddy y dificultaría el _post-mortem_.
- **`ND_ENABLEUSERREGISTRATION: "false"`**: cierra el formulario de auto-registro. Los usuarios los crea el _admin_ desde la web UI.
- **`ND_ENABLESHARING: "false"`**: las _shares_ públicas (URLs sin auth para compartir un track) requieren publicar `BASEURL` a internet o vía Tailscale; en este homelab LAN+VPN no aporta valor y abre superficie. Si en el futuro se quisiera, se activa con un cambio de variable y un reinicio.
- **`ND_SCANSCHEDULE: 12h`**: re-scan completo cada 12 horas como _fallback_ por si `inotify` perdiera algún evento. Para bibliotecas pequeñas (<10 000 _tracks_) un re-scan tarda <30 s y no impacta. Para bibliotecas muy grandes se puede subir a `24h` o `weekly`.
- **`start_period: 30s`**: el primer arranque tarda ~10 s (binario único en Go, BD vacía). Margen holgado.
- **`/ping` como _liveness probe_**: público (sin autenticación), devuelve `{"status":"ok","version":"...","type":"navidrome"}`. No requiere token, ideal para `wget -qO-`.
- **Watchtower opt-in**: razones explicadas en **Decisiones de diseño** → _Imagen y tag_.
- **No `mem_limit`**: en idle Navidrome consume ~80 MB. Durante un _full library scan_ sube a ~200-300 MB. Sin necesidad de ajuste hasta que Stash y compañía compitan por memoria (`docs/13-operaciones/03-rendimiento-pi5.md`).

---

## Despliegue

### Levantar el servicio

```bash
cd ~/homelab/multimedia
docker compose --env-file ../.env --env-file .env config | grep -A2 navidrome   # validar
docker compose --env-file ../.env --env-file .env up -d navidrome
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=multimedia
```

> `make up` aplica todo el stack; si Jellyfin ya estaba arriba, Compose lo deja como está y sólo crea/recrea el contenedor `navidrome`.

Vigilar el primer arranque (tarda ~10 s):

```bash
docker compose -f ~/homelab/multimedia/docker-compose.yml logs -f navidrome
# ...
# navidrome  | time="..." level=info msg="Starting Navidrome 0.55.x..."
# navidrome  | time="..." level=info msg="Opening DataBase" path=/data/navidrome.db
# navidrome  | time="..." level=info msg="Database schema is up to date" current=...
# navidrome  | time="..." level=info msg="Navidrome server is accepting requests" address=":4533"
```

Verificar que el contenedor está `(healthy)`:

```bash
docker compose -f ~/homelab/multimedia/docker-compose.yml ps navidrome
# NAME       STATUS                  PORTS
# navidrome  Up X seconds (healthy)
```

> El `(healthy)` lo otorga el _healthcheck_ que confirma que `/ping` devuelve `{"status":"ok"}`. Si tras 1 minuto sigue `starting`, ir a **Troubleshooting** → primer arranque.

### Caddy: bloque `music.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque (típicamente después del bloque `jellyfin.lan` para mantener orden alfabético por servicio):

```caddy
music.lan {
    tls internal
    import security-headers
    import logging

    # Subida de cover art y attachments por el admin: Navidrome acepta hasta
    # 10 MB por petición por defecto; el reverse_proxy de Caddy v2 no impone
    # un límite explícito menor, así que no se necesita 'request_body'.

    reverse_proxy navidrome:4533 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
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
curl -k --resolve music.lan:443:192.168.1.3 \
     https://music.lan/ping
# {"status":"ok","version":"0.55.x","type":"navidrome","serverVersion":"..."}

curl -k --resolve music.lan:443:192.168.1.3 \
     -s -o /dev/null -w '%{http_code}\n' https://music.lan/app/
# 200
```

Y desde el navegador: `https://music.lan/` → la web UI de Navidrome muestra la pantalla de **creación del primer usuario** (admin). Una vez creado, redirige al login.

---

## Configuración tras primer arranque

### Crear el primer usuario (admin)

`https://music.lan/` muestra **un formulario de registro inicial** (sólo aparece la primera vez, hasta que existe al menos un usuario). Rellenar:

- **Username**: distinto de `admin` (objetivo trivial de _credential stuffing_).
- **Password**: robusta. Se almacena hasheada con bcrypt en `/data/navidrome.db`.
- **Email**: opcional; sólo se usa para mostrar avatar Gravatar y para reset de contraseña por email (si se configurase SMTP, fuera de alcance hoy).

Al confirmar, ese usuario queda como `is_admin=true`. Es el único que puede crear más usuarios y modificar la configuración global.

### Activar 2FA TOTP en la web UI (opcional pero recomendado)

Desde 0.55, Navidrome soporta TOTP **para la web UI** (no para los clientes Subsonic). En **Personal Settings → Security → Two-Factor Authentication**:

1. **Enable 2FA**.
2. Escanear el QR con Authy / Aegis / Google Authenticator.
3. Validar con un código de 6 dígitos.
4. **Guardar los códigos de recuperación** en Vaultwarden (cuando exista; mientras tanto en un papel/llavero).

> **Importante**: el 2FA TOTP **sólo aplica al login web**. Los clientes Subsonic (DSub, Symfonium, etc.) seguirán autenticándose con _password+salt_ sin segundo factor. Es un _trade-off_ deliberado del proyecto: la API Subsonic no especifica TOTP, romperla rompería ~25 clientes. Mitigación: contraseñas robustas + lockout (siguiente sección) + acceso sólo por LAN/Tailscale.

### Crear usuarios adicionales (familia)

En **Settings → Users → Create User**:

- **Username**: nombre (ej. "pareja", "kid1").
- **Password**: distinta del admin. El usuario podrá cambiarla en _Personal Settings_.
- **Is admin**: NO (los demás usuarios no deben poder crear ni borrar bibliotecas, sólo escuchar).
- **User libraries**: por defecto todos ven toda la biblioteca; con _multi-library_ (0.55+) se puede segmentar.

> **Subsonic Token vs Password**: la API de Subsonic clásica recibe `?u=<usuario>&t=<MD5(password+salt)>&s=<salt>` o, alternativamente, `?u=<usuario>&p=enc:<hex(password)>`. Navidrome acepta ambas. **OpenSubsonic** añade autenticación por _bearer JWT_ (`Authorization: Bearer ...`); los clientes modernos (Symfonium, Feishin) la usan preferentemente. **No** se necesita configurar nada extra: el cliente envía la mejor que soporta y Navidrome responde.

### Configurar la biblioteca

Por defecto Navidrome ya está escaneando `/music` (= `/mnt/hd2t/services/shared/music/` en el host). En **Settings → Libraries**:

- **Library name**: `Music` (default).
- **Path**: `/music` (mapeado, no editable desde la UI por seguridad — viene de `ND_MUSICFOLDER`).
- **Auto-import**: ON.
- **Watch for changes**: ON (usa `inotify`).

Cuando el escaneo inicial termina (un par de minutos para 10 000 _tracks_), aparecen las pestañas **Albums**, **Artists**, **Songs**, **Playlists** pobladas.

### Endurecer el login (intentos máximos)

Navidrome tiene _lockout_ por usuario tras N intentos fallidos. En 0.55 está activado por defecto con 5 intentos en 5 minutos. Para revisarlo o ajustarlo:

```bash
docker exec navidrome /app/navidrome --help | grep -A1 -i 'lockout\|maxlogin'
```

Si se quisiera afinar, añadir variables al servicio en el compose (ej. `ND_AUTH_LOCKOUT_FAILEDATTEMPTS: 3`, `ND_AUTH_LOCKOUT_DURATION: "10m"`) y reiniciar.

> **Por qué no usar `fail2ban` con un jail Navidrome**: igual que Jellyfin, el _lockout_ nativo del propio servidor es suficiente y opera a nivel de _user_ (no de IP), evitando falsos positivos con NAT. Si se quisiera ban por IP también, se documentaría un jail específico en `docs/04-seguridad/02-fail2ban.md` parseando `/data/navidrome.log` (o `docker logs`).

### Scrobbling externo (opcional)

Navidrome soporta _scrobble_ a Last.fm y ListenBrainz. Por defecto **deshabilitado**; activarlo cada usuario individualmente en **Personal Settings → Last.fm / ListenBrainz**:

1. Solicitar API key en <https://www.last.fm/api/account/create> (Last.fm) o usar el _user token_ de <https://listenbrainz.org/profile/> (ListenBrainz).
2. Pegar la API key + secret en _Personal Settings_.
3. Vincular la cuenta (OAuth dance ligero).

> **Privacidad**: scrobbling externo envía a un tercero título + artista + álbum + timestamp de cada reproducción. Decisión personal por usuario. El servidor mismo (la BD del catálogo) ya guarda esa información _localmente_ en el _play count_ y _last played_; el scrobble sólo la replica fuera.

---

## Bibliotecas y tags

### Estructura recomendada de la biblioteca

Dentro de `/mnt/hd2t/services/shared/music/`, organizar:

```
/mnt/hd2t/services/shared/music/
├── Artist Name/
│   ├── 1999 - Album Title/
│   │   ├── 01 - Track Name.flac
│   │   ├── 02 - Track Name.flac
│   │   ├── ...
│   │   └── cover.jpg
│   └── 2003 - Other Album/
│       └── ...
└── Compilations/
    └── 2010 - Various Artists - Soundtrack/
        ├── 01 - Track Name.mp3
        └── ...
```

Convención _Picard / beets_ standard: `Artist/Year - Album/NN - Track.ext`. Navidrome lee tags ID3v2/Vorbis/Flac/Mp4 _embedded_ por defecto: el árbol de directorios es **una pista**, las _tags_ son la fuente de verdad. Una biblioteca con _tags_ correctas se reorganiza sola en la UI aunque los directorios estén desordenados.

> **Cover art**: Navidrome busca primero _embedded art_ en las _tags_ ID3, luego un `cover.jpg`/`cover.png`/`folder.jpg` en el directorio del álbum, luego MusicBrainz cover archive (si está activado). En orden. La primera coincidencia gana.

### Forzar un re-scan

Útil tras añadir ficheros manualmente por SMB o tras reagrupar tags con Picard:

- **UI**: _Settings → Tools → Trigger a full scan_.
- **API** (con un token Subsonic):

  ```bash
  curl -k --resolve music.lan:443:192.168.1.3 \
    "https://music.lan/rest/startScan?u=<admin>&p=<password>&v=1.16.1&c=homelab&f=json"
  ```

> **`inotify` automático**: configurado en el _wizard_ (`Watch for changes: ON`). Detecta nuevos ficheros y borrados en cuanto ocurren. El re-scan manual es para cuando el bit `inotify` se pierde un evento (raro pero ocurre con `fs.inotify.max_user_watches` bajo o cuando el _drop_ por SMB es muy masivo y satura la cola del kernel).

---

## Almacenamiento

Tras el primer arranque, el árbol `/mnt/hd2t/services/navidrome/` queda con los siguientes ficheros relevantes:

```
/mnt/hd2t/services/navidrome/
└── data/
    ├── navidrome.db                # BD SQLite (catálogo + ratings + playlists + users)
    ├── navidrome.db-wal             # WAL de SQLite (presente mientras escribe)
    ├── navidrome.db-shm             # shared memory de SQLite
    ├── navidrome.log                # log activo
    ├── cache/
    │   ├── images/                  # cover art redimensionado por bitrate y tamaño
    │   └── transcoding/             # MP3/Opus generados on-the-fly (regenerable)
    └── plugins/
        └── (vacío inicialmente)     # 0.55+ plugin support, fuera de alcance hoy
```

| Ruta                                                 | Permisos        | Contenido                                                          |
|------------------------------------------------------|-----------------|---------------------------------------------------------------------|
| `/mnt/hd2t/services/navidrome/`                      | `1000:1000 0755` | Raíz del bind mount                                                  |
| `/mnt/hd2t/services/navidrome/data/`                 | `1000:1000 0755` | Configuración persistente                                            |
| `/mnt/hd2t/services/navidrome/data/navidrome.db`     | `1000:1000 0644` | BD SQLite del catálogo                                              |
| `/mnt/hd2t/services/navidrome/data/cache/`           | `1000:1000 0755` | Caches regenerables                                                  |
| `/mnt/hd2t/services/shared/music/` (sólo lectura)    | `root:homelab-media 2775` | Biblioteca de música, montada `:ro` en el contenedor       |

---

## Backup

Patrón S (online, vía `sqlite3 .backup`) sobre la BD del catálogo, más Patrón F (filesystem-only) sobre el resto de `/data`. Resultado: respaldo coherente sin parar Navidrome.

### 1. Descomentar el bloque de Navidrome en `dump-databases.sh`

Editar `~/homelab/backups/borgmatic/hooks/dump-databases.sh` y descomentar la línea que `docs/07-backups/03-backup-docker-volumes.md` dejó preparada:

```diff
 # --- Navidrome (SQLite) — docs/09-multimedia/02-navidrome.md
-# dump_sqlite navidrome navidrome /data/navidrome.db
+dump_sqlite navidrome navidrome /data/navidrome.db
```

> **¿La imagen oficial de Navidrome trae `sqlite3`?**: sí; el binario de Navidrome es _self-contained_ pero la imagen base trae las _busybox tools_ y `sqlite3`. `docker exec navidrome which sqlite3` devuelve `/usr/bin/sqlite3`. Si en algún _bump_ futuro se eliminase, el _hook_ falla con un error claro y se conmuta a `dump_sqlite_cold` (5 s de _downtime_, aceptable de madrugada).

Re-instalar:

```bash
~/homelab/backups/borgmatic/install.sh
sudo /usr/bin/borgmatic --dry-run --verbosity 2 | grep -A2 navidrome
# debe listar el dump previsto
```

Smoke-test del hook ejecutándolo a mano:

```bash
sudo /etc/borgmatic.d/hooks/dump-databases.sh
ls -la /mnt/hd2t/backups/dumps/navidrome-*.sqlite.gz
# navidrome-2026-04-26.sqlite.gz   18M
```

Confirmar que el dump abre como SQLite válido:

```bash
sudo zcat /mnt/hd2t/backups/dumps/navidrome-*.sqlite.gz | file -
# /dev/stdin: SQLite 3.x database, ...
```

### 2. Confirmar que Navidrome está cubierto por `source_directories`

`source_directories: /mnt/hd2t/services` ya incluye `navidrome/data/` por inercia (ver `docs/07-backups/02-borgmatic.md`, sección _Por qué incluir el directorio padre y filtrar_). Las exclusiones de `cache/` ya las cubre el _exclude pattern_ global `*/cache/*`; **no hace falta añadir nada al `config.yaml`**.

Tras el siguiente _run_ programado (madrugada), Navidrome aparece en la lista de archives:

```bash
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL::pi-$(date +%F)T03:30:30" \
    | grep navidrome | head -10
'
# -rw-r--r-- 1000   1000  18.0M Apr 26 03:30 mnt/hd2t/services/navidrome/data/navidrome.db
# -rw-r----- root   root  18.0M Apr 26 03:30 mnt/hd2t/backups/dumps/navidrome-2026-04-26.sqlite.gz
# ...
```

### Restauración

Procedimiento idéntico al **Patrón de restauración común** documentado en `docs/07-backups/03-backup-docker-volumes.md`. En resumen:

1. `docker compose -f ~/homelab/multimedia/docker-compose.yml stop navidrome`.
2. Mover `/mnt/hd2t/services/navidrome/data/` a `data.broken-<ts>` (preservar 24-48 h por si la restauración tampoco arranca).
3. `borg extract` del archive elegido a `/tmp/restore-$$/`, mover en sitio.
4. Restaurar la SQLite desde el dump del Patrón S si la del archive estuviera dañada (raro):

   ```bash
   sudo gunzip -c /mnt/hd2t/backups/dumps/navidrome-YYYY-MM-DD.sqlite.gz \
     > /mnt/hd2t/services/navidrome/data/navidrome.db
   sudo chown 1000:1000 /mnt/hd2t/services/navidrome/data/navidrome.db
   ```

5. `docker compose -f ~/homelab/multimedia/docker-compose.yml up -d navidrome`.
6. Esperar al `(healthy)` (típicamente <30 s).
7. Comprobar UI: usuarios, _ratings_, _starred_, _playlists_ y _play count_ deben recuperarse. La biblioteca de `/music` se reescanea automáticamente y reconstruye el índice contra los ficheros físicos.

> **La biblioteca de música en `/mnt/hd2t/services/shared/music/` no se respalda** (Categoría C). Si se pierde el disco hd2t, hay que volver a llenar la biblioteca desde la fuente original. La BD restaurada conoce los nombres y metadatos, pero los `.flac`/`.mp3` físicos no están — al primer scan, Navidrome los marcará como ausentes hasta que reaparezcan.

---

## Verificación

Antes de dar por cerrado este documento:

- [ ] `~/homelab/multimedia/docker-compose.yml` extendido con el servicio `navidrome` y versionado en git; `~/homelab/multimedia/.env.example` extendido con `NAVIDROME_*`; `~/homelab/multimedia/.env` con valores reales (no versionado).
- [ ] `docker compose -f ~/homelab/multimedia/docker-compose.yml ps` muestra `navidrome` como `(healthy)`.
- [ ] `docker exec navidrome wget -qO- http://localhost:4533/ping` devuelve `{"status":"ok","version":"0.55.x",...}`.
- [ ] `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` acepta el bloque `music.lan` añadido.
- [ ] `curl -k --resolve music.lan:443:192.168.1.3 https://music.lan/ping` devuelve el JSON de status sin redirect (sin Authelia delante).
- [ ] Login interactivo desde el navegador con la cuenta admin funciona; la web UI muestra _Albums_, _Artists_, _Songs_ tras el primer scan.
- [ ] Cliente Subsonic (DSub o Symfonium en Android) configurado con servidor `https://music.lan/`, usuario y contraseña: lista la biblioteca, reproduce un track, el _play count_ se incrementa en la UI tras la reproducción.
- [ ] El log de Navidrome (`docker logs navidrome 2>&1 | grep -i 'remote\|forwarded'`) muestra que `X-Forwarded-For` se procesa: una petición desde el navegador del PC LAN aparece logueada con la IP del PC, no con `172.20.10.x`.
- [ ] `ND_REVERSEPROXYWHITELIST` aplicado: `docker exec navidrome env | grep REVERSE` muestra `172.20.10.0/24`.
- [ ] Dump SQLite generado por `dump-databases.sh`: `sudo ls -la /mnt/hd2t/backups/dumps/navidrome-$(date +%F).sqlite.gz` existe y `file -` lo identifica como `gzip compressed data` con SQLite dentro.
- [ ] El `Caddyfile` para `music.lan` lleva `import security-headers`, `import logging`; **no** lleva `import authelia`.
- [ ] La lista `two_factor` del `access_control.rules` de Authelia **no** menciona `music.lan` (ni siquiera comentado).
- [ ] Watchtower vigila el contenedor: `docker logs watchtower --tail 50 | grep navidrome` muestra al menos un check (label `enable: "true"` activo).
- [ ] `stat -c '%U:%G' /mnt/hd2t/services/navidrome /mnt/hd2t/services/navidrome/data` devuelve `1000:1000` en ambos.
- [ ] `docker exec navidrome id` muestra `uid=1000 gid=1000 groups=1000,${MEDIA_GID}` (o el GID real de `homelab-media`).
- [ ] La biblioteca aparece poblada: en _Settings → About_ el conteo de _Songs_ / _Albums_ / _Artists_ refleja lo que hay en `/mnt/hd2t/services/shared/music/`.

---

## Troubleshooting

### Primer arranque: el contenedor se queda en `starting` indefinidamente

```bash
docker logs navidrome --tail 50
```

Causas comunes:

- **Permisos del bind mount**: si por error se hizo un `chown -R root:root /mnt/hd2t/services/navidrome`, el proceso (que corre como `1000:1000`) falla con `permission denied` al intentar crear `data/navidrome.db`. Restaurar:

  ```bash
  sudo chown -R 1000:1000 /mnt/hd2t/services/navidrome
  docker compose -f ~/homelab/multimedia/docker-compose.yml restart navidrome
  ```

- **`/etc/localtime` ausente**: en algunos hosts minimalistas no existe; Navidrome se queja con `cannot determine local time zone`. Crear el symlink (mismo procedimiento que en Jellyfin):

  ```bash
  sudo ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
  ```

- **Imagen mal descargada**: tras un fallo de red durante el `pull`, la imagen puede quedar parcial. `docker rmi deluan/navidrome:0.55 && docker compose -f ~/homelab/multimedia/docker-compose.yml pull navidrome`.

### "Cannot scan music folder: permission denied"

Síntoma: log de Navidrome muestra `walk /music: open /music/<...>: permission denied`. Causa: el contenedor no es miembro del grupo `homelab-media` y los ficheros están con `2750` (sin `o+r`). Comprobar:

```bash
docker exec navidrome id
# uid=1000 gid=1000 groups=1000   # FALTA el GID de homelab-media
```

Si falta, revisar que `MEDIA_GID` está en `~/homelab/.env` y que el bloque `group_add` está presente en el compose. Re-aplicar:

```bash
cd ~/homelab && make up STACK=multimedia
docker exec navidrome id
# uid=1000 gid=1000 groups=1000,989   # 989 = ejemplo de homelab-media
```

### "X-Forwarded-For ignorado" / IPs reales no aparecen en el log

Navidrome loguea `172.20.10.x` (la IP del contenedor de Caddy) en lugar de la IP del cliente. Causa: `ND_REVERSEPROXYWHITELIST` no incluye la subnet correcta. Comprobar:

```bash
docker exec navidrome env | grep REVERSE
# ND_REVERSEPROXYWHITELIST=172.20.10.0/24
```

Si difiere, actualizar `NAVIDROME_REVERSE_PROXY_WHITELIST` en `~/homelab/multimedia/.env` y `make up STACK=multimedia`.

Si la subnet de la red `homelab` cambió en `docs/02-docker/02-estructura-compose.md` (raro), comprobar:

```bash
docker network inspect homelab --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

### El cliente Subsonic dice "Wrong username or password" pero la web UI funciona

Causa típica: el cliente está usando un protocolo más antiguo (Subsonic clásico con `?p=plain-password`) y el servidor lo rechaza. En **Personal Settings → Security**, comprobar que **Allow plaintext password** está habilitado **sólo si es imprescindible** — preferible actualizar el cliente a una versión que use `?t=<MD5(p+salt)>&s=<salt>` o, mejor, OpenSubsonic con _bearer_.

Si el cliente es DSub, en sus _Settings_ marcar "Use HTTPS" y desmarcar cualquier opción tipo "Force plaintext".

### "Track no aparece en la biblioteca tras un drop por SMB"

Causa: `inotify` se perdió el evento (típico con muchos miles de ficheros copiados a la vez por Samba). Solución: forzar un re-scan:

```bash
# UI: Settings -> Tools -> Trigger a full scan
# o vía API:
docker exec navidrome wget -qO- \
  'http://localhost:4533/rest/startScan?u=<admin>&p=<pass>&v=1.16.1&c=cli&f=json'
```

Si pasa frecuentemente, subir `fs.inotify.max_user_watches` y `max_queued_events` en el host:

```bash
sudo tee /etc/sysctl.d/99-inotify.conf <<'EOF'
fs.inotify.max_user_watches=524288
fs.inotify.max_queued_events=32768
EOF
sudo sysctl --system
docker compose -f ~/homelab/multimedia/docker-compose.yml restart navidrome
```

### "Transcoding falla con FFmpeg: ..."

Causa: un fichero con _tags_ corruptas o un códec exótico (Monkey's Audio APE, WMA Lossless) que el FFmpeg embebido no decodifica. Mitigación:

- Comprobar el fichero a mano:

  ```bash
  docker exec navidrome ffmpeg -i /music/<ruta>/<fichero>.ape 2>&1 | head -20
  ```

- Convertir el fichero a FLAC en otra máquina con un FFmpeg más completo y copiarlo en sitio.
- Si el cliente puede _direct play_ (Symfonium / DSub con FLAC habilitado), forzar _native format_ y saltarse el transcoding.

### La BD `navidrome.db` crece a tamaños desorbitados (>500 MB)

Causas:

- **`scrobble_buffer` no se vacía**: si Last.fm/ListenBrainz están activos pero el servicio externo está caído, los scrobbles se acumulan en una tabla _buffer_. Limpiar (con cuidado, perderás scrobbles pendientes):

  ```bash
  docker exec -u 1000:1000 navidrome sqlite3 /data/navidrome.db \
    "DELETE FROM scrobble_buffer WHERE created_at < datetime('now','-30 days'); VACUUM;"
  ```

- **Histórico de _play_ desproporcionado**: tabla `play_log` (si se activa _full play history_) crece linealmente con cada reproducción. Por defecto Navidrome **no** guarda histórico completo, sólo agregados.
- **Cover art guardado dentro de la BD** (modo _embedded_ activado): comprobar `Settings → Library → Cover Art Storage`. Si está en _embedded_, cambiar a _on-disk_ (cache en `/data/cache/images/`) para mover los blobs fuera de la BD.

---

## Actualización

### Patches de la línea `0.55.x` (vía Watchtower, automático)

Watchtower opt-in está activo. Cada domingo a las 04:00 UTC, Watchtower comprueba el _digest_ del _tag_ `0.55`; si hay uno nuevo, hace `pull` + `recreate` del contenedor Navidrome. Sin acción del operador.

Verificar tras un domingo:

```bash
docker logs watchtower --tail 50 | grep navidrome
# time=... msg="Found new deluan/navidrome:0.55 image"
# time=... msg="Stopping /navidrome"
# time=... msg="Creating /navidrome"
```

Si tras la recreación el `(healthy)` no llega en 1 minuto, ir a **Troubleshooting**.

### Bumps de minor (`0.55 → 0.56`, manual)

```bash
# 1. Leer las release notes
xdg-open https://github.com/navidrome/navidrome/releases/tag/v0.56.0
# Buscar "Breaking changes" y "Database migrations" — si toca alguna integración
# activa o hay migración irreversible, planificar el cambio antes del bump.

# 2. Backup completo previo
sudo /usr/bin/borgmatic --verbosity 1
# Verificar que el último archive tiene fecha de hoy:
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list --short "$BORG_REPO_LOCAL" | tail -1
'

# 3. Cambiar el tag y aplicar
$EDITOR ~/homelab/multimedia/.env
# NAVIDROME_IMAGE_TAG=0.56
cd ~/homelab
make pull STACK=multimedia
make up   STACK=multimedia

# 4. Vigilar el log durante la migración del schema
docker compose -f ~/homelab/multimedia/docker-compose.yml logs -f navidrome
# Buscar:
#   level=info msg="Database schema needs upgrade" current=... required=...
#   level=info msg="Schema upgrade completed"
# Si el log muestra ERROR o el contenedor entra en restart loop, ir a Troubleshooting.

# 5. Validar la web UI, los clientes Subsonic y los ratings/playlists
```

> **Migraciones irreversibles**: una vez Navidrome 0.56 arranca y migra el schema, **no hay vuelta atrás** sin restaurar desde backup. Por eso el paso 2 (backup completo previo) es obligatorio.

---

## Referencias

- Documentación oficial — Navidrome: <https://www.navidrome.org/docs/>
- Documentación oficial — Docker installation: <https://www.navidrome.org/docs/installation/docker/>
- Configuration options (variables `ND_*`): <https://www.navidrome.org/docs/usage/configuration-options/>
- OpenSubsonic API spec: <https://opensubsonic.netlify.app/>
- Reverse proxy con Navidrome: <https://www.navidrome.org/docs/usage/reverse-proxy/>
- Releases del proyecto: <https://github.com/navidrome/navidrome/releases>
- Imagen Docker oficial: <https://hub.docker.com/r/deluan/navidrome>
- Clientes Subsonic compatibles: <https://www.navidrome.org/docs/overview/#apps>
- Documentos relacionados del homelab:
  - `docs/02-docker/02-estructura-compose.md` — convenciones de stacks, red `homelab`, regla `:ro` en biblioteca multimedia.
  - `docs/03-red/04-caddy.md` — Caddy, CA local, _snippets_ `security-headers` y `logging`.
  - `docs/03-red/02-pihole.md` — DNS local `*.lan`.
  - `docs/04-seguridad/01-authelia.md` — por qué Navidrome **no** entra en `forward_auth`.
  - `docs/06-almacenamiento/02-samba.md` — _share_ `music` que escribe en la misma carpeta que Navidrome lee.
  - `docs/07-backups/01-estrategia-backup.md` — biblioteca de música como Categoría C (no entra en Borg).
  - `docs/07-backups/02-borgmatic.md` — `source_directories`, `exclude_patterns` global.
  - `docs/07-backups/03-backup-docker-volumes.md` — Patrón S, _hook_ `dump_sqlite navidrome`.
  - `docs/09-multimedia/01-jellyfin.md` — primer servicio del stack `multimedia`, convenciones compartidas.
  - `docs/09-multimedia/03-audiobookshelf.md` (siguiente fase) — siguiente servicio del stack.
