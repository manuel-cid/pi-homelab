# cAdvisor (métricas de contenedores Docker)

## Descripción

Despliegue de **cAdvisor** (_Container Advisor_, proyecto Google) como _exporter_ canónico de métricas **por contenedor** del homelab: CPU (utilización por _cgroup_, _throttling_, _quota_/_period_), memoria (RSS, _cache_, _working set_, _swap_, _OOM kills_), red (bytes/paquetes/errores por interfaz **virtual** del contenedor), I/O de disco (lecturas/escrituras por _device_ y por _cgroup_), _filesystem_ del contenedor (ocupación de la capa _writable_ de `overlay2`), tiempo de arranque, _restart count_, _labels_ del contenedor… Todo lo que Node Exporter (`docs/05-monitorizacion/03-node-exporter.md`) **no** ve porque vive una capa por encima.

cAdvisor expone `/metrics` en `:8080` (HTTP plano) dentro de la red `homelab`; **Prometheus** (`docs/05-monitorizacion/01-prometheus.md`) lo _scrapea_ por DNS interno (`cadvisor:8080`) y **Grafana** (`docs/05-monitorizacion/02-grafana.md`) pinta el _dashboard_ **cAdvisor exporter** (ID `14282`), que este documento **provisiona** dejando caer su `.json` en el directorio que el _provider_ de _dashboards_ ya está vigilando.

Este documento **se suma al _stack_ `monitor`** ya operativo. No crea nada nuevo en `~/homelab/`: añade el servicio `cadvisor` al `docker-compose.yml` del _stack_, su `scrape_job` `cadvisor` al `prometheus.yml`, el JSON del _dashboard_ `cadvisor.json` al directorio de _dashboards_ de Grafana, y dos variables al `.env`/`.env.example`.

> **Alcance**: este documento despliega cAdvisor, lo conecta a la red `homelab`, lo expone a Prometheus por DNS interno, añade el _scrape_job_ correspondiente con `instance: pi5` como _label_ estable y provisiona el _dashboard_ `14282`. **No** lo expone vía Caddy (cAdvisor trae una UI propia en `/`, pero es de _debug_; el frontend humano del homelab es Grafana). **No** activa _métricas perf_/_NUMA_/_hugetlb_/_resctrl_ ausentes de la Pi 5 — se desactivan explícitamente con `--disable_metrics` para mantener `/metrics` _lean_ y evitar explosión de cardinalidad. **No** monitoriza contenedores fuera de Docker (no hay `containerd` / `podman` directos en este homelab), por lo que se activa `--docker_only=true`.

> **Recordatorio de red**: cAdvisor **no se publica al host** (no hay `ports:`). Vive en la red Docker `homelab` (`172.20.10.0/24`, `br-homelab`) y Prometheus lo alcanza por DNS interno (`cadvisor:8080`). Sin embargo, las métricas que ofrece son del **socket Docker** y de los **cgroups** de **todos** los contenedores del host (no sólo los de la red `homelab`): para eso monta `/sys`, `/var/lib/docker`, `/var/run` y `/` en modo lectura, y exige `privileged: true` por motivos que se justifican abajo.

---

## Requisitos previos

- `docs/05-monitorizacion/01-prometheus.md` completado: el _stack_ `monitor` existe en `~/homelab/monitor/`, Prometheus está `(healthy)`, y `https://prometheus.lan/targets` ya muestra al menos los _targets_ de Prometheus + Grafana + Node Exporter en `UP`. Este doc añade un cuarto.
- `docs/05-monitorizacion/02-grafana.md` completado: Grafana está `(healthy)`, el _datasource_ `Prometheus` aparece como `default` y el _provider_ `homelab` (`provisioning/dashboards/default.yml`) está escaneando `/var/lib/grafana/dashboards/*.json` cada 30 s.
- `docs/05-monitorizacion/03-node-exporter.md` completado: la convención `instance=pi5` ya está establecida; este doc la replica.
- `docs/02-docker/02-estructura-compose.md` completado: red `homelab` (`172.20.10.0/24`, `br-homelab`) creada y _externa_, `~/homelab/.env` con `TZ`, `PUID`, `PGID` y `HOMELAB_DOMAIN=lan` operativos.
- `docs/02-docker/04-watchtower.md` completado: Watchtower está vigilando con `WATCHTOWER_LABEL_ENABLE=true` (modo _opt-in_). Este doc activa la _label_ en cAdvisor — los _patch releases_ son seguros y los _minors_ se leen pero no bloquean.
- Conectividad saliente para descargar la imagen y el _dashboard_:

  ```bash
  docker pull --platform linux/arm64 gcr.io/cadvisor/cadvisor:v0.49.1 >/dev/null && echo OK
  curl -fsS -o /dev/null https://grafana.com/api/dashboards/14282/revisions/latest/download && echo OK
  ```

- Que el host **no** tenga ya un servicio escuchando en `:8080`:

  ```bash
  sudo ss -tulpn '( sport = :8080 )'
  ```

  Salida esperada: vacía. cAdvisor **no** publica `:8080` al host (sólo lo expone a `homelab`), pero conviene confirmar que ningún `cadvisor` instalado a la antigua usanza (vía binario suelto, _systemd unit_) lo ocupa antes del primer `up`. En la Pi 5 con Pi OS Bookworm el puerto suele estar libre.

- Pi OS Bookworm con **cgroup v2 unificado** activo (es lo que `docs/01-sistema/02-configuracion-inicial.md` deja por defecto). Confirmar:

  ```bash
  stat -fc %T /sys/fs/cgroup
  # cgroup2fs
  ```

  Si devuelve `tmpfs`, está en cgroup v1 híbrido — cAdvisor lo soporta, pero los _label sets_ cambian (`id="/docker/<sha256>"` vs `id="/system.slice/docker-<sha256>.scope"`) y los _dashboards_ públicos asumen v2. Migrar siguiendo `docs/01-sistema/02-configuracion-inicial.md`.

---

## Decisiones de diseño

### Por qué cAdvisor (y no `docker stats` / Telegraf-docker / Prometheus-docker-exporter)

| Candidato                         | Por qué se descarta                                                                                                                                                                                                                                                                                                  |
|-----------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **`docker stats` polled by script** | Funciona, pero el _output_ es texto formateado para humanos y la API de `docker stats` (vía socket) es _push_-only por _stream_: hay que mantener un proceso _scraper_ que la consuma y republique en formato Prometheus. Reinventar cAdvisor.                                                                                            |
| **Telegraf con `inputs.docker`**  | Modelo _push_ a InfluxDB; para Prometheus haría falta el _output_ `prometheus_client`, lo que duplica complejidad sin aportar nada. Y los _label sets_ de Telegraf no coinciden con los de cAdvisor (`container_cpu_usage_seconds_total` vs `docker_container_cpu_usage_percent`), rompiendo los _dashboards_ públicos.                  |
| **`prom/docker-exporter`** (_unofficial_) | Proyectos de un solo autor que llevan años sin mantenimiento (último _commit_ 2021). cAdvisor lleva activo desde 2014 (Google) y v0.49.x es de 2024.                                                                                                                                                          |
| **`docker_stats_exporter`**       | Usable pero limitado a las métricas que `docker stats` ofrece (CPU%, MEM%, NET I/O, BLOCK I/O agregados). cAdvisor ofrece la misma información **más** desglose por _cgroup_ subordinado, _throttling_ events, _OOM kills_, _filesystem layer_ y _per-process stats_ opcionales.                                                          |
| **Sólo `node_exporter`**          | Node Exporter ve _slices_ de _cgroup_ vía `/sys/fs/cgroup`, pero no asocia el _cgroup id_ al _container name_ ni al _image_. Sin esa correlación, las métricas son inservibles para "qué contenedor está consumiendo X". cAdvisor consulta el socket de Docker para hacer ese _join_ y exporta las métricas con `name`, `image`, `id` ya pegados. |

