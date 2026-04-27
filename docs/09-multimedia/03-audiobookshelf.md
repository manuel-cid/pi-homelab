# Audiobookshelf (servidor de audiolibros y podcasts)

## Descripción

Despliegue de **Audiobookshelf** (en adelante, **ABS**) como servidor de audiolibros y podcasts del homelab: indexa la biblioteca compartida de audiolibros (`/mnt/hd2t/services/shared/audiobooks/`), descarga y mantiene una biblioteca propia de podcasts (`/mnt/hd2t/services/audiobookshelf/podcasts/`), expone una **web UI** y una **API REST** (`https://audiobooks.lan`) con seguimiento de progreso por usuario, sincronización entre dispositivos, capítulos, marcadores, _bookmarks_ y la app oficial Android/iOS. Toda la configuración persistente, la BD SQLite del catálogo (`absdatabase.sqlite`) y los metadatos (carátulas, descripciones, tracks de capítulos…) viven en el disco externo **hd2t** (`/mnt/hd2t/services/audiobookshelf/`); la biblioteca de audiolibros se monta `:ro` desde el árbol compartido pre-creado en `docs/01-sistema/04-estructura-directorios.md` (con bit `setgid` y grupo `homelab-media`, lectura compartida con Samba).

Este documento **se suma al _stack_ `multimedia`** que estrenó `docs/09-multimedia/01-jellyfin.md` (`~/homelab/multimedia/`) y al que `docs/09-multimedia/02-navidrome.md` añadió Navidrome. No se crea un compose nuevo: se añade un servicio `audiobookshelf` al `~/homelab/multimedia/docker-compose.yml` ya existente y se completan las variables del `.env` correspondiente. Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone ABS en `https://audiobooks.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), el mismo nombre `audiobooks.lan` resuelve a `192.168.1.3` desde dentro del _tailnet_ gracias al _Split DNS_ delegado a Pi-hole.

> **Alcance**: este documento despliega ABS con su autenticación nativa (usuario + contraseña, _root user_ creado en el primer arranque), configura una biblioteca _audiobooks_ apuntando a `/audiobooks` (`:ro`, gestionada por el operador / Samba) y una biblioteca _podcasts_ apuntando a `/podcasts` (`:rw`, gestionada por el propio ABS), deja la transcodificación _on-the-fly_ activa por defecto (la Pi 5 transcodifica audio sin sudar, igual que en Navidrome — ver **Decisiones de diseño**) y entrega un _hook_ Borgmatic listo para hacer dump _online_ de la SQLite del catálogo. **No** delega autenticación a Authelia vía `forward_auth` (rompería la app móvil oficial y todos los clientes de terceros que hablan con la API REST de ABS — ver **Decisiones de diseño**). **No** activa OIDC / SSO contra Authelia (ABS lo soporta desde 2.10, pero la cuenta nativa del _root user_ con 2FA del propio ABS es suficiente para el alcance LAN+VPN). **No** habilita la _backups_ feature interna de ABS (sería redundante con Borgmatic — ver **Decisiones de diseño**). **No** automatiza la importación masiva de audiolibros desde Audible / Goodreads ni instala _Lazy Audiobookshelf_ ni _Audnexus_ scrapers además del oficial: queda como _opt-in_ documentado en _Configuración_.

> **Recordatorio de red**: Audiobookshelf **no se publica al host**. Caddy lo alcanza por DNS interno de Docker (`audiobookshelf:80` en la red `homelab`). Pi-hole resuelve `audiobooks.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`). El operador entra siempre por `https://audiobooks.lan/` (LAN) o por el mismo nombre desde el _tailnet_.

---

## Requisitos previos

- `docs/09-multimedia/01-jellyfin.md` y `docs/09-multimedia/02-navidrome.md` completados: el _stack_ `multimedia` (`~/homelab/multimedia/`) ya existe con `docker-compose.yml`, `.env`, `.env.example` y `.gitignore`. La red `homelab` está creada como externa, las variables globales `TZ`, `PUID`, `PGID`, `MEDIA_GID` están rellenas en `~/homelab/.env`, y el _Makefile_ de operación expone `make up STACK=multimedia`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/audiobookshelf/` ya existe y está reasignado a ownership `1000:1000` (paso 7 de aquel doc, "Reasignar ownership de los servicios LinuxServer.io" — ABS se reasigna a `1000:1000` aunque la imagen oficial no sea LSIO, porque es el UID del operador y el de los demás servicios multimedia que comparten la biblioteca). El árbol `/mnt/hd2t/services/shared/audiobooks/` existe con `root:homelab-media 2775` para que ABS lo lea.
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada y por defecto desactivada. Audiobookshelf será **opt-in** explícito (ver **Decisiones de diseño**).
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `audiobooks.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile` y la CA local firma `*.lan`.
- `docs/04-seguridad/01-authelia.md` completado **opcionalmente**: si Authelia ya está montado, en este documento se decide explícitamente **no** poner ABS detrás de `forward_auth`. La lista `two_factor` del `access_control.rules` de Authelia **no incluye** `audiobooks.lan` (ni siquiera comentado).
- `docs/06-almacenamiento/02-samba.md` completado o pendiente: la _share_ `audiobooks` de Samba escribe en `/mnt/hd2t/services/shared/audiobooks/` con `force user = homelab` y `force group = homelab-media`, exactamente lo que ABS escanea. Si Samba aún no está montado, la biblioteca se rellena por SFTP / `rsync` directo.
- `docs/07-backups/02-borgmatic.md` y `docs/07-backups/03-backup-docker-volumes.md` completados (recomendado): el `source_directories: /mnt/hd2t/services` ya engloba `audiobookshelf/`, el bloque del _hook_ `dump-databases.sh` para Audiobookshelf ya está preparado y comentado. Este doc termina **descomentando** ese bloque.
- Conectividad saliente para descargar la imagen (sólo la primera vez):

  ```bash
  docker pull --platform linux/arm64 ghcr.io/advplyr/audiobookshelf:2.16 >/dev/null && echo OK
  ```

- Que el host **no** tenga ya un servicio escuchando en `:13378` ni en `:80` localmente (sólo aplica si en algún _troubleshoot_ se publicara el puerto):

  ```bash
  sudo ss -tulpn '( sport = :13378 or sport = :80 )'
  ```

  Salida esperada: vacía (o sólo Caddy en `:80` si está publicado a `192.168.1.3`). Audiobookshelf no publica `:80` al host (Caddy lo alcanza por DNS interno).

- Espacio en `/mnt/hd2t`: como mínimo **1 GB libre** para que ABS arranque cómodo. La cuota real la dictan la BD del catálogo (~50–200 MB para una biblioteca de varios miles de audiolibros), los metadatos descargados (`/metadata/items/`, ~10–50 MB por cada 100 audiolibros con _cover art_ y _chapter art_) y los podcasts descargados (variable, _depende_ del operador). En estado estable y sólo con audiolibros, el árbol `/mnt/hd2t/services/audiobookshelf/` se mantiene por debajo de **2 GB**; con podcasts puede crecer a decenas de GB.

  ```bash
  df -h /mnt/hd2t
  ```

---

## Decisiones de diseño

### Por qué Audiobookshelf (y no Booksonic / LazyLibrarian / "audiobooks en Navidrome")

El homelab necesita un servidor especializado para audiolibros y podcasts: la diferencia clave frente a la música es que el caso de uso es **contenido largo con seguimiento de posición**. Quien escucha un audiolibro de 18 horas necesita pausar en un capítulo, retomar al día siguiente desde el segundo exacto, sincronizar el progreso entre el móvil del coche y el altavoz Bluetooth de la cocina, y que la app sepa qué capítulo es "siguiente". Los servidores de música _streaming_ no resuelven este problema: tratan cada fichero como un track independiente.

Tres alternativas descartadas y por qué:

| Candidato                | Por qué se descarta                                                                                                                                                                                                                                                                                            |
|--------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Navidrome "audiobook tag"** | Navidrome permite marcar carpetas como "audiobook" en su organización, pero **no** soporta capítulos (chapters), **no** tiene _resume_ por dispositivo, **no** sincroniza progreso entre clientes y los clientes Subsonic (DSub, Symfonium) tratan cada `.m4b` como una pista única gigante. Mata la UX. |
| **Booksonic-Air**        | _Fork_ de Subsonic / Airsonic-Advanced especializado en audiolibros. Mantenimiento muy esporádico (último release maduro hace años), la app móvil va a la zaga, transcoding peor pulido y la API de progreso es _proprietary_, no compatible con la API HTTP estándar de los clientes modernos.            |
| **Plex "audiobooks"**    | Plex _Audiobooks_ existe pero hereda los mismos problemas que Plex en el resto del homelab (cuenta `plex.tv`, _claim_, dependencia de SaaS, freemium, ver `docs/09-multimedia/01-jellyfin.md`). Filosofía contraria al homelab "todo local + Tailscale".                                                  |

Audiobookshelf gana por:

- **100 % gratis y libre** (MIT): código, web UI moderna (Vue + Express), apps móviles oficiales gratuitas (Android Play Store + F-Droid + iOS App Store) sin _freemium_ ni cuentas externas.
- **Modelo de datos pensado para audiolibros**: capítulos, _series_, _collections_, _ASIN_ Audible para metadatos, sincronización de progreso por usuario, _bookmarks_ con texto, conversión M4B con _embedded chapters_ desde MP3 sueltos, podcasts con auto-descarga.
- **Imagen Docker oficial multi-arch ARM64** (`ghcr.io/advplyr/audiobookshelf`), publicada por el _maintainer_ del proyecto (advplyr).
- **Footprint razonable**: ~120–200 MB de RAM idle, Node.js + SQLite. Algo más pesado que Navidrome (Go) pero ligero comparado con Jellyfin (.NET + FFmpeg activo). Conviven los tres en la Pi 5 sin pelearse.
- **BD SQLite con WAL**: respaldable _online_ con `sqlite3 .backup` (Patrón S del homelab). Sin _runtime_ extra de Postgres/MariaDB.
- **App móvil oficial** (Android + iOS): la única razón por la que sostener un servidor de audiolibros propio merece la pena. La app conoce capítulos, descarga _offline_, sincroniza al volver online, integra con Bluetooth media controls del coche y del reloj.
- **API REST documentada**: <https://api.audiobookshelf.org/>. Permite integraciones con Homepage / Homarr (`docs/12-dashboards/`) sin parsear HTML.

### Imagen y _tag_

- **`ghcr.io/advplyr/audiobookshelf:2.16`** — imagen oficial del proyecto, _tag_ "major.minor" siguiendo la convención del homelab (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`, "Tag mayor o LTS"). Multi-arch (`linux/arm64`). El _tag_ `2.16` sigue la línea estable de 2026; los _bumps_ de patch (`2.16.0 → 2.16.1 → 2.16.2`) llegan con _bug fixes_, _security patches_, scrapers de metadatos y mejoras de la app, sin _breaking changes_ del _schema_ SQLite.
- **Por qué no `:latest`**: ese _tag_ se mueve cada vez que sale una nueva versión _minor_ (`2.16 → 2.17`); un `docker compose pull` accidental durante un _bump_ de minor podría introducir cambios de _schema_ irreversibles en `absdatabase.sqlite`.
- **Por qué no `:nightly` ni `:edge`**: tags inestables construidos a partir de _master_; no para servicio en producción doméstica.
- **Por qué `ghcr.io/advplyr/...` y no `linuxserver/audiobookshelf`**: la imagen oficial del autor del proyecto se publica primero, lleva exactamente el binario que el _maintainer_ valida y suele tener 1–3 días de adelanto sobre la LSIO. La LSIO añade `s6-overlay`, gestiona `PUID`/`PGID` por _entrypoint_ y se reasignan permisos en cada arranque, pero a cambio del retraso. Aquí, igual que en Jellyfin (`docs/09-multimedia/01-jellyfin.md`), preferimos la oficial y bajamos el contenedor a `1000:1000` con `user:` en el compose.

