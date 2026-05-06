# Estructura de Stacks Docker Compose

## Descripción
Este documento define la convención de organización de **Docker Compose** para todo el homelab de la **Raspberry Pi 5**. El objetivo es que cada servicio sea fácil de desplegar, mantener, actualizar, respaldar y restaurar sin convertir el host en un único bloque difícil de operar.

La decisión recomendada para este proyecto es usar **un `compose.yaml` por stack**, no un `docker-compose.yml` monolítico con todos los servicios. Aunque la descripción del plan hable de `docker-compose.yml`, en este homelab se estandariza el nombre moderno **`compose.yaml`**, alineado con **Docker Compose v2** y con el comando `docker compose`.

Cada stack tendrá:

- un directorio propio en `/home/<usuario>/homelab/compose/<stack>/`
- su propio `compose.yaml`
- su propio `.env`
- sus rutas persistentes bajo `/home/<usuario>/homelab/data/<stack>/`
- su red privada por defecto
- acceso opcional a una red Docker compartida para comunicación entre stacks

Esta estrategia encaja mejor con un homelab heterogéneo donde convivirán herramientas de administración, servicios multimedia, aplicaciones con base de datos y utilidades con ciclos de vida distintos.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Tener Docker Engine operativo y el plugin `docker compose` funcionando.
- Tener creados, como mínimo, estos directorios base:
  - `/home/<usuario>/homelab/compose`
  - `/home/<usuario>/homelab/data`
  - `/mnt/hd2t`
  - `/mnt/hd5t`
- Tener claro que este homelab es solo para **LAN + Tailscale**, sin exposición pública a internet.
- Puertos implicados en esta fase:
  - esta documentación no exige publicar ningún puerto nuevo del host
  - cada stack documentará sus propios puertos cuando proceda
  - para comunicación entre contenedores debe priorizarse el uso de redes Docker frente a puertos publicados

## Docker Compose
La siguiente plantilla representa la convención base recomendada para cualquier stack del homelab. Es un ejemplo funcional y reutilizable: define `name`, separa variables en `.env`, usa bind mounts claros y conecta el servicio tanto a su red privada por defecto como a la red compartida `homelab_shared`.

Directorio de ejemplo:

```text
/home/<usuario>/homelab/compose/example-app/
├── compose.yaml
└── .env
```

Fichero `compose.yaml`:

```yaml
name: example-app

services:
  whoami:
    image: traefik/whoami:latest
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      WHOAMI_PORT_NUMBER: 8000
    ports:
      - "${WHOAMI_PORT}:8000"
    volumes:
      - /home/<usuario>/homelab/data/example-app/config:/config
    networks:
      - default
      - shared
    labels:
      com.centurylinklabs.watchtower.enable: "true"
    security_opt:
      - no-new-privileges:true

networks:
  shared:
    external: true
    name: homelab_shared
```

Fichero `.env` mínimo:

```dotenv
TZ=Europe/Madrid
WHOAMI_PORT=8081
```

Validación y despliegue del ejemplo:

```bash
mkdir -p /home/<usuario>/homelab/compose/example-app
mkdir -p /home/<usuario>/homelab/data/example-app/config

cd /home/<usuario>/homelab/compose/example-app
docker compose config
docker compose up -d
docker compose ps
```

Este ejemplo sirve como referencia operativa porque:

- cada stack se define en un directorio autónomo
- el nombre del proyecto queda fijado con `name:`
- las variables cambiantes se separan en `.env`
- la persistencia usa rutas explícitas y visibles en disco
- la integración entre stacks se resuelve con una red compartida, no publicando puertos internos innecesarios

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado al terminar este documento |
|---|---|
| Organización Compose | un directorio por stack |
| Fichero principal | `compose.yaml` por stack |
| Variables | `.env` local junto al compose |
| Red entre stacks | red externa `homelab_shared` |
| Persistencia | bind mounts bajo `/home/<usuario>/homelab/data` |
| Datos multimedia grandes | montajes desde `hd2t` y `hd5t` cuando aplique |
| Gestión futura | Portainer y Watchtower alineados con la misma convención |

### 1. Modelo recomendado: un stack por servicio o dominio funcional

En este homelab no se recomienda un único fichero monolítico con todos los servicios. La estrategia preferida es:

- **un stack por servicio independiente**
- o **un stack por dominio funcional** cuando varios contenedores forman una sola aplicación inseparable

Ejemplos razonables:

- `portainer`: stack propio
- `jellyfin`: stack propio
- `navidrome`: stack propio
- `paperless`: un stack conjunto con aplicación, base de datos y Redis

Comparativa práctica:

| Enfoque | Ventajas | Inconvenientes | Recomendación |
|---|---|---|---|
| Un solo compose monolítico | un único punto de entrada | mayor acoplamiento, reinicios amplios, troubleshooting más difícil, más riesgo en cambios pequeños | no recomendado |
| Un compose por stack | cambios localizados, despliegues aislados, mejor encaje con Portainer, backups y restores más claros | hay más directorios y más ficheros | recomendado |

