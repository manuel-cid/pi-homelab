# Discos Externos con Datos

## Descripción
Procedimiento para integrar en el homelab discos externos USB que **ya contienen datos** y no deben formatearse. El objetivo es identificarlos con seguridad, revisar su estado físico, comprobar la integridad básica del sistema de archivos, montarlos de forma persistente con `fstab` y ajustar permisos según el formato real del disco.

Este flujo cubre los casos más habituales para discos existentes en `ext4`, `NTFS` y `exFAT`. Si el disco está vacío o se puede borrar sin riesgo, usar `docs/00-hardware/03-preparacion-discos.md` en lugar de este documento.

En este proyecto, estos discos heredados suelen acabar ocupando uno de estos roles:

- **`hd2t`**: multimedia general, descargas y backups locales.
- **`hd5t`**: biblioteca multimedia dedicada a Stash.

El SSD NVMe sigue reservado para el sistema operativo, Docker, configuraciones y datos persistentes críticos de los servicios.

## Requisitos Previos
- Haber revisado `docs/00-hardware/01-material-necesario.md`.
- Haber montado el hardware según `docs/00-hardware/02-esquema-conexiones.md`.
- Tener acceso shell con privilegios `sudo`.
- Saber qué disco físico corresponde a cada unidad con datos antes de montar nada en escritura.
- Tener claro si el disco con datos pasará a ser `hd2t`, `hd5t` o un volumen auxiliar temporal.
- Si el disco viene de Windows, asegurarse de que se expulsó correctamente y no quedó en hibernación ni con Fast Startup pendiente.
- Recordar que este documento **no** cubre reformateo ni redistribución de particiones; para eso usar `docs/00-hardware/03-preparacion-discos.md`.
- Puertos implicados:
  - 2 puertos USB 3.0 para discos externos.
  - PCIe interno solo para el SSD NVMe del sistema, no para este procedimiento.

## Docker Compose
No aplica en esta fase. Aquí solo se integran discos ya poblados para que después el host y los contenedores puedan consumirlos de forma estable.

## Configuración

### Estrategia recomendada

| Tipo de disco | Acción recomendada | Identificador en `fstab` | Nota |
|---|---|---|---|
| Disco con datos en `ext4` | Montar sin reformatear | `UUID=` | Mantiene permisos POSIX reales |
| Disco con datos en `NTFS` | Montar sin reformatear | `UUID=` | Válido para transición, menos ideal para uso Linux 24/7 |
| Disco con datos en `exFAT` | Montar sin reformatear | `UUID=` | Útil para compatibilidad, sin permisos POSIX nativos |

### Principios antes de tocar el disco

- No ejecutar `mkfs`, `parted mklabel`, `wipefs` ni ninguna orden destructiva sobre un disco con datos.
- No confiar solo en `/dev/sda` o `/dev/sdb`; usar también capacidad, modelo, serie, partición y UUID.
- Para discos ya poblados, es más seguro montar por **UUID** que por `LABEL`, porque la etiqueta puede faltar, estar duplicada o no seguir la convención del homelab.
- El chequeo del sistema de archivos debe hacerse sobre la **partición** real, por ejemplo `/dev/sda1`, no sobre el disco completo.
- El chequeo SMART se hace sobre el **dispositivo físico**, por ejemplo `/dev/sda`.
- Si un disco va a quedarse de forma permanente en Linux y no necesita compatibilidad con otros sistemas, conviene planificar una migración futura a `ext4`, pero solo después de copiar y validar todos los datos.

### Paquetes necesarios

Instalar herramientas de diagnóstico y soporte de sistemas de archivos:

```bash
sudo apt update
sudo apt install -y smartmontools util-linux e2fsprogs ntfs-3g exfatprogs
```

### 1. Identificar con precisión el disco y sus particiones

Listar todos los bloques conectados:

```bash
lsblk -o NAME,PATH,SIZE,FSTYPE,FSVER,LABEL,UUID,MODEL,SERIAL,MOUNTPOINT
```

Ampliar información si hace falta:

```bash
sudo blkid
sudo fdisk -l
```

Confirmar para cada disco:

- capacidad real
- modelo y serie
- tipo de sistema de archivos
- partición concreta a montar, por ejemplo `/dev/sda1`
- UUID exacto de esa partición

Ejemplo de lectura esperada:

- SSD NVMe del sistema: `/dev/nvme0n1` o similar
- disco USB con datos de 2 TB: `/dev/sda1`
- disco USB con datos de 5 TB: `/dev/sdb1`

Si el disco tiene varias particiones, no asumir que haya que montar todas. Identificar primero cuál contiene realmente los datos útiles.

### 2. Comprobar salud SMART del disco físico

Para un disco USB:

```bash
sudo smartctl -a /dev/sda
```

Si la caja USB o el bridge no expone SMART correctamente:

```bash
sudo smartctl -a -d sat /dev/sda
```

Lanzar un autotest corto si el disco lo soporta:

```bash
sudo smartctl -t short -d sat /dev/sda
```

Repetir con el resto de discos físicos que se vayan a integrar.

Señales mínimas para continuar:

- el disco responde a SMART o, al menos, no muestra fallos graves del bridge USB
- no hay alertas claras de fallo inminente
- no aparecen errores crecientes que desaconsejen ponerlo en producción

Si el disco presenta errores serios, no continuar sin copiar antes los datos importantes.

### 3. Verificar el sistema de archivos antes de montarlo en escritura

Antes de fijarlo en `fstab`, confirmar qué formato tiene la partición:

```bash
lsblk -f
sudo blkid /dev/sda1
```

#### Caso `ext4`

Comprobación no destructiva:

```bash
sudo e2fsck -f -n /dev/sda1
```

Notas:

- la partición debe estar desmontada
- `-n` obliga a no escribir cambios

#### Caso `exFAT`

Comprobación no destructiva:

```bash
sudo fsck.exfat -n /dev/sda1
```

#### Caso `NTFS`

En Linux no hay una reparación completa equivalente a `chkdsk /f`. Flujo recomendado:

1. Montar primero en solo lectura para validar que el contenido es visible.
2. Si el volumen aparece como sucio, hibernado o con apagado incorrecto, conectarlo temporalmente a Windows y ejecutar `chkdsk /f`.
3. Usar `ntfsfix` solo como corrección mínima cuando no haya otra opción inmediata.

Ejemplo de corrección básica:

```bash
sudo ntfsfix /dev/sda1
```

`ntfsfix` no sustituye una comprobación completa en Windows.

### 4. Hacer un primer montaje manual de validación

Crear un punto temporal de inspección:

```bash
sudo mkdir -p /mnt/import-test
```

Montaje manual según el tipo de sistema de archivos.

#### `ext4`

```bash
sudo mount -o ro /dev/sda1 /mnt/import-test
```

#### `NTFS`

```bash
sudo mount -t ntfs-3g -o ro /dev/sda1 /mnt/import-test
```

#### `exFAT`

```bash
sudo mount -t exfat -o ro /dev/sda1 /mnt/import-test
```

Validar contenido:

```bash
ls -la /mnt/import-test | head
df -h /mnt/import-test
```

Si el contenido es el esperado:

```bash
sudo umount /mnt/import-test
sudo rmdir /mnt/import-test
```

Este paso evita fijar en `fstab` un disco equivocado o un sistema de archivos dañado.

### 5. Crear el punto de montaje definitivo

Usar el punto de montaje final según el rol del disco:

```bash
sudo mkdir -p /mnt/hd2t
sudo mkdir -p /mnt/hd5t
```

Regla de uso en este proyecto:

- si el disco con datos va a sustituir a `hd2t`, montarlo en `/mnt/hd2t`
- si el disco con datos va a sustituir a `hd5t`, montarlo en `/mnt/hd5t`
- si se trata de un disco auxiliar o temporal, usar un punto explícito como `/mnt/import`

Ejemplo para un volumen auxiliar:

```bash
sudo mkdir -p /mnt/import
```

