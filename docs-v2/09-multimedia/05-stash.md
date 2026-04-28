# Stash

## Descripción

Despliegue de **Stash** ([imagen oficial `stashapp/stash`](https://hub.docker.com/r/stashapp/stash)) como **organizador y reproductor de contenido multimedia con etiquetado, scrapers de metadatos y filtros** del homelab. Stash escanea una biblioteca de vídeos e imágenes, **no toca los ficheros originales**, y guarda en su propia BD SQLite (`stash-go.sqlite`) toda la capa de metadatos: rutas indexadas, etiquetas, performers, studios, estudios, scenes, galleries, markers (timestamps), `phash` perceptual para detección de duplicados, y referencias a los ficheros generados (sprites, vtt, transcodes, screenshots).

Sirve la biblioteca por tres vías:

1. **Web UI propia** (React + GraphQL) servida en `:9999` dentro del contenedor: catálogo navegable con filtros combinables, reproducción HTML5 con scrubbing por sprites, edición de metadatos en línea, gestión de performers/studios/tags como entidades de primera clase, y herramienta "Identify" para reconciliar contra una base de datos comunitaria (StashDB / ThePornDB).
2. **API GraphQL** en `/graphql` que consumen las apps externas y los scrapers: queries sobre cualquier modelo (`scenes`, `performers`, `tags`, `markers`...), subscripciones para job notifications y mutations para crear/editar entidades. Toda la UI se construye sobre esta API.
3. **DLNA** opcional (servidor UPnP/AV) para reproducir en Smart TVs sin app dedicada — desactivado por defecto en este homelab y documentado como variante opt-in en §12.5.

Este doc cubre, en orden:

1. **Por qué Stash** y no Jellyfin con plugins, ni Emby, ni un gestor genérico (Photoview, Lychee) — qué se asume y qué se descarta.
2. **Plan de variables y archivos**: `.env.example` versionable, `.env` real con valores en `/mnt/hd2t/services/stash/.env`, layout de directorios bajo `/mnt/hd2t/services/stash/` (config, blobs, cache) y bajo `/mnt/hd5t/stash/` (library, generated, metadata, previews).
3. **Convivencia entre dos discos**: por qué la biblioteca y los ficheros generados viven en `hd5t` (5 TB, dedicado a Stash, [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md) §6) y la BD + scrapers + plugins viven en `hd2t` (respaldable). Implicaciones para el backup (§9): `stash-go.sqlite` y los scrapers entran en Borg principal; `library/` y `generated/` no por defecto.
4. **`docker-compose.yml`** con bind mount de `/mnt/hd5t/stash/library` en **read-only** (Stash nunca debe modificar los ficheros originales — patrón equivalente a Jellyfin/Audiobookshelf), separación entre `config/` (BD + `config.yml` + scrapers + plugins — respaldable), `blobs/` (covers, performer images — respaldable), `cache/` (procesos en curso — excluido), `generated/` (sprites, vtt, transcodes — excluido por tamaño, regenerable) y `metadata/` (exports portables — respaldable).
5. **Despliegue, onboarding inicial** (login con autenticación habilitada desde el primer arranque, port 9999 nunca publicado al host, todo el acceso pasa por Caddy).
6. **Integración con Caddy** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3): bloque `stash.{$LAN_DOMAIN}` (no existe placeholder en el `Caddyfile`; se añade en §6.1), DNS local en Pi-hole, ajuste de `MAX_REQUEST_SIZE` para uploads (covers de scenes pueden llegar a 50 MB) y proxy WebSocket para notificaciones de jobs.
7. **Auth nativa de Stash** (single-user con `username` + `password` cifrado con bcrypt; o multi-user a partir de la 0.27.x con sistema de roles) y por qué Authelia delante **rompe** las sesiones GraphQL si se aplica `forward_auth` global. Variante opt-in con bypass para `/graphql` y `/scene/<id>/stream` en §12.4.
8. **Scrapers y plugins**: catálogo CommunityScrapers (repo aparte) con scrapers YAML para sitios habituales, gestión de los YAML en `/root/.stash/scrapers/`, instalación opt-in vía Plugin Manager, sistema de plugins (Python/JS) con permisos granulares.
9. **Backup**: `config/stash-go.sqlite` (~50–500 MB con 10k scenes, dominado por `phash` y por las relaciones N:N de tags) + `config/scrapers/`, `config/plugins/`, `blobs/`, `metadata/` cubiertos por la política general 3-2-1 ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.7); el `cache/` y `generated/` se regeneran tras un re-run de "Generate". La biblioteca masiva (`/mnt/hd5t/stash/library/`) **excluida** por política — multi-TB, decisión personal del operador documentada en [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §11.
10. **Operaciones cotidianas**: upgrade vía Watchtower (Stash es **opt-in** según [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2), añadir contenido (drop-in en `library/` + Scan), forzar Generate de sprites/transcodes, gestión de scrapers, ejecución de tareas largas, exportar la biblioteca a YAML/JSON.
11. **Variantes opt-in**: Tailscale para acceso remoto, Authelia con bypass selectivo, DLNA, blobs en filesystem vs base de datos, identificación masiva contra StashDB, scan automático con `inotify`.

> **Alcance de red**: Stash **solo se accede vía Caddy** sobre `https://stash.lan` (LAN) o `https://stash.${TS_DOMAIN}` (Tailscale). El puerto 9999 del contenedor **no se publica al host** (regla del homelab para todos los servicios web, [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §0). Sin Caddy delante no hay HTTPS y la auth nativa de Stash viaja en formularios HTTP `POST` que serían interceptables en LAN.

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), grupo `media` (GID 1100) con `homelab` como miembro, `/mnt/hd2t/` y `/mnt/hd5t/` montados, los directorios `/mnt/hd5t/stash/{library,metadata,previews,generated}/` ya creados con `homelab:media 2775` ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §3, §6).
- **Disco hd5t montado y sano** según [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md): `findmnt /mnt/hd5t` debe mostrar el montaje activo con flags `noatime,nofail`, y los healthchecks SMART deben estar al día. Stash hace lecturas secuenciales largas durante el escaneo y el cómputo de `phash`; un disco con sectores defectuosos lo nota inmediatamente (`I/O error` en `dmesg`).
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` creada, convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5 — bind mounts; §4.3 — red compartida; §5.2 — `PGID=1100` para multimedia).
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) con `lan_internal_tls` operativo y la red `homelab` accesible. Sin Caddy no hay HTTPS y Stash se queda detrás de un puerto interno solo accesible desde la red Docker.
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con la posibilidad de añadir registros A locales (`stash.lan` → IP de la Pi).
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Stash lleva la etiqueta `com.centurylinklabs.watchtower.enable: "true"` por política (servicio "stateless o de lectura ligera" según §4.2 de ese doc). Las migraciones de schema de la BD SQLite son **forward-only** y se ejecutan automáticamente en el primer arranque del nuevo tag — el operador debe tener un backup reciente antes de un upgrade mayor (de `0.X` a `0.X+1`).
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) para que `/mnt/hd2t/services/stash/{config,blobs}` y `/mnt/hd5t/stash/metadata/` sean archivados, y `/mnt/hd2t/services/stash/cache/` + `/mnt/hd5t/stash/{generated,previews}/` queden **excluidos**.
- **Biblioteca presente o ruta vacía**: Stash **no se levanta vacío** sin problema; al primer arranque pide configurar al menos un path. Si el operador aún no tiene contenido, basta con dejar `/mnt/hd5t/stash/library/` vacío y configurar el path desde la UI — el primer Scan no encontrará nada y queda listo para alimentar después.
- **Disco hd2t libre**: ≥ 2 GB para `/mnt/hd2t/services/stash/` (BD `stash-go.sqlite` ~50–500 MB con 10 000 scenes, dominada por la tabla `phashes` y las relaciones N:N de tags; blobs filesystem ~100 MB–2 GB con covers y performer images; cache temporal ~hasta 500 MB durante un Generate masivo).
- **Disco hd5t libre**: ≥ 100 GB recomendados para `/mnt/hd5t/stash/generated/` solo (sprites + vtt + screenshots para 10 000 scenes ~50–80 GB; los transcodes opt-in pueden multiplicar por 5 ese tamaño). El espacio para los **propios contenidos** (`library/`) se planifica aparte: hd5t es de 5 TB y todo lo "no-Stash" está fuera del disco por diseño ([`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md) §6).

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Organizador/reproductor de contenido multimedia con etiquetado | **Stash** ([AGPL-3.0](https://github.com/stashapp/stash/blob/develop/LICENSE.md)) | Jellyfin con plugins (`Tags`, `Metadata fetcher`...) ofrece menos del 10 % de las capacidades de filtrado y agrupación que Stash. Photoview es solo imágenes. Emby es propietario y la mayoría de plugins de organización avanzada están detrás de Premiere. Lychee se centra en galerías estáticas. Stash es un **proyecto vivo** (>10 000 commits, releases mensuales), modela el dominio en **scenes/performers/studios/tags/markers** como entidades de primera clase, soporta scrapers comunitarios para metadatos automáticos, calcula `phash` perceptual para detección de duplicados (irreemplazable cuando la biblioteca crece) y expone una **API GraphQL completa** para automatizaciones externas. |
| Imagen | **`stashapp/stash`** (oficial upstream) | El proyecto publica la imagen oficial directamente — no hay imagen LinuxServer.io. Tiene manifest multi-arch que incluye `linux/arm64`. La alternativa `hotio/stash` añade soporte nativo para `PUID`/`PGID` (la oficial corre como `root` por defecto), pero introduce un fork con merge lag. Se prefiere upstream + override de `user:` en Compose (§4). |
| Tag de imagen | **`v0.27.2`** (no `latest`, no `0.27`) | Stash sigue versionado semántico desde la `0.20`. Pinear el patch obliga a confirmar el upgrade leyendo https://github.com/stashapp/stash/releases — especialmente cuando hay migraciones de `stash-go.sqlite` (la `0.24` introdujo nueva tabla `groups`; la `0.26` reordenó `phashes`). Watchtower respeta tags exactos vía `image: stashapp/stash:${STASH_IMAGE_TAG}` — al cambiar el `.env` y reiniciar, se actualiza; sin cambio, no. |
| Arquitectura | `linux/arm64` (Pi 5) | Manifest multi-arch oficial. La imagen pesa ~700 MB en disco (Go binary + ffmpeg estático + UI bundle React). |
| Red Docker | **`homelab`** (bridge, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.3). **Sin** `ports:` al host. | Caddy llega a Stash por nombre (`http://stash:9999`) sobre la red compartida. No publicar `9999` al host elimina el riesgo de que la UI sea accesible **sin** TLS (Stash maneja credenciales en formularios HTTP `POST` y la API GraphQL acepta `Authorization: Bearer <apiKey>` — sin TLS, ambas viajarían en claro). |
| Modelo de almacenamiento | **Bind mount** `/mnt/hd2t/services/stash/{config,blobs,cache}` + **Bind mount** de la biblioteca en hd5t (RO) + **Bind mount** de generated/metadata/previews en hd5t (RW) | Patrón estándar del homelab. La separación permite una política de backup quirúrgica: `config + blobs + metadata` sí, `cache + generated + previews + library` no. |
| Biblioteca como **read-only** dentro del contenedor | `/mnt/hd5t/stash/library:/data:ro` | Stash **nunca debe** modificar los ficheros originales. Su flujo es 100 % **escanear → indexar → mostrar**; las operaciones de "rename" o "delete" desde la UI están **deshabilitadas** porque el bind mount es `:ro`. Coherente con Jellyfin y Audiobookshelf. La operación "delete file" de la UI de Stash falla con `EROFS` (read-only filesystem) y eso es deseable: si el operador quiere borrar un fichero, lo hace explícitamente desde el host, no por accidente con un click en la UI. |
| BD de Stash | **SQLite** en `/root/.stash/stash-go.sqlite` | Stash 0.20+ migró de antlr a sqlc para el ORM, pero la BD sigue siendo SQLite (no soporta PostgreSQL). El único modo "remoto" es montar el `.sqlite` en un share NFS/SMB, **fuertemente desaconsejado** por upstream (corruption risk). En Pi 5 con SSD/SD local + bind mount a `hd2t`, el rendimiento es suficiente para ≥ 50 000 scenes. |
| Almacenamiento de blobs (covers, performer images, studio logos) | **Filesystem** en `/blobs` (no en BD) | Stash 0.20+ permite elegir entre dos backends para blobs: `DATABASE` (todo dentro de `stash-go.sqlite` — la BD crece a varios GB) o `FILESYSTEM` (un fichero por blob bajo `blobs/`). Filesystem mantiene la BD pequeña, permite backup deduplicado vía Borg de los blobs (covers que se repiten entre escenas se almacenan una sola vez por hash) y facilita el debug. La opción se fija en `config.yml > blobs_storage: FILESYSTEM` (§7.1). |
| Usuario dentro del contenedor | **`user: "1000:1100"`** (homelab:media) en `docker-compose.yml` | La imagen oficial corre como `root` por defecto, lo que dejaría todos los ficheros en `/config`, `/generated`, `/blobs` con propietario `0:0` — incompatible con la convención del homelab ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.2). Override con `user:` fuerza a Stash a correr como UID 1000, GID 1100. La imagen lo soporta porque Stash es un binario Go puro sin dependencias de privilegios; el único uso de privilegios sería `/dev/dri` (transcoding por hardware) que aquí no se usa. |
| Transcoding por hardware | **Desactivado** | La Pi 5 no tiene encoder hardware para H.264/HEVC accesible por VAAPI/V4L2 m2m de forma fiable bajo Docker (la Mali-G610 sirve para decode, pero el encode pasa por un blob propietario poco maduro en mainline). Stash hace transcoding bajo demanda solo para clientes que no soportan el codec original, y `ffmpeg` software en Pi 5 da ~10–30 fps a 1080p, suficiente para uso doméstico de bajo paralelismo (1–2 streams). Para evitar pegarse, se limita a **2 jobs concurrentes** en §7.1. |
| Backup | **`config/` + `blobs/` + `metadata/`, sin `cache/` ni `generated/` ni `library/`** vía Borgmatic | El resto se regenera (sprites, vtt, transcodes) o es voluminoso e irreemplazable solo por descarga (library). Política en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.7. La biblioteca masiva (`/mnt/hd5t/stash/library/`, multi-TB) está **explícitamente excluida** por el patrón general "no respaldar `/mnt/hd5t`" ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6 línea 455). El operador que quiera backup offsite de `library/` añade un repo Borg dedicado con replicación a Backblaze B2 — decisión personal documentada en [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §11. |
| Watchtower | **`com.centurylinklabs.watchtower.enable: "true"`** | Por política ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 — categoría "Servicios stateless o de lectura ligera"). Stash migra schema con migraciones idempotentes en `pkg/sqlite/migrations/` y publica releases con changelog. **Pero**: las migraciones son **forward-only** y un upgrade fallido obliga a restaurar `stash-go.sqlite` desde Borg (§9.3). El hook `pre-update` corre el backup interno (§7.5) antes de parar el contenedor. |
| Reverse proxy | **Caddy sin `forward_auth`** | Stash tiene auth nativa (`/login` + cookie de sesión). La API GraphQL acepta `Authorization: Apikey <key>` (formato propio de Stash, no JWT) directamente. Aplicar Authelia con `forward_auth` global rompería las apps que consumen la API con `Apikey` (no envían cookie SSO). El paywall SSO **no aporta** mucho sobre la auth nativa cuando el servicio está estricto-LAN. Variante con bypass selectivo en §12.4. |
| Acceso remoto | **Vía Tailscale** ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) — `stash.${TS_DOMAIN}` con `tls /data/tailscale-certs/stash.crt /data/tailscale-certs/stash.key` | Sin port forwarding ni DDNS. La UI Web y la API GraphQL funcionan idénticamente sobre Tailscale. La reproducción de vídeo va por el mismo proxy Caddy con `flush_interval -1` para evitar buffering excesivo en streams largos. |
| Onboarding del primer login | **Por la UI web**, configurando `username` y `password` en el primer arranque | A diferencia de Calibre-Web, Stash **no** crea un usuario por defecto. La UI muestra un wizard de bienvenida que pide elegir credenciales antes de habilitar nada. El operador debe completarlo **antes** de exponer Stash a otros (incluso vía LAN), porque sin credenciales la UI es accesible para cualquiera con conectividad de red al puerto 9999. |
| Identificación contra StashDB | **Configurada, opt-in por uso** | StashDB es la base comunitaria mantenida por el proyecto ([https://stashdb.org](https://stashdb.org)). Stash incluye nativamente el conector — basta añadir el endpoint y la API key en Settings > Metadata Providers. La identificación masiva ("Identify all unmatched") es opt-in: el operador la lanza cuando lo necesita, no automática. |

---

## 1. Resumen de la arquitectura

```
                 ┌────────────────── LAN ──────────────────┐
                 │                                         │
   Cliente       │  Web UI │ App externa (GraphQL)         │
        │        │   │     │      │                        │
        └────────┴───┴─────┴──────┴────────────────────────┘
                                                │
                                                ▼
                                      https://stash.lan
                                                │
                                                ▼ (TLS de Caddy)
                                       ┌────────────────────┐
                                       │       Caddy        │  (../03-red/04-caddy.md)
                                       │     stash.lan      │
                                       │       :443         │
                                       └─────────┬──────────┘
                                                 │ reverse_proxy (red homelab)
                                                 │ http://stash:9999
                                                 ▼
                          ┌──────────────────────────────────────────┐
                          │                  Stash                   │
                          │           (este doc, :9999)              │
                          │                                          │
                          │   /root/.stash    (RW)  ─► /mnt/hd2t/services/stash/config/
                          │     config.yml          (config + secrets + scrapers + plugins)
                          │     stash-go.sqlite     (BD principal)
                          │     scrapers/           (YAML CommunityScrapers)
                          │     plugins/            (Python/JS user plugins)
                          │   /blobs          (RW)  ─► /mnt/hd2t/services/stash/blobs/
                          │   /cache          (RW)  ─► /mnt/hd2t/services/stash/cache/
                          │                                          │
                          │   /data           (RO)  ─► /mnt/hd5t/stash/library/
                          │   /generated      (RW)  ─► /mnt/hd5t/stash/generated/
                          │   /metadata       (RW)  ─► /mnt/hd5t/stash/metadata/
                          │   /previews       (RW)  ─► /mnt/hd5t/stash/previews/
                          └─────────┬──────────┬─────────┬───────────┘
                                    │          │         │
                                    ▼          ▼         ▼
                  ┌─────────────────────┐ ┌──────────┐ ┌────────────────────────┐
                  │ /mnt/hd5t/stash/    │ │ ffmpeg   │ │  Internet (vía         │
                  │ library/            │ │ embedded │ │  Pi-hole DNS):         │
                  │  ├── Sitio A/       │ │ (sprites,│ │  stashdb.org (graphql) │
                  │  │   ├── *.mp4      │ │  vtt,    │ │  scrapers comunitarios │
                  │  │   └── *.jpg      │ │  trans-  │ │                        │
                  │  └── ...            │ │  codes)  │ │ (solo scraping y       │
                  │ alimentado por:     │ └──────────┘ │  identify; el contenido│
                  │  - Operador (rsync, │              │  no sale del homelab)  │
                  │    Syncthing, etc.) │              └────────────────────────┘
                  │  - NUNCA por Stash  │
                  │    (RO desde el     │
                  │    contenedor)      │
                  └─────────────────────┘
```

Lo crítico de este diagrama:

1. **Una única vía de entrada para clientes**: navegador, app externa GraphQL → Caddy → Stash. El puerto 9999 no existe para clientes externos al stack.
2. **Biblioteca read-only** (`:ro`): Stash nunca modifica los ficheros originales. Aplicaciones externas (rsync, Syncthing, Samba en variante opt-in [`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md) §14.3) son las únicas vías para añadir, mover o borrar contenido. Tras un cambio, lanzar "Scan" desde la UI de Stash.
3. **Generated separado de library**: ambos en `hd5t` (mismo disco) pero en directorios distintos. La separación permite borrar `generated/` por completo sin tocar el contenido y forzar un Generate fresco si la BD se desincroniza con los sprites.
4. **Cache pequeño y excluido**: `/mnt/hd2t/services/stash/cache/` solo contiene ficheros temporales del job runner (resúmenes intermedios de hash, downloads parciales de scrapers). Excluido del backup.
5. **Sin GPU passthrough**: el contenedor **no** monta `/dev/dri`. Las decisiones de no usar transcoding por hardware se desarrollan en la fila correspondiente del cuadro de decisiones.
6. **Tráfico saliente solo para scrapers e Identify**: el contenedor sale a internet a `stashdb.org`, `theporndb.net` (si configurado), y a los hosts que cada scraper YAML invoca. **No** sale ningún contenido propio del homelab.

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/stash/.env.example`:

```env
# ~/homelab/stacks/stash/.env.example
# Versión control: ~/homelab/stacks/stash/.env.example
# Valores reales en /mnt/hd2t/services/stash/.env (chmod 600).
# Este fichero NO contiene secretos; las credenciales del usuario
# Stash viven dentro de /root/.stash/config.yml (hash bcrypt) y se
# respaldan vía Borgmatic. Las API keys de StashDB / ThePornDB
# se configuran desde la UI y se cifran en config.yml con la
# Jwt secret_key autogenerada.

# --- Comunes del homelab ---
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
MEDIA_GID=1100
TZ=Europe/Madrid

# --- Dominios internos (consistentes con dns/.env y proxy/.env) ---
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Stash ---
# https://github.com/stashapp/stash/releases
# Pinned al patch — leer changelog antes de cambiar. Las migraciones
# de stash-go.sqlite son forward-only.
STASH_IMAGE_TAG=v0.27.2

# Hostnames públicos (sin esquema). Usados en Caddyfile.
STASH_LAN_HOST=stash.lan
STASH_TS_HOST=stash.tailnet.ts.net

# STASH_PORT: el binario escucha aquí. Coincide con la convención
# upstream y con `reverse_proxy http://stash:9999` en Caddy.
STASH_PORT=9999
```

### 2.2. `.env` real (`/mnt/hd2t/services/stash/.env`)

```bash
# Crear el .env con permisos correctos.
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/stash
sudo install -o homelab -g homelab -m 600 /dev/null \
  /mnt/hd2t/services/stash/.env

# Volcar contenido (editar valores reales).
sudo -u homelab tee /mnt/hd2t/services/stash/.env > /dev/null <<'EOF'
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
MEDIA_GID=1100
TZ=Europe/Madrid
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net
STASH_IMAGE_TAG=v0.27.2
STASH_LAN_HOST=stash.lan
STASH_TS_HOST=stash.tailnet.ts.net
STASH_PORT=9999
EOF

# Verificar.
ls -l /mnt/hd2t/services/stash/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` (§4) declara `env_file: /mnt/hd2t/services/stash/.env`. Compose carga el fichero **a la hora de interpolar `${...}` en el YAML** (para tags, hostnames, `user:`, puertos…) y **además** lo expone al proceso del contenedor. Stash leerá `STASH_PORT` directamente para decidir el puerto de escucha; el resto son solo placeholders que el Compose resuelve antes de levantar el servicio.

> **Por qué no hay secretos en `.env`**: Stash no acepta credenciales por variables de entorno. El password del usuario admin se fija desde la UI tras el primer arranque (wizard de bienvenida) y vive cifrado (bcrypt cost 10, default de Stash) en `/root/.stash/config.yml` (clave `password`). Las API keys de StashDB y ThePornDB se configuran por la UI y se cifran con la `jwt_secret_key` que Stash genera en el primer arranque (también en `config.yml`). El backup completo del directorio `config/` cubre estos secretos.

> **Por qué `STASH_PORT=9999`**: el upstream usa 9999 por convención. Cambiarlo afectaría a los snippets de Caddy y a cualquier doc que asuma el puerto. Mantenerlo como variable explícita facilita un futuro cambio sin tocar el `docker-compose.yml`.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
sudo install -d -o homelab -g homelab -m 750 ~/homelab/stacks/stash
```

### 3.2. Crear el árbol de datos persistentes del servicio en hd2t

```bash
# Datos vivos del contenedor en hd2t.
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/stash

# Subdirectorios respaldables (config, blobs) y regenerable (cache).
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/stash/config \
  /mnt/hd2t/services/stash/blobs \
  /mnt/hd2t/services/stash/cache
```

### 3.3. Verificar el árbol en hd5t

Los directorios bajo `/mnt/hd5t/stash/` ya se crearon en [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §3.1 con permisos `homelab:media 2775`:

```bash
ls -ld /mnt/hd5t /mnt/hd5t/stash /mnt/hd5t/stash/*
# Esperado:
# drwxr-xr-x ... root    root   ... /mnt/hd5t
# drwxrwsr-x ... homelab media  ... /mnt/hd5t/stash
# drwxrwsr-x ... homelab media  ... /mnt/hd5t/stash/library
# drwxrwsr-x ... homelab media  ... /mnt/hd5t/stash/metadata
# drwxrwsr-x ... homelab media  ... /mnt/hd5t/stash/previews
# drwxrwsr-x ... homelab media  ... /mnt/hd5t/stash/generated

# El usuario homelab pertenece al grupo media.
id homelab | tr ',' '\n' | grep media
# Esperado: ...,1100(media),...
```

Si por alguna razón faltara alguno, recrear con:

```bash
for sub in library metadata previews generated; do
  sudo install -d -o homelab -g media -m 2775 "/mnt/hd5t/stash/${sub}"
done
```

### 3.4. Tabla resumen de permisos

| Ruta | Modo | Owner | Quién escribe | Por qué |
|---|---|---|---|---|
| `/mnt/hd2t/services/stash/` | `750 homelab:homelab` | homelab (Compose) | Solo el operador desde el host | Patrón canónico. Solo `homelab` ve el contenido. |
| `/mnt/hd2t/services/stash/config/` | `750 homelab:homelab` (preexiste, lo rellena Stash) | Proceso Stash (UID 1000) | Materializa `config.yml`, `stash-go.sqlite`, `stash-go.sqlite-wal`, `stash-go.sqlite-shm`, `scrapers/`, `plugins/`, `custom/`, `ui.css`. **Respaldable** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.7). |
| `/mnt/hd2t/services/stash/blobs/` | `750 homelab:homelab` | Proceso Stash | Covers, performer images, studio logos como ficheros indexados por hash. Crece con el catálogo (~100 MB–2 GB). **Respaldable**: contiene metadata visual irrecuperable sin re-scrape. |
| `/mnt/hd2t/services/stash/cache/` | `750 homelab:homelab` | Proceso Stash | Ficheros temporales del job runner: descargas parciales de scrapers, hashes intermedios. Crece y se vacía solo. **Excluido** del backup. |
| `/mnt/hd5t/stash/library/` | `2775 homelab:media` | Operador (rsync, Syncthing, Samba) — **NO Stash** (montado RO) | Contenido principal. Stash lo **lee** vía Scan; nunca escribe. |
| `/mnt/hd5t/stash/generated/` | `2775 homelab:media` | Proceso Stash (UID 1000) | Sprites, vtt, screenshots, transcodes derivados de `library/`. **Excluido** del backup (regenerable con `Generate`). |
| `/mnt/hd5t/stash/metadata/` | `2775 homelab:media` | Proceso Stash | Exports YAML/JSON (Performers, Studios, Tags, Movies, Galleries, Scenes) para portabilidad entre instancias. **Respaldable** — son artefactos de export pequeños (≤ 100 MB típico). |
| `/mnt/hd5t/stash/previews/` | `2775 homelab:media` | Proceso Stash | Clips de preview (~20 segundos por scene) usados para hover en la UI. Por defecto Stash los pone dentro de `generated/scenes/<id>/`; se redirige aquí con `config.yml` (§7.1) para mantener la separación lógica. **Excluido** del backup (regenerables con `Generate Preview`). |

### 3.5. Permisos para el proceso del contenedor

La imagen `stashapp/stash` corre por defecto como `root` (UID 0). El homelab fuerza `user: "1000:1100"` en el `docker-compose.yml` para coherencia con el resto de servicios multimedia ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.2). Resultado:

- Ficheros bajo `/root/.stash` (mapeado a `/mnt/hd2t/services/stash/config/`) aparecen como `homelab:homelab` en el host.
- Ficheros bajo `/blobs` (mapeado a `/mnt/hd2t/services/stash/blobs/`) aparecen como `homelab:homelab`.
- Ficheros bajo `/generated` y `/metadata` (mapeados a `/mnt/hd5t/stash/...`) aparecen como `homelab:media` con setgid heredado (gracias al modo `2775` del directorio padre).
- Lectura de `/data:ro` (`/mnt/hd5t/stash/library/`) funciona porque el GID 1100 está en el setgid del directorio padre y el bind mount es `:ro`.

> **Atención**: Stash internamente referencia `/root/.stash` como su directorio home (es un legado del binario único, no del contenedor). Aunque `user: "1000:1100"` no tiene HOME=`/root` configurado, Stash usa el path absoluto y no `~` — funciona sin tocar nada. Algunos plugins Python pueden importar de `~`; si fallan, añadir `environment: HOME=/root` en el Compose. El homelab no lo necesita por defecto.

> **Atención 2**: si alguna ejecución previa (de prueba, sin `user:`) dejó ficheros como `root:root` bajo `/mnt/hd2t/services/stash/`, corregir antes del primer `up` formal:
> ```bash
> sudo chown -R 1000:1000 /mnt/hd2t/services/stash/{config,blobs,cache}
> sudo chown -R 1000:1100 /mnt/hd5t/stash/{generated,metadata,previews}
> ```

---

## 4. `docker-compose.yml`

`~/homelab/stacks/stash/docker-compose.yml`:

```yaml
# ~/homelab/stacks/stash/docker-compose.yml
# Stack: stash (organizador y reproductor multimedia, Fase 9).
# Datos en /mnt/hd2t/services/stash/ y /mnt/hd5t/stash/.
# Biblioteca en /mnt/hd5t/stash/library/ (RO — Stash NO modifica).

name: stash

services:
  stash:
    image: stashapp/stash:${STASH_IMAGE_TAG}
    container_name: stash
    hostname: stash
    restart: unless-stopped
    env_file: /mnt/hd2t/services/stash/.env

    # La imagen oficial corre como root por defecto. Bajamos a 1000:1100
    # (homelab:media) para coherencia con el resto del homelab. Stash
    # es un binario Go puro y no necesita privilegios para escuchar en
    # 9999 (puerto > 1024) ni para ejecutar ffmpeg embebido.
    user: "${HOMELAB_UID}:${MEDIA_GID}"

    environment:
      TZ: ${TZ}
      # Puerto interno. Stash lee STASH_PORT directamente.
      STASH_PORT: ${STASH_PORT}
      # Ubicaciones forzadas dentro del contenedor.
      # Stash respeta STASH_GENERATED, STASH_METADATA, STASH_CACHE,
      # STASH_BLOBS_PATH si están definidas; en su defecto usa
      # subdirectorios de /root/.stash.
      STASH_GENERATED: /generated
      STASH_METADATA: /metadata
      STASH_CACHE: /cache
      STASH_BLOBS_PATH: /blobs
      # Redirigir el HOME del usuario 1000:1100 a /root/.stash para
      # que los plugins Python que asuman ~/.config/... encuentren
      # un sitio escribible. Inocuo si nada lo necesita.
      HOME: /root

    volumes:
      # Config + BD + scrapers + plugins. Respaldable.
      - /mnt/hd2t/services/stash/config:/root/.stash
      # Blobs (covers, performer images) en filesystem (no en BD).
      # Respaldable.
      - /mnt/hd2t/services/stash/blobs:/blobs
      # Cache temporal del job runner. NO respaldable.
      - /mnt/hd2t/services/stash/cache:/cache
      # Biblioteca multimedia. READ-ONLY.
      - /mnt/hd5t/stash/library:/data:ro
      # Generated (sprites, vtt, transcodes). NO respaldable.
      - /mnt/hd5t/stash/generated:/generated
      # Metadata exports (YAML/JSON). Respaldable.
      - /mnt/hd5t/stash/metadata:/metadata
      # Previews redirigidos aquí desde generated/scenes/ vía config.yml.
      - /mnt/hd5t/stash/previews:/previews
      # TZ y reloj sincronizados con el host.
      - /etc/localtime:/etc/localtime:ro

    # Sin `ports:` — Stash solo es accesible vía Caddy por la red `homelab`.
    networks:
      - homelab

    # Recursos: Stash arranca con ~150 MB y rara vez supera 600 MB
    # en uso normal (Go runtime + UI bundle + caché de queries
    # GraphQL). Durante un Generate masivo (~10 000 scenes) puede
    # consumir hasta 2 GB temporalmente con ffmpeg en paralelo.
    # Limitar evita OOM en el host.
    mem_limit: 2500m
    mem_reservation: 256m

    # Healthcheck: GET / devuelve 200 (HTML del shell de la SPA) si
    # el listener HTTP está vivo. Stash arranca en ~5–30 s (init de
    # la BD SQLite, carga de scrapers, escaneo lazy de plugins).
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:9999/"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s

    # security_opt: igual que el resto del homelab
    # (../02-docker/02-estructura-compose.md §0).
    security_opt:
      - no-new-privileges:true

    labels:
      # Watchtower: actualizar automáticamente — Stash migra schema
      # con migraciones forward-only idempotentes y publica releases
      # con changelog. Política: ../02-docker/04-watchtower.md §4.2.
      com.centurylinklabs.watchtower.enable: "true"
      # Hook pre-update: backup interno de la BD ANTES de parar el
      # contenedor para upgrade. Si la migración falla, restore
      # desde Borg + este snapshot (§9.3).
      com.centurylinklabs.watchtower.lifecycle.pre-update: "/bin/sh -c 'cd /root/.stash && cp -f stash-go.sqlite stash-go.sqlite.pre-upgrade'"
      com.centurylinklabs.watchtower.lifecycle.pre-update-timeout: "60"
      # Para Dozzle: agrupar logs de servicios multimedia.
      dev.dozzle.group: "media"

networks:
  homelab:
    external: true
```

### 4.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `name: stash` | Nombre del proyecto Compose. Cada servicio multimedia tiene su propio stack folder (igual que Jellyfin, Navidrome, Audiobookshelf, Calibre-Web) — un `down` afecta solo a Stash. |
| `image: stashapp/stash:${STASH_IMAGE_TAG}` | Tag pinned vía `.env`. La imagen oficial vive en Docker Hub. |
| `container_name: stash` / `hostname: stash` | Nombre estable para que Caddy llegue por DNS (`reverse_proxy http://stash:9999`). Sin esto, Compose le pone un nombre tipo `stash-stash-1` y rompe el DNS interno. |
| `env_file: /mnt/hd2t/services/stash/.env` | Carga de variables — patrón estándar del homelab. |
| `user: "${HOMELAB_UID}:${MEDIA_GID}"` | Override de root → 1000:1100. Coherente con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.2. |
| `environment.STASH_GENERATED, STASH_METADATA, STASH_CACHE, STASH_BLOBS_PATH` | Forzar a Stash a usar los paths externos `/generated`, `/metadata`, `/cache`, `/blobs` en lugar de subdirectorios de `/root/.stash`. Esto permite separar el respaldo de la BD (en hd2t) del contenido derivado pesado (en hd5t). |
| `environment.HOME=/root` | Algunos plugins Python (`stash-plugins-python` middleware) usan `~/.config/...` para credenciales de scraper. Con `user: "1000:1100"` y sin `HOME`, esos plugins fallarían al intentar escribir en `/`. Forzar `HOME=/root` los redirige al bind mount `config/`. |
| `volumes: /mnt/hd2t/services/stash/config:/root/.stash` | Bind mount canónico. Sin `:Z`/`:z` (no SELinux en Pi OS). |
| `volumes: /mnt/hd5t/stash/library:/data:ro` | **Read-only** porque Stash nunca debe modificar los originales. Idéntico a Jellyfin. |
| `volumes: /mnt/hd5t/stash/generated:/generated` | RW — Stash escribe sprites, vtt, transcodes, screenshots. Excluido del backup (§9). |
| `volumes: /mnt/hd5t/stash/previews:/previews` | RW — Stash escribe clips de preview. Por defecto irían a `/generated/scenes/<id>/preview.mp4`; redirigidos aquí con `config.yml > previews_path: /previews` (§7.1). |
| `volumes: /etc/localtime:ro` | Sincroniza la zona del host con el contenedor — backup ante un usuario que olvide poner `TZ` en `.env`. |
| `networks: [homelab]` | Solo la red compartida. Caddy ya está ahí. |
| `mem_limit: 2500m` | Stash idle ~150 MB; durante Generate masivo con ffmpeg en paralelo puede saltar a 1.5–2 GB. 2.5 GB de tope deja margen sin pegarse con Jellyfin si ambos están activos. |
| `mem_reservation: 256m` | Garantía mínima en presión de memoria. Stash arranca con ~150 MB. |
| `healthcheck` con `GET /` | Stash sirve `/` con HTML del shell SPA si el listener HTTP está vivo y la BD está abierta. `start_period: 90s` cubre el primer arranque tras un upgrade que migra schema (puede tardar ≥ 30 s con BD grande). |
| `security_opt: no-new-privileges:true` | Patrón base ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §0). |
| `com.centurylinklabs.watchtower.enable: "true"` | Watchtower opt-in en el homelab ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2). Stash está en la lista de servicios "stateless o de lectura ligera" que se actualizan auto. |
| `com.centurylinklabs.watchtower.lifecycle.pre-update` | Snapshot ad-hoc del `stash-go.sqlite` antes de parar el contenedor — si la migración del nuevo tag falla, hay un punto de restauración rápido sin esperar al ciclo de Borg. |
| `dev.dozzle.group: "media"` | Cuando Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)) levante, agrupa Jellyfin, Navidrome, Audiobookshelf, Calibre-Web y Stash bajo el mismo grupo "media". |
| `networks.homelab.external: true` | Patrón de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.4: la red se crea **una vez** durante el bootstrap. |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/stash
docker compose --env-file /mnt/hd2t/services/stash/.env config

