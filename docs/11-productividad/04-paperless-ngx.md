# Paperless-ngx

## Descripción
**Paperless-ngx** será el gestor documental del homelab para escanear, importar, clasificar, etiquetar y buscar documentos privados desde una interfaz web ligera.

En esta arquitectura se despliega con estas reglas:

- la aplicación, la base de datos, Redis, los datos persistentes y la carpeta de consumo viven en el **SSD NVMe**
- el acceso web local se publica detrás de **Caddy** con `https://paperless.lan`
- la conexión va siempre por **HTTPS** con la **CA interna de Caddy**
- el acceso remoto sigue siendo **solo LAN + Tailscale**, sin abrir puertos en el router
- la persistencia usa **PostgreSQL** para la base de datos y **Redis** como broker interno
- se habilitan **Tika** y **Gotenberg** para soportar OCR y consumo de documentos Office, correos y otros formatos convertibles

Paperless-ngx encaja bien en este homelab porque centraliza documentos personales y administrativos, automatiza el OCR, permite etiquetado y clasificación desde el navegador y mantiene una carpeta `consume/` sencilla para ingesta automática desde escáner, SMB o sincronización local.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres consultar documentos también desde fuera de la LAN mediante VPN.
- Haber completado `docs/07-backups/01-estrategia-backup.md`.
- Haber completado `docs/07-backups/03-backup-docker-volumes.md`.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `paperless.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Tener importada en los navegadores y dispositivos cliente la CA local de Caddy desde:
  - `/home/<usuario>/homelab/compose/caddy/data/caddy/pki/authorities/local/root.crt`
- Poder usar `sudo` con el usuario administrador del homelab.
- Puertos implicados en esta fase:
  - `8000/tcp` solo dentro de Docker entre Caddy y el contenedor `paperless-webserver`
  - `5432/tcp` solo dentro de la red Docker entre `paperless-webserver` y `paperless-db`
  - `6379/tcp` solo dentro de la red Docker entre `paperless-webserver` y `paperless-redis`
  - `3000/tcp` solo dentro de la red Docker entre `paperless-webserver` y `paperless-gotenberg`
  - `9998/tcp` solo dentro de la red Docker entre `paperless-webserver` y `paperless-tika`
  - `443/tcp` ya publicado por Caddy en el host
  - no se abre ningún puerto entrante en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/paperless-ngx/
├── compose.yaml
└── .env
```

Preparación inicial:

```bash
mkdir -p /home/<usuario>/homelab/compose/paperless-ngx
mkdir -p /home/<usuario>/homelab/data/paperless-ngx/{data,media,export,consume,postgres,redis}
```

Identificar `PUID` y `PGID` del usuario administrador:

```bash
id -u <usuario>
id -g <usuario>
```

Generar una clave secreta larga para Paperless-ngx:

```bash
openssl rand -hex 32
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000

PAPERLESS_IMAGE=ghcr.io/paperless-ngx/paperless-ngx:latest
POSTGRES_IMAGE=postgres:18
REDIS_IMAGE=redis:8
GOTENBERG_IMAGE=gotenberg/gotenberg:8.25
TIKA_IMAGE=apache/tika:latest

PAPERLESS_URL=https://paperless.lan
PAPERLESS_SECRET_KEY=<clave-larga-generada-con-openssl>
PAPERLESS_TIME_ZONE=Europe/Madrid

PAPERLESS_DBHOST=paperless-db
PAPERLESS_DBPORT=5432
PAPERLESS_DBNAME=paperless
PAPERLESS_DBUSER=paperless
PAPERLESS_DBPASS=<password-larga-bd>

PAPERLESS_REDIS=redis://paperless-redis:6379

PAPERLESS_OCR_LANGUAGE=spa+eng
PAPERLESS_OCR_MODE=skip
PAPERLESS_OCR_OUTPUT_TYPE=pdfa

PAPERLESS_TASK_WORKERS=2
PAPERLESS_THREADS_PER_WORKER=2

PAPERLESS_CONSUMER_RECURSIVE=true
PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS=true
PAPERLESS_CONSUMER_POLLING=0

PAPERLESS_TIKA_ENABLED=1
PAPERLESS_TIKA_ENDPOINT=http://paperless-tika:9998
PAPERLESS_TIKA_GOTENBERG_ENDPOINT=http://paperless-gotenberg:3000

PAPERLESS_DATA_DIR=/home/<usuario>/homelab/data/paperless-ngx/data
PAPERLESS_MEDIA_DIR=/home/<usuario>/homelab/data/paperless-ngx/media
PAPERLESS_EXPORT_DIR=/home/<usuario>/homelab/data/paperless-ngx/export
PAPERLESS_CONSUME_DIR=/home/<usuario>/homelab/data/paperless-ngx/consume
PAPERLESS_POSTGRES_DIR=/home/<usuario>/homelab/data/paperless-ngx/postgres
PAPERLESS_REDIS_DIR=/home/<usuario>/homelab/data/paperless-ngx/redis
```

