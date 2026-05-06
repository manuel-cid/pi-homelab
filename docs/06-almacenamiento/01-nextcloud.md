# Nextcloud

## Descripción
**Nextcloud** será la nube privada del homelab para pruebas, aprendizaje y uso ligero: sincronización de archivos, calendario, contactos, enlaces compartidos internos y acceso web a documentos personales sin depender de servicios externos.

En esta arquitectura se despliega sobre la **Raspberry Pi 5** con:

- aplicación web de Nextcloud en contenedor Docker
- **MariaDB** como base de datos principal recomendada
- **Redis** para bloqueo de ficheros y caché distribuida
- todos los datos persistentes en el **SSD NVMe**
- publicación web interna detrás de **Caddy** con el FQDN `nextcloud.homelab.lan`

Aunque Nextcloud soporta también **PostgreSQL**, en esta guía se usa **MariaDB** como opción principal porque simplifica el arranque y encaja bien con un homelab pequeño. Más abajo se documenta qué cambiar si prefieres PostgreSQL.

Este documento asume un caso de uso deliberadamente contenido: pocos usuarios, sin exposición pública a internet, sin edición ofimática colaborativa pesada y sin querer convertir la Raspberry Pi en un sustituto de un NAS empresarial.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md` si vas a publicar Nextcloud con dominio interno.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `nextcloud.homelab.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Tener libre suficiente espacio en el SSD NVMe para:
  - datos de usuario de Nextcloud
  - base de datos
  - caché Redis
  - logs del servicio
- Poder usar `sudo` con el usuario administrador del homelab.
- Puertos implicados en esta fase:
  - `80/tcp` solo dentro de Docker entre Caddy y el contenedor `nextcloud`
  - `3306/tcp` solo dentro del stack entre Nextcloud y MariaDB
  - `6379/tcp` solo dentro del stack entre Nextcloud y Redis
  - `80/tcp` y `443/tcp` ya publicados por Caddy en el host

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/nextcloud/
├── compose.yaml
├── .env
└── php/
    └── zz-homelab.ini
```

Preparación inicial de rutas:

```bash
mkdir -p /home/<usuario>/homelab/compose/nextcloud/php
mkdir -p /home/<usuario>/homelab/data/nextcloud/{html,mariadb,redis}

sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/nextcloud
sudo find /home/<usuario>/homelab/data/nextcloud -type d -exec chmod 2775 {} \;
sudo find /home/<usuario>/homelab/data/nextcloud -type f -exec chmod 664 {} \;
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

NEXTCLOUD_IMAGE=nextcloud:apache
MARIADB_IMAGE=mariadb:11.4
REDIS_IMAGE=redis:7-alpine

NEXTCLOUD_ROOT_DIR=/home/<usuario>/homelab/data/nextcloud

NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=<CAMBIA_ESTA_PASSWORD>

NEXTCLOUD_DB_NAME=nextcloud
NEXTCLOUD_DB_USER=nextcloud
NEXTCLOUD_DB_PASSWORD=<CAMBIA_ESTA_PASSWORD_LARGA>
MARIADB_ROOT_PASSWORD=<CAMBIA_ESTA_PASSWORD_ROOT>

REDIS_PASSWORD=<CAMBIA_ESTA_PASSWORD_LARGA>

NEXTCLOUD_TRUSTED_DOMAINS=nextcloud.homelab.lan
NEXTCLOUD_TRUSTED_PROXIES=172.20.0.0/16
NEXTCLOUD_OVERWRITEHOST=nextcloud.homelab.lan
NEXTCLOUD_OVERWRITEPROTOCOL=https
NEXTCLOUD_OVERWRITECLIURL=https://nextcloud.homelab.lan

PHP_MEMORY_LIMIT=512M
PHP_UPLOAD_LIMIT=10G
```

Importante:

- `NEXTCLOUD_TRUSTED_PROXIES` debe ajustarse a la subred real desde la que Caddy alcanza a Nextcloud.
- puedes comprobarla con `docker network inspect homelab_proxy`
- si no la ajustas bien, Nextcloud puede registrar la IP del proxy en lugar de la IP cliente real

Fichero `compose.yaml`:

```yaml
name: nextcloud

