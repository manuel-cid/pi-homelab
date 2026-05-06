# Homepage

## Descripción
**Homepage** será el dashboard principal del homelab para centralizar accesos rápidos, estado básico de contenedores Docker, widgets de servicios y métricas ligeras del host en una sola página de inicio.

En esta arquitectura se despliega con estas reglas:

- la aplicación y toda su configuración viven en el **SSD NVMe**
- el acceso web local se publica detrás de **Caddy** con `https://homepage.lan`
- el acceso remoto sigue siendo **solo LAN + Tailscale**, sin abrir puertos en el router
- la definición de tarjetas, grupos, widgets y personalización queda en ficheros YAML fáciles de versionar y respaldar
- se usa integración con Docker mediante el socket local en modo **solo lectura** para mostrar estado de contenedores
- `hd2t` y `hd5t` no almacenan datos del servicio, pero pueden montarse en solo lectura para que Homepage muestre su uso en el widget de recursos

Homepage encaja bien en este homelab porque actúa como portada operativa: reduce la fricción para entrar a cada servicio, ofrece una vista rápida del estado general y mantiene toda la configuración en texto plano.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/04-caddy.md`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres abrir Homepage también a través de la VPN mesh.
- Haber completado `docs/07-backups/01-estrategia-backup.md`.
- Haber completado `docs/07-backups/03-backup-docker-volumes.md`.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el FQDN `homepage.lan` apuntando a la IP LAN principal de la Raspberry Pi.
- Tener importada en navegadores y dispositivos cliente la CA local de Caddy desde:
  - `/home/<usuario>/homelab/compose/caddy/data/caddy/pki/authorities/local/root.crt`
- Poder usar `sudo` con el usuario administrador del homelab.
- Tener claro el coste operativo de montar `/var/run/docker.sock` dentro del contenedor:
  - es útil para estado y estadísticas de contenedores
  - aumenta privilegios frente a un dashboard puramente estático
  - en este homelab se acepta el compromiso por simplicidad
- Puertos implicados en esta fase:
  - `3000/tcp` solo dentro de Docker entre Caddy y el contenedor `homepage`
  - `443/tcp` ya publicado por Caddy en el host
  - no se abre ningún puerto entrante en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/homepage/
├── compose.yaml
└── .env
```

Preparación inicial:

```bash
mkdir -p /home/<usuario>/homelab/compose/homepage
mkdir -p /home/<usuario>/homelab/data/homepage/config
mkdir -p /home/<usuario>/homelab/data/homepage/images
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid

HOMEPAGE_CONTAINER_NAME=homepage
HOMEPAGE_IMAGE=ghcr.io/gethomepage/homepage:latest
HOMEPAGE_ALLOWED_HOSTS=homepage.lan

HOMEPAGE_CONFIG_DIR=/home/<usuario>/homelab/data/homepage/config
HOMEPAGE_IMAGES_DIR=/home/<usuario>/homelab/data/homepage/images
HOMEPAGE_NVME_VIEW=/home/<usuario>/homelab

PUID=1000
PGID=1000

LOG_TARGETS=both

HOMEPAGE_VAR_PIHOLE_API_KEY=CAMBIAR_POR_API_KEY_REAL
HOMEPAGE_VAR_JELLYFIN_API_KEY=CAMBIAR_POR_API_KEY_REAL
HOMEPAGE_VAR_TAILSCALE_API_KEY=CAMBIAR_POR_API_KEY_REAL
HOMEPAGE_VAR_TAILSCALE_DEVICE_ID=CAMBIAR_POR_DEVICE_ID_REAL
```

Notas sobre estas variables:

- `HOMEPAGE_ALLOWED_HOSTS` debe incluir el host público real con el que abrirás Homepage detrás de Caddy. Si cambias a `homepage.homelab.lan`, ajusta aquí el valor.
- `PUID` y `PGID` permiten ejecutar Homepage como usuario no root para el acceso a la configuración persistente.
- el montaje del socket Docker sigue siendo de solo lectura, pero si usas el socket directo debes validar que el usuario efectivo del contenedor puede leerlo; si no, tendrás que usar GID del grupo `docker`, ejecutar temporalmente como root o pasar a un `docker-socket-proxy`
- `HOMEPAGE_VAR_*` deja las claves sensibles fuera de los YAML de configuración y facilita su rotación
- `HOMEPAGE_NVME_VIEW` se monta dentro del contenedor solo para que el widget de recursos pueda medir el uso del SSD NVMe

