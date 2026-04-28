# FreshRSS

## Descripción

Despliegue de **FreshRSS** ([imagen `freshrss/freshrss`](https://hub.docker.com/r/freshrss/freshrss)) como **agregador de feeds RSS/Atom/JSON Feed** del homelab. FreshRSS es una aplicación PHP 8.x (Apache + `mod_php` o PHP-FPM, según variante de imagen) escrita en español/francés/inglés con fuerte tradición de simplicidad, que **suscribe**, **parsea** y **archiva** feeds (RSS 0.9x/1.0/2.0, Atom 0.3/1.0, JSON Feed 1.x), aplica **filtros por palabras clave** (regex sobre título/contenido/autor), genera **categorías**, soporta **OPML** para importación/exportación masiva, expone una **API Google Reader** (también conocida como GReader API) y una **API Fever** que cubren el grueso de los clientes móviles y de escritorio del ecosistema RSS (Reeder, FluentReader, FeedMe, Readrops, Fluent Reader Lite, Capyreader, Newsboat con `--newsboat-as-greader-client`, Inoreader desktop por extensión), y refresca todo periódicamente vía un **cron interno** del propio contenedor (script `app/actualize_script.php` invocado por crond cada `$CRON_MIN`). Es la pieza canónica del homelab para "leo periódicamente las mismas fuentes (blogs, podcasts, listas de releases de GitHub, sitios de noticias) y quiero un buffer único, persistente, etiquetable y sincronizable entre dispositivos sin depender de servicios externos tipo Feedly/Inoreader/NewsBlur".

Por qué exactamente esta arquitectura, y no otra:

1. **FreshRSS, no Tiny Tiny RSS, no Miniflux, no Selfoss, no Stringer.** FreshRSS apunta al sweet spot del homelab familiar: (a) **Tiny Tiny RSS (tt-rss)** fue el referente histórico pero su mantenimiento es errático, su política de releases es exclusivamente "rolling" (solo `master`, sin tags semánticos), y su comunidad ha migrado masivamente a alternativas en 2022-2024; pin a una versión es imposible y eso choca frontalmente con la disciplina de "imágenes pinned" del homelab ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1); (b) **Miniflux** es excelente, escrito en Go (un único binario estático, ~30 MB de RAM, sin Apache ni PHP), su API es REST nativa muy limpia y soporta `Fever`/`GReader` también — el único motivo por el que **no** se elige aquí es que **Miniflux requiere PostgreSQL obligatoriamente** (no admite SQLite ni MariaDB, decisión técnica deliberada del autor para apoyarse en JSONB y full-text search nativos), lo que arrastra un contenedor PostgreSQL dedicado, una red interna, un secret BD, una entrada en `postgresql_databases` de Borgmatic, y rompe la coherencia del bloque "servicios SQLite" del homelab (Vaultwarden, Linkding, Authelia, Uptime Kuma) — la variante con Miniflux queda esbozada en §12.6 para el operador con afinidad por Go/Postgres; (c) **Selfoss** es ligero pero su última release estable (3.x) data de 2023 y el ecosistema de clientes móviles que la soportan se ha encogido; no expone GReader API, lo que rompe los lectores móviles populares; (d) **Stringer** está abandonado desde 2021. FreshRSS gana por: comunidad activa (releases ~3 meses, equipo Marien Fressinaud + comunidad francófona/internacional), soporte pleno de **GReader** + **Fever** + **API nativa REST FreshRSS** (la nueva, JSON, OAuth opcional), soporte de **OIDC opt-in** (Authelia como provider), extensiones (`xExtension-*`) instalables en caliente, y **portabilidad completa** vía OPML (todo el estado de feeds y categorías es exportable a un fichero `.opml` interoperable con cualquier otro agregador).

2. **Imagen `freshrss/freshrss:<version>` upstream, no `linuxserver/freshrss`.** A diferencia de Bookstack ([`./02-bookstack.md`](./02-bookstack.md) §0 punto 2), donde LSIO bundlea Apache + PHP-FPM + nginx en una receta probada, la imagen **upstream** de FreshRSS ya **es** monolítica y pulida: bundlea PHP 8.3 (CLI + `mod_php` para Apache, opcionalmente PHP-FPM con la variante `*-fpm`), Apache 2.4 con `mpm_event`, todas las extensiones PHP necesarias (`mbstring`, `intl`, `xml`, `gd`, `curl`, `iconv`, `pdo_sqlite`, `pdo_mysql`, `pdo_pgsql`, `zip`, `gmp`), un `crond` interno con tarea programada a `$CRON_MIN` que ejecuta `actualize_script.php`, locales `es_ES.UTF-8` + `en_US.UTF-8` + `fr_FR.UTF-8` baked-in, y un script `start.sh` que orquesta arranque, primera instalación opcional vía `FRESHRSS_INSTALL`, alta de admin opcional vía `FRESHRSS_USER` y supervisión de los procesos. La imagen LSIO `linuxserver/freshrss` existe y es válida pero añade un layer s6-overlay extra y su política de tags rolling dificulta el pinning exacto (suele ir a la zaga de la upstream en patches críticos). La etiqueta de imagen usada en este doc es `<version>` puntual (no `latest`, no `edge`, no `dev`); el canal recomendado en upstream es **`<version>-alpine`** o **`<version>-debian`** según preferencia del operador — el homelab usa **`<version>`** (Debian + Apache + `mod_php`, multi-arch incluyendo `linux/arm64`) por simplicidad y por consistencia con el resto de imágenes basadas en Debian (`watchtower`, `mariadb`, `postgres`).

3. **SQLite, no MariaDB, no PostgreSQL.** FreshRSS soporta nativamente cuatro motores: **SQLite** (default, fichero), **MySQL/MariaDB**, **PostgreSQL**. Dato peculiar y crítico de FreshRSS: **cada usuario tiene su propia base de datos** — la app crea `data/users/<username>/db.sqlite` (SQLite) o un schema separado por usuario (MySQL/PG) en el primer login. Eso significa que con SQLite, el operador del homelab con 1-3 usuarios humanos termina con 1-3 ficheros SQLite independientes, cada uno con su propia tabla `entry`, `feed`, `category`, `tag`, `entrytag`, `user`, `useredu`. Para un homelab familiar con 1-3 usuarios y ~50-300 feeds activos por usuario (~10 000-50 000 entries históricas con la retención por defecto de 6 meses): el throughput de escritura es **dominado por el cron de actualización** (cada 30 min, FreshRSS hace `INSERT INTO entry` por cada entry nueva detectada — 50-200 entries nuevas por ciclo en hogares activos), las lecturas son del orden de "operador abre la UI 2-3 veces/día y el lector móvil sincroniza 5-10 veces/día". SQLite con WAL absorbe ese perfil sin sudar. MariaDB/PostgreSQL serían valiosos para >5 usuarios humanos concurrentes con miles de feeds combinados, escenario fuera del alcance de este homelab. La decisión replica la de Linkding ([`./03-linkding.md`](./03-linkding.md) §0 punto 3) y Mealie ([`./05-mealie.md`](./05-mealie.md) §0 punto 3). El bloque `sqlite_databases` de Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6, líneas 547-548) ya tiene una entrada `freshrss` con `path: /mnt/hd2t/services/freshrss/data/db.sqlite` — **ese path es inexacto**: FreshRSS no almacena la BD en ese fichero, sino en `data/users/<username>/db.sqlite` (un fichero por usuario). Este doc deja constancia y, en §9.2, muestra el **patrón correcto** (una entrada `sqlite_databases` por usuario, materializada tras la creación del primer admin) y el **fallback** (si Borgmatic no se ajusta, el bind mount completo de `data/` ya queda capturado por `source_directories` y los ficheros SQLite se respaldan a nivel de fichero — menos consistente que un `.backup` SQLite, pero suficiente para entries que se redownloadan de los feeds de origen tras restore). Variantes con MariaDB y con PostgreSQL en §12.2 y §12.3.

4. **Detrás de Caddy con CA interna, **sin** Authelia delante.** Coherente con la lógica de [`./03-linkding.md`](./03-linkding.md) §0 punto 4 y [`./05-mealie.md`](./05-mealie.md) §0 punto 4: FreshRSS tiene **tres perfiles de cliente** que serían incompatibles con `forward_auth` de Authelia — (a) la **UI humana** en `/i/` (web): autenticada por sesión PHP nativa (cookie `Freshrss`), tolera Authelia delante en principio, pero comparte host con los endpoints de API (b) y (c); (b) la **API Google Reader** en `/api/greader.php/*` y `/p/api/greader.php/*`: punto de entrada de Reeder, FluentReader, FeedMe, Newsboat-greader, Inoreader desktop, Capyreader, Readrops — autenticación por **token GReader** (`Authorization: GoogleLogin auth=<token>`), donde el token se obtiene vía un `POST /accounts/ClientLogin` previo con username + "API password" (una password dedicada distinta de la web, generable desde **Configuration → Profile**); (c) la **API Fever** en `/api/fever.php`: punto de entrada de la rama de clientes históricos de Fever (incluido un fork de Reeder); auth vía **API password Fever** (también generable desde la UI). Authelia en `forward_auth` interceptaría las requests a `/api/greader.php` o `/api/fever.php` redirigiendo a `https://auth.lan/?rd=...` — los clientes RSS recibirían HTML en lugar de XML/JSON y la sincronización moriría inmediatamente. Y a diferencia de Paperless-ngx ([`./04-paperless-ngx.md`](./04-paperless-ngx.md) §0 punto 4), donde `/api/*` y la UI están en paths claramente separables con dos `handle` blocks, en FreshRSS los paths de API conviven con paths web (`/i/?c=...`, `/i/index.php`) bajo el mismo host y comparten cookies de sesión — cualquier separación path-based es frágil. La salida es Caddy reverse-proxy directo, sin Authelia. La regla `freshrss.{{ env "LAN_DOMAIN" }}` **no** se añade a `access_control.rules` de Authelia ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) líneas 419-424, lista actual: `bookstack`, `paperless`, `homepage`, `ha`, etc., **no** incluye `freshrss`). La auth la lleva el propio FreshRSS (PHP `password_hash` con `PASSWORD_BCRYPT` por defecto, opcional `PASSWORD_ARGON2ID` desde 1.20+). La variante con **OIDC** (Authelia como provider OIDC, FreshRSS como cliente OIDC) queda en §12.4 — es la forma correcta de aplicar SSO a FreshRSS sin romper la GReader/Fever API (que sigue usando sus tokens nativos en paralelo).

5. **Datos persistentes en `hd2t`, en `/mnt/hd2t/services/freshrss/`.** Coherente con [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.1 (loop "Fase 11 — Productividad", línea 241: `for svc in vaultwarden bookstack linkding paperless-ngx mealie stirling-pdf freshrss`). El árbol que se materializa en §3:
   - `/mnt/hd2t/services/freshrss/.env` — configuración del stack (chmod 600).
   - `/mnt/hd2t/services/freshrss/secrets/admin_password` — password inicial del admin de FreshRSS, custodiada (`chmod 600 root:homelab`).
   - `/mnt/hd2t/services/freshrss/data/` — bind mount de `/var/www/FreshRSS/data/` del contenedor:
     - `users/<username>/` — un directorio por usuario, contiene `db.sqlite` (BD por usuario), `config.php` (preferencias UI), `feeds/` (favicons cacheados de cada feed), `log_*.txt` (errores de actualización por usuario), `category-tree.txt` (caché del árbol de categorías).
     - `users/_/` — usuario "système" reservado por FreshRSS para datos globales (logs admin, ajustes globales).
     - `users/_default/` — esqueleto que FreshRSS copia al crear cada usuario nuevo.
     - `cache/` — caché HTTP de feeds (ETags, last-modified, contenido temporalmente parseado). Regenerable; no crítico.
     - `tmp/` — temporales de uploads OPML, exports, etc. Borrable.
     - `pubsubhubbub/` — estado de suscripciones a hubs PubSubHubbub/WebSub (para feeds que lo soportan, push en lugar de polling). Pequeño.
     - `users/_/log.txt` — log global del cron.
   - `/mnt/hd2t/services/freshrss/extensions/` — bind mount de `/var/www/FreshRSS/extensions/`, opcional: extensiones community (`xExtension-OriginalLink`, `xExtension-FilterAndPick`, `xExtension-RemovePopups`, `xExtension-YouTube`...). Si el operador no instala extensiones, queda vacío.
   - **El volumen real lo dominan los `users/<u>/db.sqlite`**: ~5-50 MB por usuario tras un año de uso normal con ~100-300 feeds suscritos y retención por defecto. Borgmatic los respalda mediante el dump SQLite por usuario (§9.2).

6. **Imagen pinned a release puntual; Watchtower HABILITADO.** Misma regla del homelab: nunca `latest`, nunca `edge`, nunca `dev`. **FreshRSS está en el grupo de auto-update** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.1 línea 94 y §4.2 línea 466 — "FreshRSS" listado explícitamente como `enable: "true"`). Justificación: (a) las release notes históricas de FreshRSS muestran que las migraciones de BD entre minor releases son **idempotentes** y se ejecutan automáticamente al primer login del admin tras el upgrade (no en arranque del contenedor — eso es importante); (b) cuando se introduce una migración disruptiva (ha pasado en 1.18 → 1.19 con la reorganización de la tabla `entrytag` y en 1.20 → 1.21 con cambios en `entry`), upstream publica un aviso explícito en `CHANGELOG.md` y la migración se aplica en una transacción única — un fallo deja la BD intacta y FreshRSS rechaza arrancar pidiendo `php cli/db-optimize.php`; (c) los rollbacks son triviales con SQLite (un `cp` del fichero pre-upgrade). El default de Watchtower aplica; **no** se añade `com.centurylinklabs.watchtower.enable: "false"`. La variante opt-in con hook `pre-update` (dump SQLite previo automatizado) queda en §12.7 para el operador que prefiera doble cinturón.

