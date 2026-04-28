# Rendimiento y Tuning de la Raspberry Pi 5

## Descripción

Documento operativo de la **Fase 13** del homelab. Define las **palancas de tuning** disponibles sobre la Raspberry Pi 5 (8 GB) que sostiene este homelab, **en qué orden** aplicarlas, con qué **valores defendibles** y, sobre todo, **cuándo no aplicar nada**: en una Pi 5 con *Active Cooler* oficial, fuente 27 W, swap en `hd2t` y los `mem_limit` ya documentados servicio a servicio (Fases 5–12), la línea base **no necesita overclocking** ni heroicidades para correr el catálogo descrito en `SERVICES.md`.

El doc cubre, en este orden:

1. **Filosofía**: principios del tuning en este homelab (estabilidad sobre rendimiento, observabilidad antes de tuning, presupuestos explícitos por contenedor, "no tocar lo que va bien").
2. **Línea base esperada**: qué temperatura, RAM, swap, I/O y latencias presenta una Pi 5 8 GB con todos los servicios desplegados pero **inactiva** (idle de fin de semana) y **bajo carga** (Jellyfin transcodificando + Stash generando previews + Borgmatic corriendo). Es el "control" que justifica decir "está bien" o "está mal" más adelante.
3. **Gestión térmica**: cómo lee la Pi su propia temperatura, qué hace el firmware con el *Active Cooler* (curva PWM por defecto), umbrales de *thermal throttling*, qué cambiar si se observa throttle persistente.
4. **Overclocking conservador**: si tras todo lo demás la CPU sigue siendo el cuello de botella, qué `over_voltage_delta`/`arm_freq`/`gpu_freq` admite la Pi 5 con el cooler oficial, cómo aplicarlos en `/boot/firmware/config.txt`, cómo revertir si algo va mal y por qué este homelab **no overclocka por defecto**.
5. **Priorización de servicios**: cómo se da prioridad a Pi-hole/Caddy/Authelia (servicios de **plataforma**) frente a Jellyfin/Stash/Borgmatic (cargas pesadas de **datos**) usando `cpus`, `cpu_shares`/`cpu_weight`, `mem_reservation`, `oom_score_adj` y la prioridad `IOSchedulingClass`/`Nice` de las units `systemd` que arrancan los stacks.
6. **Presupuesto consolidado de memoria**: tabla canónica de `mem_limit`/`mem_reservation` por contenedor, suma total y "huelga" disponible. Es la fuente de verdad cuando se añade un servicio nuevo y hay que decidir cuánto darle.
7. **I/O y discos**: scheduler `mq-deadline` vs `bfq`, montaje de `hd2t`/`hd5t`, comportamiento de la swap en HDD, "I/O hot zones" y cómo evitar contención entre Borgmatic y Jellyfin.
8. **Kernel y `sysctl`**: ajustes de `vm.swappiness`, `vm.vfs_cache_pressure`, `vm.dirty_*`, `net.core.*` aplicables al perfil de un homelab. Se recoge solo lo que **se ha decidido aplicar**, no la enciclopedia.
9. **Verificación**: comandos `vcgencmd`, `iostat`, `vmstat`, `glances`, paneles concretos en Grafana. Cómo medir antes y después de cualquier cambio para no actuar a ciegas.
10. **Lista de Verificación** y **Solución de Problemas** con los síntomas habituales (`exit 137`, throttle, latencia, contención de I/O en backups).

> **Alcance de este doc**: este documento **no instala servicios**. Todos los `mem_limit`, `cpus`, `restart`, etc. del homelab viven en sus respectivos `docker-compose.yml`, ya documentados en sus fases. Aquí se centraliza la **estrategia** y el **cuándo cambiar qué**, con punteros a esos otros docs.

> **Alcance de red**: las acciones de este doc se ejecutan **en local** sobre la Pi (SSH desde LAN o Tailscale). No abren puertos al exterior ni cambian la configuración de red descrita en la Fase 3.

---

## Requisitos Previos

