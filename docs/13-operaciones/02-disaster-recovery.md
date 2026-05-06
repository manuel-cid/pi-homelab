# Disaster recovery

## Descripción
Este documento define el procedimiento de recuperación del homelab cuando el **SSD NVMe** del sistema falla, se corrompe o debe sustituirse, pero los discos USB `hd2t` y `hd5t` siguen disponibles.

El objetivo no es "reparar" el host original, sino reconstruir un entorno funcional en una Raspberry Pi 5 con el mismo diseño operativo:

- **SSD NVMe** para sistema, Docker, `compose/`, `env/`, `scripts/` y `data/`
- `hd2t` para backups locales, exports, multimedia general y descargas
- `hd5t` para la biblioteca multimedia de Stash
- acceso solo por **LAN + Tailscale**, sin exposición pública

Este runbook cubre la recuperación del host y de los servicios críticos que viven en el NVMe usando como fuente principal el repositorio local de Borg en `hd2t` y, cuando haga falta, los artefactos de `exports/`.

Alcance real de esta recuperación:

- sí cubre la pérdida total del **NVMe**
- sí cubre reinstalar Raspberry Pi OS y Docker
- sí cubre restaurar `compose/`, `env/`, `scripts/` y `data/` del homelab
- no convierte una copia local en `hd2t` en backup válido de los propios datos cuyo origen ya está en `hd2t`
- no recupera por sí sola la biblioteca de Stash si también se pierde `hd5t`

