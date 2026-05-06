# Watchtower

## Descripción
**Watchtower** automatiza la comprobación de nuevas imágenes Docker y, cuando corresponde, recrea los contenedores afectados con la versión actualizada.

En este homelab su función es reducir trabajo operativo en servicios de bajo riesgo, manteniendo una política conservadora: **solo se actualiza automáticamente lo que se etiquete de forma explícita**. La recomendación no es dejar que Watchtower toque todos los contenedores indiscriminadamente, sino combinar **programación fija**, **etiquetas por servicio**, **exclusiones claras** y **notificaciones** para saber qué se ha actualizado y qué ha fallado.

Watchtower complementa a Docker Compose y Portainer, pero no sustituye el control manual de cambios. Los servicios más delicados o con dependencias fuertes deben seguir actualizándose de forma manual y revisada.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/02-docker/03-portainer.md`.
- Tener Docker Engine operativo y el comando `docker compose` funcionando en ARM64.
- Tener creada la estructura base del proyecto, al menos:
  - `/home/<usuario>/homelab/compose`
  - `/home/<usuario>/homelab/data`
- Tener claro qué servicios del homelab se actualizarán automáticamente y cuáles quedarán en actualización manual.
- Disponer de salida a internet desde la Raspberry Pi para consultar registros y descargar imágenes nuevas.
- Puertos implicados en esta fase:
  - Watchtower **no necesita publicar puertos** en el host para su funcionamiento normal
  - `/var/run/docker.sock` se monta en el contenedor para que pueda inspeccionar y recrear contenedores locales
  - si más adelante se habilitan notificaciones externas, podrían intervenir puertos salientes como `443/tcp`, `465/tcp` o `587/tcp` según el destino

## Docker Compose
La recomendación es desplegar Watchtower como un stack propio en `/home/<usuario>/homelab/compose/watchtower/`.

Directorio recomendado:

```text
/home/<usuario>/homelab/compose/watchtower/
├── compose.yaml
└── .env
```

Fichero `compose.yaml`:

```yaml
name: watchtower

services:
  watchtower:
    image: containrrr/watchtower:latest
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      WATCHTOWER_SCHEDULE: ${WATCHTOWER_SCHEDULE}
      WATCHTOWER_LABEL_ENABLE: ${WATCHTOWER_LABEL_ENABLE}
      WATCHTOWER_CLEANUP: ${WATCHTOWER_CLEANUP}
      WATCHTOWER_ROLLING_RESTART: ${WATCHTOWER_ROLLING_RESTART}
      WATCHTOWER_NO_STARTUP_MESSAGE: ${WATCHTOWER_NO_STARTUP_MESSAGE}
      WATCHTOWER_NOTIFICATION_REPORT: ${WATCHTOWER_NOTIFICATION_REPORT}
      WATCHTOWER_NOTIFICATION_LOG_STDOUT: ${WATCHTOWER_NOTIFICATION_LOG_STDOUT}
      WATCHTOWER_NOTIFICATION_URL: ${WATCHTOWER_NOTIFICATION_URL}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /etc/localtime:/etc/localtime:ro
    labels:
      com.centurylinklabs.watchtower.enable: "false"
    security_opt:
      - no-new-privileges:true
```

Fichero `.env` recomendado:

```dotenv
TZ=Europe/Madrid
WATCHTOWER_SCHEDULE=0 0 5 * * *
WATCHTOWER_LABEL_ENABLE=true
WATCHTOWER_CLEANUP=true
WATCHTOWER_ROLLING_RESTART=true
WATCHTOWER_NO_STARTUP_MESSAGE=true
WATCHTOWER_NOTIFICATION_REPORT=true
WATCHTOWER_NOTIFICATION_LOG_STDOUT=true
WATCHTOWER_NOTIFICATION_URL=logger://
```

Notas sobre este ejemplo:

- `WATCHTOWER_SCHEDULE` usa una expresión cron de **6 campos**
- con `WATCHTOWER_LABEL_ENABLE=true`, solo se actualizan los contenedores etiquetados con `com.centurylinklabs.watchtower.enable: "true"`
- el propio Watchtower queda excluido con la etiqueta `"false"`
- `WATCHTOWER_CLEANUP=true` elimina imágenes antiguas después de una actualización correcta
- `logger://` permite dejar un canal de notificación funcional en los logs del contenedor
- cuando ya tengas un webhook o servicio real, sustituye `WATCHTOWER_NOTIFICATION_URL` por su URL correspondiente

Despliegue inicial:

```bash
mkdir -p /home/<usuario>/homelab/compose/watchtower

cd /home/<usuario>/homelab/compose/watchtower
docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

Resultado esperado:

- el contenedor `watchtower-watchtower-1` queda levantado
- Watchtower consulta periódicamente si hay imágenes nuevas según la programación definida
- solo actúa sobre contenedores etiquetados para ello
- los eventos de actualización o fallo aparecen en `docker compose logs -f`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado al terminar este documento |
|---|---|
| Política de actualización | automática solo para contenedores etiquetados |
| Programación | ventana fija y predecible |
| Exclusiones | definidas por etiqueta o por lista |
| Persistencia | sin datos de aplicación que proteger |
| Notificaciones | resumen por ejecución disponible |
| Riesgo operativo | contenido mediante enfoque opt-in |

### 1. Preparar el stack

Crear la ruta del stack:

```bash
mkdir -p /home/<usuario>/homelab/compose/watchtower
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/watchtower
chmod 700 /home/<usuario>/homelab/compose/watchtower
```

Después de crear el fichero `.env`, si contiene URLs con tokens o credenciales, aplica:

```bash
chmod 600 /home/<usuario>/homelab/compose/watchtower/.env
```

Watchtower no necesita un directorio persistente bajo `/home/<usuario>/homelab/data`, porque su estado operativo reside en el propio Docker del host y en la definición del stack.

### 2. Estrategia recomendada de actualización

En este homelab la estrategia recomendada es **opt-in**:

- Watchtower se despliega una sola vez
- ningún contenedor se actualiza automáticamente por defecto
- solo reciben auto-actualización los stacks o servicios que lleven la etiqueta explícita

Etiqueta para **incluir** un servicio en Watchtower:

```yaml
labels:
  com.centurylinklabs.watchtower.enable: "true"
```

Etiqueta para **excluirlo** de forma explícita:

```yaml
labels:
  com.centurylinklabs.watchtower.enable: "false"
```

Ejemplo aplicado a un servicio cualquiera:

```yaml
services:
  whoami:
    image: traefik/whoami:latest
    restart: unless-stopped
    labels:
      com.centurylinklabs.watchtower.enable: "true"
```

Esta política encaja mejor con un homelab mixto porque evita que una actualización imprevista afecte a:

- Portainer
- bases de datos como MariaDB o PostgreSQL
- Redis
- servicios de autenticación o seguridad
- aplicaciones que requieran revisión de changelog o pasos de migración

Como norma práctica:

- deja con auto-actualización solo servicios simples, reversibles y fáciles de reiniciar
- mantén en actualización manual los servicios con estado crítico o migraciones delicadas

### 3. Programación de las actualizaciones

La recomendación es usar `WATCHTOWER_SCHEDULE`, no el intervalo por defecto, para que la comprobación ocurra en una ventana estable del día.

Ejemplo recomendado:

```dotenv
WATCHTOWER_SCHEDULE=0 0 5 * * *
```

Interpretación:

- segundo `0`
- minuto `0`
- hora `5`
- todos los días a las **05:00** según la zona horaria configurada en `TZ`

Elegir una ventana fija tiene ventajas claras:

- evita actualizaciones en horas de uso
- facilita correlacionar reinicios con logs y alertas
- simplifica la observación del homelab en Portainer o Dozzle

Si prefieres otro horario, modifica solo esa variable del `.env` y recrea el stack:

```bash
cd /home/<usuario>/homelab/compose/watchtower
docker compose up -d
```

### 4. Exclusiones recomendadas

La forma preferida de excluir es por **etiqueta**, porque queda documentada junto al propio servicio. Aun así, Watchtower también permite excluir por nombre si no puedes tocar el compose del contenedor.

Ejemplo de exclusión por nombre:

```dotenv
WATCHTOWER_DISABLE_CONTAINERS=watchtower-watchtower-1,portainer-portainer-1
```

Si usas esa variable, añádela en el `.env` y publícala también en `environment:` del `compose.yaml`:

```yaml
environment:
  WATCHTOWER_DISABLE_CONTAINERS: ${WATCHTOWER_DISABLE_CONTAINERS}
