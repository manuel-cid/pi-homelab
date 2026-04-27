# Backup y restore de volúmenes Docker y bases de datos

## Descripción

Procedimientos **por servicio** para hacer copia y restauración de los volúmenes Docker del homelab y, cuando aplica, de las **bases de datos** que viven dentro de un contenedor (PostgreSQL, MariaDB, SQLite, Redis). Es el tercer y último documento de la **Fase 7 — Copias de Seguridad**:

- `docs/07-backups/01-estrategia-backup.md` fija **qué** se respalda, dónde y con qué retención (la regla 3-2-1 aplicada al hardware del homelab, la clasificación A/B/C/D/E, la cadencia `daily 03:30 / weekly / monthly`, la custodia de la passphrase).
- `docs/07-backups/02-borgmatic.md` despliega **el motor** (Borg + Borgmatic) que materializa esa estrategia: dos repos cifrados (local + offsite), `systemd timers`, `before_backup` que llama a `dump-databases.sh`, `after_backup` con métricas y notificaciones.
- **Este documento** contiene **el contenido** del `dump-databases.sh` y los procedimientos de restauración: qué comando exacto se ejecuta para cada servicio con BD, con qué privilegios, cómo se garantiza un dump consistente, y cómo se rebobina cada servicio desde un archive Borg cuando algo se rompe.

> **Alcance**: este doc no instala nada por sí mismo. Su entregable es **el script `~/homelab/backups/borgmatic/hooks/dump-databases.sh` con todos los bloques de servicio activos**, más una colección de _runbooks_ de restauración que se invocan desde `docs/13-operaciones/02-disaster-recovery.md` y desde la sección **Backup → restauración** de cada doc de servicio. Cada doc de servicio futuro (Vaultwarden, Bookstack, Paperless, Home Assistant, …) **descomentará su bloque** del hook al desplegarse y enlazará desde su sección **Backup** al apartado correspondiente de aquí.

> **Recordatorio del contrato con la estrategia**:
> - Los dumps van a **`/mnt/hd2t/backups/dumps/`** (`0700 root:root`) con nombre `<servicio>-YYYY-MM-DD.sql.gz`.
> - Borgmatic incluye ese directorio como _source_ (`docs/07-backups/02-borgmatic.md` → `source_directories`).
> - El `after_backup` borra dumps con `mtime > 7d` para no acumular: el repo Borg ya conserva el histórico vía retención GFS.
> - Los volúmenes "de ficheros" (config files, uploads, certificados) **no necesitan dump**: Borg los lee directamente del filesystem y deduplica.
> - Las bases de datos **nunca** se respaldan copiando el datadir: ver **Decisiones de diseño → Por qué dump lógico**.

> **Recordatorio del reparto de discos** (definido en `docs/00-hardware/03-preparacion-discos.md` y `docs/01-sistema/04-estructura-directorios.md`): los servicios viven en `/mnt/hd2t/services/<servicio>/`, los dumps en `/mnt/hd2t/backups/dumps/`, los repos Borg en `/mnt/hd2t/backups/borg/`. Un mismo disco físico para "datos vivos" y "copia local" — la copia offsite es la que cumple el 3-2-1 (`docs/07-backups/01-estrategia-backup.md`).

---

## Requisitos previos

- `docs/07-backups/01-estrategia-backup.md` y `docs/07-backups/02-borgmatic.md` completados. Existen `/etc/borgmatic.d/{config.yaml,secrets.env}` y los hooks `/etc/borgmatic.d/hooks/{dump-databases.sh,notify.sh,prometheus-textfile.sh}` ya enlazados (con `dump-databases.sh` aún en su forma de **esqueleto**: cada bloque de servicio comentado).

  Verificar:

  ```bash
  sudo ls -l /etc/borgmatic.d/hooks/
  # -rwxr-xr-x 1 root root ... dump-databases.sh
  # -rwxr-xr-x 1 root root ... notify.sh
  # -rwxr-xr-x 1 root root ... prometheus-textfile.sh

  sudo grep -c '^# ' /etc/borgmatic.d/hooks/dump-databases.sh
  # número de líneas comentadas — bloques de servicio aún inactivos
  ```

- `docs/02-docker/02-estructura-compose.md` completado: existe `~/homelab/<stack>/.env` por cada stack desplegado, con `MYSQL_ROOT_PASSWORD`, `POSTGRES_PASSWORD`, etc. Los hooks de dump leen estas variables vía `docker exec -e VAR=...`, no las copian a `secrets.env`.

  Verificar para los servicios ya desplegados:

  ```bash
  ls -la ~/homelab/almacen/.env
  # -rw------- 1 homelab homelab ... .env  (modo 0600)
  ```

- `docs/01-sistema/04-estructura-directorios.md` completado: la rama `/mnt/hd2t/backups/dumps/` existe con `0700 root:root`. Esencial — los dumps contienen credenciales hash y datos personales y deben ser **ilegibles** para cualquier usuario que no sea root.

  ```bash
  sudo stat -c '%a %U:%G' /mnt/hd2t/backups/dumps
  # 700 root:root
  ```

- Cada servicio que vaya a respaldarse está **desplegado y vivo**. Los bloques del hook hacen `docker ps --format '{{.Names}}' | grep -q '^<contenedor>$'` antes de intentar el dump: si el servicio está parado por mantenimiento, el bloque se salta sin error y la línea aparece en el log con `[dump] <svc>: skipped (container not running)`.

- `docker` y `docker compose` accesibles desde `root` sin sudo (post-install paso de `docs/02-docker/01-instalacion-docker.md`). El _systemd unit_ corre como `root` directamente; el grupo `docker` no es relevante en este contexto.

- Si el servicio usa **PostgreSQL ≥ 16**, asegurarse de que se invoca el `pg_dump` **del contenedor de la BD** (`docker exec <db> pg_dump ...`), no el del host. Razón: `pg_dump` no es compatible hacia atrás — `pg_dump 15` no respalda correctamente un servidor `16`. Detalle en **Decisiones de diseño → `docker exec` vs binarios del host**.

---

## Decisiones de diseño

### Por qué dump lógico y no copia raw del datadir

Para un volumen tipo "ficheros" (uploads de Nextcloud, certificados de Caddy, configuración de Home Assistant) Borg lee del filesystem y deduplica perfectamente. Para un volumen tipo "base de datos" (`/var/lib/mysql`, `/var/lib/postgresql/data`), copiar los ficheros mientras el servicio escribe **garantiza** un repo incoherente:

- En **Postgres**, el WAL (`pg_wal/`) está fuera de sincronía con los _heap files_ a menos que se haga un _basebackup_ (`pg_basebackup`) o se pare el servidor. Una copia "fría" exigiría parar el contenedor varios minutos al día — operacionalmente inaceptable.
- En **MariaDB/MySQL**, los `.ibd` de InnoDB y el _redo log_ (`ib_logfile0`) sólo son consistentes entre sí en un _checkpoint_; copia caliente = corrupción silenciosa al restaurar.
- En **SQLite**, una copia mientras hay un `BEGIN TRANSACTION` activo deja el `.db` con páginas a medio escribir o con un `-wal` no conmutado.

La estrategia uniforme del homelab es **dump lógico** invocado desde un _hook_ Borgmatic `before_backup`:

| Motor      | Comando del homelab                                                                                              | Propiedad clave                                                                                |
|------------|------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------|
| PostgreSQL | `docker exec <db> pg_dump --clean --if-exists --no-owner --no-privileges --quote-all-identifiers <database>`     | Texto SQL plano, transacción serializada, orden estable de tablas → deduplicación efectiva en Borg. |
| MariaDB    | `docker exec <db> mariadb-dump --single-transaction --skip-lock-tables --routines --triggers --events <database>` | `--single-transaction` toma un snapshot consistente sin bloquear escritores (sólo InnoDB).      |
| SQLite     | `docker exec <svc> sqlite3 /path/to.db ".backup /path/to.db.snap"` y luego `gzip`                                 | `.backup` es la API oficial de SQLite para copia consistente _online_; respeta WAL/journal.    |
| Redis      | _No se respalda_ (cache regenerable) o `docker exec <redis> redis-cli SAVE` si el operador necesita persistencia. | `SAVE` es _blocking_; usar `BGSAVE` para no bloquear, aceptando un dump "casi consistente".    |

El _hook_ canaliza la salida por `gzip` antes de tocar disco, así nunca aparece un fichero `.sql` (texto plano con credenciales) en `/mnt/hd2t/backups/dumps/`.

> **Sobre `--single-transaction` en MariaDB**: válido sólo para tablas InnoDB (todas las del homelab). Si en el futuro alguien añade una tabla MyISAM, el dump perderá consistencia silenciosamente. Hoy no aplica; documentado para `Troubleshooting`.

> **Sobre `pg_basebackup`**: alternativa a `pg_dump` que produce un backup _físico_ (apto para PITR con WAL archiving). Más complejo, requiere `wal_level=replica` y archivado continuo. **Fuera del alcance**: el RPO de 24 h del homelab no justifica PITR. `pg_dump` lógico es suficiente y portátil entre versiones (con la salvedad de que el cliente debe ser ≥ servidor).

### `docker exec <db>` vs binarios del host

| Camino                                  | Veredicto                                                                                                                                                                                                  |
|-----------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **`docker exec <contenedor> <cmd>` ✅** | El cliente y el servidor comparten **exactamente** la misma versión. Si Watchtower (`docs/02-docker/04-watchtower.md`) actualiza la imagen de Postgres a 17, el `pg_dump` del contenedor también se actualiza. **Elección del homelab**. |
| `pg_dump` / `mariadb-dump` del host (`apt install postgresql-client mariadb-client`) | El host queda en la versión que empaqueta Debian (Postgres 15 en Bookworm, MariaDB 10.11). Cualquier _bump_ del lado servidor mayor que el del cliente produce dumps **silenciosamente incompletos** o errores explícitos (`pg_dump: server version: 16; pg_dump version: 15`). Operacionalmente frágil. |

