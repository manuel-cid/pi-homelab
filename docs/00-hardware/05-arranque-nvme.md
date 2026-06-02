# Arranque desde NVMe

## Descripción

Procedimiento para migrar una **Raspberry Pi 5** desde un arranque inicial en **microSD** a un arranque definitivo desde **SSD NVMe**. El objetivo es que el sistema operativo, Docker, configuraciones y datos persistentes queden alojados en el NVMe, dejando la microSD solo como soporte temporal o de emergencia.

Este documento cubre la actualización del firmware EEPROM, el cambio del orden de arranque, varias estrategias de migración al NVMe y la verificación final sin microSD insertada. La conexión física previa se describe en [02-esquema-conexiones.md](02-esquema-conexiones.md), la preparación de discos en [03-preparacion-discos.md](03-preparacion-discos.md) y la incorporación de discos USB con datos en [04-discos-con-datos.md](04-discos-con-datos.md).

## Requisitos Previos

- Haber validado el hardware descrito en [01-material-necesario.md](01-material-necesario.md).
- Tener montado físicamente el **SSD NVMe** en una carcasa compatible con Raspberry Pi 5 según [02-esquema-conexiones.md](02-esquema-conexiones.md).
- Disponer de una instalación funcional de Raspberry Pi OS ya arrancando desde **microSD**.
- Acceso por terminal con un usuario con permisos de `sudo`.
- Alimentación estable con la **fuente oficial USB-C de 27 W**.
- Asumir que durante la migración al NVMe se va a escribir sobre el SSD y que cualquier dato previo en él puede perderse.

## Objetivo de la Migración

El estado final esperado es este:

- **SSD NVMe**: sistema operativo, Docker Engine, configuraciones, volúmenes persistentes, bases de datos y logs.
- **`hd2t`**: multimedia general, descargas y backups.
- **`hd5t`**: biblioteca multimedia dedicada de Stash.
- **microSD**: retirada del equipo una vez verificado el arranque desde NVMe.

Esto reduce la dependencia de la microSD para cargas continuas y deja el almacenamiento operativo en el medio más rápido y fiable del conjunto.

## Recomendación de Método

Hay tres enfoques razonables para pasar el sistema al NVMe:

1. **Raspberry Pi Imager**: la opción más limpia si todavía estás en una fase temprana y puedes reinstalar el sistema en el NVMe sin necesidad de conservar exactamente la microSD.
2. **`dd`**: clonación sector a sector de la microSD al NVMe. Es directa, pero también la menos flexible y copia errores, particiones pequeñas o espacio desperdiciado.
3. **`rsync`**: copia a nivel de ficheros. Requiere más pasos, pero suele ser la opción más controlable si quieres conservar la instalación existente y adaptar mejor el tamaño del NVMe.

Para un homelab recién montado, la recomendación práctica es:

- Si apenas has configurado nada todavía, usa **Raspberry Pi Imager**.
- Si ya tienes la microSD bastante preparada y quieres migrarla tal cual, usa **`rsync`**.
- Reserva **`dd`** para casos en los que quieras una copia literal y entiendas bien sus implicaciones.

## Comprobaciones Previas

