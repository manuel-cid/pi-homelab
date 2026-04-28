# Stash

## Descripción

Con `01-jellyfin.md`, `02-navidrome.md`, `03-audiobookshelf.md` y `04-calibre-web.md` aplicados, el homelab cubre vídeo general, música, audiolibros, podcasts y libros electrónicos, todos bajo `/mnt/hd2t/media/...` y servidos por catálogos web autenticados. Queda un último catálogo, conscientemente separado del resto: el **multimedia personal especializado** que el operador mantiene fuera del catálogo "familiar" de Jellyfin. Este catálogo:

- Es **voluminoso** (decenas a cientos de TiB potenciales si crece): un `1080p` de 30 minutos puede pesar 1–3 GiB; varios miles de ficheros llenan rápidamente cualquier HDD.
- **Comparte estructura interna con bibliotecas multimedia genéricas** pero su modelo de datos es completamente distinto: en lugar de "películas y series" con metadatos de TMDb, maneja **escenas, performers (actores/actrices), studios, tags, galleries y movies** con metadatos descargados de bases de datos especializadas (StashDB, ThePornDB, PIDB) que Jellyfin no entiende.
- Por **decisiones de privacidad y aislamiento** (separar el catálogo personal del catálogo compartido del hogar, aislar I/O cuando se hace un escaneo masivo, mantener el dispositivo de almacenamiento desconectable físicamente), el homelab le dedica un disco entero, **`hd5t`** (5 TB, USB 3.0), reservado en exclusiva. Ningún otro servicio escribe ahí (`docs/01-sistema/04-estructura-directorios.md`).

**Stash** es el servidor open source que implementa este modelo: catálogo web auto-hospedado para una biblioteca multimedia personal con metadatos propios. Está escrito en Go (backend) + React (frontend), usa SQLite (`stash-go.sqlite`) como BBDD, ffmpeg para inspeccionar/transcodificar ficheros, y un sistema de **scrapers** YAML/JS que el usuario instala desde el repositorio comunitario `CommunityScrapers` (GitHub) para cada sitio/base de datos que quiera indexar.

Su rol concreto en el homelab:

1. **Catalogar** la biblioteca multimedia que vive en `/mnt/hd5t/stash/library/`: escanea recursivamente, calcula hashes (`oshash`, MD5, perceptual hash), extrae duración/resolución/codec/bitrate via ffprobe, y crea un registro por escena/imagen/galería en la BBDD.
2. **Enriquecer con metadatos**: aplica scrapers para descargar título, performers, studio, fecha, tags, sinopsis y URL de carátula desde bases de datos especializadas, vinculando cada escena con el grafo de performers/studios/tags.
3. **Generar previews y miniaturas**: por cada escena ejecuta ffmpeg para producir (a) un **screenshot** (frame único), (b) una **preview** (clip MP4 de 15–60 s con N tiles), (c) un **sprite** (imagen tile + VTT para scrub-bar) y (d) una **markdown phash** (perceptual hash para detectar duplicados). Todo este material derivado vive en `/mnt/hd2t/apps/stash/generated/` (separado del `library/` original).
4. **Servir** vía:
   - **UI web** propia, con buscador rico (filtros por tags, performers, studio, rating, resolución, bitrate, duración, fecha de añadido…) y reproductor HTML5 con `Theater Mode`, en `https://stash.${DOMAIN_LAN}/` y `https://stash.${DOMAIN_TS}/`.
   - **DLNA / interfaz Subsonic / OPDS**: **no aplica** (Stash no implementa estos protocolos).
   - **GraphQL API** (`/graphql`) consumida por aplicaciones cliente terceras (Stash-Box, Stash-Tools, scrapers externos) y por el propio frontend.
5. **Detectar duplicados** por perceptual hash, ofrecer flujo de fusión (merge) y limpieza.
6. **Mantener un cuaderno de tags y performers curado**: las edicions manuales del operador (corregir nombres, fusionar dos performers que la BBDD origen tenía duplicados, añadir tags propios) se conservan en la BBDD interna.

Lo que este documento **no** decide:

- **Qué bases de datos de metadatos suscribir**: depende del operador. Se recomiendan los scrapers comunitarios genéricos del repo `CommunityScrapers` y, opcionalmente, una credencial de **StashDB** (`https://stashdb.org/`, base abierta y comunitaria); el operador decide cuáles habilitar.
- **Migración desde otra herramienta** (PussyDB, MyAdultDataExplorer, hojas de cálculo): fuera de alcance. Stash importa CSV bajo demanda con una herramienta externa (`stash-import`); no se documenta aquí.
- **Indexar también `/mnt/hd2t/media/...`**: **no**. La biblioteca de Stash es exclusiva de `/mnt/hd5t/stash/library/`. Mezclar con el catálogo "familiar" de Jellyfin rompería las dos políticas: la de privacidad (Stash separado por diseño) y la de aislamiento de I/O (`hd5t` solo para Stash).
- **Authelia delante de Stash**: descartado por las mismas razones que JF/ND/ABS/CW (clientes API, GraphQL externo, sesiones cookie nativas), ver "Decisión: autenticación".
- **DLNA / casting a Chromecast desde Stash**: Stash no implementa DLNA y el cast HTML5 desde la UI requiere certificado válido (CA interna) en el receptor, lo que rara vez ocurre. Política: reproducción en navegador o app cliente terceira.
- **Reproducción remota desde móvil sin tailnet**: descartado por alcance del homelab. Tailscale es el único acceso fuera de la LAN.
- **Plugins de gestión de descargas** (whisparr, equivalente a sonarr/radarr para este catálogo): pertenece a una hipotética Fase 10 ampliada, no aquí. Stash en este documento solo cataloga lo que ya está en `/mnt/hd5t/stash/library/`.
- **Cifrado en reposo del disco hd5t**: el plan del homelab no contempla LUKS por defecto (`docs/00-hardware/03-preparacion-discos.md`). Si el operador lo necesita, ver "Decisiones que no se toman" para reabrirlo.

Cuando este documento se haya aplicado, el operador puede:

- Abrir `https://stash.${DOMAIN_LAN}/` desde la LAN (con CA interna instalada) o `https://stash.${DOMAIN_TS}/` desde el tailnet, completar el setup inicial (apuntar a `/library`, crear usuario admin, habilitar autenticación), e iniciar el primer escaneo.
- Tener al menos los scrapers oficiales del repo `CommunityScrapers` instalados y, opcionalmente, una `Stash-Box` configurada (StashDB) con su API key.
- Ver el catálogo poblado tras el primer escaneo: cada escena con su screenshot, preview, sprite y metadatos descargados (cuando el scraper acertó).
- Confirmar que los datos están **separados por disco**: la **biblioteca** vive en `hd5t` (no se respalda) y el **estado del servicio** (BBDD, `generated/`, `cache/`, `config/`) vive en `hd2t` (sí se respalda, ver "Backup").
- Confirmar que `docker compose down && up -d` no pierde nada (catálogo, ediciones manuales, ratings, `o-counter`, tags personalizados).

> **Recordatorio de alcance**: Stash es **solo LAN + tailnet**. No hay exposición a internet, ni DDNS, ni puertos abiertos en el router. El acceso fuera de casa va por Tailscale. Las bases de datos de metadatos externas (StashDB, ThePornDB) las consume Stash en **salida** (cliente HTTP a un endpoint público); ningún tercero entra al servidor.

> **Sobre la naturaleza de la biblioteca**: este documento es deliberadamente neutral en cuanto al contenido. Stash es una herramienta de catalogación; lo que el operador almacene en `/mnt/hd5t/stash/library/` y los scrapers que active son responsabilidad suya, dentro de la legalidad aplicable. La política operativa del homelab (privacidad, aislamiento, no-respaldo del bulk) es la única decisión técnica que se toma aquí.

---

## Requisitos Previos

