# Borgmatic — motor de backup del homelab

## Descripción

Despliegue del **motor de copias de seguridad** definido en `docs/07-backups/01-estrategia-backup.md`. Aquí se instalan **BorgBackup** (la herramienta de bajo nivel: deduplicación, cifrado, repositorios) y **Borgmatic** (el _orquestador_ encima: un único YAML que agrupa fuentes, retención, hooks y verificaciones), se inicializan los dos repositorios de la estrategia 3-2-1 — uno **local** en `/mnt/hd2t/backups/borg/homelab/` y otro **offsite** en un proveedor remoto — y se programa la cadencia diaria/semanal/mensual con _systemd timers_ del propio host.

Este documento **implementa** el contrato escrito en `docs/07-backups/01-estrategia-backup.md`: respeta la clasificación A/B/C/D/E, el calendario `daily 03:30 / weekly domingo / monthly día 1`, la política de retención GFS (`keep_daily=14`, `keep_weekly=8`, `keep_monthly=12`, `keep_yearly=3`), el cifrado `repokey-blake2`, la custodia de la passphrase en tres lugares (Vaultwarden + gestor externo + papel) y la doble ruta "local + offsite" en cada corrida. El detalle "qué dumpea cada servicio y cómo se restaura" vive en `docs/07-backups/03-backup-docker-volumes.md` y se referencia desde aquí como _hooks_ que se irán rellenando a medida que cada servicio se despliegue.

> **Alcance**: este documento instala los paquetes `borgbackup` y `borgmatic` en el **host** (no en contenedor — ver **Decisiones de diseño → Borgmatic en host vs contenedor**), crea la configuración `/etc/borgmatic.d/config.yaml` con las fuentes y retención de la estrategia, inicializa los dos repositorios Borg, programa los _systemd timers_, configura las notificaciones a `ntfy.sh` y el _textfile collector_ para Prometheus, y deja un primer **backup real** ejecutándose esta misma noche. **No** despliega `ntfy` self-hosted (cuando llegue se documentará en su propia fase; por ahora se usa `ntfy.sh` público con un _topic_ aleatorio + token). **No** rellena hooks `before_backup` específicos de cada servicio (eso lo hace `docs/07-backups/03-backup-docker-volumes.md` y la sección **Backup** de cada doc de servicio). **No** activa réplica del repo local a MinIO (eso es `docs/06-almacenamiento/04-minio.md` + un `mc mirror` programado).

> **Recordatorio del reparto de discos** (definido en `docs/00-hardware/03-preparacion-discos.md` y `docs/01-sistema/04-estructura-directorios.md`):
> - `/mnt/hd2t/backups/borg/homelab/` — repo Borg local. Permisos `0700 root:root`.
> - `/mnt/hd2t/backups/dumps/` — _scratch_ para dumps SQL pre-backup. Permisos `0700 root:root`. Borg lee de aquí cada noche.
> - `/mnt/hd2t/backups/exports/` — exportaciones manuales (no las toca Borgmatic; uso interactivo del operador).

> **Recordatorio de red**: el homelab no expone puertos al exterior. La copia offsite es siempre **iniciada desde la Pi** (modelo `push`), sobre **SSH saliente** al proveedor (rsync.net, Hetzner Storage Box, segunda Pi tras Tailscale). La conectividad saliente se validó en `docs/07-backups/01-estrategia-backup.md`.

---

## Requisitos previos

- `docs/00-hardware/03-preparacion-discos.md` y `docs/01-sistema/04-estructura-directorios.md` completados: existen `/mnt/hd2t/backups/{borg,dumps,exports}/` con ownership `root:root` y modo `0700`. Verificar:

  ```bash
  sudo ls -la /mnt/hd2t/backups
  # drwx------ 5 root root 4096 ... .
  # drwx------ 7 root root 4096 ... ..
  # drwx------ 3 root root 4096 ... borg
  # drwx------ 2 root root 4096 ... dumps
  # drwx------ 2 root root 4096 ... exports
  sudo ls -la /mnt/hd2t/backups/borg
  # drwx------ 2 root root 4096 ... homelab
  ```

- `docs/01-sistema/02-configuracion-inicial.md` completado: hora correcta vía NTP. Esencial — los _archives_ se nombran y retienen por _timestamp_.

  ```bash
  timedatectl status | grep -E '(Local time|System clock synchronized|NTP service)'
  # System clock synchronized: yes
  # NTP service: active
  ```

- `docs/01-sistema/03-seguridad-base.md` completado: usuario `homelab` con clave SSH, `sudo` sin password para `homelab`, firewall `nftables` activo en _input drop_. Borgmatic corre como `root` desde un _systemd timer_ del host; la regla "input drop" no afecta a tráfico **saliente**, que es lo único que el motor de backup necesita.

- `docs/01-sistema/04-estructura-directorios.md` completado: existen los servicios bajo `/mnt/hd2t/services/` que ya estén desplegados en el momento de leer este doc. Borgmatic respaldará los presentes; los futuros se irán añadiendo a `source_directories:` desde la sección **Backup** de cada doc de servicio.

- `docs/02-docker/02-estructura-compose.md` completado: existe `~/homelab/` (repo git con los `docker-compose.yml`, `.env.example`, `Makefile`). Es **una de las fuentes** que respaldaremos.

- `docs/07-backups/01-estrategia-backup.md` completado y leído. Este documento da por hechas:

  - la clasificación A/B/C/D/E,
  - la lista de `source_directories` y `exclude_patterns`,
  - la política de retención,
  - el calendario,
  - la elección de `repokey-blake2` y la custodia de la passphrase en tres lugares.

  Si alguna de esas decisiones no está clara, parar aquí y releer la estrategia.

- Conectividad saliente (verificación, sin credenciales todavía):

  ```bash
  # SSH saliente al puerto 22 (destino tipo rsync.net / Hetzner / segunda Pi)
  nc -zv rsync.net 22 2>&1 | head -1
  # Connection to rsync.net (...) 22 port [tcp/ssh] succeeded!

  # Si el offsite va a ser una segunda Pi en Tailscale, comprobar la conectividad por la tailnet:
  # tailscale ping <hostname-de-la-segunda-pi>
  ```

- El operador ha **decidido o aceptado provisionalmente** un destino offsite del _shortlist_ (ver `docs/07-backups/01-estrategia-backup.md` → **Destino offsite**). Si aún no se ha decidido, el doc se ejecuta hasta el repo local y la sección "Repositorio offsite" se aplaza con `# TODO offsite` en el `config.yaml`. **Pero no se da por terminado el doc** hasta que el offsite esté operativo: backup local sin offsite **no cumple** 3-2-1.

---

## Decisiones de diseño

### Borgmatic en host vs contenedor

| Modo                                         | Veredicto |
|----------------------------------------------|-----------|
| **Borgmatic en el host (`apt install borgmatic`)** ✅ | **Elección del homelab**. Razones más abajo.                                                                                                                                                                                                                                                                                  |
| Borgmatic dentro de un contenedor (`ghcr.io/borgmatic-collective/borgmatic`) | Existe la imagen y funciona. Pero exige montar `/var/run/docker.sock` dentro del contenedor de backup para que sus _hooks_ `pg_dump` puedan hacer `docker exec` contra Postgres/MariaDB; el socket de Docker **es** _root equivalente_, así que un Borgmatic comprometido es _root_ en la Pi. Además rompe la simetría: si Docker se cae, el backup no se ejecuta — precisamente el escenario donde más hace falta. |

Otras razones para mantenerlo en el host:

- **Disaster recovery**: en `docs/13-operaciones/02-disaster-recovery.md`, la primera tarea tras restaurar el OS es restaurar desde el repo offsite. Tener `borg` instalado en el host como paquete del sistema permite hacer `borg extract ...` desde una Pi nueva sin haber arrancado todavía Docker. Es una propiedad estructural del backup: **no debe depender de la pila que respalda**.
- **systemd timers nativos** integrados con `journalctl`: cualquier fallo se ve en `journalctl -u borgmatic.service` sin tener que dragar logs de contenedor.
- **`pg_dump` versionado por Debian**: la imagen oficial de Postgres en Docker es `16.x`. La versión de `pg_dump` que viene con `borgmatic` empaquetado en Debian 12 (Bookworm) es `15.x`. Eso causaría incompatibilidad. La solución del homelab es **no usar `pg_dump` del host**: los hooks de Borgmatic ejecutarán `docker exec <postgres-container> pg_dump` para que la versión coincida exactamente con la del servidor. Detalle en `docs/07-backups/03-backup-docker-volumes.md`.
- **Permisos**: Borgmatic debe leer todo `/mnt/hd2t/services/*` (UIDs `33`, `100`, `1000`, `999`, …). Como `root` en el host, lo lee directamente. En contenedor habría que montar todo como `:ro` y bypasear DAC vía `cap_add: [DAC_READ_SEARCH]` — más complejo y menos auditable.

> **Concesión**: este es el **segundo** servicio del homelab que vive fuera de Docker, junto a `tailscaled` (`docs/03-red/05-tailscale.md`) y `nftables` / `unattended-upgrades` (`docs/01-sistema/03-seguridad-base.md`). La regla "todo en Docker" admite excepciones cuando el servicio **es la red de seguridad de Docker mismo** o cuando depende de capacidades del kernel/host que no se pueden encapsular limpiamente. Borgmatic cae en la primera categoría.

### Paquetes y versiones

| Componente                             | Origen                                  | Versión mínima                                  |
|----------------------------------------|-----------------------------------------|-------------------------------------------------|
| `borgbackup`                           | repos de Raspberry Pi OS (Bookworm/Trixie) | ≥ 1.2.4 (formato del repo y `--verify-data` estables) |
| `borgmatic`                            | repos de Raspberry Pi OS                | ≥ 1.7.7 (formato YAML _flat_ sin secciones `location:`/`storage:`) |
| `python3-llfuse`                       | repos                                   | sólo si se quiere `borg mount` (montaje FUSE de archives) |
| `pwgen`                                | repos                                   | para generar passphrase y tokens                |
| `curl`                                 | repos (ya presente)                     | para hooks de notificación a `ntfy`             |
| `jq`                                   | repos                                   | para parsear `borg info --json` en hooks        |

