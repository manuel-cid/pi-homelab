# Estructura de Directorios del Homelab

## Descripción

Tras `03-seguridad-base.md` la Raspberry Pi 5 está actualizada, endurecida (SSH solo por clave, `ufw` activo, `fail2ban` y `unattended-upgrades`), con `/mnt/hd5t` y `/mnt/hd2t` ya montados desde la Fase 0 y la raíz `/mnt/hd2t/swap/swapfile` ocupada por el swap. Lo que falta para cerrar la Fase 1 es **fijar la estructura de directorios definitiva** sobre la que van a montarse los volúmenes Docker en la Fase 2 y siguientes.

Este documento responde a tres preguntas que aparecen una y otra vez al desplegar servicios y que conviene contestar **una sola vez** y por escrito, en lugar de improvisar en cada `docker-compose.yml`:

1. **¿Dónde vive cada cosa?** Reparto explícito entre la microSD (configuración del homelab y composes), `/mnt/hd2t` (datos persistentes de todos los servicios, descargas y backups) y `/mnt/hd5t` (multimedia de Stash).
2. **¿Con qué nombres?** Una convención común para los subdirectorios de cada servicio: `data/`, `config/`, `cache/`, `logs/`, `db/`. Sin convención, cada documento del servicio inventa la suya y los `docker-compose.yml` se vuelven imposibles de comparar.
3. **¿Con qué permisos y propietario?** Política de UIDs/GIDs entre el usuario `homelab` del host, los UIDs internos de las imágenes Docker (Postgres `999`, MariaDB `999`, Grafana `472`, LinuxServer.io `1000`, Pi-hole `999`…) y los datos que tienen que escribir.

El resultado es un árbol completo, idempotente y reproducible. La fase 0 ya creó la lista mínima de directorios "para no olvidarse"; aquí se cierra esa lista, se documenta la convención y se aplica el `chmod`/`chown` que cada servicio espera.

> **Recordatorio de alcance**: la Pi sigue solo accesible desde la LAN. No hay Docker instalado todavía, no hay servicios desplegados, no hay datos reales. Este documento ejecuta `mkdir`, `chown`, `chmod` y nada más; cualquier servicio que requiera estos directorios los espera ya creados cuando llegue su turno.

---

## Requisitos Previos

- `01-instalacion-os.md`, `02-configuracion-inicial.md` y `03-seguridad-base.md` aplicados: la Pi se administra por SSH con clave, tiene `ufw` activo y `unattended-upgrades` configurado.
- Discos externos montados según `docs/00-hardware/03-preparacion-discos.md`: `/mnt/hd5t` (5 TB) y `/mnt/hd2t` (2 TB) presentes en `/etc/fstab`, con `LABEL=hd5t`/`LABEL=hd2t` y montaje automático en boot.
- Usuario `homelab` con `sudo`, UID/GID `1000`. Comprobación rápida:

  ```bash
  id homelab
  # uid=1000(homelab) gid=1000(homelab) groups=1000(homelab),...
  findmnt /mnt/hd5t /mnt/hd2t
  # ambos en una línea cada uno, type ext4, options con noatime,nofail,...
  df -h /mnt/hd5t /mnt/hd2t
  # espacio libre acorde a 5T y 2T (menos el swap de 8 GiB en hd2t).
  ```

- `acl` y `coreutils` recientes (la Pi OS Lite ya los trae). Solo se confirma:

  ```bash
  command -v setfacl getfacl install rsync || sudo apt install -y acl coreutils rsync
  ```

  `acl` no se va a usar en este documento, pero se deja instalado para que esté disponible si en algún servicio futuro hace falta `setfacl` (por ejemplo, dar acceso a un usuario del host a un directorio propiedad de un UID interno de un contenedor).

---

## Modelo de Almacenamiento

La política de tres "lugares" se decidió en `SERVICES.md` y `docs/00-hardware/03-preparacion-discos.md`. Aquí se aplica de forma exhaustiva, sin excepciones tácitas.

| Soporte | Ruta raíz | Qué guarda | Qué **no** guarda |
|---|---|---|---|
| microSD 64 GB | `/home/homelab/homelab/` | `docker-compose.yml` por stack, ficheros `.env`, `Caddyfile`, `prometheus.yml`, plantillas de configuración. Texto, pequeño, versionado en git. | Datos de usuario, bases de datos, logs voluminosos, multimedia. |
| HDD USB 2 TB (`hd2t`) | `/mnt/hd2t/` | Volúmenes persistentes de **todos** los servicios menos Stash. Bases de datos, configuraciones largas (PiHole, HomeAssistant), descargas, bibliotecas no-Stash (Jellyfin, Navidrome, Audiobookshelf, Calibre-Web), repositorio Borg. | Multimedia del catálogo Stash. |
| HDD USB 5 TB (`hd5t`) | `/mnt/hd5t/` | **Solo** la biblioteca multimedia de Stash. | Cualquier otra cosa: bases de datos, backups, configuraciones, otros servicios. |