- **Fase 0** completa: `hd5t` (5 TB) particionado y montado en `/mnt/hd5t` con `LABEL=hd5t`, opciones `noatime,nofail` en `/etc/fstab` (`docs/00-hardware/03-preparacion-discos.md`).
- **Fase 1** completa: hostname `pi5`, zona horaria `Europe/Madrid`, **grupo `media` con GID 1100** y `homelab` miembro de él (existirá pero **no se usa** en Stash; el catálogo es propiedad exclusiva del operador), y la jerarquía `/mnt/hd5t/stash/library/` ya creada con owner `homelab:homelab`, modo `0750` (`docs/01-sistema/04-estructura-directorios.md`).
- **Fase 2** completa: Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convención `stacks/<svc>/`; `.env` global con `TZ`, `PUID=1000`, `PGID=1000`, `DOMAIN_LAN`, `DOMAIN_TS` si aplica.
- **Fase 3** completa, en particular:
  - Pi-hole con `address=/lan/192.168.1.10` (cubre `stash.${DOMAIN_LAN}` automáticamente).
  - Caddy desplegado y los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` en `Caddyfile`.
  - Tailscale operativo y, si se quiere `stash.${DOMAIN_TS}`, `tailscale cert` activo (`03-red/05-tailscale.md`).
- **Fase 4** completa: Authelia desplegado (aunque Stash queda en `bypass`, ver "Decisión: autenticación").
- **Fase 7** opcional pero recomendable: Borgmatic operativo, para incluir `/mnt/hd2t/apps/stash/` en T1 (la BBDD) y T2 (`generated/`, opcional).
- **Documentos `01-jellyfin.md`, `02-navidrome.md`, `03-audiobookshelf.md` y `04-calibre-web.md` aplicados**: no son bloqueantes técnicos, pero las decisiones comunes de la Fase (LSIO/upstream según servicio, bridge `homelab`, watchtower deshabilitado por servicio, healthcheck, `bypass` en Authelia, drop-ins por servicio en Caddy) ya están tomadas allí; aquí se aplican igual.
- Disco `hd5t` con espacio suficiente para la biblioteca (variable; el operador dimensiona según su catálogo).
- Disco `hd2t` con al menos **40–60 GiB libres reservados** para `apps/stash/`: `config/` ~50 MiB, `metadata/` ~100 MiB–1 GiB, `cache/` ~1–10 GiB, **`generated/` 5–50 GiB típicos** (sprites + previews crecen lineal con el número de escenas; ~3–10 MiB por escena).
- Operador con la **CA interna instalada** en navegador.

Comprobaciones rápidas:

```bash
# La red Docker compartida y Caddy
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok
docker ps --filter name=caddy --format '{{.Names}} {{.Status}}'

# DNS interno resuelve stash.lan
dig +short stash.lan @192.168.1.2
# 192.168.1.10

# hd5t montado y con espacio
findmnt /mnt/hd5t
df -h /mnt/hd5t | awk 'NR==2 {print $4 " libres"}'

# Estructura library/ correcta y owner homelab
stat -c '%a %U:%G' /mnt/hd5t/stash /mnt/hd5t/stash/library
# 750 homelab:homelab
# 750 homelab:homelab

# Estructura apps/stash/ correcta
stat -c '%a %U:%G' /mnt/hd2t/apps/stash /mnt/hd2t/apps/stash/{config,metadata,generated,cache}
# todos: 750 homelab:homelab
```

> **Sobre el grupo `media`**: a diferencia de JF/ND/ABS/CW, Stash **no** monta `/mnt/hd2t/media/` ni necesita el grupo `media`. Su biblioteca vive aislada en `hd5t`, donde el grupo `media` no aplica (la política de `hd5t` es `homelab:homelab`, sin compartir con otros servicios).

---

## Decisión: imagen — `stashapp/stash` (upstream)

A diferencia de Jellyfin, Audiobookshelf y Calibre-Web (que usan LSIO), **Stash solo se publica oficialmente como imagen upstream** del propio proyecto. No hay LSIO build maintenida.

| Imagen | Mantenedor | Tag de referencia | Pros | Contras |
|---|---|---|---|---|
| `stashapp/stash` | Equipo upstream Stash (Docker Hub) | `:v0.27.2` (multi-arch incluyendo arm64) | Imagen oficial, fija a release tag. Incluye `ffmpeg` estático con codecs habituales. UID/GID interno fijos a `1000:1000` desde v0.20+ (alineado con el `homelab` del host). Pequeña (~250 MiB). | No usa s6-overlay como LSIO; el comportamiento de UID/GID no es configurable en runtime: si el operador necesita un UID distinto, hay que reconstruir la imagen. |
| `ghcr.io/stashapp/stash` | Upstream (mirror GHCR) | `:v0.27.2` | Idéntica a la de Docker Hub; útil cuando hay rate limit en Docker Hub. | Lo mismo que arriba. |
| Compilación local desde fuente Go | Operador | n/a | Permite parchear; auditoría exhaustiva. | Mantenimiento manual (cada release Go-build, dependencias C de ffmpeg, perceptual hashing); sobreingeniería en este homelab. |

**Decisión**: `stashapp/stash:v0.27.2`.

Razones:

- **Imagen oficial** mantenida por el equipo upstream, releases coordinados con el binario y la migración de BBDD interna. Las rupturas se anuncian en `https://github.com/stashapp/stash/releases`.
- **UID/GID `1000:1000` por defecto** coincide con el operador `homelab`. No hay pelea de permisos sobre `/mnt/hd5t/stash/library/` ni sobre `/mnt/hd2t/apps/stash/`.
- **Pin a versión completa** (`v0.27.2`), no a `:latest` ni a `:v0.27`. Stash hace bumps de minor que **migran la BBDD SQLite** de forma irreversible: arrancar con `:latest` en una hora baja del operador puede dejar la BBDD migrada a un esquema que no puede revertirse sin restore. Conservador siempre.
- **Watchtower deshabilitado por etiqueta**: `com.centurylinklabs.watchtower.enable: "false"`. Las actualizaciones de Stash se aplican leyendo release notes (mucho cambio en perceptual hashing, scrapers, generación de previews entre minors).

Actualizaciones: `docker compose pull && up -d` después de leer release notes en `https://github.com/stashapp/stash/releases`. **Hacer un snapshot Borg antes** (la migración de BBDD es one-way).

> **Sobre `:latest`**: Stash 0.20 → 0.21 cambió el formato de `oshash` y el orden de columnas en `scenes`; varios homelabs perdieron el `o-counter` y los favoritos al actualizar sin revisar. Pin estricto evita ese tipo de sorpresas.

> **Sobre fork `stashapp/stash-box`**: existe un servicio hermano (`stash-box`) que actúa como base de datos colaborativa de metadatos al estilo MusicBrainz. **No** se despliega aquí. Stash consume `stash-box` remotos (`https://stashdb.org/`) como cliente, no como servidor.

---

## Decisión: networking — bridge `homelab` (sin `ports:`)

Igual que el resto de la Fase 9:

- Stash escucha en `:9999/tcp` dentro del contenedor (puerto por defecto, configurable con `STASH_PORT` pero no se altera).
- **Sin `ports:`** publicados al host: Caddy hace `reverse_proxy http://stash:9999` resolviendo el nombre por DNS interno del bridge.
- UI web, GraphQL API (`/graphql`) y descarga de archivos (`/scene/<id>/stream`) comparten puerto, así que una sola entrada de Caddy cubre todo.
- **Streaming de vídeo** viaja por el mismo puerto. Stash soporta `Range:` requests para que el reproductor HTML5 haga seeking sin descargar el fichero entero; Caddy lo pasa transparentemente.
- **WebSockets** sí se usan: el frontend mantiene un canal `/graphql` upgrade para suscripciones (progreso de jobs, notificaciones de escaneo). Caddy v2 los detecta y los pasa sin configuración extra.
- **No hay mDNS / discovery** que importe; Stash no anuncia nada en multicast.

---

## Decisión: dónde viven los datos y permisos — política de dos discos

El reparto entre `hd5t` y `hd2t` es **el** detalle que distingue a Stash del resto de servicios multimedia. Cuatro tipos de datos:

| Tipo | Dónde | Owner:Group | Modo | Observaciones |
|---|---|---|---|---|
| **Biblioteca multimedia** (ficheros originales) | `/mnt/hd5t/stash/library/` | `homelab:homelab` (`1000:1000`) | `0750` | **El bulk**. Vídeos, imágenes, galleries originales. Stash lo monta **read-only** en operación normal (`:ro`) — ver decisión abajo. **Aislado en hd5t**: ningún otro servicio escribe ahí. **No se respalda** (volumen y reconstituibilidad; ver "Backup"). |
| **Configuración** (`config/`): `config.yml`, scrapers instalados, plugins, sesiones | `/mnt/hd2t/apps/stash/config/` | `homelab:homelab` | `0750` | Pequeño (~50 MiB con todos los scrapers). Crítico para backup. |
| **BBDD + metadatos editados** (`metadata/`): `stash-go.sqlite` (catálogo, performers, tags, ratings, `o-counter`, edits manuales, vinculaciones) | `/mnt/hd2t/apps/stash/metadata/` | `homelab:homelab` | `0750` | **El alma**. Pérdida = re-escaneo + pérdida de toda la curación manual del operador (días/semanas de trabajo). Crítico para backup. |
| **Generated + cache** (`generated/`, `cache/`): sprites, previews, screenshots, transcodes, marker thumbs, perceptual hash precomputado | `/mnt/hd2t/apps/stash/{generated,cache}/` | `homelab:homelab` | `0750` | Regenerable, voluminoso (5–50 GiB típicos). `generated/` se respalda **opcionalmente** (T2/T3): regenerarlo cuesta horas de CPU; el operador decide si vale la pena el coste de Borg. `cache/` no se respalda. |

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| Todo en hd5t | Una ruta, un disco, un montaje | El backup de `metadata/` exigiría respaldar `hd5t`, multiplicando por 100 el tamaño Borg. La política del homelab es **respaldar `hd2t`**. | Descartado. |
| Todo en hd2t | Backup natural | hd2t no tiene espacio para la biblioteca multimedia (2 TB compartidos con todos los servicios). | Descartado por capacidad. |
| **Biblioteca en hd5t (`:ro`), estado del servicio en hd2t** | La biblioteca no entra en Borg (volumen); el catálogo, scrapers, ratings, edits, sí entran. Aislamiento de I/O entre escaneos masivos y resto del homelab. Si hd5t falla, el catálogo (con `path` apuntando a ficheros que ya no existen) sobrevive y se puede re-vincular cuando se restaure la biblioteca. | Dos discos a gestionar, dos rutas distintas en compose. | **Aceptado**. |
| Biblioteca `:rw` (Stash escribe en el `library/`) | Permite "Move on Edit" (Stash puede renombrar/mover ficheros al editar metadatos en la UI). | Cualquier bug o configuración accidental puede mover/borrar ficheros del bulk. La operación de mover ficheros con un disco USB cargado es lenta. | Descartado por defecto; reabrible si el operador necesita la feature explícitamente (entonces cambia `:ro` por `:rw` y desactiva los `Trash dir`). |

