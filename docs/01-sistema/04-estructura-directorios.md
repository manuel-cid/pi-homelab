# Estructura de directorios y montajes persistentes

## Descripción
Procedimiento para definir la **estructura estable de carpetas** del homelab y dejar configurados los **montajes persistentes** del **SSD NVMe**, `hd2t` y `hd5t`.

El objetivo de este documento es que, antes de instalar Docker y desplegar servicios, exista una política clara y consistente sobre **qué se guarda en cada disco**, **qué rutas se usarán en los `docker-compose.yml`** y **cómo asegurar que todo se monta automáticamente al arrancar** mediante `/etc/fstab`.

En este homelab la regla es simple:

- el **SSD NVMe** almacena todo lo operativo: sistema, configuraciones, `docker-compose.yml`, ficheros `.env`, secretos locales, bases de datos y **datos persistentes de servicios**
- `hd2t` almacena **multimedia general, descargas y backups**
- `hd5t` almacena **exclusivamente el contenido multimedia de Stash**

## Requisitos Previos
- Haber completado `docs/01-sistema/01-instalacion-os.md`.
- Haber completado `docs/01-sistema/02-configuracion-inicial.md`.
- Haber completado `docs/01-sistema/03-seguridad-base.md`.
- Haber migrado correctamente el sistema al SSD NVMe siguiendo `docs/00-hardware/05-arranque-nvme.md`.
- Tener conectados y detectados en el host:
  - el **SSD NVMe** como disco del sistema
  - el disco **hd2t** por USB
  - el disco **hd5t** por USB
- Poder usar `sudo` con el usuario administrador.
- Tener identificados los **UUID** reales de `hd2t` y `hd5t`.
- Haber decidido el nombre del usuario administrador que alojará `/home/<usuario>/homelab`.
- Puertos implicados:
  - no aplica ningún puerto nuevo en esta fase
  - solo se usan los accesos administrativos ya definidos en la documentación previa

## Docker Compose
No aplica todavía en esta fase. Aquí se prepara la estructura de rutas que después consumirán los `docker-compose.yml` del homelab.

Las decisiones de este documento son las que deben reflejarse más adelante en todos los despliegues:

- rutas operativas y volúmenes persistentes en `/home/<usuario>/homelab`
- bibliotecas multimedia, descargas y backups en `/mnt/hd2t`
- almacenamiento multimedia dedicado de Stash en `/mnt/hd5t`

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado al terminar este documento |
|---|---|
| Ruta base del homelab | `/home/<usuario>/homelab` en el SSD NVMe |
| Datos persistentes de servicios | bajo `/home/<usuario>/homelab/data` |
| Punto de montaje de `hd2t` | `/mnt/hd2t` |
| Punto de montaje de `hd5t` | `/mnt/hd5t` |
| Multimedia general | `hd2t` |
| Descargas | `hd2t` |
| Backups locales | `hd2t` |
| Multimedia de Stash | `hd5t` |
| Montajes persistentes | definidos por UUID en `/etc/fstab` |

### Estrategia recomendada

El flujo recomendado es este:

1. Verificar qué discos están presentes y qué sistema de archivos usa cada uno.
2. Crear los puntos de montaje persistentes `/mnt/hd2t` y `/mnt/hd5t`.
3. Registrar ambos discos en `/etc/fstab` usando **UUID**, nunca nombres volátiles como `/dev/sda1`.
4. Crear una estructura de carpetas estable y predecible para el homelab en el SSD NVMe.
5. Crear la estructura multimedia y de backup en los discos USB.
6. Validar montajes, permisos y espacio disponible.
7. Tomar esta estructura como contrato para todos los documentos posteriores.

Decisiones operativas de esta fase:

- el **SSD NVMe** es el lugar para todo lo que el homelab necesita para funcionar
- los **HDDs externos** no alojan bases de datos, configuraciones internas críticas ni ficheros `.env`
- `hd2t` combina **multimedia**, **descargas** y **backups** porque son datos grandes y secuenciales
- `hd5t` se reserva para **Stash** para aislar su biblioteca del resto de contenidos
- las rutas deben ser suficientemente explícitas para que un `bind mount` en Docker resulte obvio al leerlo

