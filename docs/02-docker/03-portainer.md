# Portainer CE

## Descripción
**Portainer CE** proporciona una interfaz web para administrar Docker en la **Raspberry Pi 5**, visualizar contenedores, redes, volúmenes, logs y desplegar stacks Compose sin depender siempre de la terminal.

En este homelab su papel es servir como consola operativa para el host local, manteniendo la misma estrategia definida en `docs/02-docker/02-estructura-compose.md`: **un stack por servicio**, con sus ficheros `compose.yaml` y `.env` guardados en disco bajo `/home/<usuario>/homelab/compose/`.

Portainer no sustituye la organización en archivos ni el uso de Docker Compose como fuente de verdad. La recomendación para este proyecto es usar Portainer como capa de administración visual, troubleshooting y despliegue controlado de stacks, no como único lugar donde exista la definición del homelab.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Tener Docker Engine operativo y el comando `docker compose` funcionando en ARM64.
- Tener creada la estructura base del proyecto, al menos:
  - `/home/<usuario>/homelab/compose`
  - `/home/<usuario>/homelab/data`
- Tener acceso SSH al host con privilegios para crear directorios y desplegar el stack.
- Puertos implicados en esta fase:
  - `9443/tcp` publicado en el host para acceder a la UI HTTPS de Portainer
  - `8000/tcp` no se publica en este homelab porque no se usarán Edge Agents
  - `9000/tcp` no se usa; se prioriza el acceso HTTPS en `9443`
  - `/var/run/docker.sock` se monta en el contenedor para administrar el Docker local

## Docker Compose
La recomendación es desplegar Portainer desde terminal una primera vez y dejar su stack almacenado en `/home/<usuario>/homelab/compose/portainer/`.

Directorio recomendado:

```text
/home/<usuario>/homelab/compose/portainer/
├── compose.yaml
└── .env
```

Fichero `compose.yaml`:

```yaml
name: portainer

services:
  portainer:
    image: portainer/portainer-ce:lts
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    ports:
      - "${PORTAINER_HTTPS_PORT}:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /home/<usuario>/homelab/data/portainer/data:/data
    security_opt:
      - no-new-privileges:true
```

Fichero `.env` mínimo:

```dotenv
TZ=Europe/Madrid
PORTAINER_HTTPS_PORT=9443
```

Despliegue inicial:

```bash
mkdir -p /home/<usuario>/homelab/compose/portainer
mkdir -p /home/<usuario>/homelab/data/portainer/data

cd /home/<usuario>/homelab/compose/portainer
docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

Resultado esperado:

- el contenedor `portainer-portainer-1` queda levantado
- la interfaz queda accesible en `https://<IP-del-host>:9443`
- Portainer detecta el entorno Docker local mediante el socket montado

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado al terminar este documento |
|---|---|
| UI de administración | Portainer CE accesible por HTTPS local |
| Entorno gestionado | Docker local de la Raspberry Pi |
| Persistencia | datos de Portainer guardados en el NVMe |
| Gestión de stacks | disponible desde Portainer y desde CLI |
| Superficie expuesta | solo `9443/tcp` en LAN y Tailscale |

### 1. Preparar el directorio del stack

Crear las rutas necesarias:

```bash
mkdir -p /home/<usuario>/homelab/compose/portainer
mkdir -p /home/<usuario>/homelab/data/portainer/data
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/portainer
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/portainer
```

Portainer almacena su base de datos interna, usuarios, endpoints, stacks gestionados por la propia UI y metadatos dentro de `/data`, por lo que esta ruta debe persistir en el **SSD NVMe**.

### 2. Desplegar Portainer

Una vez guardados `compose.yaml` y `.env`:

```bash
cd /home/<usuario>/homelab/compose/portainer
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f
```

Si necesitas verificar el puerto publicado desde el host:

```bash
ss -tulpn | grep 9443
```

### 3. Realizar la configuración inicial en la web

Abrir en el navegador:

```text
https://<IP-del-host>:9443
```

En el primer acceso:

1. Crear el usuario administrador de Portainer.
2. Usar una contraseña robusta, única y de al menos 12 caracteres.
3. Completar el asistente inicial dentro de los primeros minutos tras arrancar el contenedor.
4. Seleccionar el entorno local de Docker cuando Portainer lo ofrezca.
5. Entrar en la interfaz principal con `Get Started`.

Comportamiento esperado en este escenario:

- el acceso será por **HTTPS** con un certificado autofirmado de Portainer
- el navegador mostrará una advertencia inicial de certificado, algo normal en un entorno solo LAN + Tailscale
- si no completas la creación del usuario administrador a tiempo, Portainer dejará de responder hasta reiniciar el contenedor
- no hace falta publicar Portainer en internet ni configurar proxy inverso para esta fase

Ajustes recomendados justo después del primer acceso:

- revisar `Settings` y desactivar la recopilación de estadísticas anónimas si prefieres minimizar telemetría
- dejar el intervalo de snapshot por defecto salvo que más adelante gestiones muchos entornos adicionales
- no añadir más endpoints ni agentes mientras este homelab siga siendo un único host Docker

### 4. Decisión operativa recomendada para stacks

Aunque Portainer permite crear stacks desde la propia UI, en este homelab conviene mantener una disciplina clara:

- el **source of truth** de cada stack debe seguir siendo el fichero `/home/<usuario>/homelab/compose/<stack>/compose.yaml`
- el `.env` del stack debe vivir junto a su compose
- Portainer debe usarse para inspección, arranque, parada, logs, consola y despliegues puntuales

La práctica más segura y mantenible es:

1. crear primero el directorio del stack en disco
2. guardar ahí `compose.yaml` y `.env`
3. validar con `docker compose config`
4. desplegar desde CLI o importar ese contenido en Portainer

Esto evita que la definición real del homelab quede fragmentada entre archivos locales y ediciones ad hoc en la web.

### 5. Gestión recomendada de stacks desde Portainer

Portainer resulta especialmente útil para:

- revisar el estado de contenedores, redes y volúmenes
- ver logs sin entrar por SSH
- reiniciar un stack concreto
- desplegar un stack ya definido en Compose
- identificar rápidamente qué imagen está corriendo en cada servicio

Buenas prácticas concretas para este proyecto:

- mantener **un stack por servicio o dominio funcional**, igual que en `docs/02-docker/02-estructura-compose.md`
- asignar nombres de stack iguales al directorio cuando sea posible
- evitar editar desde Portainer un stack cuyo `compose.yaml` se esté manteniendo manualmente en disco, salvo que luego se sincronice ese cambio
- no usar Portainer para almacenar secretos si ya están definidos y documentados en el `.env` del stack correspondiente

Flujo operativo recomendado para un stack nuevo:

1. crear `/home/<usuario>/homelab/compose/<stack>/`
2. guardar ahí `compose.yaml` y `.env`
3. validar el YAML con `docker compose config`
4. desplegarlo desde CLI o usar Portainer para cargar ese mismo contenido
5. usar Portainer después para operación diaria, logs y reinicios controlados

Si decides crear un stack directamente desde la UI de Portainer:

- usa el mismo nombre que tendría en disco
- copia exactamente el contenido del `compose.yaml` versionado
- documenta también fuera de Portainer cualquier variable sensible o ajuste manual
- asume que la definición almacenada por Portainer en `/data` pasa a formar parte del backup del servicio

La política más mantenible para este homelab sigue siendo esta:

- **archivos en disco como fuente de verdad**
- **Portainer como capa operativa y visual**

### 6. Operaciones habituales desde la UI

Tareas típicas que sí merece la pena hacer desde Portainer:

- revisar contenedores en estado `unhealthy` o reiniciando
- abrir logs recientes de un servicio sin entrar por SSH
- escalar temporalmente un stack sencillo durante pruebas
- confirmar qué variables, puertos y bind mounts tiene aplicado un servicio
- parar e iniciar un stack concreto durante mantenimiento

Tareas que conviene seguir haciendo fuera de la UI o al menos reflejar después en archivos:

- cambios estructurales de `compose.yaml`
- rotación de credenciales
- modificaciones de rutas persistentes
- cambios de imagen o de tag que deban quedar documentados

### 7. Límites y decisiones de red

Para este homelab no es necesario:

- publicar `8000/tcp`
- usar Edge Agent
- exponer Portainer fuera de la red local
- integrarlo con Let's Encrypt, DDNS o acceso público

La exposición recomendada es únicamente:

- acceso desde la LAN
- acceso remoto privado mediante Tailscale

Si Tailscale ya está configurado en el host, Portainer será accesible también mediante la IP o nombre de MagicDNS de Tailscale usando el mismo puerto `9443`.

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose de Portainer | `/home/<usuario>/homelab/compose/portainer/` | SSD NVMe |
| Variables del stack | `/home/<usuario>/homelab/compose/portainer/.env` | SSD NVMe |
| Datos persistentes de Portainer | `/home/<usuario>/homelab/data/portainer/data/` | SSD NVMe |
| Socket Docker del host | `/var/run/docker.sock` | SSD NVMe |

Notas de almacenamiento:

- toda la persistencia de Portainer debe quedarse en el **NVMe**
- Portainer no necesita guardar bibliotecas multimedia ni datos en `hd2t` o `hd5t`
- el bind mount de `/data` es crítico; sin él perderías usuarios, configuración, endpoints y stacks almacenados por Portainer
- el socket `/var/run/docker.sock` no contiene datos persistentes, pero sí concede acceso administrativo al Docker del host

## Backup
Conviene respaldar como mínimo:

- `/home/<usuario>/homelab/compose/portainer/compose.yaml`
- `/home/<usuario>/homelab/compose/portainer/.env`
- `/home/<usuario>/homelab/data/portainer/data/`

No es necesario respaldar:

- la imagen `portainer/portainer-ce`
- el contenedor recreable
- el socket `/var/run/docker.sock`

Estrategia práctica de restauración:

1. reinstalar Docker si hiciera falta
2. recrear las rutas del stack
3. restaurar `compose.yaml`, `.env` y el directorio `/data`
4. ejecutar `docker compose up -d`

## Referencias
- Portainer Docs: Install Portainer CE with Docker on Linux  
  https://docs.portainer.io/2.33-lts/start/install-ce/server/docker/linux
- Portainer Docs: Initial setup  
  https://docs.portainer.io/start/install-ce/server/setup
- Portainer Docs: General settings  
  https://docs.portainer.io/admin/settings/general
- Portainer Docs: Add a stack  
  https://docs.portainer.io/user/docker/stacks/add
- Docker Hub: `portainer/portainer-ce`  
  https://hub.docker.com/r/portainer/portainer-ce
