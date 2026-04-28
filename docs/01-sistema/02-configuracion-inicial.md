# Configuración Inicial del Sistema

## Descripción

Tras `01-instalacion-os.md` la Raspberry Pi 5 arranca con Raspberry Pi OS Lite 64-bit, hostname `homelab`, usuario administrador y SSH habilitado solo por clave pública. Falta dejar el sistema en un estado **estable, actualizado y con el comportamiento de memoria adecuado al hardware del homelab** antes de pasar a `03-seguridad-base.md` (firewall y endurecimiento) y `04-estructura-directorios.md` (jerarquía de datos en los discos externos).

Este documento cubre las tareas que tradicionalmente se hacen "en el primer login" pero que conviene ejecutar de forma deliberada y verificable:

- Verificar que la configuración aplicada por el Imager (hostname, locale, zona horaria, teclado) ha entrado realmente en vigor.
- Actualizar el sistema completo y reiniciar para asentar cambios de kernel/firmware.
- Eliminar el paquete `dphys-swapfile` que crea por defecto un swap de 100–200 MB **sobre la microSD**, una pésima idea para una tarjeta flash que es además el único almacén del SO.
- Configurar un **swapfile en `/mnt/hd2t`** (disco USB 3.0 de 2 TB), con tamaño y `swappiness` razonables para que la Pi no muera por OOM cuando se acumulen contenedores, pero sin desgastar la microSD.
- Dejar `journald` y `apt` con valores que limiten el crecimiento descontrolado de logs y caché en `/`.

Todo lo de este documento se ejecuta **por SSH** desde el equipo de trabajo con `ssh homelab` (alias creado en `01-instalacion-os.md`).

> **Recordatorio de alcance**: la Pi sigue siendo solo accesible desde la LAN. Aún no hay Tailscale, ni Docker, ni servicios.

---

## Requisitos Previos

- Documento `01-instalacion-os.md` completado: la Pi responde a `ssh homelab` con la clave pública del equipo de trabajo y el usuario `homelab` tiene permisos de `sudo`.
- Discos externos preparados según `docs/00-hardware/03-preparacion-discos.md`: `/mnt/hd2t` y `/mnt/hd5t` están en `/etc/fstab`, montan en boot y son escribibles por el usuario `homelab`. **El swapfile depende de `/mnt/hd2t`**: si esa fase no está aplicada, parar aquí y volver atrás.
- Conexión a internet desde la Pi (Ethernet con DHCP del router): se descarga ~150–300 MB de actualizaciones en una imagen Lite recién flasheada.

Comprobación rápida antes de empezar:

```bash
ssh homelab
# Ya dentro de la Pi:
findmnt /mnt/hd2t      # debe aparecer con type ext4 y rw
ip route | grep default # debe haber una ruta por eth0
ping -c 2 deb.debian.org
```

---

## Primer Login y Estado de Partida

Una vez dentro por SSH conviene hacer una "foto" del estado inicial para tener referencia de qué se cambia con este documento:

```bash
hostnamectl
localectl
timedatectl
free -h
swapon --show
df -h /
mount | grep " / "
```

Resultado típico tras un flasheo limpio con la configuración del Imager:

| Comando | Lo que importa |
|---|---|
| `hostnamectl` | `Static hostname: homelab`. Si saliera `raspberrypi`, el Imager no aplicó el hostname (revisar). |
| `localectl` | `System Locale: LANG=es_ES.UTF-8`, `VC Keymap: es`. |
| `timedatectl` | `Time zone: Europe/Madrid (CET, +0100)` o `(CEST, +0200)` según la fecha. `System clock synchronized: yes`, `NTP service: active`. |
| `free -h` | `Mem` ≈ `7.8 Gi` total. `Swap` ≈ `100 Mi` o `200 Mi` (esto es lo que vamos a eliminar). |
| `swapon --show` | Muestra `/var/swap` o similar, en la microSD. |
| `df -h /` | El root está en `/dev/mmcblk0p2` con la capacidad real de la tarjeta (el firstboot ya expandió la partición). |

