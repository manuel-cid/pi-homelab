# Transmission

## Descripción
**Transmission** será el cliente BitTorrent del homelab para descargar contenido hacia `hd2t` y servir como backend de **Sonarr** y **Radarr** en la fase de automatización de descargas.

En esta arquitectura se despliega sobre la **Raspberry Pi 5** con estas reglas:

- la configuración persistente del servicio vive en el **SSD NVMe**
- las descargas completas, incompletas y la carpeta de entrada viven en **`/mnt/hd2t`**
- la interfaz web local se publica detrás de **Caddy** con `https://transmission.lan`
- el acceso remoto sigue siendo **solo Tailscale**, sin abrir puertos en el router
- el puerto de peers se publica en la Raspberry Pi, pero sin redirección WAN en el router

Transmission encaja bien en este homelab porque es ligero, estable en ARM64 y suficiente para un nodo de descargas doméstico donde la prioridad es automatizar flujos locales sin exponer servicios públicamente.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md` para publicar `transmission.lan`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres acceso remoto por VPN mesh.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `transmission.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Tener montado `hd2t` en `/mnt/hd2t`.
- Poder usar `sudo` con el usuario administrador del homelab.
- Puertos implicados en esta fase:
  - `9091/tcp` solo dentro de Docker entre Caddy, Transmission y futuros clientes como Sonarr/Radarr
  - `51413/tcp` publicado en el host para tráfico BitTorrent
  - `51413/udp` publicado en el host para DHT y tráfico BitTorrent UDP
  - `80/tcp` y `443/tcp` ya publicados por Caddy en el host
  - no se abre ningún puerto entrante en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/transmission/
├── compose.yaml
└── .env
```

Preparación inicial de rutas:

```bash
mkdir -p /home/<usuario>/homelab/compose/transmission
mkdir -p /home/<usuario>/homelab/data/transmission/config
mkdir -p /mnt/hd2t/downloads/transmission/{complete,incomplete,watch}
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

TRANSMISSION_IMAGE=lscr.io/linuxserver/transmission:latest

PUID=1000
PGID=1000
UMASK=002

TRANSMISSION_CONFIG_DIR=/home/<usuario>/homelab/data/transmission/config
TRANSMISSION_DOWNLOADS_DIR=/mnt/hd2t/downloads/transmission
TRANSMISSION_WATCH_DIR=/mnt/hd2t/downloads/transmission/watch

TRANSMISSION_WEB_UI_USER=transmissionadmin
TRANSMISSION_WEB_UI_PASS=<cambia-esta-password>

TRANSMISSION_RPC_WHITELIST=
TRANSMISSION_HOST_WHITELIST=transmission.lan
TRANSMISSION_PEER_PORT=51413
```

Notas sobre estas variables:

- `PUID` y `PGID` deben corresponder al usuario real que administra el homelab y tiene acceso de escritura sobre `hd2t`.
- `TRANSMISSION_RPC_WHITELIST` vacío desactiva la whitelist por IP. En este diseño es razonable porque el acceso real queda limitado por LAN/Tailscale, autenticación y reverse proxy.
- `TRANSMISSION_HOST_WHITELIST` debe incluir cualquier hostname desde el que vayas a acceder a la UI. Si más adelante publicas el servicio también bajo un nombre Tailscale, añádelo aquí.
- `UMASK=002` facilita que futuras herramientas como Sonarr o Radarr puedan mover y renombrar archivos sin pelearse con permisos demasiado restrictivos.
- `latest` sigue la última release publicada por la imagen. Si quieres máxima reproducibilidad, fija una etiqueta concreta.

Fichero `compose.yaml`:

```yaml
name: transmission

