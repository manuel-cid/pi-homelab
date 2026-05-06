# Syncthing

## Descripción
**Syncthing** permitirá sincronizar carpetas directamente entre la Raspberry Pi y tus otros dispositivos sin depender de un proveedor cloud externo.

En este homelab se usará como un servicio de sincronización **peer-to-peer** para:

- mantener carpetas pequeñas y activas en el **SSD NVMe**
- almacenar carpetas más grandes o de crecimiento rápido en **`hd2t`**
- emparejar portátiles, sobremesas y móviles dentro de la **LAN** y también por **Tailscale**
- evitar exposición pública a internet y prescindir de reenvío de puertos en el router

Syncthing no sustituye a Nextcloud ni a un sistema de backup: aquí cubre sobre todo el caso de sincronización directa entre dispositivos para documentos, carpetas de trabajo, capturas móviles y otros ficheros donde quieras control fino sobre qué nodo conserva cada copia.

Dentro de esta fase, la separación práctica es:

- **Nextcloud** para acceso web, apps de grupo y experiencia tipo nube privada
- **Samba** para exponer carpetas del homelab por SMB a otros equipos
- **Syncthing** para replicación directa entre dispositivos concretos sin servidor central de archivos

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Tener montado y accesible:
  - `/mnt/hd2t`
- Poder usar `sudo` con el usuario administrador del homelab.
- Tener decidido qué carpetas vas a sincronizar en cada tipo de almacenamiento:
  - **SSD NVMe** para datos pequeños, frecuentes o sensibles a latencia
  - **`hd2t`** para datos grandes, históricos o de crecimiento continuo
- Puertos implicados:
  - `8384/tcp` para la interfaz web de Syncthing
  - `22000/tcp` para sincronización y conexiones entre dispositivos
  - `22000/udp` para QUIC
  - `21027/udp` para descubrimiento local en LAN
  - el contenedor usa `network_mode: host`, así que esos puertos quedan abiertos en el host solo dentro de tu red local y Tailscale

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/syncthing/
├── compose.yaml
└── .env
```

Preparación inicial de rutas:

```bash
mkdir -p /home/<usuario>/homelab/compose/syncthing
mkdir -p \
  /home/<usuario>/homelab/data/syncthing/config \
  /home/<usuario>/homelab/data/syncthing/folders/documentos \
  /home/<usuario>/homelab/data/syncthing/folders/config-sync

sudo mkdir -p \
  /mnt/hd2t/syncthing/mobile-camera \
  /mnt/hd2t/syncthing/shared-media \
  /mnt/hd2t/syncthing/receive-only

sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/syncthing /mnt/hd2t/syncthing
sudo find /home/<usuario>/homelab/data/syncthing /mnt/hd2t/syncthing -type d -exec chmod 2775 {} \;
sudo find /home/<usuario>/homelab/data/syncthing /mnt/hd2t/syncthing -type f -exec chmod 664 {} \;
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

SYNCTHING_IMAGE=lscr.io/linuxserver/syncthing:latest

PUID=1000
PGID=1000
UMASK=002

SYNCTHING_CONFIG_DIR=/home/<usuario>/homelab/data/syncthing/config
SYNCTHING_SSD_ROOT=/home/<usuario>/homelab/data/syncthing/folders
SYNCTHING_HD2T_ROOT=/mnt/hd2t/syncthing
```

Notas sobre `.env`:

- `PUID` y `PGID` deben coincidir con el usuario real que poseerá las carpetas sincronizadas. Compruébalo con `id <usuario>`.
- `UMASK=002` ayuda a que los ficheros creados mantengan permisos colaborativos razonables dentro del homelab.
- `SYNCTHING_CONFIG_DIR` debe quedarse en el **SSD NVMe** porque guarda identidad del nodo, certificados, configuración y base de datos del índice.
- `SYNCTHING_HD2T_ROOT` apunta a un árbol dedicado dentro de `hd2t` para no mezclar carpetas sincronizadas con bibliotecas de otros servicios por accidente.

Fichero `compose.yaml`:

```yaml
name: syncthing

