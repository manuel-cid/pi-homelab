# Estructura de Directorios

## Descripción

Diseño y creación de la **estructura interna** de los dos discos externos del homelab antes de instalar Docker o cualquier servicio. Define dónde vive cada cosa (volúmenes de servicios, backups, swap, multimedia de Stash), qué directorios crea ya el provisionado base y qué directorios crearán los contenedores en su propio arranque, y fija las **convenciones de ownership y permisos** que el resto de docs darán por hechas.

Tras esta fase, los discos están listos para que las fases posteriores (`docs/02-docker/`, `docs/03-red/`, …) se limiten a referenciar rutas absolutas conocidas (`/mnt/hd2t/services/<servicio>/…`, `/mnt/hd2t/backups/borg/`, `/mnt/hd5t/stash/data/`) sin tener que decidir caso a caso dónde colocar los datos.

> **Alcance**: este documento crea **directorios vacíos**, fija propietarios y permisos, y deja una convención escrita. **No** despliega servicios, **no** instala Docker, **no** monta discos (eso ya está hecho en `docs/00-hardware/03-preparacion-discos.md`) y **no** configura backups (Borgmatic se trata en `docs/07-backups/02-borgmatic.md`, pero usará la rama `/mnt/hd2t/backups/` que se prepara aquí).

> **Recordatorio del reparto de discos** (definido en `docs/00-hardware/03-preparacion-discos.md`):
> - **`hd5t`** (5 TB) → biblioteca multimedia de Stash, montado en `/mnt/hd5t`.
> - **`hd2t`** (2 TB) → datos de servicios, volúmenes Docker, swap, backups, montado en `/mnt/hd2t`.

---

## Requisitos previos

- `docs/00-hardware/03-preparacion-discos.md` completado: `hd5t` y `hd2t` montados en `/mnt/hd5t` y `/mnt/hd2t` con etiquetas correctas y entradas persistentes en `/etc/fstab`.
- `docs/01-sistema/02-configuracion-inicial.md` completado: swap creado en `/mnt/hd2t/system/swap/swapfile` (la rama `system/` ya existe parcialmente y se respeta aquí).
- `docs/01-sistema/03-seguridad-base.md` completado: usuario `homelab` con clave SSH, `sudo` operativo, firewall `nftables` activo.
- Confirmación de los IDs del usuario administrador, que se usarán como `PUID`/`PGID` por defecto en los stacks de la familia LinuxServer.io:

  ```bash
  id homelab
  # uid=1000(homelab) gid=1000(homelab) groups=1000(homelab),...
  ```

  Si el UID/GID no es `1000:1000` (porque se ha creado un usuario distinto en Imager) **anotar los valores reales** y sustituirlos en todas las referencias `1000:1000` de este documento y de los siguientes.

---

## Filosofía de la estructura

El reparto se rige por cuatro principios, en orden de prioridad:

1. **Ramas estables y de propósito único por disco**. Cada cosa va en una rama clara (`services/`, `backups/`, `system/`) y nunca se mezclan datos de servicios con backups o con archivos del propio host. Así un `du -sh /mnt/hd2t/*` da una idea instantánea del reparto del disco.
2. **Un directorio por servicio**. Dentro de `services/` hay una subcarpeta por servicio (`pihole/`, `nextcloud/`, `jellyfin/`, …). Cada servicio es responsable de su propio sub-árbol y nunca escribe fuera de él. Esto permite mover, archivar o eliminar un servicio entero borrando una sola rama.
3. **Datos en disco externo, configuración en git, secretos en `.env`**. Los `docker-compose.yml` viven **fuera** de los discos externos: en `~/homelab/` bajo el HOME del usuario, en un repositorio git. Los discos contienen exclusivamente **datos de runtime** (bases de datos, uploads, índices, caché), no código ni configuración versionable. Lo único no-versionable son los `.env` con secretos, que también viven en `~/homelab/` con permisos `0600` y nunca se commitean.
4. **Permisos mínimos suficientes**. El raíz `/mnt/hd2t` y `/mnt/hd5t` son `root:root 0755`. Cada directorio de servicio se crea con el ownership concreto que necesita (típicamente `1000:1000` para imágenes LinuxServer, o sin tocar para bases de datos que se inicializan dentro del contenedor con un UID interno). No se hace `chown -R homelab:homelab /mnt/hd2t`: es la receta más común para que un Postgres o un MariaDB no arranque tras una migración.

