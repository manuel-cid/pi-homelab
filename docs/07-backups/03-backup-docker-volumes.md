# Backup y Restore de Volúmenes Docker y Bases de Datos

## Descripción

`01-estrategia-backup.md` cerró las **decisiones** (3-2-1, GFS, tiers, RPO/RTO) y `02-borgmatic.md` materializó el **automatismo** (stack Borgmatic con cron interno, hooks SQL nativos, sync offsite via rclone, métricas a Prometheus). Falta una pieza que ninguno de los dos documenta: el **manual operativo del operador**. Cuando algo se rompe a las 23:30 de un sábado y el operador necesita restaurar un servicio concreto, no quiere leer la estrategia ni la configuración YAML; quiere los **comandos exactos**, en el **orden exacto**, con las **trampas conocidas** ya marcadas. Este documento es ese manual.

El alcance se concentra en cuatro escenarios operativos, ordenados por probabilidad real:

1. **Restauración puntual de un servicio** (caso más frecuente). Un fichero corrupto, una BBDD que un upgrade dejó inconsistente, un `docker compose down -v` ejecutado por error. El operador necesita restaurar **un solo servicio** desde el archive más reciente sin tocar el resto del homelab.
2. **Restore drill trimestral** (verificación). El procedimiento que `01-estrategia-backup.md` impone trimestralmente: elegir un servicio T1, restaurarlo a un directorio scratch, validar integridad, documentar tiempos en `BACKUPS_LOG.md`. Sin drill, los backups son una esperanza.
3. **Bootstrap completo tras desastre** (caso menos frecuente, máximo impacto). `hd2t` muere o la Pi se incendia. Hay que reflashear, repasar Fases 0–6 y devolver el homelab a la última noche conocida desde el offsite. Esto incluye descargar el repo Borg desde Backblaze B2, descifrar la cadena `rclone crypt → Borg`, y restaurar selectivamente.
4. **Procedimientos manuales por motor de BBDD**. Aunque Borgmatic automatiza los dumps, hay momentos en que el operador necesita un dump *ad-hoc* (antes de un upgrade mayor de Postgres, antes de una migración entre stacks, para clonar un servicio T1 a un entorno scratch). Este documento centraliza **los comandos exactos** para PostgreSQL, MariaDB/MySQL, SQLite, Redis (con su matiz) y MinIO.

> **Recordatorio de alcance**: este documento **no introduce nuevos servicios ni stacks**. No hay `docker-compose.yml` propio. La sección "Docker Compose" más abajo describe el contenedor *one-shot* que el operador usa para restaurar (un Borgmatic en modo interactivo, sin cron); no es un servicio nuevo, es el mismo binario del stack `borgmatic` invocado con `--rm`. La filosofía es: **restaurar es una operación humana deliberada**, no un servicio automático. Automatizar el restore de un T1 es tan peligroso como no respaldarlo.

> **Re-abrible**: si en algún momento se introduce un volumen nominal Docker (named volume) por excepción documentada — por ejemplo, una imagen de tercero que no admita bind mount —, el procedimiento de backup/restore para ese volumen vive en este documento (sección "Volúmenes nominales: la excepción"). Por defecto, el homelab no usa volúmenes nominales: todo es bind mount a `/mnt/hd2t/apps/<svc>/`.

---

## Requisitos Previos

- **`07-backups/01-estrategia-backup.md` y `07-backups/02-borgmatic.md`** completados. En particular:
  - Stack `borgmatic` desplegado y con al menos **un archive** en `/mnt/hd2t/backups/borg/`. Verificar con `borg list /mnt/hd2t/backups/borg/`.
  - Passphrase Borg disponible en `/home/homelab/homelab/secrets/borg.passphrase` (`0600`).
  - `secrets/rclone.conf` con remote `b2crypt:` operativo (se prueba con `rclone --config secrets/rclone.conf ls b2crypt:homelab/borg/`).
  - `BACKUPS_LOG.md` inicializado en la raíz del repo.
- **Fase 6** completa: Nextcloud + `nextcloud-db` (Postgres 16) corriendo. Es el principal cliente Postgres del homelab y el primer caso de restore real.
- **Fase 5**: Dozzle disponible para inspeccionar logs de los contenedores scratch que se levanten durante un restore drill.
- **Estructura `/mnt/hd2t/backups/exports/`** (`0750 homelab:homelab`) creada en Fase 1. Es donde aterrizan los **restore drills** y las restauraciones puntuales antes de promoverse al destino final.
- **Espacio libre en `hd2t`**: como mínimo el tamaño del servicio más grande a restaurar (típicamente Nextcloud-DB Postgres ≈ 2–10 GiB en 2026). Verificar con `df -h /mnt/hd2t` antes de iniciar un drill.
- **Acceso SSH a la Pi como `homelab`**: ningún procedimiento de este documento requiere `root`; todos asumen `homelab:homelab` con permisos sobre `/mnt/hd2t/` y sobre el socket Docker (grupo `docker`, decidido en Fase 2).

---

## Docker Compose

Este documento **no despliega un stack nuevo**. Lo que sí define es el patrón de invocación *one-shot* que el operador usa para todas las operaciones de restore: un `docker compose run --rm` sobre el stack `borgmatic` ya existente, con un montaje extra al directorio de scratch del drill.

### Patrón one-shot de restore (referencia)

`stacks/borgmatic/restore.compose.yml` (override opcional, **versionado** en git porque no contiene secretos):

