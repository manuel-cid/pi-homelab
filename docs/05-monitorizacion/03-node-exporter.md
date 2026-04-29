# Node Exporter

## Descripción

Con `01-prometheus.md` y `02-grafana.md` desplegados, el homelab ya tiene **dónde almacenar** y **cómo visualizar** métricas, pero todavía no tiene **qué visualizar**: los targets `node`, `cadvisor` y `caddy` aparecen como `down` en `https://prometheus.lan/targets`, los paneles del dashboard "Node Exporter Full" muestran `No data` y la pregunta básica del homelab — *"¿está la Pi sobrecalentada? ¿queda RAM? ¿se está llenando hd2t?"* — sigue resolviéndose con `htop` y `df -h` por SSH.

Este documento despliega **Node Exporter**, el exportador oficial de Prometheus para métricas de **sistema operativo Linux**. Su rol concreto:

1. **Exponer en `http://node-exporter:9100/metrics`**, dentro de la red Docker `homelab`, una página en formato OpenMetrics con cientos de series sobre el host: `node_cpu_seconds_total` (uso de CPU por modo y core), `node_memory_*` (memoria por categoría: free, available, buffers, cached, dirty, swap), `node_disk_*` y `node_filesystem_*` (IOPS, latencia, ocupación por punto de montaje), `node_network_*` (bytes, paquetes, errores por interfaz), `node_load1/5/15` (load average), `node_boot_time_seconds`, `node_time_seconds`, `node_uname_info`, etc.
2. **Exponer la temperatura del SoC del Pi 5** — el dato más vigilado del homelab — vía los colectores `hwmon` y `thermal_zone`: `node_hwmon_temp_celsius` y `node_thermal_zone_temp` leen `/sys/class/hwmon/*` y `/sys/class/thermal/thermal_zone*/temp` del kernel y convierten los milligrados del kernel a grados Celsius. El dashboard `1860` ("Node Exporter Full") ya tiene un panel preparado que pinta esa serie tal cual.
3. **Ser el primer target real de Prometheus**: cerrar este documento es lo que hace que el job `node` definido en `prometheus.yml` (Fase 5, doc 01) pase de `down` a `up`, y lo que llena de líneas el dashboard de Node Exporter Full en Grafana.
4. **Servir como paciente cero del flujo de provisioning de Fase 5**: si Node Exporter aparece y los dashboards lo pintan, el patrón está validado para `04-cadvisor.md` y para los exporters de fases siguientes (Pi-hole, Mosquitto, Jellyfin, Caddy ya activado).

Lo que este documento **no** decide:

- **Métricas de contenedores Docker** (CPU, RAM, red, disco *por contenedor*). Esa es la pregunta que responde cAdvisor en `04-cadvisor.md`. Node Exporter ve el host como un todo: si Jellyfin se desboca y se come 6 GiB de RAM, Node Exporter verá "memoria del host bajando" pero no "Jellyfin culpable"; cAdvisor cierra el bucle.
- **Métricas de la red doméstica** (clientes Pi-hole, throughput de routers, IPs activas). Eso vive en `pi-hole-exporter` (Fase 8/9), fuera del alcance de Node Exporter.
- **Métricas de discos S.M.A.R.T.** (`smartctl`, errores ECC, horas de uso). Node Exporter no las recoge directamente; existe el `smartctl_exporter` y el patrón de "textfile collector" (`smartmon.sh` + `--collector.textfile`). Este documento **prepara** el directorio del textfile collector pero no escribe scripts de SMART (queda para una iteración posterior, ver "Decisiones que no se toman").
- **Exposición vía Caddy con login**. Node Exporter es un endpoint puramente de máquina-a-máquina: sólo Prometheus lo lee. Ningún humano necesita abrir `https://node-exporter.lan/metrics` en un navegador. Por tanto **no se crea drop-in en Caddy**, no se añade entrada en Authelia, y el contenedor no publica `ports:` al host. Visibilidad mínima necesaria, ataque mínimo.
- **Alertas concretas** ("temperatura > 75 °C", "filesystem > 90 %"). Las series están aquí desde hoy; las reglas de alerta son responsabilidad de Alertmanager, que no se despliega en Fase 5 (ver "Decisiones que no se toman" en `01-prometheus.md`).

Cuando este documento se haya aplicado, el operador puede:

- Ver en `https://prometheus.lan/targets` que el job `node` está `up` con instance `pi5`.
- Lanzar en el portal de Prometheus la query `node_load1` y obtener un valor (típicamente entre `0.1` y `1.5` en un Pi 5 sin carga punta).
- Abrir en Grafana el dashboard "Node Exporter Full" y ver paneles con datos reales: CPU por core, memoria, red, disco, filesystem, **temperatura del SoC**.
- Confirmar con `docker exec prometheus wget -qO- http://node-exporter:9100/metrics | wc -l` que el exporter responde y devuelve varias miles de líneas.

> **Recordatorio de alcance**: Node Exporter escucha **solo** en la red Docker `homelab`; no publica `ports:` al host. La única forma de llegar a `:9100` es desde otro contenedor de la misma red Docker (en la práctica: Prometheus). Ningún cliente LAN, ningún cliente VPN, ningún proceso humano accede directamente al endpoint. La exposición efectiva es cero más allá del scrape de Prometheus.

---

## Requisitos Previos