> **Sobre los ficheros de Compose**: el árbol `~/homelab/` (versionable) y el árbol `/mnt/hd2t/services/` (datos) son **complementarios**: el primero contiene el `docker-compose.yml` y el `.env` de cada stack, el segundo contiene los volúmenes que esos compose montan. El detalle de cómo se organiza `~/homelab/` (un compose por stack o monolito, redes compartidas, convenciones de naming) se trata en `docs/02-docker/02-estructura-compose.md`; aquí sólo se reserva la **ruta** y la convención.

---

## Estructura final

### `hd2t` (2 TB) — Servicios, backups y sistema

Cuatro ramas en la raíz, ya listadas en `docs/00-hardware/03-preparacion-discos.md` como "estructura prevista" y aquí formalizadas:

| Rama                     | Propósito                                                                                              |
|--------------------------|--------------------------------------------------------------------------------------------------------|
| `/mnt/hd2t/services/`    | Datos persistentes de los stacks Docker. Una subcarpeta por servicio.                                  |
| `/mnt/hd2t/backups/`     | Repositorios Borg, dumps SQL temporales y exportaciones manuales (ver `docs/07-backups/`).             |
| `/mnt/hd2t/system/`      | Uso interno del host: swap, opcionalmente logs persistentes o caché. **No** son datos de servicios.    |
| `/mnt/hd2t/lost+found/`  | Generado por `mkfs.ext4`. No tocar.                                                                    |

Árbol completo previsto, agrupado por la fase en la que cada servicio va a poblar su rama:

```
/mnt/hd2t/
├── services/
│   ├── portainer/                  # Fase 2 — docs/02-docker/03-portainer.md
│   ├── watchtower/                 # Fase 2 — docs/02-docker/04-watchtower.md
│   ├── pihole/                     # Fase 3
│   │   ├── etc-pihole/
│   │   └── etc-dnsmasq.d/
│   ├── unbound/                    # Fase 3
│   ├── caddy/                      # Fase 3
│   │   ├── config/
│   │   └── data/                   # certificados de la CA local
│   ├── tailscale/                  # Fase 3 (si se despliega como contenedor)
│   ├── authelia/                   # Fase 4
│   │   └── config/
│   ├── fail2ban/                   # Fase 4 (si se centraliza en contenedor)
│   ├── prometheus/                 # Fase 5
│   │   └── data/
│   ├── grafana/                    # Fase 5
│   │   └── data/
│   ├── uptime-kuma/                # Fase 5
│   ├── dozzle/                     # Fase 5 (sin estado persistente en general)
│   ├── nextcloud/                  # Fase 6
│   │   ├── html/                   # /var/www/html del contenedor
│   │   ├── data/                   # ficheros de usuario (puede crecer mucho)
│   │   └── db/                     # MariaDB/Postgres del propio Nextcloud
│   ├── samba/                      # Fase 6 (config; los shares apuntan a otras ramas)
│   ├── syncthing/                  # Fase 6
│   ├── minio/                      # Fase 6
│   │   └── data/
│   ├── home-assistant/             # Fase 8
│   ├── mosquitto/                  # Fase 8
│   │   ├── config/
│   │   ├── data/
│   │   └── log/
│   ├── zigbee2mqtt/                # Fase 8
│   ├── node-red/                   # Fase 8
│   ├── jellyfin/                   # Fase 9
│   │   ├── config/
│   │   ├── cache/
│   │   └── transcodes/             # tmpfs en runtime; el dir queda como anchor
│   ├── navidrome/                  # Fase 9
│   ├── audiobookshelf/             # Fase 9
│   ├── calibre-web/                # Fase 9
│   ├── stash/                      # Fase 9 — sólo BD/config; los datos van en hd5t
│   │   ├── config/
│   │   └── metadata/
│   ├── transmission/               # Fase 10
│   │   ├── config/
│   │   ├── downloads/              # destino de las descargas
│   │   └── watch/
│   ├── prowlarr/                   # Fase 10
│   ├── sonarr/                     # Fase 10
│   ├── radarr/                     # Fase 10
│   ├── vaultwarden/                # Fase 11
│   │   └── data/
│   ├── bookstack/                  # Fase 11
│   ├── linkding/                   # Fase 11
│   ├── paperless/                  # Fase 11
│   │   ├── data/
│   │   ├── media/
│   │   ├── consume/                # carpeta de entrada (Samba la expone)
│   │   └── export/
│   ├── mealie/                     # Fase 11
│   ├── stirling-pdf/               # Fase 11 (sin estado)
│   ├── freshrss/                   # Fase 11
│   ├── homepage/                   # Fase 12
│   ├── homarr/                     # Fase 12
│   ├── shared/                     # Datos compartidos entre varios servicios
│   │   ├── media/                  # Películas/series secundarias (Jellyfin + Samba)
│   │   ├── music/                  # Navidrome + Samba
│   │   ├── audiobooks/             # Audiobookshelf + Samba
│   │   └── ebooks/                 # Calibre-Web + Samba
│   └── databases/                  # Bases de datos compartidas (opcional)
│       ├── postgres/
│       └── mariadb/
├── backups/
│   ├── borg/                       # Repositorios Borg
│   │   └── homelab/                # Repo principal del Pi
│   ├── dumps/                      # Dumps SQL pre-Borg (transitorios)
│   └── exports/                    # Exports manuales/puntuales (Vaultwarden, Paperless…)
├── system/
│   └── swap/
│       └── swapfile                # creado en docs/01-sistema/02-configuracion-inicial.md
└── lost+found/                     # generado por ext4
```

