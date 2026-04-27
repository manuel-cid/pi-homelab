# Nextcloud (nube privada con MariaDB + Redis)

## Descripción

Despliegue de **Nextcloud** como **nube privada** del homelab: sincronización de ficheros desde escritorio (Windows/Linux/macOS) y móvil (Android/iOS), libreta de direcciones (CardDAV) y calendarios (CalDAV), galería de fotos, edición colaborativa de documentos, _client share links_ entre miembros del hogar y reemplazo "no nube pública" de Drive/Dropbox/iCloud para los datos personales del operador. Todo el contenido vive en el disco externo **hd2t** (`/mnt/hd2t/services/nextcloud/`), nunca en la microSD.

Este documento **estrena el _stack_ `almacen`** (`~/homelab/almacen/`) descrito en `docs/02-docker/02-estructura-compose.md` (tabla de stacks, fila `almacen`, fase `docs/06-almacenamiento/`). El _stack_ alojará en fases siguientes a Samba (`02-samba.md`), Syncthing (`03-syncthing.md`) y MinIO (`04-minio.md`); aquí sólo se materializan los tres servicios que necesita Nextcloud:

- **`nextcloud`** — la propia aplicación PHP (imagen oficial `nextcloud:31-apache`, Nextcloud Hub 10).
- **`nextcloud-db`** — base de datos **MariaDB 11.4 LTS** dedicada (no se comparte con otros servicios; ver **Decisiones de diseño**).
- **`nextcloud-redis`** — Redis dedicado para _file locking_ distribuido y _memcache_ de la propia aplicación.
- **`nextcloud-cron`** — _sidecar_ con la misma imagen que `nextcloud`, en modo `cron`, que ejecuta `php cron.php` cada 5 min (recomendación oficial; reemplaza al cron de la UI o al cron del host).

Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone Nextcloud en `https://nextcloud.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), `https://pi.tailnet.ts.net/nextcloud/` redirige al mismo backend (Nextcloud soporta `OVERWRITEWEBROOT` para vivir bajo subruta, pero aquí se mantiene en raíz; el acceso remoto se hace por subdominio dedicado `nextcloud.<tailnet>.ts.net` mediante MagicDNS).

> **Alcance**: este documento despliega Nextcloud con su autenticación nativa (usuarios + 2FA TOTP de la app `twofactor_totp`). **No** delega autenticación a Authelia vía `forward_auth` (rompería los clientes de sincronización; ver **Decisiones de diseño**). **No** activa colaboración en tiempo real (Collabora Online / OnlyOffice — son servicios pesados que se documentan aparte si llegan a ser necesarios). **No** activa _Talk_ (videollamadas con TURN/coturn). Sí instala las apps recomendadas para uso personal (Calendar, Contacts, Mail opcional, Notes, Tasks, Photos), y deja el sistema preparado para integrar OIDC con Authelia más adelante (sección **Migrar a OIDC con Authelia (opcional)**).

> **Recordatorio de red**: Nextcloud **no se publica al host**. Caddy la alcanza por DNS interno de Docker (`nextcloud:80` en la red `homelab`). MariaDB y Redis viven en `almacen-internal` y son inaccesibles desde fuera del _stack_. Pi-hole resuelve `nextcloud.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`).

---

## Requisitos previos

- `docs/02-docker/02-estructura-compose.md` completado: la tabla de stacks reserva el _slot_ `almacen` que aquí se estrena, la red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) externa está creada, `~/homelab/.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `HOMELAB_DOMAIN=lan` está rellenado, y el _Makefile_ de operación expone `make up STACK=<stack>`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/nextcloud/{html,data,db}` ya existen vacíos. En este documento se crea además `/mnt/hd2t/services/nextcloud/redis/`.
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada. Nextcloud y MariaDB serán **opt-out** explícito (ver **Decisiones de diseño**).
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `nextcloud.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, y la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile`. La CA local ya firma `*.lan`.
- `docs/04-seguridad/01-authelia.md` completado **opcionalmente**: si está montado, en este documento se decide explícitamente **no** poner Nextcloud detrás de `forward_auth` (rompería los clientes de sync). Si Authelia no está montado todavía, no pasa nada — Nextcloud trae su propia autenticación.
- Conectividad saliente para descargar las imágenes (sólo la primera vez):
  ```bash
  docker pull --platform linux/arm64 nextcloud:31-apache   >/dev/null && \
  docker pull --platform linux/arm64 mariadb:11.4-noble    >/dev/null && \
  docker pull --platform linux/arm64 redis:7.4.1-alpine    >/dev/null && \
  echo OK
  ```
- Que el host **no** tenga ya un servicio escuchando en `:80` (`docker ps --format '{{.Ports}}' | grep ':80->' || echo OK`); este _stack_ no publica puertos al host (Caddy es quien recibe el tráfico HTTP), pero conviene confirmar que no hay un Apache/Nginx residual que pudiese interferir si el operador, por error, añadiese un `ports:` improvisado.
- Espacio en `/mnt/hd2t`: como mínimo **50 GB libres** para que Nextcloud arranque cómodo. La cuota real la dictan los datos del operador (puede crecer fácilmente a cientos de GB). Verificar:
  ```bash
  df -h /mnt/hd2t
  # Debe quedar holgado tras el arranque inicial (~1 GB de imagen+config).
  ```

---

## Decisiones de diseño

### Por qué Nextcloud (y no ownCloud / Seafile / Filebrowser)

El homelab necesita **una nube privada** que cubra al menos: sincronización de ficheros multi-dispositivo, calendarios y contactos (CalDAV/CardDAV), galería de fotos con _backup automático_ desde el móvil, _client_ multi-plataforma maduro, y posibilidad de **compartir enlaces** con terceros. Cuatro candidatos descartados y por qué:

| Candidato       | Por qué se descarta                                                                                                                                       |
|-----------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------|
| **ownCloud Infinite Scale (OCIS)** | Reescritura en Go, prometedora pero todavía con _gaps_ funcionales (apps, _ecosystem_) frente a Nextcloud. Rompe el _ecosystem_ histórico de ownCloud Classic.                              |
| **Seafile**     | Excelente _engine_ de sincronización (más rápido que Nextcloud), pero el _ecosystem_ de apps es mucho más reducido. No tiene CalDAV/CardDAV nativos integrados; calendar/contacts se montan aparte. |
| **Filebrowser** | Trivial de desplegar, pero es **sólo** un explorador web de ficheros: ni sync clients, ni CalDAV, ni colaboración. No cubre el caso de uso.                                                  |
| **Pydio Cells** | Buena alternativa enterprise, pero _self-hosting_ menos cuidado que Nextcloud, comunidad más pequeña y _ecosystem_ de apps muy limitado.                                                    |

Nextcloud gana por:

- **Madurez del _ecosystem_** — _apps store_ con cientos de extensiones (Calendar, Contacts, Notes, Tasks, Photos, News, Mail, Talk, Maps…), todas las que un homelab personal puede necesitar.
- **Clientes oficiales mantenidos** — Windows, macOS, Linux (sync), Android, iOS (sync + autoupload de fotos).
- **CalDAV/CardDAV nativos** — DAVx⁵ en Android sincroniza calendario y contactos automáticamente sin servidor extra.
- **OIDC integrable** — _app_ `user_oidc` permite enchufar Authelia (cuando se quiera) sin romper los clientes (los _clients_ siguen usando _app passwords_ generadas en la UI).
- **Imagen Docker oficial multi-arch ARM64** publicada por el equipo de Nextcloud, sin recurrir a forks de comunidad.

### Imagen y _tag_

