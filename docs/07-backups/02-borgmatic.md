# Borgmatic

## Descripción
Borgmatic es la pieza encargada de ejecutar las copias de seguridad del homelab usando **BorgBackup** con configuración declarativa en YAML. En esta Raspberry Pi 5 se utiliza para:

- escribir un repositorio local en `hd2t`
- replicar el conjunto crítico a un destino offsite cifrado
- lanzar hooks antes y después de cada backup
- generar dumps lógicos de bases de datos antes del snapshot
- emitir notificaciones de éxito o error

La estrategia global de retención y prioridades se define en `docs/07-backups/01-estrategia-backup.md`. Los procedimientos de restore y export manual se documentan en `docs/07-backups/03-backup-docker-volumes.md`.

## Requisitos Previos
- Haber completado `docs/07-backups/01-estrategia-backup.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Tener accesibles estas rutas:
  - `/home/<usuario>/homelab/`
  - `/mnt/hd2t/backups/borgmatic/local/`
  - `/mnt/hd2t/backups/exports/`
  - `/mnt/hd2t/backups/reports/`
- Tener identificados los nombres reales de los contenedores de MariaDB y PostgreSQL si vas a generar dumps desde hooks.
- Tener creados los secretos locales para passphrase, contraseñas de BD y, si aplica, token de notificaciones.
- Tener preparado el destino offsite si vas a usar `ssh://` u otro backend remoto compatible.
- Poder montar el socket Docker del host dentro del contenedor:
  - `/var/run/docker.sock:/var/run/docker.sock`
- Puertos implicados:
  - no hace falta publicar puertos entrantes para Borgmatic
  - `22/tcp` saliente si el destino offsite usa SSH
  - `443/tcp` saliente si el destino offsite o las notificaciones usan HTTPS
  - conectividad local al Docker Engine mediante socket Unix

## Docker Compose
Despliegue recomendado para `/home/<usuario>/homelab/compose/backups/borgmatic/compose.yaml`:

```yaml
services:
  borgmatic:
    image: ghcr.io/borgmatic-collective/borgmatic:latest
    container_name: borgmatic
    restart: unless-stopped
    environment:
      TZ: Europe/Madrid
      BORG_RSH: ssh -i /root/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new
    volumes:
      - /home/<usuario>/homelab:/srv/homelab:ro
      - /home/<usuario>/homelab/data/backups/borgmatic/borgmatic.d:/etc/borgmatic.d:ro
      - /home/<usuario>/homelab/data/backups/borgmatic/scripts:/usr/local/bin:ro
      - /home/<usuario>/homelab/data/backups/borgmatic/.config/borg:/root/.config/borg
      - /home/<usuario>/homelab/data/backups/borgmatic/.cache/borg:/root/.cache/borg
      - /home/<usuario>/homelab/data/backups/borgmatic/.state/borgmatic:/root/.local/state/borgmatic
      - /home/<usuario>/homelab/data/backups/borgmatic/.ssh:/root/.ssh:ro
      - /mnt/hd2t/backups/borgmatic/local:/mnt/borg-repository-local
      - /mnt/hd2t/backups/exports:/mnt/exports
      - /mnt/hd2t/backups/reports:/mnt/reports
      - /var/run/docker.sock:/var/run/docker.sock
    secrets:
      - borg_passphrase
      - mariadb_root_password
      - postgres_password
      # Elimina esta secret si no usas ntfy.
      - ntfy_access_token

secrets:
  borg_passphrase:
    file: /home/<usuario>/homelab/env/secrets/borg_passphrase.txt
  mariadb_root_password:
    file: /home/<usuario>/homelab/env/secrets/mariadb_root_password.txt
  postgres_password:
    file: /home/<usuario>/homelab/env/secrets/postgres_password.txt
  # Elimina esta secret si no usas ntfy.
  ntfy_access_token:
    file: /home/<usuario>/homelab/env/secrets/ntfy_access_token.txt
```

Notas de este despliegue:

- el contenedor no expone puertos
- el repositorio local vive en `hd2t`, no en el NVMe
- la configuración, claves y estado operativo viven en el NVMe
- el socket Docker solo se monta para poder lanzar dumps desde hooks

## Configuración

### 1. Estructura recomendada en el NVMe

```text
/home/<usuario>/homelab/
├── compose/
│   └── backups/
│       └── borgmatic/
│           └── compose.yaml
├── data/
│   └── backups/
│       └── borgmatic/
│           ├── borgmatic.d/
│           │   ├── common/
│           │   │   └── base.yaml
│           │   ├── local.yaml
│           │   ├── offsite.yaml
│           │   └── crontab.txt
│           ├── scripts/
│           │   ├── pre-backup.sh
│           │   └── post-backup.sh
│           ├── .cache/
│           │   └── borg/
│           ├── .config/
│           │   └── borg/
│           ├── .ssh/
│           └── .state/
│               └── borgmatic/
└── env/
    └── secrets/
        ├── borg_passphrase.txt
        ├── mariadb_root_password.txt
        ├── postgres_password.txt
        └── ntfy_access_token.txt
```

