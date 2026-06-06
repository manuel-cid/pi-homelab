# Backup y Restore de Volúmenes Docker

## Descripción

Este documento define el procedimiento operativo para respaldar y restaurar los datos persistentes de los servicios Docker del homelab. Complementa a [01-estrategia-backup.md](01-estrategia-backup.md), que fija la política general, y a [02-borgmatic.md](02-borgmatic.md), que automatiza la ejecución.

La regla principal es simple:

- los **contenedores** se recrean
- los **datos persistentes** se respaldan
- las **bases de datos** se respaldan con **dump lógico consistente**
- los ficheros restaurados se validan primero en una ruta temporal antes de volver a producción

En este homelab, la opción preferida para datos persistentes es usar **bind mounts** en el **SSD NVMe** bajo `/home/<user>/homelab/data/`. Los **named volumes** de Docker solo deben usarse cuando una imagen los requiera o cuando resulte poco práctico exponer la ruta real en el host.

## Requisitos Previos

- Haber completado [01-estrategia-backup.md](01-estrategia-backup.md).
- Haber completado [02-borgmatic.md](02-borgmatic.md).
- Tener desplegados los servicios que se van a respaldar.
- Tener identificados los contenedores de bases de datos y las rutas persistentes de cada servicio.
- Tener disponible `/media/hd2t/backups/exports/` para dumps lógicos y `/media/hd2t/backups/restore-test/` para pruebas de restauración.
- Poder ejecutar `docker exec`, `docker inspect` y `docker compose` en el host.
- Conocer los `UID/GID` esperados por cada servicio crítico antes de restaurar datos.

Puertos necesarios en esta fase:

- ninguno a nivel host

## Docker Compose

No aplica en este documento. Aquí se define el procedimiento operativo de backup y restore sobre los datos persistentes ya desplegados. La automatización del stack está en [02-borgmatic.md](02-borgmatic.md).

## Configuración

### 1. Clasificar correctamente el almacenamiento de cada servicio

Antes de automatizar nada, cada servicio debe quedar clasificado en una de estas categorías:

| Tipo | Qué se respalda | Método recomendado | Método de restore |
|------|------------------|-------------------|-------------------|
| Bind mount en NVMe | Directorio bajo `/home/<user>/homelab/data/<servicio>/` | Borg/Borgmatic sobre el sistema de ficheros | Extraer a ruta temporal y sincronizar de vuelta |
| Named volume Docker | Volumen gestionado por Docker | Export `tar` con contenedor auxiliar | Crear o vaciar volumen y restaurar `tar` |
| MariaDB | Esquema, datos, rutinas, eventos, triggers | `mariadb-dump` antes del backup | Importar SQL con el servidor levantado |
| PostgreSQL | Base de datos y objetos globales | `pg_dump` + `pg_dumpall --globals-only` | `pg_restore` o `psql` según el formato |
| SQLite u otras BDs de fichero | Fichero `.db` dentro del bind mount | Backup del fichero con la aplicación parada o en modo consistente | Sustitución del fichero con el servicio detenido |

Regla práctica:

- si el servicio guarda sus datos en `/home/<user>/homelab/data/`, el backup base lo cubre Borgmatic
- si además usa MariaDB o PostgreSQL, **no basta** con copiar el directorio del contenedor; hay que generar un dump lógico
- si la imagen usa un named volume, hay que documentarlo explícitamente porque Borgmatic no lo ve como una ruta normal del host

### 2. Identificar qué monta realmente cada contenedor

Para no respaldar a ciegas, revisa los mounts reales:

```bash
docker inspect <contenedor> --format '{{ json .Mounts }}'
```

Qué debes confirmar:

- si el origen es una ruta del host, por ejemplo `/home/<user>/homelab/data/vaultwarden`
- si el origen es un volumen Docker con nombre, por ejemplo `portainer_data`
- si existe una base de datos externa al contenedor de la aplicación
- si el servicio usa cachés, thumbnails o temporales que deban excluirse

Si un servicio escribe datos importantes fuera de `/home/<user>/homelab/data/`, corrígelo antes de depender del backup.

### 3. Preferir bind mounts para datos persistentes

La política recomendada en este homelab es:

- **bind mounts** para configuración, bibliotecas, uploads, índices y ficheros de aplicación
- **dump lógico** para MariaDB y PostgreSQL
- **named volumes** solo cuando no haya una alternativa clara

Ventajas del bind mount:

- la ruta queda visible y versionable en la documentación
- Borgmatic puede respaldarla sin lógica adicional
- el restore puede hacerse con herramientas normales del host como `rsync`

Estructura recomendada:

```text
/home/<user>/homelab/data/
├── authelia/
├── grafana/
├── linkding/
├── paperless/
├── portainer/
└── vaultwarden/
```

### 4. Procedimiento de backup para bind mounts

Si un servicio usa bind mounts en el NVMe, el flujo correcto es:

1. generar primero los dumps de base de datos que correspondan
2. dejar esos dumps en una ruta que Borgmatic sí respalde
3. ejecutar el backup del árbol `compose/`, `config/`, `scripts/`, `.env` y `data/`

Rutas recomendadas para dumps previos:

```text
/media/hd2t/backups/exports/
├── mariadb/
├── postgres/
├── sqlite/
└── volumes/
```

Importante:

- `exports/` no sustituye al repositorio Borg; es un área de trabajo para generar artefactos lógicos
- el dump debe completarse **antes** de que Borg empiece a leer los datos
- si el servicio solo usa SQLite u otros ficheros locales, el propio directorio persistente suele ser suficiente, pero conviene detener la aplicación para restauraciones críticas

### 5. Procedimiento de backup para named volumes Docker

Si una imagen usa un named volume y no quieres migrarlo todavía a bind mount, exporta el contenido a `tar`.

Ejemplo de backup:

```bash
VOLUME=portainer_data
STAMP=$(date +%F_%H%M%S)
DEST=/media/hd2t/backups/exports/volumes/${VOLUME}

mkdir -p "${DEST}"

docker run --rm \
  -v "${VOLUME}:/source:ro" \
  -v "${DEST}:/backup" \
  alpine:3.22 \
  sh -c "tar czf /backup/${VOLUME}_${STAMP}.tar.gz -C /source ."
```

Ejemplo de restore:

```bash
VOLUME=portainer_data
ARCHIVE=portainer_data_2026-05-07_023000.tar.gz
SRC=/media/hd2t/backups/exports/volumes/${VOLUME}

docker run --rm \
  -v "${VOLUME}:/target" \
  -v "${SRC}:/backup:ro" \
  alpine:3.22 \
  sh -c "find /target -mindepth 1 -delete && tar xzf /backup/${ARCHIVE} -C /target"
```

Antes de restaurar un named volume:

- detén el contenedor que lo usa
- valida que el archivo `tar.gz` corresponde al servicio y fecha correctos
- restaura primero en un volumen temporal si no estás seguro del contenido

### 6. Generar dumps consistentes de MariaDB

Para MariaDB, el respaldo recomendado es un **dump lógico** ejecutado contra el contenedor de base de datos. Para tablas transaccionales, usa `--single-transaction` y `--quick` para minimizar bloqueo y consumo de memoria. Añade `--routines` y `--events` para no perder objetos que no siempre se incluyen por defecto en un volcado básico.

Ejemplo para toda la instancia:

```bash
STAMP=$(date +%F_%H%M%S)
DEST=/media/hd2t/backups/exports/mariadb

mkdir -p "${DEST}"

docker exec mariadb sh -c \
  'exec mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" \
    --all-databases \
    --single-transaction \
    --quick \
    --routines \
    --events \
    --triggers' \
  > "${DEST}/mariadb_${STAMP}.sql"
```

Si solo quieres una base de datos concreta, usa `--databases <nombre_bd>` en lugar de `--all-databases`.

Buenas prácticas:

- guarda un dump por ejecución con timestamp
- no confíes solo en copiar `/var/lib/mysql`
- si el servicio es muy sensible a cambios de esquema, detén temporalmente la aplicación cliente antes del dump
- documenta qué contenedor MariaDB sirve a qué aplicaciones

### 7. Restaurar MariaDB

Flujo recomendado:

1. detener las aplicaciones que escriben en la base de datos
2. mantener el contenedor MariaDB levantado
3. importar el dump correcto
4. verificar tablas y credenciales
5. arrancar de nuevo las aplicaciones dependientes

Ejemplo de restore:

```bash
SQL=/media/hd2t/backups/exports/mariadb/mariadb_2026-05-07_023000.sql

docker exec -i mariadb sh -c \
  'exec mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"' \
  < "${SQL}"
```

Si la restauración apunta a una sola aplicación:

- restaura primero en una instancia temporal si quieres validar integridad sin tocar producción
- confirma que el dump contiene `CREATE DATABASE` si esperas recrear la base desde cero
- revisa usuarios, grants y secretos de aplicación antes de reabrir el servicio