services:
  mariadb:
    container_name: nextcloud-mariadb
    image: ${MARIADB_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      MARIADB_AUTO_UPGRADE: "1"
      MARIADB_DATABASE: ${NEXTCLOUD_DB_NAME}
      MARIADB_USER: ${NEXTCLOUD_DB_USER}
      MARIADB_PASSWORD: ${NEXTCLOUD_DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
    command:
      - --transaction-isolation=READ-COMMITTED
      - --binlog-format=ROW
      - --innodb-read-only-compressed=OFF
    volumes:
      - ${NEXTCLOUD_ROOT_DIR}/mariadb:/var/lib/mysql
    networks:
      - default
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    security_opt:
      - no-new-privileges:true

  redis:
    container_name: nextcloud-redis
    image: ${REDIS_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    command:
      - redis-server
      - --appendonly
      - "yes"
      - --requirepass
      - ${REDIS_PASSWORD}
    volumes:
      - ${NEXTCLOUD_ROOT_DIR}/redis:/data
    networks:
      - default
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 30s
      timeout: 10s
      retries: 5
    security_opt:
      - no-new-privileges:true

  nextcloud:
    container_name: nextcloud
    image: ${NEXTCLOUD_IMAGE}
    restart: unless-stopped
    depends_on:
      mariadb:
        condition: service_healthy
      redis:
        condition: service_healthy
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      MYSQL_HOST: mariadb
      MYSQL_DATABASE: ${NEXTCLOUD_DB_NAME}
      MYSQL_USER: ${NEXTCLOUD_DB_USER}
      MYSQL_PASSWORD: ${NEXTCLOUD_DB_PASSWORD}
      REDIS_HOST: redis
      REDIS_HOST_PASSWORD: ${REDIS_PASSWORD}
      NEXTCLOUD_ADMIN_USER: ${NEXTCLOUD_ADMIN_USER}
      NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASSWORD}
      NEXTCLOUD_TRUSTED_DOMAINS: ${NEXTCLOUD_TRUSTED_DOMAINS}
      TRUSTED_PROXIES: ${NEXTCLOUD_TRUSTED_PROXIES}
      OVERWRITEHOST: ${NEXTCLOUD_OVERWRITEHOST}
      OVERWRITEPROTOCOL: ${NEXTCLOUD_OVERWRITEPROTOCOL}
      OVERWRITECLIURL: ${NEXTCLOUD_OVERWRITECLIURL}
      PHP_MEMORY_LIMIT: ${PHP_MEMORY_LIMIT}
      PHP_UPLOAD_LIMIT: ${PHP_UPLOAD_LIMIT}
    volumes:
      - ${NEXTCLOUD_ROOT_DIR}/html:/var/www/html
      - ./php/zz-homelab.ini:/usr/local/etc/php/conf.d/zz-homelab.ini:ro
    networks:
      - default
      - homelab_proxy
    security_opt:
      - no-new-privileges:true

  cron:
    container_name: nextcloud-cron
    image: ${NEXTCLOUD_IMAGE}
    restart: unless-stopped
    depends_on:
      - nextcloud
    entrypoint: /cron.sh
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      MYSQL_HOST: mariadb
      MYSQL_DATABASE: ${NEXTCLOUD_DB_NAME}
      MYSQL_USER: ${NEXTCLOUD_DB_USER}
      MYSQL_PASSWORD: ${NEXTCLOUD_DB_PASSWORD}
      REDIS_HOST: redis
      REDIS_HOST_PASSWORD: ${REDIS_PASSWORD}
    volumes:
      - ${NEXTCLOUD_ROOT_DIR}/html:/var/www/html
      - ./php/zz-homelab.ini:/usr/local/etc/php/conf.d/zz-homelab.ini:ro
    networks:
      - default
    security_opt:
      - no-new-privileges:true

networks:
  homelab_proxy:
    external: true
    name: homelab_proxy
```

Fichero `php/zz-homelab.ini`:

```ini
memory_limit=512M
upload_max_filesize=10G
post_max_size=10G
max_execution_time=3600
max_input_time=3600
output_buffering=0
apc.enable_cli=1
```

Despliegue inicial:

```bash
cd /home/<usuario>/homelab/compose/nextcloud
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f nextcloud
```

Resultado esperado tras el primer arranque:

- se crea la estructura persistente en `/home/<usuario>/homelab/data/nextcloud/`
- Nextcloud inicializa la base de datos automáticamente
- `config.php` queda generado dentro de `/home/<usuario>/homelab/data/nextcloud/html/config/`
- el contenedor `cron` ejecuta las tareas en segundo plano
- el servicio queda accesible internamente para Caddy como `http://nextcloud:80`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| FQDN interno | `https://nextcloud.homelab.lan` |
| Publicación web | detrás de Caddy |
| Base de datos | MariaDB en el SSD NVMe |
| Caché y file locking | Redis en el SSD NVMe |
| Datos de usuario | `/home/<usuario>/homelab/data/nextcloud/html/data/` |
| Background jobs | modo `cron` |
| Exposición pública | ninguna |

### 1. Integrar Nextcloud en Caddy

Partiendo del `Caddyfile` documentado en `docs/03-red/04-caddy.md`, añade un bloque específico para Nextcloud:

```caddyfile
nextcloud.homelab.lan {
  import common
  tls internal

  redir /.well-known/carddav /remote.php/dav 301
  redir /.well-known/caldav /remote.php/dav 301

  reverse_proxy nextcloud:80 {
    header_up X-Forwarded-Proto {scheme}
    header_up X-Forwarded-Host {host}
  }
}
```

Después recarga Caddy:

```bash
cd /home/<usuario>/homelab/compose/caddy
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Notas prácticas:

- Nextcloud debe compartir la red `homelab_proxy` con Caddy.
- No hace falta publicar puertos del contenedor `nextcloud` en el host.
- Si más adelante añades Authelia, prueba con cuidado la compatibilidad de clientes WebDAV, CalDAV y CardDAV antes de forzar `forward_auth` en todo el sitio.

### 2. Revisar `config.php` tras la instalación automática

El instalador por variables de entorno resuelve el arranque inicial, pero conviene verificar el fichero real de configuración:

```bash
sudo sed -n '1,220p' /home/<usuario>/homelab/data/nextcloud/html/config/config.php
```

Como mínimo debería reflejar valores equivalentes a estos:

```php
'trusted_domains' =>
  array (
    0 => 'nextcloud.homelab.lan',
  ),
'trusted_proxies' =>
  array (
    0 => '172.20.0.0/16',
  ),
'overwritehost' => 'nextcloud.homelab.lan',
'overwriteprotocol' => 'https',
'overwrite.cli.url' => 'https://nextcloud.homelab.lan',
'default_phone_region' => 'ES',
'log_type' => 'file',
'logfile' => '/var/www/html/data/nextcloud.log',
'loglevel' => 2,
'memcache.local' => '\\OC\\Memcache\\APCu',
'memcache.locking' => '\\OC\\Memcache\\Redis',
'redis' =>
  array (
    'host' => 'redis',
    'port' => 6379,
    'password' => '<REDIS_PASSWORD>',
  ),
```

Si alguno de esos parámetros no aparece todavía, puedes fijarlo con `occ` o editando `config.php` con cautela.

Ejemplo para establecer región y logging:

```bash
docker exec -u www-data nextcloud php occ config:system:set default_phone_region --value=ES
docker exec -u www-data nextcloud php occ config:system:set log_type --value=file
docker exec -u www-data nextcloud php occ config:system:set logfile --value=/var/www/html/data/nextcloud.log
docker exec -u www-data nextcloud php occ config:system:set loglevel --type=integer --value=2
```

### 3. Cambiar el modo de tareas en segundo plano a `cron`

La práctica recomendada es evitar AJAX para tareas en segundo plano:

1. Entra en Nextcloud como administrador.
2. Ve a `Ajustes de administración` -> `Configuración básica`.
3. En `Trabajos en segundo plano`, selecciona `Cron`.

Comprobación rápida:

```bash
docker compose logs --tail=50 cron
```

### 4. Ajustes recomendados para un uso ligero en Raspberry Pi 5

Configura estas opciones en la UI o mediante `occ`:

- idioma y zona horaria correctos
- región telefónica por defecto, útil para contactos
- límite de subida coherente con el tamaño real de tus ficheros
- desactivar cualquier app que no vayas a usar para ahorrar RAM y mantenimiento

Comandos útiles:

```bash
docker exec -u www-data nextcloud php occ maintenance:mode --off
docker exec -u www-data nextcloud php occ status
docker exec -u www-data nextcloud php occ app:list
```

Para un homelab de aprendizaje conviene empezar con pocas apps:

- **Files**: base del servicio
- **Calendar**: calendario CalDAV
- **Contacts**: libreta CardDAV
- **Notes**: notas sencillas
- **Tasks**: gestión ligera de tareas
- **Deck**: opcional, solo si quieres probar organización tipo kanban

Apps que conviene posponer en una Raspberry Pi salvo que tengas una necesidad clara:

- suites ofimáticas integradas tipo **Collabora** u **OnlyOffice**
- indexación y búsqueda pesada
- generación masiva de previews
- flujos de automatización complejos con muchas apps de terceros

### 5. Endurecimiento mínimo recomendado

Para este homelab LAN + Tailscale, sin exposición pública, las medidas mínimas razonables son:

- usar una contraseña administrativa distinta de la usada en `.env` si el stack ya quedó inicializado
- habilitar **2FA nativo de Nextcloud** para las cuentas que accedan desde fuera de casa por Tailscale
- usar **contraseñas de aplicación** para clientes de sincronización, móviles y DAV cuando corresponda
- no abrir el servicio en el router
- mantener `trusted_domains`, `trusted_proxies` y `overwriteprotocol` bien definidos
- revisar periódicamente `nextcloud.log`

### 6. Alternativa con PostgreSQL

Si prefieres **PostgreSQL**, la topología general no cambia: Nextcloud sigue en el SSD NVMe, Redis sigue siendo recomendable y Caddy sigue publicando `nextcloud.homelab.lan`.

Sustituciones principales:

1. Reemplaza el servicio `mariadb` por un servicio `postgres`.
2. Cambia las variables `MYSQL_*` por `POSTGRES_*`.
3. Cambia la ruta persistente a algo como `/home/<usuario>/homelab/data/nextcloud/postgres:/var/lib/postgresql/data`.

Ejemplo mínimo del servicio:

```yaml
  postgres:
    container_name: nextcloud-postgres
    image: postgres:17-alpine
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      POSTGRES_DB: ${NEXTCLOUD_DB_NAME}
      POSTGRES_USER: ${NEXTCLOUD_DB_USER}
      POSTGRES_PASSWORD: ${NEXTCLOUD_DB_PASSWORD}
    volumes:
      - /home/<usuario>/homelab/data/nextcloud/postgres:/var/lib/postgresql/data
```

Y en `nextcloud`:

```yaml
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_DB: ${NEXTCLOUD_DB_NAME}
      POSTGRES_USER: ${NEXTCLOUD_DB_USER}
      POSTGRES_PASSWORD: ${NEXTCLOUD_DB_PASSWORD}
```

No mezcles `MYSQL_*` y `POSTGRES_*` en el mismo despliegue. Elige una sola base de datos desde el principio.

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose de Nextcloud | `/home/<usuario>/homelab/compose/nextcloud/` | SSD NVMe |
| Variables del stack | `/home/<usuario>/homelab/compose/nextcloud/.env` | SSD NVMe |
| Ajustes PHP | `/home/<usuario>/homelab/compose/nextcloud/php/zz-homelab.ini` | SSD NVMe |
| Aplicación, config, apps y datos de usuario | `/home/<usuario>/homelab/data/nextcloud/html/` | SSD NVMe |
| Base de datos MariaDB | `/home/<usuario>/homelab/data/nextcloud/mariadb/` | SSD NVMe |
| Persistencia Redis | `/home/<usuario>/homelab/data/nextcloud/redis/` | SSD NVMe |
| Backups del stack y exports | `/mnt/hd2t/backups/...` | `hd2t` |

Notas de almacenamiento:

- en este homelab **no** se recomienda poner la base de datos de Nextcloud en `hd2t` ni en `hd5t`
- tampoco conviene mover el directorio `data/` de Nextcloud a un HDD USB si el objetivo es tener una experiencia ágil
- `hd2t` es buen destino para backups, exportaciones y snapshots externos del stack
- `hd5t` no interviene en Nextcloud

Permisos recomendados:

```bash
sudo chmod 750 /home/<usuario>/homelab/data/nextcloud
sudo find /home/<usuario>/homelab/data/nextcloud -type d -exec chmod 750 {} \;
sudo find /home/<usuario>/homelab/data/nextcloud -type f -exec chmod 640 {} \;
```

Sobre propietarios y UID/GID:

- si creas las carpetas manualmente, lo más seguro es levantar primero el stack y ver qué UID/GID asigna cada imagen
- evita fijar a ciegas IDs numéricos si no los has comprobado en tu entorno
- si detectas errores de escritura, inspecciona primero con `ls -ln /home/<usuario>/homelab/data/nextcloud`

## Backup
Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/nextcloud/compose.yaml`
- `/home/<usuario>/homelab/compose/nextcloud/.env`
- `/home/<usuario>/homelab/compose/nextcloud/php/zz-homelab.ini`
- `/home/<usuario>/homelab/data/nextcloud/html/`
- `/home/<usuario>/homelab/data/nextcloud/mariadb/`
- `/home/<usuario>/homelab/data/nextcloud/redis/`

El directorio más importante es `html/` porque contiene:

- `config/config.php`
- el directorio `data/` con los ficheros subidos por usuarios
- apps instaladas manualmente
- temas o personalizaciones locales
- `nextcloud.log`

Estrategia práctica de copia consistente con MariaDB:

```bash
mkdir -p /mnt/hd2t/backups/nextcloud
set -a
. /home/<usuario>/homelab/compose/nextcloud/.env
set +a
docker exec -u www-data nextcloud php occ maintenance:mode --on
docker exec nextcloud-mariadb mariadb-dump -u root -p"${MARIADB_ROOT_PASSWORD}" --single-transaction --quick --lock-tables=false nextcloud > /mnt/hd2t/backups/nextcloud/nextcloud-$(date +%F).sql
rsync -a /home/<usuario>/homelab/compose/nextcloud/ /mnt/hd2t/backups/nextcloud/compose/
rsync -a /home/<usuario>/homelab/data/nextcloud/html/ /mnt/hd2t/backups/nextcloud/html/
rsync -a /home/<usuario>/homelab/data/nextcloud/redis/ /mnt/hd2t/backups/nextcloud/redis/
docker exec -u www-data nextcloud php occ maintenance:mode --off
```

Si usas PostgreSQL, sustituye el dump por:

```bash
docker exec -u www-data nextcloud php occ maintenance:mode --on
docker exec -t nextcloud-postgres pg_dump -U "${NEXTCLOUD_DB_USER}" "${NEXTCLOUD_DB_NAME}" > /mnt/hd2t/backups/nextcloud/nextcloud-$(date +%F).sql
rsync -a /home/<usuario>/homelab/compose/nextcloud/ /mnt/hd2t/backups/nextcloud/compose/
rsync -a /home/<usuario>/homelab/data/nextcloud/html/ /mnt/hd2t/backups/nextcloud/html/
rsync -a /home/<usuario>/homelab/data/nextcloud/redis/ /mnt/hd2t/backups/nextcloud/redis/
docker exec -u www-data nextcloud php occ maintenance:mode --off
```

Para restauraciones grandes o migraciones de host:

1. Restaurar primero el directorio del stack en el NVMe.
2. Restaurar después `html/` completo.
3. Restaurar la base de datos correspondiente.
4. Levantar el stack con `docker compose up -d`.
5. Ejecutar una comprobación:

```bash
docker exec -u www-data nextcloud php occ maintenance:repair
docker exec -u www-data nextcloud php occ files:scan --all
```

No es necesario respaldar:

- la imagen `nextcloud`
- el contenedor recreable
- la red `homelab_proxy`

## Referencias
- Nextcloud Admin Manual  
  https://docs.nextcloud.com/server/stable/admin_manual/
- Nextcloud Admin Manual: Reverse proxy configuration  
  https://docs.nextcloud.com/server/stable/admin_manual/configuration_server/reverse_proxy_configuration.html
- Nextcloud Admin Manual: Memory caching  
  https://docs.nextcloud.com/server/stable/admin_manual/configuration_server/caching_configuration.html
- Nextcloud Admin Manual: Background jobs  
  https://docs.nextcloud.com/server/stable/admin_manual/configuration_server/background_jobs_configuration.html
- Imagen Docker oficial de Nextcloud  
  https://hub.docker.com/_/nextcloud
- Repositorio oficial de la imagen Docker de Nextcloud  
  https://github.com/nextcloud/docker
- Imagen Docker oficial de MariaDB  
  https://hub.docker.com/_/mariadb
- Imagen Docker oficial de PostgreSQL  
  https://hub.docker.com/_/postgres
- Imagen Docker oficial de Redis  
  https://hub.docker.com/_/redis
