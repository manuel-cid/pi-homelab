# Samba

## Descripción

**Samba** permite exponer carpetas del homelab por **SMB/CIFS** para acceder a ellas desde **Windows, macOS y Linux** sin abrir puertos en el router ni depender de servicios externos. En este proyecto se usa como capa de compartición de archivos dentro de la **LAN** y, si se desea, también a través de **Tailscale**.

La política de almacenamiento no cambia:

- los datos operativos y persistentes de servicios siguen viviendo en el **SSD NVMe**
- **`hd2t`** sigue siendo el disco de bibliotecas multimedia y descargas
- **`hd5t`** solo se comparte si quieres acceso SMB directo a la biblioteca multimedia dedicada de ese disco

El objetivo de este documento es desplegar Samba como contenedor Docker con **un share por carpeta** en `hd2t`, de forma predecible y con permisos coherentes con la estructura definida en [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Tener Docker Engine y Docker Compose operativos según [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber fijado la convención de stacks y `.env` descrita en [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Tener montados `hd2t` y `hd5t` en `/media/hd2t` y `/media/hd5t`.
- Poder administrar el firewall del host según [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md).
- Haber decidido qué usuario local del host será el propietario real de las carpetas compartidas.
- Puertos necesarios para Samba:
  - **137/udp**
  - **138/udp**
  - **139/tcp**
  - **445/tcp**

## Objetivo de esta Fase

Al terminar este documento, el estado esperado es este:

- Samba queda desplegado como stack propio `files-samba`.
- `hd2t` queda expuesto por shares independientes para `movies`, `tv`, `music`, `audiobooks`, `podcasts`, `books` y `downloads`.
- `hd5t` puede exponerse opcionalmente como share `library`.
- Los accesos SMB requieren usuario y contraseña; no se usa acceso invitado.
- Los permisos en disco quedan alineados con el `UID` y `GID` del usuario operativo del host.

## Docker Compose

Archivo: `/home/<user>/homelab/compose/files-samba/docker-compose.yml`

Sustituye `<user>` por el usuario real del host que administra el homelab.

```yaml
name: files-samba

services:
  samba:
    image: ghcr.io/servercontainers/samba:a3.24.1-s4.23.8-r0
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    env_file:
      - .env
    ports:
      - "${SAMBA_BIND_IP}:137:137/udp"
      - "${SAMBA_BIND_IP}:138:138/udp"
      - "${SAMBA_BIND_IP}:139:139/tcp"
      - "${SAMBA_BIND_IP}:445:445/tcp"
    environment:
      TZ: ${TZ}
      ACCOUNT_media: ${SAMBA_ACCOUNT_MEDIA}
      UID_media: ${PUID}
      SAMBA_CONF_WORKGROUP: ${SAMBA_WORKGROUP}
      SAMBA_CONF_SERVER_STRING: ${SAMBA_SERVER_STRING}
      SAMBA_CONF_MAP_TO_GUEST: Never
      WSDD2_DISABLE: "1"
      AVAHI_DISABLE: "1"
      SAMBA_VOLUME_CONFIG_movies: |
        [movies]
        path = /shares/movies
        valid users = media
        guest ok = no
        read only = no
        browseable = yes
        force user = media
        create mask = 0664
        directory mask = 2775
      SAMBA_VOLUME_CONFIG_tv: |
        [tv]
        path = /shares/tv
        valid users = media
        guest ok = no
        read only = no
        browseable = yes
        force user = media
        create mask = 0664
        directory mask = 2775
      SAMBA_VOLUME_CONFIG_music: |
        [music]
        path = /shares/music
        valid users = media
        guest ok = no
        read only = no
        browseable = yes
        force user = media
        create mask = 0664
        directory mask = 2775
      SAMBA_VOLUME_CONFIG_audiobooks: |
        [audiobooks]
        path = /shares/audiobooks
        valid users = media
        guest ok = no
        read only = no
        browseable = yes
        force user = media
        create mask = 0664
        directory mask = 2775
      SAMBA_VOLUME_CONFIG_books: |
        [books]
        path = /shares/books
        valid users = media
        guest ok = no
        read only = no
        browseable = yes
        force user = media
        create mask = 0664
        directory mask = 2775
      SAMBA_VOLUME_CONFIG_downloads: |
        [downloads]
        path = /shares/downloads
        valid users = media
        guest ok = no
        read only = no
        browseable = yes
        force user = media
        create mask = 0664
        directory mask = 2775
      SAMBA_VOLUME_CONFIG_podcasts: |
        [podcasts]
        path = /shares/podcasts
        valid users = media
        guest ok = no
        read only = no
        browseable = yes
        force user = media
        create mask = 0664
        directory mask = 2775
      SAMBA_VOLUME_CONFIG_library: |
        [library]
        path = /shares/library
        valid users = media
        guest ok = no
        read only = no
        browseable = yes
        force user = media
        create mask = 0664
        directory mask = 2775
    volumes:
      - /media/hd2t/media/movies:/shares/movies
      - /media/hd2t/media/tv:/shares/tv
      - /media/hd2t/media/music:/shares/music
      - /media/hd2t/media/audiobooks:/shares/audiobooks
      - /media/hd2t/media/books:/shares/books
      - /media/hd2t/downloads:/shares/downloads
      - /media/hd2t/media/podcasts:/shares/podcasts
      - /media/hd5t/media:/shares/library
    labels:
      - wud.watch=true
      - "wud.tag.include=^a\\d+\\.\\d+\\.\\d+-s\\d+\\.\\d+\\.\\d+-r\\d+$$"
```

Este Compose sigue la política general del proyecto:

- stack independiente para el servicio de archivos
- publicación directa solo de los puertos SMB estándar
- sin acceso invitado
- shares por carpeta en los discos USB
- datos de usuario reales conservados en `hd2t` y `hd5t`, no dentro del contenedor

Si **no** quieres compartir `hd5t`, elimina estas dos secciones del Compose:

- `SAMBA_VOLUME_CONFIG_library: | ...`
- `- /media/hd5t/media:/shares/library`

## Configuración

### 1. Verificar la estructura de carpetas que se va a compartir

Comprueba que las rutas del proyecto existen realmente:

```bash
find /media/hd2t/media -maxdepth 2 -type d | sort
find /media/hd2t/downloads -maxdepth 1 -type d | sort
find /media/hd5t -maxdepth 2 -type d | sort
```

Si todavía faltan carpetas, créalas:

```bash
sudo mkdir -p /media/hd2t/media/{movies,tv,music,audiobooks,books,podcasts}
sudo mkdir -p /media/hd2t/downloads
sudo mkdir -p /media/hd5t/media
```

### 2. Alinear propiedad y permisos del host

Samba escribirá con el mismo `UID` y `GID` del usuario operativo del host. Usa el mismo usuario que ya administra Docker y la estructura del homelab:

```bash
id <user>
sudo chown -R <user>:<user> /media/hd2t/media
sudo chown -R <user>:<user> /media/hd2t/downloads
sudo chown -R <user>:<user> /media/hd5t/media

sudo find /media/hd2t/media -type d -exec chmod 2775 {} \;
sudo find /media/hd2t/media -type f -exec chmod 0664 {} \;
sudo find /media/hd2t/downloads -type d -exec chmod 2775 {} \;
sudo find /media/hd2t/downloads -type f -exec chmod 0664 {} \;
sudo find /media/hd5t/media -type d -exec chmod 2775 {} \;
sudo find /media/hd5t/media -type f -exec chmod 0664 {} \;
```

Qué se consigue con esto:

- el usuario real del host conserva el control sobre los archivos
- Samba escribe con ese mismo `UID` y `GID`
- los directorios nuevos heredan permisos de grupo razonables gracias al bit `setgid`

Si reutilizas discos con **NTFS** o **exFAT** según [04-discos-con-datos.md](../00-hardware/04-discos-con-datos.md), recuerda que los permisos efectivos dependen sobre todo de las opciones de montaje del host; los `chmod` anteriores pueden no tener efecto real en esos sistemas de archivos.

### 3. Crear el directorio del stack

```bash
mkdir -p /home/<user>/homelab/compose/files-samba
```

### 4. Crear el fichero `.env`

Archivo: `/home/<user>/homelab/compose/files-samba/.env`

Sustituye los valores de ejemplo antes de desplegar:

- `<user>` por el usuario real del host
- `PUID` por el UID real de ese usuario
- `cambiar-esta-clave` por una contraseña robusta
- `SAMBA_BIND_IP` por la IP LAN fija de la Raspberry Pi si no quieres exponer SMB en todas las interfaces del host

```dotenv
TZ=Europe/Madrid
PUID=1000
SAMBA_BIND_IP=0.0.0.0
SAMBA_WORKGROUP=WORKGROUP
SAMBA_SERVER_STRING=Homelab Samba
SAMBA_ACCOUNT_MEDIA=cambiar-esta-clave
```

Notas importantes:

- `SAMBA_ACCOUNT_MEDIA` contiene solo la contraseña. El nombre de usuario lo toma la imagen del sufijo de la variable `ACCOUNT_media` definida en el Compose.
- `PUID` debe coincidir con el UID real del usuario del host que posee las carpetas. El GID se crea automáticamente dentro del contenedor al crear la cuenta.
- `SAMBA_BIND_IP=0.0.0.0` expone SMB en todas las interfaces del host, incluida `tailscale0` si existe y el firewall lo permite.
- Si prefieres limitar Samba solo a la LAN principal del host, publica en la IP LAN fija de la Raspberry Pi en lugar de `0.0.0.0`.

Protege el fichero:

```bash
chmod 600 /home/<user>/homelab/compose/files-samba/.env
```

### 5. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/files-samba
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=50 samba
```

Validaciones útiles en el host:

```bash
ss -lunp | grep -E ':137|:138'
ss -ltnp | grep -E ':139|:445'
```

El resultado esperado es que el contenedor quede en estado `Up` y que el host escuche en los cuatro puertos estándar de SMB.

### 6. Ajustar el firewall del host

Si usas `ufw`, añade las excepciones solo para la red local:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 137 proto udp comment 'Samba NBNS LAN'
sudo ufw allow from 192.168.1.0/24 to any port 138 proto udp comment 'Samba datagram LAN'
sudo ufw allow from 192.168.1.0/24 to any port 139 proto tcp comment 'Samba session LAN'
sudo ufw allow from 192.168.1.0/24 to any port 445 proto tcp comment 'Samba SMB LAN'
sudo ufw status verbose
```

Si también quieres usar Samba por **Tailscale**, añade además:

```bash
sudo ufw allow in on tailscale0 to any port 445 proto tcp comment 'Samba SMB Tailscale'
sudo ufw allow in on tailscale0 to any port 139 proto tcp comment 'Samba session Tailscale'
```

En la práctica, para clientes modernos suele bastar `445/tcp`, pero mantener `139/tcp` evita sorpresas con herramientas o clientes heredados. Los puertos `137/udp` y `138/udp` no suelen ser necesarios en Tailscale porque el acceso se hace normalmente por IP o MagicDNS, no por descubrimiento NetBIOS.

### 7. Acceso desde Windows, macOS y Linux

Rutas típicas de acceso:

- **Windows**: `\\<ip-o-hostname>\movies`
- **Windows**: `\\<ip-o-hostname>\downloads`
- **Windows**: `\\<ip-o-hostname>\library` si expones `hd5t`
- **macOS**: `smb://<ip-o-hostname>/movies`
- **Linux**: `smb://<ip-o-hostname>/movies`

Sustituye `<ip-o-hostname>` por una de estas opciones, según cómo accedas al homelab:

- la IP LAN fija de la Raspberry Pi
- el hostname local si tu red lo resuelve correctamente
- el nombre MagicDNS de Tailscale si accedes por la VPN mesh

Credenciales:

- usuario: `media`
- contraseña: la definida en `SAMBA_ACCOUNT_MEDIA`

Pasos rápidos por sistema:

- **Windows**: Explorador de archivos → barra de direcciones → `\\<ip-o-hostname>\movies`
- **macOS**: Finder → `Ir` → `Conectarse al servidor` → `smb://<ip-o-hostname>/movies`
- **Linux (GNOME/KDE)**: gestor de archivos → `Otras ubicaciones` → `smb://<ip-o-hostname>/movies`

Si la detección automática en la red no muestra el servidor, no es un error: en este despliegue se prioriza acceso directo por **IP** o **hostname** y se desactivan los componentes adicionales de descubrimiento (`wsdd2` y `avahi`) para mantener la exposición mínima.

### 8. Prueba funcional desde el host

Si tienes `smbclient` instalado en la Raspberry Pi, puedes validar los shares publicados:

```bash
smbclient -L //127.0.0.1 -U media
```

Deberías ver al menos estos recursos:

- `movies`
- `tv`
- `music`
- `audiobooks`
- `podcasts`
- `books`
- `downloads`
- `library` si no has eliminado el share opcional

## Almacenamiento

Rutas implicadas en este despliegue:

- `docker-compose.yml`: `/home/<user>/homelab/compose/files-samba/docker-compose.yml`
- `.env`: `/home/<user>/homelab/compose/files-samba/.env`
- share `movies`: `/media/hd2t/media/movies`
- share `tv`: `/media/hd2t/media/tv`
- share `music`: `/media/hd2t/media/music`
- share `audiobooks`: `/media/hd2t/media/audiobooks`
- share `podcasts`: `/media/hd2t/media/podcasts`
- share `books`: `/media/hd2t/media/books`
- share `downloads`: `/media/hd2t/downloads`
- share opcional `library`: `/media/hd5t/media`

Reglas operativas recomendadas:

- no compartas por SMB los directorios persistentes de aplicaciones en `/home/<user>/homelab/data/`
- no expongas `/media/hd2t/backups` por defecto; las copias de seguridad deben permanecer menos expuestas que la biblioteca multimedia
- usa el mismo `PUID` y `PGID` en Samba que en el resto del homelab para evitar archivos con propietarios incoherentes
- si más adelante creas nuevas carpetas multimedia en `hd2t`, añade un share nuevo en lugar de reutilizar uno ambiguo

## Backup

Para Samba no hay una base de datos propia importante dentro del contenedor. Lo que debes respaldar es esto:

- `/home/<user>/homelab/compose/files-samba/docker-compose.yml`
- `/home/<user>/homelab/compose/files-samba/.env`
- el contenido real de las carpetas compartidas:
  - `/media/hd2t/media/`
  - `/media/hd2t/downloads/`
  - `/media/hd5t/media/` si se comparte

No hace falta respaldar estado interno efímero del contenedor si mantienes:

- el `docker-compose.yml`
- el `.env`
- la estructura y permisos correctos en disco

La estrategia general y la automatización de estas copias se documentan en:

- [01-estrategia-backup.md](../07-backups/01-estrategia-backup.md)
- [03-backup-docker-volumes.md](../07-backups/03-backup-docker-volumes.md)

## Referencias

- Samba: https://www.samba.org/
- ServerContainers Samba: https://github.com/ServerContainers/samba
- GHCR: https://github.com/ServerContainers/samba/pkgs/container/samba
- Docker Compose file reference: https://docs.docker.com/compose/compose-file/
