# Linkding

## Descripción

Tras Vaultwarden (`01-vaultwarden.md`) y Bookstack (`02-bookstack.md`), el homelab tiene resueltos dos pilares de la "memoria del operador": **secretos** (qué credencial sirve para qué servicio) y **conocimiento estructurado** (decisiones, runbooks, notas operativas). Falta una tercera pieza, mucho más mundana pero igual de erosiva si se gestiona mal: **los marcadores web**. La cantidad de URLs que un operador acumula en un homelab —tutoriales seguidos, threads de GitHub, RFCs, blogs de comunidad, releases notes, vídeos de YouTube con un truco que sólo se va a necesitar dentro de seis meses— escala rápido y mal en los nativos del navegador (Firefox Sync, Chrome Sync). Específicamente:

- Los favoritos del navegador **no se etiquetan** (solo se carpetean) y la búsqueda full-text es poco más que un `grep` por título.
- Compartirlos entre máquinas obliga a depender del proveedor (sync de Mozilla, sync de Google) que vive en una cuenta externa al homelab, distinta del SSO interno.
- Cuando el contenido remoto desaparece (link rot — calculado en ~25 % de URLs cada 7 años en estudios académicos), el favorito queda como un puntero muerto sin recuperación posible.
- No hay API para ingestar marcadores desde scripts (`yt-dlp` archivando un vídeo, Newsboat marcando un artículo, scripts de "leer luego").

Este documento despliega **Linkding** — gestor de marcadores autohospedado (Django/Python, ligero: ~50 MiB de RAM en idle, ~120 MiB con varios usuarios y miles de bookmarks) creado por Sascha Ißbrücker. Su rol concreto en el homelab:

1. **Servir la UI** en `https://linkding.${DOMAIN_LAN}/` con TLS terminado en Caddy (CA interna, igual que el resto). Detrás de Caddy, sin `ports:` al host.
2. **Persistir todo en SQLite** (`/etc/linkding/data/db.sqlite3` dentro del contenedor → `/mnt/hd2t/apps/linkding/data/db.sqlite3` en el host). Un único fichero portable; mismo patrón que Vaultwarden y por las mismas razones (1–5 usuarios humanos, una BBDD relacional dedicada es sobreingeniería).
3. **Snapshots HTML locales** de cada marcador (en `/mnt/hd2t/apps/linkding/data/assets/`): Linkding descarga el HTML de la página al guardar el marcador (configurable por marcador) y lo deja en disco como copia local. Resuelve el problema de link rot a coste de espacio: ~50–500 KiB por bookmark archivado.
4. **Autenticación contra Authelia vía OIDC** (Linkding ≥ 1.21 soporta OIDC nativamente vía `mozilla-django-oidc`). El flujo es idéntico al de Bookstack: redirect a Authelia, claims `sub`, `email`, `name`, sesión propia de Django tras autenticar. La cuenta superuser local de Django queda como fallback de emergencia.
5. **API REST** estable en `/api/bookmarks/` con autenticación por token de usuario (no OIDC, porque las extensiones de navegador y los scripts no pueden hacer flujos OAuth interactivos). El token se genera por usuario en `Settings → Integrations` y se pega en la extensión oficial.
6. **Extensión oficial** (Firefox, Chrome, Edge, derivados Chromium): "Linkding extension" en los addon stores. Se configura con `Server URL: https://linkding.lan` + API token.
7. **Respaldarse vía Borgmatic** con un hook `before_backup` que hace `VACUUM INTO` sobre la SQLite (mismo patrón que Vaultwarden, ya documentado en `07-backups/02-borgmatic.md`).

Lo que este documento **no** decide:

- **PostgreSQL como backend**. Linkding soporta `LD_DB_ENGINE=postgres` con `LD_DB_HOST/USER/PASSWORD`. Para 1–5 usuarios y miles de bookmarks, SQLite es suficiente y más simple de respaldar (un único fichero vs un sidecar entero). Reabrible si en el futuro se quiere replicación o concurrencia masiva.
- **Snapshots remotos en Internet Archive** (`LD_ENABLE_SNAPSHOTS=True` activa snapshots locales y, opcionalmente, llama a `web.archive.org` para archivado público). Activar snapshots **locales** sí; archivado **público** en Internet Archive **no**: el homelab no envía URLs a terceros sin necesidad (privacidad por defecto). Reabrible por marcador si el operador lo pide explícitamente.
- **`singlefile` integration** (descarga páginas como `.html` autocontenido con CSS+JS+imágenes inline). Linkding lo soporta vía un binario externo (`LD_SINGLEFILE_PATH`). Diferido: el snapshot HTML estándar (sin assets) cubre el 90 % del caso de uso (recuperar el texto del artículo) y `singlefile` añade ~5–20 MiB por bookmark — escalado mal con miles de marcadores.
- **Notificaciones por email** (recuperación de password, invitación de usuarios). Igual que Bookstack y Vaultwarden, queda **deshabilitado** hasta Mailrise (Fase 11). Las invitaciones se materializan vía CLI (`docker exec linkding python manage.py createsuperuser`) o desde la UI por el admin (URL de invite que se copia/pega manualmente).
- **Multi-usuario con espacios separados**. Linkding 1.20+ soporta multi-user pero con un único pool de marcadores compartido (no hay aislamiento por usuario; los marcadores son privados por defecto pero los tags y el espacio de URL están "fusionados" en el modelo). Para uso doméstico (operador + pareja) es aceptable; si la familia ampliada quiere gestionar bookmarks separados, se documenta en "Decisiones que no se toman".
- **Búsqueda con embeddings semánticos** (variantes self-hosted con `sentence-transformers`). No nativo en Linkding. La búsqueda actual es full-text sobre título + descripción + tags + contenido del snapshot, suficiente para el caso de uso.
- **Importación manual de un servicio anterior** (Pocket, Raindrop, Pinboard, Wallabag). Linkding soporta el formato Netscape HTML (estándar de export de Firefox/Chrome) y un export propio. Documentado como **paso opcional**, no obligatorio.
- **Sincronización bidireccional con Firefox/Chrome**. Linkding **no** sincroniza con los favoritos nativos del navegador. La extensión oficial es **alternativa** (no reemplazo) al gestor del navegador: el operador decide migrar progresivamente o mantener ambos.

Cuando este documento se haya aplicado:

- `https://linkding.${DOMAIN_LAN}/` muestra la UI de Linkding con cert de la CA interna.
- El primer login del operador pasa por Authelia (login + TOTP), Linkding recibe el `id_token` vía OIDC y crea automáticamente la cuenta del operador con permisos de superuser (vía `LD_OIDC_USERNAME_CLAIM=preferred_username` + `OIDC_CREATE_USER=True` + flag específico para auto-promover al primer usuario).
- La cuenta `admin` local de Django (creada en bootstrap) queda con password aleatorio largo (KeePassXC offline) como contingencia.
- El operador genera un API token en `Settings → Integrations`, instala la extensión oficial en Firefox/Chrome, la configura con `https://linkding.lan` + token, y empieza a guardar marcadores con un click.
- SQLite vive en `/mnt/hd2t/apps/linkding/data/db.sqlite3`; los snapshots HTML en `/mnt/hd2t/apps/linkding/data/assets/`.
- Borgmatic respalda diariamente con `VACUUM INTO` consistente y los snapshots como ficheros (T2: recreables vía re-archivado, pero respaldarlos evita un "primer click" lento tras restore).
- Uptime Kuma tiene un monitor HTTPS sobre `https://linkding.lan/health` con alerta Telegram + email.

> **Recordatorio de alcance**: Linkding es **solo LAN + Tailscale**. **No publica `ports:` al host**, **no se expone a Internet**, **no usa Let's Encrypt**. La extensión oficial habla con `https://linkding.lan` directamente cuando el operador está en LAN; vía Tailscale, MagicDNS resuelve el mismo nombre desde fuera de casa (siempre y cuando el cliente tenga la CA interna instalada — clave para que la extensión no rechace el cert).

---

## Requisitos Previos

- **Fase 2** completa: Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN=lan`, `LAN_IP=192.168.1.10`.
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre `linkding.${DOMAIN_LAN}` sin tocar Pi-hole).
  - Caddy con los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` definidos.