Antes de fijar el montaje permanente, verificar que el directorio de destino no contiene archivos locales que luego quedarían ocultos al montar el disco encima:

```bash
sudo ls -la /mnt/hd2t
sudo ls -la /mnt/hd5t
```

Si el directorio ya tiene contenido, moverlo o revisarlo antes de continuar.

### 6. Obtener el `UUID` exacto de la partición

```bash
sudo blkid /dev/sda1
```

Ejemplos de salida:

- `UUID="2c4d2d64-..." TYPE="ext4"`
- `UUID="7A3C-11F0" TYPE="exfat"`
- `UUID="1C48A1CE48A1A6F2" TYPE="ntfs"`

Usar siempre el valor exacto devuelto por `blkid`.

### 7. Configurar `fstab` según el formato

Editar el fichero:

```bash
sudo nano /etc/fstab
```

#### Opción `ext4`

```fstab
UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  /mnt/hd2t  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10s  0  2
UUID=yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy  /mnt/hd5t  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10s  0  2
```

#### Opción `NTFS`

Antes de usar esta entrada, confirmar el UID y GID del usuario que debe acceder al contenido:

```bash
id
```

Entrada recomendada:

```fstab
UUID=XXXXXXXXXXXXXXXX  /mnt/hd2t  ntfs-3g  uid=1000,gid=1000,umask=0022,noatime,nofail,x-systemd.device-timeout=10s  0  0
UUID=YYYYYYYYYYYYYYYY  /mnt/hd5t  ntfs-3g  uid=1000,gid=1000,umask=0022,noatime,nofail,x-systemd.device-timeout=10s  0  0
```

#### Opción `exFAT`

Igual que en `NTFS`, ajustar `uid` y `gid` al usuario real:

```bash
id
```

Entrada recomendada:

```fstab
UUID=XXXX-XXXX  /mnt/hd2t  exfat  defaults,uid=1000,gid=1000,umask=0022,noatime,nofail,x-systemd.device-timeout=10s  0  0
UUID=YYYY-YYYY  /mnt/hd5t  exfat  defaults,uid=1000,gid=1000,umask=0022,noatime,nofail,x-systemd.device-timeout=10s  0  0
```

Notas de diseño:

- `UUID=` evita problemas si cambia el orden de `/dev/sdX`.
- `nofail` evita que un disco USB ausente bloquee el arranque.
- `noatime` reduce escrituras innecesarias.
- `x-systemd.device-timeout=10s` evita esperas largas si un disco tarda en aparecer.
- En `NTFS` y `exFAT`, `uid`, `gid` y `umask` sustituyen los permisos POSIX reales.

### 8. Ajustar permisos según el tipo de sistema de archivos

#### Discos `ext4`

`ext4` conserva propietarios y permisos reales. Primero montar:

```bash
sudo mount -a
```

Inspeccionar el contenido:

```bash
ls -la /mnt/hd2t | head -20
```

Opciones habituales:

- si el disco ya tiene una estructura válida y sus permisos son correctos, no tocar nada
- si todo el contenido debe pasar a ser propiedad del usuario principal del homelab, aplicar un cambio masivo con criterio

```bash
sudo chown -R <usuario>:<usuario> /mnt/hd2t
```

No ejecutar `chown -R` a ciegas sobre discos muy grandes sin confirmar antes que no romperá permisos útiles existentes.

#### Discos `NTFS` y `exFAT`

No guardan permisos POSIX completos. El control de acceso se define en el montaje.

Valores prácticos habituales:

- `uid=1000,gid=1000` para un único usuario principal
- `umask=0022` para lectura general y escritura del propietario
- `umask=0002` si se quiere escritura compartida a nivel de grupo

Si cambia el usuario o grupo efectivo del homelab, actualizar la línea de `fstab`.

### 9. Probar el montaje automático

Aplicar `fstab` sin reiniciar:

```bash
sudo mount -a
```

Comprobar resultado:

```bash
findmnt /mnt/hd2t
df -h /mnt/hd2t
ls -la /mnt/hd2t | head
```