cAdvisor gana por:

- **Estándar de facto en Kubernetes**: kubelet integra cAdvisor de fábrica para sus métricas de pods. Como subproducto, todos los _dashboards_ públicos (`14282`, `193`, `893`, `11600`) y todas las reglas de PromQL canónicas asumen su _label set_ (`container_cpu_usage_seconds_total{name=...,image=...}`), funcionando _out-of-the-box_.
- **Multi-runtime**: soporta `docker`, `containerd`, `crio`, `lxc`. En el homelab usamos sólo Docker, así que activamos `--docker_only=true` para silenciar el resto.
- **Multi-arch ARM64 nativo**: la imagen oficial `gcr.io/cadvisor/cadvisor` se publica para `linux/arm64` desde `v0.45.0` (2022). En la Pi 5 con Pi OS Bookworm 64-bit no hay sorpresas.
- **Sin estado persistente**: las _stats_ se calculan al vuelo en cada _scrape_ (cAdvisor mantiene un _ring buffer_ corto en memoria, ~2 min, suficiente para servir _scrapes_ a 15 s; Prometheus es quien las persiste).
- **Watchtower opt-in tolerable**: los _patch releases_ (`v0.49.x → v0.49.y`) corrigen _bugs_ y son seguros; los _minors_ (`v0.49 → v0.50`) ocasionalmente renombran o desprecian alguna _metric family_ marcada como `experimental` (raro), por lo que se permite la actualización automática y se vigilan las _release notes_.

### Vivir en la red `homelab` (no `network_mode: host`)

Análogo al razonamiento de `docs/05-monitorizacion/03-node-exporter.md`. cAdvisor **no** necesita `network_mode: host` porque:

1. **Los datos de los contenedores** viven en `/sys/fs/cgroup`, en `/var/lib/docker` y en el socket Docker (`/var/run/docker.sock`), todos accesibles vía _bind mount_.
2. **Las métricas de red por contenedor** (`container_network_*`) las extrae cAdvisor de los _network namespaces_ de cada contenedor leyendo `/proc/<pid>/net/dev`. Para eso necesita ver los PIDs del host (de ahí `pid: host` — ver más abajo) y poder leer `/proc/<pid>/...`, lo cual obtiene montando `/` como `/rootfs:ro,rslave`. Con `pid: host` activo, los _proc fs_ ya pertenecen al _PID namespace_ del host y cAdvisor accede directamente; **no** hace falta cambiar el _network namespace_ del contenedor.
3. **Estar en `homelab`** mantiene la convención de _scrape_ por DNS interno (`cadvisor:8080`).

### `pid: host` y `privileged: true` — sí se usan, justificación

- **`pid: host`**: imprescindible. cAdvisor itera sobre _all running PIDs_ del host para descubrir contenedores y leer sus _cgroups_, _net namespaces_, _process stats_. Sin `pid: host`, sólo vería el _PID 1_ de su propio _namespace_ (el _entrypoint_ de la imagen) y reportaría métricas vacías.
- **`privileged: true`**: necesario por dos razones concretas en cgroup v2:
  1. Acceso de lectura a `/sys/fs/cgroup/<container_slice>/cpu.stat`, `memory.stat`, etc. En cgroup v2 el árbol `/sys/fs/cgroup` está montado como _read-only_ por _userns_ por defecto en muchos kernels; `privileged: true` lo bypasea (alternativa: `cap_add: [SYS_ADMIN, SYS_RESOURCE]` + `--security-opt apparmor=unconfined`, pero la combinación es frágil entre _kernel versions_).
  2. Lectura de `/dev/kmsg` para detectar _OOM kills_ del kernel (`container_oom_events_total`). El dispositivo `/dev/kmsg` requiere `CAP_SYSLOG` o equivalente.

  > **Riesgo aceptado**: `privileged: true` en un contenedor que monta el socket Docker y `/var/lib/docker:ro` es, efectivamente, _root_ en el host. Mitigaciones:
  >
  > - **Imagen oficial firmada de Google** (`gcr.io/cadvisor/cadvisor`) — no hay imágenes _community_ ni _forks_ en el _path_.
  > - **`read-only: true`** en el _root filesystem_ del contenedor (la imagen es _stateless_ — sólo escribe en `/tmp` durante el _shutdown_ para serializar el _ring buffer_, lo cual no nos importa).
  > - **Sin `network_mode: host`**: vive en `homelab`, así que no se publica al exterior.
  > - **Watchtower opt-in con `WATCHTOWER_LABEL_ENABLE`** (`docs/02-docker/04-watchtower.md`): la imagen se actualiza con _patch releases_ en cuanto Google publica.
  >
  > Es la concesión razonable. Las alternativas (`Sysdig agent`, `Falco` _userspace_) no resuelven el problema mejor y añaden _agentes_ permanentes con capacidades equivalentes.

### Imagen y _tag_

- **`gcr.io/cadvisor/cadvisor:v0.49.1`** — multi-arch con `linux/arm64`, imagen oficial publicada por Google en su _registry_ `gcr.io/cadvisor/`. Pinneada a versión completa (convención del homelab).
- **Por qué `gcr.io/cadvisor/cadvisor` y no `gcr.io/google-containers/cadvisor`**: la segunda fue la canónica hasta v0.36 (2021); a partir de ahí Google migró a `gcr.io/cadvisor/cadvisor` (proyecto promovido a _top-level_). La vieja sólo recibe _security backports_ esporádicos y no hay _tag_ con `linux/arm64` en sus últimas versiones.
- **Por qué `v0.49.1` y no `latest`**:
  - `v0.47.0` (jul 2023) introdujo soporte completo de cgroup v2 unificado; antes había _bugs_ con _swap accounting_ en kernels 5.15+.
  - `v0.48.1` (mar 2024) corrigió un _race_ en el descubrimiento de contenedores reciclados rápidamente.
  - `v0.49.1` (ago 2024) integra el _disable_metrics_ con la lista actualizada (`accelerator`, `resctrl`, `oom_event` opcionales) y pasa el _smoke test_ de la Pi 5 sin _warnings_.
  - Para un primer despliegue en 2026, `v0.49.x` es el _baseline_ esperado; `v0.50.x` y posteriores se permiten via Watchtower _opt-in_.