Notas sobre estas variables:

- `PAPERLESS_URL` debe coincidir exactamente con la URL publicada por Caddy.
- `PAPERLESS_SECRET_KEY` es obligatoria y conviene conservarla igual durante toda la vida del servicio.
- `PAPERLESS_OCR_LANGUAGE=spa+eng` encaja bien si esperas documentos en español e inglés. Si casi todo está en español, `spa` consumirá menos CPU.
- `PAPERLESS_OCR_MODE=skip` es la opción más segura para un homelab: solo hace OCR donde no hay texto útil.
- `PAPERLESS_OCR_OUTPUT_TYPE=pdfa` favorece archivado a largo plazo y Paperless conserva también el fichero original.
- `PAPERLESS_TASK_WORKERS=2` y `PAPERLESS_THREADS_PER_WORKER=2` son un punto de partida razonable para una **Raspberry Pi 5**; si observas saturación, reduce uno de los dos valores.
- `PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS=true` permite convertir la estructura de subcarpetas dentro de `consume/` en etiquetas automáticas.
- `PAPERLESS_CONSUMER_POLLING=0` mantiene el comportamiento por `inotify`. Si en el futuro llenas `consume/` desde un montaje de red que no propague eventos bien, súbelo por ejemplo a `60`.
- `PAPERLESS_TIKA_ENABLED`, `PAPERLESS_TIKA_ENDPOINT` y `PAPERLESS_TIKA_GOTENBERG_ENDPOINT` habilitan soporte para documentos Office y `.eml`.

Fichero `compose.yaml`:

```yaml
name: paperless-ngx

services:
  paperless-redis:
    container_name: paperless-redis
    image: ${REDIS_IMAGE}
    restart: unless-stopped
    volumes:
      - ${PAPERLESS_REDIS_DIR}:/data
    networks:
      - default
    security_opt:
      - no-new-privileges:true

  paperless-db:
    container_name: paperless-db
    image: ${POSTGRES_IMAGE}
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${PAPERLESS_DBNAME}
      POSTGRES_USER: ${PAPERLESS_DBUSER}
      POSTGRES_PASSWORD: ${PAPERLESS_DBPASS}
    volumes:
      - ${PAPERLESS_POSTGRES_DIR}:/var/lib/postgresql/data
    networks:
      - default
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${PAPERLESS_DBUSER} -d ${PAPERLESS_DBNAME}"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
    security_opt:
      - no-new-privileges:true

  paperless-gotenberg:
    container_name: paperless-gotenberg
    image: ${GOTENBERG_IMAGE}
    restart: unless-stopped
    command:
      - gotenberg
      - --chromium-disable-javascript=true
      - --chromium-allow-list=file:///tmp/.*
    networks:
      - default
    security_opt:
      - no-new-privileges:true

  paperless-tika:
    container_name: paperless-tika
    image: ${TIKA_IMAGE}
    restart: unless-stopped
    networks:
      - default
    security_opt:
      - no-new-privileges:true

  paperless-webserver:
    container_name: paperless-webserver
    image: ${PAPERLESS_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      USERMAP_UID: ${PUID}
      USERMAP_GID: ${PGID}
      PAPERLESS_REDIS: ${PAPERLESS_REDIS}
      PAPERLESS_DBHOST: ${PAPERLESS_DBHOST}
      PAPERLESS_DBPORT: ${PAPERLESS_DBPORT}
      PAPERLESS_DBNAME: ${PAPERLESS_DBNAME}
      PAPERLESS_DBUSER: ${PAPERLESS_DBUSER}
      PAPERLESS_DBPASS: ${PAPERLESS_DBPASS}
      PAPERLESS_URL: ${PAPERLESS_URL}
      PAPERLESS_SECRET_KEY: ${PAPERLESS_SECRET_KEY}
      PAPERLESS_TIME_ZONE: ${PAPERLESS_TIME_ZONE}
      PAPERLESS_OCR_LANGUAGE: ${PAPERLESS_OCR_LANGUAGE}
      PAPERLESS_OCR_MODE: ${PAPERLESS_OCR_MODE}
      PAPERLESS_OCR_OUTPUT_TYPE: ${PAPERLESS_OCR_OUTPUT_TYPE}
      PAPERLESS_TASK_WORKERS: ${PAPERLESS_TASK_WORKERS}
      PAPERLESS_THREADS_PER_WORKER: ${PAPERLESS_THREADS_PER_WORKER}
      PAPERLESS_CONSUMER_RECURSIVE: ${PAPERLESS_CONSUMER_RECURSIVE}
      PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS: ${PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS}
      PAPERLESS_CONSUMER_POLLING: ${PAPERLESS_CONSUMER_POLLING}
      PAPERLESS_TIKA_ENABLED: ${PAPERLESS_TIKA_ENABLED}
      PAPERLESS_TIKA_ENDPOINT: ${PAPERLESS_TIKA_ENDPOINT}
      PAPERLESS_TIKA_GOTENBERG_ENDPOINT: ${PAPERLESS_TIKA_GOTENBERG_ENDPOINT}
    volumes:
      - ${PAPERLESS_DATA_DIR}:/usr/src/paperless/data
      - ${PAPERLESS_MEDIA_DIR}:/usr/src/paperless/media
      - ${PAPERLESS_EXPORT_DIR}:/usr/src/paperless/export
      - ${PAPERLESS_CONSUME_DIR}:/usr/src/paperless/consume
    depends_on:
      paperless-db:
        condition: service_healthy
      paperless-redis:
        condition: service_started
      paperless-gotenberg:
        condition: service_started
      paperless-tika:
        condition: service_started
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

- no se publica ningún puerto en el host porque el acceso recomendado es solo a través de **Caddy**
- `paperless-db`, `paperless-redis`, `paperless-gotenberg` y `paperless-tika` quedan accesibles solo dentro del stack
- los ficheros originales, los PDF archivados, miniaturas, índices y la carpeta `consume/` viven en el NVMe
- `Paperless-ngx` puede recrearse sin perder estado mientras se conserven `data/`, `media/`, `export/`, `consume/` y PostgreSQL

Despliegue inicial:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/paperless-ngx
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/paperless-ngx/data
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/paperless-ngx/media
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/paperless-ngx/export
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/paperless-ngx/consume

cd /home/<usuario>/homelab/compose/paperless-ngx
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f paperless-webserver
```

Si `paperless-db` o `paperless-redis` no pueden inicializar sus bind mounts por permisos, ajusta el propietario real de `/home/<usuario>/homelab/data/paperless-ngx/postgres/` o `/home/<usuario>/homelab/data/paperless-ngx/redis/` según el UID/GID con el que arranque cada imagen en tu entorno y recrea el stack.

Resultado esperado:

- los contenedores `paperless-webserver`, `paperless-db`, `paperless-redis`, `paperless-gotenberg` y `paperless-tika` quedan levantados
- Paperless-ngx escucha internamente en `http://paperless-webserver:8000`
- PostgreSQL queda accesible solo para el stack en `paperless-db:5432`
- Redis queda accesible solo para el stack en `paperless-redis:6379`
- se crean datos persistentes en `/home/<usuario>/homelab/data/paperless-ngx/`
- Caddy puede publicar el servicio como `https://paperless.lan`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `https://paperless.lan` |
| Persistencia app | `/home/<usuario>/homelab/data/paperless-ngx/{data,media,export,consume}/` |
| Persistencia BD | `/home/<usuario>/homelab/data/paperless-ngx/postgres/` |
| Broker interno | Redis en el NVMe |
| OCR | activo con `spa+eng` |
| Carpeta de consumo | `consume/` en el NVMe |
| Punto de entrada | Caddy |
| TLS | `tls internal` con CA local de Caddy |
| Organización | etiquetas, tipos de documento y correspondents |

### 1. Preparar rutas y permisos

Crear la estructura base:

```bash
mkdir -p /home/<usuario>/homelab/compose/paperless-ngx
mkdir -p /home/<usuario>/homelab/data/paperless-ngx/{data,media,export,consume,postgres,redis}
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/paperless-ngx
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/paperless-ngx/data
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/paperless-ngx/media
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/paperless-ngx/export
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/paperless-ngx/consume

chmod 755 /home/<usuario>/homelab/data/paperless-ngx
chmod 755 /home/<usuario>/homelab/data/paperless-ngx/consume
```

Todo el estado activo del servicio debe quedarse en el **SSD NVMe**. `hd2t` se reserva para backups y `hd5t` no interviene en este servicio.

### 2. Publicar Paperless-ngx en Caddy con HTTPS interno

Añade este bloque al `Caddyfile` del stack de Caddy:

```caddyfile
paperless.lan {
  import common
  tls internal
  reverse_proxy paperless-webserver:8000
}
```

Después valida y recarga Caddy:

```bash
cd /home/<usuario>/homelab/compose/caddy
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose up -d
docker compose logs --tail=100 caddy
```

Notas prácticas:

- usa un hostname dedicado en la raíz y no un subpath
- si en tu homelab ya has estandarizado `*.homelab.lan`, sustituye `paperless.lan` por `paperless.homelab.lan` en **DNS**, `.env` y `Caddyfile`
- mantén `PAPERLESS_URL` alineado con la URL real para evitar problemas con sesiones, CSRF o redirecciones

### 3. Importar la CA local de Caddy en los clientes

Ruta del certificado raíz en el host:

```text
/home/<usuario>/homelab/compose/caddy/data/caddy/pki/authorities/local/root.crt
```

Importa ese certificado en:

- tu navegador principal
- el sistema operativo del equipo desde el que vayas a subir o consultar documentos
- cualquier equipo adicional desde Tailscale que deba confiar en `https://paperless.lan`

Sin esa CA instalada el acceso seguirá cifrado, pero el navegador mostrará advertencias y no conviene operar así en un servicio donde vas a iniciar sesión y consultar documentos privados.

### 4. Primer arranque y creación del usuario administrador

Crear el superusuario inicial:

```bash
cd /home/<usuario>/homelab/compose/paperless-ngx
docker compose exec paperless-webserver createsuperuser
```

El comando pedirá nombre de usuario, correo y contraseña de forma interactiva.

Abrir después:

```text
https://paperless.lan
```

Verificación inicial recomendada:

1. Iniciar sesión con la cuenta recién creada.
2. Subir manualmente un PDF pequeño desde la interfaz.
3. Confirmar que el documento aparece indexado y con texto buscable si contiene OCR.
4. Comprobar que aparecen ficheros nuevos en `/home/<usuario>/homelab/data/paperless-ngx/media/`.
5. Revisar los logs si el procesamiento tarda demasiado:

```bash
cd /home/<usuario>/homelab/compose/paperless-ngx
docker compose logs --tail=100 paperless-webserver
docker compose logs --tail=100 paperless-db
```

### 5. Ajustes recomendados de OCR y consumo

Ajustes prácticos para este homelab:

- mantener `PAPERLESS_OCR_MODE=skip` salvo que tengas muchos escaneos con OCR deficiente generado por otro equipo
- mantener `PAPERLESS_OCR_OUTPUT_TYPE=pdfa` para archivado a largo plazo
- dejar `PAPERLESS_CONSUMER_RECURSIVE=true` para poder clasificar por subcarpetas antes de consumir
- dejar `PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS=true` para convertir la estructura de entrada en etiquetas