- **Fase 4** completa, en particular:
  - Authelia desplegado **con OIDC habilitado** (`identity_providers.oidc` configurado en `04-seguridad/01-authelia.md`). Linkding consume OIDC (no `forward_auth`): igual que Bookstack, es una aplicación web Django con sesión propia y soporta OIDC nativo. Caddy hace **bypass** de la auth (no aplica `import authelia_two_factor`); el flujo OIDC ya pasa por Authelia.
  - El **client OIDC** `linkding` registrado en `configuration.yml` de Authelia (ver "Configuración → 2. Registrar el client OIDC en Authelia").
- **Fase 7** completa: Borgmatic operativo con `homelab.backup=true` como discriminador. La SQLite se respalda con un hook `before_backup` (idéntico patrón al de Vaultwarden).
- **Operador** con la **CA interna instalada** en navegador, móvil y, **muy importante**, en el **perfil del navegador donde se instalará la extensión** (la extensión oficial de Linkding usa `fetch()` del navegador, hereda su trust store; sin la CA, la extensión devuelve `Network error: Failed to fetch` cuando intenta conectar a `https://linkding.lan/api/`).
- **Disco `hd2t`** montado en `/mnt/hd2t` con al menos **2 GiB** libres reservados para Linkding. La SQLite con miles de marcadores ronda 20–80 MiB; los snapshots HTML son lo que crece — estimar 1 GiB tras el primer año si el operador archiva ~2000 marcadores con snapshot.
- Un **`SECRET_KEY`** de Django (≥ 50 caracteres aleatorios) generado **una vez** y nunca cambiado: cifra cookies de sesión y tokens internos. Cambiarlo invalida sesiones (no destructivo: los usuarios se relogan vía OIDC).
- Una contraseña aleatoria larga (`openssl rand -base64 30`) para la cuenta `admin` local de Django, anotada en KeePassXC offline.

Comprobaciones rápidas:

```bash
# La red Docker compartida existe
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Caddy y Authelia corriendo
docker ps --filter name=caddy --filter name=authelia --format '{{.Names}} {{.Status}}'

# linkding.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short linkding.lan @192.168.1.2
# 192.168.1.10

# Espacio en hd2t
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'

# Authelia tiene OIDC habilitado
docker exec authelia grep -E '^identity_providers:|^\s+oidc:' /config/configuration.yml | head
```

---

## Decisión: imagen y versión

Linkding se publica desde Docker Hub como `sissbruecker/linkding`, con builds multi-arch (`amd64`, `arm64`, `armv7`). En la Pi 5 (aarch64) se usa el manifest `arm64`.

| Tag | Cuándo usar | Decisión aquí |
|---|---|---|
| `latest` | Demos. | Descartado (convención de Fase 2: tags exactos). |
| `latest-plus` | Variante "plus" con `singlefile` + `readability` preinstalados (~150 MiB extra). | Descartada: snapshots simples cubren el caso de uso del homelab; ver "Decisiones que no se toman". |
| `latest-alpine` | Variante con base `alpine`. | Descartada: la imagen Debian-slim por defecto pesa ~200 MiB, alpine ahorra ~60 MiB pero rota más a menudo. Diferencia irrelevante en hd2t. |
| `1.36.x` / `1.36.0` | Releases estables 1.36. | **Aceptado**. |
| `1.36.0` (ejemplo de tag exacto) | Reproducibilidad estricta. | **Aceptado** como compromiso entre reproducibilidad y mantenimiento. |
| `dev` | Builds nightly contra `main` upstream. | Descartado: rompe sin previo aviso (Linkding evoluciona OIDC y el modelo de tags rápido). |

> **Tag exacto en uso**: `sissbruecker/linkding:1.36.0`. Si en el momento de aplicar este documento existe una `1.36.x` superior con changelog limpio (sin migración de schema mayor de Django), se actualiza el tag aquí y en el `docker-compose.yml`, y se anota en el commit. **Nunca `latest`**, **nunca `dev`**.

> **Por qué Linkding y no Wallabag, Shaarli, Shiori o Hoarder**. Comparativa rápida en arm64 / homelab personal:
> - **Wallabag**: enfocado a "read-it-later" más que a marcadores; pesa ~600 MiB de imagen + necesita MariaDB/Postgres + Redis. Sobreingeniería para "guardar URLs y etiquetar". Descartado.
> - **Shaarli**: PHP minimal, sin BBDD (ficheros sueltos), sin API estable, sin OIDC. Funciona pero queda lejos del nivel de pulido de Linkding.
> - **Shiori**: Go, ligero, pero el desarrollo es lento, OIDC reciente y poco probado, snapshots locales menos maduros.
> - **Hoarder / Karakeep**: muy potente (LLM auto-tagging, full-text de PDFs), pero requiere Postgres + Meilisearch + Redis + Workers. Demasiada infraestructura para "1 usuario y 5000 bookmarks".
> - **Linkding**: punto de equilibrio: Django + SQLite, ~200 MiB en idle, OIDC nativo, API limpia, extensión oficial en Firefox/Chrome stores, multi-arch arm64 estable. Decidido.

> **Por qué `:1.36.0` y no `:1.36`**. Linkding hace migraciones de schema de Django en releases menores. Un tag flotante (`:1.36`) que avance una versión menor sin que el operador lo sepa puede dejar la SQLite en estado intermedio si el contenedor se cae a medias. Con tag exacto las actualizaciones son **deliberadas**: el operador lee el changelog, hace `borgmatic create --tag pre-linkding-upgrade-X.Y.Z`, edita el tag, `up -d`, valida que las migrations pasaron limpias. Watchtower está **deshabilitado** para este stack.

---

## Decisión: cómo se expone Linkding

Linkding corre Django con Gunicorn como WSGI, y un nginx interno reverse-proxea estáticos. La imagen escucha en `:9090` dentro del contenedor (HTTP plano; el TLS lo termina Caddy delante).

| Opción | Cómo se ve | Discusión |
|---|---|---|
| `network_mode: host` | Linkding ata `:9090` directamente. | Funcionaría (Caddy ata `:80/:443`, no `:9090`), pero rompe la convención del homelab (todos los servicios web detrás de Caddy con `expose:`). Descartado. |
| Bridge `homelab` con `ports: ["9090:9090"]` | Acceso directo desde la LAN sin pasar por Caddy. | HTTP plano sin TLS y sin auth Authelia delante. La extensión oficial **rechaza** servidores HTTP plano cuando el dominio no es `localhost`. Descartado. |
| Bridge `homelab` con `expose: 9090`, **sin `ports:`** | Linkding alcanzable solo dentro de la red Docker, vía DNS (`linkding:9090`). Caddy hace `reverse_proxy http://linkding:9090`. | Termina TLS en Caddy con la CA interna. Patrón establecido en Fase 3. **Aceptado**. |

Resultado: `expose: 9090` en el compose (no `ports:`), un drop-in `stacks/caddy/conf.d/42-linkding.caddy` que hace `reverse_proxy http://linkding:9090`, y todo el tráfico externo pasa por `https://linkding.${DOMAIN_LAN}/` con cert de la CA interna.

> **Sobre WebSocket / SSE**. Linkding **no** usa WebSocket. La UI es Django renderizado en servidor con HTMX para interacciones parciales (sin canales push). El reverse proxy es HTTP/HTTPS plano sin Upgrade.

> **Sobre el subpath**. Linkding soporta servirse en un subpath (ej. `https://homelab.lan/linkding/`) con `LD_CONTEXT_PATH=linkding/`. **No** se usa: el homelab convenido es **un subdominio por servicio** (Fase 3), más simple para Authelia (ACLs por host), Pi-hole (comodín `*.lan`), y Caddy (un bloque por host).

---

## Decisión: autenticación — Authelia OIDC, no `forward_auth`

A diferencia de Vaultwarden (que usa `forward_auth` solo en `/admin` por incompatibilidad con sus clientes nativos), Linkding tiene tres tipos de cliente:

1. **Navegador humano** sobre la UI web — auth por sesión Django.
2. **Extensión oficial** del navegador — auth por **API token** (cabecera `Authorization: Token <hex>`).
3. **Scripts del operador** vía API REST — auth por **API token** (idem).

Esto define la arquitectura de auth:

| Componente | Patrón de auth | Justificación |
|---|---|---|
| UI web (`/`, `/bookmarks`, etc.) | **OIDC contra Authelia** | El operador entra desde un navegador; el flujo OIDC es interactivo y bidireccional; SSO real con Bookstack y los demás clientes Authelia. |
| API (`/api/bookmarks/`, `/api/tags/`, etc.) | **API token** (no OIDC) | La extensión y los scripts no pueden hacer flujos OAuth interactivos. El token se genera **una vez** por usuario en la UI tras login OIDC y se pega en la extensión / script. |
| Admin Django (`/admin/`) | **OIDC contra Authelia, política `admins`** | El admin de Django es donde se gestionan usuarios y se ejecutan acciones de mantenimiento; igual que `/admin` de Vaultwarden pero el filtro lo hace Authelia con `authorization_policy: admins` (grupo dedicado) en lugar de un token aparte. |

