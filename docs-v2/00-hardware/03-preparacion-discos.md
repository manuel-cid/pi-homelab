# Preparación de Discos

## Descripción

Procedimiento de **preparación de los dos discos duros externos** (`hd5t` de 5 TB y `hd2t` de 2 TB) que sostienen todos los datos persistentes del homelab. Este documento cubre, en este orden:

1. **Verificación de salud** del hardware con SMART antes de confiar datos al disco.
2. **Particionado** con tabla GPT y una única partición que ocupe todo el disco.
3. **Formato** con `ext4` y etiqueta de volumen (`hd5t` / `hd2t`).
4. **Montaje persistente** vía `/etc/fstab` en `/mnt/hd5t` y `/mnt/hd2t`.
5. **Estrategia de uso** de cada disco dentro del homelab.

> **Importante**: este procedimiento **borra por completo** el contenido previo de cada disco. Los HDDs externos vienen normalmente con una partición NTFS o exFAT con software del fabricante; ese contenido se descarta porque el homelab los va a usar como almacenamiento Linux nativo.

> **Recordatorio**: el homelab opera en **LAN + Tailscale**. Los discos no se exponen por red en este punto; cualquier compartición (Samba, Nextcloud, Jellyfin) se configura más adelante en sus propias fases.

---

## Requisitos Previos

- Raspberry Pi 5 cableada según [`02-esquema-conexiones.md`](./02-esquema-conexiones.md), con ambos discos conectados a sendos puertos **USB 3.0 (azules)**.
- Raspberry Pi OS Lite 64-bit instalado y accesible por SSH (cubierto en `docs/01-sistema/01-instalacion-os.md`). Este documento se ejecuta tras el primer arranque, antes de instalar Docker.
- Usuario con permisos `sudo`.
- Conexión a internet para instalar `smartmontools` y `parted` desde los repositorios.
- `dmesg | tail` y `lsblk` no muestran resets ni desconexiones recientes de los puertos USB (si los hay, volver a la sección de cableado en `02-esquema-conexiones.md` antes de tocar los discos).

### Paquetes necesarios

```bash
sudo apt update
sudo apt install -y smartmontools parted e2fsprogs
```

- `smartmontools` proporciona `smartctl` para leer SMART y lanzar autotests.
- `parted` se usa para crear la tabla de particiones GPT (necesario para el disco de 5 TB, que excede el límite MBR de 2 TiB).
- `e2fsprogs` ya viene de serie en Raspberry Pi OS, pero se asegura para `mkfs.ext4`, `tune2fs` y `e2label`.

---

## 1. Identificación de los discos

Antes de tocar nada, hay que identificar **qué dispositivo `/dev/sdX` corresponde a cada disco físico**, porque el orden depende del puerto USB y del orden de detección. Confundirlos implica formatear el equivocado.

```bash
lsblk -o NAME,SIZE,TRAN,MODEL,SERIAL,LABEL,MOUNTPOINT
```

Salida esperada (ejemplo, los nombres pueden variar):

```
NAME    SIZE TRAN   MODEL              SERIAL          LABEL MOUNTPOINT
sda     4.6T usb    Elements_25A3      WX...           
sdb     1.8T usb    Expansion          NA...           
mmcblk0  59G                                          
└─...                                                  /
```

- El disco de **~4.6 TiB** (5 TB nominales) será `hd5t`.
- El disco de **~1.8 TiB** (2 TB nominales) será `hd2t`.
- Apuntar el `SERIAL` de cada uno: sirve de doble verificación si se vuelven a conectar en otro orden y permite identificarlos en los informes SMART.

> Trabajar siempre con la **ruta estable** `/dev/disk/by-id/usb-<modelo>-<serial>` cuando sea posible, ya que `/dev/sda` y `/dev/sdb` pueden intercambiarse entre arranques. Para ver los enlaces estables:
>
> ```bash
> ls -l /dev/disk/by-id/ | grep -v part
> ```

A partir de aquí los ejemplos usan `/dev/sdX` como marcador de posición. **Sustituir por el dispositivo correcto en cada paso** y nunca ejecutar los comandos a ciegas.

