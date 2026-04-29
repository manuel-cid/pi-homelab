# FreshRSS

## Descripción

Vaultwarden (`01-vaultwarden.md`), Bookstack (`02-bookstack.md`), Linkding (`03-linkding.md`), Paperless-ngx (`04-paperless-ngx.md`), Mealie (`05-mealie.md`) y Stirling-PDF (`06-stirling-pdf.md`) cubren respectivamente **secretos**, **conocimiento estructurado**, **marcadores web**, **papel digitalizado**, **recetas** y **manipulación PDF puntual**. Falta cerrar la fase con la **memoria de lectura** del operador: las **fuentes de información cuya entrada al hogar es continua** (blogs técnicos, releases de proyectos, podcasts vía RSS, news aggregators, scrapers de cambios, comunidades). El estado típico antes de tener un agregador propio:

- **Inoreader / Feedly** (SaaS): perfectamente funcionales, pero el "qué leo, qué archivo, qué destaco" — un perfil del operador notablemente íntimo — vive en servidores de terceros, vinculado a una cuenta Google. La capa gratuita de Feedly limita a 100 feeds, y la cuenta Pro cuesta ~80 €/año.
- **Bookmarks de "leer luego"** en el navegador: se acumulan a centenares, no se vacían nunca y no soportan agregación.
- **Newsletters por email**: ensucian la bandeja personal y son difíciles de archivar y buscar a posteriori.
- **El mismo navegador** (Firefox como agregador): nunca llegó a tener el pulido suficiente, y los addons (Brief, Bamboo Feed Reader) caen y resucitan con cada cambio de API.
- **Newsboat en CLI**: pulcro, pero sin sync entre máquinas, sin app móvil decente, sin búsqueda full-text persistente.

Este documento despliega **FreshRSS** — agregador RSS/Atom autohospedado escrito en PHP por Marien Fressinaud y mantenido por una comunidad activa (`https://github.com/FreshRSS/FreshRSS`, ~10k stars). Es el equivalente *self-hosted* de Inoreader: feeds organizados en categorías, marcado de favoritos, búsqueda full-text sobre titulares + cuerpo, OPML import/export, API compatible con **Fever** y **Google Reader** (consumida por una decena de apps móviles modernas: Reeder, FeedMe, FluentReader, NetNewsWire, ReadKit, FocusReader). Su rol concreto en el homelab:

1. **Servir la UI** en `https://freshrss.${DOMAIN_LAN}/` con TLS terminado en Caddy (CA interna, igual que el resto). Detrás de Caddy, sin `ports:` al host.
2. **Persistir todo en SQLite** (un fichero por usuario en `/var/www/FreshRSS/data/users/<user>/db.sqlite` dentro del contenedor → `/mnt/hd2t/apps/freshrss/data/users/<user>/db.sqlite` en el host). Mismo patrón que Vaultwarden, Linkding y Mealie (1–5 usuarios humanos, una BBDD relacional dedicada por usuario es ya suficiente; PostgreSQL/MySQL es sobreingeniería).
3. **Polling de feeds** vía un cron interno a la imagen oficial (`CRON_MIN=*/30` por defecto: refresco cada 30 min). El cron lo arranca el `entrypoint` con `supercronic`; no es un sidecar, va dentro del mismo contenedor.
4. **Importación de OPML** de Feedly/Inoreader/Newsboat: subir el `subscriptions.opml` desde la UI (`Configuración → Importar`) o vía CLI (`docker exec freshrss cli/import-for-user.php`). 200–500 feeds importan en segundos; los primeros refresh tardan más porque cada feed se polea individualmente.
5. **Autenticación contra Authelia vía OIDC** (FreshRSS 1.21+ trae el módulo Apache **`mod_auth_openidc`** preinstalado en la imagen oficial; basta con `OIDC_ENABLED=1` y un puñado de variables). Flujo: el navegador entra en `https://freshrss.lan/`, Apache redirige a Authelia (login + TOTP), Authelia devuelve el `id_token`, Apache extrae el claim configurado (`preferred_username`) y lo pasa a FreshRSS como `REMOTE_USER`; FreshRSS, configurado con `auth_type=http_auth`, confía en la cabecera y crea/loguea el usuario.
6. **API password independiente** de la auth web. Las apps móviles que hablan **Fever** (`/api/fever.php`) o **Google Reader** (`/api/greader.php`) no pueden hacer flujos OIDC interactivos: usan un par "username + API password" generado en `Configuración → Perfil → API`. Las rutas `/api/...` quedan **exentas** de OIDC en Apache (`OIDC_PASS_USERINFO=0` + `OIDCRedirectURI` selectivo).
7. **Multi-usuario**. La unidad de aislamiento de FreshRSS es el usuario: cada uno tiene su propia SQLite, sus feeds, sus categorías, sus filtros. El operador es admin (puede crear/borrar usuarios); la pareja y, opcionalmente, otros miembros, son cuentas regulares.
8. **Extensiones** (en `/var/www/FreshRSS/extensions/`): plugins comunitarios para reformatear contenido, usar Mercury/readability proxy, marcar como leído por scroll, integrar Wallabag, etc. Extensions oficiales y third-party se gestionan desde la UI; el bind mount permite persistirlas a través de upgrades.
9. **Respaldarse vía Borgmatic** con un hook `before_backup` que itera sobre los usuarios y hace `VACUUM INTO` sobre cada SQLite (idéntico patrón al script de Vaultwarden, Linkding y Mealie, con un `for` por usuario).

Lo que este documento **no** decide:

- **MariaDB / PostgreSQL como backend**. FreshRSS soporta `DB_BASE=mysql` y `DB_BASE=pgsql`. Para 1–5 usuarios y unos miles de feeds (con un buffer de ~1–2 millones de entries acumulados a 5 años entre todos), SQLite es suficiente y más simple de respaldar (un fichero por usuario vs un sidecar). Reabrible si la familia ampliada quiere centralizar.
- **`mod_auth_openidc` con cliente confidencial vs PKCE público**. A diferencia de Mealie (que es SPA y elige PKCE puro), FreshRSS es PHP server-side: `mod_auth_openidc` es un **cliente confidencial** clásico, con `client_secret` que vive en el filesystem del contenedor. Patrón equivalente al de Bookstack y Paperless-ngx (también server-side).
- **Autenticación nativa por formulario** (`auth_type=form`) además de OIDC. FreshRSS solo permite **un** `auth_type` activo a la vez. El homelab elige `http_auth` (delegado a Apache + OIDC) y reserva la cuenta admin local para el caso "Authelia roto", accesible sólo si se cambia `auth_type=form` temporalmente.
- **Web hooks / notificaciones** (Slack, Discord, Telegram cuando aparece un nuevo entry). FreshRSS soporta extensiones para esto pero el homelab lo difiere a Mailrise (Fase 11). El operador no quiere notificación push de feeds — el modelo es "leer cuando se quiera leer", no "interrumpir con cada nuevo post".
- **Búsqueda full-text con SQLite FTS5**. FreshRSS por defecto hace `LIKE %query%`, lento con >100k entries. Tiene patch comunitario para FTS5 pero no es estable. Reabrible si la búsqueda se convierte en doloroso (>10 s).
- **Extensión "Mercury Parser"** (descarga el contenido completo del artículo cuando el feed solo trae extracto). Útil pero requiere desplegar **Mercury Parser API** como sidecar; el homelab lo difiere — los feeds técnicos modernos suelen exponer entry full o el operador hace click en el link para leer en el sitio original con Mealie/Linkding capturando el snapshot.
- **Newsletter-by-email-to-RSS bridge** (Kill the Newsletter, RSS-Bridge). Diferido a una iteración posterior; es un servicio separado con sus propios problemas de IMAP/SMTP. Anotado en `Decisiones que no se toman`.
- **Sync con Pocket / Wallabag** como "leer luego". Hay extensión `Wallabag Save` que envía un entry seleccionado a Wallabag; Wallabag no está desplegado en el homelab, así que **no aplica**. El equivalente en este homelab es: si el operador quiere archivar un artículo enlazado desde un feed, lo guarda en Linkding (con snapshot HTML), no en FreshRSS.

Cuando este documento se haya aplicado:

- `https://freshrss.${DOMAIN_LAN}/` muestra la UI con cert de la CA interna.
- El primer hit redirige al operador a Authelia (login + TOTP). Tras autenticar, Apache extrae el `preferred_username` del `id_token`, lo inyecta como `REMOTE_USER`, y FreshRSS crea automáticamente la cuenta del operador (con permisos admin: el primer usuario en FreshRSS siempre se promueve a admin).
- La cuenta `admin` local (creada en bootstrap con `auth_type=form`) queda con password aleatoria (KeePassXC offline) **o** se elimina tras validar OIDC; el operador opta por **mantenerla** como contingencia.
- El operador sube su `subscriptions.opml` exportado de Feedly/Inoreader y FreshRSS importa 300–800 feeds en bloque; el primer refresh tarda 5–10 min pero se ejecuta en background, la UI sigue navegable.
- Cada usuario tiene su SQLite en `/mnt/hd2t/apps/freshrss/data/users/<user>/db.sqlite`; los feeds favicon en `data/users/<user>/favicons/`; las extensiones comunes en `/mnt/hd2t/apps/freshrss/extensions/`.
- Borgmatic respalda diariamente cada SQLite con `VACUUM INTO` consistente (T1: las suscripciones y los entries marcados como `starred` son contenido del operador, no derivable; los entries no leídos se pueden reconstruir refrescando, pero tomaría tiempo).
- En el móvil, **Reeder 5** (iOS) o **FeedMe** (Android) configurados con `https://freshrss.lan/api/greader.php` + usuario + API password leen los feeds desde la LAN y vía Tailscale fuera de casa.
- Uptime Kuma tiene un monitor HTTPS sobre `https://freshrss.lan/i/?c=auth&a=login` con alerta Telegram + email.

> **Recordatorio de alcance**: FreshRSS es **solo LAN + Tailscale**. **No publica `ports:` al host**, **no se expone a Internet**, **no usa Let's Encrypt**. La app móvil habla con `https://freshrss.lan` directamente cuando el operador está en LAN; vía Tailscale, MagicDNS resuelve el mismo nombre desde fuera de casa (siempre y cuando el dispositivo tenga la CA interna instalada — sin ella, las apps Fever/GReader fallan al validar el cert con `SSL handshake failed`).

---

## Requisitos Previos

