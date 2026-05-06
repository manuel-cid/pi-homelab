# Samba

## Descripción
**Samba** permitirá publicar por SMB/CIFS las carpetas multimedia del homelab para acceder a ellas desde **Windows, macOS y Linux** sin exponer nada a internet.

En esta arquitectura el servicio se usa como una capa de compartición de archivos para:

- publicar por separado las carpetas de `hd2t` usadas por Jellyfin, Navidrome, Audiobookshelf, Calibre-Web y descargas
- exponer opcionalmente la biblioteca de `hd5t` usada por Stash
- mantener los datos reales en los discos externos, no dentro del contenedor
- limitar el acceso a la **LAN** y, cuando haga falta, a través de **Tailscale**

No hay base de datos ni lógica de aplicación compleja: lo importante en Samba es que las rutas compartidas, los permisos POSIX del host y los usuarios SMB queden alineados.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Tener montados y accesibles:
  - `/mnt/hd2t`
  - `/mnt/hd5t` si vas a exportar la biblioteca de Stash
- Tener creadas al menos estas rutas en `hd2t`:
  - `/mnt/hd2t/jellyfin/media`
  - `/mnt/hd2t/navidrome/music`
  - `/mnt/hd2t/audiobookshelf/audiobooks`
  - `/mnt/hd2t/audiobookshelf/podcasts`
  - `/mnt/hd2t/calibre/library`
  - `/mnt/hd2t/downloads/transmission`
- Poder usar `sudo` con el usuario administrador del homelab.
- Puertos implicados:
  - `445/tcp` para acceso SMB moderno
  - `139/tcp` para compatibilidad con clientes antiguos
  - `137/udp` y `138/udp` para descubrimiento NetBIOS en LAN
  - el contenedor usa `network_mode: host`, así que esos puertos quedan abiertos en el host solo dentro de tu red local y Tailscale

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/samba/
├── compose.yaml
└── .env
```

Preparación inicial de rutas y permisos base:

```bash
mkdir -p /home/<usuario>/homelab/compose/samba
sudo mkdir -p \
  /mnt/hd2t/jellyfin/media \
  /mnt/hd2t/navidrome/music \
  /mnt/hd2t/audiobookshelf/audiobooks \
  /mnt/hd2t/audiobookshelf/podcasts \
  /mnt/hd2t/calibre/library \
  /mnt/hd2t/downloads/transmission

sudo chown -R <usuario>:<usuario> /mnt/hd2t/jellyfin /mnt/hd2t/navidrome /mnt/hd2t/audiobookshelf /mnt/hd2t/calibre /mnt/hd2t/downloads
sudo find /mnt/hd2t/jellyfin /mnt/hd2t/navidrome /mnt/hd2t/audiobookshelf /mnt/hd2t/calibre /mnt/hd2t/downloads -type d -exec chmod 2775 {} \;
sudo find /mnt/hd2t/jellyfin /mnt/hd2t/navidrome /mnt/hd2t/audiobookshelf /mnt/hd2t/calibre /mnt/hd2t/downloads -type f -exec chmod 664 {} \;
```

Si vas a compartir también Stash:

```bash
sudo mkdir -p /mnt/hd5t/stash/data
sudo chown -R <usuario>:<usuario> /mnt/hd5t/stash
sudo find /mnt/hd5t/stash -type d -exec chmod 2775 {} \;
sudo find /mnt/hd5t/stash -type f -exec chmod 664 {} \;
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

SAMBA_IMAGE=ghcr.io/servercontainers/samba:latest

SAMBA_HOSTNAME=rpi5-samba
SAMBA_WORKGROUP=WORKGROUP
SAMBA_SERVER_STRING=Homelab Samba

SAMBA_USER=homelab
SAMBA_PASSWORD=<CAMBIA_ESTA_PASSWORD>
SAMBA_UID=1000

HD2T_ROOT=/mnt/hd2t
HD5T_ROOT=/mnt/hd5t
```

Notas sobre `.env`:

- `SAMBA_USER` es la cuenta SMB que usarán los clientes. No tiene por qué coincidir con el nombre del usuario Linux del host.
- `SAMBA_UID` debe coincidir con el UID real del usuario propietario de las carpetas del host. Compruébalo con `id -u <usuario>`.
- si el GID principal de `<usuario>` no coincide con el esperado, revisa también `id -g <usuario>` y ajusta los permisos del host antes de levantar el stack
- en este documento se usa una única cuenta SMB para simplificar la operación del homelab
- el sufijo de `ACCOUNT_homelab` y `UID_homelab` en `compose.yaml` debe coincidir exactamente con el nombre de usuario SMB que crea el contenedor; si cambias `SAMBA_USER`, renombra también esas dos claves para usar el mismo sufijo
- si más adelante quieres separar usuarios por miembro de la familia, puedes añadir más variables `ACCOUNT_<usuario>` y restringir shares concretos

Fichero `compose.yaml`:

```yaml
name: samba