---

## 2. Verificación de salud SMART (pre-formato)

Comprobar el estado SMART **antes** de invertir tiempo en formatear y poblar de datos. Si un disco viene defectuoso de fábrica, conviene devolverlo en este momento.

### 2.1. Estado y atributos básicos

```bash
sudo smartctl -i /dev/sdX        # información del dispositivo
sudo smartctl -H /dev/sdX        # health summary (PASSED/FAILED)
sudo smartctl -A /dev/sdX        # atributos SMART completos
```

Si `smartctl -i` indica que **SMART no está disponible** porque el adaptador USB-SATA del HDD no lo expone, probar:

```bash
sudo smartctl -i -d sat /dev/sdX
sudo smartctl -i -d usbjmicron /dev/sdX
sudo smartctl -i -d usbsunplus /dev/sdX
```

Algunas carcasas USB necesitan el flag `-d sat` para que `smartctl` hable directamente con la unidad SATA interna. Una vez identificado el flag correcto, conviene anotarlo para usarlo en todos los comandos posteriores y en el cron de monitorización de la Fase 5.

### 2.2. Atributos críticos a revisar

En la salida de `smartctl -A`, vigilar especialmente:

| Atributo | Valor aceptable en disco nuevo |
|---|---|
| `Reallocated_Sector_Ct` | **0** |
| `Current_Pending_Sector` | **0** |
| `Offline_Uncorrectable` | **0** |
| `Power_On_Hours` | Pocas horas (<100). Valores muy altos en un disco "nuevo" sugieren refurbished. |
| `UDMA_CRC_Error_Count` | 0–pocos. Muchos errores indican cable o hub USB defectuoso. |

### 2.3. Self-test corto

Lanzar un autotest rápido (~2 minutos) en cada disco:

```bash
sudo smartctl -t short /dev/sdX
# esperar ~2 minutos
sudo smartctl -l selftest /dev/sdX
```

El resultado debe ser `Completed without error`.

### 2.4. Self-test largo (opcional pero recomendado en este momento)

El test largo recorre toda la superficie del disco y tarda **varias horas** (en torno a 8–12 h para 5 TB y 4–6 h para 2 TB). Es el mejor momento para hacerlo: aún no hay datos y la Pi puede dejarse trabajando sin servicios encima.

```bash
sudo smartctl -t long /dev/sdX
sudo smartctl -l selftest /dev/sdX   # consultar progreso/resultado
```

Si el long test reporta errores, **no continuar con el formateo**: el disco no es fiable para datos persistentes.

---

## 3. Particionado (GPT, una partición por disco)

Se crea una **tabla GPT** y una **única partición** que ocupa el 100 % del disco. GPT es obligatorio para el disco de 5 TB (MBR no admite particiones >2 TiB) y se usa también en el de 2 TB por consistencia.

> **Antes de cada comando de particionado/formato, verificar dos veces** que `/dev/sdX` es el disco correcto con `lsblk` y con el `SERIAL` apuntado en el paso 1.

### 3.1. Desmontar si estuviera montado

Si el disco se hubiera montado automáticamente al conectarlo (raro en Raspberry Pi OS Lite, pero posible si tiene una partición conocida), desmontarlo primero:

```bash
sudo umount /dev/sdX*  2>/dev/null || true
```

### 3.2. Crear tabla GPT y partición única

```bash
sudo parted -s /dev/sdX mklabel gpt
sudo parted -s -a optimal /dev/sdX mkpart primary ext4 0% 100%
sudo partprobe /dev/sdX
```

- `mklabel gpt` crea la tabla GPT (destruye la previa).
- `mkpart primary ext4 0% 100%` crea una única partición que ocupa todo el disco, alineada de forma óptima.
- `partprobe` informa al kernel de la nueva tabla sin necesidad de reiniciar.

Tras ejecutarlo, `lsblk` debe mostrar `/dev/sdX1` como hijo de `/dev/sdX`.

---

## 4. Formato ext4 con etiqueta

Se formatea cada partición con `ext4` y se le asigna su **etiqueta de volumen** (`hd5t` o `hd2t`), que es el identificador estable que se usa después en `fstab`.