Ejemplo de organización de `consume/`:

```text
/home/<usuario>/homelab/data/paperless-ngx/consume/
├── banco/
├── facturas/
├── garantias/
├── impuestos/
└── seguros/
```

Con esa estrategia:

- cualquier fichero que entre en `consume/facturas/` recibirá la etiqueta `facturas`
- si usas subdirectorios más profundos, también se crearán etiquetas adicionales
- el directorio de entrada sigue siendo simple de poblar desde otro equipo por SMB, Syncthing o copia manual local

Si observas que la Raspberry Pi 5 se satura durante OCR masivo:

- baja `PAPERLESS_TASK_WORKERS` a `1`
- o deja `PAPERLESS_TASK_WORKERS=2` y baja `PAPERLESS_THREADS_PER_WORKER` a `1`
- evita lanzar grandes lotes mientras haces otras tareas pesadas en la Pi

### 6. Etiquetado y organización documental

Configuración inicial recomendada en la interfaz:

- crear tipos de documento como `Factura`, `Contrato`, `Garantía`, `Seguro`, `Manual`, `Nómina`, `Impuesto`
- crear correspondents para emisores frecuentes: banco, suministradoras, aseguradora, administración pública, tienda online
- definir etiquetas funcionales y no demasiado específicas: `casa`, `coche`, `salud`, `finanzas`, `trabajo`, `familia`
- usar años como etiquetas solo si de verdad simplifican búsquedas o reglas

Buenas prácticas de organización:

- usar etiquetas para contexto transversal
- usar `document type` para el tipo administrativo del documento
- usar `correspondent` para quién lo emite o a quién pertenece
- evitar crear decenas de etiquetas casi duplicadas

Una taxonomía simple suele funcionar mejor que una estructura compleja. Paperless-ngx ya ofrece búsqueda de texto completo, por lo que no hace falta trasladar toda la organización a carpetas.

## Almacenamiento
Volúmenes y rutas persistentes de este servicio:

| Elemento | Ruta en host | Ubicación física |
|---|---|---|
| Datos internos de Paperless-ngx | `/home/<usuario>/homelab/data/paperless-ngx/data/` | SSD NVMe |
| Documentos y miniaturas | `/home/<usuario>/homelab/data/paperless-ngx/media/` | SSD NVMe |
| Exportaciones internas | `/home/<usuario>/homelab/data/paperless-ngx/export/` | SSD NVMe |
| Carpeta de consumo | `/home/<usuario>/homelab/data/paperless-ngx/consume/` | SSD NVMe |
| Base de datos PostgreSQL | `/home/<usuario>/homelab/data/paperless-ngx/postgres/` | SSD NVMe |
| Datos de Redis | `/home/<usuario>/homelab/data/paperless-ngx/redis/` | SSD NVMe |
| Compose del stack | `/home/<usuario>/homelab/compose/paperless-ngx/` | SSD NVMe |
| Backups exportados | `/mnt/hd2t/backups/paperless-ngx/` | `hd2t` |

Qué guarda cada zona:

- `data/` contiene índices, metadatos internos, estado de tareas y otros ficheros propios de la aplicación
- `media/` contiene originales, versiones archivadas, miniaturas y adjuntos gestionados por Paperless-ngx
- `export/` se usa como destino de `document_exporter`
- `consume/` es la bandeja de entrada automática de documentos
- `postgres/` contiene los ficheros reales de la base de datos
- `redis/` contiene el estado persistente del broker si decides conservarlo entre reinicios

Recomendaciones de almacenamiento:

- no pongas `consume/` en `hd2t` ni en `hd5t`
- no mezcles aquí otros servicios
- mantén el conjunto completo dentro de la estrategia de backup del NVMe
- si importas lotes muy grandes de documentos, vigila el crecimiento de `media/` y `export/`

## Backup
Qué respaldar en este servicio:

- el directorio `/home/<usuario>/homelab/data/paperless-ngx/media/`
- el directorio `/home/<usuario>/homelab/data/paperless-ngx/data/`
- el directorio `/home/<usuario>/homelab/data/paperless-ngx/consume/`
- el directorio `/home/<usuario>/homelab/compose/paperless-ngx/`
- preferiblemente una exportación generada con `document_exporter`
- preferiblemente un dump lógico de PostgreSQL

Preparar el destino local de backup:

```bash
mkdir -p /mnt/hd2t/backups/paperless-ngx
```

### Backup manual recomendado

```bash
mkdir -p /mnt/hd2t/backups/paperless-ngx
timestamp="$(date +%F-%H%M%S)"

cd /home/<usuario>/homelab/compose/paperless-ngx

docker compose exec -T paperless-webserver document_exporter ../export

docker compose exec -T paperless-db \
  pg_dump -U paperless -d paperless \
  > "/mnt/hd2t/backups/paperless-ngx/paperless-db-${timestamp}.sql"

rsync -a \
  /home/<usuario>/homelab/data/paperless-ngx/data/ \
  "/mnt/hd2t/backups/paperless-ngx/data-${timestamp}/"

rsync -a \
  /home/<usuario>/homelab/data/paperless-ngx/export/ \
  "/mnt/hd2t/backups/paperless-ngx/export-${timestamp}/"

rsync -a \
  /home/<usuario>/homelab/data/paperless-ngx/media/ \
  "/mnt/hd2t/backups/paperless-ngx/media-${timestamp}/"

rsync -a \
  /home/<usuario>/homelab/data/paperless-ngx/consume/ \
  "/mnt/hd2t/backups/paperless-ngx/consume-${timestamp}/"

rsync -a \
  /home/<usuario>/homelab/compose/paperless-ngx/ \
  /mnt/hd2t/backups/paperless-ngx/compose/
```

Este enfoque combina:

- una exportación lógica propia de Paperless-ngx con documentos y metadatos
- un `pg_dump` de PostgreSQL
- copias directas de `media/`, `consume/` y `compose/`

### Qué no conviene hacer

- confiar solo en la imagen Docker
- respaldar únicamente PostgreSQL y olvidar `media/`
- asumir que `consume/` no importa: puede contener documentos aún no procesados
- copiar la base de datos mientras el servicio está mutando sin una estrategia consistente

### Restore recomendado

Secuencia práctica:

1. Parar el stack.
2. Restaurar `compose/`.
3. Restaurar `media/`, `data/` y `consume/` si procede.
4. Restaurar PostgreSQL desde el dump lógico.
5. Levantar el stack.
6. Validar login, búsqueda, OCR histórico y documentos adjuntos.

Verificaciones útiles:

```bash
cd /home/<usuario>/homelab/compose/paperless-ngx
docker compose ps
docker compose logs --tail=100 paperless-webserver
docker compose logs --tail=100 paperless-db
```

## Referencias
- Documentación oficial de Paperless-ngx: `https://docs.paperless-ngx.com/`
- Instalación con Docker Compose: `https://docs.paperless-ngx.com/setup/`
- Configuración de Paperless-ngx: `https://docs.paperless-ngx.com/configuration/`
- Administración y utilidades de mantenimiento: `https://docs.paperless-ngx.com/administration/`
- Compose oficial con PostgreSQL: `https://github.com/paperless-ngx/paperless-ngx/blob/main/docker/compose/docker-compose.postgres.yml`
- Compose oficial con PostgreSQL + Tika: `https://github.com/paperless-ngx/paperless-ngx/blob/main/docker/compose/docker-compose.postgres-tika.yml`
- Imagen oficial de Paperless-ngx: `https://github.com/paperless-ngx/paperless-ngx/pkgs/container/paperless-ngx`
- Imagen oficial de PostgreSQL: `https://hub.docker.com/_/postgres`
- Imagen oficial de Redis: `https://hub.docker.com/_/redis`
- Imagen oficial de Gotenberg: `https://hub.docker.com/r/gotenberg/gotenberg`
- Imagen oficial de Apache Tika: `https://hub.docker.com/r/apache/tika`