# Esperado: salida YAML resuelta sin warnings.
# - El `image` debe estar plenamente cualificado: stashapp/stash:v0.27.2
# - user: "1000:1100" (no comillas vacías ni `null`).
# - Sin warning "variable X not set".
# - `volumes` con paths absolutos.
# - El bind de /data CON `read_only: true`.
# - El bind de /generated, /metadata, /previews SIN read_only.
```

---

## 5. Despliegue

### 5.1. Levantar el stack

```bash
cd ~/homelab/stacks/stash
docker compose --env-file /mnt/hd2t/services/stash/.env up -d
```

El primer `up` tarda **~30–90 segundos**:

1. Descarga la imagen (~700 MB en arm64).
2. Inicializa el schema SQLite en `/root/.stash/stash-go.sqlite` (~250 migraciones desde 0.0).
3. Crea `/root/.stash/config.yml` con valores por defecto (sin password aún).
4. Levanta el HTTP listener en `:9999`.

### 5.2. Estado del contenedor

```bash
docker compose --env-file /mnt/hd2t/services/stash/.env ps

# Esperado, tras ~90 segundos:
# NAME    IMAGE                       STATUS                 PORTS
# stash   stashapp/stash:v0.27.2      Up X (healthy)
```

Si tras 3 minutos el estado sigue siendo `(starting)`:

```bash
docker compose --env-file /mnt/hd2t/services/stash/.env logs --tail=200 stash

