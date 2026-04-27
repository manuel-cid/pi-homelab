# Calibre-Web (servidor de ebooks)

## Descripción

Despliegue de **Calibre-Web** como servidor de ebooks del homelab: gestiona una biblioteca Calibre (`metadata.db` + ficheros `.epub`/`.mobi`/`.azw3`/`.pdf`/`.cbz`…) almacenada en el árbol compartido `/mnt/hd2t/services/shared/ebooks/`, expone una **web UI** (`https://books.lan`), un **catálogo OPDS** (`/opds`) consumible por lectores de ebook (KOReader, Moon+ Reader, Marvin, FBReader, Aldiko, Foliate, Thorium…), una **API REST** mínima y, opcionalmente, **sincronización Kobo** (los e-readers de Rakuten Kobo registran el servidor como su _store_ y descargan/marcan progreso _over the air_). Toda la configuración persistente, la BD interna SQLite de Calibre-Web (`/config/app.db`) y el catálogo de Calibre (`metadata.db`) viven en el disco externo **hd2t**: el `/config` en `/mnt/hd2t/services/calibre-web/`, y el `metadata.db` dentro de la propia biblioteca compartida (`/mnt/hd2t/services/shared/ebooks/metadata.db`).

Este documento **se suma al _stack_ `multimedia`** (`~/homelab/multimedia/`) que estrenó `docs/09-multimedia/01-jellyfin.md` y al que `docs/09-multimedia/02-navidrome.md` y `docs/09-multimedia/03-audiobookshelf.md` añadieron Navidrome y Audiobookshelf respectivamente. No se crea un compose nuevo: se añade un servicio `calibre-web` al `~/homelab/multimedia/docker-compose.yml` ya existente y se completan las variables del `.env` correspondiente. Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone Calibre-Web en `https://books.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), el mismo nombre `books.lan` resuelve a `192.168.1.3` desde dentro del _tailnet_ gracias al _Split DNS_ delegado a Pi-hole.

> **Alcance**: este documento despliega Calibre-Web con su autenticación nativa (usuario `admin` por defecto, **a cambiar en el primer login**), apunta su biblioteca a `/books` (mapeo de `/mnt/hd2t/services/shared/ebooks/`, **read-write** porque Calibre-Web sube e importa ebooks desde la propia web UI), activa el **catálogo OPDS** y deja documentada (pero no configurada) la **sincronización Kobo** y los _converters_ pesados (Calibre completo + KEPubify) — a activar a posteriori desde la web UI cuando el operador los necesite. Entrega un _hook_ Borgmatic listo para hacer dump _online_ tanto de la SQLite del catálogo de Calibre (`metadata.db`) como de la BD interna de Calibre-Web (`app.db`). **No** delega autenticación a Authelia vía `forward_auth` (rompería el OPDS catalog y la sincronización Kobo, ver **Decisiones de diseño**). **No** instala el _Calibre Server_ completo (calibre-server, GUI VNC) ni `crocodilestick/calibre-web-automated`: ese _fork_ es interesante pero introduce reglas de auto-importación opacas que se prefieren resolver con un flujo Paperless-style explícito en una iteración futura. **No** habilita _Send-to-Kindle_ por SMTP (requiere cuenta saliente y tokenizar el dominio; queda como _opt-in_ documentado).

> **Recordatorio de red**: Calibre-Web **no se publica al host**. Caddy lo alcanza por DNS interno de Docker (`calibre-web:8083` en la red `homelab`). Pi-hole resuelve `books.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`). El operador entra siempre por `https://books.lan/` (LAN) o por el mismo nombre desde el _tailnet_.

---

## Requisitos previos

- `docs/09-multimedia/01-jellyfin.md`, `docs/09-multimedia/02-navidrome.md` y `docs/09-multimedia/03-audiobookshelf.md` completados: el _stack_ `multimedia` (`~/homelab/multimedia/`) ya existe con `docker-compose.yml`, `.env`, `.env.example` y `.gitignore`. La red `homelab` está creada como externa, las variables globales `TZ`, `PUID`, `PGID`, `MEDIA_GID` están rellenas en `~/homelab/.env`, y el _Makefile_ de operación expone `make up STACK=multimedia`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/calibre-web/` ya existe y está reasignado a ownership `1000:1000` (paso 7 de aquel doc, "Reasignar ownership de los servicios LinuxServer.io"). El árbol `/mnt/hd2t/services/shared/ebooks/` existe con `1000:homelab-media 2775` (`setgid` activo, lectura compartida).
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada y por defecto desactivada. Calibre-Web será **opt-in** explícito (ver **Decisiones de diseño**).
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `books.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile` y la CA local firma `*.lan`.
- `docs/04-seguridad/01-authelia.md` completado **opcionalmente**: si Authelia ya está montada, en este documento se decide explícitamente **no** poner Calibre-Web detrás de `forward_auth`. La lista `two_factor` del `access_control.rules` de Authelia **no incluye** `books.lan` (ni siquiera comentado).
- `docs/06-almacenamiento/02-samba.md` completado o pendiente: la _share_ `ebooks` de Samba escribe en `/mnt/hd2t/services/shared/ebooks/` con `force user = homelab` y `force group = homelab-media`. Calibre-Web también escribe ahí desde la web UI; ambos comparten ownership `1000:homelab-media` con `setgid` activo, así que conviven sin conflictos. Si Samba aún no está montado, la biblioteca se rellena por la propia web UI (subida de ficheros) o por SFTP / `rsync` directo.
- `docs/07-backups/02-borgmatic.md` y `docs/07-backups/03-backup-docker-volumes.md` completados (recomendado): el `source_directories: /mnt/hd2t/services` ya engloba `calibre-web/`; el bloque del _hook_ `dump-databases.sh` para Calibre-Web ya está preparado y comentado. Este doc termina **descomentando** ese bloque.
- Conectividad saliente para descargar la imagen (sólo la primera vez):

  ```bash
  docker pull --platform linux/arm64 lscr.io/linuxserver/calibre-web:0.6 >/dev/null && echo OK
  ```

- Que el host **no** tenga ya un servicio escuchando en `:8083` localmente (sólo aplica si en algún _troubleshoot_ se publicara el puerto):

  ```bash
  sudo ss -tulpn '( sport = :8083 )'
  ```

  Salida esperada: vacía. Calibre-Web no publica `:8083` al host (Caddy lo alcanza por DNS interno).

- Espacio en `/mnt/hd2t`: como mínimo **500 MB libres** para `/config` (la BD interna ocupa MB, no más). El crecimiento real lo dicta la biblioteca de ebooks bajo `/mnt/hd2t/services/shared/ebooks/`, no Calibre-Web. Una biblioteca Calibre típica de varios miles de ebooks ronda los **5–20 GB** (los ebooks son pequeños; el _peso_ viene del _cover art_ a alta resolución y de los PDFs de texto escaneado). Si el operador activa _Calibre converters_ pesados (KEPubify, conversión a otros formatos almacenados en `/converters_temp`), reservar otros ~500 MB para esa caché.

  ```bash
  df -h /mnt/hd2t
  ```

---

## Decisiones de diseño

### Por qué Calibre-Web (y no Calibre desktop / Kavita / Komga)

El homelab necesita un servidor de ebooks **headless** y **multi-cliente**: el operador y la familia leen desde lectores de ebook (Kindle, Kobo, BOOX), apps móviles (KOReader, Moon+, Marvin) y eventualmente desde el navegador. Cuatro alternativas y por qué se descartan:

| Candidato                | Por qué se descarta                                                                                                                                                                                                                                                                                  |
|--------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Calibre desktop + calibre-server** | Calibre completo es una aplicación de escritorio Qt; aunque incluye `calibre-server` _headless_, su _content server_ es secundario al producto, la web UI es funcional pero ruda y la sincronización Kobo es limitada. Además, ejecutar Qt en un contenedor exige X11/VNC y un overhead que no aporta nada al uso "biblioteca compartida". |
| **Kavita**               | Excelente para **comics/manga**, soporte ebooks aceptable; pero su modelo de organización (series, volúmenes, capítulos) está pensado para tomos de manga y no se ajusta naturalmente al modelo "autor → serie → libro" de Calibre. Si en el futuro la biblioteca se centra en cómics, Kavita merecería un doc propio; mientras la prioridad sean ebooks de texto con metadatos enriquecidos (`metadata.db` rellenada por Calibre desktop), la elección natural es Calibre-Web.                                                                                                                                                                              |
| **Komga**                | Mismo razonamiento que Kavita: enfocado a comics/manga. Sin soporte nativo del esquema `metadata.db` de Calibre.                                                                                                                                                                                  |
| **`crocodilestick/calibre-web-automated`** | _Fork_ activo que añade auto-importación desde una carpeta _watch_, KEPubify automático, opciones de cron... interesante pero introduce un flujo opaco y diverge del _upstream_ oficial. Se prefiere quedarse en el `linuxserver/calibre-web` canónico y, si en el futuro hace falta auto-importación, montar un _watcher_ explícito (cron + script) o una _action_ de Paperless-style. Documentado como opción pero no adoptado en este doc. |

Calibre-Web gana por:

- **100 % gratis y libre** (GPL-3.0): web UI moderna (Bootstrap), administración por usuarios con _shelves_ privadas y públicas, control granular de permisos por usuario.
- **Modelo nativo de Calibre**: lee y escribe `metadata.db` exactamente como Calibre desktop. Quien quiera mantenerse en el ecosistema Calibre _puro_ (etiquetas, _custom columns_, sagas, _tags_ jerárquicos, ratings, formatos múltiples por libro…) no pierde nada.
- **OPDS catalog out-of-the-box**: cualquier lector compatible (KOReader, Moon+ Reader Pro, Marvin, FBReader, Aldiko, Foliate, Thorium Reader, Librera, PocketBook…) descarga ebooks directamente desde el catálogo sin instalar apps específicas.
- **Sincronización Kobo nativa**: los e-readers Kobo (Clara, Libra, Sage, Forma…) registran el servidor como su _store_ vía _hostname rewriting_ y descargan/sincronizan progreso _over the air_, sin tener que conectar el e-reader al PC con un cable.
- **Send-to-Kindle vía SMTP**: para los lectores Kindle (que no soportan OPDS), Calibre-Web puede enviar ebooks por email a la cuenta `kindle.com` del lector, con conversión _on-the-fly_ a `.azw3`/`.mobi` si tiene Calibre disponible.
- **Imagen Docker LSIO multi-arch ARM64**: `lscr.io/linuxserver/calibre-web`. Convención conocida en el resto del homelab (Syncthing, Sonarr, Radarr…). Sin imagen oficial _upstream_ del proyecto Calibre-Web, la LSIO es la canónica de facto.
- **Footprint razonable**: ~80–150 MB de RAM idle, Python + Flask + SQLite. Bastante más ligero que Audiobookshelf y comparable a Navidrome. Conviven los cuatro en la Pi 5 sin problemas.
- **API REST mínima**: <https://github.com/janeczku/calibre-web/wiki/REST-API>. Suficiente para Homepage / Homarr (`docs/12-dashboards/`), Tag totals y "Recent uploads".

### Imagen y _tag_

- **`lscr.io/linuxserver/calibre-web:0.6`** — imagen LSIO, _tag_ "major.minor" siguiendo la convención del homelab (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`). Multi-arch (`linux/arm64`). El _tag_ `0.6` apunta a la línea estable `0.6.x` de Calibre-Web, que ha sido el _major.minor_ vigente durante los últimos años — el proyecto numera de forma _semver-like_ pero los _bumps_ de patch (`0.6.21 → 0.6.22 → 0.6.23`) son sólo _bug fixes_, _security patches_ y mejoras de _UI_, sin _breaking changes_ del _schema_ SQLite.
- **Por qué no `:latest`**: ese _tag_ se moverá si Calibre-Web sube alguna vez a `0.7.x` (el proyecto lo ha planteado más de una vez); un `docker compose pull` accidental en ese momento podría introducir cambios de _schema_ irreversibles tanto en `app.db` como en `metadata.db` (el formato de Calibre 8 introdujo cambios menores).
- **Por qué no `:nightly`**: LSIO no publica _nightly_ para Calibre-Web. Hay un _tag_ `:development` que sigue la rama `master` del _upstream_; no se considera para producción.
- **Por qué `lscr.io/linuxserver/...`**: como en Syncthing (`docs/06-almacenamiento/03-syncthing.md`, sección _Imagen_), no existe imagen Docker oficial _upstream_ del proyecto. La LSIO es la canónica: `s6-overlay` _entrypoint_, `PUID`/`PGID` configurables, `UMASK` configurable, `DOCKER_MODS` para extensiones (Calibre completo, KEPubify), _releases_ siguiendo _upstream_ con 1–3 días de retraso.