> **Convenio de versionado de Audiobookshelf**: el proyecto trata cada incremento de _minor_ (`2.NN → 2.N(N+1)`) como _major_ a efectos prácticos (puede haber migraciones de schema irreversibles). El _tag_ `:2.16` apunta al último parche de esa línea (`2.16.x`). Ver _Releases_ en GitHub para confirmar la línea estable vigente cuando se ejecute este documento.

#### Watchtower **opt-in**

Razones:

- **Patches frecuentes sin _breaking changes_**: la línea `2.16.x` recibe _patch releases_ con _security fixes_ del propio ABS, de Node.js base y de los _scrapers_ de metadatos (la API de Audnexus / Goodreads cambia con frecuencia y los parches de _patch_ alinean los _scrapers_ con la API actual). Mantenerse al día sin tocar a mano es deseable.
- **Schema de BD estable dentro de una `minor`**: las _migrations_ irreversibles del catálogo sólo se disparan al saltar de `2.16` a `2.17`. Dentro de `2.16.x`, los _patches_ son intercambiables. Watchtower puede reciclar el contenedor con seguridad.
- **Sin estado en RAM**: ABS persiste el progreso de escucha de cada cliente en `/config/absdatabase.sqlite` con `WAL` activo y _flush_ periódico (cada ~30 s o al recibir `SIGTERM`). Reciclar el contenedor durante la madrugada (la ventana de Watchtower es domingo a las 04:00 UTC, ver `docs/02-docker/04-watchtower.md`) no rompe sesiones — la app móvil cachea el progreso local y sincroniza al primer _poll_ tras el reinicio.

Etiquetar el contenedor con `com.centurylinklabs.watchtower.enable: "true"`. Coherente con la lista global de `docs/02-docker/04-watchtower.md` (sección _candidatos a opt-in desde el principio_) y con el criterio aplicado a Jellyfin y Navidrome.

> **Bumps de _minor_** (`2.16 → 2.17`): se hacen **a mano**, fuera de Watchtower. Cambiar `AUDIOBOOKSHELF_IMAGE_TAG=2.17` en `~/homelab/multimedia/.env`, leer las _release notes_ del proyecto en GitHub, hacer backup del `/config` previo (Borgmatic + dump SQLite) y aplicar `make pull STACK=multimedia && make up STACK=multimedia`. Watchtower con _tag_ `2.16` no salta a `2.17` automáticamente porque mira el _digest_ del _tag_ exacto que está pinneado.

### Modo de red: `bridge` (red `homelab`), no `host`

Mismo razonamiento que en Jellyfin (`docs/09-multimedia/01-jellyfin.md`) y Navidrome (`docs/09-multimedia/02-navidrome.md`): ABS corre en la red `homelab` (`bridge`, `172.20.10.0/24`), Caddy lo alcanza por nombre interno (`audiobookshelf:80`), no se publica ningún puerto al host. La app móvil oficial de ABS se configura con la URL `https://audiobooks.lan/` la primera vez y la recuerda; no necesita _auto-discovery_.

> **Único caso de fricción posible**: la _server discovery_ de ABS en la red local (mDNS) **no atraviesa el bridge**. Si el operador o un familiar abriera la app por primera vez y esperase encontrar el servidor "automáticamente" en la WiFi, no aparecerá. Solución: introducir la URL a mano una vez. La app la guarda y no vuelve a pedirla.

### Volumen de la biblioteca de audiolibros: `/services/shared/audiobooks:/audiobooks:ro`

La biblioteca de audiolibros se monta **read-only** dentro del contenedor:

```yaml
volumes:
  - /mnt/hd2t/services/shared/audiobooks:/audiobooks:ro
```

Razones (idénticas a Navidrome con la biblioteca de música):

- **ABS no debería escribir en la biblioteca**. El servidor _indexa_, lee tags ID3/M4B/Vorbis y _embedded chapters_, y guarda los **metadatos derivados** (descripciones, _cover art_ extraída, _chapter list_ resuelta…) en su árbol propio `/metadata/items/<library_item_id>/`. **No** modifica los ficheros originales: las _tags_ las cambia el operador (con `Picard`, `mp3tag`, `mp4chaps`…) en otra máquina o por SMB.
- **Samba** (`docs/06-almacenamiento/02-samba.md`) sí escribe en la misma carpeta cuando el operador arrastra un audiolibro manualmente — montaje `:rw` en _ese_ contenedor, no en ABS.
- **`:ro` mata por construcción** la mayoría de _data loss_ accidentales: un bug en ABS no podrá nunca borrar la biblioteca; un ataque a la API podrá editar metadatos en `/metadata/`, ratear, crear _collections_ o cambiar el progreso, pero no `unlink()` ficheros del disco.

> **Esta convención está alineada con `docs/02-docker/02-estructura-compose.md`** (sección **Volúmenes**, regla `:ro` explícito) y con la regla equivalente de Jellyfin sobre `services/shared/media` y de Navidrome sobre `services/shared/music`.

> **Excepción documentada — _embedded metadata back to file_**: ABS tiene una opción _Settings → Item Metadata Settings → Save metadata to file_ que **escribe** las tags M4B/MP3 modificadas de vuelta al fichero original. **Esta opción se deja DESACTIVADA por defecto** en este homelab. Si en algún momento se activase, el montaje tendría que pasar a `:rw`. Mientras eso no ocurra, `:ro` es la postura segura.

### Volumen de podcasts: `/services/audiobookshelf/podcasts:/podcasts:rw`

A diferencia de los audiolibros (que el operador deposita por SMB), los **podcasts los descarga ABS por sí mismo** desde URLs RSS. Eso requiere escritura. Por eso los podcasts viven **fuera de `/services/shared/`** y dentro del territorio propio de ABS:

```yaml
volumes:
  - /mnt/hd2t/services/audiobookshelf/podcasts:/podcasts
```

Razones:

- **ABS gestiona el ciclo de vida**: descarga episodios nuevos, los borra cuando cumplen retención, regenera tags con metadatos del feed, baja _cover art_. Es el dueño del directorio.
- **No se comparte con Samba**: el operador rara vez quiere "arrastrar un podcast" desde su portátil; los podcasts entran por RSS. Si en algún caso aislado quiere escuchar un episodio en un reproductor local, lo descarga desde la web UI de ABS.
- **Permite excluirlos de Borgmatic con un patrón limpio** (`/mnt/hd2t/services/audiobookshelf/podcasts/*` queda fuera del set "config", no del set "shared"): los podcasts son re-descargables desde sus feeds.

> **Tamaño de podcasts**: si el operador se suscribe a 5–10 podcasts con retención de "últimos 30 días", el árbol `/podcasts/` puede ocupar **5–20 GB**. Con retención agresiva (un mes, comprimidos a Opus 64 kbps) se queda en torno a **2 GB**. Vigilar con `du -sh /mnt/hd2t/services/audiobookshelf/podcasts/`.

### Transcodificación: **activa** (igual que Navidrome, distinto de Jellyfin)

