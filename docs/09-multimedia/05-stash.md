# Stash

## Descripción
**Stash** será el catalogador y servidor web para la colección multimedia dedicada almacenada en `hd5t`, con indexación de escenas, imágenes y galerías, metadatos enriquecidos mediante scrapers y acceso desde navegador dentro de la LAN o a través de Tailscale.

En esta arquitectura se despliega sobre la **Raspberry Pi 5** con estas reglas:

- el servicio y su estado persistente viven en el **SSD NVMe**
- la biblioteca principal vive en **`/mnt/hd5t/stash/library`**
- el acceso web local se publica detrás de **Caddy** con `https://stash.lan`
- el acceso remoto sigue siendo **solo Tailscale**, sin abrir puertos en el router
- los ficheros originales del disco USB se tratan como colección maestra y se montan en **solo lectura**

Stash encaja en este homelab porque permite separar claramente la biblioteca fría de `hd5t` del estado sensible a escritura frecuente del servicio, como la configuración, la base de datos, los blobs, la caché y el contenido generado, que conviene mantener en el NVMe.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md` para publicar `stash.lan`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres acceso remoto por VPN mesh.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `stash.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Tener montado `hd5t` en `/mnt/hd5t`.
- Tener espacio suficiente en el SSD NVMe para:
  - configuración persistente del servicio
  - base de datos SQLite del servicio
  - caché temporal
  - blobs binarios como portadas e imágenes descargadas
  - contenido generado como previews, sprites y transcodes
- Poder usar `sudo` con el usuario administrador del homelab.
- Puertos implicados en esta fase:
  - `9999/tcp` solo dentro de Docker entre Caddy y el contenedor `stash`
  - `80/tcp` y `443/tcp` ya publicados por Caddy en el host
  - no se abre ningún puerto entrante en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/stash/
├── compose.yaml
└── .env
```

Preparación inicial de rutas:

```bash
mkdir -p /home/<usuario>/homelab/compose/stash
mkdir -p /home/<usuario>/homelab/data/stash/{config,metadata,cache,blobs,generated}
mkdir -p /mnt/hd5t/stash/library/{videos,images,galleries}
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

STASH_IMAGE=stashapp/stash:latest

STASH_CONFIG_DIR=/home/<usuario>/homelab/data/stash/config
STASH_METADATA_DIR=/home/<usuario>/homelab/data/stash/metadata
STASH_CACHE_DIR=/home/<usuario>/homelab/data/stash/cache
STASH_BLOBS_DIR=/home/<usuario>/homelab/data/stash/blobs
STASH_GENERATED_DIR=/home/<usuario>/homelab/data/stash/generated

STASH_LIBRARY_DIR=/mnt/hd5t/stash/library
```

Notas sobre estas variables:

- `latest` sigue la última release estable publicada por el proyecto. Si quieres máxima reproducibilidad, fija una etiqueta concreta.
- `STASH_CONFIG_DIR` se guarda en el NVMe porque contiene `config.yml`, plugins, scrapers y el estado principal del servicio.
- `STASH_METADATA_DIR`, `STASH_CACHE_DIR`, `STASH_BLOBS_DIR` y `STASH_GENERATED_DIR` también se colocan en el NVMe para evitar castigar `hd5t` con escrituras pequeñas y frecuentes.
- `STASH_LIBRARY_DIR` apunta al disco dedicado `hd5t`, reservado para la colección principal de Stash.

Fichero `compose.yaml`:

```yaml
name: stash