# Buscar líneas tipo:
# - "Stash is listening on 0.0.0.0:9999": HTTP listo.
# - "Performing migrations to version N": migración de schema.
# - "level=error msg=\"open /root/.stash/...: permission denied\"": revisar
#   permisos del bind mount (§3.5).
# - "level=error msg=\"unable to open database: unable to open database file\"":
#   permisos de stash-go.sqlite o disco saturado.
# - "level=warning msg=\"Configuration file ... does not exist\"": normal en
#   el primer arranque — Stash lo crea tras el wizard.
```

### 5.3. Onboarding inicial (wizard de bienvenida)

Stash expone su UI en `http://stash:9999` (red `homelab`). Caddy aún no lo enruta hasta §6. Para el primer onboarding, dos opciones:

**Opción A — Vía Caddy (preferida)**: completar §6 antes de lanzar el formulario. Abrir `https://stash.lan` desde un navegador del LAN.

**Opción B — `docker exec` para validar**:

```bash
# Verificar que Stash responde dentro del contenedor.
docker exec stash wget -qO- http://localhost:9999/ | head -c 200
# Esperado: HTML del shell SPA (`<!doctype html><html>...`).
```

> En la práctica el flujo recomendado es **Opción A**: completar §6, abrir `https://stash.lan`, completar el wizard.