Resultado: bind mounts a `/mnt/hd2t/apps/stash/{config,metadata,generated,cache}` con `PUID=1000:PGID=1000`, y bind mount a `/mnt/hd5t/stash/library` montado **read-only** (`:ro`).

> **Por qué `:ro` en `/library`**: es defensa en profundidad. Stash, en operación normal (catalogación, scraping, generación de previews, reproducción), **no necesita escribir en `library/`**. Todo lo que produce (sprites, previews, transcodes) lo escribe en `generated/` (en `hd2t`). Si en el futuro el operador activa "File Naming Hashing → Rename Files" o las features de "Trash" (mover ficheros eliminados a una papelera dentro de la biblioteca), `:ro` lo bloqueará y obligará a una decisión consciente: reconfigurar el bind mount o cambiar la política.

> **Por qué `metadata/` en hd2t y no en `config/`**: Stash separa la BBDD (`metadata/stash-go.sqlite`) de la configuración (`config/config.yml`) por diseño. Mantenerlas en bind mounts distintos permite políticas Borg distintas (ambos en T1, pero rotas independientemente) y restaurar una sin tocar la otra.

> **Por qué `generated/` se respalda opcionalmente**: regenerar previews para una biblioteca de 5.000 escenas en una Pi 5 tarda 24–72 horas de CPU sostenida. Si el operador tolera ese coste post-restore, exclúyelo (T4). Si no, T2.

---

## Decisión: autenticación — Stash nativa, **no** Authelia

Stash tiene autenticación nativa (usuario único + password con hash, sesión cookie en navegador, **API Key** para clientes externos). En la instalación por defecto **viene desactivada** (cualquiera con acceso al puerto puede usar la UI sin loguearse) — se activa explícitamente en Settings → Security.

| Endpoint | Mecanismo de auth |
|---|---|
| UI web (`/`, `/scenes`, `/performers/...`) | Cookie de sesión (single-user) |
| GraphQL API (`/graphql`) | Cookie de sesión **o** header `ApiKey: <key>` |
| Streaming (`/scene/<id>/stream/...`) | Cookie de sesión **o** `?apikey=<key>` en URL |
| Plugin RPC (`/plugin/...`) | Token interno (no usado externamente) |

Meterlo detrás del `forward_auth` de Authelia es contraindicado por las mismas razones que JF/ND/ABS/CW:

| Razón | Impacto |
|---|---|
| **GraphQL con header `ApiKey`** | Aplicaciones cliente (Stash-Tools, scrapers que llaman a la API local desde otro contenedor) usan `ApiKey:` y no mantienen cookies. Authelia, cookie-based, las ve "no autenticadas" y redirige al portal HTML. **Resultado**: APIs rotas. |
| **Streaming con `?apikey=` en URL** | Las URLs que el frontend genera para reproducir incluyen el token; los reproductores externos (mpv, VLC) no llevan cookies. |
| **Suscripciones GraphQL via WebSocket** | Authelia interfiere en el handshake del upgrade `Connection: Upgrade`; las notificaciones de progreso de jobs caen. |
| **Aplicación móvil/escritorio terceira** (Stash-Tools, `Stash Companion`, etc.) | Asumen auth por API Key. Cookie-flow Authelia las descarta. |
| **Scrapers que llaman a stash-box** desde el contenedor | El contenedor sale a internet con su propia configuración (HTTP estándar) y no entiende la sesión Authelia. |

La política sana: **Stash gestiona su propia autenticación**. Compensaciones:

- Stash **no** sale de la LAN/tailnet. Quien quiera atacar el endpoint de login necesita ya estar dentro.
- **Activar la autenticación** durante el primer setup es **obligatorio en este homelab** (Settings → Security → "Username" + "Password"). La instalación viene sin auth por defecto y dejarla así es inaceptable incluso en LAN.
- **API Key generada** desde Settings → Security tras crear el usuario; documentada en gestor de contraseñas. Rotable en cualquier momento (cambia la key, los clientes externos se reconfiguran).
- **Cuenta única**: Stash es **single-user** (sigue habiendo una sola cuenta). Si dos personas del hogar usan Stash, comparten ratings y favoritos. Reabrible: Stash 0.28+ tiene roadmap de multiusuario; por ahora, single-user.
- **`fail2ban` (Fase 4) opcional**: los logs de Stash registran intentos fallidos en `metadata/log/`. Reabrible si se ven ataques.

Reflejo en Caddy: el `Caddyfile` para Stash importa **solo** `lan_tls`, `security_headers`, `healthcheck`; **no** `authelia_two_factor`. En Authelia, `stash.${DOMAIN_LAN}` queda en `bypass`:

```yaml
# stacks/authelia/conf.d/09-stash-bypass.yml
- domain: "stash.{$DOMAIN_LAN}"
  policy: bypass
- domain: "stash.{$DOMAIN_TS}"
  policy: bypass
```

> **Si un día se quiere SSO**: Stash **no soporta** OIDC/LDAP nativamente (al menos hasta v0.27.x). El roadmap habla de multiusuario + auth pluggable a partir de v0.30; reabrible cuando suceda.

---

## Decisión: scrapers de metadatos

Stash sin scrapers es un catálogo en blanco: encuentra ficheros, calcula hashes, pero no sabe nada de "qué es" cada escena. Los **scrapers** son ficheros YAML/JS que enseñan a Stash a extraer metadatos de fuentes externas. Hay tres familias:

| Familia | Cómo funciona | Mantenimiento | Veredicto |
|---|---|---|---|
| **Stash-Box** (StashDB, otras instancias) | API GraphQL pública, búsqueda por hash o por título. Devuelve metadatos estructurados (performers, studio, tags, fecha, scene fingerprint). | Mantenido por la comunidad; StashDB es la instancia abierta principal. Requiere registro gratuito + API key. | **Recomendado**. Es la fuente más limpia. |
| **CommunityScrapers** (`stashapp/CommunityScrapers` GitHub) | Repo comunitario con cientos de scrapers YAML/JS para sitios concretos. Cada scraper define cómo parsear las páginas web del sitio (XPath/regex) o llamar a su API si la tiene. | Activo, PRs casi diarios. Estabilidad variable: un sitio cambia su HTML y el scraper se rompe. | **Recomendado** para complementar Stash-Box donde haga falta. |
| **Scrapers ad-hoc** del operador | Ficheros YAML propios. | Solo el operador. | Reabrible si la fuente que el operador necesita no está cubierta. |

**Decisión**:

1. Suscribir el repo `CommunityScrapers` como fuente estándar (clonado en `config/scrapers/` durante el setup).
2. Configurar **al menos un Stash-Box** (StashDB) en Settings → Metadata Providers → Stash-boxes con la API key del operador.
3. **No** auto-aplicar scrapers a la biblioteca completa de forma automática: el flujo será (a) escanear, (b) seleccionar escenas con metadatos faltantes, (c) ejecutar scraper en lotes manualmente o con tarea programada limitada a los nuevos.

Razones:

- **Coste de red y rate limiting**: Stash-Box / CommunityScrapers tienen rate limits implícitos. Lanzar el scraper sobre 10.000 escenas en paralelo provoca baneos temporales. La política manual / por lote evita ese escenario.
- **Calidad heterogénea**: muchos scrapers fallan en escenas viejas o mal nombradas. Aplicarlos de forma masiva ensucia la BBDD con metadatos parciales que luego el operador tiene que limpiar a mano.
- **Privacidad**: cada scraper hace una request HTTP a un dominio externo. El operador debe ser consciente de qué dominios consulta. La configuración por defecto solo activa los scrapers que el operador habilita explícitamente; ninguno corre antes de eso.

Configuración aplicada:

```yaml
# Stash, Settings → Metadata Providers (post-setup)
Scraper packages source: https://stashapp.github.io/CommunityScrapers/develop/index.yml
Stash-boxes:
  - Name: StashDB
    Endpoint: https://stashdb.org/graphql
    API Key: <copia desde gestor de contraseñas>
```

> **Sobre los scrapers JS**: algunos scrapers comunitarios usan JavaScript (Playwright) para sitios con anti-bot agresivo. Stash los soporta vía `chromium-headless` embebido en la imagen. En arm64 (Pi 5) algunos scrapers JS son lentos (~5 s por escena). Política: usar scrapers YAML cuando exista, JS solo donde sea necesario.

