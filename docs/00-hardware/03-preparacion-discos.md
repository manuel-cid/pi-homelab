# Preparación de Discos

## Descripción

Procedimiento para dejar listos los dos discos duros externos USB del homelab antes de montar cualquier servicio: identificación física, verificación de salud (SMART), particionado en GPT, formato `ext4`, etiquetado (`hd5t` y `hd2t`), montaje automático mediante `/etc/fstab` y estrategia de uso por disco. Todos los pasos se ejecutan **una sola vez**, durante el provisionado de la Raspberry Pi 5, y son destructivos: cualquier dato previo en los discos se perderá.

> **Recordatorio del reparto**:
> - **`hd5t`** (5 TB) → biblioteca multimedia de **Stash**, montado en `/mnt/hd5t`.
> - **`hd2t`** (2 TB) → volúmenes Docker, datos de los demás servicios, backups, swap, montado en `/mnt/hd2t`.

> **Importante**: la microSD **nunca** se usa para datos persistentes con escritura intensiva (bases de datos, logs, backups). Todo lo que escribe con frecuencia vive en `hd2t`.

---

## Requisitos previos

- Raspberry Pi 5 con Raspberry Pi OS Lite 64-bit ya instalado y accesible por SSH (`docs/01-sistema/01-instalacion-os.md`).
- Discos físicamente conectados según `docs/00-hardware/02-esquema-conexiones.md` (ambos a los puertos USB 3.0 azules).
- Usuario con permisos `sudo`.
- Paquetes necesarios:

  ```bash
  sudo apt update
  sudo apt install -y parted e2fsprogs smartmontools util-linux
  ```

  - `parted` y `util-linux` (`lsblk`, `blkid`, `wipefs`) — particionado y consulta de dispositivos.
  - `e2fsprogs` — utilidades `mkfs.ext4`, `e2label`, `tune2fs`, `fsck.ext4`.
  - `smartmontools` — `smartctl` y el demonio `smartd` para monitorización SMART.

---

## Identificación de los discos

Antes de tocar nada hay que tener absoluta certeza de **qué `/dev/sdX` corresponde a cada disco**. Confundirlos significa formatear el disco equivocado.

```bash
lsblk -o NAME,SIZE,TRAN,MODEL,SERIAL,VENDOR,MOUNTPOINT
```

Salida típica con los dos discos conectados:

```
NAME    SIZE TRAN   MODEL              SERIAL          VENDOR   MOUNTPOINT
sda     4,6T usb    My Passport 25E2   WX...           WD
sdb     1,8T usb    ST2000LM015        ZDZ...          Seagate
mmcblk0  58G                                                   /
```

Identificación recomendada combinando dos métodos:

1. **Por tamaño y modelo** (visualmente con `lsblk`).
2. **Por número de serie** del disco (impreso en la etiqueta física):

   ```bash
   sudo smartctl -i /dev/sda
   sudo smartctl -i /dev/sdb
   ```

   El campo `Serial Number` debe coincidir con el serigrafiado en la carcasa.

Una vez identificados, **anotar** qué `/dev/sdX` es `hd5t` y cuál es `hd2t`:

```bash
# Ejemplo (variará en cada equipo):
HD5T_DEV=/dev/sda
HD2T_DEV=/dev/sdb
```

> El nombre `/dev/sdX` **no es estable** entre reinicios; sirve sólo para los pasos iniciales. El montaje persistente se hará por **UUID** y/o **LABEL** en `fstab`, no por `/dev/sdX`.

---

## Verificación SMART previa

Antes de particionar conviene comprobar que los discos no vienen ya con sectores defectuosos o con la carcasa USB bloqueando SMART (problema habitual en carcasas baratas).

### 1. Comprobar que la carcasa expone SMART

```bash
sudo smartctl -i /dev/sda
sudo smartctl -i /dev/sdb
```

Debe aparecer información detallada (modelo, firmware, capacidad, soporte SMART). Si la salida dice `SMART support is: Unavailable - device lacks SMART capability` y el disco interno sí lo soporta, la carcasa USB no hace *passthrough*.

Workaround típico: forzar el tipo de dispositivo con `-d sat` (la mayoría de carcasas SATA-USB) o `-d usbjmicron`, `-d usbsunplus`, etc.:

```bash
sudo smartctl -i -d sat /dev/sda
```