Antes de cambiar el arranque, verifica qué discos ve el sistema.

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,MODEL
sudo blkid
```

Lo habitual es ver:

- La microSD como `mmcblk0`.
- El SSD como `nvme0n1`.
- Los discos USB como `sda`, `sdb` o similares.

No continúes si el NVMe no aparece de forma estable.

### Recomendación operativa

Durante la migración conviene **desconectar temporalmente `hd2t` y `hd5t`** o, al menos, extremar la verificación del nombre de dispositivo para no confundir el SSD NVMe con un disco USB.

## Actualización del Sistema y del Firmware EEPROM

Antes de tocar el orden de arranque, actualiza el sistema base y el firmware de arranque.

```bash
sudo apt update
sudo apt full-upgrade -y
sudo rpi-eeprom-update
```

Si `rpi-eeprom-update` indica que hay una versión nueva pendiente, aplícala:

```bash
sudo rpi-eeprom-update -a
sudo reboot
```

Después del reinicio, vuelve a comprobar:

```bash
sudo rpi-eeprom-update
```

El objetivo es que la Raspberry Pi 5 tenga un bootloader actualizado con soporte correcto para arranque desde NVMe.

## Configuración del Boot Order

La forma más sencilla es usar `raspi-config`:

```bash
sudo raspi-config
```

Ruta habitual:

1. `Advanced Options`
2. `Boot Order`
3. Seleccionar la opción que prioriza **NVMe/USB boot** frente a microSD
4. Salir guardando cambios
5. Reiniciar

```bash
sudo reboot
```

### Verificación del orden de arranque

Tras reiniciar, revisa la configuración EEPROM:

```bash
sudo rpi-eeprom-config
```

Busca la línea `BOOT_ORDER`. El valor exacto puede variar según la versión del firmware, pero la idea es que el arranque por NVMe o almacenamiento externo quede habilitado y con prioridad adecuada.

Si `raspi-config` no ofrece la opción esperada, no fuerces edición manual de EEPROM salvo que sepas exactamente qué valor de `BOOT_ORDER` necesitas para tu versión de firmware.

## Método 1: Raspberry Pi Imager

Este método no es una clonación bit a bit. En la práctica es una **reinstalación limpia del sistema en el NVMe**, normalmente más simple y menos propensa a arrastrar problemas de una microSD temporal.

### Cuándo usarlo

- La instalación actual en microSD es mínima.
- Prefieres una base limpia en el NVMe.
- Todavía no has desplegado servicios o datos importantes.

### Flujo recomendado

1. Conecta el NVMe a un equipo desde el que puedas usar Raspberry Pi Imager.
2. Escribe en el SSD la misma edición de Raspberry Pi OS que estabas usando o la que vayas a usar como base del homelab.
3. Aplica en Imager la configuración previa necesaria:
   - usuario
   - contraseña
   - SSH habilitado
   - hostname
   - zona horaria
4. Inserta el NVMe en la carcasa de la Raspberry Pi 5.
5. Asegura que el boot order ya prioriza NVMe.
6. Arranca sin depender de la microSD o, si hace falta, con la microSD retirada para forzar la prueba real.

### Ventajas

- Evita copiar errores, particiones antiguas o ajustes provisionales.
- Suele dejar una instalación más limpia.
- Es la opción más simple si el homelab aún está en fase inicial.

### Inconvenientes

- Requiere rehacer en el NVMe cualquier ajuste que solo exista en la microSD.
- No conserva automáticamente toda la instalación previa.
- Si la carcasa es una **Argon ONE V3** y ya se instalaron los scripts de control del ventilador y botón de power, habrá que **reinstalarlos** tras el primer arranque desde NVMe (ver [02-esquema-conexiones.md](02-esquema-conexiones.md#scripts-de-la-carcasa-si-aplica)).

## Método 2: Clonación con `dd`

`dd` copia la microSD al NVMe de forma casi literal. Es útil, pero exige extremo cuidado con los nombres de dispositivo.

### Advertencias

- Un error en `if=` o `of=` puede destruir el disco equivocado.
- Si la microSD es mayor que el espacio realmente usado, también copiarás ese esquema tal cual.
- Después puede hacer falta ampliar la partición raíz para aprovechar todo el NVMe.

### 1. Identificar origen y destino

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,MODEL
```

Ejemplo típico:

- Origen: `/dev/mmcblk0`
- Destino: `/dev/nvme0n1`

### 2. Desmontar particiones del NVMe si estaban montadas

```bash
sudo umount /dev/nvme0n1p1 2>/dev/null || true
sudo umount /dev/nvme0n1p2 2>/dev/null || true
```

### 3. Ejecutar la clonación

```bash
sudo dd if=/dev/mmcblk0 of=/dev/nvme0n1 bs=64M conv=fsync,status=progress
```

Cuando termine, fuerza al kernel a releer la tabla de particiones:

```bash
sudo partprobe /dev/nvme0n1
lsblk /dev/nvme0n1
```

### 4. Ampliar el sistema de archivos si hace falta

Si el clonado deja una partición raíz más pequeña que el NVMe, usa:

```bash
sudo raspi-config
```

Ruta habitual:

1. `Advanced Options`
2. `Expand Filesystem`
3. Reiniciar

## Método 3: Migración con `rsync`

Este es el método más flexible para conservar la instalación actual sin clonar la microSD sector a sector.

### Cuándo usarlo

- Ya has configurado bastante el sistema en microSD.
- Quieres mantener usuarios, paquetes y ajustes.
- Prefieres una copia a nivel de ficheros y un esquema más limpio en el NVMe.

### Paquetes útiles

```bash
sudo apt update
sudo apt install -y rsync parted
```

### 1. Particionar el NVMe

Este ejemplo crea un esquema simple con:

- una partición FAT32 de arranque
- una partición `ext4` para raíz

```bash
sudo parted -s /dev/nvme0n1 mklabel gpt
sudo parted -s /dev/nvme0n1 mkpart primary fat32 1MiB 513MiB
sudo parted -s /dev/nvme0n1 set 1 esp on
sudo parted -s /dev/nvme0n1 mkpart primary ext4 513MiB 100%
```

### 2. Formatear las particiones

```bash
sudo mkfs.vfat -F 32 /dev/nvme0n1p1
sudo mkfs.ext4 -L rootfs /dev/nvme0n1p2
```

### 3. Montar destino

```bash
sudo mkdir -p /mnt/nvme-root
sudo mount /dev/nvme0n1p2 /mnt/nvme-root
sudo mkdir -p /mnt/nvme-root/boot/firmware
sudo mount /dev/nvme0n1p1 /mnt/nvme-root/boot/firmware
```

### 4. Copiar el sistema

```bash
sudo rsync -aAXHv \
  --exclude=/dev/* \
  --exclude=/proc/* \
  --exclude=/sys/* \
  --exclude=/tmp/* \
  --exclude=/run/* \
  --exclude=/mnt/* \
  --exclude=/media/* \
  --exclude=/lost+found \
  / /mnt/nvme-root
```