- **Watchtower opt-in** (`com.centurylinklabs.watchtower.enable: "true"`):
  - _Patch releases_ (`v0.49.x → v0.49.y`) son seguros a ciegas: bugfixes y mejora de _label cardinality_, sin renombrar métricas estables.
  - _Minor releases_ (`v0.49 → v0.50`) requieren leer las _release notes_ por si renombran/deprecan alguna _metric family_ que un _dashboard_ usa. En la práctica, los nombres "estables" (`container_cpu_usage_seconds_total`, `container_memory_usage_bytes`, `container_network_receive_bytes_total`, `container_fs_usage_bytes`) no cambian.
  - Si un _bump_ rompe el _dashboard_ `14282`, se pinnea atrás temporalmente con `cadvisor.image.tag` y se abre un _issue_ aguas arriba.

### Métricas: lista controlada (`--disable_metrics` agresivo)

cAdvisor por defecto activa **TODAS** las _metric families_ que el kernel y el runtime soportan, incluyendo varias que en una Pi 5 con un homelab modesto no aplican o disparan la cardinalidad:

| _Metric group_       | Estado en Pi 5            | Decisión        |
|----------------------|---------------------------|-----------------|
| `cpu`                | Esencial                  | **ON** (default)|
| `memory`             | Esencial                  | **ON** (default)|
| `network`            | Esencial                  | **ON** (default)|
| `diskIO`             | Útil (USB 3.0)            | **ON** (default)|
| `disk`               | Genera _filesystem stats_ por _device_ que duplica `node_exporter` | **OFF** (`--disable_metrics=disk`) |
| `accelerator`        | No hay GPU/TPU            | **OFF** |
| `cpu_topology`       | _Topology_ ya la da `node_exporter` | **OFF** |
| `hugetlb`            | _Huge pages_ no se usan en el homelab | **OFF** |
| `memory_numa`        | Pi 5 es UMA, no NUMA      | **OFF** |
| `referenced_memory`  | _Working set_ ya lo da `memory` | **OFF** |
| `resctrl`            | Intel-only, no aplica a ARM | **OFF** |
| `sched`              | _Scheduler stats_ caros y rara vez consultados | **OFF** |
| `process`            | Métricas por _PID_; explota cardinalidad | **OFF** |
| `tcp`                | _TCP connection states per container_; ya está en `node_exporter` | **OFF** |
| `udp`                | Idem `tcp`                | **OFF** |
| `advtcp`             | _TCP retransmissions advanced_; raramente útil | **OFF** |
| `perf_event`         | Contadores `perf` del kernel; agresivo y caro | **OFF** |
| `oom_event`          | _OOM kills_ del kernel    | **ON** (es lo único que `node_exporter` no ve correlacionado con un contenedor) |

Política: pasar **`--disable_metrics=accelerator,advtcp,cpu_topology,disk,hugetlb,memory_numa,perf_event,process,referenced_memory,resctrl,sched,tcp,udp`** y dejar los _enabled_ por defecto que sí queremos.

> **Por qué `disk` está en la lista de OFF pero `diskIO` está ON**: `--disable_metrics=disk` desactiva el `container_fs_*` global por _device_ del host (`/dev/sda1`, `/dev/sdb1` agregados); `diskIO` (que se llama así en la lista de `--disable_metrics`) son las métricas `container_blkio_*` por _cgroup_, que es lo que sirve para "qué contenedor está leyendo del disco". Confuso pero así es.
>
> **Excepción si en algún momento Stash/Jellyfin escriben mucho a `hd5t`/`hd2t` y hay que diagnosticarlo**: reactivar `disk` temporalmente y mirar `container_fs_writes_bytes_total{container=...,device=...}`. La activación es _backwards-compatible_: las _series_ existentes no cambian.

### `--store_container_labels=false` + `whitelisted_container_labels`

Por defecto, cAdvisor añade **TODAS** las _labels_ Docker de cada contenedor como _Prometheus labels_ a cada métrica. Si un contenedor tiene 30 _labels_ (la imagen base `linuxserver/*` añade ~10 propias, más las del _stack_, más las de Compose…), eso multiplica por 30 cada _metric family_, explotando la cardinalidad.

Política del homelab — **`--store_container_labels=false`** + lista explícita de las _labels_ que sí queremos preservar:

```
--store_container_labels=false
--whitelisted_container_labels=homelab.stack,homelab.backup,com.docker.compose.project,com.docker.compose.service
```

Resultado: las _label keys_ que se exportan a Prometheus son sólo cuatro (`container_label_homelab_stack`, `container_label_homelab_backup`, `container_label_com_docker_compose_project`, `container_label_com_docker_compose_service`), y la cardinalidad total de `container_*` queda en ~50-70 series por _metric family_ × ~15 contenedores = ~1000-1500 series totales en el TSDB (asumible).

> **Convención `homelab.stack`**: ya está aplicada en todos los servicios desde `docs/02-docker/02-estructura-compose.md`. Aquí se aprovecha para que el _dashboard_ `14282` agrupe contenedores por _stack_ (variable `$stack` en lugar de listar 15 contenedores planos). Si algún contenedor antiguo no la tiene, su métrica saldrá con `container_label_homelab_stack=""`.

### `--docker_only=true`

cAdvisor descubre contenedores escaneando `/sys/fs/cgroup` y deduciendo el runtime. Por defecto procesa **TODOS** los _slices_ que parezcan contenedores, incluyendo `system.slice/*` (servicios systemd), `user.slice/*` (procesos del operador) y `lxc.payload.*` (LXC). En un host con sólo Docker eso son ~30 _slices_ extra que ensucian `/metrics` con `container_*{id="/system.slice/ssh.service",...}` y similares.

Solución: `--docker_only=true`. Sólo se procesan _slices_ cuyo _cgroup path_ matchea con un contenedor Docker conocido (vía socket).

> **Si se añade Podman/containerd directamente** en el futuro (`docs/08-domotica/03-zigbee2mqtt.md` los considera y los descarta a favor de Docker), revisar este flag.

### `--housekeeping_interval=15s` y `--global_housekeeping_interval=1m0s`

- `--housekeeping_interval` (default `1s`): cada cuánto cAdvisor recolecta _stats_ por contenedor. A `1s` sobre 15 contenedores en una Pi 5 supone ~3% CPU constante. Subiéndolo a `15s` (alineado con el _scrape interval_ de Prometheus) baja a ~0.3%.
- `--global_housekeeping_interval` (default `1m`): cada cuánto cAdvisor _redescubre_ contenedores nuevos/eliminados. `1m` está bien — un contenedor que arranca tarda como mucho 60 s en aparecer, lo cual es aceptable.

> **Trade-off**: si bajamos `housekeeping_interval` por debajo del _scrape interval_, gastamos CPU para nada (Prometheus no va a leer más rápido). Si lo subimos por encima, perdemos resolución dentro de un _scrape_ (los _counters_ no se actualizan entre lecturas). `15s` = `scrape_interval` es óptimo.

### Acceso vía Caddy + Authelia — **no aplica**

A diferencia de Prometheus y Grafana, cAdvisor **no se expone vía Caddy**. Razones:

- **La UI nativa de cAdvisor** (en `/`) muestra árboles de _cgroups_, gráficas de _last 60s_ y poco más. Es útil para _debug_ puntual pero no algo que un humano consulte regularmente.
- **El consumidor legítimo es Prometheus**, que ya está en la red `homelab`.
- **El _dashboard_ `14282` en Grafana** ofrece toda la información en formato consumible y ya está protegido tras Authelia.

Si en algún momento el operador quiere ver la UI nativa "a ojo" (debug):

