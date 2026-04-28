# Nextcloud

## Descripción

Cerrada la Fase 5, el homelab tiene una pila de observabilidad madura (Prometheus + Grafana + Node Exporter + cAdvisor + Uptime Kuma + Dozzle), pero sigue siendo, en lo esencial, una caja que **monitoriza otras cajas**: no almacena nada propio del operador. La Fase 6 cambia eso: introduce los servicios que convierten la Pi en el "disco duro de la casa". El primero y más importante es **Nextcloud**.

Este documento despliega **Nextcloud** como suite de almacenamiento personal, con foco en sincronización de ficheros, calendario (CalDAV), contactos (CardDAV), tareas y notas. Su rol concreto en el homelab:

1. **Sustituir servicios de nube comercial** (Drive, iCloud, Dropbox) para los miembros del hogar: ficheros sincronizados desde portátil, móvil y tablet contra `https://cloud.${DOMAIN_LAN}`, sin que un solo byte salga de la LAN o, en su caso, del tailnet.
2. **Hospedar un calendario y libreta de contactos compartida** que clientes nativos (Apple Calendar, GNOME Evolution, DAVx5 en Android, Thunderbird) consumen vía CalDAV/CardDAV con auth básica sobre HTTPS.
3. **Servir como puerta de entrada a otros datos del hogar** vía la app *External Storage* (lectura de carpetas concretas de `hd2t` que ya están alimentadas por Samba o Syncthing en `02-samba.md` y `03-syncthing.md`). Esa integración se cubre allí; aquí Nextcloud queda **listo** para recibir external storage, no se conecta nada todavía.
4. **Persistir datos en `hd2t`**: los ficheros de usuarios y la base de datos PostgreSQL viven en `/mnt/hd2t/apps/nextcloud/`, fuera de la microSD por durabilidad y rendimiento. La Pi 5 ofrece USB 3.0 con holgura de IOPS para SQLite y PostgreSQL.

La pila se compone de **tres contenedores** orquestados desde un único `docker-compose.yml`:

- `nextcloud` — imagen oficial `nextcloud:30-apache` (PHP + Apache embebido), expone `:80` en la red Docker.
- `nextcloud-db` — PostgreSQL 16 (imagen oficial `postgres:16-alpine`), no publicada al host.
- `nextcloud-redis` — Redis 7 (imagen oficial `redis:7-alpine`) para *file locking* transaccional y *memcache.distributed*.

Lo que este documento **no** decide:

- **Nextcloud Office** (Collabora Online o OnlyOffice). Edición colaborativa de documentos requiere otro contenedor pesado y memoria que la Pi 5 puede asumir solo a costa de otros stacks. Reabrible en una Fase posterior si se identifica caso de uso real.
- **Nextcloud Talk con HPB** (High Performance Backend con `nats-server` y `signaling`). El Talk básico (chat + 1:1 audio) viene de serie y se documenta como app recomendada; el HPB para llamadas grupales SFU se descarta hoy: el hardware no da y los miembros del hogar ya tienen WhatsApp/Telegram para esa necesidad.
- **Memories** (app con reconocimiento facial e IA). Requiere GPU o tiempo de CPU significativo en background; reabrible si se decide dedicar CPU a ello.
- **Backend de almacenamiento primario en S3/MinIO** (`OBJECTSTORE_S3_*`). Convierte Nextcloud en stateless de cara al operador, pero cambia radicalmente el modelo de backup y consume MinIO (`04-minio.md`) como dependencia dura. Reabrible cuando MinIO esté operativo y la cantidad de ficheros lo justifique; hoy gana la simplicidad de almacenamiento en filesystem.
- **LDAP/SAML/OIDC** para autenticación contra Authelia. Decisión profundamente discutida más abajo: **Nextcloud queda con su autenticación nativa** y 2FA TOTP propio, no detrás del `forward_auth` de Authelia. La razón corta es WebDAV; la larga, en la sección dedicada.
- **Federación con otros Nextcloud** (`Federation` app). Sin instancias amigas; reabrible si en el futuro hay un segundo nodo familiar.
- **Preview generator masivo**, *full-text search* con Elasticsearch, *workflow* engine. Sobreingeniería para 1–3 usuarios.
- **Migrar a Nextcloud AIO**. La distribución *All-In-One* es opinionada, monta su propio reverse proxy y se solapa con Caddy/Authelia. Se descarta.

Cuando este documento se haya aplicado, el operador puede:

- Abrir `https://cloud.${DOMAIN_LAN}/` desde la LAN (con la CA interna instalada), iniciar sesión con la cuenta de admin y ver el dashboard de Nextcloud sin formularios intermedios.
- Configurar el cliente de escritorio y móvil contra `cloud.lan` (LAN) o `cloud.tailnet.ts.net` (Tailscale) y sincronizar una carpeta.
- Apuntar Apple Calendar/DAVx5 contra el endpoint CalDAV (`https://cloud.lan/remote.php/dav/calendars/<user>/`) y sincronizar un calendario.
- Activar 2FA TOTP para los usuarios del hogar y, opcionalmente, forzarlo a nivel de admin.
- Ejecutar comandos `occ` desde el host con `docker exec -u www-data nextcloud php occ ...` para mantenimiento.
- Confirmar que el `cron.php` de Nextcloud se ejecuta cada 5 minutos vía cron del host (no AJAX).

> **Recordatorio de alcance**: Nextcloud, su PostgreSQL y su Redis escuchan **solo** en la red Docker `homelab`; ningún `ports:` se publica al host. El acceso humano y de clientes se hace **únicamente** vía Caddy sobre HTTPS con la CA interna del homelab. Acceso remoto, vía Tailscale (`https://cloud.${DOMAIN_TS}/`). Sin DDNS, sin Let's Encrypt, sin redirección de puertos en el router.

---

## Requisitos Previos