Creación inicial:

```bash
mkdir -p \
  /home/<usuario>/homelab/compose/backups/borgmatic \
  /home/<usuario>/homelab/data/backups/borgmatic/borgmatic.d/common \
  /home/<usuario>/homelab/data/backups/borgmatic/scripts \
  /home/<usuario>/homelab/data/backups/borgmatic/.cache/borg \
  /home/<usuario>/homelab/data/backups/borgmatic/.config/borg \
  /home/<usuario>/homelab/data/backups/borgmatic/.ssh \
  /home/<usuario>/homelab/data/backups/borgmatic/.state/borgmatic \
  /home/<usuario>/homelab/env/secrets

chmod 700 /home/<usuario>/homelab/env/secrets
chmod 700 /home/<usuario>/homelab/data/backups/borgmatic/.ssh
```

Si los ficheros de secretos ya existen, limita permisos:

```bash
chmod 600 /home/<usuario>/homelab/env/secrets/*.txt
```

### 2. Configuración YAML compartida

Usa un fichero base con la lógica común y dos ficheros de entrada, uno para el repositorio local y otro para el offsite. Así puedes aplicar retenciones y horarios distintos sin duplicar toda la configuración.

`/home/<usuario>/homelab/data/backups/borgmatic/borgmatic.d/common/base.yaml`

```yaml
source_directories:
  - /srv/homelab/compose
  - /srv/homelab/env
  - /srv/homelab/scripts
  - /srv/homelab/data
  - /mnt/exports

archive_name_format: homelab-rpi5-{now:%Y-%m-%d-%H%M%S}

compression: zstd,6

encryption_passphrase: "{credential container borg_passphrase}"

one_file_system: false
read_special: false

exclude_patterns:
  - /srv/homelab/data/backups/borgmatic/.cache/borg
  - /srv/homelab/data/backups/borgmatic/.state/borgmatic

checks:
  - name: repository
    frequency: 2 weeks
  - name: archives
    frequency: 1 month

commands:
  - before: action
    when:
      - create
    run:
      - /usr/local/bin/pre-backup.sh

  - after: action
    when:
      - create
    states:
      - finish
    run:
      - /usr/local/bin/post-backup.sh success

  - after: error
    run:
      - /usr/local/bin/post-backup.sh fail

ntfy:
  topic: homelab-backups
  server: https://ntfy.tailnet.example
  access_token: "{credential container ntfy_access_token}"
  states:
    - finish
    - fail
  finish:
    title: Borgmatic OK
    message: El job de backup ha terminado correctamente.
    priority: default
    tags: borgmatic,+1
  fail:
    title: Borgmatic ERROR
    message: Revisa el contenedor borgmatic y los informes en /mnt/hd2t/backups/reports/.
    priority: high
    tags: borgmatic,warning,rotating_light
```

Notas:

- `archive_name_format` evita depender del hostname del contenedor
- `exclude_patterns` evita respaldar caché y estado efímero del propio job
- el bloque `ntfy:` es opcional; si no lo usas, elimínalo junto con la secret correspondiente

### 3. Configuración del repositorio local

`/home/<usuario>/homelab/data/backups/borgmatic/borgmatic.d/local.yaml`

```yaml
repositories:
  - path: /mnt/borg-repository-local
    label: local-hd2t

keep_daily: 14
keep_weekly: 8
keep_monthly: 12

<<: !include /etc/borgmatic.d/common/base.yaml
```

Este es el job que escribe la copia local del NVMe hacia `hd2t`.

### 4. Configuración del repositorio offsite

`/home/<usuario>/homelab/data/backups/borgmatic/borgmatic.d/offsite.yaml`

```yaml
repositories:
  - path: ssh://borg@backup.example.net/./homelab-rpi5
    label: offsite

keep_daily: 7
keep_weekly: 4
keep_monthly: 6

<<: !include /etc/borgmatic.d/common/base.yaml
```

Sustituye `ssh://borg@backup.example.net/./homelab-rpi5` por tu ruta real. Si usas otro backend remoto compatible, adapta solo `path:` y mantén el resto de la política.

### 5. Hooks pre y post backup

Los dumps se generan antes de `create` y se guardan en `hd2t` bajo `exports/`. Así dispones de artefactos SQL rápidos de restaurar y, además, esos mismos dumps quedan incluidos en el backup versionado.