Resultado: `LD_ENABLE_OIDC=True` en el `.env` de Linkding, registro de un client `linkding` en `configuration.yml` de Authelia con `redirect_uris: ["https://linkding.${DOMAIN_LAN}/oidc/callback/"]` (la barra final **es importante**, mozilla-django-oidc la añade), `LD_DISABLE_BACKGROUND_TASKS_AUTH=False` (los background workers que descargan snapshots usan auth interna, no OIDC), y Caddy hace bypass total: el flujo OIDC pasa por Authelia internamente cuando Linkding redirige.

> **Sobre el primer usuario OIDC**. mozilla-django-oidc por defecto crea usuarios con `is_staff=False, is_superuser=False`. Linkding tiene un setting **propio** (`LD_SUPERUSER_NAME=<usuario>`) que, si coincide con el `sub` o el `preferred_username` del primer login OIDC, promueve al usuario a superuser automáticamente. Documentado en "Configuración → 3".

> **Sobre la cuenta admin local de Django**. Antes de habilitar OIDC se crea un superuser local con `python manage.py createsuperuser` (sección "Despliegue → 4"). La cuenta sigue existiendo en la BBDD, pero solo es accesible si se desactiva OIDC (`LD_ENABLE_OIDC=False` y restart) — útil como **fallback si Authelia se rompe** (mismo patrón que Bookstack y la cuenta `admin@admin.com` de Vaultwarden). En operación normal el operador **no** usa esa cuenta.

> **Sobre el API token vs OIDC token**. Cuando el operador entra a la UI vía OIDC y va a `Settings → Integrations`, Linkding genera un **token Django** (`rest_framework.authtoken`) ligado a su usuario. Ese token **no expira** y es revocable individualmente desde la misma página. Las invocaciones de la extensión y los scripts mandan `Authorization: Token <hex>` en la cabecera; **no** pasan por Authelia (es un endpoint API, no UI). La defensa para fuerza bruta sobre `/api/` en este escenario sería una jail fail2ban — diferida (los tokens son de 40 hex chars aleatorios, ~160 bits de entropía; un atacante en LAN tiene tareas mejores).

---

## Decisión: persistencia y base de datos

Linkding 1.x soporta dos backends: **SQLite** (default) y **PostgreSQL**. Para 1–5 usuarios humanos:

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| SQLite (`/etc/linkding/data/db.sqlite3`) | Cero piezas adicionales, snapshot consistente con `VACUUM INTO`, archivo único portable, mismo patrón que Vaultwarden. | Worse para >50 usuarios concurrentes. | **Aceptado**. |
| PostgreSQL | Mejor concurrencia, replicación. | Otro contenedor a mantener, otra contraseña, otro consumo de RAM (~120–180 MiB). | Sobreingeniería para 1–5 usuarios. Descartado. |

Resultado: SQLite en `/mnt/hd2t/apps/linkding/data/db.sqlite3`. Linkding usa `journal_mode=WAL` por defecto. El hook `before_backup` de Borgmatic ejecuta `VACUUM INTO` antes de cada run, idéntico a Vaultwarden — el script `borg-pre-backup.sh` de este stack es un clon del de Vaultwarden cambiando ruta y nombre de contenedor.

Linkding guarda tres tipos de estado:

1. **BBDD relacional** — usuarios, marcadores, tags, sesiones, tokens. En SQLite (`db.sqlite3`).
2. **Snapshots HTML** — copia local del HTML de cada bookmark archivado. En filesystem (`/etc/linkding/data/assets/<bookmark_id>.html.gz`).
3. **Configuración runtime** — `settings.py` toma todo de variables de entorno; **no** hay ficheros de config persistentes que el operador edite.

| Aspecto | Decisión | Por qué |
|---|---|---|
| BBDD | SQLite local en `/mnt/hd2t/apps/linkding/data/db.sqlite3`. | 1–5 usuarios; ahorrar un sidecar. |
| Snapshots | Bind mount a `/mnt/hd2t/apps/linkding/data/assets/`. | Datos respaldables como ficheros (gz pequeños, < 500 KiB típico). |
| Configuración | Solo `.env` del compose, versionable (`.env.example`) salvo secretos. | Reproducible desde git + Borg. |
| Snapshot consistente BBDD | `sqlite3 db.sqlite3 'VACUUM INTO db.snapshot.sqlite3'` vía hook `before_backup` de Borgmatic. | Atómico, no requiere parar el contenedor; mismo patrón Vaultwarden. |

> **Por qué no parar el contenedor para hacer backup**. Linkding atiende requests interactivos del operador (UI) y de la extensión (API) cualquier momento — incluida la lectura de bookmarks desde una nueva pestaña. Parar el contenedor cada noche para Borg implica downtime; con `VACUUM INTO` es online y consistente. La sección "Backup" detalla el script.

> **Sobre `assets/` y crecimiento**. Cada bookmark con snapshot HTML pesa ~50–500 KiB comprimido (gzip). Con 5000 bookmarks archivados, el directorio ronda 1–2 GiB. El operador puede:
> - Desactivar snapshots por marcador en la UI (`Edit bookmark → uncheck "Create HTML snapshot"`).
> - Listar tamaños con `du -sh /mnt/hd2t/apps/linkding/data/assets/* | sort -h | tail -20` para detectar páginas pesadas (PDFs embebidos, etc.) y eliminar selectivamente.

---

## Stack: `stacks/linkding/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/linkding/docker-compose.yml` | microSD (git) | Stack. |
| `stacks/linkding/.env.example` | microSD (git) | Plantilla con `LD_SECRET_KEY`, `LD_OIDC_*`, `LD_SUPERUSER_NAME`. |
| `stacks/linkding/.env` | microSD (NO git) | Versión rellena con `SECRET_KEY` y `OIDC_RP_CLIENT_SECRET` reales. Modo `0600`. |
| `stacks/caddy/conf.d/42-linkding.caddy` | microSD (git) | Drop-in Caddy para `linkding.${DOMAIN_LAN}`. |
| `stacks/linkding/scripts/borg-pre-backup.sh` | microSD (git) | Hook `before_backup`: snapshot consistente de SQLite con `VACUUM INTO`. |
| `/mnt/hd2t/apps/linkding/data/` | hd2t | `db.sqlite3`, `assets/` (snapshots HTML). **Se respalda**. |
| `/mnt/hd2t/apps/linkding/dumps/` | hd2t | `db.snapshot.sqlite3` generado por el hook. **Se respalda**. |

### `stacks/linkding/docker-compose.yml`

