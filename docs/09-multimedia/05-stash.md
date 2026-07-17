# Stash

## Descripción

**Stash** es el organizador y reproductor multimedia del homelab para una biblioteca dedicada, con enfoque en **catalogación**, **metadatos**, **búsqueda avanzada**, **etiquetado** y **scraping**. En esta arquitectura se despliega como stack Docker propio, con los **datos operativos en el SSD NVMe** y la **biblioteca multimedia en `hd5t`**, que queda reservada exclusivamente para este servicio.

La política de almacenamiento de este proyecto se mantiene igual que en el resto de servicios:

- la configuración, la base de datos, los blobs, la metadata descargada, la caché y el contenido generado viven en `/home/<user>/homelab/data/stash/` sobre el **SSD NVMe**
- la biblioteca multimedia vive en `/media/hd5t/media/`
- el acceso principal en la **LAN** se hace preferentemente a través de **Caddy**
- el acceso remoto se hace por **Tailscale**, preferentemente a través de **Caddy**, sin abrir puertos en el router
- el puerto directo en host queda como opción operativa para bootstrap, diagnóstico o uso puntual sin proxy
- **Caddy** puede publicarlo por **HTTP en la LAN** y **HTTPS solo por Tailscale** según [05-caddy.md](../03-red/05-caddy.md)
- no hay exposición directa a internet ni port forwarding para este servicio