`/home/<usuario>/homelab/data/backups/borgmatic/scripts/pre-backup.sh`

```bash
#!/bin/sh
set -eu

timestamp="$(date +%F-%H%M%S)"

mkdir -p /mnt/exports/mariadb /mnt/exports/postgresql /mnt/reports

if docker container inspect mariadb >/dev/null 2>&1; then
  docker exec \
    -e MARIADB_PWD="$(cat /run/secrets/mariadb_root_password)" \
    mariadb \
    mariadb-dump \
      --all-databases \
      --single-transaction \
      --quick \
      --lock-tables=false \
      --routines \
      --events \
      -uroot \
    | gzip -9 > "/mnt/exports/mariadb/all-${timestamp}.sql.gz"
fi

if docker container inspect postgres >/dev/null 2>&1; then
  docker exec \
    -e PGPASSWORD="$(cat /run/secrets/postgres_password)" \
    postgres \
    pg_dumpall -U postgres \
    | gzip -9 > "/mnt/exports/postgresql/all-${timestamp}.sql.gz"
fi

{
  echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] dumps generados"
  find /mnt/exports -maxdepth 2 -type f | sort
} >> /mnt/reports/borgmatic-pre-backup.log
```

`/home/<usuario>/homelab/data/backups/borgmatic/scripts/post-backup.sh`

```bash
#!/bin/sh
set -eu

status="${1:-unknown}"

{
  echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] estado=${status}"
} >> /mnt/reports/borgmatic-post-backup.log

find /mnt/exports/mariadb -type f -mtime +14 -delete || true
find /mnt/exports/postgresql -type f -mtime +14 -delete || true
```

Permisos:

```bash
chmod 750 /home/<usuario>/homelab/data/backups/borgmatic/scripts/*.sh
```

Ajusta `mariadb` y `postgres` a los nombres reales de tus contenedores. Si usas otros motores, amplía `pre-backup.sh` con más bloques de exportación.

### 6. Programación

La forma más simple de mantener el horario dentro del contenedor es definir un `crontab.txt` junto a los YAML. El contenedor ejecuta los jobs y deja los informes en `hd2t`.

`/home/<usuario>/homelab/data/backups/borgmatic/borgmatic.d/crontab.txt`

```cron
15 2 * * * PATH=$PATH:/usr/local/bin borgmatic --config /etc/borgmatic.d/local.yaml create --stats --list >> /mnt/reports/borgmatic-local.log 2>&1
0 3 * * * PATH=$PATH:/usr/local/bin borgmatic --config /etc/borgmatic.d/offsite.yaml create --stats >> /mnt/reports/borgmatic-offsite.log 2>&1
0 4 * * 0 PATH=$PATH:/usr/local/bin borgmatic --config /etc/borgmatic.d/local.yaml prune compact --stats >> /mnt/reports/borgmatic-local.log 2>&1
30 4 * * 0 PATH=$PATH:/usr/local/bin borgmatic --config /etc/borgmatic.d/offsite.yaml prune compact --stats >> /mnt/reports/borgmatic-offsite.log 2>&1
0 5 * * 0 [ "$(date +\%d)" -le 7 ] && PATH=$PATH:/usr/local/bin borgmatic --config /etc/borgmatic.d/local.yaml check --force >> /mnt/reports/borgmatic-check.log 2>&1
30 5 * * 0 [ "$(date +\%d)" -le 7 ] && PATH=$PATH:/usr/local/bin borgmatic --config /etc/borgmatic.d/offsite.yaml check --force >> /mnt/reports/borgmatic-check.log 2>&1
```

Esta programación implementa la política definida en `docs/07-backups/01-estrategia-backup.md`:

- `02:15`: dumps y backup local
- `03:00`: réplica offsite
- domingo `04:00`: prune y compactación
- primer domingo del mes `05:00`: verificación

### 7. Inicialización y primera ejecución

Levanta el stack:

```bash
cd /home/<usuario>/homelab/compose/backups/borgmatic
docker compose up -d
```

Valida la configuración local:

```bash
docker compose exec borgmatic \
  borgmatic --config /etc/borgmatic.d/local.yaml config validate
```

Crea el repositorio local:

```bash
docker compose exec borgmatic \
  borgmatic --config /etc/borgmatic.d/local.yaml repo-create --encryption repokey-chacha20-poly1305
```

Si vas a usar copia offsite, crea también el repositorio remoto:

```bash
docker compose exec borgmatic \
  borgmatic --config /etc/borgmatic.d/offsite.yaml repo-create --encryption repokey-chacha20-poly1305
```

Lanza un primer backup manual del repositorio local:

```bash
docker compose exec borgmatic \
  borgmatic --config /etc/borgmatic.d/local.yaml create --stats --list
```