7. **`apache:apache` (UID 33:33) para el proceso del contenedor; bind mount con propietario 33:33.** La imagen oficial Debian de FreshRSS ejecuta Apache + PHP como `www-data` (UID/GID 33), heredado de la convención Debian estándar. La imagen Alpine variante ejecuta como `apache` UID 100. Este doc usa la **variante Debian** (`freshrss/freshrss:<version>`, sin sufijo Alpine) y por tanto el bind mount en `/mnt/hd2t/services/freshrss/data/` se crea con propietario `33:33`. **No** se usan PUID/PGID estilo LSIO (la imagen upstream no los implementa). El operador (UID 1000) accede a los ficheros SQLite vía `sudo` cuando hace inspecciones manuales; Borgmatic ya corre como root vía systemd unit ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §4) y los lee sin fricción. Misma decisión que Linkding ([`./03-linkding.md`](./03-linkding.md) §0 punto 7), distinta de Mealie (que sí soporta PUID/PGID 1000:1000 y se usa allí porque el operador a menudo manipula directamente las imágenes de receta desde Samba/Nextcloud — caso que aquí no aplica: las "imágenes" de FreshRSS son favicons cacheados regenerables).

8. **Auto-instalación al primer arranque vía `FRESHRSS_INSTALL` y `FRESHRSS_USER` env vars; password admin custodiada en `secrets/admin_password`.** La imagen oficial soporta dos variables de entorno especiales que su `start.sh` interpreta cuando la BD aún no existe: (a) `FRESHRSS_INSTALL` con los argumentos del CLI `cli/do-install.php` (motor de BD, idioma, default user); (b) `FRESHRSS_USER` con los argumentos del CLI `cli/create-user.php` (username + password + tipo de usuario). El homelab las usa **una sola vez** para bootstrap. La password va en plaintext en el `.env` con `chmod 600`, se rota desde la UI (`/i/?c=user&a=profile`) tras el primer login, y a partir de ese momento la fuente de verdad es la BD (hash bcrypt). El plaintext queda históricamente en el `.env` por si se reinstala el stack sobre datos vacíos. La generación se hace en §3.3 con `openssl rand -base64 32`. Misma estética que Linkding §0 punto 10.

9. **`CRON_MIN='1,31'` (FreshRSS refresca feeds dos veces por hora).** El cron interno del contenedor invoca `php cli/actualize_script.php --userlist` cada `$CRON_MIN` minutos. El default upstream es `'1,31'` (minuto 1 y 31 de cada hora) — el homelab respeta ese default por dos motivos: (a) **balance entre frescura y carga**: minuto 1 y 31 distribuye la carga en dos picos por hora, suficiente para el caso de uso "leer noticias en el desayuno y por la tarde"; (b) **respeto a los servidores remotos**: refrescar cada 5 minutos como hacen algunos lectores agresivos genera tráfico innecesario y en sitios con `Cache-Control` se traduce en `304 Not Modified` la mayoría de las veces, pero ocupa slots TCP en feeds operados por blogueros amateur que no esperan ese ritmo. El operador puede ajustarlo a `*/15` (cada 15 min) o `*/5` (cada 5 min) editando el `.env` y recreando el contenedor. **No** se delega el cron al host (cron del Pi llamando `docker exec freshrss php cli/actualize_script.php`): añade una pieza más, fragmenta la observabilidad (los logs quedarían fuera de `docker logs`) y rompe el principio de "el contenedor es autocontenido".

10. **`COPY_LOG_TO_SYSLOG=Off`, `COPY_SYSLOG_TO_STDERR=On`.** La imagen oficial soporta dos toggles de redirección de logs: `COPY_LOG_TO_SYSLOG` redirige los logs PHP/Apache de FreshRSS al syslog del contenedor, y `COPY_SYSLOG_TO_STDERR` reenvía ese syslog al stderr del PID 1 (para que `docker logs freshrss` los muestre). El homelab quiere **todos los logs en `docker logs`** (driver `json-file`, rotación de Docker, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6) — combinación: `COPY_LOG_TO_SYSLOG=Off` (FreshRSS escribe directamente a stderr cuando el wrapper lo permite, sin pasar por syslog innecesariamente) y `COPY_SYSLOG_TO_STDERR=On` (los pocos logs que sí pasan por syslog, como los de Apache, también acaban en stderr). Combinación recomendada por upstream para Docker. Sin esto, los logs PHP de errores en feeds rotos quedarían "atrapados" en `data/users/<u>/log_<feed>.txt` dentro del bind mount, fuera de la observabilidad estándar.

11. **`TRUSTED_PROXY=172.20.0.0/24` para que FreshRSS confíe en `X-Forwarded-*` de Caddy.** FreshRSS (Apache) registra la IP del cliente en sus logs (`access_log`) y la usa para detectar si la sesión web vino de una IP "razonable" cuando se generan tokens GReader/Fever. Detrás de un reverse proxy, la IP que ve Apache es la IP del contenedor `caddy` (típicamente `172.20.0.X`), lo que (a) ensucia los logs de auditoría con la misma IP siempre y (b) impide aplicar reglas defensivas tipo "el token GReader se usa siempre desde la misma IP del cliente". `TRUSTED_PROXY` define el CIDR de proxies confiables; FreshRSS lee la IP real desde `X-Forwarded-For` solo si la request entró por un proxy en ese rango. Coherente con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3 (red `homelab` 172.20.0.0/24).

12. **Sin SMTP por defecto.** El homelab no tiene MTA (consistente con [`./01-vaultwarden.md`](./01-vaultwarden.md) §0 punto 4 y [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §0 punto 7). FreshRSS usa email para: (a) reset de password de usuarios (`/i/?c=auth&a=passwordReset`), (b) notificaciones cuando un feed falla repetidamente (opt-in, "Alert me by email if a feed has been failing for X days"). Sin SMTP: los resets se hacen desde la consola con `docker compose exec freshrss php cli/update-user.php --user <user> --password <new_password>` (script CLI provisto por FreshRSS); las notificaciones por feed roto quedan en la UI bajo el indicador de errores (tres puntos rojos junto al feed, click para ver el `log_<feed>.txt`). Variante con SMTP relay externo en §12.5.

13. **Backups híbridos: dump SQLite por usuario + bind mount de `data/users/`, además del export OPML como capa portable adicional.** FreshRSS tiene un mecanismo de export OPML propio (`/i/?c=importExport&a=opmlExport`) que produce un fichero `.opml` con todos los feeds y categorías del usuario — es **portable** (cualquier otro agregador RSS en el mundo lo importa), no incluye entries históricas pero permite reconstruir la estructura de suscripciones en una nueva instalación tras pérdida total. La política del homelab: **(1)** dump SQLite por usuario vía `sqlite_databases` de Borgmatic (granular, dedup-friendly); **(2)** bind mount de `data/users/` directamente capturado por `source_directories` (cubre `config.php`, favicons cacheados, logs); **(3)** export OPML manual mensual como "tornillo extra" portable, también respaldado por Borgmatic vía bind mount. Tres capas porque la pérdida del estado curado de feeds y categorías (que el operador ha refinado durante años) es irreplicable a corto plazo aunque las entries individuales sí lo son (los feeds las regeneran).

> **Alcance de red**: la UI de FreshRSS **no** publica puertos al host. Se accede únicamente vía `https://freshrss.${LAN_DOMAIN}` (Caddy + CA interna, **sin** Authelia delante por defecto, justificado en §0 punto 4) y, una vez completada la fase Tailscale, vía `https://freshrss.${TS_DOMAIN}`. El homelab opera en LAN + Tailscale, sin exposición a internet, sin Let's Encrypt público, sin port forwarding. La salida saliente (egress) **sí** se permite: FreshRSS necesita `GET https://blog-de-ejemplo.com/feed.xml` para cada feed suscrito.

> **Alcance de auth**: una sola capa. FreshRSS maneja su propio login (PHP `password_hash` bcrypt + cookies de sesión `Freshrss`) tanto para humanos vía la UI web como para apps/integraciones vía API tokens GReader/Fever. Fail2ban ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md)) cubre intentos de fuerza bruta vía los logs de Caddy (los `4xx` quedan registrados); el filtrado fino del endpoint `/i/?c=auth&a=login` requiere un jail dedicado, ver §12.8.

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), `/mnt/hd2t/` montado, directorio `/mnt/hd2t/services/freshrss/` ya creado por el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.1 (loop "Fase 11 — Productividad", línea 241: `for svc in vaultwarden bookstack linkding paperless-ngx mealie stirling-pdf freshrss`).
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` creada (`172.20.0.0/24`, `external: true`), convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3 y §5).
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) con `lan_internal_tls` y `security_headers` operativos.
- **CA interna de Caddy** instalada en al menos un dispositivo del operador (navegador) y en cualquier dispositivo móvil donde se quiera usar un cliente RSS (Reeder en iOS, FluentReader en Android, etc.) — sin la CA confiada, los clientes móviles arrancan, hacen DNS, llegan al puerto 443 pero el handshake TLS falla con "untrusted certificate" y no avanzan a `POST /accounts/ClientLogin`.
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con la posibilidad de añadir un registro DNS local: `freshrss.${LAN_DOMAIN}` → IP del host donde escucha Caddy.
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)). El bloque `sqlite_databases` actual (§6, líneas 547-548) tiene una entrada `freshrss` con `path: /mnt/hd2t/services/freshrss/data/db.sqlite` que es **inexacta** para FreshRSS (la BD es per-user, no global). Este doc, en §9.2, ajusta el patrón al correcto: una entrada por usuario activo. Si el operador prefiere no tocar Borgmatic todavía, los ficheros SQLite quedan respaldados a nivel de fichero (no consistente, pero suficiente para feeds que se redownloadan tras restore).
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). FreshRSS **no** lleva la etiqueta `com.centurylinklabs.watchtower.enable: "false"` (justificado en §0 punto 6 y consistente con Watchtower §4.2, línea 466: FreshRSS está en la lista de servicios con auto-update).
- **Fail2ban desplegado** ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md)) con el jail `caddy-status` ya activo (cubre intentos de login web FreshRSS al venir todos por Caddy con `4xx`).
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No se añaden reglas: FreshRSS no publica puertos al host; el tráfico entra por Caddy.
- **Vaultwarden desplegado** ([`./01-vaultwarden.md`](./01-vaultwarden.md)). No es bloqueante para arrancar FreshRSS, pero la convención del homelab es que el operador ya tenga Vaultwarden activo cuando empieza la Fase 11; cualquier credencial nueva (password admin, API password GReader/Fever, password de usuarios familiares) se anota allí.
- **Salida a internet desde la red `homelab` operativa**. Crítico para FreshRSS: el cron interno necesita poder hacer `GET https://feed.example.com/rss.xml` cada `$CRON_MIN` minutos. El firewall del host (`ufw` con default-allow para outbound, [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md)) y la red `homelab` Docker no bloquean egress. Pi-hole **sí** filtra DNS — si un feed apunta a un dominio bloqueado por las listas de ads/tracking, FreshRSS lo registrará como "unable to fetch" en `log_<feed>.txt`. En la práctica los dominios de blogs no están en listas de bloqueo, pero algunos feeds de noticias agregadas (que sirven contenido desde CDNs de tracking) sí pueden caer en falsos positivos.
- **Espacio libre en `hd2t`** ≥ 2 GB recomendado. El crecimiento típico de un hogar es: ~5-50 MB por usuario en el primer año (BD + favicons + logs), y la retención por defecto de FreshRSS purga entries leídas tras N meses (configurable). Reservar margen para la importación inicial de un OPML grande (un usuario migrando desde Inoreader con 800 feeds activos puede meter ~50 MB de entries en la primera sincronización).
- **Comprobaciones rápidas**:
  ```bash
  # Red homelab existe:
  docker network inspect homelab --format '{{(index .IPAM.Config 0).Subnet}}'
  # Esperado: 172.20.0.0/24

  # Caddy está sano:
  docker inspect caddy --format '{{.Name}}: {{.State.Health.Status}}'
  # Esperado: caddy: healthy

  # Path base existe y es del usuario homelab:
  stat -c '%U:%G %a %n' /mnt/hd2t/services/freshrss
  # Esperado: homelab:homelab 750 /mnt/hd2t/services/freshrss

  # Acceso a internet vía DNS para feeds (Pi-hole no bloquea un dominio canónico):
  docker run --rm --network homelab alpine sh -c 'apk add --no-cache curl >/dev/null 2>&1 && curl -fsSI https://www.theverge.com/rss/index.xml -o /dev/null && echo OK'
  # Esperado: OK
  ```