Si el `apt` empaquetado se queda atrás (Borgmatic 1.8 trae cambios en _hooks_ y `borgmatic borg ...` que algunos usuarios prefieren), la alternativa es `pipx install borgmatic` para el operador `root` — documentado al final como _opción avanzada_. Por defecto el homelab usa `apt`: reproducible vía `unattended-upgrades`, parches de seguridad de Debian, integración con `apt list --upgradable`.

### Layout en disco

```
/etc/borgmatic.d/
├── config.yaml                  # configuración principal (versionada como plantilla)
├── secrets.env                  # BORG_PASSPHRASE, NTFY_TOKEN, … (0600 root:root, NO versionado)
└── hooks/                       # scripts auxiliares para before/after/on_error
    ├── notify.sh
    └── prometheus-textfile.sh

/etc/systemd/system/
├── borgmatic.service            # ejecuta `borgmatic` con la corrida diaria
├── borgmatic.timer              # OnCalendar=*-*-* 03:30:00
├── borgmatic-check.service      # `borgmatic check --only data`  (verify-data semanal)
├── borgmatic-check.timer        # OnCalendar=Sun *-*-* 04:30:00
├── borgmatic-verify.service     # verify-data sobre repo offsite (mensual)
└── borgmatic-verify.timer       # OnCalendar=*-*-01 05:00:00

/root/.ssh/
├── borg_offsite                 # clave Ed25519 para el offsite (sin passphrase, 0600 root:root)
├── borg_offsite.pub
└── known_hosts                  # huella pinneada del proveedor offsite

/var/lib/node_exporter/textfile_collector/
└── borgmatic.prom               # métricas para node_exporter (escrito por after_backup)

/mnt/hd2t/backups/
├── borg/homelab/                # repo Borg local (creado por `borg init`)
├── dumps/                       # dumps SQL temporales (escritos por before_backup)
└── exports/                     # exports manuales (no toca Borgmatic)

~/homelab/backups/borgmatic/     # plantillas versionadas (del usuario homelab)
├── config.yaml                  # = /etc/borgmatic.d/config.yaml
├── secrets.env.example          # plantilla pública sin valores reales
├── hooks/
│   ├── notify.sh
│   └── prometheus-textfile.sh
├── systemd/
│   ├── borgmatic.service
│   ├── borgmatic.timer
│   ├── borgmatic-check.service
│   ├── borgmatic-check.timer
│   ├── borgmatic-verify.service
│   └── borgmatic-verify.timer
├── install.sh                   # copia plantillas → /etc/, recarga systemd
└── README.md                    # punteros a este doc
```

> **Por qué duplicar entre `~/homelab/backups/borgmatic/` y `/etc/borgmatic.d/`**: la regla del homelab es "configuración versionable en `~/homelab/`, ejecución en su sitio canónico". Borgmatic se lee de `/etc/borgmatic.d/`, pero la _fuente de verdad_ vive en `~/homelab/backups/borgmatic/` (git). El script `install.sh` materializa los ficheros en `/etc/` y recarga systemd. El `secrets.env` real **nunca** entra en git: solo su _example_.

### Repositorio local — sí en `hd2t`, advertencia incluida

El repo local vive en el **mismo disco** que los datos respaldados (`/mnt/hd2t/`). Esto **no** cumple "2 medios distintos" del 3-2-1 (advertencia ya cubierta en `docs/07-backups/01-estrategia-backup.md`). Su función es **complementaria**: restauración rápida tras un borrado accidental, retención más larga sin coste de transferencia, y _staging_ del que se nutre la subida offsite. La copia offsite es la que cumple el 3-2-1 real.

### Repositorio offsite — destino y protocolo

Este documento configura el offsite con **SSH + `borg serve`** (proveedor tipo rsync.net o segunda Pi en Tailscale) como camino primario. Razones:

| Camino                        | Pros                                                                                                  | Contras                                                                              |
|-------------------------------|-------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------|
| **SSH + `borg serve`** ✅      | Borg habla nativo (latencia óptima, _append-only_ trivial, _quotas_ del lado servidor); SSH pinneable. | Requiere proveedor que ofrezca cuenta Borg (rsync.net) o servidor SSH propio (Pi-2). |
| Filesystem remoto (SFTP/sshfs montado localmente) | Funciona con cualquier SFTP server (Hetzner Storage Box).                                              | Sin _append-only_ del lado servidor; _latencia_ alta (cada chunk = round-trip).      |
| HTTPS/S3 (B2, R2, Wasabi)     | Más barato.                                                                                            | Borg **no habla S3 nativo**; requiere capa intermedia (`rclone serve sftp` localmente o repo Borg sobre `borg-store`). Más piezas, más fallos posibles. |

Si el operador eligió **rsync.net Borg account**, los pasos para inicializar el offsite están en la sección **Inicialización del repositorio offsite — rsync.net**.

Si el operador eligió **Hetzner Storage Box** (SFTP, sin `borg serve` upstream), ver la sección equivalente para Hetzner.

Si el operador eligió **segunda Pi en otra ubicación tras Tailscale**, ver la sección "Segunda Pi como destino offsite".

Si el operador eligió **B2/S3 vía rclone+rclone serve sftp**, la receta queda fuera del alcance de este doc principal y se documentará como anexo en `docs/06-almacenamiento/04-minio.md` (réplica del repo local) — el 3-2-1 puede satisfacerse con MinIO local replicado a B2 sin que Borg hable S3.

### Cifrado y custodia de la passphrase

Decidido en `docs/07-backups/01-estrategia-backup.md`. Resumen aplicable:

- Modo: `repokey-blake2` (clave AES-256 derivada vía PBKDF2; HMAC con BLAKE2b; clave de cifrado **dentro** del repo).
- Passphrase: ≥ 30 caracteres, generada con `pwgen -s 30 1`. Se exporta a Borgmatic vía `BORG_PASSPHRASE` desde `/etc/borgmatic.d/secrets.env` (`0600 root:root`).
- Custodia: triple — Vaultwarden (cuando exista), gestor externo del operador, papel impreso en sobre cerrado.

Aquí se **genera** la passphrase, se inicializa el repo, y se exige al operador anotar la passphrase en al menos **dos** de los tres lugares **antes de salir del documento**.

### Hooks de bases de datos vía `docker exec`

Los hooks `before_backup` ejecutan `docker exec <contenedor-bd> pg_dump | gzip > /mnt/hd2t/backups/dumps/...` o equivalente para MariaDB/SQLite. Detalles por servicio en `docs/07-backups/03-backup-docker-volumes.md`. Aquí se cablea:

- el _hook_ central que invoca a un script `~/homelab/backups/borgmatic/hooks/dump-databases.sh`,
- la convención de nombres `<servicio>-YYYY-MM-DD.sql.gz`,
- la limpieza de dumps tras N días (post-backup).

### `systemd` timers vs cron

| Mecanismo                       | Veredicto |
|---------------------------------|-----------|
| **systemd timers** ✅            | Integrados con `journalctl`, soportan `Persistent=true` (recuperan ejecuciones perdidas tras un apagón), `RandomizedDelaySec=` (jitter), `OnCalendar=` (sintaxis legible), `Wants=`/`Requires=`. **Elección del homelab**. |
| `cron`                          | Funciona pero `/etc/cron.daily/borgmatic` no admite jitter sin _wrapper_, los logs van a `mail` por defecto, la recuperación de ejecuciones perdidas requiere `anacron`. Más fricción.                  |
| `borgmatic --daemon`            | Borgmatic 1.9+ tiene modo demonio; sigue siendo experimental.                                                                                                                                          |

### Notificaciones — `ntfy.sh` con tópico secreto

Decisión transitoria: usar el servicio **público** `ntfy.sh` con un _topic_ aleatorio (32 chars, indistinguible de URL legítima) + token de acceso. Cuando se despliegue ntfy self-hosted (fuera del alcance de este doc), bastará con cambiar el _endpoint_ en `secrets.env`.

| Hook              | Tipo                  | Prioridad |
|-------------------|-----------------------|-----------|
| `on_error`        | mensaje a ntfy + email opcional | `urgent` (5) |
| `after_backup`    | mensaje a ntfy con duración y tamaño | `low` (2) |
| `before_backup`   | _no_ notifica (ruido)        | —     |

Uptime Kuma (`docs/05-monitorizacion/05-uptime-kuma.md`) vigila la **ausencia** de la notificación de éxito mediante un monitor _push_ con TTL 26 h. Detalles en su propia doc.

### Métricas Prometheus — _textfile collector_

Borgmatic 1.9 trae integraciones con `prometheus_pushgateway`, pero el homelab no despliega un _pushgateway_ (un servicio más para mantener). En su lugar, un hook `after_backup` escribe `/var/lib/node_exporter/textfile_collector/borgmatic.prom` con cuatro métricas:

```
# HELP borg_last_run_timestamp_seconds Epoch de la última corrida exitosa
# TYPE borg_last_run_timestamp_seconds gauge
borg_last_run_timestamp_seconds 1714137000
# HELP borg_last_run_status 0=ok 1=error
# TYPE borg_last_run_status gauge
borg_last_run_status 0
# HELP borg_repo_size_bytes Tamaño del repo
# TYPE borg_repo_size_bytes gauge
borg_repo_size_bytes{repo="local"} 53710274560
borg_repo_size_bytes{repo="offsite"} 51234567890
# HELP borg_archive_count Número de archives en el repo
# TYPE borg_archive_count gauge
borg_archive_count{repo="local"} 36
borg_archive_count{repo="offsite"} 36
```

`node_exporter` (`docs/05-monitorizacion/03-node-exporter.md`) ya está configurado con `--collector.textfile.directory=/var/lib/node_exporter/textfile_collector`; las métricas aparecen automáticamente en Prometheus sin recargar nada. Las _alerting rules_ ("backup no se ha ejecutado en 26 h", "backup ha fallado") se documentan en `docs/05-monitorizacion/01-prometheus.md`.

### Versionado de la configuración