```bash
# Tunelar el puerto del contenedor al host por SSH:
ssh -L 8080:cadvisor:8080 pi.tailnet.ts.net
# Y abrir http://localhost:8080 en el navegador local.
```

O un `docker run --rm --network homelab` puntual con `curl` para `/metrics`:

```bash
docker run --rm --network homelab curlimages/curl:8.10.1 \
    -fsS http://cadvisor:8080/metrics | head -50
```

### Instance label estable: `pi5` (no `cadvisor:8080`)

Misma convención que en `docs/05-monitorizacion/03-node-exporter.md`. En el `scrape_config` del job `cadvisor`, sobrescribir `instance` con un valor estable mediante `relabel_configs`:

```yaml
relabel_configs:
  - target_label: instance
    replacement: pi5
```

Resultado: todas las series de cAdvisor llevan `instance=pi5`, coherente con `node_exporter`. El _dashboard_ `14282` filtra por `$instance` y, al unificar el _label_, los selectores funcionan _out-of-the-box_.

### Sin `healthcheck`

La imagen `gcr.io/cadvisor/cadvisor:v0.49.x` está construida sobre `distroless`: incluye el binario y unos pocos ficheros de _CA_, sin `sh`, sin `wget`, sin `curl`. cAdvisor **sí** expone `/healthz` en `:8080`, pero no podemos sondearlo desde dentro del contenedor.

Las opciones serían:

1. Cambiar a una imagen "fat" (la había hasta v0.46, basada en Alpine). Rechazado: la elegancia de `distroless` (sin _shell_, _attack surface_ mínima) se pierde por un _healthcheck_ marginal.
2. Usar un _healthcheck_ "from outside" via `docker exec`. Rechazado por la misma razón.
3. Confiar en el _healthcheck_ que ya hace **Prometheus**: si `up{job="cadvisor"} == 0` durante varios _scrapes_, Prometheus lo refleja en `/targets`, Grafana lo pinta y Uptime Kuma (cuando llegue, `docs/05-monitorizacion/05-uptime-kuma.md`) lo vigila.

Conclusión: **omitimos `healthcheck:` en el compose**. Documentado abajo y validado durante el despliegue por la propia métrica `up`.

---

## Almacenamiento

| Ruta en el host                                                         | Contenido                                                                  | Versionable | Backup |
|-------------------------------------------------------------------------|----------------------------------------------------------------------------|-------------|--------|
| `~/homelab/monitor/docker-compose.yml`                                  | Definición del _stack_ (modificada — servicio `cadvisor` añadido)          | git         | git    |
| `~/homelab/monitor/prometheus/prometheus.yml`                           | _Scrape_ `job_name: cadvisor` añadido                                      | git         | git    |
| `~/homelab/monitor/grafana/dashboards/cadvisor.json`                    | Dashboard `14282` con placeholder de _datasource_ sustituido               | git         | git    |
| `~/homelab/monitor/.env.example` y `.env`                               | `CADVISOR_IMAGE_TAG` añadido                                               | `.example` sí, `.env` no | git aparte (nota local) |

> **Sin estado persistente**: cAdvisor es _stateless_; mantiene un _ring buffer_ en memoria de ~2 min y se calculan los _counters_ al vuelo. La pérdida del contenedor se recupera en segundos con `make up STACK=monitor`. Las series **históricas** quedan en el TSDB de Prometheus (`/mnt/hd2t/services/prometheus/data/`), respaldadas por el plan de Prometheus.

---

## Estructura del _stack_ `monitor` tras este documento

```
~/homelab/monitor/
├── docker-compose.yml              # ← modificado (servicio 'cadvisor' añadido)
├── .env                            # ← modificado (CADVISOR_IMAGE_TAG)
├── .env.example                    # ← modificado (CADVISOR_IMAGE_TAG)
├── .gitignore                      # (sin cambios)
├── prometheus/
│   ├── prometheus.yml              # ← modificado (job_name 'cadvisor' añadido)
│   └── rules/
│       └── .gitkeep
└── grafana/
    ├── grafana.ini
    ├── provisioning/
    │   ├── datasources/
    │   │   └── prometheus.yml
    │   └── dashboards/
    │       └── default.yml
    └── dashboards/
        ├── prometheus-stats.json
        ├── node-exporter-full.json
        └── cadvisor.json           # ← nuevo
```

> **Sin subdirectorio `~/homelab/monitor/cadvisor/`**: cAdvisor no tiene ficheros de configuración propios — su comportamiento se define entero en los _flags_ del `command:` del compose. No hace falta un subdirectorio para él.

---

## Variables de entorno

Editar `~/homelab/monitor/.env.example` y añadir, debajo del bloque de Node Exporter:

```bash
# --- cAdvisor --------------------------------------------------------------
CADVISOR_IMAGE_TAG=v0.49.1
```

Reflejar en `~/homelab/monitor/.env` (no versionado):

```bash
cd ~/homelab/monitor
grep -q '^CADVISOR_IMAGE_TAG=' .env || cat >> .env <<'EOF'

# --- cAdvisor ---
CADVISOR_IMAGE_TAG=v0.49.1
EOF
chmod 0600 .env
```

> No hay secretos. cAdvisor no maneja credenciales; `/metrics` es accesible sin autenticación dentro de la red `homelab` (justificación: **Acceso vía Caddy + Authelia — no aplica** en _Decisiones de diseño_).

---

## Modificar `~/homelab/monitor/docker-compose.yml`

Añadir el servicio `cadvisor` debajo del de `node-exporter` (**no** sustituir: los bloques anteriores se quedan intactos):