> **No** todos los servicios listados se van a desplegar en el primer pase. El árbol describe **el plano completo**: cada doc de fase posterior creará sólo los subdirectorios que necesite. El `services/` raíz y `backups/`, `system/`, sí se crean ahora, vacíos.

> **Sobre `services/shared/`**: cualquier dato que vayan a leer **dos o más servicios** vive aquí (típicamente multimedia secundaria expuesta tanto por Jellyfin como por Samba). Evita duplicar bibliotecas y centraliza los permisos en un único árbol con bit `setgid` (ver más abajo).

> **Sobre `services/databases/`**: la decisión de tener un Postgres/MariaDB compartido entre varios servicios o uno por servicio es responsabilidad de cada doc de fase. La rama existe como **opción**; muchos servicios (Nextcloud, Bookstack…) montarán su propia BD bajo `services/<servicio>/db/` para mantener el aislamiento.

### `hd5t` (5 TB) — Multimedia de Stash

Estructura mínima, dedicada en exclusiva a Stash:

```
/mnt/hd5t/
├── stash/
│   ├── data/                       # Biblioteca multimedia (vídeos, imágenes)
│   └── generated/                  # Thumbnails, sprites, fingerprints generados por Stash
└── lost+found/
```

El detalle de qué subcarpetas crea Stash dentro de `data/` y `generated/` (y cómo importar contenido existente) se trata en `docs/09-multimedia/05-stash.md`. Aquí sólo se reservan las dos ramas.

> **Bibliotecas multimedia secundarias** (Jellyfin, Navidrome…) **no** se almacenan en `hd5t`: van en `/mnt/hd2t/services/shared/{media,music,…}`. La razón es la planificada en `docs/00-hardware/03-preparacion-discos.md`: `hd5t` es de uso único para que un fallo o saturación del disco multimedia de Stash no afecte al resto del homelab.

---

## Creación de la estructura

Todos los pasos se ejecutan **una sola vez** y son idempotentes: re-ejecutarlos no daña nada (`mkdir -p` no falla si los directorios ya existen).

### 1. Crear las ramas raíz de `hd2t`

```bash
sudo mkdir -p /mnt/hd2t/{services,backups,system}
sudo mkdir -p /mnt/hd2t/backups/{borg,dumps,exports}
sudo mkdir -p /mnt/hd2t/backups/borg/homelab
```

`system/swap/` ya existe (creado en `docs/01-sistema/02-configuracion-inicial.md`); no se vuelve a tocar.

### 2. Crear las ramas raíz de `hd5t`

```bash
sudo mkdir -p /mnt/hd5t/stash/{data,generated}
```

### 3. Fijar ownership y permisos de los nodos raíz

Política base: las raíces son de `root:root` y el grupo `homelab` puede listar, pero no escribir directamente. Los subdirectorios de cada servicio se reasignan después según corresponda.

