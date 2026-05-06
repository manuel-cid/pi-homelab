# Node Exporter

## Descripción
**Node Exporter** será el servicio encargado de exponer métricas del sistema operativo de la **Raspberry Pi 5** para que **Prometheus** pueda recopilarlas y **Grafana** pueda visualizarlas.

En este homelab su papel es cubrir, como mínimo:

- uso de CPU, carga y tiempo de actividad
- memoria y swap
- uso de disco en el **SSD NVMe**, `hd2t` y `hd5t`
- red y tráfico por interfaces
- sensores del sistema, incluyendo temperatura si el kernel la expone mediante `hwmon` o `thermal_zone`

Aunque Node Exporter se despliega en Docker, debe observar el **host real**, no el contenedor. Por eso en esta guía se monta `proc`, `sys` y la raíz del host en modo lectura, y se mantiene el servicio unido a `homelab_shared` para que Prometheus lo alcance como `node-exporter:9100`.

Node Exporter es esencialmente **stateless**: no necesita base de datos ni volumen persistente propio. La única parte que debe versionarse y respaldarse es su stack Compose.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/05-monitorizacion/01-prometheus.md`.
- Tener creada la red Docker externa `homelab_shared`.
- Tener claro que este homelab solo se expone en **LAN + Tailscale**, sin publicación a internet.
- Tener prevista la ruta de stacks en el SSD NVMe:
  - `/home/<usuario>/homelab/compose`
- Puertos implicados:
  - `9100/tcp` expuesto por Node Exporter
  - `127.0.0.1:9100/tcp` publicado opcionalmente en el host para pruebas locales con `curl`
  - `9100/tcp` accesible dentro de `homelab_shared` para que Prometheus raspe `node-exporter:9100`

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/node-exporter/
├── compose.yaml
└── .env
```

Fichero `.env` recomendado:

```dotenv
TZ=Europe/Madrid
NODE_EXPORTER_PORT=9100
```

Notas sobre estas variables:

- `NODE_EXPORTER_PORT=9100` publica el endpoint HTTP solo en loopback del host para pruebas locales.
- Prometheus no necesita usar ese puerto publicado en el host; lo normal es que raspe `http://node-exporter:9100` dentro de `homelab_shared`.

Fichero `compose.yaml`:

```yaml
name: node-exporter

services:
  node-exporter:
    image: quay.io/prometheus/node-exporter:latest
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    command:
      - --path.procfs=/host/proc
      - --path.sysfs=/host/sys
      - --path.rootfs=/host
      - --collector.filesystem.mount-points-exclude=^/(dev|proc|run|sys|var/lib/docker/.+|var/lib/containerd/.+)($|/)
    ports:
      - "127.0.0.1:${NODE_EXPORTER_PORT}:9100"
    pid: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/host:ro,rslave
    networks:
      - shared
    security_opt:
      - no-new-privileges:true

networks:
  shared:
    external: true
    name: homelab_shared
```

Despliegue inicial:

```bash
mkdir -p /home/<usuario>/homelab/compose/node-exporter

sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/node-exporter

cd /home/<usuario>/homelab/compose/node-exporter
docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

Resultado esperado:

- el contenedor `node-exporter-node-exporter-1` queda levantado
- el endpoint local responde en `http://127.0.0.1:9100/metrics`
- Prometheus puede raspar el servicio usando `http://node-exporter:9100`
- el job `node-exporter` pasa a estado `UP` en la UI de Prometheus

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| Endpoint local de prueba | `http://127.0.0.1:9100/metrics` |
| Endpoint interno para Prometheus | `http://node-exporter:9100/metrics` |
| Stack Compose | `/home/<usuario>/homelab/compose/node-exporter/` |
| Persistencia de aplicación | No aplica |
| Red entre stacks | `homelab_shared` |
| Job esperado en Prometheus | `node-exporter` |

### 1. Preparar el directorio del stack

Crear la ruta del stack:

```bash
mkdir -p /home/<usuario>/homelab/compose/node-exporter
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/node-exporter
chmod 755 /home/<usuario>/homelab/compose/node-exporter
```

Node Exporter no necesita una carpeta de datos en `/home/<usuario>/homelab/data` porque no guarda estado entre reinicios.

### 2. Entender por qué necesita acceso al host

La imagen oficial de Node Exporter está pensada para monitorizar el **host**, no el contenedor. Si lo arrancas sin mounts ni flags extra, expondrá métricas incompletas o centradas en el namespace del propio contenedor.

Por eso este stack monta:

- `/proc` del host en `/host/proc`
- `/sys` del host en `/host/sys`
- `/` del host en `/host`

Y usa estos flags:

- `--path.procfs=/host/proc`
- `--path.sysfs=/host/sys`
- `--path.rootfs=/host`

El uso de `pid: host` ayuda a que Node Exporter observe correctamente el sistema anfitrión. El bind mount de `/:/host:ro,rslave` también permite que vea puntos de montaje reales del host, incluidos los discos externos USB y el SSD NVMe.

### 3. Entender el filtro de sistemas de ficheros

El parámetro:

```text
--collector.filesystem.mount-points-exclude=^/(dev|proc|run|sys|var/lib/docker/.+|var/lib/containerd/.+)($|/)
```

evita ruido en dashboards y consultas al excluir pseudo-filesystems y mounts internos de Docker o containerd.

En un homelab con Prometheus y Grafana esto suele mejorar la legibilidad de métricas como:

- `node_filesystem_avail_bytes`
- `node_filesystem_size_bytes`
- `node_filesystem_files_free`

Si más adelante ves que falta algún mount legítimo en dashboards, revisa el regex antes de tocar Prometheus o Grafana.