- **Fase 2** completa: Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN=lan`, `LAN_IP=192.168.1.10`.
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre `freshrss.${DOMAIN_LAN}` sin tocar Pi-hole).
  - Caddy con los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` definidos.
- **Fase 4** completa, en particular:
  - Authelia desplegado **con OIDC habilitado**. FreshRSS consume OIDC vía `mod_auth_openidc` dentro del contenedor (no `forward_auth` desde Caddy: Apache se encarga del flujo OIDC end-to-end).
  - El **client OIDC** `freshrss` registrado en `configuration.yml` de Authelia (ver "Configuración → 2. Registrar el client OIDC en Authelia"), como **cliente confidencial** con `client_secret`.
  - Los **grupos de Authelia** `freshrss-users` y `freshrss-admins` existen en el backend (file backend o LDAP) y el operador pertenece a `freshrss-admins`.
- **Fase 7** completa: Borgmatic operativo con `homelab.backup=true` como discriminador. Las SQLite de cada usuario se respaldan con un hook `before_backup` que itera sobre `data/users/*/db.sqlite`.
- **Operador** con la **CA interna instalada** en navegador (PC + móvil) y, **muy importante**, en el almacén del **sistema operativo** del móvil donde corren las apps Fever/GReader (Reeder, FeedMe). Las apps móviles **no** comparten trust store con el navegador del sistema en Android; iOS sí (perfil de configuración instalado a nivel sistema). Sin la CA, la sincronización falla con `SSL_CERTIFICATE_INVALID` o equivalente.
- **Disco `hd2t`** montado en `/mnt/hd2t` con al menos **3 GiB** libres reservados para FreshRSS:
  - `data/users/<user>/db.sqlite`: 50–500 MiB con varios meses de entries acumulados (cada entry ronda 2–10 KiB de texto en BBDD; con 500 feeds × ~50 entries/feed/mes y `keep_max=1000` por feed, son ~25 millones * 5 KiB ÷ 1000 ≈ ~125 MiB por usuario en estado estacionario).
  - `data/users/<user>/favicons/`: ~16 KiB × N feeds. Insignificante (<10 MiB).
  - `extensions/`: ~50 MiB con todas las extensiones populares.
  - Margen + dumps Borg + crecimiento: ~3 GiB sobrados a 5 años.
- Una contraseña aleatoria larga (`openssl rand -base64 30`) para la cuenta `admin` local creada en bootstrap (cuenta de contingencia).
- Un `client_secret` de OIDC generado **una vez** (`openssl rand -hex 32`) para el cliente confidencial `freshrss` registrado en Authelia.

Comprobaciones rápidas:

```bash
# La red Docker compartida existe
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Caddy y Authelia corriendo
docker ps --filter name=caddy --filter name=authelia --format '{{.Names}} {{.Status}}'

# freshrss.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short freshrss.lan @192.168.1.2
# 192.168.1.10

# Espacio en hd2t
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'

# Authelia tiene OIDC habilitado y los grupos definidos
docker exec authelia grep -E '^identity_providers:|freshrss-' /config/configuration.yml | head
```

---

## Decisión: imagen y versión

FreshRSS publica su imagen oficial en Docker Hub como `freshrss/freshrss`, con manifests multi-arch (`amd64`, `arm64`, `arm/v7`). En la Pi 5 (aarch64) se usa el manifest `arm64`. La imagen contiene **PHP-FPM + Apache** (con `mod_auth_openidc`, `mod_rewrite` y `mod_headers`) + **supercronic** (cron en user-space, sin necesidad de `cron` o `systemd-timer`) en una sola unidad — un solo contenedor, sin sidecar de cron ni nginx separado.

| Tag | Cuándo usar | Decisión aquí |
|---|---|---|
| `latest` | Demos, primera prueba. | Descartado (convención de Fase 2: tags exactos). |
| `edge` | Builds nightly contra `dev`. | Descartado: rompe sin previo aviso (FreshRSS evoluciona schema en `dev`). |
| `1` | Major track. | Descartado: avanza con cada minor. |
| `1.24` | Minor track (parcheo). | Descartado: prefiero tag exacto para auditoría. |
| `1.24.3` (ejemplo de tag exacto) | Reproducibilidad estricta. | **Aceptado**. |
| `1.24.3-arm` | Variante histórica para arm/v7. | Descartado: el manifest multi-arch del tag base ya elige `arm64` automáticamente. |
| `1.24.3-alpine` | Base alpine (~80 MiB menos). | Descartado: la diferencia es irrelevante en hd2t y la base Debian-slim trae `mod_auth_openidc` con menos sorpresas (el binding de OIDC en alpine ha tenido issues). |

> **Tag exacto en uso**: `freshrss/freshrss:1.24.3`. Si en el momento de aplicar este documento existe una `1.24.x` superior con changelog limpio (sin migración mayor de schema), se actualiza el tag aquí y en el `docker-compose.yml`, y se anota en el commit. **Nunca `latest`**, **nunca `edge`**.

> **Por qué FreshRSS y no Tiny Tiny RSS, Miniflux, Selfoss o CommaFeed**.
> - **Tiny Tiny RSS (TT-RSS)**: histórico, robusto, pero el desarrollo upstream se mueve por commits "rolling" sin releases tagged; la imagen Docker oficial es `latest` o `:edge`. No encaja con la convención del homelab de tags exactos. La UI sigue siendo de 2010 (sin móvil decente sin themes).
> - **Miniflux**: minimalista (Go binary único, Postgres obligatorio, sin extensiones, sin Fever/GReader API en algunas versiones). Excelente si la prioridad es "leer en pantalla y nada más"; queda corto para apps móviles maduras y para el operador que quiere extensiones tipo `Mercury Parser`. Reabrible si el operador busca minimalismo.
> - **Selfoss**: PHP también, más simple que FreshRSS, pero menos activo (releases esporádicas, comunidad pequeña). API limitada.
> - **CommaFeed**: Java/Spring Boot, pesado en RAM (~300 MiB), HSQLDB o Postgres. Sobreingeniería para el caso de uso.
> - **Newsboat**: CLI-only. Útil para el operador en terminal pero no para el resto de la familia ni para móvil. Compatible como cliente extra (Newsboat puede leer feeds via FreshRSS GReader API).
> - **FreshRSS**: punto de equilibrio: PHP+Apache+SQLite (~150 MiB en idle), `mod_auth_openidc` integrado, Fever + GReader API estables y ampliamente soportadas por apps móviles, OPML import, multi-usuario, extensiones, multi-arch arm64 estable, comunidad activa. **Decidido**.

> **Por qué tag exacto y no `:1.24`**. FreshRSS hace migraciones de schema entre minors (ej. 1.20 → 1.21 movió la auth para soportar OIDC nativo, 1.23 → 1.24 ajustó la tabla de entries). Un tag flotante puede dejar la SQLite en estado intermedio si el contenedor se cae a media migration. Con tag exacto las actualizaciones son **deliberadas**: el operador lee el changelog, hace `borgmatic create --tag pre-freshrss-upgrade-X.Y.Z`, edita el tag, `up -d`, valida con un par de feeds. Watchtower **deshabilitado** para este stack.

---

## Decisión: cómo se expone FreshRSS

FreshRSS corre **Apache + mod_php** dentro del contenedor, escuchando en `:80` (HTTP plano; el TLS lo termina Caddy delante).

| Opción | Cómo se ve | Discusión |
|---|---|---|
| `network_mode: host` | FreshRSS ata `:80` directamente. | Choca con Caddy (que ya ata `:80/:443`). Descartado. |
| Bridge `homelab` con `ports: ["8080:80"]` | Acceso directo desde la LAN sin pasar por Caddy. | HTTP plano sin TLS y sin cookie segura; el flujo OIDC interno con `mod_auth_openidc` requiere HTTPS estricto (cookies `SameSite=None; Secure`). Descartado. |
| Bridge `homelab` con `expose: 80`, **sin `ports:`** | FreshRSS alcanzable solo dentro de la red Docker, vía DNS (`freshrss:80`). Caddy hace `reverse_proxy http://freshrss:80`. | Termina TLS en Caddy con la CA interna. Patrón establecido. **Aceptado**. |

Resultado: `expose: 80` en el compose (no `ports:`), un drop-in `stacks/caddy/conf.d/45-freshrss.caddy` que hace `reverse_proxy http://freshrss:80`, y todo el tráfico externo pasa por `https://freshrss.${DOMAIN_LAN}/` con cert de la CA interna.

> **Sobre WebSocket / SSE**. FreshRSS **no** usa WebSocket. El refresh de la UI es polling AJAX cada N segundos (configurable por usuario). El reverse proxy estándar de Caddy basta sin directivas adicionales.

> **Sobre el subpath**. FreshRSS soporta servirse en un subpath (ej. `https://lan/freshrss/`) ajustando `BASE_URL`, pero los URLs absolutos en feeds favoritos exportados, en links compartidos y en redirecciones OIDC se complican. **No** se usa: convención del homelab es **un subdominio por servicio** (Fase 3).

> **Sobre `BASE_URL` (`FRESHRSS_ENV` + Apache rewrite)**. La imagen oficial respeta `TRUSTED_PROXY` y reconstruye URLs absolutas con `X-Forwarded-Proto`, `X-Forwarded-Host`. Si Caddy no manda esas cabeceras, FreshRSS construye links absolutos con `http://freshrss:80/...` y el flujo OIDC vuelve a Authelia con `redirect_uri` interno (que Authelia rechaza con `redirect_uri_mismatch`). El drop-in 45 manda `X-Forwarded-Proto`, `X-Forwarded-Host` y `X-Forwarded-For` explícitamente.

---

## Decisión: autenticación — Apache mod_auth_openidc + API password para apps móviles

FreshRSS tiene tres tipos de cliente:

1. **Navegador humano** sobre la UI web — auth interactiva.
2. **Apps móviles RSS** (Reeder, FeedMe, FluentReader, NetNewsWire, etc.) — auth no interactiva con `username + password` por endpoints `/api/fever.php` o `/api/greader.php`.
3. **Scripts del operador** vía API REST — mismo canal que las apps móviles (FreshRSS no tiene una "API REST moderna" tipo OpenAPI; las apps usan Fever/GReader).

