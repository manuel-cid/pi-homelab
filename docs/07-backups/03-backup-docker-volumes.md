# Backup y restore de volúmenes Docker y bases de datos

## Descripción
Este documento define el procedimiento operativo para respaldar y restaurar datos persistentes de servicios Docker en el homelab. Complementa a `docs/07-backups/01-estrategia-backup.md` y `docs/07-backups/02-borgmatic.md` con instrucciones concretas para:

- crear inventarios de volúmenes y rutas montadas
- generar backups manuales de `bind mounts` y `named volumes`
- exportar y restaurar dumps lógicos de MariaDB y PostgreSQL
- ejecutar restauraciones controladas de un servicio completo

La idea principal es separar dos capas:

- **backup continuo** con Borgmatic del contenido crítico del NVMe y de `exports/`
- **procedimientos manuales** para restauración puntual, migraciones, validaciones y operaciones antes de cambios de riesgo

## Requisitos Previos
- Haber completado `docs/07-backups/01-estrategia-backup.md`.
- Haber completado `docs/07-backups/02-borgmatic.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Tener accesibles estas rutas:
  - `/home/<usuario>/homelab/`
  - `/mnt/hd2t/backups/exports/`
  - `/mnt/hd2t/backups/restore-test/`
- Tener identificados los nombres reales de contenedores, stacks Compose, volúmenes y rutas bind-mount del servicio que vas a restaurar.
- Poder ejecutar `docker`, `docker compose` y `sudo` con el usuario administrador del homelab.
- Tener espacio libre suficiente en `hd2t` para exports temporales, `tar.gz` y restauraciones de prueba.
- Puertos implicados:
  - no hace falta publicar puertos entrantes nuevos
  - acceso local al Docker Engine por socket Unix
  - conectividad local a los puertos internos del motor de base de datos si haces validaciones desde otros contenedores o desde el host

## Docker Compose
No aplica directamente en este documento.

Aquí no se despliega un servicio nuevo, sino que se documentan procedimientos sobre stacks ya existentes. Los ejemplos usan:

- el stack real del servicio a restaurar
- el contenedor `borgmatic` descrito en `docs/07-backups/02-borgmatic.md`
- contenedores efímeros de utilidad para empaquetar o reinyectar datos en volúmenes

## Configuración

### 1. Principios operativos

Antes de tocar datos persistentes, trabaja con estas reglas:

- no restaures sobre un servicio activo salvo que el motor soporte claramente restore en caliente
- para bases de datos usa **dumps lógicos**, no copias en crudo del directorio interno del contenedor
- para `bind mounts`, restaura permisos y ownership preservando metadatos
- para `named volumes`, usa un contenedor efímero y deja el servicio parado
- genera siempre un inventario y una suma `sha256` del artefacto que vas a usar
- valida en `restore-test/` cuando la restauración completa no sea urgente

Regla práctica:

- si el dato vive en `/home/<usuario>/homelab/data/...`, Borgmatic ya lo incluye en el backup normal del NVMe
- el `tar.gz` manual sirve como export rápido antes de una migración o como restore selectivo
- si el dato principal es MariaDB o PostgreSQL, el artefacto de referencia para restore debe ser el dump SQL

### 1.1. Artefacto de referencia por tipo de dato

Usa esta tabla como criterio rápido para decidir desde qué artefacto restaurar:

| Tipo de dato | Artefacto principal | Artefacto de apoyo | Observación |
|---|---|---|---|
| `bind mount` de aplicación | archive de Borg o `tar.gz` manual | inventario + `sha256` | Borg es la copia versionada principal; el `tar.gz` es útil para operaciones puntuales |
| `named volume` genérico | `tar.gz` del volumen | inventario + `sha256` | restaura siempre con el stack parado |
| MariaDB | dump lógico `mariadb-dump` | archive Borg del directorio de configs y secretos | no uses como fuente principal el directorio interno del motor |
| PostgreSQL | dump lógico `pg_dumpall` o `pg_dump` | archive Borg del directorio de configs y secretos | restaura primero roles y bases si levantas una instancia nueva |
| Servicio mixto con ficheros + BD | filesystem desde Borg o `tar.gz` + dump SQL | inventario completo del stack | orden recomendado: ficheros primero, base de datos después |

### 2. Inventario previo de mounts y volúmenes

Antes de hacer backup o restore, captura cómo está montado el servicio. Guarda ese inventario en `exports/inventories/` para no depender de memoria o de un `compose.yaml` modificado después.

Ejemplo para inspeccionar un contenedor:

```bash
docker inspect <contenedor> \
  --format '{{range .Mounts}}{{println .Type "|" .Name "|" .Source "|" .Destination}}{{end}}'
