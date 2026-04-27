# Fail2ban (jails para servicios + integración con logs de contenedores)

## Descripción

Despliegue de un **`fail2ban` contenerizado** dentro del _stack_ `seguridad` que **extiende** el `fail2ban` del host (configurado en `docs/01-sistema/03-seguridad-base.md` para el _jail_ SSH) con _jails_ adicionales para los **servicios HTTP del homelab**: el portal de **Authelia**, el _reverse proxy_ de **Caddy** (tormenta de 4xx) y los _placeholders_ de **Nextcloud** (`docs/06-almacenamiento/01-nextcloud.md`) y **Vaultwarden** (`docs/11-productividad/01-vaultwarden.md`) que se descomentarán cuando lleguen sus respectivas fases. El contenedor lee los logs de los servicios desde el sistema de ficheros del host (no a través del _socket_ de Docker), y aplica los _bans_ inyectando reglas en el `nftables` del host vía `network_mode: host` + `NET_ADMIN`.

Este documento **completa el _stack_ `seguridad`** que estrenó `docs/04-seguridad/01-authelia.md`: añade un servicio `fail2ban` al `~/homelab/seguridad/docker-compose.yml`, crea el subdirectorio versionado `~/homelab/seguridad/fail2ban/` con `jail.local`, `fail2ban.local` y los `filter.d/*.local` que necesita, hace una **modificación mínima** al `configuration.yml` de Authelia (añadir `log.file_path` para que escriba un fichero además de a `stdout`) y deja el sistema con dos `fail2ban` corriendo en paralelo — el del host para SSH y el contenerizado para servicios — sin colisión de reglas.

> **Alcance**: este documento despliega `fail2ban` para los **servicios que ya están en pie** (Authelia, Caddy). **Activa** los _jails_ correspondientes y **deja preparados, pero deshabilitados**, los _jails_ de Nextcloud y Vaultwarden hasta que esos servicios se desplieguen. **No** toca el `fail2ban` del host (sigue gestionando SSH como en `docs/01-sistema/03-seguridad-base.md`). **No** introduce `iptables-legacy` ni cambia el _backend_ de firewall del host (`nftables`, ver `docs/01-sistema/03-seguridad-base.md`).

> **Recordatorio de red**: el homelab vive en LAN + Tailscale, sin exposición a internet. Los _bans_ que aplica este `fail2ban` afectan a IPs de la LAN doméstica (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) y de Tailscale (`100.64.0.0/10`). El `ignoreip` global excluye explícitamente la _shortlist_ del homelab para que un dispositivo del operador no se autobannee tras unos cuantos errores legítimos.

---

## Requisitos previos