El **wizard de bienvenida** pide en orden:

1. **Welcome screen** → click "Next".
2. **Setup paths**:
   - **Stash Library Directory** (donde van la BD y los blobs): `/root/.stash` (ya configurado).
   - **Generated Files**: `/generated`.
   - **Metadata Files**: `/metadata`.
   - **Cache Folder**: `/cache`.
   - **Blob Folder**: `/blobs`.
   - **Library Path** (la biblioteca multimedia a indexar): `/data` (read-only desde el bind mount).
3. **Database Backup**: dejar el path por defecto (`/root/.stash`). Stash hará backups internos de la BD aquí (§7.5).
4. **Authentication**:
   - **Username**: el que el operador prefiera (recomendado: el mismo que el del homelab, para no acumular credenciales mentales).
   - **Password**: ≥ 16 caracteres, gestionado en Vaultwarden cuando esté desplegado.
   - Stash genera la `jwt_secret_key` (32 bytes random) y la guarda en `config.yml` automáticamente.
5. **Finish** → Stash escribe `config.yml` con todo lo anterior y reinicia el listener (~3 s).

> **Acción inmediata e ineludible**: completar el wizard **antes** de descomentar bloques Tailscale o publicar `stash.lan` en Pi-hole. Sin auth configurada, cualquier dispositivo de la LAN con conectividad al puerto 9999 (incluido un huésped en la red WiFi) ve la biblioteca completa.

> **Si el wizard se cierra sin completar**: borrar `/mnt/hd2t/services/stash/config/config.yml` y reiniciar el contenedor — Stash relanza el wizard.

---

## 6. Integración con Caddy

### 6.1. Añadir el bloque `stash.{$LAN_DOMAIN}` al `Caddyfile`

A diferencia de Jellyfin/Pi-hole, el `Caddyfile` del homelab ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3) **no incluye placeholder** para Stash. Editar `~/homelab/stacks/proxy/Caddyfile` y añadir:

```caddy
# Stash (../09-multimedia/05-stash.md) — organizador multimedia
stash.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Subida de covers custom (covers de scenes pueden alcanzar 50 MB
    # con imágenes 4K). Deja margen sin permitir abuso.
    request_body {
        max_size 100MB
    }

    # GraphQL subscriptions vía WebSocket — notificaciones de jobs
    # (Scan, Generate, Identify) en tiempo real.
    @websockets {
        header Connection *Upgrade*
        header Upgrade    websocket
    }

    handle @websockets {
        reverse_proxy http://stash:9999
    }

    # Streaming de scenes — flush_interval -1 evita buffering en
    # streams largos (películas 1+h pueden congelar el reproductor
    # si Caddy bufferea).
    handle {
        reverse_proxy http://stash:9999 {
            header_up Host {host}
            header_up X-Forwarded-Proto https
            header_up X-Real-IP {remote_host}
            flush_interval -1
        }
    }
}
```

Y el bloque Tailscale gemelo (comentado hasta tener cert vía `tailscale cert`):

```caddy
# stash.{$TS_DOMAIN} {
#     import tailscale_tls stash
#     import security_headers
#     request_body {
#         max_size 100MB
#     }
#     @websockets {
#         header Connection *Upgrade*
#         header Upgrade    websocket
#     }
#     handle @websockets {
#         reverse_proxy http://stash:9999
#     }
#     handle {
#         reverse_proxy http://stash:9999 {
#             header_up Host {host}
#             header_up X-Forwarded-Proto https
#             header_up X-Real-IP {remote_host}
#             flush_interval -1
#         }
#     }
# }
```

Recargar Caddy:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
# Esperado: 2025/.../INFO   admin   admin endpoint started   {"address": "localhost:2019"}
# Si hay error, mira el lineno: el bloque que acabas de añadir.
```

### 6.2. Trusted proxies en Stash

Stash registra la IP del cliente en sus logs y en el campo `last_login` del usuario. Por defecto ve la IP de Caddy (`172.20.0.X`) porque no está configurado para confiar en `X-Forwarded-For`.

Para que Stash interprete `X-Forwarded-For` enviado por Caddy:

- Editar `/mnt/hd2t/services/stash/config/config.yml` y añadir:
  ```yaml
  proxy_prefix: ""
  trusted_proxies:
    - 172.20.0.0/24
  ```
- Recargar la config sin reiniciar:
  ```bash
  docker exec stash sh -c 'kill -HUP 1' 2>/dev/null || \
  docker compose --env-file /mnt/hd2t/services/stash/.env restart stash
  ```

> **Solo activar** si Caddy está delante (de lo contrario, un cliente puede falsificar la cabecera). El subnet `172.20.0.0/24` es el rango por defecto de la red `homelab`; ajustar si la subnet en la docker network es otra (`docker network inspect homelab | jq '.[].IPAM.Config'`).

### 6.3. Registro DNS local en Pi-hole

Pi-hole resuelve `stash.lan` → IP de la Pi. Esto ya estaba descrito conceptualmente en [`../03-red/02-pihole.md`](../03-red/02-pihole.md) §7.

```bash
# Vía la UI de Pi-hole (preferido):
# 1. Abrir https://pihole.lan/admin/
# 2. "Local DNS > DNS Records"
# 3. Domain: stash.lan
#    IP:     192.168.1.10  (la IP estática de la Pi en LAN)
# 4. "Add"
```

Verificar:

```bash
dig +short @192.168.1.2 stash.lan
# Esperado: 192.168.1.10
```

### 6.4. Probar el acceso

```bash
# Desde el host (red homelab interna):
docker exec caddy wget -qO- -S http://stash:9999/ 2>&1 | head -10
# Esperado: HTTP/1.1 200 OK + HTML del shell SPA.

# Desde la LAN (validar TLS):
curl -fsS https://stash.lan/ -o /dev/null -w "%{http_code}\n"
# Esperado: 200
# El cert es de la CA interna de Caddy ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §3.4);
# el navegador puede protestar. Solución: instalar el root cert de Caddy.

# Endpoint GraphQL (devuelve el playground HTML si es GET; JSON si es POST).
curl -fsS https://stash.lan/graphql -o /dev/null -w "%{http_code}\n"
# Esperado: 200 (GraphQL playground en GET).

# Desde el navegador:
# https://stash.lan → wizard de bienvenida (primer arranque) o login (luego).
```

### 6.5. (No por defecto) Proteger con Authelia

**El homelab no pone Authelia delante de Stash por defecto** — explicado en §0 fila "Reverse proxy" y desarrollado en §12.4. La razón en una línea: las apps externas que consumen la API GraphQL envían `Authorization: Apikey <key>` (formato propio, no JWT) directamente; un `forward_auth` global con Authelia las rechazaría con 401 antes de que el header llegara al backend.

La vía correcta para SSO **manteniendo apps externas** es **bypass selectivo** del path `/graphql` (que usa `Apikey` propio) y reservar el SSO para la UI web. Ver §12.4.

---

## 7. Configuración post-despliegue

### 7.1. Ajustes básicos del servidor (config.yml)

Tras el wizard, el fichero `/mnt/hd2t/services/stash/config/config.yml` contiene la configuración. Algunos parámetros se editan desde la UI; otros solo desde el YAML directamente. Tras editar el YAML, **reiniciar Stash** para aplicar los cambios.

Valores recomendados (extraer del fichero, completar y guardar):

```yaml
# /mnt/hd2t/services/stash/config/config.yml — fragmento ilustrativo
# (no es el YAML completo — solo los campos relevantes).