```

Ejemplo para guardar inventario con fecha:

```bash
mkdir -p /mnt/hd2t/backups/exports/inventories

timestamp="$(date +%F-%H%M%S)"

docker inspect <contenedor> \
  --format '{{range .Mounts}}{{println .Type "|" .Name "|" .Source "|" .Destination}}{{end}}' \
  > "/mnt/hd2t/backups/exports/inventories/<servicio>-mounts-${timestamp}.txt"

docker compose -f /home/<usuario>/homelab/compose/<categoria>/<servicio>/compose.yaml config \
  > "/mnt/hd2t/backups/exports/inventories/<servicio>-compose-${timestamp}.yaml"
```

Qué debes registrar como mínimo:

- nombre del stack y ruta del `compose.yaml`
- contenedor o contenedores implicados
- rutas bind-mount en el host
- nombres de `named volumes`
- nombre del contenedor de base de datos y credenciales/secret usados

### 3. Backup manual de bind mounts

Este procedimiento aplica cuando el servicio persiste datos directamente en rutas del host, por ejemplo:

- `/home/<usuario>/homelab/data/nextcloud/`
- `/home/<usuario>/homelab/data/paperless-ngx/`
- `/home/<usuario>/homelab/data/vaultwarden/`

Preparación:

```bash
mkdir -p /mnt/hd2t/backups/exports/volumes
timestamp="$(date +%F-%H%M%S)"
```

Crear backup:

```bash
sudo tar \
  --xattrs \
  --acls \
  --numeric-owner \
  -czf "/mnt/hd2t/backups/exports/volumes/<servicio>-bind-${timestamp}.tar.gz" \
  -C /home/<usuario>/homelab/data/<servicio> .

sha256sum "/mnt/hd2t/backups/exports/volumes/<servicio>-bind-${timestamp}.tar.gz" \
  > "/mnt/hd2t/backups/exports/volumes/<servicio>-bind-${timestamp}.tar.gz.sha256"
```

Cuándo usarlo:

- antes de una actualización mayor del servicio
- antes de cambiar permisos, estructura de directorios o esquema de almacenamiento
- cuando quieres extraer solo un subconjunto sin restaurar un archive completo de Borg

Si el servicio escribe de forma intensiva, detén primero el stack para evitar un `tar` incoherente:

```bash
cd /home/<usuario>/homelab/compose/<categoria>/<servicio>
docker compose stop
```

Después del backup:

```bash
docker compose start
```

### 4. Restore manual de bind mounts

Secuencia recomendada:

1. Para el stack afectado.
2. Renombra la ruta actual como salvaguarda.
3. Crea el directorio destino vacío.
4. Extrae el `tar.gz`.
5. Arranca el stack y valida logs, permisos y acceso desde la aplicación.

Ejemplo:

```bash
cd /home/<usuario>/homelab/compose/<categoria>/<servicio>
docker compose down

sudo mv \
  /home/<usuario>/homelab/data/<servicio> \
  "/home/<usuario>/homelab/data/<servicio>.before-restore-$(date +%F-%H%M%S)"

