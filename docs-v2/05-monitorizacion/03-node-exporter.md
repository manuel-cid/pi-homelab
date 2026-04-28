# Node Exporter

## Descripción

Despliegue de **Node Exporter** (`prom/node-exporter`) como **agente de métricas del host** del homelab: expone en `:9100/metrics` en formato Prometheus las lecturas de `/proc`, `/sys` y el FS raíz que describen el estado de la Pi 5 (CPU por core, RAM, swap, load average, disco por filesystem, red por interfaz, **temperatura del SoC vía `hwmon`**, uptime, descriptors abiertos, etc.). Prometheus ([`./01-prometheus.md`](./01-prometheus.md)) lo scrapea cada 30 s desde la red `homelab` y Grafana ([`./02-grafana.md`](./02-grafana.md)) lo pinta usando el dashboard "Node Exporter Full" (Grafana.com #1860) que este doc provisiona.

Node Exporter es el tercer servicio del stack `monitoring` (fila §1.1 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)). Este documento **extiende** el `~/homelab/stacks/monitoring/docker-compose.yml` que dejaron Prometheus y Grafana, **no** crea un compose nuevo. Tras este doc, el stack tiene tres servicios (`prometheus`, `grafana`, `node-exporter`); los siguientes docs (`./04-cadvisor.md`, `./05-uptime-kuma.md`, `./06-dozzle.md`) añaden el resto.

> **Alcance de red**: Node Exporter **no** publica puertos al host. No tiene UI propia: `/metrics` es texto plano consumido por Prometheus a través de la red bridge `homelab`. No se sirve detrás de Caddy + Authelia: el endpoint no aporta nada a un humano (es un dump de líneas `node_*`) y exponerlo añadiría una dependencia inversa (Caddy/Authelia → Node Exporter) que no existe. Los humanos miran las mismas métricas en Grafana.