### 4.1. `hd5t` (5 TB — multimedia Stash)

```bash
sudo mkfs.ext4 -L hd5t -m 1 -E lazy_itable_init=0,lazy_journal_init=0 /dev/sdX1
```

### 4.2. `hd2t` (2 TB — servicios + backups)

```bash
sudo mkfs.ext4 -L hd2t -m 1 -E lazy_itable_init=0,lazy_journal_init=0 /dev/sdX1
```

Notas sobre las opciones:

- `-L hd5t` / `-L hd2t`: asigna la etiqueta de volumen. Las etiquetas ext4 admiten hasta 16 caracteres.
- `-m 1`: reserva solo el **1 %** del espacio para `root` (frente al 5 % por defecto). En un disco de datos sin SO no tiene sentido reservar 5 %; con un 1 % basta de margen para evitar que el disco se llene del todo y rompa servicios.
- `-E lazy_itable_init=0,lazy_journal_init=0`: inicializa la tabla de inodos y el journal **en este momento** en lugar de en background tras el primer montaje. Hace que `mkfs` tarde más, pero evita una caída de rendimiento durante varias horas la primera vez que se escribe en el disco.

### 4.3. Verificar etiqueta y UUID

```bash
sudo blkid /dev/sdX1
```

Debe mostrar algo como:

```
/dev/sdX1: LABEL="hd5t" UUID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" TYPE="ext4" PARTUUID="..."
```

Apuntar **etiqueta**, **UUID** y **PARTUUID** de cada disco. La etiqueta es la que se usa en `fstab` por defecto en este homelab; el UUID se documenta como respaldo por si en el futuro se decide migrar a montaje por UUID (más rígido pero también más opaco).

---

## 5. Puntos de montaje y `fstab`

### 5.1. Crear los puntos de montaje

```bash
sudo mkdir -p /mnt/hd5t /mnt/hd2t
```