```bash
# Raíces de los discos: root:root, listables por el grupo del usuario
sudo chown root:root /mnt/hd2t /mnt/hd5t
sudo chmod 0755     /mnt/hd2t /mnt/hd5t

# Ramas principales en hd2t
sudo chown root:root /mnt/hd2t/services /mnt/hd2t/backups /mnt/hd2t/system
sudo chmod 0755     /mnt/hd2t/services /mnt/hd2t/backups /mnt/hd2t/system

# La rama de Stash en hd5t es propiedad del usuario del contenedor (PUID/PGID = 1000)
sudo chown -R 1000:1000 /mnt/hd5t/stash
sudo chmod 0755 /mnt/hd5t/stash
```

> **Importante**: el `chown -R 1000:1000 /mnt/hd5t/stash` se ejecuta **ahora** con los directorios vacíos. Hacerlo más tarde, una vez la biblioteca esté poblada con cientos de miles de ficheros, puede tardar **horas** en USB y bloquear lecturas en marcha. Conviene dejar el ownership correcto desde el principio.

### 4. Endurecer `backups/`

La rama de backups contiene material altamente sensible (volcados de BD, configuración con tokens, dumps de Vaultwarden). Sólo `root` debe poder leerla.

```bash
sudo chown -R root:root /mnt/hd2t/backups
sudo chmod 0700 /mnt/hd2t/backups
sudo chmod 0700 /mnt/hd2t/backups/borg /mnt/hd2t/backups/dumps /mnt/hd2t/backups/exports
sudo chmod 0700 /mnt/hd2t/backups/borg/homelab
```

Borgmatic se ejecutará como `root` (necesita leer volúmenes de contenedores con UIDs arbitrarios) y escribirá en este árbol. El detalle de la integración está en `docs/07-backups/02-borgmatic.md`.

### 5. Preparar `services/shared/` con bit `setgid`

Los datos compartidos entre varios servicios (Jellyfin + Samba leyendo la misma biblioteca, por ejemplo) requieren un grupo común para que cualquier proceso que cree un fichero deje un GID legible por todos. Se crea un grupo dedicado `homelab-media` y se aplica el bit `setgid` para que los nuevos ficheros y subdirectorios hereden el grupo.

```bash
# Crear el grupo si no existe (idempotente)
getent group homelab-media >/dev/null || sudo groupadd --system homelab-media

# Añadir al usuario homelab al grupo (relogin necesario para que tome efecto)
sudo usermod -aG homelab-media homelab

# Crear las ramas de datos compartidos
sudo mkdir -p /mnt/hd2t/services/shared/{media,music,audiobooks,ebooks}

# Ownership: usuario PUID por defecto, grupo compartido
sudo chown -R 1000:homelab-media /mnt/hd2t/services/shared
# Modo 2775: rwx para dueño y grupo, r-x para otros, + setgid (el "2")
sudo chmod 2775 /mnt/hd2t/services/shared
sudo find /mnt/hd2t/services/shared -type d -exec sudo chmod 2775 {} +
```

`2775` se desglosa así:

- `2` → bit `setgid` en directorios: los ficheros y subdirectorios nuevos heredan el GID del directorio padre, no el GID primario del proceso que los crea.
- `775` → dueño y grupo con acceso completo, otros sólo lectura/listado.

Esto evita el problema clásico: Jellyfin escanea como `1000:1000` y crea metadatos, Samba intenta leerlos como otro usuario y obtiene "Permission denied" porque el GID por defecto es `1000` y no `homelab-media`.

> Cualquier servicio que vaya a **escribir** en `services/shared/` (Sonarr/Radarr al mover descargas, Calibre-Web al importar ebooks…) tendrá que correr con `PGID=<gid de homelab-media>`. El GID concreto se obtiene con `getent group homelab-media | cut -d: -f3` y se anotará en el `.env` global de los stacks.

### 6. Crear los directorios por servicio (esqueletos vacíos)

Los siguientes comandos crean los esqueletos del árbol `services/` listado más arriba, vacíos. Se mantienen en `root:root 0755` salvo que se indique lo contrario; cada doc de fase posterior reasignará el ownership concreto del subdirectorio que vaya a montar como volumen.