- **`nextcloud:31-apache`** — Nextcloud **31** (Hub 10), variante con Apache + `mod_php` integrado. Multi-arch (`linux/arm64`). Pinneada a _tag_ "major + variante" siguiendo la convención del homelab (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`, "Tag mayor o LTS").
- **`mariadb:11.4-noble`** — MariaDB 11.4 LTS (mantenida hasta mayo 2029), multi-arch ARM64, sobre Ubuntu 24.04 (`noble`). _Tag_ con _minor_ explícito y base.
- **`redis:7.4.1-alpine`** — mismo _tag_ que el Redis del _stack_ `seguridad` (`docs/04-seguridad/01-authelia.md`); coherente y minimiza el número de imágenes distintas en el host.
- **`nextcloud-cron`**: misma imagen que `nextcloud` (`nextcloud:31-apache`); el _entrypoint_ se cambia a `/cron.sh`. **No** se duplica el pin: una sola variable `NEXTCLOUD_IMAGE_TAG` en `.env` controla ambos.

#### Watchtower opt-out en los cuatro contenedores

Razones por contenedor:

- **`nextcloud`** y **`nextcloud-cron`**: las actualizaciones **mayores** de Nextcloud (30 → 31, 31 → 32) ejecutan migraciones de _schema_ en la primera arrancada (`occ upgrade`) y pueden necesitar saltar por todas las versiones intermedias (no se permite saltar mayores). Un `pull` automático de un _tag_ `:31-apache` a `:32-apache` deja la BD parcialmente migrada si algo va mal. **Las _major upgrades_ se hacen a mano**, leyendo el _changelog_ y haciendo backup de BD + datos previo.
- **`nextcloud-db`** (MariaDB): un _bump_ de _major_ (10.x → 11.x) puede cambiar formato de InnoDB y formato del directorio de datos. Un downgrade no es trivial. **Manual** y con _dump_ previo.
- **`nextcloud-redis`**: contiene **file locks distribuidos** activos. Un reinicio brusco durante una sesión de sincronización masiva puede dejar locks "fantasma" en la BD que se limpian con `occ files:cleanup`. Aceptable, pero merece una ventana intencional.

Etiquetar los cuatro con `com.centurylinklabs.watchtower.enable: "false"`.

### MariaDB en lugar de PostgreSQL

Nextcloud soporta MariaDB ≥ 10.5, MySQL 8 y PostgreSQL ≥ 12. Elección: **MariaDB 11.4**. Razones:

- **Convención del proyecto**: el ejemplo en `docs/02-docker/02-estructura-compose.md` (sección _plantilla de compose_) ya muestra `nextcloud-db:3306` (puerto MariaDB/MySQL). Mantener la misma elección permite reutilizar la configuración cuando llegue Bookstack (`docs/11-productividad/02-bookstack.md`), que también usa MariaDB.
- **Backups**: `mariadb-dump` (alias de `mysqldump`) es trivial de cablear desde Borgmatic _hooks_ (`docs/07-backups/02-borgmatic.md`); la documentación de Borgmatic tiene ejemplos directos.
- **Rendimiento en ARM64**: MariaDB 11.4 tiene InnoDB optimizado para ARM64 desde 10.6. Para 1–3 usuarios concurrentes es indistinguible de PostgreSQL en este hardware.
- **Memoria**: idle ~120 MB con `innodb_buffer_pool_size=128M`; PostgreSQL pediría ~150 MB con `shared_buffers=128MB`. Diferencia menor pero cada MB cuenta en la Pi.

Si en el futuro un servicio del homelab exigiese PostgreSQL (por ejemplo, Paperless-ngx), se levantará un Postgres aparte en su propio _stack_ (`productividad/`), sin mezclar bases de datos de servicios distintos en un mismo motor.

### Redis dedicado, no compartido con `seguridad`

El _stack_ `seguridad` ya levanta un Redis (sesiones de Authelia, ver `docs/04-seguridad/01-authelia.md`). Tentación natural: hacer que Nextcloud lo reutilice. Se descarta por:

- **Aislamiento de stacks**: `seguridad-internal` y `almacen-internal` son redes Docker privadas y separadas. Cruzarlas para que Nextcloud llegue a `redis` de `seguridad` requiere conectar Authelia-Redis a `homelab` o crear una red ad-hoc, lo cual erosiona el principio de "una red privada por _stack_" que `02-estructura-compose.md` establece.
- **Carga distinta**: file locks de Nextcloud durante una sincronización masiva (subida de 5 GB de fotos del móvil, por ejemplo) generan miles de operaciones por segundo en Redis. Mezclar esa carga con las cookies de sesión de Authelia (operaciones lentas y poco frecuentes) introduce contención y _tail latency_ no deseada en el flujo de _login_.
- **Ciclo de vida**: el Redis de Authelia **no debe perderse** (todos vuelven a re-loguear). El Redis de Nextcloud **se puede vaciar** sin drama (los locks se rehacen, el caché de PHP se rellena). Tener políticas de backup distintas requiere instancias distintas.

Por eso `nextcloud-redis` vive en el propio _stack_ `almacen`, dentro de `almacen-internal`, sin _bind mount_ persistente (ver siguiente decisión).

### Redis sin persistencia (caché efímera)

A diferencia del Redis de `seguridad` (AOF activo, sesiones críticas), el Redis de Nextcloud **no necesita sobrevivir a reinicios**. Su contenido es:

1. _Memcache_ de PHP (objetos hidratados que se pueden regenerar leyendo BD).
2. _File locks_ distribuidos: si se pierden, Nextcloud los re-adquiere o los limpia con `occ files:cleanup`.
3. _Throttling_ y _rate limit_ counters: efímeros por diseño.

Configuración: `--save ""` (sin _snapshots_), `--appendonly no` (sin AOF), `--maxmemory 256mb` (techo duro), `--maxmemory-policy allkeys-lru` (al llenarse, evicta lo menos usado). Sin _bind mount_ — el dato vive en _tmpfs_ del contenedor y desaparece en el reinicio. Resultado: ~30 MB de RAM en idle, y un reinicio del _stack_ deja Nextcloud levemente más lento durante 30 s mientras re-puebla el caché. Aceptable.

### `forward_auth` con Authelia: **NO** para Nextcloud

Tentación natural, una vez Authelia está montado: añadir `import authelia` al bloque `nextcloud.lan` del `Caddyfile`. **No se hace**, y es importante entender por qué:

- **Los clientes de sincronización de Nextcloud (desktop + móvil) hablan WebDAV con autenticación HTTP Basic** (sobre HTTPS). No saben redirigirse a un portal _web_ ni resolver un challenge OIDC. Si Caddy intercepta sus peticiones y devuelve `302` hacia `https://auth.lan/?rd=...`, el cliente _falla en bucle_ con `401`/redirect sin sincronizar nada.
- **Los clientes CalDAV/CardDAV** (DAVx⁵ en Android, app de calendario nativa de iOS, Thunderbird) tienen el mismo problema: no siguen redirects HTML, no resuelven 2FA por TOTP en una pantalla de _login_ HTML. Sólo entienden Basic Auth o _Bearer tokens_.
- **El cliente móvil de Nextcloud** soporta _OAuth2 / OpenID_ contra el propio Nextcloud, pero no contra un _front_ HTTP que esté delante. El flujo OIDC de Nextcloud lo hace **el propio Nextcloud** vía la app `user_oidc`, no Caddy.

Solución correcta: **Nextcloud autentica con su sistema nativo** (usuario + contraseña + TOTP propio vía `twofactor_totp`). Si en el futuro se quiere SSO con Authelia, se hace **dentro** de Nextcloud habilitando `user_oidc` y registrando un cliente OIDC en Authelia (sección **Migrar a OIDC con Authelia (opcional)**). Los clientes nativos siguen usando _app passwords_ generadas en `Settings → Security → Devices & Sessions`, que **no** pasan por OIDC.

> **Resumen operativo**: el bloque `nextcloud.lan` del `Caddyfile` lleva `import security-headers` y `import logging`, pero **no** `import authelia`. Caddy actúa como _reverse proxy_ "tonto" que no añade autenticación; Nextcloud autentica.

### `OVERWRITEPROTOCOL=https` y _trusted proxies_

Nextcloud, al ser proxy-reverseado por Caddy, ve el tráfico interno como **HTTP** (Caddy termina TLS y habla con `nextcloud:80` en plano dentro de `homelab`). Si no se le dice, generará URLs absolutas con `http://...` en _share links_ y en el JavaScript de la UI, rompiendo todo lo que asume HTTPS (cookies `Secure`, _service workers_, _mixed content_ blocking del navegador).

Tres variables de entorno cierran el caso:

```yaml
OVERWRITEPROTOCOL: https        # las URLs públicas se generan https://...
OVERWRITEHOST: nextcloud.lan    # nombre canónico (no el del contenedor)
TRUSTED_PROXIES: 172.20.10.0/24 # subnet de la red Docker 'homelab'
```

`TRUSTED_PROXIES` es crítico: sin él, Nextcloud ignora la cabecera `X-Forwarded-For` que Caddy envía y los logs registran "todo el mundo viene de la IP del contenedor de Caddy". Con la subnet completa `172.20.10.0/24` se confía en cualquier proxy que pertenezca a la red `homelab`, sin tener que pinear la IP exacta de Caddy (que cambia en cada `up -d`).

> **Por qué la subnet entera y no solo la IP del contenedor Caddy**: Docker no garantiza IPs estáticas en un `bridge` por defecto. Pinear la IP requeriría `ipv4_address` en `networks:`, lo que añade complejidad operativa por un beneficio mínimo (el "ataque" sería que otro contenedor de la misma red se autodeclarase Caddy, lo cual ya está descartado por el modelo de confianza intra-_stack_).

### Cron de Nextcloud: _sidecar_, no `cron` del host ni `cron` interno de la app

Nextcloud necesita que `php cron.php` se ejecute cada **5 minutos** para tareas de mantenimiento (cleanup de share links expirados, regeneración de _previews_, ejecución de _scheduled jobs_ de las apps). Tres opciones, una elección:

| Opción                                        | Pros                                              | Contras                                                                  |
|-----------------------------------------------|---------------------------------------------------|--------------------------------------------------------------------------|
| **Cron del propio Nextcloud** (UI, AJAX)      | 0 setup; lo enciende un toggle.                   | Sólo se ejecuta cuando alguien navega la UI; en un servidor "dormido" no corre nada durante días. **Inadecuado**. |
| **Crontab del host** (`*/5 * * * * docker exec ...`) | Sencillo, sin servicios extra.                | Acopla el host al ciclo de vida del contenedor (si Nextcloud se renombra, el `docker exec` falla en silencio). Se rompe si el contenedor está parado por mantenimiento.       |
| **_Sidecar_ con `entrypoint: /cron.sh`** ✅    | Estado del contenedor visible (`docker ps`), depende de `nextcloud-db` y `nextcloud-redis` igual que el contenedor principal, se para cuando se para el _stack_. | Un contenedor extra (~50 MB de RAM idle).                                |

Se elige el _sidecar_. La imagen `nextcloud:31-apache` trae `/cron.sh` ya escrito (un bucle `while true; do sleep 300 && php cron.php; done`); basta con `entrypoint: /cron.sh`.

### Almacenamiento

| Ruta en el host                                    | Contenido                                                 | Versionable | Backup |
|----------------------------------------------------|-----------------------------------------------------------|-------------|--------|
| `~/homelab/almacen/docker-compose.yml`             | Definición del _stack_                                     | git         | git    |
| `~/homelab/almacen/.env`                            | Imágenes pinneadas + secretos (passwords DB, …)            | **NO** (`.gitignore`) | git aparte (nota local) |
| `~/homelab/almacen/.env.example`                    | Plantilla con nombres de variables, sin valores            | git         | git    |
| `/mnt/hd2t/services/nextcloud/html/`                | `/var/www/html` del contenedor: apps, config, themes, occ | **NO** versionable | **Sí** (Borgmatic) |
| `/mnt/hd2t/services/nextcloud/data/`                | Ficheros de usuarios (puede crecer mucho)                 | **NO**      | **Sí** (Borgmatic — _set_ aparte) |
| `/mnt/hd2t/services/nextcloud/db/`                  | InnoDB de MariaDB                                         | **NO**      | **Sí** (Borgmatic, vía dump) |

> **`html/` y `data/` separados**: son dos _bind mounts_ distintos por una razón de **backup**. `html/` es pequeño (~500 MB) y se respalda **completo** todas las noches; `data/` puede ser de cientos de GB y se respalda con políticas distintas (Borgmatic con _excludes_ del `.cache/` de los clientes, retención más larga, _checkpoint_ cada N GB). Si fueran un único _mount_ habría que usar _excludes_ relativos y la separación quedaría enmascarada.

> **Por qué `html/` también va a `hd2t` y no se queda en la microSD**: `html/apps/` y `html/custom_apps/` reciben los APKs de las apps instaladas desde la _Apps store_ (decenas de MB cada una) y `html/config/config.php` es el "fichero más crítico" de Nextcloud. Mantenerlo en hd2t aporta resiliencia (si la microSD se corrompe, sólo hay que reinstalar OS + Docker y montar el _stack_ apuntando al disco) y backupabilidad uniforme (todo lo de Nextcloud está en `/mnt/hd2t/services/nextcloud/`).

> **`db/` en disco rotacional**: una BD InnoDB en HDD USB es más lenta que en SSD/microSD, pero para 1–3 usuarios y ~10 RPS de carga real, el disco rotacional es **más que suficiente**. La microSD no es opción: la escritura aleatoria de InnoDB la quema en meses.

---

## Estructura del _stack_ `almacen` tras este documento

```
~/homelab/almacen/
├── docker-compose.yml        # ← nuevo
├── .env                      # ← nuevo (NO versionado)
├── .env.example              # ← nuevo (versionado)
└── .gitignore                # ← nuevo (excluye .env)
```

Y en los discos externos, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/nextcloud/
├── html/                     # creado en docs/01-sistema/04-estructura-directorios.md
├── data/                     # creado en docs/01-sistema/04-estructura-directorios.md
└── db/                       # creado en docs/01-sistema/04-estructura-directorios.md
```

Crear el subdirectorio del _stack_ y los _stubs_ de gitignore:

```bash
mkdir -p ~/homelab/almacen
chmod 0750 ~/homelab/almacen

cat > ~/homelab/almacen/.gitignore <<'EOF'
# Secretos del stack — NUNCA commitear
.env
EOF
```

> **Ownership de `/mnt/hd2t/services/nextcloud/`**: la imagen oficial de Nextcloud corre como `www-data` (UID/GID `33:33`) y la imagen oficial de MariaDB corre como `mysql` (UID/GID `999:999` en Debian/Ubuntu). El _entrypoint_ de cada imagen hace `chown` de su propio subárbol en el primer arranque, **no hay que pre-chown-ear** desde el host. Lo que sí hay que verificar es que `root:root 0755` del raíz `/mnt/hd2t/services/nextcloud/` permita a esos UIDs entrar a sus subdirectorios — `0755` lo cumple.

---

## Variables de entorno

Crear `~/homelab/almacen/.env.example` (versionado en git, sin valores reales):

```bash
# --- Imágenes pinneadas -----------------------------------------------------
NEXTCLOUD_IMAGE_TAG=31-apache
MARIADB_IMAGE_TAG=11.4-noble
REDIS_IMAGE_TAG=7.4.1-alpine

# --- Nextcloud --------------------------------------------------------------
# URL pública canónica del servicio. Coincide con el bloque del Caddyfile y
# con el wildcard *.lan que Pi-hole resuelve a 192.168.1.3.
NEXTCLOUD_TRUSTED_DOMAINS=nextcloud.lan
NEXTCLOUD_OVERWRITE_HOST=nextcloud.lan

# Subnet de la red Docker 'homelab' (creada en docs/02-docker/02-estructura-compose.md).
# Fijada ahí en 172.20.10.0/24.
NEXTCLOUD_TRUSTED_PROXIES=172.20.10.0/24

# Subida máxima por petición. Influye en client web y en sync clients (chunking
# de subidas grandes). 16G es generoso pero no excesivo para un homelab.
NEXTCLOUD_UPLOAD_LIMIT=16G

# Memory limit del proceso PHP-FPM/Apache. Default Nextcloud (512M) es
# adecuado para una Pi 5 con 8 GB y 1-3 usuarios concurrentes.
PHP_MEMORY_LIMIT=512M

# Usuario admin inicial — sólo se aplica en el primer arranque (cuando html/
# está vacío). Despues, gestionar usuarios desde la UI o `occ user:add`.
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=

# --- MariaDB (nextcloud-db) -------------------------------------------------
# Nextcloud crea la BD y el usuario al primer arranque usando estas credenciales.
# El root sólo se usa para gestion (mariadb-dump, troubleshooting).
MYSQL_DATABASE=nextcloud
MYSQL_USER=nextcloud
MYSQL_PASSWORD=
MYSQL_ROOT_PASSWORD=
```

Copiar a `.env` y rellenar los valores reales (passwords aleatorias):

```bash
cp ~/homelab/almacen/.env.example ~/homelab/almacen/.env
chmod 0600 ~/homelab/almacen/.env

# Generar passwords aleatorias (32 chars, sin caracteres problemáticos en YAML)
mariadb_pass=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
mariadb_root=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
nc_admin=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)

