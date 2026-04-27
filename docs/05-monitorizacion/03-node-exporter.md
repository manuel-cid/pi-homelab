# Node Exporter (métricas del sistema operativo)

## Descripción

Despliegue de **Node Exporter** como _exporter_ canónico de métricas del sistema operativo de la Pi 5: CPU (utilización por modo, _load average_, _context switches_), memoria (RSS, _buff/cache_, _swap_), disco (IOPS, latencia, ocupación por _filesystem_), red (bytes/paquetes/errores por interfaz), temperatura del SoC (`cpu_thermal` vía `hwmon`), _uptime_, estado de _systemd_… Todo lo que un homelab necesita para responder a "¿la Pi está sana?" y para sostener los _dashboards_ de Grafana de la fase 5.

Node Exporter expone `/metrics` en `:9100` (HTTP plano) dentro de la red `homelab`; **Prometheus** (`docs/05-monitorizacion/01-prometheus.md`) lo _scrapea_ por DNS interno (`node-exporter:9100`) y **Grafana** (`docs/05-monitorizacion/02-grafana.md`) pinta el _dashboard_ **Node Exporter Full** (ID `1860`), que este documento **provisiona** dejando caer su `.json` en el directorio que el _provider_ de _dashboards_ ya está vigilando.

Este documento **se suma al _stack_ `monitor`** ya operativo. No crea nada nuevo en `~/homelab/`: añade el servicio `node-exporter` al `docker-compose.yml` del _stack_, su `scrape_job` `node` al `prometheus.yml`, el JSON del _dashboard_ `node-exporter-full.json` al directorio de _dashboards_ de Grafana, y dos variables al `.env`/`.env.example`.