```bash
# Fase 2 — Docker
sudo mkdir -p /mnt/hd2t/services/{portainer,watchtower}

# Fase 3 — Red y DNS
sudo mkdir -p /mnt/hd2t/services/pihole/{etc-pihole,etc-dnsmasq.d}
sudo mkdir -p /mnt/hd2t/services/unbound
sudo mkdir -p /mnt/hd2t/services/caddy/{config,data}
sudo mkdir -p /mnt/hd2t/services/tailscale

# Fase 4 — Seguridad
sudo mkdir -p /mnt/hd2t/services/authelia/config
sudo mkdir -p /mnt/hd2t/services/fail2ban

# Fase 5 — Monitorización
sudo mkdir -p /mnt/hd2t/services/prometheus/data
sudo mkdir -p /mnt/hd2t/services/grafana/data
sudo mkdir -p /mnt/hd2t/services/uptime-kuma
sudo mkdir -p /mnt/hd2t/services/dozzle

# Fase 6 — Almacenamiento
sudo mkdir -p /mnt/hd2t/services/nextcloud/{html,data,db}
sudo mkdir -p /mnt/hd2t/services/samba
sudo mkdir -p /mnt/hd2t/services/syncthing
sudo mkdir -p /mnt/hd2t/services/minio/data

# Fase 8 — Domótica
sudo mkdir -p /mnt/hd2t/services/home-assistant
sudo mkdir -p /mnt/hd2t/services/mosquitto/{config,data,log}
sudo mkdir -p /mnt/hd2t/services/zigbee2mqtt
sudo mkdir -p /mnt/hd2t/services/node-red

# Fase 9 — Multimedia
sudo mkdir -p /mnt/hd2t/services/jellyfin/{config,cache,transcodes}
sudo mkdir -p /mnt/hd2t/services/navidrome
sudo mkdir -p /mnt/hd2t/services/audiobookshelf
sudo mkdir -p /mnt/hd2t/services/calibre-web
sudo mkdir -p /mnt/hd2t/services/stash/{config,metadata}

# Fase 10 — Descargas
sudo mkdir -p /mnt/hd2t/services/transmission/{config,downloads,watch}
sudo mkdir -p /mnt/hd2t/services/{prowlarr,sonarr,radarr}

# Fase 11 — Productividad
sudo mkdir -p /mnt/hd2t/services/vaultwarden/data
sudo mkdir -p /mnt/hd2t/services/{bookstack,linkding,mealie,stirling-pdf,freshrss}
sudo mkdir -p /mnt/hd2t/services/paperless/{data,media,consume,export}

# Fase 12 — Dashboards
sudo mkdir -p /mnt/hd2t/services/{homepage,homarr}

# Bases de datos compartidas (opcional)
sudo mkdir -p /mnt/hd2t/services/databases/{postgres,mariadb}
```

### 7. Reasignar ownership de los servicios LinuxServer.io

Las imágenes de la familia LinuxServer.io (`linuxserver/jellyfin`, `linuxserver/sonarr`, `linuxserver/radarr`, `linuxserver/prowlarr`, `linuxserver/transmission`, `linuxserver/calibre-web`, `linuxserver/audiobookshelf`, `linuxserver/syncthing`…) ejecutan el proceso con un UID/GID configurable vía `PUID`/`PGID`, **pero no hacen `chown` recursivo** del volumen al arrancar (sólo del nivel superior). Si el directorio inicial no es de su propiedad, el primer arranque falla con errores tipo `chown: changing ownership of '/config': Operation not permitted`.

Se deja todo el árbol de servicios "linuxserveriescos" con ownership `1000:1000`:

```bash
sudo chown -R 1000:1000 \
    /mnt/hd2t/services/jellyfin \
    /mnt/hd2t/services/navidrome \
    /mnt/hd2t/services/audiobookshelf \
    /mnt/hd2t/services/calibre-web \
    /mnt/hd2t/services/transmission \
    /mnt/hd2t/services/prowlarr \
    /mnt/hd2t/services/sonarr \
    /mnt/hd2t/services/radarr \
    /mnt/hd2t/services/syncthing \
    /mnt/hd2t/services/freshrss
```

### 8. Directorios que **no** se reasignan

Los siguientes servicios **inicializan ellos solos** su volumen con un UID interno fijo del contenedor. No se les hace `chown` desde el host: los contenedores se encargarán en el primer arranque. Quedan en `root:root 0755`.