Razones para preferir stacks pequeños:

- actualizar Jellyfin no debe afectar a Portainer ni a otros servicios
- un error de sintaxis en un stack no debe bloquear el resto del homelab
- el rollback de un servicio concreto es más simple
- la operación diaria en Portainer y por CLI resulta más clara

### 2. Estructura de directorios recomendada

La estructura operativa base queda así:

```text
/home/<usuario>/homelab/
├── compose/
│   ├── portainer/
│   │   ├── compose.yaml
│   │   └── .env
│   ├── jellyfin/
│   │   ├── compose.yaml
│   │   └── .env
│   ├── navidrome/
│   │   ├── compose.yaml
│   │   └── .env
│   └── paperless/
│       ├── compose.yaml
│       └── .env
├── data/
│   ├── portainer/
│   ├── jellyfin/
│   ├── navidrome/
│   └── paperless/
└── scripts/
```

Reglas de esta estructura:

- la definición del stack vive en `/home/<usuario>/homelab/compose/<stack>/`
- la persistencia del stack vive en `/home/<usuario>/homelab/data/<stack>/`
- las bibliotecas multimedia grandes no viven en `data`, sino en los discos USB montados
- los scripts comunes pueden centralizarse en `/home/<usuario>/homelab/scripts/`

### 3. Convención de nombres

Usar nombres coherentes desde el principio evita problemas en logs, backups, Portainer y resolución interna entre contenedores.

| Elemento | Convención recomendada | Ejemplo |
|---|---|---|
| Directorio del stack | minúsculas y kebab-case | `paperless`, `audiobookshelf` |
| Nombre del proyecto Compose | igual que el directorio | `name: paperless` |
| Fichero Compose | `compose.yaml` | `/home/<usuario>/homelab/compose/paperless/compose.yaml` |
| Fichero de variables | `.env` | `/home/<usuario>/homelab/compose/paperless/.env` |
| Ruta de datos | `/home/<usuario>/homelab/data/<stack>/` | `/home/<usuario>/homelab/data/paperless/` |
| Red compartida | `homelab_shared` | red externa única |

Convenciones adicionales:

- evita espacios, mayúsculas y nombres ambiguos
- usa `name:` para fijar el nombre del proyecto y evitar resultados inesperados
- no uses `container_name` salvo que haya una razón técnica real
- intenta que el nombre del stack, el directorio y la ruta de datos coincidan

### 4. Red Docker compartida

Cada stack tendrá su **red por defecto privada** creada automáticamente por Compose. Además, cuando un servicio necesite hablar con otro servicio que vive en otro stack, se conectará también a una red externa común llamada `homelab_shared`.

Crear la red una sola vez en el host:

```bash
docker network create homelab_shared
```

Comprobación:

```bash
docker network ls
docker network inspect homelab_shared
```

Reglas de uso de la red compartida:

- conecta a `homelab_shared` solo los servicios que realmente necesiten hablar con otros stacks
- deja bases de datos y caches en la red privada del stack salvo que exista una razón clara para exponerlos internamente
- no publiques puertos en el host solo para resolver comunicación entre contenedores
- usa nombres de servicio comprensibles si un contenedor va a ser consumido desde otro stack

Patrón recomendado:

- `default`: tráfico interno del stack
- `homelab_shared`: tráfico entre stacks

Ejemplo típico:

- `paperless-web` conectado a `default` y `homelab_shared`
- `paperless-db` conectado solo a `default`

Esto reduce superficie operativa y evita exponer servicios internos sin necesidad.

### 5. Convención para `.env`

Cada stack debe tener su propio fichero `.env` junto al `compose.yaml`.

Objetivos del `.env`:

- parametrizar puertos
- fijar zona horaria
- declarar `PUID` y `PGID` cuando la imagen lo use
- aislar secretos y valores operativos del YAML principal
- facilitar cambios pequeños sin editar la estructura del compose