```yaml
  # ---------------------------------------------------------------------------
  # cAdvisor — métricas por contenedor Docker (CPU, RAM, red, blkIO, OOM).
  # Vive en la red 'homelab'; los datos los lee del socket Docker, /sys/fs/cgroup
  # y /var/lib/docker. No publica :8080 al host: Prometheus lo scrapea por
  # DNS interno (cadvisor:8080).
  # docs/05-monitorizacion/04-cadvisor.md
  # ---------------------------------------------------------------------------
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:${CADVISOR_IMAGE_TAG}
    container_name: cadvisor
    hostname: cadvisor
    restart: unless-stopped
    # Imagen 'distroless' con el binario cAdvisor estático. Por defecto corre
    # como root; necesario para acceso a /sys/fs/cgroup y /dev/kmsg.
    privileged: true
    # PID namespace del host: necesario para iterar PIDs y leer /proc/<pid>/...
    # de cada contenedor (network namespace de cada uno).
    pid: host
    # Devices necesarios:
    #   /dev/kmsg → eventos OOM del kernel (container_oom_events_total).
    devices:
      - /dev/kmsg:/dev/kmsg
    command:
      # --- Ámbito --------------------------------------------------------
      # Sólo descubrir contenedores Docker (ignorar system.slice, user.slice).
      - --docker_only=true
      # No exportar todas las labels Docker como Prometheus labels (cardinalidad).
      - --store_container_labels=false
      # Conservar SÓLO las labels útiles del homelab + las de Compose.
      - --whitelisted_container_labels=homelab.stack,homelab.backup,com.docker.compose.project,com.docker.compose.service
      # --- Cadencia ------------------------------------------------------
      # Recolectar stats cada 15s (alineado con scrape_interval de Prometheus).
      - --housekeeping_interval=15s
      # Redescubrir contenedores nuevos/eliminados cada minuto.
      - --global_housekeeping_interval=1m0s
      # --- Métricas: desactivar las que no aplican a Pi 5 / homelab modesto.
      # Razonado en 'Decisiones de diseño > Métricas: lista controlada'.
      - --disable_metrics=accelerator,advtcp,cpu_topology,disk,hugetlb,memory_numa,perf_event,process,referenced_memory,resctrl,sched,tcp,udp
      # --- Endpoint ------------------------------------------------------
      - --port=8080
      - --listen_ip=0.0.0.0
      - --prometheus_endpoint=/metrics
      # --- Logging -------------------------------------------------------
      - --logtostderr=true
      - --v=0
    environment:
      TZ: ${TZ}
    volumes:
      # Read-only + rslave: cAdvisor ve los mounts/unmounts del host en caliente.
      - /:/rootfs:ro,rslave
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
      # Socket Docker en read-only para que cAdvisor consulte la API y haga el
      # join entre cgroup-id y nombre/imagen del contenedor.
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      homelab:
        aliases:
          - cadvisor
    labels:
      homelab.stack: "monitor"
      homelab.backup: "false"      # sin estado persistente
      # Patch releases seguros; opt-in. Lista del doc 02-docker/04-watchtower.md.
      com.centurylinklabs.watchtower.enable: "true"
    # Sin healthcheck: imagen 'distroless' sin shell ni wget/curl/nc para sondear
    # localhost:8080/healthz. El 'health' real lo mide Prometheus con
    # 'up{job=cadvisor}'. Justificación en docs/05-monitorizacion/04-cadvisor.md.
```

Notas de diseño extra:

- **`/var/run/docker.sock:ro`** monta el socket Docker en _read-only_ dentro del contenedor. cAdvisor sólo necesita **leer** (listar contenedores, inspeccionarlos, leer eventos); con `:ro` no puede crear/modificar/eliminar contenedores aunque escapase del _confinement_. Aun así, por culpa de `privileged: true`, un compromiso de cAdvisor sería _root_ en el host — el `:ro` es defensa en profundidad, no la barrera principal.
- **Sin `cap_add: SYS_TIME`** ni similares: `privileged: true` ya da todas las capacidades.
- **`--listen_ip=0.0.0.0`**: por defecto cAdvisor escucha sólo en `127.0.0.1`. Como el contenedor está en la red `homelab`, hay que escuchar en todas las interfaces para que Prometheus lo alcance vía DNS.
- **`labels.homelab.backup: "false"`**: sin estado, Borgmatic no debe respaldar nada de cAdvisor (porque no hay nada). El _label_ es informativo: el _hook_ de Borg que filtra por `homelab.backup` lo ignora.

---

## Modificar `~/homelab/monitor/prometheus/prometheus.yml`

Añadir el `scrape_config` `cadvisor` debajo del de `node`:

```diff
 scrape_configs:

   - job_name: 'prometheus'
     metrics_path: /metrics
     static_configs:
       - targets:
           - 'prometheus:9090'
         labels:
           service: prometheus
           stack:   monitor

   - job_name: 'grafana'
     metrics_path: /metrics
     static_configs:
       - targets:
           - 'grafana:3000'
         labels:
           service: grafana
           stack:   monitor

   - job_name: 'node'
     metrics_path: /metrics
     static_configs:
       - targets:
           - 'node-exporter:9100'
         labels:
           service: node-exporter
           stack:   monitor
     relabel_configs:
       - target_label: instance
         replacement: pi5

+  # -------------------------------------------------------------------------
+  # 4) cAdvisor — métricas por contenedor (CPU, RAM, red, blkIO, OOM events).
+  #    Lee de /sys/fs/cgroup, /var/lib/docker y del socket Docker.
+  #    'instance' se reescribe a 'pi5' para hacerlo estable a renombrados.
+  #    docs/05-monitorizacion/04-cadvisor.md
+  # -------------------------------------------------------------------------
+  - job_name: 'cadvisor'
+    metrics_path: /metrics
+    static_configs:
+      - targets:
+          - 'cadvisor:8080'
+        labels:
+          service: cadvisor
+          stack:   monitor
+    relabel_configs:
+      # Estabilizar el label 'instance' a 'pi5' (no al address del target).
+      - target_label: instance
+        replacement: pi5
+    metric_relabel_configs:
+      # Descartar las series sin 'name' (cgroups raíz '/', '/docker', etc.):
+      # cAdvisor exporta también el 'cgroup root' como container vacío.
+      # Esas series no aportan info útil para los dashboards y duplican
+      # cardinalidad x2.
+      - source_labels: [__name__, name]
+        regex: 'container_.+;'
+        action: drop
```

Validar y recargar Prometheus sin _restart_:

```bash
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
# Checking 4 scrape configs: SUCCESS

docker exec prometheus kill -HUP 1
# level=info ... msg="Loading configuration file"
# level=info ... msg="Completed loading of configuration file"
```

> **Sobre el `metric_relabel_configs > drop`**: cAdvisor exporta una serie `container_*` por cada _cgroup_ que ve, incluyendo los _roots_ vacíos (`/`, `/docker`, `/system.slice` cuando `--docker_only=false`, etc.). Esas series llevan `name=""` (label vacío). Aun con `--docker_only=true`, el _cgroup root_ `/` se sigue exportando con `name=""`. La regla `regex: 'container_.+;'` capta cualquier métrica que empiece por `container_` **y** tenga `name` vacío (el `;` es el separador del `__name__;name` concatenado por `source_labels`), y la descarta. Reduce ~50 series en el TSDB sin pérdida de información.

> **Orden estricto**: editar **antes** levantar el contenedor `cadvisor`, validar, levantar, y entonces recargar Prometheus (o al revés — recargar primero deja el _target_ en `DOWN` durante 15 s con error `dial tcp: lookup cadvisor: no such host` hasta que `make up` termine, lo cual ensucia los _logs_ pero no es destructivo). El procedimiento documentado abajo en _Despliegue_ recomienda el orden seguro.

---

## Añadir el _dashboard_ `cAdvisor exporter` (ID 14282)

```bash
# Descargar el JSON del dashboard canónico de Grafana Labs.
curl -fsSL \
    'https://grafana.com/api/dashboards/14282/revisions/latest/download' \
    -o ~/homelab/monitor/grafana/dashboards/cadvisor.json

# Sustituir el placeholder del datasource por el nombre real ('Prometheus'),
# tal y como hicieron los docs de Grafana (3662) y Node Exporter (1860).
sed -i 's/\${DS_PROMETHEUS}/Prometheus/g' \
    ~/homelab/monitor/grafana/dashboards/cadvisor.json

# Permisos coherentes con el resto de JSONs ya commiteados.
chmod 0644 ~/homelab/monitor/grafana/dashboards/cadvisor.json

# Validación de JSON: si falla, el provider de Grafana abortará la carga
# de TODOS los dashboards del provider 'homelab', no sólo de éste.
python3 -m json.tool ~/homelab/monitor/grafana/dashboards/cadvisor.json > /dev/null && echo OK

# Confirmar que el placeholder se sustituyó (debe ser 0):
grep -c 'DS_PROMETHEUS' ~/homelab/monitor/grafana/dashboards/cadvisor.json
# 0
```