```yaml
# Linkding — gestor de marcadores autohospedado (Django + SQLite).
# Convenciones: ver docs/02-docker/02-estructura-compose.md y docs/11-productividad/03-linkding.md.

name: linkding

services:
  linkding:
    image: sissbruecker/linkding:1.36.0
    container_name: linkding
    hostname: linkding
    restart: unless-stopped

    environment:
      TZ: ${TZ}
      # Linkding internamente corre como UID/GID 33 (www-data); ignora PUID/PGID
      # estilo LSIO. El bind mount se ajusta con setfacl (ver "Despliegue → 1").
      LD_HOST_PORT: "9090"
      LD_HOST_BIND_INTERFACE: "0.0.0.0"

      # URL canónica. Linkding la usa para construir links absolutos (emails,
      # OIDC redirect_uri, copia de URL en snapshots). DEBE coincidir con la
      # URL que ven los navegadores.
      LD_CSRF_TRUSTED_ORIGINS: https://linkding.${DOMAIN_LAN}

      # Clave secreta de Django (cookies de sesión, CSRF token, password reset
      # tokens). Generar UNA VEZ:
      #   docker run --rm sissbruecker/linkding:1.36.0 \
      #     python -c "import secrets; print(secrets.token_urlsafe(64))"
      LD_SECRET_KEY: ${LD_SECRET_KEY}

      # Auth: OIDC contra Authelia. Durante bootstrap (creación de superuser
      # local) se deja False; tras configurar Authelia se cambia a True.
      LD_ENABLE_OIDC: ${LD_ENABLE_OIDC:-False}

      # OIDC — solo se consume si LD_ENABLE_OIDC=True. Vacío durante bootstrap.
      OIDC_RP_CLIENT_ID: linkding
      OIDC_RP_CLIENT_SECRET: ${OIDC_RP_CLIENT_SECRET}
      OIDC_OP_AUTHORIZATION_ENDPOINT: https://auth.${DOMAIN_LAN}/api/oidc/authorization
      OIDC_OP_TOKEN_ENDPOINT: https://auth.${DOMAIN_LAN}/api/oidc/token
      OIDC_OP_USER_ENDPOINT: https://auth.${DOMAIN_LAN}/api/oidc/userinfo
      OIDC_OP_JWKS_ENDPOINT: https://auth.${DOMAIN_LAN}/jwks.json
      OIDC_RP_SIGN_ALGO: RS256
      OIDC_USERNAME_CLAIM: preferred_username

      # Promueve al usuario `<LD_SUPERUSER_NAME>` a is_superuser cuando entra
      # por primera vez vía OIDC. Coincide con el `preferred_username` del
      # operador en users_database.yml de Authelia.
      LD_SUPERUSER_NAME: ${LD_SUPERUSER_NAME}

      # Snapshots locales: descargar HTML al guardar bookmark. NO archivado
      # público en Internet Archive (privacidad por defecto).
      LD_ENABLE_SNAPSHOTS: "True"
      # Cuántos snapshots por bookmark se mantienen (rotación).
      LD_SNAPSHOTS_RETENTION: "3"

      # Background tasks: Linkding mantiene un pool de workers para snapshots
      # asíncronos. Mantener bajo en una Pi 5 (no saturar CPU al guardar
      # masivamente).
      LD_NUM_WORKERS: "2"

      # Idioma de la UI por defecto. Cada usuario puede sobreescribir en su
      # perfil; útil para que la familia entre directamente en español.
      LD_DEFAULT_LANGUAGE: es

      # CSRF / proxy: confiar en X-Forwarded-Proto/Host de Caddy (ver el
      # drop-in 42-linkding.caddy).
      LD_TRUST_PROXY_HOST: "True"

    networks:
      - homelab          # Caddy llega por aquí

    # NO `ports:`. Acceso solo vía Caddy.
    expose:
      - "9090"

    volumes:
      # Datos persistentes: SQLite + snapshots HTML.
      - /mnt/hd2t/apps/linkding/data:/etc/linkding/data
      # Carpeta para los snapshots SQL (VACUUM INTO) que respalda Borg.
      - /mnt/hd2t/apps/linkding/dumps:/etc/linkding/dumps
      # Hook de pre-backup montado read-only dentro del contenedor para que
      # Borgmatic pueda ejecutarlo via `docker exec`.
      - /home/homelab/homelab/stacks/linkding/scripts/borg-pre-backup.sh:/usr/local/bin/borg-pre-backup.sh:ro

    healthcheck:
      # /health devuelve 200 con `OK` cuando Django + SQLite están vivos.
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:9090/health >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

    # Hardening básico (la imagen NO corre como root: UID 33 www-data).
    security_opt:
      - "no-new-privileges:true"

    labels:
      homelab.role: "bookmarks"
      homelab.backup: "true"
      # Linkding hace migraciones de Django en releases menores; Watchtower
      # OFF, las actualizaciones son deliberadas con backup pre-upgrade.
      com.centurylinklabs.watchtower.enable: "false"

networks:
  homelab:
    external: true
```

### `stacks/linkding/.env.example`

```bash
# stacks/linkding/.env.example
# Variables específicas del stack Linkding.
# Las generales (TZ, PUID, PGID, DOMAIN_LAN) viven en el .env GLOBAL.

# Clave secreta de Django. Generar UNA VEZ:
#   docker run --rm sissbruecker/linkding:1.36.0 \
#     python -c "import secrets; print(secrets.token_urlsafe(64))"
# CAMBIARLA INVALIDA SESIONES Y CSRF TOKENS.
LD_SECRET_KEY=CHANGEME_GENERATE_64_BYTES_TOKEN_URLSAFE

# Auth method: durante el primer arranque dejar `False` para crear el
# superuser local con `createsuperuser`; tras configurar OIDC en Authelia
# y materializar OIDC_RP_CLIENT_SECRET, cambiar a `True`.
LD_ENABLE_OIDC=False

# OIDC client secret. Lo registra Authelia en su configuration.yml
# (sección identity_providers.oidc.clients). Aquí va EN CLARO (mozilla-django-oidc
# lo usa solo en memoria, no lo persiste en BBDD).
OIDC_RP_CLIENT_SECRET=CHANGEME_DEL_CLIENT_REGISTRADO_EN_AUTHELIA

# Username del operador en Authelia (`preferred_username` claim). Cuando
# este usuario entra por primera vez vía OIDC, Linkding lo promueve a
# is_superuser=True automáticamente.
LD_SUPERUSER_NAME=operator
```

### `stacks/caddy/conf.d/42-linkding.caddy`

```caddy
# /etc/caddy/conf.d/42-linkding.caddy — bloque LAN para Linkding.
# Linkding expone su UI + API + endpoints OIDC en http://linkding:9090
# dentro de `homelab`. La auth de la UI es OIDC contra Authelia (no
# forward_auth); la auth del API es por token (cabecera Authorization);
# Caddy no aplica `authelia_two_factor` aquí.
# Documentado en docs/11-productividad/03-linkding.md.

linkding.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Cabeceras estándar para que Linkding vea la IP real, el host original
    # y el esquema (importante para CSRF y para construir redirect_uri OIDC
    # con `https://`).
    reverse_proxy http://linkding:9090 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}
    }
}
```

> **Sobre `X-Forwarded-Proto` y CSRF**. Sin esta cabecera, Django ve la request como `http://linkding:9090/...` y el middleware CSRF rechaza envíos POST con `Origin: https://linkding.lan` por mismatch (`Origin checking failed`). La cabecera + `LD_TRUST_PROXY_HOST=True` en el compose alinea ambos.

> **Sobre `X-Forwarded-Host`**. mozilla-django-oidc construye el `redirect_uri` mirando `request.get_host()`; con `LD_TRUST_PROXY_HOST=True` Django usa `X-Forwarded-Host` y construye `https://linkding.lan/oidc/callback/` (coincide con lo registrado en Authelia). Sin esta cabecera Django usa `linkding:9090` (nombre interno) y Authelia rechaza con `redirect_uri_mismatch`.

### `stacks/linkding/scripts/borg-pre-backup.sh`

```bash
#!/usr/bin/env bash
# stacks/linkding/scripts/borg-pre-backup.sh
# Hook `before_backup` de Borgmatic: snapshot consistente de SQLite vía
# `VACUUM INTO`. Idéntico patrón al de Vaultwarden (07-backups/02-borgmatic.md).

set -euo pipefail

DB_SRC=/etc/linkding/data/db.sqlite3
DB_OUT=/etc/linkding/dumps/db.snapshot.sqlite3

# Asegurar que la carpeta de dumps existe (el bind mount apunta a hd2t).
mkdir -p "$(dirname "$DB_OUT")"

# Borrar el snapshot anterior; VACUUM INTO falla si el destino existe.
rm -f "$DB_OUT"

# VACUUM INTO es atómico desde SQLite 3.27 (2019). Mantiene la BBDD viva
# (ningún lock global), genera un fichero limpio (sin WAL pendiente).
sqlite3 "$DB_SRC" "VACUUM INTO '$DB_OUT';"

# Permisos legibles solo por el dueño del bind mount (root por defecto;
# Borgmatic corre como root en el host).
chmod 0600 "$DB_OUT"
```

### Crear los directorios persistentes y desplegar