services:
  transmission:
    container_name: transmission
    image: ${TRANSMISSION_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}
      UMASK: ${UMASK}
      USER: ${TRANSMISSION_WEB_UI_USER}
      PASS: ${TRANSMISSION_WEB_UI_PASS}
      WHITELIST: ${TRANSMISSION_RPC_WHITELIST}
      HOST_WHITELIST: ${TRANSMISSION_HOST_WHITELIST}
      PEERPORT: ${TRANSMISSION_PEER_PORT}
    volumes:
      - ${TRANSMISSION_CONFIG_DIR}:/config
      - type: bind
        source: ${TRANSMISSION_DOWNLOADS_DIR}
        target: /downloads
      - type: bind
        source: ${TRANSMISSION_WATCH_DIR}
        target: /watch
    ports:
      - "${TRANSMISSION_PEER_PORT}:${TRANSMISSION_PEER_PORT}"
      - "${TRANSMISSION_PEER_PORT}:${TRANSMISSION_PEER_PORT}/udp"
    networks:
      - default
      - homelab_proxy
    security_opt:
      - no-new-privileges:true

networks:
  homelab_proxy:
    external: true
    name: homelab_proxy
```

Notas operativas sobre este stack:

- no se publica `9091` en el host porque el punto de entrada recomendado es **Caddy**
- el puerto de peers sí se publica en el host para que Transmission pueda participar correctamente en la red BitTorrent dentro de las limitaciones de una red sin puertos abiertos en el router
- la configuración persistente queda en el NVMe y las descargas pesadas en `hd2t`
- la carpeta `/watch` queda disponible aunque puedes mantenerla desactivada hasta que realmente la necesites

Despliegue inicial:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/transmission
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/transmission
sudo chown -R <usuario>:<usuario> /mnt/hd2t/downloads/transmission

cd /home/<usuario>/homelab/compose/transmission
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f transmission
```

Resultado esperado:

- el contenedor `transmission` queda levantado
- Transmission escucha internamente en `http://transmission:9091`
- la UI queda disponible por defecto en `http://transmission:9091/transmission/web/`
- se crea el fichero persistente `settings.json` dentro de `/home/<usuario>/homelab/data/transmission/config/`
- la estructura de descargas de `hd2t` queda visible en el contenedor bajo `/downloads`
- Caddy puede publicar la UI como `https://transmission.lan`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `https://transmission.lan/transmission/web/` |
| Persistencia | `/home/<usuario>/homelab/data/transmission/config/` |
| Descargas completas | `/mnt/hd2t/downloads/transmission/complete/` |
| Descargas incompletas | `/mnt/hd2t/downloads/transmission/incomplete/` |
| Carpeta watch | `/mnt/hd2t/downloads/transmission/watch/` |
| Punto de entrada LAN | Caddy |
| Acceso remoto | Tailscale |
| Puerto de peers | `51413/tcp` y `51413/udp` |
| Rol futuro | backend de Sonarr y Radarr |

### 1. Preparar rutas y permisos

Crear la estructura base:

```bash
mkdir -p /home/<usuario>/homelab/compose/transmission
mkdir -p /home/<usuario>/homelab/data/transmission/config
mkdir -p /mnt/hd2t/downloads/transmission/{complete,incomplete,watch}
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/transmission
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/transmission
sudo chown -R <usuario>:<usuario> /mnt/hd2t/downloads/transmission

chmod 755 /home/<usuario>/homelab/data/transmission
chmod 750 /home/<usuario>/homelab/data/transmission/config
chmod -R 775 /mnt/hd2t/downloads/transmission
```

Si `hd2t` viene de otro sistema o se monta con un propietario distinto, corrige antes permisos y ACL. El problema más habitual en este tipo de stack no suele ser Docker, sino que Transmission descargue bien pero Sonarr o Radarr no puedan mover archivos después por UID, GID o máscara de permisos.

### 2. Arrancar el servicio y completar el primer acceso

Levantar el stack:

```bash
cd /home/<usuario>/homelab/compose/transmission
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f transmission
docker exec transmission id
docker exec transmission ls -lah /downloads
docker exec transmission ls -lah /config
```

Después, abrir:

```text
https://transmission.lan/transmission/web/
```

En el primer arranque:

1. Inicia sesión con el usuario y contraseña definidos en `.env`.
2. Comprueba que la UI carga correctamente detrás de Caddy.
3. Verifica que las carpetas `complete` e `incomplete` existen y son escribibles.
4. Descarga un torrent de prueba pequeño y legal para validar el flujo completo.
5. Comprueba en `settings.json` que el puerto fijo y las rutas persistentes han quedado guardados.