| Servicio                  | UID interno típico | Razón                                                          |
|---------------------------|--------------------|----------------------------------------------------------------|
| `pihole`                  | `pihole` (999)     | Imagen oficial; gestiona permisos en el `entrypoint`.          |
| `caddy`                   | `root`             | Imagen oficial corre como root para ligarse al puerto 53/80/443. |
| `nextcloud/html` y `db`   | `www-data` (33), `mysql`/`postgres` (999/70) | El propio contenedor hace `chown` en el primer arranque. |
| `prometheus/data`         | `nobody` (65534)   | Imagen oficial de Prometheus.                                   |
| `grafana/data`            | `grafana` (472)    | Imagen oficial.                                                 |
| `vaultwarden/data`        | `root` o `1000`    | Configurable; se decidirá en `docs/11-productividad/01-vaultwarden.md`. |
| `home-assistant`          | `root`             | Imagen oficial corre como root.                                |
| `mosquitto/{config,data,log}` | `mosquitto` (1883) | Hay que hacerle `chown` específicamente en su doc de fase.    |
| `databases/postgres`      | `postgres` (999)   | Imagen oficial de Postgres.                                     |
| `databases/mariadb`       | `mysql` (999)      | Imagen oficial de MariaDB.                                      |

> Es habitual ver guías que recomiendan `sudo chown -R 1000:1000 /mnt/hd2t` "para evitar problemas". **No hacerlo**: rompe la inicialización de Postgres, MariaDB, Prometheus, Grafana y otros, que comprueban explícitamente que su volumen pertenece al UID interno antes de tocar nada y abortan si no.

### 9. Ubicación del repositorio de Compose y `.env`

Crear el árbol de configuración versionable bajo el HOME del usuario, **no** en `/mnt/hd2t`:

```bash
mkdir -p ~/homelab
chmod 0700 ~/homelab
```

Más adelante (`docs/02-docker/02-estructura-compose.md`) este directorio se inicializa como repositorio git y se puebla con un sub-árbol por stack (`~/homelab/red/`, `~/homelab/multimedia/`, …), cada uno con su `docker-compose.yml` y su `.env`. El backup del propio `~/homelab/` se incluirá en Borg (`docs/07-backups/02-borgmatic.md`) como una fuente más, junto con `/etc/`, `/mnt/hd2t/services/` y los volúmenes Docker.

> **Por qué no en `hd2t`**: el repositorio de Compose es **código y configuración**, no datos. Vivir en `$HOME` permite editarlo desde el equipo de trabajo por SSHFS / VSCode Remote y, sobre todo, habilita que `git status` salga limpio sin ruido de ficheros generados por servicios.

> **Secretos en `.env`**: `0600`, sólo legibles por `homelab`, **nunca commiteados**. Una plantilla `.env.example` versionada documenta qué variables hay que rellenar. La rotación de secretos forma parte de `docs/04-seguridad/01-authelia.md` y del propio gestor (Vaultwarden) cuando esté operativo.

---

## Convenciones a respetar en docs posteriores

Las siguientes convenciones son **vinculantes** para todas las fases siguientes. Cualquier divergencia debe documentarse explícitamente en el doc de la fase.

### Rutas

- Los volúmenes Docker mapeados al host **siempre** apuntan a `/mnt/hd2t/services/<servicio>/<subdir>` (o `/mnt/hd5t/stash/...` para Stash).
- **Nunca** se usan paths fuera de `/mnt/hd2t/services/`, `/mnt/hd5t/stash/`, `/mnt/hd2t/backups/` o `/mnt/hd2t/system/` para datos persistentes. Si un servicio necesita una ruta nueva, se extiende el árbol de este documento (PR a esta misma página) antes de desplegarlo.
- Los volúmenes **named** de Docker (los que viven en `/var/lib/docker/volumes/`) se evitan: rompen los backups por bind-mount y dificultan la migración. Excepción: volúmenes anónimos generados por Compose para dependencias internas no críticas (caché de un build).

### Ownership y permisos

- Imágenes LinuxServer.io: `PUID=1000`, `PGID=1000`. Volumen de `/config` con `chown -R 1000:1000` previo.
- Bases de datos en imágenes oficiales (Postgres, MariaDB, Redis, MongoDB): **no** tocar el ownership desde el host. El contenedor se inicializa solo.
- Datos compartidos entre servicios: bajo `services/shared/`, ownership `1000:homelab-media`, modo `2775` (con setgid).
- `backups/` en `0700 root:root`. Sólo Borgmatic (corriendo como root) escribe ahí.
- Cualquier directorio que reciba carga de un usuario humano (Paperless `consume/`, Nextcloud `data/`) tiene su política de permisos descrita en el doc de la fase concreta.