Razones para mantener la separación estricta:

- **Aislar I/O de Stash**. Un escaneo de la biblioteca completa de Stash (ficheros muy grandes, lecturas secuenciales largas) puede saturar un HDD USB durante minutos. Si las bases de datos del resto de servicios están en el mismo disco, **toda la Pi se vuelve lenta**. Disco aparte = problemas aparte.
- **Aislar el dominio del backup**. Los backups Borg viven en `/mnt/hd2t/backups/`. La regla 3-2-1 exige que la copia esté en un soporte distinto de los datos primarios. Para todo lo que vive en `hd2t`, el "soporte distinto" será una copia offsite (Fase 7); para Stash, el primario está en `hd5t` y los **metadatos** de Stash (catálogo, miniaturas) viven en `hd2t`, con lo que el backup de hd2t recoge de forma natural el catálogo aunque la biblioteca multimedia de hd5t no se respalde (decisión documentada en `docs/00-hardware/03-preparacion-discos.md` y reafirmada en Fase 7).
- **No tocar la microSD para datos de usuario**. La microSD es el SO. Cualquier escritura intensiva la desgasta y, si falla, se cambia y se reflashea con `docs/01-sistema/01-instalacion-os.md` sin perder datos. Eso solo es cierto si **ningún** dato vive ahí.

> **Regla operativa para Fase 2 en adelante**: ningún `docker-compose.yml` puede montar un volumen de datos persistente en un path bajo `/var/lib/docker/`, `/home/homelab/` (excepto `/home/homelab/homelab/` para el propio compose) o `/`. Si algún servicio insiste, se le escribe explícitamente como excepción en su documento, con justificación.

---

## Usuarios, Grupos y UIDs/GIDs

Los contenedores Docker corren con **un UID interno** que es independiente del host. Cuando el contenedor escribe en un volumen bind-mount (`-v /mnt/hd2t/postgres/data:/var/lib/postgresql/data`), los ficheros aparecen en el host con ese UID interno. Si en el host no existe un usuario con ese UID, el `ls -l` muestra el número en bruto (`991:991`). Esto no es un problema funcional, pero conviene gestionarlo de forma deliberada para tres cosas:

1. **Borgmatic** (Fase 7) hace `borg create` desde el host: necesita poder **leer** todos los volúmenes bajo `/mnt/hd2t/` aunque sean propiedad de UIDs distintos.
2. **Lectura ad-hoc por SSH**: el operador (`homelab`, UID 1000) querrá inspeccionar logs, dumps y configuraciones sin tener que `sudo` cada vez.
3. **Imágenes LinuxServer.io** (Jellyfin, Sonarr, Radarr, Calibre-Web, Audiobookshelf, Stash…) usan internamente los UIDs `911`/`abc` por defecto, pero permiten cambiarlos con las variables `PUID`/`PGID`. Se les forzará a `PUID=1000, PGID=1000` para que escriban como `homelab`.

### Grupo `media` para acceso compartido a multimedia

Dentro de `hd2t/media/` hay bibliotecas que múltiples servicios deben **leer** simultáneamente: Jellyfin, Navidrome, Audiobookshelf, Calibre-Web, los `*arr`, Syncthing si se usa para mover ficheros. La política de "todo es del UID 1000" funciona pero acopla todos los servicios a ese UID. Es más limpio crear un grupo dedicado y dar acceso por GID:

```bash
sudo groupadd --gid 1100 media
sudo usermod -aG media homelab
# Comprobar:
getent group media
# media:x:1100:homelab
```

A partir de ese momento `homelab` pertenece a `media` (efectivo tras la próxima sesión SSH). El GID `1100` se elige fuera del rango por defecto de Debian para usuarios normales (`1000+`) y dentro del rango usable, sin colisionar con UIDs/GIDs típicos de imágenes Docker (`33` www-data, `472` Grafana, `999` postgres/mariadb/redis/pihole, etc.).

Cualquier servicio que necesite acceso a `/mnt/hd2t/media/...` se desplegará con `PGID=1100` (o `group_add: ["1100"]` en compose) en su documento. Aquí solo se establece el grupo y se asigna su ownership a los directorios multimedia.

### UIDs internos relevantes (referencia para Fase 2+)

Tabla de referencia que se reutilizará en cada documento de servicio. **No** se crea ningún usuario del sistema en este punto; los UIDs los aporta el contenedor. La tabla solo documenta a qué número va a chownarse cada subdirectorio.

