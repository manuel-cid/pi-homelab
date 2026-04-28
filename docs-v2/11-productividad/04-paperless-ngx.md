# Paperless-ngx

## Descripción

Despliegue de **Paperless-ngx** ([imagen `ghcr.io/paperless-ngx/paperless-ngx`](https://github.com/paperless-ngx/paperless-ngx)) como **gestor de archivos digitalizados (DMS)** del homelab. Paperless-ngx es una aplicación Django que **consume** PDFs e imágenes desde un directorio inotify, **OCRiza** los que no tengan texto (Tesseract vía OCRmyPDF), **clasifica** automáticamente con un clasificador bayesiano entrenable (NaiveBayes con scikit-learn) en correspondiente, etiqueta y tipo de documento, y los **archiva** en una BD PostgreSQL + ficheros en disco con dos copias por documento: el **original** intacto (para regenerar OCR si cambia el motor) y el **archive** (PDF/A con texto embebido, para búsqueda full-text). Es la pieza canónica del homelab para el ciclo "escaneo → OCR → indexación → búsqueda → archivo a largo plazo" de facturas, contratos, recibos, manuales y correspondencia digitalizada.

Por qué exactamente esta arquitectura, y no otra:

1. **Paperless-ngx, no Paperless original, no Mayan EDMS, no Teedy, no DocSpell.** Paperless-ngx es el **fork mantenido** del Paperless original (que dejó de actualizarse en 2021); el equipo de paperless-ngx publica releases mensuales, mantiene una imagen Docker oficial multi-arch (`linux/amd64`, `linux/arm64`, `linux/arm/v7`), y soporta integraciones modernas (Apache Tika para office, Gotenberg para office→PDF, OIDC para SSO, REST API estable v6+ documentada con OpenAPI). Las alternativas pecan en alguno de los ejes que importan a un homelab: (a) **Mayan EDMS** apunta a workflows enterprise con permissions ACL granulares, su matriz de contenedores incluye ~6 servicios (Postgres + Redis + Rabbit + workers separados + indexer separado + frontend) — demasiado para una Pi 5 con 8 GB; (b) **Teedy** (ex Sismics Docs) es ligero y bonito pero tiene un OCR menos potente (Tesseract sin OCRmyPDF, sin clasificación automática, sin Tika para .docx) y la comunidad es ~5 % del tamaño de paperless-ngx; (c) **DocSpell** (Scala/Java) ofrece una UI muy pulida y una arquitectura JVM, pero el footprint en RAM (~1.5 GB solo el daemon) es prohibitivo en una Pi compartida con Jellyfin, Home Assistant y todo el resto del homelab. Paperless-ngx es la talla justa: 1 contenedor de app + 1 Postgres + 1 Redis (~600-800 MB de RAM en uso normal, +200 MB durante OCR concurrente), arquitectura simple, comunidad enorme (>15 k estrellas, ~150 contributors), y exporter/importer oficial que permite migrar a otra herramienta sin lock-in.
2. **Imagen `ghcr.io/paperless-ngx/paperless-ngx:<version>` upstream, no LinuxServer.io.** A diferencia de Bookstack (donde [`./02-bookstack.md`](./02-bookstack.md) §0 punto 2 elige LSIO porque bundlea Apache + PHP-FPM + nginx) o Calibre-Web ([`../09-multimedia/04-calibre-web.md`](../09-multimedia/04-calibre-web.md)), la imagen **upstream** de paperless-ngx ya **es** monolítica para todo lo que es la app: bundlea Python 3.12 + Django + Gunicorn + supervisord + Tesseract + OCRmyPDF + qpdf + Ghostscript + ImageMagick + jbig2enc + un cron interno. LSIO no publica `paperless-ngx`. La imagen upstream está mantenida por el propio equipo (etiquetas `latest`, `<major>`, `<major>.<minor>`, `<major>.<minor>.<patch>` y digests inmutables), publica notas de release detalladas, y es la que recomienda la propia documentación. Variante con `LinuxServer.io/paperless-ngx` queda **fuera del scope** del doc: LSIO sí publica `linuxserver/paperless-ng` (notar: `paperless-ng`, fork antiguo de 2020) pero **no** `paperless-ngx`. No es la misma app.
3. **PostgreSQL, no SQLite, no MariaDB.** Paperless-ngx soporta nominalmente **los tres** (`PAPERLESS_DBENGINE=sqlite|postgres|mariadb`) pero la documentación oficial es enfática: **PostgreSQL es el backend recomendado para deploys con >500 documentos**. SQLite empieza a sufrir contención de escritura con OCR concurrente (3 workers escribiendo `tasks` + `documents` simultáneamente bloquean la BD entera durante segundos), MariaDB ha tenido bugs de migraciones reportados (issue #4555 sobre `JSONField` en MariaDB 10.6; resuelto pero con caveats sobre `utf8mb4`). PostgreSQL elimina toda esa categoría de incertidumbre, soporta `JSONField` nativo (Paperless usa JSON para metadata personalizada), y al ser el motor que más prueba el CI primario del proyecto, los issues de migración se atrapan antes. La línea `paperless` se añadirá al bloque `postgresql_databases:` de Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6, ya tiene un slot para PostgreSQL con `nextcloud` listado; este doc añade `paperless` justo debajo).
4. **Detrás de Caddy con Authelia delante, **con bypass selectivo de `/api/*` para apps móviles**.** Coherente con la lógica de [`./02-bookstack.md`](./02-bookstack.md) §0 punto 4: la **UI humana** de paperless-ngx (login Django en `/accounts/login/`, dashboard, preview de documentos, edición) tolera bien `forward_auth` y se beneficia del 2FA centralizado de Authelia. Pero las **apps móviles** ("Paperless Mobile" para Android, "Paperless" para iOS, "PaperlessShareSheetX" extension iOS) y los **clientes de consumo automatizado** (scripts que hacen `POST /api/documents/post_document/` desde un escáner, integraciones con n8n / Home Assistant / Zapier / iOS Shortcuts) se autentican con un **token de API** vía cabecera `Authorization: Token <token>`. Authelia en `forward_auth` interceptaría todas las requests a `/api/*` redirigiendo a `https://auth.lan/?rd=...` — los clientes móviles recibirían HTML en lugar de JSON, y dejarían de funcionar. La salida es un Caddyfile con **dos `handle` blocks**: uno con matcher `@api path /api/*` que **NO** importa `authelia_proxy` (la auth la lleva el token + Django REST Framework), y otro `handle` por defecto que sí importa `authelia_proxy` (para la UI humana). La regla `paperless.{{ env "LAN_DOMAIN" }}` ya está prevista en `access_control.rules` de Authelia ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) línea 422, `policy: two_factor`, `subject: group:admin`); este doc activa el bloque Caddy con la separación UI/API.
5. **Datos persistentes en `hd2t`, en `/mnt/hd2t/services/paperless-ngx/`.** Coherente con [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.1 (loop "Fase 11 — Productividad", línea 241: `for svc in vaultwarden bookstack linkding paperless-ngx mealie stirling-pdf freshrss`). El árbol que se materializa en §3 distingue **cinco** jerarquías porque paperless-ngx separa con cuidado el ciclo de vida de cada tipo de fichero:
   - `/mnt/hd2t/services/paperless-ngx/.env` — configuración del stack (chmod 600).
   - `/mnt/hd2t/services/paperless-ngx/secrets/` — secretos individuales (passwords, `SECRET_KEY` Django, admin password): cada fichero `chmod 600 root:homelab`.
   - `/mnt/hd2t/services/paperless-ngx/data/` — bind mount de `/usr/src/paperless/data` del contenedor: estado interno de Django (`db.sqlite3` **no** se usa porque el motor es PostgreSQL, pero el directorio sigue conteniendo el clasificador entrenado `classification_model.pickle`, los logs de tareas, los íconos personalizados y la caché de `pdf2image`).
   - `/mnt/hd2t/services/paperless-ngx/media/` — bind mount de `/usr/src/paperless/media`: **el archivo a largo plazo**. Subdividido por paperless en `documents/originals/` (PDF/imagen tal como entró, intocable) y `documents/archive/` (PDF/A regenerable con OCR aplicado). **Este es el directorio cuyo contenido tiene que sobrevivir cualquier disaster recovery.**
   - `/mnt/hd2t/services/paperless-ngx/consume/` — bind mount de `/usr/src/paperless/consume`: el **buzón de entrada** que paperless monitoriza por inotify. Cualquier PDF o imagen depositado aquí (por Samba, SCP, drag&drop desde Files de macOS, escaneo desde una multifunción de red, n8n, etc.) se procesa, se mueve a `media/` y se borra de aquí.
   - `/mnt/hd2t/services/paperless-ngx/export/` — bind mount de `/usr/src/paperless/export`: destino del comando `document_exporter` (export incremental de toda la BD + ficheros + metadata en formato auditable, ver §10.2). Borgmatic backup-eará `media/` directamente, pero `export/` es la salida portable para migrar fuera del homelab.
   - `/mnt/hd2t/services/paperless-ngx/db/data/` — bind mount del datadir de PostgreSQL del contenedor `postgres-paperless`.
   - `/mnt/hd2t/services/paperless-ngx/redis/data/` — bind mount del AOF de Redis del contenedor `redis-paperless` (broker de Celery; persistencia opcional pero el AOF deja recuperar la cola de tareas pendientes tras un reboot duro).
6. **Imagen `ghcr.io/paperless-ngx/paperless-ngx:<version>` pinned a release puntual; Watchtower DESHABILITADO.** Misma regla del homelab: nunca `latest`, nunca `2` rolling. Los minor releases de paperless-ngx **suelen** traer migraciones Django (cada minor entre 2.10 y 2.13 tuvo al menos una migración no trivial) y, en ocasiones, **reindexes obligatorios del classifier** o cambios incompatibles en el formato del export ZIP. Igual que Bookstack ([`./02-bookstack.md`](./02-bookstack.md) §0 punto 6) y a diferencia de Linkding ([`./03-linkding.md`](./03-linkding.md) §0 punto 6), Paperless-ngx **lleva la etiqueta `com.centurylinklabs.watchtower.enable: "false"`**: el operador actualiza manualmente, leyendo previamente las release notes (sección "Breaking changes"), haciendo dump de la BD y export del estado vía `document_exporter` (§10.1). Está consistente con Watchtower §4.2 (línea 458: `Paperless-ngx | Migraciones de Django + reindex`).
7. **UID `1000:1000` (`homelab`) para el proceso del contenedor, vía `USERMAP_UID` / `USERMAP_GID`.** A diferencia de Linkding (que arranca como root y dropea a `www-data` UID 33), la imagen oficial de paperless-ngx **sí soporta** las variables `USERMAP_UID` y `USERMAP_GID` que su `docker-entrypoint.sh` traduce a `chown -R` en el datadir antes de dropear privilegios. Esta es la diferencia que importa: el directorio `consume/` recibe ficheros de **otros servicios y humanos del homelab** — escaneos depositados por Samba (que respeta el UID del usuario `homelab`, ver [`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md)), drag&drop desde un Mac vía Finder con `homelab` como user remoto, copias desde `/mnt/hd2t/nextcloud/.../Documents/Inbox/` por una rutina cron del operador. Mantener UID 1000 elimina la fricción de tener que `sudo chown 33:33 archivo.pdf` en cada flujo. La línea ya está prometida en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §2.1 (PostgreSQL via `pg_dump`) y consistente con el árbol de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md).
8. **`PAPERLESS_CSRF_TRUSTED_ORIGINS` con ambos hosts (LAN + Tailscale) y `PAPERLESS_TRUSTED_PROXIES` con la subnet de la red `homelab`.** Django (vía paperless) aplica protección CSRF a **todos** los formularios POST (login Django, alta de etiqueta, edición de documento, generación de token API en `/admin/`). Cuando la app se sirve detrás de un reverse proxy con TLS terminado (Caddy hace HTTPS hacia el navegador, HTTP plano hacia paperless), Django **no** detecta el HTTPS por sí solo: necesita que `CSRF_TRUSTED_ORIGINS` liste explícitamente los orígenes esperados, **incluido el scheme `https://`**. Si falta, todo POST devuelve `403 Forbidden — CSRF verification failed. Origin checking failed`. La variable acepta una lista separada por comas y se materializa con ambos hosts (LAN canónico + alias Tailscale) desde el día 1, aunque el bloque Tailscale del Caddyfile se descomente más adelante. **`PAPERLESS_TRUSTED_PROXIES`** es la otra mitad: Django solo confía en las cabeceras `X-Forwarded-*` cuando la conexión TCP entrante viene de una IP en esa whitelist; con `172.20.0.0/24` (la subnet de la red `homelab` de Docker, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.3) la lista cubre **solo** a Caddy y descarta cualquier intento de spoofing de cabeceras desde otras redes.
9. **Sin SMTP por defecto.** El homelab no tiene MTA ([`./01-vaultwarden.md`](./01-vaultwarden.md) §0 punto 4 y [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §0 punto 7). Paperless-ngx usa email para: (a) reset de password Django (`/accounts/password_reset/`), (b) **email-as-source** opt-in (descargar adjuntos de una cuenta IMAP y consumirlos automáticamente), (c) notificaciones de workflow (cuando un documento cumple ciertos criterios, paperless puede mandar email). Sin SMTP: el reset se hace desde la consola con `docker compose exec paperless-app python manage.py changepassword <username>`, las invitaciones se materializan creando la cuenta en `/admin/`, y email-as-source y notificaciones quedan deshabilitados. Variantes con SMTP (relay externo) y con email-as-source (consumo IMAP) en §12.1 y §12.4.
10. **Superusuario inicial creado por env vars `PAPERLESS_ADMIN_USER` y `PAPERLESS_ADMIN_PASSWORD`, **luego rotado**.** La imagen oficial detecta esas variables al primer arranque y crea el superuser Django si no existe. El homelab las usa **una sola vez** para bootstrap (§5.2), y **rota la password desde la UI inmediatamente después** (§7.1). Tras la rotación, las variables se **eliminan del `.env`** (no solo se ignoran: se borran), porque al revés que en Linkding, paperless-ngx **vuelve a leerlas en cada arranque** y, si la password en `.env` no coincide con la BD, sobreescribe la de la BD silenciosamente. Para evitar ese pisotón, la práctica del homelab es: bootstrap con `PAPERLESS_ADMIN_USER` + `PAPERLESS_ADMIN_PASSWORD` → primer login → rotar password en UI → **comentar o borrar** ambas variables del `.env`. La password real solo vive cifrada (PBKDF2-SHA256) en PostgreSQL.
11. **Apache Tika + Gotenberg como variante opt-in (§12.2).** Por defecto paperless-ngx OCRiza PDFs e imágenes (PNG, JPG, TIFF, HEIC con un parche), y eso cubre el 90 % de los casos de un hogar. Para `.docx`, `.odt`, `.xlsx`, `.eml` (correos exportados como EML), paperless puede **delegar** la extracción de texto a **Apache Tika** y la conversión a PDF a **Gotenberg** (Chromium headless gestionado). Eso son **dos contenedores adicionales** (~300 MB de RAM cada uno) que la mayoría de usuarios del homelab no necesitan. Quedan documentados en §12.2 con el snippet de Compose listo para enchufar; la variante por defecto de este doc es **sin** Tika ni Gotenberg.
12. **Formato `originals/` intocable, `archive/` regenerable.** Paperless-ngx mantiene **dos** copias por documento. `documents/originals/<año>/<scheme>.pdf` es **el fichero tal como llegó** — si era PDF entró, si era PNG entró: paperless **no** lo modifica (integridad legal del original escaneado). `documents/archive/<año>/<scheme>.pdf` es un **PDF/A** generado por OCRmyPDF a partir del original con texto OCR embebido — es regenerable con `document_archiver` si cambia el motor OCR o el target PDF/A. La política del homelab es: **respaldar `originals/`** con prioridad alta (irreplicable: si se pierde, el documento se pierde) y **`archive/`** con prioridad media (regenerable a coste de horas de OCR, pero costoso de regenerar para 5 k documentos). Borgmatic los respalda **ambos** porque la dedup de Borg deja `archive/` casi gratis cuando ya tiene `originals/` (los blocks comprimibles se solapan).

> **Alcance de red**: la UI de paperless-ngx **no** publica puertos al host. Se accede únicamente vía `https://paperless.${LAN_DOMAIN}` (Caddy + CA interna + Authelia para UI / token-API para `/api/*`) y, una vez completada la fase Tailscale, vía `https://paperless.${TS_DOMAIN}`. El homelab opera en LAN + Tailscale, sin exposición a internet, sin Let's Encrypt público, sin port forwarding.

> **Alcance de auth**: dos capas según ruta. (a) **UI humana** (`/accounts/`, `/dashboard`, `/documents/...` no `/api/`): Caddy → Authelia (`forward_auth`, 2FA TOTP) → login Django (PBKDF2-SHA256). (b) **API** (`/api/*`): Caddy → directamente paperless → Django REST Framework con token (`Authorization: Token <hex>`). Fail2ban ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md)) cubre intentos de fuerza bruta a ambas capas vía los logs de Caddy y los logs Django de paperless.

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), `/mnt/hd2t/` montado, directorio `/mnt/hd2t/services/paperless-ngx/` ya creado por el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.1 (loop "Fase 11 — Productividad", línea 241: `for svc in vaultwarden bookstack linkding paperless-ngx mealie stirling-pdf freshrss`).
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` creada (`172.20.0.0/24`, `external: true`), convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3 y §5).
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) con `lan_internal_tls` y `security_headers` operativos.
- **Authelia desplegado** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)) con el snippet `authelia_proxy` ya disponible en `~/homelab/stacks/proxy/snippets/authelia_proxy` (§9.1 de Authelia). La regla `paperless.{{ env "LAN_DOMAIN" }}` en `access_control.rules` (línea 422) ya está activa con `policy: two_factor`, `subject: group:admin`.
- **CA interna de Caddy** instalada en al menos un dispositivo del operador (navegador) y en cualquier dispositivo donde se quiera usar la app móvil ("Paperless Mobile") — sin la CA confiada, la app arranca pero el handshake TLS falla y el sync no avanza.
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con la posibilidad de añadir un registro DNS local: `paperless.${LAN_DOMAIN}` → IP del host donde escucha Caddy.
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) con el bloque `postgresql_databases:` ya configurado para `nextcloud` (líneas 517–524). Este doc añade una entrada `paperless` justo debajo (§9.2). Si Nextcloud aún no está desplegado, la entrada `paperless` se añade igual: Borgmatic ignora hosts no resolubles si el contenedor está caído.
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Paperless-ngx **lleva** la etiqueta `com.centurylinklabs.watchtower.enable: "false"` (justificado en §0 punto 6 y en Watchtower §4.2, línea 458).
- **Fail2ban desplegado** ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md)) con el jail `caddy-status` ya activo (cubre login web Authelia + login Django de paperless al venir todos por Caddy con `4xx`).
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No se añaden reglas: paperless-ngx no publica puertos al host; el tráfico entra por Caddy.
- **Vaultwarden desplegado** ([`./01-vaultwarden.md`](./01-vaultwarden.md)). No es bloqueante, pero la convención del homelab es que el operador ya tenga Vaultwarden activo cuando empieza la Fase 11; cualquier credencial nueva (password BD Postgres, password admin Django, `SECRET_KEY`, token API móvil) se anota allí.
- **Espacio libre en `hd2t`** ≥ 20 GB recomendado para el primer año. El crecimiento típico de un hogar es ~300-500 documentos/año, ~1-3 MB cada uno por ambas copias (`originals/` + `archive/` PDF/A) → ~1.5 GB/año netos. La caché interna del classifier y los thumbnails ocupan ~50-100 MB extra. Reservar margen para picos (digitalización masiva del archivo histórico de papel del operador puede meter 5-10 GB de un tirón).
- **Comprobaciones rápidas**:
  ```bash
  # Red homelab existe:
  docker network inspect homelab --format '{{(index .IPAM.Config 0).Subnet}}'
  # Esperado: 172.20.0.0/24  (necesario para PAPERLESS_TRUSTED_PROXIES)

  # Caddy y Authelia están sanos:
  docker inspect caddy --format '{{.Name}}: {{.State.Health.Status}}'
  docker inspect authelia --format '{{.Name}}: {{.State.Health.Status}}'
  # Esperado: ambos "healthy".

  # Snippet authelia_proxy está disponible:
  ls -la ~/homelab/stacks/proxy/snippets/authelia_proxy
  # Esperado: el fichero existe (creado en Authelia §9.1).

  # Pi-hole resuelve auth.lan al host:
  dig +short @192.168.1.241 auth.lan
  # Esperado: 192.168.1.10

  # Estructura de directorios y propietario:
  ls -ld /mnt/hd2t/services/paperless-ngx
  # Esperado: drwxr-x--- homelab homelab ...

  # Borgmatic ya tiene un bloque postgresql_databases (aunque sea solo nextcloud):
  grep -A2 'postgresql_databases:' /mnt/hd2t/services/backups/borgmatic/config.yaml
  # Esperado: la sección existe; este doc añadirá la entrada paperless.
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Gestor de archivos | **Paperless-ngx** | Justificado en §0 punto 1. Talla "S/M" para 1–4 humanos. |
| Imagen Docker app | **`ghcr.io/paperless-ngx/paperless-ngx`** (upstream) | Justificado en §0 punto 2. Multi-arch (`linux/arm64` incluido). Bundle Python + Django + Gunicorn + Tesseract + OCRmyPDF. |
| Tag de imagen app | **`2.13.5`** (no `latest`, no `2` rolling) | Misma regla del homelab. Cada minor de paperless-ngx puede traer migraciones Django + reindex. Pinning fuerza al operador a leer release notes. |
| Imagen PostgreSQL | **`postgres:16-alpine`** | Misma versión y patrón que Nextcloud ([`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md)). Postgres 16 es la rama LTS más reciente con soporte hasta nov-2028. |
| Imagen Redis | **`redis:7-alpine`** | Broker de Celery. Misma versión que la que usa Authelia para sesiones ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §6.1). |
| Backend de BD | **PostgreSQL** (`PAPERLESS_DBENGINE=postgres`) | Justificado en §0 punto 3. SQLite y MariaDB como variantes opt-in (no recomendadas para >500 documentos). |
| Política de Watchtower | **`enable: "false"`** | Justificado en §0 punto 6 y en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 línea 458. Upgrade manual con dump + export previos. |
| Arquitectura | `linux/arm64` (Pi 5) | Manifest multi-arch oficial de las tres imágenes. |
| Redes Docker | **`homelab`** (bridge externa) + **`paperless_internal`** (bridge dedicada para BD/Redis) | `paperless-app` está en ambas (Caddy llega por `homelab`, BD por `paperless_internal`). `postgres-paperless` y `redis-paperless` están **solo** en `paperless_internal`. |
| Modelo de almacenamiento | **Bind mounts** sobre `/mnt/hd2t/services/paperless-ngx/{data,media,consume,export,db/data,redis/data}` | Patrón estándar del homelab. Bind mounts, no named volumes — facilita backup directo, ruta predecible, permite acceso desde Samba al `consume/`. |
| Reverse proxy | **Caddy** con `lan_internal_tls` + `security_headers`. **Authelia con bypass selectivo de `/api/*`** (matcher `@api`) | Justificado en §0 punto 4. La UI humana va con 2FA; las apps móviles + clientes API van directos con token. |
| Hostname interno (DNS Docker) | **`paperless-app`** (`container_name`) | Caddy llama `http://paperless-app:8000`. |
| Hostname interno (DB) | **`postgres`** (`hostname` en `paperless_internal`) | Paperless-app conecta vía `PAPERLESS_DBHOST=postgres`. Alias DNS corto, idéntico patrón que Nextcloud y Bookstack. |
| Hostname interno (broker) | **`broker`** (`hostname` en `paperless_internal`) | Paperless-app conecta vía `PAPERLESS_REDIS=redis://broker:6379`. Es el alias canónico que la documentación oficial usa en sus ejemplos. |
| Puerto interno app | **`8000`** (default de la imagen) | Gunicorn escucha en `8000/tcp` por configuración interna del bundle. **No** se publica al host. |
| Puerto interno PostgreSQL | **`5432`** | Default. Solo accesible desde `paperless_internal`. |
| Puerto interno Redis | **`6379`** | Default. Solo accesible desde `paperless_internal`. |
| Subdominio LAN | **`paperless.${LAN_DOMAIN}`** (típicamente `paperless.lan`) | Convención del homelab. Ya listado en Authelia (línea 422), Prometheus (línea 733), Grafana (línea 961), Uptime Kuma (línea 905), Dozzle (línea 763). |
| Subdominio Tailscale | **`paperless.${TS_DOMAIN}`** (preparado, descomentar tras [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) | Mismo patrón que el resto del homelab. |
| `PAPERLESS_URL` | **`https://paperless.${LAN_DOMAIN}`** | URL canónica que paperless usa para construir links absolutos en notificaciones, exports, y la generación de PDF de resumen. |
| `PAPERLESS_ALLOWED_HOSTS` | **`paperless.${LAN_DOMAIN},paperless.${TS_DOMAIN},paperless-app,localhost`** | Django rechaza `Host:` headers que no estén en la lista. Incluir el alias Docker para que el healthcheck local con `127.0.0.1` y `paperless-app` no falle. |
| `PAPERLESS_CSRF_TRUSTED_ORIGINS` | **`https://paperless.${LAN_DOMAIN},https://paperless.${TS_DOMAIN}`** | Justificado en §0 punto 8. Ambos orígenes desde el día 1. |
| `PAPERLESS_TRUSTED_PROXIES` | **`172.20.0.0/24`** (subnet `homelab`) | Justificado en §0 punto 8. Solo la subnet de Docker; nada del host ni de la LAN. |
| `PAPERLESS_USE_X_FORWARD_HOST` | **`true`** | Necesario para que Django reconstruya URLs con el hostname público (`paperless.lan`) y no con `paperless-app`. |
| `PAPERLESS_USE_X_FORWARD_PORT` | **`true`** | Igual con el puerto. Caddy hace HTTPS en `:443`; sin esto Django asume `:8000` y rompe los redirects. |
| `PAPERLESS_PROXY_SSL_HEADER` | **`HTTP_X_FORWARDED_PROTO,https`** | Permite a Django saber que la conexión original era HTTPS (la cookie de sesión se marca como `Secure`). |
| `PAPERLESS_TIME_ZONE` | **`${TZ}`** (heredado del homelab, típicamente `Europe/Madrid`) | Coherente con [`../01-sistema/02-configuracion-inicial.md`](../01-sistema/02-configuracion-inicial.md) §3. |
| `PAPERLESS_OCR_LANGUAGE` | **`spa+eng`** | Idioma primario español + inglés (combinación habitual en el homelab del operador). Tesseract acepta el `+` para OCR multi-idioma simultáneo (más lento pero más preciso para correspondencia mixta). |
| `PAPERLESS_OCR_LANGUAGES` | **`spa eng`** | Lista de paquetes Tesseract a **instalar** dentro del contenedor en el primer arranque. La imagen oficial baja los `tesseract-ocr-spa` y `tesseract-ocr-eng` automáticamente. Si el operador necesita `cat` (catalán) o `fra` (francés), añadir aquí. |
| `PAPERLESS_TASK_WORKERS` | **`2`** | Pi 5 tiene 4 cores. 2 workers de OCR concurrente dejan margen al resto del homelab (Jellyfin transcodificando, Home Assistant, etc.). Subir a 3-4 solo si paperless-ngx es la prioridad. |
| `PAPERLESS_THREADS_PER_WORKER` | **`1`** | OCRmyPDF ya hace paralelismo interno. Subir esto multiplica memoria y rara vez acelera. |
| `PAPERLESS_OCR_MODE` | **`skip`** (default) | OCRiza solo si el documento no tiene texto. `redo` re-OCRiza siempre (caro), `force` ignora el texto existente. `skip` es lo correcto al 99 %. |
| `PAPERLESS_OCR_OUTPUT_TYPE` | **`pdfa`** (default) | Genera PDF/A en `archive/`. Estándar de archivado a largo plazo. |
| `PAPERLESS_OCR_CLEAN` | **`clean`** (default) | OCRmyPDF aplica `unpaper` para limpiar manchas/escaneados torcidos antes del OCR. Mejora precisión. |
| `PAPERLESS_OCR_DESKEW` | **`true`** | Endereza páginas escaneadas inclinadas. |
| `PAPERLESS_OCR_ROTATE_PAGES` | **`true`** | Detecta páginas rotadas (cabeza-abajo) y las endereza. |
| `PAPERLESS_OCR_USER_ARGS` | `'{"continue_on_soft_render_error": true}'` | OCRmyPDF puede fallar en PDFs con artefactos de fuentes embebidas exóticas; con esta opción los procesa parcialmente en lugar de abortar. |
| `PAPERLESS_CONSUMER_POLLING` | **`0`** (default: usar inotify) | inotify es la vía rápida en filesystems locales. ext4 + bind mount lo soporta sin problema. Subir a `30` (segundos) solo si el operador pone `consume/` en un share NFS/SMB remoto (no es el caso del homelab). |
| `PAPERLESS_CONSUMER_RECURSIVE` | **`true`** | Permite estructurar `consume/` con subdirectorios (`consume/escaner/`, `consume/email/`, `consume/movil/`). Cada subdirectorio puede mapearse luego a una **etiqueta** automática (PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS). |
| `PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS` | **`true`** | Tagging automático según subdir de origen. |
| `PAPERLESS_CONSUMER_DELETE_DUPLICATES` | **`true`** | Si el mismo PDF entra dos veces (escaneo duplicado), descarta el segundo en lugar de crear duplicado en BD. |
| `PAPERLESS_FILENAME_FORMAT` | **`{created_year}/{correspondent}/{title}`** | Estructura limpia de `originals/` y `archive/`. Permite navegar el filesystem sin la UI (útil para disaster recovery: si paperless está caído, los PDFs siguen siendo legibles agrupados por año/remitente). |
| `PAPERLESS_FILENAME_DATE_ORDER` | **`YMD`** (default) | Orden del parser de fechas en nombres de fichero. ISO-8601. |
| `PAPERLESS_NUMBER_OF_SUGGESTED_TAGS` | **`5`** | Número de etiquetas que el classifier sugiere por documento. Default razonable. |
| `PAPERLESS_DBENGINE` | **`postgres`** | Justificado en §0 punto 3. |
| `PAPERLESS_DBHOST` | **`postgres`** (alias DNS dentro de `paperless_internal`) | El contenedor `postgres-paperless` se llama `postgres` por hostname. |
| `PAPERLESS_DBPORT` | **`5432`** | Default. |
| `PAPERLESS_DBNAME` | **`paperless`** | Default. |
| `PAPERLESS_DBUSER` | **`paperless`** | Default. La password se inyecta vía `PAPERLESS_DBPASS` desde `.env`. |
| `PAPERLESS_REDIS` | **`redis://broker:6379`** | Broker Celery. Hostname `broker` dentro de `paperless_internal`. Sin password (la red interna ya aísla). |
| `PAPERLESS_SECRET_KEY` | **Generada** con `openssl rand -hex 64` | Django `SECRET_KEY`. Si se filtra, un atacante puede forjar cookies de sesión (pero no descifrar BD). Custodiada en `secrets/secret_key`. |
| `PAPERLESS_ADMIN_USER` | `admin` (solo bootstrap) | Se elimina del `.env` tras §7.1. Justificado en §0 punto 10. |
| `PAPERLESS_ADMIN_PASSWORD` | **Generada** con `openssl rand -base64 32` (solo bootstrap) | Custodiada en `secrets/admin_password`. Rotada y eliminada tras §7.1. |
| `USERMAP_UID` / `USERMAP_GID` | **`1000` / `1000`** | UID/GID `homelab`. Justificado en §0 punto 7. |
| Healthcheck app | **`curl -fsS -o /dev/null http://127.0.0.1:8000/`** | La home de paperless redirige a `/accounts/login/` y siempre responde 200/302. |
| Healthcheck postgres | **`pg_isready -U paperless -d paperless`** | Patrón estándar (idéntico al de Nextcloud). |
| Healthcheck redis | **`redis-cli ping`** | Patrón estándar. |
| `cap_drop: ALL` + `no-new-privileges` | Patrón del homelab ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6) | Paperless app, Postgres y Redis pueden correr sin capabilities (la imagen entrypoint hace `chown` antes de dropear, no necesita CAP_CHOWN tras el primer arranque si los permisos del bind mount ya son `1000:1000`). |
| Stack name (Compose) | **`paperless`** | Coherente con `~/homelab/stacks/paperless/`. Aparece como project name en `docker compose ls`. Más corto que `paperless-ngx` para la línea de comandos. |
| Apache Tika + Gotenberg | **No desplegados por defecto** (variante §12.2) | Justificado en §0 punto 11. Solo para usuarios que digitalizan `.docx`/`.eml`/`.odt`. |
| Email-as-source (IMAP) | **No habilitado por defecto** (variante §12.4) | Solo para usuarios que reciben facturas por email y quieren consumo automatizado. |

---

## 1. Resumen de la arquitectura

Resumen visual (las flechas indican la dirección del tráfico):

```
                ┌───────────────────────────────────────────────────────┐
                │  Cliente humano (navegador, móvil con app, escáner)   │
                │  https://paperless.lan/  ó  https://paperless.ts.net  │
                └───────────────────────────────────────────────────────┘
                                       │  HTTPS (TLS interno Caddy)
                                       ▼
                ┌───────────────────────────────────────────────────────┐
                │  Caddy  (stack proxy, host)                           │
                │  - lan_internal_tls + security_headers                │
                │  - @api path /api/*  → reverse_proxy  (sin Authelia)  │
                │  - handle (resto)    → forward_auth Authelia + RP     │
                │  - X-Forwarded-* automáticos                          │
                └───────────────────────────────────────────────────────┘
                          │                              │
                          │  /api/* (token)              │  resto (cookie + 2FA)
                          ▼                              │
                ┌──────────────────────┐                 │
                │  Authelia (auth)     │                 │
                │  - 2FA TOTP          │  ◀──────────────┘  forward_auth
                │  - rule: paperless   │     (Caddy → Authelia → 200/30x)
                │      → two_factor    │
                └──────────────────────┘
                                       │  HTTP plano  (red Docker `homelab`)
                                       ▼
   red Docker  ┌───────────────────────────────────────────────────────┐
   `homelab`   │  paperless-app  (ghcr.io/paperless-ngx/...:2.13.5)    │
   (bridge)    │  - Gunicorn :8000                                     │
               │  - supervisord:                                       │
               │      • web (Django)                                   │
               │      • celery worker (OCR, classifier, indexing)      │
               │      • celery beat (cron interno)                     │
               │      • inotify consumer (vigila /usr/src/.../consume) │
               │  - user UID 1000:1000 (USERMAP)                       │
               └───────────────────────────────────────────────────────┘
                          │                              │
                          │  TCP 5432                    │  TCP 6379
                          ▼                              ▼
   red Docker  ┌──────────────────────┐    ┌──────────────────────────┐
   `paperless  │  postgres-paperless  │    │  redis-paperless         │
    _internal` │  (postgres:16-alpine)│    │  (redis:7-alpine)        │
   (bridge,    │  - hostname: postgres│    │  - hostname: broker      │
    aislada)   │  - vol: db/data      │    │  - vol: redis/data (AOF) │
               └──────────────────────┘    └──────────────────────────┘
                          │                              │
                          │  bind mount                  │  bind mount
                          ▼                              ▼
                ┌───────────────────────────────────────────────────────┐
                │  /mnt/hd2t/services/paperless-ngx/                    │
                │  ├── .env                  (chmod 600 root:homelab)   │
                │  ├── secrets/              (chmod 600, keys)          │
                │  ├── data/                 (classifier, internal)     │
                │  ├── media/                (originals/ + archive/)    │
                │  ├── consume/              (inbox inotify, 1000:1000) │
                │  ├── export/               (document_exporter dst)    │
                │  ├── db/data/              (PostgreSQL datadir)       │
                │  └── redis/data/           (Redis AOF)                │
                └───────────────────────────────────────────────────────┘
```

Punto de entrada del operador: deposita un PDF/imagen en `/mnt/hd2t/services/paperless-ngx/consume/` (vía Samba, drag&drop, escaneo de la multifunción de red, integración con Home Assistant); paperless-app lo detecta por inotify; el celery worker corre OCRmyPDF + Tesseract → clasifica → indexa → mueve a `media/documents/originals/` y `media/documents/archive/`; tras unos segundos el documento aparece en `https://paperless.lan` (autenticado vía Authelia 2FA) y es consultable por las apps móviles vía `https://paperless.lan/api/` con token.

---

## 2. Plan de variables y archivos

Coherente con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5: cada stack tiene un `.env.example` versionable en `~/homelab/stacks/paperless/` (con valores ficticios documentando) y un `.env` real fuera del repo (`/mnt/hd2t/services/paperless-ngx/.env`, `chmod 600`).

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/paperless/.env.example`:

```dotenv
# ─── Paperless-ngx — variables del stack ────────────────────────────────────
# Versionado en git (este fichero). El .env real vive en
# /mnt/hd2t/services/paperless-ngx/.env (chmod 600 root:homelab).

# ── Imágenes (pinned, no `latest`) ───────────────────────────────────────────
PAPERLESS_IMAGE=ghcr.io/paperless-ngx/paperless-ngx:2.13.5
POSTGRES_IMAGE=postgres:16-alpine
REDIS_IMAGE=redis:7-alpine

# ── Identidad de proceso ─────────────────────────────────────────────────────
PUID=1000
PGID=1000
USERMAP_UID=1000
USERMAP_GID=1000
TZ=Europe/Madrid

# ── Dominios y URL canónica ──────────────────────────────────────────────────
LAN_DOMAIN=lan
TS_DOMAIN=ts.net
PAPERLESS_URL=https://paperless.lan
PAPERLESS_ALLOWED_HOSTS=paperless.lan,paperless.ts.net,paperless-app,localhost
PAPERLESS_CSRF_TRUSTED_ORIGINS=https://paperless.lan,https://paperless.ts.net
PAPERLESS_TRUSTED_PROXIES=172.20.0.0/24
PAPERLESS_USE_X_FORWARD_HOST=true
PAPERLESS_USE_X_FORWARD_PORT=true
PAPERLESS_PROXY_SSL_HEADER=HTTP_X_FORWARDED_PROTO,https

# ── BD PostgreSQL ────────────────────────────────────────────────────────────
PAPERLESS_DBENGINE=postgres
PAPERLESS_DBHOST=postgres
PAPERLESS_DBPORT=5432
PAPERLESS_DBNAME=paperless
PAPERLESS_DBUSER=paperless
# PAPERLESS_DBPASS se lee del fichero secrets/db_password vía _FILE indirection.
PAPERLESS_DBPASS_FILE=/run/secrets/db_password
POSTGRES_DB=paperless
POSTGRES_USER=paperless
POSTGRES_PASSWORD_FILE=/run/secrets/db_password

# ── Redis (broker Celery, sin password — aislado en paperless_internal) ──────
PAPERLESS_REDIS=redis://broker:6379

# ── Django SECRET_KEY ────────────────────────────────────────────────────────
# Se lee del fichero secrets/secret_key.
PAPERLESS_SECRET_KEY_FILE=/run/secrets/secret_key

# ── Bootstrap del superuser (BORRAR tras primer login + rotación, §7.1) ──────
# PAPERLESS_ADMIN_USER=admin
# PAPERLESS_ADMIN_PASSWORD_FILE=/run/secrets/admin_password

# ── OCR ──────────────────────────────────────────────────────────────────────
PAPERLESS_OCR_LANGUAGE=spa+eng
PAPERLESS_OCR_LANGUAGES=spa eng
PAPERLESS_OCR_MODE=skip
PAPERLESS_OCR_OUTPUT_TYPE=pdfa
PAPERLESS_OCR_CLEAN=clean
PAPERLESS_OCR_DESKEW=true
PAPERLESS_OCR_ROTATE_PAGES=true
PAPERLESS_OCR_USER_ARGS={"continue_on_soft_render_error": true}

# ── Workers / paralelismo (Pi 5: 4 cores; reservar margen al resto) ──────────
PAPERLESS_TASK_WORKERS=2
PAPERLESS_THREADS_PER_WORKER=1
PAPERLESS_WEBSERVER_WORKERS=2

# ── Consumer (inotify + reglas de subdirectorios) ────────────────────────────
PAPERLESS_CONSUMER_POLLING=0
PAPERLESS_CONSUMER_RECURSIVE=true
PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS=true
PAPERLESS_CONSUMER_DELETE_DUPLICATES=true

# ── Filename format (estructura legible en disco) ────────────────────────────
PAPERLESS_FILENAME_FORMAT={created_year}/{correspondent}/{title}
PAPERLESS_FILENAME_DATE_ORDER=YMD

# ── Time zone ────────────────────────────────────────────────────────────────
PAPERLESS_TIME_ZONE=Europe/Madrid

# ── Tika / Gotenberg (variante §12.2 — descomentar y activar perfil) ─────────
# PAPERLESS_TIKA_ENABLED=true
# PAPERLESS_TIKA_GOTENBERG_ENDPOINT=http://gotenberg:3000
# PAPERLESS_TIKA_ENDPOINT=http://tika:9998
```

Notas sobre por qué en `.env.example`:

- **Hostname reales `paperless.lan` en `PAPERLESS_URL`/`ALLOWED_HOSTS`/`CSRF_TRUSTED_ORIGINS`**: en este stack **no** son secretos (son strings públicos), pero son parte del contrato con Caddy. Quedan en el `.env.example` como referencia. El operador puede sustituirlos en su `.env` real si su `LAN_DOMAIN` no es `lan` (ver [`../03-red/02-pihole.md`](../03-red/02-pihole.md) §X sobre el dominio interno).
- **`PAPERLESS_DBPASS_FILE`, `POSTGRES_PASSWORD_FILE`, `PAPERLESS_SECRET_KEY_FILE`, `PAPERLESS_ADMIN_PASSWORD_FILE`**: la imagen oficial soporta el sufijo `_FILE` para **todas** estas variables, leyendo el contenido del fichero indicado. Esto permite mantener los secretos en `secrets/` (bind mount como `/run/secrets/*`) y que **no aparezcan en `docker inspect`**. Es el patrón canónico del homelab (idéntico a Bookstack §3.3 y Authelia §6.X).
- **`PAPERLESS_ADMIN_USER` y `PAPERLESS_ADMIN_PASSWORD_FILE` están comentados**: solo se descomentan para el primer arranque (§5.2). Tras el primer login + rotación de password (§7.1), se vuelven a comentar/eliminar para evitar el pisotón silencioso descrito en §0 punto 10.

### 2.2. `.env` real (`/mnt/hd2t/services/paperless-ngx/.env`)

El `.env` real **es idéntico** al `.env.example` salvo dos diferencias durante el bootstrap:

1. Las variables `PAPERLESS_ADMIN_USER` y `PAPERLESS_ADMIN_PASSWORD_FILE` **están descomentadas** (solo el primer arranque).
2. Pertenece a `root:homelab` con `chmod 600`.

Tras §7.1, ambas líneas vuelven a comentarse y el `.env` queda idéntico al `.env.example`.

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` (§4) referencia `env_file: /mnt/hd2t/services/paperless-ngx/.env`. Compose carga **todas** las variables del fichero en el environment de los **tres** contenedores (`paperless-app`, `postgres`, `broker`). No todos los contenedores necesitan todas las variables, pero sobrar una variable es inocuo (paperless-app ignora `POSTGRES_PASSWORD_FILE` porque no la usa, postgres ignora `PAPERLESS_*`).

Los **secretos** (passwords, `SECRET_KEY`) se montan como **bind mount read-only** en `/run/secrets/<nombre>` y las variables `*_FILE` apuntan ahí. La imagen oficial de paperless-ngx, postgres y la convención de Compose secrets gestionan el resto.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
mkdir -p ~/homelab/stacks/paperless
cd ~/homelab/stacks/paperless
```

El árbol bajo `~/homelab/stacks/paperless/` (versionado en git) será:

```
paperless/
├── docker-compose.yml         # §4
├── .env.example               # §2.1, plantilla pública
└── README.md                  # opcional, "ver doc 04-paperless-ngx.md"
```

El `.env` real **NO** está aquí. Está en `/mnt/hd2t/services/paperless-ngx/.env`.

### 3.2. Crear el árbol de datos persistentes del servicio

```bash
# Directorios bajo /mnt/hd2t/services/paperless-ngx/ (creados con chown homelab por
# el bootstrap de Fase 1, §4.1 línea 241). Subdirectorios:
sudo install -d -o 1000 -g 1000 -m 750 /mnt/hd2t/services/paperless-ngx/data
sudo install -d -o 1000 -g 1000 -m 750 /mnt/hd2t/services/paperless-ngx/media
sudo install -d -o 1000 -g 1000 -m 750 /mnt/hd2t/services/paperless-ngx/consume
sudo install -d -o 1000 -g 1000 -m 750 /mnt/hd2t/services/paperless-ngx/export

# PostgreSQL: datadir va con UID 70 (postgres dentro de la imagen alpine).
# La imagen hace chown automático en el primer arranque, pero crear el dir
# con dueño correcto evita warning en logs.
sudo install -d -o 70 -g 70 -m 700 /mnt/hd2t/services/paperless-ngx/db
sudo install -d -o 70 -g 70 -m 700 /mnt/hd2t/services/paperless-ngx/db/data

# Redis: la imagen alpine corre como UID 999 (redis).
sudo install -d -o 999 -g 999 -m 750 /mnt/hd2t/services/paperless-ngx/redis
sudo install -d -o 999 -g 999 -m 750 /mnt/hd2t/services/paperless-ngx/redis/data

# Secrets (root:homelab, 750 para que homelab pueda listar pero no leer ficheros).
sudo install -d -o root -g homelab -m 750 /mnt/hd2t/services/paperless-ngx/secrets

# Verificación:
ls -la /mnt/hd2t/services/paperless-ngx
```

Esperado:

```
drwxr-x---  5 1000  1000   4096 ... consume
drwx------  3 70    70     4096 ... db
drwxr-x---  3 1000  1000   4096 ... data
drwxr-x---  3 1000  1000   4096 ... export
drwxr-x---  4 1000  1000   4096 ... media
drwxr-x---  3 999   999    4096 ... redis
drwxr-x---  2 root  homelab 4096 ... secrets
```

### 3.3. Generar las passwords y el `SECRET_KEY`

Tres secretos. Generar **fuera** del flujo de Compose (los ficheros se montarán read-only luego):

```bash
# 1) Password de PostgreSQL (la usan ambos: paperless-app y postgres-paperless).
openssl rand -base64 32 | sudo tee /mnt/hd2t/services/paperless-ngx/secrets/db_password >/dev/null

# 2) Django SECRET_KEY (mín. 50 caracteres aleatorios; usamos 128 hex = 64 bytes).
openssl rand -hex 64 | sudo tee /mnt/hd2t/services/paperless-ngx/secrets/secret_key >/dev/null

# 3) Password del superuser admin (solo para bootstrap, se rota en §7.1).
openssl rand -base64 32 | sudo tee /mnt/hd2t/services/paperless-ngx/secrets/admin_password >/dev/null

# Permisos: solo root lee, homelab no necesita acceso (Borgmatic corre como root).
sudo chmod 600 /mnt/hd2t/services/paperless-ngx/secrets/{db_password,secret_key,admin_password}
sudo chown root:homelab /mnt/hd2t/services/paperless-ngx/secrets/{db_password,secret_key,admin_password}

# Anotar en KeePassXC y Vaultwarden:
sudo cat /mnt/hd2t/services/paperless-ngx/secrets/db_password
sudo cat /mnt/hd2t/services/paperless-ngx/secrets/admin_password
# El SECRET_KEY no se anota (es regenerable: si se pierde, las sesiones existentes
# se invalidan pero la BD sigue legible; un nuevo SECRET_KEY es válido tras restart).
```

Validar que ningún fichero acaba en `\n` espurio (algunos `tee` dejan newline al final, OK; algunos parsers de Django no toleran trailing newline en `_FILE`):

```bash
sudo wc -c /mnt/hd2t/services/paperless-ngx/secrets/db_password
# Esperado: la longitud debe ser la del base64 + 1 (newline final OK; paperless lo strip-ea).

# Opcional: eliminar trailing newline (más conservador):
sudo sh -c 'for f in db_password secret_key admin_password; do
  printf "%s" "$(cat /mnt/hd2t/services/paperless-ngx/secrets/$f)" \
    > /mnt/hd2t/services/paperless-ngx/secrets/$f.tmp \
    && mv /mnt/hd2t/services/paperless-ngx/secrets/$f.tmp /mnt/hd2t/services/paperless-ngx/secrets/$f
  chmod 600 /mnt/hd2t/services/paperless-ngx/secrets/$f
  chown root:homelab /mnt/hd2t/services/paperless-ngx/secrets/$f
done'
```

### 3.4. Materializar el `.env` real

```bash
# Copiar la plantilla y editarla:
sudo cp ~/homelab/stacks/paperless/.env.example /mnt/hd2t/services/paperless-ngx/.env
sudo chown root:homelab /mnt/hd2t/services/paperless-ngx/.env
sudo chmod 600 /mnt/hd2t/services/paperless-ngx/.env

# Ediciones obligatorias antes del primer arranque (descomentar las dos líneas
# de bootstrap del admin):
sudo sed -i \
  -e 's@^# PAPERLESS_ADMIN_USER=.*@PAPERLESS_ADMIN_USER=admin@' \
  -e 's@^# PAPERLESS_ADMIN_PASSWORD_FILE=.*@PAPERLESS_ADMIN_PASSWORD_FILE=/run/secrets/admin_password@' \
  /mnt/hd2t/services/paperless-ngx/.env

# Verificar:
sudo grep -E '^PAPERLESS_(ADMIN|SECRET|DBPASS)' /mnt/hd2t/services/paperless-ngx/.env
```

Esperado:

```
PAPERLESS_DBPASS_FILE=/run/secrets/db_password
PAPERLESS_SECRET_KEY_FILE=/run/secrets/secret_key
PAPERLESS_ADMIN_USER=admin
PAPERLESS_ADMIN_PASSWORD_FILE=/run/secrets/admin_password
```

### 3.5. Tabla resumen de permisos

| Path | Owner:Group | Mode | Razón |
|---|---|---|---|
| `/mnt/hd2t/services/paperless-ngx/` | `homelab:homelab` | `750` | Creado por bootstrap Fase 1. |
| `.env` | `root:homelab` | `600` | Solo root lee (Compose lanza con sudo en su `systemd` unit; el operador `homelab` no necesita leer plaintext). |
| `secrets/` | `root:homelab` | `750` | `homelab` puede `ls` para auditar, no `cat`. |
| `secrets/db_password` | `root:homelab` | `600` | Idem. |
| `secrets/secret_key` | `root:homelab` | `600` | Idem. |
| `secrets/admin_password` | `root:homelab` | `600` | Idem. Borrado tras §7.1. |
| `data/` | `1000:1000` | `750` | Proceso paperless-app escribe el classifier, logs, caché. |
| `media/` | `1000:1000` | `750` | Proceso paperless-app escribe `originals/` y `archive/`. |
| `consume/` | `1000:1000` | `750` | Proceso paperless-app vigila inotify. **Samba puede escribir aquí** si el share usa el mismo UID 1000 (ver §10.2). |
| `export/` | `1000:1000` | `750` | Proceso paperless-app escribe la salida del `document_exporter`. |
| `db/data/` | `70:70` | `700` | Proceso postgres del contenedor. **NO `homelab`** lee aquí. |
| `redis/data/` | `999:999` | `750` | Proceso redis del contenedor. AOF + RDB. |

### 3.6. Permisos para el proceso del contenedor

La imagen oficial de paperless-ngx ejecuta su `docker-entrypoint.sh` como root al arrancar, hace `chown -R 1000:1000` sobre `/usr/src/paperless/{data,media,consume,export}` y luego dropea a UID 1000. Si los bind mounts ya tienen owner correcto (lo que §3.2 ha hecho), el `chown` es una NOOP y el arranque es rápido. Si el operador, por accidente, hace un `cp` con `sudo` en `consume/` y deja un fichero `root:root`, paperless lo procesará igual (el daemon corre como root durante el chown inicial, luego como 1000), pero **futuros backups Borgmatic** verán un fichero rootship en una jerarquía `1000:1000` y eso queda raro en logs. Convención del homelab: **siempre** `sudo install -o 1000 -g 1000` o `sudo -u homelab cp` al meter ficheros en `consume/`.

PostgreSQL alpine ejecuta como UID 70 dentro del contenedor (`postgres` user de la imagen). Su `entrypoint` también hace `chown` del datadir; al estar `db/data/` ya con owner 70, es NOOP.

Redis alpine ejecuta como UID 999 (`redis` user). Igual.

---

## 4. `docker-compose.yml`

`~/homelab/stacks/paperless/docker-compose.yml`:

```yaml
name: paperless

services:
  paperless-app:
    image: ${PAPERLESS_IMAGE}
    container_name: paperless-app
    hostname: paperless-app
    restart: unless-stopped
    env_file: /mnt/hd2t/services/paperless-ngx/.env
    environment:
      # Identidad
      USERMAP_UID: ${USERMAP_UID}
      USERMAP_GID: ${USERMAP_GID}
      TZ: ${TZ}
      PAPERLESS_TIME_ZONE: ${PAPERLESS_TIME_ZONE}

      # URL pública y proxy
      PAPERLESS_URL: ${PAPERLESS_URL}
      PAPERLESS_ALLOWED_HOSTS: ${PAPERLESS_ALLOWED_HOSTS}
      PAPERLESS_CSRF_TRUSTED_ORIGINS: ${PAPERLESS_CSRF_TRUSTED_ORIGINS}
      PAPERLESS_TRUSTED_PROXIES: ${PAPERLESS_TRUSTED_PROXIES}
      PAPERLESS_USE_X_FORWARD_HOST: ${PAPERLESS_USE_X_FORWARD_HOST}
      PAPERLESS_USE_X_FORWARD_PORT: ${PAPERLESS_USE_X_FORWARD_PORT}
      PAPERLESS_PROXY_SSL_HEADER: ${PAPERLESS_PROXY_SSL_HEADER}

      # BD
      PAPERLESS_DBENGINE: ${PAPERLESS_DBENGINE}
      PAPERLESS_DBHOST: ${PAPERLESS_DBHOST}
      PAPERLESS_DBPORT: ${PAPERLESS_DBPORT}
      PAPERLESS_DBNAME: ${PAPERLESS_DBNAME}
      PAPERLESS_DBUSER: ${PAPERLESS_DBUSER}
      PAPERLESS_DBPASS_FILE: ${PAPERLESS_DBPASS_FILE}

      # Redis broker
      PAPERLESS_REDIS: ${PAPERLESS_REDIS}

      # Django SECRET_KEY (vía _FILE)
      PAPERLESS_SECRET_KEY_FILE: ${PAPERLESS_SECRET_KEY_FILE}

      # Bootstrap admin (solo primer arranque; descomentado en .env durante §5.2)
      PAPERLESS_ADMIN_USER: ${PAPERLESS_ADMIN_USER:-}
      PAPERLESS_ADMIN_PASSWORD_FILE: ${PAPERLESS_ADMIN_PASSWORD_FILE:-}

      # OCR
      PAPERLESS_OCR_LANGUAGE: ${PAPERLESS_OCR_LANGUAGE}
      PAPERLESS_OCR_LANGUAGES: ${PAPERLESS_OCR_LANGUAGES}
      PAPERLESS_OCR_MODE: ${PAPERLESS_OCR_MODE}
      PAPERLESS_OCR_OUTPUT_TYPE: ${PAPERLESS_OCR_OUTPUT_TYPE}
      PAPERLESS_OCR_CLEAN: ${PAPERLESS_OCR_CLEAN}
      PAPERLESS_OCR_DESKEW: ${PAPERLESS_OCR_DESKEW}
      PAPERLESS_OCR_ROTATE_PAGES: ${PAPERLESS_OCR_ROTATE_PAGES}
      PAPERLESS_OCR_USER_ARGS: ${PAPERLESS_OCR_USER_ARGS}

      # Workers
      PAPERLESS_TASK_WORKERS: ${PAPERLESS_TASK_WORKERS}
      PAPERLESS_THREADS_PER_WORKER: ${PAPERLESS_THREADS_PER_WORKER}
      PAPERLESS_WEBSERVER_WORKERS: ${PAPERLESS_WEBSERVER_WORKERS}

      # Consumer
      PAPERLESS_CONSUMER_POLLING: ${PAPERLESS_CONSUMER_POLLING}
      PAPERLESS_CONSUMER_RECURSIVE: ${PAPERLESS_CONSUMER_RECURSIVE}
      PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS: ${PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS}
      PAPERLESS_CONSUMER_DELETE_DUPLICATES: ${PAPERLESS_CONSUMER_DELETE_DUPLICATES}

      # Filenames
      PAPERLESS_FILENAME_FORMAT: ${PAPERLESS_FILENAME_FORMAT}
      PAPERLESS_FILENAME_DATE_ORDER: ${PAPERLESS_FILENAME_DATE_ORDER}
    volumes:
      - type: bind
        source: /mnt/hd2t/services/paperless-ngx/data
        target: /usr/src/paperless/data
        bind:
          create_host_path: false
      - type: bind
        source: /mnt/hd2t/services/paperless-ngx/media
        target: /usr/src/paperless/media
        bind:
          create_host_path: false
      - type: bind
        source: /mnt/hd2t/services/paperless-ngx/consume
        target: /usr/src/paperless/consume
        bind:
          create_host_path: false
      - type: bind
        source: /mnt/hd2t/services/paperless-ngx/export
        target: /usr/src/paperless/export
        bind:
          create_host_path: false

      # Secretos read-only
      - type: bind
        source: /mnt/hd2t/services/paperless-ngx/secrets/db_password
        target: /run/secrets/db_password
        read_only: true
        bind:
          create_host_path: false
      - type: bind
        source: /mnt/hd2t/services/paperless-ngx/secrets/secret_key
        target: /run/secrets/secret_key
        read_only: true
        bind:
          create_host_path: false
      - type: bind
        source: /mnt/hd2t/services/paperless-ngx/secrets/admin_password
        target: /run/secrets/admin_password
        read_only: true
        bind:
          create_host_path: false
    networks:
      - homelab
      - paperless_internal
    depends_on:
      postgres:
        condition: service_healthy
      broker:
        condition: service_healthy
    cap_drop:
      - ALL
    cap_add:
      - CHOWN              # entrypoint hace chown -R UID:GID en data/media/consume/export
      - DAC_OVERRIDE       # lee secrets root-owned montados read-only
      - FOWNER
      - SETGID
      - SETUID
      - NET_BIND_SERVICE   # Gunicorn :8000 (>1024, no estricto, pero supervisord puede usarlo internamente)
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://127.0.0.1:8000/ || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s   # primera vez: instala paquetes Tesseract de OCR_LANGUAGES, ~60-90 s
    labels:
      com.centurylinklabs.watchtower.enable: "false"
      homepage.group: "Productividad"
      homepage.name: "Paperless-ngx"
      homepage.icon: "paperless-ngx.png"
      homepage.href: "https://paperless.${LAN_DOMAIN}"
      homepage.description: "Gestor documental con OCR"

  postgres:
    image: ${POSTGRES_IMAGE}
    container_name: postgres-paperless
    hostname: postgres
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD_FILE: ${POSTGRES_PASSWORD_FILE}
      # PGDATA: por defecto /var/lib/postgresql/data; mantenemos el default.
    volumes:
      - type: bind
        source: /mnt/hd2t/services/paperless-ngx/db/data
        target: /var/lib/postgresql/data
        bind:
          create_host_path: false
      - type: bind
        source: /mnt/hd2t/services/paperless-ngx/secrets/db_password
        target: /run/secrets/db_password
        read_only: true
        bind:
          create_host_path: false
    networks:
      - paperless_internal
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - DAC_OVERRIDE
      - FOWNER
      - SETGID
      - SETUID
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB} || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s
    labels:
      com.centurylinklabs.watchtower.enable: "false"

  broker:
    image: ${REDIS_IMAGE}
    container_name: redis-paperless
    hostname: broker
    restart: unless-stopped
    command:
      - "redis-server"
      - "--appendonly"
      - "yes"
      - "--maxmemory"
      - "128mb"
      - "--maxmemory-policy"
      - "allkeys-lru"
    volumes:
      - type: bind
        source: /mnt/hd2t/services/paperless-ngx/redis/data
        target: /data
        bind:
          create_host_path: false
    networks:
      - paperless_internal
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 10s
    labels:
      com.centurylinklabs.watchtower.enable: "false"

networks:
  homelab:
    external: true
  paperless_internal:
    driver: bridge
    internal: false   # paperless-app necesita salida (descarga de paquetes Tesseract en arranques tras pulls)
```

### 4.1. Por qué cada bloque

| Línea | Por qué |
|---|---|
| `name: paperless` | `compose project name` explícito; visible en `docker compose ls`. Más corto que `paperless-ngx`. |
| `image: ${PAPERLESS_IMAGE}` etc. | Tags completos desde `.env`, grep-ables, diff-ables. |
| `container_name: paperless-app` / `postgres-paperless` / `redis-paperless` | DNS interno: Caddy llama `http://paperless-app:8000`, Borgmatic llama `postgres-paperless` ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6, hostname del bloque `postgresql_databases:` `paperless`). |
| `hostname: postgres` y `hostname: broker` | DNS corto dentro de `paperless_internal`. Paperless-app conecta vía `PAPERLESS_DBHOST=postgres` y `PAPERLESS_REDIS=redis://broker:6379`. Patrón idéntico a Bookstack §4.1 (donde `mariadb` es el alias corto). |
| `restart: unless-stopped` | Auto-arranque tras reboot. `unless-stopped` (no `always`) permite parar manualmente para mantenimiento. |
| `env_file: /mnt/hd2t/services/paperless-ngx/.env` | Path absoluto, fuera del repo. Justificado en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.1. |
| `environment:` (re-declaración explícita en `paperless-app`) | Aunque `env_file` ya carga las vars, declararlas aquí explícitamente sirve de contrato visible en `docker compose config` y permite el patrón `${VAR:-}` para hacer **opcionales** las dos vars de bootstrap del admin (vacías cuando se borran tras §7.1). |
| `PAPERLESS_DBPASS_FILE: /run/secrets/db_password` | `_FILE` indirection oficial. La password no aparece en `docker inspect`. |
| `volumes:` con `bind: create_host_path: false` | Si el path host no existe, **falla** en lugar de crearlo (que podría generar un dir root-owned y romper permisos). El path host lo crea §3.2 con la propiedad correcta. |
| `paperless-app` en redes `homelab` + `paperless_internal` | Caddy llega por `homelab` (`http://paperless-app:8000`). Postgres y Redis solo son alcanzables por `paperless_internal`. |
| `postgres` y `broker` solo en `paperless_internal` | Defensa en profundidad. Imposible alcanzarlos desde Caddy o desde otros stacks aunque la env var se filtre. |
| `depends_on: { postgres: healthy, broker: healthy }` | El init de paperless-ngx hace `python manage.py migrate` y `celery worker` al arrancar; si las dependencias no están listas, falla. |
| `cap_drop: ALL` + `cap_add` selectivos | Privilegio mínimo. Las capabilities añadidas en `paperless-app` son las que el `docker-entrypoint.sh` necesita para hacer `chown` y luego dropear. |
| `no-new-privileges:true` | Impide `setuid`/`setgid` en escalada de privilegios dentro del contenedor. |
| `healthcheck: paperless-app` con `curl /` (no `/health`) | Paperless-ngx **no** expone un endpoint `/health` dedicado. La home redirige a `/accounts/login/` con 302 — `curl -fsS` (que sigue redirects con `-L`, aquí no usamos `-L` pero `--fail` también acepta 3xx) acepta cualquier 2xx/3xx como sano. La variante con `/api/` requeriría auth y complicaría el healthcheck. |
| `healthcheck: postgres` con `pg_isready` | Patrón estándar (idéntico al de Nextcloud). `$${POSTGRES_USER}` usa `$$` para que Compose **no** interpole la variable y la pase tal cual al shell del contenedor (donde sí está expandida). |
| `healthcheck: broker` con `redis-cli ping` | Patrón estándar. |
| `start_period: 120s` (paperless-app) | El **primer arranque** descarga e instala los paquetes Tesseract de `PAPERLESS_OCR_LANGUAGES`. En arm64 con conexión doméstica, `tesseract-ocr-spa` + `tesseract-ocr-eng` tarda 60-90 s. Sin `start_period` largo, los healthchecks fallan durante la instalación y Compose marca el contenedor como `unhealthy` aunque luego se recupere. |
| `redis-server` con `--appendonly yes` y `--maxmemory 128mb` | AOF (append-only file) deja recuperar la cola Celery tras un crash. 128 MB es suficiente para miles de tareas en cola; el `allkeys-lru` evicta primero las menos usadas si se llena. |
| `labels: watchtower.enable: "false"` (los tres) | Justificado en §0 punto 6. Postgres y Redis nunca van con Watchtower. |
| `labels: homepage.*` (solo en `paperless-app`) | Auto-descubrimiento en el dashboard Homepage ([`../12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md)). Postgres y Redis no se publican en Homepage. |
| `networks.paperless_internal: driver: bridge, internal: false` | `internal: true` cortaría salida a internet de **todo** lo conectado. Como `paperless-app` también está en esta red Y necesita salida (para descargar tesseract-ocr-spa la primera vez, y para futuras integraciones email-as-source/Tika), `internal: false`. Postgres y Redis solo están aquí pero ellos no inician conexiones salientes — irrelevante en la práctica. |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/paperless
docker compose --env-file /mnt/hd2t/services/paperless-ngx/.env config

# Esperado: YAML expandido, sin warnings tipo "WARNING: variable X not set",
# sin "WARNING: image with no platform".

# Verificar que las imágenes son alcanzables y multi-arch:
docker buildx imagetools inspect ghcr.io/paperless-ngx/paperless-ngx:2.13.5 \
  | grep -E 'linux/(arm64|amd64)'
docker buildx imagetools inspect postgres:16-alpine \
  | grep -E 'linux/(arm64|amd64)'
docker buildx imagetools inspect redis:7-alpine \
  | grep -E 'linux/(arm64|amd64)'
# Esperado: las tres imágenes con líneas linux/arm64 y linux/amd64.
```

---

## 5. Despliegue

### 5.1. Levantar primero `postgres` y `broker`

```bash
cd ~/homelab/stacks/paperless
docker compose --env-file /mnt/hd2t/services/paperless-ngx/.env up -d postgres broker

# Esperar a que el primer init de Postgres termine: crea el cluster, la BD
# `paperless`, el user `paperless`, aplica `initdb`. Tarda ~20-40 s.
docker logs -f postgres-paperless
# Buscar: "database system is ready to accept connections" + "PostgreSQL init process complete; ready for start up."
# Ctrl+C cuando aparezca.
```

Validación de la BD vacía:

```bash
docker exec postgres-paperless psql \
    -U paperless -d paperless \
    -c "\l" \
    -c "\du" \
    -c "SELECT version();"

# Esperado:
#   - Lista de databases: paperless, postgres, template0, template1.
#   - Lista de roles: paperless (con LOGIN), postgres (superuser).
#   - PostgreSQL 16.x.
```

Validación de Redis:

```bash
docker exec redis-paperless redis-cli ping
# Esperado: PONG

docker exec redis-paperless redis-cli config get maxmemory
# Esperado: maxmemory 134217728  (128 MB)
```

### 5.2. Levantar `paperless-app`

**Antes** del primer `up`, asegurarse de que las variables de bootstrap del admin **están descomentadas** en el `.env` (§3.4):

```bash
sudo grep -E '^PAPERLESS_ADMIN' /mnt/hd2t/services/paperless-ngx/.env
# Esperado:
#   PAPERLESS_ADMIN_USER=admin
#   PAPERLESS_ADMIN_PASSWORD_FILE=/run/secrets/admin_password
```

Levantar:

```bash
cd ~/homelab/stacks/paperless
docker compose --env-file /mnt/hd2t/services/paperless-ngx/.env up -d paperless-app

docker logs -f paperless-app
```

En el primer arranque, los logs muestran (en este orden):

1. **Permisos**: `Mapping UID for paperless to ${USERMAP_UID}` y `Mapping GID for paperless to ${USERMAP_GID}`.
2. **Instalación de paquetes Tesseract**: `Installing additional OCR languages...`. Tarda 60-90 s.
3. **Migraciones Django**: `Running migration ...` (~10-30 segundos en BD vacía).
4. **Creación del superuser**: `Creating Django superuser admin from environment.` (esta línea **solo aparece** en el primer arranque, y solo si `PAPERLESS_ADMIN_USER` y `PAPERLESS_ADMIN_PASSWORD_FILE` están definidos).
5. **Indexer**: `Index has been rebuilt.` (rebuild del índice de búsqueda Whoosh; vacío en este momento).
6. **Supervisord**: `[supervisord] starting up...` con líneas para `web` (Gunicorn), `celery_worker`, `celery_beat`, `consumer`.
7. **Listo**: `[gunicorn] Listening at: http://0.0.0.0:8000`.

`Ctrl+C` cuando llegue ahí.

### 5.3. Estado del contenedor

```bash
docker compose --env-file /mnt/hd2t/services/paperless-ngx/.env ps

# Esperado: 3 contenedores Up (healthy):
#   paperless-app       ghcr.io/paperless-ngx/paperless-ngx:2.13.5   Up X minutes (healthy)
#   postgres-paperless  postgres:16-alpine                            Up X minutes (healthy)
#   redis-paperless     redis:7-alpine                                Up X minutes (healthy)
```

Verificar las redes:

```bash
docker inspect paperless-app --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}'
# Esperado: homelab y paperless_internal.

docker inspect postgres-paperless --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}'
# Esperado: paperless_internal (y NADA más).

docker inspect redis-paperless --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}'
# Esperado: paperless_internal (y NADA más).
```

### 5.4. Verificar ficheros físicos

```bash
sudo ls -la /mnt/hd2t/services/paperless-ngx/data
# Esperado: index/, classification_model.pickle (vacío en arranque virgen),
# log/, paperless-* (Whoosh), uid/.

sudo ls -la /mnt/hd2t/services/paperless-ngx/media
# Esperado: documents/ (vacío), thumbnails/ (vacío).

sudo ls -la /mnt/hd2t/services/paperless-ngx/db/data
# Esperado: base/, global/, pg_*, postgresql.conf, etc. Estructura típica de Postgres.

sudo ls -la /mnt/hd2t/services/paperless-ngx/redis/data
# Esperado: appendonlydir/ (AOF) y/o dump.rdb.
```

### 5.5. Smoke check antes de publicar por Caddy

```bash
# Probar la app desde la red homelab usando un contenedor curl ad-hoc:
docker run --rm --network homelab curlimages/curl:8.10.1 \
    -fsS -o /dev/null -w '%{http_code}\n' http://paperless-app:8000/
# Esperado: 302 (redirect a /accounts/login/).

docker run --rm --network homelab curlimages/curl:8.10.1 \
    -fsS http://paperless-app:8000/accounts/login/ | head -20
# Esperado: HTML del formulario de login Django de paperless-ngx.

# Probar el endpoint /api/:
docker run --rm --network homelab curlimages/curl:8.10.1 \
    -fsS http://paperless-app:8000/api/
# Esperado: JSON con la lista de endpoints REST disponibles
# (correspondents, documents, document_types, tags, ...).
```

Validar que Postgres y Redis **no** son alcanzables desde la red `homelab`:

```bash
docker run --rm --network homelab curlimages/curl:8.10.1 \
    --max-time 3 -v telnet://postgres:5432 2>&1 | head -3
# Esperado: timeout o "Could not resolve host: postgres" (segregación correcta).

docker run --rm --network homelab curlimages/curl:8.10.1 \
    --max-time 3 -v telnet://broker:6379 2>&1 | head -3
# Esperado: timeout o "Could not resolve host: broker".
```

### 5.6. Backup inicial del estado virgen

Antes de añadir Caddy / Authelia / DNS / poblar la BD:

```bash
# Forzar un run Borgmatic ad-hoc (si Borgmatic ya existe) — esto valida los hooks:
sudo borgmatic --verbosity 1 --files

# Si Borgmatic aún no tiene la entrada `paperless` en postgresql_databases:,
# §9.2 muestra cómo añadirla. Por ahora, un dump manual:
sudo install -d -o root -g root -m 700 /mnt/hd2t/backups/dumps/paperless
docker exec postgres-paperless pg_dump \
    -U paperless -d paperless \
    --format=custom --no-owner --no-privileges \
    -f /tmp/paperless-virgin.dump

docker cp postgres-paperless:/tmp/paperless-virgin.dump \
    /mnt/hd2t/backups/dumps/paperless/virgin-$(date +%F).dump
sudo chown root:root /mnt/hd2t/backups/dumps/paperless/virgin-*.dump
sudo chmod 600 /mnt/hd2t/backups/dumps/paperless/virgin-*.dump

ls -la /mnt/hd2t/backups/dumps/paperless/
# Esperado: virgin-YYYY-MM-DD.dump, ~50-100 KB (BD vacía con migrations aplicadas).
```

---

## 6. Integración con Caddy

### 6.1. Añadir el bloque `paperless.{$LAN_DOMAIN}` al `Caddyfile`

Editar `~/homelab/stacks/proxy/Caddyfile` y añadir (después de los bloques ya existentes, antes del `# Tailscale` comentado):

```caddy
# Paperless-ngx (../11-productividad/04-paperless-ngx.md)
paperless.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Apps móviles, escáneres, integraciones — token API nativo de paperless.
    # Authelia romperia el flujo: las apps no siguen redirects HTML.
    @api path /api/* /api /api/token /api/token/
    handle @api {
        reverse_proxy http://paperless-app:8000
    }

    # UI humana (login Django, dashboard, edición) — Authelia 2FA + login Django.
    handle {
        import authelia_proxy
        reverse_proxy http://paperless-app:8000
    }
}
```

| Línea | Por qué |
|---|---|
| `import lan_internal_tls` | TLS con CA interna ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §X.X). |
| `import security_headers` | HSTS + X-Frame-Options + X-Content-Type-Options + Referrer-Policy. Paperless sirve sus propias páginas en HTML; ningún iframe externo legítimo. |
| `@api path /api/* /api /api/token /api/token/` | Matcher que captura **todas** las URLs bajo `/api/`. Las cuatro variantes cubren: `/api/` (root listing), `/api/<endpoint>/` (detalle), `/api/token` (login con username+password→token), `/api/token/` (variante con slash). El path matcher de Caddy **no** es greedy por defecto; `/api/*` matchea `/api/foo` pero **no** `/api`, de ahí las cuatro entradas. |
| `handle @api { ... }` (sin `import authelia_proxy`) | Las apps móviles / scripts envían `Authorization: Token <hex>` y esperan JSON. Sin Authelia: la auth la lleva el propio Django REST Framework. |
| `handle { import authelia_proxy ... }` | Bloque por defecto: cualquier path que **no** empiece por `/api/` pasa por Authelia (`forward_auth` a `auth.lan` con 2FA TOTP) **antes** de llegar a paperless. La regla `paperless.{$LAN_DOMAIN}` ya está en `access_control.rules` de Authelia (línea 422) con `policy: two_factor`, `subject: group:admin`. |
| `reverse_proxy http://paperless-app:8000` (en ambos handles) | Caddy llega por la red `homelab` al contenedor `paperless-app`. HTTP plano dentro de Docker (Caddy ya hace TLS terminator hacia el navegador). Paperless confía en `X-Forwarded-Proto: https` que Caddy inyecta y que `PAPERLESS_PROXY_SSL_HEADER` reconoce. |

### 6.2. Recargar Caddy

```bash
cd ~/homelab/stacks/proxy
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
# Esperado: "Valid configuration".

docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
# Esperado: sin output (éxito) o "successfully started".
```

Verificación en logs:

```bash
docker logs --tail 50 caddy | grep -E 'paperless|reload'
# Esperado: la nueva ruta aparece y un log "reloaded successfully".
```

### 6.3. Registro DNS local en Pi-hole

En la UI de Pi-hole (`https://pihole.${LAN_DOMAIN}/admin`):
- **Local DNS Records** → **Add a new domain/IP combination**.
- Domain: `paperless.lan`
- IP: la IP del host donde escucha Caddy (`192.168.1.10` por convención del homelab; ver [`../03-red/02-pihole.md`](../03-red/02-pihole.md)).
- **Add**.

Validación:

```bash
dig +short @192.168.1.241 paperless.lan
# Esperado: 192.168.1.10  (la IP de Caddy/Pi).
```

### 6.4. Probar el acceso desde el navegador

1. Abrir `https://paperless.lan` en un navegador con la CA interna de Caddy ya confiada.
2. **Authelia** intercepta: muestra `https://auth.lan/?rd=https%3A%2F%2Fpaperless.lan%2F`.
3. Login con la cuenta del operador + TOTP.
4. Authelia redirige a `https://paperless.lan/`.
5. Paperless-ngx muestra **su propio formulario de login Django** (el operador acepta el doble login en esta fase; OIDC en §12.5).
6. Login con `admin` / la password del fichero `secrets/admin_password` (la generada en §3.3). **Cambiar inmediatamente** en §7.1.

Validar que `/api/` **no** pasa por Authelia:

```bash
# Sin token → 401 Unauthorized de Django REST Framework, NO 30x de Authelia:
curl -k -s -o /dev/null -w '%{http_code}\n' https://paperless.lan/api/
# Esperado: 401  (no 302 ni 303 — eso significaría que Authelia está interceptando).

# Con token (cuando exista, §7.3):
curl -k -s -H 'Authorization: Token <TOKEN>' https://paperless.lan/api/ | head -20
# Esperado: JSON con la lista de endpoints.
```

### 6.5. Acceso vía Tailscale (preparado, no activo)

Mismo patrón que el resto del homelab: cuando Tailscale esté desplegado ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) se añade un segundo bloque en el `Caddyfile`:

```caddy
# Paperless-ngx vía Tailscale (descomentar tras 03-red/05-tailscale.md).
# paperless.{$TS_DOMAIN} {
#     import tailscale_tls paperless
#     import security_headers
#
#     @api path /api/* /api /api/token /api/token/
#     handle @api {
#         reverse_proxy http://paperless-app:8000
#     }
#
#     handle {
#         import authelia_proxy
#         reverse_proxy http://paperless-app:8000
#     }
# }
```

Hasta entonces, el acceso fuera de casa pasa por Tailscale al hostname `pi.${TS_DOMAIN}` con resolución DNS interna a `paperless.lan`, **no** se expone a internet.

---

## 7. Configuración post-despliegue

### 7.1. Login del operador y rotación de la password del superusuario

1. Abrir `https://paperless.lan` y hacer login (Authelia + Django como en §6.4).
2. Una vez dentro, **clicar en el icono del usuario** (esquina superior derecha) → **My profile** (o navegar a `https://paperless.lan/accounts/profile/`).
3. **Change password** → introducir la password actual (la del fichero `secrets/admin_password`) + nueva password (generar con `openssl rand -base64 24` y anotar en Vaultwarden).
4. **Logout** y volver a entrar con la password nueva, **confirmando** que funciona.

Tras la rotación, **eliminar el bootstrap del `.env`**:

```bash
# Comentar las dos líneas en el .env real:
sudo sed -i \
  -e 's@^PAPERLESS_ADMIN_USER=.*@# PAPERLESS_ADMIN_USER=admin@' \
  -e 's@^PAPERLESS_ADMIN_PASSWORD_FILE=.*@# PAPERLESS_ADMIN_PASSWORD_FILE=/run/secrets/admin_password@' \
  /mnt/hd2t/services/paperless-ngx/.env

# Borrar el fichero del secret (ya no se usa):
sudo rm /mnt/hd2t/services/paperless-ngx/secrets/admin_password

# Recrear el contenedor para que las env vars vacías surtan efecto:
cd ~/homelab/stacks/paperless
docker compose --env-file /mnt/hd2t/services/paperless-ngx/.env up -d --force-recreate paperless-app

docker logs paperless-app | grep -i 'admin' | tail -5
# Esperado: ya NO debe aparecer "Creating Django superuser admin from environment."
```

### 7.2. Configurar settings del sitio (UI)

Como `admin`, navegar a `https://paperless.lan/admin/` (Django admin clásico, distinto de la UI principal):

1. **Sites** → site `example.com` → cambiar a `paperless.lan`. (Algunas notificaciones absolute-URL usan este registro.)
2. **Volver a la UI principal** (botón "Site" arriba) → **Settings** (icono engranaje superior derecho):
   - **Display language**: español/inglés según preferencia.
   - **Date display format**: `Day/Month/Year` (España).
   - **Theme**: claro/oscuro/auto.
   - **Documents per page**: 50 (default).
   - **Notes**: enabled (permite añadir notas a documentos).

### 7.3. Crear cuentas para familiares (opcional)

Si el operador quiere compartir paperless con cónyuge/hermanos:

1. **Settings** (UI) → **Users & Groups** → **Create user**:
   - Username, email, password (generada y anotada en Vaultwarden compartido).
   - **Permissions**: por defecto, ningún permiso (deben asignarse documentos uno-a-uno o por grupo).
2. Para acceso completo al sitio: asignar al grupo `admin` (también necesario en Authelia: el `subject: group:admin` de la regla está condicionado al grupo en Authelia, ver [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §X). Para acceso de **solo lectura**: crear un grupo personalizado en `/admin/` con permisos `view_*`.
3. **Permisos de documento**: paperless-ngx soporta ACLs **por documento**. El operador puede subir un documento con `View permissions: alice@home, bob@home` y `Edit permissions: alice@home`.

Sin SMTP, las invitaciones se hacen por canal externo (chat familiar, papel, etc.) — el operador comunica username + password inicial; el familiar la rota en su primer login.

### 7.4. Generar el token API para apps móviles e integraciones

Cada **usuario** tiene su propio token. Para crear el del operador (admin):

1. Login en `https://paperless.lan` (UI).
2. **My Profile** → sección **API Auth Token** → **Generate new token**.
3. Copiar el token (es un hex de 40 caracteres). **No se vuelve a mostrar**: si se pierde, hay que regenerar.
4. Anotar en Vaultwarden con label `paperless.lan API token (admin)`.

Validación con `curl`:

```bash
TOKEN='<el token de 40 hex>'
curl -k -s -H "Authorization: Token $TOKEN" https://paperless.lan/api/documents/?page_size=1 | jq .count
# Esperado: 0  (BD vacía).
```

Configurar la app móvil:

1. **Paperless Mobile** (Android) o **Paperless** (iOS): instalar.
2. **Add server** → URL: `https://paperless.lan` → **Login type**: API Token → pegar el token.
3. La app valida → **Connect**. Si falla con TLS error, el dispositivo no tiene la CA interna confiada (volver a [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §6.5).

Para acceso desde fuera de casa: usar la misma URL `https://paperless.lan` desde un dispositivo conectado a Tailscale ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) — Tailscale + MagicDNS resuelven el hostname interno. Variante con `paperless.${TS_DOMAIN}` activa cuando el bloque del Caddyfile esté descomentado (§6.5).

### 7.5. Configurar el directorio de consumo

El consumer ya está activo (vigila `/usr/src/paperless/consume/` por inotify). Probar:

```bash
# Como homelab, copiar un PDF de prueba al consume directory:
sudo -u homelab cp /alguna/factura.pdf /mnt/hd2t/services/paperless-ngx/consume/

# En unos segundos paperless lo detecta:
docker logs --tail 20 paperless-app | grep -i 'consume\|consuming'
# Esperado:
#   Consuming 1 file at .../consume/factura.pdf
#   ...
#   Document successfully consumed.

# El fichero original se mueve a media/documents/originals/ y se borra de consume/:
ls -la /mnt/hd2t/services/paperless-ngx/consume/
# Esperado: vacío (excepto subdirectorios si existen).

ls /mnt/hd2t/services/paperless-ngx/media/documents/originals/
# Esperado: jerarquía {año}/{correspondent}/{title}.pdf.
```

### 7.6. (Opcional) Subdirectorios con tagging automático

Crear subdirectorios bajo `consume/` que paperless interpretará como **tags** automáticos:

```bash
sudo install -d -o 1000 -g 1000 /mnt/hd2t/services/paperless-ngx/consume/escaner
sudo install -d -o 1000 -g 1000 /mnt/hd2t/services/paperless-ngx/consume/movil
sudo install -d -o 1000 -g 1000 /mnt/hd2t/services/paperless-ngx/consume/email
sudo install -d -o 1000 -g 1000 /mnt/hd2t/services/paperless-ngx/consume/backup-papel
```

Cualquier PDF caído en `consume/escaner/` recibirá automáticamente la etiqueta `escaner` (creada en BD si no existe). Esto encadena con `PAPERLESS_CONSUMER_RECURSIVE=true` y `PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS=true` del `.env`.

### 7.7. Verificación post-despliegue

- [ ] `https://paperless.lan` carga, pide login Authelia + Django.
- [ ] Login admin funciona con la nueva password (la del bootstrap está rotada y desactivada).
- [ ] Las dos variables `PAPERLESS_ADMIN_*` están comentadas en `.env`.
- [ ] El fichero `secrets/admin_password` está borrado.
- [ ] Token API generado y anotado en Vaultwarden.
- [ ] App móvil conecta (al menos en una prueba) — opcional si el operador no la usa.
- [ ] Subir un PDF a `consume/` produce un documento en la UI con OCR aplicado.
- [ ] El healthcheck del contenedor está `healthy`.
- [ ] `https://paperless.lan/api/` responde 401 (no 302 a `auth.lan/?rd=...`) — el bypass de Authelia funciona.
- [ ] Borgmatic incluye paperless (ver §9.2).

---

## 8. Verificación

### 8.1. Contenedores sanos y permisos correctos

```bash
docker ps --filter name=paperless --format 'table {{.Names}}\t{{.Status}}'
# Esperado:
#   NAMES                STATUS
#   paperless-app        Up X minutes (healthy)
#   postgres-paperless   Up X minutes (healthy)
#   redis-paperless      Up X minutes (healthy)

# Owner de los datos (ningún root espurio):
sudo find /mnt/hd2t/services/paperless-ngx/{data,media,consume,export} \
    \! -user 1000 -ls
# Esperado: vacío.

sudo find /mnt/hd2t/services/paperless-ngx/db/data \! -user 70 -ls
# Esperado: vacío.

sudo find /mnt/hd2t/services/paperless-ngx/redis/data \! -user 999 -ls
# Esperado: vacío.

sudo find /mnt/hd2t/services/paperless-ngx/secrets \! -user root -ls
# Esperado: vacío.
```

### 8.2. Paperless no escucha al host

```bash
sudo ss -tlnp | grep -E ':(8000|5432|6379)\s'
# Esperado: vacío. (Ningún contenedor publica al host.)

# Postgres y Redis tampoco son alcanzables vía la red `homelab`:
docker run --rm --network homelab alpine:3.19 sh -c '
    nc -zvw3 postgres 5432 2>&1 || echo "OK: no alcanzable"
    nc -zvw3 broker 6379 2>&1 || echo "OK: no alcanzable"'
# Esperado: ambas líneas "OK: no alcanzable" (o "name does not resolve").
```

### 8.3. UI accesible vía Caddy + Authelia

```bash
# Sin cookie de Authelia → Caddy debería redirigir a auth.lan:
curl -k -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' \
    https://paperless.lan/
# Esperado: 302 -> https://auth.lan/?rd=https%3A%2F%2Fpaperless.lan%2F

# /api/ no pasa por Authelia: 401 directo:
curl -k -s -o /dev/null -w '%{http_code}\n' https://paperless.lan/api/
# Esperado: 401  (Django REST Framework).
```

### 8.4. API accesible con token

```bash
TOKEN='<token del operador>'
curl -k -s -H "Authorization: Token $TOKEN" https://paperless.lan/api/ \
    | jq 'keys'
# Esperado: ["correspondents","custom_fields","document_types","documents",
#            "groups","mail_accounts","mail_rules","saved_views","schema",
#            "share_links","statistics","storage_paths","tags","tasks",
#            "trash","ui_settings","users","workflow_actions",
#            "workflow_triggers","workflows"]
#  (orden alfabético, lista exhaustiva del API v6).

curl -k -s -H "Authorization: Token $TOKEN" \
    https://paperless.lan/api/documents/?page_size=1 \
    | jq .count
# Esperado: número entero ≥ 0.
```

### 8.5. Persistencia tras reboot

```bash
# Subir un documento de prueba:
sudo -u homelab cp /tmp/prueba.pdf /mnt/hd2t/services/paperless-ngx/consume/
sleep 30
COUNT_BEFORE=$(curl -k -s -H "Authorization: Token $TOKEN" \
    https://paperless.lan/api/documents/?page_size=1 | jq .count)

# Reiniciar todo el stack:
cd ~/homelab/stacks/paperless
docker compose --env-file /mnt/hd2t/services/paperless-ngx/.env down
docker compose --env-file /mnt/hd2t/services/paperless-ngx/.env up -d

sleep 30
COUNT_AFTER=$(curl -k -s -H "Authorization: Token $TOKEN" \
    https://paperless.lan/api/documents/?page_size=1 | jq .count)

[[ "$COUNT_BEFORE" == "$COUNT_AFTER" ]] && echo "OK: persistencia confirmada" \
                                        || echo "FAIL: pérdida de datos"
```

### 8.6. Backup hooks Borgmatic ejecutándose

(Asumiendo que §9.2 ya añadió la entrada `paperless` al `postgresql_databases:` de Borgmatic.)

```bash
sudo borgmatic --verbosity 1 --files 2>&1 | grep -i 'paperless'
# Esperado:
#   Pinging Postgres on hostname postgres-paperless port 5432 with database paperless
#   Dumping Postgres database paperless
#   Dump file ... has size XX KB

# Verificar que el dump aparece en el repo Borg:
sudo borgmatic list --archive latest --path 'borgmatic/postgresql_databases/postgres-paperless/paperless' 2>&1 \
    | head -5
# Esperado: una línea con el path del dump.
```

### 8.7. Lista de verificación

- [ ] Contenedores `paperless-app`, `postgres-paperless`, `redis-paperless` con estado `healthy`.
- [ ] Permisos: `data/`, `media/`, `consume/`, `export/` en `1000:1000`; `db/data/` en `70:70`; `redis/data/` en `999:999`; `secrets/` en `root:homelab` 600.
- [ ] Ningún puerto publicado al host.
- [ ] `https://paperless.lan/` redirige a `auth.lan` (Authelia activa).
- [ ] `https://paperless.lan/api/` responde 401 sin Authelia interceptar (bypass funciona).
- [ ] Token API generado, app móvil opcional probada.
- [ ] Bootstrap admin desactivado (`PAPERLESS_ADMIN_*` comentadas, `secrets/admin_password` borrado).
- [ ] Subir PDF a `consume/` produce un documento procesado en <60 s.
- [ ] Reboot del stack preserva documentos y configuración.
- [ ] Borgmatic dump del paperless aparece en el archive.
- [ ] `paperless.lan` listado en homepage, prometheus, uptime-kuma, dozzle ya viene precargado de fases anteriores.

---

## 9. Backup

### 9.1. Qué se respalda y qué no

| Path | Categoría | Estrategia | Tamaño esperado |
|---|---|---|---|
| `/mnt/hd2t/services/paperless-ngx/.env` | Config | Borg directo | ~3 KB |
| `/mnt/hd2t/services/paperless-ngx/secrets/{db_password,secret_key}` | Secret | Borg directo | <1 KB c/u |
| `/mnt/hd2t/services/paperless-ngx/data/` | Estado interno | Borg directo (excluye `index/` que es regenerable) | ~10-100 MB |
| `/mnt/hd2t/services/paperless-ngx/media/documents/originals/` | **Crítico irrepetible** | Borg directo | crece con el uso (~1-3 MB/doc) |
| `/mnt/hd2t/services/paperless-ngx/media/documents/archive/` | Crítico regenerable | Borg directo (la dedup lo hace casi gratis) | similar a `originals/` |
| `/mnt/hd2t/services/paperless-ngx/media/thumbnails/` | Caché regenerable | **Excluido** | regenerable con `document_thumbnails` |
| `/mnt/hd2t/services/paperless-ngx/consume/` | Tránsito | **Excluido** | debería estar vacío entre procesados |
| `/mnt/hd2t/services/paperless-ngx/export/` | Salida | **Excluido** | regenerable con `document_exporter`; el contenido ya está cubierto por `media/` + dump |
| BD PostgreSQL | Crítico estructurado | `postgresql_databases:` (dump) | ~5-50 MB |
| `/mnt/hd2t/services/paperless-ngx/db/data/` | Datadir Postgres | **Excluido** (cubierto por dump, no por copia binaria) | — |
| `/mnt/hd2t/services/paperless-ngx/redis/data/` | Cola Celery | **Excluido** | ~10 MB; perderlo solo significa que las tareas pendientes (rara vez >5) tendrán que reprocesarse |

### 9.2. Patrón Borgmatic — respaldo PostgreSQL

Editar `/mnt/hd2t/services/backups/borgmatic/config.yaml` y añadir la entrada `paperless` al bloque `postgresql_databases:` (justo debajo de `nextcloud`, líneas 517–524):

```yaml
postgresql_databases:
  - name: nextcloud
    hostname: postgres-nextcloud
    port: 5432
    username: nextcloud
    password: '{credential file /mnt/hd2t/services/nextcloud/secrets/postgres_password}'
    format: custom
    options: --no-owner --no-privileges
  - name: paperless                                             # <── nuevo
    hostname: postgres-paperless                                # <── nuevo
    port: 5432                                                  # <── nuevo
    username: paperless                                         # <── nuevo
    password: '{credential file /mnt/hd2t/services/paperless-ngx/secrets/db_password}'  # <── nuevo
    format: custom                                              # <── nuevo
    options: --no-owner --no-privileges                         # <── nuevo
```

Y añadir excluciones en `exclude_patterns:`:

```yaml
exclude_patterns:
  # ... entradas existentes ...
  # Paperless: caches y trashunsits regenerables / vacíos.
  - /mnt/hd2t/services/paperless-ngx/media/thumbnails
  - /mnt/hd2t/services/paperless-ngx/data/index
  - /mnt/hd2t/services/paperless-ngx/data/log
  - /mnt/hd2t/services/paperless-ngx/consume
  - /mnt/hd2t/services/paperless-ngx/export
  - /mnt/hd2t/services/paperless-ngx/db/data
  - /mnt/hd2t/services/paperless-ngx/redis/data
```

Validar:

```bash
sudo borgmatic --verbosity 1 --files --dry-run 2>&1 | grep -iE 'paperless|excluded'
```

### 9.3. Restore (resumen)

Caso típico: la BD se ha corrompido (errores de migración tras un upgrade fallido) pero los `originals/` están intactos.

1. **Parar el stack**:
   ```bash
   cd ~/homelab/stacks/paperless
   docker compose down
   ```
2. **Borrar el datadir de Postgres** (vacío para que el contenedor reinicialice):
   ```bash
   sudo rm -rf /mnt/hd2t/services/paperless-ngx/db/data/*
   ```
3. **Levantar solo Postgres + Redis** (paperless aún no — necesita BD lista):
   ```bash
   docker compose up -d postgres broker
   sleep 30
   ```
4. **Restaurar el dump más reciente**:
   ```bash
   sudo borgmatic restore \
       --archive latest \
       --database paperless
   # Borgmatic identifica el hostname `postgres-paperless` (en el config) y
   # llama al pg_restore dentro del contenedor.
   ```
5. **Levantar paperless-app**:
   ```bash
   docker compose up -d paperless-app
   ```
6. **Re-indexar** (los `originals/` están bien, pero el índice Whoosh y el classifier hay que regenerarlos):
   ```bash
   docker exec paperless-app document_index reindex
   docker exec paperless-app document_create_classifier
   docker exec paperless-app document_thumbnails
   ```
7. **Validar**:
   - `https://paperless.lan` muestra los documentos.
   - El número total coincide con el que se recordaba antes del crash.
   - Búsqueda full-text funciona (probar con una palabra conocida).

Caso extremo: pérdida total (incluyendo `originals/`). Restaurar todo el árbol `/mnt/hd2t/services/paperless-ngx/` desde Borg + dump como antes. La BD apunta a paths relativos; los ficheros restaurados en `media/documents/originals/` deben coincidir con las rutas que el dump conoce.

### 9.4. Smoke test mensual

El primer domingo de cada mes (en el script `~/homelab/scripts/monthly-restore-test.sh` rotacional definido en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §11):

```bash
#!/bin/bash
# Mes que toca paperless-ngx en la rotación.

# 1. Restaurar el último dump a un Postgres temporal:
docker run --rm -d --name pg-paperless-test \
    -e POSTGRES_PASSWORD=$(openssl rand -base64 16) \
    postgres:16-alpine
sleep 10

# 2. Extraer el dump del último archive:
sudo borgmatic extract --archive latest \
    --path mnt/hd2t/backups/borg/borgmatic/postgresql_databases/postgres-paperless/paperless \
    --destination /tmp/paperless-restore-test/

# 3. Cargar:
docker cp /tmp/paperless-restore-test/...paperless pg-paperless-test:/tmp/paperless.dump
docker exec pg-paperless-test pg_restore -U postgres -d postgres /tmp/paperless.dump

# 4. Validar: contar documentos:
docker exec pg-paperless-test psql -U postgres -d postgres \
    -c "SELECT count(*) FROM documents_document;"
# Esperado: número similar al de la UI en producción.

# 5. Limpiar:
docker rm -f pg-paperless-test
sudo rm -rf /tmp/paperless-restore-test
```

---

## 10. Operaciones cotidianas

### 10.1. Upgrade manual (Watchtower deshabilitado)

Cada 1-3 meses, el operador revisa releases de paperless-ngx en <https://github.com/paperless-ngx/paperless-ngx/releases>. Procedimiento:

1. **Leer las release notes** de **todos** los minor releases entre el actual y el target. Buscar:
   - "Breaking changes" / "Migrations" → sí ⇒ requiere atención extra.
   - "Reindex required" → sí ⇒ planificar 30-60 min de OCR/reindex tras el upgrade.
   - "Database schema changes" → sí ⇒ dump previo no negociable.
2. **Dump de la BD** (no confiar solo en el Borg de la noche):
   ```bash
   docker exec postgres-paperless pg_dump \
       -U paperless -d paperless \
       --format=custom --no-owner --no-privileges \
       -f /tmp/paperless-pre-upgrade-$(date +%F).dump
   docker cp postgres-paperless:/tmp/paperless-pre-upgrade-$(date +%F).dump \
       /mnt/hd2t/backups/dumps/paperless/
   sudo chown root:root /mnt/hd2t/backups/dumps/paperless/paperless-pre-upgrade-*.dump
   sudo chmod 600 /mnt/hd2t/backups/dumps/paperless/paperless-pre-upgrade-*.dump
   ```
3. **Export portable** (más resistente que el dump si hay un fallo de migración irreversible):
   ```bash
   docker exec paperless-app document_exporter -na -nt -p -d /usr/src/paperless/export
   # Crea /mnt/hd2t/services/paperless-ngx/export/manifest.json y los originals/.
   tar czf /mnt/hd2t/backups/dumps/paperless/export-pre-upgrade-$(date +%F).tar.gz \
       -C /mnt/hd2t/services/paperless-ngx/export .
   ```
4. **Editar `.env.example` y `.env`** con la nueva versión:
   ```bash
   sudo sed -i 's@PAPERLESS_IMAGE=.*@PAPERLESS_IMAGE=ghcr.io/paperless-ngx/paperless-ngx:2.14.0@' \
       /mnt/hd2t/services/paperless-ngx/.env
   sed -i 's@PAPERLESS_IMAGE=.*@PAPERLESS_IMAGE=ghcr.io/paperless-ngx/paperless-ngx:2.14.0@' \
       ~/homelab/stacks/paperless/.env.example
   ```
5. **Pull e iniciar**:
   ```bash
   cd ~/homelab/stacks/paperless
   docker compose --env-file /mnt/hd2t/services/paperless-ngx/.env pull paperless-app
   docker compose --env-file /mnt/hd2t/services/paperless-ngx/.env up -d paperless-app
   docker logs -f paperless-app
   # Buscar: migrations aplicándose, "Index has been rebuilt" si aplica, supervisord listo.
   ```
6. **Validar**:
   ```bash
   docker inspect paperless-app --format '{{.State.Health.Status}}'
   # Esperado: healthy.
   curl -k -s -o /dev/null -w '%{http_code}\n' https://paperless.lan/
   # Esperado: 302 (Authelia redirect, normal).
   ```
7. **Commit** del cambio en `.env.example`:
   ```bash
   cd ~/homelab
   git add stacks/paperless/.env.example
   git commit -m "paperless-ngx: bump 2.13.5 → 2.14.0"
   ```

Si algo falla (la app no sube, errores 500, migraciones bloqueadas):

```bash
# Volver a la versión anterior:
sudo sed -i 's@PAPERLESS_IMAGE=.*@PAPERLESS_IMAGE=ghcr.io/paperless-ngx/paperless-ngx:2.13.5@' \
    /mnt/hd2t/services/paperless-ngx/.env

# Restaurar el dump pre-upgrade:
docker compose down
sudo rm -rf /mnt/hd2t/services/paperless-ngx/db/data/*
docker compose up -d postgres
sleep 15
docker exec -i postgres-paperless pg_restore -U paperless -d paperless \
    < /mnt/hd2t/backups/dumps/paperless/paperless-pre-upgrade-$(date +%F).dump
docker compose up -d
```

### 10.2. Importar documentos masivamente (digitalización del archivo histórico)

```bash
# El operador escanea cajas de papel viejas y obtiene cientos de PDFs.
# Volcar al consume/ con tagging por subdirectorio:

sudo install -d -o 1000 -g 1000 /mnt/hd2t/services/paperless-ngx/consume/historico-2010
sudo cp -r /tmp/escaneos-2010/* /mnt/hd2t/services/paperless-ngx/consume/historico-2010/
sudo chown -R 1000:1000 /mnt/hd2t/services/paperless-ngx/consume/historico-2010

# Paperless procesa 1 cada 30-60 s en Pi 5 con OCR completo.
# Vigilar progreso:
watch 'ls /mnt/hd2t/services/paperless-ngx/consume/historico-2010/ | wc -l'

# Cuando termine, los documentos tendrán tag automático "historico-2010".
```

Para flujos más sofisticados (n8n, escáneres ScanSnap, multifunción HP/Brother con `scan-to-folder` SMB), ver §10.5 (logs) y la documentación oficial de paperless-ngx.

### 10.3. Reentrenar el classifier

Paperless-ngx aprende de los documentos que el operador **corrige manualmente** (cambiar correspondent, añadir tag). Cada noche el job `train-classifier` (cron interno de Celery beat) reentrena con el corpus actual. Forzar manual:

```bash
docker exec paperless-app document_create_classifier
# Esperado:
#   ...processing 123 documents
#   Classifier saved to /usr/src/paperless/data/classification_model.pickle
```

### 10.4. Reset de password (sin SMTP)

```bash
docker exec -it paperless-app python manage.py changepassword <username>
# Pedirá la nueva password 2 veces.
```

### 10.5. Logs y observabilidad

```bash
# Logs del contenedor app (incluye supervisord, web, worker, consumer):
docker logs --tail 100 paperless-app

# Logs Django (más detallados, dentro del bind mount):
sudo tail -f /mnt/hd2t/services/paperless-ngx/data/log/paperless.log

# Logs Celery (worker):
sudo tail -f /mnt/hd2t/services/paperless-ngx/data/log/celery.log

# Logs de Postgres:
docker logs --tail 100 postgres-paperless

# Métricas (CPU/RAM):
docker stats --no-stream paperless-app postgres-paperless redis-paperless
```

Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)) ya tiene `paperless.lan` precargado en la lista (línea 763); cualquier log se ve también vía web en `https://logs.lan`.

Uptime Kuma ([`../05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md)): añadir un monitor `https://paperless.lan/api/` con header `Authorization: Token <TOKEN>` y match-pattern `count` en JSON. Esto valida no solo que el web está vivo sino que el backend Postgres responde.

### 10.6. Mover documentos entre correspondents / etiquetas masivamente

Desde la UI: **Documents** → seleccionar varios con shift-click → **Bulk action** → cambiar tag/correspondent/document_type.

Desde CLI (más rápido para >100 docs):

```bash
docker exec paperless-app python manage.py shell <<'EOF'
from documents.models import Document, Tag
viejo = Tag.objects.get(name='Antiguo')
nuevo = Tag.objects.get(name='Archivo histórico')
docs = Document.objects.filter(tags=viejo)
print(f"Cambiando {docs.count()} documentos de tag '{viejo.name}' a '{nuevo.name}'")
for d in docs:
    d.tags.add(nuevo)
    d.tags.remove(viejo)
    d.save()
EOF
```

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `paperless-app` queda en `restarting` y los logs muestran `connection to server at "postgres" ... failed: FATAL: password authentication failed` | El fichero `secrets/db_password` no coincide con el que Postgres inicializó. Típicamente: se cambió `secrets/db_password` después del primer arranque pero el datadir Postgres ya tenía el hash de la password vieja. | Opción A (preserva datos): `docker exec -it postgres-paperless psql -U postgres -c "ALTER USER paperless PASSWORD '<la nueva del fichero>'"`. Opción B (drástica): `docker compose down && sudo rm -rf .../db/data/* && docker compose up -d` (vacía la BD entera; restaurar dump después). |
| `403 Forbidden — CSRF verification failed` al hacer login | `PAPERLESS_CSRF_TRUSTED_ORIGINS` no incluye `https://paperless.lan` (o el operador accedió por una URL diferente, ej. `https://192.168.1.10`). | Editar `.env`, restart `paperless-app`. |
| Documentos consumidos pero **sin** OCR (texto vacío, no buscables) | Tesseract no tiene el idioma instalado: `OCR_LANGUAGES` está vacío o no incluye el idioma del documento. | Verificar `docker exec paperless-app tesseract --list-langs`. Si falta, editar `.env` con `PAPERLESS_OCR_LANGUAGES="spa eng cat"` y `force-recreate paperless-app` (la imagen instala los paquetes faltantes en arranque). |
| OCR muy lento (>3 min por documento) | OCRmyPDF está aplicando `--clean` con `unpaper` en escaneos enormes (>10 MB) o `THREADS_PER_WORKER` está alto y compite con `WORKERS`. | Bajar `PAPERLESS_TASK_WORKERS=1` durante batch grandes; o desactivar `PAPERLESS_OCR_CLEAN=none` si los escaneos son ya limpios. |
| Apps móviles dan `401 Unauthorized` al conectar | Token regenerado en UI sin actualizar la app, **o** la app está enviando `Token` con prefijo wrong (algunas apps añaden `Bearer` por error). | Regenerar token desde UI, copiar de nuevo. Verificar con curl: `curl -H "Authorization: Token <hex>"` (sin Bearer). |
| Apps móviles dan TLS error / "untrusted certificate" | La CA interna de Caddy no está confiada en el dispositivo móvil. | Instalar CA en el llavero/system store del dispositivo (`../03-red/04-caddy.md` §6.5). En iOS, además, hay que activarla manualmente en Settings → General → About → Certificate Trust Settings. |
| `paperless-app` healthcheck queda permanentemente `unhealthy` aunque la web responde | El `start_period` (120 s) se quedó corto: con `PAPERLESS_OCR_LANGUAGES` largo (5+ idiomas) la instalación puede tardar >2 min. | Editar el `docker-compose.yml`, subir `start_period: 300s`, `up -d --force-recreate`. |
| Los documentos consumidos no aparecen en la UI | El consumer no detecta inotify (problema típico en filesystems `nfs`/`cifs`/`zfs`). En ext4 esto no debería pasar. | Activar polling: `.env` → `PAPERLESS_CONSUMER_POLLING=30`, restart. Esto hace `os.listdir()` cada 30 s en lugar de inotify. |
| Después de un upgrade, los documentos siguen pero la búsqueda da 0 resultados | El índice Whoosh no migró. | `docker exec paperless-app document_index reindex` (tarda 1-5 minutos por cada 1000 documentos). |
| `redis-paperless` se llena (`OOM command not allowed when used memory > 'maxmemory'`) | Una avalancha de tareas Celery (típicamente: importar 1000 documentos a la vez) supera los 128 MB. | Subir `--maxmemory` a `256mb` en el `command:` del compose. Validar que `allkeys-lru` está activo (sí lo está). |
| `403 Forbidden` al subir documento desde la UI por drag&drop | `PAPERLESS_TRUSTED_PROXIES` no contiene la subnet de Caddy. | Verificar `docker network inspect homelab` y poner la subnet exacta en `.env`. |
| `403 CSRF cookie not set` en mobile uploads | La app móvil envía `Origin:` distinto al de Django. | Verificar `CSRF_TRUSTED_ORIGINS` incluye los hosts de la app (LAN + Tailscale). |

---

## 12. Variantes opt-in

### 12.1. SMTP para emails (reset password, notificaciones de workflow)

El homelab no tiene MTA por defecto. Si el operador quiere reset de password por email y notificaciones (`Workflow → Email recipient`), añadir al `.env`:

```dotenv
PAPERLESS_EMAIL_HOST=smtp.smtp2go.com
PAPERLESS_EMAIL_PORT=2525
PAPERLESS_EMAIL_USE_TLS=true
PAPERLESS_EMAIL_HOST_USER=paperless@example.com
PAPERLESS_EMAIL_HOST_PASSWORD_FILE=/run/secrets/smtp_password
PAPERLESS_EMAIL_FROM_ADDRESS=paperless@example.com
PAPERLESS_EMAIL_FROM_NAME=Paperless homelab
```

Crear `secrets/smtp_password` (`chmod 600 root:homelab`) y añadir el bind mount al `docker-compose.yml`.

### 12.2. Apache Tika + Gotenberg (consumir `.docx`, `.odt`, `.eml`)

Añadir al `docker-compose.yml`:

```yaml
  tika:
    image: ghcr.io/paperless-ngx/tika:latest
    container_name: tika-paperless
    hostname: tika
    restart: unless-stopped
    networks:
      - paperless_internal
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    labels:
      com.centurylinklabs.watchtower.enable: "false"

  gotenberg:
    image: docker.io/gotenberg/gotenberg:8
    container_name: gotenberg-paperless
    hostname: gotenberg
    restart: unless-stopped
    command:
      - "gotenberg"
      - "--chromium-disable-javascript=true"
      - "--chromium-allow-list=file:///tmp/.*"
    networks:
      - paperless_internal
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    labels:
      com.centurylinklabs.watchtower.enable: "false"
```

Y en el `.env` descomentar las tres variables `PAPERLESS_TIKA_*` (ya están como template).

Coste: +2 contenedores, +500 MB RAM, +200 MB disk. Beneficio: paperless puede consumir Office/email nativos.

### 12.3. SQLite en lugar de PostgreSQL (no recomendado >500 docs)

Para deploys triviales (1 usuario, <100 documentos, exclusivamente de prueba):

1. Cambiar `PAPERLESS_DBENGINE=sqlite` (eliminar `PAPERLESS_DB*` del `.env`).
2. Eliminar el servicio `postgres` del `docker-compose.yml` y la network `paperless_internal` (no se necesita aislar nada).
3. La BD vivirá en `/mnt/hd2t/services/paperless-ngx/data/db.sqlite3`.
4. Borgmatic: cambiar la entrada `postgresql_databases` por `sqlite_databases: - name: paperless, path: /mnt/hd2t/services/paperless-ngx/data/db.sqlite3`.

Justificado en §0 punto 3: **no recomendado** para uso real.

### 12.4. Email-as-source (consumo automatizado desde IMAP)

Configurar desde la UI: **Settings** → **Mail Accounts** → Add → IMAP host/port/credenciales → **Mail Rules** definen qué mails mover/borrar y qué adjuntos consumir como documentos.

Útil si el operador recibe facturas y extractos por email automáticamente. Las credenciales IMAP se almacenan **cifradas** en BD con `PAPERLESS_SECRET_KEY` (otro motivo para custodiar el `secret_key`).

### 12.5. SSO con Authelia OIDC

Paperless-ngx 2.x soporta OAuth2/OIDC. En lugar del login Django + Authelia (doble login en §6.4), se puede SSO transparente:

1. En Authelia, configurar paperless como **OIDC client** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §X variant).
2. En paperless `.env`:
   ```dotenv
   PAPERLESS_APPS=allauth.socialaccount.providers.openid_connect
   PAPERLESS_SOCIALACCOUNT_PROVIDERS={"openid_connect":{"APPS":[{"provider_id":"authelia","name":"Authelia","client_id":"paperless","secret":"...","settings":{"server_url":"https://auth.lan/api/oidc/.well-known/openid-configuration"}}]}}
   PAPERLESS_DISABLE_REGULAR_LOGIN=true
   ```
3. Caddyfile: **eliminar** `import authelia_proxy` del `handle` por defecto (la auth la hace ahora paperless directamente contra Authelia OIDC; el `forward_auth` rompería el flujo callback OIDC).

Variante avanzada — el operador asume mantenerla.

### 12.6. Watchtower con `pre-update` hook (NO recomendado)

Paperless-ngx tiene migraciones críticas. `pre-update` solo cubriría dump SQL, **no** export portable; un upgrade roto con migración irreversible no se rescata solo con dump si la imagen ya recreó el datadir. **Mejor mantener `enable: "false"`** y upgrade manual (§10.1).

### 12.7. ML acelerado por GPU (descartado en Pi 5)

La Pi 5 no tiene GPU usable para Tesseract/PyTorch. El classifier de paperless es scikit-learn NaiveBayes (CPU-bound, rápido). No aplica.

### 12.8. Almacenamiento OCR en MinIO (S3 backend)

Paperless-ngx soporta `django-storages` con S3 backend (PR #1234). Permite poner `documents/originals/` y `documents/archive/` en MinIO ([`../06-almacenamiento/04-minio.md`](../06-almacenamiento/04-minio.md)). Útil si el operador quiere replicar `originals/` a un MinIO offsite. Variante avanzada; configurar siguiendo el doc oficial de paperless-ngx.

### 12.9. Acceso solo Tailscale (sin LAN)

Si el operador no quiere exponer paperless ni siquiera en la LAN (por motivos de defensa en profundidad: cualquiera con la wifi alcanzaría el portal Authelia):

1. Eliminar el bloque `paperless.{$LAN_DOMAIN}` del Caddyfile.
2. Mantener solo el bloque `paperless.{$TS_DOMAIN}`.
3. Eliminar el registro DNS local en Pi-hole.

El acceso queda restringido a dispositivos del tailnet.

---

## 13. Referencias

- **Paperless-ngx — proyecto y docs**: <https://docs.paperless-ngx.com/>
- **Imagen Docker oficial**: <https://github.com/paperless-ngx/paperless-ngx/pkgs/container/paperless-ngx>
- **Releases**: <https://github.com/paperless-ngx/paperless-ngx/releases>
- **Configuración exhaustiva** (todas las variables `PAPERLESS_*`): <https://docs.paperless-ngx.com/configuration/>
- **REST API v6 (OpenAPI)**: <https://docs.paperless-ngx.com/api/>
- **OCRmyPDF (motor de OCR)**: <https://ocrmypdf.readthedocs.io/>
- **Tesseract (engine OCR)**: <https://tesseract-ocr.github.io/>
- **PostgreSQL 16 — imagen Docker**: <https://hub.docker.com/_/postgres>
- **Redis 7 — imagen Docker**: <https://hub.docker.com/_/redis>
- **Apache Tika (variante §12.2)**: <https://tika.apache.org/>
- **Gotenberg (variante §12.2)**: <https://gotenberg.dev/>
- **Paperless Mobile (Android)**: <https://github.com/astubenbord/paperless-mobile>
- **Paperless (iOS)**: <https://apps.apple.com/app/paperless/id1634910767>
- **Documentos del homelab relacionados**:
  - [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) — el directorio `services/paperless-ngx/` se crea aquí.
  - [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) — convenciones de stacks.
  - [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 — exclusión de Watchtower (línea 458).
  - [`../03-red/02-pihole.md`](../03-red/02-pihole.md) — DNS local `paperless.lan`.
  - [`../03-red/04-caddy.md`](../03-red/04-caddy.md) — reverse proxy + CA interna.
  - [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) — 2FA SSO (regla en línea 422).
  - [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) — ban de fuerza bruta.
  - [`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md) — share opcional sobre `consume/`.
  - [`../06-almacenamiento/04-minio.md`](../06-almacenamiento/04-minio.md) — backend S3 para `originals/`.
  - [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §X — clasificación de datos paperless.
  - [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6 — entrada `postgresql_databases:` y excluciones.
  - [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §2.1 — patrón pg_dump.
  - [`../11-productividad/01-vaultwarden.md`](./01-vaultwarden.md) — custodia de credenciales.
  - [`../11-productividad/02-bookstack.md`](./02-bookstack.md) — patrón Compose con BD relacional.
  - [`../11-productividad/03-linkding.md`](./03-linkding.md) — patrón "no Authelia para `/api/*`".