sudo mkdir -p /home/<usuario>/homelab/data/<servicio>

sudo tar \
  --xattrs \
  --acls \
  --numeric-owner \
  -xzf /mnt/hd2t/backups/exports/volumes/<servicio>-bind-<timestamp>.tar.gz \
  -C /home/<usuario>/homelab/data/<servicio>

docker compose up -d
```

Comprobaciones mínimas:

- `docker compose logs --tail 100` no muestra errores de permisos
- el proceso del contenedor arranca sin recrear la estructura desde cero
- la aplicación ve sus datos antiguos y no arranca como instalación nueva

### 5. Backup manual de named volumes

Si un servicio usa un volumen gestionado por Docker, usa un contenedor efímero para leerlo y escribir el `tar.gz` en `hd2t`.

Ejemplo de backup de un volumen llamado `<volume_name>`:

```bash
mkdir -p /mnt/hd2t/backups/exports/volumes
timestamp="$(date +%F-%H%M%S)"

docker run --rm \
  -v <volume_name>:/source:ro \
  -v /mnt/hd2t/backups/exports/volumes:/backup \
  busybox sh -c \
  "cd /source && tar czf /backup/<volume_name>-${timestamp}.tar.gz ."

sha256sum "/mnt/hd2t/backups/exports/volumes/<volume_name>-${timestamp}.tar.gz" \
  > "/mnt/hd2t/backups/exports/volumes/<volume_name>-${timestamp}.tar.gz.sha256"
```

Si el volumen pertenece a una base de datos, **no** lo uses como copia principal. En ese caso:

- haz antes el dump lógico
- reserva el `tar.gz` del volumen solo como apoyo técnico o para migración

### 6. Restore manual de named volumes

Nunca restaures un `named volume` mientras el contenedor que lo usa sigue levantado.

Parar el stack:

```bash
cd /home/<usuario>/homelab/compose/<categoria>/<servicio>
docker compose down
```

Si el volumen no existe todavía:

```bash
docker volume create <volume_name>
```

Vaciar y restaurar:

```bash
docker run --rm \
  -v <volume_name>:/target \
  -v /mnt/hd2t/backups/exports/volumes:/backup \
  busybox sh -c \
  'find /target -mindepth 1 -delete && cd /target && tar xzf "/backup/<volume_name>-<timestamp>.tar.gz"'
```

Arranque posterior:

```bash
docker compose up -d
```

Si el servicio inicializa datos al primer arranque, revisa muy bien que el restore se hace sobre el volumen correcto. Un volumen vacío montado sobre una ruta poblada dentro de la imagen puede provocar que Docker copie contenido inicial y cambie el resultado esperado.

### 7. Dumps y restore de MariaDB

#### Backup completo

La convención de esta fase es guardar dumps en:

```text
/mnt/hd2t/backups/exports/mariadb/
```

Ejemplo de dump completo de todas las bases:

```bash
mkdir -p /mnt/hd2t/backups/exports/mariadb
timestamp="$(date +%F-%H%M%S)"

docker exec \
  -e MARIADB_PWD="$(cat /home/<usuario>/homelab/env/secrets/mariadb_root_password.txt)" \
  mariadb \
  mariadb-dump \
    --all-databases \
    --single-transaction \
    --quick \
    --lock-tables=false \
    --routines \
    --events \
    -uroot \
  | gzip -9 > "/mnt/hd2t/backups/exports/mariadb/all-${timestamp}.sql.gz"

sha256sum "/mnt/hd2t/backups/exports/mariadb/all-${timestamp}.sql.gz" \
  > "/mnt/hd2t/backups/exports/mariadb/all-${timestamp}.sql.gz.sha256"