| Pieza                                              | Versionado | Notas                                                                          |
|----------------------------------------------------|------------|--------------------------------------------------------------------------------|
| `~/homelab/backups/borgmatic/config.yaml`          | ✅ git     | Plantilla. **Sin** valores secretos.                                            |
| `~/homelab/backups/borgmatic/secrets.env.example`  | ✅ git     | Plantilla pública sin valores.                                                  |
| `~/homelab/backups/borgmatic/secrets.env`          | ❌ git (`.gitignore`) | Solo en la Pi. Mode `0600 root:root`.                                  |
| `~/homelab/backups/borgmatic/hooks/*.sh`           | ✅ git     | Scripts ejecutables, sin secretos en línea (los leen del entorno).              |
| `~/homelab/backups/borgmatic/systemd/*`            | ✅ git     | Unit files. Inertes hasta que `install.sh` los enlace a `/etc/systemd/system/`.|
| `~/homelab/backups/borgmatic/install.sh`           | ✅ git     | Script idempotente que aplica la configuración.                                 |
| `/root/.ssh/borg_offsite`                          | ❌ jamás   | Clave privada. Custodia papel + Vaultwarden.                                    |

`/etc/borgmatic.d/config.yaml` y los _unit files_ en `/etc/systemd/system/` son **copias** materializadas por `install.sh`. Si se editan a mano, hay que portar el cambio a `~/homelab/backups/borgmatic/` y volver a ejecutar `install.sh` (idempotente). Como salvaguarda, `install.sh` rechaza correr si detecta divergencia entre `/etc/` y `~/homelab/`.

---

## Estructura del _stack_ tras este documento

```
~/homelab/backups/
├── borgmatic/
│   ├── config.yaml
│   ├── secrets.env.example
│   ├── hooks/
│   │   ├── dump-databases.sh
│   │   ├── notify.sh
│   │   └── prometheus-textfile.sh
│   ├── systemd/
│   │   ├── borgmatic.service
│   │   ├── borgmatic.timer
│   │   ├── borgmatic-check.service
│   │   ├── borgmatic-check.timer
│   │   ├── borgmatic-verify.service
│   │   └── borgmatic-verify.timer
│   ├── install.sh
│   └── README.md
└── .gitignore                   # ignora secrets.env si alguien lo crea aquí por error
```

Crear el árbol:

```bash
mkdir -p ~/homelab/backups/borgmatic/{hooks,systemd}
cd ~/homelab/backups/borgmatic
touch config.yaml secrets.env.example install.sh README.md
touch hooks/{dump-databases.sh,notify.sh,prometheus-textfile.sh}
touch systemd/borgmatic{,-check,-verify}.{service,timer}
chmod +x hooks/*.sh install.sh
```

Crear el `.gitignore` específico:

```bash
cat > ~/homelab/backups/.gitignore <<'EOF'
# Cualquier secrets.env que aparezca aquí por error
borgmatic/secrets.env
borgmatic/secrets.env.local
EOF
```

> El `.gitignore` global de `~/homelab/` (`docs/02-docker/02-estructura-compose.md`) ya bloquea `**/.env` con la excepción `**/.env.example`; este `.gitignore` adicional es para `secrets.env` (sin punto inicial), que no encaja en aquellos patrones.

---

## Instalación de los paquetes

```bash
# Actualizar índices y aplicar parches pendientes antes de tocar nada
sudo apt update
sudo apt upgrade -y

# Borgbackup, Borgmatic y utilidades
sudo apt install -y borgbackup borgmatic pwgen jq curl openssh-client
```

Verificar versiones:

```bash
borg --version
# borg 1.2.4
borgmatic --version
# 1.7.7
python3 -c 'import borgmatic; print(borgmatic.__file__)'
# /usr/lib/python3/dist-packages/borgmatic/__init__.py
```

> **Si `borgmatic` < 1.7**: el formato YAML _flat_ que usa este doc no es compatible. Salir, instalar vía `pipx`:
>
> ```bash
> sudo apt install pipx
> sudo pipx ensurepath
> sudo pipx install borgmatic
> # /usr/local/bin/borgmatic con la versión más reciente.
> ```
>
> El resto del documento (paths `/etc/borgmatic.d/`, _systemd units_, hooks) sigue siendo idéntico — `pipx` o `apt` solo cambian dónde está el binario.

> **Si `borg` < 1.2**: improbable en una Raspberry Pi OS reciente. Salir e instalar la _release_ binaria oficial desde <https://github.com/borgbackup/borg/releases> (binario estático, no necesita Python). En ese caso documentar la actualización en el _journal_ del operador y avisar de que `unattended-upgrades` no la actualizará (es un fichero suelto, no un paquete .deb).

---

## Custodia de la passphrase y secretos

### Generar la passphrase y los tokens

```bash
sudo install -d -m 0700 -o root -g root /etc/borgmatic.d

# Passphrase del repo Borg (compartida entre repo local y offsite)
borg_pass=$(pwgen -s 40 1)
echo "Passphrase Borg: $borg_pass"

# Token de acceso para ntfy.sh (se renombra el topic con un sufijo aleatorio)
ntfy_topic="homelab-$(pwgen -s 24 1 | tr 'A-Z' 'a-z')"
ntfy_token=$(pwgen -s 32 1)
echo "ntfy topic:  $ntfy_topic"
echo "ntfy token:  $ntfy_token"

# Escribir secrets.env (atomicamente)
sudo tee /etc/borgmatic.d/secrets.env >/dev/null <<EOF
# /etc/borgmatic.d/secrets.env
# 0600 root:root  —  NUNCA versionar ni copiar fuera de la Pi sin cifrar
#
# Pasarela de Borgmatic: este fichero se 'source'-ea desde el systemd unit
# ANTES de invocar 'borgmatic'. Las variables BORG_* las lee borg-cli.

BORG_PASSPHRASE='$borg_pass'

# Cache y configuración por-ejecución (root)
BORG_BASE_DIR=/var/lib/borg
BORG_CACHE_DIR=/var/lib/borg/cache
BORG_CONFIG_DIR=/var/lib/borg/config

# ntfy.sh — notificaciones
NTFY_URL=https://ntfy.sh/$ntfy_topic
NTFY_TOKEN=$ntfy_token

# Repos — los rellena la sección 'Inicialización' de docs/07-backups/02-borgmatic.md
BORG_REPO_LOCAL=/mnt/hd2t/backups/borg/homelab
# BORG_REPO_OFFSITE=ssh://USER@HOST/./repos/homelab
EOF

sudo chown root:root /etc/borgmatic.d/secrets.env
sudo chmod 0600 /etc/borgmatic.d/secrets.env

# Crear el directorio base de Borg
sudo install -d -m 0700 -o root -g root /var/lib/borg

# Limpiar variables locales para que no queden en el history
unset borg_pass ntfy_topic ntfy_token
```

Ahora **antes de seguir**, anotar la `BORG_PASSPHRASE` y el `NTFY_TOKEN` en al menos **dos** lugares del plan de custodia (`docs/07-backups/01-estrategia-backup.md` → **Custodia de la passphrase**):

1. **Vaultwarden** si ya está vivo (probablemente no — Vaultwarden está en Fase 11). En su lugar:
2. **Gestor externo del operador** (Bitwarden cloud, 1Password, KeePassXC en otra máquina). Crear una nota "Homelab — Borg passphrase" con `BORG_PASSPHRASE`, `NTFY_TOKEN` y la fecha.
3. **Papel impreso** en sobre cerrado, fecha + passphrase + topic ntfy + URL del repo offsite cuando se decida. Guardar lejos de la Pi.

> **Aviso crítico**: si la única copia de la passphrase es `/etc/borgmatic.d/secrets.env` y la Pi se incendia, el repo offsite se vuelve un ladrillo cifrado. La triple custodia **no es opcional**.

### Plantilla pública del `secrets.env.example`

Versionar la plantilla en `~/homelab/backups/borgmatic/secrets.env.example` (sin valores reales):

```bash
cat > ~/homelab/backups/borgmatic/secrets.env.example <<'EOF'
# /etc/borgmatic.d/secrets.env
# 0600 root:root — NUNCA versionar ni copiar fuera de la Pi sin cifrar
#
# Plantilla. Generar valores reales con:
#   pwgen -s 40 1     # BORG_PASSPHRASE (>= 30 chars)
#   pwgen -s 24 1     # sufijo del topic ntfy
#   pwgen -s 32 1     # token de acceso de ntfy

BORG_PASSPHRASE=

BORG_BASE_DIR=/var/lib/borg
BORG_CACHE_DIR=/var/lib/borg/cache
BORG_CONFIG_DIR=/var/lib/borg/config

NTFY_URL=https://ntfy.sh/homelab-CHANGE_ME
NTFY_TOKEN=

BORG_REPO_LOCAL=/mnt/hd2t/backups/borg/homelab
BORG_REPO_OFFSITE=
EOF
```

---

## Inicialización de los repositorios

### Repositorio local

```bash
# Cargar las variables (BORG_PASSPHRASE, BORG_BASE_DIR, BORG_REPO_LOCAL, …)
sudo bash -c 'set -a && . /etc/borgmatic.d/secrets.env && set +a && \
  borg init --encryption=repokey-blake2 "$BORG_REPO_LOCAL"'

# Verificar
sudo bash -c 'set -a && . /etc/borgmatic.d/secrets.env && set +a && \
  borg info "$BORG_REPO_LOCAL"'
# Repository ID: ...
# Encrypted: Yes (repokey BLAKE2b)
# Cache: ...
# Number of archives: 0
```

> **Si `borg init` falla con "Repository already exists"**: la rama `/mnt/hd2t/backups/borg/homelab/` venía con archivos antiguos. Verificar `ls -la /mnt/hd2t/backups/borg/homelab/`. Si está vacío salvo `lock.exclusive` o `lock.roster`, son _locks_ huérfanos: `sudo rm /mnt/hd2t/backups/borg/homelab/lock.*` y reintentar.

> **Si `borg init` falla con "Permission denied"**: comprobar `stat /mnt/hd2t/backups/borg/homelab` — debe ser `0700 root:root`. El usuario `root` que ejecuta debería poder, pero sudo + variable expansion a veces baila.

> **Sobre `repokey` vs `keyfile-blake2`**: ya argumentado en `docs/07-backups/01-estrategia-backup.md`. El homelab usa `repokey-blake2` para que el repo sea autocontenido — basta con la passphrase para abrirlo desde cualquier máquina, sin necesidad de un fichero clave externo.

### Repositorio offsite — rsync.net (Borg account)

Si el operador eligió **rsync.net Borg account**:

1. Comprar la cuenta en <https://www.rsync.net/products/borg.html> (50 GB ≈ 1.5 €/mes; precio actual en su web).
2. rsync.net asignará `<usuario>@<hostname>.rsync.net` (ej. `12345@ch-s022.rsync.net`).
3. Generar una clave Ed25519 dedicada a backups, sin passphrase (la corrida es no interactiva):

   ```bash
   sudo install -d -m 0700 -o root -g root /root/.ssh

   # ssh-keygen -t ed25519 -N '' -C 'borg-offsite' -f /root/.ssh/borg_offsite
   sudo ssh-keygen -t ed25519 -N '' -C "borg@$(hostname)" -f /root/.ssh/borg_offsite

   # Mostrar la pública para subirla a rsync.net
   sudo cat /root/.ssh/borg_offsite.pub
   ```

4. Subir la pública a rsync.net (panel web → "Authorized keys") **sin** las opciones `command=` ni `forced-commands` por ahora; activar `from="<IP-pública-de-la-Pi>"` solo si la IP es estática.

5. Pinear la huella SSH del servidor:

   ```bash
   sudo bash -c '
     ssh-keyscan -t ed25519,rsa CH-S022.RSYNC.NET 2>/dev/null \
       | tee -a /root/.ssh/known_hosts >/dev/null
   '
   # Reemplazar CH-S022.RSYNC.NET por el hostname real asignado.
   sudo cat /root/.ssh/known_hosts
   ```

   Comparar la huella mostrada con la que rsync.net publica en su _portal_ / _welcome email_ (`SHA256:...`). Si coincide, OK. Si no, **no proceder**: alguien está interceptando.

6. Probar la conexión SSH:

   ```bash
   sudo ssh -i /root/.ssh/borg_offsite -o StrictHostKeyChecking=yes \
     12345@ch-s022.rsync.net 'borg --version'
   # borg 1.2.x   ← versión que rsync.net mantiene del lado servidor
   ```

7. Configurar el `BORG_REPO_OFFSITE` en `/etc/borgmatic.d/secrets.env`:

   ```bash
   sudo sed -i 's|^# BORG_REPO_OFFSITE=.*|BORG_REPO_OFFSITE=ssh://12345@ch-s022.rsync.net/./repos/homelab|' \
     /etc/borgmatic.d/secrets.env
   sudo grep '^BORG_REPO_OFFSITE' /etc/borgmatic.d/secrets.env
   ```

   `./repos/homelab` (con `./` después del host) es la sintaxis Borg para "ruta relativa al `$HOME` del usuario remoto". rsync.net da una `$HOME` independiente por cuenta.

8. Inicializar el repo offsite con la **misma** passphrase que el local (no son repos relacionados criptográficamente, pero compartir passphrase simplifica la operación: una sola entrada en el plan de custodia):

   ```bash
   sudo bash -c '
     set -a && . /etc/borgmatic.d/secrets.env && set +a
     export BORG_RSH="ssh -i /root/.ssh/borg_offsite -o StrictHostKeyChecking=yes"
     borg init --encryption=repokey-blake2 "$BORG_REPO_OFFSITE"
   '

   sudo bash -c '
     set -a && . /etc/borgmatic.d/secrets.env && set +a
     export BORG_RSH="ssh -i /root/.ssh/borg_offsite -o StrictHostKeyChecking=yes"
     borg info "$BORG_REPO_OFFSITE"
   '
   # Repository ID: ...
   # Encrypted: Yes (repokey BLAKE2b)
   # Number of archives: 0
   ```

   `BORG_RSH` indica a Borg qué comando SSH usar (con la clave correcta). En el `config.yaml` lo declararemos vía `ssh_command:` para que Borgmatic lo aplique automáticamente.

### Repositorio offsite — Hetzner Storage Box (SFTP, sin `borg serve`)

Si el operador eligió Hetzner Storage Box, los pasos son **casi idénticos** a rsync.net excepto:

- En el panel de Hetzner, activar **SSH access** (por defecto sólo SFTP). Una vez activo, el servidor admite `borg` ejecutándose del lado servidor.
- Si se prefiere SFTP puro (sin SSH), montar el Storage Box con `sshfs` y apuntar `BORG_REPO_OFFSITE` a la ruta local:

  ```bash
  sudo apt install -y sshfs
  sudo mkdir -p /mnt/offsite
  sudo sshfs -o IdentityFile=/root/.ssh/borg_offsite,allow_other \
    u123456@u123456.your-storagebox.de:/ /mnt/offsite
  ```

  Y `BORG_REPO_OFFSITE=/mnt/offsite/borg/homelab`. Con esta variante Borg corre **client-side** (todos los chunks viajan por la red sin _server-side dedup_), aceptable pero más lento. Documentar la decisión en `~/homelab/docs/journal/`.

### Repositorio offsite — segunda Pi en otra ubicación tras Tailscale

Si el operador eligió una segunda Pi (`pi-offsite`) accesible vía Tailscale:

1. Instalar Borg en la segunda Pi (`apt install borgbackup`) y crear un usuario `borg` con SSH habilitado.
2. Forzar `command="borg serve --append-only --restrict-to-path /home/borg/repos"` en `~borg/.ssh/authorized_keys` (modo `append-only` server-side: Borg cliente puede crear archives pero no borrarlos hasta que el operador haga `ssh borg@pi-offsite borg serve --umask 077 ...`).
3. En la Pi origen, generar la clave Ed25519 (paso 3 de rsync.net) y copiar la pública a `pi-offsite:~borg/.ssh/authorized_keys`.
4. `BORG_REPO_OFFSITE=ssh://borg@pi-offsite/./repos/homelab` (Tailscale resuelve `pi-offsite` por MagicDNS).

> **`--append-only` del lado servidor**: protege contra "alguien comprometido en la Pi origen ejecuta `borg delete` y borra todos los archives offsite". Con `--append-only`, los `delete` quedan en una _transaction log_ que el operador audita y aplica manualmente. Se documenta como _hardening_ recomendado para el offsite — local no lo activamos porque la conveniencia (prune automático nocturno) supera al riesgo.

---

## Configuración de Borgmatic — `~/homelab/backups/borgmatic/config.yaml`

Crear la plantilla versionada. **Comentar bloques de servicios que aún no estén desplegados** — cada doc de servicio futuro descomentará su línea cuando llegue su fase.

```bash
cat > ~/homelab/backups/borgmatic/config.yaml <<'EOF'
# Borgmatic — configuración del homelab
#
# Ubicación canónica: /etc/borgmatic.d/config.yaml (copiada por install.sh)
# Fuente de verdad : ~/homelab/backups/borgmatic/config.yaml
# Estrategia        : docs/07-backups/01-estrategia-backup.md
# Implementación    : docs/07-backups/02-borgmatic.md (este doc)
#
# Formato Borgmatic 'flat' (sin secciones location:/storage:/retention:/consistency:).
# Requiere borgmatic >= 1.7.

# -----------------------------------------------------------------------------
# Repositorios — local y offsite reciben CADA archive en la misma corrida.
# -----------------------------------------------------------------------------
repositories:
  - path: /mnt/hd2t/backups/borg/homelab
    label: local
  - path: ${BORG_REPO_OFFSITE}     # se interpola desde secrets.env
    label: offsite

# -----------------------------------------------------------------------------
# Fuentes — ver docs/07-backups/01-estrategia-backup.md § "Inventario consolidado"
# Las rutas que aún no existen se ignoran (warning, no fatal) gracias a:
#   working_directory: /
#   borg_create_options: --noatime
# y al hecho de que Borg ignora con warning rutas inexistentes.
# Cada doc de servicio futuro descomentará SU línea cuando llegue su fase.
# -----------------------------------------------------------------------------
source_directories:
  # Configuración versionable y secretos
  - /home/homelab/homelab          # repo de compose (siempre presente)
  - /etc                           # nftables, fstab, ssh, crontabs, /etc/borgmatic.d, ...

  # Servicios — datos persistentes (categorías A y B de la estrategia)
  # Sólo descomentar tras desplegar cada servicio:
  - /mnt/hd2t/services             # se filtra con exclude_patterns más abajo

  # Dumps de bases de datos generados por hooks before_backup
  - /mnt/hd2t/backups/dumps

# -----------------------------------------------------------------------------
# Exclusiones — ver clasificación C (regenerable) y E (efímero) en la estrategia.
# -----------------------------------------------------------------------------
exclude_patterns:
  # Cachés y transcodificaciones (Jellyfin, otros)
  - '*/cache/*'
  - '*/transcodes/*'
  - '*.tmp'
  - '*/lost+found'

  # Bibliotecas multimedia compartidas (regenerables — Categoría C)
  - /mnt/hd2t/services/shared
  - /mnt/hd2t/services/jellyfin/cache
  - /mnt/hd2t/services/jellyfin/transcodes

  # Descargas en curso (regenerables)
  - /mnt/hd2t/services/transmission/downloads

  # TSDB de Prometheus — opt-out por defecto (ver justificación en estrategia).
  # Si el operador prefiere conservar el histórico, comentar la línea siguiente.
  - /mnt/hd2t/services/prometheus

  # Servicios stateless / efímeros (Categoría E)
  - /mnt/hd2t/services/dozzle
  - /mnt/hd2t/services/cadvisor
  - /mnt/hd2t/services/watchtower
  - /mnt/hd2t/services/stirling-pdf

  # Sockets y ficheros volátiles del sistema
  - /etc/mtab
  - /etc/resolv.conf

# -----------------------------------------------------------------------------
# Convenciones de creación
# -----------------------------------------------------------------------------
archive_name_format: '{hostname}-{now:%Y-%m-%dT%H:%M:%S}'
working_directory: /

# Compresión — auto detecta incompresibles (jpg, mp4, ya cifrados) y los salta.
compression: auto,zstd,3

# No fallar si una source_directory no existe; sólo emite warning.
# Útil mientras los servicios se van añadiendo en oleadas.
borg_create_options:
  - --noatime

# Verbosidad para que journalctl tenga útil:
verbosity: 1
syslog_verbosity: 1
log_file: /var/log/borgmatic.log
log_file_verbosity: 2

# Excluir ficheros con flag 'no-cow' o 'nodump' (chattr +d). No usado de momento
# pero documentado por si en el futuro se quiere marcar a mano alguna ruta:
exclude_nodump: true

# -----------------------------------------------------------------------------
# Retención (Grandfather-Father-Son) — fijada en docs/07-backups/01-estrategia-backup.md
# -----------------------------------------------------------------------------
keep_within: 24H
keep_hourly: 0
keep_daily: 14
keep_weekly: 8
keep_monthly: 12
keep_yearly: 3

# -----------------------------------------------------------------------------
# Verificación de integridad
# -----------------------------------------------------------------------------
checks:
  - name: repository
    frequency: always   # tras cada corrida
  - name: archives
    frequency: 1 week   # comprobar coherencia de archives semanalmente
  # 'data' (--verify-data) es caro: lo dispara borgmatic-check.timer (semanal local)
  # y borgmatic-verify.timer (mensual offsite) en lugar de aquí.

# -----------------------------------------------------------------------------
# SSH — Borgmatic invoca a `borg` que lee BORG_RSH del entorno (lo provee
# secrets.env vía systemd unit). Documentado aquí para visibilidad.
# -----------------------------------------------------------------------------
# ssh_command: 'ssh -i /root/.ssh/borg_offsite -o StrictHostKeyChecking=yes'

# -----------------------------------------------------------------------------
# Hooks before/after/on_error
# -----------------------------------------------------------------------------
before_backup:
  - /etc/borgmatic.d/hooks/dump-databases.sh

after_backup:
  - /etc/borgmatic.d/hooks/prometheus-textfile.sh
  - /etc/borgmatic.d/hooks/notify.sh success
  # Limpiar dumps antiguos — los del día actual quedan dentro del archive.
  - find /mnt/hd2t/backups/dumps -type f -mtime +7 -delete

on_error:
  - /etc/borgmatic.d/hooks/prometheus-textfile.sh error
  - /etc/borgmatic.d/hooks/notify.sh error

# -----------------------------------------------------------------------------
# (Opcional) Healthchecks-style ping a Uptime Kuma — se puede usar 'apprise'
# o un curl manual desde notify.sh. Aquí dejamos el slot por documentación:
#
# Cuando Uptime Kuma esté desplegado, añadir en notify.sh:
#   curl -fsS -m 5 "${KUMA_PUSH_URL}?status=up&msg=ok&ping=${duration_seconds}"
EOF
```