- **Fase 2** completa (Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN=lan`).
- **`01-prometheus.md` aplicado**: el job `node` ya existe en `prometheus.yml` (apuntando a `node-exporter:9100`) y aparece como `down` esperando este documento. Tras `up -d` debe pasar a `up` sin tocar `prometheus.yml`.
- **`02-grafana.md` aplicado** (recomendado, no estricto): el dashboard "Node Exporter Full" (ID `1860`) ya está provisionado y empezará a renderizar paneles en cuanto Node Exporter empiece a emitir.
- Kernel del host con los sysfs habituales montados:
  - `/proc/` — procfs estándar.
  - `/sys/class/thermal/thermal_zone*/temp` — fuente de temperatura del SoC (estándar en Raspberry Pi OS).
  - `/sys/class/hwmon/hwmon*/` — sensores hardware (puede estar vacío en algunos Pi 5; el colector `thermal_zone` es el que cubre la temperatura del SoC).
- No hace falta espacio significativo en `hd2t`: Node Exporter no persiste datos. El único directorio que se crea (textfile collector) ocupa kilobytes.

Comprobaciones rápidas:

```bash
# La red Docker compartida existe
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Prometheus está corriendo y tiene el job `node` declarado en `down`
curl -ks https://prometheus.lan/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="node") | {health, scrapeUrl}'
# {
#   "health": "down",
#   "scrapeUrl": "http://node-exporter:9100/metrics"
# }

# El kernel expone temperatura del SoC
cat /sys/class/thermal/thermal_zone0/temp
# 48512   (= 48.512 °C; se divide por 1000)

# /sys/class/hwmon existe (puede estar vacío en Pi 5; no es bloqueante)
ls /sys/class/hwmon/ 2>/dev/null || echo "vacío (ok, se usa thermal_zone)"
```

---

## Decisión: imagen y versión

Prometheus publica imágenes oficiales multi-arch (`amd64`, `arm64`, `armv7`) en Docker Hub bajo `prom/node-exporter` y mirror en Quay (`quay.io/prometheus/node-exporter`). Para la Pi 5 (aarch64) se usa el manifest `arm64` automáticamente.

| Tag | Cuándo usar | Decisión aquí |
|---|---|---|
| `latest` | Demos. | Descartado (convención de Fase 2). |
| `v1` | "Última 1.x". | Descartado: minors han traído defaults de colectores distintos (`netdev` vs `netclass`, `processes` deshabilitado en 1.7+). |
| `v1.8` | Última `v1.8.x`. | Aceptable; Node Exporter es estable bumpeando patch. |
| `v1.8.2` (ejemplo) | Versión exacta `MAYOR.MENOR.PARCHE`. | **Aceptado** como compromiso entre reproducibilidad y mantenimiento. |
| `v2.x` | Cuando exista la rama 2.x. | Diferido: hoy no hay 2.x estable. |

> **Tag exacto en uso**: `prom/node-exporter:v1.8.2`. Si en el momento de aplicar este documento existe una `v1.8.x` superior con changelog limpio (sin colectores nuevos habilitados por defecto y sin renombrado de métricas), se actualiza el tag aquí y en `docker-compose.yml`. **Nunca `latest`**.

> **Por qué Node Exporter y no Telegraf / collectd / netdata-exporter**. Telegraf es más flexible y soporta múltiples backends, pero rompe la convención "un exporter por dominio" del ecosistema Prometheus y requiere TOML extra. collectd está bien pero el camino oficial es `collectd_exporter`, una capa de traducción innecesaria. netdata es un agente entero con su propia UI y telemetría, mucho más de lo necesario aquí. Node Exporter es **la** opción canónica: todos los dashboards comunitarios (incluido `1860`) están escritos para sus métricas; los nombres `node_cpu_seconds_total`, `node_memory_MemAvailable_bytes`, `node_filesystem_avail_bytes` son ya un dialecto estándar.

---

## Decisión: cómo se monta el host (procfs, sysfs, rootfs)

Node Exporter es un binario de Go que lee ficheros de `/proc` y `/sys`; eso significa que dentro del contenedor necesita ver **el procfs y sysfs del host**, no los del contenedor. La práctica estándar (la que documenta el repositorio oficial de `node_exporter`) es:

| Bind mount | Modo | Para qué |
|---|---|---|
| `/proc:/host/proc` | `ro` | Procfs del host. Sin este mount, el contenedor expone `/proc` propio (filtrado por su PID namespace) y todas las series de procesos, swap, uptime y CPU se distorsionan. |
| `/sys:/host/sys` | `ro` | Sysfs del host. Necesario para `node_hwmon_temp_celsius`, `node_thermal_zone_temp`, `node_filesystem_*`, `node_network_*` (las clases viven en `/sys/class/...`). |
| `/:/rootfs` | `ro,rslave` | Acceso al rootfs del host para que el colector `filesystem` enumere puntos de montaje reales (en lugar de los del contenedor). `rslave` propaga unmounts del host hacia el contenedor en sólo lectura: si el operador desmonta `hd2t`, Node Exporter deja de medirlo. |

Con esos mounts, hay que indicarle a Node Exporter dónde están con flags:

```text
--path.procfs=/host/proc
--path.sysfs=/host/sys
--path.rootfs=/rootfs
```

> **Por qué no `pid: host` ni `network_mode: host`**. Hay dos modos posibles de hacer esto bien:
>
> 1. **`network_mode: host` y `pid: host`**: el contenedor comparte namespaces con el host. Acceso 1:1 a `/proc` y a la pila de red. Inconveniente: el endpoint `:9100` queda escuchando en **todas las interfaces del host** (LAN incluida); para evitarlo hay que pasar `--web.listen-address=127.0.0.1:9100`, lo cual rompe el scrape desde la red Docker `homelab` (Prometheus no puede llegar a `127.0.0.1` del host desde su propio namespace).
> 2. **Red Docker `homelab` + bind mounts** (`/proc`, `/sys`, `/`): el contenedor comparte filesystem (vía mount) pero **no namespaces**. Prometheus llega por DNS a `node-exporter:9100`. Casi todas las métricas son idénticas porque viven en sysfs/procfs (que sí está mapeado). Las diferencias son pequeñas: `node_processes_state` cuenta procesos del namespace del contenedor (que es 1: el propio Node Exporter); `node_netstat_*` mira la pila de red del contenedor (vacía). El homelab acepta esa mínima pérdida a cambio de homogeneidad con el resto de exporters y de la garantía de "sin puertos en el host".
>
> Resultado: **opción 2**. Si en el futuro se quiere recuperar `node_processes_state` y `node_netstat_*` reales, se añade `pid: host` y se mantiene la red Docker (Prometheus seguiría llegando por DNS). El cambio es de una línea y no invalida nada.

---

## Decisión: colectores activados y desactivados

Node Exporter tiene ~60 colectores; cada uno se puede habilitar (`--collector.<name>`) o deshabilitar (`--no-collector.<name>`). El conjunto por defecto está bien pensado para servidores genéricos; en la Pi 5 con homelab Docker hay que afinar:

| Colector | Default | En este homelab | Razón |
|---|---|---|---|
| `cpu` | on | **on** | Indispensable. |
| `meminfo` | on | **on** | Indispensable. |
| `loadavg` | on | **on** | Indispensable. |
| `filesystem` | on | **on**, con exclusión | Habilitado, pero filtrando los puntos de montaje del propio Docker (`/var/lib/docker/...`, overlays de contenedores) para no inflar la cardinalidad. |
| `diskstats` | on | **on** | IOPS y latencia de la microSD y `hd5t`/`hd2t`. |
| `netdev` | on | **on**, con exclusión | Excluir interfaces virtuales (`veth*`, `docker0`, `br-*`, `lo`) que no aportan información del homelab. |
| `netclass` | on | **on**, con exclusión | Idem. |
| `hwmon` | on | **on** | Temperatura del SoC en Pi 5 (cuando el kernel la expone vía hwmon). |
| `thermal_zone` | on | **on** | Fuente alternativa y robusta de temperatura del SoC en Raspberry Pi OS. |
| `pressure` | on | **on** | PSI (CPU/IO/memory pressure) — kernel 4.20+, indicadores tempranos de saturación. |
| `time`, `uname`, `boottime`, `os`, `stat`, `vmstat` | on | **on** | Coste cero, valor alto. |
| `systemd` | off | **off** | Requiere mount del DBus socket; el homelab no monitoriza unidades systemd individuales (los servicios viven en Docker). |
| `processes` | off | **off** | Sin `pid: host` no aporta información útil. |
| `wifi`, `infiniband`, `ipvs`, `nfs`, `nfsd`, `bonding`, `bcache`, `mountstats` | off (varios off) | **off** explícito | Hardware/software que el Pi 5 no tiene. Reduce el binario de scrape (~5 % menos series, ~5 % menos tiempo) y elimina ruido en `up == 0` por colectores que fallan. |
| `textfile` | off | **on**, con `--collector.textfile.directory` | Permite añadir métricas custom escribiendo ficheros `.prom` en una carpeta. Hoy queda preparado y vacío; ideal para futuros scripts (estado de Borg, output de SMART, métricas del UPS). |
| `tcpstat` | off | **off** | Lee `/proc/net/tcp` entero — caro en hosts con miles de conexiones; el homelab no las tiene, pero el colector `netstat` ya cubre TCP a alto nivel. |
| `arp`, `entropy`, `edac`, `filefd`, `nvme`, `powersupplyclass`, `rapl` | on | **on** (no se desactivan) | Coste mínimo, valor situacional (UPS USB con `power_supply` aparece automáticamente). |

Esto se traduce en un puñado de flags en el `command:`:

```text
--collector.textfile.directory=/var/lib/node_exporter/textfile
--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc|rootfs/var/lib/docker/.+|rootfs/var/lib/containerd/.+|rootfs/run/docker/.+)($|/)
--collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$
--collector.netdev.device-exclude=^(veth.*|docker.*|br-.*|lo)$
--collector.netclass.ignored-devices=^(veth.*|docker.*|br-.*|lo)$
--no-collector.systemd
--no-collector.wifi
--no-collector.ipvs
--no-collector.infiniband
--no-collector.nfs
--no-collector.nfsd
--no-collector.bonding
--no-collector.bcache
--no-collector.mountstats
--no-collector.tcpstat
```

> **Sobre cardinalidad**. Cada colector aporta entre 5 y ~200 series. El conjunto resultante se queda en torno a **500 series** activas para la Pi 5 — el rango "sano" del homelab según `01-prometheus.md`. Sin las exclusiones, los colectores `netdev`/`filesystem` solos pueden añadir 200+ series fantasma (interfaces `vethXXXX` que aparecen y desaparecen con cada `docker run`), inflando el WAL y el índice TSDB.

---

## Decisión: exposición y endpoint

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| `expose: ["9100"]` (red Docker, sin `ports:`) | Sólo accesible desde otros contenedores en `homelab`; superficie cero. Prometheus llega por DNS. | El operador no puede `curl http://192.168.1.10:9100/metrics` desde su laptop sin ayuda. | **Aceptado**. |
| `ports: ["9100:9100"]` | El operador puede curl-ear desde la LAN. | Cualquier dispositivo de la LAN ve métricas detalladas del Pi 5 (uptime, kernel, sistemas de ficheros) — fingerprinting sencillo. | Descartado. |
| `ports: ["127.0.0.1:9100:9100"]` | Sólo accesible desde el host. | Prometheus está en una red Docker, no llega a `127.0.0.1` del host. | Descartado: no encaja con el patrón. |
| Caddy + `(authelia_two_factor)` | Endpoint humano disponible. | Ningún humano necesita ver `/metrics` en bruto; Grafana ya lo dibuja. | Descartado: ceremonia sin valor. |