### Decisiones de diseño asumidas

| # | Decisión | Justificación breve | Variante en §12 |
|---|---|---|---|
| 1 | Imagen `freshrss/freshrss:<version>` (Debian) | Upstream oficial, multi-arch (incluye `linux/arm64`), Apache + PHP 8.3 + cron + locales baked-in. | — |
| 2 | Tag concreto `<version>` (no `latest`, no `edge`) | Misma regla del homelab. Cada minor puede traer migraciones SQL idempotentes pero deliberadas. | — |
| 3 | Backend de BD: SQLite (un fichero por usuario en `data/users/<user>/db.sqlite`) | Justificado en §0 punto 3. | §12.2 (MariaDB) / §12.3 (PostgreSQL) |
| 4 | Política de Watchtower: `enable: "true"` (etiqueta sin sobreescribir el default) | Justificado en §0 punto 6 y en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 línea 466. | §12.7 (`pre-update` hook) |
| 5 | Arquitectura: `linux/arm64` (Pi 5) | Manifest multi-arch oficial. | — |
| 6 | Redes Docker: `homelab` (bridge externa) | Una sola red. No hay BD lateral con SQLite. | §12.2/§12.3 añaden red interna |
| 7 | Modelo de almacenamiento: bind mount sobre `/mnt/hd2t/services/freshrss/data/` → `/var/www/FreshRSS/data` | Patrón estándar del homelab. Bind mount facilita backup directo y rutas predecibles. | — |
| 8 | Reverse proxy: Caddy con `lan_internal_tls` + `security_headers`, **sin** `authelia_proxy` | Justificado en §0 punto 4. Las APIs GReader/Fever requieren paso directo. | §12.4 (OIDC) |
| 9 | Hostname interno: `freshrss` (`container_name`) | Caddy llama `http://freshrss:80`. | — |
| 10 | Puerto interno: `80` (Apache) | Default de la imagen. **No** se publica al host. | — |
| 11 | Subdominio LAN: `freshrss.${LAN_DOMAIN}` | Convención del homelab. | — |
| 12 | Subdominio Tailscale: `freshrss.${TS_DOMAIN}` (preparado, descomentar tras [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) | Mismo patrón que el resto. | — |
| 13 | `CRON_MIN='1,31'` (refresh dos veces por hora) | Justificado en §0 punto 9. | Ajustable en `.env` |
| 14 | `TRUSTED_PROXY='172.20.0.0/24'` | Justificado en §0 punto 11. Caddy en la red `homelab`. | — |
| 15 | `COPY_LOG_TO_SYSLOG=Off`, `COPY_SYSLOG_TO_STDERR=On` | Justificado en §0 punto 10. Logs en `docker logs`. | — |
| 16 | Bootstrap: `FRESHRSS_INSTALL` + `FRESHRSS_USER` con password generada | Justificado en §0 punto 8. Rotada desde la UI tras el primer login. | — |
| 17 | UID/GID del proceso en el contenedor: `33:33` (`www-data`, Debian) | Justificado en §0 punto 7. **No** se usan PUID/PGID. | — |
| 18 | Healthcheck del contenedor: `wget --no-verbose --tries=1 --spider http://127.0.0.1/i/?c=index&a=index` | FreshRSS no tiene endpoint `/health` dedicado; la index pública (login) responde `200 OK` en HTML cuando todo va bien. | — |
| 19 | `cap_drop: ALL` + `no-new-privileges` | Patrón estándar del homelab ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6). FreshRSS no necesita ningún capability. | — |
| 20 | Stack name (Compose): `freshrss` | Coherente con `~/homelab/stacks/freshrss/`. | — |

---

## 1. Resumen de la arquitectura

Resumen visual (la flecha indica la dirección del tráfico):

```
                 ┌──────────────────────────────────────────────────┐
                 │  Cliente (navegador, móvil con Reeder/FluentRdr) │
                 │  https://freshrss.lan/  ó  https://freshrss.ts/  │
                 └──────────────────────────────────────────────────┘
                                       │  HTTPS (TLS interno Caddy)
                                       ▼
                 ┌──────────────────────────────────────────────────┐
                 │  Caddy  (stack proxy, host)                      │
                 │  - lan_internal_tls + security_headers           │
                 │  - reverse_proxy http://freshrss:80              │
                 │  - X-Forwarded-* automáticos                     │
                 │  (sin authelia_proxy — ver §0 punto 4)           │
                 └──────────────────────────────────────────────────┘
                                       │  HTTP plano (red Docker)
                                       ▼
   red Docker  ┌──────────────────────────────────────────────────┐
   `homelab`   │  freshrss  (freshrss/freshrss:<version>)         │
   (bridge)    │  - Apache 2.4 + PHP 8.3 (mod_php) :80            │
               │  - crond interno: refresh feeds CRON_MIN         │
               │  - SQLite por usuario en data/users/<user>/      │
               │  - user www-data (UID 33:33)                     │
               │  - egress a internet para fetch de feeds         │
               └──────────────────────────────────────────────────┘
                                       │  bind mount
                                       ▼
                 ┌──────────────────────────────────────────────────┐
                 │  /mnt/hd2t/services/freshrss/                    │
                 │  ├── .env             (chmod 600 root:homelab)   │
                 │  ├── data/                                       │
                 │  │   ├── users/                                  │
                 │  │   │   ├── _/                                  │
                 │  │   │   │   ├── log.txt                         │
                 │  │   │   │   └── ...                             │
                 │  │   │   ├── _default/                           │
                 │  │   │   └── <username>/                         │
                 │  │   │       ├── db.sqlite       (33:33, 0640)   │
                 │  │   │       ├── config.php                     │
                 │  │   │       ├── feeds/  (favicons cacheados)   │
                 │  │   │       └── log_<feed>.txt                 │
                 │  │   ├── cache/                                 │
                 │  │   ├── tmp/                                   │
                 │  │   └── pubsubhubbub/                          │
                 │  ├── extensions/    (vacío por defecto)         │
                 │  └── secrets/                                    │
                 │      └── admin_password   (root:homelab 600)    │
                 └──────────────────────────────────────────────────┘
                                       │
                                       ▼  Borgmatic (root, systemd)
                 ┌──────────────────────────────────────────────────┐
                 │  Repo Borg en /mnt/hd2t/backups/                 │
                 │  + offsite (Backblaze B2, definido en Fase 7)    │
                 │  Hook sqlite_databases.freshrss-<user> por user  │
                 │  (patrón corregido en §9.2 de este doc).         │
                 └──────────────────────────────────────────────────┘
```

Componentes:

- **Stack directory**: `~/homelab/stacks/freshrss/` (versionado en git: `docker-compose.yml`, `.env.example`, `README.md` corto).
- **Datos**: `/mnt/hd2t/services/freshrss/` (NO versionado, con `.env` real, secretos y datos persistentes).
- **Contenedores**: solo uno (`freshrss`).
- **Red**: solo `homelab` (bridge externa, declarada en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3).
- **Backup**: Borgmatic con entrada `sqlite_databases` por usuario (corrige el patrón actual de [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6, líneas 547-548). Más detalles en §9 de este documento.
- **Caddy**: bloque `freshrss.{$LAN_DOMAIN}` + (futuro) `freshrss.{$TS_DOMAIN}` en `~/homelab/stacks/proxy/Caddyfile`.
- **Cron**: vive **dentro** del contenedor (crond del propio image), no se delega al host.

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/freshrss/.env.example`:

```dotenv
# ─── Imagen ─────────────────────────────────────────────────────────────────
# Tag puntual; revisar https://github.com/FreshRSS/FreshRSS/releases para
# la versión vigente y leer las release notes antes de cada upgrade.
FRESHRSS_IMAGE=freshrss/freshrss:1.26.0

# ─── Identidad / TZ ─────────────────────────────────────────────────────────
TZ=Europe/Madrid

# ─── Dominios (deben coincidir con el bloque de Caddy) ─────────────────────
LAN_DOMAIN=lan
TS_DOMAIN=tail-XXXXX.ts.net

# ─── Paths ──────────────────────────────────────────────────────────────────
DATA_PATH=/mnt/hd2t/services/freshrss/data
EXTENSIONS_PATH=/mnt/hd2t/services/freshrss/extensions

# ─── Cron (refresh de feeds) ────────────────────────────────────────────────
# Sintaxis cron del minuto (cron interno). Default upstream: '1,31'
# (dos refrescos por hora, distribuidos). Variantes:
#   '*/15'  -> cada 15 minutos.
#   '*/5'   -> cada 5 minutos (agresivo, usa solo si se entiende el coste).
CRON_MIN=1,31

# ─── Logs ───────────────────────────────────────────────────────────────────
# Mantener todo en docker logs. Justificado en §0 punto 10.
COPY_LOG_TO_SYSLOG=Off
COPY_SYSLOG_TO_STDERR=On

# ─── Reverse proxy ──────────────────────────────────────────────────────────
# CIDR de la red Docker `homelab`. Justificado en §0 punto 11.
TRUSTED_PROXY=172.20.0.0/24

# ─── Listen ─────────────────────────────────────────────────────────────────
# La imagen escucha en 0.0.0.0:80 por defecto. No se cambia.
LISTEN=0.0.0.0:80

# ─── Bootstrap auto-instalación ─────────────────────────────────────────────
# Ejecutado solo en primer arranque cuando data/ está vacío. Argumentos
# del CLI cli/do-install.php (motor de BD, idioma, default_user para
# data/users/_default/, language UI):
FRESHRSS_INSTALL=--api_enabled --default_user admin --language es \
  --db-type sqlite

# Crea el usuario admin en primer arranque. Argumentos del CLI
# cli/create-user.php. La password va aquí en plaintext (chmod 600 sobre
# el .env). Tras el primer login se rota desde la UI (§7.1).
FRESHRSS_USER=--user admin --password __GENERATE_AND_REPLACE__ --api_password __GENERATE_AND_REPLACE__

# ─── Resource limits (opcional, valores por defecto razonables en Pi 5) ───
FRESHRSS_MEMORY_LIMIT=512m
FRESHRSS_CPU_LIMIT=1.5
```

> **`__GENERATE_AND_REPLACE__`**: marcador placeholder. Las passwords reales (admin web + API password GReader/Fever) se generan en §3.3 con `openssl rand -base64 32`, se persisten en `/mnt/hd2t/services/freshrss/secrets/admin_password` y `/mnt/hd2t/services/freshrss/secrets/api_password`, y se inyectan vía `sed` en el `.env` real. Nunca se commitean al repo.

> **Nota sobre `FRESHRSS_INSTALL` y `FRESHRSS_USER`**: las variables son **multi-línea** vía continuación con `\` (Compose las interpreta como cadenas únicas). Si el operador prefiere mantenerlas en una sola línea, no hace falta el `\`. Documentación CLI: `docker compose exec freshrss php cli/do-install.php --help` y `cli/create-user.php --help`.

### 2.2. `.env` real (`/mnt/hd2t/services/freshrss/.env`)

El `.env` real es **una copia** del `.env.example` con los valores rellenos:

- `TS_DOMAIN`: el alias asignado por Tailscale (`tail-XXXXX.ts.net`) — el operador ya lo conoce de [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) §3 (preparación), aunque el bloque del Caddyfile siga comentado.
- `FRESHRSS_USER`: con las dos passwords (web + API) reales, plaintext, en línea única o con `\`.
- `CRON_MIN`: ajustable a gusto del operador.

`chmod 600 root:homelab` para que solo `root` y el usuario `homelab` puedan leerlo (Docker corre como root y consume el `env_file` antes del arranque del contenedor).

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` (§4) usa **dos** mecanismos:

1. **`env_file: /mnt/hd2t/services/freshrss/.env`** — Compose carga el `.env` y todas las variables se exportan al entorno del contenedor automáticamente. La imagen upstream las lee en su `start.sh` y configura Apache + cron + bootstrap.
2. **`environment:`** — re-declara variables clave (`TZ`, `CRON_MIN`, `TRUSTED_PROXY`, etc.) **explícitamente**, por dos motivos: (a) `docker compose config` muestra siempre la lista efectiva interpolada, útil para debugging; (b) el contrato del stack queda visible en el YAML sin abrir el `.env`.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
mkdir -p ~/homelab/stacks/freshrss
cd ~/homelab/stacks/freshrss
# Aquí vivirá: docker-compose.yml, .env.example, README.md.
# Versionable en git. NO commitear el .env real.
```

### 3.2. Crear el árbol de datos persistentes del servicio

```bash
# El path /mnt/hd2t/services/freshrss ya existe (creado por bootstrap §4.1
# de 01-sistema/04-estructura-directorios.md). Verificar:
ls -ld /mnt/hd2t/services/freshrss
# Esperado: drwxr-x--- 2 homelab homelab ...

# Subdirectorios:
sudo install -d -o 33 -g 33 -m 0750 /mnt/hd2t/services/freshrss/data
sudo install -d -o 33 -g 33 -m 0750 /mnt/hd2t/services/freshrss/extensions
sudo install -d -o root -g homelab -m 0750 /mnt/hd2t/services/freshrss/secrets

# Verificación final:
ls -ln /mnt/hd2t/services/freshrss/
# Esperado:
#   drwxr-x---  ... 33  33    ... data
#   drwxr-x---  ... 33  33    ... extensions
#   drwxr-x---  ... 0   1000  ... secrets
```

> **Por qué `data/` con UID/GID 33** y no `1000`: la imagen oficial de FreshRSS Debian **no** soporta `PUID`/`PGID` (justificado en §0 punto 7). El proceso Apache + PHP corre como `www-data` (UID 33) y necesita escribir en `/var/www/FreshRSS/data`. Si el directorio se crea con UID 1000, al primer arranque la imagen intenta `chown -R 33:33 /var/www/FreshRSS/data` (visible en los logs) — funciona pero genera un cambio de propiedad masivo en el bind mount cada vez que se reinicia el contenedor. Crear el directorio ya con `33:33` desde el principio elimina ese ciclo.

> **Por qué `secrets/` con `root:homelab` 0750**: lo escribe el operador (con `sudo`) y lo lee Compose vía `env_file` (que requiere que el usuario `homelab` pueda al menos atravesar el directorio; el fichero individual queda 600 root:homelab y solo lo abre Docker como root al arrancar el stack).

### 3.3. Generar las passwords del admin (web + API)

FreshRSS distingue dos passwords por usuario: la **password web** (login normal en `/i/`) y la **API password** (token usado por GReader/Fever para clientes externos). Se generan ambas, se custodian por separado.

```bash
# Password web del admin:
sudo install -m 600 -o root -g homelab /dev/null \
  /mnt/hd2t/services/freshrss/secrets/admin_password

openssl rand -base64 32 | sudo tee \
  /mnt/hd2t/services/freshrss/secrets/admin_password >/dev/null

# Password API (GReader/Fever) del admin:
sudo install -m 600 -o root -g homelab /dev/null \
  /mnt/hd2t/services/freshrss/secrets/api_password

openssl rand -base64 32 | sudo tee \
  /mnt/hd2t/services/freshrss/secrets/api_password >/dev/null

# Verificar permisos:
ls -l /mnt/hd2t/services/freshrss/secrets/
# Esperado:
#   -rw------- 1 root homelab 45 ... admin_password
#   -rw------- 1 root homelab 45 ... api_password

# Anotar los plaintext en KeePassXC + Vaultwarden con dos entradas:
#   "FreshRSS — admin web password (bootstrap)"
#   "FreshRSS — admin API password (GReader/Fever)"
sudo cat /mnt/hd2t/services/freshrss/secrets/admin_password
sudo cat /mnt/hd2t/services/freshrss/secrets/api_password
```

> **Por qué dos passwords distintas**: la API password es la que se pega en Reeder/FluentReader. Si el operador rota la password web (cambio rutinario tras un compromiso parcial), no quiere que todos los clientes RSS móviles dejen de funcionar. Mantenerlas separadas (FreshRSS lo permite y lo recomienda explícitamente) es defensa en profundidad.

### 3.4. Materializar el `.env` real

```bash
# Copiar plantilla:
sudo install -m 600 -o root -g homelab \
  ~/homelab/stacks/freshrss/.env.example \
  /mnt/hd2t/services/freshrss/.env

# Editar valores específicos del homelab (LAN_DOMAIN/TS_DOMAIN):
sudo $EDITOR /mnt/hd2t/services/freshrss/.env

# Sustituir los placeholders de las dos passwords:
ADMIN_PW="$(sudo cat /mnt/hd2t/services/freshrss/secrets/admin_password)"
API_PW="$(sudo cat /mnt/hd2t/services/freshrss/secrets/api_password)"

# La línea FRESHRSS_USER tiene los dos placeholders. Sustituir el primero
# (--password) y luego el segundo (--api_password). sed con delimitador '|'
# para evitar problemas si la password contiene '/'.
sudo sed -i \
  "0,/__GENERATE_AND_REPLACE__/{s|__GENERATE_AND_REPLACE__|${ADMIN_PW}|}" \
  /mnt/hd2t/services/freshrss/.env

sudo sed -i \
  "0,/__GENERATE_AND_REPLACE__/{s|__GENERATE_AND_REPLACE__|${API_PW}|}" \
  /mnt/hd2t/services/freshrss/.env

# Verificar (sin leer plaintext en pantalla):
sudo grep -c '__GENERATE_AND_REPLACE__' /mnt/hd2t/services/freshrss/.env
# Esperado: 0  (los dos placeholders ya no están)

sudo grep -c -- '--password' /mnt/hd2t/services/freshrss/.env
# Esperado: 1
sudo grep -c -- '--api_password' /mnt/hd2t/services/freshrss/.env
# Esperado: 1
```

### 3.5. Tabla resumen de permisos

| Path | Owner | Modo | Quién escribe | Quién lee |
|---|---|---|---|---|
| `/mnt/hd2t/services/freshrss/.env` | `root:homelab` | `0600` | operador (vía `sudo`) | Docker daemon (root) al arrancar el stack |
| `/mnt/hd2t/services/freshrss/data/` | `33:33` | `0750` | proceso Apache+PHP dentro del contenedor | Apache+PHP; Borgmatic (root) para los dumps SQLite |
| `/mnt/hd2t/services/freshrss/data/users/<user>/db.sqlite` | `33:33` | `0640` | Apache+PHP | Apache+PHP; Borgmatic (root) |
| `/mnt/hd2t/services/freshrss/data/cache/`, `tmp/`, `pubsubhubbub/` | `33:33` | `0750` | Apache+PHP | — |
| `/mnt/hd2t/services/freshrss/extensions/` | `33:33` | `0750` | operador para instalar extensiones (vía `sudo cp -r`) | Apache+PHP (lectura) |
| `/mnt/hd2t/services/freshrss/secrets/` | `root:homelab` | `0750` | operador (vía `sudo`) | Compose (root) |
| `/mnt/hd2t/services/freshrss/secrets/admin_password` | `root:homelab` | `0600` | operador (`tee`) | Compose (root) al primer arranque |
| `/mnt/hd2t/services/freshrss/secrets/api_password` | `root:homelab` | `0600` | operador (`tee`) | Compose (root) al primer arranque |

### 3.6. Permisos para el proceso del contenedor

El proceso Apache+PHP **no necesita root** después del arranque (el `start.sh` arranca como root para escribir un par de configs y luego dropea a `www-data`). La regla de oro: **el operador del homelab (UID 1000) no debe necesitar leer `/mnt/hd2t/services/freshrss/data/` directamente**. Cualquier inspección manual usa `sudo`. Si en algún momento se quisiera dar lectura al usuario `homelab` (caso raro: copia ad-hoc de `db.sqlite` para inspección con un cliente SQLite del operador), bastaría con `sudo chgrp -R homelab /mnt/hd2t/services/freshrss/data && sudo chmod -R g+rX ...`, pero el patrón estándar del homelab no lo requiere.

---

## 4. `docker-compose.yml`

`~/homelab/stacks/freshrss/docker-compose.yml`:

```yaml
# ~/homelab/stacks/freshrss/docker-compose.yml
# Stack: productivity (../02-docker/02-estructura-compose.md §1.1, fila
# 'productivity'). Datos en /mnt/hd2t/services/freshrss/.

name: freshrss

services:
  freshrss:
    image: ${FRESHRSS_IMAGE}
    container_name: freshrss
    hostname: freshrss
    restart: unless-stopped

    env_file:
      - /mnt/hd2t/services/freshrss/.env
    environment:
      TZ: ${TZ}
      CRON_MIN: ${CRON_MIN}
      COPY_LOG_TO_SYSLOG: ${COPY_LOG_TO_SYSLOG}
      COPY_SYSLOG_TO_STDERR: ${COPY_SYSLOG_TO_STDERR}
      TRUSTED_PROXY: ${TRUSTED_PROXY}
      LISTEN: ${LISTEN}
      FRESHRSS_INSTALL: ${FRESHRSS_INSTALL}
      FRESHRSS_USER: ${FRESHRSS_USER}

    volumes:
      - ${DATA_PATH}:/var/www/FreshRSS/data:rw
      - ${EXTENSIONS_PATH}:/var/www/FreshRSS/extensions:rw

    networks:
      - homelab

    cap_drop:
      - ALL
    cap_add:
      # Apache necesita CAP_NET_BIND_SERVICE para escuchar en :80 dentro
      # del contenedor (PID 1 del init dropea privilegios pero el bind
      # inicial requiere la capability).
      - NET_BIND_SERVICE
      # CHOWN/SETUID/SETGID: el start.sh arranca como root para
      # ajustar /var/www/FreshRSS/data (chown a www-data) y luego
      # dropea privilegios. Sin estas capabilities el primer arranque
      # falla con EPERM al intentar `chown 33:33 ...`.
      - CHOWN
      - SETUID
      - SETGID
      # DAC_OVERRIDE: el script de inicio escribe /etc/apache2/conf-*
      # como root. Sin esta capability los reloads de Apache fallan.
      - DAC_OVERRIDE
    security_opt:
      - no-new-privileges:true

    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://127.0.0.1/i/?c=index 2>/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 90s

    deploy:
      resources:
        limits:
          memory: ${FRESHRSS_MEMORY_LIMIT}
          cpus: '${FRESHRSS_CPU_LIMIT}'

    # Watchtower habilitado por default (ver ../02-docker/04-watchtower.md
    # §4.2 línea 466 — FreshRSS está en la lista de servicios con
    # auto-update). NO se pone enable: "false".

networks:
  homelab:
    external: true
```

### 4.1. Por qué cada bloque

| Línea | Por qué |
|---|---|
| `name: freshrss` | Hace el `compose project name` explícito en lugar de inferirlo del directorio. Aparece en `docker compose ls`. |
| `image: ${FRESHRSS_IMAGE}` | Tag completo desde `.env`. Cualquier upgrade es grep-able y `git diff`-able. |
| `container_name: freshrss` | DNS interno: Caddy llama `http://freshrss:80`. Sin `container_name` Compose le pondría `freshrss-freshrss-1`. |
| `hostname: freshrss` | Alineado con `container_name`. Apache imprime el hostname en algunos logs; mantenerlos iguales evita confusión. |
| `restart: unless-stopped` | Auto-arranque tras reboot. `unless-stopped` (no `always`) permite parar manualmente para mantenimiento sin que Docker lo levante a la fuerza. |
| **No** `user:` | La imagen upstream gestiona internamente el cambio a `www-data` (UID 33) tras el bootstrap. Forzar `user: "1000:1000"` rompería los permisos esperados por Apache (que necesita escribir en `/var/log/apache2/`, `/etc/apache2/...`). Justificado en §0 punto 7. |
| `env_file:` | Path absoluto, fuera del repo. Justificado en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.1. |
| `environment:` (re-declaración explícita) | Aunque `env_file` ya carga las vars, declararlas aquí **explícitamente** sirve de contrato: `docker compose config` muestra siempre la lista efectiva interpolada. |
| `volumes: ${DATA_PATH}:/var/www/FreshRSS/data:rw` | Bind mount principal. `/var/www/FreshRSS/data` es el path interno donde la imagen guarda BDs por usuario, cache, tmp, etc. |
| `volumes: ${EXTENSIONS_PATH}:/var/www/FreshRSS/extensions:rw` | Bind mount opcional para extensiones community (vacío por defecto). Si el operador instala una extensión vía la UI (Apache la descarga ahí), persiste tras recreación del contenedor. |
| `networks: [homelab]` | Sin red interna lateral — FreshRSS no tiene BD aparte (SQLite en el mismo contenedor). |
| `cap_drop: ALL` | Patrón estándar del homelab. |
| `cap_add: [NET_BIND_SERVICE, CHOWN, SETUID, SETGID, DAC_OVERRIDE]` | Apache + el script de bootstrap (`start.sh`) requieren estos capabilities mínimos. Documentado por upstream (`docker-compose.yml` de referencia en el repo de FreshRSS) y validado experimentalmente: sin estos, el primer arranque falla con `chown: cannot change ownership... Permission denied`. |
| `security_opt: no-new-privileges:true` | Bloquea `setuid`/`setgid` adicionales después del arranque (las capabilities concedidas en `cap_add` ya bastan). |
| `healthcheck: /i/?c=index` | FreshRSS no expone un endpoint `/health` dedicado. La página de login (`/i/?c=index&a=index`, que es la ruta default sin sesión) responde `200 OK` con HTML cuando todo va bien. Alternativa más fina: `/i/?c=stats&a=idleSpeed` (requiere sesión, no útil para healthcheck). |
| `start_period: 90s` | FreshRSS tarda ~30-60 s en arrancar tras la primera vez (corre `cli/do-install.php` + `cli/create-user.php` + scripts de migración). 90 s deja margen sin marcar `unhealthy` falso. Tras el primer arranque el tiempo baja a ~5-10 s. |
| `deploy.resources.limits` | 512 MB de RAM y 1.5 CPUs. FreshRSS consume ~60-150 MB en uso normal; los picos son cuando el cron actualiza ~300 feeds en serie, llegan a ~250 MB. La Pi 5 (8 GB) no lo nota. |
| Sin `labels: watchtower.enable: "false"` | FreshRSS **sí** está en el grupo de auto-update (justificado en §0 punto 6). El default global de Watchtower aplica. |
| `networks.homelab.external: true` | Convención §4.3 de estructura-compose. |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/freshrss
docker compose --env-file /mnt/hd2t/services/freshrss/.env config
```

La salida debe mostrar:

- `image: freshrss/freshrss:1.26.0` (o el tag pinned actual),
- el bloque `environment` totalmente interpolado (sin `${...}`),
- `CRON_MIN: '1,31'`,
- `TRUSTED_PROXY: 172.20.0.0/24`,
- `FRESHRSS_USER` con las dos passwords reales en plaintext (validar que están, **no** copiar a logs),
- `volumes: - /mnt/hd2t/services/freshrss/data:/var/www/FreshRSS/data:rw` y el de extensions,
- `networks: homelab` con `external: true`,
- ningún `ports:` publicado (no habrá línea `ports:`),
- ningún `user:` (queda implícito).

Si alguna variable aparece como `${...}` literal, falta `--env-file`. Si `FRESHRSS_USER` aparece con `__GENERATE_AND_REPLACE__`, no se ejecutó §3.4 correctamente.

---

## 5. Despliegue

### 5.1. Levantar el stack

```bash
cd ~/homelab/stacks/freshrss
docker compose --env-file /mnt/hd2t/services/freshrss/.env up -d
```

Esperar ~60 s (primer arranque hace bootstrap completo) y verificar:

```bash
docker compose --env-file /mnt/hd2t/services/freshrss/.env ps
# Esperado:
#   NAME       IMAGE                       STATUS
#   freshrss   freshrss/freshrss:1.26.0    Up X seconds (health: starting)
```

### 5.2. Estado del contenedor

```bash
# Tras ~90 s, healthy:
docker inspect freshrss --format '{{.State.Health.Status}}'
# Esperado: healthy

# Logs del primer arranque:
docker logs freshrss 2>&1 | head -80
```

Líneas de interés en los logs (varían entre versiones):

```
[start.sh] Configuring TZ to Europe/Madrid
[start.sh] Configuring CRON_MIN to '1,31'
[start.sh] FRESHRSS_INSTALL is set: running do-install.php
Detection of correct PHP version
Found:                  PHP 8.3.x
Setting   ./data/config.php... OK
Setting   ./data/users/_default/config.php... OK
[start.sh] FRESHRSS_USER is set: running create-user.php
User configuration file: ./data/users/admin/config.php
[OK] User created: admin
[start.sh] Starting Apache and crond...
[Wed Apr 27 22:00:00.000000 2026] [mpm_event:notice] [pid 1234] AH00489: Apache/2.4.x (Debian) PHP/8.3.x configured
```

> **Si NO aparece "User created: admin"** y en su lugar dice `User already exists: admin` o el script salta la sección `FRESHRSS_USER`: la BD ya tenía un usuario (no es un primer arranque limpio). En ese caso las passwords del `.env` **no** se aplican; la fuente de verdad es la BD existente. El operador entra con las passwords antiguas o resetea con `docker compose exec freshrss php cli/update-user.php --user admin --password '<new>'`.

### 5.3. Verificar ficheros físicos

```bash
sudo ls -la /mnt/hd2t/services/freshrss/data/
# Esperado:
#   drwxr-x---  2  33  33  ...  cache
#   drwxr-x---  2  33  33  ...  pubsubhubbub
#   drwxr-x---  2  33  33  ...  tmp
#   drwxr-x---  6  33  33  ...  users
#   -rw-r-----  1  33  33  ...  config.php

sudo ls -la /mnt/hd2t/services/freshrss/data/users/
# Esperado:
#   drwxr-x---  ...  _
#   drwxr-x---  ...  _default
#   drwxr-x---  ...  admin

sudo ls -la /mnt/hd2t/services/freshrss/data/users/admin/
# Esperado:
#   -rw-r-----  1  33  33  ...  db.sqlite
#   -rw-r-----  1  33  33  ...  config.php

# Tamaño inicial:
sudo du -sh /mnt/hd2t/services/freshrss/data/
# Esperado: ~1-2 MB (estructura vacía + un usuario admin sin feeds).
```

### 5.4. Smoke check antes de publicar por Caddy

```bash
# Página de login HTML accesible desde la red Docker:
docker exec caddy wget -qO- http://freshrss:80/i/ | grep -c 'FreshRSS'
# Esperado: ≥ 1 (el HTML del login mentciona "FreshRSS").

# Apache responde 200 OK en la index:
docker exec caddy wget -S -qO /dev/null http://freshrss:80/i/ 2>&1 | grep 'HTTP/'
# Esperado: HTTP/1.1 200 OK

# Cron interno funciona (al menos arrancó):
docker exec freshrss ps -ef | grep -E 'crond|cron' | grep -v grep
# Esperado: una línea con crond.
```

### 5.5. Backup inicial del estado virgen

Antes de añadir un solo feed, snapshot del estado limpio:

```bash
# Forzar un run de Borgmatic (incluye el dump SQLite de admin via §9.2 si
# ya está ajustado, o el bind mount completo si no):
sudo systemctl start borgmatic.service
sudo journalctl -u borgmatic.service --since '5 min ago' | grep -i freshrss
# Esperado: línea "Dumping freshrss-admin (sqlite)" o, si no se ajustó §9.2,
# nada explícito (el fichero entra a nivel de fichero por source_directories).

# Listar el archivo más reciente y verificar:
LATEST=$(sudo borg list /mnt/hd2t/backups/borg --last 1 --short)
sudo borg list "/mnt/hd2t/backups/borg::$LATEST" | grep -i freshrss
# Esperado: rutas con .../freshrss/data/users/admin/db.sqlite o el dump.
```

> **Importante**: si Borgmatic aún no estaba configurado al desplegar FreshRSS (orden de fases), saltar este paso y volver tras completar [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) y aplicar §9.2 de este doc.

---

## 6. Integración con Caddy

### 6.1. Añadir el bloque `freshrss.{$LAN_DOMAIN}` al `Caddyfile`

Editar `~/homelab/stacks/proxy/Caddyfile` y añadir (después de los bloques ya existentes, antes del `# Tailscale` comentado):

```caddy
# FreshRSS (../11-productividad/07-freshrss.md)
freshrss.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    reverse_proxy http://freshrss:80 {
        # FreshRSS lee X-Forwarded-* (TRUSTED_PROXY=172.20.0.0/24)
        # para registrar la IP real del cliente y para validar tokens
        # GReader/Fever vinculados a IP.
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
        header_up Host {host}
    }
}
```

| Línea | Por qué |
|---|---|
| `import lan_internal_tls` | TLS con CA interna ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.2). |
| `import security_headers` | HSTS + X-Frame-Options + X-Content-Type-Options + Referrer-Policy. FreshRSS sirve sus propias páginas en HTML; ningún iframe externo legítimo. |
| **NO** `import authelia_proxy` | Justificado en §0 punto 4. La GReader/Fever API requiere paso directo. |
| `reverse_proxy http://freshrss:80` | Caddy llega por la red `homelab` al contenedor `freshrss` en el puerto 80 (Apache). HTTP plano dentro de Docker (Caddy ya hace TLS terminator hacia el navegador y los clientes móviles). El scheme original (HTTPS) viaja en `X-Forwarded-Proto`. |
| `header_up Host {host}` | FreshRSS usa el `Host:` para construir URLs absolutas en feeds OPML exportados, en confirmation links de cuentas y en respuestas GReader. Forzarlo evita que Caddy lo reescriba a `freshrss:80`. |

