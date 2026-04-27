# FreshRSS (agregador de feeds RSS/Atom autohospedado)

## Descripción

Despliegue de **FreshRSS** como **lector de feeds RSS/Atom** del operador y de la familia: bóveda local de suscripciones (blogs técnicos, periódicos, _newsletters_ vía RSSHub, _changelogs_ de proyectos en GitHub, foros con feed expuesto) con categorías, _favourites_, búsqueda full-text, **filtros automáticos** por palabras clave, **APIs compatibles con Fever y Google Reader** para que las apps móviles (Reeder, FluentReader, Newsfold, FocusReader, NetNewsWire) funcionen contra una instancia _self-hosted_ sin reinventar el cliente, y **un único punto de verdad** para todos los dispositivos del operador — sustituyendo definitivamente a **Feedly**, **Inoreader** y **Reeder iCloud sync** (servicios cloud que monitorizan qué lee el operador, qué tarda en abrirlo y a qué hora). La promesa operativa: el operador (y la pareja, si quiere) abre el móvil en el metro, lee 20 entradas mientras va al trabajo, marca tres como _favourite_, y al llegar al portátil de casa el estado de lectura ya está sincronizado vía la _Google Reader API_ que sirve la propia FreshRSS.

Este documento **cierra el _stack_ `productividad`** (`~/homelab/productividad/`) que estrenó `docs/11-productividad/01-vaultwarden.md`, amplió `docs/11-productividad/02-bookstack.md` (introduciendo la red privada `productividad-internal` y MariaDB), `docs/11-productividad/03-linkding.md` (mismo patrón Django + SQLite + token de API que aquí, _mutatis mutandis_), `docs/11-productividad/04-paperless-ngx.md` (Postgres + Redis + Gotenberg + Tika para el archivo documental), `docs/11-productividad/05-mealie.md` (FastAPI + SQLite, recetario familiar) y `docs/11-productividad/06-stirling-pdf.md` (Spring Boot, _stateless_ puro, caja de herramientas PDF). FreshRSS sigue el mismo patrón que Linkding y Mealie — **un único contenedor sobre SQLite**, sin BD aparte, sin red privada adicional. Aquí se materializa un único servicio:

- **`freshrss`** — aplicación PHP 8.x + Apache (imagen oficial `freshrss/freshrss:1.26.2`). Una sola pieza: el binario sirve la web UI, las APIs compatibles (`api/greader.php`, `api/fever.php`) y el cron interno de refresco por el mismo puerto. Persistencia en SQLite local (`/var/www/FreshRSS/data/users/_default/db.sqlite`), sin BD aparte. La rutina de refresco de feeds la ejecuta el **cron interno de la imagen** (`CRON_MIN`), no un sidecar — la imagen oficial tiene ya `cron` instalado y configurado.

Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone FreshRSS en `https://freshrss.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), `https://pi.<tailnet>.ts.net/` con MagicDNS sirve la misma bóveda al móvil cuando el operador está fuera de la LAN, en el AVE, leyendo los _changelogs_ de la última semana.

> **Alcance**: este documento despliega FreshRSS con su autenticación nativa (formulario web con cookie de sesión PHP), crea **el usuario operador** (`_default`) en el primer arranque vía las variables `ADMIN_*` de la imagen oficial — el username `_default` se elige **a propósito** para que coincida con la ruta del _hook_ de Borgmatic ya preparado en `docs/07-backups/03-backup-docker-volumes.md` (`dump_sqlite freshrss freshrss /var/www/FreshRSS/data/users/_default/db.sqlite`). **Deshabilita el registro abierto** (sólo el admin crea usuarios desde la UI), genera la **contraseña de API** del operador para que las apps móviles (Reeder, FluentReader, Newsfold) funcionen contra `/api/greader.php` y `/api/fever.php`, configura el **cron interno** con `CRON_MIN=13,43` (refresco de feeds cada 30 min en minutos no triviales), importa el **OPML** del operador (export de Feedly/Inoreader/Reeder), y **descomenta el bloque del _hook_ de Borgmatic** que dejó preparado `docs/07-backups/03-backup-docker-volumes.md`. **No** delega autenticación a Authelia vía `forward_auth` (las APIs Fever y Google Reader usan _basic auth_ con la **API password** específica de FreshRSS — distinta de la del web — y no siguen redirects HTML a `auth.lan`; ver **Decisiones de diseño**). **No** activa OIDC (queda como **opcional** al final, mismo patrón que Linkding y Mealie). **No** configura SMTP en este documento (queda como **opcional**: FreshRSS sólo lo usaría para el _password reset_, que con un único usuario admin no aporta).

> **Recordatorio de red**: FreshRSS **no se publica al host**. Caddy la alcanza por DNS interno de Docker (`freshrss:80` en la red `homelab`). No hay BD que aislar (SQLite vive dentro del propio contenedor sobre un _bind mount_), por lo que **no** hace falta ampliar `productividad-internal` (se queda con `bookstack`, `bookstack-db`, `paperless`, `paperless-db`, `paperless-redis`, `paperless-gotenberg`, `paperless-tika` dentro). Pi-hole resuelve `freshrss.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`).

---

## Requisitos previos

- `docs/02-docker/02-estructura-compose.md` completado: la tabla de stacks reserva el _slot_ `productividad`, la red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) externa está creada, `~/homelab/.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `HOMELAB_DOMAIN=lan` está rellenado, y el _Makefile_ de operación expone `make up STACK=<stack>`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/freshrss/` ya existe vacío. En este documento se crean además `/mnt/hd2t/services/freshrss/{data,extensions}/` por _populate_ del bind mount.
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada. FreshRSS aparece en la lista de **opt-in** desde el principio (justificación en **Decisiones de diseño**).
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `freshrss.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, y la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile`. La CA local ya firma `*.lan`.
- `docs/07-backups/03-backup-docker-volumes.md` completado: el helper `dump_sqlite` está cargado en `~/homelab/backups/borgmatic/hooks/dump-databases.sh` y el bloque comentado `# dump_sqlite freshrss freshrss /var/www/FreshRSS/data/users/_default/db.sqlite` está listo para descomentar.
- `docs/11-productividad/01-vaultwarden.md` completado: el _stack_ `productividad` ya existe con `~/homelab/productividad/{docker-compose.yml,.env,.env.example,.gitignore}`. **Este documento amplía** esos ficheros — no los crea desde cero. Tener Vaultwarden vivo también significa que el operador **ya tiene una bóveda** donde guardar el _admin password_ inicial y la _API password_ que se generan abajo.
- `docs/11-productividad/06-stirling-pdf.md` completado: el _stack_ `productividad` está vivo con once servicios (Vaultwarden, Bookstack, Bookstack-db, Linkding, Paperless, Paperless-db, Paperless-redis, Paperless-gotenberg, Paperless-tika, Mealie, Stirling-PDF) en `(healthy)`. **Este documento sólo añade un duodécimo contenedor.**
- Conectividad saliente para descargar la imagen (sólo la primera vez):
  ```bash
  docker pull --platform linux/arm64 freshrss/freshrss:1.26.2 >/dev/null && echo OK
  ```
- Que el host **no** tenga ya un servicio escuchando en `:80` por error (`docker ps --format '{{.Names}} {{.Ports}}' | grep ':80->' || echo OK`). Este _stack_ no publica puertos al host; Caddy es quien recibe el tráfico HTTPS.
- Espacio en `/mnt/hd2t`: FreshRSS es **muy ligero**. La aplicación idle ocupa ~80-120 MB de RAM (Apache + PHP-FPM cacheado), la BD SQLite recién creada <1 MB, y el _favicon cache_ + entradas almacenadas raramente superan unos cientos de MB tras años de uso (FreshRSS purga entradas viejas según la política de retención por feed; por defecto guarda 3 meses). Verificar holgura mínima:
  ```bash
  df -h /mnt/hd2t
  # Debe quedar holgado. FreshRSS ocupará <500 MB iniciales en /mnt/hd2t
  # incluso con varios cientos de feeds y meses de histórico.
  ```
- **Export OPML del lector cloud actual** del operador: Feedly (`Settings → OPML → Download my OPML`), Inoreader (`Preferences → Folders & Tags → Subscriptions in OPML`), Reeder iCloud (`Settings → Export → OPML`). Guardar el `.opml` en el portátil para subirlo en **Configuración → 2** tras el primer arranque. **Si no se ha exportado antes**, hacerlo **ahora** mientras el lector cloud sigue accesible — es la última vez que se va a usar.

---

## Decisiones de diseño

### Por qué FreshRSS (y no Tiny Tiny RSS / Miniflux / NewsBlur self-hosted / Inoreader cloud / RSSHub solo)

El homelab necesita **un agregador de feeds** que cumpla a la vez: UI web rápida y usable desde el móvil, **API compatible con Fever y/o Google Reader** (para que las apps móviles maduras del ecosistema RSS funcionen sin tener que escribir clientes propios), categorías, búsqueda full-text, filtros automáticos, importación OPML, _self-hosting_ ARM64 maduro, y un footprint pequeño (es la duodécima aplicación del homelab; el _stack_ ya tiene once piezas y la Pi 5 no es infinita). Cinco candidatos descartados y por qué:

| Candidato                | Por qué se descarta                                                                                                                                                  |
|--------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Tiny Tiny RSS (TT-RSS)** | El proyecto histórico, todavía mantenido pero con un mantenedor _opinionated_ y famoso por su trato áspero a los usuarios. La calidad técnica es buena pero el **stack es PHP + PostgreSQL obligatorio** (no soporta SQLite ni MariaDB en versiones recientes) y la imagen oficial es _moving target_ (`:latest` apuntando a `git HEAD`, sin tags semver). Para un homelab donde la estabilidad de los `pulls` importa, es un riesgo. La UI, además, se siente de 2010 (ergonómica pero anticuada). |
| **Miniflux**             | Excelente, escrito en Go (binario único, RAM mínima), con UI simple y buena. **PERO**: la API que expone es **propia de Miniflux** — sólo unos pocos clientes la implementan (Reeder 5 sí, FluentReader sí, Newsfold no, FocusReader no). Para mantener la libertad de elegir cliente móvil, es una limitación real. La compatibilidad Google Reader API que tiene Miniflux 2.x **es parcial**. |
| **NewsBlur self-hosted** | _Self-hosted_ es factible pero el _stack_ es **enorme** (Django + Postgres + MongoDB + Redis + Celery + Elasticsearch + nginx). _Overkill_ absoluto para un usuario único; pensado para correr el _SaaS_ original con miles de usuarios. Descartado por _footprint_. |
| **Inoreader cloud**      | Excelente cliente, aplicación móvil pulida, sincronización transparente. **PERO**: SaaS, datos en sus servidores, telemetría (Inoreader sabe qué leyó el operador y cuándo), suscripción anual (10 €/mes plan _Pro_ para tener filtros automáticos y _trends_), riesgo de cierre del servicio. Modelo opuesto al objetivo del homelab. FreshRSS **importa OPML** desde Inoreader, así que es una rampa de salida si el operador venía de allí. |
| **Sólo RSSHub** (sin agregador) | RSSHub es **un convertidor**, no un agregador. Genera feeds RSS a partir de cualquier web (Twitter, GitHub, Reddit, etc) que no los exponga nativamente. Útil **dentro** de FreshRSS (FreshRSS suscribe los feeds que produce RSSHub), pero no sustituye al agregador. RSSHub se podría añadir como sidecar en una futura iteración del _stack_, no es objetivo de este documento. |