# Edición manual (alternativa, recomendado): vi ~/homelab/almacen/.env
sed -i "s|^MYSQL_PASSWORD=$|MYSQL_PASSWORD=$mariadb_pass|" ~/homelab/almacen/.env
sed -i "s|^MYSQL_ROOT_PASSWORD=$|MYSQL_ROOT_PASSWORD=$mariadb_root|" ~/homelab/almacen/.env
sed -i "s|^NEXTCLOUD_ADMIN_PASSWORD=$|NEXTCLOUD_ADMIN_PASSWORD=$nc_admin|" ~/homelab/almacen/.env

# Guardar las passwords en el gestor de contraseñas (Vaultwarden, cuando
# llegue su fase) ANTES de cerrar la sesión SSH. La de admin de Nextcloud
# se cambiará en la UI tras el primer login si se desea.
echo "ADMIN: $nc_admin"
unset mariadb_pass mariadb_root nc_admin
```

> **Por qué `tr -d '/+='`**: `openssl rand -base64` puede emitir `/`, `+` o `=`, todos válidos en YAML pero molestos al copiar/pegar y a veces problemáticos en _connection strings_ MySQL si el _client_ los interpreta. El _drop_ no reduce significativamente la entropía (32 chars Base64 menos 3 chars = 32 chars sobre alfabeto de 61, aún ~190 bits).

> **No commitear `.env` jamás**. El `.gitignore` del _stack_ ya lo excluye explícitamente.

---

## `~/homelab/almacen/docker-compose.yml`

```yaml
---
# Stack: almacen — Nextcloud (nube privada) + MariaDB + Redis
# Documentación: docs/06-almacenamiento/01-nextcloud.md

