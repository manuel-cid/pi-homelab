# Navidrome

## Descripción

**Navidrome** es el servidor de música del homelab, orientado a servir una biblioteca personal mediante interfaz web y clientes compatibles con **Subsonic/OpenSubsonic**. En esta arquitectura se despliega como stack Docker propio, con los **datos operativos en el SSD NVMe** y la **biblioteca musical en `hd2t`**.

La política de este proyecto se mantiene igual que en el resto de servicios multimedia:

- la configuración, la base de datos, la caché y el estado del servicio viven en `/home/<user>/homelab/data/navidrome/` sobre el **SSD NVMe**
- la música vive en `/mnt/hd2t/media/navidrome/music/`
- el acceso principal se hace desde la **LAN**
- el acceso remoto se hace por **Tailscale**, sin abrir puertos en el router
- **Caddy** puede usarse como reverse proxy interno según [05-caddy.md](/Users/x441425/workspace2/homelab/docs/03-red/05-caddy.md)

Navidrome encaja especialmente bien en este homelab porque expone su biblioteca a través de una API compatible con clientes móviles y de escritorio. Dos clientes especialmente prácticos para este escenario son **DSub** y **Symfonium**.

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](/Users/x441425/workspace2/homelab/docs/01-sistema/04-estructura-directorios.md).
- Tener Docker Engine y Docker Compose operativos según [01-instalacion-docker.md](/Users/x441425/workspace2/homelab/docs/02-docker/01-instalacion-docker.md).
- Haber fijado la convención de stacks y `.env` descrita en [02-estructura-compose.md](/Users/x441425/workspace2/homelab/docs/02-docker/02-estructura-compose.md).
- Haber desplegado [04-tailscale.md](/Users/x441425/workspace2/homelab/docs/03-red/04-tailscale.md) si quieres acceso remoto seguro.
- Haber desplegado [05-caddy.md](/Users/x441425/workspace2/homelab/docs/03-red/05-caddy.md) si quieres publicar Navidrome detrás del reverse proxy interno.
- Revisar [06-puertos-y-firewall.md](/Users/x441425/workspace2/homelab/docs/03-red/06-puertos-y-firewall.md) para registrar el puerto publicado por el servicio.
- Tener montado `hd2t` en `/mnt/hd2t`.
- Tener creada la red Docker externa `homelab_proxy` si vas a seguir el patrón de publicación detrás de Caddy.
- Puertos necesarios:
  - `14001/tcp` en el host para acceso web y API desde LAN o Tailscale
  - `4533/tcp` como puerto interno del contenedor

## Docker Compose

Archivo: `/home/<user>/homelab/compose/media-navidrome/docker-compose.yml`

```yaml
name: media-navidrome

services:
  navidrome:
    image: deluan/navidrome:latest
    restart: unless-stopped
    user: "${PUID}:${PGID}"
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      ND_MUSICFOLDER: /music
      ND_DATAFOLDER: /data
      ND_CACHEFOLDER: /cache
      ND_BASEURL: ${NAVIDROME_BASEURL}
      ND_LOGLEVEL: info
      ND_ENABLEINSIGHTSCOLLECTOR: "false"
    ports:
      - "${NAVIDROME_BIND_IP}:${NAVIDROME_HTTP_PORT}:4533"
    volumes:
      - /home/<user>/homelab/data/navidrome/data:/data
      - /home/<user>/homelab/data/navidrome/cache:/cache
      - /mnt/hd2t/media/navidrome/music:/music:ro
    networks:
      - default
      - proxy
    labels:
      - com.centurylinklabs.watchtower.enable=true

networks:
  proxy:
    external: true
    name: ${PROXY_NETWORK}
```

Notas sobre este Compose:

- el stack queda aislado bajo `media-navidrome`
- la base de datos y la caché persisten en el **SSD NVMe**
- la biblioteca musical se monta desde `hd2t` en modo lectura para proteger la colección frente a borrados accidentales desde el contenedor
- el servicio se conecta también a `homelab_proxy` para que **Caddy** pueda alcanzarlo por nombre interno Docker
- `ND_BASEURL` permite servir Navidrome detrás de una subruta como `/navidrome` cuando se publica por el hostname HTTPS de Tailscale detrás de Caddy