- **Fases 0–5 desplegadas**, en particular:
  - *Active Cooler* oficial montado y funcionando ([`../00-hardware/01-material-necesario.md`](../00-hardware/01-material-necesario.md), [`../00-hardware/02-esquema-conexiones.md`](../00-hardware/02-esquema-conexiones.md)).
  - Fuente oficial 27 W (USB-C PD) — fuentes genéricas pueden inducir throttle silencioso por bajo voltaje incluso si "técnicamente" entregan 5 V.
  - Swap creada en `hd2t` con `vm.swappiness=10` ([`../01-sistema/02-configuracion-inicial.md`](../01-sistema/02-configuracion-inicial.md) §6–§7).
  - Discos `hd5t` y `hd2t` montados con `noatime,nofail` y SMART activo ([`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md)).
  - Stack de monitorización vivo: Prometheus + Node Exporter + cAdvisor + Grafana ([`../05-monitorizacion/`](../05-monitorizacion/)). Sin este stack no hay forma honesta de decir si un cambio "mejora" el sistema; este doc se vuelve folclore.
- **Acceso SSH al host** con permisos `sudo`. Algunas acciones (editar `/boot/firmware/config.txt`, recargar `sysctl`, cambiar el scheduler de un disco) requieren reboot.
- **`vcgencmd`** disponible (forma parte de `libraspberrypi-bin`, viene con Raspberry Pi OS Lite por defecto).
- **`glances`, `iostat` (paquete `sysstat`), `htop`, `lm-sensors`** instalados como herramientas de diagnóstico. Se instalan a la primera necesidad:
  ```bash
  sudo apt install -y sysstat htop glances lm-sensors
  ```
- **Bitácora abierta**: cualquier cambio aplicado debe quedar en `~/homelab/operations/maintenance.log` con cadencia `ad-hoc` (convención §8 de [`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md)).

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Política general | **No tocar lo que va bien** | La Pi 5 8 GB con *Active Cooler* aguanta el catálogo de `SERVICES.md` con holgura (§2). El tuning preventivo introduce riesgo (un cambio de scheduler que rompe un dump de BD a las 04:00) sin recompensa medible. |
| Overclocking | **Desactivado por defecto** | Estabilidad ≫ pico de rendimiento en un equipo 24/7 con cargas no críticas en latencia. La Pi 5 a 2.4 GHz ya es ~2× la Pi 4. Solo se overclockea si una carga concreta lo justifica con datos de Grafana — ver §4. |
| Active Cooler | **Curva PWM gestionada por firmware** | La Pi 5 con `dtparam=cooling_fan=on` (configuración de fábrica de Raspberry Pi OS) tiene una curva de ventilador PWM por defecto razonable. Se cambia solo si hay throttle observado. |
| `mem_limit` por contenedor | **Obligatorio para cualquier servicio que pueda tener fugas o picos** (Jellyfin, Stash, HA, Sonarr/Radarr, Mosquitto, Z2M, etc.) | Sin `mem_limit`, un único leak puede tumbar la Pi entera. Cada doc de servicio (Fases 5–12) ya documenta su valor; §6 consolida el presupuesto. |
| `cpus:` por contenedor | **Solo en cargas que sostengan ≥ 1 core durante minutos** (Jellyfin transcoding, Stash generate, Borgmatic) | Limitar CPU a servicios "ráfaga" (Sonarr, Caddy, Bookstack) introduce más perjuicio (latencia) que beneficio. Detalle en §5. |
| Scheduler de I/O | **`mq-deadline`** para `hd2t` y `hd5t`; **`none`** para microSD | Bueno para throughput de HDD bajo cargas mixtas (Borgmatic + Jellyfin). `bfq` se evalúa solo si Grafana muestra latencias de I/O > 200 ms sostenidas. |
| `vm.swappiness` | **`10`** | Heredado de [`../01-sistema/02-configuracion-inicial.md`](../01-sistema/02-configuracion-inicial.md). Valor bajo: la swap es **red de seguridad**, no extensión de RAM. |
| Bitácora de cambios de tuning | **`~/homelab/operations/maintenance.log`** con cadencia `ad-hoc` | Tres entradas en seis meses está bien; treinta indica "tuneitis" — revisar §1.3. |
| Tareas que NO entran en este doc | Mantenimiento periódico, disaster recovery, mapa de puertos, presupuesto de RAM por servicio individual (vive en cada doc) | Cubiertas por [`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md), [`./02-disaster-recovery.md`](./02-disaster-recovery.md), [`./04-red-y-puertos.md`](./04-red-y-puertos.md) y los docs de cada servicio (Fases 5–12). |

---

## 1. Filosofía: tunear lo justo, medir siempre

### 1.1. Principios

Cinco principios vertebran las decisiones de este doc:

1. **Estabilidad sobre pico**. Este equipo corre 24/7. Un 5% más de FPS de transcodificación a costa de un crash mensual es un mal trato. Todas las palancas se eligen del lado conservador.
2. **Observabilidad antes que tuning**. Sin Prometheus + Grafana viviendo, **no se tunea nada**: cualquier "mejora" sería una sensación, no un dato. El stack de Fase 5 es prerrequisito real, no decorativo.
3. **Presupuestos explícitos**. Memoria, CPU e I/O del homelab son **finitos** (8 GB de RAM, 4 cores, 1 controladora USB compartida por dos discos). Antes de añadir un servicio nuevo, se confirma que cabe en el presupuesto (§6) — si no, hay que **quitar** algo o **bajar** los `mem_limit` de otro.
4. **Una palanca cada vez**. Si se cambian a la vez `arm_freq`, scheduler de I/O y `mem_limit` de Jellyfin, no hay forma de saber qué causó la mejora o el problema. Cada cambio se aísla, se mide 24–48 h, se anota en la bitácora.
5. **Reversibilidad documentada**. Cada cambio de este doc viene con su contrario. `over_voltage_delta=20000` se quita comentando una línea y reiniciando; `cpus: '0.5'` se sube en el compose y `up -d`. Si algo se aplica sin que se pueda revertir trivialmente, no entra en el playbook.

### 1.2. Lo que YA hace el sistema (no hace falta tunear)

Antes de listar palancas, conviene fijar lo que **ya está** optimizado por la configuración base del homelab. Tunear estas cosas es típicamente trabajo perdido:

| Aspecto | Configuración por defecto | Documento que lo aplica |
|---|---|---|
| Curva del *Active Cooler* | Gestionada por el firmware con histéresis razonable (~50 °C empieza, ~75 °C máximo) | Built-in en Raspberry Pi OS (`dtparam=cooling_fan=on`). |
| Swap fuera de la microSD | 4 GiB en `hd2t`, `swappiness=10` | [`../01-sistema/02-configuracion-inicial.md`](../01-sistema/02-configuracion-inicial.md) §5–§6. |
| Discos montados con `noatime` | Sí (reduce escrituras innecesarias) | [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md). |
| Logs de Docker con `json-file` rotado | Política `max-size: 10m`, `max-file: 3` global vía `/etc/docker/daemon.json` | [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md). |
| `mem_limit` y `mem_reservation` por servicio | Definidos en cada `docker-compose.yml` | Cada doc de Fase 5–12 (consolidado en §6). |
| `restart: unless-stopped` | Aplicado a todos los stacks (recuperación tras OOM) | [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1. |
| `unattended-upgrades` con reboot 04:00 | Activos | [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §6. |
| Métricas de temperatura, throttle, frecuencia | Expuestas por Node Exporter (`node_thermal_zone_temp`, `node_hwmon_*`) y panel Grafana #10578 | [`../05-monitorizacion/03-node-exporter.md`](../05-monitorizacion/03-node-exporter.md). |

### 1.3. Síntomas de "tuneitis"

Algunas señales tempranas de que el tuning está degenerando en hobby antes que en herramienta:

- La bitácora `maintenance.log` tiene más líneas `ad-hoc · tuning ...` que `monthly`.
- Se cambian dos cosas en la misma sesión "para ver cuál funciona".
- Se fija una frecuencia overclock por foros, sin dato de Grafana.
- Se sube `mem_limit` a un servicio porque "para qué dejar RAM sin usar".
- El operador prueba un *governor* nuevo y olvida cuál es el original.

La política del homelab: **si una sesión de tuning se está alargando > 1 h y no hay un síntoma medible disparándola, parar y volver al `maintenance.log`**.

---

## 2. Línea base: qué se espera de la Pi 5 8 GB con este homelab

Tunear sin línea base es ruido. Esta sección documenta qué métricas presenta una Pi 5 sana con todos los servicios de `SERVICES.md` desplegados, en dos escenarios típicos.

### 2.1. Hardware de referencia

- Raspberry Pi 5 modelo B con **8 GB de RAM LPDDR4X**.
- BCM2712 (4× Cortex-A76 @ **2.4 GHz** stock).
- *Active Cooler* oficial montado correctamente (sin polvo en aletas).
- Fuente oficial **27 W USB-C PD**.
- microSD A2 64 GB clase A2 (boot + rootfs).
- `hd5t` (5 TB USB 3.0, multimedia Stash) y `hd2t` (2 TB USB 3.0, datos resto + backups + swap).
- Ethernet gigabit conectado al router.

### 2.2. Idle (fin de semana, sin tareas pesadas activas)

Snapshot esperado a las 22:00 de un domingo, con todos los stacks levantados pero **sin** transcoding, scan, backup ni indexación en curso:

| Métrica | Valor esperado | Comando / panel |
|---|---|---|
| Temperatura SoC | **45–55 °C** | `vcgencmd measure_temp`; Grafana panel "CPU Temperature". |
| Frecuencia CPU | **600 MHz – 1.5 GHz** (governor `ondemand`) | `vcgencmd measure_clock arm` ÷ 1e6. |
| `vcgencmd get_throttled` | **`throttled=0x0`** | Cualquier bit ≠ 0 → ver §3.2 y §10. |
| Carga (`uptime`) | **0.10 – 0.40** | `uptime`. |
| RAM en uso (sin caches) | **2.5 – 3.5 GiB** | `free -h` columna `used`. |
| Swap en uso | **0 – 50 MiB** | `swapon --show` / `free -h`. |
| Tráfico de red | **< 100 KB/s** sostenido | Grafana "Node Network". |
| I/O `hd2t`/`hd5t` | **< 1 op/s** sostenido (algún heartbeat de logs) | `iostat -xz 5 3`. |
| Power draw aprox. | **3.5 – 5 W** | (estimación; medible con pinza si hay hardware). |

### 2.3. Bajo carga típica (escenario "mediodía sábado")

Snapshot esperado durante la **única ventana del día** en la que todo se acumula: usuario viendo Jellyfin con transcoding software a 1080p (no hay HW transcode útil en ARM aquí — ver [`../09-multimedia/01-jellyfin.md`](../09-multimedia/01-jellyfin.md)), Stash terminando un *generate* nocturno que se quedó atrás, Sonarr haciendo RSS sync, Borgmatic corriendo (programado fuera de horario habitualmente, pero asumamos coincidencia para el peor caso):

| Métrica | Valor esperado | Acción si **excede** |
|---|---|---|
| Temperatura SoC | **65–80 °C** | > 80 °C sostenido > 5 min → §3 (gestión térmica). |
| `throttled=0x...` | `0x0` o `0x80000` (bit "thermal throttle ocurrió en algún momento") aceptable | bits 0x1, 0x2, 0x4 (under-voltage o frequency-cap activo *now*) → §3.2 y §10. |
| Carga 1m | **2.5 – 4.5** | > 5 sostenido → §5 priorización. |
| RAM en uso | **5.0 – 6.5 GiB** | > 7.0 GiB sostenido → §6 presupuesto. |
| Swap en uso | **< 500 MiB**, en goteo | > 1 GiB sostenido → revisar `mem_limit` (§6) y candidatos a `mem_reservation` superior. |
| `iowait` | **5–15 %** | > 25 % sostenido → §7 (I/O). |
| I/O `hd2t` | **5–40 MB/s** durante backup; bajo el resto | I/O queue depth > 32 sostenido → §7. |
| FPS Jellyfin transcode 1080p H.264→H.264 | **30–50** (depende de bitrate) | < 24 → bajar bitrate target o revisar §3 + §5. |

> **Importante**: el bit `0x80000` de `vcgencmd get_throttled` significa "ha habido throttle térmico en algún momento desde el último reboot". Es **histórico**, no actual. No es alarma por sí solo si la temperatura *ahora* es razonable. Para el "está pasando *ahora*", mirar bit `0x4` (frequency capped) y `0x1` (under-voltage).

### 2.4. Cómo establecer la línea base personal

La primera vez que se llega aquí (típicamente justo después de Fase 5):

1. Dejar la Pi corriendo **una semana entera** con todos los servicios desplegados pero sin tuning aplicado.
2. Mirar los paneles de Grafana en rango "últimos 7 días": temperatura, RAM, swap, I/O, carga.
3. Anotar en `~/homelab/operations/maintenance.log`:

   ```text
   2026-05-15 · ad-hoc · linea base de rendimiento Pi5 fijada: idle 50C, carga<0.3, RAM 3.0GiB; carga semanal max 78C, carga 3.8, RAM 6.1GiB, swap 280MiB; throttled=0x80000 una vez tras gen masivo Stash · sin acción
   ```

4. Esta línea queda como **referencia**: cualquier "está raro" futuro se compara contra ella, no contra una sensación. Si en 6 meses la temperatura idle pasa de 50 a 62 °C es síntoma (probablemente polvo en el cooler — limpieza anual, [`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md) §7.1).