### 6.2. Recargar Caddy

```bash
cd ~/homelab/stacks/proxy
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
# Esperado: "Valid configuration".

docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
# Esperado: sin output (éxito).
```

Verificación en logs de Caddy:

```bash
docker logs --tail 50 caddy 2>&1 | grep -E 'freshrss|reload'
# Esperado: la nueva ruta aparece y un log "reloaded successfully" o
# "certificate obtained successfully" para freshrss.lan.
```

### 6.3. Registro DNS local en Pi-hole

En la UI de Pi-hole (`https://pihole.${LAN_DOMAIN}/admin`):
- **Local DNS Records** → **Add a new domain/IP combination**.
- Domain: `freshrss.lan`
- IP: la IP del host donde escucha Caddy (`192.168.1.10` por convención del homelab; ver [`../03-red/02-pihole.md`](../03-red/02-pihole.md)).
- **Add**.

Validación:

```bash
dig +short @192.168.1.241 freshrss.lan
# Esperado: 192.168.1.10
```

### 6.4. Probar el acceso desde el navegador

```bash
# Desde un cliente con la CA de Caddy ya instalada (§6.5 de Caddy):
curl -v --resolve freshrss.lan:443:192.168.1.10 https://freshrss.lan/i/ \
  | grep -c '<title>FreshRSS'
# Esperado: 1
```

Desde el navegador: `https://freshrss.lan` → debería redirigir a `/i/` y mostrar el **formulario de login de FreshRSS** (logo, campos "Username"/"Password"). Si aparece un warning de cert, el `root.crt` de Caddy no está instalado en el navegador — volver a [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §6.5.

### 6.5. Acceso vía Tailscale (preparado, no activo)

Mismo patrón que el resto del homelab: cuando Tailscale esté desplegado ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) se añade un segundo bloque en el `Caddyfile`:

```caddy
# FreshRSS vía Tailscale (descomentar tras 03-red/05-tailscale.md).
# freshrss.{$TS_DOMAIN} {
#     import tailscale_tls freshrss
#     import security_headers
#     reverse_proxy http://freshrss:80 {
#         header_up X-Real-IP {remote_host}
#         header_up X-Forwarded-Proto {scheme}
#         header_up X-Forwarded-For {remote_host}
#         header_up Host {host}
#     }
# }
```

Hasta entonces, el acceso fuera de casa pasa por Tailscale al hostname `pi.${TS_DOMAIN}` y desde ahí a `freshrss.lan` vía el resolver DNS local de Tailscale (MagicDNS).

---

## 7. Configuración post-despliegue

### 7.1. Login del operador y rotación de las passwords

1. Abrir `https://freshrss.lan/i/` desde el navegador del operador (con la CA de Caddy instalada).
2. Login con:
   - **Username**: `admin` (el del `FRESHRSS_USER` del `.env`).
   - **Password**: el plaintext custodiado en `/mnt/hd2t/services/freshrss/secrets/admin_password` (también en KeePassXC + Vaultwarden tras §3.3).
3. Click en **Configuration → Profile** (icono superior derecho).
4. Sección **Password**: introducir la password actual + una **nueva** password fuerte (≥ 16 caracteres). **Submit**.
5. Sección **API password**: introducir una API password nueva (la actual es la de `secrets/api_password`). **Submit**. Anotar la nueva en KeePassXC + Vaultwarden con la entrada "FreshRSS — admin API password (operador)".
6. Cerrar sesión y volver a entrar con la nueva password (validación end-to-end).

> **NO se renombra el username** `admin`: FreshRSS permite cambiar el username solo a nivel de BD (`UPDATE users SET name = ...`), pero hacerlo invalida la entrada de bootstrap del `.env`. La práctica del homelab es mantener `admin` como username y rotar solo passwords.

### 7.2. Configurar settings globales

**Configuration → Reading**:

- **Display articles**: gusto del operador (lista, expandido, etc.).
- **Mark articles as read on**: "scroll" (default razonable).
- **Refresh interval**: déjalo por defecto. El cron del contenedor (`CRON_MIN`) ya gestiona el refresh global; este interval es solo para el polling vía AJAX en la UI abierta.

**Configuration → Sharing**:

- **Available sharing methods**: activar/desactivar según preferencia (Twitter/Mastodon/Email...). Útil si se usan extensiones tipo "Send to Pocket" o Mastodon.

**Configuration → Authentication**:

- **Authentication method**: **Web form** (default, password). 
- **Allow API access**: **YES** (necesario para Reeder/FluentReader/Newsboat-greader). Si está **NO**, los clientes móviles devuelven 403.
- **Anonymous access**: **NO** (default, no exponer feeds sin login).

**Configuration → System** (solo admin):

- **Auto-update FreshRSS**: **NO** (default). El homelab gestiona upgrades vía Watchtower con tag pinned (§0 punto 6); la actualización in-app desde la UI mezcla canales y rompe el pinning.
- **Cron auto-update**: **YES** (el cron del contenedor ya está activo, esta opción solo confirma que la UI puede dispararlo manualmente también).
- **Default user**: `_default` (esqueleto para nuevos usuarios; déjalo).
- **Default language for new users**: `Español` o `English` según preferencia.

