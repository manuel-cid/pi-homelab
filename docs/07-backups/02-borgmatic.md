# Borgmatic

## Descripción

`01-estrategia-backup.md` cerró las **decisiones**: regla 3-2-1 con repo Borg local en `/mnt/hd2t/backups/borg/` y bucket S3-compatible offsite, retención GFS (7/4/12/2), cifrado `repokey-blake2`, dumps lógicos previos para Postgres/MariaDB/SQLite, ventana 03:30–04:30 y métricas a Prometheus. Este documento las **materializa**: despliega un stack Docker `borgmatic` que orquesta toda esa cadena de forma reproducible y observable.

La pieza central es el contenedor **`ghcr.io/borgmatic-collective/borgmatic`**, que empaqueta Borg + Borgmatic + cron + utilidades de cliente (`postgresql-client`, `mariadb-client`, `sqlite`, `mc`, `rclone`) sobre Alpine. Tiene cron interno: arranca el daemon, ejecuta `borgmatic` en la cadencia definida por `BACKUP_CRON`, y reescribe los logs vía `stdout`/`stderr` para que Dozzle (Fase 5) los muestre como cualquier otro servicio. No hay timers en `systemd` del host: la lógica de "cuándo" vive **dentro** del contenedor, junto con la lógica de "qué" y "cómo".

El despliegue tiene cinco capas que este documento cubre:

1. **Stack Docker** (`stacks/borgmatic/docker-compose.yml`). Bind mounts a `/mnt/hd2t/backups/borg/` (repo), `/mnt/hd2t/backups/dumps/` (área temporal de dumps), `/mnt/hd2t/apps/` (origen de los datos, *read-only*), `/home/homelab/homelab/secrets/` (passphrase, claves rclone, `.env` de stacks) y `/home/homelab/homelab/stacks/` (composes y plantillas). El contenedor corre como `homelab:homelab` (PUID/PGID en el `.env` global) para no enredar permisos en `hd2t`.
2. **Configuración Borgmatic** (`stacks/borgmatic/config/borgmatic.yaml`). Un único fichero declarativo con `source_directories`, `repositories`, `exclude_patterns`, hooks `before_backup` (dumps), `after_backup` (limpieza, `rclone sync`, notificaciones, métricas), `retention` con los `keep_*` GFS, `consistency` con la cadencia de `check`, e integración con `monitoring_hooks` (Apprise + Uptime Kuma).
3. **Hooks de bases de datos**. Borgmatic 1.8+ trae hooks nativos `postgresql_databases`, `mariadb_databases`, `sqlite_databases` que ya son **dump consistente → comprimir → entregar a Borg como stream**, sin tocar el filesystem si no se quiere. Para los servicios que no encajan en esos hooks (Pi-hole `pihole-FTL.db` por permisos, MinIO via `mc mirror`) se usa la tubería estándar `before_backup` → comando custom → fichero en `dumps/` → Borg lo absorbe → `after_backup` lo limpia.
4. **Offsite via `rclone`**. Tras un `borgmatic create + prune + check` exitoso, un hook `after_backup` ejecuta `rclone sync /mnt/hd2t/backups/borg/ b2crypt:homelab/borg/ --bwlimit 5M:off --backup-dir snapshots/$(date +%F)/`. Si el stack falla en cualquier paso, el offsite **no** se toca: la regla es "primero local consistente, luego offsite".
5. **Observabilidad**. Cada ejecución escribe un fichero `homelab_backup.prom` en `/var/lib/node_exporter/textfile/` (el textfile collector de Fase 5). Cuando algo falla, Apprise dispara Telegram; cuando todo va bien, un push a un monitor passive de Uptime Kuma confirma el heartbeat. La ausencia de heartbeat 36 h dispara la alerta crítica.

> **Re-abrible**: Borgmatic ofrece también modo "directo a SSH/SFTP" sin `rclone`. Se descarta hoy porque B2/R2 no ofrecen SSH y la opción `borg + rclone serve restic` añade un proceso `rclone serve` perpetuo. Si el operador migra a un proveedor con soporte SSH/Borg nativo (Hetzner Storage Box, BorgBase, rsync.net), el cambio se localiza en `repositories:` y desaparece el hook `rclone sync` — el stack sobrevive sin reescritura.

> **Re-abrible**: ejecutar Borgmatic via systemd timer en el host (sin Docker) es viable y técnicamente más limpio (menos capas). Se descarta porque rompe el principio del homelab: "todo lo que se pueda como servicio Docker, va como servicio Docker". El operador encuentra Borgmatic en `docker ps`, en Portainer, en Dozzle, sin saber que es "especial".

---

## Requisitos Previos

- **`07-backups/01-estrategia-backup.md`** aplicado: decisiones GFS, RPO/RTO, tiers T1–T4 acordadas; passphrase Borg generada y custodiada fuera de banda.
- **Fase 0–1 completas**: `04-estructura-directorios.md` ya creó:
  - `/mnt/hd2t/backups/borg/` (`0700 homelab:homelab`) — repo local, vacío.
  - `/mnt/hd2t/backups/dumps/` (`0700 homelab:homelab`) — área de dumps efímeros.
  - `/mnt/hd2t/backups/exports/` (`0750`) — restore drills.
  - `/home/homelab/homelab/secrets/` (`0700`) — listo para `borg.passphrase`, `rclone.conf`, `rclone-crypt.passphrase`.