Ejemplo típico:

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000
APP_PORT=8080
```

Reglas recomendadas:

- usa un `.env` por stack, no un `.env` gigante para todo el homelab
- guarda ahí los valores que cambian con más frecuencia
- referencia las variables con `${VARIABLE}` desde el compose
- aplica permisos restrictivos si el fichero contiene credenciales
- documenta en cada stack qué variables son obligatorias y cuáles opcionales

Permisos recomendados si contiene secretos:

```bash
chmod 700 /home/<usuario>/homelab/compose/<stack>
chmod 600 /home/<usuario>/homelab/compose/<stack>/.env
```

Criterio práctico para secretos:

- si la imagen admite otro mecanismo más seguro que variables de entorno, valora usarlo
- si la imagen solo admite usuario, password o token por variables, guárdalos en el `.env` del stack
- evita compartir el mismo secreto entre varios stacks si no es necesario

### 6. Qué debe ir dentro del mismo stack

Una regla simple para decidir si varios servicios deben vivir en el mismo `compose.yaml`:

- si se despliegan, actualizan, paran y restauran siempre juntos, van en el mismo stack
- si tienen ciclo de vida propio, van en stacks distintos

Normalmente deben ir juntos:

- aplicación + base de datos propia
- aplicación + Redis propio
- aplicación + worker o scheduler de la misma aplicación

Normalmente deben ir separados:

- Portainer respecto al resto del homelab
- Jellyfin respecto a Navidrome
- Watchtower como stack independiente
- herramientas auxiliares que puedan reiniciarse o actualizarse sin tocar otras

### 7. Flujo operativo recomendado por stack

Una vez creada la estructura, el manejo diario de cada stack debería seguir siempre el mismo patrón:

```bash
cd /home/<usuario>/homelab/compose/<stack>
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f
```

Para parar un stack concreto:

```bash
cd /home/<usuario>/homelab/compose/<stack>
docker compose down
```

Ventajas de este flujo:

- cada stack se valida de forma aislada
- los errores se localizan mejor
- los cambios tienen menos radio de impacto
- Portainer puede gestionar cada stack sin arrastrar todo el homelab

### 8. Relación con Portainer y Watchtower

Esta convención está pensada para encajar con los documentos siguientes de la fase:

- **Portainer** gestionará mejor stacks pequeños, con nombres claros y rutas previsibles
- **Watchtower** podrá trabajar con etiquetas por stack o por servicio sin obligar a una estrategia monolítica
- el troubleshooting será más simple porque cada servicio tendrá una frontera operativa clara

En consecuencia, la fuente de verdad del homelab debe seguir siendo:

- el `compose.yaml` guardado en disco
- el `.env` del stack
- las rutas persistentes del stack en `data`

Portainer debe actuar como capa operativa y visual, no como único lugar donde exista la definición real del despliegue.

## Almacenamiento

La política de almacenamiento para Compose en este homelab queda así:

| Tipo de dato | Ruta recomendada | Disco |
|---|---|---|
| Ficheros `compose.yaml` | `/home/<usuario>/homelab/compose/<stack>/` | SSD NVMe |
| Ficheros `.env` | `/home/<usuario>/homelab/compose/<stack>/` | SSD NVMe |
| Configuración persistente | `/home/<usuario>/homelab/data/<stack>/config/` | SSD NVMe |
| Bases de datos y volúmenes críticos | `/home/<usuario>/homelab/data/<stack>/` | SSD NVMe |
| Descargas y bibliotecas multimedia generales | `/mnt/hd2t/...` | `hd2t` |
| Biblioteca multimedia principal de Stash | `/mnt/hd5t/...` | `hd5t` |

Reglas operativas:

- prioriza **bind mounts** frente a volúmenes anónimos o poco visibles
- mantén en el NVMe todo lo necesario para arrancar y restaurar servicios
- usa `hd2t` y `hd5t` para bibliotecas grandes, no para el runtime básico de Docker
- evita que un stack dependa de un disco USB para arrancar si ese disco no es esencial para su función

Ejemplos correctos:

- Jellyfin: configuración y metadatos en NVMe, bibliotecas en `hd2t`
- Stash: metadatos en NVMe, contenido grande en `hd5t`

## Backup
La estrategia de backup debe respetar la misma frontera por stack.

Conviene respaldar como mínimo:

- `/home/<usuario>/homelab/compose/<stack>/compose.yaml`
- `/home/<usuario>/homelab/compose/<stack>/.env`
- `/home/<usuario>/homelab/data/<stack>/`
- cualquier dump de base de datos que ese stack genere
- las rutas de media si contienen datos irremplazables o metadatos no regenerables

No es necesario tratar como backup principal:

- las imágenes Docker descargadas
- los contenedores recreables
- la red `homelab_shared`

La idea correcta es:

1. reconstruir el stack desde `compose.yaml`
2. restaurar después su configuración y sus datos persistentes

Esto refuerza precisamente la ventaja del enfoque por stack: restauraciones más pequeñas, más rápidas y con menos riesgo.

## Referencias
- Docker Docs: Compose file reference: https://docs.docker.com/reference/compose-file/
- Docker Docs: Networking in Compose: https://docs.docker.com/compose/how-tos/networking/
- Docker Docs: Environment variables in Compose: https://docs.docker.com/compose/environment-variables/
- Docker Docs: Best practices for environment variables in Docker Compose: https://docs.docker.com/compose/how-tos/environment-variables/best-practices/
- Docker Docs: Use multiple Compose files: https://docs.docker.com/compose/how-tos/multiple-compose-files/