> Si `timedatectl` muestra `NTP service: inactive` o el reloj desincronizado, esperar 1–2 minutos: `systemd-timesyncd` necesita salir a internet la primera vez. Si tras varios minutos sigue inactivo: `sudo systemctl enable --now systemd-timesyncd` y verificar `systemctl status systemd-timesyncd`.

---

## Actualización del Sistema

Raspberry Pi OS hereda los repositorios de Debian Bookworm más los específicos de la Foundation (`archive.raspberrypi.com`). En este punto se aplican **todas** las actualizaciones disponibles, no solo seguridad: la imagen del Imager puede llevar semanas sin refrescarse.

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove --purge -y
sudo apt clean
```

Notas sobre cada comando:

| Comando | Motivo |
|---|---|
| `apt update` | Refresca los índices. Si aparece algún `NO_PUBKEY` u `Origin changed`, **no** seguir adelante: indica un repositorio mal configurado o una imagen corrupta. |
| `apt full-upgrade` | Equivalente a `dist-upgrade`. Se elige sobre `upgrade` porque puede instalar/eliminar paquetes para resolver dependencias, lo que es habitual con `linux-image-*` y `raspi-firmware`. |
| `apt autoremove --purge` | Quita paquetes huérfanos **y** sus ficheros de configuración. En una instalación recién flasheada apenas hay; con el tiempo evita acumular kernels viejos. |
| `apt clean` | Vacía `/var/cache/apt/archives`. Importante: la microSD es pequeña y los `.deb` cacheados no aportan nada después del `upgrade`. |

### Actualizar firmware de la Pi y bootloader

La Pi 5 recibe actualizaciones de firmware EEPROM y de bootloader independientes del kernel. Se gestionan con `rpi-eeprom`, ya instalado en la imagen Lite:

```bash
sudo rpi-eeprom-update
# Si aparece "UPDATE AVAILABLE":
sudo rpi-eeprom-update -a
```

El cambio de EEPROM **no se aplica hasta el siguiente reinicio**, por eso conviene encadenarlo con el reinicio que de todas formas vamos a hacer tras `full-upgrade`.

### Reinicio

```bash
sudo reboot
```

Esperar ~30–60 segundos y volver a entrar:

```bash
ssh homelab
uname -a
cat /proc/device-tree/model
```

`uname -a` debe mostrar el kernel actualizado. `device-tree/model` confirma que se sigue arrancando como Pi 5 (un EEPROM corrupto puede dejarla en modo recovery).

---

## Hostname

El hostname `homelab` ya viene del Imager. Solo se documenta aquí cómo cambiarlo correctamente si en algún momento hace falta (por ejemplo, si se monta una segunda Pi y se quiere distinguirlas):

```bash
sudo hostnamectl set-hostname homelab2
```

`hostnamectl` actualiza simultáneamente:

- `/etc/hostname`
- El nombre transitorio en kernel (visible al instante en `hostname`).
- El registro mDNS de Avahi (la Pi pasa a anunciarse como `homelab2.local`).

Después hay que sincronizar `/etc/hosts` para que `sudo` no avise de `unable to resolve host`:

```bash
sudo sed -i "s/127\\.0\\.1\\.1.*/127.0.1.1\thomelab2/" /etc/hosts
```

> **No editar `/etc/hostname` a mano** sin pasar por `hostnamectl`: deja el sistema inconsistente (kernel y systemd con nombres distintos hasta el siguiente reboot).

En el escenario habitual, este apartado solo sirve como referencia: el hostname se queda en `homelab`.

---

## Locale, Teclado y Zona Horaria

También vienen del Imager. Se verifican y, si hace falta, se corrigen sin tocar `raspi-config` (que en una instalación Lite por SSH lanza un TUI innecesario para cambios puntuales).

### Locale

```bash
localectl
# Si LANG no es es_ES.UTF-8:
sudo sed -i 's/^# *\\(es_ES.UTF-8 UTF-8\\)/\\1/' /etc/locale.gen
sudo locale-gen
sudo localectl set-locale LANG=es_ES.UTF-8
```

Conservar **también** `en_US.UTF-8` activado es útil: muchos mensajes técnicos y manpages son más buscables en inglés. Si `localectl` lo muestra como disponible, no hace falta tocar nada.

### Teclado de consola

Solo aplica para sesiones físicas (HDMI + teclado USB). Por SSH **no** afecta:

```bash
sudo localectl set-keymap es
sudo localectl set-x11-keymap es     # inocuo en Lite, sin Xorg, pero deja la config preparada
```

### Zona horaria

```bash
timedatectl
# Si no es Europe/Madrid:
sudo timedatectl set-timezone Europe/Madrid
```

Justificación de fijar la zona horaria explícitamente y no `UTC`:

- Los timestamps de los logs (`journalctl`, futuros logs de Docker, salidas de Borgmatic, alertas de Prometheus/Grafana) los va a leer una persona en hora local. Tener el host en `Europe/Madrid` evita conversiones mentales constantes y discrepancias con los relojes de los clientes (móviles, portátil) que sí están en hora local.
- Cron y los timers de systemd disparan en hora local: una limpieza programada "a las 04:00" se entiende sin ambigüedad.
- Internamente, Linux usa `CLOCK_REALTIME` en UTC; la zona horaria es solo presentación. No hay penalización de rendimiento ni problema con NTP.

### Sincronización horaria

Raspberry Pi OS Bookworm Lite usa `systemd-timesyncd` (cliente SNTP, no `chrony` ni `ntpd`). Es suficiente para un homelab donde la precisión "buena" es del orden de centenares de milisegundos:

```bash
timedatectl show-timesync --all | head -n 20
systemctl status systemd-timesyncd --no-pager
```

Verificar `NTPSynchronized=yes` y un servidor activo (por defecto `*.debian.pool.ntp.org`). Si se quisiera mayor precisión (necesaria si más adelante se firmase TOTP propio o se quisieran logs con sub-segundo coherente entre múltiples nodos), se sustituiría por `chrony`, pero para una sola Pi con SNTP basta.

---

## Desactivar el Swap en la microSD

Raspberry Pi OS instala `dphys-swapfile`, un script clásico que crea `/var/swap` (100 MB por defecto en Bookworm) sobre la microSD. Hay dos razones por las que no queremos eso en este homelab:

1. **Desgaste de la flash**. Las microSD usan TLC/QLC con un número de ciclos de escritura limitado por celda y un controlador de wear-leveling muy básico. Un swap activo, aunque sea pequeño, escribe constantemente sobre el mismo área lógica cuando hay presión de memoria, acelerando el fallo de la tarjeta.
2. **Latencia**. Una microSD típica hace ~30 MB/s en escritura sostenida con latencias de varios ms; el HDD USB 3.0 de `hd2t` ronda ~100–120 MB/s con latencias parecidas pero con miles de veces más resistencia. Para swap, el HDD es estrictamente mejor que la microSD.

La forma correcta de desactivarlo es **eliminar el paquete entero**, no solo `swapoff`. Así nos aseguramos de que un futuro `apt upgrade` no lo reactive:

```bash
sudo systemctl stop dphys-swapfile
sudo systemctl disable dphys-swapfile
sudo apt purge -y dphys-swapfile
sudo rm -f /var/swap
```

Verificar que ya no hay swap:

```bash
swapon --show
free -h | grep -i swap
```

`swapon --show` no debe imprimir nada y la línea `Swap` de `free` debe mostrar `0B`. A partir de aquí, **el sistema funciona temporalmente sin swap**: si la Pi se quedara sin RAM antes de configurar el swap nuevo, el OOM killer mataría procesos. Por eso el siguiente paso se hace **inmediatamente después**, sin reiniciar entremedias.

---

## Configurar Swap en `/mnt/hd2t`

### Tamaño y razonamiento

| Recurso | Valor | Por qué |
|---|---|---|
| RAM total | 8 GiB | Hardware fijo de la Pi 5 8 GB. |
| Swap a crear | **8 GiB** en `hd2t` | 1× la RAM. Suficiente para absorber picos cuando se reinicien stacks de Docker pesados (Nextcloud + MariaDB + Redis) o durante backups con Borg, sin caer en el escenario "todo el sistema empieza a swappear y se vuelve inusable". El homelab tiene 2 TB en `hd2t`, 8 GiB son irrelevantes en términos de espacio. |
| `vm.swappiness` | **10** | Por defecto Linux usa `60`, agresivo. Bajarlo a `10` indica al kernel que prefiera reclamar caché de páginas antes que escribir swap. En una Pi con discos USB esto es deseable: el swap se usa **solo** como red de seguridad, no como "RAM extra rutinaria". |
| `vm.vfs_cache_pressure` | **50** | Reducir la presión sobre dentry/inode cache mejora la latencia de operaciones repetitivas sobre `/mnt/hd5t` (Stash) y `/mnt/hd2t` (medias y BBDDs), donde se escanean miles de ficheros. |

### Crear el fichero de swap

Importante: crear el fichero **dentro** de `/mnt/hd2t`, no en un subdirectorio que dependa de `04-estructura-directorios.md` (todavía no aplicado). Se usa una ruta dedicada `/mnt/hd2t/swap/` que es trivial y no interfiere con ningún servicio:

```bash
sudo mkdir -p /mnt/hd2t/swap
sudo chmod 700 /mnt/hd2t/swap