FreshRSS gana por:

- **Stack mínimo viable**: un único contenedor con PHP + Apache + SQLite. ~150 MB de imagen, ~80 MB de RAM idle. Cero sidecar, cero Redis, cero cola externa, cero base de datos aparte. Cron de refresco interno (`CRON_MIN`).
- **APIs compatibles con Fever y Google Reader**: `freshrss.lan/api/fever.php` y `freshrss.lan/api/greader.php` exponen los dos protocolos legacy más implementados. Esto desbloquea: **Reeder** (iOS/macOS, top tier), **FluentReader** (Windows/macOS/Linux multiplataforma), **Newsfold** (Android, materialista), **FocusReader** (Android, minimalista), **NetNewsWire** (iOS/macOS, libre), **Reams**, **Unread**. El operador no se casa con un único cliente — puede cambiar el lunes por la mañana sin perder estado.
- **Filtros automáticos** (`Mark articles as read with title containing X`, `Auto-favorite articles with content matching regex Y`): permite construir _newsletters_ filtradas a partir de feeds ruidosos (p.ej. ocultar entradas de promociones en feeds de blogs comerciales, o auto-favoritear todo lo que mencione una empresa concreta).
- **Categorías y subcarpetas**: organización jerárquica, no sólo plana como otros agregadores.
- **Búsqueda full-text** sobre títulos, contenidos y autores. Implementada con SQL `LIKE`/FTS según el motor (en SQLite es _table scan_, lo bastante rápido para volúmenes domésticos de hasta decenas de miles de entradas).
- **Soporte ARM64 oficial** vía `freshrss/freshrss` (imagen multi-arch mantenida por el upstream). Sin dependencia de LinuxServer.io.
- **Migración fuera trivial**: exporta a OPML estándar (importable por cualquier otro agregador, incluido el propio Inoreader si el operador volviese). **Sin lock-in**.
- **Open source AGPL-3.0**: código auditable, contribuciones aceptadas, comunidad activa (mantenedores principales: Alexandre Alapetite, Marien Fressinaud, comunidad amplia).
- **Ligero y discreto**: junto con Linkding, es una de las dos piezas más austeras del _stack_ — ideal como undécimo y duodécimo servicios respectivamente.

### Imagen y _tag_

