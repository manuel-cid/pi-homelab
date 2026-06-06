# Paperless-ngx

## Descripción

**Paperless-ngx** es el gestor documental de este homelab: recibe PDFs e imágenes escaneadas, ejecuta **OCR**, clasifica documentos y permite buscarlos por texto, etiquetas, corresponsales y tipos documentales.

En esta Raspberry Pi 5 conviene desplegarlo como **una sola aplicación lógica** con varios contenedores:

- `webserver` para la aplicación principal
- `db` con **PostgreSQL**
- `broker` con **Redis**

La decisión de almacenamiento en este proyecto es clara:

- toda la persistencia vive en el **SSD NVMe**
- la carpeta de entrada `consume/` también vive en el **SSD NVMe**
- `hd2t` y `hd5t` no se usan para datos activos de Paperless-ngx

Para este homelab la topología más simple y compatible es publicar Paperless-ngx directamente en `16002/tcp` para acceso desde **LAN** y **Tailscale**. Esto evita complicaciones con subrutas en reverse proxy y mantiene una URL directa para la UI.

## Requisitos Previos

- Haber completado [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber completado [04-tailscale.md](../03-red/04-tailscale.md) si quieres acceder también desde fuera de casa por la tailnet.
- Revisar [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) para documentar el puerto del servicio.
- Revisar [03-backup-docker-volumes.md](../07-backups/03-backup-docker-volumes.md) si vas a incluir sus bind mounts en la estrategia de copias.
- Disponer de `/home/<user>/homelab/` en el **SSD NVMe** con permisos normales para el usuario administrador.
- Tener decidido el idioma principal de OCR. Para un uso doméstico en España suele ser razonable empezar con `spa+eng`.
- Puertos necesarios en esta fase:
  - **`16002/tcp` publicado en el host** para acceso web desde LAN y Tailscale
  - **`5432/tcp` y `6379/tcp` no se publican**; quedan solo en la red interna del stack

## Docker Compose

Archivo: `/home/<user>/homelab/compose/paperless-ngx/docker-compose.yml`

```yaml
name: paperless-ngx

services:
  broker:
    image: redis:8
    restart: unless-stopped
    volumes:
      - /home/<user>/homelab/data/paperless/redis:/data
    labels:
      - wud.watch=false

  db:
    image: postgres:18
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${PAPERLESS_DB_NAME}
      POSTGRES_USER: ${PAPERLESS_DB_USER}
      POSTGRES_PASSWORD: ${PAPERLESS_DB_PASSWORD}
    volumes:
      - /home/<user>/homelab/data/paperless/db:/var/lib/postgresql/data
    labels:
      - wud.watch=false

  webserver:
    image: ghcr.io/paperless-ngx/paperless-ngx:latest
    restart: unless-stopped
    depends_on:
      - broker
      - db
    env_file:
      - .env
    environment:
      PAPERLESS_REDIS: redis://broker:6379
      PAPERLESS_DBHOST: db
      PAPERLESS_DBPORT: 5432
      PAPERLESS_DBNAME: ${PAPERLESS_DB_NAME}
      PAPERLESS_DBUSER: ${PAPERLESS_DB_USER}
      PAPERLESS_DBPASS: ${PAPERLESS_DB_PASSWORD}
      PAPERLESS_TIME_ZONE: ${TZ}
      PAPERLESS_OCR_LANGUAGE: ${PAPERLESS_OCR_LANGUAGE}
      PAPERLESS_TASK_WORKERS: ${PAPERLESS_TASK_WORKERS}
      PAPERLESS_CONSUMER_RECURSIVE: ${PAPERLESS_CONSUMER_RECURSIVE}
      PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS: ${PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS}
      PAPERLESS_SECRET_KEY: ${PAPERLESS_SECRET_KEY}
      USERMAP_UID: ${PUID}
      USERMAP_GID: ${PGID}
    ports:
      - "${PAPERLESS_BIND_IP}:${PAPERLESS_PORT}:8000"
    volumes:
      - /home/<user>/homelab/data/paperless/data:/usr/src/paperless/data
      - /home/<user>/homelab/data/paperless/media:/usr/src/paperless/media
      - /home/<user>/homelab/data/paperless/export:/usr/src/paperless/export
      - /home/<user>/homelab/data/paperless/consume:/usr/src/paperless/consume
    labels:
      - wud.watch=false
```

Archivo recomendado: `/home/<user>/homelab/compose/paperless-ngx/.env`

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000
PAPERLESS_BIND_IP=0.0.0.0
PAPERLESS_PORT=16002
PAPERLESS_DB_NAME=paperless
PAPERLESS_DB_USER=paperless
PAPERLESS_DB_PASSWORD=cambiar-esta-clave-larga
PAPERLESS_SECRET_KEY=cambiar-esta-clave-secreta-larga-y-aleatoria
PAPERLESS_OCR_LANGUAGE=spa+eng
PAPERLESS_TASK_WORKERS=1
PAPERLESS_CONSUMER_RECURSIVE=true
PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS=true
```

Notas sobre este Compose:

- `Paperless-ngx` queda como un stack único porque `webserver`, `PostgreSQL` y `Redis` forman una sola aplicación lógica.
- la persistencia completa queda en bind mounts sobre el **SSD NVMe**
- `PAPERLESS_TASK_WORKERS=1` es una base prudente para una Raspberry Pi 5 de 8 GB; puedes subirlo después si importas lotes grandes
- `PAPERLESS_CONSUMER_RECURSIVE=true` y `PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS=true` permiten usar subcarpetas dentro de `consume/` como **etiquetas automáticas**
- se excluye de WUD para evitar actualizaciones automáticas ciegas en una aplicación con migraciones de base de datos
- si necesitas ingerir muchos documentos Office, puedes extender más adelante el stack con **Gotenberg** y **Tika**, pero para escaneos PDF e imágenes el despliegue anterior ya es funcional

## Configuración

### 1. Preparar directorios del stack

```bash
mkdir -p /home/<user>/homelab/compose/paperless-ngx
mkdir -p /home/<user>/homelab/data/paperless/{consume,data,media,export,db,redis}
chmod 700 /home/<user>/homelab/data/paperless/db
chmod 700 /home/<user>/homelab/data/paperless/redis
chmod 750 /home/<user>/homelab/data/paperless
chmod 770 /home/<user>/homelab/data/paperless/consume
```

Guarda en el primer directorio el `docker-compose.yml` y el `.env` del apartado anterior.

Como `.env` contiene secretos y credenciales, conviene restringir permisos:

```bash
chmod 600 /home/<user>/homelab/compose/paperless-ngx/.env
```

Si no conoces tu UID y GID reales:

```bash
id -u
id -g
```

Úsalos en `PUID` y `PGID` para que tanto el host como el contenedor puedan escribir correctamente en `consume/`.

### 2. Generar secretos antes del primer arranque

Reemplaza `PAPERLESS_DB_PASSWORD` y `PAPERLESS_SECRET_KEY` por valores fuertes. Un método simple:

```bash
openssl rand -base64 24
openssl rand -base64 48
```

Usa la primera salida como contraseña de PostgreSQL y la segunda como `PAPERLESS_SECRET_KEY`.

### 3. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/paperless-ngx
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=100 webserver
```

Validaciones rápidas:

```bash
curl -I http://127.0.0.1:16002/
ls -lah /home/<user>/homelab/data/paperless
docker compose logs --tail=50 db
docker compose logs --tail=50 broker
```

Si todo ha arrancado bien, la UI quedará accesible en una de estas URLs:

- `http://<ip-lan-de-la-pi>:16002`
- `http://pi-homelab.<tailnet>.ts.net:16002`

### 4. Crear el primer usuario administrador

En una instalación nueva, al abrir la interfaz web se te pedirá crear el primer **superuser**.

Flujo recomendado:

1. Abre `http://<ip-lan-de-la-pi>:16002` o la URL Tailscale equivalente.
2. Crea la cuenta administrativa inicial.
3. Inicia sesión y verifica que la biblioteca está vacía pero operativa.
4. Crea después un usuario normal si no quieres usar la cuenta admin para el día a día.

Si alguna vez necesitas crearlo manualmente desde consola:

```bash
cd /home/<user>/homelab/compose/paperless-ngx
docker compose exec webserver createsuperuser
```

### 5. Ajustes iniciales en la UI

Después del primer login, revisa como mínimo:

- **idioma, zona horaria y preferencias personales**
- **tipos documentales** iniciales: por ejemplo `factura`, `banco`, `seguro`, `salud`, `hacienda`
- **corresponsales** frecuentes: bancos, suministradoras, aseguradoras, administración pública
- **tags** iniciales si quieres combinar etiquetas manuales con las derivadas de carpetas
- reglas de correspondencia y título solo cuando ya tengas varios documentos reales para afinar criterios

Para un homelab personal suele funcionar bien este enfoque:

1. empezar con pocos tipos documentales y pocos tags
2. dejar que el OCR y las búsquedas te enseñen qué conviene normalizar
3. automatizar después reglas de clasificación, corresponsales y almacenamiento

### 6. Usar la carpeta `consume/` y etiquetado por subdirectorios

Con la configuración propuesta, cualquier archivo colocado en:

`/home/<user>/homelab/data/paperless/consume/`

será ingerido automáticamente por Paperless-ngx.

Además, como `PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS=true`, puedes usar subcarpetas para añadir etiquetas automáticas. Ejemplos:

```bash
mkdir -p /home/<user>/homelab/data/paperless/consume/facturas/luz
mkdir -p /home/<user>/homelab/data/paperless/consume/banco
cp ~/escaneos/factura-endesa.pdf /home/<user>/homelab/data/paperless/consume/facturas/luz/
cp ~/descargas/extracto.pdf /home/<user>/homelab/data/paperless/consume/banco/
```

Resultado esperado:

- `factura-endesa.pdf` entra con las etiquetas `facturas` y `luz`
- `extracto.pdf` entra con la etiqueta `banco`

Buenas prácticas para esta carpeta:

- usarla como **bandeja de entrada**, no como archivo permanente
- dejar nombres razonables en origen cuando sea posible
- separar por subdirectorios útiles y estables, no por carpetas improvisadas que luego solo generan ruido

### 7. OCR y rendimiento en Raspberry Pi 5

El ajuste `PAPERLESS_OCR_LANGUAGE=spa+eng` es una base razonable si manejas documentos en español e inglés, pero tiene coste de CPU.

Recomendación práctica:

- si casi todo está en español, prueba primero con `spa`
- añade `+eng` solo si realmente lo necesitas
- mantén `PAPERLESS_TASK_WORKERS=1` mientras validas consumo, memoria y tiempos de OCR
- sube workers solo después de comprobar que la Pi sigue respondiendo bien durante importaciones grandes

Comandos útiles de diagnóstico:

```bash
cd /home/<user>/homelab/compose/paperless-ngx
docker compose logs --tail=100 webserver
docker compose exec webserver document_sanity_checker
```

## Almacenamiento

Rutas persistentes de este servicio:

- `/home/<user>/homelab/data/paperless/data/` en el **SSD NVMe**
- `/home/<user>/homelab/data/paperless/media/` en el **SSD NVMe**
- `/home/<user>/homelab/data/paperless/consume/` en el **SSD NVMe**
- `/home/<user>/homelab/data/paperless/export/` en el **SSD NVMe**
- `/home/<user>/homelab/data/paperless/db/` en el **SSD NVMe**
- `/home/<user>/homelab/data/paperless/redis/` en el **SSD NVMe**

Qué suele vivir en cada ruta:

- `data/` con datos internos de la aplicación, índices y estado auxiliar
- `media/` con originales, archivos procesados, thumbnails y documentos archivados
- `consume/` como bandeja de entrada de ficheros
- `export/` para exportaciones completas generadas por `document_exporter`
- `db/` con la base PostgreSQL
- `redis/` con el broker y su estado en disco

Política recomendada:

- todo el estado operativo de Paperless-ngx vive en el **SSD NVMe**
- no mezclar datos activos del DMS con `hd2t` ni `hd5t`
- si escaneas desde otro equipo, copia o sincroniza los PDFs hacia `consume/` en el NVMe y deja que Paperless los procese allí

## Backup

Qué respaldar como mínimo:

- `/home/<user>/homelab/compose/paperless-ngx/docker-compose.yml`
- `/home/<user>/homelab/compose/paperless-ngx/.env`
- `/home/<user>/homelab/data/paperless/data/`
- `/home/<user>/homelab/data/paperless/media/`
- `/home/<user>/homelab/data/paperless/export/`
- un dump lógico de PostgreSQL

Estrategia recomendada en este homelab:

1. generar una exportación lógica de Paperless-ngx
2. generar además un dump de PostgreSQL
3. dejar ambos artefactos en una ruta de copias de `hd2t`
4. respaldar luego el árbol de bind mounts del **SSD NVMe**

Exportación lógica de documentos y metadatos:

```bash
cd /home/<user>/homelab/compose/paperless-ngx
docker compose exec -T webserver \
  document_exporter ../export --no-progress-bar
ls -lah /home/<user>/homelab/data/paperless/export
```

Dump lógico de PostgreSQL hacia la zona de backups:

```bash
mkdir -p /media/hd2t/backups/exports/postgres
cd /home/<user>/homelab/compose/paperless-ngx
docker compose exec -T db pg_dump -U paperless -d paperless | gzip \
  > /media/hd2t/backups/exports/postgres/paperless-$(date +%F).sql.gz
ls -lh /media/hd2t/backups/exports/postgres/paperless-$(date +%F).sql.gz
```

Para una copia fría consistente del árbol completo:

```bash
cd /home/<user>/homelab/compose/paperless-ngx
docker compose stop
rsync -a /home/<user>/homelab/data/paperless/ /ruta/de/backup/paperless/
docker compose start
```

Buenas prácticas de restore:

- si restauras desde `document_exporter`, conserva también una copia del dump de PostgreSQL por si necesitas una recuperación más literal
- valida el restore en un stack temporal antes de dar por buena la estrategia
- recuerda que `consume/` es cola de entrada; lo importante a preservar son `media/`, `data/`, la configuración y la base de datos

## Referencias

- [Paperless-ngx - Sitio oficial](https://docs.paperless-ngx.com/)
- [Paperless-ngx - Setup](https://docs.paperless-ngx.com/setup/)
- [Paperless-ngx - Configuration](https://docs.paperless-ngx.com/configuration/)
- [Paperless-ngx - Administration and Backups](https://docs.paperless-ngx.com/administration/)
- [Paperless-ngx - Docker Compose examples](https://github.com/paperless-ngx/paperless-ngx/tree/main/docker/compose)
- [Imagen Docker de Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx/pkgs/container/paperless-ngx)
- [Imagen Docker de PostgreSQL](https://hub.docker.com/_/postgres)
- [Imagen Docker de Redis](https://hub.docker.com/_/redis)