```bash
# 0) Asegurar el árbol de datos en hd2t (idempotente)
sudo install -d -o root -g root -m 0755 /mnt/hd2t/apps/linkding
# Linkding corre como UID 33 dentro del contenedor (www-data en su imagen
# Debian-slim). El bind mount se chowna a 33:33 para que Django pueda
# escribir SQLite y assets.
sudo install -d -o 33 -g 33 -m 0750 /mnt/hd2t/apps/linkding/data
# El directorio dumps/ lo escribe el hook como root (Borgmatic corre como
# root en el host). Owner root para que solo Borgmatic pueda leer/limpiar.
sudo install -d -o root -g root -m 0700 /mnt/hd2t/apps/linkding/dumps

# 1) Generar LD_SECRET_KEY (UNA SOLA VEZ)
docker run --rm sissbruecker/linkding:1.36.0 \
    python -c "import secrets; print(secrets.token_urlsafe(64))"
# <64-byte-urlsafe-token>

# 2) Materializar stacks/linkding/.env
cd /home/homelab/homelab
cp stacks/linkding/.env.example stacks/linkding/.env
chmod 0600 stacks/linkding/.env
# Editar: pegar LD_SECRET_KEY, dejar LD_ENABLE_OIDC=False,
# OIDC_RP_CLIENT_SECRET vacío de momento, LD_SUPERUSER_NAME=<usuario Authelia>.

# 3) Drop-in de Caddy
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/42-linkding.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/42-linkding.caddy

# 4) Validar el Caddyfile
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
# Successful

# 5) Validar el compose
docker compose \
    -f stacks/linkding/docker-compose.yml \
    --env-file .env --env-file stacks/linkding/.env \
    config >/dev/null && echo "compose OK"

# 6) Levantar el stack
docker compose \
    -f stacks/linkding/docker-compose.yml \
    --env-file .env --env-file stacks/linkding/.env \
    up -d

# 7) Recargar Caddy
docker kill --signal=SIGUSR1 caddy
```

Tras `up -d`:

```bash
docker ps --filter name=linkding --format 'table {{.Names}}\t{{.Status}}'
# linkding   Up 30 seconds (healthy)

# Logs de migraciones de Django (primer arranque)
docker logs linkding 2>&1 | grep -E 'Applying|migrated' | head
# Operations to perform: Apply all migrations: ...
# Applying contenttypes.0001_initial... OK
# Applying auth.0001_initial... OK
# ... (decenas de migrations en orden)
```

`STATUS=(healthy)` debe llegar en ~30 s. Si se queda `(starting)` > 90 s, lo más probable es:
- `LD_SECRET_KEY` mal formateado o vacío (`Django ImproperlyConfigured`).
- Permisos de `/mnt/hd2t/apps/linkding/data` mal (UID 33 no puede escribir; logs: `Permission denied: '/etc/linkding/data/db.sqlite3'`).
- Disk full en hd2t.

Comprobación de extremo a extremo:

```bash
# /health responde 200 con texto plano
curl -sk https://linkding.lan/health
# OK

# Login page (con LD_ENABLE_OIDC=False) muestra formulario nativo Django
curl -sI https://linkding.lan/login/
# HTTP/2 200
```

---

## Configuración

### 1) Bootstrap: superuser local de Django (fallback)

Con `LD_ENABLE_OIDC=False` (paso 2 del despliegue), crear el superuser local de Django **una vez**. Es la cuenta de contingencia para "Authelia roto":

```bash
docker exec -it linkding python manage.py createsuperuser
# Username: admin-local
# Email address: admin-local@homelab.lan
# Password: <pegar uno aleatorio largo: openssl rand -base64 30>
# Password (again): <repetir>
# Superuser created successfully.
```

Anotar `admin-local` + password **solo** en KeePassXC offline. Esta cuenta no se usa día a día.

### 2) Registrar el client OIDC `linkding` en Authelia

En `/mnt/hd2t/apps/authelia/config/configuration.yml`, dentro de `identity_providers.oidc.clients`, añadir el bloque:

```yaml
identity_providers:
  oidc:
    # ... hmac_secret, issuer_private_key (ya definidos en 04-seguridad/01-authelia.md)
    clients:
      # ... otros clients existentes (bookstack, etc.)
      - client_id: linkding
        client_name: Linkding
        # Generar:
        #   docker run --rm authelia/authelia:4.38.10 \
        #     authelia crypto hash generate pbkdf2 --variant sha512 \
        #     --random --random.length 64 --random.charset rfc3986
        # Apuntar el password "Random" (claro) en stacks/linkding/.env
        # como OIDC_RP_CLIENT_SECRET y el "Digest" (hash) aquí.
        client_secret: '$pbkdf2-sha512$310000$<hash-del-secret>'
        public: false
        authorization_policy: two_factor
        redirect_uris:
          - https://linkding.lan/oidc/callback/
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
docker logs authelia 2>&1 | grep 'client_id=linkding' | tail
# expected: "Provider: registered client" client_id=linkding
```

> **Sobre la barra final del `redirect_uri`**. mozilla-django-oidc registra la URL de callback con barra final por convención Django (`urls.py: path('oidc/callback/', ...)`). Authelia es estricto: si la URL en `redirect_uris` es `https://linkding.lan/oidc/callback` (sin barra) y Linkding manda `https://linkding.lan/oidc/callback/` (con barra), Authelia rechaza con `redirect_uri_mismatch`. **Mantener la barra final** en `configuration.yml`.

### 3) Activar OIDC en Linkding

Editar `stacks/linkding/.env`:

```bash
sed -i 's/^LD_ENABLE_OIDC=.*/LD_ENABLE_OIDC=True/' stacks/linkding/.env
sed -i 's/^OIDC_RP_CLIENT_SECRET=.*/OIDC_RP_CLIENT_SECRET=PEGA_EL_PASSWORD_RANDOM_DEL_PASO_2/' \
    stacks/linkding/.env

docker compose -f stacks/linkding/docker-compose.yml \
    --env-file .env --env-file stacks/linkding/.env \
    up -d --force-recreate linkding
```

Tras el restart, `https://linkding.lan/login/` muestra ahora un botón "Login with OIDC" (además del formulario nativo, todavía visible para fallback). Pulsar el botón redirige a `https://auth.lan/?rd=...`, Authelia pide TOTP (política `two_factor`) y devuelve el `id_token`. mozilla-django-oidc crea automáticamente la cuenta del operador.

Al ser **el primer login OIDC** y coincidir el `preferred_username` con `LD_SUPERUSER_NAME=operator`, Linkding promueve la cuenta a `is_superuser=True`. Verificar:

```bash
docker exec linkding python manage.py shell -c \
    "from django.contrib.auth import get_user_model; \
     U=get_user_model(); \
     [print(u.username, u.is_superuser) for u in U.objects.all()]"
# admin-local True
# operator    True
```

### 4) Generar el API token y configurar la extensión

Desde el navegador autenticado vía OIDC:

1. **Settings** (avatar arriba a la derecha) → **Integrations** → **API**.
2. Anotar el token de 40 caracteres hex que muestra la página (formato `0123abcd...`). El token **no expira**; es revocable individualmente desde la misma página.

Instalar la extensión oficial:

| Navegador | Tienda |
|---|---|
| Firefox | <https://addons.mozilla.org/firefox/addon/linkding-extension/> |
| Chrome / Brave / Edge | <https://chromewebstore.google.com/detail/linkding-extension/...> |

Configurar la extensión:

| Campo | Valor |
|---|---|
| Server URL | `https://linkding.lan` |
| API token | `<token de 40 hex>` |

Verificación: pulsar el icono de la extensión en cualquier pestaña → debe mostrar el formulario de "Add bookmark" prerellenado con la URL y título de la página actual. Si muestra `Network error: Failed to fetch`, lo más probable es que la **CA interna no esté instalada en ese perfil del navegador** (ver Requisitos Previos).

> **Sobre la rotación del token**. Si el operador sospecha del token (logs raros, sincronización en una máquina perdida), `Settings → Integrations → API → Regenerate token`. Reconfigurar la extensión en cada navegador donde se usaba. La sincronización de favoritos del navegador no se pierde (los marcadores siguen en Linkding); solo hay que pegar el nuevo token.

### 5) Preferencias por usuario y predeterminados

En `Settings → General` (cada usuario):

| Setting | Recomendación | Razón |
|---|---|---|
| Theme | Auto (sigue el sistema) | El operador suele usar dark mode; la familia, light. |
| Display URL | Yes | Útil para distinguir entre dos bookmarks con el mismo título. |
| Show item count | Yes | Saber cuántas páginas hay por tag de un vistazo. |
| Show favicon | Yes | Reconocimiento visual rápido (cuesta un fetch por dominio en el primer view). |
| Tag display sort | Frequency, descending | Tags más usados arriba. |
| Default snapshot enabled | Yes | El homelab quiere combatir link rot por defecto. |

### 6) Importar bookmarks existentes (opcional)

Linkding acepta el formato **Netscape HTML** (estándar de export en Firefox/Chrome) y un export propio. Si el operador quiere migrar los favoritos del navegador al homelab:

1. **Firefox**: `Bookmarks → Manage Bookmarks → Import and Backup → Export Bookmarks to HTML…`. Guarda `bookmarks.html`.
2. **Chrome**: `Bookmark manager → ⋮ → Export bookmarks`. Guarda `bookmarks.html`.
3. En Linkding: `Settings → General → Import → Browse → bookmarks.html → Import`.
4. Linkding parsea el HTML, crea los marcadores con tags inferidos de las carpetas (`Toolbar/Tech/Linux` → tags `tech`, `linux`).

> **Sobre la migración progresiva**. La importación es **idempotente** (Linkding deduplica por URL): el operador puede re-importar tras añadir más bookmarks al navegador. Recomendación: importar **una vez** todo lo histórico, instalar la extensión, y **a partir de ahora** guardar nuevos marcadores **directamente en Linkding** desde la extensión (no en el sync nativo del navegador). Permite descomisionar Firefox Sync / Chrome Sync para favoritos progresivamente.

### 7) Integrar el hook en Borgmatic

En `/etc/borgmatic.d/borgmatic.yaml` añadir el hook `before_backup` (si todavía no estaba el patrón Vaultwarden, este lo extiende; si ya estaba, se añade una entrada más al array):

```yaml
hooks:
  before_backup:
    - docker exec linkding /usr/local/bin/borg-pre-backup.sh
    # ... (otros hooks existentes, p.ej. el de Vaultwarden)
```

Y asegurar que `/mnt/hd2t/apps/linkding/dumps/` está en `source_directories` (Borg respalda **el dump consistente**, no el `db.sqlite3` vivo):

```yaml
source_directories:
  - /home/homelab/homelab
  - /mnt/hd2t/apps/linkding/data/assets   # snapshots HTML (T2)
  - /mnt/hd2t/apps/linkding/dumps         # db.snapshot.sqlite3 (T1)
  # ... otros directorios

exclude_patterns:
  # Excluir el SQLite vivo (lo respalda el hook como dump consistente).
  - '/mnt/hd2t/apps/linkding/data/db.sqlite3'
  - '/mnt/hd2t/apps/linkding/data/db.sqlite3-wal'
  - '/mnt/hd2t/apps/linkding/data/db.sqlite3-shm'
```

Verificar:

```bash
sudo borgmatic config validate
# All configs valid

# Test del hook manual
docker exec linkding /usr/local/bin/borg-pre-backup.sh
ls -la /mnt/hd2t/apps/linkding/dumps/
# -rw------- 1 root root 28K ... db.snapshot.sqlite3

# Dry-run de Borgmatic incluye el dump y los assets
sudo borgmatic create --dry-run --list 2>&1 | grep -i linkding
```

### 8) Monitor en Uptime Kuma

En `https://uptime.${DOMAIN_LAN}/` añadir un **monitor HTTP(s)**:

| Campo | Valor |
|---|---|
| Friendly Name | `Linkding` |
| URL | `https://linkding.lan/health` |
| Heartbeat Interval | 60 s |
| Retries | 3 |
| Accepted Status Codes | 200 |
| Notification | Telegram + email (Mailrise cuando exista) |
| Public on status page | Sí |

`/health` es un endpoint público de Linkding que devuelve `OK` (texto plano) cuando Django + SQLite responden. **No** requiere auth, **no** revela info sensible. Equivalente a `/alive` de Vaultwarden y `/status` de Bookstack.

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/linkding/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/linkding/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla versionada. |
| `/home/homelab/homelab/stacks/linkding/.env` | microSD | `homelab:homelab` | `0600` | `LD_SECRET_KEY`, `OIDC_RP_CLIENT_SECRET`. **No** versionado. |
| `/home/homelab/homelab/stacks/linkding/scripts/borg-pre-backup.sh` | microSD | `homelab:homelab` | `0755` | Hook ejecutable. **Versionado**. |
| `/home/homelab/homelab/stacks/caddy/conf.d/42-linkding.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in Caddy. **Versionado**. |
| `/mnt/hd2t/apps/caddy/etc/conf.d/42-linkding.caddy` | hd2t | `homelab:homelab` | `0644` | Drop-in materializado. |
| `/mnt/hd2t/apps/linkding/data/db.sqlite3` | hd2t | `33:33` (UID interno www-data) | `0640` | BBDD principal. **NO** se respalda raw — se respalda el dump. |
| `/mnt/hd2t/apps/linkding/data/db.sqlite3-wal`, `-shm` | hd2t | `33:33` | `0640` | Write-ahead log de SQLite. **Excluidos** del archive Borg. |
| `/mnt/hd2t/apps/linkding/data/assets/` | hd2t | `33:33` | `0750` | Snapshots HTML (`<id>.html.gz`). **Sí se respalda** (T2). |
| `/mnt/hd2t/apps/linkding/dumps/db.snapshot.sqlite3` | hd2t | `root:root` | `0600` | Dump consistente regenerado por el hook antes de cada backup. **Sí se respalda** (T1). |

> **Tamaño esperado**:
> - BBDD con 5000 marcadores + tags + sesiones: 20–80 MiB.
> - `assets/`: ~1–2 GiB tras el primer año si el operador archiva ~2000 marcadores con snapshot. Comprimido (gzip).
> - `dumps/`: tamaño similar a la BBDD viva (~50 MiB), regenerado a cada `before_backup`.

> **Sobre el UID 33 vs el resto del homelab**. El stack Vaultwarden corre como root (con `cap_drop ALL`); Bookstack y los servicios LSIO corren como `${PUID}:${PGID}` (1000:1000); MariaDB corre como UID 999; **Linkding corre como UID 33** (www-data en su imagen Debian-slim). No hay conflicto porque cada stack tiene su propio bind mount con permisos a medida; pero al hacer `ls /mnt/hd2t/apps/` el operador verá distintos owners y debe entenderlo como **decisión consciente**, no como bug. Documentado en `01-sistema/04-estructura-directorios.md` ("Tabla de UIDs por servicio").

---

## Backup

A nivel del repositorio del homelab:

| Artefacto | Estrategia |
|---|---|
| `stacks/linkding/docker-compose.yml`, `.env.example`, `scripts/borg-pre-backup.sh` | Versionados en git. Reproducibles tras un reflasheo. |
| `stacks/caddy/conf.d/42-linkding.caddy` | Versionado en git. |
| `stacks/linkding/.env` (con `LD_SECRET_KEY` y `OIDC_RP_CLIENT_SECRET` reales) | **No** versionado. Respaldado por Borg como parte de `/home/homelab/homelab/`. |
| Decisiones (Authelia OIDC, SQLite, snapshots locales sin Internet Archive, no `singlefile`) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | Tier | ¿Se respalda? | Por qué |
|---|---|---|---|
| `/mnt/hd2t/apps/linkding/dumps/db.snapshot.sqlite3` | T1 | **Sí** | Snapshot consistente vía `VACUUM INTO`. Es la fuente de verdad para restore. |
| `/mnt/hd2t/apps/linkding/data/assets/` | T2 | **Sí** | Snapshots HTML; sin estos ficheros, el operador pierde la copia local de páginas que pueden haber muerto en el origen. Recreables (re-archivado on demand) pero respaldarlos es barato y rápido. |
| `/mnt/hd2t/apps/linkding/data/db.sqlite3` y `-wal`, `-shm` | — | **Excluidos** | SQLite vivo; copia consistente vía dump. |

Patrón en `borgmatic.yaml`:

```yaml
source_directories:
  - /home/homelab/homelab
  - /mnt/hd2t/apps/linkding/data/assets
  - /mnt/hd2t/apps/linkding/dumps

exclude_patterns:
  - '/mnt/hd2t/apps/linkding/data/db.sqlite3'
  - '/mnt/hd2t/apps/linkding/data/db.sqlite3-wal'
  - '/mnt/hd2t/apps/linkding/data/db.sqlite3-shm'

hooks:
  before_backup:
    - docker exec linkding /usr/local/bin/borg-pre-backup.sh
```

Verificación trimestral de restore (Fase 7, calendario Q1 → Linkding, ver `07-backups/03-backup-docker-volumes.md`):

```bash
# 1) Levantar un Linkding temporal aislado en /tmp
mkdir -p /tmp/drill-linkding/data
sudo chown 33:33 /tmp/drill-linkding/data

# 2) Restaurar el último dump del archive Borg
sudo borg extract --list \
    /mnt/hd2t/backups/borg::homelab-LATEST \
    mnt/hd2t/apps/linkding/dumps/db.snapshot.sqlite3 \
    -o /tmp/drill-linkding/