services:

  # ---------------------------------------------------------------------------
  # MariaDB — base de datos de Nextcloud.
  # Sólo en la red privada del stack; no se expone al host ni a 'homelab'.
  # ---------------------------------------------------------------------------
  nextcloud-db:
    image: mariadb:${MARIADB_IMAGE_TAG}
    container_name: nextcloud-db
    hostname: nextcloud-db
    restart: unless-stopped
    # Recomendado por Nextcloud para evitar el bug del "binlog format" en
    # InnoDB con TRUNCATE TABLE de archivos compartidos. Documentado en
    # https://docs.nextcloud.com/server/latest/admin_manual/configuration_database/linux_database_configuration.html
    command:
      - --transaction-isolation=READ-COMMITTED
      - --log-bin=binlog
      - --binlog-format=ROW
      - --innodb-file-per-table=ON
      - --innodb-buffer-pool-size=256M
      - --max-connections=100
    environment:
      TZ: ${TZ}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      # Inicialización idempotente: la imagen sólo crea la BD si /var/lib/mysql
      # está vacío. En upgrades/restauraciones no toca nada.
    volumes:
      - /mnt/hd2t/services/nextcloud/db:/var/lib/mysql
    networks:
      - almacen-internal
    labels:
      homelab.stack: "almacen"
      homelab.backup: "true"      # /mnt/hd2t/services/nextcloud/db (vía dump)
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

  # ---------------------------------------------------------------------------
  # Redis — file locking + memcache de Nextcloud.
  # Sin persistencia: el contenido es regenerable. Sólo en almacen-internal.
  # ---------------------------------------------------------------------------
  nextcloud-redis:
    image: redis:${REDIS_IMAGE_TAG}
    container_name: nextcloud-redis
    hostname: nextcloud-redis
    restart: unless-stopped
    command:
      - redis-server
      - --save
      - ""
      - --appendonly
      - "no"
      - --maxmemory
      - 256mb
      - --maxmemory-policy
      - allkeys-lru
    environment:
      TZ: ${TZ}
    networks:
      - almacen-internal
    labels:
      homelab.stack: "almacen"
      homelab.backup: "false"     # caché efímera, regenerable
      # Opt-out: file locks vivos durante un sync. Reinicio = ventana intencional.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      test: ["CMD", "redis-cli", "PING"]
      interval: 10s
      timeout: 3s
      retries: 5
      start_period: 5s

  # ---------------------------------------------------------------------------
  # Nextcloud — la propia aplicación PHP (Apache + mod_php).
  # En 'homelab' (Caddy la alcanza por nombre) Y en 'almacen-internal'
  # (alcanza a la BD y al Redis).
  # ---------------------------------------------------------------------------
  nextcloud:
    image: nextcloud:${NEXTCLOUD_IMAGE_TAG}
    container_name: nextcloud
    hostname: nextcloud
    restart: unless-stopped
    environment:
      TZ: ${TZ}

      # --- BD ---
      MYSQL_HOST: nextcloud-db
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}

      # --- Redis ---
      REDIS_HOST: nextcloud-redis
      REDIS_HOST_PORT: 6379

      # --- Bootstrap del primer admin (sólo se aplica si html/ está vacío) ---
      NEXTCLOUD_ADMIN_USER: ${NEXTCLOUD_ADMIN_USER}
      NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASSWORD}

      # --- Reverse proxy (Caddy termina TLS) ---
      NEXTCLOUD_TRUSTED_DOMAINS: ${NEXTCLOUD_TRUSTED_DOMAINS}
      OVERWRITEPROTOCOL: https
      OVERWRITEHOST: ${NEXTCLOUD_OVERWRITE_HOST}
      TRUSTED_PROXIES: ${NEXTCLOUD_TRUSTED_PROXIES}

      # --- PHP / Apache ---
      PHP_MEMORY_LIMIT: ${PHP_MEMORY_LIMIT}
      PHP_UPLOAD_LIMIT: ${NEXTCLOUD_UPLOAD_LIMIT}

      # --- Apps a habilitar tras el primer arranque ---
      # Lista vacía: la habilitación se hace a mano en la sección
      # 'Configuración tras primer arranque' del documento (más control).
      # NEXTCLOUD_INIT_HTACCESS=true ya lo hace el entrypoint por defecto.
    volumes:
      - /mnt/hd2t/services/nextcloud/html:/var/www/html
      - /mnt/hd2t/services/nextcloud/data:/var/www/html/data
    networks:
      homelab:
        aliases:
          - nextcloud         # Caddy resuelve 'nextcloud:80' por este alias
      almacen-internal:
        # alcanza a 'nextcloud-db' y 'nextcloud-redis' por nombre
    labels:
      homelab.stack: "almacen"
      homelab.backup: "true"      # html/ y data/ entran en Borgmatic (sets distintos)
      # Opt-out: las upgrades de Nextcloud ejecutan migraciones de BD. Manual.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      # /status.php es el endpoint público estándar de healthcheck. Devuelve
      # JSON con {"installed":true,"version":"31.x.x", ...} cuando todo OK.
      test:
        - CMD-SHELL
        - "curl -fsS http://localhost/status.php | grep -q '\"installed\":true'"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s    # primer arranque: instala BD, descomprime apps, ~90 s
    depends_on:
      nextcloud-db:
        condition: service_healthy
      nextcloud-redis:
        condition: service_healthy

  # ---------------------------------------------------------------------------
  # Cron — sidecar que ejecuta /cron.sh (loop infinito: php cron.php cada 5min).
  # Misma imagen, mismos volúmenes, mismas credenciales — sólo cambia entrypoint.
  # ---------------------------------------------------------------------------
  nextcloud-cron:
    image: nextcloud:${NEXTCLOUD_IMAGE_TAG}
    container_name: nextcloud-cron
    hostname: nextcloud-cron
    restart: unless-stopped
    entrypoint: /cron.sh
    environment:
      TZ: ${TZ}
      MYSQL_HOST: nextcloud-db
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      REDIS_HOST: nextcloud-redis
      REDIS_HOST_PORT: 6379
    volumes:
      - /mnt/hd2t/services/nextcloud/html:/var/www/html
      - /mnt/hd2t/services/nextcloud/data:/var/www/html/data
    networks:
      - almacen-internal
    labels:
      homelab.stack: "almacen"
      homelab.backup: "false"     # ningún estado propio
      com.centurylinklabs.watchtower.enable: "false"
    depends_on:
      nextcloud:
        condition: service_healthy