```yaml
# Override de docker-compose para operaciones one-shot de restore.
# Uso:
#   docker compose -f docker-compose.yml -f restore.compose.yml \
#     run --rm -it borgmatic bash
#
# Diferencias con el stack productivo:
#   - sin cron interno (override de BACKUP_CRON)
#   - bind extra a exports/ con RW para escribir restauraciones
#   - bind extra a un scratch dir efímero
#   - desactiva healthcheck (la operación es interactiva, no daemon)

services:
  borgmatic:
    environment:
      BACKUP_CRON: ""                  # neutraliza el cron interno
      BORGMATIC_VERBOSITY: "2"         # debug durante restores
    volumes:
      - /mnt/hd2t/backups/exports:/mnt/exports
    healthcheck:
      disable: true
    restart: "no"
```

`scripts/restore-shell.sh` (atajo para abrir una shell de restore):

```bash
#!/usr/bin/env bash
# scripts/restore-shell.sh — abre una shell interactiva en el contenedor
# borgmatic con el override de restore. NO ejecuta restauración por sí mismo.
set -euo pipefail

cd /home/homelab/homelab/stacks/borgmatic

docker compose \
  -f docker-compose.yml \
  -f restore.compose.yml \
  --env-file .env \
  run --rm -it borgmatic bash
```

> **Por qué un override y no un stack aparte**: el código del binario, los secretos y los bind mounts ya están afinados en el stack productivo. Duplicar el `docker-compose.yml` solo para restore introduce dos sitios donde mantener volúmenes y secretos sincronizados. Un override estándar de Compose añade exactamente lo que diferencia el modo restore (sin cron, con `exports/` RW, healthcheck off).

> **Por qué `run --rm` y no `exec`**: el contenedor productivo está vivo con su cron. Si el operador hace `exec`, comparte recursos con la próxima ejecución programada (riesgo de pisarse con un run nocturno). Un `run --rm` lanza un contenedor independiente, ejecuta lo necesario y se autodestruye.

### Comandos one-liner habituales

Tres invocaciones cubren el 95% de los restores. Todas asumen que el operador está en `/home/homelab/homelab/stacks/borgmatic/`.

```bash
# 1. Listar archives del repo local
docker compose run --rm borgmatic borg list /mnt/borg-repo

# 2. Listar el contenido de un archive concreto
docker compose run --rm borgmatic \
  borg list /mnt/borg-repo::pi5-homelab-2026-04-28T03-45 | head

# 3. Extraer una ruta concreta a /mnt/exports/restore-YYYYMMDD/
docker compose -f docker-compose.yml -f restore.compose.yml \
  run --rm borgmatic \
  borg extract --list \
    /mnt/borg-repo::pi5-homelab-2026-04-28T03-45 \
    source/apps/authelia/data
```

---

## Configuración

Esta sección no configura UI ni servicios; configura **el patrón mental del operador** para restaurar. Está dividida en tres flujos: restore puntual, restore drill, y bootstrap completo. Cada flujo se materializa con comandos concretos en las secciones de motor de BBDD más abajo.

### Flujo 1 — Restore puntual de un servicio

Caso típico: "Authelia se ha quedado sin sesiones, sospecho que la BBDD está corrupta tras un kill brusco". El operador quiere restaurar `authelia/data/db.sqlite3` desde la última noche.

```
1. Identificar el archive más reciente disponible.
2. PARAR el servicio afectado (no Borgmatic).
3. Mover el dato corrupto a un nombre con sufijo .broken (no borrar todavía).
4. Extraer del archive solo la ruta necesaria a /mnt/exports/restore-YYYYMMDD/.
5. Validar el extraído (hashes, abrir BBDD en modo RO si aplica).
6. Promover el extraído al destino final (cp/mv con ownership correcto).
7. Levantar el servicio.
8. Smoke test funcional (login, lectura, métricas).
9. Borrar el .broken si todo OK.
10. Anotar en BACKUPS_LOG.md.
```

| Paso | Comando ejemplo (Authelia SQLite) | Notas |
|---|---|---|
| 1 | `docker compose run --rm borgmatic borg list /mnt/borg-repo \| tail` | El último archive de la noche pasada. |
| 2 | `docker compose -f stacks/authelia/docker-compose.yml down` | El servicio debe estar **parado** durante la sustitución del fichero SQLite. Si está vivo escribiendo al WAL, el restore es inconsistente. |
| 3 | `mv /mnt/hd2t/apps/authelia/data/db.sqlite3 /mnt/hd2t/apps/authelia/data/db.sqlite3.broken-$(date +%F)` | No borrar: si el restore falla, el fichero corrupto permite forensia. |
| 4 | (ver "PostgreSQL/MariaDB/SQLite" más abajo según motor) | El comando difiere por tipo. |
| 5 | `sqlite3 /mnt/exports/.../db.sqlite3 "PRAGMA integrity_check;"` | Para SQLite. Para Postgres se valida con `pg_restore --list` (no se aplica todavía). |
| 6 | `cp /mnt/exports/.../db.sqlite3 /mnt/hd2t/apps/authelia/data/db.sqlite3 && chown homelab:homelab /mnt/hd2t/apps/authelia/data/db.sqlite3` | El stack se levanta con el fichero in-place. |
| 7 | `docker compose -f stacks/authelia/docker-compose.yml up -d` | — |
| 8 | Login en Authelia desde el navegador | — |
| 9 | `rm /mnt/hd2t/apps/authelia/data/db.sqlite3.broken-*` | Solo si el smoke test pasa. |
| 10 | Editar `BACKUPS_LOG.md` y commit | Fecha, archive usado, motivo, tiempo total. |

> **Anti-patrón**: restaurar **encima** del fichero corrupto sin pararar el servicio. Aunque SQLite permite `.backup` en caliente para hacer dumps, **escribir** un `.sqlite3` mientras el servicio lo tiene abierto es undefined behavior; en el peor caso, se corrompe el WAL y se requiere un segundo restore.

### Flujo 2 — Restore drill trimestral

