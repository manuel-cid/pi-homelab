# BookStack

## Descripción
**BookStack** será la wiki interna del homelab para centralizar procedimientos, inventario, runbooks, notas operativas y documentación viva del propio entorno.

En esta arquitectura se despliega con estas reglas:

- la aplicación y su base de datos viven en el **SSD NVMe**
- el acceso web local se publica detrás de **Caddy** con `https://bookstack.lan`
- la conexión va siempre por **HTTPS** con la **CA interna de Caddy**
- el acceso remoto sigue siendo **solo LAN + Tailscale**, sin abrir puertos en el router
- la base de datos usa **MariaDB** en un contenedor del mismo stack, con sus ficheros persistentes también en el NVMe

BookStack encaja bien en este homelab porque permite organizar documentación técnica por estanterías, libros, capítulos y páginas, facilita mantener runbooks operativos versionados a nivel de contenido y deja claro qué conocimiento depende del homelab y qué procedimientos deben sobrevivir a un reinicio, una migración o una restauración.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres consultar la documentación también desde fuera de la LAN mediante VPN.
- Haber completado `docs/07-backups/01-estrategia-backup.md`.
- Haber completado `docs/07-backups/03-backup-docker-volumes.md`.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `bookstack.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Tener importada en los navegadores y dispositivos cliente la CA local de Caddy desde:
  - `/home/<usuario>/homelab/compose/caddy/data/caddy/pki/authorities/local/root.crt`
- Poder usar `sudo` con el usuario administrador del homelab.
- Puertos implicados en esta fase:
  - `80/tcp` solo dentro de Docker entre Caddy y el contenedor `bookstack`
  - `3306/tcp` solo dentro de la red Docker entre `bookstack` y `bookstack-db`
  - `443/tcp` ya publicado por Caddy en el host
  - no se abre ningún puerto entrante en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/bookstack/
├── compose.yaml
└── .env
```

Preparación inicial:

```bash
mkdir -p /home/<usuario>/homelab/compose/bookstack
mkdir -p /home/<usuario>/homelab/data/bookstack/{config,mariadb}
```

Identificar `PUID` y `PGID` del usuario administrador:

```bash
id -u <usuario>
id -g <usuario>
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000

BOOKSTACK_IMAGE=lscr.io/linuxserver/bookstack:latest
MARIADB_IMAGE=mariadb:11.4

APP_URL=https://bookstack.lan
APP_KEY=<clave-generada-por-la-imagen>

MARIADB_ROOT_PASSWORD=<password-larga-root>
MARIADB_DATABASE=bookstack
MARIADB_USER=bookstack
MARIADB_PASSWORD=<password-larga-app>

BOOKSTACK_CONFIG_DIR=/home/<usuario>/homelab/data/bookstack/config
BOOKSTACK_DB_DIR=/home/<usuario>/homelab/data/bookstack/mariadb
```

Notas sobre estas variables:

- `APP_URL` debe coincidir exactamente con la URL real publicada por Caddy.
- `APP_KEY` es obligatoria y debe generarse antes del primer arranque.
- `MARIADB_ROOT_PASSWORD` se usa para administración y backups del motor.
- `MARIADB_DATABASE`, `MARIADB_USER` y `MARIADB_PASSWORD` crean una base dedicada para BookStack.
- `BOOKSTACK_CONFIG_DIR` y `BOOKSTACK_DB_DIR` viven en el NVMe porque contienen configuración, uploads, adjuntos y la base de datos.
- Si usas caracteres especiales en las contraseñas del `.env`, valida después con `docker compose config` que no haya problemas de interpretación.

Generar una `APP_KEY` segura con la propia imagen de BookStack:

```bash
docker run --rm --entrypoint /bin/bash lscr.io/linuxserver/bookstack:latest appkey
```

Ese comando imprime la clave en pantalla. Cópiala en `APP_KEY` antes del primer `docker compose up -d`.

Fichero `compose.yaml`:

```yaml
name: bookstack

services:
  bookstack-db:
    container_name: bookstack-db
    image: ${MARIADB_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_DATABASE: ${MARIADB_DATABASE}
      MARIADB_USER: ${MARIADB_USER}
      MARIADB_PASSWORD: ${MARIADB_PASSWORD}
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
    volumes:
      - ${BOOKSTACK_DB_DIR}:/var/lib/mysql
    networks:
      - default
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
    security_opt:
      - no-new-privileges:true

  bookstack:
    container_name: bookstack
    image: ${BOOKSTACK_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      PUID: ${PUID}
      PGID: ${PGID}
      TZ: ${TZ}
      APP_URL: ${APP_URL}
      APP_KEY: ${APP_KEY}
      DB_HOST: bookstack-db
      DB_PORT: 3306
      DB_USERNAME: ${MARIADB_USER}
      DB_PASSWORD: ${MARIADB_PASSWORD}
      DB_DATABASE: ${MARIADB_DATABASE}
    volumes:
      - ${BOOKSTACK_CONFIG_DIR}:/config
    depends_on:
      bookstack-db:
        condition: service_healthy
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
- `bookstack-db` solo expone MariaDB dentro de la red interna del stack
- la persistencia queda separada entre configuración de la aplicación y datos de MariaDB para simplificar backup y restore
- el contenedor `bookstack` guarda en `/config` la configuración persistente de la imagen y, dentro de `/config/www/.env`, el `.env` interno de la aplicación

Despliegue inicial:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/bookstack
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/bookstack/config

cd /home/<usuario>/homelab/compose/bookstack
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f bookstack
```

Si MariaDB no puede inicializar el bind mount del NVMe por permisos, corrige el propietario real del directorio `/home/<usuario>/homelab/data/bookstack/mariadb` según el UID/GID con el que arranque la imagen en tu entorno y recrea el stack.

Resultado esperado:

- los contenedores `bookstack` y `bookstack-db` quedan levantados
- BookStack escucha internamente en `http://bookstack:80`
- MariaDB queda accesible solo para el stack en `bookstack-db:3306`
- se crean datos persistentes en `/home/<usuario>/homelab/data/bookstack/`
- Caddy puede publicar el servicio como `https://bookstack.lan`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `https://bookstack.lan` |
| Persistencia app | `/home/<usuario>/homelab/data/bookstack/config/` |
| Persistencia BD | `/home/<usuario>/homelab/data/bookstack/mariadb/` |
| Base de datos | MariaDB en el NVMe |
| Punto de entrada | Caddy |
| TLS | `tls internal` con CA local de Caddy |
| Uso principal | documentación del propio homelab |

### 1. Preparar rutas y permisos

Crear la estructura base:

```bash
mkdir -p /home/<usuario>/homelab/compose/bookstack
mkdir -p /home/<usuario>/homelab/data/bookstack/{config,mariadb}
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/bookstack
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/bookstack/config

chmod 755 /home/<usuario>/homelab/data/bookstack
chmod 755 /home/<usuario>/homelab/data/bookstack/config
```

Toda la documentación viva, los uploads, el `.env` interno de la aplicación y la base de datos deben permanecer en el **SSD NVMe**. `hd2t` se reserva para backups y no debe usarse como almacenamiento activo del servicio.

### 2. Publicar BookStack en Caddy con HTTPS interno

Añade este bloque al `Caddyfile` del stack de Caddy:

```caddyfile
bookstack.lan {
  import common
  tls internal
  reverse_proxy bookstack:80
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
- si en tu homelab ya has estandarizado `*.homelab.lan`, sustituye `bookstack.lan` por `bookstack.homelab.lan` en **DNS**, `APP_URL` y `Caddyfile`
- si cambias la URL después de crear contenido, actualiza también la URL interna de BookStack con su comando de mantenimiento

### 3. Importar la CA local de Caddy en los clientes

Ruta del certificado raíz en el host:

```text
/home/<usuario>/homelab/compose/caddy/data/caddy/pki/authorities/local/root.crt
```

Importa ese certificado en:

- tu navegador principal
- el sistema operativo desde el que vayas a consultar o editar la wiki
- cualquier equipo adicional desde Tailscale que deba confiar en `https://bookstack.lan`

Sin esa CA instalada el acceso seguirá cifrado, pero el navegador mostrará advertencias y no conviene trabajar así en una herramienta donde vas a iniciar sesión y mantener documentación operativa.

### 4. Primer arranque y endurecimiento básico

Abrir después:

```text
https://bookstack.lan
```

Credenciales iniciales por defecto:

- usuario: `admin@admin.com`
- contraseña: `password`

Secuencia recomendada:

1. Iniciar sesión con la cuenta por defecto.
2. Cambiar inmediatamente la contraseña del administrador.
3. Cambiar el correo del usuario administrador por uno real de tu homelab.
4. Crear una segunda cuenta administradora o una cuenta operativa normal si no quieres usar siempre el admin por defecto renombrado.
5. Verificar que el servicio puede crear una página de prueba y subir un adjunto pequeño.
6. Confirmar que aparecen ficheros nuevos en `/home/<usuario>/homelab/data/bookstack/config/`.

Ajustes recomendados tras el primer login:

- definir el nombre visible del sitio como `Homelab`
- desactivar el registro público si no lo necesitas
- revisar preferencias regionales, idioma y formato horario
- mantener solo los métodos de autenticación realmente necesarios en un entorno local