# ---------------------------------------------------------------------------
# Redes
# ---------------------------------------------------------------------------
networks:
  homelab:
    external: true               # creada en docs/02-docker/02-estructura-compose.md
  almacen-internal:
    driver: bridge               # privada de este stack; Compose la gestiona
```

Notas de diseño:

- **Sólo `nextcloud` está en `homelab`**. `nextcloud-db`, `nextcloud-redis` y `nextcloud-cron` se quedan en `almacen-internal` y son **inalcanzables desde Caddy** o desde otros _stacks_. Esto cumple el principio de "sólo el _front_ de cada _stack_ se publica al resto del homelab".
- **Sin `ports:`** en ningún servicio. Caddy alcanza Nextcloud por DNS interno (`nextcloud:80`). Si el operador, durante troubleshooting, necesita acceder a Nextcloud sin pasar por Caddy, puede hacer `docker exec -it nextcloud curl http://localhost/status.php` desde dentro del propio contenedor.
- **`depends_on` con `condition: service_healthy`** en cascada: `nextcloud-db` y `nextcloud-redis` deben estar `(healthy)` antes de que arranque `nextcloud`. Sin esto, Nextcloud loguearía `Connection refused` durante los primeros 30–60 s del primer arranque y entraría en _retry loop_ del propio _entrypoint_ (eventualmente arranca, pero contamina logs y atrasa el `(healthy)` global).
- **`start_period: 120s`** en `nextcloud`: la **primera** arrancada tarda ~90 s (descompresión de la imagen, copia de `/var/www/html/`, `occ maintenance:install`, `occ db:add-missing-indices`). Con un `start_period` corto, el _healthcheck_ daría `unhealthy` espuriamente y Compose intentaría reiniciar el contenedor en plena instalación, dejando `html/` a medias. 120 s es holgado; en arranques posteriores, el `(healthy)` llega en <15 s.
- **Cron como _sidecar_ con la misma imagen**: pesa lo que pesa la imagen ya descargada (la _layer_ ya está en disco; el _sidecar_ sólo añade ~30 MB de RAM por el proceso PHP en _idle_). Total: ~50 MB extra. Despreciable.
- **Watchtower opt-out** en los cuatro: razones explicadas en **Decisiones de diseño** → _Imagen y tag_.

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/almacen
docker compose --env-file ../.env --env-file .env config | head -60   # validar sintaxis
docker compose --env-file ../.env --env-file .env up -d
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=almacen
```

Vigilar el primer arranque (tarda ~90 s):

```bash
docker compose -f ~/homelab/almacen/docker-compose.yml logs -f nextcloud
# ...
# nextcloud  | New nextcloud instance
# nextcloud  | Initializing finished
# nextcloud  | Apache/2.4.62 (Debian) configured -- resuming normal operations
```

Verificar que los cuatro contenedores están `(healthy)`:

```bash
docker compose -f ~/homelab/almacen/docker-compose.yml ps
# NAME              STATUS                   PORTS
# nextcloud-db      Up X seconds (healthy)
# nextcloud-redis   Up X seconds (healthy)
# nextcloud         Up X seconds (healthy)
# nextcloud-cron    Up X seconds
```

> El `(healthy)` de `nextcloud` es el indicador clave: lo otorga el _healthcheck_ que confirma que `/status.php` devuelve `"installed":true`. Si tras 3 minutos sigue `starting`, ir a **Troubleshooting** → primer arranque.

### Caddy: bloque `nextcloud.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque:

```caddy
nextcloud.lan {
    tls internal
    import security-headers
    import logging

    # Cabeceras WebDAV — Nextcloud hace HEAD/PROPFIND/MOVE/COPY que algunos
    # proxies recortan. Caddy las pasa intactas por defecto, pero ser explícito
    # ayuda a quien lea el Caddyfile.
    @webdav {
        path /remote.php/dav/* /remote.php/webdav/*
        method PROPFIND PROPPATCH MKCOL COPY MOVE LOCK UNLOCK REPORT
    }

    # /.well-known redirects oficiales recomendados por Nextcloud:
    # https://docs.nextcloud.com/server/latest/admin_manual/issues/general_troubleshooting.html#service-discovery
    redir /.well-known/carddav /remote.php/dav/ 301
    redir /.well-known/caldav  /remote.php/dav/ 301

    # Desactivar Strict-Transport-Security para los clientes WebDAV: algunos
    # clientes legacy en Linux fallan al validar HSTS con CA local. Comentado
    # por ahora — sólo descomentar si DAVx⁵ o un cliente específico falla.
    # header /remote.php/dav/* -Strict-Transport-Security

    reverse_proxy nextcloud:80 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # Subidas grandes — el cliente desktop puede chunkear hasta 10 MB
        # por chunk; el cliente móvil hasta el tamaño del fichero (vídeos
        # de 4K llegan a 5 GB). El default de flush=0 es OK para WebDAV.
    }

    # Subida grande: PHP_UPLOAD_LIMIT=16G en .env. Caddy por defecto no
    # impone su propio límite, no hace falta configurar aquí.
}
```

Validar y recargar Caddy:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Probar (la CA local debe estar importada en el navegador, ver `docs/03-red/04-caddy.md`):

```bash
curl -k --resolve nextcloud.lan:443:192.168.1.3 https://nextcloud.lan/status.php
# {"installed":true,"maintenance":false,"needsDbUpgrade":false,
#  "version":"31.x.x.x","versionstring":"31.x.x","edition":"",
#  "productname":"Nextcloud","extendedSupport":false}
```

Y desde el navegador: `https://nextcloud.lan/` → pantalla de _login_ (no del _setup wizard_, porque el primer arranque ya hizo `occ maintenance:install` con las credenciales de `.env`).

---

## Configuración tras primer arranque

Login interactivo en `https://nextcloud.lan/` con `${NEXTCLOUD_ADMIN_USER}` y la password del `.env`. La primera vez Nextcloud pasea al admin por un wizard (apps recomendadas, dashboard inicial); se puede _Skip_ — las apps las instalamos a continuación de forma controlada.

### Endurecer la configuración con `occ`

Nextcloud se configura desde la UI o vía la herramienta de línea de comandos `occ` (Owncloud Console — el nombre se quedó). Todos los `occ` se ejecutan como `www-data`:

```bash
ncexec() { docker exec -u www-data nextcloud php occ "$@"; }

# 1. Marcar la BD para usar índices óptimos (Nextcloud lo recomienda en
#    'Settings → Administration → Overview' tras el primer arranque).
ncexec db:add-missing-indices
ncexec db:add-missing-columns
ncexec db:add-missing-primary-keys
ncexec db:convert-filecache-bigint --no-interaction

# 2. Forzar maintenance:repair (limpia inconsistencias detectadas).
ncexec maintenance:repair --include-expensive

# 3. Establecer la 'phone region' por defecto para que valide números
#    sin prefijo internacional. Coincide con la zona horaria.
ncexec config:system:set default_phone_region --value="ES"

# 4. Ajustar el log level a 'warning' (default 'info' es ruidoso).
ncexec config:system:set loglevel --value=2 --type=integer
#    0 = debug, 1 = info, 2 = warning, 3 = error, 4 = fatal

# 5. Encender el modo de cron 'cron' (lo recoge el sidecar nextcloud-cron).
ncexec config:app:set core backgroundjobs_mode --value=cron
```

