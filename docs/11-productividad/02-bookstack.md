# Bookstack (wiki interna del homelab, en MariaDB)

## Descripción

Despliegue de **Bookstack** como **wiki / base de conocimiento** del homelab y de la "vida digital" del operador: editor WYSIWYG (alternativamente Markdown puro), organización en **estanterías → libros → capítulos → páginas**, búsqueda full-text, _attachments_, control de versiones de cada página, exportación a PDF/HTML/Markdown, y multi-usuario con roles. Este Bookstack se convierte en **el sitio canónico donde versionar la documentación operativa del propio homelab** (runbooks, _disaster recovery_, contraseñas no-secret tipo "qué bombilla Zigbee es la del salón", apuntes de troubleshooting que no caben en un commit message), complementando — no sustituyendo — el repo Markdown en git que el operador mantiene en `~/workspace/homelab/docs/` para la documentación canónica de despliegue.

Este documento **continúa el _stack_ `productividad`** (`~/homelab/productividad/`) que estrenó `docs/11-productividad/01-vaultwarden.md`. Mientras Vaultwarden no necesitaba BD aparte (vive sobre SQLite local), Bookstack **sí** la necesita y obliga a:

- Crear la red Docker privada **`productividad-internal`** (que Vaultwarden no introdujo, ver `docs/11-productividad/01-vaultwarden.md` → _Notas de diseño_) para aislar la MariaDB del resto del _stack_ y de los demás _stacks_ del homelab.
- Añadir dos servicios al mismo `docker-compose.yml`:
  - **`bookstack`** — la propia aplicación (PHP-FPM + Apache + Laravel; imagen oficial-comunitaria `lscr.io/linuxserver/bookstack`).
  - **`bookstack-db`** — base de datos **MariaDB 11.4 LTS** dedicada (no se reutiliza la `nextcloud-db` del _stack_ `almacen`; razones en **Decisiones de diseño**).

Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone Bookstack en `https://bookstack.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), `https://pi.<tailnet>.ts.net/` con MagicDNS sirve la misma wiki cuando se está fuera de la LAN.

> **Alcance**: este documento despliega Bookstack con su autenticación nativa (email + password, opcional 2FA TOTP via la app `MFA` de Bookstack), crea **el usuario operador** (sustituye al `admin@admin.com` por defecto), **cierra el registro abierto** (desactiva `Allow public registration` desde la primera carga), genera y persiste el **`APP_KEY`** explícitamente (no se delega a la primera arrancada para que el backup sea reproducible), **descomenta el bloque del _hook_ de Borgmatic** que dejó preparado `docs/07-backups/02-borgmatic.md` con `dump_mariadb bookstack bookstack-db …`. **No** delega autenticación a Authelia vía `forward_auth` (mismo razonamiento que Nextcloud y Vaultwarden — los _tokens_ de la API REST de Bookstack y los _webhooks_ rompen con un redirect HTML; ver **Decisiones de diseño**). **No** despliega el visor LDAP/SAML/SSO. **No** activa Cloudflare R2/S3 para los uploads (todo vive en `/mnt/hd2t/services/bookstack/`). **No** configura SMTP en este documento (queda como **opcional** descrito al final, requiere un MTA o cuenta SMTP externa).

> **Recordatorio de red**: Bookstack (la app) **no se publica al host**. Caddy la alcanza por DNS interno de Docker (`bookstack:80` en la red `homelab`). MariaDB vive en `productividad-internal` y **no** está enganchada a `homelab`: no es accesible desde Caddy, ni desde Authelia, ni desde otros _stacks_. Pi-hole resuelve `bookstack.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`).

---

## Requisitos previos

- `docs/02-docker/02-estructura-compose.md` completado: la tabla de stacks reserva el _slot_ `productividad`, la red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) externa está creada, `~/homelab/.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `HOMELAB_DOMAIN=lan` está rellenado, y el _Makefile_ de operación expone `make up STACK=<stack>`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/bookstack/` ya existe vacío. En este documento se crean además `/mnt/hd2t/services/bookstack/{config,db}/`.
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada. Bookstack y MariaDB serán **opt-out** explícito (ver **Decisiones de diseño**).
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `bookstack.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, y la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile`. La CA local ya firma `*.lan`.
- `docs/07-backups/02-borgmatic.md` completado: Borgmatic ya está corriendo con su _hook_ `before_backup` y el helper `dump_mariadb` de `docs/07-backups/03-backup-docker-volumes.md` ya está cargado en `~/homelab/backups/borgmatic/hooks/dump-databases.sh`. El bloque comentado `# dump_mariadb bookstack bookstack-db "$HOMELAB/productividad/.env" bookstack` se descomentará en este documento.
- `docs/11-productividad/01-vaultwarden.md` completado: el _stack_ `productividad` ya existe con `~/homelab/productividad/{docker-compose.yml,.env,.env.example,.gitignore}`. **Este documento amplía** esos ficheros — no los crea desde cero. Tener el primer despliegue en marcha también significa que el operador **ya tiene una bóveda Vaultwarden viva** donde guardar las passwords de la BD que se generan abajo.
- Conectividad saliente para descargar las imágenes (sólo la primera vez):
  ```bash
  docker pull --platform linux/arm64 lscr.io/linuxserver/bookstack:25.10 >/dev/null && \
  docker pull --platform linux/arm64 mariadb:11.4-noble                  >/dev/null && \
  echo OK
  ```
- Que el host **no** tenga ya un servicio escuchando en `:3306` por error (`docker ps --format '{{.Names}} {{.Ports}}' | grep ':3306->' || echo OK`). Este _stack_ no publica puertos al host; Caddy es quien recibe el tráfico HTTPS, y la BD vive sólo en `productividad-internal`.
- Espacio en `/mnt/hd2t`: Bookstack es **ligero**. La aplicación idle ocupa ~250 MB, la BD InnoDB recién instalada ~80 MB, y los uploads del operador raramente superan unos pocos GB en uso normal (capturas de pantalla, PDFs adjuntos a runbooks). Verificar holgura mínima:
  ```bash
  df -h /mnt/hd2t
  # Debe quedar holgado tras el arranque (~500 MB iniciales).
  ```

---

## Decisiones de diseño

### Por qué Bookstack (y no DokuWiki / Wiki.js / Outline / Trilium / Obsidian)

El homelab necesita **una wiki interna** que cumpla a la vez: editor WYSIWYG **y** Markdown (el operador alterna entre ambos), jerarquía clara **multinivel** (estanterías → libros → capítulos → páginas — más rica que el árbol plano de muchas wikis), búsqueda full-text que escale a cientos de páginas, _attachments_ con permisos por libro, control de versiones por página, y _self-hosting_ ARM64 maduro. Cinco candidatos descartados y por qué:

| Candidato      | Por qué se descarta                                                                                                                                              |
|----------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **DokuWiki**   | Sin BD (ficheros de texto), muy estable, pero la UI es de los años 2000 y la edición WYSIWYG sólo existe vía plugins de calidad variable. La búsqueda full-text es _grep_-style: lenta a partir de unos cientos de páginas. **Inadecuado** para una wiki de homelab que crecerá. |
| **Wiki.js**    | Stack Node.js + PostgreSQL, multi-tenant, muy potente. Pero su **plugin model** y la transición a v3 han dejado plugins clave (LDAP, S3, Git sync) en limbo durante meses. _Self-hosting_ con incertidumbre evolutiva.     |
| **Outline**    | Notion-like, excelente UX. Pero requiere **Redis + Postgres + S3-compatible storage** obligatoriamente (no admite filesystem-only): añade ~3 contenedores y una dependencia de almacenamiento de objetos (MinIO) sólo para una wiki personal. _Overkill_.                          |
| **Trilium**    | Excelente para **notas personales** (estilo "PKM con árboles infinitos"), pero no está pensada para **multi-usuario con permisos por libro**: si en el futuro la pareja del operador quiere editar la receta familiar y el operador quiere mantener el runbook de Borgmatic privado, Trilium fuerza dos instancias separadas. |
| **Obsidian + sync por Nextcloud** | Cero servidor. Pero los _clients_ móvil necesitan Obsidian Mobile (de pago anual o setup manual del vault), no hay UI web (y por tanto no hay acceso desde un navegador prestado), y la búsqueda multi-vault no existe. **Modelo de uso individual**, no de wiki compartida.     |

Bookstack gana por:

- **Editor _both_** — WYSIWYG (TinyMCE) y Markdown (CodeMirror) por página, intercambiables. El operador puede empezar una página en Markdown y alternar al WYSIWYG cuando quiere pegar una imagen.
- **Jerarquía de tres niveles** (Shelves → Books → Chapters → Pages) que mapea naturalmente a la estructura del homelab: estantería "Operaciones", libros "Backups", "Networking", "Disaster Recovery", capítulos "Borgmatic", "Restauración Postgres", páginas individuales.
- **Búsqueda full-text en MariaDB** con índices `FULLTEXT` nativos: rápida hasta decenas de miles de páginas, con _ranking_ y _highlighting_.
- **API REST estable** documentada, lo que permite scripts `curl`/`bw`-style para volcar runbooks generados por agentes en la wiki sin abrir el navegador.
- **Soporte ARM64 oficial-comunitario** vía `lscr.io/linuxserver/bookstack`, multi-arch, mantenido por LinuxServer.io con _release_ por versión upstream y un patrón de `PUID`/`PGID` ya común con varios servicios del _stack_ `multimedia`.
- **Migración gradual**: si en el futuro el operador quiere mover toda la wiki a una de las alternativas, Bookstack exporta cada libro en HTML, PDF y Markdown (este último importable directamente por DokuWiki o Wiki.js). **Sin lock-in**.

### Imagen y _tag_