> **Sobre el repo `CommunityScrapers`**: actualizable desde la UI con "Update Available" cuando hay cambios. Política: actualizar manualmente cada 1–2 semanas, leyendo los commits relevantes (sitios que el operador realmente consulta).

---

## Decisión: generación de previews y transcodificación en ARM

Stash usa ffmpeg para tres operaciones distintas, cada una con un perfil de coste muy distinto en una Pi 5:

| Operación | Coste CPU típico (Pi 5) | Cuándo se ejecuta |
|---|---|---|
| **ffprobe** (extraer codec, resolución, duración, bitrate) | ~50 ms por escena | En cada escaneo, una vez por escena nueva. Trivial. |
| **Screenshot único** (1 frame extraído de la mitad temporal) | ~0.5 s por escena | Tras escaneo, si no existe screenshot. Trivial. |
| **Sprite + VTT** (tiles para scrub-bar, ~100 frames distribuidos) | ~5–20 s por escena 1080p | Generación bajo demanda o como tarea de fondo. |
| **Preview clip** (concat de N segmentos cortos, 15–60 s en MP4) | ~30–120 s por escena 1080p | Generación bajo demanda o como tarea de fondo. |
| **Transcodificación** (al reproducir en navegador no compatible con el codec original) | tiempo real → 4× tiempo real para H.264 1080p (sin HW) | Solo al hacer streaming desde la UI a un navegador que no decodifique el codec original. |
| **Phash perceptual** (detección de duplicados) | ~3–10 s por escena | Tarea de mantenimiento, lanzada explícitamente. |

Implicaciones:

1. **Generación masiva tras el primer escaneo**: si la biblioteca tiene 5.000 escenas, generar sprites + previews lleva **24–72 h** de CPU sostenida en la Pi 5 (4 cores Cortex-A76 a 2.4 GHz). Política: lanzar la tarea por la noche, en horas de bajo uso, escalonado a lo largo de varios días.
2. **HW transcoding en Pi 5**: igual que en Jellyfin (`01-jellyfin.md`), el SoC BCM2712 puede decodificar H.264/HEVC por hardware (v4l2-request) y, marginalmente, codificar H.264. Stash **soporta** HW transcoding desde v0.21+ pero la integración es menos madura que en JF: hay reportes de fallos con perfiles HEVC `Main10` y con DV. **Política**: dejar Stash en SW transcode por defecto; los catálogos típicos del operador son 1080p H.264 y casi siempre direct-play en navegador. Si el catálogo crece hacia 4K HEVC y se usa frecuentemente streaming desde apps que no decodifiquen, reabrir HW.
3. **Previews y sprites en hd2t (no en hd5t)**: aunque podrían vivir junto al original, el plan los separa (`generated/` en hd2t) para que (a) el backup de `hd2t` los recoja sin tocar `hd5t`, (b) el bulk de `hd5t` quede solo para originales y (c) si se cambia el HDD de `hd5t`, los previews precomputados sigan en `hd2t`.
4. **Concurrencia**: Stash serializa internamente los jobs de ffmpeg (un único worker por defecto, configurable). **No subir** el worker count en Pi 5 más allá de 1: dos ffmpeg paralelos saturan la CPU y la latencia de la UI cae a segundos.

Configuración aplicada en la UI tras setup:

```yaml
Settings → System → Transcoding:
  Hardware Acceleration: OFF (por defecto; SW)
  Sequential Scanning: ON       # un fichero a la vez
  Parallel Tasks: 1             # un job ffmpeg a la vez
  Preview Generation:
    Audio: enabled
    Segments: 12
    Segment Duration: 1.5s
    Excluded duration: 240s     # primeros y últimos 4 min se excluyen
  Sprite Generation:
    Rows x Cols: 9 x 9
    Width: 160 px
```

> **Sobre `Sequential Scanning`**: ON evita lecturas paralelas en `hd5t` durante el escaneo, que satura el HDD USB. Coste: el escaneo inicial es más lento, pero la latencia del resto del homelab no se ve afectada.

---

## Stack: `stacks/stash/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/stash/docker-compose.yml` | microSD (git) | Stack (servicio `stash`). |
| `stacks/stash/.env.example` | microSD (git) | Plantilla con variables específicas (vacía por defecto; Stash no necesita secretos en env tras el setup inicial). |
| `stacks/caddy/conf.d/09-stash.caddy` | microSD (git) | Drop-in del bloque LAN+tailnet para `stash.${DOMAIN_LAN}` y `stash.${DOMAIN_TS}`. |
| `stacks/authelia/conf.d/09-stash-bypass.yml` | microSD (git) | Fragmento de access_control para añadir bypass de `stash.*`. |
| `/mnt/hd2t/apps/stash/config/` | hd2t | `config.yml`, scrapers instalados, plugins. Owner `homelab:homelab`, modo `0750`. |
| `/mnt/hd2t/apps/stash/metadata/` | hd2t | `stash-go.sqlite` (catálogo, performers, tags, ratings). Owner `homelab:homelab`, modo `0750`. |
| `/mnt/hd2t/apps/stash/generated/` | hd2t | Sprites, previews, screenshots, marker thumbs. Owner `homelab:homelab`, modo `0750`. |
| `/mnt/hd2t/apps/stash/cache/` | hd2t | Caché transitoria (perceptual hash precomputado, scraper cache). Owner `homelab:homelab`, modo `0750`. |
| `/mnt/hd5t/stash/library/` | **hd5t** | Biblioteca multimedia. Owner `homelab:homelab`, modo `0750`. **Read-only** desde Stash. |

### `stacks/stash/docker-compose.yml`

```yaml
# Stash — catálogo multimedia personal del homelab.
# Documentado en docs/09-multimedia/05-stash.md.
#
# Networking: bridge homelab. Caddy hace reverse proxy hacia stash:9999.
# Política de discos:
#   - /mnt/hd5t/stash/library/  -> biblioteca multimedia, READ-ONLY desde Stash.
#   - /mnt/hd2t/apps/stash/...  -> estado del servicio (config, BBDD, generated, cache).

name: stash

networks:
  homelab:
    external: true

services:
  stash:
    image: stashapp/stash:v0.27.2
    container_name: stash
    hostname: stash
    restart: unless-stopped

    networks:
      - homelab

    # NO se publican puertos al host: el acceso humano va por Caddy
    # (https://stash.lan). El GraphQL y el streaming comparten puerto 9999.

    environment:
      TZ: ${TZ}
      # La imagen oficial corre como UID/GID 1000:1000 internamente; coincide
      # con el operador `homelab` del host. PUID/PGID NO son configurables
      # en runtime en esta imagen (a diferencia de LSIO).
      STASH_PORT: "9999"
      STASH_STASH: "/library"
      STASH_GENERATED: "/generated"
      STASH_METADATA: "/metadata"
      STASH_CACHE: "/cache"

    volumes:
      # Configuración (config.yml, scrapers, plugins, sesiones)
      - /mnt/hd2t/apps/stash/config:/root/.stash
      # BBDD SQLite y metadatos editados (alma del servicio)
      - /mnt/hd2t/apps/stash/metadata:/metadata
      # Material generado (sprites, previews, screenshots, marker thumbs)
      - /mnt/hd2t/apps/stash/generated:/generated
      # Cache transitoria (phash, scraper cache)
      - /mnt/hd2t/apps/stash/cache:/cache
      # Biblioteca: READ-ONLY (defensa en profundidad).
      # Si en el futuro se quiere "Move on Edit" o "Trash dir", cambiar
      # a :rw deliberadamente.
      - /mnt/hd5t/stash/library:/library:ro
      - /etc/localtime:/etc/localtime:ro

    healthcheck:
      # /healthz responde 200 cuando el servidor está listo. La imagen
      # oficial NO incluye curl ni wget; se usa el binario stash con
      # un endpoint TCP simple via /dev/tcp.
      test: ["CMD-SHELL", "exec 3<>/dev/tcp/127.0.0.1/9999 && echo -e 'GET /healthz HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3 && head -1 <&3 | grep -q '200 OK'"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 60s

    labels:
      homelab.role: "media-catalog"
      homelab.backup: "true"
      # Watchtower NO actualiza automáticamente: el tag es completo y
      # las migraciones de BBDD entre minors son one-way.
      com.centurylinklabs.watchtower.enable: "false"
```

> **Sobre `/root/.stash` como `config/`**: la imagen oficial busca su `config.yml` en el `$HOME` del usuario interno, que es `/root` (UID 0 dentro del contenedor; mapeado al UID 1000 del host vía namespaces si Docker rootless, o a UID 0 host si rootful — en este homelab Docker es rootful y el contenedor corre como UID 1000 internamente, así que `/root/.stash` se accede como ese UID). Bind mount sobre `/root/.stash`.

> **Sobre el healthcheck con `/dev/tcp`**: la imagen oficial es Alpine slim sin `curl` ni `wget` ejecutables en `PATH`. La construcción `exec 3<>/dev/tcp/...` es un truco bash puro que sí funciona en Alpine (sustituye `curl -fsS http://.../healthz`). Si en el futuro la imagen añade curl, sustituir por `["CMD", "curl", "-fsS", "http://127.0.0.1:9999/healthz"]`.