# 3) Renombrar el snapshot a `db.sqlite3` (Linkding espera ese nombre)
sudo cp /tmp/drill-linkding/mnt/hd2t/apps/linkding/dumps/db.snapshot.sqlite3 \
    /tmp/drill-linkding/data/db.sqlite3
sudo chown 33:33 /tmp/drill-linkding/data/db.sqlite3

# 4) Levantar el contenedor en modo solo lectura sin OIDC
docker run -d --rm --name drill-linkding \
    -v /tmp/drill-linkding/data:/etc/linkding/data \
    -e LD_SECRET_KEY="drill-key-not-real-not-secret-just-for-test-32b" \
    -e LD_ENABLE_OIDC=False \
    -p 19090:9090 \
    sissbruecker/linkding:1.36.0

# 5) Validar count de bookmarks vía shell de Django
docker exec drill-linkding python manage.py shell -c \
    "from bookmarks.models import Bookmark; print('bookmarks:', Bookmark.objects.count())"
# bookmarks: 5234

# 6) Validar acceso vía API (creando un token rápido para el superuser local)
docker exec drill-linkding python manage.py shell -c \
    "from rest_framework.authtoken.models import Token; \
     from django.contrib.auth import get_user_model; \
     u = get_user_model().objects.filter(is_superuser=True).first(); \
     t, _ = Token.objects.get_or_create(user=u); print(t.key)"
# <token>

curl -sH "Authorization: Token <token>" \
    http://127.0.0.1:19090/api/bookmarks/?limit=1 | jq .count
# 5234

# 7) Cleanup
docker stop drill-linkding
sudo rm -rf /tmp/drill-linkding
```

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/linkding/docker-compose.yml \
    --env-file /home/homelab/homelab/.env \
    --env-file /home/homelab/homelab/stacks/linkding/.env \
    up -d --force-recreate
# Linkding reusa /mnt/hd2t/apps/linkding/data/{db.sqlite3,assets/}.
# Las sesiones activas siguen válidas (cookies cifradas con LD_SECRET_KEY).
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear sistema base (Fase 1), Docker (Fase 2.1), red `homelab` (Fase 2.2), Pi-hole, Caddy, Authelia.
2. Restaurar el repo del homelab y los secrets:
   ```bash
   sudo borg extract /mnt/hd2t/backups/borg::homelab-LATEST \
       home/homelab/homelab
   sudo chown -R homelab:homelab /home/homelab/homelab
   sudo chmod 0600 /home/homelab/homelab/stacks/linkding/.env
   ```
3. Restaurar `/mnt/hd2t/apps/linkding/data/assets/` y los `dumps/`:
   ```bash
   sudo borg extract /mnt/hd2t/backups/borg::homelab-LATEST \
       mnt/hd2t/apps/linkding/data/assets \
       mnt/hd2t/apps/linkding/dumps
   ```
4. Restaurar la SQLite **a partir del dump consistente**:
   ```bash
   sudo install -d -o 33 -g 33 -m 0750 /mnt/hd2t/apps/linkding/data
   sudo cp /mnt/hd2t/apps/linkding/dumps/db.snapshot.sqlite3 \
       /mnt/hd2t/apps/linkding/data/db.sqlite3
   sudo chown 33:33 /mnt/hd2t/apps/linkding/data/db.sqlite3
   sudo chmod 0640 /mnt/hd2t/apps/linkding/data/db.sqlite3
   ```
5. Levantar Linkding:
   ```bash
   cd /home/homelab/homelab
   docker compose -f stacks/linkding/docker-compose.yml \
       --env-file .env --env-file stacks/linkding/.env \
       up -d
   ```
6. Verificar `https://linkding.lan/health` (200 con `OK`), login OIDC, count de bookmarks en la UI coincide con el del archive.

> **Punto de no retorno**: el RPO máximo es **24 h** (frecuencia diaria de Borgmatic). Cambios entre el último backup y la pérdida se pierden. Para Linkding es **aceptable**: los marcadores nuevos del último día se pueden recuperar manualmente desde el historial del navegador (las URLs visitadas suelen seguir en `history.sqlite` del browser local). Si el operador quiere RPO menor, añadir un timer `linkding-borg-only.timer` cada 6 h (reabrible).

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `STATUS=(starting)` indefinidamente, logs muestran `Permission denied: '/etc/linkding/data/db.sqlite3'` | El bind mount no tiene UID 33 como owner. | `sudo chown -R 33:33 /mnt/hd2t/apps/linkding/data && docker restart linkding`. |
| Login OIDC redirige a Authelia y vuelve con `redirect_uri_mismatch` | El `redirect_uri` registrado en Authelia no tiene la barra final, o Caddy no manda `X-Forwarded-Proto: https`. | Verificar que `redirect_uris: ['https://linkding.lan/oidc/callback/']` (con barra) y que el drop-in Caddy tiene `header_up X-Forwarded-Proto {scheme}`. Reload Caddy + Authelia. |
| Login OIDC redirige y vuelve con `invalid_client` | El `OIDC_RP_CLIENT_SECRET` en `.env` de Linkding es el "Digest" (hash) en lugar del "Random" (claro) que produce `authelia crypto hash generate`. | Volver a generar; el hash va en `configuration.yml` de Authelia, el claro en `.env` de Linkding. |
| Tras login OIDC, el usuario aparece como NO-superuser y no puede ver `/admin/` | `LD_SUPERUSER_NAME` no coincide exactamente con el `preferred_username` del operador en Authelia. | `docker exec linkding python manage.py shell -c "from django.contrib.auth import get_user_model; u=get_user_model().objects.get(username='operator'); u.is_superuser=True; u.is_staff=True; u.save()"`. |
| Extensión devuelve `Network error: Failed to fetch` al pulsar el icono | El navegador no confía en el cert de la CA interna en ese perfil. | Instalar la CA interna en el navegador siguiendo `03-red/04-caddy.md` → "Instalar el root CA en los clientes". Reiniciar el navegador. |
| Extensión devuelve `401 Unauthorized` al añadir un bookmark | API token revocado/regenerado y la extensión sigue con el viejo. | Copiar el nuevo token desde `Settings → Integrations`, pegar en la extensión. |
| Snapshots HTML no se generan al guardar bookmark, los marcadores aparecen sin "View snapshot" | Workers en background ahogados, o `LD_ENABLE_SNAPSHOTS=False`. | `docker exec linkding python manage.py snapshot_bookmarks` (regenera en bulk). Verificar `LD_NUM_WORKERS ≥ 2` y `LD_ENABLE_SNAPSHOTS=True`. |
| `borgmatic create` falla con `OperationalError: database is locked` cuando el hook intenta `VACUUM INTO` | El hook está apuntando al `db.sqlite3` vivo y otro proceso (worker) está escribiendo. SQLite `VACUUM INTO` puede coexistir, pero la imagen vieja a veces fuerza locks. | Verificar que el hook tiene `sqlite3 /etc/linkding/data/db.sqlite3 'VACUUM INTO ...'` (path absoluto dentro del contenedor) y que se ejecuta vía `docker exec linkding ...` (no en el host con el path de hd2t — los locks de WAL son por inode + namespace). |
| Imágenes de favicon de los marcadores rotas tras un restore | `assets/favicons/` no se restauró completamente, o los UIDs cambiaron y la imagen no puede leer. | `sudo chown -R 33:33 /mnt/hd2t/apps/linkding/data/assets`. Si persiste, regenerar: `docker exec linkding python manage.py refresh_favicons`. |
| `LD_SECRET_KEY` cambió accidentalmente y nadie puede entrar | Las cookies de sesión cifradas con la clave anterior son ilegibles. | Restaurar el `LD_SECRET_KEY` original desde el git log o desde un backup del `.env`. Si no hay copia: aceptar que todos los usuarios deben relogarse (no destructivo: los datos siguen ahí, solo las sesiones expiran). |
| Búsqueda full-text no encuentra páginas con texto del snapshot | Linkding indexa título + descripción + tags por defecto; el contenido del snapshot se indexa solo si `LD_ENABLE_SNAPSHOTS=True` **y** el snapshot ya se descargó (es asíncrono). | Esperar 1–2 min y reintentar. Para forzar reindex: `docker exec linkding python manage.py rebuild_index` (operación lenta con miles de bookmarks). |
| Tras subir versión (`1.36.0` → `1.40.0`) la BBDD no migra y Linkding arranca con HTTP 500 | Migración de Django que requiere `python manage.py migrate`. La imagen suele ejecutarlo automáticamente, pero si falla queda manual. | `docker exec linkding python manage.py migrate`. **Antes de cualquier upgrade**: `borgmatic create --tag pre-linkding-upgrade-X.Y.Z`. |
| `assets/` crece descontroladamente (>10 GiB en pocos meses) | Algún tag concreto (ej. `pdf-archive`) está marcando bookmarks con PDFs adjuntos pesados que se descargan al snapshot. | `du -sh /mnt/hd2t/apps/linkding/data/assets/* | sort -h | tail -20` para identificar; en la UI desactivar snapshot para esos bookmarks (o mover a un tag `no-snapshot`). |