> **Sobre `source_directories: /mnt/hd2t/services` _completo_**: incluir el directorio padre y filtrar lo no deseado con `exclude_patterns:` evita que cada nuevo servicio requiera una edición de `config.yaml`. Si un servicio futuro entra en categoría C o E, basta con añadir su ruta al `exclude_patterns:`. Si entra en A o B, ya está incluido por inercia. **Trade-off**: es fácil olvidar excluir algo grande y descubrirlo cuando el repo crezca; los _smoke tests_ y `borg info` periódicos lo detectan rápidamente.

---

## Hooks

### `hooks/dump-databases.sh` — esqueleto

Este script vive en `~/homelab/backups/borgmatic/hooks/dump-databases.sh` y se copia a `/etc/borgmatic.d/hooks/`. **Cada doc de servicio con BD añadirá su bloque** (`docs/06-almacenamiento/01-nextcloud.md`, `docs/11-productividad/02-bookstack.md`, `docs/04-seguridad/01-authelia.md`, …). Aquí se publica el esqueleto:

```bash
cat > ~/homelab/backups/borgmatic/hooks/dump-databases.sh <<'EOF'
#!/usr/bin/env bash
# /etc/borgmatic.d/hooks/dump-databases.sh
# Llamado por before_backup. Genera dumps en /mnt/hd2t/backups/dumps/.
# Convención: <servicio>-YYYY-MM-DD.sql.gz
#
# Cada bloque está protegido por un 'docker ps -q -f name=...' previo:
# si el contenedor no está vivo, el dump se salta sin error.
#
# El detalle por servicio vive en docs/07-backups/03-backup-docker-volumes.md.
# Cada doc de servicio rellenará su bloque al desplegarse.

set -uo pipefail

DUMPS=/mnt/hd2t/backups/dumps
DATE=$(date +%F)
mkdir -p "$DUMPS"
chmod 0700 "$DUMPS"

dump() {
  local svc=$1; shift
  local out="$DUMPS/${svc}-${DATE}.sql.gz"
  echo "[dump] $svc -> $out"
  if "$@" | gzip > "$out.tmp"; then
    mv "$out.tmp" "$out"
    chmod 0600 "$out"
  else
    echo "[dump] FAILED $svc"
    rm -f "$out.tmp"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Plantillas — descomentar y adaptar EN EL DOC DE CADA SERVICIO al desplegarse.
# -----------------------------------------------------------------------------

# Nextcloud (PostgreSQL) — docs/06-almacenamiento/01-nextcloud.md
# if docker ps --format '{{.Names}}' | grep -q '^nextcloud-db$'; then
#   dump nextcloud docker exec -i nextcloud-db \
#     pg_dump -U "${NC_DB_USER:-nextcloud}" --clean --if-exists nextcloud
# fi

# Bookstack (MariaDB) — docs/11-productividad/02-bookstack.md
# if docker ps --format '{{.Names}}' | grep -q '^bookstack-db$'; then
#   dump bookstack docker exec -i bookstack-db \
#     mariadb-dump --single-transaction --routines --triggers \
#     -u root -p"${BS_DB_ROOT_PASS}" bookstack
# fi

# Vaultwarden (SQLite, copia consistente con .backup) — docs/11-productividad/01-vaultwarden.md
# if docker ps --format '{{.Names}}' | grep -q '^vaultwarden$'; then
#   docker exec vaultwarden sh -c '
#     sqlite3 /data/db.sqlite3 ".backup /data/db.sqlite3.backup" &&
#     gzip -c /data/db.sqlite3.backup
#   ' > "$DUMPS/vaultwarden-${DATE}.sql.gz" && \
#     chmod 0600 "$DUMPS/vaultwarden-${DATE}.sql.gz"
# fi

# Authelia (config + users_database.yml ya entran como ficheros, no necesitan dump)
# Home Assistant: copia del config/ via filesystem (entra como source_directory).
# Paperless (PostgreSQL) — docs/11-productividad/04-paperless-ngx.md
# Mealie / Linkding / FreshRSS — bloques análogos.

exit 0
EOF
chmod +x ~/homelab/backups/borgmatic/hooks/dump-databases.sh
```

### `hooks/notify.sh` — ntfy

```bash
cat > ~/homelab/backups/borgmatic/hooks/notify.sh <<'EOF'
#!/usr/bin/env bash
# /etc/borgmatic.d/hooks/notify.sh [success|error]
# Lanzado desde after_backup (success) y on_error (error).
set -uo pipefail

KIND="${1:-success}"
HOSTNAME=$(hostname)
URL="${NTFY_URL:-}"
TOKEN="${NTFY_TOKEN:-}"

if [ -z "$URL" ]; then
  echo "[notify] NTFY_URL vacío; skip"
  exit 0
fi

case "$KIND" in
  success)
    title="✅ Borgmatic OK ($HOSTNAME)"
    msg="Backup diario completado correctamente. $(date -Iseconds)"
    prio=2
    tags="white_check_mark"
    ;;
  error)
    title="❌ Borgmatic FAIL ($HOSTNAME)"
    msg="Backup ha fallado. Revisar journalctl -u borgmatic.service. $(date -Iseconds)"
    prio=5
    tags="warning,rotating_light"
    ;;
  *)
    echo "[notify] kind desconocido: $KIND"; exit 1 ;;
esac

curl -fsS -m 10 \
  -H "Authorization: Bearer $TOKEN" \
  -H "Title: $title" \
  -H "Priority: $prio" \
  -H "Tags: $tags" \
  -d "$msg" \
  "$URL" >/dev/null
EOF
chmod +x ~/homelab/backups/borgmatic/hooks/notify.sh
```

### `hooks/prometheus-textfile.sh` — métricas para `node_exporter`

```bash
cat > ~/homelab/backups/borgmatic/hooks/prometheus-textfile.sh <<'EOF'
#!/usr/bin/env bash
# /etc/borgmatic.d/hooks/prometheus-textfile.sh [error]
# Llamado desde after_backup (sin args = success) y on_error (arg "error").
# Escribe /var/lib/node_exporter/textfile_collector/borgmatic.prom
set -uo pipefail

OUT=/var/lib/node_exporter/textfile_collector/borgmatic.prom
TMP="${OUT}.$$"
NOW=$(date +%s)
STATUS=0
[ "${1:-}" = "error" ] && STATUS=1

mkdir -p "$(dirname "$OUT")"

repo_size_bytes() {
  local repo=$1
  borg info --json "$repo" 2>/dev/null \
    | jq -r '.cache.stats.unique_csize // 0' 2>/dev/null \
    || echo 0
}
repo_archive_count() {
  local repo=$1
  borg list --json "$repo" 2>/dev/null \
    | jq -r '.archives | length' 2>/dev/null \
    || echo 0
}

LOCAL=${BORG_REPO_LOCAL:-}
OFFSITE=${BORG_REPO_OFFSITE:-}

local_size=$(repo_size_bytes "$LOCAL")
local_arch=$(repo_archive_count "$LOCAL")
offsite_size=$(repo_size_bytes "$OFFSITE")
offsite_arch=$(repo_archive_count "$OFFSITE")

cat > "$TMP" <<METRICS
# HELP borg_last_run_timestamp_seconds Epoch UTC de la ultima ejecucion
# TYPE borg_last_run_timestamp_seconds gauge
borg_last_run_timestamp_seconds $NOW
# HELP borg_last_run_status 0=ok 1=error
# TYPE borg_last_run_status gauge
borg_last_run_status $STATUS
# HELP borg_repo_size_bytes Bytes unicos almacenados (post-dedup)
# TYPE borg_repo_size_bytes gauge
borg_repo_size_bytes{repo="local"} $local_size
borg_repo_size_bytes{repo="offsite"} $offsite_size
# HELP borg_archive_count Numero de archives en el repo
# TYPE borg_archive_count gauge
borg_archive_count{repo="local"} $local_arch
borg_archive_count{repo="offsite"} $offsite_arch
METRICS

mv "$TMP" "$OUT"
chmod 0644 "$OUT"
EOF
chmod +x ~/homelab/backups/borgmatic/hooks/prometheus-textfile.sh
```