### `PUID`/`PGID` por defecto en `.env`

En el `.env` global del repositorio de Compose se exportarán las variables de referencia, calculadas una sola vez:

```bash
echo "PUID=$(id -u homelab)" >> ~/homelab/.env
echo "PGID=$(id -g homelab)" >> ~/homelab/.env
echo "MEDIA_GID=$(getent group homelab-media | cut -d: -f3)" >> ~/homelab/.env
echo "TZ=Europe/Madrid" >> ~/homelab/.env
chmod 0600 ~/homelab/.env
```

> El `TZ` se hereda de `docs/01-sistema/02-configuracion-inicial.md`. Centralizarlo aquí evita repetirlo en cada `docker-compose.yml` y mantiene una única fuente de verdad.

---

## Verificación final

Antes de pasar a `docs/02-docker/01-instalacion-docker.md`, comprobar:

- [ ] `tree -L 2 /mnt/hd2t` (instalable con `sudo apt install -y tree`) muestra `services/`, `backups/`, `system/` como ramas raíz, ninguna de ellas vacía después de los pasos anteriores.
- [ ] `ls -la /mnt/hd2t` deja ver `services` `backups` `system` con propietario `root:root`, modo `0755` para `services` y `system`, y `0700` para `backups`.
- [ ] `ls -la /mnt/hd5t/stash` muestra `data/` y `generated/` con propietario `1000:1000`.
- [ ] `stat -c '%a %U:%G' /mnt/hd2t/services/shared` devuelve `2775 root:homelab-media` (o el dueño que corresponda con `id 1000`).
- [ ] `getent group homelab-media` lista el grupo y `groups homelab` incluye `homelab-media` tras un `newgrp homelab-media` o un nuevo login.
- [ ] `stat -c '%U:%G' /mnt/hd2t/services/jellyfin /mnt/hd2t/services/sonarr /mnt/hd2t/services/radarr` devuelve `1000:1000` en los tres (los servicios LinuxServer.io reasignados).
- [ ] `stat -c '%U:%G' /mnt/hd2t/services/prometheus/data /mnt/hd2t/services/grafana/data` devuelve `root:root` (no se les hace `chown`; lo hará la imagen).
- [ ] `ls -la /mnt/hd2t/backups` lista `borg/`, `dumps/`, `exports/`, todos `0700 root:root`.
- [ ] `ls /mnt/hd2t/system/swap/swapfile` sigue ahí y `swapon --show` lo lista (la creación del árbol no ha tocado el swap).
- [ ] `~/homelab` existe en el HOME del usuario `homelab` con permisos `0700`.
- [ ] Un `df -hT /mnt/hd2t /mnt/hd5t` sigue indicando uso ≈0 % (la creación de directorios vacíos no consume espacio apreciable).

---

## Troubleshooting

### Un contenedor LinuxServer.io aborta con `chown: changing ownership of '/config': Operation not permitted`

El volumen del host pertenece a `root:root` (o a un UID/GID distinto del solicitado por `PUID`/`PGID`) y la imagen no tiene capabilities para hacer `chown`. Solución:

```bash
sudo chown -R 1000:1000 /mnt/hd2t/services/<servicio>
docker compose up -d <servicio>
```

Si se ha cambiado el UID del usuario `homelab` después del provisionado, ajustar todos los servicios afectados con un único comando recorriendo la lista del paso 7.

### Postgres/MariaDB aborta con `database files are incompatible with server` o `Incorrect file owner`

Probable `chown -R 1000:1000` aplicado por error sobre el directorio de datos de la base. Las imágenes oficiales comprueban que el volumen pertenezca a su UID interno (`postgres` 999 o `mysql` 999). Recuperación:

```bash
sudo chown -R 999:999 /mnt/hd2t/services/<servicio>/db
docker compose up -d <servicio>
```

Si el volumen ya tiene datos críticos, **no** ejecutar `chown -R` a ciegas: parar el servicio, hacer un backup completo del directorio (`tar` o `cp -a`), restaurar desde un volumen limpio si está disponible, y solo entonces aplicar el `chown`.

