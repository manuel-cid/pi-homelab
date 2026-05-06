# Prometheus

## Descripción
**Prometheus** será la base de métricas del homelab. Su función es recopilar, almacenar y consultar series temporales de la **Raspberry Pi 5**, del host Linux y de los contenedores que expongan métricas.

En esta fase Prometheus se despliega como un stack propio y se prepara para raspar, como mínimo:

- el propio Prometheus
- **Node Exporter** para métricas del sistema
- **cAdvisor** para métricas de contenedores Docker

La estrategia de este proyecto es mantener tanto la configuración como la base de datos TSDB de Prometheus en el **SSD NVMe**, no en `hd2t` ni en `hd5t`. La razón es operativa: la monitorización debe seguir siendo rápida, estable y poco dependiente de discos USB externos.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Tener creada la red Docker externa `homelab_shared`.
- Tener claro que este homelab solo se expone en **LAN + Tailscale**, sin publicación a internet.
- Tener previstas las rutas persistentes en el SSD NVMe:
  - `/home/<usuario>/homelab/compose`
  - `/home/<usuario>/homelab/data`
- Puertos implicados:
  - `9090/tcp` publicado en el host para la UI y API HTTP de Prometheus
  - `9100/tcp` esperado para **Node Exporter** en la red Docker compartida
  - `8080/tcp` esperado para **cAdvisor** en la red Docker compartida

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/prometheus/
├── compose.yaml
├── .env
└── prometheus.yml
```

Fichero `.env` recomendado:

```dotenv
TZ=Europe/Madrid
PROMETHEUS_PORT=9090
PROMETHEUS_RETENTION_TIME=30d
PROMETHEUS_RETENTION_SIZE=10GB
```

Notas sobre estas variables:

- `PROMETHEUS_PORT=9090` publica la UI local de Prometheus.
- `PROMETHEUS_RETENTION_TIME=30d` mantiene un histórico razonable para un homelab pequeño.
- `PROMETHEUS_RETENTION_SIZE=10GB` pone un límite adicional de espacio en el SSD NVMe.
- Prometheus aplicará el límite que se alcance antes: tiempo o tamaño.
- La TSDB seguirá almacenándose en el NVMe mediante el bind mount de `/prometheus`.

Fichero `prometheus.yml`:

```yaml
global:
  scrape_interval: 30s
  scrape_timeout: 10s
  evaluation_interval: 30s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - prometheus:9090

  - job_name: node-exporter
    static_configs:
      - targets:
          - node-exporter:9100

  - job_name: cadvisor
    static_configs:
      - targets:
          - cadvisor:8080
```

Fichero `compose.yaml`:

```yaml
name: prometheus

services:
  prometheus:
    image: prom/prometheus:latest
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=${PROMETHEUS_RETENTION_TIME}
      - --storage.tsdb.retention.size=${PROMETHEUS_RETENTION_SIZE}
      - --storage.tsdb.wal-compression
      - --web.enable-lifecycle
    ports:
      - "${PROMETHEUS_PORT}:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - /home/<usuario>/homelab/data/prometheus/data:/prometheus
    networks:
      - default
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
mkdir -p /home/<usuario>/homelab/compose/prometheus
mkdir -p /home/<usuario>/homelab/data/prometheus/data

sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/prometheus
sudo chown -R 65534:65534 /home/<usuario>/homelab/data/prometheus/data

cd /home/<usuario>/homelab/compose/prometheus
docker run --rm \
  -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  prom/prometheus:latest \
  promtool check config /etc/prometheus/prometheus.yml

docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

Resultado esperado:

- el contenedor `prometheus-prometheus-1` queda levantado
- la UI queda accesible en `http://<IP-del-host>:9090`
- Prometheus responde en la red compartida como `http://prometheus:9090`
- los jobs `prometheus`, `node-exporter` y `cadvisor` aparecen en la página de targets cuando esos exporters ya existan

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `http://<IP-del-host>:9090` |
| Persistencia TSDB | `/home/<usuario>/homelab/data/prometheus/data/` |
| Fichero de configuración | `/home/<usuario>/homelab/compose/prometheus/prometheus.yml` |
| Retención temporal | `30d` |
| Límite de tamaño | `10GB` |
| Red entre stacks | `homelab_shared` |
| Targets iniciales | `prometheus`, `node-exporter`, `cadvisor` |

