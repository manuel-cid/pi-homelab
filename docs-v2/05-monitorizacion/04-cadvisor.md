# cAdvisor

## Descripción

Despliegue de **cAdvisor** (`gcr.io/cadvisor/cadvisor`, "Container Advisor", proyecto upstream de Google) como **agente de métricas por contenedor** del homelab: expone en `:8080/metrics` en formato Prometheus las series por cgroup (CPU, memoria, IO de disco, red por interfaz, descriptors, throttling) leyendo de `/sys/fs/cgroup`, `/var/lib/docker/` y `/proc`. Prometheus ([`./01-prometheus.md`](./01-prometheus.md)) lo scrapea cada 30 s desde la red `homelab` y Grafana ([`./02-grafana.md`](./02-grafana.md)) lo pinta usando el dashboard "Docker / cAdvisor Compute Resources" (Grafana.com #14282) que este doc provisiona.

cAdvisor es el cuarto servicio del stack `monitoring` (fila §1.1 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)). Este documento **extiende** el `~/homelab/stacks/monitoring/docker-compose.yml` que dejaron Prometheus, Grafana y Node Exporter, **no** crea un compose nuevo. Tras este doc, el stack tiene cuatro servicios (`prometheus`, `grafana`, `node-exporter`, `cadvisor`); los siguientes docs (`./05-uptime-kuma.md`, `./06-dozzle.md`) añaden el resto.

> **Alcance de red**: cAdvisor **no** publica puertos al host. La UI HTML que sirve en `/` es informativa pero redundante con Portainer ([`../02-docker/03-portainer.md`](../02-docker/03-portainer.md)) — que ya da una vista de contenedores con UX mejor — y con los dashboards de Grafana, así que **no se pone detrás de Caddy + Authelia**: añadir el reverse-proxy duplicaría una capacidad ya cubierta y obligaría a mantener una nueva regla de `access_control`. El endpoint `/metrics` queda accesible **sólo** desde la red bridge `homelab`, scrapeado por Prometheus.

> **cAdvisor vs Node Exporter — qué responde cada uno**:
>
> | Pregunta | Quién responde |
> |---|---|
> | "¿Cuánta CPU está consumiendo el host en total?" | Node Exporter (`node_cpu_seconds_total`) |
> | "¿Cuánta CPU está consumiendo Jellyfin?" | cAdvisor (`container_cpu_usage_seconds_total{name="jellyfin"}`) |
> | "¿Cuánta RAM libre tiene la Pi?" | Node Exporter (`node_memory_MemAvailable_bytes`) |
> | "¿Cuánta RAM ha reservado el contenedor `prometheus` y cuánta usa?" | cAdvisor (`container_memory_usage_bytes`, `container_spec_memory_limit_bytes`) |
> | "¿Qué temperatura tiene el SoC?" | Node Exporter (`node_hwmon_temp_celsius`) |
> | "¿Cuántos bytes ha leído `nextcloud` del disco en la última hora?" | cAdvisor (`container_fs_reads_bytes_total{name="nextcloud"}`) |
>
> Los dos exporters son complementarios y no se solapan en su set de métricas: Node Exporter mira "el host", cAdvisor mira "los contenedores". Ambos viven en el mismo stack `monitoring` y son scrapeados por el mismo Prometheus.

