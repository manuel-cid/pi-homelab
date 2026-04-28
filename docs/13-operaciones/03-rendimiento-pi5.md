# Rendimiento de la Pi 5

## Descripción

`01-mantenimiento-periodico.md` fija el calendario operativo y `02-disaster-recovery.md` documenta los procedimientos de fallo. Este documento se ocupa del **régimen de rendimiento** del homelab: cómo configurar el host para que ~30 contenedores (Fases 3–12: Pi-hole, Caddy, Authelia, Prometheus, Grafana, Borgmatic, Home Assistant, Stash, Jellyfin, qBittorrent, Sonarr/Radarr, Nextcloud, Vaultwarden, Paperless-ngx, Linkding, Homepage, etc.) convivan sobre **una sola Raspberry Pi 5 con 8 GB de RAM** sin que ninguno se ahogue, sin que la microSD sufra throttling térmico silencioso, y sin que un contenedor con fugas de memoria tire al resto.

La Pi 5 es una bestia respetable para un homelab doméstico: SoC BCM2712 con cuatro Cortex-A76 a 2.4 GHz por defecto, GPU VideoCore VII, PCIe Gen 2 x1, USB 3.0 dual, y un I/O bastante más sano que el de la Pi 4. Pero sigue siendo:

- **ARM64**: algunas imágenes Docker no están bien optimizadas o ni existen para `linux/arm64` (el homelab ya filtró estos casos en cada doc de servicio).
- **Sin escalado horizontal**: una sola caja, una sola CPU, un solo bus USB compartiendo `hd2t` y `hd5t` con cualquier otro periférico USB que se conecte.
- **Limitada en memoria**: 8 GB es generoso para un Raspberry Pi pero ridículo para 30 contenedores si se les deja crecer sin tope.
- **Térmicamente sensible**: el SoC empieza a hacer *soft throttle* a 80 °C y *hard throttle* a 85 °C. Un homelab sin disipación adecuada se degrada **silenciosamente** — no cae, simplemente baja de frecuencia hasta que la latencia se nota.
- **Alimentada por una fuente de 5 V/5 A** (PSU oficial 27 W). Periferia USB pesada (dos HDD spinning + lector de tarjetas + teclado) se acerca al límite y es la causa #1 de errores `UDMA_CRC` falsos en `hd2t`/`hd5t`.

Este documento **no despliega contenedores nuevos**. Lo que hace es:

1. Fijar la **política de overclock** del homelab (decisión: **no overclockear** por defecto, con la receta documentada por si el operador cambia de criterio).
2. Documentar la **gestión térmica**: cómo medir, qué umbrales aceptar, qué cooler físico se asume, qué hacer si la Pi entra en *throttling*.
3. Establecer la **priorización de servicios** en tiers y cómo ese tier se traduce en `cpus`, `cpu_shares`, `oom_score_adj`, `restart` policy y orden de arranque.
4. Definir los **límites de memoria por contenedor** (`mem_limit`, `mem_reservation`) con un presupuesto explícito de 8 GB que **debe cuadrar** con la suma de límites + buffer del kernel.
5. Tunear el **host** (microSD, USB, swap, sysctl) para minimizar el sufrimiento de la SD y los HDD externos.

> **Recordatorio de alcance**: el homelab sigue siendo solo **LAN + Tailscale**. Ningún tuning de este documento implica abrir puertos al exterior, instalar daemons propietarios ni habilitar telemetría a terceros. Las únicas conexiones salientes nuevas que pudieran derivarse de aquí son las ya autorizadas en fases anteriores (pull de imágenes, parches APT, sync Borg, NTP, Tailscale).

> **Filosofía**: optimizar **menos** y observar **más**. Un homelab que rinde "suficiente" con configuración por defecto es más sostenible que uno overclockeado al borde y tuneado en doce sysctls. Solo se tunea lo que una métrica de Prometheus o un episodio repetido de DR-1 ha justificado.

---

## Requisitos Previos

- **Fase 0** (`00-hardware/`):
  - Pi 5 8 GB con **PSU oficial 27 W (5 V/5 A)** — no PSU de Pi 4 (5 V/3 A) ni cargador USB-C genérico.
  - **Cooler activo oficial** (Active Cooler de Raspberry Pi) o equivalente: ventilador de 2 pines + disipador acoplado al SoC. La Pi 5 sin ventilador entra en throttling con 4 contenedores activos en verano.
  - **Cables USB-A 3.0 cortos y blindados** entre la Pi y los HDD `hd2t` / `hd5t` (cable corto < 50 cm; los cables baratos largos disparan `UDMA_CRC_Error_Count`).
  - HDD `hd2t` (2 TB) y `hd5t` (5 TB) montados con UUID en `/etc/fstab` con opciones `defaults,nofail,noatime,x-systemd.device-timeout=10s`.
- **Fase 1** (`01-sistema/`):
  - Raspberry Pi OS 64-bit (Bookworm o posterior).
  - `unattended-upgrades`, `logrotate`, `journalctl --vacuum-time=14d`.
  - `vcgencmd` y `rpi-eeprom` accesibles para el usuario `homelab`.
- **Fase 2** (`02-docker/`):
  - Docker Engine + Compose v2.
  - `daemon.json` con `log-driver=json-file`, `log-opts {max-size=10m, max-file=3}`.
  - cgroup v2 habilitado (default en Bookworm; se valida con `stat -fc %T /sys/fs/cgroup` → `cgroup2fs`).
- **Fase 5** (`05-monitorizacion/`):
  - **Prometheus** con retención ≥ 30 días.
  - **Node Exporter** publicando `node_thermal_zone_temp`, `node_cpu_seconds_total`, `node_memory_MemAvailable_bytes`, `node_load1`, `node_pressure_*` (PSI).
  - **cAdvisor** publicando `container_memory_working_set_bytes`, `container_cpu_usage_seconds_total`, `container_oom_events_total`.
  - **Grafana** con dashboards "Pi 5 health" y "cAdvisor" operativos.
- **Fase 13** (este documento es Fase 13.3):
  - `01-mantenimiento-periodico.md` desplegado: el operador ya revisa temperatura, throttling y top-10 RAM/CPU mensualmente.
