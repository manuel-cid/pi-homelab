# Paperless-ngx

## Descripción

Vaultwarden (`01-vaultwarden.md`), Bookstack (`02-bookstack.md`) y Linkding (`03-linkding.md`) cubren respectivamente **secretos**, **conocimiento estructurado** y **marcadores web**. Queda fuera todavía un cuarto pilar de la productividad personal del operador: **el papel**. Facturas de la luz, recibos del banco, contratos del alquiler, justificantes médicos, garantías de electrodomésticos, declaraciones de impuestos, expedientes académicos de los hijos — el papel del hogar acaba siempre en uno de estos sitios:

- Una caja de zapatos en el armario del salón. Búsqueda por O(n), donde n crece sin parar.
- Un escáner barato → carpeta del NAS con ficheros llamados `Documento1.pdf`, `Documento1 (2).pdf`, `IMG_20240315_193412.pdf`. Búsqueda por **fecha del fichero**, no por contenido.
- Un servicio en la nube tipo Evernote, Google Drive o Dropbox con OCR por suscripción. Funciona, pero los documentos personales (DNI, contratos, nóminas) salen del hogar y caen bajo políticas de terceros que cambian con cada renovación de TOS.

Este documento despliega **Paperless-ngx** — sistema de gestión documental autohospedado (Django + PostgreSQL + Redis + workers asíncronos) creado como fork comunitario de Paperless después del abandono del proyecto original. Es la herramienta de referencia del *self-hosting* para "digitalizar el papel del hogar y poder buscarlo como si fuera Gmail". Su rol concreto en el homelab:

1. **Servir la UI** en `https://paperless.${DOMAIN_LAN}/` con TLS terminado en Caddy (CA interna, igual que el resto). Detrás de Caddy, sin `ports:` al host.
2. **Persistir contenido en PostgreSQL** (`paperless-db`, Postgres 16) sobre `hd2t`. Justificación de Postgres (vs SQLite, que sí usaron Vaultwarden y Linkding): Paperless guarda **OCR text** de cada documento (decenas de KiB por PDF) y construye un índice **Whoosh** sobre ese texto; con miles de documentos la BBDD relacional acompaña al índice y SQLite se queda corto en concurrencia (worker OCR + UI + scheduler simultáneos).
3. **OCR multilingüe** vía **OCRmyPDF + Tesseract** (modelos `spa` + `eng` empaquetados en la imagen oficial). Cada PDF que entra por la carpeta de consumo se procesa, se extrae texto, se genera un PDF/A archivable con texto seleccionable encima de la imagen escaneada, y se vuelve indexable.
4. **Carpeta de consumo** en `/mnt/hd2t/apps/paperless/consume/`: cualquier PDF/JPG/PNG/TIFF (y, si Tika está activo, DOCX/ODT/XLSX/EML) que el operador deje ahí desaparece y reaparece como documento en la UI con OCR + tags + correspondiente + tipo, según las **reglas de matching** definidas. Compatible con `scanbd`/escáneres de red, con clientes móviles (Paperless Mobile, Paperless Share) y con `rsync` desde otros equipos del hogar.
5. **Etiquetado automático** vía:
   - Reglas de matching basadas en regex/string sobre el texto OCR.
   - Asignaciones automáticas (auto-matching) que aprenden de los documentos previamente clasificados (Bayes naïve sobre el texto).
6. **Sidecars necesarios**:
   - **Redis** (broker de Celery): cola de tareas asíncronas (OCR, classify, post-process). Datos en RAM con AOF persistente en `hd2t` por si el sistema reinicia con la cola llena.
   - **Gotenberg**: render de PDF de previews para office docs. Usado solo cuando el operador sube `.docx`/`.odt`/`.xlsx` directamente.
   - **Apache Tika**: extracción de texto de office docs antes de pasarlos a OCR. Mismo caso que Gotenberg: opcional pero estándar de facto en el ecosistema Paperless.
7. **Autenticación contra Authelia vía OIDC** (Paperless-ngx ≥ 2.0 soporta OIDC nativamente vía `python-social-auth` con un provider OpenID Connect genérico y el adapter `paperless.auth.PaperlessOpenIDConnectAuthenticationBackend`). Flujo idéntico al de Bookstack y Linkding: redirect a Authelia, claims `sub`, `email`, `name`, sesión Django propia tras autenticar. La cuenta superuser local de Django (creada en bootstrap) queda como fallback.
8. **API REST** estable en `/api/` con autenticación por **token de usuario** (DRF token), generable desde `Settings → Authentication → API Tokens`. Es el canal que usan Paperless Mobile, los scripts de `rsync` que vacían el escáner y los webhooks de tareas (`yt-dlp` no aplica aquí, pero un script de `imapsync` que descarga adjuntos del email a la consume folder, sí).
9. **Respaldarse vía Borgmatic** con el hook nativo `postgresql_databases` (dump SQL del homelab que ya soporta el de Bookstack y similares) más los directorios `media/` y `data/index/` como ficheros.

Lo que este documento **no** decide:

- **Habilitar el connector de email IMAP** (`Settings → Mail`). Paperless puede entrar a un buzón IMAP y descargar adjuntos automáticamente como documentos. Útil para "facturas que llegan al email". Diferido hasta Mailrise (Fase 11) y configuración explícita por buzón; no es viable activarlo aquí porque el homelab todavía no tiene credenciales SMTP/IMAP gestionadas centralmente.
- **Activar reconocimiento facial / clasificación con LLM** (la rama `paperless-ai` o integraciones con servicios de IA externos). Privacidad por defecto: el OCR se hace localmente, las facturas no salen del hogar.
- **Doble carpeta de consumo** (una "raw" del escáner y otra "ya OCRada"). Se documenta una única `consume/` y subdirectorios por origen (`consume/scanner/`, `consume/email/`, `consume/manual/`) que se pueden usar para reglas de matching basadas en la ruta.
- **Migración desde Mayan EDMS, ecoDMS, Docspell, Teedy**. Paperless tiene importer para `paperless-classic` (el proyecto original) pero no para los demás. Si el operador venía de otro DMS, debe exportar a PDFs sueltos y re-ingestarlos por la consume folder.
- **OCR en GPU** (Tesseract acelerado). En la Pi 5 no hay GPU dedicada para esto; la CPU (4× Cortex-A76 a 2.4 GHz) tarda 5–30 s por página dependiendo del idioma y de la complejidad. Aceptable para volumen doméstico (~50 docs/mes).
- **Almacenamiento de adjuntos en S3 / object storage** (`PAPERLESS_FILESYSTEM_STORAGE`). Diferido: el homelab usa filesystem local en hd2t, suficientemente rápido (USB 3.0 + ext4) y respaldable por Borg. Reabrible si el operador quiere reservar hd2t para multimedia y mover Paperless a hd5t.
- **Auto-export periódico** (`PAPERLESS_FILESYSTEM_USE_AUTOEXPORT`). El backup ya cubre disaster recovery; el auto-export es para "tener una copia legible fuera de Paperless" y es redundante con Borg.
- **Multi-tenant familiar** (un Paperless para cada miembro de la familia con BBDD separada). Paperless-ngx soporta usuarios y permisos a nivel de documento, pero no separación física de datos por usuario. Para uso doméstico (operador + pareja, eventualmente hijos) los **permisos por documento** son suficientes (un documento "DNI hijo 1" lo ven solo los padres, una factura del piso la ven ambos).

Cuando este documento se haya aplicado:

- `https://paperless.${DOMAIN_LAN}/` muestra la UI con cert de la CA interna.
- El primer login del operador pasa por Authelia (login + TOTP), Paperless recibe el `id_token` vía OIDC y crea automáticamente su cuenta con permisos de superuser (vía mapeo `PAPERLESS_SOCIAL_AUTO_SIGNUP=True` + flag `PAPERLESS_FIRST_USER_IS_SUPERUSER`).
- La cuenta `admin` local de Django (creada en bootstrap) queda con password aleatorio largo (KeePassXC offline) como contingencia.
- El operador deja un PDF en `/mnt/hd2t/apps/paperless/consume/manual/` y, en menos de 60 s, aparece en la UI con OCR completo (texto seleccionable, búsqueda full-text), tags inferidos por matching y correspondiente asignado.
- Los `media/` (originals + archived PDFs/A) viven en `/mnt/hd2t/apps/paperless/media/`; el índice Whoosh en `/mnt/hd2t/apps/paperless/data/index/`; PostgreSQL en `/mnt/hd2t/apps/paperless/db/`.
- Borgmatic respalda diariamente la BBDD vía `postgresql_databases` (dump SQL puro) y los `media/` + `data/` como ficheros (índice Whoosh **excluido**: es regenerable con `document_index reindex`).
- Uptime Kuma tiene un monitor HTTPS sobre `https://paperless.lan/` con alerta Telegram + email.

> **Recordatorio de alcance**: Paperless es **solo LAN + Tailscale**. **No publica `ports:` al host**, **no se expone a Internet**, **no usa Let's Encrypt**. La app móvil (Paperless Mobile) habla con `https://paperless.lan` directamente cuando el operador está en LAN; vía Tailscale, MagicDNS resuelve el mismo nombre desde fuera de casa. La app debe tener la **CA interna instalada** en el almacén del sistema operativo (Android: Settings → Security → Encryption → Install certificate; iOS: Profile via Apple Configurator).