A diferencia del vídeo (donde la Pi 5 no aguanta transcoding por hardware ni por software para más de un _stream_ — ver `docs/09-multimedia/01-jellyfin.md`), el **audio sí se transcodifica sin problema** en una Pi 5:

- Un _stream_ M4B AAC 128 kbps → MP3 64 kbps (para datos móviles muy limitados) consume ~2-4 % de un _core_ ARM A76. Diez _streams_ simultáneos cabrían holgados.
- FFmpeg viene en la imagen oficial de ABS (binario embebido, no se necesita `apt`).
- La app oficial de ABS y los clientes web pueden hacer _direct play_ de M4B/MP3/Opus sin transcoding: típicamente **no se transcodifica nunca** salvo cuando el operador fuerza un bitrate específico desde la app para datos móviles.

Conclusión: **se deja la transcodificación habilitada con la configuración por defecto**. No hay que tocar nada. La _transcoding cache_ (gestionada internamente por ABS, en `/metadata/cache/`) se vacía al cerrar la sesión.

> **Cuándo desactivarla**: nunca de forma explícita; sin demanda de transcoding la cache no crece. Si la _cache_ creciese desbocada por bug, se puede limitar el tamaño en _Settings → Server → Maximum Stream Time_ y _Bitrate_, pero no es la situación normal.

### `forward_auth` con Authelia: **NO** para Audiobookshelf

Tentación natural una vez Authelia está montada: añadir `import authelia` al bloque `audiobooks.lan` del `Caddyfile`. **No se hace**, exactamente por las mismas razones que Jellyfin y Navidrome:

- **La app móvil oficial** (Android + iOS) habla con ABS por su **API REST** usando un _bearer token_ JWT (`Authorization: Bearer ...`) emitido por `/login`. **No** sabe redirigirse a un portal _web_, no resuelve un _challenge_ OIDC, no rellena formularios HTML. Si Caddy intercepta el _request_ y devuelve `302 Location: https://auth.lan/?rd=...`, la app falla en bucle.
- **El cliente web del navegador** hace login JSON puro contra `/login` y recibe un JWT. Authelia delante = el navegador recibe el HTML de la _login page_ de Authelia en lugar del JSON con el token, y la web rompe.
- **Apps de terceros** (Plappa, Voice, ShelfPlayer, AudioBookshelf-CLI) son aún más estrictas: muchas no manejan _redirect 30x_ y abortan ante el primer HTML inesperado.
- **Sincronización de progreso _push_** entre dispositivos: la app reporta posición cada ~10 segundos a `/api/me/progress`. Un _challenge_ OIDC en cada _request_ rompe la cadencia y produce un consumo de batería importante en el móvil.

Solución correcta: **ABS autentica con su sistema nativo** (usuario + contraseña por usuario, gestionado en la web UI). ABS soporta opcionalmente **OIDC/SSO** (desde 2.10) si el operador quisiera delegar en Authelia más adelante; no se activa aquí porque añade complejidad sin valor para el alcance LAN+VPN.

> **Resumen operativo**: el bloque `audiobooks.lan` del `Caddyfile` lleva `import security-headers` y `import logging`, pero **no** `import authelia`. Caddy actúa como _reverse proxy_ "tonto" que termina TLS, propaga `X-Forwarded-*` y deja a ABS la autenticación.

### Catálogo en SQLite (no MariaDB/Postgres)

Audiobookshelf **sólo soporta** SQLite como _backend_ del catálogo. Esta decisión la toma el proyecto _upstream_, no el homelab. Implicaciones:

- **Footprint mínimo**: la BD vive en `/config/absdatabase.sqlite` sin contenedor extra. Para una biblioteca de varios miles de audiolibros con progreso por 3-4 usuarios, ronda los **50–200 MB**.
- **Backups con Patrón S** (`docs/07-backups/03-backup-docker-volumes.md`): la imagen oficial de Audiobookshelf **incluye `sqlite3` en el _PATH_** (la imagen base trae `apt`-instalado el cliente CLI), así que se puede ejecutar `sqlite3 .backup` _online_ sin parar el contenedor. Si por alguna razón no estuviera, el _hook_ cae automáticamente a Patrón S-fría (parar contenedor, copiar fichero, arrancar) — _downtime_ ~5 s.
- **WAL activo**: ABS arranca SQLite con `journal_mode=WAL`. Eso significa que `absdatabase.sqlite-wal` y `absdatabase.sqlite-shm` están presentes durante la ejecución. **Importante**: si se hace una copia "en caliente" del `.sqlite` por `cp` directo sin `sqlite3 .backup`, la copia puede quedar inconsistente. Por eso `dump_sqlite` es la única vía válida (mismo razonamiento que Jellyfin y Navidrome).

### Backups internos de ABS: **deshabilitados**

Audiobookshelf incluye una _feature_ propia "Server → Backups" que crea `.audiobookshelf` _archive files_ (esencialmente un tar con la BD + metadatos selectos) en `/metadata/backups/`. Se puede programar diaria, retenida por número de copias.

**Aquí se deja DESHABILITADA** por las siguientes razones:

- **Redundante con Borgmatic**: el flujo del homelab es Patrón S (dump SQLite _online_) + Borgmatic snapshot del árbol completo. Doble backup local sin _offsite_ no añade resiliencia.
- **Los backups internos de ABS guardan en el mismo disco** (`/mnt/hd2t/services/audiobookshelf/metadata/backups/`). Si se pierde hd2t, se pierden también esos backups. Borgmatic, en cambio, replica al destino offsite (S3/Backblaze).
- **Crecimiento descontrolado**: con la retención por defecto (2 copias) ocupan ~200 MB; con retención generosa (30 días) pueden meter varios GB redundantes. La política de Borgmatic ya está afinada (`docs/07-backups/02-borgmatic.md`).
- **Borgmatic deduplica** entre snapshots; los `.audiobookshelf` no.

> Si el operador quisiera mantener los backups internos como _belt-and-suspenders_, basta con dejarlos activos en _Settings → Backups_ y excluir `*/audiobookshelf/metadata/backups/*` en el `exclude_patterns` de Borgmatic. No se documenta aquí porque el _opt-out_ por defecto es la postura recomendada.

### Almacenamiento

| Ruta en el host                                              | Contenido                                                            | Versionable           | Backup                              |
|--------------------------------------------------------------|----------------------------------------------------------------------|-----------------------|-------------------------------------|
| `~/homelab/multimedia/docker-compose.yml`                    | Definición del _stack_ (compartida con Jellyfin/Navidrome)           | git                   | git                                 |
| `~/homelab/multimedia/.env`                                  | Imágenes pinneadas + variables del _stack_                           | **NO** (`.gitignore`) | git aparte (nota local)             |
| `~/homelab/multimedia/.env.example`                          | Plantilla con nombres de variables, sin valores                      | git                   | git                                 |
| `/mnt/hd2t/services/audiobookshelf/config/`                  | `absdatabase.sqlite` + `server.json` + secrets                       | **NO** versionable    | **Sí** (Borgmatic + dump)            |
| `/mnt/hd2t/services/audiobookshelf/config/absdatabase.sqlite`| BD SQLite del catálogo (libros, progreso, usuarios, _bookmarks_)     | **NO**                | **Sí** (Borgmatic vía dump)         |
| `/mnt/hd2t/services/audiobookshelf/metadata/`                | Cover art + descripciones + chapter art descargados                  | **NO**                | **Sí** (Borgmatic, regenerable)      |
| `/mnt/hd2t/services/audiobookshelf/metadata/cache/`          | Cache de _streaming_ y transcoding (regenerable)                     | **NO**                | **NO** — excluido por `*/cache/*`   |
| `/mnt/hd2t/services/audiobookshelf/metadata/backups/`        | Backups internos de ABS (deshabilitados aquí)                        | **NO**                | **NO** — excluido por patrón        |
| `/mnt/hd2t/services/audiobookshelf/podcasts/`                | Episodios de podcasts descargados por ABS                            | **NO**                | **NO** — Categoría C, regenerable    |
| `/mnt/hd2t/services/shared/audiobooks/`                      | Biblioteca de audiolibros, montada `:ro` en ABS                      | **NO**                | **NO** — Categoría C, regenerable    |

> **`cache/` excluido**: el _exclude pattern_ global `*/cache/*` de `docs/07-backups/02-borgmatic.md` ya lo cubre. Los _cover art_ redimensionados y los _transcoding cache_ se regeneran al primer request.

> **Biblioteca compartida en `/services/shared/audiobooks/`**: política Categoría C de `docs/07-backups/01-estrategia-backup.md` — _no entra en Borg_. La BD del catálogo de ABS (que sí entra) describe qué hay y dónde, junto con _ratings_, _bookmarks_ y _progreso_, pero los `.m4b`/`.mp3` mismos no se respaldan. Si se pierde el disco hd2t, la biblioteca de audiolibros se restaura **re-importándola** desde la copia que el operador tenga en otro sitio (típicamente el laptop o un disco USB de archivo).

> **Podcasts en `/services/audiobookshelf/podcasts/`**: técnicamente _dentro_ del `source_directories` de Borgmatic (porque es subárbol de `services/audiobookshelf/`), pero **excluidos explícitamente** por el patrón `*/audiobookshelf/podcasts/*` añadido en este documento al `borgmatic/config.yaml`. Cualquier episodio se re-descarga desde el feed RSS original.

---

## Estructura del _stack_ `multimedia` tras este documento

```
~/homelab/multimedia/
├── docker-compose.yml        # ← extendido (servicio audiobookshelf añadido)
├── .env                      # ← extendido (variables AUDIOBOOKSHELF_*)
├── .env.example              # ← extendido (plantilla de AUDIOBOOKSHELF_*)
└── .gitignore                # sin cambios
```

