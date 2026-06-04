# Syncthing

## Descripción

**Syncthing** permite sincronizar carpetas entre dispositivos de forma **peer-to-peer** sin depender de un proveedor externo. En este homelab se usa para intercambiar y mantener sincronizados conjuntos de archivos personales entre la Raspberry Pi, portátiles, móviles u otros equipos de la red, tanto por **LAN** como por **Tailscale**.

La política de almacenamiento sigue siendo la misma que en el resto del proyecto:

- el **SSD NVMe** se reserva para carpetas pequeñas o de trabajo frecuente
- **`hd2t`** se usa para sincronizar contenidos más pesados o zonas de intercambio de ficheros grandes
- **`hd5t`** no se usa por defecto con Syncthing; está reservado para la biblioteca de **Stash**

Syncthing **no sustituye a un backup** y tampoco es buena idea apuntarlo a bases de datos activas o directorios internos de aplicaciones Docker. Su papel aquí es sincronizar carpetas de usuario bien delimitadas.

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Tener Docker Engine y Docker Compose operativos según [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber fijado la convención de stacks y `.env` descrita en [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Tener montado `hd2t` en `/media/hd2t`.
- Poder administrar el firewall del host según [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md).
- Tener identificados los dispositivos que se van a parear con la Raspberry Pi.
- Puertos necesarios para Syncthing:
  - **12000/tcp** para la interfaz web del homelab
  - **22000/tcp** para sincronización
  - **22000/udp** para QUIC/sincronización
  - **21027/udp** para descubrimiento local

## Objetivo de esta Fase

Al terminar este documento, el estado esperado es este:

- Syncthing queda desplegado como stack propio `files-syncthing`.
- La configuración del servicio queda persistida en el **SSD NVMe**.
- Existen carpetas de sincronización separadas entre datos ligeros en SSD y datos grandes en `hd2t`.
- La Raspberry Pi queda pareada con los dispositivos que necesites.
- La interfaz web queda restringida al ámbito **LAN + Tailscale** según las reglas del firewall del host.

## Docker Compose

Archivo: `/home/<user>/homelab/compose/files-syncthing/docker-compose.yml`

```yaml
name: files-syncthing

services:
  syncthing:
    image: lscr.io/linuxserver/syncthing:latest
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      PUID: ${PUID}
      PGID: ${PGID}
    ports:
      - "${SYNCTHING_BIND_IP}:${SYNCTHING_GUI_PORT}:8384/tcp"
      - "${SYNCTHING_BIND_IP}:${SYNCTHING_SYNC_PORT}:22000/tcp"
      - "${SYNCTHING_BIND_IP}:${SYNCTHING_SYNC_PORT}:22000/udp"
      - "${SYNCTHING_BIND_IP}:${SYNCTHING_DISCOVERY_PORT}:21027/udp"
    volumes:
      - ${DATA_ROOT}/syncthing/config:/config
      - ${SSD_SYNC_ROOT}/documents:/data/documents
      - ${SSD_SYNC_ROOT}/notes:/data/notes
      - /media/hd2t/syncthing/media-drop:/data/media-drop
    labels:
      - com.centurylinklabs.watchtower.enable=true
```

Este Compose sigue la política general del proyecto:

- stack independiente para el servicio de sincronización
- configuración persistente en el **SSD NVMe**
- carpetas de datos montadas directamente desde el host
- separación explícita entre carpetas en SSD y carpetas en `hd2t`
- publicación solo de los puertos necesarios del protocolo y de la UI

Si no quieres crear alguna de las carpetas de ejemplo, elimina su volumen del Compose y luego define en la UI solo las rutas que realmente vayas a usar.

## Configuración

### 1. Preparar directorios del stack y carpetas a sincronizar

```bash
mkdir -p /home/<user>/homelab/compose/files-syncthing
mkdir -p /home/<user>/homelab/data/syncthing/config
mkdir -p /home/<user>/homelab/sync/{documents,notes}
sudo mkdir -p /media/hd2t/syncthing/media-drop
```

### 2. Alinear propiedad y permisos del host

Usa el mismo usuario operativo del host que ya gestiona Docker y el resto del homelab:

```bash
id <user>
sudo chown -R <user>:<user> /home/<user>/homelab/data/syncthing
sudo chown -R <user>:<user> /home/<user>/homelab/sync
sudo chown -R <user>:<user> /media/hd2t/syncthing

sudo find /home/<user>/homelab/sync -type d -exec chmod 2775 {} \;
sudo find /media/hd2t/syncthing -type d -exec chmod 2775 {} \;
```

Qué se busca con esto:

- que Syncthing escriba con el mismo `UID` y `GID` que el usuario real del host
- evitar archivos con propietarios incoherentes respecto a otros servicios
- mantener permisos razonables en directorios compartidos

### 3. Crear el fichero `.env`

Archivo: `/home/<user>/homelab/compose/files-syncthing/.env`

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000
DATA_ROOT=/home/<user>/homelab/data
SSD_SYNC_ROOT=/home/<user>/homelab/sync
SYNCTHING_BIND_IP=0.0.0.0
SYNCTHING_GUI_PORT=12000
SYNCTHING_SYNC_PORT=22000
SYNCTHING_DISCOVERY_PORT=21027
```

Notas importantes:

- `DATA_ROOT` mantiene la configuración del servicio en el **SSD NVMe**.
- `SSD_SYNC_ROOT` define la raíz de carpetas sincronizadas que quieres mantener también en SSD.
- `SYNCTHING_BIND_IP=0.0.0.0` permite acceso desde la **LAN** y desde la IP de **Tailscale** del host si el firewall lo autoriza.
- Si prefieres que la interfaz web no sea accesible desde la LAN, puedes cambiar `SYNCTHING_BIND_IP` a una IP concreta del host o a `127.0.0.1` y gestionar el acceso por otro camino.

Protege el fichero:

```bash
chmod 600 /home/<user>/homelab/compose/files-syncthing/.env
```

### 4. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/files-syncthing
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=50 syncthing
```

Validaciones útiles en el host:

```bash
ss -ltnp | grep -E ':12000|:22000'
ss -lunp | grep -E ':21027|:22000'
```

El resultado esperado es que el contenedor quede en estado `Up` y que el host escuche en los puertos de la interfaz y del protocolo de sincronización.

### 5. Acceso inicial y endurecimiento mínimo de la UI

Abre la interfaz desde un navegador en una de estas rutas:

- `http://<ip-lan-de-la-raspberry>:12000`
- `http://<ip-tailscale-de-la-raspberry>:12000`

En el primer acceso:

- entra en `Actions` → `Settings` → `GUI`
- define un **usuario y contraseña** para la interfaz web
- revisa el nombre del dispositivo de la Raspberry Pi para identificarlo fácilmente
- confirma que la zona horaria y la hora mostradas son correctas

Syncthing no necesita exponer la UI a internet para funcionar; en este proyecto la UI solo debe quedar accesible por **LAN + Tailscale**.

### 6. Parear dispositivos

Para vincular un portátil, móvil u otro servidor:

1. Obtén el **Device ID** de la Raspberry Pi desde `Actions` → `Show ID`.
2. Añade ese identificador en el dispositivo remoto.
3. Acepta la solicitud entrante en la interfaz web de la Raspberry Pi.
4. Asigna un nombre claro al dispositivo remoto.
5. Comparte solo las carpetas que correspondan a ese dispositivo.

Criterio recomendado para el pareado:

- usa **`Send & Receive`** para carpetas normales de trabajo compartido
- usa **`Receive Only`** si la Raspberry Pi debe actuar como receptor principal de una copia sincronizada
- usa **`Send Only`** solo cuando la Raspberry Pi sea la fuente autoritativa de una carpeta concreta
- evita marcar la Raspberry Pi como `Introducer` salvo que quieras usarla como nodo central que propaga relaciones entre dispositivos

### 7. Crear y asignar carpetas

Carpetas de ejemplo del Compose:

- `/data/documents` para documentos pequeños o trabajo diario en el **SSD NVMe**
- `/data/notes` para notas, vaults de texto o ficheros ligeros en el **SSD NVMe**
- `/data/media-drop` para intercambio de ficheros grandes en `hd2t`

Recomendación de uso:

- guarda en **SSD** solo datos pequeños, muy activos o sensibles a la latencia
- usa **`hd2t`** para lotes grandes, importaciones multimedia o intercambio temporal
- no sincronices directorios internos de aplicaciones como `/home/<user>/homelab/data/<servicio>/`
- no sincronices bases de datos vivas ni librerías que estén siendo escritas simultáneamente por otros contenedores

Pasos en la UI para cada carpeta:

1. Pulsa `Add Folder`.
2. Define un `Folder Label` legible.
3. Usa como `Folder Path` una de las rutas ya montadas en el contenedor, por ejemplo `/data/documents`.
4. Elige el tipo de carpeta adecuado.
5. Marca solo los dispositivos que deben recibir esa carpeta.
6. Guarda y acepta la carpeta en el resto de dispositivos cuando lo soliciten.

Si vas a recibir fotos o vídeos desde móviles, suele ser mejor enviarlos primero a `/data/media-drop` y después moverlos manualmente a la biblioteca definitiva que corresponda.

### 8. Ajustar el firewall del host

Si usas `ufw`, permite los puertos solo para tu red local:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 12000 proto tcp comment 'Syncthing UI LAN'
sudo ufw allow from 192.168.1.0/24 to any port 22000 proto tcp comment 'Syncthing sync TCP LAN'
sudo ufw allow from 192.168.1.0/24 to any port 22000 proto udp comment 'Syncthing sync UDP LAN'
sudo ufw allow from 192.168.1.0/24 to any port 21027 proto udp comment 'Syncthing discovery LAN'
sudo ufw status verbose
```

Si también quieres usar Syncthing por **Tailscale**, añade además:

```bash
sudo ufw allow in on tailscale0 to any port 12000 proto tcp comment 'Syncthing UI Tailscale'
sudo ufw allow in on tailscale0 to any port 22000 proto tcp comment 'Syncthing sync TCP Tailscale'
sudo ufw allow in on tailscale0 to any port 22000 proto udp comment 'Syncthing sync UDP Tailscale'
```

El descubrimiento local `21027/udp` no suele hacer falta en `tailscale0` porque fuera de la LAN normalmente trabajarás con dispositivos ya emparejados.

### 9. Prueba funcional

Comprobaciones mínimas después del pareado:

- la Raspberry Pi aparece como dispositivo `Connected`
- las carpetas compartidas muestran estado `Up to Date` o progreso real de sincronización
- crear un archivo de prueba en un extremo acaba replicándose en el otro
- borrar o renombrar un archivo de prueba replica el cambio según el tipo de carpeta configurado

Si un dispositivo no conecta:

- revisa primero el firewall local de ambos extremos
- verifica que `22000/tcp` y `22000/udp` están accesibles
- comprueba que el reloj del sistema es correcto
- revisa los logs con `docker compose logs --tail=100 syncthing`

## Almacenamiento

Rutas implicadas en este despliegue:

- `docker-compose.yml`: `/home/<user>/homelab/compose/files-syncthing/docker-compose.yml`
- `.env`: `/home/<user>/homelab/compose/files-syncthing/.env`
- configuración persistente: `/home/<user>/homelab/data/syncthing/config`
- carpetas sincronizadas en SSD: `/home/<user>/homelab/sync/`
- carpeta sincronizada en `hd2t`: `/media/hd2t/syncthing/media-drop`

Reglas operativas recomendadas:

- usa el **SSD NVMe** para documentos, notas y conjuntos pequeños muy activos
- usa **`hd2t`** para ficheros voluminosos o como zona de entrada multimedia
- evita usar **`hd5t`** con Syncthing por defecto para no mezclar esta sincronización con la biblioteca de **Stash**
- no conviertas Syncthing en acceso indirecto a los datos internos de otros contenedores

## Backup

Syncthing no reemplaza una estrategia de copias de seguridad. Lo que debes respaldar es esto:

- `/home/<user>/homelab/compose/files-syncthing/docker-compose.yml`
- `/home/<user>/homelab/compose/files-syncthing/.env`
- `/home/<user>/homelab/data/syncthing/config/`
- las carpetas cuyo contenido sea autoritativo en la Raspberry Pi:
  - `/home/<user>/homelab/sync/`
  - `/media/hd2t/syncthing/`

Motivos:

- el directorio `config` conserva identidad del nodo, dispositivos conocidos y definición de carpetas
- los dispositivos pareados no garantizan histórico, protección frente a borrados o recuperación limpia
- un error o borrado sincronizado también se propaga si no existe backup independiente

## Referencias

- Syncthing: https://syncthing.net/
- Documentación oficial: https://docs.syncthing.net/
- LinuxServer Syncthing: https://docs.linuxserver.io/images/docker-syncthing/
- Imagen Docker: https://github.com/linuxserver/docker-syncthing
- Docker Compose file reference: https://docs.docker.com/compose/compose-file/