Coste del `docker exec`: una llamada extra al daemon de Docker por dump. Aceptable — el cuello de botella del backup nunca es el _spawn_ del contenedor sino la deduplicación + transferencia offsite.

> **Implicación**: Borgmatic corre como `root` y `root` está en el grupo `docker` (o accede al socket `/var/run/docker.sock` por DAC). Esto es **deliberado**: el motor de backup tiene que poder _exec_ contra cualquier contenedor para invocar el cliente correcto. La regla de seguridad correspondiente — "nadie más que `root` accede a `/var/run/docker.sock`" — está cubierta en `docs/02-docker/01-instalacion-docker.md`.

### Cómo se pasan las credenciales al `docker exec`

Las contraseñas de BD viven en `~/homelab/<stack>/.env` (mode `0600 homelab:homelab`). El _hook_ las **no copia** a `secrets.env`; las lee directamente al ejecutarse:

```bash
NC_ENV=/home/homelab/homelab/almacen/.env
[ -r "$NC_ENV" ] || { echo "[dump] nextcloud: .env no legible"; return 0; }
# shellcheck disable=SC1090
. "$NC_ENV"
docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" -i nextcloud-db \
  mariadb-dump --single-transaction --skip-lock-tables --routines --triggers --events \
  -u "$MYSQL_USER" nextcloud | gzip > "$OUT.tmp"
```

Tres puntos importantes:

1. **`MYSQL_PWD` por variable de entorno**, no `-p` en la línea de comandos. `-p<pass>` filtra la contraseña en `ps auxf`; `MYSQL_PWD=...` no.
2. **`docker exec -e MYSQL_PWD=...`**: la variable se inyecta al proceso `mariadb-dump` dentro del contenedor, no se queda en el entorno del host fuera del `docker exec`.
3. **El hook es `root`-only y `0700`**: nadie sin `sudo` puede leer el script. El `.env` del usuario `homelab` también está en `0600`. La cadena de custodia se mantiene.

> **Por qué no `--defaults-extra-file`**: requeriría escribir un fichero temporal `.my.cnf` con la contraseña; complica el limpiado en caso de error y deja una ventana donde el fichero existe en `/tmp`. La variable de entorno es más limpia.

### Quiesce vs hot dump

La política por defecto es **hot dump**: ningún servicio se para durante el backup. Los motores de BD soportan dump consistente _online_ (`pg_dump` con _serializable snapshot_, `mariadb-dump --single-transaction`, SQLite `.backup`). El servicio queda operativo durante toda la corrida.

Excepciones que sí requieren parar el contenedor:

| Servicio   | Por qué                                                                                                       | Cómo                                                                                                |
|------------|---------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------|
| Pi-hole    | `pihole-FTL.db` es SQLite escrito constantemente por el resolver. `.backup` funciona, pero el _hook_ es más sencillo si se pausa FTL. | `docker exec pihole pihole-FTL --terminate-once && ... && docker exec pihole service pihole-FTL start` |
| Vaultwarden | _Opcional_. SQLite con `.backup` basta. Si el operador prefiere parar el contenedor (downtime ~10 s) puede hacerlo. | `docker stop vaultwarden && cp ... && docker start vaultwarden` |
| Mosquitto  | _Si_ se decide respaldar `mosquitto.db` (retained messages). Mosquitto no tiene `.backup` API; parar es la opción limpia. | `docker stop mosquitto && cp ... && docker start mosquitto` |

Para el resto, `single-transaction` o `.backup` cubren el caso. El `dump-databases.sh` documenta cada decisión bloque a bloque.

### Convención de nombres y compresión

| Pieza                       | Convención                                                                                          |
|-----------------------------|-----------------------------------------------------------------------------------------------------|
| Nombre del fichero          | `<servicio>-<YYYY-MM-DD>.sql.gz` (un dump por servicio por día).                                    |
| Subcarpeta                  | _ninguna_ — todos los dumps en `/mnt/hd2t/backups/dumps/` raíz. Inventario plano = `borg list` legible. |
| Compresión                  | `gzip` por defecto (rápido, deduplicable por Borg). `pigz` si se quiere paralelizar — opcional.     |
| Permisos                    | `0600 root:root` siempre. El hook hace `chmod 0600` tras escribir.                                  |
| Atomicidad                  | Escribir a `<dump>.tmp`, `mv` al nombre final sólo si `pg_dump`/`mariadb-dump` retornó 0.          |
| Retención de dumps          | `find -mtime +7 -delete` en `after_backup`. El histórico vive en el repo Borg con retención GFS.   |

> **Por qué un dump por día y no por hora**: la cadencia del backup es diaria (`docs/07-backups/01-estrategia-backup.md`). Un dump por hora ocuparía 24 × más espacio sin que Borgmatic capture los archives intermedios. Si en el futuro algún servicio justifica RPO < 24 h, se documentará en su doc concreto y se añadirá un timer dedicado — **no** se infla la global.

### Determinismo del dump (importante para Borg)

Borg deduplica con _rolling hash_ sobre _chunks_ del fichero. Un dump SQL textual cuya **sola diferencia entre días** sea "una fila nueva al final" produce un delta diminuto y ahorra muchísimo espacio en el offsite. Pero si el dump es **no determinista** (orden de tablas distinto cada vez, timestamps embebidos en comentarios, índices auto-numerados), Borg ve "todo el fichero ha cambiado" cada noche y el ahorro desaparece.

Reglas para mantener el determinismo:

| Motor      | Flag obligatorio                          | Por qué                                                                                       |
|------------|-------------------------------------------|-----------------------------------------------------------------------------------------------|
| PostgreSQL | `--no-owner --no-privileges --quote-all-identifiers` + sin `--data-only`/`--schema-only` separados | Sin `--no-owner`, embeben el OID interno que cambia entre _re-creaciones_; con todo en un único dump, el orden de tablas es estable (alfabético). |
| MariaDB    | `--skip-comments` (opcional, evita la cabecera con timestamp) | El dump comienza con `-- MariaDB dump 10.19  Distrib 10.11.7-MariaDB, for Linux ...\n-- Host: ... Database: ... -- Server version ...\n-- ... -- ... (timestamp)` — los timestamps cambian cada noche y "ensucian" el primer chunk de Borg. `--skip-comments` los suprime. |
| SQLite     | `.backup` produce un binario _stable bytes_ si no hubo escritura entre _checkpoint_ y backup | _OK_ por construcción.                                                                        |

> **Verificación rápida**: tras una semana de backups, `borg info --json $REPO | jq '.cache.stats'` debe mostrar `unique_csize` (tamaño dedup) creciendo a un ritmo mucho menor que `original_size`. Si crecen casi igual → algún dump no es determinista. Diagnóstico en **Troubleshooting**.

### Restauración: matriz de decisiones

| Escenario                                           | Granularidad                          | Tiempo objetivo |
|-----------------------------------------------------|----------------------------------------|-----------------|
| _"He borrado un fichero por error"_ (foto en Nextcloud, doc en Paperless) | un fichero o un árbol pequeño         | < 5 min         |
| _"La base de datos de un servicio se ha corrompido"_ | un servicio completo (volúmenes + BD) | < 30 min        |
| _"He actualizado un servicio y ha roto sus datos"_  | un servicio + rollback de imagen Docker | < 30 min      |
| _"hd2t entero ha fallado"_                          | todos los servicios desde repo offsite | horas           |
| _"La Pi se ha incendiado"_ (DR completo)            | OS + Docker + servicios desde offsite | medio día       |

Los cuatro primeros se cubren aquí. El último — DR completo — se ejecuta desde `docs/13-operaciones/02-disaster-recovery.md` reutilizando los runbooks de aquí.

---

## Patrones por motor de bases de datos

Cada bloque del `dump-databases.sh` instancia uno de estos patrones. Documentados aparte para evitar repetición y para que el doc de un servicio pueda apuntar al patrón con un enlace en lugar de copiar comandos.

### Patrón P — PostgreSQL

```bash
# Patrón P — dump consistente PostgreSQL desde el contenedor de la BD
# Pre-condición: contenedor <db_container> vivo y con DB <database> creada.
# Variables esperadas en el .env del stack:
#   POSTGRES_USER      — usuario DBA
#   POSTGRES_PASSWORD  — su contraseña
#   POSTGRES_DB        — nombre de la base de datos
dump_postgres() {
  local svc=$1 container=$2 envfile=$3
  [ -r "$envfile" ] || { echo "[dump] $svc: env no legible: $envfile"; return 0; }
  # shellcheck disable=SC1090
  . "$envfile"
  docker ps --format '{{.Names}}' | grep -q "^${container}$" || {
    echo "[dump] $svc: container ${container} no corre; skip"; return 0; }
  local out="$DUMPS/${svc}-${DATE}.sql.gz"
  if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" -i "$container" \
       pg_dump \
         --clean --if-exists \
         --no-owner --no-privileges \
         --quote-all-identifiers \
         -U "$POSTGRES_USER" \
         "$POSTGRES_DB" \
       | gzip > "$out.tmp"; then
    mv "$out.tmp" "$out" && chmod 0600 "$out"
    echo "[dump] $svc: OK -> $out ($(stat -c%s "$out") bytes)"
  else
    rm -f "$out.tmp"
    echo "[dump] $svc: FAIL"
    return 1
  fi
}
```