services:
  syncthing:
    container_name: syncthing
    image: ${SYNCTHING_IMAGE}
    hostname: rpi5-syncthing
    restart: unless-stopped
    network_mode: host
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      PUID: ${PUID}
      PGID: ${PGID}
      UMASK: ${UMASK}
    volumes:
      - ${SYNCTHING_CONFIG_DIR}:/config
      - ${SYNCTHING_SSD_ROOT}:/sync-ssd
      - ${SYNCTHING_HD2T_ROOT}:/sync-hd2t
    security_opt:
      - no-new-privileges:true
```

Despliegue inicial:

```bash
cd /home/<usuario>/homelab/compose/syncthing
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f syncthing
```

Resultado esperado:

- Syncthing queda accesible por la UI en `http://<ip-lan-de-la-pi>:8384`
- el nodo genera su **Device ID** la primera vez que arranca
- la configuración persistente queda en `/home/<usuario>/homelab/data/syncthing/config/`
- las carpetas sincronizadas pueden repartirse entre el SSD y `hd2t`
- no hace falta Caddy ni publicar ningún dominio interno para este servicio

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| Tipo de acceso | LAN + Tailscale |
| Exposición pública | ninguna |
| UI web | `http://<ip-lan-de-la-pi>:8384` |
| Identidad del nodo | persistida en el SSD NVMe |
| Carpetas pequeñas y activas | SSD NVMe |
| Carpetas grandes o de crecimiento rápido | `hd2t` |
| Reverse proxy | no aplica |

### 1. Verificar identidad del nodo y primer acceso

Tras levantar el stack, abre:

- `http://<ip-lan-de-la-pi>:8384` desde un equipo en LAN
- `http://100.x.y.z:8384` o el nombre MagicDNS de la Raspberry Pi si accedes por Tailscale

Comprueba también el identificador del dispositivo desde terminal:

```bash
docker compose -f /home/<usuario>/homelab/compose/syncthing/compose.yaml logs --tail=100 syncthing
```

En la interfaz web, anota:

- el **Device ID** de la Raspberry Pi
- el nombre visible del dispositivo
- el estado de escucha en `tcp://0.0.0.0:22000` y `quic://0.0.0.0:22000`

### 2. Proteger la interfaz web y ajustar opciones base

Nada más entrar en la UI:

1. Ve a `Actions` -> `Settings` -> `GUI`.
2. Define usuario y contraseña para la interfaz.
3. Mantén el puerto `8384`.
4. Activa HTTPS de la GUI solo si quieres gestionarlo dentro de Syncthing; en un homelab LAN + Tailscale puede mantenerse en HTTP si confías en la red y restringes el acceso.

En `Settings` -> `Connections`, para este escenario son buenas opciones:

- mantener `Local Discovery` activado para detección automática en LAN
- desactivar `NAT Traversal / UPnP` porque no vas a abrir puertos en el router
- desactivar `Relaying` si quieres que el tráfico pase solo por rutas directas
- desactivar `Global Discovery` si todos tus dispositivos se conectarán por LAN o por Tailscale con direcciones explícitas

Si desactivas `Global Discovery`, añade en cada dispositivo remoto la Raspberry Pi con una dirección explícita como:

- `tcp://192.168.1.10:22000`
- `tcp://raspberrypi.tailnet.ts.net:22000`
- `quic://100.x.y.z:22000`

La ventaja es que sigues dentro del modelo de acceso local + Tailscale sin depender de servicios públicos de descubrimiento.

### 3. Emparejar dispositivos

El flujo recomendado es:

1. En la Raspberry Pi, copia el **Device ID**.
2. En el portátil, sobremesa o móvil, añade un nuevo dispositivo remoto.
3. Introduce el Device ID de la Raspberry Pi y un nombre descriptivo.
4. Si usas Tailscale fuera de casa, define también la dirección del nodo con la IP `100.x.y.z` o MagicDNS.
5. Acepta la solicitud recíproca en el otro extremo.