```

Notas prácticas:

- este es el mismo enfoque base que usa el hook `pre-backup.sh` de `docs/07-backups/02-borgmatic.md`
- `--single-transaction` y `--quick` son adecuados para InnoDB y reducen impacto en una Raspberry Pi
- usa nombres reales de contenedor y secret si en tu stack no se llaman `mariadb` o `mariadb_root_password.txt`

#### Restore completo

Para una restauración completa, detén primero los servicios que escriben en MariaDB y deja levantado solo el propio motor.

Ejemplo:

```bash
cd /home/<usuario>/homelab/compose/<categoria>/<servicio>
docker compose stop <app>

gunzip -c /mnt/hd2t/backups/exports/mariadb/all-<timestamp>.sql.gz \
  | docker exec -i \
      -e MARIADB_PWD="$(cat /home/<usuario>/homelab/env/secrets/mariadb_root_password.txt)" \
      mariadb \
      mariadb -uroot
```

Después:

```bash
docker compose start <app>
```

Si el objetivo es recuperar un servicio entero desde cero, suele ser más limpio:

1. recrear el contenedor MariaDB con su volumen persistente vacío
2. restaurar el dump completo
3. arrancar después la aplicación dependiente

### 8. Dumps y restore de PostgreSQL

#### Backup completo del clúster

La convención de esta fase es guardar dumps en:

```text
/mnt/hd2t/backups/exports/postgresql/
```

Ejemplo de dump completo con `pg_dumpall`:

```bash
mkdir -p /mnt/hd2t/backups/exports/postgresql
timestamp="$(date +%F-%H%M%S)"

docker exec \
  -e PGPASSWORD="$(cat /home/<usuario>/homelab/env/secrets/postgres_password.txt)" \
  postgres \
  pg_dumpall -U postgres \
  | gzip -9 > "/mnt/hd2t/backups/exports/postgresql/all-${timestamp}.sql.gz"

sha256sum "/mnt/hd2t/backups/exports/postgresql/all-${timestamp}.sql.gz" \
  > "/mnt/hd2t/backups/exports/postgresql/all-${timestamp}.sql.gz.sha256"
```

Este formato es apropiado cuando quieres conservar también roles y definiciones globales del clúster, que es justo la necesidad habitual en un homelab pequeño con una sola instancia PostgreSQL.

#### Restore completo del clúster

Detén antes las aplicaciones que escriben en PostgreSQL.

Ejemplo:

```bash
cd /home/<usuario>/homelab/compose/<categoria>/<servicio>
docker compose stop <app>

gunzip -c /mnt/hd2t/backups/exports/postgresql/all-<timestamp>.sql.gz \
  | docker exec -i \
      -e PGPASSWORD="$(cat /home/<usuario>/homelab/env/secrets/postgres_password.txt)" \
      postgres \
      psql -v ON_ERROR_STOP=1 -U postgres -d postgres
