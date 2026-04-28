# Calibre-Web

## Descripción

Despliegue de **Calibre-Web** ([imagen oficial LinuxServer.io `lscr.io/linuxserver/calibre-web`](https://docs.linuxserver.io/images/docker-calibre-web/)) como **servidor web de biblioteca de ebooks** del homelab. Calibre-Web es una **interfaz web** para una biblioteca **de Calibre** preexistente: lee y escribe sobre el `metadata.db` que la app de escritorio Calibre genera, sin necesidad de tener Calibre Desktop corriendo.

Sirve la biblioteca por tres vías:

1. **Web UI propia** (Python + Flask + Jinja2) servida en `:8083` dentro del contenedor: catálogo navegable, lectura en línea con el visor `epub.js` (EPUB nativo en el navegador) + `pdf.js` (PDF), reading list por usuario, shelves (estantes compartidos o privados), búsqueda por autor/serie/tag/idioma.
2. **Catálogo OPDS** ([Open Publication Distribution System](https://specs.opds.io/opds-1.2)) en `/opds`, que consumen los lectores ebook de terceros: **KOReader**, **Moon+ Reader**, **FBReader**, **PocketBook InkPad**, **Aldiko**, etc.
3. **Kobo Sync** (endpoint propio bajo `/kobo/<authToken>/v1/...`) que emula la API oficial de Kobo: el operador apunta su Kobo a `https://calibre.lan/kobo/<authToken>` (o equivalente Tailscale) editando `Kobo/Kobo eReader.conf` y los libros, shelves y progreso de lectura se sincronizan **en ambos sentidos** entre Calibre-Web y el dispositivo.

Este doc cubre, en orden:

1. **Por qué Calibre-Web** y no COPS, BicBucStriim, Ubooquity, Kavita, o el `Content server` que trae el propio Calibre — qué se asume y qué se descarta.
2. **Plan de variables y archivos**: `.env.example` versionable, `.env` real con valores en `/mnt/hd2t/services/calibre-web/.env`, layout de directorios bajo `/mnt/hd2t/services/calibre-web/` y bajo `/mnt/hd2t/media/books/`.
3. **Estructura de la biblioteca de Calibre**: el árbol `Autor/Título (id)/<libro>.<formato> + cover.jpg + metadata.opf + metadata_db_prefs_backup.json`, con `metadata.db` como **única fuente de verdad** de los metadatos (Calibre-Web los edita ahí, no en los tags ID3/EPUB).
4. **`docker-compose.yml`** con bind mount de `/mnt/hd2t/media/books` en read-write (Calibre-Web edita `metadata.db` y permite uploads), separación entre `config/` (BD `app.db` con usuarios, shelves, OAuth, configuración del servidor — respaldable) y `cache/` (KEPUB convertidos para Kobo Sync, thumbnails de la cover redimensionados — **excluido** del backup según [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6).
5. **Despliegue, onboarding inicial** (login con `admin` / `admin123`, **forzar cambio de password en el primer acceso**, configuración del path a la biblioteca).
6. **Integración con Caddy** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3): bloque `calibre.{$LAN_DOMAIN}` (no existe placeholder en `Caddyfile`; se añade en §6.1), DNS local en Pi-hole, ajuste de `MAX_REQUEST_SIZE` para uploads grandes (PDFs escaneados pueden llegar a ~200 MB).
7. **Auth nativa de Calibre-Web** (multi-usuario, hasheo bcrypt, JWT en cookies + Bearer en API) y por qué Authelia delante **rompe** Kobo Sync y los lectores OPDS (envían `Authorization: Basic <user:pass>` directamente, no cookie SSO). Variante opt-in con `Reverse Proxy Login Header Name` en §12.4 — Calibre-Web confía en una cabecera HTTP que Authelia inyecta y autentica al usuario sin formulario propio. Compatible con la web pero no con OPDS / Kobo Sync.
8. **DOCKER_MODS y conversión de formatos**: por defecto, la imagen es **slim** (~200 MB) y **no incluye** los binarios de Calibre (`ebook-convert`, `kepubify`). Sin ellos, los botones "Convert" y "Send-to-Kindle (con conversión)" están deshabilitados. Activar `DOCKER_MODS=linuxserver/mods:universal-calibre` añade ~1.5 GB de binarios pero habilita todas las conversiones — decisión opt-in en §12.5.
9. **Backup**: `config/app.db` (~5–20 MB) + la **biblioteca completa** (`/mnt/hd2t/media/books/` con `metadata.db` y los ficheros de los libros) cubierta por la política general 3-2-1 ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §6); el `cache/` se regenera tras la primera petición de KEPUB de cada libro / la primera vista de cada cover en cada cliente.
10. **Operaciones cotidianas**: upgrade vía Watchtower (Calibre-Web es **opt-in** según [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2), añadir libros (UI / `calibredb add` / Syncthing), gestión de usuarios, configuración de Send-to-Kindle (SMTP), Kobo Sync, exportar la biblioteca.
11. **Variantes opt-in**: Tailscale para acceso remoto, OAuth con Authelia (Reverse Proxy Header), conversión automática vía `DOCKER_MODS`, scrobbling a Goodreads, importación desde un servidor Calibre Content Server existente.

> **Alcance de red**: Calibre-Web **solo se accede vía Caddy** sobre `https://calibre.lan` (LAN) o `https://calibre.${TS_DOMAIN}` (Tailscale). El puerto 8083 del contenedor **no se publica al host** (regla del homelab para todos los servicios web, [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §0). Los lectores OPDS y Kobo Sync conectan con la URL completa: `https://calibre.lan` en LAN, `https://calibre.tailnet.ts.net` en remoto.

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), grupo `media` (GID 1100) con `homelab` como miembro, `/mnt/hd2t/` montado, `/mnt/hd2t/media/books/` creado con `homelab:media 2775` ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §3, §6).
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` creada, convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5 — bind mounts; §4.3 — red compartida; §5.2 — `PGID=1100` para multimedia).
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) con `lan_internal_tls` operativo y la red `homelab` accesible. Sin Caddy no hay HTTPS y los lectores OPDS modernos (KOReader ≥ 2023.x) rechazan conexiones HTTP por defecto.
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con la posibilidad de añadir registros A locales (`calibre.lan` → IP de la Pi).
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Calibre-Web lleva la etiqueta `com.centurylinklabs.watchtower.enable: "true"` por política — los upgrades son **automáticos** porque el proyecto Calibre-Web migra el schema de SQLite (`app.db`) vía `flask-migrate` de forma idempotente y publica releases con changelog estable.
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) para que `/mnt/hd2t/services/calibre-web/config/` y `/mnt/hd2t/media/books/` sean archivados, y `/mnt/hd2t/services/calibre-web/cache/` quede **excluido** según las reglas de §13.6 de ese doc.
- **Biblioteca Calibre presente** en `/mnt/hd2t/media/books/`: Calibre-Web **no crea** la biblioteca por sí mismo; necesita un `metadata.db` válido. Tres vías para obtenerlo (§3.3):
    1. Importar una biblioteca de Calibre Desktop (Mac/Windows/Linux) vía rsync/Syncthing.
    2. Crear una biblioteca vacía con `calibredb` desde la propia imagen (requiere `DOCKER_MODS=linuxserver/mods:universal-calibre` en el primer arranque).
    3. Descargar el `library.zip` de demo del repositorio Calibre-Web (contiene un `metadata.db` vacío + un libro de prueba) — solo recomendado para una primera prueba.
- **Disco hd2t libre**: ≥ 1 GB para `/mnt/hd2t/services/calibre-web/` (BD `app.db` ~5–20 MB con 5 usuarios y 2000 libros; cache de KEPUB ~50–200 MB con biblioteca grande, dominado por el tamaño de los EPUB convertidos). El espacio para los **propios contenidos** (los EPUB / PDF / MOBI / AZW3) se planifica aparte ([`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md) §6) — biblioteca típica de ~2000 ebooks ronda 4–8 GB.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Servidor web de biblioteca de ebooks | **Calibre-Web** ([GPL-3.0](https://github.com/janeczku/calibre-web/blob/master/LICENSE.md)) | COPS (PHP, "Calibre OPDS PHP Server") y BicBucStriim están sin actualizaciones desde 2022. Ubooquity es freeware (no FOSS) y abandonware desde 2020. Kavita es excelente para cómics/manga pero su soporte de EPUB de texto es secundario y no integra Kobo Sync. El `Content Server` que viene con Calibre Desktop requiere tener Calibre Desktop **corriendo** (~400 MB de RAM con UI Qt cargada) y no expone Kobo Sync ni OAuth. Calibre-Web es un **proyecto vivo** con releases mensuales, multi-usuario nativo, OPDS bien probado, Kobo Sync, Send-to-Kindle vía SMTP y conversión opt-in vía DOCKER_MODS. |
| Imagen | **`lscr.io/linuxserver/calibre-web`** (LinuxServer.io) | LinuxServer.io es el mantenedor de facto en Docker para Calibre-Web — el repo upstream `janeczku/calibre-web` no publica imagen oficial. La imagen LSIO respeta `PUID`/`PGID` nativamente, soporta el sistema `DOCKER_MODS` (necesario para añadir los binarios de Calibre opcionales) y ofrece arm64. La alternativa `crocodilestick/calibre-web-automated` añade automatizaciones de "drop a folder" pero introduce un binario adicional que no se necesita en este homelab. |
| Tag de imagen | **`0.6.24`** (no `latest`, no `0.6`) | Calibre-Web sigue un esquema `0.MAJOR.MINOR` algo errático (lleva años en `0.x` sin pasar a `1.0`). Pinear el patch obliga a confirmar el upgrade leyendo https://github.com/janeczku/calibre-web/releases — especialmente cuando hay migraciones de `app.db` (han ocurrido p. ej. en la 0.6.21 al añadir Kobo Sync v2). Watchtower respeta tags exactos vía `image: lscr.io/linuxserver/calibre-web:${CW_IMAGE_TAG}` — al cambiar el `.env` y reiniciar, se actualiza; sin cambio, no. |
| Arquitectura | `linux/arm64` (Pi 5) | Manifest multi-arch oficial. La imagen slim pesa ~210 MB (Python + Flask + dependencias `pip`); con `DOCKER_MODS=linuxserver/mods:universal-calibre` crece a ~1.7 GB en disco (binarios de Calibre `ebook-convert`, `kepubify`, `pdftohtml`...). |
| Red Docker | **`homelab`** (bridge, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.3). **Sin** `ports:` al host. | Caddy llega a Calibre-Web por nombre (`http://calibre-web:8083`) sobre la red compartida. No publicar `8083` al host elimina el riesgo de que la UI sea accesible **sin** TLS (Calibre-Web maneja credenciales en formularios HTTP `POST` y autenticación Basic en OPDS — sin TLS, ambas viajarían en claro). |
| Modelo de almacenamiento | **Bind mount** `/mnt/hd2t/services/calibre-web/{config,cache}:/{config,config/.cache}` + **Bind mount** de la biblioteca | Patrón estándar del homelab. La separación `config` (BD SQLite + secrets, único fichero crítico junto con la biblioteca) / `cache` (KEPUBs convertidos + thumbnails) permite una política de backup quirúrgica: `config + biblioteca` sí, `cache` no. La imagen LSIO escribe el cache de `kepubify` en `/config/.cache/kepubify/` por defecto; lo separamos con un bind mount sobre `/config/.cache` para excluirlo limpiamente sin tocar la imagen. |
| Biblioteca de libros como **read-write** dentro del contenedor | `/mnt/hd2t/media/books:/books` (sin `:ro`) | Calibre-Web **escribe** en la biblioteca: edita `metadata.db` (cambiar título, autor, tags, serie), añade ficheros nuevos (upload por la UI, "Convert" genera nuevos formatos), borra ficheros (borrado de libro). A diferencia de Audiobookshelf y Jellyfin (que mantienen sus metadatos en BD propia y dejan los ficheros intactos), **Calibre-Web es coautor de la biblioteca**: la mantiene "viva" como lo haría Calibre Desktop. Si el operador quiere proteger la biblioteca de cambios accidentales, hay un toggle "Read-Only" en Settings > UI Configuration que solo afecta a la **UI** (no impide que un admin con shell escriba). |
| BD de Calibre-Web | **SQLite** en `/config/app.db` | Calibre-Web no soporta otros backends (es Flask + `sqlalchemy` con SQLite hardcodeado en muchos sitios). Para ≤ 50 usuarios y ≤ 50 000 libros no hay problema; el coste dominante en Pi 5 es el escaneo del `metadata.db` de Calibre, no el `app.db`. |
| BD de Calibre (la **biblioteca**) | **SQLite** en `/mnt/hd2t/media/books/metadata.db` | Es la BD de la **biblioteca**, separada del `app.db`. La crea y la mantiene Calibre Desktop (o `calibredb` desde el contenedor con DOCKER_MODS). Calibre-Web la lee y la escribe; Calibre Desktop también puede abrirla. **No** ejecutar Calibre Desktop y Calibre-Web simultáneamente sobre la misma biblioteca — el `metadata.db` no soporta dos escritores concurrentes (lock fuerte de SQLite + locks ad-hoc del binario `calibredb`). Si hace falta, parar Calibre-Web → editar con Calibre Desktop → reiniciar Calibre-Web. |
| Usuario dentro del contenedor | **`PUID=1000` (homelab) + `PGID=1100` (media)** vía variables de entorno (la imagen LSIO las respeta) | Coherente con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.2. Calibre-Web puede leer y escribir la biblioteca porque pertenece al grupo `media` (GID 1100). Escritura en `/config` necesita escritura en disco — `/config` es `homelab:homelab` (GID 1000); `/books` es `homelab:media` con `setgid` (`2775`) heredado de `/mnt/hd2t/media/`. |
| Conversión de formatos (`ebook-convert`, `kepubify`) | **Desactivada por defecto** (sin DOCKER_MODS) | La imagen slim no incluye los binarios de Calibre. Sin ellos, los botones "Convert" y "Send-to-Kindle (con conversión a MOBI/AZW3)" están deshabilitados, y Kobo Sync sirve el EPUB original (no el KEPUB optimizado para Kobo, que indexa frase a frase). Para uso estándar de homelab (lectura web + envío directo del EPUB al Kindle moderno, que ya soporta EPUB desde 2022) **es suficiente**. Para activar, ver §12.5 — añade ~1.5 GB pero habilita conversión completa. |
| Backup | **`/config/` + biblioteca completa, sin `cache/`** vía Borgmatic | El resto se regenera (KEPUBs, thumbnails). Política en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6 (`/mnt/hd2t/services/calibre-web/cache` excluido). La biblioteca (`/mnt/hd2t/media/books/`) **sí** entra en backup: contiene los ficheros originales (irreplazables si fueron compras propias) y el `metadata.db` con metadatos curados (tags, series, descripciones editadas a mano). Restore: instalar CW virgen, restaurar `/config + /mnt/hd2t/media/books`, **rescanear** la biblioteca (CW re-popula índices y deja `app.db` intacto porque el `book.id` es estable entre `metadata.db` y `app.db`). |
| Watchtower | **`com.centurylinklabs.watchtower.enable: "true"`** | Por política ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2). Calibre-Web migra schema con `flask-migrate` de forma idempotente y publica releases con changelog. Distinto de Jellyfin (manual): el riesgo de un upgrade roto es bajo porque `app.db` es poco más que usuarios + shelves + tokens. |
| Reverse proxy | **Caddy sin `forward_auth`** | Calibre-Web tiene auth nativa (`/login` + cookie de sesión + JWT para Kobo Sync). Los lectores OPDS envían `Authorization: Basic <user:pass>` directamente; Kobo Sync envía `Authorization: Bearer <kobo-token>`. Aplicar Authelia con `forward_auth` rompería **ambos** (no envían cookie SSO). El paywall SSO **no aporta** nada sobre la auth nativa ya multiusuario. Variante con `Reverse Proxy Login Header Name` en §12.4 — Calibre-Web acepta una cabecera HTTP firmada por Caddy/Authelia que delega la auth solo para la UI web, manteniendo Basic Auth en OPDS y Bearer en Kobo. |
| Acceso remoto | **Vía Tailscale** ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) — `calibre.${TS_DOMAIN}` con `tls /data/tailscale-certs/calibre.crt /data/tailscale-certs/calibre.key` | Sin port forwarding ni DDNS. Los lectores OPDS aceptan **una** URL — el operador la cambia manualmente entre LAN y remoto, **o** registra dos catálogos (`Casa LAN` y `Casa remoto`). Tailscale + MagicDNS hace que `calibre.tailnet.ts.net` resuelva igual desde cualquier sitio. |
| Onboarding del primer login | **Por la UI web** con `admin` / `admin123` y **cambio inmediato de password** | Calibre-Web hardcodea las credenciales del primer admin en el bootstrap del `app.db` ([`cps/admin.py`](https://github.com/janeczku/calibre-web/blob/master/cps/admin.py)). El primer paso obligado tras el login es cambiar el password (sin esto, cualquiera con acceso de red al puerto 8083 controla el servicio). |
| Send-to-Kindle | **Configurado, vía SMTP** | Calibre-Web envía el libro como adjunto a la dirección `@kindle.com` del usuario. SMTP recomendado: la cuenta del operador (Gmail con App Password, Fastmail con SMTP Submission, etc.). Configurado por usuario (cada uno apunta a su propio Kindle). Sin DOCKER_MODS, solo se envía el formato original; con DOCKER_MODS, Calibre-Web convierte EPUB → AZW3 antes de enviarlo (más fiel al formato Kindle). |

---

## 1. Resumen de la arquitectura

```
                 ┌────────────────── LAN ──────────────────┐
                 │                                         │
   Cliente       │  Web │ KOReader │ Moon+ Reader │ Kobo   │
        │        │   │  │    │     │      │       │   │    │
        └────────┴───┴──┴────┴─────┴──────┴───────┴───┴────┘
                                                    │
                                                    ▼
                                       https://calibre.lan
                                                    │
                                                    ▼ (TLS de Caddy)
                                         ┌────────────────────┐
                                         │       Caddy        │  (../03-red/04-caddy.md)
                                         │   calibre.lan      │
                                         │       :443         │
                                         └─────────┬──────────┘
                                                   │ reverse_proxy (red homelab)
                                                   │ http://calibre-web:8083
                                                   ▼
                                       ┌──────────────────────────┐
                                       │      Calibre-Web         │
                                       │   (este doc, :8083)      │
                                       │                          │
                                       │  /config         (RW)    │ ─► /mnt/hd2t/services/calibre-web/config/
                                       │  /config/.cache  (RW)    │ ─► /mnt/hd2t/services/calibre-web/cache/
                                       │  /books          (RW)    │ ─► /mnt/hd2t/media/books/
                                       └─────────┬────────────────┘
                                                 │
                          ┌──────────────────────┼──────────────────────┐
                          ▼ inotify watcher       ▼ KEPUB on-demand     ▼ SMTP relay
                ┌──────────────────────┐ ┌──────────────────────┐ ┌──────────────────────┐
                │ /mnt/hd2t/media/     │ │ /config/.cache/      │ │  Internet (vía       │
                │ books/               │ │ kepubify/<id>/       │ │  Pi-hole DNS):       │
                │  ├── metadata.db     │ │   libro.kepub.epub   │ │  smtp.gmail.com      │
                │  ├── Autor/          │ │                      │ │  (Send-to-Kindle)    │
                │  │   └── Título (1)/ │ └──────────────────────┘ └──────────────────────┘
                │  │       ├── lib.epub│
                │  │       ├── cover.jpg│
                │  │       └── metadata.opf│
                │  └── ...             │
                │ alimentado por:      │
                │  - Operador (rsync,  │
                │    Calibre Desktop)  │
                │  - Calibre-Web (UI:  │
                │    upload, edit,     │
                │    convert, delete)  │
                └──────────────────────┘
```

Lo crítico de este diagrama:

1. **Una única vía de entrada para clientes**: navegador, KOReader, Moon+ Reader, Kobo → Caddy → Calibre-Web. El puerto 8083 no existe para clientes externos al stack.
2. **Biblioteca en read-write**: a diferencia de Audiobookshelf (`:ro`), Calibre-Web **escribe** en `/mnt/hd2t/media/books/` — edita `metadata.db`, añade libros al subir EPUBs por la UI, borra ficheros al "Delete book". Coincide con la fila `books/` de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6 ("Calibre-Web / sincronización manual").
3. **Una sola biblioteca a la vez**: SQLite `metadata.db` no soporta dos escritores. Si se usa Calibre Desktop sobre la misma carpeta, **parar Calibre-Web antes**.
4. **Cache local separado**: `/mnt/hd2t/services/calibre-web/cache/` contiene KEPUBs convertidos para Kobo Sync e imágenes redimensionadas. Excluido del backup.
5. **Sin discovery**: en bridge no hay multicast. Los lectores OPDS y Kobo se configuran **siempre** con URL.
6. **Sin GPU passthrough**: las conversiones de ebook son CPU-only (texto). El contenedor **no** monta `/dev/dri`.

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/calibre-web/.env.example`:

```env
# ~/homelab/stacks/calibre-web/.env.example
# Versión control: ~/homelab/stacks/calibre-web/.env.example
# Valores reales en /mnt/hd2t/services/calibre-web/.env (chmod 600).
# Este fichero NO contiene secretos; las credenciales de los usuarios
# Calibre-Web viven dentro de /config/app.db (hash bcrypt) y se
# respaldan vía Borgmatic. El password SMTP para Send-to-Kindle se
# configura por usuario desde la UI y se cifra en app.db.

# --- Comunes del homelab ---
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
MEDIA_GID=1100
TZ=Europe/Madrid

# --- Dominios internos (consistentes con dns/.env y proxy/.env) ---
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Calibre-Web ---
# https://docs.linuxserver.io/images/docker-calibre-web/
# Lista de cambios upstream: https://github.com/janeczku/calibre-web/releases
CW_IMAGE_TAG=0.6.24

# Hostnames públicos (sin esquema). Usados en Caddyfile.
CW_LAN_HOST=calibre.lan
CW_TS_HOST=calibre.tailnet.ts.net

# DOCKER_MODS: vacío = imagen slim (sin Calibre binaries — sin "Convert"
# ni KEPUB ni envío con conversión a Kindle). Para activar la suite
# completa, fijar a:
#   linuxserver/mods:universal-calibre
# Esto descarga ~1.5 GB extra al pull. Más detalle en §12.5.
DOCKER_MODS=

# OAUTHLIB_RELAX_TOKEN_SCOPE: Calibre-Web maneja OAuth (GitHub, Google,
# Authelia) con `oauthlib`, que valida estrictamente el `scope`
# devuelto. Algunos providers (Google) reordenan/recortan los scopes y
# rompen el flujo. Relajar evita el error "Scope has changed".
OAUTHLIB_RELAX_TOKEN_SCOPE=1
```

### 2.2. `.env` real (`/mnt/hd2t/services/calibre-web/.env`)

```bash
# Crear el .env con permisos correctos.
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/calibre-web
sudo install -o homelab -g homelab -m 600 /dev/null \
  /mnt/hd2t/services/calibre-web/.env

# Volcar contenido (editar valores reales).
sudo -u homelab tee /mnt/hd2t/services/calibre-web/.env > /dev/null <<'EOF'
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
MEDIA_GID=1100
TZ=Europe/Madrid
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net
CW_IMAGE_TAG=0.6.24
CW_LAN_HOST=calibre.lan
CW_TS_HOST=calibre.tailnet.ts.net
DOCKER_MODS=
OAUTHLIB_RELAX_TOKEN_SCOPE=1
EOF

# Verificar.
ls -l /mnt/hd2t/services/calibre-web/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` (§4) declara `env_file: /mnt/hd2t/services/calibre-web/.env`. Compose carga el fichero **a la hora de interpolar `${...}` en el YAML** (para tags, hostnames, `PUID`, `PGID`…) y **además** lo expone al proceso del contenedor. La imagen LSIO de Calibre-Web lee `PUID`, `PGID`, `TZ`, `DOCKER_MODS` directamente ([referencia oficial](https://docs.linuxserver.io/images/docker-calibre-web/)) — equivale a `docker run -e PUID=1000 ...`. El homelab prefiere `env_file` por dos razones:

1. **Trazabilidad**: una sola fuente de verdad (`.env`) en lugar de varios `-e` esparcidos en el Compose.
2. **Backup compacto**: `/config/app.db` ya respalda usuarios, shelves, tokens Kobo y configuración del servidor; el `.env` es texto plano que se versiona en git **sin** valores reales (solo `.env.example`). No se duplica config en el backup.

> **Por qué no hay secretos de usuarios en `.env`**: Calibre-Web no lee credenciales de variables de entorno. El password del admin se cambia desde la UI tras el primer login (formulario "Change Password") y vive cifrado (bcrypt cost 12, default de `werkzeug.security`) en `/config/app.db` (tabla `user`, columna `password`). Los SMTP App Passwords para Send-to-Kindle se configuran **por usuario** en `/me` y viven cifrados con la `SECRET_KEY` que Calibre-Web genera en el primer arranque (también en `app.db`).

> **Por qué `OAUTHLIB_RELAX_TOKEN_SCOPE=1`**: si el operador habilita en algún momento OAuth con Google o Authelia (§12.4), el provider puede devolver el `scope` en otro orden o con menos elementos de los pedidos. Sin esta variable, `requests_oauthlib` levanta un `Warning: Scope has changed` que en algunas versiones se convierte en error. La variable es benigna si OAuth nunca se activa.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
sudo install -d -o homelab -g homelab -m 750 ~/homelab/stacks/calibre-web
```

### 3.2. Crear el árbol de datos persistentes del servicio

```bash
# Datos vivos del contenedor.
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/calibre-web

# Subdirectorios respaldables (config) y regenerables (cache).
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/calibre-web/config \
  /mnt/hd2t/services/calibre-web/cache
```

### 3.3. Asegurar que la biblioteca de Calibre existe

La carpeta `/mnt/hd2t/media/books/` debe existir con permisos `homelab:media 2775` desde [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6:

```bash
ls -ld /mnt/hd2t/media /mnt/hd2t/media/books
# Esperado:
# drwxrwsr-x ... homelab media ... /mnt/hd2t/media
# drwxrwsr-x ... homelab media ... /mnt/hd2t/media/books

# El usuario homelab pertenece al grupo media.
id homelab | tr ',' '\n' | grep media
# Esperado: ...,1100(media),...
```

Si la carpeta **no existe** o no tiene un `metadata.db`, hay tres vías para inicializarla:

**Vía A — Importar una biblioteca de Calibre Desktop (recomendado si ya hay biblioteca en otro equipo)**:

```bash
# Desde el equipo de origen (Mac/Linux/Windows con Calibre Desktop):
# 1. Cerrar Calibre Desktop (asegura que metadata.db no esté bloqueada).
# 2. rsync de toda la biblioteca (ej. ~/Calibre Library/) a /mnt/hd2t/media/books/.
rsync -aH --delete \
  --info=progress2 \
  ~/Calibre\ Library/ \
  homelab@pi.lan:/mnt/hd2t/media/books/

# 3. En la Pi, fijar permisos correctos.
sudo chown -R homelab:media /mnt/hd2t/media/books
sudo find /mnt/hd2t/media/books -type d -exec chmod 2775 {} \;
sudo find /mnt/hd2t/media/books -type f -exec chmod 0664 {} \;

# 4. Verificar que metadata.db es accesible.
sudo -u homelab sqlite3 /mnt/hd2t/media/books/metadata.db \
  'SELECT COUNT(*) FROM books;'
# Esperado: número entero (cantidad de libros importados).
```

**Vía B — Crear una biblioteca vacía con `calibredb`** (requiere `DOCKER_MODS=linuxserver/mods:universal-calibre` activo en este primer arranque; ver §12.5):

```bash
# Tras el primer up con DOCKER_MODS:
docker exec -u 1000:1100 calibre-web sh -c \
  'mkdir -p /books && calibredb --library-path=/books add --empty'
# Calibre crea /books/metadata.db vacío con la estructura mínima.
```

**Vía C — Descargar la biblioteca de demo del repo**:

```bash
# Solo recomendado para una primera prueba — sustituir luego por la
# biblioteca real.
wget https://github.com/janeczku/calibre-web/raw/master/library/metadata.db \
  -O /mnt/hd2t/media/books/metadata.db
sudo chown homelab:media /mnt/hd2t/media/books/metadata.db
sudo chmod 0664 /mnt/hd2t/media/books/metadata.db
```

### 3.4. Tabla resumen de permisos

| Ruta | Modo | Owner | Quién escribe | Por qué |
|---|---|---|---|---|
| `/mnt/hd2t/services/calibre-web/` | `750 homelab:homelab` | homelab (Compose) | Solo el operador desde el host | Patrón canónico. Solo `homelab` ve el contenido. |
| `/mnt/hd2t/services/calibre-web/config/` | `750 homelab:homelab` (preexiste, lo rellena CW) | Proceso CW (PUID 1000) | Materializa `app.db`, `gdrive.db` (si OAuth Google), `client_secrets.json`, `cps.log`, `gunicorn.log`, `dirs.json`. **Respaldable** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6). |
| `/mnt/hd2t/services/calibre-web/cache/` | `750 homelab:homelab` | Proceso CW (PUID 1000) | KEPUBs convertidos por `kepubify` para Kobo Sync (`kepubify/<bookId>/<book>.kepub.epub`), thumbnails redimensionados de portadas. **Excluido** del backup. Mapeado a `/config/.cache` dentro del contenedor (§4). |
| `/mnt/hd2t/media/books/` | `2775 homelab:media` | Proceso CW (PUID 1000) y operador (rsync, Calibre Desktop) | CW edita `metadata.db`, añade ficheros (uploads), borra (delete). El operador puede sincronizar manualmente desde un equipo con Calibre. **Coordinar**: no escribir simultáneamente. |
| `/mnt/hd2t/media/books/metadata.db` | `0664 homelab:media` | Calibre-Web + Calibre Desktop (uno cada vez) | BD de la **biblioteca**. Distinta de `/config/app.db`. Crítica e irreemplazable. **Respaldable** dentro del repo principal de Borg. |

### 3.5. Permisos para el proceso del contenedor

La imagen `lscr.io/linuxserver/calibre-web` corre por defecto como `abc:abc` (UID 911 internamente) y baja a `PUID:PGID` en el entrypoint (s6-overlay hace un `chown -R` y `lchown` recursivo del primer arranque). El homelab pasa `PUID=1000` y `PGID=1100` por entorno. Resultado:

- Garantiza que los ficheros bajo `/config` aparezcan como `homelab:homelab` en el host (porque el bind mount es `homelab:homelab 750`).
- Garantiza que los ficheros bajo `/books` aparezcan como `homelab:media` (porque el bind mount es `homelab:media 2775` con `setgid`).
- Permite leer y escribir en la biblioteca porque el GID 1100 está en el ACL implícito del directorio padre.
- Mantiene la coherencia con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.2 ("Servicios multimedia añaden `PGID=1100`").

> **Atención**: si Calibre-Web se levantó alguna vez sin `PUID/PGID` (ejecuciones de prueba), `config/app.db` puede haber quedado como `abc:abc` (911). Corrección: `sudo chown -R 1000:1000 /mnt/hd2t/services/calibre-web/{config,cache}` antes del primer `up` formal.

> **Atención 2**: el primer `chown -R` del entrypoint de LSIO sobre `/books` puede tardar **minutos** si la biblioteca tiene miles de libros. Si no se quiere, se puede deshabilitar con la variable `DISABLE_CHOWN=true` desde versiones recientes de la base imagen LSIO — pero entonces el operador es responsable de que los permisos ya estén correctos (ver §3.3 "Vía A" paso 3, que ya los fija).

---

## 4. `docker-compose.yml`

`~/homelab/stacks/calibre-web/docker-compose.yml`:

```yaml
# ~/homelab/stacks/calibre-web/docker-compose.yml
# Stack: calibre-web (servidor web de biblioteca de ebooks, Fase 9).
# Datos en /mnt/hd2t/services/calibre-web/.
# Biblioteca en /mnt/hd2t/media/books/ (RW — CW es coautor).

name: calibre-web

services:
  calibre-web:
    image: lscr.io/linuxserver/calibre-web:${CW_IMAGE_TAG}
    container_name: calibre-web
    hostname: calibre-web
    restart: unless-stopped
    env_file: /mnt/hd2t/services/calibre-web/.env

    environment:
      # PUID 1000 (homelab), PGID 1100 (media). La imagen LSIO respeta
      # estas variables y baja el proceso a ese UID/GID en el entrypoint.
      PUID: ${HOMELAB_UID}
      PGID: ${MEDIA_GID}
      TZ: ${TZ}
      # DOCKER_MODS: vacío por defecto (imagen slim sin binarios Calibre).
      # Para activar conversión, fijar en .env (§12.5).
      DOCKER_MODS: ${DOCKER_MODS}
      # Relaja la validación de scope OAuth para Google/Authelia (§2.3).
      OAUTHLIB_RELAX_TOKEN_SCOPE: ${OAUTHLIB_RELAX_TOKEN_SCOPE}

    volumes:
      # BD app.db + secretos. Respaldable.
      - /mnt/hd2t/services/calibre-web/config:/config
      # Cache de KEPUBs y thumbnails. NO respaldable.
      # Se monta sobre /config/.cache para "secuestrar" el subdir que
      # Calibre-Web (kepubify) escribiría dentro de /config.
      - /mnt/hd2t/services/calibre-web/cache:/config/.cache
      # Biblioteca de Calibre: RW. CW edita metadata.db y añade ficheros.
      - /mnt/hd2t/media/books:/books
      # TZ y reloj sincronizados con el host.
      - /etc/localtime:/etc/localtime:ro

    # Sin `ports:` — Calibre-Web solo es accesible vía Caddy por la red `homelab`.
    networks:
      - homelab

    # Recursos: CW slim arranca con ~80 MB y rara vez supera 200 MB en
    # uso normal (Flask + SQLite + lectura de metadata.db). Con
    # DOCKER_MODS y un Convert grande (PDF de 200 MB → EPUB), el RSS
    # puede saltar a 1 GB temporalmente. Limitar evita OOM en el host.
    mem_limit: 1500m
    mem_reservation: 128m

    # Healthcheck: GET / devuelve 200 (página de login) si el listener
    # HTTP está vivo. CW arranca en ~5–15s (init de la BD SQLite y
    # validación de la biblioteca).
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:8083"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

    # security_opt: igual que el resto del homelab (../02-docker/02-estructura-compose.md §0).
    security_opt:
      - no-new-privileges:true

    labels:
      # Watchtower: actualizar automáticamente — CW migra schema con
      # flask-migrate de forma idempotente y publica releases con changelog.
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
| `name: calibre-web` | Nombre del proyecto Compose. Aunque [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §1.1 agrupa Calibre-Web bajo el stack `media`, en la práctica cada servicio multimedia tiene su propio stack folder (igual que Jellyfin, Navidrome, Audiobookshelf) — un `down` afecta solo a CW. |
| `image: lscr.io/linuxserver/calibre-web:${CW_IMAGE_TAG}` | Tag pinned vía `.env`. La imagen LSIO vive en LinuxServer Container Registry. |
| `container_name: calibre-web` / `hostname: calibre-web` | Nombre estable para que Caddy llegue por DNS (`reverse_proxy http://calibre-web:8083`). Sin esto, Compose le pone un nombre tipo `calibre-web-calibre-web-1` y rompe el DNS interno. |
| `env_file: /mnt/hd2t/services/calibre-web/.env` | Carga de variables — patrón estándar del homelab. |
| `environment.PUID` / `PGID` | UID 1000 (escribe en `/config`), GID 1100 (lee y escribe en `/books` con `setgid` heredado). |
| `environment.TZ` | CW loguea timestamps en zona local. |
| `environment.DOCKER_MODS` | Vacío por defecto. Cambiar en `.env` para activar binarios Calibre (§12.5). |
| `environment.OAUTHLIB_RELAX_TOKEN_SCOPE: 1` | Hace OAuth tolerante con providers que reordenan scopes (§2.3). |
| `volumes: /mnt/hd2t/services/calibre-web/config:/config` | Bind mount canónico de la BD. Sin `:Z`/`:z` (no SELinux en Pi OS). |
| `volumes: /mnt/hd2t/services/calibre-web/cache:/config/.cache` | **Truco clave**: la imagen LSIO escribe el cache de `kepubify` en `/config/.cache/kepubify/` y los thumbnails redimensionados en `/config/.cache/cover_cache/`. Al montar un bind sobre `/config/.cache` "secuestramos" el subdirectorio para excluirlo del backup sin tocar el código de CW. La política de [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6 lista `/mnt/hd2t/services/calibre-web/cache` como exclusión. |
| `volumes: /mnt/hd2t/media/books:/books` | **Read-write** porque CW edita `metadata.db` y permite uploads. Diferencia clave con Jellyfin/Audiobookshelf. |
| `volumes: /etc/localtime:ro` | Sincroniza la zona del host con el contenedor — backup ante un usuario que olvide poner `TZ` en `.env`. |
| `networks: [homelab]` | Solo la red compartida. Caddy ya está ahí. |
| `mem_limit: 1500m` | CW slim apenas usa 200 MB; con DOCKER_MODS y un Convert grande puede saltar a 1 GB. 1.5 GB de tope deja margen sin pegarse con el resto. |
| `mem_reservation: 128m` | Garantía mínima en presión de memoria. CW arranca con ~80 MB. |
| `healthcheck` con `GET /` | CW no expone un endpoint específico de health; la raíz devuelve 200 (formulario de login) si el listener HTTP está vivo y `app.db` está abierta. `start_period: 60s` cubre el `chown -R` del entrypoint LSIO sobre `/books` con bibliotecas medianas. |
| `security_opt: no-new-privileges:true` | Patrón base ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §0). |
| `com.centurylinklabs.watchtower.enable: "true"` | Watchtower opt-in en el homelab ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2). CW está en la lista de servicios "stateless o de lectura ligera" que se actualizan auto. |
| `dev.dozzle.group: "media"` | Cuando Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)) levante, agrupa Jellyfin, Navidrome, Audiobookshelf y Calibre-Web bajo el mismo grupo "media". |
| `networks.homelab.external: true` | Patrón de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.4: la red se crea **una vez** durante el bootstrap. |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/calibre-web
docker compose --env-file /mnt/hd2t/services/calibre-web/.env config