- **`freshrss/freshrss:1.26.2`** — FreshRSS 1.26.x empaquetada por el upstream (Apache + PHP-FPM + Composer en una imagen Debian _slim_), multi-arch (`linux/arm64`). Pinneada a _tag_ "major.minor.patch" semver siguiendo la convención del homelab (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`). FreshRSS publica versiones cada 1-3 meses; los _bumps_ de **patch** (1.26.0 → 1.26.1) traen bug fixes y son seguros (los gestiona Watchtower, ver más abajo). Los _bumps_ de **minor** (1.26.x → 1.27.0) traen funcionalidades nuevas y a veces migraciones de _schema_ (ejecutadas automáticamente al arrancar); se gestionan a mano leyendo el _changelog_. Los _bumps_ de **major** (1.x → 2.x) son raros y exigen leer las _release notes_ con calma.
- **No se usa el _tag_ `:latest`** — al ser FreshRSS una aplicación con BD propia y migraciones automáticas, un `pull` de `:latest` que cruzase un _bump minor_ podría aplicar migraciones irreversibles. El _tag_ pinneado da control del cuándo migrar.

#### Watchtower opt-in en este contenedor

Razones, mismo patrón que Linkding y Mealie:

- El proyecto sigue **semver semi-estricto**: los _bumps_ de **patch** son retrocompatibles y nunca incluyen migraciones de _schema_ rompedoras. Watchtower puede aplicarlos sin riesgo. _docs/02-docker/04-watchtower.md_ → tabla de servicios _opt-in_ ya lista a FreshRSS.
- La superficie de criticidad es baja: si FreshRSS cae 30-60 segundos durante un `restart` post-pull de Watchtower, el operador no pierde nada (los feeds vuelven a estar accesibles tras el reinicio; los clientes móviles reintentan automáticamente la siguiente vez que se sincronizan).
- El SQLite es ligero. Las migraciones de FreshRSS corren en <2 s en una Pi 5; un fallo de migración que dejara la BD a medias se detectaría en el _healthcheck_ inmediatamente y Watchtower no aplicaría más actualizaciones.
- El cron interno de refresco se reinicia automáticamente con el contenedor — no hay estado externo que rescatar.

Etiquetar con `com.centurylinklabs.watchtower.enable: "true"`. Para _bumps minor_ (1.26 → 1.27), Watchtower **respeta el _tag_** del compose: no cruza de `:1.26.2` a `:1.27.0` solo porque exista un `:latest` distinto. Lo único que hace es _re-pull_ del mismo _tag_ por si hubo un _rebuild_ con un _digest_ nuevo. En la práctica, para _bumps minor_ habrá que editar `FRESHRSS_IMAGE_TAG` a mano.

> **Coherencia con `docs/02-docker/04-watchtower.md`**: ese documento ya lista a "FreshRSS" en la lista explícita de servicios **opt-in** desde el principio. No hace falta justificar nada extra aquí; sólo aplicar la etiqueta.

### SQLite en lugar de PostgreSQL/MariaDB

FreshRSS soporta los tres backends (SQLite por defecto, MySQL/MariaDB y PostgreSQL vía variables `DB_*`). La elección **forzada por el caso de uso** del homelab es **SQLite**:

- **Volumen de datos**: un operador típico con 50-200 feeds activos acumula entre 5.000 y 50.000 entradas a lo largo del año (FreshRSS purga las entradas viejas según la política de retención por feed; por defecto, 3 meses). SQLite con índices nativos maneja eso con una latencia de UI de <100 ms. Para llegar a justificar Postgres habría que estar en el orden de cientos de miles de entradas y múltiples usuarios concurrentes — escenario absurdo en un homelab familiar.
- **Cero overhead operativo**: sin sidecar, sin _hostname_ adicional en `productividad-internal`, sin `MARIADB_PASSWORD` que custodiar, sin `mariadb-dump` o `pg_dump` extra en el _hook_ de Borgmatic (basta con `dump_sqlite`, el patrón S de `docs/07-backups/03-backup-docker-volumes.md`).
- **Backup más simple**: una llamada a `sqlite3 .backup` produce un fichero binario consistente sin parar el contenedor. Un dump SQL de Postgres requiere un _client_ instalado en el contenedor (o un sidecar `pg_dump`). El SQLite gana en tres líneas de _hook_ frente a quince.
- **Restauración más simple**: copiar el fichero `db.sqlite` a su sitio y arrancar el contenedor. Sin _hostname_ de BD, sin _user_/`password`, sin `CREATE DATABASE` previo.
- **Coherencia**: Linkding, Vaultwarden y Mealie ya viven sobre SQLite en el mismo _stack_. FreshRSS sigue el mismo patrón. **Bookstack** (MariaDB obligatoria, restricción upstream) y **Paperless** (Postgres por concurrencia Celery) son las únicas dos excepciones del _stack_ y ambas justificadas en sus respectivos documentos.
- **Multi-usuario en SQLite**: FreshRSS, a diferencia de Linkding o Mealie, mantiene **un fichero SQLite distinto por usuario** (`/var/www/FreshRSS/data/users/<username>/db.sqlite`). Para un homelab con un único admin, esto no añade complejidad; si en el futuro entran 2-3 usuarios familiares, el _hook_ de Borgmatic deberá iterar sobre los directorios de usuarios. Documentado al final en **Multiusuario (futuro)**.

> **Si en el futuro FreshRSS pasase a "muchos usuarios escribiendo en paralelo"** (improbable en un hogar), la migración a MariaDB/Postgres está documentada upstream. La operación es: `php cli/db-optimize.php` previo, exportar OPML de cada usuario, `DB_TYPE=postgres` en el `.env`, recrear cuentas, importar OPML. **Operación de un par de horas, no irreversible**.

> **Coherencia con `docs/07-backups/03-backup-docker-volumes.md`**: ese documento dejó preparado **un único** bloque comentado para SQLite (`# dump_sqlite freshrss freshrss /var/www/FreshRSS/data/users/_default/db.sqlite`). Aquí se descomenta. Si más adelante hay multi-usuario, ese bloque se sustituye por un loop documentado al final de este documento.

### `forward_auth` con Authelia: **NO** para FreshRSS

Misma decisión que en Vaultwarden, Bookstack, Linkding, Paperless y Mealie. Razones específicas para FreshRSS:

- **APIs Fever y Google Reader con _basic auth_**: FreshRSS expone `/api/fever.php` (protocolo Fever) y `/api/greader.php` (protocolo Google Reader / API Inoreader-compat). Ambos usan **_basic auth_** o **token-en-querystring**, no cookie HTTP. Los clientes móviles (Reeder, FluentReader, Newsfold) se autentican con `Authorization: Basic <user:apipass>` o, en el caso de la Google Reader API, con `Authorization: GoogleLogin auth=<token>` obtenido vía `POST /accounts/ClientLogin`. **No siguen redirects HTML**. Si Caddy intercepta una petición a `/api/greader.php?n=10` con un `302` hacia `https://auth.lan/?rd=...`, los clientes reciben HTML en lugar del XML/JSON esperado y fallan con errores opacos del tipo "no se puede sincronizar" sin pista de que el problema es Authelia.
- **PWA y _share intent_**: FreshRSS tiene una PWA decente (instalable en Android) y, aunque el _flow_ "Share to FreshRSS" desde Firefox móvil es menos común que en Linkding o Mealie, sí existe y dispara una petición POST a `/i/?c=feed&a=add` con cookies. Cualquier redirect a Authelia rompería el flujo.
- **API password distinta de la de web**: FreshRSS implementa una **separación explícita** entre la contraseña del web (para humanos en `https://freshrss.lan/`) y la **API password** (para clientes Fever/GReader). Esto es **arquitectónicamente la solución correcta** al problema "auth de humano vs auth de máquina" — equivalente al _token_ de Linkding o al _Bearer_ de Mealie. Mete a Authelia en medio sería redundante y confuso.
- **OIDC nativo**: FreshRSS soporta **autenticación REMOTE_USER** (compatible con Apache mod_auth_openidc o con un proxy delante que ponga la cabecera `X-WEBAUTH-USER`/`Remote-User`). Esto **sí permite** integración con Authelia, pero por el patrón **trusted header** (no `forward_auth` clásico): Caddy autentica al usuario contra Authelia y pasa una cabecera `Remote-User: <username>` a FreshRSS, que la respeta. Se documenta como **opcional** al final.

> **Resumen operativo**: el bloque `freshrss.lan` del `Caddyfile` lleva `import security-headers` y `import logging`, pero **no** `import authelia`. Caddy actúa como _reverse proxy_ "tonto"; FreshRSS autentica con su sistema nativo (formulario de login + cookie de sesión PHP) y, en paralelo, las APIs Fever/GReader autentican con la **API password** específica del usuario. Cuando se decida pasar a OIDC, se añadirá la integración trusted-header descrita en **Migrar a OIDC con Authelia (opcional)**.

### `BASE_URL` y _trusted proxy_

FreshRSS, al estar detrás de un _reverse proxy_ que termina TLS, necesita **dos cosas**:

1. **Saber su URL pública** para construir _absolute URLs_ en los feeds OPML exportados, en los _share links_ y en los _redirect URIs_ (si activase OIDC). Se controla con `FRESHRSS_BASE_URL` y, sobre todo, con la lógica de detección automática que hace FreshRSS a partir de las cabeceras `X-Forwarded-Proto` y `X-Forwarded-Host`.
2. **Confiar en las cabeceras `X-Forwarded-*`** que pone Caddy. FreshRSS, por defecto, **ignora** esas cabeceras (defensa contra _header injection_ si la app está expuesta directamente a internet). Para que las respete, hay que listar la IP del proxy como _trusted_ vía `TRUSTED_PROXY` (variable de la imagen).

Política aplicada:

```bash
# Caddy alcanza FreshRSS desde la red 'homelab' (172.20.10.0/24).
# Permitir cualquier IP de esa subnet:
TRUSTED_PROXY=172.20.10.0/24
```

…y NO se fuerza un `BASE_URL` explícito: la detección automática a partir de `X-Forwarded-Proto: https` + `X-Forwarded-Host: freshrss.lan` da el resultado correcto. Esto evita el problema de tener que sincronizar manualmente el `.env` con el `Caddyfile` cada vez que se cambie de dominio (no se va a cambiar en este homelab, pero la robustez es gratis).

### Cron interno: `CRON_MIN` y la sincronización de feeds

FreshRSS necesita **refrescar los feeds** periódicamente para descargar las nuevas entradas. La imagen oficial trae un **cron interno** que ejecuta `cli/actualize_user.php` cada N minutos según `CRON_MIN`. Las opciones:

| Estrategia                      | Cuándo elegirla                                                                                                    | Pros                                              | Contras                                                  |
|---------------------------------|--------------------------------------------------------------------------------------------------------------------|---------------------------------------------------|----------------------------------------------------------|
| `CRON_MIN=*/15`                | Refresco cada 15 min (cuatro veces por hora)                                                                       | Feeds siempre frescos                             | Mucho tráfico de salida; carga puntual en la Pi          |
| `CRON_MIN=13,43`               | Refresco dos veces por hora, en minutos no triviales                                                               | Bueno para uso normal; reparte carga              | Feeds pueden tardar hasta 30 min en aparecer             |
| `CRON_MIN=3`                    | Una vez por hora (en minuto 3)                                                                                     | Mínimo tráfico; menos despiertos los feeds         | Hasta 60 min de retraso para entradas urgentes           |
| `CRON_MIN=` (vacío)             | Sin cron interno — refresco manual desde la UI o externo                                                           | Cero impacto                                      | Operador debe acordarse de pulsar "actualizar"           |

Política aquí: **`CRON_MIN=13,43`**. Buen equilibrio entre frescura y carga; los minutos no triviales evitan colisiones con otros crons del homelab (Borgmatic en `~3:00`, Watchtower en `~4:00`, mantenimiento de Pi-hole en minuto 0/30, etc.). Si el operador prefiere feeds más frescos, subir a `*/15` es seguro (la Pi 5 lo aguanta sin despeinarse).

> **Alternativa: cron externo del host**. La imagen permite desactivar el cron interno (`CRON_MIN=`) y disparar el refresco desde el cron del host con `docker exec freshrss su www-data -c "/var/www/FreshRSS/app/actualize_script.sh"`. Más control de cuándo se ejecuta y _logging_ unificado vía `cron.log` del host. **No se aplica aquí** por simplicidad (un único cron por servicio, encapsulado en su contenedor) — pero queda documentado al final como **opcional**.

### Bind mount mínimo: `data/` y `extensions/`

| Bind mount         | Volumen interno              | Tipo | Por qué                                                                                              |
|--------------------|-------------------------------|------|------------------------------------------------------------------------------------------------------|
| `data/`            | `/var/www/FreshRSS/data`      | RW   | Contiene la BD SQLite por usuario, los favicons cacheados, el _config_ global, los logs de cron.    |
| `extensions/`      | `/var/www/FreshRSS/extensions`| RW   | Contiene las extensiones comunitarias instaladas (p.ej. _Auto Translate_, _YouTube Channel_). Vacío al inicio. |
| `users/`           | _(dentro de `data/users/`)_   | -    | **No se monta aparte**. Vive bajo `data/`.                                                          |

Ambos bind mounts viven en `/mnt/hd2t/services/freshrss/{data,extensions}` y entran en Borgmatic vía `source_directories:` global del set "data" (excepto el dump de SQLite, que se hace antes y se respalda como fichero plano consistente, ver `docs/07-backups/02-borgmatic.md`).

### `PUID`/`PGID` y permisos del bind mount

La imagen oficial `freshrss/freshrss` arranca como **root** y luego hace `su www-data` para los procesos PHP. Para que las escrituras de PHP en `/var/www/FreshRSS/data` funcionen, el bind mount debe ser **propiedad de `www-data`** (UID/GID 33 en Debian). La imagen **no respeta `PUID`/`PGID`** (a diferencia de las imágenes LSIO) — el `www-data` de la imagen es siempre 33.

Esto entra en tensión con la convención del homelab (`PUID=1000`, `PGID=1000` para que los ficheros sean editables desde el host por el usuario `pi`). La política aplicada:

- **Crear el bind mount con ownership `33:33` (www-data:www-data)** en el host.
- **Aceptar que los ficheros bajo `data/` y `extensions/` no son editables sin `sudo` desde el host.** En la práctica, el operador raramente tendrá que editar nada manualmente — todo se gestiona desde la UI de FreshRSS.
- **Borgmatic ya corre como `root`** (ver `docs/07-backups/02-borgmatic.md`), así que puede leer cualquier UID sin problema.
- **No** declarar `PUID`/`PGID` en el `environment:` (la imagen los ignoraría y el _override_ confundiría al lector del compose).

```bash
sudo mkdir -p /mnt/hd2t/services/freshrss/{data,extensions}
sudo chown -R 33:33 /mnt/hd2t/services/freshrss/{data,extensions}
sudo chmod 0755 /mnt/hd2t/services/freshrss/{data,extensions}
```

> **Si una operación manual desde el host requiere editar un fichero bajo `data/` (raro)**: usar `sudo $EDITOR /mnt/hd2t/services/freshrss/data/...`. Para ediciones sostenidas, considerar un `chmod g+rwX -R` con un grupo compartido entre `www-data` y el usuario del host, pero es _overkill_ aquí.

### Almacenamiento

Persistencia sobre **hd2t**, todo en `/mnt/hd2t/services/freshrss/`:

```
/mnt/hd2t/services/freshrss/
├── data/                          # ← se llena al primer arranque
│   ├── config.php                 # config global de la instancia (SALT, FRESHRSS_BASE_URL si está fijo)
│   ├── users/
│   │   └── _default/
│   │       ├── config.php         # config del usuario (categorías, tema, refresco, etc.)
│   │       ├── db.sqlite          # BD SQLite con feeds, entradas, etiquetas, favourites
│   │       └── feeds/             # caches por feed (favicons, errores temporales)
│   ├── cache/                     # cache HTTP (ETag/Last-Modified) por feed
│   └── logs/                      # logs del cron interno (actualize_*.log)
└── extensions/                    # extensiones comunitarias (vacío al inicio)
```

Tamaño total típico tras meses de uso con 100-200 feeds: **<300 MB**. Crecimiento esperado: <500 MB después de varios años (la política de retención por feed evita que crezca sin control).

> **Categoría B en la estrategia de backup** (`docs/07-backups/01-estrategia-backup.md`): datos del usuario sobre SQLite. **Sí se respalda**: Borgmatic incluye `/mnt/hd2t/services/freshrss/` en el set "data" y, vía el _hook_ de `dump_sqlite`, garantiza que el `.sqlite` se respalda en estado consistente.

---

## Estructura del _stack_ `productividad` tras este documento

Antes de este documento (tras `docs/11-productividad/06-stirling-pdf.md`):

```
~/homelab/productividad/
├── docker-compose.yml        # contiene vaultwarden + bookstack + bookstack-db + linkding +
│                             #          paperless + paperless-db + paperless-redis +
│                             #          paperless-gotenberg + paperless-tika + mealie +
│                             #          stirling-pdf
├── .env                      # APP vars de los once
├── .env.example
└── .gitignore
```

Tras este documento:

```
~/homelab/productividad/
├── docker-compose.yml        # ← MODIFICADO: añade freshrss
├── .env                      # ← MODIFICADO: añade FRESHRSS_*, ADMIN_*
├── .env.example              # ← MODIFICADO: añade plantilla FRESHRSS_*, ADMIN_*
├── .gitignore                # sin cambios
└── freshrss/                 # ← NUEVO (opcional, para snapshots de config)
    └── (vacío hasta que se necesite versionar algo)
```

Y en el disco externo, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/freshrss/
├── data/                     # ← se llena al primer arranque
│   ├── config.php
│   ├── users/_default/...
│   └── ...
└── extensions/               # ← vacío hasta que se instale alguna
```

Ningún cambio en `~/homelab/productividad/.gitignore` (ya excluye `.env`). Los subdirectorios `data/` y `extensions/` se crean explícitamente con ownership `33:33` antes del primer arranque (la imagen no hace `chown` automático y arrancaría con permisos `root:root` del host fallando al escribir).

> **Confirmar el árbol** antes de seguir:
> ```bash
> ls -la /mnt/hd2t/services/freshrss/
> # vacío         (creado por 04-estructura-directorios.md)
> ```
> Si por algún intento previo ya existiesen subdirectorios con datos antiguos, **borrarlos** antes del primer arranque limpio:
> ```bash
> sudo rm -rf /mnt/hd2t/services/freshrss/data /mnt/hd2t/services/freshrss/extensions
> ```

Crear los directorios con ownership correcto (clave: UID 33 = `www-data` dentro de la imagen):

```bash
sudo mkdir -p /mnt/hd2t/services/freshrss/{data,extensions}
sudo chown -R 33:33 /mnt/hd2t/services/freshrss/{data,extensions}
sudo chmod 0755 /mnt/hd2t/services/freshrss/{data,extensions}
ls -ld /mnt/hd2t/services/freshrss/{data,extensions}
# drwxr-xr-x 2 33 33 4096 ... data
# drwxr-xr-x 2 33 33 4096 ... extensions
```

---

## Variables de entorno

### Ampliar `~/homelab/productividad/.env.example`

Abrir el fichero existente (ampliado en `docs/11-productividad/06-stirling-pdf.md`) y **añadir al final** un nuevo bloque (no tocar las líneas de Vaultwarden, Bookstack, Linkding, Paperless, Mealie ni Stirling-PDF):

```bash
# ============================================================================
# FreshRSS — agregador de feeds RSS/Atom (docs/11-productividad/07-freshrss.md)
# ============================================================================

# --- Imagen pinneada --------------------------------------------------------
FRESHRSS_IMAGE_TAG=1.26.2

# --- FreshRSS — admin inicial (creado en el primer arranque) ----------------
# El username '_default' se elige a propósito para que coincida con la ruta
# del hook de Borgmatic ya preparado en docs/07-backups/03-backup-docker-volumes.md.
# Cambiarlo significa que hay que actualizar también el path del dump_sqlite.
ADMIN_EMAIL=operador@homelab.local
ADMIN_PASSWORD=__GENERAR_FUERTE_Y_GUARDAR_EN_VAULTWARDEN__
ADMIN_API_PASSWORD=__GENERAR_FUERTE_Y_GUARDAR_EN_VAULTWARDEN__

# --- FreshRSS — cron interno de refresco -----------------------------------
# Sintaxis cron clásica para minuto. '13,43' = dos veces por hora en minutos
# no triviales (evita colisiones con backups, watchtower, etc.).
# Alternativas: '*/15' (cada 15 min), '3' (una vez por hora), '' (sin cron).
CRON_MIN=13,43

# --- FreshRSS — confianza en X-Forwarded-* (Caddy) -------------------------
# IPs de la red Docker 'homelab' (172.20.10.0/24) son confiables para que
# FreshRSS respete X-Forwarded-Proto: https y construya bien las URLs.
TRUSTED_PROXY=172.20.10.0/24

# --- FreshRSS — locale por defecto -----------------------------------------
# 'es' = castellano. Otras: 'en', 'fr', 'de', 'it', 'pt-br', 'ca'.
FRESHRSS_LANG=es

# --- FreshRSS — TZ del cron interno ----------------------------------------
# Hereda TZ global del homelab; aquí redundante pero explícito.
FRESHRSS_TZ=Europe/Madrid

# --- FreshRSS — política de retención de entradas (segundos) ---------------
# Por defecto 7776000 = 90 días. Subir a 31536000 (1 año) si se quiere
# histórico largo, a costa de tamaño de BD.
PURGE_INTERVAL_SECONDS=7776000

# --- FreshRSS — log nivel ---------------------------------------------------
# Niveles: 0=NONE, 1=ERROR, 2=WARNING, 3=NOTICE (default), 4=DEBUG.
# 4 sólo para diagnosticar feeds problemáticos.
LOG_LEVEL=3
```

### Ampliar `~/homelab/productividad/.env`

Copiar las nuevas líneas de la plantilla y rellenar los valores reales. **Generar las dos passwords con `openssl rand`** (32 bytes para password de admin web, 24 bytes para API password — la API password es _basic auth_ con _user:pass_ Base64 codificado, las passwords largas funcionan mejor que las complejas):

```bash
# Generar las dos contraseñas (copiar al portapapeles antes de pegarlas en Vaultwarden):
openssl rand -base64 32 | tr -d '/+='
# 8nKr3WqL9pXyJhGfV2cZmBdT4RsAuQ7E
openssl rand -base64 24 | tr -d '/+='
# qYr7vL3PcWbZmK9HnEt5Jx2A
```

```bash
# Editar el .env existente (tiene ya los valores de los once anteriores;
# AÑADIR debajo las nuevas líneas).
$EDITOR ~/homelab/productividad/.env

# Confirmar que las variables nuevas están y tienen los valores deseados:
grep -E '^FRESHRSS_|^ADMIN_|^CRON_MIN|^TRUSTED_PROXY|^PURGE_INTERVAL|^LOG_LEVEL' \
    ~/homelab/productividad/.env

# Permisos restrictivos del .env (ya debería estar 0600 desde docs anteriores):
chmod 0600 ~/homelab/productividad/.env
```

> **No commitear `.env` jamás**. El `.gitignore` del _stack_ ya lo excluye explícitamente.

> **Custodia en Vaultwarden** (entrada **nueva**, distinta de la de cada otro servicio): crear en el _vault_ del operador una entrada llamada `FreshRSS — Homelab` con tres campos:
> - `Web username`: `_default`
> - `Web password`: el valor de `ADMIN_PASSWORD`
> - `API password (Fever / Google Reader)`: el valor de `ADMIN_API_PASSWORD`
>
> La diferencia entre las dos passwords es **crítica**: el web usa la primera, los clientes móviles (Reeder, FluentReader, Newsfold) usan la segunda. Confundir cuál se mete dónde es el origen del 80% de los problemas iniciales con FreshRSS.

---

## Modificar `~/homelab/productividad/docker-compose.yml`

El _docker-compose.yml_ de este _stack_ ya existe con once servicios (`vaultwarden`, `bookstack`, `bookstack-db`, `linkding`, `paperless`, `paperless-db`, `paperless-redis`, `paperless-gotenberg`, `paperless-tika`, `mealie`, `stirling-pdf`). **Editarlo, no recrearlo**: añadir el servicio `freshrss`, dejando intactos los once bloques previos.

El nuevo servicio se añade al final de la sección `services:`, justo antes de la sección `networks:`:

```yaml
  # ===========================================================================
  # FreshRSS — agregador de feeds RSS/Atom (PHP + Apache + SQLite).
  # Único contenedor. Sólo en la red 'homelab' (Caddy lo alcanza por DNS).
  # NO se engancha a productividad-internal (no hay BD que aislar).
  # SÍ entra en Borgmatic (Categoría B, dump_sqlite por usuario).
  # NO lleva forward_auth: las APIs Fever/GReader no siguen redirects.
  # ===========================================================================
  freshrss:
    image: freshrss/freshrss:${FRESHRSS_IMAGE_TAG}
    container_name: freshrss
    hostname: freshrss
    restart: unless-stopped
    mem_limit: 512m
    environment:
      TZ: ${TZ}                                 # global del homelab
      CRON_MIN: ${CRON_MIN}                     # minutos del cron interno
      TRUSTED_PROXY: ${TRUSTED_PROXY}           # confiar en X-Forwarded-* de Caddy
      FRESHRSS_LANG: ${FRESHRSS_LANG}           # idioma de la UI
      FRESHRSS_TZ: ${FRESHRSS_TZ}
      LOG_LEVEL: ${LOG_LEVEL}

      # --- Admin inicial (sólo se aplica si data/ está vacío) ---
      ADMIN_EMAIL: ${ADMIN_EMAIL}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD}
      ADMIN_API_PASSWORD: ${ADMIN_API_PASSWORD}
      # Username del admin queda fijado a '_default' por la imagen
      # cuando se usan las variables ADMIN_* sin más config.

      # --- Política de retención ---
      PURGE_INTERVAL_SECONDS: ${PURGE_INTERVAL_SECONDS}
    volumes:
      - /mnt/hd2t/services/freshrss/data:/var/www/FreshRSS/data
      - /mnt/hd2t/services/freshrss/extensions:/var/www/FreshRSS/extensions
    networks:
      homelab:
        aliases:
          - freshrss     # Caddy resuelve 'freshrss:80' por este alias
    labels:
      homelab.stack: "productividad"
      homelab.backup: "true"      # Categoría B — se respalda con dump_sqlite
      # Opt-in: semver patch retrocompatible, downtime aceptable.
      com.centurylinklabs.watchtower.enable: "true"
    healthcheck:
      # /i/?c=index&a=normal devuelve 200 (con redirect al login si no hay sesión).
      # Endpoint más robusto que /robots.txt o /favicon.ico (que también funcionarían).
      test:
        - CMD-SHELL
        - "curl -fsS -o /dev/null -w '%{http_code}' http://localhost/i/ | grep -E '^(200|302)$' >/dev/null"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s   # primer arranque: PHP migrations + crear admin user ~30 s