> **Por qué `pg_dump` y no `pg_dumpall`**: cada servicio tiene una **única** base de datos lógica en su contenedor Postgres. `pg_dumpall` añade los _roles_ globales — útil sólo si el contenedor sirviese a varios servicios (no es nuestro caso: un Postgres por servicio, principio de aislamiento de `docs/02-docker/02-estructura-compose.md`).

> **Si el contenedor de Postgres tiene varias BDs** (caso futuro hipotético): añadir `pg_dumpall --globals-only` en un dump aparte para los roles, y `pg_dump <db>` por cada BD. No aplica hoy.

### Patrón M — MariaDB / MySQL

```bash
# Patrón M — dump consistente MariaDB.
# Variables esperadas en el .env del stack:
#   MYSQL_USER, MYSQL_PASSWORD, MYSQL_DATABASE
dump_mariadb() {
  local svc=$1 container=$2 envfile=$3
  [ -r "$envfile" ] || { echo "[dump] $svc: env no legible: $envfile"; return 0; }
  # shellcheck disable=SC1090
  . "$envfile"
  docker ps --format '{{.Names}}' | grep -q "^${container}$" || {
    echo "[dump] $svc: container ${container} no corre; skip"; return 0; }
  local out="$DUMPS/${svc}-${DATE}.sql.gz"
  if docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" -i "$container" \
       mariadb-dump \
         --single-transaction \
         --skip-lock-tables \
         --routines --triggers --events \
         --skip-comments \
         -u "$MYSQL_USER" \
         "$MYSQL_DATABASE" \
       | gzip > "$out.tmp"; then
    mv "$out.tmp" "$out" && chmod 0600 "$out"
    echo "[dump] $svc: OK -> $out ($(stat -c%s "$out") bytes)"
  else
    rm -f "$out.tmp"
    echo "[dump] $svc: FAIL"
    return 1
  fi
}
```

> **`mariadb-dump` y no `mysqldump`**: la imagen oficial `mariadb` envía ambos binarios — `mysqldump` está como _wrapper_ que delega en `mariadb-dump`. Usar el nombre nativo evita warnings de _deprecation_ en versiones recientes.

> **Por qué se omite `--master-data`**: es para crear esclavos de replicación, no aplica al homelab.

### Patrón S — SQLite

```bash
# Patrón S — copia consistente de un .db SQLite usando la API .backup.
# Necesita que dentro del contenedor exista 'sqlite3'. Si no, ver Patrón S-fría.
dump_sqlite() {
  local svc=$1 container=$2 db_path_in_container=$3
  docker ps --format '{{.Names}}' | grep -q "^${container}$" || {
    echo "[dump] $svc: container ${container} no corre; skip"; return 0; }
  local out="$DUMPS/${svc}-${DATE}.sql.gz"
  if docker exec -i "$container" sh -c "
       sqlite3 '${db_path_in_container}' '.backup /tmp/${svc}.backup' &&
       gzip -c /tmp/${svc}.backup &&
       rm -f /tmp/${svc}.backup
     " > "$out.tmp"; then
    mv "$out.tmp" "$out" && chmod 0600 "$out"
    echo "[dump] $svc: OK -> $out ($(stat -c%s "$out") bytes)"
  else
    rm -f "$out.tmp"
    echo "[dump] $svc: FAIL"
    return 1
  fi
}

# Patrón S-fría — si la imagen del servicio no incluye sqlite3, parar el contenedor,
# copiar el fichero del bind mount, y arrancarlo. Downtime ~10 s.
dump_sqlite_cold() {
  local svc=$1 container=$2 host_db_path=$3
  docker ps --format '{{.Names}}' | grep -q "^${container}$" || {
    echo "[dump] $svc: container ${container} no corre; skip"; return 0; }
  local out="$DUMPS/${svc}-${DATE}.sql.gz"
  docker stop "$container" >/dev/null
  if gzip -c "$host_db_path" > "$out.tmp"; then
    mv "$out.tmp" "$out" && chmod 0600 "$out"
    echo "[dump] $svc: OK (cold) -> $out"
  else
    rm -f "$out.tmp"; echo "[dump] $svc: FAIL"
  fi
  docker start "$container" >/dev/null
}
```

> **Por qué `.backup` y no copiar el `.db` raw**: si el servicio escribe entre el momento en que el hook abre el `.db` y el momento en que lo cierra, se obtiene un fichero con páginas inconsistentes (típico tras un fallo). `.backup` toma un _snapshot_ atómico usando la propia maquinaria de SQLite (`sqlite3_backup_init`/`step`/`finish`), respetando el WAL y el journal.

> **`/tmp` dentro del contenedor**: es siempre un `tmpfs` por defecto en Docker. No persiste, no genera basura. El `rm -f` final es por higiene.

### Patrón R — Redis (raro: en general no se respalda)

Redis se usa como **cache** (Authelia, Nextcloud). Su pérdida hace que la próxima petición regenere el dato con coste despreciable. No se respalda.

Si en el futuro se despliega un Redis con `appendonly yes` y datos no regenerables, el patrón es:

```bash
docker exec redis-container redis-cli BGSAVE >/dev/null
# Esperar a que el RDB termine
while docker exec redis-container redis-cli LASTSAVE | tail -1 \
        | xargs -I{} test {} -lt $(date +%s -d '60 seconds ago'); do
  sleep 1
done
# Copiar el dump.rdb del bind mount
gzip -c /mnt/hd2t/services/<svc>/redis/dump.rdb > "$DUMPS/<svc>-redis-${DATE}.rdb.gz"
```

> **`BGSAVE` vs `SAVE`**: `BGSAVE` es no bloqueante (fork del proceso); `SAVE` para todo Redis hasta terminar. En homelab `BGSAVE` siempre.

### Patrón F — Sólo ficheros

Para servicios cuyo "estado" es un árbol de configuración + datos (sin BD interna o con una BD que ya entra como fichero plano: SQLite del propio servicio respaldado vía Patrón S, ficheros YAML/JSON de Authelia, certificados de Caddy, configuración de Home Assistant, …) **no hay bloque en `dump-databases.sh`**: Borg los lee directamente vía `source_directories: /mnt/hd2t/services/...`.

Cada doc de servicio dejará en su sección **Backup** una nota explícita: _"Categoría F (filesystem-only): no requiere hook de dump"_.

---

## Hook canónico — `dump-databases.sh` completo

Versión "todo encendido" del esqueleto que dejó `docs/07-backups/02-borgmatic.md`. Cada doc de servicio activará **su** bloque (descomentando la llamada correspondiente) cuando se despliegue. Mientras tanto, los bloques se quedan comentados sin afectar al resto.