# 8 GiB con fallocate (instantáneo, requiere ext4 — que es lo que monta hd2t):
sudo fallocate -l 8G /mnt/hd2t/swap/swapfile

# Si fallocate fallase por algún motivo (FS no soportado), fallback con dd:
# sudo dd if=/dev/zero of=/mnt/hd2t/swap/swapfile bs=1M count=8192 status=progress

sudo chmod 600 /mnt/hd2t/swap/swapfile
sudo mkswap /mnt/hd2t/swap/swapfile
sudo swapon /mnt/hd2t/swap/swapfile
```

Comprobaciones:

```bash
swapon --show
# NAME                       TYPE  SIZE   USED PRIO
# /mnt/hd2t/swap/swapfile    file  8G     0B   -2

free -h
# Mem:  7.8Gi  ...   ...
# Swap: 8.0Gi  0B    8.0Gi
```

### Persistir en `/etc/fstab` con dependencia del montaje

Una entrada `swap` plana en `fstab` se procesa antes de montar `/mnt/hd2t` y falla. Se añade con la opción `x-systemd.requires=` para que systemd ordene correctamente las units:

```bash
sudo tee -a /etc/fstab >/dev/null <<'EOF'

# Swapfile en hd2t (preferido sobre la microSD para no desgastarla)
/mnt/hd2t/swap/swapfile  none  swap  sw,x-systemd.requires=/mnt/hd2t,nofail  0  0
EOF
```

Significado de las opciones:

| Opción | Significado |
|---|---|
| `sw` | Activa el swap como tipo `swap` (equivalente a `swapon`). |
| `x-systemd.requires=/mnt/hd2t` | Genera una dependencia explícita de la unit `mnt-hd2t.mount`. Si `hd2t` no monta (cable USB suelto, disco fallando), el swap **no se intenta**, en lugar de fallar el boot. |
| `nofail` | Si el dispositivo falta, el sistema arranca igualmente. Crítico en un homelab que tiene que ser accesible por SSH aunque un disco externo no esté presente, para poder diagnosticar. |
| `0 0` | Sin `dump`, sin `fsck`. No aplican a un swapfile. |

Recargar systemd y validar:

```bash
sudo systemctl daemon-reload
sudo systemctl restart 'mnt-hd2t.mount'    # opcional: confirma que hd2t monta limpio
swapon --show                              # debe seguir mostrando el swap activo
```

### Aplicar `swappiness` y `vfs_cache_pressure` de forma persistente

```bash
sudo tee /etc/sysctl.d/90-homelab-swap.conf >/dev/null <<'EOF'
# Homelab: minimizar uso de swap (HDD USB) y presión sobre el VFS cache.
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF

sudo sysctl --system | grep -E "swappiness|vfs_cache"
```

La salida debe incluir `vm.swappiness = 10` y `vm.vfs_cache_pressure = 50`. El fichero en `sysctl.d` sobrevive a actualizaciones del paquete `procps`.

### ¿Y zram?

Una alternativa moderna (e instalable: `apt install zram-tools`) es usar swap comprimido en RAM. En máquinas con poca RAM y sin disco rápido es muy buena idea. **En este homelab se descarta de momento** porque:

- Hay 8 GiB de RAM y un HDD USB 3.0 dedicado en `hd2t` sin presión de espacio.
- zram añade carga de CPU al kernel para comprimir/descomprimir, justo en momentos de presión de memoria, donde la Pi también está haciendo otras cosas (Docker, Borg).
- El plan declarado en `PLAN.md` es "swap en hd2t". Mantener una sola fuente de verdad evita sorpresas en `13-operaciones/03-rendimiento-pi5.md`.

Si en el futuro la Pi mostrase patrones constantes de "swap activo + I/O alto en `hd2t`", se reconsidera y se añade zram **encima** del swapfile, no como sustituto.

---

## Higiene de Logs y Caché en `/`

La microSD es el único almacén del SO; conviene capar de entrada dos fuentes típicas de crecimiento descontrolado en `/`:

### `journald`

Por defecto, `journalctl` puede llegar a usar el 10 % del filesystem. En una microSD de 64 GiB son ~6 GiB de logs, más de lo razonable y mucho desgaste:

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/00-homelab.conf >/dev/null <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
SystemKeepFree=1G
SystemMaxFileSize=50M
MaxRetentionSec=1month
ForwardToSyslog=no
EOF

sudo systemctl restart systemd-journald
journalctl --disk-usage
```