> **Alcance**: este documento despliega Node Exporter, lo conecta a la red `homelab`, lo expone a Prometheus por DNS interno, añade el _scrape_job_ correspondiente con `instance: pi5` como _label_ estable y provisiona el _dashboard_ `1860`. **No** lo expone vía Caddy (Node Exporter es un _exporter_ interno; Prometheus es el único cliente legítimo, y Prometheus ya está protegido con 2FA en la fase 1). **No** activa el _textfile collector_ (no hay aún _scripts_ que generen métricas custom; se documenta cómo activarlo cuando llegue el caso). **No** activa colectores específicos de hardware ausente en una Pi 5 (`infiniband`, `nvme`, `wifi` con dispositivos PCI, _bonding_, _ipvs`, …): se desactivan explícitamente para no ensuciar `/metrics` con _metrics families_ vacías.

> **Recordatorio de red**: Node Exporter **no se publica al host** (no hay `ports:`). Vive en la red Docker `homelab` (`172.20.10.0/24`, `br-homelab`) y Prometheus lo alcanza por DNS interno (`node-exporter:9100`). Aun así, las métricas que ofrece son del **host** (Pi 5), no del contenedor: el documento monta `/proc`, `/sys` y `/` en modo lectura dentro del contenedor con `:ro,rslave`, y lanza Node Exporter con `--path.procfs=/host/proc`, `--path.sysfs=/host/sys` y `--path.rootfs=/host/root` para que los colectores lean del _filesystem_ real.

---

## Requisitos previos

- `docs/05-monitorizacion/01-prometheus.md` completado: el _stack_ `monitor` existe en `~/homelab/monitor/`, Prometheus está `(healthy)`, `prometheus.yml` activo con un único _job_ (`prometheus`), y `https://prometheus.lan/targets` muestra **un** _target_ en `UP`. Este doc añade un segundo (de hecho, después de Grafana, el tercero).
- `docs/05-monitorizacion/02-grafana.md` completado: Grafana está `(healthy)`, el _datasource_ `Prometheus` aparece como `default` y el _provider_ `homelab` (`provisioning/dashboards/default.yml`) está escaneando `/var/lib/grafana/dashboards/*.json` cada 30 s. Este doc se aprovecha de eso: con sólo dejar `node-exporter-full.json` en ese directorio, Grafana lo recoge sin _restart_.
- `docs/02-docker/02-estructura-compose.md` completado: red `homelab` (`172.20.10.0/24`, `br-homelab`) creada y _externa_, `~/homelab/.env` con `TZ`, `PUID`, `PGID` y `HOMELAB_DOMAIN=lan` operativos.
- `docs/02-docker/04-watchtower.md` completado: Watchtower está vigilando con `WATCHTOWER_LABEL_ENABLE=true` (modo _opt-in_). Este doc activa la _label_ en Node Exporter — es uno de los servicios listados como _opt-in_ desde el principio en aquella tabla (no tiene estado y los _patch releases_ son seguros).
- Conectividad saliente para descargar la imagen y el _dashboard_:

  ```bash
  docker pull --platform linux/arm64 prom/node-exporter:v1.9.1 >/dev/null && echo OK
  curl -fsS -o /dev/null https://grafana.com/api/dashboards/1860/revisions/latest/download && echo OK
  ```

- Que el host **no** tenga ya un servicio escuchando en `:9100`:

  ```bash
  sudo ss -tulpn '( sport = :9100 )'
  ```

  Salida esperada: vacía. Node Exporter **no** publica `:9100` al host (sólo lo expone a `homelab`), pero conviene confirmar que ningún `node_exporter` instalado a la antigua usanza (vía `apt`, _systemd unit_) lo ocupa antes del primer `up`.

---

## Decisiones de diseño

### Por qué Node Exporter (y no Telegraf / collectd / Netdata-as-exporter)

| Candidato       | Por qué se descarta                                                                                                                                                                                                                                                                                  |
|-----------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Telegraf**    | Modelo _push_ (envía a InfluxDB / un _output plugin_) y _config_ TOML pesado. Para _scrapear_ con Prometheus haría falta el _output_ `prometheus_client`, lo que duplica complejidad sin aportar nada — Node Exporter ya habla Prometheus de fábrica.                                                |
| **collectd**    | Excelente y ligero, pero su _output_ Prometheus pasa por el _Prometheus collectd exporter_, otro proceso intermedio. Y la mayoría de _dashboards_ públicos de Grafana asumen _label set_ de `node_exporter` (`node_cpu_seconds_total`, `node_filesystem_avail_bytes`…), no el de collectd.            |
| **Netdata** (modo _exporter_) | Netdata puede exponer `/api/v1/allmetrics?format=prometheus`, pero arrastra su agente todo-en-uno (UI, alerting, _ML anomaly detection_) que ya hemos descartado en `docs/05-monitorizacion/01-prometheus.md` por ser sobreingeniería para un homelab. Si lo tienes, úsalo; si no, Node Exporter es lo idiomático.            |
| **`cAdvisor` solo** | cAdvisor cubre métricas de **contenedores**, no del host. Es complementario, no sustituto: este doc despliega Node Exporter, y `docs/05-monitorizacion/04-cadvisor.md` desplegará cAdvisor.                                                                                                            |

Node Exporter gana por:

- **Lingua franca de Prometheus**: nombres y _label sets_ canónicos, así que cualquier _dashboard_ público (Node Exporter Full `1860`, Pi-hole `10176`, etc.) y cualquier regla de PromQL funcionan _out-of-the-box_.
- **Single binary, sin dependencias**: imagen `scratch` con un único ejecutable Go estático. ARM64 nativo. ~12 MB on-disk, ~30 MB RAM en idle.
- **Colectores _opt-in/opt-out_ por _flag_**: cada categoría se activa/desactiva sin tocar el binario. El homelab desactiva los que no aplican (`infiniband`, `nvme`, `wifi`, `ipvs`…) y deja los relevantes para Pi 5 (`cpu`, `meminfo`, `filesystem`, `netdev`, `hwmon`, `thermal_zone`, `loadavg`, `time`, …).
- **Sin estado persistente**: `/metrics` se calcula al vuelo en cada _scrape_, no hay BD que respaldar ni migrar.
- **Watchtower opt-in seguro**: un solo binario sin _schema_ ni _wire format_ que pueda romper entre _patch releases_. La actualización automática es trivial.

### Vivir en la red `homelab` (no `network_mode: host`)

Es tentador desplegar Node Exporter con `network_mode: host` "para que vea la red real": así, las métricas `node_network_*` referencian directamente las interfaces del host (`eth0`, `wlan0`, `br-homelab`, `tailscale0`). Sin embargo, eso rompe la convención del homelab — todos los servicios viven en la red `homelab` y Prometheus _scrapea_ por DNS interno — y obliga a Prometheus a apuntar al _gateway_ del puente (`172.20.10.1:9100`), poco legible y frágil ante cambios de subnet.

Solución idiomática y ya estándar en la documentación oficial de Node Exporter: **dejarlo en la red `homelab`** y **montar `/proc/net` del host** vía `--path.procfs=/host/proc`. Los colectores de red leen `/host/proc/net/dev`, `/host/proc/net/netstat`, `/host/proc/net/snmp` etc., de modo que ven las interfaces **del host** (`eth0`, `lo`, `br-homelab`, `tailscale0`, `wlan0` cuando aplique) **a pesar de** que el contenedor está en su propio _network namespace_. El truco está en que `/proc/net/dev` es un fichero del kernel cuyo contenido depende del _network namespace_ del proceso que lo lee — pero al pasarle `--path.procfs=/host/proc` no estamos abriendo `/proc/net/dev` desde dentro del _netns_ del contenedor: lo abrimos desde el _bind mount_ que se montó **antes** de entrar al _netns_, y el kernel devuelve la vista del _netns_ del init host (`PID 1`, _root namespace_).

Resultado: métricas de red del host correctas, contenedor en `homelab`, Prometheus _scrapea_ por nombre interno (`node-exporter:9100`).

> **Por qué `:ro,rslave`** en los _bind mounts_:
> - `ro` (read-only) — evidente. Node Exporter sólo lee.
> - `rslave` (recursive slave) — si el host monta o desmonta algo bajo `/proc` o `/sys` después de arrancar el contenedor (raro, pero ocurre con `pivot_root` o con _kernel modules_ que se cargan en caliente), el contenedor _ve_ los cambios. Sin `rslave`, el contenedor podría quedarse con una vista "congelada" y Node Exporter daría métricas obsoletas. Es la receta canónica de la documentación oficial.

### `pid: host` y `network_mode: host` — no se usan

- **`pid: host`**: necesario sólo si se activa el colector `processes` (que cuenta procesos por estado: `R`, `S`, `D`, `Z`…). Por defecto está **desactivado** en Node Exporter porque el coste de leer `/proc/<pid>/stat` para cada uno de los miles de PIDs en sistemas grandes es alto. En un homelab con ~150 procesos del host es asumible, pero los _dashboards_ canónicos no lo usan; lo dejamos **deshabilitado** para minimizar superficie. Si se activa más adelante, requerirá `pid: host` y se documentará entonces.
- **`network_mode: host`**: descartado arriba.

### Imagen y _tag_

- **`prom/node-exporter:v1.9.1`** — multi-arch con `linux/arm64`, imagen oficial publicada por el equipo de Prometheus. Pinneada a versión completa (convención del homelab).
- **Por qué `prom/node-exporter` y no `quay.io/prometheus/node-exporter`**: ambas son mirrors oficiales del mismo binario; `prom/*` (Docker Hub) es coherente con `prom/prometheus:v3.1.0` ya usado en `docs/05-monitorizacion/01-prometheus.md`. La convención de "una sola fuente de imágenes Prometheus" simplifica el _allow-list_ del _registry_ si en algún momento se acota.
- **Por qué `v1.9.1` y no `v1.8.x`**: `v1.9.0` (abr 2025) introdujo _scrape filtering_ por _collector_ (`?collect[]=cpu&collect[]=meminfo`) y mejoras del colector `hwmon` que detectan correctamente el sensor `cpu_thermal` de la Pi 5; `v1.9.1` (may 2025) corrigió un _race_ del colector `filesystem` con _bind mounts_ recursivos. Para un primer despliegue en 2026, `v1.9.x` es el _baseline_ esperado.
- **Watchtower opt-in** (`com.centurylinklabs.watchtower.enable: "true"`):
  - Single binary, sin _wire format_ ni _state_. Los _patch releases_ entre `v1.9.x → v1.9.y` son seguros a ciegas; los _minors_ (`v1.9 → v1.10`) sólo añaden colectores y a veces renombran _metrics_ marcados como `experimental` (raro). Las _release notes_ se leen pero no bloquean la actualización.
  - `docs/02-docker/04-watchtower.md` lista explícitamente Node Exporter en la lista de _opt-in_ desde el principio.

### Colectores: lista controlada (no `--collector.<all>` por defecto)

Por defecto Node Exporter activa **un montón** de colectores que no aplican a una Pi 5: `infiniband`, `nvme`, `bonding`, `ipvs`, `wifi` (sin `iw` userspace), `xfs`, `zfs`, `softnet`, etc. Cada uno añade _metric families_ vacías a `/metrics` (por _scrape_, ~50 ms de CPU adicional para un binario que escupe ~5 KB de texto inútil). Mejor desactivarlos.

Política del homelab — **flag `--collector.disable-defaults`** + lista explícita de los que **sí** queremos. Así el `--enabled` queda autodocumentado en el `docker-compose.yml`:

| Colector             | Por qué `--collector.<x>`                                                                                                |
|----------------------|---------------------------------------------------------------------------------------------------------------------------|
| `cpu`                | Tiempo por modo (user, system, iowait, idle, …) por core. Fundamento del _dashboard_ 1860.                                |
| `cpufreq`            | Frecuencia y _governor_ por core. Útil para detectar _throttling_ térmico en la Pi 5 (`cpu_thermal` baja la freq).        |
| `loadavg`            | `node_load1`, `node_load5`, `node_load15`. _Header_ casi obligatorio.                                                     |
| `meminfo`            | Memoria libre/usada/cached/buffers/swap. Origen de "cuánto consume el homelab".                                            |
| `vmstat`             | Page faults, swap-in/out. Útil para detectar _pressure_ de memoria antes de OOM.                                          |
| `netdev`             | Bytes/paquetes/errores por interfaz. Lee `/host/proc/net/dev` (host stats).                                                |
| `netstat`            | TCP connection states, segments retransmitted. Lee `/host/proc/net/snmp`.                                                  |
| `sockstat`           | Sockets abiertos por familia. Útil para detectar _leaks_ en servicios.                                                    |
| `filesystem`         | Bytes libres/totales por _mount point_. Lee `/host/proc/mounts` y filtra por _exclude_ (ver más abajo).                   |
| `diskstats`          | IOPS, latencia, _queue depth_ por dispositivo. Crítico para `hd5t`/`hd2t` (USB 3.0 mecánicos: una latencia >100 ms es una señal).|
| `hwmon`              | Sensores `hwmon`. En la Pi 5: `cpu_thermal` (SoC), `nvme` (cuando llegue), `pmic` (gestión de energía).                   |
| `thermal_zone`       | _Backup_ de `hwmon` que lee `/sys/class/thermal/thermal_zone*/temp`. En la Pi 5 redundante con `hwmon`, pero no estorba.  |
| `time`               | _Clock skew_ del host respecto a NTP. Detecta si `chrony`/`systemd-timesyncd` está derivando.                              |
| `uname`              | Versión del kernel, _hostname_, arquitectura. Como _label_ en algunos paneles (`Node Info`).                              |
| `os`                 | Distro (`raspbian`/`debian`), versión. Útil tras `apt full-upgrade` para confirmar el cambio de _release_.                 |
| `boottime`           | Timestamp UNIX del último _boot_. Se construye `node_time_seconds - node_boot_time_seconds = uptime`.                     |
| `entropy`            | Entropía disponible en `/proc/sys/kernel/random/entropy_avail`. Bajo riesgo en hardware moderno con `getrandom()`, pero útil. |
| `pressure`           | PSI (`/host/proc/pressure/{cpu,memory,io}`). Métrica nueva del kernel 4.20+, mucho mejor que `loadavg` para detectar saturación. |
| `stat`               | `boots`, _processes forked_, _interrupts_. Ligero.                                                                         |
| `filefd`             | _Open file descriptors_ del host. Detecta _fd leaks_ globales.                                                            |
| `systemd`            | Estado de _units_ de systemd (`failed`, `active`, …). Sólo si se monta `/run/systemd/private` o se le da `DBus`. **Lo dejamos OFF** para no acoplar el contenedor a `systemd` del host.|

Colectores **desactivados explícitamente** (pasamos `--no-collector.<x>` cuando sea necesario, pero con `--collector.disable-defaults` basta con _no_ listarlos): `infiniband`, `nvme` (sin SSD NVMe en la Pi), `bonding`, `ipvs`, `wifi` (no usamos WiFi en el homelab — la Pi va por `eth0`), `xfs`, `zfs`, `mdadm`, `nfsd`, `processes`, `bcache`, `arp` (innecesario), `btrfs`, `dmi`, `fibrechannel`, `hwmon` ya cubierto, `ksmd`, `lnstat`, `logind`, `mountstats`, `network_route`, `nfs`, `perf`, `qdisc`, `rapl`, `runit`, `schedstat`, `selinuxfs`, `softirqs`, `softnet`, `supervisord`, `sysctl`, `tapestats`, `textfile`, `udp_queues`, `wifi`, `zoneinfo`, …

> **`textfile` collector — por qué OFF por defecto**: deja que un _script_ del operador (cron, systemd timer) escriba ficheros `*.prom` en un directorio compartido y Node Exporter los expone como métricas custom. Útil para "días desde el último _backup_" o "tamaño del repo Borg", pero ningún doc actual del homelab lo necesita. Cuando llegue (probablemente en `docs/07-backups/02-borgmatic.md`), se activa con `--collector.textfile --collector.textfile.directory=/host/var/lib/node_exporter/textfile_collector` y se monta el directorio. La activación es _backwards-compatible_: las _series_ existentes no cambian.

### `--collector.filesystem.mount-points-exclude` — silenciar `overlay`, `tmpfs` ruidoso

Por defecto, el colector `filesystem` reporta TODOS los _mount points_, incluyendo los `overlay` de cada contenedor (`/var/lib/docker/overlay2/<id>/...`) y los `tmpfs` efímeros (`/run`, `/run/user/<uid>`, `/var/lib/snapd/...`). En un host con >20 contenedores, eso explota la cardinalidad de `node_filesystem_*` (un _label_ `mountpoint` distinto por _mount_) y satura `/metrics` con líneas inútiles.

Receta:

```
--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run|var/lib/docker/.+|var/lib/containers/.+|var/lib/kubelet/.+|tmp/.+|.+/shm|snap/.+)($|/)
--collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$
```

Quedan las particiones reales: `/`, `/boot`, `/mnt/hd5t`, `/mnt/hd2t` y los _mounts_ legítimos del operador. La cardinalidad de `node_filesystem_*` se mantiene en ~5 series por métrica.

### `--collector.netdev.device-exclude` — silenciar `veth*` de Docker

Cada contenedor crea un par `veth<random>@if<n>` para conectarse al puente `br-homelab`. En `/host/proc/net/dev` aparecen _todas_ las `veth` del host, lo cual significa que `node_network_*` añade ~30 series por contenedor. Se filtran por nombre:

```
--collector.netdev.device-exclude=^(veth[a-f0-9]+|docker[0-9]+|br-[a-f0-9]+|lo)$
```

Quedan las interfaces que importan: `eth0`, `wlan0` (si en algún momento se reactiva), `br-homelab` (la dejamos visible para diagnosticar Docker), `tailscale0` (cuando se levante en host network — `docs/03-red/05-tailscale.md`).

> **Trade-off**: `br-homelab` se filtra arriba por el patrón `br-[a-f0-9]+`, que captura los _bridges_ autogenerados de Docker (`br-3f4a8b2c…`). Pero `br-homelab` es manual y no tiene _hex suffix_, así que **NO** lo captura. Mantenerlo así.

### Sin `healthcheck`

La imagen `prom/node-exporter` está construida sobre `scratch`: un solo binario estático, sin `sh`, sin `wget`, sin `curl`, sin `nc`. No hay forma de ejecutar un comando dentro del contenedor para sondear `/-/healthy`. Las opciones serían:

1. Cambiar a una imagen "fat" con `busybox`. Rechazado: la elegancia de `prom/node-exporter:scratch` (~12 MB, sin _attack surface_ extra) se pierde a cambio de un _healthcheck_ marginal.
2. Usar un _healthcheck_ "from outside" via `docker exec`. Rechazado: en una imagen `scratch` no hay nada que ejecutar.
3. Confiar en el _healthcheck_ que ya hace **Prometheus**: si `up{job="node"} == 0` durante varios _scrapes_, Prometheus lo refleja en `/targets`, Grafana lo pinta y Uptime Kuma (cuando llegue, `docs/05-monitorizacion/05-uptime-kuma.md`) lo vigila. Es el _healthcheck_ correcto: está midiendo lo que importa (el _scrape_ funciona), no un endpoint local que el contenedor sirve a sí mismo.

Conclusión: **omitimos `healthcheck:` en el compose**. Documentado abajo y validado durante el despliegue por la propia métrica `up`.

### Acceso vía Caddy + Authelia — **no aplica**

A diferencia de Prometheus y Grafana, Node Exporter **no se expone vía Caddy**. Razones:

- **No hay UI**: el endpoint `/metrics` es texto plano para máquinas (Prometheus). `/` devuelve un HTML rudimentario con un único enlace a `/metrics` — nada que un humano necesite.
- **El consumidor legítimo es Prometheus**, que ya está en la red `homelab` y no necesita pasar por el _reverse proxy_.
- **Superficie reducida**: cualquier servicio expuesto vía Caddy es un endpoint más que mantener, asegurar y auditar. Node Exporter no aporta valor humano detrás de Authelia.

Si en algún momento el operador quiere ver `/metrics` "a ojo" (debug), se hace desde el host vía `docker exec`:

```bash
docker run --rm --network homelab curlimages/curl:8.10.1 \
    -fsS http://node-exporter:9100/metrics | head -50
```

O, equivalente, desde dentro de Prometheus:

```bash
docker exec prometheus wget -qO- http://node-exporter:9100/metrics | head -50
```

### Instance label estable: `pi5` (no `node-exporter:9100`)

Por defecto, Prometheus etiqueta cada _scrape_ con `instance=<address>`, así que las series quedarían como `node_cpu_seconds_total{instance="node-exporter:9100"}`. Eso funciona, pero rompe los _dashboards_ canónicos (1860 espera variar `instance` para distinguir _hosts_) y, sobre todo, queda feo y frágil: cualquier renombrado del contenedor cambia el _label_ y desaparecen las series viejas en Grafana.

Solución: en el `scrape_config` del job `node`, sobrescribir `instance` con un valor estable mediante `relabel_configs`:

```yaml
relabel_configs:
  - target_label: instance
    replacement: pi5
```

Resultado: todas las series de Node Exporter llevan `instance=pi5`. Si en el futuro el homelab crece a varios nodos físicos, cada uno se _scrapea_ con su `target_label.instance` distinto (`pi5`, `pi5-b`, `nuc-arm`, …) y los _dashboards_ los muestran como _options_ del `$instance` _variable_ de Grafana.

> **Coherencia con `external_labels.instance_role: pi5`** del `prometheus.yml` (definido en `01-prometheus.md`): allí `instance_role` es un _label_ de **producción de la serie** (todas las series del homelab lo llevan al federarse); `instance` aquí es el _label_ del **target scrapeado**. Distintos _scopes_, mismo valor por _coincidencia legible_.

---

## Almacenamiento

| Ruta en el host                                                         | Contenido                                                                  | Versionable | Backup |
|-------------------------------------------------------------------------|----------------------------------------------------------------------------|-------------|--------|
| `~/homelab/monitor/docker-compose.yml`                                  | Definición del _stack_ (modificada — servicio `node-exporter` añadido)     | git         | git    |
| `~/homelab/monitor/prometheus/prometheus.yml`                           | _Scrape_ `job_name: node` añadido                                          | git         | git    |
| `~/homelab/monitor/grafana/dashboards/node-exporter-full.json`          | Dashboard `1860` con placeholder de _datasource_ sustituido                | git         | git    |
| `~/homelab/monitor/.env.example` y `.env`                               | `NODE_EXPORTER_IMAGE_TAG` añadido                                          | `.example` sí, `.env` no | git aparte (nota local) |

> **Sin estado persistente**: Node Exporter es _stateless_; no hay nada que respaldar. La pérdida del contenedor se recupera en segundos con `make up STACK=monitor`. El _commit_ de los ficheros versionables anteriores es lo único que hay que conservar.

---

## Estructura del _stack_ `monitor` tras este documento

```
~/homelab/monitor/
├── docker-compose.yml              # ← modificado (servicio 'node-exporter' añadido)
├── .env                            # ← modificado (NODE_EXPORTER_IMAGE_TAG)
├── .env.example                    # ← modificado (NODE_EXPORTER_IMAGE_TAG)
├── .gitignore                      # (sin cambios)
├── prometheus/
│   ├── prometheus.yml              # ← modificado (job_name 'node' añadido)
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
        └── node-exporter-full.json # ← nuevo
```

> **Sin subdirectorio `~/homelab/monitor/node-exporter/`**: Node Exporter no tiene ficheros de configuración propios — su comportamiento se define entero en los _flags_ del `command:` del compose. No hace falta un subdirectorio para él.

---

## Variables de entorno

Editar `~/homelab/monitor/.env.example` y añadir, debajo del bloque de Grafana:

```bash
# --- Node Exporter ----------------------------------------------------------
NODE_EXPORTER_IMAGE_TAG=v1.9.1
```

Reflejar en `~/homelab/monitor/.env` (no versionado):

```bash
cd ~/homelab/monitor
grep -q '^NODE_EXPORTER_IMAGE_TAG=' .env || cat >> .env <<'EOF'

# --- Node Exporter ---
NODE_EXPORTER_IMAGE_TAG=v1.9.1
EOF
chmod 0600 .env
```

> No hay secretos. Node Exporter no maneja credenciales; `/metrics` es accesible sin autenticación dentro de la red `homelab` (justificación: **Acceso vía Caddy + Authelia — no aplica** en _Decisiones de diseño_).

---

## Modificar `~/homelab/monitor/docker-compose.yml`

Añadir el servicio `node-exporter` debajo del de `grafana` (**no** sustituir: los bloques de `prometheus` y `grafana` se quedan intactos):

```yaml
  # ---------------------------------------------------------------------------
  # Node Exporter — métricas del sistema operativo del host (Pi 5).
  # Vive en la red 'homelab'; los colectores leen del host vía bind-mounts
  # de /proc, /sys y /. No publica :9100 al host: Prometheus lo scrapea por
  # DNS interno (node-exporter:9100).
  # docs/05-monitorizacion/03-node-exporter.md
  # ---------------------------------------------------------------------------
  node-exporter:
    image: prom/node-exporter:${NODE_EXPORTER_IMAGE_TAG}
    container_name: node-exporter
    hostname: node-exporter
    restart: unless-stopped
    # Imagen 'scratch' con un único binario estático. Corre como UID 65534
    # (nobody) por defecto; se explicita por claridad.
    user: "65534:65534"
    # Sin pid: host: el colector 'processes' está OFF y los colectores que
    # usamos no necesitan ver los PIDs del host. Cuando se active 'processes',
    # se añadirá pid: host y se documentará en una revisión de este doc.
    command:
      # --- Paths del host (bind-mounts ro,rslave) -----------------------------
      - --path.procfs=/host/proc
      - --path.sysfs=/host/sys
      - --path.rootfs=/host/root
      # --- Sólo los colectores que aplican a una Pi 5 -------------------------
      # Apagamos los defaults y activamos uno a uno; razonado en
      # 'Decisiones de diseño > Colectores'.
      - --collector.disable-defaults
      - --collector.cpu
      - --collector.cpufreq
      - --collector.loadavg
      - --collector.meminfo
      - --collector.vmstat
      - --collector.netdev
      - --collector.netstat
      - --collector.sockstat
      - --collector.filesystem
      - --collector.diskstats
      - --collector.hwmon
      - --collector.thermal_zone
      - --collector.time
      - --collector.uname
      - --collector.os
      - --collector.boottime
      - --collector.entropy
      - --collector.pressure
      - --collector.stat
      - --collector.filefd
      # --- Filtros de cardinalidad -------------------------------------------
      # Excluir mountpoints/fstypes ruidosos (overlay de Docker, tmpfs efímero).
      - --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run|var/lib/docker/.+|var/lib/containers/.+|var/lib/kubelet/.+|tmp/.+|.+/shm|snap/.+)($$|/)
      - --collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$$
      # Excluir interfaces virtuales de Docker (veth*, br-<hash>, docker0).
      # NOTA: 'br-homelab' NO encaja en '^br-[a-f0-9]+$' (no tiene hex suffix),
      # así que sigue visible — esto es deseado.
      - --collector.netdev.device-exclude=^(veth[a-f0-9]+|docker[0-9]+|br-[a-f0-9]+|lo)$$
      # --- Endpoint --------------------------------------------------------
      - --web.listen-address=:9100
      - --web.telemetry-path=/metrics
      # --- Logging ----------------------------------------------------------
      - --log.level=info
      - --log.format=logfmt
    environment:
      TZ: ${TZ}
    volumes:
      # Read-only + rslave: Node Exporter ve los mounts/unmounts del host
      # en caliente. Sin :rslave, montar un disco USB tras el boot dejaría
      # node_filesystem_* sin reflejarlo hasta el siguiente restart.
      - /proc:/host/proc:ro,rslave
      - /sys:/host/sys:ro,rslave
      - /:/host/root:ro,rslave
    networks:
      homelab:
        aliases:
          - node-exporter
    labels:
      homelab.stack: "monitor"
      homelab.backup: "false"      # sin estado persistente
      # Patch releases seguros; opt-in. Lista del doc 02-docker/04-watchtower.md.
      com.centurylinklabs.watchtower.enable: "true"
    # Sin healthcheck: imagen 'scratch' sin shell ni wget/curl/nc para sondear
    # localhost:9100. El 'health' real lo mide Prometheus con 'up{job=node}'.
    # Justificación en docs/05-monitorizacion/03-node-exporter.md.
```

> **`$$` (doble dólar) en los regex**: Compose interpola `$VAR` desde `.env`, así que para que un `$` literal llegue al binario hay que escribirlo `$$`. Si se escribe un solo `$`, Compose intenta resolverlo como variable, no la encuentra, y lo deja vacío — convirtiendo `^/dev|proc|...|.+/shm$` en `^/dev|proc|...|.+/shm` y rompiendo el ancla del fin.

Notas de diseño extra:

- **`/:/host/root:ro,rslave`** monta la raíz del host como _read-only_ dentro del contenedor. Esto no es un riesgo de seguridad porque (1) Node Exporter es _read-only_ por flag (`ro`), (2) corre como `UID 65534` sin caps escalados, (3) la imagen es `scratch` y no contiene un _shell_ desde el que un atacante pudiera leer interactivamente. Lo único que `--path.rootfs=/host/root` permite a Node Exporter es resolver _mountpoints_ del host (cuando el colector `filesystem` lee `/host/proc/mounts` y necesita _statfs_ sobre el _real path_, lo hace contra `/host/root/<mountpoint>`).
- **Sin `cap_add: SYS_TIME`**: el colector `time` lee `/proc/timer_list` y `clock_gettime`, sin necesidad de capacidad extra.
- **Sin `pid: host`**: el colector `processes` está OFF y el resto no leen `/host/proc/<pid>/...`.
- **`labels.homelab.backup: "false"`**: sin estado, Borgmatic no debe respaldar nada de Node Exporter (porque no hay nada). El _label_ es informativo: el _hook_ de Borg que filtra por `homelab.backup` lo ignora.

---

## Modificar `~/homelab/monitor/prometheus/prometheus.yml`

Añadir el `scrape_config` `node` debajo del de `grafana`:

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

+  # -------------------------------------------------------------------------
+  # 3) Node Exporter — métricas del sistema (CPU, RAM, disco, red, hwmon).
+  #    Lee del host vía bind-mounts de /proc /sys /. 'instance' se reescribe
+  #    a 'pi5' para hacerlo estable a renombrados del contenedor.
+  #    docs/05-monitorizacion/03-node-exporter.md
+  # -------------------------------------------------------------------------
+  - job_name: 'node'
+    metrics_path: /metrics
+    static_configs:
+      - targets:
+          - 'node-exporter:9100'
+        labels:
+          service: node-exporter
+          stack:   monitor
+    relabel_configs:
+      # Estabilizar el label 'instance' a 'pi5' (no al address del target).
+      # Cuando el homelab tenga >1 nodo físico, se duplicará este job con
+      # otros 'targets' y otros 'replacement' (pi5-b, nuc-arm, ...).
+      - target_label: instance
+        replacement: pi5
```

Validar y recargar Prometheus sin _restart_:

```bash
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
# Checking 3 scrape configs: SUCCESS

docker exec prometheus kill -HUP 1
# level=info ... msg="Loading configuration file"
# level=info ... msg="Completed loading of configuration file"
```

> **Orden estricto**: editar **antes** levantar el contenedor `node-exporter`, validar, levantar, y entonces recargar Prometheus (o al revés — recargar primero deja el _target_ en `DOWN` durante 15 s con error `dial tcp: lookup node-exporter: no such host` hasta que `make up` termine, lo cual ensucia los _logs_ pero no es destructivo). El procedimiento documentado abajo en _Despliegue_ recomienda el orden seguro.

---

## Añadir el _dashboard_ `Node Exporter Full` (ID 1860)

```bash
# Descargar el JSON del dashboard canónico de Grafana Labs.
curl -fsSL \
    'https://grafana.com/api/dashboards/1860/revisions/latest/download' \
    -o ~/homelab/monitor/grafana/dashboards/node-exporter-full.json

# Sustituir el placeholder del datasource por el nombre real ('Prometheus'),
# tal y como hizo el doc de Grafana con el dashboard 3662.
sed -i 's/\${DS_PROMETHEUS}/Prometheus/g' \
    ~/homelab/monitor/grafana/dashboards/node-exporter-full.json

# Permisos coherentes con el otro JSON ya commiteado.
chmod 0644 ~/homelab/monitor/grafana/dashboards/node-exporter-full.json

# Validación de JSON: si falla, el provider de Grafana abortará la carga
# de TODOS los dashboards del provider 'homelab', no sólo de éste.
python3 -m json.tool ~/homelab/monitor/grafana/dashboards/node-exporter-full.json > /dev/null && echo OK

# Confirmar que el placeholder se sustituyó (debe ser 0):
grep -c 'DS_PROMETHEUS' ~/homelab/monitor/grafana/dashboards/node-exporter-full.json
# 0
```

> **Por qué `1860` y no `11074` (Node Exporter for Prometheus Dashboard EN)**: ambos cubren las mismas métricas y son popularísimos. `1860` (mantenido por _idealista_, ~1500 _downloads/day_) tiene más paneles desglosados (network errors por tipo, hwmon por sensor) y filtros estándar (`$instance`, `$datasource`, `$job`); `11074` es más compacto. Para la Pi 5, el detalle de `1860` es útil (los paneles de _hwmon_ pintan la temperatura del SoC bien etiquetada).

> **El _provider_ recoge el JSON en <30 s**: gracias a `updateIntervalSeconds: 30` del `provisioning/dashboards/default.yml` (definido en `02-grafana.md`). No hace falta `restart` de Grafana. Validación: `Dashboards → Homelab` muestra el nuevo en lo alto a los pocos segundos.

---

## Despliegue

Orden seguro (evita _logs_ ruidosos durante 15-30 s entre pasos):

```bash
# 1) Editar los ficheros versionables ya descritos:
#    - ~/homelab/monitor/.env y .env.example   (NODE_EXPORTER_IMAGE_TAG)
#    - ~/homelab/monitor/docker-compose.yml    (servicio 'node-exporter')
#    - ~/homelab/monitor/prometheus/prometheus.yml (job 'node')
#    - ~/homelab/monitor/grafana/dashboards/node-exporter-full.json (curl)

# 2) Validar prometheus.yml sin tocar nada:
docker run --rm \
    -v ~/homelab/monitor/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
    -v ~/homelab/monitor/prometheus/rules:/etc/prometheus/rules:ro \
    --entrypoint promtool \
    prom/prometheus:v3.1.0 \
    check config /etc/prometheus/prometheus.yml
# Checking 3 scrape configs: SUCCESS

# 3) Validar el compose modificado:
docker compose -f ~/homelab/monitor/docker-compose.yml \
    --env-file ~/homelab/.env --env-file ~/homelab/monitor/.env \
    config | head -120

# 4) Levantar el nuevo servicio (sólo recreará 'node-exporter';
#    Prometheus y Grafana siguen vivos):
cd ~/homelab
make up STACK=monitor
# o, equivalente:
docker compose -f ~/homelab/monitor/docker-compose.yml \
    --env-file ~/homelab/.env --env-file ~/homelab/monitor/.env \
    up -d node-exporter

# 5) Recargar Prometheus para que aplique el nuevo job_name:
docker exec prometheus kill -HUP 1
```

Verificar que Node Exporter levantó:

```bash
docker compose -f ~/homelab/monitor/docker-compose.yml ps
# NAME            STATUS
# prometheus      Up X minutes (healthy)
# grafana         Up Y minutes (healthy)
# node-exporter   Up Z seconds
# (sin '(healthy)' — no se define healthcheck, ver Decisiones de diseño)
```

Inspeccionar `/metrics` desde dentro de `homelab`:

```bash
docker exec prometheus wget -qO- http://node-exporter:9100/metrics | head -20
# # HELP go_gc_duration_seconds A summary of the wall-time pause (stop-the-world) duration in garbage collection cycles.
# # TYPE go_gc_duration_seconds summary
# ...
# # HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.
# # TYPE node_cpu_seconds_total counter
# node_cpu_seconds_total{cpu="0",mode="idle"} 12345.67
# ...
```

Confirmar el _target_ en Prometheus:

```bash
docker exec prometheus wget -qO- \
    'http://localhost:9090/api/v1/targets?state=active' \
    | python3 -c "import json,sys;d=json.load(sys.stdin);[print(t['labels']['job'],t['labels'].get('instance',''),t['health']) for t in d['data']['activeTargets']]"
# prometheus pi5 up    # ojo: 'instance' del job 'prometheus' no se reescribe; será 'prometheus:9090'
# grafana    grafana:3000 up
# node       pi5 up
```

> Si un `instance` queda como `node-exporter:9100` en lugar de `pi5`, la sección `relabel_configs` del `prometheus.yml` no se aplicó (probablemente por un YAML mal indentado). Validar y recargar.

Verificar la `up{job="node"}` directamente:

```bash
docker exec prometheus wget -qO- \
    'http://localhost:9090/api/v1/query?query=up{job=%22node%22}' \
    | python3 -m json.tool
# {"status":"success", ..., "result":[{"metric":{"__name__":"up","instance":"pi5","job":"node",...},"value":[..., "1"]}]}
```

Confirmar la temperatura del SoC (sanity check específico de Pi 5):

```bash
docker exec prometheus wget -qO- \
    'http://localhost:9090/api/v1/query?query=node_hwmon_temp_celsius' \
    | python3 -m json.tool | head -30
# Debe mostrar al menos un sample con label chip=cpu_thermal-virtual-0
# y un value entre 30 y 70 (°C en idle/uso normal de Pi 5).
```

---

## Verificación final

Antes de pasar a `docs/05-monitorizacion/04-cadvisor.md`, comprobar:

- [ ] `docker compose -f ~/homelab/monitor/docker-compose.yml ps` muestra `prometheus`, `grafana` y `node-exporter` en `Up`.
- [ ] `docker logs node-exporter --tail 30` muestra `msg="Listening on" address=:9100` y, justo antes, una línea `msg="Enabled collectors"` con la lista exacta declarada en el `command:` (cpu, cpufreq, loadavg, meminfo, vmstat, netdev, netstat, sockstat, filesystem, diskstats, hwmon, thermal_zone, time, uname, os, boottime, entropy, pressure, stat, filefd). Si aparecen colectores extra, `--collector.disable-defaults` no se interpoló.
- [ ] `docker exec prometheus wget -qO- http://node-exporter:9100/metrics | grep -c '^node_'` devuelve un número entre 200 y 600 (típico para los colectores activados; <50 es síntoma de que algún colector falló silenciosamente).
- [ ] `docker exec prometheus promtool check config /etc/prometheus/prometheus.yml` devuelve `Checking 3 scrape configs: SUCCESS`.
- [ ] `https://prometheus.lan/targets` (tras login 2FA) muestra **tres** _targets_, todos `UP`: `prometheus`, `grafana` y `node` (con `instance="pi5"`, no `node-exporter:9100`).
- [ ] `https://prometheus.lan/graph?g0.expr=node_load1&g0.tab=0` (tras login 2FA) devuelve un valor entre 0 y 4 (el _load_ típico de la Pi 5 con el homelab básico).
- [ ] `https://prometheus.lan/graph?g0.expr=node_hwmon_temp_celsius` devuelve al menos una serie con `chip="cpu_thermal-virtual-0"` y un valor entre 30 y 70.
- [ ] `https://grafana.lan/dashboards` (tras login 2FA) muestra **dos** _dashboards_ en la carpeta `Homelab`: `Prometheus 2.0 Stats` y `Node Exporter Full`.
- [ ] Abrir `Node Exporter Full`: el _variable_ `instance` ofrece sólo `pi5`; los paneles `CPU Busy`, `Sys Load`, `RAM Used`, `Network Traffic by Interface`, `Disk Space Used`, `CPU Temperature` muestran datos reales (no "No data" ni "N/A"). El panel `CPU Temperature` lee `node_hwmon_temp_celsius{chip="cpu_thermal-virtual-0"}` (la Pi 5 no tiene `coretemp` x86; el panel original pinta sin _filter_ y muestra la del SoC sin más).
- [ ] `node_filesystem_avail_bytes` devuelve sólo las particiones reales — `/`, `/boot/firmware` (en Pi OS Bookworm), `/mnt/hd5t`, `/mnt/hd2t`. **No** muestra `/var/lib/docker/overlay2/<id>/...` ni `tmpfs` efímeros: si los muestra, los regex `mount-points-exclude` o `fs-types-exclude` no se aplicaron (pista: los `$$` se interpolaron mal a `$`).
- [ ] `node_network_receive_bytes_total` devuelve series para `eth0` (y `tailscale0` cuando la fase 3 lo levante), pero **no** para `veth*`/`br-<hex>`/`docker0`. Si aparecen `veth*`, el `device-exclude` no se aplicó.
- [ ] `docker logs prometheus --tail 20 | grep -i error` no muestra errores nuevos relacionados con `node`.
- [ ] Tras un `docker compose -f ~/homelab/monitor/docker-compose.yml restart node-exporter`, el _target_ vuelve a `UP` en <15 s y las series no se interrumpen visiblemente en Grafana (gap de 1 _scrape_ — 15 s — esperable).
- [ ] Tras un `sudo reboot` de la Pi, `node-exporter` arranca solo (`restart: unless-stopped`) y `up{job="node"}` vuelve a `1` en <60 s. El _dashboard_ `Node Exporter Full` muestra la métrica `node_boot_time_seconds` actualizada al nuevo _epoch_.
- [ ] `git -C ~/homelab status` muestra como **modificados**: `monitor/docker-compose.yml`, `monitor/.env.example`, `monitor/prometheus/prometheus.yml`. Y como **nuevo**: `monitor/grafana/dashboards/node-exporter-full.json`. **No** muestra `monitor/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add monitor/docker-compose.yml monitor/.env.example \
          monitor/prometheus/prometheus.yml \
          monitor/grafana/dashboards/node-exporter-full.json
  git commit -m "feat(monitor): add Node Exporter with Pi 5 collector set and dashboard 1860"
  ```

---

## Operaciones habituales

### Ver `/metrics` a ojo

```bash
# Todas las métricas (filtrar con grep):
docker exec prometheus wget -qO- http://node-exporter:9100/metrics

# Sólo CPU:
docker exec prometheus wget -qO- http://node-exporter:9100/metrics | grep '^node_cpu_'

# Sólo temperaturas:
docker exec prometheus wget -qO- http://node-exporter:9100/metrics | grep '^node_hwmon_temp'
```

### Activar el _textfile collector_ (cuando llegue)

Para que Borgmatic exponga "días desde el último _backup_" como métrica (ejemplo del que se usará en `docs/07-backups/02-borgmatic.md`):

1. Crear un directorio en el host:

   ```bash
   sudo mkdir -p /var/lib/node_exporter/textfile_collector
   sudo chown 65534:65534 /var/lib/node_exporter/textfile_collector
   sudo chmod 0755 /var/lib/node_exporter/textfile_collector
   ```

2. Añadir al `command:` del compose:

   ```yaml
       - --collector.textfile
       - --collector.textfile.directory=/host/var/lib/node_exporter/textfile_collector
   ```

3. Añadir al `volumes:` del compose:

   ```yaml
       - /var/lib/node_exporter/textfile_collector:/host/var/lib/node_exporter/textfile_collector:ro
   ```

4. `docker compose -f ~/homelab/monitor/docker-compose.yml up -d node-exporter`.

5. Cualquier `*.prom` válido en ese directorio aparecerá en `/metrics`. Formato:

   ```
   # HELP borgmatic_last_backup_seconds Seconds since the last successful backup.
   # TYPE borgmatic_last_backup_seconds gauge
   borgmatic_last_backup_seconds{repo="hd2t"} 86400
   ```

### Activar el colector `processes` (si quieres `node_processes_*`)

1. Añadir al compose, en el servicio `node-exporter`:

   ```yaml
       pid: host
       command:
         # ... resto sin cambios ...
         - --collector.processes
   ```

2. `docker compose -f ~/homelab/monitor/docker-compose.yml up -d node-exporter`.

3. Verificar `node_processes_state{state="R"}` en Prometheus.

> **Trade-off**: con `pid: host`, el contenedor ve los PIDs del host, no sólo los suyos. Sigue siendo `read-only` por _flag_, pero amplía la superficie. Recomendado **sólo si** algún _dashboard_ o _alert_ lo necesita.

### Desactivar/activar un colector sin _restart_

No hay forma — los _flags_ se leen al arrancar. Hay que `docker compose up -d node-exporter` (recreación, ~3 s de _downtime_ del _scrape_).

---

## Backup

| Qué                                            | Dónde                                                       | Cómo                                            |
|------------------------------------------------|-------------------------------------------------------------|-------------------------------------------------|
| `docker-compose.yml`, `prometheus.yml`         | `~/homelab/monitor/`                                        | git                                             |
| `node-exporter-full.json`                      | `~/homelab/monitor/grafana/dashboards/`                     | git                                             |
| _Estado del propio Node Exporter_              | (no aplica — _stateless_)                                   | n/a                                             |

> **Restauración**: clonar el repo, `make up STACK=monitor`, recargar Prometheus. En segundos vuelve a haber `up{job="node"} == 1` y el _dashboard_ vuelve a pintar. Las series **históricas** de Node Exporter están en el TSDB de Prometheus (`/mnt/hd2t/services/prometheus/data/`), respaldadas por el plan de Prometheus.

---

## Troubleshooting

### `node-exporter` arranca y muere en bucle: `error opening directory "/host/proc": permission denied`

Los _bind mounts_ están bien declarados pero el _UID_ `65534` no puede leer `/host/proc`. Causa típica: la opción `hidepid=2` del _kernel_ está activa en `/proc` (`mount -o remount,hidepid=2 proc /proc`). Confirmar:

```bash
mount | grep ' on /proc '
# proc on /proc type proc (rw,nosuid,nodev,noexec,relatime,hidepid=2)
```

Solución: o se quita `hidepid=2` del _fstab_ (no recomendable: es un _hardening_), o se añade el grupo `proc` al contenedor con `group_add`. La Pi OS Lite **no** activa `hidepid` por defecto, así que en un homelab estándar este error no aparece. Si aparece, casi seguro hubo un paso de _hardening_ extra en `docs/01-sistema/03-seguridad-base.md`.

### `node_filesystem_*` muestra cientos de _series_ con `mountpoint="/var/lib/docker/overlay2/<id>/..."`

El regex de `--collector.filesystem.mount-points-exclude` no se aplicó. Causas:

1. **`$` en lugar de `$$`** en el `command:` del compose. Compose interpoló `$dev` (vacío) y rompió el regex. Confirmar:

   ```bash
   docker exec node-exporter cat /proc/1/cmdline | tr '\0' '\n' | grep mount-points-exclude
   # Debe terminar en '($|/)' — si termina en '(|/)' o sin '($|...', está roto.
   ```

   Solución: editar el compose y duplicar el `$` (`$$|/`), `up -d node-exporter`.

2. **Sintaxis YAML mal anidada**: el _flag_ acabó en otro servicio o se cortó en mitad. Validar con `docker compose ... config`.

### `node_network_*` muestra cientos de _series_ con `device="veth..."`

Mismo síntoma, mismo culpable: el regex `--collector.netdev.device-exclude` no llegó al binario. Diagnóstico igual al anterior.

### El _target_ `node` aparece en Prometheus pero `up=0` con `error="dial tcp: lookup node-exporter on 127.0.0.11:53: no such host"`

`node-exporter` no está en la red `homelab`. Confirmar:

```bash
docker network inspect homelab --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}'
# Debe listar 'node-exporter'.
```

Si no aparece: revisar la sección `networks:` del servicio en el compose. Debe ser `networks: { homelab: { aliases: [ node-exporter ] } }`.

### El _dashboard_ `Node Exporter Full` aparece pero los paneles dicen "No data"

Causas en orden de probabilidad:

1. **Placeholder `${DS_PROMETHEUS}` no sustituido**:

   ```bash
   grep -c 'DS_PROMETHEUS' ~/homelab/monitor/grafana/dashboards/node-exporter-full.json
   # 0 si todo bien; >0 = problema.
   ```

   Repetir el `sed -i 's/\${DS_PROMETHEUS}/Prometheus/g' ...` y esperar 30 s al re-provisioning.

2. **`instance` no se reescribió a `pi5`**: el _dashboard_ filtra por `$instance`, y si no hay opción `pi5` selecciona la primera (`node-exporter:9100`) que también funciona, pero algunos paneles que filtran adicionalmente por `nodename` rompen. Confirmar:

   ```bash
   docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/label/instance/values'
   # {"status":"success","data":["pi5","prometheus:9090","grafana:3000"]}
   # 'pi5' debe estar.
   ```

3. **Colector ausente**: el panel pide `node_systemd_unit_state` (colector `systemd`), que está OFF. No hay arreglo limpio salvo activarlo (no recomendado, ver _Decisiones_) o aceptar el panel vacío.

### `node_hwmon_temp_celsius` no aparece (panel "CPU Temperature" en blanco)

En la Pi 5 con kernel ≥6.1 el sensor del SoC se llama `cpu_thermal-virtual-0`. Confirmar a mano:

```bash
ls /sys/class/hwmon/
# hwmon0 hwmon1 ...
cat /sys/class/hwmon/hwmon0/name
# cpu_thermal
cat /sys/class/hwmon/hwmon0/temp1_input
# 45230  (= 45.230 °C)
```

Si el sensor existe en el host pero `/metrics` no lo expone, casi seguro el _flag_ `--collector.hwmon` se omitió (revisar `docker exec node-exporter cat /proc/1/cmdline | tr '\0' '\n'`). Si no existe en el host (`hwmon0` no presente), hay un problema de _kernel_/`raspi-firmware` y se sale del alcance de este doc — ver `docs/01-sistema/02-configuracion-inicial.md`.

### Cardinalidad sigue creciendo tras añadir Node Exporter

Esperable: ~300-500 series nuevas (CPU × cores × modes + filesystem × mountpoints + netdev × interfaces + hwmon × sensors + … ). En la Pi 5 con la lista del homelab, total estimado <500.

Si crece a >5000: probablemente algún colector ruidoso se coló:

```bash
docker exec prometheus wget -qO- \
    'http://localhost:9090/api/v1/query?query=count by (__name__) ({job="node"})' \
    | python3 -c "import json,sys;d=json.load(sys.stdin);[print(r['metric']['__name__'],'=',r['value'][1]) for r in sorted(d['data']['result'],key=lambda r: -int(r['value'][1]))[:20]]"
```

Top métricas por cardinalidad. Si ves `node_systemd_*` con miles de series, el colector `systemd` se activó por error. Apagar y recargar.

### `level=warn ... msg="Failed to read /host/proc/<pid>/..."` en logs de Node Exporter

Procesos efímeros que existen en `/proc/<pid>/` cuando Node Exporter abre el directorio y desaparecen antes de leer el fichero. Es ruido inevitable del colector `processes` (que tenemos OFF). Si aparece sin haber activado `processes`, casi seguro algún otro colector raro se coló — comprobar `--collector.disable-defaults`.

### Tras un `apt full-upgrade` del host, Node Exporter pierde algunas series y aparecen otras nuevas

Esperable. Renombrados/eliminaciones de _kernel modules_, nuevos _hwmon_, etc. Las _alerts_ (cuando existan) que dependan de _label values_ exactos hay que revisarlas tras un _bump_ de kernel mayor.

---

## Referencias

- Node Exporter — Repo y _release notes_: <https://github.com/prometheus/node_exporter>
- Node Exporter — Lista de colectores y _flags_: <https://github.com/prometheus/node_exporter#collectors>
- Node Exporter — Imagen Docker oficial: <https://hub.docker.com/r/prom/node-exporter>
- Node Exporter — Texto de cada métrica (referencia): <https://github.com/prometheus/node_exporter/blob/master/docs/node-mixin/README.md>
- Grafana Labs — _Dashboard_ `Node Exporter Full` (ID 1860): <https://grafana.com/grafana/dashboards/1860-node-exporter-full/>
- Linux kernel — _Pressure Stall Information_ (PSI), origen de `node_pressure_*`: <https://docs.kernel.org/accounting/psi.html>
- Prometheus — _Best practices on instrumentation_ (`instance` label, `relabel_configs`): <https://prometheus.io/docs/practices/naming/>
- Raspberry Pi — `cpu_thermal` sensor (driver `bcm2835_thermal`): <https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#monitor-core-temperature>
