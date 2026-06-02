# Configuración Inicial del Sistema

## Descripción

Procedimiento para completar la **configuración base del sistema operativo** en el **primer arranque ya migrado al SSD NVMe**, después de haber instalado Raspberry Pi OS y movido el arranque fuera de la microSD. El objetivo es dejar la Raspberry Pi 5 con una base limpia y coherente para las siguientes fases: sistema actualizado, identidad del host definida, parámetros regionales correctos y una estrategia de memoria adaptada al homelab.

La política de memoria de este proyecto usa **`zram` como swap primario** y un **swapfile de 2 GB en el SSD NVMe** como red de seguridad. No se debe usar swap en los discos USB `hd2t` o `hd5t`: añaden latencia, pueden sufrir desconexiones y compiten con el I/O de multimedia y backups.

Este documento asume que la Raspberry Pi **ya arranca desde el NVMe** siguiendo [05-arranque-nvme.md](/Users/x441425/workspace2/homelab/docs/00-hardware/05-arranque-nvme.md). La estructura final de discos y su función dentro del homelab se apoya en [03-preparacion-discos.md](/Users/x441425/workspace2/homelab/docs/00-hardware/03-preparacion-discos.md).

## Requisitos Previos

- Haber completado la instalación inicial descrita en [01-instalacion-os.md](/Users/x441425/workspace2/homelab/docs/01-sistema/01-instalacion-os.md).
- Haber migrado el arranque al SSD NVMe siguiendo [05-arranque-nvme.md](/Users/x441425/workspace2/homelab/docs/00-hardware/05-arranque-nvme.md).
- Poder acceder por **SSH** al sistema con el usuario administrativo.
- Disponer de conectividad de red funcional, preferiblemente por **Ethernet**.
- Tener decidido de antemano:
  - `hostname` definitivo
  - zona horaria real del homelab
  - locale principal del sistema

## Objetivo de esta Fase

Al terminar este documento, el estado esperado es este:

- La Raspberry Pi arranca realmente desde el **SSD NVMe**.
- El sistema base está actualizado con los últimos paquetes disponibles.
- El `hostname`, la zona horaria y el locale están alineados con la ubicación y uso reales del homelab.
- La estrategia de swap queda configurada así:
  - **`zram`** con prioridad alta como primera capa
  - **`/swapfile` de 2 GB en el SSD NVMe** con prioridad baja como respaldo
  - `vm.swappiness=10` para evitar swapping agresivo
- No existe swap en los discos USB dedicados a multimedia o backups.

## Docker Compose

No aplica en esta fase. Aquí todavía no se instala Docker ni se despliegan servicios.

## Configuración

### 1. Confirmar que el sistema ya está arrancando desde el NVMe

Antes de tocar nada, valida que la raíz del sistema ya no está en la microSD:

```bash
findmnt -no SOURCE /
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,LABEL
```

El dispositivo montado en `/` debe corresponder al **SSD NVMe**, no a la microSD. En una instalación típica verás algo parecido a `nvme0n1p2`.

Si el sistema todavía arranca desde la microSD, detente aquí y vuelve a [05-arranque-nvme.md](/Users/x441425/workspace2/homelab/docs/00-hardware/05-arranque-nvme.md).

### 2. Actualizar el sistema base

Con el arranque ya validado sobre NVMe, actualiza el sistema completo:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove --purge -y
sudo apt clean
```

Si durante la actualización se renuevan kernel, firmware o componentes base de systemd, reinicia antes de seguir:

```bash
sudo reboot
```

Después del reinicio, vuelve a entrar por SSH y confirma que todo sigue montado sobre el NVMe.

### 3. Ajustar el hostname definitivo

Comprueba el nombre actual:

```bash
hostnamectl status --static
```

Si necesitas cambiarlo:

```bash
sudo hostnamectl set-hostname <hostname>
```

Después edita `/etc/hosts` para que la entrada `127.0.1.1` use el mismo nombre:

```bash
sudo nano /etc/hosts
```

Ejemplo mínimo:

```text
127.0.0.1       localhost
127.0.1.1       <hostname>
```

Verifica el resultado:

```bash
hostnamectl
```

### 4. Configurar zona horaria

Define la zona horaria real del equipo. Ejemplo para Madrid:

```bash
sudo timedatectl set-timezone Europe/Madrid
timedatectl
```

Usa siempre la zona horaria real del lugar donde vive el homelab. Esto evita problemas posteriores con logs, tareas programadas, backups y gráficas de monitorización.

### 5. Configurar locale

Edita el fichero de locales y habilita el que vayas a usar:

```bash
sudo nano /etc/locale.gen
```

Descomenta la línea correspondiente, por ejemplo:

```text
es_ES.UTF-8 UTF-8
```

Genera el locale y aplícalo como predeterminado:

```bash
sudo locale-gen
sudo update-locale LANG=es_ES.UTF-8 LC_ALL=es_ES.UTF-8
```

Abre una nueva sesión SSH y verifica:

```bash
locale
```

Si prefieres otro locale principal, sustituye `es_ES.UTF-8` por el valor que corresponda. Lo importante es dejarlo fijado de forma explícita y no depender de valores implícitos o parciales.

### 6. Revisar la situación actual de swap

Antes de reconfigurar la memoria virtual, comprueba qué swap existe ahora mismo:

```bash
swapon --show --output=NAME,TYPE,SIZE,USED,PRIO
systemctl status dphys-swapfile --no-pager
```

En Raspberry Pi OS es habitual encontrar `dphys-swapfile` activo por defecto. Para este homelab no interesa mantener esa configuración genérica porque vamos a sustituirla por una política controlada y explícita.

### 7. Desactivar el swap por defecto

Desactiva y deshabilita `dphys-swapfile`:

```bash
sudo systemctl disable --now dphys-swapfile
```

Si existe el swapfile antiguo de la configuración por defecto, elimínalo:

```bash
sudo rm -f /var/swap
```

Vuelve a comprobar el estado:

```bash
swapon --show
```

### 8. Configurar `zram` como swap primario

Instala el generador de zram para systemd:

```bash
sudo apt install -y systemd-zram-generator
```

Crea el fichero de configuración:

```bash
sudo nano /etc/systemd/zram-generator.conf
```

Contenido recomendado para una Raspberry Pi 5 con 8 GB de RAM:

```ini
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
```

Con esta configuración:

- `zram` ofrece una primera capa de swap en memoria comprimida.
- `ram / 2` equivale aproximadamente a **4 GB** de swap comprimido en una Pi de 8 GB.
- `swap-priority = 100` hace que el kernel prefiera `zram` antes que el swapfile físico.

No hace falta activarlo manualmente todavía; quedará listo tras el siguiente reinicio.

### 9. Crear un swapfile de 2 GB en el SSD NVMe

El swapfile actúa como red de seguridad cuando la presión de memoria supera lo que puede absorber `zram`. Debe vivir en el **SSD NVMe**, nunca en `hd2t` ni en `hd5t`.

Crea el fichero:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
```