```bash
cat > ~/homelab/backups/borgmatic/hooks/dump-databases.sh <<'EOF'
#!/usr/bin/env bash
# /etc/borgmatic.d/hooks/dump-databases.sh
# Llamado por before_backup. Genera dumps en /mnt/hd2t/backups/dumps/.
# Convención: <servicio>-YYYY-MM-DD.sql.gz
#
# Cada bloque se activa al desplegar el servicio (ver doc del servicio).
# Política y fundamento: docs/07-backups/03-backup-docker-volumes.md.
#
# El script NUNCA falla el backup global: cada bloque falla "suave"
# (return en su función) y el script termina con exit 0 a menos que
# el operador haya descomentado el 'set -e' o redirigido errores.

set -uo pipefail

DUMPS=/mnt/hd2t/backups/dumps
DATE=$(date +%F)
HOMELAB=/home/homelab/homelab

mkdir -p "$DUMPS"
chmod 0700 "$DUMPS"

# -----------------------------------------------------------------------------
# Helpers — Patrones P, M, S, S-fría, R. Documentados en
# docs/07-backups/03-backup-docker-volumes.md.
# -----------------------------------------------------------------------------

dump_postgres() {
  local svc=$1 container=$2 envfile=$3
  [ -r "$envfile" ] || { echo "[dump] $svc: env no legible: $envfile"; return 0; }
  # shellcheck disable=SC1090
  . "$envfile"
  docker ps --format '{{.Names}}' | grep -q "^${container}$" || {
    echo "[dump] $svc: container ${container} no corre; skip"; return 0; }
  local out="$DUMPS/${svc}-${DATE}.sql.gz"
  if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" -i "$container" \
       pg_dump --clean --if-exists --no-owner --no-privileges \
               --quote-all-identifiers \
               -U "$POSTGRES_USER" "$POSTGRES_DB" \
       | gzip > "$out.tmp"; then
    mv "$out.tmp" "$out" && chmod 0600 "$out"
    echo "[dump] $svc: OK -> $out"
  else
    rm -f "$out.tmp"; echo "[dump] $svc: FAIL"; return 1
  fi
}

dump_mariadb() {
  local svc=$1 container=$2 envfile=$3 dbname=${4:-}
  [ -r "$envfile" ] || { echo "[dump] $svc: env no legible: $envfile"; return 0; }
  # shellcheck disable=SC1090
  . "$envfile"
  docker ps --format '{{.Names}}' | grep -q "^${container}$" || {
    echo "[dump] $svc: container ${container} no corre; skip"; return 0; }
  local out="$DUMPS/${svc}-${DATE}.sql.gz"
  : "${dbname:=$MYSQL_DATABASE}"
  if docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" -i "$container" \
       mariadb-dump --single-transaction --skip-lock-tables \
                    --routines --triggers --events --skip-comments \
                    -u "$MYSQL_USER" "$dbname" \
       | gzip > "$out.tmp"; then
    mv "$out.tmp" "$out" && chmod 0600 "$out"
    echo "[dump] $svc: OK -> $out"
  else
    rm -f "$out.tmp"; echo "[dump] $svc: FAIL"; return 1
  fi
}

dump_sqlite() {
  local svc=$1 container=$2 db_in=$3
  docker ps --format '{{.Names}}' | grep -q "^${container}$" || {
    echo "[dump] $svc: container ${container} no corre; skip"; return 0; }
  local out="$DUMPS/${svc}-${DATE}.sqlite.gz"
  if docker exec -i "$container" sh -c "
       sqlite3 '$db_in' '.backup /tmp/${svc}.backup' &&
       gzip -c /tmp/${svc}.backup &&
       rm -f /tmp/${svc}.backup
     " > "$out.tmp"; then
    mv "$out.tmp" "$out" && chmod 0600 "$out"
    echo "[dump] $svc: OK -> $out"
  else
    rm -f "$out.tmp"; echo "[dump] $svc: FAIL"; return 1
  fi
}

dump_sqlite_cold() {
  local svc=$1 container=$2 host_db=$3
  docker ps --format '{{.Names}}' | grep -q "^${container}$" || {
    echo "[dump] $svc: container ${container} no corre; skip"; return 0; }
  local out="$DUMPS/${svc}-${DATE}.sqlite.gz"
  docker stop "$container" >/dev/null
  if gzip -c "$host_db" > "$out.tmp"; then
    mv "$out.tmp" "$out" && chmod 0600 "$out"
    echo "[dump] $svc: OK (cold) -> $out"
  else
    rm -f "$out.tmp"; echo "[dump] $svc: FAIL"
  fi
  docker start "$container" >/dev/null
}

# -----------------------------------------------------------------------------
# Bloques por servicio — DESCOMENTAR el que aplique al desplegar el servicio.
# El orden no importa; los dumps son independientes.
# -----------------------------------------------------------------------------

# --- Pi-hole (SQLite, FTL pausado) — docs/03-red/02-pihole.md
# docker ps --format '{{.Names}}' | grep -q '^pihole$' && {
#   docker exec pihole pihole-FTL --terminate-once 2>/dev/null || true
#   for db in /etc/pihole/gravity.db /etc/pihole/pihole-FTL.db; do
#     dump_sqlite "pihole-$(basename "$db" .db)" pihole "$db"
#   done
#   docker exec pihole service pihole-FTL start 2>/dev/null || true
# }

# --- Authelia (config en ficheros — Categoría F, sin dump)
# Authelia no tiene BD del lado servidor (ver docs/04-seguridad/01-authelia.md).
# Sus YAML viven en /mnt/hd2t/services/authelia/config/ y entran como source_directory.
# No hace falta bloque de dump.

# --- Caddy (CA local en ficheros — Categoría F, sin dump)
# /mnt/hd2t/services/caddy/data/ contiene la CA y los certificados.
# Entra como source_directory.

# --- Grafana (SQLite por defecto) — docs/05-monitorizacion/02-grafana.md
# dump_sqlite grafana grafana /var/lib/grafana/grafana.db

# --- Uptime Kuma (SQLite) — docs/05-monitorizacion/05-uptime-kuma.md
# dump_sqlite uptime-kuma uptime-kuma /app/data/kuma.db

# --- Nextcloud (MariaDB + ficheros separados) — docs/06-almacenamiento/01-nextcloud.md
# dump_mariadb nextcloud nextcloud-db "$HOMELAB/almacen/.env" nextcloud
# El árbol /mnt/hd2t/services/nextcloud/data/ entra como source_directory aparte.

# --- MinIO (filesystem-only — Categoría F)
# /mnt/hd2t/services/minio/data/ entra como source_directory.
# La metadata interna de MinIO está en el propio bucket; no hay BD externa.

# --- Vaultwarden (SQLite con .backup) — docs/11-productividad/01-vaultwarden.md
# dump_sqlite vaultwarden vaultwarden /data/db.sqlite3

# --- Bookstack (MariaDB) — docs/11-productividad/02-bookstack.md
# dump_mariadb bookstack bookstack-db "$HOMELAB/productividad/.env" bookstack

# --- Linkding (SQLite por defecto) — docs/11-productividad/03-linkding.md
# dump_sqlite linkding linkding /etc/linkding/data/db.sqlite3

# --- Paperless-ngx (PostgreSQL + media/originals) — docs/11-productividad/04-paperless-ngx.md
# dump_postgres paperless paperless-db "$HOMELAB/productividad/.env"
# /mnt/hd2t/services/paperless/media/documents/originals/ entra como source_directory.

# --- Mealie (PostgreSQL o SQLite) — docs/11-productividad/05-mealie.md
# dump_postgres mealie mealie-db "$HOMELAB/productividad/.env"
# o, si quedó en SQLite por simplicidad:
# dump_sqlite mealie mealie /app/data/mealie.db

# --- FreshRSS (SQLite por defecto) — docs/11-productividad/07-freshrss.md
# dump_sqlite freshrss freshrss /var/www/FreshRSS/data/users/_default/db.sqlite

# --- Home Assistant (SQLite — recorder) — docs/08-domotica/01-home-assistant.md
# dump_sqlite home-assistant home-assistant /config/home-assistant_v2.db
# El árbol /mnt/hd2t/services/home-assistant/ entra como source_directory aparte.

# --- Mosquitto (filesystem; opcional) — docs/08-domotica/02-mosquitto.md
# /mnt/hd2t/services/mosquitto/{config,data}/ entra como source_directory.
# Si se quiere preservar retained messages crudos: dump_sqlite_cold no aplica
# (mosquitto.db no es SQLite). Parar el contenedor y copiar:
# docker stop mosquitto && \
#   gzip -c /mnt/hd2t/services/mosquitto/data/mosquitto.db \
#     > "$DUMPS/mosquitto-${DATE}.db.gz" && \
#   chmod 0600 "$DUMPS/mosquitto-${DATE}.db.gz" && \
#   docker start mosquitto

# --- Zigbee2MQTT (YAML + state.json — Categoría F) — docs/08-domotica/03-zigbee2mqtt.md
# /mnt/hd2t/services/zigbee2mqtt/ entra como source_directory.

# --- Node-RED (flows.json — Categoría F) — docs/08-domotica/04-node-red.md
# /mnt/hd2t/services/node-red/ entra como source_directory.

# --- Jellyfin (SQLite — config + library) — docs/09-multimedia/01-jellyfin.md
# La BD vive en /mnt/hd2t/services/jellyfin/config/data/jellyfin.db
# y se respalda con Patrón S si la imagen tiene sqlite3, o vía cold copy:
# dump_sqlite jellyfin jellyfin /config/data/jellyfin.db

# --- Navidrome (SQLite) — docs/09-multimedia/02-navidrome.md
# dump_sqlite navidrome navidrome /data/navidrome.db

# --- Audiobookshelf (SQLite) — docs/09-multimedia/03-audiobookshelf.md
# dump_sqlite audiobookshelf audiobookshelf /config/absdatabase.sqlite

# --- Calibre-Web (SQLite) — docs/09-multimedia/04-calibre-web.md
# dump_sqlite calibre-web calibre-web /books/metadata.db
# NB: metadata.db pertenece a Calibre, no al contenedor. Verificar en su doc.

# --- Stash (SQLite + metadata) — docs/09-multimedia/05-stash.md
# dump_sqlite stash stash /root/.stash/stash-go.sqlite
# El árbol /mnt/hd2t/services/stash/{config,metadata}/ entra como source_directory.

# --- *arr family (Sonarr/Radarr/Prowlarr — SQLite) — docs/10-descargas/0[3-2].md
# dump_sqlite sonarr   sonarr   /config/sonarr.db
# dump_sqlite radarr   radarr   /config/radarr.db
# dump_sqlite prowlarr prowlarr /config/prowlarr.db

# --- Transmission (settings.json + resume — Categoría F) — docs/10-descargas/01-transmission.md
# /mnt/hd2t/services/transmission/config/ entra como source_directory.

# --- Dashboards (config files — Categoría F)
# Homepage: /mnt/hd2t/services/homepage/config/
# Homarr  : /mnt/hd2t/services/homarr/configs/

exit 0
EOF
chmod 0755 ~/homelab/backups/borgmatic/hooks/dump-databases.sh
~/homelab/backups/borgmatic/install.sh
```

> **Política**: cuando un servicio se despliega, su doc termina con un commit que **descomenta** el bloque correspondiente arriba y vuelve a ejecutar `install.sh`. Si un bloque queda activado para un servicio que aún no existe (`docker ps` no encuentra el contenedor), `dump-databases.sh` lo registra como `skip` y sigue: el coste de un bloque "muerto" es despreciable.

---

## Inventario por servicio

Ficha por servicio: a qué categoría pertenece (`docs/07-backups/01-estrategia-backup.md`), qué patrón de dump usa, qué entra al repo Borg "como ficheros", y dónde está el _runbook_ de restauración. Sólo los servicios **con BD propia o con sutilezas de respaldo** tienen ficha; el resto cae en "filesystem-only" y basta con la entrada en `source_directories:` del `config.yaml`.

### Pi-hole

| Aspecto                       | Valor                                                                                            |
|-------------------------------|--------------------------------------------------------------------------------------------------|
| Categoría                     | A (configuración personal: listas, whitelist) + B (FTL DB: histórico de queries)                  |
| Contenedor                    | `pihole`                                                                                         |
| Bind mount                    | `/mnt/hd2t/services/pihole/etc-pihole/`, `/mnt/hd2t/services/pihole/etc-dnsmasq.d/`              |
| BD                            | SQLite — `gravity.db` (listas), `pihole-FTL.db` (queries)                                        |
| Patrón                        | S (online `.backup`) — con FTL pausado momentáneamente para evitar lecturas durante el snapshot   |
| Excluir                       | `gravity_old.db`, `dhcp.leases`                                                                  |
| Doc del servicio              | `docs/03-red/02-pihole.md`                                                                       |
| Restauración                  | Ver más abajo: **Restauración → Pi-hole**                                                        |