### 1. Preparar directorios y permisos

Crear las rutas del stack y de la base de datos:

```bash
mkdir -p /home/<usuario>/homelab/compose/prometheus
mkdir -p /home/<usuario>/homelab/data/prometheus/data
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/prometheus
sudo chown -R 65534:65534 /home/<usuario>/homelab/data/prometheus/data
chmod 755 /home/<usuario>/homelab/data/prometheus
chmod 700 /home/<usuario>/homelab/data/prometheus/data
```

El contenedor oficial de Prometheus escribe su TSDB dentro de `/prometheus`, así que el directorio montado en el host debe ser escribible por el usuario efectivo del contenedor. En este documento se usa `65534:65534`, que es la opción más predecible para el bind mount de datos.

### 2. Entender qué guarda Prometheus en el NVMe

El directorio `/home/<usuario>/homelab/data/prometheus/data/` contendrá:

- bloques TSDB compactados
- WAL de Prometheus
- metadatos internos del motor de series temporales

En este despliegue se activa además la compresión del WAL con `--storage.tsdb.wal-compression`, una opción sensata para reducir escritura y consumo de espacio en un host pequeño como la Raspberry Pi 5.

No conviene llevar esta ruta a `hd2t` o `hd5t` porque:

- la latencia de consulta empeora
- la base de métricas depende de un disco USB externo
- se mezclan datos operativos del homelab con almacenamiento multimedia

En este proyecto la regla sigue siendo la misma que en fases anteriores: **configuración y datos persistentes de servicios en NVMe; bibliotecas grandes y backups en HDD**.

### 3. Ajustar el fichero `prometheus.yml`

El ejemplo de esta guía define tres jobs básicos:

- `prometheus`: autoconsumo para comprobar que el propio servidor responde
- `node-exporter`: métricas del host Linux y de la Raspberry Pi
- `cadvisor`: métricas de contenedores Docker

Si más adelante cambias el nombre del servicio en otro stack, actualiza también el target correspondiente. Por ejemplo:

- si el servicio de Node Exporter se llama `monitor-node-exporter`, el target ya no será `node-exporter:9100`
- si cAdvisor escucha en otro puerto, debes reflejarlo aquí

Validar el fichero antes de recrear el stack:

```bash
cd /home/<usuario>/homelab/compose/prometheus
docker run --rm \
  -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  prom/prometheus:latest \
  promtool check config /etc/prometheus/prometheus.yml
```

Resultado esperado:

- `SUCCESS` si la sintaxis del fichero es válida

### 4. Desplegar Prometheus

Una vez guardados `compose.yaml`, `.env` y `prometheus.yml`:

```bash
cd /home/<usuario>/homelab/compose/prometheus
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f
ss -tulpn | grep 9090
```

Abrir en navegador:

```text
http://<IP-del-host>:9090
```

Páginas útiles tras el arranque:

- `/targets` para comprobar el estado de los scrape jobs
- `/graph` para probar consultas PromQL simples
- `/status` para revisar runtime, flags y configuración cargada

### 5. Verificar targets y estado de scrape

En la pantalla **Status > Target health** o directamente en:

```text
http://<IP-del-host>:9090/targets
```

deberías ver:

- `prometheus` en estado `UP`
- `node-exporter` en `DOWN` hasta que se despliegue su stack
- `cadvisor` en `DOWN` hasta que se despliegue su stack

Ese comportamiento inicial es normal si todavía no has creado los documentos:

- `docs/05-monitorizacion/03-node-exporter.md`
- `docs/05-monitorizacion/04-cadvisor.md`

Cuando ambos servicios existan y estén conectados a `homelab_shared`, Prometheus empezará a rasparlos sin necesidad de cambiar la topología general.

### 6. Política de retención recomendada para este homelab

En una Raspberry Pi 5 con un SSD NVMe de 500 GB compartido por todos los servicios, lo prudente es limitar Prometheus desde el principio.

Configuración recomendada en esta fase:

- `30d` de histórico
- `10GB` como tope de almacenamiento

Este enfoque evita que Prometheus crezca sin control si:

- añades más exporters
- aumentas la frecuencia de scrape
- habilitas dashboards más detallados en Grafana