### Jellyfin no ve los ficheros de `services/shared/media/` aunque `ls` los lista bien

Casi siempre es un problema de **GID heredado**. Comprobar:

```bash
ls -la /mnt/hd2t/services/shared/media/<carpeta-problema>
stat -c '%a %U:%G' /mnt/hd2t/services/shared/media/<carpeta-problema>
```

Si el GID no es `homelab-media` y el modo no incluye el bit `setgid` (el primer dígito debería ser `2`), reaplicar:

```bash
sudo chown -R 1000:homelab-media /mnt/hd2t/services/shared
sudo find /mnt/hd2t/services/shared -type d -exec sudo chmod 2775 {} +
sudo find /mnt/hd2t/services/shared -type f -exec sudo chmod 0664 {} +
```

A partir de aquí, todo nuevo fichero hereda el grupo correcto. Verificar también que el contenedor tenga `PGID` igual al GID de `homelab-media` (no al `1000` por defecto del usuario): se puede pasar como variable extra en el `.env` (`MEDIA_GID`) y referenciarla en el `docker-compose.yml` del servicio compartido.

### `mkdir -p /mnt/hd2t/services/...` falla con `Read-only file system`

Síntoma de filesystem montado en sólo lectura, normalmente porque ext4 ha detectado un error y se ha auto-protegido. Diagnóstico:

```bash
dmesg | tail -50
mount | grep hd2t
```

Recuperación segura:

1. Parar contenedores que usen `hd2t` (en este punto del provisionado todavía no hay).
2. Desmontar: `sudo umount /mnt/hd2t`.
3. Comprobar el filesystem: `sudo fsck -y /dev/disk/by-label/hd2t`.
4. Volver a montar: `sudo mount /mnt/hd2t`.
5. Si vuelve a pasarse a sólo lectura espontáneamente, sospechar del cable USB, alimentación o del propio disco: revisar SMART (`docs/00-hardware/03-preparacion-discos.md`).

### `du -sh /mnt/hd2t/*` cuelga durante minutos

Tener varios subdirectorios ya poblados con muchísimos ficheros pequeños sobre USB es lento por diseño. Mitigaciones:

```bash
# Vista por servicio sin recurrir a métricas exactas:
df -hT /mnt/hd2t

# Tamaño aproximado por rama, en paralelo y con caché:
sudo apt install -y ncdu
sudo ncdu -x /mnt/hd2t
```

`ncdu` es interactivo y mucho más rápido en discos USB que un `du -sh` en bucle. Conviene mantenerlo instalado para diagnósticos rápidos.

### Tras crear el grupo `homelab-media`, los nuevos `docker compose up` siguen escribiendo con grupo `1000`

El `.env` no se ha actualizado o el contenedor tiene cacheada la sesión anterior. Pasos:

1. Confirmar el GID real: `getent group homelab-media | cut -d: -f3`.
2. Comparar con `~/homelab/.env`: `grep MEDIA_GID ~/homelab/.env`.
3. Recargar el stack del servicio afectado: `docker compose up -d --force-recreate <servicio>`.
4. Comprobar dentro del contenedor: `docker exec <servicio> id` debe listar el GID nuevo en `groups`.

---

## Referencias

- Filesystem Hierarchy Standard (FHS): <https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html>
- LinuxServer.io — `PUID`/`PGID` y volúmenes: <https://docs.linuxserver.io/general/understanding-puid-and-pgid>
- Docker — Bind mounts vs volúmenes nombrados: <https://docs.docker.com/storage/bind-mounts/>
- `chmod` — Bit `setgid` en directorios: <https://man7.org/linux/man-pages/man1/chmod.1.html>
- `find` — Aplicar permisos por tipo (`-type d`, `-type f`): <https://man7.org/linux/man-pages/man1/find.1.html>
- `ncdu` — Análisis interactivo de uso de disco: <https://dev.yorhel.nl/ncdu>
- Compose — Variables de entorno y `.env`: <https://docs.docker.com/compose/environment-variables/set-environment-variables/>
- Postgres en Docker — Permisos del volumen de datos: <https://hub.docker.com/_/postgres>
- MariaDB en Docker — Permisos del volumen de datos: <https://hub.docker.com/_/mariadb>