---

## Requisitos Previos

- **Fase 2** completa: Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN=lan`, `LAN_IP=192.168.1.10`.
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre `paperless.${DOMAIN_LAN}` sin tocar Pi-hole).
  - Caddy con los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` definidos.
- **Fase 4** completa, en particular:
  - Authelia desplegado **con OIDC habilitado**. Paperless consume OIDC nativo (no `forward_auth`); patrón idéntico al de Bookstack y Linkding.
  - El **client OIDC** `paperless` registrado en `configuration.yml` de Authelia (ver "Configuración → 2. Registrar el client OIDC en Authelia").
- **Fase 7** completa: Borgmatic operativo con `homelab.backup=true` como discriminador. La BBDD se respalda vía `postgresql_databases`; los hooks ya soportan Postgres por el patrón de Bookstack-MariaDB extendido al motor Postgres (mismo formato YAML, distinto driver).
- **Operador** con la **CA interna instalada** en navegador (PC + móvil) para que la UI no muestre warning y para que la app móvil de Paperless acepte la conexión TLS sin `--insecure`.
- **Disco `hd2t`** montado en `/mnt/hd2t` con al menos **20 GiB** libres reservados para Paperless (estimación a 5 años):
  - `media/originals/`: ~3 GiB (1500 docs × 2 MiB promedio).
  - `media/archive/`: ~3 GiB (PDFs/A con OCR superpuesto, ligeramente más grandes que el original).
  - `data/index/` (Whoosh): ~500 MiB.
  - `db/` (Postgres): ~1–2 GiB con OCR text de 1500 docs.
  - Margen de crecimiento + dumps + WAL: ~10 GiB.
- Una **`PAPERLESS_SECRET_KEY`** de Django (≥ 64 caracteres aleatorios) generada **una vez** y nunca cambiada: cifra cookies de sesión, CSRF tokens, tokens de email-confirmation. Cambiarla invalida sesiones (no destructivo: los usuarios se relogan vía OIDC).
- Una **`PAPERLESS_DBPASS`** (≥ 24 caracteres, `openssl rand -base64 30`) para el usuario `paperless` de Postgres.
- Una contraseña aleatoria larga para la cuenta `admin` local de Django (creada con `createsuperuser`), anotada en KeePassXC offline.

Comprobaciones rápidas:

```bash
# La red Docker compartida existe
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Caddy y Authelia corriendo
docker ps --filter name=caddy --filter name=authelia --format '{{.Names}} {{.Status}}'

# paperless.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short paperless.lan @192.168.1.2
# 192.168.1.10

# Espacio en hd2t
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'

# Authelia tiene OIDC habilitado
docker exec authelia grep -E '^identity_providers:|^\s+oidc:' /config/configuration.yml | head
```

---

## Decisión: imagen y versión

Paperless-ngx se publica en GitHub Container Registry como `ghcr.io/paperless-ngx/paperless-ngx`, con manifests multi-arch (`amd64`, `arm64`, `armv7`). En la Pi 5 (aarch64) se usa el manifest `arm64`.

| Tag | Cuándo usar | Decisión aquí |
|---|---|---|
| `latest` | Demos, primera prueba. | Descartado (convención de Fase 2: tags exactos). |
| `2` | Major track. | Descartado por la misma razón: avanza con cada minor. |
| `2.18` | Minor track (parcheo de bugs sin migración de schema). | Descartado: prefiero tag exacto para auditoría. |
| `2.18.4` (ejemplo de tag exacto) | Reproducibilidad estricta. | **Aceptado**. |
| `dev` / `nightly` | Builds de desarrollo. | Descartado: rompe sin previo aviso. |

> **Tag exacto en uso**: `ghcr.io/paperless-ngx/paperless-ngx:2.18.4`. Si en el momento de aplicar este documento existe una `2.18.x` superior con changelog limpio (sin migration mayor de Django), se actualiza el tag aquí y en el `docker-compose.yml`, y se anota en el commit. **Nunca `latest`**, **nunca `dev`**.

> **Por qué Paperless-ngx y no Mayan EDMS, Docspell, Teedy o ecoDMS**.
> - **Mayan EDMS**: muy potente (workflows, OCR multimotor, ACL granular) pero pesa ~3 GiB de imagen, requiere RabbitMQ + Postgres + Redis + cuatro workers + nginx. Sobreingeniería para uso doméstico.
> - **Docspell**: Scala/JVM, ligero pero con menos comunidad y plugins; OCR menos pulido (depende de stanford-corenlp para etiquetado).
> - **Teedy / Sismics Docs**: Java, abandonado parcialmente (último release significativo ~2022).
> - **ecoDMS**: comercial, no open source.
> - **Paperless-ngx**: Django + Postgres + Redis + Celery, ~800 MiB de imagen con Tesseract incluido, comunidad activa (>20k stars en GitHub), apps móviles de calidad (Paperless Mobile, Paperless Share), ecosistema de scripts (`paperless-cli`, `paperless-cli-import`), arm64 estable. **Decidido**.

> **Por qué tag exacto y no `2.18`**. Paperless hace migrations de Django + de Whoosh + de filesystem en releases minores. Un tag flotante puede dejar la BBDD a medias si el contenedor cae durante una migration. Con tag exacto las actualizaciones son **deliberadas**: el operador lee el changelog, hace `borgmatic create --tag pre-paperless-upgrade-X.Y.Z`, edita el tag, `up -d`, valida con `document_index status`. Watchtower **deshabilitado** para este stack.

---

## Decisión: cómo se expone Paperless

Paperless ejecuta un proceso `gunicorn` (WSGI) detrás de un nginx interno que sirve estáticos. El contenedor escucha en `:8000` (HTTP plano; el TLS lo termina Caddy delante).

| Opción | Cómo se ve | Discusión |
|---|---|---|
| `network_mode: host` | Paperless ata `:8000` directamente. | Funcionaría, pero rompe la convención del homelab. Descartado. |
| Bridge `homelab` con `ports: ["8000:8000"]` | Acceso directo desde la LAN sin pasar por Caddy. | HTTP plano sin TLS y sin Authelia delante. Las apps móviles cliente se quejan en redes públicas. Descartado. |
| Bridge `homelab` con `expose: 8000`, **sin `ports:`** | Paperless alcanzable solo dentro de la red Docker. Caddy hace `reverse_proxy http://paperless:8000`. | Termina TLS en Caddy con la CA interna. Patrón establecido. **Aceptado**. |

Resultado: `expose: 8000` en el compose (no `ports:`), un drop-in `stacks/caddy/conf.d/43-paperless.caddy` que hace `reverse_proxy http://paperless:8000`, y todo el tráfico externo pasa por `https://paperless.${DOMAIN_LAN}/` con cert de la CA interna.

> **Sobre WebSocket / SSE**. Paperless-ngx **sí** usa WebSocket (`/ws/status/` para empujar el progreso del consume al frontend en tiempo real). El reverse proxy debe **no** romper el upgrade HTTP/1.1 → WebSocket. Caddy lo hace transparentemente con `reverse_proxy` (no requiere `header_up Connection upgrade` en versiones recientes), pero documento explícitamente la directiva por si en debug se desactiva HTTP/2 backend.

> **Sobre el subpath**. Paperless soporta `PAPERLESS_FORCE_SCRIPT_NAME=/paperless` para servirse en un subpath. **No** se usa: la convención es **un subdominio por servicio** (Fase 3), más simple para Authelia (ACLs por host) y Caddy (un bloque por host).

> **Sobre `PAPERLESS_URL`**. El propio Paperless construye URLs absolutas con esta variable (links en emails de tareas, callback OIDC). Debe coincidir con el FQDN externo: `https://paperless.${DOMAIN_LAN}`. Si no se setea, Paperless infiere desde el host de la request, lo que rompe el flujo OIDC con `redirect_uri_mismatch` (igual que Linkding).

---

## Decisión: autenticación — Authelia OIDC + DRF token para API

Paperless tiene tres tipos de cliente:

1. **Navegador humano** sobre la UI web — auth por sesión Django.
2. **App móvil** (Paperless Mobile, Android/iOS) — auth por **DRF token** (cabecera `Authorization: Token <hex>`) o por **basic auth** (deprecada).
3. **Scripts del operador** vía API REST (`rsync` post-hook, `imapsync` que descarga adjuntos) — auth por **DRF token**.

| Componente | Patrón de auth | Justificación |
|---|---|---|
| UI web (`/`, `/documents/`, `/admin/`) | **OIDC contra Authelia** | El operador entra desde un navegador; flujo OIDC interactivo; SSO real con Bookstack y Linkding. |
| API (`/api/documents/`, `/api/tags/`, etc.) | **DRF token** (no OIDC) | La app móvil y los scripts no pueden hacer flujos OAuth interactivos. Token generado **una vez** por usuario en `Settings → Authentication → API Tokens` tras login OIDC. |
| Admin Django (`/admin/`) | **OIDC contra Authelia, política `admins`** | Mismo patrón que Bookstack y Linkding: el flujo OIDC ya pasa por Authelia con `authorization_policy: admins` para `/admin/*`. |