| Componente | Patrón de auth | Justificación |
|---|---|---|
| UI web (`/i/...`, `/p/...`, `/`) | **OIDC contra Authelia** (vía `mod_auth_openidc` dentro del contenedor) + FreshRSS configurado con `auth_type=http_auth` | El operador entra desde un navegador; flujo OIDC interactivo con TOTP; SSO real con Mealie, Bookstack, Linkding y Paperless. |
| API Fever (`/api/fever.php`) | **API password de FreshRSS** (no OIDC, **bypass** explícito en la config Apache) | Las apps móviles no pueden hacer flujos OAuth interactivos. La API password se genera **una vez** en `Configuración → Perfil → API` tras login OIDC. |
| API Google Reader (`/api/greader.php`) | **API password de FreshRSS** (igual que Fever, **bypass** OIDC) | Misma razón. La auth GReader sí soporta OAuth pero las apps existentes no lo usan; usan ClientLogin con username + password. |
| Healthcheck (`/i/?c=auth&a=login`) | **Sin auth** (HTTP 200 abierto) | El healthcheck del contenedor y Uptime Kuma necesitan llegar sin token. La página de login sigue siendo `/i/?c=auth`; al verla en HTML 200 confirma que PHP + Apache + SQLite están vivos. |

`mod_auth_openidc` es un cliente OIDC **confidencial** clásico (Apache server-side, con `client_secret` en disco). En Authelia se registra con `public: false` + `client_secret` (idéntico patrón a Bookstack, Paperless-ngx).

Resultado: registro de un client `freshrss` en `configuration.yml` de Authelia con `client_secret`, `redirect_uris: ["https://freshrss.${DOMAIN_LAN}/oidc-redirect"]`, `scopes: [openid, profile, email, groups]`. La imagen oficial expone variables `OIDC_*` que se traducen a directivas Apache en `/etc/apache2/conf-enabled/oidc.conf` durante el `entrypoint`.

> **Sobre el grupo `freshrss-users` vs `freshrss-admins`**. FreshRSS no tiene un sistema RBAC con grupos OIDC nativo: la única distinción interna es **admin** (el primer usuario creado o quien tiene `is_admin=1` en su perfil) y **usuario regular**. El homelab usa los grupos de Authelia como **filtro de acceso** (Authelia rechaza con 403 a quien no esté en `freshrss-users` ni en `freshrss-admins`); la promoción a admin dentro de FreshRSS se hace **manualmente** por el operador desde la UI (`Administración → Gestionar usuarios → <user> → Promover a admin`).

> **Sobre la cuenta admin local de FreshRSS**. La imagen oficial crea automáticamente una cuenta admin al primer arranque si se setean `ADMIN_EMAIL`, `ADMIN_PASSWORD` y `ADMIN_API_PASSWORD`. **Riesgo crítico** si quedaran las defaults — cualquier persona en la LAN podría entrar. El bootstrap (sección "Despliegue") **fija explícitamente** un random largo, lo guarda en KeePassXC offline, y solo es accesible si se cambia `auth_type=form` temporalmente. En operación normal `auth_type=http_auth`, así que la cuenta admin local **no aparece** en el formulario de login.

> **Sobre la API password**. Cuando un usuario entra a la UI vía OIDC y va a `Configuración → Perfil → Acceso a la API`, FreshRSS genera (o se le pide al usuario que genere) una **API password** independiente de su password de UI. Esa password se hashea con `bcrypt` en la SQLite del usuario; las apps móviles la mandan sobre HTTPS (autenticadas vía Basic Auth o como query param dependiendo de la app). **No** pasa por OIDC ni por Authelia — es un endpoint API directo, **bypass** explícito en `<Location /api/>` de Apache.

> **Sobre el auto-provisioning del usuario OIDC**. La imagen oficial soporta `OIDC_REMOTE_USER_CLAIM=preferred_username` (qué claim del id_token usar como nombre de usuario en FreshRSS) y, vía `OIDC_FORCE_USER`, fuerza el `REMOTE_USER` desde Apache. FreshRSS con `auth_type=http_auth` confía ciegamente en `REMOTE_USER` — si no existe el usuario, lo crea automáticamente con `default_user` como template (config heredada del primer admin: misma zona horaria, mismo idioma, misma página de inicio, **sin** suscripciones — cada uno empieza con OPML vacío).

---

## Decisión: persistencia y base de datos

FreshRSS soporta tres backends: **SQLite** (default), **MariaDB/MySQL** y **PostgreSQL**. Para 1–5 usuarios y el volumen doméstico esperado (~500 feeds/usuario, ~25 millones de entries acumulados a 5 años entre todos), SQLite es el camino más simple — exactamente como en Vaultwarden, Linkding y Mealie.

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| **SQLite** (`/var/www/FreshRSS/data/users/<user>/db.sqlite`, **un fichero por usuario**) | Cero piezas adicionales, snapshot consistente con `VACUUM INTO` por usuario, ficheros independientes (un usuario corrupto no toca los demás), mismo patrón que Vaultwarden / Linkding / Mealie. | Worse para >50 usuarios concurrentes refrescando feeds masivamente. No es el caso doméstico. | **Aceptado**. |
| MariaDB | Mejor concurrencia, índices más finos para búsquedas full-text. | Otro contenedor (`freshrss-db`), otra contraseña, ~120–180 MiB de RAM extra, hook `mariadb_databases` (más complejo). | Sobreingeniería para 1–5 usuarios. Descartado. |
| PostgreSQL | Idem MariaDB pero con FTS nativo. | Idem coste; FTS no es bloqueante en este caso. | Descartado. |

Resultado: SQLite, **un fichero por usuario**, en `/mnt/hd2t/apps/freshrss/data/users/<user>/db.sqlite`. FreshRSS configura cada SQLite con `journal_mode=WAL`. El hook `before_backup` de Borgmatic itera sobre los usuarios y ejecuta `VACUUM INTO` por cada SQLite — patrón equivalente al de Vaultwarden/Linkding/Mealie pero con un `for` por la lista de usuarios (típicamente 2–4).

FreshRSS guarda cinco tipos de estado:

1. **BBDD relacional por usuario** — feeds, categorías, entries, favoritos, filtros, API password hashada. En SQLite (`users/<user>/db.sqlite`).
2. **Configuración por usuario** — `users/<user>/config.php` (zona horaria, idioma, modo de lectura, intervalos de refresh). PHP serializado.
3. **Favicons** — `users/<user>/favicons/<feed_id>.ico`. Filesystem.
4. **Configuración global** — `data/config.php` (auth_type, BBDD, secret de cookies, lista de admins). PHP serializado.
5. **Extensiones** — `extensions/<extension_name>/` con código PHP. Filesystem, instalable desde la UI o vía `cli/`.

| Aspecto | Decisión | Por qué |
|---|---|---|
| BBDD | SQLite con WAL, **una por usuario**, en `/mnt/hd2t/apps/freshrss/data/users/<user>/db.sqlite`. | Suficiente para 1–5 usuarios; respaldable con `VACUUM INTO` por usuario. |
| Config global y por usuario | Bind mount al subdirectorio `data/` en `/mnt/hd2t/apps/freshrss/`. | Datos respaldables como ficheros (PHP serializado, pequeño). |
| Favicons | Bind mount en `data/users/<user>/favicons/`. **Se respaldan** (T2: regenerables refrescando, pero la primera vez tras restore es lento). | Tiered como T2 (recreable pero costoso). |
| Extensiones | Bind mount en `/mnt/hd2t/apps/freshrss/extensions/`. **Se respalda**. | El operador puede haber configurado extensiones específicas; reproducir desde upstream tras restore es manual. |
| Snapshot consistente BBDD | `for u in users/*; do sqlite3 $u/db.sqlite 'VACUUM INTO ...'; done` vía hook `before_backup`. | Atómico, no requiere parar el contenedor; mismo patrón Vaultwarden / Linkding / Mealie pero con loop. |

> **Por qué no parar el contenedor para hacer backup**. FreshRSS poléa feeds en background (cron interno cada 30 min). Parar el contenedor durante el backup implica saltar uno de los slots de polling. Con `VACUUM INTO` el backup es online y consistente. El cron interno respeta el lockfile estándar de SQLite (no hay corrupción si se ejecuta concurrente con el `VACUUM INTO`).

> **Sobre `data/users/<user>/db.sqlite-wal` y `-shm`**. SQLite con WAL deja dos sidecar files pequeños (`-wal`, `-shm`). Borg los **excluye** explícitamente del archive porque pueden tener escrituras pendientes; el `VACUUM INTO` en un fichero aparte (`db.snapshot.sqlite`) garantiza consistencia. Mismo patrón documentado para Vaultwarden, Linkding y Mealie.

---

## Stack: `stacks/freshrss/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/freshrss/docker-compose.yml` | microSD (git) | Stack (FreshRSS único contenedor con cron interno). |
| `stacks/freshrss/.env.example` | microSD (git) | Plantilla con `OIDC_*`, `ADMIN_*` y password del admin de bootstrap. |
| `stacks/freshrss/.env` | microSD (NO git) | Versión rellena con secretos reales. Modo `0600`. |
| `stacks/freshrss/scripts/borg-pre-backup.sh` | microSD (git) | Hook `before_backup`: itera sobre usuarios y hace `VACUUM INTO` por SQLite. |
| `stacks/caddy/conf.d/45-freshrss.caddy` | microSD (git) | Drop-in Caddy para `freshrss.${DOMAIN_LAN}`. |
| `/mnt/hd2t/apps/freshrss/data/` | hd2t | `config.php` global, `users/<user>/{db.sqlite,config.php,favicons/}`. **Se respalda** (excluyendo `*.sqlite-wal`, `*.sqlite-shm`). |
| `/mnt/hd2t/apps/freshrss/extensions/` | hd2t | Extensiones third-party. **Se respalda**. |
| `/mnt/hd2t/apps/freshrss/dumps/` | hd2t | `<user>.snapshot.sqlite` generados por el hook. **Se respalda**. |

### `stacks/freshrss/docker-compose.yml`

