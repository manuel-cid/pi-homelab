# Stash

## Descripción

**Stash** es el organizador y reproductor multimedia del homelab para una biblioteca dedicada, con enfoque en **catalogación**, **metadatos**, **búsqueda avanzada**, **etiquetado** y **scraping**. En esta arquitectura se despliega como stack Docker propio, con los **datos operativos en el SSD NVMe** y la **biblioteca multimedia en `hd5t`**, que queda reservada exclusivamente para este servicio.

La política de almacenamiento de este proyecto se mantiene igual que en el resto de servicios:

- la configuración, la base de datos, los blobs, la metadata descargada, la caché y el contenido generado viven en `/home/<user>/homelab/data/stash/` sobre el **SSD NVMe**
- la biblioteca multimedia vive en `/mnt/hd5t/stash/data/`
- el acceso principal se hace desde la **LAN**
- el acceso remoto se hace por **Tailscale**, sin abrir puertos en el router
- **Caddy** puede usarse como reverse proxy interno según [05-caddy.md](/Users/x441425/workspace2/homelab/docs/03-red/05-caddy.md)

Stash encaja bien en este homelab porque separa claramente la **biblioteca real** del **estado operativo** del servicio. Eso permite dejar en el SSD NVMe lo sensible al rendimiento y a la consistencia del SQLite, mientras `hd5t` absorbe el crecimiento del catálogo multimedia.

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](/Users/x441425/workspace2/homelab/docs/01-sistema/04-estructura-directorios.md).
- Tener Docker Engine y Docker Compose operativos según [01-instalacion-docker.md](/Users/x441425/workspace2/homelab/docs/02-docker/01-instalacion-docker.md).
- Haber fijado la convención de stacks y `.env` descrita en [02-estructura-compose.md](/Users/x441425/workspace2/homelab/docs/02-docker/02-estructura-compose.md).
- Haber desplegado [04-tailscale.md](/Users/x441425/workspace2/homelab/docs/03-red/04-tailscale.md) si quieres acceso remoto seguro.
- Haber desplegado [05-caddy.md](/Users/x441425/workspace2/homelab/docs/03-red/05-caddy.md) si quieres publicar Stash detrás del reverse proxy interno.
- Revisar [06-puertos-y-firewall.md](/Users/x441425/workspace2/homelab/docs/03-red/06-puertos-y-firewall.md) para registrar el puerto publicado por el servicio.
- Tener montado `hd5t` en `/mnt/hd5t`.
- Tener creada la red Docker externa `homelab_proxy` si vas a seguir el patrón de publicación detrás de Caddy.
- Puertos necesarios:
  - `14004/tcp` en el host para acceso web desde LAN o Tailscale
  - `9999/tcp` como puerto interno del contenedor

## Docker Compose

Archivo: `/home/<user>/homelab/compose/media-stash/docker-compose.yml`

```yaml
name: media-stash

services:
  stash:
    image: stashapp/stash:latest
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      STASH_STASH: /data/
      STASH_GENERATED: /generated/
      STASH_METADATA: /metadata/
      STASH_CACHE: /cache/
      STASH_PORT: ${STASH_PORT}
    ports:
      - "${STASH_BIND_IP}:${STASH_HTTP_PORT}:${STASH_PORT}"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /home/<user>/homelab/data/stash/config:/root/.stash
      - /mnt/hd5t/stash/data:/data:ro
      - /home/<user>/homelab/data/stash/metadata:/metadata
      - /home/<user>/homelab/data/stash/cache:/cache
      - /home/<user>/homelab/data/stash/blobs:/blobs
      - /home/<user>/homelab/data/stash/generated:/generated
    logging:
      driver: json-file
      options:
        max-file: "10"
        max-size: "2m"
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

- el stack queda aislado bajo `media-stash`
- la biblioteca vive en `hd5t`
- la base de datos, blobs, caché, scrapers, plugins y contenido generado viven en el **SSD NVMe**
- la biblioteca se monta en modo lectura para un despliegue base más seguro
- el servicio se conecta también a `homelab_proxy` para que **Caddy** pueda alcanzarlo por nombre interno Docker
- el Compose sigue el esquema oficial de Stash para `config`, `metadata`, `cache`, `blobs` y `generated`

Si más adelante quieres usar funciones de **organización, renombrado o movimiento de archivos desde Stash**, tendrás que quitar `:ro` del bind mount `/mnt/hd5t/stash/data:/data:ro` y validar muy bien esa política antes de activarla en producción.

## Configuración

### 1. Preparar directorios del stack y de la biblioteca

```bash
mkdir -p /home/<user>/homelab/compose/media-stash
mkdir -p /home/<user>/homelab/data/stash/{config,metadata,cache,blobs,generated}
sudo mkdir -p /mnt/hd5t/stash/data/{scenes,galleries,incoming}
```

Una organización razonable de la biblioteca puede ser:

```bash
sudo mkdir -p /mnt/hd5t/stash/data/scenes/{studio,clips,movies}
sudo mkdir -p /mnt/hd5t/stash/data/galleries/{sets,photos}
```

No es obligatorio seguir ese esquema exacto, pero sí conviene mantener raíces estables para que los escaneos, filtros y scrapers sean predecibles.

### 2. Ajustar propiedad y permisos

Usa el mismo usuario operativo del host que administra Docker y las carpetas del homelab:

```bash
id <user>
sudo chown -R <user>:<user> /home/<user>/homelab/data/stash
sudo chown -R <user>:<user> /mnt/hd5t/stash