```bash
# Bloque del hook (descomentar en dump-databases.sh)
docker ps --format '{{.Names}}' | grep -q '^pihole$' && {
  docker exec pihole pihole-FTL --terminate-once 2>/dev/null || true
  for db in /etc/pihole/gravity.db /etc/pihole/pihole-FTL.db; do
    dump_sqlite "pihole-$(basename "$db" .db)" pihole "$db"
  done
  docker exec pihole service pihole-FTL start 2>/dev/null || true
}
```

> **Por qué pausar FTL aunque `.backup` sea online**: FTL escribe queries casi cada segundo. `.backup` funciona, pero produce un dump _muy poco_ deduplicable (cada noche cambia "todo el final" del fichero). Pausar 5 s reduce drásticamente el delta y evita que el repo offsite suba 50 MB de queries cada noche. La latencia para el usuario es nula: las consultas DNS pendientes encolan y se procesan al recuperar.

### Authelia

| Aspecto              | Valor                                                                                          |
|----------------------|------------------------------------------------------------------------------------------------|
| Categoría            | A (`users_database.yml` con hashes Argon2id, `configuration.yml`, `notifier.smtp.password`)    |
| Contenedor           | `authelia`                                                                                     |
| Bind mount           | `/mnt/hd2t/services/authelia/config/`                                                          |
| BD                   | _Ninguna_ — Authelia versión "file-based" (homelab) no usa BD; las sesiones viven en Redis (efímero) |
| Patrón               | F (filesystem-only)                                                                            |
| Doc del servicio     | `docs/04-seguridad/01-authelia.md`                                                             |
| Restauración         | Restaurar el árbol de `config/` a su sitio + reiniciar el contenedor                          |

> **Sobre Redis de Authelia**: tiene "estado" (sesiones autenticadas), pero perderlo solo obliga a que los usuarios vuelvan a iniciar sesión. **No** se respalda. El bind mount de Redis (si existe) entra en `exclude_patterns` del `config.yaml`.

### Caddy

| Aspecto              | Valor                                                                                          |
|----------------------|------------------------------------------------------------------------------------------------|
| Categoría            | A (CA local — perderla obliga a re-emitir certs en todos los clientes)                         |
| Contenedor           | `caddy`                                                                                        |
| Bind mount           | `/mnt/hd2t/services/caddy/{data,config}/`                                                      |
| BD                   | _Ninguna_                                                                                      |
| Patrón               | F                                                                                              |
| Excluir              | `data/caddy/locks/` (locks transitorios)                                                       |
| Doc del servicio     | `docs/03-red/04-caddy.md`                                                                      |
| Restauración         | Restaurar `data/` (incluye CA) → reiniciar Caddy → los clientes confían automáticamente        |

### Grafana

| Aspecto              | Valor                                                                                          |
|----------------------|------------------------------------------------------------------------------------------------|
| Categoría            | B (datasources, dashboards: regenerable, pero con horas de trabajo manual)                     |
| Contenedor           | `grafana`                                                                                      |
| Bind mount           | `/mnt/hd2t/services/grafana/data/`                                                             |
| BD                   | SQLite — `/var/lib/grafana/grafana.db` (default; el homelab no usa Postgres aquí)              |
| Patrón               | S (online `.backup`)                                                                           |
| Doc del servicio     | `docs/05-monitorizacion/02-grafana.md`                                                         |
| Restauración         | Restaurar `data/` completo → reiniciar Grafana                                                 |

### Uptime Kuma

| Aspecto              | Valor                                                                                          |
|----------------------|------------------------------------------------------------------------------------------------|
| Categoría            | B (monitores configurados, histórico)                                                          |
| Contenedor           | `uptime-kuma`                                                                                  |
| Bind mount           | `/mnt/hd2t/services/uptime-kuma/`                                                              |
| BD                   | SQLite — `/app/data/kuma.db`                                                                   |
| Patrón               | S                                                                                              |
| Doc del servicio     | `docs/05-monitorizacion/05-uptime-kuma.md`                                                     |

### Nextcloud

| Aspecto              | Valor                                                                                          |
|----------------------|------------------------------------------------------------------------------------------------|
| Categoría            | A (datos de usuario y BD)                                                                      |
| Contenedores         | `nextcloud-db` (MariaDB), `nextcloud` (app), `nextcloud-redis` (cache, no respaldar)           |
| Bind mount (datos)   | `/mnt/hd2t/services/nextcloud/data/` (uploads de usuarios)                                     |
| Bind mount (config)  | `/mnt/hd2t/services/nextcloud/{config,custom_apps}/`                                           |
| BD                   | MariaDB                                                                                        |
| Patrón               | M (`mariadb-dump --single-transaction`)                                                        |
| Excluir              | `data/<user>/cache/`, `data/appdata_*/preview/` (regenerable, ocupa)                           |
| Doc del servicio     | `docs/06-almacenamiento/01-nextcloud.md`                                                       |
| Restauración         | **Crítica — orden importa**: restaurar `data/` + `config/` desde Borg → arrancar `nextcloud-db` → importar dump SQL → arrancar `nextcloud` → `occ maintenance:repair`. Ver runbook abajo. |

### Vaultwarden

| Aspecto              | Valor                                                                                          |
|----------------------|------------------------------------------------------------------------------------------------|
| Categoría            | A — **el dato más crítico del homelab** (bóveda de contraseñas)                                 |
| Contenedor           | `vaultwarden`                                                                                  |
| Bind mount           | `/mnt/hd2t/services/vaultwarden/data/`                                                         |
| BD                   | SQLite — `/data/db.sqlite3`                                                                    |
| Patrón               | S (online `.backup`)                                                                           |
| Doc del servicio     | `docs/11-productividad/01-vaultwarden.md`                                                      |
| Drill                | **Mensual obligatorio** (`docs/07-backups/01-estrategia-backup.md` → Drills)                   |

> **Por qué Vaultwarden está en _todos_ los drills mensuales**: porque la passphrase de Borg vive (entre otros lugares) en una nota de Vaultwarden. Si el día del DR descubrimos que el dump de Vaultwarden está corrupto **y** la copia papel se ha extraviado, hemos perdido el repo offsite por imposibilidad de descifrarlo. Probar la restauración cada mes evita el _circular dependency_ silencioso.

### Bookstack

| Aspecto              | Valor                                                                                          |
|----------------------|------------------------------------------------------------------------------------------------|
| Categoría            | A (documentación del propio homelab)                                                           |
| Contenedores         | `bookstack`, `bookstack-db` (MariaDB)                                                          |
| BD                   | MariaDB                                                                                        |
| Patrón               | M                                                                                              |
| Bind mount (uploads) | `/mnt/hd2t/services/bookstack/uploads/`                                                        |
| Doc del servicio     | `docs/11-productividad/02-bookstack.md`                                                        |

### Paperless-ngx

| Aspecto              | Valor                                                                                          |
|----------------------|------------------------------------------------------------------------------------------------|
| Categoría            | A (BD + originales escaneados)                                                                 |
| Contenedores         | `paperless`, `paperless-db` (PostgreSQL), `paperless-redis` (no respaldar), `paperless-tika` (no respaldar) |
| BD                   | PostgreSQL                                                                                     |
| Patrón               | P                                                                                              |
| Bind mount (datos)   | `/mnt/hd2t/services/paperless/media/documents/originals/` (originales) y `.../archive/` (PDFs OCR) |
| Doc del servicio     | `docs/11-productividad/04-paperless-ngx.md`                                                    |
| Restauración         | BD → `media/` → `consume/` (vacío) → arrancar Paperless en orden: `paperless-db` primero       |

### Mealie / Linkding / FreshRSS

| Servicio   | BD                  | Patrón | Bind mount                                  | Doc                                           |
|------------|---------------------|--------|----------------------------------------------|-----------------------------------------------|
| Mealie     | PostgreSQL o SQLite | P o S  | `/mnt/hd2t/services/mealie/data/`           | `docs/11-productividad/05-mealie.md`         |
| Linkding   | SQLite              | S      | `/mnt/hd2t/services/linkding/data/`         | `docs/11-productividad/03-linkding.md`       |
| FreshRSS  | SQLite              | S      | `/mnt/hd2t/services/freshrss/data/`         | `docs/11-productividad/07-freshrss.md`       |

### Home Assistant

| Aspecto              | Valor                                                                                          |
|----------------------|------------------------------------------------------------------------------------------------|
| Categoría            | A (automatizaciones, devices emparejados, secrets)                                             |
| Contenedor           | `home-assistant`                                                                               |
| Bind mount           | `/mnt/hd2t/services/home-assistant/`                                                           |
| BD                   | SQLite — `/config/home-assistant_v2.db` (recorder; clase B: histórico de estados, regenerable parcial) |
| Patrón               | S sobre la BD + F sobre el resto del árbol                                                     |
| Doc del servicio     | `docs/08-domotica/01-home-assistant.md`                                                        |
| Excluir              | `**/home-assistant.log*`, `**/.storage/auth_provider.homeassistant` solo si se rota (no por defecto) |

> **Sobre la BD del recorder**: ocupa MB-GB y crece con cada estado de cada entidad. Si la pérdida del histórico es aceptable, se puede excluir vía `recorder: purge_keep_days: 7` en `configuration.yaml` y dejar que entre en Borg con tamaño manejable.

### Multimedia (Jellyfin / Navidrome / Audiobookshelf / Calibre-Web)

