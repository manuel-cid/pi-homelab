# Portainer CE

## Descripción

**Portainer CE** aporta una interfaz web ligera para administrar el motor Docker del homelab: contenedores, imágenes, volúmenes, redes y stacks. En una Raspberry Pi 5 resulta especialmente útil para operaciones cotidianas de mantenimiento, consulta rápida del estado de servicios y despliegues puntuales sin depender siempre de la terminal.

En este proyecto, Portainer se usa como **capa de gestión**, no como sustituto del diseño operativo definido en [01-instalacion-docker.md](/Users/x441425/workspace2/homelab/docs/02-docker/01-instalacion-docker.md) y [02-estructura-compose.md](/Users/x441425/workspace2/homelab/docs/02-docker/02-estructura-compose.md). El motor sigue siendo Docker Engine local, los datos persistentes siguen viviendo en el **SSD NVMe** y la publicación del panel queda limitada a la **LAN** y, si se desea, a acceso remoto a través de **Tailscale**.

## Requisitos Previos

- Haber completado [01-instalacion-docker.md](/Users/x441425/workspace2/homelab/docs/02-docker/01-instalacion-docker.md).
- Haber completado [02-estructura-compose.md](/Users/x441425/workspace2/homelab/docs/02-docker/02-estructura-compose.md).
- Disponer del directorio operativo del homelab en `/home/<user>/homelab/`.
- Poder crear directorios persistentes bajo `/home/<user>/homelab/data/`.
- Tener claro que Portainer necesitará acceso al socket Docker del host (`/var/run/docker.sock`).
- Puertos necesarios en esta fase:
  - **9443/tcp** publicado en el host para la interfaz web HTTPS de Portainer
  - **8000/tcp** no se publica en este proyecto porque no se usará Edge Agent
  - **9000/tcp** no se publica porque se evita la interfaz HTTP legado

## Objetivo de esta Fase

Al terminar este documento, el estado esperado es este:

- Portainer CE queda desplegado como stack propio `infra-portainer`.
- La interfaz web queda accesible desde la LAN o desde Tailscale por `https://<ip-del-host>:9443`.
- El almacenamiento persistente de Portainer queda en el **SSD NVMe**.
- El entorno local Docker queda registrado en Portainer.
- Queda definido un criterio claro para gestionar stacks sin mezclar irresponsablemente Portainer y CLI.

## Docker Compose

Archivo: `/home/<user>/homelab/compose/infra-portainer/docker-compose.yml`

```yaml
name: infra-portainer

services:
  portainer:
    image: portainer/portainer-ce:lts
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    ports:
      - "${PORTAINER_BIND_IP}:${PORTAINER_HTTPS_PORT}:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${DATA_ROOT}/portainer:/data
    labels:
      - com.centurylinklabs.watchtower.enable=true
```

Este Compose sigue la convención definida en [02-estructura-compose.md](/Users/x441425/workspace2/homelab/docs/02-docker/02-estructura-compose.md):

- stack independiente para infraestructura
- sin campo legado `version:`
- datos persistentes en el **SSD NVMe**
- publicación explícita solo del puerto necesario
- etiqueta preparada para la política futura de Watchtower

## Configuración

### 1. Preparar directorios del stack

Crea el directorio del stack y el directorio de datos persistentes:

```bash
mkdir -p /home/<user>/homelab/compose/infra-portainer
mkdir -p /home/<user>/homelab/data/portainer
```

### 2. Crear el fichero `.env`

Archivo: `/home/<user>/homelab/compose/infra-portainer/.env`

```dotenv
TZ=Europe/Madrid
DATA_ROOT=/home/<user>/homelab/data
PORTAINER_BIND_IP=0.0.0.0
PORTAINER_HTTPS_PORT=9443
```

Notas de esta configuración:

- `PORTAINER_BIND_IP=0.0.0.0` permite acceso desde la **LAN** y desde la IP de **Tailscale** del host.
- Si prefieres que Portainer solo sea accesible localmente o detrás de un proxy futuro, cambia a `127.0.0.1`.
- El fichero `.env` no contiene credenciales iniciales, así que no requiere nada especial aparte de la disciplina habitual del proyecto.

### 3. Desplegar el stack

Sitúate en el directorio del stack, valida la sintaxis y arranca Portainer:

```bash
cd /home/<user>/homelab/compose/infra-portainer
docker compose config
docker compose up -d
docker compose ps
```

Validaciones útiles tras el arranque:

```bash
docker compose logs --tail=50 portainer
ss -ltnp | grep 9443
```

El resultado esperado es que el contenedor quede en estado `Up` y que el host escuche en `9443/tcp`.

### 4. Acceso inicial a la interfaz web

Abre Portainer desde un navegador en:

- `https://<ip-lan-de-la-raspberry>:9443`
- o `https://<ip-tailscale-de-la-raspberry>:9443`

