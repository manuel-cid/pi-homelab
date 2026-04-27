# Rendimiento de la Pi 5

## Descripción

Define la **disciplina de rendimiento** del homelab: cómo se mide la Pi 5, qué umbrales son normales, cuándo intervenir, qué tocar primero (y qué **no** tocar) y cómo dejar registro de cada ajuste para que el siguiente operador (o el mismo, seis meses después) entienda por qué ese servicio tiene `mem_limit: 1500m` y aquel no. Es el doc al que delegan todos los demás cuando aparece la frase "los límites se ajustarán desde `docs/13-operaciones/03-rendimiento-pi5.md`": aquí es donde esa frase deja de ser una promesa y se convierte en procedimiento.

A diferencia de `docs/13-operaciones/01-mantenimiento-periodico.md` (calendario rutinario) y `docs/13-operaciones/02-disaster-recovery.md` (recuperación tras desastre), este documento cubre **operación bajo carga**: el homelab arranca, **funciona**, pero algo en su rendimiento empieza a deteriorarse — la temperatura sube, el _throttling_ aparece de noche, una alerta de RAM lleva tres días en _firing_, Jellyfin tartamudea cuando Borgmatic está corriendo. La pregunta no es "¿se ha roto?" sino "¿cómo seguir teniéndolo en verde sin sobreingeniería?".

> **Filosofía**: la Pi 5 con 8 GB es **generosa para un homelab doméstico**, pero finita. La política por defecto es **no aplicar límites preventivos** (`mem_limit`, `cpus`, `oom_score_adj`) a ningún servicio: los _composes_ de las fases 2-12 se despliegan sin restricciones de recursos, porque el _scheduler_ de Linux y el _arena_ de cgroups del propio Docker hacen un trabajo razonable cuando nada está apretando. Los límites entran **sólo cuando una métrica concreta** lo justifica, **sólo en el servicio concreto** afectado, y **sólo con el dato observado** como referencia. Aplicar `mem_limit` a un servicio que nunca pasa de 200 MB es teatro de cgroups: añade complejidad, riesgo de OOM, ruido en los _logs_, y no aporta nada.

> **Alcance**: este documento cubre la **Pi 5 como sistema completo** (host + Docker + servicios) bajo el supuesto de que el homelab está desplegado y operativo. No cubre _benchmarking_ sintético ("¿cuántos FPS hace la GPU?"), ni problemas de _build_ de imágenes (la Pi no compila imágenes — pull desde Docker Hub), ni optimización de servicios individuales más allá de los _knobs_ que el _compose_ expone (`mem_limit`, `cpus`, `oom_score_adj`, _envs_ de _runtime_). Si un servicio tiene problemas internos de _tuning_ (Nextcloud y su cache Redis, Home Assistant y sus _recorder purges_, Jellyfin y su escaneo de bibliotecas), eso vive en el doc del servicio, no aquí.

> **Alcance de red**: como en el resto del homelab, todo se mide y se ajusta **desde la LAN o vía Tailscale** (`docs/03-red/05-tailscale.md`). Las métricas de Prometheus, los _logs_ de cAdvisor, la consola Grafana y los `vcgencmd` por SSH viven dentro del _tailnet_; no hay endpoint público de telemetría.

---

## Requisitos previos

Para que las decisiones de este doc tengan datos en los que apoyarse, el _stack_ de monitorización y los detalles físicos deben estar ya en su sitio:

- `docs/00-hardware/01-material-necesario.md` completado: fuente oficial **27 W USB-C PD** y **carcasa con refrigeración activa** (Active Cooler oficial o equivalente con _fan_ controlado por el firmware). Sin ventilador activo, casi cualquier _stack_ medio cargado entra en _throttling_ térmico antes de los 30 minutos sostenidos al 100 %.
- `docs/00-hardware/02-esquema-conexiones.md` completado: ambos discos en los puertos **USB 3.0 azules**, no en los USB 2.0; sin _hub_ pasivo intermedio (los _hubs_ no alimentados son la causa #1 de desconexiones intermitentes de `hd5t`/`hd2t` bajo carga).
- `docs/01-sistema/02-configuracion-inicial.md` completado: _swap_ desplazada de la microSD a `/mnt/hd2t/system/swap/swapfile`, _zram_ desactivada, `vm.swappiness=10`, `journald` con límite de tamaño. Este punto es no negociable: una microSD nunca debe ser el destino de _swap_ del homelab — la latencia y el desgaste lo convierten en un _bottleneck_ destructivo.
- `docs/02-docker/02-estructura-compose.md` completado: cada servicio vive en su subdirectorio de `~/homelab/`, los _composes_ no tienen `mem_limit`/`cpus` por defecto (política explícita del homelab), y la red `homelab_net` es compartida.
- `docs/05-monitorizacion/01-prometheus.md`, `docs/05-monitorizacion/02-grafana.md`, `docs/05-monitorizacion/03-node-exporter.md` y `docs/05-monitorizacion/04-cadvisor.md` desplegados y funcionando. Sin `node_exporter` no hay temperatura ni _throttling_; sin cAdvisor no hay forma de saber qué contenedor consume qué.
- `docs/05-monitorizacion/05-uptime-kuma.md` desplegado: las alertas de "servicio caído" llegan al operador antes de que la familia se queje.
- Paquetes auxiliares instalados en el host (no se piden en `01-sistema/`, se suman aquí porque son específicos del _troubleshooting_ de rendimiento):
  ```bash
  sudo apt update
  sudo apt install -y htop iotop sysstat stress-ng linux-cpupower lm-sensors
  ```
  - `htop`: vista interactiva de procesos.
  - `iotop`: vista de I/O por proceso (`sudo iotop -ao` para acumulado).
  - `sysstat`: aporta `iostat`, `mpstat`, `pidstat` para series cortas.
  - `stress-ng`: generador de carga sintética para validar _overclocks_ y refrigeración.
  - `linux-cpupower`: `cpupower frequency-info` y `cpupower frequency-set` (cambiar _governor_).
- `vcgencmd` disponible (viene en Raspberry Pi OS; pertenece al paquete `libraspberrypi-bin`). Es el oráculo del estado del SoC: temperatura, _throttling_, frecuencia, _undervoltage_.

---

## Decisiones de diseño

### Una Pi 5 es generosa, pero la USB 3.0 es estrecha

El cuello de botella en este homelab no es la CPU ni la RAM: es la **USB 3.0**. La Pi 5 expone dos puertos USB 3.0 azules, pero **comparten un único controlador xHCI** y un único bus PCIe Gen 2 x1 hacia el SoC. El _bandwidth_ teórico agregado ronda los **5 Gbit/s** (≈ 600 MB/s) pero el sostenido real con dos discos rotacionales escribiendo simultáneamente cae a **250-300 MB/s** entre los dos. En el peor caso (Borgmatic leyendo `hd2t/services/`, escribiendo a `hd2t/backups/`, mientras Sonarr mueve un fichero pesado a `hd2t/services/sonarr/media/`) se observan picos de `iowait > 30 %` en los cores.

Esto cambia la jerarquía de tuning **respecto a un servidor x86 normal**: en la Pi 5 hay que **proteger el bus USB antes que la CPU**. Por eso:

- `hd5t` (Stash, multimedia voluminoso) y `hd2t` (resto del homelab) están **en discos físicamente distintos**, en puertos USB 3.0 distintos, para que un escaneo de Stash no compita con un backup nocturno de Borgmatic.
- Borgmatic corre con `Nice=15` e `IOSchedulingClass=idle` (`docs/07-backups/02-borgmatic.md`): cualquier I/O legítimo del homelab desplaza al backup, no al revés.
- Stash sólo se respalda en categoría D (no se respalda; reconstruible — `docs/07-backups/01-estrategia-backup.md`), precisamente para que su tráfico no sature el bus durante el _window_ de backup.

Cuando este doc habla de "rendimiento de la Pi 5", el primer reflejo del operador debe ser **mirar `iostat`/`iotop`**, no `top`/`htop`.

### La memoria es donde se pelea de verdad

El segundo recurso escaso, después del bus USB, es la **RAM efectiva**. Con el _stack_ entero de las fases 2-12 desplegado y "respirando" (sin escaneos masivos en marcha) se observa empíricamente:

| Categoría                                          | Idle aprox. | Pico aprox. | Notas                                                                         |
|----------------------------------------------------|-------------|-------------|-------------------------------------------------------------------------------|
| Sistema (kernel, journald, dockerd, ssh, fail2ban) | 350-500 MB  | 600 MB      | Crece con `journald` si se olvida `SystemMaxUse=`.                            |
| Pi-hole + Unbound (macvlan)                        | 80-120 MB   | 150 MB      | Estable.                                                                      |
| Caddy + Authelia + Tailscale                       | 100-150 MB  | 200 MB      | Caddy reserva _buffers_ por _vhost_; Authelia es Go, ~50-80 MB cada uno.      |
| Prometheus + Grafana + cAdvisor + Node Exporter    | 400-600 MB  | 800 MB      | Prometheus es el más glotón; depende de retención y de `--query.max-samples`. |
| Nextcloud (PHP-FPM + MariaDB + Redis)              | 600-900 MB  | 1.5-2 GB    | El caso _real_ que justifica `mem_limit` cuando hay carga concurrente.        |
| Jellyfin (idle)                                    | 300-500 MB  | 1 GB        | Crece linealmente con la biblioteca durante un _full scan_.                   |
| Stash                                              | 300-500 MB  | 1.5 GB      | _Phash_/_thumbnail generation_ son costosos.                                  |
| Home Assistant + Mosquitto + Z2M + Node-RED        | 400-700 MB  | 1 GB        | Crece con número de integraciones y entidades.                                |
| Servicios productividad (Vaultwarden, Bookstack, Linkding, Paperless, Mealie, Stirling, FreshRSS) | 600-900 MB | 1.5 GB | Paperless picos durante _consume_/_OCR_; Bookstack picos en _search reindex_. |
| Servicios *arr (Sonarr, Radarr, Prowlarr, Transmission) | 250-400 MB | 500 MB | Sonarr/Radarr son .NET — _GC_ devuelve memoria con retraso.                   |
| Multimedia secundario (Navidrome, Audiobookshelf, Calibre-Web) | 150-300 MB | 500 MB | Picos durante escaneo.                                                        |
| Dashboards (Homepage, Homarr) + Dozzle + Uptime Kuma | 200-300 MB | 400 MB | Estables.                                                                     |

Suma estable de "todo en idle": **~3.5-4.5 GB**. Suma con varios servicios en pico simultáneo: **6-7 GB**. Margen para el _page cache_ del kernel (que mejora _todo_ el I/O del sistema): los **1-2 GB restantes**. La conclusión operativa es:

- En condiciones normales, hay holgura. Aplicar `mem_limit` a Nextcloud o Jellyfin _antes_ de tener evidencia de presión es contraproducente: corta el `RSS` justo cuando el servicio lo necesita y dispara OOM kill.
- Cuando dos picos coinciden en el tiempo (escaneo Stash + escaneo Jellyfin + Borgmatic + un _full reindex_ de Bookstack), la RAM disponible cae a ~500 MB y el kernel empieza a recortar el _page cache_. Es el momento de aplicar `mem_limit` **al servicio que se descontroló**, no a todos.
- La _swap_ de `hd2t` (`docs/01-sistema/02-configuracion-inicial.md`) está **para emergencias**, no como amortiguador habitual: con `vm.swappiness=10`, Linux la usa sólo cuando MemAvailable < ~5 % durante segundos. Si la _swap_ crece sostenidamente más de unos cientos de MB, hay un servicio mal dimensionado.

### CPU: la Pi 5 sobra para un homelab — siempre que no se transcodifique

Cuatro cores Cortex-A76 a 2.4 GHz (≈ 2× el rendimiento _per core_ de una Pi 4) son más de lo necesario para el _stack_ entero **mientras nadie haga _video transcoding_ por software**. La GPU VideoCore VII todavía no tiene un _path_ VAAPI estable en `mesa` para Jellyfin (estado en `docs/09-multimedia/01-jellyfin.md`), así que cualquier _transcode_ activo recae en CPU al 100 %. Implicaciones:

- En operación normal, el `load average` típico de la Pi se mantiene < 1.5 (sobre 4 cores).
- Picos a _load average_ 4-6 son aceptables si duran minutos (escaneos, OCR, _phash_).
- _Load average_ sostenido > 6 (CPU saturada y procesos esperando) durante **más de 30 min** es la señal de que algo está mal — habitualmente un _transcode_ olvidado, un _bug_ en un escaneo o un cron del invitado descontrolado.

Por eso el `mem_limit` es la herramienta de tuning **principal** en este homelab y `cpus` es la **excepcional**: una CPU saturada se nota a los pocos segundos en cualquier _dashboard_; una RAM saturada se cuela durante horas si nadie la vigila.

### Overclocking: no por defecto

La Pi 5 **se puede overclockear** vía `/boot/firmware/config.txt`, hasta valores comúnmente reportados de `arm_freq=2700-3000` con `over_voltage_delta=20000-50000` y un cooler activo decente. **Este homelab no overclockea**, por las siguientes razones:

1. **No hay justificación funcional**: ningún servicio del catálogo `SERVICES.md` se beneficia notablemente de pasar de 2.4 a 2.7 GHz. Ni Jellyfin (limitado por la falta de _hardware decode_, no por GHz), ni Nextcloud (limitado por I/O y BD), ni Home Assistant (limitado por integraciones, no por CPU).
2. **Coste térmico desproporcionado**: cada 100 MHz extra significan ~3-5 °C más en sostenido. Un homelab que ya está en 70 °C de fondo se acerca al _throttling_ con el _overclock_ aplicado.
3. **Variabilidad de _binning_**: dos Pis 5 del mismo lote pueden aceptar `arm_freq=2700` con voltage default y otra **necesitar** `over_voltage_delta=20000` para no _crashear_. Esto exige un _stress test_ por unidad, y obliga a recordarlo durante un DR (`docs/13-operaciones/02-disaster-recovery.md`) — añadir esa carga cognitiva no compensa.
4. **Disciplina de soporte**: cualquier _crash_ misterioso en una Pi overclockeada exige descartar primero la inestabilidad del _overclock_. Un _stack_ tan grande como este no quiere variables de confusión.

> **Excepción documentada**: si en algún momento una versión futura de Jellyfin (con `mesa` VAAPI estable en V3D) o un servicio _self-hosted AI_ (Ollama, etc.) justifica el _overclock_, este doc define en la sección _Overclocking conservador_ la receta exacta y los criterios de aceptación. Hasta que llegue ese caso, la decisión por defecto es **stock**.

### `force_turbo=1`, `over_voltage_delta` agresivo y `arm_boost`: no

Hay tres _knobs_ del firmware que **el homelab no toca jamás** y que conviene listar para que ningún tutorial de internet los suba al `config.txt`:

- **`force_turbo=1`**: fuerza la frecuencia máxima permanentemente. Convierte el SoC en una sauna y dispara el desgaste del _silicon_. Anula cualquier _throttling_ térmico de seguridad.
- **`over_voltage_delta` > `25000`**: sube el _Vcore_ de forma agresiva. Más temperatura, más corriente, más estrés en el VRM. Sin un cooler de gama alta y monitorización de temperatura del propio VRM (que la Pi 5 no expone bien), es jugar a la ruleta.
- **`arm_boost=1`** (Pi 4 legacy): no aplica a Pi 5; ignorar.

### `swappiness=10` y `vm.vfs_cache_pressure=50`

Los dos sysctls heredados de `docs/01-sistema/02-configuracion-inicial.md` se asumen activos y son la base del comportamiento de memoria del homelab. Conviene reafirmarlos aquí:

- `vm.swappiness=10`: Linux prefiere descartar _page cache_ antes que enviar páginas a `hd2t/system/swap/swapfile`. Es lo correcto para un homelab donde la _swap_ está en disco USB.
- `vm.vfs_cache_pressure=50`: el kernel retiene _inode/dentry cache_ con más insistencia. En un sistema con muchos ficheros pequeños (Nextcloud, Stash, Paperless), esto reduce I/O sintomático.

Si en el _troubleshooting_ se observa _swap_ creciendo de forma anómala, **antes** de subir el _swappiness_ o desactivar la _swap_, hay que entender qué proceso está pidiendo la RAM. La _swap_ es el síntoma, no la enfermedad.

### Listas de comprobación, no _runbooks_ de tuning

Como en `docs/13-operaciones/01-mantenimiento-periodico.md`, la unidad de trabajo de este doc es la **comprobación corta**, no el _runbook_ enciclopédico. Una lista de 6-10 puntos se sigue; un _runbook_ de 40 _knobs_ se ignora. Cuando un punto necesita más detalle (ej. "comprobar _undervoltage_ histórico"), se delega al comando concreto y al doc enlazado.

---

## Las seis métricas que importan

Cada vez que un operador entra al homelab a investigar rendimiento, debe poder responder a estas seis preguntas en menos de cinco minutos. Las demás métricas (red, IOPS desglosados, _ksoftirq_, IRQ por core, etc.) son interesantes pero secundarias.

### 1. Temperatura del SoC

```bash
vcgencmd measure_temp
# temp=58.3'C
```

| Rango        | Diagnóstico                                                                                       |
|--------------|---------------------------------------------------------------------------------------------------|
| < 60 °C      | Idle perfecto. Carcasa con cooler bien dimensionada.                                              |
| 60-75 °C     | Carga normal (escaneos, picos de servicios). Sin acción.                                          |
| 75-80 °C     | Banda amarilla. Investigar carga sostenida; esperable durante un _full scan_ de Stash.            |
| 80-85 °C     | _Soft throttling_ activo. La frecuencia ARM baja automáticamente. **Anotar en bitácora**.        |
| > 85 °C      | _Hard throttling_. Si dura más de unos minutos, hay un fallo de refrigeración (polvo, ventilador detenido, carcasa cerrada). Parar carga, ventilar, investigar. |

### 2. _Throttling_ histórico desde el último arranque

```bash
vcgencmd get_throttled
# throttled=0x0
```

El valor es un _bitmask_. Los bits relevantes:

| Bit       | Significado                          |
|-----------|--------------------------------------|
| `0x1`     | Under-voltage detectado **ahora**    |
| `0x2`     | ARM frequency capped **ahora**       |
| `0x4`     | _Currently throttled_                |
| `0x8`     | _Soft temp limit_ activo **ahora**   |
| `0x10000` | Under-voltage **ocurrió** desde boot |
| `0x20000` | ARM frequency capped **ocurrió**     |
| `0x40000` | _Throttling_ **ocurrió**             |
| `0x80000` | _Soft temp limit_ **ocurrió**        |

> **Regla**: cualquier valor distinto de `0x0` se anota en la bitácora del mes (`docs/13-operaciones/01-mantenimiento-periodico.md`). El _bitmask_ se resetea en cada reboot, así que este doc no se fía de "mirarlo cuando el operador pasa por allí" — la **alerta Prometheus** (más abajo) se encarga.

### 3. Frecuencia y voltaje actuales

```bash
vcgencmd measure_clock arm
# frequency(0)=2400000384      # 2.4 GHz, default Pi 5
vcgencmd measure_volts core
# volt=0.7075V
```

Si la frecuencia muestra valores < 2.4 GHz **sin carga ligera evidente**, hay _throttling_ silencioso (térmico o de _undervoltage_). Si el voltaje está en valores anómalos, suele ser síntoma de fuente insuficiente — no debería pasar con la fuente oficial 27 W.

### 4. CPU% y _load average_

```bash
htop
# o, no interactivo:
uptime
# 14:32:07 up 23 days,  3:14,  1 user,  load average: 0.42, 0.55, 0.61
mpstat -P ALL 1 5
```

| `load avg` (1 min) sobre 4 cores | Diagnóstico                                                       |
|----------------------------------|-------------------------------------------------------------------|
| < 1.5                            | Idle / carga normal de fondo.                                     |
| 1.5-3                            | Carga moderada (un escaneo activo, un servicio bajo trabajo).     |
| 3-6                              | Carga alta. Esperable durante OCR Paperless, _phash_ Stash, etc.  |
| > 6 sostenido > 30 min           | Investigación obligatoria. Casi siempre es un _transcode_ activo o un proceso descontrolado. |

### 5. Memoria disponible (no `free`, sino `MemAvailable`)

```bash
free -h
#                total        used        free      shared  buff/cache   available
# Mem:           7.9Gi       4.2Gi       0.5Gi       110Mi       3.2Gi       3.5Gi
# Swap:          4.0Gi          0B       4.0Gi
```

La columna que importa es **`available`** (≈ `MemAvailable` del kernel), no `free`. En Linux, `free` casi siempre es bajo — el _page cache_ ocupa la diferencia, y se libera al instante si alguien la pide. Lo que mide presión real es `MemAvailable`:

| `MemAvailable` (8 GB total) | Diagnóstico                                                            |
|-----------------------------|------------------------------------------------------------------------|
| > 2 GB                      | Holgura. Sin acción.                                                   |
| 1-2 GB                      | Margen estrecho. Aceptable transitorio.                                |
| 500 MB - 1 GB               | Banda amarilla. Vigilar; si dura, identificar el servicio que crece.    |
| < 500 MB                    | Presión real. El kernel está recortando _page cache_ y `swap` empieza. |

### 6. I/O y _iowait_

```bash
iostat -xz 5 3
# %iowait suele ser < 5 % en operación normal.
# Picos > 20 % durante 5 min ya son sospechosos.
sudo iotop -ao -d 5
```

`%iowait` alto sostenido es el síntoma más fiable de saturación del bus USB. Si dos servicios escriben simultáneamente al mismo disco (`hd2t`), `iowait` se dispara y el _load average_ sube sin que la CPU esté realmente ocupada.

---

## Comandos rápidos: el _kit_ de auditoría

Cuando una alerta llega y el operador entra por SSH, este es el orden recomendado de comandos. **No se usan todos** — se usan hasta que aparece la pista.

```bash
# 1. ¿Hay throttling activo o histórico?
vcgencmd measure_temp; vcgencmd get_throttled; vcgencmd measure_clock arm

# 2. ¿Qué proceso/contenedor consume?
htop                       # interactivo, panorámica
docker stats --no-stream   # snapshot de cada contenedor

# 3. ¿Hay presión real de memoria?
free -h
sudo dmesg | grep -iE 'out of memory|killed process' | tail
journalctl -k --since "1 hour ago" | grep -iE 'oom|memory'

# 4. ¿Quién escribe/lee a disco?
iostat -xz 5 3
sudo iotop -ao -d 5

# 5. ¿Quién bloquea la red?
ss -s
sudo nethogs eth0     # apt install nethogs si no está

# 6. ¿Qué dice el log del kernel?
sudo dmesg -T | tail -50
journalctl -k --since "30 min ago" | tail -50

# 7. ¿Qué contenedor concreto?
docker top <nombre>
docker logs --since 30m <nombre> | tail -100
```

> **Regla del operador**: anotar en la bitácora **el comando exacto** que reveló la pista, no sólo la conclusión. La próxima vez se ahorra el paseo por todos los comandos.

---

## Refrigeración: el seguro térmico

### Hardware mínimo aceptado por el homelab

Tres opciones, en orden creciente de capacidad y coste:

| Solución                          | Idle / Carga típica | Carga sostenida | Notas                                                                       |
|-----------------------------------|---------------------|-----------------|-----------------------------------------------------------------------------|
| **Disipador pasivo** (no aceptado) | 65 °C / 78 °C       | _throttling_    | No es opción para este homelab. Se descarta.                                |
| **Active Cooler oficial Pi 5**    | 45 °C / 60 °C       | 70-75 °C        | Lo recomendado. PWM gestionado por el firmware. Silencioso.                 |
| **Carcasa Argon ONE V3 / equivalente** | 42 °C / 58 °C  | 65-70 °C        | Aporta más masa térmica y _shroud_; también gestiona los discos USB.        |

### Configuración del _fan_ del Active Cooler oficial

En Raspberry Pi OS Bookworm y posterior, el ventilador del Active Cooler oficial **se gestiona automáticamente** por el firmware vía device tree. La línea relevante de `/boot/firmware/config.txt`:

```ini
# /boot/firmware/config.txt
[all]
dtparam=cooling_fan=on
```

(Habitualmente ya activa por defecto en imágenes recientes — verificar.) El firmware aplica una curva PWM razonable: el ventilador no arranca por debajo de ~50 °C, y va escalando según la temperatura. Si se quiere una curva más agresiva (arrancar antes), se puede ajustar el _temp soft limit_ — pero rara vez vale la pena: el cooler oficial aguanta el _stack_ entero sin tocar nada.

> **No script externo**: existen proyectos que controlan el _fan_ desde un servicio Python o como contenedor Docker. **No se usan** en este homelab. La curva del firmware es suficiente y eliminar dependencias externas reduce _surface area_ de fallo.

### Comprobaciones de salud térmica

```bash
# Temperatura actual.
vcgencmd measure_temp

# Histórico del último arranque (kernel).
journalctl -k | grep -i 'temp\|thermal' | tail

# Sensores expuestos por hwmon (si lm-sensors detectó algo).
sensors

# Verificar que el cooler está controlado por el firmware:
cat /sys/class/thermal/thermal_zone0/temp     # SoC en miligrados (52345 = 52.3°C)
```

### Cuándo intervenir físicamente

- Si la temperatura idle pasa de los 50 °C "habituales" a 65 °C **sin cambio de carga**, suele ser **polvo** acumulado en el disipador o un ventilador que ha empezado a fallar mecánicamente.
- Si tras una mudanza/limpieza la Pi sube +10 °C respecto a antes, comprobar la **pasta térmica** del Active Cooler (rara vez se degrada en < 2 años, pero un golpe puede levantarlo).
- Si la carcasa cerrada está en un mueble sin ventilación, **sacarla**. Ningún cooler interno compensa una caja sin renovación de aire.

---

## Overclocking conservador (opcional, no por defecto)

Esta sección se incluye **por si en el futuro un servicio lo justifica** (ver _Decisiones de diseño_ → "Overclocking: no por defecto"). Mientras no haya un caso documentado en la bitácora, el homelab corre _stock_.

### Receta conservadora

```ini
# /boot/firmware/config.txt
# === OVERCLOCK CONSERVADOR — sólo si está documentado el motivo ===
arm_freq=2600
# over_voltage_delta NO se sube. El firmware ajusta automáticamente.
# force_turbo NO se activa.
```

Cambios mínimos: subir `arm_freq` de 2400 a 2600 MHz (~+8 %) sin tocar voltaje. La gran mayoría de Pis 5 con cooler activo aceptan este ajuste sin _undervoltage_ ni inestabilidad. Si se necesita más (no debería), la siguiente parada documentada es `arm_freq=2700` con `over_voltage_delta=20000`.

### Procedimiento de validación (obligatorio antes de aceptar)

Cualquier cambio de `arm_freq` se valida con un _stress test_ de 30 minutos antes de considerarlo "estable". Sin esta prueba, un _crash_ aleatorio una semana después es indistinguible de un _bug_ de servicio.

```bash
# Terminal 1 — generar carga
stress-ng --cpu 4 --cpu-method matrixprod --metrics --timeout 30m

# Terminal 2 — vigilar
watch -n2 'echo "TEMP: $(vcgencmd measure_temp)"; \
           echo "THRO: $(vcgencmd get_throttled)"; \
           echo "FREQ: $(vcgencmd measure_clock arm)"'
```

**Criterios de aceptación**:

- Al final de los 30 minutos: `vcgencmd get_throttled` debe seguir siendo `0x0`.
- Temperatura pico < 80 °C.
- `stress-ng` debe terminar sin errores ni _segfaults_.
- Ningún `dmesg | grep -iE 'oops|panic|fail'` nuevo.

Si alguno falla: revertir el cambio (comentar `arm_freq` en `config.txt`, reboot) y **anotar en la bitácora** el síntoma exacto. Subir voltaje no se hace sin entender por qué falla a default.

### Documentar la decisión

Si el _overclock_ se acepta, el _commit_ correspondiente debe quedar registrado:

```bash
sudo sed -i 's/^#arm_freq=.*/arm_freq=2600/' /boot/firmware/config.txt
# o editar manualmente.

# Bitácora
echo "Overclock arm_freq=2600 aplicado el $(date '+%Y-%m-%d') tras stress-ng 30 min OK." \
  >> ~/homelab/docs/journal/$(date +%Y-%m).md
cd ~/homelab && git add docs/journal/ && \
  git commit -m "ops: overclock arm_freq=2600 validado" && git push
```

> **Drift de hardware**: una Pi 5 que aceptaba `arm_freq=2600` en su día puede dejar de aceptarlo dos años más tarde por degradación del _silicon_, polvo o cambio de fuente. La ronda anual (`docs/13-operaciones/01-mantenimiento-periodico.md`) reanaliza el caso: si en el _stress test_ del aniversario aparece _throttling_ que antes no aparecía, revertir.

---

## Priorización: qué se protege, qué cede

El homelab clasifica sus servicios en cuatro categorías de prioridad. La categoría **no es un campo de los `.env`**: es una decisión documentada aquí que se traduce, **cuando hay presión de recursos**, en `mem_limit`, `cpus`, `oom_score_adj` o `nice`/`ionice`.

### Categorías

| Cat | Etiqueta            | Servicios típicos                                                                                                | Política                                                                                          |
|-----|---------------------|------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|
| **A** | Críticos          | Vaultwarden, Authelia, Caddy, Pi-hole, Unbound, Tailscale, Home Assistant, MariaDB/PostgreSQL/Redis (de servicios de cat. A/B) | **Nunca** se les aplica `mem_limit` restrictivo ni `cpus` < 1.0. `oom_score_adj: -500`. Si están bajo presión, el problema se resuelve recortando otros, no a ellos. |
| **B** | Pesados de uso diario | Nextcloud, Jellyfin, Stash, Paperless-ngx, Bookstack                                                          | Aceptan `mem_limit` "generoso" (1.5× pico observado) cuando hay evidencia de presión. `cpus` rara vez. |
| **C** | Reactivos / *arr   | Sonarr, Radarr, Prowlarr, Transmission, Mealie, Linkding, FreshRSS, Stirling, Audiobookshelf, Calibre-Web, Navidrome | `mem_limit` se aplica con holgura sólo si compiten con A/B. Toleran latencia.                     |
| **D** | Background        | Borgmatic, Watchtower, escaneos programados, _gravity update_ de Pi-hole, _self-test_ SMART                       | Corren con `nice`/`ionice` para no perturbar A/B/C. No necesitan `mem_limit`.                     |

### Tabla canónica de _watchpoints_ (RAM por servicio)

Esta tabla se actualiza **a partir de cAdvisor**, no a priori. Cada vez que un servicio supera su _watchpoint_ durante la ronda mensual, se actualiza la tabla y se decide si aplicar `mem_limit`.

| Servicio              | Cat | RSS idle | RSS pico esperado | _Watchpoint_ (alerta) | `mem_limit` recomendado si compite |
|-----------------------|-----|----------|-------------------|-----------------------|-------------------------------------|
| Vaultwarden           | A   | 30-60 MB | 100 MB            | > 200 MB              | nunca                               |
| Authelia              | A   | 50-90 MB | 150 MB            | > 300 MB              | nunca                               |
| Caddy                 | A   | 30-60 MB | 120 MB            | > 250 MB              | nunca                               |
| Pi-hole               | A   | 50-80 MB | 150 MB            | > 250 MB              | nunca                               |
| Unbound               | A   | 20-40 MB | 80 MB             | > 150 MB              | nunca                               |
| Home Assistant        | A   | 250-400 MB | 600 MB          | > 900 MB              | sólo si memoria global crítica      |
| MariaDB               | A   | 200-400 MB | 600 MB          | > 1 GB                | revisar `innodb_buffer_pool_size`   |
| PostgreSQL            | A   | 100-200 MB | 400 MB          | > 800 MB              | revisar `shared_buffers`            |
| Redis                 | A   | 30-80 MB | 150 MB            | > 500 MB              | `maxmemory` en `redis.conf`         |
| Nextcloud (PHP-FPM)   | B   | 300-500 MB | 1-1.5 GB        | > 2 GB                | `mem_limit: 2g`                     |
| Jellyfin              | B   | 300-500 MB | 1 GB              | > 1.5 GB              | `mem_limit: 1500m`                  |
| Stash                 | B   | 300-500 MB | 1.5 GB            | > 2 GB                | `mem_limit: 2g`                     |
| Paperless-ngx         | B   | 250-400 MB | 800 MB            | > 1.2 GB              | `mem_limit: 1g`                     |
| Bookstack             | B   | 200-400 MB | 600 MB            | > 1 GB                | `mem_limit: 1g`                     |
| Sonarr/Radarr         | C   | 150-250 MB | 400 MB           | > 600 MB              | `mem_limit: 600m` (rara vez)        |
| Prowlarr              | C   | 100-150 MB | 250 MB           | > 400 MB              | `mem_limit: 400m`                   |
| Transmission          | C   | 80-120 MB | 250 MB            | > 400 MB              | `mem_limit: 400m`                   |
| Navidrome             | C   | 80-150 MB | 300 MB            | > 500 MB              | `mem_limit: 500m`                   |
| Audiobookshelf        | C   | 150-300 MB | 500 MB            | > 700 MB              | `mem_limit: 700m`                   |
| Mealie                | C   | 200-300 MB | 400 MB            | > 600 MB              | `mem_limit: 600m`                   |
| FreshRSS              | C   | 80-150 MB | 300 MB            | > 500 MB              | `mem_limit: 500m`                   |
| Stirling-PDF          | C   | 200-400 MB | 800 MB            | > 1 GB                | `mem_limit: 1g`                     |
| Linkding              | C   | 100-150 MB | 250 MB            | > 400 MB              | `mem_limit: 400m`                   |
| Calibre-Web           | C   | 100-200 MB | 400 MB            | > 600 MB              | `mem_limit: 600m`                   |
| Prometheus            | A   | 200-400 MB | 600 MB            | > 1 GB                | revisar retención antes que `mem_limit` |
| Grafana               | A   | 100-200 MB | 350 MB            | > 600 MB              | `mem_limit: 600m`                   |
| cAdvisor              | A   | 80-150 MB | 250 MB            | > 400 MB              | `mem_limit: 400m`                   |
| Node Exporter         | A   | 20-40 MB | 60 MB             | > 100 MB              | nunca                               |
| Uptime Kuma           | A   | 80-120 MB | 200 MB            | > 350 MB              | `mem_limit: 350m`                   |

> **Cómo se usa esta tabla**: cuando una alerta de Prometheus dispara (RAM contenedor > _watchpoint_ durante 1 h), el operador busca el servicio en la tabla y aplica el `mem_limit` recomendado en su `~/homelab/<stack>/docker-compose.yml`. **No** se aplican los límites preventivamente. Los _watchpoints_ son el resultado de meses de cAdvisor: se ajustan a la baja cuando un servicio se demuestra más estable y al alza cuando un servicio crece de forma legítima (ej. Nextcloud al crecer la base de datos de usuarios).

### Aplicar `mem_limit` con seguridad

Receta canónica para añadir un límite a un servicio existente:

```yaml
# ~/homelab/<stack>/docker-compose.yml
services:
  jellyfin:
    image: jellyfin/jellyfin:${JELLYFIN_IMAGE_TAG}
    # ... resto de la config ...
    mem_limit: 1500m              # hard cap. Excederlo → OOM kill del contenedor.
    mem_reservation: 1g           # soft hint para el scheduler. Opcional.
    oom_score_adj: 200            # más matable que el default (0). Sólo cat. C/D.
```

Validación tras aplicar:

```bash
make pull STACK=multimedia      # si hubo bump de imagen
make up STACK=multimedia
docker stats --no-stream jellyfin
docker exec jellyfin cat /sys/fs/cgroup/memory.max
# Debe mostrar 1572864000 (1500m) o el valor en bytes equivalente.
```

> **OJO con MariaDB/PostgreSQL**: el `mem_limit` corta el RSS del proceso, **no** el _shared buffer_ que la BD pidió internamente. Si la BD tiene `innodb_buffer_pool_size=512m` y el contenedor tiene `mem_limit: 600m`, no hay margen para conexiones concurrentes y la BD puede ser OOM-killed bajo carga. **Ajustar primero la configuración interna de la BD**, no el `mem_limit` del contenedor.

### Aplicar `cpus` (raramente necesario)

```yaml
services:
  paperless-ngx:
    cpus: "2.0"     # 2 cores como techo. La Pi 5 tiene 4.
```

Sólo se usa cuando un servicio en cat. C/D realiza un trabajo en _foreground_ y bloquea cores enteros (OCR de Paperless en una rampa de _consume_ con muchos PDFs, _full reindex_ de Bookstack tras un bump). En el homelab típico, `cpus` ha aparecido cero veces — está documentado por completitud.

### `nice` e `ionice` para servicios de fondo

Borgmatic ya viene configurado en `docs/07-backups/02-borgmatic.md` con:

```ini
# /etc/systemd/system/borgmatic.service.d/override.conf
[Service]
Nice=15
IOSchedulingClass=idle
IOSchedulingPriority=7
```

Aplicar el mismo patrón a otros servicios de fondo es trivial. Para un contenedor Docker que actúa como _job_ programado:

```yaml
services:
  scheduled-job:
    # ...
    cpu_shares: 256          # default 1024; menos peso en el scheduler.
    blkio_config:
      weight: 100            # default 500.
```

> **Regla**: cualquier ajuste a un servicio se acompaña de una entrada en la bitácora con la **fecha**, el **motivo medible** ("RAM > 1.8 GB durante 4 h el 2026-04-13 según cAdvisor") y el **resultado esperado** ("limitar a 1.5 GB; si OOM-kill > 1×/semana, revisar al alza"). Sin esto, dentro de seis meses nadie sabrá por qué Jellyfin tiene `mem_limit: 1500m` y la siguiente ronda lo quitará "porque parecía arbitrario".

---

## I/O y discos: el cuello de botella real

### Diagnóstico inicial

```bash
iostat -xz 2 5
# Columnas a mirar:
# %util — cuán saturado está el dispositivo (>80% sostenido = saturado)
# r_await / w_await — latencia (>20 ms en HDD = bajo carga; >100 ms = sufriendo)
# rkB/s, wkB/s — throughput
```

```bash
sudo iotop -ao -d 5
# Acumulado por proceso. Identifica al culpable real.
# Mirar especialmente DISK READ y DISK WRITE en MB acumulados.
```

### Patrones típicos y su mitigación

| Síntoma                                                                | Causa probable                                                | Mitigación                                                                                              |
|------------------------------------------------------------------------|---------------------------------------------------------------|---------------------------------------------------------------------------------------------------------|
| `%util` de `hd2t` al 95 %, `%iowait` > 30 %, todo lentísimo, ~03:30 AM | Borgmatic respaldando + Watchtower haciendo _pulls_ (raro)    | Confirmar `Nice=15`/`IOSchedulingClass=idle` en `borgmatic.service`. Mover Watchtower fuera de 03:30.    |
| `hd5t` al 95 % en _full library scan_ de Stash, todo el resto va lento | Escaneo de Stash                                              | Stash está en `hd5t` precisamente para que no toque a `hd2t`. Si afecta servicios `hd2t`, revisar `iotop` — puede ser un proceso _kernel_ (`kworker`) o un _bind mount_ mal configurado. |
| `%iowait` alto pero `iostat` no muestra `%util` alto                   | Saturación del bus USB controller, no del disco               | Desconectar uno de los dos discos durante el test. Si `%iowait` baja, es el bus.                        |
| Sonarr/Radarr renombrando ficheros lentísimos                          | _Hardlink_ no soportado entre el FS de Transmission y Sonarr  | Confirmar que ambos viven en el mismo FS (`hd2t`) y que las rutas están alineadas (`docs/10-descargas/`). |
| `journald` saturando IO con `flush` constantes                         | _Logs_ de Docker mal rotados                                  | Revisar `daemon.json` del Docker Engine: `log-opts.max-size=10m`, `log-opts.max-file=3` (`docs/02-docker/01-instalacion-docker.md`). |
| `hd5t` o `hd2t` se desconecta espontáneamente bajo carga               | Power management USB, fuente insuficiente, _hub_ no alimentado | Aplicar `usb-storage.quirks=...` si fuera necesario; verificar que la fuente es la 27 W oficial; eliminar _hub_ pasivo intermedio. |

### Confirmar que el bus USB es el bottleneck (test sintético)

```bash
# Test concurrente — cuidado: usa espacio temporal.
sudo dd if=/dev/zero of=/mnt/hd2t/system/iotest.bin bs=1M count=2048 conv=fdatasync &
sudo dd if=/dev/zero of=/mnt/hd5t/iotest.bin bs=1M count=2048 conv=fdatasync &
wait
sudo rm -f /mnt/hd2t/system/iotest.bin /mnt/hd5t/iotest.bin
```

Las dos tasas combinadas no deberían superar **~250-300 MB/s** sostenidos. Si una sola tasa va a > 200 MB/s pero la combinada cae a < 150 MB/s + 150 MB/s, el bus está saturado. Es **normal en Pi 5**, no es un bug; es el motivo por el que el homelab nunca programa dos operaciones pesadas de I/O simultáneas en el mismo intervalo.

---

## Alertas Prometheus mínimas

Las alertas se configuran en `docs/05-monitorizacion/01-prometheus.md`. Las mínimas que este doc considera obligatorias para que el operador tenga datos antes de que algo se rompa:

```yaml
# /etc/prometheus/rules.d/pi5-perf.yml
groups:
  - name: pi5-rendimiento
    interval: 30s
    rules:
      - alert: Pi5TempHigh
        expr: node_hwmon_temp_celsius{chip="thermal-thermal_zone0"} > 78
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "CPU > 78 °C durante 10 min"
          runbook: "docs/13-operaciones/03-rendimiento-pi5.md → Refrigeración"

      - alert: Pi5TempCritical
        expr: node_hwmon_temp_celsius{chip="thermal-thermal_zone0"} > 82
        for: 2m
        labels: { severity: critical }
        annotations:
          summary: "CPU > 82 °C — throttling activo"

      - alert: Pi5Throttled
        # node_exporter expone vcgencmd via textfile collector
        # (script periódico en /var/lib/node_exporter/textfile/throttled.prom).
        expr: rpi_throttled_status != 0
        for: 1m
        labels: { severity: warning }
        annotations:
          summary: "vcgencmd get_throttled != 0"

      - alert: Pi5MemAvailableLow
        expr: (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 < 10
        for: 30m
        labels: { severity: warning }
        annotations:
          summary: "MemAvailable < 10 % durante 30 min"

      - alert: Pi5SwapInUse
        expr: (node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes) > 500e6
        for: 1h
        labels: { severity: warning }
        annotations:
          summary: "Swap > 500 MB durante 1 h"

      - alert: Pi5LoadHigh
        expr: node_load5 > 6
        for: 30m
        labels: { severity: warning }
        annotations:
          summary: "load5 > 6 durante 30 min"

      - alert: Pi5IOWaitHigh
        expr: avg by () (rate(node_cpu_seconds_total{mode="iowait"}[5m])) * 100 > 25
        for: 30m
        labels: { severity: warning }
        annotations:
          summary: "%iowait promedio > 25 % durante 30 min"

      - alert: ContainerMemoryHigh
        # Por contenedor — comparar contra los watchpoints de la tabla canónica.
        expr: (container_memory_working_set_bytes{name!=""} / 1024 / 1024) > 1500
        for: 1h
        labels: { severity: info }
        annotations:
          summary: "Contenedor {{ $labels.name }} con RSS > 1500 MB durante 1 h"
          runbook: "docs/13-operaciones/03-rendimiento-pi5.md → Tabla canónica de watchpoints"
```

> **Sobre `rpi_throttled_status`**: `vcgencmd get_throttled` no es exportado nativamente por `node_exporter`. Se exporta vía _textfile collector_ con un script auxiliar simple en cron cada minuto (`echo "rpi_throttled_status $(vcgencmd get_throttled | grep -oE '0x[0-9a-f]+' | head -1)" > /var/lib/node_exporter/textfile/throttled.prom`). El detalle vive en `docs/05-monitorizacion/03-node-exporter.md`.

### Dashboards Grafana de referencia

Tres dashboards específicos, además de los genéricos del homelab:

- **"Pi 5 Termal"**: temperatura SoC, frecuencia ARM, voltaje core, _throttling bitmask_ histórico. Una sola fila, suficiente para la ronda mensual.
- **"Pi 5 I/O"**: `iostat`-style con `%util`, `r_await`, `w_await`, `rkB/s`, `wkB/s` por dispositivo (`hd5t`, `hd2t`, `mmcblk0`).
- **"Containers Top RSS"**: top 10 contenedores por `container_memory_working_set_bytes` con _heatmap_ del último mes. Al cruzarlo con la tabla canónica, el _drift_ se detecta de un vistazo.

---

## Procedimiento de auditoría de rendimiento

Cuando una alerta dispara o el operador detecta lentitud subjetiva, esta es la rutina **estándar**, en orden, sin saltos.

### 1. _Triage_ (5 min, sin tocar nada)

```markdown
## Triage de rendimiento — YYYY-MM-DD HH:MM

- [ ] **¿Qué alerta o síntoma detonó esto?**
      Anotar literal: nombre de la alerta Prometheus, métrica, _firing since_; o descripción del síntoma subjetivo.
- [ ] **¿Es un episodio puntual o recurrente?**
      Cruzar con bitácora (`docs/13-operaciones/01-mantenimiento-periodico.md`): ¿pasó algo similar el mes pasado?
- [ ] **¿Coincide con un evento conocido?**
      Backup nocturno, _full scan_ de Stash, OCR masivo de Paperless, despliegue reciente, _bump_ de imagen.
- [ ] **¿Quién está afectado?**
      Sólo un servicio (probable problema interno), todos los servicios (probable host: CPU/RAM/IO/red), familia (afecta UX visible).
- [ ] **¿Hay riesgo de empeorar si se actúa rápido?**
      Si está en mitad de un OCR de 2 h, cortarlo puede dejar el _consume_ a medias. Si la BD está en _checkpoint_, kill abrupto puede corromper.
```

### 2. Identificar el recurso saturado (5-10 min)

Recorrer las **seis métricas que importan** (sección homónima) en este orden:

1. `vcgencmd measure_temp; vcgencmd get_throttled` → ¿térmico?
2. `htop` + `uptime` → ¿CPU?
3. `free -h` + `dmesg | grep -i oom` → ¿memoria?
4. `iostat -xz 5 3` + `iotop -ao -d 5` → ¿I/O?
5. Si nada de lo anterior salta: red (`ss`, `nethogs`).

### 3. Identificar al servicio o proceso culpable (5 min)

```bash
docker stats --no-stream | sort -k4 -h    # ordenar por mem
docker stats --no-stream | sort -k3 -h    # ordenar por cpu
sudo iotop -ao | head -20
```

Cruzar contra la **tabla canónica de _watchpoints_**: ¿está el servicio fuera de su rango esperado?

### 4. Decidir tipo de intervención (decisión)

| Tipo                              | Cuándo                                                                              | Acción                                                                                  |
|-----------------------------------|-------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|
| _Watchful waiting_                | Pico transitorio coincidente con evento legítimo (escaneo, OCR, reindex).           | Anotar y observar. No tocar. Cerrar incidente al volver a normal.                       |
| _Apply mem_limit_ al servicio     | Pico sostenido > 1 h y > _watchpoint_ con otros servicios sufriendo.                | Editar `docker-compose.yml`; `mem_limit` ≈ 1.5× pico observado; commit; observar 24 h.  |
| _Apply cpus_ al servicio          | Servicio bloqueando cores enteros y desplazando a categoría A.                       | `cpus: "2.0"` o similar; commit; observar.                                              |
| _Tunear configuración interna_    | El _bottleneck_ está dentro del servicio (Redis sin `maxmemory`, MariaDB con _buffer pool_ desproporcionado). | Editar config del servicio; doc específico del servicio.                                |
| _Mover el servicio_               | Mismo disco saturado por dos cargas simultáneas evitables (ej. Borgmatic + scan).   | Reprogramar uno de los dos. Suele ser ajuste de `cron` o de `borgmatic` _hooks_.        |
| _Hardware_                        | Bus USB saturado de forma estructural (raro en este homelab).                        | Considerar PCIe HAT con NVMe para el `hd2t`. Decisión grande, no en caliente.            |

### 5. Aplicar **el cambio mínimo** (15-30 min)

Editar el `docker-compose.yml` o el `.env` correspondiente, hacer `make up STACK=<nombre>`, validar que el servicio sigue arriba (`make ps STACK=<nombre>`, _healthcheck_ pasa, abrir UI).

### 6. Validar 24 h (silencio)

Esperar al menos un ciclo diario completo. La métrica que disparaba la alerta debe volver al rango normal **y** ningún OOM-kill ni síntoma nuevo debe aparecer en `journalctl -k --since "24 hours ago"`.

### 7. Documentar la decisión

```bash
cat >> ~/homelab/docs/journal/$(date +%Y-%m).md <<EOF
## Ajuste de rendimiento — $(date '+%Y-%m-%d %H:%M')

- Alerta detonante: \`Pi5MemAvailableLow firing 2h\` el 2026-04-15 13:42.
- Causa: Jellyfin RSS = 1.85 GB durante full scan + Nextcloud RSS = 1.4 GB simultáneos.
- Cambio: \`mem_limit: 1500m\` añadido a Jellyfin (compose: ~/homelab/multimedia/docker-compose.yml).
- Validación: 26 h sin recurrencia; cAdvisor muestra Jellyfin oscilando entre 1.1-1.4 GB.
- Pendiente: revisar próximo full scan (programado mensual, día 1) sin que el cap dispare OOM.
EOF
cd ~/homelab && git add docs/journal/ <stack>/docker-compose.yml && \
  git commit -m "ops(perf): mem_limit Jellyfin 1500m tras presión RAM 2026-04-15" && git push
```

---

## Troubleshooting

### `vcgencmd get_throttled` muestra `0x50000` y nada parece pasar

`0x50000` = `0x10000 | 0x40000` = "_undervoltage_ ocurrido" + "_throttling_ ocurrido" desde el último arranque. El _bitmask_ es **histórico**, no actual; tras un reboot vuelve a `0x0`. Causas frecuentes:

- Fuente no oficial (cualquier cargador de teléfono — la Pi 5 exige PD 5 V/5 A o equivalente). Sustituir por la fuente 27 W oficial.
- Cable USB-C de mala calidad o muy largo. Cambiar.
- _Hub_ pasivo entre la fuente y la Pi (insólito pero ocurre). Conectar directo.
- Si tras corregir las tres cosas reaparece: la propia fuente puede estar degradada (años, golpes). Probar otra Pi 5 conocida con la misma fuente y ver si reproduce.

### OOM-kill recurrente del mismo contenedor

```bash
sudo dmesg -T | grep -iE 'killed process'
journalctl -k --since "7 days ago" | grep -iE 'oom|killed' | tail -50
```

Identificar el contenedor (`Killed process 12345 (xxx)`). Posibilidades:

- `mem_limit` demasiado bajo respecto al uso real → subirlo (consultar `cAdvisor` para el _peak_).
- _Memory leak_ del servicio → reportar _upstream_, mientras tanto programar `docker compose restart <servicio>` semanal.
- Configuración interna del servicio glotona (_Redis_ sin `maxmemory`, _MariaDB_ con `innodb_buffer_pool_size` mayor que el `mem_limit` del contenedor). Ajustar la configuración interna **antes** de subir el cap.
- Sólo en cat. C/D: si el OOM-kill no afecta UX, **es trabajo bien hecho** del cgroup. Aceptar y documentar.

### "RAM al 95 % en `htop` pero todo va bien"

`htop` cuenta el _page cache_ como "usado" en su barra por defecto. Pulsar `s` (Setup) → _Meters_ → editar la barra de _Memory_ y activar "Memory bar mode = Detailed" para ver _used_, _buffers_, _cached_, _shared_. Lo que importa es `MemAvailable`, no la barra global.

### Swap creciendo lentamente día a día

```bash
free -h
sudo smem -tk
sudo swapon --show
```

Si la _swap_ pasa de unos cientos de MB sin recuperarse tras 24 h, **algún servicio tiene _memory leak_**. Identificarlo cruzando `cAdvisor` (RSS por contenedor en serie temporal). Posibilidades habituales: Sonarr/Radarr con _GC_ del .NET retrasado (esperable hasta cierto punto, agresivo si crece sin techo), Home Assistant con un _custom integration_ con _leak_, Stash en escaneo continuo. Mitigación corta: `docker compose restart <servicio>` programado semanal. Mitigación larga: reportar/actualizar.

### Los discos USB se desconectan bajo carga

```bash
dmesg -T | grep -iE 'usb|hd5t|hd2t' | tail -50
```

Buscar `disconnect`, `reset SuperSpeed`, `over-current`. Soluciones por orden de probabilidad:

1. **Fuente insuficiente** o cable USB-C de baja calidad → fuente 27 W oficial, cable corto y certificado.
2. **Cable USB del disco** flojo o de calidad → sustituir.
3. **Disco de USB-bus-powered** que pide mucho en _spin-up_ → usar uno con alimentación externa, especialmente para `hd5t` (5 TB).
4. **_Quirk_ de chipset** del disco → añadir a `/etc/default/grub` o `cmdline.txt`: `usb-storage.quirks=<vid>:<pid>:u` (UAS off para ese modelo). Documentado en `docs/00-hardware/03-preparacion-discos.md`.

### Zigbee2MQTT pierde dispositivos cuando hay tráfico WiFi alto

Conflicto Zigbee (2.4 GHz canal 11-25) ↔ WiFi (2.4 GHz canales 1-13). Mitigaciones:

- Mover el adaptador Zigbee a un alargador USB para alejarlo de la Pi (la propia Pi 5 emite ruido en 2.4 GHz).
- Cambiar el canal Zigbee en Z2M (`docs/08-domotica/03-zigbee2mqtt.md`) a uno alejado del WiFi del router (si WiFi está en canal 6, usar Zigbee canal 25).
- Ethernet siempre — nunca operar la Pi en WiFi.

### El homelab estaba fluido y de repente "todo lento" sin causa aparente

```bash
sudo dmesg -T | tail -200
journalctl --since "1 hour ago" -p warning --no-pager | tail
sudo nft list ruleset | head
```

Causas históricas detectadas en este tipo de homelab:

- `fail2ban` con un _ruleset_ enorme (miles de IPs) por un ataque sostenido → `nftables` degradado; pasar las IPs persistentes a un `set` permanente o a `nft drop` en /16 (`docs/13-operaciones/04-red-y-puertos.md`).
- Contenedor con _restart loop_ silencioso pegándole al _engine_ → `docker ps` y revisar columna `STATUS`.
- microSD muriendo y errores I/O del rootfs → `dmesg | grep -iE 'mmcblk|i/o error'`. Si aparece, planificar DR (`docs/13-operaciones/02-disaster-recovery.md`) en cuanto sea posible.

---

## Verificación final (cierre de la fase 13.3)

Antes de dar la fase 13.3 por cerrada, ejecutar **una vez** el procedimiento de auditoría sobre el homelab actual (incluso si nada está alertando), para validar que las herramientas funcionan y que las métricas reportan lo esperado.

- [ ] La carcasa con cooler activo está montada y `vcgencmd measure_temp` en idle reporta < 60 °C en la sala donde vivirá la Pi.
- [ ] `vcgencmd get_throttled` reporta `0x0` tras 24 h de uso normal sin eventos extraordinarios. Si reporta otro valor, investigar y resolver **antes** de cerrar la fase.
- [ ] El _swap_ está en `/mnt/hd2t/system/swap/swapfile` (no en microSD), `swapon --show` lo confirma, `vm.swappiness=10` está aplicado.
- [ ] Las alertas Prometheus mínimas (`Pi5TempHigh`, `Pi5TempCritical`, `Pi5Throttled`, `Pi5MemAvailableLow`, `Pi5SwapInUse`, `Pi5LoadHigh`, `Pi5IOWaitHigh`, `ContainerMemoryHigh`) están definidas en `prometheus/rules.d/pi5-perf.yml` y `amtool check-rules` no devuelve errores.
- [ ] El _textfile collector_ exportando `rpi_throttled_status` está en su sitio, el script auxiliar corre por cron cada minuto, y la alerta `Pi5Throttled` aparece en Grafana → _Alerting_ con estado `OK`.
- [ ] Los tres dashboards Grafana ("Pi 5 Termal", "Pi 5 I/O", "Containers Top RSS") están desplegados y muestran datos del último día.
- [ ] La **tabla canónica de _watchpoints_** se ha cotejado con cAdvisor a 24 h vista: cada servicio desplegado está en su rango _Idle_ esperado o el rango se ha actualizado en este doc (si el rango cambia, _commit_ del cambio).
- [ ] Se ha ejecutado un _stress test_ de 30 min con `stress-ng --cpu 4 --cpu-method matrixprod` con el cooler oficial montado: `vcgencmd get_throttled` permanece `0x0` y la temperatura pico < 80 °C. Anotar el _peak_ en bitácora.
- [ ] **No** se ha aplicado ningún `mem_limit` ni `cpus` preventivo. La política por defecto es _no limits_; la fase se cierra sin haberlos aplicado.
- [ ] Si se decidió overclockear (caso excepcional, raro), el _stress test_ correspondiente está documentado en bitácora y `arm_freq=` aparece en `/boot/firmware/config.txt` con _commit_ explicativo.
- [ ] La fase 13.3 se cierra con commit:
  ```bash
  cd ~/homelab
  git add docs/13-operaciones/03-rendimiento-pi5.md \
          monitorizacion/prometheus/rules.d/pi5-perf.yml \
          monitorizacion/grafana/dashboards/pi5-*.json \
          docs/journal/
  git commit -m "feat(ops): bootstrap rendimiento Pi 5 (alertas + dashboards + tabla watchpoints)"
  git push
  ```

A partir de aquí, la última sección de la fase 13 (`04-red-y-puertos.md`) cubrirá el mapa de puertos, la configuración del firewall y la coherencia de la superficie de red expuesta — el último _runbook_ del homelab antes de pasar a operación pura.

---

## Referencias

- Raspberry Pi — _Raspberry Pi 5 documentation_: <https://www.raspberrypi.com/documentation/computers/raspberry-pi-5.html>
- Raspberry Pi — _config.txt_ (firmware tuning): <https://www.raspberrypi.com/documentation/computers/config_txt.html>
- Raspberry Pi — _vcgencmd_: <https://www.raspberrypi.com/documentation/computers/os.html#vcgencmd>
- Raspberry Pi Forums — _Pi 5 cooling and overclocking_ (hilo canónico): <https://forums.raspberrypi.com/viewforum.php?f=146>
- Linux kernel — _Memory pressure (PSI)_: <https://docs.kernel.org/accounting/psi.html>
- Linux kernel — _OOM killer & oom_score_adj_: <https://docs.kernel.org/admin-guide/sysctl/vm.html>
- Linux kernel — _swappiness_ y _vfs_cache_pressure_: <https://docs.kernel.org/admin-guide/sysctl/vm.html#swappiness>
- Docker — _Resource constraints_ (`mem_limit`, `cpus`, `oom_score_adj`): <https://docs.docker.com/config/containers/resource_constraints/>
- Docker Compose — _Resources reference_: <https://docs.docker.com/compose/compose-file/deploy/#resources>
- cAdvisor — _Metrics_: <https://github.com/google/cadvisor/blob/master/docs/storage/prometheus.md>
- Prometheus — _Alerting rules_: <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>
- Node Exporter — _Textfile collector_: <https://github.com/prometheus/node_exporter#textfile-collector>
- `stress-ng` — _Manual_: <https://wiki.ubuntu.com/Kernel/Reference/stress-ng>
- `iostat` y `sysstat` — _Manual_: <https://github.com/sysstat/sysstat>
- `iotop` — _Manual_: <http://guichaz.free.fr/iotop/>
- `cpupower` — _Linux CPU frequency scaling_: <https://www.kernel.org/doc/html/latest/admin-guide/pm/cpufreq.html>