Resultado: `PAPERLESS_APPS=allauth.socialaccount.providers.openid_connect` + `PAPERLESS_SOCIALACCOUNT_PROVIDERS` apuntando a Authelia, registro de un client `paperless` en `configuration.yml` de Authelia con `redirect_uris: ["https://paperless.${DOMAIN_LAN}/accounts/oidc/authelia/login/callback/"]`, y Caddy hace bypass total: el flujo OIDC pasa por Authelia internamente cuando Paperless redirige.

> **Sobre el primer usuario OIDC**. `django-allauth` (que es lo que usa Paperless-ngx 2.x para social auth) crea cuentas con permisos por defecto definidos por `SOCIALACCOUNT_AUTO_SIGNUP=True` + las migrations propias de Paperless. Para promover al primer usuario a superuser, Paperless tiene un setting `PAPERLESS_AUTO_LOGIN_USERNAME` que también se puede usar como "promote-to-superuser-on-first-OIDC-login" si combinamos con un management command — documentado en "Configuración → 4".

> **Sobre la cuenta admin local de Django**. Antes de habilitar OIDC se crea un superuser local con `python manage.py createsuperuser` (sección "Despliegue → 4"). La cuenta sigue existiendo en la BBDD y solo es accesible si se desactiva OIDC (`PAPERLESS_APPS` sin `socialaccount` y restart) — fallback de "Authelia roto". Mismo patrón que Linkding y Bookstack.

> **Sobre el DRF token vs OIDC token**. Cuando el operador entra a la UI vía OIDC y va a `Settings → Authentication → API Tokens`, Paperless genera un token DRF (`rest_framework.authtoken`) ligado a su usuario. Ese token **no expira** y es revocable desde la misma página. Las invocaciones de la app móvil mandan `Authorization: Token <hex>` en la cabecera; **no** pasan por Authelia (es un endpoint API, no UI). La defensa para fuerza bruta sobre `/api/` quedaría a una jail fail2ban — diferida (los tokens DRF son de 40 hex chars aleatorios, ~160 bits de entropía).

---

## Decisión: persistencia y base de datos

Paperless-ngx soporta tres backends: **SQLite**, **MariaDB** y **PostgreSQL**. A diferencia de Linkding (1–5 usuarios, miles de bookmarks) y Bookstack (similar volumen), Paperless tiene un perfil de carga distinto: **escritura intensiva durante OCR**, **full-text search constante**, **muchas tablas relacionales** (documents, tags, correspondents, document_types, custom_fields, custom_field_instances, log).

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| SQLite (`/usr/src/paperless/data/db.sqlite3`) | Cero piezas adicionales, snapshot consistente con `VACUUM INTO`. | OCR worker + scheduler + UI escriben simultáneamente; `database is locked` en cargas medias-altas (>50 docs/mes). El propio README de Paperless-ngx desaconseja SQLite para producción. | Descartado. |
| MariaDB | Misma familia que Bookstack (reuso de imagen, hooks Borg). | Ningún usuario lo usa para Paperless en la comunidad; full-text + collation `utf8mb4` con casos raros. | Descartado por aislar de Bookstack: si MariaDB de Bookstack se cae, no debe arrastrar a Paperless, y viceversa. |
| **PostgreSQL** (`paperless-db`) | Mejor concurrencia, full-text con `GIN` index nativo, comunidad Paperless lo recomienda. Hook `postgresql_databases` de Borgmatic. | Otro contenedor a mantener, otra contraseña, ~120–180 MiB RAM. | **Aceptado**. |

Resultado: PostgreSQL 16 (`postgres:16-alpine`, arm64) en un contenedor dedicado `paperless-db`, BBDD `paperless`, usuario `paperless`. El hook `before_backup` de Borgmatic ejecuta `pg_dump` (de hecho, lo hace el hook nativo `postgresql_databases:` de Borgmatic).

Paperless guarda cuatro tipos de estado:

1. **BBDD relacional** — usuarios, sesiones, documents, tags, correspondents, custom_fields, log, scheduled_tasks. En Postgres (`paperless-db`).
2. **Originales** — `media/documents/originals/<año>/<mes>/<documento>.pdf`. Filesystem.
3. **Archived** — `media/documents/archive/<año>/<mes>/<documento>.pdf` (PDF/A con OCR superpuesto). Filesystem.
4. **Índice Whoosh** — `data/index/` (índice full-text de OCR). Filesystem. **Regenerable** con `document_index reindex` desde la BBDD + los archived; **excluido del backup** para ahorrar tamaño.

| Aspecto | Decisión | Por qué |
|---|---|---|
| BBDD | PostgreSQL 16 dedicada en `/mnt/hd2t/apps/paperless/db/`. | Concurrencia + full-text + recomendación oficial. |
| Originales + archived | Bind mount a `/mnt/hd2t/apps/paperless/media/`. | Datos respaldables como ficheros (no derivables). |
| Consume folder | Bind mount a `/mnt/hd2t/apps/paperless/consume/`. | Volátil — contenido **no** se respalda (Paperless lo borra al consumir). |
| Index Whoosh | Bind mount a `/mnt/hd2t/apps/paperless/data/`. | Regenerable; **excluido** del archive Borg. |
| Configuración | Solo `.env` del compose, versionable (`.env.example`) salvo secretos. | Reproducible desde git + Borg. |
| Snapshot consistente BBDD | `pg_dump` vía hook nativo de Borgmatic. | Atómico, no requiere parar el contenedor. |

> **Por qué no parar el contenedor para hacer backup**. Los OCR pueden tardar minutos en terminar; parar el contenedor cancela tareas Celery a medias y deja documentos en estado "consuming" en la BBDD que el restart resuelve mal. Con `pg_dump` la BBDD queda online y consistente.

> **Sobre `media/` y crecimiento**. Cada PDF original ronda 200 KiB – 5 MiB; el archived suele ser un 10–30 % más grande (capa OCR superpuesta). Con 1500 docs/año (≈4/día), el directorio crece ~3 GiB/año. Reabrir si se acerca al 50 % de hd2t.

---

## Stack: `stacks/paperless/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/paperless/docker-compose.yml` | microSD (git) | Stack (paperless + paperless-db + paperless-redis + gotenberg + tika). |
| `stacks/paperless/.env.example` | microSD (git) | Plantilla con `PAPERLESS_SECRET_KEY`, `PAPERLESS_DBPASS`, `PAPERLESS_OIDC_*`. |
| `stacks/paperless/.env` | microSD (NO git) | Versión rellena con secretos reales. Modo `0600`. |
| `stacks/caddy/conf.d/43-paperless.caddy` | microSD (git) | Drop-in Caddy para `paperless.${DOMAIN_LAN}`. |
| `/mnt/hd2t/apps/paperless/data/` | hd2t | Index Whoosh, classifiers, sessions. Regenerable; **excluido del backup**. |
| `/mnt/hd2t/apps/paperless/media/` | hd2t | Originales + archived PDFs. **Se respalda**. |
| `/mnt/hd2t/apps/paperless/consume/` | hd2t | Carpeta de consumo. Volátil; **no se respalda**. |
| `/mnt/hd2t/apps/paperless/export/` | hd2t | Carpeta de export bajo demanda (`document_exporter`). **Se respalda** si tiene contenido. |
| `/mnt/hd2t/apps/paperless/db/` | hd2t | Datadir de Postgres. **Excluido** del archive (se respalda dump SQL). |
| `/mnt/hd2t/apps/paperless/redis/` | hd2t | AOF de Redis (cola Celery). **Excluido** (regenerable; pérdida = re-procesar tareas en flight). |
| `/mnt/hd2t/apps/paperless/dumps/` | hd2t | `pg_dump` que produce Borgmatic. **Se respalda**. |

### `stacks/paperless/docker-compose.yml`