> **Convenio de versionado de Calibre-Web**: el proyecto usa _semver_ pero ha estado en `0.6.x` desde hace años; cada _patch_ trae _security fixes_ y _bug fixes_ sin migración. Vigilar las _release notes_ de cada versión: <https://github.com/janeczku/calibre-web/releases>.

#### Watchtower **opt-in**

Razones:

- **Patches frecuentes sin _breaking changes_**: la línea `0.6.x` recibe _patch releases_ con _security fixes_ del propio Calibre-Web (parches a Flask, dependencias Python, parsers de _metadata_) y de la imagen base de LSIO. Mantenerse al día sin tocar a mano es deseable.
- **Schema de BD estable dentro de una `minor`**: `app.db` (la BD interna de Calibre-Web) sólo cambia entre _minors_ (cuando aparezcan; el último cambio relevante fue al introducir _Kobo sync_); los _patches_ son intercambiables. `metadata.db` es propiedad del _esquema Calibre upstream_ y casi nunca cambia (la última migración relevante fue a Calibre 5.x, hace años).
- **Sin estado en RAM**: Calibre-Web persiste todo lo importante en `app.db` y `metadata.db`. Reciclar el contenedor durante la madrugada (la ventana de Watchtower es domingo a las 04:00 UTC, ver `docs/02-docker/04-watchtower.md`) sólo interrumpe lecturas activas — los clientes OPDS y Kobo reintentan al siguiente _poll_ sin problema.

Etiquetar el contenedor con `com.centurylinklabs.watchtower.enable: "true"`. Coherente con la lista global de `docs/02-docker/04-watchtower.md` y con el criterio aplicado a Jellyfin, Navidrome y Audiobookshelf.

> **Bumps de _minor_** (`0.6 → 0.7` el día que ocurra): se hacen **a mano**, fuera de Watchtower. Cambiar `CALIBRE_WEB_IMAGE_TAG=0.7` en `~/homelab/multimedia/.env`, leer las _release notes_ del proyecto en GitHub, hacer backup de `metadata.db` y `app.db` (Borgmatic + dump SQLite) y aplicar `make pull STACK=multimedia && make up STACK=multimedia`. Watchtower con _tag_ `0.6` no salta a `0.7` automáticamente porque mira el _digest_ del _tag_ exacto que está pinneado.

### Modo de red: `bridge` (red `homelab`), no `host`

Mismo razonamiento que en Jellyfin, Navidrome y Audiobookshelf: Calibre-Web corre en la red `homelab` (`bridge`, `172.20.10.0/24`), Caddy lo alcanza por nombre interno (`calibre-web:8083`), no se publica ningún puerto al host. No hay descubrimiento _multicast_ que necesite atravesar el bridge: los lectores se configuran a mano la primera vez con la URL `https://books.lan/opds` y la recuerdan.

### Volumen de la biblioteca de ebooks: `/services/shared/ebooks:/books:rw` (sí, **read-write**)

A diferencia de Jellyfin, Navidrome y Audiobookshelf — donde la biblioteca se montaba `:ro` y los datos llegaban "por fuera" desde Samba o Sonarr/Radarr — Calibre-Web **necesita escribir** en su biblioteca:

```yaml
volumes:
  - /mnt/hd2t/services/shared/ebooks:/books
```

Razones:

- **Subida de ebooks desde la web UI**: cualquier usuario con permiso _Upload_ puede arrastrar un fichero EPUB / PDF / MOBI directamente al navegador. Calibre-Web lo deposita en `/books/<Author>/<Title> (id)/` y actualiza `metadata.db`.
- **Edición de metadatos**: cuando el operador modifica autor, título, _tags_, _cover art_, _series_, _ratings_… los cambios se persisten en `metadata.db` (que vive **dentro** de `/books/`) y, si la opción "Save metadata to file" está activada en la _config_, también en las _tags_ OPF/EPUB del propio fichero.
- **Conversión _on-the-fly_** (si se activa): la conversión a otros formatos crea ficheros nuevos `<Title>.kepub.epub`, `<Title>.mobi`, etc., dentro del directorio del libro.
- **Importación masiva desde Calibre desktop**: el _flow_ típico es copiar un árbol Calibre completo (con su `metadata.db`) a `/books/` por SFTP/SMB y luego apuntar Calibre-Web a esa ruta. Calibre-Web seguirá escribiendo ahí.

Implicación práctica: **la biblioteca de ebooks no es Categoría C completa** como las otras bibliotecas multimedia. El `metadata.db` que vive dentro **sí** se respalda (es la BD del catálogo Calibre, no una mera caché regenerable). Los ficheros `.epub`/`.pdf`/`.mobi` mismos siguen siendo Categoría C (recuperables de la fuente original o vía operador), pero `metadata.db` es Categoría B (regenerable con esfuerzo: _re-tagging_ manual o `calibre import` desde cero, lo cual lleva horas para una biblioteca grande).

> **Esta es la convención divergente del stack `multimedia`**: tres servicios montan `:ro` (jellyfin, navidrome, audiobookshelf) y uno monta `:rw` (calibre-web). Conviene dejarlo explícito en el compose para evitar confusiones.

### Por qué `metadata.db` vive en `/books/`, no en `/config/`

Calibre tiene un único modelo: la biblioteca **es** un directorio en disco que contiene `metadata.db` en la raíz, más subdirectorios `<Author>/<Title>/` con los ficheros. Calibre-Web **no inventa nada**: lee y escribe el mismo `metadata.db` que Calibre desktop. Por tanto:

- `/books/metadata.db` ← BD del catálogo de Calibre. **Patrón S** vía `sqlite3 .backup`.
- `/config/app.db` ← BD interna de Calibre-Web (usuarios, _shelves_, configuración del servidor, sessions, OAuth tokens…). **Patrón S** vía `sqlite3 .backup`.
- `/config/gdrive.db` ← (opcional) si se activa _Google Drive sync_, persiste ahí. **No** se activa en este doc.
- `/config/kobo.db` ← (opcional) la BD de _sync_ Kobo. Generada al activar la sincronización Kobo. **No** se activa por defecto.

Ambas SQLite se respaldan con dos invocaciones distintas de `dump_sqlite` en el _hook_ de Borgmatic.

### `forward_auth` con Authelia: **NO** para Calibre-Web

Tentación natural una vez Authelia está montada: añadir `import authelia` al bloque `books.lan` del `Caddyfile`. **No se hace**, exactamente por las mismas razones que Jellyfin, Navidrome y Audiobookshelf, con un agravante específico:

- **El catálogo OPDS** (`/opds`) usa **HTTP Basic Auth** o **token Bearer**: los lectores (KOReader, Moon+, Marvin, FBReader…) abren un _stream_ XML/Atom y esperan respuesta. Si Caddy intercepta y devuelve `302 Location: https://auth.lan/?rd=...`, el cliente OPDS recibe HTML en lugar de XML y rompe el _parser_.
- **La sincronización Kobo** usa una URL larga con un token aleatorio embedido (`/kobo/<TOKEN>/...`). El e-reader no sabe redirigirse a un portal _web_ ni rellenar formularios HTML. Un _challenge_ OIDC en cada poll rompe la sincronización completamente — y los e-readers Kobo no muestran error legible: simplemente "no hay libros nuevos".
- **Send-to-Kindle vía SMTP** (si se activase): no aplica al _challenge_ porque no es HTTP, pero los _webhooks_ y URLs absolutas que Calibre-Web compone usando `Host` necesitan llegar coherentes — Authelia-aware proxying sólo añade fricción.
- **API REST**: usada desde Homepage / Homarr y, eventualmente, desde lectores que la consulten para metadatos. Mismo problema que el OPDS: el cliente espera JSON, no HTML de Authelia.
- **El propio uploader de la web UI** envía POST con `Content-Type: multipart/form-data` y _payload_ de hasta 100 MB (un PDF gordo). Authelia delante con _session refresh_ desincroniza el upload y el navegador pierde la conexión.