Diferencia clave con el restore puntual: el drill **no toca producción**. Restaura a un scratch dir, valida, y descarta. El objetivo es responder a la pregunta "¿el backup de la noche del lunes pasado restauraría algo útil?".

```
1. Elegir un servicio T1 al azar de la lista (rotar cada trimestre).
2. mkdir -p /mnt/hd2t/backups/exports/restore-drill-YYYYMMDD/
3. Extraer del último archive todo el directorio del servicio.
4. Para BBDD: levantar un contenedor scratch (postgres:16-alpine, mariadb:11-alpine,
   o un binario sqlite3 dentro del contenedor borgmatic) y aplicar el dump.
5. Ejecutar SELECTs básicos: contar filas de tablas relevantes, leer un registro
   conocido (e.g. el usuario admin de Authelia debe existir).
6. Para ficheros: comparar count y tamaño total contra el live (deltas razonables
   por escrituras durante el día).
7. Documentar tiempos: cuánto tardó borg extract, cuánto pg_restore, cuánto la
   validación. Esto alimenta el RTO real.
8. rm -rf /mnt/hd2t/backups/exports/restore-drill-YYYYMMDD/
9. Anotar en BACKUPS_LOG.md con detalle.
```

Rotación T1 sugerida (cuatro trimestres, una rotación anual completa):

| Trimestre | Servicio T1 a drillear |
|---|---|
| Q1 (enero–marzo) | Nextcloud (Postgres + ficheros) |
| Q2 (abril–junio) | Authelia (SQLite + secretos) |
| Q3 (julio–septiembre) | Pi-hole (`pihole-FTL.db` + listas custom + DHCP leases) |
| Q4 (octubre–diciembre) | Vaultwarden (cuando esté desplegado) o el T1 con más cambios del año |

> **Drill anual desde offsite**: una vez al año (típicamente diciembre o enero, alineado con la auditoría de fin de año), el drill **forza** descarga desde el bucket B2 en lugar de usar el repo local. Comando: `rclone --config secrets/rclone.conf copy b2crypt:homelab/borg/data/0/<segment> /mnt/hd2t/backups/exports/offsite-pull/` previo, y luego `borg extract` apuntando al pull. Esto valida la cadena `rclone crypt → Borg` que es la única red de seguridad en un escenario de pérdida total.

### Flujo 3 — Bootstrap completo tras desastre

Caso más grave: la Pi y `hd2t` desaparecen. Hardware nuevo, microSD nueva, HDD nuevo. El operador tiene exclusivamente:

- La passphrase Borg (de la caja fuerte).
- La passphrase rclone-crypt (de la caja fuerte).
- Las credenciales B2 (App Key del gestor cloud externo).
- El repo git (de GitHub privado).

```
1. Reflashear la microSD (Raspberry Pi OS según Fase 0).
2. Aplicar Fases 0–2 hasta tener Docker funcional y Caddy listo.
   No desplegar todavía servicios T1; solo el sustrato.
3. Restaurar secretos manualmente:
   a. Crear /home/homelab/homelab/ y clonar el repo git.
   b. Crear secrets/borg.passphrase y secrets/rclone-crypt.passphrase
      escribiéndolas a mano desde la caja fuerte.
   c. Crear secrets/rclone.conf con las credenciales B2 (a mano).
4. Pull del repo Borg desde offsite a /mnt/hd2t/backups/borg/.
5. Verificar integridad del repo recuperado: borg check --repository-only.
6. Restaurar /mnt/hd2t/apps/ desde el archive más reciente (extract completo).
7. Restaurar /mnt/hd2t/backups/dumps/ (los dumps SQL de la última noche viven
   ahí dentro del archive — son el origen de verdad para Postgres).
8. Aplicar Fase 6 (servicios) levantando los stacks. Para los servicios con
   Postgres: arrancar el contenedor de BBDD vacío y restaurar desde
   /mnt/hd2t/backups/dumps/<svc>/<svc>.dump.
9. Smoke test extensivo: login en Nextcloud, login en Authelia, Pi-hole con
   sus listas, etc.
10. Anotar en BACKUPS_LOG.md el evento, los tiempos y los problemas.
```

| Paso | Comando ejemplo | Tiempo estimado (RTO) |
|---|---|---|
| 1 | (manual, según Fase 0) | 1–2 h |
| 2 | (Fases 0–2 reaplicadas) | 2–3 h |
| 3a | `git clone git@github.com:<usuario>/homelab.git /home/homelab/homelab` | 1 min |
| 3b–3c | `vi /home/homelab/homelab/secrets/borg.passphrase` (cuidado con permisos `0600`) | 5 min |
| 4 | `rclone --config secrets/rclone.conf copy b2crypt:homelab/borg/ /mnt/hd2t/backups/borg/ --progress --transfers 8` | 1–6 h según volumen y ancho de banda |
| 5 | `borg check --repository-only /mnt/hd2t/backups/borg/` | 5–30 min |
| 6 | (ver "Restore masivo desde archive" más abajo) | 10–60 min |
| 7 | (incluido en paso 6) | — |
| 8 | (ver "PostgreSQL — Restore" por servicio) | 10–30 min por BBDD |
| 9 | Manual | 30 min |
| 10 | Manual | 10 min |

**RTO total estimado en escenario "pérdida del sitio"**: 8–14 h en condiciones favorables (hardware comprado en local, fibra estable, operador descansado). Compatible con el RTO ≤ 24 h establecido en `01-estrategia-backup.md`.

> **Bootstrap problem revisitado**: las passphrase Borg y rclone-crypt **viven dentro** del propio Borg (en `secrets/`). Para el primer arranque post-desastre, esas dos passphrase se obtienen exclusivamente de la **custodia fuera de banda** (caja fuerte + gestor cloud externo no homelab). Una vez recuperadas, se descifra el repo, se restaura `secrets/`, y a partir de ahí el sistema se autosostiene. **La caja fuerte y el gestor cloud externo no son opcionales**.

