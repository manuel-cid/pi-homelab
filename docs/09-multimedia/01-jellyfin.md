# Jellyfin

## Descripción

**Jellyfin** es el servidor multimedia del homelab para películas, series, vídeos caseros y música. En esta arquitectura se despliega como stack Docker propio, con los **datos operativos en el SSD NVMe** y las **bibliotecas multimedia en `hd2t`**.

La política de este proyecto se mantiene sin excepciones:

- la configuración, la base de datos, la caché y el estado del servicio viven en `/home/<user>/homelab/data/jellyfin/` sobre el **SSD NVMe**
- los archivos multimedia viven en las categorías globales de `hd2t`, principalmente `/media/hd2t/media/video/` y opcionalmente `/media/hd2t/media/music/`
- el acceso principal se hace desde la **LAN**
- el acceso remoto se hace por **Tailscale**, sin abrir puertos en el router
- **Caddy** puede usarse como reverse proxy interno según [05-caddy.md](../03-red/05-caddy.md)

En una **Raspberry Pi 5**, Jellyfin funciona bien si el objetivo principal es **Direct Play** y **Direct Stream**. La transcodificación existe, pero en ARM no conviene diseñar el servicio como si fuera un host x86 con Quick Sync o VA-API: el margen es más estrecho, la compatibilidad depende más del sistema base y ciertas combinaciones de códec, resolución, HDR o subtítulos pueden degradar mucho el rendimiento.

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Tener Docker Engine y Docker Compose operativos según [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber fijado la convención de stacks y `.env` descrita en [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber desplegado [04-tailscale.md](../03-red/04-tailscale.md) si quieres acceso remoto seguro.
- Haber desplegado [05-caddy.md](../03-red/05-caddy.md) si quieres publicar Jellyfin detrás del reverse proxy interno.
- Revisar [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) para registrar el puerto publicado por el servicio.
- Tener montado `hd2t` en `/media/hd2t`.
- Tener creada la red Docker externa `homelab_proxy` si vas a seguir el patrón de publicación detrás de Caddy.
- Puertos necesarios:
  - `8096/tcp` para la interfaz web y API HTTP de Jellyfin
  - `1900/udp` solo si quieres DLNA
  - `7359/udp` solo si quieres descubrimiento automático de clientes

## Docker Compose

Archivo: `/home/<user>/homelab/compose/media-jellyfin/docker-compose.yml`

```yaml
name: media-jellyfin

services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    restart: unless-stopped
    user: "${PUID}:${PGID}"
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    ports:
      - "${JELLYFIN_BIND_IP}:${JELLYFIN_HTTP_PORT}:8096"
    volumes:
      - /home/<user>/homelab/data/jellyfin/config:/config
      - /home/<user>/homelab/data/jellyfin/cache:/cache
      - /media/hd2t/media/video:/media/video:ro
      - /media/hd2t/media/music:/media/music:ro
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

- el stack queda aislado bajo `media-jellyfin`
- los datos persistentes van al **SSD NVMe**
- la biblioteca multimedia se monta desde las categorías compartidas de `hd2t` en modo lectura para reducir riesgo de borrados accidentales
- el servicio se conecta también a `homelab_proxy` para que **Caddy** pueda alcanzarlo por nombre interno Docker
- el Compose base no habilita aceleración hardware porque en Raspberry Pi depende del kernel, del stack multimedia disponible y de qué dispositivos exponga realmente el host

## Configuración

### 1. Preparar directorios del stack y de la biblioteca

```bash
mkdir -p /home/<user>/homelab/compose/media-jellyfin
mkdir -p /home/<user>/homelab/data/jellyfin/{config,cache}
sudo mkdir -p /media/hd2t/media/video/{movies,series,concerts,homevideos}
```

Si quieres exponer también música desde Jellyfin, añade una carpeta más:

```bash
sudo mkdir -p /media/hd2t/media/music
```

### 2. Ajustar propiedad y permisos

Usa el mismo usuario operativo del host que administra Docker y las carpetas del homelab:

```bash
id <user>
sudo chown -R <user>:<user> /home/<user>/homelab/data/jellyfin
sudo chown -R <user>:<user> /media/hd2t/media/video
sudo chown -R <user>:<user> /media/hd2t/media/music

sudo find /home/<user>/homelab/data/jellyfin -type d -exec chmod 775 {} \;
sudo find /home/<user>/homelab/data/jellyfin -type f -exec chmod 664 {} \;
sudo find /media/hd2t/media/video -type d -exec chmod 755 {} \;
sudo find /media/hd2t/media/video -type f -exec chmod 644 {} \;
sudo find /media/hd2t/media/music -type d -exec chmod 755 {} \;
sudo find /media/hd2t/media/music -type f -exec chmod 644 {} \;
```

La idea es simple:

- Jellyfin necesita escribir en `config/` y `cache/`
- la biblioteca de medios no necesita permisos de escritura desde el contenedor para un despliegue base

### 3. Crear el fichero `.env`

Archivo: `/home/<user>/homelab/compose/media-jellyfin/.env`

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000
JELLYFIN_BIND_IP=0.0.0.0
JELLYFIN_HTTP_PORT=8096
PROXY_NETWORK=homelab_proxy
```

Notas prácticas:

- `PUID` y `PGID` deben coincidir con el usuario real del host
- `JELLYFIN_BIND_IP=0.0.0.0` deja el servicio accesible desde la LAN y también desde la IP Tailscale del host
- si prefieres que solo sea accesible mediante Caddy, puedes publicar `127.0.0.1:8096` y dejar que el proxy sea la única entrada web

### 4. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/media-jellyfin
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=50 jellyfin
```

Validaciones útiles:

```bash
ss -ltnp | grep 8096
curl -I http://127.0.0.1:8096
```

Si todo ha arrancado bien, la interfaz quedará disponible por acceso directo en:

- `http://IP_DE_LA_PI:8096`
- `http://pi-homelab.<tailnet>.ts.net:8096` desde dispositivos unidos a Tailscale

Y, si ya tienes Caddy operativo:

- `http://jellyfin.lan`

### 5. Asistente inicial de Jellyfin

En el primer arranque:

1. Abre la interfaz web.
2. Elige idioma y usuario administrador.
3. Configura la metadata en el idioma que prefieras.
4. Crea las bibliotecas apuntando a las rutas internas del contenedor.

Rutas típicas dentro del contenedor:

- películas: `/media/video/movies`
- series: `/media/video/series`
- conciertos o directos: `/media/video/concerts`
- vídeos caseros: `/media/video/homevideos`
- música, si la usas: `/media/music`

Como los metadatos y la base de datos viven en el SSD NVMe, no hace falta guardar `nfo`, posters o bases SQLite en `hd2t`.

### 6. Ajustes recomendados tras el primer arranque

En **Dashboard -> Playback**:

- activa la aceleración hardware solo después de comprobar que realmente mejora tu caso de uso
- deja la ruta de transcodificación temporal dentro de `/cache`
- evita asumir varias transcodificaciones simultáneas en una Raspberry Pi 5

En **Dashboard -> Libraries**:

- desactiva escaneos demasiado agresivos si la biblioteca es grande
- programa la actualización de bibliotecas en horas de baja actividad

En **Dashboard -> Networking**:

- si accedes por nombre LAN detrás de Caddy, puedes mantener el acceso normal sin cambios especiales
- si vas a usar la ruta remota `https://pi-homelab.<tailnet>.ts.net/jellyfin/` del ejemplo de [05-caddy.md](../03-red/05-caddy.md), valida cuidadosamente la opción **Base URL** con `/jellyfin` antes de depender de ella en clientes móviles o TV

Recomendación operativa:

- para la **LAN**, usa `http://jellyfin.lan` o acceso directo a `:8096`
- para acceso remoto sencillo, Tailscale directo a `:8096` suele dar menos fricción que una subruta
- usa Caddy delante de Jellyfin cuando quieras centralizar nombres internos o unificar la entrada web del homelab

### 7. Transcodificación por hardware en Raspberry Pi 5

Aquí conviene ser conservador:

- en ARM, Jellyfin no ofrece una experiencia tan predecible de transcodificación hardware como en hosts x86 con Intel Quick Sync
- la compatibilidad real depende de la versión de **Jellyfin**, **FFmpeg**, el kernel, los drivers y los dispositivos multimedia que exponga tu sistema
- el punto fuerte de una Raspberry Pi 5 para Jellyfin no es servir varias transcodificaciones pesadas, sino reproducir contenido que los clientes puedan consumir por **Direct Play**

Qué evitar como expectativa base:

- múltiples transcodificaciones simultáneas
- conversión 4K pesada hacia clientes lentos
- `burn-in` frecuente de subtítulos en vídeo
- `tone mapping` HDR como carga habitual

Qué sí funciona mejor en este escenario:

- clientes modernos con soporte nativo de H.264, H.265, AAC, AC3 y subtítulos externos sencillos
- bibliotecas bien organizadas para reducir rescans y trabajo de metadata
- mantener la caché y los temporales en el SSD NVMe

Si quieres experimentar con aceleración hardware real, hazlo como ajuste posterior y no como requisito de despliegue:

- identifica primero qué nodos expone el host, por ejemplo `/dev/video*` o `/dev/dri/*`
- prueba con un solo flujo y monitoriza CPU, memoria y estabilidad
- conserva siempre la opción de volver a **software transcoding** o a **Direct Play** si el resultado no es estable

## Almacenamiento

Rutas persistentes del servicio:

- Compose: `/home/<user>/homelab/compose/media-jellyfin/docker-compose.yml`
- Variables del stack: `/home/<user>/homelab/compose/media-jellyfin/.env`
- Configuración y base de datos: `/home/<user>/homelab/data/jellyfin/config`
- Caché y temporales: `/home/<user>/homelab/data/jellyfin/cache`
- Biblioteca de vídeo: `/media/hd2t/media/video`
- Biblioteca de música: `/media/hd2t/media/music`

Criterio de almacenamiento:

- todo lo operativo de Jellyfin vive en el **SSD NVMe**
- `hd2t` solo almacena los archivos multimedia
- no se guarda base de datos ni caché de Jellyfin en discos USB

## Backup

Respaldar como mínimo:

- `/home/<user>/homelab/compose/media-jellyfin/docker-compose.yml`
- `/home/<user>/homelab/compose/media-jellyfin/.env`
- `/home/<user>/homelab/data/jellyfin/config`

Opcional según tu política de restauración:

- `/home/<user>/homelab/data/jellyfin/cache`

En general, la caché puede reconstruirse, así que no suele merecer la pena priorizarla frente a la configuración y la base de datos.

Las bibliotecas de `/media/hd2t/media/video` y `/media/hd2t/media/music` no forman parte del backup de la aplicación en sí; son el **contenido multimedia** y deben tratarse según la estrategia general de copias del homelab.

Para una copia más consistente de la base de datos interna, detén brevemente el contenedor durante el backup:

```bash
cd /home/<user>/homelab/compose/media-jellyfin
docker compose stop jellyfin
# ejecutar backup
docker compose start jellyfin
```

## Referencias

- Documentación oficial de Jellyfin en contenedor: https://jellyfin.org/docs/general/installation/container/
- Documentación oficial de red y puertos: https://jellyfin.org/docs/general/post-install/networking/
- Documentación oficial de aceleración hardware: https://jellyfin.org/docs/general/post-install/transcoding/hardware-acceleration/
- Imagen oficial Docker: https://hub.docker.com/r/jellyfin/jellyfin