```yaml
# FreshRSS — agregador RSS/Atom autohospedado.
# Convenciones: ver docs/02-docker/02-estructura-compose.md y
# docs/11-productividad/07-freshrss.md.

name: freshrss

x-restart: &default-restart
  restart: unless-stopped

services:

  freshrss:
    image: freshrss/freshrss:1.24.3
    container_name: freshrss
    hostname: freshrss
    <<: *default-restart

    environment:
      # Usuario del proceso. La imagen LSIO-style respeta PUID/PGID.
      # PUID 1000:1000 alinea con el dueño del bind mount en hd2t.
      TZ: ${TZ}
      CRON_MIN: "*/30"            # refresco cada 30 min (default sano).

      # Confiar en la cabecera X-Forwarded-* de Caddy. Sin esto FreshRSS
      # construye URLs absolutas con http://freshrss:80/... y rompe OIDC
      # redirect_uri y los favicons en la UI.
      TRUSTED_PROXY: "172.30.10.0/24"

      # auth_type fijo en http_auth: la auth real la hace mod_auth_openidc.
      # FreshRSS confía en REMOTE_USER que Apache inyecta tras OIDC.
      # En bootstrap se arranca con FRESHRSS_INSTALL_AUTH=form para crear
      # la cuenta admin local; tras eso se pasa a http_auth.
      FRESHRSS_INSTALL_AUTH: ${FRESHRSS_AUTH:-http_auth}

      # Idioma y timezone por defecto del usuario default (template).
      FRESHRSS_INSTALL_DEFAULT_USER_LANGUAGE: es
      FRESHRSS_INSTALL_DEFAULT_USER_TZ: ${TZ}

      # Cuenta admin local creada al primer arranque. SOLO se usa para
      # bootstrap y como contingencia "Authelia roto". Random largos,
      # guardados en KeePassXC offline.
      ADMIN_EMAIL: ${FRESHRSS_ADMIN_EMAIL}
      ADMIN_PASSWORD: ${FRESHRSS_ADMIN_PASSWORD}
      ADMIN_API_PASSWORD: ${FRESHRSS_ADMIN_API_PASSWORD}

      # ---------- OIDC ----------
      # mod_auth_openidc se activa con OIDC_ENABLED=1 en la imagen oficial.
      # El entrypoint genera /etc/apache2/conf-enabled/oidc.conf desde
      # estas variables.
      OIDC_ENABLED: "1"
      OIDC_PROVIDER_METADATA_URL: https://auth.${DOMAIN_LAN}/.well-known/openid-configuration
      OIDC_CLIENT_ID: freshrss
      OIDC_CLIENT_SECRET: ${OIDC_CLIENT_SECRET}
      OIDC_REMOTE_USER_CLAIM: preferred_username
      OIDC_SCOPES: "openid profile email groups"
      OIDC_X_FORWARDED_HEADERS: "X-Forwarded-Host X-Forwarded-Port X-Forwarded-Proto"

      # CA interna: mod_auth_openidc valida el cert del IdP. Apunta al
      # bundle PEM montado read-only.
      OIDC_CRYPTO_PASSPHRASE: ${OIDC_CRYPTO_PASSPHRASE}

    networks:
      - homelab               # Caddy llega por aquí

    expose:
      - "80"
    # NO `ports:`. Acceso solo vía Caddy.

    volumes:
      - /mnt/hd2t/apps/freshrss/data:/var/www/FreshRSS/data
      - /mnt/hd2t/apps/freshrss/extensions:/var/www/FreshRSS/extensions
      # Carpeta para los snapshots SQL (VACUUM INTO) que respalda Borg.
      - /mnt/hd2t/apps/freshrss/dumps:/var/www/FreshRSS/dumps
      # Hook de pre-backup montado read-only para que Borgmatic pueda
      # invocarlo via `docker exec`.
      - /home/homelab/homelab/stacks/freshrss/scripts/borg-pre-backup.sh:/usr/local/bin/borg-pre-backup.sh:ro
      # CA interna disponible al proceso para que mod_auth_openidc valide
      # auth.lan/.well-known/openid-configuration sin --insecure.
      - /mnt/hd2t/apps/caddy/etc/ca/homelab-ca.crt:/etc/ssl/certs/homelab-ca.crt:ro

    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://127.0.0.1/i/?c=auth >/dev/null || exit 1"]
      interval: 60s
      timeout: 10s
      retries: 5
      start_period: 60s

    security_opt:
      - "no-new-privileges:true"

    labels:
      homelab.role: "rss"
      homelab.backup: "true"
      com.centurylinklabs.watchtower.enable: "false"

networks:
  homelab:
    external: true
```

> **Sobre el `start_period: 60s`**. El primer arranque ejecuta el `install.php` automatizado (crea SQLite global, crea `data/config.php`, crea la cuenta admin), luego Apache arranca con `mod_auth_openidc`. En la Pi 5 esto tarda 30–45 s. Si el periodo es más corto, Compose marca el contenedor como unhealthy antes de tiempo.

> **Sobre `OIDC_CRYPTO_PASSPHRASE`**. `mod_auth_openidc` cifra las cookies de sesión OIDC con un secret simétrico (no el `client_secret`). Si se pierde, las sesiones existentes invalidan (los usuarios se relogan); no es destructivo. Generar **una vez** con `openssl rand -hex 32` y guardar en `.env`.

> **Sobre `TRUSTED_PROXY` con CIDR**. FreshRSS valida que `X-Forwarded-Proto` venga de una IP en el rango especificado. La red `homelab` es `172.30.10.0/24`; Caddy desde dentro de esa red es siempre confiable. Sin esto, FreshRSS ignora `X-Forwarded-Proto` y construye `http://...` URLs.

### `stacks/freshrss/.env.example`

```bash
# stacks/freshrss/.env.example
# Variables específicas del stack FreshRSS. Las generales (TZ, PUID, PGID,
# DOMAIN_LAN) viven en el .env GLOBAL.

# ---------- Cuenta admin local de bootstrap ----------
# Creada automáticamente al primer arranque. Tras configurar OIDC se accede
# a ella SOLO si se cambia FRESHRSS_AUTH=form temporalmente. Random largos,
# pegar en KeePassXC offline:
#   openssl rand -base64 30   # FRESHRSS_ADMIN_PASSWORD
#   openssl rand -hex 32      # FRESHRSS_ADMIN_API_PASSWORD
FRESHRSS_ADMIN_EMAIL=admin-local@homelab.lan
FRESHRSS_ADMIN_PASSWORD=CHANGEME_RANDOM_30_BASE64
FRESHRSS_ADMIN_API_PASSWORD=CHANGEME_RANDOM_64_HEX

# ---------- auth_type ----------
# Bootstrap: dejar `form` para crear la cuenta admin local. Tras OIDC
# configurado, cambiar a `http_auth` y restart.
FRESHRSS_AUTH=form

# ---------- OIDC ----------
# Cliente confidencial registrado en Authelia (configuration.yml).
# El client_secret debe coincidir EXACTAMENTE entre Authelia y este fichero.
#   openssl rand -hex 32
OIDC_CLIENT_SECRET=CHANGEME_DEL_CLIENT_REGISTRADO_EN_AUTHELIA

# Passphrase de cifrado de cookies OIDC dentro de mod_auth_openidc.
# Cambiarla invalida sesiones (usuarios se relogan vía OIDC; no destructivo).
#   openssl rand -hex 32
OIDC_CRYPTO_PASSPHRASE=CHANGEME_64_HEX
```

### `stacks/caddy/conf.d/45-freshrss.caddy`

```caddy
# /etc/caddy/conf.d/45-freshrss.caddy — bloque LAN para FreshRSS.
# UI + API + endpoints OIDC en http://freshrss:80 dentro de `homelab`.
# Auth UI: OIDC contra Authelia (vía mod_auth_openidc dentro del contenedor;
# Caddy NO aplica forward_auth, el flujo OIDC es end-to-end PHP/Apache).
# Auth API (/api/fever.php, /api/greader.php): API password de FreshRSS,
# bypass explícito de OIDC en la config Apache.
# Documentado en docs/11-productividad/07-freshrss.md.

freshrss.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # OPML import puede ser grande (Feedly export con 1000 feeds y todas
    # sus carpetas como atributos puede pasar de 5 MiB).
    request_body {
        max_size 50MB
    }

    reverse_proxy http://freshrss:80 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}
        header_up X-Forwarded-Port {server_port}
    }
}
```

> **Sobre `X-Forwarded-Port`**. `mod_auth_openidc` construye `redirect_uri` con `proto://host:port/oidc-redirect`. Si `port` viene como `80` desde Apache (port interno) en vez de `443` desde Caddy (port externo), el `redirect_uri` queda como `https://freshrss.lan:80/oidc-redirect` y Authelia rechaza. La cabecera `X-Forwarded-Port` + `OIDC_X_FORWARDED_HEADERS` resuelven el mismatch.

> **Sobre `request_body max_size`**. Sin esto, el OPML de Feedly (que incluye `<outline ...>` con todos los feeds + atributos) llega a 5–15 MiB en operadores con muchos feeds. Caddy con default 10 MiB falla con `413`.

### `stacks/freshrss/scripts/borg-pre-backup.sh`

```bash
#!/usr/bin/env bash
# stacks/freshrss/scripts/borg-pre-backup.sh
# Hook `before_backup` de Borgmatic: snapshot consistente de cada SQLite
# (una por usuario) vía `VACUUM INTO`. Mismo patrón que Vaultwarden,
# Linkding y Mealie, con un loop sobre los usuarios.

set -euo pipefail

USERS_DIR="/var/www/FreshRSS/data/users"
DUMPS_DIR="/var/www/FreshRSS/dumps"

mkdir -p "$DUMPS_DIR"

# Limpiar snapshots de usuarios borrados (housekeeping idempotente).
find "$DUMPS_DIR" -maxdepth 1 -name '*.snapshot.sqlite' -print0 | \
while IFS= read -r -d '' snap; do
    user=$(basename "$snap" .snapshot.sqlite)
    if [ ! -d "$USERS_DIR/$user" ]; then
        rm -f "$snap"
        echo "[borg-pre-backup] freshrss: limpiado snapshot huérfano de '$user'"
    fi
done

# Snapshot por usuario activo.
for user_dir in "$USERS_DIR"/*/; do
    user=$(basename "$user_dir")
    # Saltar el directorio interno `_` que FreshRSS usa para defaults.
    [ "$user" = "_" ] && continue

    DB_SRC="$user_dir/db.sqlite"
    DB_OUT="$DUMPS_DIR/$user.snapshot.sqlite"

    [ -f "$DB_SRC" ] || continue

    # VACUUM INTO falla si el destino existe.
    rm -f "$DB_OUT"

    # VACUUM INTO es atómico desde SQLite 3.27 (2019). Mantiene la BBDD
    # viva (ningún lock global), genera un fichero limpio.
    sqlite3 "$DB_SRC" "VACUUM INTO '$DB_OUT';"

    chmod 0600 "$DB_OUT"
    echo "[borg-pre-backup] freshrss snapshot OK ($user): $(stat -c %s "$DB_OUT") bytes"
done
```

### Crear los directorios persistentes y desplegar

