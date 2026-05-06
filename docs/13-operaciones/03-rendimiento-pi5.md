# Rendimiento de la Raspberry Pi 5

## Descripción
Este documento define una política de tuning para la **Raspberry Pi 5 (8 GB)** del homelab con un criterio conservador: mantener estabilidad, temperaturas controladas y buen reparto de recursos entre contenedores antes que perseguir el máximo rendimiento teórico.

El escenario operativo asumido es el del proyecto:

- **SSD NVMe** como disco principal para el sistema, Docker, `compose/`, `env/`, `scripts/` y datos persistentes
- `hd2t` para multimedia general, descargas y backups
- `hd5t` para la biblioteca multimedia de Stash
- acceso solo por **LAN + Tailscale**

Este documento cubre cuatro áreas:

- overclocking conservador y reversible
- gestión térmica y detección de throttling
- priorización de servicios según criticidad y consumo
- límites de memoria y CPU por contenedor para evitar que una carga puntual degrade todo el host

La regla general de esta fase es simple: en una Pi 5 el mejor tuning no es el más agresivo, sino el que mantiene el sistema predecible durante semanas.

## Requisitos Previos
- Haber completado `docs/13-operaciones/01-mantenimiento-periodico.md`.
- Haber completado `docs/13-operaciones/02-disaster-recovery.md`.
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/05-monitorizacion/01-prometheus.md`, `docs/05-monitorizacion/03-node-exporter.md` y `docs/05-monitorizacion/04-cadvisor.md` si quieres medir el impacto de los cambios con métricas históricas.
- Poder editar `/boot/firmware/config.txt` con privilegios de `sudo`.
- Tener refrigeración activa o, como mínimo, una carcasa con disipación real antes de probar cualquier overclock.
- Tener una fuente de alimentación estable y adecuada para Raspberry Pi 5.
- Poder ejecutar `docker`, `docker compose`, `sudo`, `vcgencmd`, `free`, `uptime`, `df`, `journalctl` y `docker stats`.
- Tener disponibles y montadas estas rutas:
  - `/home/<usuario>/homelab`
  - `/mnt/hd2t`
  - `/mnt/hd5t`
- Paquetes recomendados para validación y estrés controlado:

```bash
sudo apt update
sudo apt install -y stress-ng sysstat lm-sensors
```

- Puertos implicados:
  - no hace falta abrir puertos nuevos para esta fase
  - se reutilizan los accesos administrativos ya existentes en LAN o Tailscale
  - si usas dashboards o monitorización, se mantienen los puertos ya definidos en sus propios stacks

## Docker Compose
No aplica como despliegue independiente.

Este documento no introduce un servicio nuevo, pero sí define patrones reutilizables que deben integrarse en los `compose.yml` existentes cuando un contenedor necesite límites explícitos.

Fragmento base para un servicio ligero:

```yaml
services:
  dozzle:
    image: amir20/dozzle:latest
    restart: unless-stopped
    mem_limit: 256m
    mem_reservation: 128m
    cpus: 0.50
```

Fragmento base para un servicio más pesado:

```yaml
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    restart: unless-stopped
    mem_limit: 1536m
    mem_reservation: 768m
    cpus: 2.00
    shm_size: "256m"