### 7.3. Importar feeds desde un OPML existente

Si el operador llega desde Inoreader, Feedly, Tiny Tiny RSS o cualquier otro agregador, exporta un `.opml` desde allí y lo importa aquí:

1. **Subscription management** (icono `+` arriba) → **Import / Export** → **OPML file**.
2. **Browse** → seleccionar el `.opml`.
3. **Submit**.
4. FreshRSS parsea el árbol de categorías y crea los feeds. Para 800 feeds tarda ~30-60 s; los favicons y entries se llenan en el siguiente ciclo del cron.

> **Tras una import grande, forzar un refresh inmediato** desde **Subscription management → Refresh**, o bien `docker compose exec freshrss php cli/actualize_script.php --user admin` (usuario explícito).

### 7.4. Configurar un cliente RSS móvil (Reeder / FluentReader / FeedMe)

**Reeder 5 (iOS) / Reeder 4 (macOS)**:

1. Add Account → **FreshRSS / Selfoss**.
2. **URL**: `https://freshrss.lan` (o `https://freshrss.${TS_DOMAIN}` desde fuera de casa por Tailscale).
3. **Username**: `admin`.
4. **Password**: la **API password** (no la web; se anotó en §3.3 / §7.1).
5. **Save**. Reeder hace `POST /accounts/ClientLogin`, obtiene el token GReader y empieza a sincronizar.

**FluentReader (desktop multi-plataforma)**:

1. Settings → Accounts → **+ Add account** → **Fever** o **Google Reader**.
2. **Endpoint**: `https://freshrss.lan/api/greader.php` (GReader) o `https://freshrss.lan/api/fever.php` (Fever).
3. **Username** + **API password**.
4. **Save**.

**FeedMe (Android)**:

1. Add Account → **FreshRSS** (la app lo soporta nativamente desde 2023).
2. **Server URL**: `https://freshrss.lan`.
3. **Username** + **API password**.

> **Si la conexión falla con "untrusted certificate"**: el cliente móvil no tiene la CA de Caddy instalada en su trust store. Procedimiento por plataforma en [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §6.5. iOS requiere instalar el `root.crt` como perfil + activar "Trust certificates for root..." en `Settings → General → About → Certificate Trust Settings`.

### 7.5. Crear cuentas para familiares (opcional)

FreshRSS soporta multi-usuario nativo. Para añadir un usuario:

1. **Configuration → Users → Add user**.
2. **Username** + **password** + **API password** (todas anotadas en Vaultwarden, compartidas con el familiar por canal seguro).
3. **Type**: `normal` (no admin).
4. **Submit**.
5. Al primer login, el familiar puede cambiar sus passwords desde **Configuration → Profile**.

> **Aislamiento entre usuarios**: cada usuario tiene su propio `data/users/<user>/db.sqlite` con sus feeds, categorías, entries y tokens. No hay "feeds compartidos" entre usuarios — si dos personas quieren leer la misma fuente, cada una se suscribe individualmente. Variante OIDC en §12.4 puede unificar el login pero no la BD.

### 7.6. Verificación post-despliegue

- [ ] `freshrss.lan` carga el formulario de login (sin pasar por Authelia — eso es **lo correcto** aquí).
- [ ] Login con la nueva password del admin funciona.
- [ ] La password antigua del `.env` **ya no** funciona.
- [ ] El cliente RSS móvil conecta vía GReader API y sincroniza al menos un feed.
- [ ] Al añadir un feed desde la UI, aparece en la lista tras refresh manual o tras `CRON_MIN`.
- [ ] Los favicons de los feeds se descargan tras el primer ciclo del cron.
- [ ] **Configuration → System → API access** = YES.
- [ ] **Configuration → Profile** muestra el username correcto.

---

## 8. Verificación

### 8.1. Contenedor sano y permisos correctos

```bash
docker inspect freshrss --format '{{.State.Health.Status}}'
# Esperado: healthy

docker inspect freshrss --format '{{.State.StartedAt}}'
# Esperado: timestamp reciente.

# Permisos del bind mount:
sudo ls -ln /mnt/hd2t/services/freshrss/data/users/admin/db.sqlite
# Esperado: -rw-r----- 1 33 33 ... db.sqlite

# Tamaño tras unos días con feeds activos:
sudo du -sh /mnt/hd2t/services/freshrss/data/
# Esperado: < 100 MB para uso normal con 100-300 feeds.

# Cron interno corriendo:
docker exec freshrss ps -ef | grep -E 'crond' | grep -v grep
# Esperado: una línea con `crond`.
```

### 8.2. FreshRSS no escucha al host

```bash
sudo ss -tlnp | grep ':80\b'
# Esperado: vacío (Caddy escucha en el host pero no FreshRSS directamente).

# Dentro del contenedor sí está abierto:
docker exec freshrss ss -tlnp 2>/dev/null | grep ':80' || \
  docker exec freshrss netstat -tlnp 2>/dev/null | grep ':80'
# Esperado: 0.0.0.0:80 LISTEN PID/apache2
```

### 8.3. UI accesible vía Caddy

```bash
curl -sI --resolve freshrss.lan:443:192.168.1.10 https://freshrss.lan/
# Esperado:
#   HTTP/2 302
#   location: /i/
#   strict-transport-security: max-age=...
#   x-content-type-options: nosniff

curl -sI --resolve freshrss.lan:443:192.168.1.10 https://freshrss.lan/i/
# Esperado: HTTP/2 200
```

### 8.4. API GReader accesible con token

```bash
USERNAME=admin
API_PW="$(sudo cat /mnt/hd2t/services/freshrss/secrets/api_password)"
# (o la rotada en §7.1, anotada en Vaultwarden)

# Login GReader (devuelve un token Auth=...):
TOKEN=$(curl -s --resolve freshrss.lan:443:192.168.1.10 \
  -d "Email=${USERNAME}&Passwd=${API_PW}" \
  https://freshrss.lan/api/greader.php/accounts/ClientLogin \
  | grep '^Auth=' | cut -d= -f2)
echo "Token len: ${#TOKEN}"
# Esperado: ~120 caracteres (token base64ish).

# Listar suscripciones:
curl -s --resolve freshrss.lan:443:192.168.1.10 \
  -H "Authorization: GoogleLogin auth=${TOKEN}" \
  "https://freshrss.lan/api/greader.php/reader/api/0/subscription/list?output=json" \
  | jq '.subscriptions | length'
# Esperado: número entero (0 si aún no se ha suscrito a nada).
```

> Si la respuesta no es JSON (sino HTML), Authelia se ha colado por error en el bloque Caddy de §6.1 (releer §0 punto 4). Sin token o con token mal: respuesta vacía o `Authentication failed`.

### 8.5. Persistencia tras reboot

```bash
# Forzar un reinicio del stack:
cd ~/homelab/stacks/freshrss
docker compose --env-file /mnt/hd2t/services/freshrss/.env down
docker compose --env-file /mnt/hd2t/services/freshrss/.env up -d

# Esperar ~60 s y verificar:
docker inspect freshrss --format '{{.State.Health.Status}}'
# Esperado: healthy

# Login + feeds siguen ahí (la BD persiste en el bind mount).
# Reaplicar el flujo §8.4 — el token cambia (cada login lo regenera) pero
# la lista de subscriptions debe coincidir.
```

### 8.6. Cron de refresh ejecutándose

```bash
# Verificar que el último ciclo del cron fue reciente:
docker logs freshrss 2>&1 | grep -i 'actualize\|refresh' | tail -5
# Esperado: líneas con timestamps recientes (<60 min) y "OK" o conteos
# de entries añadidas.

# Forzar un refresh manual:
docker compose exec freshrss php cli/actualize_script.php --user admin
# Esperado: salida con líneas tipo "Feed X: Y new entries" sin errores.
```

### 8.7. Backup hooks Borgmatic ejecutándose

```bash
# Último run de Borgmatic:
sudo journalctl -u borgmatic.service --since 'yesterday' \
  | grep -iE 'freshrss|sqlite_databases'
# Esperado: línea como "Dumping freshrss-admin (sqlite)" tras aplicar §9.2.
# Si §9.2 aún no se aplicó, no aparece nada explícito; los SQLite entran
# por source_directories (a nivel de fichero, menos consistente).

# Listar el archivo Borg más reciente y confirmar:
LATEST=$(sudo borg list /mnt/hd2t/backups/borg --last 1 --short)
sudo borg list "/mnt/hd2t/backups/borg::$LATEST" \
  | grep -E 'freshrss/data/users/admin/db\.sqlite|borgmatic.*freshrss'
# Esperado: línea(s) con el dump SQLite consistente o el fichero crudo.
```

### 8.8. Lista de verificación

- [ ] `docker compose ps` muestra `freshrss` `Up X (healthy)`.
- [ ] `data/users/admin/db.sqlite` con propietario `33:33`, modo `0640`.
- [ ] `freshrss.lan` resuelve a la IP de Caddy desde Pi-hole.
- [ ] `https://freshrss.lan/i/` muestra el formulario de login HTTPS sin warnings de cert.
- [ ] El cliente móvil RSS conecta vía GReader/Fever API y guarda al menos un feed.
- [ ] El cron interno del contenedor refresca feeds al menos una vez (`docker logs freshrss | grep actualize`).
- [ ] El último Borg incluye `freshrss/data/users/<u>/db.sqlite` (dump consistente o fichero crudo).
- [ ] Las passwords del `.env` (web + API) **ya no** sirven: rotadas en §7.1.
- [ ] El puerto 80 **no** está abierto en el host (`ss -tlnp | grep ':80\b'` vacío salvo si Caddy también escucha en :80, en cuyo caso es Caddy, no FreshRSS).

---

## 9. Backup

### 9.1. Qué se respalda y qué no

| Categoría | Path | ¿Se respalda? | Cómo |
|---|---|---|---|
| Base de datos por usuario | `/mnt/hd2t/services/freshrss/data/users/<user>/db.sqlite` (+ `-wal`, `-shm`) | **Sí**, vía dump consistente | Borgmatic `sqlite_databases.freshrss-<user>` (patrón corregido en §9.2). El hook usa `sqlite3 ... .backup`. |
| Config por usuario | `/mnt/hd2t/services/freshrss/data/users/<user>/config.php` | **Sí** | Capturado a nivel de fichero por `source_directories: /mnt/hd2t/services/`. Tras restore, las preferencias UI reaparecen. |
| Favicons cacheados | `/mnt/hd2t/services/freshrss/data/users/<user>/feeds/` | **Sí** (a nivel de fichero, regenerable) | Capturado por `source_directories`. Si se pierden, FreshRSS los redescarga del `<link rel="icon">` de cada feed. |
| Logs por feed | `/mnt/hd2t/services/freshrss/data/users/<user>/log_<feed>.txt` | **No (ruido)** | Capturados a nivel de fichero pero no críticos; Borgmatic los puede excluir con un patrón si se quiere reducir tamaño (no se hace por defecto, son <1 MB total). |
| Cache HTTP | `/mnt/hd2t/services/freshrss/data/cache/` | **No (regenerable)** | Excluido vía `exclude_patterns` de Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §5). FreshRSS lo regenera con cada ciclo del cron. |
| Tmp uploads | `/mnt/hd2t/services/freshrss/data/tmp/` | **No** | Excluir igual que `cache/`. Solo contiene OPML temporales en tránsito. |
| Extensions | `/mnt/hd2t/services/freshrss/extensions/` | **Sí** | Capturado por `source_directories`. Si está vacío, no aporta nada. |
| `.env` | `/mnt/hd2t/services/freshrss/.env` | **No** (custodiado en KeePassXC + Vaultwarden) | Reproducible desde el `.env.example` versionado en git + las passwords del gestor de contraseñas. |
| Tokens GReader/Fever | (vive en `db.sqlite`, tabla `tokens`) | **Sí**, indirectamente vía dump | Tras restore, los tokens activos siguen siendo válidos. Los clientes móviles siguen funcionando sin reconfiguración. |
| Logs de Apache | (stdout del contenedor, capturados por Docker) | **No** | Rotación gestionada por Docker (`json-file` driver). Para retención larga, configurar un sink centralizado (Loki/Promtail en Fase 5+). |

### 9.2. Patrón Borgmatic — respaldo SQLite por usuario

El bloque actual en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6 (líneas 547-548):

```yaml
sqlite_databases:
  - name: freshrss
    path: /mnt/hd2t/services/freshrss/data/db.sqlite      # ← INEXACTO
```

es **incorrecto** para FreshRSS porque la BD es per-user. El patrón correcto, una vez creado el primer admin (y para cada nuevo usuario que se añada), es **una entrada por usuario**:

```yaml
sqlite_databases:
  - name: freshrss-admin
    path: /mnt/hd2t/services/freshrss/data/users/admin/db.sqlite
  # Añadir una línea por cada usuario adicional creado en §7.5:
  # - name: freshrss-<otro-usuario>
  #   path: /mnt/hd2t/services/freshrss/data/users/<otro-usuario>/db.sqlite
```

**Aplicar el ajuste** (procedimiento manual, una vez tras el bootstrap):

