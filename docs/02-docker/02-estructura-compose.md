# Estructura y Organización de Docker Compose

## Descripción

Este documento define la **estrategia de organización** de los despliegues Docker del homelab. El objetivo no es levantar todavía un servicio concreto, sino fijar una base operativa mantenible para las siguientes fases: cómo dividir los stacks, dónde guardar cada `docker-compose.yml`, cómo usar una **red Docker compartida** entre stacks y qué convención seguir con los ficheros **`.env`**.

Para este proyecto, la recomendación es clara: **no** usar un único `docker-compose.yml` monolítico para todo el homelab y **no** fragmentar sin criterio en un fichero por contenedor. El punto de equilibrio es usar **un `docker-compose.yml` por stack funcional**, entendiendo por stack un conjunto de servicios que comparten ciclo de vida, dependencias y contexto operativo.

Esto encaja especialmente bien con una Raspberry Pi 5: simplifica actualizaciones, reduce el riesgo de tocar servicios no relacionados y hace más cómoda la gestión posterior desde terminal y desde [03-portainer.md](03-portainer.md).

## Requisitos Previos

- Haber completado [01-instalacion-docker.md](01-instalacion-docker.md).
- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Disponer de la raíz operativa del homelab en `/home/<user>/homelab/`.
- Poder acceder por terminal con el usuario administrativo que ejecutará `docker compose`.
- Tener claros los puntos de montaje persistentes del proyecto:
  - **SSD NVMe** para `compose`, `.env`, configuración y datos persistentes
  - **`/mnt/hd2t`** para multimedia general, descargas y backups
  - **`/mnt/hd5t`** para la librería de Stash
- Puertos necesarios en esta fase:
  - ninguno obligatorio a nivel host
  - se recomienda reservar el nombre de la red compartida Docker `homelab_proxy`

## Objetivo de esta Fase

Al terminar este documento, el criterio operativo esperado es este:

- Cada grupo lógico de servicios del homelab tiene su propio directorio bajo `compose/`.
- Cada stack tiene su propio `docker-compose.yml` y su propio `.env`.
- Existe una red Docker externa compartida para los servicios que deban hablar con un reverse proxy u otros stacks de forma controlada.
- Las rutas persistentes siguen una convención estable y predecible.
- El despliegue manual por CLI y la gestión posterior desde Portainer comparten la misma estructura.

## Docker Compose

Ejemplo de stack autocontenido siguiendo la convención recomendada. En este caso se usa **Linkding** solo como muestra de estructura: un stack pequeño, con datos persistentes en el NVMe, un `.env` local y conexión opcional a la red compartida.

Archivo: `/home/<user>/homelab/compose/productivity-linkding/docker-compose.yml`