| Servicio (imagen) | UID:GID interno | Comentario |
|---|---|---|
| LinuxServer.io (Jellyfin, Sonarr, Radarr, Calibre-Web, Audiobookshelf, Stash, Prowlarr, Transmission) | Configurable vía `PUID`/`PGID`. Se forzará a `1000:1000` (homelab) o `1000:1100` (homelab:media). | Forma idiomática del proyecto LSIO. |
| PostgreSQL (`postgres:*`) | `999:999` (`postgres`) | Fijo en la imagen oficial. |
| MariaDB (`mariadb:*`) | `999:999` (`mysql`) | Fijo en la imagen oficial. |
| Redis (`redis:*`) | `999:999` (`redis`) | Fijo en la imagen oficial. |
| Nextcloud (`nextcloud:*`) | `33:33` (`www-data`) | Fijo en la imagen oficial. |
| Grafana (`grafana/grafana`) | `472:472` (`grafana`) | Fijo en la imagen oficial. Famoso porque rompe muchos despliegues si no se chownea. |
| Prometheus (`prom/prometheus`) | `65534:65534` (`nobody:nogroup`) | Fijo en la imagen oficial. |
| Pi-hole (`pihole/pihole`) | `999:999` por defecto, configurable. | Se fijará en su documento. |
| Vaultwarden (`vaultwarden/server`) | `0:0` (root) | Vaultwarden corre como root. Se mitiga con `read_only`, `cap_drop` y `no-new-privileges` en su compose. |
| Paperless-ngx (`paperlessngx/paperless-ngx`) | Configurable `USERMAP_UID`/`USERMAP_GID`. Se forzará a `1000:1000`. | |
| Home Assistant (`homeassistant/home-assistant`) | `0:0` (root) | Necesario para algunos integraciones (USB Zigbee). |
| Caddy (`caddy:*`) | `0:0` (root) | Necesario para escuchar 80/443 si así se decide; se reevaluará en su doc. |
| Mosquitto (`eclipse-mosquitto`) | `1883:1883` (`mosquitto`) | UID propio fijo. |

Esta tabla se cita; **no** se ejecuta nada todavía. Los `chown` específicos por servicio van en cada `docs/0X-.../*.md`. Lo que sí hace este documento es preparar la propiedad de los directorios de **primer nivel** para que el operador `homelab` pueda escribir y, donde aplique, dejar el grupo `media`.

---

## Estructura en la microSD: `/home/homelab/homelab/`

Es el **repositorio operativo** del homelab: todo lo que se versiona en git, todo lo que se restaura primero tras un reflasheo. No contiene datos: solo composes, plantillas y secretos cifrados.

### Layout

```
/home/homelab/homelab/                    ← repositorio git (este árbol)
├── .env                                    Variables globales (TZ, PUID, PGID, dominio interno…)
├── .gitignore                              Excluye .env reales y otros secretos en claro.
├── docker-compose.yml                      Compose raíz (red común, healthchecks…) — opcional según Fase 2
├── docs/                                   Documentación fuente (este árbol). Versionada.
├── plans/                                  Plan maestro y entregables intermedios.
├── stacks/                                 Un subdirectorio por stack/servicio
│   ├── pihole/
│   │   ├── docker-compose.yml
│   │   └── .env
│   ├── caddy/
│   │   ├── docker-compose.yml
│   │   └── Caddyfile
│   ├── nextcloud/
│   │   ├── docker-compose.yml
│   │   └── .env
│   ├── jellyfin/
│   │   └── docker-compose.yml
│   ├── stash/
│   │   ├── docker-compose.yml
│   │   └── .env
│   └── ...                                 (resto de servicios de SERVICES.md)
└── secrets/                                Secretos cifrados (sops/age, opcional). NUNCA en claro en git.
```

> El nombre exacto del subdirectorio (`stacks/`, `apps/`, `services/`) y la decisión de un compose monolítico vs por stack se documentan en `02-docker/02-estructura-compose.md`. Aquí solo se reserva la **ruta raíz** y se establece que **cualquier `docker-compose.yml` vive bajo `/home/homelab/homelab/`** y referencia rutas absolutas a `/mnt/hd2t/...` o `/mnt/hd5t/...` para los volúmenes.

### Crear la jerarquía mínima

```bash
sudo install -d -o homelab -g homelab -m 0750 /home/homelab/homelab
sudo install -d -o homelab -g homelab -m 0750 /home/homelab/homelab/stacks
sudo install -d -o homelab -g homelab -m 0700 /home/homelab/homelab/secrets
```

`install -d` (de `coreutils`) es `mkdir -p` con `chown` y `chmod` atómicos en una sola llamada, lo que evita la ventana de un directorio creado como `root:root` antes del `chown`.

| Directorio | Permisos | Justificación |
|---|---|---|
| `/home/homelab/homelab/` | `0750` `homelab:homelab` | Solo el propietario puede escribir; el grupo (a futuro: `homelab` puro o un eventual operador secundario) lee. `o-rwx` para no exponer composes y `.env` a otras cuentas si en algún momento existiesen. |
| `stacks/` | `0750` `homelab:homelab` | Mismo motivo. |
| `secrets/` | `0700` `homelab:homelab` | Más restrictivo: ni grupo ni otros. Aquí van blobs cifrados y, si por descuido alguno queda en claro, no es legible más allá del propietario. |

### `.gitignore` y `.env`

El esqueleto del repo, que se cerrará en `02-docker/02-estructura-compose.md`, ya puede asumir un `.gitignore` con al menos:

