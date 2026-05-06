# Preparación de Discos

## Descripción
Procedimiento para preparar el almacenamiento del homelab antes de desplegar servicios: identificación segura de unidades, revisión SMART, particionado, formateo en `ext4`, etiquetado y montaje automático con `fstab`.

La distribución objetivo del proyecto es esta:

- **SSD NVMe**: sistema operativo, Docker Engine, configuraciones y datos persistentes de todos los servicios.
- **`hd2t`**: multimedia general, descargas y backups locales.
- **`hd5t`**: biblioteca multimedia dedicada a Stash.

Este documento está pensado para discos **vacíos o reutilizables**. Si alguno de los discos USB ya contiene datos que no deben perderse, no seguir este flujo para ese disco y usar `docs/00-hardware/04-discos-con-datos.md`.

## Requisitos Previos
- Haber revisado `docs/00-hardware/01-material-necesario.md`.
- Haber conectado físicamente el hardware según `docs/00-hardware/02-esquema-conexiones.md`.
- Tener acceso shell con privilegios `sudo`.
- Confirmar qué disco es el SSD NVMe y qué discos USB se convertirán en `hd2t` y `hd5t`.
- Tener claro si el SSD NVMe se usará con una instalación limpia del sistema o con una migración posterior desde microSD; el arranque desde NVMe se documenta en `docs/00-hardware/05-arranque-nvme.md`.
- Asegurarse de que los discos USB que se van a preparar pueden borrarse por completo.
- Puertos implicados:
  - PCIe interno para el SSD NVMe.
  - 2 puertos USB 3.0 para `hd2t` y `hd5t`.

## Docker Compose
No aplica en esta fase. Aquí solo se prepara la base de almacenamiento sobre la que después se desplegarán los contenedores.

## Configuración

### Estrategia de almacenamiento objetivo

| Dispositivo | Etiqueta | Sistema de archivos | Punto de montaje | Uso |
|---|---|---|---|---|
| SSD NVMe 500 GB | No aplica | `ext4` dentro de la instalación del sistema | `/` | Raspberry Pi OS, Docker, configuraciones y datos persistentes |
| HDD USB 2 TB | `hd2t` | `ext4` | `/mnt/hd2t` | Multimedia general, descargas y backups |
| HDD USB 5 TB | `hd5t` | `ext4` | `/mnt/hd5t` | Biblioteca multimedia de Stash |

### Principios antes de tocar particiones

- Identificar siempre cada disco por **ruta, capacidad, modelo y serie**. No confiar solo en `/dev/sda` o `/dev/sdb`.
- No ejecutar `mklabel`, `mkfs`, `wipefs` ni comandos destructivos sobre discos con datos válidos.
- Mantener el **SSD NVMe** como almacenamiento operativo del host y de Docker; no usarlo como destino principal de bibliotecas multimedia grandes.
- Usar **GPT + una única partición `ext4`** por cada disco USB nuevo simplifica `fstab`, mantenimiento y recuperación.
- Para los discos USB del homelab, la convención de etiquetas debe quedar fijada desde el principio: `hd2t` y `hd5t`.
- Los servicios deben montar sus datos persistentes en el NVMe y sus bibliotecas multimedia en los discos USB.

### Paquetes necesarios

Instalar primero las herramientas base:

```bash
sudo apt update
sudo apt install -y smartmontools parted e2fsprogs util-linux
```

### 1. Identificar correctamente las unidades

Listar todos los dispositivos conectados:

```bash
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MODEL,SERIAL,MOUNTPOINT
```

Ampliar la información si hace falta:

```bash
sudo blkid
sudo fdisk -l
```

Lectura esperada:

- el SSD del sistema suele aparecer como `/dev/nvme0n1`
- los discos USB suelen aparecer como `/dev/sda`, `/dev/sdb`, etc.
- cada disco debe poder asociarse sin ambigüedad a su capacidad:
  - 500 GB -> SSD NVMe
  - 2 TB -> futuro `hd2t`
  - 5 TB -> futuro `hd5t`

Antes de continuar, anotar qué dispositivo físico corresponde a cada rol.

### 2. Comprobar salud SMART antes de usarlos

#### SSD NVMe

```bash
sudo smartctl -a /dev/nvme0
sudo smartctl -t short /dev/nvme0
```

#### Discos USB

Primero probar SMART directo:

```bash
sudo smartctl -a /dev/sda
sudo smartctl -a /dev/sdb
```

Si la caja USB o el bridge no lo expone bien, repetir con `-d sat`:

