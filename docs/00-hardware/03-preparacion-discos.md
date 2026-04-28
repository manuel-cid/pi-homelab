# Preparación de los Discos Externos

## Descripción

Procedimiento completo para dejar los dos discos duros externos (`hd5t` de 5 TB y `hd2t` de 2 TB) listos para alojar los datos del homelab: identificación segura del dispositivo, pruebas SMART, particionado **GPT**, formato **ext4** con etiquetas estables, montaje automático en el arranque mediante `/etc/fstab` por **UUID** y estructura de directorios inicial alineada con la política definida en `SERVICES.md`.

El objetivo es que, tras este documento, la Pi pueda **reiniciarse en cualquier momento** y los discos aparezcan siempre en el mismo punto de montaje (`/mnt/hd5t` y `/mnt/hd2t`) con los permisos correctos para que Docker pueda escribir en ellos en las fases siguientes.

> **Recordatorio de alcance**: la preparación se realiza en la propia Pi por **SSH desde la LAN o desde Tailscale**. No requiere acceso externo, ni se exponen los discos por red en esta fase (eso se hace después con servicios como Samba/Nextcloud, no a nivel de bloque).

---

## Requisitos Previos

- Cableado físico verificado según [`02-esquema-conexiones.md`](./02-esquema-conexiones.md): ambos HDDs en puertos **USB 3.0 (azules)**, sin errores en `dmesg`.
- Raspberry Pi OS Lite 64-bit instalado y accesible por SSH (Fase 1, `docs/01-sistema/01-instalacion-os.md`).
- Usuario con permisos `sudo` (no se trabaja como `root` directamente; siempre `sudo`).
- Paquetes instalados:
  ```bash
  sudo apt update
  sudo apt install -y parted e2fsprogs smartmontools util-linux
  ```
  - `parted` y `util-linux` (que aporta `lsblk`, `blkid`, `wipefs`) para particionado.
  - `e2fsprogs` para `mkfs.ext4`, `tune2fs`, `e2label`.
  - `smartmontools` para los tests SMART (`smartctl`).
- Confirmación explícita de que **los discos están vacíos o se pueden borrar**: este procedimiento **destruye** todo su contenido. Si se reciben de un uso previo, hacer copia de seguridad antes.

---

## Identificación de los Discos

> **Aviso crítico**: nunca asumir que `hd5t` es `/dev/sda` y `hd2t` es `/dev/sdb`. El kernel asigna `/dev/sdX` por orden de detección y puede cambiar entre arranques o si se desconectan. Identificar siempre por **modelo y tamaño** antes de cualquier operación destructiva.

```bash
lsblk -o NAME,SIZE,TRAN,MODEL,SERIAL,VENDOR,MOUNTPOINTS
```

Resultado típico (ejemplo, los modelos varían):

```
NAME    SIZE  TRAN  MODEL              SERIAL          VENDOR   MOUNTPOINTS
sda     4.6T  usb   Elements_25A3      WX12345ABCDE    WD
sdb     1.8T  usb   My_Passport_25E2   WX67890FGHIJ    WD
mmcblk0 58.2G          ...                                       /
```

Reglas para asignar la etiqueta lógica:

| Etiqueta | Disco | Cómo identificarlo |
|---|---|---|
| `hd5t` | El de **~4.6 TB / 5 TB** (los HDDs venden TB decimales, el SO muestra TiB). | `SIZE` ≈ 4.5–4.7 T |
| `hd2t` | El de **~1.8 TB / 2 TB**. | `SIZE` ≈ 1.8–1.9 T |

Anotar el **número de serie (`SERIAL`)** de cada disco en este momento. Servirá para identificarlos físicamente sin tener que leer la pegatina del exterior y para ligar las alertas SMART al disco correcto en el futuro.

A partir de aquí, sustituir en los comandos:

- `${DEV_HD5T}` → `/dev/sdX` correspondiente al disco de 5 TB (ej. `/dev/sda`).
- `${DEV_HD2T}` → `/dev/sdX` correspondiente al disco de 2 TB (ej. `/dev/sdb`).

Los procedimientos siguientes muestran cada paso para `hd5t`; **repetir exactamente igual para `hd2t`** sustituyendo dispositivo y etiqueta.

---

## Pruebas SMART Iniciales

Antes de invertir tiempo en formatear, comprobar que ambos discos están sanos. Detectar un disco defectuoso ahora ahorra reconstruir todo el homelab en cuanto Borgmatic empiece a llenar el de backups.

### Estado y atributos básicos

```bash
sudo smartctl -i ${DEV_HD5T}        # información del dispositivo
sudo smartctl -H ${DEV_HD5T}        # health overall
sudo smartctl -A ${DEV_HD5T}        # atributos
```

- `smartctl -H` debe devolver `PASSED`. Cualquier `FAILED` invalida el disco para uso en el homelab.
- En `smartctl -A`, vigilar especialmente:
  - `Reallocated_Sector_Ct` debe ser **0** en un disco nuevo.
  - `Current_Pending_Sector` y `Offline_Uncorrectable` deben ser **0**.
  - `Power_On_Hours` debe ser bajo (decenas de horas como mucho) si el disco se vende como nuevo.

Si `smartctl` responde `Device does not support SMART` o `Unknown USB bridge`, probar con:

```bash
sudo smartctl -d sat -i ${DEV_HD5T}
sudo smartctl -d sat -H ${DEV_HD5T}
sudo smartctl -d sat -A ${DEV_HD5T}
```

La mayoría de carcasas USB modernas requieren el modo `-d sat` (SCSI-ATA Translation). Si funciona, anotarlo: se reutilizará en la monitorización (Fase 13).

### Test corto

Test no destructivo de ~2 minutos:

```bash
sudo smartctl -t short ${DEV_HD5T}        # o:  -d sat -t short
# esperar lo que indique el comando (1–2 min)
sudo smartctl -l selftest ${DEV_HD5T}
```

El log debe mostrar `Completed without error` para el último test.

### Test largo (recomendado, opcional en este punto)

Recorre toda la superficie del disco. **Tarda muchas horas** (un disco de 5 TB sobre USB puede llevar 8–12 h). Se puede dejar en marcha y continuar con el resto del documento en paralelo, **pero sin formatear todavía** ese disco.

```bash
sudo smartctl -t long ${DEV_HD5T}
# Consultar el progreso periódicamente:
sudo smartctl -l selftest ${DEV_HD5T}
```

Si por tiempo se prefiere no esperar al test largo aquí, dejarlo programado en Fase 13 (`docs/13-operaciones/`) como tarea recurrente. El test corto es **obligatorio** antes de seguir; el largo es muy recomendable al menos una vez antes de poner el disco en producción.

---

## Limpieza y Particionado

> **Punto de no retorno**: a partir de aquí los datos previos del disco se pierden. Confirmar tres veces que `${DEV_HD5T}` y `${DEV_HD2T}` apuntan a los discos correctos, y **no** a la microSD (`/dev/mmcblk0`).

### 1. Desmontar cualquier partición previa

Si el disco se ha auto-montado al conectarlo, desmontarlo:

```bash
mount | grep ${DEV_HD5T} || echo "No montado, ok"
sudo umount ${DEV_HD5T}?* 2>/dev/null || true
```

### 2. Borrar firmas de filesystems anteriores

```bash
sudo wipefs -a ${DEV_HD5T}
```

Esto elimina restos de tablas de particiones (MBR/GPT) y firmas de filesystems (NTFS, exFAT…) que podrían confundir a `parted` o al kernel.

### 3. Crear tabla de particiones GPT y una única partición

Se usa **GPT** en lugar de MBR: soporta discos > 2 TB (necesario para `hd5t`) y se mantiene homogéneo entre ambos discos.