# Esperado: salida YAML resuelta sin warnings.
# - El `image` debe estar plenamente cualificado: lscr.io/linuxserver/calibre-web:0.6.24
# - PUID=1000, PGID=1100 (no comillas vacías ni `null`).
# - Sin warning "variable X not set".
# - `volumes` con paths absolutos.
# - El bind de /books SIN `read_only: true`.
# - El bind /config/.cache montado por encima de /config (orden correcto).
```

---

## 5. Despliegue

### 5.1. Levantar el stack

```bash
cd ~/homelab/stacks/calibre-web
docker compose --env-file /mnt/hd2t/services/calibre-web/.env up -d
```

El primer `up` tarda **~30–90 segundos** según el tamaño de la biblioteca:

1. Descarga la imagen (~210 MB en arm64 — slim sin DOCKER_MODS; ~1.7 GB con `universal-calibre`).
2. El entrypoint s6 hace `chown -R PUID:PGID` sobre `/config` y `/books` (con biblioteca de 5 000 libros y disco USB tarda 30–60 s).
3. Inicializa el schema SQLite en `/config/app.db` (migrations vía `flask-migrate`).
4. Levanta el HTTP listener en `:8083`.

### 5.2. Estado de los contenedores

```bash
docker compose --env-file /mnt/hd2t/services/calibre-web/.env ps