> **Por qué Node Exporter y no otro agente** (Telegraf, collectd, glances exporter, etc.):
>
> 1. **Estándar de facto del ecosistema Prometheus.** Casi todos los dashboards públicos para "salud de un servidor Linux" (Grafana.com) están escritos contra las métricas de Node Exporter (`node_cpu_seconds_total`, `node_memory_MemAvailable_bytes`, `node_filesystem_avail_bytes`, `node_hwmon_temp_celsius`...). Importar `Node Exporter Full` (#1860) y `Raspberry Pi Monitoring` (#10578) requiere cero adaptación.
> 2. **Modelo Prometheus puro: pull-based, sin estado.** El proceso sólo abre `/metrics` HTTP plano; Prometheus va a buscar las series. No hay agente central, ni cola, ni acoplamiento con un broker. Si Prometheus está parado, Node Exporter sigue funcionando y no consume nada (no hay buffer, no hay backpressure).
> 3. **Lectura directa de `/proc`, `/sys` y FS raíz.** No usa polling de comandos (`ps`, `df`, `iostat`); lee los ficheros del kernel directamente. Esto da granularidad de scrape (cada 30 s) sin coste y, sobre todo, evita las quirks de los wrappers (`df` con loopbacks, `ps` con /proc auto-mounts, etc.).
> 4. **Coste mínimo en una Pi 5.** El proceso reposa en torno a 8–12 MB RAM y consume <0.1 % CPU en idle. En cada scrape sube a ~50 ms de CPU para parsear `/proc`. Es la sobrecarga más baja de todos los exporters del homelab.
> 5. **Multi-arch oficial.** La imagen `prom/node-exporter` se publica para `linux/arm64` desde 2020; no hay que recurrir a forks comunitarios. La rama 1.x es muy estable y no ha tenido cambios incompatibles desde hace años.
> 6. **No se elige Telegraf** porque InfluxDB no se usa (Prometheus ya hace de TSDB) y Telegraf duplica la sintaxis de scrape; **no se elige collectd** porque su modelo push y su formato (RRD) no encajan con Prometheus; **no se elige glances** porque su exporter Prometheus es un proyecto de terceros (no oficial), su set de métricas se solapa parcialmente con Node Exporter y mezclar ambos crea ambigüedades en los dashboards.

---

## Requisitos Previos

- **Prometheus desplegado y sano** según [`./01-prometheus.md`](./01-prometheus.md): `docker inspect prometheus --format '{{.State.Health.Status}}'` debe devolver `healthy`. La query `up{job="prometheus"}` devuelve `1`. El `prometheus.yml` ya tiene el placeholder comentado del `job_name: 'node-exporter'` (§4 de Prometheus, líneas marcadas como `ACTIVAR cuando ./03-node-exporter.md ...`).
- **Grafana desplegado y sano** según [`./02-grafana.md`](./02-grafana.md): `docker inspect grafana --format '{{.State.Health.Status}}'` debe devolver `healthy`. El árbol de provisioning `~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/` existe y está configurado para auto-recargar cualquier `.json` que aparezca (§6.1 de Grafana, `updateIntervalSeconds: 30`).
- **Stack `monitoring` ya inicializado** con los servicios anteriores: `~/homelab/stacks/monitoring/{docker-compose.yml,prometheus.yml,grafana/...,.env.example}` versionados en git, `/mnt/hd2t/services/monitoring/.env` con las variables comunes y las de Prometheus + Grafana.
- **Red `homelab`** creada según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2 (`172.20.0.0/24`, bridge `br-homelab`, `external: true`).
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No se añaden reglas: Node Exporter no publica puertos al host; el tráfico llega únicamente desde Prometheus por la red bridge.
- **Estructura de directorios** del stack `monitoring` ya en su sitio (creada por [`./01-prometheus.md`](./01-prometheus.md) §3.2 y [`./02-grafana.md`](./02-grafana.md) §3.2). Node Exporter **no necesita un directorio de datos propio** (no escribe nada al disco); el bootstrap original ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6.6) creó un `/mnt/hd2t/services/node-exporter/` vacío del esquema antiguo "un dir por servicio" que se **elimina** en §3.1.
- **Comprobaciones rápidas**:
  ```bash
  # Prometheus está sano y tiene el placeholder del job listo:
  docker inspect prometheus --format '{{.State.Health.Status}}'
  # Esperado: healthy
  grep -A2 "job_name: 'node-exporter'" ~/homelab/stacks/monitoring/prometheus.yml | head
  # Esperado: las 3 líneas comentadas (#) que se descomentarán en §6.

  # Grafana está sano y autoprovisiona dashboards:
  docker inspect grafana --format '{{.State.Health.Status}}'
  # Esperado: healthy
  ls ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/
  # Esperado: prometheus-stats.json (el único hasta ahora).

  # El stack monitoring tiene exactamente prometheus + grafana:
  docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml ps --services
  # Esperado: prometheus, grafana

  # /proc, /sys y / son accesibles por root (lo serán al bind-mountarlos):
  test -r /proc/stat && test -r /sys/class/hwmon && echo "OK"
  # Esperado: OK
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Imagen Docker | **`prom/node-exporter:v1.8.2`** | Imagen oficial multi-arch (incluye `linux/arm64`). v1.8.x es la rama estable actual, sin cambios incompatibles con dashboards públicos en años. **No** se usa `quay.io/prometheus/node-exporter` (mismo binario, otro registry); el repo en Docker Hub `prom/...` es coherente con el resto del homelab (`prom/prometheus` en [`./01-prometheus.md`](./01-prometheus.md)). |
| Tag de imagen | **Pinned a release puntual**, nunca `latest` | Misma regla de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1. La rama 1.x es muy estable, pero el upgrade se hace leyendo el [CHANGELOG](https://github.com/prometheus/node_exporter/blob/master/CHANGELOG.md) por si alguna métrica se renombra (caso poco frecuente, pero documentado: e.g. `node_cpu` → `node_cpu_seconds_total` en 0.16). |
| Política de Watchtower | **`watchtower.enable: "true"`** | Coherente con [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 (Node Exporter está en la lista de incluidos). Los upgrades de patch (1.8.2 → 1.8.3) son seguros: no hay BD propia, no hay schema, no hay estado. |
| Modo de red | **Sólo `homelab`** (bridge `external`) | Prometheus, que vive en `homelab`, scrapea `node-exporter:9100` por DNS interno. **No** se usa `network_mode: host` (alternativa común en otros homelabs): es incompatible con `networks:` (no se puede pertenecer a la vez al host y a un bridge), expondría `:9100` al LAN sin filtro y obligaría a Prometheus a usar la IP del gateway del bridge para alcanzarlo, rompiendo el patrón "todo por DNS Docker" del homelab. **Las métricas del host se obtienen igual** vía bind mount de `/proc`, `/sys` y `/` con los flags `--path.procfs`, `--path.sysfs` y `--path.rootfs` (§5.1). |
| `ports:` publicados al host | **Ninguno** | Idéntico razonamiento que Prometheus y Grafana. `:9100` queda accesible **sólo** desde la red `homelab`. Publicarlo añadiría una entrada que cualquier cliente del LAN podría leer (las métricas de Node Exporter son una buena pista de inventario para un atacante: hostname, kernel, IPs, FS, procesos abiertos a través de descriptors). |
| Acceso al `/metrics` | **Sin autenticación, sólo desde `homelab`** | Node Exporter soporta TLS y basic auth (`--web.config.file`), pero añadir esa capa cuando ya hay aislamiento de red (bridge privado `172.20.0.0/24`) es complejidad sin beneficio. El threat model "alguien con acceso al daemon Docker" ya tiene caminos mucho más fáciles para extraer información del host. |
| `pid: host` | **NO** se activa | El default de Node Exporter NO necesita el namespace de PIDs del host. Sólo lo necesitan colectores opcionales (`--collector.processes`, `--collector.systemd`) que **no** se activan en este homelab. Mantener el aislamiento de PIDs es una victoria gratuita de superficie. |
| Bind mounts del host | **`/proc:/host/proc:ro,rslave`, `/sys:/host/sys:ro,rslave`, `/:/rootfs:ro,rslave`** | Receta canónica del proyecto upstream ([README de node_exporter](https://github.com/prometheus/node_exporter#docker)). `/proc` da CPU, RAM, red, load average, descriptors. `/sys` da `hwmon` (temperatura del SoC), block devices, network classes. `/` (montado como `/rootfs`) permite al colector `filesystem` enumerar todos los mountpoints del host (no sólo los del namespace del contenedor). `ro,rslave` es lo más restrictivo posible: read-only y propagación de unmounts del host (si se desconecta `hd2t`, el contenedor lo ve). |
| `--path.procfs=/host/proc` | **Activado** | Le dice al binario que en lugar de leer `/proc` (el del namespace del contenedor) lea `/host/proc` (el bind mount del host). Sin esto, el contenedor reportaría sus propias métricas (1 proceso, 1 interfaz `eth0` de bridge, etc.) en lugar de las del host. |
| `--path.sysfs=/host/sys` | **Activado** | Idem para `/sys`. Crítico para `hwmon` (temperatura) y `node_class_*` (interfaces y discos). |
| `--path.rootfs=/rootfs` | **Activado** | El colector `filesystem` reporta una métrica por cada mountpoint que ve. Sin `--path.rootfs`, vería los mountpoints del namespace del contenedor (típicamente `/`, `/etc/hosts`, `/etc/resolv.conf`, los bind mounts...) que no son los del host. Con `--path.rootfs=/rootfs` reporta los del host (`/`, `/boot/firmware`, `/mnt/hd5t`, `/mnt/hd2t`, swap...). |
| `--collector.filesystem.mount-points-exclude` | **`^/(sys\|proc\|dev\|host\|etc\|rootfs/(sys\|proc\|dev\|host\|etc))($\|/)`** | Filtra mountpoints "ruido" del propio namespace del contenedor (que no se esconden por completo aunque se haya hecho `--path.rootfs`). Sin este filtro, el dashboard "Node Exporter Full" muestra docenas de filesystems irrelevantes (`/etc/hosts`, `/dev/shm`, etc.). El default de upstream cubre lo básico; aquí se amplía para incluir `^/host/...` y `^/rootfs/(sys\|proc\|...)/...` que son los bind mounts. |
| `--collector.filesystem.fs-types-exclude` | **`^(autofs\|binfmt_misc\|bpf\|cgroup\|cgroup2\|configfs\|debugfs\|devpts\|devtmpfs\|fusectl\|hugetlbfs\|mqueue\|nsfs\|overlay\|proc\|procfs\|pstore\|rpc_pipefs\|securityfs\|selinuxfs\|squashfs\|sysfs\|tracefs)$`** | Filtra tipos de FS sintéticos (los que no representan almacenamiento real). El default de upstream es similar; se hace explícito para que el panel "Disk Space Used" del dashboard 1860 sólo muestre los FS reales (microSD, hd5t, hd2t). |
| `--collector.netclass.netlink` | **Activado** | Por defecto Node Exporter lee `/sys/class/net/<iface>/` para descubrir interfaces. En kernels modernos, `--collector.netclass.netlink` usa Netlink (más rápido y con menos race conditions). Debe combinarse con `--path.sysfs=/host/sys` para que las interfaces enumeradas sean las del host. |
| Colectores adicionales activados | **`--collector.processes`** **NO**, **`--collector.systemd`** **NO**, **`--collector.interrupts`** **NO** | Cada uno requiere capabilities o namespaces extra (`processes` necesita `pid: host`; `systemd` necesita el socket DBus; `interrupts` lee `/proc/interrupts` pero produce métricas de cardinalidad alta). El homelab no los necesita: la temperatura, CPU, RAM y disco (que son la pregunta del 95% de las veces) ya están cubiertos por los colectores del default. |
| Colectores desactivados | **`--no-collector.wifi`**, **`--no-collector.zfs`**, **`--no-collector.btrfs`**, **`--no-collector.infiniband`**, **`--no-collector.nfs`**, **`--no-collector.nfsd`** | La Pi 5 del homelab no tiene WiFi (Ethernet por cable, [`../00-hardware/02-esquema-conexiones.md`](../00-hardware/02-esquema-conexiones.md) §1), no usa ZFS/Btrfs (los discos van con ext4, [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md) §3), ni NFS/Infiniband. Desactivar colectores que devolverían siempre `0` reduce el `/metrics` y elimina cardinalidad muerta. |
| Usuario del contenedor | **`65534:65534`** (`nobody:nobody`, default de la imagen) | La imagen oficial `prom/node-exporter` se construye con `USER nobody`. El binario sólo necesita lectura de `/proc`, `/sys` y `/rootfs` (todos montados `ro,rslave`); no escribe en ningún sitio. **No** se sobreescribe con `${PUID}:${PGID}`. |
| `cap_drop: ALL` + `cap_add` mínimo | `cap_drop: [ALL]`, sin `cap_add` | Node Exporter sólo lee ficheros del kernel a través de bind mounts read-only y bindea `:9100` (>1024). Ningún capability necesario. **No** se añade `SYS_TIME` ni `DAC_READ_SEARCH`: los ficheros de `/proc` y `/sys` son world-readable; los pocos que no lo son (e.g. `/proc/<pid>/io`) sólo afectan al colector `processes` (desactivado). |
| `security_opt` | **`no-new-privileges:true`** | Plantilla §6 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). |
| `read_only` | **`true`** (sin `tmpfs:` adicional) | Node Exporter no escribe nada al filesystem del contenedor (ni siquiera logs: van a stdout). FS root RO sin tmpfs es la postura más restrictiva. Si en el futuro se activase `--collector.textfile` (lee de un directorio plano), habría que montar un volumen específico para esa carpeta; mientras no se use, RO total. |
| Persistencia | **Ninguna** | No hay BD, no hay caché, no hay estado. Reiniciar el contenedor pierde 0 datos del propio Node Exporter; las series temporales viven en Prometheus, que las trae a su TSDB en cada scrape. **No se crea** ningún directorio bajo `/mnt/hd2t/services/monitoring/node-exporter/`. |
| Healthcheck | **`/-/healthy`** vía `wget` busybox de la imagen | El endpoint `/-/healthy` (sin auth) responde 200 con `Node Exporter is Healthy.` cuando el proceso está vivo y el HTTP server escucha. La imagen oficial trae `wget` busybox. `start_period` corto (10 s): el binario no tiene migraciones ni warm-up significativo. |
| Logs Docker | **`json-file` 10 MB × 3** (heredado del demonio) | Plantilla §6.1 de estructura-compose. Node Exporter tiene logs muy escasos en estado estable (sólo errores ocasionales de colector); 10 MB cubren semanas. |
| Dashboards | **`Node Exporter Full` (#1860, rev 39)** + **`Raspberry Pi Monitoring` (#10578, rev 1)** | El primero es el dashboard "todo en uno" estándar del ecosistema (~80 paneles: CPU, RAM, swap, disco, red, hardware, sistema...). El segundo está adaptado a SoCs (paneles dedicados a temperatura, throttle del CPU, voltaje); en una Pi 5 ambos se complementan. Los dos vienen de Grafana.com con `${DS_PROMETHEUS}` y se post-procesan con la receta de [`./02-grafana.md`](./02-grafana.md) §6.3.2 antes de meterlos en `provisioning/dashboards/json/`. |

---

## 1. Resumen de la arquitectura

```
                ┌───────────────────────────── HOST: Pi 5 (Raspberry Pi OS) ───────────────────────────┐
                │                                                                                       │
                │   /proc/  /sys/  /  (kernel exposes CPU, RAM, hwmon, netdev, filesystems...)          │
                │      ▲       ▲      ▲                                                                 │
                │      │       │      │   bind mount (ro,rslave)                                        │
                │      │       │      │                                                                 │
                │   ┌──┼───────┼──────┼─────────── docker network: homelab (172.20.0.0/24) ───────────┐ │
                │   │  │       │      │                                                                │ │
                │   │  │ /host/proc   /host/sys   /rootfs                                              │ │
                │   │  │ ▲              ▲           ▲                                                  │ │
                │   │  │ │              │           │                                                  │ │
                │   │  │ │     ┌────────┴───────────┴──────── node-exporter ──────────────┐            │ │
                │   │  │ │     │ image: prom/node-exporter:v1.8.2                          │            │ │
                │   │  │ │     │ user: 65534:65534 (nobody)                                │            │ │
                │   │  │ │     │ networks: [homelab]                                       │            │ │
                │   │  │ │     │ ports: -                                                  │            │ │
                │   │  │ │     │ flags:                                                    │            │ │
                │   │  │ │     │   --path.procfs=/host/proc                                │            │ │
                │   │  │ │     │   --path.sysfs=/host/sys                                  │            │ │
                │   │  │ │     │   --path.rootfs=/rootfs                                   │            │ │
                │   │  │ │     │   --collector.netclass.netlink                            │            │ │
                │   │  │ │     │   --no-collector.wifi --no-collector.zfs ...              │            │ │
                │   │  │ │     │ /metrics  (HTTP plano, sin auth, :9100)                   │            │ │
                │   │  │ │     └─────▲─────────────────────────────────────────────────────┘            │ │
                │   │  │ │           │                                                                  │ │
                │   │  │ │           │  scrape_interval: 30s                                            │ │
                │   │  │ │           │  GET http://node-exporter:9100/metrics                          │ │
                │   │  │ │           │                                                                  │ │
                │   │  │ │     ┌─────┴─────────── prometheus ───────────────────┐                       │ │
                │   │  │ │     │ job_name: 'node-exporter'                       │                       │ │
                │   │  │ │     │ targets: [node-exporter:9100]                   │                       │ │
                │   │  │ │     │ labels: { service: node-exporter, instance:... }│                       │ │
                │   │  │ │     └─────┬─────────────────────────────────────────┘                        │ │
                │   │  │ │           │                                                                  │ │
                │   │  │ │           │  TSDB local en /mnt/hd2t/.../prometheus/data/                   │ │
                │   │  │ │           │                                                                  │ │
                │   │  │ │     ┌─────▼─────────── grafana ───────────────────────┐                      │ │
                │   │  │ │     │ datasource: Prometheus (uid=prometheus)         │                      │ │
                │   │  │ │     │ dashboards (provisioned, JSON):                  │                      │ │
                │   │  │ │     │   - Node Exporter Full (#1860)                  │                      │ │
                │   │  │ │     │   - Raspberry Pi Monitoring (#10578)            │                      │ │
                │   │  │ │     └──────────────────────────────────────────────────┘                      │ │
                │   │  │ │                                                                                │ │
                │   │  └──┴────────────────────────────────────────────────────────────────────────────┘ │
                │                                                                                       │
                └───────────────────────────────────────────────────────────────────────────────────────┘
```

Tres invariantes:

- **Node Exporter sólo es accesible desde la red `homelab`.** No hay `ports:` al host, no hay reverse-proxy, no hay TLS ni auth. Su `/metrics` es información operacional sensible (kernel, IPs, hostname, FS) y queda a un network-namespace de distancia de cualquier cliente del LAN.
- **El proceso es stateless.** Reiniciar, recrear o borrar el contenedor pierde 0 datos. Las métricas se reconstruyen al siguiente scrape leyendo `/proc` y `/sys`.
- **El agente lee el host, no el contenedor.** Los flags `--path.procfs`, `--path.sysfs` y `--path.rootfs` redirigen las lecturas a los bind mounts del host. Cuando un dashboard dice "CPU del nodo", se está midiendo la Pi 5, no los 4 cores virtuales que vería el contenedor por defecto.

Flujo de un scrape:

```
1. Prometheus consulta su prometheus.yml: job 'node-exporter' / target 'node-exporter:9100'.
2. cada 30 s: HTTP GET http://node-exporter:9100/metrics  (DNS interno de homelab).
3. node-exporter, en el handler /metrics, recorre cada colector activo:
       - cpu:        lee /host/proc/stat       -> node_cpu_seconds_total{cpu, mode}
       - meminfo:    lee /host/proc/meminfo    -> node_memory_*_bytes
       - netdev:     lee /host/proc/net/dev    -> node_network_*_bytes_total{device}
       - hwmon:      lee /host/sys/class/hwmon -> node_hwmon_temp_celsius{chip, sensor}
       - filesystem: stat sobre /rootfs        -> node_filesystem_*_bytes{mountpoint, fstype}
       - ...
4. Devuelve un texto plano de ~5–10 KB con ~600–900 series (defaults).
5. Prometheus parsea, etiqueta con (job, instance, scrape_pool), y escribe al TSDB.
6. Grafana, en el siguiente refresh del dashboard, ejecuta PromQL contra el TSDB.
```

---

## 2. Plan de variables y archivos

El stack `monitoring` ya existe; este doc **extiende** los ficheros que dejaron Prometheus y Grafana. Estado del repo después de este doc:

```
~/homelab/stacks/monitoring/             # versionable en git
├── docker-compose.yml                   # +bloque `node-exporter:`
├── .env.example                         # +sección Node Exporter
├── prometheus.yml                       # job 'node-exporter' DESCOMENTADO
└── grafana/
    ├── grafana.ini                       # sin cambios
    └── provisioning/
        ├── datasources/prometheus.yml    # sin cambios
        └── dashboards/
            ├── default.yml               # sin cambios
            └── json/
                ├── prometheus-stats.json
                ├── node-exporter-full.json   # NUEVO (Grafana.com #1860)
                └── rpi-monitoring.json       # NUEVO (Grafana.com #10578)

/mnt/hd2t/services/monitoring/           # datos persistentes, NO en git
├── .env                                  # +sección Node Exporter
├── prometheus/data/                      # sin cambios
└── grafana/data/                         # sin cambios

# (NO se crea /mnt/hd2t/services/monitoring/node-exporter/: el agente es stateless.)
```

### 2.1. Variables del stack — extender `.env.example`

Editar `~/homelab/stacks/monitoring/.env.example` (creado por [`./01-prometheus.md`](./01-prometheus.md) §2.1, ampliado por [`./02-grafana.md`](./02-grafana.md) §2.1) y **descomentar/rellenar** la sección Node Exporter:

```dotenv
# ~/homelab/stacks/monitoring/.env.example
# Versión control: ~/homelab/stacks/monitoring/.env.example
# Valores reales en /mnt/hd2t/services/monitoring/.env (chmod 600).

# --- Comunes del homelab ---
PUID=1000
PGID=1000
TZ=Europe/Madrid

# --- Dominios internos ---
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Prometheus (./01-prometheus.md) ---
PROMETHEUS_IMAGE_TAG=v2.55.1
PROMETHEUS_HOSTNAME=prometheus.lan
PROMETHEUS_RETENTION_TIME=30d
PROMETHEUS_RETENTION_SIZE=5GB

# --- Grafana (./02-grafana.md) ---
GRAFANA_IMAGE_TAG=11.4.0
GRAFANA_HOSTNAME=grafana.lan
GRAFANA_ADMIN_PASSWORD=changeme-ver-el-env-real
GRAFANA_AUTH_PROXY_WHITELIST=172.20.0.0/24

# --- Node Exporter (./03-node-exporter.md) ---
# https://hub.docker.com/r/prom/node-exporter/tags
# CHANGELOG: https://github.com/prometheus/node_exporter/blob/master/CHANGELOG.md
NODE_EXPORTER_IMAGE_TAG=v1.8.2

# (Reservado para los siguientes docs de Fase 5; se rellenarán cuando toquen)
# CADVISOR_IMAGE_TAG=
# UPTIME_KUMA_IMAGE_TAG=
# DOZZLE_IMAGE_TAG=
```

### 2.2. Extender el `.env` real (`/mnt/hd2t/services/monitoring/.env`)

```bash
# Añadir las nuevas líneas al .env (sin tocar las existentes de Prometheus/Grafana):
sudo tee -a /mnt/hd2t/services/monitoring/.env >/dev/null <<'EOF'

# --- Node Exporter (./03-node-exporter.md) ---
NODE_EXPORTER_IMAGE_TAG=v1.8.2
EOF

# Comprobar permisos (deben seguir siendo 600):
ls -l /mnt/hd2t/services/monitoring/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

> **No hay secretos** en la sección Node Exporter: ni passwords, ni tokens, ni TLS configurada. La única variable es la versión de la imagen.

---

## 3. Preparar el host

### 3.1. Limpieza del directorio del esquema antiguo

El bootstrap original ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6.6) creó `/mnt/hd2t/services/node-exporter/` siguiendo el esquema "un dir por servicio" que el plan ha sustituido por "un dir por stack". Node Exporter **no necesita** ningún directorio de datos porque no escribe nada al filesystem; el directorio queda huérfano y se elimina:

```bash
# Confirmar que está vacío:
ls -la /mnt/hd2t/services/node-exporter/ 2>/dev/null
# Esperado: . y .. solamente; cualquier otra cosa indicaría un experimento
# previo que conviene revisar antes de borrar.

sudo rmdir /mnt/hd2t/services/node-exporter 2>/dev/null || true
# El rmdir falla silenciosamente si el directorio no existe; ambos casos OK.
```

> **No se crea** `/mnt/hd2t/services/monitoring/node-exporter/`: a diferencia de Prometheus (TSDB en `prometheus/data/`) y Grafana (`grafana.db` en `grafana/data/`), Node Exporter no escribe nada al disco. Crear un directorio vacío sólo añadiría ruido al árbol y a Borgmatic.

### 3.2. Verificar que `/proc`, `/sys` y `/` son legibles

```bash
# /proc: world-readable por defecto
test -r /proc/stat && test -r /proc/meminfo && test -r /proc/net/dev && echo "/proc OK"

# /sys: world-readable; /sys/class/hwmon es la fuente de la temperatura
test -d /sys/class/hwmon && ls /sys/class/hwmon/ && echo "/sys OK"

# /: el FS raíz de Raspberry Pi OS
test -r / && stat / && echo "/ OK"
```

Esperado (Pi 5 con Raspberry Pi OS):

```
/proc OK
hwmon0  hwmon1  hwmon2     # tres sensores típicos en Pi 5: CPU, ext_temp, etc.
/sys OK
/ OK
```

> Si `/sys/class/hwmon` está vacío, el kernel no ha cargado los drivers del SoC: revisar `/boot/firmware/config.txt` (típico ya cubierto por Raspberry Pi OS de fábrica) o `dmesg | grep -i thermal`. Sin `hwmon`, los paneles de temperatura del dashboard 1860 quedan vacíos pero el resto funciona.

### 3.3. Permisos para el proceso del contenedor

Node Exporter corre como UID 65534 (`nobody`) por defecto. Los bind mounts de `/proc`, `/sys` y `/` se montan **read-only** (`ro,rslave`); aunque algún sub-path tuviera permisos restrictivos para `nobody`, los colectores que dependen de él se silencian (loggean error en stdout y siguen). El homelab no cambia ningún permiso del host; los defaults de Raspberry Pi OS son los correctos.

> **No se añade** el usuario `homelab` al grupo `nogroup` ni se altera el ownership de `/proc`, `/sys` o `/`. Cualquier modificación de estos paths en el host afectaría a procesos del sistema y rompería invariantes muy básicas.

---

## 4. Activar el `scrape_config` en `prometheus.yml`

`~/homelab/stacks/monitoring/prometheus.yml` (creado por [`./01-prometheus.md`](./01-prometheus.md) §4) ya contiene el placeholder del job de Node Exporter, comentado y con un puntero a este doc:

```yaml
  # ----- Node Exporter (./03-node-exporter.md) --------------------------------
  # Métricas del host (CPU, RAM, disco, red, temperatura). ACTIVAR cuando el
  # doc Node Exporter despliegue el contenedor `node-exporter` en el stack.
  #
  # - job_name: 'node-exporter'
  #   static_configs:
  #     - targets: ['node-exporter:9100']
  #       labels:
  #         service: node-exporter
```

### 4.1. Descomentar el bloque

Editar `~/homelab/stacks/monitoring/prometheus.yml` y sustituir el bloque de placeholder por:

```yaml
  # ----- Node Exporter (./03-node-exporter.md) --------------------------------
  # Métricas del host (CPU, RAM, disco, red, temperatura). ACTIVO desde el
  # despliegue del contenedor en docs/05-monitorizacion/03-node-exporter.md §5.
  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']
        labels:
          service: node-exporter
```

> **No** se baja `scrape_interval` por debajo del global (30 s). Algunos guides recomiendan 15 s para "ver" los picos de temperatura del SoC; en una Pi 5 con disipación pasiva, el termal time constant es del orden de minutos, así que 30 s sobra. Si en el futuro se conecta una carga de transcoding intensa, se considera bajar el `scrape_interval` específicamente para este job (manteniéndolo a 30 s para los demás).

### 4.2. Validar la sintaxis sin reiniciar

```bash
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
# Esperado:
#   Checking /etc/prometheus/prometheus.yml
#     SUCCESS: 1 rule files found
#   ... (sin warnings)
```

### 4.3. Aplicar sin downtime (POST /-/reload)

```bash
docker exec caddy wget -q --post-data='' -O- http://prometheus:9090/-/reload
# Esperado: salida vacía y exit code 0.

# Confirmar que el job aparece en la config corriente:
docker exec caddy wget -qO- http://prometheus:9090/api/v1/status/config \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["yaml"])' \
  | grep -A2 "job_name: node-exporter"
# Esperado:
#   - job_name: node-exporter
#     ...
```

> El target aparecerá en `https://prometheus.lan/targets` como **DOWN** (`connection refused`) hasta que el contenedor `node-exporter` esté levantado en §5. Es lo esperado.

---

## 5. `docker-compose.yml`

Editar `~/homelab/stacks/monitoring/docker-compose.yml` (extendido por [`./01-prometheus.md`](./01-prometheus.md) §5 y [`./02-grafana.md`](./02-grafana.md) §7) y **añadir** el bloque `node-exporter:` debajo del bloque `grafana:`. **No** se toca el bloque `prometheus:`, ni el bloque `grafana:`, ni el bloque `networks:`.

```yaml
# ~/homelab/stacks/monitoring/docker-compose.yml
# Stack: monitoring (../02-docker/02-estructura-compose.md §1.1).
#
# Estado tras este doc: tres servicios (`prometheus`, `grafana`, `node-exporter`).
# Los siguientes docs de Fase 5 (./04-cadvisor.md, ./05-uptime-kuma.md,
# ./06-dozzle.md) añadirán cada uno su servicio sin tocar los existentes.

name: monitoring

services:
  prometheus:
    # ... bloque sin cambios; ver ./01-prometheus.md §5 ...

  grafana:
    # ... bloque sin cambios; ver ./02-grafana.md §7 ...

  node-exporter:
    image: prom/node-exporter:${NODE_EXPORTER_IMAGE_TAG}
    container_name: node-exporter
    hostname: node-exporter
    restart: unless-stopped

    # Imagen oficial: USER nobody (UID 65534). El contenedor sólo LEE de
    # /host/proc, /host/sys y /rootfs (ro,rslave); no escribe nada.

    # No depende de Prometheus para arrancar: si Prometheus está caído,
    # node-exporter sigue sirviendo /metrics; el agujero queda en el TSDB.
    # No depends_on.

    env_file:
      - /mnt/hd2t/services/monitoring/.env
    environment:
      TZ: ${TZ}

    command:
      # Paths re-mapeados a los bind mounts del host.
      - "--path.procfs=/host/proc"
      - "--path.sysfs=/host/sys"
      - "--path.rootfs=/rootfs"

      # Filesystem: filtrar mountpoints y tipos de FS sintéticos / del propio
      # contenedor para que el dashboard 1860 sólo muestre los discos reales.
      - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc|rootfs/(sys|proc|dev|host|etc))($$|/)"
      - "--collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup|cgroup2|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$$"

      # Netclass por Netlink (más rápido que parsear /sys/class/net/).
      - "--collector.netclass.netlink"

      # Colectores que NO aplican al hardware del homelab — desactivarlos para
      # no engordar /metrics con métricas que valen siempre 0.
      - "--no-collector.wifi"          # Pi 5 va por Ethernet (00-hardware/02).
      - "--no-collector.zfs"           # discos en ext4 (00-hardware/03).
      - "--no-collector.btrfs"         # idem.
      - "--no-collector.infiniband"    # no aplica.
      - "--no-collector.nfs"           # no se monta NFS.
      - "--no-collector.nfsd"          # idem (lado servidor).
      - "--no-collector.ipvs"          # sin balanceador IPVS.
      - "--no-collector.mdadm"         # sin RAID software (los discos van solos).
      - "--no-collector.xfs"           # ext4, no XFS.

      # Logs.
      - "--log.level=info"
      - "--log.format=logfmt"

    volumes:
      # Bind mounts read-only del host (receta canónica upstream).
      - type: bind
        source: /proc
        target: /host/proc
        read_only: true
        bind:
          create_host_path: false
          propagation: rslave

      - type: bind
        source: /sys
        target: /host/sys
        read_only: true
        bind:
          create_host_path: false
          propagation: rslave

      - type: bind
        source: /
        target: /rootfs
        read_only: true
        bind:
          create_host_path: false
          propagation: rslave

    read_only: true

    networks:
      - homelab

    cap_drop:
      - ALL

    security_opt:
      - no-new-privileges:true

    # NO pid: host  (no se necesita; --collector.processes está desactivado).

    healthcheck:
      # /-/healthy responde 200 con "Node Exporter is Healthy." cuando el
      # binario está vivo y el HTTP server escucha en 9100.
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:9100/-/healthy"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

    labels:
      com.centurylinklabs.watchtower.enable: "true"
      # NO labels homepage.*: Node Exporter no tiene UI; el operador
      # interactúa con sus métricas vía Grafana.

networks:
  homelab:
    external: true
```

### 5.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `image: prom/node-exporter:${NODE_EXPORTER_IMAGE_TAG}` | Tag fijo desde el `.env`. Multi-arch oficial (incluye `linux/arm64`). |
| `container_name: node-exporter` / `hostname: node-exporter` | Prometheus llama a `http://node-exporter:9100` por nombre Docker (placeholder ya configurado en `prometheus.yml`). Sin `container_name` el nombre real sería `monitoring-node-exporter-1`. |
| (sin `user:`) | La imagen oficial fija `USER nobody` (UID 65534). El binario sólo lee bind mounts ro; no necesita más. |
| (sin `depends_on:`) | Node Exporter es deliberadamente desacoplado de Prometheus: arranca incluso si Prometheus está parado. Si Prometheus arranca después, simplemente reanuda los scrapes y el TSDB tendrá un gap acotado. |
| `env_file` ruta absoluta | Plantilla §6 de estructura-compose. Coherente con el resto del stack. |
| `command: --path.procfs=/host/proc` etc. | Sin estos flags, el binario leería `/proc` y `/sys` del namespace del contenedor (no del host) y reportaría métricas absurdas (1 PID, 0 hwmon, 1 interfaz `eth0` del bridge). |
| `command: --collector.filesystem.mount-points-exclude` | Cubre los puntos de montaje sintéticos (`/sys`, `/proc`, ...) y los del bind mount del propio contenedor (`/host/...`, `/rootfs/sys`, etc.). El default upstream es similar pero no incluye `/host` y `/rootfs/...`. |
| `command: --collector.filesystem.fs-types-exclude` | Filtra FS no representativos de almacenamiento real (cgroup, sysfs, overlay, tmpfs implícitos). El panel "Disk Space Used" del dashboard 1860 queda con los 3 FS reales: `/`, `/mnt/hd5t`, `/mnt/hd2t` (más `/boot/firmware` en una Pi). |
| `command: --collector.netclass.netlink` | Netlink en lugar de leer `/sys/class/net/<dev>/`: más rápido y sin race conditions cuando una interfaz aparece/desaparece. Coste cero. |
| `command: --no-collector.wifi`, ZFS, Btrfs, etc. | Cada colector no aplicable que sigue corriendo emite series con valor `0` que ocupan espacio en el TSDB y aparecen en autocompletes de PromQL. Desactivarlos limpia el namespace. Justificado en la tabla §0. |
| `volumes: /proc:/host/proc:ro,rslave` | El `:ro` impide cualquier escritura accidental. `rslave` propaga unmounts del host al contenedor (si se desmonta `hd2t`, Node Exporter ya no lo ve y reporta el cambio en el siguiente scrape). |
| `volumes: /sys:/host/sys:ro,rslave` | Idem. Crítico para `hwmon` (temperatura) y `--collector.netclass.netlink` (que aún consulta `/sys/class/net/<iface>/...` para metadatos). |
| `volumes: /:/rootfs:ro,rslave` | El colector `filesystem` enumera mountpoints abriendo el FS raíz del host. Sin esto, vería los del contenedor. `ro,rslave` mantiene la lectura segura. |
| `read_only: true` (sin tmpfs) | Node Exporter no escribe nada (ni siquiera `/tmp` lo usa en defaults). FS root RO total es la postura más restrictiva posible. Si en el futuro se activase `--collector.textfile`, habría que añadir un tmpfs/bind para ese directorio. |
| `networks: [homelab]` | Único networking. Resuelve `prometheus` por DNS interno del bridge. No se usa `network_mode: host` (justificado en la tabla §0). |
| `cap_drop: ALL` (sin `cap_add`) | Sin capabilities especiales. Las lecturas de `/proc` y `/sys` que los colectores activos requieren son world-readable. |
| `security_opt: no-new-privileges:true` | Plantilla §6. |
| (sin `pid: host`) | Default colectores no necesitan ver PIDs del host. Mantenerlo aislado es una victoria gratuita de superficie. |
| `healthcheck: /-/healthy` | El endpoint `/-/healthy` no requiere auth y responde 200 con un texto fijo. La imagen oficial trae `wget` busybox. `start_period` de sólo 10 s: el binario arranca en milisegundos. |
| `labels.watchtower.enable=true` | Justificado en la tabla §0. Patches de la rama 1.x son seguros. |
| (sin `labels.homepage.*`) | Node Exporter no tiene UI. Homepage no debe listarlo: enlazar a `/metrics` desde la home sería ruido para el operador. |

### 5.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/monitoring

# Validar sintaxis del compose:
docker compose --env-file /mnt/hd2t/services/monitoring/.env config >/dev/null \
  && echo "Compose OK"

# Inspeccionar los bind mounts que aplicará:
docker compose --env-file /mnt/hd2t/services/monitoring/.env config \
  | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
ne = d["services"]["node-exporter"]
print("VOLUMES:")
for v in ne.get("volumes", []):
    print(" -", v)
print("READ_ONLY:", ne.get("read_only"))
print("CAP_DROP:", ne.get("cap_drop"))
'
# Esperado: 3 bind mounts (/proc, /sys, /), read_only=True, cap_drop=[ALL].
```

> Si el compose validate emite "warning: variable not set", revisar el `.env` y `.env.example`: la variable `NODE_EXPORTER_IMAGE_TAG` debe existir en `/mnt/hd2t/services/monitoring/.env`.

---

## 6. Despliegue

### 6.1. Levantar el contenedor

```bash
cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d node-exporter
```

Salida esperada:

```
[+] Running 1/1
 ✔ Container node-exporter  Started
```

> **Sólo se levanta `node-exporter`** (`up -d node-exporter`): los servicios `prometheus` y `grafana` ya están corriendo y no necesitan recreate. Si por algún motivo `up -d` solo (sin nombre) recrea otros servicios, revisar que los bloques antiguos no se hayan modificado por accidente.

### 6.2. Estado del contenedor

```bash
docker compose ps node-exporter
# Esperado:
# NAME             IMAGE                          STATUS                  PORTS
# node-exporter    prom/node-exporter:v1.8.2      Up X (healthy)
```

Si tarda en `(healthy)` o entra en `(unhealthy)`:

```bash
docker compose logs node-exporter | tail -50
```

Eventos esperados en los logs:

```
ts=... caller=node_exporter.go:... level=info msg="Starting node_exporter" version="(version=1.8.2, ...)"
ts=... caller=node_exporter.go:... level=info msg="Operational information"
ts=... caller=node_exporter.go:... level=info msg="Listening on" address=:9100
ts=... caller=tls_config.go:... level=info msg="TLS is disabled." http2=false
```

> Si aparecen warnings tipo `error reading /host/sys/...`: algunos sub-colectores intentan leer paths que no existen en kernels concretos (e.g. `arp`, `bonding`, `infiniband` en Pi). Si el colector está activo, loggea y sigue; si está en `--no-collector.<x>`, ni se intenta. Los warnings residuales se silencian añadiendo `--no-collector.<nombre>` al `command`.

### 6.3. Smoke test desde la red `homelab`

```bash
# Cualquier contenedor en homelab puede alcanzar node-exporter por nombre Docker.
# Usar caddy o prometheus indistintamente:
docker exec prometheus wget -qO- http://node-exporter:9100/-/healthy
# Esperado: Node Exporter is Healthy.

# Listado de colectores activos:
docker exec prometheus wget -qO- http://node-exporter:9100/-/healthy >/dev/null && \
docker exec prometheus wget -qO- http://node-exporter:9100/metrics \
  | grep -E '^# HELP node_scrape_collector_success' \
  | head
# Esperado: una entrada `node_scrape_collector_success{collector="..."}` por
# cada colector activo (cpu, meminfo, hwmon, filesystem, netdev, ...).

# Algunas métricas clave:
docker exec prometheus wget -qO- http://node-exporter:9100/metrics \
  | grep -E '^node_(boot_time|memory_MemTotal_bytes|hwmon_temp_celsius)' \
  | head
# Esperado:
#   node_boot_time_seconds 1.71...e+09
#   node_memory_MemTotal_bytes 8.21...e+09     (~8 GB en Pi 5 8GB)
#   node_hwmon_temp_celsius{chip="...",sensor="..."} 45.7
```

### 6.4. Smoke test desde el host

```bash
# Node Exporter NO debe ser alcanzable desde la IP del host:
curl -sf http://192.168.1.10:9100/-/healthy -m 2 ; echo "exit=$?"
# Esperado: exit=7 (connection refused) o exit=28 (timeout). Nunca 200.

docker port node-exporter
# Esperado: vacío (sin port mappings).
```

### 6.5. El target aparece UP en Prometheus

```
https://prometheus.lan/targets
```

Esperado: una nueva fila para el job `node-exporter`, target `node-exporter:9100`, estado **UP** (verde), `Last Scrape` reciente, `Scrape Duration` < 100 ms.

Por API:

```bash
docker exec caddy wget -qO- 'http://prometheus:9090/api/v1/query?query=up{job="node-exporter"}' \
  | python3 -m json.tool
# Esperado: una serie con value=1 y labels { job="node-exporter", instance="node-exporter:9100", service="node-exporter", ... }.
```

---

## 7. Provisioning de dashboards en Grafana

### 7.1. Node Exporter Full (Grafana.com #1860)

#### 7.1.1. Descargar el JSON

```bash
cd ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json

# revision=39 es la última al momento de escribir este doc.
# Revisar: https://grafana.com/grafana/dashboards/1860-node-exporter-full/
curl -fsSL \
  "https://grafana.com/api/dashboards/1860/revisions/39/download" \
  -o node-exporter-full.json

# Verificar que es un JSON válido:
python3 -c 'import json; d=json.load(open("node-exporter-full.json")); print("title:", d.get("title")); print("panels:", len(d.get("panels", [])))'
# Esperado:
#   title: Node Exporter Full
#   panels: ~25 (muchas filas con sub-paneles)
```

#### 7.1.2. Apuntar el JSON al UID `prometheus`

Igual que en [`./02-grafana.md`](./02-grafana.md) §6.3.2: sustituir `${DS_PROMETHEUS}` por el UID estable del datasource (`prometheus`) y limpiar las claves `__inputs/__elements/__requires` (incompatibles con provisioning):

```bash
cd ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json

# 1. Sustituir el placeholder:
sed -i 's/"\${DS_PROMETHEUS}"/"prometheus"/g' node-exporter-full.json

# 2. Eliminar __inputs/__elements/__requires:
python3 - <<'PY'
import json
p = "node-exporter-full.json"
d = json.load(open(p))
for k in ("__inputs", "__elements", "__requires"):
    d.pop(k, None)
json.dump(d, open(p, "w"), indent=2)
print("Cleaned:", p)
PY

# 3. Comprobación: no debe quedar ningún ${DS_*}:
grep -c '${DS_' node-exporter-full.json
# Esperado: 0
```

### 7.2. Raspberry Pi Monitoring (Grafana.com #10578)

Complementa #1860 con paneles dedicados a SoC: temperatura del CPU, throttle, voltaje. La revisión 1 funciona con Node Exporter "puro" (sin necesidad del exporter `rpi_exporter` específico).

```bash
cd ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json

# revision=1 es la única publicada.
# Revisar: https://grafana.com/grafana/dashboards/10578-rpi-monitoring/
curl -fsSL \
  "https://grafana.com/api/dashboards/10578/revisions/1/download" \
  -o rpi-monitoring.json

# Mismo post-procesado que en §7.1.2:
sed -i 's/"\${DS_PROMETHEUS}"/"prometheus"/g' rpi-monitoring.json

python3 - <<'PY'
import json
p = "rpi-monitoring.json"
d = json.load(open(p))
for k in ("__inputs", "__elements", "__requires"):
    d.pop(k, None)
json.dump(d, open(p, "w"), indent=2)
print("Cleaned:", p)
PY

grep -c '${DS_' rpi-monitoring.json
# Esperado: 0
```

> Algunos paneles del dashboard 10578 asumen una métrica de throttle específica del SoC (`node_thermal_zone_temp` o métricas custom). En una Pi 5 vanilla, esos paneles aparecerán en gris ("No data"); el resto sí renderiza. No es un fallo crítico — el dashboard 1860 ya cubre lo esencial.

### 7.3. Verificar que Grafana los ha cargado

Grafana releé el directorio `provisioning/dashboards/json/` cada 30 s ([`./02-grafana.md`](./02-grafana.md) §6.1, `updateIntervalSeconds: 30`). Tras esperar ~30 s desde que se dejó el JSON:

```bash
docker logs grafana --since 1m 2>&1 | grep -iE 'provisioning|dashboard' | tail
# Esperado: líneas tipo
#   logger=provisioning.dashboard.fileReader t=... level=info msg="finished to provision dashboards"
```

En la UI:

```
https://grafana.lan/dashboards
```

- Debe aparecer "Node Exporter Full" en la lista (con icono de candado provisioned).
- Debe aparecer "Raspberry Pi Monitoring" en la lista (con icono de candado provisioned).

---

## 8. Verificación

### 8.1. Contenedor sano

```bash
docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml ps node-exporter
# STATUS: "Up X (healthy)".
```

### 8.2. Node Exporter no escucha en el host

```bash
sudo ss -ltn | awk '$4 ~ /:9100$/'
# Esperado: vacío (no se publica al host).

docker port node-exporter
# Esperado: vacío.
```

### 8.3. `/metrics` responde y tiene las métricas esperadas

```bash
# Tamaño del payload (~5–10 KB con los defaults filtrados):
docker exec prometheus wget -qO- http://node-exporter:9100/metrics | wc -c
# Esperado: 5000–15000 (varía con número de FS, interfaces, hwmon).

# Familias de métricas presentes:
docker exec prometheus wget -qO- http://node-exporter:9100/metrics \
  | grep -E '^# HELP node_(cpu|memory|network|filesystem|hwmon|load|boot|uname)' \
  | wc -l
# Esperado: >= 8 (cpu, memory, network, filesystem, hwmon, load1, boot_time, uname_info).

# Familias que deberían NO estar (colectores desactivados):
docker exec prometheus wget -qO- http://node-exporter:9100/metrics \
  | grep -E '^node_(wifi|zfs|btrfs|nfs|nfsd)_' \
  | wc -l
# Esperado: 0.
```

### 8.4. Las métricas reflejan el HOST, no el contenedor

```bash
# 1. Boot time del host:
HOST_BOOT=$(awk '/btime/ {print $2}' /proc/stat)
NE_BOOT=$(docker exec prometheus wget -qO- http://node-exporter:9100/metrics \
          | awk '/^node_boot_time_seconds/ {print int($2)}')
echo "Host: $HOST_BOOT  /  Node Exporter: $NE_BOOT"
# Deben coincidir.

# 2. Memoria total: la Pi 5 8GB declara ~8.2 * 10^9 bytes en /proc/meminfo:
HOST_MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
NE_MEM=$(docker exec prometheus wget -qO- http://node-exporter:9100/metrics \
         | awk '/^node_memory_MemTotal_bytes/ {print int($2)}')
echo "Host: $((HOST_MEM_KB * 1024))  /  Node Exporter: $NE_MEM"
# Deben coincidir (mismo valor, en bytes).

# 3. La interfaz Ethernet eth0 del host está reportada (no la del contenedor):
docker exec prometheus wget -qO- http://node-exporter:9100/metrics \
  | grep -E 'node_network_info{.*device="eth0"'
# Esperado: una línea con address="<MAC del host>" (no la MAC del bridge Docker).
```

### 8.5. Temperatura del SoC presente

```bash
docker exec prometheus wget -qO- http://node-exporter:9100/metrics \
  | grep -E '^node_hwmon_temp_celsius'
# Esperado: al menos una serie con valor numérico (e.g. 42.5 a 60.0 ºC).

# Equivalente desde el host (debe coincidir o estar muy cerca):
cat /sys/class/thermal/thermal_zone0/temp
# (Valor en milidegrees: 42500 = 42.5 ºC.)
```

> Si `node_hwmon_temp_celsius` no aparece, el colector `hwmon` no encontró sensores en `/host/sys/class/hwmon`. Causas: bind mount mal configurado (revisar §5), o el kernel no exporta los sensores (improbable en RPi OS reciente).

### 8.6. El job aparece UP en Prometheus

```bash
# Vía API:
docker exec caddy wget -qO- 'http://prometheus:9090/api/v1/query?query=up{job="node-exporter"}' \
  | python3 -m json.tool
# Esperado: { "status":"success", "data": {"result": [{"metric": {..., "job":"node-exporter", "instance":"node-exporter:9100", ...}, "value": [..., "1"]}]} }

# Vía UI: https://prometheus.lan/targets → fila node-exporter → UP (verde).
```

### 8.7. Los dashboards renderizan en Grafana

En `https://grafana.lan/dashboards`, abrir:

- **Node Exporter Full**: las filas "Quick CPU / Mem / Disk", "Basic CPU / Mem / Net / Disk", "CPU / Memory / Net / Disk" deben mostrar valores. La fila "Hardware temperature" muestra ~40–60 ºC.
- **Raspberry Pi Monitoring**: paneles de CPU, RAM, temperatura, network. Algunos paneles específicos (throttle por bits) pueden aparecer vacíos en una Pi 5 (los bits exactos son específicos de Pi 4 firmware).

Si un panel concreto muestra "No data":

- Click sobre el panel → **Inspect → Query** → ver la query PromQL.
- Pegarla en `https://prometheus.lan/graph` para confirmar si la métrica existe.
- Si la métrica no existe, suele ser que el colector está desactivado en la lista de §5 (raro para los datos que esperan los dashboards 1860/10578).

### 8.8. Persistencia tras reboot

```bash
sudo reboot
# (esperar a que vuelva)

docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml ps node-exporter
# Esperado: node-exporter (healthy).

# El TSDB de Prometheus debe mostrar continuidad de la serie node_boot_time_seconds:
# en https://prometheus.lan/graph la query `node_boot_time_seconds` devuelve
# un nuevo valor (más reciente) tras el reboot, y `up{job="node-exporter"}[1h]`
# muestra el hueco del downtime.
```

### 8.9. Lista de Verificación

Antes de pasar a [`./04-cadvisor.md`](./04-cadvisor.md):

- [ ] `docker compose ps node-exporter` → `Up X (healthy)`.
- [ ] `sudo ss -ltn | grep -E ':9100'` → vacío en el host.
- [ ] `docker exec prometheus wget -qO- http://node-exporter:9100/-/healthy` devuelve `Node Exporter is Healthy.`.
- [ ] `node_memory_MemTotal_bytes` coincide con `MemTotal` de `/proc/meminfo`.
- [ ] `node_boot_time_seconds` coincide con `btime` de `/proc/stat`.
- [ ] `node_hwmon_temp_celsius` devuelve un valor numérico (~40–60 ºC).
- [ ] `https://prometheus.lan/targets` → fila `node-exporter` en estado **UP**.
- [ ] PromQL `up{job="node-exporter"}` devuelve `1` con etiquetas `cluster=homelab, host=pi5, service=node-exporter`.
- [ ] El bloque `node-exporter:` está en `~/homelab/stacks/monitoring/docker-compose.yml`; el `scrape_config` `node-exporter` está descomentado en `~/homelab/stacks/monitoring/prometheus.yml`; ambos versionados en git.
- [ ] `~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/{node-exporter-full,rpi-monitoring}.json` versionados en git.
- [ ] En `https://grafana.lan/dashboards` aparecen "Node Exporter Full" y "Raspberry Pi Monitoring", con paneles renderizando.
- [ ] Tras `sudo reboot`, el contenedor arranca y las series tienen continuidad (con el hueco esperado del downtime).

---

## 9. Backup

| Ruta | Qué contiene | Frecuencia |
|---|---|---|
| `~/homelab/stacks/monitoring/docker-compose.yml` (bloque `node-exporter:`) | Definición del servicio. | Versionado en git → `git push`. |
| `~/homelab/stacks/monitoring/prometheus.yml` (job `node-exporter`) | Scrape config. | Versionado en git. |
| `~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/{node-exporter-full,rpi-monitoring}.json` | Dashboards provisioned. | Versionado en git. |
| `/mnt/hd2t/services/monitoring/.env` (variable `NODE_EXPORTER_IMAGE_TAG`) | Tag de imagen pinneado. | Borg con cifrado en repo (junto al resto de variables del stack, [`./01-prometheus.md`](./01-prometheus.md) §9). |
| Estado del contenedor | (no aplica) | **Sin backup**. Node Exporter es stateless por diseño: no hay BD, no hay caché, no hay sesiones. Las métricas históricas viven en el TSDB de Prometheus, ya respaldado en [`./01-prometheus.md`](./01-prometheus.md) §9. |

> **Sin restore especial**: tras pérdida total, basta con `git clone` del repo de stacks + `docker compose up -d node-exporter`. El primer scrape (≤30 s después de levantar) repobla las series en el TSDB de Prometheus y los dashboards de Grafana muestran datos en cuanto hay 2 puntos.

---

## 10. Operaciones cotidianas

### 10.1. Activar un colector adicional

Por defecto Node Exporter activa ~30 colectores; algunos útiles que el homelab no enciende:

| Colector | Activarlo añade | Coste | Cuándo activarlo |
|---|---|---|---|
| `--collector.processes` | `node_processes_*` (estados R/S/D/Z, threads, max_processes). | **Requiere `pid: host`**. Cardinalidad media. | Si se sospecha de "fork bombs" o se quiere ver el número de threads del homelab. |
| `--collector.systemd` | `node_systemd_unit_state{name=...}` (estado de cada unit del host). | Requiere DBus socket bindeado al contenedor. Cardinalidad alta (una serie por unit × estado). | Sólo si se quiere alertar de "service X failed" desde Prometheus. Para el homelab, Uptime Kuma cubre el caso. |
| `--collector.interrupts` | `node_interrupts_total{cpu, type}` (interrupts del kernel). | Cardinalidad alta (cores × tipos). | Diagnóstico puntual de problemas de IO/IRQ. Activar y volver a desactivar. |
| `--collector.tcpstat` | `node_tcp_connection_states{state=...}` (TIME_WAIT, ESTABLISHED, etc.). | Bajo. | Si se sospechan agotamiento de file descriptors o leaks de TCP. |
| `--collector.textfile` | Permite exponer métricas custom dejando ficheros `.prom` en un directorio. | Requiere bind mount adicional. | Cuando el homelab tenga métricas propias (e.g. resultado de un script de health-check de SMART). Documentado en una variante futura. |

Para activar uno (ejemplo: `tcpstat`):

```bash
# Editar ~/homelab/stacks/monitoring/docker-compose.yml, en el command: del
# servicio node-exporter, añadir:
#   - "--collector.tcpstat"

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate node-exporter

# Confirmar:
docker exec prometheus wget -qO- http://node-exporter:9100/metrics \
  | grep -E '^node_tcp_connection_states' | head
```

### 10.2. Desactivar un colector que aparece ruidoso en los logs

Si los logs muestran repetidamente errores tipo:

```
ts=... caller=collector.go:... level=error msg="collector failed" name=<X> err="..."
```

Desactivarlo es trivial: añadir `- "--no-collector.<X>"` al `command:` y `up -d --force-recreate`. La regla general: si el colector emite siempre `0` o errores, se desactiva (y se documenta brevemente en el `command:` por qué).

### 10.3. Bajar el nivel de log a `debug` para troubleshooting

```bash
# En docker-compose.yml, cambiar:
#   - "--log.level=info"
# por:
#   - "--log.level=debug"

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate node-exporter

# Tras diagnosticar: revertir y volver a recrear.
```

> `debug` produce salida por cada scrape (cada 30 s) listando todos los colectores. Útil para diagnosticar "por qué este colector emite 0"; volver a `info` después.

### 10.4. Upgrade manual

```bash
# Antes de cambiar el tag, leer:
# https://github.com/prometheus/node_exporter/blob/master/CHANGELOG.md

sudo sed -i 's|^NODE_EXPORTER_IMAGE_TAG=.*|NODE_EXPORTER_IMAGE_TAG=v1.8.3|' \
  /mnt/hd2t/services/monitoring/.env

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env pull node-exporter
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate node-exporter

# Verificar:
docker exec node-exporter node_exporter --version 2>&1 | head
docker logs node-exporter | tail -20
```

> Watchtower **sí** actualiza Node Exporter automáticamente a las 04:00 si el tag tiene una nueva digest. Patches (1.8.x → 1.8.y) son seguros (no hay schema, no hay BD). Para minors (1.8 → 1.9) y majors (1.x → 2.x), el upgrade manual permite leer el CHANGELOG por si una métrica se renombra.

### 10.5. Rotación de la convención de etiquetas

Si en el futuro se añade un segundo host (NAS, otra Pi, VM), se puede:

- Dejar `external_labels: {host: pi5}` en `prometheus.yml` y desplegar otro Node Exporter con su propio Prometheus (federación);
- O, más simple, añadir el segundo target al mismo job:
  ```yaml
  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']
        labels: { service: node-exporter, host: pi5 }
      - targets: ['nas-node-exporter:9100']
        labels: { service: node-exporter, host: nas01 }
  ```
  Los dashboards 1860 / 10578 ya tienen una variable `$instance` que filtra por host.

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `docker compose up node-exporter` falla con `network homelab declared as external, but could not be found` | La red `homelab` no está creada. | Crearla según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2. |
| `node-exporter` arranca pero `/metrics` reporta valores absurdos (1 PID, 0 hwmon, eth0 con MAC del bridge Docker) | Faltan los flags `--path.procfs/sysfs/rootfs` o los bind mounts correspondientes. | Comparar `command:` y `volumes:` con §5. `docker exec node-exporter cat /host/proc/meminfo \| head` debe mostrar el meminfo del host. |
| `node_hwmon_temp_celsius` no aparece | El bind mount de `/sys` no está en su sitio o el kernel no expone sensores. | `docker exec node-exporter ls /host/sys/class/hwmon/`: si está vacío, el problema es del kernel del host (`dmesg \| grep -i thermal`). Si tiene `hwmon0/`, etc., revisar el flag `--path.sysfs=/host/sys`. |
| El target `node-exporter` aparece **DOWN** con `connection refused` en `/targets` | El contenedor `node-exporter` no está sano o no resuelve. | `docker compose ps node-exporter` y `docker exec prometheus wget -qO- http://node-exporter:9100/-/healthy`. Revisar la red: `docker inspect node-exporter --format '{{json .NetworkSettings.Networks}}'` debe listar `homelab`. |
| El target aparece **UP** pero el dashboard 1860 está casi todo vacío | El placeholder `${DS_PROMETHEUS}` no se sustituyó en el JSON. | Aplicar §7.1.2 (sed + limpieza de `__inputs`). Tras editar el JSON, esperar ≤30 s al refresh del provider de Grafana. |
| `node_filesystem_*` lista decenas de mountpoints "ruido" (`/etc/hosts`, `/dev/shm`, mountpoints de Docker) | Falta `--collector.filesystem.mount-points-exclude` o no incluye los paths del propio bind mount. | Revisar §5 (`mount-points-exclude` debe cubrir `^/(sys\|proc\|dev\|host\|etc\|rootfs/(sys\|proc\|dev\|host\|etc))($\|/)`). |
| Node Exporter consume CPU constante (>5 %) en idle | Algún colector caro está activo (típicamente `--collector.processes` con `pid: host` y miles de PIDs, o `--collector.systemd` con muchos units). | Listar colectores activos: `wget -qO- http://node-exporter:9100/metrics \| grep node_scrape_collector_duration_seconds \| sort -k2 -n -r \| head`. El más caro normalmente es `filesystem` en hosts con muchos discos; aceptable. Si es otro y no se necesita, desactivarlo (§10.2). |
| Logs muestran `error reading /host/sys/class/<X>: permission denied` | Un sub-path de `/sys` no es legible por UID 65534. | Improbable en Raspberry Pi OS por defecto. Si pasa, identificar el colector responsable y desactivarlo con `--no-collector.<X>` (la pérdida es mínima: las clases sensibles suelen ser de FS exóticos no usados). |
| Tras un upgrade de minor (1.8 → 1.9 o similar), un dashboard pierde paneles | Una métrica fue renombrada en el CHANGELOG. | Leer el CHANGELOG, identificar el rename (raro pero documentado), ajustar el JSON del dashboard o usar `relabel_configs` en el job para mantener compatibilidad. Mientras tanto, fijar `NODE_EXPORTER_IMAGE_TAG` a la versión anterior. |
| `docker compose ps` muestra `node-exporter (unhealthy)` justo tras arrancar | `start_period` (10 s) demasiado corto si el host está muy cargado. | Subir `start_period: 30s` en el healthcheck. En operación normal el binario está listo en <1 s; sólo afecta al primer arranque. |
| Watchtower actualiza la imagen y rompe un dashboard | Cambio de minor con rename de métrica que el operador no notó. | Pin del tag en `.env` (ya hecho) **+** `watchtower.enable: "false"` temporal mientras se decide el upgrade. Se rebobina la imagen con `docker pull prom/node-exporter:<tag-anterior>` + `up -d --force-recreate`. |

---

## Referencias

- [Node Exporter — Repo y CHANGELOG (GitHub)](https://github.com/prometheus/node_exporter)
- [Node Exporter — Imagen Docker oficial](https://hub.docker.com/r/prom/node-exporter)
- [Node Exporter — Lista completa de colectores y métricas](https://github.com/prometheus/node_exporter#collectors)
- [Node Exporter — Receta canónica para Docker (`--path.procfs`, `--path.sysfs`, `--path.rootfs`)](https://github.com/prometheus/node_exporter#docker)
- [Prometheus — Configuración de `scrape_configs`](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config)
- [Grafana.com — Dashboard "Node Exporter Full" (#1860)](https://grafana.com/grafana/dashboards/1860-node-exporter-full/)
- [Grafana.com — Dashboard "Raspberry Pi Monitoring" (#10578)](https://grafana.com/grafana/dashboards/10578-rpi-monitoring/)
- [Linux kernel — `/proc` filesystem](https://docs.kernel.org/filesystems/proc.html)
- [Linux kernel — `hwmon` (sensores de temperatura, voltaje, ventilador)](https://docs.kernel.org/hwmon/sysfs-interface.html)
- [Awesome Prometheus alerts (catálogo de reglas, sección "Host & hardware")](https://samber.github.io/awesome-prometheus-alerts/rules.html#host-and-hardware)
