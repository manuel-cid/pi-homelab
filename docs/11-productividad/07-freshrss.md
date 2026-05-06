# FreshRSS

## Descripción
**FreshRSS** será el lector de feeds RSS y Atom del homelab para centralizar fuentes técnicas, blogs, changelogs, medios y otras suscripciones en una interfaz privada y autohospedada.

En esta arquitectura se despliega con estas reglas:

- la aplicación y todos sus datos persistentes viven en el **SSD NVMe**
- el acceso web local se publica detrás de **Caddy** con `https://freshrss.lan`
- la conexión va siempre por **HTTPS** con la **CA interna de Caddy**
- el acceso remoto sigue siendo **solo LAN + Tailscale**, sin abrir puertos en el router
- la persistencia usa la base de datos **SQLite** integrada, suficiente para un uso personal o familiar pequeño
- la actualización automática de feeds se hace con el **cron interno** del contenedor, sin depender del cron del host
- la migración inicial de suscripciones se hace mediante **importación OPML**

FreshRSS encaja bien en este homelab porque resuelve una necesidad diaria con un stack ligero, evita depender de servicios externos para la lectura de feeds y mantiene casi todo el estado en un único directorio sencillo de respaldar.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres consultar FreshRSS también desde fuera de la LAN mediante VPN.
- Haber completado `docs/07-backups/01-estrategia-backup.md`.
- Haber completado `docs/07-backups/03-backup-docker-volumes.md`.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `freshrss.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Tener importada en los navegadores y dispositivos cliente la CA local de Caddy desde:
  - `/home/<usuario>/homelab/compose/caddy/data/caddy/pki/authorities/local/root.crt`
- Poder usar `sudo` con el usuario administrador del homelab.
- Puertos implicados en esta fase:
  - `80/tcp` solo dentro de Docker entre Caddy y el contenedor `freshrss`
  - `443/tcp` ya publicado por Caddy en el host
  - no se abre ningún puerto entrante en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/freshrss/
├── compose.yaml
└── .env
```

Preparación inicial:

```bash
mkdir -p /home/<usuario>/homelab/compose/freshrss
mkdir -p /home/<usuario>/homelab/data/freshrss
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

FRESHRSS_CONTAINER_NAME=freshrss
FRESHRSS_IMAGE=freshrss/freshrss:latest

CRON_MIN=13,43
FRESHRSS_ENV=production
TRUSTED_PROXY=172.16.0.0/12

FRESHRSS_DATA_DIR=/home/<usuario>/homelab/data/freshrss
```

Notas sobre estas variables:

- `FRESHRSS_IMAGE` usa la imagen oficial estándar, suficiente para un despliegue doméstico simple en Raspberry Pi 5.
- `CRON_MIN=13,43` activa la actualización automática aproximadamente dos veces por hora, un punto de equilibrio razonable para un lector personal.
- `FRESHRSS_ENV=production` evita ruido extra de depuración y deja el contenedor en el modo recomendado para uso normal.
- `TRUSTED_PROXY=172.16.0.0/12` hace que FreshRSS confíe en la IP que le reenvía Caddy dentro de la red Docker; si tus redes Docker usan otro rango, ajusta este valor.
- `FRESHRSS_DATA_DIR` vive en el NVMe porque ahí quedarán la configuración global, las bases SQLite por usuario, logs y cachés del servicio.
- En este despliegue no se usa `FRESHRSS_INSTALL`; la instalación inicial se completa desde la interfaz web, que es el método más cómodo para este homelab y evita dejar contraseñas en texto claro dentro del `.env`.

Fichero `compose.yaml`:

```yaml
name: freshrss

services:
  freshrss:
    container_name: ${FRESHRSS_CONTAINER_NAME}
    image: ${FRESHRSS_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      CRON_MIN: ${CRON_MIN}
      FRESHRSS_ENV: ${FRESHRSS_ENV}
      TRUSTED_PROXY: ${TRUSTED_PROXY}
    volumes:
      - ${FRESHRSS_DATA_DIR}:/var/www/FreshRSS/data
    networks:
      - default
      - homelab_proxy
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD", "cli/health.php"]
      timeout: 10s
      start_period: 60s
      start_interval: 11s
      interval: 75s
      retries: 3

networks:
  homelab_proxy:
    external: true
    name: homelab_proxy
```

Notas operativas sobre este stack:

- no se publica ningún puerto en el host porque el acceso recomendado es solo a través de **Caddy**
- FreshRSS escucha internamente en el puerto `80`
- toda la persistencia queda concentrada en `/var/www/FreshRSS/data`
- la base de datos por defecto es **SQLite**, adecuada para este caso de uso y fácil de respaldar
- el propio entrypoint de la imagen ajusta permisos internos en el directorio de datos al arrancar
- el cron interno del contenedor actualiza los feeds sin requerir tareas programadas adicionales en Raspberry Pi OS

Despliegue inicial:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/freshrss
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/freshrss