---

## Procedimientos por motor de base de datos

Esta es la sección de referencia rápida. Cada motor tiene su sub-sección con: backup ad-hoc, restore puntual, restore drill, particularidades.

### PostgreSQL (Nextcloud, futuros Bookstack/Paperless)

#### Backup ad-hoc (antes de un upgrade mayor)

Borgmatic ya hace dumps nocturnos automáticos vía el hook `postgresql_databases`. Pero antes de un upgrade de Postgres 16 → 17, el operador quiere un dump *fuera de Borgmatic* que pueda inspeccionar y guardar en un destino temporal.

```bash
# Desde el host (no desde el contenedor Postgres):
SVC=nextcloud
DB_CONTAINER=nextcloud-db
DB_USER=nextcloud
DB_NAME=nextcloud
TS=$(date +%F-%H%M)
DEST=/mnt/hd2t/backups/exports/${SVC}-pre-upgrade-${TS}.dump

docker exec -i "${DB_CONTAINER}" \
  pg_dump -U "${DB_USER}" -d "${DB_NAME}" \
    --format=custom --compress=9 \
    --no-owner --no-privileges \
  > "${DEST}"

# Verificación inmediata: pg_restore puede leer el TOC del dump
docker run --rm -v "${DEST}:/dump:ro" postgres:16-alpine \
  pg_restore --list /dump | head

# Tamaño y hash
ls -lh "${DEST}"
sha256sum "${DEST}" > "${DEST}.sha256"
```

| Decisión | Valor | Por qué |
|---|---|---|
| `--format=custom` | binario comprimido | Permite restore selectivo de tablas con `pg_restore -t`. Imprescindible cuando se quiere restaurar solo `oc_filecache` y no toda la BBDD. |
| `--compress=9` | máxima compresión | El cuello de botella es el disco USB, no la CPU del Pi 5. Compresión alta ahorra espacio en `exports/` y acelera el sync offsite si se respaldase ese fichero. |
| `--no-owner --no-privileges` | sí | El restore en otro contenedor (mismo hostname `nextcloud-db` pero potencialmente otro UUID de cluster) no necesita re-aplicar grants; los recrea el `init` del nuevo contenedor con `POSTGRES_USER` / `POSTGRES_PASSWORD`. |
| `pg_dumpall` | descartado para este patrón | Útil si se respaldan **todos** los clusters; aquí cada servicio tiene su propio Postgres y se respalda DB a DB. Para roles/globals se hace un `pg_dumpall --globals-only` aparte cuando se introduzca un Postgres compartido (no es el caso hoy). |

#### Restore puntual desde el archive Borg

Caso: el dump nocturno de Nextcloud existe en el último archive. Hay que restaurarlo a la BBDD productiva (la BBDD va a perder los cambios de hoy).

```bash
# 1. Parar Nextcloud (no su BBDD; la BBDD la queremos viva para recibir el restore)
cd /home/homelab/homelab
docker compose -f stacks/nextcloud/docker-compose.yml stop nextcloud

# 2. Extraer el dump del archive más reciente
cd stacks/borgmatic
ARCHIVE=$(docker compose run --rm borgmatic borg list /mnt/borg-repo --short | tail -1)
docker compose -f docker-compose.yml -f restore.compose.yml run --rm borgmatic \
  borg extract --list \
    "/mnt/borg-repo::${ARCHIVE}" \
    borgmatic/postgresql_databases/nextcloud-db/nextcloud
# El dump cae en /mnt/exports/borgmatic/postgresql_databases/nextcloud-db/nextcloud

DUMP=/mnt/hd2t/backups/exports/borgmatic/postgresql_databases/nextcloud-db/nextcloud

# 3. Aplicar el dump sobre la BBDD productiva (drop + recreate cluster lógico).
#    pg_restore con --clean --if-exists --create regenera la BBDD desde cero.
docker exec -i nextcloud-db \
  pg_restore --clean --if-exists --create \
             --no-owner --no-privileges \
             -U nextcloud -d postgres \
  < "${DUMP}"

# 4. Validación rápida
docker exec nextcloud-db psql -U nextcloud -d nextcloud -c "SELECT count(*) FROM oc_users;"

# 5. Levantar Nextcloud
cd /home/homelab/homelab
docker compose -f stacks/nextcloud/docker-compose.yml up -d nextcloud

# 6. Smoke test desde navegador + occ files:scan si hubo desync de ficheros
docker exec -u www-data nextcloud occ files:scan --all
```

> **Trampa habitual**: hacer `pg_restore -d nextcloud` (la BBDD a restaurar) en lugar de `-d postgres` (la BBDD admin). Si la BBDD destino tiene conexiones activas, el `DROP DATABASE` falla. La pauta es: **conectarse a `postgres` y dejar que `pg_restore --clean --create` haga DROP+CREATE de la BBDD destino**.

> **Trampa con `--single-transaction`**: parece atractivo (rollback automático en error), pero es incompatible con `--clean --create` porque el DROP DATABASE no puede ocurrir dentro de una transacción. Se omite.

#### Restore drill — Postgres en contenedor scratch