- **Fase 2 completa**: red Docker `homelab` (`external: true`), `.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `LAN_IP`. Plantilla `stacks/_template/` y convenciones `homelab.backup=true|false` ya aplicadas a los stacks desplegados hasta Fase 6.
- **Fase 5**: Prometheus + `node_exporter` con textfile collector activo en `/var/lib/node_exporter/textfile/` (`0775`, propietario `nodeexp:nodeexp`, grupo writeable por `homelab`). Apprise desplegado y endpoint local `http://apprise:8000/notify/homelab` operativo. Uptime Kuma con un *push monitor* "Borgmatic Daily" creado y su URL anotada.
- **Fase 6**: si MinIO está en uso, las credenciales `mc` con permiso de lectura sobre los buckets T1/T2 viven en `secrets/mcadmin.json`.
- **Cuenta offsite**: bucket B2 `homelab-borg` creado, App Key con scope al bucket, `rclone config` ejecutado **una vez** en el host generando `secrets/rclone.conf` con dos remotes: `b2:` (raw B2) y `b2crypt:` (overlay `crypt` apuntando a `b2:homelab-borg/borg/`).
- **Secretos en `secrets/`** preparados con permisos `0600 homelab:homelab`:
  - `secrets/borg.passphrase` — passphrase Borg ≥ 32 chars.
  - `secrets/rclone-crypt.passphrase` — passphrase rclone-crypt distinta.
  - `secrets/rclone.conf` — perfiles `b2` y `b2crypt`.
  - `secrets/db/nextcloud-db.env` (existente desde Fase 6) — credenciales Postgres reutilizables.
  - *(opcional)* `secrets/notifications/apprise-borgmatic.url` — URL Apprise canalizada solo a Telegram del operador.
  - *(opcional)* `secrets/notifications/uptime-kuma-push.url` — URL push monitor de Uptime Kuma.

---

## Docker Compose

`stacks/borgmatic/docker-compose.yml`:

```yaml
name: borgmatic

services:
  borgmatic:
    image: ghcr.io/borgmatic-collective/borgmatic:1.9-alpine
    container_name: borgmatic
    hostname: borgmatic
    restart: unless-stopped
    user: "${PUID}:${PGID}"

    environment:
      TZ: ${TZ}
      PUID: ${PUID}
      PGID: ${PGID}

      # Cron interno del contenedor: 03:45 todas las noches.
      # Pre-dumps los maneja Borgmatic vía hooks dentro del propio run.
      BACKUP_CRON: "45 3 * * *"

      # Borg/Borgmatic: passphrase y rutas estandarizadas.
      BORG_PASSPHRASE_FILE: /run/secrets/borg.passphrase
      BORG_BASE_DIR: /root/.borg
      BORG_RSH: "ssh -o StrictHostKeyChecking=accept-new"

      # rclone: ruta al config en lugar de copiarlo a $HOME.
      RCLONE_CONFIG: /run/secrets/rclone.conf
      RCLONE_PASSWORD_COMMAND: "cat /run/secrets/rclone-crypt.passphrase"

      # Verbosidad: 1 = info, 2 = debug. En arranque dejar 2 unos días.
      BORGMATIC_VERBOSITY: "1"

    env_file:
      - ./.env

    networks:
      - homelab

    volumes:
      # ── Repo Borg (RW: el contenedor escribe nuevos archives) ─────
      - /mnt/hd2t/backups/borg:/mnt/borg-repo

      # ── Área de dumps efímeros (RW) ──────────────────────────────
      - /mnt/hd2t/backups/dumps:/mnt/dumps

      # ── Datos a respaldar (RO: borgmatic NO debe poder escribir) ─
      - /mnt/hd2t/apps:/source/apps:ro
      - /home/homelab/homelab/stacks:/source/stacks:ro
      - /home/homelab/homelab/secrets:/source/secrets:ro
      - /home/homelab/homelab/.env:/source/env-global:ro
      - /home/homelab/homelab/BACKUPS_LOG.md:/source/BACKUPS_LOG.md:ro

      # ── Configuración Borgmatic ──────────────────────────────────
      - ./config/borgmatic.yaml:/etc/borgmatic.d/borgmatic.yaml:ro
      - ./config/hooks:/etc/borgmatic.d/hooks:ro

      # ── Secretos (montados como ficheros, nunca como dir entero) ─
      - /home/homelab/homelab/secrets/borg.passphrase:/run/secrets/borg.passphrase:ro
      - /home/homelab/homelab/secrets/rclone.conf:/run/secrets/rclone.conf:ro
      - /home/homelab/homelab/secrets/rclone-crypt.passphrase:/run/secrets/rclone-crypt.passphrase:ro
      - /home/homelab/homelab/secrets/notifications:/run/secrets/notifications:ro

      # ── Prometheus textfile collector (RW para escribir métricas) ─
      - /var/lib/node_exporter/textfile:/var/lib/node_exporter/textfile

    # Borgmatic NO publica puertos: solo cliente saliente.
    # Tampoco necesita la network `homelab` para nada salvo resolver
    # `apprise` y `uptime-kuma` por DNS interno (notificaciones).

    healthcheck:
      # El contenedor se considera sano si crond está vivo Y
      # existe un archive en las últimas 36 h (lo escribe el hook
      # post-backup en /mnt/borg-repo/.last-success).
      test:
        - CMD-SHELL
        - >
          pidof crond >/dev/null &&
          test "$(($(date +%s) - $(stat -c %Y /mnt/borg-repo/.last-success 2>/dev/null || echo 0)))" -lt 129600
      interval: 5m
      timeout: 10s
      retries: 3
      start_period: 24h     # tras crear el stack, da 24h al primer run

    labels:
      homelab.role: "backup"
      homelab.backup: "false"          # Borgmatic NO se respalda a sí mismo
      com.centurylinklabs.watchtower.enable: "true"

networks:
  homelab:
    external: true
```