Fichero `compose.yaml`:

```yaml
name: homepage

services:
  homepage:
    container_name: ${HOMEPAGE_CONTAINER_NAME}
    image: ${HOMEPAGE_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      HOMEPAGE_ALLOWED_HOSTS: ${HOMEPAGE_ALLOWED_HOSTS}
      PUID: ${PUID}
      PGID: ${PGID}
      LOG_TARGETS: ${LOG_TARGETS}
      HOMEPAGE_VAR_PIHOLE_API_KEY: ${HOMEPAGE_VAR_PIHOLE_API_KEY}
      HOMEPAGE_VAR_JELLYFIN_API_KEY: ${HOMEPAGE_VAR_JELLYFIN_API_KEY}
      HOMEPAGE_VAR_TAILSCALE_API_KEY: ${HOMEPAGE_VAR_TAILSCALE_API_KEY}
      HOMEPAGE_VAR_TAILSCALE_DEVICE_ID: ${HOMEPAGE_VAR_TAILSCALE_DEVICE_ID}
    volumes:
      - ${HOMEPAGE_CONFIG_DIR}:/app/config
      - ${HOMEPAGE_IMAGES_DIR}:/app/public/images
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${HOMEPAGE_NVME_VIEW}:/mnt/nvme:ro
      - /mnt/hd2t:/mnt/hd2t:ro
      - /mnt/hd5t:/mnt/hd5t:ro
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
- Homepage escucha internamente en `3000/tcp`
- toda la configuración persistente queda concentrada en `/app/config`
- las imágenes locales de fondo o iconos personalizados se sirven desde `/app/public/images`
- los montajes de `hd2t` y `hd5t` son de solo lectura y se usan solo para el widget de recursos
- si no quieres integración con Docker, puedes eliminar el montaje de `/var/run/docker.sock` y el fichero `docker.yaml`

Despliegue inicial:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/homepage
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/homepage

cd /home/<usuario>/homelab/compose/homepage
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f homepage
```

Resultado esperado:

- el contenedor `homepage` queda levantado
- Homepage escucha internamente en `http://homepage:3000`
- se crea la estructura persistente en `/home/<usuario>/homelab/data/homepage/`
- Caddy puede publicar el servicio como `https://homepage.lan`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `https://homepage.lan` |
| Persistencia | `/home/<usuario>/homelab/data/homepage/` |
| Configuración | YAML bajo `config/` |
| Punto de entrada | Caddy |
| TLS | `tls internal` con CA local de Caddy |
| Estado de contenedores | vía Docker socket en solo lectura |
| Personalización | grupos, widgets, bookmarks, fondo local |

### 1. Preparar rutas y permisos

Crear la estructura base:

```bash
mkdir -p /home/<usuario>/homelab/compose/homepage
mkdir -p /home/<usuario>/homelab/data/homepage/config
mkdir -p /home/<usuario>/homelab/data/homepage/images
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/homepage
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/homepage

chmod 755 /home/<usuario>/homelab/data/homepage
chmod 755 /home/<usuario>/homelab/data/homepage/config
chmod 755 /home/<usuario>/homelab/data/homepage/images
```

Toda la configuración operativa de Homepage debe quedarse en el **SSD NVMe**. `hd2t` y `hd5t` solo se montan de forma auxiliar para visualización de capacidad.

### 2. Publicar Homepage en Caddy con HTTPS interno

Añade este bloque al `Caddyfile` del stack de Caddy:

```caddyfile
homepage.lan {
  import common
  tls internal
  reverse_proxy homepage:3000
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

- usa un hostname dedicado y estable; Homepage será la portada del resto del homelab
- si ya has estandarizado `*.homelab.lan`, sustituye `homepage.lan` por `homepage.homelab.lan` en DNS, `.env` y `Caddyfile`
- si entras con un host distinto al configurado en `HOMEPAGE_ALLOWED_HOSTS`, Homepage rechazará la petición

### 3. Crear los ficheros de configuración base

Homepage lee su configuración desde YAML bajo:

```text
/home/<usuario>/homelab/data/homepage/config/
```

Estructura recomendada:

```text
/home/<usuario>/homelab/data/homepage/config/
├── settings.yaml
├── services.yaml
├── widgets.yaml
├── bookmarks.yaml
├── docker.yaml
└── custom.css
```

Fichero `settings.yaml` recomendado:

```yaml
title: Homelab
description: Dashboard principal de la Raspberry Pi 5
language: es
startUrl: https://homepage.lan
headerStyle: boxedWidgets
statusStyle: dot
hideVersion: true
disableUpdateCheck: false
showStats: true
color: slate
cardBlur: xs
background:
  image: /images/homelab-bg.jpg
  opacity: 35
layout:
  Infraestructura:
    style: row
    columns: 3
  Red:
    style: row
    columns: 3
  Monitorizacion:
    style: row
    columns: 3
  Multimedia:
    style: row
    columns: 4
  Productividad:
    style: row
    columns: 4
  Acceso:
    style: row
    columns: 2
```

Notas:

- si aún no tienes una imagen de fondo, elimina el bloque `background` o deja preparado el fichero `homelab-bg.jpg` en `/home/<usuario>/homelab/data/homepage/images/`
- cuando añadas o cambies imágenes locales, reinicia el contenedor para que Homepage regenere el contenido estático
- `showStats: true` aprovecha la integración con Docker para mostrar datos de contenedores en las tarjetas conectadas a `docker.yaml`

Fichero `docker.yaml`:

```yaml
local-docker:
  socket: /var/run/docker.sock
```

Este fichero permite asociar tarjetas con contenedores concretos para mostrar estado y estadísticas.

Fichero `widgets.yaml` recomendado:

```yaml
- search:
    provider: [duckduckgo, google]
    focus: true
    target: _blank

- datetime:
    text_size: xl
    format:
      dateStyle: full
      timeStyle: short
      hourCycle: h23

- resources:
    label: Sistema
    cpu: true
    memory: true
    cputemp: true
    uptime: true
    refresh: 5000

- resources:
    label: Almacenamiento
    expanded: true
    disk:
      - /mnt/nvme
      - /mnt/hd2t
      - /mnt/hd5t
```

Notas:

- el widget `resources` mide las rutas montadas dentro del contenedor, no discos “mágicos” del host; por eso se montan `nvme`, `hd2t` y `hd5t`
- si la temperatura de CPU no aparece en tu instalación, mantén el resto del widget y elimina `cputemp: true`

Fichero `services.yaml` con una base razonable para este homelab:

```yaml
- Infraestructura:
    - Portainer:
        icon: portainer.png
        href: https://portainer.lan
        description: Gestion de stacks y contenedores
        server: local-docker
        container: portainer

    - Dozzle:
        icon: dozzle.png
        href: https://dozzle.lan
        description: Logs en tiempo real
        server: local-docker
        container: dozzle

    - Homepage:
        icon: homepage.png
        href: https://homepage.lan
        description: Dashboard principal
        server: local-docker
        container: homepage

- Red:
    - Pi-hole:
        icon: pi-hole.png
        href: https://pihole.lan/admin
        description: DNS y bloqueo de anuncios
        widget:
          type: pihole
          url: http://pihole
          version: 6
          key: "{{HOMEPAGE_VAR_PIHOLE_API_KEY}}"

    - Caddy:
        icon: caddy.png
        href: https://caddy.lan
        description: Reverse proxy interno
        server: local-docker
        container: caddy

    - Tailscale:
        icon: tailscale.png
        href: https://login.tailscale.com/admin/machines
        description: Acceso remoto por VPN mesh
        widget:
          type: tailscale
          deviceid: "{{HOMEPAGE_VAR_TAILSCALE_DEVICE_ID}}"
          key: "{{HOMEPAGE_VAR_TAILSCALE_API_KEY}}"