services:
  stash:
    container_name: stash
    image: ${STASH_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      STASH_STASH: /data/
      STASH_GENERATED: /generated/
      STASH_METADATA: /metadata/
      STASH_CACHE: /cache/
      STASH_PORT: 9999
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ${STASH_CONFIG_DIR}:/root/.stash
      - ${STASH_METADATA_DIR}:/metadata
      - ${STASH_CACHE_DIR}:/cache
      - ${STASH_BLOBS_DIR}:/blobs
      - ${STASH_GENERATED_DIR}:/generated
      - type: bind
        source: ${STASH_LIBRARY_DIR}
        target: /data
        read_only: true
    networks:
      - default
      - homelab_proxy
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  homelab_proxy:
    external: true
    name: homelab_proxy
```

Notas operativas sobre este stack:

- no se publica `9999` en el host porque el punto de entrada recomendado es **Caddy**
- la biblioteca de `hd5t` se monta en solo lectura para proteger el contenido original
- Stash usa SQLite y conviene tratar la base de datos como estado operativo que vive en el NVMe
- `/generated` y `/cache` deben quedar en almacenamiento rápido porque soportan previews, sprites, streaming temporal y otras tareas intensivas en escritura
- la imagen oficial funciona en ARM64, por lo que encaja en Raspberry Pi 5 sin depender de una base de datos externa

Despliegue inicial:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/stash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/stash
sudo chown -R <usuario>:<usuario> /mnt/hd5t/stash

cd /home/<usuario>/homelab/compose/stash
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f stash
```

Resultado esperado:

- el contenedor `stash` queda levantado
- Stash escucha internamente en `http://stash:9999`
- se crea la estructura persistente en `/home/<usuario>/homelab/data/stash/`
- la biblioteca de `hd5t` queda visible desde el contenedor en `/data`
- Caddy puede publicar el servicio como `https://stash.lan`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `https://stash.lan` |
| Persistencia | `/home/<usuario>/homelab/data/stash/` |
| Biblioteca principal | `/mnt/hd5t/stash/library/` |
| Punto de entrada LAN | Caddy |
| Acceso remoto | Tailscale |
| Scrapers | configurados solo para las fuentes que realmente uses |
| Tipo de almacenamiento binario | `Filesystem` sobre NVMe |

### 1. Preparar rutas y permisos

Crear la estructura base:

```bash
mkdir -p /home/<usuario>/homelab/compose/stash
mkdir -p /home/<usuario>/homelab/data/stash/{config,metadata,cache,blobs,generated}
mkdir -p /mnt/hd5t/stash/library/{videos,images,galleries}
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/stash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/stash
sudo chown -R <usuario>:<usuario> /mnt/hd5t/stash

chmod 755 /home/<usuario>/homelab/data/stash
chmod 750 /home/<usuario>/homelab/data/stash/config
chmod 750 /home/<usuario>/homelab/data/stash/metadata
chmod 750 /home/<usuario>/homelab/data/stash/cache
chmod 750 /home/<usuario>/homelab/data/stash/blobs
chmod 750 /home/<usuario>/homelab/data/stash/generated
chmod 755 /mnt/hd5t/stash
chmod 755 /mnt/hd5t/stash/library
```

La clave para que Stash funcione bien es separar correctamente:

- la colección original en `hd5t`
- los metadatos internos y blobs en el NVMe
- el contenido generado y temporal en el NVMe

Si `hd5t` viene de otro sistema de ficheros o se monta con un propietario distinto, corrige antes permisos y ACL. El problema más habitual en Stash no suele ser Docker, sino que el contenedor no pueda recorrer correctamente la biblioteca o que acabe escribiendo ficheros donde no debe.

### 2. Arrancar el servicio y completar el primer acceso

Levantar el stack:

```bash
cd /home/<usuario>/homelab/compose/stash
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f stash
docker exec stash ls -lah /data
docker exec stash ls -lah /metadata
docker exec stash ls -lah /generated
docker exec stash ls -lah /cache
docker exec stash ls -lah /root/.stash
```

Después, abrir:

```text
https://stash.lan
```

En el primer arranque:

1. Crear inmediatamente usuario y contraseña si todavía no están definidos.
2. Confirmar idioma, zona horaria y comportamiento general del servidor.
3. Revisar `Settings > System` antes de empezar a escanear bibliotecas.
4. Configurar las rutas operativas sobre el NVMe.
5. Añadir bibliotecas y lanzar el primer escaneo.

Stash no activa autenticación por defecto. En este homelab, aunque el acceso sea solo LAN + Tailscale, no conviene dejar la instancia abierta sin credenciales.

### 3. Configurar rutas internas del servicio

Nada más terminar el primer arranque, revisa en `Settings > System`:

| Ajuste de Stash | Valor recomendado |
|---|---|
| Library directories | `/data/videos`, `/data/images`, `/data/galleries` según corresponda |
| Cache path | `/cache` |
| Generated path | `/generated` |
| Metadata path | `/metadata` |
| Backup directory path | `/metadata/backups` |
| Binary data storage type | `Filesystem` |
| Binary data path | `/blobs` |

Notas prácticas:

- el `Backup directory path` se deja dentro de `metadata` para que las copias creadas desde la UI también queden en el NVMe
- el tipo `Filesystem` para blobs evita inflar innecesariamente la base de datos
- si en el futuro usas HLS o DASH para streaming, `Cache path` debe estar configurado y apuntar a almacenamiento rápido

### 4. Configurar las bibliotecas de `hd5t`

Ruta base esperada en el host:

```text
/mnt/hd5t/stash/library/
```

Estructura sugerida:

```text
/mnt/hd5t/stash/library/
├── videos/
│   ├── Studio A/
│   └── Studio B/
├── images/
│   ├── Set 01/
│   └── Set 02/
└── galleries/
    ├── Gallery 01/
    └── Gallery 02/
```

Bibliotecas sugeridas para este homelab:

| Biblioteca Stash | Ruta dentro del contenedor | Tipo sugerido |
|---|---|---|
| Vídeos | `/data/videos` | Videos |
| Imágenes | `/data/images` | Images |
| Galerías | `/data/galleries` | Images o Both según tu organización |

Buenas prácticas para que el escaneo sea estable:

- no mezcles descargas temporales con la colección definitiva
- usa carpetas consistentes por estudio, set o colección
- evita nombres caóticos o cambios frecuentes de ruta una vez indexado el contenido
- deja la biblioteca en solo lectura y guarda toda la actividad derivada en `generated`, `metadata`, `blobs` y `cache`

### 5. Scrapers de metadatos

Stash permite enriquecer la colección con scrapers y paquetes de metadatos. Para este homelab, el enfoque recomendado es conservador:

1. Actualizar solo los scrapers o paquetes que realmente vayas a usar.
2. Probar primero con una biblioteca pequeña antes de lanzar scraping masivo.
3. Mantener la colección original en `hd5t` sin escrituras directas desde el servicio.
4. Guardar los resultados derivados en el NVMe.

Recomendaciones prácticas:

- empieza con unas pocas escenas o galerías para validar coincidencias y calidad de metadatos
- revisa idioma, país o reglas de scraping antes de procesar toda la colección
- si un scraper requiere navegador automatizado, deja `Chrome CDP path` vacío hasta que despliegues explícitamente una instancia compatible
- evita habilitar scrapers innecesarios para no aumentar tráfico, tiempo de escaneo y ruido en los resultados

También conviene revisar:

1. **Settings > System > Scraping** para ajustar el `User-Agent` si alguna fuente lo necesita.
2. **Settings > Tasks** para lanzar scraping manual o en lotes de forma controlada.
3. **Logs** para detectar fallos de autenticación, rate limits o scrapers rotos.

### 6. Ajustes recomendados para Raspberry Pi 5

Stash puede generar previews, sprites y transcodes, pero en una Raspberry Pi 5 conviene priorizar estabilidad sobre agresividad:

- usa pocos trabajos paralelos durante escaneo y generación
- programa el primer escaneo grande en horas de baja actividad
- mantén `generated` y `cache` en el NVMe
- no bases el diseño del servicio en transcodificación en tiempo real

Si la biblioteca es grande, empieza por:

1. escanear solo una parte del árbol
2. validar tiempos y consumo de CPU
3. ajustar número de tareas paralelas
4. lanzar después el escaneo completo

### 7. Integración con Caddy

La integración esperada con `docs/03-red/04-caddy.md` es el bloque:

```caddyfile
stash.lan {
  import common
  tls internal
  reverse_proxy stash:9999 {
    header_up Host {host}
    header_up X-Real-IP {remote_host}
    header_up X-Forwarded-For {remote_host}
    header_up X-Forwarded-Proto {scheme}
    header_up X-Forwarded-Port {server_port}
  }
}
```

Después de levantar ambos stacks:

```bash
docker network inspect homelab_proxy
docker compose -f /home/<usuario>/homelab/compose/caddy/compose.yaml ps
docker compose -f /home/<usuario>/homelab/compose/stash/compose.yaml ps
```

Validaciones:

- `stash` y `caddy` deben estar en `homelab_proxy`
- `https://stash.lan` debe responder con la pantalla inicial o el login
- el certificado será el de la CA interna de Caddy para la LAN
- el login, navegación y reproducción básica deben funcionar detrás del proxy

Si observas enlaces absolutos incorrectos o comportamiento extraño con una URL fija, revisa `config.yml` y estandariza un único `external_host` canónico.

### 8. Tailscale y acceso remoto

El patrón recomendado para simplicidad operativa es:

- usar `https://stash.lan` dentro de la LAN
- entrar por Tailscale cuando estés fuera de casa
- exponer Stash en una subruta remota si ya estás consolidando servicios bajo el endpoint Tailscale de Caddy

La subruta razonable para este servicio es:

```text
/stash
```

Por tanto, la integración remota con el bloque de `docs/03-red/04-caddy.md` es:

```caddyfile
handle_path /stash/* {
  reverse_proxy stash:9999 {
    header_up Host {host}
    header_up X-Real-IP {remote_host}
    header_up X-Forwarded-For {remote_host}
    header_up X-Forwarded-Proto {scheme}
    header_up X-Forwarded-Port {server_port}
    header_up X-Forwarded-Prefix /stash
  }
}
```

Si vas a usar esta subruta como URL remota estable, deja también fijado un `external_host` coherente en `config.yml`, por ejemplo:

```yaml
external_host: https://pi.tailnet.ts.net/stash
```

Esto reduce problemas con enlaces absolutos, redirecciones y generación de URLs cuando Stash queda detrás de un prefijo.

Antes de darlo por válido, prueba:

- login desde navegador en LAN
- escaneo básico de una carpeta pequeña
- carga de portadas y vistas previas
- acceso desde un dispositivo conectado por Tailscale usando `https://pi.tailnet.ts.net/stash/`

## Almacenamiento

Distribución de datos recomendada:

| Tipo de dato | Ruta |
|---|---|
| Compose del servicio | `/home/<usuario>/homelab/compose/stash/` |
| Configuración y estado principal | `/home/<usuario>/homelab/data/stash/config/` |
| Metadatos de aplicación | `/home/<usuario>/homelab/data/stash/metadata/` |
| Caché temporal | `/home/<usuario>/homelab/data/stash/cache/` |
| Blobs binarios | `/home/<usuario>/homelab/data/stash/blobs/` |
| Contenido generado | `/home/<usuario>/homelab/data/stash/generated/` |
| Biblioteca principal | `/mnt/hd5t/stash/library/` |

Criterios de esta distribución:

- el **NVMe** absorbe todas las escrituras frecuentes del servicio
- `hd5t` almacena únicamente la colección principal de Stash
- la biblioteca se monta como `read_only` para proteger el contenido original
- el servicio queda desacoplado de la colección: puedes regenerar previews, restaurar configuración o rehacer scraping sin mover los ficheros del disco USB

Qué guarda Stash habitualmente en el NVMe:

- `config.yml`, credenciales, plugins y scrapers
- base de datos SQLite del servicio
- blobs binarios como portadas e imágenes auxiliares
- previews, sprites, transcodes y otros derivados
- caché temporal y backups creados desde la UI

Qué guarda `hd5t` en este diseño:

- vídeos
- imágenes
- galerías
- estructura de carpetas de la colección principal

## Backup

Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/stash/`
- `/home/<usuario>/homelab/data/stash/config/`
- `/home/<usuario>/homelab/data/stash/metadata/`
- `/home/<usuario>/homelab/data/stash/blobs/`
- `/home/<usuario>/homelab/data/stash/generated/`

Respaldar de forma opcional según tu estrategia:

- `/home/<usuario>/homelab/data/stash/cache/` si quieres preservar también caché temporal
- `/mnt/hd5t/stash/library/` si `hd5t` no es ya la copia maestra de tu colección

Recomendación práctica:

- usa la tarea de **Backup** desde la UI de Stash para respaldar la base de datos
- no copies manualmente el fichero SQLite mientras Stash está en ejecución
- si quieres un backup autocontenido, valora incluir también blobs en la tarea de backup
- trata `config`, `metadata`, `blobs` y `generated` como **obligatorios**

Antes de un backup importante o una actualización mayor:

1. Ejecuta un backup desde `Settings > Tasks > Backup`.
2. Verifica que el fichero se ha creado en `/metadata/backups`.
3. Detén el contenedor si además vas a copiar directorios completos del estado del servicio.

Parada controlada:

```bash
cd /home/<usuario>/homelab/compose/stash
docker compose stop stash
```

Después de copiar los directorios necesarios, volver a arrancar:

```bash
docker compose up -d
```

Si restauras una base de datos, revisa también dónde apunta el almacenamiento binario. Si el tipo de blobs era `Filesystem`, debes conservar o restaurar igualmente el contenido de `/blobs`.

## Referencias
- Documentación oficial de Stash: `https://docs.stashapp.cc/`
- Instalación en Docker: `https://docs.stashapp.cc/installation/docker/`
- Guía de reverse proxy: `https://docs.stashapp.cc/guides/reverse-proxy/`
- Guía oficial de backup y restore: `https://docs.stashapp.cc/guides/backup-and-restore-database/`
- Manual de configuración: `https://docs.stashapp.cc/in-app-manual/configuration/`
- Repositorio oficial: `https://github.com/stashapp/stash`
- Imagen oficial Docker Hub: `https://hub.docker.com/r/stashapp/stash`