```
# Secretos en claro: nunca al repo
.env
*.env
!.env.example
secrets/*.unenc

# Volúmenes/datos por error
/data/
/var/
/mnt/

# Locales del editor
.vscode/
.idea/
*.swp
```

El operador puede añadir un `.env.example` por stack (sin valores) y mantener `.env` solo en disco. La decisión sobre cifrado de secretos (sops + age) se posterga a `04-seguridad/` o al doc del stack que primero los necesite (Vaultwarden, Authelia).

---

## Estructura en `/mnt/hd2t/`

`hd2t` es el "disco principal de servicios". El árbol se organiza en **cuatro grandes ramas** funcionales:

```
/mnt/hd2t/
├── apps/                       Datos de servicios (configs, bases de datos, caches…)
│   ├── pihole/{etc,dnsmasq.d}
│   ├── unbound/etc
│   ├── caddy/{config,data}
│   ├── portainer/data
│   ├── prometheus/data
│   ├── grafana/data
│   ├── uptime-kuma/data
│   ├── nextcloud/{db,data,redis}
│   ├── vaultwarden/data
│   ├── home-assistant/config
│   ├── mosquitto/{config,data,log}
│   ├── zigbee2mqtt/data
│   ├── node-red/data
│   ├── jellyfin/{config,cache}
│   ├── navidrome/data
│   ├── audiobookshelf/{config,metadata}
│   ├── calibre-web/{config,books}
│   ├── stash/{config,metadata,generated,cache}
│   ├── transmission/config
│   ├── prowlarr/config
│   ├── sonarr/config
│   ├── radarr/config
│   ├── paperless-ngx/{data,media,export,consume,db,redis}
│   ├── bookstack/{db,uploads}
│   ├── linkding/data
│   ├── mealie/data
│   ├── freshrss/data
│   ├── stirling-pdf/data
│   ├── homepage/config
│   ├── authelia/{config,data}
│   ├── minio/data
│   └── samba/config
├── media/                      Bibliotecas multimedia (excepto Stash)
│   ├── movies/
│   ├── tv/
│   ├── music/
│   ├── audiobooks/
│   ├── ebooks/
│   └── photos/
├── downloads/                  Trabajo en curso de Transmission/*arr
│   ├── incomplete/
│   ├── complete/
│   └── watch/
├── swap/                       Ya creado en Fase 1 (02-configuracion-inicial.md)
│   └── swapfile
└── backups/                    Repositorios Borg + dumps temporales
    ├── borg/                     Repos cifrados de Borgmatic
    ├── dumps/                    Dumps SQL pre-backup (postgres, mariadb)
    └── exports/                  Exportaciones manuales (Nextcloud occ, etc.)
```

### Por qué esta forma y no otra

| Decisión | Justificación |
|---|---|
| `apps/` agrupa datos por servicio en lugar de "todo plano" en `/mnt/hd2t/<servicio>` | En el plan original (`SERVICES.md`) se sugirió `/mnt/hd2t/<servicio>/`. Se mantiene el espíritu pero bajo `apps/` para dejar libres los nombres de primer nivel (`media/`, `downloads/`, `backups/`, `swap/`) sin colisiones. Si un servicio futuro se llama `media` o `backups`, no hay ambigüedad. |
| Subdirectorios `config/`, `data/`, `cache/`, `db/` por servicio | Permiten **excluir caches y dumps temporales del backup Borg** sin reglas complicadas. La política de Borgmatic (Fase 7) será incluir `apps/*/data` y `apps/*/db` y excluir `apps/*/cache`. |
| `media/` separado de `apps/` | Las bibliotecas multimedia las leen varios servicios (Jellyfin, Navidrome, Audiobookshelf, Calibre-Web, los `*arr`). Tenerlas en `apps/jellyfin/media` ataba semánticamente la biblioteca a Jellyfin; en `media/` son neutrales y compartibles vía grupo `media`. |
| `downloads/` separado de `media/` | Distintos UIDs (los `*arr` y Transmission con PUID 1000) y distinta política de retención: `downloads/incomplete` y `downloads/watch` se vacían a menudo, `media/` no. Distintas reglas de Borg (excluir `downloads/`). |
| `backups/borg`, `backups/dumps`, `backups/exports` separados | Borg tiene que apuntar a un repo dedicado; mezclar el repo con dumps planos confunde la deduplicación. Los dumps SQL son **input** del backup, no son el backup. Los exports manuales viven aparte para que no se confundan con backups automáticos. |
| `paperless-ngx/{data,media,export,consume,db,redis}` con varios subdirectorios | Es el servicio del catálogo con más volúmenes propios (config, BBDD, OCR, watch folder, exportación). Su layout completo se cierra en `11-productividad/04-paperless-ngx.md`; aquí se reservan las rutas. |
| `nextcloud/{db,data,redis}` con BBDD aparte | El compose de Nextcloud llevará MariaDB y Redis como sidecars; cada uno escribe en su carpeta. Mantenerlos separados permite tomar dump de la BBDD sin tocar `data/`. |

