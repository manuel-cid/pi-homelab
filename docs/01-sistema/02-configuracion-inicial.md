# Configuración Inicial del Sistema

## Descripción

Tareas mínimas tras el primer login por SSH en la Raspberry Pi 5 para dejar el sistema **base** listo y estable: actualización completa del OS y del firmware, verificación y, en su caso, ajuste de **hostname**, **zona horaria** y **locale** (que ya quedaron preconfigurados por Raspberry Pi Imager), instalación de un conjunto pequeño de utilidades de diagnóstico y, sobre todo, **traslado del swap de la microSD a `hd2t`** para evitar la causa más común de muerte prematura de tarjetas en homelabs sobre Raspberry Pi.

> **Alcance**: este documento se centra en el sistema operativo "vacío", sin endurecimiento ni servicios. El cambio de password, las claves SSH definitivas, el firewall, `fail2ban` y las actualizaciones desatendidas se tratan en `docs/01-sistema/03-seguridad-base.md`. La estructura final de directorios para Docker y servicios queda para `docs/01-sistema/04-estructura-directorios.md`.

> **Recordatorio**: el homelab vive sólo en **LAN + Tailscale**. Todos los pasos de este documento se ejecutan desde la sesión SSH abierta en `docs/01-sistema/01-instalacion-os.md`.

---

## Requisitos previos

- Raspberry Pi 5 arrancada con **Raspberry Pi OS Lite 64-bit (Bookworm)** y accesible por SSH como usuario `homelab` (`docs/01-sistema/01-instalacion-os.md`).
- `vcgencmd get_throttled` devuelve `0x0` (alimentación correcta). Actualizar el sistema con la fuente al límite es una receta para corrupciones de paquete a medias.
- Conexión a internet operativa por Ethernet:

  ```bash
  ping -c 3 deb.debian.org
  ```

- Para la sección de swap en `hd2t`: el disco `hd2t` ya particionado, formateado, etiquetado y montado en `/mnt/hd2t` según `docs/00-hardware/03-preparacion-discos.md`. Si todavía no se ha hecho, se puede ejecutar el resto de este documento ahora y dejar la sección de swap para cuando `hd2t` esté preparada.

---

## Actualización del sistema

El primer paso es subir la Pi a la última versión disponible de Bookworm y al último firmware del bootloader/EEPROM. Cualquier doc posterior asume que se parte de un sistema actualizado: ejecutarla más tarde puede arrastrar incompatibilidades sutiles entre paquetes y módulos del kernel.

### 1. Refrescar índices y paquetes

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove --purge -y
sudo apt clean
```

- `full-upgrade` (no `upgrade`) permite que se eliminen paquetes obsoletos cuando una actualización lo requiere; en Raspberry Pi OS es la operación recomendada.
- `autoremove --purge` borra dependencias huérfanas y sus ficheros de configuración. Conviene hacerlo desde el principio para que el sistema no acumule cruft.

> Si la actualización trae un kernel nuevo, conviene **reiniciar al final de esta sección**: hasta entonces, `uname -r` mostrará el kernel antiguo y los módulos cargados serán los antiguos.

### 2. Firmware y bootloader (EEPROM)

La Pi 5 lleva su propio firmware en EEPROM separado del kernel; la herramienta oficial para gestionarlo es `rpi-eeprom`, que viene preinstalada en Raspberry Pi OS.

```bash
# Versión actual del bootloader
sudo rpi-eeprom-update

# Aplicar la última recomendada por la rama 'default' (estable)
sudo rpi-eeprom-update -a
```

- La rama por defecto es `default` (firmware probado y firmado por Raspberry Pi). **No** cambiar a `latest` salvo necesidad: no aporta nada al uso de homelab y es la rama menos testeada.
- Si `rpi-eeprom-update -a` indica que se ha programado una nueva versión, **reiniciar** para aplicarla:

  ```bash
  sudo reboot
  ```

  Tras el reinicio, volver a entrar por SSH y comprobar:

  ```bash
  sudo rpi-eeprom-update
  vcgencmd bootloader_version
  ```

### 3. Limpieza de configuración heredada

Tras un `full-upgrade` masivo desde una imagen recién flasheada es habitual que `apt` deje configuración antigua de paquetes ya retirados:

```bash
sudo apt purge $(dpkg -l | awk '/^rc/ {print $2}') 2>/dev/null || true
```

Este comando elimina sólo paquetes en estado `rc` ("removed, configuration remaining"); no toca paquetes activos.

---

## Instalación de utilidades base

Sobre `Raspberry Pi OS Lite` se instala únicamente el conjunto mínimo de herramientas necesarias para diagnóstico y operaciones manuales. Todo lo demás vivirá en contenedores Docker.

```bash
sudo apt install -y \
  htop \
  iotop \
  iftop \
  tmux \
  vim \
  curl \
  wget \
  git \
  jq \
  rsync \
  unzip \
  zstd \
  ca-certificates \
  gnupg \
  lsb-release \
  bash-completion \
  rpi-eeprom