```yaml
# Paperless-ngx — gestión documental con OCR.
# Convenciones: ver docs/02-docker/02-estructura-compose.md y
# docs/11-productividad/04-paperless-ngx.md.

name: paperless

x-restart: &default-restart
  restart: unless-stopped

services:

  paperless-db:
    image: postgres:16-alpine
    container_name: paperless-db
    hostname: paperless-db
    <<: *default-restart
    environment:
      POSTGRES_DB: paperless
      POSTGRES_USER: paperless
      POSTGRES_PASSWORD: ${PAPERLESS_DBPASS}
      TZ: ${TZ}
    volumes:
      - /mnt/hd2t/apps/paperless/db:/var/lib/postgresql/data
    networks:
      - paperless-internal      # solo paperless-app habla con la BBDD
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U paperless -d paperless || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
    security_opt:
      - "no-new-privileges:true"
    labels:
      homelab.role: "paperless-db"
      homelab.backup: "true"
      com.centurylinklabs.watchtower.enable: "false"

  paperless-redis:
    image: redis:7-alpine
    container_name: paperless-redis
    hostname: paperless-redis
    <<: *default-restart
    command:
      - "redis-server"
      - "--appendonly"
      - "yes"
      - "--save"
      - ""                      # AOF only, no RDB snapshots
    environment:
      TZ: ${TZ}
    volumes:
      - /mnt/hd2t/apps/paperless/redis:/data
    networks:
      - paperless-internal
    healthcheck:
      test: ["CMD-SHELL", "redis-cli ping | grep -q PONG"]
      interval: 30s
      timeout: 5s
      retries: 3
    security_opt:
      - "no-new-privileges:true"
    labels:
      homelab.role: "paperless-broker"
      # No se respalda; AOF es regenerable.
      com.centurylinklabs.watchtower.enable: "false"

  paperless-gotenberg:
    # Render de PDFs preview de office docs. Opcional pero estándar.
    image: gotenberg/gotenberg:8.7.0
    container_name: paperless-gotenberg
    hostname: paperless-gotenberg
    <<: *default-restart
    command:
      - "gotenberg"
      - "--chromium-disable-javascript=true"
      - "--chromium-allow-list=file:///tmp/.*"
    networks:
      - paperless-internal
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:3000/health >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
    security_opt:
      - "no-new-privileges:true"
    labels:
      homelab.role: "paperless-gotenberg"
      com.centurylinklabs.watchtower.enable: "false"

  paperless-tika:
    # Extracción de texto de office docs antes de OCR.
    image: apache/tika:2.9.2.1-full
    container_name: paperless-tika
    hostname: paperless-tika
    <<: *default-restart
    networks:
      - paperless-internal
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://127.0.0.1:9998/tika >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
    security_opt:
      - "no-new-privileges:true"
    labels:
      homelab.role: "paperless-tika"
      com.centurylinklabs.watchtower.enable: "false"

  paperless:
    image: ghcr.io/paperless-ngx/paperless-ngx:2.18.4
    container_name: paperless
    hostname: paperless
    <<: *default-restart
    depends_on:
      paperless-db:
        condition: service_healthy
      paperless-redis:
        condition: service_healthy
      paperless-gotenberg:
        condition: service_healthy
      paperless-tika:
        condition: service_healthy

    environment:
      # Usuarios: Paperless-ngx respeta PUID/PGID (estilo LSIO), pero internamente
      # corre la mayoría como `paperless` (1000). Mantenemos 1000:1000 para que el
      # ownership de los bind mounts encaje con el del operador.
      USERMAP_UID: ${PUID}
      USERMAP_GID: ${PGID}
      TZ: ${TZ}

      # URL canónica externa. CRÍTICO: callback OIDC se construye desde aquí.
      PAPERLESS_URL: https://paperless.${DOMAIN_LAN}
      PAPERLESS_CSRF_TRUSTED_ORIGINS: https://paperless.${DOMAIN_LAN}
      PAPERLESS_ALLOWED_HOSTS: paperless.${DOMAIN_LAN},paperless,localhost
      PAPERLESS_CORS_ALLOWED_HOSTS: https://paperless.${DOMAIN_LAN}
      PAPERLESS_TRUSTED_PROXIES: 172.30.10.0/24

      # Clave secreta de Django (ver Requisitos).
      PAPERLESS_SECRET_KEY: ${PAPERLESS_SECRET_KEY}

      # BBDD
      PAPERLESS_DBENGINE: postgresql
      PAPERLESS_DBHOST: paperless-db
      PAPERLESS_DBPORT: "5432"
      PAPERLESS_DBNAME: paperless
      PAPERLESS_DBUSER: paperless
      PAPERLESS_DBPASS: ${PAPERLESS_DBPASS}

      # Broker
      PAPERLESS_REDIS: redis://paperless-redis:6379

      # Sidecars
      PAPERLESS_TIKA_ENABLED: "true"
      PAPERLESS_TIKA_ENDPOINT: http://paperless-tika:9998
      PAPERLESS_TIKA_GOTENBERG_ENDPOINT: http://paperless-gotenberg:3000

      # OCR — idiomas instalados en la imagen oficial (ver "Decisión: OCR").
      PAPERLESS_OCR_LANGUAGE: spa+eng
      PAPERLESS_OCR_LANGUAGES: spa eng                  # paquetes a instalar al arranque
      PAPERLESS_OCR_MODE: skip                          # skip si ya tiene capa de texto
      PAPERLESS_OCR_CLEAN: clean
      PAPERLESS_OCR_DESKEW: "true"
      PAPERLESS_OCR_ROTATE_PAGES: "true"
      PAPERLESS_OCR_OUTPUT_TYPE: pdfa                   # archived = PDF/A
      PAPERLESS_OCR_USER_ARGS: '{"invalidate_digital_signatures": true}'
      PAPERLESS_OCR_THREADS_PER_WORKER: "2"

      # Workers Celery — ajuste para Pi 5 (4 cores).
      PAPERLESS_TASK_WORKERS: "1"
      PAPERLESS_THREADS_PER_WORKER: "2"

      # Consume folder
      PAPERLESS_CONSUMER_POLLING: "0"                   # inotify (eficiente)
      PAPERLESS_CONSUMER_RECURSIVE: "true"
      PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS: "true"        # consume/scanner/* → tag "scanner"
      PAPERLESS_CONSUMER_DELETE_DUPLICATES: "true"
      PAPERLESS_CONSUMER_BARCODE_ENABLE: "true"         # split por barcode si el escáner los inserta

      # Tiempo
      PAPERLESS_TIME_ZONE: ${TZ}
      PAPERLESS_FILENAME_FORMAT: "{created_year}/{correspondent}/{title}"

      # Auth — OIDC contra Authelia (allauth + provider openid_connect).
      # Durante bootstrap se deja sin OIDC para crear el superuser local;
      # se activa tras registrar el client en Authelia (ver "Configuración → 3").
      PAPERLESS_APPS: allauth.socialaccount.providers.openid_connect
      PAPERLESS_DISABLE_REGULAR_LOGIN: "false"          # mantener login local como fallback
      PAPERLESS_REDIRECT_LOGIN_TO_SSO: ${PAPERLESS_REDIRECT_LOGIN_TO_SSO:-false}
      PAPERLESS_ACCOUNT_DEFAULT_HTTP_PROTOCOL: https
      PAPERLESS_SOCIALACCOUNT_PROVIDERS: |
        {
          "openid_connect": {
            "APPS": [
              {
                "provider_id": "authelia",
                "name": "Authelia",
                "client_id": "paperless",
                "secret": "${PAPERLESS_OIDC_CLIENT_SECRET}",
                "settings": {
                  "server_url": "https://auth.${DOMAIN_LAN}/.well-known/openid-configuration",
                  "token_auth_method": "client_secret_basic"
                }
              }
            ]
          }
        }

      # Logs
      PAPERLESS_LOGGING_DIR: /usr/src/paperless/data/log

    networks:
      - homelab               # Caddy llega por aquí
      - paperless-internal    # Postgres / Redis / Tika / Gotenberg

    expose:
      - "8000"
    # NO `ports:`. Acceso solo vía Caddy.

    volumes:
      - /mnt/hd2t/apps/paperless/data:/usr/src/paperless/data
      - /mnt/hd2t/apps/paperless/media:/usr/src/paperless/media
      - /mnt/hd2t/apps/paperless/export:/usr/src/paperless/export
      - /mnt/hd2t/apps/paperless/consume:/usr/src/paperless/consume

    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:8000/api/ >/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s

    security_opt:
      - "no-new-privileges:true"

    labels:
      homelab.role: "documents"
      homelab.backup: "true"
      com.centurylinklabs.watchtower.enable: "false"

networks:
  homelab:
    external: true
  paperless-internal:
    name: paperless-internal
    driver: bridge
    internal: true            # sin ruta a internet ni al host
    ipam:
      config:
        - subnet: 172.30.42.0/29
```

> **Sobre `paperless-internal`**. Es una red **interna** (sin gateway), aislada del bridge `homelab`. Postgres, Redis, Tika y Gotenberg solo se exponen al contenedor `paperless` y entre ellos. No hay forma de hablar con la BBDD desde Caddy o desde otros stacks por accidente. La superficie pública es exclusivamente `paperless:8000` que Caddy alcanza por la red `homelab`.

> **Sobre el `start_period: 90s` de Paperless**. El primer arranque ejecuta migrations Django, creación del schema en Postgres, descarga de modelos Tesseract si faltan, y `document_index sanity_check`. En la Pi 5 esto tarda 60–80 s. Si el periodo es más corto, Compose marca el contenedor como unhealthy antes de tiempo y `restart: unless-stopped` entra en bucle.

### `stacks/paperless/.env.example`

```bash
# stacks/paperless/.env.example
# Variables específicas del stack Paperless. Las generales (TZ, PUID, PGID,
# DOMAIN_LAN) viven en el .env GLOBAL.

# Clave secreta de Django. Generar UNA VEZ:
#   docker run --rm ghcr.io/paperless-ngx/paperless-ngx:2.18.4 \
#     python -c "import secrets; print(secrets.token_urlsafe(64))"
# CAMBIARLA INVALIDA SESIONES Y CSRF TOKENS.
PAPERLESS_SECRET_KEY=CHANGEME_GENERATE_64_BYTES_TOKEN_URLSAFE

# Password del usuario `paperless` de Postgres.
#   openssl rand -base64 30
PAPERLESS_DBPASS=CHANGEME_RANDOM_30_BASE64

# OIDC — secret del client `paperless` registrado en Authelia (paso 2 de Configuración).
# CLARO (no hash); django-allauth lo usa solo en memoria.
PAPERLESS_OIDC_CLIENT_SECRET=CHANGEME_DEL_CLIENT_REGISTRADO_EN_AUTHELIA

# Cuando todo el flujo OIDC esté validado, ponerlo a true para que /accounts/login/
# redirija directamente a Authelia. Mantener false durante bootstrap.
PAPERLESS_REDIRECT_LOGIN_TO_SSO=false
```

