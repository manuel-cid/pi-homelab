# Preparación de Discos

## Descripción

Procedimiento para preparar el almacenamiento del homelab antes del despliegue de servicios. Este documento cubre la validación de discos, pruebas SMART, particionado, formateo en **ext4**, etiquetado, montaje automático con `fstab` y la estrategia de uso de cada unidad.

El objetivo es dejar tres roles bien definidos:

- **SSD NVMe**: sistema operativo, Docker Engine, configuraciones y datos persistentes de servicios.
- **`hd2t`**: multimedia general, descargas y copias de seguridad.
- **`hd5t`**: biblioteca multimedia dedicada de Stash.

Este documento aplica a discos nuevos o vacíos que se pueden reformatear. Si alguno de los discos USB ya contiene datos y no debe tocarse, usa [04-discos-con-datos.md](04-discos-con-datos.md). La conexión física previa se describe en [02-esquema-conexiones.md](02-esquema-conexiones.md) y el arranque definitivo desde el SSD se documenta en [05-arranque-nvme.md](05-arranque-nvme.md).

## Requisitos Previos

- Haber completado o validado [01-material-necesario.md](01-material-necesario.md).
- Tener conectados físicamente el **SSD NVMe**, **`hd2t`** y **`hd5t`** según [02-esquema-conexiones.md](02-esquema-conexiones.md).
- Arrancar temporalmente con Raspberry Pi OS ya instalado, aunque todavía sea desde microSD.
- Acceso por terminal con un usuario con permisos de `sudo`.
- Confirmar que **`hd2t`** y **`hd5t`** pueden borrarse por completo.

## Estrategia de Almacenamiento

| Disco | Sistema de archivos | Etiqueta | Punto de montaje | Uso |
|-------|---------------------|----------|------------------|-----|
| SSD NVMe | Gestionado por la instalación del sistema | Según instalación | `/` y sistema base | Raspberry Pi OS, Docker, configs, volúmenes, bases de datos y logs |
| Disco USB 2 TB | `ext4` | `hd2t` | `/srv/storage/hd2t` | Multimedia general, descargas y backups |
| Disco USB 5 TB | `ext4` | `hd5t` | `/srv/storage/hd5t` | Biblioteca multimedia de Stash |

### Criterio operativo

- El **SSD NVMe** no se usa para bibliotecas multimedia masivas.
- Los datos críticos de servicios viven en el **NVMe**, no en discos USB.
- **`hd2t`** absorbe almacenamiento grande pero no crítico para latencia: media, descargas y backups.
- **`hd5t`** queda dedicado a Stash para aislar ese catálogo del resto del contenido.

## Advertencia Sobre el SSD NVMe

En esta fase **no hace falta reparticionar manualmente el SSD NVMe** si va a recibir el sistema mediante clonación o instalación en [05-arranque-nvme.md](05-arranque-nvme.md). Ese proceso crea o adapta las particiones del disco del sistema.

En otras palabras:

- Prepara aquí los discos USB **`hd2t`** y **`hd5t`**.
- Reserva el **NVMe** para el sistema y para los datos persistentes de Docker una vez el arranque desde NVMe esté completado.
- No ejecutes `mkfs` sobre el NVMe salvo que estés rehaciendo deliberadamente la instalación del sistema.

## Identificación Segura de Discos

