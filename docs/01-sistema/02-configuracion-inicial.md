# Configuración inicial del sistema

## Descripción
Procedimiento para completar la **configuración base del host** en el **primer arranque ya desde el SSD NVMe**, después de haber migrado el sistema desde la microSD.

El objetivo de este documento es dejar la Raspberry Pi 5 en un estado operativo y coherente para continuar con el endurecimiento del host y la preparación del almacenamiento del homelab. Al terminar, el sistema debe estar actualizado, arrancando desde el **NVMe**, con **hostname**, **zona horaria** y **locale** definidos, y con una **swapfile ubicada en `hd2t`** para evitar escribir swap sobre el SSD principal.

## Requisitos Previos
- Haber completado `docs/01-sistema/01-instalacion-os.md`.
- Haber migrado correctamente el sistema al SSD NVMe siguiendo `docs/00-hardware/05-arranque-nvme.md`.
- Poder acceder por SSH al host con el usuario administrador creado en la instalación inicial.
- Tener conectados:
  - el **SSD NVMe**, que ahora debe alojar `/`
  - el disco **hd2t** por USB, que se usará para la swap y más adelante para multimedia y backups
- Tener conexión de red en la LAN para actualizar paquetes.
- Puertos implicados:
  - `22/tcp` para administración SSH dentro de la red local
  - no se expone ningún puerto a internet en esta fase

## Docker Compose
No aplica en esta fase. Aquí solo se termina de preparar el sistema operativo base que después alojará Docker Engine y los servicios del homelab.

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado al terminar este documento |
|---|---|
| Medio de arranque activo | SSD NVMe |
| Sistema base | actualizado |
| Hostname | definitivo para el homelab |
| Zona horaria | correcta, por ejemplo `Europe/Madrid` |
| Locale | definido y generado |
| Swap | activa en `hd2t`, no en NVMe |
| microSD | ya no necesaria para operar normalmente |

### Estrategia recomendada

El flujo recomendado es este:

1. Confirmar que el sistema realmente ha arrancado desde el NVMe.
2. Actualizar completamente el sistema base.
3. Fijar identidad del host: hostname, zona horaria y locale.
4. Preparar el montaje mínimo de `hd2t` necesario para alojar la swap.
5. Crear y activar una swapfile en `hd2t`.
6. Verificar que el host queda listo para continuar con seguridad base y estructura final de directorios.

Decisiones operativas de esta fase:

- El **NVMe** queda reservado para sistema, Docker, configuraciones y datos persistentes del homelab.
- La **swap no se coloca en el NVMe** para evitar castigar innecesariamente el disco con escrituras evitables.
- El disco **`hd2t`** se usa como soporte de swap por ser almacenamiento secundario mecánico, aceptando que será más lento que el NVMe pero suficiente como red de seguridad ante picos de memoria.
- La estructura definitiva de montajes y rutas se documenta en `docs/01-sistema/04-estructura-directorios.md`; aquí solo se realiza la preparación mínima necesaria para que la swap quede operativa.

### 1. Validar que el sistema ya arranca desde el NVMe

Nada de lo siguiente tiene sentido si el host sigue arrancando desde la microSD. Confirmarlo primero:

```bash
findmnt /
findmnt /boot/firmware
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,MOUNTPOINT
```

Resultado esperado:

- `/` debe residir en el **SSD NVMe**, normalmente algo como `/dev/nvme0n1p2`
- `/boot/firmware` también debe corresponder al arranque definitivo configurado tras la migración
- la microSD, si sigue insertada, no debe ser la raíz activa del sistema

Comprobación adicional útil:

```bash
mount | grep " / "
```

Si todavía ves la raíz en un dispositivo tipo `/dev/mmcblk0p2`, **detén esta fase** y vuelve a revisar `docs/00-hardware/05-arranque-nvme.md`.

### 2. Actualizar completamente el sistema base