cd /home/<usuario>/homelab/compose/freshrss
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f freshrss
```

Resultado esperado:

- el contenedor `freshrss` queda levantado
- FreshRSS escucha internamente en `http://freshrss:80`
- se crea la estructura persistente en `/home/<usuario>/homelab/data/freshrss/`
- el healthcheck termina en estado saludable tras el arranque inicial
- Caddy puede publicar el servicio como `https://freshrss.lan`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `https://freshrss.lan` |
| Persistencia | `/home/<usuario>/homelab/data/freshrss/` |
| Base de datos | SQLite en el NVMe |
| Punto de entrada | Caddy |
| TLS | `tls internal` con CA local de Caddy |
| Actualización de feeds | cron interno del contenedor |
| Migración inicial | importación OPML |

### 1. Preparar rutas y permisos

Crear la estructura base:

```bash
mkdir -p /home/<usuario>/homelab/compose/freshrss
mkdir -p /home/<usuario>/homelab/data/freshrss
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/freshrss
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/freshrss

chmod 755 /home/<usuario>/homelab/data/freshrss
```

Toda la información operativa de FreshRSS debe quedarse en el **SSD NVMe**. `hd2t` se reserva para backups y `hd5t` no interviene en este servicio.

### 2. Publicar FreshRSS en Caddy con HTTPS interno

Añade este bloque al `Caddyfile` del stack de Caddy:

```caddyfile
freshrss.lan {
  import common
  tls internal
  reverse_proxy freshrss:80
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
- si en tu homelab ya has estandarizado `*.homelab.lan`, sustituye `freshrss.lan` por `freshrss.homelab.lan` en **DNS** y `Caddyfile`
- si tu red Docker no usa subredes `172.16.0.0/12`, actualiza también `TRUSTED_PROXY` en el `.env` antes del primer arranque o recrea el contenedor después

### 3. Importar la CA local de Caddy en los clientes

Ruta del certificado raíz en el host:

```text
/home/<usuario>/homelab/compose/caddy/data/caddy/pki/authorities/local/root.crt
```

Importa ese certificado en:

- tu navegador principal
- cualquier otro navegador o dispositivo desde el que vayas a abrir `https://freshrss.lan`
- cualquier equipo adicional conectado por Tailscale que deba confiar en el certificado interno

Sin esa CA instalada el acceso seguirá cifrado, pero el navegador no confiará en el certificado y la experiencia será peor.

### 4. Primer arranque e instalación inicial

Abrir después:

```text
https://freshrss.lan
```

En el asistente inicial:

1. Elegir idioma.
2. Verificar que los chequeos previos no muestran errores de permisos en `data/`.
3. Mantener **SQLite** como base de datos del servicio.
4. Crear el usuario administrador inicial.
5. Completar la instalación y volver a iniciar sesión con la cuenta creada.

Validación mínima recomendada:

- comprobar que la interfaz carga correctamente detrás de Caddy
- verificar que el login funciona
- abrir la pantalla de administración y revisar que no haya errores graves en logs o diagnósticos
- confirmar en `docker compose logs freshrss` que el contenedor no entra en reinicio

Si el instalador web indica problemas de escritura en el directorio `data/`, para el stack, revisa permisos del bind mount y vuelve a levantar el contenedor. La imagen oficial ajusta permisos internos al arrancar, pero el directorio del host debe seguir siendo escribible por Docker.

### 5. Ajustes recomendados tras el primer login

Revisión práctica inicial:

- definir la zona horaria e idioma de la cuenta si quieres que coincidan con tu uso diario
- revisar la política de borrado y retención antes de empezar una importación grande
- comprobar que la actualización manual de feeds funciona antes de depender del cron interno
- validar que el FQDN real sigue siendo `https://freshrss.lan`

Notas operativas:

- `CRON_MIN=13,43` ya deja activo el refresco periódico; no hace falta programar nada en el host
- si más adelante quieres menos carga en la Raspberry Pi, aumenta el intervalo del cron
- si algún feed interno usa certificados privados o autofirmados, lo correcto es instalar la CA correspondiente en el host o en la imagen, no desactivar verificaciones de TLS de forma global

### 6. Importación de feeds OPML

Para migrar desde otro lector RSS o cargar un conjunto inicial de suscripciones:

1. Ir a **Subscriptions management**.
2. Abrir **Import / export**.
3. Seleccionar el fichero `.opml` exportado desde el origen.
4. Ejecutar la importación.
5. Revisar categorías, títulos de feeds y primeros refrescos.

Recomendaciones operativas:

- empieza con un OPML pequeño o con una copia de prueba antes de importar toda tu colección
- después de importar, lanza una actualización manual y comprueba que aparecen artículos nuevos
- usa categorías funcionales como `homelab`, `docker`, `seguridad`, `linux`, `programación`, `noticias`
- recuerda que el formato **OPML** sirve para migrar la lista estándar de feeds, pero no conserva todos los ajustes específicos de FreshRSS como credenciales, frecuencia de refresco o reglas avanzadas de scraping

## Almacenamiento
Volúmenes y rutas persistentes de este servicio:

| Elemento | Ruta en host | Ubicación física |
|---|---|---|
| Datos de FreshRSS | `/home/<usuario>/homelab/data/freshrss/` | SSD NVMe |
| Compose del stack | `/home/<usuario>/homelab/compose/freshrss/` | SSD NVMe |
| Backups exportados | `/mnt/hd2t/backups/freshrss/` | `hd2t` |