Una única partición que ocupa el 100 % del disco. No tiene sentido fragmentar: el reparto entre servicios se hace por **directorios** dentro del filesystem, no por particiones.

```bash
sudo parted -s ${DEV_HD5T} -- \
    mklabel gpt \
    mkpart primary ext4 0% 100%

sudo partprobe ${DEV_HD5T}
```

Verificar:

```bash
sudo parted ${DEV_HD5T} print
lsblk ${DEV_HD5T}
```

La partición resultante será `${DEV_HD5T}1` (ej. `/dev/sda1`). Se referencia en adelante como `${PART_HD5T}`.

---

## Formato ext4 y Etiquetado

### ¿Por qué ext4?

- **Estable, soportado nativamente** por el kernel de Raspberry Pi OS sin paquetes adicionales.
- Permisos POSIX completos (necesarios para que Docker, Jellyfin, Nextcloud y Borg respeten UIDs).
- Buen rendimiento en HDDs USB y herramientas maduras de reparación (`fsck.ext4`).
- Alternativas como `xfs` o `btrfs` aportan ventajas (snapshots, checksums) pero añaden complejidad operativa que no se justifica para este homelab. Cualquier servicio que necesite snapshots los hará a nivel aplicación o vía Borg.

### Formatear

```bash
# hd5t (5 TB) — para multimedia de Stash
sudo mkfs.ext4 -L hd5t -m 1 -T largefile4 ${PART_HD5T}

# hd2t (2 TB) — para datos de servicios y backups
sudo mkfs.ext4 -L hd2t -m 1 ${PART_HD2T}
```

Justificación de las opciones:

| Opción | Propósito |
|---|---|
| `-L hd5t` / `-L hd2t` | **Etiqueta** del filesystem. Aparece en `lsblk -f` y permite identificar el disco aunque cambie de puerto USB. **No** se usa para el montaje (eso se hace por UUID, ver siguiente sección), pero sí para inspección humana y como red de seguridad. |
| `-m 1` | Reserva el **1 %** del disco para `root` en lugar del 5 % por defecto. En un disco de datos (no de SO), el 5 % son **decenas de GB malgastados**. |
| `-T largefile4` (solo en `hd5t`) | Genera **menos inodos**: 1 inodo por cada 4 MiB en lugar de 1 por cada 16 KiB. La biblioteca de Stash son ficheros multimedia grandes (cientos de MB / varios GB cada uno); no se necesitan millones de inodos y se libera espacio útil. **No** aplicar `-T largefile4` a `hd2t`, donde sí habrá muchos ficheros pequeños (Nextcloud, Paperless, configs, snapshots de Borg). |

### Verificar y obtener UUIDs

```bash
sudo blkid ${PART_HD5T} ${PART_HD2T}
```

Salida esperada (UUIDs de ejemplo):

```
/dev/sda1: LABEL="hd5t" UUID="11111111-2222-3333-4444-555555555555" TYPE="ext4"
/dev/sdb1: LABEL="hd2t" UUID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" TYPE="ext4"
```

**Anotar ambos UUIDs**. Son el identificador estable que se usará en `/etc/fstab`.

---

## Montaje Automático (`/etc/fstab`)

### 1. Crear puntos de montaje

```bash
sudo mkdir -p /mnt/hd5t /mnt/hd2t
```

### 2. Editar `/etc/fstab`

> **Hacer copia antes de tocar `fstab`**: un error en este fichero puede dejar la Pi sin arrancar.

```bash
sudo cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d)
sudo nano /etc/fstab
```

Añadir al final (sustituyendo los UUIDs reales obtenidos arriba):

```
# --- Homelab: discos externos USB ---
UUID=11111111-2222-3333-4444-555555555555  /mnt/hd5t  ext4  defaults,noatime,nofail,x-systemd.device-timeout=30  0  2
UUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee  /mnt/hd2t  ext4  defaults,noatime,nofail,x-systemd.device-timeout=30  0  2
```