```

Notas prácticas:

- usa `mem_limit` como tope duro para contener picos descontrolados
- usa `mem_reservation` como referencia de consumo esperado
- usa `cpus` para evitar que un solo contenedor monopolice todos los cores
- aplica límites primero a servicios pesados o poco críticos; no limites a ciegas bases de datos o middleware sin observar antes su comportamiento real

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| CPU | funcionamiento estable, preferiblemente a frecuencias stock o con overclock ligero validado |
| Temperatura | operación sostenida sin throttling; objetivo práctico por debajo de 80 °C |
| Memoria | sin presión constante, sin `OOMKilled` y sin swap creciendo sin control |
| Contenedores pesados | con límites explícitos de RAM y CPU |
| Servicios críticos | priorizados frente a multimedia, indexación o tareas batch |
| Operación | cambios reversibles y documentados |

### 1. Principios de tuning

Antes de tocar nada, fija estas reglas:

1. la estabilidad vale más que un pequeño aumento de rendimiento
2. el overclock solo tiene sentido si la refrigeración y la fuente son correctas
3. los límites por contenedor son más útiles que exprimir la CPU del host
4. cualquier cambio debe probarse bajo carga real, no solo con el sistema en reposo
5. si aparece throttling, reinicios o corrupción, vuelve al perfil anterior inmediatamente

La Pi 5 con 8 GB ya ofrece un margen razonable para este homelab. En la mayoría de casos, el cuello de botella no es la frecuencia base de CPU sino:

- transcodificación o escaneos intensivos de multimedia
- picos de RAM por indexación, importaciones o generación de miniaturas
- exceso de contenedores arrancando a la vez
- temperatura alta mantenida durante cargas largas

### 2. Línea base antes de cambiar rendimiento

Mide siempre el estado actual antes de introducir límites o overclock.

Inventario rápido:

```bash
uptime
free -h
df -h / /mnt/hd2t /mnt/hd5t
docker ps --format 'table {{.Names}}\t{{.Status}}'
docker stats --no-stream
vcgencmd measure_temp
vcgencmd get_throttled
```

Si tienes monitorización desplegada, anota durante varios días al menos:

- uso medio y pico de CPU
- uso de RAM del host
- contenedores con mayor consumo sostenido
- temperatura típica en reposo y bajo carga
- franjas horarias con más actividad de descargas, escaneos o streaming

Señales de que debes optimizar antes por software que por overclock:

- memoria libre muy baja de forma habitual
- contenedores `OOMKilled`
- CPU al 100 % durante importaciones, pero no el resto del día
- temperaturas altas incluso a frecuencias stock
- varios servicios pesados corriendo a la vez sin límites

### 3. Overclocking conservador

La recomendación por defecto para este homelab es **mantener frecuencias stock** si el comportamiento actual ya es estable. Solo aplica overclock si has detectado una carga sostenida que realmente lo justifica y tienes buena refrigeración.

Ruta habitual del fichero de arranque en Raspberry Pi OS moderno:

```bash
sudoedit /boot/firmware/config.txt
```

Perfil conservador de ejemplo:

```ini
# Tuning conservador para Raspberry Pi 5
# Validar siempre con carga real antes de darlo por bueno
arm_freq=2600
gpu_freq=900
over_voltage_delta=25000
```

Reglas para usar este perfil:

- aplícalo solo si la Pi es estable a frecuencias stock
- cambia una sola vez y valida; no combines varios incrementos seguidos
- mantén copia del `config.txt` anterior
- si el homelab es principalmente de servicios ligeros, no fuerces overclock por costumbre

Backup del fichero antes de editar:

```bash
sudo cp /boot/firmware/config.txt /boot/firmware/config.txt.bak
```

Aplicación del cambio:

```bash
sudo reboot
```

Validación tras reinicio:

```bash
vcgencmd measure_clock arm
vcgencmd measure_temp
vcgencmd get_throttled
```

Prueba de estrés controlada:

```bash
stress-ng --cpu 4 --cpu-method matrixprod --timeout 10m
```

Estado aceptable tras la prueba:

- el sistema no reinicia ni se congela
- `vcgencmd get_throttled` no muestra flags activos durante la prueba
- la temperatura no se mantiene en zona de throttling
- los servicios Docker siguen respondiendo al terminar la carga

Si algo falla, revierte al backup:

```bash
sudo cp /boot/firmware/config.txt.bak /boot/firmware/config.txt
sudo reboot
```

### 4. Gestión de temperatura

Un homelab sobre Pi 5 rinde mejor con temperatura contenida que con frecuencias más altas pero inestables.

Objetivos prácticos:

- reposo: temperatura razonable y estable según tu carcasa y ambiente
- carga sostenida: preferiblemente por debajo de 80 °C
- `get_throttled`: idealmente `0x0` en operación normal

Comprobación rápida en vivo:

```bash
watch -n 2 'vcgencmd measure_temp; vcgencmd get_throttled'
```

Medidas recomendadas:

- usa ventilación activa en la carcasa NVMe si el diseño lo permite
- evita encerrar la Pi 5 junto a fuentes de calor o sin flujo de aire
- mantén la carcasa y rejillas limpias de polvo
- no apiles procesos intensivos de CPU, escaneo y transcodificación al mismo tiempo
- programa tareas pesadas fuera de las horas habituales de uso

Si detectas throttling repetido:

1. vuelve a frecuencias stock si estabas usando overclock
2. mejora ventilación antes de tocar más parámetros
3. reduce carga simultánea de contenedores pesados
4. revisa si hay procesos del host o contenedores consumiendo CPU de forma anómala

### 5. Priorización de servicios

No todos los servicios merecen el mismo trato cuando faltan CPU, RAM o temperatura.

Clasificación operativa sugerida:

| Prioridad | Tipo de servicio | Ejemplos | Política |
|---|---|---|---|
| P1 | infraestructura crítica | Tailscale, Pi-hole, Unbound, Portainer, backups, monitorización básica | mantener siempre estables, con arranque prioritario y sin competir con cargas pesadas |
| P2 | aplicaciones persistentes | Vaultwarden, Nextcloud, BookStack, Linkding, Mealie, Home Assistant | proteger su estabilidad; evitar que queden sin RAM por culpa de multimedia o descargas |
| P3 | multimedia e indexación | Jellyfin, Navidrome, Calibre-Web, Paperless-ngx, Stash | limitar recursos y programar escaneos fuera de horas pico |
| P4 | batch y descargas | Transmission, Sonarr, Radarr, Prowlarr, tareas de importación masiva | permitir ráfagas, pero con límites para que no degraden el host completo |

Reglas prácticas de priorización:

- los servicios P1 no deben depender de que P3 o P4 estén desahogados
- evita ejecutar escaneos, imports y backups pesados al mismo tiempo
- si Jellyfin o Stash generan carga alta, reduce antes sus límites o su concurrencia antes que tocar infraestructura
- si un servicio P3 o P4 genera presión de RAM, es mejor limitarlo que dejar que el kernel expulse otros procesos

Orden recomendado para investigar degradación:

1. comprobar si el problema viene de multimedia, descargas o tareas batch
2. revisar límites de RAM y CPU de los contenedores más pesados
3. revisar temperatura y throttling
4. solo después valorar overclock o cambios más agresivos

### 6. Límites de memoria por contenedor

En una Pi 5 de 8 GB no conviene sumar límites duros como si toda la memoria fuera utilizable por Docker. Deja margen para:

- kernel y servicios del host
- cache del sistema de archivos
- picos breves de bases de datos y aplicaciones web
- buffers de red, Docker y tareas administrativas

Regla práctica: intenta que la suma de límites duros de los contenedores con actividad simultánea habitual no consuma toda la RAM del host. Deja al menos un margen operativo claro para el sistema.

Rangos conservadores orientativos:

| Perfil | RAM sugerida | Ejemplos |
|---|---|---|
| Ligero | `128m` a `256m` | Dozzle, Uptime Kuma, Homepage, node-exporter |
| Medio ligero | `256m` a `512m` | Pi-hole, Unbound, Portainer, Authelia |
| Medio | `512m` a `1024m` | Vaultwarden, Linkding, BookStack, Mealie, Navidrome |
| Pesado | `1024m` a `2048m` | Nextcloud, Paperless-ngx, Home Assistant, Jellyfin |
| Muy pesado o burst | `1536m` a `3072m` | Stash, imports grandes, escaneos intensivos, procesos ligados a multimedia |

Ejemplo de límites razonables para una carga multimedia:

```yaml
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    restart: unless-stopped
    mem_limit: 1536m
    mem_reservation: 768m
    cpus: 2.00
    shm_size: "256m"

  stash:
    image: stashapp/stash:latest
    restart: unless-stopped
    mem_limit: 2048m
    mem_reservation: 1024m
    cpus: 2.50
