# Prowlarr

## Descripción

**Prowlarr** es el gestor centralizado de indexadores del homelab. Su función es mantener en un solo sitio la configuración de trackers torrent y, más adelante, sincronizarlos con **Sonarr** y **Radarr** para evitar repetir la misma configuración en cada aplicación.

En esta arquitectura, Prowlarr sigue la misma política general del proyecto:

- la configuración, la base de datos SQLite, los logs y el estado del servicio viven en `/home/<user>/homelab/data/prowlarr/config/` sobre el **SSD NVMe**
- no necesita almacenar payloads ni bibliotecas en `hd2t` o `hd5t`
- el acceso principal se hace desde la **LAN**
- el acceso remoto se hace por **Tailscale**, sin abrir puertos en el router
- el stack se une a la red Docker compartida `homelab_proxy` para comunicarse por nombre interno con futuros stacks como **Sonarr** y **Radarr**

La decisión importante aquí es que **Prowlarr no descarga contenido**. Solo centraliza indexadores, categorías y sincronización hacia las aplicaciones consumidoras. Las descargas reales seguirán recayendo en **Transmission** y en los clientes que configuren **Sonarr** y **Radarr**.

Cuando este documento use placeholders como `<user>`, `IP_DE_LA_PI`, `<hostname-de-tu-pi>` o `<tailnet>`, sustitúyelos por los valores reales de tu entorno antes de ejecutar comandos o guardar configuraciones.

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Tener Docker Engine y Docker Compose operativos según [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber fijado la convención de stacks y `.env` descrita en [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber desplegado [01-transmission.md](01-transmission.md) si más adelante vas a usar búsquedas manuales desde Prowlarr con envío directo al cliente torrent.
- Haber desplegado [04-tailscale.md](../03-red/04-tailscale.md) si quieres acceder a la interfaz fuera de la LAN.
- Haber desplegado [05-caddy.md](../03-red/05-caddy.md) si quieres publicar Prowlarr detrás del reverse proxy interno.
- Revisar [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) para registrar el puerto publicado por el servicio.
- Tener creada la red Docker externa `homelab_proxy` si vas a seguir el patrón de integración entre stacks.
- Puertos necesarios:
  - `15001/tcp` en el host solo si vas a publicar acceso directo desde LAN o Tailscale
  - `9696/tcp` como puerto interno del contenedor y de integración entre contenedores

## Docker Compose

Archivo: `/home/<user>/homelab/compose/downloads-prowlarr/docker-compose.yml`

```yaml
name: downloads-prowlarr

services:
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      PUID: ${PUID}
      PGID: ${PGID}
    ports:
      - "${PROWLARR_BIND_IP}:${PROWLARR_HTTP_PORT}:9696"
    volumes:
      - /home/<user>/homelab/data/prowlarr/config:/config
    networks:
      - default
      - proxy
    labels:
      - wud.watch=true

networks:
  proxy:
    external: true
    name: ${PROXY_NETWORK}
```

Notas sobre este Compose:

- el stack queda aislado bajo `downloads-prowlarr`
- toda la persistencia del servicio vive en el **SSD NVMe**
- no se monta ningún directorio de `hd2t` ni de `hd5t` porque Prowlarr no almacena multimedia
- la imagen de LinuxServer gestiona el usuario efectivo con `PUID` y `PGID`, así que no hace falta forzar `user:` en el servicio
- el servicio se conecta también a `homelab_proxy` para que otros stacks puedan alcanzarlo por nombre interno Docker
- la API de Prowlarr queda disponible para Sonarr y Radarr a través del propio servicio `prowlarr`

## Configuración

### 1. Preparar directorios del stack y de datos

```bash
mkdir -p /home/<user>/homelab/compose/downloads-prowlarr
mkdir -p /home/<user>/homelab/data/prowlarr/config
```

Prowlarr no necesita estructura adicional en discos externos. La preparación es deliberadamente simple porque solo persiste configuración y base de datos local.

### 2. Ajustar propiedad y permisos

Usa el mismo usuario operativo del host que administra Docker y las carpetas del homelab:

```bash
id <user>
sudo chown -R <user>:<user> /home/<user>/homelab/data/prowlarr

sudo find /home/<user>/homelab/data/prowlarr -type d -exec chmod 775 {} \;
sudo find /home/<user>/homelab/data/prowlarr -type f -exec chmod 664 {} \;
```

La lógica aquí es directa:

- Prowlarr necesita escritura sobre `/config`
- la base de datos y los logs deben quedar en almacenamiento estable sobre el NVMe
- no hay ninguna razón para repartir datos de este servicio entre el SSD y los discos USB

### 3. Crear el fichero `.env`

Archivo: `/home/<user>/homelab/compose/downloads-prowlarr/.env`

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000
PROWLARR_BIND_IP=0.0.0.0
PROWLARR_HTTP_PORT=15001
PROXY_NETWORK=homelab_proxy
```

Notas prácticas:

- `PUID` y `PGID` deben coincidir con el usuario real del host
- `PROWLARR_BIND_IP=0.0.0.0` deja la interfaz accesible desde la LAN y desde la IP Tailscale del host
- si prefieres dejar la UI detrás de Caddy o limitarla a administración local del host, publica `127.0.0.1:15001`
- si no vas a exponer la interfaz web por LAN, Tailscale ni Caddy y solo quieres que Sonarr y Radarr hablen con Prowlarr por la red Docker compartida, puedes eliminar el bloque `ports:` completo y dejar Prowlarr accesible solo por nombre interno Docker
- `homelab_proxy` sirve para comunicación entre contenedores; no sustituye por sí sola la publicación web de la interfaz para usuarios

### 4. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/downloads-prowlarr
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=50 prowlarr
```

Validaciones útiles:

```bash
ss -ltnp | grep 15001
curl -I http://127.0.0.1:15001
```

Si todo ha arrancado bien, la interfaz quedará disponible por acceso directo en:

- `http://IP_DE_LA_PI:15001`
- `http://<hostname-de-tu-pi>.<tailnet>.ts.net:15001` desde dispositivos unidos a Tailscale con MagicDNS

Si tienes `ufw` activo y mantienes este acceso directo publicado en `0.0.0.0`, añade al menos estas reglas:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 15001 proto tcp comment 'Prowlarr desde LAN'
sudo ufw allow in on tailscale0 to any port 15001 proto tcp comment 'Prowlarr desde Tailscale'
```

<!-- TODO: verificar la subred LAN real antes de aplicar la regla de `ufw`; si tu red no es `192.168.1.0/24`, sustituirla por la correcta. -->

Y, si además amplías el `Caddyfile` de [05-caddy.md](../03-red/05-caddy.md) con publicación interna para este servicio, recuerda que en esta arquitectura **Caddy llega a Prowlarr por `127.0.0.1:15001` en el host**, no por nombre de contenedor en `homelab_proxy`:

- `http://prowlarr.lan`

<!-- TODO: verificar si el acceso por Caddy se publicará como subruta (por ejemplo `/prowlarr`) o mediante un hostname dedicado; si se usa subruta, ajustar `URL Base` en Prowlarr y el `Caddyfile` de forma coherente antes de dar ese acceso por válido. -->

### 5. Primer arranque y endurecimiento básico

En el primer arranque:

1. Abre la interfaz web.
2. Ve a `Settings` y activa `Show Advanced` cuando necesites ver opciones extra.
3. En `Settings` -> `General`, activa la autenticación y define credenciales si vas a dejar la UI accesible desde LAN o Tailscale.
4. Comprueba que la `API Key` existe y toma nota de ella; la necesitarás cuando conectes Sonarr y Radarr.
5. Verifica en `System` -> `Status` que no aparecen errores de permisos ni de base de datos.

Puntos prácticos:

- no hace falta tocar la base de datos manualmente; Prowlarr la inicializa en `/config`
- si publicas el servicio detrás de Caddy con hostname propio, valida también login, navegación y uso de la API antes de dar la integración por cerrada

### 6. Añadir indexadores

El flujo correcto en Prowlarr empieza por los indexadores.

Pasos recomendados:

1. Entra en `Indexers`.
2. Pulsa `+` y añade cada indexador de forma individual.
3. Para trackers o motores no listados, usa:
   - `Generic Torznab` para torrents
   - `Generic Newznab` para usenet
4. Introduce URL, credenciales y claves API según lo que exija cada indexador.
5. Ejecuta `Test` antes de guardar.

Buenas prácticas iniciales:

- empieza con pocos indexadores y verifica que todos responden antes de ampliar la lista
- usa nombres claros porque en Sonarr y Radarr aparecerán con el sufijo `(Prowlarr)`
- si un indexador solo sirve para series o solo para películas, revisa después sus categorías y el perfil de sincronización antes de propagarlo a todas las apps

### 7. Conectar Sonarr y Radarr en `Settings` -> `Apps`

Cuando tengas desplegados los stacks de [03-sonarr.md](03-sonarr.md) y [04-radarr.md](04-radarr.md), conecta ambas aplicaciones desde `Settings` -> `Apps`.

Ejemplo recomendado si todos los stacks comparten `homelab_proxy`:

- App Sonarr:
  - nombre: `Sonarr`
  - `Sync Level`: `Full Sync`
  - `Prowlarr Server`: `http://prowlarr:9696`
  - `Application Server`: `http://sonarr:8989`
  - `API Key`: la clave API de Sonarr
- App Radarr:
  - nombre: `Radarr`
  - `Sync Level`: `Full Sync`
  - `Prowlarr Server`: `http://prowlarr:9696`
  - `Application Server`: `http://radarr:7878`
  - `API Key`: la clave API de Radarr

Notas operativas importantes:

- `Full Sync` convierte Prowlarr en la fuente de verdad de los indexadores; si cambias esos indexadores directamente en Sonarr o Radarr, Prowlarr podrá sobrescribir esos cambios en la siguiente sincronización
- si prefieres una transición más conservadora, empieza con `Add and Remove Only` y pasa a `Full Sync` cuando valides el comportamiento
- si Sonarr o Radarr usan `URL Base`, inclúyela también en `Application Server`
- al guardar, Prowlarr sincronizará los indexadores compatibles por categorías; uno orientado solo a `tv` no se enviará a Radarr y uno orientado solo a `movies` no se enviará a Sonarr

Verificación recomendada tras añadir cada app:

1. Guarda la app en Prowlarr.
2. Lanza `Test`.
3. Entra en Sonarr o Radarr y comprueba que aparecen nuevos indexadores con el sufijo `(Prowlarr)`.
4. Desactiva primero los indexadores antiguos configurados a mano en esas apps.
5. Cuando confirmes que todo funciona, elimina las entradas antiguas y deja solo las gestionadas por Prowlarr.

### 8. Sync Profiles recomendados

Prowlarr incluye un perfil estándar, y para un homelab pequeño suele ser suficiente al principio.

En este escenario conviene empezar así:

- usar el perfil por defecto para la mayoría de indexadores
- mantener activadas las búsquedas RSS, automáticas e interactivas mientras validas el flujo completo
- fijar `Minimum Seeders` solo si detectas demasiados resultados basura o torrents muertos

Cuándo compensa crear perfiles adicionales:

- si quieres un grupo de indexadores solo para búsquedas manuales
- si quieres evitar búsquedas automáticas en trackers frágiles o con límites estrictos
- si quieres separar mejor indexadores de series y películas mediante tags y perfiles distintos

### 9. Integración opcional con Transmission para búsquedas desde Prowlarr

Esta parte es **opcional**.

Si el uso normal del homelab va a ser:

- buscar contenido desde **Sonarr** y **Radarr**
- enviar las descargas a **Transmission** desde esas aplicaciones

entonces **no necesitas añadir Transmission en Prowlarr**.

Solo debes configurarlo en `Settings` -> `Download Clients` si quieres lanzar búsquedas y envíos directamente desde la interfaz de Prowlarr.

Ejemplo de conexión con el stack descrito en [01-transmission.md](01-transmission.md):

- nombre: `Transmission`
- host: `transmission`
- puerto: `9091`
- usuario y contraseña: los definidos en el `.env` de Transmission
- categoría: opcional, según tu flujo

Validación:

1. Añade el cliente.
2. Pulsa `Test`.
3. Haz una búsqueda manual en Prowlarr y confirma que el envío llega a Transmission.

No confundas este paso con la integración principal del sistema:

- **Prowlarr -> Apps** sirve para sincronizar indexadores hacia Sonarr y Radarr
- **Prowlarr -> Download Clients** solo sirve para búsquedas hechas dentro de Prowlarr

## Almacenamiento

Rutas persistentes del servicio:

- Compose: `/home/<user>/homelab/compose/downloads-prowlarr/docker-compose.yml`
- Variables del stack: `/home/<user>/homelab/compose/downloads-prowlarr/.env`
- Configuración, base de datos y logs: `/home/<user>/homelab/data/prowlarr/config`

Criterio de almacenamiento:

- todo lo operativo de Prowlarr vive en el **SSD NVMe**
- `hd2t` y `hd5t` no participan en este servicio
- no hay payloads de descarga ni bibliotecas multimedia que mover a discos externos

## Backup

Respaldar como mínimo:

- `/home/<user>/homelab/compose/downloads-prowlarr/docker-compose.yml`
- `/home/<user>/homelab/compose/downloads-prowlarr/.env`
- `/home/<user>/homelab/data/prowlarr/config`

Eso cubre:

- la base de datos de Prowlarr
- la lista de indexadores
- la configuración de `Apps`
- logs y ajustes persistentes del servicio

Para una copia más consistente, detén brevemente el contenedor durante el backup:

```bash
cd /home/<user>/homelab/compose/downloads-prowlarr
docker compose stop prowlarr
# ejecutar backup
docker compose start prowlarr
```

Esto reduce el riesgo de capturar una base de datos SQLite en mitad de una escritura.

## Referencias

- Documentación oficial de Prowlarr: https://prowlarr.com/
- Guía oficial de inicio rápido de Prowlarr: https://wiki.servarr.com/prowlarr/quick-start-guide
- Documentación de la imagen Docker de LinuxServer: https://docs.linuxserver.io/images/docker-prowlarr/
- Repositorio oficial de Prowlarr: https://github.com/Prowlarr/Prowlarr
- Repositorio oficial de la imagen Docker de LinuxServer: https://github.com/linuxserver/docker-prowlarr