Solución correcta: **Calibre-Web autentica con su sistema nativo** (usuario + contraseña por usuario, gestionado en la web UI), con el _admin_ habilitando 2FA opcional (TOTP, soportado nativamente desde 0.6.20) **sólo para la web UI**. El OPDS y el Kobo sync siguen autenticando con _Basic_/_Bearer_ sin segundo factor (limitación conocida del proyecto, igual que en Audiobookshelf con la API REST).

> **Resumen operativo**: el bloque `books.lan` del `Caddyfile` lleva `import security-headers` y `import logging`, pero **no** `import authelia`. Caddy actúa como _reverse proxy_ "tonto" que termina TLS, propaga `X-Forwarded-*` y deja a Calibre-Web la autenticación.

> **Si en el futuro el operador quisiera SSO**: Calibre-Web soporta **OAuth2 / OIDC** (login vía Google, GitHub, GitLab, custom OIDC) configurable en _Admin → OAuth Settings_. Se podría apuntar a Authelia como _provider_ OIDC. Queda fuera de alcance hoy: el alcance LAN+VPN no justifica la complejidad y, aun activando OIDC, el OPDS y Kobo sync siguen autenticándose con credenciales nativas — no es un SSO real, es "OIDC sólo para humanos web".

### `app.db` y `metadata.db` ambas en SQLite (no MariaDB/Postgres)

Calibre-Web **sólo soporta** SQLite como _backend_. Misma decisión _upstream_ que Audiobookshelf. Implicaciones:

- **Footprint mínimo**: las dos BD juntas raramente superan los **50–200 MB**.
- **Backups con Patrón S** (`docs/07-backups/03-backup-docker-volumes.md`): la imagen LSIO de Calibre-Web **incluye `sqlite3` en el _PATH_** (LSIO añade el cliente CLI por convención en todas sus imágenes con SQLite). Verificable con `docker exec calibre-web which sqlite3` → `/usr/bin/sqlite3`.
- **WAL no siempre activo**: a diferencia de Audiobookshelf, Calibre-Web **no fuerza WAL** por defecto en sus dos SQLite. La copia "en caliente" con `cp` directo puede quedar inconsistente igualmente: por seguridad, **siempre** se usa `sqlite3 .backup`.

### Calibre completo vs sólo Calibre-Web: **no se instala Calibre completo en el contenedor**

LSIO publica una _docker mod_ (`linuxserver/mods:universal-calibre`) que añade el binario `ebook-convert` y la suite Calibre completa al contenedor de Calibre-Web. Habilita:

- **Conversión _on-the-fly_** entre formatos (EPUB → MOBI, EPUB → AZW3, KEPUB…).
- **Send-to-Kindle** con conversión a MOBI/AZW3 si el ebook está en otro formato.

**No se activa por defecto** en este doc por estas razones:

- **Tamaño de la imagen**: Calibre completo añade ~500 MB a la imagen (sólo Calibre-Web son ~100 MB). En una microSD de 64 GB es _bearable_, pero no se añade hasta que haga falta.
- **Conversión consume CPU**: en una Pi 5 conviviendo con Jellyfin, Navidrome, Audiobookshelf y _Stash_, una conversión EPUB → KEPUB simultánea con un escaneo de Audiobookshelf puede saturar dos _cores_. Mejor activarlo con conciencia.
- **Pocas conversiones reales**: la mayoría de lectores aceptan EPUB nativo. Sólo Kindles requieren MOBI/AZW3 (y para eso se usaría Send-to-Kindle ad-hoc, _on-demand_).

**Cómo activarlo más tarde**: descomentar la variable `DOCKER_MODS` en el `.env` y recrear el contenedor:

```bash
DOCKER_MODS=linuxserver/mods:universal-calibre
```

### Almacenamiento

| Ruta en el host                                              | Contenido                                                            | Versionable           | Backup                              |
|--------------------------------------------------------------|----------------------------------------------------------------------|-----------------------|-------------------------------------|
| `~/homelab/multimedia/docker-compose.yml`                    | Definición del _stack_ (compartida con Jellyfin/Navidrome/ABS)       | git                   | git                                 |
| `~/homelab/multimedia/.env`                                  | Imágenes pinneadas + variables del _stack_                           | **NO** (`.gitignore`) | git aparte (nota local)             |
| `~/homelab/multimedia/.env.example`                          | Plantilla con nombres de variables, sin valores                      | git                   | git                                 |
| `/mnt/hd2t/services/calibre-web/`                            | `/config` interno de Calibre-Web                                     | **NO**                | **Sí** (Borgmatic + dump)           |
| `/mnt/hd2t/services/calibre-web/app.db`                      | BD interna de Calibre-Web (usuarios, shelves, OAuth, sessions)       | **NO**                | **Sí** (Borgmatic vía dump)         |
| `/mnt/hd2t/services/calibre-web/gdrive.db`                   | (opcional) BD del sync Google Drive — **NO** activado aquí           | **NO**                | **Sí** si llega a existir            |
| `/mnt/hd2t/services/calibre-web/kobo.db`                     | (opcional) BD del sync Kobo — generada si se activa                  | **NO**                | **Sí** si llega a existir            |
| `/mnt/hd2t/services/calibre-web/log/`                        | Logs (rotados por LSIO)                                              | **NO**                | **NO** — excluido por `*/log/*`      |
| `/mnt/hd2t/services/calibre-web/converters_temp/`            | (opcional) caché de conversión temporal                              | **NO**                | **NO** — excluido por `*/cache/*`    |
| `/mnt/hd2t/services/shared/ebooks/metadata.db`               | BD del catálogo Calibre (autores, libros, _tags_, _series_…)          | **NO**                | **Sí** (Borgmatic vía dump SQLite)  |
| `/mnt/hd2t/services/shared/ebooks/<Author>/<Title>/<file>`   | Ficheros ebook (EPUB/PDF/MOBI/AZW3/CBZ…) y `cover.jpg`/`metadata.opf`| **NO**                | **NO** — Categoría C, regenerable    |

> **`metadata.db` es Categoría B, no C**: los ficheros físicos son recuperables, pero la **organización** (etiquetas, custom columns, ratings, _series_, _collections_, descripciones limpiadas a mano…) puede haber costado decenas de horas al operador. Borgmatic respalda `metadata.db` vía dump _online_ (Patrón S); el árbol de ficheros lo respalda como _filesystem_ pero queda **excluido explícitamente** por patrón (`*/services/shared/ebooks/*` salvo el `metadata.db`).

> **Decisión sobre el respaldo del árbol completo de ebooks**: por defecto **se excluye** (Categoría C), igual que music, audiobooks y media. Si el operador prefiere respaldar también los ficheros (porque la biblioteca es pequeña <50 GB y no la tiene en otro sitio), basta con eliminar el patrón de exclusión `*/services/shared/ebooks/*` del `config.yaml` de Borgmatic.

---

## Estructura del _stack_ `multimedia` tras este documento

```
~/homelab/multimedia/
├── docker-compose.yml        # ← extendido (servicio calibre-web añadido)
├── .env                      # ← extendido (variables CALIBRE_WEB_*)
├── .env.example              # ← extendido (plantilla de CALIBRE_WEB_*)
└── .gitignore                # sin cambios
```

Y en el disco externo, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/calibre-web/
├── (vacío al empezar; el primer arranque lo puebla con app.db, log/, …)

/mnt/hd2t/services/shared/ebooks/
├── (vacío al empezar; en el primer arranque Calibre-Web crea metadata.db
│   o se importa desde una biblioteca Calibre existente)
```

Verificar / asegurar permisos (deberían estar correctos por el doc de directorios; este paso es defensivo):

```bash
sudo chown -R 1000:1000 /mnt/hd2t/services/calibre-web
sudo chmod 0755 /mnt/hd2t/services/calibre-web

# Biblioteca compartida (ya creada en docs/01-sistema/04-estructura-directorios.md
# con setgid; dejamos el chown idempotente):
sudo chown -R 1000:homelab-media /mnt/hd2t/services/shared/ebooks
sudo find /mnt/hd2t/services/shared/ebooks -type d -exec sudo chmod 2775 {} +
```

> **Ownership de `/mnt/hd2t/services/calibre-web/`**: ya está fijado por `docs/01-sistema/04-estructura-directorios.md` paso 7 a `1000:1000`. La imagen LSIO arranca como `root` con `s6-overlay` y _drop_ a `abc:abc` (= `PUID:PGID` mapeados, en este caso `1000:1000`) tras configurar permisos.

> **Ownership de `/mnt/hd2t/services/shared/ebooks/`**: `1000:homelab-media 2775` (bit `setgid` activo). Calibre-Web escribe (`:rw`); para garantizar que los ficheros nuevos hereden el grupo `homelab-media` (y no `1000`), el bit `setgid` de los directorios padre se encarga del trabajo. Como medida adicional, se usa `group_add` para añadir `MEDIA_GID` como grupo suplementario al proceso, lo que evita problemas si algún subdirectorio se crease sin `setgid`.

---

## Variables de entorno

Añadir las siguientes líneas al `~/homelab/multimedia/.env.example` (debajo de las ya existentes para Jellyfin, Navidrome y Audiobookshelf):

```bash
# --- Calibre-Web ----------------------------------------------------------
# https://github.com/janeczku/calibre-web/releases — patches automáticos vía
# Watchtower; bumps de minor (0.6 -> 0.7 cuando ocurra) a mano con dump
# previo de metadata.db y app.db.
CALIBRE_WEB_IMAGE_TAG=0.6