```

Cómo validar que un límite es correcto:

- el contenedor funciona normalmente en uso real
- no aparecen reinicios por falta de memoria
- el host conserva margen de RAM libre y no entra en presión constante
- el servicio sigue respondiendo durante su tarea más pesada esperable

Qué evitar:

- fijar límites idénticos para todos los servicios
- limitar bases de datos o middleware críticos sin revisar métricas previas
- considerar el overclock como sustituto de una mala asignación de memoria

### 7. CPU, afinidad y cargas intensivas

En la Pi 5 suele bastar con limitar `cpus` por contenedor. La afinidad manual de cores solo merece la pena si has demostrado un problema concreto.

Ejemplo simple:

```yaml
services:
  transmission:
    image: lscr.io/linuxserver/transmission:latest
    restart: unless-stopped
    cpus: 1.50
    mem_limit: 768m
```

Política recomendada:

- limita primero servicios de descarga, indexación y multimedia
- no limites en exceso servicios P1 si apenas consumen CPU
- evita lanzar tareas administrativas pesadas mientras hay streaming o backups

### 8. Señales de que el tuning es correcto

El sistema está bien ajustado cuando ocurre todo esto a la vez:

- no hay throttling recurrente
- la Pi mantiene temperaturas razonables para su carcasa y ambiente
- no hay contenedores muriendo por falta de memoria
- los servicios críticos siguen respondiendo aunque haya carga secundaria
- los discos USB y el NVMe no muestran retrasos anómalos por saturación inducida desde Docker

### 9. Cuándo no tocar nada

No ajustes más parámetros si:

- el host es estable durante semanas
- el uso de CPU y RAM tiene margen suficiente
- no hay throttling
- los tiempos de respuesta reales ya son aceptables

La optimización innecesaria en una Pi 5 suele introducir más riesgo operativo que beneficio real.

## Almacenamiento
El rendimiento del homelab depende también de mantener separadas las cargas de disco según el diseño del proyecto:

- el **NVMe** debe seguir alojando sistema, Docker, `compose/`, `env/`, `scripts/` y datos persistentes de servicios
- `hd2t` debe seguir concentrando multimedia general, descargas y backups
- `hd5t` debe seguir concentrando la biblioteca de Stash

Implicaciones de rendimiento:

- evita mover bases de datos y volúmenes persistentes críticos a discos USB solo por ganar espacio
- evita que tareas de importación, descargas y backups saturen a la vez `hd2t`
- deja el NVMe para operaciones sensibles a latencia y metadatos frecuentes
- revisa con prioridad los servicios que escriben mucho en `data/` si el NVMe empieza a llenarse

Comprobación rápida:

```bash
findmnt / /mnt/hd2t /mnt/hd5t
df -h / /mnt/hd2t /mnt/hd5t
docker stats --no-stream
```

## Backup
Si aplicas tuning o límites de recursos, debes incluir en backup la configuración que hace reproducible ese estado:

- `/boot/firmware/config.txt`
- cualquier copia de seguridad manual del `config.txt` anterior
- ficheros `compose.yml` y overrides donde hayas definido `mem_limit`, `mem_reservation`, `cpus` o `shm_size`
- scripts de validación o estrés guardados en `/home/<usuario>/homelab/scripts/`
- notas operativas o baseline de métricas si las guardas en el repositorio del homelab

Antes de modificar overclock o límites de recursos:

1. confirma que el último backup es válido
2. guarda copia del fichero que vas a cambiar
3. aplica un único cambio cada vez
4. valida estabilidad antes del siguiente ajuste

La recuperación de estos cambios debe coordinarse con `docs/13-operaciones/02-disaster-recovery.md`.

## Referencias
- [Raspberry Pi documentation: `config.txt`](https://www.raspberrypi.com/documentation/computers/config_txt.html)
- [Raspberry Pi documentation](https://www.raspberrypi.com/documentation/)
- [Docker Docs: resource constraints](https://docs.docker.com/engine/containers/resource_constraints/)
- [Compose Specification](https://compose-spec.io/)