Añádelo a `/etc/fstab` con prioridad baja:

```bash
sudo nano /etc/fstab
```

Añade esta línea al final:

```fstab
/swapfile none swap defaults,pri=10 0 0
```

La prioridad `10` deja claro que este swapfile debe usarse solo después de `zram`.

### 10. Ajustar `swappiness`

Para evitar que el sistema empiece a intercambiar memoria de forma agresiva, fija `swappiness` a `10`:

```bash
sudo nano /etc/sysctl.d/99-homelab-memory.conf
```

Contenido:

```conf
vm.swappiness=10
```

Aplica los cambios:

```bash
sudo sysctl --system
```

Con este valor, el sistema seguirá priorizando la RAM real y solo recurrirá al swap cuando de verdad haya presión de memoria.

### 11. Reiniciar y validar la configuración final

Reinicia el sistema para activar `zram`, aplicar el swapfile persistente y dejar el entorno en su estado definitivo:

```bash
sudo reboot
```

Después del reinicio, comprueba:

```bash
swapon --show --output=NAME,TYPE,SIZE,USED,PRIO
cat /proc/sys/vm/swappiness
findmnt -no SOURCE /
```

El resultado esperado es equivalente a este:

- `/dev/zram0` con prioridad alta, por ejemplo `100`
- `/swapfile` con prioridad baja, por ejemplo `10`
- `vm.swappiness` igual a `10`
- raíz del sistema montada sobre el **NVMe**

### 12. Comprobación operativa mínima

Antes de pasar a la siguiente guía, ejecuta una verificación rápida:

```bash
hostnamectl
timedatectl
locale
free -h
swapon --show
```

Revisa especialmente:

- que el `hostname` sea el definitivo
- que fecha, hora y zona horaria sean correctas
- que el locale activo sea el esperado
- que `zram` y el swapfile estén presentes simultáneamente
- que no exista swap en discos USB

### 13. Qué hacer justo después

El siguiente paso recomendado es endurecer el sistema con [03-seguridad-base.md](/Users/x441425/workspace2/homelab/docs/01-sistema/03-seguridad-base.md). Más adelante, la organización definitiva de carpetas y montajes persistentes se documenta en [04-estructura-directorios.md](/Users/x441425/workspace2/homelab/docs/01-sistema/04-estructura-directorios.md).

## Almacenamiento

Durante esta fase, el criterio de almacenamiento queda así:

- **SSD NVMe**: sistema operativo, `swapfile`, configuraciones y más adelante datos persistentes de servicios.
- **`hd2t`**: multimedia general, descargas y backups, pero nunca swap.
- **`hd5t`**: biblioteca multimedia de Stash, pero nunca swap.

Motivos para no usar swap en discos USB:

- añaden más latencia que el NVMe
- una desconexión o reinicio del bus USB puede provocar errores graves
- compiten con flujos intensivos de lectura/escritura de multimedia, scrapers y backups

## Backup

En esta fase todavía no hay servicios con datos persistentes, pero sí conviene conservar:

- el `hostname` definitivo configurado
- la zona horaria y el locale elegidos
- la política de swap aplicada
- cualquier cambio manual adicional hecho en `/etc/hosts`, `/etc/fstab`, `/etc/sysctl.d/` y `/etc/systemd/zram-generator.conf`

Estos ficheros son pequeños, pero forman parte del estado base del host y conviene poder reconstruirlos sin improvisar.

## Referencias

- Raspberry Pi OS
- systemd
- `man timedatectl`
- `man locale`
- `man swapon`
- [01-instalacion-os.md](/Users/x441425/workspace2/homelab/docs/01-sistema/01-instalacion-os.md)
- [03-preparacion-discos.md](/Users/x441425/workspace2/homelab/docs/00-hardware/03-preparacion-discos.md)
- [05-arranque-nvme.md](/Users/x441425/workspace2/homelab/docs/00-hardware/05-arranque-nvme.md)