`stacks/borgmatic/.env.example`:

```bash
# Variables específicas de Borgmatic.
# Copiar a .env y rellenar; .env no se versiona.

# Hostname con el que aparecerá la máquina en los archives Borg.
# Útil si en el futuro hay más nodos respaldando al mismo repo offsite.
BORG_HOSTNAME=pi5-homelab

# Si en algún momento se quiere desactivar el sync offsite sin tocar
# el yaml de borgmatic (por ejemplo, durante una migración):
HOMELAB_OFFSITE_ENABLED=true
```

`stacks/borgmatic/.env` se genera copiando el `.example` y nunca se commitea (la gitignore global lo cubre).

### Por qué este compose, decisión a decisión

| Decisión | Valor | Razón |
|---|---|---|
| Imagen | `ghcr.io/borgmatic-collective/borgmatic:1.9-alpine` | Mantenida por la comunidad oficial (`borgmatic-collective`), trae Borg + Borgmatic + clientes SQL + `mc` + `rclone` listos. Tag `1.9-alpine` ancla la minor; Watchtower trae los parches. `:latest` está prohibido por convención. |
| `user: "${PUID}:${PGID}"` | UID/GID `homelab` | Los archives entrantes y los dumps se escriben con el mismo owner que el resto de `/mnt/hd2t/`. Evita que `restore` produzca ficheros propiedad de `root`. |
| `BACKUP_CRON: "45 3 * * *"` | 03:45 | La estrategia fija 03:30 para pre-hooks; aquí Borgmatic dispara a 03:45 y son **los hooks de Borgmatic** los que ejecutan los dumps. No hay un cron separado a las 03:30 para evitar dos relojes coordinados a mano. |
| `BORG_PASSPHRASE_FILE` | `/run/secrets/borg.passphrase` | Borg 1.4 acepta `BORG_PASSPHRASE_FILE`; mejor que `BORG_PASSPHRASE` en variable de entorno (no aparece en `docker inspect`). |
| `BORG_BASE_DIR` | `/root/.borg` | Por defecto Borg escribe `~/.config/borg/` y `~/.cache/borg/`. Centralizarlos en un solo path simplifica el debug. |
| `RCLONE_CONFIG` y `RCLONE_PASSWORD_COMMAND` | apuntando a `/run/secrets/...` | rclone soporta password obfuscation, pero `crypt` exige passphrase en claro. Pasar por `command` evita escribirla en el `rclone.conf`. |
| `BORGMATIC_VERBOSITY: "1"` | `info` | Nivel `2` (debug) genera ~MB de log por noche. `1` da suficiente trazabilidad y Dozzle lo muestra ágilmente. |
| Bind mount `/mnt/hd2t/apps:/source/apps:ro` | **read-only** | Defensa en profundidad: si Borgmatic tuviera un bug que hiciera `rm`, no podría tocar los datos primarios. Solo `mnt/borg-repo` y `mnt/dumps` son RW. |
| Bind mount `/home/homelab/homelab/stacks:/source/stacks:ro` | RO | Permite respaldar los `.env` por stack y los composes que **no** están versionados (ya están en git, pero el `.env` sí lo necesita el operador para reconstruir). |
| Bind mount `secrets/notifications:/run/secrets/notifications:ro` | RO | Las URLs de Apprise/Kuma viven aquí, separadas de las passphrase de cifrado para que un leak de notificaciones no comprometa cifrado. |
| Bind mount textfile collector | RW | El hook `after_backup` escribe `homelab_backup.prom` que `node_exporter` reservará. |
| Sin `ports:` | — | Borgmatic es solo cliente saliente. No expone UI; los logs se ven por Dozzle, las métricas por Prometheus, las notificaciones por Telegram. |
| Healthcheck doble (cron + last-success) | — | Detecta dos fallos típicos: crond muerto (contenedor vivo pero zombi) y "borgmatic se ejecuta pero falla siempre" (el archive no se escribe). 36 h de margen permite tolerar un fallo ocasional sin spam de alertas. |
| `homelab.backup: "false"` | — | Meta-decisión: el propio Borgmatic **no** se respalda a sí mismo. Su `borgmatic.yaml` está versionado en git; sus secretos viven en `secrets/` que sí entra en otro hook (cubierto más abajo). |
| `com.centurylinklabs.watchtower.enable: "true"` | — | El doc de Watchtower (Fase 2.4) y la estrategia de Fase 7 lo confirman: Borgmatic recibe parches automáticos dentro de su minor. Una versión rota se detecta en pocas noches por el healthcheck. |

---

## Configuración

### `config/borgmatic.yaml`