```bash
# 1. Extraer el dump al scratch
DRILL_DIR=/mnt/hd2t/backups/exports/restore-drill-$(date +%F)
mkdir -p "${DRILL_DIR}"

cd /home/homelab/homelab/stacks/borgmatic
ARCHIVE=$(docker compose run --rm borgmatic borg list /mnt/borg-repo --short | tail -1)
docker compose -f docker-compose.yml -f restore.compose.yml run --rm borgmatic \
  bash -c "borg extract --strip-components=99 \
    /mnt/borg-repo::${ARCHIVE} borgmatic/postgresql_databases/nextcloud-db/nextcloud \
    --strip-components=4 \
    && cp -a borgmatic/postgresql_databases/nextcloud-db/nextcloud /mnt/exports/restore-drill-$(date +%F)/nextcloud.dump"

# 2. Levantar un Postgres scratch en una red separada
docker network create drill-net 2>/dev/null || true
docker run -d --name drill-postgres --network drill-net \
  -e POSTGRES_PASSWORD=drill -e POSTGRES_USER=nextcloud -e POSTGRES_DB=nextcloud \
  postgres:16-alpine

# Esperar a que arranque
until docker exec drill-postgres pg_isready -U nextcloud; do sleep 1; done

# 3. Restaurar
docker exec -i drill-postgres \
  pg_restore --no-owner --no-privileges -U nextcloud -d nextcloud \
  < "${DRILL_DIR}/nextcloud.dump"

# 4. Validar
docker exec drill-postgres psql -U nextcloud -d nextcloud -c "
  SELECT
    (SELECT count(*) FROM oc_users)        AS usuarios,
    (SELECT count(*) FROM oc_filecache)    AS ficheros_cacheados,
    (SELECT max(mtime) FROM oc_filecache)  AS ultimo_mtime
;"

# 5. Tear down
docker rm -f drill-postgres
docker network rm drill-net
rm -rf "${DRILL_DIR}"

# 6. Documentar en BACKUPS_LOG.md
```

#### Tabla resumen Postgres

| Operación | Comando núcleo | Tiempo típico Nextcloud (hoy) |
|---|---|---|
| Dump ad-hoc | `pg_dump --format=custom --compress=9 --no-owner --no-privileges` | 30–120 s |
| Restore productivo | `pg_restore --clean --if-exists --create --no-owner --no-privileges` | 30–180 s |
| Restore drill | Igual que el productivo, en `drill-postgres` | 30–180 s + 30 s setup |
| `pg_dumpall --globals-only` | (no aplica hoy: no hay roles compartidos) | — |

---

### MariaDB / MySQL (futuros Bookstack, Paperless-ngx)

Hoy ningún stack despliega MariaDB; este apartado queda como referencia para cuando Bookstack o Paperless aterricen. La lógica es paralela a Postgres salvo en los flags.

#### Backup ad-hoc

```bash
SVC=bookstack
DB_CONTAINER=bookstack-db
DB_USER=bookstack
DB_NAME=bookstack
TS=$(date +%F-%H%M)
DEST=/mnt/hd2t/backups/exports/${SVC}-pre-upgrade-${TS}.sql.gz

docker exec -i "${DB_CONTAINER}" \
  mysqldump -u "${DB_USER}" -p"$(cat /home/homelab/homelab/secrets/db/${SVC}-db.env | grep MYSQL_PASSWORD | cut -d= -f2)" \
    --single-transaction --routines --triggers --events \
    --default-character-set=utf8mb4 \
    "${DB_NAME}" \
  | gzip -9 > "${DEST}"

ls -lh "${DEST}"
gunzip -t "${DEST}"      # gzip integrity test
sha256sum "${DEST}" > "${DEST}.sha256"
```

| Decisión | Valor | Por qué |
|---|---|---|
| `--single-transaction` | sí | Consistencia transaccional para InnoDB sin lock global. Solo válido si **todas** las tablas son InnoDB (no MyISAM). Bookstack/Paperless cumplen. |
| `--routines --triggers --events` | sí | Si no se incluyen, los procedimientos almacenados, triggers y events se pierden silenciosamente. Caso real reportado en muchas restauraciones fallidas. |
| `--default-character-set=utf8mb4` | sí | Evita corrupción de caracteres en BBDD que mezclan `utf8` (3-byte) y `utf8mb4` (4-byte). |
| `--master-data` | descartado | Solo útil para configurar replicación. El homelab single-node no replica. |
| Compresión `gzip -9` | sí | Output `.sql` puro es muy comprimible (×10). |

#### Restore puntual

```bash
# 1. Parar el servicio aplicación (no la BBDD)
docker compose -f stacks/bookstack/docker-compose.yml stop bookstack

# 2. Extraer el dump del archive
DUMP=/mnt/hd2t/backups/exports/borgmatic/mariadb_databases/bookstack-db/bookstack
# (Borgmatic guarda los dumps mariadb sin .sql.gz; son SQL puros)

# 3. Aplicar
docker exec -i bookstack-db \
  mariadb -u root -p"$(cat /home/homelab/homelab/secrets/db/bookstack-db.env | grep MYSQL_ROOT_PASSWORD | cut -d= -f2)" \
  bookstack < "${DUMP}"

# 4. Validar
docker exec bookstack-db \
  mariadb -u bookstack -p"..." -e "SELECT count(*) FROM users;" bookstack

# 5. Levantar
docker compose -f stacks/bookstack/docker-compose.yml up -d bookstack
```

> **Trampa**: el usuario `bookstack` puede no tener permisos para hacer `DROP TABLE` de tablas con FK. Para un restore "limpio" se conecta como `root` y se aplica `SET FOREIGN_KEY_CHECKS=0; ... ; SET FOREIGN_KEY_CHECKS=1;` (el dump ya lo incluye al principio si se hizo con `mysqldump` estándar).

#### Restore drill MariaDB

Idéntico a Postgres pero con `mariadb:11-alpine` o `mysql:8` según el stack original.

```bash
docker run -d --name drill-mariadb --network drill-net \
  -e MARIADB_ROOT_PASSWORD=drill \
  -e MARIADB_DATABASE=bookstack \
  -e MARIADB_USER=bookstack \
  -e MARIADB_PASSWORD=drill \
  mariadb:11-alpine
```

---