Si necesitas editar `settings.json` manualmente, para antes el contenedor:

```bash
cd /home/<usuario>/homelab/compose/transmission
docker compose stop transmission
```

Después de editarlo, vuelve a arrancar:

```bash
docker compose up -d
```

### 3. Ajustar rutas de descarga

En la UI de Transmission, revisa y deja estos valores:

| Ajuste | Valor recomendado |
|---|---|
| Download to | `/downloads/complete` |
| Keep incomplete files in | `/downloads/incomplete` |
| Incomplete directory | activado |
| Automatically add `.torrent` files from | `/watch` |
| Watch directory | desactivado al principio, opcional más adelante |

Estructura recomendada en el host:

```text
/mnt/hd2t/downloads/transmission/
├── complete/
├── incomplete/
└── watch/
```

Buenas prácticas para esta carpeta:

- no mezcles aquí bibliotecas finales de Jellyfin, Navidrome o Audiobookshelf
- deja `complete/` como zona de aterrizaje temporal para que Sonarr y Radarr importen después
- mantén `incomplete/` separada para evitar que otros servicios indexen archivos a medio descargar
- activa `watch/` solo si realmente vas a depositar torrents manualmente por SMB, Syncthing u otro mecanismo

### 4. Configuración recomendada de velocidad

Transmission permite fijar límites globales y un modo de velocidad alternativa. Como regla práctica:

- limita la **subida** al `70-80 %` de tu velocidad real de upstream si notas que la línea se degrada
- deja la **bajada** sin límite salvo que quieras reservar ancho de banda para otros servicios
- usa la velocidad alternativa para franjas horarias en las que no quieras saturar la conexión

Ajustes iniciales razonables en la UI:

| Sección | Ajuste | Valor de partida |
|---|---|---|
| Speed | Upload | activado si compartes la línea con otros usos |
| Speed | Upload limit | el `70-80 %` de tu subida real |
| Speed | Download | opcional |
| Speed | Download limit | el `85-90 %` de tu bajada real si necesitas limitar |
| Speed | Alternative speed limits | activado solo si quieres horarios suaves |
| Queue | Maximum active downloads | `3` |
| Queue | Maximum active uploads | `5` |
| Seeding | Stop seeding at ratio | `1.5` como punto de partida |

Ejemplo práctico:

- si tu subida real ronda `10 MiB/s`, empieza con un límite de `7-8 MiB/s`
- si tu bajada real ronda `30 MiB/s` y quieres reservar margen, prueba con `25-27 MiB/s`

En Transmission los límites suelen mostrarse en **kB/s**, así que conviene convertir antes de introducir valores exactos.

### 5. Configuración recomendada de peers y red

Para este homelab interesa una configuración estable, predecible y fácil de integrar con automatizaciones posteriores.

Revisa en la UI:

| Ajuste | Valor recomendado |
|---|---|
| Peer listening port | `51413` |
| Pick a random port on startup | desactivado |
| Port forwarding from my router | desactivado |
| Enable DHT | activado |
| Enable PEX | activado |
| Enable LPD | desactivado por defecto |
| Encryption mode | `Preferred` |
| Global peer limit | `200` |
| Peer limit per torrent | `50` |

Qué significan estas decisiones en este proyecto:

- fijar un puerto estático simplifica troubleshooting, reglas locales y futuras integraciones
- desactivar el cambio aleatorio de puerto evita inconsistencias entre reinicios
- desactivar el port forwarding es coherente con una red donde no se van a abrir puertos en el router
- mantener **DHT** y **PEX** activos mejora el descubrimiento de peers en torrents públicos
- dejar **LPD** apagado reduce ruido en LAN si no necesitas descubrir peers locales automáticamente

Limitación importante de esta arquitectura:

- al no abrir puertos en el router, Transmission podrá iniciar conexiones salientes pero normalmente no aceptará conexiones entrantes desde internet
- esto no impide descargar, pero puede reducir el número de peers útiles y empeorar ratios o velocidad en algunos torrents