### Crear la estructura de `hd2t`

Se ejecuta **una sola vez**, idempotente (todos los `mkdir -p`/`install -d` son re-ejecutables sin efectos secundarios). Permisos de partida: cada directorio propiedad de `homelab:homelab` con modo `0750`, salvo los multimedia (grupo `media`) y los marcados como sensibles.

Para mantener el documento corto y reutilizable, se centraliza en un **script idempotente** que se guarda en el propio repo:

```bash
sudo install -d -o homelab -g homelab -m 0750 /home/homelab/homelab/scripts
sudo tee /home/homelab/homelab/scripts/00-create-homelab-tree.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
# Crea (idempotente) la estructura de directorios del homelab en hd2t y hd5t.
# Solo crea rutas y aplica owner/perms del primer nivel; los chown finos por
# servicio (postgres 999, grafana 472, etc.) se aplican en cada doc de servicio.

set -euo pipefail

require_mount() {
    findmnt --target "$1" >/dev/null \
        || { echo "ERROR: $1 no está montado" >&2; exit 1; }
}
require_mount /mnt/hd2t
require_mount /mnt/hd5t

mkd() {
    # mkd <ruta> <owner> <group> <mode>
    sudo install -d -o "$2" -g "$3" -m "$4" "$1"
}

# --- Raíces -------------------------------------------------------------
mkd /mnt/hd2t                  root     root    0755
mkd /mnt/hd5t                  root     root    0755

# --- /mnt/hd2t ----------------------------------------------------------
mkd /mnt/hd2t/apps             homelab  homelab 0750
mkd /mnt/hd2t/media            homelab  media   2750   # setgid: hereda grupo media
mkd /mnt/hd2t/media/movies     homelab  media   2770
mkd /mnt/hd2t/media/tv         homelab  media   2770
mkd /mnt/hd2t/media/music      homelab  media   2770
mkd /mnt/hd2t/media/audiobooks homelab  media   2770
mkd /mnt/hd2t/media/ebooks     homelab  media   2770
mkd /mnt/hd2t/media/photos     homelab  media   2770

mkd /mnt/hd2t/downloads            homelab media 2770
mkd /mnt/hd2t/downloads/incomplete homelab media 2770
mkd /mnt/hd2t/downloads/complete   homelab media 2770
mkd /mnt/hd2t/downloads/watch      homelab media 2770

mkd /mnt/hd2t/backups          homelab homelab 0750
mkd /mnt/hd2t/backups/borg     homelab homelab 0700
mkd /mnt/hd2t/backups/dumps    homelab homelab 0700
mkd /mnt/hd2t/backups/exports  homelab homelab 0750

# (swap ya creado por 02-configuracion-inicial.md, no se toca aquí)

# --- /mnt/hd2t/apps por servicio ---------------------------------------
# Estructura mínima: <servicio>/{config,data,...}. Se chowna a homelab:homelab
# y se ajusta finamente en cada documento de servicio.
for s in pihole unbound caddy portainer prometheus grafana uptime-kuma \
         vaultwarden home-assistant mosquitto zigbee2mqtt node-red \
         jellyfin navidrome audiobookshelf calibre-web stash \
         transmission prowlarr sonarr radarr \
         bookstack linkding mealie freshrss stirling-pdf homepage \
         authelia minio samba; do
    mkd "/mnt/hd2t/apps/$s" homelab homelab 0750
done

# Subdirectorios típicos (config + data) para los servicios más comunes:
for s in caddy portainer uptime-kuma vaultwarden mealie freshrss \
         stirling-pdf homepage minio linkding navidrome; do
    mkd "/mnt/hd2t/apps/$s/data" homelab homelab 0750
done

mkd /mnt/hd2t/apps/pihole/etc           homelab homelab 0750
mkd /mnt/hd2t/apps/pihole/dnsmasq.d     homelab homelab 0750
mkd /mnt/hd2t/apps/unbound/etc          homelab homelab 0750
mkd /mnt/hd2t/apps/caddy/config         homelab homelab 0750
mkd /mnt/hd2t/apps/prometheus/data      homelab homelab 0750
mkd /mnt/hd2t/apps/grafana/data         homelab homelab 0750

mkd /mnt/hd2t/apps/nextcloud/db         homelab homelab 0750
mkd /mnt/hd2t/apps/nextcloud/data       homelab homelab 0750
mkd /mnt/hd2t/apps/nextcloud/redis      homelab homelab 0750

mkd /mnt/hd2t/apps/home-assistant/config  homelab homelab 0750
mkd /mnt/hd2t/apps/mosquitto/config       homelab homelab 0750
mkd /mnt/hd2t/apps/mosquitto/data         homelab homelab 0750
mkd /mnt/hd2t/apps/mosquitto/log          homelab homelab 0750
mkd /mnt/hd2t/apps/zigbee2mqtt/data       homelab homelab 0750
mkd /mnt/hd2t/apps/node-red/data          homelab homelab 0750

mkd /mnt/hd2t/apps/jellyfin/config        homelab homelab 0750
mkd /mnt/hd2t/apps/jellyfin/cache         homelab homelab 0750

mkd /mnt/hd2t/apps/audiobookshelf/config    homelab homelab 0750
mkd /mnt/hd2t/apps/audiobookshelf/metadata  homelab homelab 0750
mkd /mnt/hd2t/apps/calibre-web/config       homelab homelab 0750
mkd /mnt/hd2t/apps/calibre-web/books        homelab homelab 0750

mkd /mnt/hd2t/apps/stash/config     homelab homelab 0750
mkd /mnt/hd2t/apps/stash/metadata   homelab homelab 0750
mkd /mnt/hd2t/apps/stash/generated  homelab homelab 0750
mkd /mnt/hd2t/apps/stash/cache      homelab homelab 0750

mkd /mnt/hd2t/apps/transmission/config homelab homelab 0750
mkd /mnt/hd2t/apps/prowlarr/config     homelab homelab 0750
mkd /mnt/hd2t/apps/sonarr/config       homelab homelab 0750
mkd /mnt/hd2t/apps/radarr/config       homelab homelab 0750

mkd /mnt/hd2t/apps/paperless-ngx/data    homelab homelab 0750
mkd /mnt/hd2t/apps/paperless-ngx/media   homelab homelab 0750
mkd /mnt/hd2t/apps/paperless-ngx/export  homelab homelab 0750
mkd /mnt/hd2t/apps/paperless-ngx/consume homelab homelab 0750
mkd /mnt/hd2t/apps/paperless-ngx/db      homelab homelab 0750
mkd /mnt/hd2t/apps/paperless-ngx/redis   homelab homelab 0750

mkd /mnt/hd2t/apps/bookstack/db      homelab homelab 0750
mkd /mnt/hd2t/apps/bookstack/uploads homelab homelab 0750
mkd /mnt/hd2t/apps/authelia/config   homelab homelab 0750
mkd /mnt/hd2t/apps/authelia/data     homelab homelab 0700
mkd /mnt/hd2t/apps/samba/config      homelab homelab 0750

# --- /mnt/hd5t (Stash) --------------------------------------------------
mkd /mnt/hd5t/stash         homelab homelab 0750
mkd /mnt/hd5t/stash/library homelab homelab 0750

echo "Estructura del homelab creada/verificada correctamente."
EOF

sudo chmod +x /home/homelab/homelab/scripts/00-create-homelab-tree.sh
sudo chown homelab:homelab /home/homelab/homelab/scripts/00-create-homelab-tree.sh
```