Verificaciones mínimas después de la primera ejecución:

1. Existe al menos un dump en `/mnt/hd2t/backups/exports/mariadb/` o `/mnt/hd2t/backups/exports/postgresql/`.
2. `docker compose logs borgmatic` no muestra errores de hooks.
3. `docker compose exec borgmatic borgmatic --config /etc/borgmatic.d/local.yaml list --short` devuelve al menos un archive.
4. Se ha generado actividad en `/mnt/hd2t/backups/reports/`.
5. Si configuraste notificaciones, ha llegado un aviso de éxito o fallo.

### 8. Ajustes operativos recomendados

- Mantén `base.yaml`, `local.yaml`, `offsite.yaml` y los scripts bajo control de cambios junto al resto del homelab.
- Haz copia adicional del directorio `/home/<usuario>/homelab/data/backups/borgmatic/.config/borg/`, porque puede contener material necesario para operar con el repositorio.
- Si el job offsite tarda demasiado, crea una variante más restrictiva que incluya solo el conjunto irremplazable.
- Si más adelante excluyes datos grandes o regenerables, actualiza la lista en `common/base.yaml` para que local y offsite sigan la misma lógica.

## Almacenamiento

| Elemento | Ruta | Disco |
|---|---|---|
| Stack Compose de Borgmatic | `/home/<usuario>/homelab/compose/backups/borgmatic/` | SSD NVMe |
| Configuración YAML | `/home/<usuario>/homelab/data/backups/borgmatic/borgmatic.d/` | SSD NVMe |
| Scripts de hooks | `/home/<usuario>/homelab/data/backups/borgmatic/scripts/` | SSD NVMe |
| Caché y estado local | `/home/<usuario>/homelab/data/backups/borgmatic/.cache/` y `.state/` | SSD NVMe |
| Claves y configuración Borg/SSH | `/home/<usuario>/homelab/data/backups/borgmatic/.config/borg/` y `.ssh/` | SSD NVMe |
| Repositorio local Borg | `/mnt/hd2t/backups/borgmatic/local/` | `hd2t` |
| Exportaciones de BD | `/mnt/hd2t/backups/exports/` | `hd2t` |
| Informes y logs de backup | `/mnt/hd2t/backups/reports/` | `hd2t` |
| Repositorio offsite | `ssh://...` o backend remoto compatible | fuera del homelab |

## Backup

Qué respalda Borgmatic en este despliegue:

- `compose/`, `env/`, `scripts/` y `data/` del homelab en el NVMe
- dumps lógicos de MariaDB y PostgreSQL generados justo antes del snapshot
- configuración y material operativo de Borg necesarios para listar, verificar y restaurar
- una copia local versionada en `hd2t`
- una réplica cifrada al destino offsite si `offsite.yaml` está habilitado

Qué no conviene incluir aquí salvo necesidad explícita:

- bibliotecas grandes ya almacenadas en `hd2t`
- contenido de `hd5t` salvo estrategia adicional dedicada
- cachés recreables, transcodes, miniaturas regenerables y descargas temporales

Checklist operativo de este documento:

1. El contenedor `borgmatic` arranca sin publicar puertos.
2. El repositorio local escribe en `/mnt/hd2t/backups/borgmatic/local/`.
3. `pre-backup.sh` genera dumps antes de cada `create`.
4. `post-backup.sh` registra el resultado y limpia exports antiguos.
5. `crontab.txt` separa local, offsite, prune y checks.
6. La passphrase y las credenciales viven fuera del `compose.yaml`.
7. Hay notificación configurada o, como mínimo, revisión manual de informes.

## Referencias
- Borgmatic: overview  
  https://torsion.org/borgmatic/
- Borgmatic documentation: Docker image  
  https://torsion.org/borgmatic/docs/how-to/set-up-backups/#docker
- Borgmatic documentation: configuration reference  
  https://torsion.org/borgmatic/reference/configuration/
- Borgmatic documentation: repositories  
  https://torsion.org/borgmatic/reference/configuration/repositories/
- Borgmatic documentation: command hooks  
  https://torsion.org/borgmatic/reference/configuration/command-hooks/
- Borgmatic documentation: consistency checks  
  https://torsion.org/borgmatic/reference/configuration/consistency-checks/
- Borgmatic documentation: monitoring with ntfy  
  https://torsion.org/borgmatic/reference/configuration/monitoring/ntfy/
- Borgmatic documentation: backup your databases  
  https://torsion.org/borgmatic/how-to/backup-your-databases/
- Borgmatic documentation: make backups redundant  
  https://torsion.org/borgmatic/how-to/make-backups-redundant/
- Official Docker image for Borgmatic  
  https://github.com/borgmatic-collective/docker-borgmatic