```

- `htop`, `iotop`, `iftop` — diagnóstico en vivo de CPU, disco y red.
- `tmux` — sesiones persistentes para trabajos largos por SSH (importante en una Pi accesible sólo por LAN si se cae el cliente).
- `jq`, `rsync`, `zstd` — herramientas que aparecen continuamente en backups, scripts y volcados.
- `ca-certificates`, `gnupg`, `lsb-release` — prerrequisitos para añadir el repositorio oficial de Docker en `docs/02-docker/01-instalacion-docker.md`.

> Se evitan deliberadamente paquetes pesados como `build-essential`, escritorios o servidores web nativos: cada cosa vivirá en su propio contenedor para no contaminar el host.

---

## Hostname

El hostname ya quedó fijado por Raspberry Pi Imager (`homelab` por defecto en `docs/01-sistema/01-instalacion-os.md`). Verificarlo y, sólo si es necesario, cambiarlo aquí, antes de generar certificados o registrar la máquina en Tailscale.

### 1. Verificación

```bash
hostnamectl
hostname -f
```

Salida esperada (si no se cambia nada):

```
Static hostname: homelab
Pretty hostname: Homelab
Operating System: Debian GNU/Linux 12 (bookworm)
Kernel: Linux 6.6.x ...
Architecture: arm64
```

### 2. Cambio de hostname (sólo si procede)

```bash
sudo hostnamectl set-hostname <nuevo-hostname>
```

`hostnamectl set-hostname` actualiza `/etc/hostname` y aplica el cambio sin reiniciar. Además hay que mantener coherencia en `/etc/hosts`:

```bash
sudo sed -i "s/127\.0\.1\.1.*/127.0.1.1\t<nuevo-hostname>/" /etc/hosts
```

> Conviene usar **un único hostname corto, en minúsculas y sin caracteres extraños**. Ese mismo nombre aparecerá luego en Tailscale (`<hostname>.<tailnet>.ts.net`), en MagicDNS, en el DNS local de Pi-hole y en los certificados internos de Caddy. Renombrar la máquina más adelante implica regenerar todos esos.

Para que el cambio se propague a la sesión actual, salir del SSH y volver a entrar.

---

## Zona horaria

La zona horaria queda preconfigurada por Imager (`Europe/Madrid` en la guía base). Verificarla y ajustarla si fuera necesario; **es crítica** porque define cómo se interpretan los logs, los `cron`, los nombres de los snapshots de backup y la validez de los certificados internos.

```bash
timedatectl
```

Si la zona no es la deseada:

```bash
# Listar las zonas disponibles
timedatectl list-timezones | grep Europe

# Aplicar
sudo timedatectl set-timezone Europe/Madrid
```

Habilitar la sincronización por NTP (en Bookworm se gestiona mediante `systemd-timesyncd`, ya activo por defecto):

```bash
sudo timedatectl set-ntp true
timedatectl show-timesync --all | head
```

Salida esperada (extracto):

```
System clock synchronized: yes
NTP service: active
RTC in local TZ: no
```

> La Raspberry Pi 5 no incluye RTC con pila por defecto. Mientras esté en marcha la hora se mantiene; tras un apagón largo la hora se recupera vía NTP en el siguiente arranque, pero hasta que sincroniza pueden aparecer logs con timestamps absurdos. Si esto resulta molesto en operación real, se puede instalar el módulo RTC oficial de Raspberry Pi y conectarle una pila CR2032 (no es imprescindible para el homelab).

---

## Locale

Imager también escribe la configuración de locale, pero por defecto la imagen Lite arranca con `en_GB.UTF-8` y, dependiendo de la versión, no genera el locale español. Los logs del sistema, los mensajes de muchos contenedores y la salida de algunas herramientas se ajustan a este valor.

### 1. Estado actual

```bash
locale
localectl status
```

Salida típica recién instalada:

```
   System Locale: LANG=en_GB.UTF-8
       VC Keymap: es
      X11 Layout: es