## Requisitos Previos
- Haber completado `docs/07-backups/01-estrategia-backup.md`.
- Haber completado `docs/07-backups/02-borgmatic.md`.
- Haber completado `docs/07-backups/03-backup-docker-volumes.md`.
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/00-hardware/03-preparacion-discos.md`.
- Tener acceso físico a la Raspberry Pi 5, al NVMe de sustitución si aplica y a los discos USB `hd2t` y `hd5t`.
- Tener una copia **fuera del NVMe** de estos datos mínimos para desbloquear la recuperación:
  - usuario administrador del host
  - hostname esperado
  - passphrase de Borg
  - claves o credenciales SSH necesarias
  - cualquier secreto no recuperable desde otro origen
- Tener un backup local utilizable en:
  - `/mnt/hd2t/backups/borgmatic/local/`
  - `/mnt/hd2t/backups/exports/`
  - `/mnt/hd2t/backups/reports/`
- Poder ejecutar `sudo`, `docker`, `docker compose`, `lsblk`, `findmnt`, `mount`, `rsync` y `sha256sum`.
- Disponer de conectividad de red saliente para reinstalar paquetes y descargar imágenes Docker.
- Puertos implicados:
  - `22/tcp` para recuperación por SSH dentro de la LAN
  - `443/tcp` saliente para instalar paquetes y, si aplica, reactivar Tailscale
  - no hace falta abrir puertos entrantes nuevos en el router

## Docker Compose
No aplica directamente en este documento.

Aquí no se despliega un servicio nuevo, sino que se reconstruye el host y después se vuelven a levantar los stacks ya definidos en `/home/<usuario>/homelab/compose/`.

Durante la recuperación puede ser útil lanzar un contenedor temporal de Borgmatic para listar y extraer backups sin depender todavía del stack definitivo de `borgmatic`.

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| Host base | Raspberry Pi OS funcional sobre el NVMe |
| Montajes | `hd2t` y `hd5t` visibles en `/mnt/hd2t` y `/mnt/hd5t` |
| Runtime | Docker Engine y `docker compose` reinstalados |
| Restauración de datos | `compose/`, `env/`, `scripts/` y `data/` recuperados desde Borg |
| Restauración puntual | dumps SQL y exports disponibles en `hd2t` si algún servicio lo requiere |
| Servicios | stacks críticos levantados y validados |
| Red | acceso en LAN y Tailscale restaurado, sin port forwarding |

### 1. Qué escenario cubre este runbook

Úsalo cuando se cumple este patrón:

- el **NVMe** ha fallado o su sistema no es fiable
- `hd2t` sigue legible y contiene el repositorio local de Borg
- `hd5t` sigue legible si quieres conservar la biblioteca de Stash sin moverla
- la Raspberry Pi 5, su fuente y la conectividad física siguen operativas

Si también se ha perdido `hd2t`, este documento ya no basta para recuperar los datos críticos del NVMe desde la copia local. En ese caso debes recurrir al destino offsite descrito en `docs/07-backups/01-estrategia-backup.md`.

### 2. Orden de recuperación recomendado

No improvises el orden. Sigue esta secuencia:

1. aislar el incidente y confirmar qué discos siguen sanos
2. reinstalar un sistema base limpio en el NVMe
3. recuperar montajes estables de `hd2t` y `hd5t`
4. reinstalar Docker Engine y `docker compose`
5. listar el repositorio Borg y elegir el archive correcto
6. restaurar `/home/<usuario>/homelab/`
7. corregir permisos y secretos mínimos
8. levantar primero infraestructura base y después aplicaciones
9. validar servicios, datos y backups
10. documentar el incidente y reanudar la operación normal

Ese orden reduce el riesgo de:

- levantar contenedores antes de tener todos sus datos restaurados
- sobrescribir rutas persistentes con inicializaciones vacías
- usar un archive Borg correcto pero un dump SQL de fecha incompatible

### 3. Evaluación inicial del incidente

Antes de reinstalar nada, identifica si el problema es realmente el NVMe y no la fuente, la carcasa, el firmware o el cableado.

Comprobaciones mínimas:

```bash
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,MOUNTPOINT,MODEL,TRAN
findmnt /
findmnt /mnt/hd2t /mnt/hd5t
dmesg | tail -n 100
```

Si el sistema todavía arranca parcialmente desde el NVMe, recoge antes de apagarlo todo lo que puedas:

```bash
hostnamectl
ip -brief address
lsblk -f
sudo cp /etc/fstab /tmp/fstab.before-disaster
```

Qué debes decidir en esta fase:

- si el NVMe se puede reutilizar tras un borrado completo
- si necesitas sustituir físicamente el SSD o la carcasa
- si `hd2t` y `hd5t` están sanos y con sus etiquetas correctas
- qué fecha aproximada tuvo el último backup bueno

Si `hd2t` muestra errores I/O o no monta con estabilidad, detén la recuperación destructiva y prioriza clonar o preservar esa unidad. Sin el repositorio local de Borg, reinstalar el host sin una fuente de datos fiable solo empeora la situación.

### 4. Reinstalar Raspberry Pi OS en el NVMe

La recuperación del host debe terminar otra vez con **Raspberry Pi OS Lite 64-bit** arrancando desde el **NVMe**.

Camino recomendado:

1. grabar Raspberry Pi OS Lite 64-bit en el NVMe con Raspberry Pi Imager desde otro equipo
2. preconfigurar hostname, usuario administrador y SSH
3. arrancar la Raspberry Pi 5 con el NVMe nuevo o regrabado
4. usar una microSD temporal solo si necesitas recuperar el arranque o reconfigurar el boot order

Validaciones tras el primer arranque:

```bash
hostnamectl
cat /etc/os-release
uname -m
dpkg --print-architecture
findmnt /
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,MOUNTPOINT
```

Estado esperado:

- `uname -m` devuelve `aarch64`
- `dpkg --print-architecture` devuelve `arm64`
- `/` reside en el **NVMe**
- el usuario administrador puede usar `sudo`

Actualización base del sistema:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

Tras volver a entrar, confirma de nuevo que el arranque sigue sobre el NVMe.

### 5. Recuperar montajes estables de `hd2t` y `hd5t`

Antes de restaurar datos debes volver a montar exactamente las rutas esperadas por los stacks.

Crear puntos de montaje:

```bash
sudo mkdir -p /mnt/hd2t /mnt/hd5t
sudo chown root:root /mnt/hd2t /mnt/hd5t
sudo chmod 755 /mnt/hd2t /mnt/hd5t
```

Identificar discos:

```bash
lsblk -f
sudo blkid
```

Configurar `/etc/fstab` con las etiquetas del proyecto:

```fstab
LABEL=hd2t  /mnt/hd2t  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10s  0  2
LABEL=hd5t  /mnt/hd5t  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10s  0  2
```

Aplicar y validar:

```bash
sudo mount -a
findmnt /mnt/hd2t /mnt/hd5t
df -h /mnt/hd2t /mnt/hd5t
ls -lah /mnt/hd2t/backups
```

Qué debes ver:

- `hd2t` montado en `/mnt/hd2t`
- `hd5t` montado en `/mnt/hd5t`
- el árbol `/mnt/hd2t/backups/` visible
- el repositorio Borg local y `exports/` presentes

Comprobaciones útiles del repositorio local:

```bash
ls -lah /mnt/hd2t/backups/borgmatic/local
ls -lah /mnt/hd2t/backups/exports
find /mnt/hd2t/backups/reports -type f | sort | tail -n 20
```

### 6. Reinstalar Docker Engine y Docker Compose

Reinstala Docker antes de tocar los datos del homelab para poder usar imágenes de utilidad y volver a levantar los stacks.

Eliminar restos conflictivos si existen:

```bash
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
  sudo apt remove -y "$pkg"