> **Sobre `node_exporter`**: el textfile collector necesita que `node_exporter` esté arrancado con `--collector.textfile.directory=/var/lib/node_exporter/textfile_collector`. La `docker-compose.yml` de `node_exporter` (ya cubierta en `docs/05-monitorizacion/03-node-exporter.md`) monta ese directorio en `:ro` desde el contenedor. Aquí el host **escribe** y el contenedor **lee**. Si node_exporter aún no está desplegado, las métricas quedan en disco esperando: cuando se despliegue, las recoge automáticamente.

---

## `systemd` units

### `borgmatic.service` y `borgmatic.timer` — corrida diaria

```bash
cat > ~/homelab/backups/borgmatic/systemd/borgmatic.service <<'EOF'
[Unit]
Description=Borgmatic — copia de seguridad diaria del homelab
Documentation=docs/07-backups/02-borgmatic.md
Wants=network-online.target
After=network-online.target

# No empezar si la red no llegó (el offsite necesita SSH saliente).
ConditionPathExists=/etc/borgmatic.d/secrets.env
ConditionPathExists=/etc/borgmatic.d/config.yaml

[Service]
Type=oneshot

# Cargar secretos como variables de entorno
EnvironmentFile=/etc/borgmatic.d/secrets.env

# SSH para el repo offsite (rsync.net / Hetzner / pi-offsite)
Environment="BORG_RSH=ssh -i /root/.ssh/borg_offsite -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes"

# Reducir prioridad para no entorpecer el resto de la Pi.
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
CPUSchedulingPolicy=batch

# Hardening básico — pero Borgmatic necesita escribir en muchos sitios.
ProtectSystem=strict
ReadWritePaths=/var/log /var/lib/borg /mnt/hd2t/backups /var/lib/node_exporter
PrivateTmp=true
NoNewPrivileges=true
RestrictSUIDSGID=true
LockPersonality=true

# El backup puede tardar horas la primera vez. Sin timeout.
TimeoutStartSec=infinity

ExecStart=/usr/bin/borgmatic --verbosity 1 --syslog-verbosity 1

[Install]
WantedBy=multi-user.target
EOF
```

```bash
cat > ~/homelab/backups/borgmatic/systemd/borgmatic.timer <<'EOF'
[Unit]
Description=Disparador diario de Borgmatic (03:30 hora local)

[Timer]
# 03:30 evita la 'hora fantasma' del cambio de horario en Europa
# (último domingo de marzo y de octubre).
OnCalendar=*-*-* 03:30:00

# Si la Pi estaba apagada a las 03:30, ejecutar al volver.
Persistent=true

# Jitter de hasta 15 min para no pegarse contra otros timers a la misma hora.
RandomizedDelaySec=15min

# Identificador estable
Unit=borgmatic.service

[Install]
WantedBy=timers.target
EOF
```

### `borgmatic-check.service` y `.timer` — `--verify-data` semanal sobre el repo local

```bash
cat > ~/homelab/backups/borgmatic/systemd/borgmatic-check.service <<'EOF'
[Unit]
Description=Borgmatic — verify-data semanal del repo local
Documentation=docs/07-backups/02-borgmatic.md
ConditionPathExists=/etc/borgmatic.d/config.yaml
ConditionPathExists=/etc/borgmatic.d/secrets.env

[Service]
Type=oneshot
EnvironmentFile=/etc/borgmatic.d/secrets.env
Environment="BORG_RSH=ssh -i /root/.ssh/borg_offsite -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes"

Nice=15
IOSchedulingClass=idle
TimeoutStartSec=infinity

# Sólo el repo local (rápido, sin tráfico offsite).
ExecStart=/usr/bin/borgmatic check --only data --repository /mnt/hd2t/backups/borg/homelab --verbosity 1
EOF
```

```bash
cat > ~/homelab/backups/borgmatic/systemd/borgmatic-check.timer <<'EOF'
[Unit]
Description=Disparador semanal de borgmatic-check (domingos 04:30)

[Timer]
OnCalendar=Sun *-*-* 04:30:00
Persistent=true
RandomizedDelaySec=30min
Unit=borgmatic-check.service

[Install]
WantedBy=timers.target
EOF
```

### `borgmatic-verify.service` y `.timer` — `--verify-data` mensual sobre el repo offsite

```bash
cat > ~/homelab/backups/borgmatic/systemd/borgmatic-verify.service <<'EOF'
[Unit]
Description=Borgmatic — verify-data mensual del repo offsite
Documentation=docs/07-backups/02-borgmatic.md
ConditionPathExists=/etc/borgmatic.d/config.yaml
ConditionPathExists=/etc/borgmatic.d/secrets.env

[Service]
Type=oneshot
EnvironmentFile=/etc/borgmatic.d/secrets.env
Environment="BORG_RSH=ssh -i /root/.ssh/borg_offsite -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes"

Nice=15
IOSchedulingClass=idle
TimeoutStartSec=infinity

# El repo offsite — cuidado: descarga/lee TODOS los chunks. Costoso.
ExecStart=/bin/sh -c '/usr/bin/borgmatic check --only data --repository "$BORG_REPO_OFFSITE" --verbosity 1'
EOF
```

```bash
cat > ~/homelab/backups/borgmatic/systemd/borgmatic-verify.timer <<'EOF'
[Unit]
Description=Disparador mensual de borgmatic-verify (día 1, 05:00)

[Timer]
OnCalendar=*-*-01 05:00:00
Persistent=true
RandomizedDelaySec=30min
Unit=borgmatic-verify.service

[Install]
WantedBy=timers.target
EOF
```

---

## `install.sh` — copiar plantillas a `/etc/`

Script idempotente para sincronizar `~/homelab/backups/borgmatic/` con el sistema. Se ejecuta tras cada cambio en las plantillas.

```bash
cat > ~/homelab/backups/borgmatic/install.sh <<'EOF'
#!/usr/bin/env bash
# install.sh — copia las plantillas de Borgmatic a /etc/ y recarga systemd.
# Idempotente: re-ejecutar es seguro.
#
# Requiere sudo / root.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DST_CONF=/etc/borgmatic.d
DST_HOOKS=/etc/borgmatic.d/hooks
DST_SYSD=/etc/systemd/system

if [ "$(id -u)" -ne 0 ]; then
  echo "Re-lanzando con sudo..."
  exec sudo -E "$0" "$@"
fi

# Crear destinos
install -d -m 0700 -o root -g root "$DST_CONF" "$DST_HOOKS"

# Plantillas (NO el secrets.env)
install -m 0644 -o root -g root "$SRC/config.yaml" "$DST_CONF/config.yaml"
install -m 0755 -o root -g root "$SRC/hooks/dump-databases.sh"      "$DST_HOOKS/"
install -m 0755 -o root -g root "$SRC/hooks/notify.sh"              "$DST_HOOKS/"
install -m 0755 -o root -g root "$SRC/hooks/prometheus-textfile.sh" "$DST_HOOKS/"

# systemd unit files
for f in borgmatic.service borgmatic.timer \
         borgmatic-check.service borgmatic-check.timer \
         borgmatic-verify.service borgmatic-verify.timer; do
  install -m 0644 -o root -g root "$SRC/systemd/$f" "$DST_SYSD/$f"
done

# Validar config.yaml antes de seguir
if ! /usr/bin/borgmatic config validate >/dev/null; then
  echo "ERROR: config.yaml invalido" >&2
  exit 1
fi

# Recargar systemd y activar timers
systemctl daemon-reload

for t in borgmatic.timer borgmatic-check.timer borgmatic-verify.timer; do
  systemctl enable --now "$t"
done

echo "OK — timers activos:"
systemctl list-timers --no-pager | grep -E '^NEXT|borgmatic'
EOF
chmod +x ~/homelab/backups/borgmatic/install.sh
```

Ejecutar la primera vez:

```bash
sudo ~/homelab/backups/borgmatic/install.sh
# OK — timers activos:
# NEXT                        LEFT      LAST  PASSED  UNIT                          ACTIVATES
# Mon 2026-04-27 03:30:30 ...           -     -       borgmatic.timer               borgmatic.service
# Sun 2026-05-03 04:48:12 ...           -     -       borgmatic-check.timer         borgmatic-check.service
# Fri 2026-05-01 05:14:21 ...           -     -       borgmatic-verify.timer        borgmatic-verify.service
```

---

## Primer backup manual (smoke test)

Antes de esperar a las 03:30, lanzar una corrida manual. Es la **prueba de que toda la cadena funciona**:

```bash
# Dry-run primero — Borgmatic enumera qué haría sin tocar nada
sudo /usr/bin/borgmatic --dry-run --verbosity 1
# ...
# create archive: pi-XXXX-04-26T11:23:45 (dry run)
# ...

# Backup real
sudo /usr/bin/borgmatic --verbosity 1 2>&1 | tee /tmp/borgmatic-firstrun.log
```

La primera corrida puede tardar **horas**: sube todo a offsite. Las siguientes serán _delta_ (decenas de MB).

Comprobaciones tras la primera corrida:

```bash
# Listar archives en cada repo
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL"
  echo "---"
  export BORG_RSH="ssh -i /root/.ssh/borg_offsite -o StrictHostKeyChecking=yes"
  borg list "$BORG_REPO_OFFSITE"
'
# pi-2026-04-26T03:30:30                Mon, 2026-04-26 03:30:30 [...]

# Tamaños y dedup
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg info "$BORG_REPO_LOCAL"
  echo "---"
  export BORG_RSH="ssh -i /root/.ssh/borg_offsite -o StrictHostKeyChecking=yes"
  borg info "$BORG_REPO_OFFSITE"
'
# Original size      Compressed size    Deduplicated size
# 12.34 GB           5.67 GB            5.67 GB
```

Comprobar también que el _hook_ de notificación llegó:

- Abrir <https://ntfy.sh/$NTFY_TOPIC> en el navegador (o suscribir el topic en la app móvil de ntfy). Debería verse un mensaje "✅ Borgmatic OK".
- `cat /var/lib/node_exporter/textfile_collector/borgmatic.prom` muestra las métricas con `borg_last_run_status 0`.

---

## Restauración de prueba

Sin restauración, no hay backup. Drill rápido — extraer un fichero conocido a `/tmp/restore/` y comparar con el original:

```bash
sudo mkdir -p /tmp/restore && cd /tmp/restore

ARCHIVE=$(sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list --short "$BORG_REPO_LOCAL" | tail -1
')
echo "Probando con archive: $ARCHIVE"

sudo bash -c "
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg extract --list \"\$BORG_REPO_LOCAL::$ARCHIVE\" home/homelab/homelab/.gitignore
"

# Comparar
diff /tmp/restore/home/homelab/homelab/.gitignore /home/homelab/homelab/.gitignore
# (sin output = idénticos)

sudo rm -rf /tmp/restore
```

Drill más serio (mensual, según calendario de la estrategia): restaurar Vaultwarden o Nextcloud completos a `/tmp/restore-<svc>/` y arrancar un contenedor temporal apuntando ahí. Procedimientos detallados en `docs/07-backups/03-backup-docker-volumes.md`.

> **Por qué hacer el drill _hoy_, no en 30 días**: las dos primeras restauraciones siempre revelan algo (un `.env` no respaldado, un permiso no preservado, un `service_account` que se restauró pero no se le re-pegó la passphrase). Mejor descubrirlo con todo limpio y reciente, no en plena emergencia.

---

## Versionado en git

Tras dejar todo funcionando:

```bash
cd ~/homelab
git status
# modified:   (untracked) backups/

# Verificar que .gitignore bloquea secrets.env si alguien lo creara aquí
echo "BORG_PASSPHRASE=fake" > backups/borgmatic/secrets.env
git status
# debe seguir SIN listar backups/borgmatic/secrets.env
rm backups/borgmatic/secrets.env

# Commit
git add backups/.gitignore backups/borgmatic/
git commit -m "feat(backups): add Borgmatic config, hooks, systemd timers"
```

`/etc/borgmatic.d/secrets.env` y `/root/.ssh/borg_offsite` **no** entran en git: viven solo en la Pi y en el plan de custodia.

---

## Verificación final

Antes de dar por cerrado este documento:

- [ ] `borg --version` ≥ 1.2 y `borgmatic --version` ≥ 1.7.
- [ ] `sudo stat -c '%a %U:%G' /etc/borgmatic.d/secrets.env` devuelve `600 root:root`.
- [ ] `sudo stat -c '%a %U:%G' /root/.ssh/borg_offsite` devuelve `600 root:root`.
- [ ] `sudo borgmatic config validate` no reporta errores.
- [ ] `sudo bash -c '. /etc/borgmatic.d/secrets.env; borg info "$BORG_REPO_LOCAL"'` muestra `Encrypted: Yes (repokey BLAKE2b)` y `Number of archives: ≥ 1` (tras el primer backup manual).
- [ ] `sudo bash -c '. /etc/borgmatic.d/secrets.env; export BORG_RSH=...; borg info "$BORG_REPO_OFFSITE"'` muestra lo mismo en el repo offsite.
- [ ] `systemctl list-timers --no-pager | grep borgmatic` lista los tres timers en estado activo (`active`).
- [ ] `journalctl -u borgmatic.service --since today --no-pager | tail -50` muestra la corrida manual y termina con `Summary: total: X archives`.
- [ ] El topic de `ntfy.sh` recibió la notificación "✅ Borgmatic OK" del primer backup.
- [ ] `cat /var/lib/node_exporter/textfile_collector/borgmatic.prom` existe, `borg_last_run_status 0`, `borg_archive_count{repo="local"} ≥ 1`.
- [ ] Restauración de un fichero conocido a `/tmp/restore` y `diff` con el original sin diferencias.
- [ ] La passphrase está en al menos **dos** lugares de custodia (gestor externo + papel mientras Vaultwarden no exista).
- [ ] El destino offsite real (rsync.net / Hetzner / pi-offsite) está confirmado y funcionando, no un placeholder. Si por algún motivo se aplazó: anotar en `~/homelab/docs/journal/YYYY-MM-DD-borgmatic-offsite-pendiente.md` y volver al doc cuando se decida.
- [ ] `git log --oneline | head -5` muestra el _commit_ con `feat(backups): add Borgmatic ...`.

---

## Backup

Sí, este documento también tiene una sección **Backup**. Lo que respaldar:

| Qué                                          | Dónde                                                    | Cómo                                                       |
|----------------------------------------------|----------------------------------------------------------|------------------------------------------------------------|
| Plantillas (`config.yaml`, hooks, systemd, install.sh) | `~/homelab/backups/borgmatic/`                           | git                                                        |
| `/etc/borgmatic.d/config.yaml` (copia desplegada) | `/etc/borgmatic.d/`                                      | entra en `source_directories: /etc` del propio Borg (auto-respaldo) |
| `/etc/borgmatic.d/secrets.env`               | `/etc/borgmatic.d/`                                      | entra en `/etc` (Borg lo respalda); además: passphrase y tokens custodiados en gestor externo + papel. **No** versionar. |
| `/root/.ssh/borg_offsite`                    | `/root/.ssh/`                                            | entra en `/etc`? — **no**, `/root` no está en `/etc`. Añadir explícitamente: `/root` a `source_directories` o documentar que se regenera. **Decisión del homelab**: la clave SSH se respalda como parte del archive (excluyendo `/root/.ssh/known_hosts.old`). Si la Pi se pierde, generar nueva clave y subir la pública al proveedor offsite — la antigua deja de servir, sin daño. |
| `/var/lib/borg` (cache de Borg)              | host                                                     | **No** respaldar. Es _cache_ regenerable: `borg` lo reconstruye en la primera operación si falta. |
| Repos Borg (`/mnt/hd2t/backups/borg/`)       | hd2t                                                     | **No** se respaldan a sí mismos. La copia offsite es _su_ backup. |

> **Sobre `/root/.ssh/`**: añadir, en `~/homelab/backups/borgmatic/config.yaml`, la línea `- /root` a `source_directories:` (con su correspondiente exclude para `*/known_hosts.old` y `*/.bash_history`). Esto cubre la clave de offsite y los `known_hosts` pinneados. Update vía `install.sh`.

> **Restauración del propio Borgmatic tras un disaster recovery completo** (Pi nueva, microSD nueva, hd2t recuperado o no):
>
> 1. Reinstalar OS según `docs/01-sistema/01-instalacion-os.md`.
> 2. `sudo apt install borgbackup borgmatic pwgen jq curl`.
> 3. Recuperar la passphrase del plan de custodia y la clave SSH del offsite (si existe copia, ej. KeePassXC en otra máquina) o **generar una nueva clave** y subir la pública al proveedor (con `command="borg serve --append-only"` apuntando al repo existente).
> 4. `borg list ssh://...../homelab` → ver archives disponibles.
> 5. `borg extract --target / ssh://...../homelab::<archive_reciente> etc/borgmatic.d` → recuperar la configuración.
> 6. `borg extract --target / ...::<archive> home/homelab/homelab` → recuperar el repo de Compose.
> 7. Re-aplicar `~/homelab/backups/borgmatic/install.sh`.
> 8. Continuar con `docs/13-operaciones/02-disaster-recovery.md` para los servicios.

---

## Troubleshooting

### `borg init` falla con `repository already exists` y la ruta está vacía

Síntoma:

```
sudo borg init --encryption=repokey-blake2 /mnt/hd2t/backups/borg/homelab
ERROR Repository /mnt/hd2t/backups/borg/homelab already exists.
```

`ls -la` en la ruta solo muestra `lock.exclusive` o `lock.roster`.

Causa: locks Borg huérfanos de un intento previo.

Solución:

```bash
sudo find /mnt/hd2t/backups/borg/homelab -mindepth 1 -delete
sudo bash -c '. /etc/borgmatic.d/secrets.env && \
  borg init --encryption=repokey-blake2 "$BORG_REPO_LOCAL"'
```

### `borgmatic` falla con `Permission denied` al leer `/mnt/hd2t/services/.../config.php`

Síntoma:

```
borg: PermissionError: [Errno 13] Permission denied: '/mnt/hd2t/services/nextcloud/data/.../config.php'
```

Causa: el _systemd unit_ corre como `root`, pero algún _hardening_ (`ProtectSystem=strict`, `PrivateMounts=true`) está enmascarando el bind mount.

Diagnóstico:

```bash
# Probar manualmente como root sin systemd
sudo borgmatic --verbosity 2 --dry-run
# Si funciona aquí, el problema es del unit.
```

Solución: relajar `ProtectSystem` o añadir `ReadOnlyPaths=/mnt/hd2t` al `borgmatic.service`. Aplicar `install.sh` y `systemctl daemon-reload`.

### `journalctl -u borgmatic.service` muestra `BORG_RSH not set` y el repo offsite falla

Síntoma:

```
borg: Connection closed by remote host
```

`BORG_RSH` no está siendo pasado al subproceso `borg`.

Causa: el _systemd unit_ tiene `EnvironmentFile=/etc/borgmatic.d/secrets.env` pero `BORG_RSH` se define en `Environment=...` y, por orden, se ve sobreescrito por el `EnvironmentFile`. O viceversa.

Solución: confirmar el orden. Por defecto en este doc, `EnvironmentFile` se carga primero y `Environment=BORG_RSH=...` después, así que `BORG_RSH` siempre gana. Si por algún motivo se invirtió:

```bash
sudo systemctl cat borgmatic.service | grep -E 'Environment(File)?'
# EnvironmentFile=/etc/borgmatic.d/secrets.env
# Environment="BORG_RSH=ssh ..."
```

`Environment=` con `BORG_RSH` debe estar **después** del `EnvironmentFile`. Si no, mover en `~/homelab/backups/borgmatic/systemd/borgmatic.service`, `install.sh`, `daemon-reload`, reintentar.

### El backup tarda muchísimo cada noche, no parece deduplicar

Síntoma: `borg info "$BORG_REPO_LOCAL"` muestra `Deduplicated size` casi igual a `Original size` día tras día. La subida offsite tarda como la primera vez.

Causas posibles:

1. **Cache de Borg corrupto o vaciado**: `BORG_CACHE_DIR` no persiste entre corridas (típico si se montó un `tmpfs` por error). Verificar `ls -la /var/lib/borg/cache`. Si está vacío tras una corrida exitosa, está siendo limpiado.

2. **`compression: auto,zstd,3` no está activa**: confirmar en `/etc/borgmatic.d/config.yaml`. Sin compresión, las BD textuales (SQL dumps) no se aprovechan.

