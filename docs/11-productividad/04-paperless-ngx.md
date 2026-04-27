# Paperless-ngx (gestor documental con OCR)

## Descripción

Despliegue de **Paperless-ngx** como **archivo digital del operador y de la familia**: cada papel que entra en casa (factura, contrato, recibo, nómina, manual, certificado, justificante de pago, póliza, prescripción médica, ticket de garantía, libro de familia escaneado, comunicado del banco) se digitaliza una vez, Paperless le pasa **OCR** (`tesseract` + `OCRmyPDF`), extrae texto, autodetecta corresponsal, fecha del documento y tipo, lo etiqueta, lo archiva en un PDF/A normalizado en `hd2t` y lo deja **buscable por full-text** desde una UI web. La promesa operativa: el operador deja de necesitar carpetas físicas, deja de tener miedo a perder un papel, y puede contestar a "¿qué pagué a la mutua en 2023?" en treinta segundos desde el móvil. Es el contrapunto _document-centric_ del homelab a Nextcloud (`docs/06-almacenamiento/01-nextcloud.md`, _file-centric_): Nextcloud guarda **ficheros como tales** (en árbol, nombre como verdad); Paperless guarda **documentos** (texto, fecha, corresponsal, etiquetas, con el fichero como un detalle interno).

Este documento **continúa el _stack_ `productividad`** (`~/homelab/productividad/`) que estrenó `docs/11-productividad/01-vaultwarden.md`, amplió `docs/11-productividad/02-bookstack.md` (con la red privada `productividad-internal` y MariaDB) y `docs/11-productividad/03-linkding.md`. A diferencia de los tres anteriores, Paperless-ngx **es la primera aplicación del homelab que necesita simultáneamente PostgreSQL + Redis** y, por tanto, materializa **cuatro contenedores de un golpe** dentro del mismo _stack_:

- **`paperless`** — el _frontend_ Django + el _consumer_ que vigila la carpeta de consumo. Imagen oficial `ghcr.io/paperless-ngx/paperless-ngx`.
- **`paperless-db`** — base de datos **PostgreSQL 16** dedicada (no se reutiliza la `bookstack-db` de MariaDB; razones en **Decisiones de diseño**).
- **`paperless-redis`** — broker de **Redis 7** para Celery + Celery Beat (la cola de _tasks_ de OCR e indexación).
- **`paperless-gotenberg`** — sidecar opcional de _Gotenberg_ (LibreOffice headless) para convertir DOCX/ODT/XLSX a PDF antes del OCR. **Recomendado**.
- **`paperless-tika`** — sidecar opcional de _Apache Tika_ para extraer texto de documentos office sin pasar por LibreOffice. **Recomendado** junto con Gotenberg para cubrir el catálogo completo de Office, RTF, EPUB, etc.

Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone Paperless en `https://paperless.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), `https://pi.<tailnet>.ts.net/` con MagicDNS sirve el mismo archivo desde fuera de la LAN. **Samba** (`docs/06-almacenamiento/02-samba.md`) ya expone `/mnt/hd2t/services/paperless/consume/` como _share_ `paperless-consume` para que el operador "imprima a fichero" desde Windows/macOS/iOS y deje el escaneo en esa carpeta — Paperless lo detecta y lo OCRea automáticamente sin intervención. Esta integración **ya está hecha** desde `docs/06-almacenamiento/02-samba.md`; aquí sólo se confirma el contrato (UID/GID, polling) y se documenta el _runbook_.

> **Alcance**: este documento despliega Paperless-ngx con su autenticación nativa (username + password, opcional 2FA TOTP via la app `django-allauth-2fa` integrada), crea **el usuario operador** vía las variables `PAPERLESS_ADMIN_USER`/`PAPERLESS_ADMIN_PASSWORD` del primer arranque, **deshabilita el registro abierto** (Paperless lo trae **off por defecto** y se confirma desde Django admin), genera el **token de API** del operador para que las apps móviles (`Paperless Mobile`, `Paperless Share`) y las CLIs funcionen, configura **OCR en español + inglés** (los dos idiomas del operador), define la **convención de `PAPERLESS_FILENAME_FORMAT`** que organiza el archivo final en `hd2t` por año/corresponsal, **descomenta el bloque del _hook_ de Borgmatic** que dejó preparado `docs/07-backups/03-backup-docker-volumes.md` con `dump_postgres paperless paperless-db "$HOMELAB/productividad/.env"` y, además, añade **`/mnt/hd2t/services/paperless/media/documents/originals/`** como _source_directory_ del set "data" (los originales escaneados son la categoría A — pérdida ≡ pérdida total e irrecuperable). **No** delega autenticación a Authelia vía `forward_auth` (mismo razonamiento que Vaultwarden, Bookstack y Linkding — la API REST con _bearer tokens_ y los _intents_ de las apps móviles rompen con un redirect HTML; ver **Decisiones de diseño**). **No** activa OIDC contra Authelia (queda como **opcional** al final, mismo patrón). **No** configura SMTP en este documento (queda como **opcional** al final). **No** activa _email ingestion_ vía IMAP (también opcional).

> **Recordatorio de red**: sólo `paperless` (la app) **se publica** a la red `homelab` para que Caddy la alcance por DNS interno (`paperless:8000`). `paperless-db`, `paperless-redis`, `paperless-gotenberg` y `paperless-tika` viven **exclusivamente** en `productividad-internal`: no son alcanzables desde Caddy, ni desde Authelia, ni desde otros _stacks_, ni desde los demás contenedores del _stack_ `productividad` (Vaultwarden y Linkding **no** se enchufan a `productividad-internal`; sólo Bookstack — desde `02-bookstack.md` — y ahora Paperless). Pi-hole resuelve `paperless.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`).

---

## Requisitos previos

- `docs/02-docker/02-estructura-compose.md` completado: la tabla de stacks reserva el _slot_ `productividad`, la red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) externa está creada, `~/homelab/.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `HOMELAB_DOMAIN=lan` está rellenado, y el _Makefile_ de operación expone `make up STACK=<stack>`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/paperless/{data,media,consume,export}/` ya existen, vacíos, con ownership `root:root 0755`. **No tocar el ownership** antes del primer arranque: el _entrypoint_ de Paperless hace `chown` recursivo a `${USERMAP_UID}:${USERMAP_GID}` (que se fijarán a `1000:1000`).
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada. Paperless, Postgres, Redis, Gotenberg y Tika serán **opt-out** explícito (justificación en **Decisiones de diseño**).
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `paperless.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, y la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile`. La CA local ya firma `*.lan`.
- `docs/06-almacenamiento/02-samba.md` completado: el _share_ `paperless-consume` apunta a `/mnt/hd2t/services/paperless/consume/`, con `force user = homelab` y `force group = homelab`. El operador puede dejar ficheros en esa carpeta desde su portátil/móvil. **Sin Samba este servicio funciona igual** (uno puede dejar ficheros con `scp` o desde Nextcloud directo en `consume/`); Samba sólo es la rampa cómoda.
- `docs/07-backups/03-backup-docker-volumes.md` completado: el helper `dump_postgres` está cargado en `~/homelab/backups/borgmatic/hooks/dump-databases.sh` y el bloque comentado `# dump_postgres paperless paperless-db "$HOMELAB/productividad/.env"` está listo para descomentar. La nota "originales como _source_directory_ adicional" del mismo documento se materializa aquí.
- `docs/11-productividad/02-bookstack.md` completado: la red `productividad-internal` ya existe (la trajo Bookstack). Paperless **se enchufa** a ella; **no hay que crearla** de nuevo, sólo añadir `paperless` como miembro.
- `docs/11-productividad/03-linkding.md` completado: el _stack_ `productividad` está vivo con cuatro servicios (Vaultwarden, Bookstack, Bookstack-db, Linkding) en `(healthy)`. **Este documento amplía** los ficheros del _stack_ — no los crea desde cero. Tener Vaultwarden vivo también significa que el operador **ya tiene una bóveda** donde guardar `PAPERLESS_SECRET_KEY`, las _passwords_ de Postgres y el _API token_ que se generan abajo.
- Conectividad saliente para descargar las imágenes (sólo la primera vez):
  ```bash
  docker pull --platform linux/arm64 ghcr.io/paperless-ngx/paperless-ngx:2.13.5 >/dev/null && \
  docker pull --platform linux/arm64 postgres:16-alpine                          >/dev/null && \
  docker pull --platform linux/arm64 redis:7-alpine                              >/dev/null && \
  docker pull --platform linux/arm64 docker.io/gotenberg/gotenberg:8.7           >/dev/null && \
  docker pull --platform linux/arm64 ghcr.io/paperless-ngx/tika:latest           >/dev/null && \
  echo OK
  ```
- Que el host **no** tenga ya un servicio escuchando en `:8000`, `:5432`, `:6379`, `:3000` (Gotenberg) ni `:9998` (Tika) por error (`docker ps --format '{{.Names}} {{.Ports}}' | grep -E ':8000->|:5432->|:6379->|:3000->|:9998->' || echo OK`). Este _stack_ no publica puertos al host; Caddy es quien recibe el tráfico HTTPS.
- Espacio en `/mnt/hd2t`: Paperless es **moderadamente intensivo** en disco. Cada documento se guarda **dos veces** (el original tal como lo escaneó el operador y la versión _archive_ PDF/A con OCR). Para 1.000 documentos típicos (mezcla de PDF y escaneados a 300 DPI) se estima ~5–8 GB. La BD Postgres pesa <100 MB para 10.000 documentos. Verificar holgura mínima:
  ```bash
  df -h /mnt/hd2t
  # Debe quedar holgado. Reservar al menos 20 GB libres pensando en crecimiento
  # de los originales (categoría A: NO se borran nunca).
  ```

---

## Decisiones de diseño

### Por qué Paperless-ngx (y no Mayan EDMS / Teedy / OpenKM / DocSpell / Stalwart Workshare / "PDFs en Nextcloud")

El homelab necesita **un gestor documental con OCR** que cumpla a la vez: ingesta automática desde una carpeta de red, OCR multilenguaje (español + inglés), búsqueda full-text, etiquetado, _correspondents_, tipos de documento, fechas extraídas automáticamente, API REST, app móvil decente, _self-hosting_ ARM64 maduro y un _footprint_ razonable para una Pi 5 que ya tiene Nextcloud, Jellyfin y Home Assistant pidiendo RAM. Cinco candidatos descartados y por qué:

| Candidato                | Por qué se descarta                                                                                                                                                 |
|--------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Mayan EDMS**           | Funcionalmente muy completo (workflows, firmas digitales, OCR, multi-tenant). Pero el _stack_ es **mucho más pesado** (Django + Celery + RabbitMQ + Postgres + Redis + Elasticsearch opcional) y la UI es industrial: orientada a empresas con un departamento de archivo. _Overkill_ para un homelab familiar. |
| **Teedy** (ex Sismics Docs) | Java + Tomcat + Lucene. UI minimalista, buena, pero el OCR es _build-time_ y no tiene un _consumer_ que vigile carpeta: hay que subir cada doc manualmente. **Ingesta manual** rompe el caso de uso "imprime a fichero desde el iPad y olvídate". |
| **OpenKM**              | Java EE pesado (Tomcat + MySQL + Hibernate). Edición Community recortada respecto a Professional. Migración fuera complicada (export propio en formato ZIP que pocas herramientas leen). _Vendor lock-in_ velado.                          |
| **DocSpell**            | Scala + JVM. Excelente arquitectura, OCR distribuido, address-book de _correspondents_ con autocompletado desde tarjetas vCard. Pero la JVM en una Pi 5 cuesta ~1 GB de RAM idle por proceso, hay tres procesos. La huella **dobla** a Paperless-ngx para una funcionalidad muy similar. |
| **PDFs en Nextcloud + tag manual** | Es lo que el operador hacía hasta ahora. Ventaja: cero servicio nuevo. Desventajas: no hay OCR (los PDFs escaneados son "imágenes con extensión .pdf", la búsqueda no los encuentra), las etiquetas de Nextcloud son planas y poco rápidas, no hay extracción automática de fecha/corresponsal, no hay vista "documentos de 2023" cómoda. **El motivo de existir** de Paperless es exactamente lo que aquí falta. |

Paperless-ngx gana por:

- **Stack mínimo viable** (Django + Celery + Postgres + Redis) sin colas externas tipo RabbitMQ. Para los sidecar de Office y Tika, son _opt-in_ (el operador puede arrancar sólo `paperless` + `paperless-db` + `paperless-redis` y conformarse con PDF, JPG, PNG, TIFF — Tika y Gotenberg sólo son para `.docx`, `.odt`, `.xlsx`, `.eml`, etc.).
- **Consumer integrado**: vigila `/usr/src/paperless/consume/` (que es nuestro `/mnt/hd2t/services/paperless/consume/`) en _polling_ o _inotify_ y procesa todo lo que aparezca, sin que el operador toque la web. Al terminar, **el original se mueve** a `media/documents/originals/` y **se borra** del consume folder. Comportamiento exactamente equivalente al "scan-to-folder" de los multifuncionales, pero con OCR potente detrás.
- **OCR de calidad**: usa **`OCRmyPDF`** (que envuelve `tesseract` + `Ghostscript` + `pikepdf`) para producir un PDF/A con la capa de texto invisible sobre la imagen. La **misma página** sigue viéndose como antes (la imagen no se altera) pero ahora es buscable. PDF/A es un estándar de archivo a largo plazo (descomprime sin software propietario en el año 2050). El operador puede abrir el archive PDF en cualquier visor y verlo idéntico al original; sólo Paperless _sabe_ que detrás hay texto.
- **Multilenguaje**: `PAPERLESS_OCR_LANGUAGE=spa+eng` corre los dos modelos a la vez. El sobrecoste es ~10–20 % de tiempo de OCR; a cambio, Paperless detecta correctamente facturas en español, manuales en inglés y cualquier mezcla.
- **Auto-clasificación**: tras unos cientos de documentos etiquetados a mano, Paperless entrena un clasificador interno (`scikit-learn`-style) que sugiere etiquetas, _correspondents_ y tipos de documento para los nuevos. **Activación opcional**: para empezar, mejor a mano; cuando haya volumen, el _auto-tagging_ acierta el 70-80 %.
- **App móvil decente**: [Paperless Mobile](https://github.com/astubenbord/paperless-mobile) (Android/iOS) consume la API REST con _bearer tokens_. _Share intent_ desde la cámara o desde un visor PDF: el documento sube al consume folder por API y se OCRea en la Pi.
- **Soporte ARM64 oficial** vía `ghcr.io/paperless-ngx/paperless-ngx`. Multi-arch nativo, mantenido por el upstream. **Sin** dependencia de LinuxServer.io aquí.
- **Migración fuera trivial**: `document_exporter` produce un ZIP con todos los documentos + un manifest JSON. Cualquier sustituto (DocSpell, Mayan, scripts caseros) puede importarlo. **Sin lock-in**.

### Imágenes y _tags_

- **`ghcr.io/paperless-ngx/paperless-ngx:2.13.5`** — Paperless-ngx 2.13.x. Pinneada a _tag_ "major.minor.patch" semver siguiendo la convención del homelab (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`). Los _bumps_ de **patch** (2.13.5 → 2.13.6) son retrocompatibles. Los _bumps_ de **minor** (2.13 → 2.14) traen funcionalidades y, ocasionalmente, migraciones de schema; se gestionan a mano leyendo el _changelog_. Los _bumps_ de **major** (2.x → 3.x) suelen ser raros y exigen leer las _release notes_ con calma.
- **`postgres:16-alpine`** — PostgreSQL 16 sobre Alpine, multi-arch ARM64. Misma _major_ que recomienda upstream para Paperless-ngx 2.x. Alpine ahorra ~80 MB de imagen sobre la `:16` Debian. Atención al `lc_collate` (ver más abajo, sección **Decisiones de diseño → PostgreSQL `--lc-collate`**).
- **`redis:7-alpine`** — Redis 7 sobre Alpine, **sin persistencia** activada (sólo cola de tasks; pérdida tolerable, ver más abajo). Misma _major_ que el _stack_ Almacen+Authelia (`docs/06-almacenamiento/01-nextcloud.md`, `docs/04-seguridad/01-authelia.md`) si se quisiera reutilizar — aquí se prefiere instancia dedicada por aislamiento del _stack_.
- **`docker.io/gotenberg/gotenberg:8.7`** — Gotenberg 8.x con LibreOffice headless. Multi-arch ARM64. _Tag_ "major.minor". Endpoint sólo escucha en `productividad-internal`, no se publica.
- **`ghcr.io/paperless-ngx/tika:latest`** — Apache Tika empaquetado por el upstream de Paperless. Aquí **se acepta `:latest`** porque el _wrapper_ del upstream cambia poco y Tika upstream es estable; si se prefiere pinear, usar el _digest_ específico (`paperless-tika@sha256:…`). Multi-arch ARM64.

#### Watchtower opt-out en los cinco contenedores

Razones por contenedor:

- **`paperless`**: las _major upgrades_ (2.x → 3.x) ejecutan migraciones de Django (`python manage.py migrate`) y, en algunos saltos, el modelo de _consumer_ y de búsqueda full-text se reescribe (paso de Whoosh a Postgres trigrams, paso de WebSocket a SSE, ...). Un `pull` automático de un _tag_ que cruzase un _bump_ rompería la BD a medio migrar. Las _major upgrades_ se hacen a mano, leyendo el _changelog_ y haciendo dump previo.
- **`paperless-db`** (Postgres): mismo razonamiento que cualquier RDBMS — un _bump_ de _major_ (16 → 17) puede cambiar formato del cluster y exige `pg_upgrade`. **Manual** y con _dump_ previo.
- **`paperless-redis`**: aunque Redis es esencialmente un cache, _bumps_ entre _major_ (7 → 8) cambian el protocolo en detalles que pueden afectar a _clients_ Celery con _pinning_ específico. Coste cero mantenerlo manual.
- **`paperless-gotenberg`**: depende de LibreOffice; LibreOffice cambia comportamiento entre _majors_ (formatos exóticos pueden dejar de convertirse igual). Conservador.
- **`paperless-tika`**: similar a Gotenberg. La imagen del upstream es _latest_ (tag flotante); Watchtower no aporta nada — manual y conservador.

Etiquetar los cinco con `com.centurylinklabs.watchtower.enable: "false"`.

> **Coherencia con `docs/02-docker/04-watchtower.md`**: ese documento ya lista a "Paperless-ngx" y "PostgreSQL" en la lista explícita de servicios **opt-out** desde el principio. No hace falta justificar nada extra aquí; sólo aplicar la etiqueta a cada contenedor del _stack_.

### PostgreSQL en lugar de SQLite o MariaDB

Paperless-ngx soporta los tres backends (SQLite por defecto, PostgreSQL, MariaDB). La elección **forzada por el caso de uso** es **PostgreSQL**:

- **Búsqueda full-text** — Paperless usa el motor FTS de Postgres (con _trigram_ para fuzzy matching) si se le configura. Es **muy** superior al `LIKE %...%` que SQLite ofrece sin extensiones; en BDs con ≥ 5.000 documentos la diferencia es de "instantáneo" a "diez segundos". Aunque el upstream también soporta SQLite + Whoosh, el camino recomendado y mejor mantenido es Postgres + FTS.
- **Concurrencia de Celery**: el _consumer_ corre en _Celery workers_ que escriben en la BD en paralelo cuando se ingestan varios documentos. SQLite serializa todas las escrituras en un único _writer lock_; con dos workers, uno se queda esperando. Postgres lo gestiona limpiamente.
- **Aislamiento del _stack_**: Bookstack vive en MariaDB (`bookstack-db`). Paperless en Postgres. Que cada servicio tenga su _engine_ canónico evita reutilizar mal y deja libertad para sintonizar la BD a las necesidades del servicio (Postgres aquí afina el _stemmer_ español; MariaDB en Bookstack afina el `FULLTEXT` de InnoDB). Coste: ~150 MB de RAM idle adicionales por la instancia Postgres. Aceptable en una Pi 5 con 8 GB.
- **Backup más simple con `pg_dump`**: el helper `dump_postgres` ya existe en el _hook_ de Borgmatic (`docs/07-backups/03-backup-docker-volumes.md`). Reutilizarlo es trivial; cambiar a SQLite supondría usar el helper `dump_sqlite` y cargar `sqlite3` dentro del contenedor.

> **Si en el futuro la BD creciera tanto que Postgres en la Pi se vuelva el cuello de botella** (improbable en uso doméstico), la migración a otra Pi/NAS exclusivamente para Postgres es un cambio de `paperless-db` por una IP externa en `PAPERLESS_DBHOST`. El resto del _stack_ no se entera.

### PostgreSQL `--lc-collate` y `--lc-ctype`

Paperless ordena documentos por título y por _correspondent_. Si la _collation_ de la BD es `C` (default de la imagen `postgres:16-alpine`), **`Á`, `Ñ`, `Ü`** ordenan **después** de `Z` — la lista de documentos aparece desordenada visualmente para un operador que lee en español. Forzar collation `es_ES.UTF-8` arregla el ordering y, además, hace que el _stemmer_ de FTS use el catálogo español si se activa.

Política aplicada en el `command:` de `paperless-db`:

```yaml
POSTGRES_INITDB_ARGS: --locale=es_ES.UTF-8 --lc-collate=es_ES.UTF-8 --lc-ctype=es_ES.UTF-8 --encoding=UTF-8
```

Atención: la imagen `postgres:16-alpine` **no incluye** los locales de Alpine por defecto; hay que inyectarlos. La forma más limpia es montar un mini-volumen con un `init.sh` que ejecute `apk add --no-cache musl-locales musl-locales-lang` antes del `initdb`. Para no añadir un `command` complicado al compose, **se cambia a la imagen Debian `postgres:16-bookworm`** (que ya trae los locales `es_ES.UTF-8` precompilados). El sobrecoste es ~80 MB de capa adicional, aceptable.

> **Alternativa**: dejar la BD en `C.UTF-8` y aplicar el ordering correcto **a nivel aplicación** desde Paperless (que llama a `unaccent` y similar). Funciona, pero el ordering nativo de Postgres es más rápido y robusto. Se prefiere lo simple.

### Redis sin persistencia

Paperless usa Redis sólo como _broker_ de Celery (cola de tasks de OCR e indexación). Si Redis se cae mientras un OCR está en curso:

- Las tasks pendientes en cola se pierden — el operador tendría que **dejar de nuevo el documento en consume/** (lo cual le da exactamente igual: el original sigue ahí).
- Los documentos ya OCReados y guardados en la BD están a salvo (la BD es Postgres, no Redis).

Por tanto **no se activa persistencia**: ni `appendonly yes` ni `save` snapshots. La memoria Redis se queda al puro RAM, sin escribir nada a disco. Esto:

- Ahorra ~50–100 MB de _bind mount_ en `/mnt/hd2t/services/paperless/`.
- Evita un fichero más en backup.
- Hace al _restart_ de Redis trivial (no hay que esperar a que cargue el AOF).

> **Si el operador en el futuro activase tareas más críticas en Celery** (por ejemplo, procesos largos de re-indexación que duraran horas), valdría la pena `appendonly yes` y persistir el AOF para que un reinicio no perdiera la cola. **No es el caso hoy**.

### Gotenberg y Tika **recomendados**, no obligatorios

Paperless funciona sin Gotenberg ni Tika; en ese caso, los formatos soportados se limitan a:

- PDF (con/sin OCR previo).
- Imágenes (JPG, PNG, TIFF, BMP, WEBP).
- Texto plano y RTF mínimo.

Cuando se añaden Gotenberg + Tika, se desbloquean:

- **Documentos Office**: `.doc`, `.docx`, `.odt`, `.xls`, `.xlsx`, `.ods`, `.ppt`, `.pptx`, `.odp` (Gotenberg los convierte a PDF con LibreOffice headless y luego Paperless OCR los pasa al pipeline normal).
- **Email**: `.eml`, `.msg` (Tika los extrae y Paperless los archiva).
- **EPUB / RTF / HTML / Markdown** y un puñado de otros — Tika es polifacético.

Decisión del documento: **se recomienda activar los dos**. La Pi 5 8 GB los soporta sin sudar (Gotenberg en idle ocupa ~80 MB, Tika ~150 MB); la cobertura de formatos crece de "el operador escanea papel y archiva PDFs" a "el operador puede archivar **cualquier** documento que reciba digitalmente" (incluido el `.docx` que la mutua envía por email). El `.env.example` los activa por defecto; quien quiera ahorrar memoria los puede dejar comentados.

### `forward_auth` con Authelia: **NO** para Paperless

Misma decisión que en Vaultwarden, Bookstack y Linkding. Razones específicas para Paperless:

- **API REST con _Bearer tokens_**: Paperless expone `/api/*` con autenticación por _token_ (`Authorization: Token <40-char-hex>`). No sigue redirects HTML. Si Caddy intercepta una petición a `/api/documents/?ordering=-created` con un `302` hacia `https://auth.lan/?rd=...`, la **app móvil** (`Paperless Mobile` en Android/iOS) y los scripts de subida automática (`pngx`, `paperless-cli`) reciben HTML y fallan con errores opacos.
- **`Paperless Share` _intent_** desde Android Firefox / Drive: el _share sheet_ del móvil abre un POST a `/api/documents/post_document/` con el PDF en `multipart/form-data`. Cualquier redirect a Authelia rompe el flujo, y volver a desbloquear Authelia desde el _share sheet_ del móvil es un sufrimiento UX inaceptable.
- **WebDAV opcional para escáneres de red**: algunos multifuncionales no tienen Samba/SMB pero sí WebDAV. Paperless puede recibir documentos por un endpoint WebDAV (no nativo, vía un sidecar) que tampoco hablaría OAuth. Evita problemas presentes y futuros.
- **OIDC nativo**: Paperless soporta **OIDC desde 2.x** vía `mozilla-django-oidc` y las variables `PAPERLESS_APPS` + `PAPERLESS_SOCIAL_AUTH_*`. Igual que en Bookstack y Linkding, el camino correcto para unificar el _login_ con Authelia es **dentro** de Paperless, **no** poniendo Authelia delante con `forward_auth`. La sección **Migrar a OIDC con Authelia (opcional)** del final de este documento describe ese camino.

> **Resumen operativo**: el bloque `paperless.lan` del `Caddyfile` lleva `import security-headers` y `import logging`, pero **no** `import authelia`. Caddy actúa como _reverse proxy_ "tonto"; Paperless autentica con su sistema nativo (username + password + opcional MFA TOTP) y, cuando se decida, con OIDC contra Authelia desde dentro de la propia app.

### `PAPERLESS_URL` y `PAPERLESS_CSRF_TRUSTED_ORIGINS` byte a byte

Paperless (Django) genera URLs absolutas en _password reset_ (si SMTP está activo), en los _share links_ y en los _OAuth redirect URIs_ a partir de `PAPERLESS_URL`. Si no se le dice, las construye con el _hostname_ que el WSGI (`granian`/`gunicorn`) ve en la request — y como Caddy reescribe `Host` a `paperless.lan` por defecto, lo natural es que coincidan… pero **lo natural no es lo seguro**, y además `PAPERLESS_URL` se usa también para la **lista de orígenes CSRF** de Django.

Política:

```bash
PAPERLESS_URL=https://paperless.lan
PAPERLESS_CSRF_TRUSTED_ORIGINS=https://paperless.lan,https://pi.tailnet.ts.net
PAPERLESS_ALLOWED_HOSTS=paperless.lan,pi.tailnet.ts.net,paperless,localhost
```

…fijado en el `.env`. La inclusión de la URL de Tailscale en `PAPERLESS_CSRF_TRUSTED_ORIGINS` permite que la app funcione **también** cuando se accede vía MagicDNS desde fuera de la LAN; sin ella, los formularios POST devuelven `403 CSRF verification failed` al hacerlos vía Tailscale. `PAPERLESS_ALLOWED_HOSTS` añade además `paperless` (DNS interno de Docker, útil para healthchecks) y `localhost` (para `docker exec paperless curl ...`).

> Si el operador no ha configurado Tailscale aún (es un paso opcional al final de la fase 3), poner sólo `PAPERLESS_CSRF_TRUSTED_ORIGINS=https://paperless.lan` y `PAPERLESS_ALLOWED_HOSTS=paperless.lan,paperless,localhost`. Cuando Tailscale aterrice, ampliar las dos listas y `up -d paperless`.

### `PAPERLESS_FILENAME_FORMAT` — la convención del archivo

Cuando Paperless ingesta un documento, lo deja por defecto en `media/documents/originals/<UUID>.pdf` y la app es la única que sabe qué documento es cuál. **Eso es perfectamente válido**: el operador no debería editar los ficheros directamente. Pero, por _disaster recovery_ y por inspección humana ocasional, conviene que la jerarquía de directorios refleje algo legible.

Política aplicada:

```bash
PAPERLESS_FILENAME_FORMAT={created_year}/{correspondent}/{created} - {title}
PAPERLESS_FILENAME_FORMAT_REMOVE_NONE=true
```

Esto produce, por ejemplo, `originals/2024/Mutua Madrileña/2024-03-15 - Recibo cuota anual.pdf`. **Atención**: el _filename format_ se aplica **a los archivos físicos** en disco, no a los metadatos de la BD (que siempre son los canónicos). Si se cambia este formato más tarde, Paperless **mueve los ficheros** en la siguiente carga (operación _segura_ pero ruidosa en logs y en los backups incrementales).

> **`PAPERLESS_FILENAME_FORMAT_REMOVE_NONE=true`**: si un documento aún no tiene corresponsal asignado, el placeholder `{correspondent}` quedaría como literal `none`. Con esta variable, Paperless lo omite y el documento queda directamente bajo `2024/2024-03-15 - Recibo.pdf` hasta que se le asigne corresponsal y se mueva.

### Bootstrap del superuser por env vars (no por `manage.py`)

Paperless ofrece dos caminos para crear el primer usuario:

1. `docker exec paperless python manage.py createsuperuser` (Django clásico): pregunta interactivamente username, email, password.
2. Variables `PAPERLESS_ADMIN_USER`, `PAPERLESS_ADMIN_MAIL` y `PAPERLESS_ADMIN_PASSWORD` en el `.env`: el _entrypoint_ las lee en cada arranque y, si **no existe ya** un usuario con ese nombre, lo crea con esas credenciales. Si existe, no toca nada (no resetea la password).

Política aplicada: **opción 2**. Razones idénticas a Linkding (`docs/11-productividad/03-linkding.md` → _Bootstrap del superuser_):

- **Reproducibilidad**: el bootstrap está en `~/homelab/productividad/.env`, custodiado igual que el resto de secrets. Una restauración en una Pi nueva crea automáticamente el operador en el primer arranque.
- **Cero interactividad**: no hay que ejecutar comandos manuales después de `make up`. El despliegue queda en `up -d` + verificar.
- **Seguridad**: tras el primer login, **se cambia la password** desde la UI a una nueva (anotada en Vaultwarden). La password del `.env` deja de ser válida (Paperless no la sobrescribe en futuros arranques porque "el usuario ya existe"). El `.env` se queda con la password vieja como fósil; no es un secreto activo.

> **Atención**: si se borra el usuario desde `Settings → Users` por error, el siguiente arranque del contenedor lo **recreará** con la password del `.env`. Esto es deseable como "ruta de recuperación" si el operador queda fuera. Si el operador no quiere ese comportamiento, debe **vaciar `PAPERLESS_ADMIN_PASSWORD`** tras el primer arranque.

### `USERMAP_UID`/`USERMAP_GID` y permisos de `consume/`

Paperless corre **como root** en el _entrypoint_ inicial para hacer `chown` de los _bind mounts_ y luego baja a `paperless` (UID por defecto 1000, GID por defecto 1000) para servir y consumir. Las variables `USERMAP_UID` y `USERMAP_GID` permiten **alinear ese UID con el del operador en el host**: si el operador es `homelab` (UID 1000, GID 1000), Paperless escribirá `media/`, `data/` y `export/` con dueño `1000:1000`, lo que el host ve como propiedad del usuario `homelab`.

Política:

```bash
USERMAP_UID=${PUID}      # 1000, definido en ~/homelab/.env global
USERMAP_GID=${PGID}      # 1000, definido en ~/homelab/.env global
```

> **Por qué importa para `consume/`**: la carpeta `/mnt/hd2t/services/paperless/consume/` también la usa **Samba** desde `docs/06-almacenamiento/02-samba.md`, con `force user = homelab` y `force group = homelab`. Si Samba escribe `recibo.pdf` como `homelab:homelab` (UID 1000:GID 1000) y Paperless intenta leer/borrar ese fichero como su propio UID **1000**, todo funciona. **Si los UIDs no coincidieran** (Paperless como UID 1001 por descuido), Paperless detectaría ficheros que no puede leer ni mover, los logs llenarían de `PermissionError: [Errno 13]`, y el operador vería ficheros _atascados_ en `consume/` que nunca se ingestan. Por eso `PUID=PGID=1000` es **vinculante** y se confirma en la verificación final.

### Almacenamiento

| Ruta en el host                                            | Contenido                                                                                                  | Versionable | Backup |
|------------------------------------------------------------|------------------------------------------------------------------------------------------------------------|-------------|--------|
| `~/homelab/productividad/docker-compose.yml`               | Definición del _stack_ (modificada — añade `paperless`, `paperless-db`, `paperless-redis`, `paperless-gotenberg`, `paperless-tika`) | git | git |
| `~/homelab/productividad/.env`                             | Imágenes pinneadas + `PAPERLESS_SECRET_KEY` + secrets DB + `PAPERLESS_ADMIN_*`                            | **NO** (`.gitignore`) | nota local (custodia separada) |
| `~/homelab/productividad/.env.example`                     | Plantilla con nombres de variables, sin valores                                                            | git         | git    |
| `/mnt/hd2t/services/paperless/data/`                       | Datos internos de Paperless (índice de búsqueda, classificadores ML, logs, settings persistidos por la app) | **NO**     | **Sí** (Borgmatic, copia raw — ligero, ~100 MB) |
| `/mnt/hd2t/services/paperless/media/documents/originals/`  | **Ficheros originales** tal como llegaron al consume folder. **Categoría A** (pérdida ≡ pérdida total)     | **NO**     | **Sí** (Borgmatic, copia raw — _source_directory_ del set "data") |
| `/mnt/hd2t/services/paperless/media/documents/archive/`    | PDFs archivados (con OCR aplicado, PDF/A). **Regenerables** desde los originales pero costoso (re-OCR de toda la BD = horas) | **NO** | **Sí** (Borgmatic, copia raw — extra cinturón) |
| `/mnt/hd2t/services/paperless/media/documents/thumbnails/` | Thumbnails JPG de cada documento. **Regenerables** trivialmente.                                           | **NO**     | No (excluido vía `exclude_patterns` de Borgmatic) |
| `/mnt/hd2t/services/paperless/consume/`                    | **Drop folder** de Paperless. Se vacía en cuanto cada doc se ingesta.                                      | **NO**     | No (transitorio: máximo unos minutos de retención) |
| `/mnt/hd2t/services/paperless/export/`                     | _Exports_ generados con `document_exporter` para migración o backup manual ad-hoc.                         | **NO**     | No (regenerable a demanda; si se quiere conservar un export concreto, copiarlo aparte) |
| `/mnt/hd2t/services/paperless/db/`                         | Cluster PostgreSQL de `paperless-db`. **Crítico** pero con dump SQL como _canon_                           | **NO**     | **Sí** (Borgmatic, vía `dump_postgres`; el directorio raw NO entra en _source_directories_) |
| `/mnt/hd2t/services/paperless/redis/`                      | _No existe_ (Redis sin persistencia)                                                                       | —           | —      |

> **Cuatro subdirectorios bajo `media/documents/`**: `originals/`, `archive/`, `thumbnails/`, `consume_files/` (este último está en _media_ por compatibilidad con Paperless Mobile, contiene ficheros recibidos por API). El _consumer_ los crea en el primer arranque; **no hay nada que pre-mkdir**.

> **Permisos**: tras el primer arranque, todo `/mnt/hd2t/services/paperless/{data,media,export}/` tiene ownership `1000:1000` (= `homelab:homelab` en el host). El _entrypoint_ de Paperless lo aplica recursivo. **Confirmar** después del primer arranque:
> ```bash
> stat -c '%U:%G' /mnt/hd2t/services/paperless/media/documents
> # homelab:homelab
> ```

> **`db/` separado**: el cluster Postgres tiene su propio _bind mount_, ownership `999:999` (= `postgres:postgres` dentro de la imagen oficial). El _entrypoint_ de Postgres hace su propio `chown`. Se respalda **sólo vía `pg_dump`**; la copia raw del directorio Postgres no es consistente sin parar el contenedor.

---

## Estructura del _stack_ `productividad` tras este documento

Antes de este documento (tras `docs/11-productividad/03-linkding.md`):

```
~/homelab/productividad/
├── docker-compose.yml        # contiene vaultwarden + bookstack + bookstack-db + linkding
├── .env                      # APP vars de los cuatro
├── .env.example
└── .gitignore
```

Tras este documento:

```
~/homelab/productividad/
├── docker-compose.yml        # ← MODIFICADO: añade paperless + paperless-db +
│                             #               paperless-redis + paperless-gotenberg + paperless-tika
├── .env                      # ← MODIFICADO: añade PAPERLESS_*, POSTGRES_*
├── .env.example              # ← MODIFICADO: añade plantilla PAPERLESS_*
└── .gitignore                # sin cambios
```

Y en el disco externo, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/paperless/
├── consume/                  # ya creada por 04-estructura-directorios.md, expuesta por Samba
├── data/                     # ← se crea al primer arranque del contenedor paperless
├── media/                    # ← se crea al primer arranque del contenedor paperless
│   └── documents/
│       ├── originals/        # ← categoría A
│       ├── archive/          # ← categoría A regenerable
│       ├── thumbnails/       # ← excluida del backup
│       └── consume_files/    # ← uploads vía API
├── export/                   # ya creada por 04-estructura-directorios.md
└── db/                       # ← se crea al primer arranque del contenedor paperless-db
```

Ningún cambio en `~/homelab/productividad/.gitignore` (ya excluye `.env`). Ningún subdirectorio _stub_ que crear a mano: las imágenes hacen _populate_ del bind mount en el primer arranque.

> **Confirmar el árbol** antes de seguir:
> ```bash
> ls -la /mnt/hd2t/services/paperless/
> # drwxr-xr-x consume/    <- ya creada
> # drwxr-xr-x export/     <- ya creada
> # (data/, media/, db/ se crean al primer up)
> ```
> Si por algún intento previo ya existiesen `data/`, `media/` o `db/` con datos antiguos, **borrarlos** antes del primer arranque limpio:
> ```bash
> sudo rm -rf /mnt/hd2t/services/paperless/{data,media,db}
> ```
> **Atención**: NO borrar `consume/` ni `export/` (las pre-creó `04-estructura-directorios.md` con ownership específico para Samba).

---

## Variables de entorno

### Ampliar `~/homelab/productividad/.env.example`

Abrir el fichero existente (ampliado en `docs/11-productividad/03-linkding.md`) y **añadir al final** un nuevo bloque (no tocar las líneas de Vaultwarden, Bookstack ni Linkding):

```bash
# ============================================================================
# Paperless-ngx — gestor documental con OCR (docs/11-productividad/04-paperless-ngx.md)
# ============================================================================

# --- Imágenes pinneadas -----------------------------------------------------
PAPERLESS_IMAGE_TAG=2.13.5
# Postgres reusable entre servicios del stack productividad si en el futuro
# llega otro Postgres-based aquí. De momento, sólo paperless-db.
POSTGRES_IMAGE_TAG=16-bookworm
REDIS_IMAGE_TAG=7-alpine
GOTENBERG_IMAGE_TAG=8.7
TIKA_IMAGE_TAG=latest

# --- Paperless — endpoint y dominio ----------------------------------------
# CRÍTICO: Paperless lo usa para construir URLs absolutas (password reset si
# SMTP, OIDC redirects) y para la lista de orígenes confiables CSRF de Django.
PAPERLESS_URL=https://paperless.lan
PAPERLESS_CSRF_TRUSTED_ORIGINS=https://paperless.lan
PAPERLESS_ALLOWED_HOSTS=paperless.lan,paperless,localhost

# Si Tailscale está desplegado (docs/03-red/05-tailscale.md), AÑADIR:
#   PAPERLESS_CSRF_TRUSTED_ORIGINS=https://paperless.lan,https://pi.tailnet.ts.net
#   PAPERLESS_ALLOWED_HOSTS=paperless.lan,pi.tailnet.ts.net,paperless,localhost
# Sin esto, los formularios POST devuelven 403 CSRF cuando se accede vía Tailscale.

# --- Paperless — clave de cifrado de Django --------------------------------
# Usada para firmar cookies de sesión, tokens de password reset, y settings
# encriptados en la BD. Si se pierde, las sesiones activas se invalidan.
# Si se REGENERA tras tener datos cifrados en BD, esos datos quedan ilegibles.
#
# Generación recomendada (al rellenar el .env real):
#   openssl rand -base64 64 | tr -d '/+=' | head -c 64
# Custodia: nota "Homelab — Paperless secrets" en Vaultwarden + papel.
PAPERLESS_SECRET_KEY=

# --- Paperless — bootstrap del superuser -----------------------------------
# Variables leídas en el primer arranque (cuando no hay usuarios en la BD).
# Crean el usuario operador automáticamente. Tras el primer login, el
# operador cambia la password desde 'Settings → User → Change password' y
# deja estas variables como fósiles inertes (Paperless no las re-aplica si
# el usuario ya existe).
#
# Generación del PAPERLESS_ADMIN_PASSWORD (al rellenar el .env real):
#   openssl rand -base64 32 | tr -d '/+=' | head -c 24
# Custodia: nota "Homelab — Paperless bootstrap" en Vaultwarden.
PAPERLESS_ADMIN_USER=operador
PAPERLESS_ADMIN_MAIL=operador@homelab.lan
PAPERLESS_ADMIN_PASSWORD=

# --- Paperless — política de registro y autenticación ----------------------
# Sin OIDC en este documento (ver sección "Migrar a OIDC" al final).
# El registro abierto NO existe en Paperless (siempre se crean usuarios desde
# Settings → Users); no hay variable que apagar.
PAPERLESS_ENABLE_HTTP_REMOTE_USER=false
PAPERLESS_DISABLE_REGULAR_LOGIN=false

# --- Paperless — conexión a PostgreSQL -------------------------------------
# Hostname coincide con container_name de paperless-db. Paperless se conecta
# por DNS interno de Docker dentro de productividad-internal.
PAPERLESS_DBENGINE=postgresql
PAPERLESS_DBHOST=paperless-db
PAPERLESS_DBPORT=5432
PAPERLESS_DBNAME=paperless
PAPERLESS_DBUSER=paperless

# Generación recomendada (al rellenar el .env real):
#   openssl rand -base64 48 | tr -d '/+=' | head -c 32
# Custodia: nota "Homelab — Paperless DB" en Vaultwarden.
PAPERLESS_DBPASS=

# --- PostgreSQL (paperless-db) — variables del init ------------------------
# IMPORTANTE: deben coincidir EXACTAMENTE con PAPERLESS_DBNAME / DBUSER /
# DBPASS para que el pg_dump de Borgmatic (que usa POSTGRES_USER, POSTGRES_DB,
# POSTGRES_PASSWORD del helper dump_postgres) funcione sin acrobacias.
POSTGRES_DB=paperless
POSTGRES_USER=paperless
POSTGRES_PASSWORD=         # = PAPERLESS_DBPASS, mismo valor

# --- Paperless — Redis broker ----------------------------------------------
# Hostname coincide con container_name. Sin password (Redis sin auth en red
# privada productividad-internal). Si se quisiera ponerla, Redis 7 admite
# 'requirepass' y Paperless la pasaría como redis://:pass@host:6379.
PAPERLESS_REDIS=redis://paperless-redis:6379

# --- Paperless — sidecars opcionales (Gotenberg + Tika) --------------------
# Comentar las dos líneas si NO se quieren los sidecars (formatos limitados
# a PDF + imágenes + texto plano). Recomendado: dejarlas activas.
PAPERLESS_TIKA_ENABLED=1
PAPERLESS_TIKA_GOTENBERG_ENDPOINT=http://paperless-gotenberg:3000
PAPERLESS_TIKA_ENDPOINT=http://paperless-tika:9998

# --- Paperless — OCR -------------------------------------------------------
# Idiomas instalados en la imagen oficial via apt (paquetes 'tesseract-ocr-spa'
# y 'tesseract-ocr-eng' ya están). Más idiomas: añadir a esta variable y
# reconstruir el contenedor para que descargue los language packs.
# Formato: códigos ISO 639-2/T separados por '+'.
PAPERLESS_OCR_LANGUAGE=spa+eng
PAPERLESS_OCR_LANGUAGES=spa eng

# Modo del OCR. 'skip' = sólo OCR si el PDF no tiene capa de texto (rápido).
# 'redo' = ignora la capa de texto existente y re-OCR (lento). 'force' =
# OCR siempre, incluso sobrescribiendo. 'skip_noarchive' = OCR pero no genera
# archive PDF/A si ya tenía capa OCR (raro).
PAPERLESS_OCR_MODE=skip

# DPI mínimo de salida. 300 es suficiente para la mayoría de papeles A4
# escaneados; subir a 600 sólo si el operador escanea con mucho detalle.
PAPERLESS_OCR_OUTPUT_TYPE=pdfa
PAPERLESS_OCR_PAGES=0      # 0 = todas las páginas
PAPERLESS_OCR_IMAGE_DPI=300

# --- Paperless — consumer (carpeta de consumo) -----------------------------
# Modo polling porque consume/ está en un bind mount y Samba no actualiza
# inotify de forma fiable cuando el escritor es el cliente SMB. Polling
# cada 10 s es imperceptible para el operador.
PAPERLESS_CONSUMER_POLLING=10
PAPERLESS_CONSUMER_DELETE_DUPLICATES=true
PAPERLESS_CONSUMER_RECURSIVE=true
PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS=true   # carpetas dentro de consume/ se vuelven tags
PAPERLESS_CONSUMER_IGNORE_PATTERNS=[".DS_Store/*", "._*", ".~lock*"]

# --- Paperless — convención de filenames -----------------------------------
# Estructura del archivo en disco:
#   media/documents/originals/<año>/<corresponsal>/<fecha> - <título>.<ext>
# Cambia esto solo conociendo las consecuencias (Paperless re-organiza los
# ficheros físicos en la siguiente carga si se modifica).
PAPERLESS_FILENAME_FORMAT={created_year}/{correspondent}/{created} - {title}
PAPERLESS_FILENAME_FORMAT_REMOVE_NONE=true

# --- Paperless — tareas Celery ---------------------------------------------
# Pi 5 8 GB: 2 workers + 2 threads por worker = 4 OCR concurrentes a tope
# de CPU. Si el operador nota la Pi caliente o lenta, bajar a 1+1.
PAPERLESS_TASK_WORKERS=2
PAPERLESS_THREADS_PER_WORKER=2

# --- Paperless — locale y zona horaria -------------------------------------
PAPERLESS_TIME_ZONE=Europe/Madrid

# --- Paperless — UID/GID de los procesos internos --------------------------
# Coincidir con PUID/PGID del homelab para que los ficheros escritos por
# Paperless en /mnt/hd2t/services/paperless/ sean propiedad del operador.
USERMAP_UID=${PUID}
USERMAP_GID=${PGID}

# --- Paperless — varios ----------------------------------------------------
# Compresión interna de la BD (campos de texto). Reduce ~30% el tamaño.
PAPERLESS_DB_TIMEOUT=60

# Apagar la verificación SSL del cliente HTTP que Paperless usa para
# Tika/Gotenberg internos (productividad-internal es red privada, sin TLS).
# False es el default; explicitar por claridad.
PAPERLESS_OCR_USER_ARGS={"invalidate_digital_signatures": true}

# --- SMTP (opcional, ver sección 'SMTP opcional' al final) -----------------
# Vacío = funcionalidad de email deshabilitada. Sin SMTP siguen funcionando
# login y la wiki; sólo se pierden notificaciones, password reset por email
# y la "ingesta por email" (PAPERLESS_EMAIL_*) si se activase.
# PAPERLESS_EMAIL_HOST=
# PAPERLESS_EMAIL_PORT=587
# PAPERLESS_EMAIL_HOST_USER=
# PAPERLESS_EMAIL_HOST_PASSWORD=
# PAPERLESS_EMAIL_USE_TLS=true
# PAPERLESS_EMAIL_FROM=paperless@homelab.example

# --- OIDC (opcional, ver sección 'Migrar a OIDC con Authelia' al final) ----
# PAPERLESS_APPS=allauth.socialaccount.providers.openid_connect
# PAPERLESS_SOCIALACCOUNT_PROVIDERS=
# PAPERLESS_DISABLE_REGULAR_LOGIN=false
```

### Ampliar `~/homelab/productividad/.env`

Copiar las nuevas líneas de la plantilla y rellenar los valores reales. Hay tres secrets a generar (la `SECRET_KEY` de Django, la password de Postgres y la password del superuser de Paperless):

```bash
# Editar el .env existente (tiene ya los valores de Vaultwarden, Bookstack y
# Linkding; AÑADIR debajo las nuevas líneas).
$EDITOR ~/homelab/productividad/.env

# 1. Generar PAPERLESS_SECRET_KEY (64 chars sin /+=)
secret_key=$(openssl rand -base64 96 | tr -d '/+=' | head -c 64)
echo "PAPERLESS_SECRET_KEY (anotar en Vaultwarden — nota 'Homelab — Paperless secrets'): $secret_key"
sed -i "s|^PAPERLESS_SECRET_KEY=$|PAPERLESS_SECRET_KEY=$secret_key|" ~/homelab/productividad/.env

# 2. Generar password de la BD (32 chars sin /+=)
db_pass=$(openssl rand -base64 48 | tr -d '/+=' | head -c 32)
echo "PAPERLESS_DBPASS (anotar en Vaultwarden — nota 'Homelab — Paperless DB'): $db_pass"
sed -i "s|^PAPERLESS_DBPASS=$|PAPERLESS_DBPASS=$db_pass|" ~/homelab/productividad/.env
sed -i "s|^POSTGRES_PASSWORD=.*$|POSTGRES_PASSWORD=$db_pass|" ~/homelab/productividad/.env
# CRÍTICO: las dos variables (PAPERLESS_DBPASS y POSTGRES_PASSWORD) tienen
# el mismo valor. Es lo que permite que dump_postgres del hook de Borgmatic
# se autentique con el mismo secret que usa Paperless para conectar a la BD.

# 3. Generar el PAPERLESS_ADMIN_PASSWORD (24 chars sin /+=)
admin_pass=$(openssl rand -base64 32 | tr -d '/+=' | head -c 24)
echo "PAPERLESS_ADMIN_PASSWORD (anotar en Vaultwarden — nota 'Homelab — Paperless bootstrap'): $admin_pass"
sed -i "s|^PAPERLESS_ADMIN_PASSWORD=$|PAPERLESS_ADMIN_PASSWORD=$admin_pass|" ~/homelab/productividad/.env

# 4. Confirmar que los tres están y que las dos passwords de BD coinciden
grep -E '^(PAPERLESS_SECRET_KEY|PAPERLESS_DBPASS|POSTGRES_PASSWORD|PAPERLESS_ADMIN_PASSWORD)=' ~/homelab/productividad/.env
# PAPERLESS_SECRET_KEY=...
# PAPERLESS_DBPASS=...        <- estos dos
# POSTGRES_PASSWORD=...       <- deben ser idénticos
# PAPERLESS_ADMIN_PASSWORD=...

# 5. Asegurar permisos restrictivos del .env
chmod 0600 ~/homelab/productividad/.env

# 6. Limpiar las variables de la sesión
unset secret_key db_pass admin_pass
```

> **Custodia inmediata**: añadir las tres entradas a Vaultwarden **antes** de seguir adelante. La pérdida de `PAPERLESS_SECRET_KEY` invalida sesiones y `settings` cifrados (los `correspondents`, `tags`, `document_types` que el operador haya creado siguen estando, pero los _settings_ encriptados —como las credenciales SMTP si se hubiesen guardado— quedan basura). Custodia separada del repo:
>
> - `Homelab — Paperless secrets`: `PAPERLESS_SECRET_KEY`.
> - `Homelab — Paperless DB`: `PAPERLESS_DBPASS` (= `POSTGRES_PASSWORD`).
> - `Homelab — Paperless bootstrap`: `PAPERLESS_ADMIN_USER` + `PAPERLESS_ADMIN_PASSWORD` (la del primer arranque, que dejará de ser canon tras cambiar la del operador en runtime).

> **Por qué `tr -d '/+='`**: igual razón que en `docs/11-productividad/02-bookstack.md` y `docs/11-productividad/03-linkding.md` — `openssl rand -base64` puede emitir `/`, `+` o `=`; molestos al copiar/pegar y problemáticos si algún cliente parsea los valores como _URL_ sin escapar.

> **No commitear `.env` jamás**. El `.gitignore` del _stack_ ya lo excluye explícitamente.

---

## Modificar `~/homelab/productividad/docker-compose.yml`

El _docker-compose.yml_ de este _stack_ ya existe con `vaultwarden`, `bookstack`, `bookstack-db` y `linkding`. **Editarlo, no recrearlo**: añadir los cinco servicios nuevos (Paperless + 4 sidecars) y enchufar `paperless` también a `productividad-internal`. Los cuatro contenedores anteriores quedan **intactos**.

Los nuevos servicios se añaden al final de la sección `services:`, justo antes de la sección `networks:`:

```yaml
  # ===========================================================================
  # PostgreSQL — base de datos de Paperless-ngx.
  # Sólo en productividad-internal; no se expone al host ni a 'homelab'.
  # ===========================================================================
  paperless-db:
    image: postgres:${POSTGRES_IMAGE_TAG}
    container_name: paperless-db
    hostname: paperless-db
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      # Locale español para ordering correcto y FTS español si se activa.
      POSTGRES_INITDB_ARGS: "--locale=es_ES.UTF-8 --lc-collate=es_ES.UTF-8 --lc-ctype=es_ES.UTF-8 --encoding=UTF-8"
      LANG: es_ES.UTF-8
    volumes:
      - /mnt/hd2t/services/paperless/db:/var/lib/postgresql/data
    networks:
      - productividad-internal
    labels:
      homelab.stack: "productividad"
      homelab.backup: "true"      # vía dump_postgres (hook Borgmatic)
      # Opt-out: bumps de major requieren pg_upgrade. Manual.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      test:
        - CMD-SHELL
        - "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 30s

  # ===========================================================================
  # Redis — broker de Celery para Paperless. Sin persistencia.
  # Sólo en productividad-internal.
  # ===========================================================================
  paperless-redis:
    image: redis:${REDIS_IMAGE_TAG}
    container_name: paperless-redis
    hostname: paperless-redis
    restart: unless-stopped
    # Sin appendonly, sin save: sólo cola de tasks volátil.
    command:
      - redis-server
      - --save
      - ""
      - --appendonly
      - "no"
    networks:
      - productividad-internal
    labels:
      homelab.stack: "productividad"
      homelab.backup: "false"     # nada que respaldar (sin persistencia)
      # Opt-out: bumps de major pueden cambiar protocolo. Manual.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 15s
      timeout: 3s
      retries: 5
      start_period: 5s

  # ===========================================================================
  # Gotenberg — LibreOffice headless para convertir Office a PDF.
  # Sólo en productividad-internal.
  # ===========================================================================
  paperless-gotenberg:
    image: gotenberg/gotenberg:${GOTENBERG_IMAGE_TAG}
    container_name: paperless-gotenberg
    hostname: paperless-gotenberg
    restart: unless-stopped
    # Recomendaciones del upstream de Paperless para Gotenberg:
    command:
      - "gotenberg"
      - "--chromium-disable-javascript=true"
      - "--chromium-allow-list=file:///tmp/.*"
    networks:
      - productividad-internal
    labels:
      homelab.stack: "productividad"
      homelab.backup: "false"     # stateless
      # Opt-out: cambios en LibreOffice headless entre majors. Manual.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:3000/health >/dev/null"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 15s

  # ===========================================================================
  # Apache Tika — extracción de texto de documentos no-PDF/no-imagen.
  # Sólo en productividad-internal.
  # ===========================================================================
  paperless-tika:
    image: ghcr.io/paperless-ngx/tika:${TIKA_IMAGE_TAG}
    container_name: paperless-tika
    hostname: paperless-tika
    restart: unless-stopped
    networks:
      - productividad-internal
    labels:
      homelab.stack: "productividad"
      homelab.backup: "false"     # stateless
      # Opt-out: imagen :latest del wrapper de Paperless. Manual.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:9998/tika >/dev/null"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s   # arranque de la JVM en ARM64 tarda

  # ===========================================================================
  # Paperless-ngx — la app (Django + Celery worker + consumer).
  # En 'homelab' (Caddy la alcanza por DNS) Y en 'productividad-internal'
  # (alcanza a la BD, Redis, Gotenberg y Tika).
  # ===========================================================================
  paperless:
    image: ghcr.io/paperless-ngx/paperless-ngx:${PAPERLESS_IMAGE_TAG}
    container_name: paperless
    hostname: paperless
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      USERMAP_UID: ${USERMAP_UID}
      USERMAP_GID: ${USERMAP_GID}

      # --- Endpoint y reverse proxy ---
      PAPERLESS_URL: ${PAPERLESS_URL}
      PAPERLESS_CSRF_TRUSTED_ORIGINS: ${PAPERLESS_CSRF_TRUSTED_ORIGINS}
      PAPERLESS_ALLOWED_HOSTS: ${PAPERLESS_ALLOWED_HOSTS}
      PAPERLESS_TRUSTED_PROXIES: 172.20.10.0/24

      # --- Cifrado Django ---
      PAPERLESS_SECRET_KEY: ${PAPERLESS_SECRET_KEY}

      # --- Autenticación ---
      PAPERLESS_ADMIN_USER: ${PAPERLESS_ADMIN_USER}
      PAPERLESS_ADMIN_MAIL: ${PAPERLESS_ADMIN_MAIL}
      PAPERLESS_ADMIN_PASSWORD: ${PAPERLESS_ADMIN_PASSWORD}
      PAPERLESS_ENABLE_HTTP_REMOTE_USER: ${PAPERLESS_ENABLE_HTTP_REMOTE_USER}
      PAPERLESS_DISABLE_REGULAR_LOGIN: ${PAPERLESS_DISABLE_REGULAR_LOGIN}

      # --- Base de datos ---
      PAPERLESS_DBENGINE: ${PAPERLESS_DBENGINE}
      PAPERLESS_DBHOST: ${PAPERLESS_DBHOST}
      PAPERLESS_DBPORT: ${PAPERLESS_DBPORT}
      PAPERLESS_DBNAME: ${PAPERLESS_DBNAME}
      PAPERLESS_DBUSER: ${PAPERLESS_DBUSER}
      PAPERLESS_DBPASS: ${PAPERLESS_DBPASS}
      PAPERLESS_DB_TIMEOUT: ${PAPERLESS_DB_TIMEOUT}

      # --- Redis broker ---
      PAPERLESS_REDIS: ${PAPERLESS_REDIS}

      # --- Sidecars Tika + Gotenberg ---
      PAPERLESS_TIKA_ENABLED: ${PAPERLESS_TIKA_ENABLED}
      PAPERLESS_TIKA_GOTENBERG_ENDPOINT: ${PAPERLESS_TIKA_GOTENBERG_ENDPOINT}
      PAPERLESS_TIKA_ENDPOINT: ${PAPERLESS_TIKA_ENDPOINT}

      # --- OCR ---
      PAPERLESS_OCR_LANGUAGE: ${PAPERLESS_OCR_LANGUAGE}
      PAPERLESS_OCR_LANGUAGES: ${PAPERLESS_OCR_LANGUAGES}
      PAPERLESS_OCR_MODE: ${PAPERLESS_OCR_MODE}
      PAPERLESS_OCR_OUTPUT_TYPE: ${PAPERLESS_OCR_OUTPUT_TYPE}
      PAPERLESS_OCR_PAGES: ${PAPERLESS_OCR_PAGES}
      PAPERLESS_OCR_IMAGE_DPI: ${PAPERLESS_OCR_IMAGE_DPI}
      PAPERLESS_OCR_USER_ARGS: ${PAPERLESS_OCR_USER_ARGS}

      # --- Consumer (carpeta de consumo) ---
      PAPERLESS_CONSUMER_POLLING: ${PAPERLESS_CONSUMER_POLLING}
      PAPERLESS_CONSUMER_DELETE_DUPLICATES: ${PAPERLESS_CONSUMER_DELETE_DUPLICATES}
      PAPERLESS_CONSUMER_RECURSIVE: ${PAPERLESS_CONSUMER_RECURSIVE}
      PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS: ${PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS}
      PAPERLESS_CONSUMER_IGNORE_PATTERNS: ${PAPERLESS_CONSUMER_IGNORE_PATTERNS}

      # --- Filenames y locale ---
      PAPERLESS_FILENAME_FORMAT: ${PAPERLESS_FILENAME_FORMAT}
      PAPERLESS_FILENAME_FORMAT_REMOVE_NONE: ${PAPERLESS_FILENAME_FORMAT_REMOVE_NONE}
      PAPERLESS_TIME_ZONE: ${PAPERLESS_TIME_ZONE}

      # --- Tareas Celery ---
      PAPERLESS_TASK_WORKERS: ${PAPERLESS_TASK_WORKERS}
      PAPERLESS_THREADS_PER_WORKER: ${PAPERLESS_THREADS_PER_WORKER}

      # --- SMTP (opcional, descomentar cuando se configure) ---
      # PAPERLESS_EMAIL_HOST: ${PAPERLESS_EMAIL_HOST}
      # PAPERLESS_EMAIL_PORT: ${PAPERLESS_EMAIL_PORT}
      # PAPERLESS_EMAIL_HOST_USER: ${PAPERLESS_EMAIL_HOST_USER}
      # PAPERLESS_EMAIL_HOST_PASSWORD: ${PAPERLESS_EMAIL_HOST_PASSWORD}
      # PAPERLESS_EMAIL_USE_TLS: ${PAPERLESS_EMAIL_USE_TLS}
      # PAPERLESS_EMAIL_FROM: ${PAPERLESS_EMAIL_FROM}
    volumes:
      - /mnt/hd2t/services/paperless/data:/usr/src/paperless/data
      - /mnt/hd2t/services/paperless/media:/usr/src/paperless/media
      - /mnt/hd2t/services/paperless/consume:/usr/src/paperless/consume
      - /mnt/hd2t/services/paperless/export:/usr/src/paperless/export
    networks:
      homelab:
        aliases:
          - paperless         # Caddy resuelve 'paperless:8000' por este alias
      productividad-internal:
        # alcanza a paperless-db, paperless-redis, paperless-gotenberg, paperless-tika
    labels:
      homelab.stack: "productividad"
      homelab.backup: "true"      # /mnt/hd2t/services/paperless/{data,media} (raw)
      # Opt-out: las upgrades de Paperless ejecutan migraciones. Manual.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      # /api/ devuelve 200 + JSON con la versión cuando el WSGI sirve y la
      # BD responde. Endpoint estable desde Paperless-ngx 1.x.
      test:
        - CMD-SHELL
        - "curl -fsS http://localhost:8000/api/ >/dev/null"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s   # primer arranque: migrate + bootstrap superuser ~90 s
    depends_on:
      paperless-db:
        condition: service_healthy
      paperless-redis:
        condition: service_healthy
      paperless-gotenberg:
        condition: service_healthy
      paperless-tika:
        condition: service_healthy
```

> **Importante** — los cinco servicios se añaden **dentro** del bloque `services:` ya existente, **NO sustituyen** nada. Validar después con `docker compose config | grep -E '^\s+(vaultwarden|bookstack|bookstack-db|linkding|paperless|paperless-db|paperless-redis|paperless-gotenberg|paperless-tika):'` que los nueve siguen estando.

> **Nota sobre la red `productividad-internal`**: en el `networks:` global del compose ya está definida desde Bookstack (`docs/11-productividad/02-bookstack.md`). **No** hay que volver a declararla. Sólo `paperless`, `paperless-db`, `paperless-redis`, `paperless-gotenberg` y `paperless-tika` se enchufan a ella.

Notas de diseño:

- **Sólo `paperless` está en `homelab`**. Los otros cuatro contenedores se quedan en `productividad-internal` y son inalcanzables desde Caddy o desde otros _stacks_, igual que `bookstack-db` lo es. Cumple el principio de "sólo el _front_ de cada _stack_ se publica al resto del homelab", igual que Nextcloud y Bookstack.
- **`depends_on` con `condition: service_healthy`** en los cuatro sidecars: garantiza que cuando Paperless arranca, la BD ya está aceptando conexiones, Redis ya hace `PONG`, Gotenberg responde `/health` y Tika responde a `/tika`. Sin esto, el primer arranque de Paperless tendría retries ruidosos en logs.
- **`start_period: 120s`** en `paperless`: el primer arranque ejecuta `migrate` (~25 migraciones), `compilemessages`, crea el _index_ Whoosh-style si está vacío, y bootstrappea el superuser. Es la operación más larga del _stack_; con `start_period` corto el _healthcheck_ daría `unhealthy` espuriamente y Compose intentaría reiniciar el contenedor en plena instalación. 120 s es holgado; en arranques posteriores, `(healthy)` llega en <30 s.
- **Sin `ports:`** en ningún servicio. Caddy alcanza Paperless por DNS interno (`paperless:8000`). Si el operador, durante troubleshooting, necesita acceder sin pasar por Caddy: `docker exec -it paperless curl -fsS http://localhost:8000/api/`.
- **Watchtower opt-out** en los cinco: razones explicadas en **Decisiones de diseño** → _Imágenes y tags_.
- **`PAPERLESS_TRUSTED_PROXIES: 172.20.10.0/24`**: subnet de la red Docker `homelab`. Sin esto, Paperless ignora `X-Forwarded-Proto` que envía Caddy y construye URLs `http://...` en los emails (cookies sin `Secure`, mixed content). Equivalente al `APP_PROXIES` de Bookstack.
- **`USERMAP_UID`/`USERMAP_GID`** en `paperless` (no en los otros): sólo Paperless escribe a `/mnt/hd2t/services/paperless/{data,media,export}/` en nombre del usuario host; los demás escriben a sus propios bind mounts (`paperless-db` → `db/`, gestionado por la imagen oficial de Postgres con UID 999).

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/productividad
# Validar la sintaxis sin levantar nada (recomendado tras editar el compose).
docker compose --env-file ../.env --env-file .env config | \
    grep -E '^\s+(vaultwarden|bookstack|bookstack-db|linkding|paperless|paperless-db|paperless-redis|paperless-gotenberg|paperless-tika):'
# vaultwarden:
# bookstack-db:
# bookstack:
# linkding:
# paperless-db:
# paperless-redis:
# paperless-gotenberg:
# paperless-tika:
# paperless:

# Levantar SÓLO los servicios nuevos (los cuatro previos ya están corriendo y healthy):
docker compose --env-file ../.env --env-file .env up -d \
    paperless-db paperless-redis paperless-gotenberg paperless-tika paperless
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=productividad
# El make up no es selectivo: lleva el stack completo al estado deseado.
# Como los cuatro previos ya están up y nada del compose los cambia,
# Compose los deja tal cual y arranca los cinco nuevos.
```

Vigilar el primer arranque (tarda ~120 s en una Pi 5):

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml logs -f \
    paperless-db paperless-redis paperless paperless-gotenberg paperless-tika
# paperless-db        | LOG:  database system is ready to accept connections
# paperless-redis     | Ready to accept connections tcp
# paperless-gotenberg | {"level":"info","msg":"http server started on port 3000"}
# paperless-tika      | INFO  org.apache.tika.server.core.TikaServerCore - Started Tika server at http://localhost:9998/
# paperless           | Paperless-ngx docker container starting...
# paperless           | Mapping UID and GID for paperless:paperless to 1000:1000
# paperless           | Apply database migrations...
# paperless           |  ... (~25 Django migrations) ...
# paperless           | Creating superuser 'operador'
# paperless           | Superuser 'operador' was created with the password from the env variable.
# paperless           | Starting paperless services...
# paperless           | [INFO] Listening on http://0.0.0.0:8000
```

Verificar que los cinco contenedores están `(healthy)`:

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml ps
# NAME                  STATUS                   PORTS
# vaultwarden           Up X minutes (healthy)
# bookstack-db          Up X minutes (healthy)
# bookstack             Up X minutes (healthy)
# linkding              Up X minutes (healthy)
# paperless-db          Up X seconds (healthy)
# paperless-redis       Up X seconds (healthy)
# paperless-gotenberg   Up X seconds (healthy)
# paperless-tika        Up X seconds (healthy)
# paperless             Up X seconds (healthy)
```

> El `(healthy)` de `paperless` lo otorga el _healthcheck_ de `/api/`. Si tras 3 minutos sigue `starting`/`unhealthy`, ir a **Troubleshooting** → primer arranque.

Confirmar que la BD se creó bien:

```bash
docker exec paperless-db psql -U paperless -d paperless -c "\dt" | head -20
# Debe listar tablas como auth_user, documents_document, documents_correspondent,
# documents_tag, documents_documenttype, etc.

docker exec paperless-db psql -U paperless -d paperless -c \
    "SELECT username, is_superuser FROM auth_user;"
# username  | is_superuser
# operador  | t
```

Y que los _bind mounts_ tienen el ownership correcto:

```bash
ls -la /mnt/hd2t/services/paperless/
# drwxr-xr-x  homelab homelab   ... data/
# drwxr-xr-x  homelab homelab   ... media/
# drwxr-xr-x  homelab homelab   ... consume/   (ya estaba; sin cambios)
# drwxr-xr-x  homelab homelab   ... export/
# drwxr-xr-x   999     999      ... db/         (postgres del contenedor)
```

(El UID/GID `999` del directorio `db/` es `postgres:postgres` dentro del contenedor; en el host aparecen como `999:999` sin nombre porque ese UID no está mapeado a un usuario del host. **Es lo esperado**.)

### Caddy: bloque `paperless.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque:

```caddy
paperless.lan {
    tls internal
    import security-headers
    import logging

    # Subidas grandes (PDFs escaneados a 600 DPI multipage). Caddy no impone
    # límite por defecto; Paperless tampoco. Pasar tal cual.
    request_body {
        max_size 100MB
    }

    # Pasar a Paperless tal cual. Caddy reescribe Host por defecto, lo que
    # combinado con PAPERLESS_URL=https://paperless.lan y
    # PAPERLESS_CSRF_TRUSTED_ORIGINS del .env, permite a Paperless pasar la
    # verificación CSRF de Django y construir URLs https:// correctas.
    reverse_proxy paperless:8000 {
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
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Probar (la CA local debe estar importada en el navegador, ver `docs/03-red/04-caddy.md`):

```bash
curl -k --resolve paperless.lan:443:192.168.1.3 https://paperless.lan/api/ \
    -H "Accept: application/json"
# {"correspondents":"https://paperless.lan/api/correspondents/",
#  "document_types":"https://paperless.lan/api/document_types/",
#  "documents":"https://paperless.lan/api/documents/", ...}

# Y el endpoint de la web (200 + redirect a /accounts/login si no hay cookie):
curl -k --resolve paperless.lan:443:192.168.1.3 -o /dev/null -s -w "%{http_code}\n" \
    https://paperless.lan/
# 302
```

Y desde el navegador: `https://paperless.lan/` → pantalla de login con candado verde y formulario que pide username + password.

---

## Configuración tras primer arranque

### 1. Login y cambio de password

El bootstrap creó el usuario `operador` con la password de `PAPERLESS_ADMIN_PASSWORD`. **Antes de cualquier otra cosa**:

1. `Log in` con `operador` / la password del `.env`.
2. Click en el icono de avatar (esquina superior derecha) → `My Profile` → `Change password`.
3. Generar una password fuerte (≥ 16 chars) en Vaultwarden, anotarla _antes_ de pegarla. Confirmar.
4. Logout y volver a hacer login con la nueva password. Verificar que se entra sin pedir reset.
5. Actualizar la nota "Homelab — Paperless bootstrap" en Vaultwarden con la **nueva** password (la del runtime), dejando como histórico la del bootstrap.

> **No vaciar `PAPERLESS_ADMIN_PASSWORD` del `.env`** automáticamente: dejarlo permite, en un escenario de DR, recrear el usuario si por error se borrase. Si el operador prefiere que el `.env` no contenga la password vieja, vaciar `PAPERLESS_ADMIN_PASSWORD=` y `up -d paperless` — el _entrypoint_ no recrea ni borra al usuario existente; sólo dejaría de tener fallback automático.

### 2. Activar 2FA TOTP (recomendado)

Paperless integra TOTP nativo desde 2.0. Activación por usuario:

1. `My Profile → Settings → Two-factor authentication → Set up`.
2. Escanear el QR con Aegis / Authy / 1Password / `oath-tool`.
3. Confirmar con un código TOTP válido.
4. Paperless muestra los **recovery tokens**. **Imprescindible**: copiarlos a "Homelab — Paperless secrets" en Vaultwarden. Si el dispositivo TOTP se pierde y los recovery tokens también, el único camino es resetear el MFA del usuario desde el shell de Django (descrito en **Troubleshooting**).

> **Por qué activar MFA antes de generar el API token**: el token de API **no respeta** MFA — un atacante con el token bypassea TOTP. MFA blinda el _login web_ y la creación de **nuevos** tokens. El token ya creado, si se filtra, sigue siendo válido hasta que se revoque. Por eso (a) MFA primero, (b) token después con custodia estricta en Vaultwarden.

### 3. Generar el token de API para las apps móviles y CLIs

La app móvil [Paperless Mobile](https://github.com/astubenbord/paperless-mobile) y los _clients_ CLI autentican con un token por usuario:

1. `My Profile → Settings → Authorization Tokens → Create New Token`.
2. Paperless muestra un token de 40 chars hex (ej. `a1b2c3d4e5f6...`).
3. **Copiarlo a Vaultwarden** (nota "Homelab — Paperless API token") — no se vuelve a mostrar; si se pierde, hay que revocarlo y generar uno nuevo (operación reversible pero molesta porque rompe todos los _clients_ a la vez).

> **Múltiples tokens por usuario**: a diferencia de Linkding (un único token por usuario), Paperless permite generar varios tokens (uno por dispositivo/uso). Recomendable mantener uno por dispositivo: "iPhone-share", "Android-mobile", "scripts-cli", "n8n-integration", para revocar selectivamente si uno se filtra.

### 4. Configurar Paperless Mobile (Android/iOS)

1. Instalar [Paperless Mobile](https://play.google.com/store/apps/details?id=de.astubenbord.paperless_mobile) (Android) o iOS equivalente.
2. **First-time setup**:
   - **Server URL**: `https://paperless.lan/` (con barra final). **Importante**: la app móvil debe estar conectada a la LAN, o vía Tailscale; Pi-hole debe resolver `paperless.lan` también para el móvil (ver `docs/03-red/02-pihole.md`).
   - **API token**: el de `My Profile → Authorization Tokens` (paso anterior).
   - **Test connection**: la app hace `GET /api/`. Debe responder 200.
3. **Para usar `Share` desde el móvil**: cualquier visor PDF / cámara / Drive → Compartir → `Paperless Mobile`. La app sube el doc a `/api/documents/post_document/`, Paperless lo encola en Celery, OCR, archiva. Aparece en la lista en ~30-60 s.

> **Si el móvil no confía en la CA local del homelab**, la app falla con `Network error` o `Certificate error`. Importar la CA local en el móvil (ver `docs/03-red/04-caddy.md`). En iOS hay que **además** instalar la CA en `Settings → General → About → Certificate Trust Settings` y activarla manualmente.

### 5. Estructura inicial de _correspondents_, _tags_, _document types_

Paperless modela cada documento con tres dimensiones ortogonales (más fecha y título). **No** hay que pre-crear nada — Paperless las puede crear "on-the-fly" según se ingestan documentos. Pero, para que el clasificador automático tenga material desde el principio, conviene dejar listo un esqueleto mínimo:

**Correspondents** (`Settings → Correspondents`):

| Correspondent       | Comentario                                              |
|---------------------|---------------------------------------------------------|
| `Banco Santander`   | Banco principal del operador                            |
| `Movistar`          | Operador de telefonía/internet                          |
| `Iberdrola`         | Compañía eléctrica                                      |
| `Mutua Madrileña`   | Aseguradora                                             |
| `Hacienda`          | Agencia Tributaria                                      |
| `Ayuntamiento`      | Comunicaciones del ayuntamiento                         |
| `Mercadona`         | Tickets de supermercado (si se quiere granularidad)     |

**Tags** (`Settings → Tags`):

| Tag           | Color       | Comentario                                  |
|---------------|-------------|---------------------------------------------|
| `factura`     | rojo        | Cualquier factura (recibida o emitida)      |
| `recibo`      | naranja     | Pagos recurrentes ya hechos                 |
| `contrato`    | azul        | Contratos firmados (alquiler, servicios, …) |
| `nómina`      | verde       | Nóminas mensuales del operador              |
| `medico`      | rosa        | Recetas, informes, justificantes médicos    |
| `garantía`    | gris        | Tickets/manuales de electrónica con garantía|
| `revisar`    | amarillo    | _Bandeja de entrada_: doc con texto extraído pero pendiente de etiquetar a mano |

**Document types** (`Settings → Document Types`):

| Type          | Comentario                                        |
|---------------|---------------------------------------------------|
| `Factura`     | Documento financiero, suele ser "factura …" en el título |
| `Contrato`    | Acuerdos formales con duración                    |
| `Carta`       | Correspondencia genérica                          |
| `Manual`      | Manuales de productos                             |
| `Certificado` | Documentos oficiales (notariado, registro civil, …) |

> **Convivencia con el `consume/` por subdirectorios**: con `PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS=true`, si el operador deja un fichero en `consume/factura/` Paperless le asigna automáticamente el tag `factura`. Aprovechable: estructurar `consume/` con subdirectorios `factura/`, `recibo/`, `medico/`, `revisar/` (los que el operador use a diario) ahorra mucho click después.

### 6. (Opcional) Activar el clasificador automático

Tras unos cientos de documentos manualmente etiquetados, Paperless puede entrenar un clasificador y empezar a sugerir/auto-asignar:

1. `Settings → Settings → Auto-Classify`.
2. **Tagging**: `Auto` (sugiere y aplica si la confianza ≥ umbral).
3. **Document type**: `Auto`.
4. **Correspondent**: `Auto`.
5. Save.

Tras esto, una task semanal de Celery (`Train classifier`) entrena el modelo (KNN sobre TF-IDF de los textos OCR) y lo guarda en `data/classification_model.pickle`. **No reentrenar a mano**; basta con etiquetar más documentos y esperar al próximo ciclo.

> **Atención**: el clasificador asigna **a partir del momento de la activación**; los documentos ya etiquetados no se re-clasifican. Si el operador quiere re-clasificarlos: `Selección masiva → Auto Classify Selected` desde la UI.

### 7. Activar el bloque del _hook_ de Borgmatic

`docs/07-backups/03-backup-docker-volumes.md` dejó preparada la línea comentada:

```bash
# --- Paperless-ngx (PostgreSQL + media/originals) — docs/11-productividad/04-paperless-ngx.md
# dump_postgres paperless paperless-db "$HOMELAB/productividad/.env"
# /mnt/hd2t/services/paperless/media/documents/originals/ entra como source_directory.
```

Descomentar la primera línea (la del `dump_postgres`):

```bash
# Localizar el script del hook
hook=~/homelab/backups/borgmatic/hooks/dump-databases.sh
ls -la "$hook"

# Descomentar la línea (o usar el editor interactivo).
# Variante con sed:
sed -i 's|^# dump_postgres paperless paperless-db "\$HOMELAB/productividad/\.env"$|dump_postgres paperless paperless-db "$HOMELAB/productividad/.env"|' "$hook"

# Validar la sintaxis bash:
bash -n "$hook" && echo OK

# Reinstalar el hook (copia el script a /etc/borgmatic.d/hooks/, ver
# docs/07-backups/03-backup-docker-volumes.md → install.sh):
~/homelab/backups/borgmatic/install.sh
```

Probar el _hook_ ad hoc sin esperar a las 03:30 AM:

```bash
sudo BORG_PASSPHRASE_FILE=/etc/borgmatic.d/secrets.env \
    bash /etc/borgmatic.d/hooks/dump-databases.sh

ls -la /mnt/hd2t/backups/dumps/ | grep paperless
# paperless-2026-04-26.sql.gz   ~50–500 KB para una BD recién creada
```

Verificar que el dump es válido:

```bash
gunzip -c /mnt/hd2t/backups/dumps/paperless-$(date +%F).sql.gz | head -20
# -- PostgreSQL database dump
# --
# -- Dumped from database version 16.x
# -- Dumped by pg_dump version 16.x
# ...
# DROP TABLE IF EXISTS "public"."documents_document";

# Tablas críticas presentes:
gunzip -c /mnt/hd2t/backups/dumps/paperless-$(date +%F).sql.gz | \
    grep -oE 'CREATE TABLE "public"\."[^"]+"' | sort -u
# CREATE TABLE "public"."auth_user"
# CREATE TABLE "public"."authtoken_token"
# CREATE TABLE "public"."django_migrations"
# CREATE TABLE "public"."documents_correspondent"
# CREATE TABLE "public"."documents_document"
# CREATE TABLE "public"."documents_documenttype"
# CREATE TABLE "public"."documents_tag"
# ... (~30 tablas)
```

Y, además del dump SQL, **añadir `originals/` y `archive/` como _source_directories_** del set "data" de Borgmatic (la segunda y tercera línea del bloque comentado del hook eran sólo recordatorios; el cambio real es en el config de Borgmatic):

```bash
# Editar el config de Borgmatic; sección 'source_directories:' del set "data".
$EDITOR ~/homelab/backups/borgmatic/config.d/data.yaml
# Confirmar / añadir bajo source_directories:
#   - /mnt/hd2t/services/paperless/data
#   - /mnt/hd2t/services/paperless/media

# Y bajo exclude_patterns (los thumbnails son regenerables):
#   - '**/services/paperless/media/documents/thumbnails'
#   - '**/services/paperless/media/log'

sudo borgmatic config validate
```

> **Por qué dump SQL _y_ copia raw del directorio `media/`**: el dump (`pg_dump --clean --if-exists`) es el **canónico para la BD** (consistente, deduplicable, restaurable a cualquier versión de Paperless). La copia raw del directorio `media/documents/originals/` es **categoría A**: los originales escaneados son **irrecuperables** si se pierden — no hay forma de regenerarlos sin volver a escanear todo el papel. La copia raw de `media/documents/archive/` es categoría A pero **regenerable** (re-OCR de los originales reproduce los archive PDFs); aún así se respalda para que la restauración sea de minutos en lugar de horas. Cinturón y tirantes — la BD sin los originales es metadatos huérfanos; los originales sin la BD son ficheros sin etiquetas, fechas ni búsqueda.

### 8. (No aplica) Activar un _jail_ de fail2ban

A diferencia de Vaultwarden (que tiene un _jail_ explícito en `docs/04-seguridad/02-fail2ban.md`), **Paperless no tiene un _jail_ pre-configurado**. Las razones:

- Paperless no expone un endpoint público a internet — vive sólo en LAN + Tailscale, donde el modelo de amenaza de _brute force_ es muy bajo.
- El log de Paperless **no escribe líneas estructuradas para fallos de login**: Django registra `Forbidden: /api/token/` con código 401 pero sin _delimitar_ "fallo de autenticación humana" vs "intento técnico". Un filtro fail2ban genérico daría falsos positivos.
- Para tener un _jail_ útil habría que añadir un _signal handler_ en Django + un filtro `fail2ban` _ad hoc_. Es factible (existen plugins comunitarios) pero el _ROI_ es bajo en un archivo personal en LAN.

**Política asumida**: no se configura jail. Si en el futuro Paperless se publicase en internet (cambio de modelo de red), este documento se complementaría con un _jail_ específico, en línea con el patrón Vaultwarden.

---

## Verificación final

Antes de pasar a `docs/11-productividad/05-mealie.md`, comprobar:

- [ ] `docker compose -f ~/homelab/productividad/docker-compose.yml ps` muestra los **nueve** contenedores (`vaultwarden`, `bookstack-db`, `bookstack`, `linkding`, `paperless-db`, `paperless-redis`, `paperless-gotenberg`, `paperless-tika`, `paperless`) en `(healthy)`.
- [ ] `curl -k --resolve paperless.lan:443:192.168.1.3 https://paperless.lan/api/` devuelve un JSON con los endpoints de la API REST.
- [ ] `https://paperless.lan/` carga la pantalla de login en el navegador con candado verde (CA local importada).
- [ ] El usuario operador puede hacer login con su username + password (ya cambiada desde la del bootstrap).
- [ ] La password actual del operador está almacenada en Vaultwarden en una nota titulada "Homelab — Paperless".
- [ ] El operador tiene MFA TOTP activo en su cuenta y los _recovery tokens_ están **anotados en Vaultwarden** y en papel.
- [ ] Al menos **un token de API** está generado y almacenado en Vaultwarden en una nota "Homelab — Paperless API token".
- [ ] **Test del consumer**: dejar un PDF cualquiera en `/mnt/hd2t/services/paperless/consume/` (o vía Samba en `\\pi.lan\paperless-consume\`). Esperar 30 s. El fichero **desaparece** del consume folder y aparece en `https://paperless.lan/` como un documento nuevo con su preview, OCR aplicado y un título extraído de las primeras líneas.
- [ ] **Test de Tika/Gotenberg**: dejar un `.docx` en `consume/`. Mismo resultado: desaparece, aparece en la lista con OCR sobre el texto del documento.
- [ ] El _hook_ de Borgmatic genera `dumps/paperless-YYYY-MM-DD.sql.gz`. Verificar que el dump contiene las tablas `documents_document`, `documents_correspondent`, `documents_tag`, `auth_user` (mínimas) y que `pg_restore --list` o `gunzip -c | head` muestran texto SQL válido.
- [ ] `~/homelab/backups/borgmatic/config.d/data.yaml` lista a `/mnt/hd2t/services/paperless/data` y `/mnt/hd2t/services/paperless/media` en `source_directories:`.
- [ ] `docker network inspect productividad-internal --format '{{range .Containers}}{{.Name}} {{end}}'` lista exactamente: `bookstack bookstack-db paperless paperless-db paperless-redis paperless-gotenberg paperless-tika`. **Vaultwarden y Linkding NO** deben aparecer.
- [ ] `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` lista a `paperless` (entre los demás del homelab); **NO** lista a `paperless-db`, `paperless-redis`, `paperless-gotenberg` ni `paperless-tika`.
- [ ] Permisos de los _bind mounts_:
  ```bash
  stat -c '%U:%G' /mnt/hd2t/services/paperless/data
  stat -c '%U:%G' /mnt/hd2t/services/paperless/media
  stat -c '%U:%G' /mnt/hd2t/services/paperless/consume
  stat -c '%U:%G' /mnt/hd2t/services/paperless/export
  # Los cuatro deben mostrar 'homelab:homelab'.
  stat -c '%U:%G' /mnt/hd2t/services/paperless/db
  # Debe mostrar '999:999' (postgres dentro del contenedor; sin nombre en host).
  ```
- [ ] Tras un `docker compose -f ~/homelab/productividad/docker-compose.yml restart paperless`, la página vuelve a `(healthy)` en <60 s y el operador sigue logueado (la sesión sobrevive porque `PAPERLESS_SECRET_KEY` no cambia entre restarts).
- [ ] Tras un `sudo reboot` de la Pi, los nueve contenedores vuelven a estar `(healthy)` sin intervención manual y `https://paperless.lan/` responde.
- [ ] `git -C ~/homelab status` muestra como **modificados**: `productividad/docker-compose.yml`, `productividad/.env.example`, `red/Caddyfile`, `backups/borgmatic/hooks/dump-databases.sh`, `backups/borgmatic/config.d/data.yaml`. **No** muestra `productividad/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add productividad/docker-compose.yml productividad/.env.example \
          red/Caddyfile backups/borgmatic/hooks/dump-databases.sh \
          backups/borgmatic/config.d/data.yaml
  git commit -m "feat(productividad): add Paperless-ngx + Postgres + Redis + Gotenberg + Tika; activate borgmatic dump hook"
  ```

---

## Backup

| Qué                                       | Dónde                                                                          | Cómo                                                       |
|-------------------------------------------|--------------------------------------------------------------------------------|------------------------------------------------------------|
| `docker-compose.yml`, `.env.example`      | `~/homelab/productividad/`                                                     | git                                                        |
| `paperless` schema + datos                | PostgreSQL en `/mnt/hd2t/services/paperless/db/`                                | **Dump consistente** vía `dump_postgres` (`pg_dump --clean --if-exists`) en el _hook_ de Borgmatic. El directorio raw `db/` **no entra** en _source_directories_ (no consistente sin parar el contenedor). |
| `media/documents/originals/`              | `/mnt/hd2t/services/paperless/media/documents/originals/`                      | Borgmatic — copia raw, retención larga (set "data"). **Categoría A** — pérdida ≡ pérdida total. |
| `media/documents/archive/`                | `/mnt/hd2t/services/paperless/media/documents/archive/`                        | Borgmatic — copia raw. Regenerable desde `originals/` vía re-OCR (horas), pero más rápido restaurar que regenerar. |
| `media/documents/thumbnails/`             | `/mnt/hd2t/services/paperless/media/documents/thumbnails/`                     | **Excluido** del backup (regenerable trivialmente). Borgmatic excluye explícitamente vía `exclude_patterns`. |
| `data/`                                   | `/mnt/hd2t/services/paperless/data/`                                            | Borgmatic — copia raw, ligero (~100 MB). Aquí viven el índice de búsqueda Whoosh-style, el clasificador ML, _settings_ persistidos por la app. **Regenerables** en su mayoría, pero entran "gratis". |
| `consume/`                                | `/mnt/hd2t/services/paperless/consume/`                                        | **Excluido** (transitorio: Paperless lo vacía al ingerir; un fichero respaldado a las 03:30 AM seguramente ya no exista a las 03:35). |
| `export/`                                 | `/mnt/hd2t/services/paperless/export/`                                          | **Excluido** (regenerable a demanda con `document_exporter`). |
| `PAPERLESS_SECRET_KEY`, `PAPERLESS_DBPASS`, `PAPERLESS_ADMIN_PASSWORD` | Notas dentro de Vaultwarden + papel                                  | Custodia humana. NUNCA en git, NUNCA en backups con la misma passphrase que el repo. |
| Token(s) de API del operador              | Nota dentro de Vaultwarden                                                     | Idem.                                                      |

Verificar que las inclusiones del set "data" de Borgmatic (en `~/homelab/backups/borgmatic/config.d/`) cubren `**/services/paperless/{data,media}/`. Por defecto sí, ya que `docs/07-backups/01-estrategia-backup.md` lista a `/mnt/hd2t/services/paperless` como _source_directory_ del set "data". Verificación rápida:

```bash
grep -A6 source_directories ~/homelab/backups/borgmatic/config.d/data.yaml | grep paperless
# - /mnt/hd2t/services/paperless/data
# - /mnt/hd2t/services/paperless/media
```

Y que las exclusiones cubren los thumbnails:

```bash
grep -A6 exclude_patterns ~/homelab/backups/borgmatic/config.d/data.yaml | grep paperless
# - '**/services/paperless/media/documents/thumbnails'
# - '**/services/paperless/media/log'
```

> **Restauración desde backup**:
> 1. Restaurar `/mnt/hd2t/services/paperless/{data,media}/` desde Borgmatic (incluye `originals/`, `archive/`, `data/`).
> 2. Borrar `/mnt/hd2t/services/paperless/db/` antiguo (si existía):
>    ```bash
>    sudo rm -rf /mnt/hd2t/services/paperless/db
>    sudo mkdir -p /mnt/hd2t/services/paperless/db
>    ```
> 3. Levantar **sólo** `paperless-db` y esperar a `(healthy)` con la BD `paperless` recreada vacía:
>    ```bash
>    docker compose -f ~/homelab/productividad/docker-compose.yml up -d paperless-db
>    until docker exec paperless-db pg_isready -U paperless -d paperless; do sleep 2; done
>    ```
> 4. Importar el dump (ver también `docs/07-backups/03-backup-docker-volumes.md` → _Restauración: una base de datos (Patrón P)_):
>    ```bash
>    . ~/homelab/productividad/.env
>    gunzip -c /mnt/hd2t/backups/dumps/paperless-YYYY-MM-DD.sql.gz | \
>      docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" -i paperless-db \
>          psql -U "$POSTGRES_USER" "$POSTGRES_DB"
>    ```
> 5. Levantar el resto de sidecars y `paperless`:
>    ```bash
>    docker compose -f ~/homelab/productividad/docker-compose.yml up -d \
>        paperless-redis paperless-gotenberg paperless-tika paperless
>    ```
> 6. Verificar login con la cuenta operador y abrir un documento aleatorio: la preview debe cargar (los `originals/` están en su sitio), el OCR debe ser legible (los `archive/` también) y la búsqueda debe encontrarlo (la BD se importó).

> **Antes de cualquier upgrade _minor_ de Paperless** (2.13 → 2.14):
> 1. `docker compose stop paperless`.
> 2. Backup completo: dump SQL + copia `data/` + copia `media/originals/` (Borgmatic _on-demand_).
> 3. Editar `.env`: `PAPERLESS_IMAGE_TAG=2.14.0` (leer el _changelog_ upstream).
> 4. `docker compose pull paperless && docker compose up -d paperless`.
> 5. `docker logs -f paperless` — esperar a `Apply database migrations... ... OK` (las migraciones de la nueva versión) y `(healthy)`.
> 6. `curl -k https://paperless.lan/api/` — confirmar response.
> 7. Verificación final completa de la sección anterior.
> 8. Si algo va mal: `docker compose down paperless`, restaurar `data/`, `media/originals/`, dump SQL, `PAPERLESS_IMAGE_TAG=2.13.5`, `up -d paperless`.

> Los _bumps_ de **patch** y **minor** de Paperless **NO** los gestiona Watchtower (opt-out). El operador los aplica a mano leyendo el _changelog_.

---

## Troubleshooting

### `paperless` arranca y queda en `unhealthy`

El `start_period: 120s` da margen para `migrate` + bootstrap + creación del índice. Si tras 3 minutos sigue `starting`/`unhealthy`, mirar los logs:

```bash
docker logs paperless --tail 80
```

Causas frecuentes:

1. **`paperless-db` no está `(healthy)`**: Paperless hace `depends_on: condition: service_healthy`, así que esto se manifiesta como Paperless en `created` y nunca arrancando. Verificar:
   ```bash
   docker logs paperless-db --tail 40
   # Buscar "database system is ready to accept connections" — si no aparece, la BD no levanta.
   ```
   Causas habituales en `paperless-db`:
   - Espacio en `/mnt/hd2t/services/paperless/db/` insuficiente (`df -h /mnt/hd2t`).
   - Permisos: si por error se hizo `chown` antes del primer arranque, Postgres puede fallar al inicializar. Solución: `sudo rm -rf /mnt/hd2t/services/paperless/db && sudo mkdir -p /mnt/hd2t/services/paperless/db && docker compose up -d paperless-db`.
   - `POSTGRES_PASSWORD` con caracteres especiales que rompen el shell al cargar el `.env` (raro si se usó la fórmula `tr -d '/+='`).
   - Conflicto de locale: si el sistema operativo de la Pi tuviese `es_ES.UTF-8` _no_ generado, `initdb` con `--locale=es_ES.UTF-8` falla. Confirmar `locale -a | grep es_ES`. La imagen `postgres:16-bookworm` trae los locales precompilados, no debería pasar.

2. **`paperless-redis` no responde**: el _depends_on_ con _service_healthy_ debería bloquear el arranque, pero si Redis arrancó y se cayó después, Paperless da `redis.exceptions.ConnectionError`. Solución: `docker logs paperless-redis` y, si está caído, `docker compose up -d paperless-redis`.

3. **`PAPERLESS_SECRET_KEY` vacío o malformado**: Django falla con `RuntimeException: SECRET_KEY must not be empty.` o `ImproperlyConfigured`. Solución: regenerar siguiendo la sección **Variables de entorno** y reiniciar.

4. **Migraciones fallaron**: aparece como `django.db.migrations.exceptions.MigrationError: ...` en logs. Causas habituales:
   - Schema previo de otra versión de Paperless incompatible (si el bind mount `db/` estaba sucio). Solución: backup del cluster Postgres a otra ruta, borrar `db/`, dejar que se recree limpia, importar dump SQL si lo hubiera.
   - Versión de Postgres no soportada por la versión de Paperless: Paperless 2.x exige Postgres ≥ 13. Confirmar `POSTGRES_IMAGE_TAG`.

5. **`PAPERLESS_URL` o `PAPERLESS_CSRF_TRUSTED_ORIGINS` malformados**: Django falla con `ImproperlyConfigured: ALLOWED_HOSTS or CSRF_TRUSTED_ORIGINS` al arrancar. Soluciones:
   - `PAPERLESS_URL` es una URL completa con esquema: `https://paperless.lan` (NO `paperless.lan` ni `https://paperless.lan/` con barra final).
   - `PAPERLESS_CSRF_TRUSTED_ORIGINS` es lista coma-separada de URLs completas: `https://paperless.lan,https://pi.tailnet.ts.net` (con esquema, sin barra final).
   - `PAPERLESS_ALLOWED_HOSTS` es lista coma-separada **sin esquema**: `paperless.lan,paperless,localhost`.

6. **Permisos de los _bind mounts_**: Paperless escribe a `data/`, `media/`, `consume/`, `export/`. Si por error se pre-chown-eó alguno con un UID distinto, el _entrypoint_ puede fallar al hacer su propio `chown`. Solución: `sudo chown -R 1000:1000 /mnt/hd2t/services/paperless/{data,media,consume,export}` (UID 1000 = `homelab` = `USERMAP_UID`).

### `403 CSRF verification failed` al hacer login o al subir un documento

Django devuelve este error cuando el _origin_ de la petición no está en `PAPERLESS_CSRF_TRUSTED_ORIGINS`. Causas:

1. **Acceso por una URL no incluida en la lista**: el operador entra por `https://pi.tailnet.ts.net/paperless/...` (sin que `pi.tailnet.ts.net` esté en `PAPERLESS_CSRF_TRUSTED_ORIGINS`). Solución: añadir esa URL a la lista (`PAPERLESS_CSRF_TRUSTED_ORIGINS=https://paperless.lan,https://pi.tailnet.ts.net`) y `up -d paperless`.

2. **Mismatch de `Host`**: Caddy reescribe `Host` por defecto, pero si el bloque del `Caddyfile` tiene un `header_up Host` distinto, llega un valor inesperado a Django. Solución: confirmar que el `Caddyfile` tiene `header_up Host {host}` (no `{remote_host}` ni un literal).

3. **`PAPERLESS_TRUSTED_PROXIES` no incluye la subnet de Caddy**: si Paperless no confía en el proxy, descarta `X-Forwarded-Proto`, `X-Forwarded-For` y los flags `secure` de las cookies se quedan a `False`. Confirmar `PAPERLESS_TRUSTED_PROXIES=172.20.10.0/24` (subnet de la red `homelab`).

### Documentos quedan _atascados_ en `consume/` y nunca se ingestan

Síntomas: el operador deja un PDF en `consume/`, espera 30 s, no aparece en la UI, el fichero sigue ahí.

```bash
docker logs paperless --tail 60 | grep -iE "consum|permission|error"
```

Causas:

1. **Permisos**: el fichero fue escrito por Samba con UID 1001 (la cuenta `familia`) y Paperless corre con UID 1000. Confirmar:
   ```bash
   ls -la /mnt/hd2t/services/paperless/consume/ | head
   ```
   Si los UIDs no son 1000, el _share_ de Samba está mal configurado: revisar `docs/06-almacenamiento/02-samba.md` → bloque `[paperless-consume]` debe tener `force user = homelab` y `force group = homelab`.

2. **Polling no detecta**: con `PAPERLESS_CONSUMER_POLLING=10`, debería tardar máximo 10 s en detectar. Si tarda mucho más, comprobar:
   ```bash
   docker exec paperless ls -la /usr/src/paperless/consume/
   # Debe ver los mismos ficheros que ls -la /mnt/hd2t/services/paperless/consume/
   ```
   Si no, el bind mount está roto: `docker compose down paperless && docker compose up -d paperless`.

3. **Fichero corrupto**: un PDF a medio escribir (Samba aún copiando) puede atascar Paperless con `Error processing document: ...`. Solución: borrar el fichero a medias y dejarlo entero. Para evitar el _race condition_, escribir primero a un fichero temporal `recibo.pdf.uploading` y renombrarlo a `recibo.pdf` cuando termine la subida — algunos clientes Samba lo hacen por defecto, otros no.

4. **`.DS_Store` o `._archivos` de macOS**: el patrón `PAPERLESS_CONSUMER_IGNORE_PATTERNS` ya los excluye explícitamente. Si aparecen igualmente, confirmar que el patrón está cargado: `docker exec paperless env | grep IGNORE`.

### `502 Bad Gateway` desde Caddy hacia `paperless`

Caddy responde 502 si no puede alcanzar `paperless:8000` desde la red `homelab`. Probar:

```bash
docker exec caddy curl -fsS http://paperless:8000/api/
# Debe devolver un JSON. Si "Failed to connect": Paperless no está sirviendo.

docker exec caddy nslookup paperless
# Debe resolver a una IP del 172.20.10.0/24.
```

Causas:

1. Paperless en `unhealthy` — ver caso anterior.
2. `paperless` no está enganchada a `homelab` (mira con `docker network inspect homelab`). Si no está, revisar la sección `networks:` del compose y `up -d paperless` de nuevo.
3. La red `homelab` está sin `paperless` por un fallo silencioso de Compose. `docker compose down paperless && docker compose up -d paperless` lo recrea.

### La app móvil devuelve "Network error" o "Invalid token"

1. **CA local no importada**: el móvil rechaza el certificado autofirmado. Solución: importar y **confiar** la CA local del homelab en el dispositivo (Android: `Settings → Security → Encryption & credentials → Install a certificate → CA certificate`. iOS: `Settings → General → Profile → CA → Install` + `Settings → General → About → Certificate Trust Settings`).
2. **Token caducado o regenerado**: el operador regeneró el token desde Settings y olvidó actualizarlo en la app. Solución: copiar el token actual desde `My Profile → Authorization Tokens` y pegarlo en la configuración de la app.
3. **URL mal escrita**: la app exige la URL **con barra final**: `https://paperless.lan/`, no `https://paperless.lan`. Causa común de "Network error" silencioso.
4. **Tailscale y MagicDNS**: si la app apunta a `https://pi.tailnet.ts.net/` desde fuera de casa, asegúrate de que ese dominio está en `PAPERLESS_CSRF_TRUSTED_ORIGINS` y `PAPERLESS_ALLOWED_HOSTS`, y de que el operador realmente está conectado al _tailnet_.

### Resetear la password del usuario desde el contenedor

Si se perdió la password del operador y SMTP no está configurado (no hay forma de hacer `Reset password` desde el formulario):

```bash
docker exec -it paperless python manage.py changepassword operador
# Changing password for user 'operador'
# Password:
# Password (again):
# Password changed successfully for user 'operador'.
```

> Esto sólo es seguro si **el contenedor sigue arrancado**. Si Paperless está caído por la propia razón que motivó perder la password, levantar primero `docker start paperless`.

> **Alternativa de DR**: si por algún motivo `manage.py changepassword` no funciona, basta con borrar el usuario con `manage.py shell` y reiniciar el contenedor; el _entrypoint_ recreará al operador con `PAPERLESS_ADMIN_PASSWORD`. La nota fósil de Vaultwarden ("Homelab — Paperless bootstrap") es exactamente para este caso.

### Reset de MFA (si el operador perdió el TOTP y los recovery tokens)

```bash
docker exec -it paperless python manage.py shell <<'PY'
from django.contrib.auth import get_user_model
from allauth.mfa.models import Authenticator
User = get_user_model()
u = User.objects.get(username='operador')
Authenticator.objects.filter(user=u).delete()
print("MFA cleared for operador")
PY
```

El usuario podrá hacer login sólo con username + password (sin MFA) hasta que vuelva a configurarlo desde `My Profile → Settings → Two-factor authentication`.

### El dump de Borgmatic falla con `password authentication failed`

```
[dump] paperless: FAIL
pg_dump: error: connection to server at "paperless-db" (172.20.10.x), port 5432 failed:
        FATAL: password authentication failed for user "paperless"
```

Causas:

1. **`PAPERLESS_DBPASS` y `POSTGRES_PASSWORD` desincronizados** en el `.env`. La política del documento es que **deben ser idénticos**. Solución: recopiar el valor de `POSTGRES_PASSWORD` a `PAPERLESS_DBPASS` (o viceversa) y `up -d paperless paperless-db`.
2. **El helper `dump_postgres` lee `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB`** del `.env` del _stack_. Si esos nombres están "renombrados" en el `.env` (raro), ajustar el helper o renombrar las variables.

### El consumer detecta el fichero pero el OCR falla

Síntomas: en logs aparece `tasks.py: Consuming /usr/src/paperless/consume/X.pdf` seguido de `tasks.py: ERROR: ...`.

Causas:

1. **PDF protegido con contraseña**: `OCRmyPDF` no puede abrir PDFs cifrados sin password. Solución: el operador desbloquea el PDF antes de subirlo (con `qpdf --decrypt` o desde Stirling-PDF, ver `docs/11-productividad/06-stirling-pdf.md`).
2. **Imagen escaneada con DPI inconsistente** (algunas multi-tiff): `OCRmyPDF` falla con `RasterImageError`. Solución: `tesseract` directo sobre cada página (workaround manual) o convertir a PDF con un escáner con DPI uniforme.
3. **Idioma de OCR no instalado**: si `PAPERLESS_OCR_LANGUAGE=cat+eng` y `cat` no está en `PAPERLESS_OCR_LANGUAGES`, falla. Solución: añadir a `PAPERLESS_OCR_LANGUAGES` y reiniciar (la imagen apt-instala los language packs en el `entrypoint`).

### `Search engine is broken` o búsqueda muy lenta

Paperless 2.x usa Postgres con extensiones para búsqueda full-text. Si la búsqueda no devuelve resultados o tarda mucho:

```bash
# Reconstruir el índice de búsqueda
docker exec -it paperless python manage.py document_index reindex
# Reindexed N documents
```

Para BDs grandes puede tardar minutos.

### Mover el _stack_ a otra Pi (DR scenario)

1. En la Pi nueva: instalar Pi OS, Docker, montar hd2t, restaurar `~/homelab/` (git clone + `.env` desde la copia papel/Vaultwarden).
2. Restaurar `/mnt/hd2t/services/paperless/{data,media}/` desde Borgmatic.
3. Crear `/mnt/hd2t/services/paperless/db/` vacío.
4. Levantar `paperless-db` solo y esperar a `(healthy)`.
5. Importar el dump SQL más reciente (ver **Backup → Restauración**).
6. Levantar el resto de sidecars y `paperless`.
7. Verificar login con la cuenta operador y abrir un documento aleatorio.

> **Crítico**: el `PAPERLESS_SECRET_KEY` en el `.env` restaurado **debe ser el mismo** que el que se usó cuando se generaron los datos cifrados de la BD (sesiones, settings encriptados). Si el `.env` se perdió y sólo hay backup del cluster Postgres, los _settings_ encriptados quedan ilegibles pero los documentos siguen accesibles (los datos de los documentos no se encriptan con `SECRET_KEY`).

---

## SMTP opcional

Paperless funciona sin SMTP, pero algunas funcionalidades quedan limitadas:

- **Recuperación de password** del usuario olvidadizo: sin SMTP, el _link de reset_ no se envía y la única ruta es `manage.py changepassword` desde dentro del contenedor (descrito en **Troubleshooting**).
- **Notificaciones de tareas Celery** (cuando termina un OCR largo, cuando falla una task): sin SMTP no llegan emails. La UI sigue mostrando notificaciones in-app.
- **Ingesta por email** (`PAPERLESS_EMAIL_*`): si en el futuro se quiere que Paperless lea una cuenta IMAP y archive los attachments automáticamente, **eso sí requiere SMTP saliente** + IMAP entrante. Documentar entonces aparte.

Para activar, descomentar el bloque correspondiente del `~/homelab/productividad/.env`:

```bash
PAPERLESS_EMAIL_HOST=smtp.tu-proveedor.com
PAPERLESS_EMAIL_PORT=587
PAPERLESS_EMAIL_HOST_USER=tu-cuenta-smtp
PAPERLESS_EMAIL_HOST_PASSWORD=tu-password-de-aplicacion
PAPERLESS_EMAIL_USE_TLS=true
PAPERLESS_EMAIL_FROM=paperless@tu-dominio.example
```

…y descomentar el bloque correspondiente del `docker-compose.yml`. Reiniciar:

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml up -d paperless
```

Probar desde el shell de Django:

```bash
docker exec -it paperless python manage.py shell <<'PY'
from django.core.mail import send_mail
send_mail("Test SMTP", "Funciona.", None, ["operador@tu-dominio.example"])
PY
```

Si falla, los detalles aparecen en `docker logs paperless`.

> **Por qué `true/false` en minúscula**: a diferencia de Linkding (Pascal case `True`/`False`), Paperless lee los booleanos vía `os.environ` y los normaliza con `str.lower() == "true"`. Tanto `True` como `true` funcionan, pero `true` es lo que la documentación oficial usa.

---

## Migrar a OIDC con Authelia (opcional, futuro)

Paperless soporta **OIDC nativo desde 2.0** vía `mozilla-django-oidc` y `django-allauth-2fa`. La integración con Authelia (`docs/04-seguridad/01-authelia.md`) consiste en:

1. **Registrar un cliente OIDC en Authelia**: añadir al `configuration.yml` de Authelia un nuevo `identity_providers.oidc.clients[]` con:
   - `id: paperless`
   - `secret: $argon2id$<hash>` (generado con `authelia crypto hash generate argon2`)
   - `redirect_uris: [https://paperless.lan/accounts/oidc/authelia/login/callback/]`
   - `scopes: [openid, profile, email]`
   - `userinfo_signing_algorithm: none`
2. **Configurar Paperless** añadiendo al `~/homelab/productividad/.env`:
   ```bash
   PAPERLESS_APPS=allauth.socialaccount.providers.openid_connect
   PAPERLESS_SOCIALACCOUNT_PROVIDERS={"openid_connect":{"APPS":[{"provider_id":"authelia","name":"Authelia","client_id":"paperless","secret":"<el secret en plano>","settings":{"server_url":"https://auth.lan/.well-known/openid-configuration"}}]}}
   PAPERLESS_DISABLE_REGULAR_LOGIN=false   # mantenerlo en false durante la migración para no quedarse fuera
   ```
3. Reiniciar Paperless: `docker compose up -d paperless`.
4. Probar el login desde un navegador limpio: `https://paperless.lan/accounts/login/` muestra ahora un botón "Sign in with Authelia"; al pulsar, redirige a `https://auth.lan/?rd=...`, el operador hace su login + 2FA en Authelia, vuelve a Paperless y entra ya autenticado.
5. Tras confirmar que el OIDC funciona, **opcionalmente** apagar el login regular: `PAPERLESS_DISABLE_REGULAR_LOGIN=true`.

**No** se aplica en este documento por las mismas razones que en Bookstack y Linkding:

- El operador único del homelab (y posiblemente la familia) no se beneficia mucho del SSO: ya hay 2FA TOTP nativo en Paperless, y el _login_ con username + password ya está unificado en Vaultwarden.
- OIDC añade una **dependencia operativa**: si Authelia se cae, Paperless queda inaccesible aunque la propia app esté `(healthy)`. La opción nativa (username + password) sigue funcionando sin cadenas de dependencia.
- Paperless **mantiene los usuarios locales en paralelo** a los OIDC (no rompe nada). La migración es **incremental** (activar OIDC manteniendo login local en paralelo, migrar el operador, y al final apagar el local con `PAPERLESS_DISABLE_REGULAR_LOGIN=true`).

> **Atención al token de API**: el _token_ se asocia al **usuario interno de Django**, no al _claim_ OIDC. Si tras migrar a OIDC el username cambia (ej. de `operador` a `operador@tu-dominio.example` porque el _claim_ `sub` de Authelia tiene esa forma), Paperless crea un usuario **nuevo** en su BD interna; el token del usuario antiguo deja de funcionar y la app móvil necesita reconfigurarse con un token nuevo del usuario OIDC.

---

## Referencias

- Documentación oficial de Paperless-ngx: <https://docs.paperless-ngx.com/>
  - Variables de configuración: <https://docs.paperless-ngx.com/configuration/>
  - API REST: <https://docs.paperless-ngx.com/api/>
  - OIDC / SSO: <https://docs.paperless-ngx.com/configuration/#openid-connect-and-social-authentication>
  - Reverse proxy: <https://docs.paperless-ngx.com/setup/#hosting-with-a-reverse-proxy>
  - Backup y restore: <https://docs.paperless-ngx.com/administration/#backup>
- Repositorio upstream: <https://github.com/paperless-ngx/paperless-ngx>
- Imagen Docker oficial: <https://github.com/paperless-ngx/paperless-ngx/pkgs/container/paperless-ngx>
- Apps móviles:
  - **Paperless Mobile** (Android/iOS open source, recomendada): <https://github.com/astubenbord/paperless-mobile>
  - **Paperless App** (alternativa, sólo Android): <https://github.com/bauerj/paperless_app>
- Backup de Postgres con `pg_dump` (Patrón P): `docs/07-backups/03-backup-docker-volumes.md` → _Patrón P_.
- Documento adyacente: `docs/11-productividad/01-vaultwarden.md` (estrenó el _stack_ `productividad`).
- Documento adyacente: `docs/11-productividad/02-bookstack.md` (introdujo `productividad-internal` y el patrón app+DB).
- Documento adyacente: `docs/11-productividad/03-linkding.md` (mismo patrón Django + token de API).
- `docs/01-sistema/04-estructura-directorios.md` — pre-creación de `/mnt/hd2t/services/paperless/{data,media,consume,export}` y `paperless/` en `services/`.
- `docs/02-docker/02-estructura-compose.md` — un compose por dominio, redes externas/internas, convenciones de _naming_.
- `docs/02-docker/04-watchtower.md` — opt-out de Paperless y Postgres (migraciones de schema, formato InnoDB/cluster).
- `docs/03-red/02-pihole.md` — wildcard `*.lan → 192.168.1.3`.
- `docs/03-red/04-caddy.md` — Caddy, CA local, _snippets_ `security-headers` y `logging`.
- `docs/03-red/05-tailscale.md` — acceso remoto vía MagicDNS, ampliación de `PAPERLESS_CSRF_TRUSTED_ORIGINS`.
- `docs/04-seguridad/01-authelia.md` — por qué Paperless **no** entra hoy en `forward_auth`; cómo migraría a OIDC en el futuro.
- `docs/06-almacenamiento/02-samba.md` — _share_ `paperless-consume` que expone `consume/` por SMB.
- `docs/07-backups/01-estrategia-backup.md` — Categoría A (BD + originales escaneados) + Patrón P.
- `docs/07-backups/03-backup-docker-volumes.md` — helper `dump_postgres` y bloque comentado del _hook_.
- Tesseract OCR (engine de OCRmyPDF): <https://tesseract-ocr.github.io/>
- OCRmyPDF (envoltorio que produce PDF/A): <https://ocrmypdf.readthedocs.io/>