- **Herramientas del host**:
  - `vcgencmd` (preinstalado).
  - `cpufrequtils` (`apt install cpufrequtils`) para inspección y ajuste manual de governor.
  - `htop`, `iotop`, `iostat`, `dstat` (`apt install htop iotop sysstat dstat`) para diagnóstico ad-hoc.
  - `stress-ng` (`apt install stress-ng`) **solo** para benchmarking puntual; **no** se deja corriendo.

---

## Filosofía: tunear lo justo

Antes de la receta, una tabla que separa **qué se toca** de **qué se deja en default**. Si un parámetro aparece en la columna derecha, se considera que el default de Raspberry Pi OS / Docker es razonable y no se modifica salvo evidencia contraria.

| Área | Se tunea | Se deja en default |
|---|---|---|
| CPU clock | Nada por defecto. Receta documentada para overclock conservador opcional. | `arm_freq=2400`, `over_voltage_delta=0`, `force_turbo=0` |
| Governor cpufreq | `ondemand` confirmado y monitorizado. | (es el default en RPi OS) |
| Temperatura | `temp_limit=80` (más conservador que el default 85) **opcional**, justificado abajo. | Curva del cooler activo (firmware) |
| Memoria por contenedor | **`mem_limit` y `mem_reservation` en cada compose** según tier. | `oom_kill_disable` (no se toca; se acepta OOM) |
| CPU por contenedor | **`cpus` y `cpu_shares` por tier** en composes críticos. | CPU pinning con `cpuset_cpus` (no se usa) |
| OOM score | `oom_score_adj` por tier en composes Tier 1 y Tier 3. | Default (0) en Tier 2 |
| Restart policy | **`unless-stopped`** universal salvo excepciones documentadas. | — |
| Swap | **`zram-tools` con 1 GB comprimido**, swappiness=10. | Swap en microSD (se desactiva). |
| sysctl | `vm.swappiness`, `vm.dirty_ratio`, `vm.dirty_background_ratio`, `net.core.somaxconn`. | Resto de `vm.*` y `net.*` |
| Logs Docker | Ya tuneado en Fase 2. | — |
| Storage driver | `overlay2`. | (es el default) |
| Pids limit | `pids-limit=4096` global en daemon.json. | Por contenedor |
| USB current | `usb_max_current_enable=1` en `config.txt`. | — |
| HDD mount | `noatime,commit=120,nofail`. | `data=ordered` (default ext4) |

> **Decisión "tunear menos"**: cada parámetro tuneado es deuda operativa. Una `vm.dirty_ratio` cambiada hace tres años "porque sí" es la pesadilla del que en cinco años intenta entender por qué la Pi se comporta raro. Solo se tunea lo que una métrica justifica y cada decisión queda **escrita y razonada** aquí.

---

## Overclocking conservador

### Decisión: NO overclockear por defecto

El Pi 5 a 2.4 GHz stock con cooler activo y los servicios del homelab (la mayoría I/O-bound: red, disco, BBDD ligeras) **no está limitado por CPU**. Los cuellos de botella reales son:

1. **Latencia I/O del HDD USB** (Stash, Jellyfin escaneando librería, Sonarr renombrando ficheros).
2. **Memoria** cuando todos los contenedores están al borde de su `mem_limit`.
3. **Bus USB compartido** entre `hd2t` y `hd5t` (un escaneo simultáneo en ambos discos los ralentiza a la mitad efectiva por dispositivo).

Subir el clock a 2.6 / 2.8 GHz aporta ganancias marginales (< 10 %) en los pocos workloads CPU-bound (transcode de Jellyfin, indexado inicial de Stash) y mete los siguientes costes:

- **Calor**: cada 200 MHz extra suben ~5 °C la temperatura sostenida. Con cooler activo se mantiene en margen, pero menos margen es menos margen.
- **Voltaje extra** (`over_voltage_delta`): degrada el SoC más rápido a largo plazo (envejecimiento por electromigración). El homelab está pensado para vivir años, no meses.
- **Consumo eléctrico**: + 1–2 W sostenidos. Pi 5 + 2 HDD + cooler ya está cerca de 12–15 W; el margen del PSU 27 W es cómodo pero no infinito.
- **Estabilidad**: cualquier overclock introduce una variable más en el bisect del próximo incidente.

> **Decisión**: el homelab corre **a 2.4 GHz stock**. Si el operador detecta un cuello de botella **medido** (Grafana mostrando `node_load1` > 4 sostenido durante 1 h, o un servicio con CPU al 100 % bloqueando la UI), abre un análisis ad-hoc, **no** sube el clock como reflejo.

### Receta de overclock conservador (opcional, si en el futuro se justifica)

Si tras un análisis serio se concluye que la Pi sí está CPU-bound y el overclock compensa, la receta del homelab — conservadora, probada por la comunidad — es la siguiente:

```ini
# /boot/firmware/config.txt — bloque [pi5]
[pi5]
# Overclock conservador: +200 MHz sin tocar voltaje base
arm_freq=2600
gpu_freq=950
over_voltage_delta=0

# Limitar throttling térmico antes que el default 85°C
temp_limit=80
```

Pasos:

```bash
# 1. Pre-condición: backup reciente verificado
grep "$(date -I)" /home/homelab/homelab/BACKUPS_LOG.md || echo "ATENCIÓN: forzar borgmatic antes."

# 2. Editar config.txt (con backup)
sudo cp /boot/firmware/config.txt /boot/firmware/config.txt.bak.$(date +%F)
sudo vi /boot/firmware/config.txt   # añadir el bloque [pi5] de arriba

# 3. Reboot
sudo reboot

# 4. Validar tras el reboot
vcgencmd measure_clock arm           # debe reportar ~2.6 GHz bajo carga
vcgencmd measure_volts core
vcgencmd measure_temp
vcgencmd get_throttled               # 0x0 esperado tras 30 min de uptime

# 5. Stress test 10 minutos (NO más sin supervisión)
stress-ng --cpu 4 --timeout 600s --metrics-brief
# Mientras corre:
watch -n 5 'vcgencmd measure_temp; vcgencmd measure_clock arm; vcgencmd get_throttled'

# 6. Si get_throttled != 0x0 o T > 80 °C sostenido: REVERTIR
# (restaurar config.txt.bak y reboot)
```