Resultado: **`expose: ["9100"]` y nada más**. Para depurar manualmente, el flujo es siempre desde el contenedor de Prometheus o uno *ad-hoc* en la red `homelab`:

```bash
docker exec prometheus wget -qO- http://node-exporter:9100/metrics | head
# Útil para confirmar formato OpenMetrics y métricas presentes.
```

---

## Decisión: textfile collector — directorio y permisos

El textfile collector lee ficheros `.prom` de un directorio y publica su contenido como métricas. Es el mecanismo estándar para añadir métricas custom (script de SMART, estado de Borg, contadores propios) sin escribir un exporter completo.

| Aspecto | Decisión |
|---|---|
| **Ruta dentro del contenedor** | `/var/lib/node_exporter/textfile`. |
| **Ruta en el host** | `/mnt/hd2t/apps/node-exporter/textfile`. |
| **Owner** | `nobody:nobody` (UID/GID `65534:65534`) para que coincida con el usuario interno del binario oficial; los scripts que escriban allí (futuros) deben hacer `sudo -u nobody` o emitir a `/tmp/<file>.prom.$$` y `mv` final con `chown 65534:65534`. |
| **Modo** | `0750` en el directorio, `0640` en los ficheros. |
| **Hoy** | Vacío. La presencia del bind mount es la "puerta" para añadir scripts en el futuro sin redeploy. |