| Servicio        | BD              | Patrón | Doc                                             |
|-----------------|-----------------|--------|-------------------------------------------------|
| Jellyfin        | SQLite          | S      | `docs/09-multimedia/01-jellyfin.md`             |
| Navidrome       | SQLite          | S      | `docs/09-multimedia/02-navidrome.md`            |
| Audiobookshelf  | SQLite          | S      | `docs/09-multimedia/03-audiobookshelf.md`       |
| Calibre-Web     | SQLite (`metadata.db` de Calibre) | S | `docs/09-multimedia/04-calibre-web.md`     |
| Stash           | SQLite          | S      | `docs/09-multimedia/05-stash.md`                |

> **Bibliotecas multimedia binarias**: NUNCA en `dump-databases.sh`. Categoría C (regenerable) o D (Stash, decisión por separado). Las _bibliotecas_ se excluyen vía `exclude_patterns` en `config.yaml`; sólo se respalda la BD/metadata.

### *arr family + Transmission

| Servicio     | BD       | Patrón | Doc                                          |
|--------------|----------|--------|----------------------------------------------|
| Sonarr       | SQLite   | S      | `docs/10-descargas/03-sonarr.md`             |
| Radarr       | SQLite   | S      | `docs/10-descargas/04-radarr.md`             |
| Prowlarr     | SQLite   | S      | `docs/10-descargas/02-prowlarr.md`           |
| Transmission | _ninguna_ | F     | `docs/10-descargas/01-transmission.md`       |

### Filesystem-only (Categoría F — sin hook de dump)

Se respaldan exclusivamente por `source_directories: /mnt/hd2t/services/...`. Cada doc de servicio confirmará en su sección **Backup**:

- Authelia (config/)
- Caddy (data/, config/)
- Pi-hole config (la lista de adlists que vive en gravity.db sí necesita dump; el `setupVars.conf` y similares son ficheros)
- Samba (`smb.conf` + shares — los datos compartidos viven dentro de los servicios respaldados aparte)
- Syncthing (config + datos de cada folder marcado como categoría A o B)
- MinIO (objetos en `data/`)
- Mosquitto (config/, opcionalmente data/)
- Zigbee2MQTT, Node-RED (config + flows.json)
- Transmission (config + settings.json)
- Stirling-PDF (Categoría E — ni siquiera se respalda)

---

## Procedimientos de restauración

### Patrón de restauración común

Tres pasos invariables, válidos para cualquier servicio:

```bash
# 1. Identificar el archive a restaurar
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list --short "$BORG_REPO_LOCAL"
' | tail -10
# pi-2026-04-26T03:30:30
# pi-2026-04-25T03:30:31
# ...
ARCHIVE='pi-2026-04-26T03:30:30'

# 2. Crear destino temporal aislado (NO restaurar sobre la ruta viva del servicio)
sudo mkdir -p /tmp/restore-$$
cd /tmp/restore-$$

# 3. Extraer SOLO la ruta que interesa
sudo bash -c "
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg extract --list \"\$BORG_REPO_LOCAL::$ARCHIVE\" \
    mnt/hd2t/backups/dumps/<servicio>-<fecha>.sql.gz \
    mnt/hd2t/services/<servicio>
"

# 4. (Opcional) si el repo local está dañado, usar el offsite
sudo bash -c "
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  export BORG_RSH='ssh -i /root/.ssh/borg_offsite -o StrictHostKeyChecking=yes'
  borg extract --list \"\$BORG_REPO_OFFSITE::$ARCHIVE\" mnt/hd2t/services/<servicio>
"
```

> **Por qué `mnt/hd2t/...` sin `/` inicial**: Borg almacena rutas relativas. `borg extract` deposita en `$PWD`. Si extrajésemos a `/`, sobrescribiríamos los datos vivos sin revisar — error catastrófico. Restaurar siempre a `/tmp/restore-$$/` y mover manualmente con `rsync -aHA --delete` tras revisar.

> **Sobre `--list`**: imprime cada fichero a medida que lo extrae. Útil para confirmar que se está restaurando lo correcto, especialmente cuando se filtra con globs.

### Restauración: sólo un fichero

```bash
sudo mkdir -p /tmp/restore-$$ && cd /tmp/restore-$$
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg extract --list "$BORG_REPO_LOCAL::pi-2026-04-26T03:30:30" \
    home/homelab/homelab/almacen/.env
'
sudo cp home/homelab/homelab/almacen/.env /home/homelab/homelab/almacen/.env.restored
sudo diff /home/homelab/homelab/almacen/.env{,.restored}
# revisar diferencias antes de mover en sitio
```

### Restauración: una base de datos (Patrón M — MariaDB)

Caso típico: la BD de Bookstack se ha corrompido tras un apagón.

```bash
# 0. Parar el contenedor de la app (no la BD todavía)
docker stop bookstack

# 1. Extraer el dump más reciente
sudo mkdir -p /tmp/restore-$$ && cd /tmp/restore-$$
ARCHIVE=$(sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list --short "$BORG_REPO_LOCAL"
' | tail -1)
sudo bash -c "
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg extract \"\$BORG_REPO_LOCAL::$ARCHIVE\" mnt/hd2t/backups/dumps
"
ls mnt/hd2t/backups/dumps/bookstack-*.sql.gz
# bookstack-2026-04-26.sql.gz

# 2. Cargar credenciales
. ~/homelab/productividad/.env

# 3. Importar el dump
gunzip -c mnt/hd2t/backups/dumps/bookstack-2026-04-26.sql.gz | \
  docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" -i bookstack-db \
    mariadb -u "$MYSQL_USER" "$MYSQL_DATABASE"

# 4. Reanudar la app
docker start bookstack

# 5. Verificar
curl -fsS https://bookstack.lan/login >/dev/null && echo "OK"
```

> **Sobre `--clean --if-exists`** (en el dump original): el `pg_dump`/`mariadb-dump` del homelab incluyen estos flags, así que el `mariadb < dump.sql` re-crea las tablas desde cero (DROP previo). Restauración idempotente sobre una BD existente.

### Restauración: una base de datos (Patrón P — PostgreSQL)

Caso: Paperless ha perdido la BD pero el `media/` está intacto.

```bash
# 0. Parar la app
docker stop paperless

# 1. Extraer dump
sudo mkdir -p /tmp/restore-$$ && cd /tmp/restore-$$
ARCHIVE=$(sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list --short "$BORG_REPO_LOCAL"
' | tail -1)
sudo bash -c "
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg extract \"\$BORG_REPO_LOCAL::$ARCHIVE\" mnt/hd2t/backups/dumps
"

# 2. Cargar credenciales
. ~/homelab/productividad/.env

# 3. Importar el dump (con --clean --if-exists ya incluido)
gunzip -c mnt/hd2t/backups/dumps/paperless-*.sql.gz | \
  docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" -i paperless-db \
    psql -U "$POSTGRES_USER" "$POSTGRES_DB"

# 4. Reanudar la app
docker start paperless
docker logs -f paperless | head -30
# Esperar a "Ready" / "Listening on 0.0.0.0:8000"
```

### Restauración: una base de datos (Patrón S — SQLite)

Caso: la BD de Vaultwarden se ha corrompido.

```bash
# 0. Parar el contenedor
docker stop vaultwarden

# 1. Extraer el dump
sudo mkdir -p /tmp/restore-$$ && cd /tmp/restore-$$
ARCHIVE=$(sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list --short "$BORG_REPO_LOCAL"
' | tail -1)
sudo bash -c "
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg extract \"\$BORG_REPO_LOCAL::$ARCHIVE\" \
    mnt/hd2t/backups/dumps/vaultwarden-$(date +%F).sqlite.gz
"

# 2. Sustituir el .sqlite3 vivo por el dump
sudo cp /mnt/hd2t/services/vaultwarden/data/db.sqlite3 \
        /mnt/hd2t/services/vaultwarden/data/db.sqlite3.broken
sudo gunzip -c mnt/hd2t/backups/dumps/vaultwarden-*.sqlite.gz \
        > /mnt/hd2t/services/vaultwarden/data/db.sqlite3
sudo chown root:root /mnt/hd2t/services/vaultwarden/data/db.sqlite3  # ajustar a UID/GID real
sudo chmod 0600       /mnt/hd2t/services/vaultwarden/data/db.sqlite3

# 3. Verificar antes de arrancar
sudo sqlite3 /mnt/hd2t/services/vaultwarden/data/db.sqlite3 'PRAGMA integrity_check;'
# ok

# 4. Reanudar
docker start vaultwarden
```

> **Sobre el UID/GID**: SQLite del Patrón S guarda el contenido del `.db` pero NO sus permisos en disco — cada servicio tiene un usuario dentro del contenedor (UID arbitrario, ej. `1000`, `33`, `999`). El `chown` debe coincidir con el UID que el contenedor espera; se documenta en cada doc de servicio. Si está mal, el servicio arranca y devuelve `read-only database` o `unable to open database file`.

### Restauración: un servicio entero (volúmenes + BD)

Caso: Nextcloud se ha vuelto incoherente y queremos restaurarlo entero al estado de hace 2 días.