Ejecutar el script:

```bash
/home/homelab/homelab/scripts/00-create-homelab-tree.sh
```

> **Sobre el bit `setgid` en `media/` (modo `2770` / `2750`)**: el dígito `2` al inicio activa `g+s`. Cualquier fichero o subdirectorio creado dentro hereda el **grupo** del padre (`media`) automáticamente, en vez de coger el grupo primario del proceso que escribe. Es el mecanismo clásico de "directorio compartido por un grupo" y elimina la necesidad de aplicar `chgrp -R media` cada vez que un servicio crea ficheros nuevos. `2770` da rwx al propietario (`homelab`) y al grupo (`media`), nada a `others`.

### Verificación de la estructura

```bash
tree -L 2 -d /mnt/hd2t /mnt/hd5t 2>/dev/null \
    || find /mnt/hd2t /mnt/hd5t -maxdepth 2 -type d | sort

ls -ld /mnt/hd2t /mnt/hd5t \
       /mnt/hd2t/apps /mnt/hd2t/media /mnt/hd2t/downloads \
       /mnt/hd2t/backups /mnt/hd2t/backups/borg \
       /mnt/hd5t/stash
```

`tree` no viene preinstalado en Lite y, salvo que ya esté presente, no se instala solo por esto: el `find` da equivalente.

---

## Estructura en `/mnt/hd5t/`

`hd5t` se reserva exclusivamente a Stash. La política se reafirma: **solo Stash escribe ahí, solo Stash lee desde ahí**.

```
/mnt/hd5t/
└── stash/
    └── library/                Biblioteca multimedia (escenarios, imágenes, galerías)
```

Sutilezas:

- **No** se almacena en `hd5t` el `metadata/`, `generated/` ni `cache/` de Stash. Esos viven en `hd2t/apps/stash/...` y son los que entran al backup. Si Stash perdiera `hd5t` (fallo del HDD de 5 TB), la biblioteca multimedia se considera regenerable desde fuente externa, pero los **metadatos editados a mano por el operador** (tags, performers, scrapers configurados) se conservan en `hd2t` y, por tanto, en Borg.
- Los subdirectorios dentro de `library/` (`scenes/`, `images/`, `galleries/`) los crea Stash al primer arranque siguiendo la configuración del servicio en `09-multimedia/05-stash.md`. No se pre-crean aquí para no mezclar la decisión "ruta del SO" con "configuración del servicio".