### `stacks/caddy/conf.d/43-paperless.caddy`

```caddy
# /etc/caddy/conf.d/43-paperless.caddy — bloque LAN para Paperless-ngx.
# UI + API + endpoints OIDC en http://paperless:8000 dentro de `homelab`.
# Auth UI: OIDC contra Authelia (no forward_auth).
# Auth API: DRF token (cabecera Authorization: Token <hex>).
# Documentado en docs/11-productividad/04-paperless-ngx.md.

paperless.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Subida de documentos puede ser grande (multifoto escaneado, lote
    # mensual). Paperless internamente acepta hasta 100 MiB; ajustar Caddy
    # para no truncar antes.
    request_body {
        max_size 100MB
    }

    reverse_proxy http://paperless:8000 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}

        # WebSocket /ws/status/ (progreso del consume en vivo): Caddy lo
        # gestiona automáticamente, pero documento la directiva por claridad.
        flush_interval -1
    }
}
```

> **Sobre `request_body max_size`**. Sin esta directiva, Caddy aplica el límite por defecto (10 MiB) y subir un escaneado a alta resolución de un contrato de 30 páginas (~30 MiB) falla con `413 Request Entity Too Large`. 100 MiB cubre el 99 % del caso de uso doméstico.

### Crear los directorios persistentes y desplegar

```bash
# 0) Asegurar el árbol de datos en hd2t (idempotente)
sudo install -d -o root  -g root  -m 0755 /mnt/hd2t/apps/paperless

# Postgres tiene su propio UID interno (70 en alpine, 999 en debian-based).
# La imagen postgres:16-alpine corre como UID 70.
sudo install -d -o 70    -g 70    -m 0700 /mnt/hd2t/apps/paperless/db

# Redis alpine corre como UID 999.
sudo install -d -o 999   -g 999   -m 0700 /mnt/hd2t/apps/paperless/redis

# Paperless app respeta PUID/PGID = 1000:1000.
sudo install -d -o 1000  -g 1000  -m 0750 /mnt/hd2t/apps/paperless/data
sudo install -d -o 1000  -g 1000  -m 0750 /mnt/hd2t/apps/paperless/media
sudo install -d -o 1000  -g 1000  -m 0775 /mnt/hd2t/apps/paperless/consume
sudo install -d -o 1000  -g 1000  -m 0750 /mnt/hd2t/apps/paperless/export

# Subdirs de consume/ que se mapean a tags (PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS).
sudo -u "#1000" install -d /mnt/hd2t/apps/paperless/consume/scanner
sudo -u "#1000" install -d /mnt/hd2t/apps/paperless/consume/email
sudo -u "#1000" install -d /mnt/hd2t/apps/paperless/consume/manual

# Para el dump SQL (lo escribe el hook nativo de Borgmatic; root en el host).
sudo install -d -o root -g root -m 0700 /mnt/hd2t/apps/paperless/dumps

# 1) Generar PAPERLESS_SECRET_KEY (UNA SOLA VEZ)
docker run --rm ghcr.io/paperless-ngx/paperless-ngx:2.18.4 \
    python -c "import secrets; print(secrets.token_urlsafe(64))"

# 2) Generar PAPERLESS_DBPASS (UNA SOLA VEZ)
openssl rand -base64 30

# 3) Materializar stacks/paperless/.env
cd /home/homelab/homelab
set -a; source .env; set +a

cp stacks/paperless/.env.example stacks/paperless/.env
chmod 0600 stacks/paperless/.env
# Editar: pegar PAPERLESS_SECRET_KEY, PAPERLESS_DBPASS, dejar
# PAPERLESS_OIDC_CLIENT_SECRET vacío de momento, REDIRECT_LOGIN_TO_SSO=false.

# 4) Drop-in de Caddy
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/43-paperless.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/43-paperless.caddy

# 5) Validar el Caddyfile
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
# Successful

# 6) Validar el compose
docker compose \
    -f stacks/paperless/docker-compose.yml \
    --env-file stacks/paperless/.env \
    config >/dev/null && echo "compose OK"

# 7) Levantar el stack (Postgres + Redis + Tika + Gotenberg + Paperless)
docker compose \
    -f stacks/paperless/docker-compose.yml \
    --env-file stacks/paperless/.env \
    up -d

# 8) Recargar Caddy
docker kill --signal=SIGUSR1 caddy
```

Tras `up -d`:

```bash
docker ps --filter name=paperless --format 'table {{.Names}}\t{{.Status}}'
# paperless-db          Up 2 minutes (healthy)
# paperless-redis       Up 2 minutes (healthy)
# paperless-tika        Up 2 minutes (healthy)
# paperless-gotenberg   Up 2 minutes (healthy)
# paperless             Up 1 minute (healthy)

# Logs de migrations (primer arranque)
docker logs paperless 2>&1 | grep -E 'Applying|migrated|server is now' | head
# Operations to perform: Apply all migrations: ...
# Applying contenttypes.0001_initial... OK
# ... (decenas de migrations)
# Paperless-ngx server is now running
```

Si el contenedor `paperless` no llega a `(healthy)` en 2–3 minutos, lo más probable es:
- `PAPERLESS_DBPASS` mal pegado en `.env`: logs muestran `password authentication failed for user "paperless"`.
- UID 70 sin acceso a `/mnt/hd2t/apps/paperless/db/`: `chown: changing ownership: Permission denied` en logs de `paperless-db`.
- Disco hd2t lleno.
- `paperless-tika` o `paperless-gotenberg` no llegan a healthy en 90 s y Paperless aborta el `depends_on`.

Comprobación de extremo a extremo:

```bash
# UI responde 200 con la página de login
curl -skI https://paperless.lan/accounts/login/
# HTTP/2 200

# API responde 200 (login no requerido para listar el schema)
curl -skI https://paperless.lan/api/
# HTTP/2 200
```

---

## Configuración

### 1) Bootstrap: superuser local de Django (fallback)

Con `PAPERLESS_REDIRECT_LOGIN_TO_SSO=false` y antes de configurar OIDC, crear el superuser local **una vez**. Es la cuenta de contingencia para "Authelia roto":

```bash
docker exec -it paperless python manage.py createsuperuser
# Username: admin-local
# Email address: admin-local@homelab.lan
# Password: <pegar uno aleatorio largo: openssl rand -base64 30>
# Password (again): <repetir>
# Superuser created successfully.
```

Anotar `admin-local` + password **solo** en KeePassXC offline. Esta cuenta no se usa día a día.

### 2) Registrar el client OIDC `paperless` en Authelia

En `/mnt/hd2t/apps/authelia/config/configuration.yml`, dentro de `identity_providers.oidc.clients`, añadir el bloque:

```yaml
identity_providers:
  oidc:
    # ... hmac_secret, issuer_private_key (ya definidos en 04-seguridad/01-authelia.md)
    clients:
      # ... otros clients existentes (bookstack, linkding, ...)
      - client_id: paperless
        client_name: Paperless-ngx
        # Generar:
        #   docker run --rm authelia/authelia:4.38.10 \
        #     authelia crypto hash generate pbkdf2 --variant sha512 \
        #     --random --random.length 64 --random.charset rfc3986
        # Apuntar el "Random" (claro) en stacks/paperless/.env
        # como PAPERLESS_OIDC_CLIENT_SECRET y el "Digest" (hash) aquí.
        client_secret: '$pbkdf2-sha512$310000$<hash-del-secret>'
        public: false
        authorization_policy: two_factor
        redirect_uris:
          - https://paperless.lan/accounts/oidc/authelia/login/callback/
        scopes:
          - openid
          - profile
          - email
        userinfo_signed_response_alg: none
        token_endpoint_auth_method: client_secret_basic
        consent_mode: implicit
```

Recargar Authelia:

```bash
docker compose -f /home/homelab/homelab/stacks/authelia/docker-compose.yml \
    up -d --force-recreate
docker logs authelia 2>&1 | grep 'client_id=paperless' | tail
# expected: "Provider: registered client" client_id=paperless
```

> **Sobre la barra final del `redirect_uri`**. django-allauth usa `path('accounts/oidc/<provider_id>/login/callback/', ...)` con barra final. Authelia es estricto: si la URL en `redirect_uris` no coincide carácter a carácter (incluida la barra), Authelia rechaza con `redirect_uri_mismatch`.

### 3) Activar OIDC en Paperless

Editar `stacks/paperless/.env` y pegar el secret claro generado en el paso 2:

```bash
sed -i 's|^PAPERLESS_OIDC_CLIENT_SECRET=.*|PAPERLESS_OIDC_CLIENT_SECRET=PEGA_EL_RANDOM_DEL_PASO_2|' \
    stacks/paperless/.env

docker compose -f stacks/paperless/docker-compose.yml \
    --env-file stacks/paperless/.env \
    up -d --force-recreate paperless
```