```bash
# 0. Anunciar mantenimiento
docker compose -f ~/homelab/almacen/docker-compose.yml stop

# 1. Mover los datos vivos a un sitio seguro (NUNCA borrar antes de verificar)
sudo mv /mnt/hd2t/services/nextcloud /mnt/hd2t/services/nextcloud.broken-$(date +%s)

# 2. Extraer el árbol entero del archive
ARCHIVE='pi-2026-04-24T03:30:31'
cd / && sudo bash -c "
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg extract --progress \"\$BORG_REPO_LOCAL::$ARCHIVE\" \
    mnt/hd2t/services/nextcloud \
    mnt/hd2t/backups/dumps/nextcloud-$(date +%F -d '2 days ago').sql.gz
"

# 3. Arrancar SOLO la BD
docker compose -f ~/homelab/almacen/docker-compose.yml up -d nextcloud-db
sleep 10  # esperar a que MariaDB esté listo
docker exec nextcloud-db mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" \
  -e 'CREATE DATABASE IF NOT EXISTS nextcloud;'

# 4. Importar el dump
gunzip -c /mnt/hd2t/backups/dumps/nextcloud-*.sql.gz | \
  docker exec -e MYSQL_PWD="$MYSQL_PASSWORD" -i nextcloud-db \
    mariadb -u "$MYSQL_USER" nextcloud

# 5. Arrancar la app
docker compose -f ~/homelab/almacen/docker-compose.yml up -d

# 6. Reparar y reescanear
docker exec -u www-data nextcloud php occ maintenance:repair --include-expensive
docker exec -u www-data nextcloud php occ files:scan --all

# 7. Verificar y, sólo si todo OK, borrar el árbol .broken
ls /mnt/hd2t/services/nextcloud.broken-*
# tras 24-48 h sin problemas:
sudo rm -rf /mnt/hd2t/services/nextcloud.broken-*
```

> **Por qué no borrar `.broken-` inmediatamente**: a veces la restauración revela un problema que se arregla mejor con datos de la versión rota (un fichero subido entre el archive y el momento del fallo). El .broken hace de _safety net_ durante 24-48 h. Cuesta unos GB en `hd2t`; merece la pena.

### Pi-hole — restauración

Tras restaurar `etc-pihole/` desde Borg, los `gravity.db` y `pihole-FTL.db` ya tienen la versión del dump. Si Pi-hole estaba apagado durante la restauración:

```bash
# 1. Restaurar tree
docker stop pihole
sudo rm -rf /mnt/hd2t/services/pihole.broken
sudo mv /mnt/hd2t/services/pihole /mnt/hd2t/services/pihole.broken

cd / && sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  ARCHIVE=$(borg list --short "$BORG_REPO_LOCAL" | tail -1)
  borg extract "$BORG_REPO_LOCAL::$ARCHIVE" mnt/hd2t/services/pihole
'

# 2. Si los .db venían del Patrón S (dumps), restaurar el .db vivo desde el dump:
sudo gunzip -c /mnt/hd2t/backups/dumps/pihole-gravity-*.sqlite.gz \
  > /mnt/hd2t/services/pihole/etc-pihole/gravity.db
sudo gunzip -c /mnt/hd2t/backups/dumps/pihole-pihole-FTL-*.sqlite.gz \
  > /mnt/hd2t/services/pihole/etc-pihole/pihole-FTL.db

# 3. Arrancar
docker start pihole
docker exec pihole pihole status
docker exec pihole pihole -g  # forzar reload de gravity.db
```

### Home Assistant — restauración

Idéntica estructura (servicio = árbol + SQLite). Lo único diferente: `secrets.yaml`. Verificar tras la restauración que sigue presente y con permisos `0600`.

### Drill rápido — extraer y comparar

Para verificar mensualmente que un dump abre y restaura sin error, sin tocar el servicio en producción:

```bash
sudo mkdir -p /tmp/drill && cd /tmp/drill

ARCHIVE=$(sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list --short "$BORG_REPO_LOCAL"
' | tail -1)

# Sacar el dump del archive
sudo bash -c "
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg extract \"\$BORG_REPO_LOCAL::$ARCHIVE\" \
    mnt/hd2t/backups/dumps/vaultwarden-$(date +%F).sqlite.gz
"

# Levantar un Vaultwarden temporal en otro puerto, con el .db restaurado
sudo gunzip -c mnt/hd2t/backups/dumps/vaultwarden-*.sqlite.gz > /tmp/drill/db.sqlite3
docker run --rm -d --name vw-drill -p 18080:80 \
  -v /tmp/drill:/data \
  vaultwarden/server:latest >/dev/null
sleep 5
curl -fsS http://localhost:18080/alive | grep -q 'alive' && echo "DRILL OK"
docker stop vw-drill
sudo rm -rf /tmp/drill
```

Anotar el resultado en `~/homelab/docs/journal/YYYY-MM-DD-drill-vaultwarden.md` con timing, archive usado, problemas encontrados.

---

## Almacenamiento

| Ruta                                      | Permisos       | Contenido                                                         |
|-------------------------------------------|----------------|-------------------------------------------------------------------|
| `/etc/borgmatic.d/hooks/dump-databases.sh` | `0755 root:root` | Hook completo (copia de `~/homelab/backups/borgmatic/hooks/`)     |
| `~/homelab/backups/borgmatic/hooks/dump-databases.sh` | `0755 homelab:homelab` | Fuente de verdad versionada (git)                       |
| `/mnt/hd2t/backups/dumps/`                | `0700 root:root` | Dumps SQL/SQLite del día actual + ≤ 7 días (limpieza automática)  |
| `/mnt/hd2t/backups/dumps/<svc>-YYYY-MM-DD.sql.gz` | `0600 root:root` | Dump individual                                                   |
| `/tmp/restore-$$/`                        | `0700 root:root` | Restauración temporal (borrar tras verificar)                     |
| `/mnt/hd2t/services/<svc>.broken-<ts>/`   | original        | Datos rotos preservados durante 24-48 h tras una restauración     |

> **Espacio**: los dumps locales pueden llegar a varios GB en estado estable (Nextcloud + Paperless + Bookstack pueden sumar 5-10 GB). El `find -mtime +7 -delete` los limita: en estado estable, entre 1× y 7× el tamaño de un dump diario.

---

## Backup

Este documento es una **convención más que un servicio**. Lo único que respaldar es el propio script y los runbooks:

| Qué                                          | Dónde                                                    | Cómo                                                       |
|----------------------------------------------|----------------------------------------------------------|------------------------------------------------------------|
| `~/homelab/backups/borgmatic/hooks/dump-databases.sh` | git                                                      | Versionado en `~/homelab/`                                  |
| `/etc/borgmatic.d/hooks/dump-databases.sh`   | host                                                     | Copia de la plantilla; entra en `source_directories: /etc` automáticamente |
| Este documento                               | `docs/07-backups/03-backup-docker-volumes.md`            | git                                                        |

Si se modifica el hook (por ejemplo al añadir un servicio nuevo), procedimiento estándar:

```bash
$EDITOR ~/homelab/backups/borgmatic/hooks/dump-databases.sh
~/homelab/backups/borgmatic/install.sh        # copia a /etc/borgmatic.d/hooks/
sudo /usr/bin/borgmatic --dry-run --verbosity 2 | head -20  # smoke test del hook
git -C ~/homelab add backups/borgmatic/hooks/dump-databases.sh
git -C ~/homelab commit -m "feat(backups): activar dump de <servicio>"
```

---

## Verificación

Antes de dar por cerrado este documento:

- [ ] `~/homelab/backups/borgmatic/hooks/dump-databases.sh` contiene los **helpers** `dump_postgres`, `dump_mariadb`, `dump_sqlite`, `dump_sqlite_cold` (al menos en su forma comentada/activa).
- [ ] `bash -n ~/homelab/backups/borgmatic/hooks/dump-databases.sh` no reporta errores de sintaxis.
- [ ] `shellcheck ~/homelab/backups/borgmatic/hooks/dump-databases.sh` no reporta errores **bloqueantes** (warnings menores aceptables).
- [ ] Para los servicios ya desplegados (`Pi-hole`, `Nextcloud` si está, `Authelia`, `Caddy`, `Grafana`, `Uptime Kuma`): **su bloque del hook está descomentado** y `borgmatic --dry-run` lista los dumps que generaría.
- [ ] `sudo /etc/borgmatic.d/hooks/dump-databases.sh && ls -la /mnt/hd2t/backups/dumps/*-$(date +%F).*` muestra al menos un fichero por servicio activo.
- [ ] Cada dump generado abre correctamente:
  - Para Patrón M: `gunzip -c <dump>.sql.gz | head -20` muestra `-- MariaDB dump ...` y luego `DROP TABLE IF EXISTS \`...\`;`.
  - Para Patrón P: `gunzip -c <dump>.sql.gz | head -20` muestra `-- PostgreSQL database dump` y `DROP TABLE IF EXISTS "..." CASCADE;`.
  - Para Patrón S: `gunzip -c <dump>.sqlite.gz | file -` reporta `application/x-sqlite3` (binary).
- [ ] Drill mensual de Vaultwarden ejecutado y registrado en `~/homelab/docs/journal/`.
- [ ] La sección **Backup → restauración** de cada doc de servicio ya escrito enlaza explícitamente a este documento (ej. _"Restauración: ver `docs/07-backups/03-backup-docker-volumes.md` → Patrón M"_).

---

## Troubleshooting

### `mariadb-dump: error 1146: Table '...' doesn't exist`

Síntoma: el dump aborta con error `1146` y produce un fichero parcial.

Causa típica: la BD se actualizó (Watchtower hizo `pull`) y dejó tablas en migración. La nueva versión del esquema aún no terminó de aplicarse.

Diagnóstico:

```bash
docker logs --tail 50 nextcloud-db | grep -i 'starting'
# si hay 'starting innodb upgrade...' la BD está migrando.
```

Solución: esperar a que termine la migración (puede tardar minutos en una Pi 5). El backup del día siguiente capturará el estado migrado. Si urge, lanzar manualmente:

```bash
sudo /etc/borgmatic.d/hooks/dump-databases.sh
```