# Listening
host: 0.0.0.0
port: 9999

# Auth (escrito por el wizard)
username: <usuario>
password: <hash bcrypt>
jwt_secret_key: <32 bytes random>

# Paths (escrito por el wizard)
generated: /generated
metadata: /metadata
cache: /cache
blobs_path: /blobs
blobs_storage: FILESYSTEM      # NO DATABASE — backup-friendly.

# Library paths (configurado en Settings > Library tras el wizard)
stash:
  - /data

# Previews redirigidos a /previews (separados de generated/scenes/<id>/).
previews_path: /previews

# Performance
parallel_tasks: 2              # ffmpeg en paralelo durante Generate.
                               # Pi 5 con 4 cores: 2 deja margen para
                               # responder a la UI durante un job largo.
preview_audio: true
preview_segments: 12
preview_segment_duration: 0.75
preview_exclude_start: 0       # No saltar el principio.
preview_exclude_end: 0
preview_preset: ultrafast      # ffmpeg preset; "ultrafast" prioriza
                               # tiempo sobre tamaño/calidad — los
                               # previews son cortos, no compensa
                               # comprimir mejor.

# Transcoding (bajo demanda durante streaming)
transcode_input_args: []       # Sin aceleración hardware (no GPU).
transcode_output_args: []
ffmpeg_path: ""                # Usar el embebido en la imagen.

# Scan
calculate_md5: true
calculate_phash: true          # Crítico para detección de duplicados.
sequential_scanning: false

# Web behavior
proxy_prefix: ""
trusted_proxies:
  - 172.20.0.0/24              # red homelab; ver §6.2.

# Backups internos
max_database_backup_count: 3   # Mantener los últimos 3 backups
                               # generados por Stash en /root/.stash/
                               # (independientes del Borg externo).
```

> **Por qué `blobs_storage: FILESYSTEM`**: con `DATABASE`, todos los blobs (covers, performer images) viven dentro de `stash-go.sqlite`. Una biblioteca de 10 000 scenes con cover por escena llevaría la BD a 5–8 GB y haría cualquier `VACUUM INTO` o `borg create` muy costoso. Con `FILESYSTEM`, la BD queda en ~50–500 MB y los blobs son ficheros indexados por SHA en `/blobs/<aa>/<bb>/...` — Borg los deduplica perfectamente.

> **Por qué `parallel_tasks: 2`**: Stash deja dos slots de ffmpeg corriendo a la vez. Pi 5 (4 cores Cortex-A76) puede sostener 2 transcodes 1080p en paralelo a ~30 fps y aún responder a la UI. Subirlo a 4 satura los cores y la UI se queda colgada durante el Generate — peor experiencia. Bajarlo a 1 hace los Generate masivos demasiado lentos.

### 7.2. Configurar la biblioteca

**Settings > Library > Folders**:

1. **Folder Path**: `/data` (path **dentro del contenedor** — corresponde a `/mnt/hd5t/stash/library/` en el host).
2. **Save**.

Tras añadir el path:

- **Settings > Tasks > Scan** → arranca el primer scan.
- Stash recorre `/data` recursivamente, identifica vídeos por extensión (`.mp4`, `.mkv`, `.webm`, `.avi`, `.wmv`, `.mov`, `.flv`, `.mpg`, `.mpeg`, `.m4v`, `.ts`), calcula `md5`/`phash` de cada uno (~30 s–5 min por hora de vídeo en Pi 5 con disco USB 3.0) y los inserta en la tabla `scenes`.
- Las imágenes (`.jpg`, `.png`, `.webp`, `.gif`) van a la tabla `images`; los archivos de gallery (`.zip`, `.cbz`, `.cbr`) a `galleries`.
- Los `.srt` / `.vtt` adyacentes al vídeo se asocian automáticamente como subtítulos.

> **Consejo**: para una biblioteca grande (≥ 1 TB), correr el primer Scan **de noche**. La fase de `phash` es la más lenta y satura el disco. Con un hd5t USB 3.0, ~10–20 horas para 5 TB.

### 7.3. Generar derivados (sprites, vtt, screenshots, previews)

**Settings > Tasks > Generate**:

Para cada scene, Stash puede generar hasta 6 derivados:

| Derivado | Qué es | Tiempo aprox (1080p, Pi 5) | Tamaño | Necesario para |
|---|---|---|---|---|
| **Cover** | Imagen JPG en un timestamp | < 1 s | ~50 KB | Listing visible. |
| **Sprite + VTT** | Tira de thumbnails para scrubbing | 5–30 s | ~200 KB + 5 KB | Previsualizar timeline al hover. |
| **Preview** | Clip ~12 s (8 segmentos × 1.5 s) | 30 s–2 min | ~2–5 MB | Hover en card del listing. |
| **Image Preview** | WebP animado del Preview | 10–30 s | ~1 MB | Preview en clientes sin video. |
| **Screenshots** | N capturas equiespaciadas | 2–5 s | ~100 KB × N | Galería de la scene. |
| **Transcode** | Re-encode H.264 1080p | 10–30 min | ~variable | Streaming a clientes sin codec original (raro hoy). |

Recomendación inicial: marcar **Sprites, VTT, Previews, Screenshots**; **NO** marcar Transcodes (los clientes modernos ya soportan AV1/HEVC nativamente y Transcode quema CPU sin ganancia).

Lanzar Generate sobre la biblioteca completa. Para 10 000 scenes a 1080p, ~24–48 horas en Pi 5 con `parallel_tasks: 2`.

### 7.4. Scrapers comunitarios (opt-in por uso)

Los scrapers de Stash son ficheros YAML que describen cómo extraer metadatos de un sitio web. Stash **incluye un par genéricos** y delega al repo aparte [stashapp/CommunityScrapers](https://github.com/stashapp/CommunityScrapers) los específicos por sitio.

**Instalar CommunityScrapers**:

```bash
# Clonar el repo bajo el bind mount de scrapers.
sudo -u homelab git clone --depth 1 \
  https://github.com/stashapp/CommunityScrapers.git \
  /mnt/hd2t/services/stash/config/scrapers/community

# Activar todos los YAML del repo.
docker exec stash sh -c 'cd /root/.stash/scrapers/community/scrapers && cp -rn ./* /root/.stash/scrapers/'

# Reload de scrapers desde la UI:
# Settings > Metadata Providers > Scrapers > "Reload Scrapers"
```

> **Actualizar más adelante**: `cd /mnt/hd2t/services/stash/config/scrapers/community && sudo -u homelab git pull && docker exec stash sh -c 'cd /root/.stash/scrapers/community/scrapers && cp -rfu ./* /root/.stash/scrapers/'` — y recargar desde la UI.

> **Alternativa moderna (Stash 0.27+)**: Settings > Plugins > Available Plugins > "Community Scrapers" (instalación gestionada por la UI, sin git manual). Si la UI lo ofrece, preferir esa vía — actualizaciones automáticas y selección granular.

**Configurar StashDB** (recomendado, free, sin registro):

1. Crear cuenta en [https://stashdb.org/register](https://stashdb.org/register).
2. **My Profile > API Key** → copiar el token.
3. **Settings > Metadata Providers > Stash-box Endpoints > Add**:
   - **Name**: `stashdb`
   - **GraphQL Endpoint**: `https://stashdb.org/graphql`
   - **API Key**: el token copiado.
4. **Save**.

A partir de ahora, en cualquier scene: **Edit > "Scrape with..." > stashdb** intenta identificarla por `phash` o `md5`. La operación masiva está en **Tasks > Identify > Stash-box: stashdb**.

### 7.5. Backup interno automático de Stash

Stash tiene su propio sistema de backup, independiente de Borg:

**Settings > Tasks > "Backup Database Now"** o programado vía:

```yaml
# config.yml
db_backup_schedule: "@daily"   # cron-like; @daily = a las 00:00.
```

Genera un fichero `stash-go.sqlite-backup-YYYYMMDD-HHMMSS.sqlite` en `/root/.stash/` cada vez. La política `max_database_backup_count: 3` (§7.1) mantiene solo los 3 más recientes.

> **Por qué redundar con Borg**: el backup interno de Stash es inmediato y sin coste de orquestación, útil **antes** de un upgrade arriesgado o una operación masiva (Identify de toda la biblioteca). Borg cubre el escenario de "perder hd2t entero", que el backup interno no resuelve (vive en el mismo disco).

### 7.6. Identificación masiva (opcional)

Cuando la biblioteca está scaneada y Generate ha terminado:

**Settings > Tasks > Identify**:

- **Sources** (en orden): `stashdb`, luego scrapers concretos como fallback.
- **Field Strategy**:
  - **Title**: Overwrite.
  - **Studio**: Merge.
  - **Performers**: Merge.
  - **Tags**: Merge.
  - **Date**: Overwrite.
  - **Cover**: Overwrite (si la fuente tiene mejor cover).
- **Skip Already Identified**: marcar si quieres que solo procese los aún sin StashID.
- **Run** → cola un job que recorre todas las scenes y consulta StashDB por `phash`/`md5`. ~5 s por scene; 10 000 scenes → ~14 h.

> **Consejo**: lanzar Identify **después** de Generate (Stash usa el `phash` para emparejar). Si Generate aún no ha pasado, el match será peor y dependerá solo del `md5`.

---

## 8. Verificación

### 8.1. Contenedor sano

```bash
docker compose --env-file /mnt/hd2t/services/stash/.env ps
# Esperado: Up X (healthy)

docker inspect stash --format '{{.State.Health.Status}}'
# Esperado: healthy
```

### 8.2. Stash escucha solo dentro de la red `homelab`

```bash
# Desde el host: el puerto 9999 del contenedor NO debe responder.
ss -tlnp | grep ":9999 "
# Esperado: vacío (Caddy escucha en :443, no en :9999; el :9999 de Stash es interno).

# Desde dentro de la red homelab sí debe responder.
docker exec caddy wget -qO- http://stash:9999/ -O - -S 2>&1 | head -5
# Esperado: HTTP/1.1 200 OK
```

### 8.3. Biblioteca montada y visible

```bash
docker exec stash ls -la /data | head
# Esperado: contenido del operador, propietario homelab:media
# (visible como UID 1000, GID 1100 dentro del contenedor).

# Test escritura en /data (debería FALLAR — RO):
docker exec stash sh -c 'touch /data/.test_write 2>&1' || echo "OK - read-only"
# Esperado: "Read-only file system" + "OK - read-only".

# Generated y metadata sí escriben.
docker exec stash sh -c 'touch /generated/.test_write && rm /generated/.test_write && echo OK'
docker exec stash sh -c 'touch /metadata/.test_write && rm /metadata/.test_write && echo OK'
# Esperado: OK + OK.
```

### 8.4. UI web operativa

```bash
# Probar que el shell SPA responde.
curl -fsS https://stash.lan/ | grep -oE '<title>[^<]*</title>'
# Esperado: <title>Stash</title>

# Login + obtener cookie de sesión.
curl -c /tmp/stash-cookies -fsS -X POST https://stash.lan/login \
  -d 'username=<usuario>&password=<password>' \
  -o /dev/null -w "%{http_code}\n"
# Esperado: 200 o 302.

# Acceder al endpoint GraphQL con la cookie.
curl -b /tmp/stash-cookies -fsS https://stash.lan/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"{stats{scene_count performer_count tag_count}}"}'
# Esperado: {"data":{"stats":{"scene_count":N,...}}}
rm /tmp/stash-cookies
```

### 8.5. API GraphQL con API key