Tras el restart, `https://paperless.lan/accounts/login/` muestra ahora el botón "Sign In via Authelia" (junto al formulario de login local). Pulsar el botón redirige a `https://auth.lan/?rd=...`, Authelia pide TOTP (política `two_factor`) y devuelve el `id_token`. django-allauth crea automáticamente la cuenta del operador.

Verificar:

```bash
docker exec paperless python manage.py shell -c \
    "from django.contrib.auth import get_user_model; \
     U=get_user_model(); \
     [print(u.username, u.is_superuser) for u in U.objects.all()]"
# admin-local True
# operator    False    ← OIDC creado, todavía sin superuser
```

### 4) Promover al usuario OIDC a superuser

django-allauth no ejecuta el bit "first user is superuser" automáticamente. Promover manualmente la cuenta del operador (una sola vez):

```bash
docker exec paperless python manage.py shell -c \
    "from django.contrib.auth import get_user_model; \
     u=get_user_model().objects.get(username='operator'); \
     u.is_superuser=True; u.is_staff=True; u.save(); \
     print('promoted', u.username)"
# promoted operator
```

A partir de ahora la familia que entre por OIDC quedará como usuarios normales (no-staff); el operador puede ascender en `https://paperless.lan/admin/auth/user/` cuando lo necesite.

### 5) Forzar el flujo SSO por defecto (opcional, recomendado tras validar)

Una vez confirmado que el operador y la familia entran sin fricción vía Authelia, redirigir `/accounts/login/` directamente a SSO para esconder el formulario local:

```bash
sed -i 's/^PAPERLESS_REDIRECT_LOGIN_TO_SSO=.*/PAPERLESS_REDIRECT_LOGIN_TO_SSO=true/' \
    stacks/paperless/.env

docker compose -f stacks/paperless/docker-compose.yml \
    --env-file stacks/paperless/.env \
    up -d --force-recreate paperless
```

El formulario local sigue siendo accesible en `https://paperless.lan/accounts/login/?next=/admin/` con `PAPERLESS_DISABLE_REGULAR_LOGIN=false` (mantenido como `false` para fallback).

### 6) Configurar la consume folder y subdirectorios como tags

La estructura `consume/{scanner,email,manual}/` con `PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS=true` hace que cualquier PDF dejado en `consume/scanner/` se ingiera con un tag automático `scanner`. El operador define los tags raíz una sola vez en la UI:

1. **Settings → Tags → Add Tag** → `scanner` (color azul).
2. **Settings → Tags → Add Tag** → `email` (color verde).
3. **Settings → Tags → Add Tag** → `manual` (color gris).

Con `PAPERLESS_CONSUMER_BARCODE_ENABLE=true`, además, si el escáner inserta una hoja con un barcode tipo `PATCHT` entre dos documentos, Paperless **divide** el escaneado en dos archivos (útil para escanear un fajo de facturas como un solo PDF).

### 7) Reglas de matching y correspondents

Paperless intenta clasificar automáticamente cada documento en:
- **Correspondent** (quién emitió el documento — "Iberdrola", "Banco Santander", "Tienda XYZ").
- **Document Type** ("Factura", "Contrato", "Recibo", "Nómina").
- **Tags** ("luz", "gas", "alquiler", "salud").

Cada uno tiene un campo "matching algorithm" en su admin:

| Algoritmo | Cuándo usar |
|---|---|
| `Exact match` | El nombre del correspondent aparece literalmente en el documento ("Iberdrola"). |
| `Any word` | Cualquiera de las palabras del nombre aparece. |
| `All words` | Todas las palabras aparecen, en cualquier orden. |
| `Regular expression` | Patrones complejos (ej. número de cliente). |
| `Auto-matching` | Bayes naïve: aprende de los documentos asignados manualmente. **Recomendado** una vez se tienen 5–10 ejemplos por categoría. |

Workflow recomendado:
1. **Primer mes**: clasificar manualmente cada documento que entra (asignar correspondent, doc type, tags). Coste: ~30 s/documento.
2. **Segundo mes**: poner cada categoría en `Auto-matching`. Paperless empieza a sugerir asignaciones; el operador acepta/corrige.
3. **A partir del tercer mes**: ~80 % de los documentos llegan ya clasificados; el operador solo revisa los `inbox-pending`.

### 8) Custom Fields para datos específicos del hogar

Útiles para "tracking" más allá del título: importes de facturas, fechas de vencimiento, números de contrato. Definir desde `Settings → Custom Fields`:

| Field | Tipo | Aplicado a |
|---|---|---|
| Importe | Monetary | Facturas. |
| Fecha vencimiento | Date | Garantías, contratos. |
| Número de contrato | String | Contratos, suministros. |
| Producto | String | Garantías de electrodomésticos. |

Con custom fields rellenados, la búsqueda full-text de Paperless permite consultas como `tag:luz importe:>100` (vía la UI de búsqueda avanzada) — útil para el cierre fiscal anual.

### 9) Integrar el dump Postgres en Borgmatic

Borgmatic soporta `postgresql_databases` nativamente. En `/etc/borgmatic.d/borgmatic.yaml` añadir/extender:

```yaml
postgresql_databases:
  # ... (otras BBDD que pueda haber, p.ej. bookstack si fuera Postgres)
  - name: paperless
    hostname: paperless-db
    port: 5432
    username: paperless
    password: ${PAPERLESS_DBPASS}                   # via env-file en el systemd unit
    format: custom                                  # pg_dump -Fc, comprimido + restorable
    options: "--clean --if-exists"
```

Y asegurar que `media/`, `export/` y `dumps/` están en `source_directories` (Borg respalda **los ficheros**, el dump SQL lo gestiona el hook nativo):

```yaml
source_directories:
  - /home/homelab/homelab
  - /mnt/hd2t/apps/paperless/media
  - /mnt/hd2t/apps/paperless/export
  # /mnt/hd2t/apps/paperless/dumps lo escribe el propio Borgmatic.

exclude_patterns:
  - '/mnt/hd2t/apps/paperless/data/index'           # Whoosh: regenerable.
  - '/mnt/hd2t/apps/paperless/data/log'             # logs: ruidosos.
  - '/mnt/hd2t/apps/paperless/db'                   # datadir Postgres: usar dump.
  - '/mnt/hd2t/apps/paperless/redis'                # AOF Celery: regenerable.
  - '/mnt/hd2t/apps/paperless/consume'              # volátil; lo borra el consumer.
```

Verificar:

```bash
sudo borgmatic config validate
# All configs valid

# Test del hook nativo: dry-run que invoca pg_dump y borra el dump tras el archive
sudo borgmatic create --dry-run --list 2>&1 | grep -i paperless
```

### 10) Monitor en Uptime Kuma

En `https://uptime.${DOMAIN_LAN}/` añadir un **monitor HTTP(s)**:

| Campo | Valor |
|---|---|
| Friendly Name | `Paperless` |
| URL | `https://paperless.lan/api/` |
| Heartbeat Interval | 60 s |
| Retries | 3 |
| Accepted Status Codes | 200 |
| Notification | Telegram + email (Mailrise cuando exista) |
| Public on status page | Sí |