Permisos `0750`: lectura solo para `homelab` y su grupo. Stash corre con PUID/PGID `1000`, suficiente.

---

## Tabla resumen de Permisos y Ownership

Referencia rápida del estado **inicial** del árbol tras este documento. Los `chown` finos a UIDs internos de imágenes (postgres 999, grafana 472, www-data 33, mosquitto 1883…) se aplican **en el documento del servicio correspondiente**, no aquí.

| Ruta | Owner:Group | Modo | Comentario |
|---|---|---|---|
| `/home/homelab/homelab/` | `homelab:homelab` | `0750` | Repo operativo. |
| `/home/homelab/homelab/secrets/` | `homelab:homelab` | `0700` | Sólo el operador. |
| `/mnt/hd2t/` | `root:root` | `0755` | Raíz del FS, no se toca. |
| `/mnt/hd2t/apps/` | `homelab:homelab` | `0750` | Cada servicio reasigna su subdir. |
| `/mnt/hd2t/apps/<servicio>/` | `homelab:homelab` | `0750` (por defecto) | Reservado al servicio; se chownea fino en su doc (p. ej. `chown -R 999:999 /mnt/hd2t/apps/postgres/data`). |
| `/mnt/hd2t/apps/authelia/data/` | `homelab:homelab` | `0700` | Contiene secret keys; aún más restrictivo. |
| `/mnt/hd2t/media/` | `homelab:media` | `2750` | Setgid, lectura para el grupo. |
| `/mnt/hd2t/media/<biblioteca>/` | `homelab:media` | `2770` | Escritura del grupo (Sonarr/Radarr/Syncthing/Calibre). |
| `/mnt/hd2t/downloads/` y subdirs | `homelab:media` | `2770` | Igual que media; se gestionan en Fase 10. |
| `/mnt/hd2t/backups/` | `homelab:homelab` | `0750` | |
| `/mnt/hd2t/backups/borg/` | `homelab:homelab` | `0700` | Contiene repositorios cifrados pero la passphrase está en `secrets/`. Igualmente se restringe. |
| `/mnt/hd2t/backups/dumps/` | `homelab:homelab` | `0700` | Dumps SQL en claro durante segundos antes de archivarse. Restringir. |
| `/mnt/hd2t/swap/swapfile` | `root:root` | `0600` | Aplicado en Fase 1, no se toca. |
| `/mnt/hd5t/` | `root:root` | `0755` | Raíz del FS. |
| `/mnt/hd5t/stash/library/` | `homelab:homelab` | `0750` | Stash escribe como UID 1000. |

> **`/mnt/hd2t/apps/vaultwarden/data` y similares de servicios root**: se quedan con `0750 homelab:homelab` ahora; cuando Vaultwarden levante por primera vez, los ficheros internos los creará como `root:root`. Para que Borg pueda leer (Borg corre como root via systemd), no hace falta cambio. Para que el operador los inspeccione sin sudo, se documenta el `sudo cat` correspondiente en su servicio. **No** se aplica `chmod -R o+r` global: es la solución cómoda y la incorrecta.

---

## Decisiones que **no** se toman en este documento

Para evitar que crezca y duplique trabajo de las fases siguientes, queda explícitamente fuera de alcance:

- **`chown` a UIDs internos** (postgres 999, grafana 472, mariadb 999, www-data 33, mosquitto 1883…). Cada uno se aplica en el documento del servicio que lo necesita.
- **Reglas de Borgmatic** sobre qué incluir/excluir de `/mnt/hd2t/`. Se diseñan en `07-backups/02-borgmatic.md` apoyándose en este árbol.
- **ACLs adicionales** (`setfacl`) para casos cruzados (un servicio que necesita leer un directorio de otro). Solo se aplicarán cuando aparezca el caso real, documentadas en el servicio que las pida.
- **Cuotas por servicio** (`quota` ext4). Hoy no hay caso para limitar 5 GB a Paperless: el disco es de 2 TB y la disciplina de qué escribe cada servicio se gestiona por convención. Si en operación apareciese un servicio fugitivo, se reabre el debate en `13-operaciones/`.
- **Cifrado de `/mnt/hd2t`** con LUKS. Se evaluó en `03-seguridad-base.md` (modelo de amenaza) y se descartó: la Pi vive en custodia física, los datos sensibles (claves Vaultwarden, secretos Authelia) van cifrados a nivel aplicación, y el coste de teclear la passphrase tras cada reboot anularía el backup automático.

---

## Verificación Final