- Monitorizacion:
    - Grafana:
        icon: grafana.png
        href: https://grafana.lan
        description: Dashboards de metricas
        server: local-docker
        container: grafana

    - Prometheus:
        icon: prometheus.png
        href: https://prometheus.lan
        description: Recoleccion de metricas
        server: local-docker
        container: prometheus

    - Uptime Kuma:
        icon: uptime-kuma.png
        href: https://uptime-kuma.lan
        description: Estado general de servicios
        widget:
          type: uptimekuma
          url: http://uptime-kuma:3001
          slug: homelab

- Multimedia:
    - Jellyfin:
        icon: jellyfin.png
        href: https://jellyfin.lan
        description: Video, musica y biblioteca multimedia
        server: local-docker
        container: jellyfin
        widget:
          type: jellyfin
          url: http://jellyfin:8096
          key: "{{HOMEPAGE_VAR_JELLYFIN_API_KEY}}"
          version: 2
          enableBlocks: true

    - Navidrome:
        icon: navidrome.png
        href: https://navidrome.lan
        description: Musica por Subsonic
        server: local-docker
        container: navidrome

    - Audiobookshelf:
        icon: audiobookshelf.png
        href: https://audiobookshelf.lan
        description: Audiolibros y podcasts
        server: local-docker
        container: audiobookshelf

    - Stash:
        icon: stash.png
        href: https://stash.lan
        description: Biblioteca multimedia en hd5t
        server: local-docker
        container: stash

- Productividad:
    - Vaultwarden:
        icon: vaultwarden.png
        href: https://vaultwarden.lan
        description: Gestor de contraseñas
        server: local-docker
        container: vaultwarden

    - BookStack:
        icon: bookstack.png
        href: https://bookstack.lan
        description: Wiki interna
        server: local-docker
        container: bookstack

    - Paperless-ngx:
        icon: paperless-ngx.png
        href: https://paperless.lan
        description: Archivo documental
        server: local-docker
        container: paperless-ngx

    - FreshRSS:
        icon: freshrss.png
        href: https://freshrss.lan
        description: Lector RSS
        server: local-docker
        container: freshrss

- Acceso:
    - Router:
        icon: router.png
        href: http://192.168.1.1
        description: Administracion de red local

    - Raspberry Pi:
        icon: raspberry-pi.png
        href: https://portainer.lan
        description: Entrada de administracion del host
```

Puntos importantes de este ejemplo:

- ajusta `href` a los FQDN reales que hayas definido en Caddy y en DNS local
- los valores de `container:` deben coincidir con el nombre real del contenedor o con el `container_name` definido en cada stack
- los widgets con API requieren claves válidas; si aún no las tienes, deja la tarjeta sin el bloque `widget`
- el widget de **Uptime Kuma** necesita una status page publicada en Kuma y su `slug`; si no la tienes, elimina ese bloque
- si Pi-hole vive fuera de la red Docker habitual o en macvlan, puede que debas usar su IP LAN real en `url:`

Fichero `bookmarks.yaml` opcional:

```yaml
- Operacion:
    - GitHub:
        - abbr: GH
          href: https://github.com/
    - Tailscale Admin:
        - abbr: TS
          href: https://login.tailscale.com/admin/machines
    - Docker Hub:
        - abbr: DH
          href: https://hub.docker.com/
```

### 4. Personalización visual

Para una personalización mínima pero limpia:

1. Copia una imagen de fondo a `/home/<usuario>/homelab/data/homepage/images/homelab-bg.jpg`.
2. Mantén el bloque `background` en `settings.yaml`.
3. Agrupa los servicios por dominio funcional en `services.yaml`.
4. Ajusta `columns` por grupo para que el dashboard no se vuelva demasiado denso en móvil.

Si quieres añadir CSS propio, crea `custom.css`:

```css
.service-card,
.bookmark-card {
  border-radius: 1rem;
}