done
```

Configurar el repositorio oficial:

```bash
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
```

```bash
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "${VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
```

Instalar paquetes:

```bash
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin rsync
sudo systemctl enable --now docker.service
sudo systemctl enable --now containerd.service
getent group docker || sudo groupadd docker
sudo usermod -aG docker <usuario>
```

Abre una sesión nueva y valida:

```bash
docker version
docker compose version
docker run --rm hello-world
```

### 7. Preparar el destino de restauración

Antes de extraer el backup, recrea solo la estructura mínima del homelab en el NVMe.

```bash
mkdir -p /home/<usuario>/homelab
mkdir -p /home/<usuario>/homelab/.restore
```

No arranques todavía ningún stack real. Primero debes decidir qué archive Borg vas a restaurar.

Si el repositorio local está cifrado, exporta la passphrase en la sesión actual:

```bash
export BORG_PASSPHRASE='TU_PASSPHRASE_REAL'
```

Si prefieres no dejarla en el historial, cárgala desde un fichero temporal fuera de `/home/<usuario>/homelab` y elimínalo al terminar.

### 8. Listar y elegir el archive Borg correcto

Una vez disponible Docker, puedes usar un contenedor temporal de Borgmatic para inspeccionar el repositorio local sin depender de la restauración previa del stack oficial.

Listar archives:

```bash
docker run --rm \
  -e BORG_PASSPHRASE \
  -v /mnt/hd2t/backups/borgmatic/local:/mnt/borg-repository-local \
  ghcr.io/borgmatic-collective/borgmatic:latest \
  borg list /mnt/borg-repository-local
```

Si el listado es largo, toma los más recientes:

```bash
docker run --rm \
  -e BORG_PASSPHRASE \
  -v /mnt/hd2t/backups/borgmatic/local:/mnt/borg-repository-local \
  ghcr.io/borgmatic-collective/borgmatic:latest \
  borg list --last 10 /mnt/borg-repository-local
```

Criterios para elegir el archive:

- prioriza el último archive completado sin error
- asegúrate de que su fecha encaja con los dumps en `exports/`
- si hubo una actualización problemática, usa el archive inmediatamente anterior

Comprobación opcional de contenido sin extraer:

```bash
docker run --rm \
  -e BORG_PASSPHRASE \
  -v /mnt/hd2t/backups/borgmatic/local:/mnt/borg-repository-local \
  ghcr.io/borgmatic-collective/borgmatic:latest \
  borg list /mnt/borg-repository-local::homelab-rpi5-AAAA-MM-DD-HHMMSS | head -n 50
```

### 9. Restaurar `/home/<usuario>/homelab/` desde Borg

Este proyecto usa Borg como copia versionada principal del contenido crítico del NVMe:

- `/home/<usuario>/homelab/compose`
- `/home/<usuario>/homelab/env`
- `/home/<usuario>/homelab/scripts`
- `/home/<usuario>/homelab/data`

Extrae el archive elegido sobre una ruta temporal para poder inspeccionarlo antes de moverlo a producción:

```bash
mkdir -p /home/<usuario>/homelab/.restore/extracted
```

```bash
docker run --rm \
  -e BORG_PASSPHRASE \
  -v /mnt/hd2t/backups/borgmatic/local:/mnt/borg-repository-local \
  -v /home/<usuario>/homelab/.restore/extracted:/restore \
  ghcr.io/borgmatic-collective/borgmatic:latest \
  sh -c 'cd /restore && borg extract /mnt/borg-repository-local::homelab-rpi5-AAAA-MM-DD-HHMMSS'
```

Verifica la estructura restaurada:

```bash
find /home/<usuario>/homelab/.restore/extracted -maxdepth 3 -type d | sort | sed -n '1,80p'
```

Sincroniza al destino definitivo preservando metadatos:

```bash
sudo rsync -aHAX --numeric-ids \
  /home/<usuario>/homelab/.restore/extracted/srv/homelab/ \
  /home/<usuario>/homelab/
