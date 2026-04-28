# cAdvisor

## Descripción

Con `03-node-exporter.md` aplicado, Prometheus ya recibe métricas del **host** (CPU, RAM, disco, red, temperatura del SoC). Pero el homelab vive de contenedores: Stash, Jellyfin, Pi-hole, Caddy, Authelia, Prometheus, Grafana, Borgmatic… ~30 contenedores en régimen normal. Si Jellyfin se desboca y se come 6 GiB de RAM, Node Exporter ve "memoria del host bajando" pero **no** sabe quién es el culpable. Si la microSD se llena de logs de un contenedor ruidoso, `node_filesystem_avail_bytes` muestra el problema pero no su origen. La pregunta *"¿qué contenedor está consumiendo qué?"* sigue sin responderse desde Grafana, y se resuelve con `docker stats` por SSH — incompatible con la idea de homelab observable.

Este documento despliega **cAdvisor** (Container Advisor), el exporter de Google para métricas **por contenedor** sobre runtimes compatibles con cgroups (Docker, containerd, runc). Su rol concreto:

1. **Exponer en `http://cadvisor:8080/metrics`**, dentro de la red Docker `homelab`, una página OpenMetrics con cientos de series por contenedor activo: `container_cpu_usage_seconds_total`, `container_memory_usage_bytes`, `container_memory_working_set_bytes`, `container_network_receive_bytes_total`, `container_network_transmit_bytes_total`, `container_fs_*` (lectura/escritura por contenedor), `container_last_seen`, `container_start_time_seconds`, `machine_*` (capacidades del host: cores, memoria total, kernel) y un puñado de gauges de salud propios (`container_tasks_state`, `container_processes`).
2. **Etiquetar las series con metadatos significativos** (`name`, `image`, `id` y un subconjunto controlado de Docker labels — `com.docker.compose.project`, `com.docker.compose.service`, `homelab.role`) para que los dashboards puedan agrupar por servicio sin caer en cardinalidades absurdas.
3. **Cerrar el segundo target real de Prometheus** declarado en `prometheus.yml` (Fase 5, doc 01): el job `cadvisor` apuntando a `cadvisor:8080` pasa de `down` a `up` en cuanto este documento se aplica.
4. **Alimentar el dashboard "Cadvisor exporter" (ID 14282)** ya provisionado en Grafana (Fase 5, doc 02), que dibuja CPU/RAM/red/disco *por contenedor* — la vista "top contenedores que sufren" del homelab.

Lo que este documento **no** decide:

- **Métricas del sistema operativo del host** (CPU total, RAM total, temperatura del SoC, espacio libre en `hd5t`/`hd2t`). Eso vive en Node Exporter (`03-node-exporter.md`). cAdvisor mira contenedores; Node Exporter mira el host. Ambos son complementarios y los dashboards de Grafana los combinan en paneles separados.
- **Métricas internas de cada aplicación** (sesiones de Jellyfin, queries DNS de Pi-hole, peticiones HTTP de Caddy). Esas las exponen los servicios mediante sus propios `/metrics` o exporters específicos (Pi-hole exporter, MQTT exporter, `caddy { servers { metrics } }`), no cAdvisor. cAdvisor sólo ve "Jellyfin consume X CPU y Y RAM"; **por qué** las consume es responsabilidad del exporter del propio Jellyfin (cuando exista) o de los logs.
- **Health-check y disponibilidad** ("Jellyfin lleva 5 minutos caído"). Eso vive en Uptime Kuma (`05-uptime-kuma.md`); cAdvisor sólo emite métricas para los contenedores **que existen y están corriendo** — un contenedor parado simplemente desaparece de las series.
- **Logs en tiempo real** de los contenedores. Eso vive en Dozzle (`06-dozzle.md`); cAdvisor no es un agregador de logs.
- **Métricas de containerd o de pods** (Kubernetes, k3s). El homelab corre Docker Engine (no Kubernetes), así que cAdvisor se configura en modo `--docker_only=true`. Si en el futuro el homelab migrase a k3s, este flag se quitaría y cAdvisor empezaría a emitir métricas a nivel de pod sin reescribir nada más.
- **Exposición vía Caddy con login**. Igual que Node Exporter, cAdvisor es un endpoint puramente máquina-a-máquina: sólo Prometheus lo consume. La UI HTML que cAdvisor sirve en `:8080/` es secundaria (gráficas tiempo real ofrecidas por la propia herramienta, redundantes con Grafana). **No se crea drop-in en Caddy**, no se añade entrada en Authelia, y el contenedor no publica `ports:` al host. Para depurar a mano, el flujo es siempre `docker exec prometheus wget -qO- http://cadvisor:8080/metrics`.
- **Alertas** ("Jellyfin > 80 % CPU durante 10 minutos"). Las series están aquí desde hoy; las reglas de alerta son responsabilidad de Alertmanager, que no se despliega en Fase 5 (ver "Decisiones que no se toman" en `01-prometheus.md`).

Cuando este documento se haya aplicado, el operador puede:

- Ver en `https://prometheus.lan/targets` que el job `cadvisor` está `up` con instance `pi5`.
- Lanzar en el portal de Prometheus la query `count(container_last_seen{name!=""})` y obtener un valor cercano al número de contenedores corriendo (típicamente 8–15 al cerrar Fase 5; 25–35 al cerrar Fase 11).
- Abrir en Grafana el dashboard "Cadvisor exporter" (ID `14282`) y ver paneles con datos reales: CPU/RAM/red/IO **por contenedor**.
- Confirmar con `docker exec prometheus wget -qO- http://cadvisor:8080/metrics | wc -l` que el exporter responde y devuelve varios miles de líneas (proporcionales al número de contenedores activos).

> **Recordatorio de alcance**: cAdvisor escucha **solo** en la red Docker `homelab`; no publica `ports:` al host. La única forma de llegar a `:8080` es desde otro contenedor de la misma red Docker (en la práctica: Prometheus). Ningún cliente LAN, ningún cliente VPN, ningún proceso humano accede directamente al endpoint. La UI que cAdvisor sirve por defecto en la raíz queda **inalcanzable**, lo cual es deseable: la observabilidad del homelab es Grafana, no la UI lateral de un exporter.

---

## Requisitos Previos