Antes de tocar nada, identifica cada unidad por **modelo, tamaño y ruta de dispositivo**.

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,MODEL
sudo blkid
```

Ejemplo de interpretación esperada:

- El **NVMe** aparecerá normalmente como `/dev/nvme0n1`.
- Los discos USB aparecerán normalmente como `/dev/sda` y `/dev/sdb`, pero **el orden puede cambiar** entre reinicios.

No te fíes solo del nombre del dispositivo. Verifica siempre:

- Tamaño aproximado: `500G`, `2T`, `5T`.
- Modelo o fabricante.
- Si el disco ya tiene particiones montadas.

## Paquetes de Utilidad

Instala las herramientas necesarias antes de continuar:

```bash
sudo apt update
sudo apt install -y smartmontools parted e2fsprogs util-linux
```

## Comprobación SMART Inicial

Antes de particionar y formatear, valida el estado básico de cada disco.

### Detectar información SMART

```bash
sudo smartctl -i /dev/nvme0n1
sudo smartctl -i /dev/sda
sudo smartctl -i /dev/sdb
```

En algunas carcasas USB puede hacer falta indicar el tipo de bridge:

```bash
sudo smartctl -d sat -i /dev/sda
sudo smartctl -d sat -i /dev/sdb
```

### Lanzar pruebas cortas

```bash
sudo smartctl -t short /dev/nvme0n1
sudo smartctl -t short /dev/sda
sudo smartctl -t short /dev/sdb
```

Espera el tiempo que indique cada disco y consulta el resultado:

```bash
sudo smartctl -a /dev/nvme0n1
sudo smartctl -a /dev/sda
sudo smartctl -a /dev/sdb
```

Si un disco reporta errores SMART, sectores reasignados en aumento, fallos de lectura o un estado general preocupante, no lo incorpores al homelab hasta revisarlo.

## Particionado de `hd2t` y `hd5t`

Los dos discos USB se preparan con:

- Tabla de particiones **GPT**.
- Una única partición ocupando todo el disco.
- Sistema de archivos **ext4**.

### 1. Desmontar particiones si el sistema las ha montado automáticamente

```bash
sudo umount /dev/sda1 2>/dev/null || true
sudo umount /dev/sdb1 2>/dev/null || true
```

### 2. Crear tabla GPT y partición primaria

Sustituye las rutas si en tu caso `hd2t` y `hd5t` aparecen con otros nombres.

```bash
sudo parted -s /dev/sda mklabel gpt
sudo parted -s /dev/sda mkpart primary ext4 0% 100%

sudo parted -s /dev/sdb mklabel gpt
sudo parted -s /dev/sdb mkpart primary ext4 0% 100%
```

### 3. Verificar el resultado

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT /dev/sda /dev/sdb
```

Lo esperado es disponer de:

- `/dev/sda1` como partición principal del disco de 2 TB.
- `/dev/sdb1` como partición principal del disco de 5 TB.

## Formateo y Etiquetado

Aplica `ext4` con las etiquetas definitivas:

```bash
sudo mkfs.ext4 -L hd2t /dev/sda1
sudo mkfs.ext4 -L hd5t /dev/sdb1
```

Confirma después:

```bash
sudo blkid /dev/sda1 /dev/sdb1
lsblk -f /dev/sda /dev/sdb
```

Las etiquetas deben quedar exactamente así:

- `hd2t`
- `hd5t`

## Estructura de Montaje

Crea puntos de montaje persistentes:

```bash
sudo mkdir -p /srv/storage/hd2t
sudo mkdir -p /srv/storage/hd5t
```

## Montaje Manual de Prueba

Antes de tocar `fstab`, prueba el montaje manual:

```bash
sudo mount /dev/disk/by-label/hd2t /srv/storage/hd2t
sudo mount /dev/disk/by-label/hd5t /srv/storage/hd5t
```

Verifica:

```bash
df -h | grep -E 'hd2t|hd5t'
lsblk -f
```

Si el montaje es correcto, crea ya la estructura inicial dentro de cada disco:

```bash
sudo mkdir -p /srv/storage/hd2t/media
sudo mkdir -p /srv/storage/hd2t/downloads
sudo mkdir -p /srv/storage/hd2t/backups
sudo mkdir -p /srv/storage/hd5t/media
```

Si todo es correcto, desmonta de nuevo para preparar el montaje persistente:

```bash
sudo umount /srv/storage/hd2t
sudo umount /srv/storage/hd5t
```

## Montaje Automático con `fstab`

Haz copia de seguridad del fichero antes de editar:

```bash
sudo cp /etc/fstab /etc/fstab.bak
```

Abre `/etc/fstab` y añade estas líneas al final:

```fstab
LABEL=hd2t  /srv/storage/hd2t  ext4  defaults,nofail,noatime,x-systemd.device-timeout=10  0  2
LABEL=hd5t  /srv/storage/hd5t  ext4  defaults,nofail,noatime,x-systemd.device-timeout=10  0  2
```

### Significado de las opciones

- `defaults`: opciones estándar de lectura y escritura.
- `nofail`: permite arrancar aunque un disco USB no esté presente.
- `noatime`: reduce escrituras innecesarias.
- `x-systemd.device-timeout=10`: evita bloqueos largos en arranque si una unidad no responde.

### Validación inmediata

Después de guardar `fstab`, valida sin reiniciar:

```bash
sudo mount -a
findmnt /srv/storage/hd2t
findmnt /srv/storage/hd5t
```

Si `mount -a` no devuelve errores, el montaje persistente está correcto.

## Permisos Iniciales

Si más adelante los contenedores Docker van a escribir directamente en estos discos, conviene definir desde el principio un propietario operativo. Un patrón simple es usar el usuario principal de administración del host.

Ejemplo:

```bash
sudo chown -R $USER:$USER /srv/storage/hd2t
sudo chown -R $USER:$USER /srv/storage/hd5t
```

Si vas a trabajar con un UID/GID fijo para contenedores, ajusta permisos más adelante según ese criterio. Lo importante en esta fase es que el montaje funcione y quede estable.

## Verificación Final

Comprueba el estado final del almacenamiento:

```bash
lsblk -f
df -h
sudo blkid
```

Debes poder verificar lo siguiente:

- El **NVMe** queda identificado como disco del sistema o candidato a serlo en la siguiente fase.
- **`hd2t`** está montado en `/srv/storage/hd2t`.
- **`hd5t`** está montado en `/srv/storage/hd5t`.
- Ambos discos USB usan **ext4** y conservan sus etiquetas.
- `mount -a` no genera errores.

## Distribución Recomendada de Datos

Usa desde el inicio una separación clara de contenidos:

| Ruta | Contenido |
|------|-----------|
| `/` sobre SSD NVMe | Raspberry Pi OS y sistema base |
| `/var/lib/docker` sobre SSD NVMe | Imágenes, capas y red de Docker |
| Volúmenes persistentes de servicios sobre SSD NVMe | Configuraciones, bases de datos, uploads y logs |
| `/srv/storage/hd2t/media` | Películas, series, música, libros y contenido general |
| `/srv/storage/hd2t/downloads` | Descargas temporales o de ingestión |
| `/srv/storage/hd2t/backups` | Backups locales del host y de servicios |
| `/srv/storage/hd5t/media` | Biblioteca multimedia dedicada |

### Qué no conviene mover a USB

- Bases de datos de servicios.
- Configuraciones de contenedores.
- Volúmenes con escrituras frecuentes.
- Logs operativos del host o de Docker.

Ese contenido debe permanecer en el **SSD NVMe** para reducir latencia, mejorar estabilidad y evitar depender de discos USB para el funcionamiento básico del homelab.

## Errores Comunes a Evitar

- Formatear el disco equivocado por confiar solo en `/dev/sdX`.
- Intentar preparar aquí un disco USB que ya contiene datos útiles.
- Usar `fstab` con rutas de dispositivo como `/dev/sda1` en vez de `LABEL=` o `UUID=`.
- Guardar bibliotecas multimedia masivas en el SSD NVMe.
- Mover bases de datos y volúmenes críticos de Docker a discos USB mecánicos.
- Reiniciar sin haber probado antes `sudo mount -a`.

## Siguiente Paso

Con los discos ya preparados:

- Continúa con [05-arranque-nvme.md](05-arranque-nvme.md) para migrar el arranque del sistema al SSD NVMe.
- Si en realidad uno o ambos discos externos ya tenían datos y no deben reformatearse, sigue [04-discos-con-datos.md](04-discos-con-datos.md).

## Referencias

- Raspberry Pi OS
- `smartmontools`
- `parted`
- `mkfs.ext4`
- `fstab`