```bash
# Generar una API key desde la UI: Settings > Security > "Generate API Key".
# La key aparece UNA SOLA VEZ — copiarla a Vaultwarden / KeePassXC.

API_KEY=<key copiada>

curl -fsS https://stash.lan/graphql \
  -H "Content-Type: application/json" \
  -H "ApiKey: $API_KEY" \
  -d '{"query":"{version{version}}"}'
# Esperado: {"data":{"version":{"version":"v0.27.2"}}}
```

### 8.6. Smoke test desde el navegador

1. `https://stash.lan` carga el login (si ya configurado) o el dashboard.
2. Login con la cuenta admin exitoso.
3. **Settings > Library > Folders** lista `/data`.
4. **Settings > Tasks > Scan** procesa la biblioteca (vía un disco USB 3.0 con ~100 ficheros, < 5 min).
5. La página principal lista las scenes scaneadas con cover por defecto.
6. Click en una scene: abre el reproductor HTML5; el vídeo se reproduce (si Generate completó: scrubbing por sprites funciona).
7. **Settings > Tasks > Generate** se completa para una scene de prueba en < 5 min (1080p).
8. **Markers**: dentro de una scene, en el reproductor, click "Add Marker" en un timestamp → guardado.

### 8.7. Persistencia tras reboot

```bash
sudo reboot
# Esperar ~2 min.
ssh homelab@pi.lan
docker compose --env-file /mnt/hd2t/services/stash/.env -f ~/homelab/stacks/stash/docker-compose.yml ps
# Esperado: stash Up X (healthy) — restart: unless-stopped lo trae solo.
```

### 8.8. Lista de verificación

- [ ] `docker compose ... ps` muestra `Up X (healthy)`.
- [ ] `docker inspect stash --format '{{.State.Health.Status}}'` = `healthy`.
- [ ] `ss -tlnp | grep ":9999 "` no devuelve nada del contenedor (no hay puerto publicado).
- [ ] `curl -fsS https://stash.lan/` devuelve HTTP 200 con el shell SPA.
- [ ] `docker exec stash sh -c 'touch /data/.test'` falla con `Read-only file system`.
- [ ] `docker exec stash sh -c 'touch /generated/.test && rm /generated/.test'` funciona.
- [ ] El wizard de bienvenida quedó completado: existe `username` y `password` en `/mnt/hd2t/services/stash/config/config.yml`.
- [ ] Login en `https://stash.lan` con cuenta admin OK.
- [ ] La query GraphQL `{stats}` devuelve contadores válidos.
- [ ] Scan de una biblioteca de prueba inserta scenes en la BD.
- [ ] Generate de una scene produce sprite + vtt + preview en `/mnt/hd5t/stash/generated/scenes/<id>/`.
- [ ] Stash-box endpoint (`stashdb`) configurado y `Identify` resuelve al menos una scene.
- [ ] `blobs_storage: FILESYSTEM` en `config.yml`; el directorio `/mnt/hd2t/services/stash/blobs/` empieza a llenarse de ficheros.
- [ ] Tras `sudo reboot`, Stash vuelve a estar `(healthy)` en menos de 2 minutos.
- [ ] Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.7) lista `/mnt/hd2t/services/stash/{config,blobs}` y `/mnt/hd5t/stash/metadata/` en el archivo y **no** lista `cache/`, `generated/`, `previews/` ni `library/`.

---

## 9. Backup

### 9.1. Qué se respalda y qué no