> **Importante: atomicidad del escritor**. La pauta canónica de los scripts que producen ficheros del textfile collector es escribir a `<destino>.prom.$$` y hacer `mv` al final. Sin atomicidad, Node Exporter puede leer un fichero a medias y reportar series rotas. Esto se documentará dentro del subdocumento que despliegue cada generador (SMART, Borg). En este documento sólo se reserva el directorio.

---

## Stack: `stacks/node-exporter/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/node-exporter/docker-compose.yml` | microSD (git) | Stack (servicio `node-exporter`). |
| `stacks/node-exporter/.env.example` | microSD (git) | Plantilla (vacía hoy). |
| `/mnt/hd2t/apps/node-exporter/textfile/` | hd2t | Carpeta para el textfile collector (vacía hoy). Owner `65534:65534`. |

> **Nota**: no hay drop-in en Caddy (ver "Decisión: exposición y endpoint") y no hay configuración propia: Node Exporter es 100 % flags, sin fichero de configuración.

### `stacks/node-exporter/docker-compose.yml`

```yaml
# Node Exporter — métricas del sistema operativo del homelab (Pi 5).
# Documentado en docs/05-monitorizacion/03-node-exporter.md.

name: node-exporter

services:
  node-exporter:
    image: prom/node-exporter:v1.8.2
    container_name: node-exporter
    hostname: node-exporter
    restart: unless-stopped

    # No publica `ports:` al host: sólo accesible vía red Docker `homelab`.
    expose:
      - "9100"

    # Sin `pid: host` ni `network_mode: host`: ver "Decisión: cómo se monta
    # el host". Las métricas vienen del bind mount de procfs/sysfs.

    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--path.rootfs=/rootfs'
      - '--web.listen-address=0.0.0.0:9100'
      - '--web.telemetry-path=/metrics'
      - '--log.level=info'
      # --- Textfile collector (vacío hoy; preparado para SMART/Borg/UPS) ---
      - '--collector.textfile.directory=/var/lib/node_exporter/textfile'
      # --- Filesystem: excluir overlays Docker y FS sintéticos ---
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc|rootfs/var/lib/docker/.+|rootfs/var/lib/containerd/.+|rootfs/run/docker/.+)($$|/)'
      - '--collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$$'
      # --- Red: excluir interfaces virtuales de Docker ---
      - '--collector.netdev.device-exclude=^(veth.*|docker.*|br-.*|lo)$$'
      - '--collector.netclass.ignored-devices=^(veth.*|docker.*|br-.*|lo)$$'
      # --- Colectores deshabilitados (hardware/software inexistente en Pi 5) ---
      - '--no-collector.systemd'
      - '--no-collector.wifi'
      - '--no-collector.ipvs'
      - '--no-collector.infiniband'
      - '--no-collector.nfs'
      - '--no-collector.nfsd'
      - '--no-collector.bonding'
      - '--no-collector.bcache'
      - '--no-collector.mountstats'
      - '--no-collector.tcpstat'

    environment:
      TZ: ${TZ}

    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro,rslave
      - /mnt/hd2t/apps/node-exporter/textfile:/var/lib/node_exporter/textfile:ro

    networks:
      - homelab

    healthcheck:
      # /metrics responde 200 en cuanto el binario está escuchando.
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:9100/metrics"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

    labels:
      homelab.role: "metrics-exporter"
      homelab.backup: "false"   # sin estado: el binario no persiste nada.
      com.centurylinklabs.watchtower.enable: "true"

networks:
  homelab:
    external: true
```

> **Sobre `$$` en los regex**. Compose interpola variables `${VAR}` y `$VAR` en el YAML antes de pasarlo a Docker. Para que un `$` literal sobreviva al parser (necesario en los anclajes `$` final de los regex de exclusión), hay que escribirlo `$$`. Sin la duplicación, Compose se queja de "Invalid interpolation format" al `up -d`.

> **Sobre `ro,rslave` en `/:/rootfs`**. `ro` impide cualquier escritura desde el contenedor. `rslave` propaga las operaciones de mount/unmount del host hacia el contenedor pero **no** al revés: si el operador desmonta `hd2t` o `hd5t`, el contenedor lo verá inmediatamente (y Node Exporter dejará de reportar `node_filesystem_*` para esos puntos), pero el contenedor no puede emitir mounts que afecten al host. Es la combinación segura recomendada por la documentación oficial.

> **Sobre el textfile mount como `:ro`**. El contenedor sólo lee los `.prom` que produzcan otros procesos (scripts del operador). Montar la carpeta como `:ro` impide que un Node Exporter comprometido pudiera escribir métricas falsas o saturar el disco con basura.