> **Por qué `over_voltage_delta=0`**: subir voltaje da margen para frecuencias mayores pero **acelera el envejecimiento del SoC**. El homelab prefiere quedarse 200 MHz por debajo del máximo posible que arriesgar la Pi a cinco años vista.

> **Decisión `temp_limit=80`**: el default es 85 °C (entonces empieza el hard throttle). Bajarlo a 80 fuerza al SoC a hacer soft throttle antes y mantener una temperatura sostenida más sana. La pérdida de pico es < 5 % en los rare casos CPU-bound; la ganancia en longevidad es no-medible pero real.

### Bits de `vcgencmd get_throttled`

Cuando se sospecha throttling, la salida de `get_throttled` es la fuente de verdad:

| Bit | Significado | Acción |
|---|---|---|
| `0x1` | Bajo voltaje activo | PSU insuficiente o cable USB-C malo. **Cambiar PSU** antes de ninguna otra cosa. |
| `0x2` | Frecuencia ARM throttled activamente | Sobrecalentamiento puntual. Revisar cooler. |
| `0x4` | Throttling activo (cualquiera) | Idem. |
| `0x8` | Soft temp limit activo (≥ 80 °C con `temp_limit=80`) | Idem. |
| `0x10000` | Bajo voltaje **ocurrió** desde el último boot | PSU dudosa o pico de carga. Vigilar. |
| `0x20000` | Frecuencia ARM **fue** throttled desde el último boot | Calor sostenido en algún momento. Revisar logs. |
| `0x40000` | Throttling **ocurrió** | Idem. |
| `0x80000` | Soft temp limit **ocurrido** | Idem. |

`0x0` significa "todo limpio desde el último boot". Cualquier otro valor merece anotación en `MAINTENANCE_LOG.md`.

---

## Gestión térmica

### Umbrales y régimen normal

Con cooler activo oficial sobre la Pi 5 8 GB y los ~30 contenedores del homelab corriendo:

| Estado | Temperatura SoC esperada | Acción |
|---|---|---|
| Idle (todo levantado, sin escaneos) | 45–55 °C | Normal |
| Carga baja (uso típico nocturno) | 50–60 °C | Normal |
| Carga media (Jellyfin streaming + Sonarr renombrando) | 60–70 °C | Normal |
| Carga alta (stash scan + jellyfin transcode + borgmatic) | 70–78 °C | Normal pero atención |
| Sostenido > 78 °C | — | Investigar: cooler, polvo, ambiente |
| Sostenido > 80 °C con `temp_limit=80` | — | Throttling activo. Acción inmediata. |
| Pico > 85 °C | — | Hard throttle. Carga incompatible con la disipación actual. |

### Comandos de medición

```bash
# Medición puntual
vcgencmd measure_temp                 # CPU/SoC
vcgencmd measure_clock arm            # frecuencia actual
vcgencmd get_throttled                # bitmap de throttling

# Continuo (debug ad-hoc)
watch -n 5 'echo "T=$(vcgencmd measure_temp) F=$(vcgencmd measure_clock arm) Throt=$(vcgencmd get_throttled)"'

# Vía Node Exporter (Prometheus)
curl -s localhost:9100/metrics | grep node_thermal_zone_temp

# Histórico Grafana
# Dashboard "Pi 5 health" → panel "Temperature 7d/30d"
```

### Alertas de Prometheus

`05-monitorizacion/01-prometheus.md` ya documenta el formato; este documento solo enumera las **reglas mínimas** que el operador debe tener activas:

```yaml
groups:
  - name: pi5-thermal
    rules:
      - alert: Pi5TempHigh
        expr: node_thermal_zone_temp{type="cpu-thermal"} > 75
        for: 30m
        labels: {severity: warning}
        annotations:
          summary: "Pi 5 temperatura sostenida > 75 °C"
          description: "Revisar cooler, polvo o carga anómala (cAdvisor top CPU)."
      - alert: Pi5TempCritical
        expr: node_thermal_zone_temp{type="cpu-thermal"} > 80
        for: 5m
        labels: {severity: critical}
        annotations:
          summary: "Pi 5 throttling inminente"
          description: "Throttle a 80 °C con temp_limit=80. Detener servicios T3 si persiste."
      - alert: Pi5UnderVoltage
        expr: increase(node_hwmon_in0_alarm[10m]) > 0
        for: 0m
        labels: {severity: critical}
        annotations:
          summary: "Bajo voltaje detectado en la Pi 5"
          description: "PSU insuficiente o cable USB-C dañado. Revisar PSU oficial 27 W."
```

> **Decisión "alertar a 75/80, no a 85"**: alertar al hard throttle (85 °C) es alertar **demasiado tarde**. El operador prefiere ver "atención T sostenida" 30 min antes que "throttle activo ahora".

### Mitigaciones por orden

Si la Pi entra en zona caliente, las mitigaciones se aplican **en orden** y se anota el resultado en `MAINTENANCE_LOG.md`:

1. **Identificar el contenedor culpable**: Grafana → cAdvisor → top CPU last 1 h. ¿Hay un contenedor en el 100 % sostenido? ¿Es esperado (escaneo programado) o anómalo (loop)?
2. **Aislar workload anómalo**: si el contenedor está en bucle CPU, `docker compose stop <svc>`, mirar logs, ir a su doc.
3. **Verificar cooler físico**: el ventilador del Active Cooler es PWM; con la Pi parada se inspecciona que gire libre. Polvo en las aletas baja la disipación un 20–30 %.
4. **Verificar ambiente**: Pi metida dentro de un mueble cerrado en pleno verano = +5–10 °C respecto a un sitio ventilado. El emplazamiento físico **importa**.
5. **Revisar cables USB**: cables USB largos o defectuosos disparan retransmisiones que se traducen en CPU softirq sostenida y calor adicional. Más raro, pero ocurre.
6. **Reducir tier 3**: si la Pi está pasando un calor de verano duradero y aún no toca cambiar hardware, parar temporalmente servicios T3 (Stash scan, Sonarr/Radarr search nocturna). Los T1 y T2 mantienen el homelab usable.
7. **Reabrir Fase 0**: si los pasos anteriores no bastan, el problema es de hardware (cooler insuficiente, PSU al borde, cableado). Vuelve a `00-hardware/` para replantear.

