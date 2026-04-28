# Configuración Inicial del Sistema

## Descripción

Procedimiento de **configuración inicial** de la Raspberry Pi 5 una vez que el sistema operativo arranca limpio y es accesible por SSH (ver [`01-instalacion-os.md`](./01-instalacion-os.md)) y los discos externos `hd5t` y `hd2t` están particionados y montados (ver [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md)).

Este documento cubre, en este orden:

1. **Primera conexión** y verificación del estado del sistema tras el arranque.
2. **Actualización completa** de paquetes (`apt`) y firmware de la Pi (`rpi-eeprom`).
3. **Verificación y ajuste** de `hostname`, **zona horaria** y **locale**.
4. **Deshabilitación de la swap en la microSD** (`dphys-swapfile`) para no desgastar la tarjeta.
5. **Creación de un swapfile en `hd2t`** como red de seguridad ante presión de memoria.
6. Ajustes de **comportamiento de swap** (`vm.swappiness`).

> **Alcance**: este documento deja la Pi con un SO actualizado, con la localización correcta y con un esquema de swap saludable para un homelab que va a tener varios contenedores Docker corriendo. El **endurecimiento de seguridad** (claves SSH, firewall, fail2ban, unattended-upgrades) se hace en [`03-seguridad-base.md`](./03-seguridad-base.md). La **estructura de directorios** sobre los discos externos se define en [`04-estructura-directorios.md`](./04-estructura-directorios.md).

> **Recordatorio**: el homelab opera en **LAN + Tailscale**. Todo lo que se haga aquí ocurre dentro de la red local, sin exposición a internet.

---

## Requisitos Previos