```bash
# 0) Asegurar el árbol de datos en hd2t (idempotente)
sudo install -d -o root -g root -m 0755 /mnt/hd2t/apps/freshrss

# FreshRSS corre como UID/GID 33:33 (www-data) en la imagen oficial.
sudo install -d -o 33 -g 33 -m 0750 /mnt/hd2t/apps/freshrss/data
sudo install -d -o 33 -g 33 -m 0750 /mnt/hd2t/apps/freshrss/extensions
sudo install -d -o 33 -g 33 -m 0750 /mnt/hd2t/apps/freshrss/dumps

# 1) Generar secretos UNA SOLA VEZ
openssl rand -base64 30   # → FRESHRSS_ADMIN_PASSWORD
openssl rand -hex 32      # → FRESHRSS_ADMIN_API_PASSWORD
openssl rand -hex 32      # → OIDC_CLIENT_SECRET (registrar en Authelia)
openssl rand -hex 32      # → OIDC_CRYPTO_PASSPHRASE

# 2) Materializar stacks/freshrss/.env
cd /home/homelab/homelab
set -a; source .env; set +a

cp stacks/freshrss/.env.example stacks/freshrss/.env
chmod 0600 stacks/freshrss/.env
# Editar y pegar los cuatro secretos. Dejar FRESHRSS_AUTH=form para bootstrap.

# 3) Drop-in de Caddy
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/45-freshrss.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/45-freshrss.caddy

# 4) Validar el Caddyfile
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
# Successful

# 5) Validar el compose
docker compose \
    -f stacks/freshrss/docker-compose.yml \
    --env-file stacks/freshrss/.env \
    config >/dev/null && echo "compose OK"

# 6) Levantar el stack en bootstrap (FRESHRSS_AUTH=form)
docker compose \
    -f stacks/freshrss/docker-compose.yml \
    --env-file stacks/freshrss/.env \
    up -d

# 7) Recargar Caddy
docker kill --signal=SIGUSR1 caddy
```

Tras `up -d`:

```bash
docker ps --filter name=freshrss --format 'table {{.Names}}\t{{.Status}}'
# freshrss             Up 1 minute (healthy)

# Logs del install (primer arranque)
docker logs freshrss 2>&1 | grep -E 'install|admin|cron|OIDC' | head
# [install] Creating data/config.php
# [install] Creating admin user 'admin-local'
# [supercronic] schedule: */30 * * * *
# [oidc] mod_auth_openidc enabled, provider=https://auth.lan/.well-known/openid-configuration
```

Si el contenedor `freshrss` no llega a `(healthy)` en 90 s, lo más probable es:
- UID 33 sin acceso a `/mnt/hd2t/apps/freshrss/data/` → logs muestran `Permission denied`.
- `OIDC_PROVIDER_METADATA_URL` apunta a un Authelia no resuelto (red Docker mal o `auth.lan` no en Pi-hole) → logs `mod_auth_openidc: failed to download metadata`.
- CA interna no inyectada → logs `mod_auth_openidc: certificate verify failed`.
- Disco hd2t lleno.

Comprobación de extremo a extremo:

```bash
# UI responde 200 con la página de login
curl -skI https://freshrss.lan/i/?c=auth
# HTTP/2 200

# Versión visible en el HTML del login
curl -sk https://freshrss.lan/i/?c=auth | grep -oE 'FreshRSS [0-9.]+' | head -1
# FreshRSS 1.24.3
```

---

## Configuración

### 1) Bootstrap: validar la cuenta admin local

Con `FRESHRSS_AUTH=form` la imagen ya creó al arranque la cuenta `admin-local` con `FRESHRSS_ADMIN_PASSWORD`. Verificar:

1. Entrar a `https://freshrss.lan/i/?c=auth&a=login`.
2. Login con `admin-local` / `<FRESHRSS_ADMIN_PASSWORD>`.
3. Pulsar el icono de usuario → `Configuración` → confirmar que `Tipo de autenticación` muestra "Formulario".
4. `Configuración → Perfil → Acceso a la API` → confirmar que la API password (`<FRESHRSS_ADMIN_API_PASSWORD>`) está activa para Fever/GReader.

> **Por qué no eliminar la cuenta admin local**. Es la cuenta de contingencia para "Authelia roto". Se mantiene con password rotada en KeePassXC offline. Para acceder en emergencia: `sed -i 's/FRESHRSS_AUTH=http_auth/FRESHRSS_AUTH=form/' stacks/freshrss/.env && docker compose ... up -d --force-recreate freshrss`.

### 2) Registrar el client OIDC `freshrss` en Authelia

En `/mnt/hd2t/apps/authelia/config/configuration.yml`, dentro de `identity_providers.oidc.clients`, añadir el bloque:

```yaml
identity_providers:
  oidc:
    # ... hmac_secret, issuer_private_key (ya definidos en 04-seguridad/01-authelia.md)
    clients:
      # ... otros clients existentes (mealie, bookstack, linkding, paperless, ...)
      - client_id: freshrss
        client_name: FreshRSS
        # CLIENTE CONFIDENCIAL: client_secret obligatorio.
        # El secret se compara hasheado: en Authelia se almacena el hash
        # bcrypt; el valor en claro vive solo en stacks/freshrss/.env.
        # Para Authelia >= 4.38: usar `client_secret: '$pbkdf2-sha512$...'`
        # generado con `authelia crypto hash generate pbkdf2 --variant sha512 --password '<secret-en-claro>'`.
        client_secret: '$pbkdf2-sha512$310000$....'
        public: false
        authorization_policy: two_factor
        redirect_uris:
          - https://freshrss.lan/oidc-redirect
        scopes:
          - openid
          - profile
          - email
          - groups
        userinfo_signed_response_alg: none
        token_endpoint_auth_method: client_secret_basic
        consent_mode: implicit
```

Asegurar también que los grupos `freshrss-users` y `freshrss-admins` existen en el backend de Authelia. Para el file backend (`/mnt/hd2t/apps/authelia/config/users_database.yml`):

```yaml
users:
  operator:
    displayname: "Operador"
    password: "$argon2id$..."
    email: operator@homelab.lan
    groups:
      - admins
      - freshrss-admins
      - freshrss-users
  pareja:
    displayname: "Pareja"
    password: "$argon2id$..."
    email: pareja@homelab.lan
    groups:
      - freshrss-users
```

Y, en `access_control.rules`, una regla que permita acceder solo a esos grupos (los demás reciben 403 de Authelia antes de llegar a FreshRSS):

```yaml
access_control:
  rules:
    # ... otras reglas
    - domain: "freshrss.lan"
      policy: two_factor
      subject:
        - "group:freshrss-users"
        - "group:freshrss-admins"
```

Recargar Authelia:

```bash
docker compose -f /home/homelab/homelab/stacks/authelia/docker-compose.yml \
    up -d --force-recreate
docker logs authelia 2>&1 | grep 'client_id=freshrss' | tail
# expected: "Provider: registered client" client_id=freshrss
```

> **Sobre la URL exacta de `redirect_uris`**. `mod_auth_openidc` construye el callback como `<FRESHRSS_ROOT>/oidc-redirect` (path fijo del módulo). Authelia es estricto: si la URL no coincide carácter a carácter (sin barra final tras `oidc-redirect`), rechaza con `redirect_uri_mismatch`.

### 3) Activar OIDC: cambiar `auth_type=http_auth` y reiniciar

Tras validar que Authelia tiene el client registrado y los grupos definidos:

```bash
sed -i 's/^FRESHRSS_AUTH=form/FRESHRSS_AUTH=http_auth/' \
    /home/homelab/homelab/stacks/freshrss/.env

docker compose -f /home/homelab/homelab/stacks/freshrss/docker-compose.yml \
    --env-file /home/homelab/homelab/.env \
    --env-file /home/homelab/homelab/stacks/freshrss/.env \
    up -d --force-recreate freshrss

# Esperar healthy
sleep 30
docker ps --filter name=freshrss --format '{{.Names}} {{.Status}}'
# freshrss   Up 30 seconds (healthy)
```

### 4) Primer login OIDC del operador

Tras el restart con `auth_type=http_auth`, abrir `https://freshrss.lan/` en el navegador del operador (con la CA interna instalada):

1. Apache redirige inmediatamente a `https://auth.lan/?rd=...&workflow=openid_connect`.
2. Authelia pide login + TOTP (política `two_factor`).
3. Authelia devuelve el `id_token` con claims `sub`, `email`, `name`, `groups: ["admins","freshrss-admins","freshrss-users"]`, `preferred_username: "operator"`.
4. `mod_auth_openidc` extrae `preferred_username=operator` y lo inyecta en `REMOTE_USER`.
5. FreshRSS, configurado con `auth_type=http_auth`, recibe `REMOTE_USER=operator`. El usuario `operator` no existe en FreshRSS → lo crea automáticamente (clonando los defaults del template `_`).
6. Sesión iniciada como `operator`. **Importante**: el operador es un usuario regular en FreshRSS (no admin) hasta que el `admin-local` lo promueva manualmente.

### 5) Promover al operador a admin de FreshRSS

Acceso *one-shot* con la cuenta admin local para promover al operador:

```bash
# (a) Cambiar temporalmente a auth_type=form
sed -i 's/^FRESHRSS_AUTH=http_auth/FRESHRSS_AUTH=form/' stacks/freshrss/.env
docker compose -f stacks/freshrss/docker-compose.yml \
    --env-file stacks/freshrss/.env \
    up -d --force-recreate freshrss

# (b) Login como admin-local en https://freshrss.lan/i/?c=auth&a=login
# (c) Administración → Gestionar usuarios → operator → Promover a admin
# (d) Logout

# (e) Volver a auth_type=http_auth
sed -i 's/^FRESHRSS_AUTH=form/FRESHRSS_AUTH=http_auth/' stacks/freshrss/.env
docker compose -f stacks/freshrss/docker-compose.yml \
    --env-file stacks/freshrss/.env \
    up -d --force-recreate freshrss
```

**Alternativa CLI** (preferida, sin tener que cambiar `auth_type` ida y vuelta):

```bash
docker exec -u www-data freshrss \
    php /var/www/FreshRSS/cli/update-user.php --user operator --is_admin yes
# User 'operator' updated.
```

### 6) Importar OPML de Feedly / Inoreader / Newsboat

**Vía UI** (recomendado para cuentas con <500 feeds):

