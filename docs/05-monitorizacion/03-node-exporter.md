# Node Exporter

## Descripción

**Node Exporter** es el exporter de Prometheus para métricas del sistema operativo. En este homelab se usa para exponer el estado real de la **Raspberry Pi 5**: CPU, memoria, carga, sistema de ficheros, red y, cuando el kernel lo publica, temperatura.

Su función en esta fase es muy concreta:

- exponer métricas del host para que las recoja [01-prometheus.md](01-prometheus.md)
- alimentar dashboards de sistema en [02-grafana.md](02-grafana.md), especialmente **Node Exporter Full**
- dar visibilidad sobre el **SSD NVMe** y los discos USB conectados al host

En este proyecto conviene mantener un criterio simple:

- Node Exporter no necesita base de datos ni almacenamiento persistente
- no hace falta publicar su puerto en la LAN
- debe ser accesible solo desde la red Docker compartida con Prometheus
- el nombre del servicio debe ser `node-exporter`, porque así está definido el target en [01-prometheus.md](01-prometheus.md)

## Requisitos Previos

- Haber completado [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber completado [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Haber completado [01-prometheus.md](01-prometheus.md).
- Haber completado [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md).
- Tener creada la red Docker externa `homelab_proxy`.
- Poder montar en modo solo lectura el sistema de ficheros del host dentro del contenedor.
- Puertos necesarios en esta fase:
  - **`9100/tcp`** interno del contenedor para Prometheus
  - no hace falta publicar `9100/tcp` en `127.0.0.1` ni en la LAN

## Docker Compose

Archivo: `/home/<user>/homelab/compose/monitoring-node-exporter/docker-compose.yml`

```yaml
name: monitoring-node-exporter

services:
  node-exporter:
    image: quay.io/prometheus/node-exporter:latest
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    read_only: true
    env_file:
      - .env
    command:
      - --path.rootfs=/host
      - --path.procfs=/host/proc
      - --path.sysfs=/host/sys
      - --collector.hwmon
      - --collector.thermal_zone
      - --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run/credentials/.+|var/lib/docker/.+|var/lib/containers/storage/.+)($|/)
      - --collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$
    expose:
      - "9100"
    volumes:
      - /:/host:ro,rslave
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
    networks:
      - default
      - proxy
    labels:
      - com.centurylinklabs.watchtower.enable=false

networks:
  proxy:
    external: true
    name: ${PROXY_NETWORK}
```

Archivo recomendado: `/home/<user>/homelab/compose/monitoring-node-exporter/.env`

```dotenv
PROXY_NETWORK=homelab_proxy
```

Puntos importantes de este Compose:

- `read_only: true` reduce superficie de escritura en un servicio que no necesita persistencia
- el contenedor monta `/`, `/proc` y `/sys` del host en solo lectura para exportar métricas reales de la Raspberry Pi
- `expose: 9100` deja el servicio accesible para Prometheus dentro de Docker sin abrirlo en la LAN
- `--collector.hwmon` y `--collector.thermal_zone` ayudan a obtener métricas de temperatura útiles en la Pi
- el stack se une a `homelab_proxy` para que Prometheus llegue a `node-exporter:9100`
- se recomienda **no** autoactualizar Node Exporter ciegamente con Watchtower

## Configuración

### 1. Preparar directorios del stack

```bash
mkdir -p /home/<user>/homelab/compose/monitoring-node-exporter
```

Node Exporter es esencialmente **stateless** en este despliegue:

- no necesita directorio en `/home/<user>/homelab/data/`
- no necesita configuración persistente en `/home/<user>/homelab/config/`
- el único fichero auxiliar recomendado es el `.env` del stack

Si la red externa compartida aún no existe, créala:

```bash
docker network inspect homelab_proxy >/dev/null 2>&1 || docker network create homelab_proxy
```

### 2. Guardar el `.env` y desplegar el stack

Guarda el `.env` del apartado Compose y despliega:

```bash
cd /home/<user>/homelab/compose/monitoring-node-exporter
docker compose config
docker compose up -d
docker compose ps
```

Validaciones mínimas tras el arranque:

```bash
docker compose logs --tail=100 node-exporter
```

El resultado esperado es este:

- el contenedor queda en estado `Up`
- no aparecen errores de lectura sobre `/host`, `/host/proc` o `/host/sys`
- el servicio escucha en `9100/tcp` dentro de la red Docker compartida

### 3. Verificar que Prometheus puede scrapear el exporter

Como este servicio no publica puerto al host, la validación práctica debe hacerse a través de Prometheus.

Si ya tienes desplegado [01-prometheus.md](01-prometheus.md), una comprobación útil es esta:

```bash
curl -s http://127.0.0.1:11000/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="node-exporter") | {scrapeUrl: .scrapeUrl, health: .health, lastError: .lastError}'
```

Si `health` aparece como `up`, la conectividad entre Prometheus y Node Exporter es correcta.

Después revisa la UI de Prometheus:

- `http://127.0.0.1:11000`
- `Status` → `Targets`

Estado esperado:

- el target `node-exporter` aparece en estado `UP`

Si aparece `DOWN`, las causas más habituales son estas:

- el servicio no se llama `node-exporter`
- Prometheus y Node Exporter no comparten la red `homelab_proxy`
- el contenedor no arrancó bien por una ruta montada incorrecta

### 4. Consultas rápidas recomendadas

Una vez el target esté `UP`, estas consultas son útiles en Prometheus o Grafana:

```promql
node_uname_info
```

```promql
node_load1
```

```promql
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

```promql
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100
```

Para temperatura, prueba primero cuál de estas métricas existe realmente en tu host:

```promql
node_thermal_zone_temp
```

```promql
node_hwmon_temp_celsius
```

Lectura práctica:

- `node_uname_info` confirma que el exporter está devolviendo metadatos del host
- `node_load1` da una señal rápida de carga del sistema
- la consulta de CPU devuelve porcentaje de uso agregado
- la consulta de memoria devuelve porcentaje de memoria usada
- para temperatura, en muchas instalaciones de Raspberry Pi la métrica útil será `node_thermal_zone_temp` y habrá que dividir entre `1000`

### 5. Relación con Grafana

En [02-grafana.md](02-grafana.md), este servicio se usa para alimentar dos vistas especialmente útiles:

- el dashboard **Node Exporter Full**
- paneles de temperatura de la Raspberry Pi

Si el dashboard de sistema no muestra datos, revisa siempre en este orden:

1. que `node-exporter` esté `UP` en Prometheus
2. que la variable `job` del dashboard tenga el valor `node-exporter`
3. que existan realmente las métricas esperadas en `Explore`

### 6. Operación diaria

Comandos útiles para operación diaria:

```bash
cd /home/<user>/homelab/compose/monitoring-node-exporter
docker compose logs -f node-exporter
docker compose restart node-exporter
docker compose ps
```

## Almacenamiento

Rutas relevantes de este despliegue:

- `docker-compose.yml`: `/home/<user>/homelab/compose/monitoring-node-exporter/docker-compose.yml`
- `.env`: `/home/<user>/homelab/compose/monitoring-node-exporter/.env`

Notas importantes:

- Node Exporter no mantiene base de datos ni volúmenes persistentes en este homelab
- no hace falta crear `/home/<user>/homelab/data/node-exporter/`
- no hace falta crear `/home/<user>/homelab/config/node-exporter/` salvo que en el futuro quieras encapsular opciones adicionales fuera del Compose
- las métricas se generan en tiempo real y quedan almacenadas realmente en [01-prometheus.md](01-prometheus.md), no aquí

## Backup

Lo que conviene respaldar en este servicio es esto:

- `/home/<user>/homelab/compose/monitoring-node-exporter/docker-compose.yml`
- `/home/<user>/homelab/compose/monitoring-node-exporter/.env`

Matiz importante:

- no hay datos históricos propios que copiar desde Node Exporter
- si se pierde el contenedor, basta con volver a desplegarlo
- el histórico de métricas que realmente importa se respalda desde Prometheus, no desde este servicio

## Referencias

- Prometheus Docs: [Node Exporter guide](https://prometheus.io/docs/guides/node-exporter/)
- GitHub: [prometheus/node_exporter](https://github.com/prometheus/node_exporter)
- Quay.io: [prometheus/node-exporter](https://quay.io/repository/prometheus/node-exporter)