```

### 2. Estrategia recomendada

Mantener el sistema con un locale **inglés UTF-8** para los logs (más predecible en troubleshooting y en compatibilidad con herramientas y trazas que se publican en internet) y, en paralelo, generar el locale local (`es_ES.UTF-8`) por si alguna aplicación o script lo necesita en el futuro.

### 3. Generar locales

```bash
sudo sed -i 's/^# *\(en_GB\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sudo sed -i 's/^# *\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sudo sed -i 's/^# *\(es_ES\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sudo locale-gen
```

`locale-gen` compila los locales descomentados en `/etc/locale.gen`. La salida debe listar `Generation complete.`

### 4. Fijar el locale por defecto del sistema

```bash
sudo localectl set-locale LANG=en_GB.UTF-8 LC_TIME=es_ES.UTF-8 LC_MESSAGES=C.UTF-8
```

- `LANG=en_GB.UTF-8` — categoría general en inglés.
- `LC_TIME=es_ES.UTF-8` — formato de fecha/hora en español (afecta a `date`, `ls -l`, etc.).
- `LC_MESSAGES=C.UTF-8` — mensajes de sistema en inglés "puro" para que sean fácilmente buscables.

Aplicar a la sesión actual o relogarse:

```bash
exec $SHELL -l
locale
```

### 5. Keymap (opcional)

El layout de teclado sólo importa si en algún momento se conecta un teclado físico (rescate). Si la imagen viene ya con `es` (caso por defecto del Imager configurado a España), no hay que tocar nada. Para cambiarlo:

```bash
sudo localectl set-keymap es
sudo localectl set-x11-keymap es
```

---

## Swap: deshabilitar en microSD y configurar en `hd2t`

Raspberry Pi OS Lite arranca con un swapfile de 200 MB en `/var/swap`, gestionado por **`dphys-swapfile`**. Mantener el swap en la microSD es la causa más frecuente de tarjetas muertas en homelabs domésticos: cualquier presión de memoria moderada (Jellyfin transcodificando, una BD compactando, un `apt` grande) escribe gigabytes en una zona pequeña del filesystem y desgasta las celdas en cuestión de meses.

La estrategia es:

1. **Desactivar y purgar `dphys-swapfile`** para que la Pi nunca vuelva a crear swap en la microSD.
2. **Crear un swapfile estático en `hd2t`** (disco mecánico/SSD externo, hecho para escritura intensiva).
3. Activarlo de forma persistente en `/etc/fstab` con `nofail` para que la ausencia del disco nunca rompa el arranque.

> Si `hd2t` aún no está montada (porque todavía no se ha completado `docs/00-hardware/03-preparacion-discos.md`), ejecutar **sólo** el paso 1 y dejar los pasos 2 y 3 para cuando el disco esté listo. El sistema funcionará perfectamente sin swap en una Pi 5 de 8 GB para este homelab.

### 1. Desactivar swap en la microSD

```bash
# Estado actual
swapon --show
free -h

# Apagar el swap activo
sudo swapoff -a

# Detener y deshabilitar el servicio que crea el swap en /var/swap
sudo systemctl disable --now dphys-swapfile

# Eliminar el paquete y su configuración
sudo apt purge -y dphys-swapfile
sudo rm -f /var/swap
```

Verificar que ya no hay swap:

```bash
swapon --show   # no debe imprimir nada
free -h         # la fila "Swap:" debe ser 0
```

### 2. Crear el swapfile en `hd2t`

Pre-condición: `hd2t` montada en `/mnt/hd2t` con filesystem `ext4` (ver `docs/00-hardware/03-preparacion-discos.md`).

```bash
# Carpeta dedicada para que el swapfile no se mezcle con datos de servicios
sudo mkdir -p /mnt/hd2t/system/swap

# Reservar 4 GB en disco (suficiente para ráfagas; no se busca un swap grande)
sudo fallocate -l 4G /mnt/hd2t/system/swap/swapfile

# Si fallocate falla en el filesystem (raro en ext4 moderno), alternativa:
# sudo dd if=/dev/zero of=/mnt/hd2t/system/swap/swapfile bs=1M count=4096 status=progress

# Permisos obligatorios
sudo chmod 600 /mnt/hd2t/system/swap/swapfile