> **Lo que NO se hace**: bajar el `temp_limit` por debajo de 75 °C (la Pi pasaría todo el día throttled). Tampoco se desactiva el throttling (`force_turbo=1`) — eso sí degrada el SoC en pocos meses bajo carga térmica.

---

## Priorización de servicios

### Tiers

Los servicios del homelab se agrupan en tres tiers según criticidad operativa. **El tier de un servicio determina su `cpus`, `mem_limit`, `oom_score_adj` y orden de arranque**.

| Tier | Definición | Servicios | Si caen | Política |
|---|---|---|---|---|
| **T1 — Críticos** | Su caída rompe acceso a otros servicios o a internet del operador. | Pi-hole, Caddy, Authelia, Tailscale (host service) | Internet en LAN deja de resolver. UIs no son alcanzables. | `oom_score_adj=-500`. CPU sin tope (`cpus` no fijado). RAM con `mem_reservation` generoso. **Arrancan primero.** |
| **T2 — Soporte** | Sostienen la observabilidad y la integridad del homelab pero su caída no bloquea al usuario. | Prometheus, Grafana, Node Exporter, cAdvisor, Uptime Kuma, Dozzle, Borgmatic, Watchtower, Portainer, Homepage | Pierdes visibilidad y la siguiente ventana de backup. | `oom_score_adj=0` (default). CPU sin tope. RAM con `mem_limit` justo. |
| **T3 — Funcionales** | Aplicaciones de uso. Su caída es molesta pero no urgente. | Home Assistant, Stash, Jellyfin, qBittorrent, Sonarr, Radarr, Prowlarr, Bazarr, Nextcloud, Vaultwarden, Paperless-ngx, Linkding, Mosquitto, Zigbee2MQTT | El operador no puede ver una serie / añadir una contraseña / scrapear un torrent. | `oom_score_adj=+500` para los **opcionales** (Stash, Jellyfin, qBittorrent, Sonarr/Radarr/Prowlarr/Bazarr); `0` para los que el operador considera críticos personalmente (Vaultwarden, Home Assistant, Nextcloud). CPU con `cpus=2.0`. RAM con `mem_limit` ajustado. |

> **Excepción Vaultwarden / Home Assistant / Nextcloud**: viven en T3 por arquitectura (no son infraestructura del homelab) pero el operador los considera "no perdibles ante OOM" porque guardan estado humano (contraseñas, automatizaciones, ficheros propios). Por eso su `oom_score_adj=0` y no `+500`. Es una decisión personal **anotada explícitamente** aquí; si otro operador hereda el homelab puede revisarla.

### Traducción a Compose

Cada servicio incorpora en su `docker-compose.yml` un bloque coherente con su tier:

**Tier 1 — Pi-hole / Caddy / Authelia**:

```yaml
services:
  pihole:
    image: pihole/pihole:latest
    restart: unless-stopped
    mem_limit: 512m
    mem_reservation: 256m
    oom_score_adj: -500
    # cpus: NO fijado — T1 puede usar todo lo que necesite
    # ulimits opcional para socket limits altos
```

**Tier 2 — Prometheus / Grafana / cAdvisor**:

```yaml
services:
  prometheus:
    image: prom/prometheus:latest
    restart: unless-stopped
    mem_limit: 768m
    mem_reservation: 384m
    # oom_score_adj default (0)
    # cpus: NO fijado — bursts puntuales en queries pesadas
```

**Tier 3 — Stash / Jellyfin / qBittorrent**:

```yaml
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    restart: unless-stopped
    mem_limit: 1g
    mem_reservation: 512m
    cpus: "2.0"
    oom_score_adj: 500   # primero a morir si la Pi se queda sin RAM
```

> **`cpus` vs `cpu_shares`**: `cpus` (Compose v3) limita el equivalente a un share fraccional sobre los 4 cores; `cpu_shares` es un peso relativo (1024 default). El homelab usa `cpus` por legibilidad. Solo cuando varios contenedores compiten por CPU se nota la diferencia; en operación normal todos tienen margen.

### Orden de arranque

El orden importa cuando la Pi reinicia (DR-2, mantenimiento M3 con reboot, corte eléctrico). Docker arranca contenedores con `restart: unless-stopped` en orden indeterminado salvo que se use `depends_on` o se levante por capas manualmente.

| Capa | Stacks | Comando |
|---|---|---|
| 1. Red | `pihole`, `caddy`, `authelia` | `docker compose -f stacks/network/docker-compose.yml up -d` |
| 2. Observabilidad | `prometheus`, `grafana`, `node_exporter`, `cadvisor`, `uptime-kuma`, `dozzle` | `docker compose -f stacks/monitoring/docker-compose.yml up -d` |
| 3. Backups | `borgmatic`, `watchtower` | `docker compose -f stacks/backups/docker-compose.yml up -d` |
| 4. Almacenamiento / DBs | `postgres` interno (si lo hay), `mariadb` (si lo hay) | … |
| 5. Aplicaciones T3 | resto | `docker compose up -d` por stack |

En condiciones normales con `restart: unless-stopped`, Docker arranca todos los contenedores tras un reboot y el sistema converge en 60–90 s. El orden por capas se usa **solo** en disaster recovery o cuando un mantenimiento requiere bajar todo y volver a subir.

```bash
# Bajar todo en orden inverso (mantenimiento programado)
for stack in apps backups monitoring network; do
  docker compose -f stacks/$stack/docker-compose.yml down
done

# Subir en orden directo
for stack in network monitoring backups apps; do
  docker compose -f stacks/$stack/docker-compose.yml up -d
  sleep 15  # margen para que la capa anterior esté lista
done
```

> **Decisión `unless-stopped`**: universal. Lo único excluido son contenedores oneshot (init de DB) que llevan `restart: "no"` explícito. `always` es demasiado agresivo (sigue reiniciando incluso tras `docker stop` manual); `on-failure` deja servicios caídos tras reboot.