```

Corrige propietario del árbol restaurado:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab
find /home/<usuario>/homelab -maxdepth 2 -type d | sort | sed -n '1,80p'
```

Qué debes validar antes de seguir:

- existen `compose/`, `env/`, `scripts/` y `data/`
- reaparecen los stacks esperados bajo `/home/<usuario>/homelab/compose/`
- los secretos bajo `env/` tienen contenido y permisos restrictivos
- la restauración no se ha hecho directamente encima de una ruta parcialmente poblada por error

### 10. Restaurar artefactos puntuales desde `exports/` cuando haga falta

En muchos casos, restaurar `/home/<usuario>/homelab/data/` desde Borg será suficiente. Aun así, conserva esta lógica:

- si un servicio usa MariaDB o PostgreSQL y sospechas inconsistencia, usa el dump lógico de `exports/`
- si un stack usa un `named volume`, restaura ese volumen con el procedimiento de `docs/07-backups/03-backup-docker-volumes.md`
- si necesitas validar un directorio antes de sobrescribir producción, extrae primero en `restore-test/`

Inventario rápido de exports disponibles:

```bash
find /mnt/hd2t/backups/exports -maxdepth 2 -type f | sort | tail -n 50
```

Comprobación de checksum:

```bash
sha256sum -c /mnt/hd2t/backups/exports/<ruta>/<archivo>.sha256
```

Ejemplo de restore de MariaDB tras levantar solo el motor:

```bash
gunzip -c /mnt/hd2t/backups/exports/mariadb/all-<timestamp>.sql.gz \
  | docker exec -i \
      -e MARIADB_PWD="$(cat /home/<usuario>/homelab/env/secrets/mariadb_root_password.txt)" \
      mariadb \
      mariadb -uroot
```

Ejemplo de restore de PostgreSQL tras levantar solo el motor:

```bash
gunzip -c /mnt/hd2t/backups/exports/postgresql/all-<timestamp>.sql.gz \
  | docker exec -i \
      -e PGPASSWORD="$(cat /home/<usuario>/homelab/env/secrets/postgres_password.txt)" \
      postgres \
      psql -v ON_ERROR_STOP=1 -U postgres -d postgres
```

No hagas restore SQL a ciegas sobre una instancia ya arrancada con datos nuevos si antes no has decidido si vas a sustituir o fusionar estado. En recuperación completa, normalmente es más limpio restaurar primero filesystem y después bases de datos sobre instancias recién recreadas.

### 11. Orden recomendado para levantar los stacks

No subas todo a la vez. Levanta el homelab por capas.

Capa 1, infraestructura base:

- proxy y capa de acceso local si aplica
- DNS o resolución local si depende de contenedores
- Tailscale, si lo ejecutas en contenedor o si depende de archivos restaurados
- motores de base de datos

Capa 2, observabilidad y operaciones:

- Portainer
- Dozzle
- Uptime Kuma
- Borgmatic

Capa 3, aplicaciones con estado:

- Nextcloud
- Paperless-ngx
- Vaultwarden
- BookStack
- Linkding
- resto de servicios con bind mounts en el NVMe

Capa 4, servicios con bibliotecas en discos USB:

- Jellyfin
- Navidrome
- Audiobookshelf
- Calibre-Web
- Transmission, Sonarr y Radarr
- Stash

Secuencia genérica por stack:

```bash
cd /home/<usuario>/homelab/compose/<categoria>/<servicio>
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail 100
```

Qué debes vigilar especialmente:

- errores de permisos en rutas restauradas
- montajes hacia `/mnt/hd2t` o `/mnt/hd5t` ausentes o vacíos
- servicios que arrancan como instalación nueva
- bases de datos que intentan migrar sobre un estado incoherente

### 12. Verificación final del homelab recuperado

No cierres la recuperación solo porque los contenedores estén `Up`.

Validación del host:

```bash
findmnt / /mnt/hd2t /mnt/hd5t
df -h / /mnt/hd2t /mnt/hd5t
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

Validación de servicios:

- acceder a Portainer y comprobar que muestra el endpoint local
- acceder a Dozzle y confirmar que los logs recientes no muestran errores en cascada
- abrir las aplicaciones críticas por LAN o Tailscale
- comprobar que Nextcloud, Paperless-ngx y Vaultwarden muestran datos reales
- comprobar que Jellyfin y Navidrome ven sus bibliotecas en `hd2t`
- comprobar que Stash sigue viendo la biblioteca de `hd5t`

Validación de datos y permisos:

```bash
docker exec <contenedor> sh -c 'id && ls -lah <ruta_interna>'
```

Validación del backup después de recuperar:

```bash
cd /home/<usuario>/homelab/compose/backups/borgmatic
docker compose up -d
docker compose exec borgmatic \
  borgmatic --config /etc/borgmatic.d/local.yaml list --last 3
