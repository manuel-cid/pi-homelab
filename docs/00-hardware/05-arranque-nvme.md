# Arranque desde NVMe

## Descripción
Procedimiento para migrar el arranque de la Raspberry Pi 5 desde la microSD al SSD NVMe montado en la carcasa M.2, de forma que el sistema operativo, Docker, configuraciones y datos persistentes queden alojados en el almacenamiento principal previsto para el homelab.

Este documento cubre la actualización del firmware EEPROM, el ajuste del orden de arranque, tres métodos de migración al NVMe y la validación final sin microSD. La preparación física del hardware y de los discos externos se documenta en `docs/00-hardware/01-material-necesario.md`, `docs/00-hardware/02-esquema-conexiones.md`, `docs/00-hardware/03-preparacion-discos.md` y `docs/00-hardware/04-discos-con-datos.md`.

## Requisitos Previos
- Haber revisado `docs/00-hardware/01-material-necesario.md`.
- Haber montado el SSD NVMe en la carcasa y conectado el conjunto según `docs/00-hardware/02-esquema-conexiones.md`.
- Tener una Raspberry Pi OS funcional arrancando desde microSD al menos una vez.
- Confirmar que el SSD NVMe aparece en el sistema, normalmente como `/dev/nvme0n1`.
- Tener acceso shell con privilegios `sudo`.
- Usar una fuente estable, preferiblemente la oficial de 27 W, para reducir problemas durante la migración y el primer arranque desde NVMe.
- Haber decidido si los discos USB `hd2t` y `hd5t` se prepararán desde cero (`docs/00-hardware/03-preparacion-discos.md`) o se integrarán con datos existentes (`docs/00-hardware/04-discos-con-datos.md`).
- Disponer de una copia de seguridad mínima de cualquier dato importante de la microSD antes de migrar.
- Puertos implicados:
  - PCIe interno para el SSD NVMe.
  - 1 ranura microSD solo para la fase inicial y como recuperación temporal.
  - Ethernet recomendado para administrar la migración con estabilidad.

## Docker Compose
No aplica en esta fase. Aquí se migra el disco de arranque del host base sobre el que después se desplegarán los contenedores.

## Configuración

### Objetivo final

| Elemento | Estado esperado tras la migración |
|---|---|
| Arranque del sistema | Desde el SSD NVMe |
| MicroSD | Retirada del equipo y conservada como respaldo temporal |
| Sistema operativo | Ejecutándose desde el NVMe |
| Datos persistentes del homelab | Alojados en el NVMe |
| `hd2t` y `hd5t` | Siguen siendo discos USB de datos, no discos de arranque |

### Estrategia recomendada

El flujo recomendado es este:

1. Verificar que el NVMe es visible para el sistema.
2. Actualizar el firmware EEPROM del bootloader.
3. Ajustar el orden de arranque para priorizar NVMe o almacenamiento masivo.
4. Migrar el sistema al NVMe.
5. Apagar, retirar la microSD y arrancar solo con NVMe.
6. Verificar que `/` y la partición de arranque están realmente en el NVMe.

Recomendaciones prácticas antes de empezar:

- Mantener la microSD intacta hasta haber completado varias comprobaciones con éxito.
- Guardar una copia rápida de los ficheros de arranque actuales antes de migrar:

```bash
mkdir -p ~/backup-pre-nvme
sudo cp /etc/fstab ~/backup-pre-nvme/fstab.microSD
sudo cp /boot/firmware/cmdline.txt ~/backup-pre-nvme/cmdline.microSD 2>/dev/null || sudo cp /boot/cmdline.txt ~/backup-pre-nvme/cmdline.microSD
```

- Si `hd2t` y `hd5t` ya están conectados, identificar muy bien cada disco con `lsblk` antes de tocar nada.
- Para minimizar errores durante la migración, es razonable hacer el primer arranque de prueba solo con el NVMe conectado como almacenamiento principal.

### 1. Verificar que el SSD NVMe se detecta correctamente

Comprobar que el sistema ve el NVMe:

```bash
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,MODEL,MOUNTPOINT
```

Confirmar con más detalle:

```bash
sudo fdisk -l
sudo dmesg | grep -i nvme
```

Resultado esperado:

- el SSD aparece normalmente como `/dev/nvme0n1`
- no hay errores graves de enlace PCIe o detección
- la capacidad coincide con el NVMe instalado

Si el NVMe no aparece, no continuar todavía. Revisar montaje físico, carcasa, cableado PCIe y alimentación.

### 2. Actualizar el firmware EEPROM del bootloader

Actualizar índices y paquetes base:

```bash
sudo apt update
sudo apt full-upgrade -y
```

Comprobar la versión actual del EEPROM:

```bash
sudo rpi-eeprom-update
```

Aplicar la actualización disponible del bootloader:

```bash
sudo rpi-eeprom-update -a
```

Reiniciar para cargar el nuevo firmware:

```bash
sudo reboot
```

Tras volver al sistema, confirmar otra vez:

```bash
sudo rpi-eeprom-update
```

Notas:

- Si el comando indica que ya está al día, no hace falta forzar nada más.
- Hacer la migración al NVMe sin haber actualizado el bootloader añade una causa frecuente de fallos de arranque evitables.

### 3. Cambiar el orden de arranque para priorizar NVMe

Abrir la utilidad de configuración:

```bash
sudo raspi-config
```

Ruta habitual:

- `Advanced Options`
- `Boot Order`

Seleccionar la opción que priorice arranque desde NVMe o almacenamiento masivo USB antes que la microSD. El texto exacto puede variar según la versión de Raspberry Pi OS, pero el objetivo es que el bootloader intente arrancar desde el NVMe sin depender de la microSD.

Salir guardando cambios y reiniciar si `raspi-config` lo solicita.

Consideraciones:

- Si el clon se ha hecho con `dd`, la microSD y el NVMe pueden quedar con identificadores de partición idénticos; en ese caso retirar la microSD no es opcional, es obligatorio.
- Aunque el orden de arranque se configure bien, retirar la microSD simplifica mucho la validación inicial.

### 4. Elegir el método de migración

| Método | Cuándo usarlo | Ventajas | Limitaciones |
|---|---|---|---|
| `Raspberry Pi Imager` | Si prefieres reinstalar limpio directamente en el NVMe | Flujo asistido y simple | No es una clonación exacta de la microSD |
| `dd` | Si quieres un clon bit a bit y puedes trabajar offline o desde otro entorno de arranque | Réplica exacta del disco | No se recomienda clonar la microSD activa en caliente |
| `rsync` | Si la Raspberry Pi ya está arrancada desde microSD y quieres migrar al NVMe desde la propia máquina | Control fino y válido en la propia Pi | Requiere preparar particiones y ajustar `fstab` y `cmdline.txt` |

Para este homelab, el método más práctico en una Raspberry Pi ya instalada y funcionando suele ser `rsync`.

Tabla rápida de decisión:

- Usa `Raspberry Pi Imager` si todavía estás en una fase temprana y prefieres una instalación limpia en el NVMe.
- Usa `dd` si necesitas una copia exacta y puedes clonar fuera del sistema arrancado desde microSD.
- Usa `rsync` si ya tienes una Raspberry Pi operativa y quieres migrarla al NVMe con control fino desde la propia máquina.

### 5. Método A: migración asistida con Raspberry Pi Imager

Este método sirve para dejar el NVMe listo con una instalación nueva de Raspberry Pi OS, manteniendo la microSD como referencia o respaldo. No es un clon exacto del sistema actual, pero sí una forma sencilla y soportada de pasar el arranque al NVMe.

Flujo recomendado:

1. Conectar el NVMe a una máquina desde la que puedas grabarlo, o prepararlo antes del montaje final si la carcasa lo permite.
2. Abrir Raspberry Pi Imager.
3. Seleccionar la misma edición de Raspberry Pi OS que usarás en la Pi, preferiblemente Lite 64-bit.
4. Elegir el SSD NVMe como destino.
5. Configurar las opciones avanzadas si quieres dejar predefinidos usuario, SSH, hostname y red de emergencia.
6. Grabar la imagen en el NVMe.
7. Montar de nuevo el NVMe en la Raspberry Pi, arrancar con la microSD retirada y completar la configuración.
8. Restaurar después la configuración útil del host y del homelab desde copia de seguridad si ya existía una instalación previa.

Cuándo tiene sentido:

- si todavía no hay datos relevantes en la microSD
- si prefieres una reinstalación limpia antes que migrar una instalación ya tocada
- si vas a seguir la documentación posterior del sistema desde cero

Si lo que quieres es mantener exactamente el sistema existente, usar `dd` o `rsync`.

### 6. Método B: clonación exacta con `dd`

Usar este método solo cuando puedas hacerlo sin arrancar desde la microSD que vas a clonar, por ejemplo:

- desde otro equipo Linux
- desde un entorno de rescate
- desde la Raspberry Pi arrancada temporalmente desde otro medio

Requisitos específicos:

- el NVMe debe tener igual o mayor tamaño que la microSD origen
- hay que identificar con total certeza origen y destino

Ejemplo típico:

- origen: `/dev/mmcblk0`
- destino: `/dev/nvme0n1`

Comprobación previa:

```bash
lsblk -o NAME,PATH,SIZE,MODEL,MOUNTPOINT
```

Clonado:

```bash
sudo dd if=/dev/mmcblk0 of=/dev/nvme0n1 bs=64M conv=fsync,status=progress
sync
```

Notas críticas:

- `dd` sobrescribe el disco de destino completo.
- No invertir `if=` y `of=`; ese error destruye el sistema origen.
- El clon conserva la tabla de particiones y los identificadores del disco original.

Si el NVMe es mayor que la microSD, tras el primer arranque desde NVMe conviene expandir el sistema de archivos con `raspi-config`:

```bash
sudo raspi-config
```

Ruta habitual:

- `Advanced Options`
- `Expand Filesystem`

Después, reiniciar:

```bash
sudo reboot
```

Este método obliga especialmente a retirar la microSD tras el clonado para evitar conflictos de arranque por identificadores duplicados.

### 7. Método C: migración en la propia Raspberry Pi con `rsync`

Este método permite arrancar desde la microSD actual, copiar el sistema al NVMe y ajustar después el arranque al nuevo disco.

#### 7.1. Instalar herramientas necesarias

```bash
sudo apt update
sudo apt install -y rsync parted dosfstools
```

#### 7.2. Crear particiones en el NVMe

Este paso borra el contenido actual del NVMe.

```bash
sudo parted /dev/nvme0n1 --script mklabel gpt
sudo parted /dev/nvme0n1 --script mkpart primary fat32 1MiB 513MiB
sudo parted /dev/nvme0n1 --script set 1 boot on
sudo parted /dev/nvme0n1 --script mkpart primary ext4 513MiB 100%
```

Formatear ambas particiones:

```bash
sudo mkfs.vfat -F 32 /dev/nvme0n1p1
sudo mkfs.ext4 /dev/nvme0n1p2
```

#### 7.3. Montar el sistema de destino

En Raspberry Pi OS Bookworm, la partición de arranque se monta normalmente en `/boot/firmware`. Si tu imagen usa `/boot`, sustituye esa ruta en los pasos siguientes.

```bash
sudo mkdir -p /mnt/nvme-root
sudo mount /dev/nvme0n1p2 /mnt/nvme-root
sudo mkdir -p /mnt/nvme-root/boot/firmware
sudo mount /dev/nvme0n1p1 /mnt/nvme-root/boot/firmware
```

#### 7.4. Copiar el sistema al NVMe

Copiar el sistema raíz excluyendo pseudo-sistemas de ficheros y puntos de montaje temporales:

```bash
sudo rsync -aAXH --numeric-ids --info=progress2 \
  --exclude=/boot/firmware/* \
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

Copiar la partición de arranque:

```bash
sudo rsync -aH --info=progress2 /boot/firmware/ /mnt/nvme-root/boot/firmware/
```

Si tu sistema actual usa `/boot` en vez de `/boot/firmware`, usa la ruta equivalente tanto en la exclusión anterior como en esta segunda copia.

#### 7.5. Ajustar `fstab` del sistema nuevo

Obtener los `PARTUUID` del NVMe:

```bash
ROOT_PARTUUID=$(sudo blkid -s PARTUUID -o value /dev/nvme0n1p2)
BOOT_PARTUUID=$(sudo blkid -s PARTUUID -o value /dev/nvme0n1p1)
echo "$ROOT_PARTUUID"
echo "$BOOT_PARTUUID"
```

Reescribir el `fstab` del sistema migrado:

```bash
sudo tee /mnt/nvme-root/etc/fstab >/dev/null <<EOF
proc            /proc          proc    defaults          0  0
PARTUUID=${ROOT_PARTUUID}  /              ext4    defaults,noatime  0  1
PARTUUID=${BOOT_PARTUUID}  /boot/firmware vfat    defaults          0  2
EOF
```

Si tu instalación actual usa `/boot` en vez de `/boot/firmware`, ajustar esa línea antes de continuar.

#### 7.6. Ajustar `cmdline.txt` del sistema nuevo

Sustituir la partición raíz del arranque por la del NVMe:

```bash
sudo sed -i "s#root=PARTUUID=[^ ]*#root=PARTUUID=${ROOT_PARTUUID}#g" /mnt/nvme-root/boot/firmware/cmdline.txt
```

Comprobar el resultado:

```bash
cat /mnt/nvme-root/boot/firmware/cmdline.txt
cat /mnt/nvme-root/etc/fstab
```

La línea de `cmdline.txt` debe seguir estando en una sola línea y apuntar al `PARTUUID` del NVMe.

#### 7.7. Desmontar y preparar el primer arranque real

```bash
sync
sudo umount /mnt/nvme-root/boot/firmware
sudo umount /mnt/nvme-root
```

En este punto, el contenido del sistema ya está en el NVMe y el bootloader debería poder arrancarlo una vez retirada la microSD.

### 8. Apagar, retirar la microSD y arrancar desde NVMe

Apagar la Raspberry Pi:

```bash
sudo shutdown -h now
```

Con el equipo apagado:

1. retirar la microSD
2. dejar conectado el SSD NVMe
3. opcionalmente dejar desconectados `hd2t` y `hd5t` en la primera prueba si quieres simplificar el diagnóstico
4. volver a alimentar la Raspberry Pi

Si todo está correcto, el sistema debe arrancar directamente desde el NVMe.

### 9. Verificación posterior al arranque

Comprobar qué dispositivo aloja `/`:

```bash
findmnt /
lsblk -o NAME,PATH,SIZE,FSTYPE,MOUNTPOINT
df -h /
```

Comprobar la partición de arranque:

```bash
findmnt /boot/firmware || findmnt /boot
```

Comprobar la línea de arranque efectiva:

```bash
cat /proc/cmdline
```

Resultado esperado:

- `/` está montado desde `/dev/nvme0n1p2` o equivalente
- la partición de arranque está en `/dev/nvme0n1p1`
- la microSD no aparece como disco del que depende el sistema
- `cat /proc/cmdline` referencia el NVMe por `PARTUUID` o por el dispositivo correcto
- `sudo findmnt /` y `sudo findmnt /boot/firmware` no muestran rutas bajo `/dev/mmcblk0`

Prueba adicional útil para cerrar la validación:

```bash
sudo systemctl --failed
sudo reboot
```

Tras ese segundo reinicio, repetir `findmnt /`, `findmnt /boot/firmware || findmnt /boot` y `df -h /` para confirmar que el arranque desde NVMe se mantiene de forma consistente sin depender de la microSD.

Comprobación adicional útil:

```bash
sudo rpi-eeprom-update
sudo dmesg | grep -i nvme
```

### 10. Qué hacer si no arranca desde el NVMe

Si la Raspberry Pi no arranca correctamente tras retirar la microSD:

1. Apagar el equipo.
2. Volver a insertar la microSD para recuperar el acceso.
3. Comprobar de nuevo que el NVMe aparece en `lsblk`.
4. Revisar que el EEPROM está actualizado con `sudo rpi-eeprom-update`.
5. Confirmar el orden de arranque en `sudo raspi-config`.
6. Revisar `cmdline.txt` y `fstab` en el NVMe si se usó `rsync`.
7. Si se usó `dd`, confirmar que la microSD está fuera durante la prueba.

Errores típicos:

- bootloader antiguo que no intenta arrancar desde NVMe
- `root=PARTUUID=` apuntando todavía a la microSD
- `fstab` del sistema migrado apuntando al disco equivocado
- confusión entre `/boot` y `/boot/firmware`
- discos identificados erróneamente durante la clonación

## Almacenamiento

### Estado esperado tras completar este documento

| Ruta o medio | Dispositivo esperado | Uso |
|---|---|---|
| `/` | SSD NVMe | Sistema operativo y base persistente del host |
| `/boot/firmware` | SSD NVMe partición 1 | Archivos de arranque en Raspberry Pi OS Bookworm |
| `/home/<usuario>/homelab` | SSD NVMe | Compose, configuraciones y datos persistentes de servicios |
| microSD | Fuera del equipo | Respaldo temporal y recuperación |
| `/mnt/hd2t` | HDD USB 2 TB | Multimedia general, descargas y backups |
| `/mnt/hd5t` | HDD USB 5 TB | Biblioteca multimedia de Stash |

### Decisiones de diseño

- La microSD deja de ser el almacenamiento operativo normal del homelab.
- El SSD NVMe pasa a ser el único disco del sistema y el destino principal de Docker, configuraciones y datos críticos.
- `hd2t` y `hd5t` siguen siendo volúmenes de datos grandes, no parte del arranque.
- El documento `docs/00-hardware/03-preparacion-discos.md` sigue siendo el punto de referencia para etiquetado y montaje persistente de los discos USB.

## Backup
- Conservar la microSD original sin modificar hasta haber validado varios reinicios correctos desde NVMe.
- Guardar copia de `/etc/fstab` y de `/boot/firmware/cmdline.txt` después de la migración.
- Registrar la salida de `lsblk -o NAME,PATH,SIZE,FSTYPE,MOUNTPOINT` y `sudo rpi-eeprom-update` ayuda a recuperar el host si vuelve a fallar el arranque.
- Si se usó `dd`, considerar crear una imagen de respaldo de la microSD antes de reutilizarla para otro fin.
- No mover todavía servicios ni datos grandes a los discos USB hasta haber confirmado que el host base arranca de forma estable desde NVMe.

## Referencias
- `docs/00-hardware/01-material-necesario.md`
- `docs/00-hardware/02-esquema-conexiones.md`
- `docs/00-hardware/03-preparacion-discos.md`
- `docs/00-hardware/04-discos-con-datos.md`
- `docs/01-sistema/01-instalacion-os.md`
- Raspberry Pi OS
- Raspberry Pi Imager
- `rpi-eeprom-update`
- `raspi-config`
- `dd`
- `rsync`