# Formatear como swap
sudo mkswap /mnt/hd2t/system/swap/swapfile

# Activar
sudo swapon /mnt/hd2t/system/swap/swapfile

# Verificar
swapon --show
free -h
```

Tamaño elegido: **4 GB**. La Pi 5 tiene 8 GB de RAM y este homelab es modesto en uso simultáneo; 4 GB de swap son una red de seguridad razonable contra picos puntuales (compactación de bases de datos, transcodificaciones, builds esporádicos), sin convertirse en una "extensión de RAM" permanente.

### 3. Persistencia en `/etc/fstab`

Para que el swapfile se active solo en cada arranque:

```bash
# Backup del fstab antes de tocarlo
sudo cp -a /etc/fstab /etc/fstab.bak

# Añadir la línea (idempotente: no duplica si ya existe)
grep -q '/mnt/hd2t/system/swap/swapfile' /etc/fstab \
  || echo '/mnt/hd2t/system/swap/swapfile  none  swap  sw,nofail  0  0' \
       | sudo tee -a /etc/fstab
```

- `nofail` — si por la razón que sea `hd2t` no llega a montarse en el arranque, el sistema sigue arrancando sin swap en lugar de quedarse esperando en *emergency mode*.
- El swapfile **debe estar dentro del filesystem ya montado** (`/mnt/hd2t`); si la línea de montaje de `hd2t` también tiene `nofail`, la del swap no se intenta hasta que el filesystem esté disponible.

Probar la sintaxis sin reiniciar:

```bash
sudo systemctl daemon-reload
sudo swapoff -a
sudo swapon -a
swapon --show
```

### 4. Tuning conservador del kernel

Por defecto Linux tiene `vm.swappiness=60`, pensado para portátiles y escritorios. En un servidor con SSD/HDD externo y RAM holgada, conviene bajarlo para que el swap actúe sólo como red de seguridad y no como "RAM lenta de uso habitual":

```bash
sudo tee /etc/sysctl.d/99-homelab-swap.conf > /dev/null <<'EOF'
# Reducir presión sobre swap: usar sólo bajo presión real de memoria.
vm.swappiness = 10

# Preferir reclamar caché del filesystem antes que tocar swap.
vm.vfs_cache_pressure = 50
EOF