```bash
sudo smartctl -a -d sat /dev/sda
sudo smartctl -a -d sat /dev/sdb
sudo smartctl -t short -d sat /dev/sda
sudo smartctl -t short -d sat /dev/sdb
```

Señales mínimas para continuar:

- el disco responde a SMART o, al menos, no presenta errores graves del bridge USB
- no hay alertas claras de fallo inminente
- no aparecen errores crecientes que hagan desaconsejable poner el disco en producción

Si un disco presenta problemas serios, no seguir con él como parte estable del homelab.

### 3. Definir qué se prepara en este documento y qué no

#### Discos USB `hd2t` y `hd5t`

En este documento sí se preparan completamente:

- tabla GPT
- partición única
- formato `ext4`
- etiqueta
- punto de montaje
- entrada en `fstab`

#### SSD NVMe

El NVMe también debe acabar en `ext4`, pero normalmente **no se formatea aquí manualmente** salvo que se esté haciendo una instalación limpia muy controlada. En la práctica:

- si vas a instalar Raspberry Pi OS directamente en el NVMe, el instalador crea sus particiones
- si vas a migrar desde microSD al NVMe, seguir `docs/00-hardware/05-arranque-nvme.md`

La decisión importante en esta fase es reservar el NVMe para:

- sistema operativo
- Docker Engine
- archivos `compose`, `.env` y configuraciones
- volúmenes persistentes, bases de datos, uploads, cachés e índices de servicios

### 4. Crear tabla GPT y partición única en los discos USB nuevos

Este paso **borra todo el contenido** del disco seleccionado.

Ejemplo para el disco de 2 TB que será `hd2t`:

```bash
sudo parted /dev/sda --script mklabel gpt
sudo parted /dev/sda --script mkpart primary ext4 1MiB 100%
```

Ejemplo para el disco de 5 TB que será `hd5t`:

```bash
sudo parted /dev/sdb --script mklabel gpt
sudo parted /dev/sdb --script mkpart primary ext4 1MiB 100%
```

Validar el resultado:

```bash
lsblk -o NAME,PATH,SIZE,FSTYPE,PARTTYPE,PARTLABEL,LABEL,MOUNTPOINT
```

El resultado esperado es una partición por disco, normalmente `/dev/sda1` y `/dev/sdb1`.

### 5. Formatear en `ext4` y aplicar etiquetas

Formatear y etiquetar `hd2t`:

```bash
sudo mkfs.ext4 -L hd2t /dev/sda1
```

Formatear y etiquetar `hd5t`:

```bash
sudo mkfs.ext4 -L hd5t /dev/sdb1
```

Verificar el resultado:

```bash
lsblk -f
sudo blkid /dev/sda1 /dev/sdb1
```

Si en algún momento hace falta corregir la etiqueta sin reformatear:

```bash
sudo e2label /dev/sda1 hd2t
sudo e2label /dev/sdb1 hd5t
```

### 6. Crear puntos de montaje

```bash
sudo mkdir -p /mnt/hd2t
sudo mkdir -p /mnt/hd5t
```

Permisos base recomendados:

```bash
sudo chown root:root /mnt/hd2t /mnt/hd5t
sudo chmod 755 /mnt/hd2t /mnt/hd5t
```

Todavía no hace falta afinar permisos por servicio. Eso se hará más adelante cuando existan los directorios concretos de medios, descargas y backups.

### 7. Configurar montaje automático en `fstab`

Obtener UUID y etiquetas:

```bash
lsblk -f
sudo blkid /dev/sda1 /dev/sdb1
```

Editar `/etc/fstab`:

```bash
sudo nano /etc/fstab
```

Añadir estas entradas para los discos USB:

```fstab
LABEL=hd2t  /mnt/hd2t  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10s  0  2
LABEL=hd5t  /mnt/hd5t  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10s  0  2
```

Notas de diseño:

- `LABEL=` hace `fstab` más legible que usar UUID largos.
- `nofail` evita que un problema puntual en un disco USB bloquee el arranque completo.
- `noatime` reduce escrituras innecesarias.
- `x-systemd.device-timeout=10s` evita esperas largas si una unidad no responde.

El SSD NVMe no necesita aquí una entrada manual adicional si ya forma parte de la instalación o migración normal del sistema.

### 8. Probar el montaje y validar persistencia

Aplicar `fstab` sin reiniciar:

```bash
sudo mount -a
```

Comprobar que no hay errores:

```bash
findmnt /mnt/hd2t
findmnt /mnt/hd5t
df -h /mnt/hd2t /mnt/hd5t
```

Prueba funcional mínima:

```bash
sudo touch /mnt/hd2t/.test-hd2t
sudo touch /mnt/hd5t/.test-hd5t
ls -la /mnt/hd2t /mnt/hd5t
sudo rm /mnt/hd2t/.test-hd2t /mnt/hd5t/.test-hd5t
```

Si todo es correcto, reiniciar y validar otra vez:

```bash
sudo reboot
```

Tras el reinicio:

```bash
findmnt /mnt/hd2t
findmnt /mnt/hd5t
lsblk -f
```

### 9. Política de uso recomendada

#### SSD NVMe

- Alojar el sistema operativo.
- Alojar Docker Engine, `docker compose`, archivos `.env`, configuraciones y volúmenes persistentes.
- Alojar bases de datos, uploads, índices, miniaturas y logs.
- Mantener en el NVMe rutas equivalentes a `/home/<usuario>/homelab/` para `compose`, configuraciones y datos críticos de servicios.
- Evitar usarlo como destino principal de descargas pesadas o bibliotecas multimedia grandes.

#### `hd2t`

- Usarlo para multimedia general.
- Usarlo para descargas temporales o definitivas.
- Reservar espacio para backups locales del NVMe y configuraciones críticas.
- Alojar rutas equivalentes a:
  - `/mnt/hd2t/jellyfin/media`
  - `/mnt/hd2t/navidrome/music`
  - `/mnt/hd2t/audiobookshelf/data`
  - `/mnt/hd2t/calibre/library`
  - `/mnt/hd2t/transmission/downloads`
  - `/mnt/hd2t/backups`

#### `hd5t`

- Dedicación exclusiva o casi exclusiva al contenido de Stash.
- Mantener este volumen separado simplifica permisos, organización y futuras migraciones.
- Alojar una ruta equivalente a `/mnt/hd5t/stash/data`.

### 10. Estructura mínima sugerida en los discos USB

No es obligatorio crearla todavía, pero deja una base coherente para fases posteriores:

```bash
sudo mkdir -p /mnt/hd2t/jellyfin/media
sudo mkdir -p /mnt/hd2t/navidrome/music
sudo mkdir -p /mnt/hd2t/audiobookshelf/data
sudo mkdir -p /mnt/hd2t/calibre/library
sudo mkdir -p /mnt/hd2t/transmission/downloads
sudo mkdir -p /mnt/hd2t/backups
sudo mkdir -p /mnt/hd5t/stash/data
```

Si prefieres una capa intermedia más genérica, también es válido empezar con esta estructura y refinarla más adelante:

```bash
sudo mkdir -p /mnt/hd2t/media
sudo mkdir -p /mnt/hd2t/downloads
sudo mkdir -p /mnt/hd2t/backups
sudo mkdir -p /mnt/hd5t/stash
```

## Almacenamiento

### Resumen operativo

| Ruta | Dispositivo esperado | Tipo de contenido |
|---|---|---|
| `/` | SSD NVMe | Sistema operativo y base del host |
| `/mnt/hd2t` | HDD USB 2 TB | Multimedia general, descargas y backups |
| `/mnt/hd5t` | HDD USB 5 TB | Biblioteca multimedia de Stash |

### Decisiones de diseño

- Los servicios deben mantener sus **datos críticos** en el SSD NVMe.
- Los discos USB se reservan para **datos grandes**, restaurables o menos sensibles a latencia.
- Las etiquetas `hd2t` y `hd5t` deben mantenerse estables para que `fstab`, scripts y documentación futura no dependan del orden cambiante de `/dev/sdX`.
- Si un disco externo ya trae contenido útil, debe integrarse con `docs/00-hardware/04-discos-con-datos.md` en lugar de reformatearse.

## Backup
- Guardar una copia de `/etc/fstab` después de validarlo.
- Registrar la salida de `lsblk -f` y `blkid` ayuda a recuperar el sistema tras un cambio de discos o de carcasa.
- Incluir más adelante en la estrategia de copias:
  - configuración del host en el SSD NVMe
  - volúmenes persistentes Docker en el SSD NVMe
  - contenido crítico alojado en `hd2t` si no existe otra copia maestra
- La política completa de backup se documentará en la fase correspondiente.

## Referencias
- `docs/00-hardware/01-material-necesario.md`
- `docs/00-hardware/02-esquema-conexiones.md`
- `docs/00-hardware/04-discos-con-datos.md`
- `docs/00-hardware/05-arranque-nvme.md`
- `SERVICES.md`
- `smartctl`
- `parted`
- `mkfs.ext4`
- `/etc/fstab`