### SQLite (Authelia, Uptime Kuma, Pi-hole, FreshRSS, Linkding, Mealie, Calibre-Web, Stash)

SQLite es el motor más común en el homelab y el que más trampas tiene a la hora de respaldar/restaurar. La regla de oro: **nunca copiar el fichero `.sqlite3` con `cp` mientras el servicio está vivo**.

#### Backup ad-hoc consistente (sin parar el servicio)

```bash
SVC=authelia
DB_PATH=/mnt/hd2t/apps/${SVC}/data/db.sqlite3
TS=$(date +%F-%H%M)
DEST=/mnt/hd2t/backups/exports/${SVC}-${TS}.sqlite3

# Usa la API de backup interna de SQLite (consistente bajo escritura concurrente)
sqlite3 "${DB_PATH}" ".backup '${DEST}'"

# Verificación de integridad
sqlite3 "${DEST}" "PRAGMA integrity_check;"
sqlite3 "${DEST}" "PRAGMA foreign_key_check;"

ls -lh "${DEST}"
sha256sum "${DEST}" > "${DEST}.sha256"
```

| Decisión | Valor | Por qué |
|---|---|---|
| `.backup` (API) | sí | Implementación interna idéntica a `VACUUM INTO`: snapshot consistente bajo cualquier nivel de concurrencia. Funciona aunque el WAL tenga páginas pendientes. |
| `cp ${DB_PATH}` | **prohibido** | Si el servicio escribe durante la copia, el fichero resultante tiene un estado a medio commit. El restore puede fallar o, peor, restaurar datos parciales sin error visible. |
| `sqlite3 ... ".dump" > .sql` | descartado para backup nocturno | Genera SQL textual portable entre versiones de SQLite, pero pesa ~3× más y no preserva PRAGMAs ni encoding binario. Útil para **migraciones** entre versiones major (raro). |
| `PRAGMA foreign_key_check` | sí | Valida que no haya FK rotos. Si SQLite estaba con `foreign_keys=OFF` (común en Pi-hole), una corrupción puede haber introducido orphan rows. |

#### Particularidad Pi-hole `pihole-FTL.db`

`pihole-FTL.db` tiene un WAL agresivo (escribe ~50 entradas/segundo de queries DNS). El hook nativo de Borgmatic ya lo cubre con `wal_checkpoint(TRUNCATE)` previo, pero para un backup ad-hoc:

```bash
# Pi-hole-FTL: forzar checkpoint del WAL antes del .backup para garantizar
# que todo lo escrito hasta el segundo previo esté en el .sqlite3 principal
DB=/mnt/hd2t/apps/pihole/etc/pihole-FTL.db
DEST=/mnt/hd2t/backups/exports/pihole-FTL-$(date +%F-%H%M).db

sqlite3 "${DB}" "PRAGMA wal_checkpoint(TRUNCATE); .backup '${DEST}'"
```

> **No copiar a mano** los ficheros adyacentes `*.db-wal` y `*.db-shm`. El comando `.backup` los consolida internamente; el destino es un fichero único.

#### Restore puntual SQLite

```bash
SVC=authelia
ARCHIVE=$(cd /home/homelab/homelab/stacks/borgmatic && docker compose run --rm borgmatic borg list /mnt/borg-repo --short | tail -1)
DEST_LIVE=/mnt/hd2t/apps/${SVC}/data/db.sqlite3

# 1. Parar el servicio
docker compose -f /home/homelab/homelab/stacks/${SVC}/docker-compose.yml down

# 2. Mover el actual (no borrar)
mv "${DEST_LIVE}" "${DEST_LIVE}.broken-$(date +%F)"

# 3. Extraer el dump SQLite del archive
cd /home/homelab/homelab/stacks/borgmatic
docker compose -f docker-compose.yml -f restore.compose.yml run --rm borgmatic \
  borg extract \
    "/mnt/borg-repo::${ARCHIVE}" \
    "borgmatic/sqlite_databases/${SVC}/${SVC}.sqlite3"
# Cae en /mnt/exports/borgmatic/sqlite_databases/${SVC}/${SVC}.sqlite3

EXTRACTED=/mnt/hd2t/backups/exports/borgmatic/sqlite_databases/${SVC}/${SVC}.sqlite3

# 4. Validar
sqlite3 "${EXTRACTED}" "PRAGMA integrity_check;"

# 5. Promover
cp "${EXTRACTED}" "${DEST_LIVE}"
chown homelab:homelab "${DEST_LIVE}"
chmod 0640 "${DEST_LIVE}"

# 6. Levantar y smoke test
docker compose -f /home/homelab/homelab/stacks/${SVC}/docker-compose.yml up -d
```

> **Trampa con WAL fantasma**: si el directorio `data/` aún contiene `db.sqlite3-wal` o `db.sqlite3-shm` del fichero corrupto, SQLite los puede interpretar como pertenecientes al nuevo `.sqlite3` y corromper el restore. Borrarlos antes de levantar el servicio:
> ```bash
> rm -f /mnt/hd2t/apps/${SVC}/data/db.sqlite3-wal /mnt/hd2t/apps/${SVC}/data/db.sqlite3-shm
> ```

---

### Redis (Nextcloud-Redis, Authelia-Redis)

**No se respalda.** `01-estrategia-backup.md` cierra esta decisión: Redis del homelab es caché o sesiones; la fuente de verdad está en la BBDD primaria del servicio. El AOF y RDB están **excluidos** del repo Borg.

Procedimiento operativo si Redis pierde su estado:

```bash
# 1. Comprobar que el directorio Redis está realmente perdido
ls -la /mnt/hd2t/apps/nextcloud/redis/

# 2. Reiniciar Redis vacío. Nextcloud reconstruye locks y file cache desde Postgres
docker compose -f stacks/nextcloud/docker-compose.yml restart nextcloud-redis nextcloud

# 3. (Authelia) Las sesiones se invalidan; los usuarios re-loguean
#    Esto NO requiere acción del operador. Es by design.
```

