# Borgmatic

## Descripción

Este documento despliega **Borgmatic** como servicio Docker para automatizar las copias de seguridad del homelab hacia un repositorio local en **`/mnt/hd2t/backups/borg/`**. La idea es centralizar en un único stack:

- ejecución programada
- política de retención
- hooks antes y después del backup
- notificaciones
- integración con dumps de bases de datos

La estrategia general 3-2-1 se define en [01-estrategia-backup.md](/Users/x441425/workspace2/homelab/docs/07-backups/01-estrategia-backup.md). El detalle de qué volúmenes y qué dumps debe generar cada servicio se documenta en [03-backup-docker-volumes.md](/Users/x441425/workspace2/homelab/docs/07-backups/03-backup-docker-volumes.md).

## Requisitos Previos

- Haber completado [01-estrategia-backup.md](/Users/x441425/workspace2/homelab/docs/07-backups/01-estrategia-backup.md).
- Haber completado [04-estructura-directorios.md](/Users/x441425/workspace2/homelab/docs/01-sistema/04-estructura-directorios.md).
- Haber completado [01-instalacion-docker.md](/Users/x441425/workspace2/homelab/docs/02-docker/01-instalacion-docker.md) y [02-estructura-compose.md](/Users/x441425/workspace2/homelab/docs/02-docker/02-estructura-compose.md).
- Tener montado **`hd2t`** en **`/mnt/hd2t`** con permisos de escritura.
- Tener creadas las rutas base de backup:
  - `/mnt/hd2t/backups/borg/`
  - `/mnt/hd2t/backups/exports/`
  - `/mnt/hd2t/backups/restore-test/`
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
    image: modem7/borgmatic-docker:latest
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      DOCKERCLI: "true"
    volumes:
      - ${CONFIG_ROOT}/borgmatic:/etc/borgmatic.d
      - ${ROOT_DIR}/compose:/source/homelab/compose:ro
      - ${ROOT_DIR}/config:/source/homelab/config:ro
      - ${ROOT_DIR}/scripts:/source/homelab/scripts:ro
      - ${ROOT_DIR}/data:/source/homelab/data:ro
      - ${ROOT_DIR}/.env:/source/homelab/.env:ro
      - /mnt/hd2t/backups/borg:/mnt/borg-repository
      - /mnt/hd2t/backups/exports:/mnt/borg-exports
      - ${DATA_ROOT}/borgmatic/cache:/root/.cache/borg
      - ${DATA_ROOT}/borgmatic/state:/var/lib/borgmatic
      - ${DATA_ROOT}/borgmatic/runtime:/run/borgmatic
      - ${CONFIG_ROOT}/borgmatic/ssh:/root/.ssh:ro
      - /var/run/docker.sock:/var/run/docker.sock
    labels:
      - com.centurylinklabs.watchtower.enable=true
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
- el repositorio local Borg vive en **`/mnt/hd2t/backups/borg/`**
- el directorio `exports/` sirve para dumps o exportaciones auxiliares que quieras conservar fuera del repositorio
- se monta el **socket Docker** para que los hooks o los data sources puedan ejecutar dumps en contenedores de PostgreSQL/MariaDB

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
│       ├── crontab.txt
│       ├── keys/
│       │   └── repository-passphrase
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

### 2. Crear `config.yaml`

Archivo: `/home/<user>/homelab/config/borgmatic/config.yaml`

```yaml
source_directories:
  - /source/homelab/compose
  - /source/homelab/config
  - /source/homelab/scripts
  - /source/homelab/data
  - /source/homelab/.env

repositories:
  - path: /mnt/borg-repository/{hostname}
    label: local
    encryption: repokey-blake2

archive_name_format: "{hostname}-homelab-{now:%Y-%m-%dT%H:%M:%S}"
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
    container: postgres
    username: postgres
    password: "<postgres-password>"
    format: directory
    compression: none

mariadb_databases:
  - name: all
    container: mariadb
    username: root
    password: "<mariadb-root-password>"
    password_transport: environment
    format: sql

sqlite_databases:
  - name: vaultwarden
    path: /source/homelab/data/vaultwarden/db.sqlite3
  - name: uptime-kuma
    path: /source/homelab/data/uptime-kuma/kuma.db

apprise:
  services:
    - url: gotify://gotify.local/<token>
      label: gotify
  send_logs: true
  logs_size_limit: 50000
  start:
    title: borgmatic
    body: Backup iniciado
  finish:
    title: borgmatic
    body: Backup completado
  fail:
    title: borgmatic
    body: Backup fallido
```

Notas operativas sobre este ejemplo:

- el repositorio local se crea bajo **`/mnt/hd2t/backups/borg/<hostname>/`**
- el bloque `postgresql_databases`, `mariadb_databases` y `sqlite_databases` es una plantilla base; elimina lo que no uses
- los nombres de `container:` deben coincidir con los nombres reales que ve Docker en tu despliegue
- los dumps detallados por servicio y el criterio exacto de restore se desarrollan en [03-backup-docker-volumes.md](/Users/x441425/workspace2/homelab/docs/07-backups/03-backup-docker-volumes.md)

### 3. Añadir programación con `crontab.txt`

Archivo: `/home/<user>/homelab/config/borgmatic/crontab.txt`

