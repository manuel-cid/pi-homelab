# Watchtower

## Descripción

**Watchtower** automatiza la comprobación de nuevas imágenes Docker y, cuando detecta una actualización, recrea los contenedores afectados usando la nueva imagen y la misma configuración con la que fueron desplegados originalmente. En un homelab pequeño como esta **Raspberry Pi 5**, resulta útil para reducir tareas repetitivas de mantenimiento, pero conviene usarlo con criterio.

En este proyecto, Watchtower se plantea como una herramienta de **mantenimiento controlado**, no como una política de actualización ciega para todo el host. La recomendación es trabajar en modo **opt-in**: solo se actualizan automáticamente los contenedores etiquetados explícitamente para ello. Así se evita tocar sin supervisión servicios críticos, bases de datos o componentes de infraestructura sensibles.

## Requisitos Previos

- Haber completado [01-instalacion-docker.md](01-instalacion-docker.md).
- Haber completado [02-estructura-compose.md](02-estructura-compose.md).
- Haber completado [03-portainer.md](03-portainer.md) si se quiere inspeccionar el estado desde la UI, aunque no es obligatorio para desplegar Watchtower.
- Disponer del directorio operativo del homelab en `/home/<user>/homelab/`.
- Poder crear el stack en `/home/<user>/homelab/compose/infra-watchtower/`.
- Tener claro que Watchtower necesita acceso al socket Docker del host (`/var/run/docker.sock`), lo que implica capacidad de administración real sobre los contenedores.
- Disponer de conectividad saliente desde la Raspberry hacia los registros de imágenes Docker que usen los stacks del homelab.
- Si se van a activar notificaciones, disponer también de conectividad hacia el destino elegido: SMTP, webhook, Gotify u otro backend compatible.
- Puertos necesarios en esta fase:
  - ninguno publicado en el host
  - no habilitar el modo HTTP API ni el endpoint de métricas salvo que exista una necesidad operativa concreta

## Objetivo de esta Fase

Al terminar este documento, el estado esperado es este:

- Watchtower queda desplegado como stack propio `infra-watchtower`.
- Las comprobaciones de actualización quedan programadas en una ventana de mantenimiento definida.
- Solo se actualizan automáticamente los contenedores marcados con la etiqueta correspondiente.
- Queda fijado un criterio claro para exclusiones y para contenedores en modo solo supervisión.
- Las notificaciones quedan documentadas como una opción adicional, no como un requisito obligatorio del despliegue base.

## Docker Compose

Archivo: `/home/<user>/homelab/compose/infra-watchtower/docker-compose.yml`

```yaml
name: infra-watchtower

services:
  watchtower:
    image: containrrr/watchtower:latest
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      WATCHTOWER_LABEL_ENABLE: "true"
      WATCHTOWER_CLEANUP: "true"
      WATCHTOWER_SCHEDULE: ${WATCHTOWER_SCHEDULE}
      WATCHTOWER_NO_STARTUP_MESSAGE: "true"
      WATCHTOWER_NOTIFICATIONS_LEVEL: ${WATCHTOWER_NOTIFICATIONS_LEVEL}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /etc/localtime:/etc/localtime:ro
```

Este Compose sigue la convención definida en [02-estructura-compose.md](02-estructura-compose.md):

- stack independiente de infraestructura
- sin campo legado `version:`
- sin puertos publicados
- uso de `env_file` para separar configuración del YAML
- política **opt-in** mediante `WATCHTOWER_LABEL_ENABLE=true`

## Configuración

### 1. Preparar el directorio del stack

Crea el directorio del stack:

```bash
mkdir -p /home/<user>/homelab/compose/infra-watchtower
```

Watchtower no necesita un volumen de datos persistentes propio en el NVMe, porque su estado operativo es esencialmente efímero.

### 2. Crear el fichero `.env`

Archivo: `/home/<user>/homelab/compose/infra-watchtower/.env`