- Raspberry Pi 5 con **Raspberry Pi OS Lite 64-bit** instalado según [`01-instalacion-os.md`](./01-instalacion-os.md), accesible por `ssh homelab@<ip>` con autenticación por clave pública.
- Discos externos **`hd5t`** y **`hd2t`** particionados, formateados (`ext4`) y montados en `/mnt/hd5t` y `/mnt/hd2t` respectivamente, según [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md).
- Conexión a internet vía Ethernet (necesaria para `apt update` y para descargar firmware de la Pi).
- Usuario `homelab` con permisos `sudo`.
- Una sesión SSH abierta desde el PC de administración (preferiblemente vía el alias `ssh homelab` configurado en [`01-instalacion-os.md`](./01-instalacion-os.md#71-opcional-alias-en-sshconfig)).

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Hostname | `homelab` | Ya se preconfigura con Raspberry Pi Imager en [`01-instalacion-os.md`](./01-instalacion-os.md). En este documento solo se **verifica** y se documenta cómo cambiarlo si fuera necesario. |
| Zona horaria | `Europe/Madrid` | Coherencia con el operador y con los logs del homelab. |
| Locale del sistema | `es_ES.UTF-8` | Locale principal del operador. Se mantiene `C.UTF-8` como locale de respaldo del sistema, así los mensajes de servicios y scripts no dependen de traducciones. |
| Layout de teclado de la consola física | `es` | Solo afecta a la consola conectada por HDMI (recovery). SSH no se ve afectado. |
| Swap en microSD | **Deshabilitada** | Las tarjetas microSD tienen ciclos de escritura limitados; usarlas como swap las desgasta de forma acelerada. Es uno de los motivos típicos de fallo prematuro en Raspberry Pi. |
| Swap en `hd2t` | **Habilitada, 4 GiB**, fichero `/mnt/hd2t/swap/swapfile` | La Pi 5 tiene 8 GiB de RAM; con todos los servicios del homelab corriendo conviene tener una swap mínima como red de seguridad para evitar OOM kills. Se aloja en `hd2t` (HDD), no en la microSD, para preservar la tarjeta. |
| `vm.swappiness` | `10` | Valor bajo: el kernel solo recurre a swap bajo presión real de memoria. En sistemas con HDD como swap, valores altos penalizan mucho el rendimiento. |

---

## 1. Primera conexión y diagnóstico inicial

Conectarse por SSH desde el PC de administración:

```bash
ssh homelab
# o, si no se ha creado el alias:
# ssh homelab@<ip-de-la-pi>
```

Una vez dentro, hacer un repaso rápido del estado del sistema antes de tocar nada:

```bash
hostnamectl                    # hostname, kernel, arquitectura
timedatectl                    # zona horaria y estado de NTP
localectl                      # locale activo y layout de teclado
uname -a                       # debe indicar aarch64
cat /etc/os-release            # Debian Bookworm / Raspberry Pi OS
free -h                        # memoria y swap actuales
swapon --show                  # ubicación de la swap si está activa
df -hT / /mnt/hd5t /mnt/hd2t   # raíz + discos externos
uptime                         # tiempo encendido y carga
```

Apuntar:

- Si **swap** está activa, dónde está (lo más probable: `/var/swap` en la microSD vía `dphys-swapfile`).
- Si la **zona horaria** ya es `Europe/Madrid` (Imager debería haberla configurado).
- Si el **locale** ya es `es_ES.UTF-8`.

Estos valores se ajustan más abajo solo si no son los esperados.

---

## 2. Actualización completa del sistema

El primer paso real de configuración es dejar el SO totalmente actualizado: paquetes Debian + firmware específico de la Pi.

### 2.1. Sincronizar índices y paquetes

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove -y
sudo apt clean
```

- `apt full-upgrade` (en lugar de `upgrade`) permite resolver dependencias que requieren instalar/eliminar paquetes; es la forma recomendada en Debian/Raspberry Pi OS.
- `autoremove` elimina paquetes huérfanos que dejaron de ser dependencia tras el upgrade.

### 2.2. Firmware de la Pi (`rpi-eeprom`) y kernel

Raspberry Pi OS expone el firmware de bootloader/EEPROM y el kernel a través de paquetes `apt`, así que tras el `full-upgrade` ya están actualizados. Conviene confirmar el estado del bootloader:

```bash
sudo rpi-eeprom-update
```

Si reporta `BOOTLOADER: up to date`, no hay nada que hacer. Si dice `BOOTLOADER: update available`, aplicarlo:

```bash
sudo rpi-eeprom-update -a
```

El nuevo bootloader se aplica en el siguiente reinicio.

### 2.3. Reinicio para aplicar kernel/firmware

Si `apt full-upgrade` ha actualizado el kernel (paquetes `linux-image-*` o `raspberrypi-kernel`) o `rpi-eeprom` ha aplicado un bootloader nuevo, **reiniciar**:

```bash
sudo reboot
```

Esperar ~1 minuto y volver por SSH:

```bash
ssh homelab
uname -a
sudo rpi-eeprom-update
```

`rpi-eeprom-update` debe ahora reportar `up to date`.

---

## 3. Hostname

El hostname ya se establece en `homelab` desde Raspberry Pi Imager. Verificarlo:

```bash
hostnamectl
```

Salida esperada (parcial):

```
   Static hostname: homelab
         Icon name: computer
        Machine ID: ...
           Boot ID: ...
  Operating System: Debian GNU/Linux 12 (bookworm)
            Kernel: Linux 6.x.y
      Architecture: arm64
```

Si por cualquier motivo el hostname no es `homelab` (o se quiere cambiar), aplicar de forma persistente:

```bash
sudo hostnamectl set-hostname homelab
```

Y mantener `/etc/hosts` coherente (Raspberry Pi OS suele hacerlo, pero conviene revisar):

```bash
sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1\thomelab/" /etc/hosts
cat /etc/hosts
```

`/etc/hosts` debe contener al menos:

```
127.0.0.1   localhost
127.0.1.1   homelab
```

Tras esto, recargar la sesión (`logout` + `ssh homelab`) para que el prompt refleje el nuevo nombre.

---

## 4. Zona horaria

Comprobar el estado actual:

```bash
timedatectl
```

Establecer `Europe/Madrid` si no lo está ya:

```bash
sudo timedatectl set-timezone Europe/Madrid
```

Activar sincronización NTP (debería estar activa por defecto):

```bash
sudo timedatectl set-ntp true
timedatectl
```

Salida esperada (campos relevantes):

```
               Local time: ...
           Universal time: ...
                 RTC time: n/a
                Time zone: Europe/Madrid (CET/CEST, +0100/+0200)
System clock synchronized: yes
              NTP service: active
          RTC in local TZ: no
```

> La Raspberry Pi 5 **no tiene RTC respaldado por batería** salvo que se le haya conectado el módulo opcional. Es esperado que `RTC time: n/a`. Mientras la Pi tenga conectividad, NTP pone la hora en cuestión de segundos tras el arranque.

---

## 5. Locale

Imager preconfigura `es_ES.UTF-8` y teclado `es`. Verificar:

```bash
localectl
```

Salida esperada:

```
   System Locale: LANG=es_ES.UTF-8
       VC Keymap: es
      X11 Layout: es
```

### 5.1. Generar el locale si no está presente

Si `LANG` no es `es_ES.UTF-8` o si al ejecutar comandos aparecen warnings tipo `locale: Cannot set LC_ALL to default locale: No such file or directory`, regenerar locales:

```bash
sudo sed -i 's/^# *\(es_ES.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sudo sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sudo locale-gen
sudo update-locale LANG=es_ES.UTF-8 LC_ALL=es_ES.UTF-8
```

Se mantiene `en_US.UTF-8` también generado porque algunas herramientas y mensajes de error en Debian/Bookworm asumen un locale en inglés disponible.

> Como alternativa interactiva: `sudo dpkg-reconfigure locales`. Marcar `es_ES.UTF-8` y `en_US.UTF-8`, elegir `es_ES.UTF-8` como locale por defecto.

### 5.2. Layout de teclado de la consola física

Solo importa si en algún momento se conecta un teclado físico a la Pi (recovery). Verificar y ajustar:

```bash
sudo localectl set-keymap es
sudo localectl set-x11-keymap es
```

Cerrar y volver a abrir la sesión SSH para que las variables de locale del shell se apliquen.

---

## 6. Deshabilitar la swap en la microSD

Raspberry Pi OS instala por defecto **`dphys-swapfile`**, que crea un swapfile (típicamente `/var/swap`, 100–200 MiB) en la **microSD**. Esto es problemático en un homelab porque las microSD tienen ciclos de escritura limitados y la swap, aunque pequeña, se escribe muy a menudo cuando hay presión de memoria.

### 6.1. Estado actual

```bash
swapon --show
sudo systemctl status dphys-swapfile --no-pager
```

Si `swapon --show` muestra una entrada como `/var/swap`, está activa en la microSD.

### 6.2. Apagar y deshabilitar `dphys-swapfile`

```bash
sudo dphys-swapfile swapoff
sudo dphys-swapfile uninstall
sudo systemctl stop dphys-swapfile
sudo systemctl disable dphys-swapfile
```

- `swapoff`: detiene la swap actual.
- `uninstall`: elimina el fichero `/var/swap` de la microSD.
- `disable`: evita que el servicio vuelva a crearla al arrancar.

### 6.3. Eliminar el paquete (opcional, recomendado)

Para asegurarse de que ningún `apt full-upgrade` futuro vuelva a habilitarlo:

```bash
sudo apt purge -y dphys-swapfile
sudo apt autoremove -y
```

### 6.4. Verificar que no queda swap

```bash
swapon --show
free -h
```

`swapon --show` no debe imprimir nada (output vacío). En `free -h`, la línea `Swap:` debe mostrar `0B` total.

A partir de aquí la Pi corre **sin swap**. La sustitución por un swapfile en `hd2t` se hace en el siguiente paso.

---

## 7. Crear swapfile en `hd2t`

Se aloja la swap en el HDD `hd2t` (montado en `/mnt/hd2t`) para no tocar la microSD. Tamaño elegido: **4 GiB**, suficiente como red de seguridad ante un pico ocasional de memoria sin penalizar el rendimiento general (la swap en HDD es mucho más lenta que la RAM).

> **Requisito**: el disco `hd2t` debe estar montado en `/mnt/hd2t` (paso ya cubierto en [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md)). Verificarlo con `findmnt /mnt/hd2t` antes de continuar.

### 7.1. Reservar un directorio dedicado

```bash
sudo mkdir -p /mnt/hd2t/swap
sudo chmod 700 /mnt/hd2t/swap
```

`chmod 700` evita que ningún usuario salvo `root` pueda leer el swapfile (la swap puede contener fragmentos de memoria sensible).

### 7.2. Crear el fichero de 4 GiB

Usar `fallocate` (rápido) y, si por algún motivo falla en ext4 con la combinación de opciones del mount, recurrir a `dd`:

```bash
sudo fallocate -l 4G /mnt/hd2t/swap/swapfile
# si fallocate falla:
# sudo dd if=/dev/zero of=/mnt/hd2t/swap/swapfile bs=1M count=4096 status=progress
```

Asegurar permisos correctos (la herramienta `mkswap` se queja si no son `600`):

```bash
sudo chmod 600 /mnt/hd2t/swap/swapfile
```

### 7.3. Inicializar y activar la swap

```bash
sudo mkswap /mnt/hd2t/swap/swapfile
sudo swapon /mnt/hd2t/swap/swapfile
swapon --show
free -h
```

`swapon --show` debe mostrar:

```
NAME                       TYPE SIZE USED PRIO
/mnt/hd2t/swap/swapfile    file   4G   0B   -2
```

### 7.4. Persistir en `/etc/fstab`

Para que la swap se monte sola en cada arranque, añadir una línea a `/etc/fstab`:

```bash
sudo cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d-%H%M%S)
echo '/mnt/hd2t/swap/swapfile  none  swap  sw,nofail,x-systemd.requires=/mnt/hd2t  0  0' | sudo tee -a /etc/fstab
```

Justificación de las opciones:

- `sw`: swap estándar.
- `nofail`: si el disco `hd2t` no está disponible en el arranque, **no** caer en modo emergencia. Crítico, igual que en las líneas de los propios discos.
- `x-systemd.requires=/mnt/hd2t`: indica a systemd que esta unidad de swap **depende** del montaje de `/mnt/hd2t`. Sin esto, systemd puede intentar activar la swap **antes** de que `hd2t` esté montado, y fallar en cada arranque.

Recargar systemd y comprobar que la línea se interpreta sin error:

```bash
sudo systemctl daemon-reload
sudo swapoff /mnt/hd2t/swap/swapfile
sudo swapon -a
swapon --show
```

### 7.5. Prueba de reinicio

El test definitivo es reiniciar y confirmar que la swap aparece sola:

```bash
sudo reboot
```

Tras volver por SSH:

```bash
swapon --show
free -h
findmnt /mnt/hd2t
```

`/mnt/hd2t` debe estar montado y la swap debe aparecer activa apuntando a `/mnt/hd2t/swap/swapfile`.

---

## 8. Ajustar `vm.swappiness`

Por defecto, el kernel Linux usa `vm.swappiness=60`, lo que significa que tiende a mover páginas a swap incluso con RAM disponible. En un sistema con la swap en HDD, eso penaliza mucho el rendimiento. Un valor bajo (`10`) hace que el kernel solo recurra a swap **bajo presión real** de memoria.

### 8.1. Valor actual

```bash
cat /proc/sys/vm/swappiness
```

### 8.2. Persistir el valor

```bash
sudo tee /etc/sysctl.d/99-homelab-swappiness.conf > /dev/null <<'EOF'
# Homelab — swap en HDD: usar swap solo bajo presión real de memoria.
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF

sudo sysctl --system
```

- `vm.swappiness = 10`: minimiza uso de swap mientras quede RAM.
- `vm.vfs_cache_pressure = 50`: reduce a la mitad la presión sobre la cache de inodos/dentries; útil cuando hay servicios de archivos como Jellyfin o Stash que se benefician de mantener en cache muchos metadatos.

### 8.3. Verificar

```bash
sysctl vm.swappiness vm.vfs_cache_pressure
```

Debe imprimir:

```
vm.swappiness = 10
vm.vfs_cache_pressure = 50
```

---

## Lista de Verificación

Antes de pasar a [`03-seguridad-base.md`](./03-seguridad-base.md):

- [ ] `apt update && apt full-upgrade` no reporta paquetes pendientes.
- [ ] `sudo rpi-eeprom-update` indica `BOOTLOADER: up to date`.
- [ ] `hostnamectl` muestra `Static hostname: homelab` y `Operating System: Debian GNU/Linux 12 (bookworm)` (o versión actual).
- [ ] `timedatectl` muestra `Time zone: Europe/Madrid` y `System clock synchronized: yes`.
- [ ] `localectl` muestra `LANG=es_ES.UTF-8` y `VC Keymap: es`.
- [ ] `swapon --show` **no** lista `/var/swap` (microSD); `dphys-swapfile` está deshabilitado y purgado.
- [ ] `swapon --show` lista `/mnt/hd2t/swap/swapfile` con `SIZE=4G`.
- [ ] `/etc/fstab` contiene la línea de swap con `nofail` y `x-systemd.requires=/mnt/hd2t`.
- [ ] Tras un reboot, la swap se activa sola y `findmnt /mnt/hd2t` reporta el disco montado.
- [ ] `sysctl vm.swappiness` devuelve `10`.

---

## Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `apt update` falla con `Could not resolve` o `Temporary failure in name resolution` | DNS aún no configurado (Pi-hole se monta en la Fase 3). | Verificar que `/etc/resolv.conf` apunta al DNS del router (DHCP). `ping 1.1.1.1` debe funcionar; si sí, el problema es solo de DNS y se puede usar temporalmente `1.1.1.1` editando `/etc/resolv.conf`. |
| `apt full-upgrade` deja paquetes "kept back" | Cambios de dependencia que `upgrade` evitaría. | Usar `apt full-upgrade` (no `apt upgrade`); revisar manualmente los paquetes listados. |
| `rpi-eeprom-update` no existe | Paquete `rpi-eeprom` no instalado. | `sudo apt install -y rpi-eeprom`. |
| `localectl` sigue mostrando `LANG=C.UTF-8` tras `update-locale` | El locale `es_ES.UTF-8` no se generó. | Editar `/etc/locale.gen`, descomentar la línea `es_ES.UTF-8 UTF-8` y ejecutar `sudo locale-gen`. |
| Avisos `setlocale: LC_ALL: cannot change locale (es_ES.UTF-8)` | El locale no está disponible en el sistema. | Igual que arriba: regenerar con `locale-gen` y reabrir la sesión SSH. |
| `swapon /mnt/hd2t/swap/swapfile` falla con `Insecure permissions` | Permisos del swapfile distintos de `600`. | `sudo chmod 600 /mnt/hd2t/swap/swapfile`. |
| `swapon` falla con `swapfile has holes` | `fallocate` produjo un fichero esparcido que `mkswap` no acepta en algunas versiones de kernel. | Recrearlo con `dd if=/dev/zero of=... bs=1M count=4096`. |
| Tras un reboot, la swap no se activa pero `/mnt/hd2t` sí está montado | Falta `x-systemd.requires=/mnt/hd2t` en la línea de swap, o systemd activó la swap demasiado pronto. | Añadir/confirmar `x-systemd.requires=/mnt/hd2t`, `sudo systemctl daemon-reload`, reboot. |
| Tras un reboot, la Pi se queda colgada en `A start job is running for /dev/...` durante 90 s | Falta `nofail` en la línea de swap o de los discos en `/etc/fstab`. | Añadir `nofail` y `x-systemd.device-timeout=15`. Ver también [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md). |
| `dphys-swapfile` reaparece tras un upgrade | El paquete fue solo deshabilitado, no purgado. | `sudo apt purge -y dphys-swapfile`. |

---

## Referencias

- [Raspberry Pi OS — Configuration](https://www.raspberrypi.com/documentation/computers/configuration.html)
- [`rpi-eeprom-update(8)` — Raspberry Pi documentation](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-boot-eeprom)
- [`hostnamectl(1)` — manual page](https://www.freedesktop.org/software/systemd/man/hostnamectl.html)
- [`timedatectl(1)` — manual page](https://www.freedesktop.org/software/systemd/man/timedatectl.html)
- [`localectl(1)` — manual page](https://www.freedesktop.org/software/systemd/man/localectl.html)
- [`locale.gen(5)` y `locale-gen(8)` — Debian](https://manpages.debian.org/bookworm/locales/locale.gen.5.en.html)
- [`mkswap(8)` — manual page](https://man7.org/linux/man-pages/man8/mkswap.8.html)
- [`swapon(8)` — manual page](https://man7.org/linux/man-pages/man8/swapon.8.html)
- [`fstab(5)` — manual page](https://man7.org/linux/man-pages/man5/fstab.5.html)
- [`systemd.mount` — `nofail`, `x-systemd.requires`](https://www.freedesktop.org/software/systemd/man/systemd.mount.html)
- [`sysctl.d(5)` — manual page](https://www.freedesktop.org/software/systemd/man/sysctl.d.html)
- [Documentación del kernel sobre `vm.swappiness`](https://www.kernel.org/doc/Documentation/sysctl/vm.txt)
