# Rendimiento Pi 5

## Descripción

Este documento define una política de tuning para la **Raspberry Pi 5 (8 GB)** del homelab con foco en **estabilidad 24/7**, no en maximizar benchmarks. El objetivo es mejorar margen operativo bajo carga real sin comprometer:

- acceso interno por **LAN** y **Tailscale**
- integridad del **SSD NVMe** donde viven sistema, Docker y datos persistentes
- estabilidad de los discos USB `hd2t` y `hd5t`
- previsibilidad del consumo de CPU, RAM y temperatura

En este proyecto, optimizar rendimiento significa:

- medir antes de cambiar
- mantener temperaturas sostenidas razonables
- aplicar overclocking solo si la refrigeración y la alimentación lo soportan
- priorizar servicios críticos frente a cargas pesadas de multimedia, scraping o indexado
- fijar límites de memoria y CPU en contenedores propensos a crecer sin control

Regla principal:

- en un homelab 24/7, una configuración **ligeramente más lenta pero estable** vale más que un overclock agresivo

## Requisitos Previos

- Haber completado [02-configuracion-inicial.md](../01-sistema/02-configuracion-inicial.md).
- Haber completado [05-arranque-nvme.md](../00-hardware/05-arranque-nvme.md).
- Haber completado [03-node-exporter.md](../05-monitorizacion/03-node-exporter.md).
- Haber completado [01-mantenimiento-periodico.md](01-mantenimiento-periodico.md).
- Tener refrigeración activa funcional en la carcasa de la Pi 5.
- Usar una fuente de alimentación estable y adecuada para la Pi 5 con **NVMe** y discos USB conectados.
- Tener acceso administrativo por **SSH** o consola local.
- Tener instaladas estas herramientas en el host:
  - `docker`
  - `docker compose`
  - `vcgencmd`
  - `util-linux`
  - `procps`
- Herramientas opcionales recomendadas para pruebas de carga:
  - `stress-ng`
  - `sysstat`

Puertos necesarios en esta fase:

- ninguno adicional a los ya definidos en el proyecto

## Docker Compose

No aplica en este documento. Aquí se define una política de tuning del host y criterios de limitación para stacks ya desplegados.

## Configuración

### 1. Principios de tuning para este homelab

Antes de tocar frecuencia, voltaje o límites de contenedores, fija estos criterios:

1. el sistema debe ser estable a frecuencia stock
2. no debe haber alertas de **undervoltage**
3. la temperatura en carga normal no debe estar ya al borde del throttling
4. los ajustes deben poder revertirse rápido
5. cualquier cambio debe validarse con carga real, no solo con un arranque correcto

Señales de que **no** conviene overclockear todavía:

- `vcgencmd get_throttled` muestra bits de undervoltage o throttling
- el ventilador o la carcasa no están disipando bien
- el sistema ya alcanza temperaturas altas con carga moderada
- los discos USB se reconectan o aparecen errores de I/O
- el host ya depende demasiado de `swap`

### 2. Medir la línea base antes de tocar nada

Registra primero un estado base para poder comparar después:

```bash
date
hostnamectl
uptime
free -h
swapon --show
df -h /
df -h /mnt/hd2t
df -h /mnt/hd5t
vcgencmd measure_temp
vcgencmd get_throttled
vcgencmd measure_clock arm
docker stats --no-stream
```

Si tienes Prometheus y Grafana ya operativos, conviene observar durante varios días:

- temperatura del SoC
- carga media
- uso de memoria
- ritmo de uso de `swap`
- actividad de disco sobre **NVMe**, `hd2t` y `hd5t`

Consultas rápidas útiles en Prometheus o Grafana:

```promql
node_load1
```

```promql
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100
```

```promql
node_memory_SwapUsed_bytes
```

```promql
node_thermal_zone_temp / 1000
```

Si la métrica de temperatura disponible en tu host es `node_hwmon_temp_celsius`, usa esa.

### 3. Objetivos térmicos realistas

La Pi 5 puede trabajar caliente, pero para un host 24/7 conviene dejar margen.

Rangos prácticos recomendados:

| Estado | Temperatura SoC | Lectura operativa |
|--------|------------------|-------------------|
| Ideal | hasta **70 °C** | margen cómodo para uso continuo |
| Aceptable | **70–79 °C** | carga sostenida razonable, pero conviene vigilar |
| Alta | **80–84 °C** | ya existe riesgo real de throttling progresivo |
| Límite | **85 °C** | se activa protección térmica y baja rendimiento |

Reglas prácticas:

- si una carga sostenida deja la Pi en **80 °C** o más, prioriza refrigeración antes que más tuning
- si aparecen eventos históricos de throttling, trata eso como incidencia
- si el host solo está estable con el ventilador siempre al máximo, el margen térmico es escaso

Comprobación rápida durante carga:

```bash
watch -n 2 'vcgencmd measure_temp; vcgencmd get_throttled'
```

Interpretación mínima de `get_throttled`:

- `0x0` es el escenario sano
- cualquier bit de **undervoltage** indica problema de alimentación
- cualquier bit de **throttling** o **frequency capping** indica pérdida real de rendimiento

### 4. Gestión térmica del host

Antes de tocar `config.txt`, optimiza la disipación:

- mantén la carcasa en un lugar ventilado, no dentro de un armario cerrado
- evita apoyar `hd2t` y `hd5t` pegados a la salida de aire caliente
- limpia polvo de ranuras, ventilador y disipadores en la rutina mensual
- usa la fuente recomendada para Pi 5 y evita cables USB-C dudosos
- no añadas overclock si la refrigeración activa de la carcasa falla

Mediciones rápidas útiles:

```bash
vcgencmd measure_temp
vcgencmd get_throttled
sudo smartctl -a /dev/nvme0n1 | grep -Ei 'temperature|temp'
sudo smartctl -a -d sat /dev/sda | grep -Ei 'temperature|temp'
sudo smartctl -a -d sat /dev/sdb | grep -Ei 'temperature|temp'
```

En este homelab interesa vigilar no solo el SoC, sino también:

- temperatura del **NVMe**
- temperatura de las carcasas USB si exponen SMART
- estabilidad del enlace PCIe/NVMe bajo carga y temperatura

### 5. Overclocking conservador

El overclocking debe ser **opcional** y reversible. La configuración preferida para producción sigue siendo frecuencia stock si el sistema ya cumple bien su función.

Solo considera overclock si se cumplen estas condiciones:

- la Pi 5 es estable durante días a valores stock
- no existen flags de undervoltage
- la temperatura habitual bajo carga está claramente por debajo de la zona de throttling
- la carcasa con NVMe refrigera bien

Haz copia de seguridad del fichero antes de tocarlo:

```bash
sudo cp /boot/firmware/config.txt /boot/firmware/config.txt.bak
```

Perfil conservador de partida para probar:

Archivo: `/boot/firmware/config.txt`

```ini
# Tuning conservador para homelab 24/7
arm_freq=2600
temp_limit=80

# Solo si 2600 MHz no es estable y la refrigeración sigue siendo buena:
# over_voltage_delta=25000
```

Qué persigue este perfil:

- subir moderadamente la frecuencia de CPU
- mantener el voltaje por defecto en la primera prueba
- dejar un margen pequeño de voltaje dinámico solo como ajuste posterior si hace falta
- forzar que el sistema vuelva a valores por defecto antes del límite térmico duro

Reglas importantes:

- no combines este cambio con otras modificaciones grandes el mismo día
- no toques a la vez CPU, GPU, PCIe y almacenamiento si no tienes una línea base limpia
- si la Pi ya usa **PCIe/NVMe** y dos discos USB, la estabilidad eléctrica importa más que un extra pequeño de CPU
- si aparece inestabilidad, revierte primero el overclock; no sigas ajustando voltaje a ciegas

Aplica el cambio y reinicia:

```bash
sudo reboot
```

Después valida:

```bash
vcgencmd get_config arm_freq
vcgencmd measure_clock arm
vcgencmd measure_temp
vcgencmd get_throttled
dmesg -T | grep -Ei 'thrott|voltage|nvme|pcie|usb|error'
```

Si tienes `stress-ng`, ejecuta una prueba simple:

```bash
stress-ng --cpu 4 --timeout 10m --metrics-brief
```

Durante la prueba, vigila:

- que no aparezcan bits de undervoltage
- que no haya throttling sostenido
- que el host siga viendo el **NVMe**, `hd2t` y `hd5t` sin errores
- que Docker siga estable y sin reinicios anómalos

Si algo falla, vuelve atrás:

```bash
sudo cp /boot/firmware/config.txt.bak /boot/firmware/config.txt
sudo reboot
```

### 6. Priorización de servicios

En una Pi 5 con 8 GB, el problema más común no es un único servicio pesado, sino varias cargas razonables coincidiendo a la vez:

- backup + compresión
- scraping o indexado
- transcodificación en Jellyfin
- escaneo de bibliotecas
- OCR en Paperless
- actualizaciones Docker

La forma correcta de priorizar es distinguir servicios por criticidad.

#### Nivel 1: acceso e infraestructura base

No conviene degradarlos salvo emergencia:

- `tailscale`
- `caddy`
- `pihole`
- `unbound`
- `authelia`
- base de datos principal si otros servicios dependen de ella

#### Nivel 2: estado y aplicaciones diarias

Deben seguir siendo estables, pero pueden llevar límites más estrictos:

- `vaultwarden`
- `mealie`
- `paperless`
- `grafana`
- `prometheus`
- `linkding`
- `freshrss`

#### Nivel 3: cargas pesadas o aplazables

Son los primeros candidatos a limitar, pausar o mover de horario:

- `jellyfin` durante transcodificación
- `stash` durante scans o generación de previews
- `sonarr`, `radarr` y `prowlarr` durante indexados grandes
- tareas de mantenimiento intensivas
- restauraciones, checks de backup y migraciones

Regla operativa:

- si el host entra en presión de CPU, RAM o temperatura, reduce primero servicios del **Nivel 3**

Orden práctico de intervención cuando notes degradación:

1. pausar scans pesados o tareas batch
2. detener temporalmente `stash` o recreaciones multimedia grandes
3. posponer backups, `prune` y actualizaciones
4. solo si hace falta, revisar límites de servicios de Nivel 2
5. evitar tocar Nivel 1 salvo incidencia real

### 7. Programación y concurrencia de cargas

Más importante que un overclock pequeño es evitar picos tontos de concurrencia.

Buenas prácticas:

- no lances `borgmatic check`, actualización masiva de imágenes y escaneos multimedia en la misma ventana
- separa en el tiempo transcodificación, indexado y backups
- si **Stash** hace trabajo intensivo sobre `hd5t`, evita coincidir con procesos largos sobre `hd2t`
- si Prometheus, Paperless o una base de datos están escribiendo mucho en el **NVMe**, evita al mismo tiempo tareas de mantenimiento intensivas

La Pi 5 suele responder mejor a:

- menos tareas simultáneas
- límites explícitos en contenedores pesados
- ventanas de mantenimiento planificadas

### 8. Límites de memoria y CPU por contenedor

En este homelab, los límites de contenedor son una herramienta de contención, no de precisión absoluta.

Objetivo:

- evitar que un servicio oportunista consuma toda la RAM
- dejar margen para el host, la caché de disco, Docker y `zram`
- impedir que una carga multimedia o de OCR deteriore servicios críticos

Reglas prácticas:

- empieza con límites conservadores y observa una semana
- no impongas límites extremadamente bajos a bases de datos o aplicaciones Java/.NET sin validarlas
- no sumes límites pensando que esa RAM queda reservada; son topes, no reservas
- aun así, evita declarar límites absurdamente altos en muchos contenedores a la vez

Guía inicial orientativa para una Pi 5 de **8 GB**:

| Perfil | Servicios típicos | `mem_limit` inicial | `cpus` inicial |
|--------|-------------------|---------------------|----------------|
| Muy ligero | `tailscale`, `unbound`, `node-exporter` | `128m`–`256m` | `0.25`–`0.50` |
| Ligero | `caddy`, `linkding`, `freshrss`, `uptime-kuma` | `256m`–`512m` | `0.50`–`1.00` |
| Medio | `authelia`, `grafana`, `vaultwarden`, `calibre-web` | `512m`–`1g` | `0.75`–`1.50` |
| Medio-alto | `mariadb`, `postgres`, `mealie`, `home-assistant` | `512m`–`1g` | `1.00`–`2.00` |
| Alto | `paperless`, `jellyfin`, `stash` | `1g`–`2g` | `1.50`–`3.00` |

Ejemplo práctico en un `docker-compose.yml`:

```yaml
services:
  caddy:
    image: caddy:latest
    restart: unless-stopped
    mem_limit: 256m
    cpus: 0.50

  mealie:
    image: ghcr.io/mealie-recipes/mealie:v3.17.0
    restart: unless-stopped
    mem_limit: 1g
    cpus: 1.00

  jellyfin:
    image: jellyfin/jellyfin:latest
    restart: unless-stopped
    mem_limit: 1500m
    cpus: 2.50
```

Qué debes observar después de aplicar límites:

- si el contenedor empieza a reiniciar por falta de memoria
- si aumentan errores `OOMKilled`
- si el servicio se vuelve demasiado lento en momentos normales
- si el host reduce su uso de swap y recupera margen térmico

Comprobaciones útiles:

```bash
docker stats --no-stream
docker inspect <contenedor> --format '{{json .HostConfig.Memory}} {{json .HostConfig.NanoCpus}}'
dmesg -T | grep -Ei 'out of memory|oom|killed process'
free -h
swapon --show
```

### 9. Política de memoria del host