```

Después ejecuta un backup manual para reanudar la protección del nuevo NVMe:

```bash
docker compose exec borgmatic \
  borgmatic --config /etc/borgmatic.d/local.yaml create --stats --list
```

Si ese backup falla, no consideres cerrada la recuperación. Un host recuperado sin nueva política de backup activa sigue en estado frágil.

### 13. Cierre del incidente y tareas posteriores

Cuando el sistema vuelva a estar estable, deja rastro operativo.

Ruta sugerida:

```text
/mnt/hd2t/backups/reports/operations/
```

Qué conviene registrar:

- fecha y hora del incidente
- causa probable del fallo
- archive Borg y dumps usados
- servicios que necesitaron restore adicional
- cambios de hardware realizados
- validaciones completadas
- tareas pendientes o riesgos residuales

Acciones posteriores recomendadas:

1. sustituir definitivamente el NVMe o la carcasa si el fallo fue físico
2. revisar SMART de las unidades supervivientes
3. confirmar que Tailscale y el acceso administrativo vuelven a estar operativos
4. ejecutar una restauración de prueba pequeña semanas después para no confiar solo en este incidente real

## Almacenamiento
Rutas clave en una recuperación completa:

- sistema y datos restaurados: `/home/<usuario>/homelab/`
- repositorio Borg local: `/mnt/hd2t/backups/borgmatic/local/`
- dumps y exports: `/mnt/hd2t/backups/exports/`
- informes y logs de backup: `/mnt/hd2t/backups/reports/`
- restauraciones de prueba: `/mnt/hd2t/backups/restore-test/`
- multimedia general y descargas: `/mnt/hd2t/`
- biblioteca de Stash: `/mnt/hd5t/`

Principios de almacenamiento durante el desastre:

- el nuevo NVMe vuelve a ser el origen principal de `compose/`, `env/`, `scripts/` y `data/`
- `hd2t` actúa como soporte de recuperación local del NVMe, no como backup de sí mismo
- `hd5t` no necesita copiarse durante esta recuperación si sigue sano y montado en la misma ruta

## Backup
Este documento depende directamente de que la estrategia de backup crítica del NVMe esté funcionando de verdad.

Qué debe existir para que este runbook sea viable:

- repositorio Borg local utilizable en `hd2t`
- passphrase de Borg disponible fuera del NVMe
- dumps recientes de MariaDB y PostgreSQL en `exports/`
- `compose/`, `env/`, `scripts/` y `data/` incluidos en el backup versionado
- informes recientes en `reports/` para identificar el último job sano

Qué conviene revisar al terminar la recuperación:

- que el stack `borgmatic` vuelve a arrancar
- que el repositorio local sigue siendo legible
- que el primer backup post-recuperación termina sin error
- que la copia offsite, si existe, vuelve a sincronizar

Riesgos que este documento no elimina:

- pérdida simultánea de NVMe y `hd2t`
- pérdida de la passphrase de Borg
- corrupción no detectada si nunca se validan restauraciones de prueba
- pérdida de datos cuyo único original estaba en `hd2t` o `hd5t`

## Referencias
- Documentación interna:
  - `docs/00-hardware/03-preparacion-discos.md`
  - `docs/00-hardware/05-arranque-nvme.md`
  - `docs/01-sistema/01-instalacion-os.md`
  - `docs/02-docker/01-instalacion-docker.md`
  - `docs/02-docker/02-estructura-compose.md`
  - `docs/07-backups/01-estrategia-backup.md`
  - `docs/07-backups/02-borgmatic.md`
  - `docs/07-backups/03-backup-docker-volumes.md`
- Documentación oficial:
  - Raspberry Pi Imager: `https://www.raspberrypi.com/software/`
  - Docker Engine on Debian: `https://docs.docker.com/engine/install/debian/`
  - Docker Compose CLI: `https://docs.docker.com/compose/reference/`
  - BorgBackup CLI: `https://borgbackup.readthedocs.io/en/stable/usage/list.html`
  - Borg extract: `https://borgbackup.readthedocs.io/en/stable/usage/extract.html`