`stacks/borgmatic/config/borgmatic.yaml` es el corazón declarativo del stack. Se versiona en git **íntegramente**: no contiene secretos, todo lo sensible viaja por `BORG_PASSPHRASE_FILE` y por el montaje `secrets/`.

```yaml
# ============================================================
#  Borgmatic – homelab Pi5
#  Documentación: docs/07-backups/02-borgmatic.md
# ============================================================

# ───── Qué se respalda ─────
source_directories:
  - /source/apps
  - /source/stacks
  - /source/secrets
  - /source/env-global
  - /source/BACKUPS_LOG.md
  - /mnt/dumps                 # dumps producidos por los hooks SQL/MinIO

# ───── Qué se excluye ─────
exclude_patterns:
  # T4 – voluminoso o efímero
  - '/source/apps/*/cache'
  - '/source/apps/*/redis'
  - '/source/apps/*/dump.rdb'
  - '/source/apps/*/appendonly.aof'
  - '/source/apps/prometheus/data'
  - '/source/apps/jellyfin/cache'
  - '/source/apps/jellyfin/transcodes'

  # Datos primarios de Postgres / MariaDB: NO se respalda pgdata,
  # se respalda el dump generado por los hooks (más abajo).
  - '/source/apps/*/pgdata'
  - '/source/apps/*/postgres-data'
  - '/source/apps/*/mariadb-data'
  - '/source/apps/*/mysql-data'

  # Secretos que NO viajan offsite (decisión por servicio si aplica)
  # - '/source/secrets/no-offsite/'

  # Archivos sin valor de restauración
  - '**/*.log'
  - '**/*.tmp'
  - '**/lost+found'

exclude_caches: true              # respeta CACHEDIR.TAG (Borg estándar)
exclude_if_present:
  - .nobackup                     # un fichero `.nobackup` excluye su carpeta
exclude_from:
  - /etc/borgmatic.d/hooks/exclude-extra.txt

# ───── Dónde se respalda ─────
repositories:
  - path: /mnt/borg-repo
    label: pi5-local

# ───── Cifrado / compresión ─────
encryption_passcommand: "cat /run/secrets/borg.passphrase"
compression: zstd,3
chunker_params: "buzhash,19,23,21,4095"
files_cache: ctime,size

# ───── Retención GFS ─────
keep_daily: 7
keep_weekly: 4
keep_monthly: 12
keep_yearly: 2
prefix: "{hostname}-"             # archives se llaman pi5-homelab-2026-04-28T03-45

# ───── Verificación ─────
checks:
  - name: repository
    frequency: 1 week
  - name: archives
    frequency: 1 month
  - name: extract
    frequency: 1 month            # extract en dry-run de un archive aleatorio

# ───── Hooks de bases de datos ─────
postgresql_databases:
  - name: nextcloud
    hostname: nextcloud-db
    port: 5432
    username: nextcloud
    password: "${POSTGRES_NEXTCLOUD_PASSWORD}"
    format: custom
    pg_dump_command: pg_dump
    pg_restore_command: pg_restore
    psql_command: psql
    options: "--compress=9 --no-owner --no-privileges"

# (Plantilla para futuros servicios — descomentar al desplegar)
# mariadb_databases:
#   - name: bookstack
#     hostname: bookstack-db
#     port: 3306
#     username: bookstack
#     password: "${MARIADB_BOOKSTACK_PASSWORD}"
#     format: sql
#     options: "--single-transaction --routines --triggers --events"

sqlite_databases:
  - name: authelia
    path: /source/apps/authelia/data/db.sqlite3
  - name: uptime-kuma
    path: /source/apps/uptime-kuma/data/kuma.db
  - name: pihole
    path: /source/apps/pihole/etc/pihole-FTL.db
  # Servicios futuros (descomentar al desplegar):
  # - name: linkding
  #   path: /source/apps/linkding/data/db.sqlite3
  # - name: freshrss
  #   path: /source/apps/freshrss/data/users/_/db.sqlite
  # - name: mealie
  #   path: /source/apps/mealie/data/mealie.db
  # - name: calibre-web
  #   path: /source/apps/calibre-web/config/app.db
  # - name: stash
  #   path: /source/apps/stash/data/stash-go.sqlite

# ───── Hooks de comandos arbitrarios ─────
before_backup:
  - echo "[$(date -Is)] borgmatic start" >&2
  - /etc/borgmatic.d/hooks/before-backup.sh

after_backup:
  - /etc/borgmatic.d/hooks/after-backup.sh
  - echo "[$(date -Is)] borgmatic post-create OK" >&2

after_prune:
  - /etc/borgmatic.d/hooks/after-prune.sh

on_error:
  - /etc/borgmatic.d/hooks/on-error.sh

# ───── Notificaciones ─────
ntfy:
  topic: ""                        # no usado; se usa Apprise + Kuma vía hooks

# Hook integrado de healthchecks-style: ping a Uptime Kuma push monitor.
healthchecks:
  ping_url: "${UPTIMEKUMA_PUSH_URL}"
  states:
    - start
    - finish
    - fail
  verify_tls: false                # Kuma local sin TLS válido (Caddy interno)
```

### Variables de interpolación

Borgmatic 1.8+ resuelve `${VAR}` desde el entorno del proceso. Sus valores los aporta `stacks/borgmatic/.env` (no versionado), que el contenedor carga vía `env_file`:

```bash
# stacks/borgmatic/.env  (NO commitear)
POSTGRES_NEXTCLOUD_PASSWORD=...                    # mismo valor que secrets/db/nextcloud-db.env
UPTIMEKUMA_PUSH_URL=http://uptime-kuma:3001/api/push/abc123def456
APPRISE_NOTIFY_URL=http://apprise:8000/notify/borgmatic
```

> **Por qué duplicar `POSTGRES_NEXTCLOUD_PASSWORD` aquí**: Borgmatic interpola variables de entorno, no ficheros. Mantener una segunda copia es un coste real; el alternativo (un script wrapper que lee `secrets/db/nextcloud-db.env` y exporta antes de invocar `borgmatic`) añade una capa más. Se acepta la duplicación con disciplina: cuando se rote la password de Nextcloud-DB, ambos `.env` se actualizan en la misma operación. Reabrible: si crece el número de passwords duplicadas, un hook `before_backup` puede sourcear `/run/secrets/db/*.env` antes de que Borgmatic interprete su YAML.

### Hooks de comandos: `config/hooks/`

Cuatro scripts cortos, todos con `set -euo pipefail` y trazas a `stderr`. Bind-montados read-only.

#### `config/hooks/before-backup.sh`

Cubre lo que los hooks SQL nativos no abarcan: dumps de **MinIO** y *mantenimiento puntual* de `pihole-FTL.db` (que tiene un FK que `.backup` resuelve solo si se invoca con `--cmd "PRAGMA wal_checkpoint(TRUNCATE);"` antes; el hook nativo de Borgmatic ya lo hace internamente, así que aquí solo va MinIO).

```bash
#!/usr/bin/env bash
# /etc/borgmatic.d/hooks/before-backup.sh
set -euo pipefail

DUMPS=/mnt/dumps
mkdir -p "$DUMPS/minio"

# Buckets críticos T1/T2 — opt-in lista explícita.
# La política T3 ("buckets MinIO solo si el operador opta-in") se
# materializa aquí: añadir/quitar líneas reescribe la cobertura.
BUCKETS=(
  # "app-snapshots"
  # "documentos-paperless"
)

if [ ${#BUCKETS[@]} -gt 0 ]; then
  for b in "${BUCKETS[@]}"; do
    echo "[before-backup] mc mirror minio/$b → $DUMPS/minio/$b"
    mc --config-dir /run/secrets mirror --quiet --overwrite --remove \
      "minio/$b" "$DUMPS/minio/$b"
  done
fi
```

#### `config/hooks/after-backup.sh`

Limpieza de dumps, sync offsite, métrica de éxito, marca de healthcheck.

```bash
#!/usr/bin/env bash
# /etc/borgmatic.d/hooks/after-backup.sh
set -euo pipefail

DUMPS=/mnt/dumps
TEXTFILE=/var/lib/node_exporter/textfile/homelab_backup.prom
TEXTFILE_TMP="${TEXTFILE}.tmp"
REPO=/mnt/borg-repo

# 1. Limpieza: los hooks SQL nativos limpian sus dumps; aquí limpiamos
#    solo lo que produjo before-backup.sh (MinIO).
rm -rf "$DUMPS/minio" 2>/dev/null || true

# 2. Marca de last-success para el healthcheck del compose.
touch "$REPO/.last-success"

# 3. Sync offsite (gobernado por HOMELAB_OFFSITE_ENABLED).
if [ "${HOMELAB_OFFSITE_ENABLED:-true}" = "true" ]; then
  echo "[after-backup] rclone sync hacia offsite"
  rclone --config /run/secrets/rclone.conf sync \
    "$REPO/" "b2crypt:homelab/borg/" \
    --bwlimit 5M:off \
    --backup-dir "snapshots/$(date +%F)/" \
    --transfers 4 \
    --checkers 8 \
    --fast-list \
    --log-level NOTICE
  OFFSITE_TS=$(date +%s)
else
  OFFSITE_TS=0
fi

# 4. Métricas Prometheus (textfile collector).
ARCHIVES=$(borg list --short "$REPO" | wc -l)
SIZE=$(borg info --json "$REPO" | sed -n 's/.*"deduplicated_size":\s*\([0-9]*\).*/\1/p' | head -1)
NOW=$(date +%s)

cat > "$TEXTFILE_TMP" <<EOF
# HELP homelab_backup_last_success_timestamp Unix ts del último backup exitoso.
# TYPE homelab_backup_last_success_timestamp gauge
homelab_backup_last_success_timestamp ${NOW}
# HELP homelab_backup_archives_total Número total de archives en el repo.
# TYPE homelab_backup_archives_total gauge
homelab_backup_archives_total ${ARCHIVES}
# HELP homelab_backup_dedup_size_bytes Tamaño deduplicado del repo en bytes.
# TYPE homelab_backup_dedup_size_bytes gauge
homelab_backup_dedup_size_bytes ${SIZE:-0}
# HELP homelab_backup_offsite_last_success_timestamp Unix ts del último sync offsite.
# TYPE homelab_backup_offsite_last_success_timestamp gauge
homelab_backup_offsite_last_success_timestamp ${OFFSITE_TS}
EOF
mv "$TEXTFILE_TMP" "$TEXTFILE"

echo "[after-backup] OK archives=$ARCHIVES size=$SIZE offsite_ts=$OFFSITE_TS"
```