Y en el disco externo, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/audiobookshelf/
├── config/                   (vacío al empezar; el primer arranque lo puebla)
├── metadata/                 (vacío al empezar)
└── podcasts/                 (vacío al empezar)
```

Crear los subdirectorios (si no existen ya):

```bash
sudo mkdir -p /mnt/hd2t/services/audiobookshelf/{config,metadata,podcasts}
sudo chown -R 1000:1000 /mnt/hd2t/services/audiobookshelf
```

> **Ownership de `/mnt/hd2t/services/audiobookshelf/`**: ya está fijado por `docs/01-sistema/04-estructura-directorios.md` paso 7 a `1000:1000`. El contenedor corre como `${PUID}:${PGID}` (= `1000:1000`) gracias a la directiva `user:` del compose, así que escribe sin fricciones. La creación de los subdirectorios `config/`, `metadata/` y `podcasts/` mantiene el ownership heredado.

> **Ownership de `/mnt/hd2t/services/shared/audiobooks/`**: `root:homelab-media 2775` (bit `setgid` activo). ABS sólo lee (`:ro`); para garantizar lectura por GID en lugar de "otros", se añade `MEDIA_GID` al contenedor como **grupo suplementario** vía `group_add`, igual que en Jellyfin y Navidrome.

---

## Variables de entorno

Añadir las siguientes líneas al `~/homelab/multimedia/.env.example` (debajo de las ya existentes para Jellyfin y Navidrome):

```bash
# --- Audiobookshelf -------------------------------------------------------
# https://github.com/advplyr/audiobookshelf/releases — patches automáticos
# vía Watchtower; bumps de minor (2.16 -> 2.17) a mano con dump previo de
# la SQLite.
AUDIOBOOKSHELF_IMAGE_TAG=2.16

# URL pública canónica del servicio. Usada por ABS para construir URLs
# absolutas en feeds RSS de podcasts (cuando se compartan), notificaciones
# por email (si se configurase SMTP) y la metadata OIDC (.well-known) si se
# activase SSO contra Authelia (fuera de alcance hoy).
AUDIOBOOKSHELF_BASE_URL=https://audiobooks.lan
```

Copiar a `.env` (ya creado por el doc de Jellyfin):

```bash
$EDITOR ~/homelab/multimedia/.env
# Añadir los mismos AUDIOBOOKSHELF_* con los valores reales.
```

> **`.env` aquí no contiene secretos** (ABS gestiona las credenciales de los usuarios en `/config/absdatabase.sqlite`, hashed con bcrypt; el `JWT_SECRET` se autogenera al primer arranque y se persiste en `/config/server.json`). Aun así, se mantiene `0600` y fuera de git por consistencia con el resto de _stacks_.

---

## `~/homelab/multimedia/docker-compose.yml` (extensión)

Añadir el siguiente servicio al compose ya existente, **a continuación** del bloque `navidrome:` y **antes** del bloque `networks:` final:

```yaml
  # ---------------------------------------------------------------------------
  # Audiobookshelf — servidor de audiolibros y podcasts.
  # Comparte red 'homelab' con jellyfin y navidrome. Caddy alcanza los tres
  # por nombre interno (jellyfin:8096, navidrome:4533, audiobookshelf:80).
  # ---------------------------------------------------------------------------
  audiobookshelf:
    image: ghcr.io/advplyr/audiobookshelf:${AUDIOBOOKSHELF_IMAGE_TAG}
    container_name: audiobookshelf
    hostname: audiobookshelf
    restart: unless-stopped
    user: "${PUID}:${PGID}"
    group_add:
      # Permite a ABS LEER /mnt/hd2t/services/shared/audiobooks/ por GID en
      # lugar de depender del bit 'o+r'. MEDIA_GID viene del .env global,
      # ver docs/01-sistema/04-estructura-directorios.md.
      - "${MEDIA_GID}"
    environment:
      TZ: ${TZ}
      # ABS arranca por defecto en :80; conservamos ese puerto interno.
      # Caddy resuelve audiobookshelf:80 por DNS interno de la red 'homelab'.
      PORT: "80"
      HOST: "0.0.0.0"
      # Rutas internas (las imágenes oficiales las leen de estas vars).
      CONFIG_PATH: /config
      METADATA_PATH: /metadata
      # SOURCE: helps the project's anonymous telemetry to differentiate
      # native installs vs Docker. No envía datos de uso; sólo el plano
      # de instalación. Documentado en upstream.
      SOURCE: "docker"
    volumes:
      - /mnt/hd2t/services/audiobookshelf/config:/config
      - /mnt/hd2t/services/audiobookshelf/metadata:/metadata
      # Biblioteca de audiolibros compartida — read-only (Samba la escribe).
      - /mnt/hd2t/services/shared/audiobooks:/audiobooks:ro
      # Podcasts — gestionados por ABS, escritura habilitada.
      - /mnt/hd2t/services/audiobookshelf/podcasts:/podcasts
      # Hora del host coincidente.
      - /etc/localtime:/etc/localtime:ro
    networks:
      homelab:
        aliases:
          - audiobookshelf  # Caddy resuelve 'audiobookshelf:80' por este alias
    labels:
      homelab.stack: "multimedia"
      homelab.backup: "true"   # /mnt/hd2t/services/audiobookshelf entra en Borgmatic
      # Opt-in: patches dentro de 2.16.x son seguros (sin schema migrations).
      com.centurylinklabs.watchtower.enable: "true"
    healthcheck:
      # /healthcheck es el endpoint canónico de ABS desde 2.5+. Devuelve
      # 200 OK con cuerpo "OK" sin requerir autenticación. Útil para
      # liveness probes.
      test:
        - CMD-SHELL
        - "wget -qO- --tries=1 --timeout=5 http://localhost:80/healthcheck | grep -q OK || exit 1"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s   # primer arranque: ~20-30 s (Node.js + migraciones BD)
    # Sin 'ports:'. Caddy alcanza ABS por DNS interno.
```

Notas de diseño:

- **`user: "${PUID}:${PGID}"`**: la imagen oficial de ABS corre como `root` por defecto. Bajarla a `1000:1000` cumple la convención del homelab. El `/mnt/hd2t/services/audiobookshelf/` ya es `1000:1000` por `docs/01-sistema/04-estructura-directorios.md` paso 7.
- **`group_add: ["${MEDIA_GID}"]`**: añade el GID del grupo `homelab-media` como _grupo suplementario_ del proceso. Permite a ABS leer `/mnt/hd2t/services/shared/audiobooks/` (que es `root:homelab-media 2775`) por _ownership_ y no sólo por bit `o+r`.
- **`/audiobooks:ro`**: explícito y deliberado. Ver **Decisiones de diseño** → _Volumen de la biblioteca de audiolibros_.
- **`/podcasts` sin `:ro`**: ABS necesita escribir aquí para descargar episodios.
- **Sin `ports:`**. Caddy alcanza ABS por DNS interno (`audiobookshelf:80`). Si el operador necesita acceso directo durante un _troubleshooting_, puede `docker exec -it audiobookshelf wget -qO- http://localhost:80/healthcheck`.
- **`PORT: "80"` y `HOST: "0.0.0.0"`**: explicitan los valores por defecto de la imagen para evitar sorpresas si en una versión futura cambiara el _default_. Caddy reverse_proxy usa este puerto.
- **No `INTERNAL_URL` ni `BASE_URL` en el contenedor**: ABS deduce las URLs absolutas a partir de la cabecera `Host` que reenvía Caddy. La variable `AUDIOBOOKSHELF_BASE_URL` del `.env` se usa **a nivel del homelab** (referencia para documentación, dashboards, OIDC futuro), no se inyecta al contenedor — ABS sabe ser servido detrás de un reverse proxy sin configuración adicional siempre que las cabeceras `X-Forwarded-*` lleguen bien.
- **`start_period: 60s`**: el primer arranque tarda ~20-30 s (Node.js arrancando, migraciones SQLite si toca). Margen holgado.
- **`/healthcheck` como _liveness probe_**: público (sin autenticación), devuelve `OK`. No requiere token, ideal para `wget -qO-`.
- **Watchtower opt-in**: razones explicadas en **Decisiones de diseño** → _Imagen y tag_.
- **No `mem_limit`**: en idle ABS consume ~150 MB. Durante un _full library scan_ con varios miles de audiolibros sube a ~300-500 MB. Sin necesidad de ajuste hasta que Stash y compañía compitan por memoria (`docs/13-operaciones/03-rendimiento-pi5.md`).

---

## Despliegue

### Levantar el servicio

```bash
cd ~/homelab/multimedia
docker compose --env-file ../.env --env-file .env config | grep -A2 audiobookshelf   # validar
docker compose --env-file ../.env --env-file .env up -d audiobookshelf
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=multimedia
```

> `make up` aplica todo el stack; si Jellyfin y Navidrome ya estaban arriba, Compose los deja como estaban y sólo crea/recrea el contenedor `audiobookshelf`.

Vigilar el primer arranque (tarda ~20-30 s):

```bash
docker compose -f ~/homelab/multimedia/docker-compose.yml logs -f audiobookshelf
# ...
# audiobookshelf  | [TIMESTAMP] INFO: === Starting Server ===
# audiobookshelf  | [TIMESTAMP] INFO: Init - server v2.16.x
# audiobookshelf  | [TIMESTAMP] INFO: Database connection established
# audiobookshelf  | [TIMESTAMP] INFO: Listening on 0.0.0.0:80
```