### 5. Organizar la documentación del propio homelab

Estructura recomendada para que BookStack replique la documentación operativa del repositorio:

- crear una estantería `Homelab`
- crear libros por área funcional, por ejemplo `Sistema`, `Docker`, `Red`, `Seguridad`, `Backups`, `Multimedia`, `Productividad` y `Operaciones`
- usar capítulos para separar instalación, configuración, troubleshooting y mantenimiento
- reservar páginas cortas para runbooks concretos: reinicio seguro, restauración de backup, actualización de imágenes, revisión de discos o validación post-cambios
- usar etiquetas consistentes como `servicio:<nombre>`, `fase:<n>`, `tipo:runbook`, `tipo:inventario` o `estado:pendiente`

Una estructura útil para este homelab es mantener dos planos de documentación:

- documentación estable: arquitectura, red, almacenamiento, convenciones y credenciales de servicio sin secretos
- documentación operativa: procedimientos paso a paso, incidencias conocidas, comprobaciones posteriores y cambios aplicados

### 6. Cambios de URL y mantenimiento

Si cambias el FQDN de BookStack más adelante, actualiza `APP_URL`, recrea el contenedor y después ajusta las URLs almacenadas:

```bash
docker exec -it bookstack php /app/www/artisan bookstack:update-url \
  https://bookstack.lan \
  https://bookstack.homelab.lan
```

Verificaciones útiles:

```bash
cd /home/<usuario>/homelab/compose/bookstack
docker compose ps
docker compose logs --tail=100 bookstack
docker compose logs --tail=100 bookstack-db
```

## Almacenamiento
Volúmenes y rutas persistentes de este servicio:

| Elemento | Ruta en host | Ubicación física |
|---|---|---|
| Configuración de BookStack | `/home/<usuario>/homelab/data/bookstack/config/` | SSD NVMe |
| Base de datos MariaDB | `/home/<usuario>/homelab/data/bookstack/mariadb/` | SSD NVMe |
| Compose del stack | `/home/<usuario>/homelab/compose/bookstack/` | SSD NVMe |
| Backups exportados | `/mnt/hd2t/backups/bookstack/` | `hd2t` |

Qué guarda cada ruta:

- `config/` contiene la configuración persistente de la imagen, el fichero `/config/www/.env`, uploads, imágenes, adjuntos, temas y logs de la aplicación
- `mariadb/` contiene los ficheros de la base de datos
- `compose/` contiene el `compose.yaml` y el `.env` del stack, necesarios para recrear el servicio con la misma configuración
- `hd2t` se usa solo como destino de backup y exportación, no como almacenamiento activo del servicio

## Backup
Qué respaldar en este servicio:

- el directorio `/home/<usuario>/homelab/data/bookstack/config/`
- el directorio `/home/<usuario>/homelab/data/bookstack/mariadb/` o, preferiblemente, un dump lógico de MariaDB
- el directorio `/home/<usuario>/homelab/compose/bookstack/`

Preparar el destino local de backup:

```bash
mkdir -p /mnt/hd2t/backups/bookstack
```

Ejemplo de backup manual:

```bash
mkdir -p /mnt/hd2t/backups/bookstack

docker exec bookstack-db mariadb-dump \
  -u root \
  -p'<password-root-mariadb>' \
  --single-transaction \
  --quick \
  --lock-tables=false \
  bookstack > /mnt/hd2t/backups/bookstack/bookstack-$(date +%F).sql

rsync -a /home/<usuario>/homelab/compose/bookstack/ /mnt/hd2t/backups/bookstack/compose/
rsync -a /home/<usuario>/homelab/data/bookstack/config/ /mnt/hd2t/backups/bookstack/config/
```

Notas de backup:

- para una restauración limpia suele ser más práctico combinar `dump` de MariaDB + copia del directorio `config/`
- conserva la `APP_KEY`; si la pierdes y recreas otra, habrá datos cifrados que dejarán de poder descifrarse correctamente
- si usas temas personalizados o assets propios en `config/`, deben entrar también en la copia
- valida periódicamente que puedes restaurar el dump en un entorno de prueba

## Referencias
- Documentación oficial de BookStack: `https://www.bookstackapp.com/docs/`
- Instalación y requisitos: `https://www.bookstackapp.com/docs/admin/installation/`
- Backup y restore de BookStack: `https://www.bookstackapp.com/docs/admin/backup-restore/`
- Imagen Docker de LinuxServer para BookStack: `https://docs.linuxserver.io/images/docker-bookstack/`
- Imagen Docker oficial de MariaDB: `https://hub.docker.com/_/mariadb`