---

## Límites de memoria por contenedor

### Presupuesto de los 8 GB

La Pi 5 8 GB no son 8 GB para contenedores. Hay que descontar:

| Consumidor | Reserva | Notas |
|---|---|---|
| Kernel + initramfs + buffers | ~400 MB | Estable. |
| Page cache "objetivo" (HDD I/O) | ~1 GB | El kernel decide; el operador deja margen para que page cache haga su trabajo o los HDD sufren. |
| Procesos del host (sshd, smartd, journald, systemd, cron, tailscaled, node_exporter, …) | ~300 MB | Medido con `free -h` sin contenedores. |
| Docker Engine (daemon, containerd, healthchecks, networking) | ~200 MB | Medido con contenedores ya arrancados. |
| zram (1 GB comprimido en RAM) | ~256 MB efectivos | Compresión típica 4:1; ver § Swap. |
| **Subtotal sistema** | **~2.1 GB** | |
| **Disponible para contenedores** | **~5.9 GB** | |

El homelab debe **caber** en ese presupuesto con holgura. La tabla siguiente fija un `mem_limit` por servicio basado en uso típico observado en deploys equivalentes (cifras conservadoras; el operador refina con métricas reales tras los primeros meses):

| Servicio | Tier | `mem_limit` | `mem_reservation` | Notas |
|---|---|---|---|---|
| Pi-hole | T1 | 512m | 256m | DNS + UI ligera |
| Caddy | T1 | 256m | 128m | Reverse proxy estable |
| Authelia | T1 | 256m | 128m | OIDC + sqlite |
| Prometheus | T2 | 768m | 384m | Retención 30 días, ~30 targets |
| Grafana | T2 | 384m | 192m | Renderizado cliente; servidor ligero |
| Node Exporter | T2 | 64m | 32m | Trivial |
| cAdvisor | T2 | 256m | 128m | Pesado proporcional al nº contenedores |
| Uptime Kuma | T2 | 256m | 128m | sqlite + Node |
| Dozzle | T2 | 128m | 64m | Stream WS, sin estado |
| Watchtower | T2 | 128m | 64m | Pull periódico |
| Portainer | T2 | 256m | 128m | UI Docker |
| Borgmatic | T2 | 512m | 256m | Picos durante backup |
| Homepage | T2 | 128m | 64m | Estático |
| Mosquitto | T3 | 64m | 32m | MQTT broker mínimo |
| Zigbee2MQTT | T3 | 256m | 128m | Adaptador Zigbee |
| Home Assistant | T3 | 1g | 512m | Núcleo doméstico |
| Stash | T3 | 1g | 512m | Indexa biblioteca; pico al scan |
| Jellyfin | T3 | 1g | 512m | Sin transcode HW (Pi no tiene); contenido directo H.264/HEVC ya optimizado |
| qBittorrent | T3 | 512m | 256m | + libtorrent |
| Sonarr | T3 | 384m | 192m | .NET runtime ligero arm64 |
| Radarr | T3 | 384m | 192m | Idem |
| Prowlarr | T3 | 256m | 128m | Indexer |
| Bazarr | T3 | 256m | 128m | Subs |
| Nextcloud | T3 | 768m | 384m | + Postgres aparte si aplica |
| Vaultwarden | T3 | 192m | 96m | Rust eficiente |
| Paperless-ngx | T3 | 768m | 384m | OCR consume; pico al ingestar |
| Linkding | T3 | 192m | 96m | Django + sqlite |

**Suma de `mem_limit` ~ 9.6 GB**. Esto **excede** los 5.9 GB disponibles, y es **deliberado**: no todos los contenedores están al límite a la vez. El homelab apuesta por *overcommit moderado* y deja al kernel arbitrar con OOM cuando la pelea se da. Por eso los `oom_score_adj` están fijados: el T3 muere primero y el T1 sobrevive.

> **Decisión "overcommit"**: alternativa rígida sería ajustar `mem_limit` para que sumen ≤ 5.9 GB. Eso obligaría a bajar muchos servicios a límites artificialmente bajos donde harían `OOMKilled` constante. La estrategia "límites realistas + tier de OOM" funciona mejor en la práctica para un homelab doméstico. **El operador monitoriza `container_oom_events_total` y reacciona si un T1 o T2 muere por OOM**.

### Suma de `mem_reservation`

A diferencia del `mem_limit`, las **`mem_reservation`** son una promesa al kernel ("no expulses esto del page cache si puedes evitarlo"). La suma de reservations debe caber **cómodamente** en RAM:

| Tier | Suma `mem_reservation` |
|---|---|
| T1 (Pi-hole + Caddy + Authelia) | 512 MB |
| T2 (observabilidad + backups + dashboards) | 1.4 GB |
| T3 (resto) | 3.0 GB |
| **Total** | **~5.0 GB** |

Caben holgados en los 5.9 GB de presupuesto. Si en el futuro se añaden servicios que empujan la reservation total por encima de ~5.5 GB, se replantea: o se eliminan servicios marginales (Q9 trimestral) o se considera ampliar a Pi 5 16 GB cuando esté disponible.

### Detección de fugas de memoria

`container_memory_working_set_bytes` (cAdvisor) es la métrica clave. Una **curva monotónica creciente sin caídas** durante 7+ días es síntoma de fuga.

Patrón típico en Grafana:

- **Sano**: la línea sube y baja con la actividad, con suelo estable durante días.
- **Fuga**: la línea sube y nunca baja del nivel anterior. En T+10 días el contenedor está al borde de su `mem_limit`. En T+15 días `OOMKilled`.

Acciones:

1. **Confirmar OOM**: `docker inspect <container> --format '{{.State.OOMKilled}}'`. Si `true`, el kernel mató al contenedor por exceder `mem_limit`.
2. **Subir el límite temporalmente** (× 1.5) y reabrir incidente: ¿es la app, una versión nueva, una integración mal configurada?
3. **Revisar issues upstream** del proyecto. Las fugas de memoria recurrentes en software estable son raras; las recurrentes en software joven (Stash, Paperless-ngx, ciertos addons de Home Assistant) no son tan raras.
4. **Si no se identifica causa**: programar **reinicio periódico** del contenedor con un timer systemd o un cron simple. Es feo pero estable.