Verificar que el contenedor está `(healthy)`:

```bash
docker compose -f ~/homelab/multimedia/docker-compose.yml ps audiobookshelf
# NAME            STATUS                  PORTS
# audiobookshelf  Up X seconds (healthy)
```

> El `(healthy)` lo otorga el _healthcheck_ que confirma que `/healthcheck` devuelve `OK`. Si tras 1 minuto sigue `starting`, ir a **Troubleshooting** → primer arranque.

### Caddy: bloque `audiobooks.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque (típicamente después del bloque `audiobooks.lan` no existe aún; insertar tras `jellyfin.lan` o `music.lan` para mantener orden alfabético por servicio):

```caddy
audiobooks.lan {
    tls internal
    import security-headers
    import logging

    # Subida de cover art y attachments por el admin: ABS acepta hasta
    # 50 MB por petición por defecto (ficheros de audio que se cargan vía
    # web UI). El reverse_proxy de Caddy v2 no impone límite explícito
    # menor; los 'request_body' globales de Caddy aceptan hasta 100 MB
    # por defecto. No hace falta ajuste.

    # Streaming de audio: keep-alive más holgado para clientes móviles
    # con conexiones inestables.
    reverse_proxy audiobookshelf:80 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        # ABS usa websockets para SyncPlay y notificaciones en tiempo
        # real entre la app y el servidor. Caddy v2 detecta y reenvía
        # WS automáticamente; se hace explícito por documentación.
        transport http {
            keepalive 30s
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
curl -k --resolve audiobooks.lan:443:192.168.1.3 \
     https://audiobooks.lan/healthcheck
# OK

curl -k --resolve audiobooks.lan:443:192.168.1.3 \
     -s -o /dev/null -w '%{http_code}\n' https://audiobooks.lan/
# 200
```

Y desde el navegador: `https://audiobooks.lan/` → la web UI de ABS muestra la pantalla de **creación del primer usuario** (root user). Una vez creado, redirige al login.

---

## Configuración tras primer arranque

### Crear el primer usuario (root)

`https://audiobooks.lan/` muestra **un formulario de creación inicial** (sólo aparece la primera vez, hasta que existe al menos un usuario). Rellenar:

- **Username**: distinto de `admin`/`root` (objetivo trivial de _credential stuffing_).
- **Password**: robusta. Se almacena hasheada con bcrypt en `/config/absdatabase.sqlite`.

Al confirmar, ese usuario queda como `type=root`. Es el único que puede crear más usuarios, modificar la configuración global del servidor y cambiar parámetros de bibliotecas.

### Activar 2FA en la web UI (opcional pero recomendado)

Audiobookshelf soporta TOTP **para la web UI** (no para los clientes que hablan con la API REST). En **Settings → Account → Two-Factor Authentication**:

1. **Enable 2FA**.
2. Escanear el QR con Authy / Aegis / Google Authenticator.
3. Validar con un código de 6 dígitos.
4. **Guardar los códigos de recuperación** en Vaultwarden (cuando exista; mientras tanto en un papel/llavero).

> **Importante**: el 2FA TOTP **sólo aplica al login web**. La app móvil oficial y los clientes de terceros (Plappa, Voice…) seguirán autenticándose con _password_ y obteniendo un JWT sin segundo factor. Es un _trade-off_ deliberado del proyecto: la API REST de ABS no especifica TOTP, romperla rompería la app oficial. Mitigación: contraseñas robustas + acceso sólo por LAN/Tailscale + el JWT emitido es de larga duración pero revocable desde _Settings → Sessions_.

### Configurar la biblioteca de audiolibros

Por defecto ABS arranca sin bibliotecas configuradas. En **Config → Libraries → Add New Library**:

- **Name**: `Audiolibros` (o el nombre preferido).
- **Icon**: _audiobookshelf_ (el icono de libro con auriculares).
- **Type**: **Book** (audiolibros).
- **Language**: `es` (o el idioma principal de la biblioteca).
- **Folders**: añadir `/audiobooks` (mapeado del bind mount, no editable directamente desde la UI más allá de ese path).
- **Settings → Auto Scan Cron**: `0 4 * * *` (re-scan completo nocturno a las 04:00 de fallback; el _watcher_ de filesystem detecta cambios _live_).
- **Settings → Library Scanner Settings**: dejar los defaults excepto:
  - **Save metadata to file**: `OFF` (mantiene el montaje `:ro` válido — ver **Decisiones de diseño**).
  - **Cover art at item folder**: `ON` (descarga `cover.jpg` al árbol de metadatos, no al fichero original).

Guardar. ABS empieza el primer escaneo. Para 5 000 audiolibros tarda 5–15 minutos (Node.js + lectura de tags M4B + descarga de _cover art_ desde Audnexus). Vigilar el progreso:

```bash
docker logs audiobookshelf --tail 50 -f | grep -i 'scan\|library'
```

Cuando termina, el dashboard muestra los audiolibros ordenados por _added at_, con _cover art_ visible.

### Configurar la biblioteca de podcasts (opcional)

En **Config → Libraries → Add New Library**:

- **Name**: `Podcasts`.
- **Icon**: _microphone_.
- **Type**: **Podcast**.
- **Folders**: `/podcasts`.
- **Settings → Auto-Download Episodes**: `ON`.
- **Settings → Auto-Download Schedule**: `0 6 * * *` (descargar nuevos episodios a las 06:00 cada día).
- **Settings → Episode Limit**: `5` (mantener sólo los últimos 5 episodios por podcast — ajustar al gusto).

Para añadir podcasts a esta biblioteca:

1. **Add Podcast** desde el dashboard de la biblioteca.
2. **Search** o **Manual RSS feed URL**.
3. ABS descarga los últimos N episodios y queda suscrito.

> **Tamaño en disco**: vigilar `/mnt/hd2t/services/audiobookshelf/podcasts/` — con retención laxa puede crecer mucho. La política de "últimos 5 episodios" mantiene un cap razonable.

### Crear usuarios adicionales (familia)

En **Config → Users → Add New User**:

- **Username**: nombre (ej. "pareja", "kid1").
- **Password**: distinta del root user. El usuario podrá cambiarla en _Account Settings_.
- **Type**: **User** (no _admin_; los usuarios estándar pueden escuchar y cambiar su propio progreso, pero no editar bibliotecas ni gestionar otros usuarios).
- **Permissions → Libraries**: por defecto todos ven todas las bibliotecas; con _multi-library access control_ se puede segmentar (ej. el usuario "kid1" sólo ve la biblioteca "Audiolibros infantiles" si se creara una aparte).

> **Token API por usuario**: cada usuario tiene un `apiToken` accesible desde _Account Settings → API Token_. Útil para integraciones (Homepage / Homarr) sin compartir la contraseña.

### Endurecer el login (intentos máximos)

ABS no expone configuración de _lockout_ por intentos fallidos en la UI. La mitigación se delega a:

- **Pi-hole + LAN aislada** (`docs/03-red/02-pihole.md`): el atacante tiene que estar en LAN o tailnet.
- **Authelia con _rate limiting_ de IP global** (`docs/04-seguridad/01-authelia.md`, sección _Anti brute-force_): aunque ABS no esté detrás de `forward_auth`, el _rate limiting_ a nivel de Caddy (que sí se documenta en el `Caddyfile` global) amortigua el _credential stuffing_.
- **Fail2ban con jail específico de ABS** (`docs/04-seguridad/02-fail2ban.md`): parsea `docker logs audiobookshelf` buscando `Failed login` y banea por 1 hora a la IP origen tras 5 intentos en 10 minutos. Documentado allí.

> **Por qué no usar `fail2ban` con un jail Audiobookshelf de fábrica**: el jail genérico de ABS está documentado en `docs/04-seguridad/02-fail2ban.md`. Aquí se da por hecho que Fail2ban está montado **antes** o **después** de este servicio; si está, automáticamente vigila los _failed logins_ de ABS por la regex compartida del jail "multimedia-auth-fail".

### Integraciones de scrapers de metadatos (opcional)

ABS trae de fábrica scrapers para:

- **Audnexus** (Audible mirror público): la fuente principal para audiolibros. Sin configuración, funciona _out-of-the-box_.
- **Goodreads**: para descripciones y series.
- **iTunes Podcasts**: para feeds de podcasts.

Activarlos / priorizarlos en **Config → Item Metadata Settings → Metadata Providers**: arrastrar Audnexus al primer puesto para audiolibros.

> **Privacidad**: cada match contra Audnexus envía el ASIN o título del audiolibro al servicio externo. Decisión personal por usuario. El servidor mismo (la BD del catálogo) ya guarda esa información _localmente_ en `absdatabase.sqlite` tras el primer match; la consulta externa sólo se dispara una vez por libro.

### Conectar la app móvil oficial

Desde el dispositivo móvil (en la LAN o tras `tailscale up`):

1. Instalar **Audiobookshelf** desde Play Store (Android) o App Store (iOS).
2. Abrir la app → **Add Server**.
3. **URL**: `https://audiobooks.lan` (sin slash final).
4. **Username + Password**: las del usuario creado.
5. La primera vez, la app pregunta si confía en el certificado de la CA local — aceptar (la CA local debe estar importada en el dispositivo, ver `docs/03-red/04-caddy.md` sección _Importar CA en clientes_).

A partir de ahí, la app sincroniza el catálogo y permite descargar audiolibros para escuchar _offline_.