1. Como `operator`, ir a `Configuración → Importar/Exportar`.
2. `Importar` → seleccionar el `subscriptions.opml` exportado (Feedly: `Settings → Import/Export → OPML export`; Inoreader: `Configuración → Importar/Exportar → OPML`).
3. Marcar `Importar las categorías` y `Mantener la jerarquía`.
4. `Enviar`. Tras unos segundos aparece "X feeds importados, Y categorías".
5. El primer refresh se dispara en background; los entries empiezan a poblarse en 1–5 min.

**Vía CLI** (para cuentas con >1000 feeds o para automatizar):

```bash
# Copiar el OPML al volumen del contenedor
sudo cp ~/feedly-export.opml /mnt/hd2t/apps/freshrss/data/import/operator.opml
sudo chown 33:33 /mnt/hd2t/apps/freshrss/data/import/operator.opml

# Ejecutar el importer
docker exec -u www-data freshrss \
    php /var/www/FreshRSS/cli/import-for-user.php \
    --user operator --filename /var/www/FreshRSS/data/import/operator.opml
# Imported 873 feeds, 142 categories for user 'operator'.

# Forzar el primer refresh inmediato (sin esperar al cron de */30)
docker exec -u www-data freshrss \
    php /var/www/FreshRSS/app/actualize_script.php > /tmp/freshrss-actualize.log 2>&1 &
```

> **Sobre el rate-limit del refresh inicial**. Refrescar 800 feeds en paralelo desde una sola IP (la de la Pi) puede triggerear rate-limits en algunos sitios (CloudFlare devuelve 429). FreshRSS hace requests **secuencialmente** por defecto; en una Pi 5 con conexión 600 Mbps esto tarda ~10 min para 800 feeds. Si se requiere rapidez, ajustar `feeds_in_parallel` en `data/config.php` a 5 (default 1) — más alto satura red doméstica.

### 7) Generar la API password para apps móviles

Cada usuario que quiera consumir feeds desde el móvil necesita su propia API password (independiente de la session OIDC):

1. Como ese usuario en la UI: `Configuración → Perfil → Acceso a la API`.
2. `Generar / cambiar` → FreshRSS muestra una password aleatoria de 16 caracteres alfanuméricos.
3. **Copiar inmediatamente** (la UI la muestra solo una vez en claro; se guarda hasheada con bcrypt).
4. Guardar en KeePassXC del operador o KeePass/Passwords del usuario.

### 8) Configurar app móvil (Reeder 5 / FeedMe)

| Campo (Reeder iOS) | Valor |
|---|---|
| Account Type | Fever (recomendado por simplicidad) **o** Google Reader compatible |
| Server URL | `https://freshrss.lan/api/fever.php` (Fever) **o** `https://freshrss.lan/api/greader.php` (GReader) |
| Username | `operator` (el username de FreshRSS, **no** el email) |
| Password | la API password de 16 caracteres |
| Refresh on launch | habilitado |
| Sync interval | 30 min (alineado con `CRON_MIN`) |

| Campo (FeedMe Android) | Valor |
|---|---|
| Provider | FreshRSS / Tiny Tiny RSS / Google Reader compatible |
| URL | `https://freshrss.lan/api/greader.php` |
| Username | `operator` |
| Password | la API password |

> **Sobre la CA interna en el móvil**. Las apps Reeder/FeedMe usan el trust store del **sistema operativo** del móvil (no el del navegador). Importar la CA via:
> - **iOS**: instalar perfil de configuración con Apple Configurator desde el Mac, o vía AirDrop con un `.mobileconfig` que el operador firma con la CA. `Settings → General → VPN & Device Management → Install`. Tras instalar, ir a `Settings → General → About → Certificate Trust Settings` y habilitar "Enable Full Trust" para la CA del homelab. Sin esto, las apps fallan con `kCFStreamErrorDomainSSL=-9802`.
> - **Android**: importar la CA en `Settings → Security → Encryption & credentials → Install a certificate → CA certificate`. Desde Android 7+, las apps por defecto **no confían en CA de usuario** (solo CA del sistema); requiere o bien rootear y mover a `/system/etc/security/cacerts/`, o bien configurar la app específicamente (algunas apps tienen "Trust user CAs" en su settings — Reeder Android no, FeedMe sí).

### 9) Forzar SSO por defecto y deshabilitar formulario residual

Tras validar que la familia entra sin fricción vía Authelia, no hay nada que cambiar — `auth_type=http_auth` ya redirige todo el tráfico de UI por OIDC. La cuenta `admin-local` queda **sin acceso desde la UI** mientras `auth_type=http_auth` esté activo (solo aparece como cuenta interna). Esa es la configuración objetivo.

### 10) Configurar el cron interno de polling

El cron interno (`supercronic`) ya corre con `CRON_MIN=*/30` (cada 30 min). Para confirmar:

```bash
docker exec freshrss ps -ef | grep -E 'supercronic|actualize'
# www-data ... supercronic /etc/freshrss/freshrss.cron
# www-data ... php /var/www/FreshRSS/app/actualize_script.php

docker logs freshrss --since 1h 2>&1 | grep -E 'actualize|fetched'
# [actualize_script] start
# [actualize_script] feed 'XKCD' fetched: 0 new entries
# ...
# [actualize_script] done in 142s
```

Para refrescos más frecuentes (ej. feeds técnicos cada 10 min): cambiar `CRON_MIN: "*/10"` en el compose. Tener en cuenta el rate-limit upstream en feeds populares (Reddit, GitHub releases) — `*/30` es el default sano del proyecto.

### 11) Integrar el snapshot SQLite en Borgmatic

En `/etc/borgmatic.d/borgmatic.yaml`:

```yaml
before_backup:
  # ... otros hooks (vaultwarden, linkding, mealie)
  - docker exec freshrss /usr/local/bin/borg-pre-backup.sh

source_directories:
  # ... otros directorios
  - /home/homelab/homelab
  - /mnt/hd2t/apps/freshrss/data
  - /mnt/hd2t/apps/freshrss/extensions
  - /mnt/hd2t/apps/freshrss/dumps

exclude_patterns:
  # ... otros excludes
  - '/mnt/hd2t/apps/freshrss/data/users/*/db.sqlite'         # se respalda el snapshot
  - '/mnt/hd2t/apps/freshrss/data/users/*/db.sqlite-wal'
  - '/mnt/hd2t/apps/freshrss/data/users/*/db.sqlite-shm'
  - '/mnt/hd2t/apps/freshrss/data/cache/'                    # cache HTTP de feeds (regenerable)
  - '/mnt/hd2t/apps/freshrss/data/import/'                   # OPML temporales
  - '/mnt/hd2t/apps/freshrss/data/tmp/'
```

Verificar:

```bash
sudo borgmatic config validate
# All configs valid

# Disparar el hook a mano
docker exec freshrss /usr/local/bin/borg-pre-backup.sh
# [borg-pre-backup] freshrss snapshot OK (operator): 32145678 bytes
# [borg-pre-backup] freshrss snapshot OK (pareja):   12345678 bytes

ls -lh /mnt/hd2t/apps/freshrss/dumps/
# -rw------- 1 33 33  31M ... operator.snapshot.sqlite
# -rw------- 1 33 33  12M ... pareja.snapshot.sqlite

# Dry-run completo
sudo borgmatic create --dry-run --list 2>&1 | grep -i freshrss | head
```

> **Sobre excluir `db.sqlite` del archive**. Como en Vaultwarden/Linkding/Mealie: la SQLite con WAL puede tener escrituras pendientes en `db.sqlite-wal` cuando Borg la copia "en frío"; el snapshot copiado puede quedar inconsistente. El hook `before_backup` genera un fichero `<user>.snapshot.sqlite` consistente, y el archive incluye **solo** esos. Mismo patrón documentado en `07-backups/02-borgmatic.md`.

### 12) Monitor en Uptime Kuma

En `https://uptime.${DOMAIN_LAN}/` añadir un **monitor HTTP(s)**:

| Campo | Valor |
|---|---|
| Friendly Name | `FreshRSS` |
| URL | `https://freshrss.lan/i/?c=auth&a=login` |
| Heartbeat Interval | 60 s |
| Retries | 3 |
| Accepted Status Codes | 200, 302 (redirect a Authelia) |
| Notification | Telegram + email (Mailrise cuando exista) |
| Public on status page | Sí |

`/i/?c=auth&a=login` responde 200 con el HTML del formulario de login (auth_type=form) o 302 a Authelia (auth_type=http_auth). En ambos casos confirma PHP + Apache + SQLite + reverse proxy vivos. **No** usar `/api/fever.php` o `/api/greader.php` directamente para health: ambas requieren auth y un GET sin params devuelve `200 {api_version: 0, auth: 0}` (sería válido pero menos legible).

### 13) Extensiones recomendadas (opcional)

Tras `Configuración → Extensiones → Sistema → Galería`, instalar:

| Extensión | Para qué |
|---|---|
| **Mark as read on scroll** | Marca como leído según el operador hace scroll por la lista, sin click manual. Imprescindible para listas largas. |
| **Tweaks** | Ajustes de UI (atajos de teclado custom, alineado de imágenes, etc.). |
| **YouTube video feed** | Reemplaza el thumbnail simple del feed de YouTube por un embed reproducible inline. |
| **Reading time** | Estima los minutos de lectura por entry. Útil cuando un feed mezcla artículos cortos y largos. |
| **Better Stars** | Permite tener varios "favorito" colors para clasificar entries marcados. |