> **Sobre la ausencia de `user:`**. La imagen oficial corre como `nobody` (UID `65534`) por defecto; no se fuerza con `--user` para no chocar con la convención y porque la única ruta de escritura potencial (`/var/lib/node_exporter/textfile`) está montada `:ro`.

### `stacks/node-exporter/.env.example`

```bash
# stacks/node-exporter/.env.example
# Variables específicas del stack Node Exporter. Las generales (TZ)
# vienen del .env GLOBAL del homelab.
#
# (Vacío en esta fase: Node Exporter no usa variables de entorno propias;
# toda su configuración va en flags del `command:` del compose.)
```

### Crear los directorios persistentes y desplegar

```bash
# Directorio del textfile collector (vacío hoy; preparado para futuros scripts).
sudo install -d -o 65534 -g 65534 -m 0750 /mnt/hd2t/apps/node-exporter
sudo install -d -o 65534 -g 65534 -m 0750 /mnt/hd2t/apps/node-exporter/textfile

# .env del stack (vacío en esta fase)
cd /home/homelab/homelab
set -a; source .env; set +a

cp stacks/node-exporter/.env.example stacks/node-exporter/.env
chmod 0600 stacks/node-exporter/.env

# Levantar Node Exporter
docker compose \
    -f stacks/node-exporter/docker-compose.yml \
    --env-file stacks/node-exporter/.env \
    up -d
```

Tras `up -d`:

```bash
docker ps --filter name=node-exporter
# CONTAINER ID  IMAGE                          STATUS                  PORTS    NAMES
# ...           prom/node-exporter:v1.8.2      Up 10 seconds (healthy)          node-exporter

docker compose -f stacks/node-exporter/docker-compose.yml logs --tail 20 node-exporter
# level=info ts=... msg="Starting node_exporter" version="(version=1.8.2, ...)"
# level=info ts=... msg="Enabled collectors"
# level=info ts=...   collector=cpu
# level=info ts=...   collector=diskstats
# level=info ts=...   collector=filesystem
# level=info ts=...   collector=hwmon
# level=info ts=...   collector=loadavg
# level=info ts=...   collector=meminfo
# level=info ts=...   collector=netdev
# level=info ts=...   collector=textfile
# level=info ts=...   collector=thermal_zone
# level=info ts=... msg="Listening on" address=0.0.0.0:9100
# level=info ts=... msg="TLS is disabled." http2=false address=0.0.0.0:9100
```

---

## Configuración

### 1) Verificar que Prometheus lo descubre

```bash
# Esperar uno o dos scrape intervals (30s+30s) y consultar el estado del target.
sleep 60
curl -ks https://prometheus.lan/api/v1/targets | \
    jq '.data.activeTargets[] | select(.labels.job=="node") | {health, lastError, lastScrape}'
# {
#   "health": "up",
#   "lastError": "",
#   "lastScrape": "2026-..."
# }
```

O desde la UI: `https://prometheus.lan/targets` → buscar `job=node` → `State: UP`. Esto **cierra** la primera mitad de la lista de targets pendientes de Fase 5.

### 2) Queries útiles para verificar la instalación

Desde la pestaña `Graph` de Prometheus o desde el panel de queries de Grafana:

```promql
# 1) El target está vivo
up{job="node"} == 1

# 2) Uptime del host (en segundos)
node_time_seconds - node_boot_time_seconds

# 3) Carga 1m
node_load1{instance="pi5"}

# 4) Memoria disponible (GiB)
node_memory_MemAvailable_bytes{instance="pi5"} / 1024 / 1024 / 1024

# 5) Uso de CPU (%) — todas las modalidades excepto idle
100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m])))

# 6) Temperatura del SoC del Pi 5 (°C) vía thermal_zone
node_thermal_zone_temp{type="cpu_thermal"}
# Alternativamente, vía hwmon (si está poblado en el kernel):
node_hwmon_temp_celsius

# 7) Espacio libre en hd5t (TiB)
node_filesystem_avail_bytes{mountpoint="/rootfs/mnt/hd5t",fstype!~"tmpfs|overlay"} / 1024 / 1024 / 1024 / 1024

# 8) Espacio libre en hd2t (GiB)
node_filesystem_avail_bytes{mountpoint="/rootfs/mnt/hd2t",fstype!~"tmpfs|overlay"} / 1024 / 1024 / 1024
```

> **Sobre el prefijo `/rootfs`** en `mountpoint`. Como el rootfs del host se monta dentro del contenedor en `/rootfs`, los puntos de montaje aparecen en las métricas con ese prefijo: `/rootfs/`, `/rootfs/mnt/hd2t`, `/rootfs/mnt/hd5t`, `/rootfs/boot/firmware`, etc. Es una característica del bind mount, no un bug. Los dashboards comunitarios (`1860`) usan `mountpoint=~"/rootfs.*"` o filtros equivalentes. Si en algún momento se quisiera "limpiar" la apariencia (`/mnt/hd2t` en vez de `/rootfs/mnt/hd2t`), se puede aplicar `metric_relabel_configs` en `prometheus.yml` job `node` para reescribir el label, pero rompe los dashboards comunitarios — se descarta.

### 3) Ver el dashboard "Node Exporter Full" en Grafana

Desde un cliente de la LAN con la CA interna ya instalada:

```text
1. Abrir https://grafana.lan/
2. Login Authelia + TOTP si aún no hay sesión.
3. Dashboards → carpeta "Homelab" → "Node Exporter Full".
4. En el selector de instance (arriba a la izquierda), elegir `pi5`.
5. Los paneles de CPU, Memory, Disk Space, Network y "Node Memory" se llenan
   en cuanto pasen 1–2 scrape intervals. Algunos paneles específicos (PSI,
   pressure, NVMe) pueden mostrar "No data" si el kernel del Pi 5 no expone
   esa fuente — comportamiento esperado.
6. Verificar el panel "Hardware temperature" en la sección "Node Memory" o
   "System": debe pintar la temperatura del SoC en una banda 40–65 °C.
```