> **Sobre el bind mount `:ro` sobre `library`**: si Stash intenta escribir (al activar accidentalmente "Move on Edit"), recibe `EROFS` y la operación falla limpiamente. Mensaje de error en logs: claro y atribuible. Cambiar a `:rw` solo cuando se haya tomado la decisión consciente de delegar la organización del bulk a Stash.

### `stacks/stash/.env.example`

```bash
# stacks/stash/.env.example
# Stash no requiere variables propias por defecto. Las generales (TZ,
# DOMAIN_LAN, DOMAIN_TS) vienen del .env GLOBAL del homelab.
#
# Si en el futuro se activan integraciones que requieran secretos
# (claves de Stash-Box, de scrapers privados, plugin tokens), añadir
# aquí. Nada por ahora.
```

### Drop-in de Caddy: `stacks/caddy/conf.d/09-stash.caddy`

```caddy
# /etc/caddy/conf.d/09-stash.caddy — bloques de Stash.
# Documentado en docs/09-multimedia/05-stash.md.
#
# IMPORTANTE: NO se importa authelia_two_factor (decisión documentada en
# "Decisión: autenticación"). Stash gestiona su propio login y la API
# Key vía header propio.

# ---- Acceso LAN ------------------------------------------------------------
stash.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    reverse_proxy http://stash:9999 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # Caddy v2 detecta y pasa WebSockets (suscripciones GraphQL,
        # progreso de jobs en tiempo real) automáticamente.

        # Streams de vídeo pueden ser largos; subir read/write timeouts.
        # La generación de previews puede mantener una request abierta
        # 1-2 min mientras el cliente espera el sprite.
        transport http {
            read_timeout 24h
            write_timeout 24h
        }
    }

    # Subir el límite de body para uploads desde la UI (instalación de
    # scrapers manuales como ZIP, plugins, imágenes de portada). 50 MiB
    # cubre todos los casos prácticos.
    request_body {
        max_size 50MB
    }
}

# ---- Acceso Tailscale ------------------------------------------------------
# Solo se materializa si DOMAIN_TS está definido (tailnet con tailscale cert).
stash.{$DOMAIN_TS} {
    tls {
        get_certificate tailscale
    }
    import security_headers
    import healthcheck

    reverse_proxy http://stash:9999 {
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
        max_size 50MB
    }
}
```

> **Sobre `read_timeout 24h`**: como en Jellyfin, los streams HTTP de Stash mantienen la conexión abierta durante toda la reproducción. El default de Caddy (~30 s) cortaría una sesión larga; 24 h cubre cualquier caso práctico.

### Fragmento de Authelia: `stacks/authelia/conf.d/09-stash-bypass.yml`

```yaml
# stacks/authelia/conf.d/09-stash-bypass.yml
# Excluir Stash del control de acceso de Authelia.
# Se incluye desde stacks/authelia/configuration.yml mediante el mecanismo
# de merge documentado en 04-seguridad/01-authelia.md.

- domain: "stash.{$DOMAIN_LAN}"
  policy: bypass
- domain: "stash.{$DOMAIN_TS}"
  policy: bypass
```

### Crear directorios y desplegar

```bash
# 1) Verificar prerequisitos de discos (Fase 0/1).
findmnt /mnt/hd5t >/dev/null || {
    echo "ERROR: /mnt/hd5t no está montado. Aplicar 00-hardware/03-preparacion-discos.md."
    exit 1
}
[ -d /mnt/hd5t/stash/library ] || {
    echo "ERROR: /mnt/hd5t/stash/library no existe. Aplicar 01-sistema/04-estructura-directorios.md."
    exit 1
}

# 2) Crear directorios persistentes en hd2t (idempotente).
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/stash
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/stash/config
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/stash/metadata
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/stash/generated
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/stash/cache

# 3) Confirmar que la biblioteca tiene el owner correcto.
stat -c '%u:%g %a' /mnt/hd5t/stash /mnt/hd5t/stash/library
# 1000:1000 750
# 1000:1000 750

# 4) Materializar Caddy drop-in y fragmento de Authelia.
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/09-stash.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/09-stash.caddy

install -o homelab -g homelab -m 0644 \
    stacks/authelia/conf.d/09-stash-bypass.yml \
    /mnt/hd2t/apps/authelia/etc/conf.d/09-stash-bypass.yml

# 5) .env del stack (vacío en esta fase pero lo creamos para coherencia).
cp stacks/stash/.env.example stacks/stash/.env
chmod 0600 stacks/stash/.env

# 6) Levantar el stack.
docker compose \
    -f stacks/stash/docker-compose.yml \
    --env-file .env --env-file stacks/stash/.env \
    up -d

# 7) Recargar Caddy y Authelia para tomar drop-ins.
docker exec caddy caddy validate --config /etc/caddy/Caddyfile && \
    docker kill --signal=SIGUSR1 caddy
docker exec authelia kill -HUP 1 || \
    docker compose -f stacks/authelia/docker-compose.yml restart authelia
```

Tras `up -d`:

```bash
docker ps --filter name=stash
# CONTAINER ID  IMAGE                        STATUS
# ...           stashapp/stash:v0.27.2       Up 1 minute (healthy)

docker logs stash --tail 30
# ... time="..." level=info msg="stash version: v0.27.2 ..."
# ... time="..." level=info msg="using config file: /root/.stash/config.yml"
# ... time="..." level=info msg="starting webserver on port 9999"

# Confirmar puertos NO publicados al host
ss -tlnp | grep ':9999 ' && echo "WARN: stash publicando al host" || echo "OK: stash NO publica al host"

# Probar el endpoint vía Caddy
curl -ksI https://stash.lan/healthz
# HTTP/2 200
```

---

## Configuración

### 1) Setup inicial

Desde un cliente de la LAN con la CA interna instalada:

```text
1. Abrir https://stash.lan/
2. Stash muestra la "Welcome page":
   a. "Stash directory location": auto-detectado en /root/.stash (montado
      desde /mnt/hd2t/apps/stash/config). Aceptar.
   b. "Where will Stash store generated content?":
      - Generated: /generated
      - Metadata:  /metadata
      - Cache:     /cache
      - Blob path (interno): dejar default
   c. "Add directories to your library":
      - + Add: /library
      - (no añadir más; /library es la única ruta de la biblioteca)
   d. Submit. Stash crea config.yml y reinicia internamente.

3. Tras el reinicio, abrir Settings → Security:
   a. Username: <usuario propio>
   b. Password: gestor de contraseñas; mínimo 16 caracteres
   c. Save. La sesión actual se invalida; Stash exige login inmediato.

4. Loguear con las credenciales que se acaban de crear.

5. Settings → Security → "Generate New API Key":
   - Copia la API key generada al gestor de contraseñas.
   - Etiquétala como "Stash API Key (LAN)".
```

> **Activación de auth obligatoria**: la instalación viene **sin autenticación** por defecto. Dejar Stash sin auth en el homelab es inaceptable, incluso en LAN, porque el catálogo personal queda accesible para cualquier dispositivo de la red doméstica (TVs, invitados con WiFi, IoT comprometido). Activar auth es el primer paso post-deploy.

> **Stash es single-user**: solo hay una cuenta. Si dos personas comparten el homelab y ambas usan Stash, comparten ratings y `o-counter`. Reabrible cuando v0.30+ traiga multiusuario.

### 2) Configuración básica

`Settings → Library`:

```text
- Library Paths:
  /library  (la única; corresponde al bind mount /mnt/hd5t/stash/library)
- Excluded patterns: añadir patrones a ignorar (ej. .recycle, .DS_Store,
  thumbs.db, @eaDir si llega de un NAS Synology).
- File naming: dejar default. NO activar "Rename files" (requiere :rw).
```

`Settings → System → Transcoding`:

```text
- Hardware Acceleration:    OFF
- Transcode CPU codec:      libx264 (default)
- Streaming Browsers:       MP4 (compatibilidad universal)
- Sequential Scanning:      ON
- Parallel Tasks:           1
- File-format-based H.264 streaming: ON
```

`Settings → System → Preview/Sprite Generation`:

```text
- Image Preview:        ON
- Preview audio:        ON
- Preview segments:     12
- Preview segment dur:  1.5
- Preview excluded dur: 240
- Sprite cols/rows:     9 / 9
- Sprite width:         160
```

`Settings → Interface`:

```text
- Locale:                  Español (España)
- Show studio as text:     opcional
- Wall preview type:       Animated
- Slideshow delay:         5 s
```

### 3) Instalar scrapers comunitarios

```text
Settings → Metadata Providers → Available Scraper Packages:
- Source URL: https://stashapp.github.io/CommunityScrapers/develop/index.yml
- Click "Install" en los scrapers concretos que vaya a usar el operador
  (NO "Install All"; cada scraper instala dependencias y consume espacio).
- Los scrapers quedan en /root/.stash/scrapers/<scraper-name>/.
```

> **Sobre "Install All"**: existen >300 scrapers comunitarios. Instalar todos consume ~150 MiB de `config/` y arranque más lento (Stash los enumera al boot). Política: instalar solo los que el operador usa.

### 4) Configurar Stash-Box (StashDB)

