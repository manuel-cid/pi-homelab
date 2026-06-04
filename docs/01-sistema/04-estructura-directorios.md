# Estructura de Directorios del Homelab

## Descripción

Procedimiento para fijar la **estructura operativa final de almacenamiento** del homelab una vez que la Raspberry Pi 5 ya arranca desde el **SSD NVMe** y tiene completada la configuración base del sistema. El objetivo es dejar una organización simple y estable: todo lo **operativo** vive en el **SSD NVMe** bajo `/home/<user>/homelab/`, mientras que los discos USB se reservan para **multimedia, descargas y backups**.

La política de este proyecto es estricta:

- El **SSD NVMe** almacena sistema, configuraciones, archivos `compose`, `.env`, datos persistentes de servicios, bases de datos, uploads y logs.
- **`/media/hd2t`** se dedica a multimedia general, descargas y copias de seguridad.
- **`/media/hd5t`** se dedica en exclusiva a la biblioteca multimedia de **Stash**.

En [03-preparacion-discos.md](../00-hardware/03-preparacion-discos.md) se validaron etiquetas, formato y montaje de los discos. Este documento **normaliza la estructura operativa final** y fija como puntos de montaje definitivos **`/media/hd2t`** y **`/media/hd5t`**.

## Requisitos Previos

- Haber completado [01-instalacion-os.md](01-instalacion-os.md).
- Haber completado [02-configuracion-inicial.md](02-configuracion-inicial.md).
- Tener la Raspberry Pi arrancando realmente desde el **SSD NVMe** según [05-arranque-nvme.md](../00-hardware/05-arranque-nvme.md).
- Tener preparados y etiquetados los discos USB como **`hd2t`** y **`hd5t`** según [03-preparacion-discos.md](../00-hardware/03-preparacion-discos.md).
- Poder acceder por terminal con el usuario administrativo y permisos de `sudo`.
- Tener decidido qué usuario local será el propietario operativo de la estructura de carpetas.

## Objetivo de esta Fase

Al terminar este documento, el estado esperado es este:

- Existe una raíz operativa única en **`/home/<user>/homelab`** sobre el **SSD NVMe**.
- Los discos USB quedan montados de forma persistente en **`/media/hd2t`** y **`/media/hd5t`** mediante **`/etc/fstab`**.
- La estructura de carpetas deja separado el almacenamiento operativo del almacenamiento masivo.
- Los futuros servicios Docker tienen rutas claras para `compose`, configuración y datos persistentes.
- Ningún servicio crítico depende de guardar bases de datos o volúmenes operativos en discos USB.

## Docker Compose

No aplica en esta fase. Aquí no se despliegan todavía contenedores, pero sí se deja preparada la estructura que usarán los `docker-compose.yml` y los bind mounts de las siguientes fases.

## Configuración

### 1. Verificar el estado actual de discos y montajes

Antes de reorganizar rutas, valida el estado real del sistema:

```bash
whoami
findmnt -no SOURCE /
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS
findmnt /media/hd2t /media/hd5t
```

Resultados esperados:

- `/` debe vivir sobre el **SSD NVMe**.
- Los discos USB deben conservar las etiquetas **`hd2t`** y **`hd5t`**.
- Si todavía aparecen montados en rutas antiguas como `/srv/storage/hd2t` o `/srv/storage/hd5t`, no es un problema: en este documento se corrige `fstab` para dejar el diseño final en `/media/...`.

### 2. Aplicar la política definitiva de almacenamiento

Usa esta distribución como criterio estable del proyecto:

| Ubicación | Disco | Uso |
|-----------|-------|-----|
| `/home/<user>/homelab/` | SSD NVMe | `compose`, configs, `.env`, volúmenes persistentes, bases de datos, uploads, logs y utilidades del homelab |
| `/media/hd2t/media/` | `hd2t` | Bibliotecas multimedia de Jellyfin, Navidrome, Audiobookshelf y Calibre-Web |
| `/media/hd2t/downloads/` | `hd2t` | Descargas temporales o procesadas |
| `/media/hd2t/backups/` | `hd2t` | Backups del host, exports y copias de datos de servicios |
| `/media/hd5t/stash/` | `hd5t` | Biblioteca multimedia dedicada de Stash |