La política base de memoria de este proyecto ya está definida en [02-configuracion-inicial.md](../01-sistema/02-configuracion-inicial.md):

- `zram` como swap primario
- `swapfile` de **2 GB** en el **SSD NVMe**
- `vm.swappiness=10`

Eso no sustituye a unos límites razonables de contenedores. Su función es amortiguar picos, no normalizar saturación continua.

Señales de que el host está corto de memoria:

- `SwapUsed` crece de forma sostenida en periodos normales
- `docker stats` muestra varios contenedores pegados a su tope
- aparecen eventos OOM en `dmesg`
- la latencia de servicios sube sin que la CPU esté claramente saturada

En ese caso, corrige en este orden:

1. reduce concurrencia de tareas pesadas
2. revisa límites de contenedores voraces
3. comprueba si una base de datos o servicio concreto está creciendo anómalamente
4. deja el overclock en segundo plano; casi nunca resuelve un problema real de memoria

### 10. Validación después de cualquier cambio

Cada vez que ajustes frecuencia, temperatura o límites de contenedores, valida el sistema al menos durante una ventana de carga real.

Checklist mínimo:

```bash
uptime
vcgencmd measure_temp
vcgencmd get_throttled
free -h
swapon --show
docker ps --format 'table {{.Names}}\t{{.Status}}'
docker stats --no-stream
systemctl --failed
journalctl -p err -b --no-pager
```

Debes confirmar:

- ausencia de undervoltage y throttling
- estabilidad de contenedores críticos
- ausencia de OOM
- temperatura sostenible
- discos visibles y sin errores nuevos

### 11. Plantilla de revisión de rendimiento

Puedes registrar cada ajuste con una nota simple:

```text
Fecha:
Cambio aplicado:

[ ] Línea base registrada
[ ] Backup previo de config.txt
[ ] Reinicio correcto
[ ] Sin undervoltage
[ ] Sin throttling
[ ] Temperatura estable
[ ] Docker estable
[ ] NVMe estable
[ ] hd2t estable
[ ] hd5t estable
[ ] Sin OOM

Observaciones:
Decisión final:
```

Esto evita olvidar qué combinación de ajustes era realmente estable.

## Almacenamiento

Rutas y ficheros relevantes para esta fase:

- `/boot/firmware/config.txt` para ajustes de frecuencia y temperatura
- `/boot/firmware/config.txt.bak` como rollback rápido
- `/etc/systemd/zram-generator.conf` y `/etc/sysctl.d/99-homelab-memory.conf` para la política de memoria del host
- `/home/<user>/homelab/compose/` para `docker-compose.yml` con `mem_limit` y `cpus`
- **SSD NVMe** para sistema, Docker, `compose`, datos persistentes y métricas
- `/mnt/hd2t` y `/mnt/hd5t` para bibliotecas y cargas pesadas que influyen en el rendimiento global

Reglas importantes:

- no guardes tuning operativo crítico solo en notas sueltas; deja los límites dentro del `compose` versionado
- no uses los discos USB como swap
- si el **NVMe** o los USB muestran errores, no sigas afinando rendimiento hasta resolver la base física

## Backup

Para que este tuning sea reversible, conviene respaldar como mínimo:

- `/boot/firmware/config.txt`
- `/etc/systemd/zram-generator.conf`
- `/etc/sysctl.d/99-homelab-memory.conf`
- `docker-compose.yml` y `.env` de stacks donde añadas `mem_limit` o `cpus`
- cualquier dashboard, consulta o nota operativa usada para validar rendimiento

Buenas prácticas:

- antes de tocar `config.txt`, haz copia local inmediata
- si cambias límites de varios stacks, asegúrate de que esos ficheros ya están cubiertos por la estrategia de backup del homelab
- si el cambio afecta a servicios críticos, registra también la fecha y la razón del ajuste

## Referencias

- [02-configuracion-inicial.md](../01-sistema/02-configuracion-inicial.md)
- [03-node-exporter.md](../05-monitorizacion/03-node-exporter.md)
- [01-mantenimiento-periodico.md](01-mantenimiento-periodico.md)
- Raspberry Pi Docs: [config.txt](https://www.raspberrypi.com/documentation/computers/config_txt.html)
- Raspberry Pi Docs: [Raspberry Pi OS utilities (`vcgencmd`)](https://www.raspberrypi.com/documentation/computers/os.html#vcgencmd)
- Raspberry Pi Docs: [Frequency management and thermal control](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#frequency-management-and-thermal-control)
- Docker Docs: [Compose services reference](https://docs.docker.com/reference/compose-file/services/)
- stress-ng: [stress-ng manual](https://manpages.ubuntu.com/manpages/jammy/man1/stress-ng.1.html)