> **Cuándo sí respaldar Redis**: si en algún momento Redis se usa como **storage primario** (e.g. una cola Bull en Node-RED con jobs no idempotentes, o RedisStack con datos JSON canónicos), revisar la decisión y mover ese servicio a `homelab.backup=true` con configuración de AOF persistente respaldada.

---

### MinIO (buckets opt-in)

Por defecto los buckets MinIO **no** se respaldan (T3 selectivo). El operador opta-in editando la lista `BUCKETS=()` del hook `before-backup.sh` documentado en `02-borgmatic.md`. Para operaciones manuales:

#### Backup ad-hoc de un bucket

```bash
BUCKET=app-snapshots
DEST=/mnt/hd2t/backups/exports/minio-${BUCKET}-$(date +%F-%H%M)/
mkdir -p "${DEST}"

# Usar el alias 'minio' ya configurado en secrets/mcadmin.json (Fase 6)
mc --config-dir /home/homelab/homelab/secrets mirror \
  --quiet --overwrite \
  "minio/${BUCKET}" "${DEST}"

# Validación: comparar object count y tamaño total
mc --config-dir /home/homelab/homelab/secrets du "minio/${BUCKET}"
du -sh "${DEST}"
```

#### Restore de un bucket

```bash
BUCKET=app-snapshots
SOURCE=/mnt/hd2t/backups/exports/minio-${BUCKET}-2026-04-28-0345/

# --remove sincroniza también los borrados; quitar si solo se quiere restaurar
# objetos sin afectar a los nuevos creados desde el backup
mc --config-dir /home/homelab/homelab/secrets mirror \
  --overwrite --remove \
  "${SOURCE}" "minio/${BUCKET}"

# Validar
mc --config-dir /home/homelab/homelab/secrets ls --recursive "minio/${BUCKET}" | wc -l
```

> **Sobre metadata S3**: `mc mirror` preserva ETags y headers personalizados. Para versiones (si está activado en el bucket) la copia es la **última versión** de cada objeto. Si se necesita el histórico completo, `mc mirror --preserve` es insuficiente; habría que iterar las versiones manualmente. No es el caso del homelab hoy.

---

## Volúmenes nominales: la excepción

El homelab por convención usa **bind mounts** (regla de `02-estructura-compose.md`); todos los datos viven en `/mnt/hd2t/apps/<svc>/`. Si un servicio futuro **fuerza** un volumen nominal (named volume) que no admite bind, el procedimiento es:

```bash
VOLUME=ejemplo_data
DEST=/mnt/hd2t/backups/exports/volume-${VOLUME}-$(date +%F).tar.gz

# Backup: tar del volumen vía un contenedor scratch
docker run --rm \
  -v "${VOLUME}:/source:ro" \
  -v "/mnt/hd2t/backups/exports:/dest" \
  alpine \
  tar czf "/dest/$(basename "${DEST}")" -C /source .

# Restore: untar dentro de un volumen nuevo (o vacío)
docker volume create "${VOLUME}"
docker run --rm \
  -v "${VOLUME}:/dest" \
  -v "/mnt/hd2t/backups/exports:/source:ro" \
  alpine \
  tar xzf "/source/$(basename "${DEST}")" -C /dest
```

Y se documenta en `02-borgmatic.md` añadiendo el path equivalente al `source_directories` (o un hook que materialice el tar.gz antes del create). Hoy **no aplica a ningún servicio**.

---

## Almacenamiento

Rutas y propósito durante operaciones de restore. Ninguna se crea aquí; todas existen desde Fase 1 / 7.

| Ruta host | Propósito durante el restore | Permisos |
|---|---|---|
| `/mnt/hd2t/backups/borg/` | Origen primario para restores. **Solo lectura** durante un restore (no se modifica). | `0700 homelab:homelab` |
| `/mnt/hd2t/backups/exports/` | Destino de restauraciones puntuales y drills. RW. Se **vacía manualmente** tras cada drill. | `0750 homelab:homelab` |
| `/mnt/hd2t/backups/exports/restore-drill-YYYYMMDD/` | Scratch dir efímero por drill. Se borra al finalizar. | hereda |
| `/mnt/hd2t/backups/exports/<svc>-pre-upgrade-<TS>.dump` | Dumps ad-hoc. Conservar mientras el upgrade esté "en período de garantía" (típicamente 1–2 semanas) y borrar después. | hereda |
| `/mnt/hd2t/backups/dumps/` | Área efímera usada **solo durante** el run de Borgmatic. No tocar manualmente. | `0700 homelab:homelab` |
| `/mnt/hd2t/apps/<svc>/` | Destino final del restore (cuando se promueve). RW. | varía por servicio |
| `/home/homelab/homelab/BACKUPS_LOG.md` | Bitácora versionada en git con fecha, archive usado, motivo, tiempos. | `0644` |
| `/home/homelab/homelab/scripts/restore-shell.sh` | Atajo opcional para abrir el contenedor borgmatic en modo interactivo. **Versionado en git.** | `0755` |

### Higiene de `exports/`

Un `exports/` que crece sin control consume `hd2t` y desorienta al operador siguiente. Política simple:

- Restauraciones puntuales: el extraído se promueve a `apps/` y se **borra** el rastro en `exports/` tras smoke test. Solo el `.broken-<fecha>` original puede sobrevivir hasta confirmar OK.
- Restore drills: `rm -rf` al finalizar. La memoria del drill vive en `BACKUPS_LOG.md`.
- Dumps ad-hoc pre-upgrade: borrarlos cuando el operador está seguro de que el upgrade fue estable (típicamente 1–2 semanas tras el upgrade).
- Cron de higiene opcional: `find /mnt/hd2t/backups/exports/ -maxdepth 1 -type d -mtime +30 -name 'restore-*' -exec rm -rf {} \;` semanal.