# Esperado, tras ~60 segundos:
# NAME           IMAGE                                       STATUS                 PORTS
# calibre-web    lscr.io/linuxserver/calibre-web:0.6.24      Up X (healthy)
```

Si tras 3 minutos el estado sigue siendo `(starting)`:

```bash
docker compose --env-file /mnt/hd2t/services/calibre-web/.env logs --tail=200 calibre-web

# Buscar líneas tipo:
# - "[ls.io-init] done": entrypoint LSIO terminó.
# - "Booting worker with pid": Gunicorn arrancó.
# - "Starting Gunicorn": HTTP listo.
# - "EACCES: permission denied, open '/config/app.db'": revisar PUID/PGID y permisos del bind mount.
# - "no such file or directory: /books/metadata.db": revisar §3.3 (la biblioteca debe existir).
# - "OperationalError: unable to open database file": permisos del metadata.db.
```

### 5.3. Onboarding inicial (login + cambio de password + path a la biblioteca)

Calibre-Web expone su UI en `http://calibre-web:8083` (red `homelab`). Caddy aún no lo enruta hasta §6. Para el primer onboarding, dos opciones:

**Opción A — Vía Caddy (preferida)**: completar §6 antes de lanzar el formulario. Abrir `https://calibre.lan` desde un navegador del LAN.