> **Si el dashboard pintara "No data" para CPU/Memory** y el target está `up`: lo más probable es que el JSON del dashboard haya quedado con `datasource: "${DS_PROMETHEUS}"` (placeholder de la importación interactiva) en vez del UID estable `homelab-prometheus`. Se corrige según el procedimiento de `02-grafana.md` ("Cómo importar un dashboard de grafana.com como JSON local"), se materializa y Grafana lo recarga al siguiente `updateIntervalSeconds`.

### 4) Forzar un scrape manual desde Prometheus

Útil para depurar latencia o filtros incorrectos:

```bash
# Desde el contenedor de Prometheus, hacia node-exporter por DNS Docker:
docker exec prometheus wget -qO- http://node-exporter:9100/metrics | head -20
# # HELP node_arp_entries ARP entries by device
# # TYPE node_arp_entries gauge
# node_arp_entries{device="eth0"} 12
# # HELP node_boot_time_seconds Node boot time, in unixtime.
# # TYPE node_boot_time_seconds gauge
# node_boot_time_seconds 1.7515e+09
# ...

# Total de líneas (orientativo: ~5000–7000 con esta config):
docker exec prometheus wget -qO- http://node-exporter:9100/metrics | wc -l
```

### 5) Añadir métricas custom vía textfile collector (futuro)

El directorio ya está montado y con permisos correctos. Para añadir, por ejemplo, una métrica de "última copia Borg" desde un script del host:

```bash
# Ejemplo de script (NO se despliega aquí; es ilustrativo).
# Vivirá en /home/homelab/homelab/scripts/borg-status.sh y se ejecuta por cron.

cat > /tmp/borg_status.prom.$$ <<EOF
# HELP borg_last_backup_unixtime Última copia Borg exitosa (epoch).
# TYPE borg_last_backup_unixtime gauge
borg_last_backup_unixtime $(date +%s)
EOF

sudo chown 65534:65534 /tmp/borg_status.prom.$$
sudo mv /tmp/borg_status.prom.$$ /mnt/hd2t/apps/node-exporter/textfile/borg_status.prom
```

Tras este `mv`, la siguiente lectura de Node Exporter (en menos de 30 s) incluirá `borg_last_backup_unixtime` como serie real. La materialización concreta de scripts SMART/Borg/UPS llega en sus respectivas fases.

### 6) Operación diaria

| Acción | Comando |
|---|---|
| Verificar `up{job="node"}` | `https://prometheus.lan/graph?g0.expr=up%7Bjob%3D%22node%22%7D` |
| Ver salud del contenedor | `docker ps --filter name=node-exporter` |
| Tail de logs | `docker logs -f node-exporter` |
| Reiniciar Node Exporter | `docker compose -f stacks/node-exporter/docker-compose.yml restart node-exporter` |
| Tamaño del payload `/metrics` | `docker exec prometheus wget -qO- http://node-exporter:9100/metrics \| wc -c` |
| Listar métricas únicas | `docker exec prometheus wget -qO- http://node-exporter:9100/metrics \| grep -oE '^node_[a-z_]+' \| sort -u` |
| Listar colectores activos (vía métrica) | `docker exec prometheus wget -qO- http://node-exporter:9100/metrics \| grep '^node_scrape_collector_success'` |

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/node-exporter/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/node-exporter/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/proc` | host (kernel) | `root:root` | (procfs) | Procfs del host, montado `:ro` como `/host/proc` en el contenedor. |
| `/sys` | host (kernel) | `root:root` | (sysfs) | Sysfs del host, montado `:ro` como `/host/sys` en el contenedor. |
| `/` | host | `root:root` | — | Rootfs del host, montado `:ro,rslave` como `/rootfs` en el contenedor. |
| `/mnt/hd2t/apps/node-exporter/textfile/` | hd2t | `65534:65534` (`nobody`) | `0750` | Carpeta del textfile collector. Vacía hoy; futuros scripts escriben aquí. |

> **Tamaño esperado en disco**. Cero. Node Exporter no persiste nada (las métricas viven en la TSDB de Prometheus). El directorio del textfile collector ocupa kilobytes incluso con varios scripts activos: cada `.prom` típico son 1–10 KiB.

> **Por qué no `:ro` en los mounts del kernel**. `/proc` y `/sys` se montan `:ro`: aunque procfs/sysfs ya restringen las escrituras (sólo `root` con CAP_SYS_ADMIN puede tocar ciertos nodos), `:ro` es defensa en profundidad y deja claro que Node Exporter **lee** el host, no lo modifica. La excepción es `:ro,rslave` para `/`: necesita `rslave` para que los unmounts del host se propaguen, pero `ro` se mantiene.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/node-exporter/docker-compose.yml`, `.env.example` | Versionados. |
| Decisiones (colectores, filtros, exposure interna) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Por qué |
|---|---|---|
| `/mnt/hd2t/apps/node-exporter/textfile/` | **Sí** (cuando contenga ficheros). | Cada `.prom` representa el último valor conocido de una métrica externa (último backup Borg, último SMART). Aunque cada uno es regenerable por su script, respaldarlos da continuidad sin esperar al siguiente cron tras un restore. Coste ínfimo (kilobytes). |
| Series en la TSDB de Prometheus | Heredado de `01-prometheus.md`: **no se respalda**. | La TSDB es regenerable; tras un restore, Node Exporter vuelve a emitir y Prometheus rellena el head block en minutos. |