```text
1. Crear cuenta gratuita en https://stashdb.org/ (registro requiere
   invitación; existe un canal Discord de la comunidad para conseguirla).
2. Stashdb.org → Account → API Keys → "Create New" → copiar key.
3. En Stash: Settings → Metadata Providers → Stash-boxes:
   - Name: StashDB
   - Endpoint: https://stashdb.org/graphql
   - API Key: <copia desde gestor>
   - Save.
4. Test: en una escena del catálogo, "Scrape With → StashDB → fingerprint".
   Stash hace lookup por hash; si la escena está en StashDB, devuelve
   metadatos completos.
```

> **Sobre StashDB**: es la base abierta más completa. Su modelo es colaborativo: el operador puede contribuir fingerprints + correcciones (opcional) y mejorar la BBDD comunitaria.

### 5) Primer escaneo

```text
Settings → Tasks → Scan:
- Selected Paths: /library  (todos los subdirs)
- Generate previews: OFF en el primer escaneo
  (se generarán por separado tras revisar)
- Generate covers: ON
- Generate phashes: ON  (para detección de duplicados)
- Click "Scan".
```

El primer escaneo de una biblioteca de 5.000 escenas en `hd5t` (USB 3.0) tarda **2–6 horas** en una Pi 5: el cuello es el cálculo de `oshash` (lectura de los primeros y últimos MiB de cada fichero) y `phash` (decodificación de varios frames por escena). Stash muestra progreso en Tasks → Job Queue.

> **Por qué `Generate previews: OFF` en el primer escaneo**: la generación de previews tarda 30–120 s por escena. Mezclarlo con el escaneo masivo bloquea la BBDD durante días. Política: primero escanear todo (rápido), luego generar previews en lotes.

### 6) Generación masiva de previews y sprites

Tras el escaneo:

```text
Settings → Tasks → Generate:
- Sprites + VTT: ON
- Previews:      ON
- Markers:       ON
- Screenshots:   solo si faltan (ya hay un screenshot por escena del scan)
- Phashes:       ya generadas en el scan
- Click "Generate".
```

Esta tarea **toma 24–72 h** para 5.000 escenas. Lanzarla por la noche; no interrumpir la Pi durante ese tiempo. Stash retoma el job si se cae el contenedor (estado en BBDD).

> **Liberar CPU para otros servicios**: si el operador necesita la Pi para HA/Jellyfin/etc., pausar el job en Tasks. Reanudar cuando se libere.

### 7) Aplicar scrapers a las escenas (manualmente o por lotes)

Para una escena individual: abrir la escena → "Scrape With" → escoger el scraper → confirmar los campos detectados.

Para lotes pequeños: filtrar el catálogo (ej. "escenas sin performer") y usar la opción "Identify" en `Tasks` con un workflow definido (Stash 0.27+).

> **No automatizar el scraping global**: política del homelab. Los scrapers tienen tasas de error y rate limits; aplicarlos a 5.000 escenas en una sola pasada ensucia la BBDD. Política: por lotes, con revisión humana del resultado.

### 8) Operación diaria

| Acción | Comando |
|---|---|
| Ver el log activo | `docker logs stash -f` |
| Reescaneo incremental (tras añadir ficheros a `/library`) | UI: Settings → Tasks → Scan (Stash detecta solo lo nuevo) |
| Reiniciar Stash | `docker compose -f stacks/stash/docker-compose.yml restart stash` |
| Backup manual de la BBDD | `sudo tar czf /mnt/hd2t/backups/stash-snapshot-$(date +%F).tgz -C /mnt/hd2t/apps stash/config stash/metadata` |
| Tamaño actual del estado | `du -sh /mnt/hd2t/apps/stash/{config,metadata,generated,cache}` |
| Tamaño de la BBDD | `du -sh /mnt/hd2t/apps/stash/metadata/stash-go.sqlite*` |
| Verificar integridad de la BBDD | `docker exec stash sqlite3 /metadata/stash-go.sqlite "PRAGMA integrity_check;"` |
| Limpiar `cache/` | `docker compose stop stash && sudo rm -rf /mnt/hd2t/apps/stash/cache/* && docker compose start stash` |
| Forzar regeneración de previews de una escena | UI: escena → Operations → "Generate" |
| Detectar duplicados | UI: Stats → Duplicate Files (requiere `phash` generadas en escaneo previo) |
| Exportar el catálogo a JSON | UI: Settings → Tools → "Export"  (genera ZIP en `metadata/exports/`) |

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/stash/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/stash/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/stash/.env` | microSD | `homelab:homelab` | `0600` | Vacío en este servicio (consistencia con resto de stacks). En `.gitignore`. |
| `/home/homelab/homelab/stacks/caddy/conf.d/09-stash.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy. |
| `/home/homelab/homelab/stacks/authelia/conf.d/09-stash-bypass.yml` | microSD | `homelab:homelab` | `0644` | Fragmento de bypass. |
| `/mnt/hd2t/apps/stash/config/` | hd2t | `homelab:homelab` | `0750` | `config.yml`, scrapers, plugins, sesiones. **Crítico**, se respalda. |
| `/mnt/hd2t/apps/stash/config/config.yml` | hd2t | `homelab:homelab` | `0640` | Configuración principal: rutas, hashing, intervalos, paths de scrapers. |
| `/mnt/hd2t/apps/stash/config/scrapers/` | hd2t | `homelab:homelab` | `0750` | Scrapers comunitarios instalados. ~50–150 MiB. |
| `/mnt/hd2t/apps/stash/metadata/` | hd2t | `homelab:homelab` | `0750` | BBDD + edits manuales. **Crítico**, se respalda en T1. |
| `/mnt/hd2t/apps/stash/metadata/stash-go.sqlite` | hd2t | `homelab:homelab` | `0640` | BBDD principal. ~50 MiB–1 GiB según catálogo. |
| `/mnt/hd2t/apps/stash/metadata/stash-go.sqlite-wal`, `-shm` | hd2t | `homelab:homelab` | `0640` | WAL de SQLite. Snapshot Borg con `.backup` (ver "Backup"). |
| `/mnt/hd2t/apps/stash/metadata/exports/` | hd2t | `homelab:homelab` | `0750` | Exports JSON de la BBDD (manuales). Útil como respaldo extra. |
| `/mnt/hd2t/apps/stash/generated/` | hd2t | `homelab:homelab` | `0750` | Sprites, previews, screenshots, marker thumbs. **Regenerable**, T2/T3 según política. |
| `/mnt/hd2t/apps/stash/generated/scenes/<id>/preview.mp4` | hd2t | `homelab:homelab` | `0640` | Preview clip por escena. ~1–10 MiB. |
| `/mnt/hd2t/apps/stash/generated/scenes/<id>/sprite.jpg` + `.vtt` | hd2t | `homelab:homelab` | `0640` | Sprite + VTT por escena. ~500 KiB–2 MiB. |
| `/mnt/hd2t/apps/stash/cache/` | hd2t | `homelab:homelab` | `0750` | Caché transitoria (phash, scraper). **No se respalda**. |
| `/mnt/hd5t/stash/library/` | **hd5t** | `homelab:homelab` | `0750` | **Biblioteca multimedia**. Bind mount `:ro`. **No se respalda**. |

> **Tamaño esperado**.
> - `config/`: **~50–200 MiB** estable.
> - `metadata/stash-go.sqlite`: **50 MiB** para 1.000 escenas, **~500 MiB–1 GiB** para 10.000+ con muchos performers/tags y embeddings de phash.
> - `generated/`: **~3–10 MiB por escena**. 5.000 escenas = ~25–50 GiB.
> - `cache/`: **<1 GiB** estable.
> - **`library/` en hd5t**: el bulk; depende del catálogo del operador, decenas a miles de GiB.

> **Por qué no microSD**. Stash tiene patrón SQLite intensivo (cada escaneo, cada edit, cada job genera writes), y `generated/` crece a decenas de GiB. La microSD es inviable; los HDDs USB son el destino correcto.