`/api/` responde 200 sin auth (devuelve el schema OpenAPI público de DRF). Es el equivalente a `/health` de Linkding y `/status` de Bookstack para health checks externos.

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/paperless/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/paperless/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla versionada. |
| `/home/homelab/homelab/stacks/paperless/.env` | microSD | `homelab:homelab` | `0600` | `PAPERLESS_SECRET_KEY`, `PAPERLESS_DBPASS`, `PAPERLESS_OIDC_CLIENT_SECRET`. **No** versionado. |
| `/home/homelab/homelab/stacks/caddy/conf.d/43-paperless.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in Caddy. **Versionado**. |
| `/mnt/hd2t/apps/caddy/etc/conf.d/43-paperless.caddy` | hd2t | `homelab:homelab` | `0644` | Drop-in materializado. |
| `/mnt/hd2t/apps/paperless/db/` | hd2t | `70:70` | `0700` | Datadir Postgres. **Excluido** del archive (se respalda dump SQL vía `postgresql_databases`). |
| `/mnt/hd2t/apps/paperless/redis/` | hd2t | `999:999` | `0700` | AOF Redis (cola Celery). **Excluido** (regenerable). |
| `/mnt/hd2t/apps/paperless/data/index/` | hd2t | `1000:1000` | `0750` | Índice Whoosh. **Excluido** (regenerable con `document_index reindex`). |
| `/mnt/hd2t/apps/paperless/data/log/` | hd2t | `1000:1000` | `0750` | Logs aplicación. **Excluido**. |
| `/mnt/hd2t/apps/paperless/data/classifier.pickle` | hd2t | `1000:1000` | `0640` | Modelo Bayes naïve para auto-matching. **Incluido** en el archive (regenerable pero costoso). |
| `/mnt/hd2t/apps/paperless/media/documents/originals/` | hd2t | `1000:1000` | `0750` | Originales sin tocar. **Sí se respalda** (T1). |
| `/mnt/hd2t/apps/paperless/media/documents/archive/` | hd2t | `1000:1000` | `0750` | PDFs/A con OCR superpuesto. **Sí se respalda** (T1, redundancia con originals + dump). |
| `/mnt/hd2t/apps/paperless/media/documents/thumbnails/` | hd2t | `1000:1000` | `0750` | Miniaturas pequeñas. **Sí se respalda** (T2; regenerables pero baratas). |
| `/mnt/hd2t/apps/paperless/consume/` | hd2t | `1000:1000` | `0775` | Carpeta de entrada. Volátil (Paperless borra al consumir). **No se respalda**. |
| `/mnt/hd2t/apps/paperless/export/` | hd2t | `1000:1000` | `0750` | Exportaciones a demanda con `document_exporter`. **Sí se respalda** si tiene contenido. |
| `/mnt/hd2t/apps/paperless/dumps/` | hd2t | `root:root` | `0700` | `pg_dump -Fc paperless` que produce Borgmatic. **Sí se respalda** (T1). |

> **Tamaño esperado a 5 años (1500 docs/año, ≈4/día)**:
> - `media/originals/`: 15 GiB (7500 docs × 2 MiB).
> - `media/archive/`: 18 GiB (PDFs/A ~20 % más grandes).
> - `media/thumbnails/`: ~150 MiB.
> - `data/index/`: 2–3 GiB.
> - `db/` Postgres: ~3 GiB con OCR text.
> - Total: ~40 GiB.

> **Sobre los UIDs heterogéneos**. Postgres corre como UID 70 (alpine), Redis como 999, Paperless como 1000. Tres dueños distintos en `/mnt/hd2t/apps/paperless/`. No hay conflicto porque cada uno tiene su subdirectorio aislado. Documentado consistentemente con el resto de stacks ("Tabla de UIDs por servicio" en `01-sistema/04-estructura-directorios.md`).

---

## Backup

A nivel del repositorio del homelab:

| Artefacto | Estrategia |
|---|---|
| `stacks/paperless/docker-compose.yml`, `.env.example` | Versionados en git. Reproducibles tras un reflasheo. |
| `stacks/caddy/conf.d/43-paperless.caddy` | Versionado en git. |
| `stacks/paperless/.env` (con `PAPERLESS_SECRET_KEY`, `PAPERLESS_DBPASS`, `PAPERLESS_OIDC_CLIENT_SECRET` reales) | **No** versionado. Respaldado por Borg como parte de `/home/homelab/homelab/`. |
| Decisiones (Postgres, OIDC allauth, OCR `spa+eng`, Tika+Gotenberg activados) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | Tier | ¿Se respalda? | Por qué |
|---|---|---|---|
| `/mnt/hd2t/apps/paperless/dumps/<archive>.psql` | T1 | **Sí** (vía `postgresql_databases:` nativo) | Dump consistente, comprimido (`-Fc`). Fuente de verdad para restore relacional. |
| `/mnt/hd2t/apps/paperless/media/` | T1 | **Sí** | Originales + archived. **No** son derivables (los originales son la fuente). |
| `/mnt/hd2t/apps/paperless/export/` | T2 | **Sí** | Solo si el operador hace export manual con `document_exporter`. |
| `/mnt/hd2t/apps/paperless/data/classifier.pickle` | T2 | **Sí** | Modelo Bayes; regenerable (`document_create_classifier`) pero ahorra entrenamiento tras restore. |
| `/mnt/hd2t/apps/paperless/data/index/` | — | **Excluido** | Whoosh; regenerable con `document_index reindex` desde la BBDD + media. |
| `/mnt/hd2t/apps/paperless/db/` | — | **Excluido** | Datadir Postgres; usar dump. |
| `/mnt/hd2t/apps/paperless/redis/` | — | **Excluido** | AOF Celery; pérdida = re-procesar tareas en flight. |
| `/mnt/hd2t/apps/paperless/consume/` | — | **Excluido** | Volátil. |

Patrón en `borgmatic.yaml`:

```yaml
source_directories:
  - /home/homelab/homelab
  - /mnt/hd2t/apps/paperless/media
  - /mnt/hd2t/apps/paperless/export
  - /mnt/hd2t/apps/paperless/data/classifier.pickle

exclude_patterns:
  - '/mnt/hd2t/apps/paperless/data/index'
  - '/mnt/hd2t/apps/paperless/data/log'
  - '/mnt/hd2t/apps/paperless/db'
  - '/mnt/hd2t/apps/paperless/redis'
  - '/mnt/hd2t/apps/paperless/consume'

postgresql_databases:
  - name: paperless
    hostname: paperless-db
    port: 5432
    username: paperless
    password: ${PAPERLESS_DBPASS}
    format: custom
    options: "--clean --if-exists"
```

Verificación trimestral de restore (Fase 7, calendario Q1 → Paperless, ver `07-backups/03-backup-docker-volumes.md`):

```bash
# 1) Levantar Postgres + Paperless aislados en /tmp con datos restaurados
mkdir -p /tmp/drill-paperless/{db,data,media,export}
sudo chown -R 70:70    /tmp/drill-paperless/db
sudo chown -R 1000:1000 /tmp/drill-paperless/{data,media,export}

# 2) Restaurar el dump SQL más reciente
sudo borgmatic restore --archive latest \
    --database paperless \
    --restore-path /tmp/drill-paperless/dumps/

# 3) Restaurar media/
sudo borg extract --list \
    /mnt/hd2t/backups/borg::homelab-LATEST \
    mnt/hd2t/apps/paperless/media \
    -o /tmp/drill-paperless/

# 4) Levantar Postgres temporal (puerto 15432, no choca con producción)
docker run -d --rm --name drill-pg \
    -e POSTGRES_DB=paperless -e POSTGRES_USER=paperless \
    -e POSTGRES_PASSWORD=drill \
    -v /tmp/drill-paperless/db:/var/lib/postgresql/data \
    -p 15432:5432 \
    postgres:16-alpine

# 5) Cargar el dump
sleep 10
PGPASSWORD=drill pg_restore -h 127.0.0.1 -p 15432 \
    -U paperless -d paperless --clean --if-exists \
    /tmp/drill-paperless/dumps/paperless.psql

# 6) Levantar un Paperless temporal contra esa BBDD
docker run -d --rm --name drill-paperless \
    --link drill-pg:paperless-db \
    -e PAPERLESS_DBHOST=paperless-db \
    -e PAPERLESS_DBNAME=paperless \
    -e PAPERLESS_DBUSER=paperless \
    -e PAPERLESS_DBPASS=drill \
    -e PAPERLESS_SECRET_KEY="drill-key-not-real-not-secret-just-for-test-32b" \
    -e PAPERLESS_REDIS=redis://drill-redis:6379 \
    -v /tmp/drill-paperless/media:/usr/src/paperless/media \
    -v /tmp/drill-paperless/data:/usr/src/paperless/data \
    -v /tmp/drill-paperless/export:/usr/src/paperless/export \
    -p 18000:8000 \
    ghcr.io/paperless-ngx/paperless-ngx:2.18.4

# 7) Validar count de documentos vía Django shell
docker exec drill-paperless python manage.py shell -c \
    "from documents.models import Document; print('docs:', Document.objects.count())"
# docs: 432

# 8) Reindex (porque el Whoosh está vacío)
docker exec drill-paperless document_index reindex

# 9) Cleanup
docker stop drill-paperless drill-pg
sudo rm -rf /tmp/drill-paperless
```

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/paperless/docker-compose.yml \
    --env-file /home/homelab/homelab/.env \
    --env-file /home/homelab/homelab/stacks/paperless/.env \
    up -d --force-recreate
# Paperless reusa todos los bind mounts en hd2t.
# Si el índice Whoosh está corrupto: docker exec paperless document_index reindex.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear sistema base (Fase 1), Docker (Fase 2.1), red `homelab` (Fase 2.2), Pi-hole, Caddy, Authelia.
2. Restaurar el repo del homelab y los secrets:
   ```bash
   sudo borg extract /mnt/hd2t/backups/borg::homelab-LATEST \
       home/homelab/homelab
   sudo chown -R homelab:homelab /home/homelab/homelab
   sudo chmod 0600 /home/homelab/homelab/stacks/paperless/.env
   ```
3. Restaurar `media/`, `export/`, `classifier.pickle`:
   ```bash
   sudo borg extract /mnt/hd2t/backups/borg::homelab-LATEST \
       mnt/hd2t/apps/paperless/media \
       mnt/hd2t/apps/paperless/export \
       mnt/hd2t/apps/paperless/data/classifier.pickle
   ```
4. Levantar **solo** Postgres y restaurar el dump:
   ```bash
   cd /home/homelab/homelab
   docker compose -f stacks/paperless/docker-compose.yml \
       --env-file stacks/paperless/.env \
       up -d paperless-db

   sleep 15
   sudo borgmatic restore --archive latest --database paperless

   docker exec -i paperless-db psql -U paperless -d paperless \
       < /mnt/hd2t/apps/paperless/dumps/paperless.psql
   ```
5. Levantar el resto del stack:
   ```bash
   docker compose -f stacks/paperless/docker-compose.yml \
       --env-file stacks/paperless/.env \
       up -d
   ```
6. Reindex (el Whoosh estaba excluido del backup):
   ```bash
   docker exec paperless document_index reindex
   ```
7. Verificar `https://paperless.lan/api/` (200), login OIDC, count de documentos en la UI coincide con el del archive, `Settings → Mail → Test connection` (si está configurado).

