# cAdvisor

## Descripción
**cAdvisor** será el servicio encargado de exponer métricas de uso y rendimiento de los contenedores Docker del homelab para que **Prometheus** pueda recopilarlas y **Grafana** pueda visualizarlas.

En este proyecto su papel es cubrir, como mínimo:

- CPU por contenedor
- memoria y límites de memoria
- red por contenedor
- actividad básica de sistema de ficheros y disco por contenedor
- metadatos útiles para relacionar métricas con servicios Docker

cAdvisor se despliega en Docker, pero necesita observar el **host real** y el estado interno del motor Docker. Por eso en esta guía se montan rutas del sistema anfitrión en modo lectura y se conecta el stack a `homelab_shared` para que Prometheus lo alcance como `cadvisor:8080`.

cAdvisor es esencialmente **stateless** para este homelab: no requiere base de datos ni volumen persistente propio. La parte que conviene versionar y respaldar es su stack Compose.

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
  - `8080/tcp` expuesto por cAdvisor
  - `127.0.0.1:8080/tcp` publicado opcionalmente en el host para pruebas locales con `curl`
  - `8080/tcp` accesible dentro de `homelab_shared` para que Prometheus raspe `cadvisor:8080`

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/cadvisor/
├── compose.yaml
└── .env
```

Fichero `.env` recomendado:

```dotenv
TZ=Europe/Madrid
CADVISOR_PORT=8080
```

Notas sobre estas variables:

- `CADVISOR_PORT=8080` publica la interfaz y el endpoint de métricas solo en loopback del host para pruebas locales.
- Prometheus no necesita usar ese puerto publicado en el host; lo normal es que raspe `http://cadvisor:8080/metrics` dentro de `homelab_shared`.
- la imagen queda fijada a `ghcr.io/google/cadvisor:v0.56.2` para evitar cambios inesperados al recrear el stack; si más adelante actualizas la versión, conviene revisar de nuevo dashboards y métricas expuestas

Fichero `compose.yaml`:

```yaml
name: cadvisor

services:
  cadvisor:
    image: ghcr.io/google/cadvisor:v0.56.2
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    command:
      - --docker_only=true
    ports:
      - "127.0.0.1:${CADVISOR_PORT}:8080"
    privileged: true
    devices:
      - /dev/kmsg:/dev/kmsg
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker:/var/lib/docker:ro
      - /dev/disk:/dev/disk:ro
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
mkdir -p /home/<usuario>/homelab/compose/cadvisor

sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/cadvisor

cd /home/<usuario>/homelab/compose/cadvisor
docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

Resultado esperado:

- el contenedor `cadvisor-cadvisor-1` queda levantado
- el endpoint local responde en `http://127.0.0.1:8080/metrics`
- Prometheus puede raspar el servicio usando `http://cadvisor:8080/metrics`
- el job `cadvisor` pasa a estado `UP` en la UI de Prometheus

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| Endpoint local de prueba | `http://127.0.0.1:8080/metrics` |
| Endpoint interno para Prometheus | `http://cadvisor:8080/metrics` |
| Stack Compose | `/home/<usuario>/homelab/compose/cadvisor/` |
| Persistencia de aplicación | No aplica |
| Red entre stacks | `homelab_shared` |
| Job esperado en Prometheus | `cadvisor` |

### 1. Preparar el directorio del stack

Crear la ruta del stack:

```bash
mkdir -p /home/<usuario>/homelab/compose/cadvisor
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/cadvisor
chmod 755 /home/<usuario>/homelab/compose/cadvisor
```

cAdvisor no necesita una carpeta de datos en `/home/<usuario>/homelab/data` porque no mantiene una base persistente propia en este despliegue.

### 2. Entender por qué necesita acceso amplio al host

cAdvisor debe inspeccionar tanto el sistema anfitrión como el runtime de contenedores para poder exponer métricas útiles. En este stack se montan estas rutas:

- `/:/rootfs:ro` para ver la raíz del host
- `/var/run:/var/run:ro` para acceder al socket y al estado del runtime
- `/sys:/sys:ro` para leer información de cgroups y del kernel
- `/var/lib/docker:/var/lib/docker:ro` para descubrir contenedores, capas y metadatos de Docker
- `/dev/disk:/dev/disk:ro` para resolver información de dispositivos de bloque

Además, se usa:

- `privileged: true`
- `devices: /dev/kmsg:/dev/kmsg`

Ese conjunto se parece al despliegue de referencia del proyecto y reduce problemas típicos al leer métricas del host. En un homelab pequeño es una opción pragmática, pero conviene recordar que aumenta el nivel de acceso del contenedor y por eso no debe exponerse innecesariamente.

### 3. Entender el flag `--docker_only=true`

El parámetro:

```text
--docker_only=true
```

hace que cAdvisor se centre en contenedores Docker y reduzca ruido procedente de cgroups crudos del host.

En este homelab ese enfoque encaja bien porque:

- el objetivo principal es monitorizar servicios Docker
- simplifica dashboards y consultas en Grafana
- evita mezclar demasiadas series no relevantes con las métricas de contenedores reales

Si en el futuro necesitas estadísticas más detalladas de cgroups ajenos a Docker, puedes retirar ese flag y volver a validar dashboards y cardinalidad en Prometheus.

### 4. Desplegar cAdvisor

Una vez guardados `compose.yaml` y `.env`:

```bash
cd /home/<usuario>/homelab/compose/cadvisor
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f
ss -tulpn | grep 8080
curl http://127.0.0.1:8080/metrics | head
```

Resultados esperados:

- `ss` muestra el puerto `8080` escuchando solo en `127.0.0.1`
- `curl` devuelve métricas en formato Prometheus
- aparecen familias `container_*` y `machine_*`

### 5. Verificar la integración con Prometheus

En la UI de Prometheus revisa:

```text
http://<IP-del-host>:9090/targets
```

El target esperado es:

```text
cadvisor:8080
```

Y su estado debería pasar a `UP`.

Consultas rápidas en Prometheus:

```promql
up{job="cadvisor"}
```

```promql
container_cpu_usage_seconds_total{job="cadvisor"}
```

```promql
container_memory_usage_bytes{job="cadvisor"}
```

```promql
container_network_receive_bytes_total{job="cadvisor"}
```

Interpretación rápida:

- `up{job="cadvisor"}` debe devolver `1`
- las demás consultas deben devolver series por contenedor
- si no aparece nada, revisa nombre del servicio, red `homelab_shared` y el target definido en `prometheus.yml`

### 6. Validar que las métricas corresponden a contenedores reales

cAdvisor expone muchas series. Antes de importar dashboards conviene comprobar que devuelve datos de contenedores reales del homelab.

Consultas útiles:

```promql
sum by (name) (rate(container_cpu_usage_seconds_total{job="cadvisor"}[5m]))
```

```promql
sum by (name) (container_memory_working_set_bytes{job="cadvisor"})
```

```promql
sum by (name) (rate(container_network_transmit_bytes_total{job="cadvisor"}[5m]))
```

Qué revisar:

- que aparezcan nombres de contenedores esperables del homelab
- que las series no estén vacías para servicios activos
- que no todo el tráfico o el consumo recaiga solo en un contenedor genérico

Si ves demasiadas series con nombres poco útiles o contenedores internos, filtra después en PromQL o en Grafana, pero no cambies todavía el job `cadvisor` definido en Prometheus.

### 7. Preparar el uso desde Grafana

Cuando despliegues `docs/05-monitorizacion/02-grafana.md`, la integración habitual será con el datasource `Prometheus`.

El punto importante es mantener consistencia entre:

- nombre del job en Prometheus: `cadvisor`
- endpoint interno: `cadvisor:8080`
- dashboards que consulten métricas `container_*`

Consultas sencillas para un dashboard inicial:

```promql
sum by (name) (rate(container_cpu_usage_seconds_total{job="cadvisor"}[5m]))
```

```promql
sum by (name) (container_memory_working_set_bytes{job="cadvisor"})
```

```promql
sum by (name) (rate(container_fs_reads_bytes_total{job="cadvisor"}[5m]))
```

```promql
sum by (name) (rate(container_fs_writes_bytes_total{job="cadvisor"}[5m]))
```

Si más adelante importas un dashboard comunitario y algunos paneles quedan vacíos, revisa primero:

- que el job siga llamándose `cadvisor`
- que las consultas no esperen otro label distinto para el nombre del contenedor
- que el rango temporal del panel sea suficiente para ver actividad real

### 8. Endurecimiento mínimo recomendado

cAdvisor no incorpora autenticación propia y no debería exponerse más de lo necesario.

En esta guía se sigue una política conservadora:

- no se publica `8080` en todas las interfaces del host
- el scraping real queda dentro de `homelab_shared`
- el puerto del host queda limitado a `127.0.0.1` solo para pruebas locales
- no se habilitan métricas o flags extra de forma prematura

Como el contenedor necesita acceso elevado al host, no conviene reutilizar este stack para exposición pública, proxy inverso ni acceso externo fuera de la LAN y Tailscale.

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose de cAdvisor | `/home/<usuario>/homelab/compose/cadvisor/` | SSD NVMe |
| Variables del stack | `/home/<usuario>/homelab/compose/cadvisor/.env` | SSD NVMe |
| Datos persistentes de aplicación | No aplica | No aplica |
| Mounts de solo lectura del host | `/`, `/var/run`, `/sys`, `/var/lib/docker`, `/dev/disk` | Host |
| Backups del stack | `/mnt/hd2t/backups/...` | `hd2t` |

Notas de almacenamiento:

- cAdvisor no mantiene base de datos ni volumen persistente propio en este despliegue
- el histórico local que conserva cAdvisor es temporal y se mantiene en memoria, no en disco
- no hace falta crear `/home/<usuario>/homelab/data/cadvisor`
- el servicio solo lee información del host mediante bind mounts
- `hd5t` no interviene en este stack

## Backup
Respaldar como mínimo:

- `/home/<usuario>/homelab/compose/cadvisor/compose.yaml`
- `/home/<usuario>/homelab/compose/cadvisor/.env`

No es necesario respaldar:

- la imagen `ghcr.io/google/cadvisor`
- el contenedor recreable
- ningún volumen persistente, porque cAdvisor no guarda estado duradero en este diseño
- la red `homelab_shared`

Si pierdes este stack, bastará con restaurar `compose.yaml` y `.env`, ejecutar `docker compose up -d` y verificar que Prometheus vuelva a ver `cadvisor:8080`.

## Referencias
- Documentación oficial de cAdvisor: <https://github.com/google/cadvisor>
- Quick start oficial en Docker: <https://github.com/google/cadvisor/blob/master/README.md>
- Flags y opciones de runtime: <https://github.com/google/cadvisor/blob/master/docs/runtime_options.md>
- Integración oficial con Prometheus: <https://github.com/google/cadvisor/blob/master/docs/storage/prometheus.md>
- Imagen oficial en GHCR: <https://github.com/google/cadvisor/pkgs/container/cadvisor>
- Releases oficiales: <https://github.com/google/cadvisor/releases>