Si sigue sin funcionar, sustituir la carcasa: sin SMART no se puede monitorizar fiabilidad y el disco se convierte en una caja negra.

### 2. Habilitar SMART y leer el estado de salud

```bash
sudo smartctl -s on /dev/sda
sudo smartctl -H /dev/sda
sudo smartctl -A /dev/sda
```

- `-H` debe devolver `SMART overall-health self-assessment test result: PASSED`.
- `-A` muestra los atributos: prestar atención a `Reallocated_Sector_Ct`, `Current_Pending_Sector`, `Offline_Uncorrectable` y `UDMA_CRC_Error_Count`. Cualquier valor distinto de 0 en los tres primeros, **especialmente en un disco nuevo**, es motivo para devolverlo.

### 3. Self-test corto

```bash
sudo smartctl -t short /dev/sda
sudo smartctl -t short /dev/sdb
```

Esperar 2–3 minutos y consultar el resultado:

```bash
sudo smartctl -l selftest /dev/sda
```

Debe figurar `Completed without error`. Si falla, **no continuar**: cambiar el disco antes de meter datos.

> El test corto basta para descartar fallos evidentes en discos nuevos. Un test largo (`-t long`) recorre toda la superficie y tarda varias horas en discos de varios TB; se programará periódicamente con `smartd` (ver más abajo) y no es bloqueante para el provisionado inicial.

---

## Limpieza y particionado

Cada disco tendrá **una única partición GPT** que ocupa todo el dispositivo. Esto simplifica `fstab`, evita límites de MBR y deja el filesystem responsable de la gestión interna del espacio (los backups serán un **subdirectorio** en `hd2t`, no una partición separada).

> **Aviso**: los siguientes comandos **borran cualquier dato existente**. Releer el dispositivo antes de cada `parted` / `wipefs` para no equivocarse de disco.

### 1. Desmontar y limpiar firmas previas

```bash
# Asegurarse de que el disco no está montado:
mount | grep -E "/dev/sda|/dev/sdb" || echo "Ningún disco montado"

# Borrar firmas y tablas de particiones residuales:
sudo wipefs -a /dev/sda
sudo wipefs -a /dev/sdb
```

### 2. Crear tabla GPT y partición única

```bash
sudo parted -s /dev/sda mklabel gpt
sudo parted -s /dev/sda mkpart primary ext4 0% 100%
sudo parted -s /dev/sda align-check optimal 1

sudo parted -s /dev/sdb mklabel gpt
sudo parted -s /dev/sdb mkpart primary ext4 0% 100%
sudo parted -s /dev/sdb align-check optimal 1
```

- `0% 100%` deja a `parted` elegir el offset óptimo (alineación a 1 MiB) y maximiza el aprovechamiento.
- `align-check optimal 1` confirma que la partición está alineada (importante para rendimiento en USB y SMR).

Verificar:

```bash
sudo parted /dev/sda print
sudo parted /dev/sdb print
lsblk
```

Debe aparecer una partición `sda1` y `sdb1` ocupando casi la totalidad del disco.

---

## Formato ext4 con etiqueta

`ext4` es la opción por defecto en este homelab: rendimiento sólido, soporte universal, herramientas maduras (`fsck`, `tune2fs`) y reservación de superusuario configurable. No se usa Btrfs/ZFS para mantener simplicidad y porque el almacenamiento principal es USB externo, no local.

### 1. Crear los filesystems con la etiqueta correspondiente

```bash
# hd5t (5 TB) — multimedia Stash
sudo mkfs.ext4 -L hd5t -m 1 -E lazy_itable_init=0,lazy_journal_init=0 /dev/sda1

# hd2t (2 TB) — datos de servicios + backups
sudo mkfs.ext4 -L hd2t -m 1 -E lazy_itable_init=0,lazy_journal_init=0 /dev/sdb1
```

Opciones usadas:

- `-L hd5t` / `-L hd2t`: **etiqueta** del filesystem. Permite referirse al disco por nombre (`LABEL=hd5t`) en `fstab` y en herramientas (`blkid -L hd5t`).
- `-m 1`: reduce la reserva de root del 5 % por defecto al 1 %. En discos de 5 TB el 5 % son 250 GB inutilizables, exagerado en un volumen de datos.
- `-E lazy_itable_init=0,lazy_journal_init=0`: inicializa la tabla de inodos y el journal en el momento del formateo (tarda más, pero evita el primer arranque "lento" mientras el kernel termina de inicializar el filesystem en background).