#### `config/hooks/after-prune.sh`

`borg compact` para liberar espacio en `hd2t` tras la poda GFS de la noche.

```bash
#!/usr/bin/env bash
# /etc/borgmatic.d/hooks/after-prune.sh
set -euo pipefail

# Compact solo los lunes para no penalizar el resto de noches.
if [ "$(date +%u)" = "1" ]; then
  echo "[after-prune] borg compact (lunes)"
  borg compact /mnt/borg-repo
fi
```

#### `config/hooks/on-error.sh`

Notificación por Apprise → Telegram con contexto mínimo. No toca el repo, no toca los dumps (los dejamos para diagnóstico hasta el siguiente run).

```bash
#!/usr/bin/env bash
# /etc/borgmatic.d/hooks/on-error.sh
set -euo pipefail

URL=$(cat /run/secrets/notifications/apprise-borgmatic.url 2>/dev/null || echo "")
if [ -z "$URL" ]; then
  echo "[on-error] sin URL de Apprise; nada que notificar"
  exit 0
fi

HOST=${BORG_HOSTNAME:-pi5-homelab}
MSG="🚨 Borgmatic FAIL en ${HOST} a las $(date -Is). Revisar Dozzle: docker logs borgmatic"

# Apprise local; el endpoint resuelve internamente a Telegram, ntfy, etc.
curl -fsSL -X POST -d "body=${MSG}" "${URL}" \
  || echo "[on-error] no se pudo notificar: ${URL}"
```

### Despliegue inicial

```bash
cd /home/homelab/homelab

# 1. Estructura
mkdir -p stacks/borgmatic/config/hooks

# 2. Materializar el compose, el yaml y los hooks
#    (copy-paste desde este documento o desde un repo template)
$EDITOR stacks/borgmatic/docker-compose.yml
$EDITOR stacks/borgmatic/config/borgmatic.yaml
$EDITOR stacks/borgmatic/config/hooks/before-backup.sh
$EDITOR stacks/borgmatic/config/hooks/after-backup.sh
$EDITOR stacks/borgmatic/config/hooks/after-prune.sh
$EDITOR stacks/borgmatic/config/hooks/on-error.sh
chmod 0755 stacks/borgmatic/config/hooks/*.sh

# 3. .env (no se commitea)
cp stacks/borgmatic/.env.example stacks/borgmatic/.env
$EDITOR stacks/borgmatic/.env

# 4. Validar compose
docker compose -f stacks/borgmatic/docker-compose.yml --env-file .env config >/dev/null

# 5. Inicializar el repo Borg (UNA sola vez en la vida del homelab)
docker compose -f stacks/borgmatic/docker-compose.yml --env-file .env run --rm borgmatic \
  borg init --encryption=repokey-blake2 /mnt/borg-repo

# 6. Smoke test: un run completo SIN entrar en cron, en primer plano
docker compose -f stacks/borgmatic/docker-compose.yml --env-file .env run --rm borgmatic \
  borgmatic --verbosity 2 create prune check

# 7. Levantar el stack en daemon (cron interno tomará a las 03:45)
docker compose -f stacks/borgmatic/docker-compose.yml --env-file .env up -d

# 8. Verificar
docker ps --filter name=borgmatic --format '{{.Status}}'
docker logs --since 5m borgmatic
borg list /mnt/hd2t/backups/borg/                     # un archive presente
ls -lh /mnt/hd2t/backups/borg/.last-success           # marca presente
cat /var/lib/node_exporter/textfile/homelab_backup.prom
```

> **Importante**: el paso 5 (`borg init`) **no** se debe repetir; rompería el repo. Si Borgmatic detecta repo no inicializado en arranques posteriores, falla con un error claro y el operador sabe que la inicialización se saltó.

### Programación: por qué cron interno y no `borgmatic --schedule`

| Opción | Pros | Contras | Decisión |
|---|---|---|---|
| Cron interno del contenedor (`BACKUP_CRON`) | Una sola pieza, logs unificados con el resto del stack, reproducible al 100% en otra máquina copiando el directorio. | El cron del contenedor depende de que el contenedor esté vivo. Si el restart loop entra en bucle, no se ejecuta. | **Aceptado** (el healthcheck detecta el zombi). |
| `systemd timer` en el host invocando `docker compose run --rm borgmatic` | Aislamiento limpio, timer nativo. | Dos sitios donde mirar (timer host + contenedor), peor reproducibilidad, mete dependencia en el systemd del host. | Descartado. |
| Job de cron del host | Solución barata. | Mismas pegas que systemd timer + falta de tracking de últimas ejecuciones. | Descartado. |

### Notificaciones (resumen aplicado)

| Evento | Origen | Canal |
|---|---|---|
| Cada start/finish/fail | `healthchecks` de Borgmatic | Push monitor de Uptime Kuma. Los push reciben heartbeat; la **ausencia** de heartbeat 36 h dispara alerta crítica. |
| `on_error` (cualquier hook revienta) | `on-error.sh` | Apprise → Telegram inmediato. |
| `borg check` falla | `consistency.checks` de Borgmatic + `on_error` | Apprise → Telegram. |
| `rclone sync` falla 2 noches consecutivas | Regla Prometheus sobre `homelab_backup_offsite_last_success_timestamp` | Alertmanager → Apprise → Telegram. |
| Backup OK | `after-backup.sh` actualiza textfile y marca last-success | Sin notificación activa: la métrica positiva se ve en Grafana y la ausencia de fallo es la confirmación. |