sudo find /home/<user>/homelab/data/stash -type d -exec chmod 775 {} \;
sudo find /home/<user>/homelab/data/stash -type f -exec chmod 664 {} \;
sudo find /mnt/hd5t/stash -type d -exec chmod 755 {} \;
sudo find /mnt/hd5t/stash -type f -exec chmod 644 {} \;
```

La lógica base es:

- Stash necesita escritura en `config/`, `metadata/`, `cache/`, `blobs/` y `generated/`
- la biblioteca multimedia no necesita escritura desde el contenedor en el despliegue recomendado

La imagen oficial de Stash suele ejecutarse con el usuario por defecto del contenedor. Este documento mantiene el Compose cercano al ejemplo oficial y evita forzar `PUID` o `PGID` sin haber validado antes ese cambio con la versión concreta que estés usando.

### 3. Crear el fichero `.env`

Archivo: `/home/<user>/homelab/compose/media-stash/.env`

```dotenv
TZ=Europe/Madrid
STASH_BIND_IP=0.0.0.0
STASH_HTTP_PORT=14004
STASH_PORT=9999
PROXY_NETWORK=homelab_proxy
```

Notas prácticas:

- `STASH_BIND_IP=0.0.0.0` deja el servicio accesible desde la LAN y también desde la IP Tailscale del host
- si prefieres acceso solo detrás de Caddy, puedes publicar `127.0.0.1:14004`
- `STASH_PORT` debe coincidir con el puerto interno del contenedor y con el mapeo del Compose

### 4. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/media-stash
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=50 stash
```

Validaciones útiles:

```bash
ss -ltnp | grep 14004
curl -I http://127.0.0.1:14004
```

Si todo ha arrancado bien, la interfaz quedará disponible por acceso directo en:

- `http://IP_DE_LA_PI:14004`
- `http://pi-homelab.<tailnet>.ts.net:14004` desde dispositivos unidos a Tailscale

Y, si ya tienes Caddy operativo:

- `http://stash.lan`

### 5. Primer arranque y rutas de trabajo

En el primer arranque:

1. Abre la interfaz web.
2. Revisa en la configuración que la biblioteca principal apunta a `/data`.
3. Define una ruta de backup dentro del SSD, por ejemplo `/metadata/backups`.
4. Si vas a usar almacenamiento binario en sistema de ficheros, configura la ruta de blobs en `/blobs`.
5. Lanza un primer escaneo de biblioteca para que Stash indexe el contenido.

Rutas relevantes dentro del contenedor:

- biblioteca multimedia: `/data`
- configuración, scrapers y plugins: `/root/.stash`
- metadata y base de datos: `/metadata`
- caché operativa: `/cache`
- blobs binarios: `/blobs`
- contenido generado: `/generated`

Como la base de datos y el estado del servicio viven en el SSD NVMe, no conviene mezclar `metadata`, `cache`, `blobs` o `generated` con el disco USB.

### 6. Scraping de metadatos: orden recomendado

En Stash conviene seguir este orden de trabajo:

1. escanear biblioteca
2. generar `pHashes`
3. usar primero el **Scene Tagger** contra una fuente tipo **stash-box**
4. recurrir a scrapers específicos de sitio solo cuando lo anterior no da buen resultado

Buenas prácticas:

- activa la generación de `pHashes` para nuevas escenas si realmente quieres aprovechar bien el matching
- para la primera biblioteca, genera `pHashes` manualmente en una ventana de baja carga
- usa primero el **Scene Tagger** antes de tirar de scrapers manuales o por URL
- en Raspberry Pi 5 conviene ejecutar tareas pesadas por lotes y evitar lanzar a la vez escaneo, generación de previews y scraping masivo

### 7. Configurar proveedores de metadatos

En **Settings -> Metadata Providers** puedes configurar las fuentes principales.

Fuentes habituales:

- **StashDB**: `https://stashdb.org/graphql`
- **ThePornDB**: `https://theporndb.net/graphql`
- **FansDB**: `https://fansdb.cc/graphql`

Notas prácticas:

- algunas fuentes requieren registro previo o configuración adicional en su propio portal
- usa **StashDB** como primera opción si buscas datos más curados
- **ThePornDB** puede cubrir más catálogo, pero conviene revisar resultados antes de aceptarlos a ciegas
- si trabajas con colecciones centradas en creadores de plataformas, **FansDB** puede ser útil como fuente adicional

### 8. Scrapers comunitarios y scrapers manuales

Stash permite instalar scrapers desde la propia interfaz en **Settings -> Metadata Providers**. La fuente comunitaria estable suele venir preparada por defecto.

Si necesitas scrapers manuales:

- Stash busca los ficheros de scraper en el subdirectorio `scrapers` del directorio de configuración
- en este despliegue, esa ruta del host es `/home/<user>/homelab/data/stash/config/scrapers`
- algunos scrapers son simples archivos YAML
- otros requieren scripts adicionales, por ejemplo Python o Ruby
- otros usan CDP y necesitan un navegador compatible para automatización

Recomendación operativa:

- empieza por las fuentes `stash-box` y por los scrapers instalables desde la UI
- añade scrapers manuales solo cuando tengas un caso concreto
- evita acumular scrapers poco mantenidos si no los usas de verdad

### 9. Ajustes recomendados para Raspberry Pi 5

Stash puede generar bastante carga en CPU, disco y temperatura cuando produce contenido derivado.

Conviene ser conservador con:

- previews de vídeo
- transcodes
- sprites
- generación masiva de imágenes derivadas

Recomendación base para una Pi 5:

- prioriza escaneo, `pHashes` y scraping antes que previews pesadas
- deja `generated/` en el SSD NVMe para reducir latencia
- programa tareas largas cuando no estés usando el resto del homelab
- si ves throttling o lentitud general, reduce la cantidad de tareas de generación simultáneas

## Almacenamiento

Rutas persistentes del servicio:

- Compose: `/home/<user>/homelab/compose/media-stash/docker-compose.yml`
- Variables del stack: `/home/<user>/homelab/compose/media-stash/.env`
- Configuración, plugins y scrapers: `/home/<user>/homelab/data/stash/config`
- Metadata y base de datos: `/home/<user>/homelab/data/stash/metadata`
- Caché: `/home/<user>/homelab/data/stash/cache`
- Blobs binarios: `/home/<user>/homelab/data/stash/blobs`
- Contenido generado: `/home/<user>/homelab/data/stash/generated`
- Biblioteca multimedia: `/mnt/hd5t/stash/data`

Criterio de almacenamiento:

- todo lo operativo de Stash vive en el **SSD NVMe**
- `hd5t` almacena exclusivamente la biblioteca multimedia de Stash
- no se guarda la base de datos ni el contenido generado en el disco USB
- los scrapers manuales y plugins quedan bajo `config/`, por lo que también forman parte del estado persistente del servicio

## Backup

Respaldar como mínimo:

- `/home/<user>/homelab/compose/media-stash/docker-compose.yml`
- `/home/<user>/homelab/compose/media-stash/.env`
- `/home/<user>/homelab/data/stash/config`
- `/home/<user>/homelab/data/stash/metadata`
- `/home/<user>/homelab/data/stash/blobs`

Opcional según tu política de restauración:

- `/home/<user>/homelab/data/stash/generated`
- `/home/<user>/homelab/data/stash/cache`

Puntos importantes:

- **no copies manualmente** la base de datos SQLite de Stash mientras el servicio está funcionando
- Stash usa SQLite en modo `WAL`, así que la copia consistente de la base debe hacerse desde la **tarea de Backup de la propia UI**
- una ruta razonable para guardar ese backup es `/metadata/backups`
- si quieres un único fichero de recuperación, puedes incluir `blobs` en el backup desde la UI, sabiendo que pesará más

La biblioteca de `/mnt/hd5t/stash/data` no forma parte del backup de la aplicación en sí; es el **contenido multimedia** y debe tratarse según la estrategia general de copias del homelab.

Secuencia práctica recomendada:

1. configurar en Stash el directorio de backup como `/metadata/backups`
2. ejecutar el backup desde **Settings -> Tasks**
3. respaldar además `config/` y, si no los incluyes en el backup UI, también `blobs/`

## Referencias

- Documentación oficial de Stash: https://docs.stashapp.cc
- Instalación oficial con Docker: https://docs.stashapp.cc/installation/docker/
- `docker-compose.yml` oficial de producción: https://github.com/stashapp/stash/blob/master/docker/production/docker-compose.yml
- Guía oficial de scraping: https://docs.stashapp.cc/beginner-guides/guide-to-scraping/
- Fuentes `stash-box` oficiales: https://docs.stashapp.cc/metadata-sources/stash-box-instances/
- Documentación oficial de scrapers: https://docs.stashapp.cc/metadata-sources/scrapers/
- Guía oficial de backup y restore: https://docs.stashapp.cc/guides/backup-and-restore-database/
- Imagen oficial Docker: https://hub.docker.com/r/stashapp/stash