```

> **Importante** — `freshrss` se añade **dentro** del bloque `services:` ya existente, NO sustituye nada. Validar después con `docker compose config | grep -E '^\s+(vaultwarden|bookstack|bookstack-db|linkding|paperless|paperless-db|paperless-redis|paperless-gotenberg|paperless-tika|mealie|stirling-pdf|freshrss):'` que los doce siguen estando.

Notas de diseño:

- **Sólo en `homelab`**, no en `productividad-internal`. No hay BD que aislar (la SQLite vive dentro del propio contenedor sobre un bind mount).
- **Sin `ports:`**. Caddy alcanza FreshRSS por DNS interno (`freshrss:80`). Si el operador, durante troubleshooting, necesita acceder sin pasar por Caddy: `docker exec freshrss curl -fsS http://localhost/i/`.
- **`mem_limit: 512m`**: límite generoso para PHP + Apache + cron. FreshRSS idle se queda en torno a **80-120 MB de RSS reales**; el cron de actualización puntualmente sube a ~200 MB durante 30-60 s al refrescar 100+ feeds en paralelo. `512m` deja margen sin penalizar a los otros 11 contenedores del stack.
- **`start_period: 60s`**: el primer arranque ejecuta las migraciones PHP de la BD vacía (~5 s), crea el admin desde las variables `ADMIN_*` (~2 s) y arranca Apache. Total ~30-40 s. El margen evita que el _healthcheck_ marque `unhealthy` durante el setup inicial. Reinicios posteriores son ~5-10 s.
- **Watchtower opt-in**: razones explicadas en **Decisiones de diseño** → _Imagen y tag_.
- **Sin `depends_on`**: FreshRSS es un único contenedor sin dependencias internas al _stack_. Se levanta y se cae solo.
- **`curl` en el _healthcheck_**: la imagen base de FreshRSS (Debian _slim_) **sí trae `curl`** por defecto. Confirmable con `docker run --rm freshrss/freshrss:1.26.2 which curl`.
- **`homelab.backup: "true"`**: etiqueta informativa coherente con que SÍ entra en Borgmatic (Categoría B). Útil como _marker_ legible si en el futuro se usa para automatizar reportes (`docker ps --filter "label=homelab.backup=true"`).

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/productividad