# URL pública canónica del servicio. Usada por Calibre-Web para construir
# URLs absolutas en feeds OPDS, los enlaces de Send-to-Kindle (cuando se
# active), y los magic-links del Kobo sync.
CALIBRE_WEB_BASE_URL=https://books.lan

# DOCKER_MODS de LSIO. Por defecto vacío. Para activar Calibre completo
# (ebook-convert, Send-to-Kindle real, KEPubify…) descomentar:
#   linuxserver/mods:universal-calibre
# Aumenta la imagen ~500 MB y la RAM idle ~50 MB. Activar a posteriori.
CALIBRE_WEB_DOCKER_MODS=
```

Copiar a `.env` (ya creado por el doc de Jellyfin):

```bash
$EDITOR ~/homelab/multimedia/.env
# Añadir los mismos CALIBRE_WEB_* con los valores reales.
```

> **`.env` aquí no contiene secretos** (Calibre-Web gestiona las credenciales de los usuarios en `app.db`, hashed con `werkzeug.security.generate_password_hash`; el _Flask secret key_ se autogenera al primer arranque). Aun así, se mantiene `0600` y fuera de git por consistencia con el resto de _stacks_.

---

## `~/homelab/multimedia/docker-compose.yml` (extensión)

Añadir el siguiente servicio al compose ya existente, **a continuación** del bloque `audiobookshelf:` y **antes** del bloque `networks:` final:

```yaml
  # ---------------------------------------------------------------------------
  # Calibre-Web — servidor de ebooks (web UI + OPDS + Kobo sync).
  # Comparte red 'homelab' con jellyfin, navidrome y audiobookshelf. Caddy
  # alcanza los cuatro por nombre interno (jellyfin:8096, navidrome:4533,
  # audiobookshelf:80, calibre-web:8083).
  # ---------------------------------------------------------------------------
  calibre-web:
    image: lscr.io/linuxserver/calibre-web:${CALIBRE_WEB_IMAGE_TAG}
    container_name: calibre-web
    hostname: calibre-web
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      PUID: ${PUID}              # 1000 (homelab) — convención LSIO
      PGID: ${PGID}              # 1000 (homelab)
      UMASK: "002"               # ficheros 0664, dirs 2775 (compatible con setgid)
      # DOCKER_MODS: opcional. Por defecto vacío. Para activar Calibre completo
      # (ebook-convert + KEPubify + Send-to-Kindle real) descomentar la
      # variable en el .env:
      #   CALIBRE_WEB_DOCKER_MODS=linuxserver/mods:universal-calibre
      DOCKER_MODS: ${CALIBRE_WEB_DOCKER_MODS}
    group_add:
      # Permite a Calibre-Web LEER y ESCRIBIR /mnt/hd2t/services/shared/ebooks/
      # con el GID correcto, complementando el bit setgid de los directorios.
      # MEDIA_GID viene del .env global.
      - "${MEDIA_GID}"
    volumes:
      - /mnt/hd2t/services/calibre-web:/config
      # Biblioteca de ebooks compartida — read-write (Calibre-Web sube y
      # edita ebooks desde su web UI).
      - /mnt/hd2t/services/shared/ebooks:/books
      # Hora del host (Calibre-Web escribe timestamps en app.db).
      - /etc/localtime:/etc/localtime:ro
    networks:
      homelab:
        aliases:
          - calibre-web   # Caddy resuelve 'calibre-web:8083' por este alias
    labels:
      homelab.stack: "multimedia"
      homelab.backup: "true"   # /mnt/hd2t/services/calibre-web entra en Borgmatic
      # Opt-in: patches dentro de 0.6.x son seguros (sin schema migrations).
      com.centurylinklabs.watchtower.enable: "true"
    healthcheck:
      # /opds es público (devuelve un 401 con WWW-Authenticate si OPDS está
      # activo y requiere auth, o un 200 con Atom XML si está abierto), lo
      # cual sirve perfectamente como liveness probe sin necesitar token.
      # /robots.txt también funciona y no depende de la config OPDS.
      test:
        - CMD-SHELL
        - "wget -qO- --tries=1 --timeout=5 -S http://localhost:8083/robots.txt 2>&1 | grep -qE 'HTTP/1\\.[01] (200|401)' || exit 1"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s   # primer arranque: ~20-30 s (Python venv + app.db init)
    # Sin 'ports:'. Caddy alcanza Calibre-Web por DNS interno.
```

Notas de diseño:

- **LSIO con `PUID`/`PGID` (no `user:` directiva)**: a diferencia de Jellyfin (oficial) y Audiobookshelf (oficial), Calibre-Web es LSIO. Las imágenes LSIO arrancan como `root` para que `s6-overlay` configure permisos del volumen y luego _drop_ al UID/GID indicado en `PUID`/`PGID`. **No** usar `user:` en el compose — rompe el _entrypoint_.
- **`group_add: ["${MEDIA_GID}"]`**: añade el GID del grupo `homelab-media` como _grupo suplementario_ del proceso. Permite leer/escribir `/mnt/hd2t/services/shared/ebooks/` (que es `1000:homelab-media 2775`) coherentemente con el resto de servicios multimedia. Combinado con el bit `setgid` de los directorios, garantiza que cualquier ebook que Calibre-Web suba quede accesible por Samba sin conflictos.
- **`UMASK: "002"`**: ficheros nuevos `0664`, directorios `2775`. Lo necesario para que Samba (que también escribe en `services/shared/ebooks`) pueda releerlos sin sorpresas. `UMASK: "022"` (el _default_ de LSIO) crearía ficheros `0644` (leíbles por todos) y dirs `0755` — válido pero menos coherente con el resto del árbol `services/shared/`.
- **`/books` sin `:ro`**: deliberado y explícito. Ver **Decisiones de diseño** → _Volumen de la biblioteca de ebooks_.
- **Sin `ports:`**. Caddy alcanza Calibre-Web por DNS interno (`calibre-web:8083`). Si el operador necesita acceso directo durante un _troubleshooting_, puede `docker exec -it calibre-web wget -qO- http://localhost:8083/`.
- **`start_period: 60s`**: el primer arranque tarda ~20-30 s (S6 init + Python venv + Flask + app.db init). Margen holgado.
- **`/robots.txt` como _liveness probe_**: público (sin autenticación), siempre devuelve `200`. No requiere token, ideal para `wget -qO- -S`. Funciona también antes de que el operador haya creado la biblioteca.
- **Watchtower opt-in**: razones explicadas en **Decisiones de diseño** → _Imagen y tag_.
- **No `mem_limit`**: en idle Calibre-Web consume ~80–150 MB. Durante un _full library scan_ (`Admin → Update metadata`) sube a ~250–400 MB. Sin necesidad de ajuste en convivencia con el resto del stack `multimedia`.

---

## Despliegue

### Levantar el servicio

```bash
cd ~/homelab/multimedia
docker compose --env-file ../.env --env-file .env config | grep -A2 calibre-web   # validar
docker compose --env-file ../.env --env-file .env up -d calibre-web
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=multimedia
```

> `make up` aplica todo el stack; si Jellyfin, Navidrome y Audiobookshelf ya estaban arriba, Compose los deja como estaban y sólo crea/recrea el contenedor `calibre-web`.

Vigilar el primer arranque (tarda ~20-30 s):

```bash
docker compose -f ~/homelab/multimedia/docker-compose.yml logs -f calibre-web
# ...
# calibre-web  | [TIMESTAMP] User uid:    1000
# calibre-web  | [TIMESTAMP] User gid:    1000
# calibre-web  | [s6-init] ...
# calibre-web  | [TIMESTAMP] [INFO ] Starting Calibre-Web...
# calibre-web  | [TIMESTAMP] [INFO ] Starting Gevent server on 0.0.0.0:8083
```

Verificar que el contenedor está `(healthy)`:

```bash
docker compose -f ~/homelab/multimedia/docker-compose.yml ps calibre-web
# NAME          STATUS                  PORTS
# calibre-web   Up X seconds (healthy)
```

> El `(healthy)` lo otorga el _healthcheck_ que confirma que `/robots.txt` responde `200`. Si tras 1 minuto sigue `starting`, ir a **Troubleshooting** → primer arranque.

### Caddy: bloque `books.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque (insertar tras `audiobooks.lan` para mantener orden alfabético por servicio):

```caddy
books.lan {
    tls internal
    import security-headers
    import logging

    # Subida de ebooks por la web UI: PDFs grandes pueden superar el
    # default de Caddy de 100 MB en algunos paths. El default de Calibre-Web
    # mismo es 200 MB. Subimos el límite del reverse proxy a 200 MB para
    # cubrir el caso (ebooks de arte / cómics).
    request_body {
        max_size 200MB
    }

    reverse_proxy calibre-web:8083 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        # Calibre-Web no usa websockets, pero las descargas de ebooks
        # pueden ser largas; un keep-alive holgado evita timeouts en
        # conexiones lentas (ebooks PDF de varios cientos de MB).
        transport http {
            keepalive 60s
            response_header_timeout 120s
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
curl -k --resolve books.lan:443:192.168.1.3 \
     -s -o /dev/null -w '%{http_code}\n' https://books.lan/robots.txt
# 200

curl -k --resolve books.lan:443:192.168.1.3 \
     -s -o /dev/null -w '%{http_code}\n' https://books.lan/
# 302  (redirige al /login)
```

Y desde el navegador: `https://books.lan/` → la web UI de Calibre-Web muestra el formulario de **login** (con las credenciales por defecto `admin` / `admin123`, a cambiar inmediatamente; ver siguiente sección).

---

## Configuración tras primer arranque

### Cambiar la contraseña del admin (paso obligatorio)

Calibre-Web arranca con un usuario por defecto **`admin`** y contraseña **`admin123`**. Es **lo primero** que hay que cambiar:

1. Login con `admin` / `admin123` en `https://books.lan/`.
2. Esquina superior derecha → **Account**.
3. **Change password** → introducir una contraseña robusta (sin segundo factor todavía; ver siguiente paso).
4. **Submit**.