Las extensiones se persisten en `/mnt/hd2t/apps/freshrss/extensions/` y sobreviven a upgrades de imagen.

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/freshrss/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/freshrss/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla versionada. |
| `/home/homelab/homelab/stacks/freshrss/.env` | microSD | `homelab:homelab` | `0600` | Secretos reales. **No** versionado. |
| `/home/homelab/homelab/stacks/freshrss/scripts/borg-pre-backup.sh` | microSD | `homelab:homelab` | `0750` | Hook de pre-backup. **Versionado**. |
| `/home/homelab/homelab/stacks/caddy/conf.d/45-freshrss.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in Caddy. **Versionado**. |
| `/mnt/hd2t/apps/caddy/etc/conf.d/45-freshrss.caddy` | hd2t | `homelab:homelab` | `0644` | Drop-in materializado. |
| `/mnt/hd2t/apps/freshrss/data/config.php` | hd2t | `33:33` | `0640` | Configuración global FreshRSS. **Sí se respalda**. |
| `/mnt/hd2t/apps/freshrss/data/users/<user>/db.sqlite` | hd2t | `33:33` | `0640` | SQLite live (WAL). **Excluido** del archive (se respalda el snapshot). |
| `/mnt/hd2t/apps/freshrss/data/users/<user>/db.sqlite-wal` | hd2t | `33:33` | `0640` | WAL de SQLite. **Excluido**. |
| `/mnt/hd2t/apps/freshrss/data/users/<user>/db.sqlite-shm` | hd2t | `33:33` | `0640` | Shared memory. **Excluido**. |
| `/mnt/hd2t/apps/freshrss/data/users/<user>/config.php` | hd2t | `33:33` | `0640` | Config por usuario (idioma, timezone, refresco). **Sí se respalda**. |
| `/mnt/hd2t/apps/freshrss/data/users/<user>/favicons/` | hd2t | `33:33` | `0750` | Favicons descargados. **Sí se respalda** (T2). |
| `/mnt/hd2t/apps/freshrss/data/cache/` | hd2t | `33:33` | `0750` | Cache HTTP intermedio (Last-Modified, ETag). **Excluido**. |
| `/mnt/hd2t/apps/freshrss/data/tmp/` | hd2t | `33:33` | `0750` | Temporales. **Excluido**. |
| `/mnt/hd2t/apps/freshrss/data/import/` | hd2t | `33:33` | `0750` | OPML temporales subidos. **Excluido**. |
| `/mnt/hd2t/apps/freshrss/extensions/` | hd2t | `33:33` | `0750` | Extensiones third-party. **Sí se respalda**. |
| `/mnt/hd2t/apps/freshrss/dumps/<user>.snapshot.sqlite` | hd2t | `33:33` | `0600` | Snapshot consistente generado por el hook. **Sí se respalda** (T1). |

> **Tamaño esperado a 5 años (3 usuarios activos, ~600 feeds/usuario, retención por defecto)**:
> - `data/users/<user>/db.sqlite`: ~150 MiB × 3 = ~450 MiB.
> - `data/users/<user>/favicons/`: ~10 MiB × 3 = ~30 MiB.
> - `extensions/`: ~50 MiB.
> - `dumps/`: ~mismo orden que las SQLite vivas.
> - Total: ~1 GiB. Sobrado en hd2t.

> **Sobre la retención de entries**. FreshRSS por defecto guarda **todos** los entries indefinidamente. Para evitar crecimiento descontrolado, configurar por feed `Configuración → Suscripciones → <feed> → Avanzado → Política de archivo`: típicamente **"mantener los últimos 1000 entries por feed"** o **"mantener entries de los últimos 6 meses"**. Aplicar como default en `Configuración → Configuración de archivado`.

---

## Backup

A nivel del repositorio del homelab:

| Artefacto | Estrategia |
|---|---|
| `stacks/freshrss/docker-compose.yml`, `.env.example`, `scripts/borg-pre-backup.sh` | Versionados en git. Reproducibles tras un reflasheo. |
| `stacks/caddy/conf.d/45-freshrss.caddy` | Versionado en git. |
| `stacks/freshrss/.env` (con secretos reales: `OIDC_CLIENT_SECRET`, `FRESHRSS_ADMIN_*`, `OIDC_CRYPTO_PASSPHRASE`) | **No** versionado. Respaldado por Borg como parte de `/home/homelab/homelab/`. |
| Decisiones (SQLite por usuario, OIDC vía mod_auth_openidc, grupos `freshrss-{users,admins}`, API password aparte) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | Tier | ¿Se respalda? | Por qué |
|---|---|---|---|
| `/mnt/hd2t/apps/freshrss/dumps/<user>.snapshot.sqlite` | T1 | **Sí** (vía hook `before_backup` con loop por usuario) | Fuente de verdad para restore. Atómico, consistente. |
| `/mnt/hd2t/apps/freshrss/data/config.php` | T1 | **Sí** | Configuración global (auth_type, lista admins, locale). |
| `/mnt/hd2t/apps/freshrss/data/users/<user>/config.php` | T1 | **Sí** | Configuración por usuario (idioma, refresco, atajos). |
| `/mnt/hd2t/apps/freshrss/data/users/<user>/favicons/` | T2 | **Sí** | Recreables refrescando, pero respaldarlos evita un primer-paint feo. |
| `/mnt/hd2t/apps/freshrss/extensions/` | T1 | **Sí** | Extensiones instaladas; reproducir tras restore es manual. |
| `/mnt/hd2t/apps/freshrss/data/users/<user>/db.sqlite` (live) | — | **Excluido** | Puede tener WAL pendiente; usar el snapshot. |
| `/mnt/hd2t/apps/freshrss/data/cache/`, `tmp/`, `import/` | — | **Excluido** | Volátiles. |

Patrón en `borgmatic.yaml`:

```yaml
before_backup:
  - docker exec freshrss /usr/local/bin/borg-pre-backup.sh

source_directories:
  - /home/homelab/homelab
  - /mnt/hd2t/apps/freshrss/data
  - /mnt/hd2t/apps/freshrss/extensions
  - /mnt/hd2t/apps/freshrss/dumps

exclude_patterns:
  - '/mnt/hd2t/apps/freshrss/data/users/*/db.sqlite'
  - '/mnt/hd2t/apps/freshrss/data/users/*/db.sqlite-wal'
  - '/mnt/hd2t/apps/freshrss/data/users/*/db.sqlite-shm'
  - '/mnt/hd2t/apps/freshrss/data/cache'
  - '/mnt/hd2t/apps/freshrss/data/tmp'
  - '/mnt/hd2t/apps/freshrss/data/import'
```

Verificación trimestral de restore (Fase 7, calendario Q3 → FreshRSS, ver `07-backups/03-backup-docker-volumes.md`):

```bash
# 1) Levantar un FreshRSS aislado en /tmp con datos restaurados
mkdir -p /tmp/drill-freshrss/{data,extensions}
sudo chown -R 33:33 /tmp/drill-freshrss

# 2) Restaurar los snapshots SQLite y la config global
sudo borg extract --list \
    /mnt/hd2t/backups/borg::homelab-LATEST \
    mnt/hd2t/apps/freshrss/dumps \
    mnt/hd2t/apps/freshrss/data/config.php \
    mnt/hd2t/apps/freshrss/data/users \
    -o /tmp/drill-freshrss/

# 3) Promover los snapshots a las BBDD live de cada usuario
for snap in /tmp/drill-freshrss/mnt/hd2t/apps/freshrss/dumps/*.snapshot.sqlite; do
    user=$(basename "$snap" .snapshot.sqlite)
    mkdir -p /tmp/drill-freshrss/data/users/$user
    cp "$snap" /tmp/drill-freshrss/data/users/$user/db.sqlite
done
cp /tmp/drill-freshrss/mnt/hd2t/apps/freshrss/data/config.php \
   /tmp/drill-freshrss/data/config.php
cp -r /tmp/drill-freshrss/mnt/hd2t/apps/freshrss/data/users/*/config.php \
      /tmp/drill-freshrss/data/users/   # uno por usuario
sudo chown -R 33:33 /tmp/drill-freshrss/data

# 4) Levantar un FreshRSS temporal contra esa BBDD (sin OIDC, sin Caddy)
docker run -d --rm --name drill-freshrss \
    -e TZ=Europe/Madrid \
    -e CRON_MIN="" \
    -e FRESHRSS_INSTALL_AUTH=form \
    -v /tmp/drill-freshrss/data:/var/www/FreshRSS/data \
    -p 18080:80 \
    freshrss/freshrss:1.24.3

# 5) Esperar healthy
sleep 30
curl -s http://127.0.0.1:18080/i/?c=auth | grep -oE 'FreshRSS [0-9.]+'
# FreshRSS 1.24.3

# 6) Validar count de feeds del operador en su SQLite restaurada
docker exec drill-freshrss \
    sqlite3 /var/www/FreshRSS/data/users/operator/db.sqlite \
    'SELECT COUNT(*) FROM feed;'
# 873