La **estructura de subdirectorios** dentro de cada punto de montaje (carpetas por servicio, volúmenes Docker, carpeta de backups) **no** se crea aquí. Se define en [`docs/01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md), una vez fijada la convención global.

### 5.2. Editar `/etc/fstab`

Hacer copia de seguridad antes de tocar `fstab`:

```bash
sudo cp /etc/fstab /etc/fstab.bak
```

Añadir al final de `/etc/fstab` las siguientes líneas:

```fstab
# Discos externos del homelab (montaje por LABEL)
LABEL=hd5t  /mnt/hd5t  ext4  defaults,nofail,noatime,x-systemd.device-timeout=15  0  2
LABEL=hd2t  /mnt/hd2t  ext4  defaults,nofail,noatime,x-systemd.device-timeout=15  0  2
```

Justificación de cada opción:

- `LABEL=...`: monta por etiqueta. Coherente con el resto del proyecto (`hd5t`, `hd2t`) y resiste cambios de orden de detección USB.
- `defaults`: equivale a `rw,suid,dev,exec,auto,nouser,async`. Adecuado para un disco de datos.
- `nofail`: **crítico**. Si un disco está desconectado durante el arranque, el sistema continúa en lugar de caer en modo emergencia. Sin `nofail`, una desconexión puntual de un HDD bloquea el arranque entero de la Pi.
- `noatime`: no actualiza el timestamp de acceso en cada lectura. Reduce escrituras y mejora rendimiento, especialmente con bibliotecas grandes como las de Jellyfin o Stash.
- `x-systemd.device-timeout=15`: si el dispositivo no aparece en 15 s durante el arranque, systemd no espera más y continúa (junto con `nofail`).
- Campo `dump = 0`: no usar `dump`.
- Campo `pass = 2`: `fsck` puede revisarlo en paralelo tras la raíz (`pass=1`).

### 5.3. Aplicar el montaje

Recargar las units de systemd y montar todo lo que esté pendiente:

```bash
sudo systemctl daemon-reload
sudo mount -a
```

Si `mount -a` no devuelve errores, comprobar:

```bash
findmnt /mnt/hd5t
findmnt /mnt/hd2t
df -hT /mnt/hd5t /mnt/hd2t
```

Cada uno debe aparecer montado como `ext4` en su punto correspondiente, con el tamaño esperado.

### 5.4. Prueba de reinicio

El verdadero test del montaje persistente es reiniciar:

```bash
sudo reboot
```

Tras volver por SSH:

```bash
findmnt /mnt/hd5t /mnt/hd2t
```

Ambos deben aparecer montados sin intervención. Si alguno no monta, revisar `journalctl -b | grep -iE "mount|hd5t|hd2t"`.

---

## 6. Estrategia de uso de cada disco

Decisión arquitectónica del homelab para separar contenido pesado de datos críticos:

### `hd5t` — multimedia de Stash (5 TB, `/mnt/hd5t`)

- **Único propósito**: bibliotecas multimedia gestionadas por **Stash** (ver [`docs/09-multimedia/05-stash.md`](../09-multimedia/05-stash.md)).
- Contenido pesado, mayoritariamente de **lectura secuencial**, que se reemplaza con poca frecuencia.
- Se aísla en un disco propio para que el resto del homelab (bases de datos, backups, servicios) **no compita** por I/O ni por espacio con la biblioteca multimedia.
- **No** se usa como destino de backups: si este disco falla, se pierde la biblioteca, pero **no** se pierden datos críticos del resto de servicios.
- **No** se exporta por Samba/Nextcloud al resto de equipos en este punto (eso se decide por servicio en sus respectivas fases).

### `hd2t` — servicios y backups (2 TB, `/mnt/hd2t`)

- **Datos persistentes** del resto de servicios: bases de datos (MariaDB/PostgreSQL/Redis), volúmenes Docker, configuraciones, uploads de Nextcloud, descargas, bibliotecas de Jellyfin/Navidrome/Audiobookshelf/Calibre, datos de Home Assistant, etc.
- **Carpeta de backups locales** (Borgmatic, dumps de BD, snapshots de configs) gestionada por la Fase 7. Es el destino **local** de la estrategia 3-2-1; el destino offsite es la nube y se documenta también en la Fase 7.
- **Swap del sistema** (Fase 1): la Pi 5 deshabilita la swap en microSD para no desgastarla, y configura una swapfile pequeña en `hd2t` para tener red de seguridad bajo presión de memoria.
- Por tanto, este disco concentra **el riesgo crítico** del homelab. Su monitorización SMART (Fase 5) y sus backups (Fase 7) son **prioritarios**.

> **Regla de pulgar**: si un dato cabe en `hd2t` y no es multimedia "consumible" por Stash, va en `hd2t`. Si es de Stash, va en `hd5t`.

---

## 7. Monitorización SMART continua

La verificación SMART del paso 2 es solo el chequeo inicial. La monitorización periódica se cubre en la Fase 5 (`docs/05-monitorizacion/`), pero conviene dejar ya programado un autotest corto semanal para detectar degradación temprana.

### 7.1. Habilitar el daemon `smartd`

`smartmontools` instala el servicio `smartd`. Editar `/etc/smartd.conf` y reemplazar la línea `DEVICESCAN ...` por entradas explícitas para los dos discos USB:

```conf
# /etc/smartd.conf — homelab
/dev/disk/by-id/usb-<modelo-hd5t>-<serial>-0:0 -d sat -a -s S/../.././02 -m root
/dev/disk/by-id/usb-<modelo-hd2t>-<serial>-0:0 -d sat -a -s S/../.././03 -m root
```

- `-d sat`: forzar el protocolo SAT a través del puente USB (ajustar al flag que haya funcionado en el paso 2.1).
- `-a`: monitorización completa.
- `-s S/../.././02`: ejecuta self-test **corto** todos los días a las 02:00 (ajustar las horas para que no coincidan entre discos ni con backups).
- `-m root`: notifica al usuario `root` por correo local (la integración con Telegram/email se hace en Uptime Kuma / Prometheus en la Fase 5).

Activar y arrancar:

```bash
sudo systemctl enable --now smartd
sudo systemctl status smartd
```

### 7.2. Comprobación manual periódica

Hasta que la Fase 5 esté en marcha, revisar manualmente cada cierto tiempo:

```bash
sudo smartctl -H /dev/disk/by-id/usb-<modelo-hd5t>-<serial>
sudo smartctl -H /dev/disk/by-id/usb-<modelo-hd2t>-<serial>
sudo smartctl -l selftest /dev/disk/by-id/usb-<modelo-hd5t>-<serial>
sudo smartctl -l selftest /dev/disk/by-id/usb-<modelo-hd2t>-<serial>
```

---

## Lista de Verificación

Antes de cerrar esta fase y pasar a `docs/01-sistema/04-estructura-directorios.md`:

- [ ] `lsblk -f` muestra `/dev/sdX1` con `LABEL=hd5t` y `/dev/sdY1` con `LABEL=hd2t`, ambos `ext4`.
- [ ] `findmnt /mnt/hd5t` y `findmnt /mnt/hd2t` reportan los discos montados como `ext4` con `noatime` y `nofail`.
- [ ] `df -hT /mnt/hd5t /mnt/hd2t` muestra el tamaño esperado (~4.6 TiB y ~1.8 TiB tras formateo).
- [ ] Tras un reboot, ambos discos siguen montados automáticamente sin intervención.
- [ ] `sudo smartctl -H /dev/sdX` devuelve `PASSED` para los dos discos.
- [ ] El self-test corto y, en lo posible, el largo han terminado sin errores.
- [ ] `smartd` está habilitado y arrancado, con un self-test corto programado para cada disco.
- [ ] Tanto el `SERIAL` como el `UUID` y la ruta `by-id` de cada disco están **anotados** en algún sitio fuera de la Pi (gestor de contraseñas, vault, README local), por si hay que recuperar el sistema con los discos en otro orden.

---

## Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `mount: /mnt/hd5t: special device LABEL=hd5t does not exist` | El disco no se ha enumerado a tiempo, o la etiqueta no coincide. | `sudo blkid` para confirmar `LABEL`. Aumentar `x-systemd.device-timeout`. Verificar cable USB. |
| Reset USB en `dmesg` durante operaciones grandes | Falta de potencia o cable largo de baja calidad. | Cable corto y de calidad; en último caso, hub USB 3.0 con alimentación externa (ver `02-esquema-conexiones.md`). |
| `smartctl: Unknown USB bridge` | Puente USB-SATA no soportado en modo automático. | Probar `-d sat`, `-d usbjmicron`, `-d usbsunplus`. |
| Rendimiento muy bajo (<30 MB/s) en uno de los discos | Disco conectado a USB 2.0 (negro) en lugar de USB 3.0 (azul). | Mover el cable al puerto azul correspondiente. |
| `mount -a` falla y bloquea boot | Falta `nofail` en `fstab`. | Añadir `nofail` y `x-systemd.device-timeout=15` a la línea correspondiente. |
| El disco aparece como `/dev/sda` un día y `/dev/sdb` al siguiente | Orden de detección USB. | Ya contemplado: el montaje por `LABEL` lo abstrae. Para scripts y `smartd`, usar `/dev/disk/by-id/`. |

---

## Referencias

- [ext4 — Kernel.org documentation](https://www.kernel.org/doc/html/latest/filesystems/ext4/index.html)
- [`mkfs.ext4(8)` — manual page](https://man7.org/linux/man-pages/man8/mkfs.ext4.8.html)
- [`fstab(5)` — manual page](https://man7.org/linux/man-pages/man5/fstab.5.html)
- [`systemd.mount` — `nofail`, `x-systemd.device-timeout`](https://www.freedesktop.org/software/systemd/man/systemd.mount.html)
- [smartmontools — Home page](https://www.smartmontools.org/)
- [`smartctl(8)` — manual page](https://www.smartmontools.org/browser/trunk/smartmontools/smartctl.8.in)
- [`smartd.conf(5)` — manual page](https://www.smartmontools.org/browser/trunk/smartmontools/smartd.conf.5.in)
- [GNU Parted — Manual](https://www.gnu.org/software/parted/manual/parted.html)