### 1. Inventariar discos y sistemas de archivos

Antes de escribir nada en `/etc/fstab`, identificar con precisión los discos:

```bash
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT
sudo blkid
findmnt /
```

Resultado esperado:

- `/` debe estar en el **SSD NVMe**
- `hd2t` y `hd5t` deben aparecer como discos USB diferenciables
- cada disco debe tener una partición con un sistema de archivos Linux utilizable, preferiblemente `ext4`

Si alguno de los dos HDDs no está formateado todavía o usa un sistema de archivos no deseado, corrígelo antes de fijar montajes permanentes.

Recomendaciones prácticas:

- usar etiquetas legibles como `hd2t` y `hd5t` ayuda a identificar los discos
- el montaje persistente debe seguir haciéndose por **UUID**
- no dependas del orden `/dev/sda`, `/dev/sdb`, porque puede cambiar entre reinicios

### 2. Crear los puntos de montaje permanentes

Crear los puntos de montaje definitivos:

```bash
sudo mkdir -p /mnt/hd2t
sudo mkdir -p /mnt/hd5t
```

Comprobar que existen:

```bash
ls -ld /mnt/hd2t /mnt/hd5t
```

Estos son los únicos puntos de montaje que deben consumir los servicios. No conviene montar los discos bajo rutas ambiguas ni dependientes de entornos de escritorio como `/media/<usuario>/...`.

### 3. Definir montajes persistentes en `/etc/fstab`

Obtener primero los UUID reales:

```bash
sudo blkid <DISPOSITIVO_HD2T>
sudo blkid <DISPOSITIVO_HD5T>
```

Ejemplo de configuración recomendada en `/etc/fstab`:

```fstab
UUID=<UUID_HD2T>  /mnt/hd2t  ext4  defaults,nofail,x-systemd.device-timeout=10,noatime  0  2
UUID=<UUID_HD5T>  /mnt/hd5t  ext4  defaults,nofail,x-systemd.device-timeout=10,noatime  0  2
```

Notas sobre estas opciones:

- `defaults` aplica el comportamiento estándar de montaje
- `nofail` evita que el sistema quede bloqueado si un disco USB no está presente al arrancar
- `x-systemd.device-timeout=10` reduce la espera durante el arranque si falta el dispositivo
- `noatime` disminuye escrituras innecesarias
- si `hd2t` ya quedó registrado en `docs/01-sistema/02-configuracion-inicial.md` para alojar la swap, **no dupliques la línea**: reutiliza esa entrada y añade solo la de `hd5t` si todavía no existe

Editar `/etc/fstab` con cuidado y después validar:

```bash
sudo mount -a
findmnt /mnt/hd2t
findmnt /mnt/hd5t
df -h /mnt/hd2t /mnt/hd5t
```

Si `mount -a` devuelve cualquier error, corrígelo antes de continuar. No sigas creando estructura de carpetas sobre puntos de montaje rotos o sin montar.

### 4. Crear la ruta base del homelab en el SSD NVMe

La raíz operativa del homelab vive bajo el home del usuario administrador:

```bash
mkdir -p /home/<usuario>/homelab/{compose,env,scripts,data}
```

Estructura base recomendada:

```text
/home/<usuario>/homelab/
├── docker-compose.yml
├── .env
├── compose/
├── env/
├── scripts/
└── data/
```

Criterio de uso:

- `docker-compose.yml`: compose principal si optas por una orquestación central en la raíz
- `compose/`: composes separados por servicio o por stack
- `env/`: variables `.env` específicas de servicios si no quieres concentrarlo todo en la raíz
- `scripts/`: automatizaciones operativas del homelab
- `data/`: volúmenes persistentes y estado interno de servicios

Si prefieres una organización por stack en lugar de una única raíz con `compose/`, mantén el mismo principio: **los ficheros de operación y los volúmenes persistentes siguen yendo en el NVMe**. Los backups locales pesados siguen teniendo como destino `hd2t`, no el SSD.

### 5. Crear la estructura de datos persistentes en el SSD

Crear una base coherente para volúmenes de servicios:

```bash
mkdir -p /home/<usuario>/homelab/data
```