```bash
# Ejemplo: reiniciar stash cada 7 días a las 04:30
# /etc/systemd/system/stash-restart.service
[Unit]
Description=Restart stash to mitigate memory leak
[Service]
Type=oneshot
ExecStart=/usr/bin/docker restart stash

# /etc/systemd/system/stash-restart.timer
[Unit]
Description=Weekly stash restart
[Timer]
OnCalendar=weekly
Persistent=true
[Install]
WantedBy=timers.target
```

> **Decisión "no autorestart por defecto"**: solo se programa un reinicio periódico cuando una fuga **medida** lo justifica. No se aplica preventivamente "por si acaso" porque oculta problemas reales.

---

## Tuning del host

### microSD y desgaste

La microSD es el **componente más frágil** del homelab. Las medidas de Fase 1 + Fase 2 ya minimizan su sufrimiento (logs Docker en `json-file` con rotación, journalctl con `--vacuum-time=14d`). Este documento añade dos medidas más:

**1. Mover Docker root a `hd2t`** (decisión ya tomada en `02-docker/01-instalacion.md`, recordatorio aquí):

```jsonc
// /etc/docker/daemon.json
{
  "data-root": "/mnt/hd2t/docker",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "default-ulimits": {
    "nofile": { "Soft": 65536, "Hard": 65536 }
  },
  "pids-limit": 4096
}
```

Mover `/var/lib/docker` a `hd2t` saca **toda la escritura de imágenes, capas y volúmenes** de la microSD. Lo único que sigue escribiendo en SD son: logs del sistema (rotados), APT (esporádico) y journald (acotado).

**2. tmpfs para directorios volátiles**:

```ini
# /etc/fstab — añadir
tmpfs   /tmp           tmpfs   defaults,noatime,nosuid,size=512m  0  0
tmpfs   /var/log/tmp   tmpfs   defaults,noatime,nosuid,size=128m  0  0
```

> **Decisión "no /var/log entero en tmpfs"**: eso pierde logs ante reboot, lo cual rompe el debugging post-incidente. Solo `/tmp` y un subdirectorio efímero.

### USB y HDD

```ini
# /boot/firmware/config.txt — bloque [pi5]
[pi5]
# Habilitar 5 A en USB (PSU oficial 27 W lo soporta).
# Sin esto, la Pi 5 limita el USB a 600 mA total y dos HDD simultáneos
# pueden saturar — un HDD se desconecta esporádicamente y reaparece.
usb_max_current_enable=1
```

```ini
# /etc/fstab — montaje hd2t / hd5t (ejemplo; UUIDs reales vienen de Fase 0)
UUID=xxxx-hd2t  /mnt/hd2t  ext4  defaults,nofail,noatime,commit=120,x-systemd.device-timeout=10s  0  2
UUID=yyyy-hd5t  /mnt/hd5t  ext4  defaults,nofail,noatime,commit=120,x-systemd.device-timeout=10s  0  2
```

Razones:
- **`noatime`**: cada lectura no actualiza el timestamp de acceso del inodo. Reduce I/O de escritura a HDD un 5–15 %, especialmente en directorios con muchos ficheros pequeños (Stash thumbnails, Paperless OCR cache).
- **`commit=120`**: ext4 hace commit del journal cada 120 s (default 5 s). Tolera mejor un HDD lento o un bus saturado, a cambio de hasta 120 s de datos en buffer si la Pi pierde corriente. El homelab acepta esta ventana porque las BBDD relevantes (Postgres, MariaDB, sqlite) tienen su propio fsync interno.
- **`nofail`** + **`x-systemd.device-timeout=10s`**: si un HDD no monta al boot (cable suelto, disco muerto), la Pi arranca igualmente y el operador puede entrar por SSH a diagnosticar. Sin esto, una Pi sin HDD se queda en emergency mode bloqueada.

> **Decisión `commit=120`**: con UPS la ventana sería irrelevante (no hay corte de corriente). Sin UPS, una pérdida puntual de hasta 120 s de I/O es asumible para el homelab; los datos críticos (BBDD relacionales) cierran sus propias transacciones aparte y se respaldan con dump.

### Swap con zram

La microSD no debe usarse como swap (escrituras random destruyen la SD en meses bajo presión). El homelab usa **zram-tools**: swap **comprimido en RAM** que cuesta CPU pero no I/O.

```bash
sudo apt install zram-tools
sudo systemctl enable --now zramswap
```

```ini
# /etc/default/zramswap
ALGO=zstd
PERCENT=12             # 12% de 8GB = ~960MB de swap comprimido (~250MB efectivos en RAM)
PRIORITY=100
```

```ini
# /etc/sysctl.d/99-homelab.conf
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
net.core.somaxconn = 1024
```

Razones:
- **`vm.swappiness=10`** (default 60): el kernel evita meter en swap salvo que la presión de memoria sea seria. Con zram el swap es barato pero no gratis; preferimos cache que swap.
- **`vm.vfs_cache_pressure=50`** (default 100): el kernel retiene más metadata cache. Ayuda con `find`, `ls -laR`, escaneos de Stash y Jellyfin.
- **`vm.dirty_ratio=10`** y **`dirty_background_ratio=5`** (defaults 20/10): bajar los umbrales obliga al kernel a flushear más a menudo a HDD. Mejor patrón para HDD spinning USB que ráfagas grandes ocasionales.
- **`net.core.somaxconn=1024`** (default 4096 en kernels recientes; lo fijamos por si el default cambia): backlog de conexiones aceptadas. Suficiente para LAN + Tailscale.

```bash
# Aplicar
sudo sysctl --system

# Verificar
swapon --show              # debe listar /dev/zram0 con prio 100
sysctl vm.swappiness       # 10
free -h                    # swap ~960M
```

> **Decisión "swap pequeño y comprimido"**: alternativa sería swap en `hd2t` (no en SD). Pero swap en HDD spinning USB añade latencia inaceptable bajo presión real. Zram es el compromiso correcto: aprieta CPU 1–2 % cuando se usa, no toca el disco, y libera al kernel de matar contenedores por OOM ante picos transitorios.