---

## Decisiones que **no** se toman en este documento

- **PostgreSQL como backend**: SQLite es suficiente y más simple de respaldar para 1–5 usuarios. Reabrible si el homelab evoluciona a multi-Pi o multi-tenant.
- **Variante `latest-plus` con `singlefile` y `readability` preinstalados**: snapshots simples cubren el 90 % del caso de uso a coste mucho menor en disco. Reabrible si el operador detecta páginas que se "rompen" sin JS al re-visitar el snapshot.
- **Archivado público en Internet Archive** (`LD_SAVE_TO_WAYBACK_MACHINE=True`): privacidad por defecto; el homelab no manda URLs a terceros sin necesidad. Reabrible por bookmark si el operador lo pide.
- **`LD_ENABLE_LINK_PREFETCH`** (descarga título + favicon de la URL al pegarla): activado por defecto en imágenes recientes, no se cambia.
- **SMTP saliente real** (Mailrise / relay externo): a la espera de Fase 11 (`mailrise.md`). Hoy `EMAIL_BACKEND=console` (los emails se vuelcan a `docker logs linkding`); las invitaciones de usuario, en homelab doméstico, se materializan vía CLI o copiando el link manualmente.
- **OAuth social** (GitHub, Google): Linkding soporta múltiples providers. Hoy: solo Authelia. Reabrible si se quiere abrir colaboración a externos sin crear cuenta Authelia.
- **Multi-user con espacios separados**: Linkding fusiona el espacio de bookmarks (la separación es por **owner del bookmark**, pero los tags y URLs son globales). Para uso doméstico es aceptable; si la familia ampliada quiere espacios totalmente aislados, considerar una segunda instancia de Linkding (`linkding-family.lan`) con su propia BBDD — diferido por sobreingeniería.
- **Búsqueda con embeddings semánticos**: no nativa en Linkding. La full-text actual sobre título + descripción + tags + contenido del snapshot es suficiente; añadir embeddings requeriría Qdrant/Meilisearch/Postgres pgvector + un job de indexado. Diferido.
- **Sincronización bidireccional con Firefox/Chrome Sync**: incompatible (Mozilla y Google no exponen API público de write). El homelab acepta que Linkding es **alternativo** al gestor del navegador, no replicado.
- **Métricas Prometheus**: Django/Linkding no exponen `/metrics` nativamente (existen `django-prometheus` libs pero no integradas en la imagen oficial). cAdvisor cubre RAM/CPU, Uptime Kuma cubre disponibilidad, `docker logs` cubre auditoría. Diferido.
- **Jail fail2ban sobre `/api/`**: el API token tiene 160 bits de entropía; un atacante en LAN tiene tareas mejores. Diferida si en el futuro se observan logs de fuerza bruta.
- **Replicación / HA**: descartada. Para 1–5 usuarios y SQLite en un único disco con backup Borg diario, es sobreingeniería. Si el homelab evoluciona a multi-Pi, reabrir con Postgres + read replicas.
- **Browser extension forks** (Floccus, otros): Floccus sincroniza marcadores **del navegador** con Linkding (mantiene el sync nativo además de Linkding). Reabrible si el operador quiere mantener ambos vivos en paralelo durante la migración; no es la postura por defecto del proyecto.

---

## Verificación Final

Antes de pasar a `04-paperless-ngx.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/linkding/docker-compose.yml ps` | `linkding ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect linkding --format '{{.Config.Image}}'` | `sissbruecker/linkding:1.36.0` |
| Linkding en la red `homelab`, sin `ports:` | `docker inspect linkding --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'`<br>`docker port linkding` | `homelab` y `(vacío)` |
| Caddy alcanza Linkding | `docker exec caddy curl -fsS http://linkding:9090/health` | `OK` |
| `/health` responde desde la LAN | `curl -sk https://linkding.lan/health` | `OK` |
| Home carga (HTML) | `curl -sI https://linkding.lan/` | `HTTP/2 200` (o 302 a `/login/` si no hay cookie) |
| Cert hoja firmado por la CA local | `echo \| openssl s_client -connect linkding.lan:443 -servername linkding.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| OIDC negociado correctamente | clic en "Login with OIDC" → completar 2FA → vuelve a `https://linkding.lan/` con sesión | sin errores en la URL, avatar del operador visible |
| `LD_ENABLE_OIDC=True` aplicado | `docker exec linkding printenv LD_ENABLE_OIDC` | `True` |
| Cuenta admin local existe (fallback) | `docker exec linkding python manage.py shell -c "from django.contrib.auth import get_user_model; print([(u.username, u.is_superuser) for u in get_user_model().objects.all()])"` | lista que incluye `('admin-local', True)` y `('operator', True)` |
| API token funcional | `curl -sH "Authorization: Token <token>" https://linkding.lan/api/bookmarks/?limit=1 \| jq .count` | número entero (count actual de bookmarks) |
| Extensión oficial conecta | añadir un bookmark de prueba desde la extensión | aparece en la UI con título + URL + (si snapshot habilitado) "View snapshot" funcional tras unos segundos |
| Hook de pre-backup ejecutable | `docker exec linkding /usr/local/bin/borg-pre-backup.sh; ls -la /mnt/hd2t/apps/linkding/dumps/` | `db.snapshot.sqlite3` con tamaño > 0 y mtime reciente |
| Borgmatic incluye Linkding | `sudo borgmatic create --dry-run --list 2>&1 \| grep -i linkding` | `mnt/hd2t/apps/linkding/dumps/db.snapshot.sqlite3` y `mnt/hd2t/apps/linkding/data/assets/` listados |
| Patrón de exclusión activo | `grep '/mnt/hd2t/apps/linkding/data/db.sqlite3' /etc/borgmatic.d/borgmatic.yaml` | línea presente en `exclude_patterns` |
| Monitor Uptime Kuma activo | UI Uptime Kuma, monitor `Linkding` | verde con latencia < 200 ms |
| Datos persistidos tras reboot | `sudo reboot`; tras reconectar: `docker ps --filter name=linkding` | `Up (healthy)` sin acción manual; los bookmarks siguen ahí |
| Stack en git (sin secretos) | `git status; git ls-files stacks/linkding stacks/caddy/conf.d/42-linkding.caddy` | `docker-compose.yml`, `.env.example`, `scripts/borg-pre-backup.sh`, `42-linkding.caddy` tracked; `stacks/linkding/.env` ignorado |

Cumplido el último punto, el homelab tiene su **gestor de marcadores** con TLS de la CA local, SSO real contra Authelia, snapshots HTML locales contra link rot, API token para extensiones del navegador, dump consistente diario en Borg, restore drill documentado y monitor Uptime Kuma con alerta. La siguiente puerta es **gestión documental con OCR**: Paperless-ngx en `04-paperless-ngx.md`.

---

## Referencias

- [Documento anterior: `docs/11-productividad/02-bookstack.md`](./02-bookstack.md)
- [Documento siguiente: `docs/11-productividad/04-paperless-ngx.md`](./04-paperless-ngx.md)
- [Documento relacionado: `docs/03-red/04-caddy.md`](../03-red/04-caddy.md)
- [Documento relacionado: `docs/04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)
- [Documento relacionado: `docs/05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md)
- [Documento relacionado: `docs/07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
- [Documento relacionado: `docs/07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md)
- [Linkding en GitHub](https://github.com/sissbruecker/linkding)
- [Documentación oficial de Linkding](https://linkding.link/)
- [Imagen Docker `sissbruecker/linkding`](https://hub.docker.com/r/sissbruecker/linkding)
- [Extensión oficial para Firefox](https://addons.mozilla.org/firefox/addon/linkding-extension/)
- [`mozilla-django-oidc` (auth backend)](https://mozilla-django-oidc.readthedocs.io/)