```

Orden de preferencia recomendado:

1. exclusión por etiqueta en el stack del servicio
2. exclusión por nombre solo como excepción

Contenedores que conviene dejar fuera de auto-actualización salvo que tengas una razón clara:

- Watchtower
- Portainer
- bases de datos
- reverse proxy
- servicios SSO o de seguridad
- cualquier contenedor con upgrades que impliquen migraciones manuales

### 5. Modo de monitorización sin aplicar cambios

Si quieres que Watchtower compruebe imágenes nuevas y notifique, pero sin recrear contenedores, puedes usar un enfoque de **monitor-only**.

Opciones prácticas:

- activar `WATCHTOWER_MONITOR_ONLY=true` para que ninguna actualización se aplique
- o usar la etiqueta `com.centurylinklabs.watchtower.monitor-only: "true"` en un servicio concreto

Este modo es útil para:

- validar la ventana de ejecución antes de automatizar
- detectar imágenes nuevas en servicios sensibles
- ensayar notificaciones sin tocar producción

### 6. Notificaciones

Watchtower puede enviar notificaciones mediante una URL compatible con **Shoutrrr**. En el ejemplo anterior se usa:

```dotenv
WATCHTOWER_NOTIFICATION_URL=logger://
WATCHTOWER_NOTIFICATION_LOG_STDOUT=true
```

Eso hace que el resumen de cada ejecución quede visible en `docker compose logs` sin depender todavía de un servicio externo.

Cuando quieras sacar esas alertas fuera del contenedor, sustituye `WATCHTOWER_NOTIFICATION_URL` por la URL del destino real. Watchtower soporta, entre otros:

- Gotify
- Discord
- Slack
- Microsoft Teams
- email SMTP

Recomendación práctica para este homelab:

- activar notificaciones externas solo cuando ya exista un destino fiable
- usar `WATCHTOWER_NOTIFICATION_REPORT=true` para recibir un resumen por ejecución
- guardar tokens o credenciales en el `.env` con permisos `600`
- si configuras varios destinos, documentarlos con claridad en el stack

Verificación útil tras desplegar:

```bash
cd /home/<usuario>/homelab/compose/watchtower
docker compose logs -f
```

### 7. Verificaciones operativas recomendadas

Comprobaciones básicas después del despliegue:

```bash
cd /home/<usuario>/homelab/compose/watchtower
docker compose ps
docker compose logs --tail=100
docker inspect watchtower-watchtower-1 --format '{{ .State.Status }}'
```

Qué conviene confirmar:

- el contenedor está en estado `running`
- no hay errores de autenticación contra registros de imágenes
- la programación cargada es la esperada
- solo aparecen como candidatos los contenedores etiquetados

Si quieres forzar una comprobación puntual sin esperar a la siguiente ventana programada, puedes lanzar una ejecución manual efímera:

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --env-file /home/<usuario>/homelab/compose/watchtower/.env \
  containrrr/watchtower:latest \
  --run-once
```

Esto es útil para validar:

- que el socket Docker está accesible
- que las etiquetas están bien aplicadas
- que las notificaciones funcionan
- que no hay contenedores inesperados dentro del alcance de Watchtower

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose de Watchtower | `/home/<usuario>/homelab/compose/watchtower/` | SSD NVMe |
| Variables del stack | `/home/<usuario>/homelab/compose/watchtower/.env` | SSD NVMe |
| Socket Docker del host | `/var/run/docker.sock` | SSD NVMe |
| Zona horaria del host | `/etc/localtime` | SSD NVMe |

Notas de almacenamiento:

- Watchtower no necesita volumen de datos propio bajo `/home/<usuario>/homelab/data`
- el estado importante está en el `compose.yaml`, el `.env` y la propia configuración Docker del host
- el socket `/var/run/docker.sock` no almacena datos persistentes, pero concede a Watchtower capacidad para inspeccionar y recrear contenedores
- no se usan `hd2t` ni `hd5t` en este servicio

## Backup
Conviene respaldar como mínimo:

- `/home/<usuario>/homelab/compose/watchtower/compose.yaml`
- `/home/<usuario>/homelab/compose/watchtower/.env`

No es necesario respaldar:

- la imagen `containrrr/watchtower`
- el contenedor recreable
- `/var/run/docker.sock`
- `/etc/localtime`

Estrategia práctica de restauración:

1. reinstalar Docker si hiciera falta
2. restaurar el directorio `/home/<usuario>/homelab/compose/watchtower/`
3. validar el stack con `docker compose config`
4. ejecutar `docker compose up -d`

## Referencias
- Watchtower Docs: Overview  
  https://containrrr.dev/watchtower/
- Watchtower Docs: Arguments  
  https://containrrr.dev/watchtower/arguments/
- Watchtower Docs: Container selection  
  https://containrrr.dev/watchtower/container-selection/
- Watchtower Docs: Notifications  
  https://containrrr.dev/watchtower/notifications/
- Docker Hub: `containrrr/watchtower`  
  https://hub.docker.com/r/containrrr/watchtower