> **Por qué `14282` y no `193` (el clásico de cAdvisor)**: ambos cubren las mismas métricas. `193` (mantenido por Brian Christner desde 2017) es histórico y muy popular, pero arrastra paneles que asumen Docker Swarm (`task_name`) y métricas pre-cAdvisor v0.40 (algunas renombradas hace años). `14282` (mantenido por _ssgreg_, ~800 _downloads/day_) está actualizado a v0.45+ y usa exclusivamente _label sets_ de cAdvisor moderno (`name`, `image`, `container_label_*`). Para una Pi 5 con cAdvisor `v0.49.x`, `14282` es la opción sin sorpresas.

> **El _provider_ recoge el JSON en <30 s**: gracias a `updateIntervalSeconds: 30` del `provisioning/dashboards/default.yml` (definido en `02-grafana.md`). No hace falta `restart` de Grafana.

---

## Despliegue

Orden seguro (evita _logs_ ruidosos durante 15-30 s entre pasos):

```bash
# 1) Editar los ficheros versionables ya descritos:
#    - ~/homelab/monitor/.env y .env.example   (CADVISOR_IMAGE_TAG)
#    - ~/homelab/monitor/docker-compose.yml    (servicio 'cadvisor')
#    - ~/homelab/monitor/prometheus/prometheus.yml (job 'cadvisor')
#    - ~/homelab/monitor/grafana/dashboards/cadvisor.json (curl)

# 2) Validar prometheus.yml sin tocar nada:
docker run --rm \
    -v ~/homelab/monitor/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
    -v ~/homelab/monitor/prometheus/rules:/etc/prometheus/rules:ro \
    --entrypoint promtool \
    prom/prometheus:v3.1.0 \
    check config /etc/prometheus/prometheus.yml
# Checking 4 scrape configs: SUCCESS

# 3) Validar el compose modificado:
docker compose -f ~/homelab/monitor/docker-compose.yml \
    --env-file ~/homelab/.env --env-file ~/homelab/monitor/.env \
    config | head -160

# 4) Levantar el nuevo servicio (sólo recreará 'cadvisor';
#    Prometheus, Grafana y Node Exporter siguen vivos):
cd ~/homelab
make up STACK=monitor
# o, equivalente:
docker compose -f ~/homelab/monitor/docker-compose.yml \
    --env-file ~/homelab/.env --env-file ~/homelab/monitor/.env \
    up -d cadvisor

# 5) Recargar Prometheus para que aplique el nuevo job_name:
docker exec prometheus kill -HUP 1
```

Verificar que cAdvisor levantó:

```bash
docker compose -f ~/homelab/monitor/docker-compose.yml ps
# NAME            STATUS
# prometheus      Up X minutes (healthy)
# grafana         Up Y minutes (healthy)
# node-exporter   Up Z minutes
# cadvisor        Up W seconds
# (sin '(healthy)' — no se define healthcheck, ver Decisiones de diseño)
```

Inspeccionar `/metrics` desde dentro de `homelab`:

```bash
docker exec prometheus wget -qO- http://cadvisor:8080/metrics | head -20
# # HELP cadvisor_version_info A metric with a constant '1' value labeled by kernel version, OS version, docker version, cadvisor version & cadvisor revision.
# # TYPE cadvisor_version_info gauge
# cadvisor_version_info{cadvisorRevision="...",cadvisorVersion="v0.49.1",dockerVersion="...",kernelVersion="...",osVersion="..."} 1
# # HELP container_cpu_usage_seconds_total Cumulative cpu time consumed in seconds.
# # TYPE container_cpu_usage_seconds_total counter
# ...
```

Confirmar el _target_ en Prometheus:

```bash
docker exec prometheus wget -qO- \
    'http://localhost:9090/api/v1/targets?state=active' \
    | python3 -c "import json,sys;d=json.load(sys.stdin);[print(t['labels']['job'],t['labels'].get('instance',''),t['health']) for t in d['data']['activeTargets']]"
# prometheus    prometheus:9090 up
# grafana       grafana:3000 up
# node          pi5 up
# cadvisor      pi5 up
```

> Si `cadvisor` queda como `cadvisor:8080` en lugar de `pi5`, la sección `relabel_configs` del `prometheus.yml` no se aplicó (probablemente por un YAML mal indentado). Validar y recargar.

Verificar la `up{job="cadvisor"}` directamente:

```bash
docker exec prometheus wget -qO- \
    'http://localhost:9090/api/v1/query?query=up{job=%22cadvisor%22}' \
    | python3 -m json.tool
# {"status":"success", ..., "result":[{"metric":{"__name__":"up","instance":"pi5","job":"cadvisor",...},"value":[..., "1"]}]}
```

Confirmar que cAdvisor está viendo los contenedores del homelab (sanity check):

```bash
docker exec prometheus wget -qO- \
    'http://localhost:9090/api/v1/query?query=count%20by%20(name)(container_last_seen)' \
    | python3 -m json.tool | head -40
# Debe listar todos los contenedores activos del host:
# prometheus, grafana, node-exporter, cadvisor, caddy, pihole, unbound,
# authelia, watchtower, portainer, ... (uno por contenedor)
```

Confirmar que la _label_ `homelab.stack` se está exportando:

```bash
docker exec prometheus wget -qO- \
    'http://localhost:9090/api/v1/label/container_label_homelab_stack/values' \
    | python3 -m json.tool
# {"status":"success","data":["monitor","red","seguridad", ...]}
```

---

## Verificación final

Antes de pasar a `docs/05-monitorizacion/05-uptime-kuma.md`, comprobar:

- [ ] `docker compose -f ~/homelab/monitor/docker-compose.yml ps` muestra `prometheus`, `grafana`, `node-exporter` y `cadvisor` en `Up`.
- [ ] `docker logs cadvisor --tail 50` muestra `Starting cAdvisor version: v0.49.1` y `Start cAdvisor REST API on port 8080`. **No** debe mostrar errores `failed to access /sys/fs/cgroup/...` (síntoma típico de cgroup v1 con _flags_ de v2, o de `privileged: false`).
- [ ] `docker exec prometheus wget -qO- http://cadvisor:8080/metrics | grep -c '^container_'` devuelve un número entre 500 y 2000 (15 contenedores × ~50-130 series por contenedor; <100 es síntoma de que `--docker_only=true` falló y descubrió todos los _slices_, o que algún _flag_ de `--disable_metrics` desactivó más de la cuenta).
- [ ] `docker exec prometheus promtool check config /etc/prometheus/prometheus.yml` devuelve `Checking 4 scrape configs: SUCCESS`.
- [ ] `https://prometheus.lan/targets` (tras login 2FA) muestra **cuatro** _targets_, todos `UP`: `prometheus`, `grafana`, `node` y `cadvisor` (este último con `instance="pi5"`, no `cadvisor:8080`).
- [ ] `https://prometheus.lan/graph?g0.expr=container_cpu_usage_seconds_total{name=%22prometheus%22}` (tras login 2FA) devuelve un _counter_ creciente (la CPU acumulada del propio Prometheus).
- [ ] `https://prometheus.lan/graph?g0.expr=container_memory_working_set_bytes{name=%22grafana%22}` devuelve un valor entre 50 MB y 200 MB (RAM real de Grafana en idle).
- [ ] `https://prometheus.lan/graph?g0.expr=count%20by%20(container_label_homelab_stack)(container_last_seen)` muestra los _stacks_ activos con sus _counts_: `monitor=4, red=N, seguridad=N, ...`.
- [ ] `https://grafana.lan/dashboards` (tras login 2FA) muestra **tres** _dashboards_ en la carpeta `Homelab`: `Prometheus 2.0 Stats`, `Node Exporter Full` y `Cadvisor exporter`.
- [ ] Abrir `Cadvisor exporter`: el _variable_ `instance` ofrece sólo `pi5`; el _variable_ `name` lista los contenedores reales del host (sin entradas vacías ni `/docker`); los paneles `CPU usage`, `Memory usage`, `Network I/O`, `Filesystem usage` muestran datos reales (no "No data") para al menos los contenedores `prometheus`, `grafana`, `node-exporter`, `cadvisor`.
- [ ] `container_oom_events_total` existe como _metric family_ aunque a `0` (`docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/series?match[]=container_oom_events_total'` debe devolver `data: []` o filas con valor `0`). Si devuelve `404`/error, el dispositivo `/dev/kmsg` no está montado correctamente.
- [ ] `container_*` con `name=""` **no** aparecen (el `metric_relabel_configs > drop` los está filtrando). Verificación:

  ```bash
  docker exec prometheus wget -qO- \
      'http://localhost:9090/api/v1/query?query=count(container_cpu_usage_seconds_total{name=%22%22})' \
      | python3 -m json.tool
  # "result":[]   ← deseado (0 series)
  ```

- [ ] Tras `docker compose restart prometheus`, el _scrape_ de cAdvisor vuelve a `UP` en <30 s y no se pierden series visiblemente en el _dashboard_ (gap de 1-2 _scrapes_ esperable).
- [ ] Tras un `sudo reboot` de la Pi, `cadvisor` arranca solo (`restart: unless-stopped`) y `up{job="cadvisor"}` vuelve a `1` en <60 s.
- [ ] `docker logs prometheus --tail 50 | grep -i error` no muestra errores nuevos relacionados con `cadvisor`.
- [ ] `git -C ~/homelab status` muestra como **modificados**: `monitor/docker-compose.yml`, `monitor/.env.example`, `monitor/prometheus/prometheus.yml`. Y como **nuevo**: `monitor/grafana/dashboards/cadvisor.json`. **No** muestra `monitor/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add monitor/docker-compose.yml monitor/.env.example \
          monitor/prometheus/prometheus.yml \
          monitor/grafana/dashboards/cadvisor.json
  git commit -m "feat(monitor): add cAdvisor with curated metric set and dashboard 14282"
  ```

---

## Operaciones habituales

### Ver `/metrics` a ojo

```bash
# Todas las métricas (filtrar con grep):
docker exec prometheus wget -qO- http://cadvisor:8080/metrics

# Sólo CPU del contenedor 'jellyfin':
docker exec prometheus wget -qO- http://cadvisor:8080/metrics \
    | grep '^container_cpu.*name="jellyfin"'

# Sólo memoria de los contenedores del stack 'monitor':
docker exec prometheus wget -qO- http://cadvisor:8080/metrics \
    | grep '^container_memory.*homelab_stack="monitor"'
```

### Acceder a la UI nativa de cAdvisor (debug puntual)

cAdvisor sirve en `/` un árbol de _cgroups_ con gráficas en vivo (últimos 60 s). Útil para confirmar visualmente que un contenedor está siendo monitorizado.

```bash
# Tunelar el puerto del contenedor al host por SSH+Tailscale:
ssh -L 8080:cadvisor:8080 pi.tailnet.ts.net
# Y abrir http://localhost:8080 en el navegador local. Cerrar tras debug.
```

> **No exponerlo vía Caddy** salvo necesidad muy puntual: la UI no tiene autenticación propia, y el _value-add_ sobre Grafana es marginal.

### Activar una _metric family_ desactivada

Por ejemplo, reactivar `disk` para diagnosticar I/O del host:

1. Editar `~/homelab/monitor/docker-compose.yml`, en el servicio `cadvisor`, eliminar `disk` de la lista `--disable_metrics`.

2. `docker compose -f ~/homelab/monitor/docker-compose.yml up -d cadvisor` (recreación, ~3 s de _downtime_ del _scrape_).

3. Verificar `container_fs_*` en Prometheus.

4. Tras la sesión de _debug_, volver a añadir `disk` a la lista y recrear.

### Whitelistear una nueva _label_ Docker

Por ejemplo, exportar `traefik.enable` (cuando Traefik o similares lleguen):

1. Editar el `command:` del servicio `cadvisor`:

   ```yaml
       - --whitelisted_container_labels=homelab.stack,homelab.backup,com.docker.compose.project,com.docker.compose.service,traefik.enable
   ```

2. `docker compose -f ~/homelab/monitor/docker-compose.yml up -d cadvisor`.

3. Verificar `container_label_traefik_enable` en Prometheus.

> **Cuidado con la cardinalidad**: cada _label_ nueva multiplica las series por su número de _values_ distintos. Sólo añadir _labels_ con _value space_ acotado (booleanas, enums); evitar _labels_ con valores libres (timestamps, UUIDs).

### Desactivar/activar `--docker_only` sin _restart_

No hay forma — los _flags_ se leen al arrancar. Hay que `docker compose up -d cadvisor` (recreación, ~3 s de _downtime_ del _scrape_).

---

## Backup

| Qué                                            | Dónde                                                       | Cómo                                            |
|------------------------------------------------|-------------------------------------------------------------|-------------------------------------------------|
| `docker-compose.yml`, `prometheus.yml`         | `~/homelab/monitor/`                                        | git                                             |
| `cadvisor.json`                                | `~/homelab/monitor/grafana/dashboards/`                     | git                                             |
| _Estado del propio cAdvisor_                   | (no aplica — _stateless_)                                   | n/a                                             |

> **Restauración**: clonar el repo, `make up STACK=monitor`, recargar Prometheus. En segundos vuelve a haber `up{job="cadvisor"} == 1` y el _dashboard_ vuelve a pintar. Las series **históricas** de cAdvisor están en el TSDB de Prometheus (`/mnt/hd2t/services/prometheus/data/`), respaldadas por el plan de Prometheus.

---

## Troubleshooting

### `cadvisor` arranca y muere en bucle: `Failed to start manager: failed to create a manager: ...cgroup...`

Causa típica: cgroup v1 híbrido en el host con _flags_ asumiendo cgroup v2 unificado. Confirmar:

```bash
stat -fc %T /sys/fs/cgroup
# cgroup2fs   ← deseado (Pi OS Bookworm por defecto)
# tmpfs       ← cgroup v1 híbrido; migrar siguiendo docs/01-sistema/02-configuracion-inicial.md
```

Solución: añadir `systemd.unified_cgroup_hierarchy=1` a `/boot/firmware/cmdline.txt` y reiniciar. Documentado en `docs/01-sistema/02-configuracion-inicial.md`.