.service-card {
  border: 1px solid rgba(255, 255, 255, 0.08);
}
```

Recomendaciones prácticas:

- usa fondos discretos y con poco contraste; Homepage funciona mejor cuando las tarjetas siguen siendo legibles
- evita mezclar demasiados grupos con una sola columna; el dashboard pierde valor si obliga a hacer demasiado scroll
- no conviertas Homepage en un sistema de monitorización profunda; para eso ya están Grafana, Prometheus y Uptime Kuma

### 5. Cargar cambios y validar resultado

Después de crear o modificar YAML:

```bash
cd /home/<usuario>/homelab/compose/homepage
docker compose restart homepage
docker compose logs --tail=100 homepage
```

Abrir después:

```text
https://homepage.lan
```

Validación mínima recomendada:

1. Confirmar que Homepage carga con certificado confiable.
2. Comprobar que aparecen los grupos definidos en `services.yaml`.
3. Verificar que el widget de recursos muestra NVMe, `hd2t` y `hd5t`.
4. Revisar que las tarjetas conectadas a Docker muestran estado.
5. Probar al menos un widget con API, por ejemplo Jellyfin o Tailscale.

Si un widget falla:

- revisa primero `docker compose logs homepage`
- confirma conectividad interna desde el contenedor hacia la URL usada en el widget
- valida que la clave API sigue siendo válida
- comprueba que el placeholder `{{HOMEPAGE_VAR_*}}` existe realmente en `.env`

### 6. Estrategia recomendada de mantenimiento

Para que Homepage siga siendo útil con el tiempo:

- añade nuevas tarjetas cuando cierres la documentación de cada servicio
- elimina accesos que ya no existan; un dashboard desactualizado pierde valor muy rápido
- prioriza enlaces de operación real y no enlaces “bonitos” que nunca abres
- usa widgets solo cuando aporten señal útil; demasiados widgets convierten Homepage en una página ruidosa

## Almacenamiento
Volúmenes y rutas persistentes de este servicio:

| Ruta en host | Montaje en contenedor | Uso |
|---|---|---|
| `/home/<usuario>/homelab/data/homepage/config` | `/app/config` | YAML, logs, configuración principal |
| `/home/<usuario>/homelab/data/homepage/images` | `/app/public/images` | fondos e imágenes locales |
| `/var/run/docker.sock` | `/var/run/docker.sock` | integración con Docker |
| `/home/<usuario>/homelab` | `/mnt/nvme` | medición de uso del SSD NVMe |
| `/mnt/hd2t` | `/mnt/hd2t` | medición de uso del disco hd2t |
| `/mnt/hd5t` | `/mnt/hd5t` | medición de uso del disco hd5t |

Notas de almacenamiento:

- Homepage no necesita guardar bibliotecas multimedia ni bases de datos pesadas
- el estado importante del servicio son los ficheros YAML y los assets locales
- el socket Docker no contiene datos persistentes, pero sí es una dependencia operativa crítica si usas integración con contenedores

## Backup
Qué respaldar de este servicio:

- `/home/<usuario>/homelab/compose/homepage/`
- `/home/<usuario>/homelab/data/homepage/config/`
- `/home/<usuario>/homelab/data/homepage/images/`

Qué no hace falta respaldar específicamente:

- `/var/run/docker.sock`
- montajes auxiliares de `hd2t` y `hd5t`

Recomendación práctica:

- incluye Homepage en el backup regular del **SSD NVMe**
- si usas fondo personalizado o iconos propios, verifica que `images/` entre en la política de backup
- si guardas secretos reales en `.env`, trata ese fichero como material sensible y protégelo igual que el resto de credenciales del homelab

## Referencias
- Documentación oficial de Homepage: `https://gethomepage.dev/`
- Instalación Docker de Homepage: `https://gethomepage.dev/installation/docker/`
- Configuración general (`settings.yaml`, `services.yaml`, `widgets.yaml`, `docker.yaml`): `https://gethomepage.dev/configs/`
- Imagen Docker oficial: `https://github.com/gethomepage/homepage/pkgs/container/homepage`