```cron
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

30 2 * * * borgmatic --stats --list --verbosity 1 create
30 4 * * 0 borgmatic --stats --list --verbosity 1 prune
45 4 * * 0 borgmatic --verbosity 1 compact
0 5 1 * * borgmatic --verbosity 1 check --only repository --only archives
```

Esta programación sigue la política de la fase:

- backup diario a las `02:30`
- `prune` semanal el domingo
- `compact` después del `prune`
- `check` mensual de repositorio y archivos

Si necesitas separar retención o ventana de ejecución entre **local** y **offsite**, usa un segundo fichero de configuración de Borgmatic en vez de mezclar políticas incompatibles en la misma rutina.

### 4. Preparar los hooks

Archivo: `/home/<user>/homelab/config/borgmatic/hooks/pre-backup.sh`

```bash
#!/bin/sh
set -eu

mkdir -p /mnt/borg-exports
find /mnt/borg-exports -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +

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
- exportar ficheros administrativos pequeños a `/mnt/hd2t/backups/exports/`

Qué no debe hacer:

- copiar bibliotecas multimedia masivas
- detener todo el stack Docker sin necesidad
- borrar dumps recientes antes de validar el backup

### 5. Inicializar y validar el repositorio local

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

### 6. Añadir destino offsite sin romper la operativa local

La estrategia offsite pertenece al criterio 3-2-1 descrito en [01-estrategia-backup.md](/Users/x441425/workspace2/homelab/docs/07-backups/01-estrategia-backup.md). La recomendación práctica aquí es:

- empezar con el repositorio local en `hd2t`
- validar restauración local primero
- añadir después un segundo fichero de configuración para el destino remoto
- aplicar una retención más corta en offsite si el coste o el ancho de banda lo exigen

Ejemplo mínimo de segundo repositorio remoto dentro de otro fichero `config-offsite.yaml`:

```yaml
repositories:
  - path: ssh://borg@backup-remoto/./rpi5-homelab
    label: offsite
    encryption: repokey-blake2

keep_daily: 7
keep_weekly: 4
keep_monthly: 6
```

### 7. Verificar que la automatización funciona

Comprobaciones mínimas después del despliegue:

- `docker compose logs -f borgmatic` no muestra errores de sintaxis ni de permisos
- `borgmatic config validate` termina correctamente
- el backup manual crea un archivo nuevo en el repo local
- las notificaciones llegan al canal configurado
- `crontab.txt` queda montado dentro del contenedor junto a `config.yaml`
- las rutas del NVMe aparecen como montajes `:ro`

## Almacenamiento

Distribución recomendada de este servicio:

- **Configuración**
  - `/home/<user>/homelab/config/borgmatic/config.yaml`
  - `/home/<user>/homelab/config/borgmatic/crontab.txt`
  - `/home/<user>/homelab/config/borgmatic/hooks/`
  - `/home/<user>/homelab/config/borgmatic/keys/`
  - `/home/<user>/homelab/config/borgmatic/ssh/`
- **Estado del contenedor**
  - `/home/<user>/homelab/data/borgmatic/cache/`
  - `/home/<user>/homelab/data/borgmatic/runtime/`
  - `/home/<user>/homelab/data/borgmatic/state/`
- **Destino local**
  - `/mnt/hd2t/backups/borg/`
- **Exports auxiliares**
  - `/mnt/hd2t/backups/exports/`

Regla importante:

- Borgmatic **lee** los datos persistentes del **SSD NVMe**
- Borgmatic **escribe** el repositorio local en **`hd2t`**
- no se debe guardar el repositorio Borg dentro de `/home/<user>/homelab/data/`, porque mezclaría origen y destino

## Backup

Para Borgmatic, lo crítico a proteger es:

- `/home/<user>/homelab/config/borgmatic/`
- `/home/<user>/homelab/compose/infra-borgmatic/`
- la passphrase del repositorio
- la clave SSH del destino offsite si existe

Qué no se debe incluir dentro del mismo repositorio que Borgmatic gestiona:

- `/mnt/hd2t/backups/borg/` sobre sí mismo
- cachés recreables de Borg
- media grande de `hd2t` o `hd5t`

Regla práctica:

- el **repo local** es el resultado del backup
- la **configuración de Borgmatic** y sus claves forman parte del estado que debe poder recuperarse en un desastre
- la restauración de servicios concretos se ejecuta siguiendo [03-backup-docker-volumes.md](/Users/x441425/workspace2/homelab/docs/07-backups/03-backup-docker-volumes.md)

## Referencias

- [01-estrategia-backup.md](/Users/x441425/workspace2/homelab/docs/07-backups/01-estrategia-backup.md)
- [03-backup-docker-volumes.md](/Users/x441425/workspace2/homelab/docs/07-backups/03-backup-docker-volumes.md)
- [04-estructura-directorios.md](/Users/x441425/workspace2/homelab/docs/01-sistema/04-estructura-directorios.md)
- [02-estructura-compose.md](/Users/x441425/workspace2/homelab/docs/02-docker/02-estructura-compose.md)
- Documentación oficial de Borgmatic: https://torsion.org/borgmatic/
- Referencia de configuración de Borgmatic: https://torsion.org/borgmatic/reference/configuration/
- Instalación de Borgmatic: https://torsion.org/borgmatic/how-to/install-borgmatic/
- Imagen Docker multi-arquitectura con soporte Docker CLI: https://github.com/modem7/docker-borgmatic