### `cadvisor` arranca pero `/metrics` no expone `container_oom_events_total`

El dispositivo `/dev/kmsg` no se montó. Confirmar:

```bash
docker exec cadvisor ls -l /dev/kmsg
# crw------- 1 root root 1, 11 Apr 26 10:00 /dev/kmsg
```

Si no existe: revisar la sección `devices:` del compose. Debe ser `devices: ["/dev/kmsg:/dev/kmsg"]`. Si existe pero `container_oom_events_total` sigue ausente, el binario cAdvisor no tiene permisos de lectura — síntoma de que `privileged: true` está mal escrito (`privileged: "true"` con comillas no funciona; es booleano YAML).

### `cadvisor` arranca pero `/metrics` muestra cientos de series con `id="/system.slice/..."`

`--docker_only=true` no se aplicó. Causas típicas:

1. **Sintaxis `--docker-only` (con guion) en vez de `--docker_only`**: cAdvisor usa `_` en sus _flags_, no `-`. Confirmar:

   ```bash
   docker exec cadvisor cat /proc/1/cmdline | tr '\0' '\n' | grep docker
   # Debe mostrar '--docker_only=true'.
   ```

2. **YAML mal anidado**: el _flag_ acabó en otro servicio. Validar con `docker compose ... config`.

### El _target_ `cadvisor` aparece en Prometheus pero `up=0` con `error="dial tcp: lookup cadvisor on 127.0.0.11:53: no such host"`

`cadvisor` no está en la red `homelab`. Confirmar:

```bash
docker network inspect homelab --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}'
# Debe listar 'cadvisor'.
```

Si no aparece: revisar la sección `networks:` del servicio en el compose. Debe ser `networks: { homelab: { aliases: [ cadvisor ] } }`.

### El _dashboard_ `Cadvisor exporter` aparece pero los paneles dicen "No data"

Causas en orden de probabilidad:

1. **Placeholder `${DS_PROMETHEUS}` no sustituido**:

   ```bash
   grep -c 'DS_PROMETHEUS' ~/homelab/monitor/grafana/dashboards/cadvisor.json
   # 0 si todo bien; >0 = problema.
   ```

   Repetir el `sed -i 's/\${DS_PROMETHEUS}/Prometheus/g' ...` y esperar 30 s al re-_provisioning_.

2. **`instance` no se reescribió a `pi5`**: el _dashboard_ filtra por `$instance`, y si no hay opción `pi5` selecciona la primera (`cadvisor:8080`) que también funciona, pero algunos paneles que filtran por `instance=~"pi5"` quedan en blanco. Verificación con `wget -qO- 'http://localhost:9090/api/v1/label/instance/values'`.

3. **Métricas desactivadas que el _dashboard_ usa**: `14282` no usa `process`, `tcp`, `udp`, `perf_event` etc., así que la lista de `--disable_metrics` propuesta es compatible. Si en algún momento se añade `disk` a la lista de _disabled_, los paneles `Filesystem usage` quedan en blanco — reactivar `disk`.

### `container_fs_*` no aparece para algunos contenedores

cAdvisor sólo reporta `filesystem stats` para contenedores cuyo _root_ esté en `overlay2` (el _storage driver_ por defecto de Docker en Pi OS Bookworm). Si algún contenedor usa `volumes:` con `tmpfs` como _root_ (raro), no aparecerá. Confirmar:

```bash
docker info --format '{{.Driver}}'
# overlay2
```

### `container_*` siguen apareciendo con `name=""`

El `metric_relabel_configs > drop` no se aplicó correctamente. El _regex_ `'container_.+;'` requiere que el separador entre `__name__` y `name` sea `;` (separador por defecto de Prometheus). Si se cambió `separator:` en el _scrape_config_, el patrón hay que ajustarlo. Validar:

```bash
docker exec prometheus wget -qO- \
    'http://localhost:9090/api/v1/query?query=count(container_cpu_usage_seconds_total{name=%22%22})' \
    | python3 -m json.tool
# "result":[]   ← deseado (0 series)
```

Si sigue >0, recargar Prometheus tras editar el `prometheus.yml`.

### Cardinalidad sigue creciendo tras añadir cAdvisor

Esperable: ~50-130 series nuevas por contenedor (CPU × cores × modes + memoria × stat + network × interface + blkio × device + filesystem × mountpoint + …). En la Pi 5 con ~15 contenedores y la lista del homelab, total estimado <2000.

Si crece a >10000: probablemente algún _flag_ de cardinalidad falló:

```bash
docker exec prometheus wget -qO- \
    'http://localhost:9090/api/v1/query?query=count%20by%20(__name__)%20({job=%22cadvisor%22})' \
    | python3 -c "import json,sys;d=json.load(sys.stdin);[print(r['metric']['__name__'],'=',r['value'][1]) for r in sorted(d['data']['result'],key=lambda r: -int(r['value'][1]))[:20]]"
```

Top métricas por cardinalidad. Si ves `container_processes` con miles de series, el _flag_ `--disable_metrics=process` no se aplicó. Si ves `container_label_*` con decenas de _label keys_, el `--store_container_labels=false` no se aplicó. Apagar y recargar.

### `docker logs cadvisor` muestra `cAdvisor running with too many container labels` o similar

Aviso del propio cAdvisor cuando algún contenedor tiene >100 _labels_ (raro, pero ocurre con imágenes Bitnami u Open Container labels muy granulares). Solución: confirmar `--store_container_labels=false` y, si persiste, _whitelist_ explícito con sólo las que importan.

### Tras `docker compose pull` con _bump_ a `v0.50.x`, `Cadvisor exporter` deja de pintar paneles concretos

Algún _metric name_ se renombró/depreció. Revisar las _release notes_ de cAdvisor en GitHub:

```bash
# Encontrar diff de métricas:
docker exec prometheus wget -qO- http://cadvisor:8080/metrics | grep '^# HELP container_' > /tmp/new
# Comparar con /tmp/old (capturado antes del bump).
diff /tmp/old /tmp/new
```

Solución de emergencia: pinnear atrás en `~/homelab/monitor/.env` (`CADVISOR_IMAGE_TAG=v0.49.1`), `docker compose up -d cadvisor`, y abrir un _issue_ aguas arriba para arreglar el _dashboard_ con calma.

---

## Referencias

- cAdvisor — Repo y _release notes_: <https://github.com/google/cadvisor>
- cAdvisor — Lista de _flags_: <https://github.com/google/cadvisor/blob/master/docs/runtime_options.md>
- cAdvisor — Lista de métricas: <https://github.com/google/cadvisor/blob/master/docs/storage/prometheus.md>
- cAdvisor — Imagen Docker oficial (gcr.io): <https://gcr.io/cadvisor/cadvisor>
- Grafana Labs — _Dashboard_ `Cadvisor exporter` (ID 14282): <https://grafana.com/grafana/dashboards/14282-cadvisor-exporter/>
- Linux kernel — cgroup v2 unificado: <https://docs.kernel.org/admin-guide/cgroup-v2.html>
- Prometheus — `relabel_configs` y `metric_relabel_configs`: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config>
- Prometheus — _Best practices on instrumentation_ (`instance` label, `relabel_configs`): <https://prometheus.io/docs/practices/naming/>