> **Anti-patrón evitado**: notificar éxitos por Telegram. Si todas las noches el operador recibe "✅ backup OK", deja de leer el canal y se pierde el "❌ backup FAIL". Solo se notifica activamente lo que requiere acción.

---

## Almacenamiento

| Ruta host | Ruta contenedor | Modo | Contenido |
|---|---|---|---|
| `/mnt/hd2t/backups/borg/` | `/mnt/borg-repo` | RW | Repo Borg, cifrado `repokey-blake2`. Crece con cada archive; deduplicado. |
| `/mnt/hd2t/backups/dumps/` | `/mnt/dumps` | RW | Dumps efímeros: existen segundos antes de entrar al archive y se borran en `after_backup`. Espacio pico ≈ tamaño del dump más grande (~Postgres Nextcloud). |
| `/mnt/hd2t/apps/` | `/source/apps` | **RO** | Origen de datos. RO obligatorio. |
| `/home/homelab/homelab/stacks/` | `/source/stacks` | RO | Composes y `.env` por stack (los `.env` no están en git). |
| `/home/homelab/homelab/secrets/` | `/source/secrets` | RO | Pase de secretos al archive Borg (incluye `borg.passphrase` mismo: ver "Bootstrap problem" en `01-estrategia-backup.md`). |
| `/home/homelab/homelab/.env` | `/source/env-global` | RO | Variables globales (`TZ`, `PUID`, `PGID`, `LAN_IP`). |
| `/home/homelab/homelab/BACKUPS_LOG.md` | `/source/BACKUPS_LOG.md` | RO | Bitácora de drills, versionada en git. |
| `/home/homelab/homelab/secrets/borg.passphrase` | `/run/secrets/borg.passphrase` | RO | Passphrase Borg (`0600`). |
| `/home/homelab/homelab/secrets/rclone.conf` | `/run/secrets/rclone.conf` | RO | Config rclone con remotes `b2` y `b2crypt`. |
| `/home/homelab/homelab/secrets/rclone-crypt.passphrase` | `/run/secrets/rclone-crypt.passphrase` | RO | Passphrase del overlay crypt. |
| `/home/homelab/homelab/secrets/notifications/` | `/run/secrets/notifications` | RO | URLs de Apprise y Uptime Kuma push. |
| `/var/lib/node_exporter/textfile/` | `/var/lib/node_exporter/textfile` | RW | `homelab_backup.prom` consumido por `node_exporter`. |
| `stacks/borgmatic/config/borgmatic.yaml` | `/etc/borgmatic.d/borgmatic.yaml` | RO | Config declarativa, **versionada en git**. |
| `stacks/borgmatic/config/hooks/` | `/etc/borgmatic.d/hooks/` | RO | Scripts de hook, **versionados en git**. |

### Espacio esperado en `hd2t`

| Componente | Tamaño orientativo en estado estable |
|---|---|
| Repo Borg | 50–250 GiB (depende del churn de Nextcloud y del histórico GFS). Reservados 300 GiB iniciales. |
| Dumps efímeros | < 5 GiB pico (dump custom de Postgres Nextcloud + SQLite snapshots). |
| Cache de Borg en `/root/.borg` (dentro del propio contenedor, persistido vía bind opcional) | < 100 MiB. No se persiste; se reconstruye en cada arranque. |

> **Decisión sobre la cache de Borg**: no se monta volumen para `/root/.borg`. Se prefiere que cada run reconstruya el chunks index si fuera necesario; el coste (segundos extra) es marginal frente a la ganancia operativa de no tener un volumen que pueda corromperse en silencio.

### Permisos en host

```bash
# Tras crear los hooks
chmod 0700 /home/homelab/homelab/secrets
chmod 0600 /home/homelab/homelab/secrets/borg.passphrase \
           /home/homelab/homelab/secrets/rclone.conf \
           /home/homelab/homelab/secrets/rclone-crypt.passphrase
chmod 0700 /home/homelab/homelab/secrets/notifications
find /home/homelab/homelab/secrets/notifications -type f -exec chmod 0600 {} \;
chown -R homelab:homelab /home/homelab/homelab/secrets

# textfile collector
sudo install -d -m 0775 -o nodeexp -g homelab /var/lib/node_exporter/textfile
```

---

## Backup

### Backup del propio Borgmatic

| Artefacto | Estrategia |
|---|---|
| `stacks/borgmatic/docker-compose.yml` | Versionado en git. |
| `stacks/borgmatic/config/borgmatic.yaml` | Versionado en git. |
| `stacks/borgmatic/config/hooks/*.sh` | Versionado en git. |
| `stacks/borgmatic/.env` | **No** versionado. Respaldado por el propio Borg como parte de `/source/stacks/borgmatic/.env` (recursividad controlada: el repo no se respalda a sí mismo porque está excluido implícitamente — `/mnt/hd2t/backups/borg/` no está en `source_directories`). |
| `secrets/borg.passphrase` y `secrets/rclone-crypt.passphrase` | Respaldados dentro del propio Borg (capturados en `/source/secrets/`). **Bootstrap problem** mitigado por la custodia fuera de banda (caja fuerte + gestor cloud externo) que `01-estrategia-backup.md` cierra. |