**Opción B — `docker exec` para validar**:

```bash
# Verificar que CW responde dentro del contenedor.
docker exec calibre-web wget -qO- http://localhost:8083 | head -c 200
# Esperado: HTML del formulario de login (`<form action="/login" ...>`).
```

> En la práctica el flujo recomendado es **Opción A**: completar §6, abrir `https://calibre.lan`, hacer login.

El primer login se hace con las **credenciales por defecto**:

- **Usuario**: `admin`
- **Password**: `admin123`

**Acción inmediata e ineludible** tras el login:

1. **Click en el icono de usuario (esquina superior derecha) > "User Profile"**.
2. **Cambiar el password** a uno propio (≥ 16 caracteres, gestionado en Vaultwarden cuando esté desplegado).
3. (Opcional) cambiar el username de `admin` a algo menos predecible.

> **Sin este paso, el homelab está abierto a cualquiera que llegue al puerto 8083** — y aunque solo Caddy llegue, una mala config de macvlan o un puerto publicado por error daría acceso. Hacerlo **siempre**, antes de cualquier otro ajuste.

**Configurar el path a la biblioteca de Calibre**:

1. **Settings (icono de tuerca) > Basic Configuration**.
2. **"Location of Calibre Database"**: `/books` (el path **dentro del contenedor**).
3. **Submit** → CW lee `/books/metadata.db`, valida el schema y muestra el catálogo.

Si la biblioteca está vacía (solo `metadata.db` sin libros), CW muestra un dashboard vacío con "No books found". Subir un EPUB de prueba desde la UI confirma que la integración funciona.

---

## 6. Integración con Caddy

### 6.1. Añadir el bloque `calibre.{$LAN_DOMAIN}` al `Caddyfile`

A diferencia de Jellyfin/Pi-hole, el `Caddyfile` del homelab ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3) **no incluye placeholder** para Calibre-Web. Editar `~/homelab/stacks/proxy/Caddyfile` y añadir:

```caddy
# Calibre-Web (../09-multimedia/04-calibre-web.md) — biblioteca de ebooks
calibre.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Subida de ebooks (PDF escaneados pueden alcanzar ~200 MB; deja
    # margen para uploads grandes con OCR + portada embebida).
    request_body {
        max_size 250MB
    }

    # Streaming de KEPUBs grandes (la conversión kepubify de un EPUB
    # de 50 MB sin flush latencia y rompe el "Sync Library" del Kobo).
    reverse_proxy http://calibre-web:8083 {
        header_up Host {host}
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
        flush_interval -1
    }
}
```

> **Sin WebSocket**: Calibre-Web **no** usa WebSocket. La sincronización Kobo es polling HTTP plano cada vez que el dispositivo se conecta. No hay que añadir `header_up Connection upgrade` ni nada similar.

Y el bloque Tailscale gemelo (comentado hasta tener cert vía `tailscale cert`):

```caddy
# calibre.{$TS_DOMAIN} {
#     import tailscale_tls calibre
#     import security_headers
#     request_body {
#         max_size 250MB
#     }
#     reverse_proxy http://calibre-web:8083 {
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

### 6.2. Trusted proxies en Calibre-Web

Calibre-Web confía en `X-Forwarded-For` solo si el operador habilita explícitamente "Reverse Proxy Login Header Name" (§12.4). Mientras no esté activo, el log de CW muestra la IP de Caddy (`172.20.0.X`), no la del cliente real. Es **cosmético** para el log y para el campo "Last Login" del usuario; no afecta a la seguridad.

Si se quiere la IP real en el log sin SSO completo:

```yaml
# Añadir en environment del docker-compose.yml:
environment:
  TRUSTED_PROXIES: 172.20.0.0/24
```

CW interpretará `X-Forwarded-For` enviado por Caddy y lo loggueará. **Solo activar** si Caddy está delante (de lo contrario, un cliente puede falsificar la cabecera).

### 6.3. Registro DNS local en Pi-hole

Pi-hole resuelve `calibre.lan` → IP de la Pi. Esto ya estaba descrito conceptualmente en [`../03-red/02-pihole.md`](../03-red/02-pihole.md) §7.

```bash
# Vía la UI de Pi-hole (preferido):
# 1. Abrir https://pihole.lan/admin/
# 2. "Local DNS > DNS Records"
# 3. Domain: calibre.lan
#    IP:     192.168.1.10  (la IP estática de la Pi en LAN)
# 4. "Add"
```

Verificar:

```bash
dig +short @192.168.1.2 calibre.lan
# Esperado: 192.168.1.10
```

### 6.4. Probar el acceso

```bash
# Desde el host (red homelab interna):
docker exec caddy wget -qO- -S http://calibre-web:8083 2>&1 | head -10
# Esperado: HTTP/1.1 200 OK + HTML del login.

# Desde la LAN (validar TLS):
curl -fsS https://calibre.lan/login -o /dev/null -w "%{http_code}\n"
# Esperado: 200
# El cert es de la CA interna de Caddy ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §3.4);
# el navegador puede protestar. Solución: instalar el root cert de Caddy.

