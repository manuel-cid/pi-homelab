# Calibre-Web

## Descripción

**Calibre-Web** es la interfaz web del homelab para **explorar, leer y descargar ebooks** a partir de una **biblioteca Calibre existente**. En esta arquitectura se despliega como stack Docker propio, con los **datos operativos en el SSD NVMe** y la **biblioteca de libros en `hd2t`**.

La política de este proyecto se mantiene igual que en el resto de servicios multimedia:

- la configuración, la base de datos interna de la aplicación y el estado del servicio viven en `/home/<user>/homelab/data/calibre-web/` sobre el **SSD NVMe**
- la biblioteca de ebooks vive en `/media/hd2t/media/books/calibre-library/`
- el acceso principal se hace desde la **LAN** a través de **Caddy**
- el acceso remoto se hace por **Tailscale** a través de **Caddy**, sin abrir puertos en el router
- el puerto directo en el host queda publicado solo en `127.0.0.1:14003` como upstream local para **Caddy** y como opción de bootstrap o diagnóstico desde la propia Raspberry Pi
- **Caddy** debe usar `127.0.0.1:14003` como upstream, siguiendo el patrón general descrito en [05-caddy.md](../03-red/05-caddy.md)

Calibre-Web no sustituye a **Calibre** como gestor completo de biblioteca. En este homelab conviene entenderlo como una capa web sobre una biblioteca que ya existe y cuyo índice principal es el fichero `metadata.db`.

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Tener Docker Engine y Docker Compose operativos según [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber fijado la convención de stacks y `.env` descrita en [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber desplegado [04-tailscale.md](../03-red/04-tailscale.md) si quieres acceso remoto seguro.
- Haber desplegado [05-caddy.md](../03-red/05-caddy.md) si quieres publicar Calibre-Web detrás del reverse proxy interno.
- Añadir en tu `Caddyfile` un bloque dedicado para `http://calibre-web.lan` si vas a seguir el patrón de hostname interno del homelab.
- Revisar [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) para registrar el puerto publicado por el servicio.
- Tener montado `hd2t` en `/media/hd2t`.
- Tener preparada una biblioteca Calibre válida en `hd2t`, con `metadata.db` en la raíz de la carpeta que vayas a montar.
- Puertos necesarios:
  - `14003/tcp` publicado solo en `127.0.0.1` en el host para que **Caddy** alcance el servicio
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
      - /media/hd2t/media/books/calibre-library:/books:ro
    labels:
      - wud.watch=true
```

Notas sobre este Compose:

- el stack queda aislado bajo `media-calibre-web`
- `config/` persiste en el **SSD NVMe**
- la biblioteca Calibre vive en `hd2t`
- la biblioteca se monta en modo lectura para reducir el riesgo de corromper `metadata.db` o mezclar escrituras concurrentes con otras herramientas
- el servicio publica `14003/tcp` solo en `127.0.0.1` para que **Caddy**, al usar `network_mode: host`, lo alcance por loopback
- este despliegue base no habilita conversión avanzada de ebooks dentro del contenedor; en una Raspberry Pi 5 conviene asumir un rol de catálogo y lectura web, no de pipeline pesado de conversión
- si eliminas el bloque `ports:`, **Caddy** ya no podrá alcanzar el servicio en la arquitectura actual del repositorio

## Configuración

### 1. Preparar directorios del stack y de la biblioteca

```bash
mkdir -p /home/<user>/homelab/compose/media-calibre-web
mkdir -p /home/<user>/homelab/data/calibre-web/config
sudo mkdir -p /media/hd2t/media/books/calibre-library
```

Si quieres separar mejor entradas y exportaciones, puedes añadir carpetas auxiliares fuera de la biblioteca principal:

```bash
sudo mkdir -p /media/hd2t/media/books/{import,exports}
```

La carpeta importante para Calibre-Web es `calibre-library/`: ahí debe existir el fichero `metadata.db` en el nivel superior.

### 2. Importar o mover una biblioteca Calibre existente

Si ya gestionas tus ebooks con **Calibre** en otro equipo, copia o sincroniza la biblioteca completa a:

```bash
/media/hd2t/media/books/calibre-library
```

Validación mínima:

```bash
ls -lah /media/hd2t/media/books/calibre-library/metadata.db
find /media/hd2t/media/books/calibre-library -maxdepth 2 -type d | head
```

Puntos importantes:

- copia la **biblioteca completa**, no solo los ficheros `.epub`, `.pdf` o `.mobi`
- `metadata.db` debe quedar en la raíz de `calibre-library/`
- cada libro suele vivir en subcarpetas organizadas por autor y título; no reestructures eso manualmente si ya proviene de Calibre

Si todavía no tienes biblioteca Calibre, créala primero con la aplicación de escritorio y mueve esa biblioteca al directorio anterior antes de configurar Calibre-Web.

### 3. Ajustar propiedad y permisos

Usa el mismo usuario operativo del host que administra Docker y las carpetas del homelab:

```bash
id <user>
sudo chown -R <user>:<user> /home/<user>/homelab/data/calibre-web
sudo chown -R <user>:<user> /media/hd2t/media/books/calibre-library

sudo find /home/<user>/homelab/data/calibre-web -type d -exec chmod 775 {} \;
sudo find /home/<user>/homelab/data/calibre-web -type f -exec chmod 664 {} \;
sudo find /media/hd2t/media/books/calibre-library -type d -exec chmod 755 {} \;
sudo find /media/hd2t/media/books/calibre-library -type f -exec chmod 644 {} \;
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
CALIBRE_WEB_BIND_IP=127.0.0.1
CALIBRE_WEB_HTTP_PORT=14003
```

Notas prácticas:

- `PUID` y `PGID` deben coincidir con el usuario real del host
- `CALIBRE_WEB_BIND_IP=127.0.0.1` sigue la política general del proyecto para servicios web detrás de **Caddy**
- si cambias temporalmente a `0.0.0.0`, el servicio quedará accesible directamente desde la LAN y desde la IP Tailscale del host; registra esa excepción en [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md)

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
curl -I -H 'Host: calibre-web.lan' http://127.0.0.1
```

Si todo ha arrancado bien, la interfaz quedará disponible en:

- `http://calibre-web.lan`
- `http://127.0.0.1:14003` desde la propia Raspberry Pi, un túnel SSH o como upstream local para **Caddy**

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

- revisa que `metadata.db` exista en `/media/hd2t/media/books/calibre-library/`
- confirma que la ruta configurada en la interfaz es `/books`
- valida permisos de lectura sobre la biblioteca

### 7. Ajustes recomendados tras el alta inicial

Puntos prácticos a revisar después del primer acceso:

- cambia credenciales por defecto y crea usuarios separados si varias personas van a usar el servicio
- revisa idioma, zona horaria y opciones de interfaz
- habilita **OPDS** solo si realmente lo vas a consumir desde lectores o apps compatibles
- valida descargas, lectura en navegador y visualización de portadas con varios formatos reales de tu biblioteca

Recomendación operativa:

- para la **LAN**, usa preferentemente `http://calibre-web.lan`
- reserva el acceso directo a `127.0.0.1:14003` para bootstrap, pruebas desde la propia Raspberry Pi o diagnóstico local
- para acceso remoto, usa la publicación que definas en **Caddy** sobre Tailscale en lugar de exponer `:14003` directamente
- usa **Caddy** delante de Calibre-Web para mantener una entrada coherente con el resto de servicios web del homelab

Si vas a exponerlo por hostname interno en **Caddy**, el bloque esperado sigue el mismo patrón que otros servicios multimedia ya documentados:

```caddy
http://calibre-web.lan {
    import common_proxy
    reverse_proxy 127.0.0.1:14003
}
```

Este bloque debe añadirse al `Caddyfile` del stack de Caddy antes de dar por operativo `http://calibre-web.lan`.

### 8. Política recomendada de importación y escritura

En este homelab conviene separar responsabilidades:

- usa **Calibre** de escritorio como herramienta principal para importar masivamente, limpiar metadatos, convertir formatos y reorganizar la biblioteca
- usa **Calibre-Web** como interfaz de consulta, lectura, descarga y administración ligera
- evita editar la misma biblioteca al mismo tiempo desde Calibre, Calibre-Web y un cliente de archivos por Samba

Por eso el Compose propuesto monta `/books` en solo lectura.

Si más adelante quieres permitir subidas o cambios de metadatos directamente desde Calibre-Web:

1. elimina `:ro` del bind mount `/media/hd2t/media/books/calibre-library:/books:ro`
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
- Biblioteca de ebooks: `/media/hd2t/media/books/calibre-library`
- Entrada manual opcional: `/media/hd2t/media/books/import`
- Exportaciones manuales opcionales: `/media/hd2t/media/books/exports`

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
- `/media/hd2t/media/books/calibre-library`

Aquí conviene hacer una distinción importante:

- `config/` contiene la configuración de Calibre-Web, usuarios, preferencias y base interna propia del servicio
- `calibre-library/` contiene la **biblioteca real** de ebooks, incluido `metadata.db`, así que también es crítica y no puede tratarse como simple contenido prescindible

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