sudo sysctl --system | grep -E 'swappiness|vfs_cache_pressure'
```

Salida esperada:

```
vm.swappiness = 10
vm.vfs_cache_pressure = 50
```

---

## Limpieza de la WiFi de emergencia (opcional)

Si la WiFi configurada en Imager era estrictamente un *fallback* y se prefiere que la Pi sólo use Ethernet en operación normal, conviene **desactivar** el perfil para que `wlan0` no quede asociado todo el tiempo (consumo eléctrico, ruido en logs, otra superficie de ataque):

```bash
nmcli connection show
# Si aparece, por ejemplo, "preconfigured" en wlan0:
sudo nmcli connection modify "preconfigured" connection.autoconnect no
```

Esto deja el perfil **guardado** (se puede reactivar con `nmcli connection up preconfigured` si Ethernet falla) pero impide que se conecte automáticamente.

> **No** se recomienda eliminar la conexión WiFi entera: en un fallo del switch o del cable Ethernet, tener WiFi recuperable con un único comando (incluso accediendo desde una pantalla y un teclado físicos) es la diferencia entre 5 minutos de recuperación y desmontar todo el cableado.

Comprobar tras el cambio:

```bash
nmcli device status
```

`wlan0` debe quedar `disconnected` y `eth0` `connected`.

---

## Verificación final

Antes de pasar a `docs/01-sistema/03-seguridad-base.md`:

- [ ] `apt update && apt full-upgrade -y` no reporta paquetes pendientes (`apt list --upgradable` vacío).
- [ ] `sudo rpi-eeprom-update` indica `BOOTLOADER: up to date`.
- [ ] `hostnamectl` muestra el hostname elegido (`homelab` por defecto) y `Operating System: Debian GNU/Linux 12 (bookworm)`.
- [ ] `timedatectl` muestra la zona horaria correcta y `System clock synchronized: yes`.
- [ ] `locale` muestra `LANG=en_GB.UTF-8` y los locales españoles disponibles (`locale -a | grep es_ES`).
- [ ] `dphys-swapfile` ya no está instalado (`dpkg -l | grep dphys-swapfile` no devuelve nada).
- [ ] `swapon --show` lista `/mnt/hd2t/system/swap/swapfile` (si `hd2t` ya está preparada) o no lista nada (si todavía no lo está).
- [ ] `free -h` refleja la situación coherente con el punto anterior.
- [ ] `cat /proc/sys/vm/swappiness` devuelve `10`.
- [ ] Las utilidades base (`htop`, `tmux`, `jq`, `rsync`, etc.) están disponibles.

---

## Troubleshooting

### `apt full-upgrade` se interrumpe a mitad

Causas habituales:

- **Alimentación insuficiente**: la Pi se reinicia o entra en *throttling* durante una descompresión grande. Revisar `vcgencmd get_throttled` y la fuente.
- **microSD degradada**: errores `EXT4-fs error` en `dmesg` o checksums fallidos en paquetes. Recuperar con:

  ```bash
  sudo dpkg --configure -a
  sudo apt --fix-broken install
  sudo apt full-upgrade -y
  ```

  Si el problema reaparece, regrabar la microSD con una nueva (ver `docs/01-sistema/01-instalacion-os.md`).

### `rpi-eeprom-update` dice `*** UPDATE REQUIRED ***` pero `-a` falla

```bash
sudo apt install --reinstall rpi-eeprom
sudo rpi-eeprom-update -a
```

Si sigue fallando, comprobar que la partición de boot está montada y con espacio:

```bash
mount | grep firmware
df -h /boot/firmware
```

Raspberry Pi OS monta el firmware en `/boot/firmware` (no en `/boot` como en imágenes anteriores).

### `localectl set-locale` devuelve `Failed to set locale: ...`

Significa que el locale destino no está generado todavía. Ejecutar primero:

```bash
sudo dpkg-reconfigure locales
```

y marcar con la barra espaciadora los locales deseados. Tras `OK`, repetir `localectl set-locale`.

### `swapon` falla con `Insecure permissions`

`mkswap`/`swapon` exigen que el swapfile sea propiedad de `root` y permisos `600`:

```bash
sudo chown root:root /mnt/hd2t/system/swap/swapfile
sudo chmod 600 /mnt/hd2t/system/swap/swapfile
sudo mkswap /mnt/hd2t/system/swap/swapfile
sudo swapon /mnt/hd2t/system/swap/swapfile
```

### El swap no se activa tras reiniciar

Síntoma: tras `reboot`, `swapon --show` aparece vacío.

Comprobar el orden de montaje:

```bash
findmnt /mnt/hd2t
systemctl status mnt-hd2t.mount 2>/dev/null || true
journalctl -b -u systemd-fstab-generator
```

Causas habituales:

- La línea de `hd2t` en `/etc/fstab` no tiene `nofail` y el disco no estaba presente al arrancar → el sistema entra en modo de emergencia o salta el montaje. Revisar `docs/00-hardware/03-preparacion-discos.md`.
- El swapfile fue creado en un filesystem distinto del que aparece en `fstab` (ruta diferente). Comparar con `swapon --show` tras `swapon -a` manual.

### `dphys-swapfile` reaparece tras un `apt full-upgrade`

Algunos *meta-packages* de Raspberry Pi OS lo arrastran como dependencia "recomendada". Si se reinstala solo:

```bash
sudo systemctl disable --now dphys-swapfile
sudo apt-mark hold dphys-swapfile
```

`apt-mark hold` impide que se reinstale automáticamente sin tocar el resto de actualizaciones.

---

## Referencias

- Raspberry Pi OS — Configuración del sistema: <https://www.raspberrypi.com/documentation/computers/configuration.html>
- `rpi-eeprom` — Actualización del bootloader de la Pi 5: <https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-boot-eeprom>
- `systemd-timesyncd` — Sincronización NTP en Debian/Bookworm: <https://www.freedesktop.org/software/systemd/man/systemd-timesyncd.service.html>
- `localectl` y locales en Debian: <https://wiki.debian.org/Locale>
- `dphys-swapfile` — Configuración por defecto del swap en Raspberry Pi OS: <https://github.com/RPi-Distro/dphys-swapfile>
- Tunables de memoria virtual del kernel (`vm.swappiness`, `vm.vfs_cache_pressure`): <https://www.kernel.org/doc/Documentation/sysctl/vm.txt>
- NetworkManager en Bookworm — Gestión de WiFi y Ethernet: <https://www.raspberrypi.com/documentation/computers/configuration.html#configuring-networking>
