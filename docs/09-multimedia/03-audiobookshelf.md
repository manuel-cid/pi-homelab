# Audiobookshelf

## Descripción

**Audiobookshelf** es el servidor del homelab para **audiolibros** y **podcasts**, con seguimiento de progreso por usuario, metadatos, carátulas, marcadores y clientes web o móviles. En esta arquitectura se despliega como stack Docker propio, con los **datos operativos en el SSD NVMe** y la **biblioteca de contenidos en `hd2t`**.

La política de almacenamiento de este proyecto se mantiene igual que en el resto de servicios:

- la configuración, el estado del servicio, la metadata descargada y la base de datos viven en `/home/<user>/homelab/data/audiobookshelf/` sobre el **SSD NVMe**
- la biblioteca de audiolibros y podcasts vive en `/media/hd2t/audiobookshelf/data/`
- el acceso principal se hace desde la **LAN**
- el acceso remoto se hace por **Tailscale**, sin abrir puertos en el router
- **Caddy** puede usarse como reverse proxy interno según [05-caddy.md](../03-red/05-caddy.md)

Audiobookshelf encaja bien en este homelab porque separa bien el **contenido multimedia** de la **metadata y el estado de lectura/escucha**. Eso permite mantener los ficheros grandes en `hd2t` y dejar en el SSD NVMe lo sensible al rendimiento: base de datos, índices, progreso de reproducción y carátulas.

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Tener Docker Engine y Docker Compose operativos según [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber fijado la convención de stacks y `.env` descrita en [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber desplegado [04-tailscale.md](../03-red/04-tailscale.md) si quieres acceso remoto seguro.
- Haber desplegado [05-caddy.md](../03-red/05-caddy.md) si quieres publicar Audiobookshelf detrás del reverse proxy interno.
- Revisar [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) para registrar el puerto publicado por el servicio.
- Tener montado `hd2t` en `/media/hd2t`.
- Tener creada la red Docker externa `homelab_proxy` si vas a seguir el patrón de publicación detrás de Caddy.
- Puertos necesarios:
  - `13378/tcp` en el host para acceso web y API desde LAN o Tailscale
  - `80/tcp` como puerto interno del contenedor

## Docker Compose

Archivo: `/home/<user>/homelab/compose/media-audiobookshelf/docker-compose.yml`

```yaml
name: media-audiobookshelf

services:
  audiobookshelf:
    image: ghcr.io/advplyr/audiobookshelf:latest
    restart: unless-stopped
    user: "${PUID}:${PGID}"
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    ports:
      - "${AUDIOBOOKSHELF_BIND_IP}:${AUDIOBOOKSHELF_HTTP_PORT}:80"
    volumes:
      - /media/hd2t/audiobookshelf/data/audiobooks:/audiobooks:ro
      - /media/hd2t/audiobookshelf/data/podcasts:/podcasts
      - /home/<user>/homelab/data/audiobookshelf/metadata:/metadata
      - /home/<user>/homelab/data/audiobookshelf/config:/config
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

- el stack queda aislado bajo `media-audiobookshelf`
- `config/` y `metadata/` persisten en el **SSD NVMe**
- la biblioteca multimedia vive en `hd2t`
- los audiolibros se montan en modo lectura para reducir riesgo de borrados o cambios accidentales
- la carpeta de podcasts se deja con escritura para permitir descargas o gestión desde Audiobookshelf si decides usar esa función
- el servicio se conecta también a `homelab_proxy` para que **Caddy** pueda alcanzarlo por nombre interno Docker

## Configuración

### 1. Preparar directorios del stack y de la biblioteca

```bash
mkdir -p /home/<user>/homelab/compose/media-audiobookshelf
mkdir -p /home/<user>/homelab/data/audiobookshelf/{config,metadata}
sudo mkdir -p /media/hd2t/audiobookshelf/data/{audiobooks,podcasts}
```

Una organización razonable de la biblioteca puede ser:

```bash
sudo mkdir -p /media/hd2t/audiobookshelf/data/audiobooks/{fiction,non-fiction,courses}
sudo mkdir -p /media/hd2t/audiobookshelf/data/podcasts/{subscriptions,archives}
```

No es obligatorio seguir ese esquema exacto, pero sí conviene mantener una estructura estable para que las bibliotecas y los escaneos sean previsibles.

### 2. Ajustar propiedad y permisos

Usa el mismo usuario operativo del host que administra Docker y las carpetas del homelab:

```bash
id <user>
sudo chown -R <user>:<user> /home/<user>/homelab/data/audiobookshelf
sudo chown -R <user>:<user> /media/hd2t/audiobookshelf

sudo find /home/<user>/homelab/data/audiobookshelf -type d -exec chmod 775 {} \;
sudo find /home/<user>/homelab/data/audiobookshelf -type f -exec chmod 664 {} \;
sudo find /media/hd2t/audiobookshelf -type d -exec chmod 755 {} \;
sudo find /media/hd2t/audiobookshelf -type f -exec chmod 644 {} \;
sudo chmod 775 /media/hd2t/audiobookshelf/data/podcasts
```

La idea es simple:

- Audiobookshelf necesita escritura en `config/` y `metadata/`
- la biblioteca de audiolibros no necesita permisos de escritura desde el contenedor en un despliegue base
- si quieres que Audiobookshelf descargue o gestione podcasts, la carpeta `podcasts/` sí debe permanecer escribible

Si prefieres no usar descargas de podcasts desde Audiobookshelf y solo vas a indexar ficheros existentes, puedes montar también `/podcasts` en modo lectura.

### 3. Crear el fichero `.env`

Archivo: `/home/<user>/homelab/compose/media-audiobookshelf/.env`

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000
AUDIOBOOKSHELF_BIND_IP=0.0.0.0
AUDIOBOOKSHELF_HTTP_PORT=13378
PROXY_NETWORK=homelab_proxy
```

Notas prácticas:

- `PUID` y `PGID` deben coincidir con el usuario real del host
- `AUDIOBOOKSHELF_BIND_IP=0.0.0.0` deja el servicio accesible desde la LAN y también desde la IP Tailscale del host
- si prefieres acceso solo detrás de Caddy, puedes publicar `127.0.0.1:13378`

### 4. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/media-audiobookshelf
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=50 audiobookshelf
```

Validaciones útiles:

```bash
ss -ltnp | grep 13378
curl -I http://127.0.0.1:13378
```

Si todo ha arrancado bien, la interfaz quedará disponible por acceso directo en:

- `http://IP_DE_LA_PI:13378`
- `http://pi-homelab.<tailnet>.ts.net:13378` desde dispositivos unidos a Tailscale

Y, si ya tienes Caddy operativo:

- `http://audiobookshelf.lan`

### 5. Primer arranque y creación de bibliotecas

En el primer arranque:

1. Abre la interfaz web.
2. Crea la cuenta administradora inicial.
3. Añade una biblioteca de tipo **Audiobooks** apuntando a `/audiobooks`.
4. Añade una biblioteca de tipo **Podcasts** apuntando a `/podcasts` si la vas a usar.
5. Verifica que el escaneo inicial encuentra correctamente los archivos.

Rutas típicas dentro del contenedor:

- audiolibros: `/audiobooks`
- podcasts: `/podcasts`
- metadata: `/metadata`
- configuración y base de datos: `/config`

Como la metadata descargada, los usuarios y el progreso de escucha viven en el SSD NVMe, no hace falta guardar esa información junto a los ficheros multimedia del disco USB.

### 6. Ajustes recomendados tras el alta inicial

Puntos prácticos a revisar después del primer acceso:

- confirma idioma, zona horaria y comportamiento del escaneo automático
- revisa que los metadatos de autores, series y capítulos se están resolviendo bien
- si importas podcasts, valida la política de descarga para no llenar `hd2t` sin control
- revisa el intervalo de escaneo si tu biblioteca es grande o si el disco USB entra en reposo

Recomendación operativa:

- para la **LAN**, usa `http://audiobookshelf.lan` o acceso directo a `:13378`
- para acceso remoto sencillo, Tailscale directo a `:13378` suele ser la opción más simple
- usa Caddy delante de Audiobookshelf cuando quieras centralizar nombres internos del homelab

### 7. Organización de la biblioteca y buenas prácticas

Audiobookshelf funciona mejor cuando cada libro o podcast está bien separado y con nombres consistentes.

Conviene mantener:

- un directorio por libro o por colección si el contenido ocupa varios ficheros
- nombres estables y sin mezclar audiolibros con podcasts en la misma raíz
- carátulas y archivos auxiliares, si existen, junto al contenido correspondiente

En podcasts:

- si Audiobookshelf va a descargar episodios, controla retención y limpieza periódica
- si los podcasts se importan desde otra herramienta o por copia manual, evita que varias aplicaciones escriban en la misma carpeta al mismo tiempo

## Almacenamiento

Rutas persistentes del servicio:

- Compose: `/home/<user>/homelab/compose/media-audiobookshelf/docker-compose.yml`
- Variables del stack: `/home/<user>/homelab/compose/media-audiobookshelf/.env`
- Configuración, base de datos y usuarios: `/home/<user>/homelab/data/audiobookshelf/config`
- Metadata descargada, carátulas e índices: `/home/<user>/homelab/data/audiobookshelf/metadata`
- Biblioteca de audiolibros: `/media/hd2t/audiobookshelf/data/audiobooks`
- Biblioteca de podcasts: `/media/hd2t/audiobookshelf/data/podcasts`

Criterio de almacenamiento:

- todo lo operativo de Audiobookshelf vive en el **SSD NVMe**
- `hd2t` solo almacena los ficheros multimedia
- no se guarda base de datos ni metadata operativa en discos USB

## Backup

Respaldar como mínimo:

- `/home/<user>/homelab/compose/media-audiobookshelf/docker-compose.yml`
- `/home/<user>/homelab/compose/media-audiobookshelf/.env`
- `/home/<user>/homelab/data/audiobookshelf/config`
- `/home/<user>/homelab/data/audiobookshelf/metadata`

La biblioteca de `/media/hd2t/audiobookshelf/data/` no forma parte del backup de la aplicación en sí; es el **contenido multimedia** y debe tratarse según la estrategia general de copias del homelab.

Para una copia más consistente de la base de datos interna, detén brevemente el contenedor durante el backup:

```bash
cd /home/<user>/homelab/compose/media-audiobookshelf
docker compose stop audiobookshelf
# ejecutar backup
docker compose start audiobookshelf
```

Si el volumen de `metadata/` crece mucho, sigue siendo prioritario respaldarlo: ahí vive buena parte del trabajo de catalogación, carátulas y enriquecimiento de la biblioteca.

## Referencias

- Documentación oficial de Audiobookshelf: https://www.audiobookshelf.org/docs
- Guía oficial de instalación en Docker: https://www.audiobookshelf.org/guides/docker-install
- Repositorio oficial con ejemplo de `docker-compose.yml`: https://github.com/advplyr/audiobookshelf/blob/master/docker-compose.yml
- Imagen oficial Docker en GHCR: https://github.com/advplyr/audiobookshelf/pkgs/container/audiobookshelf