```dotenv
TZ=Europe/Madrid
WATCHTOWER_SCHEDULE=0 0 4 * * *
WATCHTOWER_NOTIFICATIONS_LEVEL=info
```

Notas de esta configuración:

- `WATCHTOWER_SCHEDULE` usa una expresión cron de **6 campos**, no la tradicional de 5.
- `0 0 4 * * *` significa comprobación diaria a las **04:00:00**.
- La zona horaria de referencia será `Europe/Madrid`, tanto para logs como para la planificación.
- `WATCHTOWER_NOTIFICATIONS_LEVEL=info` deja preparado el nivel de notificación si más adelante activas un backend externo.

Si en el futuro guardas secretos en este `.env`, por ejemplo una URL de webhook o una contraseña SMTP, aplica permisos restrictivos:

```bash
chmod 600 /home/<user>/homelab/compose/infra-watchtower/.env
```

### 3. Desplegar el stack

Valida la configuración y arranca Watchtower:

```bash
cd /home/<user>/homelab/compose/infra-watchtower
docker compose config
docker compose up -d
docker compose ps
```

Comprobaciones útiles tras el arranque:

```bash
docker compose logs --tail=50 watchtower
docker inspect watchtower --format '{{json .Mounts}}'
```

El resultado esperado es que el contenedor quede en estado `Up` y que monte correctamente:

- `/var/run/docker.sock`
- `/etc/localtime`

### 4. Política recomendada de actualizaciones

La decisión más importante de este documento es esta:

- **no** dejes Watchtower actualizando todos los contenedores del host

Como el stack base activa `WATCHTOWER_LABEL_ENABLE=true`, solo se evaluarán contenedores con la etiqueta:

```yaml
labels:
  - com.centurylinklabs.watchtower.enable=true
```

Esto encaja bien con la estrategia del homelab:

- habilita actualizaciones automáticas solo en servicios simples y fáciles de recrear
- deja fuera servicios críticos, bases de datos y componentes de infraestructura delicados
- evita cambios inesperados en ventanas no supervisadas

Regla práctica recomendada:

- **sí** considerar autoactualización para aplicaciones sencillas sin dependencia fuerte de esquema o migraciones
- **no** activar autoactualización por defecto para bases de datos, reverse proxy, DNS, autenticación o piezas troncales del homelab

### 5. Exclusiones y modo solo supervisión

Si quieres excluir expresamente un servicio de cualquier evaluación por parte de Watchtower, usa:

```yaml
labels:
  - com.centurylinklabs.watchtower.enable=false
```

Esto puede ser útil incluso si el stack ya funciona en modo opt-in, porque deja documentada la intención de exclusión en el propio servicio.

Si quieres que Watchtower compruebe si hay nuevas imágenes y emita notificaciones, pero **sin aplicar la actualización**, usa:

```yaml
labels:
  - com.centurylinklabs.watchtower.enable=true
  - com.centurylinklabs.watchtower.monitor-only=true
```

Este modo es útil para:

- servicios sensibles que quieres revisar manualmente antes de recrear
- aplicaciones en las que te interesa saber que existe una imagen nueva, pero no actualizar en caliente
- periodos de validación antes de pasar un servicio a autoactualización real

### 6. Programación recomendada

La ventana por defecto propuesta en este homelab es:

- **cada día a las 04:00** hora local del host

Motivos:

- reduce la probabilidad de interferir con uso normal en la LAN
- deja una hora razonable para revisar por la mañana si hubo cambios o fallos
- encaja bien con una Raspberry Pi que normalmente estará encendida de forma continua

Si prefieres otra política, cambia solo la variable `WATCHTOWER_SCHEDULE`. Ejemplos:

- `0 0 3 * * 0` para ejecutar los domingos a las 03:00
- `0 30 2 * * *` para ejecutar todos los días a las 02:30

Conviene no mezclar planificación por cron y otros mecanismos alternativos de sondeo en el mismo despliegue.