Reglas operativas:

- No guardes bases de datos ni volúmenes críticos de aplicaciones en `hd2t` o `hd5t`.
- No uses `hd5t` para descargas, backups ni otras bibliotecas ajenas a Stash.
- No llenes el SSD NVMe con contenido multimedia masivo.
- Los siguientes documentos de servicios deben montar sus datos persistentes desde **`/home/<user>/homelab/data/<servicio>/`** salvo que se trate explícitamente de bibliotecas multimedia o backups.

### 3. Crear los puntos de montaje definitivos

Crea los puntos de montaje que usará el sistema de forma permanente:

```bash
sudo mkdir -p /media/hd2t
sudo mkdir -p /media/hd5t
```

Si existen rutas antiguas bajo `/srv/storage/`, no las borres todavía. Primero deja el nuevo montaje persistente funcionando y valida que los discos realmente quedan accesibles en `/media/...`.

### 4. Ajustar `fstab` para el montaje persistente final

Haz copia de seguridad del fichero:

```bash
sudo cp /etc/fstab /etc/fstab.bak
```

Revisa si ya existen entradas para `hd2t` y `hd5t`:

```bash
grep -nE 'hd2t|hd5t' /etc/fstab
```

Abre el fichero:

```bash
sudo nano /etc/fstab
```

Las entradas finales deben quedar así:

```fstab
LABEL=hd2t  /media/hd2t  ext4  defaults,nofail,noatime,x-systemd.device-timeout=10  0  2
LABEL=hd5t  /media/hd5t  ext4  defaults,nofail,noatime,x-systemd.device-timeout=10  0  2
```

Si en `fstab` todavía aparecen rutas anteriores como `/srv/storage/hd2t` o `/srv/storage/hd5t`, **sustitúyelas** por las rutas nuevas en `/media/...`. No dejes entradas duplicadas para la misma etiqueta.

### 5. Montar y validar los discos en las rutas finales

Aplica el fichero sin reiniciar:

```bash
sudo mount -a
findmnt /media/hd2t
findmnt /media/hd5t
df -h | grep -E '/media/hd2t|/media/hd5t'
```

Si `mount -a` no devuelve errores y ambos discos aparecen montados donde corresponde, la parte de persistencia queda resuelta.

### 6. Crear la estructura base del homelab en el SSD NVMe

La raíz operativa del proyecto vivirá en el home del usuario administrador:

```bash
mkdir -p /home/<user>/homelab/{compose,config,data,logs,scripts}
touch /home/<user>/homelab/.env
```

Estructura recomendada:

```text
/home/<user>/homelab/
├── .env
├── compose/
├── config/
├── data/
│   └── <servicio>/
├── logs/
└── scripts/
```

Criterio de uso:

- `compose/`: archivos `docker-compose.yml` o stacks separados por servicio.
- `config/`: configuraciones editables, plantillas y ficheros auxiliares versionables o respaldables.
- `.env`: variables compartidas del homelab o de stacks concretos.
- `data/`: bind mounts persistentes de cada servicio, incluidas bases de datos y uploads.
- `logs/`: logs locales que interese conservar fuera de los contenedores.
- `scripts/`: utilidades operativas, tareas de backup y mantenimiento.

Si más adelante necesitas más subdirectorios, añádelos sin romper esta idea base: raíz simple en NVMe y datos persistentes por servicio bajo `data/`.

### 7. Crear la estructura de `hd2t`

Prepara el disco de 2 TB para su función mixta de media, descargas y backups:

```bash
sudo mkdir -p /media/hd2t/media/{jellyfin,navidrome,audiobookshelf,calibre-web}
sudo mkdir -p /media/hd2t/downloads
sudo mkdir -p /media/hd2t/backups
```

Ejemplo de lectura operativa:

- `Jellyfin` podrá montar bibliotecas dentro de `/media/hd2t/media/jellyfin/`.
- `Navidrome` usará `/media/hd2t/media/navidrome/`.
- `Audiobookshelf` usará `/media/hd2t/media/audiobookshelf/`.
- `Calibre-Web` trabajará sobre `/media/hd2t/media/calibre-web/`.
- Las descargas temporales o finales vivirán en `/media/hd2t/downloads/`.
- Los backups centralizados del homelab vivirán en `/media/hd2t/backups/`.

Si más adelante necesitas subcarpetas internas como `movies`, `series`, `music`, `incoming` o `exports`, créalas dentro de estos bloques sin cambiar los puntos de anclaje principales.

### 8. Crear la estructura de `hd5t`

El disco de 5 TB queda reservado exclusivamente a Stash:

```bash
sudo mkdir -p /media/hd5t/stash
```

Mantener este disco aislado simplifica permisos, evita mezclar catálogos y hace más predecible el crecimiento de almacenamiento de Stash.

### 9. Ajustar propiedad y permisos base

Asigna como propietario operativo al usuario administrador del host:

```bash
sudo chown -R <user>:<user> /home/<user>/homelab
sudo chown -R <user>:<user> /media/hd2t
sudo chown -R <user>:<user> /media/hd5t
chmod 750 /home/<user>/homelab
```

Si más adelante usas un `PUID` y `PGID` fijos para contenedores, ajusta permisos con ese criterio. Lo importante en esta fase es dejar una base consistente y fácilmente administrable.

### 10. Verificación final de la estructura

Haz una comprobación rápida del resultado:

```bash
find /home/<user>/homelab -maxdepth 2 -type d | sort
find /media/hd2t -maxdepth 3 -type d | sort
find /media/hd5t -maxdepth 2 -type d | sort
findmnt /media/hd2t /media/hd5t
```

Al terminar, deberías poder afirmar todo esto:

- el sistema arranca desde el **NVMe**
- la raíz operativa del homelab vive en **`/home/<user>/homelab`**
- `hd2t` queda montado en **`/media/hd2t`**
- `hd5t` queda montado en **`/media/hd5t`**
- las rutas para media, descargas, backups y datos persistentes ya existen

## Almacenamiento

Resumen de uso por tipo de dato:

- **SSD NVMe**
  - `/home/<user>/homelab/compose/`
  - `/home/<user>/homelab/config/`
  - `/home/<user>/homelab/.env`
  - `/home/<user>/homelab/data/<servicio>/`
  - `/home/<user>/homelab/logs/`
- **`hd2t`**
  - `/media/hd2t/media/`
  - `/media/hd2t/downloads/`
  - `/media/hd2t/backups/`
- **`hd5t`**
  - `/media/hd5t/stash/`

Política importante:

- Los directorios de **configuración**, **estado de aplicación** y **bases de datos** deben estar siempre en el **SSD NVMe**.
- Los directorios de **media**, **descargas** y **backups** pueden vivir en los discos USB.
- Si un servicio mezcla metadatos y contenido, separa ambas capas: metadatos en el **NVMe**, contenido pesado en `hd2t` o `hd5t` según corresponda.

## Backup

Los elementos mínimos que deben formar parte de la estrategia de backup son:

- `/home/<user>/homelab/compose/`
- `/home/<user>/homelab/config/`
- `/home/<user>/homelab/.env`
- `/home/<user>/homelab/data/` de los servicios críticos
- scripts operativos ubicados en `/home/<user>/homelab/scripts/`

Destino recomendado dentro del propio homelab:

- `/media/hd2t/backups/`

Notas prácticas:

- Los backups deben copiar **configuración y estado**, no solo los ficheros `compose`.
- El contenido multimedia de `hd2t` y `hd5t` puede requerir una estrategia distinta por volumen total; no lo confundas con el backup de configuración y bases de datos.
- Antes de automatizar backups en fases posteriores, asegúrate de que las rutas anteriores ya están estabilizadas y en uso real por los servicios.

## Referencias

- [01-instalacion-os.md](01-instalacion-os.md)
- [02-configuracion-inicial.md](02-configuracion-inicial.md)
- [03-preparacion-discos.md](../00-hardware/03-preparacion-discos.md)
- [05-arranque-nvme.md](../00-hardware/05-arranque-nvme.md)
- `fstab(5)`