- **Fase 2** completa (Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN=lan`).
- **`01-prometheus.md` aplicado**: el job `cadvisor` ya existe en `prometheus.yml` (apuntando a `cadvisor:8080`) y aparece como `down` esperando este documento. Tras `up -d` debe pasar a `up` sin tocar `prometheus.yml`.
- **`02-grafana.md` aplicado** (recomendado, no estricto): el dashboard "Cadvisor exporter" (ID `14282`) ya está provisionado y empezará a renderizar paneles en cuanto cAdvisor empiece a emitir.
- **`03-node-exporter.md` aplicado** (recomendado): no es dependencia técnica — Node Exporter y cAdvisor son independientes — pero el patrón de despliegue (procfs/sysfs montados, scrape verificado) ya está validado y este documento lo reutiliza tal cual.
- **Kernel del host** con cgroups habilitados. En Raspberry Pi OS Bookworm (kernel 6.6+) **cgroup v2** está activo por defecto en el `cgroup_unified_hierarchy` y montado en `/sys/fs/cgroup`. cAdvisor `v0.47+` soporta cgroup v2 sin gimnasias adicionales.
- **Docker Engine 20.10+** (real en Pi: `26.x` tras Fase 2). Las versiones modernas de Docker usan el cgroup driver `systemd` por defecto en bookworm; cAdvisor lee directamente el sysfs y no depende del driver.

Comprobaciones rápidas:

```bash
# La red Docker compartida existe
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Prometheus está corriendo y tiene el job `cadvisor` declarado en `down`
curl -ks https://prometheus.lan/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="cadvisor") | {health, scrapeUrl}'
# {
#   "health": "down",
#   "scrapeUrl": "http://cadvisor:8080/metrics"
# }

# El kernel monta cgroup v2 unified
mount | grep '^cgroup2 on /sys/fs/cgroup'
# cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursiveprot)

# /dev/kmsg existe (lo necesita cAdvisor para detectar OOM kills)
ls -l /dev/kmsg
# crw-rw---- 1 root adm 1, 11 ... /dev/kmsg

# El socket de Docker está donde cAdvisor lo espera
ls -l /var/run/docker.sock
# srw-rw---- 1 root docker 0 ... /var/run/docker.sock
```

---

## Decisión: imagen y versión

cAdvisor se distribuye desde el registro oficial de Google: `gcr.io/cadvisor/cadvisor`. Hay también un mirror histórico en `google/cadvisor` (Docker Hub) que **dejó de actualizarse en `v0.33`** y **no sirve** para Pi 5 (cgroup v2). Las imágenes oficiales modernas son multi-arch (`amd64`, `arm/v7`, `arm64`); para la Pi 5 (aarch64) se usa el manifest `arm64` automáticamente.

| Tag | Cuándo usar | Decisión aquí |
|---|---|---|
| `latest` | Demos. | Descartado (convención de Fase 2). |
| `v0.47.2` | Última `0.47.x`. | Aceptable, pero `v0.47.x` arrastra un bug en arm64 sobre cgroup v2 con `--docker_only=true` que produce métricas vacías intermitentes. |
| `v0.48.x` | Última `0.48.x`. | Aceptable; resuelve el bug de 0.47 pero introduce un cambio en `container_cpu_cfs_*` que rompe paneles antiguos. |
| `v0.49.1` | Versión exacta. | **Aceptado** como compromiso: arm64 estable, cgroup v2 sin sorpresas, dashboards 14282 y 193 funcionan tal cual. |
| `v0.50.x`+ | Cuando salgan. | Diferido: comprobar changelog antes de subir, especialmente `--disable_metrics` (los nombres han cambiado entre minors). |

> **Tag exacto en uso**: `gcr.io/cadvisor/cadvisor:v0.49.1`. Si en el momento de aplicar este documento existe una `v0.49.x` superior con changelog limpio (sin renombrado de métricas y sin nuevos colectores habilitados por defecto), se actualiza el tag aquí y en `docker-compose.yml`. **Nunca `latest`**, **nunca `google/cadvisor`** (mirror muerto).

> **Por qué cAdvisor y no `docker_stats_exporter` / Telegraf con plugin `docker` / `ctop` con `/metrics`**. `docker_stats_exporter` consulta el daemon vía API y heredera de su latencia; con 30 contenedores en un Pi 5 las llamadas `/containers/stats` se acumulan. Telegraf es válido pero rompe la convención "un exporter por dominio" (Fase 5 evita Telegraf, igual que evitó collectd en Node Exporter). `ctop` no es un exporter de Prometheus en sentido estricto (su `/metrics` es no oficial y no encaja con los dashboards estándar). cAdvisor es **el** estándar: lee directamente cgroups del kernel sin pasar por la API de Docker, soporta cgroup v2, lo mantiene Google y todos los dashboards comunitarios (`14282`, `193`, `893`) hablan su dialecto (`container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`).

---

## Decisión: cgroup v2, privileges y bind mounts

cAdvisor lee métricas de cuatro fuentes en el host:

1. **cgroup sysfs** (`/sys/fs/cgroup`) — la fuente principal en cgroup v2. Cada contenedor tiene su jerarquía y cAdvisor lee `cpu.stat`, `memory.current`, `memory.stat`, `io.stat`, etc.
2. **Procfs del host** (`/proc`) — para enumerar PIDs, namespaces y resolver `pid → cgroup → container`.
3. **Socket de Docker** (`/var/run/docker.sock`) — para enriquecer las métricas con metadatos del contenedor: `image`, `name`, `labels` (filtrados, ver "Decisión: cardinalidad").
4. **/dev/kmsg** — buffer del kernel; cAdvisor lo lee para detectar **OOM kills** y emitir `container_memory_failures_total{type="oom"}`.

La práctica estándar (la que documenta el README oficial de cAdvisor) requiere los siguientes bind mounts:

| Bind mount | Modo | Para qué |
|---|---|---|
| `/:/rootfs` | `ro` | Acceso al rootfs del host (resolución de paths absolutos de contenedores y volúmenes). |
| `/var/run:/var/run` | `ro` | Sockets de runtime (`docker.sock`, posiblemente `containerd.sock`). |
| `/sys:/sys` | `ro` | Sysfs del host. **Indispensable para cgroup v2** (cAdvisor lee `/sys/fs/cgroup/...`). |
| `/var/lib/docker/:/var/lib/docker` | `ro` | Metadatos de imágenes y contenedores (capa overlay, mapeos de volúmenes). |
| `/dev/disk/:/dev/disk` | `ro` | Metadata de discos para etiquetar `device=...` en métricas de IO. |
| `/etc/machine-id:/etc/machine-id` | `ro` | ID estable del host; se emite como label `boot_id`/`machine_id` en algunas series. |

Adicionalmente, hay que dar acceso al device `/dev/kmsg` (no es un bind mount, es un device node):

```yaml
devices:
  - /dev/kmsg
```

Y, hoy por hoy, **`privileged: true`** porque hay nodos sysfs (especialmente en cgroup v2 con `nsdelegate`) que el kernel sólo deja leer con CAP_SYS_ADMIN del namespace inicial. Es el patrón que recomienda el README oficial.

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| `privileged: true` | Lectura completa de sysfs y `/dev/kmsg` sin batallas. | El contenedor obtiene todas las capabilities; si fuera comprometido, el aislamiento es nulo. | **Aceptado**, con mitigaciones (ver abajo). |
| `cap_add: [SYS_ADMIN, DAC_READ_SEARCH]` y `security_opt: apparmor=unconfined` | Más granular que `privileged: true`. | En cgroup v2 + bookworm sigue dejando paneles "No data" en algunas series; depuración tediosa por arquitectura/kernel. | Descartado por ergonomía. |
| Sin privilegios extra | Mejor postura de seguridad teórica. | cAdvisor no funciona: emite warnings constantes y series vacías. | Descartado: rompe el caso de uso. |

**Mitigaciones para `privileged: true`**:

- Imagen oficial fija (`v0.49.1`), **nunca `latest`**, sin entrypoint custom — superficie de ataque es exactamente la del binario `cadvisor` upstream.
- Todos los bind mounts en `:ro` excepto los que el README marca como necesarios (todos `:ro` también, en este caso).
- Sin `ports:` publicados al host: el contenedor no es accesible desde fuera de la red Docker `homelab`.
- `read_only: true` en el filesystem raíz del contenedor + `tmpfs:` para `/tmp` (ver "Stack").
- Watchtower con `homelab.role: "metrics-exporter"` se encargará de refrescar la imagen cuando salga un patch upstream.

Resultado: **`privileged: true` + bind mounts `:ro` + endpoint sólo en red Docker**. La superficie efectiva expuesta a la LAN es cero; la postura de seguridad real es comparable a Node Exporter aunque el flag suene más ruidoso.

> **Por qué no `pid: host` ni `network_mode: host`**. cAdvisor **no** necesita compartir el namespace de PIDs ni el de red con el host: lo que lee son **cgroups** (vía sysfs montado) y **metadatos de Docker** (vía socket montado). Compartir PID o red sólo añadiría superficie sin habilitar nuevas métricas. Resultado: red Docker `homelab` con DNS estándar, sin `pid: host`. Si en el futuro Prometheus se moviera fuera de Docker, este patrón se mantiene (Prometheus tendría que entrar en la red `homelab` para alcanzar a cAdvisor — ya hoy es así).

---

## Decisión: cardinalidad — el problema central de cAdvisor

cAdvisor con configuración por defecto es **el peor enemigo de la TSDB de Prometheus** en un homelab. El motivo: emite docenas de métricas por contenedor con labels altamente combinatorios (`device`, `interface`, `cpu`, `id`, `image`, todos los Docker labels del contenedor — incluidos los de Compose: project, service, version, working_dir…) y, sin filtros, un solo Pi 5 con 30 contenedores puede pasar de **10 000 series activas** a más de **80 000** sólo por dejar `--store_container_labels=true` (default).

`01-prometheus.md` parte de la base de "TSDB sana = 10–20 k series totales". Salir de ese rango infla el WAL, multiplica los IOPS sobre `hd2t` y degrada la latencia de query del datasource en Grafana. Por tanto, en este homelab **cAdvisor se domestica de fábrica** con cuatro políticas:

### 1) Sólo Docker, no jerarquías arbitrarias del host

```text
--docker_only=true
```

Sin este flag, cAdvisor enumera **todas** las jerarquías de cgroup del host: las del propio Docker, las de systemd (`system.slice`, `user.slice`, `init.scope`, todas las `*.service` y `*.scope`), las de procesos sueltos. En un Pi 5 que también ejecuta SSH, cron, systemd-resolved, `pi5-poweroff.service` (ejemplo), etc., aparecen 50–100 cgroups extra **además** de los contenedores. Casi todas esas series son ruido (CPU al 0 %, RAM trivial) y multiplican cardinalidad. `--docker_only=true` deja sólo las jerarquías bajo `system.slice/docker-*` o `docker.slice/docker-*` (depende del cgroup driver) — exactamente lo que el dashboard 14282 dibuja.

### 2) Filtrado de Docker labels

```text
--store_container_labels=false
--whitelisted_container_labels=com.docker.compose.project,com.docker.compose.service,homelab.role
```

`--store_container_labels=false` desactiva el comportamiento por defecto de copiar **todos** los labels Docker del contenedor a series Prometheus. Con esto, contenedores Compose dejan de inflar series con `com.docker.compose.config-hash`, `com.docker.compose.container-number`, `com.docker.compose.depends_on`, `com.docker.compose.image`, `com.docker.compose.oneoff`, `com.docker.compose.project.config_files`, `com.docker.compose.project.working_dir`, `com.docker.compose.service`, `com.docker.compose.version`, etc.

`--whitelisted_container_labels=...` reintroduce **sólo** los labels útiles para los dashboards:

- `com.docker.compose.project` — útil para "agrupar por stack" (ej. `cadvisor`, `prometheus`, `grafana`).
- `com.docker.compose.service` — distingue múltiples contenedores dentro de un stack.
- `homelab.role` — label propio del homelab (`metrics-exporter`, `web-proxy`, `auth`, `media`, `dns`, etc.) declarado en cada `docker-compose.yml`. Permite queries del tipo "uso medio de CPU por rol" sin tocar cada `service`.

### 3) Desactivación de colectores costosos

```text
--disable_metrics=accelerator,cpu_topology,disk,hugetlb,memory_numa,percpu,referenced_memory,resctrl,sched,tcp,udp,advtcp,process,cpuset
```

Cada colector deshabilitado tiene una razón concreta:

| Colector | Por qué se desactiva |
|---|---|
| `accelerator` | GPU/TPU. El Pi 5 no tiene aceleradores discretos; el colector intenta enumerarlos, falla en silencio, no aporta nada. |
| `cpu_topology` | Series duplicadas (`container_cpu_*` ya existe sin partir por `cpu_id`). |
| `percpu` | Una serie `container_cpu_usage_seconds_total` **por core y por contenedor**. En un Pi 5 (4 cores) son 4× más series; el dashboard 14282 no las usa. |
| `cpuset` | Reproducible desde `cpu` con menos coste. |
| `disk` | Estadísticas de discos del host. Node Exporter ya las cubre con mejor calidad (`node_disk_*`). |
| `hugetlb` | Páginas grandes; el Pi 5 raramente las usa con cargas Docker estándar. |
| `memory_numa` | Topología NUMA. Pi 5 es uniforme; series siempre 0. |
| `referenced_memory` | Caro de calcular (paginación) y rara vez accionable. |
| `resctrl` | Control de cache LLC (Intel). No existe en ARM. |
| `sched` | Métricas del scheduler; ruidosas y no accionables sin contexto kernel. |
| `tcp` / `udp` / `advtcp` | Estadísticas de sockets por contenedor. Las pocas veces que importa, se mira el contenedor concreto con `ss` o `nstat`. |
| `process` | Lista de procesos por contenedor (`/proc/<pid>/...`); cardinalidad explosiva. |

Lo que **se mantiene activo** es la columna vertebral de cAdvisor: `cpu`, `memory`, `network`, `diskIO`, `oom_event`, `app` (apps detectadas vía cgroups). Suficiente para los paneles del 14282 y para el dashboard "Homelab Overview" propio.

### 4) Housekeeping intervals alineados con scrape

```text
--housekeeping_interval=30s
--max_housekeeping_interval=35s
--global_housekeeping_interval=30s
--allow_dynamic_housekeeping=false
```

Por defecto cAdvisor hace housekeeping cada **1 segundo** (`--housekeeping_interval=1s`), recolectando estadísticas tan rápido como puede. Eso era razonable cuando cAdvisor servía su UI propia con gráficos en tiempo real, pero el homelab lee cAdvisor sólo a través de Prometheus (cada 30 s). Hacer housekeeping cada segundo es 30× más trabajo del necesario:

- Más uso de CPU del propio cAdvisor (subido en torno a 6–10 % de un core a 1 s; baja a < 1 % a 30 s).
- Más calor en el SoC (medible: ~1 °C de diferencia sostenida).
- Más wear sobre el sysfs y los dispositivos `/dev/disk` (la lectura es barata pero constante).

Alinear `--housekeeping_interval` con el `scrape_interval` de Prometheus (30 s) es una decisión de eficiencia que no quita resolución a las queries: cuando Prometheus hace `scrape`, el último valor ya tiene como mucho 30 s de antigüedad. `--allow_dynamic_housekeeping=false` evita que cAdvisor decida por sí mismo "este contenedor está parado, voy a aumentar el intervalo" — la previsibilidad se prioriza sobre el ahorro extra.

> **Resultado de las cuatro políticas combinadas**. Un Pi 5 con 25 contenedores Compose pasa de ~30 000 series cAdvisor en config por defecto a ~3 000–5 000 series con esta config. La TSDB se mantiene en el rango sano definido por `01-prometheus.md` y los dashboards `14282` y "Homelab Overview" siguen renderizando todos sus paneles.

---

## Decisión: exposición y endpoint

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| `expose: ["8080"]` (red Docker, sin `ports:`) | Sólo accesible desde otros contenedores en `homelab`; superficie cero. Prometheus llega por DNS. | El operador no puede `curl http://192.168.1.10:8080/metrics` desde su laptop ni abrir la UI HTML de cAdvisor. | **Aceptado**. |
| `ports: ["8080:8080"]` | El operador puede curl-ear desde la LAN y abrir la UI. | Cualquier dispositivo de la LAN ve métricas detalladas de **todos** los contenedores (imagen, labels, comandos) — fingerprinting trivial del homelab. La UI de cAdvisor no tiene autenticación. | Descartado. |
| `ports: ["127.0.0.1:8080:8080"]` | Sólo accesible desde el host; permite `curl localhost:8080`. | Prometheus está en una red Docker, no llega a `127.0.0.1` del host. Mantener dos rutas (host + red Docker) sólo para depurar duplica complejidad. | Descartado. |
| Caddy + `(authelia_two_factor)` | UI accesible con login. | La UI de cAdvisor es redundante con Grafana (mismas series, mejor pintadas). Ceremonia sin valor. | Descartado. |

Resultado: **`expose: ["8080"]` y nada más**. Para depurar manualmente:

```bash
docker exec prometheus wget -qO- http://cadvisor:8080/metrics | head
# Útil para confirmar formato OpenMetrics y métricas presentes.

docker exec prometheus wget -qO- http://cadvisor:8080/metrics | grep -E '^container_(cpu|memory|network)' | head
# Top de las métricas vivas que el dashboard 14282 va a leer.
```

Si excepcionalmente se quiere **ver la UI HTML de cAdvisor** (para debug puntual), se levanta un override one-shot:

```bash
docker run --rm --network homelab -p 127.0.0.1:8080:8080 \
    --entrypoint /usr/bin/socat alpine/socat \
    TCP-LISTEN:8080,fork,reuseaddr TCP:cadvisor:8080
# Luego: ssh -L 8080:127.0.0.1:8080 pi5  → http://localhost:8080/
```

Es una válvula de escape, no parte del flujo normal.

---

## Stack: `stacks/cadvisor/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/cadvisor/docker-compose.yml` | microSD (git) | Stack (servicio `cadvisor`). |
| `stacks/cadvisor/.env.example` | microSD (git) | Plantilla (vacía hoy). |

> **Nota**: no hay drop-in en Caddy (ver "Decisión: exposición y endpoint"), no hay configuración propia (cAdvisor es 100 % flags) y no hay rutas en `hd2t`/`hd5t`: cAdvisor es completamente **stateless**.

### `stacks/cadvisor/docker-compose.yml`

```yaml
# cAdvisor — métricas por contenedor del homelab (Pi 5, cgroup v2).
# Documentado en docs/05-monitorizacion/04-cadvisor.md.

name: cadvisor

services:
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    container_name: cadvisor
    hostname: cadvisor
    restart: unless-stopped

    # No publica `ports:` al host: sólo accesible vía red Docker `homelab`.
    expose:
      - "8080"

    # Necesario en cgroup v2 + bookworm para leer todo el sysfs y /dev/kmsg.
    # Mitigaciones documentadas en "Decisión: cgroup v2, privileges y bind mounts".
    privileged: true

    # OOM kills del kernel: sin esto, container_memory_failures_total{type="oom"}
    # se queda a 0 y los paneles "OOM kills" del dashboard 14282 mienten.
    devices:
      - /dev/kmsg

    command:
      # --- Endpoint y operación ---
      - '--listen_ip=0.0.0.0'
      - '--port=8080'
      - '--log_dir=/var/log'
      - '--logtostderr=true'

      # --- Sólo Docker; ignorar systemd slices y cgroups arbitrarios ---
      - '--docker_only=true'

      # --- Cardinalidad: filtrado de Docker labels ---
      - '--store_container_labels=false'
      - '--whitelisted_container_labels=com.docker.compose.project,com.docker.compose.service,homelab.role'

      # --- Cardinalidad: colectores deshabilitados ---
      - '--disable_metrics=accelerator,cpu_topology,disk,hugetlb,memory_numa,percpu,referenced_memory,resctrl,sched,tcp,udp,advtcp,process,cpuset'

      # --- Housekeeping alineado con scrape_interval de Prometheus (30s) ---
      - '--housekeeping_interval=30s'
      - '--max_housekeeping_interval=35s'
      - '--global_housekeeping_interval=30s'
      - '--allow_dynamic_housekeeping=false'

      # --- Storage interno mínimo (cAdvisor no debe almacenar histórico:
      #     eso es trabajo de Prometheus). 1m es suficiente para que la UI
      #     interna funcione si alguien levanta el túnel de socat ---
      - '--storage_duration=1m'

    environment:
      TZ: ${TZ}

    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
      - /etc/machine-id:/etc/machine-id:ro

    networks:
      - homelab

    # FS raíz inmutable: cAdvisor no necesita escribir nada (logs van a stderr,
    # storage_duration=1m vive en memoria). Cualquier escritura desde un proceso
    # comprometido falla. /tmp se da como tmpfs por si alguna versión futura
    # del binario lo requiere.
    read_only: true
    tmpfs:
      - /tmp:size=8m,mode=1777
      - /var/log:size=8m,mode=0755

    healthcheck:
      # /healthz responde 200 OK en cuanto el binario está escuchando.
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:8080/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

    labels:
      homelab.role: "metrics-exporter"
      homelab.backup: "false"   # sin estado: el binario no persiste nada.
      com.centurylinklabs.watchtower.enable: "true"

networks:
  homelab:
    external: true
```

> **Sobre `start_period: 30s`**. cAdvisor en arm64 tarda más que Node Exporter en arrancar: enumera `/var/lib/docker`, abre `/dev/kmsg`, descubre cgroups. En un Pi 5 la primera respuesta a `/healthz` puede llegar a los 15–25 s del `up`. Con `start_period: 30s` el contenedor no se marca como `unhealthy` durante ese arranque legítimo.

> **Sobre `--storage_duration=1m`**. cAdvisor mantiene un buffer in-memory para servir gráficas en su UI HTML. Por defecto son 2 minutos; se baja a 1 minuto porque no hay UI consumiéndolo (Prometheus hace scrape y guarda él mismo). Reduce el RSS del proceso ~10–20 MiB en un Pi 5 con 25 contenedores.

> **Sobre `read_only: true` con `tmpfs`**. cAdvisor no escribe a disco en operación normal; se ata el FS raíz como `read_only: true` para defensa en profundidad. Las versiones recientes a veces escriben un fichero efímero a `/tmp` durante el self-check; un `tmpfs` minúsculo cubre ese caso sin abrir el FS raíz.

> **Sobre la ausencia de `user:`**. La imagen oficial corre como `root` por diseño (necesita CAP_SYS_ADMIN para sysfs en cgroup v2 con `nsdelegate`). No se fuerza `user: 65534:65534` porque rompe la lectura de varios nodos de sysfs en kernel 6.6 de bookworm.

### `stacks/cadvisor/.env.example`

```bash
# stacks/cadvisor/.env.example
# Variables específicas del stack cAdvisor. Las generales (TZ)
# vienen del .env GLOBAL del homelab.
#
# (Vacío en esta fase: cAdvisor no usa variables de entorno propias;
# toda su configuración va en flags del `command:` del compose.)
```

### Crear los directorios persistentes y desplegar

cAdvisor no necesita directorios en `hd2t`/`hd5t` (todo el estado vive en memoria del proceso o en la TSDB de Prometheus). El despliegue se reduce a:

```bash
# .env del stack (vacío en esta fase)
cd /home/homelab/homelab
cp stacks/cadvisor/.env.example stacks/cadvisor/.env
chmod 0600 stacks/cadvisor/.env

# Levantar cAdvisor
docker compose \
    -f stacks/cadvisor/docker-compose.yml \
    --env-file .env --env-file stacks/cadvisor/.env \
    up -d
```

Tras `up -d`:

```bash
docker ps --filter name=cadvisor
# CONTAINER ID  IMAGE                                 STATUS                  PORTS    NAMES
# ...           gcr.io/cadvisor/cadvisor:v0.49.1      Up 30 seconds (healthy)          cadvisor

docker compose -f stacks/cadvisor/docker-compose.yml logs --tail 30 cadvisor
# I... cadvisor.go:142] Starting cAdvisor version: v0.49.1
# I... container.go:127] Using factory "containerd" for container "/system.slice/..."
# I... factory.go:223] Using factory "raw" for container "/"
# I... factory.go:223] Using factory "docker" for container "/docker/<id>"
# I... cadvisor.go:172] Starting recovery of all containers
# I... cadvisor.go:178] Recovery completed
# I... cadvisor.go:209] Listening on port :8080
```

---

## Configuración

### 1) Verificar que Prometheus lo descubre

```bash
# Esperar uno o dos scrape intervals (30s+30s) y consultar el estado del target.
sleep 60
curl -ks https://prometheus.lan/api/v1/targets | \
    jq '.data.activeTargets[] | select(.labels.job=="cadvisor") | {health, lastError, lastScrape}'
# {
#   "health": "up",
#   "lastError": "",
#   "lastScrape": "2026-..."
# }
```

O desde la UI: `https://prometheus.lan/targets` → buscar `job=cadvisor` → `State: UP`. Esto **cierra** la segunda mitad de los exporters básicos de Fase 5; los siguientes `up{job=...}` que faltan corresponden a Caddy (Fase 3, ya desplegado pero con `metrics` activable) y a los exporters específicos de Fases 8+.

### 2) Queries útiles para verificar la instalación

Desde la pestaña `Graph` de Prometheus o desde el panel de queries de Grafana:

```promql
# 1) El target está vivo
up{job="cadvisor"} == 1

# 2) Contenedores activos (uno por contenedor "real"; el filtro name!="" excluye
#    el cgroup raíz y los infra de pause)
count(container_last_seen{name!=""})

# 3) Top 5 contenedores por uso de CPU (en cores, ventana 5m)
topk(5,
  sum by (name) (
    rate(container_cpu_usage_seconds_total{name!=""}[5m])
  )
)

# 4) Top 5 contenedores por memoria working_set (MiB)
topk(5,
  sum by (name) (
    container_memory_working_set_bytes{name!=""}
  ) / 1024 / 1024
)

# 5) Tráfico de red entrante por contenedor (KiB/s, ventana 5m)
sum by (name) (
  rate(container_network_receive_bytes_total{name!=""}[5m])
) / 1024

# 6) OOM kills históricos por contenedor (acumulado)
sum by (name) (
  container_oom_events_total{name!=""}
)

# 7) Agrupado por stack Compose (project)
sum by (container_label_com_docker_compose_project) (
  rate(container_cpu_usage_seconds_total{name!=""}[5m])
)

# 8) Agrupado por rol del homelab
sum by (container_label_homelab_role) (
  rate(container_cpu_usage_seconds_total{name!=""}[5m])
)
```

> **Sobre los nombres de label `container_label_*`**. Prometheus convierte los Docker labels (`com.docker.compose.project`, `homelab.role`) en labels Prometheus añadiendo el prefijo `container_label_` y reemplazando `.` y `-` por `_`. Por eso `homelab.role` aparece como `container_label_homelab_role` en las queries. Los dashboards `14282` y "Homelab Overview" ya usan estas convenciones.

### 3) Ver el dashboard "Cadvisor exporter" en Grafana

Desde un cliente de la LAN con la CA interna ya instalada:

```text
1. Abrir https://grafana.lan/
2. Login Authelia + TOTP si aún no hay sesión.
3. Dashboards → carpeta "Homelab" → "Cadvisor exporter".
4. En el selector de instance, elegir `pi5`.
5. Los paneles "Container CPU", "Container Memory", "Network usage",
   "Filesystem usage" se llenan en cuanto pasen 1–2 scrape intervals.
6. Verificar la tabla "Top containers by CPU" — debe listar los contenedores
   activos del homelab (cadvisor, prometheus, grafana, node-exporter, caddy,
   pihole, authelia, etc.) con porcentajes coherentes.
```

> **Si el dashboard pintara "No data"** y el target está `up`: lo más probable es que el JSON haya quedado con `datasource: "${DS_PROMETHEUS}"` (placeholder de la importación interactiva) en vez del UID estable `homelab-prometheus`. Procedimiento de corrección documentado en `02-grafana.md` ("Cómo importar un dashboard de grafana.com como JSON local").

### 4) Forzar un scrape manual desde Prometheus

```bash
# Desde el contenedor de Prometheus, hacia cadvisor por DNS Docker:
docker exec prometheus wget -qO- http://cadvisor:8080/metrics | head -20
# # HELP cadvisor_version_info A metric with a constant '1' value labeled by ...
# # TYPE cadvisor_version_info gauge
# cadvisor_version_info{cadvisorRevision="...",cadvisorVersion="v0.49.1",...} 1
# # HELP container_cpu_usage_seconds_total Cumulative cpu time consumed in seconds.
# # TYPE container_cpu_usage_seconds_total counter
# ...

# Total de líneas (orientativo: 3000–5000 con esta config y 25 contenedores;
# si pasas de ~10000, alguna decisión de cardinalidad se ha relajado y
# conviene revisar):
docker exec prometheus wget -qO- http://cadvisor:8080/metrics | wc -l

# Cardinalidad real desde Prometheus (cantidad de series del job cadvisor):
curl -ks "https://prometheus.lan/api/v1/query?query=count(\{job=\"cadvisor\"\})" | jq '.data.result'
```

### 5) Confirmar que el filtrado de cardinalidad se aplica

```bash
# Debe devolver SÓLO los tres labels whitelisted (compose project, compose service, homelab role):
docker exec prometheus wget -qO- http://cadvisor:8080/metrics \
  | grep '^container_cpu_usage_seconds_total{name="prometheus"' \
  | head -1
# container_cpu_usage_seconds_total{container_label_com_docker_compose_project="prometheus",container_label_com_docker_compose_service="prometheus",container_label_homelab_role="metrics",cpu="total",id="/docker/...",image="prom/prometheus:...",name="prometheus"} ...

# Si aparecieran labels como `container_label_com_docker_compose_config_hash`,
# `container_label_com_docker_compose_oneoff`, etc.: la flag
# --whitelisted_container_labels no se está aplicando. Revisar el `command:`
# y reconfirmar con `docker inspect cadvisor --format '{{range .Config.Cmd}}{{.}}{{"\n"}}{{end}}'`.
```

### 6) Operación diaria

| Acción | Comando |
|---|---|
| Verificar `up{job="cadvisor"}` | `https://prometheus.lan/graph?g0.expr=up%7Bjob%3D%22cadvisor%22%7D` |
| Ver salud del contenedor | `docker ps --filter name=cadvisor` |
| Tail de logs | `docker logs -f cadvisor` |
| Reiniciar cAdvisor | `docker compose -f stacks/cadvisor/docker-compose.yml restart cadvisor` |
| Tamaño del payload `/metrics` | `docker exec prometheus wget -qO- http://cadvisor:8080/metrics \| wc -c` |
| Listar métricas únicas | `docker exec prometheus wget -qO- http://cadvisor:8080/metrics \| grep -oE '^container_[a-z_]+' \| sort -u` |
| Cardinalidad en TSDB | `curl -ks 'https://prometheus.lan/api/v1/query?query=count(\{job=\"cadvisor\"\})' \| jq '.data.result[0].value[1]'` |
| Top contenedores por CPU (en vivo) | `https://grafana.lan/` → dashboard "Cadvisor exporter" → panel "Top by CPU" |

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/cadvisor/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/cadvisor/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/` | host | `root:root` | — | Rootfs del host, montado `:ro` como `/rootfs`. |
| `/var/run` | host | `root:root` | — | Sockets de runtime, montado `:ro`. Incluye `docker.sock`. |
| `/sys` | host (kernel) | `root:root` | (sysfs) | Sysfs del host, montado `:ro`. Fuente principal de cgroup v2. |
| `/var/lib/docker` | host | `root:root` | — | Metadata de imágenes/contenedores Docker, montado `:ro`. |
| `/dev/disk` | host | `root:root` | — | Metadata de discos, montado `:ro`. |
| `/etc/machine-id` | host | `root:root` | `0444` | ID estable del host, montado `:ro`. |

> **Tamaño esperado en disco**. Cero. cAdvisor no persiste nada (las métricas viven en la TSDB de Prometheus). El RSS del proceso en operación normal con 25 contenedores es ~80–120 MiB; el CPU steady state, < 1 % de un core gracias a `--housekeeping_interval=30s`.

> **Por qué todos los mounts son `:ro`**. cAdvisor lee, no escribe. `:ro` impide que un binario comprometido escriba en `/var/run/docker.sock` (con `:rw` un atacante podría crear contenedores arbitrarios), en `/var/lib/docker` (manipulación de imágenes) o en `/sys` (cambio de parámetros del kernel). El único sitio con potencial de escritura — `/tmp` y `/var/log` dentro del contenedor — está cubierto por `tmpfs`, así que tampoco escribe a la microSD ni a `hd2t`.

> **Por qué `/etc/machine-id`**. cAdvisor usa machine-id como label `boot_id` en `machine_*` métricas. Si no se monta, cAdvisor genera uno aleatorio en cada reinicio y los paneles que filtran por `boot_id` rompen continuidad histórica.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/cadvisor/docker-compose.yml`, `.env.example` | Versionados. |
| Decisiones (cardinalidad, colectores, exposure interna, privileged) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Por qué |
|---|---|---|
| (ninguna) | **No** | cAdvisor es completamente *stateless*. El único estado son las series en la TSDB de Prometheus, que se decidió **no** respaldar (ver `01-prometheus.md`, sección Backup). |

> **Política explícita: no hay estado propio que respaldar**. Si el contenedor se destruye, basta con `docker compose up -d` en otro Pi para recuperar el servicio. Las métricas históricas previas se quedan en la TSDB del Prometheus original (mientras éste exista) o se aceptan como pérdida (homologa a la política de Prometheus).

Procedimiento de restore tras pérdida del contenedor:

```bash
docker compose -f /home/homelab/homelab/stacks/cadvisor/docker-compose.yml up -d --force-recreate
# cAdvisor remonta /sys, /var/run, /var/lib/docker, abre :8080 y vuelve a aparecer
# como `up` en Prometheus al siguiente scrape interval (≤30s). Cero pérdida real.
```

Procedimiento de restore tras pérdida total:

1. Recrear Fase 1, 2, 5 (docs 01 y 02).
2. `docker compose -f stacks/cadvisor/docker-compose.yml up -d`.
3. Verificar en Prometheus: `up{job="cadvisor"} == 1`.
4. Verificar en Grafana: dashboard "Cadvisor exporter" con datos en < 1 minuto.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `up{job="cadvisor"} == 0` con `connection refused` | El contenedor está caído, o aún no escucha (arranque lento típico en arm64). | `docker ps --filter name=cadvisor`; si está `Up`, esperar 30 s más (start_period). Revisar `docker logs cadvisor`. |
| `up{job="cadvisor"} == 0` con `dial tcp: lookup cadvisor on 127.0.0.11:53: no such host` | El contenedor no está en la red `homelab`. | Confirmar `networks: - homelab` en el compose; `docker network inspect homelab` debe listar `cadvisor`. |
| Métricas `container_*` vacías o todos los valores a 0 | cgroup v2 + `nsdelegate` está bloqueando el sysfs sin privilegios. | Confirmar `privileged: true`; `mount | grep cgroup2` debe mostrar `nsdelegate`. Sin `privileged: true`, varios nodos quedan ilegibles. |
| `container_oom_events_total` siempre a 0 incluso con OOM kills reales | Falta `devices: - /dev/kmsg`. | Añadirlo y `up -d --force-recreate`. |
| Cardinalidad muy alta del job `cadvisor` (> 10 000 series) | Algún flag de cardinalidad no está aplicándose: `--store_container_labels=false` o `--disable_metrics=...`. | `docker inspect cadvisor --format '{{range .Config.Cmd}}{{.}}{{"\n"}}{{end}}'` debe listar los flags. Si faltan, revisar el `command:` del compose. |
| Una métrica concreta no aparece (p.ej. `container_network_receive_bytes_total`) | El colector que la produce está en `--disable_metrics=...`. | Revisar la lista deshabilitada. `network` **no** está deshabilitado en este homelab; si la métrica falta es por otra causa (contenedor con `network_mode: host`, que por definición no genera estas series). |
| Logs muestran `Failed to remove container ... : container not found` | cAdvisor intenta quitar de su buffer un contenedor que ya no existe. | Inocuo. Si se vuelve ruidoso, bajar `--storage_duration=1m` aún más (ej. `30s`). |
| Logs muestran `unable to load /sys/fs/cgroup/...` repetidamente | cgroup que el kernel ha eliminado entre dos housekeepings. | Inocuo cuando es transitorio (contenedores efímeros o restart). Si es persistente para un contenedor concreto, revisar si el contenedor usa `cgroup_parent` no estándar. |
| Tras `docker compose pull` la imagen "no actualiza" | gcr.io a veces tarda en propagar tags arm64. | Forzar tag concreto en el compose (`v0.49.1`), no usar floating; `docker pull gcr.io/cadvisor/cadvisor:v0.49.1`. |
| `/healthz` devuelve 404 | Versión de cAdvisor < 0.36 (no aplica aquí, pero en migraciones puede pasar). | Cambiar el healthcheck a `wget --spider http://127.0.0.1:8080/metrics` (responde 200 OK siempre que el binario esté arriba). |
| Memoria del contenedor sube a > 300 MiB y crece | Algún `--disable_metrics=...` se quitó y el colector caro está activo (`process`, `percpu`). | Reactivar la lista completa de exclusiones del compose; reiniciar. |
| Compose se queja `Error response from daemon: error gathering device information` al `up -d` | `/dev/kmsg` no existe (kernels custom muy minimalistas). | No aplicable a Pi 5 con Raspberry Pi OS (siempre presente). Si pasara, comentar `devices: - /dev/kmsg` y aceptar que `oom_events` queda en 0. |
| Caddy no tiene drop-in y el operador lo "echa de menos" | Decisión consciente: no se expone vía Caddy. | Para depurar a mano, usar `docker exec prometheus wget -qO- http://cadvisor:8080/metrics`. |

---

## Decisiones que **no** se toman en este documento

- **`pid: host` para cAdvisor**: cAdvisor lee `/proc` del host vía `/rootfs/proc` cuando lo necesita; añadir `pid: host` no habilita métricas nuevas y aumenta superficie. Se descarta.
- **Reemplazar `privileged: true` por `cap_add` granular**: en cgroup v2 + bookworm + arm64 hay nodos de sysfs que requieren CAP_SYS_ADMIN del namespace inicial; los caps granulares no bastan para todas las métricas. Reabrible cuando upstream documente una receta cap-only estable para arm64+cgroup v2.
- **Exposición de la UI HTML de cAdvisor con login Authelia**: ceremonia sin valor (Grafana cubre el caso de uso, mejor). Para depurar manualmente, se documentó la válvula de `socat`.
- **Métricas a 5 s o 15 s**: bajar `--housekeeping_interval` por debajo de 30 s entra en conflicto con `scrape_interval=30s` (datos muestreados que Prometheus nunca lee). Reabrible si se introduce un Prometheus secundario con `scrape_interval=5s` para una sesión de debugging puntual.
- **Activar el colector `process`** (lista de procesos por contenedor): cardinalidad explosiva (PIDs cambiantes) y rara vez útil con un Pi 5 controlado. Reabrible si en el futuro hay un servicio sospechoso que necesite este nivel de detalle (mejor: hacerlo ad-hoc con un cAdvisor secundario).
- **Re-etiquetado en `prometheus.yml` (`metric_relabel_configs`)** para reducir más la cardinalidad: ya se filtra de origen con `--store_container_labels=false`. Hacer un segundo filtro en Prometheus duplica trabajo y oculta lo que cAdvisor realmente emite. Reabrible si una versión futura de cAdvisor introduce una métrica indeseada que no se pueda desactivar con `--disable_metrics`.
- **Múltiples instances** (varios Pi, varios hosts). El homelab vive en una caja; el label `instance: 'pi5'` deja preparado el día que llegue un segundo nodo (`instance: 'pi5b'`).
- **Containerd directo (sin Docker)** vía `--containerd=...`. El homelab corre Docker Engine; `--docker_only=true` ya hace exactamente lo que se quiere. Reabrible si el homelab migrase a containerd standalone o k3s.
- **TLS y autenticación en cAdvisor** (`--http_auth_file`, `--http_digest_file`). El endpoint vive en una red Docker interna, sólo Prometheus lo consume. Añadir TLS aquí es ceremonia. Reabrible si en algún momento aparece un Prometheus en otra máquina y el scrape pasa por la LAN/Tailscale.
- **Per-contenedor `disable_metrics` distintos**: cAdvisor sólo permite una lista global. Si en el futuro un contenedor concreto necesita métricas de `process` y los demás no, la solución es un cAdvisor secundario con etiqueta distinta — no una capa de filtrado por contenedor.

---

## Verificación Final

Antes de pasar a `05-uptime-kuma.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/cadvisor/docker-compose.yml ps` | `cadvisor ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect cadvisor --format '{{.Config.Image}}'` | `gcr.io/cadvisor/cadvisor:v0.49.1` |
| Conectado a `homelab` | `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` | incluye `cadvisor` y `prometheus` |
| Sin puertos publicados al host | `docker port cadvisor` | salida vacía |
| Bind mounts del host correctos | `docker inspect cadvisor --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Mode}}){{"\n"}}{{end}}'` | `/ -> /rootfs (ro)`, `/var/run -> /var/run (ro)`, `/sys -> /sys (ro)`, `/var/lib/docker -> /var/lib/docker (ro)`, `/dev/disk -> /dev/disk (ro)`, `/etc/machine-id -> /etc/machine-id (ro)` |
| Endpoint `/metrics` responde (interno) | `docker exec prometheus wget -qO- http://cadvisor:8080/metrics \| head -1` | línea `# HELP cadvisor_version_info ...` o similar |
| `/healthz` responde 200 | `docker exec prometheus wget -qO- http://cadvisor:8080/healthz` | `ok` |
| Target Prometheus `up` | `curl -ks https://prometheus.lan/api/v1/targets \| jq '.data.activeTargets[] \| select(.labels.job=="cadvisor") \| .health'` | `"up"` |
| Cardinalidad en rango sano | `curl -ks 'https://prometheus.lan/api/v1/query?query=count(\{job=\"cadvisor\"\})' \| jq '.data.result[0].value[1]'` | número entre `1500` y `8000` (depende del nº de contenedores) |
| Filtrado de labels Compose aplicado | `docker exec prometheus wget -qO- http://cadvisor:8080/metrics \| grep -oE 'container_label_[a-z_]+' \| sort -u` | sólo `container_label_com_docker_compose_project`, `container_label_com_docker_compose_service`, `container_label_homelab_role` |
| Dashboard Grafana con datos | navegador → `https://grafana.lan/` → "Cadvisor exporter" → instance `pi5` | paneles "Container CPU/Memory/Network" con series no vacías |
| OOM detection vía `/dev/kmsg` | `docker inspect cadvisor --format '{{json .HostConfig.Devices}}'` | incluye `/dev/kmsg` |

---

## Referencias

- Repositorio cAdvisor: https://github.com/google/cadvisor
- Documentación oficial (flags y métricas): https://github.com/google/cadvisor/blob/master/docs/runtime_options.md
- Lista de métricas Prometheus: https://github.com/google/cadvisor/blob/master/docs/storage/prometheus.md
- Imagen oficial multi-arch: https://gcr.io/cadvisor/cadvisor (pin: `v0.49.1`)
- Dashboard Grafana "Cadvisor exporter" (ID 14282): https://grafana.com/grafana/dashboards/14282
- Notas sobre cgroup v2: https://github.com/google/cadvisor/blob/master/docs/development/release_notes.md
- Documentos relacionados:
  - `docs/05-monitorizacion/01-prometheus.md` — Prometheus consume `cadvisor:8080`.
  - `docs/05-monitorizacion/02-grafana.md` — dashboard `14282` provisionado por código.
  - `docs/05-monitorizacion/03-node-exporter.md` — patrón hermano (host vs contenedor).
  - `docs/02-docker/02-estructura-compose.md` — convenciones de stacks.
