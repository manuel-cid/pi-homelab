# Discos con Datos Existentes

## Descripción

Procedimiento para incorporar al homelab discos USB que **ya contienen datos** y que **no deben formatearse**. El objetivo es identificar cada unidad con seguridad, comprobar su estado de salud, validar la integridad del sistema de archivos y dejar el montaje automático funcionando en la Raspberry Pi 5 sin perder contenido.

Este documento cubre los casos habituales de reutilización de discos en **ext4**, **NTFS** y **exFAT**. La conexión física previa se describe en [02-esquema-conexiones.md](02-esquema-conexiones.md), la preparación de discos vacíos en [03-preparacion-discos.md](03-preparacion-discos.md) y el arranque definitivo desde el SSD en [05-arranque-nvme.md](05-arranque-nvme.md).

## Requisitos Previos

- Haber completado o validado [01-material-necesario.md](01-material-necesario.md).
- Tener conectados físicamente el **SSD NVMe**, **`hd2t`** y **`hd5t`** según [02-esquema-conexiones.md](02-esquema-conexiones.md).
- Arrancar con **Raspberry Pi OS Lite 64-bit** y disponer de acceso por terminal con un usuario con permisos de `sudo`.
- Si la carcasa es una **Argon ONE V3**, haber instalado los scripts de control del ventilador y botón de power según se indica en [02-esquema-conexiones.md](02-esquema-conexiones.md#scripts-de-la-carcasa-si-aplica).
- Confirmar qué disco reutilizado será **`hd2t`** y cuál será **`hd5t`** según su contenido real.
- Asumir que en esta fase **no se reformatea nada**.

## Cuándo Usar Este Documento

Usa este procedimiento si se cumple cualquiera de estas condiciones:

- El disco ya contiene biblioteca multimedia, descargas antiguas o copias de seguridad que se deben conservar.
- El disco viene de otro PC, NAS o Raspberry Pi y quieres montarlo tal cual.
- El sistema de archivos actual es **ext4**, **NTFS** o **exFAT** y prefieres posponer una migración a `ext4`.

Si el disco puede borrarse por completo, el flujo correcto es [03-preparacion-discos.md](03-preparacion-discos.md).

## Estrategia Recomendada

Aunque el homelab está pensado para trabajar idealmente con discos USB en **ext4**, reutilizar discos con datos existentes es perfectamente válido si primero se verifica su estado.

### Reparto previsto

- **`hd2t`**: multimedia general, descargas y backups.
- **`hd5t`**: biblioteca multimedia dedicada de Stash.

### Criterio operativo

- Mantén el **SSD NVMe** para sistema, Docker, configuraciones, bases de datos y volúmenes persistentes.
- Usa los discos reutilizados solo para datos grandes: bibliotecas, descargas y backups.
- Si un disco con datos está en **NTFS** o **exFAT**, puede seguir así al principio, pero para uso permanente en Linux **ext4** sigue siendo la mejor opción a medio plazo.
- Para discos con datos existentes, identifica el montaje en `fstab` por **UUID**, no por nombre de dispositivo.

## Paquetes Necesarios

Instala herramientas de diagnóstico y soporte para sistemas de archivos reutilizados:

```bash
sudo apt update
sudo apt install -y smartmontools util-linux e2fsprogs exfatprogs ntfs-3g
```

## Identificación Segura de las Unidades

Antes de montar nada, identifica los discos por **modelo, tamaño, partición y sistema de archivos**.

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINT,MODEL
sudo blkid
findmnt -D
```

Puntos importantes:

- El **NVMe** aparecerá normalmente como `/dev/nvme0n1`.
- Los discos USB suelen aparecer como `/dev/sda`, `/dev/sdb` y sus particiones como `/dev/sda1`, `/dev/sdb1`.
- **No confíes en `/dev/sdX`** como identificador estable: puede cambiar entre reinicios o reconexiones.
- Verifica siempre tamaño, modelo y sistema de archivos antes de continuar.

Si quieres más detalle de una unidad concreta:

```bash
udevadm info --query=all --name=/dev/sda
udevadm info --query=all --name=/dev/sdb
```

## Comprobación SMART

Antes de usar un disco que ya contiene datos, comprueba su salud básica.

### Información SMART

```bash
sudo smartctl -i /dev/sda
sudo smartctl -i /dev/sdb
```

En algunas carcasas USB puede hacer falta indicar el tipo de bridge:

```bash
sudo smartctl -d sat -i /dev/sda
sudo smartctl -d sat -i /dev/sdb
```

### Prueba corta

```bash
sudo smartctl -t short /dev/sda
sudo smartctl -t short /dev/sdb
```

Espera el tiempo indicado y revisa el resultado:

```bash
sudo smartctl -a /dev/sda
sudo smartctl -a /dev/sdb
```

No incorpores al homelab un disco que muestre cualquiera de estas señales:

- Errores de lectura o escritura recurrentes.
- Sectores reasignados en aumento.
- Fallos de autoevaluación SMART.
- Desconexiones USB frecuentes bajo carga.

## Comprobación de Integridad del Sistema de Archivos

Haz esta comprobación **con la partición desmontada**. Si el escritorio o el automontaje la ha montado, desmonta primero:

```bash
sudo umount /dev/sda1 2>/dev/null || true
sudo umount /dev/sdb1 2>/dev/null || true
```

### Si el disco es `ext4`

```bash
sudo e2fsck -f /dev/sda1
sudo e2fsck -f /dev/sdb1
```

`e2fsck` es la verificación correcta para particiones Linux nativas. Si encuentra errores, deja que los repare antes de montar el disco en producción.

### Si el disco es `NTFS`

```bash
sudo ntfsfix /dev/sda1
sudo ntfsfix /dev/sdb1
```

Consideraciones importantes:

- `ntfsfix` corrige problemas básicos, pero **no sustituye** a `chkdsk` de Windows.
- Si el volumen quedó marcado como hibernado o sucio, conecta el disco a un Windows y ejecuta una comprobación completa antes de seguir.
- Si el disco viene de Windows, desactiva **Fast Startup** o cualquier cierre híbrido para evitar montajes problemáticos en Linux.

### Si el disco es `exFAT`

```bash
sudo fsck.exfat /dev/sda1
sudo fsck.exfat /dev/sdb1
```

`exFAT` es útil para compatibilidad entre sistemas, pero ofrece menos garantías operativas que `ext4` en un host Linux 24/7.

## Elección del Punto de Montaje

Mantén la misma estructura del resto del homelab:

```bash
sudo mkdir -p /media/hd2t
sudo mkdir -p /media/hd5t
```

La recomendación es:

- Montar el disco reutilizado que hará de **`hd2t`** en `/media/hd2t`.
- Montar el disco reutilizado que hará de **`hd5t`** en `/media/hd5t`.

No hace falta que la etiqueta original del volumen coincida con `hd2t` o `hd5t` si usas **UUID** en `fstab`.

Si el disco ya contiene datos con otra estructura, no hace falta reorganizarlo en esta fase. Aun así, para que los servicios del homelab puedan reutilizar rutas coherentes más adelante, conviene validar si el contenido ya encaja con la estructura objetivo:

- **`hd2t`**: `/media/hd2t/media/video`, `/media/hd2t/media/music`, `/media/hd2t/media/audiobooks`, `/media/hd2t/media/books`, `/media/hd2t/downloads`, `/media/hd2t/backups`
- **`hd5t`**: `/media/hd5t/media/`

<!-- TODO: verificar si los datos heredados ya siguen la estructura esperada por los futuros `docker-compose.yml` o si habrá que adaptar rutas de biblioteca al desplegar cada servicio. -->

## Montaje Manual de Prueba

Antes de editar `fstab`, monta cada disco manualmente y valida que el contenido esperado aparece.

Primero localiza el UUID:

```bash
sudo blkid /dev/sda1 /dev/sdb1
```

### Ejemplo para `ext4`

```bash
sudo mount -t ext4 /dev/sda1 /media/hd2t
sudo mount -t ext4 /dev/sdb1 /media/hd5t
```

### Ejemplo para `NTFS`

Primero obtén el UID/GID reales del usuario operativo:

```bash
id -u
id -g
```

Si el kernel soporta `ntfs3`, usa esta opción:

```bash
sudo mount -t ntfs3 /dev/sda1 /media/hd2t
sudo mount -t ntfs3 /dev/sdb1 /media/hd5t
```

Si `ntfs3` no está disponible, usa el fallback:

```bash
sudo mount -t ntfs-3g /dev/sda1 /media/hd2t
sudo mount -t ntfs-3g /dev/sdb1 /media/hd5t
```

### Ejemplo para `exFAT`

```bash
sudo mount -t exfat /dev/sda1 /media/hd2t
sudo mount -t exfat /dev/sdb1 /media/hd5t
```

### Verificación

```bash
df -h | grep -E 'hd2t|hd5t'
ls -la /media/hd2t
ls -la /media/hd5t
```

Valida estas tres cosas:

- El tamaño del disco coincide con el esperado.
- El contenido visible es el correcto.
- No aparecen errores de permisos o lectura en `dmesg`.

Consulta eventos recientes si algo falla:

```bash
dmesg | tail -n 50
```

Cuando termines la prueba manual:

```bash
sudo umount /media/hd2t
sudo umount /media/hd5t
```

## Montaje Automático con `fstab`

Haz copia de seguridad antes de editar:

```bash
sudo cp /etc/fstab /etc/fstab.bak
```

### Regla general

- Usa **UUID** para evitar depender de `/dev/sdX`.
- Usa `nofail` para que la Raspberry Pi pueda arrancar aunque un disco no esté presente.
- Usa `x-systemd.device-timeout=10` para evitar esperas largas si la unidad no responde.

### Ejemplo para `ext4`

```fstab
UUID=AAAA-BBBB-CCCC-DDDD  /media/hd2t  ext4   defaults,nofail,noatime,x-systemd.device-timeout=10  0  2
UUID=EEEE-FFFF-GGGG-HHHH  /media/hd5t  ext4   defaults,nofail,noatime,x-systemd.device-timeout=10  0  2
```

### Ejemplo para `NTFS`

Con driver `ntfs3`:

```fstab
UUID=AAAA-BBBB  /media/hd2t  ntfs3   uid=<uid>,gid=<gid>,umask=002,nofail,noatime,x-systemd.device-timeout=10  0  0
UUID=CCCC-DDDD  /media/hd5t  ntfs3   uid=<uid>,gid=<gid>,umask=002,nofail,noatime,x-systemd.device-timeout=10  0  0
```

Fallback con `ntfs-3g`:

```fstab
UUID=AAAA-BBBB  /media/hd2t  ntfs-3g  uid=<uid>,gid=<gid>,umask=002,nofail,noatime,x-systemd.device-timeout=10  0  0
UUID=CCCC-DDDD  /media/hd5t  ntfs-3g  uid=<uid>,gid=<gid>,umask=002,nofail,noatime,x-systemd.device-timeout=10  0  0
```

### Ejemplo para `exFAT`

```fstab
UUID=AAAA-BBBB  /media/hd2t  exfat  uid=<uid>,gid=<gid>,umask=002,nofail,noatime,x-systemd.device-timeout=10  0  0
UUID=CCCC-DDDD  /media/hd5t  exfat  uid=<uid>,gid=<gid>,umask=002,nofail,noatime,x-systemd.device-timeout=10  0  0
```

### Validación inmediata

Después de guardar `fstab`, comprueba el resultado sin reiniciar:

```bash
sudo mount -a
findmnt /media/hd2t
findmnt /media/hd5t
```

Si `mount -a` no devuelve errores, el montaje persistente está listo.

## Permisos y Propiedad

El tratamiento de permisos depende del sistema de archivos.

### Si el disco es `ext4`

`ext4` sí guarda permisos y propietarios Linux reales. Después de montar:

```bash
sudo chown -R $USER:$USER /media/hd2t
sudo chown -R $USER:$USER /media/hd5t
```

Haz esto solo si el contenido debe quedar gestionado por tu usuario operativo. Si ya existe una estructura con permisos deliberados, revisa antes de aplicar cambios recursivos.

### Si el disco es `NTFS` o `exFAT`

Estos sistemas de archivos no manejan permisos Linux de la misma forma. El control se hace en el propio montaje con:

- `uid=<uid>`
- `gid=<gid>`
- `umask=002`

Eso deja los archivos accesibles para el usuario principal y su grupo, que suele ser suficiente para bibliotecas multimedia y directorios compartidos con contenedores.

Sustituye esos valores por el UID/GID reales de tu usuario operativo (`id -u` y `id -g`). Si más adelante usas un UID/GID distinto para Docker, ajusta también esos valores en `fstab` para que coincidan con el usuario efectivo de los contenedores.

## Recomendaciones Operativas

- Si un disco reutilizado está en **NTFS** o **exFAT** y va a quedarse conectado de forma permanente a la Raspberry Pi, planifica una migración futura a `ext4` cuando tengas backup.
- No guardes bases de datos ni volúmenes críticos de Docker en un disco USB heredado por comodidad; mantenlos en el **SSD NVMe**.
- Si un disco tarda mucho en despertarse, `nofail` evitará bloquear el arranque, pero no corrige problemas físicos o de alimentación.
- Si detectas errores intermitentes, revisa primero cable USB, caja del disco y alimentación antes de tocar `fstab`.

## Verificación Final

Antes de dar por integrado el disco, comprueba:

- `lsblk -f` muestra cada partición con su sistema de archivos y punto de montaje correcto.
- `findmnt /media/hd2t` y `findmnt /media/hd5t` devuelven la unidad esperada.
- El contenido visible coincide con la biblioteca real que querías conservar.
- No hay errores recientes en `dmesg`.
- El sistema reinicia correctamente y vuelve a montar ambos discos.

## Solución de Problemas

### Los discos USB no aparecen en `lsblk`

Si al ejecutar `lsblk` los discos USB no aparecen como `/dev/sda` o `/dev/sdb`, comprueba primero si el kernel los ha detectado por USB:

```bash
lsusb
dmesg | grep -iE 'usb|sd[a-z]' | tail -30
```

#### Caso más habitual: over-current / alimentación insuficiente

Si en la salida de `dmesg` ves mensajes como:

```
usb usb3-port1: over-current change #N
sd X:0:0:0: [sdX] Spinning up disk...
sd X:0:0:0: [sdX] tag#N uas_eh_abort_handler
```

El problema es que la Raspberry Pi 5 **limita por defecto la corriente USB a 600 mA** en total para todos los puertos. Dos discos mecánicos necesitan mucho más que eso, especialmente durante el arranque (spin-up), y la Pi corta la alimentación por protección.

**Solución**: si tu carcasa o tu montaje lo requieren, habilitar la entrega de alta corriente USB añadiendo `usb_max_current_enable=1` en `/boot/firmware/config.txt`. Esto requiere una fuente de alimentación de al menos **5 V / 5 A** (la fuente oficial de la Raspberry Pi 5).

<!-- TODO: verificar en la carcasa/controladora USB concreta si `usb_max_current_enable=1` sigue siendo necesario en Raspberry Pi 5 o si ya viene resuelto por firmware o scripts del fabricante. -->

Si la carcasa es una **Argon ONE V3** y ya se instalaron los scripts del fabricante según [02-esquema-conexiones.md](02-esquema-conexiones.md#scripts-de-la-carcasa-si-aplica), esta línea **ya se añadió automáticamente**. Verifica que existe:

```bash
grep usb_max_current_enable /boot/firmware/config.txt
```

Si aparece `usb_max_current_enable=1`, solo necesitas reiniciar para que surta efecto (si no lo has hecho tras instalar el script):

```bash
sudo reboot
```

Si la línea **no** está presente (carcasas sin script de Argon u otros modelos), añádela manualmente:

```bash
sudo cp /boot/firmware/config.txt /boot/firmware/config.txt.bak
echo 'usb_max_current_enable=1' | sudo tee -a /boot/firmware/config.txt
sudo reboot
```

Tras el reinicio, comprueba que los discos ya aparecen:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINT,MODEL
```

## Siguiente Paso

Con los discos reutilizados ya validados y montados, el siguiente documento a completar o seguir es [05-arranque-nvme.md](05-arranque-nvme.md), donde se documenta el arranque definitivo desde el SSD NVMe.

## Referencias

- `smartctl`
- `lsblk`
- `blkid`
- `e2fsck`
- `ntfsfix`
- `fsck.exfat`
- `/etc/fstab`