No es obligatorio precrear todos los directorios de servicios en esta fase. Lo importante ahora es fijar la convención: cada servicio tendrá su propio subdirectorio dentro de `data/` cuando se despliegue.

Principios de diseño para `data/`:

- un directorio por servicio
- nombres simples, estables y sin espacios
- las bases de datos van también en el NVMe
- el estado interno del servicio vive en el SSD aunque sus bibliotecas o ficheros pesados estén fuera

Ejemplo de estructura razonable:

```text
/home/<usuario>/homelab/data/
├── jellyfin/
├── navidrome/
├── audiobookshelf/
├── calibre-web/
├── stash/
├── transmission/
├── postgres/
├── mariadb/
└── redis/
```

Importante:

- las **bases de datos**, índices, metadatos y configuraciones van en el NVMe
- los **uploads**, bibliotecas o colecciones grandes pueden vivir en HDDs si el servicio lo permite
- no mezcles ficheros operativos del homelab con contenido multimedia de usuario

### 6. Crear la estructura multimedia, descargas y backups en `hd2t`

Crear las carpetas persistentes del disco de 2 TB:

```bash
sudo mkdir -p /mnt/hd2t/{jellyfin/media,navidrome/music,audiobookshelf/{audiobooks,podcasts},calibre/library,downloads/{transmission,incomplete,complete},backups}
sudo chown -R <usuario>:<usuario> /mnt/hd2t/jellyfin /mnt/hd2t/navidrome /mnt/hd2t/audiobookshelf /mnt/hd2t/calibre /mnt/hd2t/downloads /mnt/hd2t/backups
```

Estructura objetivo:

```text
/mnt/hd2t/
├── .swap/
├── jellyfin/
│   └── media/
├── navidrome/
│   └── music/
├── audiobookshelf/
│   ├── audiobooks/
│   └── podcasts/
├── calibre/
│   └── library/
├── downloads/
│   ├── transmission/
│   ├── incomplete/
│   └── complete/
└── backups/
```

Política para `hd2t`:

- `.swap/` queda reservada para la swap creada en `docs/01-sistema/02-configuracion-inicial.md`
- **Jellyfin**: películas, series y otros medios generales
- **Navidrome**: biblioteca musical
- **Audiobookshelf**: audiolibros y podcasts
- **Calibre-Web**: biblioteca de ebooks
- **Transmission** y automatizaciones asociadas: descargas en curso y terminadas
- **Backups**: destino local de Borgmatic o estrategia equivalente

Este disco no debe almacenar:

- bases de datos de aplicaciones
- configuraciones de contenedores
- secretos, `.env` o ficheros de despliegue
- volúmenes críticos cuyo acceso aleatorio penalice claramente el rendimiento

Importante:

- no cambies la propiedad ni los permisos de `/mnt/hd2t/.swap`
- mantén `swapfile` como `root:root` y con permisos restrictivos, tal como quedó en la fase anterior

### 7. Crear la estructura multimedia dedicada en `hd5t`

Crear la estructura del disco reservado a Stash:

```bash
sudo mkdir -p /mnt/hd5t/stash/data
sudo chown -R <usuario>:<usuario> /mnt/hd5t/stash
```

Estructura objetivo:

```text
/mnt/hd5t/
└── stash/
    └── data/
```

Separar Stash en su propio disco simplifica:

- el dimensionamiento de espacio
- la política de backup y exclusión
- la gestión de permisos y mantenimiento
- el aislamiento frente al resto de bibliotecas multimedia del homelab

### 8. Validar permisos, montajes y capacidad

Comprobaciones recomendadas tras crear toda la estructura:

```bash
findmnt /mnt/hd2t
findmnt /mnt/hd5t
df -h /home/<usuario>/homelab /mnt/hd2t /mnt/hd5t
ls -lah /home/<usuario>/homelab
find /mnt/hd2t -maxdepth 3 -type d | sort
find /mnt/hd5t -maxdepth 3 -type d | sort
```

Estado esperado:

- `/home/<usuario>/homelab` reside en el **SSD NVMe**
- `hd2t` y `hd5t` están montados correctamente
- las carpetas existen en el disco correcto
- el usuario administrador puede preparar archivos y directorios sin fricción

### 9. Política de uso para futuros documentos de servicios

