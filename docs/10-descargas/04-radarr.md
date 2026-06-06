# Radarr

## Descripción

**Radarr** es el gestor de películas del homelab. Su función es vigilar RSS y búsquedas, enviar descargas al cliente torrent y mover o enlazar automáticamente las películas terminadas hacia la biblioteca final.

En esta arquitectura, Radarr sigue la misma política general del proyecto:

- la configuración, la base de datos SQLite, los logs y el estado del servicio viven en `/home/<user>/homelab/data/radarr/` sobre el **SSD NVMe**
- las descargas de entrada llegan desde `/media/hd2t/downloads/transmission/complete/`
- la biblioteca final de películas vive en `/media/hd2t/media/video/movies/`
- el acceso principal se hace desde la **LAN**
- el acceso remoto se hace por **Tailscale**, sin abrir puertos en el router
- el stack se une a la red Docker compartida `homelab_proxy` para comunicarse por nombre interno con **Transmission**, **Prowlarr** y, si lo necesitas, **Caddy**

La decisión de diseño importante aquí es que **Radarr no debe descargar directamente en la biblioteca final**. El flujo correcto es:

1. **Transmission** descarga en `hd2t`.
2. **Radarr** detecta la descarga completada.
3. **Radarr** importa la película a la biblioteca final.
4. **Jellyfin** solo consume esa biblioteca ya ordenada.

