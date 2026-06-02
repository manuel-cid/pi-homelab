# Disaster Recovery

## Descripción

Este documento define el procedimiento de recuperación ante fallo del homelab sobre **Raspberry Pi 5** cuando el host deja de ser operativo o el **SSD NVMe** debe reconstruirse. El objetivo no es reparar en caliente cada incidencia menor, sino recuperar un estado funcional y coherente a partir de:

- reinstalación o restauración del sistema en el **SSD NVMe**
- reinstalación de **Docker Engine** y del plugin **Docker Compose**
- recuperación de `compose`, configuración, datos persistentes y dumps desde **`hd2t`**
- validación final de servicios, montajes, red y acceso interno

La idea base de esta fase es simple:

- el **host** se puede reinstalar
- los **contenedores** se pueden recrear
- lo importante son los **datos**, la **configuración** y los **secretos**
- la recuperación solo termina cuando los servicios vuelven a responder y los datos son correctos

Este procedimiento cubre el escenario principal definido por el proyecto:

- **SSD NVMe**: sistema operativo, Docker, `compose`, configuración y datos persistentes
- **`hd2t`**: backups locales y multimedia general
- **`hd5t`**: contenido multimedia grande de **Stash**

## Requisitos Previos

- Haber completado [05-arranque-nvme.md](../00-hardware/05-arranque-nvme.md).
- Haber completado [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber completado [02-borgmatic.md](../07-backups/02-borgmatic.md).
- Haber completado [03-backup-docker-volumes.md](../07-backups/03-backup-docker-volumes.md).
- Tener acceso físico a la **Raspberry Pi 5**, al **SSD NVMe**, a **`hd2t`** y a **`hd5t`**.
- Disponer de un medio de instalación válido de **Raspberry Pi OS Lite 64-bit** o equivalente.
- Poder acceder por terminal con un usuario con permisos de `sudo`.
- Tener disponible el disco **`hd2t`** con el repositorio Borg y los exports de restore:
  - `/mnt/hd2t/backups/borg/`
  - `/mnt/hd2t/backups/exports/`
- Conocer o poder recuperar secretos críticos:
  - claves SSH del host
  - passphrase del repositorio Borg
  - `.env` globales y por stack
  - credenciales de bases de datos
  - credenciales de **Tailscale**

Puertos necesarios en esta fase:

- ninguno adicional a los ya definidos en el proyecto

## Docker Compose

No aplica en este documento. Aquí se define un procedimiento de recuperación del host y de los stacks ya existentes.

## Configuración

### 1. Cuándo activar este procedimiento

Usa este runbook cuando ocurra alguno de estos casos:

- el **SSD NVMe** falla o deja de arrancar
- el sistema del host queda corrupto y no compensa repararlo sobre la marcha
- una actualización deja el host en un estado no recuperable con seguridad
- necesitas reconstruir el homelab completo sobre un **NVMe** nuevo

No lo uses como primera respuesta para incidencias pequeñas como:

- un solo contenedor caído
- una configuración rota en un servicio concreto
- un problema puntual de red que no afecta al host completo

En esos casos conviene restaurar solo el servicio afectado.

### 2. Prioridades de recuperación

El orden correcto es este:

1. recuperar el **host** sobre el **SSD NVMe**
2. volver a montar correctamente **`hd2t`** y **`hd5t`**
3. reinstalar **Docker**
4. restaurar `compose`, `config`, `.env`, scripts y datos persistentes
5. restaurar dumps o named volumes si aplica
6. levantar stacks en orden controlado
7. verificar acceso, integridad y estado operativo

Regla importante:

- no levantes todos los stacks a la vez si todavía no has validado datos, secretos y montajes

### 3. Evaluación inicial del incidente

Antes de tocar nada, identifica qué ha fallado realmente.

Comprobaciones útiles:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL
sudo blkid
sudo fdisk -l
```

Qué debes clasificar:

- si el problema está solo en el **NVMe**
- si **`hd2t`** sigue sano y legible
- si **`hd5t`** sigue sano y legible
- si el fallo afecta también a la fuente, carcasa, cable USB o adaptador NVMe

Si `hd2t` no es legible, detén el procedimiento y prioriza preservar ese disco, porque contiene los backups locales del proyecto.

### 4. Escenario A: restaurar el sistema en el SSD NVMe

Si el **NVMe** sigue siendo reutilizable, o si lo sustituyes por uno nuevo, reconstruye primero el sistema base siguiendo [05-arranque-nvme.md](../00-hardware/05-arranque-nvme.md).

El resultado mínimo que debes obtener antes de seguir es este:

- la Raspberry Pi 5 arranca desde el **SSD NVMe**
- el usuario administrativo puede entrar por consola o SSH
- la red local funciona
- el sistema usa zona horaria correcta
- el firmware y el boot order quedan validados

Comprobaciones mínimas tras el arranque:

```bash
findmnt -no SOURCE /
hostnamectl
ip a
df -h /
```

Resultado esperado:

- `/` montado desde el **NVMe**, no desde microSD
- hostname correcto
- conectividad LAN funcional
- espacio libre suficiente en el **NVMe**

### 5. Montar de nuevo hd2t y hd5t

Una vez que el host arranca correctamente, conecta y valida los discos USB.

Comandos base:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,MODEL
findmnt /mnt/hd2t
findmnt /mnt/hd5t
df -h /mnt/hd2t
df -h /mnt/hd5t
```

Debes confirmar:

- **`hd2t`** montado en `/mnt/hd2t`
- **`hd5t`** montado en `/mnt/hd5t`
- permisos de lectura y escritura correctos
- presencia del repositorio Borg y de los exports

Verificación mínima:

```bash
ls -lah /mnt/hd2t/backups
ls -lah /mnt/hd2t/backups/exports
ls -lah /mnt/hd2t/backups/borg
```

No continúes con la restauración de servicios si los discos no están montados exactamente en las rutas esperadas.

### 6. Reinstalar Docker y preparar la base del homelab

Con el sistema estable y los discos montados, reinstala Docker siguiendo [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).

Antes de restaurar datos, valida el runtime:

```bash
docker version
docker info
docker compose version
docker ps
```

Además, vuelve a crear la estructura base si el sistema es limpio:

```bash
mkdir -p /home/<user>/homelab
mkdir -p /home/<user>/homelab/compose
mkdir -p /home/<user>/homelab/config
mkdir -p /home/<user>/homelab/data
mkdir -p /home/<user>/homelab/scripts
```

Regla práctica:

- primero deja operativo el host
- después restaura el árbol `/home/<user>/homelab/`
- solo entonces recrea contenedores

### 7. Restaurar la configuración y los datos desde Borg

La recuperación base del proyecto se hace restaurando desde el repositorio definido en [02-borgmatic.md](../07-backups/02-borgmatic.md).

Primero, identifica los archivos disponibles:

```bash
cd /home/<user>/homelab
docker run --rm \
  -v /mnt/hd2t/backups/borg:/mnt/borg-repository \
  -v /mnt/hd2t/backups/restore-test:/mnt/restore \
  -it modem7/borgmatic-docker:latest \
  borg list /mnt/borg-repository/$(hostname)
```

Si prefieres restaurar con Borg/Borgmatic instalado temporalmente en el host, puedes hacerlo, pero mantén la restauración inicial fuera de producción.

Ruta de trabajo recomendada:

```bash
mkdir -p /mnt/hd2t/backups/restore-test/full-host
```

Ejemplo genérico de extracción:

```bash
docker run --rm \
  -v /mnt/hd2t/backups/borg:/mnt/borg-repository \
  -v /mnt/hd2t/backups/restore-test/full-host:/mnt/restore \
  -it modem7/borgmatic-docker:latest \
  borg extract /mnt/borg-repository/$(hostname)::$(hostname)-homelab-<fecha> \
    source/homelab/compose \
    source/homelab/config \
    source/homelab/scripts \
    source/homelab/data \
    source/homelab/.env
```

Después, copia de vuelta al árbol operativo:

```bash
rsync -aHAX /mnt/hd2t/backups/restore-test/full-host/source/homelab/compose/ /home/<user>/homelab/compose/
rsync -aHAX /mnt/hd2t/backups/restore-test/full-host/source/homelab/config/ /home/<user>/homelab/config/
rsync -aHAX /mnt/hd2t/backups/restore-test/full-host/source/homelab/scripts/ /home/<user>/homelab/scripts/
rsync -aHAX /mnt/hd2t/backups/restore-test/full-host/source/homelab/data/ /home/<user>/homelab/data/
cp /mnt/hd2t/backups/restore-test/full-host/source/homelab/.env /home/<user>/homelab/.env
```

Validaciones obligatorias antes de arrancar contenedores:

- existen los directorios `compose/`, `config/`, `data/` y `scripts/`
- los `.env` restaurados corresponden al host correcto
- los permisos y propietarios son coherentes con cada servicio
- las claves y secretos críticos están presentes

### 8. Restaurar exports, dumps y named volumes si aplica

La restauración detallada por tipo de dato se documenta en [03-backup-docker-volumes.md](../07-backups/03-backup-docker-volumes.md). En un desastre real, úsalo así:

- **bind mounts**: restaura desde Borg a ruta temporal y sincroniza de vuelta al **NVMe**
- **MariaDB/PostgreSQL**: importa dumps lógicos desde `/mnt/hd2t/backups/exports/`
- **named volumes**: recrea el volumen y restaura su `tar.gz`
- **SQLite**: sustituye el fichero solo con el servicio detenido

Comprobaciones previas:

```bash
find /mnt/hd2t/backups/exports -maxdepth 3 -type f | sort
docker volume ls
```

No mezcles a ciegas una copia antigua de `data/` con un dump reciente de base de datos o al revés. El criterio correcto es restaurar un conjunto temporalmente coherente.

### 9. Orden recomendado para volver a levantar servicios

No conviene arrancar todo el homelab de golpe. El orden más seguro es:

1. infraestructura base
2. bases de datos
3. reverse proxy y acceso
4. aplicaciones con estado
5. servicios multimedia pesados

Orden práctico orientativo:

1. `tailscale`
2. `borgmatic`
3. `mariadb` y/o `postgres`
4. `caddy`
5. `authelia`, `lldap`, `vaultwarden` u otros servicios de acceso
6. aplicaciones web con base de datos
7. servicios multimedia sobre `hd2t`
8. **Stash** y cargas grandes sobre `hd5t`

Ejemplo por stack:

```bash
cd /home/<user>/homelab/compose/<stack>
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=100
```

Reglas de esta fase:

- valida cada stack antes de seguir con el siguiente
- si una base de datos no arranca limpia, no levantes todavía sus aplicaciones dependientes
- si falta un mount externo, detén el arranque del servicio afectado

### 10. Verificación final de recuperación

La recuperación solo se considera completada cuando validas host, datos y acceso.

Checklist mínimo del host:

```bash
uptime
df -h /
df -h /mnt/hd2t
df -h /mnt/hd5t
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
systemctl --failed
```

Checklist mínimo de datos:

- el contenido restaurado existe en `/home/<user>/homelab/data/`
- los servicios críticos ven sus bases de datos
- las bibliotecas en `hd2t` y `hd5t` siguen accesibles
- los logs no muestran migraciones fallidas ni errores de permisos

Checklist mínimo de acceso:

- acceso por **LAN** a los servicios principales
- acceso remoto por **Tailscale** si aplica
- login correcto en servicios críticos
- reverse proxy respondiendo en los endpoints previstos

Comandos útiles:

```bash
docker logs --tail=100 <contenedor>
journalctl -u docker --since "1 hour ago" --no-pager
tailscale status
```

### 11. Cierre del incidente

Una vez recuperado el entorno:

1. ejecuta un backup nuevo lo antes posible
2. documenta qué se restauró exactamente y desde qué fecha
3. anota cualquier secreto rotado o cambio manual aplicado durante la recuperación
4. revisa por qué falló el host y qué acción preventiva corresponde

Si el incidente obligó a cambiar discos, carcasa o cableado, conviene además repetir la comprobación SMART y revisar temperatura y estabilidad en los días siguientes.

## Almacenamiento

Durante la recuperación, cada dato debe volver a su sitio original:

- **sistema operativo y Docker**: **SSD NVMe**
- **árbol del proyecto**: `/home/<user>/homelab/`
- **datos persistentes de servicios**: `/home/<user>/homelab/data/`
- **`compose` y configuración**: `/home/<user>/homelab/compose/` y `/home/<user>/homelab/config/`
- **backups locales y exports**: `/mnt/hd2t/backups/`
- **multimedia general**: `hd2t`
- **biblioteca grande de Stash**: `hd5t`

Reglas importantes:

- no restaures datos persistentes en la microSD
- no dejes `compose` ni `.env` operativos dentro de `hd2t`
- no arranques servicios que esperan `hd5t` si ese disco no está montado correctamente

## Backup

Este documento depende directamente de que la estrategia de backup sea restaurable. Para que este procedimiento funcione de verdad, debes tener respaldado como mínimo:

- `/home/<user>/homelab/compose/`
- `/home/<user>/homelab/config/`
- `/home/<user>/homelab/scripts/`
- `/home/<user>/homelab/data/`
- `/home/<user>/homelab/.env`
- dumps lógicos de **MariaDB** y **PostgreSQL** en `/mnt/hd2t/backups/exports/`
- exports de **named volumes** si existen
- passphrases, claves y secretos necesarios para abrir el repositorio y reconfigurar acceso

Prueba operativa recomendada:

- al menos una vez por trimestre, restaura un servicio completo en `/mnt/hd2t/backups/restore-test/` y valida que este runbook sigue siendo realista

## Referencias

- Raspberry Pi Docs: [Raspberry Pi bootloader and boot order](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#bootloader)
- Raspberry Pi Docs: [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
- Borg Documentation: [borg list](https://borgbackup.readthedocs.io/en/stable/usage/list.html)
- Borg Documentation: [borg extract](https://borgbackup.readthedocs.io/en/stable/usage/extract.html)
- rsync Documentation: [rsync(1)](https://download.samba.org/pub/rsync/rsync.1)