> **`config.php` no se edita a mano**. Todos los cambios pasan por `occ config:system:set` o por la UI. `occ` actualiza `/var/www/html/config/config.php` de forma transaccional y respeta el formato.

Verificar el resultado en `Settings → Administration → Overview`. La página muestra una lista de _checks_ (verde = OK, naranja = warning, rojo = error). Al final de esta sección, lo "esperable" es:

- ✅ La instancia ha sido configurada correctamente.
- ✅ El módulo de PHP `imagick` está habilitado.
- ✅ La BD tiene los índices recomendados.
- ✅ El cron se ejecuta cada 5 minutos.
- ⚠️ "El módulo PHP `gmp` no está disponible" — _puede_ aparecer; es para WebAuthn (FIDO2), opcional. Si se quiere usar llaves físicas, se instala con la sección **Habilitar GMP para WebAuthn** en _Troubleshooting_.

### Crear el usuario operador

El admin (`${NEXTCLOUD_ADMIN_USER}`) **no** se usa para el día a día (es la "cuenta root" de Nextcloud, sólo para administración). Crear una cuenta personal:

```bash
# Genera una password aleatoria temporal; el usuario la cambiará en el primer login
docker exec -u www-data -i nextcloud bash -c '
  OC_PASS=$(openssl rand -base64 24 | tr -d "/+=" | head -c 24)
  echo "Temp password: $OC_PASS"
  OC_PASS=$OC_PASS php occ user:add --password-from-env --display-name="Operador" homelab
'
# Salida: Temp password: <copiar a Vaultwarden>
#         The user "homelab" was created successfully
```

Login `homelab` → cambiar password → activar 2FA TOTP (siguiente paso).

### Activar 2FA TOTP

Nextcloud soporta TOTP (Aegis, Google Authenticator, 1Password) vía la app `twofactor_totp`. Habilitarla globalmente y forzarla para todos los usuarios excepto el primer admin:

```bash
ncexec app:install twofactor_totp
ncexec app:enable twofactor_totp

# Forzar 2FA para todos los usuarios (excepto admin durante setup).
# Cuando el operador 'homelab' ya tenga su TOTP, se puede activar para 'admin'
# también o desactivar 'admin' (recomendado).
ncexec config:app:set twofactor_totp enforced --value=true
ncexec config:app:set twofactor_totp enforced_groups --value='["users"]'
```

En el navegador: `Settings → Security → Two-Factor Authentication` → **Enable TOTP** → escanear QR con Aegis → introducir código → guardar.

> **App passwords para clientes nativos**: con 2FA forzado, el cliente desktop, móvil y DAVx⁵ **no** funcionan con la password personal (no hay UI para meter el TOTP). Hay que generar una _app password_ por cada cliente: `Settings → Security → Devices & Sessions → Create new app password`. Esa password de 64 caracteres es la que se mete en el cliente. Si se compromete un dispositivo, se revoca su app password sin afectar al resto.

### Apps recomendadas (uso personal)

Conjunto mínimo "ofimática personal":

```bash
# Calendario (CalDAV) y Contactos (CardDAV)
ncexec app:install calendar
ncexec app:install contacts

# Notas markdown (sincronizables con cliente Nextcloud Notes)
ncexec app:install notes

# Tareas (compatible con CalDAV / VTODO)
ncexec app:install tasks

# Fotos — gestión de la galería con álbumes y reconocimiento de caras
# (este último vía la app 'recognize', opcional, pesado en CPU).
ncexec app:install photos

# Marcadores (alternativa a Linkding si se prefiere todo bajo Nextcloud)
# Comentado: en este homelab Linkding es el gestor de marcadores oficial
# (docs/11-productividad/03-linkding.md). Descomentar si se prefiere usar
# el de Nextcloud.
# ncexec app:install bookmarks

# Notify Push — endpoint WebSocket que evita el polling del cliente
# desktop/móvil. Mejora la latencia de notificación de cambios remotos
# de varios segundos a sub-segundo.
ncexec app:install notify_push
```

> **Notify Push requiere configuración extra**: sirve un proceso aparte (`nextcloud-notify_push`) en el puerto 7867 dentro del contenedor `nextcloud`. Caddy debe redirigir `/push/*` a ese socket. La configuración del bloque `nextcloud.lan` ya documentada **no** lo incluye porque añade complejidad y los clientes funcionan perfectamente sin él (con _polling_ cada 30 s). **Activar Notify Push está documentado** en la sección _Habilitar Notify Push_ al final del documento.

### Reglas de subida y cuotas

```bash
# Cuota por usuario por defecto. Sin cuota, un usuario puede llenar el disco.
# 'unlimited' (default Nextcloud) cambia a un techo razonable para 1-3 usuarios.
ncexec config:app:set files default_quota --value="100 GB"

# Tamaño máximo de subida por petición (PHP_UPLOAD_LIMIT en .env ya lo fija
# a nivel de PHP; aquí se le dice a Nextcloud que respete ese límite).
ncexec config:app:set files max_chunk_size --value="10 MB"
```

> **Cambiar `default_quota` no afecta a usuarios existentes**. Hay que actualizarlos uno a uno con `occ user:setting <usuario> files quota '50 GB'` o desde la UI (`Settings → Administration → Users`).

---

## Verificación final

Antes de pasar a `docs/06-almacenamiento/02-samba.md`, comprobar:

- [ ] `docker compose -f ~/homelab/almacen/docker-compose.yml ps` muestra `nextcloud`, `nextcloud-db`, `nextcloud-redis` en `(healthy)` y `nextcloud-cron` en `Up`.
- [ ] `docker exec -u www-data nextcloud php occ status` devuelve `installed: true` y `maintenance: false`.
- [ ] `docker exec nextcloud-db healthcheck.sh --connect --innodb_initialized` exit-code `0`.
- [ ] `docker exec nextcloud-redis redis-cli PING` devuelve `PONG`.
- [ ] `curl -k --resolve nextcloud.lan:443:192.168.1.3 https://nextcloud.lan/status.php | python3 -m json.tool` devuelve un JSON con `"installed": true` y la versión correcta.
- [ ] `https://nextcloud.lan/` carga en el navegador con candado verde (CA local importada). El _login_ con `${NEXTCLOUD_ADMIN_USER}` funciona.
- [ ] `Settings → Administration → Overview` no muestra ningún _check_ rojo. Los _warnings_ naranjas aceptables son: _Memory cache configurado correctamente_ (verde si Redis OK), _PHP módulo `gmp` no disponible_ (sólo si no se usa WebAuthn).
- [ ] El usuario `homelab` (no admin) puede crear una carpeta, subir un fichero (~10 MB) y descargarlo. Test con `curl`:
  ```bash
  curl -k --resolve nextcloud.lan:443:192.168.1.3 \
    -u 'homelab:<app-password>' \
    -T /tmp/test.bin \
    https://nextcloud.lan/remote.php/dav/files/homelab/test.bin
  curl -k --resolve nextcloud.lan:443:192.168.1.3 \
    -u 'homelab:<app-password>' \
    -X DELETE \
    https://nextcloud.lan/remote.php/dav/files/homelab/test.bin
  ```