# Validar la sintaxis sin levantar nada (recomendado tras editar el compose).
docker compose --env-file ../.env --env-file .env config | \
    grep -E '^\s+(vaultwarden|bookstack|bookstack-db|linkding|paperless|paperless-db|paperless-redis|paperless-gotenberg|paperless-tika|mealie|stirling-pdf|freshrss):'
# vaultwarden:
# bookstack-db:
# bookstack:
# linkding:
# paperless-db:
# paperless-redis:
# paperless-gotenberg:
# paperless-tika:
# paperless:
# mealie:
# stirling-pdf:
# freshrss:

# Levantar SÓLO el servicio nuevo (los otros once ya están corriendo y healthy):
docker compose --env-file ../.env --env-file .env up -d freshrss
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=productividad
# El make up no es selectivo: lleva el stack completo al estado deseado.
# Como los once previos ya están up y nada del compose los cambia,
# Compose los deja tal cual y sólo arranca freshrss.
```

Vigilar el primer arranque (~30-40 s):

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml logs -f freshrss
# freshrss | Initializing FreshRSS database...
# freshrss | Running migrations...
# freshrss | Creating admin user '_default' from environment variables...
# freshrss | Starting cron with CRON_MIN=13,43
# freshrss | Starting Apache HTTP Server...
# freshrss | [Apache] AH00094: Command line: '/usr/sbin/apache2 -D FOREGROUND'
```

> **Si tarda más de 2 minutos** sin llegar a "Apache HTTP Server": probablemente hay un problema de permisos sobre el bind mount (la imagen no puede escribir en `/var/www/FreshRSS/data`). Confirmar con `docker logs freshrss | grep -i 'permission denied\|cannot write'`. Solución: ejecutar de nuevo el `chown -R 33:33 /mnt/hd2t/services/freshrss/{data,extensions}` con `sudo` y `restart`.

Verificar que el contenedor está `(healthy)`:

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml ps
# NAME                  STATUS                   PORTS
# vaultwarden           Up X minutes (healthy)
# bookstack-db          Up X minutes (healthy)
# bookstack             Up X minutes (healthy)
# linkding              Up X minutes (healthy)
# paperless-db          Up X minutes (healthy)
# paperless-redis       Up X minutes (healthy)
# paperless-gotenberg   Up X minutes (healthy)
# paperless-tika        Up X minutes (healthy)
# paperless             Up X minutes (healthy)
# mealie                Up X minutes (healthy)
# stirling-pdf          Up X minutes (healthy)
# freshrss              Up X seconds (healthy)
```

> El `(healthy)` lo otorga el _healthcheck_ que comprueba `/i/` devolviendo `200` o `302`. Si tras 2 minutos sigue `starting`/`unhealthy`, ir a **Troubleshooting** → primer arranque.

Confirmar que el bind mount se pobló:

```bash
sudo ls -la /mnt/hd2t/services/freshrss/data/
# drwxr-xr-x 5 33 33 4096 ... users
# -rw-r--r-- 1 33 33  ... config.php
# drwxr-xr-x 2 33 33 4096 ... cache
# drwxr-xr-x 2 33 33 4096 ... logs

sudo ls -la /mnt/hd2t/services/freshrss/data/users/
# drwxr-xr-x 4 33 33 4096 ... _default

sudo ls -la /mnt/hd2t/services/freshrss/data/users/_default/
# -rw-r--r-- 1 33 33    ... config.php
# -rw-r--r-- 1 33 33    ... db.sqlite       ← ¡importante! confirma que el admin se creó.
```

(Los UID/GID `33:33` son lo esperado: FreshRSS corre como `www-data` dentro del contenedor.)

### Caddy: bloque `freshrss.lan` (sin `import authelia`)

Editar `~/homelab/red/Caddyfile` y añadir el bloque:

```caddy
freshrss.lan {
    tls internal
    import security-headers
    import logging

    # Subidas de OPML grandes: un export de Inoreader con 500 feeds puede
    # llegar a varios MB (con todos los meta-datos). 16 MB de margen amplio.
    request_body {
        max_size 16MB
    }

    # FreshRSS no construye URLs absolutas si recibe X-Forwarded-Host bien;
    # X-Forwarded-Proto es crítico para que las APIs Fever/GReader devuelvan
    # endpoints https://... y no http://...
    reverse_proxy freshrss:80 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}
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
# Login form (sin sesión): devuelve 200 con HTML del formulario
curl -k --resolve freshrss.lan:443:192.168.1.3 -I https://freshrss.lan/
# HTTP/2 302
# location: /i/?c=auth&a=login
# (FreshRSS redirige primero a /i/, luego al login)

# La home pública del login:
curl -k --resolve freshrss.lan:443:192.168.1.3 https://freshrss.lan/i/?c=auth\&a=login | head -20
# <!DOCTYPE html>
# <html>
# (HTML del formulario de login)
```

Y desde el navegador:

1. Visitar `https://freshrss.lan/`.
2. **Login**: usuario `_default`, contraseña la de `ADMIN_PASSWORD` del `.env` (custodiada en Vaultwarden).
3. Tras el login, FreshRSS muestra la **home vacía** (sin feeds aún) con su navbar:
   - **`Feeds`** (lista — vacía al inicio)
   - **`+ Add`** (botón para suscribir un feed nuevo)
   - **`Search`** (buscador)
   - **`Settings`** (configuración por usuario)
   - **`Logout`**

---

## Configuración tras primer arranque

### 1. Confirmar idioma y zona horaria del usuario

FreshRSS hereda `FRESHRSS_LANG=es` y `TZ=Europe/Madrid` del `.env`, pero estos sólo se aplican al **idioma de la UI** y al **cron interno**, no necesariamente a las **preferencias del usuario `_default`**. Confirmar/ajustar:

1. `Settings → User profile`.
2. **Language**: confirmar `Spanish (es)`.
3. **Time zone**: confirmar `Europe/Madrid`.
4. **Theme**: elegir `Dark` o `Light` según preferencia. FreshRSS trae unos 15 temas integrados.
5. **Reading mode**: `Mark articles as read on scroll` activado (UX más fluida en el móvil; las que no se han leído explícitamente quedan _unread_).
6. `Submit`.

### 2. Importar OPML (migrar desde Feedly / Inoreader / Reeder)

Este es el paso **crítico** para que el operador no abandone FreshRSS en 24 h por flojera de añadir feeds uno a uno.

1. **Antes de empezar**: tener el `.opml` exportado del lector cloud (ver **Requisitos previos** → último bullet).
2. En FreshRSS: `Subscriptions management → Import / export → Import` (o, en versiones recientes: `+ Add → Import`).
3. **Subir el fichero `.opml`**.
4. FreshRSS parsea el OPML, crea las categorías (carpetas) y suscribe todos los feeds en lote. **Tarda 10-60 s** según el número de feeds y el _ping_ a cada uno (FreshRSS hace una primera petición a cada feed para validar que responde).
5. Tras la importación, la home muestra todos los feeds importados, agrupados por categoría. Algunos pueden aparecer en estado **error** (rojo) si la URL del feed cambió desde que se exportó del cloud.
6. **Refresco inicial**: `Subscriptions management → Refresh all`. Esto llama el `actualize_user.php` para todos los feeds y descarga las entradas más recientes. Tarda 1-5 minutos según número de feeds y velocidad de la red.

> **Si algunos feeds dan error tras la importación**: lo más común es que la URL haya cambiado. Click en el feed con error → `Edit` → buscar la nueva URL del feed (Google "<nombre del blog> rss feed" o, mejor, abrir el blog y mirar el `<link rel="alternate" type="application/rss+xml">` en el HTML). Sustituir y `Save`.

> **Importación parcial / añadir más feeds en el futuro**: el flujo es el mismo. FreshRSS detecta feeds duplicados (por URL) y los omite, así que se puede importar el mismo OPML varias veces sin riesgo de duplicar.

### 3. Verificar la API password (Fever / Google Reader)

La API password se generó automáticamente desde `ADMIN_API_PASSWORD` en el primer arranque. Confirmar que está activa:

1. `Settings → Authentication → API access`.
2. Comprobar que aparece "API password is set" (o equivalente). Si por alguna razón no se aplicó (variante de la imagen, etc.), generarla manualmente: pegar el valor de `ADMIN_API_PASSWORD` y `Submit`.
3. **Anotar los _endpoints_ que necesitan los clientes**:
   - **Google Reader API**: `https://freshrss.lan/api/greader.php`
   - **Fever API**: `https://freshrss.lan/api/fever.php`
4. **Probar la API desde el host** (no requiere navegador):
   ```bash
   # Calcular el hash MD5 que requiere Fever (md5(user:apipass))
   echo -n "_default:<API_PASSWORD>" | md5sum
   # 3f8a9b1c2d4e5f6789012345678901ab

   # Llamar a la API Fever:
   curl -k --resolve freshrss.lan:443:192.168.1.3 \
       "https://freshrss.lan/api/fever.php?api&groups" \
       -d "api_key=3f8a9b1c2d4e5f6789012345678901ab"
   # {"api_version":3,"auth":1,"last_refreshed_on_time":"...","groups":[...]}
   ```
   Si `auth:1` en la respuesta JSON, la API está funcionando. Si `auth:0`, la API password no se aplicó — repetir el paso 2 a mano.

### 4. Configurar un cliente móvil (Reeder / FluentReader / Newsfold)

Ejemplo con **Newsfold** (Android, gratis, FOSS, F-Droid):

1. Instalar Newsfold desde F-Droid o Play Store.
2. **Add account** → seleccionar **Google Reader API** o **FreshRSS**.
3. **Server URL**: `https://freshrss.lan` (cuando estás en LAN) o `https://pi.<tailnet>.ts.net` (cuando estás fuera, vía Tailscale).
4. **Username**: `_default`.
5. **Password**: la **API password** (no la web password).
6. **Sync**. Tras 30-60 s, todos los feeds y el estado de lectura están en el móvil.

