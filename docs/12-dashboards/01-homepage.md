# Homepage

## Descripción

**Homepage** será la portada operativa del homelab: un dashboard ligero para agrupar accesos, estados básicos y widgets de sistema sin añadir una base de datos ni una pila compleja. En este proyecto encaja bien porque su configuración es **declarativa** y queda versionable como YAML sobre el **SSD NVMe**.

La topología recomendada para esta Raspberry Pi 5 es esta:

- la aplicación vive en `/home/<user>/homelab/compose/dashboards-homepage/`
- la configuración editable vive en `/home/<user>/homelab/config/homepage/`
- el servicio se publica en `17000/tcp` para acceso directo desde **LAN** y **Tailscale**
- además se conecta a `homelab_proxy` para poder publicarlo detrás de **Caddy** y, si quieres, proteger la ruta remota con **Authelia**
- Homepage no necesita base de datos propia; lo importante es respaldar sus YAML, imágenes locales y secretos de `.env`

Para este homelab, esa combinación da un resultado razonable: un panel central sencillo, fácil de reconstruir y suficientemente flexible para crecer con el resto de servicios.

## Requisitos Previos

- Haber completado [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber completado [04-tailscale.md](../03-red/04-tailscale.md) si quieres usar Homepage también desde la tailnet.
- Haber completado [05-caddy.md](../03-red/05-caddy.md) si quieres publicar Homepage como `http://homepage.lan` o bajo `https://pi-homelab.<tailnet>.ts.net/homepage/`.
- Haber completado [01-authelia.md](../04-seguridad/01-authelia.md) si quieres exigir autenticación en la ruta remota `/homepage/`.
- Revisar [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) para mantener documentado el puerto `17000/tcp`.
- Tener creada la red Docker externa `homelab_proxy` si vas a integrarlo con Caddy.
- Tener ya definidos los servicios que quieras mostrar y sus URLs canónicas.
- Tener a mano las claves de API solo de los widgets que realmente vayas a usar; no hace falta preparar tokens para todos desde el primer día.
- Puertos necesarios en esta fase:
  - **`17000/tcp` publicado en el host** para acceso directo desde LAN y Tailscale
  - **`3000/tcp`** como puerto interno del contenedor
  - **`80/tcp` y `443/tcp`** solo si decides publicarlo detrás de Caddy, ya documentados en la fase de red

## Docker Compose

Archivo: `/home/<user>/homelab/compose/dashboards-homepage/docker-compose.yml`

```yaml
name: dashboards-homepage

services:
  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      HOMEPAGE_ALLOWED_HOSTS: ${HOMEPAGE_ALLOWED_HOSTS}
    ports:
      - "${HOMEPAGE_BIND_IP}:${HOMEPAGE_PORT}:3000"
    volumes:
      - /home/<user>/homelab/config/homepage:/app/config
      - /home/<user>/homelab/config/homepage/images:/app/public/images
      - /home/<user>/homelab:/mnt/nvme:ro
      - /media/hd2t:/media/hd2t:ro
      - /media/hd5t:/media/hd5t:ro
    networks:
      - default
      - homelab_proxy
    labels:
      - com.centurylinklabs.watchtower.enable=true

networks:
  homelab_proxy:
    external: true
    name: homelab_proxy
```

Archivo recomendado: `/home/<user>/homelab/compose/dashboards-homepage/.env`

```dotenv
TZ=Europe/Madrid
HOMEPAGE_BIND_IP=0.0.0.0
HOMEPAGE_PORT=17000
HOMEPAGE_ALLOWED_HOSTS=localhost,127.0.0.1,<ip-lan-de-la-pi>:17000,homepage.lan,pi-homelab.<tailnet>.ts.net,pi-homelab.<tailnet>.ts.net:17000

HOMEPAGE_VAR_PORTAINER_URL=http://portainer.lan
HOMEPAGE_VAR_PIHOLE_URL=http://192.168.1.194/admin
HOMEPAGE_VAR_JELLYFIN_URL=http://jellyfin.lan
HOMEPAGE_VAR_NAVIDROME_URL=http://navidrome.lan
HOMEPAGE_VAR_AUDIOBOOKSHELF_URL=http://audiobookshelf.lan
HOMEPAGE_VAR_CALIBRE_URL=http://calibre-web.lan
HOMEPAGE_VAR_TRANSMISSION_URL=http://<ip-lan-de-la-pi>:15000
HOMEPAGE_VAR_PROWLARR_URL=http://<ip-lan-de-la-pi>:15001
HOMEPAGE_VAR_VAULTWARDEN_URL=https://pi-homelab.<tailnet>.ts.net/vaultwarden/
HOMEPAGE_VAR_LINKDING_URL=http://<ip-lan-de-la-pi>:9090
HOMEPAGE_VAR_PAPERLESS_URL=http://<ip-lan-de-la-pi>:16002
HOMEPAGE_VAR_HOMEASSISTANT_URL=http://<ip-lan-de-la-pi>:8123

# TODO: verificar la URL canónica final de Grafana, Uptime Kuma y FreshRSS si decides
# mostrarlos en Homepage; sus documentos base los dejan detrás de 127.0.0.1 o de Caddy,
# así que no conviene añadir aquí enlaces de ejemplo no documentados todavía.

HOMEPAGE_VAR_JELLYFIN_API_KEY=REEMPLAZAR_SI_USAS_WIDGET_DE_JELLYFIN
```

Notas sobre este Compose:

- Homepage escucha internamente en `3000/tcp`, pero en este homelab se publica en `17000/tcp`
- `HOMEPAGE_ALLOWED_HOSTS` debe incluir tanto el acceso directo por puerto como los hostnames que usarás detrás de Caddy
- el bind mount de `/app/config` deja toda la configuración versionable en el **SSD NVMe**
- el subdirectorio `images/` permite usar fondos o logos locales sin montar todo `/app/public`
- los mounts de `/mnt/nvme`, `/media/hd2t` y `/media/hd5t` están pensados para que el widget `resources` pueda enseñar uso de disco real del host
- si no quieres mostrar almacenamiento en Homepage, puedes quitar esos tres montajes de solo lectura

## Configuración

### 1. Preparar directorios del stack

```bash
mkdir -p /home/<user>/homelab/compose/dashboards-homepage
mkdir -p /home/<user>/homelab/config/homepage/images
mkdir -p /home/<user>/homelab/config/homepage/logs
touch /home/<user>/homelab/config/homepage/{settings.yaml,widgets.yaml,services.yaml,bookmarks.yaml,custom.css,custom.js}
chmod 750 /home/<user>/homelab/config/homepage
chmod 750 /home/<user>/homelab/config/homepage/images
chmod 750 /home/<user>/homelab/config/homepage/logs
```

Guarda en `/home/<user>/homelab/compose/dashboards-homepage/` el `docker-compose.yml` y el `.env` del apartado anterior.

Como `.env` puede contener tokens de widgets, restringe permisos:

```bash
chmod 600 /home/<user>/homelab/compose/dashboards-homepage/.env
```

### 2. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/dashboards-homepage
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=100 homepage
```

Validaciones iniciales:

```bash
curl -I http://127.0.0.1:17000/
ls -lah /home/<user>/homelab/config/homepage
```

Si el arranque ha ido bien, Homepage quedará accesible al menos por una de estas rutas:

- `http://<ip-lan-de-la-pi>:17000`
- `http://pi-homelab.<tailnet>.ts.net:17000`

### 3. Crear una configuración mínima y mantenible

Archivo: `/home/<user>/homelab/config/homepage/settings.yaml`

```yaml
title: Homelab Pi 5
description: Panel central de servicios LAN + Tailscale
language: es
target: _self
theme: dark
color: slate
headerStyle: boxed
statusStyle: dot
hideVersion: true
showStats: true

layout:
  Infraestructura:
    style: row
    columns: 4
  Multimedia:
    style: row
    columns: 4
  Descargas:
    style: row
    columns: 3
  Productividad:
    style: row
    columns: 4
  Domotica:
    style: row
    columns: 3

quicklaunch:
  searchDescriptions: true

# Si lo publicas detrás de Caddy en subruta, descomenta esta linea:
# base: https://pi-homelab.<tailnet>.ts.net/homepage
```

Archivo: `/home/<user>/homelab/config/homepage/widgets.yaml`

```yaml
- resources:
    cpu: true
    memory: true
    disk:
      - /mnt/nvme
      - /media/hd2t
      - /media/hd5t

- datetime:
    text_size: xl
    format:
      timeStyle: short
      dateStyle: full
```

Archivo: `/home/<user>/homelab/config/homepage/services.yaml`

```yaml
- Infraestructura:
    - Portainer:
        icon: portainer.png
        href: "{{HOMEPAGE_VAR_PORTAINER_URL}}"
        description: Gestion de contenedores y stacks
        siteMonitor: "{{HOMEPAGE_VAR_PORTAINER_URL}}"
    - Pi-hole:
        icon: pi-hole.png
        href: "{{HOMEPAGE_VAR_PIHOLE_URL}}"
        description: DNS y bloqueo de anuncios
        siteMonitor: "{{HOMEPAGE_VAR_PIHOLE_URL}}"

- Multimedia:
    - Jellyfin:
        icon: jellyfin.png
        href: "{{HOMEPAGE_VAR_JELLYFIN_URL}}"
        description: Peliculas y series
        siteMonitor: "{{HOMEPAGE_VAR_JELLYFIN_URL}}"
        widget:
          type: jellyfin
          url: "{{HOMEPAGE_VAR_JELLYFIN_URL}}"
          key: "{{HOMEPAGE_VAR_JELLYFIN_API_KEY}}"
    - Navidrome:
        icon: navidrome.png
        href: "{{HOMEPAGE_VAR_NAVIDROME_URL}}"
        description: Musica
        siteMonitor: "{{HOMEPAGE_VAR_NAVIDROME_URL}}"
    - Audiobookshelf:
        icon: audiobookshelf.png
        href: "{{HOMEPAGE_VAR_AUDIOBOOKSHELF_URL}}"
        description: Audiolibros y podcasts
        siteMonitor: "{{HOMEPAGE_VAR_AUDIOBOOKSHELF_URL}}"
    - Calibre-Web:
        icon: calibre-web.png
        href: "{{HOMEPAGE_VAR_CALIBRE_URL}}"
        description: Biblioteca de ebooks
        siteMonitor: "{{HOMEPAGE_VAR_CALIBRE_URL}}"

- Descargas:
    - Transmission:
        icon: transmission.png
        href: "{{HOMEPAGE_VAR_TRANSMISSION_URL}}"
        description: Cliente BitTorrent
        siteMonitor: "{{HOMEPAGE_VAR_TRANSMISSION_URL}}"
    - Prowlarr:
        icon: prowlarr.png
        href: "{{HOMEPAGE_VAR_PROWLARR_URL}}"
        description: Indexadores y busquedas
        siteMonitor: "{{HOMEPAGE_VAR_PROWLARR_URL}}"

- Productividad:
    - Vaultwarden:
        icon: vaultwarden.png
        href: "{{HOMEPAGE_VAR_VAULTWARDEN_URL}}"
        description: Gestor de contrasenas
    - Linkding:
        icon: linkding.png
        href: "{{HOMEPAGE_VAR_LINKDING_URL}}"
        description: Marcadores web
        siteMonitor: "{{HOMEPAGE_VAR_LINKDING_URL}}"
    - Paperless-ngx:
        icon: paperless-ngx.png
        href: "{{HOMEPAGE_VAR_PAPERLESS_URL}}"
        description: Gestion documental
        siteMonitor: "{{HOMEPAGE_VAR_PAPERLESS_URL}}"

- Domotica:
    - Home Assistant:
        icon: home-assistant.png
        href: "{{HOMEPAGE_VAR_HOMEASSISTANT_URL}}"
        description: Automatizacion y dispositivos
        siteMonitor: "{{HOMEPAGE_VAR_HOMEASSISTANT_URL}}"
```

Archivo: `/home/<user>/homelab/config/homepage/bookmarks.yaml`

```yaml
[]
```

Con esa base ya tienes un panel funcional y fácil de mantener. La idea no es rellenar todos los servicios el primer día, sino arrancar con los imprescindibles y refinar la portada según el uso real.

Si más adelante quieres añadir tarjetas para servicios como **Grafana**, **Uptime Kuma** o **FreshRSS**, define primero su URL canónica real en **Caddy** o el método de acceso operativo que vayas a mantener. Evita poner en Homepage enlaces de ejemplo a hostnames o rutas que todavía no existan en el resto de la documentación.

### 4. Personalizar sin complicar el mantenimiento

Patrón recomendado para personalización:

- usa `settings.yaml` para tema, color, orden y layout
- deja `services.yaml` solo para tarjetas de servicio
- reserva `widgets.yaml` para indicadores globales como fecha, recursos o búsquedas
- guarda imágenes locales en `/home/<user>/homelab/config/homepage/images/`
- usa `custom.css` y `custom.js` solo para ajustes muy concretos; si todo acaba ahí, la configuración se vuelve difícil de mantener

Ejemplo de `custom.css` mínimo y razonable:

Archivo: `/home/<user>/homelab/config/homepage/custom.css`

```css
body {
  letter-spacing: 0.01em;
}

.service-card {
  border-radius: 18px;
}
```

Ejemplo de personalización con fondo local. Primero copia una imagen a:

`/home/<user>/homelab/config/homepage/images/homepage-bg.webp`

Luego añade este bloque a `settings.yaml`:

```yaml
background:
  image: /images/homepage-bg.webp
  blur: sm
```

Mantén el fondo discreto. En una pantalla de operaciones importa más la legibilidad de las tarjetas que la decoración.

### 5. Publicar Homepage con Caddy y opcionalmente protegerlo con Authelia

Si quieres una URL más limpia dentro de la LAN y una ruta protegida en Tailscale, integra Homepage con Caddy.

Bloque LAN recomendado para `/home/<user>/homelab/config/caddy/Caddyfile`:

```caddyfile
http://homepage.lan {
	import common_proxy
	reverse_proxy homepage:3000
}
```

Si ya sigues el patrón descrito en [01-authelia.md](../04-seguridad/01-authelia.md), añade o conserva dentro del bloque HTTPS:

```caddyfile
handle_path /homepage/* {
	import authelia_forward_auth
	reverse_proxy homepage:3000
}
```

Después valida y reaplica Caddy:

```bash
cd /home/<user>/homelab/compose/infra-caddy
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose up -d
docker compose logs --tail=100 caddy
```

Con esta topología puedes usar estas rutas:

- `http://homepage.lan` dentro de la LAN
- `https://pi-homelab.<tailnet>.ts.net/homepage/` desde Tailscale si lo publicas por Caddy
- `http://<ip-lan-de-la-pi>:17000` como acceso directo o de emergencia

Si decides usar solo Caddy, puedes endurecer el servicio cambiando `HOMEPAGE_BIND_IP=127.0.0.1` y recreando el stack.

### 6. Operación básica y mantenimiento

Comandos útiles:

```bash
cd /home/<user>/homelab/compose/dashboards-homepage
docker compose logs --tail=100 homepage
docker compose restart homepage
docker compose pull
docker compose up -d
```

Comprobaciones recomendadas después de cada cambio en YAML:

- abrir Homepage y verificar que no aparecen tarjetas vacías ni widgets rotos
- revisar los logs del contenedor si una tarjeta no se renderiza
- comprobar que los `href` llevan a la URL canónica correcta
- revisar que los `siteMonitor` no apuntan a rutas protegidas por Authelia si quieres estado sin login adicional

Cuando añadas un servicio nuevo al homelab, la secuencia operativa razonable es:

1. desplegar y validar primero el servicio real
2. decidir su URL canónica
3. añadir la tarjeta a `services.yaml`
4. solo después estudiar si merece un widget con token o datos extra

## Almacenamiento

Rutas persistentes principales de Homepage:

- `/home/<user>/homelab/config/homepage/` en el **SSD NVMe**
- `/home/<user>/homelab/config/homepage/images/` en el **SSD NVMe** para fondos, logos o iconos locales
- `/home/<user>/homelab/config/homepage/logs/` en el **SSD NVMe** si decides conservar logs del servicio dentro de la configuración

Qué vive realmente en esa ruta:

- `settings.yaml`, `widgets.yaml`, `services.yaml` y `bookmarks.yaml`
- `custom.css` y `custom.js` si aplicas personalizaciones
- secretos interpolados desde `.env` de Compose
- imágenes locales montadas en `/app/public/images`

Qué **no** forma parte de la persistencia propia de Homepage:

- `/mnt/nvme`, `/media/hd2t` y `/media/hd5t` montados en el contenedor solo para lectura
- los datos de los servicios enlazados desde la portada

En otras palabras: Homepage es un servicio muy barato de reconstruir, pero solo si mantienes a salvo sus archivos YAML y el `.env` del stack.

## Backup

Qué respaldar como mínimo:

- `/home/<user>/homelab/compose/dashboards-homepage/docker-compose.yml`
- `/home/<user>/homelab/compose/dashboards-homepage/.env`
- todo `/home/<user>/homelab/config/homepage/`

Estrategia recomendada en este homelab:

- incluir el stack completo en el backup de filesystem del **SSD NVMe**
- no hace falta dump de base de datos porque Homepage no mantiene una propia
- si usas imágenes locales para fondos o branding, respaldarlas junto con la configuración
- si guardas tokens de widgets en `.env`, tratar ese fichero como secreto

Copia simple del árbol de configuración:

```bash
mkdir -p /media/hd2t/backups/exports/config/homepage
rsync -a /home/<user>/homelab/config/homepage/ \
  /media/hd2t/backups/exports/config/homepage/
```

Copia del stack y sus secretos:

```bash
mkdir -p /media/hd2t/backups/exports/compose/dashboards-homepage
rsync -a /home/<user>/homelab/compose/dashboards-homepage/ \
  /media/hd2t/backups/exports/compose/dashboards-homepage/
```

Buenas practicas de restore:

- restaurar siempre juntos `docker-compose.yml`, `.env` y los YAML de `/config/homepage`
- comprobar despues del restore que no han quedado URLs antiguas ni tokens caducados
- si cambiaste de hostname o de path en Caddy, revisar `HOMEPAGE_ALLOWED_HOSTS` y el posible `base:` de `settings.yaml`

## Referencias

- [Homepage - Sitio oficial](https://gethomepage.dev/)
- [Homepage - Repositorio oficial](https://github.com/gethomepage/homepage)
- [Homepage - Imagen Docker en GHCR](https://ghcr.io/gethomepage/homepage)