cuando `docker logs` muestre `ready for connections`.

### `pg_dump: server version: 16; pg_dump version: 15`

Síntoma: el `pg_dump` falla con incompatibilidad de versiones.

Causa: el `pg_dump` que se ha invocado es del host (Debian) en lugar de del contenedor.

Diagnóstico:

```bash
which pg_dump
# /usr/bin/pg_dump   ← incorrecto (host)
grep 'pg_dump' /etc/borgmatic.d/hooks/dump-databases.sh
# debe verse 'docker exec ... pg_dump'   ← correcto
```

Solución: confirmar que el bloque del servicio usa `docker exec -e PGPASSWORD=... -i $container pg_dump ...`, no `pg_dump` a secas. Re-aplicar `install.sh`.

### El dump pesa decenas de MB cada noche y Borg no deduplica

Síntoma: `borg info` muestra `unique_csize` creciendo casi al ritmo de `original_size`.

Causa: el dump no es determinista. Las versiones nuevas de `mariadb-dump` añaden un comentario inicial con la fecha, y el orden de tablas a veces cambia entre minor versions.

Diagnóstico:

```bash
gunzip -c /mnt/hd2t/backups/dumps/<svc>-$(date +%F).sql.gz | head -5
gunzip -c /mnt/hd2t/backups/dumps/<svc>-$(date -d yesterday +%F).sql.gz | head -5
# ¿la línea con el timestamp es lo único que cambia? — añadir --skip-comments
diff <(gunzip -c .../svc-yesterday.sql.gz) <(gunzip -c .../svc-today.sql.gz) | head -50
```

Solución: añadir `--skip-comments` al `mariadb-dump`. Para `pg_dump`, usar `--no-tablespaces` y `--quote-all-identifiers` (el primero quita la cláusula `SET default_tablespace`, que cambia entre runs en algunas versiones).

### `Permission denied` al escribir en `/mnt/hd2t/backups/dumps/`

Síntoma:

```
[dump] nextcloud: FAIL
gzip: stdout: Permission denied
```

Causa: el _hook_ corre como `root` (desde `borgmatic.service`), pero **manualmente** se invocó como `homelab` (sin sudo).

Diagnóstico:

```bash
stat -c '%a %U:%G' /mnt/hd2t/backups/dumps
# 700 root:root
id
# uid=1000(homelab) ...
```

Solución: invocar siempre con `sudo`:

```bash
sudo /etc/borgmatic.d/hooks/dump-databases.sh
```

o forzar dentro del script un `[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"` al inicio. **No** cambiar la ownership de `dumps/` a `homelab` — la regla "los dumps son root-only" es deliberada.

### `docker exec`: `Error response from daemon: container ... is not running`

Síntoma: dump del servicio X falla porque su contenedor no está vivo.

Causa: `dump-databases.sh` ya hace `docker ps --format ... | grep -q ^X$` antes de cada bloque para evitar este error. Si aparece, es porque el bloque no se construyó con esa guarda.

Solución: **siempre** envolver el bloque con la guarda. Plantilla:

```bash
docker ps --format '{{.Names}}' | grep -q '^<container>$' || {
  echo "[dump] <svc>: container no corre; skip"
  exit 0  # o return 0 dentro de una función
}
```

### El bloque de Vaultwarden falla con `database is locked`

Síntoma: `sqlite3 /data/db.sqlite3 .backup` retorna error `5 (SQLITE_BUSY)`.

Causa: Vaultwarden está escribiendo en el momento del `.backup`. SQLite serializa con `BEGIN IMMEDIATE`; si hay un escritor de larga duración (raro en Vaultwarden), el `.backup` falla.

Solución a) reintentar con backoff:

```bash
for i in 1 2 3 4 5; do
  if docker exec vaultwarden sh -c "sqlite3 /data/db.sqlite3 '.backup /tmp/vw.bak'"; then
    break
  fi
  echo "[dump] vaultwarden: retry $i"
  sleep $((i*2))
done
```

Solución b) parar el contenedor (downtime ~10 s) — usar `dump_sqlite_cold` en lugar de `dump_sqlite`. Aceptable porque Vaultwarden tiene clientes _offline-first_.

### El servicio restaurado arranca pero la app reporta "página de instalación / configuración inicial"

Síntoma: tras restaurar, Nextcloud o Paperless preguntan por usuario admin como si fuera fresh install.

Causa típica: el `.env` no se restauró junto al `docker-compose.yml`, **o** la BD no se importó (sólo se restauró el árbol de ficheros).

Diagnóstico:

```bash
docker exec nextcloud-db mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" \
  -e 'SELECT COUNT(*) FROM nextcloud.oc_users;'
# Si devuelve 0: la BD está vacía → falta importar el dump.

ls -la ~/homelab/almacen/.env
# Si no existe: restaurar `home/homelab/homelab/almacen/.env` desde Borg.
```

Solución: importar el dump faltante (ver **Restauración: una BD**) o restaurar el `.env` y reiniciar el stack.

### El restauro deja ficheros con el UID equivocado

Síntoma: tras `borg extract`, los ficheros pertenecen a un UID inexistente en el host nuevo (ej. UID 999) y el contenedor reporta `Permission denied`.

Causa: el sistema de restauración (DR completo en una Pi nueva) no replicó los grupos del sistema, así que UIDs no coinciden.

Diagnóstico:

```bash
sudo ls -la /mnt/hd2t/services/nextcloud/data/ | head -5
# drwxr-x---  3 999 999 ... admin
```

Solución: re-aplicar ownerships desde el doc del servicio. Cada doc de servicio documenta el `chown` correcto. Ejemplo Nextcloud:

```bash
sudo chown -R 33:33 /mnt/hd2t/services/nextcloud/data    # www-data en imagen oficial
```

> **Por qué Borg no resuelve esto**: Borg conserva los UIDs **numéricos** del archive. Si la Pi original tenía `nextcloud:33` y la nueva no, el _mapping_ no se hace automáticamente. Cada doc de servicio **debe** documentar su UID:GID para hacer el `chown` post-restauración.

### `borg extract` consume todo el espacio de `/tmp`

Síntoma: la restauración a `/tmp/restore-$$/` falla con `No space left on device`.

Causa: `/tmp` es un `tmpfs` (RAM) limitado a unos GB; un archive grande no cabe.

Solución: extraer a `/mnt/hd2t/restore-$$/` directamente:

```bash
sudo mkdir -p /mnt/hd2t/restore-$$ && cd /mnt/hd2t/restore-$$
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg extract "$BORG_REPO_LOCAL::pi-..." mnt/hd2t/services/<svc>
'
```

`hd2t` tiene cientos de GB libres; cabe cualquier archive. Borrar tras restaurar.

### `pihole`/`mosquitto` etc. quedan parados tras el dump

Síntoma: se usó `dump_sqlite_cold` y el contenedor no volvió a arrancar.

Causa: el `docker start` retornó error por un cambio en el `docker-compose.yml` (ej. nueva variable obligatoria).

Diagnóstico:

```bash
docker logs <container> --tail 20
docker compose -f ~/homelab/<stack>/docker-compose.yml up -d <service>
```

Solución: en el hook, envolver `docker start` con detección de fallo y _retry_ vía `docker compose up -d`. Plantilla mejorada:

```bash
docker stop pihole >/dev/null
gzip -c /mnt/hd2t/services/pihole/etc-pihole/gravity.db > "$DUMPS/pihole-gravity-$DATE.db.gz"
chmod 0600 "$DUMPS/pihole-gravity-$DATE.db.gz"
docker start pihole >/dev/null || \
  docker compose -f ~/homelab/red/docker-compose.yml up -d pihole
```

---

## Referencias

- PostgreSQL — `pg_dump` y modos de backup lógico: <https://www.postgresql.org/docs/current/app-pgdump.html>
- PostgreSQL — `pg_basebackup` y _physical backups_: <https://www.postgresql.org/docs/current/app-pgbasebackup.html>
- MariaDB — `mariadb-dump` (alias `mysqldump`): <https://mariadb.com/kb/en/mariadb-dump/>
- MariaDB — `--single-transaction` y consistencia online: <https://mariadb.com/kb/en/mariadb-dumpmysqldump/#options>
- SQLite — `.backup` API y backups online: <https://www.sqlite.org/backup.html>
- SQLite — `PRAGMA integrity_check`: <https://www.sqlite.org/pragma.html#pragma_integrity_check>
- Redis — `BGSAVE` vs `SAVE`: <https://redis.io/commands/bgsave/>
- BorgBackup — `borg extract` y restauración granular: <https://borgbackup.readthedocs.io/en/stable/usage/extract.html>
- BorgBackup — `borg mount` (FUSE) para browsing interactivo: <https://borgbackup.readthedocs.io/en/stable/usage/mount.html>
- Borgmatic — hooks `before_backup` y patrón de _database dump_: <https://torsion.org/borgmatic/docs/how-to/backup-your-databases/>
- Docker — `docker exec` y paso de variables de entorno: <https://docs.docker.com/reference/cli/docker/container/exec/>
- Nextcloud — restauración manual y `occ maintenance:repair`: <https://docs.nextcloud.com/server/latest/admin_manual/maintenance/restore.html>
- Paperless-ngx — backup y restore (BD + media): <https://docs.paperless-ngx.com/administration/#backup>
- Vaultwarden — backup wiki: <https://github.com/dani-garcia/vaultwarden/wiki/Backing-up-your-vault>
- Home Assistant — recorder y SQLite backups: <https://www.home-assistant.io/integrations/recorder/>
- Pi-hole — _Teleporter_ y backup nativo (alternativa al filesystem dump): <https://docs.pi-hole.net/teleporter/>