| Ruta | Backup | Justificación |
|---|---|---|
| `/mnt/hd2t/services/stash/config/` | **Sí** (Borgmatic, [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.7) | Contiene `config.yml` (con `password` bcrypt, `jwt_secret_key`, API keys de Stash-box cifradas, paths configurados), `stash-go.sqlite` (BD principal: scenes, performers, tags, markers, phashes, history), `scrapers/` (catálogo CommunityScrapers + custom), `plugins/` (plugins user-installed), `custom/` (CSS/JS personalizados de la UI). ~50–500 MB. |
| `/mnt/hd2t/services/stash/blobs/` | **Sí** | Covers, performer images, studio logos como ficheros indexados por hash. ~100 MB–2 GB. Borg deduplica entre archivos lo que comparte hash. |
| `/mnt/hd2t/services/stash/cache/` | **No** | Ficheros temporales del job runner (descargas parciales de scrapers, hashes intermedios). Se limpia solo. |
| `/mnt/hd5t/stash/metadata/` | **Sí** | Exports YAML/JSON portables (Performers, Studios, Tags, Movies, Galleries, Scenes). Pequeños (≤ 100 MB). Permiten reconstruir la metadata si la BD se pierde, importándolos en una instancia nueva con "Tasks > Import". |
| `/mnt/hd5t/stash/library/` | **No** (ya excluido por `/mnt/hd5t` global) | Biblioteca multimedia voluminosa (multi-TB). Decisión documentada en [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §11. El operador que la quiera offsite añade un repo Borg dedicado a `hd5t/stash/library/` con replicación a Backblaze B2 (~$30/mes para 5 TB). |
| `/mnt/hd5t/stash/generated/` | **No** | Sprites, vtt, screenshots, transcodes. Regenerable con `Settings > Tasks > Generate`. Tarda 24–48 h re-procesar 10 000 scenes pero es determinista. |
| `/mnt/hd5t/stash/previews/` | **No** | Clips de preview cortos. Regenerables con `Generate > Preview`. |

### 9.2. Política Borgmatic

`~/homelab/stacks/backup/config/borgmatic.d/stash.yaml` (extendiendo el doc principal):

```yaml
# Cubierto en ../07-backups/02-borgmatic.md §13.7 — solo aquí como referencia.
source_directories:
  - /mnt/hd2t/services/stash/config
  - /mnt/hd2t/services/stash/blobs
  - /mnt/hd5t/stash/metadata

exclude_patterns:
  - /mnt/hd2t/services/stash/cache
  # /mnt/hd5t ya está excluido globalmente; metadata/ vuelve a entrar
  # explícitamente vía source_directories.

# Hooks para snapshot consistente de SQLite (evita races con WAL).
before_backup:
  # stash-go.sqlite (BD de Stash). VACUUM INTO da snapshot consistente
  # incluso con WAL activo y Stash corriendo.
  - sqlite3 /mnt/hd2t/services/stash/config/stash-go.sqlite "VACUUM INTO '/mnt/hd2t/services/stash/config/stash-go.sqlite.bak'"
```

> **Por qué `VACUUM INTO`**: la BD corre con WAL mode (default de Stash); un copiado directo del `.sqlite` sin checkpoint puede dar una BD inconsistente. `VACUUM INTO` es el método canónico de SQLite para hacer un snapshot consistente sin parar el servidor. El snapshot queda como `.bak` que entra en el archivo Borg natural.

> **Snapshot pre-upgrade independiente**: el hook Watchtower `pre-update` del `docker-compose.yml` (§4) genera además `stash-go.sqlite.pre-upgrade` justo antes de cada upgrade. No interfiere con el VACUUM INTO de Borg — son dos snapshots con semánticas distintas.

### 9.3. Restore (resumen)

```bash
# 0. Asumiendo Pi recién instalada y borg/borgmatic operativo.
# 1. Recrear el árbol de directorios (§3.2 + §3.3).
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/stash \
  /mnt/hd2t/services/stash/config \
  /mnt/hd2t/services/stash/blobs \
  /mnt/hd2t/services/stash/cache
sudo install -d -o homelab -g media -m 2775 \
  /mnt/hd5t/stash \
  /mnt/hd5t/stash/library \
  /mnt/hd5t/stash/metadata \
  /mnt/hd5t/stash/previews \
  /mnt/hd5t/stash/generated

# 2. Listar archivos disponibles.
sudo borgmatic list

# 3. Extraer SOLO los datos de Stash del último archivo.
sudo borgmatic extract \
  --archive latest \
  --path mnt/hd2t/services/stash/config \
  --destination /
sudo borgmatic extract \
  --archive latest \
  --path mnt/hd2t/services/stash/blobs \
  --destination /
sudo borgmatic extract \
  --archive latest \
  --path mnt/hd5t/stash/metadata \
  --destination /

# 4. Verificar permisos.
sudo chown -R 1000:1000 /mnt/hd2t/services/stash/{config,blobs,cache}
sudo chown -R 1000:1100 /mnt/hd5t/stash/{generated,metadata,previews}
sudo find /mnt/hd5t/stash -type d -exec chmod 2775 {} \;

# 5. Re-poblar /mnt/hd5t/stash/library/ con la fuente original
#    (rsync desde otro disco, restore de un backup offsite del library
#    si existiera, etc.). Sin esto, las rutas en stash-go.sqlite
#    apuntarán a ficheros inexistentes.

# 6. Levantar Stash.
cd ~/homelab/stacks/stash
docker compose --env-file /mnt/hd2t/services/stash/.env up -d

# 7. Validar:
# - Login con la cuenta admin (password de antes del desastre).
# - Settings > Library > Folders sigue mostrando /data.
# - Listing de scenes vuelve.
# - Settings > Tasks > Scan: detecta los ficheros que NO encuentra y los
#   marca como "missing" si el restore de library/ está parcial.
# - Settings > Tasks > Generate (re-poblar /mnt/hd5t/stash/generated/
#   tras el restore — 24–48 h para 10 000 scenes).
```

### 9.4. Smoke test mensual de restore

[`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §10 fija un drill mensual de restore. Para Stash:

```bash
# En un directorio temporal (NO sobre la instalación viva):
mkdir -p /tmp/stash-restore-test
cd /tmp/stash-restore-test

sudo borgmatic extract \
  --archive latest \
  --path mnt/hd2t/services/stash/config/stash-go.sqlite \
  --destination .

# Verificar que la BD es válida.
sudo apt-get install -y sqlite3  # si no está
sqlite3 ./mnt/hd2t/services/stash/config/stash-go.sqlite \
  'SELECT COUNT(*) FROM scenes; SELECT COUNT(*) FROM performers; SELECT COUNT(*) FROM tags;'
# Esperado: tres números enteros (cantidades indexadas).

# Validar integridad estructural.
sqlite3 ./mnt/hd2t/services/stash/config/stash-go.sqlite \
  'PRAGMA integrity_check;'
# Esperado: ok

rm -rf /tmp/stash-restore-test
```

---

## 10. Operaciones cotidianas

### 10.1. Upgrade automático (Watchtower)

Stash lleva `com.centurylinklabs.watchtower.enable: "true"` (§4). Watchtower comprueba semanalmente; cuando hay un nuevo digest del tag pinned, ejecuta el `pre-update` (snapshot de la BD) + `pull` + `up -d`. **Pero**: como el tag está pinned a `v0.27.2`, Watchtower no actualiza versiones nuevas a no ser que el operador edite `.env`.

**Upgrade manual de versión** (cambio de tag, p. ej. v0.27.2 → v0.28.0):

```bash
# 1. Leer las release notes: https://github.com/stashapp/stash/releases.
#    Buscar "Breaking changes" y "Database migrations".
#    Las migraciones de stash-go.sqlite son forward-only: una vez
#    aplicadas, NO se puede volver al tag anterior sin restaurar la BD
#    desde antes de la migración.

# 2. Editar /mnt/hd2t/services/stash/.env:
sed -i 's/^STASH_IMAGE_TAG=.*/STASH_IMAGE_TAG=v0.28.0/' \
  /mnt/hd2t/services/stash/.env

# 3. Backup ad-hoc del config + blobs ANTES.
sudo borgmatic create --verbosity 1
# (también el snapshot pre-upgrade interno — Stash > Tasks > Backup Database Now).

# 4. Pull + recrear.
cd ~/homelab/stacks/stash
docker compose --env-file /mnt/hd2t/services/stash/.env pull stash
docker compose --env-file /mnt/hd2t/services/stash/.env up -d

# 5. Vigilar el primer arranque tras upgrade (la BD migra schema).
docker compose --env-file /mnt/hd2t/services/stash/.env logs -f stash

# Esperado:
# - "Stash is starting"
# - "Performing migrations to version N" (si toca migrar schema).
# - "Stash is listening on 0.0.0.0:9999"

# 6. Smoke test: login + listing de scenes + reproducción de una.

# 7. Si algo se rompe: rollback.
sed -i 's/^STASH_IMAGE_TAG=.*/STASH_IMAGE_TAG=v0.27.2/' \
  /mnt/hd2t/services/stash/.env
# Restaurar la BD al estado pre-upgrade.
docker compose --env-file /mnt/hd2t/services/stash/.env stop stash
sudo cp /mnt/hd2t/services/stash/config/stash-go.sqlite.pre-upgrade \
        /mnt/hd2t/services/stash/config/stash-go.sqlite
sudo chown 1000:1000 /mnt/hd2t/services/stash/config/stash-go.sqlite
docker compose --env-file /mnt/hd2t/services/stash/.env up -d
```

### 10.2. Añadir contenido nuevo

**Vía A — rsync / Syncthing / drop manual** (la recomendada):

1. Copiar los ficheros nuevos a una subcarpeta de `/mnt/hd5t/stash/library/` desde el host (rsync, Syncthing) o desde Samba (variante opt-in, [`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md) §14.3).
2. **Settings > Tasks > Scan** desde la UI, o vía GraphQL:
   ```bash
   curl -fsS https://stash.lan/graphql \
     -H "ApiKey: $API_KEY" \
     -H "Content-Type: application/json" \
     -d '{"query":"mutation{metadataScan(input:{paths:[\"/data\"]})}"}'
   ```
3. Stash detecta los ficheros nuevos, calcula `phash`/`md5`, los inserta como scenes/images/galleries.
4. (Opcional) **Tasks > Generate** sobre los nuevos para crear sprites/previews.

**Vía B — Auto-scan con `inotify`** (variante opt-in §12.6).

> **Por qué Stash no hace auto-scan por defecto**: el escaneo recursivo de un disco USB 3.0 con miles de ficheros es costoso (5–30 min por TB solo en metadatos del filesystem). Disparar Scan automático en cada cambio inundaría el job runner. El patrón canónico es: añadir contenido en lotes y escanear en lotes.

### 10.3. Forzar reescaneo / re-generate selectivo

Tras movimientos masivos en `library/` o tras corrupción de la tabla `scenes`:

- **Settings > Tasks > Scan with options**:
  - **Generate covers during scan**: marcado.
  - **Calculate MD5 / phash**: marcado (críticos para detección de duplicados; lentos pero re-utilizables si no han cambiado).
- **Tasks > Generate with options**:
  - Marcar SOLO los derivados que faltan (sprites, vtt, etc.).
  - **Overwrite Existing**: solo si la lógica del derivado cambió (raro entre minor versions).

Para limpiar `generated/` por completo (re-generate from scratch):

```bash
docker compose --env-file /mnt/hd2t/services/stash/.env stop stash
sudo find /mnt/hd5t/stash/generated -mindepth 1 -delete
sudo find /mnt/hd5t/stash/previews -mindepth 1 -delete
docker compose --env-file /mnt/hd2t/services/stash/.env start stash
# UI > Tasks > Generate (todo).
```

### 10.4. Limpieza de cache

```bash
# Con Stash corriendo es seguro — Stash regenera lo necesario en
# el siguiente job que necesite cache.
sudo find /mnt/hd2t/services/stash/cache -mindepth 1 -delete

# O parar primero para asegurar (no estrictamente necesario):
docker compose --env-file /mnt/hd2t/services/stash/.env stop stash
sudo find /mnt/hd2t/services/stash/cache -mindepth 1 -delete
docker compose --env-file /mnt/hd2t/services/stash/.env start stash
```

### 10.5. Reset password de admin (perdido el control)

Stash **no** tiene "olvidé contraseña". Si se pierde el password:

```bash
# Detener Stash.
docker compose --env-file /mnt/hd2t/services/stash/.env stop stash

# Editar config.yml y dejar `password:` vacío (string vacío).
sudo sed -i 's|^password: .*|password: ""|' \
  /mnt/hd2t/services/stash/config/config.yml

# Levantar Stash. Con password vacío y username vacío, Stash relanza
# el wizard de bienvenida en el primer acceso.
sudo sed -i 's|^username: .*|username: ""|' \
  /mnt/hd2t/services/stash/config/config.yml
docker compose --env-file /mnt/hd2t/services/stash/.env up -d

# Abrir https://stash.lan → wizard pide username + password nuevos.
# El resto de la BD (scenes, performers, tags) queda intacto.
```

> **Nota**: a diferencia de Calibre-Web, Stash guarda el password en `config.yml` (texto plano del fichero, hash bcrypt como valor) — no en la BD SQLite. Por eso el reset es una edición de YAML.

### 10.6. Logs

```bash
# Stream en vivo (vía Dozzle o `docker compose logs`).
docker compose --env-file /mnt/hd2t/services/stash/.env logs -f stash

# Errores recientes:
docker compose --env-file /mnt/hd2t/services/stash/.env logs --tail=500 stash \
  | grep -iE "level=(error|warn)" | tail -30

# Logs internos persistentes (si log_file configurado en config.yml):
docker exec stash ls -la /root/.stash/stash.log 2>/dev/null
# Por defecto Stash loggea a stdout (y por tanto a docker logs); el
# fichero solo aparece si se fija `log_file: /root/.stash/stash.log`.
```

Subir el loglevel a `Trace` puntualmente desde la UI (cuidado, **muy** verboso):

- **Settings > Logs > Log Level**: `Trace` → Save.
- (Recordar volver a `Info` tras la sesión de debug — `Trace` log-spam puede llenar la partición rápidamente.)

### 10.7. Comportamiento durante mantenimiento

| Situación | Resultado | Mitigación |
|---|---|---|
| `docker compose stop stash` (planificado) | UI muestra "502 Bad Gateway" desde Caddy. Apps externas vía GraphQL reciben `Connection refused` y deben reintentar. | Avisar 1 min antes (raramente crítico). |
| Caddy reload | Las requests reciben `502` momentáneo (~1 segundo); Stash está vivo, los clientes reintentan transparentemente. WebSocket de notificaciones de jobs se cae y se reconecta. | Sin acción. |
| Pi-hole caído | `stash.lan` no resuelve dentro del LAN. | Fallback DNS en clientes ([`../03-red/02-pihole.md`](../03-red/02-pihole.md) §10) o IP directa. |
| Disco hd5t saturado | Stash no puede escribir generated, ni transcodes, ni previews. La lectura de la biblioteca (RO) sigue funcionando. | Monitorización ([`../05-monitorizacion/02-grafana.md`](../05-monitorizacion/02-grafana.md), Node Exporter). Borrar `generated/` (§10.3) o transcodes selectivos. |
| Disco hd2t saturado | Stash no puede escribir BD, blobs, ni cache. Crítico — la UI rompe con "database is locked" o "disk full". | Limpieza de cache (§10.4) y revisión de Borg local (puede haber crecido). |
| `stash-go.sqlite` corrupto | UI rompe con "malformed database". | Restaurar `stash-go.sqlite.pre-upgrade` o el `VACUUM INTO` más reciente (§9.3). Si fue un crash hard, `sqlite3 stash-go.sqlite ".recover" > recovered.sql && sqlite3 new.sqlite < recovered.sql` recupera ~95 % de los registros. |

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Cómo diagnosticar | Remedio |
|---|---|---|---|
| `unable to open database: unable to open database file` al arrancar | Permisos de `/root/.stash` mal o disco saturado | `docker compose logs stash \| tail -50` y `df -h /mnt/hd2t` | `chown -R 1000:1000 /mnt/hd2t/services/stash/{config,blobs,cache}`. Liberar espacio si saturado. |
| Login OK pero biblioteca aparece vacía | Path a la biblioteca mal o no scaneada | Settings > Library > Folders | Comprobar que `/data` está listado. Lanzar Scan. |
| Scan no encuentra ficheros que sí están | Ficheros con extensión no reconocida o permisos read-denied desde el contenedor | `docker exec stash ls -la /data/<subcarpeta>` | Verificar extensión soportada (mp4, mkv, webm, ...). Verificar permisos de lectura como UID 1000:1100. |
| Generate falla con "Out of memory" en sprites | ffmpeg consume RAM con vídeo 4K | `docker stats stash` durante el job | Bajar `parallel_tasks` a 1 en config.yml. |
| Generate produce sprites en negro | El timestamp inicial cae en frames sin contenido (intro negra) | Settings > Interface > "Preview Audio" + Settings > Tasks > Generate Options | Aumentar `preview_exclude_start` en config.yml (e.g., a 3 segundos). |
| Identify no encuentra matches en StashDB | `phash` no calculado o vídeo no en StashDB | Settings > Logs > Filter por "stash-box" | Asegurar Generate completado (calcula phash). Verificar que el contenido está en StashDB. |
| Scrapers community no aparecen tras git clone | Path equivocado o no se hizo "Reload Scrapers" | Settings > Metadata Providers > Scrapers > "Reload Scrapers" | Reload, o reiniciar Stash. |
| Hover preview no funciona en la UI | Previews aún no generados | Settings > Tasks > Generate > marcar Previews | Ejecutar Generate Previews. |
| Reproducción se cuelga a los 5 min en streams largos | Caddy bufferea sin `flush_interval -1` | `curl -i https://stash.lan/scene/<id>/stream` | Verificar el bloque `reverse_proxy` en Caddyfile (§6.1) tiene `flush_interval -1`. |
| GraphQL devuelve 401 con API key correcta | Header con nombre incorrecto (algunas apps envían `X-Api-Key` en lugar de `ApiKey`) | `docker logs stash \| grep -i auth` | Stash espera `ApiKey: <key>` (sin guion ni X-prefix). Ajustar el cliente. |
| Watchtower actualiza pero el contenedor no arranca | Migración de `stash-go.sqlite` falló o tag con bug | `docker compose logs stash \| grep -iE "migration\|error"` | Rollback de tag (§10.1 paso 7) + restaurar `stash-go.sqlite.pre-upgrade`. Reportar a https://github.com/stashapp/stash/issues. |
| `stash-go.sqlite` crece a > 5 GB | `blobs_storage: DATABASE` en lugar de FILESYSTEM | `sqlite3 stash-go.sqlite ".tables"` y revisar tabla `blobs` | Cambiar a `FILESYSTEM` en config.yml + `Tasks > Migrate Blobs`. |
| El PR/PRBypass tras cambiar trusted_proxies sigue mostrando IP de Caddy | `trusted_proxies` mal escrito o sin reiniciar | `docker compose logs stash \| head -20` busca "TrustedProxies" | Verificar YAML correcto, reiniciar contenedor. |
| Performer images / studio logos no se ven en la UI | Permisos de `/blobs` mal o `blobs_storage` no consistente con el directorio | `docker exec stash ls -la /blobs \| head` | Verificar `blobs_path: /blobs` en config.yml + `chown 1000:1000 /mnt/hd2t/services/stash/blobs`. |
| ffmpeg falla con "Permission denied" sobre `/data/<file>` | El UID/GID del contenedor no tiene lectura al fichero | `ls -l /mnt/hd5t/stash/library/<carpeta>/<file>` | Verificar grupo `media` (1100) en el fichero; `chmod g+r` si no. |
| WebSocket de jobs se reconecta cada pocos segundos | Caddy timeout corto en `@websockets` | Logs del navegador → consola | Confirmar el bloque `@websockets` matchea las cabeceras correctas (`header Connection *Upgrade*`). |

---

## 12. Variantes opt-in

### 12.1. Acceso remoto vía Tailscale

Tras desplegar Tailscale en el host ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) y emitir el cert:

```bash
# 1. Generar cert de Tailscale para el host stash.
tailscale cert stash.tailnet.ts.net

# 2. Mover los .crt y .key al bind mount de Caddy.
sudo mv stash.tailnet.ts.net.crt \
  /mnt/hd2t/services/caddy/tailscale-certs/stash.crt
sudo mv stash.tailnet.ts.net.key \
  /mnt/hd2t/services/caddy/tailscale-certs/stash.key

# 3. Descomentar el bloque stash.{$TS_DOMAIN} en el Caddyfile (§6.1).

# 4. Recargar Caddy.
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Tras esto, abrir `https://stash.tailnet.ts.net` desde cualquier dispositivo en el tailnet del operador. La autenticación nativa de Stash funciona idénticamente; las API keys creadas vía LAN siguen siendo válidas.