Stash encaja bien en este homelab porque separa claramente la **biblioteca real** del **estado operativo** del servicio. Eso permite dejar en el SSD NVMe lo sensible al rendimiento y a la consistencia del SQLite, mientras `hd5t` absorbe el crecimiento del catálogo multimedia.

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Tener Docker Engine y Docker Compose operativos según [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber fijado la convención de stacks y `.env` descrita en [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber desplegado [04-tailscale.md](../03-red/04-tailscale.md) si quieres acceso remoto seguro.
- Haber desplegado [05-caddy.md](../03-red/05-caddy.md) si quieres publicar Stash detrás del reverse proxy interno del homelab.
- Revisar [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) para registrar el puerto publicado por el servicio.
- Tener montado `hd5t` en `/media/hd5t`.
- Puertos necesarios:
  - `14004/tcp` publicado en el host; úsalo en `127.0.0.1` si Stash va detrás de Caddy o en `0.0.0.0` solo si quieres acceso directo desde LAN o Tailscale
  - `9999/tcp` como puerto interno del contenedor

## Docker Compose

Archivo: `/home/<user>/homelab/compose/media-stash/docker-compose.yml`

```yaml
name: media-stash

services:
  stash:
    image: stashapp/stash:v0.31.1
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
      - /media/hd5t/media:/data:ro
      - /home/<user>/homelab/data/stash/metadata:/metadata
      - /home/<user>/homelab/data/stash/cache:/cache
      - /home/<user>/homelab/data/stash/blobs:/blobs
      - /home/<user>/homelab/data/stash/generated:/generated
    networks:
      - default
      - proxy
    logging:
      driver: json-file
      options:
        max-file: "10"
        max-size: "2m"
    labels:
      - wud.watch=true

networks:
  proxy:
    external: true
    name: homelab_proxy
```

Notas sobre este Compose:

- el stack queda aislado bajo `media-stash`
- la biblioteca vive en `hd5t`
- la configuración, la base de datos, blobs, caché, scrapers, plugins y contenido generado viven en el **SSD NVMe**
- la biblioteca se monta en modo lectura para un despliegue base más seguro
- el servicio publica `14004/tcp` en el host y **Caddy**, al usar `network_mode: host`, debe alcanzarlo por `127.0.0.1:14004`
- el Compose sigue el esquema oficial de Stash para `config`, `metadata`, `cache`, `blobs` y `generated`
- el stack se une a `homelab_proxy` para que otros servicios Docker (como Uptime Kuma) puedan alcanzar Stash por nombre de contenedor en el puerto interno `9999`

Si más adelante quieres usar funciones de **organización, renombrado o movimiento de archivos desde Stash**, tendrás que quitar `:ro` del bind mount `/media/hd5t/media:/data:ro` y validar muy bien esa política antes de activarla en producción.

## Configuración

### 1. Preparar directorios del stack y de la biblioteca

```bash
mkdir -p /home/<user>/homelab/compose/media-stash
mkdir -p /home/<user>/homelab/data/stash/{config,metadata,cache,blobs,generated}
sudo mkdir -p /media/hd5t/media/{scenes,galleries,incoming}
```

Una organización razonable de la biblioteca puede ser:

```bash
sudo mkdir -p /media/hd5t/media/scenes/{studio,clips,movies}
sudo mkdir -p /media/hd5t/media/galleries/{sets,photos}
```

No es obligatorio seguir ese esquema exacto, pero sí conviene mantener raíces estables para que los escaneos, filtros y scrapers sean predecibles.

### 2. Ajustar propiedad y permisos

Usa el mismo usuario operativo del host que administra Docker y las carpetas del homelab:

```bash
id <user>
sudo chown -R <user>:<user> /home/<user>/homelab/data/stash
sudo chown -R <user>:<user> /media/hd5t/media

sudo find /home/<user>/homelab/data/stash -type d -exec chmod 775 {} \;
sudo find /home/<user>/homelab/data/stash -type f -exec chmod 664 {} \;
sudo find /media/hd5t/media -type d -exec chmod 755 {} \;
sudo find /media/hd5t/media -type f -exec chmod 644 {} \;
```

La lógica base es:

- Stash necesita escritura en `config/`, `metadata/`, `cache/`, `blobs/` y `generated/`
- la biblioteca multimedia no necesita escritura desde el contenedor en el despliegue recomendado

La imagen oficial de Stash suele ejecutarse con el usuario por defecto del contenedor. Este documento mantiene el Compose cercano al ejemplo oficial y evita forzar `PUID` o `PGID` sin haber validado antes ese cambio con la versión concreta que estés usando.

### 3. Crear el fichero `.env`

Archivo: `/home/<user>/homelab/compose/media-stash/.env`

```dotenv
TZ=Europe/Madrid
STASH_BIND_IP=127.0.0.1
STASH_HTTP_PORT=14004
STASH_PORT=9999
```

Notas prácticas:

- `STASH_BIND_IP=127.0.0.1` es el valor recomendado para el acceso dual con **Caddy** por delante: el puerto queda expuesto solo en loopback y el acceso desde LAN y Tailscale entra únicamente a través de Caddy
- `STASH_BIND_IP=0.0.0.0` deja el servicio accesible por acceso directo desde la LAN y también desde la IP Tailscale del host; úsalo solo si esa excepción te interesa de forma consciente
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

Si además quieres validar el acceso detrás de **Caddy** (acceso dual), añade estas comprobaciones:

```bash
curl -I -H 'Host: stash.lan' http://127.0.0.1
curl -I https://pi-homelab.<tailnet>.ts.net/stash
```

No elimines `ports:` si vas a publicar Stash detrás de **Caddy** con la arquitectura actual del repositorio. Como **Caddy** usa `network_mode: host`, necesita un upstream estable en el host, normalmente `127.0.0.1:14004`.

Si todo ha arrancado bien, la interfaz quedará disponible por acceso directo en:

- `http://127.0.0.1:14004` desde la propia Raspberry Pi si usas `STASH_BIND_IP=127.0.0.1`
- `http://IP_DE_LA_PI:14004` y `http://pi-homelab.<tailnet>.ts.net:14004` solo si usas `STASH_BIND_IP=0.0.0.0`

Si prefieres el patrón recomendado del homelab, con Caddy por delante (acceso dual):

- `http://stash.lan` desde la LAN
- `https://pi-homelab.<tailnet>.ts.net/stash` desde Tailscale
- la configuración concreta de ambos bloques de Caddy se detalla más abajo

Publicación detrás de **Caddy** — acceso dual LAN + Tailscale:

Stash se puede publicar simultáneamente por **hostname dedicado en la LAN** y por **subruta compartida en Tailscale**. Ambos bloques de Caddy son independientes y no entran en conflicto: Caddy evalúa cada petición por hostname y protocolo de forma separada.

- **LAN**: `http://stash.lan` — hostname dedicado, patrón más simple y el que mejor tolera Stash (sin depender de reescrituras de ruta ni de `X-Forwarded-Prefix`).
- **Tailscale**: `https://pi-homelab.<tailnet>.ts.net/stash` — subruta compartida dentro del hostname HTTPS del nodo. Stash soporta publicación bajo prefijo de URL siempre que el proxy elimine el prefijo antes de reenviar la petición al backend y añada la cabecera `X-Forwarded-Prefix` con ese mismo valor. En Caddy, `handle_path /stash/*` se encarga de ambas cosas.

Configuración de Caddy para acceso dual:

```caddyfile
http://stash.lan {
    import common_proxy
    reverse_proxy 127.0.0.1:14004
}
```

```caddyfile
https://{$TAILSCALE_DOMAIN} {
    # ... bloques existentes de otros servicios ...

    redir /stash /stash/ permanent

    handle_path /stash/* {
        reverse_proxy 127.0.0.1:14004 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-Port {server_port}
            header_up X-Forwarded-Prefix /stash
        }
    }
}
```

Notas sobre `external_host` en acceso dual:

- Stash tiene un parámetro `external_host` que solo acepta **un valor**. Stash lo usa para generar URLs absolutas, gestionar redirects tras login y construir URLs de websockets.
- Con acceso dual, la opción más compatible es **dejar `external_host` vacío** (no definirlo). Cuando `external_host` no está definido, Stash usa la URL de la petición entrante para construir sus respuestas, lo que permite que ambas rutas de acceso funcionen correctamente siempre que `X-Forwarded-Prefix` esté bien configurado en la subruta de Tailscale.
- Si defines `external_host` con una de las dos URLs, la otra puede recibir redirects o URLs absolutas que apunten al host equivocado. Ejemplo: si fijas `external_host: http://stash.lan`, un acceso remoto por Tailscale podría recibir un redirect hacia `stash.lan`, que es inalcanzable fuera de la LAN.
- Tras el despliegue, valida siempre el login, la navegación, la reproducción y la carga de recursos estáticos desde **ambas rutas** antes de dar la configuración por buena.

El acceso directo por puerto es válido para administración o pruebas, pero no sustituye la política general del proyecto: **sin exposición WAN y sin abrir puertos en el router**.

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
- metadata persistente y directorio razonable para backups: `/metadata`
- caché operativa: `/cache`
- blobs binarios: `/blobs`
- contenido generado: `/generated`

Ruta recomendada para este homelab:

- trata `config/` y `metadata/` como estado persistente crítico del servicio y mantenlos siempre en el **SSD NVMe**
- usa `/metadata/backups` como directorio de backup desde la UI
- antes de dar por cerrada una instalación nueva o una migración, comprueba siempre en **Settings -> System -> Database path** la ruta efectiva de la base SQLite y verifica que apunta a un volumen persistente del SSD
- si en una instalación ya existente la base está en una ruta distinta de la esperada, no la muevas por homogeneidad sin validar antes el procedimiento de restauración

<!-- TODO: verificar en una instancia real del stack qué ruta concreta muestra Stash en `Settings -> System -> Database path` con este Compose antes de documentarla como valor por defecto fijo. -->

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
- Metadata persistente, export/import y backups: `/home/<user>/homelab/data/stash/metadata`
- Caché: `/home/<user>/homelab/data/stash/cache`
- Blobs binarios: `/home/<user>/homelab/data/stash/blobs`
- Contenido generado: `/home/<user>/homelab/data/stash/generated`
- Biblioteca multimedia: `/media/hd5t/media`

Criterio de almacenamiento:

- todo lo operativo de Stash vive en el **SSD NVMe**
- `hd5t` almacena exclusivamente la biblioteca multimedia de Stash
- no se guarda la base de datos ni el contenido generado en el disco USB
- la ruta efectiva de la base SQLite debe verificarse en **Settings -> System -> Database path** antes de cerrar una migración o una restauración
- los scrapers manuales y plugins quedan bajo `config/`, por lo que también forman parte del estado persistente del servicio
- `metadata/` debe conservarse como volumen persistente porque Stash lo usa para metadata de la aplicación, exportaciones y backups

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
- verifica en **Settings -> System -> Database path** dónde está realmente la base SQLite antes de dar por buena una política de restore
- Stash usa SQLite en modo `WAL`, así que la copia consistente de la base debe hacerse desde la **tarea de Backup de la propia UI**
- una ruta razonable para guardar ese backup es `/metadata/backups`
- si quieres un único fichero de recuperación, puedes incluir `blobs` en el backup desde la UI, sabiendo que pesará más

La biblioteca de `/media/hd5t/media` no forma parte del backup de la aplicación en sí; es el **contenido multimedia** y debe tratarse según la estrategia general de copias del homelab.

Secuencia práctica recomendada:

1. configurar en Stash el directorio de backup como `/metadata/backups`
2. ejecutar el backup desde **Settings -> Tasks**
3. respaldar además `config/`, `metadata/` y, si no los incluyes en el backup UI, también `blobs/`

## Referencias

- Documentación oficial de Stash: https://docs.stashapp.cc
- Instalación oficial con Docker: https://docs.stashapp.cc/installation/docker/
- `docker-compose.yml` oficial de producción: https://github.com/stashapp/stash/blob/master/docker/production/docker-compose.yml
- Guía oficial de scraping: https://docs.stashapp.cc/beginner-guides/guide-to-scraping/
- Fuentes `stash-box` oficiales: https://docs.stashapp.cc/metadata-sources/stash-box-instances/
- Documentación oficial de scrapers: https://docs.stashapp.cc/metadata-sources/scrapers/
- Guía oficial de reverse proxy: https://docs.stashapp.cc/guides/reverse-proxy/
- Opciones avanzadas de configuración (`external_host`): https://docs.stashapp.cc/guides/advanced-configuration-options/
- Guía oficial de backup y restore: https://docs.stashapp.cc/guides/backup-and-restore-database/
- Imagen oficial Docker: https://hub.docker.com/r/stashapp/stash