# OPDS feed (requiere Basic Auth):
curl -fsS -u admin:<password> https://calibre.lan/opds | head -20
# Esperado: <feed xmlns="http://www.w3.org/2005/Atom" ...>
#   <title>Calibre-Web</title> ...

# Desde el navegador:
# https://calibre.lan → login (admin / admin123 en el primer arranque, §5.3).
```

### 6.5. (No por defecto) Proteger con Authelia

**El homelab no pone Authelia delante de Calibre-Web por defecto** — explicado en §0 fila "Reverse proxy" y desarrollado en §12.4. La razón en una línea: los lectores OPDS y Kobo Sync envían `Authorization: Basic <user:pass>` o `Authorization: Bearer <kobo-token>` directamente, sin cookie SSO; un `forward_auth` con Authelia las rechazaría con 401 antes de que el header llegara al backend.

La vía correcta para SSO **manteniendo OPDS y Kobo** es **Reverse Proxy Login Header** (Calibre-Web nativo, sin `forward_auth` en Caddy) — Calibre-Web confía en una cabecera HTTP firmada por Caddy/Authelia que solo afecta a la **UI web** (`/login`, `/`, `/book/<id>`); las rutas `/opds` y `/kobo/<token>/...` siguen usando Basic/Bearer respectivamente. Ver §12.4.

---

## 7. Configuración post-despliegue

### 7.1. Ajustes básicos del servidor

**Settings (tuerca) > Basic Configuration**:

| Campo | Valor recomendado | Por qué |
|---|---|---|
| Location of Calibre Database | `/books` | Path **dentro del contenedor**. Ya lo cubre §5.3. |
| Calibre Library Compatibility Issues | (sin marcar) | Solo activar si la biblioteca viene de Calibre Desktop ≥ 7.x con campos custom incompatibles. |
| Log Level | `INFO` | `DEBUG` llena `cps.log` rápido con cada request. |
| Server Port (External) | (vacío) | CW solo escucha en interno. Caddy hace el SSL termination. |
| Update Channel | `Stable` | El canal `Nightly` corresponde al `master` upstream — para early adopters únicamente. |
| Reverse Proxy Login Header Name | (vacío de momento) | Solo activar si se hace §12.4 (SSO con Authelia). |

**Settings > UI Configuration**:

| Campo | Valor recomendado | Por qué |
|---|---|---|
| Read-Only | (sin marcar) | Solo activar si el operador quiere bloquear edits desde la UI (los uploads, conversiones y ediciones de metadata se deshabilitan). |
| Allow Anonymous Read | (sin marcar) | Forzar login. |
| Allow public registration | (sin marcar) | Los usuarios los crea el admin manualmente — el homelab no tiene "registro público". |
| Default Visibility | "Logged in only" | Coherente con "Allow Anonymous Read = false". |
| Books per page | `48` | Balance entre carga de página y scroll. |
| Theme | "Caliblur (dark)" | Preferencia personal — la opción `Standard (light)` también está. |
| Magic Link Login | (sin marcar) | Send-to-Email para login sin password — solo activar si Send-to-Kindle SMTP funciona. |

### 7.2. Crear los usuarios secundarios (familia)

**Admin (icono de usuario) > Admin Settings > +**:

| Usuario | Tipo | Notas |
|---|---|---|
| `admin` (creado en §5.3) | Admin | Acceso completo. |
| `family` | User | Puede leer todos los libros, crear shelves privadas, marcar progreso. **No** ve "Admin Settings". |
| `kids` (opcional) | User | Restricciones: solo libros con tag "Kids" visibles, sin permiso de upload, sin Send-to-Kindle. |

**Permisos por usuario** (CW soporta granularidad por dominio):

- **Admin Settings > Edit User > `<user>` > Permissions**:
    - `Admin`: marca al usuario como admin.
    - `Download`: permite descargar el fichero original (deshabilitar para `kids` si la idea es que solo lean en línea).
    - `Upload`: permite subir libros nuevos (deshabilitar para `kids`).
    - `Edit Books`: permite cambiar metadatos.
    - `Delete Books`: permite borrar (cuidado — borra del filesystem también).
    - `View Books`: filtros por idioma, tags incluidos/excluidos, custom columns.

- **"Visible Tags / Hidden Tags"**: para `kids`, marcar como visible solo `Infantil` o lo que se prefiera.

### 7.3. Configurar Send-to-Kindle (SMTP)

**Admin Settings > Edit Email Server Settings**:

| Campo | Valor de ejemplo (Gmail) |
|---|---|
| SMTP Hostname | `smtp.gmail.com` |
| SMTP Port | `587` |
| Encryption | `STARTTLS` |
| SMTP Username | `tu-cuenta@gmail.com` |
| SMTP Password | App Password de 16 chars (generar en https://myaccount.google.com/apppasswords) |
| From E-Mail | `tu-cuenta@gmail.com` |
| Attachment Size Limit | `20 MB` (Gmail no permite adjuntos > 25 MB) |

> **Por qué App Password y no el password normal**: Google bloquea desde 2022 los logins SMTP "less secure". El App Password es un token específico de aplicación, separado de la contraseña principal. Equivalentes en otros providers:
> - **Fastmail**: Settings > Privacy & Security > "App Passwords" → "Create new" con scope SMTP.
> - **iCloud**: Settings > Sign-In & Security > "App-Specific Passwords".
> - **Outlook/Microsoft 365**: requiere licencia E5 o "Modern Auth" con OAuth — mejor usar un proveedor SMTP dedicado (Mailgun, SendGrid free tier).

**Por usuario** (cada uno apunta a su propio Kindle):

- **User Profile (icono de usuario) > Kindle E-Mail**: `<usuario>@kindle.com`.
- En la cuenta Amazon del usuario: **"Manage Your Content and Devices" > Preferences > Personal Document Settings > "Approved Personal Document E-mail List"**: añadir la dirección de `From E-Mail` (la del SMTP del homelab) — sin esto, Amazon rechaza los adjuntos.

**Probar**: abrir un libro > "Send to Kindle". CW envía el EPUB (o lo convierte a AZW3 si DOCKER_MODS está activo, §12.5) y debería aparecer en el Kindle del usuario en 1–10 minutos.

### 7.4. Configurar Kobo Sync

Kobo Sync replica una experiencia de "biblioteca en la nube" para Kobo: sincroniza shelves, marca de lectura y progreso bidireccionales, y envía los KEPUBs a la tienda interna del Kobo.

1. **Admin Settings > Feature Configuration > Kobo Sync**: marcar "Enable Kobo sync support".
2. **Por usuario, generar el authToken**:
    - User Profile > "Kobo Sync token" > "Generate" → CW genera un token UUID y lo asocia al usuario.
3. **En el Kobo** (vía USB o desde la home network):
    - Editar `Kobo/Kobo eReader.conf` (raíz del Kobo cuando está conectado por USB).
    - Cambiar `api_endpoint=https://storeapi.kobo.com` por:
      ```
      api_endpoint=https://calibre.lan/kobo/<authToken>
      ```
      (sustituir `<authToken>` por el generado en el paso anterior).
    - Guardar y desconectar. El Kobo, en el próximo "Sync Library", consultará a Calibre-Web y descargará los libros visibles para el usuario.

> **Por qué KEPUB y no EPUB**: Kobo lee EPUB pero su feature "Reading Statistics" (palabras leídas, tiempo restante por capítulo) solo funciona con KEPUB (variante con metadatos por frase añadidos por `kepubify`). CW convierte EPUB → KEPUB on-demand y cachea el resultado en `/config/.cache/kepubify/<bookId>/`. Sin DOCKER_MODS, `kepubify` **no está disponible** y CW sirve EPUB directamente — sigue funcionando, solo se pierden las stats.

### 7.5. Reescaneo y sincronización con la biblioteca

Calibre-Web no monitoriza el filesystem en tiempo real: confía en que cualquier cambio en la biblioteca venga desde la propia UI. Pero si el operador usa rsync/Syncthing/Calibre Desktop para añadir libros directamente:

- **Admin Settings > Database Configuration > "Recalculate Hot/New books"**: actualiza los contadores y el feed de novedades.
- **Admin Settings > Reconnect Database**: re-abre `metadata.db` desde el filesystem (necesario tras un rsync que reemplace el fichero por completo).
- Si la `metadata.db` cambió en disco mientras CW estaba abierta, hacer:

  ```bash
  docker compose --env-file /mnt/hd2t/services/calibre-web/.env restart calibre-web
  ```

  Es la vía más fiable.

### 7.6. Backups automáticos internos (no aplica)

A diferencia de Audiobookshelf, Calibre-Web **no** tiene un sistema de backup interno propio. Todo el backup va por Borgmatic (§9). El operador puede, manualmente, exportar los datos:

```bash
# Dump consistente de app.db (sin parar CW).
docker exec calibre-web sqlite3 /config/app.db ".backup /config/app.db.bak"

# Dump de metadata.db (parar CW antes — calibredb usa locks fuertes):
docker compose --env-file /mnt/hd2t/services/calibre-web/.env stop calibre-web
sqlite3 /mnt/hd2t/media/books/metadata.db ".backup /mnt/hd2t/media/books/metadata.db.bak"
docker compose --env-file /mnt/hd2t/services/calibre-web/.env start calibre-web
```

Borgmatic ya ejecuta el equivalente con `VACUUM INTO` en su hook `before_backup` para `app.db` y `metadata.db` (§9.2).

---

## 8. Verificación

### 8.1. Contenedor sano

```bash
docker compose --env-file /mnt/hd2t/services/calibre-web/.env ps
# Esperado: Up X (healthy)

docker inspect calibre-web --format '{{.State.Health.Status}}'
# Esperado: healthy
```

### 8.2. Calibre-Web escucha solo dentro de la red `homelab`

```bash
# Desde el host: el puerto 8083 del contenedor NO debe responder.
ss -tlnp | grep ":8083 "
# Esperado: vacío (Caddy escucha en :443, no en :8083; el :8083 de CW es interno).

# Desde dentro de la red homelab sí debe responder.
docker exec caddy wget -qO- http://calibre-web:8083 -O - -S 2>&1 | head -5
# Esperado: HTTP/1.1 200 OK
```

### 8.3. Biblioteca montada y leída

```bash
docker exec calibre-web ls -la /books | head
# Esperado: metadata.db visible + carpetas de autores.

# Test escritura en /books (debería FUNCIONAR — RW):
docker exec calibre-web sh -c 'touch /books/.test_write && rm /books/.test_write && echo OK'
# Esperado: OK

# Conteo de libros desde fuera del contenedor.
sqlite3 /mnt/hd2t/media/books/metadata.db 'SELECT COUNT(*) FROM books;'
# Esperado: número entero ≥ 0.
```

### 8.4. UI web operativa

```bash
# Probar que el formulario de login responde.
curl -fsS https://calibre.lan/login | grep -o '<title>[^<]*</title>'
# Esperado: <title>Calibre-Web | Login</title>

# Login + obtener cookie de sesión.
curl -c /tmp/cw-cookies -fsS -X POST https://calibre.lan/login \
  -d 'username=admin&password=<password>&submit=Login&next=%2F' \
  -o /dev/null -w "%{http_code}\n"
# Esperado: 200 (o 302 si redirige al dashboard).

# Acceder al dashboard con la cookie.
curl -b /tmp/cw-cookies -fsS https://calibre.lan/ | grep -o '<title>[^<]*</title>'
# Esperado: <title>Calibre-Web</title>
rm /tmp/cw-cookies
```

### 8.5. OPDS feed operativo