- `docs/01-sistema/03-seguridad-base.md` completado: `fail2ban` instalado en el host con el _jail_ `sshd` activo y `nftables` con la tabla `inet filter` cargada. Confirmar:
  ```bash
  systemctl is-active fail2ban
  sudo fail2ban-client status sshd
  sudo nft list table inet filter | head -20
  ```
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/fail2ban/` ya existe (creado en la sección "Fase 4 — Seguridad", `root:root 0755`). En este documento se aplica el `chown`/`chmod` final que falta y se crea el subárbol `db/`.
- `docs/02-docker/02-estructura-compose.md` completado: red Docker `homelab` (`br-homelab`) externa creada, `~/homelab/.env` con `TZ`, `PUID`, `PGID`, `HOMELAB_DOMAIN=lan` poblados, _Makefile_ con `make up STACK=<stack>` operativo.
- `docs/03-red/04-caddy.md` completado: el _snippet_ `~/homelab/red/caddy/snippets/logging.caddy` está activo y los servicios HTTP escriben sus logs a `/mnt/hd2t/services/caddy/log/<host>.log` en formato JSON (un fichero por _virtual host_). Confirmar:
  ```bash
  ls -la /mnt/hd2t/services/caddy/log/
  # debe listar al menos pihole.lan.log y portainer.lan.log
  ```
- `docs/04-seguridad/01-authelia.md` completado: el _stack_ `seguridad` existe con Authelia + Redis (`docker compose -f ~/homelab/seguridad/docker-compose.yml ps`), `auth.lan` responde y el _jail_ de Authelia tiene un servicio real al que vigilar.
- Conectividad saliente para descargar la imagen del `fail2ban` contenerizado:
  ```bash
  docker pull --platform linux/arm64 crazymax/fail2ban:1.1.0 >/dev/null && echo OK
  ```
- Que el _kernel_ tenga el módulo `nf_tables` cargado (lo cargó ya `docs/01-sistema/03-seguridad-base.md`):
  ```bash
  lsmod | grep -E 'nf_tables|nft' | head -3
  ```

---

## Decisiones de diseño

### Por qué un segundo `fail2ban` contenerizado, en lugar de extender el del host

El `fail2ban` del host de `docs/01-sistema/03-seguridad-base.md` ya escucha `journald` y banea por SSH. La _opción A_ sería añadirle más _jails_ que leyeran ficheros de logs de Docker (`/var/lib/docker/containers/<id>/<id>-json.log` o `/mnt/hd2t/services/<servicio>/log/`). Funciona técnicamente, pero tiene tres inconvenientes serios para este homelab:

1. **Configuración no versionable**. El `fail2ban` del host vive en `/etc/fail2ban/`, fuera del repositorio `~/homelab/`. Cada vez que se añade un servicio nuevo (Nextcloud, Vaultwarden…) hay que editar `/etc/fail2ban/jail.local` con `sudo` y reiniciar el servicio del host. No queda traza en git, los _diffs_ entre cambios son invisibles, los _rollback_ son manuales.
2. **Acoplamiento con la microSD del host**. Si la microSD muere y se restaura desde una imagen base, hay que recrear todos los `jail.d/`/`filter.d/` a mano. La _disaster recovery_ del `seguridad` _stack_ (`docs/13-operaciones/02-disaster-recovery.md`) se simplifica si toda la configuración de servicios vive en `~/homelab/seguridad/` (que está en hd2t y/o git).
3. **Dependencia ordinal del arranque**. El `fail2ban` del host arranca antes que `docker.service` por dependencias de _systemd_. Los _logs_ de los contenedores no existen aún en disco cuando `fail2ban` recarga sus _jails_, lo que provoca _warnings_ tipo `Could not find any log file matching '...'` y, dependiendo del _backend_, marca el _jail_ como `disabled`. Es resoluble (`systemd` overrides) pero añade fricción.

La _opción B_ — un `fail2ban` contenerizado en el _stack_ `seguridad` — resuelve los tres puntos:

1. **Versionable**: la configuración entera (`jail.local`, `fail2ban.local`, `filter.d/`) vive en `~/homelab/seguridad/fail2ban/` y se _commitea_ a git como cualquier otra pieza del homelab.
2. **Backups limpios**: el contenedor montará la BD persistente (`fail2ban.sqlite3`) en `/mnt/hd2t/services/fail2ban/`, donde Borgmatic ya respalda el resto del _stack_.
3. **Arranque coherente**: `fail2ban` arranca _con_ el resto del _stack_ `seguridad` (`docker compose up -d`), después de que los logs de los servicios existan. `restart: unless-stopped` y los _healthchecks_ encajan en el mismo modelo que Authelia y Redis.

**Coste**: hay dos `fail2ban` en la Pi. No es un problema operativo: cada uno mantiene **sus propias _chains_ en `nftables`** (prefijo `f2b-` con nombre de _jail_, distintos en cada instancia) y **sus propias DBs** (`/var/lib/fail2ban/fail2ban.sqlite3` para el host, `/mnt/hd2t/services/fail2ban/db/fail2ban.sqlite3` para el contenedor). Dos procesos, ~25 MB extra de RAM, sin solapamiento. La separación de roles (host=SSH, contenedor=servicios HTTP) es además didácticamente clara.

### Por qué `crazymax/fail2ban` y no otra imagen

Tres imágenes oficiales / mantenidas hay en el ecosistema:

| Imagen                               | Notas                                                                                                                                                        |
|--------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `crazymax/fail2ban`                  | Mantenida por Crazymax (autor de varias herramientas de Docker bien consideradas), multi-arch (ARM64 incluido), entrypoint `s6-overlay` simple, reload con `SIGHUP`, _healthcheck_ via `fail2ban-client ping`, configurable por env vars (`F2B_LOG_LEVEL`, `F2B_DB_PURGE_AGE`, `TZ`). Imagen ~50 MB. |
| `lscr.io/linuxserver/fail2ban`       | LinuxServer.io. Multi-arch. Mismo soporte de UID/GID por env (`PUID`/`PGID`). Algo más pesada (~70 MB). Convención `/config` un poco distinta (no usa `s6-overlay` para los servicios internos en este caso, pero sí en sus otras imágenes). |
| Construir desde `debian:bookworm-slim` con `apt install fail2ban` | La opción "vainilla". Da control total pero hay que mantener el `Dockerfile`, los `apt-get update` periódicos, y reproducir lo que las dos imágenes anteriores ya hacen. Sólo merece la pena si las dos anteriores quedasen abandonadas. |

**`crazymax/fail2ban:1.1.0` elegido**:

- _Tag_ pinneado a versión completa (convención del homelab; nada de `:latest` ni `:1`).
- ARM64 oficial, sin compilación cruzada propia.
- Soporta de fábrica el patrón "configs en bind-mount read-only + DB en bind-mount rw" que se aplica aquí.
- Watchtower **opt-out**: ver más abajo.

### `network_mode: host` y por qué

`fail2ban` aplica los _bans_ insertando reglas en el firewall del sistema. Para que esas reglas filtren el tráfico que entra a la Pi (puertos `:80`, `:443` de Caddy en macvlan / red `homelab`, etc.), las reglas tienen que vivir en **el `nftables` del host**, no en el _network namespace_ del contenedor.

Dos formas de conseguirlo:

1. **`network_mode: host`** + `cap_add: NET_ADMIN, NET_RAW` — el contenedor comparte _network namespace_ con el host. `nft` dentro del contenedor opera sobre el mismo _ruleset_ que `nft` desde una _shell_ del host. Es el patrón documentado por la propia imagen `crazymax/fail2ban` y por el equipo de `fail2ban` (`fail2ban` en Docker, FAQ).
2. Mantener `network_mode: bridge` y montar el `nftables` _socket_ vía `bind` — técnicamente posible con _tooling_ adicional, pero frágil y poco soportado.

Se va con (1). Implicaciones:

- **El contenedor no se conecta a la red Docker `homelab`**. No la necesita: no habla HTTP con ningún otro contenedor; sólo lee logs del sistema de ficheros y manda comandos `nft` al kernel del host.
- **Los _ports_ que abre `fail2ban-client` (`/var/run/fail2ban/fail2ban.sock`) son del _filesystem namespace_ del contenedor**, no de la red. No hay riesgo de que se publique al host.
- **`cap_add: NET_ADMIN, NET_RAW`** es lo mínimo necesario para que `nft` modifique `nftables`. No se concede `--privileged`.

### Coexistencia con el `fail2ban` del host

Los dos `fail2ban` escriben en el mismo `nftables` del host. Coexisten sin colisión por **dos hechos del propio diseño de `fail2ban`**:

1. **Cada _jail_ crea su propia _chain_** con nombre `f2b-<jail>` (acción `nftables-multiport`). El _jail_ `sshd` del host crea `f2b-sshd`. El _jail_ `authelia` del contenedor crea `f2b-authelia`. Son _chains_ distintas que `nftables` mantiene independientes.
2. **Las _set_ de IPs baneadas también son independientes**: `addr-set-sshd` y `addr-set-authelia` viven cada uno en su propia _chain_. Un IP baneado por uno no aparece en el otro (lo cual es **lo correcto**: si una IP intenta forzar Authelia, no es razón para bloquearle el SSH si nunca lo ha intentado).

Para confirmar manualmente la separación tras desplegar:

```bash
sudo nft list ruleset | grep -E 'chain f2b-' | sort
# chain f2b-authelia { ... }     ← contenedor
# chain f2b-caddy-status { ... } ← contenedor
# chain f2b-sshd { ... }         ← host
```

> **Riesgo asumido**: si en el futuro se renombra un _jail_ (p.ej. cambiar `[authelia]` a `[authelia-1fa]` y dejar el viejo en una segunda jail) **y los nombres del host y del contenedor llegasen a coincidir**, las _chains_ se pisarían. La regla operativa: **prefijar con `f2b-` y dejar el sufijo único entre ambas instancias**. En este documento el sufijo de cada _jail_ es genérico (servicio), no genera ambigüedad.

### Lectura de logs: ficheros, no `docker logs`

`fail2ban` admite tres _backends_ de lectura de logs: `pyinotify` (ficheros con notificación de cambios), `polling` (ficheros con _polling_), y `systemd` (journald). El contenerizado no tiene acceso al _journald_ del host (montar `/run/log/journal` y `/etc/machine-id` en _read-only_ es posible pero frágil entre versiones de Debian/`systemd`), así que se eligen ficheros (`backend = auto`, que prioriza `pyinotify` y cae a `polling` si fallara).

Dos fuentes de logs de servicios HTTP, ambas ya disponibles:

1. **Authelia** — escribe a `stdout` por defecto. Para que `fail2ban` lo lea por fichero, este documento añade dos líneas a `~/homelab/seguridad/configuration.yml`:
   ```yaml
   log:
     # ... lo ya existente ...
     file_path: /config/authelia.log
     keep_stdout: true
   ```
   `/config` está bind-mounteado a `/mnt/hd2t/services/authelia/config/`, así que el fichero queda en `/mnt/hd2t/services/authelia/config/authelia.log` en el host. `fail2ban` lo monta como `/var/log/authelia/authelia.log:ro`. `keep_stdout: true` mantiene el log a `stdout` para que Dozzle (`docs/05-monitorizacion/06-dozzle.md`) y los `docker logs` sigan funcionando. _Es el único cambio que este documento hace fuera de su propio _stack_ a un fichero de otra fase: es un **añadido**, no un renombrado, y no rompe nada del despliegue de Authelia._

2. **Caddy** — `docs/03-red/04-caddy.md` ya configuró el _snippet_ `logging` que escribe un fichero JSON por _virtual host_ a `/var/log/caddy/<host>.log` (mapeado a `/mnt/hd2t/services/caddy/log/<host>.log` en el host). `fail2ban` lo monta como `/var/log/caddy:ro` y lee `/var/log/caddy/*.log`. **No** se modifica nada del _stack_ `red`.

> **Por qué no leer `/var/lib/docker/containers/<id>/<id>-json.log`**: técnicamente es la otra opción (Docker conserva ahí los `stdout`/`stderr` de cada contenedor en formato JSON-lines). El problema es que el `<id>` del contenedor cambia en cada `docker compose up -d --force-recreate`, lo que obliga a un `logpath` con _glob_ (`/var/lib/docker/containers/*/*-json.log`) que `fail2ban` re-evalúa cada vez. Funciona pero (a) requiere un _filter_ que entienda la doble envoltura JSON (`{"log":"<json_real>","stream":"stdout"}`), y (b) hace que un cambio en el _logging driver_ de Docker (de `json-file` a `journald` o `local`) rompa el _jail_ silenciosamente. Mantener cada servicio escribiendo a un fichero "humano" en su propio bind-mount es más estable y más fácil de depurar.

### `dbfile` fuera de `/data`

La imagen `crazymax/fail2ban` por defecto deja la base de datos en `/data/db/fail2ban.sqlite3`, lo que mete configuración versionable y estado mutable en la misma carpeta. Aquí se separan:

- **Configuración versionada**: `~/homelab/seguridad/fail2ban/` → bind-mount a `/data` **read-only** (`:ro`).
- **Base de datos y _runtime_**: `/mnt/hd2t/services/fail2ban/` → bind-mount a `/var/lib/fail2ban` **read-write**.

`fail2ban.local` redefine `dbfile` para que apunte a `/var/lib/fail2ban/fail2ban.sqlite3`, no a `/data/db/`. Resultado: el _stack_ se puede recrear en otra Pi clonando el repo + restaurando `/mnt/hd2t/services/fail2ban/`, sin tener que extraer la BD del propio bind de configuración.

### Cuáles _jails_ se activan ahora y cuáles quedan como _placeholder_

| Jail              | Estado en este doc      | Servicio del homelab            | Documento donde se activará |
|-------------------|-------------------------|---------------------------------|------------------------------|
| `authelia`        | **`enabled = true`**    | Authelia (este _stack_)         | _ya en este documento_       |
| `caddy-status`    | **`enabled = true`**    | Caddy (stack `red`)             | _ya en este documento_       |
| `nextcloud`       | _placeholder_, `enabled = false` | Nextcloud                | `docs/06-almacenamiento/01-nextcloud.md` |
| `vaultwarden`     | _placeholder_, `enabled = false` | Vaultwarden              | `docs/11-productividad/01-vaultwarden.md` |
| `recidive`        | **`enabled = true`**    | Meta-jail: re-bania a IPs ya baneadas varias veces antes | _ya en este documento_ |

> **Por qué dejar los _placeholder_ desactivados pero versionados desde ya**: cuando llegue la fase de Nextcloud o Vaultwarden, su documento sólo tiene que cambiar `enabled = false → true`, validar y recargar el contenedor. La definición del _jail_, el _filter_ y el `logpath` ya están escritos en sitio coherente (`~/homelab/seguridad/fail2ban/`), revisados, y no hay que coordinar cambios entre _stacks_.

> **Por qué `recidive`**: es el _jail_ "meta" canónico de `fail2ban`: monitoriza el log del propio `fail2ban` (`/var/log/fail2ban/fail2ban.log`) y banea durante mucho más tiempo (1 semana) a IPs que ya han sido baneadas N veces por otros _jails_. Útil cuando un dispositivo de la LAN comprometido prueba a tantear varios servicios distintos: en lugar de N bans cortos por servicio, un único ban largo que cubre todo el tráfico hacia la Pi.

### Política de _bans_

Valores por defecto del `[DEFAULT]` (consistentes con los del `fail2ban` del host pero **algo más estrictos** para servicios HTTP, que son más fáciles de scriptear que SSH):

| Parámetro    | Valor    | Comentario                                                                                  |
|--------------|----------|---------------------------------------------------------------------------------------------|
| `bantime`    | `1h`     | Tiempo de ban inicial.                                                                      |
| `findtime`   | `10m`    | Ventana de cuenta de fallos.                                                                |
| `maxretry`   | `5`      | Fallos en `findtime` antes de banear.                                                       |
| `bantime.increment` | `true` | Re-bans del mismo IP se duplican: 1 h, 2 h, 4 h, … hasta `bantime.maxtime`.                |
| `bantime.factor` | `2`   | Cómo crece el `bantime` en cada repetición.                                                  |
| `bantime.maxtime` | `1w` | Tope superior por re-ban (1 semana). El `recidive` _jail_ trabaja sobre este mecanismo.     |
| `banaction`  | `nftables-multiport` | Coherente con el firewall del host (`nftables`).                                  |
| `banaction_allports` | `nftables-allports` | Para _jails_ que cubren todo el tráfico de la IP (`recidive`).            |
| `backend`    | `auto`   | `pyinotify` si está disponible (lo está en la imagen), `polling` _fallback_.                |

### Almacenamiento

| Ruta en el host                                                | Contenido                                                   | Versionable | Backup |
|----------------------------------------------------------------|-------------------------------------------------------------|-------------|--------|
| `~/homelab/seguridad/docker-compose.yml`                       | Definición del _stack_ — modificada para añadir `fail2ban`  | git         | git    |
| `~/homelab/seguridad/.env`                                     | Variables del _stack_ — añade `FAIL2BAN_IMAGE_TAG`          | **NO**      | nota local |
| `~/homelab/seguridad/.env.example`                             | Plantilla — añade `FAIL2BAN_IMAGE_TAG`                       | git         | git    |
| `~/homelab/seguridad/configuration.yml`                        | Configuración de Authelia — **+2 líneas** (`file_path`, `keep_stdout`) | git | git    |
| `~/homelab/seguridad/fail2ban/fail2ban.local`                  | _Daemon_ defaults: `loglevel`, `dbfile`, `dbpurgeage`        | git         | git    |
| `~/homelab/seguridad/fail2ban/jail.local`                      | Definición de _jails_ y `[DEFAULT]`                          | git         | git    |
| `~/homelab/seguridad/fail2ban/filter.d/authelia.local`         | Filtro JSON para logs de Authelia                            | git         | git    |
| `~/homelab/seguridad/fail2ban/filter.d/caddy-status.local`     | Filtro JSON para logs de Caddy (4xx por IP)                  | git         | git    |
| `~/homelab/seguridad/fail2ban/filter.d/nextcloud.local`        | Filtro para logs de Nextcloud (`docs/06-almacenamiento/01-nextcloud.md`) | git | git |
| `~/homelab/seguridad/fail2ban/filter.d/vaultwarden.local`      | Filtro para logs de Vaultwarden (`docs/11-productividad/01-vaultwarden.md`) | git | git |
| `/mnt/hd2t/services/fail2ban/db/fail2ban.sqlite3`              | DB de bans persistentes (sobrevive a reinicios)              | **NO**      | Sí (Borgmatic) — pérdida = re-detección, no crítico |
| `/mnt/hd2t/services/fail2ban/log/fail2ban.log`                 | Log propio de `fail2ban` (consumido por el _jail_ `recidive`) | **NO**     | No (transitorio) |
| `/mnt/hd2t/services/authelia/config/authelia.log`              | Log de Authelia escrito por el propio Authelia tras este doc  | **NO**     | No (transitorio) |
| `/mnt/hd2t/services/caddy/log/*.log`                           | Logs de Caddy (ya existentes desde `docs/03-red/04-caddy.md`) | **NO**     | No (transitorio) |

> **Sobre `db/fail2ban.sqlite3`**: si se borra, `fail2ban` arranca con la lista de bans vacía. No es catastrófico (un atacante volverá a ser baneado en cuanto vuelva a fallar), pero conviene respaldarla con Borgmatic para no "perdonar" automáticamente todas las IPs en un _restore_ tras incidente.

---

## Estructura del _stack_ `seguridad` tras este documento

El _stack_ ya existía con Authelia + Redis. Tras este documento se le añade el subdirectorio `fail2ban/`:

```
~/homelab/seguridad/
├── docker-compose.yml        # ← modificado (añade el servicio fail2ban)
├── .env                      # ← modificado (añade FAIL2BAN_IMAGE_TAG)
├── .env.example              # ← modificado (idem)
├── configuration.yml         # ← modificado (Authelia: +log.file_path, +keep_stdout)
├── .gitignore                # (sin cambios)
└── fail2ban/                 # ← nuevo
    ├── fail2ban.local
    ├── jail.local
    └── filter.d/
        ├── authelia.local
        ├── caddy-status.local
        ├── nextcloud.local      # placeholder, jail desactivado
        └── vaultwarden.local    # placeholder, jail desactivado
```

Y en los discos externos (creación):

```
/mnt/hd2t/services/fail2ban/
├── db/                       # ← se crea en este doc (DB de bans)
└── log/                      # ← se crea en este doc (log propio del daemon)
```

Crear los directorios:

```bash
# Subdirectorio del stack para configuración versionada
mkdir -p ~/homelab/seguridad/fail2ban/filter.d
chmod 0750 ~/homelab/seguridad/fail2ban
chmod 0750 ~/homelab/seguridad/fail2ban/filter.d

# Datos persistentes (DB + log) en el disco externo. /mnt/hd2t/services/fail2ban
# ya existía vacío desde docs/01-sistema/04-estructura-directorios.md.
sudo mkdir -p /mnt/hd2t/services/fail2ban/{db,log}

# La imagen crazymax/fail2ban corre como root dentro del contenedor (necesita
# CAP_NET_ADMIN para nft) y escribe la BD/logs como root. Coincide con el
# ownership por defecto del path en hd2t (root:root). No tocar:
sudo chown -R root:root /mnt/hd2t/services/fail2ban
sudo chmod 0750 /mnt/hd2t/services/fail2ban
sudo chmod 0750 /mnt/hd2t/services/fail2ban/{db,log}
```

> **Por qué `root:root` y no UID 1000**: a diferencia de Authelia (corre como `1000:1000` por imposición del `user:` del compose), `fail2ban` necesita capacidades de _kernel_ que sólo el `root` del contenedor puede ejercer. El `root` del contenedor mapea al `root` del host (no se usa _user namespace_ remap), por eso el ownership de `/mnt/hd2t/services/fail2ban/` es `root:root`. El bind-mount `/data:ro` lo lee `fail2ban` como `root` sin más.

---

## Variables de entorno

Editar `~/homelab/seguridad/.env.example` (versionado en git, sin valores reales) y añadir:

```bash
# --- Fail2ban (docs/04-seguridad/02-fail2ban.md) ----------------------------
FAIL2BAN_IMAGE_TAG=1.1.0

# Nivel de log del daemon. INFO en operación normal; subir a DEBUG sólo
# para depurar regex de filtros.
F2B_LOG_LEVEL=INFO

# Edad a la que la BD purga bans expirados (no afecta a la persistencia
# de los bans activos; sólo limpia el histórico que alimenta a 'recidive').
F2B_DB_PURGE_AGE=1d
```

Reflejar el añadido en `~/homelab/seguridad/.env`:

```bash
# Editar a mano o con sed el .env existente
sudoedit ~/homelab/seguridad/.env  # mismas variables, mismos valores
```

> **No hay secretos en estas variables**. `fail2ban` no se autentica con nadie; sus _bans_ son una operación local sobre `nftables`. Los valores de la plantilla son los correctos para el homelab.

---

## Modificación a `~/homelab/seguridad/configuration.yml` (Authelia)

`docs/04-seguridad/01-authelia.md` dejó la sección `log:` así:

```yaml
log:
  level: info
  format: json
```

Editarla para que escriba **además** un fichero accesible por `fail2ban`:

```yaml
log:
  level: info
  format: json
  # docs/04-seguridad/02-fail2ban.md — fail2ban tail-ea este fichero.
  # /config se bind-mountea a /mnt/hd2t/services/authelia/config/ en el host;
  # el contenedor de fail2ban lo monta como /var/log/authelia/authelia.log:ro.
  file_path: /config/authelia.log
  keep_stdout: true       # mantener stdout para Dozzle / `docker logs`
```

> **`keep_stdout: true` es esencial**: sin él, Authelia deja de escribir a `stdout` y los `docker logs authelia` aparecen vacíos, lo que rompe Dozzle, los _healthchecks_ que parsean stdout y la sección de troubleshooting de `docs/04-seguridad/01-authelia.md`. Con `true`, escribe a los dos sitios (cero penalización medible en una Pi 5; el log de Authelia no es de alta frecuencia).

Validar la configuración (mismo comando de `01-authelia.md`):

```bash
docker run --rm \
  -v ~/homelab/seguridad/configuration.yml:/config/configuration.yml:ro \
  authelia/authelia:4.38.16 \
  authelia validate-config --config /config/configuration.yml
# Configuration parsed and loaded successfully without errors.
```

Aplicar el cambio recargando Authelia (no requiere `down`/`up`):

```bash
docker exec authelia kill -HUP 1
# Authelia recarga; en pocos segundos /mnt/hd2t/services/authelia/config/authelia.log empieza a aparecer.
```

Confirmar que el fichero existe y crece:

```bash
ls -la /mnt/hd2t/services/authelia/config/authelia.log
sudo tail -f /mnt/hd2t/services/authelia/config/authelia.log    # Ctrl-C tras ver una línea
```

---

## `~/homelab/seguridad/fail2ban/fail2ban.local`

Defaults globales del _daemon_ (no _jails_). Contenido completo:

```ini
# ============================================================================
# Fail2ban — defaults globales del daemon (docs/04-seguridad/02-fail2ban.md)
# Sobrescribe valores del fail2ban.conf por defecto que la imagen distribuye.
# ============================================================================

[Definition]

# Nivel de log. La env var F2B_LOG_LEVEL del compose lo sobrescribe en runtime
# (la imagen crazymax/fail2ban inyecta ese valor); este es el fallback.
loglevel = INFO

# Log propio del daemon. El jail 'recidive' (jail.local) lo lee.
# Bind-mount: /mnt/hd2t/services/fail2ban/log/fail2ban.log
logtarget = /var/log/fail2ban/fail2ban.log

# Fichero de socket (ipc fail2ban-client <-> daemon). Dentro del contenedor.
socket = /var/run/fail2ban/fail2ban.sock

# Fichero PID
pidfile = /var/run/fail2ban/fail2ban.pid

# Persistencia de bans en SQLite. La sobrescribimos al disco externo
# (en lugar del default /data/db) para que el bind-mount /data sea ro.
# Bind-mount: /mnt/hd2t/services/fail2ban/db/fail2ban.sqlite3
dbfile = /var/lib/fail2ban/fail2ban.sqlite3

# Edad a la que la BD purga bans expirados. Influye en cuánto tiempo
# atrás puede 'recidive' encontrar reincidencias.
dbpurgeage = 1d
```

```bash
chmod 0644 ~/homelab/seguridad/fail2ban/fail2ban.local
```

---

## `~/homelab/seguridad/fail2ban/jail.local`

Definiciones de los _jails_ y los defaults heredados por todos. Contenido completo:

```ini
# ============================================================================
# Fail2ban — jails del homelab (docs/04-seguridad/02-fail2ban.md)
#
# Convenciones:
#   - Los logpath usan rutas dentro del contenedor (ver docker-compose.yml).
#   - Los filtros viven en /etc/fail2ban/filter.d/<filter>.local
#     (la imagen los monta desde ~/homelab/seguridad/fail2ban/filter.d/).
#   - banaction = nftables-multiport: una chain f2b-<jail> por jail.
# ============================================================================

[DEFAULT]

# Tiempo de ban inicial — escala automáticamente con bantime.increment.
bantime  = 1h
findtime = 10m
maxretry = 5

# Re-bans del mismo IP escalan: 1h -> 2h -> 4h -> ... hasta bantime.maxtime.
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1w

# Backend de lectura de logs. 'auto' usa pyinotify (preferido) y cae a polling
# si pyinotify no está disponible. La imagen trae pyinotify de fábrica.
backend = auto

# Acciones de ban: nftables nativo, coherente con el firewall del host.
# 'multiport' inserta reglas que afectan SÓLO a los puertos del jail.
# 'allports' (usado por recidive) bloquea TODO el tráfico desde la IP.
banaction         = nftables-multiport
banaction_allports = nftables-allports

# Caracteres de log: utf-8 (Authelia y Caddy emiten UTF-8 limpio).
logencoding = utf-8

# IPs ignoradas: localhost, LAN doméstica y la red de Tailscale.
# Coincide con el ignoreip del fail2ban del host (docs/01-sistema/03-seguridad-base.md).
# IMPORTANTE: ajustar 192.168.1.0/24 a la subred LAN real del operador.
ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24 100.64.0.0/10 172.20.0.0/12

# Notas:
# - 172.20.0.0/12 cubre las redes Docker bridge del homelab (br-homelab
#   está en 172.20.10.0/24, ver docs/02-docker/02-estructura-compose.md).
#   Los X-Forwarded-For que Caddy reescribe a la IP real ya se filtran por
#   los regex de los filter.d, pero conviene cubrir el caso por si algún
#   acceso no llevase el header (sondeo interno, healthcheck local).
# - NO se ignora la IP del cliente principal: si se compromete, no hay defensa.

# ============================================================================
#  JAIL: authelia
# ============================================================================
[authelia]
enabled  = true
port     = http,https
filter   = authelia
logpath  = /var/log/authelia/authelia.log
maxretry = 3
findtime = 5m
bantime  = 1h
# Authelia ya tiene 'regulation' interna (3 fallos en 2m -> ban de 5m, ver
# configuration.yml, docs/04-seguridad/01-authelia.md). Este jail es la
# segunda capa: 3 fallos en 5m banea la IP a NIVEL DE FIREWALL del host
# durante 1h. Más restrictivo y más persistente que la regulation interna.

# ============================================================================
#  JAIL: caddy-status
#  Banea IPs que generan tormentas de 4xx contra Caddy (sondeos, scrapers).
#  No banea por 401/403 individual (eso es ruido legítimo cuando un usuario
#  se equivoca al teclear una URL); banea por TASA: muchos 4xx en poco tiempo.
# ============================================================================
[caddy-status]
enabled  = true
port     = http,https
filter   = caddy-status
logpath  = /var/log/caddy/*.log
maxretry = 20
findtime = 1m
bantime  = 30m
# 20 respuestas 4xx en 1 min desde una IP -> ban 30m. Una persona navegando
# nunca llega a ese ritmo; un script enumerando paths sí.

# ============================================================================
#  JAIL: nextcloud  (PLACEHOLDER — se activará en docs/06-almacenamiento/01-nextcloud.md)
# ============================================================================
[nextcloud]
enabled  = false
port     = http,https
filter   = nextcloud
logpath  = /var/log/nextcloud/nextcloud.log
maxretry = 3
findtime = 10m
bantime  = 1h

# ============================================================================
#  JAIL: vaultwarden  (PLACEHOLDER — se activará en docs/11-productividad/01-vaultwarden.md)
# ============================================================================
[vaultwarden]
enabled  = false
port     = http,https
filter   = vaultwarden
logpath  = /var/log/vaultwarden/vaultwarden.log
maxretry = 3
findtime = 10m
bantime  = 1h

# ============================================================================
#  JAIL: recidive  (meta-jail: re-bania a IPs ya baneadas N veces)
#  Lee el log del propio fail2ban y banea durante 1 semana en TODOS los
#  puertos a quien haya sido baneado >=5 veces en las últimas 24h por
#  cualquier otro jail.
# ============================================================================
[recidive]
enabled  = true
filter   = recidive
logpath  = /var/log/fail2ban/fail2ban.log
banaction = nftables-allports
bantime  = 1w
findtime = 1d
maxretry = 5
```

```bash
chmod 0644 ~/homelab/seguridad/fail2ban/jail.local
```

---

## `~/homelab/seguridad/fail2ban/filter.d/authelia.local`

Filtro para los logs JSON de Authelia. Authelia escribe líneas como:

```json
{"level":"error","msg":"Unsuccessful 1FA authentication attempt by user 'homelab'","method":"POST","path":"/api/firstfactor","remote_ip":"192.168.1.50","stack":"...","time":"2026-04-25T12:34:56+02:00"}
```

Contenido completo:

```ini
# ============================================================================
# Filter: authelia
# Detecta intentos fallidos de 1FA / 2FA y eventos de regulation.
# Logs: JSON estructurado de Authelia 4.38 (configuration.yml: log.format=json).
# ============================================================================

[INCLUDES]
before = common.conf

[Definition]

# Authelia emite el remote_ip dentro del JSON. <HOST> casa con IPv4 e IPv6.
failregex = ^.*"remote_ip":"<HOST>".*"msg":"Unsuccessful (1FA|TOTP|Webauthn|Time-based One-Time Password|Duo) authentication attempt.*$
            ^.*"remote_ip":"<HOST>".*"msg":"Sending an email .* reason ":?"check requested before being authorized.*$
            ^.*"remote_ip":"<HOST>".*"msg":"Authentication attempt unsuccessful: user .* is banned until.*$

# Líneas a ignorar (éxitos, eventos informativos)
ignoreregex = ^.*"level":"info".*$

# Date formats que Authelia usa: ISO 8601 con offset (+02:00) o Z (UTC).
# fail2ban detecta automáticamente RFC 3339 / ISO 8601, no hace falta datepattern.

[Init]
journalmatch =
```

```bash
chmod 0644 ~/homelab/seguridad/fail2ban/filter.d/authelia.local
```

> **Validación local del regex** (probar contra una línea de ejemplo antes de desplegar):
> ```bash
> docker run --rm -i \
>   -v ~/homelab/seguridad/fail2ban/filter.d:/etc/fail2ban/filter.d:ro \
>   crazymax/fail2ban:1.1.0 \
>   fail2ban-regex - /etc/fail2ban/filter.d/authelia.local <<'EOF'
> {"level":"error","msg":"Unsuccessful 1FA authentication attempt by user 'homelab'","remote_ip":"192.168.1.50","time":"2026-04-25T12:00:00+02:00"}
> EOF
> # Salida esperada: 'Lines: 1 ... Matches: 1'
> ```

---

## `~/homelab/seguridad/fail2ban/filter.d/caddy-status.local`

Caddy escribe access logs en formato JSON, una línea por _request_, vía el _snippet_ `logging.caddy` (`docs/03-red/04-caddy.md`). Cada línea tiene la forma:

```json
{"level":"info","ts":1745580000.123,"logger":"http.log.access.log0","msg":"handled request","request":{"remote_ip":"192.168.1.50","remote_port":"54321","host":"portainer.lan","uri":"/foo","method":"GET","headers":{...}},"status":404,...}
```

El _filter_ banea por **respuesta de la familia 4xx** (excepto 401, que es el que devuelve Authelia mientras el flujo SSO completa, y 404 sobre `/`, que es lo que pasa cuando se accede a un host que no existe — falsos positivos del navegador). Contenido completo:

```ini
# ============================================================================
# Filter: caddy-status
# Banea por tormenta de 4xx contra Caddy (sondeos, scrapers, fuzzers).
# Logs: JSON access log de Caddy (docs/03-red/04-caddy.md, snippets/logging.caddy).
# ============================================================================

[INCLUDES]
before = common.conf

[Definition]

# Casamos status 4xx (400-499) excepto 401 (autenticación pendiente, ruido
# legítimo durante el flujo SSO) y 404 sobre la raíz (un cliente despistado
# tecleando una URL incorrecta no es un atacante).
#
# remote_ip viene en .request.remote_ip — JSON anidado, el regex no parsea
# JSON, sólo busca el patrón. <HOST> casa con IPv4 e IPv6.
failregex = ^.*"remote_ip":"<HOST>".*"status":4(0[02-9]|[1-9][0-9]).*$
            ^.*"remote_ip":"<HOST>".*"status":404.*"uri":"(?!/")[^"]+".*$

# Ignorar entradas de log informativas que no son requests
ignoreregex = ^.*"logger":"(?!http\.log\.access\.log).*$

[Init]
journalmatch =
```

```bash
chmod 0644 ~/homelab/seguridad/fail2ban/filter.d/caddy-status.local
```

> **Cómo se distinguen los hosts en el regex**: Caddy escribe **un fichero por _virtual host_** (`portainer.lan.log`, `pihole.lan.log`, `auth.lan.log`, …) gracias a `output file /var/log/caddy/{host}.log` del _snippet_ `logging.caddy`. El _jail_ los lee a todos con `logpath = /var/log/caddy/*.log`, así que un atacante que sondee 5 hosts distintos suma sus 4xx en el conteo del _jail_. Esto es **lo deseado**: lo que importa es la IP, no el _host_.

---

## `~/homelab/seguridad/fail2ban/filter.d/nextcloud.local`

_Placeholder_ — el _jail_ está deshabilitado hasta `docs/06-almacenamiento/01-nextcloud.md`. La regex es la canónica de la comunidad Nextcloud (busca el campo `remoteAddr` y el evento `Login failed`):

```ini
# ============================================================================
# Filter: nextcloud (placeholder — jail disabled hasta docs/06-almacenamiento/01-nextcloud.md)
# Logs: JSON de Nextcloud (logfile_path en config.php, formato json).
# ============================================================================

[Definition]

failregex = ^\{.*"remoteAddr":"<HOST>".*"message":"Login failed.*$
            ^\{.*"remoteAddr":"<HOST>".*"message":"Trusted domain error.*$
            ^\{.*"remoteAddr":"<HOST>".*"message":".*Bruteforce.*$

ignoreregex = ^\{.*"level":(0|1).*$

[Init]
journalmatch =
```

```bash
chmod 0644 ~/homelab/seguridad/fail2ban/filter.d/nextcloud.local
```

---

## `~/homelab/seguridad/fail2ban/filter.d/vaultwarden.local`

_Placeholder_ — el _jail_ está deshabilitado hasta `docs/11-productividad/01-vaultwarden.md`. Vaultwarden emite a `stderr` (log a fichero configurable vía `LOG_FILE` env) líneas como `[2026-04-25 12:34:56][warning][vaultwarden::api::identity] Username or password is incorrect. Try again. IP: 192.168.1.50. Username: foo`:

```ini
# ============================================================================
# Filter: vaultwarden (placeholder — jail disabled hasta docs/11-productividad/01-vaultwarden.md)
# Logs: log clásico de Vaultwarden (LOG_FILE=/data/vaultwarden.log, formato texto).
# ============================================================================

[Definition]

failregex = ^.*\[warning\]\[vaultwarden::api::identity\] Username or password is incorrect\..*IP:\s*<HOST>\..*$
            ^.*\[error\]\[vaultwarden::api::admin\] .* IP:\s*<HOST>\..*$

ignoreregex =

[Init]
journalmatch =
```

```bash
chmod 0644 ~/homelab/seguridad/fail2ban/filter.d/vaultwarden.local
```

---

## Modificar `~/homelab/seguridad/docker-compose.yml`

Editar el compose existente para añadir el servicio `fail2ban`. **No se toca** ni el bloque `redis` ni el bloque `authelia`. Se añade al final del bloque `services:` (antes del `networks:` final):

```yaml
  # ---------------------------------------------------------------------------
  # Fail2ban — jails para servicios HTTP (Authelia, Caddy, Nextcloud, Vaultwarden)
  # docs/04-seguridad/02-fail2ban.md
  #
  # network_mode: host — para que las reglas nft inserten en el ruleset del host.
  # NET_ADMIN, NET_RAW   — capacidades mínimas para manipular nftables.
  # ---------------------------------------------------------------------------
  fail2ban:
    image: crazymax/fail2ban:${FAIL2BAN_IMAGE_TAG}
    container_name: fail2ban
    hostname: fail2ban
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
    environment:
      TZ: ${TZ}
      F2B_LOG_LEVEL: ${F2B_LOG_LEVEL:-INFO}
      F2B_DB_PURGE_AGE: ${F2B_DB_PURGE_AGE:-1d}
    volumes:
      # Configuración versionada (read-only) — sirve a /data, que la imagen
      # symlinkea a /etc/fail2ban/.
      - ./fail2ban:/data:ro
      # Estado runtime (read-write): DB de bans + log propio.
      # 'dbfile' y 'logtarget' (en fail2ban.local) apuntan aquí.
      - /mnt/hd2t/services/fail2ban/db:/var/lib/fail2ban
      - /mnt/hd2t/services/fail2ban/log:/var/log/fail2ban
      # Logs de los servicios — read-only.
      - /mnt/hd2t/services/authelia/config:/var/log/authelia:ro
      - /mnt/hd2t/services/caddy/log:/var/log/caddy:ro
    labels:
      homelab.stack: "seguridad"
      homelab.backup: "true"      # /mnt/hd2t/services/fail2ban/db
      # Opt-out: cambios de versión pueden alterar el formato de la SQLite
      # de bans o cambiar nombres de chains nftables. Manual.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      test: ["CMD", "fail2ban-client", "ping"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    depends_on:
      authelia:
        condition: service_healthy
```

> **Por qué `depends_on: authelia: service_healthy`**: es preferible que `fail2ban` arranque **después** de Authelia para que `/var/log/authelia/authelia.log` exista cuando `pyinotify` empiece a observarlo. Si el fichero no existiera, `fail2ban` arrancaría con un _warning_ (`Unable to find a corresponding rule for the IPs you wish to ignore` o `Log file does not exist`) y el _jail_ `authelia` quedaría en estado degradado hasta el siguiente `reload`.

> **Por qué `network_mode: host` y no la red `homelab`**: explicado en **Decisiones de diseño**. `fail2ban` no habla con ningún otro contenedor por TCP; sólo manipula `nftables` y lee ficheros. La red Docker no le aporta nada y `network_mode: host` es la única vía para que las reglas afecten al firewall del host.

> **Por qué `:ro` en `/data`**: separa configuración inmutable de estado mutable, hace el _diff_ de git limpio y evita que un proceso runaway dentro del contenedor estropee los `*.local` versionados. La DB y el log van a paths rw distintos (`/var/lib/fail2ban`, `/var/log/fail2ban`).

Editar el compose:

```bash
sudoedit ~/homelab/seguridad/docker-compose.yml
# Pegar el bloque 'fail2ban' antes de 'networks:'.
# Validar:
docker compose -f ~/homelab/seguridad/docker-compose.yml config | tail -40
```

---

## Despliegue

```bash
cd ~/homelab/seguridad
docker compose --env-file ../.env --env-file .env up -d
```

O equivalente con el _Makefile_:

```bash
cd ~/homelab
make up STACK=seguridad
```

> **`up -d` re-evalúa todos los servicios del compose**: Compose detecta que sólo `fail2ban` es nuevo y deja `redis` y `authelia` intactos (no los recrea). Si Compose por alguna razón decidiera recrear Authelia, _no es problema_: las sesiones viven en Redis (que tampoco se recrea) y la cookie del navegador sigue siendo válida.

Verificar:

```bash
docker compose -f ~/homelab/seguridad/docker-compose.yml ps
# NAME       STATUS                   PORTS
# redis      Up X (healthy)
# authelia   Up X (healthy)
# fail2ban   Up X (healthy)
```

Y dentro del contenedor:

```bash
docker exec fail2ban fail2ban-client status
# Status
# |- Number of jail:      3
# `- Jail list:           authelia, caddy-status, recidive
```

```bash
docker exec fail2ban fail2ban-client status authelia
# Status for the jail: authelia
# |- Filter
# |  |- Currently failed: 0
# |  |- Total failed:     0
# |  `- File list:        /var/log/authelia/authelia.log
# `- Actions
#    |- Currently banned: 0
#    |- Total banned:     0
#    `- Banned IP list:
```

```bash
docker exec fail2ban fail2ban-client status caddy-status
# Status for the jail: caddy-status
# |- Filter
# |  |- Currently failed: 0
# |  |- Total failed:     0
# |  `- File list:        /var/log/caddy/auth.lan.log
# |                       /var/log/caddy/pihole.lan.log
# |                       /var/log/caddy/portainer.lan.log
# `- Actions
# ...
```

Confirmar que las _chains_ de `nftables` se han creado en el host:

```bash
sudo nft list ruleset | grep -E 'chain f2b-' | sort
# chain f2b-authelia { ... }
# chain f2b-caddy-status { ... }
# chain f2b-recidive { ... }
# chain f2b-sshd { ... }       <- la del host (docs/01-sistema/03-seguridad-base.md)
```

Las cuatro _chains_ existen, las tres del contenedor más la del host: confirma la coexistencia limpia.

---

## Probar el ban (Authelia)

Desde una IP **no incluida** en `ignoreip` (otro dispositivo de la LAN o, mejor, un móvil 4G), provocar 3 fallos contra el portal:

```bash
# Sustituir 192.168.1.3 por la IP de la Pi.
for i in 1 2 3 4; do
  curl -k -s -o /dev/null -w "%{http_code}\n" \
    --resolve auth.lan:443:192.168.1.3 \
    -X POST 'https://auth.lan/api/firstfactor' \
    -H 'Content-Type: application/json' \
    -d '{"username":"homelab","password":"esto-no-vale","keepMeLoggedIn":false}'
done
# 401
# 401
# 401
# 401
```

En la Pi, verificar que la IP atacante aparece en el _jail_:

```bash
docker exec fail2ban fail2ban-client status authelia
# ...
# |- Currently failed: 0      (cero porque, al banear, los conteos se purgan)
# |- Total failed:     3
# `- Actions
#    |- Currently banned: 1
#    `- Banned IP list:   <IP_ATACANTE>
```

Confirmar la _set_ de IPs en `nftables`:

```bash
sudo nft list set inet f2b-table addr-set-authelia
# table inet f2b-table {
#   set addr-set-authelia {
#     type ipv4_addr
#     elements = { <IP_ATACANTE> }
#   }
# }
```

Probar que la IP atacante **no puede alcanzar Caddy** durante el ban:

```bash
# Desde la IP atacante, mientras está baneada
curl -k --resolve auth.lan:443:192.168.1.3 https://auth.lan/ -m 5
# curl: (28) Connection timed out after 5000 milliseconds
```

Desbanear manualmente (sin esperar 1 h):

```bash
docker exec fail2ban fail2ban-client set authelia unbanip <IP_ATACANTE>
# 1
```

Y confirmar:

```bash
sudo nft list set inet f2b-table addr-set-authelia
# elements = { }
```

---

## Probar el ban (Caddy 4xx)

Desde una IP no ignorada, provocar 25 respuestas 404 en menos de 1 minuto:

```bash
for i in $(seq 1 25); do
  curl -k -s -o /dev/null --resolve portainer.lan:443:192.168.1.3 \
    "https://portainer.lan/no-existe-$i"
done
```

Verificar el ban:

```bash
docker exec fail2ban fail2ban-client status caddy-status
# Currently banned: 1
# Banned IP list:   <IP_ATACANTE>
```

> **Si en el primer test no se llega a 25**: aumentar el bucle a `seq 1 30` o reducir el ratio temporal del _jail_ con `findtime = 30s` durante el debugging. Restaurar `findtime = 1m` después.

Desbanear:

```bash
docker exec fail2ban fail2ban-client set caddy-status unbanip <IP_ATACANTE>
```

---

## Verificación final

Antes de pasar a `docs/05-monitorizacion/01-prometheus.md`:

- [ ] `docker compose -f ~/homelab/seguridad/docker-compose.yml ps` muestra `fail2ban` en `Up` y `(healthy)` junto a `authelia` y `redis`.
- [ ] `docker exec fail2ban fail2ban-client status` lista 3 _jails_ (`authelia`, `caddy-status`, `recidive`). Los _placeholder_ (`nextcloud`, `vaultwarden`) **no** aparecen porque están `enabled = false`.
- [ ] `sudo nft list ruleset | grep 'chain f2b-'` lista al menos 4 _chains_: `f2b-sshd` (host), `f2b-authelia`, `f2b-caddy-status`, `f2b-recidive`.
- [ ] `ls -la /mnt/hd2t/services/fail2ban/db/fail2ban.sqlite3` existe, propiedad `root:root`, modo `0600` (creado por el _daemon_).
- [ ] `tail /mnt/hd2t/services/fail2ban/log/fail2ban.log` muestra "Jail authelia is enabled" y "Filter authelia found".
- [ ] Test funcional Authelia: 4 logins fallidos desde IP no ignorada activan el ban. La IP aparece en `f2b-authelia` y no puede alcanzar la Pi durante `bantime`.
- [ ] Test funcional Caddy: 25 requests con 404 en <1 min activan el ban en `caddy-status`.
- [ ] Tras un `docker compose -f ~/homelab/seguridad/docker-compose.yml restart fail2ban`, la lista de IPs baneadas previas se restaura desde `/mnt/hd2t/services/fail2ban/db/fail2ban.sqlite3` (las _chains_ se reconstruyen idénticas).
- [ ] Tras un `sudo reboot`, el _stack_ vuelve `(healthy)` sin intervención manual y `fail2ban-client status` lista los 3 _jails_.
- [ ] `docker exec authelia tail -1 /config/authelia.log` devuelve una línea JSON (Authelia sigue escribiendo el fichero después del reload).
- [ ] `docker logs authelia --tail 5` también devuelve líneas (Authelia mantiene `stdout`, `keep_stdout: true`).
- [ ] `git -C ~/homelab status` muestra como **modificados**: `seguridad/docker-compose.yml`, `seguridad/.env.example`, `seguridad/configuration.yml`. Y como **nuevos**: `seguridad/fail2ban/fail2ban.local`, `seguridad/fail2ban/jail.local`, `seguridad/fail2ban/filter.d/*.local`. **No** muestra `seguridad/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add seguridad/docker-compose.yml seguridad/.env.example \
          seguridad/configuration.yml seguridad/fail2ban/
  git commit -m "feat(seguridad): add containerized fail2ban with jails for Authelia and Caddy"
  ```

---

## Backup

| Qué                                            | Dónde                                                       | Cómo                                            |
|------------------------------------------------|-------------------------------------------------------------|-------------------------------------------------|
| `fail2ban.local`, `jail.local`, `filter.d/*`   | `~/homelab/seguridad/fail2ban/`                             | git                                             |
| DB de bans persistentes                        | `/mnt/hd2t/services/fail2ban/db/fail2ban.sqlite3`           | Borgmatic (`docs/07-backups/02-borgmatic.md`)   |
| Log propio del daemon                          | `/mnt/hd2t/services/fail2ban/log/fail2ban.log`              | No (transitorio)                                |

> **Restauración**: clonar el repo, restaurar `/mnt/hd2t/services/fail2ban/db/` desde Borgmatic, `make up STACK=seguridad`. La DB restaurada vuelve a aplicar los bans activos en el momento del _snapshot_; los _bans_ caducados ya no se aplican.

> **Sobre la pérdida de la DB**: si se pierde, `fail2ban` arranca con la lista vacía. Cualquier IP atacante volverá a ser baneada en cuanto vuelva a fallar (y dado que `bantime.increment = true` con `factor = 2`, el _segundo_ ban a la misma IP es más largo, así que la "memoria" se reconstruye en 1-2 incidentes).

---

## Troubleshooting

### `fail2ban` arranca pero `fail2ban-client status` devuelve "Unable to find a corresponding rule"

El _jail_ está cargado pero el `logpath` no existe o no es legible. Diagnóstico:

```bash
docker exec fail2ban ls -la /var/log/authelia/authelia.log
docker exec fail2ban ls -la /var/log/caddy/
```

Causas habituales:

1. **Authelia no está escribiendo el log**: el cambio en `configuration.yml` no se aplicó. `docker exec authelia kill -HUP 1` y volver a comprobar.
2. **Permisos en el host**: `/mnt/hd2t/services/authelia/config/authelia.log` está creado por UID 1000 con `0600`. El `root` del contenedor `fail2ban` lo lee igualmente (capacidad `DAC_READ_SEARCH` implícita en el `root` no _user-namespaced_).
3. **Bind-mount mal escrito** en `docker-compose.yml`: comprobar que la línea `/mnt/hd2t/services/authelia/config:/var/log/authelia:ro` está literalmente así, sin _typos_.

### `fail2ban-regex` para Authelia no casa ninguna línea

```bash
docker exec fail2ban fail2ban-regex /var/log/authelia/authelia.log /etc/fail2ban/filter.d/authelia.local
# Lines: N ... Matches: 0
```

Causas:

1. **No hay líneas de error en el log todavía**: Authelia no ha registrado ningún fallo. Provocar uno (`curl` contra `/api/firstfactor` con credenciales malas) y reintentar.
2. **El formato de log de Authelia ha cambiado** entre versiones. Comprobar una línea real del log y comparar con el regex:
   ```bash
   docker exec authelia tail -1 /config/authelia.log
   ```
   Si el campo `remote_ip` apareciera con otro nombre (`source_ip`, `client_ip`), actualizar el regex en `~/homelab/seguridad/fail2ban/filter.d/authelia.local` y `docker exec fail2ban fail2ban-client reload authelia`.

### `nftables` se queja de "table 'f2b-table' is not present"

El _daemon_ no creó la tabla todavía. `fail2ban` la crea perezosamente al primer ban. Para forzar:

```bash
docker exec fail2ban fail2ban-client set authelia banip 198.51.100.99
sudo nft list table inet f2b-table
docker exec fail2ban fail2ban-client set authelia unbanip 198.51.100.99
```

### El _jail_ `recidive` no banea a una IP que ya ha sido baneada 5 veces

`recidive` lee `/var/log/fail2ban/fail2ban.log` y busca patrones tipo `WARNING [<jail>] Ban <ip>`. Si el log no se está escribiendo (por ejemplo, el bind-mount `/var/log/fail2ban` no es _writable_), `recidive` ve un fichero vacío. Comprobar:

```bash
docker exec fail2ban tail -20 /var/log/fail2ban/fail2ban.log
# Debe contener líneas tipo:
# YYYY-MM-DD HH:MM:SS,xyz fail2ban.actions [...]: WARNING [authelia] Ban 192.168.1.50
```

Si está vacío:

```bash
docker exec fail2ban ls -la /var/log/fail2ban/
# fail2ban.log debe existir con propiedad root:root y modo 0644.
```

### Tras un `apt full-upgrade` del host, las reglas `f2b-*` desaparecen

Es posible si el _kernel_ se actualizó y se reinició sin levantar bien `nftables.service`. Diagnóstico:

```bash
sudo systemctl status nftables
sudo nft list ruleset | head -20
docker restart fail2ban
sudo nft list ruleset | grep 'chain f2b-' | wc -l
```

`docker restart fail2ban` reaplica todas las reglas desde la BD. Si las reglas siguen ausentes, comprobar que `cap_add: NET_ADMIN, NET_RAW` siguen en el compose y que `network_mode: host` no haya quedado sobreescrito por algún _override_ accidental.

### Una IP del operador queda baneada por error

Pasos para desbanear y prevenir:

```bash
# Listar todos los jails y ver dónde está
for jail in authelia caddy-status recidive; do
  echo "=== $jail ==="
  docker exec fail2ban fail2ban-client status $jail | grep "Banned IP list"
done

# Desbanear en el jail correspondiente
docker exec fail2ban fail2ban-client set <jail> unbanip <IP>

# Si la IP está en 'recidive', desbanearla también ahí (es independiente)
docker exec fail2ban fail2ban-client set recidive unbanip <IP>
```

Si la IP es la del propio operador desde un dispositivo nuevo, ampliar `ignoreip` en `~/homelab/seguridad/fail2ban/jail.local` (sección `[DEFAULT]`):

```ini
ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24 100.64.0.0/10 172.20.0.0/12 <IP_NUEVA>/32
```

Y recargar:

```bash
docker exec fail2ban fail2ban-client reload
```

### Conflicto: `fail2ban` (host) y `fail2ban` (contenedor) intentan banear el mismo SSH

**No debería pasar** porque el _jail_ `[sshd]` sólo está habilitado en el del host (este documento NO añade `[sshd]` al contenedor). Si por algún error de copy-paste se duplicara:

1. Verificar que `~/homelab/seguridad/fail2ban/jail.local` **no** tiene un bloque `[sshd]` con `enabled = true`.
2. Si lo tuviera, eliminarlo y recargar:
   ```bash
   docker exec fail2ban fail2ban-client reload
   ```

### `docker exec authelia tail /config/authelia.log` muestra el fichero pero `fail2ban` no ve cambios

Posible problema de _inotify_ con bind-mounts y _filesystem_ (más probable en cifrados o cifras encriptadas, no en ext4 estándar). Workaround: cambiar `backend = auto` por `backend = polling` en `~/homelab/seguridad/fail2ban/jail.local` sección `[DEFAULT]` y recargar:

```bash
docker exec fail2ban fail2ban-client reload
```

`polling` consume un poco más de CPU (re-lee el _stat_ del fichero cada segundo) pero es independiente de _inotify_.

---

## Activar los _jails_ pendientes (Nextcloud, Vaultwarden)

Cuando llegue `docs/06-almacenamiento/01-nextcloud.md`:

1. Asegurarse de que Nextcloud está configurado con `loglevel = json` y que `logfile` apunta a `/var/www/html/data/nextcloud.log` dentro del contenedor (mapeado al host en `/mnt/hd2t/services/nextcloud/data/nextcloud.log`).
2. Añadir un bind-mount al servicio `fail2ban` en `~/homelab/seguridad/docker-compose.yml`:
   ```yaml
       - /mnt/hd2t/services/nextcloud/data:/var/log/nextcloud:ro
   ```
3. Editar `~/homelab/seguridad/fail2ban/jail.local`, sección `[nextcloud]`:
   ```ini
   enabled = true
   logpath = /var/log/nextcloud/nextcloud.log
   ```
4. Recargar:
   ```bash
   docker compose -f ~/homelab/seguridad/docker-compose.yml up -d fail2ban
   docker exec fail2ban fail2ban-client status nextcloud
   ```

Para Vaultwarden (`docs/11-productividad/01-vaultwarden.md`), mismo patrón con bind-mount `/mnt/hd2t/services/vaultwarden/data:/var/log/vaultwarden:ro` y la env var `LOG_FILE=/data/vaultwarden.log` en el compose de Vaultwarden.

> **Convención**: cada vez que se añada un servicio con _jail_, su documento de fase es responsable de (a) añadir el bind-mount aquí y (b) flippear el `enabled = false → true` y (c) ajustar el `logpath`. **No** se modifica el filtro `<servicio>.local`: ya está versionado desde este documento. Si la _release_ del servicio cambiase el formato del log, se actualiza el filtro en este mismo subdirectorio (con un _commit_ en la fase del servicio).

---

## Referencias

- `fail2ban` — Documentación oficial: <https://github.com/fail2ban/fail2ban/wiki>
- `fail2ban` — Manual: <https://github.com/fail2ban/fail2ban/blob/master/MANUAL>
- `fail2ban` — Acción `nftables`: <https://github.com/fail2ban/fail2ban/blob/master/config/action.d/nftables.conf>
- `crazymax/fail2ban` — Imagen Docker oficial mantenida: <https://github.com/crazy-max/docker-fail2ban>
- `crazymax/fail2ban` — Docker Hub: <https://hub.docker.com/r/crazymax/fail2ban>
- Authelia — Configuración de logs: <https://www.authelia.com/configuration/miscellaneous/logging/>
- Caddy — Logs estructurados: <https://caddyserver.com/docs/logging>
- Nextcloud — Logging y _bruteforce_: <https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/logging_configuration.html>
- Vaultwarden — Logging: <https://github.com/dani-garcia/vaultwarden/wiki/Logging>
- `nftables` — `man nft`: <https://man.archlinux.org/man/nft.8>