> **Punto de no retorno**: el RPO máximo es **24 h** (frecuencia diaria de Borgmatic). Documentos consumidos entre el último backup y la pérdida se pierden de la BBDD; **pero** los originales **siguen existiendo** en `media/originals/` (Borg los respalda en cada run). Tras restore se pueden re-ingerir desde `consume/` para reconstruir la fila de la BBDD. Si el operador quiere RPO menor, añadir un timer `paperless-borg-only.timer` cada 6 h (reabrible).

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `paperless-db` falla a iniciar con `chown: changing ownership of '/var/lib/postgresql/data': Permission denied` | El bind mount `/mnt/hd2t/apps/paperless/db` no tiene UID 70 como owner. | `sudo chown -R 70:70 /mnt/hd2t/apps/paperless/db && docker compose up -d --force-recreate paperless-db`. |
| `paperless` queda en `(starting)` 5+ minutos | `depends_on` esperando un sidecar `unhealthy`. Revisar `docker ps`: típicamente `paperless-tika` tarda > 90 s en arm64 con poco RAM. | Subir `start_period` de Tika a `120s`, o liberar RAM (parar otros stacks). |
| Login OIDC redirige a Authelia y vuelve con `redirect_uri_mismatch` | El `redirect_uri` registrado en Authelia no tiene la barra final, o Caddy no manda `X-Forwarded-Proto`. | Verificar `redirect_uris: ['https://paperless.lan/accounts/oidc/authelia/login/callback/']` y que el drop-in tiene `header_up X-Forwarded-Proto {scheme}`. Reload Caddy + Authelia. |
| Login OIDC redirige y vuelve con `invalid_client` | El `PAPERLESS_OIDC_CLIENT_SECRET` en `.env` es el "Digest" (hash) en lugar del "Random" (claro). | Volver a generar; el hash va en `configuration.yml` de Authelia, el claro en `.env` de Paperless. |
| Tras login OIDC, `/admin/` devuelve 403 | El usuario OIDC no se promovió a `is_superuser`. | `docker exec paperless python manage.py shell -c "from django.contrib.auth import get_user_model; u=get_user_model().objects.get(username='operator'); u.is_superuser=True; u.is_staff=True; u.save()"`. |
| Documento pasa por consume/ pero queda en `inbox` sin OCR | Worker Celery no arrancó, o Tika/Gotenberg unhealthy en momento del consume. | `docker logs paperless --tail 100 \| grep -i celery`. Reiniciar: `docker compose restart paperless`. Re-procesar el doc: `docker exec paperless document_retagger -m -d`. |
| OCR muy lento (>2 min/página en arm64) | `PAPERLESS_OCR_THREADS_PER_WORKER` demasiado alto satura los 4 cores; o el documento es una imagen escaneada a 600 DPI. | Bajar a `PAPERLESS_OCR_THREADS_PER_WORKER=2` y `PAPERLESS_TASK_WORKERS=1`. Para escaneados configurar el escáner a 300 DPI (suficiente para OCR). |
| Búsqueda full-text no encuentra texto que aparece en un PDF | Whoosh no indexó (consumió antes de tener `data/index/` montado, o OCR falló silenciosamente). | `docker exec paperless document_index reindex` (operación lenta con miles de docs). |
| `borgmatic create` falla con `pg_dump: error: connection to server` | El contenedor `paperless-db` está down, o `${PAPERLESS_DBPASS}` no está exportado al unit systemd de Borgmatic. | `docker ps --filter name=paperless-db` y `systemctl cat borgmatic.service \| grep EnvironmentFile` → debe apuntar a un fichero con `PAPERLESS_DBPASS=...`. |
| Tras subir versión (`2.18.x` → `2.20.0`) Paperless arranca con HTTP 500 | Migration de Django pendiente. La imagen ejecuta `migrate` automáticamente, pero si fallara queda manual. | `docker exec paperless python manage.py migrate`. **Antes de cualquier upgrade**: `borgmatic create --tag pre-paperless-upgrade-X.Y.Z`. |
| `media/` crece descontroladamente (>30 GiB en 6 meses) | El operador ingiere PDFs ya OCRados y Paperless los **dobla** (original + archive). Es comportamiento por diseño. | Aceptar el coste o setear `PAPERLESS_OCR_MODE=skip_noarchive` para omitir el archived cuando el original ya tiene capa de texto seleccionable. |
| App móvil "Paperless Mobile" devuelve `SSL handshake failed` | La CA interna no está instalada en el almacén Android/iOS. | Android: Settings → Security → Encryption → Install certificate; iOS: descargar el `.crt` y permitir el perfil completo. Reiniciar la app. |
| `PAPERLESS_SECRET_KEY` cambió accidentalmente y nadie puede entrar | Las cookies de sesión cifradas con la clave anterior son ilegibles. | Restaurar el `PAPERLESS_SECRET_KEY` original desde git log o desde un backup del `.env`. Si no hay copia: aceptar que todos los usuarios deben relogarse (no destructivo). |
| Auto-matching de correspondents/tags clasifica mal sistemáticamente | El classifier Bayes está sesgado por documentos mal etiquetados. | `Settings → Saved Views → "Inbox"` → revisar y corregir manualmente 20–30 documentos; `docker exec paperless document_create_classifier` reentrena. |

---

## Decisiones que **no** se toman en este documento

- **SQLite o MariaDB como backend**: PostgreSQL es lo que la propia comunidad Paperless-ngx recomienda para producción. Reabrible si el homelab pivota a otro motor por unificación; descartado hoy por concurrencia y full-text.
- **Multi-tenant familiar con BBDD separadas**: Paperless gestiona permisos por documento; uso doméstico (operador + pareja) está cubierto. Una segunda instancia (`paperless-family.lan`) sería sobreingeniería.
- **OCR en GPU / aceleración Coral USB**: la Pi 5 + Tesseract en CPU procesa ~10–30 s/página, suficiente para volumen doméstico. Reabrible si el operador escala a >50 docs/día.
- **Reconocimiento facial / clasificación con LLM externo**: privacidad por defecto. El OCR es local; no se mandan documentos a APIs de terceros.
- **Connector IMAP** para descargar adjuntos del email: requiere credenciales de buzón gestionadas centralmente. Diferido a Fase 11 / Mailrise.
- **Almacenamiento en S3 / object storage**: Filesystem local en hd2t es suficientemente rápido y respaldable. Reabrible si Paperless se mueve a hd5t cuando hd2t se quede pequeño.
- **Auto-export periódico** (`document_exporter` en cron): redundante con Borg; el operador puede ejecutarlo bajo demanda si necesita "documentos legibles fuera de Paperless" para una migración o auditoría.
- **`paperless-cli` como herramienta cron**: ecosistema externo (no oficial). El operador puede instalarlo si automatiza pipelines complejos; no se documenta como parte del homelab por defecto.
- **Webhooks salientes** (Paperless 2.x los soporta para notificar a otros sistemas tras un consume). Diferido: no hay caso de uso inmediato.
- **Métricas Prometheus**: Django/Paperless no exponen `/metrics` nativamente. cAdvisor cubre RAM/CPU, Uptime Kuma cubre disponibilidad, `docker logs` cubre auditoría. Diferido.
- **Auto-tagging por LLM** (proyectos comunitarios tipo `paperless-ai`): comprometería privacidad y añadiría una pieza más a mantener. El Bayes naïve nativo es suficiente.

---

## Referencias

- Documentación oficial Paperless-ngx: <https://docs.paperless-ngx.com/>
- Setup recomendado por la comunidad: <https://docs.paperless-ngx.com/setup/>
- Variables de configuración: <https://docs.paperless-ngx.com/configuration/>
- Imagen Docker: <https://github.com/paperless-ngx/paperless-ngx/pkgs/container/paperless-ngx>
- Repositorio: <https://github.com/paperless-ngx/paperless-ngx>
- OCRmyPDF (motor OCR subyacente): <https://ocrmypdf.readthedocs.io/>
- Tesseract (idiomas instalables): <https://github.com/tesseract-ocr/tesseract>
- Apache Tika: <https://tika.apache.org/>
- Gotenberg: <https://gotenberg.dev/>
- django-allauth (OIDC): <https://docs.allauth.org/en/latest/socialaccount/providers/openid_connect.html>
- App móvil Paperless Mobile (Android): <https://github.com/astubenbord/paperless-mobile>
- Documentos del homelab relacionados:
  - `02-docker/02-estructura-compose.md` — convenciones del compose y de las redes Docker.
  - `03-red/04-caddy.md` — TLS interno con CA y `(lan_tls)`.
  - `04-seguridad/01-authelia.md` — registro de clients OIDC.
  - `07-backups/02-borgmatic.md` — hooks `postgresql_databases` y `before_backup`.
  - `11-productividad/02-bookstack.md` — patrón Postgres + OIDC del que este documento se inspira.
  - `11-productividad/03-linkding.md` — patrón Django + DRF token + OIDC equivalente.