services:
  samba:
    container_name: samba
    image: ${SAMBA_IMAGE}
    hostname: ${SAMBA_HOSTNAME}
    restart: unless-stopped
    network_mode: host
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      AVAHI_NAME: ${SAMBA_HOSTNAME}
      FAIL_FAST: "1"
      SAMBA_CONF_WORKGROUP: ${SAMBA_WORKGROUP}
      SAMBA_CONF_SERVER_STRING: ${SAMBA_SERVER_STRING}
      SAMBA_CONF_LOG_LEVEL: "1"
      ACCOUNT_homelab: ${SAMBA_PASSWORD}
      UID_homelab: ${SAMBA_UID}

      SAMBA_VOLUME_CONFIG_jellyfin: |
        [jellyfin-media]
        path = /shares/jellyfin-media
        valid users = ${SAMBA_USER}
        browseable = yes
        read only = no
        guest ok = no
        force user = ${SAMBA_USER}
        create mask = 0664
        directory mask = 2775

      SAMBA_VOLUME_CONFIG_music: |
        [music]
        path = /shares/music
        valid users = ${SAMBA_USER}
        browseable = yes
        read only = no
        guest ok = no
        force user = ${SAMBA_USER}
        create mask = 0664
        directory mask = 2775

      SAMBA_VOLUME_CONFIG_audiobooks: |
        [audiobooks]
        path = /shares/audiobooks
        valid users = ${SAMBA_USER}
        browseable = yes
        read only = no
        guest ok = no
        force user = ${SAMBA_USER}
        create mask = 0664
        directory mask = 2775

      SAMBA_VOLUME_CONFIG_podcasts: |
        [podcasts]
        path = /shares/podcasts
        valid users = ${SAMBA_USER}
        browseable = yes
        read only = no
        guest ok = no
        force user = ${SAMBA_USER}
        create mask = 0664
        directory mask = 2775

      SAMBA_VOLUME_CONFIG_ebooks: |
        [ebooks]
        path = /shares/ebooks
        valid users = ${SAMBA_USER}
        browseable = yes
        read only = no
        guest ok = no
        force user = ${SAMBA_USER}
        create mask = 0664
        directory mask = 2775

      SAMBA_VOLUME_CONFIG_downloads: |
        [downloads]
        path = /shares/downloads
        valid users = ${SAMBA_USER}
        browseable = yes
        read only = no
        guest ok = no
        force user = ${SAMBA_USER}
        create mask = 0664
        directory mask = 2775

      # Share opcional para Stash.
      # Descomenta también el bind mount correspondiente en "volumes" si lo necesitas.
      # SAMBA_VOLUME_CONFIG_stash: |
      #   [stash]
      #   path = /shares/stash
      #   valid users = ${SAMBA_USER}
      #   browseable = yes
      #   read only = yes
      #   guest ok = no
      #   force user = ${SAMBA_USER}
      #   create mask = 0664
      #   directory mask = 2775
    volumes:
      - ${HD2T_ROOT}/jellyfin/media:/shares/jellyfin-media
      - ${HD2T_ROOT}/navidrome/music:/shares/music
      - ${HD2T_ROOT}/audiobookshelf/audiobooks:/shares/audiobooks
      - ${HD2T_ROOT}/audiobookshelf/podcasts:/shares/podcasts
      - ${HD2T_ROOT}/calibre/library:/shares/ebooks
      - ${HD2T_ROOT}/downloads/transmission:/shares/downloads
      # - ${HD5T_ROOT}/stash/data:/shares/stash
    security_opt:
      - no-new-privileges:true