Con el sistema ya arrancado desde NVMe, actualizar paquetes y limpiar dependencias obsoletas:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove -y
sudo apt autoclean
```

Comprobar si el kernel o componentes base han cambiado:

```bash
uname -a
cat /etc/os-release
```

Si `apt` ha actualizado componentes críticos del sistema, reiniciar antes de seguir:

```bash
sudo reboot
```

Tras reconectar por SSH, repetir brevemente la validación del NVMe:

```bash
findmnt /
```

### 3. Definir o corregir el hostname del host

Comprobar el nombre actual:

```bash
hostnamectl
cat /etc/hostname
```

Si necesitas ajustarlo, usar `hostnamectl`:

```bash
sudo hostnamectl set-hostname rpi5-homelab
```

Después, revisar `/etc/hosts` para que el nombre corto del equipo resuelva localmente. El bloque habitual debe quedar parecido a este:

```text
127.0.0.1       localhost
127.0.1.1       rpi5-homelab
```

Validar:

```bash
hostname
hostnamectl --static
getent hosts 127.0.1.1
```

Recomendación:

- usar un hostname corto, estable y sin caracteres especiales
- evitar nombres genéricos como `raspberrypi` para que el host sea fácil de identificar en la LAN y más adelante en Tailscale

### 4. Configurar zona horaria

Ver el estado actual:

```bash
timedatectl
```

Configurar la zona horaria deseada. Para este homelab se asume `Europe/Madrid`:

```bash
sudo timedatectl set-timezone Europe/Madrid
```

Validar:

```bash
timedatectl
date
```

Esto es importante porque más adelante afectará a:

- logs del sistema
- tareas programadas
- timestamps de backups
- horarios visibles en interfaces web de los servicios

### 5. Configurar locale

Comprobar el locale actual:

```bash
locale
localectl status
```

Generar y aplicar el locale deseado. Un valor razonable para este entorno es `es_ES.UTF-8`:

```bash
sudo sed -i 's/^# *es_ES.UTF-8 UTF-8/es_ES.UTF-8 UTF-8/' /etc/locale.gen
sudo locale-gen
sudo update-locale LANG=es_ES.UTF-8
```

Si prefieres mantener mensajes del sistema en inglés pero formatos regionales europeos, también puedes usar esta alternativa:

```bash
sudo update-locale LANG=en_US.UTF-8 LC_TIME=es_ES.UTF-8 LC_NUMERIC=es_ES.UTF-8 LC_MONETARY=es_ES.UTF-8
```

Importante:

- elige **una sola estrategia** y mantenla consistente
- evita fijar `LC_ALL` de forma persistente salvo que tengas una necesidad muy concreta
- si ya configuraste el locale correcto desde Raspberry Pi Imager, valida y no cambies nada sin necesidad

Aplicar los cambios en la sesión actual:

```bash
logout
```

Tras volver a entrar por SSH:

```bash
locale
```

### 6. Preparar `hd2t` para alojar la swap

Antes de crear la swap, identificar correctamente el disco y su sistema de archivos:

```bash
lsblk -f
sudo blkid
```

En muchos montajes `hd2t` aparecerá como algo parecido a `/dev/sda1`, pero **no asumas el nombre del dispositivo**. Usa siempre su **UUID** para montaje persistente.

Crear el punto de montaje que se utilizará también en la estructura definitiva:

```bash
sudo mkdir -p /mnt/hd2t
```

Obtener el UUID real de la partición:

```bash
sudo blkid <DISPOSITIVO_HD2T>
```

Ejemplo de línea válida para esta fase en `/etc/fstab`:

```fstab
UUID=<UUID_HD2T>  /mnt/hd2t  ext4  defaults,nofail,x-systemd.device-timeout=10,noatime  0  2
```

Añadir la línea con el UUID real, guardar y probar:

```bash
sudo mount -a
findmnt /mnt/hd2t
```

Si `mount -a` devuelve errores, corrígelos antes de continuar.

Notas:

- este documento asume que `hd2t` ya tiene una partición Linux utilizable, por ejemplo `ext4`
- la definición completa de carpetas de medios, descargas y backups dentro de `hd2t` se documenta después en `docs/01-sistema/04-estructura-directorios.md`

### 7. Desactivar una swap previa en el disco del sistema si existiera

En algunos sistemas puede existir una swap previa heredada de la instalación inicial. Antes de crear la nueva, comprobarlo:

```bash
swapon --show
free -h
```

Si aparece una swap en el disco del sistema o gestionada por `dphys-swapfile`, desactivarla primero:

```bash
sudo swapoff -a
```

Después, comprobar si `dphys-swapfile` está instalado:

```bash
dpkg -l | grep dphys-swapfile
```

Si existe, dejarlo deshabilitado para que no recree swap sobre el disco del sistema:

```bash
sudo systemctl disable --now dphys-swapfile
sudo apt purge -y dphys-swapfile
```

Verificar de nuevo:

```bash
swapon --show
```

En este punto no debería aparecer ninguna swap activa.

### 8. Crear y activar la swapfile en `hd2t`

Crear un directorio oculto y restringido:

```bash
sudo mkdir -p /mnt/hd2t/.swap
sudo chmod 700 /mnt/hd2t/.swap
```

Tamaño recomendado para este homelab en una Raspberry Pi 5 con 8 GB de RAM:

- **4 GB** como valor base conservador
- **8 GB** si prevés picos fuertes de memoria y aceptas más latencia cuando el sistema empiece a paginar

Ejemplo con **4 GB**:

```bash
sudo dd if=/dev/zero of=/mnt/hd2t/.swap/swapfile bs=1M count=4096 status=progress
sudo chmod 600 /mnt/hd2t/.swap/swapfile
sudo mkswap /mnt/hd2t/.swap/swapfile
sudo swapon /mnt/hd2t/.swap/swapfile
```

Validar:

```bash
swapon --show
free -h
```

Persistir la activación en `/etc/fstab`:

```fstab
/mnt/hd2t/.swap/swapfile  none  swap  sw,nofail,pri=10  0  0
```

El uso de `nofail` tanto en el montaje de `hd2t` como en la entrada de swap permite que el sistema siga arrancando aunque ese disco USB no esté disponible, simplemente sin swap activa.

Comprobar la sintaxis final de montajes y swap:

```bash
sudo mount -a
sudo swapon --show
```

### 9. Ajustar la política de uso de swap

No interesa que el sistema pagine agresivamente en un disco USB mecánico. Ajustar `vm.swappiness` a un valor moderado:

```bash
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-homelab.conf
sudo sysctl --system
```

Validar:

```bash
sysctl vm.swappiness
```

Un valor bajo reduce el uso de swap mientras aún queda memoria libre y encaja mejor con este diseño:

- RAM como recurso principal
- swap como colchón de seguridad
- HDD externo como ubicación de compromiso para preservar el NVMe

### 10. Validación final del host

Ejecutar una comprobación rápida de todo lo hecho:

```bash
hostnamectl
timedatectl
locale
findmnt /
findmnt /mnt/hd2t
swapon --show
free -h
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,MOUNTPOINT
```

Estado esperado:

- el host arranca desde el **SSD NVMe**
- el sistema está actualizado
- el hostname es el definitivo
- la zona horaria es correcta
- el locale está aplicado
- `hd2t` está montado en `/mnt/hd2t`
- la swap activa está en `/mnt/hd2t/.swap/swapfile`

### 11. Qué queda pendiente tras este documento

Tras completar esta fase, el siguiente orden recomendado es:

1. Aplicar endurecimiento básico del host en `docs/01-sistema/03-seguridad-base.md`.
2. Completar la estructura permanente de directorios y montajes en `docs/01-sistema/04-estructura-directorios.md`.
3. Instalar Docker y continuar con los servicios del homelab en las fases posteriores.

## Almacenamiento

### Estado esperado tras completar este documento

| Ruta o medio | Dispositivo esperado | Uso |
|---|---|---|
| `/` | SSD NVMe | sistema operativo |
| `/boot/firmware` | SSD NVMe o arranque definitivo tras la migración | archivos de arranque |
| `/home/<usuario>` | SSD NVMe | usuario administrador y configuración base |
| `/mnt/hd2t` | HDD externo de 2 TB | swap, multimedia y backups |
| `/mnt/hd2t/.swap/swapfile` | archivo sobre `hd2t` | swap del host |
| microSD | opcional o retirada | recuperación puntual si se conserva |

### Decisiones de diseño

- Todo lo operativo del homelab debe residir en el **NVMe**, excepto la swap.
- La **swap se saca del NVMe** para evitar escrituras continuas sobre el disco principal.
- `hd2t` se usa como disco auxiliar para absorber swap, descargas, multimedia y backups.
- `hd5t` todavía no se configura en este documento porque se tratará junto con la estructura completa de almacenamiento.

## Backup
- Guardar copia de estos archivos tras completar la fase:
  - `/etc/hostname`
  - `/etc/hosts`
  - `/etc/default/locale`
  - `/etc/fstab`
  - `/etc/sysctl.d/99-homelab.conf`
- Conservar la salida de estos comandos como referencia de inventario y recuperación:
  - `lsblk -f`
  - `blkid`
  - `swapon --show`
  - `findmnt /`
  - `findmnt /mnt/hd2t`
- Anotar el UUID real de `hd2t` evita errores al rehacer montajes o sustituir el disco.
- Si mantienes la microSD como respaldo de emergencia, etiquétala claramente para no confundirla con el sistema operativo activo en NVMe.

## Referencias
- `SERVICES.md`
- `docs/01-sistema/01-instalacion-os.md`
- `docs/00-hardware/05-arranque-nvme.md`
- `docs/01-sistema/03-seguridad-base.md`
- `docs/01-sistema/04-estructura-directorios.md`
- Raspberry Pi OS Lite 64-bit
- `hostnamectl`
- `timedatectl`
- `locale`
- `lsblk`
- `blkid`
- `swapon`
- `/etc/fstab`