### 5. Obtener UUID del nuevo sistema

```bash
sudo blkid /dev/nvme0n1p1 /dev/nvme0n1p2
```

### 6. Ajustar `fstab` del sistema nuevo

Edita el fichero del sistema copiado:

```bash
sudo nano /mnt/nvme-root/etc/fstab
```

Contenido orientativo:

```fstab
UUID=<UUID-ROOT-NVME>  /              ext4  defaults,noatime  0  1
UUID=<UUID-BOOT-NVME>  /boot/firmware vfat  defaults          0  2
```

### 7. Ajustar la línea de arranque

En Raspberry Pi OS moderno, revisa:

```bash
sudo nano /mnt/nvme-root/boot/firmware/cmdline.txt
```

La línea debe seguir en una sola línea y apuntar al sistema raíz del NVMe, por ejemplo:

```text
console=serial0,115200 console=tty1 root=UUID=<UUID-ROOT-NVME> rootfstype=ext4 fsck.repair=yes rootwait
```

### 8. Desmontar y preparar la prueba

```bash
sudo sync
sudo umount /mnt/nvme-root/boot/firmware
sudo umount /mnt/nvme-root
```

## Retirada de la microSD

Una vez completado cualquiera de los métodos anteriores:

1. Apaga la Raspberry Pi.
2. Retira la **microSD** físicamente.
3. Deja conectado solo el **SSD NVMe** como disco de sistema.
4. Arranca de nuevo.

```bash
sudo poweroff
```

La retirada física de la microSD no es un detalle cosmético: es la prueba real de que el sistema ya no depende de ella.

## Verificación del Arranque Real desde NVMe

Después del arranque sin microSD, valida que la raíz del sistema está realmente en el SSD.

### Comprobar el dispositivo raíz

```bash
findmnt /
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL
```

Lo esperado es que `/` cuelgue de `nvme0n1p2` o equivalente, no de `mmcblk0p2`.

### Comprobar la línea de kernel activa

```bash
cat /proc/cmdline
```

Debe aparecer `root=UUID=...` o `root=PARTUUID=...` apuntando al NVMe, no a la microSD.

### Comprobar `/boot/firmware`

```bash
findmnt /boot/firmware
```

Debe montar la partición de arranque del NVMe.

### Confirmar que la microSD ya no participa

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep mmcblk0 || true
```

Si la microSD está retirada, no debería aparecer como dispositivo activo de arranque.

## Verificación Funcional Post-Migración

Antes de seguir con la fase de sistema base, comprueba:

- El host arranca varias veces seguidas sin microSD.
- `findmnt /` apunta al NVMe.
- `sudo rpi-eeprom-update` no reporta problemas de firmware pendientes por el cambio.
- La red por Ethernet funciona con normalidad.
- El SSD NVMe permanece visible y estable en `lsblk`.
- Si la carcasa es una **Argon ONE V3** y se usó Raspberry Pi Imager, los scripts de control del ventilador y botón de power están reinstalados y funcionando.

Si además ya conectaste `hd2t` y `hd5t`, verifica que siguen montando correctamente según [03-preparacion-discos.md](03-preparacion-discos.md) o [04-discos-con-datos.md](04-discos-con-datos.md).

## Problemas Habituales

### La Pi sigue arrancando desde microSD

Posibles causas:

- La microSD seguía insertada durante la prueba.
- El boot order no prioriza correctamente NVMe.
- El firmware EEPROM no estaba actualizado.
- El sistema del NVMe no quedó arrancable.

### El NVMe aparece en `lsblk` pero no arranca

Revisa:

- partición de arranque presente
- `cmdline.txt` apuntando al UUID correcto
- `fstab` del sistema nuevo
- integridad del cableado o adaptador PCIe de la carcasa

### El sistema arrancó, pero `/` sigue en `mmcblk0`

Eso significa que el sistema operativo real todavía está en la microSD y el NVMe solo está conectado como disco secundario. Repite la verificación quitando físicamente la microSD.

### `dd` dejó el NVMe con poco espacio útil

Amplía el sistema de archivos con `raspi-config` o rehace la migración con `rsync` si prefieres un esquema más limpio.

## Criterio de Cierre de Esta Fase

Da esta tarea por terminada solo si se cumplen estas condiciones:

- La Raspberry Pi 5 arranca con la **microSD retirada**.
- El sistema raíz `/` está en el **SSD NVMe**.
- El arranque es repetible tras reinicios.
- El NVMe será el disco operativo permanente del homelab.

## Siguiente Paso

Con el arranque desde NVMe verificado, el siguiente documento a completar o seguir es `docs/01-sistema/01-instalacion-os.md` si vas a rehacer la instalación base con un flujo limpio, o `docs/01-sistema/02-configuracion-inicial.md` si la migración ya dejó un sistema operativo funcional sobre el NVMe.

## Referencias

- `rpi-eeprom-update`
- `rpi-eeprom-config`
- `raspi-config`
- Raspberry Pi Imager
- `dd`
- `rsync`
- `lsblk`
- `blkid`
- `findmnt`
- `/boot/firmware/cmdline.txt`
- `/etc/fstab`