### 4. Desplegar Node Exporter

Una vez guardados `compose.yaml` y `.env`:

```bash
cd /home/<usuario>/homelab/compose/node-exporter
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f
ss -tulpn | grep 9100
curl http://127.0.0.1:9100/metrics | head
```

Resultados esperados:

- `ss` muestra el puerto `9100` escuchando solo en `127.0.0.1`
- `curl` devuelve métricas en formato Prometheus
- aparecen series `node_*` y `node_exporter_*`

### 5. Verificar la integración con Prometheus

En la UI de Prometheus revisa:

```text
http://<IP-del-host>:9090/targets
```

El target esperado es:

```text
node-exporter:9100
```

Y su estado debería pasar a `UP`.

Consultas rápidas en Prometheus:

```promql
up{job="node-exporter"}
```

```promql
node_load1{job="node-exporter"}
```

```promql
node_memory_MemAvailable_bytes{job="node-exporter"}
```

```promql
node_filesystem_avail_bytes{job="node-exporter"}
```

Interpretación rápida:

- `up{job="node-exporter"}` debe devolver `1`
- las demás consultas deben devolver series del host real
- si no aparece nada, revisa nombre del servicio, red `homelab_shared` y el target definido en `prometheus.yml`

### 6. Verificar discos y montaje USB

Node Exporter debería reflejar el estado de:

- el sistema en el **SSD NVMe**
- `hd2t`
- `hd5t`

Una forma rápida de comprobarlo es consultar en Prometheus:

```promql
node_filesystem_size_bytes{job="node-exporter"}
```

Después puedes filtrar por mountpoint según tu estructura real, por ejemplo:

```promql
node_filesystem_avail_bytes{job="node-exporter", mountpoint="/"}
```

```promql
node_filesystem_avail_bytes{job="node-exporter", mountpoint="/mnt/hd2t"}
```

```promql
node_filesystem_avail_bytes{job="node-exporter", mountpoint="/mnt/hd5t"}
```

Si alguno de esos puntos de montaje no aparece:

- verifica que el disco esté montado realmente en el host
- confirma que el bind mount `/:/host:ro,rslave` sigue presente
- revisa que el regex de exclusión no esté descartando una ruta válida

### 7. Verificar temperatura y sensores en la Raspberry Pi 5

Cuando más adelante construyas dashboards en `docs/05-monitorizacion/02-grafana.md`, interesa especialmente disponer de temperatura del host. En Raspberry Pi 5 esto suele aparecer a través de una de estas familias de métricas:

```promql
node_thermal_zone_temp{job="node-exporter"}
```

```promql
node_hwmon_temp_celsius{job="node-exporter"}
```

Pruebas útiles:

```bash
curl -s http://127.0.0.1:9100/metrics | grep node_thermal
curl -s http://127.0.0.1:9100/metrics | grep node_hwmon
```

Si no aparece ninguna de esas familias:

- revisa si el kernel del host expone sensores en `/sys/class/thermal` o `/sys/class/hwmon`
- comprueba si el contenedor puede leer correctamente `/host/sys`
- valida después desde Prometheus antes de asumir que el problema es Grafana
- si aparecen métricas `hwmon`, usa esas series reales en Grafana en vez de forzar `node_thermal_zone_temp`

### 8. Endurecimiento mínimo recomendado

Node Exporter no incorpora autenticación propia y no debería exponerse innecesariamente.

En esta guía se sigue una política conservadora:

- no se publica `9100` en todas las interfaces del host
- el endpoint público para scraping real queda dentro de `homelab_shared`
- el puerto del host queda limitado a `127.0.0.1` solo para pruebas locales
- no se añaden collectors extra de alto coste en esta fase

No actives collectors deshabilitados por defecto salvo que tengas una necesidad concreta y midas primero el impacto en `scrape_duration_seconds`.

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose de Node Exporter | `/home/<usuario>/homelab/compose/node-exporter/` | SSD NVMe |
| Variables del stack | `/home/<usuario>/homelab/compose/node-exporter/.env` | SSD NVMe |
| Datos persistentes de aplicación | No aplica | No aplica |
| Mounts de solo lectura del host | `/proc`, `/sys`, `/` | Host |
| Backups del stack | `/mnt/hd2t/backups/...` | `hd2t` |

Notas de almacenamiento:

- Node Exporter no mantiene base de datos, uploads ni configuración mutable propia
- no hace falta crear `/home/<usuario>/homelab/data/node-exporter`
- el servicio solo lee información del host mediante bind mounts en modo lectura
- `hd5t` no interviene en este stack

## Backup
Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/node-exporter/compose.yaml`
- `/home/<usuario>/homelab/compose/node-exporter/.env`

No es necesario respaldar:

- la imagen `quay.io/prometheus/node-exporter`
- el contenedor recreable
- ningún volumen persistente, porque Node Exporter no guarda estado
- la red `homelab_shared`

Si pierdes este stack, bastará con restaurar `compose.yaml` y `.env`, ejecutar `docker compose up -d` y verificar que Prometheus vuelva a ver `node-exporter:9100`.

## Referencias
- Documentación oficial de Node Exporter: <https://github.com/prometheus/node_exporter>
- Guía oficial de Prometheus para Node Exporter: <https://prometheus.io/docs/guides/node-exporter/>
- Colectores y flags de Node Exporter: <https://github.com/prometheus/node_exporter/blob/master/README.md>
- Imagen Docker oficial: <https://quay.io/repository/prometheus/node-exporter>
- Repositorio oficial: <https://github.com/prometheus/node_exporter>