- [ ] El _cron sidecar_ está ejecutando: `docker logs nextcloud-cron --since 10m | grep -E 'cron'` muestra al menos una invocación reciente.
- [ ] El cliente desktop oficial (Windows/Linux/macOS) puede sincronizar usando una _app password_ generada en `Settings → Security`.
- [ ] DAVx⁵ en Android puede sincronizar `Calendar` y `Contacts` apuntando a `https://nextcloud.lan/remote.php/dav/` con la _app password_ (requiere que el dispositivo tenga la CA local importada o esté conectado vía Tailscale, ver `docs/03-red/05-tailscale.md`).
- [ ] Tras un `docker compose -f ~/homelab/almacen/docker-compose.yml restart nextcloud`, la página vuelve a `(healthy)` en <30 s y los datos siguen ahí.
- [ ] Tras un `sudo reboot` de la Pi, el _stack_ vuelve a estar `(healthy)` sin intervención manual y `https://nextcloud.lan/` responde.
- [ ] `git -C ~/homelab status` muestra como **modificados**: `red/Caddyfile`. Y como **nuevos**: `almacen/docker-compose.yml`, `almacen/.env.example`, `almacen/.gitignore`. **No** muestra `almacen/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add almacen/docker-compose.yml almacen/.env.example almacen/.gitignore \
          red/Caddyfile
  git commit -m "feat(almacen): add Nextcloud with MariaDB and Redis"
  ```

---

## Backup

| Qué                                            | Dónde                                                       | Cómo                                            |
|------------------------------------------------|-------------------------------------------------------------|-------------------------------------------------|
| `docker-compose.yml`                           | `~/homelab/almacen/`                                        | git                                             |
| `html/` (apps, config, themes, occ)            | `/mnt/hd2t/services/nextcloud/html/`                        | Borgmatic — _set_ "config", retención larga    |
| `data/` (ficheros de usuario)                  | `/mnt/hd2t/services/nextcloud/data/`                        | Borgmatic — _set_ "data", retención más corta, _excludes_ de `.cache/` |
| BD MariaDB                                     | `/mnt/hd2t/services/nextcloud/db/`                          | **Dump SQL** vía Borgmatic _hook_ pre-backup, NO copia raw |
| Redis (caché)                                  | _tmpfs_ (no persistente)                                    | No (regenerable)                                |

> **Por qué dump SQL y no copia raw del directorio `db/`**: copiar `/var/lib/mysql/` mientras MariaDB está escribiendo da una imagen **incoherente** (mid-transaction). El _hook_ de Borgmatic ejecuta `mariadb-dump` antes del snapshot, lo que produce un fichero `.sql` puntual y consistente. Borgmatic lo deduplica eficientemente entre ejecuciones. La sintaxis exacta del _hook_ se documenta en `docs/07-backups/02-borgmatic.md`.

> **Restauración desde backup**:
> 1. Restaurar el repo (clone), restaurar `/mnt/hd2t/services/nextcloud/{html,data}/` desde Borgmatic.
> 2. Restaurar la BD: `docker compose up -d nextcloud-db && docker exec -i nextcloud-db mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" nextcloud < /path/to/backup.sql`
> 3. `make up STACK=almacen`. Los datos de Redis se regeneran solos.
> 4. `docker exec -u www-data nextcloud php occ maintenance:data-fingerprint` — actualiza el _fingerprint_ para que los clientes sincronicen los cambios "extraños" del restore sin romper.

> **Antes de cualquier upgrade mayor de Nextcloud (31 → 32)**:
> 1. `docker compose stop nextcloud nextcloud-cron`
> 2. Backup completo de `html/` + `data/` + dump de BD (Borgmatic _on-demand_).
> 3. Editar `.env`: `NEXTCLOUD_IMAGE_TAG=32-apache`.
> 4. `docker compose pull && docker compose up -d nextcloud nextcloud-cron`.
> 5. `docker logs -f nextcloud` — esperar a `Initializing finished` y `(healthy)`.
> 6. `docker exec -u www-data nextcloud php occ status` — confirmar versión nueva, `versionstring: 32.x`.
> 7. Verificación final completa de la sección anterior.
> 8. Si algo va mal: `docker compose down`, restaurar backup, `NEXTCLOUD_IMAGE_TAG=31-apache`, `up -d`.

---

## Troubleshooting

### `nextcloud` arranca y queda en `unhealthy` durante el primer arranque

El `start_period: 120s` da margen para la instalación inicial; si tras 3 minutos sigue `starting`/`unhealthy`, mirar los logs:

```bash
docker logs nextcloud --tail 100
```

Causas frecuentes:

1. **`html/` no estaba vacío**: si `/mnt/hd2t/services/nextcloud/html/` ya tenía ficheros (de un despliegue anterior abortado), el _entrypoint_ detecta "instalación existente", salta la instalación y arranca Apache contra una BD vacía. Síntoma: `An exception occurred while executing 'SELECT ... FROM oc_appconfig'` en logs. Solución:
   ```bash
   docker compose -f ~/homelab/almacen/docker-compose.yml down
   sudo rm -rf /mnt/hd2t/services/nextcloud/html/* /mnt/hd2t/services/nextcloud/html/.htaccess
   sudo rm -rf /mnt/hd2t/services/nextcloud/db/*
   make up STACK=almacen
   ```
2. **BD no alcanzable**: `Could not open input file: occ` o `SQLSTATE[HY000] [2002] Connection refused`. Verificar que `nextcloud-db` está `(healthy)` _antes_ de que arranque `nextcloud`. El `depends_on: condition: service_healthy` lo garantiza, pero un volumen `db/` corrupto puede dejar al healthcheck en bucle. Solución: revisar `docker logs nextcloud-db`.
3. **Permisos**: `Permission denied` al escribir en `/var/www/html`. La imagen oficial hace `chown -R www-data:www-data /var/www/html` en el _entrypoint_, pero si el _bind mount_ tiene un dueño extraño puede fallar. Solución:
   ```bash
   sudo chown -R 33:33 /mnt/hd2t/services/nextcloud/html /mnt/hd2t/services/nextcloud/data
   docker compose -f ~/homelab/almacen/docker-compose.yml restart nextcloud
   ```

### `Trusted domain error` al acceder por `https://nextcloud.lan/`

Aparece como página blanca con `Access through untrusted domain` en logs de `nextcloud`. Causa: `NEXTCLOUD_TRUSTED_DOMAINS` del `.env` no incluye el FQDN que pasó el navegador (típico tras renombrar el dominio o tras restaurar de backup).

Solución sin tirar el contenedor:

```bash
docker exec -u www-data nextcloud php occ config:system:set trusted_domains 0 --value=nextcloud.lan
docker exec -u www-data nextcloud php occ config:system:set trusted_domains 1 --value=pi.tailnet.ts.net
# (la entrada 1 sólo tiene sentido si ya está configurado el FQDN de Tailscale,
#  ver docs/03-red/05-tailscale.md)
```

### El cliente desktop / móvil rechaza el cert con `untrusted CA`

La CA local del homelab no está importada en el _trust store_ del dispositivo. Soluciones:

- **Windows / macOS**: importar `caddy_root.crt` (extraído con `docker exec caddy cat /data/caddy/pki/authorities/local/root.crt`) al _trust store_ del sistema; ver `docs/03-red/04-caddy.md` sección "Confianza en la CA local".
- **Linux**: copiar a `/usr/local/share/ca-certificates/caddy_root.crt` y `sudo update-ca-certificates`.
- **Android**: importar como _Credencial de usuario_ desde Ajustes → Seguridad → Cifrado y credenciales. **Algunos clientes rechazan CAs de usuario** (regla de Android desde 7.0). Workaround: usar el cliente vía Tailscale (`https://pi.tailnet.ts.net/`), donde el cert lo emite Tailscale (LetsEncrypt-firmado, confiado de fábrica).
- **iOS**: el client oficial de Nextcloud tiene un _override_ "Aceptar cert no confiado" en _Settings_ → _Advanced_. Para DAVx⁵ y otros, importar el `.crt` desde Ajustes → General → Perfiles.

### Logs llenos de `Could not retrieve mount`

Síntoma: ruido constante en `docker logs nextcloud` con `Could not retrieve mount for storage [...]`. Causa típica: una _external storage_ configurada (SMB, FTP, S3) que ya no responde. Listarlas y desactivar la conflictiva:

```bash
docker exec -u www-data nextcloud php occ files_external:list
docker exec -u www-data nextcloud php occ files_external:option <ID> enabled false
```

### `Cannot write into apps directory` en _Settings → Apps_

