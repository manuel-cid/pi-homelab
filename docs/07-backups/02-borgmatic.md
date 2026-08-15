# Borgmatic

## Descripción

Este documento despliega **Borgmatic** como servicio Docker para automatizar las copias de seguridad del homelab hacia un repositorio local en **`/media/hd2t/backups/borg/`**. La idea es centralizar en un único stack:

- lógica de backup, retención y validación
- política de retención
- hooks antes y después del backup
- notificaciones
- integración con dumps de bases de datos

La estrategia general 3-2-1 se define en [01-estrategia-backup.md](01-estrategia-backup.md). El detalle de qué volúmenes y qué dumps debe generar cada servicio se documenta en [03-backup-docker-volumes.md](03-backup-docker-volumes.md).

## Requisitos Previos

- Haber completado [01-estrategia-backup.md](01-estrategia-backup.md).
- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Haber completado [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md) y [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Tener montado **`hd2t`** en **`/media/hd2t`** con permisos de escritura.
- Tener creadas las rutas base de backup:
  - `/media/hd2t/backups/borg/`
  - `/media/hd2t/backups/exports/`
  - `/media/hd2t/backups/restore-test/`
- Tener desplegados los servicios con datos que vayan a entrar en backup.
- Si vas a usar hooks contra contenedores de bases de datos, permitir acceso a **`/var/run/docker.sock`** desde Borgmatic.
- Si vas a añadir destino offsite, disponer de clave SSH y conectividad saliente hacia ese destino.

Puertos necesarios en esta fase:

- ninguno a nivel host

## Docker Compose

Archivo: `/home/<user>/homelab/compose/infra-borgmatic/docker-compose.yml`

```yaml
name: infra-borgmatic

services:
  borgmatic:
    image: modem7/borgmatic-docker:2.1.7-1.4.5
    restart: unless-stopped
    hostname: homelab
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      DOCKERCLI: "true"
      CRON: "false"
    secrets:
      - postgres_backup_password
      - mariadb_backup_password
      - telegram_apprise_url
    volumes:
      - ${CONFIG_ROOT}/borgmatic:/etc/borgmatic.d
      - ${ROOT_DIR}/compose:/source/homelab/compose:ro
      - ${ROOT_DIR}/config:/source/homelab/config:ro
      - ${ROOT_DIR}/scripts:/source/homelab/scripts:ro
      - ${ROOT_DIR}/data:/source/homelab/data:ro
      - ${ROOT_DIR}/.env:/source/homelab/.env:ro
      - /media/hd2t/backups/borg:/mnt/borg-repository
      - /media/hd2t/backups/exports:/mnt/borg-exports
      - /media/hd2t/backups/restore-test:/mnt/restore-test
      - ${DATA_ROOT}/borgmatic/cache:/root/.cache/borg
      - ${DATA_ROOT}/borgmatic/state:/var/lib/borgmatic
      - ${DATA_ROOT}/borgmatic/runtime:/run/borgmatic
      - ${CONFIG_ROOT}/borgmatic/ssh:/root/.ssh:ro
      - /var/run/docker.sock:/var/run/docker.sock
    labels:
      - wud.watch=true
      - "wud.tag.include=^\\d+\\.\\d+\\.\\d+-\\d+\\.\\d+\\.\\d+$$"

secrets:
  postgres_backup_password:
    file: ${CONFIG_ROOT}/borgmatic/keys/postgres-backup-password
  mariadb_backup_password:
    file: ${CONFIG_ROOT}/borgmatic/keys/mariadb-backup-password
  telegram_apprise_url:
    file: ${CONFIG_ROOT}/borgmatic/keys/telegram-apprise-url
```

Variables mínimas recomendadas para `/home/<user>/homelab/compose/infra-borgmatic/.env`:

```dotenv
TZ=Europe/Madrid
ROOT_DIR=/home/<user>/homelab
CONFIG_ROOT=/home/<user>/homelab/config
DATA_ROOT=/home/<user>/homelab/data
```

Puntos importantes del stack:

- la configuración editable vive en **`/home/<user>/homelab/config/borgmatic/`**
- los orígenes a respaldar se montan en modo **solo lectura**
- el repositorio local Borg vive en **`/media/hd2t/backups/borg/`**
- el directorio `exports/` sirve como área de trabajo para dumps y exportaciones auxiliares que luego también quedan incorporados al backup lógico
- el directorio `restore-test/` se monta en **`/mnt/restore-test`** para que `borgmatic extract` pueda escribir restauraciones de prueba desde dentro del contenedor sin tocar producción; es el destino recomendado por [03-backup-docker-volumes.md](03-backup-docker-volumes.md) y **no** debe estar en `source_directories` para no respaldar restauraciones sobre sí mismas
- se monta el **socket Docker** para que los hooks o los data sources puedan ejecutar dumps en contenedores de PostgreSQL/MariaDB
- se fija **`CRON: "false"`** para **desactivar el cron interno de la imagen**: `modem7/borgmatic-docker` ejecuta borgmatic por su cuenta a las **01:00** si no se define `CRON`; en este proyecto la programación la lleva el host (`/etc/cron.d/`), así que hay que apagar el interno para no duplicar backups y notificaciones
- este Compose base no publica puertos; la ejecución periódica se dispara desde el host
- se fija **`hostname: homelab`** (el hostname real del host) para que `{hostname}` en la ruta del repositorio sea estable; sin esto Docker asigna el ID del contenedor como hostname y la ruta del repo cambia en cada recreación del contenedor, provocando errores `Repository does not exist`

## Configuración

### 1. Crear la estructura del stack

La estructura recomendada para este servicio es:

```text
/home/<user>/homelab/
├── compose/
│   └── infra-borgmatic/
│       ├── docker-compose.yml
│       └── .env
├── config/
│   └── borgmatic/
│       ├── config.yaml
│       ├── config-offsite.yaml.disabled
│       ├── keys/
│       │   ├── repository-passphrase
│       │   ├── postgres-backup-password
│       │   ├── mariadb-backup-password
│       │   └── telegram-apprise-url
│       ├── hooks/
│       │   ├── pre-backup.sh
│       │   ├── post-backup.sh
│       │   └── on-error.sh
│       └── ssh/
│           ├── config
│           └── id_ed25519
└── data/
    └── borgmatic/
        ├── cache/
        ├── runtime/
        └── state/
```

Permisos recomendados:

- `keys/` y `ssh/` con permisos restrictivos
- `repository-passphrase` con `chmod 600`
- scripts de `hooks/` con `chmod 750`

Comandos para crear la estructura:

```bash
# Directorios del compose
mkdir -p /home/<user>/homelab/compose/infra-borgmatic

# Directorios de configuración
mkdir -p /home/<user>/homelab/config/borgmatic/keys
mkdir -p /home/<user>/homelab/config/borgmatic/hooks
mkdir -p /home/<user>/homelab/config/borgmatic/ssh

# Directorios de datos
mkdir -p /home/<user>/homelab/data/borgmatic/cache
mkdir -p /home/<user>/homelab/data/borgmatic/runtime
mkdir -p /home/<user>/homelab/data/borgmatic/state

# Directorios de destino en hd2t
sudo mkdir -p /media/hd2t/backups/borg
sudo mkdir -p /media/hd2t/backups/exports
sudo mkdir -p /media/hd2t/backups/restore-test

# Ficheros placeholder del compose
touch /home/<user>/homelab/compose/infra-borgmatic/docker-compose.yml
touch /home/<user>/homelab/compose/infra-borgmatic/.env

# Ficheros de configuración
touch /home/<user>/homelab/config/borgmatic/config.yaml
touch /home/<user>/homelab/config/borgmatic/config-offsite.yaml.disabled

# Ficheros de secretos
touch /home/<user>/homelab/config/borgmatic/keys/repository-passphrase
touch /home/<user>/homelab/config/borgmatic/keys/postgres-backup-password
touch /home/<user>/homelab/config/borgmatic/keys/mariadb-backup-password
touch /home/<user>/homelab/config/borgmatic/keys/telegram-apprise-url

# Hooks
touch /home/<user>/homelab/config/borgmatic/hooks/pre-backup.sh
touch /home/<user>/homelab/config/borgmatic/hooks/post-backup.sh
touch /home/<user>/homelab/config/borgmatic/hooks/on-error.sh

# SSH (config placeholder; la clave se genera aparte)
touch /home/<user>/homelab/config/borgmatic/ssh/config

# Permisos restrictivos para keys y ssh
chmod 700 /home/<user>/homelab/config/borgmatic/keys
chmod 600 /home/<user>/homelab/config/borgmatic/keys/*
chmod 700 /home/<user>/homelab/config/borgmatic/ssh
chmod 600 /home/<user>/homelab/config/borgmatic/ssh/*

# Permisos ejecutables para hooks
chmod 750 /home/<user>/homelab/config/borgmatic/hooks/*.sh
```

### 2. Crear `config.yaml`

Archivo: `/home/<user>/homelab/config/borgmatic/config.yaml`

```yaml
source_directories:
  - /source/homelab/compose
  - /source/homelab/config
  - /source/homelab/scripts
  - /source/homelab/data
  - /source/homelab/.env
  - /mnt/borg-exports

repositories:
  - path: /mnt/borg-repository/{hostname}
    label: local
    encryption: repokey-blake2

archive_name_format: "{hostname}-{now:%Y-%m-%dT%H:%M:%S}"
compression: zstd,6
one_file_system: true
numeric_ids: true
exclude_caches: true
umask: 77
lock_wait: 60
user_runtime_directory: /run/borgmatic
user_state_directory: /var/lib/borgmatic
encryption_passcommand: cat /etc/borgmatic.d/keys/repository-passphrase

exclude_patterns:
  - /source/homelab/data/*/cache
  - /source/homelab/data/*/tmp
  - /source/homelab/data/*/transcodes
  - /source/homelab/data/*/thumbnails
  - /source/homelab/data/*/downloads/incomplete
  - /source/homelab/data/*/logs/*.log
  - /source/homelab/data/*/www/admin/api/sessions/*
  - /source/homelab/data/*/Library/Application Support/*/Cache
  - /source/homelab/data/borgmatic

keep_daily: 14
keep_weekly: 8
keep_monthly: 6
compact_threshold: 10

checks:
  - name: repository
    frequency: 1 month
  - name: archives
    frequency: 1 month

commands:
  - before: action
    when:
      - create
    run:
      - /etc/borgmatic.d/hooks/pre-backup.sh
  - after: action
    when:
      - create
    states:
      - finish
    run:
      - /etc/borgmatic.d/hooks/post-backup.sh
  - after: action
    when:
      - create
      - prune
      - compact
      - check
    states:
      - fail
    run:
      - /etc/borgmatic.d/hooks/on-error.sh

postgresql_databases:
  - name: all
    container: paperless-ngx-db-1
    username: postgres
    password: "{credential container postgres_backup_password}"
    format: directory
    compression: none

mariadb_databases:
  - name: all
    container: productivity-app-mariadb-1
    username: root
    password: "{credential container mariadb_backup_password}"
    format: sql

sqlite_databases:
  - name: vaultwarden
    path: /source/homelab/data/vaultwarden/db.sqlite3
  - name: uptime-kuma
    path: /source/homelab/data/uptime-kuma/kuma.db

apprise:
  services:
    - url: "{credential container telegram_apprise_url}"
      label: telegram
  send_logs: true
  logs_size_limit: 3500
  start:
    title: borgmatic
    body: Backup iniciado
  finish:
    title: borgmatic
    body: Backup completado
  fail:
    title: borgmatic
    body: Backup fallido
  states:
    - start
    - finish
    - fail
```

Notas operativas sobre este ejemplo:

- el repositorio local se crea bajo **`/media/hd2t/backups/borg/<hostname>/`**
- `{hostname}` se resuelve al hostname del contenedor; por eso el stack fija **`hostname: homelab`** en el Compose para que la ruta del repositorio no cambie al recrear el contenedor
- dentro del contenedor, los dumps previos se escriben en **`/mnt/borg-exports/`**, que corresponde a **`/media/hd2t/backups/exports/`** en el host
- se excluye **`/source/homelab/data/borgmatic`** porque el propio estado, caché y runtime de Borgmatic viven bajo `data/` y no deben respaldarse a sí mismos; son recreables y el `runtime/` es efímero durante `create`. Lo crítico de Borgmatic (config, hooks, keys, passphrase) ya se respalda vía `config/`
- los bloques `postgresql_databases`, `mariadb_databases` y `sqlite_databases` son una plantilla base; elimina lo que no uses
- los nombres de `container:` deben coincidir con los nombres reales que ve Docker en tu despliegue; en este proyecto eso significa normalmente el nombre generado por Compose, no un alias genérico como `postgres` o `mariadb`
- `paperless-ngx-db-1` y `productivity-app-mariadb-1` son ejemplos coherentes con la convención de nombres del repositorio, no valores universales
- el ejemplo base ya presupone secretos Docker para PostgreSQL, MariaDB y Telegram; si no vas a usar alguno de esos bloques, elimina también el secreto correspondiente del Compose
- los dumps detallados por servicio y el criterio exacto de restore se desarrollan en [03-backup-docker-volumes.md](03-backup-docker-volumes.md)
- la sección `apprise` de este ejemplo queda fijada para **Telegram**; si en algún momento desactivas notificaciones, elimina el bloque completo hasta definir otro backend

#### Convención de nombres para contenedores PostgreSQL y MariaDB

La convención general del repositorio viene de [02-estructura-compose.md](../02-docker/02-estructura-compose.md):

- cada stack fija `name:` con un identificador estable
- los servicios internos suelen tener nombres cortos como `db`, `postgres` o `mariadb`
- `container_name` se evita salvo que haga falta un nombre fijo por una razón operativa concreta

Traducción práctica para Borgmatic:

- el campo `container:` de `postgresql_databases` o `mariadb_databases` debe apuntar al **nombre real del contenedor** que devuelve Docker
- si el stack **no** define `container_name`, Docker Compose genera normalmente `<stack>-<servicio>-1`
- si el stack **sí** define `container_name`, usa ese valor exacto y no el nombre del servicio

Ejemplos coherentes con los Compose documentados en este proyecto:

- `paperless-ngx` usa `name: paperless-ngx` y un servicio PostgreSQL llamado `db`, así que el contenedor esperable es **`paperless-ngx-db-1`**
- si en otro stack defines `name: productivity-app` y un servicio `mariadb`, el contenedor esperable será **`productivity-app-mariadb-1`**
- si fijas `container_name: mealie`, Borgmatic debe usar **`mealie`**

Por tanto, el ejemplo base de este documento debe ajustarse así cuando el servicio real sea el de Paperless:

```yaml
postgresql_databases:
  - name: all
    container: paperless-ngx-db-1
    username: postgres
    password: "{credential container postgres_backup_password}"
    format: directory
    compression: none
```

Y para un stack con MariaDB sin `container_name`:

```yaml
mariadb_databases:
  - name: all
    container: productivity-app-mariadb-1
    username: root
    password: "{credential container mariadb_backup_password}"
    format: sql
```

Antes de activar un data source, valida el nombre efectivo con:

```bash
docker ps --format '{{.Names}}' | grep -E 'postgres|mariadb|db'
```

No des por hecho que el nombre será `postgres` o `mariadb`: en este homelab lo normal es que dependa del `name:` del stack y del nombre del servicio.

#### Inyección de credenciales para dumps

La opción recomendada en este proyecto es **Docker secrets en el stack de Borgmatic** y lectura desde `config.yaml` con las credenciales externas de Borgmatic. Es la vía más limpia para no dejar contraseñas en claro en el YAML y encaja bien con Docker Compose porque los secretos se montan como ficheros bajo `/run/secrets/` solo en los servicios que los declaran.

Ejemplo recomendado en `/home/<user>/homelab/compose/infra-borgmatic/docker-compose.yml`:

```yaml
name: infra-borgmatic

services:
  borgmatic:
    image: modem7/borgmatic-docker:2.1.7-1.4.5
    restart: unless-stopped
    hostname: homelab
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      DOCKERCLI: "true"
      CRON: "false"
    secrets:
      - postgres_backup_password
      - mariadb_backup_password
    volumes:
      - ${CONFIG_ROOT}/borgmatic:/etc/borgmatic.d
      - ${ROOT_DIR}/compose:/source/homelab/compose:ro
      - ${ROOT_DIR}/config:/source/homelab/config:ro
      - ${ROOT_DIR}/scripts:/source/homelab/scripts:ro
      - ${ROOT_DIR}/data:/source/homelab/data:ro
      - ${ROOT_DIR}/.env:/source/homelab/.env:ro
      - /media/hd2t/backups/borg:/mnt/borg-repository
      - /media/hd2t/backups/exports:/mnt/borg-exports
      - ${DATA_ROOT}/borgmatic/cache:/root/.cache/borg
      - ${DATA_ROOT}/borgmatic/state:/var/lib/borgmatic
      - ${DATA_ROOT}/borgmatic/runtime:/run/borgmatic
      - ${CONFIG_ROOT}/borgmatic/ssh:/root/.ssh:ro
      - /var/run/docker.sock:/var/run/docker.sock

secrets:
  postgres_backup_password:
    file: ${CONFIG_ROOT}/borgmatic/keys/postgres-backup-password
  mariadb_backup_password:
    file: ${CONFIG_ROOT}/borgmatic/keys/mariadb-backup-password
```

Ejemplo correspondiente en `config.yaml`:

```yaml
postgresql_databases:
  - name: all
    container: paperless-ngx-db-1
    username: postgres
    password: "{credential container postgres_backup_password}"

mariadb_databases:
  - name: all
    container: productivity-app-mariadb-1
    username: root
    password: "{credential container mariadb_backup_password}"
```

Buenas prácticas para esta opción:

- guarda los ficheros de secretos en `config/borgmatic/keys/`
- aplica `chmod 600` a cada fichero de secreto
- si la imagen de base de datos lo soporta, puedes inicializar también PostgreSQL o MariaDB con `*_PASSWORD_FILE` para no duplicar la contraseña en su propio Compose

La alternativa razonable es usar **variables de entorno restringidas** solo para el contenedor `borgmatic`. Funciona bien, es más simple de arrancar y Borgmatic permite interpolarlas directamente en `config.yaml`, pero expone más superficie que un secreto montado como fichero. Si eliges esta vía, separa esas variables en un fichero no versionado y con permisos estrictos.

Ejemplo alternativo en `/home/<user>/homelab/compose/infra-borgmatic/docker-compose.yml`:

```yaml
services:
  borgmatic:
    image: modem7/borgmatic-docker:2.1.7-1.4.5
    restart: unless-stopped
    hostname: homelab
    env_file:
      - .env
      - .env.secrets
```

Archivo recomendado: `/home/<user>/homelab/compose/infra-borgmatic/.env.secrets`

```dotenv
BORGMATIC_POSTGRES_PASSWORD=REEMPLAZAR_CON_PASSWORD_REAL
BORGMATIC_MARIADB_PASSWORD=REEMPLAZAR_CON_PASSWORD_REAL
```

Y su uso en `config.yaml`:

```yaml
postgresql_databases:
  - name: all
    container: paperless-ngx-db-1
    username: postgres
    password: ${BORGMATIC_POSTGRES_PASSWORD}

mariadb_databases:
  - name: all
    container: productivity-app-mariadb-1
    username: root
    password: ${BORGMATIC_MARIADB_PASSWORD}
```

Regla final para este homelab:

- **recomendado**: `Docker secrets` + `"{credential container ...}"`
- **aceptable**: `.env.secrets` con `chmod 600` y variables solo cargadas por el stack `infra-borgmatic`
- **evitar**: contraseñas literales dentro de `config.yaml`

#### Notificaciones por Telegram con Apprise

Para este homelab se fija **Telegram** como backend de notificaciones de Borgmatic. Es la opción más simple de las evaluadas porque no añade un servicio adicional al stack de backups, evita depender de un servidor SMTP externo y encaja con el soporte nativo de **Apprise** dentro de Borgmatic.

Preparación mínima fuera de Borgmatic:

1. crear un bot con **BotFather** y guardar el `bot token`
2. abrir un chat con ese bot y enviar al menos un mensaje
3. obtener el `chat_id` del destino con la API de Telegram

Ejemplo para localizar el `chat_id` después de haber enviado el primer mensaje:

```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates"
```

En la respuesta busca el bloque `chat` y anota el valor de `id` del chat, grupo o canal que deba recibir las alertas.

La recomendación práctica en este proyecto es guardar la **URL completa de Apprise** como secreto Docker. Así el token y el `chat_id` no quedan repartidos entre varios ficheros y se reutiliza el mismo mecanismo ya adoptado para las contraseñas de dumps.

Archivo recomendado: `/home/<user>/homelab/config/borgmatic/keys/telegram-apprise-url`

```text
tgram://123456789:ABCDEFghIJKlmNoPQRsTUVwxyz/123456789/?format=text&silent=no
```

Añade ese secreto al stack `infra-borgmatic`:

```yaml
services:
  borgmatic:
    secrets:
      - postgres_backup_password
      - mariadb_backup_password
      - telegram_apprise_url

secrets:
  postgres_backup_password:
    file: ${CONFIG_ROOT}/borgmatic/keys/postgres-backup-password
  mariadb_backup_password:
    file: ${CONFIG_ROOT}/borgmatic/keys/mariadb-backup-password
  telegram_apprise_url:
    file: ${CONFIG_ROOT}/borgmatic/keys/telegram-apprise-url
```

Y deja el bloque `apprise` de `config.yaml` así:

```yaml
apprise:
  services:
    - url: "{credential container telegram_apprise_url}"
      label: telegram
  send_logs: true
  logs_size_limit: 3500
  start:
    title: borgmatic
    body: Backup iniciado
  finish:
    title: borgmatic
    body: Backup completado
  fail:
    title: borgmatic
    body: Backup fallido
  states:
    - start
    - finish
    - fail
```

Detalles operativos de esta elección:

- `states:` se fija explícitamente para que Borgmatic notifique inicio, fin y error; si lo omites, el comportamiento por defecto no cubre necesariamente los tres eventos
- `logs_size_limit` se reduce respecto a un backend genérico para no mandar mensajes excesivamente grandes a Telegram
- si más adelante quieres publicar en un grupo o en un tema concreto de foro, cambia solo la URL secreta de Apprise y deja intacta la configuración de Borgmatic

Alternativas razonables si en el futuro cambia el criterio del homelab:

- **Gotify**: buena opción si quieres que todas las alertas del homelab queden autocontenidas, a costa de desplegar y mantener otro servicio
- **email/SMTP**: útil si ya tienes una cuenta o relay fiable, pero añade dependencia externa y gestión de credenciales adicional
- **sin notificaciones por ahora**: elimina el bloque `apprise` y conserva la validación operativa mediante `docker compose logs`, `cron` y revisiones manuales

### 3. Añadir programación desde el host

La programación se gestiona desde el **host** mediante un archivo en `/etc/cron.d/`, que es la opción preferida por ser declarativa, auditable y reproducible: el archivo queda documentado con ruta exacta, se puede versionar en el repo del homelab y al inspeccionar `/etc/cron.d/` se ven de un vistazo todos los cron del sistema.

> **Importante — desactiva el cron interno de la imagen:** `modem7/borgmatic-docker` incluye su **propio programador**. Si no defines la variable `CRON`, ejecuta borgmatic **por defecto a las 01:00** con los mensajes de `config.yaml`. Al usar el cron del host debes fijar **`CRON: "false"`** en el `environment` del contenedor (ya incluido en el Compose de este documento); si no, tendrás **backups y notificaciones duplicados** (uno a las 01:00 del cron interno y otro a la hora que definas en el host).

> **Importante:** las líneas siguientes son sintaxis de crontab, **no comandos bash**.
> No las pegues directamente en la terminal.

Crea el archivo `/etc/cron.d/homelab-borgmatic`:

```bash
sudo tee /etc/cron.d/homelab-borgmatic > /dev/null << 'EOF'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# backup diario a las 02:30
30 2 * * * root cd /home/<user>/homelab/compose/infra-borgmatic && docker compose exec -T borgmatic borgmatic --apprise.start.body "Create started" --apprise.finish.body "Create finished" --apprise.fail.body "Create failed" --stats --list --verbosity 1 create
# prune semanal (domingo 04:30)
30 4 * * 0 root cd /home/<user>/homelab/compose/infra-borgmatic && docker compose exec -T borgmatic borgmatic --apprise.start.body "Prune started" --apprise.finish.body "Prune finished" --apprise.fail.body "Prune failed " --stats --list --verbosity 1 prune
# compact después del prune (domingo 04:45)
45 4 * * 0 root cd /home/<user>/homelab/compose/infra-borgmatic && docker compose exec -T borgmatic borgmatic --apprise.start.body "Compact started" --apprise.finish.body "Compact finished" --apprise.fail.body "Compact failed" --verbosity 1 compact
# check mensual de repositorio y archivos (día 1, 05:00)
0 5 1 * * root cd /home/<user>/homelab/compose/infra-borgmatic && docker compose exec -T borgmatic borgmatic --apprise.start.body "Check started" --apprise.finish.body "Check finished " --apprise.fail.body "Check failed " --verbosity 1 check --only repository --only archives
EOF
```

Verifica que se ha creado correctamente:

```bash
cat /etc/cron.d/homelab-borgmatic
```

> **Nota sobre el formato `/etc/cron.d/`:** a diferencia de `crontab -e`, los archivos en `/etc/cron.d/` requieren un campo extra con el **usuario** (`root`) entre el schedule y el comando. El archivo debe terminar con una línea en blanco o un salto de línea final para que `cron` lo procese correctamente.

Si necesitas separar retención o ventana de ejecución entre **local** y **offsite**, usa un segundo fichero de configuración de Borgmatic en vez de mezclar políticas incompatibles en la misma rutina.

#### Indicar en el mensaje de Telegram qué tarea se ha ejecutado

El bloque `apprise` de `config.yaml` usa textos **estáticos** (`start.body`, `finish.body`, `fail.body`) y **no soporta interpolar el nombre de la acción** (`create`, `prune`, `compact`, `check`) dentro del mensaje. Las variables de interpolación (`{repository}`, `{configuration_filename}`, etc.) solo existen en los *command hooks*, no en el hook de Apprise.

Como cada línea de `/etc/cron.d/homelab-borgmatic` ejecuta **una sola acción**, la vía más limpia es sobreescribir el texto de la notificación por tarea con el command-line flag correspondiente de Borgmatic. Así cada cron envía su propio mensaje identificable a Telegram sin tocar `config.yaml`.

```bash
sudo tee /etc/cron.d/homelab-borgmatic > /dev/null << 'EOF'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# backup diario a las 02:30
30 2 * * * root cd /home/<user>/homelab/compose/infra-borgmatic && docker compose exec -T borgmatic borgmatic --apprise.start.title "📦 Borgmatic create Started 📦" --apprise.finish.title "📦 Borgmatic create Finished 📦" --apprise.fail.title "📦 Borgmatic create Failed 📦" --stats --list --verbosity 1 create
# prune semanal (domingo 04:30)
30 4 * * 0 root cd /home/<user>/homelab/compose/infra-borgmatic && docker compose exec -T borgmatic borgmatic --apprise.start.title "📦 Borgmatic prune Started 📦" --apprise.finish.title "📦 Borgmatic prune Finished 📦" --apprise.fail.title "📦 Borgmatic prune Failed 📦" --stats --list --verbosity 1 prune
# compact después del prune (domingo 04:45)
45 4 * * 0 root cd /home/<user>/homelab/compose/infra-borgmatic && docker compose exec -T borgmatic borgmatic --apprise.start.title "📦 Borgmatic compact Started 📦" --apprise.finish.title "📦 Borgmatic compact Finished 📦" --apprise.fail.title "📦 Borgmatic compact Failed 📦" --verbosity 1 compact
# check mensual de repositorio y archivos (día 1, 05:00)
0 5 1 * * root cd /home/<user>/homelab/compose/infra-borgmatic && docker compose exec -T borgmatic borgmatic --apprise.start.title "📦 Borgmatic check Started 📦" --apprise.finish.title "📦 Borgmatic check Finished 📦" --apprise.fail.title "📦 Borgmatic check Failed 📦" --verbosity 1 check --only repository --only archives
EOF
```

Notas sobre este enfoque:

- `--override` es un flag **global**, así que debe ir **antes** del nombre de la acción (`create`, `prune`, etc.)
- se sobreescribe **`body`** (no `title`) porque es el texto que Telegram muestra siempre; con `format=text` el `title` puede no aparecer de forma evidente
- los logs (`send_logs: true`) se siguen añadiendo **después** del `body`, así que no se pierde el detalle
- alternativa más flexible pero más compleja: usar *command hooks* (`commands:` con `after: action` y `when: [create]`, `when: [prune]`, etc.) que ejecuten un script propio de notificación; permite interpolar `{repository}` y `{configuration_filename}`, a costa de duplicar la lógica de envío fuera de Apprise

### 4. Preparar los hooks

Archivo: `/home/<user>/homelab/config/borgmatic/hooks/pre-backup.sh`

```bash
#!/bin/sh
set -eu

mkdir -p /mnt/borg-exports
find /mnt/borg-exports -type f -mtime +7 -delete
find /mnt/borg-exports -mindepth 1 -type d -empty -delete

echo "[$(date -Iseconds)] Preparando backup"
echo "[$(date -Iseconds)] Ejecuta aqui los dumps previos documentados en 03-backup-docker-volumes.md"
```

Archivo: `/home/<user>/homelab/config/borgmatic/hooks/post-backup.sh`

```bash
#!/bin/sh
set -eu

echo "[$(date -Iseconds)] Backup completado"
```

Archivo: `/home/<user>/homelab/config/borgmatic/hooks/on-error.sh`

```bash
#!/bin/sh
set -eu

echo "[$(date -Iseconds)] Borgmatic terminó con error" >&2
```

Qué debe hacer el `pre-backup.sh` en un despliegue real:

- generar dumps coherentes de PostgreSQL o MariaDB si no usas los data sources nativos
- congelar temporalmente aplicaciones si un servicio concreto lo requiere
- dejar esos artefactos en `/mnt/borg-exports/` antes de que empiece `borgmatic create`

Qué no debe hacer:

- copiar bibliotecas multimedia masivas
- detener todo el stack Docker sin necesidad
- borrar dumps recientes antes de validar el backup

### 5. Definir la passphrase del repositorio

El repositorio se crea cifrado (`encryption: repokey-blake2`), por lo que Borg necesita una passphrase que proteja la clave del repositorio. Borgmatic la obtiene ejecutando `encryption_passcommand: cat /etc/borgmatic.d/keys/repository-passphrase`, es decir, lee el contenido del fichero `keys/repository-passphrase`.

En el paso 1 ese fichero se crea **vacío** con `touch`. Debes rellenarlo con una passphrase fuerte **antes** de ejecutar `repo-create`; si lo dejas vacío, crearías un repositorio sin protección real.

```bash
# Generar una passphrase fuerte y guardarla en el fichero de secreto
openssl rand -base64 48 > /home/<user>/homelab/config/borgmatic/keys/repository-passphrase
chmod 600 /home/<user>/homelab/config/borgmatic/keys/repository-passphrase
```

Regla crítica:

- **guarda además una copia de la passphrase fuera del homelab** (gestor de contraseñas o copia offline); si la pierdes, pierdes el acceso a **todos** los backups y no hay forma de recuperarlos
- no cambies la passphrase después de crear el repositorio sin usar el procedimiento propio de Borg (`borg key change-passphrase`); el fichero por sí solo no re-cifra la clave existente

### 6. Inicializar y validar el repositorio local

Desde `/home/<user>/homelab/compose/infra-borgmatic/`:

```bash
docker compose up -d
docker compose exec borgmatic borgmatic config validate
docker compose exec borgmatic borgmatic repo-create --repository local
docker compose exec borgmatic borgmatic create --repository local --stats --list
docker compose exec borgmatic borgmatic repo-list --repository local
```

Objetivo de esta secuencia:

- validar el YAML antes de automatizar
- crear el repositorio local cifrado
- ejecutar una primera copia manual
- confirmar que aparecen archivos y archivos de control en el repositorio

#### Exportar y custodiar la clave del repositorio

Al ejecutar `repo-create`, Borg muestra el aviso `IMPORTANT: you will need both KEY AND PASSPHRASE to access this repo!`. Es un mensaje **genérico** para todos los modos de cifrado.

En modo `repokey-blake2` la **clave se guarda dentro del propio repositorio**, así que para el uso diario **basta con la passphrase**: la clave viaja siempre con el repo. El riesgo real aparece en recuperación ante desastres: si el repositorio se pierde o su cabecera se corrompe, la passphrase por sí sola **no reconstruye la clave** y perderías el acceso a los backups.

Por eso, guarda **por separado y fuera del homelab** dos cosas: la passphrase y una exportación de la clave.

```bash
# Exportar la clave a un fichero
docker compose exec borgmatic borg key export /mnt/borg-repository/homelab /root/borg-key-export.txt

# Sacar el fichero del contenedor al host
docker compose cp borgmatic:/root/borg-key-export.txt ./borg-key-export.txt

# (opcional) versión imprimible en papel
docker compose exec borgmatic borg key export --paper /mnt/borg-repository/homelab
```

Reglas de custodia:

- guarda `borg-key-export.txt` en un gestor de contraseñas, USB offline o en papel; **nunca** dentro del propio repositorio ni junto al disco `hd2t`
- elimina la copia temporal del host tras trasladarla a su ubicación segura
- vuelve a exportar la clave si en algún momento la cambias con `borg key change-passphrase`

### 7. Añadir destino offsite sin romper la operativa local

La estrategia offsite pertenece al criterio 3-2-1 descrito en [01-estrategia-backup.md](01-estrategia-backup.md). La recomendación práctica aquí es:

- empezar con el repositorio local en `hd2t`
- validar restauración local primero
- añadir después un segundo fichero de configuración para el destino remoto
- aplicar una retención más corta en offsite si el coste o el ancho de banda lo exigen

Archivo recomendado cuando actives la réplica remota: `/home/<user>/homelab/config/borgmatic/config-offsite.yaml`

Mientras solo estés validando el backup local, deja ese fichero fuera de `/home/<user>/homelab/config/borgmatic/` o con un sufijo como `.disabled` para que Borgmatic no lo cargue por error.

Ejemplo mínimo de segundo fichero de configuración para el destino remoto:

```yaml
repositories:
  - path: ssh://borg@backup-remoto/./homelab
    label: offsite
    encryption: repokey-blake2

keep_daily: 7
keep_weekly: 4
keep_monthly: 6
```

Regla operativa importante:

- Borgmatic interpreta cada fichero de configuración por separado; no asumas que `config.yaml` y `config-offsite.yaml` se fusionan automáticamente
- si quieres reutilizar la configuración base para local y offsite, crea `config-offsite.yaml` usando `include:` hacia `config.yaml` y redefine solo `repositories` y la retención remota
- si prefieres mantener ambas configuraciones totalmente separadas, duplica explícitamente en `config-offsite.yaml` las rutas de origen, hooks y credenciales necesarias

<!-- TODO: verificar un ejemplo cerrado de `include:` compatible con la versión concreta de Borgmatic que se fije finalmente en el stack. -->

### 8. Verificar que la automatización funciona

Comprobaciones mínimas después del despliegue:

- `docker compose logs -f borgmatic` no muestra errores de sintaxis ni de permisos
- `docker compose exec -T borgmatic borgmatic config validate` termina correctamente
- el backup manual crea un archivo nuevo en el repo local
- las notificaciones llegan al canal configurado
- las rutas del NVMe aparecen como montajes `:ro`
- la tarea `cron` del host queda instalada y ejecuta el contenedor sin pedir TTY

## Almacenamiento

Distribución recomendada de este servicio:

- **Configuración**
  - `/home/<user>/homelab/config/borgmatic/config.yaml`
  - `/home/<user>/homelab/config/borgmatic/hooks/`
  - `/home/<user>/homelab/config/borgmatic/keys/`
  - `/home/<user>/homelab/config/borgmatic/ssh/`
  - `/home/<user>/homelab/config/borgmatic/host-cron.example` si decides versionar la planificación del host
- **Estado del contenedor**
  - `/home/<user>/homelab/data/borgmatic/cache/`
  - `/home/<user>/homelab/data/borgmatic/runtime/`
  - `/home/<user>/homelab/data/borgmatic/state/`
- **Destino local**
  - `/media/hd2t/backups/borg/`
- **Exports auxiliares**
  - `/media/hd2t/backups/exports/`
- **Restauraciones de prueba**
  - `/media/hd2t/backups/restore-test/` montado en el contenedor como `/mnt/restore-test`

Regla importante:

- Borgmatic **lee** los datos persistentes del **SSD NVMe**
- Borgmatic **incorpora** también los dumps lógicos generados en `exports/`
- Borgmatic **escribe** el repositorio local en **`hd2t`**
- no se debe guardar el repositorio Borg dentro de `/home/<user>/homelab/data/`, porque mezclaría origen y destino

## Backup

Para Borgmatic, lo crítico a proteger es:

- `/home/<user>/homelab/config/borgmatic/`
- `/home/<user>/homelab/compose/infra-borgmatic/`
- la passphrase del repositorio
- la clave SSH del destino offsite si existe

Qué no se debe incluir dentro del mismo repositorio que Borgmatic gestiona:

- `/media/hd2t/backups/borg/` sobre sí mismo
- cachés recreables de Borg
- media grande de `hd2t` o `hd5t`

Regla práctica:

- el **repo local** es el resultado del backup
- la **configuración de Borgmatic** y sus claves forman parte del estado que debe poder recuperarse en un desastre
- la restauración de servicios concretos se ejecuta siguiendo [03-backup-docker-volumes.md](03-backup-docker-volumes.md)

## Referencias

- [01-estrategia-backup.md](01-estrategia-backup.md)
- [03-backup-docker-volumes.md](03-backup-docker-volumes.md)
- [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md)
- [02-estructura-compose.md](../02-docker/02-estructura-compose.md)
- Documentación oficial de Borgmatic: https://torsion.org/borgmatic/
- Referencia de configuración de Borgmatic: https://torsion.org/borgmatic/reference/configuration/
- Credenciales desde contenedor en Borgmatic: https://torsion.org/borgmatic/reference/configuration/credentials/container/
- Instalación de Borgmatic: https://torsion.org/borgmatic/how-to/install-borgmatic/
- Notificaciones y monitorización en Borgmatic: https://torsion.org/borgmatic/how-to/monitor-your-backups/
- Servicio Telegram en Apprise: https://github.com/caronc/apprise/wiki/Notify_telegram
- Telegram Bot API `getUpdates`: https://core.telegram.org/bots/api#getupdates
- Imagen Docker multi-arquitectura con soporte Docker CLI: https://github.com/modem7/docker-borgmatic