Justificación de las opciones de montaje:

| Opción | Propósito |
|---|---|
| `UUID=…` | Montaje **estable** independiente de `/dev/sdX`, que puede cambiar de orden. |
| `defaults` | `rw, suid, dev, exec, auto, nouser, async`. Comportamiento estándar. |
| `noatime` | No actualizar la marca de "último acceso" en cada lectura. **Reduce escrituras** (importante para vida útil del HDD y del propio filesystem) y mejora rendimiento. Imprescindible para Jellyfin/Stash, que escanean miles de ficheros. |
| `nofail` | Si el disco no está conectado en el arranque, **la Pi sigue arrancando** en lugar de quedarse en modo emergencia. Crítico cuando los discos cuelgan de USB y pueden tardar más en aparecer. |
| `x-systemd.device-timeout=30` | systemd espera **hasta 30 s** a que el dispositivo aparezca antes de continuar (los HDDs USB tardan en hacer spin-up). Sin esto, `nofail` puede saltarse el montaje y los servicios Docker arrancarían sin sus volúmenes. |
| Campo `0 2` (final) | `dump=0` (no usado), `pass=2` (chequeo `fsck` después de la raíz, no en paralelo). |

### 3. Probar la configuración sin reiniciar

```bash
sudo systemctl daemon-reload
sudo mount -a
mount | grep -E "hd5t|hd2t"
df -h /mnt/hd5t /mnt/hd2t
```

Ambos discos deben aparecer montados. Si `mount -a` da error, **no reiniciar**: corregir `/etc/fstab` primero (o restaurar la copia de seguridad), o la Pi puede no arrancar.

### 4. Validar tras un reinicio

```bash
sudo reboot
# tras volver a entrar por SSH:
mount | grep -E "hd5t|hd2t"
lsblk -f
```

Confirmar que ambos puntos de montaje están activos automáticamente.

---

## Estructura Inicial de Directorios

Coherente con `SERVICES.md` y con la política de almacenamiento del homelab.

### Permisos base

Para los datos de servicios Docker (en `hd2t`) los permisos definitivos los marcará cada servicio en su fase (típicamente UID/GID `1000` o uno dedicado). En este punto basta con dejar la raíz preparada:

```bash
sudo chown root:root /mnt/hd5t /mnt/hd2t
sudo chmod 755 /mnt/hd5t /mnt/hd2t
```

### Directorios en `hd5t` (multimedia de Stash)

```bash
sudo mkdir -p /mnt/hd5t/stash/data
```

Solo Stash escribirá aquí. El detalle de subdirectorios (biblioteca, generated, metadata) se decide en el documento del servicio en Fase 7.

### Directorios en `hd2t` (datos de servicios + backups)

```bash
sudo mkdir -p \
    /mnt/hd2t/nextcloud/data \
    /mnt/hd2t/postgres/data \
    /mnt/hd2t/jellyfin/data \
    /mnt/hd2t/paperless/data \
    /mnt/hd2t/vaultwarden/data \
    /mnt/hd2t/pihole/etc \
    /mnt/hd2t/backups
```

Los UID/GID concretos de cada subdirectorio (`postgres`, `nextcloud`, etc.) se aplicarán **en cada documento de servicio**, no aquí, para que cada fase quede autocontenida.

### Política de uso (resumen operativo)

| Disco | Uso permitido | Uso prohibido |
|---|---|---|
| `hd5t` (5 TB) | **Solo** biblioteca multimedia de **Stash** (`/mnt/hd5t/stash/...`). | Bases de datos, backups, datos de otros servicios. |
| `hd2t` (2 TB) | Volúmenes persistentes de todos los demás servicios y **destino de backups Borg**. | Multimedia de Stash. |
| microSD | SO + Docker root + ficheros `docker-compose.yml`, `.env`, configs ligeras. | Bases de datos, logs voluminosos, datos de usuario. |

