# Instalar Discos Externos con Datos Existentes

## Descripción

Procedimiento para conectar discos duros externos USB que **ya contienen datos** a la Raspberry Pi 5 y dejarlos operativos para el homelab **sin formatearlos ni perder información**. Cubre la identificación segura del dispositivo, comprobación de salud (SMART), montaje manual y automático vía `/etc/fstab` por **UUID**, verificación de integridad del filesystem existente y ajuste de permisos para que Docker pueda trabajar con ellos.

Este documento es la **alternativa no destructiva** a [`03-preparacion-discos.md`](./03-preparacion-discos.md), pensado para el caso en que los discos que se conecten al homelab ya contengan archivos que se desean conservar (bibliotecas multimedia, documentos, backups previos, etc.).

> **Diferencia clave con `03-preparacion-discos.md`**: aquel documento **borra y reformatea** los discos desde cero. Este documento **nunca ejecuta** `wipefs`, `parted mklabel`, `mkfs` ni ningún otro comando destructivo sobre los discos.

---

## Requisitos Previos

- Cableado físico verificado según [`02-esquema-conexiones.md`](./02-esquema-conexiones.md): los HDDs en puertos **USB 3.0 (azules)**, sin errores en `dmesg`.
- Raspberry Pi OS Lite 64-bit instalado y accesible por SSH (Fase 1, `docs/01-sistema/01-instalacion-os.md`).
- Usuario con permisos `sudo`.
- Paquetes instalados:
  ```bash
  sudo apt update
  sudo apt install -y smartmontools util-linux e2fsprogs ntfs-3g exfatprogs
  ```
  - `smartmontools` para tests SMART (`smartctl`).
  - `util-linux` aporta `lsblk`, `blkid`, `mount`, `findmnt`.
  - `e2fsprogs` para `fsck.ext4`, `tune2fs`, `e2label` (si el disco es ext4).
  - `ntfs-3g` para montar y leer/escribir particiones **NTFS** (típicas de discos usados en Windows).
  - `exfatprogs` para montar particiones **exFAT** (discos formateados para compatibilidad Mac/Windows).

> **Nota**: si los discos ya están formateados en **ext4**, los paquetes `ntfs-3g` y `exfatprogs` no son necesarios y viceversa. Se instalan todos para cubrir los casos más habituales.

---

## Identificación de los Discos

> **Aviso crítico**: nunca asumir qué disco es `/dev/sda` o `/dev/sdb`. El kernel asigna los nombres por orden de detección y pueden cambiar entre arranques. Identificar siempre por **modelo, tamaño y número de serie** antes de cualquier operación.

### 1. Listar dispositivos de bloque

```bash
lsblk -o NAME,SIZE,TRAN,MODEL,SERIAL,VENDOR,FSTYPE,LABEL,MOUNTPOINTS
```

Resultado típico de un disco que ya viene con datos (ejemplo):

```
NAME    SIZE  TRAN  MODEL              SERIAL          VENDOR   FSTYPE  LABEL       MOUNTPOINTS
sda     4.6T  usb   Elements_25A3      WX12345ABCDE    WD
└─sda1  4.6T                                                    ntfs    Multimedia
sdb     1.8T  usb   My_Passport_25E2   WX67890FGHIJ    WD
└─sdb1  1.8T                                                    ext4    datos
mmcblk0 58.2G          ...                                                          /
```

Puntos clave a anotar:

| Dato | Para qué |
|---|---|
| `NAME` (ej. `sda1`) | Dispositivo de la partición — se usará para montar. |
| `SIZE` | Confirmar que es el disco esperado. |
| `FSTYPE` | Tipo de filesystem actual (`ext4`, `ntfs`, `exfat`, `vfat`, `hfsplus`…). |
| `LABEL` | Etiqueta del filesystem (si la tiene). |
| `SERIAL` | Número de serie — anotar para referencia e identificación física. |

### 2. Obtener el UUID

```bash
sudo blkid /dev/sda1 /dev/sdb1
```

Ejemplo:

```
/dev/sda1: LABEL="Multimedia" UUID="ABCD1234ABCD1234" TYPE="ntfs"
/dev/sdb1: LABEL="datos" UUID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" TYPE="ext4"
```

**Anotar los UUIDs**: son el identificador estable para `/etc/fstab`.

### 3. Verificar que no están auto-montados

Algunos entornos de escritorio montan automáticamente los discos USB. En Raspberry Pi OS Lite no suele pasar, pero conviene verificar:

```bash
mount | grep -E "sd[a-z]"
```

Si aparecen montados en rutas tipo `/media/...`, desmontarlos antes de continuar:

```bash
sudo umount /dev/sda1 2>/dev/null || true
sudo umount /dev/sdb1 2>/dev/null || true
```

---

## Pruebas SMART

Antes de integrar un disco con datos existentes al homelab, comprobar que está sano. Un disco con sectores defectuosos puede corromper silenciosamente los datos que ya contiene.

### Estado y atributos básicos

```bash
sudo smartctl -i /dev/sda
sudo smartctl -H /dev/sda
sudo smartctl -A /dev/sda
```

Si responde `Device does not support SMART` o `Unknown USB bridge`:

```bash
sudo smartctl -d sat -i /dev/sda
sudo smartctl -d sat -H /dev/sda
sudo smartctl -d sat -A /dev/sda
```

Interpretar los resultados:

| Atributo | Valor aceptable | Acción si falla |
|---|---|---|
| `SMART overall-health` | `PASSED` | `FAILED` → el disco está muriendo. **Copiar datos a otro disco cuanto antes** y no integrarlo en el homelab. |
| `Reallocated_Sector_Ct` | `0` ideal; < 50 tolerable en disco usado | Valores altos → disco en degradación. Planificar reemplazo. |
| `Current_Pending_Sector` | `0` | > 0 → sectores pendientes de reasignación. El disco puede perder datos. |
| `Offline_Uncorrectable` | `0` | > 0 → datos ya perdidos en algún sector. |
| `Power_On_Hours` | Depende de la edad del disco | Solo informativo; útil para estimar vida restante. |

### Test corto (no destructivo)

```bash
sudo smartctl -t short /dev/sda        # o: -d sat -t short
# esperar 1–2 min
sudo smartctl -l selftest /dev/sda
```

El resultado debe ser `Completed without error`.

> **Importante**: los tests SMART son **no destructivos** — no modifican ni borran datos del disco. Se pueden ejecutar con total seguridad sobre discos con datos.

---

## Comprobación de Integridad del Filesystem

Antes de montar el disco para uso continuo, es recomendable verificar la integridad del filesystem. El procedimiento depende del tipo de filesystem.

> **Requisito**: el disco debe estar **desmontado** para ejecutar la comprobación. No ejecutar `fsck` sobre un filesystem montado; puede causar corrupción.

### ext4

```bash
sudo fsck.ext4 -n /dev/sda1
```

- `-n` → modo **solo lectura** (no repara, solo informa). Seguro para datos.
- Si reporta errores y se quiere reparar:
  ```bash
  sudo fsck.ext4 -p /dev/sda1
  ```
  `-p` → reparación automática de errores seguros (los que no requieren intervención manual).

### NTFS

```bash
sudo ntfsfix -n /dev/sda1
```

- `-n` → modo solo lectura (diagnóstico sin modificar).
- `ntfsfix` solo realiza reparaciones básicas. Para una reparación completa de NTFS, lo recomendable es conectar el disco a un equipo Windows y usar `chkdsk /f`.

### exFAT

```bash
sudo fsck.exfat -n /dev/sda1
```

- `-n` → modo solo lectura.

---

## Montaje

### 1. Crear puntos de montaje

Usar nombres descriptivos coherentes con la política del homelab. Ejemplos:

```bash
sudo mkdir -p /mnt/hd5t /mnt/hd2t
```

Si los discos tienen un propósito diferente al previsto en `SERVICES.md`, adaptar los nombres (ej. `/mnt/datos-externos`, `/mnt/media-antigua`).

### 2. Montar manualmente (prueba)

El comando de montaje depende del tipo de filesystem detectado en `blkid`:

#### ext4

```bash
sudo mount -t ext4 -o defaults,noatime /dev/sda1 /mnt/hd5t
```

#### NTFS (lectura y escritura)

```bash
sudo mount -t ntfs-3g -o defaults,noatime,uid=1000,gid=1000,dmask=022,fmask=133 /dev/sda1 /mnt/hd5t
```

- `uid=1000,gid=1000` → asigna la propiedad al usuario principal de la Pi (necesario porque NTFS no tiene permisos POSIX nativos).
- `dmask=022,fmask=133` → directorios con `755`, ficheros con `644`.

#### exFAT

```bash
sudo mount -t exfat -o defaults,noatime,uid=1000,gid=1000,dmask=022,fmask=133 /dev/sda1 /mnt/hd5t
```

### 3. Verificar que los datos están accesibles

```bash
ls -la /mnt/hd5t/
df -h /mnt/hd5t
```

Confirmar que se ven los ficheros y directorios esperados y que el espacio reportado coincide con lo esperado.

---

## Montaje Automático (`/etc/fstab`)

