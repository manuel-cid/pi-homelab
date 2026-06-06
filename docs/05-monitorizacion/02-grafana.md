# Grafana

## Descripción

**Grafana** es la capa de visualización del stack de observabilidad del homelab: consulta métricas almacenadas en [01-prometheus.md](01-prometheus.md), las presenta en dashboards y permite construir paneles para revisar de un vistazo el estado de la Raspberry Pi 5, Docker Engine y los servicios del laboratorio.

En este homelab conviene mantener un criterio simple:

- Grafana **no** guarda métricas; solo guarda configuración, usuarios, dashboards, alertas y preferencias
- esos datos persistentes deben vivir en el **SSD NVMe**
- el datasource principal es Prometheus, alcanzable por nombre interno `prometheus:9090`
- los dashboards más útiles en esta fase son:
  - métricas del host con **Node Exporter Full** cuando exista [03-node-exporter.md](03-node-exporter.md)
  - métricas del daemon Docker obtenidas desde el endpoint nativo `/metrics`
  - temperatura de la Raspberry Pi a partir de las métricas del host

## Requisitos Previos

- Haber completado [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber completado [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Haber completado [01-prometheus.md](01-prometheus.md).
- Haber completado [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md).
- Recomendable haber completado [03-node-exporter.md](03-node-exporter.md) si se van a usar dashboards de sistema y temperatura.
- Tener creada la red Docker externa `homelab_proxy` para que Grafana alcance Prometheus por nombre interno.
- Poder crear directorios persistentes en `/home/<user>/homelab/config/` y `/home/<user>/homelab/data/`.
- Puertos necesarios en esta fase:
  - **`11100/tcp`** publicado solo en `127.0.0.1` para la UI de Grafana
  - **`3000/tcp`** interno del contenedor

## Docker Compose

Archivo: `/home/<user>/homelab/compose/monitoring-grafana/docker-compose.yml`

```yaml
name: monitoring-grafana

services:
  grafana:
    image: grafana/grafana:11.6.15
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      GF_SECURITY_ADMIN_USER: ${GRAFANA_ADMIN_USER}
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_AUTH_ANONYMOUS_ENABLED: "false"
    ports:
      - "${GRAFANA_BIND_IP}:${GRAFANA_PORT}:3000"
    volumes:
      - ${DATA_ROOT}/grafana:/var/lib/grafana
      - ${CONFIG_ROOT}/grafana/provisioning:/etc/grafana/provisioning:ro
      - ${CONFIG_ROOT}/grafana/dashboards:/var/lib/grafana/dashboards:ro
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

Archivo recomendado: `/home/<user>/homelab/compose/monitoring-grafana/.env`

```dotenv
TZ=Europe/Madrid
CONFIG_ROOT=/home/<user>/homelab/config
DATA_ROOT=/home/<user>/homelab/data
GRAFANA_BIND_IP=127.0.0.1
GRAFANA_PORT=11100
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=<cambia-esta-password>
PROXY_NETWORK=homelab_proxy
```

La etiqueta `11.6.15` es una opción conservadora para este homelab: fija una release anual madura de Grafana 11 y evita la deriva de `latest`, manteniendo además manifiesto multi-arquitectura con variante `linux/arm64`.

Puntos importantes de este Compose:

- Grafana se publica solo en `127.0.0.1:11100`, no en toda la LAN por defecto
- el stack se une a `homelab_proxy` para alcanzar `http://prometheus:9090` sin publicar Prometheus en la red local
- los datos persistentes viven en `/home/<user>/homelab/data/grafana/` sobre el **SSD NVMe**
- el aprovisionamiento de datasource y dashboards vive fuera del contenedor, bajo `/home/<user>/homelab/config/grafana/`
- la imagen queda fijada a `grafana/grafana:11.6.15` para evitar cambios inesperados al recrear el contenedor
- se recomienda **no** configurar triggers de actualización automática de WUD para Grafana

## Configuración

### 1. Preparar directorios del stack

```bash
mkdir -p /home/<user>/homelab/compose/monitoring-grafana
mkdir -p /home/<user>/homelab/config/grafana/provisioning/datasources
mkdir -p /home/<user>/homelab/config/grafana/provisioning/dashboards
mkdir -p /home/<user>/homelab/config/grafana/dashboards
mkdir -p /home/<user>/homelab/data/grafana
```

El contenedor oficial de Grafana usa el UID `472` para escribir datos persistentes. Ajusta permisos del directorio de datos antes del primer arranque:

```bash
sudo chown -R 472:472 /home/<user>/homelab/data/grafana
sudo chmod 755 /home/<user>/homelab/data/grafana
```

Si la red externa compartida aún no existe, créala:

```bash
docker network inspect homelab_proxy >/dev/null 2>&1 || docker network create homelab_proxy
```

### 2. Aprovisionar el datasource de Prometheus

Archivo: `/home/<user>/homelab/config/grafana/provisioning/datasources/prometheus.yml`

```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
    jsonData:
      httpMethod: POST
```

Con este fichero, Grafana arranca con el datasource listo sin tener que crearlo a mano desde la UI.

Punto importante:

- `prometheus` debe ser el nombre del servicio definido en [01-prometheus.md](01-prometheus.md) y ambos stacks deben compartir la red `homelab_proxy`

### 3. Aprovisionar la carpeta de dashboards

Archivo: `/home/<user>/homelab/config/grafana/provisioning/dashboards/default.yml`

```yaml
apiVersion: 1

providers:
  - name: default
    orgId: 1
    folder: Homelab
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /var/lib/grafana/dashboards
```

Esto deja preparada una carpeta persistente para guardar dashboards versionados como JSON bajo `/home/<user>/homelab/config/grafana/dashboards/`.

No es obligatorio llenar esa carpeta desde el primer día. Puedes importar dashboards desde la UI y, cuando alguno quede estable, exportarlo a JSON para dejarlo bajo control de cambios.

### 4. Guardar el `.env` y desplegar el stack

Guarda el `.env` del apartado Compose y despliega:

```bash
cd /home/<user>/homelab/compose/monitoring-grafana
docker compose config
docker compose up -d
docker compose ps
```

Validaciones mínimas tras el arranque:

```bash
docker compose logs --tail=100 grafana
curl http://127.0.0.1:11100/api/health
```

El resultado esperado es este:

- el contenedor queda en estado `Up`
- `GET /api/health` responde JSON con estado `ok`
- Grafana arranca sin errores de permisos sobre `/var/lib/grafana`

### 5. Acceso inicial y endurecimiento básico

Abre la UI desde el host o mediante un túnel SSH local:

- `http://127.0.0.1:11100`

Pasos recomendados nada más entrar:

1. Iniciar sesión con `GRAFANA_ADMIN_USER` y `GRAFANA_ADMIN_PASSWORD`.
2. Cambiar la contraseña inicial si has usado un valor temporal en el `.env`.
3. Revisar `Connections` → `Data sources` y verificar que `Prometheus` aparece como datasource por defecto.
4. Entrar en `Administration` → `Users and access` y confirmar que el registro público está deshabilitado.

Si Grafana no puede conectar con Prometheus, las causas habituales son estas:

- Prometheus no está levantado
- Grafana y Prometheus no comparten la red `homelab_proxy`
- el nombre del servicio no es `prometheus`

### 6. Verificar consultas con Explore

Antes de importar dashboards, conviene validar que las métricas llegan bien:

1. Ir a `Explore`.
2. Elegir el datasource `Prometheus`.
3. Lanzar consultas simples:

```promql
up
```

```promql
node_uname_info
```

```promql
engine_daemon_engine_cpus_cpus
```

Lectura práctica:

- `up` confirma el estado de scrape de los targets
- `node_uname_info` funcionará cuando esté desplegado [03-node-exporter.md](03-node-exporter.md)
- `engine_daemon_engine_cpus_cpus` funcionará si en [01-prometheus.md](01-prometheus.md) ya habilitaste el endpoint nativo `/metrics` de Docker Engine

### 7. Dashboards recomendados

#### Dashboard 1: sistema del host con Node Exporter Full

El dashboard recomendado para el host es **Node Exporter Full** una vez desplegado [03-node-exporter.md](03-node-exporter.md).

Qué debe mostrar como mínimo:

- carga del sistema
- uso de CPU por modo
- memoria libre y usada
- uso de disco del **SSD NVMe**
- actividad de red
- uso de sistema de ficheros para `/`, `/boot/firmware` y puntos de montaje relevantes

Consejos prácticos:

- usa siempre el datasource `Prometheus`
- si el dashboard pide la variable `job`, normalmente el valor correcto será `node-exporter`
- si no aparecen datos, revisa primero en Prometheus que el target `node-exporter` esté `UP`

#### Dashboard 2: Docker Engine vía endpoint nativo `/metrics`

Para Docker no hace falta añadir un exporter adicional si ya estás recogiendo el endpoint nativo del daemon definido en [01-prometheus.md](01-prometheus.md).

La opción más simple es crear un dashboard propio llamado `Docker Engine` con paneles como estos:

- contenedores en ejecución:

```promql
sum(engine_daemon_container_states_containers{state="running"})
```

- contenedores parados:

```promql
sum(engine_daemon_container_states_containers{state="stopped"})
```

- contenedores pausados:

```promql
sum(engine_daemon_container_states_containers{state="paused"})
```

- imágenes almacenadas:

```promql
engine_daemon_images
```

- CPUs visibles para el daemon:

```promql
engine_daemon_engine_cpus_cpus
```

- memoria visible para el daemon:

```promql
engine_daemon_engine_memory_bytes
```

Esto no sustituye a métricas por contenedor con cAdvisor o exporters específicos, pero para este homelab ofrece una visión suficiente del estado general del motor Docker con menos complejidad.

#### Dashboard 3: temperatura de la Raspberry Pi

La temperatura es especialmente útil en una Raspberry Pi 5 con SSD NVMe y varios discos USB conectados.

La forma práctica de montarlo es:

1. Ir a `Explore`.
2. Buscar primero una de estas métricas:

```promql
node_thermal_zone_temp
```

```promql
node_hwmon_temp_celsius
```

3. Crear un panel nuevo usando la métrica que realmente exista en tu host.

Consultas típicas:

- si existe `node_thermal_zone_temp`:

```promql
max(node_thermal_zone_temp) / 1000
```

- si existe `node_hwmon_temp_celsius`:

```promql
max(node_hwmon_temp_celsius)
```

Ajustes recomendados del panel:

- unidad: `Celsius (°C)`
- visualización: `Time series` y un `Stat` adicional para el valor actual
- umbrales orientativos: `70 °C` advertencia, `80 °C` crítico

Si no aparece ninguna métrica de temperatura, revisa la configuración de [03-node-exporter.md](03-node-exporter.md), porque ahí es donde debe quedar resuelta la exportación de métricas del host.

### 8. Operación diaria

Comandos útiles para operación diaria:

```bash
cd /home/<user>/homelab/compose/monitoring-grafana
docker compose logs -f grafana
docker compose restart grafana
curl -s http://127.0.0.1:11100/api/health
```

Si quieres verificar la conectividad hacia Prometheus desde la misma red Docker compartida, usa un contenedor efímero conectado a `homelab_proxy`:

```bash
docker run --rm --network homelab_proxy curlimages/curl:8.12.1 \
  -fsS http://prometheus:9090/-/ready
```

Esto evita asumir que la imagen de Grafana incluya herramientas como `wget` o `curl` en su interior.

## Almacenamiento

Rutas relevantes de este despliegue:

- `docker-compose.yml`: `/home/<user>/homelab/compose/monitoring-grafana/docker-compose.yml`
- `.env`: `/home/<user>/homelab/compose/monitoring-grafana/.env`
- aprovisionamiento de datasources: `/home/<user>/homelab/config/grafana/provisioning/datasources/`
- aprovisionamiento de dashboards: `/home/<user>/homelab/config/grafana/provisioning/dashboards/`
- dashboards versionados: `/home/<user>/homelab/config/grafana/dashboards/`
- datos persistentes: `/home/<user>/homelab/data/grafana/`

Notas importantes:

- `/home/<user>/homelab/data/grafana/` debe permanecer en el **SSD NVMe**
- ahí Grafana guarda su base SQLite por defecto, sesiones, plugins instalados y estado interno
- `hd2t` y `hd5t` no son ubicaciones adecuadas para estos datos operativos
- los dashboards que realmente quieras conservar de forma reproducible conviene exportarlos a JSON y guardarlos bajo `/home/<user>/homelab/config/grafana/dashboards/`

## Backup

Lo que conviene respaldar en este servicio es esto:

- `/home/<user>/homelab/compose/monitoring-grafana/docker-compose.yml`
- `/home/<user>/homelab/compose/monitoring-grafana/.env`
- `/home/<user>/homelab/config/grafana/provisioning/`
- `/home/<user>/homelab/config/grafana/dashboards/`
- `/home/<user>/homelab/data/grafana/`

Matiz importante:

- si todos los datasources y dashboards críticos están aprovisionados como ficheros, la restauración será más limpia y predecible
- si creas dashboards solo desde la UI y no los exportas, seguirán viviendo dentro de `/home/<user>/homelab/data/grafana/`, normalmente en la base SQLite interna
- el `.env` puede contener credenciales sensibles; trátalo como material de backup protegido

## Referencias

- Grafana Docs: [Run Grafana Docker image](https://grafana.com/docs/grafana/latest/setup-grafana/installation/docker/)
- Grafana Docs: [Provision Grafana](https://grafana.com/docs/grafana/latest/administration/provisioning/)
- Grafana Docs: [Prometheus data source](https://grafana.com/docs/grafana/latest/datasources/prometheus/)
- Docker Hub: [grafana/grafana](https://hub.docker.com/r/grafana/grafana)
