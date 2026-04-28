# Estructura de Directorios

## Descripción

Definición de la **estructura de carpetas** sobre los dos discos externos (`hd5t` montado en `/mnt/hd5t` y `hd2t` montado en `/mnt/hd2t`). Esta es la última pieza que falta antes de empezar a desplegar Docker en la [Fase 2](../02-docker/01-instalacion-docker.md): cuando los contenedores hagan `bind mount` a `/mnt/hd2t/services/<servicio>/...` ya tendrán los directorios creados, con el dueño correcto y los permisos adecuados.

Este documento cubre, en este orden:

1. **Convenciones globales** del homelab: paths, ownership, modos de permisos, estrategia de UID/GID.
2. **Grupo `media`** compartido entre servicios que leen/escriben las bibliotecas multimedia.
3. **Estructura de `/mnt/hd5t`** (multimedia exclusiva de Stash).
4. **Estructura de `/mnt/hd2t`** (volúmenes de servicios, bibliotecas multimedia "de servicios", descargas, backups y swap ya creada en [`02-configuracion-inicial.md`](./02-configuracion-inicial.md#7-crear-swapfile-en-hd2t)).
5. **Aplicación** de la estructura: comandos `mkdir`, `chown`, `chmod` idempotentes.
6. **Verificación** y resolución de incidencias típicas.

> **Alcance**: aquí solo se crean **carpetas vacías** con la propiedad y permisos correctos. Cada documento de servicio decidirá qué subcarpetas finas necesita (`config/`, `data/`, `db/`, `cache/`...) dentro de su directorio raíz `/mnt/hd2t/services/<servicio>/`. La política aquí es **uniforme y predecible**, no exhaustiva.

> **Recordatorio**: el homelab opera en **LAN + Tailscale**. Ningún directorio se exporta por red en este documento; las exportaciones (Samba, Nextcloud, Jellyfin) se configuran en sus propias fases con permisos específicos.

---

## Requisitos Previos

- Discos `hd5t` y `hd2t` particionados, formateados (`ext4`) y montados en `/mnt/hd5t` y `/mnt/hd2t` según [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md).
- Sistema actualizado y con swap en `/mnt/hd2t/swap/swapfile` según [`02-configuracion-inicial.md`](./02-configuracion-inicial.md).
- Endurecimiento de seguridad del host completado según [`03-seguridad-base.md`](./03-seguridad-base.md).
- Usuario `homelab` con `UID=1000` y grupo primario `homelab` con `GID=1000` (estado por defecto tras la instalación con Raspberry Pi Imager).
- `findmnt /mnt/hd5t` y `findmnt /mnt/hd2t` reportan ambos discos montados como `ext4` con `noatime,nofail`.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Raíz de datos de servicios | `/mnt/hd2t/services/<servicio>/` | Una carpeta raíz por servicio, en `hd2t` (HDD respaldado). Dentro, el servicio decide su sub-estructura (`config/`, `data/`, `db/`...). |
| Bibliotecas multimedia "de servicios" (Jellyfin, Navidrome, Audiobookshelf, Calibre-Web) | `/mnt/hd2t/media/{movies,tv,music,audiobooks,podcasts,books}/` | Compartidas entre los servicios "arr" (Sonarr/Radarr) y los reproductores. Viven en `hd2t` porque son críticas y entran en backup. |
| Biblioteca de Stash | `/mnt/hd5t/stash/library/` (+ `metadata/`, `previews/`) | **Disco dedicado**: el contenido de Stash es voluminoso y de lectura secuencial. Se aísla en `hd5t` para que no compita con el resto del homelab por I/O ni por espacio (decisión heredada de [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md#6-estrategia-de-uso-de-cada-disco)). |
| Descargas (Transmission) | `/mnt/hd2t/downloads/{incomplete,complete}/` | Separadas de `media/` porque tienen flujo distinto: descargan, se procesan y se mueven (lo hacen Sonarr/Radarr en su Fase 10). |
| Backups locales | `/mnt/hd2t/backups/{borg,dumps,configs,system}/` | Destino **local** de la estrategia 3-2-1; el destino offsite (nube) se documenta en [`../07-backups/`](../07-backups/). |
| UID/PGID de los contenedores | `PUID=1000`, `PGID=1000` (`homelab:homelab`) | Convención de las imágenes de [LinuxServer.io](https://docs.linuxserver.io/general/understanding-puid-and-pgid/) y de la mayoría de imágenes oficiales. Mantener un único par UID/PGID simplifica permisos y backups. Las pocas imágenes que requieren UID propio (PostgreSQL, Mosquitto, MariaDB...) se documentan **en el doc del servicio**. |
| Grupo compartido para multimedia | `media` con `GID=1100` | Permite que servicios que escriben (Sonarr/Radarr/Transmission) y servicios que solo leen (Jellyfin/Navidrome/Audiobookshelf/Calibre-Web) compartan acceso sin ampliar permisos a "world". |
| Bit `setgid` en `media/` y `downloads/` | **Activado** (`chmod 2775`) | Cualquier fichero o carpeta nueva hereda automáticamente el grupo `media`. Sin `setgid`, los descargados por Transmission saldrían con grupo `homelab` y Sonarr/Radarr no podrían moverlos sin un `chgrp` posterior. |
| Permisos de `services/` | `750 homelab:homelab` | Solo el operador (`homelab`) y procesos que corran como `homelab` ven el contenido. Se evita filtrar configs por accidente a otras cuentas locales. |
| Permisos de `backups/` | `700 root:root` | Los backups contienen dumps de BD con datos sensibles. Solo `root` los lee/escribe; los hooks pre/post-backup de Borgmatic corren como `root` (Fase 7). |
| Permisos del root del disco (`/mnt/hd5t`, `/mnt/hd2t`) | `755 root:root` | El punto de montaje pertenece al sistema, no al operador. La granularidad real está en las subcarpetas. |
| Idempotencia | Todos los comandos de este doc se pueden re-ejecutar sin romper el estado | Importante para reconstrucciones y para `disaster recovery` ([`../13-operaciones/02-disaster-recovery.md`](../13-operaciones/02-disaster-recovery.md)). |

---

## 1. Convenciones globales

### 1.1. Layout general

```
/mnt/hd5t/                    # disco multimedia Stash (5 TB, lectura secuencial)
└── stash/
    ├── library/              # biblioteca multimedia gestionada por Stash
    ├── metadata/             # metadatos generados por Stash (sqlite, hashes)
    ├── previews/             # previews/sprites generados (cache pesada)
    └── generated/            # otros contenidos derivados (transcodes, screenshots)

/mnt/hd2t/                    # disco de servicios y backups (2 TB)
├── swap/                     # ya creado en 02-configuracion-inicial.md
│   └── swapfile
├── services/                 # datos persistentes de servicios Docker
│   └── <servicio>/           # un subdirectorio por servicio (ver lista en §4.1)
├── media/                    # bibliotecas multimedia compartidas
│   ├── movies/
│   ├── tv/
│   ├── music/
│   ├── audiobooks/
│   ├── podcasts/
│   └── books/
├── downloads/                # carpeta compartida con Transmission/Sonarr/Radarr
│   ├── incomplete/
│   ├── complete/
│   └── watch/                # carpeta de auto-add (.torrent / .magnet)
└── backups/                  # destino local de la estrategia 3-2-1
    ├── borg/                 # repositorio Borg (Borgmatic)
    ├── dumps/                # dumps de BD generados por hooks pre-backup
    │   ├── postgresql/
    │   └── mariadb/
    ├── configs/              # snapshots de docker-compose, .env, Caddyfile, etc.
    └── system/               # /etc, listados apt, métricas de host
```

### 1.2. UID, GID y grupos

| Nombre | Tipo | ID | Uso |
|---|---|---|---|
| `homelab` | usuario | `UID=1000` | Operador del homelab; PUID por defecto en contenedores. |
| `homelab` | grupo | `GID=1000` | Grupo primario del operador; PGID por defecto en contenedores. |
| `media` | grupo | `GID=1100` | Grupo compartido entre servicios multimedia. Miembros: `homelab` (más adelante: cualquier servicio que necesite leer/escribir media). |

> El **GID `1100`** se elige a propósito **fuera** del rango "system" (`<1000`) y por encima del usuario `homelab` (`1000`). Si en el futuro se añaden más usuarios o grupos, queda hueco entre `1001-1099` para cuentas humanas y a partir de `1100` para grupos funcionales del homelab.

### 1.3. Modos de permisos por sección

| Path | Owner:Group | Modo | Notas |
|---|---|---|---|
| `/mnt/hd5t` | `root:root` | `755` | Punto de montaje. |
| `/mnt/hd5t/stash/` | `homelab:media` | `2775` | `setgid` para herencia del grupo `media`. |
| `/mnt/hd5t/stash/{library,metadata,previews,generated}/` | `homelab:media` | `2775` | Idem; cualquier fichero nuevo hereda `media`. |
| `/mnt/hd2t` | `root:root` | `755` | Punto de montaje. |
| `/mnt/hd2t/swap/` | `root:root` | `700` | Ya configurado en [`02-configuracion-inicial.md`](./02-configuracion-inicial.md#71-reservar-un-directorio-dedicado). |
| `/mnt/hd2t/services/` | `homelab:homelab` | `750` | Configuración de servicios; sin acceso "world". |
| `/mnt/hd2t/services/<servicio>/` | `homelab:homelab` | `750` | El doc de cada servicio indica si necesita un UID propio (p.ej. PostgreSQL = `999`). |
| `/mnt/hd2t/media/` | `homelab:media` | `2775` | `setgid` para herencia del grupo `media`. |
| `/mnt/hd2t/media/{movies,tv,music,audiobooks,podcasts,books}/` | `homelab:media` | `2775` | Idem. |
| `/mnt/hd2t/downloads/` | `homelab:media` | `2775` | `setgid` para que los .arr puedan mover ficheros sin permisos extra. |
| `/mnt/hd2t/downloads/{incomplete,complete,watch}/` | `homelab:media` | `2775` | Idem. |
| `/mnt/hd2t/backups/` | `root:root` | `700` | Solo `root`; contiene dumps con datos sensibles. |
| `/mnt/hd2t/backups/{borg,dumps,dumps/postgresql,dumps/mariadb,configs,system}/` | `root:root` | `700` | Idem. |

> **`setgid` (`2xxx`) en `media/` y `downloads/`**: hace que cualquier carpeta o fichero **nuevo** que se cree dentro herede automáticamente el grupo del directorio padre (`media`). Sin esto, Transmission descarga con grupo `homelab` y Sonarr/Radarr fallarían al mover los ficheros si corren como otro usuario.

---

## 2. Crear el grupo `media`

Se crea con un GID fijo (`1100`) para que sea estable entre reinstalaciones y entre contenedores. Si la imagen Docker espera el mismo GID dentro del contenedor, se le pasa con `PGID=1100` (los servicios de la Fase 9 y 10 lo harán explícitamente).

```bash
sudo groupadd -g 1100 media || sudo groupmod -g 1100 media
sudo usermod -aG media homelab
```

- `groupadd -g 1100 media` falla si ya existe; el `||` con `groupmod -g 1100 media` arregla el GID si el grupo ya estaba creado con otro número (caso típico tras un `apt install` previo que crease un grupo `media` con GID arbitrario).
- `usermod -aG media homelab` añade `homelab` al grupo `media` **sin sacarlo** de los grupos a los que ya pertenece (`-a` = append). Sin esto, `homelab` no podría leer/escribir en `media/` ni en `downloads/` desde el shell.

### 2.1. Verificar pertenencia

```bash
getent group media
id homelab
```

Salida esperada:

```
media:x:1100:homelab
uid=1000(homelab) gid=1000(homelab) groups=1000(homelab),1100(media),...
```

> **Importante**: si el shell SSH **estaba abierto antes** de añadir `homelab` al grupo `media`, los grupos efectivos **no** se actualizan en esa sesión. Cerrar y volver a abrir la sesión SSH (o ejecutar los comandos de creación de directorios siguientes precedidos de `sudo`, que es lo que hacen los snippets de este documento).

---

## 3. Estructura en `/mnt/hd5t` (Stash)

`hd5t` aloja **exclusivamente** la biblioteca multimedia gestionada por Stash. La sub-estructura sigue las recomendaciones del propio Stash: un directorio raíz para la **biblioteca** (los ficheros de vídeo) y carpetas separadas para los **datos generados** (metadatos, previews, transcodes), de forma que la biblioteca se pueda hacer read-only y los datos generados se puedan vaciar sin tocarla.

### 3.1. Crear los directorios

```bash
sudo install -d -o homelab -g media -m 2775 /mnt/hd5t/stash
sudo install -d -o homelab -g media -m 2775 /mnt/hd5t/stash/library
sudo install -d -o homelab -g media -m 2775 /mnt/hd5t/stash/metadata
sudo install -d -o homelab -g media -m 2775 /mnt/hd5t/stash/previews
sudo install -d -o homelab -g media -m 2775 /mnt/hd5t/stash/generated
```

`install -d` crea el directorio si no existe y aplica owner, group y modo en una sola llamada **idempotente** (re-ejecutar no rompe nada y reaplica lo prescrito).

### 3.2. Verificar

```bash
ls -ld /mnt/hd5t /mnt/hd5t/stash /mnt/hd5t/stash/*
```

Salida esperada (modo `drwxrwsr-x`, la `s` indica `setgid`):

```
drwxr-xr-x 3 root    root     ... /mnt/hd5t
drwxrwsr-x 6 homelab media    ... /mnt/hd5t/stash
drwxrwsr-x 2 homelab media    ... /mnt/hd5t/stash/library
drwxrwsr-x 2 homelab media    ... /mnt/hd5t/stash/metadata
drwxrwsr-x 2 homelab media    ... /mnt/hd5t/stash/previews
drwxrwsr-x 2 homelab media    ... /mnt/hd5t/stash/generated
```

> El detalle fino de qué contiene cada subcarpeta (qué bibliotecas configura Stash, scrapers, etc.) se cubre en [`../09-multimedia/05-stash.md`](../09-multimedia/05-stash.md). Aquí solo se prepara el "contenedor" de carpetas con permisos correctos.

---

## 4. Estructura en `/mnt/hd2t`

### 4.1. `services/` — un directorio por servicio Docker

Cada servicio del homelab tiene **un único directorio raíz** en `/mnt/hd2t/services/<servicio>/`. Dentro, el doc del servicio decidirá su sub-estructura (típicamente `config/`, `data/`, `db/`, `cache/`).

Lista de directorios a crear ahora, derivada de los servicios definidos en `SERVICES.md` y el plan ([`../../plans/PLAN.md`](../../plans/PLAN.md)):

```bash
# Carpeta raíz de servicios.
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services

# Fase 2 — Docker y orquestación.
for svc in portainer watchtower; do
  sudo install -d -o homelab -g homelab -m 750 "/mnt/hd2t/services/${svc}"
done

# Fase 3 — Red y DNS.
for svc in pihole unbound caddy tailscale; do
  sudo install -d -o homelab -g homelab -m 750 "/mnt/hd2t/services/${svc}"
done

# Fase 4 — Seguridad.
for svc in authelia fail2ban; do
  sudo install -d -o homelab -g homelab -m 750 "/mnt/hd2t/services/${svc}"
done

# Fase 5 — Monitorización.
for svc in prometheus grafana node-exporter cadvisor uptime-kuma dozzle; do
  sudo install -d -o homelab -g homelab -m 750 "/mnt/hd2t/services/${svc}"
done

# Fase 6 — Almacenamiento.
for svc in nextcloud samba syncthing minio; do
  sudo install -d -o homelab -g homelab -m 750 "/mnt/hd2t/services/${svc}"
done

# Fase 7 — Backups (Borgmatic guarda su config aquí; el repo Borg vive en /mnt/hd2t/backups/borg).
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/borgmatic

# Fase 8 — Domótica.
for svc in home-assistant mosquitto zigbee2mqtt node-red; do
  sudo install -d -o homelab -g homelab -m 750 "/mnt/hd2t/services/${svc}"
done

# Fase 9 — Multimedia (solo config; las bibliotecas viven en /mnt/hd2t/media o /mnt/hd5t).
for svc in jellyfin navidrome audiobookshelf calibre-web stash; do
  sudo install -d -o homelab -g homelab -m 750 "/mnt/hd2t/services/${svc}"
done

# Fase 10 — Descargas.
for svc in transmission prowlarr sonarr radarr; do
  sudo install -d -o homelab -g homelab -m 750 "/mnt/hd2t/services/${svc}"
done

# Fase 11 — Productividad.
for svc in vaultwarden bookstack linkding paperless-ngx mealie stirling-pdf freshrss; do
  sudo install -d -o homelab -g homelab -m 750 "/mnt/hd2t/services/${svc}"
done

# Fase 12 — Dashboards.
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/homepage
```

> **Servicios con UID propio**: algunos contenedores (PostgreSQL `999:999`, MariaDB `999:999`, Mosquitto `1883:1883`, etc.) escriben con UID **distinto** de `homelab`. En esos casos, el doc del servicio aplicará un `chown` específico **sobre la subcarpeta** correspondiente (p.ej. `/mnt/hd2t/services/nextcloud/db/` para MariaDB), pero la **raíz** `/mnt/hd2t/services/<servicio>/` sigue siendo `homelab:homelab` para que el operador siga gestionando configs y backups. Esa decisión se documenta caso a caso, no se anticipa aquí.

### 4.2. `media/` — bibliotecas multimedia compartidas

```bash
sudo install -d -o homelab -g media -m 2775 /mnt/hd2t/media
for sub in movies tv music audiobooks podcasts books; do
  sudo install -d -o homelab -g media -m 2775 "/mnt/hd2t/media/${sub}"
done
```

Estas seis carpetas son las "fuentes de la verdad" de cada biblioteca:

| Carpeta | Servicio principal de lectura | Servicio principal de escritura |
|---|---|---|
| `movies/` | Jellyfin | Radarr |
| `tv/` | Jellyfin | Sonarr |
| `music/` | Navidrome, Jellyfin | Sincronización manual (`rsync`/Syncthing) o `*arr` futuros |
| `audiobooks/` | Audiobookshelf | Sincronización manual / Audiobookshelf |
| `podcasts/` | Audiobookshelf | Audiobookshelf (descarga RSS) |
| `books/` | Calibre-Web | Calibre-Web / sincronización manual |

### 4.3. `downloads/` — carpeta compartida con clientes BT

```bash
sudo install -d -o homelab -g media -m 2775 /mnt/hd2t/downloads
for sub in incomplete complete watch; do
  sudo install -d -o homelab -g media -m 2775 "/mnt/hd2t/downloads/${sub}"
done
```

- `incomplete/` → Transmission descarga aquí.
- `complete/` → Transmission mueve aquí al terminar.
- `watch/` → carpeta vigilada para añadir `.torrent`/`.magnet` automáticamente.

Sonarr/Radarr (Fase 10) leerán de `complete/` y moverán/copiarán a `media/movies/` o `media/tv/`. Como ambas árboles viven en el **mismo filesystem** (`hd2t`), el move es atómico (rename) en lugar de copiar y borrar.

### 4.4. `backups/` — destino local de la estrategia 3-2-1

```bash
sudo install -d -o root -g root -m 700 /mnt/hd2t/backups
sudo install -d -o root -g root -m 700 /mnt/hd2t/backups/borg
sudo install -d -o root -g root -m 700 /mnt/hd2t/backups/dumps
sudo install -d -o root -g root -m 700 /mnt/hd2t/backups/dumps/postgresql
sudo install -d -o root -g root -m 700 /mnt/hd2t/backups/dumps/mariadb
sudo install -d -o root -g root -m 700 /mnt/hd2t/backups/configs
sudo install -d -o root -g root -m 700 /mnt/hd2t/backups/system
```

Decisiones:

- **Owner `root:root` y modo `700`**: los hooks pre/post-backup de Borgmatic (Fase 7) corren como `root`, y los dumps de BD pueden contener datos personales (Vaultwarden, Nextcloud, Bookstack...). Se evita exponerlos al usuario `homelab`, que en otra sesión podría tener un script malicioso de un proyecto sin relación.
- **Subcarpeta `borg/`**: repositorio Borg gestionado por Borgmatic. Ver [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md).
- **Subcarpeta `dumps/`**: dumps `pg_dump`/`mariadb-dump` generados como hooks `before_backup` antes de que Borgmatic snapshotee el contenido.
- **Subcarpeta `configs/`**: snapshots de `docker-compose.yml`, `.env`, `Caddyfile`, etc. (idealmente versionados en git pero respaldados también aquí).
- **Subcarpeta `system/`**: listados de paquetes (`dpkg -l`), `/etc/fstab`, `crontab -l`, etc. — todo lo que no está en git pero hace falta en una recuperación.

---

## 5. Aplicar la estructura completa

Si se quiere **re-aplicar** todo de golpe (por ejemplo, tras una reinstalación o como parte de un script de bootstrap), encadenar los snippets anteriores. Como todo usa `install -d`, el resultado es idempotente:

```bash
# 0. Crear el grupo media si no existe; añadir homelab.
sudo groupadd -g 1100 media 2>/dev/null || sudo groupmod -g 1100 media
sudo usermod -aG media homelab

# 1. Estructura en hd5t (Stash).
sudo install -d -o homelab -g media -m 2775 /mnt/hd5t/stash
for sub in library metadata previews generated; do
  sudo install -d -o homelab -g media -m 2775 "/mnt/hd5t/stash/${sub}"
done

# 2. Estructura en hd2t — services/.
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services
for svc in \
  portainer watchtower \
  pihole unbound caddy tailscale \
  authelia fail2ban \
  prometheus grafana node-exporter cadvisor uptime-kuma dozzle \
  nextcloud samba syncthing minio \
  borgmatic \
  home-assistant mosquitto zigbee2mqtt node-red \
  jellyfin navidrome audiobookshelf calibre-web stash \
  transmission prowlarr sonarr radarr \
  vaultwarden bookstack linkding paperless-ngx mealie stirling-pdf freshrss \
  homepage; do
  sudo install -d -o homelab -g homelab -m 750 "/mnt/hd2t/services/${svc}"
done

# 3. Estructura en hd2t — media/ y downloads/ (con grupo media y setgid).
sudo install -d -o homelab -g media -m 2775 /mnt/hd2t/media
for sub in movies tv music audiobooks podcasts books; do
  sudo install -d -o homelab -g media -m 2775 "/mnt/hd2t/media/${sub}"
done
sudo install -d -o homelab -g media -m 2775 /mnt/hd2t/downloads
for sub in incomplete complete watch; do
  sudo install -d -o homelab -g media -m 2775 "/mnt/hd2t/downloads/${sub}"
done

# 4. Estructura en hd2t — backups/ (root-only).
sudo install -d -o root -g root -m 700 /mnt/hd2t/backups
for sub in borg dumps dumps/postgresql dumps/mariadb configs system; do
  sudo install -d -o root -g root -m 700 "/mnt/hd2t/backups/${sub}"
done
```

> **Tras este bloque**, los discos están listos para que la Fase 2 ([`../02-docker/`](../02-docker/)) instale Docker y empiece a montar volúmenes con confianza de que las rutas existen y los permisos son los correctos.

---

## 6. Lista de Verificación

Antes de pasar a [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md):

- [ ] `getent group media` devuelve `media:x:1100:homelab` (GID `1100` y `homelab` como miembro).
- [ ] `id homelab` lista `1100(media)` en `groups=`.
- [ ] `ls -ld /mnt/hd5t /mnt/hd2t` muestra `drwxr-xr-x ... root root` para ambos puntos de montaje.
- [ ] `ls -ld /mnt/hd5t/stash` muestra `drwxrwsr-x ... homelab media` (la `s` confirma `setgid`).
- [ ] `ls /mnt/hd5t/stash` lista `library`, `metadata`, `previews`, `generated`, todos `homelab:media` con modo `2775`.
- [ ] `ls -ld /mnt/hd2t/services` muestra `drwxr-x--- ... homelab homelab` (modo `750`).
- [ ] `ls /mnt/hd2t/services | wc -l` devuelve **40** (número de servicios listados en §4.1; ajustar si se añade/quita alguno del plan).
- [ ] `ls -ld /mnt/hd2t/media /mnt/hd2t/downloads` muestra `drwxrwsr-x ... homelab media` para ambos.
- [ ] `ls /mnt/hd2t/media` lista las 6 subcarpetas (`movies`, `tv`, `music`, `audiobooks`, `podcasts`, `books`).
- [ ] `ls /mnt/hd2t/downloads` lista `incomplete`, `complete`, `watch`.
- [ ] `sudo ls -ld /mnt/hd2t/backups /mnt/hd2t/backups/borg /mnt/hd2t/backups/dumps /mnt/hd2t/backups/configs /mnt/hd2t/backups/system` muestra `drwx------ ... root root` para todos.
- [ ] **Smoke test de `setgid`**: `sudo -u homelab touch /mnt/hd2t/media/movies/.test && ls -l /mnt/hd2t/media/movies/.test` devuelve un fichero con grupo `media`. Borrar tras la prueba: `rm /mnt/hd2t/media/movies/.test`.
- [ ] **Smoke test de aislamiento**: como otro usuario no-`homelab` (si existiera) o sin pertenecer a `homelab`, `cat /mnt/hd2t/services/.../config` debe fallar con `Permission denied`.
- [ ] La swap creada en el paso anterior sigue en `/mnt/hd2t/swap/swapfile` y `swapon --show` la lista (ningún paso de este doc la ha tocado).

---

## 7. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `groupadd: GID '1100' already in use` | Otro grupo ocupa el GID `1100`. | `getent group 1100` para identificarlo. Renombrarlo o elegir otro GID coherente para `media` y actualizar este doc. |
| `usermod -aG media homelab` ejecutado, pero `groups` en la sesión actual no lista `media` | Los grupos efectivos solo se actualizan en sesiones nuevas. | Cerrar y reabrir la sesión SSH; o usar `sg media -c '<comando>'` para una invocación puntual. |
| Tras descargar con Transmission, los ficheros aparecen con grupo `homelab` en vez de `media` | Falta el bit `setgid` en la carpeta o se creó el fichero antes de aplicar `chmod 2775`. | `sudo chmod 2775 /mnt/hd2t/downloads/{,incomplete,complete,watch}` y, para los ficheros ya existentes, `sudo chgrp -R media /mnt/hd2t/downloads`. |
| Sonarr/Radarr fallan al mover de `downloads/complete/` a `media/...` con `Permission denied` | Sonarr/Radarr corren como un PUID/PGID que no es miembro de `media`, o la subcarpeta de destino tiene permisos restrictivos. | Verificar `PUID=1000` y `PGID=1100` en el compose del servicio; comprobar `id` dentro del contenedor con `docker exec`. |
| `mkdir -p /mnt/hd2t/services/<x>` falla con `Read-only file system` | El disco se ha remontado en RO por errores I/O o porque `fstab` lo declara así. | `dmesg | tail`, revisar SMART ([`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md#7-monitorización-smart-continua)) y `findmnt -o SOURCE,TARGET,OPTIONS /mnt/hd2t`. |
| `ls -l /mnt/hd2t/backups` devuelve `Permission denied` para el usuario `homelab` | Comportamiento esperado: `backups/` es `700 root:root`. | Usar `sudo ls /mnt/hd2t/backups`. |
| Tras un reboot, todas las carpetas de `services/` aparecen vacías | Probablemente `hd2t` no está montado y se está escribiendo sobre el punto de montaje vacío. | `findmnt /mnt/hd2t`. Si no aparece, revisar `fstab` y `dmesg`. La opción `nofail` permite que el sistema arranque pero no monta el disco; investigar antes de seguir creando datos. |
| Stash muestra ruta `/data` o similar dentro del contenedor pero no encuentra ficheros | Confusión entre la ruta dentro del contenedor y la ruta del host. | El doc de Stash define el bind mount `/mnt/hd5t/stash/library:/data:ro` (o equivalente). Aquí solo se prepara la ruta del host. |
| `install: cannot change owner ...: Operation not permitted` | El comando se ejecutó sin `sudo`. | Reejecutar con `sudo`. |

---

## Referencias

- [`install(1)` — manual page](https://man7.org/linux/man-pages/man1/install.1.html)
- [`chmod(1)` y bit `setgid`](https://man7.org/linux/man-pages/man1/chmod.1.html)
- [Linux Permissions — `setuid`, `setgid`, sticky bit (Debian Wiki)](https://wiki.debian.org/Permissions)
- [`groupadd(8)`, `groupmod(8)`, `usermod(8)`](https://manpages.debian.org/bookworm/passwd/usermod.8.en.html)
- [LinuxServer.io — Understanding `PUID` and `PGID`](https://docs.linuxserver.io/general/understanding-puid-and-pgid/)
- [Filesystem Hierarchy Standard (FHS) — `/mnt`](https://refspecs.linuxfoundation.org/FHS_3.0/fhs/ch03s11.html)
- [Stash — Documentación de configuración de bibliotecas](https://docs.stashapp.cc/in-app-manual/configuration/library/)