Esta fase fija un contrato que debe respetarse en toda la documentación posterior:

- los `docker-compose.yml` y `.env` viven en el **SSD NVMe**
- los volúmenes de configuración y bases de datos viven en el **SSD NVMe**
- las bibliotecas multimedia y descargas viven en los **HDDs**
- los backups locales pesados viven en `hd2t`
- la swap del host sigue en `/mnt/hd2t/.swap/swapfile`
- **Stash** monta su biblioteca desde `hd5t`

Ejemplo conceptual de `bind mounts` coherentes:

```yaml
services:
  jellyfin:
    volumes:
      - /home/<usuario>/homelab/data/jellyfin:/config
      - /mnt/hd2t/jellyfin/media:/media

  navidrome:
    volumes:
      - /home/<usuario>/homelab/data/navidrome:/data
      - /mnt/hd2t/navidrome/music:/music:ro

  transmission:
    volumes:
      - /home/<usuario>/homelab/data/transmission:/config
      - /mnt/hd2t/downloads/transmission:/downloads

  stash:
    volumes:
      - /home/<usuario>/homelab/data/stash:/root/.stash
      - /mnt/hd5t/stash/data:/data
```

La idea clave no es copiar exactamente estas rutas en todos los servicios, sino mantener siempre la misma separación:

- **estado operativo** en SSD
- **datos grandes de usuario** en HDD

## Almacenamiento

### Estado esperado tras completar este documento

| Ruta o medio | Dispositivo esperado | Uso |
|---|---|---|
| `/` | SSD NVMe | sistema operativo |
| `/home/<usuario>/homelab` | SSD NVMe | composes, `.env`, scripts y datos persistentes |
| `/home/<usuario>/homelab/data` | SSD NVMe | volúmenes de servicios |
| `/mnt/hd2t` | HDD externo de 2 TB | multimedia general, descargas y backups |
| `/mnt/hd5t` | HDD externo de 5 TB | multimedia de Stash |
| `/mnt/hd2t/.swap/swapfile` | HDD externo de 2 TB | swap del host |
| `/mnt/hd2t/backups` | HDD externo de 2 TB | backups locales |
| `/mnt/hd5t/stash/data` | HDD externo de 5 TB | biblioteca multimedia de Stash |

### Decisiones de diseño

- El **SSD NVMe** soporta toda la operativa del homelab y debe bastar por sí solo para mantener el sistema, Docker y los volúmenes persistentes.
- Los **HDDs externos** se usan para datos grandes, secuenciales y menos sensibles a latencia.
- La separación entre **datos operativos** y **contenidos multimedia** simplifica mantenimiento, backup, migración y resolución de incidencias.
- Los montajes persistentes se definen por **UUID** en `/etc/fstab` para evitar dependencias de nombres de dispositivo inestables.

## Backup
- Guardar copia de `/etc/fstab` tras validar los montajes definitivos.
- Conservar la salida de inventario de:
  - `lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT`
  - `blkid`
  - `findmnt /mnt/hd2t`
  - `findmnt /mnt/hd5t`
  - `df -h /home/<usuario>/homelab /mnt/hd2t /mnt/hd5t`
- Incluir en la estrategia de backup del SSD al menos:
  - `docker-compose.yml`
  - ficheros `.env`
  - scripts operativos
  - configuraciones bajo `/home/<usuario>/homelab`
  - volúmenes persistentes críticos bajo `/home/<usuario>/homelab/data`
- Excluir la swap (`/mnt/hd2t/.swap/swapfile`) de cualquier copia de seguridad.
- Tratar `hd2t/backups` como destino local de backup, no como única copia válida.
- Documentar cualquier cambio de UUID, sistema de archivos o estructura de carpetas antes de tocar los `docker-compose.yml` que dependan de esas rutas.

## Referencias
- `SERVICES.md`
- `docs/00-hardware/05-arranque-nvme.md`
- `docs/01-sistema/01-instalacion-os.md`
- `docs/01-sistema/02-configuracion-inicial.md`
- `docs/01-sistema/03-seguridad-base.md`
- `/etc/fstab`
- `lsblk`
- `blkid`
- `findmnt`
- Docker Compose