> **Streaming sobre Tailscale**: la red overlay de Tailscale añade ~5–10 ms de latencia y ~5 % de overhead de cifrado WireGuard. Para 1080p H.264 es transparente; para 4K HEVC en redes domésticas saturadas, conviene reducir el bitrate o forzar transcoding bajo en `Settings > Streaming`.

### 12.2. Authelia con bypass selectivo (para conservar API keys)

**El homelab no pone Authelia delante de Stash por defecto** porque rompería las apps externas que consumen GraphQL con `ApiKey`. Para añadir SSO solo a la UI web manteniendo las apps:

```caddy
# Caddyfile — bloque stash.lan (con bypass)
stash.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    request_body {
        max_size 100MB
    }

    # Bypass Authelia para GraphQL y para streaming de scenes — son
    # las rutas que usan apps externas con ApiKey.
    @bypass {
        path /graphql /graphql/* /scene/*/stream /scene/*/preview /scene/*/sprite /scene/*/vtt /image/* /performer/*/image
    }
    handle @bypass {
        reverse_proxy http://stash:9999 {
            header_up Host {host}
            header_up X-Forwarded-Proto https
            header_up X-Real-IP {remote_host}
            flush_interval -1
        }
    }

    # Resto de rutas (UI web): forward_auth a Authelia.
    @websockets {
        header Connection *Upgrade*
        header Upgrade    websocket
    }
    handle @websockets {
        forward_auth http://authelia:9091 {
            uri /api/verify?rd=https://auth.lan
            copy_headers Remote-User Remote-Groups Remote-Email
        }
        reverse_proxy http://stash:9999
    }

    handle {
        forward_auth http://authelia:9091 {
            uri /api/verify?rd=https://auth.lan
            copy_headers Remote-User Remote-Groups Remote-Email
        }
        reverse_proxy http://stash:9999 {
            header_up Host {host}
            header_up X-Forwarded-Proto https
            header_up X-Real-IP {remote_host}
            flush_interval -1
        }
    }
}
```

> **Por qué SÍ funciona con apps externas en este modo**: las rutas `/graphql` y `/scene/*/stream` (las que usan apps con ApiKey) pasan por `handle @bypass` que **NO** invoca `forward_auth`. Stash las ve directamente con su header `ApiKey` original. Solo la UI web entra por el `handle` final con SSO 2FA.

> **Coste**: el operador paga 2FA solo al entrar a la UI web. Las apps externas siguen con sus API keys nativas Stash (que no tienen 2FA — no soportan TOTP, pero sí caducidad y revocación).

3. **Authelia**: añadir `stash.lan` como dominio protegido en `configuration.yml > access_control.rules` con `policy: two_factor` (siguiendo el patrón del resto del homelab).

### 12.3. DLNA (servidor UPnP/AV)

Stash incluye un servidor DLNA opt-in para reproducir scenes en Smart TVs sin app dedicada:

1. **Settings > DLNA**: marcar "Enable DLNA Server".
2. **Friendly Name**: "Stash @ homelab" (lo que el TV verá en el menú "Fuentes").
3. **Stash > Restart** desde la UI.
4. En el TV, ir a "Fuentes > Servidores multimedia" → debe aparecer "Stash @ homelab".

> **Limitación de red**: DLNA usa multicast UDP que **no atraviesa** la red bridge de Docker. Para que funcione, el contenedor de Stash debe estar en `network_mode: host` o conectado a una red macvlan/host-mode. En el homelab, esto rompe la integración con Caddy (Stash deja de ser accesible por nombre `stash:9999`). La variante opt-in implica:
>
> ```yaml
> # docker-compose.yml — variante DLNA
> services:
>   stash:
>     # ... resto igual ...
>     network_mode: host
>     # Eliminar `networks:` y el bind ports si lo había.
> ```
>
> Y reescribir Caddy para que apunte a `http://localhost:9999` (el contenedor en host network expone su puerto en `localhost` del host). Conlleva exponer el puerto 9999 al host — limitar con `ufw deny 9999` desde fuera del LAN.

### 12.4. Blobs en BD (no recomendado)

Si por alguna razón se prefiere `blobs_storage: DATABASE` (todo dentro de `stash-go.sqlite`):

- **Pros**: una sola fuente de verdad (la BD); no hay que sincronizar `blobs/` aparte.
- **Cons**: la BD crece a varios GB; `VACUUM INTO` y `borg create` se vuelven caros; perder un blob y poder restaurarlo solo significa restore completo de la BD.

Cambio:

1. **Settings > System > Blobs Storage Type**: `DATABASE`.
2. **Tasks > Migrate Blobs** (mueve los blobs de filesystem a BD; tarda con biblioteca grande).
3. Tras la migración, el directorio `/blobs` queda obsoleto (puede borrarse).

> Para volver a FILESYSTEM, repetir en sentido inverso. Stash soporta migración bidireccional sin pérdida.

### 12.5. Auto-scan con `inotify` (opt-in avanzado)

Stash no tiene watcher integrado, pero se puede orquestar con un sidecar `inotifywait`:

```bash
# Sidecar manual (no como contenedor; cron del host).
sudo apt-get install -y inotify-tools

cat <<'EOF' | sudo tee /usr/local/bin/stash-autoscan.sh
#!/bin/bash
# Vigila /mnt/hd5t/stash/library y dispara Scan cuando aparezca un
# fichero nuevo (close_write) o se mueva uno (moved_to).
# Debounce de 5 minutos: agrupa múltiples cambios.

API_KEY=<api-key-stash>
LIBRARY=/mnt/hd5t/stash/library
DEBOUNCE_LOCK=/tmp/stash-scan.lock

inotifywait -m -r -e close_write,moved_to "${LIBRARY}" --format '%w%f' |
while read -r FILE; do
  if [ -f "${DEBOUNCE_LOCK}" ] && [ "$(($(date +%s) - $(stat -c %Y "${DEBOUNCE_LOCK}")))" -lt 300 ]; then
    continue
  fi
  touch "${DEBOUNCE_LOCK}"
  curl -fsS https://stash.lan/graphql \
    -H "ApiKey: ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"query":"mutation{metadataScan(input:{paths:[\"/data\"]})}"}' \
    > /dev/null
done
EOF
sudo chmod +x /usr/local/bin/stash-autoscan.sh

# Systemd unit:
cat <<'EOF' | sudo tee /etc/systemd/system/stash-autoscan.service
[Unit]
Description=Stash auto-scan trigger via inotify
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/local/bin/stash-autoscan.sh
Restart=always
RestartSec=10
User=homelab

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now stash-autoscan
```

> **Por qué no por defecto**: añade un servicio extra del host (no en Docker), depende de inotify funcionando bajo USB 3.0 (a veces inestable con discos externos), y multiplica la probabilidad de falsos positivos durante operaciones masivas (rsync de 10 000 ficheros lanza 10 000 close_write y aunque haya debounce, el primer batch dispara Scan completo). Para uso doméstico, scan manual cada vez que se añade contenido es más simple.

### 12.6. Plugins de la comunidad

Stash tiene un sistema de plugins (Python/JS) instalables vía:

1. **Settings > Plugins > Available Plugins** lista los publicados en [stashapp/CommunityScripts](https://github.com/stashapp/CommunityScripts).
2. Click "Install" en los deseados (popular: `phashScene`, `Renamer`, `pathParser`, `tagger`).
3. Algunos plugins exigen permisos extra (`Files`, `Stash`, `Files-write`); leer el README antes de aceptar.
4. Tras la instalación, los plugins viven en `/root/.stash/plugins/<plugin_name>/` (mapeado a `/mnt/hd2t/services/stash/config/plugins/`) y entran en backup natural.

> **Plugins con dependencias Python**: algunos plugins requieren `pip install <paquete>`. Stash no incluye un Python con gestión de paquetes — la imagen es solo el binario Go + ffmpeg. Para plugins Python, usar la imagen `stashapp/stash-base` (mayor) o instalar dependencias bajo `/root/.stash/plugins/<plugin>/.venv/`.

### 12.7. Backup offsite del library/ (opt-in personal)

Por defecto, `/mnt/hd5t/stash/library/` **no** entra en el repo Borg principal. Si el operador quiere backup offsite del contenido masivo:

```yaml
# Añadir un segundo repositorio en borgmatic.yml (../07-backups/02-borgmatic.md §3.2):
repositories:
  - path: /mnt/hd2t/backups/borg-stash
    label: stash-library
  - path: rclone:b2:homelab-borg-stash
    label: stash-library-offsite

source_directories:
  - /mnt/hd5t/stash/library
```

**Coste estimado**: para 5 TB en Backblaze B2 Cloud Storage, ~$30/mes (a $6/TB/mes). Bandwidth de upload una vez (vía rclone) + cualquier cambio incremental (mucho menos).

> **Decisión personal**: el contenido de Stash suele ser reemplazable (mediante re-descarga). El operador valora si los $30/mes compensan el tiempo de re-construir la biblioteca tras un fallo total de hd5t. Para libraries con contenido propio (filmaciones personales, fotos), backup offsite es no negociable; para contenido descargado, suele ser opcional.

---

## Referencias

- **Documentación oficial**: https://docs.stashapp.cc/
- **Repositorio principal**: https://github.com/stashapp/stash
- **Imagen Docker**: https://hub.docker.com/r/stashapp/stash
- **Release notes upstream**: https://github.com/stashapp/stash/releases
- **CommunityScrapers**: https://github.com/stashapp/CommunityScrapers
- **CommunityScripts (plugins)**: https://github.com/stashapp/CommunityScripts
- **StashDB (base comunitaria)**: https://stashdb.org/
- **API GraphQL playground**: `https://stash.lan/graphql` (en GET, devuelve la UI Apollo).
- **Discord de la comunidad**: https://discord.gg/2TsNFKt8X6
- **Subreddit**: https://www.reddit.com/r/stashapp/

**Documentos del homelab relacionados**:

- [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md) §6 — `hd5t` dedicado a Stash.
- [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §3 — layout de `/mnt/hd5t/stash/{library,metadata,previews,generated}/`, permisos.
- [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) — convenciones de `docker-compose.yml`, red `homelab`, `PGID=1100`.
- [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 — Stash incluido en upgrades automáticos (categoría "stateless o de lectura ligera").
- [`../03-red/02-pihole.md`](../03-red/02-pihole.md) — DNS local `stash.lan`.
- [`../03-red/04-caddy.md`](../03-red/04-caddy.md) — reverse proxy, snippets `lan_internal_tls`, `security_headers`, `tailscale_tls`.
- [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) — acceso remoto sin port forwarding.
- [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) — SSO/2FA opcional con bypass selectivo (§12.2).
- [`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md) — agrupación de logs por `dev.dozzle.group: "media"`.
- [`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md) §14.3 — share opt-in `[stash]` para acceder al `library/` desde Windows/Mac.
- [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §11 — política sobre el contenido masivo de hd5t (opcional offsite).
- [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.7 — exclusión específica de Stash (`cache`, `generated`, `previews`, `library`).
- [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.8 — patrón de backup para servicios SQLite simples (Stash incluido).
- [`./01-jellyfin.md`](./01-jellyfin.md) — el servidor multimedia hermano para vídeo "general" (RO library, BD propia, sin scrapers comunitarios). Stash y Jellyfin son **complementarios**: Jellyfin para reproducción tipo TV, Stash para gestión avanzada de catálogo + metadata + duplicados.
- [`./02-navidrome.md`](./02-navidrome.md) — el servidor de música hermano (RO library, API Subsonic, sin escritura).
- [`./03-audiobookshelf.md`](./03-audiobookshelf.md) — el servidor de audiolibros hermano (RO library, BD propia, auth nativa).
- [`./04-calibre-web.md`](./04-calibre-web.md) — el servidor de ebooks hermano (RW library, BD propia + BD de Calibre, OPDS + Kobo Sync).