3. **Los dumps no son determinísticos**: `pg_dump` con `--data-only` en orden aleatorio rompe el _rolling hash_. Usar siempre `pg_dump --clean --if-exists` (orden estable de tablas) o `pg_dump --schema-only` + `--data-only` separados con orden por PK. Detalle en `docs/07-backups/03-backup-docker-volumes.md`.

4. **El servicio gira ficheros enormes con cada arranque**: ej. `/var/log/journal/`. Excluir.

Diagnóstico:

```bash
sudo bash -c '. /etc/borgmatic.d/secrets.env && \
  borg list "$BORG_REPO_LOCAL"'

A1=$(sudo bash -c '. /etc/borgmatic.d/secrets.env && \
  borg list --short "$BORG_REPO_LOCAL"' | tail -2 | head -1)
A2=$(sudo bash -c '. /etc/borgmatic.d/secrets.env && \
  borg list --short "$BORG_REPO_LOCAL"' | tail -1)

sudo bash -c ". /etc/borgmatic.d/secrets.env && \
  borg diff \"\$BORG_REPO_LOCAL::$A1\" \"\$BORG_REPO_LOCAL::$A2\" | head -50"
# Lista los ficheros que cambiaron entre las dos últimas corridas.
```

### `borgmatic` con `before_backup` falla pero el backup se ejecuta de todos modos

Síntoma: `dump-databases.sh` falla (ej. el contenedor de BD está caído), pero el archive Borg se crea sin la BD.

Comportamiento por diseño: `before_backup` no aborta el _create_ por defecto. Para abortar, en `config.yaml`:

```yaml
before_backup:
  - sh -c '/etc/borgmatic.d/hooks/dump-databases.sh || exit 1'
```

Si se quiere que el script falle el backup **solo** si la BD estaba arrancada (no abortar si todo el servicio está parado por mantenimiento), hacerlo en `dump-databases.sh` con un `exit 0` suave en el _check_ inicial (ya hecho en el esqueleto).

### El timer dispara pero `journalctl` no muestra nada el día siguiente

Síntoma: `systemctl list-timers` muestra que el timer se disparó (`Last:`), pero `journalctl -u borgmatic.service --since yesterday` está vacío.

Causa típica: confusión de zonas horarias. `OnCalendar=*-*-* 03:30:00` se interpreta en la zona horaria del sistema; `journalctl --since yesterday` también — pero si el reloj del sistema cambió (cambio de horario) entre la corrida y la consulta, "ayer" puede no abarcar el momento de la corrida.

Diagnóstico:

```bash
journalctl -u borgmatic.service --since '3 days ago' --no-pager | head -100
systemctl status borgmatic.timer
systemd-analyze calendar 'OnCalendar=*-*-* 03:30:00'
# Original form: *-*-* 03:30:00
# Normalized form: *-*-* 03:30:00
# Next elapse: Mon 2026-04-27 03:30:00 CEST
# (in UTC): Mon 2026-04-27 01:30:00 UTC
# From now: 16h 12min left
```

### `notify.sh` no envía nada y `journalctl` muestra `curl: (6) Could not resolve host`

Síntoma: el hook de ntfy falla porque no hay DNS.

Causa típica: en el momento de las 03:30, Pi-hole estaba reiniciándose o macvlan no estaba listo.

Solución: añadir resolver _fallback_ en `/etc/resolv.conf` (cubierto en `docs/03-red/02-pihole.md`, sección "DNS fallback"). El backup en sí no necesita DNS si el `BORG_REPO_OFFSITE` lleva IP literal o nombre Tailscale (MagicDNS). Las notificaciones necesitan DNS público.

### `prometheus-textfile.sh` deja un fichero `.prom.NNN` sin renombrar

Síntoma: `ls /var/lib/node_exporter/textfile_collector/` muestra `borgmatic.prom.12345` y no `borgmatic.prom`. node_exporter ignora ficheros que no terminen en `.prom` y `borgmatic_*` métricas no aparecen.

Causa: el `mv "$TMP" "$OUT"` falló (probablemente `borg info` colgó y el script murió en el medio).

Solución manual: `sudo mv /var/lib/node_exporter/textfile_collector/borgmatic.prom.* /var/lib/node_exporter/textfile_collector/borgmatic.prom`. Como prevención, el script ya hace `mv` atómico (mismo filesystem) — el problema sólo aparece si el script se interrumpió a mitad. La próxima corrida lo resuelve.

### `borg check --verify-data` semanal aborta tras horas con error de I/O

Síntoma:

```
borg: Repository check complete, errors found: 12 (corrupt segments).
```

Diagnóstico inmediato:

1. Confirmar SMART del HDD: `sudo smartctl -H /dev/disk/by-label/hd2t`. Si reporta `FAILED`, el disco está muriendo — sustituir y restaurar desde offsite.
2. Si SMART OK: posible _bit rot_ silencioso. `borg check --repair` puede recuperar parte (con advertencia: borra chunks corruptos). Antes, marcar el repo offsite como **fuente fiable** y considerar reinicializar el local desde cero (la próxima corrida lo rellena).

Pasos de respuesta documentados en `docs/07-backups/01-estrategia-backup.md` → "El repo `--verify-data` semanal ha fallado".

### `borgmatic config validate` se queja de YAML inválido tras editar

Síntoma:

```
ERROR: borgmatic.d/config.yaml: while parsing a block mapping ...
```

Causa más común: TAB en lugar de espacios, o mezcla de los dos. YAML es estricto.

Diagnóstico:

```bash
cat -A ~/homelab/backups/borgmatic/config.yaml | grep -n '\^I'
# Si encuentra '^I' es un TAB. Sustituir por 2 espacios.
```

Y siempre antes de `install.sh`:

```bash
yamllint ~/homelab/backups/borgmatic/config.yaml || true
borgmatic --config ~/homelab/backups/borgmatic/config.yaml config validate
```

---

## Operaciones recurrentes

### Listar archives

```bash
sudo bash -c '. /etc/borgmatic.d/secrets.env && \
  borg list "$BORG_REPO_LOCAL"'
```

### Extraer un fichero o árbol

```bash
sudo mkdir -p /tmp/restore && cd /tmp/restore
sudo bash -c '. /etc/borgmatic.d/secrets.env && \
  borg extract --list "$BORG_REPO_LOCAL::pi-2026-04-26T03:30:30" \
    home/homelab/homelab/almacen/.env'
```

`borg extract` siempre extrae paths **relativos** al directorio actual. La ruta dentro del archive **no** lleva `/` inicial.

### Montar un archive (browse interactivo)

```bash
sudo apt install -y python3-llfuse fuse3
sudo mkdir -p /mnt/borg
sudo bash -c '. /etc/borgmatic.d/secrets.env && \
  borg mount "$BORG_REPO_LOCAL::pi-2026-04-26T03:30:30" /mnt/borg'

ls /mnt/borg/home/homelab/homelab/

sudo umount /mnt/borg
```

### Forzar un backup _ad hoc_ (antes de un upgrade arriesgado)

```bash
sudo systemctl start borgmatic.service
sudo journalctl -u borgmatic.service -f
```

### Pausar Borgmatic (mantenimiento de hd2t, viaje, …)

```bash
sudo systemctl stop borgmatic.timer borgmatic-check.timer borgmatic-verify.timer
sudo systemctl disable borgmatic.timer borgmatic-check.timer borgmatic-verify.timer
# ... mantenimiento ...
sudo systemctl enable --now borgmatic.timer borgmatic-check.timer borgmatic-verify.timer
```

### Rotar la passphrase

```bash
sudo bash -c '. /etc/borgmatic.d/secrets.env && \
  borg key change-passphrase "$BORG_REPO_LOCAL"'
sudo bash -c '. /etc/borgmatic.d/secrets.env && \
  export BORG_RSH="ssh -i /root/.ssh/borg_offsite -o StrictHostKeyChecking=yes" && \
  borg key change-passphrase "$BORG_REPO_OFFSITE"'

# Editar /etc/borgmatic.d/secrets.env con la nueva passphrase
sudo $EDITOR /etc/borgmatic.d/secrets.env
```

Y **el mismo día**, actualizar las tres copias del plan de custodia (gestor externo + papel + Vaultwarden cuando exista).

### Migrar el repo local a un disco nuevo

`borg` soporta copia 1:1 del repo (es un directorio con ficheros). `cp -a /mnt/hd2t/backups/borg/homelab /mnt/hdNUEVO/backups/borg/homelab`, luego cambiar `BORG_REPO_LOCAL` en `secrets.env` y `path:` en `config.yaml`. La cache (`/var/lib/borg`) se reconstruye sola en la siguiente operación.

---

## Referencias

- BorgBackup — documentación oficial: <https://borgbackup.readthedocs.io/en/stable/>
- BorgBackup — modos de cifrado y `repokey-blake2`: <https://borgbackup.readthedocs.io/en/stable/usage/init.html>
- BorgBackup — `borg check`, `--verify-data`, `--repair`: <https://borgbackup.readthedocs.io/en/stable/usage/check.html>
- BorgBackup — `borg create` opciones: <https://borgbackup.readthedocs.io/en/stable/usage/create.html>
- Borgmatic — documentación oficial y referencia YAML: <https://torsion.org/borgmatic/>
- Borgmatic — hooks `before_backup` / `after_backup` / `on_error`: <https://torsion.org/borgmatic/docs/how-to/add-preparation-and-cleanup-steps-to-backups/>
- Borgmatic — monitorización (ntfy, Healthchecks, PagerDuty, …): <https://torsion.org/borgmatic/docs/how-to/monitor-your-backups/>
- Borgmatic — chequeos de integridad: <https://torsion.org/borgmatic/docs/how-to/deal-with-very-large-backups/>
- systemd — `OnCalendar=` y `Persistent=true`: <https://www.freedesktop.org/software/systemd/man/systemd.timer.html>
- systemd — `EnvironmentFile=` y orden de carga: <https://www.freedesktop.org/software/systemd/man/systemd.exec.html>
- ntfy — API HTTP, prioridades y _tags_: <https://docs.ntfy.sh/publish/>
- node_exporter — _textfile collector_: <https://github.com/prometheus/node_exporter#textfile-collector>
- rsync.net — Borg account: <https://www.rsync.net/products/borg.html>
- Hetzner Storage Box — uso con SSH/SFTP: <https://docs.hetzner.com/robot/storage-box/>
- Tailscale — MagicDNS y SSH para nodos remotos: <https://tailscale.com/kb/1081/magicdns>