### Governor cpufreq

El default `ondemand` en RPi OS escala la frecuencia con la carga. Otros governors:

| Governor | Comportamiento | Uso en homelab |
|---|---|---|
| `ondemand` | Sube/baja según carga, con histéresis. | **Default. Se mantiene.** |
| `performance` | Siempre al máximo. | Solo durante benchmarking. Mete +3–5 °C continuos. |
| `powersave` | Siempre al mínimo. | No: la Pi se siente lenta y picos quedan throttled. |
| `conservative` | Como ondemand pero más vago al subir. | Probado por el operador, no aporta vs ondemand. |

```bash
# Verificar governor actual
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor   # ondemand esperado

# Cambiar (no se hace por defecto)
sudo cpufreq-set -g ondemand
```

> **Decisión**: `ondemand` queda explícito en `MAINTENANCE_LOG.md` como elección del homelab. Si en algún momento aparece en otro valor, es síntoma de que algo lo cambió y merece auditoría.

---

## Verificación de rendimiento

Tras aplicar los cambios de este documento, una **batería de comprobaciones** confirma que el homelab quedó en régimen sano.

### Idle (después de un reboot, todos los servicios up, sin actividad de usuario)

```bash
# Esperar 5 min tras el `up -d` final para que las métricas se estabilicen
sleep 300

vcgencmd measure_temp                # esperado < 60 °C
vcgencmd get_throttled               # 0x0
free -h                              # used < 4G, available > 4G
uptime                               # load1 < 1.0
```

### Bajo carga moderada (uso típico nocturno)

```bash
# Una sola sesión de Jellyfin streaming + Sonarr search programada
vcgencmd measure_temp                # < 70 °C
uptime                               # load1 < 2.0
docker stats --no-stream | head -20  # ningún contenedor > 80% de su mem_limit
```

### Bajo carga alta (sintetizado con stress-ng, 5 minutos máximo)

```bash
# stress-ng en 4 cores + I/O sobre /tmp
stress-ng --cpu 4 --io 2 --vm 2 --vm-bytes 1G --timeout 300s --metrics-brief

# Mientras corre:
watch -n 5 'echo "T=$(vcgencmd measure_temp) Throt=$(vcgencmd get_throttled) Load=$(uptime)"'
# Esperado: T < 80 °C, Throt=0x0, load1 ~ 4 (un core saturado por stress)
```

### Persistencia 7 días (no hay batería: solo monitorizar y revisar el lunes)

| Métrica Grafana | Verde si |
|---|---|
| `node_thermal_zone_temp` (CPU) | p95 7d < 75 °C |
| `node_load1` | p95 7d < 3.0 |
| `node_memory_MemAvailable_bytes` | mín 7d > 1.5 GB |
| `container_oom_events_total` | sum 7d == 0 (ningún OOMKilled) |
| `node_pressure_io_stalled_seconds_total` derivada | < 5 s/día acumulados |
| `vcgencmd get_throttled` (script exporter ad-hoc) | siempre 0x0 |

Si tras una semana cualquiera de las cinco filas aparece en rojo, se abre análisis. La métrica de OOM y la de PSI I/O son las más informativas a medio plazo.

---

## Almacenamiento