### 2. Comprobar etiquetas y UUID

```bash
sudo blkid /dev/sda1
sudo blkid /dev/sdb1
```

Salida esperada (los UUID serán distintos):

```
/dev/sda1: LABEL="hd5t" UUID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" BLOCK_SIZE="4096" TYPE="ext4" PARTUUID="..."
/dev/sdb1: LABEL="hd2t" UUID="yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" BLOCK_SIZE="4096" TYPE="ext4" PARTUUID="..."
```

**Anotar los UUID**: se usarán en `fstab`. Si se reformatea un disco en el futuro, el UUID cambia y hay que actualizar `fstab` (de ahí que también se use `LABEL` como fallback más legible).

---

## Puntos de montaje

```bash
sudo mkdir -p /mnt/hd5t /mnt/hd2t
sudo chown root:root /mnt/hd5t /mnt/hd2t
sudo chmod 755 /mnt/hd5t /mnt/hd2t
```

La estructura de subdirectorios por servicio (p. ej. `/mnt/hd2t/nextcloud/data`, `/mnt/hd2t/backups`, `/mnt/hd5t/stash/data`) se crea más adelante en `docs/01-sistema/04-estructura-directorios.md`. Aquí solo se preparan los puntos de montaje raíz.

---

## Montaje automático con `fstab`

### 1. Editar `/etc/fstab`

Añadir al final del fichero (sustituyendo los UUID por los obtenidos con `blkid`):

```fstab
# Disco multimedia Stash (5 TB)
UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  /mnt/hd5t  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10s  0  2

# Disco de servicios y backups (2 TB)
UUID=yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy  /mnt/hd2t  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10s  0  2
```

Significado de las opciones:

- `defaults` → `rw,suid,dev,exec,auto,nouser,async`.
- `noatime` → no actualiza el `atime` en cada lectura. Reduce escrituras (especialmente en multimedia, donde el `atime` no aporta nada).
- `nofail` → si el disco no está presente en el arranque, el sistema **arranca igualmente** en lugar de caer en modo *emergency*. Crítico en un homelab headless: evita quedarse sin SSH por un cable USB suelto.
- `x-systemd.device-timeout=10s` → systemd espera como máximo 10 s a que aparezca el dispositivo antes de continuar el arranque. Sin este timeout, `nofail` por sí solo puede colgar el boot hasta 90 s.
- `0` (dump) y `2` (fsck order) → `dump` no se usa; `fsck` en orden 2 (después del `/`).

> Alternativa por **etiqueta** (más legible, más frágil si se reformatea con otra label):
>
> ```fstab
> LABEL=hd5t  /mnt/hd5t  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10s  0  2
> LABEL=hd2t  /mnt/hd2t  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10s  0  2
> ```
>
> Recomendación: dejar `UUID=` y añadir un comentario con la etiqueta para localizar el disco visualmente.

### 2. Recargar systemd y montar

```bash
sudo systemctl daemon-reload
sudo mount -a
```

`mount -a` no debe devolver ningún error. Si aparece algo, **no reiniciar** hasta arreglarlo: un `fstab` mal formado puede dejar el sistema sin arrancar (con `nofail` el riesgo es menor, pero los typos en rutas o UUID provocan errores ruidosos).

### 3. Verificar

```bash
mount | grep -E "hd5t|hd2t"
df -hT /mnt/hd5t /mnt/hd2t
lsblk -o NAME,SIZE,LABEL,UUID,MOUNTPOINT
```

Resultado esperado:

```
/dev/sda1 on /mnt/hd5t type ext4 (rw,noatime, ...)
/dev/sdb1 on /mnt/hd2t type ext4 (rw,noatime, ...)
```

### 4. Reiniciar y comprobar persistencia

```bash
sudo reboot
```

Tras el reinicio, repetir `df -hT /mnt/hd5t /mnt/hd2t`. Ambos deben aparecer montados sin intervención manual.

---

## Estrategia de uso por disco

### `hd5t` (5 TB) — Multimedia de Stash