---

## Backup

Este documento es una **referencia operativa**. Su propio backup:

| Artefacto | Estrategia |
|---|---|
| `docs/07-backups/03-backup-docker-volumes.md` | Versionado en git. Cualquier mejora del procedimiento queda trazada. |
| `BACKUPS_LOG.md` | Versionado en git. Es la bitácora de drills y restores reales; cada entrada es un dato histórico sobre RTO efectivo. |
| `scripts/restore-shell.sh` y `stacks/borgmatic/restore.compose.yml` | Versionados en git. No contienen secretos. |

> El **valor de este documento se mide** por la velocidad con la que el operador, a las 3 AM y bajo presión, encuentra el comando exacto que necesita. Si una sección es ambigua, se reescribe; si un paso ha cambiado en producción, se actualiza inmediatamente. Una documentación de restore desactualizada es peor que no tener ninguna: induce errores con confianza falsa.

---

## Verificación

Antes de declarar la Fase 7 cerrada, ejecutar al menos **un drill completo** end-to-end y dejar la entrada en `BACKUPS_LOG.md`. La fase no se da por completa hasta que ese drill pasa.

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| El override de restore parsea | `cd stacks/borgmatic && docker compose -f docker-compose.yml -f restore.compose.yml config >/dev/null` | Sin errores. |
| Hay archives listables | `cd stacks/borgmatic && docker compose run --rm borgmatic borg list /mnt/borg-repo` | Al menos 1 archive presente, fechado en las últimas 24 h. |
| Dumps SQL presentes en el archive | `... borg list /mnt/borg-repo::<archive> \| grep borgmatic/postgresql_databases` | Al menos `nextcloud-db/nextcloud` listado. |
| Drill Postgres scratch funciona | Ejecutar el "Restore drill — Postgres en contenedor scratch" completo | `count(*)` razonable, contenedor scratch tearable. |
| Drill SQLite restore puntual ensayado | Ejecutar restore puntual de Authelia en *staging* (pararlo, restaurar, levantar) | Login funciona post-restore. |
| `BACKUPS_LOG.md` con entrada del drill | `git log --oneline BACKUPS_LOG.md` | Commit de la entrada presente. |
| `exports/` limpio post-drill | `ls /mnt/hd2t/backups/exports/` | Vacío o solo con dumps ad-hoc justificados. |
| Permisos `exports/` correctos | `stat -c '%a %U:%G' /mnt/hd2t/backups/exports` | `750 homelab:homelab` |

Cumplido el último punto, la Fase 7 (backups) queda **operativamente cerrada**: estrategia decidida (`01`), automatismo desplegado (`02`), procedimientos manuales documentados y probados (`03`).

---

## Decisiones que **no** se toman en este documento

- **Configuración de los hooks Borgmatic**: ya cerrada en `02-borgmatic.md`. Aquí solo se consume el output (los dumps que produjo Borgmatic).
- **Política de retención GFS y RPO/RTO objetivo**: cerrada en `01-estrategia-backup.md`. Aquí solo se mide RTO real durante drills.
- **Cifrado offsite y custodia de claves**: cerrada en `01-estrategia-backup.md`. Este documento asume que las claves están donde deben estar.
- **Reglas de alerta Prometheus para fallos de backup**: definidas en `02-borgmatic.md` y `05-monitorizacion/01-prometheus.md`.
- **Integración con Vaultwarden** como gestor de passphrases del homelab: descartada explícitamente en `01-estrategia-backup.md` (autorreferencial).
- **Procedimientos para servicios todavía no desplegados** (Bookstack, Paperless, Mealie, Linkding, FreshRSS, Calibre-Web, Stash, Vaultwarden): se documentarán en sus propias páginas de servicio (Fases 8+) referenciando los patrones genéricos de este documento.

---

## Referencias

- [Documento anterior: `docs/07-backups/02-borgmatic.md`](./02-borgmatic.md)
- [Documento anterior: `docs/07-backups/01-estrategia-backup.md`](./01-estrategia-backup.md)
- [Documento relacionado: `docs/01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)
- [Documento relacionado: `docs/02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)
- [Documento relacionado: `docs/06-almacenamiento/04-minio.md`](../06-almacenamiento/04-minio.md)
- [PostgreSQL — `pg_dump` y `pg_restore`](https://www.postgresql.org/docs/16/backup-dump.html)
- [PostgreSQL — `--format=custom` y restore selectivo](https://www.postgresql.org/docs/16/app-pgrestore.html)
- [MariaDB — `mysqldump` con `--single-transaction`](https://mariadb.com/kb/en/mariadb-dumpmysqldump/)
- [SQLite — Backup API y `.backup` command](https://www.sqlite.org/backup.html)
- [SQLite — `PRAGMA integrity_check` / `foreign_key_check`](https://www.sqlite.org/pragma.html#pragma_integrity_check)
- [Borg — `borg extract` y restauración selectiva](https://borgbackup.readthedocs.io/en/stable/usage/extract.html)
- [Borgmatic — Restore de bases de datos](https://torsion.org/borgmatic/docs/how-to/restore-a-database/)
- [rclone — `copy` y `sync` para pull desde offsite](https://rclone.org/commands/rclone_copy/)
- [MinIO `mc` — `mirror` para backup/restore de buckets](https://min.io/docs/minio/linux/reference/minio-mc/mc-mirror.html)
- [Docker — Backup/restore de volúmenes nominales](https://docs.docker.com/engine/storage/volumes/#back-up-restore-or-migrate-data-volumes)