```yaml
name: productivity-linkding

services:
  linkding:
    image: sissbruecker/linkding:latest
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      LD_SUPERUSER_NAME: ${LINKDING_SUPERUSER_NAME}
      LD_SUPERUSER_PASSWORD: ${LINKDING_SUPERUSER_PASSWORD}
    ports:
      - "${LINKDING_BIND_IP}:${LINKDING_PORT}:9090"
    volumes:
      - ${DATA_ROOT}/linkding:/etc/linkding/data
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

Puntos importantes del ejemplo:

- se usa `name:` para fijar un nombre estable del proyecto Compose
- no se usa el campo legado `version:`
- el stack es autocontenido: `docker-compose.yml` y `.env` viven juntos
- los datos persistentes van al **SSD NVMe** bajo `/home/<user>/homelab/data/`
- la red `proxy` es **externa** y compartida entre stacks solo cuando haga falta
- el puerto puede publicarse en `127.0.0.1` o en una IP LAN según el tipo de servicio

## Configuración

### 1. Elegir el modelo correcto: stack funcional, no monolito

Para este homelab, la opción recomendada es:

- **un `docker-compose.yml` por stack funcional**

Esto significa agrupar juntos solo los servicios que:

- dependen unos de otros para arrancar correctamente
- se actualizan normalmente en la misma ventana de mantenimiento
- comparten configuración, red interna o almacenamiento relacionado
- tiene sentido gestionar como una unidad desde Portainer

Ejemplos razonables:

- `infra-portainer`
- `infra-pihole-unbound`
- `monitoring-prometheus-grafana`
- `auth-authelia`
- `media-jellyfin`
- `media-arr`
- `paperless-ngx`
- `automation-homeassistant`

Evita estos dos extremos:

- **monolito único** para todo el homelab:
  - hace más difícil validar cambios
  - mezcla servicios sin relación
  - complica reinicios y rollbacks
  - convierte cualquier error de sintaxis en un problema global
- **un compose por contenedor sin criterio**:
  - fragmenta demasiado
  - multiplica redes y `.env`
  - hace más incómoda la gestión de aplicaciones compuestas como Paperless, Pi-hole + Unbound o Prometheus + Grafana

Regla práctica:

- si dos o más contenedores forman **una sola aplicación lógica**, van en el mismo stack
- si dos servicios pueden pararse, actualizarse y diagnosticarse por separado, van en stacks distintos

### 2. Estructura recomendada de directorios

La estructura recomendada sobre el **SSD NVMe** es esta:

```text
/home/<user>/homelab/
├── .env
├── compose/
│   ├── infra-portainer/
│   │   ├── docker-compose.yml
│   │   └── .env
│   ├── infra-pihole-unbound/
│   │   ├── docker-compose.yml
│   │   └── .env
│   ├── media-jellyfin/
│   │   ├── docker-compose.yml
│   │   └── .env
│   └── productivity-linkding/
│       ├── docker-compose.yml
│       └── .env
├── config/
│   ├── caddy/
│   ├── grafana/
│   └── prometheus/
├── data/
│   ├── linkding/
│   ├── portainer/
│   ├── pihole/
│   └── postgres/
├── logs/
└── scripts/
```

Convención recomendada:

- `compose/<stack>/docker-compose.yml`: definición del stack
- `compose/<stack>/.env`: variables de ese stack
- `config/<servicio>/`: configuración editable fuera del contenedor
- `data/<servicio>/`: datos persistentes, bases de datos, uploads y estado
- `logs/<servicio>/`: solo si interesa persistir logs fuera del contenedor

### 3. Crear la red Docker compartida

Cuando varios stacks deban conectarse al mismo reverse proxy o compartir una comunicación controlada entre servicios, usa una red externa única y nombrada explícitamente.

Créala una sola vez:

```bash
docker network create homelab_proxy
docker network ls | grep homelab_proxy
```

La política recomendada es esta:

- cada stack mantiene su red `default` aislada
- solo los servicios que realmente lo necesiten se unen también a `homelab_proxy`
- no uses una red externa compartida como sustituto de diseñar bien los límites entre stacks

Casos típicos en los que **sí** conviene usarla:

- servicios HTTP/S publicados detrás de Caddy
- aplicaciones que Portainer o un dashboard deban alcanzar por nombre DNS interno de Docker

Casos en los que **no** conviene usarla por defecto:

- bases de datos que solo usa su propia aplicación
- Redis, PostgreSQL o MariaDB internos de un stack
- servicios que no necesitan exposición transversal

### 4. Convenciones de nombres

Usa nombres simples, estables y previsibles.

Convenciones recomendadas:

- directorios de stack en **kebab-case**
- `name:` del Compose igual que el nombre del directorio
- nombres de servicio cortos y semánticos: `app`, `db`, `redis`, `unbound`, `grafana`
- redes externas con nombres globales y claros: `homelab_proxy`
- rutas persistentes con nombre de servicio único: `/home/<user>/homelab/data/<servicio>/`

Ejemplos:

- directorio: `compose/infra-pihole-unbound/`
- `name:`: `infra-pihole-unbound`
- servicios dentro del stack: `pihole` y `unbound`
- datos persistentes: `/home/<user>/homelab/data/pihole/`

Sobre `container_name`:

- no es obligatorio en este proyecto
- con `name:` y nombres de servicio claros, Compose ya genera nombres suficientemente predecibles
- úsalo solo si necesitas un nombre fijo por una razón operativa concreta

### 5. Convenciones para `.env`

La regla más importante es esta:

- **cada stack debe ser autocontenido y tener su propio `.env`**

Esto evita ambigüedades entre despliegues manuales y despliegues desde Portainer. Aunque existe `/home/<user>/homelab/.env`, no conviene asumir que Compose lo cargará automáticamente para todos los stacks.

Recomendación práctica:

- `/home/<user>/homelab/.env`
  - inventario de valores globales del host
  - referencia humana
  - posible uso por scripts operativos
- `/home/<user>/homelab/compose/<stack>/.env`
  - fuente real de variables del stack
  - puertos, rutas, etiquetas de imagen y credenciales de ese despliegue

Ejemplo de `.env` para el stack anterior:

Archivo: `/home/<user>/homelab/compose/productivity-linkding/.env`

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000
DATA_ROOT=/home/<user>/homelab/data
PROXY_NETWORK=homelab_proxy
LINKDING_BIND_IP=127.0.0.1
LINKDING_PORT=9090
LINKDING_SUPERUSER_NAME=admin
LINKDING_SUPERUSER_PASSWORD=cambiar-esta-clave
```