### 7. Activar notificaciones opcionales

El despliegue base puede funcionar perfectamente sin notificaciones externas y apoyarse solo en:

```bash
docker compose logs -f watchtower
```

Si más adelante quieres recibir avisos, la forma recomendada es usar `WATCHTOWER_NOTIFICATION_URL`, que permite backends compatibles con **Shoutrrr**.

Ejemplo de variables adicionales en `.env`:

```dotenv
WATCHTOWER_NOTIFICATION_URL=gotify://<host>/<token>
WATCHTOWER_NOTIFICATION_REPORT=true
WATCHTOWER_NOTIFICATION_TITLE_TAG=homelab-rpi5
```

Y añade estas variables al bloque `environment:` del servicio:

```yaml
      WATCHTOWER_NOTIFICATION_URL: ${WATCHTOWER_NOTIFICATION_URL}
      WATCHTOWER_NOTIFICATION_REPORT: ${WATCHTOWER_NOTIFICATION_REPORT}
      WATCHTOWER_NOTIFICATION_TITLE_TAG: ${WATCHTOWER_NOTIFICATION_TITLE_TAG}
```

Recomendaciones prácticas:

- usa notificaciones de resumen (`WATCHTOWER_NOTIFICATION_REPORT=true`) para no generar ruido innecesario
- guarda tokens, contraseñas o webhooks fuera del `docker-compose.yml`
- si el canal de notificación contiene secretos, protégelos con permisos restrictivos

En este proyecto, las notificaciones son opcionales porque el alcance del homelab es **LAN + Tailscale**, sin exposición pública a internet.

### 8. Operación habitual

Comandos útiles para la operación diaria:

```bash
cd /home/<user>/homelab/compose/infra-watchtower
docker compose logs --tail=100 watchtower
docker compose pull
docker compose up -d
```

Nota importante:

- Watchtower **no** debe convertirse en sustituto de una revisión mínima de cambios mayores
- el propio contenedor de Watchtower queda fuera de la política de autoactualización porque el stack funciona en modo **opt-in** y este servicio no lleva la etiqueta `com.centurylinklabs.watchtower.enable=true`
- por tanto, la actualización de Watchtower debe hacerse manualmente cuando toque revisar la pila de infraestructura

## Almacenamiento

Rutas relevantes de este despliegue:

- `docker-compose.yml`: `/home/<user>/homelab/compose/infra-watchtower/docker-compose.yml`
- `.env`: `/home/<user>/homelab/compose/infra-watchtower/.env`
- socket Docker del host: `/var/run/docker.sock`
- hora local del host: `/etc/localtime`

Notas importantes:

- Watchtower no necesita un volumen persistente en `/home/<user>/homelab/data/`
- la definición del stack sí debe vivir en el **SSD NVMe**, junto al resto de `compose` y `.env`
- el acceso a `/var/run/docker.sock` concede a Watchtower capacidad administrativa real sobre los contenedores del host

## Backup

Lo que debe respaldarse para este stack es esto:

- `/home/<user>/homelab/compose/infra-watchtower/docker-compose.yml`
- `/home/<user>/homelab/compose/infra-watchtower/.env`
- cualquier fichero externo con secretos si decides usar URLs de notificación, tokens o contraseñas SMTP fuera del `.env`

No hay una base de datos propia de Watchtower ni un volumen persistente que conservar. Si se pierde el contenedor, el stack se reconstruye recreándolo a partir del `compose` y su configuración.

## Referencias

- Watchtower Docs: [Home](https://containrrr.dev/watchtower/)
- Watchtower Docs: [Arguments](https://containrrr.dev/watchtower/arguments/)
- Watchtower Docs: [Container selection](https://containrrr.dev/watchtower/container-selection/)
- Watchtower Docs: [Notifications](https://containrrr.dev/watchtower/notifications/)
- Docker Hub: [containrrr/watchtower](https://hub.docker.com/r/containrrr/watchtower)
