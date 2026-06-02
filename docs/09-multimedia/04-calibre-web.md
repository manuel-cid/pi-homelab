# Calibre-Web

## Descripción

**Calibre-Web** es la interfaz web del homelab para **explorar, leer y descargar ebooks** a partir de una **biblioteca Calibre existente**. En esta arquitectura se despliega como stack Docker propio, con los **datos operativos en el SSD NVMe** y la **biblioteca de libros en `hd2t`**.

La política de este proyecto se mantiene igual que en el resto de servicios multimedia:

- la configuración, la base de datos interna de la aplicación y el estado del servicio viven en `/home/<user>/homelab/data/calibre-web/` sobre el **SSD NVMe**
- la biblioteca de ebooks vive en `/mnt/hd2t/media/calibre-web/library/`
- el acceso principal se hace desde la **LAN**
- el acceso remoto se hace por **Tailscale**, sin abrir puertos en el router
- **Caddy** puede usarse como reverse proxy interno según [05-caddy.md](../03-red/05-caddy.md)

Calibre-Web no sustituye a **Calibre** como gestor completo de biblioteca. En este homelab conviene entenderlo como una capa web sobre una biblioteca que ya existe y cuyo índice principal es el fichero `metadata.db`.

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Tener Docker Engine y Docker Compose operativos según [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber fijado la convención de stacks y `.env` descrita en [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber desplegado [04-tailscale.md](../03-red/04-tailscale.md) si quieres acceso remoto seguro.
- Haber desplegado [05-caddy.md](../03-red/05-caddy.md) si quieres publicar Calibre-Web detrás del reverse proxy interno.
- Revisar [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) para registrar el puerto publicado por el servicio.
- Tener montado `hd2t` en `/mnt/hd2t`.
- Tener creada la red Docker externa `homelab_proxy` si vas a seguir el patrón de publicación detrás de Caddy.
- Tener preparada una biblioteca Calibre válida en `hd2t`, con `metadata.db` en la raíz de la carpeta que vayas a montar.
- Puertos necesarios:
  - `14003/tcp` en el host para acceso web desde LAN o Tailscale
  - `8083/tcp` como puerto interno del contenedor

## Docker Compose

Archivo: `/home/<user>/homelab/compose/media-calibre-web/docker-compose.yml`

```yaml
name: media-calibre-web

services:
  calibre-web:
    image: lscr.io/linuxserver/calibre-web:latest
    restart: unless-stopped
    user: "${PUID}:${PGID}"
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    ports:
      - "${CALIBRE_WEB_BIND_IP}:${CALIBRE_WEB_HTTP_PORT}:8083"
    volumes:
      - /home/<user>/homelab/data/calibre-web/config:/config
      - /mnt/hd2t/media/calibre-web/library:/books:ro
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

- el stack queda aislado bajo `media-calibre-web`
- `config/` persiste en el **SSD NVMe**
- la biblioteca Calibre vive en `hd2t`
- la biblioteca se monta en modo lectura para reducir el riesgo de corromper `metadata.db` o mezclar escrituras concurrentes con otras herramientas
- el servicio se conecta también a `homelab_proxy` para que **Caddy** pueda alcanzarlo por nombre interno Docker
- este despliegue base no habilita conversión avanzada de ebooks dentro del contenedor; en una Raspberry Pi 5 conviene asumir un rol de catálogo y lectura web, no de pipeline pesado de conversión

## Configuración

### 1. Preparar directorios del stack y de la biblioteca

```bash
mkdir -p /home/<user>/homelab/compose/media-calibre-web
mkdir -p /home/<user>/homelab/data/calibre-web/config
sudo mkdir -p /mnt/hd2t/media/calibre-web/library
```

Si quieres separar mejor entradas y exportaciones, puedes añadir carpetas auxiliares fuera de la biblioteca principal:

```bash
sudo mkdir -p /mnt/hd2t/media/calibre-web/{import,exports}
```

La carpeta importante para Calibre-Web es `library/`: ahí debe existir el fichero `metadata.db` en el nivel superior.

### 2. Importar o mover una biblioteca Calibre existente

Si ya gestionas tus ebooks con **Calibre** en otro equipo, copia o sincroniza la biblioteca completa a:

```bash
/mnt/hd2t/media/calibre-web/library
```

Validación mínima:

```bash
ls -lah /mnt/hd2t/media/calibre-web/library/metadata.db
find /mnt/hd2t/media/calibre-web/library -maxdepth 2 -type d | head
```

Puntos importantes:

- copia la **biblioteca completa**, no solo los ficheros `.epub`, `.pdf` o `.mobi`
- `metadata.db` debe quedar en la raíz de `library/`
- cada libro suele vivir en subcarpetas organizadas por autor y título; no reestructures eso manualmente si ya proviene de Calibre

Si todavía no tienes biblioteca Calibre, créala primero con la aplicación de escritorio y mueve esa biblioteca al directorio anterior antes de configurar Calibre-Web.

### 3. Ajustar propiedad y permisos

Usa el mismo usuario operativo del host que administra Docker y las carpetas del homelab:

```bash
id <user>
sudo chown -R <user>:<user> /home/<user>/homelab/data/calibre-web
sudo chown -R <user>:<user> /mnt/hd2t/media/calibre-web

sudo find /home/<user>/homelab/data/calibre-web -type d -exec chmod 775 {} \;
sudo find /home/<user>/homelab/data/calibre-web -type f -exec chmod 664 {} \;
sudo find /mnt/hd2t/media/calibre-web/library -type d -exec chmod 755 {} \;
sudo find /mnt/hd2t/media/calibre-web/library -type f -exec chmod 644 {} \;
```

La lógica base es:

- Calibre-Web necesita escritura en `config/`
- la biblioteca montada como `/books` no necesita escritura desde el contenedor en el despliegue recomendado

Si gestionas la biblioteca mediante Samba desde otros equipos, adapta permisos y grupo del host a esa política, pero conserva el montaje `:ro` en Docker mientras no quieras permitir escrituras desde Calibre-Web.

### 4. Crear el fichero `.env`

Archivo: `/home/<user>/homelab/compose/media-calibre-web/.env`

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000
CALIBRE_WEB_BIND_IP=0.0.0.0
CALIBRE_WEB_HTTP_PORT=14003
PROXY_NETWORK=homelab_proxy
```

Notas prácticas:

- `PUID` y `PGID` deben coincidir con el usuario real del host
- `CALIBRE_WEB_BIND_IP=0.0.0.0` deja el servicio accesible desde la LAN y también desde la IP Tailscale del host
- si prefieres acceso solo detrás de Caddy, puedes publicar `127.0.0.1:14003`

### 5. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/media-calibre-web
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=50 calibre-web
```

Validaciones útiles:

```bash
ss -ltnp | grep 14003
curl -I http://127.0.0.1:14003
```

Si todo ha arrancado bien, la interfaz quedará disponible por acceso directo en:

- `http://IP_DE_LA_PI:14003`
- `http://pi-homelab.<tailnet>.ts.net:14003` desde dispositivos unidos a Tailscale

Y, si ya tienes Caddy operativo:

- `http://calibre-web.lan`

### 6. Primer arranque e importación desde Calibre

En el primer arranque:

1. Abre la interfaz web.
2. Inicia sesión con el usuario por defecto `admin` y la contraseña `admin123`.
3. Cuando se pida la ubicación de la biblioteca, introduce `/books`.
4. Guarda la configuración y verifica que aparecen los libros de `metadata.db`.
5. Cambia inmediatamente la contraseña del usuario administrador.

Rutas relevantes dentro del contenedor:

- biblioteca Calibre: `/books`
- configuración y base interna de Calibre-Web: `/config`

Si no aparecen libros:

- revisa que `metadata.db` exista en `/mnt/hd2t/media/calibre-web/library/`
- confirma que la ruta configurada en la interfaz es `/books`
- valida permisos de lectura sobre la biblioteca

### 7. Ajustes recomendados tras el alta inicial

Puntos prácticos a revisar después del primer acceso:

- cambia credenciales por defecto y crea usuarios separados si varias personas van a usar el servicio
- revisa idioma, zona horaria y opciones de interfaz
- habilita **OPDS** solo si realmente lo vas a consumir desde lectores o apps compatibles
- valida descargas, lectura en navegador y visualización de portadas con varios formatos reales de tu biblioteca

Recomendación operativa:

- para la **LAN**, usa `http://calibre-web.lan` o acceso directo a `:14003`
- para acceso remoto sencillo, Tailscale directo a `:14003` suele ser la opción más simple
- usa Caddy delante de Calibre-Web cuando quieras centralizar nombres internos del homelab

### 8. Política recomendada de importación y escritura

En este homelab conviene separar responsabilidades:

- usa **Calibre** de escritorio como herramienta principal para importar masivamente, limpiar metadatos, convertir formatos y reorganizar la biblioteca
- usa **Calibre-Web** como interfaz de consulta, lectura, descarga y administración ligera
- evita editar la misma biblioteca al mismo tiempo desde Calibre, Calibre-Web y un cliente de archivos por Samba

Por eso el Compose propuesto monta `/books` en solo lectura.

Si más adelante quieres permitir subidas o cambios de metadatos directamente desde Calibre-Web:

1. elimina `:ro` del bind mount `/mnt/hd2t/media/calibre-web/library:/books:ro`
2. reinicia el stack
3. establece una política clara de **un solo escritor a la vez** sobre esa biblioteca

No conviertas el modo lectura-escritura en el comportamiento por defecto salvo que realmente necesites esas funciones y controles bien cómo se modifica la biblioteca.

### 9. Conversión de ebooks en Raspberry Pi 5

Calibre-Web puede integrarse con binarios externos para conversión, pero este despliegue no lo da por hecho.

En una Raspberry Pi 5 conviene asumir estas limitaciones:

- el caso base del homelab es **catálogo web + descarga + lectura**, no conversión pesada dentro del contenedor
- la capa opcional habitual para añadir binarios de Calibre en la imagen de LinuxServer está orientada a `x86-64`, no a este despliegue ARM64
- si necesitas conversiones complejas, es más sensato hacerlas desde Calibre de escritorio y luego sincronizar la biblioteca resultante a `hd2t`

## Almacenamiento

Rutas persistentes del servicio:

- Compose: `/home/<user>/homelab/compose/media-calibre-web/docker-compose.yml`
- Variables del stack: `/home/<user>/homelab/compose/media-calibre-web/.env`
- Configuración, base interna y estado del servicio: `/home/<user>/homelab/data/calibre-web/config`
- Biblioteca de ebooks: `/mnt/hd2t/media/calibre-web/library`
- Entrada manual opcional: `/mnt/hd2t/media/calibre-web/import`
- Exportaciones manuales opcionales: `/mnt/hd2t/media/calibre-web/exports`

Criterio de almacenamiento:

- todo lo operativo de Calibre-Web vive en el **SSD NVMe**
- `hd2t` almacena la biblioteca real de ebooks
- el fichero `metadata.db` y los formatos de libro asociados forman parte de la biblioteca en `hd2t`
- no se guarda la configuración interna del servicio en discos USB

## Backup

Respaldar como mínimo:

- `/home/<user>/homelab/compose/media-calibre-web/docker-compose.yml`
- `/home/<user>/homelab/compose/media-calibre-web/.env`
- `/home/<user>/homelab/data/calibre-web/config`
- `/mnt/hd2t/media/calibre-web/library`

Aquí conviene hacer una distinción importante:

- `config/` contiene la configuración de Calibre-Web, usuarios, preferencias y base interna propia del servicio
- `library/` contiene la **biblioteca real** de ebooks, incluido `metadata.db`, así que también es crítica y no puede tratarse como simple contenido prescindible

Para una copia más consistente:

```bash
cd /home/<user>/homelab/compose/media-calibre-web
docker compose stop calibre-web
# ejecutar backup
docker compose start calibre-web
```

Si la biblioteca también se modifica desde Calibre de escritorio, evita hacer backup mientras esa biblioteca esté siendo editada en otro equipo.

## Referencias

- Documentación oficial de Calibre-Web: https://github.com/janeczku/calibre-web
- Wiki oficial de Calibre-Web: https://github.com/janeczku/calibre-web/wiki
- Imagen Docker de LinuxServer para Calibre-Web: https://github.com/linuxserver/docker-calibre-web
- Manual oficial de calibre sobre bibliotecas y `metadata.db`: https://manual.calibre-ebook.com/faq.html