> **Tailscale Magic DNS**: si el dispositivo tiene Tailscale activo, `audiobooks.lan` resuelve a `192.168.1.3` también desde fuera de la LAN gracias al _Split DNS_ delegado a Pi-hole (`docs/03-red/05-tailscale.md`).

---

## Bibliotecas y tags

### Estructura recomendada de la biblioteca de audiolibros

Dentro de `/mnt/hd2t/services/shared/audiobooks/`, organizar (convención _Audiobookshelf-recommended_):

```
/mnt/hd2t/services/shared/audiobooks/
├── Author Name/
│   ├── Series Name/
│   │   ├── Volume 1 - Book Title/
│   │   │   ├── Book Title.m4b
│   │   │   └── cover.jpg
│   │   └── Volume 2 - Other Book/
│   │       └── ...
│   └── Standalone Book Title/
│       ├── 01 - Chapter 1.mp3
│       ├── 02 - Chapter 2.mp3
│       ├── ...
│       └── cover.jpg
└── Compilations/
    └── Anthology Title/
        └── ...
```

ABS soporta tres formatos:

- **`.m4b` con _embedded chapters_**: ideal. Un solo fichero por libro, capítulos navegables, _cover art_ embebido.
- **`.mp3` sueltos numerados**: ABS los une en una pista lógica usando los nombres de fichero como capítulos. Requiere numeración consistente (`01 - …`, `02 - …`).
- **`.flac`/`.ogg`/`.m4a`/`.opus`**: aceptados, mismo modelo. ABS prefiere M4B por compatibilidad universal pero no convierte por sí solo.

> **Cover art**: ABS busca primero _embedded cover_ en las _tags_ ID3/M4B, luego un `cover.jpg`/`cover.png`/`folder.jpg` en el directorio del libro, luego Audnexus por ASIN/título-autor. En orden. La primera coincidencia gana. ABS guarda el _cover art_ derivado en `/metadata/items/<id>/cover.jpg` (no toca el original).

### Forzar un re-scan

Útil tras añadir ficheros manualmente por SMB o tras reagrupar tags con _mp3tag_:

- **UI**: _Library → Settings → Force Re-scan_ (botón en la cabecera de la biblioteca).
- **API** (con un token de un usuario):

  ```bash
  curl -k --resolve audiobooks.lan:443:192.168.1.3 \
    -H "Authorization: Bearer <user_api_token>" \
    -X POST \
    "https://audiobooks.lan/api/libraries/<library_id>/scan"
  ```

  El `<library_id>` se obtiene en la UI (URL al entrar en una biblioteca) o vía API: `curl -H "Authorization: Bearer <token>" https://audiobooks.lan/api/libraries`.

> **Watcher de filesystem automático**: ABS observa `/audiobooks` con `chokidar` (Node.js wrapper sobre `inotify` en Linux). Detecta nuevos ficheros y borrados en cuanto ocurren. El re-scan manual es para cuando el _watcher_ se pierde un evento (raro pero ocurre con `fs.inotify.max_user_watches` bajo o cuando el _drop_ por SMB es muy masivo y satura la cola del kernel).

---

## Almacenamiento

Tras el primer arranque, el árbol `/mnt/hd2t/services/audiobookshelf/` queda con los siguientes ficheros relevantes:

```
/mnt/hd2t/services/audiobookshelf/
├── config/
│   ├── absdatabase.sqlite                # BD SQLite (catálogo + progreso + usuarios)
│   ├── absdatabase.sqlite-wal             # WAL de SQLite (presente mientras escribe)
│   ├── absdatabase.sqlite-shm             # shared memory de SQLite
│   └── server.json                        # JWT secret + token signing key
├── metadata/
│   ├── items/<library_item_id>/           # cover art, descripciones, chapter art descargados
│   ├── authors/<author_id>/               # cover art de autor descargado
│   ├── cache/                             # cache de streaming/transcoding (regenerable)
│   ├── logs/                              # logs por día (rotación interna)
│   ├── backups/                           # backups internos de ABS (deshabilitados aquí)
│   └── streams/                           # transcoding sessions activas (efímero)
└── podcasts/
    └── <Podcast Title>/
        ├── episodes-*.mp3
        └── ...
```

| Ruta                                                      | Permisos        | Contenido                                                          |
|-----------------------------------------------------------|-----------------|---------------------------------------------------------------------|
| `/mnt/hd2t/services/audiobookshelf/`                      | `1000:1000 0755` | Raíz del bind mount                                                  |
| `/mnt/hd2t/services/audiobookshelf/config/`               | `1000:1000 0755` | Configuración persistente                                            |
| `/mnt/hd2t/services/audiobookshelf/config/absdatabase.sqlite` | `1000:1000 0644` | BD SQLite del catálogo                                            |
| `/mnt/hd2t/services/audiobookshelf/config/server.json`    | `1000:1000 0600` | JWT secret (sensible — modo restringido)                             |
| `/mnt/hd2t/services/audiobookshelf/metadata/`             | `1000:1000 0755` | Metadatos derivados (covers, descripciones)                          |
| `/mnt/hd2t/services/audiobookshelf/metadata/cache/`       | `1000:1000 0755` | Caches regenerables (excluido de Borg)                               |
| `/mnt/hd2t/services/audiobookshelf/podcasts/`             | `1000:1000 0755` | Podcasts descargados (excluido de Borg)                              |
| `/mnt/hd2t/services/shared/audiobooks/` (sólo lectura)    | `root:homelab-media 2775` | Biblioteca de audiolibros, montada `:ro` en el contenedor   |

> **`server.json` con `0600`**: contiene el _JWT secret_ que firma los _tokens_ de sesión. Si se filtra, un atacante con la BD podría forjar tokens válidos. ABS lo crea con `0600` por defecto al arrancar como `1000:1000`; verificar con `stat -c '%a' /mnt/hd2t/services/audiobookshelf/config/server.json` tras el primer arranque.

---

## Backup

Patrón S (online, vía `sqlite3 .backup`) sobre la BD del catálogo, más Patrón F (filesystem-only) sobre el resto de `/config` y `/metadata`. Resultado: respaldo coherente sin parar Audiobookshelf. Los podcasts (regenerables) se excluyen explícitamente.

### 1. Descomentar el bloque de Audiobookshelf en `dump-databases.sh`

Editar `~/homelab/backups/borgmatic/hooks/dump-databases.sh` y descomentar la línea que `docs/07-backups/03-backup-docker-volumes.md` dejó preparada:

```diff
 # --- Audiobookshelf (SQLite) — docs/09-multimedia/03-audiobookshelf.md
-# dump_sqlite audiobookshelf audiobookshelf /config/absdatabase.sqlite
+dump_sqlite audiobookshelf audiobookshelf /config/absdatabase.sqlite
```

> **¿La imagen oficial de ABS trae `sqlite3`?**: sí; la imagen base (`node:18-alpine` derivada) tiene instalado el cliente CLI de SQLite porque el propio `node-sqlite3` lo usa internamente para algunos paths de _migration_. `docker exec audiobookshelf which sqlite3` devuelve `/usr/bin/sqlite3` (o `/usr/local/bin/sqlite3` según _build_). Si en algún _bump_ futuro se eliminase, el _hook_ falla con un error claro y se conmuta a `dump_sqlite_cold` (5 s de _downtime_, aceptable de madrugada).

Re-instalar:

```bash
~/homelab/backups/borgmatic/install.sh
sudo /usr/bin/borgmatic --dry-run --verbosity 2 | grep -A2 audiobookshelf
# debe listar el dump previsto
```

Smoke-test del hook ejecutándolo a mano:

```bash
sudo /etc/borgmatic.d/hooks/dump-databases.sh
ls -la /mnt/hd2t/backups/dumps/audiobookshelf-*.sqlite.gz
# audiobookshelf-2026-04-26.sqlite.gz   65M
```

Confirmar que el dump abre como SQLite válido:

```bash
sudo zcat /mnt/hd2t/backups/dumps/audiobookshelf-*.sqlite.gz | file -
# /dev/stdin: SQLite 3.x database, ...
```

### 2. Excluir podcasts y caches de Borgmatic

Editar `~/homelab/backups/borgmatic/config.yaml` y añadir al bloque `exclude_patterns` (debajo del patrón global `*/cache/*` ya existente):

```yaml
exclude_patterns:
  # ...patterns existentes...
  - '*/cache/*'
  # Podcasts: regenerables desde sus feeds RSS — Categoría C.
  - '*/audiobookshelf/podcasts/*'
  # Backups internos de ABS: redundantes con el propio Borg.
  - '*/audiobookshelf/metadata/backups/*'
  # Streams transcoding efímeros.
  - '*/audiobookshelf/metadata/streams/*'
```

Validar:

```bash
sudo borgmatic config validate
```

### 3. Confirmar que Audiobookshelf está cubierto por `source_directories`

`source_directories: /mnt/hd2t/services` ya incluye `audiobookshelf/` por inercia (ver `docs/07-backups/02-borgmatic.md`, sección _Por qué incluir el directorio padre y filtrar_). Junto con los `exclude_patterns` añadidos arriba, el efecto neto es:

- ✅ `/mnt/hd2t/services/audiobookshelf/config/` — backup completo.
- ✅ `/mnt/hd2t/services/audiobookshelf/metadata/items/` — backup (covers descargados; tamaño moderado).
- ❌ `/mnt/hd2t/services/audiobookshelf/metadata/cache/` — excluido.
- ❌ `/mnt/hd2t/services/audiobookshelf/metadata/streams/` — excluido.
- ❌ `/mnt/hd2t/services/audiobookshelf/metadata/backups/` — excluido.
- ❌ `/mnt/hd2t/services/audiobookshelf/podcasts/` — excluido.