> **Cuando la app no acepta certificados auto-firmados**: la CA local del homelab no está instalada en el móvil. Solución: instalarla (procedimiento en `docs/03-red/04-caddy.md` → "Distribuir la CA en clientes Android/iOS"). Alternativa rápida: usar la app **sólo cuando se está conectado vía Tailscale** (cuyas conexiones llevan certificados de la CA Tailscale, autotrust en cualquier dispositivo del tailnet).

### 5. Configurar el refresco automático de feeds

El cron interno está activo (`CRON_MIN=13,43`). Verificarlo:

```bash
docker exec freshrss cat /etc/cron.d/freshrss
# 13,43 * * * * www-data /usr/local/bin/php /var/www/FreshRSS/app/actualize_script.php

docker exec freshrss tail -f /var/www/FreshRSS/data/users/_default/log_user.txt
# (tras unos minutos verás líneas tipo:)
# 2026-04-25 12:43:01 INFO Started feed refresh
# 2026-04-25 12:43:08 INFO Refreshed 47 feeds, 312 new entries
# 2026-04-25 12:43:08 INFO Finished feed refresh
```

> **Si el cron no se dispara**: verificar `docker exec freshrss ps aux | grep cron` que `cron` está corriendo. Si no, `docker compose restart freshrss` (la imagen arranca cron como _supervisor_; un fallo en el arranque lo deja sin levantarlo).

### 6. (Opcional) Instalar extensiones comunitarias

FreshRSS tiene un repositorio de **extensiones comunitarias** que añaden funcionalidades concretas: _YouTube Channels_ (convierte URLs de canales YouTube en feeds RSS dentro de FreshRSS), _Auto Translate_ (traduce entradas en idiomas extranjeros con DeepL), _Reddit_ (mejora el _rendering_ de feeds de Reddit), _Tweaks_ (atajos de teclado adicionales), etc.

Procedimiento:

```bash
# 1. Clonar el repositorio de extensiones comunitarias dentro del bind mount de extensions/
sudo git clone --depth 1 https://github.com/FreshRSS/Extensions \
    /tmp/freshrss-extensions

# 2. Copiar SÓLO las que interesen al bind mount (ejemplo: YouTube y Auto Translate):
sudo cp -r /tmp/freshrss-extensions/xExtension-YouTube \
    /mnt/hd2t/services/freshrss/extensions/
sudo cp -r /tmp/freshrss-extensions/xExtension-AutoTranslate \
    /mnt/hd2t/services/freshrss/extensions/
sudo chown -R 33:33 /mnt/hd2t/services/freshrss/extensions

# 3. Limpiar el clone temporal:
sudo rm -rf /tmp/freshrss-extensions

# 4. En la UI: Settings → Extensions → activar las recién copiadas.
```

> **Confiabilidad**: el repositorio oficial (`FreshRSS/Extensions`) contiene extensiones revisadas. Repos de terceros existen pero meten código PHP en el contenedor — auditar antes de copiar nada.

### 7. **Sí aplica**: descomentar el _hook_ de Borgmatic

A diferencia de Stirling-PDF (Categoría E), FreshRSS **sí entra** en Borgmatic. Editar `~/homelab/backups/borgmatic/hooks/dump-databases.sh` y descomentar la línea preparada en `docs/07-backups/03-backup-docker-volumes.md`:

```bash
$EDITOR ~/homelab/backups/borgmatic/hooks/dump-databases.sh
```

Buscar la línea:

```bash
# --- FreshRSS (SQLite por defecto) — docs/11-productividad/07-freshrss.md
# dump_sqlite freshrss freshrss /var/www/FreshRSS/data/users/_default/db.sqlite
```

Y dejarla así (sin `#` delante de `dump_sqlite`):

```bash
# --- FreshRSS (SQLite por defecto) — docs/11-productividad/07-freshrss.md
dump_sqlite freshrss freshrss /var/www/FreshRSS/data/users/_default/db.sqlite
```

Validar el hook con un dry-run:

```bash
sudo bash ~/homelab/backups/borgmatic/hooks/dump-databases.sh
# [INFO] Dumping mealie (SQLite)
# [INFO] Dumping linkding (SQLite)
# [INFO] Dumping freshrss (SQLite)         ← nuevo
# [INFO] Dumping bookstack (MariaDB)
# [INFO] Dumping paperless (PostgreSQL)
# [INFO] Done. Dumps in /mnt/hd2t/backups/dumps/

ls -la /mnt/hd2t/backups/dumps/freshrss-*.sqlite
# -rw-r--r-- 1 root root  ... freshrss-_default.sqlite       ← snapshot consistente
```

> **Si la copia falla con "no such file" / "database is locked"**: el path puede ser distinto si en algún momento el operador cambió de username (no debería: `_default` es lo configurado). Confirmar que el fichero existe dentro del contenedor: `docker exec freshrss ls -la /var/www/FreshRSS/data/users/`. Si el directorio del usuario no es `_default`, ajustar la línea del hook.

> **Multiusuario en el futuro**: si en algún momento se añaden más usuarios, el hook actual sólo respalda al `_default`. Sustituirlo por un loop:
>
> ```bash
> for user_dir in $(docker exec freshrss ls /var/www/FreshRSS/data/users/); do
>     dump_sqlite freshrss "freshrss-${user_dir}" \
>         "/var/www/FreshRSS/data/users/${user_dir}/db.sqlite"
> done
> ```

Commitear el cambio:

```bash
git -C ~/homelab add backups/borgmatic/hooks/dump-databases.sh
git -C ~/homelab commit -m "feat(backups): enable FreshRSS SQLite dump hook"
```

### 8. (No aplica) _jail_ de fail2ban

FreshRSS sirve un formulario de login con _rate limiting_ nativo (configurable en `Settings → Authentication → Brute force protection`) que bloquea IP tras 3-5 intentos fallidos. **No hace falta** un _jail_ específico para `freshrss` en `docs/04-seguridad/02-fail2ban.md`. Si el operador quiere reforzar (la familia es lo bastante mayor para teclear bien una password al primer intento), un _jail_ que parsee `data/logs/access_*.log` por entradas con _user-agent_ y código 401 es opcional, no se aplica aquí.

---

## Verificación final

Antes de pasar a `docs/12-dashboards/01-homepage.md`, comprobar:

- [ ] `docker compose -f ~/homelab/productividad/docker-compose.yml ps` muestra los **doce** contenedores (`vaultwarden`, `bookstack-db`, `bookstack`, `linkding`, `paperless-db`, `paperless-redis`, `paperless-gotenberg`, `paperless-tika`, `paperless`, `mealie`, `stirling-pdf`, `freshrss`) en `(healthy)`.
- [ ] `docker exec freshrss curl -fsS -o /dev/null -w '%{http_code}' http://localhost/i/` devuelve `302` (redirect al login) o `200`.
- [ ] **Sin sesión** en el navegador: `https://freshrss.lan/` redirige a `https://freshrss.lan/i/?c=auth&a=login` y muestra el formulario de FreshRSS (NO Authelia — confirmación de que `import authelia` no está aplicado por error).
- [ ] **Con sesión válida**: tras login con `_default` + `ADMIN_PASSWORD`, la home carga con los feeds importados y la lista de _unread_.
- [ ] **Test de OPML**: el `.opml` del operador se importó, las categorías están bien, y `Refresh all` descargó las entradas más recientes en <5 min.
- [ ] **Test de API Fever**:
  ```bash
  HASH=$(echo -n "_default:<API_PASSWORD>" | md5sum | awk '{print $1}')
  curl -k --resolve freshrss.lan:443:192.168.1.3 \
      "https://freshrss.lan/api/fever.php?api&groups" \
      -d "api_key=${HASH}" | head -c 200
  # {"api_version":3,"auth":1,"last_refreshed_on_time":"...",...
  ```
  El `auth:1` confirma que la API y la API password funcionan.
- [ ] **Test de cliente móvil**: Newsfold (o Reeder, o FluentReader) sincroniza correctamente contra `https://freshrss.lan` con username `_default` + API password. Marcar una entrada como leída desde el móvil y comprobar que el web la muestra como leída en <30 s.
- [ ] **Cron interno activo**: `docker exec freshrss tail -20 /var/www/FreshRSS/data/users/_default/log_user.txt` muestra al menos un ciclo de refresco completo (líneas con "Started feed refresh" y "Finished feed refresh").
- [ ] `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` lista a `freshrss` (entre los demás del homelab); **NO** lista a `freshrss` en `productividad-internal`:
  ```bash
  docker network inspect productividad-internal --format '{{range .Containers}}{{.Name}} {{end}}'
  # Debe listar bookstack bookstack-db paperless paperless-db paperless-redis
  # paperless-gotenberg paperless-tika  (freshrss NO debe estar).
  ```
- [ ] **Memoria controlada**: `docker stats freshrss --no-stream --format '{{.MemUsage}}'` reporta uso de RAM <250 MiB en idle (típico ~80-120 MiB; pico durante refresco ~150-200 MiB).
- [ ] Permisos del bind mount:
  ```bash
  stat -c '%U:%G' /mnt/hd2t/services/freshrss/data
  # www-data:www-data    (UID/GID 33:33)
  ```
- [ ] **Borgmatic incluye FreshRSS**:
  ```bash
  sudo bash ~/homelab/backups/borgmatic/hooks/dump-databases.sh
  ls -la /mnt/hd2t/backups/dumps/freshrss-_default.sqlite
  # -rw-r--r-- ... (fichero de varios KB-MB)
  sqlite3 /mnt/hd2t/backups/dumps/freshrss-_default.sqlite "SELECT COUNT(*) FROM feed;"
  # <número de feeds importados>
  ```
- [ ] Tras un `docker compose -f ~/homelab/productividad/docker-compose.yml restart freshrss`, el contenedor vuelve a `(healthy)` en <30 s y el cron sigue corriendo en los minutos `13,43`.
- [ ] Tras un `sudo reboot` de la Pi, los doce contenedores vuelven a estar `(healthy)` sin intervención manual y `https://freshrss.lan/` responde con la sesión del operador (cookie de PHP persistente vía `data/users/_default/`).
- [ ] `git -C ~/homelab status` muestra como **modificados**: `productividad/docker-compose.yml`, `productividad/.env.example`, `red/Caddyfile`, `backups/borgmatic/hooks/dump-databases.sh`. **No** muestra `productividad/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add productividad/docker-compose.yml productividad/.env.example \
          red/Caddyfile backups/borgmatic/hooks/dump-databases.sh
  git commit -m "feat(productividad): add FreshRSS (SQLite, Fever/GReader API, Borgmatic hook)"
  ```

---

## Backup