Comportamiento resultante: hasta 500 MB de logs persistentes en `/var/log/journal/`, rotando ficheros de 50 MB y descartando entradas mayores de un mes. Suficiente para diagnosticar problemas recientes; cuando se quieran logs largos de servicios concretos, se exportarán desde Loki o Dozzle (Fase 5), no desde el journal del host.

### Caché de `apt`

El `apt clean` que ya hicimos vacía la caché actual. Para que no se vuelva a llenar tras cada `unattended-upgrades` (Fase `03-seguridad-base.md`), se configura limpieza periódica:

```bash
sudo tee /etc/apt/apt.conf.d/99-homelab-clean >/dev/null <<'EOF'
APT::Periodic::AutocleanInterval "7";
APT::Periodic::CleanInterval     "30";
EOF
```

Esto activa `apt-daily-clean.timer` en sus valores por defecto sin interferir con la futura configuración de `unattended-upgrades`.

---

## Verificación Final

Antes de pasar a `03-seguridad-base.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Hostname aplicado | `hostnamectl --static` | `homelab` |
| Locale | `localectl` | `LANG=es_ES.UTF-8` |
| Zona horaria | `timedatectl` | `Time zone: Europe/Madrid`, `NTP service: active`, `System clock synchronized: yes` |
| Sistema actualizado | `apt list --upgradable 2>/dev/null \| wc -l` | `0` (o `1`, contando el header) |
| EEPROM al día | `sudo rpi-eeprom-update` | `BOOTLOADER: up to date` |
| `dphys-swapfile` ausente | `dpkg -l dphys-swapfile 2>/dev/null` | Sin entradas |
| Swap activo en hd2t | `swapon --show` | Línea `/mnt/hd2t/swap/swapfile  file  8G  ...` |
| Swap persistente | `grep swapfile /etc/fstab` | Una línea con `x-systemd.requires=/mnt/hd2t,nofail` |
| `swappiness` aplicado | `sysctl vm.swappiness vm.vfs_cache_pressure` | `vm.swappiness = 10`, `vm.vfs_cache_pressure = 50` |
| Logs limitados | `journalctl --disk-usage` | Tamaño < 500 MB tras unas horas de uso |
| Reboot sin sorpresas | `sudo reboot` y luego `swapon --show` | El swap vuelve activo solo, sin tocar nada |

El último punto es el más importante: **reiniciar y comprobar que el sistema vuelve solo, con el swap activo y `/mnt/hd2t` montado**. Si tras reboot `swapon --show` está vacío, el problema típico es que `/mnt/hd2t` no se montó (revisar `dmesg | grep -i usb` y la entrada de fstab del disco en Fase 0).

---

## Backup

En esta fase aún no hay servicios ni datos de usuario que respaldar, pero sí piezas de configuración relevantes que conviene saber dónde viven, para cuando entren en el ámbito de Borgmatic en Fase 7:

| Ruta | Qué guarda | Estrategia |
|---|---|---|
| `/etc/fstab` | Montajes de hd5t, hd2t y la entrada del swapfile | Versionado en repo del homelab + Borg en Fase 7. |
| `/etc/sysctl.d/90-homelab-swap.conf` | `swappiness` y `vfs_cache_pressure` | Idem. |
| `/etc/systemd/journald.conf.d/00-homelab.conf` | Límites de logs | Idem. |
| `/etc/apt/apt.conf.d/99-homelab-clean` | Limpieza de caché APT | Idem. |
| `/etc/locale.gen`, `/etc/default/locale`, `/etc/timezone` | Locale y zona horaria | Idem; reproducibles también con `localectl`/`timedatectl`. |
| `/mnt/hd2t/swap/swapfile` | El propio fichero de swap | **NO se respalda**: 8 GiB de datos efímeros sin valor. Borgmatic lo excluirá explícitamente cuando se configure (Fase 7). |

Mientras tanto, el repositorio de documentación (este árbol bajo `docs/`) es la fuente de verdad para reconstruir esta configuración a mano si la microSD muere.

---

## Referencias

- [Documento anterior: `01-instalacion-os.md`](./01-instalacion-os.md)
- [Documento siguiente: `03-seguridad-base.md`](./03-seguridad-base.md)
- [`docs/00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md) — Montaje de `/mnt/hd2t` y `/mnt/hd5t`.
- [`SERVICES.md`](../../SERVICES.md) — Alcance del homelab.
- [Raspberry Pi — `rpi-eeprom-update`](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-boot-eeprom)
- [`hostnamectl(1)` — manpage Debian](https://manpages.debian.org/bookworm/systemd/hostnamectl.1.en.html)
- [`localectl(1)` — manpage Debian](https://manpages.debian.org/bookworm/systemd/localectl.1.en.html)
- [`timedatectl(1)` — manpage Debian](https://manpages.debian.org/bookworm/systemd/timedatectl.1.en.html)
- [`systemd-timesyncd(8)` — manpage Debian](https://manpages.debian.org/bookworm/systemd/systemd-timesyncd.8.en.html)
- [`fstab(5)` — manpage Debian](https://manpages.debian.org/bookworm/util-linux/fstab.5.en.html)
- [`systemd.mount(5)` — opciones `x-systemd.requires`, `nofail`](https://manpages.debian.org/bookworm/systemd/systemd.mount.5.en.html)
- [`sysctl.d(5)` — manpage Debian](https://manpages.debian.org/bookworm/systemd/sysctl.d.5.en.html)
- [`journald.conf(5)` — manpage Debian](https://manpages.debian.org/bookworm/systemd/journald.conf.5.en.html)
- [Kernel docs — `vm.swappiness`](https://docs.kernel.org/admin-guide/sysctl/vm.html#swappiness)
- [Debian Wiki — Swap](https://wiki.debian.org/Swap)