### Métricas de salud para Prometheus

`05-monitorizacion/01-prometheus.md` recoge la regla; aquí queda fijado el contrato del fichero `homelab_backup.prom`:

```
homelab_backup_last_success_timestamp           gauge   unix ts del último create+prune+check OK
homelab_backup_archives_total                   gauge   nº total de archives en el repo
homelab_backup_dedup_size_bytes                 gauge   bytes deduplicados ocupados en hd2t
homelab_backup_offsite_last_success_timestamp   gauge   unix ts del último rclone sync OK (0 si offsite OFF)
```

Reglas de alerta (en `prometheus/rules/borgmatic.yml`, definidas formalmente en Fase 5):

```yaml
groups:
  - name: borgmatic
    rules:
      - alert: BorgmaticNoSuccess36h
        expr: time() - homelab_backup_last_success_timestamp > 36 * 3600
        for: 10m
        labels: { severity: critical }
      - alert: BorgmaticOffsiteLag48h
        expr: time() - homelab_backup_offsite_last_success_timestamp > 48 * 3600
        for: 10m
        labels: { severity: warning }
      - alert: BorgmaticArchivesTooFew
        expr: homelab_backup_archives_total < 5
        for: 1h
        labels: { severity: warning }
```

### Verificación operativa diaria/semanal/mensual

| Cadencia | Comando | Qué se valida |
|---|---|---|
| Diaria (automática) | `borgmatic create prune check --only repository` | Crea archive, poda GFS, comprueba que el repo es coherente. |
| Semanal (lunes, automática) | `borgmatic compact` | Recupera espacio físico tras el prune. |
| Mensual (día 1, automática) | `borgmatic check --only archives` + `--only extract` | Rehash completo de archives y dry-run de extracción. |
| Trimestral (manual) | Restore drill completo descrito en `03-backup-docker-volumes.md` | Servicio T1 restaurado a `exports/restore-drill-YYYYMMDD/`, hashes comparados, BBDD scratch levantada para validar. |
| Anual (manual) | Restore drill **forzando origen offsite** (`--repository b2crypt:...` o `rclone copy` previo del repo offsite a un scratch dir) | Valida que la cadena rclone-crypt → Borg sigue siendo capaz de descifrar y restaurar. |

> Cualquier fallo se anota en `BACKUPS_LOG.md` con fecha, comando, output relevante y acción correctiva. La bitácora es el único registro **versionado** de la salud histórica del backup.

---

## Decisiones que **no** se cierran aquí

- **Procedimientos manuales detallados de restore por servicio** (cómo restaurar Nextcloud paso a paso, Authelia, Pi-hole, MinIO buckets) → `03-backup-docker-volumes.md`.
- **Reglas de alerta en Prometheus / Alertmanager** → se referencian aquí, pero el detalle del routing por severidad vive en Fase 5.
- **Configuración del bucket B2 (lifecycle, versioning)** → vive en la consola del proveedor; documentada operativamente en `01-estrategia-backup.md`. Si en algún momento Backblaze permite gestión via Terraform/IaC, se reabre.
- **Disco USB externo "frío" opcional** → reabierto como en la estrategia. Cuando se compre, se añade un script `scripts/cold-backup.sh` que rsync-ea `/mnt/hd2t/backups/borg/` y `secrets/` al disco montado; no requiere tocar el stack Borgmatic.
- **Dashboard Grafana de backups** → se despliega en Fase 5.5 (panel "Backups"). Aquí solo se garantiza que las métricas existen y son consistentes.
- **Borg sobre `rclone serve restic`** o destinos SSH directos → reabribles si se cambia de proveedor offsite.

---

## Referencias

- [Documento anterior: `docs/07-backups/01-estrategia-backup.md`](./01-estrategia-backup.md)
- [Documento siguiente: `docs/07-backups/03-backup-docker-volumes.md`](./03-backup-docker-volumes.md)
- [Documento relacionado: `docs/01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)
- [Documento relacionado: `docs/02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)
- [Documento relacionado: `docs/02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)
- [Documento relacionado: `docs/05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md)
- [Borgmatic — Documentación oficial](https://torsion.org/borgmatic/)
- [Borgmatic — Hooks de bases de datos](https://torsion.org/borgmatic/docs/how-to/backup-your-databases/)
- [Borgmatic — Command hooks](https://torsion.org/borgmatic/docs/how-to/add-preparation-and-cleanup-steps-to-backups/)
- [Borgmatic — Healthchecks/Apprise integration](https://torsion.org/borgmatic/docs/how-to/monitor-your-backups/)
- [Imagen `borgmatic-collective/borgmatic` (GHCR)](https://github.com/borgmatic-collective/docker-borgmatic)
- [BorgBackup — Modos de cifrado](https://borgbackup.readthedocs.io/en/stable/usage/init.html#encryption-modes)
- [rclone — Backblaze B2](https://rclone.org/b2/)
- [rclone — `crypt` overlay](https://rclone.org/crypt/)
- [Apprise — formato de URLs por canal](https://github.com/caronc/apprise/wiki)
- [Uptime Kuma — Push monitors](https://github.com/louislam/uptime-kuma/wiki/Push-Monitor)
- [Prometheus — Textfile collector](https://github.com/prometheus/node_exporter#textfile-collector)