- **Fase 2** completa (Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN=lan`, `DOMAIN_TS` opcional para Tailscale).
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre automáticamente `cloud.${DOMAIN_LAN}` sin tocar Pi-hole).
  - Caddy desplegado y los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` en `Caddyfile`.
- **Fase 4** completa: Authelia desplegado (aunque Nextcloud **no se protege con `forward_auth`**, Authelia sigue activa para el resto del homelab y Nextcloud convive con su política `default_policy: deny`; aquí se documenta cómo añadir `cloud.${DOMAIN_LAN}` al *bypass* de Authelia para que **no** intercepte sus peticiones).
- Disco `hd2t` montado en `/mnt/hd2t` con al menos **50 GiB** libres reservados inicialmente para Nextcloud (10 GiB para la base de datos + 40 GiB de margen para datos de usuarios). Crecerá según uso real; el *cap* operativo lo marca el espacio total de `hd2t` (2 TB) menos lo reservado para otros servicios y backups.
- Operador con la **CA interna instalada** en su navegador y en los dispositivos clientes que vayan a sincronizar.

Comprobaciones rápidas:

```bash
# La red Docker compartida existe
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Caddy está corriendo y healthy
docker ps --filter name=caddy --format '{{.Names}} {{.Status}}'
# caddy   Up 2 days (healthy)

# cloud.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short cloud.lan @192.168.1.2
# 192.168.1.10

# Espacio en hd2t
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'
# 1.6T libres

# El UID 33 (www-data interno de la imagen oficial Apache) puede escribir en hd2t
# (se confirmará al crear el directorio dedicado más abajo).
```

---

## Decisión: imagen y variante

Nextcloud publica varias imágenes oficiales en Docker Hub bajo `nextcloud`:

| Variante | Qué incluye | Pros | Contras |
|---|---|---|---|
| `nextcloud:30-apache` | PHP + Apache embebido en la imagen. Un solo contenedor sirve el HTTP. | Simplicidad: un proceso, una expose, un reverse_proxy desde Caddy. | Apache es más pesado en RAM que PHP-FPM. |
| `nextcloud:30-fpm` | Solo PHP-FPM (FastCGI); requiere un nginx delante en otro contenedor. | Mayor rendimiento bajo carga concurrente alta. | Dos contenedores adicionales (fpm + nginx) y configuración acoplada. |
| `nextcloud:30-fpm-alpine` | Idem fpm, sobre Alpine. | Imagen más pequeña. | Idem fpm; además Alpine ha dado problemas históricos con extensiones PHP nativas. |
| Nextcloud AIO | Distribución "all-in-one" con master container que orquesta el resto. | Setup automatizado para principiantes. | Toma control del reverse proxy y la red; incompatible con Caddy/Authelia ya en marcha. |

| Decisión | Justificación |
|---|---|
| **`nextcloud:30-apache`** | Para 1–3 usuarios y un puñado de clientes sincronizando, la diferencia de rendimiento entre Apache y FPM+nginx es invisible. Apache simplifica a un único contenedor, evita coordinar la configuración de nginx para CalDAV/CardDAV y los redirects de `.well-known`, y mantiene el `docker-compose.yml` corto. |
| **Tag `30-apache`** (rama mayor pin) | Compromiso entre reproducibilidad y mantenimiento: las minors `30.x.y` traen parches de seguridad sin migraciones disruptivas. Subir de mayor (a `31`, `32`...) es una operación manual con `occ upgrade` y verificación de apps; se hace de forma deliberada en una iteración futura, **no** automáticamente con Watchtower. Por eso este stack queda **excluido de Watchtower** (`com.centurylinklabs.watchtower.enable: "false"` más abajo). |

> **Nunca `latest`**: Nextcloud salta de mayor cada año y un upgrade *in-place* mal hecho corrompe la base de datos. La política aquí es: el operador decide cuándo subir de mayor, lo prueba en frío y solo entonces actualiza este documento.

> **Por qué no Nextcloud AIO**. AIO es excelente para arrancar de cero sin un reverse proxy previo. Aquí Caddy lleva semanas en marcha, Authelia ya custodia la mitad de los servicios y Pi-hole ya resuelve subdominios. Adoptar AIO obligaría a desmontar todo eso. La pila clásica `app + db + redis` encaja sin fricciones.

---

## Decisión: base de datos (MariaDB vs PostgreSQL vs SQLite)

Nextcloud soporta SQLite, MySQL/MariaDB y PostgreSQL como backend.

| Backend | Pros | Contras | Veredicto |
|---|---|---|---|
| **SQLite** (default cuando no se configura nada) | Cero servicios extra; un fichero `nextcloud.db`. | La documentación oficial **desaconseja SQLite para uso compartido**: bloqueos en sincronizaciones concurrentes, rendimiento decreciente por encima de ~10 GiB de ficheros y sin réplica. | Descartado. |
| **MariaDB 10.11** | Históricamente la opción "por defecto" en la documentación de Nextcloud y en la mayoría de tutoriales. ARM64 oficial. | Migración futura a Postgres más complicada que arrancar ya en Postgres. Algunas optimizaciones de Nextcloud están más maduras en Postgres (índices, FULLTEXT, json). | Aceptable; descartado por simetría con el resto del homelab (futuras BBDD irán a Postgres). |
| **PostgreSQL 16** | Mejor rendimiento en cargas mixtas, JSON nativo, índices `db:add-missing-indices` específicos. ARM64 oficial. Es la BD que el resto de servicios del homelab tienden a usar (ver `04-seguridad/01-authelia.md`, `08-aplicaciones/...`). | Algunos plugins/apps de Nextcloud asumen MariaDB en su README; en práctica funcionan en Postgres. | **Aceptado**. |

> **Tags exactos**: `postgres:16-alpine`. Alpine para la base de datos es seguro: la imagen oficial mantiene el binario de PostgreSQL contra musl sin desviaciones funcionales conocidas y la imagen pesa ~80 MiB en vez de ~400 MiB. Las extensiones específicas de PostgreSQL que Nextcloud usa (`btree_gin`, etc.) están incluidas.

> **No usar `postgres:latest`**: idéntica regla que para Nextcloud — el upgrade de mayor de PostgreSQL **requiere** `pg_upgrade` o `pg_dumpall + restore`, nunca pasa solo. Pin a `16-alpine` y se sube manualmente.

---

## Decisión: caché Redis

Nextcloud necesita una caché de tres tipos: *local* (por proceso PHP), *distributed* (compartida entre procesos PHP) y *file locking* (transaccional). Las opciones:

| Combinación | Pros | Contras | Veredicto |
|---|---|---|---|
| Solo APCu (caché local) | Cero servicios extra. | El *file locking transaccional* (`OC\Memcache\Redis`) **no** funciona con APCu; se cae a la base de datos, lo cual es lento y bloquea más de la cuenta. | Descartado. |
| **APCu (local) + Redis (distributed + locking)** | APCu para caché por proceso (rapidísimo, sin red), Redis para lo que tiene que ser global. Es la combinación recomendada en la documentación oficial. | Un contenedor más. | **Aceptado**. |
| Solo Redis (todo, incluso local) | Una sola caché, configuración mínima. | Pierde la velocidad de APCu para acceso por proceso (cada `get` cruza la red Docker). | Descartado. |

> **Tag**: `redis:7-alpine`. Redis 7.x es la rama estable; alpine reduce la imagen sin pérdida funcional. La RAM de Redis se cap-ea con `--maxmemory 128mb --maxmemory-policy allkeys-lru` para evitar que crezca sin control en un homelab con 8 GiB totales.

> **Persistencia de Redis**: deshabilitada (`--save '' --appendonly no`). Lo que Redis cachea para Nextcloud es regenerable; reiniciar el contenedor implica que la primera petición tras el reinicio sea ligeramente más lenta. Aceptable a cambio de cero IOPS de Redis sobre el disco. El *file locking* es transaccional pero por sesión: tras un reinicio limpio no hay nada que recuperar.

---

## Decisión: autenticación (Authelia `forward_auth` vs nativa de Nextcloud)

Esta es la decisión más importante del documento.

Nextcloud expone múltiples superficies HTTP:

| Endpoint | Quién lo consume | Tipo de auth |
|---|---|---|
| `/` (UI web) | Navegadores humanos. | Sesión + cookie de Nextcloud. |
| `/login`, `/logout` | Idem. | Form POST. |
| `/remote.php/dav/...` | Clientes WebDAV (Files de escritorio, Files móvil, sincronización iOS, DAVx5, Apple Calendar, Thunderbird). | **HTTP Basic Auth** o *App Password* (token de 25 caracteres). |
| `/remote.php/webdav` | Idem (legacy). | Idem. |
| `/ocs/v2.php/...` | Apps móviles (Talk, Notes, Tasks). | Token Bearer. |
| `/.well-known/{caldav,carddav}` | Auto-discovery de Apple/Mozilla. | Redirect. |
| `/index.php/login/v2/...` | Login flow OAuth de los clientes oficiales. | Token. |

| Mecanismo | Pros | Contras | Veredicto |
|---|---|---|---|
| **`forward_auth` de Authelia delante de todo Nextcloud** | SSO con el resto del homelab, sin doble login. | Authelia responde con `302 → auth.lan/?rd=...` cuando no hay sesión. **Los clientes WebDAV y móviles no siguen ese redirect HTML**: se quedan en bucle, fallan o piden credenciales que el operador termina escribiendo en Authelia (no en Nextcloud) y entonces tampoco funcionan. Es un problema bien documentado en la comunidad. | Descartado. |
| **`forward_auth` solo en `/`** y bypass en `/remote.php`, `/ocs`, `/.well-known`, `/login` | Filtrar por `path` en Caddy. | Frágil: cualquier endpoint nuevo de Nextcloud (cada upgrade los añade) que no esté en la *whitelist* queda inaccesible para los clientes. La superficie a mantener crece para nada: la UI sigue requiriendo login de Nextcloud después de Authelia, así que el usuario hace **dos** logins. | Descartado. |
| **Auth nativa de Nextcloud** + 2FA TOTP **+ bypass total** en Authelia para `cloud.${DOMAIN_LAN}` | Compatible con todos los clientes. La 2FA TOTP es la única protección que tienen los proveedores comerciales (Proton, Drive). Combinada con *App Passwords* limita el blast radius si un dispositivo se pierde. | Ligera duplicación: TOTP en Authelia (resto del homelab) y TOTP en Nextcloud (este servicio). En la práctica se usan dos entradas en la misma app TOTP del operador. | **Aceptado**. |
| OIDC contra Authelia (servicio Authelia como IdP, Nextcloud como cliente con la app `User OIDC`) | SSO real. | Requiere activar el endpoint OIDC de Authelia (no está activado en `04-seguridad/01-authelia.md`) y la app `User OIDC` en Nextcloud (proviene de App Store, mantenimiento por su cuenta). Los clientes móviles de Nextcloud manejan OIDC con webview, lo cual ha sido históricamente inestable. | Reabrible cuando Authelia exponga OIDC y la app `User OIDC` esté madura para los clientes que el hogar usa. |

Resultado: **Nextcloud NO se protege con `forward_auth`**. En el bloque de Caddy se importa `(security_headers)` y `(healthcheck)` pero **no** se importa `(authelia_two_factor)`. Como el `default_policy` de Authelia es `deny`, hay que añadir explícitamente `cloud.${DOMAIN_LAN}` a `access_control.rules` con política `bypass` para evitar que Authelia bloquee llamadas internas de inspección. Esa entrada se añade en `configuration.yml` de Authelia (`04-seguridad/01-authelia.md` queda actualizado al aplicar este documento).

> **2FA TOTP en Nextcloud**: la app `Two-Factor TOTP Provider` (mantenida por el equipo Nextcloud) se instala desde *Apps → Security* y se activa por usuario en *Personal → Security → Two-Factor Authentication*. Como administrador, el flag `twofactor_enforced` en `config.php` puede convertirla en obligatoria. La política aquí es **obligatoria para el rol `admin` y opcional para usuarios estándar**, balanceando seguridad y la realidad del hogar.

---

## Decisión: dónde viven los datos y permisos

La imagen `nextcloud:30-apache` corre como UID `33` (`www-data`). PostgreSQL como `999` (`postgres`). Redis como `999` (`redis`).

| Subsistema | Ruta en hd2t | Owner:Group | Justificación |
|---|---|---|---|
| HTML + apps de Nextcloud | `/mnt/hd2t/apps/nextcloud/html` | `33:33` | El contenedor escribe ahí (apps instaladas vía UI, themes, etc.). |
| Datos de usuarios (ficheros sincronizados) | `/mnt/hd2t/apps/nextcloud/data` | `33:33` | El operador puede crecer este directorio sin tocar nada más. |
| `config.php` y configuración | `/mnt/hd2t/apps/nextcloud/config` | `33:33` | Editable manualmente con `docker exec`. |
| Custom apps adicionales | `/mnt/hd2t/apps/nextcloud/custom_apps` | `33:33` | Apps que no vienen del store oficial; vacío hoy. |
| Themes | `/mnt/hd2t/apps/nextcloud/themes` | `33:33` | Personalización; vacío hoy. |
| Datos de PostgreSQL | `/mnt/hd2t/apps/nextcloud/db` | `999:999` | TSDB equivalente para BD relacional. |

La estrategia: directorio raíz `/mnt/hd2t/apps/nextcloud/` con subdirectorios dedicados, cada uno con el owner correcto. La configuración (`stacks/nextcloud/.env`, `docker-compose.yml`) vive en `~/homelab/stacks/nextcloud/` con `homelab:homelab` y modo `0640` (`0600` para `.env` por contener contraseñas).

> **Por qué no microSD**. Los datos crecerán hasta cientos de GiB; PostgreSQL hace `fsync()` por commit; Nextcloud escribe `oc_filecache` continuamente al sincronizar. La SD-card de la Pi 5 no debe absorber esto. Todo va a `hd2t` con USB 3.0, suficiente para ~50 MB/s sostenidos sobre los discos externos contemplados.

---

## Stack: `stacks/nextcloud/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/nextcloud/docker-compose.yml` | microSD (git) | Stack (servicios `nextcloud`, `nextcloud-db`, `nextcloud-redis`). |
| `stacks/nextcloud/.env.example` | microSD (git) | Plantilla con `NEXTCLOUD_*`, `POSTGRES_*`, `REDIS_*`. |
| `stacks/caddy/conf.d/07-nextcloud.caddy` | microSD (git) | Drop-in del bloque LAN para `cloud.${DOMAIN_LAN}`. |
| `/mnt/hd2t/apps/nextcloud/html` | hd2t | HTML, apps oficiales, código PHP. Owner `33:33`. |
| `/mnt/hd2t/apps/nextcloud/data` | hd2t | Ficheros sincronizados de los usuarios. Owner `33:33`. |
| `/mnt/hd2t/apps/nextcloud/config` | hd2t | `config.php`, `CAN_INSTALL`, etc. Owner `33:33`. |
| `/mnt/hd2t/apps/nextcloud/custom_apps` | hd2t | Apps de terceros instaladas a mano. Owner `33:33`. |
| `/mnt/hd2t/apps/nextcloud/themes` | hd2t | Themes personalizados. Owner `33:33`. |
| `/mnt/hd2t/apps/nextcloud/db` | hd2t | Cluster de PostgreSQL. Owner `999:999`. |

### `stacks/nextcloud/docker-compose.yml`

```yaml
# Nextcloud — suite de almacenamiento personal del homelab.
# Documentado en docs/06-almacenamiento/01-nextcloud.md.

name: nextcloud

services:
  nextcloud:
    image: nextcloud:30-apache
    container_name: nextcloud
    hostname: nextcloud
    restart: unless-stopped
    depends_on:
      nextcloud-db:
        condition: service_healthy
      nextcloud-redis:
        condition: service_healthy

    # No publica `ports:` al host: solo accesible vía Caddy y vía red `homelab`.
    expose:
      - "80"

    environment:
      TZ: ${TZ}

      # --- Base de datos ---
      POSTGRES_HOST: nextcloud-db
      POSTGRES_DB: ${NEXTCLOUD_DB_NAME}
      POSTGRES_USER: ${NEXTCLOUD_DB_USER}
      POSTGRES_PASSWORD: ${NEXTCLOUD_DB_PASSWORD}

      # --- Caché Redis ---
      REDIS_HOST: nextcloud-redis
      REDIS_HOST_PORT: 6379
      REDIS_HOST_PASSWORD: ${NEXTCLOUD_REDIS_PASSWORD}

      # --- Bootstrap del admin (solo se aplica en el primer arranque) ---
      NEXTCLOUD_ADMIN_USER: ${NEXTCLOUD_ADMIN_USER}
      NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASSWORD}

      # --- Dominios y proxy ---
      NEXTCLOUD_TRUSTED_DOMAINS: "cloud.${DOMAIN_LAN} cloud.${DOMAIN_TS}"
      OVERWRITEPROTOCOL: https
      OVERWRITEHOST: "cloud.${DOMAIN_LAN}"
      OVERWRITECLIURL: "https://cloud.${DOMAIN_LAN}"
      # Caddy vive en la red `homelab` (172.30.10.0/24); confiamos en su rango.
      TRUSTED_PROXIES: "172.30.10.0/24"

      # --- PHP ---
      PHP_MEMORY_LIMIT: 512M
      PHP_UPLOAD_LIMIT: 10G

      # --- Apache ---
      # APACHE_DISABLE_REWRITE_IP: 1 — confiamos en X-Forwarded-For que envía Caddy.
      APACHE_DISABLE_REWRITE_IP: "1"

    volumes:
      - /mnt/hd2t/apps/nextcloud/html:/var/www/html
      - /mnt/hd2t/apps/nextcloud/data:/var/www/html/data
      - /mnt/hd2t/apps/nextcloud/config:/var/www/html/config
      - /mnt/hd2t/apps/nextcloud/custom_apps:/var/www/html/custom_apps
      - /mnt/hd2t/apps/nextcloud/themes:/var/www/html/themes

    networks:
      - homelab

    healthcheck:
      # /status.php devuelve un JSON con `installed: true` cuando todo está OK.
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1/status.php | grep -q '\"installed\":true' || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s   # primer arranque corre setup; puede tardar 60-90s.

    labels:
      homelab.role: "storage-suite"
      homelab.backup: "true"
      # Nextcloud NO se actualiza con Watchtower: los major bumps requieren occ upgrade manual.
      com.centurylinklabs.watchtower.enable: "false"

  nextcloud-db:
    image: postgres:16-alpine
    container_name: nextcloud-db
    hostname: nextcloud-db
    restart: unless-stopped

    expose:
      - "5432"

    environment:
      TZ: ${TZ}
      POSTGRES_DB: ${NEXTCLOUD_DB_NAME}
      POSTGRES_USER: ${NEXTCLOUD_DB_USER}
      POSTGRES_PASSWORD: ${NEXTCLOUD_DB_PASSWORD}
      # Localización para evitar warnings de PostgreSQL al inicializar el cluster.
      POSTGRES_INITDB_ARGS: "--encoding=UTF-8 --lc-collate=C --lc-ctype=C"

    volumes:
      - /mnt/hd2t/apps/nextcloud/db:/var/lib/postgresql/data

    networks:
      - homelab

    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${NEXTCLOUD_DB_USER} -d ${NEXTCLOUD_DB_NAME}"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s

    labels:
      homelab.role: "storage-suite-db"
      homelab.backup: "true"
      com.centurylinklabs.watchtower.enable: "false"

  nextcloud-redis:
    image: redis:7-alpine
    container_name: nextcloud-redis
    hostname: nextcloud-redis
    restart: unless-stopped

    expose:
      - "6379"

    # Cap de memoria + sin persistencia (caché regenerable).
    command:
      - "redis-server"
      - "--requirepass"
      - "${NEXTCLOUD_REDIS_PASSWORD}"
      - "--maxmemory"
      - "128mb"
      - "--maxmemory-policy"
      - "allkeys-lru"
      - "--save"
      - ""
      - "--appendonly"
      - "no"

    networks:
      - homelab

    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${NEXTCLOUD_REDIS_PASSWORD}", "ping"]
      interval: 15s
      timeout: 3s
      retries: 5
      start_period: 5s

    labels:
      homelab.role: "storage-suite-cache"
      homelab.backup: "false"   # caché regenerable, no se respalda.
      com.centurylinklabs.watchtower.enable: "true"

networks:
  homelab:
    external: true
```

> **Sobre `depends_on` con `condition: service_healthy`**: Nextcloud, en su primer arranque, ejecuta el `installer` PHP que se conecta a PostgreSQL. Sin el `service_healthy`, lanzar `up -d` puede pillar PostgreSQL aún inicializando el cluster y Nextcloud cae en una secuencia de errores difícil de leer. La condición `service_healthy` (que se basa en el `pg_isready` del propio healthcheck del contenedor `nextcloud-db`) garantiza que el orden es correcto.

> **Sobre `OVERWRITEPROTOCOL=https`**: sin esta variable, Nextcloud detecta `http` (porque Caddy le habla por HTTP en la red Docker) y genera enlaces internos `http://cloud.lan/...` que el navegador rechaza por mixed content. La variable fuerza a Nextcloud a generar URLs `https://` siempre.

> **Sobre `TRUSTED_PROXIES=172.30.10.0/24`**: Nextcloud usa esta lista para decidir si confiar en `X-Forwarded-For` y `X-Forwarded-Proto`. Sin ella, los logs muestran siempre la IP del contenedor de Caddy en vez de la IP del cliente real.

> **Sobre `APACHE_DISABLE_REWRITE_IP=1`**: la imagen oficial Apache habilita `mod_remoteip` por defecto. Lo deshabilitamos porque queremos que Nextcloud (vía sus *trusted proxies*) sea quien interprete `X-Forwarded-For`. Sin esto, el rate-limiting interno y los logs ven IPs erróneas.

> **Sobre `PHP_UPLOAD_LIMIT=10G`**: el límite de subida vive en tres sitios y los tres deben coincidir: PHP (`upload_max_filesize`/`post_max_size`), el body de la request en Caddy (`request_body max_size`) y la propia configuración de Nextcloud. Aquí se fija a 10 GiB; es generoso para vídeos de móvil, fotos RAW y backups ocasionales sin abrir el flanco a abusos accidentales.

### `stacks/nextcloud/.env.example`

```bash
# stacks/nextcloud/.env.example
# Plantilla para el stack Nextcloud. Copiar a `.env` y rellenar.
# Las generales (TZ, PUID, PGID, DOMAIN_LAN, DOMAIN_TS) vienen del .env GLOBAL.

# --- Admin Nextcloud (solo se aplica en el primer arranque) ---
NEXTCLOUD_ADMIN_USER=admin
# Generar con: openssl rand -base64 24
NEXTCLOUD_ADMIN_PASSWORD=CAMBIAR_PASSWORD_FUERTE

# --- PostgreSQL ---
NEXTCLOUD_DB_NAME=nextcloud
NEXTCLOUD_DB_USER=nextcloud
# Generar con: openssl rand -base64 32
NEXTCLOUD_DB_PASSWORD=CAMBIAR_PASSWORD_FUERTE

# --- Redis ---
# Generar con: openssl rand -base64 32
NEXTCLOUD_REDIS_PASSWORD=CAMBIAR_PASSWORD_FUERTE
```

> **`.env` real, no `.env.example`**: el fichero realmente cargado por Compose es `stacks/nextcloud/.env`, generado al desplegar (`cp .env.example .env && $EDITOR .env`). El `.example` sí se versiona en git como plantilla; el `.env` con secretos **nunca**: añadir `stacks/*/.env` a `.gitignore` global del repo si no estaba ya.

### Drop-in de Caddy: `stacks/caddy/conf.d/07-nextcloud.caddy`

```caddy
# /etc/caddy/conf.d/07-nextcloud.caddy — bloque LAN para Nextcloud.
# Documentado en docs/06-almacenamiento/01-nextcloud.md.
#
# IMPORTANTE: Nextcloud NO se protege con Authelia (forward_auth) porque sus
# clientes WebDAV (Files, Calendar/Contacts, móviles) no siguen redirects HTML
# de login. La autenticación la maneja el propio Nextcloud + 2FA TOTP.
# En `configuration.yml` de Authelia, `cloud.${DOMAIN_LAN}` debe estar en
# access_control.rules con `policy: bypass`.

cloud.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Subida y descarga de ficheros grandes (vídeos, backups, RAW).
    # Coincide con PHP_UPLOAD_LIMIT del docker-compose.yml.
    request_body {
        max_size 10GB
    }

    # Auto-discovery de CalDAV/CardDAV. Apple Calendar/iOS lo usa al añadir
    # una cuenta solo con dominio raíz; sin estos redirects no encuentra
    # los endpoints de Nextcloud.
    redir /.well-known/carddav /remote.php/dav/ 301
    redir /.well-known/caldav  /remote.php/dav/ 301
    # Algunos clientes consultan webfinger / nodeinfo: pasar al backend.
    # (Nextcloud responde 404 si no existe, lo cual es válido.)

    # Bloquear acceso a rutas internas que el reverse proxy no debe servir.
    @forbidden {
        path /data/* /config/* /db_structure /.htaccess /.user.ini
        path /3rdparty/* /lib/* /templates/* /occ /console.php
    }
    respond @forbidden 404

    reverse_proxy http://nextcloud:80 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

> **Sobre los `redir` de `.well-known`**: Apple Calendar (macOS/iOS) y muchos clientes CalDAV/CardDAV consultan `https://cloud.lan/.well-known/{caldav,carddav}` antes de pedir credenciales. Nextcloud sí sirve esas rutas internamente, pero solo si el `mod_rewrite` de Apache está activo (lo está); aún así, este redir explícito a nivel de Caddy aísla la UX del cliente del comportamiento interno y evita una petición extra al backend.

> **Sobre el matcher `@forbidden`**: defensa en profundidad. Una mala configuración de `RewriteRule` o un upgrade que cambie el `.htaccess` no debería exponer `/data/`. Listar paths "siempre 404" en Caddy garantiza que esa ruta no responde nada útil **aunque** Apache se rompa.

> **Sobre `import healthcheck`**: el snippet (definido en `03-red/04-caddy.md`) responde directamente desde Caddy a `/healthz` interno, sin tocar Nextcloud. Para *liveness check* del bloque Caddy, no para Nextcloud (que tiene su propio healthcheck a nivel de contenedor).

### Crear los directorios persistentes y desplegar

```bash
# Directorios de datos: cada uno con su owner correcto.
sudo install -d -o 33  -g 33  -m 0750 /mnt/hd2t/apps/nextcloud
sudo install -d -o 33  -g 33  -m 0750 /mnt/hd2t/apps/nextcloud/html
sudo install -d -o 33  -g 33  -m 0750 /mnt/hd2t/apps/nextcloud/data
sudo install -d -o 33  -g 33  -m 0750 /mnt/hd2t/apps/nextcloud/config
sudo install -d -o 33  -g 33  -m 0750 /mnt/hd2t/apps/nextcloud/custom_apps
sudo install -d -o 33  -g 33  -m 0750 /mnt/hd2t/apps/nextcloud/themes
sudo install -d -o 999 -g 999 -m 0700 /mnt/hd2t/apps/nextcloud/db

# Drop-in de Caddy
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/07-nextcloud.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/07-nextcloud.caddy

# .env del stack
cd /home/homelab/homelab
cp stacks/nextcloud/.env.example stacks/nextcloud/.env
chmod 0600 stacks/nextcloud/.env
$EDITOR stacks/nextcloud/.env   # rellenar con `openssl rand -base64 32`

# Añadir cloud.${DOMAIN_LAN} con `policy: bypass` en Authelia
# (configuration.yml — Authelia recarga en caliente con watch: true).
sudo $EDITOR /mnt/hd2t/apps/authelia/config/configuration.yml
docker logs authelia --tail 20 | grep -i 'reloaded'

# Validar la sintaxis del Caddyfile antes de recargarlo
docker exec caddy caddy validate --config /etc/caddy/Caddyfile

# Levantar el stack (primer arranque tarda ~90s: setup de Postgres + occ install)
docker compose \
    -f stacks/nextcloud/docker-compose.yml \
    --env-file .env --env-file stacks/nextcloud/.env \
    up -d

# Recargar Caddy para que tome el nuevo drop-in
docker kill --signal=SIGUSR1 caddy

# Esperar a que el contenedor esté healthy
docker compose -f stacks/nextcloud/docker-compose.yml ps
# nextcloud         Up 90s (healthy)
# nextcloud-db      Up 95s (healthy)
# nextcloud-redis   Up 95s (healthy)
```

Tras `up -d`, los logs del primer arranque se parecen a:

```bash
docker compose -f stacks/nextcloud/docker-compose.yml logs --tail 50 nextcloud
# ... New nextcloud instance
# ... Initializing Nextcloud 30.x.y ...
# ... Starting nextcloud installation
# ... Nextcloud was successfully installed
# ... Initializing finished
# ... apache2 -DFOREGROUND
```

---

## Configuración

### 1) Acceso al portal e inicio de sesión inicial

Desde un cliente de la LAN con la CA interna ya instalada:

```text
1. Abrir https://cloud.lan/
2. Caddy sirve directamente el HTML de Nextcloud (sin redirect a Authelia,
   porque cloud.lan está en `bypass`).
3. Login con NEXTCLOUD_ADMIN_USER + NEXTCLOUD_ADMIN_PASSWORD del .env.
4. Aterriza en el dashboard de Nextcloud (Files, Activity, Photos, ...).
```

### 2) Habilitar 2FA TOTP (obligatorio para admin)

```text
1. Apps → Categoría "Security" → buscar "Two-Factor TOTP Provider".
2. Click en "Download and enable". Esperar a que termine.
3. (Como admin) Personal settings → Security → Two-Factor Authentication
   → "Activate TOTP" → escanear QR con la app TOTP del operador (la misma
   que ya guarda los códigos de Authelia).
4. Confirmar con un código TOTP. La cuenta queda con 2FA obligatorio.
5. Como administrador, opcionalmente forzar 2FA para todos:
   docker exec -u www-data nextcloud php occ twofactorauth:enforce --on
   docker exec -u www-data nextcloud php occ twofactorauth:enforce --on \
       --group=admin    # solo para administradores
```

### 3) `db:add-missing-indices` (mejorar rendimiento)

Tras la instalación, Nextcloud puede recomendar añadir índices que la versión actual creó. Es un *one-shot*:

```bash
docker exec -u www-data nextcloud php occ db:add-missing-indices
# Adding additional ... index to the oc_share table, this can take some time...
# Adding additional ... index to the oc_filecache table, this can take some time...
# ...
```

Idéntico para `db:add-missing-columns`, `db:add-missing-primary-keys` y `db:convert-filecache-bigint` (este último puede pedir entrar en modo mantenimiento; ver siguiente sección).

### 4) Modo mantenimiento

Cualquier operación destructiva o larga (upgrades, migraciones, reparación de filecache) requiere modo mantenimiento. La UI muestra "Nextcloud is in maintenance mode" durante ese tiempo:

```bash
docker exec -u www-data nextcloud php occ maintenance:mode --on
# ... operación delicada ...
docker exec -u www-data nextcloud php occ maintenance:mode --off
```

### 5) Cron del sistema en lugar de AJAX

Nextcloud tiene tres modos para ejecutar tareas en background:

| Modo | Pros | Contras | Veredicto |
|---|---|---|---|
| AJAX | Cero configuración. | Tareas se disparan al cargar páginas; un usuario silencioso = tareas atrasadas. | Descartado. |
| Webcron | Pulse externo. | Otra dependencia HTTP. | Descartado. |
| **Cron** del sistema | Predecible, ejecuta cada 5 minutos sin depender de tráfico humano. | Requiere una entrada en el cron del host. | **Aceptado**. |

Activar el modo "Cron" en `Settings → Administration → Basic settings → Background jobs`, y crear la entrada en el host:

```bash
# Editar el cron del usuario `homelab` (que está en el grupo `docker`).
crontab -e
```

Añadir:

```cron
# Nextcloud — ejecutar tareas en background cada 5 minutos.
*/5 * * * * docker exec -u www-data nextcloud php -f /var/www/html/cron.php > /dev/null 2>&1
```

Verificar al cabo de unos minutos:

```bash
# El último job debería ser hace <5 min.
docker exec -u www-data nextcloud php occ background:cron
# (idempotente; configura el modo, no dispara nada)

docker exec -u www-data nextcloud php occ system:cron:lastrun
# 2025-04-28 09:35:04
```

### 6) Apps recomendadas para el homelab

Instalar desde `Apps`:

| App | Categoría | Para qué |
|---|---|---|
| **Two-Factor TOTP Provider** | Security | Ya cubierto en (2). Obligatorio. |
| **Calendar** | Office & text | CalDAV server + UI de calendario. |
| **Contacts** | Office & text | CardDAV server + libreta. |
| **Tasks** | Office & text | Tareas (compatible con Apple Reminders, Tasks de DAVx5). |
| **Notes** | Office & text | Markdown notes; sync con Notes de Nextcloud (móvil). |
| **Mail** | Office & text | Cliente IMAP (opcional). |
| **External storage support** | Files | Habilita montar carpetas locales/SMB/SFTP. Útil para `02-samba.md`. |
| **Recognize** | Multimedia | Reconocimiento básico de objetos en fotos (CPU only). Opcional, costoso en background. |

> **Brute-force throttling para LAN**: por defecto Nextcloud hace *throttling* tras varios intentos fallidos. En LAN, un IP del rango `192.168.x.x` o `172.30.10.x` (Docker) puede caer en penalización si un cliente sincroniza con tokens caducados. Whitelist:
> ```bash
> docker exec -u www-data nextcloud php occ config:system:set \
>     trusted_proxies 0 --value=172.30.10.0/24
> docker exec -u www-data nextcloud php occ config:system:set \
>     bruteforce.whitelist.0 --value=192.168.0.0/16
> docker exec -u www-data nextcloud php occ config:system:set \
>     bruteforce.whitelist.1 --value=172.30.10.0/24
> ```

### 7) Ajustes finales recomendados

| Ajuste | Comando |
|---|---|
| Phone region por defecto (para validar números de teléfono en perfiles) | `docker exec -u www-data nextcloud php occ config:system:set default_phone_region --value=ES` |
| Idioma por defecto | `docker exec -u www-data nextcloud php occ config:system:set default_language --value=es` |
| Locale | `docker exec -u www-data nextcloud php occ config:system:set default_locale --value=es_ES` |
| Log level (info en producción) | `docker exec -u www-data nextcloud php occ config:system:set loglevel --value=2` |
| Log timezone | `docker exec -u www-data nextcloud php occ config:system:set logtimezone --value=Europe/Madrid` |
| Memcache APCu (local) + Redis (distributed + locking) | (la imagen oficial lo configura solo si `REDIS_HOST` está definido; verificar) |

Verificar la configuración de caché:

```bash
docker exec -u www-data nextcloud php occ config:list system | \
    grep -A2 -E '"memcache.local"|"memcache.distributed"|"memcache.locking"|"redis"'
# "memcache.local": "\\OC\\Memcache\\APCu",
# "memcache.distributed": "\\OC\\Memcache\\Redis",
# "memcache.locking": "\\OC\\Memcache\\Redis",
# "redis": { "host": "nextcloud-redis", "port": 6379, "password": "..." }
```

### 8) Operación diaria

| Acción | Comando |
|---|---|
| Estado general | `https://cloud.lan/settings/admin/overview` |
| Modo mantenimiento on/off | `docker exec -u www-data nextcloud php occ maintenance:mode --on|--off` |
| Listar usuarios | `docker exec -u www-data nextcloud php occ user:list` |
| Crear usuario | `docker exec -u www-data nextcloud php occ user:add <login>` |
| Reiniciar el stack | `docker compose -f stacks/nextcloud/docker-compose.yml restart` |
| Ver logs de la app (no del contenedor) | `docker exec -u www-data nextcloud tail -F /var/www/html/data/nextcloud.log` |
| Conexión a la BD para queries ad-hoc | `docker exec -it nextcloud-db psql -U $NEXTCLOUD_DB_USER -d $NEXTCLOUD_DB_NAME` |
| Tamaño actual de los datos | `du -sh /mnt/hd2t/apps/nextcloud/data/` |
| Tamaño de la BD | `du -sh /mnt/hd2t/apps/nextcloud/db/` |

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/nextcloud/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/nextcloud/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/nextcloud/.env` | microSD | `homelab:homelab` | `0600` | Secretos (NO en git). |
| `/home/homelab/homelab/stacks/caddy/conf.d/07-nextcloud.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy. |
| `/mnt/hd2t/apps/nextcloud/html/` | hd2t | `33:33` (`www-data`) | `0750` | Código PHP, apps oficiales, themes mergeados. |
| `/mnt/hd2t/apps/nextcloud/data/` | hd2t | `33:33` | `0750` | **Ficheros de los usuarios**. Es el directorio que más crece. |
| `/mnt/hd2t/apps/nextcloud/data/<user>/files/` | hd2t | `33:33` | `0750` | Espacio de cada usuario. |
| `/mnt/hd2t/apps/nextcloud/data/nextcloud.log` | hd2t | `33:33` | `0640` | Log de la aplicación; rotado por la propia Nextcloud cuando supera 100 MiB. |
| `/mnt/hd2t/apps/nextcloud/config/config.php` | hd2t | `33:33` | `0640` | Configuración persistente (DB, redis, trusted_domains). |
| `/mnt/hd2t/apps/nextcloud/custom_apps/` | hd2t | `33:33` | `0750` | Apps de terceros instaladas a mano. Vacío hoy. |
| `/mnt/hd2t/apps/nextcloud/themes/` | hd2t | `33:33` | `0750` | Themes personalizados. Vacío hoy. |
| `/mnt/hd2t/apps/nextcloud/db/` | hd2t | `999:999` (`postgres`) | `0700` | Cluster de PostgreSQL. |

> **Tamaño esperado**. Tras instalación: `html` ≈ 700 MiB, `db` ≈ 200 MiB (esquema vacío + caché de PHP). El crecimiento real lo marca `data/`. Una sincronización típica de un portátil con documentos + fotos suele asentarse entre 50 y 300 GiB. Vídeo + RAW pueden subirlo a TBs rápidamente.

> **Por qué la fragmentación de directorios**. Tener `html`, `config`, `custom_apps`, `themes` en bind mounts separados (en vez de un solo volumen `/var/www/html`) permite a Borg respaldar `config` con frecuencia (cambios pequeños) y `data` con calendario distinto (volumen grande, cambios constantes), lo cual reduce el tamaño del repositorio Borg y los tiempos de prune.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/nextcloud/docker-compose.yml`, `.env.example` | Versionados. |
| `stacks/nextcloud/.env` | **NO** versionado (contiene `NEXTCLOUD_ADMIN_PASSWORD`, `NEXTCLOUD_DB_PASSWORD`, `NEXTCLOUD_REDIS_PASSWORD`); incluido en `.gitignore`. |
| `stacks/caddy/conf.d/07-nextcloud.caddy` | Versionado. |
| Decisiones (Apache vs FPM, Postgres vs MariaDB, no-Authelia, 2FA TOTP nativo) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Estrategia | Por qué |
|---|---|---|---|
| `/mnt/hd2t/apps/nextcloud/config/` | Sí. | Diaria. | Configuración crítica (`config.php`, secretos del install). Sin esto, restaurar `data` es inservible. |
| `/mnt/hd2t/apps/nextcloud/html/` | Sí. | Semanal. | Apps instaladas, themes; reproducible reinstalando, pero respaldarlo acelera el restore. |
| `/mnt/hd2t/apps/nextcloud/custom_apps/` | Sí. | Semanal. | Apps no oficiales que pudieran no estar disponibles en el store en el futuro. |
| `/mnt/hd2t/apps/nextcloud/themes/` | Sí. | Semanal. | Personalizaciones que no son reproducibles. |
| `/mnt/hd2t/apps/nextcloud/data/` | Sí. | Diaria, **incremental** (Borg deduplica). | **Datos de los usuarios.** Pérdida = pérdida total para el operador. Imposible reconstruir. |
| `/mnt/hd2t/apps/nextcloud/db/` (cluster PostgreSQL) | **No** directamente; sí vía dump. | Hook pre-backup en Borgmatic: `pg_dumpall -c -U <user>` a un fichero `.sql.gz` que sí entra al repo Borg. | Respaldar el cluster PostgreSQL "en caliente" produce backups inconsistentes. El dump es atómico y garantiza restore reproducible. |
| `/mnt/hd2t/apps/nextcloud/data/<user>/cache/` y `*.tmp` | **No.** | Excluido. | Regenerable. |
| Volumen `nextcloud-redis` | **No** (no hay datos persistentes; AOF/RDB deshabilitados). | — | La caché es regenerable; la pérdida solo implica latencia ligeramente mayor en la primera petición tras restore. |

> **Procedimiento de dump consistente** (a integrar en `07-backups/02-borgmatic.md` como hook):
>
> ```bash
> # Hook pre-backup
> docker exec -u www-data nextcloud php occ maintenance:mode --on
> docker exec nextcloud-db pg_dumpall -c -U "$NEXTCLOUD_DB_USER" \
>     | gzip > /mnt/hd2t/apps/nextcloud/db-dump-latest.sql.gz
>
> # Borg corre y respalda /mnt/hd2t/apps/nextcloud/{data,config,html,custom_apps,themes,db-dump-latest.sql.gz}
>
> # Hook post-backup
> docker exec -u www-data nextcloud php occ maintenance:mode --off
> ```
>
> El modo mantenimiento durante el dump garantiza que no llegan escrituras nuevas mientras `pg_dumpall` y Borg leen `data/`. El downtime típico es <2 minutos para el dump + el tiempo de Borg (incremental, segundos a minutos según delta).

> **Política de retención**: la decisión vive en `07-backups/01-estrategia-backup.md`. Recomendación de partida para Nextcloud: 7 daily, 4 weekly, 6 monthly.

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/nextcloud/docker-compose.yml \
    up -d --force-recreate
# Nextcloud reusa /mnt/hd2t/apps/nextcloud/{html,data,config}; PostgreSQL reusa db/.
# Tras ~30s de healthcheck, todo vuelve a `healthy` sin pérdida.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear Fase 1, 2, 3 y 4.
2. Restaurar `/mnt/hd2t/apps/nextcloud/{config,html,data,custom_apps,themes,db-dump-latest.sql.gz}` desde Borg.
3. Recrear `/mnt/hd2t/apps/nextcloud/db/` con `chown 999:999`.
4. Levantar **solo** el servicio `nextcloud-db`, esperar `healthy`, y restaurar el dump:
   ```bash
   docker compose -f stacks/nextcloud/docker-compose.yml up -d nextcloud-db
   gunzip -c /mnt/hd2t/apps/nextcloud/db-dump-latest.sql.gz | \
       docker exec -i nextcloud-db psql -U "$NEXTCLOUD_DB_USER" -d postgres
   ```
5. Levantar el resto: `docker compose -f stacks/nextcloud/docker-compose.yml up -d`.
6. Salir del modo mantenimiento si quedó on: `docker exec -u www-data nextcloud php occ maintenance:mode --off`.
7. Re-añadir trusted_domains si es necesario y verificar `https://cloud.lan/`.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `Access through untrusted domain` al abrir `https://cloud.lan/` | `cloud.${DOMAIN_LAN}` no está en `NEXTCLOUD_TRUSTED_DOMAINS`. | Añadirlo al `.env`, recrear el contenedor (`docker compose up -d`), o ajustar via occ: `docker exec -u www-data nextcloud php occ config:system:set trusted_domains 1 --value=cloud.lan`. |
| Bucle infinito de redirects entre `cloud.lan/login` y `cloud.lan/` | `OVERWRITEPROTOCOL` o `OVERWRITEHOST` mal seteados; Nextcloud genera `http://` y el navegador insiste en `https://`. | Verificar variables; recrear contenedor. |
| Mixed content (assets cargan como `http://`) | Idem anterior; o `TRUSTED_PROXIES` no incluye al rango de Caddy. | Asegurar `TRUSTED_PROXIES=172.30.10.0/24` y `OVERWRITEPROTOCOL=https`. |
| Cliente WebDAV (DAVx5, Apple) recibe `302` y bucle al sincronizar | Authelia está interceptando `cloud.lan` (la regla `bypass` no se aplicó). | Editar `configuration.yml` de Authelia, añadir entrada `policy: bypass` para `domain: cloud.${DOMAIN_LAN}`, esperar reload (~5 s) y reintentar. |
| Subida de fichero de >2 GiB falla | `request_body max_size` de Caddy o `PHP_UPLOAD_LIMIT` por debajo del tamaño. | Ambos a 10 GiB en este documento; comprobar con `docker exec nextcloud php -i | grep upload`. |
| `php-fpm` o `apache2` consumen 100% CPU sostenido en Pi 5 | Búsqueda de previews masiva, o un cliente sincronizando un árbol enorme de golpe. | Verificar logs de actividad; si es preview generation, considerar limitar con `occ preview:cleanup`. Bajar `PHP_MEMORY_LIMIT` no ayuda; es CPU. |
| `PostgreSQL connection refused` en logs de Nextcloud al primer arranque | El healthcheck de `nextcloud-db` aún no ha pasado a `healthy`. | El `depends_on: condition: service_healthy` lo soluciona; si persiste, `docker compose down && up -d` para reiniciar el orden. |
| `Redis NOAUTH Authentication required` | `REDIS_HOST_PASSWORD` en `.env` no coincide con `--requirepass` del comando de Redis. | Verificar que `NEXTCLOUD_REDIS_PASSWORD` está bien y se está sustituyendo en el `command:` y en el environment de Nextcloud. |
| `db:add-missing-indices` falla con `duplicate key`/`already exists` | Una versión anterior dejó índices a medias. | `maintenance:mode --on`, ejecutar manualmente `psql` para inspeccionar `\di+ oc_*` y borrar índices duplicados; volver a correr el comando. |
| Logs llenos de `Trusted domain error` desde la red Docker | Algún healthcheck o monitor accede vía IP del contenedor en vez del hostname. | Añadir el hostname interno (`nextcloud`) o la IP del rango `homelab` a `trusted_domains`. |
| `/data/nextcloud.log` crece sin parar | Log level `0` (Debug). | `occ config:system:set loglevel --value=2`. |
| Sincronización del cliente desktop tarda muchísimo en `Discovering ...` | Cardinalidad alta de ficheros (>100k), `oc_filecache` sin índices. | Correr `db:add-missing-indices` (sección "Configuración"). |
| `cron.php` no corre y la UI muestra "Last cron job execution: hace 2 días" | La crontab del usuario no se aplicó, o el `docker exec` falla porque el contenedor no se llama `nextcloud`. | `crontab -l`; verificar `docker exec -u www-data nextcloud php -f /var/www/html/cron.php` manualmente. |
| El usuario admin pierde la 2FA y no puede entrar | Forzaron `twofactorauth:enforce --on` antes de tener TOTP configurado. | Acceso de emergencia: `docker exec -u www-data nextcloud php occ twofactorauth:disable <admin_user> totp_provider`; entrar; reconfigurar; volver a habilitar. |
| Tras reiniciar el host, Nextcloud está en *maintenance mode* permanente | Un dump anterior dejó `maintenance: true` en `config.php`. | `docker exec -u www-data nextcloud php occ maintenance:mode --off`. |
| `Internal Server Error` con stack trace mencionando `oc_filecache_extended` | Tabla corrupta tras un kill duro. | `occ maintenance:repair`. |

---

## Decisiones que **no** se toman en este documento

- **Authelia OIDC + app `User OIDC`** para SSO. Reabrible cuando Authelia exponga OIDC endpoints (no activado en `04-seguridad/01-authelia.md`) y la app de Nextcloud esté madura para los clientes móviles que el hogar usa.
- **Nextcloud Office** (Collabora / OnlyOffice). Otro contenedor pesado que la Pi 5 puede sostener solo a costa de algún otro stack; valor cuestionable para 1–3 usuarios que ya editan en local.
- **Nextcloud Talk con HPB** (signaling SFU). Sin caso de uso real.
- **Memories** (reconocimiento facial / clasificación con IA). CPU intensivo; reabrible si se decide invertir CPU en background tasks de Nextcloud.
- **Recognize** se documenta como app *opcional* en sección "Apps recomendadas" pero no se activa por defecto: corre tareas de fondo significativas.
- **Backend de almacenamiento en S3/MinIO** (`OBJECTSTORE_S3_*`). Reabrible cuando MinIO (`04-minio.md`) esté operativo y la cantidad de ficheros lo justifique.
- **Full-text search** con Elasticsearch. Sobreingeniería para 1–3 usuarios.
- **Federation** con otros Nextcloud. Sin instancias amigas.
- **Auto-actualización vía Watchtower**. Excluido explícitamente: los upgrades de major requieren `occ upgrade` deliberado y prueba.
- **Preview generator masivo en background**. Genera previews de todo el contenido al instalarse; consume horas de CPU en una Pi 5. La generación on-demand (default) es suficiente.
- **Multi-tenancy** (varias organizaciones / theming por grupo). Irrelevante.
- **External storage hacia `hd5t` (multimedia Stash)**. Aunque Nextcloud queda con la app *External storage support* habilitada, el montaje real se hace cuando se documenta el flujo Stash↔Nextcloud (Fase 8 o documento específico). Hoy `hd5t` queda **fuera** del alcance de Nextcloud.
- **Brute-force throttling agresivo**. Para LAN se whitelistea el rango interno; en futuras Fases con exposición vía Tailscale se puede añadir un perfil `fail2ban` específico (`04-seguridad/02-fail2ban.md`).

---

## Verificación Final

Antes de pasar a `02-samba.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/nextcloud/docker-compose.yml ps` | `nextcloud Up (healthy)`, `nextcloud-db Up (healthy)`, `nextcloud-redis Up (healthy)` |
| Imágenes correctas y fijas | `docker inspect nextcloud nextcloud-db nextcloud-redis --format '{{.Config.Image}}'` | `nextcloud:30-apache`, `postgres:16-alpine`, `redis:7-alpine` |
| Conectados a `homelab` | `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` | incluye `nextcloud`, `nextcloud-db`, `nextcloud-redis`, `caddy` |
| Sin puertos publicados al host | `docker port nextcloud nextcloud-db nextcloud-redis` | salida vacía para los tres |
| `cloud.lan` resuelve al IP de la Pi | `dig +short cloud.lan @192.168.1.2` | `192.168.1.10` |
| Caddy sirve `cloud.lan` con cert de la CA interna | `echo \| openssl s_client -connect cloud.lan:443 -servername cloud.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| Authelia hace `bypass` para `cloud.lan` (sin `forward_auth`) | desde la LAN, `curl -ksI https://cloud.lan/login` | `HTTP/2 200` directo de Nextcloud (no `302` a `auth.lan`) |
| `status.php` responde `installed: true` | `curl -ks https://cloud.lan/status.php` | JSON con `"installed":true,"maintenance":false,"productname":"Nextcloud"` |
| `config.php` con dominios y proxy correctos | `docker exec -u www-data nextcloud php occ config:system:get trusted_domains` | array con `cloud.lan` (y `cloud.<DOMAIN_TS>` si aplica) |
| `config.php` con caché Redis | `docker exec -u www-data nextcloud php occ config:list system \| grep -i redis` | host `nextcloud-redis`, password presente |
| Cron del sistema activo | `crontab -l \| grep cron.php` | línea con `*/5 * * * * docker exec ... cron.php` |
| Última ejecución de cron reciente | `docker exec -u www-data nextcloud php occ system:cron:lastrun` | timestamp <10 minutos |
| Owner correcto de los datos | `stat -c '%u:%g' /mnt/hd2t/apps/nextcloud/data` | `33:33` |
| Owner correcto de la BD | `stat -c '%u:%g' /mnt/hd2t/apps/nextcloud/db` | `999:999` |
| Login admin con 2FA | navegador con CA instalada → `https://cloud.lan/` → user + password + TOTP | dashboard de Nextcloud carga sin error |
| App "Two-Factor TOTP Provider" instalada y habilitada | `docker exec -u www-data nextcloud php occ app:list \| grep totp` | `twofactor_totp` listado bajo "Enabled" |
| `db:add-missing-indices` ya aplicado | `docker exec -u www-data nextcloud php occ db:add-missing-indices` | `Done.` sin nuevos índices que añadir |
| `pg_isready` desde el contenedor de la BD | `docker exec nextcloud-db pg_isready -U $NEXTCLOUD_DB_USER` | `accepting connections` |
| Cliente desktop sincroniza | configurar Nextcloud Desktop (CA instalada) contra `https://cloud.lan/` | la primera carpeta sincroniza sin loop |
| Cliente CalDAV añade calendario | DAVx5/Apple Calendar contra `https://cloud.lan/remote.php/dav/` | calendario `Personal` aparece y sincroniza |
| Persistencia tras reboot | `sudo reboot`; al reconectar: `docker ps --filter name=nextcloud` | tres contenedores `Up ... (healthy)` sin acción manual |
| Stack en git | `git ls-files stacks/nextcloud` | `docker-compose.yml`, `.env.example` tracked; `.env` **no** tracked |

Cumplido el último punto, el homelab tiene su servicio de almacenamiento personal operativo: ficheros, calendario, contactos y tareas viven sobre `hd2t`, accesibles desde la LAN y vía Tailscale, con autenticación nativa de Nextcloud y 2FA TOTP. La siguiente puerta es **abrir esos ficheros al sistema operativo de los clientes** sin pasar por el cliente de Nextcloud: `02-samba.md` añadirá Samba con shares de carpetas concretas de `hd2t` (y opcionalmente `hd5t` para multimedia), que Windows, macOS y Linux montan como discos de red.

---

## Referencias

- [Documento siguiente: `docs/06-almacenamiento/02-samba.md`](./02-samba.md)
- [Documento relacionado: `docs/06-almacenamiento/03-syncthing.md`](./03-syncthing.md)
- [Documento relacionado: `docs/06-almacenamiento/04-minio.md`](./04-minio.md)
- [Documento relacionado: `docs/03-red/04-caddy.md`](../03-red/04-caddy.md)
- [Documento relacionado: `docs/04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)
- [Documento relacionado: `docs/02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)
- [Documento relacionado: `docs/07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
- [Nextcloud — Documentación oficial (Administration manual)](https://docs.nextcloud.com/server/latest/admin_manual/)
- [Nextcloud — Imagen Docker oficial](https://hub.docker.com/_/nextcloud)
- [Nextcloud — Reverse proxy configuration](https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/reverse_proxy_configuration.html)
- [Nextcloud — `occ` command reference](https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/occ_command.html)
- [Nextcloud — Two-Factor TOTP Provider (App Store)](https://apps.nextcloud.com/apps/twofactor_totp)
- [Nextcloud — Background jobs](https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/background_jobs_configuration.html)
- [Nextcloud — Caching configuration (APCu + Redis)](https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/caching_configuration.html)
- [PostgreSQL — Imagen Docker oficial](https://hub.docker.com/_/postgres)
- [PostgreSQL — Documentación oficial 16](https://www.postgresql.org/docs/16/)
- [Redis — Imagen Docker oficial](https://hub.docker.com/_/redis)
- [Caddy — `reverse_proxy` directive](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [DAVx5 — Cliente CalDAV/CardDAV para Android](https://www.davx5.com/)