| Qué                                       | Dónde                                                                          | Cómo                                                       |
|-------------------------------------------|--------------------------------------------------------------------------------|------------------------------------------------------------|
| `docker-compose.yml`, `.env.example`      | `~/homelab/productividad/`                                                     | git                                                        |
| Bloque del `Caddyfile`                    | `~/homelab/red/Caddyfile`                                                      | git                                                        |
| Hook de Borgmatic                         | `~/homelab/backups/borgmatic/hooks/dump-databases.sh`                          | git                                                        |
| `.env` con `ADMIN_PASSWORD` y `ADMIN_API_PASSWORD` | `~/homelab/productividad/.env`                                                 | **Vaultwarden** (custodia: entrada "FreshRSS — Homelab")  |
| `data/users/_default/db.sqlite` (BD)      | `/mnt/hd2t/services/freshrss/`                                                 | **Borgmatic** (Categoría B): `dump_sqlite` previo + `source_directory` global incluyendo `/mnt/hd2t/services/freshrss/` (excepto el SQLite vivo, snapshotted al `dumps/` por el hook). |
| `data/cache/` y `data/logs/`              | `/mnt/hd2t/services/freshrss/data/`                                            | **Borgmatic** (en el set "data", regenerable pero barato)  |
| `extensions/`                             | `/mnt/hd2t/services/freshrss/extensions/`                                      | **Borgmatic** (regenerable desde upstream pero pequeño)    |
| Estado de lectura/favourites              | `db.sqlite`                                                                    | Vía dump SQLite (Categoría B)                              |
| OPML del operador                         | importado en `db.sqlite`; opcionalmente exportado con `Subscriptions management → Export OPML` | git en `~/homelab/productividad/freshrss/feeds.opml` (opcional, _backup of last resort_) |

> **Restauración tras desastre**:
>
> 1. Restaurar el repo `~/homelab/` desde git remoto (Codeberg/GitHub privado).
> 2. Restaurar `~/homelab/productividad/.env` con los valores custodiados en Vaultwarden (admin password y API password).
> 3. Restaurar `/mnt/hd2t/services/freshrss/` desde el repo Borg más reciente (`borgmatic restore --archive latest --repository ~/homelab/backups/borg-repo --pattern '+/mnt/hd2t/services/freshrss/'`).
> 4. Restaurar `db.sqlite` desde el dump consistente: `cp /mnt/hd2t/backups/dumps/freshrss-_default.sqlite /mnt/hd2t/services/freshrss/data/users/_default/db.sqlite && sudo chown 33:33 ...`.
> 5. `make up STACK=productividad` — FreshRSS arranca, detecta la BD existente (no re-crea el admin: las variables `ADMIN_*` sólo se aplican si `data/` está vacío), y queda listo. Estado de lectura, favourites, categorías y feeds preservados.
> 6. Re-conectar los clientes móviles (Reeder, Newsfold) — la API password no cambió, así que basta con hacer `Sync` y vuelven a operar.

> **Antes de cualquier upgrade _minor_ de FreshRSS** (1.26 → 1.27 → 1.28):
> 1. Editar `.env`: `FRESHRSS_IMAGE_TAG=1.27.0` (leer el _changelog_ upstream — algunos _bumps minor_ traen migraciones automáticas que cambian columnas en SQLite, irreversibles).
> 2. **Snapshot manual** de la BD antes del pull: `sudo cp /mnt/hd2t/services/freshrss/data/users/_default/db.sqlite /mnt/hd2t/backups/manual/freshrss-pre-1.27.0.sqlite`.
> 3. `docker compose pull freshrss && docker compose up -d freshrss`.
> 4. `docker logs -f freshrss` — esperar a "Apache HTTP Server" y `(healthy)`. Las migraciones aparecen como `Running migration ###`.
> 5. `https://freshrss.lan/` — confirmar que la home carga, los feeds están y el estado de lectura sobrevive.
> 6. Si algo va mal: `docker compose down freshrss`, `restore manual snapshot`, restaurar `FRESHRSS_IMAGE_TAG=1.26.2`, `up -d freshrss`. **Sin pérdida de datos** del operador.
>
> Los _bumps_ de **patch** (1.26.2 → 1.26.3) los gestiona Watchtower automáticamente; el operador no necesita intervenir, pero **debería revisar el `docker logs freshrss` el día siguiente al pull** para confirmar que arrancó bien.

---

## Troubleshooting

### `freshrss` arranca y queda en `unhealthy`

El `start_period: 60s` da margen para PHP migrations + creación del admin. Si tras 2 minutos sigue `starting`/`unhealthy`, mirar los logs:

```bash
docker logs freshrss --tail 100
```

Causas frecuentes:

1. **Permisos del bind mount**: `cannot create config file: Permission denied` o `SQLSTATE[HY000]: General error: 8 attempt to write a readonly database`. Causa: el bind mount no tiene ownership `33:33`. Solución:
   ```bash
   sudo chown -R 33:33 /mnt/hd2t/services/freshrss/{data,extensions}
   docker compose -f ~/homelab/productividad/docker-compose.yml restart freshrss
   ```

2. **Variables `ADMIN_*` no presentes en el primer arranque**: si el `.env` no tiene `ADMIN_EMAIL`, `ADMIN_PASSWORD`, `ADMIN_API_PASSWORD`, la imagen arranca pero no crea el admin. Login imposible. Solución: verificar el `.env`:
   ```bash
   grep -E '^ADMIN_' ~/homelab/productividad/.env
   # ADMIN_EMAIL=...
   # ADMIN_PASSWORD=...
   # ADMIN_API_PASSWORD=...
   ```
   Y, si el `data/` ya se creó vacío sin el admin, **borrarlo y reiniciar** (sólo seguro si NO hay datos del operador):
   ```bash
   sudo rm -rf /mnt/hd2t/services/freshrss/data/*
   sudo chown -R 33:33 /mnt/hd2t/services/freshrss/data
   docker compose restart freshrss
   ```

3. **Migración fallida en upgrade**: `Migration ### failed: <SQL error>`. Causa: SQLite con un schema incompatible con la nueva versión. Solución: **rollback** al tag anterior, restaurar la BD del snapshot manual, investigar el _changelog_ upstream antes de reintentar.

4. **`X-Forwarded-Proto` no se respeta**: la home carga pero el navegador da _mixed content errors_ (CSS y JS tirados de `http://...` mezclados con la página `https://...`). Causa: `TRUSTED_PROXY` no incluye la IP de Caddy. Solución: confirmar que `TRUSTED_PROXY=172.20.10.0/24` cubre la red Docker, o usar `0.0.0.0/0` si fuese necesario (menos seguro, pero aceptable en LAN aislada).

5. **PHP fatal error**: `PHP Fatal error: Uncaught Error: Class "..." not found` en los logs. Causa: imagen corrupta o pull incompleto. Solución: `docker rmi freshrss/freshrss:1.26.2 && docker compose up -d freshrss` para forzar un re-pull limpio.

### `502 Bad Gateway` desde Caddy hacia `freshrss`

Caddy responde 502 si no puede alcanzar `freshrss:80` desde la red `homelab`. Probar:

```bash
docker exec caddy curl -fsS -o /dev/null -w '%{http_code}' http://freshrss:80/i/
# 200 o 302  — si devuelve esto, Caddy está bien y el problema es otro.
# "Connection refused": FreshRSS no está sirviendo. Pasar al caso anterior.

docker exec caddy nslookup freshrss
# Debe resolver a una IP del 172.20.10.0/24.
```

Causas:

1. FreshRSS en `unhealthy` — ver caso anterior.
2. `freshrss` no está enganchado a `homelab` (mira con `docker network inspect homelab`). Si no está, revisar la sección `networks:` del compose y `up -d freshrss` de nuevo.
3. `freshrss` está en `homelab` pero el alias DNS no está propagado (raro). Reinicio del contenedor lo arregla.

### El cliente móvil falla con `auth:0` o `Unauthorized`

Diagnóstico:

```bash
# Confirmar que la API responde:
HASH=$(echo -n "_default:<API_PASSWORD>" | md5sum | awk '{print $1}')
curl -k --resolve freshrss.lan:443:192.168.1.3 \
    "https://freshrss.lan/api/fever.php?api&groups" \
    -d "api_key=${HASH}"
# Si devuelve auth:0, la API password no está activa o no coincide.
```

Causas:

1. **API password sin _set_ en la UI**: pasar a `Settings → Authentication → API access` y pegar la password manualmente (ver **Configuración → 3**).
2. **Cliente usa la web password en lugar de la API password**: confusión común. La API password es la **segunda** entrada en la entrada de Vaultwarden, distinta de la web password.
3. **Username mal escrito**: el username es `_default` (con guion bajo al principio), no `default`. Sensible a mayúsculas: `_default` ≠ `_Default`.
4. **HTTPS estricto en el cliente**: si el cliente rechaza el certificado autofirmado de la CA local, falla antes de llegar a la auth. Solución: instalar la CA local en el dispositivo (ver `docs/03-red/04-caddy.md`) o conectarse vía Tailscale (con su propia CA gestionada).

### Feeds no se actualizan automáticamente (cron interno no dispara)

Diagnóstico:

```bash
docker exec freshrss ps aux | grep cron
# Debe haber un proceso 'cron' o 'crond' corriendo.

docker exec freshrss cat /etc/cron.d/freshrss
# 13,43 * * * * www-data /usr/local/bin/php /var/www/FreshRSS/app/actualize_script.php

docker exec freshrss tail -50 /var/log/cron.log 2>/dev/null || \
    docker exec freshrss tail -50 /var/www/FreshRSS/data/users/_default/log_user.txt
```

Causas:

1. **`CRON_MIN` mal interpretado**: si `CRON_MIN=` (vacío), no se instala el cron. Si `CRON_MIN=*/15`, cada 15 min. Confirmar el `.env`.
2. **`cron` no arrancó como _supervisor_**: la imagen usa un script de entrypoint que arranca `cron` y `apache2` como dos procesos. Si uno falla (raro), el otro queda solo. Solución: `docker compose restart freshrss`.
3. **TZ del contenedor desincronizada**: el cron se ejecuta en UTC del contenedor si `TZ=Europe/Madrid` no se aplica correctamente (caso muy raro, requeriría que `freshrss/freshrss` ignore `TZ`). Solución: verificar `docker exec freshrss date` que muestra la hora correcta de Madrid; si no, añadir el bind mount `/etc/timezone:/etc/timezone:ro` y `/etc/localtime:/etc/localtime:ro`.
4. **Refresco manual sí funciona**: si `Subscriptions management → Refresh all` actualiza los feeds correctamente pero el cron no, el problema es del cron, no de la app. Como _workaround_ temporal: el operador puede dejar abierta una pestaña del navegador y refrescar a mano cuando le dé la gana, mientras se diagnostica.