### 6. Integración con Caddy

La integración esperada con `docs/03-red/04-caddy.md` es el bloque:

```caddyfile
transmission.lan {
  import common
  tls internal
  reverse_proxy transmission:9091
}
```

Después de levantar ambos stacks:

```bash
docker network inspect homelab_proxy
docker compose -f /home/<usuario>/homelab/compose/caddy/compose.yaml ps
docker compose -f /home/<usuario>/homelab/compose/transmission/compose.yaml ps
```

Validaciones:

- `transmission` y `caddy` deben estar en `homelab_proxy`
- `https://transmission.lan/transmission/web/` debe responder con la pantalla de login
- el certificado será el de la CA interna de Caddy para la LAN
- si ves errores de host no autorizado, revisa `TRANSMISSION_HOST_WHITELIST`

### 7. Preparar la integración futura con Sonarr y Radarr

Aunque esa integración se documentará en los siguientes documentos de esta fase, deja preparado este criterio desde ahora:

- Sonarr y Radarr deberán usar como ruta de descargas completadas `complete/`
- la importación final moverá los archivos desde `hd2t` hacia las carpetas multimedia definitivas
- evita renombrados manuales dentro de `complete/` para no romper el seguimiento automático

Endpoint interno recomendado para futuras integraciones:

```text
http://transmission:9091
```

Este endpoint funciona bien si los contenedores comparten una red Docker común como `homelab_proxy`. Transmission sigue usando por defecto su ruta web y RPC bajo `/transmission/`, pero para Sonarr y Radarr conviene documentar el host y puerto base tal como se usarán en sus formularios de integración.

## Almacenamiento

Distribución de datos recomendada:

| Tipo de dato | Ruta |
|---|---|
| Compose del servicio | `/home/<usuario>/homelab/compose/transmission/` |
| Configuración persistente | `/home/<usuario>/homelab/data/transmission/config/` |
| Descargas completas | `/mnt/hd2t/downloads/transmission/complete/` |
| Descargas incompletas | `/mnt/hd2t/downloads/transmission/incomplete/` |
| Watch directory | `/mnt/hd2t/downloads/transmission/watch/` |

Criterios de esta distribución:

- el **NVMe** absorbe la configuración sensible y las escrituras pequeñas del servicio
- `hd2t` absorbe las escrituras pesadas y los ficheros grandes de descarga
- separar `complete/` e `incomplete/` simplifica automatización e indexación
- la carpeta `watch/` queda fuera de la configuración del contenedor y puede gestionarse como una simple entrada de archivos

Qué guarda Transmission en `/config` habitualmente:

- `settings.json`
- ficheros `.resume`
- estado de sesiones y torrents
- metadatos persistentes de la aplicación

Qué guarda en `hd2t`:

- datos descargados
- ficheros temporales incompletos
- posibles torrents añadidos manualmente en `watch/`

## Backup

Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/transmission/`
- `/home/<usuario>/homelab/data/transmission/config/`

Respaldar de forma opcional según tu estrategia:

- `/mnt/hd2t/downloads/transmission/watch/` si allí dejas torrents o `.magnet` de trabajo
- `/mnt/hd2t/downloads/transmission/complete/` si esa carpeta contiene material todavía no importado a su destino final

Recomendación práctica:

- trata `config/` como **obligatorio**
- trata `complete/` e `incomplete/` como datos operativos, no como almacenamiento definitivo
- antes de un backup coherente de `config/`, para brevemente el contenedor para evitar copiar estado en mitad de escritura

Parada breve antes del backup:

```bash
cd /home/<usuario>/homelab/compose/transmission
docker compose stop transmission
```

Después del backup:

```bash
docker compose up -d
```

## Referencias
- Documentación oficial de Transmission: `https://transmissionbt.com/`
- Repositorio oficial de Transmission: `https://github.com/transmission/transmission`
- Imagen LinuxServer para Transmission: `https://docs.linuxserver.io/images/docker-transmission/`
- Imagen Docker: `https://hub.docker.com/r/linuxserver/transmission`
