# Backup y Restore de Volúmenes Docker y Bases de Datos

## Descripción

**Manual operativo** de la Fase 7. Este documento es el **complemento práctico** de [`./01-estrategia-backup.md`](./01-estrategia-backup.md) (estrategia 3-2-1) y [`./02-borgmatic.md`](./02-borgmatic.md) (orquestador): aquí viven los **procedimientos concretos** que cada doc de servicio referencia desde su sección "Backup → Restore (resumen)".

Cubre, en este orden:

1. **Modelo de datos del homelab**: por qué bind mounts y no named volumes (recordatorio operativo, fijado en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5), y qué hacer cuando un servicio impone named volume.
2. **Patrones canónicos de dump por motor de BD**: PostgreSQL, MariaDB/MySQL, SQLite, Redis. Comandos exactos, flags y por qué se eligen — la implementación en `borgmatic.yml` ya los aplica, pero el operador los necesita "a mano" para ad-hoc.
3. **Backup ad-hoc de un volumen Docker named** (patrón `alpine + tar`). Vía recomendada solo para volúmenes que el operador no puede convertir a bind mount (raro: imagen oficial que falla con bind mount, contenedor temporal de smoke test).
4. **Restore por servicio**: la "memoria operativa" que cada doc de la fase 6 / 9 / 11 enlaza desde su §10.2 (o equivalente). Aquí está el **paso a paso** real.
5. **Hooks `pre-update`/`post-update` de Watchtower**: dump automático de la BD justo antes de un upgrade de imagen, sin tocar Borgmatic. Imprescindible para Nextcloud, Bookstack, Vaultwarden y similares con BD relacional.
6. **Smoke test L3 (mensual)**: el procedimiento canónico de verificación de restauración referenciado por [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §8.3 y [`./02-borgmatic.md`](./02-borgmatic.md) §13.3.
7. **Disaster recovery — resumen y orden de restauración**. El procedimiento end-to-end vive en [`../13-operaciones/02-disaster-recovery.md`](../13-operaciones/02-disaster-recovery.md); aquí se documenta solo la **parte de datos** (qué se restaura, en qué orden, con qué comandos).

> **Alcance**: este documento **no** redefine la estrategia ni reescribe el `borgmatic.yml`. Si entra en conflicto con [`./01-estrategia-backup.md`](./01-estrategia-backup.md) o [`./02-borgmatic.md`](./02-borgmatic.md), gana el doc anterior. Aquí se concretan procedimientos, no se toman decisiones de diseño.

> **Alcance de red**: ninguna operación de las descritas aquí abre puertos ni hace tráfico saliente que no esté ya cubierto por [`./02-borgmatic.md`](./02-borgmatic.md). Los `docker exec` y `docker run --rm` son locales al socket Docker; los `borg/borgmatic extract/restore` leen el repo local en `/mnt/hd2t/backups/borg/`.

---

## Requisitos Previos

- **Borgmatic operativo** según [`./02-borgmatic.md`](./02-borgmatic.md). Al menos un snapshot exitoso en `/mnt/hd2t/backups/borg/` (`sudo borgmatic list` lista ≥ 1 archivo).
- **Estrategia leída**: [`./01-estrategia-backup.md`](./01-estrategia-backup.md). El operador debe entender la diferencia entre el "dato vivo" (`/mnt/hd2t/services/<stack>/`), el "dump" (`/mnt/hd2t/backups/dumps/<motor>/`) y el "snapshot Borg" (`/mnt/hd2t/backups/borg/`).
- **Convenciones de Compose**: bind mount sobre `/mnt/hd2t/services/<stack>/` ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5). Cualquier excepción (named volume) está documentada en el doc del servicio que la imponga.
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)) si se quiere usar el patrón `pre-update`/`post-update` (§5).
- **Acceso `sudo`** o sesión `root` directa para `borgmatic extract`, `borg list`, manipular `/mnt/hd2t/backups/dumps/` (modo `0700 root:root`).
- **`docker` en `PATH`** del usuario que ejecute los procedimientos. Los `docker exec` se hacen como `homelab` cuando el contenedor no requiera root del host; los que escriben en `/mnt/hd2t/backups/dumps/` requieren `sudo`.
- **Disco con espacio libre** suficiente para extraer un snapshot grande de un servicio sin presionar `hd2t`. Convención: `/mnt/hd2t/backups/restore-test/<servicio>-YYYY-MM-DD/` como destino de pruebas.
- **`~/homelab/operations/restore-tests.log`** existe (puede estar vacío) y está versionado en git. Si no existe: `touch ~/homelab/operations/restore-tests.log && git add operations/restore-tests.log`.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Modelo de almacenamiento | **Bind mount sobre `/mnt/hd2t/services/<stack>/`** para datos persistentes; named volumes solo para datos efímeros (cache de Caddy, etc.) | [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5. Permite backup directo sin "extraer" volúmenes y restore con `cp -a` o `borgmatic extract` a la ruta original. |
| Motor canónico de dump por BD | **PostgreSQL → `pg_dump --format=custom`**, **MariaDB → `mariadb-dump --single-transaction`**, **SQLite → `sqlite3 .backup`** | [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §5.2. Los flags están elegidos para snapshot consistente sin lockear escritores. |
| Vía de invocación del dump en runtime | **`docker exec <contenedor-bd> <comando-dump>`** desde un hook de Borgmatic o script ad-hoc, **no** instalar el cliente del motor en el host | El cliente que generó la versión X de la BD vive en la imagen del contenedor X. Usar el cliente del host (versión Y de apt) es la causa típica de restore roto entre versiones (p. ej. PostgreSQL 15 dump leído por psql 13). |
| Destino de los dumps | **`/mnt/hd2t/backups/dumps/<motor>/<servicio>-YYYY-MM-DD.<ext>`** con permisos `0700 root:root` | [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §3. Estandariza los paths para que cualquier hook/script de cualquier servicio sepa dónde escribir y dónde leer. |
| Vía de invocación del restore | **`borgmatic restore --database <nombre>`** para BD declaradas en `borgmatic.yml`; **`sudo borgmatic extract --archive ... --path ... --destination ...`** para ficheros sueltos | Borgmatic encapsula el ciclo `extract dump → cliente nativo → carga`. Tirar `borg extract` + `psql` a mano es reservar un pie para auto-disparo. |
| Snapshots ad-hoc de volúmenes Docker named | **Patrón `docker run --rm -v <vol>:/data -v /mnt/hd2t/backups/dumps/docker-volumes:/backup alpine tar czf /backup/<vol>-YYYY-MM-DD.tar.gz -C /data .`** | Es la única vía portátil para extraer un named volume. Vive en `/mnt/hd2t/backups/dumps/docker-volumes/`. **No** se programa rutinario: cada uso es excepcional y se documenta. |
| Hooks Watchtower | **`pre-update`** dentro del contenedor, escribe a un bind mount `/data/backups/`; **`post-update`** opcional para verificación tras upgrade | [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §52. `pre-update` con exit ≠ 0 cancela el upgrade — propiedad clave: nunca se actualiza una imagen sin un dump consistente. |
| Cadencia smoke test L3 | **Mensual**, rotando servicio (Vaultwarden M1 → Authelia M2 → Bookstack M3 → Nextcloud-mini M4 → vuelta a Vaultwarden) | [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §8.3. La rotación cubre los servicios "diversos": SQLite (Vaultwarden, Authelia), MariaDB (Bookstack), PostgreSQL + ficheros (Nextcloud). Si solo se prueba uno siempre, los demás siguen siendo "esperanza, no backup". |
| Destino del smoke test | **`/mnt/hd2t/backups/restore-test/<servicio>-YYYY-MM-DD/`** | Mismo disco para no contaminar otros mounts; modo `0700 root:root`. Tras éxito: `sudo rm -rf` el directorio. |
| Anotación del smoke test | **`~/homelab/operations/restore-tests.log`** (versionado en git) | Auditable, parte de la "definición del homelab". Cada entrada: fecha · servicio · snapshot · resultado · hallazgos. |
| Orden de restauración en disaster recovery | **secrets → red/DNS → BD → datos de servicios → reverse proxy → resto** | Sin secrets las BD no arrancan; sin DNS interno los servicios no se ven; sin BD el código no levanta; sin reverse proxy el operador no llega a las UIs para verificar. |

---

## 1. Modelo de datos del homelab (recordatorio)

### 1.1. Bind mounts por defecto

[`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5 fijó la convención: **todos los datos persistentes** del homelab son **bind mounts** a `/mnt/hd2t/services/<stack>/<subdir>/`. Razones operativas para el backup/restore:

1. **El backup es trivial**: Borgmatic ([`./02-borgmatic.md`](./02-borgmatic.md) §6) pone `/mnt/hd2t/services` directamente en `source_directories`. No hace falta "extraer" volúmenes ni inspeccionar el driver.
2. **El restore es trivial**: `sudo borgmatic extract --path mnt/hd2t/services/<stack>` deposita los ficheros en su ruta original. Solo hay que `chown` si el UID/GID cambió (raro: el operador `homelab` es UID 1000 estable).
3. **Diff entre fechas es trivial**: `diff -r /mnt/hd2t/services/<stack> /mnt/hd2t/backups/restore-test/<stack>-2026-02-01/mnt/hd2t/services/<stack>` — sin abrir el repo Borg.
4. **Inspección puntual sin Docker**: si el contenedor no arranca, el operador puede mirar/editar los ficheros directamente con `sudo less` o `sudo nano`.

### 1.2. Named volumes: cuándo y cómo

Casos en los que un named volume es la opción correcta:

- **Cache regenerable** (Caddy `data/`, transcodes de Jellyfin si se decide así). Pérdida = re-descarga / re-transcode. **No backup**.
- **Imagen que no soporta bind mount limpio** (raro; típicamente por permisos hardcodeados que chocan con `noexec`). En ese caso el doc del servicio explicará la excepción.

Para el caso "necesito respaldar un named volume" (que **no** debería darse en el set por defecto), la vía operativa está en §3.

### 1.3. Tipos de datos por servicio (mapa)

Resumen de qué motor de BD usa cada servicio del set por defecto. Determina qué procedimiento de §2 aplica:

| Servicio | BD relacional | Otros artefactos críticos | Procedimiento dump |
|---|---|---|---|
| **Authelia** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)) | SQLite (`db.sqlite3`) | `secrets/storage_encryption` (par indisociable) | §2.3 + cp del `storage_encryption` |
| **Nextcloud** ([`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md)) | MariaDB | `nextcloud/data/` (ficheros usuario), `secrets/*` | §2.2 + bind mount |
| **Vaultwarden** ([`../11-productividad/01-vaultwarden.md`](../11-productividad/01-vaultwarden.md)) | SQLite | `attachments/`, `sends/`, `rsa_key.*` | §2.3 + bind mount |
| **Bookstack** ([`../11-productividad/02-bookstack.md`](../11-productividad/02-bookstack.md)) | MariaDB | `uploads/`, `storage/` | §2.2 + bind mount |
| **Linkding** ([`../11-productividad/03-linkding.md`](../11-productividad/03-linkding.md)) | SQLite | — | §2.3 |
| **Paperless-ngx** ([`../11-productividad/04-paperless-ngx.md`](../11-productividad/04-paperless-ngx.md)) | PostgreSQL | `media/originals/`, `media/archive/` | §2.1 + bind mount |
| **Mealie** ([`../11-productividad/05-mealie.md`](../11-productividad/05-mealie.md)) | PostgreSQL o SQLite | `data/` | §2.1 ó §2.3 |
| **FreshRSS** ([`../11-productividad/07-freshrss.md`](../11-productividad/07-freshrss.md)) | SQLite | — | §2.3 |
| **Uptime Kuma** ([`../05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md)) | SQLite | — | §2.3 |
| **Grafana** ([`../05-monitorizacion/02-grafana.md`](../05-monitorizacion/02-grafana.md)) | SQLite (WAL) | — | §2.3 (cp seguro vía WAL) |
| **Home Assistant** (Fase 8) | SQLite (recorder) + propio `.storage/` | snapshots vía API HA | §2.3 + API HA |
| **Stash** ([`../09-multimedia/05-stash.md`](../09-multimedia/05-stash.md)) | SQLite | export propio (settings + scrapers) | §2.3 + export Stash |
| **Sonarr / Radarr / Prowlarr** ([`../10-descargas/`](../10-descargas/)) | SQLite | `Backups/` propios | §2.3 |
| **Samba** ([`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md)) | TDB (`tdbbackup`) | `smb.conf`, `users.conf` | §2.4 |
| **MinIO** ([`../06-almacenamiento/04-minio.md`](../06-almacenamiento/04-minio.md)) | — (FS) | `data/.minio.sys/` (metadata IAM) | bind mount + `mc mirror` opcional |

> **No relacionales con estado en RAM**: Redis (locks de sesión Authelia/Nextcloud), Mosquitto (MQTT). En el patrón del homelab **no se respaldan**: estado efímero, pérdida = re-login / retry de cliente. Documentado en [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §2.2.

---

## 2. Patrones canónicos de dump por motor

Los hooks declarativos de Borgmatic ([`./02-borgmatic.md`](./02-borgmatic.md) §6) ya invocan los comandos de esta sección. Lo que sigue es el **manual** para que el operador los entienda y pueda ejecutarlos a mano (smoke test, dump puntual antes de una operación delicada, recuperación de un dump perdido).

### 2.1. PostgreSQL

Comando canónico:

```bash
docker exec postgres-<servicio> sh -c \
  'pg_dump --format=custom --no-owner --no-privileges \
     -U "$POSTGRES_USER" "$POSTGRES_DB"' \
  | sudo tee /mnt/hd2t/backups/dumps/postgresql/<servicio>-$(date +%F).pgdump > /dev/null

sudo chmod 600 /mnt/hd2t/backups/dumps/postgresql/<servicio>-$(date +%F).pgdump
```

| Flag | Por qué |
|---|---|
| `--format=custom` | Formato binario, incluye índices y compresión interna. Permite **restauración parcial** (`pg_restore -t <tabla>`), imposible con `--format=plain`. |
| `--no-owner` | Omite las sentencias `ALTER ... OWNER TO`. Permite restaurar el dump a un cluster con roles distintos sin error. Imprescindible si se restaura a un Postgres recién levantado. |
| `--no-privileges` | Omite `GRANT/REVOKE`. Mismo motivo que `--no-owner`: portabilidad entre clusters. |
| `-U "$POSTGRES_USER"` | El user que la imagen oficial expone como variable de entorno; equivale a `nextcloud` / `paperless` / etc. según el contenedor. |
| `"$POSTGRES_DB"` | Nombre de la BD por convención de imagen oficial. |

> **Variante "todas las BD del cluster"**: `pg_dumpall -U "$POSTGRES_USER"` produce un fichero `.sql` plano con `CREATE DATABASE` + datos. Útil para clusters multi-tenant. En el homelab cada servicio tiene su propio Postgres, así que **no** se usa por defecto.

> **Por qué `docker exec` y no `pg_dump` desde el host**: la versión de `pg_dump` debe coincidir con la del servidor (regla de compatibilidad: cliente N puede leer servidor N o N-1, no más). El cliente del host (apt) no se actualiza al ritmo de la imagen; usar el cliente **dentro** del contenedor garantiza match.

Restore (a un Postgres ya arrancado, vacío):

```bash
docker exec -i postgres-<servicio> sh -c \
  'pg_restore --no-owner --no-privileges --clean --if-exists \
     -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < /mnt/hd2t/backups/dumps/postgresql/<servicio>-2026-01-15.pgdump
```

| Flag adicional | Por qué |
|---|---|
| `--clean` | Antes de cada `CREATE`, hace `DROP IF EXISTS`. Reentrante: aplicable sobre BD ya parcialmente cargada sin error. |
| `--if-exists` | Sin esto, `--clean` falla si una tabla del dump no existe en destino. |

### 2.2. MariaDB / MySQL

Comando canónico:

```bash
docker exec mariadb-<servicio> sh -c \
  'mariadb-dump --single-transaction --routines --triggers --events \
     -u root -p"$(cat /run/secrets/db_root_password)" "$MYSQL_DATABASE"' \
  | gzip -c \
  | sudo tee /mnt/hd2t/backups/dumps/mariadb/<servicio>-$(date +%F).sql.gz > /dev/null

sudo chmod 600 /mnt/hd2t/backups/dumps/mariadb/<servicio>-$(date +%F).sql.gz
```

| Flag | Por qué |
|---|---|
| `--single-transaction` | Inicia una transacción de lectura consistente sobre InnoDB. **Sin** lockear escritores (a diferencia de `--lock-tables`). El snapshot es del momento del `BEGIN`. Imprescindible para BD activas. |
| `--routines` | Incluye stored procedures y functions. Sin esto, se pierden si se restaura el dump en BD vacía. |
| `--triggers` | Idem para triggers (Bookstack y Nextcloud usan algunos para integridad referencial). |
| `--events` | Idem para eventos programados (cron MariaDB). Aunque el homelab no los usa, es barato incluirlos. |
| `gzip -c` | Compresión inline. Reduce el dump a ~10–20% del tamaño en BD típicas. Borg deduplica peor sobre comprimido (cada cambio rompe la firma de bloque), pero el ahorro de I/O en `/mnt/hd2t/backups/dumps/` lo justifica. |

> **Por qué `mariadb-dump` y no `mysqldump`**: la imagen oficial `mariadb` rebautizó el binario en 11.x. `mysqldump` sigue presente como compat shim, pero usar el nombre canónico evita warnings en logs y prepara para la próxima major.

> **`-p"$(cat /run/secrets/db_root_password)"`**: el password de root vive en `/run/secrets/db_root_password` dentro del contenedor (Docker secret o bind mount, según el stack). **No** se pasa por línea de comandos directa para no aparecer en `ps aux`.

Restore:

```bash
zcat /mnt/hd2t/backups/dumps/mariadb/<servicio>-2026-01-15.sql.gz \
  | docker exec -i mariadb-<servicio> sh -c \
      'mariadb -u root -p"$(cat /run/secrets/db_root_password)" "$MYSQL_DATABASE"'
```

> **Antes del restore**: vaciar la BD destino (`mariadb -e 'DROP DATABASE <db>; CREATE DATABASE <db>;'`) o arrancar MariaDB con la BD recién creada por la imagen oficial (`MYSQL_DATABASE=<db>` en el env, sin `data/` previo). Cargar un dump sobre tablas existentes mezcla datos y rompe constraints.

### 2.3. SQLite

Comando canónico (desde el host, con el fichero `.sqlite3` en bind mount):

```bash
sudo sqlite3 /mnt/hd2t/services/<servicio>/<subpath>/db.sqlite3 \
  ".backup '/mnt/hd2t/backups/dumps/sqlite/<servicio>-$(date +%F).sqlite3'"

sudo chmod 600 /mnt/hd2t/backups/dumps/sqlite/<servicio>-$(date +%F).sqlite3
```

| Por qué `.backup` y no `cp` | Razón |
|---|---|
| `.backup` usa la API oficial de SQLite | Hace un snapshot consistente incluso con escritores activos. Internamente abre transacción de lectura, copia páginas, libera transacción. |
| `cp` puede capturar un estado intermedio | Si SQLite está en `journal_mode=WAL` (por defecto en Authelia, Vaultwarden, Uptime Kuma), `cp` solo del `.sqlite3` deja fuera el `.sqlite3-wal` con cambios no fusionados. El restore de `.sqlite3` solo es **incompleto**. |
| `cp` con `journal_mode=DELETE` y sin escrituras concurrentes | Es seguro, pero detectar "sin escrituras concurrentes" requiere parar el contenedor. `.backup` evita la parada. |

Variante desde dentro del contenedor (preferida si el binario `sqlite3` no está en el host):

```bash
docker exec <servicio> sqlite3 /config/db.sqlite3 \
  ".backup '/config/db-backup.sqlite3'"

# Mover al destino externo (el contenedor tiene bind mount sobre /config).
sudo mv /mnt/hd2t/services/<servicio>/<config_path>/db-backup.sqlite3 \
  /mnt/hd2t/backups/dumps/sqlite/<servicio>-$(date +%F).sqlite3
```

Restore: `cp` directo. Para SQLite, restore es literalmente reemplazar el fichero:

```bash
docker compose -f ~/homelab/stacks/<stack>/docker-compose.yml stop <servicio>
sudo cp /mnt/hd2t/backups/dumps/sqlite/<servicio>-2026-01-15.sqlite3 \
  /mnt/hd2t/services/<servicio>/<subpath>/db.sqlite3
sudo chown <uid>:<gid> /mnt/hd2t/services/<servicio>/<subpath>/db.sqlite3
docker compose -f ~/homelab/stacks/<stack>/docker-compose.yml up -d <servicio>
```

### 2.4. Samba TDBs

Samba usa **TDB** (Trivial Database, propio de Samba) para `passdb.tdb` (hashes NTLM/Kerberos), `secrets.tdb` (claves de máquina). El backup correcto **no es** `cp`:

```bash
docker exec samba sh -c '
  tdbbackup /var/lib/samba/private/passdb.tdb
  tdbbackup /var/lib/samba/private/secrets.tdb
'
# tdbbackup deja un fichero .bak junto a cada .tdb. El bind mount los expone:
ls /mnt/hd2t/services/samba/private/*.bak
```

`tdbbackup` valida checksums y hace vacuum. Borgmatic ([`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md) §11.1) ya incorpora este `before_backup`.

### 2.5. Redis (caso sin backup)

Por defecto, **no se respaldan** los datos de Redis del homelab (locks de Authelia, sesiones de Nextcloud, cache de Bookstack). Pérdida ⇒ re-login del usuario, retry de cliente. Si en algún caso aislado un servicio justifica el respaldo:

```bash
docker exec redis-<servicio> redis-cli -a "$REDIS_PASSWORD" BGSAVE
# BGSAVE escribe /data/dump.rdb (snapshot binario) en el bind mount.
```

Es un caso documentado servicio por servicio cuando aplique. **No** se generaliza.

---

## 3. Backup ad-hoc de un volumen Docker named

[`./01-estrategia-backup.md`](./01-estrategia-backup.md) §3.2 explica que el patrón **no recomendado** es snapshotear named volumes; la regla del homelab es bind mount. Cuando, excepcionalmente, un volumen named se queda en un stack:

### 3.1. Patrón `alpine + tar`

```bash
sudo install -d -o root -g root -m 700 /mnt/hd2t/backups/dumps/docker-volumes/<servicio>

docker run --rm \
  -v <volumen-named>:/data:ro \
  -v /mnt/hd2t/backups/dumps/docker-volumes/<servicio>:/backup \
  alpine:3.19 \
  sh -c "tar czf /backup/<volumen>-$(date +%F).tar.gz -C /data . && chmod 600 /backup/<volumen>-$(date +%F).tar.gz"
```

| Decisión | Por qué |
|---|---|
| `:ro` en el volumen origen | Defensa: el contenedor de tar no puede modificar nada. Si por error la imagen se rompe, no daña el volumen. |
| `alpine:3.19` (pin) | Versión fija. `alpine:latest` cambia y un día puede no traer `tar` con `-z`. Pin en versión testeada. |
| `tar czf` con `-C /data .` | El `.` final mete el **contenido** (no la carpeta `/data` raíz). Restore con `tar xzf` en el directorio destino restaura los ficheros tal cual. |
| `chmod 600` final | Coherente con el `0700 root:root` del directorio padre. |

> **Limitaciones**: este patrón **no** garantiza consistencia transaccional. Para volúmenes que contienen una BD activa, hay que parar el contenedor antes (`docker compose stop <servicio>`), hacer el `tar`, y `start` de nuevo. La ventana de parada vale para pruebas; para producción se prefiere bind mount + dump.

### 3.2. Restore desde tarball

```bash
# 1. Parar el servicio.
docker compose -f ~/homelab/stacks/<stack>/docker-compose.yml stop <servicio>

# 2. Vaciar el volumen (peligroso; revisar antes de ejecutar).
docker run --rm -v <volumen-named>:/data alpine:3.19 sh -c 'rm -rf /data/*'

# 3. Restaurar el contenido.
docker run --rm \
  -v <volumen-named>:/data \
  -v /mnt/hd2t/backups/dumps/docker-volumes/<servicio>:/backup:ro \
  alpine:3.19 \
  tar xzf /backup/<volumen>-2026-01-15.tar.gz -C /data

# 4. Levantar el servicio.
docker compose -f ~/homelab/stacks/<stack>/docker-compose.yml start <servicio>
```

### 3.3. Por qué este patrón **no** entra en `borgmatic.yml`

Tres razones:

1. **Un named volume del homelab es la excepción**, no la regla. Programar un hook genérico para algo que en el set por defecto no existe abre puerta a confusión.
2. **El nombre del volumen depende del proyecto Compose** (`<proyecto>_<volumen>` por convención). Si el operador renombra un stack, el hook fallaría en silencio.
3. **El uso es ad-hoc**: típicamente "estoy migrando este servicio que tiene un named volume legacy a bind mount; quiero un snapshot de seguridad antes". Esa intención cambia mes a mes; codificarla en `borgmatic.yml` la oxida.

---

## 4. Restore por servicio

Procedimientos canónicos referenciados desde `Backup → Restore (resumen)` de cada doc de servicio. Patrón general:

1. **`docker compose stop`** (no `down -v`: `down -v` borra volúmenes).
2. **Restaurar ficheros** desde Borg (con `borgmatic extract`) o desde el dump (con `pg_restore` / `mariadb` / `cp`).
3. **Ajustar ownership** si el operador `homelab` cambió de UID (raro).
4. **`docker compose up -d`** y verificar arranque.
5. **Validación funcional** específica del servicio (login, OCR, etc.).

### 4.1. Patrón general

```bash
# Suposiciones: <stack> = nombre del directorio en ~/homelab/stacks/.
#               El backup que se va a restaurar es de fecha YYYY-MM-DD.
ARCH="homelab-pi5-2026-01-15T03:00:00"
STACK="<stack>"

# 1. Parar el stack (preserva volúmenes y bind mounts).
cd ~/homelab/stacks/$STACK
docker compose --env-file /mnt/hd2t/services/$STACK/.env stop

# 2. Hacer copia de seguridad del estado actual (por si el restore va mal).
sudo mv /mnt/hd2t/services/$STACK /mnt/hd2t/services/$STACK.broken-$(date +%F-%H%M)

# 3. Restaurar desde Borg.
sudo install -d -o root -g root -m 700 /mnt/hd2t/services
sudo borgmatic extract \
  --archive "$ARCH" \
  --path "mnt/hd2t/services/$STACK" \
  --destination /

# Borgmatic extract con --destination / restaura en la ruta original.

# 4. Verificar permisos (UID/GID típicos: homelab 1000:1000, services específicos pueden tener su propio UID).
sudo ls -ld /mnt/hd2t/services/$STACK
# Esperado: drwx------ homelab homelab (o el UID/GID del servicio).

# 5. Levantar el stack.
docker compose --env-file /mnt/hd2t/services/$STACK/.env up -d

# 6. Verificar.
docker compose --env-file /mnt/hd2t/services/$STACK/.env ps
docker compose --env-file /mnt/hd2t/services/$STACK/.env logs --tail=100
```

> **Tras éxito**: `sudo rm -rf /mnt/hd2t/services/$STACK.broken-...` para liberar espacio. **Antes de borrar**: confirmar que la UI del servicio funciona, no solo que arranca.

### 4.2. Nextcloud

Resume el procedimiento ya esbozado en [`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md) §10.2. **Punto crítico**: `nextcloud/data/` y el dump de MariaDB **deben corresponder al mismo run de Borgmatic** (no mezclar fechas distintas).

```bash
ARCH="homelab-pi5-2026-01-15T03:00:00"
STACK="nextcloud"

cd ~/homelab/stacks/$STACK
docker compose --env-file /mnt/hd2t/services/$STACK/.env down   # OK aquí: data persistente está en bind mount, no en volúmenes named.

sudo mv /mnt/hd2t/services/$STACK /mnt/hd2t/services/$STACK.broken-$(date +%F)

# 1. Restaurar bind mounts (secrets, html, data, redis, db excepto db/data).
sudo borgmatic extract --archive "$ARCH" \
  --path "mnt/hd2t/services/$STACK" --destination /

# 2. La BD: opción A (desde dump consistente — recomendada).
#    Vaciar db/data para que MariaDB lo recree limpio al arrancar.
sudo rm -rf /mnt/hd2t/services/$STACK/db/data
sudo install -d -o 999 -g 999 -m 700 /mnt/hd2t/services/$STACK/db/data

# 3. Levantar SOLO MariaDB, esperar a que esté ready.
docker compose --env-file /mnt/hd2t/services/$STACK/.env up -d mariadb
until docker exec mariadb-nextcloud mariadb-admin ping -uroot \
        -p"$(sudo cat /mnt/hd2t/services/$STACK/secrets/db_root_password)" --silent 2>/dev/null; do
  sleep 2
done

# 4. Cargar el dump.
zcat /mnt/hd2t/backups/dumps/mariadb/nextcloud-2026-01-15.sql.gz \
  | docker exec -i mariadb-nextcloud sh -c \
      'mariadb -u root -p"$(cat /run/secrets/db_root_password)" nextcloud'

# 5. Levantar el resto.
docker compose --env-file /mnt/hd2t/services/$STACK/.env up -d

# 6. Reparación post-restore.
docker exec -u www-data nextcloud php occ maintenance:repair --include-expensive
docker exec -u www-data nextcloud php occ files:scan --all
```

| Paso | Por qué |
|---|---|
| Vaciar `db/data` y dejar que MariaDB lo recree | Restaurar `db/data/` "tal cual" desde Borg arrastra inconsistencias del estado vivo (páginas no flusheadas). El dump es la fuente de verdad. |
| `occ maintenance:repair --include-expensive` | Reconstruye `oc_filecache` y refs internas. Tras un restore "limpio" siempre se ejecuta. |
| `occ files:scan --all` | Re-indexa los ficheros que la BD acaba de redescubrir. Pesado en bibliotecas grandes (>1 h por TB) pero imprescindible. |

> **Variante "restore desde db/data/"** (no recomendada): si el operador prefiere restaurar el directorio vivo en lugar del dump (porque el dump está corrupto, p. ej.), copiar `db/data` desde Borg igual que el resto. Riesgo: páginas inconsistentes. Solo aceptable si el dump no existe.

### 4.3. Authelia

[`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §11. **Punto crítico**: `db.sqlite3` y `secrets/storage_encryption` son indisociables — restaurar uno sin el otro inutiliza el otro.

```bash
ARCH="homelab-pi5-2026-01-15T03:00:00"
STACK="auth"

cd ~/homelab/stacks/$STACK
docker compose --env-file /mnt/hd2t/services/$STACK/.env down

sudo mv /mnt/hd2t/services/$STACK /mnt/hd2t/services/$STACK.broken-$(date +%F)

# 1. Restaurar todo el stack (incluye config, secrets, redis y authelia/config/db.sqlite3).
sudo borgmatic extract --archive "$ARCH" \
  --path "mnt/hd2t/services/$STACK" --destination /

# 2. Verificar el par crítico:
sudo ls -l /mnt/hd2t/services/$STACK/secrets/storage_encryption \
            /mnt/hd2t/services/$STACK/authelia/config/db.sqlite3
# Ambos deben existir, ambos del mismo snapshot.

# 3. Si el dump declarativo de Borgmatic generó una versión más limpia del SQLite,
#    sustituir el extraído por el de dumps/:
sudo cp /mnt/hd2t/backups/dumps/sqlite/authelia-2026-01-15.sqlite3 \
  /mnt/hd2t/services/$STACK/authelia/config/db.sqlite3
sudo chown homelab:homelab /mnt/hd2t/services/$STACK/authelia/config/db.sqlite3

# 4. Levantar.
docker compose --env-file /mnt/hd2t/services/$STACK/.env up -d

# 5. Validar:
docker logs --tail=30 authelia
# Esperado: "users database loaded with N users", sin "encryption key invalid".

# 6. Probar login en https://auth.lan con un usuario conocido y su TOTP.
```

> **Si el TOTP falla tras el restore**: la `storage_encryption` extraída no corresponde al `db.sqlite3` extraído (mezcla de fechas). Volver al snapshot anterior coincidente, o forzar reset de TOTP del usuario afectado (`authelia storage user totp delete <user>`).

### 4.4. Bookstack (MariaDB)

```bash
ARCH="homelab-pi5-2026-01-15T03:00:00"
STACK="bookstack"

cd ~/homelab/stacks/$STACK
docker compose --env-file /mnt/hd2t/services/$STACK/.env down

sudo mv /mnt/hd2t/services/$STACK /mnt/hd2t/services/$STACK.broken-$(date +%F)

# 1. Restaurar bind mounts.
sudo borgmatic extract --archive "$ARCH" \
  --path "mnt/hd2t/services/$STACK" --destination /

# 2. Vaciar db/data (la BD se reconstruirá desde el dump).
sudo rm -rf /mnt/hd2t/services/$STACK/db/data
sudo install -d -o 999 -g 999 -m 700 /mnt/hd2t/services/$STACK/db/data

# 3. Levantar solo MariaDB.
docker compose --env-file /mnt/hd2t/services/$STACK/.env up -d mariadb
until docker exec mariadb-bookstack mariadb-admin ping --silent 2>/dev/null; do sleep 2; done

# 4. Cargar el dump.
zcat /mnt/hd2t/backups/dumps/mariadb/bookstack-2026-01-15.sql.gz \
  | docker exec -i mariadb-bookstack sh -c \
      'mariadb -u root -p"$(cat /run/secrets/db_root_password)" bookstack'

# 5. Levantar bookstack-app.
docker compose --env-file /mnt/hd2t/services/$STACK/.env up -d
```

> Bookstack no tiene un comando de "repair" equivalente a `occ`: si la BD restaurada está sana, la app arranca limpia.

### 4.5. Vaultwarden (SQLite)

```bash
ARCH="homelab-pi5-2026-01-15T03:00:00"
STACK="vaultwarden"

cd ~/homelab/stacks/$STACK
docker compose --env-file /mnt/hd2t/services/$STACK/.env stop vaultwarden

# 1. Reemplazar el SQLite con el dump consistente.
sudo cp /mnt/hd2t/backups/dumps/sqlite/vaultwarden-2026-01-15.sqlite3 \
  /mnt/hd2t/services/$STACK/data/db.sqlite3
sudo chown -R 1000:1000 /mnt/hd2t/services/$STACK/data/db.sqlite3

# 2. Restaurar attachments, sends, rsa_key.* (no son BD, basta cp).
sudo borgmatic extract --archive "$ARCH" \
  --path "mnt/hd2t/services/$STACK/data/attachments" --destination /
sudo borgmatic extract --archive "$ARCH" \
  --path "mnt/hd2t/services/$STACK/data/sends" --destination /
sudo borgmatic extract --archive "$ARCH" \
  --path "mnt/hd2t/services/$STACK/data/rsa_key.pem" --destination /
sudo borgmatic extract --archive "$ARCH" \
  --path "mnt/hd2t/services/$STACK/data/rsa_key.pub.pem" --destination /

# 3. Levantar.
docker compose --env-file /mnt/hd2t/services/$STACK/.env up -d
```

> **El `rsa_key.*` es crítico**: Vaultwarden lo usa para firmar JWTs de sesión. Si se pierde, todos los clientes deben re-loguearse (no es desastre). Si se *desincroniza* del SQLite (dos snapshots distintos), todos los `auth_request` fallan hasta que se re-genera.

### 4.6. Samba (TDB + config)

[`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md) §11.2.

```bash
ARCH="homelab-pi5-2026-01-15T03:00:00"
STACK="samba"

cd ~/homelab/stacks/$STACK
docker compose --env-file /mnt/hd2t/services/$STACK/.env down

# 1. Restaurar config + private (TDBs) + secrets + .env.
sudo borgmatic extract --archive "$ARCH" \
  --path "mnt/hd2t/services/$STACK" --destination /

# 2. Si hay .bak de tdbbackup, restaurar el .bak sobre el .tdb (es la versión validada).
sudo cp /mnt/hd2t/services/$STACK/private/passdb.tdb.bak \
        /mnt/hd2t/services/$STACK/private/passdb.tdb
sudo cp /mnt/hd2t/services/$STACK/private/secrets.tdb.bak \
        /mnt/hd2t/services/$STACK/private/secrets.tdb

# 3. Restaurar shares (los datos compartidos).
sudo borgmatic extract --archive "$ARCH" \
  --path "mnt/hd2t/shares/homelab" --destination /

# 4. Levantar.
docker compose --env-file /mnt/hd2t/services/$STACK/.env up -d

# 5. Probar login con cliente conocido.
smbclient -L //pi5.lan -U homelab
```

### 4.7. Syncthing

[`../06-almacenamiento/03-syncthing.md`](../06-almacenamiento/03-syncthing.md) §10.2. **Punto crítico**: preservar `cert.pem`/`key.pem` originales (cambian el Device ID si se regeneran).

```bash
ARCH="homelab-pi5-2026-01-15T03:00:00"
STACK="syncthing"

cd ~/homelab/stacks/$STACK
docker compose --env-file /mnt/hd2t/services/$STACK/.env down

# 1. Restaurar config (incluye cert.pem, key.pem, config.xml; NO incluye index-*.db por exclude).
sudo borgmatic extract --archive "$ARCH" \
  --path "mnt/hd2t/services/$STACK/config" --destination /

# 2. Restaurar /mnt/hd2t/sync (carpetas compartidas).
sudo borgmatic extract --archive "$ARCH" --path "mnt/hd2t/sync" --destination /

# 3. NO restaurar index-*.db (Syncthing los reconstruye al arrancar; el rescan inicial puede tardar horas en bibliotecas grandes pero es lo correcto).

# 4. Levantar.
docker compose --env-file /mnt/hd2t/services/$STACK/.env up -d

# 5. Verificar Device ID en la GUI:
docker exec syncthing syncthing --device-id
# Comparar con el ID histórico guardado en notas; si difiere, los peers verán "Disconnected" y hay que re-aceptar.
```

### 4.8. Servicios SQLite simples (Linkding, FreshRSS, Uptime Kuma, Sonarr, Radarr, Prowlarr, Stash, Mealie)

Patrón unificado:

```bash
ARCH="homelab-pi5-2026-01-15T03:00:00"
STACK="<stack>"
DB_FILE="<ruta-relativa-a-/mnt/hd2t/services/$STACK>/db.sqlite3"   # cada servicio difiere

cd ~/homelab/stacks/$STACK
docker compose --env-file /mnt/hd2t/services/$STACK/.env stop

# 1. Restaurar todo el bind mount.
sudo borgmatic extract --archive "$ARCH" \
  --path "mnt/hd2t/services/$STACK" --destination /

# 2. (Recomendado) sustituir el SQLite vivo por el dump declarativo.
sudo cp /mnt/hd2t/backups/dumps/sqlite/<servicio>-2026-01-15.sqlite3 \
  /mnt/hd2t/services/$STACK/$DB_FILE

# 3. Permisos.
sudo chown -R <uid>:<gid> /mnt/hd2t/services/$STACK/$DB_FILE

# 4. Levantar.
docker compose --env-file /mnt/hd2t/services/$STACK/.env up -d
```

Rutas concretas por servicio (consultar el doc del servicio si difiere):

| Servicio | Path del SQLite | UID:GID típico |
|---|---|---|
| Uptime Kuma | `data/kuma.db` | `1000:1000` |
| Linkding | `data/db.sqlite3` | `33:33` (www-data) |
| FreshRSS | `data/db.sqlite` | `33:33` |
| Vaultwarden | `data/db.sqlite3` | `1000:1000` |
| Sonarr/Radarr/Prowlarr | `config/<servicio>.db` | `1000:1000` |
| Stash | `config/stash-go.sqlite` | `1000:1000` |
| Grafana | `data/grafana.db` | `472:472` |

### 4.9. Restore de un fichero suelto

Caso "el operador borró por accidente un fichero ayer". No hace falta tocar contenedores ni dumps:

```bash
sudo install -d -o root -g root -m 700 /tmp/restore

sudo borgmatic extract \
  --archive 'homelab-pi5-2026-01-14T03:00:00' \
  --path 'mnt/hd2t/services/nextcloud/data/user1/files/important.pdf' \
  --destination /tmp/restore

sudo cp /tmp/restore/mnt/hd2t/services/nextcloud/data/user1/files/important.pdf \
  /mnt/hd2t/services/nextcloud/data/user1/files/important.pdf
sudo chown 33:33 /mnt/hd2t/services/nextcloud/data/user1/files/important.pdf

# Decirle a Nextcloud que re-escanee ese usuario.
docker exec -u www-data nextcloud php occ files:scan user1

sudo rm -rf /tmp/restore
```

---

## 5. Watchtower lifecycle hooks (`pre-update` / `post-update`)

[`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §52 activa `WATCHTOWER_LIFECYCLE_HOOKS=true`. Esto permite que cada contenedor declare scripts que se ejecutan **dentro del contenedor antiguo** justo antes de pararlo (y opcionalmente en el nuevo tras arrancar).

### 5.1. Por qué este patrón

Un upgrade de imagen (Nextcloud 30.x → 31.x, MariaDB 11.x → 12.x) puede requerir migraciones de schema **irreversibles**. Si el upgrade se rompe a medias, sin un dump consistente del estado pre-upgrade el operador queda en limbo: ni la versión vieja arranca (su BD ya está parcialmente migrada) ni la nueva (la migración falló). El `pre-update` garantiza un punto de retorno **para cada upgrade**, no solo el snapshot diario de Borgmatic (que puede ser de hace 23 h).

Ventajas frente a "esperar al backup nocturno antes de un upgrade":

- **Atómico con el upgrade**: el dump se hace en el segundo previo al stop. La BD no ha cambiado un byte entre el dump y el shutdown.
- **No requiere intervención del operador**: Watchtower lo invoca; el operador solo decide si quiere upgrades automáticos.
- **Si el dump falla, el upgrade no se hace**: exit code ≠ 0 cancela el upgrade. Watchtower deja el contenedor antiguo corriendo y notifica.

### 5.2. Convenciones de path

Los `pre-update` escriben a un bind mount **dentro del propio servicio**, no a `/mnt/hd2t/backups/dumps/` (lo escribe Borgmatic, no Watchtower):

- Convención: `/mnt/hd2t/services/<stack>/<servicio>/backups/pre-update-<servicio>-YYYY-MM-DDTHHMM.sql.gz`.
- Modo: `0700` del directorio padre, `0600` del fichero.
- Lifecycle: el siguiente backup nocturno de Borgmatic los archiva (entran en `/mnt/hd2t/services` que es `source_directory`); un `find ... -mtime +14 -delete` opcional en `after_backup` los limpia (mismo lifecycle que `dumps/`).

### 5.3. Ejemplo: Nextcloud (MariaDB)

`/mnt/hd2t/services/nextcloud/scripts/pre-update.sh`:

```bash
#!/bin/sh
# Pre-update hook ejecutado por Watchtower DENTRO del contenedor `nextcloud` antiguo
# justo antes del stop. El bind mount /mnt/hd2t/services/nextcloud/scripts/
# está montado como /scripts dentro del contenedor.
#
# El servicio mariadb-nextcloud sigue corriendo (Watchtower no lo para; solo para `nextcloud`).
# Por tanto el dump se hace contra él vía red `homelab` interna.
set -eu

DEST_DIR="/data/backups"
DEST_FILE="$DEST_DIR/pre-update-nextcloud-$(date +%FT%H%M).sql.gz"
mkdir -p "$DEST_DIR"
chmod 700 "$DEST_DIR"

# Modo mantenimiento: evita escrituras concurrentes durante el dump.
php /var/www/html/occ maintenance:mode --on

# Dump consistente desde el contenedor de la BD (al cual nextcloud puede llamar por red Docker).
mysqldump --single-transaction --routines --triggers --events \
  -h mariadb-nextcloud -uroot -p"$(cat /run/secrets/db_root_password)" nextcloud \
  | gzip -c > "$DEST_FILE"

chmod 600 "$DEST_FILE"

# Modo mantenimiento OFF (el contenedor va a parar igual; mejor dejarlo coherente).
php /var/www/html/occ maintenance:mode --off

# Validar que el dump no está vacío.
[ -s "$DEST_FILE" ] || { echo "Dump vacío: $DEST_FILE" >&2; exit 1; }
echo "Pre-update dump OK: $DEST_FILE"
```

Etiquetas en el `docker-compose.yml` del stack `nextcloud`:

```yaml
nextcloud:
  # ... resto del compose ...
  volumes:
    - /mnt/hd2t/services/nextcloud/scripts:/scripts:ro
    - /mnt/hd2t/services/nextcloud/backups:/data/backups
  labels:
    com.centurylinklabs.watchtower.enable: "true"
    com.centurylinklabs.watchtower.lifecycle.pre-update: "/scripts/pre-update.sh"
    com.centurylinklabs.watchtower.lifecycle.pre-update-timeout: "300"   # 5 min
    com.centurylinklabs.watchtower.lifecycle.post-update: "/scripts/post-update.sh"
```

### 5.4. Ejemplo: Bookstack (MariaDB)

Estructura idéntica. `pre-update.sh`:

```bash
#!/bin/sh
set -eu
DEST="/data/backups/pre-update-bookstack-$(date +%FT%H%M).sql.gz"
mkdir -p /data/backups && chmod 700 /data/backups
mariadb-dump --single-transaction --routines --triggers --events \
  -h mariadb-bookstack -ubookstack -p"$(cat /run/secrets/db_password)" bookstack \
  | gzip -c > "$DEST"
chmod 600 "$DEST"
[ -s "$DEST" ] || exit 1
```

### 5.5. Ejemplo: Vaultwarden (SQLite)

Vaultwarden corre como un único contenedor (sin BD lateral). `pre-update.sh`:

```bash
#!/bin/sh
set -eu
DEST="/data/backups/pre-update-vw-$(date +%FT%H%M).sqlite3"
mkdir -p /data/backups && chmod 700 /data/backups
sqlite3 /data/db.sqlite3 ".backup '$DEST'"
chmod 600 "$DEST"
[ -s "$DEST" ] || exit 1
```

### 5.6. `post-update` (opcional)

Útil para healthcheck post-upgrade que valide algo más allá del HTTP 200. Ejemplo simple:

```bash
#!/bin/sh
# post-update: ejecutado en el contenedor NUEVO tras arrancar.
set -eu
sleep 10
php /var/www/html/occ status | grep -q '"installed":true' || {
  echo "occ status no reporta installed=true" >&2
  exit 1
}
```

> **Cuidado con `exit ≠ 0` en `post-update`**: Watchtower no rollbackea. El contenedor nuevo queda corriendo y solo se registra una notificación de fallo. El rollback manual es: parar, restaurar el SQLite/MariaDB desde el dump pre-update, recrear con el tag anterior. Por eso el `post-update` es opcional y se reserva para diagnóstico.

### 5.7. Servicios `enable: "false"` y upgrades manuales

Para los servicios excluidos de Watchtower (BD, Pi-hole, Authelia, Home Assistant, Portainer — ver [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6), el patrón es manual:

```bash
# Antes del upgrade manual:
sudo borgmatic create --verbosity 1   # snapshot completo, no solo el dump.

# Editar tag en .env y aplicar:
docker compose pull <servicio>
docker compose up -d --force-recreate <servicio>

# Si rompe: restore del último snapshot (§4 del doc del servicio).
```

---

## 6. Smoke test L3 (mensual)

Procedimiento canónico de **verificación de restauración** referenciado por:

- [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §8.3.
- [`./02-borgmatic.md`](./02-borgmatic.md) §13.3.

> "Un backup que no se ha restaurado nunca no es un backup, es una esperanza." — el smoke test L3 es lo que convierte la esperanza en hecho.

### 6.1. Por qué L3 además de L1 y L2

| Nivel | Qué prueba | Qué NO prueba |
|---|---|---|
| **L1** (`borg check --repository-only`, diaria) | Estructura del repo Borg (índice coherente). | Que los blobs cifrados representan datos reales del homelab. |
| **L2** (`borg check --verify-data`, mensual) | Que cada blob tiene HMAC válido. Detecta bit-rot. | Que el contenido descifrado **es semánticamente útil** (un dump de Postgres puede tener HMAC válido y estar vacío por un fallo del hook). |
| **L3** (smoke test, mensual) | Que un servicio real puede **arrancar** desde el backup. Cubre todo lo que L1 y L2 no ven: hooks que escribieron 0 bytes, secrets desincronizados con BD, paths excluidos por error, permisos rotos, versión de imagen incompatible con el dump. | — (es el último filtro). |

### 6.2. Calendario de rotación

| Mes | Servicio | Motor | Por qué este mes |
|---|---|---|---|
| 1, 5, 9 (cada 4) | **Vaultwarden** | SQLite | Crítico (passwords del operador). Pequeño (~MB). Tiempo de restore: minutos. |
| 2, 6, 10 | **Authelia** | SQLite + secrets indisociables | Cubre el caso "par crítico" (db + storage_encryption). |
| 3, 7, 11 | **Bookstack** | MariaDB | Cubre el motor MariaDB (Nextcloud lo cubre indirectamente cuando toca Nextcloud-mini). |
| 4, 8, 12 | **Nextcloud-mini** | PostgreSQL/MariaDB + ficheros | "Mini" = solo dump y `nextcloud/html/`, sin restaurar `data/` masivo. Cubre el motor relacional + el ciclo `occ maintenance:repair`. |

> **Ad-hoc**: si un mes el operador no puede rotar (vacaciones, emergencia), saltar. **No** repetir Vaultwarden cada mes "por comodidad" — el objetivo es cubrir la matriz de motores y patrones.

### 6.3. Procedimiento paso a paso

Ejemplo: smoke test de **Vaultwarden** en M1 (enero 2026).

```bash
# 1. Listar snapshots disponibles, elegir el del día anterior.
sudo borgmatic list
# Salida: homelab-pi5-2026-01-14T03:00:00, homelab-pi5-2026-01-13T03:00:00, ...
ARCH="homelab-pi5-2026-01-14T03:00:00"

# 2. Crear directorio de prueba.
DEST="/mnt/hd2t/backups/restore-test/vaultwarden-$(date +%F)"
sudo install -d -o root -g root -m 700 "$DEST"

# 3. Extraer el bind mount de Vaultwarden completo.
sudo borgmatic extract \
  --archive "$ARCH" \
  --path 'mnt/hd2t/services/vaultwarden' \
  --destination "$DEST"

# 4. Inspección "a mano":
sudo ls -la "$DEST/mnt/hd2t/services/vaultwarden/data"
# Esperado: db.sqlite3 (>0 bytes), attachments/, sends/, rsa_key.pem, rsa_key.pub.pem.

sudo file "$DEST/mnt/hd2t/services/vaultwarden/data/db.sqlite3"
# Esperado: SQLite 3.x database, last written using SQLite version ...

sudo sqlite3 "$DEST/mnt/hd2t/services/vaultwarden/data/db.sqlite3" \
  "SELECT count(*) FROM users;"
# Esperado: número plausible (≥ 1, igual al esperado por el operador).

# 5. (Opcional, recomendado) levantar un compose paralelo.
cd /tmp && mkdir vw-restore && cd vw-restore
cat > docker-compose.yml <<'EOF'
services:
  vw-test:
    image: vaultwarden/server:latest
    container_name: vw-restore-test
    environment:
      DOMAIN: http://localhost:8181
      WEBSOCKET_ENABLED: "false"
    ports:
      - "127.0.0.1:8181:80"
    volumes:
      - "${DEST_PATH}:/data"
EOF
sudo DEST_PATH="$DEST/mnt/hd2t/services/vaultwarden/data" docker compose up -d

# 6. Verificar que arranca y la UI responde.
sleep 10
curl -fsv http://localhost:8181/alive   # endpoint de health
# Esperado: HTTP 200 OK.

# 7. Limpiar.
sudo docker compose -p vw-restore down -v
sudo rm -rf "$DEST" /tmp/vw-restore

# 8. Anotar el resultado.
echo "$(date -u +%FT%TZ) | vaultwarden | $ARCH | OK | Restore + arranque + /alive 200 OK." \
  >> ~/homelab/operations/restore-tests.log
git -C ~/homelab add operations/restore-tests.log
git -C ~/homelab commit -m "ops: smoke test Vaultwarden 2026-01"
```

### 6.4. Hallazgos típicos

Lo normal en los primeros 6 meses es encontrar **un fallo pequeño cada smoke test**. Eso es exactamente para lo que sirve. Casos reales esperables:

- **Dump vacío (0 bytes)**: el hook `before_backup` falló silenciosamente porque `mariadb-dump` exit ≠ 0 pero el `| gzip -c > file` deja un fichero vacío en `file`. **Acción**: añadir `[ -s "$DEST" ] || exit 1` al final del hook.
- **`secrets/storage_encryption` no encontrado**: el `exclude_patterns` capturaba más de lo previsto. **Acción**: revisar `exclude_patterns` en `borgmatic.yml` §6.
- **Dump válido pero contenedor de prueba no arranca**: la versión de imagen `latest` es incompatible con el schema del dump (la app de prod estaba en un major anterior). **Acción**: anotar la versión exacta en el `docker-compose.yml` de prueba (`vaultwarden/server:1.30.5-alpine`).
- **Permisos rotos**: el `borgmatic extract` extrae con UID/GID del archivo (Borg los preserva), pero si el operador cambió de UID en el host real el restore "real" requeriría `chown`. **Acción**: documentar en el procedimiento del servicio.

Cada hallazgo se convierte en un commit en `~/homelab/`. Sin smoke test, se acumulan invisibles hasta el día del incidente.

### 6.5. Variante "Nextcloud-mini"

Para Nextcloud el smoke test completo (con `data/` real) es caro: TBs de ficheros, horas de extract. La variante **mini** prueba solo lo crítico:

```bash
ARCH="homelab-pi5-2026-04-14T03:00:00"
DEST="/mnt/hd2t/backups/restore-test/nextcloud-mini-$(date +%F)"
sudo install -d -o root -g root -m 700 "$DEST"

# 1. Extraer SOLO el dump y los secrets (sin data/).
sudo borgmatic extract --archive "$ARCH" \
  --path 'mnt/hd2t/services/nextcloud/secrets' --destination "$DEST"
sudo borgmatic extract --archive "$ARCH" \
  --path 'mnt/hd2t/backups/dumps/mariadb' --destination "$DEST"

# 2. Levantar un MariaDB temporal con el dump cargado.
docker run --rm -d --name mariadb-test \
  -e MARIADB_ROOT_PASSWORD=test -e MARIADB_DATABASE=nextcloud \
  -p 127.0.0.1:33306:3306 \
  mariadb:11
sleep 15

zcat "$DEST/mnt/hd2t/backups/dumps/mariadb/nextcloud-2026-04-14.sql.gz" \
  | docker exec -i mariadb-test mariadb -uroot -ptest nextcloud

# 3. Smoke check: ¿hay tablas, hay usuarios?
docker exec mariadb-test mariadb -uroot -ptest -e \
  "SELECT count(*) AS users FROM nextcloud.oc_users;
   SELECT count(*) AS files FROM nextcloud.oc_filecache;"
# Esperado: counts plausibles.

# 4. Limpiar.
docker rm -f mariadb-test
sudo rm -rf "$DEST"

# 5. Anotar.
echo "$(date -u +%FT%TZ) | nextcloud-mini | $ARCH | OK | dump cargado, oc_users=N, oc_filecache=M" \
  >> ~/homelab/operations/restore-tests.log
```

### 6.6. Script de soporte

[`./02-borgmatic.md`](./02-borgmatic.md) §13.4 documenta `borg-smoke-test.sh`, el helper opcional que automatiza pasos 1-3 y 7. La inspección manual (paso 4) y la validación funcional (paso 5-6) **no se automatizan** a propósito: el operador debe mirar con ojos humanos para detectar regresiones que un check binario no captura.

---

## 7. Disaster recovery — orden de restauración de datos

[`../13-operaciones/02-disaster-recovery.md`](../13-operaciones/02-disaster-recovery.md) cubre el procedimiento end-to-end ("Pi nueva → homelab funcionando"). Este apartado documenta solo la **parte de datos**: una vez que la Pi base está lista (OS, Docker, red `homelab`, repo `~/homelab/` clonado), en qué orden se restauran los servicios.

### 7.1. Orden recomendado

| Fase | Servicios | Por qué este orden |
|---|---|---|
| **1. Secrets y configs base** | `/mnt/hd2t/services/*/secrets/`, `/etc/`, `~/homelab/` | Sin secrets, los siguientes contenedores no arrancan. Sin `~/homelab/` no hay `docker-compose.yml`. |
| **2. Red y DNS** | Pi-hole, Unbound, Caddy ([`../03-red/`](../03-red/)) | Sin DNS interno (`*.lan`) los servicios no se ven entre ellos por nombre. Sin Caddy no hay HTTPS interno (smoke tests de UI fallan). |
| **3. Identidad** | Authelia ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)) | Su backup tiene un par crítico (db + storage_encryption). Mejor restaurarlo temprano y sin presión: si falla, todavía no se ha tocado el resto. |
| **4. Bases de datos** | MariaDB y PostgreSQL de Nextcloud, Bookstack, Paperless-ngx, Mealie (los que tengan BD) | Cargar dumps requiere los contenedores de BD funcionando. Es una fase larga (cargar dumps grandes tarda decenas de min). |
| **5. Almacenamiento** | Nextcloud, Samba, Syncthing, MinIO ([`../06-almacenamiento/`](../06-almacenamiento/)) | Los servicios de almacenamiento arrancan apuntando a sus BD ya cargadas + bind mounts restaurados. |
| **6. Reverse proxy + auth** | Caddy listo, Authelia funcionando, las UIs de los servicios anteriores accesibles | Validar que el operador puede llegar al GUI de Nextcloud, Vaultwarden, Bookstack desde el navegador. |
| **7. Resto de servicios** | Multimedia, descargas, productividad, dashboards | Sin urgencia: si el resto está bien, estos pueden levantar progresivamente sin afectar al "núcleo" del homelab. |
| **8. Monitorización y backups** | Prometheus, Grafana, Uptime Kuma, Borgmatic timers | Reactivar los timers `borgmatic-*.timer` solo al final, cuando el resto está sano. Antes, el primer backup post-recovery saldría con datos parciales y desalinearía la retención GFS. |

### 7.2. Comandos resumen

```bash
# Asume: hd2t montado, docker activo, ~/homelab/ clonado, /mnt/hd2t/backups/borg/ presente.
# Si /mnt/hd2t/backups/borg/ no sobrevivió, primero:
#   sudo rclone --config <conf> sync b2:homelab-borg/ /mnt/hd2t/backups/borg/

# 1. Recuperar la passphrase desde KeePassXC/sobre/Vaultwarden externo.
sudo install -m 600 /tmp/passphrase.txt /etc/borgmatic/.passphrase   # luego shred -u el temporal.

# 2. Reaplicar config de Borgmatic.
sudo install -d -m 700 /etc/borgmatic
sudo install -m 600 ~/homelab/operations/borgmatic.config.yaml /etc/borgmatic/config.yaml
sudo borgmatic config validate

# 3. Localizar el último archivo del repo.
sudo borgmatic list
ARCH="homelab-pi5-2026-01-14T03:00:00"   # el último OK conocido.

# 4. Restaurar /etc selectivo (NO restaurar /etc completo: rompe el sistema base).
sudo borgmatic extract --archive "$ARCH" \
  --path 'etc/ssh' 'etc/fstab' 'etc/ufw' 'etc/fail2ban' --destination /

# 5. Restaurar /mnt/hd2t/services entero (todos los stacks).
sudo borgmatic extract --archive "$ARCH" --path 'mnt/hd2t/services' --destination /

# 6. Restaurar /mnt/hd2t/sync (datos de Syncthing).
sudo borgmatic extract --archive "$ARCH" --path 'mnt/hd2t/sync' --destination /

# 7. Levantar los stacks en el orden de la tabla §7.1, validando cada uno.
for STACK in dns auth proxy; do
  cd ~/homelab/stacks/$STACK
  docker compose --env-file /mnt/hd2t/services/$STACK/.env up -d
  docker compose --env-file /mnt/hd2t/services/$STACK/.env ps
done

# 8. Para cada servicio con BD: cargar dump (§4.2, §4.3, §4.4).

# 9. Reactivar timers de backup solo al final.
sudo systemctl enable --now borgmatic-daily.timer borgmatic-weekly.timer borgmatic-monthly.timer
```

> **Verificación post-DR**: `docker ps -a | grep -v Up` para ver contenedores rotos. `docker logs --tail 50 <c>` para cada uno hasta que la lista quede limpia.

---

## 8. Lista de Verificación

Antes de considerar este doc "operativo":

- [ ] El operador ha leído [`./01-estrategia-backup.md`](./01-estrategia-backup.md) y [`./02-borgmatic.md`](./02-borgmatic.md) **antes** de este doc.
- [ ] `sudo borgmatic list` muestra al menos un snapshot reciente.
- [ ] `sudo ls /mnt/hd2t/backups/dumps/` lista al menos `postgresql/`, `mariadb/`, `sqlite/` con dumps recientes (≤ 1 día) si los servicios correspondientes están desplegados.
- [ ] `~/homelab/operations/restore-tests.log` existe y está versionado en git (puede estar vacío en el primer mes).
- [ ] Para cada servicio con `pre-update` Watchtower (Nextcloud, Bookstack, Vaultwarden si está): el script `pre-update.sh` existe en `/mnt/hd2t/services/<stack>/scripts/`, es ejecutable (`chmod +x`), y la label `com.centurylinklabs.watchtower.lifecycle.pre-update` apunta a su path **dentro del contenedor**.
- [ ] Smoke test L3 ejecutado al menos una vez con éxito y anotado en `restore-tests.log`. Mensaje del commit: `ops: smoke test <servicio> <YYYY-MM>`.
- [ ] Calendario del operador tiene recordatorio mensual: smoke test rotando servicio según §6.2.
- [ ] El operador tiene en notas la **lista de UIDs/GIDs por servicio** (§4.8 los lista; cada doc de servicio los confirma) para evitar `chown` mal aplicado tras un restore.
- [ ] Probado al menos una vez: `sudo borgmatic extract --archive <último> --path mnt/hd2t/services/<un-servicio> --destination /tmp/test` extrae sin errores y los ficheros tienen contenido coherente.

---

## 9. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `sudo borgmatic extract ...` falla con `borg: error: argument --path: invalid choice` | Versión de Borgmatic anterior a 1.7 con sintaxis incompatible. | Confirmar `borgmatic --version`. En 1.7+ es `extract --archive ... --path ...`. En 1.5-1.6 era `extract <archivo> <path>`. Adaptar al binario instalado. |
| `borgmatic extract` tarda horas en restaurar `nextcloud/data/` | Es esperado en bibliotecas grandes (>500 GB). Sin `--progress`, no hay feedback. | Añadir `--progress` al comando. Si la velocidad <50 MB/s sostenidos en hd2t local, revisar `iotop` para descartar contención con otro servicio. Reducir paralelismo si Borg está chunkeando otra cosa (raro durante extract). |
| Tras restore de Nextcloud, la UI muestra "no se puede descargar" para muchos ficheros | `oc_filecache` tiene refs a inodes que no existen (mezcla de fechas dump+data). | Ejecutar `docker exec -u www-data nextcloud php occ files:scan --all`. Tarda decenas de min por TB pero reconstruye refs. Si tras eso siguen los warnings, el snapshot tenía `data/` y `db/` desalineados — repetir restore con archivo coincidente. |
| Tras restore de Authelia, el TOTP de un usuario no funciona | `db.sqlite3` y `secrets/storage_encryption` provienen de fechas distintas. | Validar `sudo file /mnt/hd2t/services/auth/secrets/storage_encryption` y la mtime del `db.sqlite3` extraído. Si difieren, restaurar ambos del **mismo** archivo. Si la pérdida es inevitable, borrar TOTP del usuario y forzar re-enroll: `docker exec authelia authelia storage user totp delete <user>`. |
| `pre-update` de Watchtower falla con `Lifecycle hook failed: exit status 127` | El script no existe dentro del contenedor o no es ejecutable. Watchtower busca en el contenedor antiguo, no en el host. | `docker exec <servicio> ls -l /scripts/pre-update.sh` debe mostrar `-rwxr-xr-x`. Si no, ajustar el bind mount y `chmod +x` desde el host (el modo se preserva). |
| `pre-update` exit ≠ 0 cancela todos los upgrades del ciclo de Watchtower | Comportamiento correcto. Watchtower cancela el upgrade del contenedor afectado, no toca al resto. | Revisar el log: `docker logs watchtower | grep -A 5 pre-update`. Probar el script a mano: `docker exec <servicio> /scripts/pre-update.sh`. Corregir, dejar que el siguiente ciclo lo intente. |
| `pg_restore` falla con `role "postgres" does not exist` | El dump fue tomado con `--owner` (sin `--no-owner`) y se está restaurando a un cluster con roles distintos. | Re-tomar el dump con `--no-owner --no-privileges` (el patrón canónico §2.1 ya lo hace). Si no se puede re-tomar, restaurar con `pg_restore --no-owner --no-privileges` igualmente — se ignoran los `ALTER OWNER`. |
| `mariadb` (cliente) falla al cargar el dump con `ERROR 1142 ... command denied to user 'root'` | El dump contiene `DEFINER='user'@'host'` que no existe en el destino. Aparece con `--routines/--triggers/--events`. | Strip de los DEFINER en el dump: `zcat foo.sql.gz | sed -E 's/DEFINER=[^*]*\*/\*/g' | gzip -c > foo.fixed.sql.gz`. Cargar el `.fixed`. |
| El smoke test L3 reporta "OK" pero la app no funciona en producción | El smoke test arrancó solo la app, no validó funcionalidad real. | Mejorar el smoke test del servicio concreto: añadir un `curl` a un endpoint que exija BD (no solo `/alive`/`/health`). Añadir el patrón al `restore-tests.log` para futuros tests. |
| `docker run --rm ... alpine tar czf ...` (snapshot de named volume) deja tarball corrupto | El contenedor que escribe en el volumen sigue activo durante el `tar`. | Parar el contenedor antes del `tar` (`docker compose stop <servicio>`), tarballear, arrancar. La ventana de parada es proporcional al tamaño del volumen. |
| Restore "sobre" un servicio en marcha deja BD híbrida (mitad vieja, mitad nueva) | El operador olvidó parar el servicio antes de copiar ficheros. | **Siempre** `docker compose stop` antes del restore. Si pasó: parar ahora, restaurar de nuevo desde Borg (idempotente), arrancar. |
| `sudo borgmatic extract --destination /` machaca ficheros del host | Comportamiento esperado: `--destination /` restaura en la ruta original. Si Borg incluyó `/etc` en `source_directories`, restaurar todo `etc/` machacaría `/etc/`. | Restaurar siempre con `--path` selectivo. **Nunca** `borgmatic extract --destination /` sin `--path`. |
| Tras un disaster recovery, los timers de Borgmatic no disparan | El timer `Persistent=true` se basa en `/var/lib/systemd/timers/`. En un OS recién flasheado ese directorio está vacío y el timer cree que el último run fue hace años. | Esperar a la siguiente hora programada (no se reactiva nada hasta entonces) o forzar un primer run manual: `sudo systemctl start borgmatic-daily.service`. |
| `restore-tests.log` se desincroniza entre operadores (varios commits con misma fecha) | Conflicto de merge en git. | El fichero es append-only por convención. Resolver el conflicto manteniendo ambas líneas (orden cronológico) y commitear. Considerar `merge=union` en `.gitattributes` para `operations/restore-tests.log`. |
| El smoke test del mes pasado funcionó, este mes el `borgmatic extract` produce ficheros con tamaño 0 | El `prune` borró el archivo del mes pasado y el del día anterior; lo extraído ahora corresponde a un dump más antiguo en el que un hook fallaba. | Comprobar `borgmatic list` y la fecha del archivo extraído. Si el dump de la fecha que se quería ya no existe (retención), elegir un archivo posterior y revisar si en algún momento el hook se rompió: `journalctl -u borgmatic-daily.service --since '<fecha>'`. |

---

## Referencias

- [PostgreSQL — `pg_dump` (manpage)](https://www.postgresql.org/docs/current/app-pgdump.html)
- [PostgreSQL — `pg_restore` (manpage)](https://www.postgresql.org/docs/current/app-pgrestore.html)
- [MariaDB — `mariadb-dump` (manpage)](https://mariadb.com/kb/en/mariadb-dump/)
- [MariaDB — Backup and Restore Overview](https://mariadb.com/kb/en/backup-and-restore-overview/)
- [SQLite — Backup API (`.backup`)](https://www.sqlite.org/lang_backup.html)
- [SQLite — WAL mode](https://www.sqlite.org/wal.html)
- [Samba — `tdbbackup`](https://www.samba.org/samba/docs/current/man-html/tdbbackup.8.html)
- [Borg — `borg extract`](https://borgbackup.readthedocs.io/en/stable/usage/extract.html)
- [Borgmatic — `borgmatic extract` y `borgmatic restore`](https://torsion.org/borgmatic/docs/how-to/extract-a-backup/)
- [Borgmatic — Database hooks](https://torsion.org/borgmatic/docs/how-to/backup-your-databases/)
- [Watchtower — Lifecycle hooks](https://containrrr.dev/watchtower/lifecycle-hooks/)
- [Docker — Backup, restore, or migrate data volumes](https://docs.docker.com/engine/storage/volumes/#back-up-restore-or-migrate-data-volumes)
- [Nextcloud — Backup procedure](https://docs.nextcloud.com/server/latest/admin_manual/maintenance/backup.html)
- [Nextcloud — `occ` reference](https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/occ_command.html)
- [Vaultwarden — Backing up your installation](https://github.com/dani-garcia/vaultwarden/wiki/Backing-up-your-vault)