```bash
# El OPDS feed requiere Basic Auth.
curl -fsS -u admin:<password> https://calibre.lan/opds | head -20
# Esperado:
# <?xml version="1.0" encoding="UTF-8"?>
# <feed xmlns="http://www.w3.org/2005/Atom" ...>
#   <id>...</id>
#   <title>Calibre-Web</title>
#   ...

# El feed de "Latest books".
curl -fsS -u admin:<password> https://calibre.lan/opds/new | head -20
# Esperado: feed Atom con los últimos libros añadidos.
```

### 8.6. Kobo Sync (si configurado, §7.4)

```bash
# El authToken se ve en la UI > User Profile > Kobo Sync token.
TOKEN=<authToken>
curl -fsS https://calibre.lan/kobo/$TOKEN/v1/auth/device | head -c 300
# Esperado: JSON con "AccessToken", "RefreshToken", "TrackingId" — emulando la API oficial Kobo.
```

### 8.7. Smoke test desde el navegador

1. `https://calibre.lan` carga el login.
2. Login con `admin` exitoso.
3. El dashboard muestra "Latest Books", "Hot Books", "Discover" (vacíos si la biblioteca es nueva).
4. Click en un libro: la página de detalle muestra cover, descripción, formatos disponibles.
5. Click en "Read in Browser" (si EPUB/PDF): el visor `epub.js` carga el libro en línea.
6. Click en "Download": el fichero se descarga.
7. Si Send-to-Kindle configurado (§7.3): Click "Send to Kindle" → el adjunto llega al Kindle en 1–10 min.
8. Si Kobo Sync configurado (§7.4): el Kobo, al hacer "Sync Library", baja al menos un libro nuevo.

### 8.8. Persistencia tras reboot

```bash
sudo reboot
# Esperar ~2 min.
ssh homelab@pi.lan
docker compose --env-file /mnt/hd2t/services/calibre-web/.env -f ~/homelab/stacks/calibre-web/docker-compose.yml ps
# Esperado: calibre-web Up X (healthy) — restart: unless-stopped lo trae solo.
```

### 8.9. Lista de verificación

- [ ] `docker compose ... ps` muestra `Up X (healthy)`.
- [ ] `docker inspect calibre-web --format '{{.State.Health.Status}}'` = `healthy`.
- [ ] `ss -tlnp | grep ":8083 "` no devuelve nada del contenedor (no hay puerto publicado).
- [ ] `curl -fsS https://calibre.lan/login` devuelve HTTP 200 con el formulario.
- [ ] `docker exec calibre-web sh -c 'touch /books/.test && rm /books/.test'` funciona (RW).
- [ ] `sqlite3 /mnt/hd2t/media/books/metadata.db 'SELECT COUNT(*) FROM books'` devuelve un número (BD válida).
- [ ] Login en `https://calibre.lan` con cuenta admin (password CAMBIADO desde `admin123`) OK.
- [ ] OPDS responde a `GET /opds` con Basic Auth devolviendo XML Atom.
- [ ] Reading test: abrir un libro EPUB en el visor en línea funciona en < 5 s.
- [ ] Si Send-to-Kindle: el adjunto llega al Kindle.
- [ ] Si Kobo Sync: `GET /kobo/<token>/v1/auth/device` devuelve JSON.
- [ ] Tras `sudo reboot`, CW vuelve a estar `(healthy)` en menos de 2 minutos.
- [ ] Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6) lista `/mnt/hd2t/services/calibre-web/config/` y `/mnt/hd2t/media/books/` en el archivo y **no** lista `/mnt/hd2t/services/calibre-web/cache/`.

---

## 9. Backup

### 9.1. Qué se respalda y qué no