### 1. Hacer backup de fstab

```bash
sudo cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d)
```

### 2. Desmontar los discos montados manualmente

```bash
sudo umount /mnt/hd5t
sudo umount /mnt/hd2t
```

### 3. Editar `/etc/fstab`

```bash
sudo nano /etc/fstab
```

Añadir al final las líneas correspondientes al tipo de filesystem de cada disco. Sustituir los UUIDs por los reales obtenidos con `blkid`.

#### Para discos ext4

```
# --- Homelab: discos externos USB (con datos existentes) ---
UUID=11111111-2222-3333-4444-555555555555  /mnt/hd5t  ext4     defaults,noatime,nofail,x-systemd.device-timeout=30  0  2
UUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee  /mnt/hd2t  ext4     defaults,noatime,nofail,x-systemd.device-timeout=30  0  2
```

#### Para discos NTFS

```
UUID=ABCD1234ABCD1234  /mnt/hd5t  ntfs-3g  defaults,noatime,nofail,x-systemd.device-timeout=30,uid=1000,gid=1000,dmask=022,fmask=133  0  0
```

#### Para discos exFAT

```
UUID=1234-ABCD  /mnt/hd5t  exfat  defaults,noatime,nofail,x-systemd.device-timeout=30,uid=1000,gid=1000,dmask=022,fmask=133  0  0
```

Justificación de las opciones de montaje:

| Opción | Propósito |
|---|---|
| `UUID=…` | Montaje **estable** independiente de `/dev/sdX`. |
| `noatime` | No actualizar la marca de último acceso en cada lectura. Reduce escrituras innecesarias. |
| `nofail` | Si el disco no está conectado, la Pi sigue arrancando normalmente. |
| `x-systemd.device-timeout=30` | Espera hasta 30 s el spin-up del HDD USB antes de continuar. |
| `uid=1000,gid=1000` | (Solo NTFS/exFAT) Asigna propiedad al usuario principal para que Docker y los servicios puedan acceder. |
| `0 0` (NTFS/exFAT) | No ejecutar `fsck` automático al arrancar — `fsck` de Linux no repara completamente estos filesystems. |
| `0 2` (ext4) | Chequeo `fsck` después de la raíz. |

### 4. Probar sin reiniciar

```bash
sudo systemctl daemon-reload
sudo mount -a
mount | grep -E "hd5t|hd2t"
df -h /mnt/hd5t /mnt/hd2t
```

Si `mount -a` da error, **no reiniciar**: corregir `/etc/fstab` primero o restaurar la copia de seguridad.

### 5. Validar tras un reinicio

```bash
sudo reboot
# tras volver a entrar por SSH:
mount | grep -E "hd5t|hd2t"
ls /mnt/hd5t/
ls /mnt/hd2t/
```

Confirmar que ambos puntos de montaje están activos y los datos siguen accesibles.

---

## Ajuste de Permisos (solo ext4)

En filesystems NTFS y exFAT los permisos se controlan con las opciones de montaje (`uid`, `gid`, `dmask`, `fmask`). En ext4, los permisos están almacenados en el propio filesystem y pueden necesitar ajustes.

### Verificar propiedad actual

```bash
ls -la /mnt/hd5t/
stat -c "%U:%G %a %n" /mnt/hd5t/*
```

### Ajustar si es necesario

Si Docker o los servicios necesitan escribir en los directorios y la propiedad no es la correcta:

```bash
# Opción A: Asignar al usuario principal de la Pi
sudo chown -R 1000:1000 /mnt/hd5t/ruta/especifica

# Opción B: Solo cambiar el directorio raíz y dejar los subdirectorios intactos
sudo chown 1000:1000 /mnt/hd5t
sudo chmod 755 /mnt/hd5t
```

> **Precaución con `chown -R`**: en un disco con millones de ficheros puede tardar mucho y cambiar permisos que luego sean difíciles de revertir. Preferir cambios quirúrgicos sobre directorios concretos en lugar de recursivos sobre la raíz del disco.

---

## Etiquetado (Opcional)

Si se quiere asignar una etiqueta al disco para facilitar su identificación sin cambiar el filesystem:

### ext4

```bash
sudo e2label /dev/sda1 hd5t
```

### NTFS

```bash
sudo ntfslabel /dev/sda1 hd5t
```

### exFAT

```bash
sudo exfatlabel /dev/sda1 hd5t
```

> El etiquetado **no destruye datos**. Solo modifica el campo de etiqueta en los metadatos del filesystem.

---

## Consideraciones sobre el Filesystem

### ¿Conviene reformatear a ext4?