### Un feed concreto da error y no se actualiza nunca

FreshRSS marca los feeds problemáticos en rojo. Click en el feed → `Stats and properties` muestra:

- **Last update**: cuándo se intentó por última vez.
- **Error**: mensaje del fallo (`HTTP 404`, `Could not parse XML`, `cURL timeout`, etc).

Causas frecuentes:

1. **URL del feed cambió**: la web movió su feed a otra URL. Solución: `Edit → Feed URL` y poner la nueva.
2. **Feed bloquea User-Agent de FreshRSS**: algunos sitios (CloudFlare _agresivo_, sitios anti-scraping) devuelven 403 al UA de FreshRSS. Solución: `Edit → Advanced → User Agent` y poner uno de navegador estándar (`Mozilla/5.0 (X11; Linux x86_64) ...`).
3. **Feed requiere auth**: HTTP basic auth en feeds privados. Solución: `Edit → Authentication`.
4. **Timeout en feeds lentos**: por defecto 5 s, ampliable a 30 s desde `Settings → Reading → Per-feed settings`.
5. **El sitio fuente no existe**: si el blog cerró, el feed dará 404 o ECONNREFUSED indefinidamente. Eliminar el feed (`Delete`).

### La BD SQLite crece sin control

Síntomas: `du -sh /mnt/hd2t/services/freshrss/data/users/_default/db.sqlite` reporta varios GB tras un año de uso.

Causa: la política de retención por feed está desactivada, o cada feed publica con frecuencia muy alta y se acumulan miles de entradas.

Diagnóstico:

```bash
docker exec freshrss sqlite3 /var/www/FreshRSS/data/users/_default/db.sqlite \
    "SELECT name, count(*) AS n FROM feed JOIN entry ON entry.id_feed = feed.id GROUP BY name ORDER BY n DESC LIMIT 10;"
# Lista los 10 feeds con más entradas almacenadas.
```

Solución:

1. **Activar la purga global**: `PURGE_INTERVAL_SECONDS=2592000` (30 días) en el `.env`, `restart freshrss`. Las entradas más viejas que 30 días se purgan en el próximo cron de mantenimiento.
2. **Purga puntual desde la CLI**:
   ```bash
   docker exec -u www-data freshrss \
       php /var/www/FreshRSS/cli/db-optimize.php
   # VACUUM + ANALYZE + purga según política.
   ```
3. **Política por feed**: para feeds especialmente ruidosos, `Edit → Archiving → Number of articles to keep` (p.ej. 50) anula la política global y guarda sólo los más recientes.

### Importación OPML falla parcialmente

Síntomas: tras subir el OPML, algunos feeds aparecen como suscritos pero otros no. La UI muestra mensajes de error.

Causas:

1. **Feeds duplicados**: FreshRSS rechaza un feed con la misma URL que ya existe (no es un error, es una característica). Aparecen en el log de importación pero no en la lista de errores.
2. **OPML mal formado**: algunos exportadores (versiones viejas de Feedly, Reeder) producen XML con caracteres no escapados que rompen el parser. Solución: validar el OPML con `xmllint --noout export.opml`. Si da error, abrirlo en un editor y arreglar a mano (o usar un servicio online de _OPML cleaner_, p.ej. https://opml.fivefilters.org/).
3. **Demasiados feeds a la vez**: importaciones de >1000 feeds pueden _timeout_-ear en PHP. Solución: dividir el OPML en lotes de 200-300 (cualquier editor permite cortar `<outline>` blocks) e importar por separado.

---

## Migrar a OIDC con Authelia (opcional)

FreshRSS soporta autenticación por **REMOTE_USER** (cabecera HTTP `X-Forwarded-User` / `Remote-User` / `X-WEBAUTH-USER` puesta por un _trusted proxy_). Esto permite integrar con Authelia **sin** poner Authelia delante via `forward_auth` clásico — en su lugar, Caddy autentica al usuario contra Authelia por una _request_ paralela y, si la sesión es válida, pasa la cabecera `Remote-User: <username>` a FreshRSS, que la respeta.

Procedimiento (sólo cuando se decida unificar SSO):

1. **Activar el modo REMOTE_USER en FreshRSS**:
   ```bash
   # En ~/homelab/productividad/.env, añadir:
   FRESHRSS_AUTH_TYPE=http_auth     # acepta REMOTE_USER del proxy
   ```
2. **En el `Caddyfile`**, sustituir el bloque `freshrss.lan` por uno con `forward_auth` que ponga la cabecera `Remote-User`:
   ```caddy
   freshrss.lan {
       tls internal
       import security-headers
       import logging

       forward_auth authelia:9091 {
           uri /api/verify?rd=https://auth.lan/
           copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
       }

       reverse_proxy freshrss:80 {
           header_up Host {host}
           header_up X-Real-IP {remote_host}
           header_up X-Forwarded-For {remote_host}
           header_up X-Forwarded-Proto {scheme}
           header_up X-Forwarded-Host {host}
           # FreshRSS espera Remote-User en una cabecera específica:
           header_up Remote-User {http.request.header.Remote-User}
       }
   }
   ```
3. **Crear el usuario en FreshRSS** con el mismo username que en Authelia (si Authelia gestiona `operador`, el usuario en FreshRSS debe ser `operador`, no `_default`). Esto requiere migrar:
   - `Settings → User management → Add user → operador` (con la web password vacía o aleatoria — no se va a usar).
   - Mover la BD: `mv data/users/_default data/users/operador && chown -R 33:33 data/users/`.
   - Actualizar el _hook_ de Borgmatic: `dump_sqlite freshrss freshrss /var/www/FreshRSS/data/users/operador/db.sqlite`.
4. **Las APIs Fever/GReader se ven afectadas**: el modo REMOTE_USER autentica al humano, pero las APIs siguen necesitando la API password. Reeder/Newsfold no rompen — siguen usando `_default:<api>` o `operador:<api>` como antes.

> **Coste**: migrar requiere coordinar con el resto del _stack_ (Bookstack, Linkding, Mealie también tendrían sentido en SSO). **No se aplica por defecto**: hasta que la fricción de tener una password por servicio sea inaceptable, conviene mantener auth nativa.

---

## Multiusuario (futuro)

Si en algún momento se añaden más usuarios (la pareja del operador, los hijos, un invitado), el procedimiento es:

1. **Crear el usuario** desde la UI del admin: `Settings → User management → Add user`. Definir username, email, web password y API password (la API password es independiente por usuario).
2. **Compartir el endpoint** (`https://freshrss.lan` o vía Tailscale) y las credenciales con el nuevo usuario, custodiadas en su propio Vaultwarden / vault familiar.
3. **Adaptar el _hook_ de Borgmatic** para iterar (ver bloque comentado en **Configuración → 7**).
4. **Revisar el _disk usage_**: cada usuario tiene su `db.sqlite` independiente; un usuario muy activo con 500 feeds puede llegar a varios cientos de MB.

> FreshRSS **no comparte feeds entre usuarios** (a diferencia de Bookstack que sí tiene "shelves" compartidos). Cada usuario tiene su propio OPML, sus categorías y su estado de lectura. Esto es deliberado y correcto para el modelo de "lector personal".

---

## Cron externo en lugar del interno (opcional)

Si en algún momento el operador prefiere un control más fino del refresco (p.ej. lanzarlo manualmente desde Home Assistant cuando el operador llega a casa, o desactivarlo durante backups nocturnos):

1. **Desactivar el cron interno**:
   ```bash
   # En .env:
   CRON_MIN=
   ```
   Y `restart freshrss`. La imagen arrancará sin el supervisor `cron`.
2. **Programar desde el host** un cron equivalente:
   ```cron
   # /etc/cron.d/freshrss-refresh
   13,43 * * * * root docker exec -u www-data freshrss /usr/local/bin/php /var/www/FreshRSS/app/actualize_script.php >/dev/null 2>&1
   ```
3. **O integrar con Home Assistant** vía un `command_line` que lance el `docker exec` cuando se cumpla una condición.

> **No se aplica por defecto** por simplicidad. Mantener el cron encapsulado en el contenedor es coherente con el resto del homelab; el operador no debería tener crons en `/etc/cron.d/` para servicios Docker salvo casos justificados.

---

## Referencias

- **FreshRSS — repositorio oficial**: https://github.com/FreshRSS/FreshRSS
- **FreshRSS — documentación**: https://freshrss.github.io/FreshRSS/en/
- **FreshRSS — imagen Docker**: https://hub.docker.com/r/freshrss/freshrss
- **FreshRSS — variables de entorno de la imagen**: https://github.com/FreshRSS/FreshRSS/blob/edge/Docker/README.md
- **FreshRSS — Extensions community repo**: https://github.com/FreshRSS/Extensions
- **Google Reader API (compatibilidad FreshRSS)**: https://github.com/FreshRSS/FreshRSS/blob/edge/docs/en/users/06_GoogleReaderAPI.md
- **Fever API (compatibilidad FreshRSS)**: https://github.com/FreshRSS/FreshRSS/blob/edge/docs/en/users/07_FeverAPI.md
- **OPML 2.0 spec** (formato de import/export): http://opml.org/spec2.opml
- **RSSHub — feeds RSS para webs sin RSS** (futuro candidato a sidecar): https://docs.rsshub.app/
- **Documentación interna**:
  - `docs/02-docker/02-estructura-compose.md` — definición del _stack_ `productividad`.
  - `docs/02-docker/04-watchtower.md` — convención `com.centurylinklabs.watchtower.enable` y lista de servicios opt-in (incluye FreshRSS).
  - `docs/03-red/04-caddy.md` — _snippets_ `security-headers`, `logging` y CA local.
  - `docs/04-seguridad/01-authelia.md` — Authelia (referencia para la migración OIDC opcional).
  - `docs/07-backups/01-estrategia-backup.md` — clasificación A/B/C/D/E (FreshRSS es Categoría B).
  - `docs/07-backups/02-borgmatic.md` — set "data" que cubre `/mnt/hd2t/services/freshrss/`.
  - `docs/07-backups/03-backup-docker-volumes.md` — patrón S (`dump_sqlite`) y bloque para FreshRSS.
  - `docs/11-productividad/01-vaultwarden.md` — _stack_ `productividad` y `~/homelab/productividad/.env`.
  - `docs/11-productividad/03-linkding.md` — patrón Django + SQLite + token API (análogo al patrón Fever/GReader de FreshRSS).
  - `docs/11-productividad/05-mealie.md` — patrón FastAPI + SQLite + bearer token.
  - `docs/11-productividad/06-stirling-pdf.md` — documento previo del _stack_.
  - `docs/12-dashboards/01-homepage.md` — siguiente documento (nuevo _stack_ `dashboards`).