- **`lscr.io/linuxserver/bookstack:25.10`** — Bookstack 25.10 empaquetada por LinuxServer.io, multi-arch (`linux/arm64`). Pinneada a _tag_ "year.month" siguiendo la convención del homelab (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`, "Tag mayor o LTS"). Bookstack publica versiones cada uno o dos meses; la imagen LS añade su propio sufijo `-ls<rev>` para sus rebuilds, pero el _tag_ "year.month" desnudo es el alias estable que LS mantiene mientras hay parches en esa versión.
- **`mariadb:11.4-noble`** — MariaDB 11.4 LTS (mantenida hasta mayo 2029), multi-arch ARM64, sobre Ubuntu 24.04 (`noble`). **Misma imagen que `nextcloud-db`** del _stack_ `almacen` (ver `docs/06-almacenamiento/01-nextcloud.md`): un solo `mariadb:11.4-noble` en disco, dos contenedores distintos lo usan; ahorro de 200 MB de _layers_ en `/mnt/hd2t/system/docker/`.
- **No** se usa `lscr.io/linuxserver/mariadb` (la imagen LS de MariaDB) por dos razones: (a) la imagen oficial `mariadb:11.4-noble` ya está en uso por Nextcloud y queremos minimizar el catálogo de imágenes; (b) la imagen LS de MariaDB usa un esquema de inicialización ligeramente distinto (variables `MYSQL_*` con prefijos LS) que rompería la consistencia de los _hooks_ de Borgmatic.

#### Watchtower opt-out en ambos contenedores

Razones por contenedor:

- **`bookstack`**: las actualizaciones **mayores** (24.x → 25.x) ejecutan migraciones de _schema_ Laravel en la primera arrancada (`php artisan migrate`) y, en algunos saltos (notablemente 23.10 → 24.02), se requiere una migración **lenta** que reescribe tablas (`pages`, `revisions`) y pueden tardar **minutos** en una BD grande. Un `pull` automático de un _tag_ `:25.10` a `:25.12` deja la BD parcialmente migrada si el contenedor reinicia a mitad de la `migrate`. Las _major upgrades_ se hacen a mano, leyendo el _changelog_ y haciendo backup completo previo.
- **`bookstack-db`** (MariaDB): mismo razonamiento que en `nextcloud-db` (`docs/06-almacenamiento/01-nextcloud.md` → _Watchtower opt-out_). Un _bump_ de _major_ (10.x → 11.x) puede cambiar formato de InnoDB; un _downgrade_ no es trivial. **Manual** y con _dump_ previo.

Etiquetar ambos con `com.centurylinklabs.watchtower.enable: "false"`.

> **Coherencia con `docs/02-docker/04-watchtower.md`**: ese documento ya lista a "Bookstack" y "MariaDB" en la lista explícita de servicios **opt-out** desde el principio. No hace falta justificar nada extra aquí; sólo aplicar la etiqueta.

### MariaDB en lugar de PostgreSQL o SQLite

A diferencia de Nextcloud (que soporta los tres), Bookstack **sólo** soporta MySQL/MariaDB. Es una restricción del proyecto upstream: el _schema_ Laravel y las _migrations_ usan `FULLTEXT` indices con sintaxis específica de MariaDB que no existen como tales en PostgreSQL. Por tanto la elección es **forzada**: MariaDB.

Lo que **sí** es elección es **no compartir** la BD con `nextcloud-db`. Tentación natural: tener una sola MariaDB que sirva a Nextcloud y a Bookstack y, en el futuro, a Mealie, FreshRSS… Se descarta por:

- **Aislamiento de _stacks_** (principio de `docs/02-docker/02-estructura-compose.md`): la BD de Nextcloud está en `almacen-internal`, en el _stack_ `almacen`. Hacer que Bookstack del _stack_ `productividad` la alcance requeriría enchufar `bookstack` a `almacen-internal` o crear una red ad-hoc. Cualquiera de los dos rompe la regla de "una red privada por _stack_, las dependencias internas se quedan dentro del _stack_".
- **Ciclos de vida divergentes**: un mantenimiento de Bookstack que requiera tirar la BD para reindexar `FULLTEXT` (operación rara pero existente) **no debe** afectar a Nextcloud. Tener instancias separadas es la separación más simple.
- **Backups por servicio**: `dump_mariadb bookstack bookstack-db …` y `dump_mariadb nextcloud nextcloud-db …` son dos `mariadb-dump` independientes, restauables por separado, retenciones distintas si se quiere. Un único `mariadb-dump --all-databases` mezclaría todo y forzaría restauraciones "todo o nada".
- **Coste**: ~120 MB de RAM idle por instancia MariaDB (con `innodb_buffer_pool_size=128M`). Tener dos = 240 MB. Para Bookstack con 1–4 usuarios concurrentes y unos cientos de páginas, 128 MB de _buffer pool_ es más que suficiente y deja a Nextcloud su propio _buffer pool_ caliente sin contención de _evictions_.

### `forward_auth` con Authelia: **NO** para Bookstack

Misma decisión que en Nextcloud (`docs/06-almacenamiento/01-nextcloud.md`, sección homónima) y Vaultwarden (`docs/11-productividad/01-vaultwarden.md`, sección homónima). Razones específicas para Bookstack:

- **API REST con _Bearer tokens_**: Bookstack expone `/api/*` con autenticación por _token_ (`Authorization: Token <id>:<secret>`). No sigue redirects HTML. Si Caddy intercepta una petición a `/api/books` con un `302` hacia `https://auth.lan/?rd=...`, el cliente (un script `curl`, un agente que vuelque runbooks, una integración futura con Home Assistant) falla con `Unexpected response: <html>...` y devuelve datos mal parseados. El operador ve "el script no funciona" y empieza a investigar la API… cuando el problema es Authelia interceptando el endpoint.
- **_Webhooks_** entrantes: si en el futuro se usa una integración tipo "GitHub envía un webhook al editar el repo, Bookstack actualiza una página" (improbable en este homelab, pero posible), GitHub tampoco sigue redirects de Authelia.
- **OIDC nativo**: Bookstack soporta **OIDC desde 22.10** vía `AUTH_METHOD=oidc`. La forma _correcta_ de unificar el _login_ de Bookstack con Authelia es **dentro** de Bookstack (registrando un _client OIDC_ en Authelia y configurando las cuatro variables `OIDC_*` en el `.env`), **no** poniendo Authelia delante con `forward_auth`. La sección **Migrar a OIDC con Authelia (opcional)** del final de este documento describe ese camino.

> **Resumen operativo**: el bloque `bookstack.lan` del `Caddyfile` lleva `import security-headers` y `import logging`, pero **no** `import authelia`. Caddy actúa como _reverse proxy_ "tonto"; Bookstack autentica con su sistema nativo (email + password + opcional MFA TOTP) y, cuando se decida, con OIDC contra Authelia desde dentro de la propia app.

### `APP_KEY` fijado explícitamente y persistido

Bookstack es Laravel; usa una **clave de cifrado simétrica** (`APP_KEY`, 32 bytes base64, prefijo `base64:`) para cifrar:

- _Cookies_ de sesión.
- _Tokens_ de _password reset_.
- _Settings_ encriptados de la propia aplicación (incluido el secreto SMTP si se configura).

Si se pierde, **todas las sesiones activas se invalidan** (los usuarios deben volver a hacer login) y los _settings_ encriptados aparecen como basura ilegible. Si se **regenera** sin antes desencriptar la BD con la clave antigua, los datos cifrados quedan **inutilizables**.

Política aplicada:

1. **Generar** un `APP_KEY` aleatorio en el host **antes** del primer arranque y guardarlo en `~/homelab/productividad/.env` (no dejar que la imagen LS lo autogenere).
2. **Persistirlo** en Vaultwarden (en una nota "Homelab — Bookstack APP_KEY") y en papel custodiado.
3. **No regenerarlo nunca** salvo en una recuperación tras compromiso explícito.

Generación (será descrita en **Variables de entorno**):

```bash
echo "base64:$(openssl rand -base64 32)"
# base64:fcMSb4U7gT1z9PqkW3oHr+jX9k2sVL4nA8CbE7nM0xY=
```

> **Por qué no dejar que la imagen lo genere**: la imagen `lscr.io/linuxserver/bookstack` lo escribe a `/config/www/.env` la primera vez; eso queda persistido en `/mnt/hd2t/services/bookstack/config/www/.env` y sobrevive a reinicios. Pero **no entra en `~/homelab/productividad/.env`**: el `git status` del repo no avisa de su existencia, y el operador podría destruir el bind mount creyendo que es regenerable. Forzarlo en el `.env` desde el principio mantiene **una sola fuente de verdad** y lo lleva a los backups offsite junto con el resto del `.env` (custodia separada, ver **Backup**).

### `APP_URL` byte a byte y _trusted proxies_

Bookstack genera URLs absolutas en _emails_ (de password reset, invitaciones, notificaciones) y en _share links_ a partir de la variable `APP_URL`. Si no se le dice, las construye con el _hostname_ que Apache ve en la request (`Host: bookstack`) — y como Caddy reescribe `Host` a `bookstack.lan` por defecto, lo natural es que coincidan… pero **lo natural no es lo seguro**.

Política:

```bash
APP_URL=https://bookstack.lan
```

…fijado en el `.env`. Coincide byte a byte con el dominio del bloque del `Caddyfile`.

Y, complementario, en el `docker-compose.yml`:

```yaml
APP_PROXIES: "172.20.10.0/24"
```

Subnet de la red Docker `homelab`. Sin esto, Bookstack ignora la cabecera `X-Forwarded-Proto` que envía Caddy y construye URLs `http://...` en los emails (cookies sin `Secure`, mixed content). Con la subnet completa `172.20.10.0/24` confía en cualquier proxy de la red `homelab` (en la práctica, sólo Caddy), sin tener que pinear la IP exacta del contenedor de Caddy (que cambia entre `up -d`).

### Cron interno del propio contenedor de LinuxServer

Bookstack necesita ejecutar **tareas programadas** Laravel (`php artisan schedule:run` cada minuto):

- Eliminar drafts antiguos.
- Limpiar tokens de _password reset_ caducados.
- Procesar la cola de jobs (envío de notificaciones por email si SMTP está configurado).
- Estadísticas internas.

A diferencia de Nextcloud, donde se decidió un _sidecar_ explícito (`docs/06-almacenamiento/01-nextcloud.md` → **Cron de Nextcloud**), la imagen `lscr.io/linuxserver/bookstack` ya **incluye** el cron interno: el `entrypoint` de LinuxServer arranca un `cron` _supervisord_-style dentro del propio contenedor. **No** hace falta un _sidecar_ adicional; la única acción del operador es asegurarse de que `cron` está corriendo (el _healthcheck_ no lo verifica directamente, pero un `docker exec bookstack ps aux | grep cron` debe mostrarlo).

> **Por qué se acepta el patrón LinuxServer en este caso y se rechazó en Nextcloud**: la imagen LS de Bookstack tiene **un único proceso PHP** (no un cluster php-fpm + apache + cron como Nextcloud) y el cron interno está bien aislado del proceso web, sin acoplarse a su ciclo de vida. En Nextcloud, el _sidecar_ se prefirió porque el cron debe correr **incluso si el contenedor web está parado para mantenimiento** (notificaciones de emergencia, expiración de share links). Bookstack no tiene ese requisito.

### Almacenamiento

| Ruta en el host                                       | Contenido                                                              | Versionable | Backup |
|-------------------------------------------------------|------------------------------------------------------------------------|-------------|--------|
| `~/homelab/productividad/docker-compose.yml`          | Definición del _stack_ (modificada — añade `bookstack`+`bookstack-db`) | git         | git    |
| `~/homelab/productividad/.env`                        | Imágenes pinneadas + `APP_KEY` + secrets DB                            | **NO** (`.gitignore`) | nota local (custodia separada) |
| `~/homelab/productividad/.env.example`                | Plantilla con nombres de variables, sin valores                        | git         | git    |
| `/mnt/hd2t/services/bookstack/config/`                | `/config` del contenedor: `www/.env`, `www/uploads/`, `www/storage/files/`, `www/storage/images/`, _cache_ Laravel | **NO** | **Sí** (Borgmatic, copia raw del directorio) |
| `/mnt/hd2t/services/bookstack/db/`                    | InnoDB de MariaDB: `bookstack.ibd`, `mysql.ibd`, redo logs, etc.       | **NO**      | **Sí** (Borgmatic, vía `mariadb-dump`) |

> **`config/` y `db/` separados**: dos _bind mounts_ distintos, uno por contenedor, sin solapes. Son **dos categorías de backup**: `config/` se respalda como **filesystem raw** (el dump del Patrón M ya cubre la BD; sólo necesitamos la copia binaria del directorio para restaurar uploads y `APP_KEY` derivados), `db/` se respalda **sólo vía dump SQL** (la copia raw del directorio MariaDB **no** es consistente sin parar el contenedor — el _dump_ sí).

> **Nota sobre `config/www/.env`**: la imagen LS de Bookstack **escribe** una versión derivada del `.env` Laravel en `/config/www/.env` la primera vez. Ese fichero es **regenerado por el _entrypoint_** en cada arranque a partir de las env vars del compose: si se pierde, no pasa nada al reiniciar. Lo importante es que el **`APP_KEY`** que usa esté **el mismo** que el del compose (es lo que garantizamos fijándolo en `~/homelab/productividad/.env`).

> **Permisos de `/mnt/hd2t/services/bookstack/{config,db}/`**: la imagen LS de Bookstack corre como `abc:abc` (UID/GID configurables vía `PUID`/`PGID`, default `911:911`; **el operador los pondrá a `1000:1000` desde el `.env`** global del homelab). La imagen oficial de MariaDB corre como `mysql:mysql` (UID/GID `999:999` en Debian/Ubuntu). El _entrypoint_ de cada imagen hace `chown` de su propio subárbol en el primer arranque. Como el host monta `/mnt/hd2t` con permisos uniformes y los subdirectorios se crearon con `root:root 0755` en `docs/01-sistema/04-estructura-directorios.md`, **no hay nada que pre-chown-ear**.

---

## Estructura del _stack_ `productividad` tras este documento

Antes de este documento (tras `docs/11-productividad/01-vaultwarden.md`):

```
~/homelab/productividad/
├── docker-compose.yml        # contiene SÓLO vaultwarden
├── .env                      # APP vars de Vaultwarden
├── .env.example
└── .gitignore
```

Tras este documento:

```
~/homelab/productividad/
├── docker-compose.yml        # ← MODIFICADO: añade bookstack + bookstack-db + red productividad-internal
├── .env                      # ← MODIFICADO: añade BS_* y MariaDB
├── .env.example              # ← MODIFICADO: añade plantilla BS_*
└── .gitignore                # sin cambios
```

Y en el disco externo, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/bookstack/
├── config/                   # ← se crea al primer arranque del contenedor bookstack
└── db/                       # ← se crea al primer arranque del contenedor bookstack-db
```

Ningún cambio en `~/homelab/productividad/.gitignore` (ya excluye `.env`). Ningún subdirectorio _stub_ que crear a mano: las imágenes hacen _populate_ del bind mount en el primer arranque.

> **Confirmar el árbol** antes de seguir:
> ```bash
> ls -la /mnt/hd2t/services/bookstack/
> # drwxr-xr-x 2 root root 4096 ... .   <- vacío
> # drwxr-xr-x ...               ..
> ```
> Si ya hay subdirectorios `config/` o `db/` aquí (de un intento previo), **borrarlos** antes del primer arranque limpio:
> ```bash
> sudo rm -rf /mnt/hd2t/services/bookstack/config /mnt/hd2t/services/bookstack/db
> ```

---

## Variables de entorno

### Ampliar `~/homelab/productividad/.env.example`

Abrir el fichero existente (creado en `docs/11-productividad/01-vaultwarden.md`) y **añadir al final** un nuevo bloque (no tocar las líneas de Vaultwarden):

```bash
# ============================================================================
# Bookstack — wiki interna del homelab (docs/11-productividad/02-bookstack.md)
# ============================================================================

# --- Imágenes pinneadas -----------------------------------------------------
BOOKSTACK_IMAGE_TAG=25.10
# MariaDB se reusa entre Bookstack y otros futuros servicios del stack
# productividad. Coincide con MARIADB_IMAGE_TAG del stack 'almacen'.
MARIADB_IMAGE_TAG=11.4-noble

# --- Bookstack — endpoint y dominio ----------------------------------------
# URL pública canónica. CRÍTICO: Bookstack genera URLs absolutas en emails y
# share links a partir de aquí; cambiarlo después invalida los links ya
# enviados (no rompe la BD, pero confunde a los receptores).
APP_URL=https://bookstack.lan

# --- Bookstack — clave de cifrado de Laravel -------------------------------
# Generación (UNA sola vez, al rellenar el .env real):
#   echo "base64:$(openssl rand -base64 32)"
# CRÍTICO: si se pierde, los settings cifrados (incl. SMTP) y todas las
# sesiones activas quedan inutilizables. Custodia: dentro de Vaultwarden +
# papel. NUNCA regenerar tras un primer arranque exitoso.
APP_KEY=

# --- Bookstack — proxy reverso (Caddy) -------------------------------------
# Subnet de la red Docker 'homelab' (creada en docs/02-docker/02-estructura-compose.md).
# Sin esto, Bookstack ignora X-Forwarded-Proto y construye URLs http://.
APP_PROXIES=172.20.10.0/24

# --- Bookstack — política de registro --------------------------------------
# Cierra el alta abierta. El operador crea su cuenta con el admin@admin.com
# por defecto (cambia su email/password en el primer login) y, después,
# añade más usuarios desde Settings → Users. NUNCA dejar a true en producción.
APP_PUBLIC=false

# --- Bookstack — connection a MariaDB --------------------------------------
# El hostname coincide con el container_name del servicio bookstack-db.
# Bookstack se conecta por DNS interno de Docker dentro de productividad-internal.
DB_HOST=bookstack-db
DB_PORT=3306
DB_DATABASE=bookstack
DB_USERNAME=bookstack

# Generación recomendada (al rellenar el .env real):
#   openssl rand -base64 32 | tr -d '/+=' | head -c 32
# Custodia: dentro de Vaultwarden, nota "Homelab — Bookstack DB".
DB_PASSWORD=

# --- MariaDB (bookstack-db) — root password --------------------------------
# Sólo se usa para troubleshooting (mariadb -uroot -p) y para futuros mantenimientos
# de schema. Generación: misma fórmula que DB_PASSWORD. Custodia: Vaultwarden.
MYSQL_ROOT_PASSWORD=

# --- Bookstack — locale ----------------------------------------------------
APP_LANG=es

# --- Bookstack — logging ---------------------------------------------------
# 'errorlog' loguea a stderr del contenedor (lo recoge dozzle / docker logs).
# 'single' escribe a /config/log/laravel.log (volumen persistente).
APP_LOG=errorlog
APP_DEBUG=false

# --- SMTP (opcional, ver sección 'SMTP opcional' al final del documento) ---
# Vacío = funcionalidad de email deshabilitada. Sin SMTP siguen funcionando
# login y la wiki; sólo se pierden invitaciones a usuarios y notificaciones.
# MAIL_HOST=
# MAIL_PORT=587
# MAIL_USERNAME=
# MAIL_PASSWORD=
# MAIL_ENCRYPTION=tls
# MAIL_FROM=bookstack@homelab.example
# MAIL_FROM_NAME=Bookstack
```

### Ampliar `~/homelab/productividad/.env`

Copiar las nuevas líneas de la plantilla y rellenar los valores reales. El paso clave es generar `APP_KEY` y las dos passwords de la BD:

```bash
# Editar el .env existente (tiene ya los valores de Vaultwarden; AÑADIR debajo).
# Alternativamente, regenerar todo:
cp ~/homelab/productividad/.env.example ~/homelab/productividad/.env.new
# Combinar manualmente con vi: copiar los valores de Vaultwarden de .env al
# .env.new, luego rellenar los nuevos. Cuando esté:
mv ~/homelab/productividad/.env.new ~/homelab/productividad/.env
chmod 0600 ~/homelab/productividad/.env

# 1. Generar APP_KEY (32 bytes base64, prefijo 'base64:')
app_key="base64:$(openssl rand -base64 32)"
echo "APP_KEY = $app_key"
sed -i "s|^APP_KEY=$|APP_KEY=$app_key|" ~/homelab/productividad/.env

# 2. Generar password de DB para el usuario 'bookstack' (32 chars sin /+=)
db_pass=$(openssl rand -base64 48 | tr -d '/+=' | head -c 32)
echo "DB_PASSWORD (anotar en Vaultwarden — nota 'Homelab — Bookstack DB'): $db_pass"
sed -i "s|^DB_PASSWORD=$|DB_PASSWORD=$db_pass|" ~/homelab/productividad/.env

# 3. Generar password root de MariaDB
db_root=$(openssl rand -base64 48 | tr -d '/+=' | head -c 32)
echo "MYSQL_ROOT_PASSWORD (anotar en Vaultwarden): $db_root"
sed -i "s|^MYSQL_ROOT_PASSWORD=$|MYSQL_ROOT_PASSWORD=$db_root|" ~/homelab/productividad/.env

# 4. Confirmar
grep -E '^(APP_KEY|DB_PASSWORD|MYSQL_ROOT_PASSWORD)=' ~/homelab/productividad/.env
# APP_KEY=base64:...
# DB_PASSWORD=...
# MYSQL_ROOT_PASSWORD=...

# 5. Limpiar las variables de la sesión
unset app_key db_pass db_root
```

> **Custodia inmediata**: añadir las tres líneas (APP_KEY, DB_PASSWORD, MYSQL_ROOT_PASSWORD) a una nota en **Vaultwarden** titulada "Homelab — Bookstack secrets", **antes** de seguir adelante. Si Vaultwarden está caído, anotarlas en papel y hacerlo en cuanto se levante. La pérdida de `APP_KEY` es lo más doloroso (los _settings_ cifrados y las sesiones activas quedan inutilizables; recuperación documentada en **Troubleshooting**).

> **Por qué `tr -d '/+='`**: `openssl rand -base64` puede emitir `/`, `+` o `=`, todos válidos en YAML pero molestos al copiar/pegar y problemáticos en _connection strings_ MySQL si el _client_ los interpreta. Detalle ya documentado en `docs/06-almacenamiento/01-nextcloud.md` → _Variables de entorno_.

> **No commitear `.env` jamás**. El `.gitignore` del _stack_ ya lo excluye explícitamente.

---

## Modificar `~/homelab/productividad/docker-compose.yml`

El _docker-compose.yml_ de este _stack_ ya existe (creado en `docs/11-productividad/01-vaultwarden.md`) con un único servicio `vaultwarden`. **Editarlo, no recrearlo**: añadir los dos servicios nuevos y la red privada `productividad-internal`, dejando intacto el bloque de Vaultwarden.

El fichero completo tras la edición debe quedar así:

```yaml
---
# Stack: productividad — Vaultwarden, Bookstack, …
# Documentación:
#   - docs/11-productividad/01-vaultwarden.md
#   - docs/11-productividad/02-bookstack.md

services:

  # ===========================================================================
  # Vaultwarden — definido en docs/11-productividad/01-vaultwarden.md.
  # NO TOCAR ESTE BLOQUE: añadir Bookstack abajo.
  # ===========================================================================
  vaultwarden:
    # … bloque existente sin cambios (ver 01-vaultwarden.md) …
    # placeholder en este snippet del doc; el contenido real ya está en disco.
    image: vaultwarden/server:${VAULTWARDEN_IMAGE_TAG}
    # ...

  # ===========================================================================
  # MariaDB — base de datos de Bookstack.
  # Sólo en productividad-internal; no se expone al host ni a 'homelab'.
  # ===========================================================================
  bookstack-db:
    image: mariadb:${MARIADB_IMAGE_TAG}
    container_name: bookstack-db
    hostname: bookstack-db
    restart: unless-stopped
    # Recomendado por Bookstack: collation utf8mb4 con _unicode_ci para que
    # FULLTEXT funcione bien con texto en español, alemán y otros locales.
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --innodb-file-per-table=ON
      - --innodb-buffer-pool-size=128M
      - --max-connections=50
    environment:
      TZ: ${TZ}
      MYSQL_DATABASE: ${DB_DATABASE}
      MYSQL_USER: ${DB_USERNAME}
      MYSQL_PASSWORD: ${DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    volumes:
      - /mnt/hd2t/services/bookstack/db:/var/lib/mysql
    networks:
      - productividad-internal
    labels:
      homelab.stack: "productividad"
      homelab.backup: "true"      # vía dump_mariadb (hook Borgmatic)
      # Opt-out: bumps de major rompen formato InnoDB. Manual.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      test:
        - CMD
        - healthcheck.sh
        - --connect
        - --innodb_initialized
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 60s

  # ===========================================================================
  # Bookstack — la propia aplicación (PHP-FPM + Apache + Laravel).
  # En 'homelab' (Caddy la alcanza por DNS) Y en 'productividad-internal'
  # (alcanza a la BD).
  # ===========================================================================
  bookstack:
    image: lscr.io/linuxserver/bookstack:${BOOKSTACK_IMAGE_TAG}
    container_name: bookstack
    hostname: bookstack
    restart: unless-stopped
    environment:
      # --- Identidad LinuxServer ---
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}

      # --- Endpoint y reverse proxy ---
      APP_URL: ${APP_URL}
      APP_PROXIES: ${APP_PROXIES}

      # --- Cifrado Laravel ---
      APP_KEY: ${APP_KEY}

      # --- Política de registro ---
      APP_PUBLIC: ${APP_PUBLIC}

      # --- Locale y logging ---
      APP_LANG: ${APP_LANG}
      APP_LOG: ${APP_LOG}
      APP_DEBUG: ${APP_DEBUG}

      # --- Conexión a MariaDB ---
      DB_HOST: ${DB_HOST}
      DB_PORT: ${DB_PORT}
      DB_DATABASE: ${DB_DATABASE}
      DB_USERNAME: ${DB_USERNAME}
      DB_PASSWORD: ${DB_PASSWORD}

      # --- SMTP (opcional, descomentar cuando se configure) ---
      # MAIL_HOST: ${MAIL_HOST}
      # MAIL_PORT: ${MAIL_PORT}
      # MAIL_USERNAME: ${MAIL_USERNAME}
      # MAIL_PASSWORD: ${MAIL_PASSWORD}
      # MAIL_ENCRYPTION: ${MAIL_ENCRYPTION}
      # MAIL_FROM: ${MAIL_FROM}
      # MAIL_FROM_NAME: ${MAIL_FROM_NAME}
    volumes:
      - /mnt/hd2t/services/bookstack/config:/config
    networks:
      homelab:
        aliases:
          - bookstack         # Caddy resuelve 'bookstack:80' por este alias
      productividad-internal:
        # alcanza a 'bookstack-db' por nombre, sólo desde aquí
    labels:
      homelab.stack: "productividad"
      homelab.backup: "true"      # /mnt/hd2t/services/bookstack/config (raw)
      # Opt-out: las upgrades de Bookstack ejecutan migraciones de schema. Manual.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      # /status devuelve 200 + JSON {"app_name":"BookStack","app_version":"v25.10",...}
      # cuando la app está sirviendo y la BD responde.
      test:
        - CMD-SHELL
        - "curl -fsS http://localhost:80/status >/dev/null"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s    # primer arranque: php artisan migrate, ~60 s
    depends_on:
      bookstack-db:
        condition: service_healthy

# ===========================================================================
# Redes
# ===========================================================================
networks:
  homelab:
    external: true               # creada en docs/02-docker/02-estructura-compose.md

  productividad-internal:
    driver: bridge               # privada de este stack; Compose la gestiona
    # Nota: Vaultwarden (definido más arriba) NO se engancha a esta red.
    # Sólo bookstack y bookstack-db viven aquí. Si más adelante un servicio
    # del stack productividad necesita una BD, se añade al mismo
    # productividad-internal sin cambiar el aislamiento de Vaultwarden.
```

> **Importante — el bloque `vaultwarden:` mostrado arriba es un _placeholder_** ilustrativo. El contenido real ya está en disco desde `docs/11-productividad/01-vaultwarden.md`; al editar el fichero, **no** sobreescribir ese bloque, sólo añadir los dos servicios nuevos y la red `productividad-internal`. Validar después con `docker compose config | grep -E '^\s+(vaultwarden|bookstack|bookstack-db):'` que los tres siguen estando.

Notas de diseño:

- **Sólo `bookstack` está en `homelab`**. `bookstack-db` se queda en `productividad-internal` y es **inalcanzable desde Caddy** o desde Vaultwarden o desde otros _stacks_. Esto cumple el principio de "sólo el _front_ de cada _stack_ se publica al resto del homelab", igual que Nextcloud (`docs/06-almacenamiento/01-nextcloud.md`).
- **Vaultwarden NO se engancha a `productividad-internal`**. Sigue viviendo sólo en `homelab`. El aislamiento es por servicio: Vaultwarden no necesita la BD de Bookstack ni viceversa, por tanto no hay razón para que estén en la misma red privada. Si Bookstack-db se compromete, Vaultwarden no se ve afectado.
- **Sin `ports:`** en ningún servicio. Caddy alcanza Bookstack por DNS interno (`bookstack:80`). Si el operador, durante troubleshooting, necesita acceder a Bookstack sin pasar por Caddy: `docker exec -it bookstack curl -fsS http://localhost/status`.
- **`depends_on` con `condition: service_healthy`**: `bookstack-db` debe estar `(healthy)` antes de que arranque `bookstack`. Sin esto, Bookstack loguearía `SQLSTATE[HY000] [2002] Connection refused` durante los primeros 30–60 s del primer arranque; eventualmente arranca tras los reintentos del entrypoint LS, pero contamina logs.
- **`start_period: 90s`** en `bookstack`: la **primera** arrancada tarda ~60 s (descompresión de Bookstack en `/config`, `php artisan key:generate` _no_ — porque ya tiene `APP_KEY`, `php artisan migrate` que crea las ~30 tablas iniciales, `php artisan db:seed` que crea el usuario `admin@admin.com`). Con un `start_period` corto, el _healthcheck_ daría `unhealthy` espuriamente y Compose intentaría reiniciar el contenedor en plena instalación. 90 s es holgado; en arranques posteriores, el `(healthy)` llega en <15 s.
- **Watchtower opt-out** en ambos: razones explicadas en **Decisiones de diseño** → _Imagen y tag_.
- **Sin `user:` explícito en `bookstack`**: la imagen LS gestiona el cambio de UID via `PUID`/`PGID` desde dentro del entrypoint (chowns iniciales + `s6-setuidgid abc`). Forzar `user:` aquí rompe el comportamiento por defecto de LS.

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/productividad
# Validar la sintaxis sin levantar nada (recomendado tras editar el compose).
docker compose --env-file ../.env --env-file .env config | grep -E '^\s+(vaultwarden|bookstack|bookstack-db):'
# vaultwarden:
# bookstack-db:
# bookstack:

# Levantar SÓLO los servicios nuevos (Vaultwarden ya está corriendo y healthy):
docker compose --env-file ../.env --env-file .env up -d bookstack-db bookstack
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=productividad
# El make up no es selectivo: lleva el stack completo al estado deseado.
# Como Vaultwarden ya está up y nada del compose lo cambia, Compose lo deja
# tal cual y sólo arranca bookstack-db + bookstack. El up es idempotente.
```

Vigilar el primer arranque (tarda ~75 s en una Pi 5):

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml logs -f bookstack-db bookstack
# bookstack-db | [Note] mariadbd: ready for connections.
# ...
# bookstack    | [migrations] starting
# bookstack    | [migrations] no migrations found
# bookstack    | [services.d] starting services
# bookstack    | [cont-init.d] 50-config: applying configuration
# bookstack    | INFO[migrate] Migration table created successfully.
# bookstack    | INFO[migrate] Migrating: 2014_10_12_000000_create_users_table
# ... (~25 migraciones más) ...
# bookstack    | INFO[migrate] Migrated: ... (xxx ms)
# bookstack    | INFO[seeder]  Seeding: PermissionRoleSeeder
# bookstack    | INFO[seeder]  Seeded:  PermissionRoleSeeder
# bookstack    | [ls.io-init] done.
# bookstack    | AH00094: Command line: '/usr/sbin/apache2 -D FOREGROUND'
```

Verificar que ambos contenedores están `(healthy)`:

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml ps
# NAME            STATUS                   PORTS
# vaultwarden     Up X minutes (healthy)
# bookstack-db    Up X seconds (healthy)
# bookstack       Up X seconds (healthy)
```

> El `(healthy)` de `bookstack` lo otorga el _healthcheck_ de `/status`. Si tras 2 minutos sigue `starting`/`unhealthy`, ir a **Troubleshooting** → primer arranque.

Confirmar que la BD se creó bien:

```bash
docker exec bookstack-db mariadb -uroot -p"$(grep ^MYSQL_ROOT_PASSWORD ~/homelab/productividad/.env | cut -d= -f2)" \
    -e "SHOW DATABASES; SELECT COUNT(*) AS tablas FROM information_schema.tables WHERE table_schema='bookstack';"
# +--------------------+
# | Database           |
# +--------------------+
# | bookstack          |
# | information_schema |
# | mysql              |
# | performance_schema |
# | sys                |
# +--------------------+
# +--------+
# | tablas |
# +--------+
# |     30 | (aprox; depende de la versión exacta de Bookstack)
# +--------+
```

Y que `/config` se ha poblado:

```bash
ls /mnt/hd2t/services/bookstack/config/
# log/
# nginx/    (no se usa en LS de Bookstack pero el árbol /config/ trae plantillas)
# php/
# www/      <- aquí está la app: storage/, public/, .env (Laravel), etc.
```

### Caddy: bloque `bookstack.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque:

```caddy
bookstack.lan {
    tls internal
    import security-headers
    import logging

    # Subidas grandes (uploads de imágenes en páginas, ficheros adjuntos a libros).
    # Bookstack admite hasta el límite de PHP, default 32 MB en la imagen LS.
    # Caddy no impone su propio límite; suficiente con el de PHP.

    # Pasar a Bookstack tal cual. Caddy reescribe Host por defecto, lo que
    # combinado con APP_PROXIES=172.20.10.0/24 y APP_URL=https://bookstack.lan
    # del .env, permite a Bookstack generar URLs https:// correctas en emails.
    reverse_proxy bookstack:80 {
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
curl -k --resolve bookstack.lan:443:192.168.1.3 https://bookstack.lan/status
# {"app_name":"BookStack","app_version":"v25.10","app_locale":"es",
#  "app_url":"https://bookstack.lan","cache_size":...,"db_status":"working",...}
```

Y desde el navegador: `https://bookstack.lan/` → pantalla de login con candado verde y un formulario que pide email + password.

---

## Configuración tras primer arranque

### 1. Cambiar el usuario admin por defecto

Bookstack crea, en su primera ejecución de _seeders_, un usuario:

- **Email**: `admin@admin.com`
- **Password**: `password`

**Antes de cualquier otra cosa**, sustituirlo por la cuenta del operador. En el web vault:

1. `Log in` con `admin@admin.com` / `password`.
2. Ir a `Settings` (icono de engranaje arriba a la derecha) → `Users` → click en el usuario "Admin".
3. **Cambiar email, nombre, password**:
   - **Email**: el del operador (puede ser cualquier email, real o no; sin SMTP no se envía nada de validación).
   - **Name**: el nombre real del operador.
   - **Password**: pulsar `Change Password`, generar una password fuerte (≥ 16 chars) en Vaultwarden, anotarla _antes_ de pegarla. Confirmar.
4. Logout y volver a hacer login con la cuenta nueva. Verificar que se entra y que el email del header muestra el nuevo.

> **No borrar** el usuario admin@admin.com original sin antes hacer login con la cuenta nueva: si la nueva no funciona y la original ya no existe, no hay forma de entrar (la única ruta de recuperación es `php artisan tinker` desde dentro del contenedor para crear un usuario manualmente; descrito en **Troubleshooting**).

### 2. Cerrar el alta abierta

Bookstack tiene la opción _Allow public registration_. **Por defecto**, en una instalación nueva, está **desactivada**, y el `.env` que hemos rellenado lo refuerza con `APP_PUBLIC=false`. Pero conviene confirmarlo explícitamente desde la UI:

1. `Settings → Settings` (engranaje arriba derecha) → ir a la sección `Registration`.
2. Verificar que `Allow public registration` está **OFF**. Si estuviese ON (por una migración antigua o un toggle accidental), apagarla.
3. `Save Settings`.

A partir de aquí, el único camino para añadir más usuarios es `Settings → Users → Add New User` (creando la cuenta a mano y pasando la password al usuario por canal seguro — Vaultwarden Send, Signal — o esperando a tener SMTP para usar `Send invite email`).

### 3. Activar 2FA (MFA TOTP)

Bookstack soporta TOTP nativo desde 22.10. Cada usuario lo activa desde su perfil:

1. Click en el avatar (arriba derecha) → `My Account` → `MFA`.
2. `Setup` → escanear el QR con Aegis / Authy / 1Password / `oath-tool`.
3. Confirmar con un código TOTP válido.
4. Bookstack muestra un **recovery code** de un solo uso. **Imprescindible**: copiarlo a la nota "Homelab — Bookstack secrets" en Vaultwarden. Si el dispositivo TOTP se pierde y el recovery code se pierde, el único camino es `php artisan tinker` desde dentro del contenedor para resetear el MFA del usuario afectado (descrito en **Troubleshooting**).

> **Por qué activar MFA antes de añadir contenido sensible**: la wiki va a contener runbooks con detalles operativos del homelab (rutas de backup, nombres de hosts, IPs). No son secretos de máxima criticidad (las **passwords** viven en Vaultwarden, no aquí), pero son **información explotable** por un atacante con acceso al login. MFA blinda el acceso.

### 4. Personalizar la wiki (opcional pero recomendado)

`Settings → Settings`:

- **Application Name**: "Homelab Pi5" (o el que el operador prefiera).
- **Application Logo**: subir un logo si se quiere; default está bien.
- **Default Language**: `Español` (ya lo aplica `APP_LANG=es`, esto sólo afecta a usuarios nuevos).
- **Allow Content Export**: ON (permite exportar páginas a PDF/HTML/Markdown — útil para backups manuales fuera de Borgmatic).
- **Default Books Sort Order**: `Manual order` (el operador organiza el orden a mano; `Last updated` es ruido cuando hay pocos libros).

`Settings → Customisation`:

- **Homepage**: por defecto `Default`. Si ya hay contenido relevante, cambiar a `Specific Page` y elegir la página de bienvenida.

### 5. Estructura inicial de contenido recomendada

Crear las **estanterías** (Shelves) iniciales que reflejen el plano del homelab:

| Shelf                     | Contenido                                                                            |
|---------------------------|--------------------------------------------------------------------------------------|
| **00 — Operaciones**      | Runbooks: backups, restauración, monitorización, mantenimiento periódico             |
| **01 — Servicios**        | Apuntes por servicio: Nextcloud, Vaultwarden, Bookstack, Home Assistant, Jellyfin… |
| **02 — Disaster Recovery** | Escenarios DR: pérdida de microSD, pérdida de hd2t, pérdida de hd5t                  |
| **03 — Diario / Bitácora** | Notas del día: cambios hechos, fallos vistos, ideas a probar                         |
| **99 — Sandbox**          | Páginas borrador, sin organizar                                                      |

> **Convivencia con `~/workspace/homelab/docs/`**: este Bookstack **no sustituye** al repo Markdown del homelab que está en git (donde viven los `.md` canónicos como `docs/11-productividad/02-bookstack.md` que estás leyendo). El repo es **canónico**: lo que tiene que ser reproducible, versionado, exportable a otra Pi. Bookstack es **operativo**: notas del día a día, ideas, datos circunstanciales, snapshots de troubleshooting que no merecen un commit. Una página típica de Bookstack en "00 — Operaciones / Runbooks / Restauración Borg" puede tener tres líneas: "El comando `borg list` con `--last 3` filtra a los últimos backups; útil para drills mensuales". Tres líneas que sería ridículo committear al repo, pero que perderlas es perder tiempo.

### 6. Activar el bloque del _hook_ de Borgmatic

`docs/07-backups/03-backup-docker-volumes.md` dejó preparada la línea comentada:

```bash
# --- Bookstack (MariaDB) — docs/11-productividad/02-bookstack.md
# dump_mariadb bookstack bookstack-db "$HOMELAB/productividad/.env" bookstack
```

Descomentarla:

```bash
# Localizar el script del hook
hook=~/homelab/backups/borgmatic/hooks/dump-databases.sh
ls -la "$hook"

# Descomentar las dos líneas (o usar el editor interactivo).
# Variante con sed:
sed -i 's|^# dump_mariadb bookstack bookstack-db "\$HOMELAB/productividad/\.env" bookstack$|dump_mariadb bookstack bookstack-db "$HOMELAB/productividad/.env" bookstack|' "$hook"

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

ls -la /mnt/hd2t/backups/dumps/ | grep bookstack
# bookstack-2026-04-25.sql.gz   ~50 KB para una BD recién creada
```

Verificar que el dump es válido:

```bash
gunzip -c /mnt/hd2t/backups/dumps/bookstack-$(date +%F).sql.gz | head -20
# -- MariaDB dump 10.19  Distrib 10.6.0-MariaDB, for Linux (aarch64)
# --
# -- Host: localhost    Database: bookstack
# -- ------------------------------------------------------
# -- Server version       11.4.x-MariaDB-...
# /*!40103 SET TIME_ZONE='+00:00' */;
# ...
# DROP TABLE IF EXISTS `activities`;
```

Y que las tablas críticas están presentes:

```bash
gunzip -c /mnt/hd2t/backups/dumps/bookstack-$(date +%F).sql.gz | \
    grep -oE 'CREATE TABLE `[^`]+`' | sort -u
# CREATE TABLE `activities`
# CREATE TABLE `attachments`
# CREATE TABLE `books`
# CREATE TABLE `chapters`
# CREATE TABLE `images`
# CREATE TABLE `migrations`
# CREATE TABLE `pages`
# CREATE TABLE `revisions`
# CREATE TABLE `users`
# ... (las que tenga la versión, ~30)
```

> **Por qué `--single-transaction --skip-lock-tables`** (lo aplica el helper `dump_mariadb`): InnoDB con `--single-transaction` produce un dump **consistente** sin bloquear escrituras concurrentes; `--skip-lock-tables` evita el `LOCK TABLES` global que MyISAM exigía y que en InnoDB sólo bloquea sin aportar consistencia. Es el patrón estándar para BD InnoDB-only y está documentado en `docs/07-backups/03-backup-docker-volumes.md` → _Patrón M_.

### 7. (No aplica) Activar un _jail_ de fail2ban

A diferencia de Vaultwarden (que tiene un _jail_ explícito en `docs/04-seguridad/02-fail2ban.md`), **Bookstack no tiene un _jail_ pre-configurado**. Las razones:

- Bookstack no expone un endpoint público a internet — vive sólo en LAN + Tailscale, donde el modelo de amenaza de _brute force_ es muy bajo.
- El log de Bookstack en `errorlog` (que es lo que se configuró con `APP_LOG=errorlog`) **no escribe líneas estructuradas para fallos de login**: una autenticación fallida no aparece como tal en el log de Apache; aparece sólo como un `POST /login 422` o similar, indistinguible de validaciones legítimas.
- Para tener un _jail_ útil habría que configurar `APP_LOG=single` y un log Laravel parseable, **más** un filtro `fail2ban` _ad hoc_. Es factible, pero el _ROI_ es bajo en una wiki personal en LAN.

**Política asumida**: no se configura jail. Si en el futuro Bookstack se publicase en internet (cambio de modelo de red), este documento se complementaría con un _jail_ específico, en línea con el patrón Vaultwarden.

---

## Verificación final

Antes de pasar a `docs/11-productividad/03-linkding.md`, comprobar:

- [ ] `docker compose -f ~/homelab/productividad/docker-compose.yml ps` muestra `vaultwarden`, `bookstack-db` y `bookstack` los tres en `(healthy)`.
- [ ] `curl -k --resolve bookstack.lan:443:192.168.1.3 https://bookstack.lan/status` devuelve un JSON con `"app_version":"v25.10"` (o el _tag_ pinneado), `"db_status":"working"` y `"app_url":"https://bookstack.lan"`.
- [ ] `https://bookstack.lan/` carga la wiki en el navegador con candado verde (CA local importada).
- [ ] El usuario operador (no `admin@admin.com`) puede hacer login con email + password.
- [ ] El usuario `admin@admin.com` ya **no existe** o tiene email/nombre/password sustituidos; ningún usuario quedó con la password por defecto `password`.
- [ ] `Settings → Settings → Registration → Allow public registration` está **OFF**.
- [ ] El operador tiene MFA TOTP activo en su cuenta y el _recovery code_ está **anotado en Vaultwarden** y en papel.
- [ ] `APP_KEY`, `DB_PASSWORD` y `MYSQL_ROOT_PASSWORD` están almacenados en Vaultwarden en una nota titulada "Homelab — Bookstack secrets".
- [ ] La estructura inicial (≥ 1 estantería, ≥ 1 libro de prueba con ≥ 1 página) está creada y se renderiza correctamente con WYSIWYG y Markdown.
- [ ] Subir un _attachment_ (PDF de prueba ≤ 5 MB) a una página, recargar, descargar el PDF, verificar que abre. Confirmar que `/mnt/hd2t/services/bookstack/config/www/storage/uploads/files/` tiene un fichero nuevo.
- [ ] El _hook_ de Borgmatic genera `dumps/bookstack-YYYY-MM-DD.sql.gz`. Verificar que el dump es válido (cabecera `MariaDB dump`, tablas `pages`, `users`, etc.).
- [ ] `docker network ls --format '{{.Name}}' | grep productividad-internal` muestra la red privada del _stack_ ya creada por Compose.
- [ ] `docker network inspect productividad-internal --format '{{range .Containers}}{{.Name}} {{end}}'` lista exactamente `bookstack bookstack-db` (Vaultwarden **no** debe aparecer).
- [ ] `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` lista a `bookstack` y a `vaultwarden` (entre otros del homelab); **NO** lista a `bookstack-db`.
- [ ] Tras un `docker compose -f ~/homelab/productividad/docker-compose.yml restart bookstack`, la página vuelve a `(healthy)` en <30 s y el operador sigue logueado (la sesión se mantiene porque el `APP_KEY` no cambia).
- [ ] Tras un `sudo reboot` de la Pi, los tres contenedores vuelven a estar `(healthy)` sin intervención manual y `https://bookstack.lan/` responde.
- [ ] `git -C ~/homelab status` muestra como **modificados**: `productividad/docker-compose.yml`, `productividad/.env.example`, `red/Caddyfile`, `backups/borgmatic/hooks/dump-databases.sh`. **No** muestra `productividad/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add productividad/docker-compose.yml productividad/.env.example \
          red/Caddyfile backups/borgmatic/hooks/dump-databases.sh
  git commit -m "feat(productividad): add Bookstack + MariaDB and activate borgmatic dump hook"
  ```

---

## Backup

| Qué                                     | Dónde                                                         | Cómo                                                       |
|-----------------------------------------|---------------------------------------------------------------|------------------------------------------------------------|
| `docker-compose.yml`, `.env.example`    | `~/homelab/productividad/`                                     | git                                                        |
| `bookstack` schema + datos              | InnoDB en `/mnt/hd2t/services/bookstack/db/`                   | **Dump consistente** vía `dump_mariadb` (`mariadb-dump --single-transaction`) en el _hook_ de Borgmatic. El fichero binario _raw_ del directorio MariaDB **no entra** en el set "data" del config de Borgmatic (queda excluido — no es consistente sin parar el contenedor). |
| `config/www/storage/uploads/`           | `/mnt/hd2t/services/bookstack/config/www/storage/uploads/`    | Borgmatic — copia raw, retención larga (mismas políticas que `nextcloud/data` del _set_ "data"). Aquí viven los _attachments_ y las imágenes pegadas en páginas. |
| `config/www/storage/images/`            | `/mnt/hd2t/services/bookstack/config/www/storage/images/`     | Borgmatic — copia raw. Aquí viven los thumbnails generados por Bookstack. **Regenerable** desde los originales en `uploads/`, pero más rápido de restaurar incluyéndolos. |
| `config/www/.env` (Laravel auto-generado) | `/mnt/hd2t/services/bookstack/config/www/.env`               | Borgmatic — copia raw. Es **regenerado** por el entrypoint de LS desde las env vars del compose en cada arranque, así que no es estrictamente necesario, pero entra "gratis" en la copia raw del directorio. |
| `config/log/`                           | `/mnt/hd2t/services/bookstack/config/log/`                    | **Excluido** del backup (transitorio; ruido). Borgmatic excluye explícitamente vía `exclude_patterns`. |
| `config/php/`, `config/nginx/`          | `/mnt/hd2t/services/bookstack/config/{php,nginx}/`            | **Excluido** (plantillas LS, regenerables). Misma exclusión que `config/log/`. |
| `APP_KEY`, `DB_PASSWORD`, `MYSQL_ROOT_PASSWORD` | Papel + nota dentro de Vaultwarden                          | Custodia humana. NUNCA en git, NUNCA en backups con la misma passphrase que el repo. |

Verificar que las exclusiones del set "data" de Borgmatic (en `~/homelab/backups/borgmatic/config.d/`) cubren `**/services/bookstack/config/{log,php,nginx}/**`. Si no, añadir las líneas correspondientes:

```bash
# Editar el config de Borgmatic; sección 'exclude_patterns:' del set "data".
$EDITOR ~/homelab/backups/borgmatic/config.d/data.yaml
# Añadir bajo exclude_patterns:
#   - '**/services/bookstack/config/log'
#   - '**/services/bookstack/config/php'
#   - '**/services/bookstack/config/nginx'
sudo borgmatic config validate
```

> **Por qué dump SQL _y_ copia raw del directorio `config/`**: el dump (`mariadb-dump`) es el **canónico para la BD** (consistente con el último _commit_), pero la copia raw del directorio `config/` es lo que permite **restaurar uploads y attachments**, que viven _fuera_ de la BD (en el filesystem). Cinturón y tirantes — la BD sin los uploads es una wiki vacía de imágenes; los uploads sin la BD es un montón de ficheros sin contexto.

> **Restauración desde backup**:
> 1. Restaurar `/mnt/hd2t/services/bookstack/config/` desde Borgmatic (incluye `www/storage/uploads/`, `www/storage/images/`).
> 2. Borrar `/mnt/hd2t/services/bookstack/db/` antiguo (si existía):
>    ```bash
>    sudo rm -rf /mnt/hd2t/services/bookstack/db
>    sudo mkdir -p /mnt/hd2t/services/bookstack/db
>    ```
> 3. Levantar **sólo** `bookstack-db` y esperar a que esté `(healthy)` con la BD `bookstack` recreada vacía:
>    ```bash
>    docker compose -f ~/homelab/productividad/docker-compose.yml up -d bookstack-db
>    until docker exec bookstack-db healthcheck.sh --connect --innodb_initialized; do sleep 2; done
>    ```
> 4. Importar el dump:
>    ```bash
>    gunzip -c /mnt/hd2t/backups/dumps/bookstack-YYYY-MM-DD.sql.gz | \
>        docker exec -i -e MYSQL_PWD="$(grep ^MYSQL_ROOT_PASSWORD ~/homelab/productividad/.env | cut -d= -f2)" \
>            bookstack-db mariadb -uroot bookstack
>    ```
> 5. Levantar `bookstack`:
>    ```bash
>    docker compose -f ~/homelab/productividad/docker-compose.yml up -d bookstack
>    ```
> 6. Verificar login con la cuenta operador y que las páginas, libros y attachments están en su sitio.

> **Antes de cualquier upgrade de Bookstack** (25.10 → 25.12 → 26.02):
> 1. `docker compose stop bookstack`.
> 2. Backup completo `config/` + dump SQL (Borgmatic _on-demand_).
> 3. Editar `.env`: `BOOKSTACK_IMAGE_TAG=25.12` (leer el _changelog_ upstream y de LinuxServer).
> 4. `docker compose pull bookstack && docker compose up -d bookstack`.
> 5. `docker logs -f bookstack` — esperar a `[migrate] Migrated:` (las migraciones de la nueva versión) y `(healthy)`.
> 6. `curl -k https://bookstack.lan/status` — confirmar `app_version`.
> 7. Verificación final completa de la sección anterior.
> 8. Si algo va mal: `docker compose down bookstack`, restaurar backup `config/`, restaurar dump SQL, `BOOKSTACK_IMAGE_TAG=25.10`, `up -d bookstack`.

---

## Troubleshooting

### `bookstack` arranca y queda en `unhealthy`

El `start_period: 90s` da margen para `migrate` + `seed`. Si tras 2 minutos sigue `starting`/`unhealthy`, mirar los logs:

```bash
docker logs bookstack --tail 80
```

Causas frecuentes:

1. **`bookstack-db` no está `(healthy)`**: Bookstack hace `depends_on: condition: service_healthy`, así que esto se manifiesta como Bookstack en `created` y nunca arrancando. Verificar:
   ```bash
   docker logs bookstack-db --tail 40
   # Buscar "ready for connections" — si no aparece, la BD no levanta.
   ```
   Causas habituales en `bookstack-db`:
   - Espacio en `/mnt/hd2t/services/bookstack/db/` insuficiente (`df -h /mnt/hd2t`).
   - Permisos: si por error se hizo `chown` antes del primer arranque, MariaDB puede fallar al inicializar. Solución: `sudo rm -rf /mnt/hd2t/services/bookstack/db && sudo mkdir -p /mnt/hd2t/services/bookstack/db && docker compose up -d bookstack-db`.
   - `MYSQL_ROOT_PASSWORD` o `MYSQL_PASSWORD` con caracteres especiales que el shell rompe al cargar el `.env` (raro si se usó la fórmula `tr -d '/+='`).

2. **`APP_KEY` malformado**: si el `.env` tiene `APP_KEY=base64:` con valor vacío, o sin el prefijo `base64:`, Bookstack falla al arrancar con `RuntimeException: No application encryption key has been specified.` o similar. Solución: regenerar siguiendo la sección **Variables de entorno** y reiniciar.

3. **`APP_URL` con `http://` o sin `https://`**: Bookstack genera URLs con ese prefijo; si el `.env` dice `http://bookstack.lan` y Caddy sirve por `https://`, los _service workers_ del navegador se quejan, las cookies no van con `Secure`, y los _share links_ se generan con `http://` (que el navegador rechazará por _mixed content_ una vez el usuario está en `https://`). Solución: confirmar `APP_URL=https://bookstack.lan` (con `https://` y sin trailing slash).

4. **Migraciones fallaron**: aparece en logs como `SQLSTATE[xxx] [yyy] ...`. Las causas habituales son passwords mal configuradas (Bookstack no puede conectar) o un `bookstack-db` con un schema previo de otro proyecto (si el bind mount estaba sucio). Solución última: borrar `db/` y dejar que se recree limpia, repitiendo el primer arranque.

### `502 Bad Gateway` desde Caddy hacia `bookstack`

Caddy responde 502 si no puede alcanzar `bookstack:80` desde la red `homelab`. Probar:

```bash
docker exec caddy curl -fsS http://bookstack/status
# Debe devolver el JSON. Si "Failed to connect": Bookstack no está sirviendo.

docker exec caddy nslookup bookstack
# Debe resolver a una IP del 172.20.10.0/24.
```

Causas:

1. Bookstack en `unhealthy` — ver caso anterior.
2. `bookstack` no está enganchada a `homelab` (mira con `docker network inspect homelab`). Si no está, revisar la sección `networks:` del compose y `up -d bookstack` de nuevo.
3. La red `homelab` está sin `bookstack` por un fallo silencioso de Compose. `docker compose down bookstack && docker compose up -d bookstack` lo recrea.

### `419 Page Expired` al hacer login

Bookstack devuelve `419` cuando el _CSRF token_ del formulario no coincide. Causas:

1. **`APP_KEY` cambió** desde el último arranque: invalida todas las _sessions_ y _CSRF tokens_. Solución: cerrar y reabrir el navegador (sesión limpia), volver a intentar el login.
2. **Cookie de sesión bloqueada por el navegador**: pasa si `APP_URL=http://...` pero el navegador entró por `https://` (las cookies con `Secure` no se envían en peticiones HTTP). Solución: confirmar `APP_URL=https://bookstack.lan`.
3. **Reverse proxy reescribiendo `Cookie`**: muy improbable con Caddy. Confirmar que `header_up Cookie` no aparece en el bloque del Caddyfile (no debe aparecer; Caddy pasa la cookie por defecto).

### Restablecer la password del usuario admin desde el contenedor

Si se perdió la password del único admin y SMTP no está configurado (no hay forma de hacer `Reset password` desde el formulario de login):

```bash
docker exec -it -u abc bookstack php /app/www/artisan tinker
# >>> $u = \BookStack\Users\Models\User::where('email', 'operador@homelab')->first();
# >>> $u->password = \Hash::make('NuevaPasswordSuperSecreta!');
# >>> $u->save();
# >>> exit
```

> Esto sólo es seguro si **el contenedor sigue arrancado y Tinker funciona**. Si Tinker falla con `Class "BookStack\Users\Models\User" not found`, la versión exacta del namespace varía entre _major releases_ — consultar `app/Users/Models/User.php` dentro de `/config/www/app/Users/Models/User.php` para confirmar el namespace de la versión instalada.

### Reset de MFA (si el operador perdió el TOTP y el recovery code)

```bash
docker exec -it -u abc bookstack php /app/www/artisan tinker
# >>> $u = \BookStack\Users\Models\User::where('email', 'operador@homelab')->first();
# >>> $u->mfaValues()->delete();   # borra todos los métodos MFA registrados
# >>> exit
```

El usuario podrá hacer login sólo con email + password (sin MFA) hasta que vuelva a configurarlo desde `My Account → MFA`.

### El dump de Borgmatic falla con `Access denied for user`

```
[dump] bookstack: FAIL
mariadb-dump: Got error: 1045: Access denied for user 'bookstack'@'localhost'
```

Causa: el _hook_ está intentando autenticarse como `bookstack` (usuario), pero `mariadb-dump --routines --triggers` requiere privilegios extra (`PROCESS`, `LOCK TABLES`, etc.) que el usuario `bookstack` no tiene. La línea preparada en `docs/07-backups/02-borgmatic.md` autenticaba como **`root`**:

```bash
mariadb-dump --single-transaction --routines --triggers \
    -u root -p"${BS_DB_ROOT_PASS}" bookstack
```

Pero el helper `dump_mariadb` de `docs/07-backups/03-backup-docker-volumes.md` autentica con `MYSQL_USER`/`MYSQL_PASSWORD` (el usuario `bookstack`). Los `--routines --triggers` requieren `PROCESS` que el usuario no tiene por defecto. Soluciones:

**Opción A — usar root en el helper (recomendado, simétrico con Nextcloud)**: editar `dump_mariadb` (en `~/homelab/backups/borgmatic/hooks/dump-databases.sh`) para que use `MYSQL_ROOT_PASSWORD` en vez de `MYSQL_PASSWORD`. **Atención**: esto afecta también al dump de Nextcloud — confirmar que ambos `.env` exportan `MYSQL_ROOT_PASSWORD` con el mismo nombre.

**Opción B — conceder `PROCESS` al usuario `bookstack`** (sólo en este `bookstack-db`):
```bash
docker exec -i -e MYSQL_PWD="$(grep ^MYSQL_ROOT_PASSWORD ~/homelab/productividad/.env | cut -d= -f2)" \
    bookstack-db mariadb -uroot -e "GRANT PROCESS ON *.* TO 'bookstack'@'%'; FLUSH PRIVILEGES;"
```

La opción B es más quirúrgica; la opción A es la convención del proyecto si se aplica a todos los `dump_mariadb`. Decidir según preferencia del operador y dejar el cambio documentado en `docs/07-backups/03-backup-docker-volumes.md`.

### `Search engine is broken` o búsqueda muy lenta

Bookstack usa `FULLTEXT` index en MariaDB. Si la búsqueda no devuelve resultados o tarda más de 5 segundos en una BD pequeña, el índice puede estar desincronizado:

```bash
docker exec -it -u abc bookstack php /app/www/artisan bookstack:regenerate-search
# Regenerated search for X books, Y chapters, Z pages
```

Ese comando reconstruye el índice `search_terms`. Para BDs grandes puede tardar minutos.

### Mover el _stack_ a otra Pi (DR scenario)

1. En la Pi nueva: instalar Pi OS, Docker, montar hd2t, restaurar `~/homelab/` (git clone + `.env` desde la copia papel/Vaultwarden).
2. Restaurar `/mnt/hd2t/services/bookstack/config/` desde Borgmatic.
3. Crear `/mnt/hd2t/services/bookstack/db/` vacío.
4. Levantar el _stack_ con `make up STACK=productividad`.
5. Esperar a `bookstack-db (healthy)`, después importar el dump SQL más reciente (ver **Backup → Restauración**).
6. Levantar `bookstack`.
7. Verificar.

> **Crítico**: el `APP_KEY` en el `.env` restaurado **debe ser el mismo** que el que se usó cuando se generaron los datos cifrados de la BD (settings, sesiones). Si el `.env` se perdió y sólo hay backup de `config/www/.env`, leer el `APP_KEY` de ahí (es el mismo, lo escribió el entrypoint LS) y usarlo en el `.env` del _stack_ — **no** regenerar uno nuevo o se pierden los _settings_ cifrados (ver **Decisiones de diseño** → _APP_KEY_).

---

## SMTP opcional

Bookstack funciona sin SMTP, pero algunas funcionalidades quedan limitadas:

- **Invitar a un usuario nuevo**: sin SMTP, hay que crear la cuenta a mano desde `Settings → Users → Add User` y pasarle la password al usuario por canal seguro (Vaultwarden Send, Signal). Con SMTP, `Send invite` envía un email de alta donde el usuario fija su propia password.
- **Recuperación de password** del usuario olvidadizo: sin SMTP, el _link de reset_ no se envía y la única ruta es el reset desde tinker (descrito en **Troubleshooting**) o desde otro admin.
- **Notificaciones**: por defecto Bookstack envía un email cuando alguien comenta una página (si las notificaciones están suscritas). Sin SMTP, los comentarios funcionan, pero el suscriptor no recibe nada.

Para activar, descomentar el bloque correspondiente del `~/homelab/productividad/.env`:

```bash
MAIL_HOST=smtp.tu-proveedor.com
MAIL_PORT=587
MAIL_USERNAME=tu-cuenta-smtp
MAIL_PASSWORD=tu-password-de-aplicacion
MAIL_ENCRYPTION=tls
MAIL_FROM=bookstack@tu-dominio.example
MAIL_FROM_NAME=Bookstack
```

…y descomentar el bloque correspondiente del `docker-compose.yml`. Reiniciar:

```bash
docker compose -f ~/homelab/productividad/docker-compose.yml up -d bookstack
```

Probar desde la propia UI: `Settings → Maintenance → Send a test email → input email del operador`. Bookstack envía un mail. Si falla, los detalles aparecen en `docker logs bookstack`.

> **Por qué `tls` (STARTTLS) y no `ssl`**: la mayoría de proveedores (Gmail, Outlook, Mailgun, ProtonMail Bridge, Postmark) ofrecen STARTTLS en `:587`. `ssl` (TLS directo) sólo en `:465`. Si el proveedor exige `:465`, cambiar `MAIL_PORT=465` y `MAIL_ENCRYPTION=ssl`.

> **App passwords de Gmail / iCloud**: igual que en Vaultwarden, ambos requieren generar una "app password" específica (las credenciales normales de la cuenta no funcionan con SMTP desde 2022). Crear desde el portal del proveedor.

---

## Migrar a OIDC con Authelia (opcional, futuro)

Bookstack soporta **OIDC nativo desde 22.10** vía `AUTH_METHOD=oidc`. La integración con Authelia (`docs/04-seguridad/01-authelia.md`) consiste en:

1. **Registrar un cliente OIDC en Authelia**: añadir al `configuration.yml` de Authelia un nuevo `identity_providers.oidc.clients[]` con:
   - `id: bookstack`
   - `secret: $argon2id$<hash>` (generado con `authelia crypto hash generate argon2`)
   - `redirect_uris: [https://bookstack.lan/oidc/callback]`
   - `scopes: [openid, profile, email, groups]`
   - `userinfo_signing_algorithm: none`
2. **Configurar Bookstack** añadiendo al `~/homelab/productividad/.env`:
   ```bash
   AUTH_METHOD=oidc
   OIDC_NAME=Authelia
   OIDC_DISPLAY_NAME_CLAIMS=name
   OIDC_CLIENT_ID=bookstack
   OIDC_CLIENT_SECRET=<el secret en plano, NO el hash>
   OIDC_ISSUER=https://auth.lan
   OIDC_ISSUER_DISCOVER=true
   OIDC_USER_TO_GROUPS=true
   OIDC_GROUPS_CLAIM=groups
   OIDC_REMOVE_FROM_GROUPS=true
   ```
3. **Mapear roles** de Authelia (definidos en `users_database.yml`) a roles de Bookstack: si en Authelia el usuario operador tiene `groups: [admin, operator]`, esos grupos se traducen a roles Bookstack del mismo nombre (que el operador debe haber creado previamente desde `Settings → Roles`).
4. Reiniciar Bookstack: `docker compose up -d bookstack`.
5. Probar el login desde un navegador limpio: `https://bookstack.lan/login` muestra ahora el botón "Sign in with Authelia"; al pulsar, redirige a `https://auth.lan/?rd=...`, el operador hace su login + 2FA en Authelia, vuelve a Bookstack y entra ya autenticado.

**No** se aplica en este documento porque:

- El operador único del homelab (y posiblemente la familia) no se beneficia mucho del SSO: ya hay 2FA TOTP nativo en Bookstack, y el _login_ con email + password ya está unificado en gestores de password (Vaultwarden lo hace por todos los servicios).
- OIDC añade una **dependencia operativa**: si Authelia se cae, Bookstack queda inaccesible aunque la propia app esté `(healthy)`. La opción nativa (email + password) sigue funcionando sin cadenas de dependencia. En un homelab que prioriza simplicidad, mantener autenticación local es defensible.
- Una vez OIDC está activo, los usuarios creados con autenticación local **conviven** con los OIDC (`AUTH_METHOD=oidc` no rompe los locales si se mantiene la opción `oidc.local_login_enabled=true`); pero la migración requiere _renombrar_ los usuarios para que el `email` coincida con el `claim sub` que envía Authelia. Operación factible pero propensa a errores.

Si en el futuro la familia crece y la unificación de login pasa a justificar la complejidad: la migración es **incremental** (se puede activar OIDC manteniendo login local en paralelo, migrar usuarios uno a uno, y al final apagar el local con `AUTH_METHOD=oidc + local_login_enabled=false`).

---

## Referencias

- Documentación oficial de Bookstack: <https://www.bookstackapp.com/docs/>
  - Variables de configuración: <https://www.bookstackapp.com/docs/admin/configuration/>
  - Reverse proxy: <https://www.bookstackapp.com/docs/admin/proxy-setup/>
  - OIDC / SSO: <https://www.bookstackapp.com/docs/admin/oidc-auth/>
  - API REST: <https://demo.bookstackapp.com/api/docs>
  - MFA y recuperación: <https://www.bookstackapp.com/docs/admin/mfa-setup/>
- Imagen Docker LinuxServer.io: <https://docs.linuxserver.io/images/docker-bookstack/>
- Imagen Docker oficial de MariaDB: <https://hub.docker.com/_/mariadb>
- LinuxServer.io — `PUID`/`PGID` y volúmenes: <https://docs.linuxserver.io/general/understanding-puid-and-pgid>
- Backup de MariaDB con `--single-transaction` (Patrón M): `docs/07-backups/03-backup-docker-volumes.md` → _Patrón M_.
- Documento adyacente: `docs/11-productividad/01-vaultwarden.md` (estrenó el _stack_ `productividad`).
- Documento adyacente: `docs/06-almacenamiento/01-nextcloud.md` (mismo patrón de servicio web + MariaDB; convenciones reutilizadas aquí).
- `docs/02-docker/02-estructura-compose.md` — un compose por dominio, redes externas/internas, convenciones de _naming_.
- `docs/02-docker/04-watchtower.md` — opt-out explícito de Bookstack y MariaDB.
- `docs/03-red/04-caddy.md` — Caddy, CA local, _snippets_ `security-headers` y `logging`.
- `docs/04-seguridad/01-authelia.md` — por qué Bookstack **no** entra hoy en `forward_auth`; cómo migraría a OIDC en el futuro.
- `docs/07-backups/01-estrategia-backup.md` — Categoría A (documentación operativa propia) + Patrón M.
- `docs/07-backups/02-borgmatic.md` — `before_backup` y `dump-databases.sh`.
- `docs/07-backups/03-backup-docker-volumes.md` — bloque del helper `dump_mariadb` y línea Bookstack que aquí se descomenta.