Esta separación cumple dos propósitos: aísla el alto volumen de Stash del resto (un escaneo masivo no satura el disco de Postgres), y mantiene los **backups en un disco distinto del que aloja los datos primarios** (necesario para que la copia de Borg tenga sentido como recuperación ante fallo del servicio).

---

## Verificación Final

Lista de comprobaciones antes de pasar a la Fase 1:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Discos montados | `df -h \| grep -E "hd5t\|hd2t"` | Ambos visibles, con espacio libre acorde al tamaño nominal. |
| Etiquetas correctas | `lsblk -f` | Filesystems `ext4` con `LABEL` `hd5t` y `hd2t`. |
| `fstab` válido | `findmnt --verify` | `Success, no errors or warnings detected`. |
| Persistencia tras reboot | `sudo reboot && mount \| grep mnt` | Ambos puntos de montaje activos sin intervención manual. |
| SMART OK | `sudo smartctl -H ${DEV_HD5T}` y `${DEV_HD2T}` | `PASSED` en ambos. |
| Sin errores USB recientes | `dmesg \| grep -iE "usb\|reset\|sd[ab]"` | Sin `device descriptor read/64 error`, sin resets. |
| Escritura básica | `sudo touch /mnt/hd5t/.write_test && sudo touch /mnt/hd2t/.write_test && sudo rm /mnt/hd{5t,2t}/.write_test` | Sin errores. |

Si todas las comprobaciones pasan, los discos están listos para que las fases siguientes monten volúmenes Docker sobre ellos sin sorpresas.

---

## Backup

En esta fase **no hay datos que respaldar todavía**: los discos están recién formateados y vacíos. Sin embargo, sí conviene **persistir la información de identificación** que costaría recuperar:

- **UUIDs** de las particiones `hd5t` y `hd2t` (los obtenidos con `blkid`).
- **Números de serie** de los HDDs (de `lsblk -o ...,SERIAL` o `smartctl -i`).
- **Modo SMART** detectado (`auto` o `-d sat`), para reutilizarlo en la monitorización.
- Copia de `/etc/fstab` y de `/etc/fstab.bak.YYYYMMDD` ya generada arriba.

Guardar esta información en el repositorio del homelab (en una nota local, no comprometida en git si contiene serial numbers que se prefieran privados) o en el gestor de contraseñas. Será imprescindible para diagnosticar fallos de disco, reemplazos por garantía y monitorización SMART en Fase 13.

A partir de la Fase 5 (Borgmatic), el contenido de `/mnt/hd2t/` se respalda automáticamente; el contenido de `/mnt/hd5t/` se considera **regenerable** (procede de fuentes externas y su backup es opcional, decisión documentada en `docs/05-backup/`).

---

## Referencias

- [Documento anterior: `02-esquema-conexiones.md`](./02-esquema-conexiones.md)
- [`SERVICES.md`](../../SERVICES.md) — Estructura de almacenamiento y política `/mnt/hd5t` vs `/mnt/hd2t`.
- [GNU `parted` — Manual oficial](https://www.gnu.org/software/parted/manual/parted.html)
- [`mkfs.ext4(8)` — manpage Debian](https://manpages.debian.org/bookworm/e2fsprogs/mkfs.ext4.8.en.html)
- [`fstab(5)` — manpage Debian](https://manpages.debian.org/bookworm/util-linux/fstab.5.en.html)
- [`smartctl(8)` — manpage smartmontools](https://www.smartmontools.org/browser/trunk/smartmontools/smartctl.8.in)
- [Arch Wiki — ext4](https://wiki.archlinux.org/title/Ext4)
- [Arch Wiki — S.M.A.R.T.](https://wiki.archlinux.org/title/S.M.A.R.T.)
- [Documento siguiente: `docs/01-sistema/01-instalacion-os.md`](../01-sistema/01-instalacion-os.md)