Nombres útiles para los pares:

- `thinkpad-casa`
- `macbook-personal`
- `pixel-9`
- `workstation-estudio`

Buenas prácticas de emparejamiento:

- no emparejes dispositivos que realmente no necesiten intercambiar datos
- evita marcar como `Introducer` un nodo si no quieres propagación automática de nuevos dispositivos
- usa `Auto Accept Folders` solo cuando tengas una política clara de qué carpetas puede proponerte otro equipo

### 4. Decidir qué carpetas van al SSD y cuáles a `hd2t`

Regla práctica:

- usa el **SSD NVMe** para carpetas pequeñas, frecuentes o de trabajo diario
- usa **`hd2t`** para cargas de móvil, carpetas compartidas grandes, repositorios pesados o datos que crecen mucho

Ejemplo de reparto razonable:

| Carpeta Syncthing | Ruta en host | Disco | Tipo recomendado |
|---|---|---|---|
| `documentos` | `/home/<usuario>/homelab/data/syncthing/folders/documentos/` | SSD NVMe | `Send & Receive` |
| `config-sync` | `/home/<usuario>/homelab/data/syncthing/folders/config-sync/` | SSD NVMe | `Send & Receive` |
| `mobile-camera` | `/mnt/hd2t/syncthing/mobile-camera/` | `hd2t` | `Receive Only` o `Send & Receive` |
| `shared-media` | `/mnt/hd2t/syncthing/shared-media/` | `hd2t` | `Send & Receive` |
| `receive-only` | `/mnt/hd2t/syncthing/receive-only/` | `hd2t` | `Receive Only` |

Recomendación importante:

- **no** uses Syncthing para sincronizar directorios vivos de bases de datos
- **no** sincronices volúmenes de Docker en uso por MariaDB, PostgreSQL, Redis o aplicaciones similares
- **no** mezcles por defecto carpetas de Jellyfin, Navidrome o Stash salvo que tengas claro el impacto sobre metadatos, permisos y escrituras concurrentes

### 5. Crear carpetas en la UI con una política simple

Para cada carpeta:

1. `Add Folder`.
2. Define un `Folder ID` corto y estable.
3. Elige la ruta exacta dentro de `/sync-ssd` o `/sync-hd2t`.
4. Selecciona los dispositivos con los que compartirá esa carpeta.
5. Escoge el tipo:
   - `Send & Receive` para trabajo bidireccional
   - `Receive Only` cuando la Raspberry Pi deba actuar como receptor o repositorio
   - `Send Only` cuando quieras que la Pi imponga el estado de referencia

Ejemplos de rutas dentro del contenedor:

- `/sync-ssd/documentos`
- `/sync-ssd/config-sync`
- `/sync-hd2t/mobile-camera`
- `/sync-hd2t/shared-media`

### 6. Opciones recomendadas por carpeta

Para un homelab doméstico conviene empezar con ajustes conservadores:

- activar `Filesystem Watcher` cuando la carpeta tenga cambios frecuentes
- usar `Staggered File Versioning` o `Trash Can File Versioning` en carpetas importantes
- mantener `Ignore Permissions` activado si vas a sincronizar entre sistemas distintos y no te interesa preservar bits POSIX exactos
- revisar `.stignore` en carpetas donde no quieras mover basura de sistema o temporales

Ejemplo de `.stignore` útil en una carpeta compartida entre Windows, macOS y Linux:

```text
.DS_Store
Thumbs.db
desktop.ini
@eaDir
*.tmp
```

### 7. Comprobaciones rápidas

Desde la Raspberry Pi:

```bash
docker compose -f /home/<usuario>/homelab/compose/syncthing/compose.yaml logs --tail=100 syncthing
ss -tulpn | rg ':(8384|22000|21027)\\b'
```

Validaciones útiles:

- la UI carga correctamente en LAN y por Tailscale
- cada dispositivo aparece como `Connected`
- las carpetas terminan en estado `Up to Date`
- no hay errores de permisos en el log