```bash
# 1. Editar el config Borgmatic:
sudo $EDITOR /mnt/hd2t/services/backups/borgmatic/config.yaml

# 2. Localizar la entrada actual (líneas ~547-548) y sustituirla por
#    el patrón per-user mostrado arriba.

# 3. Validar la sintaxis:
sudo borgmatic --config /mnt/hd2t/services/backups/borgmatic/config.yaml --validate
# Esperado: "Validation succeeded".

# 4. Forzar un run y verificar:
sudo systemctl start borgmatic.service
sudo journalctl -u borgmatic.service --since '5 min ago' | grep -i freshrss
# Esperado: "Dumping freshrss-admin (sqlite)" sin errores.
```

> **Por qué `name` con prefijo `freshrss-`**: Borgmatic usa `name` para el directorio de dumps (`/root/.borgmatic/sqlite_databases/<host>/<name>/db.sqlite`). Si dos servicios distintos tienen una BD llamada `db.sqlite`, los dumps colisionarían. El prefijo `freshrss-` evita la colisión con otros servicios (Linkding usa `name: linkding`, Vaultwarden `name: vaultwarden`).

> **Fallback si NO se aplica §9.2**: el bind mount completo de `/mnt/hd2t/services/` está en `source_directories` de Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §5). Los ficheros `db.sqlite` se respaldan a nivel de fichero (cp directo del Borg). El riesgo es **inconsistencia**: si Borg copia `db.sqlite` justo cuando Apache+PHP está escribiendo (ciclo del cron de refresh), el resultado puede ser un fichero "torn" — recuperable con `sqlite3 db.sqlite '.recover'` la mayoría de las veces, pero no garantizado al 100%. Por eso se recomienda aplicar §9.2.

### 9.3. Restore (resumen)

Procedimiento detallado en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.x (patrón unificado para servicios SQLite simples). Resumen para FreshRSS:

```bash
# 1. Parar el stack:
cd ~/homelab/stacks/freshrss
docker compose --env-file /mnt/hd2t/services/freshrss/.env down

# 2. Identificar el archivo Borg deseado:
sudo borg list /mnt/hd2t/backups/borg --short | tail -10

# 3. Extraer el dump SQLite de admin del archivo:
LATEST=homelab-2026-XX-XX_XX-XX-XX
sudo mkdir -p /tmp/restore-freshrss
cd /tmp/restore-freshrss
sudo borg extract \
  "/mnt/hd2t/backups/borg::$LATEST" \
  root/.borgmatic/sqlite_databases

# 4. Sustituir db.sqlite por usuario (con backup defensivo del actual):
USER=admin
sudo cp /mnt/hd2t/services/freshrss/data/users/${USER}/db.sqlite \
        /mnt/hd2t/services/freshrss/data/users/${USER}/db.sqlite.bak-$(date +%s)
sudo cp /tmp/restore-freshrss/root/.borgmatic/sqlite_databases/*/freshrss-${USER}/db.sqlite \
        /mnt/hd2t/services/freshrss/data/users/${USER}/db.sqlite
sudo chown 33:33 /mnt/hd2t/services/freshrss/data/users/${USER}/db.sqlite
sudo chmod 0640 /mnt/hd2t/services/freshrss/data/users/${USER}/db.sqlite

# 5. Borrar los ficheros WAL/SHM (huérfanos tras el restore):
sudo rm -f /mnt/hd2t/services/freshrss/data/users/${USER}/db.sqlite-wal
sudo rm -f /mnt/hd2t/services/freshrss/data/users/${USER}/db.sqlite-shm

# 6. Repetir pasos 4-5 para cada usuario adicional.

# 7. Levantar el stack y verificar:
cd ~/homelab/stacks/freshrss
docker compose --env-file /mnt/hd2t/services/freshrss/.env up -d
sleep 60
docker inspect freshrss --format '{{.State.Health.Status}}'
# Esperado: healthy

# 8. Limpiar el restore temporal:
sudo rm -rf /tmp/restore-freshrss
```

### 9.4. Smoke test mensual

Un domingo al mes (alineado con el smoke test global de [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §8):

1. Listar el último archivo Borg.
2. Extraer **solo** el dump de `freshrss-admin/db.sqlite` a `/tmp`.
3. Abrirlo con `sqlite3 /tmp/.../db.sqlite` y ejecutar:
   ```sql
   SELECT COUNT(*) FROM `freshrss_admin_feed`;
   SELECT COUNT(*) FROM `freshrss_admin_entry`;
   SELECT COUNT(*) FROM `freshrss_admin_category`;
   ```
   (Las tablas tienen prefijo `freshrss_<user>_` por convención del schema).
4. Comparar con el conteo en producción:
   ```bash
   docker exec freshrss sqlite3 /var/www/FreshRSS/data/users/admin/db.sqlite \
     'SELECT COUNT(*) FROM freshrss_admin_feed;'
   ```
5. Diferencia esperada: 0 o ≤ N (donde N son los feeds añadidos desde el último backup nocturno).

### 9.5. Export OPML manual mensual (capa portable adicional)

Independiente de Borg, una vez al mes, exportar los feeds de cada usuario a un `.opml` y dejarlo en `hd2t`:

```bash
# Vía CLI dentro del contenedor:
docker compose exec freshrss php cli/export-opml-for-user.php --user admin \
  > /tmp/freshrss-admin-$(date +%Y%m%d).opml

# Mover a hd2t (queda dentro de Borg al siguiente run):
sudo mv /tmp/freshrss-admin-*.opml \
  /mnt/hd2t/services/freshrss/data/exports/
sudo chown 33:33 /mnt/hd2t/services/freshrss/data/exports/*.opml
```

> Crear el directorio `exports/` la primera vez con `sudo install -d -o 33 -g 33 -m 0750 /mnt/hd2t/services/freshrss/data/exports`. El OPML es texto plano portable: cualquier agregador RSS lo importa.

---

## 10. Operaciones cotidianas

### 10.1. Upgrade (Watchtower habilitado)

FreshRSS está en el grupo de auto-update de Watchtower ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 línea 466). Watchtower hace `docker pull` cada noche a las 04:00 y, si hay imagen nueva, hace `down` + `up -d` automáticamente.

**Migraciones SQL**: FreshRSS no las ejecuta en arranque del contenedor — las difiere al **primer login del admin** tras el upgrade. Por eso, tras un upgrade automático, conviene que el operador entre a la UI al día siguiente y vea si aparece el banner "Database update required" → click y la migración se aplica en una transacción única.

Si el operador prefiere un ritmo manual (variante §12.7 con hook `pre-update`), el procedimiento es:

```bash
# 1. Leer release notes:
# https://github.com/FreshRSS/FreshRSS/releases

# 2. Backup defensivo previo:
sudo systemctl start borgmatic.service

# 3. Actualizar el tag en el .env:
sudo $EDITOR ~/homelab/stacks/freshrss/.env.example  # actualizar y commit
sudo $EDITOR /mnt/hd2t/services/freshrss/.env

# 4. Pull + up:
cd ~/homelab/stacks/freshrss
docker compose --env-file /mnt/hd2t/services/freshrss/.env pull
docker compose --env-file /mnt/hd2t/services/freshrss/.env up -d

# 5. Verificar healthy y aplicar migraciones (entrar como admin a la UI
#    si aparece el banner, o vía CLI):
docker logs --tail 80 freshrss
docker compose exec freshrss php cli/db-optimize.php --user admin

# 6. Smoke test UI: login + ver lista de feeds + forzar refresh.
```

> **Rollback** (si el upgrade rompe algo):
> 1. Volver el tag al anterior en el `.env`.
> 2. `docker compose pull && docker compose up -d`.
> 3. Si la migración SQL ya se aplicó y es **forward-only** (raro pero posible), restaurar `db.sqlite` por usuario del último Borg pre-upgrade (§9.3).

### 10.2. Añadir un feed

```
UI: Subscription management (icono +) → Add a new feed → URL → Submit.
```

O vía CLI (útil para scripts):

```bash
docker compose exec freshrss php cli/import-for-user.php \
  --user admin --filename /var/www/FreshRSS/data/import.opml
# (Antes copia un OPML mínimo a /mnt/hd2t/services/freshrss/data/import.opml,
# que dentro del contenedor se ve en /var/www/FreshRSS/data/import.opml.)
```

### 10.3. Forzar un refresh manual

```bash
docker compose exec freshrss php cli/actualize_script.php
# Refresca todos los feeds de todos los usuarios.

docker compose exec freshrss php cli/actualize_script.php --user admin
# Solo los feeds del usuario admin.

docker compose exec freshrss php cli/actualize_script.php --feed-id 42
# Un feed concreto (id visible en la UI bajo el feed).
```

### 10.4. Reset de password (sin SMTP)

```bash
# Reset de la password web del usuario:
docker compose exec freshrss php cli/update-user.php \
  --user admin --password 'NuevaPasswordFuerte!'

# Reset de la API password:
docker compose exec freshrss php cli/update-user.php \
  --user admin --api_password 'NuevaApiPasswordFuerte!'

# Anotar las nuevas en KeePassXC + Vaultwarden.
```

### 10.5. Rotar la API password

1. **Configuration → Profile → API password** → introducir una nueva (anotar en Vaultwarden).
2. **Submit**. Los clientes móviles dejan de funcionar inmediatamente.
3. Actualizar la password en cada cliente RSS móvil/desktop.
4. Reeder/FluentReader/FeedMe vuelven a hacer `POST /accounts/ClientLogin` con la nueva password y obtienen un token GReader nuevo.

### 10.6. Importar / exportar OPML

**Importar**:

```
UI: Subscription management → Import / Export → Import OPML file.
```

**Exportar**:

```
UI: Subscription management → Import / Export → Export OPML.
```

El OPML exportado contiene todos los feeds y categorías del usuario (no las entries). Útil para backup adicional, migración, o sincronización entre dos instancias FreshRSS independientes.

### 10.7. Instalar una extensión community