> **Por qué este paso es crítico**: en LAN+Tailscale el riesgo es bajo, pero las credenciales `admin` / `admin123` son trivialmente _googleables_ y el primer log que un escaneo automatizado intentaría.

### Configurar la ruta de la biblioteca

Calibre-Web arranca **sin biblioteca** la primera vez. Hay dos caminos:

**Opción A: importar una biblioteca Calibre existente**

Si el operador ya tenía una biblioteca Calibre (con su `metadata.db`) en otro sitio, copiarla a `/mnt/hd2t/services/shared/ebooks/` por SFTP o `rsync`:

```bash
# Desde el equipo donde vive la biblioteca Calibre actual:
rsync -avz --info=progress2 ~/Calibre\ Library/ \
    homelab@192.168.1.3:/mnt/hd2t/services/shared/ebooks/

# Asegurarse de que el ownership y los permisos quedan coherentes:
ssh homelab@192.168.1.3 '
  sudo chown -R 1000:homelab-media /mnt/hd2t/services/shared/ebooks
  sudo find /mnt/hd2t/services/shared/ebooks -type d -exec sudo chmod 2775 {} +
  sudo find /mnt/hd2t/services/shared/ebooks -type f -exec sudo chmod 0664 {} +
'
```

Verificar que `metadata.db` está presente:

```bash
ls -la /mnt/hd2t/services/shared/ebooks/metadata.db
# -rw-rw-r-- 1 1000 homelab-media ... metadata.db
```

**Opción B: dejar que Calibre-Web cree una biblioteca vacía**

Si no hay biblioteca previa, la web UI ofrece "Create Empty Library" en la pantalla de configuración inicial.

**Apuntar Calibre-Web a la biblioteca**:

1. En la web UI, _Admin → Edit Basic Configuration_.
2. **Location of Calibre Database**: introducir `/books` (la ruta **dentro** del contenedor; el bind mount apunta a `/mnt/hd2t/services/shared/ebooks/`).
3. **Submit**.

Calibre-Web arranca el primer escaneo. Para una biblioteca de varios miles de libros tarda 30 s – 2 minutos (Python + lectura de cubiertas + parseo de OPF). Vigilar el progreso:

```bash
docker logs calibre-web --tail 50 -f | grep -i 'librar\|scan\|metadata'
```

Cuando termina, el dashboard muestra los libros ordenados por _added at_, con _cover art_ visible.

### Activar 2FA en la web UI (opcional pero recomendado)

Calibre-Web soporta TOTP **sólo para la web UI** (no para OPDS ni Kobo sync, mismas razones que Audiobookshelf). En _Account → Two-Factor Authentication_:

1. **Enable 2FA**.
2. Escanear el QR con Authy / Aegis / Google Authenticator.
3. Validar con un código de 6 dígitos.
4. **Guardar los códigos de recuperación** en Vaultwarden (cuando exista; mientras tanto en un papel/llavero).

> **Importante**: el 2FA TOTP **sólo aplica al login web**. El OPDS catalog y la sincronización Kobo siguen autenticándose con _Basic_/_Bearer_ sin segundo factor. Es un _trade-off_ deliberado del proyecto: si el cliente OPDS recibiese un _challenge_ TOTP, la mayoría de lectores fallarían en bucle.

### Configuración del servidor (Admin → Edit UI Configuration)

Ajustes recomendados para el homelab:

- **Default Visibilities for new Users**: dejar todo desmarcado. Los usuarios nuevos arrancan con permisos mínimos y el _admin_ los amplía manualmente.
- **Default Settings for New Users**: en _Default Role_, dejar desmarcado todo excepto _View Books_. El _admin_ promociona usuarios después.
- **Default Visibility for Books**: _Show all_.
- **Cover Image Resolution**: `300` (default; el _re-render_ a alta resolución consume RAM).
- **Quick Search Limits**: `5` resultados por categoría.

### Activar OPDS (cliente de lectores)

OPDS está **activado por defecto** en Calibre-Web. Verificar:

1. _Admin → Edit Basic Configuration → Feature Configuration_.
2. **Enable OPDS** debe estar marcado.
3. **OPDS Authentication**: **Basic Auth** (la opción _Bearer Token_ requiere extensión y no la usan los lectores estándar).

Probar el endpoint OPDS desde un cliente externo (KOReader, Moon+ Reader Pro, FBReader…):

- **Catalog URL**: `https://books.lan/opds`
- **Username**: `<usuario_creado>`
- **Password**: `<contraseña>`

> **Importar la CA local**: el lector tiene que confiar en el certificado de la CA local que firma `books.lan`. Si el lector no permite importar CAs (caso típico de los Kindle ; KOReader sí lo permite), forzar TLS-skip o usar el endpoint `:8083` directamente vía Tailscale al device (fuera del modelo recomendado).

### Activar Kobo sync (opcional)

Para que un e-reader Kobo (Clara, Libra, Sage, Forma…) descargue ebooks _over the air_ desde Calibre-Web:

1. _Admin → Edit Basic Configuration → Feature Configuration_ → **Enable Kobo sync** = ON. Submit.
2. _Admin → Users → <user> → Edit_ → **Generate Token**. Copiar el token largo.
3. La URL de sincronización es: `https://books.lan/kobo/<TOKEN>/`.
4. En el e-reader Kobo, modificar el fichero `Kobo eReader.conf` (montar el e-reader como USB, editar):

   ```ini
   [OneStoreServices]
   api_endpoint=https://books.lan/kobo/<TOKEN>
   ```

   (la línea exacta depende de la versión de firmware Kobo; ver _Calibre-Web wiki → Kobo sync_ para detalle actualizado).

5. Importar la CA local en el e-reader (Kobo permite importar CAs vía `nickel.cfg`; ver wiki).
6. Conectar el e-reader a la WiFi → forzar sync. Los ebooks marcados como _Show in Kobo Sync_ aparecerán como descargas pendientes.

> **Por qué Kobo sync queda como _opt-in_**: requiere _hostname rewriting_ en el e-reader (lo que técnicamente es _trampear_ el firmware Kobo para que conecte a `books.lan` en vez de `*.kobo.com`). Funciona pero tiene contras: el e-reader perderá acceso al store oficial Kobo (lecturas compradas en kobo.com), no recibirá _firmware updates_ por OTA (hay que aplicarlos manualmente), y las _book lists_ del operador en kobo.com se desconectan. Decisión personal.

### Crear usuarios adicionales (familia)

En _Admin → Users → Add new user_:

- **Username**: nombre (ej. "pareja", "kid1").
- **Password**: distinta del admin. El usuario podrá cambiarla en _Account_.
- **Role**: marcar las opciones que correspondan:
  - **View Books** ✓ (siempre)
  - **Download** ✓ (para descargar ebooks)
  - **Upload** ✗ (sólo el _admin_ y usuarios de confianza pueden subir)
  - **Edit** ✗ (sólo el _admin_ edita metadatos)
  - **Delete** ✗
  - **Admin** ✗
- **Visibility**: marcar lo que el usuario puede ver (Authors, Languages, Series, Categories, Hot Books, Best Rated, Read and Unread…).
- **Allowed/Denied Tags y Categories**: granularidad si la biblioteca tiene contenido restringido (ej. ocultar la categoría _Adult_ a los _kids_).

> **Token API por usuario**: cada usuario puede generar su propio token desde _Account_ para integraciones (Homepage / Homarr) sin compartir la contraseña.

### Send-to-Kindle (opcional, requiere Calibre completo)

Para que Calibre-Web pueda enviar un ebook al `*.kindle.com` del lector Kindle:

1. Activar el _DOCKER MOD_ de Calibre completo: editar `~/homelab/multimedia/.env` y poner:

   ```bash
   CALIBRE_WEB_DOCKER_MODS=linuxserver/mods:universal-calibre
   ```

2. Recrear el contenedor:

   ```bash
   cd ~/homelab && make up STACK=multimedia
   ```

   El primer arranque tras activar el _mod_ tarda ~2-3 minutos extra (descarga e instala Calibre completo).

3. _Admin → Edit Basic Configuration → External binaries_:
   - **Path to Calibre E-Book Converter** → `/usr/bin/ebook-convert` (lo añade el _mod_).
4. _Admin → Edit Basic Configuration → Mail Server Settings_:
   - **Mail server type**: _SMTP_ o _Gmail OAuth_.
   - **Mail server hostname**, **Port**, **Encryption**, **Username**, **Password**: del proveedor SMTP.
   - **From email address**: la cuenta SMTP. El operador tiene que añadir esta dirección a la lista de _Approved Personal Document Email List_ de su cuenta Amazon (`amazon.es/myk` → _Settings_ → _Personal Document Settings_).
5. _Account_ → **Kindle Email**: introducir la dirección `*.kindle.com` (típicamente `<usuario>@kindle.com`).
6. Probar: en cualquier libro, botón **Send to Kindle**. El ebook se convierte a AZW3/MOBI si no lo está y se envía por email a Amazon.

> **Por qué queda como _opt-in_ y no se documenta el SMTP completo**: el SMTP saliente requiere credenciales de un proveedor (Gmail con _app password_, ProtonMail Bridge, una VPS propia con Postfix…) que están fuera del alcance del homelab _puro_ LAN+VPN. El operador que lo necesite seguirá la guía oficial.

---

## Bibliotecas y _tags_

### Estructura recomendada de la biblioteca de ebooks

Calibre **dicta** la estructura del directorio. No hay decisión a tomar: cualquier modificación rompe el _link_ entre `metadata.db` y los ficheros físicos.

```
/mnt/hd2t/services/shared/ebooks/
├── metadata.db                                # BD del catálogo
├── Author Name/
│   ├── Book Title (1234)/                     # 1234 = id en metadata.db
│   │   ├── Book Title - Author Name.epub
│   │   ├── Book Title - Author Name.mobi      # otros formatos opcionales
│   │   ├── cover.jpg
│   │   └── metadata.opf                       # tags Calibre en XML
│   └── Other Book (5678)/
│       └── ...
└── Other Author/
    └── ...
```