> **Por qué cAdvisor y no otro agente** (Docker exporter, ctop, telegraf-docker, etc.):
>
> 1. **Estándar de facto del ecosistema**. Los dashboards públicos de Grafana.com para "salud de contenedores Docker" (#14282 Docker/cAdvisor, #11600 Docker monitoring, #893 Docker Container & Host Metrics) están escritos contra los nombres `container_*` de cAdvisor. Importarlos requiere cero adaptación.
> 2. **Lectura directa de cgroups + Docker socket**. cAdvisor abre `/sys/fs/cgroup/<container>/...` y `/var/lib/docker/` (read-only) para enumerar contenedores; no llama al Docker API por TCP ni necesita un proxy. Esto da granularidad fina (cada 30 s) sin coste de network round-trip y, sobre todo, evita exponer el daemon Docker a la red `homelab`.
> 3. **Cardinalidad acotada por defecto**. Las métricas vienen etiquetadas por `name`, `id`, `image`, `container_label_*`. En un homelab con ~30–40 contenedores y `--store_container_labels=false`, el TSDB de Prometheus crece en torno a 2–5 MB/día (estimación coherente con la retención de [`./01-prometheus.md`](./01-prometheus.md) §3).
> 4. **Multi-arch oficial desde v0.36**. La imagen `gcr.io/cadvisor/cadvisor` se publica para `linux/arm64` desde 2020. Antes había que recurrir al fork `zcube/cadvisor` para Raspberry Pi; ya no.
> 5. **No se elige `prometheus-docker-exporter`** porque el repo upstream lleva años sin commits y su set de métricas es estrictamente menor; **no se elige Telegraf con `inputs.docker`** porque InfluxDB no se usa en el homelab y duplicaría el agente de scrape; **no se elige `ctop`** porque es una TUI interactiva, no un exporter (no expone `/metrics`).
> 6. **Coste mínimo en una Pi 5**. El proceso reposa en torno a 60–90 MB RAM (incluye los caches internos de cgroups) y consume ~0.5–1 % CPU en idle. Es más caro que Node Exporter (que es prácticamente gratis), pero el output justifica el coste: visibilidad por contenedor.

---

## Requisitos Previos

- **Prometheus desplegado y sano** según [`./01-prometheus.md`](./01-prometheus.md): `docker inspect prometheus --format '{{.State.Health.Status}}'` debe devolver `healthy`. La query `up{job="prometheus"}` devuelve `1`. El `prometheus.yml` ya tiene el placeholder comentado del `job_name: 'cadvisor'` (§4 de Prometheus, líneas marcadas como `ACTIVAR cuando ./04-cadvisor.md ...`).
- **Grafana desplegado y sano** según [`./02-grafana.md`](./02-grafana.md): `docker inspect grafana --format '{{.State.Health.Status}}'` debe devolver `healthy`. El árbol de provisioning `~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/` existe y está configurado para auto-recargar cualquier `.json` que aparezca (§6.1 de Grafana, `updateIntervalSeconds: 30`).
- **Node Exporter desplegado y sano** según [`./03-node-exporter.md`](./03-node-exporter.md): no es una dependencia técnica de cAdvisor (los dos exporters son independientes), pero la Fase 5 se redacta en orden y este doc asume que la fila anterior está completa. Si por alguna razón Node Exporter aún no está desplegado, los pasos de cAdvisor siguen siendo válidos sin cambios.
- **Stack `monitoring` ya inicializado** con los servicios anteriores: `~/homelab/stacks/monitoring/{docker-compose.yml,prometheus.yml,grafana/...,.env.example}` versionados en git, `/mnt/hd2t/services/monitoring/.env` con las variables comunes y las de Prometheus + Grafana + Node Exporter.
- **Red `homelab`** creada según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2 (`172.20.0.0/24`, bridge `br-homelab`, `external: true`).
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No se añaden reglas: cAdvisor no publica puertos al host; el tráfico llega únicamente desde Prometheus por la red bridge.
- **cgroups v2 unificados** (default en Raspberry Pi OS Bookworm). cAdvisor v0.47+ funciona con v1 y v2 transparentemente, pero las decisiones de §0 asumen v2 (jerarquía única en `/sys/fs/cgroup/`). Confirmar con `mount | grep cgroup`: debe aparecer una sola línea `cgroup2 on /sys/fs/cgroup type cgroup2 ...`.
- **Estructura de directorios** del stack `monitoring` ya en su sitio (creada por [`./01-prometheus.md`](./01-prometheus.md) §3.2 y [`./02-grafana.md`](./02-grafana.md) §3.2). cAdvisor **no necesita un directorio de datos propio** (no escribe nada al disco); el bootstrap original ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6.6) creó un `/mnt/hd2t/services/cadvisor/` vacío del esquema antiguo "un dir por servicio" que se **elimina** en §3.1.
- **Comprobaciones rápidas**:
  ```bash
  # Prometheus está sano y tiene el placeholder del job listo:
  docker inspect prometheus --format '{{.State.Health.Status}}'
  # Esperado: healthy
  grep -A4 "job_name: 'cadvisor'" ~/homelab/stacks/monitoring/prometheus.yml | head
  # Esperado: las 4 líneas comentadas (#) que se descomentarán en §4.

  # Grafana está sano y autoprovisiona dashboards:
  docker inspect grafana --format '{{.State.Health.Status}}'
  # Esperado: healthy
  ls ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/
  # Esperado: prometheus-stats.json y los dejados por ./03-node-exporter.md.

  # El stack monitoring tiene exactamente prometheus + grafana + node-exporter:
  docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml ps --services
  # Esperado: prometheus, grafana, node-exporter

  # cgroups v2 unificados (default Bookworm):
  mount | grep -E '^cgroup'
  # Esperado: cgroup2 on /sys/fs/cgroup type cgroup2 ...

  # /var/run/docker.sock existe y es accesible por root:
  test -S /var/run/docker.sock && echo "docker.sock OK"
  # Esperado: docker.sock OK

  # /var/lib/docker/ es legible:
  sudo test -d /var/lib/docker && echo "/var/lib/docker OK"
  # Esperado: /var/lib/docker OK
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Imagen Docker | **`gcr.io/cadvisor/cadvisor:v0.49.1`** | Imagen oficial multi-arch del proyecto upstream Google (`linux/arm64` publicado desde v0.36). v0.49 es la rama estable actual; el changelog de v0.49.x sólo trae bugfixes y dependencias actualizadas. **No se usa** `zcube/cadvisor` (fork comunitario que en su día rellenó el hueco de ARM antes de que Google publicase imágenes oficiales): hoy es redundante y suma una dependencia de un mantenedor único. |
| Tag de imagen | **Pinned a release puntual**, nunca `latest` | Misma regla de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1. cAdvisor renombra/retira métricas con frecuencia mayor que Node Exporter; el upgrade se hace leyendo el [CHANGELOG](https://github.com/google/cadvisor/blob/master/CHANGELOG.md) por si algún panel del dashboard 14282 se queda sin datos. |
| Política de Watchtower | **`watchtower.enable: "true"`** | Coherente con [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 (cAdvisor está en la lista de incluidos). Los upgrades de patch (v0.49.1 → v0.49.2) son seguros: no hay BD propia, no hay schema. Para minor (v0.49 → v0.50) revisar el changelog antes de aceptarlo manualmente; mientras tanto, si Watchtower lo hace de noche, el peor caso es un dashboard con un panel "No data" hasta que se ajuste. |
| Modo de red | **Sólo `homelab`** (bridge `external`) | Prometheus, que vive en `homelab`, scrapea `cadvisor:8080` por DNS interno. **No** se usa `network_mode: host` (alternativa común en otros homelabs): es incompatible con `networks:` y publicaría `:8080` al LAN sin filtro. cAdvisor obtiene la información de los contenedores leyendo cgroups y `/var/lib/docker/`, no consultando otros contenedores por red, así que no le hace falta el namespace de red del host. |
| `ports:` publicados al host | **Ninguno** | Idéntico razonamiento que Prometheus, Grafana y Node Exporter. `:8080` queda accesible **sólo** desde la red `homelab`. La UI HTML de cAdvisor incluye listados de procesos y rutas internas — exponerla al LAN sin auth sería información gratis para un atacante interno. |
| Acceso a la UI / `/metrics` | **Sin autenticación, sólo desde `homelab`** | cAdvisor soporta `--http_basic_auth_file` y TLS (`--tls_cert_file` / `--tls_key_file`), pero añadir esa capa cuando ya hay aislamiento de red (bridge privado `172.20.0.0/24`) es complejidad sin beneficio. La superficie está cerrada por la red, no por auth de aplicación. |
| Reverse-proxy en Caddy | **NO** se publica `cadvisor.lan` | A diferencia de Prometheus o Grafana (que tienen UIs operacionales útiles para humanos), la UI HTML de cAdvisor es redundante: Portainer ([`../02-docker/03-portainer.md`](../02-docker/03-portainer.md)) ya muestra contenedores con mejor UX, y los dashboards de Grafana cubren las series temporales. Publicar otro hostname añadiría una nueva regla en el `Caddyfile` y otra entrada en `access_control` de Authelia para nada. |
| `privileged: true` | **Activado** | cAdvisor necesita acceso amplio a `/sys/fs/cgroup`, `/proc`, `/var/lib/docker/` y los namespaces internos de los contenedores que monitoriza. La receta canónica del proyecto upstream ([README de cadvisor](https://github.com/google/cadvisor/blob/master/docs/running.md)) usa `--privileged`. La alternativa "fina" (sólo `cap_add: [SYS_ADMIN, SYS_PTRACE]` + `security_opt: apparmor=unconfined` + bind mounts ro) funciona en kernels concretos pero rompe en otros (los detalles cambian con cada kernel/cgroup driver). En un homelab personal, la simplicidad y robustez de `privileged: true` ganan al ligero plus de hardening. La superficie real está limitada por los bind mounts read-only (§5). |
| Bind mounts del host | **`/:/rootfs:ro`, `/var/run:/var/run:ro`, `/sys:/sys:ro`, `/var/lib/docker/:/var/lib/docker:ro`, `/dev/disk/:/dev/disk:ro`, `/etc/machine-id:/etc/machine-id:ro`** | Receta canónica upstream. `/:/rootfs:ro` permite a cAdvisor leer estadísticas de filesystems del host. `/var/run` da acceso al socket de Docker (necesario para enriquecer las métricas con metadatos de los contenedores: `image`, `container_label_*`). `/sys:ro` da acceso a los cgroups (carpeta `/sys/fs/cgroup/`). `/var/lib/docker:ro` deja a cAdvisor descubrir contenedores parados/efímeros. `/dev/disk:ro` permite mapear `dm-X`/`mmcblk*` a sus device names humanos en las métricas de IO. `/etc/machine-id:ro` etiqueta las series con un identificador estable del host (útil cuando se federa con otro Prometheus). Todos `ro`: cAdvisor no escribe en el host bajo ningún concepto. |
| Devices del host | **`--device=/dev/kmsg`** | Algunos kernels exponen mensajes de OOM y throttling sólo en `/dev/kmsg`. cAdvisor lo lee para correlacionar OOM-kills con el contenedor culpable y exponerlo en `container_oom_events_total`. Sin esto, los OOM siguen registrándose en `dmesg` del host pero no aparecen como métrica por contenedor. La exposición es de **lectura**: cAdvisor abre el dispositivo en O_RDONLY. |
| `--docker_only=true` | **Activado** | Por defecto cAdvisor enumera **todos** los cgroups del sistema: containers Docker, `system.slice/*`, `user.slice/*`, sesiones systemd-logind, etc. La métrica `container_*` con label `name=""` (cgroups del host) infla el output con datos que ya cubre Node Exporter. `--docker_only=true` filtra al exporter para que sólo emita series de cgroups que pertenecen a Docker. **Reduce ~70% el tamaño del `/metrics`** sin perder información útil. |
| `--store_container_labels=false` + `--whitelisted_container_labels` | **Lista corta**: `com.docker.compose.project,com.docker.compose.service,com.docker.compose.oneoff,com.centurylinklabs.watchtower.enable` | Por defecto cAdvisor copia **todas** las labels Docker de cada contenedor (`com.docker.compose.config-hash`, `org.opencontainers.image.*`, `homepage.*`, `traefik.*`, etc.) como labels de cada serie temporal. Con ~40 contenedores en el homelab y ~10–20 labels por contenedor, esto explota la cardinalidad del TSDB. La whitelist conserva sólo las útiles para agrupar (proyecto/servicio compose) y filtrar (`watchtower.enable=true/false` para alertas tipo "qué se va a actualizar de noche"). |
| `--disable_metrics` | **`referenced_memory,cpu_topology,resctrl,udp,advtcp,sched,hugetlb,process,percpu`** | Cada métrica desactivada cubre un caso que el homelab no usa: `referenced_memory` (sólo válida con kernel patches concretos, suele dar 0), `cpu_topology` (requiere `--enable_load_reader`, sólo aplica en NUMA), `resctrl` (Intel RDT, no aplica en ARM), `udp`/`advtcp` (estadísticas TCP/UDP por cgroup — alta cardinalidad y poco accionable), `sched` (`/proc/<pid>/schedstat`, casi siempre 0), `hugetlb` (Pi 5 no usa hugepages), `process` (un labelset por proceso dentro del contenedor: cardinalidad explosiva), `percpu` (CPU usage por core × contenedor: en Pi 5 con 4 cores y 40 contenedores son 160 series sólo para esto). |
| `--housekeeping_interval` | **`30s`** | Cada cuánto cAdvisor refresca su caché interna leyendo cgroups. Default upstream: `10s`. En un homelab con 30 s de `scrape_interval` (Prometheus), bajar housekeeping a 10 s sólo desperdicia CPU: las muestras intermedias entre dos scrapes se descartan. `30s` lo alinea al scrape de Prometheus. Reduce la CPU media del proceso ~3×. |
| `--global_housekeeping_interval` | **`1m0s`** (default) | Cada cuánto cAdvisor descubre **nuevos** contenedores. 1 minuto es suficiente: los containers nuevos del homelab se crean por humanos (despliegues manuales) y no necesitan aparecer en Grafana al segundo. |
| `--storage_driver` | **`""` (vacío, sin storage propio)** | cAdvisor puede escribir las muestras en backends propios (StatsD, BigQuery, Elasticsearch...). En este homelab Prometheus es el único consumidor; el storage interno se desactiva (es el default cuando no se especifica `--storage_driver`). |
| Usuario del contenedor | **`root` (default de la imagen)** | La imagen oficial corre como root. Es lo esperado por `--privileged`: si se forzara `user: 1000:1000`, los bind mounts de `/sys/fs/cgroup` y `/var/lib/docker/` darían `permission denied` y el agente arrancaría sin métricas. **No** se sobreescribe con `${PUID}:${PGID}`. |
| `cap_drop` / `cap_add` | (no se especifican: `privileged: true` los hace irrelevantes) | Cuando `privileged: true` está activo, Docker concede todas las capabilities y desactiva los seccomp filters; añadir o quitar capabilities por encima no tiene efecto. Si en el futuro se migra al modo "sin privileged", la lista mínima documentada es `cap_add: [SYS_ADMIN, DAC_READ_SEARCH]` + `security_opt: [apparmor=unconfined, no-new-privileges:true]` + bind mounts iguales. Mientras tanto, no se declara para no inducir falsa seguridad. |
| `security_opt: no-new-privileges:true` | **NO** se activa con `privileged: true` | Igual que el punto anterior: con privileged, Docker reescribe las opciones de seguridad. Documentar `no-new-privileges:true` aquí da una falsa sensación de hardening. La opción aparecerá si en el futuro se quita el privileged. |
| `read_only: true` | **NO** se activa | A diferencia de Node Exporter, cAdvisor escribe a `/tmp` (caches temporales) y, en algunos colectores, abre rutas en `/var/run/cadvisor*`. Forzar root FS read-only ha dado lugar a regresiones intermitentes (issue [#2944](https://github.com/google/cadvisor/issues/2944) y similares). Se deja en lectura/escritura (default). El daño potencial está acotado por los bind mounts del host (todos `ro`). |
| Persistencia | **Ninguna** | No hay BD, no hay caché en disco, no hay estado. Reiniciar el contenedor pierde 0 datos del propio cAdvisor; las series temporales viven en Prometheus. **No se crea** ningún directorio bajo `/mnt/hd2t/services/monitoring/cadvisor/`. |
| Healthcheck | **`/healthz`** vía `wget` busybox de la imagen | El endpoint `/healthz` (sin auth) responde 200 con `ok` cuando el HTTP server escucha y la inicialización ha terminado. La imagen oficial trae `wget` busybox. `start_period` algo más holgado que Node Exporter (30 s): cAdvisor enumera todos los contenedores en el primer arranque, lo que en una Pi 5 con ~30–40 contenedores tarda ~5–15 s. |
| Logs Docker | **`json-file` 10 MB × 3** (heredado del demonio) | Plantilla §6.1 de estructura-compose. cAdvisor genera logs moderados (un puñado de líneas por minuto, más en debug). 10 MB cubren días. |
| Memoria del contenedor (`mem_limit`) | **`256m`** | cAdvisor en idle reposa ~60–90 MB. El límite duro a 256 MB protege a la Pi de un leak (han aparecido en el pasado, e.g. issue [#3097](https://github.com/google/cadvisor/issues/3097) en versiones afectadas) o de un pico al enumerar muchos contenedores efímeros. Si se alcanza el límite, Docker mata el contenedor y `restart: unless-stopped` lo levanta de nuevo. La pérdida de datos es 0 (Prometheus tiene un agujero de un scrape). |
| Dashboard | **`Docker / cAdvisor Compute Resources` (#14282, rev 4)** | Dashboard "todo en uno" para cAdvisor (~30 paneles: CPU/RAM/Net/IO por contenedor, top consumers, container start time). Viene de Grafana.com con `${DS_PROMETHEUS}` y se post-procesa con la receta de [`./02-grafana.md`](./02-grafana.md) §6.3.2 antes de meterlo en `provisioning/dashboards/json/`. |

---

## 1. Resumen de la arquitectura

```
                ┌───────────────────────────── HOST: Pi 5 (Raspberry Pi OS) ───────────────────────────┐
                │                                                                                       │
                │   /sys/fs/cgroup/   /var/lib/docker/   /var/run/docker.sock   /  /dev/disk  /dev/kmsg │
                │           ▲                ▲                  ▲                ▲       ▲        ▲     │
                │           │                │                  │                │       │        │     │
                │           │   bind mount (ro)                 │ socket (ro)    │ ro    │ ro     │ chr │
                │           │                                                                          │
                │   ┌───────┼────────┼──────────┼────────────┼──────── docker network: homelab ─────┐ │
                │   │       │        │          │            │                                       │ │
                │   │     /sys  /var/lib/docker  /var/run  /rootfs  /dev/disk  /dev/kmsg              │ │
                │   │       ▲        ▲                                                                │ │
                │   │       │        │                                                                │ │
                │   │   ┌───┴────────┴─────────────── cadvisor ─────────────────────────┐             │ │
                │   │   │ image: gcr.io/cadvisor/cadvisor:v0.49.1                        │             │ │
                │   │   │ user:  root                                                    │             │ │
                │   │   │ networks: [homelab]                                            │             │ │
                │   │   │ ports: -                                                       │             │ │
                │   │   │ privileged: true                                               │             │ │
                │   │   │ flags:                                                         │             │ │
                │   │   │   --docker_only=true                                           │             │ │
                │   │   │   --store_container_labels=false                               │             │ │
                │   │   │   --whitelisted_container_labels=com.docker.compose.project,...│             │ │
                │   │   │   --disable_metrics=referenced_memory,cpu_topology,...         │             │ │
                │   │   │   --housekeeping_interval=30s                                  │             │ │
                │   │   │ /metrics  (HTTP plano, sin auth, :8080)                        │             │ │
                │   │   └─────▲──────────────────────────────────────────────────────────┘             │ │
                │   │         │                                                                        │ │
                │   │         │  scrape_interval: 30s                                                  │ │
                │   │         │  GET http://cadvisor:8080/metrics                                      │ │
                │   │         │                                                                        │ │
                │   │   ┌─────┴─────────── prometheus ───────────────────┐                             │ │
                │   │   │ job_name: 'cadvisor'                            │                             │ │
                │   │   │ targets: [cadvisor:8080]                        │                             │ │
                │   │   │ labels: { service: cadvisor, instance: ... }    │                             │ │
                │   │   └─────┬─────────────────────────────────────────┘                              │ │
                │   │         │                                                                        │ │
                │   │         │  TSDB local en /mnt/hd2t/.../prometheus/data/                          │ │
                │   │         │                                                                        │ │
                │   │   ┌─────▼─────────── grafana ───────────────────────┐                            │ │
                │   │   │ datasource: Prometheus (uid=prometheus)         │                            │ │
                │   │   │ dashboards (provisioned, JSON):                  │                            │ │
                │   │   │   - Docker / cAdvisor Compute Resources (#14282) │                            │ │
                │   │   └──────────────────────────────────────────────────┘                            │ │
                │   │                                                                                  │ │
                │   └──────────────────────────────────────────────────────────────────────────────────┘ │
                │                                                                                       │
                └───────────────────────────────────────────────────────────────────────────────────────┘
```

Tres invariantes:

- **cAdvisor sólo es accesible desde la red `homelab`.** No hay `ports:` al host, no hay reverse-proxy en Caddy, no hay TLS ni auth. Su `/metrics` y su UI HTML quedan a un network-namespace de distancia de cualquier cliente del LAN.
- **El proceso es stateless.** Reiniciar, recrear o borrar el contenedor pierde 0 datos. Las métricas se reconstruyen al siguiente scrape leyendo cgroups y `/var/lib/docker/`.
- **El agente lee el host, no a sí mismo.** `--docker_only=true` filtra el ruido del cgroup root. Los bind mounts de `/sys` y `/var/lib/docker` redirigen las lecturas al estado real de Docker en la Pi, no al estado del namespace del propio cAdvisor.

Flujo de un scrape:

```
1. Prometheus consulta su prometheus.yml: job 'cadvisor' / target 'cadvisor:8080'.
2. cada 30 s: HTTP GET http://cadvisor:8080/metrics  (DNS interno de homelab).
3. cAdvisor sirve el contenido cacheado por su housekeeping (también 30 s):
       - container_cpu_usage_seconds_total{name, image, ...}
       - container_memory_usage_bytes{name, ...}
       - container_memory_working_set_bytes{name, ...}
       - container_network_receive_bytes_total{name, interface}
       - container_network_transmit_bytes_total{name, interface}
       - container_fs_reads_bytes_total / container_fs_writes_bytes_total
       - container_oom_events_total
       - container_start_time_seconds
       - container_spec_memory_limit_bytes / container_spec_cpu_quota
       - ... (~60–80 series por contenedor, según métricas activas)
4. Devuelve un texto plano de ~200–500 KB con ~2000–3000 series totales (40 containers).
5. Prometheus parsea, etiqueta con (job, instance, scrape_pool), y escribe al TSDB.
6. Grafana, en el siguiente refresh del dashboard, ejecuta PromQL contra el TSDB.
```

---

## 2. Plan de variables y archivos

El stack `monitoring` ya existe; este doc **extiende** los ficheros que dejaron Prometheus, Grafana y Node Exporter. Estado del repo después de este doc:

```
~/homelab/stacks/monitoring/             # versionable en git
├── docker-compose.yml                   # +bloque `cadvisor:`
├── .env.example                         # +sección cAdvisor
├── prometheus.yml                       # job 'cadvisor' DESCOMENTADO
└── grafana/
    ├── grafana.ini                       # sin cambios
    └── provisioning/
        ├── datasources/prometheus.yml    # sin cambios
        └── dashboards/
            ├── default.yml               # sin cambios
            └── json/
                ├── prometheus-stats.json
                ├── node-exporter-full.json
                ├── rpi-monitoring.json
                └── docker-cadvisor.json     # NUEVO (Grafana.com #14282)

/mnt/hd2t/services/monitoring/           # datos persistentes, NO en git
├── .env                                  # +sección cAdvisor
├── prometheus/data/                      # sin cambios
└── grafana/data/                         # sin cambios

# (NO se crea /mnt/hd2t/services/monitoring/cadvisor/: el agente es stateless.)
```

### 2.1. Variables del stack — extender `.env.example`

Editar `~/homelab/stacks/monitoring/.env.example` (creado por [`./01-prometheus.md`](./01-prometheus.md) §2.1, ampliado por [`./02-grafana.md`](./02-grafana.md) §2.1 y [`./03-node-exporter.md`](./03-node-exporter.md) §2.1) y **descomentar/rellenar** la sección cAdvisor:

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
NODE_EXPORTER_IMAGE_TAG=v1.8.2

# --- cAdvisor (./04-cadvisor.md) ---
# https://github.com/google/cadvisor/releases
# CHANGELOG: https://github.com/google/cadvisor/blob/master/CHANGELOG.md
# Imagen oficial multi-arch (linux/arm64) desde v0.36.
CADVISOR_IMAGE_TAG=v0.49.1

# (Reservado para los siguientes docs de Fase 5; se rellenarán cuando toquen)
# UPTIME_KUMA_IMAGE_TAG=
# DOZZLE_IMAGE_TAG=
```

### 2.2. Extender el `.env` real (`/mnt/hd2t/services/monitoring/.env`)

```bash
# Añadir las nuevas líneas al .env (sin tocar las existentes de Prometheus/
# Grafana/Node Exporter):
sudo tee -a /mnt/hd2t/services/monitoring/.env >/dev/null <<'EOF'

# --- cAdvisor (./04-cadvisor.md) ---
CADVISOR_IMAGE_TAG=v0.49.1
EOF

# Comprobar permisos (deben seguir siendo 600):
ls -l /mnt/hd2t/services/monitoring/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

> **No hay secretos** en la sección cAdvisor: ni passwords, ni tokens, ni TLS configurada. La única variable es la versión de la imagen.

---

## 3. Preparar el host

### 3.1. Limpieza del directorio del esquema antiguo

El bootstrap original ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6.6) creó `/mnt/hd2t/services/cadvisor/` siguiendo el esquema "un dir por servicio" que el plan ha sustituido por "un dir por stack". cAdvisor **no necesita** ningún directorio de datos porque no escribe nada al filesystem persistente; el directorio queda huérfano y se elimina:

```bash
# Confirmar que está vacío:
ls -la /mnt/hd2t/services/cadvisor/ 2>/dev/null
# Esperado: . y .. solamente; cualquier otra cosa indicaría un experimento
# previo que conviene revisar antes de borrar.

sudo rmdir /mnt/hd2t/services/cadvisor 2>/dev/null || true
# El rmdir falla silenciosamente si el directorio no existe; ambos casos OK.
```

> **No se crea** `/mnt/hd2t/services/monitoring/cadvisor/`: a diferencia de Prometheus y Grafana, cAdvisor no escribe nada al disco persistente. Crear un directorio vacío sólo añadiría ruido al árbol y a Borgmatic.

### 3.2. Verificar cgroups v2 y rutas necesarias

```bash
# cgroups v2 unificados (default en Bookworm):
mount | grep -E '^cgroup'
# Esperado:
#   cgroup2 on /sys/fs/cgroup type cgroup2 ...
# Si aparecen múltiples montajes "cgroup on /sys/fs/cgroup/<controller>" estás
# en cgroup v1 — cAdvisor sigue funcionando, pero el filtro de métricas y
# algunos labels difieren ligeramente del esperado por el dashboard 14282.

# /var/run/docker.sock existe y root puede leerlo:
sudo test -S /var/run/docker.sock && echo "docker.sock OK"
# Esperado: docker.sock OK

# /var/lib/docker/ es el data root de Docker (no se ha movido):
docker info --format '{{.DockerRootDir}}'
# Esperado: /var/lib/docker
# Si saliera otra cosa (e.g. /mnt/hd2t/docker), el bind mount de §5 debe
# adaptarse a ese path. Los docs del homelab no han movido el data root.

# /dev/kmsg existe (suele estar en cualquier kernel reciente):
ls -l /dev/kmsg
# Esperado: crw------- 1 root root 1, 11 ... /dev/kmsg
```

> Si `/dev/kmsg` no existe (raro, pero posible en entornos contenerizados), eliminar la línea correspondiente del `command:` y `devices:` en §5; cAdvisor arranca igualmente sin esa señal — sólo se pierden los OOM events por contenedor.

### 3.3. Pasar la Pi al cgroup driver `systemd` (verificación)

Docker en Raspberry Pi OS Bookworm usa `systemd` como cgroup driver por defecto desde [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md). Confirmar:

```bash
docker info --format '{{.CgroupDriver}}'
# Esperado: systemd
docker info --format '{{.CgroupVersion}}'
# Esperado: 2
```

> Si `CgroupDriver` fuera `cgroupfs`, cAdvisor sigue funcionando, pero los `name` de los cgroups en `/sys/fs/cgroup/` cambian de la jerarquía `system.slice/docker-<id>.scope` a `docker/<id>`. El dashboard 14282 está pensado para `systemd` (lo más común). Para `cgroupfs` no se ha probado; documentado por completitud.

---

## 4. Activar el `scrape_config` en `prometheus.yml`

`~/homelab/stacks/monitoring/prometheus.yml` (creado por [`./01-prometheus.md`](./01-prometheus.md) §4) ya contiene el placeholder del job de cAdvisor, comentado y con un puntero a este doc:

```yaml
  # ----- cAdvisor (./04-cadvisor.md) ------------------------------------------
  # Métricas por contenedor Docker (CPU, RAM, IO, network) — complementarias a
  # node-exporter (que ve "el host", no contenedores). ACTIVAR cuando el doc
  # cAdvisor despliegue el contenedor `cadvisor` en el stack.
  #
  # - job_name: 'cadvisor'
  #   metrics_path: /metrics
  #   static_configs:
  #     - targets: ['cadvisor:8080']
  #       labels:
  #         service: cadvisor
```

### 4.1. Descomentar el bloque

Editar `~/homelab/stacks/monitoring/prometheus.yml` y sustituir el bloque de placeholder por:

```yaml
  # ----- cAdvisor (./04-cadvisor.md) ------------------------------------------
  # Métricas por contenedor Docker (CPU, RAM, IO, network) — complementarias a
  # node-exporter (que ve "el host", no contenedores). ACTIVO desde el
  # despliegue del contenedor en docs/05-monitorizacion/04-cadvisor.md §5.
  - job_name: 'cadvisor'
    metrics_path: /metrics
    static_configs:
      - targets: ['cadvisor:8080']
        labels:
          service: cadvisor
```

> **No** se baja `scrape_interval` por debajo del global (30 s). cAdvisor cachea las muestras durante `--housekeeping_interval` (también 30 s en esta config), así que pedirle métricas más a menudo no aporta granularidad. La cardinalidad por scrape ya es la más alta del homelab; bajar el intervalo multiplicaría el coste del TSDB sin mejora visible.

> **Sin `metric_relabel_configs`**. La whitelist de container_labels y `--disable_metrics` se aplica en cAdvisor (más eficiente que filtrar en Prometheus tras el scrape). Si en el futuro aparece una serie ruidosa que cAdvisor no permita filtrar de origen, se añade aquí un `drop` con `regex:`.

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
  | grep -A3 "job_name: cadvisor"
# Esperado:
#   - job_name: cadvisor
#     metrics_path: /metrics
#     ...
```

> El target aparecerá en `https://prometheus.lan/targets` como **DOWN** (`connection refused`) hasta que el contenedor `cadvisor` esté levantado en §5. Es lo esperado.

---

## 5. `docker-compose.yml`

Editar `~/homelab/stacks/monitoring/docker-compose.yml` (extendido por [`./01-prometheus.md`](./01-prometheus.md) §5, [`./02-grafana.md`](./02-grafana.md) §7 y [`./03-node-exporter.md`](./03-node-exporter.md) §5) y **añadir** el bloque `cadvisor:` debajo del bloque `node-exporter:`. **No** se tocan los bloques `prometheus:`, `grafana:`, `node-exporter:`, ni el bloque `networks:`.

```yaml
# ~/homelab/stacks/monitoring/docker-compose.yml
# Stack: monitoring (../02-docker/02-estructura-compose.md §1.1).
#
# Estado tras este doc: cuatro servicios (`prometheus`, `grafana`,
# `node-exporter`, `cadvisor`).
# Los siguientes docs de Fase 5 (./05-uptime-kuma.md, ./06-dozzle.md)
# añadirán cada uno su servicio sin tocar los existentes.

name: monitoring

services:
  prometheus:
    # ... bloque sin cambios; ver ./01-prometheus.md §5 ...

  grafana:
    # ... bloque sin cambios; ver ./02-grafana.md §7 ...

  node-exporter:
    # ... bloque sin cambios; ver ./03-node-exporter.md §5 ...

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:${CADVISOR_IMAGE_TAG}
    container_name: cadvisor
    hostname: cadvisor
    restart: unless-stopped

    # Imagen oficial: USER root. Necesario para los bind mounts de
    # /sys/fs/cgroup y /var/lib/docker (ambos protegidos por root en el host).

    # No depende de Prometheus para arrancar: si Prometheus está caído,
    # cadvisor sigue sirviendo /metrics; el agujero queda en el TSDB.
    # No depends_on.

    env_file:
      - /mnt/hd2t/services/monitoring/.env
    environment:
      TZ: ${TZ}

    command:
      # Filtrar cgroups: sólo containers Docker, no system.slice / user.slice.
      - "--docker_only=true"

      # No copiar TODAS las labels Docker como labels de cada serie; conservar
      # sólo las útiles para agrupar dashboards y alertas.
      - "--store_container_labels=false"
      - "--whitelisted_container_labels=com.docker.compose.project,com.docker.compose.service,com.docker.compose.oneoff,com.centurylinklabs.watchtower.enable"

      # Desactivar familias de métricas no usadas por el dashboard 14282 ni
      # por queries del homelab. Cada una justificada en la tabla §0.
      - "--disable_metrics=referenced_memory,cpu_topology,resctrl,udp,advtcp,sched,hugetlb,process,percpu"

      # Alinear housekeeping con el scrape de Prometheus (30 s). Default 10 s.
      - "--housekeeping_interval=30s"

      # Discovery de nuevos contenedores cada 1 min (default).
      - "--global_housekeeping_interval=1m0s"

      # Sin storage propio: Prometheus es el único consumidor.
      - "--storage_driver="

      # Logs.
      - "--logtostderr=true"
      - "--v=0"

    volumes:
      # Receta canónica del README upstream
      # (https://github.com/google/cadvisor/blob/master/docs/running.md#docker).
      - type: bind
        source: /
        target: /rootfs
        read_only: true
        bind:
          create_host_path: false
          propagation: rslave

      - type: bind
        source: /var/run
        target: /var/run
        read_only: true
        bind:
          create_host_path: false

      - type: bind
        source: /sys
        target: /sys
        read_only: true
        bind:
          create_host_path: false
          propagation: rslave

      - type: bind
        source: /var/lib/docker/
        target: /var/lib/docker
        read_only: true
        bind:
          create_host_path: false

      - type: bind
        source: /dev/disk/
        target: /dev/disk
        read_only: true
        bind:
          create_host_path: false

      - type: bind
        source: /etc/machine-id
        target: /etc/machine-id
        read_only: true
        bind:
          create_host_path: false

    devices:
      # /dev/kmsg permite a cAdvisor leer los OOM-kills del kernel y exponerlos
      # como container_oom_events_total{name=...}.
      - "/dev/kmsg:/dev/kmsg"

    privileged: true
    # Justificado en la tabla §0: la receta canónica usa --privileged para
    # acceso completo a /sys/fs/cgroup y namespaces de los contenedores. Los
    # bind mounts son ro, y la red es bridge interno: la superficie real
    # queda acotada por la red.

    networks:
      - homelab

    mem_limit: 256m
    memswap_limit: 256m
    # Sin cpu_quota: cAdvisor consume <1 % CPU en idle; un quota artificial
    # haría más daño que bien si en el primer arranque enumera muchos
    # contenedores y necesita un pico breve.

    healthcheck:
      # /healthz responde 200 con "ok" cuando el HTTP server escucha y la
      # primera ronda de housekeeping ha terminado.
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:8080/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

    labels:
      com.centurylinklabs.watchtower.enable: "true"
      # NO labels homepage.*: cAdvisor no se publica por Caddy; Homepage
      # no debe mostrar un enlace que apunta a un host inalcanzable.

networks:
  homelab:
    external: true
```

### 5.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `image: gcr.io/cadvisor/cadvisor:${CADVISOR_IMAGE_TAG}` | Tag fijo desde el `.env`. Multi-arch oficial (incluye `linux/arm64`). Repositorio `gcr.io/cadvisor/cadvisor` es la ubicación oficial actual; `google/cadvisor` (Docker Hub) está deprecado y no recibe arm64. |
| `container_name: cadvisor` / `hostname: cadvisor` | Prometheus llama a `http://cadvisor:8080` por nombre Docker (placeholder ya configurado en `prometheus.yml`). Sin `container_name` el nombre real sería `monitoring-cadvisor-1`. |
| (sin `user:`) | La imagen oficial corre como root; necesario para leer `/sys/fs/cgroup/` y `/var/lib/docker/` (ambos restringidos a root en el host). Igual que con Prometheus, intentar `user: 1000:1000` rompe el agente sin ningún beneficio. |
| (sin `depends_on:`) | cAdvisor es deliberadamente desacoplado de Prometheus: arranca incluso si Prometheus está parado. Si Prometheus arranca después, simplemente reanuda los scrapes y el TSDB tendrá un gap acotado. |
| `env_file` ruta absoluta | Plantilla §6 de estructura-compose. Coherente con el resto del stack. |
| `command: --docker_only=true` | Sin esto, cAdvisor enumera **todos** los cgroups del sistema (system.slice, user.slice, sesiones systemd-logind...). Output `/metrics` ~3× más grande, con series duplicadas que ya cubre Node Exporter. |
| `command: --store_container_labels=false` + `--whitelisted_container_labels=...` | Por defecto cAdvisor copia cada label Docker como label de cada serie temporal: explosión de cardinalidad cuando se usan stacks compose con muchos labels (`org.opencontainers.image.*`, `traefik.*`, `homepage.*`, `com.docker.compose.config-hash` con su hash distinto cada despliegue, etc.). La whitelist conserva sólo las útiles. |
| `command: --disable_metrics=...` | Cada familia desactivada cubre un caso que el homelab no usa (justificado en la tabla §0). Reduce el TSDB ~40 %. |
| `command: --housekeeping_interval=30s` | Default upstream es `10s`. Con scrape Prometheus a 30 s, las muestras intermedias se descartan; subir el intervalo reduce la CPU media del proceso ~3× sin pérdida observable. |
| `command: --global_housekeeping_interval=1m0s` | Default. Discovery de nuevos containers cada 1 min: aceptable para un homelab donde los nuevos despliegues son humanos. |
| `command: --storage_driver=` | Vacío explícito para dejar claro que no se usa el storage interno (StatsD, BigQuery, etc.); Prometheus es el único consumidor. |
| `volumes: /:/rootfs:ro` | El colector `filesystem` enumera mountpoints abriendo el FS raíz del host (igual que en Node Exporter). `ro,rslave` mantiene la lectura segura. |
| `volumes: /var/run:/var/run:ro` | Da acceso al socket Docker (`/var/run/docker.sock`). cAdvisor lo usa para enriquecer las métricas con metadatos (image name, container labels). Read-only: el agente no llama a la API de "control" (start/stop), sólo a "list/inspect". |
| `volumes: /sys:/sys:ro` | Acceso a `/sys/fs/cgroup/` (las cuotas y estadísticas por cgroup) y a `/sys/class/net/` (interfaces de red). `rslave` propaga unmounts del host. |
| `volumes: /var/lib/docker/:/var/lib/docker:ro` | Permite a cAdvisor descubrir contenedores efímeros y leer detalles que el socket Docker no expone tan rápido. Sólo lectura. |
| `volumes: /dev/disk/:/dev/disk:ro` | Mapea identificadores `dm-X`/`mmcblk*` a sus device names humanos en las métricas de IO (`container_fs_reads_bytes_total{device="..."}`). Sin esto el dashboard muestra "dm-0", "dm-1" en vez de "mmcblk0p2" o "sda1". |
| `volumes: /etc/machine-id:/etc/machine-id:ro` | Identificador único del host. cAdvisor lo expone como label en algunas métricas (`machine_id`). Útil cuando se federa con otro Prometheus / segundo nodo. |
| `devices: /dev/kmsg:/dev/kmsg` | Acceso al canal de mensajes del kernel. cAdvisor parsea `kmsg` para detectar OOM-kills y exponerlos como `container_oom_events_total`. Sin esto, los OOM siguen yendo al `dmesg` del host pero no aparecen como métrica por contenedor. |
| `privileged: true` | Receta canónica upstream. Justificado en la tabla §0. La alternativa "fina" (cap_add SYS_ADMIN + apparmor=unconfined) funciona en kernels concretos pero rompe en otros; en un homelab personal, simplicidad y robustez ganan al ligero plus de hardening. |
| `networks: [homelab]` | Único networking. Resuelve `prometheus` por DNS interno del bridge. No se usa `network_mode: host` (cAdvisor no lo necesita: la información viene de cgroups y `/var/lib/docker`, no de tráfico de red). |
| `mem_limit: 256m` / `memswap_limit: 256m` | cAdvisor en idle reposa ~60–90 MB. El límite duro a 256 MB protege a la Pi de un leak; si se alcanza, Docker mata el contenedor y `restart: unless-stopped` lo levanta de nuevo. La pérdida de datos es 0 (Prometheus tiene un agujero de un scrape). |
| (sin `cap_drop`/`cap_add`/`security_opt`) | Con `privileged: true`, Docker concede todas las capabilities y desactiva seccomp/apparmor; añadir o quitar capabilities por encima no tiene efecto. Documentar `cap_drop: [ALL]` aquí daría una falsa sensación de hardening. |
| (sin `read_only:`) | cAdvisor escribe a `/tmp` y abre rutas en `/var/run/cadvisor*`. Forzar root FS read-only ha dado lugar a regresiones (issue #2944 y similares). Default lectura/escritura, acotado por los bind mounts del host (todos `ro`). |
| `healthcheck: /healthz` | El endpoint `/healthz` no requiere auth y responde 200 con `ok`. La imagen oficial trae `wget` busybox. `start_period: 30s` cubre el tiempo de la primera ronda de housekeeping en un homelab con ~30–40 contenedores. |
| `labels.watchtower.enable=true` | Justificado en la tabla §0. Patches de la rama 0.49.x son seguros. |
| (sin `labels.homepage.*`) | cAdvisor no se publica por Caddy; añadir un enlace en Homepage apuntaría a un host inalcanzable desde el LAN. |

### 5.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/monitoring

# Validar sintaxis del compose:
docker compose --env-file /mnt/hd2t/services/monitoring/.env config >/dev/null \
  && echo "Compose OK"

# Inspeccionar el bloque de cadvisor:
docker compose --env-file /mnt/hd2t/services/monitoring/.env config \
  | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
ca = d["services"]["cadvisor"]
print("PRIVILEGED:", ca.get("privileged"))
print("NETWORKS:", list(ca.get("networks", {}).keys()) if isinstance(ca.get("networks"), dict) else ca.get("networks"))
print("MEM_LIMIT:", ca.get("mem_limit"))
print("VOLUMES:")
for v in ca.get("volumes", []):
    print(" -", v)
print("DEVICES:", ca.get("devices"))
print("PORTS:", ca.get("ports"))
'
# Esperado: privileged=True, networks=[homelab], mem_limit=268435456 (256MB),
# 6 bind mounts, /dev/kmsg, sin ports.
```

> Si `compose config` emite "warning: variable not set", revisar el `.env` y `.env.example`: la variable `CADVISOR_IMAGE_TAG` debe existir en `/mnt/hd2t/services/monitoring/.env`.

---

## 6. Despliegue

### 6.1. Levantar el contenedor

```bash
cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d cadvisor
```

Salida esperada:

```
[+] Running 1/1
 ✔ Container cadvisor  Started
```

> **Sólo se levanta `cadvisor`** (`up -d cadvisor`): los otros tres servicios ya están corriendo y no necesitan recreate. El primer arranque puede tardar 10–30 s en estado `(starting)` mientras cAdvisor enumera todos los contenedores existentes.

### 6.2. Estado del contenedor

```bash
docker compose ps cadvisor
# Esperado:
# NAME       IMAGE                                STATUS                  PORTS
# cadvisor   gcr.io/cadvisor/cadvisor:v0.49.1     Up X (healthy)
```

Si tarda en `(healthy)` o entra en `(unhealthy)`:

```bash
docker compose logs cadvisor | tail -50
```

Eventos esperados en los logs:

```
I... cadvisor.go:... Storage driver = ""
I... factory.go:... Registering Docker factory
I... manager.go:... Created a manager using volume id ...
I... cadvisor.go:... Starting cAdvisor version: ... (build_date: ...)
I... cadvisor.go:... Listening on port 8080
```

> Si aparecen errores tipo `failed to get rootfs info: unable to find data in memory cache`: son benignos en los primeros segundos (el `housekeeping` aún no ha completado la primera ronda). Si persisten más allá del `start_period`, revisar §11.

### 6.3. Smoke test desde la red `homelab`

```bash
# Cualquier contenedor en homelab puede alcanzar cadvisor por nombre Docker.
# Usar prometheus o caddy indistintamente:
docker exec prometheus wget -qO- http://cadvisor:8080/healthz
# Esperado: ok

# Tamaño aproximado del payload /metrics (~200–500 KB con ~30–40 contenedores):
docker exec prometheus wget -qO- http://cadvisor:8080/metrics | wc -c
# Esperado: 100000–800000 (varía con número de contenedores y métricas activas).

# Algunas métricas clave:
docker exec prometheus wget -qO- http://cadvisor:8080/metrics \
  | grep -E '^container_(cpu_usage_seconds_total|memory_usage_bytes|start_time_seconds)\{' \
  | head
# Esperado: una línea por contenedor del homelab, con label name="<container_name>".
```

### 6.4. Smoke test desde el host

```bash
# cAdvisor NO debe ser alcanzable desde la IP del host:
curl -sf http://192.168.1.10:8080/metrics -m 2 ; echo "exit=$?"
# Esperado: exit=7 (connection refused) o exit=28 (timeout). Nunca 200.

docker port cadvisor
# Esperado: vacío (sin port mappings).
```

### 6.5. El target aparece UP en Prometheus

```
https://prometheus.lan/targets
```

Esperado: una nueva fila para el job `cadvisor`, target `cadvisor:8080`, estado **UP** (verde), `Last Scrape` reciente, `Scrape Duration` < 500 ms.

Por API:

```bash
docker exec caddy wget -qO- 'http://prometheus:9090/api/v1/query?query=up{job="cadvisor"}' \
  | python3 -m json.tool
# Esperado: una serie con value=1 y labels { job="cadvisor", instance="cadvisor:8080", service="cadvisor", ... }.
```

> El `Scrape Duration` de cAdvisor suele ser el más alto del homelab (50–300 ms vs <50 ms de los demás): es esperado por el volumen de series. Si supera 1 s, indica que cAdvisor está tardando demasiado en serializar `/metrics`; ver §11.

---

## 7. Provisioning del dashboard en Grafana

### 7.1. Docker / cAdvisor Compute Resources (Grafana.com #14282)

#### 7.1.1. Descargar el JSON

```bash
cd ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json

# revision=4 es la última al momento de escribir este doc.
# Revisar: https://grafana.com/grafana/dashboards/14282-cadvisor-exporter/
curl -fsSL \
  "https://grafana.com/api/dashboards/14282/revisions/4/download" \
  -o docker-cadvisor.json

# Verificar que es un JSON válido:
python3 -c 'import json; d=json.load(open("docker-cadvisor.json")); print("title:", d.get("title")); print("panels:", len(d.get("panels", [])))'
# Esperado:
#   title: Cadvisor exporter
#   panels: ~30
```

#### 7.1.2. Apuntar el JSON al UID `prometheus`

Igual que en [`./02-grafana.md`](./02-grafana.md) §6.3.2: sustituir `${DS_PROMETHEUS}` por el UID estable del datasource (`prometheus`) y limpiar las claves `__inputs/__elements/__requires` (incompatibles con provisioning):

```bash
cd ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json

# 1. Sustituir el placeholder:
sed -i 's/"\${DS_PROMETHEUS}"/"prometheus"/g' docker-cadvisor.json

# 2. Eliminar __inputs/__elements/__requires:
python3 - <<'PY'
import json
p = "docker-cadvisor.json"
d = json.load(open(p))
for k in ("__inputs", "__elements", "__requires"):
    d.pop(k, None)
json.dump(d, open(p, "w"), indent=2)
print("Cleaned:", p)
PY

# 3. Comprobación: no debe quedar ningún ${DS_*}:
grep -c '${DS_' docker-cadvisor.json
# Esperado: 0
```

> Algunos paneles del dashboard 14282 usan métricas que dependen de `--store_container_labels=true` (e.g. paneles agregados por `image`). Con la whitelist de §5 se conservan `com.docker.compose.project` y `com.docker.compose.service`, así que las agrupaciones por stack/servicio funcionan; las agrupaciones por `image` puede que muestren el `image` de cAdvisor como label (ya viene como label nativo de cAdvisor) sin problemas.

### 7.2. Verificar que Grafana lo ha cargado

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

- Debe aparecer "Cadvisor exporter" (o el título exacto del JSON) en la lista, con icono de candado provisioned.

---

## 8. Verificación

### 8.1. Contenedor sano

```bash
docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml ps cadvisor
# STATUS: "Up X (healthy)".
```

### 8.2. cAdvisor no escucha en el host

```bash
sudo ss -ltn | awk '$4 ~ /:8080$/'
# Esperado: vacío (no se publica al host).

docker port cadvisor
# Esperado: vacío.
```

### 8.3. `/metrics` responde y tiene las familias esperadas

```bash
# Familias presentes:
docker exec prometheus wget -qO- http://cadvisor:8080/metrics \
  | grep -E '^# HELP container_(cpu|memory|network|fs|oom|spec)' \
  | wc -l
# Esperado: >= 6 (cpu, memory, network, fs, oom, spec — al menos uno de cada).

# Familias ausentes (desactivadas por --disable_metrics):
docker exec prometheus wget -qO- http://cadvisor:8080/metrics \
  | grep -E '^container_(referenced_memory|cpu_topology|tasks_state)' \
  | wc -l
# Esperado: 0 (referenced_memory, cpu_topology, sched, hugetlb, process, percpu).
```

### 8.4. Las métricas reflejan los CONTENEDORES, no a sí mismo

```bash
# 1. Hay una serie por cada contenedor del homelab:
docker exec prometheus wget -qO- http://cadvisor:8080/metrics \
  | grep -E '^container_start_time_seconds\{' \
  | grep -oE 'name="[^"]+"' | sort -u
# Esperado: una línea por cada container_name del homelab (prometheus,
# grafana, node-exporter, cadvisor mismo, caddy, pihole, ...).

# 2. CPU usage de cAdvisor mismo coincide con `docker stats`:
echo "--- cadvisor según docker stats ---"
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' cadvisor
echo "--- cadvisor según cadvisor ---"
docker exec prometheus wget -qO- 'http://cadvisor:8080/metrics' \
  | grep -E '^container_memory_usage_bytes\{name="cadvisor"' | head -1
# Las cifras deben ser similares (mismo valor en bytes; cAdvisor expone bytes
# directos, docker stats redondea a MiB).

# 3. La whitelist de container_labels funciona:
docker exec prometheus wget -qO- http://cadvisor:8080/metrics \
  | grep -E '^container_start_time_seconds\{name="prometheus"' | head -1
# Esperado: una línea con labels que incluyen `container_label_com_docker_compose_project="monitoring"`
# y `container_label_com_docker_compose_service="prometheus"`. NO debe aparecer
# `container_label_org_opencontainers_image_*` (no estaba en la whitelist).
```

### 8.5. El job aparece UP en Prometheus

```bash
docker exec caddy wget -qO- 'http://prometheus:9090/api/v1/query?query=up{job="cadvisor"}' \
  | python3 -m json.tool
# Esperado: { "status":"success", "data": {"result": [{"metric": {..., "job":"cadvisor", "instance":"cadvisor:8080", "service":"cadvisor", ...}, "value": [..., "1"]}]} }

# Series por contenedor visible desde Prometheus:
docker exec caddy wget -qO- 'http://prometheus:9090/api/v1/query?query=count(container_start_time_seconds)' \
  | python3 -m json.tool
# Esperado: value entre 30 y 60 (depende de cuántos containers haya en el homelab).
```

### 8.6. El dashboard renderiza en Grafana

En `https://grafana.lan/dashboards`, abrir **Cadvisor exporter** (#14282):

- El panel "Containers running" debe mostrar el número de contenedores del homelab.
- El panel "CPU Usage" debe mostrar una serie por cada contenedor relevante (los más activos: caddy, prometheus, grafana, jellyfin si está, etc.).
- El panel "Memory Usage" debe mostrar valores entre 5 MB (Watchtower idle) y varios cientos de MB (Nextcloud, Jellyfin) según los servicios.
- El panel "Network I/O" debe mostrar tráfico al menos en `caddy` (que recibe peticiones) y `pihole` (consultas DNS).

Si un panel concreto muestra "No data":

- Click sobre el panel → **Inspect → Query** → ver la query PromQL.
- Pegarla en `https://prometheus.lan/graph` para confirmar si la métrica existe.
- Si la métrica no existe, revisar si está en `--disable_metrics` (§5). Algunos paneles asumen `process` o `percpu` activos; aceptable: el dashboard 14282 no es perfecto, pero los paneles principales (CPU, RAM, network, disk) sí dependen de métricas que el homelab sí emite.

### 8.7. Persistencia tras reboot

```bash
sudo reboot
# (esperar a que vuelva)

docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml ps cadvisor
# Esperado: cadvisor (healthy).

# El TSDB de Prometheus debe mostrar continuidad:
# en https://prometheus.lan/graph la query `container_start_time_seconds{name="cadvisor"}`
# devuelve un valor nuevo (más reciente) tras el reboot, y `up{job="cadvisor"}[1h]`
# muestra el hueco del downtime.
```

### 8.8. Lista de Verificación

Antes de pasar a [`./05-uptime-kuma.md`](./05-uptime-kuma.md):

- [ ] `docker compose ps cadvisor` → `Up X (healthy)`.
- [ ] `sudo ss -ltn | grep -E ':8080'` → vacío en el host.
- [ ] `docker exec prometheus wget -qO- http://cadvisor:8080/healthz` devuelve `ok`.
- [ ] `count(container_start_time_seconds)` en Prometheus está en torno al número real de contenedores del homelab.
- [ ] `container_memory_usage_bytes{name="cadvisor"}` está por debajo del `mem_limit` (256 MB).
- [ ] `container_oom_events_total` está expuesta como métrica (aunque suele valer 0 en operación normal).
- [ ] `https://prometheus.lan/targets` → fila `cadvisor` en estado **UP**.
- [ ] PromQL `up{job="cadvisor"}` devuelve `1` con etiquetas `cluster=homelab, host=pi5, service=cadvisor`.
- [ ] El bloque `cadvisor:` está en `~/homelab/stacks/monitoring/docker-compose.yml`; el `scrape_config` `cadvisor` está descomentado en `~/homelab/stacks/monitoring/prometheus.yml`; ambos versionados en git.
- [ ] `~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/docker-cadvisor.json` versionado en git.
- [ ] En `https://grafana.lan/dashboards` aparece "Cadvisor exporter" con paneles renderizando.
- [ ] Tras `sudo reboot`, el contenedor arranca y las series tienen continuidad (con el hueco esperado del downtime).

---

## 9. Backup

| Ruta | Qué contiene | Frecuencia |
|---|---|---|
| `~/homelab/stacks/monitoring/docker-compose.yml` (bloque `cadvisor:`) | Definición del servicio. | Versionado en git → `git push`. |
| `~/homelab/stacks/monitoring/prometheus.yml` (job `cadvisor`) | Scrape config. | Versionado en git. |
| `~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/docker-cadvisor.json` | Dashboard provisioned. | Versionado en git. |
| `/mnt/hd2t/services/monitoring/.env` (variable `CADVISOR_IMAGE_TAG`) | Tag de imagen pinneado. | Borg con cifrado en repo (junto al resto de variables del stack, [`./01-prometheus.md`](./01-prometheus.md) §9). |
| Estado del contenedor | (no aplica) | **Sin backup**. cAdvisor es stateless por diseño: no hay BD, no hay caché, no hay sesiones. Las métricas históricas viven en el TSDB de Prometheus, ya respaldado en [`./01-prometheus.md`](./01-prometheus.md) §9. |

> **Sin restore especial**: tras pérdida total, basta con `git clone` del repo de stacks + `docker compose up -d cadvisor`. El primer scrape (≤30 s después de levantar) repobla las series en el TSDB de Prometheus y el dashboard 14282 muestra datos en cuanto hay 2 puntos por contenedor.

---

## 10. Operaciones cotidianas

### 10.1. Activar una familia de métricas que se desactivó

Si un dashboard nuevo o una alerta requiere métricas en `--disable_metrics` (e.g. `percpu` para ver consumo por core), editar el `command:` quitando esa familia y recrear el contenedor:

```bash
# En docker-compose.yml, en el command: de cadvisor, cambiar:
#   - "--disable_metrics=referenced_memory,cpu_topology,resctrl,udp,advtcp,sched,hugetlb,process,percpu"
# por (sin `percpu`):
#   - "--disable_metrics=referenced_memory,cpu_topology,resctrl,udp,advtcp,sched,hugetlb,process"

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate cadvisor

# Confirmar que la métrica vuelve:
docker exec prometheus wget -qO- http://cadvisor:8080/metrics \
  | grep -E '^container_cpu_usage_seconds_total\{.*cpu="' | head
```

> **Coste**: cada familia activada multiplica la cardinalidad. `percpu` × 4 cores × 40 contenedores = 160 series adicionales sólo para esto. Documentar el `git commit` con el motivo del cambio y revisarlo si en los siguientes días el TSDB crece más rápido de lo habitual.

### 10.2. Añadir un container_label a la whitelist

```bash
# En docker-compose.yml, extender la lista de --whitelisted_container_labels:
#   - "--whitelisted_container_labels=com.docker.compose.project,com.docker.compose.service,com.docker.compose.oneoff,com.centurylinklabs.watchtower.enable,homepage.group"

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate cadvisor

# Verificar:
docker exec prometheus wget -qO- http://cadvisor:8080/metrics \
  | grep -E '^container_start_time_seconds\{name="homepage"' | head -1
# Esperado: una línea con `container_label_homepage_group="..."`.
```

### 10.3. Bajar el housekeeping_interval para diagnóstico fino

En un incidente puntual donde se quiere ver picos de CPU sub-30 s:

```bash
# En docker-compose.yml, cambiar:
#   - "--housekeeping_interval=30s"
# por:
#   - "--housekeeping_interval=5s"

# Y, en prometheus.yml, en el job 'cadvisor', añadir:
#   scrape_interval: 5s

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate cadvisor
docker exec caddy wget -q --post-data='' -O- http://prometheus:9090/-/reload

# Tras diagnosticar: revertir AMBOS cambios y volver a aplicar.
```

> Bajar el intervalo multiplica las muestras: pasar de 30 s a 5 s × 6 = 6× más datos en el TSDB. Aceptable durante minutos/horas, problemático si se deja una semana.

### 10.4. Subir el `--v` para troubleshooting

```bash
# En docker-compose.yml, cambiar:
#   - "--v=0"
# por:
#   - "--v=4"

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate cadvisor

# Tras diagnosticar: revertir y volver a recrear.
```

> `--v=4` lista cada llamada al socket Docker y cada lectura de cgroup. Útil para diagnosticar "por qué este contenedor no aparece en métricas"; volver a `0` después.

### 10.5. Upgrade manual

```bash
# Antes de cambiar el tag, leer:
# https://github.com/google/cadvisor/blob/master/CHANGELOG.md
# (busca "metric removed" / "metric renamed" en cada release).

sudo sed -i 's|^CADVISOR_IMAGE_TAG=.*|CADVISOR_IMAGE_TAG=v0.49.2|' \
  /mnt/hd2t/services/monitoring/.env

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env pull cadvisor
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate cadvisor

# Verificar:
docker compose ps cadvisor
docker logs cadvisor --tail 20
```

> Watchtower **sí** actualiza cAdvisor automáticamente a las 04:00 si el tag tiene una nueva digest. Patches (0.49.x → 0.49.y) son seguros (no hay schema, no hay BD). Para minors (0.49 → 0.50) y majors, el upgrade manual permite leer el CHANGELOG por si una métrica se renombra y romper el dashboard 14282 (caso documentado: `container_cpu_load_average_10s` se eliminó en v0.46).

### 10.6. Migrar a modo "no privileged" (variante futura)

Si una auditoría exige eliminar `privileged: true`, esta es la receta tentativa:

```yaml
    # Eliminar privileged: true.
    cap_drop:
      - ALL
    cap_add:
      - SYS_ADMIN          # /sys/fs/cgroup writes (no, sólo lecturas, pero algunos kernels lo exigen)
      - SYS_PTRACE         # leer /proc/<pid>/ns/* de otros contenedores
      - DAC_READ_SEARCH    # leer ficheros con perms restringidos
    security_opt:
      - apparmor=unconfined   # o un perfil custom
      - no-new-privileges:true
```

**Estado actual**: probado en kernels concretos (5.15 y 6.1 con cgroup v2), en otros (e.g. al usar cgroup v1) requiere ajustes adicionales. Por eso no es la opción por defecto del homelab. Documentar pruebas si se llega a hacer la migración.

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `docker compose up cadvisor` falla con `network homelab declared as external, but could not be found` | La red `homelab` no está creada. | Crearla según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2. |
| `docker compose up cadvisor` falla con `Mounts denied: ... /sys/fs/cgroup ...` o errores de bind mount | El path no existe (e.g. `/dev/disk` ausente en algún kernel minimal) o `create_host_path: false` y la ruta no está. | Comprobar `ls -ld /sys /var/run /var/lib/docker /dev/disk /etc/machine-id /dev/kmsg` en el host. Si alguno falta, ajustar el bloque `volumes:`/`devices:` o eliminar la entrada correspondiente (cAdvisor sigue funcionando con menos info). |
| `cadvisor` arranca pero `/metrics` está casi vacío (sólo unas pocas líneas `process_*`) | Falta `privileged: true` o algún bind mount crítico (`/sys`, `/var/lib/docker`). | Comparar con §5. `docker exec cadvisor ls /sys/fs/cgroup/` debe listar el árbol cgroup v2 (`cgroup.controllers`, `system.slice/`, ...). Si está vacío, el bind mount de `/sys` no llegó. |
| `cadvisor` arranca pero las métricas tienen `name=""` y los containers no aparecen identificados | `--docker_only=true` no se aplicó o `/var/run/docker.sock` no es accesible. | `docker exec cadvisor ls -l /var/run/docker.sock` debe listar el socket. Comprobar el `command:` y `volumes:`. |
| `container_oom_events_total` no aparece en `/metrics` | El device `/dev/kmsg` no se mapeó. | Revisar §5 (`devices: ["/dev/kmsg:/dev/kmsg"]`). En kernels donde no exista, eliminar la línea: el resto de métricas funciona. |
| El target `cadvisor` aparece **DOWN** con `connection refused` en `/targets` | El contenedor `cadvisor` no está sano o no resuelve. | `docker compose ps cadvisor` y `docker exec prometheus wget -qO- http://cadvisor:8080/healthz`. Revisar la red: `docker inspect cadvisor --format '{{json .NetworkSettings.Networks}}'` debe listar `homelab`. |
| El target aparece **UP** pero `Scrape Duration` >5 s y a veces falla con `context deadline exceeded` | cAdvisor está serializando demasiadas series en cada scrape. | Subir `scrape_timeout` del job a `30s` o, mejor, **reducir series**: añadir más familias a `--disable_metrics`, restringir más la whitelist de container_labels. Verificar con `cadvisor_scrape_duration_seconds` (auto-métrica) si está >2 s consistentemente. |
| `container_memory_usage_bytes` reporta valores absurdos (siempre 0 o picos a 16 EB) | Bug específico de v0.x con cgroup v2 / kernels antiguos (issue [#3082](https://github.com/google/cadvisor/issues/3082) y similares). | Pinnar a una versión donde sea conocido sano. Documentar en el CHANGELOG del repo del homelab. |
| `cadvisor` se queda colgado en estado `(unhealthy)` justo tras arrancar | `start_period: 30s` insuficiente porque el host tiene >50 contenedores. | Subir `start_period: 90s` en el healthcheck. La primera ronda de housekeeping escala con el número de containers. |
| El dashboard 14282 está casi todo vacío | El placeholder `${DS_PROMETHEUS}` no se sustituyó en el JSON. | Aplicar §7.1.2 (sed + limpieza de `__inputs`). Tras editar el JSON, esperar ≤30 s al refresh del provider de Grafana. |
| El dashboard 14282 muestra un panel "No data" para CPU per core | El homelab desactivó `percpu` en `--disable_metrics`. | Activarlo (§10.1) o aceptar el panel vacío (la mayoría del dashboard funciona sin `percpu`). |
| `cadvisor` consume CPU constante (>10 %) en idle | Algún colector caro está recorriendo todos los containers cada `housekeeping_interval`. Suele ser `disk` o `network` con muchos containers / muchas interfaces. | Subir `--housekeeping_interval` (60 s o 90 s). Si persiste, añadir `--disable_metrics=disk` temporalmente y observar. |
| `cadvisor` se reinicia en bucle por OOM (`exit 137`) | El `mem_limit: 256m` está justo. Pico al primer arranque con muchos containers. | Subir `mem_limit: 512m` y `memswap_limit: 512m`. Si persiste, hay un leak — pinnar versión y abrir issue upstream. |
| Watchtower actualiza la imagen y rompe un panel del dashboard 14282 | Cambio de minor con rename/eliminación de métrica. | Pin del tag en `.env` (ya hecho) **+** `watchtower.enable: "false"` temporal mientras se decide el upgrade. Se rebobina la imagen con `docker pull gcr.io/cadvisor/cadvisor:<tag-anterior>` + `up -d --force-recreate`. |
| `docker compose down && up -d` deja el contenedor en `Created` pero no `Started` | Bug intermitente de Compose con `privileged: true` y docker-compose CLI mezclados. | Forzar `docker compose up -d --force-recreate cadvisor`. |

---

## Referencias

- [cAdvisor — Repo y CHANGELOG (GitHub)](https://github.com/google/cadvisor)
- [cAdvisor — Imagen Docker oficial (gcr.io)](https://gcr.io/cadvisor/cadvisor)
- [cAdvisor — Documentación de "Running cAdvisor" (bind mounts canónicos)](https://github.com/google/cadvisor/blob/master/docs/running.md)
- [cAdvisor — Lista completa de métricas](https://github.com/google/cadvisor/blob/master/docs/storage/prometheus.md)
- [cAdvisor — Flags de línea de comandos](https://github.com/google/cadvisor/blob/master/docs/runtime_options.md)
- [Prometheus — Configuración de `scrape_configs`](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config)
- [Grafana.com — Dashboard "Cadvisor exporter" (#14282)](https://grafana.com/grafana/dashboards/14282-cadvisor-exporter/)
- [Linux kernel — cgroups v2](https://docs.kernel.org/admin-guide/cgroup-v2.html)
- [Awesome Prometheus alerts (catálogo de reglas, sección "Docker containers")](https://samber.github.io/awesome-prometheus-alerts/rules.html#docker-containers)