- **Propósito único**: alojar la biblioteca multimedia consumida por **Stash** (`docs/09-multimedia/05-stash.md`).
- **Patrón de acceso**: muchas lecturas secuenciales (streaming), pocas escrituras (importaciones puntuales). `noatime` es ideal para este perfil.
- **No** se usa para volúmenes Docker ni bases de datos: si se llena `hd5t`, el resto del homelab sigue funcionando con normalidad.
- **No** se usa como destino de backups: el contenido de `hd5t` es reemplazable y voluminoso, no se respalda en el propio Pi (puede copiarse manualmente a otro disco si se desea).

Estructura prevista (creada en `docs/01-sistema/04-estructura-directorios.md`):

```
/mnt/hd5t/
└── stash/
    └── data/
```

### `hd2t` (2 TB) — Servicios, datos persistentes y backups

- Aloja **todos los volúmenes Docker** con datos persistentes: bases de datos, uploads, logs, configuración generada por las apps, multimedia secundaria (Jellyfin, Navidrome, Audiobookshelf, Calibre-Web), descargas (*arr + Transmission), Paperless, Nextcloud, etc.
- Aloja **la zona de backups** Borgmatic en `/mnt/hd2t/backups/` (ver `docs/07-backups/02-borgmatic.md`). Usar un subdirectorio en lugar de una partición separada permite reasignar espacio entre datos y backups sin reformatear.
- Aloja también el **swap del sistema** (`docs/01-sistema/02-configuracion-inicial.md`), para evitar desgaste de la microSD.
- El reparto interno de espacio se controla con cuotas a nivel de aplicación (p. ej. retención en Borg, límite de tamaño en Nextcloud) y monitorización en Prometheus/Grafana.

Estructura prevista:

```
/mnt/hd2t/
├── nextcloud/
├── postgres/
├── jellyfin/
├── paperless/
├── vaultwarden/
├── pihole/
├── backups/
└── ...
```

---

## Monitorización SMART continua

Las pruebas previas son puntuales. En operación 24/7 hay que detectar degradación temprana de los discos automáticamente.

### 1. Activar `smartd`

`smartmontools` instala el demonio `smartd`. Configurarlo para vigilar ambos discos:

```bash
sudo nano /etc/smartd.conf
```

Comentar la línea por defecto `DEVICESCAN ...` y añadir:

```
# hd5t — test corto cada lunes 03:00, test largo el primer domingo de mes 04:00
/dev/disk/by-label/hd5t -a -o on -S on -s (S/../.././03|L/../(01|02|03|04|05|06|07)/7/04) -m root

# hd2t — test corto cada martes 03:00, test largo el segundo domingo de mes 04:00
/dev/disk/by-label/hd2t -a -o on -S on -s (S/../.././03|L/../(08|09|10|11|12|13|14)/7/04) -m root
```

Significado:

- `-a`: comprobaciones por defecto (errores, atributos, self-tests).
- `-o on -S on`: activa offline data collection y autosave de atributos.
- `-s "S/.../03|L/.../04"`: programa **S**elf-test corto (hora 03) y **L**argo mensual (hora 04), escalonando hd5t y hd2t para no solaparlos.
- `-m root`: notifica por correo local. Para alertas reales se canalizará al stack de monitorización (Uptime Kuma / Grafana Alerting) en la Fase 5.

Reiniciar el demonio:

```bash
sudo systemctl restart smartd
sudo systemctl enable smartd
sudo systemctl status smartd
```

### 2. Comprobaciones manuales periódicas

Dentro del mantenimiento periódico (`docs/13-operaciones/01-mantenimiento-periodico.md`) se incluirá una revisión mensual:

```bash
sudo smartctl -H /dev/disk/by-label/hd5t
sudo smartctl -H /dev/disk/by-label/hd2t
sudo smartctl -A /dev/disk/by-label/hd5t | grep -E "Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error_Count"
sudo smartctl -A /dev/disk/by-label/hd2t | grep -E "Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error_Count"
sudo smartctl -l selftest /dev/disk/by-label/hd5t | head
sudo smartctl -l selftest /dev/disk/by-label/hd2t | head
```

Cualquier subida en los contadores de sectores reasignados / pendientes / no corregibles → planificar reemplazo del disco antes de que falle.

---

## Verificación final

Antes de continuar con las siguientes fases, comprobar:

- [ ] `lsblk` muestra `sda1` y `sdb1` montados en `/mnt/hd5t` y `/mnt/hd2t`.
- [ ] `blkid` muestra etiquetas `hd5t` y `hd2t`, ambos `TYPE="ext4"`.
- [ ] `df -hT /mnt/hd5t /mnt/hd2t` muestra el tamaño correcto y uso ~0 %.
- [ ] Tras `sudo reboot`, los dos discos están de nuevo montados sin intervención.
- [ ] `sudo smartctl -H` devuelve `PASSED` en los dos discos.
- [ ] `systemctl status smartd` activo y sin errores.
- [ ] `dmesg | grep -iE "usb|sda|sdb"` no muestra `error -71`, resets de USB ni desmontajes inesperados.

---

## Troubleshooting

### El disco aparece y desaparece (`usb X-1: device descriptor read/64, error -71`)

Síntoma típico de **sub-alimentación** del bus USB:

- Verificar que se está usando la **fuente oficial 27 W** de la Pi 5 y un cable USB-C de calidad (ver `docs/00-hardware/02-esquema-conexiones.md`).
- Si el problema persiste con `hd2t` (autoalimentado por USB), intercalar un **hub USB 3.0 con alimentación externa** entre la Pi y el disco.
- Comprobar `dmesg -w` mientras se conecta el disco: revela si el kernel lo expulsa por consumo o por errores de protocolo.

### `smartctl` dice "device lacks SMART capability"

La carcasa USB no hace passthrough. Probar:

```bash
sudo smartctl -d sat -i /dev/sda
sudo smartctl -d usbjmicron -i /dev/sda
sudo smartctl -d usbsunplus -i /dev/sda
```

Si ninguna combinación devuelve datos, sustituir la carcasa por una compatible (Sabrent EC-UASP, Inateck FE2011, etc.).

### Rendimiento USB pobre o cuelgues bajo carga

El driver UAS funciona bien en la mayoría de carcasas modernas, pero algunas tienen firmware defectuoso y rinden mejor en modo `usb-storage` clásico. Síntoma: el disco se "congela" durante segundos bajo I/O sostenido. Solución: blacklistear UAS para ese controlador concreto añadiendo a `/boot/firmware/cmdline.txt` (Pi OS Bookworm) la opción `usb-storage.quirks=VID:PID:u`, donde `VID:PID` se obtiene con `lsusb`.

### Pi no arranca tras editar `fstab`

Con `nofail,x-systemd.device-timeout=10s` el riesgo es bajo, pero si el sistema cae a *emergency mode*:

- Conectar HDMI + teclado.
- Login como root.
- Montar `/` en lectura/escritura: `mount -o remount,rw /`.
- Editar `/etc/fstab`, comentar las líneas problemáticas.
- `sudo reboot`.

### Etiqueta o UUID duplicados

Si en algún momento se reformatean los discos sin actualizar `fstab` y se mezclan etiquetas, `mount -a` fallará. Recuperar UUID/LABEL actuales con `blkid` y reescribir `fstab` con los valores reales antes de reiniciar.

### El disco se desmonta solo por inactividad

Algunas carcasas USB ponen el disco en *spin-down* tras unos minutos sin actividad y la Pi lo termina expulsando. Mitigar con `hdparm -B` para desactivar APM agresivo, o mantener una tarea ligera (p. ej. el propio Prometheus escribiendo métricas en `hd2t`) que evite el spin-down.

---

## Referencias

- Manual de `parted`: <https://www.gnu.org/software/parted/manual/parted.html>
- `mkfs.ext4` (man-pages): <https://man7.org/linux/man-pages/man8/mke2fs.8.html>
- `tune2fs` (man-pages): <https://man7.org/linux/man-pages/man8/tune2fs.8.html>
- `fstab` y opciones de montaje: <https://man7.org/linux/man-pages/man5/fstab.5.html>
- Opciones systemd para puntos de montaje (`x-systemd.*`): <https://www.freedesktop.org/software/systemd/man/systemd.mount.html>
- `smartmontools` y `smartd`: <https://www.smartmontools.org/>
- Configuración de `smartd.conf`: <https://www.smartmontools.org/browser/trunk/smartmontools/smartd.conf.5.in>
- Quirks USB en Linux (UAS / usb-storage): <https://www.kernel.org/doc/html/latest/usb/usb-help.html>
- Raspberry Pi 5 — Notas sobre USB y alimentación: <https://www.raspberrypi.com/documentation/computers/raspberry-pi-5.html>