# 7) Cleanup
docker stop drill-freshrss
sudo rm -rf /tmp/drill-freshrss
```

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/freshrss/docker-compose.yml \
    --env-file /home/homelab/homelab/.env \
    --env-file /home/homelab/homelab/stacks/freshrss/.env \
    up -d --force-recreate
# FreshRSS reusa todos los bind mounts en hd2t.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear sistema base (Fase 1), Docker (Fase 2.1), red `homelab` (Fase 2.2), Pi-hole, Caddy, Authelia.
2. Restaurar el repo del homelab y los secrets:
   ```bash
   sudo borg extract /mnt/hd2t/backups/borg::homelab-LATEST \
       home/homelab/homelab
   sudo chown -R homelab:homelab /home/homelab/homelab
   sudo chmod 0600 /home/homelab/homelab/stacks/freshrss/.env
   ```
3. Restaurar `data/`, `extensions/` y los snapshots SQLite:
   ```bash
   sudo borg extract /mnt/hd2t/backups/borg::homelab-LATEST \
       mnt/hd2t/apps/freshrss/data \
       mnt/hd2t/apps/freshrss/extensions \
       mnt/hd2t/apps/freshrss/dumps
   ```
4. Promover los snapshots a las BBDD live de cada usuario (FreshRSS carga `data/users/<user>/db.sqlite`):
   ```bash
   for snap in /mnt/hd2t/apps/freshrss/dumps/*.snapshot.sqlite; do
       user=$(basename "$snap" .snapshot.sqlite)
       sudo cp "$snap" /mnt/hd2t/apps/freshrss/data/users/$user/db.sqlite
       sudo chown 33:33 /mnt/hd2t/apps/freshrss/data/users/$user/db.sqlite
       sudo chmod 0640 /mnt/hd2t/apps/freshrss/data/users/$user/db.sqlite
   done
   ```
5. Levantar el stack:
   ```bash
   cd /home/homelab/homelab
   docker compose -f stacks/freshrss/docker-compose.yml \
       --env-file stacks/freshrss/.env \
       up -d
   ```
6. Verificar `https://freshrss.lan/i/?c=auth` (200 o 302), login OIDC, count de feeds en la UI coincide con el del archive.

> **Punto de no retorno**: el RPO máximo es **24 h** (frecuencia diaria de Borgmatic). Entries marcados como `starred` o `read` entre el último backup y la pérdida se pierden de la BBDD; los entries no leídos se reconstruyen automáticamente al primer refresh tras restore (FreshRSS vuelve a polear los feeds y guarda lo que el sitio aún sirve — feeds con retención corta como Twitter/X scrapers pueden quedar incompletos). Si el operador quiere RPO menor, añadir un timer `freshrss-borg-only.timer` cada 6 h (reabrible).

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `freshrss` queda en `(starting)` 2+ minutos y luego cae a `unhealthy` | El `install.php` falló por permisos en `/var/www/FreshRSS/data`. | `sudo chown -R 33:33 /mnt/hd2t/apps/freshrss/data && docker compose up -d --force-recreate freshrss`. |
| Login OIDC redirige a Authelia y vuelve con `redirect_uri_mismatch` | El `redirect_uri` registrado en Authelia tiene barra final extra, o Caddy no manda `X-Forwarded-Port`. | Verificar `redirect_uris: ['https://freshrss.lan/oidc-redirect']` (sin barra final) y que el drop-in 45 tiene las cinco cabeceras `X-Forwarded-*`. Reload Caddy + Authelia. |
| `mod_auth_openidc` rechaza el id_token con `invalid_jwt` | `OIDC_PROVIDER_METADATA_URL` apunta a un Authelia con clock desincronizado, o el `iss` del id_token no coincide. | `docker exec freshrss curl -sk https://auth.lan/.well-known/openid-configuration | jq '.issuer'` debe ser exactamente lo que firma el id_token. Sincronizar reloj con `sudo timedatectl status`. |
| Logs de FreshRSS muestran `mod_auth_openidc: certificate verify failed` al arrancar | La CA interna no está montada en `/etc/ssl/certs/homelab-ca.crt` o Apache no la está cargando. | Verificar `ls -l /mnt/hd2t/apps/caddy/etc/ca/homelab-ca.crt` y `docker exec freshrss ls /etc/ssl/certs/homelab-ca.crt`. Reiniciar contenedor. |
| Login OIDC funciona pero el usuario aparece como **no admin** | FreshRSS no tiene RBAC nativo por OIDC groups; la promoción a admin es manual. | Promover vía CLI: `docker exec -u www-data freshrss php cli/update-user.php --user <username> --is_admin yes`. |
| Login OIDC devuelve `403 Forbidden` (página de Authelia) | El usuario no pertenece ni a `freshrss-users` ni a `freshrss-admins` en `users_database.yml` de Authelia. | Añadir al usuario al grupo apropiado y `docker compose -f stacks/authelia/... up -d --force-recreate`. |
| App móvil Reeder/FeedMe falla con `Network error / SSL handshake failed` | La CA interna no está instalada a nivel sistema en el móvil. Las apps no comparten trust store con el navegador en Android. | Importar la CA en el SO (iOS: perfil con full trust; Android: rootear o app con "Trust user CAs"). Ver "Configuración → 8". |
| App móvil falla con `401 Unauthorized` | API password mal copiada (typo) o el usuario está desactivado en FreshRSS. | Regenerar API password en `Configuración → Perfil → API` y volver a copiar a la app. |
| OPML import dice "0 feeds importados" pero el `.opml` tiene cientos | El XML del OPML está mal formado (Feedly a veces exporta categorías sin `<outline title="...">` wrapping correcto). | Validar con `xmllint --noout file.opml`; si falla, ejecutar el script de [opml-cleanup](https://github.com/karlicoss/promnesia/blob/master/tools/opml-cleanup.py) o pegar manualmente categorías. |
| El cron de polling no se ejecuta (entries no se actualizan) | `supercronic` murió en silencio o `CRON_MIN=""` (vacío deshabilita el cron). | `docker exec freshrss ps -ef | grep supercronic`. Si no aparece, revisar `CRON_MIN` y `docker compose up -d --force-recreate freshrss`. |
| Refresh de feeds tarda >30 min y se solapa con el siguiente cron | Demasiados feeds, conexión saturada, o un feed específico cuelga 5 min cada vez. | Identificar feeds problemáticos en `Estadísticas → Feeds → Tiempo medio de refresh`. Aumentar `CRON_MIN: "*/60"` o ajustar `feeds_in_parallel` en `data/config.php`. |
| `data/users/operator/db.sqlite` crece a >1 GiB en pocos meses | Política de archivado por feed no aplicada (default = mantener todo). | `Configuración → Configuración de archivado` aplicar "mantener últimos 1000 entries" como default y `Aplicar a todos los feeds`. Tras el cron de purga, `sqlite3 db.sqlite 'VACUUM;'` recupera el espacio. |
| Tras subir versión (`1.24.3` → `1.25.0`) FreshRSS arranca con HTTP 500 | Migration de schema pendiente. La imagen ejecuta migraciones automáticamente al arranque, pero si falla quedan a medias. | `docker logs freshrss` para ver el error. Si la SQLite del usuario quedó inconsistente, restaurar desde el snapshot Borg pre-upgrade. **Antes de cualquier upgrade**: `borgmatic create --tag pre-freshrss-upgrade-X.Y.Z`. |
| `borgmatic create` reporta `db.sqlite cambió durante el archive` | El hook `before_backup` no se ejecutó (Borgmatic no encuentra el comando) o no se excluyó `db.sqlite` del archive. | Verificar `before_backup:` apunta a `docker exec freshrss /usr/local/bin/borg-pre-backup.sh` y `exclude_patterns:` lista los `db.sqlite*` glob. |
| Authelia caído pero el operador necesita leer feeds urgente | OIDC no funciona, pero la cuenta admin local sigue existiendo. | `sed -i 's/^FRESHRSS_AUTH=http_auth/FRESHRSS_AUTH=form/' stacks/freshrss/.env && docker compose ... up -d --force-recreate freshrss`. Login con `admin-local` + password de KeePassXC. Tras restaurar Authelia, volver a `http_auth`. |
| Healthcheck falla con `wget: command not found` | Variante de imagen sin `wget`. | Sustituir por `curl -fsS http://127.0.0.1/i/?c=auth >/dev/null` o `php -r 'file_get_contents("http://127.0.0.1/i/?c=auth");'`. |

---

## Decisiones que **no** se toman en este documento

- **MariaDB / PostgreSQL como backend**: SQLite es suficiente para 1–5 usuarios. Reabrible si la familia ampliada (>10 personas) lo requiere; FreshRSS soporta migración con `cli/migrate-database.php` (export/import entre backends).
- **Cliente OIDC público con PKCE**: `mod_auth_openidc` funciona como cliente confidencial server-side; PKCE no aporta seguridad adicional aquí (el secret no viaja al navegador). Mantener cliente confidencial.
- **forward_auth en Caddy en lugar de mod_auth_openidc**: funcionaría (Authelia setearía `Remote-User` directamente sin OIDC end-to-end), pero pierde el id_token y los claims completos. El homelab estandariza OIDC nativo donde es posible (mealie, linkding, paperless, freshrss). Reabrible si una versión futura de FreshRSS retira `mod_auth_openidc`.
- **Notificaciones por email** (recuperación de password, alertas de feed roto): diferido a Mailrise (Fase 11). FreshRSS soporta SMTP nativo en `data/config.php`; activar tras Fase 11.
- **Notificaciones push de nuevos entries** (Telegram, ntfy, Discord): diferido. La extensión "Notify by Apprise" lo hace, pero el modelo de uso del operador es "leer cuando se quiera" — interrupciones por feed nuevo son contraproducentes.
- **Mercury Parser API como sidecar**: extensión `Mercury Fulltext` funciona si Mercury Parser está accesible. Diferido. Reabrible si los feeds técnicos del operador exponen solo extracto.
- **Newsletter-by-email-to-RSS bridge** (Kill the Newsletter, RSS-Bridge): servicio separado con sus propios IMAP/SMTP. Diferido.
- **Búsqueda con FTS5**: el `LIKE %query%` actual es lento sobre >100k entries pero aceptable. Reabrible si la búsqueda se vuelve dolorosa.
- **Sync con Wallabag** (extensión `Wallabag Save`): Wallabag no está desplegado. El equivalente para "leer luego" en este homelab es Linkding con snapshot HTML.
- **Multi-instancia para aislamiento real entre usuarios**: el operador y la pareja comparten el mismo contenedor con SQLite por usuario; suficiente para uso doméstico. Reabrible.
- **Métricas Prometheus**: FreshRSS no expone `/metrics`. cAdvisor cubre RAM/CPU, Uptime Kuma cubre disponibilidad, `docker logs` cubre auditoría. Diferido.
- **Auto-promoción a admin vía claim OIDC `groups: ["freshrss-admins"]`**: FreshRSS no soporta mapeo nativo de OIDC groups a admin. La promoción es manual (UI o `cli/update-user.php`). Reabrible si una versión futura lo añade.

---

## Referencias

- Documentación oficial FreshRSS: <https://freshrss.github.io/FreshRSS/en/>
- Guía de despliegue Docker: <https://github.com/FreshRSS/FreshRSS/blob/edge/Docker/README.md>
- OIDC con `mod_auth_openidc`: <https://freshrss.github.io/FreshRSS/en/admins/16_OpenID-Connect.html>
- Variables de entorno de la imagen: <https://github.com/FreshRSS/FreshRSS/blob/edge/Docker/README.md#environment-variables>
- API Fever: <https://feedafever.com/api>
- API Google Reader (compat): <https://github.com/FreshRSS/FreshRSS/blob/edge/docs/en/developers/06_GoogleReader_API.md>
- CLI scripts (`import-for-user.php`, `update-user.php`, etc.): <https://github.com/FreshRSS/FreshRSS/tree/edge/cli>
- Galería oficial de extensiones: <https://github.com/FreshRSS/Extensions>
- Imagen Docker Hub: <https://hub.docker.com/r/freshrss/freshrss>
- Repositorio: <https://github.com/FreshRSS/FreshRSS>
- `mod_auth_openidc` (Apache): <https://github.com/OpenIDC/mod_auth_openidc/wiki>
- Documentos del homelab relacionados:
  - `02-docker/02-estructura-compose.md` — convenciones del compose y de las redes Docker.
  - `03-red/04-caddy.md` — TLS interno con CA y `(lan_tls)`.
  - `04-seguridad/01-authelia.md` — registro de clients OIDC y backend de usuarios.
  - `07-backups/02-borgmatic.md` — hooks `before_backup` con `VACUUM INTO`.
  - `11-productividad/01-vaultwarden.md` — patrón SQLite + hook de pre-backup del que este documento se inspira.
  - `11-productividad/03-linkding.md` — patrón Django/SQLite + OIDC + extensión de cliente (App móvil ↔ API token).
  - `11-productividad/05-mealie.md` — patrón OIDC + cliente público (alternativo al confidencial usado aquí).