```

Despliegue inicial:

```bash
cd /home/<usuario>/homelab/compose/samba
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f samba
```

Resultado esperado:

- el servicio escucha en el host por SMB
- los shares aparecen como recursos independientes
- no se publica ninguna aplicación web ni hace falta Caddy
- las rutas compartidas siguen viviendo en `hd2t` y opcionalmente en `hd5t`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| Tipo de acceso | LAN + Tailscale |
| Exposición pública | ninguna |
| Datos compartidos | bind mounts desde `hd2t` y opcionalmente `hd5t` |
| Autenticación | usuario SMB dedicado |
| Descubrimiento en LAN | SMB/NetBIOS y, según clientes, anuncios automáticos |
| Reverse proxy | no aplica |

### 1. Verificar UID y permisos reales del host

Antes de culpar a Samba, valida el lado host:

```bash
id <usuario>
ls -ld /mnt/hd2t/jellyfin/media
ls -ld /mnt/hd2t/navidrome/music
ls -ld /mnt/hd2t/audiobookshelf/audiobooks
ls -ld /mnt/hd2t/calibre/library
ls -ld /mnt/hd2t/downloads/transmission
```

Lo importante es que:

- el propietario del contenido sea el mismo UID que declaras en `SAMBA_UID`
- el usuario tenga escritura real sobre las carpetas que Samba exporta
- no dependas de permisos demasiado abiertos como `777`

Si detectas desalineación, corrígela antes de seguir:

```bash
sudo chown -R <usuario>:<usuario> /mnt/hd2t/jellyfin /mnt/hd2t/navidrome /mnt/hd2t/audiobookshelf /mnt/hd2t/calibre /mnt/hd2t/downloads
sudo find /mnt/hd2t/jellyfin /mnt/hd2t/navidrome /mnt/hd2t/audiobookshelf /mnt/hd2t/calibre /mnt/hd2t/downloads -type d -exec chmod 2775 {} \;
sudo find /mnt/hd2t/jellyfin /mnt/hd2t/navidrome /mnt/hd2t/audiobookshelf /mnt/hd2t/calibre /mnt/hd2t/downloads -type f -exec chmod 664 {} \;
```

### 2. Activar el share opcional de Stash solo si realmente lo necesitas

`hd5t` se reserva para **Stash**, así que no conviene exportarlo por SMB por defecto si no vas a administrarlo desde otros equipos.

Si sí quieres acceder a esa biblioteca:

1. Descomenta `SAMBA_VOLUME_CONFIG_stash` en `compose.yaml`.
2. Descomenta el bind mount `- ${HD5T_ROOT}/stash/data:/shares/stash`.
3. Mantén `read only = yes` salvo que tengas un motivo claro para editar ese contenido por SMB.
4. Recrea el stack:

```bash
cd /home/<usuario>/homelab/compose/samba
docker compose up -d
```

### 3. Acceso desde Windows

Formas de conexión recomendadas:

- Explorador de archivos:
  - `\\<ip-lan-de-la-pi>\jellyfin-media`
  - `\\<ip-lan-de-la-pi>\music`
  - `\\<ip-lan-de-la-pi>\downloads`
- si usas resolución local o MagicDNS y funciona en tu red:
  - `\\rpi5-samba\jellyfin-media`
  - `\\raspberrypi.tailnet.ts.net\jellyfin-media`

Si quieres montar una unidad:

1. Abre `Este equipo`.
2. Elige `Conectar a unidad de red`.
3. Introduce la ruta SMB del share.
4. Marca `Conectar con otras credenciales`.
5. Usa el usuario y contraseña definidos en `.env`.

Notas prácticas:

- por Tailscale, el descubrimiento automático suele ser peor que en LAN; usa la IP `100.x.y.z` o el nombre MagicDNS directamente
- si Windows no muestra el servidor en la vista de red, eso no implica que el share esté caído; prueba con la ruta UNC completa

### 4. Acceso desde macOS

En Finder:

1. `Ir` -> `Conectarse al servidor`.
2. Usa una URL como:
   - `smb://<ip-lan-de-la-pi>/jellyfin-media`
   - `smb://<ip-lan-de-la-pi>/music`
   - `smb://100.x.y.z/jellyfin-media` por Tailscale
3. Autentícate con el usuario SMB definido en `.env`.

Si quieres que el montaje reaparezca al iniciar sesión, añade el recurso montado a `Ítems de inicio` del usuario en macOS.

Nota para clientes Apple:

- esta imagen ya incorpora por defecto ajustes de compatibilidad para macOS e iOS
- evita desactivar esas extensiones salvo que estés resolviendo un problema concreto de compatibilidad con el sistema de ficheros subyacente

### 5. Acceso desde Linux

En gestores de archivos modernos suele bastar con:

- `smb://<ip-lan-de-la-pi>/jellyfin-media`
- `smb://<ip-lan-de-la-pi>/music`

Montaje manual temporal:

```bash
sudo mkdir -p /mnt/samba-jellyfin
sudo mount -t cifs //192.168.1.10/jellyfin-media /mnt/samba-jellyfin \
  -o username=<usuario>,vers=3.0,uid=$(id -u),gid=$(id -g)
```

Desmontaje:

```bash
sudo umount /mnt/samba-jellyfin
```

### 6. Comprobaciones rápidas

Desde la Raspberry Pi:

```bash
docker compose -f /home/<usuario>/homelab/compose/samba/compose.yaml logs --tail=100 samba
ss -tulpn | rg ':(137|138|139|445)\\b'
```

Desde un cliente Linux con `smbclient`:

```bash
smbclient -L //<ip-lan-de-la-pi> -U <usuario>
smbclient //<ip-lan-de-la-pi>/downloads -U <usuario>
```

Si algo falla, revisa en este orden:

1. permisos reales en `/mnt/hd2t` o `/mnt/hd5t`
2. que `SAMBA_UID` coincida con el propietario del host
3. que el cliente esté usando SMB moderno y no un protocolo legado
4. que ningún firewall local esté bloqueando `445/tcp`

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose de Samba | `/home/<usuario>/homelab/compose/samba/` | SSD NVMe |
| Variables del stack | `/home/<usuario>/homelab/compose/samba/.env` | SSD NVMe |
| Share `jellyfin-media` | `/mnt/hd2t/jellyfin/media/` | `hd2t` |
| Share `music` | `/mnt/hd2t/navidrome/music/` | `hd2t` |
| Share `audiobooks` | `/mnt/hd2t/audiobookshelf/audiobooks/` | `hd2t` |
| Share `podcasts` | `/mnt/hd2t/audiobookshelf/podcasts/` | `hd2t` |
| Share `ebooks` | `/mnt/hd2t/calibre/library/` | `hd2t` |
| Share `downloads` | `/mnt/hd2t/downloads/transmission/` | `hd2t` |
| Share opcional `stash` | `/mnt/hd5t/stash/data/` | `hd5t` |

Notas de almacenamiento:

- Samba no necesita una persistencia propia grande en el SSD NVMe; el valor está en la definición del stack y en los datos ya existentes en los discos
- `hd2t` es el disco principal para shares SMB de uso general en este homelab
- `hd5t` solo debe exportarse si realmente necesitas gestionar la biblioteca de Stash desde otros equipos
- no uses un único share sobre todo `/mnt/hd2t` si quieres mantener separación clara entre bibliotecas, descargas y permisos

Permisos recomendados:

```bash
sudo find /mnt/hd2t/jellyfin /mnt/hd2t/navidrome /mnt/hd2t/audiobookshelf /mnt/hd2t/calibre /mnt/hd2t/downloads -type d -exec chmod 2775 {} \;
sudo find /mnt/hd2t/jellyfin /mnt/hd2t/navidrome /mnt/hd2t/audiobookshelf /mnt/hd2t/calibre /mnt/hd2t/downloads -type f -exec chmod 664 {} \;
```

Si exportas `hd5t`:

```bash
sudo find /mnt/hd5t/stash -type d -exec chmod 2775 {} \;
sudo find /mnt/hd5t/stash -type f -exec chmod 664 {} \;
```

Sobre propietarios y UID/GID:

- la decisión más simple y robusta es usar en Samba el mismo UID que posee las carpetas del host
- `force user = ${SAMBA_USER}` ayuda a que las escrituras entren con un propietario consistente
- evita mezclar varios usuarios SMB escribiendo sobre la misma biblioteca si no tienes una necesidad clara y una política de permisos definida

## Backup
Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/samba/compose.yaml`
- `/home/<usuario>/homelab/compose/samba/.env`
- el inventario de shares realmente publicados

Si quieres conservar también el contenido real compartido, recuerda esta distinción:

- los datos de `hd2t` no deben "respaldarse" dentro del propio `hd2t`
- los datos de `hd5t` no deben "respaldarse" dentro del propio `hd5t`
- la copia válida de esas bibliotecas debe ir a otro destino según la estrategia de `docs/07-backups/01-estrategia-backup.md`

Copia rápida de configuración hacia el área local de backups:

```bash
mkdir -p /mnt/hd2t/backups/samba
rsync -a /home/<usuario>/homelab/compose/samba/ /mnt/hd2t/backups/samba/compose/
```

Inventario útil de shares y permisos:

```bash
{
  date
  echo
  docker compose -f /home/<usuario>/homelab/compose/samba/compose.yaml config
  echo
  ls -ld /mnt/hd2t/jellyfin/media /mnt/hd2t/navidrome/music /mnt/hd2t/audiobookshelf/audiobooks /mnt/hd2t/audiobookshelf/podcasts /mnt/hd2t/calibre/library /mnt/hd2t/downloads/transmission
} > /mnt/hd2t/backups/samba/inventario-$(date +%F).txt
```

No es necesario respaldar:

- la imagen Docker de Samba
- el contenedor recreable
- puertos o estado de red del host

## Referencias
- Samba official documentation  
  https://www.samba.org/samba/docs/
- Samba Wiki  
  https://wiki.samba.org/
- Imagen Docker `ghcr.io/servercontainers/samba`  
  https://github.com/ServerContainers/samba
- GitHub Container Registry de `servercontainers/samba`  
  https://ghcr.io/servercontainers/samba