Convenciones útiles:

- `TZ`, `PUID` y `PGID` repetidos por stack si la imagen los usa
- rutas siempre **absolutas**, no relativas
- credenciales fuera del `docker-compose.yml`
- permisos restrictivos para `.env` con secretos:

```bash
chmod 600 /home/<user>/homelab/compose/*/.env
```

### 6. Convención de puertos

No todos los servicios deben exponerse igual.

Regla recomendada:

- usa `127.0.0.1:<puerto>:<puerto_interno>` para servicios HTTP que irán detrás de reverse proxy en la propia Raspberry Pi
- usa `0.0.0.0:<puerto>:<puerto_interno>` solo cuando el servicio deba ser accesible directamente desde la LAN o Tailscale
- evita `network_mode: host` salvo que un servicio realmente lo requiera por su naturaleza

Ejemplos típicos:

- **sí** suele tener sentido acceso directo:
  - Portainer
  - Jellyfin
  - Samba
  - Pi-hole en sus puertos DNS y web según el diseño final
- **no** suele necesitar acceso directo:
  - Linkding
  - Mealie
  - FreshRSS
  - Vaultwarden detrás de proxy

### 7. Flujo recomendado de despliegue

Para cualquier stack nuevo, sigue esta secuencia:

```bash
mkdir -p /home/<user>/homelab/compose/<stack>
mkdir -p /home/<user>/homelab/data/<servicio>
cd /home/<user>/homelab/compose/<stack>
docker compose config
docker compose up -d
docker compose ps
```

Antes de levantar un stack:

- valida la sintaxis con `docker compose config`
- confirma que los directorios de datos ya existen
- comprueba que la red externa compartida existe si el stack la referencia
- revisa que los puertos elegidos no colisionan con otros servicios

### 8. Relación con Portainer y Watchtower

La estructura definida aquí está pensada para funcionar bien con los siguientes documentos de esta fase:

- Portainer gestionará mejor stacks pequeños y coherentes que un monolito gigante
- Watchtower se puede controlar mejor con etiquetas por stack o por servicio

Convención recomendada desde el principio:

- añade la etiqueta `com.centurylinklabs.watchtower.enable=true` solo a los servicios que quieras actualizar automáticamente
- deja fuera de esa política servicios especialmente sensibles si prefieres actualizarlos manualmente

## Almacenamiento

La política de almacenamiento no cambia por usar múltiples stacks:

- los `docker-compose.yml` y `.env` viven en el **SSD NVMe** bajo `/home/<user>/homelab/compose/`
- los datos persistentes de aplicaciones viven en el **SSD NVMe** bajo `/home/<user>/homelab/data/<servicio>/`
- las configuraciones editables viven en `/home/<user>/homelab/config/<servicio>/`
- las bibliotecas multimedia se montan desde **`/mnt/hd2t`** o **`/mnt/hd5t`** según el servicio
- los backups del homelab se almacenan en **`/mnt/hd2t/backups/`**

Reglas operativas:

- no guardes bases de datos en `hd2t` ni en `hd5t`
- no uses volúmenes anónimos para datos importantes
- prefiere bind mounts con rutas explícitas para que el backup y la recuperación sean predecibles
- monta bibliotecas multimedia en modo lectura cuando el caso de uso lo permita

## Backup

En esta fase, lo que debe respaldarse es la estructura declarativa y los datos persistentes asociados:

- `/home/<user>/homelab/compose/`
- `/home/<user>/homelab/.env`
- todos los `.env` de cada stack
- `/home/<user>/homelab/config/`
- `/home/<user>/homelab/data/`
- scripts auxiliares bajo `/home/<user>/homelab/scripts/`

La red Docker compartida `homelab_proxy` no requiere backup propio: se puede recrear con un único comando. Lo importante es conservar los ficheros `compose`, variables y datos persistentes.

## Referencias

- Docker Docs: [Compose file reference](https://docs.docker.com/reference/compose-file/)
- Docker Docs: [Environment variables in Compose](https://docs.docker.com/compose/how-tos/environment-variables/set-environment-variables/)
- Docker Docs: [Define and manage networks in Docker Compose](https://docs.docker.com/reference/compose-file/networks/)
- Docker Docs: [Use multiple Compose files](https://docs.docker.com/compose/how-tos/multiple-compose-files/)