### 8. Generar dumps consistentes de PostgreSQL

Para PostgreSQL conviene separar:

- backup de cada base de datos con `pg_dump`
- backup de objetos globales con `pg_dumpall --globals-only`

Esta separación facilita restores selectivos y mantiene fuera del dump principal la parte global de roles y tablespaces.

Ejemplo para una base de datos concreta en formato `custom`:

```bash
STAMP=$(date +%F_%H%M%S)
DEST=/media/hd2t/backups/exports/postgres

mkdir -p "${DEST}"

docker exec postgres sh -c \
  'export PGPASSWORD="$POSTGRES_PASSWORD"; exec pg_dump -U postgres -d appdb -Fc' \
  > "${DEST}/appdb_${STAMP}.dump"

docker exec postgres sh -c \
  'export PGPASSWORD="$POSTGRES_PASSWORD"; exec pg_dumpall -U postgres --globals-only' \
  > "${DEST}/globals_${STAMP}.sql"
```

Si prefieres un dump completo de toda la instancia, usa `pg_dumpall`, sabiendo que genera un script SQL único y requiere privilegios elevados tanto para exportar como para restaurar.

### 9. Restaurar PostgreSQL

Flujo recomendado:

1. detener las aplicaciones que usan la base de datos
2. restaurar antes los objetos globales si el dump los necesita
3. recrear la base de datos destino si procede
4. cargar el dump con `pg_restore` o `psql`
5. arrancar el servicio y verificar login, migraciones y permisos

Ejemplo de restore de objetos globales:

```bash
GLOBALS=/media/hd2t/backups/exports/postgres/globals_2026-05-07_023000.sql

docker exec -i postgres sh -c \
  'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -U postgres -d postgres' \
  < "${GLOBALS}"
```

Ejemplo de restore de una base de datos en formato `custom`:

```bash
DUMP=/media/hd2t/backups/exports/postgres/appdb_2026-05-07_023000.dump

docker exec postgres sh -c \
  'export PGPASSWORD="$POSTGRES_PASSWORD"; exec dropdb -U postgres --if-exists appdb'

docker exec postgres sh -c \
  'export PGPASSWORD="$POSTGRES_PASSWORD"; exec createdb -U postgres appdb'

cat "${DUMP}" | docker exec -i postgres sh -c \
  'export PGPASSWORD="$POSTGRES_PASSWORD"; exec pg_restore -U postgres -d appdb --clean --if-exists'
```

Si restauras en un entorno distinto:

- considera `--no-owner` y `--no-privileges`
- valida extensiones, collation y versión principal de PostgreSQL antes de sustituir producción

### 10. Procedimiento para SQLite y otras bases de datos de fichero

SQLite no necesita dump separado si el fichero vive dentro de un bind mount y el servicio tolera backup en caliente. Aun así, para restauraciones limpias el procedimiento recomendado es:

1. detener el contenedor de la aplicación
2. restaurar el directorio o el fichero `.db` desde Borg a una ruta temporal
3. sustituir el fichero en producción
4. corregir permisos si hace falta
5. arrancar de nuevo el contenedor

Ejemplo típico:

<!-- TODO: verificar la ruta exacta del stack que contiene Vaultwarden -->

```bash
cd /home/<user>/homelab/compose/<stack>
docker compose stop vaultwarden
sudo rsync -aHAX --delete \
  /media/hd2t/backups/restore-test/vaultwarden/ \
  /home/<user>/homelab/data/vaultwarden/
docker compose start vaultwarden
```

### 11. Integrar los dumps en `pre-backup.sh`

El `pre-backup.sh` de [02-borgmatic.md](02-borgmatic.md) debe comportarse como un orquestador simple. Ese script se ejecuta **dentro del contenedor de Borgmatic**, así que debe usar las rutas internas montadas por ese stack, por ejemplo **`/mnt/borg-exports`** y no **`/media/hd2t/backups/exports`**.

- crear directorios de export si no existen
- generar dumps con timestamp
- borrar exports temporales muy antiguos si ya están incluidos en la política
- abortar con código distinto de cero si falla un dump crítico

Ejemplo mínimo:

```bash
#!/bin/sh
set -eu

STAMP=$(date +%F_%H%M%S)

mkdir -p /mnt/borg-exports/mariadb
mkdir -p /mnt/borg-exports/postgres

docker exec mariadb sh -c \
  'exec mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" \
    --all-databases \
    --single-transaction \
    --quick \
    --routines \
    --events \
    --triggers' \
  > "/mnt/borg-exports/mariadb/mariadb_${STAMP}.sql"

docker exec postgres sh -c \
  'export PGPASSWORD="$POSTGRES_PASSWORD"; exec pg_dumpall -U postgres --globals-only' \
  > "/mnt/borg-exports/postgres/globals_${STAMP}.sql"
```

Si una aplicación necesita además su propio `pg_dump`, añádelo aquí o usa los bloques nativos `postgresql_databases` y `mariadb_databases` de Borgmatic cuando el caso encaje bien.

### 12. Procedimiento general de restore sin sobrescribir datos en caliente

El restore correcto no consiste en extraer directamente encima del directorio activo. La secuencia recomendada es:

1. restaurar primero a `/media/hd2t/backups/restore-test/<servicio>/`
2. inspeccionar contenido, tamaños y fecha esperada
3. detener el contenedor afectado
4. hacer copia del estado actual si aún no existe una
5. sincronizar datos restaurados al directorio real
6. corregir permisos y propietarios
7. arrancar el contenedor
8. validar login, integridad y logs

Ejemplo de sincronización final:

<!-- TODO: verificar la ruta exacta del stack que contiene este servicio -->

```bash
SERVICE=vaultwarden

cd /home/<user>/homelab/compose/<stack>
docker compose stop "${SERVICE}"

sudo rsync -aHAX --delete \
  "/media/hd2t/backups/restore-test/${SERVICE}/" \
  "/home/<user>/homelab/data/${SERVICE}/"

docker compose start "${SERVICE}"
```

Qué revisar después:

- que el contenedor arranca sin migraciones inesperadas
- que la aplicación responde y puede autenticarse
- que no hay errores de permisos en logs
- que los secretos y variables `.env` siguen alineados con los datos restaurados

## Almacenamiento

Distribución recomendada para este procedimiento:

- **Datos persistentes en producción**
  - `/home/<user>/homelab/data/<servicio>/`
- **Exports lógicos temporales o retenidos**
  - `/media/hd2t/backups/exports/mariadb/`
  - `/media/hd2t/backups/exports/postgres/`
  - `/media/hd2t/backups/exports/sqlite/`
  - `/media/hd2t/backups/exports/volumes/`
- **Restauraciones de prueba**
  - `/media/hd2t/backups/restore-test/<servicio>/`

Reglas importantes:

- el **origen** de los datos operativos es el **SSD NVMe**
- `exports/` es una zona auxiliar, no la copia canónica
- `restore-test/` debe usarse para validar antes de tocar producción
- los contenidos multimedia de `hd2t` y `hd5t` siguen fuera del flujo base de restore de servicios

## Backup

Para cada servicio con estado, valida como mínimo estos elementos:

- directorio persistente en `/home/<user>/homelab/data/<servicio>/`
- dump lógico de MariaDB o PostgreSQL si existe base de datos separada
- archivo `.env` o secretos que permitan arrancar el servicio restaurado
- named volume exportado si la imagen no usa bind mount

Regla operativa:

- si un servicio usa **volumen + base de datos**, respalda ambos
- si un servicio usa solo **ficheros locales**, el bind mount suele ser suficiente
- si el dump lógico falla, el backup de ese servicio debe considerarse incompleto

Orden recomendado de recuperación:

1. restaurar configuración y secretos
2. restaurar base de datos
3. restaurar volumen o bind mount
4. arrancar el servicio
5. validar funcionamiento desde la aplicación

## Referencias

- [01-estrategia-backup.md](01-estrategia-backup.md)
- [02-borgmatic.md](02-borgmatic.md)
- Documentación oficial de Borgmatic sobre backup de bases de datos: https://torsion.org/borgmatic/how-to/backup-your-databases/
- Documentación oficial de Docker sobre volúmenes y backup/restore: https://docs.docker.com/engine/storage/volumes/
- Documentación oficial de MariaDB para `mariadb-dump`: https://mariadb.com/docs/server/clients-and-utilities/backup-restore-and-import-clients/mariadb-dump
- Documentación oficial de PostgreSQL para `pg_dump`: https://www.postgresql.org/docs/current/app-pgdump.html
- Documentación oficial de PostgreSQL para `pg_dumpall`: https://www.postgresql.org/docs/current/app-pg-dumpall.html
- Documentación oficial de PostgreSQL para `pg_restore`: https://www.postgresql.org/docs/current/app-pgrestore.html