Tras el siguiente _run_ programado (madrugada), Audiobookshelf aparece en la lista de archives:

```bash
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL::pi-$(date +%F)T03:30:30" \
    | grep audiobookshelf | head -10
'
# -rw-r--r-- 1000   1000  65M Apr 26 03:30 mnt/hd2t/services/audiobookshelf/config/absdatabase.sqlite
# -rw-r----- root   root  65M Apr 26 03:30 mnt/hd2t/backups/dumps/audiobookshelf-2026-04-26.sqlite.gz
# ...
```

### Restauración

Procedimiento idéntico al **Patrón de restauración común** documentado en `docs/07-backups/03-backup-docker-volumes.md`. En resumen:

1. `docker compose -f ~/homelab/multimedia/docker-compose.yml stop audiobookshelf`.
2. Mover `/mnt/hd2t/services/audiobookshelf/{config,metadata}/` a `<dir>.broken-<ts>` (preservar 24-48 h por si la restauración tampoco arranca).
3. `borg extract` del archive elegido a `/tmp/restore-$$/`, mover en sitio.
4. Restaurar la SQLite desde el dump del Patrón S si la del archive estuviera dañada (raro):

   ```bash
   sudo gunzip -c /mnt/hd2t/backups/dumps/audiobookshelf-YYYY-MM-DD.sqlite.gz \
     > /mnt/hd2t/services/audiobookshelf/config/absdatabase.sqlite
   sudo chown 1000:1000 /mnt/hd2t/services/audiobookshelf/config/absdatabase.sqlite
   ```

5. `docker compose -f ~/homelab/multimedia/docker-compose.yml up -d audiobookshelf`.
6. Esperar al `(healthy)` (típicamente <60 s).
7. Comprobar UI: usuarios, _bookmarks_, progreso por libro y suscripciones a podcasts deben recuperarse. La biblioteca de `/audiobooks` se reescanea automáticamente y reconstruye el índice contra los ficheros físicos.

> **La biblioteca de audiolibros en `/mnt/hd2t/services/shared/audiobooks/` no se respalda** (Categoría C). Si se pierde el disco hd2t, hay que volver a llenar la biblioteca desde la fuente original. La BD restaurada conoce los nombres y metadatos, pero los `.m4b`/`.mp3` físicos no están — al primer scan, ABS los marcará como `missing` hasta que reaparezcan.

> **Los podcasts no se respaldan tampoco** (excluidos explícitamente). Tras restaurar, ABS conoce las suscripciones (vienen en la BD), pero los episodios concretos hay que dejar que se redescarguen al siguiente cron de "auto-download". Si un episodio estaba sólo en hd2t y desapareció del feed, ese episodio se pierde.

---

## Verificación

Antes de dar por cerrado este documento:

- [ ] `~/homelab/multimedia/docker-compose.yml` extendido con el servicio `audiobookshelf` y versionado en git; `~/homelab/multimedia/.env.example` extendido con `AUDIOBOOKSHELF_*`; `~/homelab/multimedia/.env` con valores reales (no versionado).
- [ ] `docker compose -f ~/homelab/multimedia/docker-compose.yml ps` muestra `audiobookshelf` como `(healthy)`.
- [ ] `docker exec audiobookshelf wget -qO- http://localhost:80/healthcheck` devuelve `OK`.
- [ ] `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` acepta el bloque `audiobooks.lan` añadido.
- [ ] `curl -k --resolve audiobooks.lan:443:192.168.1.3 https://audiobooks.lan/healthcheck` devuelve `OK` sin redirect (sin Authelia delante).
- [ ] Login interactivo desde el navegador con la cuenta root user funciona; la web UI muestra _Libraries_, _Latest_ y _Authors_ tras el primer scan.
- [ ] App móvil oficial (Android o iOS) configurada con servidor `https://audiobooks.lan/`, usuario y contraseña: lista la biblioteca, descarga un audiolibro _offline_, reproduce un capítulo, el progreso se sincroniza a la web UI tras volver a la app online.
- [ ] El log de ABS (`docker logs audiobookshelf 2>&1 | grep -i 'remote\|forwarded\|client'`) muestra que `X-Forwarded-For` se procesa: una petición desde el navegador del PC LAN aparece logueada con la IP del PC, no con `172.20.10.x`.
- [ ] Dump SQLite generado por `dump-databases.sh`: `sudo ls -la /mnt/hd2t/backups/dumps/audiobookshelf-$(date +%F).sqlite.gz` existe y `file -` lo identifica como `gzip compressed data` con SQLite dentro.
- [ ] El `Caddyfile` para `audiobooks.lan` lleva `import security-headers`, `import logging`; **no** lleva `import authelia`.
- [ ] La lista `two_factor` del `access_control.rules` de Authelia **no** menciona `audiobooks.lan` (ni siquiera comentado).
- [ ] Watchtower vigila el contenedor: `docker logs watchtower --tail 50 | grep audiobookshelf` muestra al menos un check (label `enable: "true"` activo).
- [ ] `stat -c '%U:%G' /mnt/hd2t/services/audiobookshelf /mnt/hd2t/services/audiobookshelf/config /mnt/hd2t/services/audiobookshelf/metadata /mnt/hd2t/services/audiobookshelf/podcasts` devuelve `1000:1000` en los cuatro.
- [ ] `docker exec audiobookshelf id` muestra `uid=1000 gid=1000 groups=1000,${MEDIA_GID}` (o el GID real de `homelab-media`).
- [ ] `stat -c '%a' /mnt/hd2t/services/audiobookshelf/config/server.json` devuelve `600` (JWT secret restringido).
- [ ] Borgmatic `exclude_patterns` incluye `*/audiobookshelf/podcasts/*`, `*/audiobookshelf/metadata/cache/*`, `*/audiobookshelf/metadata/streams/*`, `*/audiobookshelf/metadata/backups/*`. Validado con `sudo borgmatic config validate`.
- [ ] La biblioteca aparece poblada: en _Library Stats_ el conteo de _Items_ refleja lo que hay en `/mnt/hd2t/services/shared/audiobooks/`.
- [ ] (Si hay biblioteca de podcasts) Suscribirse a un podcast de prueba; un episodio se descarga a `/mnt/hd2t/services/audiobookshelf/podcasts/<Title>/`.

---

## Troubleshooting

### Primer arranque: el contenedor se queda en `starting` indefinidamente

```bash
docker logs audiobookshelf --tail 50
```

Causas comunes:

- **Permisos del bind mount**: si por error se hizo un `chown -R root:root /mnt/hd2t/services/audiobookshelf`, el proceso (que corre como `1000:1000`) falla con `EACCES` al intentar crear `config/absdatabase.sqlite`. Restaurar:

  ```bash
  sudo chown -R 1000:1000 /mnt/hd2t/services/audiobookshelf
  docker compose -f ~/homelab/multimedia/docker-compose.yml restart audiobookshelf
  ```

- **`/etc/localtime` ausente**: en algunos hosts minimalistas no existe; ABS se queja con `cannot determine local time zone` y los timestamps de _logs_ y _scrobbles_ caen a UTC. Crear el symlink (mismo procedimiento que en Jellyfin/Navidrome):

  ```bash
  sudo ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
  ```

- **Imagen mal descargada**: tras un fallo de red durante el `pull`, la imagen puede quedar parcial. `docker rmi ghcr.io/advplyr/audiobookshelf:2.16 && docker compose -f ~/homelab/multimedia/docker-compose.yml pull audiobookshelf`.

- **`PORT: "80"` y user no-root**: ejecutarse como `1000:1000` no permite escuchar en puertos privilegiados (<1024) por defecto en Linux. La imagen oficial de ABS, tal como está construida, **sí puede** escuchar en `:80` aunque el proceso sea no-root, gracias a `setcap cap_net_bind_service=+ep` aplicado al binario de Node.js. Si en una versión futura se eliminase ese `setcap`, el contenedor fallaría con `EACCES` al hacer `bind`. Mitigación: cambiar `PORT: "13378"` (puerto no privilegiado, default histórico de ABS) en el `.env` global del stack (variable nueva opcional `AUDIOBOOKSHELF_PORT`) y actualizar el `Caddyfile`:

  ```caddy
  reverse_proxy audiobookshelf:13378 { ... }
  ```

  Hoy (2.16.x) **no es necesario**.

### "Cannot scan audiobooks folder: permission denied"

Síntoma: log de ABS muestra `EACCES: permission denied, scandir '/audiobooks/<...>'`. Causa: el contenedor no es miembro del grupo `homelab-media` y los ficheros están con `2750` (sin `o+r`). Comprobar:

```bash
docker exec audiobookshelf id
# uid=1000 gid=1000 groups=1000   # FALTA el GID de homelab-media
```

Si falta, revisar que `MEDIA_GID` está en `~/homelab/.env` y que el bloque `group_add` está presente en el compose. Re-aplicar:

```bash
cd ~/homelab && make up STACK=multimedia
docker exec audiobookshelf id
# uid=1000 gid=1000 groups=1000,989   # 989 = ejemplo de homelab-media
```

### "X-Forwarded-For ignorado" / IPs reales no aparecen en el log

ABS confía por defecto en cualquier proxy que le envíe `X-Forwarded-For` (el proyecto deja la decisión al operador del reverse proxy). El log debería mostrar la IP del cliente real, no la del contenedor de Caddy.

Si en cambio aparece `172.20.10.x` (Caddy) en el log, el problema está en Caddy:

```bash
docker exec caddy cat /etc/caddy/Caddyfile | grep -A10 audiobooks.lan
```

Confirmar que el bloque tiene `header_up X-Forwarded-For {remote_host}` y `header_up X-Real-IP {remote_host}`. Recargar Caddy si se ha modificado:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

### La app móvil dice "Server not responding" pero la web UI funciona

Causa típica: la app no acepta el certificado de la CA local. Verificar:

1. **CA local importada en el dispositivo**: ver `docs/03-red/04-caddy.md`, sección _Importar CA en clientes Android/iOS_.
2. **DNS**: el dispositivo debe resolver `audiobooks.lan → 192.168.1.3`. Si no está conectado a la WiFi del homelab y no tiene Tailscale, no resolverá. Tras `tailscale up` y MagicDNS, la resolución llega vía Pi-hole (`docs/03-red/05-tailscale.md`).
3. **WebSocket**: ABS usa WS para el _live progress sync_. Si Caddy no reenvía WS correctamente (raro con la config canónica), la app conecta pero no sincroniza. Verificar:

   ```bash
   curl -k --resolve audiobooks.lan:443:192.168.1.3 \
     -H "Connection: Upgrade" -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" \
     -H "Sec-WebSocket-Key: dGVzdAo=" \
     https://audiobooks.lan/socket.io/ -i
   # Esperado: HTTP/1.1 101 Switching Protocols (o un 400 si faltan params,
   #           pero NO un 200 plano que indicaría que Caddy no upgradeó).
   ```

### "Audiolibro no aparece en la biblioteca tras un drop por SMB"

Causa: el _watcher_ se perdió el evento (típico con muchos miles de ficheros copiados a la vez por Samba). Solución: forzar un re-scan:

```bash
# UI: Library -> Settings -> Force Re-scan
# o vía API:
docker exec audiobookshelf wget -qO- \
  --header="Authorization: Bearer <user_api_token>" \
  --post-data="" \
  "http://localhost:80/api/libraries/<library_id>/scan"
```

Si pasa frecuentemente, subir `fs.inotify.max_user_watches` y `max_queued_events` en el host (ya recomendado en `docs/09-multimedia/02-navidrome.md`):

```bash
sudo tee /etc/sysctl.d/99-inotify.conf <<'EOF'
fs.inotify.max_user_watches=524288
fs.inotify.max_queued_events=32768
EOF
sudo sysctl --system
docker compose -f ~/homelab/multimedia/docker-compose.yml restart audiobookshelf
```

### "No se descarga el episodio nuevo del podcast"

Causas:

- **Cron no ha corrido**: la auto-descarga se dispara según el _Auto-Download Schedule_ configurado por biblioteca. Forzar manualmente: en la página del podcast, **Check for New Episodes**.
- **Feed RSS roto**: si el feed cambió de URL (típico tras una migración del podcaster), ABS lo marca con un icono de alerta en la página del podcast. Editar la URL del feed.
- **Permisos de `/podcasts`**: si por algún `chown` accidental el directorio no es writable por `1000:1000`, la descarga falla con `EACCES`. Verificar:

  ```bash
  ls -la /mnt/hd2t/services/audiobookshelf/podcasts
  # drwxr-xr-x 1000 1000 ...
  ```

### La BD `absdatabase.sqlite` crece a tamaños desorbitados (>1 GB)

Causas:

- **Histórico de _listening sessions_**: cada inicio de reproducción crea una _session_ en `mediaProgress` y `playbackSessions`. Por defecto ABS no limita el histórico — con uso intensivo crece linealmente. Limpiar (con cuidado, perderás histórico):

  ```bash
  docker exec -u 1000:1000 audiobookshelf sqlite3 /config/absdatabase.sqlite \
    "DELETE FROM playbackSessions WHERE updatedAt < datetime('now','-180 days'); VACUUM;"
  ```

- **Backups internos activos** sin retención: si por error se activaron los backups internos de ABS y se quedaron 50 backups acumulados, mover los backups fuera y limpiar:

  ```bash
  ls -la /mnt/hd2t/services/audiobookshelf/metadata/backups/
  # si hay >2-3, desactivar en Settings -> Backups y borrar los huérfanos.
  ```

- **Cover art guardado dentro de la BD** (raro): comprobar el tamaño de la tabla `images`. ABS por defecto guarda los _covers_ en disco (`/metadata/items/<id>/cover.jpg`), no en la BD.

### "Transcoding falla con FFmpeg: ..."

Causa: un fichero con _tags_ corruptas o un códec exótico (Monkey's Audio APE, WMA Lossless) que el FFmpeg embebido no decodifica. Mitigación:

- Comprobar el fichero a mano:

  ```bash
  docker exec audiobookshelf ffmpeg -i /audiobooks/<ruta>/<fichero>.ape 2>&1 | head -20
  ```

- Convertir el fichero a M4B en otra máquina con un FFmpeg más completo y copiarlo en sitio.
- Si el cliente puede _direct play_ (la app oficial reproduce M4B/MP3/Opus de forma nativa), forzar _native format_ desde la app y saltarse el transcoding.

---

## Actualización

### Patches de la línea `2.16.x` (vía Watchtower, automático)

Watchtower opt-in está activo. Cada domingo a las 04:00 UTC, Watchtower comprueba el _digest_ del _tag_ `2.16`; si hay uno nuevo, hace `pull` + `recreate` del contenedor Audiobookshelf. Sin acción del operador.

Verificar tras un domingo:

```bash
docker logs watchtower --tail 50 | grep audiobookshelf
# time=... msg="Found new ghcr.io/advplyr/audiobookshelf:2.16 image"
# time=... msg="Stopping /audiobookshelf"
# time=... msg="Creating /audiobookshelf"
```

Si tras la recreación el `(healthy)` no llega en 1-2 minutos, ir a **Troubleshooting**.

### Bumps de minor (`2.16 → 2.17`, manual)

```bash
# 1. Leer las release notes
xdg-open https://github.com/advplyr/audiobookshelf/releases/tag/v2.17.0
# Buscar "Breaking changes", "Database migrations" y "Library scanner" — si
# toca alguna integración activa o hay migración irreversible, planificar el
# cambio antes del bump.

# 2. Backup completo previo
sudo /usr/bin/borgmatic --verbosity 1
# Verificar que el último archive tiene fecha de hoy:
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list --short "$BORG_REPO_LOCAL" | tail -1
'

# 3. Cambiar el tag y aplicar
$EDITOR ~/homelab/multimedia/.env
# AUDIOBOOKSHELF_IMAGE_TAG=2.17
cd ~/homelab
make pull STACK=multimedia
make up   STACK=multimedia

# 4. Vigilar el log durante la migración del schema
docker compose -f ~/homelab/multimedia/docker-compose.yml logs -f audiobookshelf
# Buscar:
#   INFO: Database needs migration ...
#   INFO: Migration completed
# Si el log muestra ERROR o el contenedor entra en restart loop, ir a Troubleshooting.

# 5. Validar la web UI, la app móvil, el progreso de escucha y los podcasts
```

> **Migraciones irreversibles**: una vez Audiobookshelf 2.17 arranca y migra el schema, **no hay vuelta atrás** sin restaurar desde backup. Por eso el paso 2 (backup completo previo) es obligatorio.

---

## Referencias

- Documentación oficial — Audiobookshelf: <https://www.audiobookshelf.org/docs>
- Documentación oficial — Docker installation: <https://www.audiobookshelf.org/docs#docker>
- API REST documentada: <https://api.audiobookshelf.org/>
- Reverse proxy (Caddy / Nginx): <https://www.audiobookshelf.org/guides/reverse-proxy>
- Releases del proyecto: <https://github.com/advplyr/audiobookshelf/releases>
- Imagen Docker oficial: <https://github.com/advplyr/audiobookshelf/pkgs/container/audiobookshelf>
- App Android (Play Store): <https://play.google.com/store/apps/details?id=com.audiobookshelf.app>
- App iOS (App Store): <https://apps.apple.com/app/audiobookshelf/id1610421701>
- Audnexus (scraper de metadatos): <https://audnex.us/>
- Documentos relacionados del homelab:
  - `docs/02-docker/02-estructura-compose.md` — convenciones de stacks, red `homelab`, regla `:ro` en biblioteca multimedia.
  - `docs/03-red/04-caddy.md` — Caddy, CA local, _snippets_ `security-headers` y `logging`.
  - `docs/03-red/02-pihole.md` — DNS local `*.lan`.
  - `docs/04-seguridad/01-authelia.md` — por qué Audiobookshelf **no** entra en `forward_auth`.
  - `docs/04-seguridad/02-fail2ban.md` — jail "multimedia-auth-fail" compartido (vigila `Failed login` de ABS).
  - `docs/06-almacenamiento/02-samba.md` — _share_ `audiobooks` que escribe en la misma carpeta que ABS lee.
  - `docs/07-backups/01-estrategia-backup.md` — biblioteca de audiolibros y podcasts como Categoría C (no entran en Borg).
  - `docs/07-backups/02-borgmatic.md` — `source_directories`, `exclude_patterns` global.
  - `docs/07-backups/03-backup-docker-volumes.md` — Patrón S, _hook_ `dump_sqlite audiobookshelf`.
  - `docs/09-multimedia/01-jellyfin.md` — primer servicio del stack `multimedia`, convenciones compartidas.
  - `docs/09-multimedia/02-navidrome.md` — segundo servicio del stack `multimedia`, gemelo arquitectónico de éste.
  - `docs/09-multimedia/04-calibre-web.md` (siguiente fase) — siguiente servicio del stack.