1. Descargar una extensión (carpeta con `metadata.json` + ficheros PHP) — ejemplos: [FreshRSS-Extensions repo](https://github.com/FreshRSS/Extensions).
2. Copiar la carpeta dentro del bind mount:
   ```bash
   sudo cp -r ~/Downloads/xExtension-OriginalLink \
     /mnt/hd2t/services/freshrss/extensions/
   sudo chown -R 33:33 /mnt/hd2t/services/freshrss/extensions/xExtension-OriginalLink
   ```
3. **Configuration → Extensions** en la UI → buscar la nueva extensión → **Activate**.
4. Configurar parámetros si los tiene (depende de la extensión).

### 10.8. Logs y observabilidad

```bash
# Logs en vivo:
docker logs -f freshrss

# Últimas 200 líneas:
docker logs --tail 200 freshrss

# Filtrar errores PHP:
docker logs freshrss 2>&1 | grep -iE 'error|fatal|deprecat'

# Logs por feed (errores de actualización individuales):
sudo cat /mnt/hd2t/services/freshrss/data/users/admin/log_*.txt
```

FreshRSS también tiene un panel de estadísticas en **Statistics** (icono superior derecho) que muestra: feeds más activos, días con más entries, distribución por hora, top categorías. Útil para detectar un feed roto que dejó de actualizar.

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Solución |
|---|---|---|
| Reeder/FluentReader devuelve "Login failed" o "Invalid credentials" | Se está usando la password **web** en lugar de la **API password**. Son distintas. | **Configuration → Profile → API password** en la UI, regenerar y pegar en el cliente. |
| Reeder/FluentReader devuelve "Untrusted certificate" | El móvil no tiene la CA de Caddy en su trust store. | Instalar `root.crt` siguiendo [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §6.5. En iOS también hay que activar "Trust this certificate" en `Settings → General → About → Certificate Trust`. |
| El cron interno no refresca feeds (todo se queda con timestamp viejo) | `crond` del contenedor no arrancó, o `CRON_MIN` está vacío/mal escrito. | `docker exec freshrss ps -ef \| grep crond` debe mostrar el proceso. Validar `CRON_MIN` en el `.env` (sintaxis cron de **minuto**: `1,31`, `*/15`, etc.). Recrear contenedor. |
| Tras un upgrade, login funciona pero la UI muestra "Database update required" | Migraciones SQL diferidas (FreshRSS las difiere al primer login admin). | Click en el banner para aplicarlas, o `docker compose exec freshrss php cli/db-optimize.php --user admin`. |
| Un feed concreto deja de actualizar y aparece con un círculo rojo | El servidor remoto cambió la URL del feed, devuelve `404`/`410`/`5xx` repetidamente, o tiene un certificado inválido. | Click en el feed → **Three dots → Show error log** → leer el detalle. Si la URL cambió, **Edit feed** y actualizarla. |
| `docker logs freshrss` muestra `database is locked` repetidamente | SQLite con WAL pero múltiples writers concurrentes (raro en single-user). | Reducir concurrencia. Si persiste, considerar PostgreSQL (variante §12.3). |
| Tras restore: login falla con la password correcta | El restore mezcló `db.sqlite` nuevo con `db.sqlite-wal` viejo. | Borrar `*-wal` y `*-shm` por usuario tras restaurar `db.sqlite` (paso 5 de §9.3) y reiniciar el contenedor. |
| Los favicons no aparecen | El cron aún no ha pasado (los descarga durante el refresh) o la red `homelab` no tiene egress. | Esperar `CRON_MIN` minutos. `docker exec freshrss curl -fsSI https://example.com/favicon.ico` debe devolver `200 OK`. |
| `502 Bad Gateway` desde Caddy | El contenedor `freshrss` está parado, en `unhealthy`, o no está en la red `homelab`. | `docker inspect freshrss --format '{{.State.Status}} {{json .NetworkSettings.Networks}}'`. Si la red no es `homelab`, releer §4 (`networks: [homelab]` con `external: true`). |
| El refresh manual desde la UI cuelga durante minutos | FreshRSS está procesando feeds en serie (no en paralelo) y uno tiene timeout largo. | El cron interno usa el mismo flujo, pero en background. Aumentar `--curl-options-timeout` modificando el config global en **System → Cron-related options** (no expuesto por defecto). |
| Después de añadir un usuario nuevo en §7.5, no se puede loguear | El usuario fue creado pero la BD por usuario aún no se inicializó (FreshRSS lo hace en el primer login: si falla por timing, queda inconsistente). | `docker compose exec freshrss php cli/list-users.php` confirma la lista. Si falta, eliminar y recrear vía `cli/delete-user.php` + `cli/create-user.php`. |
| Pi-hole no resuelve `freshrss.lan` | Falta el registro DNS local en Pi-hole. | UI de Pi-hole → "Local DNS Records" → añadir `freshrss.lan → 192.168.1.10` (§6.3). |
| GReader API responde con HTML en lugar de XML/JSON | `import authelia_proxy` se ha colado por error en el bloque Caddy. | Releer §6.1: el bloque `freshrss.{$LAN_DOMAIN}` **no** debe importar `authelia_proxy`. |

---

## 12. Variantes opt-in

### 12.1. Variante Alpine (imagen más ligera)

Cambiar el tag a `<version>-alpine` (p. ej. `freshrss/freshrss:1.26.0-alpine`):

- **Pro**: imagen ~50 MB más pequeña, footprint RAM ligeramente menor.
- **Contra**: usuario interno es `apache` (UID 100, no 33), por lo que el bind mount cambia de propietario (`sudo chown -R 100:100 /mnt/hd2t/services/freshrss/data extensions`). Locales españoles pueden no estar baked-in (FreshRSS los tiene como `*.UTF-8` baked si la imagen los incluye; en Alpine variant a veces caen).

Si se adopta, ajustar el `chown` de §3.2 a `100:100` y la sección "Permisos para el proceso" §3.6.

### 12.2. MariaDB en lugar de SQLite

Para >5 usuarios humanos sincronizando muchos feeds en paralelo (raro en homelab):

1. Añadir un servicio `mariadb-freshrss` al `docker-compose.yml` con su propia red interna (`freshrss_internal`), patrón idéntico al de Bookstack ([`./02-bookstack.md`](./02-bookstack.md)).
2. Variables en el `.env`:
   ```dotenv
   FRESHRSS_INSTALL=--api_enabled --default_user admin --language es \
     --db-type mysql --db-host mariadb-freshrss --db-user freshrss \
     --db-password '<password>' --db-base freshrss
   ```
3. Migración del estado existente: dump SQLite por usuario + script de import a MySQL (FreshRSS no provee CLI nativo de migración entre motores; la vía es: instalar nueva instancia con MySQL, exportar OPML del SQLite anterior, importar OPML — pierdes entries históricas pero conservas suscripciones).
4. Actualizar Borgmatic: mover de `sqlite_databases` a `mariadb_databases` ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6).

> **Recomendación**: no migrar a MariaDB salvo necesidad real. SQLite cubre el 99% de los homelabs.

### 12.3. PostgreSQL en lugar de SQLite

Mismo flujo que §12.2 pero con `--db-type pgsql --db-host postgres-freshrss --db-port 5432 ...`. Adecuado si el operador ya tiene una instancia PostgreSQL para Paperless-ngx ([`./04-paperless-ngx.md`](./04-paperless-ngx.md)) y quiere unificar el motor de BD entre ambos servicios.

> En la práctica, mantener cada servicio con su BD dedicada (un PostgreSQL por servicio o SQLite donde se puede) es más simple operacionalmente que un PostgreSQL "compartido". El homelab no se beneficia significativamente de la consolidación a este nivel.

### 12.4. SSO con OIDC (Authelia como provider)

FreshRSS soporta autenticación OIDC desde 1.20+. Permite que el login web pase por Authelia (con 2FA TOTP) sin romper la API GReader/Fever (que sigue con tokens nativos en paralelo):

1. En Authelia (`configuration.yml`), declarar FreshRSS como cliente OIDC ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §10.x):
   ```yaml
   identity_providers:
     oidc:
       clients:
         - id: freshrss
           description: FreshRSS
           secret: '<bcrypt-hash-del-client-secret>'
           public: false
           authorization_policy: two_factor
           redirect_uris:
             - https://freshrss.lan/i/oidc.php
           scopes: [openid, profile, email]
           userinfo_signing_algorithm: none
   ```
2. En el `.env` de FreshRSS, añadir las variables OIDC:
   ```dotenv
   OIDC_ENABLED=1
   OIDC_PROVIDER_METADATA_URL=https://auth.lan/.well-known/openid-configuration
   OIDC_CLIENT_ID=freshrss
   OIDC_CLIENT_SECRET=<el-secreto-en-plaintext>
   OIDC_X_FORWARDED_HEADERS=X-Forwarded-Host X-Forwarded-Port X-Forwarded-Proto
   OIDC_SCOPES='openid profile email'
   ```
3. La GReader API sigue funcionando con la API password nativa — **no** se aplica OIDC a los endpoints `/api/*`. Eso es exactamente lo que se quiere (los clientes móviles no implementan flow OIDC con TOTP).
4. Recargar Authelia y FreshRSS.

> **Trade-off**: el operador acepta dos logins (Authelia + FreshRSS provisiona la cuenta automáticamente) y migra los usuarios humanos a este flujo, manteniendo la API password como segundo canal para los clientes móviles.

### 12.5. SMTP para emails (reset password, alertas de feeds rotos)

FreshRSS tiene soporte nativo de PHPMailer. Configurar en **Configuration → System → SMTP**:

- **SMTP host**: `smtp.example.com`
- **SMTP port**: `587`
- **SMTP username** / **password**.
- **TLS**: `STARTTLS`.
- **Sender email**: `freshrss@example.com`.

Probar con **Send test email** desde la UI. Si funciona, los resets de password (`/i/?c=auth&a=passwordReset`) y las alertas de feeds rotos (opt-in por feed) empezarán a llegar al email del usuario.

### 12.6. Sustituir FreshRSS por Miniflux

Para el operador que prefiere un agregador en Go (más eficiente en RAM) con PostgreSQL:

1. Reemplazar este stack por un nuevo stack `miniflux` con la imagen `miniflux/miniflux:<version>` + `postgres:16-alpine` lateral.
2. Migrar feeds vía OPML (export desde FreshRSS → import en Miniflux).
3. Borrar `/mnt/hd2t/services/freshrss/` tras confirmar la migración.

Miniflux **no** soporta GReader ni Fever — implementa su propia API y un subset compatible con Fever 0.x. Verificar antes de migrar que los clientes RSS del operador soportan la API de Miniflux (Reeder 5+ sí; FluentReader sí; FeedMe parcialmente).

### 12.7. Watchtower con `pre-update` hook (dump SQLite por usuario previo)

Para el operador que quiere auto-update pero con dump defensivo en cada ciclo:

1. Crear `~/homelab/stacks/freshrss/scripts/pre-update.sh`:
   ```bash
   #!/bin/sh
   set -e
   for user_dir in /var/www/FreshRSS/data/users/*/; do
     user=$(basename "$user_dir")
     [ "$user" = "_" ] && continue
     [ "$user" = "_default" ] && continue
     [ -f "${user_dir}db.sqlite" ] || continue
     sqlite3 "${user_dir}db.sqlite" \
       ".backup '${user_dir}db.sqlite.preupdate-$(date +%s)'"
   done
   # Limpiar dumps viejos (mantener solo los 5 últimos por usuario):
   for user_dir in /var/www/FreshRSS/data/users/*/; do
     ls -1t "${user_dir}"db.sqlite.preupdate-* 2>/dev/null \
       | tail -n +6 | xargs -r rm -f
   done
   ```
2. Bind-mount el script en `/var/www/FreshRSS/data/scripts/pre-update.sh` y añadir las labels al servicio:
   ```yaml
   labels:
     com.centurylinklabs.watchtower.lifecycle.pre-update: /var/www/FreshRSS/data/scripts/pre-update.sh
     com.centurylinklabs.watchtower.lifecycle.pre-update-timeout: "60"
   ```
3. Watchtower ejecuta el script **dentro** del contenedor antes del `down`, dejando dumps consistentes en el bind mount.

> **Coste**: ~5-50 MB extra por dump por usuario, máximo 5 dumps = 25-250 MB. Despreciable.

### 12.8. Jail Fail2ban dedicado para `/i/?c=auth&a=login`

El jail global `caddy-status` cubre intentos `4xx` de forma genérica, pero un jail dedicado al endpoint de login de FreshRSS permite bans más rápidos en intentos de fuerza bruta:

1. Crear `/etc/fail2ban/filter.d/freshrss-login.conf`:
   ```ini
   [Definition]
   failregex = ^<HOST>.*"POST /i/\?c=auth&a=login.*" 401 .*$
               ^<HOST>.*"POST /api/greader\.php/accounts/ClientLogin.*" 401 .*$
   ignoreregex =
   ```
2. En `jail.local`:
   ```ini
   [freshrss-login]
   enabled = true
   port = 80,443
   filter = freshrss-login
   logpath = /var/log/caddy/access.log
   maxretry = 5
   bantime = 1h
   findtime = 10m
   ```
3. `sudo fail2ban-client reload`.

> **Coste**: una regla más en el firewall. Beneficio: bans específicos por intentos sobre FreshRSS sin afectar a otros servicios.

### 12.9. Acceso solo Tailscale (sin LAN)

Si el operador quiere que `freshrss.lan` **no** funcione fuera de Tailscale (caso raro: ya estamos en LAN-only, pero algunos operadores prefieren forzar el flujo Tailscale incluso en casa):

1. **Eliminar** el bloque `freshrss.{$LAN_DOMAIN}` del `Caddyfile`.
2. **Activar** solo el bloque `freshrss.{$TS_DOMAIN}` (descomentar de §6.5).
3. **Eliminar** el registro DNS local `freshrss.lan` de Pi-hole.

Tras esto, el acceso solo funciona desde dispositivos en la tailnet. Los clientes RSS móviles deben configurarse con `https://freshrss.${TS_DOMAIN}` como endpoint.

---

## 13. Referencias

- [FreshRSS — repositorio oficial (GitHub)](https://github.com/FreshRSS/FreshRSS)
- [FreshRSS — releases (release notes para upgrades)](https://github.com/FreshRSS/FreshRSS/releases)
- [FreshRSS — imagen Docker oficial (Docker Hub)](https://hub.docker.com/r/freshrss/freshrss)
- [FreshRSS — documentación de la imagen Docker](https://github.com/FreshRSS/FreshRSS/blob/edge/Docker/README.md)
- [FreshRSS — documentación oficial (incluye GReader/Fever API y OIDC)](https://freshrss.github.io/FreshRSS/)
- [FreshRSS — extensiones community](https://github.com/FreshRSS/Extensions)
- [Google Reader API — referencia (API soportada por FreshRSS)](https://github.com/theoldreader/api)
- [Fever API — referencia (API soportada por FreshRSS)](https://web.archive.org/web/20161204133933/https://feedafever.com/api)
- [PHP — `password_hash` (PASSWORD_BCRYPT)](https://www.php.net/manual/en/function.password-hash.php)
- [SQLite — Online Backup API (`.backup`)](https://www.sqlite.org/backup.html)
- Documentos relacionados del homelab:
  - [`./03-linkding.md`](./03-linkding.md) — Patrón de servicio sin Authelia (clientes API).
  - [`./05-mealie.md`](./05-mealie.md) — Patrón de servicio con SQLite y clientes externos.
  - [`./04-paperless-ngx.md`](./04-paperless-ngx.md) — Patrón de servicio con Authelia + bypass selectivo (contraste).
  - [`../03-red/04-caddy.md`](../03-red/04-caddy.md) — Reverse proxy y CA interna.
  - [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) — Por qué FreshRSS **no** está en `access_control.rules`.
  - [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6 (líneas 547-548) — Hook SQLite (a corregir vía §9.2 de este doc).
  - [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) — Patrón de restore para SQLite.
  - [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 (línea 466) — FreshRSS en el grupo de auto-update.
  - [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.1 (línea 241) — Bootstrap de `/mnt/hd2t/services/freshrss/`.