---

## 3. Gestión térmica

La Pi 5 con *Active Cooler* es razonablemente generosa: la curva por defecto del firmware empieza a hacer girar el ventilador en torno a 50 °C, lo lleva al ~50 % a 67 °C y al 100 % a 75 °C, y la SoC empieza a *throttle* (bajar frecuencia) **a 80 °C** y dispara *cap* fuerte a **85 °C**.

### 3.1. Cómo lee la Pi su propia temperatura

```bash
# Lectura única:
vcgencmd measure_temp
# temp=53.2'C

# Lectura por hwmon (lo que consume Node Exporter):
cat /sys/class/thermal/thermal_zone0/temp     # millidegC, p.ej. "53203"

# Estado térmico/eléctrico extendido (clave en debugging):
vcgencmd get_throttled
# throttled=0x0   → todo OK
# throttled=0x50000  → bit 16 = throttle térmico ocurrió, bit 18 = soft-temp limit ocurrió

# Frecuencia actual (cgi-bin friendly):
vcgencmd measure_clock arm
# frequency(48)=2400000000   (2.4 GHz)

# Voltaje del SoC core:
vcgencmd measure_volts core
```

Decodificación de `get_throttled` (los bits que importan):

| Bit | Hex | Significado | Acción si está en 1 *ahora* |
|---|---|---|---|
| 0 | `0x1` | Under-voltage detectado | Cambiar fuente a oficial 27 W. Revisar cable USB-C de la fuente (algunos cables baratos caen mucho voltaje). |
| 1 | `0x2` | Arm frequency capped | Térmico (usual) o `force_turbo` mal configurado. Mirar bit 2 y bit 16. |
| 2 | `0x4` | Currently throttled | El SoC está rebajando frecuencia *ahora mismo*. §3.4. |
| 3 | `0x8` | Soft temperature limit active | El SoC está aplicando límite suave de temperatura. |
| 16 | `0x10000` | Under-voltage *ha ocurrido* desde boot | Histórico. Si nunca aparece "actual" (bit 0), tolerable, pero anotar. |
| 17 | `0x20000` | Arm frequency capped *ha ocurrido* | Histórico. |
| 18 | `0x40000` | Currently throttled *ha ocurrido* | Histórico. |
| 19 | `0x80000` | Soft temp limit *ha ocurrido* | Histórico. |

Regla operativa: **bits 0–3 en 1 = problema vivo**; bits 16–19 en 1 = histórico, contextualizar contra Grafana en rango "últimos 7 días".

### 3.2. Curva del *Active Cooler* y cuándo tocarla

Por defecto, en Raspberry Pi OS Lite con *Active Cooler*, el archivo `/boot/firmware/config.txt` ya incluye (entre otras cosas):

```
dtparam=cooling_fan=on
```

Esto activa la curva PWM gestionada por firmware. Los umbrales son (`dtparam` documentado en el árbol de dispositivos del kernel del Pi):

| Umbral por defecto | Velocidad ventilador | Cuándo |
|---|---|---|
| 50 °C | ~30 % (audible suave) | Carga ligera. |
| 60 °C | ~50 % | Carga media (Sonarr scan, Borgmatic en curso). |
| 67–70 °C | ~75 % | Stash generate o Jellyfin transcoding. |
| 75 °C | 100 % | Pico — duración esperada < 5 min. |
| 80 °C | (throttle entra a frenar al SoC) | Si la curva no logra bajar la temperatura, el firmware reduce frecuencia. |

**Cuándo cambiar la curva**: prácticamente nunca. Las dos razones legítimas:

1. **El ventilador molesta** (Pi en el dormitorio): se baja umbral inferior para que arranque antes y suba más lento, sacrificando 2–3 °C de cabeza:
   ```ini
   # /boot/firmware/config.txt
   dtparam=fan_temp0=45000     # 45 C arranca
   dtparam=fan_temp0_hyst=5000 # histéresis 5 C
   dtparam=fan_temp1=55000
   dtparam=fan_temp1_speed=128 # 0..255
   dtparam=fan_temp2=65000
   dtparam=fan_temp2_speed=192
   dtparam=fan_temp3=75000
   dtparam=fan_temp3_speed=255
   ```
   Reboot (`sudo reboot`) y verificar con `vcgencmd measure_temp` durante 24 h.

2. **El cooler está infradimensionado** (carcasa no oficial, perfil pasivo) y el throttling es persistente: subir los umbrales no soluciona nada — la solución es **cambiar el cooler**, no la curva.

### 3.3. Limpieza física

Polvo en el disipador del *Active Cooler* sube fácilmente +5 °C la temperatura idle, lo que **traslada toda la curva**: lo que antes se estabilizaba a 70 °C ahora corona en 75–78 °C y entra en throttle más fácilmente. La sesión anual del playbook periódico ([`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md) §7.1) incluye limpieza con aire comprimido como tarea explícita.

### 3.4. Qué hacer si la Pi *throttle* sostenido

Síntoma: `vcgencmd get_throttled` reporta `0x4` o `0xc` (currently throttled) durante minutos, y Grafana confirma que la frecuencia del CPU está clavada por debajo de 2.4 GHz a pesar de la carga.

Acciones por orden:

1. **Confirmar la causa**: temperatura > 80 °C → térmica; bit `0x1` activo → eléctrica (fuente / cable / disco USB tirando demasiada corriente).
2. **Si térmica**:
   - Pausar la carga pesada (`docker compose stop jellyfin stash`).
   - Limpiar polvo (visual + aire comprimido).
   - Verificar que la pasta térmica del cooler oficial no se ha desplazado (visible al desmontar).
   - Si persiste tras limpieza → considerar cambio de cooler a uno **mejor**, no aplicar más curva.
3. **Si eléctrica**:
   - Sustituir la fuente por la oficial 27 W si se está usando una genérica.
   - Probar con otro cable USB-C corto y certificado.
   - Si los discos USB son auto-alimentados desde la Pi (caso desaconsejado en el homelab — ambos deben ir con su propia fuente), pasarlos a alimentación externa.
4. **Anotar en `maintenance.log`** la causa raíz y la acción aplicada.

---

## 4. Overclocking conservador (opcional, normalmente innecesario)

### 4.1. Por qué este homelab NO overclocka por defecto

La Pi 5 stock entrega 4 cores Cortex-A76 a 2.4 GHz, suficiente para el catálogo descrito. Las cargas que más castigan CPU son:

- **Jellyfin transcoding software**: limitado por ffmpeg/codec antes que por reloj. Pasar de 2.4 a 2.6 GHz mejora ~6–8 % los FPS, no resuelve un transcode imposible.
- **Stash generate**: I/O-bound más que CPU-bound; el cuello suele estar en `hd5t` (USB HDD) y no en el reloj.
- **Borgmatic compression**: `lz4` ya es ~free; `zstd -3` (default Borg) es ligero. Subir reloj acelera ~10 %, pero el cuello real es el HDD destino.

**Conclusión**: en el ~95 % de los casos, overclockear "para tener más" es coste sin recompensa. La justificación sólida solo aparece si Grafana muestra **CPU pegada al 95 %+ durante > 30 min sostenidos en > 3 cores** durante una operación que el operador necesita acelerar.

### 4.2. Receta conservadora documentada (solo si justificada)

Si tras §5 (priorización) y §6 (presupuesto) la conclusión es "necesito más CPU bruta", el escalón conservador para una Pi 5 con *Active Cooler* oficial y fuente 27 W es **2.6 GHz**:

```ini
# /boot/firmware/config.txt — bloque [pi5]
[pi5]
arm_freq=2600
over_voltage_delta=20000
```

- `arm_freq=2600`: sube el reloj ARM de 2.4 a 2.6 GHz.
- `over_voltage_delta=20000`: añade 20 mV al rail del SoC (notación en µV; 20000 = 20 mV). Es el delta mínimo razonable para sostener 2.6 GHz estable. **No subir más** sin medición controlada.

Pasos:

1. Backup del fichero antes de tocar:
   ```bash
   sudo cp /boot/firmware/config.txt /boot/firmware/config.txt.bak.$(date +%F)
   ```
2. Editar con `sudo nano /boot/firmware/config.txt`, añadir el bloque al final dentro de `[pi5]` (creándolo si no existe).
3. `sudo reboot`.
4. Verificar tras boot:
   ```bash
   vcgencmd measure_clock arm     # debería leer 2600000000 bajo carga
   vcgencmd measure_volts core
   vcgencmd get_throttled         # debe seguir en 0x0 tras minutos de carga
   ```
5. **Test de estabilidad**: `stress-ng --cpu 4 --timeout 10m --metrics-brief` con `vcgencmd measure_temp` y `vcgencmd get_throttled` al final. Si `throttled` sigue en `0x0` y la temperatura no superó 82 °C, el overclock es viable.
6. **Test de 48 h**: dejar la Pi con su carga real durante 48 h y revisar Grafana en busca de reboots inesperados (panel "Uptime"). Si hubo, **revertir**.

### 4.3. Cómo revertir

Comentar o borrar las dos líneas del bloque `[pi5]` y `sudo reboot`. La Pi vuelve a 2.4 GHz stock.

### 4.4. Lo que NO se hace en este homelab

| Tentación | Por qué se rechaza |
|---|---|
| `arm_freq=2800` o superior | Necesita `over_voltage_delta` ≥ 50000 + cooler agresivo. Riesgo real de inestabilidad de cgroups, cierres súbitos durante backup. Beneficio < 10 % sobre 2.6 GHz. |
| `force_turbo=1` | Desactiva escalado dinámico. Sube consumo, calor y desgaste continuamente para una carga que es por ráfagas. |
| `gpu_freq=...` | Esta Pi no hace render 3D. Tunear GPU es solucionar un problema que no existe. |
| Cambiar `cpu_governor` a `performance` permanente | Mismo razonamiento que `force_turbo=1`. El `ondemand` por defecto reacciona en milisegundos. |
| Disable de cgroups, cgroups-v1, etc. | Docker y `mem_limit` dependen de cgroups v2; tocar esto rompe los presupuestos del §6 silenciosamente. |

---

## 5. Priorización de servicios

La Pi 5 tiene 4 cores y 8 GB de RAM compartidos por **todo** el homelab. Cuando hay contención, hay servicios que **no pueden** llegar tarde (Pi-hole, Caddy, Authelia: si caen, todo el LAN nota) y otros que **sí** pueden (Stash generate, Borgmatic, Sonarr scan: si tardan unos minutos más, nadie se entera). La priorización codifica esa diferencia.

### 5.1. Tres ejes de priorización

1. **CPU**: `cpus`, `cpu_shares` / `cpu_weight` en cada `docker-compose.yml`.
2. **Memoria**: `mem_limit`, `mem_reservation` (§6) y `oom_score_adj`.
3. **I/O**: `IOSchedulingClass` y `IOSchedulingPriority` aplicables vía `systemd` al servicio Docker o vía `device_cgroup_rules`. En la práctica, el homelab solo aplica esto al servicio Borgmatic mediante una unit timer dedicada.

### 5.2. Tabla canónica de tiers

Los servicios del homelab se clasifican en cuatro tiers, cada uno con un perfil de recursos:

| Tier | Servicios típicos | `cpus` | `cpu_shares` (relativo) | `mem_reservation` | `oom_score_adj` |
|---|---|---|---|---|---|
| **T0 — Plataforma** | Pi-hole, Unbound, Caddy, Tailscale, Authelia, Watchtower (*excluido del kill*) | sin tope (acceden a los 4 cores si hace falta) | `1024` (peso medio normal) | suficiente para arrancar limpio | `-500` (poco probable matar) |
| **T1 — Acceso del usuario** | Jellyfin, Nextcloud, Vaultwarden, Bookstack, Home Assistant | sin tope general; `cpus: '3.5'` opcional para Jellyfin durante transcoding | `1024` | el del doc | `0` (default) |
| **T2 — Procesamiento por ráfaga** | Sonarr, Radarr, Prowlarr, Stash generate, Paperless OCR, Navidrome scan, Audiobookshelf scan | `cpus: '2.0'` para los más pesados (Stash, Paperless) | `512` | el del doc | `+200` (kill antes que T0/T1) |
| **T3 — Tareas batch nocturnas** | Borgmatic | `cpus: '2.0'` | `256` | (corre como CLI, no contenedor 24/7) | `+500` (kill primero si OOM) |

> **Nota**: estos `cpus` y `cpu_shares` **no** están aplicados todos por defecto en los `docker-compose.yml` actuales. Cada servicio define su propio criterio en su doc de Fase. Esta tabla **propone** la convención cuando el operador detecte contención; se aplica servicio a servicio editando su compose, no globalmente.

### 5.3. Aplicar `cpus` a un servicio (ejemplo Stash)

```yaml
# docker-compose.yml de Stash
services:
  stash:
    image: stashapp/stash:latest
    # ... resto ...
    cpus: '2.0'             # ≤ 2 cores para Stash; deja 2 para todos los demás
    mem_limit: 2500m        # ya documentado en 09-multimedia/05-stash.md
    mem_reservation: 256m
```

`cpus: '2.0'` se traduce, en cgroups v2, a `cpu.max = "200000 100000"` (es decir, 200 ms de CPU por cada 100 ms de período). Stash **nunca** dejará a Pi-hole sin CPU para responder DNS — a costa de que su *generate* tarde algo más.

### 5.4. `oom_score_adj`: a quién matar primero si la memoria se agota

Cuando el OOM-killer entra (memoria + swap saturadas), la elección de la víctima sigue una puntuación. Por defecto todos los procesos parten de cerca de 0 y el kernel suma la huella de memoria del proceso. Se ajusta con `oom_score_adj` (rango -1000 a +1000):

```yaml
# Pi-hole o Caddy: penalizar al kernel por intentar matarlos
services:
  pihole:
    # ...
    oom_score_adj: -500

# Borgmatic CLI: invitar al kernel a matarlo antes que a un servicio T0
# (esto se aplica en la unit systemd que lanza borgmatic, no en compose)
```

> **Cuidado**: `oom_score_adj: -1000` deshabilita por completo el kill del proceso. Si ese proceso es el que tiene la fuga, **el sistema entero** entra en thrashing. Por eso `-500` (no `-1000`) para T0.

### 5.5. Priorizar I/O de Borgmatic

Borgmatic corre como CLI desde un timer `systemd` (no como contenedor 24/7). En la unit que lo dispara se puede bajar su prioridad de I/O para que no compita con Jellyfin si por alguna razón coinciden:

```ini
# /etc/systemd/system/borgmatic.service (extracto)
[Service]
Type=oneshot
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7         # 0 = mayor prioridad, 7 = menor
ExecStart=/usr/bin/borgmatic --verbosity 1
```

Esto, combinado con `vm.swappiness=10` y el scheduler `mq-deadline` del §7, hace que un `docker compose logs -f` de Jellyfin bajo carga no se atasque cuando Borgmatic está leyendo el árbol de servicios.

### 5.6. Lo que NO se prioriza

- **No se renicea Caddy con valores < -10**: la latencia importa, pero forzar un nice negativo entra en territorio donde un bug del proceso se traga el equipo. El valor por defecto (0) ya es competitivo si se respetan los `cpus` del resto.
- **No se intenta "pinear cores"** (CPU affinity por servicio). Beneficio teórico < 5 %, complejidad operativa alta. La Pi 5 no es el equipo para eso.

---

## 6. Presupuesto consolidado de memoria

Esta sección es la **fuente de verdad** del homelab cuando se decide si un servicio nuevo cabe o no. Suma los `mem_limit` documentados en cada `docker-compose.yml` de Fases 5–12.

### 6.1. Tabla por servicio

| Fase | Servicio | `mem_limit` | `mem_reservation` | Notas |
|---|---|---|---|---|
| 02 | Portainer | 256m | 64m | Idle ~80 MB. |
| 02 | Watchtower | 128m | 32m | Solo activo en el tick semanal. |
| 03 | Pi-hole + Unbound | 384m | 96m | Pi-hole (256m) + Unbound (128m). |
| 03 | Caddy | 256m | 32m | Idle ~30 MB. |
| 03 | Tailscale (host) | (no contenedor) | — | ~50–80 MB residentes en host. |
| 04 | Authelia | 256m | 64m | Idle ~80 MB. |
| 05 | Prometheus | 1024m | 256m | Crece con retención; vigilar. |
| 05 | Grafana | 512m | 128m | Idle ~150 MB. |
| 05 | Node Exporter | 64m | 16m | <30 MB. |
| 05 | cAdvisor | 256m | 64m | Vigilar leaks (ver doc). |
| 05 | Uptime Kuma | 256m | 64m | <80 MB con ~30 monitores. |
| 05 | Dozzle | 128m | 32m | <30 MB stateless. |
| 06 | Nextcloud + DB + Redis | 1536m | 384m | Pico durante reescaneos. |
| 06 | Samba | 128m | 32m | Por sesión activa. |
| 06 | Syncthing | 256m | 64m | Crece con índices. |
| 06 | MinIO | 384m | 64m | Solo si se usa. |
| 07 | Borgmatic (CLI por timer) | — | — | No 24/7. |
| 08 | Home Assistant | 2048m | 512m | Con HACS + integraciones. |
| 08 | Mosquitto | 256m | 32m | <50 MB. |
| 08 | Zigbee2MQTT | 512m | 128m | Pico OTA. |
| 08 | Node-RED | 512m | 96m | `--max-old-space-size=384`. |
| 09 | Jellyfin | 2048m | 512m | Pico transcoding + scan. |
| 09 | Navidrome | 1024m | 128m | Scan grande. |
| 09 | Audiobookshelf | 1500m | 256m | Scan + HLS streaming. |
| 09 | Calibre-Web | 1500m | 128m | Convert puntual. |
| 09 | Stash | 2500m | 256m | Generate masivo. |
| 10 | Transmission | 768m | 64m | Verificación de piezas. |
| 10 | Prowlarr | 768m | 128m | Sync indexers. |
| 10 | Sonarr | 1280m | 256m | Mass Editor. |
| 10 | Radarr | 1024m | 256m | Mass Editor. |
| 11 | Vaultwarden | 256m | 64m | <80 MB. |
| 11 | Bookstack + DB | 768m | 128m | PHP-FPM. |
| 11 | Linkding | 256m | 64m | Django + worker. |
| 11 | Paperless-ngx | 1024m | 256m | OCR (cargas batch). |
| 11 | Mealie | 512m | 96m | <200 MB. |
| 11 | Stirling-PDF | 512m | 64m | Stateless. |
| 11 | FreshRSS | 256m | 64m | <80 MB. |
| 12 | Homepage + dockerproxy | 320m | 64m | Idle ~120 MB. |

### 6.2. Suma y huelga

- **Suma de `mem_limit`**: ≈ **24 GiB** declarados.
- **Suma de `mem_reservation`**: ≈ **5 GiB**.
- **RAM física**: 8 GiB.

La suma de `mem_limit` excede holgadamente la RAM física **a propósito**: los `mem_limit` son **techos** raramente alcanzados a la vez. La métrica que de verdad importa es la suma de **uso real concurrente**, que en el peor caso documentado (§2.3) ronda los 6.5 GiB. La suma de `mem_reservation` (~5 GiB) es la garantía mínima de arranque limpio: queda margen de ~3 GiB para caches del kernel, transitorios y arranque de un servicio nuevo.

### 6.3. Reglas para añadir un servicio nuevo

1. Documentar `mem_limit` + `mem_reservation` en su `docker-compose.yml`. Sin esto, el servicio **no entra**.
2. Sumar a la columna `mem_reservation` total. Si pasa de **6 GiB**, hay que **bajar** la reserva de algún otro servicio o decidir no añadir el nuevo.
3. Probar 7 días midiendo en cAdvisor el uso real (panel "Memory by container" en Grafana). Si el uso real supera el 80 % del `mem_limit` sostenido, **subir** el límite (con justificación) y revisar §6.2.

### 6.4. Señales de fuga

| Síntoma | Probable causa | Acción |
|---|---|---|
| Uso sostenido > 90 % de `mem_limit` durante días | Leak en el servicio | Ver doc del servicio (sección "Solución de Problemas"); fijar versión anterior si Watchtower lo subió de major. |
| `exit 137` recurrente en un contenedor | OOM kill por cgroups | Subir `mem_limit` (con justificación) o investigar leak. |
| Swap creciendo lentamente cada día | Memoria fragmentada / leak lento | Reboot programado mensual (lo cubre `unattended-upgrades`). |
| RAM al 95 %+ con swap saturada | Saturación real | Pausar servicio T2/T3, revisar carga atípica, bajar `mem_limit` general. |

---

## 7. I/O y discos

La Pi 5 enchufa los dos HDD por **una sola controladora USB 3.0** compartida. Es la limitación I/O más relevante del homelab: dos lecturas/escrituras secuenciales paralelas en `hd5t` y `hd2t` se serializan en esa controladora.

### 7.1. Scheduler de I/O

Por defecto, Raspberry Pi OS asigna `mq-deadline` a HDDs y `none` a microSDs. Se puede confirmar:

```bash
for dev in /sys/block/sd?/queue/scheduler /sys/block/mmcblk0/queue/scheduler; do
  printf '%-30s -> ' "$dev"; cat "$dev"
done
```

Salida esperada:

```
/sys/block/sda/queue/scheduler -> [mq-deadline] none
/sys/block/sdb/queue/scheduler -> [mq-deadline] none
/sys/block/mmcblk0/queue/scheduler -> [none] mq-deadline
```

- **`mq-deadline`** en HDDs: prioriza completar requests dentro de un deadline; muy bueno para mezclar Borgmatic (lecturas grandes secuenciales) con Jellyfin (lecturas medianas a la cabeza del disco).
- **`none`** en microSD: la microSD ya tiene su FTL interno; un scheduler en software añade latencia sin beneficio.

**Cuándo cambiar a `bfq`**: solo si Grafana muestra latencias > 200 ms sostenidas en `node_disk_read_time_seconds_total / node_disk_reads_completed_total` durante operaciones mixtas. `bfq` es más justo bajo contención fuerte pero más caro en CPU; en este homelab la contención apenas existe gracias a la separación funcional `hd5t`/`hd2t`.

Si se decide aplicar `bfq` (a `hd2t`, donde está toda la actividad mixta):

```bash
# Inmediato (no persiste tras reboot):
echo bfq | sudo tee /sys/block/sda/queue/scheduler

# Persistente vía udev:
sudo tee /etc/udev/rules.d/60-io-scheduler.rules <<'EOF'
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", \
    ATTR{queue/scheduler}="bfq"
EOF
sudo udevadm control --reload && sudo udevadm trigger
```

Y revertir consiste en borrar el archivo y volver a triggerear.

### 7.2. Hot zones de I/O

Quién escribe dónde, en orden de actividad típica:

| Disco / partición | Servicios principales | Patrón |
|---|---|---|
| **microSD** | rootfs, `/var/lib/docker/` (capas e imágenes), logs `journald` | Escritura ligera continua + ráfagas en update Watchtower domingos. |
| **`/mnt/hd5t/`** | Solo Stash multimedia (lectura masiva, escritura ocasional) | Lecturas grandes secuenciales durante streaming; escrituras solo en imports. |
| **`/mnt/hd2t/services/`** | Datos de **todos** los demás servicios + BD + caches | Escritura mixta moderada continua. |
| **`/mnt/hd2t/backups/`** | Borg repo + dumps | Escritura masiva una vez al día (03:00). |
| **`/mnt/hd2t/swap/swapfile`** | Swap del kernel | Idealmente sin uso; goteo bajo presión. |

Lo crítico: **`/mnt/hd2t/services/` y `/mnt/hd2t/backups/` están en el mismo disco físico**. La sesión nocturna de Borgmatic (lectura masiva de `services/` + escritura masiva en `backups/`) genera un periodo de I/O alto. Por eso Borgmatic se programa a las 03:00 (sin actividad humana) y por eso §5.5 baja su prioridad de I/O.

### 7.3. Microoptimización: `noatime` y `commit=600`

Ambos discos están montados con `noatime` ya en [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md). Eso evita escribir el "atime" en cada lectura — ahorro pequeño pero real con HDDs.

`commit=600` en `fstab` (ext4) puede subir el intervalo de fsync del journal de 5 s a 10 min, reduciendo escrituras pero **aumentando** la pérdida potencial en un corte súbito. **No se aplica** en este homelab: `hd2t` contiene BD que no toleran esa ventana, y el ahorro no compensa la complicación. Mantener defaults.

### 7.4. Swap en HDD

El swapfile en `hd2t` con `swappiness=10` está pensado como **red de seguridad**, no como extensión. Si el operador ve > 1 GiB de swap usado sostenido, lo correcto **no** es subir la swap o cambiar el `swappiness`, sino:

1. Identificar el contenedor culpable con `docker stats` o panel cAdvisor "Memory by container".
2. Aplicar `mem_limit` o reducirlo donde proceda.
3. Considerar pausar T2/T3 mientras se diagnostica.

Subir `swappiness` con HDD como swap es prácticamente garantía de degradación visible (latencias multimillonarias en ms).

---

## 8. Kernel y `sysctl`

Lista corta de ajustes de kernel aplicados o evaluados en este homelab. Solo se incluye lo **decidido**, no la enciclopedia.

### 8.1. Aplicados por defecto (en Fase 1)

| Parámetro | Valor | Documento que lo aplica |
|---|---|---|
| `vm.swappiness` | `10` | [`../01-sistema/02-configuracion-inicial.md`](../01-sistema/02-configuracion-inicial.md) §6. |

### 8.2. Evaluados — aplicar **solo si justificado**

| Parámetro | Valor sugerido | Cuándo aplicar | Justificación |
|---|---|---|---|
| `vm.vfs_cache_pressure` | `50` | Si Grafana muestra mucha rotación de inodos en cache | Reduce la presión que el kernel pone sobre las caches de FS. En idle no aporta. |
| `vm.dirty_ratio` | `10` | Solo si se observa gran retraso de fsync que afecta latencia visible | Limita el porcentaje de RAM "sucia" (pendiente de flush). Defaults Debian (~20) están OK. |
| `vm.dirty_background_ratio` | `5` | Junto con el anterior | Inicia flush antes — útil si los HDD escriben en ráfagas grandes. |
| `net.core.rmem_max` / `wmem_max` | `2500000` | Si Tailscale o Caddy pierden paquetes en ráfaga | Buffers de socket. La mayoría del tráfico del homelab es trivial; default suele ser suficiente. |
| `kernel.numa_balancing` | `0` | (N/A: la Pi no es NUMA) | — |
| `vm.overcommit_memory` | `1` | Si Redis o servicios con `fork()` quejan en logs | Permite overcommit; Redis lo recomienda. La huella es baja en este homelab. |

Aplicar de forma persistente:

```bash
sudo tee /etc/sysctl.d/90-homelab.conf <<'EOF'
# Tuning específico del homelab. Documentado en docs/13-operaciones/03-rendimiento-pi5.md
vm.swappiness=10
# vm.vfs_cache_pressure=50
# vm.dirty_ratio=10
# vm.dirty_background_ratio=5
EOF
sudo sysctl --system
```

> Las líneas comentadas se descomentan **solo** cuando hay un dato de Grafana que lo justifique. No descomentar "por buena medida".

### 8.3. Lo que no se toca

- `transparent_hugepage`: en ARM64 con cargas variadas, dejar en `madvise` (default).
- `net.ipv4.tcp_*` (timers, rwin, etc.): el tráfico interno LAN no se beneficia de tuning agresivo. Tailscale ya hace su propio tuning a nivel WireGuard.
- `cgroup` swap accounting: ya está habilitado por defecto en Raspberry Pi OS Bookworm. Sin él, `mem_limit` no contabilizaría swap. Verificar `cat /proc/cmdline | grep cgroup_enable=memory`.

---

## 9. Verificación

Toda intervención de tuning se cierra con una pasada de verificación.

### 9.1. Comandos canónicos

```bash
# CPU y reloj:
vcgencmd measure_clock arm
vcgencmd measure_volts core
vcgencmd get_throttled
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq

# Térmica:
vcgencmd measure_temp
sensors                         # con lm-sensors

# Memoria y swap:
free -h
swapon --show
cat /proc/pressure/memory       # PSI: la mejor métrica moderna
docker stats --no-stream

# I/O:
iostat -xz 5 3
iotop -aoP                      # apt install iotop
cat /proc/pressure/io

# Carga global:
uptime
glances                         # vista consolidada interactiva
htop
```

`/proc/pressure/{cpu,memory,io}` (PSI — Pressure Stall Information) es la métrica moderna que dice cuánto tiempo "stallea" el sistema esperando un recurso. Más útil que `iowait` simple para detectar saturación intermitente.

### 9.2. Paneles de Grafana

Los paneles relevantes vienen ya provisionados por [`../05-monitorizacion/02-grafana.md`](../05-monitorizacion/02-grafana.md):

- **Node Exporter Full** (#1860): "CPU Basic", "Memory Basic", "Disk IOps", "Network".
- **Raspberry Pi Monitoring** (#10578): paneles dedicados a temperatura, throttle y voltaje.
- **Docker / cAdvisor** (provisionado vía [`../05-monitorizacion/04-cadvisor.md`](../05-monitorizacion/04-cadvisor.md)): "Memory by container", "CPU by container".

Antes y después de cualquier cambio de §3, §4, §5, §7 u §8, **screenshot** de los paneles relevantes (rango "últimas 24 h" antes; rango "últimas 24 h" 24 h después) y archivar en `~/homelab/operations/perf/<YYYY-MM-DD>/`.

### 9.3. Stress test reproducible

```bash
sudo apt install -y stress-ng

# CPU 4 cores, 10 min — calienta y mide térmica:
stress-ng --cpu 4 --timeout 10m --metrics-brief

# Memoria — 4 GiB, 5 min, comprueba que mem_limit no rompe nada en pares:
stress-ng --vm 2 --vm-bytes 2G --timeout 5m

# I/O — escritura mixta sobre hd2t (CON CUIDADO: usar fichero dedicado bajo /mnt/hd2t/services/_perf/):
stress-ng --hdd 1 --hdd-bytes 2G --temp-path /mnt/hd2t/services/_perf --timeout 3m
```

Tras cada test:

```bash
vcgencmd get_throttled
vcgencmd measure_temp
free -h
```

### 9.4. Anotación en bitácora

Toda sesión de tuning, exitosa o no, cierra con entrada en `~/homelab/operations/maintenance.log`:

```text
2026-06-08 · ad-hoc · perf: cambio scheduler hd2t a bfq tras observar lat. >250ms en backups (panel #1860). Test 48h OK, lat. baja a ~80ms · aplicado y persistido vía udev
2026-07-12 · ad-hoc · perf: probado arm_freq=2600 + over_voltage_delta=20000. stress 10m OK, sin throttle. 48h sin reboots. · aplicado, anotado en /boot/firmware/config.txt
2026-08-03 · ad-hoc · perf: revertido bfq a mq-deadline en hd2t — bajo carga real no había mejora medible y stress test mostró +3% CPU en kernel · revertido
```

Commit message: `ops: maintenance ad-hoc YYYY-MM-DD <resumen>` (convención §8.3 de [`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md)).

---

## 10. Lista de Verificación

Esta sección es la forma corta del playbook de tuning: si se imprimiera y pegara al lado del monitor, debería bastar para una sesión sin abrir el doc completo.

### 10.1. Antes de aplicar cualquier cambio

- [ ] Existe línea base reciente (§2.4) anotada en `maintenance.log`.
- [ ] Hay un **síntoma medible** documentado: gráfica de Grafana, log, o `vcgencmd` que justifica la acción.
- [ ] El cambio es **uno solo** (§1.1 principio 4).
- [ ] El cambio tiene **procedimiento de rollback** documentado.
- [ ] Backup del fichero a tocar (`/boot/firmware/config.txt.bak.<fecha>`, etc.) si aplica.

### 10.2. Después del cambio

- [ ] Tras boot/reload, `vcgencmd get_throttled` sigue en `0x0` bajo carga.
- [ ] `free -h`, `iostat`, `htop` muestran lo esperado.
- [ ] Servicios T0 (Pi-hole, Caddy, Authelia) siguen verdes en Uptime Kuma.
- [ ] 24 h después: revisar mismo panel Grafana en rango "últimas 24 h" para ver el efecto antes/después.
- [ ] 48 h después: confirmar que no ha habido reboots inesperados.
- [ ] Entrada en `maintenance.log` con `ad-hoc` y resumen.

### 10.3. Cuándo NO aplicar

- [ ] La temperatura idle ronda 50 °C, las cargas no superan 75 °C, no hay `exit 137`, los servicios responden con latencia razonable → **no tunear**.
- [ ] El "problema" se ha visto una sola vez en los últimos 7 días → **no tunear** todavía, esperar dato.
- [ ] No hay forma de medir si la "mejora" funciona → **no tunear**, instalar la métrica primero.

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `vcgencmd get_throttled` reporta `0x4` o `0xc` durante minutos | Throttle térmico activo o frequency-cap | Pausar carga pesada (`docker compose stop jellyfin stash`); medir temperatura; limpiar polvo del cooler; revisar pasta térmica. Si persiste → §3.4. |
| `vcgencmd get_throttled` reporta `0x1` (under-voltage) bajo carga | Fuente / cable USB-C inadecuado | Cambiar a fuente oficial 27 W; cable corto certificado. Verificar que los HDD externos tienen su propia alimentación. |
| `vcgencmd get_throttled` se queda en `0x80000` (histórico) tras incidente | Throttle histórico pero ya recuperado | Aceptable. Se "limpia" tras reboot. No es alarma por sí solo. |
| Temperatura idle subió +5–8 °C respecto a línea base sin cambios | Polvo en el *Active Cooler* | Limpieza con aire comprimido (sesión anual del playbook periódico). |
| Contenedor con `exit 137` recurrente | OOM kill por `mem_limit` | `docker logs <c>` + cAdvisor "Memory by container". Revisar §6.4. Subir `mem_limit` si está justificado o investigar leak. |
| Sistema completo lento, swap > 1 GiB usada sostenida | Saturación de RAM | `docker stats` → identificar culpable. Aplicar/bajar `mem_limit`. NO subir `swappiness`. §7.4. |
| Latencias altas en panel Grafana "Disk IO" durante backup | Contención en la única controladora USB | Confirmar Borgmatic en horario nocturno; aplicar `IOSchedulingPriority=7` (§5.5); evaluar `bfq` (§7.1) **solo si** hay contención real durante el día. |
| Jellyfin dropea frames al transcodificar 1080p H.264 | CPU saturada (no hay HW transcode útil aquí) | Bajar bitrate target; aplicar `cpus: '3.0'` para dejar margen al resto; considerar §4 overclock conservador **si** ha sido descartado todo lo demás. |
| `htop` muestra carga > 6 sostenida | Demasiados servicios T2/T3 corriendo a la vez | Revisar §5 priorización; aplicar `cpus` a Stash, Sonarr, Paperless. |
| Pi reinicia espontáneamente bajo carga tras tocar `arm_freq` | Inestabilidad por overclock | Quitar líneas `arm_freq`/`over_voltage_delta` de `/boot/firmware/config.txt`. Reboot. Anotar en `maintenance.log`. |
| Métricas de Node Exporter muestran `node_thermal_zone_temp` plana en 0 | Drivers `hwmon` no expuestos al contenedor | Confirmar que Node Exporter monta `/sys` y se ejecuta con `--path.rootfs=/rootfs`. Detalle en [`../05-monitorizacion/03-node-exporter.md`](../05-monitorizacion/03-node-exporter.md) §N. |
| Tras `apt full-upgrade` con kernel nuevo, ventilador no arranca | El nuevo kernel cambió DT defaults | Revisar `/boot/firmware/config.txt` por si `dtparam=cooling_fan=on` quedó comentado; reaplicarlo y reboot. |
| Las gráficas de Grafana muestran mejora con un cambio pero el operador "no nota nada" | El cambio era marginal o subjetivo | Aceptar el dato: si la mejora medible es < 5 % en la métrica relevante, considerar revertir para reducir complejidad. §1.1 principio 1. |
| `glances` muestra `iowait` 30 %+ sostenido fuera de horario de backup | Servicio escribiendo en bucle (logs verbosos, transmisión sin límite) | Revisar `docker stats` con `--format "table {{.Name}}\t{{.BlockIO}}"`; ajustar log level del servicio o `logging.options.max-size` en su compose. |
| El operador overclockeó "para no quedarse atrás" sin medición previa | Tuneitis (§1.3) | Revertir, restablecer `arm_freq` por defecto, anotar lección, volver a operar. |

---

## Referencias

- [Raspberry Pi — `vcgencmd` reference](https://www.raspberrypi.com/documentation/computers/os.html#vcgencmd)
- [Raspberry Pi — Active Cooler product brief](https://datasheets.raspberrypi.com/cooling/raspberry-pi-active-cooler-product-brief.pdf)
- [Raspberry Pi — Overclocking the Raspberry Pi](https://www.raspberrypi.com/documentation/computers/config_txt.html#overclocking)
- [Raspberry Pi — `config.txt` reference (`pi5` block)](https://www.raspberrypi.com/documentation/computers/config_txt.html)
- [Linux kernel — Pressure Stall Information (PSI)](https://docs.kernel.org/accounting/psi.html)
- [Linux kernel — `vm` sysctl docs](https://docs.kernel.org/admin-guide/sysctl/vm.html)
- [Linux kernel — block I/O schedulers](https://docs.kernel.org/block/blk-mq.html)
- [Docker — Resource constraints (`mem_limit`, `cpus`, `oom_score_adj`)](https://docs.docker.com/config/containers/resource_constraints/)
- [Docker Compose — `deploy.resources` and resource limits](https://docs.docker.com/compose/compose-file/deploy/#resources)
- [stress-ng — manual](https://wiki.ubuntu.com/Kernel/Reference/stress-ng)
- [Glances — official documentation](https://nicolargo.github.io/glances/)
