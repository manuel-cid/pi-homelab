# WUD (What's Up Docker)

## Descripción

**WUD** (What's Up Docker) monitoriza los contenedores Docker del host, detecta cuándo existen imágenes nuevas disponibles y permite decidir si actualizar automáticamente o solo recibir notificación. Dispone de una **interfaz web** que muestra el estado de cada contenedor, las versiones disponibles y los triggers configurados.

En este proyecto, WUD se plantea como una herramienta de **mantenimiento controlado**, no como una política de actualización ciega para todo el host. La recomendación es trabajar en modo **opt-in**: solo se monitorizan los contenedores que no se excluyan expresamente, y las actualizaciones automáticas solo se activan para los servicios donde resulte seguro. Así se evita tocar sin supervisión servicios críticos, bases de datos o componentes de infraestructura sensibles.

## Requisitos Previos

- Haber completado [01-instalacion-docker.md](01-instalacion-docker.md).
- Haber completado [02-estructura-compose.md](02-estructura-compose.md).
- Haber completado [03-portainer.md](03-portainer.md) si se quiere inspeccionar el estado desde la UI, aunque no es obligatorio para desplegar WUD.
- Disponer del directorio operativo del homelab en `/home/<user>/homelab/`.
- Poder crear el stack en `/home/<user>/homelab/compose/infra-wud/`.
- Tener claro que WUD necesita acceso al socket Docker del host (`/var/run/docker.sock`), lo que implica capacidad de administración real sobre los contenedores.
- Disponer de conectividad saliente desde la Raspberry hacia los registros de imágenes Docker que usen los stacks del homelab.
- Si se van a activar notificaciones, disponer también de conectividad hacia el destino elegido: SMTP, webhook, Gotify u otro backend compatible.
- Puertos necesarios en esta fase:
  - **3000/tcp** publicado en el host para la interfaz web de WUD
  - el acceso debe limitarse a **LAN + Tailscale**; no exponer a internet

## Objetivo de esta Fase

Al terminar este documento, el estado esperado es este:

- WUD queda desplegado como stack propio `infra-wud`.
- Las comprobaciones de actualización quedan programadas en una ventana de mantenimiento definida.
- WUD monitoriza todos los contenedores por defecto, pero solo actualiza automáticamente los que tienen un trigger explícito.
- Los servicios sensibles quedan excluidos de la monitorización mediante la etiqueta `wud.watch=false`.
- La interfaz web queda accesible desde la LAN o desde Tailscale.
- Las notificaciones quedan documentadas como una opción adicional, no como un requisito obligatorio del despliegue base.

## Docker Compose

Archivo: `/home/<user>/homelab/compose/infra-wud/docker-compose.yml`

```yaml
name: infra-wud

services:
  wud:
    image: getwud/wud:latest
    container_name: wud
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      WUD_WATCHER_LOCAL_CRON: ${WUD_WATCHER_CRON}
      WUD_WATCHER_LOCAL_WATCHBYDEFAULT: ${WUD_WATCHER_WATCHBYDEFAULT}
    ports:
      - "${WUD_BIND_IP}:${WUD_PORT}:3000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /etc/localtime:/etc/localtime:ro
```

Este Compose sigue la convención definida en [02-estructura-compose.md](02-estructura-compose.md):

- stack independiente de infraestructura
- sin campo legado `version:`
- uso de `env_file` para separar configuración del YAML
- publicación explícita del puerto de la UI web

## Configuración

### 1. Preparar el directorio del stack

Crea el directorio del stack:

```bash
mkdir -p /home/<user>/homelab/compose/infra-wud
```

WUD no necesita un volumen de datos persistentes propio en el NVMe, porque su estado operativo es esencialmente efímero.

### 2. Crear el fichero `.env`

Archivo: `/home/<user>/homelab/compose/infra-wud/.env`

```dotenv
TZ=Europe/Madrid
WUD_WATCHER_CRON=0 4 * * *
WUD_WATCHER_WATCHBYDEFAULT=true
WUD_BIND_IP=0.0.0.0
WUD_PORT=3000
```

Notas de esta configuración:

- `WUD_WATCHER_CRON` usa una expresión cron estándar de **5 campos**.
- `0 4 * * *` significa comprobación diaria a las **04:00**.
- La zona horaria de referencia será `Europe/Madrid`, tanto para logs como para la planificación.
- `WUD_WATCHER_WATCHBYDEFAULT=true` indica que WUD monitoriza todos los contenedores del host salvo los excluidos expresamente con la etiqueta `wud.watch=false`.
- `WUD_BIND_IP=0.0.0.0` permite acceso desde la **LAN** y desde la IP de **Tailscale** del host.

Si en el futuro guardas secretos en este `.env`, por ejemplo credenciales de autenticación o una URL de webhook, aplica permisos restrictivos:

```bash
chmod 600 /home/<user>/homelab/compose/infra-wud/.env
```

### 3. Desplegar el stack

Valida la configuración y arranca WUD:

```bash
cd /home/<user>/homelab/compose/infra-wud
docker compose config
docker compose up -d
docker compose ps
```

Comprobaciones útiles tras el arranque:

```bash
docker compose logs --tail=50 wud
docker inspect "$(docker compose ps -q wud)" --format '{{json .Mounts}}'
ss -ltnp | grep 3000
```

El resultado esperado es que el contenedor quede en estado `Up`, que monte correctamente `/var/run/docker.sock` y `/etc/localtime`, y que el host escuche en `3000/tcp`.

### 4. Acceso a la interfaz web

Abre WUD desde un navegador en:

- `http://<ip-lan-de-la-raspberry>:3000`
- o `http://<ip-tailscale-de-la-raspberry>:3000`

La interfaz web muestra:

- un resumen general de watchers, registros y triggers configurados
- el estado de cada contenedor monitorizado
- si hay versiones nuevas disponibles para cada imagen
- el tipo de actualización detectada (major, minor, patch)
- botones para ejecutar triggers manualmente si están configurados con `AUTO=false`

Si quieres proteger la interfaz con autenticación básica, añade estas variables al `.env`:

```dotenv
WUD_AUTH_BASIC_MYUSER_USER=<tu_usuario>
WUD_AUTH_BASIC_MYUSER_HASH=<hash_apr1_con_dolar_duplicado>
```

Para generar el hash de contraseña:

```bash
openssl passwd -apr1
```

El hash resultante debe escapar cada `$` duplicándolo (`$$`) cuando se usa en ficheros de Compose o `.env` con interpolación de variables.

Y añade estas variables al bloque `environment:` del servicio:

```yaml
      WUD_AUTH_BASIC_MYUSER_USER: ${WUD_AUTH_BASIC_MYUSER_USER}
      WUD_AUTH_BASIC_MYUSER_HASH: ${WUD_AUTH_BASIC_MYUSER_HASH}
```

### 5. Política recomendada de monitorización y actualizaciones

WUD diferencia claramente entre **monitorizar** (detectar versiones nuevas) y **actualizar** (recrear el contenedor con la nueva imagen). Esta distinción es la pieza clave de su modelo:

- **monitorización**: WUD comprueba si existe una imagen más reciente. Es lo que hace por defecto para todos los contenedores visibles.
- **actualización automática**: requiere configurar un **trigger** explícito. Sin trigger, WUD solo informa; no toca nada.

Esto significa que el despliegue base de WUD es inherentemente seguro: no va a actualizar ningún contenedor a menos que se le indique expresamente cómo hacerlo.

Regla práctica recomendada:

- **sí** dejar que WUD monitorice todos los contenedores para tener visibilidad de versiones pendientes
- **sí** considerar triggers de actualización para aplicaciones sencillas sin dependencia fuerte de esquema o migraciones
- **no** configurar triggers de actualización para bases de datos, reverse proxy, DNS, autenticación o piezas troncales del homelab

### 6. Exclusiones

Si quieres excluir expresamente un servicio de la monitorización de WUD, añade la etiqueta `wud.watch=false` en el Compose del servicio:

```yaml
labels:
  - wud.watch=false
```

Esto es útil para:

- servicios especialmente sensibles que no quieres que aparezcan siquiera en la UI de WUD
- contenedores con imágenes privadas o sin tags semánticos que generarían ruido en la monitorización

Si prefieres el enfoque inverso, puedes cambiar `WUD_WATCHER_LOCAL_WATCHBYDEFAULT=false` en el `.env` de WUD y marcar expresamente cada contenedor que sí quieras monitorizar con `wud.watch=true`.

### 7. Control de tags

Cuando un contenedor usa el tag `latest`, WUD compara imágenes por digest. Esto puede generar muchas peticiones a Docker Hub y consumir rate limits. La recomendación es indicar a WUD qué tags debe considerar usando la etiqueta `wud.tag.include` con una expresión regular:

```yaml
labels:
  - "wud.tag.include=^\\d+\\.\\d+\\.\\d+$$"
```

Esto le indica a WUD que solo considere tags con formato semántico (`1.27.2`, `3.0.1`, etc.). Ajusta la regex al esquema de versionado de cada imagen.

### 8. Programación recomendada

La ventana por defecto propuesta en este homelab es:

- **cada día a las 04:00** hora local del host

Motivos:

- reduce la probabilidad de interferir con uso normal en la LAN
- deja una hora razonable para revisar por la mañana si hubo cambios o fallos
- encaja bien con una Raspberry Pi que normalmente estará encendida de forma continua

Si prefieres otra política, cambia solo la variable `WUD_WATCHER_CRON`. Ejemplos:

- `0 3 * * 0` para ejecutar los domingos a las 03:00
- `30 2 * * *` para ejecutar todos los días a las 02:30

### 9. Activar notificaciones opcionales

El despliegue base puede funcionar perfectamente sin notificaciones externas y apoyarse solo en la interfaz web y los logs:

```bash
docker compose logs -f wud
```

Si más adelante quieres recibir avisos por correo, webhook u otro canal, WUD soporta triggers de tipo SMTP, Slack, Gotify, IFTTT, Pushover y otros.

Ejemplo de variables adicionales en `.env` para notificación SMTP:

```dotenv
WUD_TRIGGER_SMTP_GMAIL_HOST=smtp.gmail.com
WUD_TRIGGER_SMTP_GMAIL_PORT=465
WUD_TRIGGER_SMTP_GMAIL_USER=tu_correo@gmail.com
WUD_TRIGGER_SMTP_GMAIL_PASS=contraseña_de_aplicacion
WUD_TRIGGER_SMTP_GMAIL_FROM=tu_correo@gmail.com
WUD_TRIGGER_SMTP_GMAIL_TO=destino@correo.com
```

Y añade estas variables al bloque `environment:` del servicio en el `docker-compose.yml`.

Recomendaciones prácticas:

- guarda credenciales fuera del `docker-compose.yml`, en el `.env`
- si el `.env` contiene secretos, protégelo con `chmod 600`
- usa `wud.trigger.include` en los contenedores para controlar qué triggers aplican a cada uno

En este proyecto, las notificaciones son opcionales porque el alcance del homelab es **LAN + Tailscale**, sin exposición pública a internet.

### 10. Operación habitual

Comandos útiles para la operación diaria:

```bash
cd /home/<user>/homelab/compose/infra-wud
docker compose logs --tail=100 wud
docker compose pull
docker compose up -d
```

Nota importante:

- WUD **no** debe convertirse en sustituto de una revisión mínima de cambios mayores
- sin triggers configurados, WUD solo informa; no actualiza nada
- la actualización de WUD debe hacerse manualmente cuando toque revisar la pila de infraestructura

## Almacenamiento

Rutas relevantes de este despliegue:

- `docker-compose.yml`: `/home/<user>/homelab/compose/infra-wud/docker-compose.yml`
- `.env`: `/home/<user>/homelab/compose/infra-wud/.env`
- socket Docker del host: `/var/run/docker.sock`
- hora local del host: `/etc/localtime`

Notas importantes:

- WUD no necesita un volumen persistente en `/home/<user>/homelab/data/`
- la definición del stack sí debe vivir en el **SSD NVMe**, junto al resto de `compose` y `.env`
- el acceso a `/var/run/docker.sock` concede a WUD capacidad administrativa real sobre los contenedores del host

## Backup

Lo que debe respaldarse para este stack es esto:

- `/home/<user>/homelab/compose/infra-wud/docker-compose.yml`
- `/home/<user>/homelab/compose/infra-wud/.env`
- cualquier fichero externo con secretos si decides usar credenciales SMTP, tokens o webhooks fuera del `.env`

No hay una base de datos propia de WUD ni un volumen persistente que conservar. Si se pierde el contenedor, el stack se reconstruye recreándolo a partir del `compose` y su configuración.

## Referencias

- WUD Docs: [Getting started](https://getwud.github.io/wud/)
- WUD GitHub: [getwud/wud](https://github.com/getwud/wud)
- Docker Hub: [getwud/wud](https://hub.docker.com/r/getwud/wud)
- Guía práctica: [How to Keep Containers Up-to-Date with WUD](https://linuxiac.com/how-to-keep-containers-up-to-date-with-whats-up-docker-wud/)