Si en el futuro necesitas más histórico, amplía primero de forma conservadora, por ejemplo:

```dotenv
PROMETHEUS_RETENTION_TIME=60d
PROMETHEUS_RETENTION_SIZE=20GB
```

Después recrea el stack:

```bash
cd /home/<usuario>/homelab/compose/prometheus
docker compose up -d
```

### 7. Recargar la configuración

El `compose.yaml` activa `--web.enable-lifecycle`, lo que permite recargar `prometheus.yml` sin destruir el contenedor.

Opción simple y segura:

```bash
cd /home/<usuario>/homelab/compose/prometheus
docker compose restart prometheus
```

Opción de recarga HTTP desde el host:

```bash
curl -X POST http://127.0.0.1:9090/-/reload
```

Usa la recarga HTTP solo en el propio host o desde una red de confianza, porque Prometheus no incorpora autenticación nativa.

### 8. Preparar la integración con Grafana

Cuando despliegues `docs/05-monitorizacion/02-grafana.md`, el datasource recomendado será:

```text
http://prometheus:9090
```

La condición para que esto funcione es sencilla:

- Grafana y Prometheus deben compartir la red `homelab_shared`
- el servicio debe seguir llamándose `prometheus` dentro del stack

Esto permite que Grafana consulte Prometheus por nombre interno de Docker, sin depender del puerto publicado en el host.

### 9. Endurecimiento mínimo recomendado

Prometheus no incorpora autenticación ni control de acceso fino por sí solo. En este homelab la medida principal es mantenerlo accesible solo por **LAN + Tailscale**.

Recomendaciones mínimas:

- no publiques `9090` fuera de tu red local o de Tailscale
- no uses `/-/reload` desde redes no confiables
- valida `prometheus.yml` con `promtool` antes de cada cambio
- vigila el crecimiento de la TSDB para no erosionar el espacio del NVMe
- evita añadir exporters o labels de alta cardinalidad sin una necesidad real

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose de Prometheus | `/home/<usuario>/homelab/compose/prometheus/` | SSD NVMe |
| Variables del stack | `/home/<usuario>/homelab/compose/prometheus/.env` | SSD NVMe |
| Configuración de scrape | `/home/<usuario>/homelab/compose/prometheus/prometheus.yml` | SSD NVMe |
| Base de datos TSDB | `/home/<usuario>/homelab/data/prometheus/data/` | SSD NVMe |
| Backups pesados del histórico | `/mnt/hd2t/backups/...` | `hd2t` |

Notas de almacenamiento:

- toda la persistencia activa de Prometheus debe quedarse en el **NVMe**
- `hd2t` puede recibir copias de seguridad del histórico, pero no debe alojar la TSDB en uso
- `hd5t` no interviene en Prometheus
- el crecimiento del directorio `data/` debe vigilarse desde Grafana o con `du -sh`

## Backup
Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/prometheus/compose.yaml`
- `/home/<usuario>/homelab/compose/prometheus/.env`
- `/home/<usuario>/homelab/compose/prometheus/prometheus.yml`

Si quieres conservar histórico de métricas, respalda también:

- `/home/<usuario>/homelab/data/prometheus/data/`

Recomendación práctica para copiar la TSDB con menor riesgo de inconsistencias:

```bash
cd /home/<usuario>/homelab/compose/prometheus
docker compose stop
```

Después del backup o de una restauración:

```bash
cd /home/<usuario>/homelab/compose/prometheus
docker compose up -d
```

No es necesario respaldar:

- la imagen `prom/prometheus`
- el contenedor recreable
- la red `homelab_shared`

Si pierdes solo la TSDB pero conservas el stack y `prometheus.yml`, Prometheus puede reconstruirse rápidamente, aunque perderás el histórico acumulado.

## Referencias
- Documentación oficial de Prometheus: <https://prometheus.io/docs/introduction/overview/>
- Configuración de Prometheus: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/>
- Flags de línea de comandos y almacenamiento TSDB: <https://prometheus.io/docs/prometheus/latest/command-line/prometheus/>
- Guía oficial de Docker para Prometheus: <https://prometheus.io/docs/guides/getting_started/>
- Imagen Docker oficial: <https://hub.docker.com/r/prom/prometheus>
- Repositorio oficial: <https://github.com/prometheus/prometheus>
