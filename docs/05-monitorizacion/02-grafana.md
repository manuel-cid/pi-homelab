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
- Recomendable haber completado [05-caddy.md](../03-red/05-caddy.md) y [01-authelia.md](../04-seguridad/01-authelia.md) si también vas a publicar Grafana por HTTPS remoto en la subruta `/grafana/` sobre Tailscale.
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
    image: grafana/grafana:12.4.5
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
      GF_SERVER_ROOT_URL: ${GRAFANA_ROOT_URL}
      GF_SERVER_SERVE_FROM_SUB_PATH: ${GRAFANA_SERVE_FROM_SUB_PATH}
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
GRAFANA_ROOT_URL=http://127.0.0.1:11100/
GRAFANA_SERVE_FROM_SUB_PATH=false
PROXY_NETWORK=homelab_proxy
```

La etiqueta `12.4.5` fija una release estable de la rama Grafana 12 y evita la deriva de `latest`, manteniendo además manifiesto multi-arquitectura con variante `linux/arm64`. Al ser un salto de major desde Grafana 11, conviene revisar las notas de migración y validar los dashboards y plugins existentes tras recrear el contenedor.

Puntos importantes de este Compose:

- Grafana se publica solo en `127.0.0.1:11100`, no en toda la LAN por defecto
- el stack se une a `homelab_proxy` para alcanzar `http://prometheus:9090` sin publicar Prometheus en la red local
- los datos persistentes viven en `/home/<user>/homelab/data/grafana/` sobre el **SSD NVMe**
- el aprovisionamiento de datasource y dashboards vive fuera del contenedor, bajo `/home/<user>/homelab/config/grafana/`
- `GF_SERVER_ROOT_URL` y `GF_SERVER_SERVE_FROM_SUB_PATH` permiten dejar preparado el acceso remoto en `https://pi-homelab.<tailnet>.ts.net/grafana/` cuando lo publiques detrás de Caddy
- la imagen queda fijada a `grafana/grafana:12.4.5` para evitar cambios inesperados al recrear el contenedor
- se recomienda **no** configurar triggers de actualización automática de WUD para Grafana

En el `.env` anterior, el valor por defecto mantiene Grafana con acceso local directo en `http://127.0.0.1:11100/`. Cuando actives la publicación remota por Caddy en `/grafana/`, cambia estos dos valores:

```dotenv
GRAFANA_ROOT_URL=https://pi-homelab.<tailnet>.ts.net/grafana/
GRAFANA_SERVE_FROM_SUB_PATH=true
```

<!-- TODO: verificar el hostname MagicDNS final del nodo antes de sustituir `pi-homelab.<tailnet>.ts.net` en `GRAFANA_ROOT_URL`, Caddy y Authelia; si no coincide exactamente, el login remoto y los assets pueden fallar. -->

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

Esta URL local es la opción más simple mientras `GRAFANA_ROOT_URL` siga en `http://127.0.0.1:11100/`. Si más adelante activas la publicación remota con `GRAFANA_ROOT_URL=https://pi-homelab.<tailnet>.ts.net/grafana/`, Grafana pasará a considerar esa subruta HTTPS como URL canónica y la UI local puede redirigir ahí.

Pasos recomendados nada más entrar:

1. Iniciar sesión con `GRAFANA_ADMIN_USER` y `GRAFANA_ADMIN_PASSWORD`.
2. Cambiar la contraseña inicial si has usado un valor temporal en el `.env`.
3. Revisar `Connections` → `Data sources` y verificar que `Prometheus` aparece como datasource por defecto.
4. Confirmar que el registro público está deshabilitado. La pantalla `Administration` → `Settings` puede mostrar el valor por defecto del `grafana.ini` embebido en la imagen, no el valor efectivo inyectado por variable de entorno. La forma fiable de verificarlo es consultar la API:

```bash
curl -u admin:<password> http://127.0.0.1:11100/api/admin/settings 2>/dev/null \
  | grep -o '"users":{[^}]*}'
```

En la respuesta, `allow_sign_up` debe aparecer como `"false"`. Ese valor lo controla `GF_USERS_ALLOW_SIGN_UP=false` en el `.env`. Como comprobación visual complementaria, al cerrar sesión la pantalla de login **no** debe mostrar un enlace *Sign up*.

Si Grafana no puede conectar con Prometheus, las causas habituales son estas:

- Prometheus no está levantado
- Grafana y Prometheus no comparten la red `homelab_proxy`
- el nombre del servicio no es `prometheus`

### 6. Publicación remota opcional en `/grafana/` detrás de Caddy + Authelia

El plan maestro de este repositorio reserva para Grafana una publicación HTTPS remota bajo la subruta `/grafana/`, accesible solo por **Tailscale** y protegida con **Authelia**.

El patrón correcto en este proyecto es este:

- **Caddy** sigue usando `network_mode: host` y llega a Grafana en `127.0.0.1:11100`
- Grafana se configura con `GF_SERVER_ROOT_URL=https://pi-homelab.<tailnet>.ts.net/grafana/`
- Grafana activa `GF_SERVER_SERVE_FROM_SUB_PATH=true`
- **Authelia** protege `/grafana/*` con `forward_auth`

Primero, ajusta el `.env` del stack de Grafana:

```dotenv
GRAFANA_ROOT_URL=https://pi-homelab.<tailnet>.ts.net/grafana/
GRAFANA_SERVE_FROM_SUB_PATH=true
```

Después recrea Grafana:

```bash
cd /home/<user>/homelab/compose/monitoring-grafana
docker compose up -d
docker compose ps
```

Luego, en el `Caddyfile` definido en [05-caddy.md](../03-red/05-caddy.md), añade dentro del bloque `https://{$TAILSCALE_DOMAIN}` este bloque:

```caddyfile
handle /grafana/* {
	import authelia_forward_auth
	reverse_proxy 127.0.0.1:11100
}
```

Y en `configuration.yml` de Authelia, descrito en [01-authelia.md](../04-seguridad/01-authelia.md), añade una regla `two_factor` para esa subruta:

```yaml
access_control:
  rules:
    - domain: 'pi-homelab.<tailnet>.ts.net'
      resources:
        - '^/grafana(/.*)?$'
      policy: two_factor
```

Puntos importantes para no romper el acceso remoto:

- usa `handle /grafana/*` en Caddy (no `handle_path`), porque con `SERVE_FROM_SUB_PATH=true` Grafana espera recibir el prefijo `/grafana` en cada petición; `handle_path` lo recortaría y Grafana no reconocería la ruta
- mantén la barra final en `GRAFANA_ROOT_URL`, porque Grafana genera enlaces y assets en función de esa URL exacta
- no publiques Grafana directamente en la LAN; el patrón de este repositorio es `127.0.0.1:11100` más proxy inverso si hace falta acceso web
- si no has validado todavía Authelia o Caddy, mantén temporalmente `GRAFANA_ROOT_URL=http://127.0.0.1:11100/` y pospone la subruta HTTPS

<!-- TODO: verificar en una prueba real si el flujo final de login remoto exige además ajustar `GF_AUTH_DISABLE_LOGIN_FORM` o encabezados extra en Caddy; con la arquitectura actual no debería hacer falta, pero conviene validarlo al desplegar `Authelia` y `Caddy` juntos. -->

### 7. Verificar consultas con Explore

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

### 8. Dashboards recomendados

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

### 9. Operación diaria

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