| Ruta | Backup | Justificación |
|---|---|---|
| `/mnt/hd2t/services/calibre-web/config/` | **Sí** (Borgmatic, [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6) | Contiene `app.db` (usuarios, shelves, tokens Kobo, configuración del servidor, `SECRET_KEY`, OAuth client secrets cifrados con `SECRET_KEY`), `cps.log`, `gunicorn.log`, `dirs.json`. ~5–20 MB. |
| `/mnt/hd2t/services/calibre-web/cache/` | **No** | KEPUBs convertidos por `kepubify` (regenerable on-demand desde EPUB), thumbnails redimensionados (regenerable). Puede crecer a 200 MB+ con biblioteca grande. |
| `/mnt/hd2t/media/books/metadata.db` | **Sí** | BD de la **biblioteca** (curada a mano: tags, series, descripciones editadas, custom columns). Irreemplazable salvo "rehacer todo el curado". El hook §9.2 hace `VACUUM INTO` para snapshot consistente. |
| `/mnt/hd2t/media/books/Autor/Título (id)/<libro>.<formato>` | **Sí** | Los ficheros originales (EPUB/PDF/MOBI/AZW3). Pueden ser compras propias (Amazon, Kobo Store con Calibre + plugins de DRM removal), rips de DRM, o ebooks free de Project Gutenberg. Irreemplazables si fueron compras. |
| `/mnt/hd2t/media/books/Autor/Título (id)/cover.jpg` | **Sí** | Las portadas embebidas en el EPUB se pueden regenerar; las portadas custom (subidas a mano por el operador) no. Por simplicidad, todo el árbol entra en backup. |
| `/mnt/hd2t/media/books/Autor/Título (id)/metadata.opf` | **Sí** | Backup redundante del registro en `metadata.db`. Calibre los mantiene como fuente alternativa. Útil si `metadata.db` se corrompe. |

### 9.2. Política Borgmatic

`~/homelab/stacks/backup/config/borgmatic.d/calibre-web.yaml` (extendiendo el doc principal):

```yaml
# Cubierto en ../07-backups/02-borgmatic.md §13.6 — solo aquí como referencia.
source_directories:
  - /mnt/hd2t/services/calibre-web/config
  - /mnt/hd2t/media/books

# Hooks para snapshots consistentes de SQLite (evita races con WAL).
before_backup:
  # app.db (BD de Calibre-Web — usuarios, shelves).
  - sqlite3 /mnt/hd2t/services/calibre-web/config/app.db "VACUUM INTO '/mnt/hd2t/services/calibre-web/config/app.db.bak'"
  # metadata.db (BD de la biblioteca de Calibre).
  - sqlite3 /mnt/hd2t/media/books/metadata.db "VACUUM INTO '/mnt/hd2t/media/books/metadata.db.bak'"
```

> **Por qué `VACUUM INTO`**: ambas BDs corren con WAL mode; un copiado directo del `.sqlite` sin checkpoint puede dar una BD inconsistente. `VACUUM INTO` es el método canónico de SQLite para hacer un snapshot consistente. Los snapshots quedan como `.bak` que entran en el archivo Borg natural.

### 9.3. Restore (resumen)

```bash
# 0. Asumiendo Pi recién instalada y borg/borgmatic operativo.
# 1. Recrear el árbol de directorios (§3.2).
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/calibre-web \
  /mnt/hd2t/services/calibre-web/config \
  /mnt/hd2t/services/calibre-web/cache
sudo install -d -o homelab -g media -m 2775 /mnt/hd2t/media/books

# 2. Listar archivos disponibles.
sudo borgmatic list

# 3. Extraer SOLO los datos de Calibre-Web del último archivo.
sudo borgmatic extract \
  --archive latest \
  --path mnt/hd2t/services/calibre-web/config \
  --destination /
sudo borgmatic extract \
  --archive latest \
  --path mnt/hd2t/media/books \
  --destination /

# 4. Verificar permisos.
sudo chown -R 1000:1000 /mnt/hd2t/services/calibre-web/{config,cache}
sudo chown -R 1000:1100 /mnt/hd2t/media/books
sudo find /mnt/hd2t/media/books -type d -exec chmod 2775 {} \;
sudo find /mnt/hd2t/media/books -type f -exec chmod 0664 {} \;

# 5. Levantar Calibre-Web.
cd ~/homelab/stacks/calibre-web
docker compose --env-file /mnt/hd2t/services/calibre-web/.env up -d

# 6. Validar:
# - Login con la cuenta admin (password de antes del desastre).
# - Settings > Basic Configuration > "Location of Calibre Database" sigue siendo /books.
# - Catálogo muestra los libros restaurados.
# - Si Kobo Sync: el authToken sigue válido en User Profile.
# - OPDS responde.
```

### 9.4. Smoke test mensual de restore

[`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §10 fija un drill mensual de restore. Para Calibre-Web:

```bash
# En un directorio temporal (NO sobre la instalación viva):
mkdir -p /tmp/cw-restore-test
cd /tmp/cw-restore-test

sudo borgmatic extract \
  --archive latest \
  --path mnt/hd2t/services/calibre-web/config/app.db \
  --destination .
sudo borgmatic extract \
  --archive latest \
  --path mnt/hd2t/media/books/metadata.db \
  --destination .

# Verificar que ambas BDs son válidas.
sudo apt-get install -y sqlite3  # si no está

sqlite3 ./mnt/hd2t/services/calibre-web/config/app.db \
  'SELECT name, role FROM user;'
# Esperado: lista con admin, family, kids (los creados en §7.2).

sqlite3 ./mnt/hd2t/media/books/metadata.db \
  'SELECT COUNT(*) FROM books;'
# Esperado: número entero (cantidad de libros indexados).

rm -rf /tmp/cw-restore-test
```

---

## 10. Operaciones cotidianas

### 10.1. Upgrade automático (Watchtower)

Calibre-Web lleva `com.centurylinklabs.watchtower.enable: "true"` (§4). Watchtower comprueba a diario; cuando hay un nuevo digest del tag pinned, hace `pull` + `up -d`. **Pero**: como el tag está pinned a `0.6.24`, Watchtower no actualiza versiones nuevas a no ser que el operador edite `.env`.

**Upgrade manual de versión** (cambio de tag, p. ej. 0.6.24 → 0.6.25):

```bash
# 1. Leer las release notes: https://github.com/janeczku/calibre-web/releases.
#    Buscar "Breaking changes" y "Database migrations".

# 2. Editar /mnt/hd2t/services/calibre-web/.env:
sed -i 's/^CW_IMAGE_TAG=.*/CW_IMAGE_TAG=0.6.25/' \
  /mnt/hd2t/services/calibre-web/.env

# 3. Backup ad-hoc del config + biblioteca ANTES.
sudo borgmatic create --verbosity 1

# 4. Pull + recrear.
cd ~/homelab/stacks/calibre-web
docker compose --env-file /mnt/hd2t/services/calibre-web/.env pull calibre-web
docker compose --env-file /mnt/hd2t/services/calibre-web/.env up -d

# 5. Vigilar el primer arranque tras upgrade (la BD migra schema).
docker compose --env-file /mnt/hd2t/services/calibre-web/.env logs -f calibre-web

# Esperado:
# - "Calibre-Web v0.6.25"
# - "[INFO] flask-migrate: applying migration <name>" si toca migrar schema.
# - "[INFO] Booting Gunicorn on port 8083"

# 6. Smoke test: login + abrir un libro + send-to-Kindle.

# 7. Si algo se rompe: rollback.
sed -i 's/^CW_IMAGE_TAG=.*/CW_IMAGE_TAG=0.6.24/' \
  /mnt/hd2t/services/calibre-web/.env
docker compose --env-file /mnt/hd2t/services/calibre-web/.env up -d
# Si app.db ya migró a un schema más nuevo, restaurar config/ desde Borg.
```

### 10.2. Añadir libros nuevos

**Vía A — Upload por la UI (el más sencillo)**:

1. Click `+` flotante > "Add Book" > seleccionar EPUB/PDF/MOBI.
2. Calibre-Web extrae metadatos del fichero (título, autor, idioma, fecha).
3. (Opcional) Click "Edit Metadata" antes de guardar para corregir.

**Vía B — rsync / Calibre Desktop** (gestión externa de la biblioteca):

1. **Parar Calibre-Web**: `docker compose --env-file /mnt/hd2t/services/calibre-web/.env stop calibre-web`.
2. Abrir Calibre Desktop apuntando a `/mnt/hd2t/media/books` (vía Samba o VPN al equipo).
3. Añadir libros con la UI de Calibre.
4. Cerrar Calibre Desktop (libera el lock de `metadata.db`).
5. **Reiniciar Calibre-Web**: `docker compose --env-file /mnt/hd2t/services/calibre-web/.env start calibre-web`.

**Vía C — `calibredb` desde el contenedor** (requiere DOCKER_MODS, §12.5):

```bash
# Copiar el ebook al host primero.
scp libro.epub homelab@pi.lan:/tmp/libro.epub

# Importar con calibredb (parar CW antes — calibredb usa locks).
docker compose --env-file /mnt/hd2t/services/calibre-web/.env stop calibre-web
docker exec -u 1000:1100 calibre-web sh -c \
  'cp /tmp/libro.epub /books/.import.epub && \
   calibredb --library-path=/books add /books/.import.epub && \
   rm /books/.import.epub'
docker compose --env-file /mnt/hd2t/services/calibre-web/.env start calibre-web
```

> **Vía D (no recomendada) — Syncthing**: si hay un Syncthing ([`../06-almacenamiento/03-syncthing.md`](../06-almacenamiento/03-syncthing.md)) sincronizando otra biblioteca, las modificaciones simultáneas en `metadata.db` desde dos lados generan conflictos (sufijos `.sync-conflict-*`) y la BD se corrompe sin remedio. Sincronizar **solo** la carpeta de libros (los EPUBs/PDFs por separado), no `metadata.db`. O dejar Syncthing como pull-only en una cara.

### 10.3. Forzar reescaneo / reconectar la BD

Tras un movimiento manual (rsync de un disco externo) o una edición externa con Calibre Desktop:

- **Admin Settings > Database Configuration > "Reconnect Database"**.
- Si no aparece o el cambio no se ve, reiniciar el contenedor: `docker compose --env-file /mnt/hd2t/services/calibre-web/.env restart calibre-web`.

### 10.4. Limpieza de cache

```bash
# Con CW corriendo es seguro — CW regenera lo necesario.
sudo find /mnt/hd2t/services/calibre-web/cache -mindepth 1 -delete

# O reiniciar el contenedor primero para liberar locks (no estrictamente necesario):
docker compose --env-file /mnt/hd2t/services/calibre-web/.env stop calibre-web
sudo find /mnt/hd2t/services/calibre-web/cache -mindepth 1 -delete
docker compose --env-file /mnt/hd2t/services/calibre-web/.env start calibre-web
```

> Tras la limpieza, la primera petición de KEPUB de cada libro del Kobo regenera el `.kepub.epub` (~1–5 s por libro en Pi 5).

### 10.5. Reset password de admin (perdido el control)

CW **no** tiene "olvidé contraseña" sin acceso al filesystem. Si se pierde el password del admin:

```bash
# Generar un hash bcrypt nuevo desde el host (CW usa werkzeug.security,
# que envuelve bcrypt o pbkdf2). El método más simple es restablecer
# directamente con un Python que use el mismo werkzeug del contenedor.

docker exec calibre-web python3 -c \
  "from werkzeug.security import generate_password_hash; \
   print(generate_password_hash('NUEVO_PASSWORD', method='pbkdf2:sha256'))"
# Salida: pbkdf2:sha256:600000$...

# Detener Calibre-Web.
docker compose --env-file /mnt/hd2t/services/calibre-web/.env stop calibre-web

# Actualizar la BD.
sudo sqlite3 /mnt/hd2t/services/calibre-web/config/app.db \
  "UPDATE user SET password='<HASH>' WHERE name='admin';"

# Levantar y entrar con el nuevo password.
docker compose --env-file /mnt/hd2t/services/calibre-web/.env up -d
```

> **Nota**: la columna se llama `password` (a diferencia de Audiobookshelf, que usa `pash`). Y CW **no** acepta hashes bcrypt directos en este campo — usa el formato envuelto de werkzeug (`pbkdf2:sha256:...`). Generar el hash desde el propio contenedor garantiza que el formato sea compatible con la versión de werkzeug del CW desplegado.

### 10.6. Logs

```bash
# Stream en vivo (vía Dozzle o `docker compose logs`).
docker compose --env-file /mnt/hd2t/services/calibre-web/.env logs -f calibre-web

# Errores recientes:
docker compose --env-file /mnt/hd2t/services/calibre-web/.env logs --tail=500 calibre-web \
  | grep -E "ERROR|WARN" | tail -30

# Logs internos persistentes en /config/:
docker exec calibre-web ls -la /config/cps.log /config/gunicorn.log
# cps.log = log de la app Flask; gunicorn.log = log del servidor WSGI.
```

Subir el loglevel a `DEBUG` puntualmente desde la UI:

- **Settings > Basic Configuration > Log Level**: `DEBUG` → Save.
- (Recordar volver a `INFO` tras la sesión de debug — el log crece rápido.)

### 10.7. Comportamiento durante mantenimiento

| Situación | Resultado | Mitigación |
|---|---|---|
| `docker compose stop calibre-web` (planificado) | UI muestra "502 Bad Gateway" desde Caddy. Lectores OPDS reciben el mismo error. Kobo en sync recibe `Connection refused` y reintenta más tarde. | Avisar 1 min antes (raramente crítico — leer es asíncrono). |
| Caddy reload | Las requests reciben `502` momentáneo (~1 segundo); CW está vivo, los clientes reintentan transparentemente. | Sin acción. |
| Pi-hole caído | `calibre.lan` no resuelve dentro del LAN. | Fallback DNS en clientes ([`../03-red/02-pihole.md`](../03-red/02-pihole.md) §10) o IP directa. |
| Disco hd2t saturado | CW no puede escribir cache, ni convertir KEPUBs, ni guardar libros nuevos. La lectura sigue funcionando. | Monitorización ([`../05-monitorizacion/02-grafana.md`](../05-monitorizacion/02-grafana.md), Node Exporter). Limpiar cache (§10.4). |
| `metadata.db` corrupto | UI rompe con "OperationalError: malformed". | Restaurar desde Borg (§9.3). Si fue un crash, `sqlite3 metadata.db ".recover" > recovered.sql && sqlite3 new.db < recovered.sql` recupera ~95 % de los registros. |

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Cómo diagnosticar | Remedio |
|---|---|---|---|
| `OperationalError: unable to open database file` al arrancar | Permisos de `/config` o `/books` mal | `docker compose logs calibre-web \| tail -50` | `chown -R 1000:1000 /mnt/hd2t/services/calibre-web/{config,cache}` y `chown -R 1000:1100 /mnt/hd2t/media/books`. |
| Login OK pero "No books found" | Path a la biblioteca mal configurado | Settings > Basic Configuration > "Location of Calibre Database" | Cambiar a `/books`. Reconnect Database. |
| OPDS devuelve 401 con cliente que dice usar credenciales correctas | El cliente envía `Authorization: Bearer ...` (no Basic) | `docker compose logs calibre-web \| grep -i auth` | Cambiar el cliente a Basic Auth. KOReader: "OPDS catalog > Edit > Basic Authentication". |
| Kobo dice "Sync failed" | `api_endpoint` mal escrito en `Kobo eReader.conf` o el authToken expiró | En el Kobo: `cat /mnt/onboard/.kobo/Kobo/Kobo\ eReader.conf` | Reescribir la URL completa con el authToken correcto (ver §7.4). |
| Kobo Sync: faltan libros | Kobo solo soporta EPUB/KEPUB/PDF/CBZ — no MOBI ni AZW3 | En CW: filtrar el catálogo del usuario por formato | Convertir a EPUB con DOCKER_MODS (§12.5) o subir versiones EPUB. |
| "Send to Kindle" devuelve "SMTP error: 535" | Password SMTP incorrecto o no es App Password (Gmail) | Admin Settings > Email Server Settings > "Test E-Mail" | Generar App Password en https://myaccount.google.com/apppasswords y reemplazar. |
| "Send to Kindle" envía pero no llega al Kindle | El "From" no está en "Approved Personal Document E-mail List" en Amazon | `https://www.amazon.com/myk` > Preferences > Personal Document Settings | Añadir el From E-Mail del SMTP a la lista de aprobados. |
| Conversión "Convert" devuelve error | DOCKER_MODS no está activo | `docker exec calibre-web which ebook-convert` | Activar DOCKER_MODS=linuxserver/mods:universal-calibre y recrear contenedor (§12.5). |
| Lentitud al cargar el catálogo | Biblioteca enorme (>10 000 libros) + thumbnails sin cache | `du -sh /mnt/hd2t/services/calibre-web/cache` | Esperar (la primera carga genera thumbnails). Reducir "Books per page" en Settings > UI Configuration. |
| Logs muestran "Cover image not found" repetidamente | El path a la cover en `metadata.db` no coincide con el filesystem (rsync incompleto) | `find /mnt/hd2t/media/books -name 'cover.jpg' \| wc -l` vs filas con `has_cover=1` | Reescanear: parar CW, abrir con Calibre Desktop, "Polish books > Update cover", reiniciar. |
| Tras importar biblioteca, autores con acentos aparecen mojibake | `metadata.db` viene de Calibre con encoding distinto | `sqlite3 metadata.db 'SELECT name FROM authors LIMIT 5;'` | Re-tagear los libros con Calibre Desktop > "Edit metadata > Use info from these formats". |
| Kobo Sync funciona pero el progreso de lectura no se actualiza en CW | Kobo guarda progreso en su propio `KoboReader.sqlite`; el sync CW depende de versiones recientes del firmware | Comprobar firmware Kobo ≥ 4.30 | Actualizar firmware del Kobo. |
| Watchtower actualiza pero el contenedor no arranca | Migración de `app.db` falló (raro) | `docker compose logs calibre-web \| grep -i migration` | Rollback de tag (§10.1 paso 7) + restaurar `config/app.db` desde Borg. Reportar a https://github.com/janeczku/calibre-web/issues. |
| `app.db` crece a >100 MB | Logs de auditoría (`anonymous_browse`) se acumulan en el schema antiguo | `sqlite3 /config/app.db ".tables"` y revisar tablas grandes | `VACUUM` desde sqlite3, o "Admin Settings > Database Configuration > "Vacuum the database". |
| OPDS con tildes en el feed devuelve XML inválido | Entidad XML mal escapada (bug histórico de CW < 0.6.20) | Validar con `xmllint --noout <(curl ...)` | Upgrade a ≥ 0.6.20. |

---

## 12. Variantes opt-in

### 12.1. Acceso remoto vía Tailscale

Tras desplegar Tailscale en el host ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) y emitir el cert:

```bash
# 1. Generar cert de Tailscale para el host calibre.
tailscale cert calibre.tailnet.ts.net

# 2. Mover los .crt y .key al bind mount de Caddy.
sudo mv calibre.tailnet.ts.net.crt \
  /mnt/hd2t/services/caddy/tailscale-certs/calibre.crt
sudo mv calibre.tailnet.ts.net.key \
  /mnt/hd2t/services/caddy/tailscale-certs/calibre.key

# 3. Descomentar el bloque calibre.{$TS_DOMAIN} en el Caddyfile (§6.1).

# 4. Recargar Caddy.
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

En los lectores OPDS, **el operador puede registrar dos catálogos** ("Casa LAN" y "Casa remoto") con sus URLs respectivas y elegir el correcto. **No** hay auto-switch — el lector no sabe si está en LAN o vía Tailscale.

### 12.2. Importar desde Calibre Content Server existente

Si el operador tenía un Calibre Content Server corriendo en otro equipo (ya sea un VPS o el laptop con Calibre Desktop "Connect to server"):

1. **Migrar la biblioteca** vía rsync (§3.3 Vía A).
2. **Migrar usuarios y autenticación**: Content Server **no comparte** schema de usuarios con Calibre-Web — son sistemas distintos. Los usuarios hay que crearlos a mano en CW (§7.2). Las shelves de Content Server no existen como tales (Content Server tiene "tags personales"); migrar manualmente.
3. **Apagar el Content Server** original. Ambos servidores no pueden compartir la misma `metadata.db`.

### 12.3. Múltiples bibliotecas (idiomas, ficción/no-ficción)

Calibre-Web **no soporta múltiples bibliotecas simultáneas**. La opción "Switch Library" no existe. Si el operador necesita separar bibliotecas:

- **Vía A — Mantenerlas en una sola y filtrar por tags**: añadir tag `ES` o `NF` a cada libro y usar el filtro de la UI. Es el approach recomendado.
- **Vía B — Desplegar dos instancias de Calibre-Web** con distintos `container_name`, distintos `:/books` mount, distintos `:/config` mount, y distintos hostnames en Caddy (`calibre.lan` y `calibre-en.lan`). Coste: dos `app.db` que sincronizar a mano (usuarios, shelves duplicados).
- **Vía C — Subcarpetas dentro de la única biblioteca**: Calibre Desktop soporta "Library Manage > Move Library" pero la estructura física es `Autor/Título`, no `idioma/Autor/Título`. CW no respeta subcarpetas custom. **No usar**.

### 12.4. (Opt-in recomendado para SSO web) Reverse Proxy Login Header con Authelia

Calibre-Web acepta un trusted header HTTP para auth: si la cabecera `Remote-User` (o el nombre que se configure) viene presente en una request a `/`, CW asume que el cliente ya está autenticado y crea/asocia la sesión sin pedir password. **Esto solo afecta a la UI web**; las rutas `/opds` y `/kobo/<token>/...` siguen usando Basic Auth y Bearer respectivamente.

Configuración:

1. **CW > Admin Settings > Basic Configuration > "Reverse Proxy Login Header Name"**: `Remote-User`.

2. **Caddy + Authelia (esto requiere Authelia desplegado, [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md))**:

```caddy
# Caddyfile — bloque calibre.lan
calibre.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    request_body {
        max_size 250MB
    }

    # Rutas públicas / no-auth: OPDS y Kobo Sync. Sin forward_auth.
    @opds_or_kobo {
        path /opds /opds/* /kobo/* /api/*
    }
    handle @opds_or_kobo {
        reverse_proxy http://calibre-web:8083 {
            header_up Host {host}
            header_up X-Forwarded-Proto https
            header_up X-Real-IP {remote_host}
            flush_interval -1
        }
    }

    # Rutas web (UI): forward_auth a Authelia.
    handle {
        forward_auth http://authelia:9091 {
            uri /api/verify?rd=https://auth.lan
            copy_headers Remote-User Remote-Groups Remote-Email
        }
        reverse_proxy http://calibre-web:8083 {
            header_up Host {host}
            header_up X-Forwarded-Proto https
            header_up X-Real-IP {remote_host}
            header_up Remote-User {http.auth.user.id}
            flush_interval -1
        }
    }
}
```

3. **Authelia**: añadir `calibre.lan` como dominio protegido en `configuration.yml > access_control.rules` con `policy: two_factor` (siguiendo el patrón del resto del homelab).

> **Por qué SÍ funciona con OPDS / Kobo en este modo**: las rutas `/opds` y `/kobo/*` pasan por el `handle @opds_or_kobo` que **NO** invoca `forward_auth`. CW las ve directamente con sus headers Basic/Bearer originales. Solo la UI web (paths sin esos prefijos) entra por el `handle` final con SSO.

> **Coste**: el operador paga 2FA solo al entrar a la UI web. Los clientes OPDS/Kobo siguen con sus credenciales nativas Calibre-Web (que no tienen 2FA — no soportan TOTP).

### 12.5. (Opt-in) Activar conversión completa con DOCKER_MODS

La imagen LSIO admite el sistema `DOCKER_MODS`: variable de entorno que descarga e instala mods adicionales en el contenedor en cada arranque. El mod `universal-calibre` instala los binarios de Calibre (`ebook-convert`, `kepubify`, `pdftohtml`, `lrf2lrs`...) y permite:

- **Botón "Convert" en la UI**: convierte EPUB ↔ MOBI ↔ AZW3 ↔ PDF ↔ TXT ↔ ...
- **Send-to-Kindle con conversión**: convierte EPUB → AZW3 antes de enviarlo (más fiel al formato Kindle).
- **Kobo Sync con KEPUB**: convierte EPUB → KEPUB on-demand para que las stats del Kobo (palabras leídas, tiempo restante por capítulo) funcionen.
- **`calibredb` en el contenedor**: permite añadir libros desde shell sin Calibre Desktop (§10.2 Vía C).

Activación:

```bash
# 1. Editar /mnt/hd2t/services/calibre-web/.env:
sed -i 's|^DOCKER_MODS=.*|DOCKER_MODS=linuxserver/mods:universal-calibre|' \
  /mnt/hd2t/services/calibre-web/.env

# 2. Recrear el contenedor (es necesario, no basta restart — DOCKER_MODS
# se procesa en el entrypoint y necesita un init nuevo).
cd ~/homelab/stacks/calibre-web
docker compose --env-file /mnt/hd2t/services/calibre-web/.env up -d --force-recreate

# 3. Vigilar el primer arranque — descarga 1.5 GB de binarios Calibre.
docker compose --env-file /mnt/hd2t/services/calibre-web/.env logs -f calibre-web
# Esperado:
# - "[mod-init] Adding universal-calibre to container"
# - "[mod-init] Installing Calibre" (5–10 min)
# - "[ls.io-init] done"
# - "Booting worker with pid"

# 4. Verificar.
docker exec calibre-web which ebook-convert
# Esperado: /usr/bin/ebook-convert
docker exec calibre-web ebook-convert --version
# Esperado: calibre 7.x.x

docker exec calibre-web which kepubify
# Esperado: /usr/bin/kepubify
```

**Costes**:

- La imagen pasa de ~210 MB a ~1.7 GB (en disco; el descarga de DOCKER_MODS son ~1.5 GB).
- El primer arranque tarda 5–10 min mientras se instalan los binarios.
- Subsiguientes arranques son rápidos (los binarios están en `/usr/bin/` ya).
- Actualizar el tag de la imagen base **reinstala** DOCKER_MODS desde cero — el mismo coste de 5–10 min cada upgrade.

**Cuándo desactivarlo**:

- Si el operador solo lee EPUBs en la web y no usa Kindle ni Kobo: no aporta nada.
- Si la Pi tiene la SD/eMMC con poco espacio: 1.5 GB extra duele.

### 12.6. Scrobbling a Goodreads

Calibre-Web puede integrarse con Goodreads para marcar libros como "currently reading" / "read":

1. **Admin Settings > Feature Configuration > Goodreads support**: activar.
2. Pedir API key en https://www.goodreads.com/api (Goodreads cerró el registro nuevo en 2020 — solo viable si el operador ya tiene una key heredada).
3. Configurar el secret en el campo correspondiente.

> **Estado del soporte upstream**: Goodreads ha sido progresivamente hostil con APIs de terceros desde la adquisición por Amazon. La feature en CW funciona pero está en mantenimiento mínimo. Alternativa moderna: **Hardcover** o **The StoryGraph** — sin integración nativa en CW por ahora.

### 12.7. Importar desde Audiobookshelf (libros en formato texto)

Si el operador tiene EPUBs / PDFs mezclados con audiolibros en Audiobookshelf ([`./03-audiobookshelf.md`](./03-audiobookshelf.md) §12.6):

1. **Mover los EPUBs/PDFs** de `/mnt/hd2t/media/audiobooks/<Autor>/<Título>/` a `/mnt/hd2t/media/books/<Autor>/<Título> (id)/`.
2. **Desde Calibre Desktop o `calibredb add`**: importar a la biblioteca CW.
3. **En Audiobookshelf**: forzar re-scan de la biblioteca de audiolibros para que ABS limpie las referencias huérfanas.

> El homelab por defecto separa: **ABS = audio**, **CW = texto**. La separación facilita el backup, la auth especializada (Kobo, Kindle) y los clientes nativos.

---

## Referencias

- **Documentación oficial**: https://github.com/janeczku/calibre-web/wiki
- **Imagen Docker LinuxServer.io**: https://docs.linuxserver.io/images/docker-calibre-web/
- **Release notes upstream**: https://github.com/janeczku/calibre-web/releases
- **Repositorio**: https://github.com/janeczku/calibre-web
- **DOCKER_MODS universal-calibre**: https://github.com/linuxserver/docker-mods/tree/universal-calibre
- **Calibre (proyecto upstream)**: https://calibre-ebook.com/
- **`calibredb` reference**: https://manual.calibre-ebook.com/generated/en/calibredb.html
- **OPDS spec**: https://specs.opds.io/opds-1.2
- **Kobo Sync (cómo funciona)**: https://github.com/janeczku/calibre-web/wiki/Kobo-Integration
- **KOReader (cliente OPDS recomendado)**: https://koreader.rocks/
- **Foro de la comunidad**: https://github.com/janeczku/calibre-web/discussions
- **Subreddit**: https://www.reddit.com/r/Calibre_Web/

**Documentos del homelab relacionados**:

- [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) — UID/GID, layout de `/mnt/hd2t/media/books/`.
- [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) — convenciones de `docker-compose.yml`, red `homelab`, `PGID=1100`.
- [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 — Calibre-Web incluido en upgrades automáticos.
- [`../03-red/02-pihole.md`](../03-red/02-pihole.md) — DNS local `calibre.lan`.
- [`../03-red/04-caddy.md`](../03-red/04-caddy.md) — reverse proxy, snippets `lan_internal_tls`, `security_headers`, `tailscale_tls`.
- [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) — acceso remoto sin port forwarding.
- [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) — SSO/2FA opcional vía Reverse Proxy Login Header (recomendado, §12.4).
- [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) — jail opt-in para Calibre-Web.
- [`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md) — agrupación de logs por `dev.dozzle.group: "media"`.
- [`../06-almacenamiento/03-syncthing.md`](../06-almacenamiento/03-syncthing.md) — vía recomendada para sincronizar el árbol de **ficheros** (no `metadata.db`) hacia/desde otros equipos.
- [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) — política 3-2-1.
- [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6 — exclusión específica de Calibre-Web (`cache`).
- [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) — patrón general de backup de bind mounts.
- [`./01-jellyfin.md`](./01-jellyfin.md) — el servidor multimedia hermano para vídeo (RO library, BD propia, sin DOCKER_MODS).
- [`./02-navidrome.md`](./02-navidrome.md) — el servidor de música hermano (RO library, API Subsonic, sin escritura).
- [`./03-audiobookshelf.md`](./03-audiobookshelf.md) — el servidor de audiolibros hermano; ABS y CW son los dos servidores **de texto** del homelab y comparten patrón (BD SQLite propia, Caddy delante, auth nativa con clientes específicos), pero divergen en el modelo de biblioteca: ABS RO (lee, no escribe), CW RW (es coautor de la biblioteca de Calibre).