> **Política explícita: no hay estado propio que respaldar**. Node Exporter es completamente *stateless*. La única "memoria" del homelab que pasa por aquí son los ficheros del textfile collector — y esos los dueños son sus generadores (scripts SMART/Borg), que ya se respaldarán como parte del repositorio o de los datos del servicio que los produce.

Procedimiento de restore tras pérdida del contenedor:

```bash
docker compose -f /home/homelab/homelab/stacks/node-exporter/docker-compose.yml up -d --force-recreate
# Node Exporter remonta /proc, /sys, /, abre :9100 y vuelve a aparecer como
# `up` en Prometheus al siguiente scrape interval (≤30s). Cero pérdida real.
```

Procedimiento de restore tras pérdida total:

1. Recrear Fase 1, 2, 5 (docs 01 y 02).
2. Recrear el directorio `/mnt/hd2t/apps/node-exporter/textfile/` con `chown 65534:65534 -m 0750`.
3. (Opcional) Restaurar contenido del textfile desde Borg si se respaldó.
4. `docker compose -f stacks/node-exporter/docker-compose.yml up -d`.
5. Verificar en Prometheus: `up{job="node"} == 1`.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `up{job="node"} == 0` con `connection refused` | El contenedor está caído o aún no escucha. | `docker ps --filter name=node-exporter`; revisar logs. |
| `up{job="node"} == 0` con `dial tcp: lookup node-exporter on 127.0.0.11:53: no such host` | El contenedor no está en la red `homelab`. | Confirmar `networks: - homelab` en el compose; `docker network inspect homelab` debe listar `node-exporter`. |
| `node_filesystem_*` no muestra `hd2t` ni `hd5t` | Los discos no estaban montados al arrancar el contenedor, **o** el regex de exclusión de `mount-points-exclude` se comió `/rootfs/mnt/...`. | Confirmar con `docker exec prometheus wget -qO- http://node-exporter:9100/metrics \| grep node_filesystem_avail_bytes \| grep mnt`. Si no aparece, ajustar la regex y `up -d`. |
| `node_thermal_zone_temp` ausente o vacío | El kernel no expone `/sys/class/thermal/thermal_zone*/temp` (poco probable en Raspberry Pi OS). | `ls /sys/class/thermal/` desde el host. Si está vacío, usar `node_hwmon_temp_celsius` como fuente alternativa. |
| `node_hwmon_*` ausente | El Pi 5 (según versión del kernel) no siempre expone hwmon para el SoC. | No es un fallo: usar `node_thermal_zone_temp{type="cpu_thermal"}` en su lugar. El dashboard `1860` ya cubre ambas fuentes. |
| Varias series `vethXXXX` apareciendo y desapareciendo | El regex de `netdev.device-exclude` no coincide. | Confirmar las flags en `docker inspect node-exporter --format '{{range .Config.Cmd}}{{.}}{{"\n"}}{{end}}'`; en Compose hay que usar `$$` para el ancla `$` final. |
| Logs muestran `Couldn't get sysctl ... permission denied` | Algún colector intenta `sysctl` que requiere CAP_SYS_ADMIN. | Habitualmente inocuo (el colector deshabilita esa métrica concreta y sigue). Si molesta, deshabilitar el colector con `--no-collector.<name>`. |
| `level=error msg="Couldn't get tlsConfig: TLS is disabled."` al arrancar | Falsa alarma del binario en versiones recientes (es un `info` mal etiquetado). | Ignorar; el endpoint funciona en HTTP plano por diseño. |
| `du` reporta crecimiento sostenido en `/mnt/hd2t/apps/node-exporter/textfile/` | Algún script externo escribe `.prom` sin rotar. | Revisar el script: la pauta es **sobreescribir** el `.prom` con `mv` atómico, no acumular ficheros nuevos. |
| Compose se queja `Invalid interpolation format ... ${VAR}` al `up -d` | Falta `$$` para escapar los `$` finales en los regex. | Sustituir `$` por `$$` en los flags `--collector.filesystem.mount-points-exclude`, `--collector.netdev.device-exclude`, etc. |
| Métricas `node_processes_state` siempre en `1` | Sin `pid: host`, el contenedor sólo ve su propio PID. | Esperado por la decisión de no usar `pid: host`. Si se necesita, añadir `pid: host` al servicio y `up -d`. |
| Tras restart del host: el contenedor arranca antes que `hd2t` | Node Exporter monta `/` rslave, pero los puntos de montaje tardan en aparecer. | El bind mount `rslave` resuelve esto automáticamente (el contenedor verá los nuevos mounts en cuanto el host los haga). Si no aparece tras 30 s, revisar el unit de systemd que monta `hd2t` (Fase 1). |
| Caddy no tiene drop-in y el operador lo "echa de menos" | Decisión consciente: no se expone vía Caddy. | Para depurar a mano, usar siempre el flujo `docker exec prometheus wget -qO- http://node-exporter:9100/metrics`. |

---

## Decisiones que **no** se toman en este documento