> **Por qué `library/` en hd5t separado**. Política del homelab: **un disco entero para el bulk de Stash, ningún otro servicio comparte hd5t**. Razones documentadas en `docs/01-sistema/04-estructura-directorios.md`: aislamiento de I/O (un escaneo masivo no satura el disco que también aloja la BBDD del resto del homelab), aislamiento del backup (`hd5t` queda fuera del scope Borg por volumen) y posibilidad de desconectar físicamente el disco si el operador lo desea.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/stash/docker-compose.yml`, `.env.example` | Versionados. |
| `stacks/stash/.env` | **NO** versionado (consistencia, vacío hoy). En `.gitignore`. |
| `stacks/caddy/conf.d/09-stash.caddy` | Versionado. |
| `stacks/authelia/conf.d/09-stash-bypass.yml` | Versionado. |
| Decisiones (upstream, bridge, sin Authelia, library `:ro` en hd5t, estado en hd2t, scrapers manuales) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Tier (`07-backups/01-estrategia-backup.md`) | Por qué |
|---|---|---|---|
| `/mnt/hd2t/apps/stash/config/config.yml` | Sí. | T1 | Configuración del servicio + paths + ajustes. Pequeña. |
| `/mnt/hd2t/apps/stash/config/scrapers/` | Sí. | T2 | Scrapers comunitarios. Reinstalables, pero respaldarlos preserva el set exacto que el operador validó. |
| `/mnt/hd2t/apps/stash/config/plugins/` | Sí. | T2 | Plugins instalados. |
| `/mnt/hd2t/apps/stash/metadata/stash-go.sqlite` (snapshot atómico) | Sí. | T1 | **El alma**: catálogo, performers, tags, ratings, `o-counter`, ediciones manuales. **Pérdida = re-escaneo + pérdida total de la curación manual del operador (días/semanas)**. |
| `/mnt/hd2t/apps/stash/metadata/exports/` | Sí. | T2 | Exports JSON (si el operador los genera periódicamente como respaldo extra). |
| `/mnt/hd2t/apps/stash/generated/` | **Opcional** (T2 conservador, T4 si se acepta el coste de regeneración). | T2 / T4 | Sprites + previews. Regenerar tras restore lleva 24–72 h de CPU; si el operador acepta ese coste, exclúyelo. **Política por defecto del homelab**: **excluido (T4)**. La BBDD vincula los `generated/` a IDs por hash de fichero; tras restore de la BBDD, una tarea "Generate (Missing only)" reconstruye lo que falta. |
| `/mnt/hd2t/apps/stash/cache/` | **No.** | T4 | Caché por definición. Regenerable. |
| `/mnt/hd5t/stash/library/` | **No.** | T5 | **Política del homelab**: la biblioteca de Stash es **voluminosa y reconstituible** desde la fuente externa (compras, rips propios, descargas). Respaldarla en Borg multiplicaría el tamaño del repo por uno o dos órdenes de magnitud. La salvaguarda es tener los originales (o un script que sepa volver a obtenerlos) en un soporte distinto, **fuera del homelab**. Documentado en `07-backups/01-estrategia-backup.md` y reafirmado en `00-hardware/03-preparacion-discos.md`. |

Entrada en `borgmatic.yaml` (parche relativo al patrón de `07-backups/02-borgmatic.md`):

```yaml
source_directories:
  # ...
  - /mnt/hd2t/apps/stash/config
  - /mnt/hd2t/apps/stash/metadata

# Excluir lo regenerable y lo voluminoso.
patterns:
  # ...
  - '!/mnt/hd2t/apps/stash/cache'
  - '!/mnt/hd2t/apps/stash/generated'    # política por defecto: regenerable
  - '!/mnt/hd2t/apps/stash/metadata/stash-go.sqlite-wal'
  - '!/mnt/hd2t/apps/stash/metadata/stash-go.sqlite-shm'
  # NUNCA respaldar /mnt/hd5t/* (política global)

# Hooks: snapshot consistente de la BBDD antes del backup.
before_backup:
  - 'docker exec stash sqlite3 /metadata/stash-go.sqlite ".backup ''/metadata/stash-go.sqlite.borg''"'
after_backup:
  - 'docker exec stash rm -f /metadata/stash-go.sqlite.borg'
```

> **Política sobre la BBDD**. Snapshot consistente con `.backup` (atómico) sobre la SQLite con WAL activo. Stash mantiene WAL agresivo durante escaneos: copiar el `.sqlite` en caliente sin `.backup` puede dar una BBDD corrupta. Para un fichero de ~500 MiB, el snapshot tarda 5–15 s.

> **Política sobre `generated/`**. Por defecto **excluido**. Si el operador prefiere respaldarlo (T2), comentar la línea `'!/mnt/hd2t/apps/stash/generated'` en patterns. Trade-off documentado: 25–50 GiB extra en Borg por evitar 24–72 h de regeneración tras restore.

> **Política sobre `/mnt/hd5t`**. **Excluida del backup, sin excepciones**. Si el operador identifica un subconjunto irreemplazable del catálogo (rips propios, contenido único), debe **separarlo** a otra ruta fuera de `hd5t/stash/library/` (por ejemplo, `/mnt/hd2t/personal/...`) y respaldarlo específicamente; el fichero queda fuera de Stash o se referencia desde Stash con un segundo path. La regla "hd5t = solo Stash, sin backup" no admite excepciones tácitas.

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t` y `hd5t`):

```bash
docker compose -f /home/homelab/homelab/stacks/stash/docker-compose.yml up -d --force-recreate
# Stash reusa /mnt/hd2t/apps/stash/{config,metadata,generated,cache} y
# /mnt/hd5t/stash/library: arranque normal en ~30 s, todo el catálogo,
# performers, tags, ratings, sprites siguen ahí.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear Fases 0 → 7 (incluyendo el montaje de `hd5t` y `hd2t`).
2. `borgmatic extract --archive latest --path mnt/hd2t/apps/stash`.
3. Verificar permisos: `sudo chown -R homelab:homelab /mnt/hd2t/apps/stash && sudo chmod -R u=rwX,g=rX,o= /mnt/hd2t/apps/stash`.
4. Confirmar `/mnt/hd5t/stash/library/` (si el disco hd5t también se perdió: empezar con biblioteca vacía, repoblar desde fuente externa).
5. `docker compose -f stacks/stash/docker-compose.yml up -d`.
6. `https://stash.lan` → login con credenciales pre-existentes.
7. **Si `generated/` se excluyó del backup**: Settings → Tasks → "Generate (Missing only)" para reconstruir sprites y previews (24–72 h en background; el catálogo sigue funcional sin ellos, solo los scrub-bars y previews quedan vacíos hasta que se regeneren).
8. **Si `library/` quedó vacía y se repuebla**: la BBDD restaurada conserva los registros con `path` apuntando a ficheros que ya no existen. Stash muestra "Missing files" en la UI; cuando el operador devuelve los ficheros con el mismo path, Stash los re-vincula automáticamente en el siguiente escaneo (los IDs internos son el `oshash`, así que aunque el path cambie, el hash conecta el registro con el fichero).

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `https://stash.lan` da `502 Bad Gateway` | Caddy no resuelve `stash` (contenedor caído o no en la red `homelab`). | `docker ps --filter name=stash`. Si está caído, `docker logs stash --tail 100`. Si está vivo: `docker network inspect homelab` debe listarlo. |
| Primer arranque tarda >2 min y nunca pasa a `healthy` | BBDD corrupta tras parada sucia, o permisos incorrectos en `/metadata`. | `docker logs stash 2>&1 \| grep -iE 'sqlite\|permission\|fatal'`. Verificar `stat -c '%u:%g' /mnt/hd2t/apps/stash/metadata` (debe ser `1000:1000`). |
| Logs Stash: `permission denied: /library/...` | El bind mount `:ro` está OK pero los ficheros del HDD no son legibles para UID 1000. | `find /mnt/hd5t/stash/library -not -group homelab -o -not -user homelab` (lista los problemáticos); `sudo chown -R homelab:homelab /mnt/hd5t/stash/library`. |
| Logs Stash: `read-only file system: /library` | Stash está intentando escribir en la biblioteca (config errónea: `Move on Edit` o `Trash dir` apuntando a `/library`). | Settings → Library → desactivar "Rename files", "Move on Edit", quitar `Trash dir` de `/library`. Si el operador necesita esas features, cambiar `:ro` por `:rw` en compose deliberadamente. |
| Escaneo se atasca en una escena concreta | Fichero corrupto que ffprobe no puede parsear. | UI: Tasks → ver el job → "Skip"; identificar el fichero en logs (`docker logs stash 2>&1 \| grep -i 'error\|panic'`); validar con `ffprobe` desde el host. |
| BBDD muy lenta tras meses de uso | `VACUUM` no se ha ejecutado; BBDD fragmentada. | `docker exec stash sqlite3 /metadata/stash-go.sqlite "VACUUM;"` (lleva 1–10 min según tamaño; Stash debe estar idle). |
| Generación de previews crashea con OOM | Stash + ffmpeg consumen RAM inesperadamente en perfiles HEVC 10-bit. | Settings → System → bajar `Parallel Tasks` a 1 si no lo está; pausar otros servicios pesados durante el job; en último caso, dividir `library/` en lotes y procesar por carpeta. |
| StashDB scraper devuelve 401 | API key revocada o caducada. | StashDB → Account → API Keys → regenerar; actualizar en Settings → Metadata Providers. |
| Scraper comunitario falla con "page structure changed" | El sitio web fuente cambió HTML. | `Update Available` en Settings → Metadata Providers (los maintainers suelen parchear en días); si no hay parche, deshabilitar ese scraper temporalmente. |
| Suscripción GraphQL (job progress) no actualiza en la UI | Caddy no está pasando el WebSocket upgrade. | `docker logs caddy 2>&1 \| grep -i 'upgrade\|websocket'`. En caddy v2 debería funcionar de oficio; si no, verificar la versión y considerar `header_up Connection {>Connection}` explícito. |
| Login pide credenciales infinitamente | Cookie de sesión inválida tras cambio de hostname / cert. | Borrar cookies del navegador para `stash.lan`; reloguear. Si persiste: `Settings → Security → Logout from all sessions`. |
| `phash` repetidos detectan duplicados que no lo son | Algoritmo perceptual con falsos positivos en escenas con poca variación visual. | Ajustar el threshold en Settings → Library → "phash distance"; revisar manualmente antes de fusionar. |
| `Authelia` interfiere a pesar del bypass | El fragmento `09-stash-bypass.yml` no se cargó en `configuration.yml`. | `docker logs authelia \| grep stash`; revisar la inclusión del fragmento; reiniciar Authelia. |
| `https://stash.lan` muestra cert "no confiable" tras instalar la CA | Caddy no recargó el `Caddyfile` (drop-in nuevo). | `docker exec caddy caddy validate --config /etc/caddy/Caddyfile && docker kill --signal=SIGUSR1 caddy`. |
| Reproducción 4K HEVC en navegador cae a transcoding lento | El navegador no decodifica HEVC; Stash transcodifica en SW (lento en Pi 5). | Reproducir desde un cliente que sí lo soporte (Safari macOS/iOS, Edge Windows con extensión), o re-codificar la fuente a H.264. HW transcoding desactivado por política (ver "Decisión: transcoding"). |
| `generated/` consume todo `hd2t` libre | Catálogo crece más rápido de lo previsto; previews + sprites se acumulan. | `du -sh /mnt/hd2t/apps/stash/generated/scenes/*` para identificar; considerar bajar resolución de sprites (Settings → System), o purgar previews de escenas con rating bajo. |
| Tras `docker compose pull`, Stash arranca y dice "Database migration failed" | Bump de minor con migración fallida. | Restore `metadata/stash-go.sqlite` desde el snapshot Borg de la noche anterior. Reportar issue upstream con logs. **No** intentar revertir manualmente la migración. |
| Stash detecta una escena como "duplicado" tras renombrarla en el HDD | El `oshash` cambia si los primeros/últimos MiB del fichero cambian (poco probable con un rename, pero pasa con re-mux). | UI: Stats → Duplicate Files → fusionar manualmente. |
| `library/` con miles de subcarpetas escanea muy lento | Latencia inherente del HDD USB con árboles profundos. | Aceptar el tiempo del primer escaneo; para reescaneos incrementales, Stash usa `mtime` y es ~1 min para detectar lo nuevo. |
| Plugin custom no se carga | Permisos en `/root/.stash/plugins/` o YAML mal formado. | `docker logs stash \| grep -i plugin`; validar el YAML del plugin; reiniciar Stash. |