Contenido típico tras el despliegue:

```text
/home/<usuario>/homelab/data/freshrss/
├── config.php
├── users/
├── cache/
└── favicons/
```

Qué guarda cada zona:

- `config.php`: configuración global e instalación de FreshRSS
- `users/`: configuración por usuario, bases SQLite, logs y estado individual
- `cache/`: caché temporal de contenidos y metadatos, regenerable si hiciera falta
- `favicons/`: iconos descargados de los feeds, regenerables si se pierden

Recomendaciones de almacenamiento:

- no pongas esta ruta en `hd2t` ni en `hd5t`
- no mezcles aquí otros servicios
- mantén el directorio completo dentro de los backups del NVMe
- aunque `cache/` y `favicons/` se pueden reconstruir, para un homelab pequeño suele compensar respaldar todo el directorio y simplificar el restore

## Backup
Qué respaldar en este servicio:

- el directorio `/home/<usuario>/homelab/data/freshrss/`
- el directorio `/home/<usuario>/homelab/compose/freshrss/`
- opcionalmente, una exportación OPML por usuario como copia lógica adicional de la lista de suscripciones

Como este despliegue usa **SQLite**, la copia más segura y simple para este homelab es parar unos segundos el contenedor y respaldar el directorio completo.

Preparar el destino local de backup:

```bash
mkdir -p /mnt/hd2t/backups/freshrss
```

### Backup manual recomendado

```bash
mkdir -p /mnt/hd2t/backups/freshrss
timestamp="$(date +%F-%H%M%S)"

cd /home/<usuario>/homelab/compose/freshrss
docker compose stop freshrss

sudo tar -C /home/<usuario>/homelab/data \
  -czf "/mnt/hd2t/backups/freshrss/freshrss-data-${timestamp}.tar.gz" \
  freshrss

rsync -a \
  /home/<usuario>/homelab/compose/freshrss/ \
  /mnt/hd2t/backups/freshrss/compose/

docker compose start freshrss

sha256sum "/mnt/hd2t/backups/freshrss/freshrss-data-${timestamp}.tar.gz" \
  > "/mnt/hd2t/backups/freshrss/freshrss-data-${timestamp}.tar.gz.sha256"
```

Este enfoque cubre la configuración global, las bases SQLite por usuario, logs y el resto de estado persistente.

### Exportación complementaria de feeds

Como copia adicional, conviene exportar periódicamente la lista de suscripciones desde la interfaz web en formato OPML. Esa exportación:

- es portable a otros lectores RSS
- sirve para una migración rápida o contingencia básica
- no sustituye el backup completo, porque no conserva todos los parámetros específicos del servicio

### Qué no conviene hacer

- confiar solo en la imagen Docker o en el `compose.yaml`
- respaldar únicamente una exportación OPML y asumir que equivale a una copia completa del servicio
- copiar solo ficheros sueltos de SQLite en caliente como única estrategia si el contenedor está escribiendo

### Restore recomendado

Secuencia práctica:

1. Parar el stack de FreshRSS.
2. Renombrar el directorio actual como salvaguarda.
3. Restaurar el `tar.gz` del backup en `/home/<usuario>/homelab/data/`.
4. Levantar el stack y validar login, categorías, feeds y artículos.

Ejemplo:

```bash
cd /home/<usuario>/homelab/compose/freshrss
docker compose down

sudo mv \
  /home/<usuario>/homelab/data/freshrss \
  "/home/<usuario>/homelab/data/freshrss.before-restore-$(date +%F-%H%M%S)"

sudo mkdir -p /home/<usuario>/homelab/data
sudo tar -C /home/<usuario>/homelab/data \
  -xzf /mnt/hd2t/backups/freshrss/freshrss-data-<timestamp>.tar.gz

docker compose up -d
docker compose logs --tail=100 freshrss
```

Validación posterior al restore:

- el login funciona con la cuenta existente
- los feeds siguen presentes y agrupados en sus categorías
- aparecen artículos anteriores en el historial
- la actualización manual vuelve a funcionar

## Referencias
- Documentación oficial de FreshRSS: `https://freshrss.github.io/FreshRSS/`
- Documentación oficial para Docker: `https://github.com/FreshRSS/FreshRSS/blob/edge/Docker/README.md`
- Docker Compose oficial de referencia: `https://github.com/FreshRSS/FreshRSS/blob/edge/Docker/freshrss/docker-compose.yml`
- Gestión de suscripciones e importación OPML: `https://github.com/FreshRSS/FreshRSS/blob/edge/docs/en/users/04_Subscriptions.md`
- Backup oficial de FreshRSS: `https://github.com/FreshRSS/FreshRSS/blob/edge/docs/en/admins/05_Backup.md`
- Repositorio oficial de FreshRSS: `https://github.com/FreshRSS/FreshRSS`
- Imagen Docker oficial `freshrss/freshrss`: `https://hub.docker.com/r/freshrss/freshrss`