- **`pid: host`**: permitiría que `node_processes_state` y `node_netstat_*` reportasen valores reales del host. Se descarta hoy: las series útiles para 99 % de los dashboards (CPU, RAM, disco, red por interfaz, temperatura) ya vienen del filesystem mapeado. Reabrible si el dashboard "Node Exporter Full" muestra paneles vacíos que importen.
- **Colector `systemd`**: requiere mount del DBus socket (`/var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket:ro`) y aporta valor sólo cuando el sistema corre servicios fuera de Docker. En este homelab todos los servicios viven en contenedores; el colector aportaría visibilidad sobre `ssh`, `cron`, `systemd-resolved` (poco accionable). Reabrible si en el futuro hay daemons en el host que merezcan supervisión.
- **TLS y autenticación en Node Exporter** (`--web.config.file` con basic auth + cert). El endpoint vive en una red Docker interna, sólo Prometheus lo consume y la red Docker no es enrutable desde fuera. Añadir TLS aquí es ceremonia. Reabrible si en algún momento aparece un Prometheus en otra máquina y el scrape pasa por la LAN/Tailscale.
- **Scripts del textfile collector** (SMART, Borg status, UPS). Cada uno merece su propia documentación dentro de la fase del servicio que produce la métrica (Borg en Fase 7, SMART probablemente como anexo a Fase 1, UPS si llega).
- **`smartctl_exporter` como contenedor aparte**: alternativa "pura" al textfile collector + `smartmon.sh` script. Más limpio en cardinalidad y menos código bash en el homelab. Reabrible al cerrar Fase 7 cuando se decida la estrategia de monitorización de discos.
- **Múltiples instances** (varios Pi, varios hosts). El homelab vive en una caja; el label `instance: 'pi5'` es semántico y deja preparado el día que llegue un segundo nodo (`instance: 'pi5b'`).
- **Métricas de NVMe específicas** (`node_nvme_*`). El Pi 5 puede llevar HAT NVMe; si en el futuro se añade, el colector `nvme` ya está habilitado por defecto en `v1.8.x` y empezará a reportar sin tocar nada.
- **Exposición vía Caddy con login**. Descartada conscientemente (ver "Decisión: exposición y endpoint").

---

## Verificación Final

Antes de pasar a `04-cadvisor.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/node-exporter/docker-compose.yml ps` | `node-exporter ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect node-exporter --format '{{.Config.Image}}'` | `prom/node-exporter:v1.8.2` |
| Conectado a `homelab` | `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` | incluye `node-exporter` y `prometheus` |
| Sin puertos publicados al host | `docker port node-exporter` | salida vacía |
| Bind mounts de host correctos | `docker inspect node-exporter --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Mode}}){{"\n"}}{{end}}'` | `/proc -> /host/proc (ro)`, `/sys -> /host/sys (ro)`, `/ -> /rootfs (ro,rslave)`, `/mnt/hd2t/apps/node-exporter/textfile -> /var/lib/node_exporter/textfile (ro)` |
| Endpoint `/metrics` responde (interno) | `docker exec prometheus wget -qO- http://node-exporter:9100/metrics \| head -1` | línea `# HELP node_arp_entries ...` o similar |
| Prometheus marca el target `up` | `curl -ks https://prometheus.lan/api/v1/targets \| jq '.data.activeTargets[] \| select(.labels.job=="node") \| .health'` | `"up"` |
| Temperatura del SoC presente | `docker exec prometheus wget -qO- 'http://prometheus:9090/api/v1/query?query=node_thermal_zone_temp' \| jq '.data.result \| length'` | `>= 1` |
| Filesystem de hd2t presente | `docker exec prometheus wget -qO- 'http://prometheus:9090/api/v1/query?query=node_filesystem_avail_bytes%7Bmountpoint%3D%22/rootfs/mnt/hd2t%22%7D' \| jq '.data.result \| length'` | `1` |
| Filesystem de hd5t presente | `docker exec prometheus wget -qO- 'http://prometheus:9090/api/v1/query?query=node_filesystem_avail_bytes%7Bmountpoint%3D%22/rootfs/mnt/hd5t%22%7D' \| jq '.data.result \| length'` | `1` |
| Sin interfaces virtuales en `node_network_*` | `docker exec prometheus wget -qO- http://node-exporter:9100/metrics \| grep '^node_network_up{' \| grep -E 'veth\|docker\|br-'` | sin resultados |
| Textfile collector activo y vacío | `docker exec prometheus wget -qO- http://node-exporter:9100/metrics \| grep '^node_textfile_scrape_error'` | `node_textfile_scrape_error 0` |
| Owner correcto del textfile dir | `stat -c '%u:%g %a' /mnt/hd2t/apps/node-exporter/textfile/` | `65534:65534 750` |
| Dashboard "Node Exporter Full" pinta datos | abrir `https://grafana.lan/d/...` con instance `pi5` | paneles de CPU, RAM, disco, temperatura con datos reales |
| Cardinalidad razonable | `docker exec prometheus wget -qO- 'http://prometheus:9090/api/v1/query?query=count(%7B__name__%3D~%22node_.%2B%22%7D)' \| jq '.data.result[0].value[1]'` | en torno a `400`–`700` series |

---

## Referencias

- [Repositorio oficial `prometheus/node_exporter`](https://github.com/prometheus/node_exporter) — fuente, lista de colectores y flags.
- [Documentación oficial de los colectores](https://github.com/prometheus/node_exporter#collectors) — estado (stable/experimental) y descripción.
- [Imagen Docker `prom/node-exporter`](https://hub.docker.com/r/prom/node-exporter) — tags multi-arch (incluye `arm64` para Pi 5).
- [Mirror Quay `quay.io/prometheus/node-exporter`](https://quay.io/repository/prometheus/node-exporter) — alternativa cuando Docker Hub aplica rate-limits.
- [Dashboard "Node Exporter Full" (`1860`)](https://grafana.com/grafana/dashboards/1860) — el dashboard de referencia para visualizar las métricas de este exporter.
- [Best practices: textfile collector](https://github.com/prometheus/node_exporter#textfile-collector) — pauta de escritura atómica (`mv` desde `.prom.$$`).
- [Mount propagation en Docker](https://docs.docker.com/engine/storage/bind-mounts/#configure-bind-propagation) — explicación de `rslave` y por qué se usa para `/:/rootfs:ro,rslave`.
- [Sibling: `01-prometheus.md`](./01-prometheus.md) — define el job `node` que este documento "rellena".
- [Sibling: `02-grafana.md`](./02-grafana.md) — provisiona el dashboard `1860` que consume estas métricas.