La UI no puede instalar nuevas apps porque `html/apps` está como _read-only_. Tres causas posibles:

1. **`html/` montado como `:ro`** por error en el `docker-compose.yml`. Confirmar que **no** tiene `:ro`.
2. **El _entrypoint_ no completó el `chown`**. `docker exec nextcloud ls -la /var/www/html | head` debe mostrar `www-data www-data` como dueño. Si no, `docker compose restart nextcloud` (el _entrypoint_ vuelve a chown-ear).
3. **Disco lleno**. `df -h /mnt/hd2t`.

### `Background job task ID X has not been run for the past 2 days`

Algún _job_ del cron está bloqueado. Ver cuál:

```bash
docker exec -u www-data nextcloud php occ background-job:list --output=json | python3 -m json.tool
```

Suele ser un job de la app Photos (escaneo de imágenes nuevas) en una biblioteca enorme; el _sidecar_ `nextcloud-cron` lo ejecutará en el siguiente ciclo. Si lleva días así, forzar:

```bash
docker exec -u www-data nextcloud php occ background-job:execute <task_id>
```

### Subida de ficheros >2 GB falla con `Request Entity Too Large`

`PHP_UPLOAD_LIMIT` en `.env` debe ser ≥ tamaño deseado. El default `16G` ya cubre vídeos 4K. Si tras editar `.env` no surte efecto:

```bash
# Restart del contenedor para que recoja el env var nuevo
docker compose -f ~/homelab/almacen/docker-compose.yml up -d nextcloud
```

Y, en el cliente, asegurar que el _chunking_ está activo (default en cliente desktop ≥ 3.0).

### `Memory cache not configured` en _Settings → Administration → Overview_

El _check_ confirma que Nextcloud no encuentra Redis. Causas:

1. `nextcloud-redis` no está `(healthy)`. `docker logs nextcloud-redis`.
2. Las env vars `REDIS_HOST` / `REDIS_HOST_PORT` no se aplicaron. `docker exec nextcloud env | grep REDIS`.
3. La imagen oficial no autoconfigura Redis al arrancar — sólo lo hace en el primer arranque. Si Redis se añadió **después**, hay que escribirlo a mano:
   ```bash
   docker exec -u www-data nextcloud php occ config:system:set memcache.local --value='\OC\Memcache\APCu'
   docker exec -u www-data nextcloud php occ config:system:set memcache.distributed --value='\OC\Memcache\Redis'
   docker exec -u www-data nextcloud php occ config:system:set memcache.locking --value='\OC\Memcache\Redis'
   docker exec -u www-data nextcloud php occ config:system:set redis host --value=nextcloud-redis
   docker exec -u www-data nextcloud php occ config:system:set redis port --value=6379 --type=integer
   ```

### Habilitar GMP para WebAuthn (FIDO2)

La imagen oficial **no** trae `php-gmp`. Si se quiere usar llaves físicas (YubiKey, Solokey) como segundo factor:

```bash
# Construir una imagen derivada con php-gmp instalado, en ~/homelab/almacen/Dockerfile
cat > ~/homelab/almacen/Dockerfile <<'EOF'
ARG NEXTCLOUD_IMAGE_TAG=31-apache
FROM nextcloud:${NEXTCLOUD_IMAGE_TAG}
RUN apt-get update && \
    apt-get install -y libgmp-dev && \
    docker-php-ext-install gmp && \
    rm -rf /var/lib/apt/lists/*
EOF
```

Y en `docker-compose.yml`, sustituir el `image:` de `nextcloud` (y `nextcloud-cron`) por:

```yaml
build:
  context: .
  dockerfile: Dockerfile
  args:
    NEXTCLOUD_IMAGE_TAG: ${NEXTCLOUD_IMAGE_TAG}
image: nextcloud-with-gmp:${NEXTCLOUD_IMAGE_TAG}
```

`docker compose build && docker compose up -d nextcloud nextcloud-cron`.

> **Recordar**: Watchtower seguirá _opt-out_; el _bump_ de versión requiere `docker compose build --pull && up -d`.

### Habilitar Notify Push

`notify_push` corre como proceso aparte dentro del contenedor `nextcloud` en el puerto **7867**. Para usarlo:

1. App ya instalada (`occ app:install notify_push` lo hizo en _Apps recomendadas_).
2. Configurar la URL pública del servicio de push:
   ```bash
   docker exec -u www-data nextcloud php occ notify_push:setup https://nextcloud.lan/push
   ```
3. Editar `~/homelab/red/Caddyfile`, dentro del bloque `nextcloud.lan`, añadir antes del `reverse_proxy` general:
   ```caddy
   handle_path /push/* {
       reverse_proxy nextcloud:7867
   }
   ```
4. `caddy reload` y `docker exec nextcloud-cron php /var/www/html/occ notify_push:metrics` debe mostrar `redis: OK`, `subscribers: 0`.

---

## Migrar a OIDC con Authelia (opcional)

Cuando Authelia (`docs/04-seguridad/01-authelia.md`) esté montado y se quiera _Single Sign-On_ entre Nextcloud y el resto de `*.lan`, **sin** romper los clientes nativos:

1. Instalar la app oficial `user_oidc`:
   ```bash
   docker exec -u www-data nextcloud php occ app:install user_oidc
   docker exec -u www-data nextcloud php occ app:enable user_oidc
   ```
2. En `~/homelab/seguridad/configuration.yml` (Authelia), bajo `identity_providers.oidc.clients`, añadir un cliente para Nextcloud (la sección OIDC de Authelia se documenta cuando se active; queda fuera del alcance de este documento).
3. En Nextcloud, _Settings → Administration → OpenID Connect_, crear un proveedor:
   - **Discovery URL**: `https://auth.lan/.well-known/openid-configuration`
   - **Client ID**: `nextcloud`
   - **Client secret**: el generado en Authelia
   - **Mapping**: `sub → username`, `email → email`, `name → display name`.
4. **Mantener login local activo** (`occ config:app:set user_oidc allow_multiple_user_backends --value=true`) para que los clientes con _app password_ (que usan auth Basic) sigan funcionando. Lo único que cambia es que el _login web_ pasa por Authelia.

> **Resultado**: el navegador en `https://nextcloud.lan/` redirige a `https://auth.lan/` para el _login_ inicial, y después aprovecha la cookie de sesión de Authelia para no pedir credenciales de nuevo durante toda la sesión SSO. Los clientes desktop y móvil siguen usando _app passwords_ generadas en `Settings → Security` y **no** pasan por Authelia.

---

## Referencias

- Nextcloud — Documentación oficial del admin: <https://docs.nextcloud.com/server/latest/admin_manual/>
- Nextcloud — Imagen Docker oficial: <https://hub.docker.com/_/nextcloud>
- Nextcloud — Configuración con _reverse proxy_: <https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/reverse_proxy_configuration.html>
- Nextcloud — Servidor `notify_push`: <https://github.com/nextcloud/notify_push>
- Nextcloud — _Background jobs_ con cron: <https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/background_jobs_configuration.html>
- Nextcloud — `occ` _command reference_: <https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/occ_command.html>
- Nextcloud — App `user_oidc`: <https://github.com/nextcloud/user_oidc>
- Nextcloud — Service discovery (`.well-known`): <https://docs.nextcloud.com/server/latest/admin_manual/issues/general_troubleshooting.html#service-discovery>
- MariaDB — Imagen Docker oficial: <https://hub.docker.com/_/mariadb>
- MariaDB — Configuración recomendada por Nextcloud: <https://docs.nextcloud.com/server/latest/admin_manual/configuration_database/linux_database_configuration.html>
- Redis — Imagen Docker oficial: <https://hub.docker.com/_/redis>
- Redis — Eviction policies (`maxmemory-policy`): <https://redis.io/docs/reference/eviction/>
- Caddy — `reverse_proxy` directive: <https://caddyserver.com/docs/caddyfile/directives/reverse_proxy>
- DAVx⁵ — Cliente CalDAV/CardDAV para Android: <https://www.davx5.com/>
