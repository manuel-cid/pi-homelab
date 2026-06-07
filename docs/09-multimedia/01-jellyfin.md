# Jellyfin

## Descripción

**Jellyfin** es el servidor multimedia del homelab para películas, series, vídeos caseros y música. En esta arquitectura se despliega como stack Docker propio, con los **datos operativos en el SSD NVMe** y las **bibliotecas multimedia en `hd2t`**.

La política de este proyecto se mantiene sin excepciones:

- la configuración, la base de datos, la caché y el estado del servicio viven en `/home/<user>/homelab/data/jellyfin/` sobre el **SSD NVMe**
- los archivos multimedia viven en las categorías globales de `hd2t`, principalmente `/media/hd2t/media/movies/`, `/media/hd2t/media/tv/` y opcionalmente `/media/hd2t/media/music/`
- el acceso principal se hace desde la **LAN** a través de **Caddy**
- el acceso remoto se hace por **Tailscale** a través de **Caddy**, sin abrir puertos en el router
- **Caddy** puede usarse como reverse proxy interno según [05-caddy.md](../03-red/05-caddy.md)

En una **Raspberry Pi 5**, Jellyfin funciona bien si el objetivo principal es **Direct Play** y **Direct Stream**. La transcodificación existe, pero en ARM no conviene diseñar el servicio como si fuera un host x86 con Quick Sync o VA-API: el margen es más estrecho, la compatibilidad depende más del sistema base y ciertas combinaciones de códec, resolución, HDR o subtítulos pueden degradar mucho el rendimiento.

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Tener Docker Engine y Docker Compose operativos según [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber fijado la convención de stacks y `.env` descrita en [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber desplegado [04-tailscale.md](../03-red/04-tailscale.md) si quieres acceso remoto seguro.
- Haber desplegado [05-caddy.md](../03-red/05-caddy.md) si quieres publicar Jellyfin detrás del reverse proxy interno.
- Revisar [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) para mantener la política de no exponer servicios web en `0.0.0.0` cuando pueden ir detrás de Caddy.
- Tener montado `hd2t` en `/media/hd2t`.
- Puertos necesarios:
  - `8096/tcp` interno del contenedor para la interfaz web y API HTTP de Jellyfin
  - `127.0.0.1:8096:8096` en el host para que **Caddy**, al usar `network_mode: host`, alcance Jellyfin en loopback
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
    volumes:
      - /home/<user>/homelab/data/jellyfin/config:/config
      - /home/<user>/homelab/data/jellyfin/cache:/cache
      - /media/hd2t/media/movies:/media/movies:ro
      - /media/hd2t/media/tv:/media/tv:ro
      - /media/hd2t/media/music:/media/music:ro
    ports:
      - "127.0.0.1:8096:8096"
    labels:
      - wud.watch=true
```

Notas sobre este Compose:

- el stack queda aislado bajo `media-jellyfin`
- los datos persistentes van al **SSD NVMe**
- la biblioteca multimedia se monta desde las categorías compartidas de `hd2t` en modo lectura para reducir riesgo de borrados accidentales
- `8096` se publica solo en `127.0.0.1`, no en la IP LAN del host, para que **Caddy** lo alcance según la arquitectura definida en [05-caddy.md](../03-red/05-caddy.md)
- la entrada web recomendada del proyecto sigue siendo **Caddy**; la publicación en loopback existe para el upstream interno, no para acceso directo desde la LAN
- el Compose base no habilita aceleración hardware porque en Raspberry Pi depende del kernel, del stack multimedia disponible y de qué dispositivos exponga realmente el host

## Configuración

### 1. Preparar directorios del stack y de la biblioteca

```bash
mkdir -p /home/<user>/homelab/compose/media-jellyfin
mkdir -p /home/<user>/homelab/data/jellyfin/{config,cache}
sudo mkdir -p /media/hd2t/media/movies
sudo mkdir -p /media/hd2t/media/tv
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
sudo chown -R <user>:<user> /media/hd2t/media/movies
sudo chown -R <user>:<user> /media/hd2t/media/tv
sudo find /home/<user>/homelab/data/jellyfin -type d -exec chmod 775 {} \;
sudo find /home/<user>/homelab/data/jellyfin -type f -exec chmod 664 {} \;
sudo find /media/hd2t/media/movies -type d -exec chmod 755 {} \;
sudo find /media/hd2t/media/movies -type f -exec chmod 644 {} \;
sudo find /media/hd2t/media/tv -type d -exec chmod 755 {} \;
sudo find /media/hd2t/media/tv -type f -exec chmod 644 {} \;
```

Si has creado `/media/hd2t/media/music`, aplica también permisos sobre esa ruta:

```bash
sudo chown -R <user>:<user> /media/hd2t/media/music
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
```

Notas prácticas:

- `PUID` y `PGID` deben coincidir con el usuario real del host
- `127.0.0.1:8096:8096` ya deja el upstream listo para **Caddy** y permite diagnóstico local desde la propia Raspberry Pi o mediante túnel SSH
- no cambies esa publicación a `0.0.0.0:8096:8096` salvo que tengas un motivo muy concreto y hayas revisado antes [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md)

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
curl -I http://127.0.0.1:8096
```

Para validar el flujo completo a través de **Caddy**:

```bash
curl -I -H 'Host: jellyfin.lan' http://127.0.0.1
```

Si todo ha arrancado bien, la interfaz quedará disponible en:

- `http://jellyfin.lan` en la LAN
- `http://127.0.0.1:8096` solo desde la propia Raspberry Pi o por túnel SSH, útil para bootstrap y diagnóstico
- acceso remoto por Tailscale una vez valides en Caddy un patrón compatible para Jellyfin

### 5. Asistente inicial de Jellyfin

En el primer arranque:

1. Abre la interfaz web.
2. Elige idioma y usuario administrador.
3. Configura la metadata en el idioma que prefieras.
4. Crea las bibliotecas apuntando a las rutas internas del contenedor.

Rutas típicas dentro del contenedor:

- películas: `/media/movies`
- series: `/media/tv`
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
- [05-caddy.md](../03-red/05-caddy.md) deja explícito que no debes asumir que Jellyfin soporte bien una subruta remota por defecto
- <!-- TODO: verificar si Jellyfin se publicará por subruta bajo `https://pi-homelab.<tailnet>.ts.net/...` o por hostname dedicado antes de activarlo en producción -->

Recomendación operativa:

- para la **LAN**, usa `http://jellyfin.lan`
- para acceso remoto, usa Tailscale solo después de validar en Caddy un patrón compatible para Jellyfin
- mantén `127.0.0.1:8096` como upstream interno y punto de diagnóstico local; no lo conviertas en publicación LAN directa

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
- Biblioteca de películas: `/media/hd2t/media/movies`
- Biblioteca de series: `/media/hd2t/media/tv`
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
- `/home/<user>/homelab/config/caddy/Caddyfile` si publicas Jellyfin detrás de Caddy

Opcional según tu política de restauración:

- `/home/<user>/homelab/data/jellyfin/cache`

En general, la caché puede reconstruirse, así que no suele merecer la pena priorizarla frente a la configuración y la base de datos.

Las bibliotecas de `/media/hd2t/media/movies`, `/media/hd2t/media/tv` y `/media/hd2t/media/music` no forman parte del backup de la aplicación en sí; son el **contenido multimedia** y deben tratarse según la estrategia general de copias del homelab.

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