---

## Decisiones que **no** se toman en este documento

- **Authelia delante de Stash**: descartado por compatibilidad con la API GraphQL y el streaming con `?apikey=`. Reabrible solo cuando Stash gane soporte OIDC nativo.
- **Multiusuario**: no soportado en v0.27.x. Stash es single-user por ahora; los miembros del hogar comparten cuenta o usan instancias separadas (no soportado en este compose). Reabrible cuando v0.30+ traiga multiusuario.
- **Cifrado en reposo de hd5t** (LUKS): el plan del homelab no lo contempla por defecto (`docs/00-hardware/03-preparacion-discos.md`). Si el operador lo necesita: reformatear `hd5t` con LUKS, ajustar `/etc/fstab` con `crypttab`, y la unidad pedirá passphrase al boot (incompatible con boot desatendido). Reabrible.
- **`library/` en `:rw`**: descartado por defecto. Reabrible si el operador quiere usar "Move on Edit" o "Trash" delegando al servicio la organización del bulk.
- **HW transcoding en Pi 5 para Stash**: descartado por madurez de la integración. Reabrible si el catálogo se mueve a 4K HEVC dominante y el SW transcoding se vuelve cuello.
- **DLNA / Chromecast nativo**: Stash no implementa DLNA. Reabrible solo via terceros.
- **Scraping masivo automático sobre toda la biblioteca**: descartado por rate limits y calidad heterogénea. Política manual / por lotes con revisión humana.
- **Migración a `MyAdultDataExplorer`, `Whisparr`, otros**: descartado. Stash es el catálogo más maduro de la categoría open source.
- **Whisparr (descarga automatizada complementaria a Stash)**: pertenece a una hipotética Fase 10 ampliada (`docs/10-descargas/`), análoga al stack `*arr` de Jellyfin. No se despliega aquí.
- **`stash-box` propio (instancia colaborativa privada)**: sobreingeniería para un homelab; reabrible si el operador quiere alojar una BBDD propia compartida con un grupo.
- **Métricas Prometheus**: Stash **no** expone métricas Prometheus nativas. Hay un exporter terciario (`stash-prometheus-exporter`) que consume la GraphQL API. Reabrible en Fase 5.
- **Backups del bulk de hd5t**: política deliberada de **no respaldar** `/mnt/hd5t/stash/library/`. Documentada arriba y en `07-backups/01-estrategia-backup.md`. La salvaguarda es la fuente externa.
- **Backup de `generated/`**: por defecto excluido (T4). El operador puede invertir la decisión si acepta el coste extra en Borg.
- **Indexación de `/mnt/hd2t/media/...` en Stash**: descartado por política de separación. Stash es exclusivo de `/mnt/hd5t/stash/library/`.
- **Compartir el catálogo con otros usuarios** (familiares, amigos): fuera de alcance. Tailscale + cuenta única + operador único, por diseño.

---

## Verificación Final

Antes de cerrar la Fase 9:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/stash/docker-compose.yml ps` | `stash ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect stash --format '{{.Config.Image}}'` | `stashapp/stash:v0.27.2` |
| Conectado a la red homelab y NO a host | `docker inspect stash --format '{{.HostConfig.NetworkMode}}'` | `default` o `homelab` (no `host`) |
| Sin puertos publicados al host | `docker port stash` | salida vacía |
| `stash.lan` resuelve al IP de la Pi | `dig +short stash.lan @192.168.1.2` | `192.168.1.10` |
| Caddy sirve `stash.lan` con cert de la CA interna | `echo \| openssl s_client -connect stash.lan:443 -servername stash.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| Health endpoint responde | `curl -ksS https://stash.lan/healthz` | `HTTP 200` |
| Usuario interno con UID/GID correctos | `docker exec stash id` | `uid=1000 gid=1000` |
| `/library` montado y read-only | `docker exec stash sh -c 'touch /library/.write_test 2>&1 \| head -1'` | `touch: cannot touch ...: Read-only file system` |
| `/metadata`, `/generated`, `/cache` montados read-write | `docker exec stash sh -c 'for d in /metadata /generated /cache; do touch $d/.w && rm $d/.w && echo "$d OK"; done'` | tres líneas `OK` |
| Autenticación habilitada | `curl -ksS -o /dev/null -w '%{http_code}\n' https://stash.lan/graphql -H 'Content-Type: application/json' -d '{"query":"{stats{scene_count}}"}'` | `401` (sin auth) |
| Autenticación con API Key funciona | `curl -ksS https://stash.lan/graphql -H 'ApiKey: <KEY>' -H 'Content-Type: application/json' -d '{"query":"{stats{scene_count}}"}'` | `{"data":{"stats":{"scene_count":<N>}}}` con `<N>` ≥ 0 |
| BBDD presente e íntegra | `docker exec stash sqlite3 /metadata/stash-go.sqlite "PRAGMA integrity_check;"` | `ok` |
| Owner correcto del estado | `stat -c '%u:%g %a' /mnt/hd2t/apps/stash/{config,metadata,generated,cache}` | `1000:1000 750` para los cuatro |
| Owner correcto de la biblioteca | `stat -c '%u:%g %a' /mnt/hd5t/stash/library` | `1000:1000 750` |
| Library aparece en la UI con conteo > 0 | UI: dashboard | conteo de escenas y/o imágenes coherente con la biblioteca |
| Login funciona desde navegador | navegador con CA instalada | UI carga el dashboard tras login |
| Authelia bypass para `stash.lan` | `curl -ksI https://stash.lan/` | sin `Location` apuntando a `auth.lan` |
| `hd5t` montado y accesible | `findmnt /mnt/hd5t \| grep -q ext4 && echo OK` | `OK` |
| Sin warnings críticos en logs | `docker logs stash 2>&1 \| grep -iE 'error\|fail\|panic' \| head` | salida razonable (no errores recurrentes de permisos o BBDD) |

---

## Referencias

- Documentación oficial Stash — https://docs.stashapp.cc/
- Repo del proyecto — https://github.com/stashapp/stash
- Imagen Docker upstream — https://hub.docker.com/r/stashapp/stash
- Mirror GHCR — https://github.com/stashapp/stash/pkgs/container/stash
- CommunityScrapers (repo) — https://github.com/stashapp/CommunityScrapers
- StashDB (Stash-Box público) — https://stashdb.org/
- Stash-Box (servidor de metadatos) — https://github.com/stashapp/stash-box
- Reverse proxy con Caddy (oficial) — https://docs.stashapp.cc/networking/reverse-proxies/caddy/
- API GraphQL — https://docs.stashapp.cc/networking/graphql/
- Plugins y scrapers — https://docs.stashapp.cc/plugins/, https://docs.stashapp.cc/scraping/
- Documentos hermanos: `01-jellyfin.md`, `02-navidrome.md`, `03-audiobookshelf.md`, `04-calibre-web.md`.