El documento [`03-preparacion-discos.md`](./03-preparacion-discos.md) usa ext4 por buenas razones (permisos POSIX, rendimiento, estabilidad). Si el disco viene con NTFS o exFAT, hay limitaciones:

| Aspecto | ext4 | NTFS (ntfs-3g) | exFAT |
|---|---|---|---|
| Permisos POSIX | Nativos | Emulados vía opciones de montaje | Emulados vía opciones de montaje |
| Rendimiento en Pi | Nativo del kernel | Espacio de usuario (FUSE) — más lento | Kernel (desde Linux 5.7) — aceptable |
| Soporte Docker | Completo | Funcional pero con limitaciones de permisos | Funcional pero con limitaciones de permisos |
| `fsck` en Linux | Completo (`fsck.ext4`) | Parcial (`ntfsfix`) | Básico (`fsck.exfat`) |
| Journaling | Sí | Sí | No |

**Recomendación**:
- Si el disco contiene datos que **no se pueden copiar a otro sitio** temporalmente → usar el filesystem actual tal cual con este documento.
- Si se pueden copiar los datos a otro disco o equipo temporalmente → copiarlos, formatear a ext4 con [`03-preparacion-discos.md`](./03-preparacion-discos.md) y luego devolver los datos. Es la opción más robusta a largo plazo.
- Para servicios Docker que requieren permisos POSIX estrictos (Nextcloud, Postgres, Paperless), **ext4 es muy recomendable**. NTFS/exFAT funcionan para almacenamiento multimedia de solo lectura (Jellyfin, Stash) pero pueden dar problemas con servicios que necesitan locks, symlinks o permisos granulares.

---

## Verificación Final

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Discos montados | `df -h \| grep -E "hd5t\|hd2t"` | Ambos visibles con espacio acorde a su tamaño. |
| Datos accesibles | `ls /mnt/hd5t/ && ls /mnt/hd2t/` | Se ven los ficheros y directorios existentes. |
| Tipo de filesystem | `lsblk -f` | `FSTYPE` correcto (`ext4`, `ntfs`, `exfat`). |
| `fstab` válido | `findmnt --verify` | Sin errores ni warnings. |
| Persistencia tras reboot | `sudo reboot && mount \| grep mnt` | Ambos puntos de montaje activos sin intervención. |
| SMART OK | `sudo smartctl -H /dev/sda` | `PASSED`. |
| Sin errores USB | `dmesg \| grep -iE "usb\|reset\|sd[ab]"` | Sin errores de descriptor, sin resets. |
| Escritura (si aplica) | `sudo touch /mnt/hd5t/.write_test && sudo rm /mnt/hd5t/.write_test` | Sin errores. |

---

## Backup

Dado que los discos **ya contienen datos valiosos**, es especialmente importante:

1. **Antes de integrar al homelab**: si es posible, hacer una copia de seguridad de los datos más importantes a otro medio (otro disco, NAS, nube). Aunque este procedimiento es no destructivo, un disco con problemas SMART ocultos podría fallar en cualquier momento.

2. **Información a persistir** (guardar en el repositorio del homelab o gestor de contraseñas):
   - **UUIDs** de las particiones (de `blkid`).
   - **Números de serie** de los HDDs (de `lsblk` o `smartctl -i`).
   - **Tipo de filesystem** de cada disco.
   - **Modo SMART** detectado (`auto` o `-d sat`).
   - Copia de `/etc/fstab`.

3. **A partir de la Fase 7 (Borgmatic)**: incorporar los directorios relevantes de estos discos a la estrategia de backups del homelab.

---

## Referencias

- [Documento anterior: `03-preparacion-discos.md`](./03-preparacion-discos.md) — Preparación destructiva (formateo desde cero).
- [`02-esquema-conexiones.md`](./02-esquema-conexiones.md) — Cableado físico.
- [`SERVICES.md`](../../SERVICES.md) — Estructura de almacenamiento y política de discos.
- [`ntfs-3g` — documentación oficial](https://github.com/tuxera/ntfs-3g/wiki)
- [`exfatprogs` — repositorio oficial](https://github.com/exfatprogs/exfatprogs)
- [`smartctl(8)` — manpage smartmontools](https://www.smartmontools.org/browser/trunk/smartmontools/smartctl.8.in)
- [`fstab(5)` — manpage Debian](https://manpages.debian.org/bookworm/util-linux/fstab.5.en.html)
- [Arch Wiki — NTFS](https://wiki.archlinux.org/title/NTFS)
- [Arch Wiki — exFAT](https://wiki.archlinux.org/title/ExFAT)
- [Arch Wiki — ext4](https://wiki.archlinux.org/title/Ext4)