Antes de pasar a Fase 2 (`docs/02-docker/01-instalacion-docker.md`):

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Repo operativo creado | `ls -ld /home/homelab/homelab /home/homelab/homelab/{stacks,secrets,scripts}` | Cuatro líneas, propietario `homelab:homelab`, modos `0750`/`0700`. |
| Grupo `media` creado | `getent group media` | `media:x:1100:homelab`. |
| `homelab` en `media` | `id homelab` | Lista de grupos contiene `1100(media)`. |
| Script de árbol presente | `ls -l /home/homelab/homelab/scripts/00-create-homelab-tree.sh` | Ejecutable, propietario `homelab:homelab`. |
| `hd2t/apps/` poblado | `ls /mnt/hd2t/apps \| wc -l` | Coincide con el número de servicios listados en el script (≈ 30). |
| `hd2t/media/` con setgid | `stat -c '%a %U:%G %n' /mnt/hd2t/media /mnt/hd2t/media/movies` | `2750 homelab:media`, `2770 homelab:media`. |
| `hd2t/downloads/` con setgid | `stat -c '%a %U:%G %n' /mnt/hd2t/downloads/{incomplete,complete,watch}` | `2770 homelab:media` en los tres. |
| `hd2t/backups/borg` restringido | `stat -c '%a %U:%G %n' /mnt/hd2t/backups/borg /mnt/hd2t/backups/dumps` | `700 homelab:homelab`. |
| `hd5t/stash/library` listo | `stat -c '%a %U:%G %n' /mnt/hd5t/stash/library` | `750 homelab:homelab`. |
| Sin restos de `lost+found` accesibles | `ls -ld /mnt/hd5t/lost+found /mnt/hd2t/lost+found` | Existen (los crea `mkfs.ext4`), pertenecen a `root:root` con `0700` o `0700`-equivalente. **No tocar**. |
| Espacio libre tras crear el árbol | `df -h /mnt/hd5t /mnt/hd2t /` | Sin cambios apreciables: solo se crean directorios, sin datos. |
| Script idempotente | Re-ejecutar `00-create-homelab-tree.sh` | Sin errores, sin cambios visibles en `ls -lR` salvo timestamps. |
| Reboot sin sorpresas | `sudo reboot` y, tras reentrar, repetir las comprobaciones anteriores | Todo persistente. La estructura vive en los discos USB; nada depende del SO de la microSD. |

El último punto es el que confirma que lo creado es **independiente** del SO: si la microSD muere y se reflashea, basta con reaplicar `01..03` y volver a ejecutar `00-create-homelab-tree.sh` para reconstruir el árbol vacío. Los datos los repondrá Borg en su momento (Fase 7).

---

## Backup

En esta fase no se generan datos de usuario, pero sí dos artefactos que conviene incluir desde ya en el ámbito del repo del homelab y de Borgmatic cuando llegue su momento:

| Ruta | Qué guarda | Estrategia |
|---|---|---|
| `/home/homelab/homelab/scripts/00-create-homelab-tree.sh` | Script de creación idempotente del árbol | Versionado en git (este árbol). Reproduce la estructura tras un reflasheo de la microSD. |
| `/etc/group` (línea `media:x:1100:homelab`) | Grupo `media` y pertenencia | Borg en Fase 7; reproducible con `groupadd --gid 1100 media && usermod -aG media homelab`. |
| Documentación de la tabla de UIDs/GIDs | Referencia para los `chown` por servicio | Este propio documento es la fuente de verdad. |

Sobre los datos en sí, válido como recordatorio para Fase 7:

- **`/mnt/hd2t/apps/`**: entra **completo** al backup, con exclusiones explícitas de `apps/*/cache/` y `apps/*/redis/dump.rdb` (regenerable).
- **`/mnt/hd2t/media/`** y **`/mnt/hd2t/downloads/`**: **se excluyen** del backup. La biblioteca multimedia es voluminosa y reconstituible desde la fuente externa; las descargas son efímeras.
- **`/mnt/hd2t/backups/`**: **no se respalda a sí mismo**. Borg trata su propio repo aparte.
- **`/mnt/hd2t/swap/swapfile`**: excluido.
- **`/mnt/hd5t/`**: excluido en el plan; opcionalmente, se puede ofrecer un repo Borg secundario en almacenamiento externo solo para Stash, decisión documentada en `07-backups/01-estrategia-backup.md`.

---

## Referencias

- [Documento anterior: `03-seguridad-base.md`](./03-seguridad-base.md)
- [Documento siguiente: `docs/02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md)
- [`docs/00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md) — Montaje y formato de los discos externos.
- [`SERVICES.md`](../../SERVICES.md) — Catálogo de servicios y política de almacenamiento.
- [`install(1)` — manpage Debian](https://manpages.debian.org/bookworm/coreutils/install.1.en.html)
- [`chmod(1)` — bits especiales (setgid, setuid, sticky)](https://manpages.debian.org/bookworm/coreutils/chmod.1.en.html)
- [Linux Foundation FHS — Filesystem Hierarchy Standard](https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html)
- [LinuxServer.io — variables `PUID`/`PGID`](https://docs.linuxserver.io/general/understanding-puid-and-pgid)
- [Docker — Bind mounts y permisos](https://docs.docker.com/storage/bind-mounts/)