Si el disco debe ser escribible, validar escritura:

```bash
touch /mnt/hd2t/.write-test
rm /mnt/hd2t/.write-test
```

Si el punto de montaje no corresponde a `hd2t`, sustituir la ruta por la que aplique.

Después, reiniciar y validar otra vez:

```bash
sudo reboot
```

Tras el reinicio:

```bash
findmnt /mnt/hd2t
lsblk -f
```

Si también has montado `hd5t`, repetir la comprobación con:

```bash
findmnt /mnt/hd5t
df -h /mnt/hd5t
```

### 10. Recomendaciones operativas para el homelab

- Si `hd2t` o `hd5t` vienen con datos ya organizados, mantener la estructura y adaptar después los bind mounts de los servicios a esas carpetas reales.
- Evitar montar la raíz completa del disco directamente dentro de un contenedor si no hace falta; es preferible exponer carpetas concretas como `media`, `music`, `downloads` o `backups`.
- Para bibliotecas heredadas de Windows, `NTFS` o `exFAT` son válidos para una migración inicial, pero `ext4` sigue siendo la mejor opción a largo plazo en un host Linux permanente.
- No usar discos heredados como almacén de bases de datos o datos críticos de Docker; esos datos deben permanecer en el SSD NVMe.
- Si un mismo disco contendrá multimedia y backups, separar ambos usos en carpetas distintas desde el primer día.
- Si el disco tiene varias carpetas raíz desordenadas, normalizarlas antes de exponerlas a Jellyfin, Navidrome, Audiobookshelf o Stash.

## Almacenamiento

### Uso recomendado dentro de este proyecto

| Ruta | Dispositivo esperado | Tipo de contenido |
|---|---|---|
| `/` | SSD NVMe | Sistema operativo, Docker, configuraciones y datos persistentes |
| `/mnt/hd2t` | Disco USB existente de 2 TB o equivalente | Multimedia general, descargas y backups |
| `/mnt/hd5t` | Disco USB existente de 5 TB o equivalente | Biblioteca multimedia de Stash |

### Resumen por formato

| Formato | Ventajas | Limitaciones |
|---|---|---|
| `ext4` | Mejor integración con Linux, permisos reales, menor fricción | Menor compatibilidad con Windows |
| `NTFS` | Útil si el disco viene de Windows y no se quiere migrar aún | Reparación más limitada desde Linux |
| `exFAT` | Muy portable entre sistemas | Sin permisos POSIX reales ni journaling |

### Decisiones de diseño

- Los servicios deben mantener sus **datos críticos** en el SSD NVMe.
- Los discos USB se reservan para **datos grandes**, restaurables o menos sensibles a latencia.
- Si un disco heredado pasa a ocupar el rol de `hd2t` o `hd5t`, la ruta de montaje debe respetar esa convención para no romper documentación futura ni configuraciones de servicios.
- Si el disco externo finalmente puede borrarse, el flujo correcto deja de ser este documento y pasa a ser `docs/00-hardware/03-preparacion-discos.md`.

## Backup
- Antes de fijar un disco con datos en `fstab`, registrar la salida de `lsblk -f` y `blkid`.
- Si el contenido es importante, hacer una copia previa de las carpetas críticas antes del primer montaje en escritura en la Raspberry Pi.
- Guardar una copia de `/etc/fstab` una vez validado.
- Si un disco viene de Windows, asegurarse de que no quedó en hibernación o apagado rápido antes de dejarlo montado de forma permanente en Linux.
- Si SMART ya muestra señales de degradación, priorizar la copia del contenido antes de usar ese disco como parte estable del homelab.

## Referencias
- `docs/00-hardware/01-material-necesario.md`
- `docs/00-hardware/02-esquema-conexiones.md`
- `docs/00-hardware/03-preparacion-discos.md`
- `docs/00-hardware/05-arranque-nvme.md`
- `SERVICES.md`
- `smartctl`
- `e2fsck`
- `ntfsfix`
- `fsck.exfat`
- `/etc/fstab`