Como el certificado inicial de Portainer es propio del contenedor, el navegador mostrará un aviso de confianza la primera vez. En este proyecto eso es aceptable porque:

- no hay exposición pública a internet
- el acceso queda restringido a **LAN + Tailscale**
- más adelante, si interesa, Portainer puede publicarse detrás del reverse proxy interno del homelab

En el primer acceso:

- crea el usuario administrador con una contraseña robusta y única
- completa el alta inicial del entorno local si Portainer lo solicita
- confirma que el endpoint local Docker aparece como entorno gestionado

### 5. Ajustes recomendados tras el primer login

Revisión mínima recomendada dentro de la UI:

- verifica que el entorno local apunta al Docker del host correcto
- revisa contenedores, imágenes, redes y volúmenes para confirmar visibilidad completa
- comprueba que la zona horaria y la hora mostrada son coherentes con el host
- crea, si quieres, un usuario no administrador solo para consulta, pero mantén una cuenta admin para operaciones reales

En este homelab no hace falta:

- Edge Agent
- entornos remotos adicionales
- registro externo obligatorio
- exposición del puerto `8000`

### 6. Criterio recomendado para gestión de stacks

Portainer puede gestionar stacks, pero conviene fijar una norma clara para no crear deriva entre la UI y los ficheros del host.

Regla práctica recomendada:

- usa **CLI + archivos en disco** como fuente de verdad del homelab
- usa Portainer para inspección, logs, reinicios controlados y operaciones diarias
- si despliegas un stack desde Portainer, considera que Portainer pasa a ser el punto de edición de ese stack
- no edites el mismo stack indistintamente desde Portainer y desde `docker compose` sin un proceso claro

Motivo de esta norma:

- Portainer guarda internamente la definición de los stacks creados desde su UI
- `docker compose` usa los archivos reales del sistema de ficheros
- si ambos caminos se usan sin disciplina, es fácil perder el rastro del estado real

Criterio concreto para este proyecto:

- **infraestructura base crítica** como Portainer debe poder reconstruirse siempre desde archivos en `/home/<user>/homelab/compose/`
- para servicios pequeños, Portainer puede servir como interfaz cómoda de despliegue, pero cualquier cambio importante debe reflejarse también en la estructura documental del homelab

### 7. Operaciones habituales desde Portainer

Usos especialmente prácticos en este entorno:

- revisar rápidamente qué contenedores están caídos o reiniciando
- consultar logs sin entrar por SSH
- parar, arrancar o recrear contenedores durante mantenimiento
- inspeccionar redes, puertos publicados y volúmenes
- validar el consumo general de recursos antes de ampliar el homelab

Portainer es útil, pero no sustituye la necesidad de:

- conservar los `docker-compose.yml`
- mantener `.env` ordenados
- respaldar datos persistentes
- documentar puertos y dependencias entre servicios

## Almacenamiento

Portainer usa estas rutas relevantes en este despliegue:

- `docker-compose.yml`: `/home/<user>/homelab/compose/infra-portainer/docker-compose.yml`
- `.env`: `/home/<user>/homelab/compose/infra-portainer/.env`
- datos persistentes del contenedor: `/home/<user>/homelab/data/portainer`
- socket Docker del host: `/var/run/docker.sock`

Notas importantes:

- los datos persistentes de Portainer deben permanecer en el **SSD NVMe**
- no conviene mover `/data` a `hd2t` ni a `hd5t`
- el montaje del socket Docker otorga a Portainer control administrativo real sobre Docker en el host
- el directorio `/home/<user>/homelab/data/portainer` debe pertenecer al usuario del host que opera Docker o, como mínimo, ser escribible por Docker

## Backup

Lo que debe respaldarse para Portainer es esto:

- `/home/<user>/homelab/compose/infra-portainer/docker-compose.yml`
- `/home/<user>/homelab/compose/infra-portainer/.env`
- `/home/<user>/homelab/data/portainer/`

El punto más importante es `/home/<user>/homelab/data/portainer/`, porque ahí viven:

- la base de datos interna de Portainer
- la configuración de la interfaz
- usuarios locales creados en Portainer
- definiciones de stacks creados directamente desde la UI

Aunque Portainer pueda reconstruirse desde cero, respaldar su directorio de datos evita perder configuraciones y metadatos operativos. Aun así, la política correcta del homelab sigue siendo conservar los stacks importantes también fuera de Portainer, en archivos versionables del host.

## Referencias

- Portainer Docs: [Portainer CE installation with Docker](https://docs.portainer.io/start/install-ce/server/docker)
- Portainer Docs: [Add and manage environments](https://docs.portainer.io/admin/environments/add/docker)
- Portainer Docs: [Manage stacks](https://docs.portainer.io/user/docker/stacks)
- Docker Hub: [portainer/portainer-ce](https://hub.docker.com/r/portainer/portainer-ce)