## Configuración

### 1. Preparar directorios del stack y de la biblioteca

```bash
mkdir -p /home/<user>/homelab/compose/media-navidrome
mkdir -p /home/<user>/homelab/data/navidrome/{data,cache}
sudo mkdir -p /mnt/hd2t/media/navidrome/music
```

Una organización razonable de la biblioteca puede ser:

```bash
sudo mkdir -p /mnt/hd2t/media/navidrome/music/{artists,compilations,soundtracks}
```

No es obligatorio seguir ese esquema exacto, pero sí conviene mantener una estructura estable y metadatos bien etiquetados para que el escaneo de Navidrome sea predecible.

### 2. Ajustar propiedad y permisos

Usa el mismo usuario operativo del host que administra Docker y las carpetas del homelab:

```bash
id <user>
sudo chown -R <user>:<user> /home/<user>/homelab/data/navidrome
sudo chown -R <user>:<user> /mnt/hd2t/media/navidrome

sudo find /home/<user>/homelab/data/navidrome -type d -exec chmod 775 {} \;
sudo find /home/<user>/homelab/data/navidrome -type f -exec chmod 664 {} \;
sudo find /mnt/hd2t/media/navidrome -type d -exec chmod 755 {} \;
sudo find /mnt/hd2t/media/navidrome -type f -exec chmod 644 {} \;
```

La lógica es la misma que en otros servicios multimedia:

- Navidrome necesita escritura en `data/` y `cache/`
- la biblioteca musical no necesita permisos de escritura desde el contenedor en un despliegue base

Si gestionas la música desde un share Samba con permisos de grupo más abiertos, mantén esa política en el host, pero conserva el montaje `:ro` en Docker.

### 3. Crear el fichero `.env`

Archivo: `/home/<user>/homelab/compose/media-navidrome/.env`

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000
NAVIDROME_BIND_IP=0.0.0.0
NAVIDROME_HTTP_PORT=14001
NAVIDROME_BASEURL=
PROXY_NETWORK=homelab_proxy
```

Notas prácticas:

- `PUID` y `PGID` deben coincidir con el usuario real del host
- `NAVIDROME_BIND_IP=0.0.0.0` deja el servicio accesible desde la LAN y también desde la IP Tailscale del host
- si prefieres acceso solo detrás de Caddy, puedes publicar `127.0.0.1:14001`
- deja `NAVIDROME_BASEURL` vacío si accedes por puerto directo o por `http://navidrome.lan`
- usa `NAVIDROME_BASEURL=/navidrome` si vas a publicar el servicio en `https://<host>.ts.net/navidrome/` detrás de Caddy

### 4. Configuración opcional con `navidrome.toml`

Navidrome puede funcionar solo con variables de entorno, pero algunas preferencias quedan más cómodas en un fichero dedicado.

Archivo opcional: `/home/<user>/homelab/data/navidrome/data/navidrome.toml`

```toml
Scanner.Schedule = '@every 24h'
TranscodingCacheSize = '150MiB'
DefaultLanguage = 'es'
```

Este enfoque resulta útil para:

- fijar un escaneo periódico sin meter expresiones con espacios en `.env`
- limitar el tamaño de la caché de transcodificación
- dejar la configuración avanzada junto al resto de datos persistentes del servicio

### 5. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/media-navidrome
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=50 navidrome
```

Validaciones útiles:

```bash
ss -ltnp | grep 14001
curl -I http://127.0.0.1:14001
```

Si todo ha arrancado bien, la interfaz quedará disponible por acceso directo en:

- `http://IP_DE_LA_PI:14001`
- `http://pi-homelab.<tailnet>.ts.net:14001` desde dispositivos unidos a Tailscale

Y, si ya tienes Caddy operativo:

- `http://navidrome.lan`
- `https://pi-homelab.<tailnet>.ts.net/navidrome/` si has configurado `ND_BASEURL=/navidrome`

### 6. Primer arranque y ajustes recomendados

En el primer arranque:

1. Abre la interfaz web.
2. Crea el usuario administrador inicial.
3. Verifica que la biblioteca montada en `/music` es accesible.
4. Espera al primer escaneo o lánzalo manualmente desde la interfaz de administración.

Puntos prácticos a revisar tras el alta inicial:

- confirma idioma, zona horaria y comportamiento de escaneo
- valida que carátulas y metadatos aparecen correctamente; si no, revisa primero los tags de los ficheros
- si publicas Navidrome detrás de una subruta, valida navegación, reproducción y login antes de darla por buena para móvil

Navidrome suele comportarse mejor cuando la colección está bien etiquetada de origen. Antes de culpar al servidor, revisa `artist`, `album`, `album artist`, `track number`, año y carátulas embebidas o `cover.*`.

### 7. Clientes compatibles: DSub y Symfonium

Navidrome expone una API compatible con clientes **Subsonic/OpenSubsonic**, así que no hace falta ningún plugin adicional.

Parámetros base para ambos clientes:

- URL del servidor:
  - `http://IP_DE_LA_PI:14001`
  - `http://navidrome.lan`
  - `http://pi-homelab.<tailnet>.ts.net:14001`
  - `https://pi-homelab.<tailnet>.ts.net/navidrome/` si usas Caddy con `ND_BASEURL=/navidrome`
- usuario: el mismo usuario creado en Navidrome
- contraseña: la misma contraseña del usuario

Notas operativas:

- no añadas manualmente `/rest`; el cliente suele construir las rutas API por su cuenta
- **DSub** funciona bien como cliente Subsonic clásico en Android y es una opción válida si quieres algo sencillo y probado
- **Symfonium** suele ofrecer mejor experiencia moderna en Android, soporte OpenSubsonic y más opciones de caché, descarga y reproducción
- si un cliente da problemas con una URL en subruta, prueba primero el acceso directo por puerto `:14001`

## Almacenamiento

Rutas persistentes del servicio:

- Compose: `/home/<user>/homelab/compose/media-navidrome/docker-compose.yml`
- Variables del stack: `/home/<user>/homelab/compose/media-navidrome/.env`
- Configuración opcional avanzada: `/home/<user>/homelab/data/navidrome/data/navidrome.toml`
- Base de datos y datos del servicio: `/home/<user>/homelab/data/navidrome/data`
- Caché y temporales: `/home/<user>/homelab/data/navidrome/cache`
- Biblioteca musical: `/mnt/hd2t/media/navidrome/music`

Criterio de almacenamiento:

- todo lo operativo de Navidrome vive en el **SSD NVMe**
- `hd2t` solo almacena los archivos musicales
- no se guarda base de datos ni caché de Navidrome en discos USB

## Backup

Respaldar como mínimo:

- `/home/<user>/homelab/compose/media-navidrome/docker-compose.yml`
- `/home/<user>/homelab/compose/media-navidrome/.env`
- `/home/<user>/homelab/data/navidrome/data`

Opcional según tu política de restauración:

- `/home/<user>/homelab/data/navidrome/cache`

En general, la caché puede reconstruirse. Lo realmente importante es conservar la configuración efectiva, la base de datos y el estado del servicio.

La biblioteca de `/mnt/hd2t/media/navidrome/music` no forma parte del backup de la aplicación en sí; es el **contenido musical** y debe tratarse según la estrategia general de copias del homelab.

Para una copia más consistente de la base de datos interna, detén brevemente el contenedor durante el backup:

```bash
cd /home/<user>/homelab/compose/media-navidrome
docker compose stop navidrome
# ejecutar backup
docker compose start navidrome
```

Navidrome incluye opciones propias de backup, pero en este homelab no sustituyen la estrategia general centralizada sobre `hd2t`.

## Referencias

- Documentación oficial de instalación con Docker: https://www.navidrome.org/docs/installation/docker/
- Documentación oficial de opciones de configuración: https://www.navidrome.org/docs/usage/configuration/options/
- Catálogo oficial de apps y clientes compatibles: https://www.navidrome.org/apps/
- Imagen oficial Docker: https://hub.docker.com/r/deluan/navidrome
