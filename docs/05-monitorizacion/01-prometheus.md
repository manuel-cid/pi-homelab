# Prometheus

## Descripción

**Prometheus** es la base de la monitorización del homelab: recopila métricas en formato de series temporales, las guarda localmente en el **SSD NVMe** y las expone para consulta desde su propia UI o desde [02-grafana.md](02-grafana.md).

En esta Raspberry Pi 5 conviene fijar un criterio simple:

- Prometheus guarda su base de datos TSDB en el **SSD NVMe**, nunca en `hd2t` ni en `hd5t`
- la UI no debe exponerse directamente a toda la LAN por defecto
- los targets iniciales del proyecto son:
  - el propio Prometheus
  - [03-node-exporter.md](03-node-exporter.md) para métricas del sistema
  - el endpoint nativo de métricas de Docker Engine `/metrics`, opcional pero recomendado

## Requisitos Previos

- Haber completado [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber completado [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Haber completado [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md).
- Tener creada la red Docker externa `homelab_proxy`, ya que este stack la usa para que Grafana pueda consultar Prometheus por nombre interno.
- Poder crear directorios persistentes en `/home/<user>/homelab/config/` y `/home/<user>/homelab/data/`.
- Si se quiere scrapear el endpoint nativo de Docker, tener acceso administrativo al host para editar `/etc/docker/daemon.json` y reiniciar `docker`.
- Puertos necesarios en esta fase:
  - **`11000/tcp`** publicado solo en `127.0.0.1` para la UI de Prometheus
  - **`9090/tcp`** interno del contenedor
  - **`9100/tcp`** interno para el target de Node Exporter cuando ese servicio exista
  - **`9323/tcp`** en la IP del bridge Docker del host si se habilitan métricas nativas de Docker Engine

Cuando este documento use placeholders como `<user>`, debes sustituirlos por el usuario real del sistema antes de ejecutar comandos o guardar rutas.

## Objetivo de esta Fase

Al terminar este documento, el estado esperado es este:

- Prometheus queda desplegado como stack propio `monitoring-prometheus`.
- La configuración vive fuera del contenedor en `/home/<user>/homelab/config/prometheus/`.
- La TSDB de Prometheus vive en `/home/<user>/homelab/data/prometheus/` sobre el **SSD NVMe**.
- La retención queda limitada por tiempo y por tamaño para evitar crecimiento sin control.
- Queda definido un `prometheus.yml` base listo para scrapear Prometheus y preparado para añadir Node Exporter y, opcionalmente, el endpoint nativo de Docker Engine.

## Docker Compose

Archivo: `/home/<user>/homelab/compose/monitoring-prometheus/docker-compose.yml`

```yaml
name: monitoring-prometheus

services:
  prometheus:
    image: prom/prometheus:v3.12.0
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=${PROMETHEUS_RETENTION_TIME}
      - --storage.tsdb.retention.size=${PROMETHEUS_RETENTION_SIZE}
      - --web.enable-lifecycle
    ports:
      - "${PROMETHEUS_BIND_IP}:${PROMETHEUS_PORT}:9090"
    volumes:
      - ${CONFIG_ROOT}/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ${DATA_ROOT}/prometheus:/prometheus
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - default
      - proxy
    labels:
      - wud.watch=false

networks:
  proxy:
    external: true
    name: ${PROXY_NETWORK}
```

Archivo recomendado: `/home/<user>/homelab/compose/monitoring-prometheus/.env`

```dotenv
TZ=Europe/Madrid
CONFIG_ROOT=/home/<user>/homelab/config
DATA_ROOT=/home/<user>/homelab/data
PROMETHEUS_BIND_IP=127.0.0.1
PROMETHEUS_PORT=11000
PROMETHEUS_RETENTION_TIME=15d
PROMETHEUS_RETENTION_SIZE=15GB
PROXY_NETWORK=homelab_proxy
```

Puntos importantes de este Compose:

- Prometheus se publica solo en `127.0.0.1:11000`, no en toda la LAN
- el stack se une a `homelab_proxy` para que [02-grafana.md](02-grafana.md) pueda alcanzarlo por nombre interno `prometheus:9090`
- `extra_hosts` deja resuelto `host.docker.internal` hacia el gateway del host, útil para scrapear métricas del daemon Docker
- la retención queda acotada a **15 días** o **15 GB**, lo que ocurra antes
- la imagen queda fijada a una versión concreta para evitar cambios inesperados al recrear el contenedor
- se recomienda **no** configurar triggers de actualización automática de WUD para Prometheus

## Configuración

### 1. Preparar directorios del stack

```bash
mkdir -p /home/<user>/homelab/compose/monitoring-prometheus
mkdir -p /home/<user>/homelab/config/prometheus
mkdir -p /home/<user>/homelab/data/prometheus
```

El contenedor oficial de Prometheus escribe la TSDB con un usuario no privilegiado. Ajusta permisos del directorio de datos antes del primer arranque:

```bash
sudo chown -R 65534:65534 /home/<user>/homelab/data/prometheus
sudo chmod 755 /home/<user>/homelab/data/prometheus
```

Si ya existe la red externa compartida del homelab, déjala tal cual. Si todavía no existe:

```bash
docker network inspect homelab_proxy >/dev/null 2>&1 || docker network create homelab_proxy
```

### 2. Crear `prometheus.yml`

Archivo: `/home/<user>/homelab/config/prometheus/prometheus.yml`

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - prometheus:9090

  # Descomenta este bloque cuando despliegues Node Exporter:
  # - job_name: node-exporter
  #   static_configs:
  #     - targets:
  #         - node-exporter:9100

  # Descomenta este bloque cuando habilites el endpoint nativo
  # de métricas de Docker Engine en el host:
  # - job_name: docker
  #   static_configs:
  #     - targets:
  #         - host.docker.internal:9323
```

Lectura práctica de estos targets:

- `prometheus:9090` valida que el propio servidor está sano
- `node-exporter:9100` debe añadirse cuando se despliegue [03-node-exporter.md](03-node-exporter.md)
- `host.docker.internal:9323` debe añadirse cuando habilites el endpoint nativo de Docker Engine

Con este enfoque, el primer arranque de Prometheus queda limpio: solo aparece `UP` el propio servicio y no introduces `DOWN` permanentes por targets todavía no desplegados.

### 3. Habilitar opcionalmente las métricas nativas de Docker Engine

Si quieres que Prometheus recoja métricas del daemon Docker sin usar exporters adicionales, habilita el endpoint `/metrics` del propio motor.

Primero obtén la IP gateway de la red bridge del host:

```bash
docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}'
```

En la mayoría de hosts Docker devolverá algo como `172.17.0.1`. Usa ese valor en `/etc/docker/daemon.json`.

Archivo: `/etc/docker/daemon.json`

```json
{
  "metrics-addr": "172.17.0.1:9323",
  "experimental": true
}
```

Notas importantes:

- no uses `0.0.0.0:9323`, porque expondrías métricas del daemon más allá de lo necesario
- no uses `127.0.0.1:9323` si el objetivo es que Prometheus lo scrapee desde el contenedor
- si `/etc/docker/daemon.json` ya existe, integra estas claves sin borrar el resto de tu configuración

Aplica el cambio:

```bash
sudo systemctl restart docker
sudo systemctl status docker --no-pager
curl http://172.17.0.1:9323/metrics | head
```

Si tu gateway bridge no es `172.17.0.1`, sustituye esa IP en la prueba y mantén el mismo criterio.

Después añade el bloque `job_name: docker` del apartado anterior a `prometheus.yml` y recarga la configuración.

### 4. Guardar el `.env` y desplegar el stack

Guarda el `.env` del apartado Compose y despliega:

```bash
cd /home/<user>/homelab/compose/monitoring-prometheus
docker compose config
docker compose up -d
docker compose ps
```

Validaciones mínimas tras el arranque:

```bash
docker compose logs --tail=100 prometheus
curl http://127.0.0.1:11000/-/ready
curl http://127.0.0.1:11000/-/healthy
```

El resultado esperado es este:

- el contenedor queda en estado `Up`
- `/-/ready` responde `Prometheus Server is Ready.`
- `/-/healthy` responde `Prometheus Server is Healthy.`

### 5. Revisar targets en la UI

Abre la UI desde el host o mediante un túnel SSH local:

- `http://127.0.0.1:11000`

Dentro de la interfaz, revisa `Status` → `Targets`.

Estado esperado justo después de desplegar solo Prometheus:

- `prometheus` en estado `UP`
- no deberían aparecer todavía `node-exporter` ni `docker` si no has activado esos bloques en `prometheus.yml`

Cuando completes [03-node-exporter.md](03-node-exporter.md), añade su bloque al fichero y recarga Prometheus. Si además habilitas las métricas nativas de Docker Engine, añade también el bloque `docker`.

### 6. Política recomendada de retención en el SSD NVMe

Para este homelab, la política base recomendada es:

- `PROMETHEUS_RETENTION_TIME=15d`
- `PROMETHEUS_RETENTION_SIZE=15GB`

Motivo de esta decisión:

- en una Raspberry Pi 5 interesa limitar escrituras y crecimiento de la TSDB
- el SSD NVMe tiene margen de sobra, pero no conviene dejar series temporales sin límite
- con Node Exporter, métricas propias de Prometheus y métricas de Docker, **15 días** suele ser un equilibrio razonable entre utilidad histórica y consumo de disco

Si más adelante añades muchos exporters o dashboards con más granularidad, revisa el consumo real:

```bash
du -sh /home/<user>/homelab/data/prometheus
```

No muevas la TSDB a `hd2t` ni `hd5t`: Prometheus hace escrituras frecuentes y necesita baja latencia. El **SSD NVMe** es el lugar correcto.

### 7. Consulta rápida desde línea de comandos

Comandos útiles para operación diaria:

```bash
cd /home/<user>/homelab/compose/monitoring-prometheus
docker compose logs -f prometheus
docker compose restart prometheus
curl -s http://127.0.0.1:11000/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'
```

El último comando ayuda a verificar rápido qué targets están `up` o `down` sin abrir la UI. Si no tienes `jq` instalado, puedes revisar la salida JSON en bruto con:

```bash
curl -s http://127.0.0.1:11000/api/v1/targets
```

## Almacenamiento

Rutas relevantes de este despliegue:

- `docker-compose.yml`: `/home/<user>/homelab/compose/monitoring-prometheus/docker-compose.yml`
- `.env`: `/home/<user>/homelab/compose/monitoring-prometheus/.env`
- configuración principal: `/home/<user>/homelab/config/prometheus/prometheus.yml`
- datos persistentes TSDB: `/home/<user>/homelab/data/prometheus/`

Notas importantes:

- la TSDB de Prometheus debe permanecer en el **SSD NVMe**
- `hd2t` y `hd5t` no son ubicaciones adecuadas para la base de datos de métricas
- si usas reglas o ficheros adicionales en el futuro, guárdalos también bajo `/home/<user>/homelab/config/prometheus/`
- el directorio de datos puede crecer de forma apreciable si amplías exporters o retención; vigílalo periódicamente

## Backup

Lo que conviene respaldar en este servicio es esto:

- `/home/<user>/homelab/compose/monitoring-prometheus/docker-compose.yml`
- `/home/<user>/homelab/compose/monitoring-prometheus/.env`
- `/home/<user>/homelab/config/prometheus/prometheus.yml`
- `/home/<user>/homelab/data/prometheus/`

Matiz importante:

- el fichero de configuración y el Compose son imprescindibles
- la TSDB puede reconstruirse con el tiempo, así que su backup no es tan crítico como el de una base de datos de negocio
- aun así, si quieres conservar histórico de métricas tras una recuperación, respalda también `/home/<user>/homelab/data/prometheus/`

## Referencias

- Prometheus Docs: [Getting started](https://prometheus.io/docs/prometheus/latest/getting_started/)
- Prometheus Docs: [Configuration](https://prometheus.io/docs/prometheus/latest/configuration/configuration/)
- Prometheus Docs: [Storage](https://prometheus.io/docs/prometheus/latest/storage/)
- Docker Docs: [Collect Docker metrics with Prometheus](https://docs.docker.com/engine/daemon/prometheus/)
- Docker Hub: [prom/prometheus](https://hub.docker.com/r/prom/prometheus)
