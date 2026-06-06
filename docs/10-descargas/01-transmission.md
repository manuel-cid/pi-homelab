# Transmission

## Descripción

**Transmission** es el cliente BitTorrent ligero del homelab. En esta arquitectura se despliega como stack Docker propio, con los **datos operativos en el SSD NVMe** y los **payloads de descarga en `hd2t`**.

La política de este proyecto se mantiene igual que en el resto de servicios:

- la configuración, el estado del cliente, la sesión y el fichero `settings.json` viven en `/home/<user>/homelab/data/transmission/config/` sobre el **SSD NVMe**
- las descargas incompletas, completas y la carpeta de vigilancia viven en `/media/hd2t/downloads/transmission/`
- el acceso principal se hace desde la **LAN**
- el acceso remoto se hace por **Tailscale**, sin abrir puertos en el router
- el stack se une a la red Docker compartida para facilitar la integración posterior con **Sonarr**, **Radarr** y **Prowlarr**

En este homelab hay una decisión de diseño importante: **no** se abren puertos en el router y **no** se expone Transmission a internet. Eso significa que el cliente seguirá funcionando, pero no debe esperarse el mismo nivel de conectividad entrante que en un despliegue con port forwarding. En la práctica, Transmission seguirá descargando mediante conexiones salientes, DHT y PEX, pero el estado del puerto de peers puede no aparecer como abierto desde internet, y eso es coherente con el alcance del proyecto.

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Tener Docker Engine y Docker Compose operativos según [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber fijado la convención de stacks y `.env` descrita en [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber desplegado [04-tailscale.md](../03-red/04-tailscale.md) si quieres acceder a la interfaz fuera de la LAN.
- Revisar [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) para registrar los puertos publicados por el servicio.
- Tener montado `hd2t` en `/media/hd2t`.
- Tener creada la red Docker externa `homelab_proxy` si vas a seguir el patrón de integración entre stacks.
- Puertos necesarios:
  - `15000/tcp` en el host para la interfaz web y RPC de Transmission
  - `51413/tcp` para tráfico BitTorrent entre peers
  - `51413/udp` para tráfico BitTorrent entre peers

## Docker Compose

Archivo: `/home/<user>/homelab/compose/downloads-transmission/docker-compose.yml`

```yaml
name: downloads-transmission

services:
  transmission:
    image: lscr.io/linuxserver/transmission:latest
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      PUID: ${PUID}
      PGID: ${PGID}
      USER: ${TRANSMISSION_RPC_USER}
      PASS: ${TRANSMISSION_RPC_PASS}
      WHITELIST: ${TRANSMISSION_RPC_WHITELIST}
      HOST_WHITELIST: ${TRANSMISSION_HOST_WHITELIST}
      PEERPORT: ${TRANSMISSION_PEER_PORT}
    ports:
      - "${TRANSMISSION_BIND_IP}:${TRANSMISSION_WEB_PORT}:9091"
      - "${TRANSMISSION_PEER_PORT}:${TRANSMISSION_PEER_PORT}"
      - "${TRANSMISSION_PEER_PORT}:${TRANSMISSION_PEER_PORT}/udp"
    volumes:
      - /home/<user>/homelab/data/transmission/config:/config
      - /media/hd2t/downloads/transmission:/downloads
      - /media/hd2t/downloads/transmission/watch:/watch
    networks:
      - default
      - proxy
    labels:
      - wud.watch=true

networks:
  proxy:
    external: true
    name: ${PROXY_NETWORK}
```

Notas sobre este Compose:

- el stack queda aislado bajo `downloads-transmission`
- la configuración persistente vive en el **SSD NVMe**
- el contenido pesado de descarga vive en `hd2t`
- `PUID` y `PGID` se pasan también como variables de entorno porque la imagen de LinuxServer usa ese patrón para ajustar permisos internos
- no se fuerza `user:` en el servicio porque esta imagen ya gestiona permisos mediante `PUID` y `PGID`
- el puerto de peers se fija en `51413` para evitar cambios aleatorios tras reinicios
- la carpeta `/downloads` agrupa `complete/`, `incomplete/` y otras subcarpetas sin mezclar descargas con las bibliotecas finales
- el servicio se conecta también a `homelab_proxy` para que futuros stacks como Sonarr o Radarr puedan alcanzar `transmission:9091` por nombre interno Docker
- `WHITELIST` y `HOST_WHITELIST` se dejan vacíos en el despliegue base para no bloquear accesos legítimos desde LAN, Tailscale o entre contenedores; si tu topología queda fija y quieres endurecer esto, puedes restringirlos más adelante

## Configuración

### 1. Preparar directorios del stack y de descargas

```bash
mkdir -p /home/<user>/homelab/compose/downloads-transmission
mkdir -p /home/<user>/homelab/data/transmission/config
sudo mkdir -p /media/hd2t/downloads/transmission/{complete,incomplete,watch}
```

Punto importante de diseño:

- `complete/` es el destino de descargas terminadas
- `incomplete/` separa lo que aún está escribiéndose
- `watch/` es opcional y sirve para que Transmission importe automáticamente ficheros `.torrent`

No descargues directamente en las bibliotecas finales de Jellyfin, ni en carpetas de series o películas. La idea correcta es **descargar primero**, **verificar después** y **dejar que Sonarr/Radarr importen más adelante**.

### 2. Ajustar propiedad y permisos

Usa el mismo usuario operativo del host que administra Docker y las carpetas del homelab:

```bash
id <user>
sudo chown -R <user>:<user> /home/<user>/homelab/data/transmission
sudo chown -R <user>:<user> /media/hd2t/downloads/transmission

sudo find /home/<user>/homelab/data/transmission -type d -exec chmod 775 {} \;
sudo find /home/<user>/homelab/data/transmission -type f -exec chmod 664 {} \;
sudo find /media/hd2t/downloads/transmission -type d -exec chmod 775 {} \;
sudo find /media/hd2t/downloads/transmission -type f -exec chmod 664 {} \;
```

La lógica operativa es esta:

- Transmission necesita escritura tanto en `config/` como en las carpetas de descarga
- mantener `complete/` e `incomplete/` en el mismo disco facilita movimientos rápidos y reduce trabajo extra de I/O
- si más adelante Sonarr y Radarr importan desde el mismo `hd2t`, mantener todo dentro del mismo sistema de archivos permite aprovechar **hardlinks** cuando se configure esa estrategia

### 3. Crear el fichero `.env`

Archivo: `/home/<user>/homelab/compose/downloads-transmission/.env`

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000
TRANSMISSION_BIND_IP=0.0.0.0
TRANSMISSION_WEB_PORT=15000
TRANSMISSION_PEER_PORT=51413
TRANSMISSION_RPC_USER=admin
TRANSMISSION_RPC_PASS=cambiar-esta-clave
TRANSMISSION_RPC_WHITELIST=
TRANSMISSION_HOST_WHITELIST=
PROXY_NETWORK=homelab_proxy
```

Notas prácticas:

- `PUID` y `PGID` deben coincidir con el usuario real del host
- `TRANSMISSION_BIND_IP=0.0.0.0` deja la interfaz accesible desde la LAN y desde la IP Tailscale del host
- si prefieres que la UI solo sea accesible detrás de otro servicio intermedio, puedes publicar `127.0.0.1:15000`
- cambia `TRANSMISSION_RPC_PASS` antes del primer uso real
- cuando `TRANSMISSION_RPC_WHITELIST` y `TRANSMISSION_HOST_WHITELIST` quedan vacíos, el cliente no impone esas restricciones adicionales; en este proyecto el control principal lo ponen la red local, Tailscale y la autenticación RPC

### 4. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/downloads-transmission
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=50 transmission
```

Validaciones útiles:

```bash
ss -ltnup | grep -E '15000|51413'
curl -sI http://127.0.0.1:15000 | head -n 5
```

Si todo ha arrancado bien, la interfaz quedará disponible por acceso directo en:

- `http://IP_DE_LA_PI:15000`
- `http://<hostname-de-tu-pi>.<tailnet>.ts.net:15000` desde dispositivos unidos a Tailscale con MagicDNS

Si tienes `ufw` activo y mantienes este acceso directo publicado en `0.0.0.0`, añade al menos la excepción del puerto web para no contradecir la política base de [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md):

```bash
sudo ufw allow from 192.168.1.0/24 to any port 15000 proto tcp comment 'Transmission UI desde LAN'
sudo ufw allow in on tailscale0 to any port 15000 proto tcp comment 'Transmission UI desde Tailscale'
```

El puerto de peers `51413/tcp` y `51413/udp` puede permanecer publicado en Docker aunque el router no haga `port forwarding`; eso no expone el servicio a internet por sí solo, pero sí conviene revisar que no lo estés bloqueando localmente si esperas tráfico BitTorrent desde la propia LAN.

### 5. Primer arranque y autenticación básica

En el primer arranque:

1. Abre la interfaz web.
2. Inicia sesión con el usuario y contraseña definidos en `.env`.
3. Verifica que el servicio responde con normalidad y que no aparecen errores de permisos en los logs.
4. Confirma que el stack ha creado correctamente `settings.json` dentro de `/home/<user>/homelab/data/transmission/config/`.

Rutas relevantes dentro del contenedor:

- configuración persistente: `/config`
- descargas gestionadas por Transmission: `/downloads`
- carpeta de vigilancia opcional: `/watch`

### 6. Configurar el directorio de descargas en `hd2t`

Tras entrar en la interfaz web, ajusta la ubicación de descargas para que quede alineada con el diseño del homelab.

Ajuste recomendado:

- directorio de descargas completas: `/downloads/complete`
- directorio de descargas incompletas: `/downloads/incomplete`
- activar uso de directorio incompleto
- activar renombrado parcial mientras la descarga está en curso
- dejar `watch-dir` desactivado salvo que realmente vayas a depositar `.torrent` en `/watch`

Si prefieres editar el fichero directamente, detén primero el contenedor para evitar que Transmission sobrescriba cambios al cerrar:

```bash
cd /home/<user>/homelab/compose/downloads-transmission
docker compose stop transmission
sudoedit /home/<user>/homelab/data/transmission/config/settings.json
docker compose start transmission
```

Bloque mínimo recomendado en `settings.json`:

```json
{
  "download-dir": "/downloads/complete",
  "incomplete-dir": "/downloads/incomplete",
  "incomplete-dir-enabled": true,
  "rename-partial-files": true,
  "watch-dir": "/watch",
  "watch-dir-enabled": false,
  "rpc-authentication-required": true,
  "peer-port": 51413,
  "peer-port-random-on-start": false,
  "port-forwarding-enabled": false
}
```

La clave aquí no es complicar Transmission, sino mantener un flujo limpio:

- las descargas siempre aterrizan en `hd2t`
- los datos críticos del cliente viven en el NVMe
- el cliente no intenta abrir puertos automáticamente en el router

### 7. Perfil inicial recomendado de velocidad

En una Raspberry Pi 5 con disco USB para payload y un uso mixto del homelab, conviene empezar con límites razonables y observar antes de subirlos.

Perfil de partida recomendable:

- límite de descarga global: `20000 KB/s`
- límite de subida global: `3000 KB/s`
- modo de velocidad alternativa:
  - descarga: `4000 KB/s`
  - subida: `500 KB/s`
- horario alternativo: horas laborables o de baja prioridad, si compartes la conexión con otros usos de casa

Interpretación práctica:

- `20000 KB/s` son aproximadamente `20 MB/s`, un punto de partida prudente si no conoces todavía el impacto real sobre tu línea y sobre `hd2t`
- no tiene sentido dejar Transmission sin límites si notas que degrada streaming, navegación o copias de seguridad
- si tu conexión y tus discos responden bien, sube los topes de forma gradual en lugar de empezar sin control

Recomendación operativa:

- empieza con límites moderados
- observa CPU, temperatura y latencia de la red de la Pi
- si Jellyfin u otros servicios empiezan a resentirse mientras hay descargas activas, baja primero la velocidad de subida antes que la de bajada

### 8. Perfil inicial recomendado de peers

Para este homelab, el objetivo no es maximizar peers a cualquier coste, sino mantener buen comportamiento general del host.

Punto de partida recomendable:

- puerto de peers fijo: `51413`
- puerto aleatorio al arrancar: desactivado
- DHT: activado
- PEX: activado
- LPD: desactivado salvo que tengas un caso concreto en la LAN
- cifrado: preferido
- límite global de peers: `120`
- límite de peers por torrent: `40`
- slots de subida por torrent: `6`

Qué significa esto en la práctica:

- **DHT** y **PEX** ayudan a compensar parcialmente la falta de conectividad entrante típica de un entorno sin port forwarding
- **LPD** aporta poco en este escenario y puede dejarse apagado
- un límite global de `120` y `40` por torrent suele ser suficiente para una Raspberry Pi 5 sin disparar el ruido de red ni la carga sobre el disco USB
- si cargas muchos torrents pequeños al mismo tiempo, es mejor controlar las colas antes que elevar agresivamente los peers

Importante:

- como el router no abrirá `51413` hacia internet, el cliente puede no aparecer como completamente conectable desde fuera
- eso no es un fallo de Transmission; es una consecuencia deliberada del diseño de red de este homelab

### 9. Cola y comportamiento recomendado

Para no convertir la Pi en una máquina de I/O caótico, conviene limitar cuántas tareas activas trabajan a la vez.

Ajuste inicial razonable:

- descargas activas simultáneas: `3`
- torrents en seed simultáneos: `8`
- ratio o tiempo de seed: según tu política personal, pero sin dejar colas infinitas por defecto si el espacio de `hd2t` importa

El objetivo es sencillo:

- mantener `hd2t` estable
- evitar picos de I/O innecesarios
- dejar margen a otros servicios del homelab

## Almacenamiento

Rutas persistentes del servicio:

- Compose: `/home/<user>/homelab/compose/downloads-transmission/docker-compose.yml`
- Variables del stack: `/home/<user>/homelab/compose/downloads-transmission/.env`
- Configuración, sesión y estado del cliente: `/home/<user>/homelab/data/transmission/config`
- Descargas completas: `/media/hd2t/downloads/transmission/complete`
- Descargas incompletas: `/media/hd2t/downloads/transmission/incomplete`
- Watch directory opcional: `/media/hd2t/downloads/transmission/watch`

Criterio de almacenamiento:

- todo lo operativo de Transmission vive en el **SSD NVMe**
- `hd2t` solo almacena los payloads de descarga
- no se guarda el estado del cliente ni `settings.json` en discos USB
- no se descargan torrents directamente en las bibliotecas finales del resto de servicios
- la ruta base compartida con otros stacks es `/media/hd2t/downloads/transmission/`: **Sonarr** y **Radarr** montan el mismo árbol base para ver las rutas exactamente igual que Transmission y evitar `Remote Path Mappings` en el caso base

## Backup

Respaldar como mínimo:

- `/home/<user>/homelab/compose/downloads-transmission/docker-compose.yml`
- `/home/<user>/homelab/compose/downloads-transmission/.env`
- `/home/<user>/homelab/data/transmission/config`

Las carpetas de `/media/hd2t/downloads/transmission/` no forman parte del backup de la **aplicación** en sí; son el **contenido descargado** y deben tratarse como datos operativos o multimedia según tu política general del homelab.

Para una copia más consistente del estado del cliente, detén brevemente el contenedor durante el backup:

```bash
cd /home/<user>/homelab/compose/downloads-transmission
docker compose stop transmission
# ejecutar backup
docker compose start transmission
```

Esto es especialmente recomendable si quieres conservar:

- torrents cargados
- estado de seed
- progreso de descargas pausadas
- ajustes efectivos de `settings.json`

## Referencias

- Documentación oficial de Transmission: https://transmissionbt.com/
- Documentación oficial de edición de configuración: https://github.com/transmission/transmission/blob/main/docs/Editing-Configuration-Files.md
- Documentación de la imagen Docker de LinuxServer: https://docs.linuxserver.io/images/docker-transmission/
- Repositorio oficial de la imagen Docker de LinuxServer: https://github.com/linuxserver/docker-transmission