Como la zona de descargas y la biblioteca final están en el mismo disco `hd2t`, más adelante podrás usar **hardlinks** para evitar copias innecesarias y reducir I/O.

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Tener Docker Engine y Docker Compose operativos según [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber fijado la convención de stacks y `.env` descrita en [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber desplegado [01-transmission.md](01-transmission.md) para disponer del cliente de descargas.
- Haber desplegado [02-prowlarr.md](02-prowlarr.md) si quieres centralizar los indexadores.
- Haber desplegado [01-jellyfin.md](../09-multimedia/01-jellyfin.md) o, al menos, haber adoptado la misma ruta final de películas en `hd2t` bajo `/media/hd2t/media/video/movies/`.
- Haber desplegado [04-tailscale.md](../03-red/04-tailscale.md) si quieres acceder a la interfaz fuera de la LAN.
- Haber desplegado [05-caddy.md](../03-red/05-caddy.md) si quieres publicar Radarr detrás del reverse proxy interno.
- Revisar [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) para registrar el puerto publicado por el servicio.
- Tener montado `hd2t` en `/media/hd2t`.
- Tener creada la red Docker externa `homelab_proxy` si vas a seguir el patrón de integración entre stacks.
- Puertos necesarios:
  - `15003/tcp` en el host para acceso web y API desde LAN o Tailscale
  - `7878/tcp` como puerto interno del contenedor

## Docker Compose

Archivo: `/home/<user>/homelab/compose/downloads-radarr/docker-compose.yml`

```yaml
name: downloads-radarr

services:
  radarr:
    image: lscr.io/linuxserver/radarr:latest
    restart: unless-stopped
    user: "${PUID}:${PGID}"
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      PUID: ${PUID}
      PGID: ${PGID}
    ports:
      - "${RADARR_BIND_IP}:${RADARR_HTTP_PORT}:7878"
    volumes:
      - /home/<user>/homelab/data/radarr/config:/config
      - /media/hd2t/media/video/movies:/movies
      - /media/hd2t/downloads/transmission/complete:/downloads
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

- el stack queda aislado bajo `downloads-radarr`
- la base de datos y toda la persistencia del servicio viven en el **SSD NVMe**
- Radarr monta la biblioteca final y la carpeta de descargas del mismo modo que las necesita para importar sin traducciones extra de rutas
- el servicio se conecta también a `homelab_proxy` para que **Prowlarr**, **Transmission** y **Caddy** puedan alcanzarlo por nombre interno Docker
- montar `/media/hd2t/downloads/transmission/complete` como `/downloads` evita depender de `Remote Path Mappings` en el caso base

## Configuración

### 1. Preparar directorios del stack y de la biblioteca

```bash
mkdir -p /home/<user>/homelab/compose/downloads-radarr
mkdir -p /home/<user>/homelab/data/radarr/config
sudo mkdir -p /media/hd2t/media/video/movies
```

La carpeta de descargas completas ya debe existir si has seguido [01-transmission.md](01-transmission.md). No la recrees con otra estructura distinta, porque Radarr y Transmission deben ver la misma jerarquía de archivos terminados.

### 2. Ajustar propiedad y permisos

Usa el mismo usuario operativo del host que administra Docker y las carpetas del homelab:

```bash
id <user>
sudo chown -R <user>:<user> /home/<user>/homelab/data/radarr
sudo chown -R <user>:<user> /media/hd2t/media/video/movies
sudo chown -R <user>:<user> /media/hd2t/downloads/transmission/complete

sudo find /home/<user>/homelab/data/radarr -type d -exec chmod 775 {} \;
sudo find /home/<user>/homelab/data/radarr -type f -exec chmod 664 {} \;
sudo find /media/hd2t/media/video/movies -type d -exec chmod 775 {} \;
sudo find /media/hd2t/media/video/movies -type f -exec chmod 664 {} \;
sudo find /media/hd2t/downloads/transmission/complete -type d -exec chmod 775 {} \;
sudo find /media/hd2t/downloads/transmission/complete -type f -exec chmod 664 {} \;
```

La lógica operativa es esta:

- Radarr necesita escribir en `/config`
- Radarr necesita leer las descargas terminadas y escribir en la biblioteca final
- si el mismo `PUID` y `PGID` se usan en Radarr y Transmission, la importación y los hardlinks funcionan con mucha menos fricción
- usar la carpeta `complete/` evita que Radarr intente importar ficheros aún incompletos

### 3. Crear el fichero `.env`

Archivo: `/home/<user>/homelab/compose/downloads-radarr/.env`

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000
RADARR_BIND_IP=0.0.0.0
RADARR_HTTP_PORT=15003
PROXY_NETWORK=homelab_proxy
```

Notas prácticas:

- `PUID` y `PGID` deben coincidir con el usuario real del host
- `RADARR_BIND_IP=0.0.0.0` deja la interfaz accesible desde la LAN y desde la IP Tailscale del host
- si prefieres exponerla solo detrás de Caddy, puedes publicar `127.0.0.1:15003`

### 4. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/downloads-radarr
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=50 radarr
```

Validaciones útiles:

```bash
ss -ltnp | grep 15003
curl -I http://127.0.0.1:15003
```

Si todo ha arrancado bien, la interfaz quedará disponible por acceso directo en:

- `http://IP_DE_LA_PI:15003`
- `http://pi-homelab.<tailnet>.ts.net:15003` desde dispositivos unidos a Tailscale

Y, si ya tienes Caddy operativo:

- `http://radarr.lan`

### 5. Primer arranque y endurecimiento básico

En el primer arranque:

1. Abre la interfaz web.
2. Ve a `Settings` y activa `Show Advanced`.
3. En `Settings` -> `General`, activa autenticación si la interfaz va a quedar accesible desde LAN o Tailscale.
4. Comprueba que la `API Key` existe y toma nota de ella; la necesitarás para integrarlo con Prowlarr.
5. Verifica en `System` -> `Status` que no aparecen errores de permisos ni de base de datos.

Rutas relevantes dentro del contenedor:

- configuración persistente: `/config`
- biblioteca final de películas: `/movies`
- zona de descargas observada por Radarr: `/downloads`

### 6. Configurar rutas y gestión de medios

El primer ajuste importante de Radarr es dejar claras las dos zonas del flujo:

- **entrada**: `/downloads`
- **salida**: `/movies`

Pasos recomendados:

1. Ve a `Settings` -> `Media Management`.
2. Activa `Rename Movies`.
3. Activa `Create Empty Movie Folders`.
4. Activa `Use Hardlinks instead of Copy` si aparece disponible.
5. Activa `Import Extra Files` solo si realmente quieres conservar subtítulos u otros adjuntos de las releases.
6. En `Movies` -> `Add New`, selecciona como root folder `/movies`.

Recomendación práctica de nombres:

- usa un patrón sencillo y estable
- evita formatos demasiado recargados mientras validas el flujo base

Ejemplo razonable:

- carpeta de película: `{Movie Title} ({Release Year})`
- archivo de película: `{Movie Title} ({Release Year}) [{Quality Full}]`

La clave aquí es que Radarr ordene la biblioteca final y no deje películas sueltas o con nombres inconsistentes para Jellyfin.

### 7. Integrar Transmission como cliente de descargas

En `Settings` -> `Download Clients`, añade **Transmission** con los parámetros del stack descrito en [01-transmission.md](01-transmission.md).

Valores recomendados:

- nombre: `Transmission`
- host: `transmission`
- puerto: `9091`
- `Use SSL`: desactivado
- usuario y contraseña: los definidos en el `.env` de Transmission
- categoría, etiqueta o directorio dedicado: úsalo solo si tu versión de Transmission y tu flujo realmente lo soportan; el caso base funciona sin depender de esa separación lógica

Buenas prácticas al guardar:

1. Activa `Completed Download Handling`.
2. Pulsa `Test`.
3. Comprueba que Radarr puede ver correctamente las descargas terminadas bajo `/downloads`.

Punto importante de diseño:

- como Transmission expone las descargas completas en `/downloads/complete` y Radarr monta esa misma ruta del host como `/downloads`, en el despliegue base **no necesitas `Remote Path Mapping`**
- si en el futuro cambias las rutas internas y cada contenedor ve las descargas con un path distinto, entonces sí tendrás que añadir ese mapeo manualmente

### 8. Integrar Prowlarr para los indexadores

Si ya has completado [02-prowlarr.md](02-prowlarr.md), la integración correcta se hace desde **Prowlarr**, no creando indexadores a mano en Radarr.

Flujo recomendado:

1. Copia la `API Key` de Radarr.
2. Entra en Prowlarr -> `Settings` -> `Apps`.
3. Añade la app `Radarr`.
4. Usa como `Application Server` la URL interna `http://radarr:7878`.
5. Pega la `API Key` y ejecuta `Test`.
6. Guarda y confirma que los indexadores aparecen en Radarr con el sufijo `(Prowlarr)`.

No mezcles dos fuentes de verdad:

- si Prowlarr va a gestionar los indexadores, evita mantener indexadores manuales en Radarr
- si ya existían entradas manuales, desactívalas primero y elimina después las que queden duplicadas

### 9. Perfil inicial recomendado de calidad

Radarr permite afinar mucho, pero para este homelab conviene empezar con un perfil simple y útil en lugar de intentar modelar todos los casos desde el primer día.

Perfil inicial recomendado para cine general:

- nombre: `Movies HD`
- calidades permitidas:
  - `HDTV-720p`
  - `WEBDL-720p`
  - `WEBRip-720p`
  - `HDTV-1080p`
  - `WEBDL-1080p`
  - `WEBRip-1080p`
  - `Bluray-1080p`
- `Upgrade Until`: `Bluray-1080p`
- actualizaciones: activadas hasta alcanzar el `cutoff`

Por qué este perfil suele funcionar bien:

- evita crecer demasiado rápido hacia 4K, algo poco razonable para una Raspberry Pi 5 y para una biblioteca doméstica generalista
- prioriza fuentes muy comunes y compatibles con reproducción local
- mantiene un equilibrio razonable entre calidad visual, espacio ocupado en `hd2t` y tiempo de descarga

Qué dejar para más adelante:

- `Custom Formats` complejos
- puntuaciones finas por codec, edición o release group
- perfiles especiales para remux, cine clásico o colecciones 4K

Primero valida el flujo completo de indexador -> descarga -> importación -> biblioteca -> reproducción.

### 10. Añadir películas y validar el flujo completo

Prueba primero con una sola película antes de poblar toda la biblioteca.

Pasos recomendados:

1. Añade una película en `Movies` -> `Add New`.
2. Asigna el root folder `/movies`.
3. Elige el perfil `Movies HD`.
4. Confirma que Radarr ve los indexadores sincronizados desde Prowlarr.
5. Lanza una búsqueda manual.
6. Verifica que el envío llega a Transmission.
7. Espera a que finalice la descarga.
8. Comprueba que Radarr importa la película a `/movies`.
9. Confirma en Jellyfin que el contenido aparece en la biblioteca de películas.

Si en este punto algo falla, revisa primero:

- permisos de escritura sobre `/movies`
- visibilidad de las descargas dentro de `/downloads`
- conectividad entre `radarr`, `transmission` y `prowlarr` en la red Docker

## Almacenamiento

Rutas persistentes del servicio:

- Compose: `/home/<user>/homelab/compose/downloads-radarr/docker-compose.yml`
- Variables del stack: `/home/<user>/homelab/compose/downloads-radarr/.env`
- Configuración, base de datos y logs: `/home/<user>/homelab/data/radarr/config`
- Biblioteca final de películas: `/media/hd2t/media/video/movies`
- Descargas observadas para importación: `/media/hd2t/downloads/transmission/complete`

Criterio de almacenamiento:

- todo lo operativo de Radarr vive en el **SSD NVMe**
- la biblioteca final de películas vive en `hd2t`
- las descargas de entrada también viven en `hd2t`
- mantener descargas y biblioteca final en el mismo disco permite usar **hardlinks** y reduce copias completas de archivos

## Backup

Respaldar como mínimo:

- `/home/<user>/homelab/compose/downloads-radarr/docker-compose.yml`
- `/home/<user>/homelab/compose/downloads-radarr/.env`
- `/home/<user>/homelab/data/radarr/config`

Eso cubre:

- la base de datos de Radarr
- películas monitorizadas y su estado
- perfiles de calidad
- clientes de descarga
- configuración de indexadores recibida desde Prowlarr

La biblioteca final en `/media/hd2t/media/video/movies` forma parte de la estrategia general de backup del contenido multimedia, no del backup de la **aplicación** Radarr en sí.

Para una copia más consistente, detén brevemente el contenedor durante el backup:

```bash
cd /home/<user>/homelab/compose/downloads-radarr
docker compose stop radarr
# ejecutar backup
docker compose start radarr
```

Esto reduce el riesgo de capturar la base de datos SQLite en mitad de una escritura.

## Referencias

- Documentación oficial de Radarr: https://radarr.video/
- Wiki oficial de Radarr: https://wiki.servarr.com/radarr
- Guía oficial de inicio rápido de Radarr: https://wiki.servarr.com/radarr/quick-start-guide
- Documentación de la imagen Docker de LinuxServer: https://docs.linuxserver.io/images/docker-radarr/
- Repositorio oficial de Radarr: https://github.com/Radarr/Radarr
- Repositorio oficial de la imagen Docker de LinuxServer: https://github.com/linuxserver/docker-radarr
