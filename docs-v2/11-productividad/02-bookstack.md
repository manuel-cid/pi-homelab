# Bookstack

## Descripción

Despliegue de **Bookstack** ([imagen `lscr.io/linuxserver/bookstack`](https://docs.linuxserver.io/images/docker-bookstack/)) como **wiki/sistema de documentación** del homelab. Bookstack es una aplicación Laravel (PHP 8) con una jerarquía de tres niveles — **estanterías → libros → capítulos → páginas** — y un editor WYSIWYG/Markdown. Es el **sistema canónico para la documentación operativa interna del homelab**: desde "el procedimiento exacto para resetear el TOTP de un familiar en Authelia" hasta "los stickers QR que se imprimieron para los enchufes Zigbee", pasando por las "notas privadas que NO encajan en este repo de Markdown público o privado en git".

> **Frontera con este repo en git**: el contenido de `docs/00-` … `docs/13-` (este árbol) es la **documentación arquitectónica reproducible**, escrita una vez y revisada en PRs. Bookstack es la **memoria operativa del día a día**: actas de cambios, rastros de incidentes resueltos, fotos de las conexiones físicas, listas mutables (bombillas Zigbee con su `friendly_name`, mapeo de habitaciones, IPs DHCP del momento). El criterio: si una nota podría ayudar a otra persona a montar el mismo homelab desde cero, va a git; si solo tiene sentido para **este** homelab concreto en su estado **actual**, va a Bookstack.

Bookstack es **el segundo servicio de la Fase 11 — Productividad**, después de Vaultwarden, y su compañero natural: Vaultwarden custodia los **secretos circulantes** ([`./01-vaultwarden.md`](./01-vaultwarden.md) §0), Bookstack custodia el **conocimiento circulante**. Entre los dos cubren la "huella mental" del operador sobre el homelab — todo lo que **no** está en git ni en `~/homelab/stacks/`.

Por qué exactamente esta arquitectura, y no otra:

1. **Bookstack, no Wiki.js, no MediaWiki, no Outline, no Trilium, no Obsidian sync.** Bookstack apuesta por una jerarquía **rígida y opinada** (estanterías → libros → capítulos → páginas, ver §1) que escala bien hasta varios miles de páginas sin convertirse en un grafo ingobernable. Las alternativas pecan en alguno de estos ejes: (a) **Wiki.js** es excelente pero su persistencia preferida es PostgreSQL + Elasticsearch (más componentes, más migraciones); (b) **MediaWiki** es industrialmente sólido pero su markup es legacy y su DX para "una persona, no Wikipedia" es excesivo; (c) **Outline** apunta a equipos con SaaS-flavor, requiere Redis + S3 obligatorio, y el self-host es ciudadano de segunda clase frente a su nube; (d) **Trilium** es maravilloso para notas personales pero su modelo de "tree of notes con clones" es difícil de compartir con otros humanos; (e) **Obsidian sync** delega la sincronización a un servicio de pago o a Syncthing — válido para uno mismo, no para "la pareja apunta una receta y el operador la encuentra". Bookstack es la talla "S/M" justa para un homelab de 1–4 humanos: editor decente, jerarquía explícita, búsqueda full-text con MySQL/MariaDB stock (sin Elasticsearch), permisos por libro/capítulo/página, multi-usuario, exportación a PDF/HTML/Markdown.
2. **Imagen `lscr.io/linuxserver/bookstack`, no la upstream `bookstackapp/bookstack`.** La imagen upstream entrega solo el código PHP-FPM y obliga al operador a montar nginx/Apache aparte; la de LinuxServer.io bundlea **Apache + PHP-FPM + cron + supervisor** en un único contenedor multi-arch (incluye `linux/arm64` nativo para Pi 5), expone `:80` y orquesta `php artisan migrate --force` en cada arranque tras pinear el tag. Coherente con el resto de stacks LSIO ya desplegados en el homelab — Sonarr ([`../10-descargas/03-sonarr.md`](../10-descargas/03-sonarr.md)), Radarr ([`../10-descargas/04-radarr.md`](../10-descargas/04-radarr.md)), Prowlarr, Transmission, Calibre-Web, Audiobookshelf, etc. — todos comparten convención `PUID`/`PGID`/`TZ` y registro `lscr.io`. La imagen upstream `bookstackapp/bookstack` queda como variante opt-in en §12.3 para el operador que prefiera php-fpm puro y servidor web propio.
3. **MariaDB 11.4 LTS, no SQLite, no PostgreSQL.** Bookstack soporta nominalmente SQLite y PostgreSQL **pero su CI primario, su documentación y sus migraciones de Laravel se prueban contra MySQL/MariaDB** — el resto de motores reciben fixes con retraso y cada `php artisan migrate` puede esconder un edge case. MariaDB 11.4 LTS es además el **mismo motor que ya despliega Nextcloud** ([`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md) §0 y §10), así que el operador ya tiene scripts, dumps, hooks de Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6, líneas 528–534, **bookstack ya está declarado**) y procedimientos de restore ([`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §2.2, §4.4, §5.4) familiares. Cada stack monta su **propia** instancia de MariaDB en una red interna aislada (no se reusa la de Nextcloud): el contrato del homelab ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §1.3) es **un stack por dominio funcional**, sin compartir BD entre stacks; eso simplifica los upgrades y elimina blast radius. SQLite queda como variante opt-in (§12.4) para el operador que solo vaya a tener 1 usuario.
4. **Detrás de Caddy con CA interna y de Authelia en `forward_auth`.** Coherente con la regla de [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §0 punto 1 y con la lista de hosts ya declarada en su `access_control` (línea 421 de Authelia: `bookstack.{$LAN_DOMAIN}` con `policy: two_factor` y `subject: group:admin`). A diferencia de Vaultwarden ([`./01-vaultwarden.md`](./01-vaultwarden.md) §0 punto 3), Bookstack **sí** se sirve detrás de Authelia — toda la interacción es **humana** (UI web, sin app móvil oficial que se autentique por OAuth2 contra `/api/*`), así que el flujo de redirección de `forward_auth` no rompe ningún cliente. Authelia provee el **borde** (login + 2FA TOTP), Bookstack provee la **autorización fina** (su propio sistema de roles internos: admin / editor / viewer / personal-only). El operador acepta **dos logins** (uno en Authelia, uno en Bookstack) durante la fase actual; la integración SSO via OIDC queda como variante opt-in en §12.5 para cuando Authelia exponga OIDC ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) tiene la documentación de OIDC marcada como "futura").
5. **Datos persistentes en `hd2t`, en `/mnt/hd2t/services/bookstack/`.** Coherente con [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.1 (loop "Fase 11 — Productividad", línea `for svc in vaultwarden bookstack ...`) y con el path ya prometido en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6 (`password: '{credential file /mnt/hd2t/services/bookstack/secrets/db_password}'`). El árbol que se materializa en §3:
   - `/mnt/hd2t/services/bookstack/.env` — configuración del stack (chmod 600).
   - `/mnt/hd2t/services/bookstack/config/` — bind mount de `/config` del contenedor Bookstack: `www/uploads/` (imágenes embebidas en páginas), `www/files/` (adjuntos), `nginx/site-confs/`, `keys/`, logs.
   - `/mnt/hd2t/services/bookstack/db/data/` — bind mount de `/var/lib/mysql` del contenedor MariaDB.
   - `/mnt/hd2t/services/bookstack/secrets/db_password`, `secrets/db_root_password`, `secrets/app_key` — credenciales custodiadas (`chmod 600 root:homelab`).
   - `/mnt/hd2t/services/bookstack/scripts/pre-update.sh` — hook Watchtower opt-in (variante §12.6).
6. **Imagen `lscr.io/linuxserver/bookstack:<version>-ls<N>` y `mariadb:11.4` pinned a release puntual.** Igual que el resto del homelab: nunca `latest`, nunca `<major>` rolling. Misma regla que [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1. **Watchtower NO actualiza Bookstack** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.1 línea 457, fila `Bookstack`: "Migraciones de Laravel; mejor con backup previo"). El upgrade es manual: leer release notes → hacer dump → `docker compose pull` → `docker compose up -d`. Los detalles, en §10.1.
7. **Dos redes Docker, una pública (`homelab`) y una interna (`bookstack_internal`).** El contenedor `bookstack-app` se conecta a **ambas**: a `homelab` para que Caddy le llegue por nombre Docker (`http://bookstack-app:80`), y a `bookstack_internal` para hablar con MariaDB. El contenedor `mariadb-bookstack` se conecta **solo** a `bookstack_internal`. Patrón idéntico al de Nextcloud ([`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md) §0 punto 1). Eso garantiza que: (a) ningún otro servicio del homelab pueda hablar accidentalmente con la BD de Bookstack (defensa en profundidad si un contenedor de la red `homelab` se compromete); (b) MariaDB no publica `:3306` al host (Caddy nunca la toca, y eso elimina el principal vector contra MariaDB: acceso TCP anónimo desde la LAN).
8. **`APP_URL=https://bookstack.${LAN_DOMAIN}` con scheme HTTPS.** Bookstack/Laravel usa `APP_URL` para construir todos los enlaces absolutos: redirecciones de login, callbacks OAuth/OIDC futuros, links en emails, URLs de recursos estáticos, sitemap. Si está mal o ausente, los formularios redirigen a `http://localhost` (visible en la consola del navegador, los enlaces en exportes a HTML/PDF salen rotos, las imágenes embebidas se sirven con `Content-Security-Policy` mixed). Debe coincidir **byte a byte** con el host del bloque Caddy (§6).
9. **`APP_KEY` generado una sola vez y custodiado.** Laravel usa `APP_KEY` (32 bytes random, formato `base64:...`) para cifrar cookies de sesión, tokens de password reset y campos cifrados en BD (los **adjuntos privados** se cifran con esta clave). **Cambiar `APP_KEY` después del primer arranque invalida sesiones activas y, lo que es peor, impide descifrar adjuntos cifrados existentes.** Por eso `APP_KEY` se genera **una vez** (§5.3) con `php artisan key:generate --show`, se custodia en KeePassXC + Vaultwarden (cuando aplique), y se persiste en `secrets/app_key` con `chmod 600`. El `.env.example` lo deja vacío.
10. **Sin SMTP por defecto.** El homelab no tiene MTA ([`./01-vaultwarden.md`](./01-vaultwarden.md) §0 punto 4 y [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §0 punto 7). Bookstack puede usar email para invitaciones, reseteo de password, notificaciones de comentario. Sin SMTP: las invitaciones se materializan como links que el operador pasa por canal alternativo (Signal/Telegram), el reset de password se hace desde la consola con `php artisan bookstack:reset-password`, y las notificaciones de comentario se ven solo desde la UI. Variante con SMTP relay en §12.1.

> **Alcance de red**: la UI de Bookstack **no** publica puertos al host. Se accede únicamente vía `https://bookstack.${LAN_DOMAIN}` (Caddy + CA interna + Authelia 2FA) y, una vez completada la fase Tailscale, vía `https://bookstack.${TS_DOMAIN}`. El homelab opera en LAN + Tailscale, sin exposición a internet, sin Let's Encrypt público, sin port forwarding.

> **Alcance de auth**: Authelia (`forward_auth` con `policy: two_factor`, `subject: group:admin`) cubre el borde. Bookstack mantiene su propio modelo de usuarios y roles para autorización fina. La cuenta `admin@admin.com` por defecto se renombra y blinda en §7.1 antes de exponer la URL incluso a la familia.

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), `/mnt/hd2t/` montado, directorio `/mnt/hd2t/services/bookstack/` ya creado por el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.1 (loop "Fase 11 — Productividad", línea `for svc in vaultwarden bookstack ...`).
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` creada (`172.20.0.0/24`, `external: true`), convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3 y §5).
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) con `lan_internal_tls` y `security_headers` operativos.
- **CA interna de Caddy** instalada en al menos un dispositivo (navegador del operador), procedimiento §6.5 de Caddy. Sin la CA confiada, Bookstack carga pero el navegador marca el sitio como inseguro y los exportes a PDF (Bookstack los genera vía cabecera `Content-Disposition`) se sirven con warnings.
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con la posibilidad de añadir un registro DNS local: `bookstack.${LAN_DOMAIN}` → IP del host donde escucha Caddy.
- **Authelia desplegado** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)) con el snippet `authelia_proxy` en `~/homelab/stacks/proxy/snippets/authelia_proxy` (§9.1 de Authelia) y la entrada `bookstack.{$LAN_DOMAIN}` ya presente en `access_control.rules` (línea 421 de Authelia, ya escrita anticipadamente). El operador tiene su cuenta TOTP enrollada y al menos una recovery key custodiada (Authelia §10).
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) con el bloque `mariadb_databases` ya configurado para `bookstack` (líneas 528–534 de Borgmatic, ya presentes). El hook se ejecuta cada noche y produce un dump consistente con `mariadb-dump --single-transaction` antes del snapshot Borg.
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Bookstack lleva la etiqueta `com.centurylinklabs.watchtower.enable: "false"` (justificado en §0 punto 6 y en Watchtower §4.1, línea 457).
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No se añaden reglas: Bookstack no publica puertos al host; el tráfico entra por Caddy.
- **Vaultwarden desplegado** ([`./01-vaultwarden.md`](./01-vaultwarden.md)). No es bloqueante para arrancar Bookstack (los secretos pueden custodiarse provisionalmente en KeePassXC), pero la convención del homelab es que el operador ya tenga Vaultwarden activo cuando empieza la Fase 11; cualquier credencial nueva (passwords de BD, `APP_KEY`) se anota allí.
- **Espacio libre en `hd2t`** ≥ 1 GB es más que suficiente para el primer año de uso. La BD de Bookstack crece muy lento (<10 MB para varios cientos de páginas); los `uploads/` y `files/` crecen con el peso de imágenes/adjuntos que el operador suba (~1–10 MB por imagen).
- **Comprobaciones rápidas**:
  ```bash
  # Red homelab existe:
  docker network inspect homelab --format '{{(index .IPAM.Config 0).Subnet}}'
  # Esperado: 172.20.0.0/24

  # Caddy está sano:
  docker inspect caddy --format '{{.Name}}: {{.State.Health.Status}}'
  # Esperado: caddy: healthy

  # Authelia está sano y con la regla bookstack.lan ya en su config:
  docker inspect authelia --format '{{.State.Health.Status}}'
  grep -F 'bookstack.{{ env "LAN_DOMAIN" }}' \
    ~/homelab/stacks/auth/configuration.yml
  # Esperado: línea encontrada bajo policy: two_factor.

  # Pi-hole resuelve bookstack.lan al host (preparar antes en su UI):
  dig +short @192.168.1.241 bookstack.lan
  # Esperado: 192.168.1.10  (si no, añadir el registro en Pi-hole y volver)

  # Estructura de directorios y propietario:
  ls -ld /mnt/hd2t/services/bookstack
  # Esperado: drwxr-x--- homelab homelab ...
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Wiki engine | **Bookstack** | Justificado en §0 punto 1. Talla "S/M" para 1–4 humanos. |
| Imagen Docker (app) | **`lscr.io/linuxserver/bookstack`** | Multi-arch incluyendo `linux/arm64`. Bundle Apache + PHP-FPM + cron + supervisor. Coherente con el resto del homelab que usa imágenes LSIO. Variante upstream en §12.3. |
| Tag de imagen (app) | **`24.10.4-ls289`** (no `latest`, no `version-24` rolling) | Misma regla del homelab. Cada minor de Bookstack puede traer migraciones Laravel. Pinning fuerza al operador a leer release notes antes de subir. |
| Imagen Docker (BD) | **`mariadb:11.4`** (LTS oficial) | Coherente con Nextcloud ([`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md) §0 punto 4). LTS hasta 2029. Multi-arch. |
| Backend de BD | **MariaDB** | Justificado en §0 punto 3. SQLite/PostgreSQL como variantes opt-in (§12.4). |
| Política de Watchtower | **`watchtower.enable: "false"`** (en ambos contenedores) | Justificado en §0 punto 6 y en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.1, línea 457. Upgrade manual con dump previo (§10.1). |
| Arquitectura | `linux/arm64` (Pi 5) | Manifest multi-arch oficial de ambas imágenes. |
| Redes Docker | **`homelab`** (bridge externa) + **`bookstack_internal`** (bridge interna del stack) | Justificado en §0 punto 7. App en ambas, BD solo en `bookstack_internal`. |
| Modelo de almacenamiento | **Bind mounts** sobre `/mnt/hd2t/services/bookstack/{config,db/data,secrets,scripts}/` | Patrón estándar del homelab. Bind mount, no named volume — facilita backup directo, ruta predecible. |
| Reverse proxy | **Caddy** con `lan_internal_tls` + `security_headers` + **`authelia_proxy`** | Justificado en §0 punto 4. Authelia delante con `policy: two_factor`, `subject: group:admin` (ya en `access_control.rules` de Authelia, línea 421). |
| Hostname interno (app) | **`bookstack-app`** (`container_name`) | Caddy llama `http://bookstack-app:80`. Un nombre con guion explícito evita confusión con el directorio del stack. |
| Hostname interno (BD) | **`mariadb-bookstack`** (`container_name`) + `hostname: mariadb` | Coherente con Nextcloud (`mariadb-nextcloud`/`hostname: mariadb`). Borgmatic ya espera `mariadb-bookstack` ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6, línea 531). |
| Subdominio LAN | **`bookstack.${LAN_DOMAIN}`** (típicamente `bookstack.lan`) | Mismo subdominio ya escrito en `access_control.rules` de Authelia (línea 421). |
| `APP_URL` env | **`https://bookstack.${LAN_DOMAIN}`**, sin trailing slash | Justificado en §0 punto 8. |
| `APP_KEY` env | **Generado una vez** con `php artisan key:generate --show` (§5.3), custodiado en `secrets/app_key` | Justificado en §0 punto 9. **Nunca** rotar después del primer uso (rompe sesiones y descifrado). |
| `DB_HOST`/`DB_PORT`/`DB_DATABASE`/`DB_USERNAME`/`DB_PASSWORD` | `mariadb` / `3306` / `bookstack` / `bookstack` / leído de `secrets/db_password` | Convención LSIO. La password se inyecta desde el `.env` (no se usa `_FILE` porque la imagen LSIO no soporta `*_FILE` indirection para esta variable; ver §4.1). |
| `MAIL_DRIVER` | **`log`** (default sin SMTP) | El homelab no tiene MTA. Bookstack escribe los emails que enviaría a `/config/log/laravel.log`. Variante con SMTP en §12.1. |
| `APP_DEBUG` | **`false`** (default de la imagen) | `true` filtra stack traces detallados al navegador. **Nunca** activarlo en producción. |
| `APP_ENV` | **`production`** | Activa caches de configuración y rutas (Laravel optimizaciones). |
| `APP_LOCALE` | **`es`** | Operador en castellano. Variantes (`en`, `fr`, etc.) en la UI de admin. |
| `APP_TIMEZONE` | **`Europe/Madrid`** (== `${TZ}` del homelab) | Coherente con [`../01-sistema/02-configuracion-inicial.md`](../01-sistema/02-configuracion-inicial.md). |
| `AUTH_METHOD` | **`standard`** (login local Bookstack) | La integración OIDC con Authelia queda como variante §12.5 cuando Authelia exponga el endpoint. La defensa de borde la lleva Authelia `forward_auth`; la fina, los roles internos de Bookstack. |
| `STORAGE_TYPE` | **`local_secure`** (default) | Adjuntos cifrados con `APP_KEY`, accesibles solo a través de Bookstack (no exponiendo el directorio vía URL directa). Variante S3/MinIO en §12.7. |
| `ALLOW_ROBOTS` | **`false`** | Bookstack no debe ser indexado: aunque el sitio no es público, la regla impide que un crawler accidental dentro de la LAN indexe el contenido. |
| `IP_HEADER` (Apache `RemoteIPInternalProxy`) | **Default LSIO** (`X-Forwarded-For` desde `localhost` a través del Caddy). Bookstack lee la IP real del cliente para auditoría. | Caddy ya inyecta `X-Forwarded-For` y `X-Real-IP` por defecto. |

---

## 1. Resumen de la arquitectura

```
                     ┌──────────────────────────────────────────────┐
LAN / Tailscale ───► │  Caddy (stack proxy)                         │
                     │   bookstack.{$LAN_DOMAIN}                    │
                     │     import lan_internal_tls                  │
                     │     import security_headers                  │
                     │     import authelia_proxy   ◄─┐              │
                     │     reverse_proxy http://bookstack-app:80    │
                     └───────────────────┬──────────────────────────┘
                                         │
                          forward_auth (cookie de sesión Authelia)
                                         │
                     ┌───────────────────▼──────────────────────────┐
                     │  Authelia (stack auth)                        │
                     │   /api/authz/forward-auth                     │
                     │   policy: two_factor, subject: group:admin    │
                     └──────────────────────────────────────────────┘

      Tras pasar Authelia, la petición sigue al backend:

                        ┌──────────────────── network: homelab ───────────────────┐
                        │                                                          │
                        │  bookstack-app (lscr.io/linuxserver/bookstack)           │
                        │   user: 1000:1000                                        │
                        │   /:80 (Apache + PHP-FPM)                                │
                        │   bind: /mnt/hd2t/services/bookstack/config:/config      │
                        │                                                          │
                        └──────────────────────┬───────────────────────────────────┘
                                               │
                                               │ network: bookstack_internal
                                               │
                        ┌──────────────────────▼───────────────────────────────────┐
                        │  mariadb-bookstack (mariadb:11.4)                        │
                        │   user: 999:999 (mysql:mysql, default de la imagen)      │
                        │   :3306  (NO publicado al host)                          │
                        │   bind: /mnt/hd2t/services/bookstack/db/data:/var/lib/mysql │
                        │   secrets: db_password, db_root_password (bind mounts ro)│
                        └──────────────────────────────────────────────────────────┘
```

| Componente | Stack file | Datos persistentes | Contacto exterior |
|---|---|---|---|
| `bookstack-app` | `~/homelab/stacks/bookstack/docker-compose.yml` | `/mnt/hd2t/services/bookstack/config/` | Solo vía Caddy (`http://bookstack-app:80`) |
| `mariadb-bookstack` | mismo `docker-compose.yml`, segundo servicio | `/mnt/hd2t/services/bookstack/db/data/` | Solo vía red `bookstack_internal` desde `bookstack-app` |

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/bookstack/.env.example` (en git, sin secretos):

```env
# ============================================================================
#  Stack: bookstack  ([../11-productividad/02-bookstack.md])
#  Plantilla — el .env real vive en /mnt/hd2t/services/bookstack/.env
# ============================================================================

# --- Identidad & dominio ---------------------------------------------------
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net   # se rellenará cuando 05-tailscale.md esté listo
APP_URL=https://bookstack.${LAN_DOMAIN}

# --- Imágenes --------------------------------------------------------------
BOOKSTACK_IMAGE=lscr.io/linuxserver/bookstack:24.10.4-ls289
MARIADB_IMAGE=mariadb:11.4

# --- Permisos y rutas ------------------------------------------------------
PUID=1000
PGID=1000
TZ=Europe/Madrid

# --- Comportamiento de la app ----------------------------------------------
APP_ENV=production
APP_DEBUG=false
APP_LOCALE=es
APP_TIMEZONE=Europe/Madrid
ALLOW_ROBOTS=false
AUTH_METHOD=standard
STORAGE_TYPE=local_secure
MAIL_DRIVER=log

# --- Conexión a la BD ------------------------------------------------------
DB_HOST=mariadb
DB_PORT=3306
DB_DATABASE=bookstack
DB_USERNAME=bookstack
# DB_PASSWORD se inyecta desde el .env real (NUNCA aquí).

# --- APP_KEY ---------------------------------------------------------------
# Generado UNA SOLA VEZ con `docker run --rm lscr.io/linuxserver/bookstack \
#   php /app/www/artisan key:generate --show`. Empieza por "base64:".
# Vacío en .env.example: el valor real vive en .env y en secrets/app_key.
APP_KEY=

# --- SMTP (opcional, vacío por defecto) ------------------------------------
MAIL_HOST=
MAIL_PORT=
MAIL_USERNAME=
MAIL_PASSWORD=
MAIL_ENCRYPTION=
MAIL_FROM=
```

| Bloque | Por qué versionar |
|---|---|
| `LAN_DOMAIN`, `TS_DOMAIN`, `APP_URL` | Convención del homelab; sin valor secreto. `APP_URL` debe sincronizarse con el bloque Caddy. |
| `BOOKSTACK_IMAGE`, `MARIADB_IMAGE` | Tags pinned. Cambiarlos se hace mediante PR en el repo, con review. |
| `PUID`/`PGID`/`TZ` | Convenciones del homelab, sin secretos. |
| Comportamiento de la app (`APP_*`, `ALLOW_ROBOTS`, `AUTH_METHOD`, `STORAGE_TYPE`, `MAIL_DRIVER`) | Decisiones públicas (no son credenciales). El día que el operador conmute a OIDC o a SMTP real se hace por PR, queda auditado en git. |
| `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME` | Acoplamiento con el servicio MariaDB del mismo stack — los nombres no son secretos, las passwords sí. |
| `APP_KEY` (vacío) | El valor real **nunca** toca git. |
| Credenciales SMTP | Vacías por defecto (homelab sin SMTP). El día que se rellenen, irán al `.env` real, no aquí. |

### 2.2. `.env` real (`/mnt/hd2t/services/bookstack/.env`)

Fuera de git, modo `600 homelab:homelab`. Mismo contenido que `.env.example` **pero** con tres adiciones:

```env
# (todas las variables anteriores con sus mismos valores) ...

APP_KEY=base64:<el valor real generado en §5.3>
DB_PASSWORD=<password fuerte custodiada en Vaultwarden y en secrets/db_password>

# Solo si SMTP se activa en el futuro (variante §12.1):
# MAIL_HOST=smtp.relay.example.com
# MAIL_PORT=587
# MAIL_USERNAME=...
# MAIL_PASSWORD=...
# MAIL_ENCRYPTION=tls
# MAIL_FROM=bookstack@example.com
```

> **Nota sobre `DB_PASSWORD` y `secrets/db_password`**: la misma password se almacena en **dos sitios**: (a) como variable de entorno en el `.env` (que Compose carga e inyecta en el contenedor `bookstack-app`), y (b) como fichero `/mnt/hd2t/services/bookstack/secrets/db_password` que el contenedor `mariadb-bookstack` monta como `/run/secrets/db_password` y lee con `MARIADB_PASSWORD_FILE`. Esta duplicación es **necesaria** porque la imagen LSIO de Bookstack **no soporta** la indirection `DB_PASSWORD_FILE` (lee la env directamente, sin expansion `$(cat ...)`). El operador escribe **el mismo valor** en `.env` y en `secrets/db_password`; el script de despliegue de §5 lo verifica.

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` usa `env_file: /mnt/hd2t/services/bookstack/.env` para `bookstack-app`. Compose carga **todas** las variables del fichero en el environment del contenedor; la imagen LSIO las lee al ejecutar su `init` script (`/etc/cont-init.d/`), que renderiza `/app/www/.env` de Bookstack a partir de las env detectadas. La BD MariaDB recibe sus credenciales por la combinación de `MARIADB_*_FILE` (root y user passwords) + `MARIADB_DATABASE`/`MARIADB_USER` directos del `.env`.

> **Por qué `MARIADB_*_FILE` y no env directas para MariaDB**: la imagen oficial `mariadb` **sí** soporta la indirection `_FILE` para passwords; usarla evita que la password aparezca en `docker inspect` (que muestra todas las env del contenedor). En cambio, la app LSIO de Bookstack no la soporta, así que la `DB_PASSWORD` sí aparece en `docker inspect bookstack-app`. Es un compromiso aceptado: la mitigación es que `docker inspect` solo lo lee `root` (o miembros del grupo `docker`), y el operador es el único en ese grupo.

> **`.env.example` y `.env` deben tener las mismas claves**. Política coherente con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.4: "el `.env.example` es el contrato — si tienes algo en `.env` que no está documentado allí, otra persona no podrá reconstruir el stack tras un disaster recovery".

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
mkdir -p ~/homelab/stacks/bookstack
cd ~/homelab/stacks/bookstack

# Solo el .env.example y el docker-compose.yml viven aquí.
touch .env.example
touch docker-compose.yml
```

### 3.2. Crear el árbol de datos persistentes del servicio

El directorio `/mnt/hd2t/services/bookstack/` ya existe (creado por el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.1 con propietario `homelab:homelab` y modo `750`). Se crean los subárboles que las imágenes poblarán al primer arranque:

```bash
# Datos de la app (bind mount /config dentro del contenedor LSIO).
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/bookstack/config

# Datos de MariaDB. Owner mysql:mysql (UID/GID 999) — NO homelab.
sudo install -d -o 999 -g 999 -m 750 /mnt/hd2t/services/bookstack/db
sudo install -d -o 999 -g 999 -m 700 /mnt/hd2t/services/bookstack/db/data

# Secretos del stack. root:homelab para que homelab solo pueda leer
# los .env files que él mismo creó (no los secretos), pero los
# scripts de pre-update Watchtower (que corren como root) sí.
sudo install -d -o root -g homelab -m 750 /mnt/hd2t/services/bookstack/secrets

# Scripts opt-in (pre-update Watchtower). Vacío por defecto.
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/bookstack/scripts
```

### 3.3. Generar las passwords y el `APP_KEY`

Las dos passwords de MariaDB (root y user) y el `APP_KEY` se generan **antes** de levantar el stack, para no caer en el antipatrón "MariaDB arranca con password aleatoria de la imagen y luego el operador la ignora":

```bash
# 1. Password del usuario `bookstack` de MariaDB (la lee bookstack-app).
DB_PASS="$(openssl rand -base64 32 | tr -d '/=+' | head -c 40)"
echo -n "$DB_PASS" | sudo install -m 600 -o root -g homelab /dev/stdin \
    /mnt/hd2t/services/bookstack/secrets/db_password

# 2. Password de root de MariaDB (solo la usan los hooks de mantenimiento;
#    la app NO la usa).
DB_ROOT_PASS="$(openssl rand -base64 32 | tr -d '/=+' | head -c 40)"
echo -n "$DB_ROOT_PASS" | sudo install -m 600 -o root -g homelab /dev/stdin \
    /mnt/hd2t/services/bookstack/secrets/db_root_password

# 3. APP_KEY (Laravel). Lo extraemos sin arrancar el stack:
APP_KEY="$(docker run --rm \
    -e APP_KEY="" \
    lscr.io/linuxserver/bookstack:24.10.4-ls289 \
    /usr/bin/php /app/www/artisan key:generate --show \
    2>/dev/null | tail -n1)"

# Validación: empieza por "base64:" y tiene 44 caracteres tras el prefijo.
if ! echo "$APP_KEY" | grep -Eq '^base64:[A-Za-z0-9+/=]{44}$'; then
  echo "ERROR: APP_KEY mal formada: $APP_KEY"; exit 1
fi

echo -n "$APP_KEY" | sudo install -m 600 -o root -g homelab /dev/stdin \
    /mnt/hd2t/services/bookstack/secrets/app_key

# 4. Anotar en Vaultwarden (manualmente desde el navegador) las tres claves:
#    - "Bookstack — DB user password"
#    - "Bookstack — DB root password"
#    - "Bookstack — APP_KEY"
echo "DB_PASS=$DB_PASS"
echo "DB_ROOT_PASS=$DB_ROOT_PASS"
echo "APP_KEY=$APP_KEY"
unset DB_PASS DB_ROOT_PASS APP_KEY
```

### 3.4. Materializar el `.env` real

```bash
# Copiar el .env.example como base.
sudo install -m 600 -o homelab -g homelab \
    ~/homelab/stacks/bookstack/.env.example \
    /mnt/hd2t/services/bookstack/.env

# Editar para rellenar APP_KEY y DB_PASSWORD desde los ficheros de secretos.
sudo -u homelab tee -a /mnt/hd2t/services/bookstack/.env >/dev/null <<EOF

# --- Valores reales (NO versionar, NO commitear) ---
APP_KEY=$(sudo cat /mnt/hd2t/services/bookstack/secrets/app_key)
DB_PASSWORD=$(sudo cat /mnt/hd2t/services/bookstack/secrets/db_password)
EOF

# Verificación.
sudo grep -E '^(APP_KEY|DB_PASSWORD)=' /mnt/hd2t/services/bookstack/.env | wc -l
# Esperado: 2
sudo stat -c '%U:%G %a' /mnt/hd2t/services/bookstack/.env
# Esperado: homelab:homelab 600
```

### 3.5. Tabla resumen de permisos

| Path | Owner | Modo | Por qué |
|---|---|---|---|
| `~/homelab/stacks/bookstack/` | `homelab:homelab` | `750` | Repo de configuración (git). |
| `~/homelab/stacks/bookstack/.env.example` | `homelab:homelab` | `644` | Plantilla pública. |
| `~/homelab/stacks/bookstack/docker-compose.yml` | `homelab:homelab` | `644` | YAML versionado. |
| `/mnt/hd2t/services/bookstack/` | `homelab:homelab` | `750` | Bind mount root del stack. |
| `/mnt/hd2t/services/bookstack/.env` | `homelab:homelab` | `600` | Secretos (incluye `APP_KEY`, `DB_PASSWORD`). |
| `/mnt/hd2t/services/bookstack/config/` | `homelab:homelab` | `750` | Datos de la app (uploads, files, logs). |
| `/mnt/hd2t/services/bookstack/db/` | `mysql:mysql` (999:999) | `750` | Raíz de MariaDB. |
| `/mnt/hd2t/services/bookstack/db/data/` | `mysql:mysql` (999:999) | `700` | Datafiles de InnoDB (sensibles). |
| `/mnt/hd2t/services/bookstack/secrets/` | `root:homelab` | `750` | Solo `homelab` puede listar; los ficheros tienen sus propios permisos. |
| `/mnt/hd2t/services/bookstack/secrets/db_password` | `root:homelab` | `600` | Lo monta MariaDB como `/run/secrets/db_password` (read-only en el contenedor). |
| `/mnt/hd2t/services/bookstack/secrets/db_root_password` | `root:homelab` | `600` | Idem para root password. |
| `/mnt/hd2t/services/bookstack/secrets/app_key` | `root:homelab` | `600` | Custodia local del `APP_KEY` (también está en el `.env` y en Vaultwarden). |
| `/mnt/hd2t/services/bookstack/scripts/` | `homelab:homelab` | `750` | Scripts opt-in (pre-update Watchtower §12.6). |

### 3.6. Permisos para el proceso del contenedor

- `bookstack-app` corre con `PUID=1000`/`PGID=1000` (la imagen LSIO usa `s6` y el `init` hace `chown -R abc:abc` sobre `/config`). UID 1000 = `homelab` en el host: ficheros creados (uploads, logs, caches) heredan la propiedad esperada por Borg y los hooks de backup.
- `mariadb-bookstack` corre con su `mysql:mysql` (999:999), default de la imagen oficial MariaDB. Verificable con:
  ```bash
  docker run --rm mariadb:11.4 id mysql
  # uid=999(mysql) gid=999(mysql) groups=999(mysql)
  ```
  El bind mount `/mnt/hd2t/services/bookstack/db/data/` ya está chowneado a 999:999 en §3.2.

---

## 4. `docker-compose.yml`

`~/homelab/stacks/bookstack/docker-compose.yml`:

```yaml
name: bookstack

services:
  bookstack-app:
    image: ${BOOKSTACK_IMAGE}
    container_name: bookstack-app
    hostname: bookstack-app
    restart: unless-stopped
    env_file: /mnt/hd2t/services/bookstack/.env
    environment:
      # Identidad
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}

      # App
      APP_URL: ${APP_URL}
      APP_KEY: ${APP_KEY}
      APP_ENV: ${APP_ENV}
      APP_DEBUG: ${APP_DEBUG}
      APP_LOCALE: ${APP_LOCALE}
      APP_TIMEZONE: ${APP_TIMEZONE}
      ALLOW_ROBOTS: ${ALLOW_ROBOTS}
      AUTH_METHOD: ${AUTH_METHOD}
      STORAGE_TYPE: ${STORAGE_TYPE}
      MAIL_DRIVER: ${MAIL_DRIVER}

      # Conexión a la BD
      DB_HOST: ${DB_HOST}
      DB_PORT: ${DB_PORT}
      DB_DATABASE: ${DB_DATABASE}
      DB_USERNAME: ${DB_USERNAME}
      DB_PASSWORD: ${DB_PASSWORD}

      # SMTP (opcional)
      MAIL_HOST: ${MAIL_HOST}
      MAIL_PORT: ${MAIL_PORT}
      MAIL_USERNAME: ${MAIL_USERNAME}
      MAIL_PASSWORD: ${MAIL_PASSWORD}
      MAIL_ENCRYPTION: ${MAIL_ENCRYPTION}
      MAIL_FROM: ${MAIL_FROM}
    volumes:
      - type: bind
        source: /mnt/hd2t/services/bookstack/config
        target: /config
        bind:
          create_host_path: false
    networks:
      - homelab
      - bookstack_internal
    depends_on:
      mariadb:
        condition: service_healthy
    cap_drop:
      - ALL
    cap_add:
      - CHOWN              # init de LSIO hace chown -R abc:abc sobre /config
      - DAC_OVERRIDE       # Apache lee /config/nginx/site-confs como UID 0 antes del drop
      - FOWNER
      - SETGID
      - SETUID
      - NET_BIND_SERVICE   # Apache se bindea a :80 dentro del contenedor
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://127.0.0.1/login || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s
    labels:
      com.centurylinklabs.watchtower.enable: "false"
      homepage.group: "Productividad"
      homepage.name: "Bookstack"
      homepage.icon: "bookstack.png"
      homepage.href: "https://bookstack.${LAN_DOMAIN}"
      homepage.description: "Wiki interna del homelab"

  mariadb:
    image: ${MARIADB_IMAGE}
    container_name: mariadb-bookstack
    hostname: mariadb
    restart: unless-stopped

    command:
      # Ajustes recomendados para Bookstack/Laravel (UTF-8MB4, charset).
      - "--character-set-server=utf8mb4"
      - "--collation-server=utf8mb4_unicode_ci"
      - "--transaction-isolation=READ-COMMITTED"
      - "--max-connections=80"

    environment:
      TZ: ${TZ}
      MARIADB_DATABASE: ${DB_DATABASE}
      MARIADB_USER: ${DB_USERNAME}
      MARIADB_PASSWORD_FILE: /run/secrets/db_password
      MARIADB_ROOT_PASSWORD_FILE: /run/secrets/db_root_password
      MARIADB_AUTO_UPGRADE: "1"

    volumes:
      - type: bind
        source: /mnt/hd2t/services/bookstack/db/data
        target: /var/lib/mysql
        bind:
          create_host_path: false

      - type: bind
        source: /mnt/hd2t/services/bookstack/secrets/db_password
        target: /run/secrets/db_password
        read_only: true
        bind:
          create_host_path: false
      - type: bind
        source: /mnt/hd2t/services/bookstack/secrets/db_root_password
        target: /run/secrets/db_root_password
        read_only: true
        bind:
          create_host_path: false

    networks:
      - bookstack_internal

    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - DAC_OVERRIDE
      - SETGID
      - SETUID
      - NET_BIND_SERVICE
    security_opt:
      - no-new-privileges:true

    healthcheck:
      test:
        - "CMD-SHELL"
        - 'mariadb-admin ping --silent -uroot -p"$$(cat /run/secrets/db_root_password)"'
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

    labels:
      com.centurylinklabs.watchtower.enable: "false"

networks:
  homelab:
    external: true
  bookstack_internal:
    driver: bridge
    internal: false   # MariaDB no necesita salida; pero Compose-LSIO usa DNS embedded.
```

### 4.1. Por qué cada bloque

| Línea | Por qué |
|---|---|
| `name: bookstack` | `compose project name` explícito; visible en `docker compose ls`. |
| `image: ${BOOKSTACK_IMAGE}` / `image: ${MARIADB_IMAGE}` | Tags completos desde `.env`, grep-ables, diff-ables. |
| `container_name: bookstack-app` / `mariadb-bookstack` | DNS interno: Caddy llama `http://bookstack-app:80`, Borgmatic `mariadb-bookstack` ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6 línea 531). |
| `hostname: mariadb` (en el contenedor BD) | Bookstack-app conecta vía `DB_HOST=mariadb`. Dentro de la red `bookstack_internal`, `mariadb` es el alias DNS más corto y estándar (idéntico patrón que Nextcloud). |
| `restart: unless-stopped` | Auto-arranque tras reboot. `unless-stopped` (no `always`) permite parar manualmente para mantenimiento. |
| `env_file: /mnt/hd2t/services/bookstack/.env` | Path absoluto, fuera del repo. Justificado en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.1. |
| `environment:` (re-declaración explícita en `bookstack-app`) | Aunque `env_file` ya carga las vars, declararlas aquí explícitamente sirve de contrato visible en `docker compose config`. |
| `MARIADB_PASSWORD_FILE: /run/secrets/db_password` | `_FILE` indirection oficial de la imagen `mariadb`. La password no aparece en `docker inspect`. |
| `volumes:` con `bind: create_host_path: false` | Si el path host no existe, **falla** en lugar de crearlo (que podría generar un directorio root-owned y romper permisos). El path host lo crea §3.2 con la propiedad correcta. |
| `bookstack-app` en redes `homelab` + `bookstack_internal` | Caddy llega por `homelab` (`http://bookstack-app:80`). MariaDB solo es alcanzable por `bookstack_internal` desde `bookstack-app`. |
| `mariadb` solo en `bookstack_internal` | MariaDB **no** debe ser alcanzable desde `homelab`. Defensa en profundidad. |
| `depends_on: mariadb { condition: service_healthy }` | El init de LSIO hace `php artisan migrate --force` al arrancar; si MariaDB aún no está aceptando conexiones, falla. |
| `cap_drop: ALL` + `cap_add` selectivos | Privilegio mínimo. Las capabilities añadidas son las imprescindibles para que `s6-init` (LSIO) y MariaDB (chown del datadir si está vacío) hagan su trabajo y luego dropeen. |
| `no-new-privileges:true` | Impide `setuid`/`setgid` en escalada de privilegios dentro del contenedor. |
| `healthcheck: bookstack-app` con `curl /login` | `/login` siempre devuelve 200 con el formulario, incluso pre-config; es un buen liveness check. |
| `healthcheck: mariadb` con `mariadb-admin ping` y `_FILE` | Patrón del homelab (idéntico a Nextcloud). |
| `labels: watchtower.enable: "false"` (ambos contenedores) | Justificado en §0 punto 6. |
| `labels: homepage.*` (solo en `bookstack-app`) | Auto-descubrimiento en el dashboard Homepage ([`../12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md)). MariaDB no se publica en Homepage. |
| `networks.bookstack_internal: driver: bridge, internal: false` | `internal: true` cortaría la salida a internet de **todo** lo conectado a esa red. Como `bookstack-app` también está en `bookstack_internal`, eso bloquearía sus actualizaciones de scrapers/iconos. Con `internal: false`, MariaDB **no** publica al host pero sí podría salir a internet — irrelevante en la práctica porque no inicia conexiones salientes (un reverse proxy nunca llama a MariaDB, MariaDB nunca llama fuera). |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/bookstack
docker compose --env-file /mnt/hd2t/services/bookstack/.env config

# Esperado: YAML expandido, sin warnings tipo "WARNING: variable X not set",
# sin "WARNING: image with no platform" (ARM64 multi-arch).

# Verificar que las imágenes son alcanzables y multi-arch.
docker buildx imagetools inspect lscr.io/linuxserver/bookstack:24.10.4-ls289 \
  | grep -E 'linux/(arm64|amd64)'
# Esperado: ambas líneas presentes.

docker buildx imagetools inspect mariadb:11.4 \
  | grep -E 'linux/(arm64|amd64)'
# Esperado: ambas líneas presentes.
```

---

## 5. Despliegue

### 5.1. Levantar primero MariaDB sola

```bash
cd ~/homelab/stacks/bookstack
docker compose --env-file /mnt/hd2t/services/bookstack/.env up -d mariadb

# Esperar a que el primer init termine (crear la BD `bookstack`, el user,
# aplicar `mariadb-upgrade` si vino de un dump previo). Tarda ~30-60 s.
docker logs -f mariadb-bookstack
# Buscar: "ready for connections" y "mariadbd: ready for connections".
# Ctrl+C cuando aparezca.
```

Validación de la BD vacía:

```bash
docker exec mariadb-bookstack mariadb \
    -uroot -p"$(sudo cat /mnt/hd2t/services/bookstack/secrets/db_root_password)" \
    -e "SHOW DATABASES; SELECT user, host FROM mysql.user;"

# Esperado:
#   Database
#   information_schema
#   bookstack
#   mysql
#   performance_schema
#   sys
#
#   user        host
#   bookstack   %
#   mariadb.sys localhost
#   root        localhost
```

### 5.2. Levantar bookstack-app

```bash
cd ~/homelab/stacks/bookstack
docker compose --env-file /mnt/hd2t/services/bookstack/.env up -d bookstack-app

# El init de LSIO ejecuta:
#   - chown -R abc:abc /config (~10-30 s la primera vez)
#   - copia el código de la app a /app/www
#   - php artisan migrate --force  (crea ~70 tablas)
#   - php artisan cache:clear
#   - inicia Apache + PHP-FPM
docker logs -f bookstack-app
# Buscar: "[ls.io-init] done." y "AH00558: apache2: Could not reliably determine..."
# (warning irrelevante de Apache sobre ServerName; ignorar).
```

### 5.3. Estado del contenedor

```bash
docker inspect --format \
    '{{.Name}}: {{.State.Status}} — {{.State.Health.Status}}' \
    bookstack-app mariadb-bookstack

# Esperado tras ~2 min:
# /bookstack-app: running — healthy
# /mariadb-bookstack: running — healthy

# Confirmación de que Bookstack ha aplicado las migraciones:
docker exec mariadb-bookstack mariadb \
    -uroot -p"$(sudo cat /mnt/hd2t/services/bookstack/secrets/db_root_password)" \
    bookstack -e "SELECT COUNT(*) AS tablas FROM information_schema.tables \
                    WHERE table_schema='bookstack';"
# Esperado: tablas ≥ 70 (varía con la versión).

# Confirmación de que el usuario admin por defecto existe:
docker exec mariadb-bookstack mariadb \
    -uroot -p"$(sudo cat /mnt/hd2t/services/bookstack/secrets/db_root_password)" \
    bookstack -e "SELECT id, name, email FROM users;"
# Esperado: 1 fila — Admin / admin@admin.com (la cambiamos en §7.1).
```

### 5.4. Smoke check antes de publicar por Caddy

```bash
# Hablar al contenedor desde el host por la red Docker:
BOOKSTACK_IP="$(docker inspect bookstack-app \
  --format '{{range .NetworkSettings.Networks}}{{if eq .NetworkID (index $.NetworkSettings.Networks "homelab").NetworkID}}{{.IPAddress}}{{end}}{{end}}' \
  2>/dev/null)"
# Más simple, igual de válido si solo hay una IP en la red `homelab`:
BOOKSTACK_IP="$(docker inspect bookstack-app \
  --format '{{(index .NetworkSettings.Networks "homelab").IPAddress}}')"

curl -fsS -o /dev/null -w '%{http_code}\n' "http://${BOOKSTACK_IP}/login"
# Esperado: 200
```

### 5.5. Backup inicial del estado virgen

Antes de tocar la UI, capturamos un backup "estado de fábrica" útil para volver atrás si el operador quiere reiniciar la configuración manual:

```bash
# Dump de la BD virgen (con user admin por defecto + tablas vacías).
sudo install -d -m 700 -o root -g root /mnt/hd2t/backups/dumps/mariadb
docker exec mariadb-bookstack sh -c '
  mariadb-dump --single-transaction --routines --triggers --events \
    -ubookstack -p"$(cat /run/secrets/db_password)" bookstack
' | gzip -c | sudo tee /mnt/hd2t/backups/dumps/mariadb/bookstack-virgin-$(date +%F).sql.gz \
   > /dev/null
sudo chmod 600 /mnt/hd2t/backups/dumps/mariadb/bookstack-virgin-*.sql.gz
```

---

## 6. Integración con Caddy

### 6.1. Añadir el bloque `bookstack.{$LAN_DOMAIN}` al `Caddyfile`

Editar `~/homelab/stacks/proxy/Caddyfile` y añadir (después de los bloques ya existentes, antes del `# Tailscale` comentado):

```caddy
# Bookstack (../11-productividad/02-bookstack.md)
bookstack.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    import authelia_proxy
    reverse_proxy http://bookstack-app:80
}
```

| Línea | Por qué |
|---|---|
| `import lan_internal_tls` | TLS con CA interna ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §X.X). |
| `import security_headers` | HSTS + X-Frame-Options + X-Content-Type-Options + Referrer-Policy. Bookstack sirve sus propias páginas en HTML; ningún iframe externo legítimo. |
| `import authelia_proxy` | Snippet definido en [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §9.1. Aplica `forward_auth` a Authelia con `/api/authz/forward-auth`. La regla `bookstack.{$LAN_DOMAIN}` ya está en `access_control.rules` (línea 421 de Authelia) con `policy: two_factor`, `subject: group:admin`. |
| `reverse_proxy http://bookstack-app:80` | Caddy llega por la red `homelab` al contenedor `bookstack-app`. HTTP plano dentro de Docker (Caddy ya hace TLS terminator hacia el navegador). Bookstack confía en `X-Forwarded-Proto: https` que Caddy inyecta por defecto. |

### 6.2. Recargar Caddy

```bash
cd ~/homelab/stacks/proxy
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
# Esperado: "Valid configuration".

docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
# Esperado: sin output (éxito) o "successfully started".
```

Verificación en logs de Caddy:

```bash
docker logs --tail 50 caddy | grep -E 'bookstack|reload'
# Esperado: la nueva ruta aparece y un log "reloaded successfully".
```

### 6.3. Registro DNS local en Pi-hole

En la UI de Pi-hole (`https://pihole.${LAN_DOMAIN}/admin`):
- **Local DNS Records** → **Add a new domain/IP combination**.
- Domain: `bookstack.lan`
- IP: la IP del host donde escucha Caddy (`192.168.1.10` por convención del homelab; ver [`../03-red/02-pihole.md`](../03-red/02-pihole.md)).
- **Add**.

Validación:

```bash
dig +short @192.168.1.241 bookstack.lan
# Esperado: 192.168.1.10  (la IP de Caddy/Pi).
```

### 6.4. Probar el acceso desde el navegador

1. Abrir `https://bookstack.lan` en un navegador con la CA interna de Caddy ya confiada.
2. **Authelia** intercepta: muestra `https://auth.lan/?rd=https%3A%2F%2Fbookstack.lan%2F`.
3. Login con la cuenta del operador + TOTP.
4. Authelia redirige a `https://bookstack.lan/`.
5. Bookstack muestra **su propio formulario de login** (el operador acepta el doble login en esta fase; OIDC en §12.5).
6. Login con `admin@admin.com` / `password` (el default de Bookstack — se cambia inmediatamente en §7.1).

### 6.5. Acceso vía Tailscale (preparado, no activo)

Mismo patrón que el resto del homelab: cuando Tailscale esté desplegado ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) se añade un segundo bloque en el `Caddyfile`:

```caddy
# Bookstack vía Tailscale (descomentar tras 03-red/05-tailscale.md).
# bookstack.{$TS_DOMAIN} {
#     import tailscale_tls bookstack
#     import security_headers
#     import authelia_proxy
#     reverse_proxy http://bookstack-app:80
# }
```

Hasta entonces, el acceso fuera de casa pasa por Tailscale al hostname `pi.${TS_DOMAIN}` con port-forwarding HTTP **interno** a `bookstack.lan`, **no** se expone a internet.

---

## 7. Configuración post-despliegue

### 7.1. Cambiar las credenciales del admin por defecto

**Crítico**: el usuario por defecto de Bookstack es `admin@admin.com` con password `password`. Cualquier persona con acceso a la URL (incluso pasando Authelia: si el operador comparte temporalmente su cookie o si Authelia falla en `default_policy: bypass` por error) podría loguearse. Se cambia **antes** de cualquier otra acción:

1. Login en `https://bookstack.lan` con `admin@admin.com` / `password`.
2. Click en el avatar (esquina superior derecha) → **Edit Profile**.
3. **Email**: poner el del operador (`operador@example.com` o similar — solo se usa internamente para logs y como ID, no envía nada porque no hay SMTP).
4. **Display Name**: nombre real del operador.
5. **Set Password**: introducir una password fuerte (anotada en Vaultwarden con la entrada "Bookstack — admin").
6. **Save**.
7. Cerrar sesión y volver a entrar con la nueva password (validación end-to-end).

### 7.2. Configurar settings del sitio

**Settings** (icono engranaje) → **Settings**:

- **Site Name**: "Wiki — Homelab Pi5" (o el que el operador prefiera).
- **Application Logo**: opcional; si se sube, vive en `/config/www/uploads/system/`.
- **Allow public viewing**: **OFF**. Sin esto, las páginas son visibles para cualquiera que llegue a la URL **sin loguear**, contradiciendo Authelia y la postura del homelab (LAN-only).
- **Default registration role**: **Viewer**. Nadie nuevo se auto-registra (Authelia ya filtra al borde), pero si llegara a entrar alguien por error, lo más restrictivo.
- **Allow public registration**: **OFF**.

Bajar a **Customization**:
- **Application color**: gusto del operador.
- **Default Page Editor**: **WYSIWYG** o **Markdown**, lo que el operador prefiera. El homelab típico empieza con WYSIWYG (más rápido para notas operativas) y migra a Markdown cuando hay >50 páginas (mejor para diff/import/export).

### 7.3. Crear cuentas para familiares (opcional)

Si la pareja/familia debe acceder:

1. **Settings** → **Users** → **+ Add new user**.
2. Email + Display Name + Password inicial (se anota en Vaultwarden y se comparte por canal seguro).
3. Role: **Editor** (puede crear/editar páginas pero no administrar usuarios) o **Viewer**.
4. **Save**.

> El usuario **también** debe existir en Authelia (`~/homelab/stacks/auth/users_database.yml`, en su grupo `admin` para que la regla `policy: two_factor, subject: group:admin` le deje pasar). El operador edita ese fichero, hace `touch` para forzar reload (Authelia §10.4) y avisa al usuario.

### 7.4. Verificación post-despliegue

- [ ] `bookstack.lan` carga el portal de Authelia, no Bookstack directamente.
- [ ] Tras login en Authelia, Bookstack muestra **su** login (ese es el comportamiento esperado en `AUTH_METHOD=standard`; con OIDC §12.5 sería SSO transparente).
- [ ] Tras login en Bookstack con la cuenta no-default, el dashboard se muestra correctamente.
- [ ] El usuario `admin@admin.com` ya no existe (ha sido renombrado al email del operador).
- [ ] La password por defecto `password` ya no funciona (rotada).
- [ ] **Settings → Maintenance** muestra la versión esperada y la BD está en estado "Up to date".
- [ ] Subir una imagen embebida en una página de prueba funciona (validación end-to-end de `/config/www/uploads/`).
- [ ] El formulario de "Forgot Password" muestra "Email no enviado (driver: log)" o equivalente — confirma que MAIL_DRIVER=log está activo y no intenta SMTP.

---

## 8. Verificación

### 8.1. Contenedores sanos y permisos correctos

```bash
docker ps --format '{{.Names}} {{.Status}}' | grep -E 'bookstack-app|mariadb-bookstack'
# Esperado: ambos "Up X (healthy)".

ls -la /mnt/hd2t/services/bookstack/
# Esperado:
#   drwxr-x--- homelab   homelab   .          (raíz, 750)
#   -rw------- homelab   homelab   .env       (600)
#   drwxr-x--- homelab   homelab   config/
#   drwxr-x--- 999       999       db/        (mysql:mysql, 750)
#   drwxr-x--- root      homelab   secrets/   (750)
#   drwxr-x--- homelab   homelab   scripts/

stat -c '%a %U:%G' /mnt/hd2t/services/bookstack/secrets/db_password \
                   /mnt/hd2t/services/bookstack/secrets/db_root_password \
                   /mnt/hd2t/services/bookstack/secrets/app_key
# Esperado en cada uno: 600 root:homelab.
```

### 8.2. Bookstack no escucha al host

```bash
sudo ss -tlnp | grep -E ':80|:3306|:443'
# Esperado: solo lo que ya escuchaba antes (Caddy en 80/443; nada en 3306).
# Bookstack-app y mariadb NO deben aparecer.
```

### 8.3. UI accesible vía Caddy

```bash
curl -fsS -o /dev/null -w 'HTTP %{http_code}\n' \
    -H "Host: bookstack.lan" \
    --cacert <(docker exec caddy cat /data/caddy/pki/authorities/local/root.crt) \
    https://192.168.1.10/login
# Esperado: HTTP 401 (Authelia interceptó la petición sin cookie de sesión).
#           Si devuelve 200, Authelia NO está delante: revisar el Caddyfile.
```

### 8.4. Persistencia tras reboot

```bash
sudo reboot
# Esperar ~2 min.

ssh homelab@pi
docker ps --format '{{.Names}} {{.Status}}' | grep bookstack
# Esperado: bookstack-app y mariadb-bookstack en "Up X (healthy)".

curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1/login \
    --resolve bookstack.lan:443:192.168.1.10 \
    --cacert <(docker exec caddy cat /data/caddy/pki/authorities/local/root.crt) \
    https://bookstack.lan/login
# Esperado: 401 (Authelia hace su trabajo).
```

### 8.5. Backup hooks Borgmatic ejecutándose

```bash
# Forzar un dump manual para validar el hook mariadb_databases:
sudo borgmatic --dry-run --verbosity 1 borgmatic 2>&1 | grep -i 'bookstack'
# Esperado: línea "Would dump MariaDB database bookstack".

# Ejecutar el hook real (sin snapshot Borg, solo el dump):
sudo borgmatic create --files-cache disabled \
    --before-backup-hook 'echo "test"' \
    --skip-actions create check 2>/dev/null

# Verificar que el dump existe:
ls -la /mnt/hd2t/backups/dumps/mariadb/bookstack-*.sql.gz
# Esperado: al menos un fichero reciente (≤ 1 día).
```

### 8.6. Lista de verificación

- [ ] Ambos contenedores (`bookstack-app`, `mariadb-bookstack`) en `Up (healthy)`.
- [ ] `https://bookstack.lan` redirige a `https://auth.lan` sin cookie de sesión.
- [ ] Tras login en Authelia + Bookstack, el dashboard carga y se puede crear una estantería de prueba.
- [ ] Subir una imagen embebida funciona (escribe en `/mnt/hd2t/services/bookstack/config/www/uploads/`).
- [ ] El usuario `admin@admin.com` ha sido renombrado/blindado.
- [ ] `MARIADB_ROOT_PASSWORD` y `MARIADB_PASSWORD` están en Vaultwarden con etiquetas claras.
- [ ] `APP_KEY` está en Vaultwarden con etiqueta clara y en `secrets/app_key` con `chmod 600`.
- [ ] `~/homelab/stacks/bookstack/{docker-compose.yml,.env.example}` versionados en git; **`.env` y `secrets/*` NO**.
- [ ] El bloque `bookstack.{$LAN_DOMAIN}` está en `~/homelab/stacks/proxy/Caddyfile`.
- [ ] Pi-hole tiene el registro local `bookstack.lan → 192.168.1.10`.
- [ ] Borgmatic genera el dump nocturno en `/mnt/hd2t/backups/dumps/mariadb/bookstack-*.sql.gz`.
- [ ] La label `homepage.*` la lee Homepage (cuando se despliegue).

---

## 9. Backup

### 9.1. Qué se respalda y qué no

| Path | Cómo se respalda | Tamaño típico |
|---|---|---|
| `/mnt/hd2t/services/bookstack/db/data/` | **No** directamente. Borg lo excluye explícitamente — un snapshot de un datadir InnoDB en uso es inconsistente. La fuente de verdad es el dump. | ~50–500 MB |
| Dump de la BD `bookstack` | Hook `mariadb_databases` de Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6 líneas 528–534) genera `/mnt/hd2t/backups/dumps/mariadb/bookstack-<fecha>.sql.gz` antes de cada snapshot Borg. | 1–20 MB comprimido |
| `/mnt/hd2t/services/bookstack/config/` | Bind mount completo dentro del snapshot Borg. Cubre `www/uploads/`, `www/files/`, `nginx/site-confs/`, `keys/`, logs. | 0.1–10 GB según uploads |
| `/mnt/hd2t/services/bookstack/.env` | Snapshot Borg directamente. **Contiene `APP_KEY` y `DB_PASSWORD`** — el repo Borg está cifrado con passphrase fuerte. | <1 KB |
| `/mnt/hd2t/services/bookstack/secrets/{db_password,db_root_password,app_key}` | Snapshot Borg directamente. **Críticos** — sin `app_key` los adjuntos cifrados no se descifran tras restore. | <1 KB cada uno |
| `~/homelab/stacks/bookstack/{docker-compose.yml,.env.example}` | Snapshot Borg de `~/homelab/` + git remote (espejo). | <10 KB |

> **Nada se excluye de cache/regenerable** porque Bookstack apenas tiene caches: Laravel cachea config en `/config/www/storage/framework/cache/` (~MB, regenerable, pero pesa poco — incluirlo es más sencillo que excluirlo selectivamente).

### 9.2. Patrón Borgmatic — respaldo MariaDB

Ya está declarado en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6 (sin que este doc tenga que añadir nada):

```yaml
mariadb_databases:
  - name: bookstack
    hostname: mariadb-bookstack
    port: 3306
    username: bookstack
    password: '{credential file /mnt/hd2t/services/bookstack/secrets/db_password}'
    options: --single-transaction --routines --triggers --events
```

| Línea | Qué hace |
|---|---|
| `hostname: mariadb-bookstack` | Borgmatic se conecta al contenedor por su `container_name` (resolvible vía Docker DNS desde el contenedor `borgmatic` que vive en la red `homelab` con `bookstack_internal` como `external` adicional cuando aplique; ver [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §3.4). |
| `password: '{credential file ...}'` | Lee la password directamente del fichero de secretos del stack. Si rota, Borgmatic la lee actualizada sin tocar `borgmatic.yml`. |
| `options: --single-transaction --routines --triggers --events` | Justificado en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §2.2. |

### 9.3. Restore (resumen)

Procedimiento detallado en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §4.4. Pasos críticos en orden:

1. Archivar el directorio actual: `sudo mv /mnt/hd2t/services/bookstack /mnt/hd2t/services/bookstack.broken-$(date +%F)`.
2. `borgmatic extract --archive <ARCH> --path 'mnt/hd2t/services/bookstack' --destination /`.
3. **Vaciar `db/data/` y reinstalarlo vacío con UID 999:999** (la BD se reconstruye desde el dump).
4. Levantar **solo MariaDB**: `docker compose up -d mariadb`.
5. Esperar a `healthy`, cargar el dump: `zcat <dump>.sql.gz | docker exec -i mariadb-bookstack mariadb -uroot -p"$(...)" bookstack`.
6. Levantar `bookstack-app`. Validar que el `APP_KEY` extraído del backup coincide con el del `.env` extraído (**debe** coincidir; si no, los adjuntos cifrados son ilegibles).
7. Smoke test: login con la cuenta del operador, abrir una página con imagen embebida, descargar un adjunto cifrado.

> **Si el `APP_KEY` se ha perdido y no está en Vaultwarden ni en el backup**: las páginas de texto (que **no** están cifradas, viven en columnas TEXT de la BD) sobreviven al restore. Solo se pierden los **adjuntos cifrados** (`local_secure`). Variante de almacenamiento sin cifrado en §12.7.

### 9.4. Smoke test mensual

Calendario rotatorio del homelab ([`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §6.2): **Bookstack en meses 3, 7, 11**. Cada test se anota en `~/homelab/operations/restore-tests.log` con el commit `ops: smoke test bookstack <YYYY-MM>`.

---

## 10. Operaciones cotidianas

### 10.1. Upgrade manual (Watchtower deshabilitado)

```bash
# 1. Leer release notes:
#    https://github.com/BookStackApp/BookStack/releases
#    https://github.com/linuxserver/docker-bookstack/releases

# 2. Dump explícito previo (NO el del cron de Borgmatic; uno reciente):
docker exec mariadb-bookstack sh -c '
  mariadb-dump --single-transaction --routines --triggers --events \
    -ubookstack -p"$(cat /run/secrets/db_password)" bookstack
' | gzip -c | sudo tee /mnt/hd2t/backups/dumps/mariadb/bookstack-pre-upgrade-$(date +%FT%H%M).sql.gz \
   > /dev/null
sudo chmod 600 /mnt/hd2t/backups/dumps/mariadb/bookstack-pre-upgrade-*.sql.gz

# 3. Pinear nuevo tag en .env.example y .env:
$EDITOR ~/homelab/stacks/bookstack/.env.example
sudo $EDITOR /mnt/hd2t/services/bookstack/.env
# Cambiar BOOKSTACK_IMAGE=lscr.io/linuxserver/bookstack:<nuevo>-ls<N>

# 4. Pull + recreate (LSIO ejecuta `php artisan migrate --force` al arrancar):
cd ~/homelab/stacks/bookstack
docker compose --env-file /mnt/hd2t/services/bookstack/.env pull bookstack-app
docker compose --env-file /mnt/hd2t/services/bookstack/.env up -d bookstack-app

# 5. Validar:
docker logs --tail 100 bookstack-app | grep -E 'migrat|done\.|error'
# Esperado: "Migrating: ..." (varias líneas), "[ls.io-init] done.", sin error.

# 6. Smoke test en navegador.

# 7. Commit:
cd ~/homelab
git add stacks/bookstack/.env.example
git commit -m "ops(bookstack): upgrade to <version>"
```

> **Si el upgrade falla**: `docker compose down bookstack-app && docker compose up -d bookstack-app` con la imagen vieja (`docker image ls` para confirmar el digest anterior). Si la BD se ha migrado parcialmente, restaurar desde el dump pre-upgrade (§10.1 paso 2).

### 10.2. Añadir un usuario nuevo

Ya cubierto en §7.3. Variante CLI (sin pasar por la UI), útil cuando el operador quiere crear el primer admin de un restore:

```bash
docker exec -it bookstack-app php /app/www/artisan bookstack:create-admin \
    --email "operador@example.com" \
    --name "Operador" \
    --password "PASSWORD-FUERTE"
```

### 10.3. Reset de password (sin SMTP)

```bash
docker exec -it bookstack-app php /app/www/artisan bookstack:reset-password \
    --email "operador@example.com"
# Pide la nueva password por stdin y la setea.
```

### 10.4. Importar contenido (Markdown/HTML/Word)

Bookstack soporta importar páginas individuales desde la UI (**Edit Page** → **Import**). Para importes masivos (cientos de páginas desde otra wiki):

1. Exportar la wiki origen a Markdown plano (un fichero `.md` por página).
2. Crear las estanterías/libros de destino vacíos en la UI.
3. Bash loop para crear páginas por API (Bookstack expone `POST /api/pages` con el cuerpo Markdown):
   ```bash
   TOKEN_ID="..."         # creado en Settings → Users → <user> → API Tokens
   TOKEN_SECRET="..."
   AUTH="Authorization: Token ${TOKEN_ID}:${TOKEN_SECRET}"

   curl -fsS -H "$AUTH" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg book_id "$BOOK_ID" --arg name "$NAME" --rawfile md "page.md" \
              '{book_id: ($book_id|tonumber), name: $name, markdown: $md}')" \
        https://bookstack.lan/api/pages
   ```
4. La API respeta los permisos del token (no salta autorización Bookstack), pero Authelia delante exige tener cookie de sesión Authelia → más práctico saltarse Authelia para esto **temporalmente** levantando un túnel SSH al puerto 80 del contenedor:
   ```bash
   ssh -L 8080:bookstack-app:80 homelab@pi
   # En el host local:
   curl -H "$AUTH" -H "Content-Type: application/json" ... http://localhost:8080/api/pages
   ```

### 10.5. Logs y observabilidad

| Log | Path | Cómo leerlo |
|---|---|---|
| Apache (HTTP, errores) | `/mnt/hd2t/services/bookstack/config/log/nginx/` (LSIO usa nginx en algunas versiones; comprobar) o `docker logs bookstack-app` | `docker logs --tail 200 bookstack-app` |
| Laravel app | `/mnt/hd2t/services/bookstack/config/log/laravel.log` (rotación interna) | `sudo tail -F /mnt/hd2t/services/bookstack/config/log/laravel.log` |
| MariaDB | `docker logs mariadb-bookstack` | Idem. |
| Auditoría de Bookstack | `Settings → Audit Log` (UI) | Acciones de usuarios: páginas creadas/borradas, cambios de roles, etc. **Persistente en BD**, va en el dump nocturno. |

Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)) muestra ambos contenedores en tiempo real desde su UI.

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Remedio |
|---|---|---|
| `bookstack-app` arranca, hace `migrate` y se queda en bucle de restart | `DB_PASSWORD` en el `.env` no coincide con la del `secrets/db_password` que carga MariaDB. | Verificar: `grep ^DB_PASSWORD= /mnt/hd2t/services/bookstack/.env` y `sudo cat /mnt/hd2t/services/bookstack/secrets/db_password` deben dar el **mismo** valor. Reescribir uno de los dos. |
| `mariadb-bookstack` no arranca: "Failed to access directory for --datadir" | Permisos del bind mount. | `sudo chown -R 999:999 /mnt/hd2t/services/bookstack/db && sudo chmod 700 /mnt/hd2t/services/bookstack/db/data`. |
| `bookstack-app` arranca pero la UI muestra "500 Server Error" | `APP_KEY` mal formada o vacía. | `sudo cat /mnt/hd2t/services/bookstack/secrets/app_key` debe empezar por `base64:` y tener 44 chars. Si vacía, regenerar (§3.3) y **antes** de relanzar, hacer un dump y vaciar la BD (los adjuntos cifrados con la APP_KEY anterior se pierden — irrecuperables sin la clave original). |
| Login en Authelia OK, pero Bookstack muestra "Whoops, looks like something went wrong." | `APP_DEBUG=true` está activo y la traza se esconde. | `grep ^APP_DEBUG /mnt/hd2t/services/bookstack/.env` debe decir `false`. Para diagnosticar puntualmente, conmutar a `true`, recargar (`docker compose up -d bookstack-app`), reproducir, **volver a `false` inmediatamente**. |
| "419 Page Expired" en formularios | Token CSRF de Laravel inválido. Causa típica: cookies bloqueadas por discordancia entre `APP_URL` y la URL real. | `grep ^APP_URL /mnt/hd2t/services/bookstack/.env` debe ser **exactamente** `https://bookstack.lan` (o el host real del Caddyfile). Sin trailing slash. |
| Imágenes embebidas en páginas dan 404 | `STORAGE_TYPE` cambió o el directorio `/config/www/uploads/` se borró. | Restaurar `uploads/` desde Borg. Si solo cambió el `STORAGE_TYPE`, volver a `local_secure` y reiniciar. |
| Authelia se queja de "Forwarded Authentication failed" tras añadir el bloque Caddy | El snippet `authelia_proxy` no está en `~/homelab/stacks/proxy/snippets/`. | Verificar `ls -la ~/homelab/stacks/proxy/snippets/authelia_proxy`; si no existe, copiarlo desde `~/homelab/stacks/auth/snippets-caddy/authelia_proxy` ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §9.1). |
| Caddy reload tras añadir el bloque falla con "ambiguous site" | Otro bloque del Caddyfile usa `bookstack.{$LAN_DOMAIN}` (duplicado tras un git merge). | Buscar duplicados: `grep -n bookstack ~/homelab/stacks/proxy/Caddyfile`. Mantener uno solo. |
| Tras recrear contenedores, Bookstack pide volver a hacer setup | El bind mount `/config` se desmontó/borró/recreó vacío. | `ls /mnt/hd2t/services/bookstack/config/www/.env` debe existir. Si está vacío, restaurar desde Borg. |
| `php artisan migrate --force` falla con "Specified key was too long" | Versión antigua de MariaDB (<10.6) sin `innodb_default_row_format=DYNAMIC`. | El homelab usa MariaDB 11.4: este error no aplica. Si por algún motivo el operador conmuta a MariaDB <10.6 (no se recomienda), añadir `--innodb-default-row-format=DYNAMIC` al `command:` del servicio MariaDB. |
| Las exportaciones a PDF salen sin imágenes | El servicio `wkhtmltopdf` interno de Bookstack no encuentra `APP_URL`. | Verificar `APP_URL` (tiene que coincidir con la URL pública). Adicionalmente, en `Settings → Customization → Allowed iframe hosts` añadir `bookstack.lan` (tiene que ser igual al `APP_URL`). |
| `mariadb-bookstack` reinicia tras consumir RAM | `--max-connections=80` + workload pesado. | Subir a `--max-connections=120`. No suele aplicar a un homelab de <10 usuarios. |

---

## 12. Variantes opt-in

### 12.1. SMTP para emails (invitaciones, reset password)

El homelab por defecto no tiene MTA. Si el operador conmuta a SMTP relay externo (Mailgun, Postmark, AWS SES, o un servidor SMTP propio en otro host):

```env
# /mnt/hd2t/services/bookstack/.env (añadir / cambiar)
MAIL_DRIVER=smtp
MAIL_HOST=smtp.mailgun.org
MAIL_PORT=587
MAIL_USERNAME=postmaster@mg.example.com
MAIL_PASSWORD=<password>
MAIL_ENCRYPTION=tls
MAIL_FROM=bookstack@example.com
```

`docker compose up -d bookstack-app` para recargar. Validación: **Settings → Maintenance → Send test email**.

### 12.2. Autenticación local pura (sin Authelia delante)

Si el operador quiere quitar Authelia del borde de Bookstack temporalmente (por ejemplo, para que un cliente API legacy hable directamente):

En `~/homelab/stacks/proxy/Caddyfile`, **comentar** la línea `import authelia_proxy` del bloque `bookstack.{$LAN_DOMAIN}` y recargar Caddy. Bookstack queda accesible solo con su login interno.

> **Coste de seguridad**: el modo "Authelia-only" obligaba a 2FA TOTP para llegar al login de Bookstack. Sin Authelia, cualquier persona con acceso a la LAN puede intentar fuerza bruta contra el login de Bookstack. La mitigación es **el regulator interno de Bookstack** (5 intentos / 15 min) y, ya activo, **el rate-limit de Caddy** si se configura. **No** se recomienda como modo permanente.

### 12.3. Imagen upstream `bookstackapp/bookstack`

La imagen oficial upstream entrega solo PHP-FPM. Hay que añadir nginx como sidecar y un volume compartido:

```yaml
services:
  bookstack-app:
    image: bookstackapp/bookstack:24.10.4
    # ... resto similar, sin `:80`. Expone `:9000` (PHP-FPM).
  bookstack-web:
    image: nginx:1.27-alpine
    # ... bind mount del volume con el código + un nginx.conf custom.
```

**Tradeoff**: más control sobre el webserver (TLS, headers, plugins nginx) a cambio de más complejidad. La mayoría de homelabbers se quedan en LSIO.

### 12.4. SQLite en lugar de MariaDB

Para 1 usuario y <100 páginas, SQLite es viable. Borrar el servicio `mariadb` del compose y poner en el `.env`:

```env
DB_HOST=
DB_PORT=
DB_DATABASE=/config/www/database.sqlite
DB_USERNAME=
DB_PASSWORD=
DB_CONNECTION=sqlite
```

**Tradeoffs**: el dump pasa de `mariadb-dump` a `sqlite3 .backup` ([`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §2.3); la búsqueda full-text de Bookstack se hace más lenta (sin `FULLTEXT INDEX` de MariaDB); **NO se recomienda** si el operador planea crecer a >2 usuarios.

### 12.5. SSO con Authelia OIDC

Cuando Authelia tenga el endpoint `oidc` activado (variante futura del doc Authelia §12.X):

```env
# /mnt/hd2t/services/bookstack/.env
AUTH_METHOD=oidc
OIDC_NAME=Authelia
OIDC_DISPLAY_NAME_CLAIMS=name
OIDC_CLIENT_ID=bookstack
OIDC_CLIENT_SECRET=<secret cogenerado en Authelia>
OIDC_ISSUER=https://auth.lan
OIDC_ISSUER_DISCOVER=true
OIDC_AUTH_ENDPOINT=https://auth.lan/api/oidc/authorization
OIDC_TOKEN_ENDPOINT=https://auth.lan/api/oidc/token
OIDC_USER_TO_GROUPS=true
OIDC_GROUPS_CLAIM=groups
```

El operador deja de hacer doble login: Authelia loguea en el borde y el OIDC hace SSO transparente al pasar al backend. La regla `forward_auth` se relaja a `policy: bypass` en Authelia para `bookstack.lan` (la auth la asume Bookstack vía OIDC, no la cookie de Authelia).

### 12.6. Watchtower con `pre-update` hook (NO recomendado)

Si el operador quiere automatizar el upgrade (a sabiendas de que las migraciones Laravel pueden fallar a las 04:00 sin nadie mirando), crear `/mnt/hd2t/services/bookstack/scripts/pre-update.sh`:

```bash
#!/bin/sh
set -eu
DEST="/data/backups/pre-update-bookstack-$(date +%FT%H%M).sql.gz"
mkdir -p /data/backups && chmod 700 /data/backups
mariadb-dump --single-transaction --routines --triggers --events \
  -h mariadb-bookstack -ubookstack -p"$(cat /run/secrets/db_password)" bookstack \
  | gzip -c > "$DEST"
chmod 600 "$DEST"
[ -s "$DEST" ] || exit 1
```

Y añadir al `docker-compose.yml` del servicio `bookstack-app`:

```yaml
labels:
  com.centurylinklabs.watchtower.enable: "true"
  com.centurylinklabs.watchtower.lifecycle.pre-update: "/scripts/pre-update.sh"
  com.centurylinklabs.watchtower.lifecycle.pre-update-timeout: "300"
```

Más bind mounts (`/scripts`, `/data/backups`, `/run/secrets/db_password`). Detalles en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §5.4.

> **No es la postura del homelab** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.1, línea 457). Documentado solo por completitud, para el operador que prefiera asumir el riesgo.

### 12.7. Almacenamiento S3-compatible (MinIO)

Para mover los uploads/files a MinIO ([`../06-almacenamiento/04-minio.md`](../06-almacenamiento/04-minio.md)):

```env
STORAGE_TYPE=s3
STORAGE_S3_KEY=<minio access key>
STORAGE_S3_SECRET=<minio secret>
STORAGE_S3_REGION=us-east-1
STORAGE_S3_BUCKET=bookstack
STORAGE_S3_ENDPOINT=http://minio:9000
STORAGE_URL=https://minio.lan/bookstack
```

**Tradeoff**: los adjuntos se centralizan en MinIO (escalable, replicable a B2 vía `mc mirror`). Pero dejan de cifrarse con `APP_KEY` (S3 se encarga del cifrado en tránsito y reposo, si MinIO está configurado para ello). El backup pasa a involucrar MinIO también.

---

## 13. Referencias

- [Bookstack — documentación oficial](https://www.bookstackapp.com/docs/)
- [Bookstack — variables de entorno](https://www.bookstackapp.com/docs/admin/configuration/)
- [Bookstack — release notes / changelog](https://github.com/BookStackApp/BookStack/releases)
- [LinuxServer.io — imagen `bookstack`](https://docs.linuxserver.io/images/docker-bookstack/)
- [LinuxServer.io — release notes de la imagen](https://github.com/linuxserver/docker-bookstack/releases)
- [MariaDB 11.4 LTS](https://mariadb.com/kb/en/mariadb-11-4-lts/)
- [Imagen oficial `mariadb` en Docker Hub](https://hub.docker.com/_/mariadb)
- [Laravel — gestión de `APP_KEY`](https://laravel.com/docs/11.x/encryption#configuration)
- [Authelia — `forward_auth` con Caddy](https://www.authelia.com/integration/proxies/caddy/)
- [Authelia — OIDC provider](https://www.authelia.com/configuration/identity-providers/openid-connect/) (preparado para variante §12.5)