```

Después:

```bash
docker compose start <app>
```

Si la restauración se hace sobre una instancia nueva, conviene revisar:

- que el usuario `postgres` tiene la misma contraseña esperada por los servicios
- que los roles y bases creados por el dump existen antes de arrancar la aplicación
- que no quedan migraciones pendientes al primer arranque

### 9. Restore completo de un servicio

Cuando un servicio tiene **ficheros persistentes + base de datos**, usa este orden:

1. Identifica el último backup coherente:
   - archive Borg
   - `tar.gz` de bind mount o volume si aplica
   - dump SQL con fecha compatible
2. Para el stack completo:
   - `docker compose down`
3. Restaura la parte de filesystem:
   - bind mount desde Borg o `tar.gz`
   - o `named volume` desde `tar.gz`
4. Levanta solo la base de datos si hace falta:
   - `docker compose up -d mariadb`
   - o `docker compose up -d postgres`
5. Restaura el dump lógico.
6. Levanta el resto del stack.
7. Valida:
   - logs
   - permisos
   - acceso web
   - integridad funcional del servicio

Ejemplos típicos:

- **Nextcloud**: restaurar primero `config/`, `custom_apps/`, `data/` y después la base de datos
- **Paperless-ngx**: restaurar `consume/`, `media/`, `export/` si aplica y luego PostgreSQL o MariaDB según despliegue
- **Vaultwarden**: restaurar su directorio persistente y verificar inmediatamente acceso al panel y adjuntos

### 10. Verificación de restore

La restauración no termina cuando el contenedor arranca. Haz al menos estas verificaciones:

```bash
sha256sum -c /mnt/hd2t/backups/exports/<ruta>/<archivo>.sha256
```

```bash
docker compose ps
docker compose logs --tail 100
```

```bash
docker exec <contenedor> sh -c 'id && ls -lah <ruta_interna>'
```

Checklist mínimo:

1. El checksum del artefacto es válido.
2. El contenedor queda en estado `healthy` o estable.
3. Los permisos del directorio persistente coinciden con el UID/GID esperado.
4. La aplicación muestra datos antiguos reales y no una instancia vacía.
5. El servicio puede escribir de nuevo sin errores.

Cuando la operación no sea urgente, restaura primero en:

```text
/mnt/hd2t/backups/restore-test/
```

Esto permite comprobar contenido, ownership y estructura antes de sustituir la ruta en producción.

## Almacenamiento

| Elemento | Ruta | Disco |
|---|---|---|
| Documento de procedimiento | `docs/07-backups/03-backup-docker-volumes.md` | SSD NVMe |
| Bind mounts de servicios | `/home/<usuario>/homelab/data/<servicio>/` | SSD NVMe |
| Dumps de MariaDB | `/mnt/hd2t/backups/exports/mariadb/` | `hd2t` |
| Dumps de PostgreSQL | `/mnt/hd2t/backups/exports/postgresql/` | `hd2t` |
| Inventarios y exports auxiliares | `/mnt/hd2t/backups/exports/inventories/` y `volumes/` | `hd2t` |
| Restauraciones de prueba | `/mnt/hd2t/backups/restore-test/` | `hd2t` |
| Repositorio Borg local | `/mnt/hd2t/backups/borgmatic/local/` | `hd2t` |
| Bibliotecas multimedia grandes | `/mnt/hd2t/...` y `/mnt/hd5t/...` | `hd2t` y `hd5t` |

## Backup

Qué debe quedar cubierto con este procedimiento:

- rutas persistentes en `/home/<usuario>/homelab/data/`
- `named volumes` que todavía existan en servicios concretos
- dumps lógicos de MariaDB y PostgreSQL
- inventarios de mounts y archivos `sha256`
- restauraciones de prueba antes de tocar producción

Qué no debes considerar backup válido por sí solo:

- copiar el directorio interno de una base de datos mientras el motor está en uso
- exportar solo el contenedor sin sus datos persistentes
- guardar un `tar.gz` en el mismo disco físico que quieres proteger
- asumir que un archive Borg es suficiente si nunca has probado el restore del servicio

Checklist operativo de este documento:

1. Existe inventario reciente del servicio antes de restaurar.
2. Los dumps SQL se guardan en `exports/` con fecha y checksum.
3. Los `bind mounts` se empaquetan con metadatos preservados.
4. Los `named volumes` se restauran con el stack parado.
5. El orden de restore es filesystem primero y base de datos después.
6. Hay validación final de logs, permisos y datos reales.

## Referencias
- Docker Docs: volumes  
  https://docs.docker.com/engine/storage/volumes/
- Docker Docs: bind mounts  
  https://docs.docker.com/engine/storage/bind-mounts/
- MariaDB Server Documentation: `mariadb-dump`  
  https://mariadb.com/docs/server/clients-and-utilities/backup-restore-and-import-clients/mariadb-dump
- PostgreSQL Documentation: SQL Dump  
  https://www.postgresql.org/docs/current/backup-dump.html
- PostgreSQL Documentation: `psql`  
  https://www.postgresql.org/docs/current/app-psql.html