Si algo falla, revisa en este orden:

1. permisos reales sobre la carpeta del host
2. que `PUID` y `PGID` coincidan con el propietario
3. rutas del contenedor elegidas en la carpeta Syncthing
4. firewall local en cliente o servidor
5. dirección explícita correcta si has desactivado `Global Discovery`

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose de Syncthing | `/home/<usuario>/homelab/compose/syncthing/` | SSD NVMe |
| Variables del stack | `/home/<usuario>/homelab/compose/syncthing/.env` | SSD NVMe |
| Configuración, identidad y base de datos del índice | `/home/<usuario>/homelab/data/syncthing/config/` | SSD NVMe |
| Carpetas rápidas o pequeñas | `/home/<usuario>/homelab/data/syncthing/folders/` | SSD NVMe |
| Carpetas grandes o de recepción continua | `/mnt/hd2t/syncthing/` | `hd2t` |

Notas de almacenamiento:

- el **SSD NVMe** debe alojar siempre la configuración del nodo
- `hd2t` es mejor destino para carpetas de móvil, históricos o datos que puedan crecer mucho
- `hd5t` no participa por defecto en Syncthing y conviene reservarlo para Stash
- no conviertas Syncthing en una capa de replicación para todos los datos del homelab indiscriminadamente

Permisos recomendados:

```bash
sudo find /home/<usuario>/homelab/data/syncthing /mnt/hd2t/syncthing -type d -exec chmod 2775 {} \;
sudo find /home/<usuario>/homelab/data/syncthing /mnt/hd2t/syncthing -type f -exec chmod 664 {} \;
```

Sobre propietarios y UID/GID:

- la opción más robusta es que las carpetas sincronizadas pertenezcan al mismo usuario Linux que corre el stack
- si sincronizas entre sistemas con modelos de permisos distintos, prioriza consistencia funcional sobre fidelidad exacta de metadatos
- cuando haya conflicto entre permisos del host y Syncthing, el problema suele estar en el host antes que en el contenedor

## Backup
Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/syncthing/compose.yaml`
- `/home/<usuario>/homelab/compose/syncthing/.env`
- `/home/<usuario>/homelab/data/syncthing/config/`
- las carpetas sincronizadas que actúen como copia principal o repositorio en la Raspberry Pi

El directorio más importante es `config/` porque contiene:

- la identidad criptográfica del nodo
- la definición de dispositivos emparejados
- la configuración de carpetas
- la base de datos local del índice

Estrategia práctica de copia:

```bash
mkdir -p /mnt/hd2t/backups/syncthing
rsync -a /home/<usuario>/homelab/compose/syncthing/ /mnt/hd2t/backups/syncthing/compose/
rsync -a /home/<usuario>/homelab/data/syncthing/config/ /mnt/hd2t/backups/syncthing/config/
rsync -a /home/<usuario>/homelab/data/syncthing/folders/ /mnt/hd2t/backups/syncthing/folders-ssd/
```

Si además quieres una copia local de las carpetas grandes en `hd2t`, hazla hacia otro destino real distinto de ese mismo disco según la estrategia general de backups del homelab.

No es necesario respaldar:

- la imagen Docker
- el contenedor recreable
- el estado transitorio de conexión de Syncthing

Recuerda:

- **sincronización no es backup**
- una carpeta `Send & Receive` con borrado propagado puede destruir datos en todos los nodos
- si una carpeta es importante, combina Syncthing con versionado y con copia externa independiente

## Referencias
- Documentación oficial de Syncthing  
  https://docs.syncthing.net/
- Conceptos de sincronización y tipos de carpeta  
  https://docs.syncthing.net/users/foldertypes.html
- Configuración de dispositivos y direcciones  
  https://docs.syncthing.net/users/config.html
- Imagen Docker `lscr.io/linuxserver/syncthing`  
  https://docs.linuxserver.io/images/docker-syncthing/
- Registro de imagen `lscr.io/linuxserver/syncthing`  
  https://github.com/linuxserver/docker-syncthing