Este documento operativo no despliega artefactos persistentes nuevos. Los ficheros que **sí** crea son:

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/boot/firmware/config.txt` (bloque `[pi5]`) | microSD | `root:root` | `0755` | Reservaciones de overclock conservador (opcional) y `usb_max_current_enable=1`. **Versionado fuera de banda**: `cp /boot/firmware/config.txt /home/homelab/homelab/host/config.txt.snapshot` y commit. |
| `/etc/sysctl.d/99-homelab.conf` | microSD | `root:root` | `0644` | `vm.swappiness`, `vm.dirty_*`, `vm.vfs_cache_pressure`, `net.core.somaxconn`. |
| `/etc/default/zramswap` | microSD | `root:root` | `0644` | Configuración de zram-tools. |
| `/etc/fstab` (líneas `tmpfs`) | microSD | `root:root` | `0644` | Montaje de `/tmp` y `/var/log/tmp` en tmpfs. |
| `/home/homelab/homelab/host/config.txt.snapshot` | microSD | `homelab:homelab` | `0644` | Copia del `config.txt` para auditoría git. |
| `/home/homelab/homelab/host/sysctl.conf.snapshot` | microSD | `homelab:homelab` | `0644` | Idem para sysctl. |
| `mem_limit` / `mem_reservation` / `cpus` / `oom_score_adj` por compose | microSD (`/home/homelab/homelab/stacks/*/docker-compose.yml`) | `homelab:homelab` | `0644` | Bloques añadidos a cada `docker-compose.yml` según tier. |

No se crean directorios nuevos en `/mnt/hd2t/` ni en `/mnt/hd5t/`. Los snapshots de configuración del host se versionan en git para auditoría posterior.

---

## Backup

| Artefacto | Estrategia |
|---|---|
| `docs/13-operaciones/03-rendimiento-pi5.md` | Versionado en git. |
| `host/config.txt.snapshot`, `host/sysctl.conf.snapshot` | Versionados en git. **Sin secretos.** El `config.txt` real no contiene credenciales. |
| `/etc/sysctl.d/99-homelab.conf` y `/etc/default/zramswap` | Cubiertos por el include de `/etc/` en Borgmatic (Fase 7 los añade al backup del host). |
| Ajustes `mem_limit` / `cpus` / `oom_score_adj` en composes | Se respaldan con el resto del repo `/home/homelab/homelab/`. |
| Métricas históricas de rendimiento (Prometheus) | Se respaldan según política de Prometheus en Fase 7. La retención de 30 días en Prometheus es la fuente principal; backup mensual del WAL si se quiere mayor histórico. |

> **Decisión**: los snapshots del host no son la fuente de verdad — la fuente de verdad es el fichero real en la microSD. Los snapshots existen para que un `git diff` revele cambios no documentados al host (auditoría de drift).

---

## Verificación Final

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Cooler activo girando | inspección visual + `vcgencmd measure_temp` antes y después de `stress-ng --cpu 4 --timeout 60s` | Diferencia > 5 °C entre ambos puntos |
| `vcgencmd get_throttled` tras 24 h de uptime | comando en SSH | `throttled=0x0` |
| Temperatura idle estabilizada | `vcgencmd measure_temp` con todos los servicios up, sin actividad de usuario | < 60 °C |
| `usb_max_current_enable=1` aplicado | `vcgencmd get_config usb_max_current_enable` | `usb_max_current_enable=1` |
| zram activo | `swapon --show` | Línea con `/dev/zram0`, prio 100 |
| sysctl aplicados | `sysctl vm.swappiness vm.dirty_ratio vm.vfs_cache_pressure net.core.somaxconn` | 10 / 10 / 50 / ≥1024 |
| HDD montados con `noatime` | `mount \| grep -E 'hd2t\|hd5t'` | Incluye `noatime` y `commit=120` |
| Docker root en `hd2t` | `docker info \| grep "Docker Root Dir"` | `/mnt/hd2t/docker` |
| Cada servicio T1 tiene `oom_score_adj=-500` | `docker inspect <pihole> --format '{{.HostConfig.OomScoreAdj}}'` | `-500` |
| Cada servicio T3 opcional tiene `oom_score_adj=500` | idem para `stash`, `jellyfin`, `qbittorrent` | `500` |
| Suma de `mem_reservation` cabe en RAM | script ad-hoc que itera `docker inspect --format '{{.HostConfig.MemoryReservation}}'` por contenedor | `< 5.5 GB` total |
| Ningún OOM en últimos 7 días | Grafana panel `container_oom_events_total` 7d | `0` |
| Governor `ondemand` activo | `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` | `ondemand` |
| Snapshots versionados | `git status host/` | `host/config.txt.snapshot` y `host/sysctl.conf.snapshot` commiteados |

Cumplido todo lo anterior, el homelab tiene un **régimen de rendimiento documentado y aplicado**. El siguiente documento (`04-red-y-puertos.md`) cierra Fase 13 con el mapa de red.

---

## Decisiones que **no** se toman en este documento

- **Migración a NVMe** (HAT NVMe sobre Pi 5): no es tuning de rendimiento sino un cambio de arquitectura. Vive en `00-hardware/` cuando se decida.
- **Migración a Pi 5 16 GB** (cuando esté disponible): idem.
- **Cambio de governor** a `performance`: explícitamente desaconsejado aquí; cualquier cambio futuro lleva análisis en `MAINTENANCE_LOG.md`.
- **Reglas de alertas Prometheus** completas: las dos reglas térmicas listadas son el mínimo; el catálogo completo vive en `05-monitorizacion/01-prometheus.md`.
- **Tuning de Postgres / MariaDB / Redis** internos: cada servicio que hospeda una BBDD relacional tiene su propio doc con `shared_buffers`, `work_mem`, etc. Aquí solo se fija el `mem_limit` envolvente.
- **Tuning de Caddy** (workers, buffers): vive en `03-red/02-caddy.md`. Aquí solo se le da `mem_limit=256m` como T1.
- **Procedimiento de reemplazo del cooler activo**: si el ventilador se rompe, es DR-tipo "fallo parcial de hardware" que se trata como una mini-actuación de Fase 0, no aquí.
- **Hardware UPS** (alimentación ininterrumpida): no contemplado en el alcance del homelab actual; sin UPS, `commit=120` en ext4 es la mitigación.
- **Power capping** (limitar consumo eléctrico al PSU): la Pi 5 no expone `cpu_power_cap` como un x86; el homelab confía en el PSU oficial 27 W y el `usb_max_current_enable=1`.
- **Benchmarking comparativo** Pi 4 vs Pi 5 vs Pi 5 + NVMe: no es objetivo del documento. Hay benchmarks públicos suficientes y cada operador puede correr los suyos con `stress-ng` y `fio` ad-hoc.

---

## Referencias

- [Documento previo: `docs/13-operaciones/02-disaster-recovery.md`](./02-disaster-recovery.md)
- [Documento siguiente: `docs/13-operaciones/04-red-y-puertos.md`](./04-red-y-puertos.md)
- [Documento relacionado: `docs/13-operaciones/01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md)
- [Documento relacionado: `docs/00-hardware/`](../00-hardware/)
- [Documento relacionado: `docs/01-sistema/`](../01-sistema/)
- [Documento relacionado: `docs/02-docker/01-instalacion.md`](../02-docker/01-instalacion.md)
- [Documento relacionado: `docs/05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md)
- [Documento relacionado: `docs/05-monitorizacion/03-cadvisor.md`](../05-monitorizacion/03-cadvisor.md)
- [Documento relacionado: `docs/07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
- [Raspberry Pi — `config.txt` (`arm_freq`, `over_voltage_delta`, `temp_limit`, `usb_max_current_enable`)](https://www.raspberrypi.com/documentation/computers/config_txt.html)
- [Raspberry Pi — `vcgencmd` y `get_throttled`](https://www.raspberrypi.com/documentation/computers/os.html#vcgencmd)
- [Raspberry Pi — Active Cooler](https://www.raspberrypi.com/products/active-cooler/)
- [Raspberry Pi — PSU oficial 27 W](https://www.raspberrypi.com/products/27w-power-supply/)
- [Linux kernel — Pressure Stall Information (PSI)](https://www.kernel.org/doc/html/latest/accounting/psi.html)
- [Linux kernel — `vm.swappiness`, `vm.dirty_ratio`, `vm.vfs_cache_pressure`](https://www.kernel.org/doc/html/latest/admin-guide/sysctl/vm.html)
- [Docker — `mem_limit`, `mem_reservation`, `cpus`, `oom_score_adj`](https://docs.docker.com/reference/compose-file/deploy/#resources)
- [Docker — `daemon.json` (data-root, default-ulimits, pids-limit)](https://docs.docker.com/reference/cli/dockerd/)
- [zram-tools — Debian package](https://packages.debian.org/bookworm/zram-tools)
- [stress-ng — manpage](https://manpages.debian.org/bookworm/stress-ng/stress-ng.1.en.html)
- [cpufrequtils — governors](https://wiki.archlinux.org/title/CPU_frequency_scaling)