Calibre-Web acepta los siguientes formatos:

- **`.epub`**: el formato universal. Soportado por todos los lectores.
- **`.azw3`/`.mobi`**: Kindle. Calibre puede convertir a/desde EPUB.
- **`.pdf`**: para libros de texto, cómics y arte. PDFs muy grandes (>100 MB) pueden hacer lenta la web UI.
- **`.cbz`/`.cbr`**: cómics.
- **`.fb2`**: formato ruso, soportado por algunos lectores.
- **`.kepub.epub`**: variante de Kobo. Si se usa el _DOCKER MOD_ con KEPubify, Calibre-Web puede generar `.kepub.epub` automáticamente al subir.

> **Cover art**: Calibre extrae el _cover_ embedido del EPUB/MOBI; si no hay, descarga uno de Goodreads / Amazon (configurable en _Edit Books → Download metadata_). Guarda `cover.jpg` en el directorio del libro.

### Forzar un re-scan / actualización de metadatos

Útil tras añadir libros manualmente por SMB o tras cambiar `metadata.db` desde Calibre desktop:

- **UI**: _Admin → Edit Basic Configuration → Reconnect to Calibre Database_ (botón).
- O, más drástico, _Admin → Update Metadata_ (relee todos los libros y refresca metadatos).

> **Watcher de filesystem**: Calibre-Web **no** observa el directorio de la biblioteca con `inotify`. Si se añade un libro **manualmente** (copiando ficheros por SFTP/SMB sin pasar por Calibre-Web ni Calibre desktop), no aparece en la web UI hasta que se **reconnecte la BD** o se **reinicie el contenedor**. Por eso se recomienda **subir ebooks por la web UI** (o por Calibre desktop apuntando a `/mnt/hd2t/services/shared/ebooks/` por SMB, lo cual sí actualiza `metadata.db` correctamente).

---

## Almacenamiento

Tras el primer arranque, los árboles relevantes quedan así:

```
/mnt/hd2t/services/calibre-web/
├── app.db                         # BD interna de Calibre-Web (usuarios, shelves, sessions)
├── app.db.bak                     # backup automático cuando el admin guarda config
├── log/
│   └── calibre-web.log            # rotación interna por LSIO
├── gdrive.db                      # (sólo si se activa Google Drive sync)
└── kobo.db                        # (sólo si se activa Kobo sync)

/mnt/hd2t/services/shared/ebooks/
├── metadata.db                    # BD del catálogo Calibre
├── metadata_db_prefs_backup.json  # snapshot de prefs Calibre (regenerable)
├── <Author>/<Title> (id)/
│   ├── <Title>.epub
│   ├── cover.jpg
│   └── metadata.opf
└── ...
```

| Ruta                                                      | Permisos                  | Contenido                                                          |
|-----------------------------------------------------------|---------------------------|---------------------------------------------------------------------|
| `/mnt/hd2t/services/calibre-web/`                         | `1000:1000 0755`           | Raíz del bind mount `/config`                                        |
| `/mnt/hd2t/services/calibre-web/app.db`                   | `1000:1000 0664`           | BD SQLite interna de Calibre-Web                                     |
| `/mnt/hd2t/services/calibre-web/log/`                     | `1000:1000 0755`           | Logs (excluido de Borg via `*/log/*`)                                 |
| `/mnt/hd2t/services/shared/ebooks/`                       | `1000:homelab-media 2775`  | Biblioteca compartida, `setgid` activo                                |
| `/mnt/hd2t/services/shared/ebooks/metadata.db`            | `1000:homelab-media 0664`  | BD SQLite del catálogo Calibre                                       |
| `/mnt/hd2t/services/shared/ebooks/<Author>/<Title>/`      | `1000:homelab-media 2775`  | Subdirectorios por libro                                             |
| `/mnt/hd2t/services/shared/ebooks/<Author>/<Title>/<file>`| `1000:homelab-media 0664`  | Ebooks (`.epub`, `.pdf`, …) y `cover.jpg`/`metadata.opf`              |

> **`app.db.bak`**: Calibre-Web hace una copia automática de `app.db` cada vez que el _admin_ guarda configuración importante. Útil para rollback manual sin Borg si algo se corrompe en el último cambio.

---

## Backup

Patrón S (online, vía `sqlite3 .backup`) sobre **dos** SQLite (`metadata.db` y `app.db`), más Patrón F (filesystem-only) sobre el resto de `/config`. La biblioteca de ficheros queda excluida (Categoría C, regenerable desde el operador).

### 1. Descomentar el bloque de Calibre-Web en `dump-databases.sh`

Editar `~/homelab/backups/borgmatic/hooks/dump-databases.sh` y descomentar la línea que `docs/07-backups/03-backup-docker-volumes.md` dejó preparada, **y añadir un segundo dump para `app.db`** (en el repositorio de _hooks_ sólo hay una línea preparada por servicio; aquí necesitamos dos):

```diff
 # --- Calibre-Web (SQLite) — docs/09-multimedia/04-calibre-web.md
-# dump_sqlite calibre-web calibre-web /books/metadata.db
-# NB: metadata.db pertenece a Calibre, no al contenedor. Verificar en su doc.
+# metadata.db: BD del catálogo Calibre (vive en la biblioteca compartida).
+dump_sqlite calibre-web calibre-web /books/metadata.db
+# app.db: BD interna de Calibre-Web (usuarios, shelves, OAuth, sessions).
+dump_sqlite calibre-web calibre-web-app /config/app.db
```

> **Doble dump con nombres distintos**: `dump_sqlite` toma como segundo argumento el _basename_ con el que se nombra el fichero `.sqlite.gz` resultante. Usar `calibre-web` para `metadata.db` y `calibre-web-app` para `app.db` evita pisar uno con el otro y deja claro en el repo Borg cuál es cuál.

> **¿La imagen LSIO de Calibre-Web trae `sqlite3`?**: sí; LSIO instala el cliente CLI por convención en sus imágenes con SQLite. `docker exec calibre-web which sqlite3` devuelve `/usr/bin/sqlite3`. Si en algún _bump_ futuro se eliminase, el _hook_ falla con un error claro y se conmuta a `dump_sqlite_cold` (5 s de _downtime_, aceptable de madrugada).

Re-instalar:

```bash
~/homelab/backups/borgmatic/install.sh
sudo /usr/bin/borgmatic --dry-run --verbosity 2 | grep -A2 calibre-web
# debe listar los DOS dumps previstos (metadata.db y app.db).
```

Smoke-test del hook ejecutándolo a mano:

```bash
sudo /etc/borgmatic.d/hooks/dump-databases.sh
ls -la /mnt/hd2t/backups/dumps/calibre-web*-$(date +%F).sqlite.gz
# calibre-web-2026-04-26.sqlite.gz       12M
# calibre-web-app-2026-04-26.sqlite.gz   2M
```

Confirmar que ambos dumps abren como SQLite válido:

```bash
for f in /mnt/hd2t/backups/dumps/calibre-web*-$(date +%F).sqlite.gz; do
  echo "=== $f ==="
  sudo zcat "$f" | file -
done
# === ...calibre-web-2026-04-26.sqlite.gz ===
# /dev/stdin: SQLite 3.x database, ...
# === ...calibre-web-app-2026-04-26.sqlite.gz ===
# /dev/stdin: SQLite 3.x database, ...
```

### 2. Excluir caches y la biblioteca binaria de Borgmatic

Editar `~/homelab/backups/borgmatic/config.yaml` y añadir al bloque `exclude_patterns` (debajo de los patrones globales `*/cache/*` y `*/log/*` ya existentes, y junto a las exclusiones de otras bibliotecas multimedia):

```yaml
exclude_patterns:
  # ...patterns existentes...
  - '*/cache/*'
  - '*/log/*'
  # Calibre-Web: la BD interna y metadata.db se respaldan por dump (Patrón S).
  # El árbol de ebooks ocupa GB y es Categoría C (regenerable desde la fuente
  # original del operador). Si el operador quiere respaldar también los ficheros,
  # eliminar este patrón.
  - '/mnt/hd2t/services/shared/ebooks/**/*.epub'
  - '/mnt/hd2t/services/shared/ebooks/**/*.mobi'
  - '/mnt/hd2t/services/shared/ebooks/**/*.azw3'
  - '/mnt/hd2t/services/shared/ebooks/**/*.pdf'
  - '/mnt/hd2t/services/shared/ebooks/**/*.cbz'
  - '/mnt/hd2t/services/shared/ebooks/**/*.cbr'
  - '/mnt/hd2t/services/shared/ebooks/**/*.fb2'
  # Cache de conversión temporal (LSIO + Calibre completo).
  - '*/calibre-web/converters_temp/*'
```

> **Por qué excluir por extensión y no `*/services/shared/ebooks/*` entero**: `metadata.db` y `metadata.opf` viven _dentro_ del árbol de `ebooks/`. Excluir el directorio entero perdería esa información. La granularidad por extensión deja entrar `metadata.db`, los `metadata.opf` (legibles XML, regenerables desde `metadata.db` pero útiles si sobreviven) y `cover.jpg` (regenerables pero baratos en peso) y excluye los ficheros pesados de los ebooks.

> **Si la biblioteca es pequeña** (<10 GB) y el operador no la tiene en otro sitio, eliminar las líneas `*.epub`/`*.mobi`/etc. del `exclude_patterns` y dejar que Borg la respalde íntegra. La política por defecto opta por la versión conservadora (excluir).

Validar:

```bash
sudo borgmatic config validate
```

### 3. Confirmar que Calibre-Web está cubierto por `source_directories`

`source_directories: /mnt/hd2t/services` ya incluye `calibre-web/` y `shared/ebooks/` por inercia (ver `docs/07-backups/02-borgmatic.md`, sección _Por qué incluir el directorio padre y filtrar_). Junto con los `exclude_patterns` añadidos arriba, el efecto neto es:

- ✅ `/mnt/hd2t/services/calibre-web/app.db` — backup del filesystem (la versión "viva") + dump _online_ vía Patrón S.
- ✅ `/mnt/hd2t/services/calibre-web/app.db.bak` — backup automático de Calibre-Web.
- ❌ `/mnt/hd2t/services/calibre-web/log/` — excluido.
- ❌ `/mnt/hd2t/services/calibre-web/converters_temp/` — excluido (si llega a existir).
- ✅ `/mnt/hd2t/services/shared/ebooks/metadata.db` — backup del filesystem + dump _online_ vía Patrón S.
- ✅ `/mnt/hd2t/services/shared/ebooks/<Author>/<Title>/cover.jpg` — backup (cover art es ligero).
- ✅ `/mnt/hd2t/services/shared/ebooks/<Author>/<Title>/metadata.opf` — backup (XML ligero).
- ❌ `/mnt/hd2t/services/shared/ebooks/<Author>/<Title>/*.epub` — excluido.
- ❌ `/mnt/hd2t/services/shared/ebooks/<Author>/<Title>/*.pdf` — excluido (etc.).

Tras el siguiente _run_ programado (madrugada), Calibre-Web aparece en la lista de archives:

```bash
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL::pi-$(date +%F)T03:30:30" \
    | grep -E 'calibre-web|metadata.db' | head -10
'
# -rw-rw-r-- 1000 homelab-media 12M Apr 26 03:30 mnt/hd2t/services/shared/ebooks/metadata.db
# -rw-rw-r-- 1000 homelab-media  2M Apr 26 03:30 mnt/hd2t/services/calibre-web/app.db
# -rw-r----- root root            12M Apr 26 03:30 mnt/hd2t/backups/dumps/calibre-web-2026-04-26.sqlite.gz
# -rw-r----- root root             2M Apr 26 03:30 mnt/hd2t/backups/dumps/calibre-web-app-2026-04-26.sqlite.gz
# ...
```

### Restauración

Procedimiento idéntico al **Patrón de restauración común** documentado en `docs/07-backups/03-backup-docker-volumes.md`. En resumen:

1. `docker compose -f ~/homelab/multimedia/docker-compose.yml stop calibre-web`.
2. Mover `/mnt/hd2t/services/calibre-web/` a `<dir>.broken-<ts>` (preservar 24-48 h).
3. `borg extract` del archive elegido a `/tmp/restore-$$/`, mover en sitio.
4. Restaurar las dos SQLite desde los dumps si las del archive estuviesen dañadas (raro):

   ```bash
   sudo gunzip -c /mnt/hd2t/backups/dumps/calibre-web-app-YYYY-MM-DD.sqlite.gz \
     > /mnt/hd2t/services/calibre-web/app.db
   sudo chown 1000:1000 /mnt/hd2t/services/calibre-web/app.db

   sudo gunzip -c /mnt/hd2t/backups/dumps/calibre-web-YYYY-MM-DD.sqlite.gz \
     > /mnt/hd2t/services/shared/ebooks/metadata.db
   sudo chown 1000:homelab-media /mnt/hd2t/services/shared/ebooks/metadata.db
   ```

5. Restaurar también los ebooks **si** estaban incluidos en el backup (si se eliminaron las líneas de exclusión por extensión). Si no, los ebooks se vuelven a sincronizar manualmente desde la fuente original.
6. `docker compose -f ~/homelab/multimedia/docker-compose.yml up -d calibre-web`.
7. Esperar al `(healthy)` (típicamente <60 s).
8. Comprobar UI: usuarios, _shelves_, _ratings_, _series_ y descripciones deben recuperarse. Si hay ebooks listados en `metadata.db` pero ausentes del filesystem (porque la biblioteca binaria no se respaldó), Calibre-Web los muestra con un icono de "missing" hasta que reaparezcan.

> **La biblioteca de ebooks no se respalda por defecto** (Categoría C). Si se pierde el disco hd2t y no hay copia externa, el catálogo (`metadata.db`) se restaura pero sin los ficheros físicos. La columna "Formats" de cada libro queda vacía y el _admin_ tiene que volver a subir los ebooks desde la fuente original (laptop, drive externo, _purchases_ del operador).

---

## Verificación

Antes de dar por cerrado este documento:

- [ ] `~/homelab/multimedia/docker-compose.yml` extendido con el servicio `calibre-web` y versionado en git; `~/homelab/multimedia/.env.example` extendido con `CALIBRE_WEB_*`; `~/homelab/multimedia/.env` con valores reales (no versionado).
- [ ] `docker compose -f ~/homelab/multimedia/docker-compose.yml ps` muestra `calibre-web` como `(healthy)`.
- [ ] `docker exec calibre-web wget -qO- -S http://localhost:8083/robots.txt 2>&1 | grep 'HTTP/1'` devuelve un `200 OK`.
- [ ] `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` acepta el bloque `books.lan` añadido.
- [ ] `curl -k --resolve books.lan:443:192.168.1.3 https://books.lan/robots.txt` devuelve `200` sin redirect (sin Authelia delante).
- [ ] Login interactivo desde el navegador con la cuenta `admin` (contraseña **cambiada** desde el default `admin123`) funciona; la web UI muestra _Books_, _Authors_, _Series_ tras apuntar a `/books`.
- [ ] `metadata.db` existe en `/mnt/hd2t/services/shared/ebooks/metadata.db` con permisos `1000:homelab-media 0664`.
- [ ] Subir un ebook EPUB de prueba desde la web UI (_Upload_) → aparece en la lista de _Latest_ → se descarga vía OPDS desde un cliente externo (KOReader/Moon+/etc.) en LAN.
- [ ] El log de Calibre-Web (`docker logs calibre-web 2>&1 | grep -i 'remote\|forwarded'`) muestra que `X-Forwarded-For` se procesa: una petición desde el navegador del PC LAN aparece logueada con la IP del PC, no con `172.20.10.x`.
- [ ] Dumps SQLite generados por `dump-databases.sh`: existen `/mnt/hd2t/backups/dumps/calibre-web-$(date +%F).sqlite.gz` y `/mnt/hd2t/backups/dumps/calibre-web-app-$(date +%F).sqlite.gz`, ambos identificables como SQLite por `file -`.
- [ ] El `Caddyfile` para `books.lan` lleva `import security-headers`, `import logging`; **no** lleva `import authelia`.
- [ ] La lista `two_factor` del `access_control.rules` de Authelia **no** menciona `books.lan` (ni siquiera comentado).
- [ ] Watchtower vigila el contenedor: `docker logs watchtower --tail 50 | grep calibre-web` muestra al menos un check (label `enable: "true"` activo).
- [ ] `stat -c '%U:%G' /mnt/hd2t/services/calibre-web` devuelve `1000:1000`.
- [ ] `stat -c '%U:%G' /mnt/hd2t/services/shared/ebooks` devuelve `1000:homelab-media`.
- [ ] `docker exec calibre-web id abc` muestra `uid=1000(abc) gid=1000(abc) groups=1000(abc),${MEDIA_GID}` (o el GID real de `homelab-media`).
- [ ] Borgmatic `exclude_patterns` incluye los patrones de extensiones de ebook y `*/calibre-web/converters_temp/*`. Validado con `sudo borgmatic config validate`.
- [ ] La biblioteca aparece poblada: en _Admin → View Logs_ no hay errores tras el primer scan; el conteo de _Books_ del dashboard refleja lo que hay en `/mnt/hd2t/services/shared/ebooks/`.
- [ ] (Si se activa) OPDS funcional: `curl -k -u <user>:<pass> --resolve books.lan:443:192.168.1.3 https://books.lan/opds` devuelve un Atom XML con la lista de libros.

---

## Troubleshooting

### Primer arranque: el contenedor se queda en `starting` indefinidamente

```bash
docker logs calibre-web --tail 50
```

Causas comunes:

- **Permisos del bind mount**: si por error se hizo un `chown -R root:root /mnt/hd2t/services/calibre-web`, el _entrypoint_ S6 puede _drop_ correctamente a `1000:1000` pero el proceso falla con `PermissionError` al intentar crear `app.db`. Restaurar:

  ```bash
  sudo chown -R 1000:1000 /mnt/hd2t/services/calibre-web
  docker compose -f ~/homelab/multimedia/docker-compose.yml restart calibre-web
  ```

- **`/etc/localtime` ausente**: en algunos hosts minimalistas no existe; Calibre-Web cae a UTC silenciosamente. Crear el symlink:

  ```bash
  sudo ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
  ```

- **`metadata.db` corrupto en una restauración previa**: si Calibre-Web no puede abrir `metadata.db`, queda en bucle de log "Database error". Mover el fichero a un nombre `.bak` y dejar que Calibre-Web cree uno vacío al apuntar a `/books` desde la UI:

  ```bash
  sudo mv /mnt/hd2t/services/shared/ebooks/metadata.db \
          /mnt/hd2t/services/shared/ebooks/metadata.db.broken-$(date +%s)
  docker compose -f ~/homelab/multimedia/docker-compose.yml restart calibre-web
  # En la UI: Admin -> Edit Basic Configuration -> Location of Calibre Database -> /books
  ```

- **Imagen mal descargada**: tras un fallo de red durante el `pull`, la imagen puede quedar parcial. `docker rmi lscr.io/linuxserver/calibre-web:0.6 && docker compose -f ~/homelab/multimedia/docker-compose.yml pull calibre-web`.

### "Cannot scan books folder: permission denied"

Síntoma: log muestra `PermissionError: [Errno 13] Permission denied: '/books/<...>'`. Causa: el contenedor no es miembro del grupo `homelab-media` y los ficheros están con `0660` (sin `o+r`). Comprobar:

```bash
docker exec calibre-web id abc
# uid=1000(abc) gid=1000(abc) groups=1000(abc)   # FALTA el GID de homelab-media
```

Si falta, revisar que `MEDIA_GID` está en `~/homelab/.env` y que el bloque `group_add` está presente en el compose. Re-aplicar:

```bash
cd ~/homelab && make up STACK=multimedia
docker exec calibre-web id abc
# uid=1000(abc) gid=1000(abc) groups=1000(abc),989  # 989 = ejemplo de homelab-media
```

### "Subir ebook falla con 413 Request Entity Too Large"

Síntoma: subir un PDF / cómic grande devuelve `413` desde el navegador. Causas posibles:

- **Caddy `request_body max_size`**: el bloque `books.lan` tiene `request_body { max_size 200MB }`. Si el ebook es mayor (raro, pero posible para libros de arte), subir el límite:

  ```caddy
  request_body {
      max_size 500MB
  }
  ```

- **Calibre-Web `MAX_CONTENT_LENGTH`**: el _default_ es 200 MB. Editable desde _Admin → Edit Basic Configuration → Maximum Cover Size_ (en realidad afecta a todo el upload). Subir si es necesario.

### OPDS devuelve 401 desde el lector pero las credenciales son correctas

Causas:

- **El usuario no tiene permiso _Download_**: en Calibre-Web, sin permiso _Download_ el OPDS catalog responde `401`. _Admin → Users → <user> → Edit_ → marcar **Download**.
- **El usuario tiene una restricción de _Allowed Tags_** que vacía el catálogo: si se ha configurado _Allowed Tags_ a un valor que no casa con ningún libro, el feed OPDS aparece vacío y algunos clientes interpretan eso como `401`. Limpiar la restricción.
- **Credenciales con caracteres especiales**: algunos lectores OPDS (FBReader 2.x antiguo, ciertas versiones de Aldiko) no codifican correctamente caracteres no-ASCII en HTTP Basic. Cambiar la contraseña a una sin tildes ni símbolos exóticos.

### Kobo sync no descarga libros nuevos

Causas:

- **El libro no está marcado para Kobo sync**: por defecto, los libros nuevos no se sincronizan a Kobo. Activar el flag por libro o, mejor, en _Admin → Edit Basic Configuration → Kobo Sync_ → marcar _Sync all books_.
- **El token del usuario expiró o se regeneró**: comprobar que la URL `api_endpoint` del e-reader coincide con el token vigente en _Admin → Users → <user> → Token_.
- **Certificado de la CA local no importado en el e-reader**: el Kobo cierra la conexión sin error visible si TLS falla. Importar la CA local (ver wiki de Calibre-Web → Kobo).
- **El proxy `/kobo/<TOKEN>` se rompe en Caddy**: comprobar que Caddy reenvía sin reescribir la URL. El bloque del `Caddyfile` no debe tener `handle_path`; el `reverse_proxy` simple ya pasa la URL tal cual.

### "Send to Kindle" falla con "Calibre binary not found"

Causa: el _DOCKER MOD_ `universal-calibre` no está activado o el contenedor no se ha recreado tras activarlo. Verificar:

```bash
docker exec calibre-web which ebook-convert
# /usr/bin/ebook-convert  (si está activado)
# (vacío si no)
```

Si vacío, comprobar `docker exec calibre-web env | grep DOCKER_MODS` y que la variable contiene `linuxserver/mods:universal-calibre`. Si no, ajustar `~/homelab/multimedia/.env`:

```bash
CALIBRE_WEB_DOCKER_MODS=linuxserver/mods:universal-calibre
```

Recrear el contenedor:

```bash
docker compose -f ~/homelab/multimedia/docker-compose.yml up -d --force-recreate calibre-web
```

Esperar 2-3 minutos al primer arranque (el _mod_ instala Calibre completo en el _entrypoint_).

### `app.db` se corrompe tras un corte de luz

Síntoma: tras un `kill -9` o un corte abrupto, `app.db` queda inconsistente y Calibre-Web no arranca. La copia automática `app.db.bak` (que Calibre-Web crea al guardar config) puede salvar la situación:

```bash
docker compose -f ~/homelab/multimedia/docker-compose.yml stop calibre-web
sudo mv /mnt/hd2t/services/calibre-web/app.db \
        /mnt/hd2t/services/calibre-web/app.db.broken-$(date +%s)
sudo cp /mnt/hd2t/services/calibre-web/app.db.bak \
        /mnt/hd2t/services/calibre-web/app.db
sudo chown 1000:1000 /mnt/hd2t/services/calibre-web/app.db
docker compose -f ~/homelab/multimedia/docker-compose.yml up -d calibre-web
```

Si `app.db.bak` también está dañado, restaurar desde el último dump del Patrón S (ver _Restauración_).

### "Update Metadata" tarda horas y no termina

Síntoma: en _Admin → Update Metadata_, el job se queda colgado. Causa típica: una biblioteca grande (>10 000 libros) en USB HDD lento + Python single-threaded.

Mitigaciones:

- **No ejecutar Update Metadata sobre todo a la vez**: usar el filtro por _Tags_ o _Authors_ para procesar por tandas.
- **Excluir el job de un horario activo**: el escaneo bloquea I/O del disco.
- **Reiniciar el contenedor si queda colgado**: `docker compose -f ~/homelab/multimedia/docker-compose.yml restart calibre-web`. El re-scan al volver es relativamente rápido (Calibre-Web cachea).

---

## Actualización

### Patches de la línea `0.6.x` (vía Watchtower, automático)

Watchtower opt-in está activo. Cada domingo a las 04:00 UTC, Watchtower comprueba el _digest_ del _tag_ `0.6`; si hay uno nuevo, hace `pull` + `recreate` del contenedor Calibre-Web. Sin acción del operador.

Verificar tras un domingo:

```bash
docker logs watchtower --tail 50 | grep calibre-web
# time=... msg="Found new lscr.io/linuxserver/calibre-web:0.6 image"
# time=... msg="Stopping /calibre-web"
# time=... msg="Creating /calibre-web"
```

Si tras la recreación el `(healthy)` no llega en 1-2 minutos, ir a **Troubleshooting**.

### Bumps de minor (`0.6 → 0.7`, manual)

Cuando Calibre-Web suba a `0.7.x` el día que ocurra:

```bash
# 1. Leer las release notes
xdg-open https://github.com/janeczku/calibre-web/releases
# Buscar "Breaking changes", "Database migrations" y "Schema changes" — si
# toca alguna integración activa o hay migración irreversible, planificar el
# cambio antes del bump.

# 2. Backup completo previo
sudo /usr/bin/borgmatic --verbosity 1
# Verificar que el último archive tiene fecha de hoy y que los DOS dumps
# (calibre-web-* y calibre-web-app-*) están presentes:
sudo ls -la /mnt/hd2t/backups/dumps/calibre-web*-$(date +%F).sqlite.gz

# 3. Cambiar el tag y aplicar
$EDITOR ~/homelab/multimedia/.env
# CALIBRE_WEB_IMAGE_TAG=0.7
cd ~/homelab
make pull STACK=multimedia
make up   STACK=multimedia

# 4. Vigilar el log durante la migración del schema
docker compose -f ~/homelab/multimedia/docker-compose.yml logs -f calibre-web
# Buscar:
#   INFO: Performing app.db schema migration ...
#   INFO: Migration completed
# Si el log muestra ERROR o el contenedor entra en restart loop, ir a Troubleshooting.

# 5. Validar la web UI, OPDS, los usuarios y (si está activo) Kobo sync
```

> **Migraciones irreversibles**: una vez Calibre-Web 0.7 arranca y migra `app.db`, **no hay vuelta atrás** sin restaurar desde backup. Por eso el paso 2 (backup completo previo) es obligatorio.

---

## Referencias

- Documentación oficial — Calibre-Web (wiki): <https://github.com/janeczku/calibre-web/wiki>
- Releases del proyecto: <https://github.com/janeczku/calibre-web/releases>
- Imagen Docker LSIO: <https://github.com/linuxserver/docker-calibre-web>
- LinuxServer.io — Convención `PUID`/`PGID`: <https://docs.linuxserver.io/general/understanding-puid-and-pgid/>
- LSIO `docker-mods` (Calibre completo): <https://github.com/linuxserver/docker-mods/tree/universal-calibre>
- API REST de Calibre-Web: <https://github.com/janeczku/calibre-web/wiki/REST-API>
- OPDS spec (Atom Publishing): <https://opds.io/>
- Kobo sync (configuración avanzada en el wiki): <https://github.com/janeczku/calibre-web/wiki/Kobo-Sync-via-Calibre-Web>
- Calibre upstream (esquema `metadata.db`): <https://manual.calibre-ebook.com/>
- Documentos relacionados del homelab:
  - `docs/02-docker/02-estructura-compose.md` — convenciones de stacks, red `homelab`, regla `:rw` deliberada en biblioteca de ebooks.
  - `docs/03-red/04-caddy.md` — Caddy, CA local, _snippets_ `security-headers` y `logging`.
  - `docs/03-red/02-pihole.md` — DNS local `*.lan`.
  - `docs/04-seguridad/01-authelia.md` — por qué Calibre-Web **no** entra en `forward_auth`.
  - `docs/04-seguridad/02-fail2ban.md` — _jails_ futuros para `Failed login` de Calibre-Web (mismo patrón que ABS).
  - `docs/06-almacenamiento/02-samba.md` — _share_ `ebooks` que escribe en la misma carpeta que Calibre-Web (también `:rw`).
  - `docs/07-backups/01-estrategia-backup.md` — biblioteca de ebooks como Categoría C, `metadata.db` como Categoría B.
  - `docs/07-backups/02-borgmatic.md` — `source_directories`, `exclude_patterns` global.
  - `docs/07-backups/03-backup-docker-volumes.md` — Patrón S, _hooks_ `dump_sqlite calibre-web` y `dump_sqlite calibre-web-app`.
  - `docs/09-multimedia/01-jellyfin.md` — primer servicio del stack `multimedia`, convenciones compartidas.
  - `docs/09-multimedia/02-navidrome.md` — segundo servicio del stack `multimedia`.
  - `docs/09-multimedia/03-audiobookshelf.md` — tercer servicio del stack `multimedia`, gemelo del razonamiento `forward_auth`.
  - `docs/09-multimedia/05-stash.md` (siguiente fase) — siguiente servicio del stack.
