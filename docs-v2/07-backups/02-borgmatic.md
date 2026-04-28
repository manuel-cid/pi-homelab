# Borgmatic

## Descripción

Despliegue de **Borgmatic** como **orquestador de [BorgBackup](https://www.borgbackup.org/)** para el homelab de la Pi 5. Implementa de forma concreta — `borgmatic.yml`, `systemd` timers y hooks por servicio — las decisiones de fondo que [`./01-estrategia-backup.md`](./01-estrategia-backup.md) ya fijó (3-2-1, repo `repokey-blake2`, GFS 7d/4w/6m/1y, "dump primero, snapshot después", offsite B2 append-only).

Borgmatic **no es** un motor de backup nuevo: es una capa declarativa fina sobre Borg (~3000 SLOC en Python) que aporta exactamente lo que falta para operar Borg en producción doméstica:

1. **Configuración en YAML único** (`/etc/borgmatic/config.yaml`) en lugar de un script bash que invoque `borg create`/`borg prune`/`borg compact` por separado, con sus reintentos, su quoting y sus `set -e`. El YAML versionable cubre fuentes, exclusiones, repos, cifrado, retención, hooks, notificación.
2. **Hooks declarativos** (`before_backup`, `after_backup`, `on_error`, `before_everything`, `after_everything`) que ejecutan comandos arbitrarios en orden definido y con manejo de errores común. Sustituye al patrón `pg_dump | tee | gzip && borg create && rm` propenso a olvidos.
3. **Hooks específicos para BD** ([`postgresql_databases:`](https://torsion.org/borgmatic/docs/reference/configuration/), [`mariadb_databases:`](https://torsion.org/borgmatic/docs/reference/configuration/), [`sqlite_databases:`](https://torsion.org/borgmatic/docs/reference/configuration/)) que internamente saben llamar a `pg_dump`/`mariadb-dump`/`sqlite3 .backup` con los flags correctos (`--single-transaction`, `--format=custom`, etc.) y limpian los dumps tras snapshot. El operador no escribe esos comandos a mano.
4. **Hook nativo `monitoring`** con soporte para [Apprise](https://github.com/caronc/apprise), [Healthchecks.io](https://healthchecks.io/), [Cronhub](https://cronhub.io/), [Cronitor](https://cronitor.io/) y [ntfy](https://ntfy.sh/), más URLs genéricas (Uptime Kuma push usa esta vía). Notificación de éxito y fallo unificada, sin escribir un wrapper bash.
5. **Subcomandos `extract`, `mount`, `list`, `info`, `check`, `compact`, `prune`** mapeados directamente a Borg con la configuración ya cargada, evitando que el operador tenga que recordar la passphrase, el path del repo y los flags cada vez.
6. **Validación del YAML** (`borgmatic config validate`) antes de ejecutar — atrapa typos en `source_directories`, paths inexistentes y secciones malformadas.

El stack `backups` ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §1.1) **no** despliega un contenedor de Borgmatic. Borgmatic se instala **nativo en el host** (paquete `apt` o `pipx`) y se ejecuta desde un **systemd timer como `root`**. Las razones son explícitas y operativas:

1. **Borgmatic necesita leer paths con `0700 root:root`**: `/mnt/hd2t/backups/dumps/`, `/etc/ssh/`, `/etc/ufw/`, `/root/.ssh/`. Un contenedor exige montar esos paths con `:ro` y dar al UID del contenedor (típicamente `0` dentro, mapeado a `0` del host con `user: 0:0`) acceso real, lo cual equivale a meter root del host dentro del contenedor. La capa de aislamiento Docker no aporta nada cuando el contenedor ya es root over-the-host (acceso a `/etc/`, al socket Docker para los hooks, a todo `/mnt/hd2t/`). Mejor que la cosa que es root, sea root del host directamente.
2. **Hooks `docker exec` a otros contenedores**: para el dump de la BD de Nextcloud, el hook entra al contenedor `postgres-nextcloud` y ejecuta `pg_dump`. Borgmatic en el host hace `docker exec postgres-nextcloud pg_dumpall -U postgres > /mnt/.../dump.sql.gz` directamente. Borgmatic dentro de un contenedor exige montar `/var/run/docker.sock:/var/run/docker.sock` y aprender que el `pg_dump` que tiene a mano es el del *host*, no el del contenedor de la BD destino — versión diferente del que generó el dump, que es exactamente la causa típica de restauraciones rotas.
3. **`systemd` ya está en el host** y resuelve dependencias (`After=local-fs.target docker.service`), reintentos (`Restart=on-failure` con `RestartSec=`), retención de logs (`journalctl -u borgmatic.timer`), y montaje del disco (`RequiresMountsFor=/mnt/hd2t`). Reproducir esto dentro de un contenedor exige `cron` o `supervisord` o `s6-overlay`, todos peores que `systemd` para esto.
4. **Versión de Borg necesaria**: `borg ≥ 1.2` para `repokey-blake2` con compresión `zstd`, `borgmatic ≥ 1.8` para los hooks `mariadb_databases`/`sqlite_databases` declarativos. Raspberry Pi OS Bookworm trae `borg 1.2.4` y `borgmatic 1.7.7` en `apt`. La 1.7.7 ya tiene los tres hooks de BD; si el operador quiere ir más adelante (2.x) usa `pipx install borgmatic` y obtiene siempre la última. Detallado en §2.
5. **El repo de Borg vive en `/mnt/hd2t/backups/borg/`**, gestionado por root. No hay nada que el sistema haga con él que justifique aislarlo en un contenedor: las "bibliotecas externas" (Borg) son binarias estáticas Python y no traen ecosistema de plugins peligrosos.

> **Variante**: el operador que quiera Borgmatic en contenedor puede usar [`ghcr.io/borgmatic-collective/borgmatic`](https://github.com/borgmatic-collective/docker-borgmatic) y un timer systemd que ejecute `docker run --rm`. La configuración de `borgmatic.yml` documentada aquí es **idéntica** en ambas variantes (el binario es el mismo). Cambia solo cómo se invoca. La elección por defecto del homelab es nativa por lo dicho arriba.

Por qué exactamente esta arquitectura, y no otra:

1. **Un solo repo Borg, no dos.** [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §7.3 contempla un futuro `borg-core` + `borg-media`, pero la versión por defecto es **un repo único** con `exclude_patterns` que mantiene fuera la multimedia voluminosa de Stash (`/mnt/hd5t/stash/library/`) y `nextcloud/data/` si el operador lo decide. Razones:
   - Borg dedup actúa **dentro** del repo. Un solo repo deduplica entre todo: dumps de BD que comparten cabeceras, configs versionadas, etc. Dos repos pierden esa dedup cruzada (no es enorme, pero es real).
   - Un solo repo implica un solo `rclone sync` al offsite, una sola passphrase a custodiar, una sola operación de `prune`/`compact`, un solo `borg check --verify-data` mensual.
   - Cuando el operador quiera respaldar `library/` de Stash offsite (decisión personal, $30/mes en B2 para 5 TB), basta con añadir un segundo `repositories:` al mismo `borgmatic.yml`. No hace falta segundo doc.
2. **Repo cifrado con `repokey-blake2`**, passphrase de 384 bits de entropía, custodia triple (KeePassXC + papel en sobre cerrado + Vaultwarden cuando esté). Decisiones razonadas en [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §6.1–§6.2. **No** se cambia aquí.
3. **Compresión `zstd,3`** (no `lz4`, no `zstd,9`). `zstd` nivel 3 da una ratio de compresión ~30% mejor que `lz4` con un overhead de CPU manejable para la Pi 5 (8 GB, 4× Cortex-A76 a 2.4 GHz). `zstd,9` o `zstd,22` empuja el ratio unos puntos más a costa de **multiplicar** el tiempo de backup en ARM64 sin AES-NI. El sweet spot empírico en Pi 5 es `zstd,3`.
4. **Tres timers** `systemd`, no uno. [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §4.1 fija las cadencias diaria/semanal/mensual. Cada cadencia tiene su propio timer que apunta al **mismo** `borgmatic.yml` con flags distintos: `borgmatic create --files-cache=ctime,size` (diaria), `borgmatic create --stats` (semanal con métricas extra), `borgmatic check --verify-data` (mensual). Separar en tres units permite logs separados (`journalctl -u borgmatic-daily.timer`), retries independientes, y desactivar uno sin tocar los otros (p. ej., desactivar el `verify-data` mensual mientras se hace una migración pesada de hd2t). Detallado en §8.
5. **Hooks de BD declarativos para Postgres/MariaDB/SQLite, hooks `before_backup` libres para el resto.** Borgmatic 1.8+ trae soporte nativo para los tres motores: él se encarga del comando, del path del dump, de comprimir y de borrar tras snapshot. Para Pi-hole (`pihole -a -t teleporter`), Caddy (`caddy adapt --pretty`), Tailscale (`tailscale status --json`), Unbound (`unbound-control dump_cache`), Authelia (más complejo: `db.sqlite3` + `storage_encryption`) y dpkg (`dpkg -l > packages.txt`) se usan `before_backup` libres con comandos shell. Justificado en §7.
6. **`monitoring_hooks: apprise:` para Telegram + email** y un `after_everything: curl https://kuma.lan/api/push/...` para Uptime Kuma push. Apprise es la vía nativa de Borgmatic; Kuma push se hace con un comando `curl` en `after_everything` porque Borgmatic ≤2.x no tiene un hook nativo de Kuma. Justificado en §11.
7. **Offsite con `rclone sync` en `after_everything`**, no con `borg with-lock` ni con `borg sync`. `rclone` sincroniza el directorio entero del repo Borg (incluyendo `config`, `data/`, `index.*`, `hints.*`, `integrity.*`) hacia el bucket B2. Como el repo Borg ya está cifrado, `rclone` solo mueve blobs cifrados — no hay riesgo de que credenciales B2 leakeen plaintext. Crítico: B2 con **Object Lock** activo o, alternativamente, una `application key` con permisos `writeFiles, readFiles, listFiles` pero **sin** `deleteFiles`. Detalle en §10.
8. **`borgmatic-exporter` como contenedor en el stack `monitoring`**, no en `backups`. Es coherente con [`../05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md): los exporters viven con Prometheus. El exporter es opcional y se configura en §12.
9. **Dos modos de prune: en host (write+delete keys) y en cliente del operador (full-access)**. [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §6.3 describe la defensa contra ransomware: el host empuja al offsite con clave que no puede borrar; el operador, desde su laptop, hace `borg compact` puntualmente con una clave full-access. Implementación en §10.4.
10. **Sin LUKS bajo `hd2t`**. Decisión de [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §6.4. Borg cifra el repo, los dumps en `dumps/` están en `0700 root:root` y la Pi no es escenario de robo físico oportunista. No se reabre aquí.

> **Alcance de red**: Borgmatic no escucha en ningún puerto. Las únicas conexiones son **salientes** desde la Pi: HTTPS hacia Backblaze B2 para `rclone`, HTTPS hacia `https://kuma.lan` (red local) para el push, HTTPS hacia API de Telegram para Apprise. El `ufw` ya configurado en [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §4 (default deny inbound, allow outbound) cubre el caso sin reglas adicionales.

---

## Requisitos Previos

- **[`./01-estrategia-backup.md`](./01-estrategia-backup.md) leída** y la lista de verificación §11 cumplida. En particular: passphrase de Borg **decidida y custodiada antes** de inicializar el repo (§4 de este doc).
- **Estructura de directorios** aplicada según [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md):
  - `/mnt/hd2t/backups/` con propietario `root:root` y modo `700`.
  - Subcarpetas `borg/`, `dumps/{postgresql,mariadb,sqlite,authelia,pihole,caddy,unbound,tailscale,grafana,prometheus}/`, `configs/`, `system/` ya creadas con los mismos permisos.
- **Discos `hd2t` y `hd5t`** montados con `noatime,nofail` según [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md). Verificable con `findmnt /mnt/hd2t /mnt/hd5t` (ambas líneas presentes).
- **Reloj sincronizado por NTP** según [`../01-sistema/02-configuracion-inicial.md`](../01-sistema/02-configuracion-inicial.md). `timedatectl | grep 'System clock synchronized'` debe decir `yes`.
- **Docker Engine + Compose v2** instalados según [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md). Borgmatic los necesita para los hooks `docker exec` contra contenedores de BD.
- **Servicios con BD ya desplegados** que vayan a entrar en backup desde el día 1: como mínimo Authelia ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)) y Uptime Kuma ([`../05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md)). Los hooks de Nextcloud ([`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md)) se activan cuando esa fase 6 esté operativa.
- **Uptime Kuma desplegado** ([`../05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md)) y un monitor "Push" creado dedicado a Borgmatic, con su token (`https://kuma.lan/api/push/<TOKEN>`) anotado.
- **Apprise + Telegram bot** funcionando: bot creado con `@BotFather`, `bot_token` y `chat_id` obtenidos, prueba `curl` de envío de mensaje exitosa. Detalle en §11.1.
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No hay reglas nuevas — todas las conexiones de Borgmatic son salientes.
- **Cuenta de Backblaze B2 creada** (o el proveedor offsite elegido) con un bucket `homelab-borg` ya provisionado y una `application key` con permisos restringidos (§10.2). Si el operador aún no quiere offsite el día 1, se puede levantar Borgmatic solo con repo local y añadir offsite más tarde — el `borgmatic.yml` está pensado para ese movimiento.
- **`~/homelab/` versionado en remoto** (GitHub privado o Gitea propio): `git -C ~/homelab remote -v` debe listar al menos un origin. La definición del homelab vive ahí; Borgmatic respalda los datos.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Implementación | **Borg + Borgmatic nativos en el host** (apt o pipx), `systemd` timers como `root` | Justificado en §0. Variante container disponible pero no por defecto. |
| Versión de Borg | **`≥ 1.2.4`** (la que trae Bookworm en `apt`) | `repokey-blake2` requiere ≥ 1.1; `zstd` requiere ≥ 1.1.4; ambas presentes desde hace años. |
| Versión de Borgmatic | **`≥ 1.7.7`** (apt Bookworm) o **`≥ 1.8.x`** (pipx) | 1.7.7 trae los tres hooks de BD declarativos; 1.8.x trae mejoras de `monitoring_hooks` (Apprise nativo). El YAML documentado funciona en ambas. |
| Vía de instalación | **`apt install borgmatic`** por defecto; **`pipx install borgmatic`** si el operador quiere últimas features | Apt simplifica unattended-upgrades; pipx exige actualizar a mano pero da versión más reciente. Comparación en §2.1. |
| Cifrado del repo | **`repokey-blake2`** | Justificado en [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §6.1. ARM64 sin AES-NI gana ~2× con BLAKE2b vs SHA-256. |
| Compresión | **`zstd,3`** | Sweet spot ratio/CPU en Pi 5. Subir a `zstd,9` duplica tiempo sin ganar mucho. Bajar a `lz4` ahorra CPU pero hincha repo y ancho de banda offsite. |
| Retención | `keep_daily: 7`, `keep_weekly: 4`, `keep_monthly: 6`, `keep_yearly: 1` (GFS) | [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §4.2. ~18 snapshots simultáneos. |
| Cadencia | **Tres timers**: `borgmatic-daily.timer` (03:00 todos los días), `borgmatic-weekly.timer` (03:30 domingos), `borgmatic-monthly.timer` (04:00 día 1 del mes) | [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §4.1. Separar timers permite logs y retries independientes (§8). |
| Hooks de BD | Declarativos vía `postgresql_databases`, `mariadb_databases`, `sqlite_databases` para los servicios soportados | Borgmatic genera el comando `pg_dump`/`mariadb-dump`/`sqlite3 .backup` con los flags correctos. El operador no escribe esos comandos. Detalle en §7.1. |
| Hooks no-BD | `before_backup:` libres con comandos shell para Pi-hole, Caddy, Tailscale, Unbound, Authelia (caso especial) y dpkg | Justificado en §7.2. |
| Lifecycle de `dumps/` | `find /mnt/hd2t/backups/dumps -mtime +14 -delete` en `after_backup` | [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §4.4. 14 días de holgura por si una restauración rápida no quiere pasar por `borg extract`. |
| Notificación | **Apprise** (Telegram + email) en `on_error` y `after_everything`; **Uptime Kuma push** en `after_everything` | [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §9. Heartbeat de éxito, no solo alerta de fallo. Detalle en §11. |
| Offsite | **Backblaze B2** vía `rclone sync` en `after_everything`, bucket en modo Object Lock con `application key` write-only para el host | [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §6.3 y §7. Detalle en §10. |
| Retención offsite | Object Lock 30 días + lifecycle del bucket (versiones >180 días → cold) | Detalle en §10.3. |
| Prune & compact | `borgmatic compact` mensual desde el host (clave write+prune); compactaciones grandes desde el laptop del operador con clave full-access | [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §6.3. Detalle en §10.4. |
| Verificación L1 | `borg check --repository-only` en `after_backup` (cada noche) | Diaria, ~2 min, valida estructura del repo sin leer blobs. |
| Verificación L2 | `borg check --verify-data` en timer mensual | [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §8.2. Lee y verifica HMAC de todos los blobs. Lento (horas) pero detecta bit-rot. Detalle en §13. |
| Verificación L3 | Smoke test mensual de restauración manual o semi-automática | Procedimiento en [`./03-backup-docker-volumes.md`](./03-backup-docker-volumes.md). En este doc se documenta el script de soporte (§13.3). |
| Permisos del config | `/etc/borgmatic/config.yaml` modo `600 root:root` | Contiene paths sensibles y la passphrase si se inlinea (que no se inlinea: va en `BORG_PASSPHRASE_FILE`). |
| Custodia de la passphrase | KeePassXC + papel en sobre cerrado **+** Vaultwarden cuando esté ([`../11-productividad/01-vaultwarden.md`](../11-productividad/01-vaultwarden.md)) | [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §6.2. Triple custodia es el mínimo. |
| Logs | `journalctl -u borgmatic-*.service` (rotación gestionada por journald) **+** `/var/log/borgmatic.log` con `logrotate` semanal | systemd ya rota; el fichero externo ayuda a `tail -f` y a archivarlo en `/mnt/hd2t/backups/system/` para historico. |
| Monitorización Prometheus | **Opcional**: `borgmatic-exporter` en stack `monitoring`, scrapeado cada 60s, dashboard Grafana custom | Detalle en §12. Si el operador no lo quiere, basta con el push de Kuma. |
| Tamaño esperado del repo (régimen) | ~30-100 GB para el set típico del homelab tras 1 año de uso (sin `nextcloud/data/` masivo, sin `media/`) | Borg dedup + `zstd,3` da ratios de ~5-8× sobre datos de homelab típicos (configs, dumps, secrets, archivos pequeños del operador). |
| Tamaño primer backup | ~5-15 GB en runs típicos (Authelia, Kuma, configs, secrets, `~/homelab/`); >100 GB si entran `services/` ya populados con Nextcloud / Syncthing | Tarda **horas** la primera vez. Programar manual fuera de los timers. |

---

## 1. Arquitectura

### 1.1. Diagrama de flujo

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Pi 5 (host)                                                                  │
│                                                                              │
│  /etc/borgmatic/config.yaml        ─── (read by borgmatic)                   │
│  /etc/borgmatic/.passphrase        600 root:root  (BORG_PASSPHRASE_FILE)     │
│                                                                              │
│  systemd:                                                                    │
│    borgmatic-daily.timer    → borgmatic-daily.service                        │
│    borgmatic-weekly.timer   → borgmatic-weekly.service                       │
│    borgmatic-monthly.timer  → borgmatic-monthly.service                      │
│                                                                              │
│  borgmatic-daily.service:                                                    │
│    ExecStart=/usr/bin/borgmatic --verbosity 1 \                              │
│              --syslog-verbosity 0 create prune compact                       │
│                                                                              │
│      ┌──────────────────────────────────────────────────────────────────┐    │
│      │ before_everything: curl https://kuma.lan/api/push/<T>?status=up  │    │
│      │ before_backup hooks (orden de declaración):                      │    │
│      │   ├─ docker exec authelia /scripts/backup.sh                     │    │
│      │   ├─ docker exec pihole pihole -a -t                             │    │
│      │   ├─ caddy adapt --config /etc/caddy/Caddyfile --pretty          │    │
│      │   ├─ tailscale status --json > .../tailscale/status.json         │    │
│      │   ├─ unbound-control dump_cache > .../unbound/cache.dump         │    │
│      │   └─ dpkg -l > .../system/packages-$(date +%F).txt               │    │
│      │ postgresql_databases hook (si Nextcloud está activo): pg_dump    │    │
│      │ mariadb_databases hook (si Bookstack está activo): mariadb-dump  │    │
│      │ sqlite_databases hook (Vaultwarden, Kuma): sqlite3 .backup       │    │
│      │                                                                  │    │
│      │ borg create <repo>::{hostname}-{now}  (snapshot)                 │    │
│      │ borg prune --keep-daily 7 --keep-weekly 4 ...                    │    │
│      │ borg compact (cada N días, controlado por flag)                  │    │
│      │ borg check --repository-only                                     │    │
│      │                                                                  │    │
│      │ after_backup hooks:                                              │    │
│      │   └─ find /mnt/hd2t/backups/dumps -mtime +14 -delete             │    │
│      │ after_everything hooks:                                          │    │
│      │   ├─ rclone sync /mnt/hd2t/backups/borg/ b2:homelab-borg/        │    │
│      │   └─ curl https://kuma.lan/api/push/<T>?status=up&msg=OK&ping=N  │    │
│      │ on_error hook:                                                   │    │
│      │   ├─ apprise -t "BACKUP FAILED" -b "<journal tail>" tgram://...  │    │
│      │   └─ curl https://kuma.lan/api/push/<T>?status=down&msg=FAIL     │    │
│      └──────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  Repo local: /mnt/hd2t/backups/borg/  (root:root 700)                        │
│       ├─ config        (Borg metadata, passphrase-cifrada)                   │
│       ├─ data/         (chunks cifrados con AES-CTR + HMAC)                  │
│       ├─ index.<id>    (índice de chunks)                                    │
│       ├─ integrity.<id>                                                      │
│       └─ hints.<id>                                                          │
└─────────────────────────┬────────────────────────────────────────────────────┘
                          │ rclone sync (HTTPS, AWS SigV4 → B2)
                          ▼
                ┌──────────────────────────────┐
                │  Backblaze B2                │
                │  bucket: homelab-borg        │
                │  - Object Lock (compliance)  │
                │  - lifecycle: 30d retention  │
                │  - app key write-only        │
                └──────────────────────────────┘
```

### 1.2. Ciclo de vida de un snapshot

1. `borgmatic-daily.timer` dispara `borgmatic-daily.service` a las 03:00.
2. El servicio invoca `borgmatic --verbosity 1 create prune compact`.
3. Borgmatic carga `/etc/borgmatic/config.yaml`, valida sintaxis y resuelve variables.
4. **`before_everything`**: `curl` push "up&msg=started" a Kuma (heartbeat de inicio; si Kuma está caído, Borgmatic NO falla — el `--continue-on-error` default del hook lo absorbe).
5. **`before_backup`** (orden de declaración del YAML): cada hook escribe su dump en `/mnt/hd2t/backups/dumps/<servicio>/...`. Si un hook falla con exit ≠ 0, Borgmatic aborta y dispara `on_error`.
6. **Hooks declarativos de BD**: Borgmatic invoca internamente `pg_dump`/`mariadb-dump`/`sqlite3 .backup` para cada BD declarada y guarda el dump en un directorio temporal (`/root/.borgmatic/<engine>_databases/<host>/<db>`) que se incluye automáticamente como `source_directory`.
7. **`borg create`**: snapshot con nombre `{hostname}-{now:%Y-%m-%dT%H:%M:%S}`. Borg detecta chunks ya presentes (dedup) y solo escribe los nuevos.
8. **`borg prune`**: aplica la retención GFS, marca como "podables" los snapshots que ya no entran en `keep_daily/keep_weekly/keep_monthly/keep_yearly`. **No** libera espacio físico todavía.
9. **`borg compact`**: libera el espacio de los blobs huérfanos (referenced-by-zero) tras el prune. Costoso en disco; el daily lo ejecuta solo si `--compact-threshold` se cumple.
10. **`borg check --repository-only`**: valida estructura del repo (no lee blobs). Rápido.
11. **`after_backup`**: limpia `dumps/` con >14 días.
12. **`after_everything`**: `rclone sync` al offsite + push de éxito a Kuma + notificación Apprise (success heartbeat al email).
13. Si **algo falla** en pasos 4-11: salta a `on_error` con `apprise` + push "down" a Kuma.

### 1.3. Por qué el comando es `create prune compact` (en ese orden)

Tres acciones de Borg encadenadas en una invocación. El orden importa:

- `create`: hace el snapshot.
- `prune`: marca obsoletos los que ya no caben en la retención.
- `compact`: libera el espacio.

Sin `compact`, el repo crece monotonamente (los blobs marcados por `prune` siguen ocupando disco hasta que algún `compact` los pase por la guillotina). Sin `prune`, `compact` no tiene nada que compactar. Sin `create`, no hay snapshot.

Borgmatic ejecuta los tres como subcomandos de un solo proceso. Si uno falla, los siguientes **no** se ejecutan (`--no-create-output-on-success` y compañía no afectan al control de flujo). Esto es lo deseable: si el `create` falla, no queremos que `prune` borre el snapshot del día anterior dejándonos con menos copias todavía.

---

## 2. Instalación de Borg y Borgmatic

### 2.1. Vía apt (recomendada por defecto)

Raspberry Pi OS Bookworm 64-bit incluye en `apt`:

- `borgbackup` (Borg) ≥ 1.2.4
- `borgmatic` ≥ 1.7.7

Ambos son suficientes para el `borgmatic.yml` documentado aquí.

```bash
sudo apt update
sudo apt install -y borgbackup borgmatic

# Verificación.
borg --version    # esperado: borg 1.2.x
borgmatic --version    # esperado: 1.7.x o superior
```

Ventajas:

- `unattended-upgrades` ([`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §6) cubre los parches de seguridad sin acción manual.
- Dependencias (Python 3.11, `python3-yaml`, `python3-jsonschema`, etc.) gestionadas por apt.
- Coherente con el resto del host (todos los demonios del host vienen de apt).

Inconvenientes:

- Versión "frozen" en la release de Debian. Las features de Borgmatic 1.8.x (mejoras en `monitoring_hooks`, mejor handling de errores en hooks declarativos de BD, soporte directo para `apprise:` como sub-bloque de `monitoring_hooks`) llegan tarde o no llegan hasta la siguiente Debian.
- Si el operador necesita un hook nuevo que solo trae 1.8.x, tendrá que ir a pipx.

### 2.2. Vía pipx (si se quiere última Borgmatic)

`pipx` instala paquetes Python en venvs aislados con sus binarios en `$HOME/.local/bin/` (o `/opt/pipx` si se usa `--global`).

```bash
sudo apt install -y pipx
sudo pipx ensurepath --global

# Borg sigue viniendo de apt (lo más estable; pipx solo para borgmatic).
sudo apt install -y borgbackup

# Borgmatic más reciente.
sudo pipx install --global borgmatic

borgmatic --version    # esperado: 1.8.x o 2.x
```

> **Por qué Borg sigue por apt**: Borg no se beneficia tanto de versiones nuevas como Borgmatic. El formato del repo es estable en 1.x, y Borg 2.x (cuando salga estable) traerá un nuevo formato que requerirá migración explícita — momento en el que el operador se moverá conscientemente. Mientras tanto, Borg 1.2.x de apt es más que suficiente.

> **`pipx --global`**: instala en `/opt/pipx/venvs/borgmatic/` con `/usr/local/bin/borgmatic` como entry point. Sin `--global`, queda en `~/.local/bin/borgmatic` del usuario que ejecutó pipx — pero el systemd unit corre como `root`, así que necesita la versión global. **Importante**.

### 2.3. Decisión por defecto

En este doc se asume **`apt install borgmatic` (1.7.7)**. Todo lo documentado funciona en ambas versiones. Si el operador prefiere pipx, el único cambio práctico es `which borgmatic` → `/usr/local/bin/borgmatic` en lugar de `/usr/bin/borgmatic`; el path va al `ExecStart=` de los systemd units (§8).

---

## 3. Estructura de ficheros

```
/etc/borgmatic/                               root:root  700
├── config.yaml                               root:root  600   # YAML principal
├── .passphrase                               root:root  600   # passphrase del repo Borg
└── snippets/                                 root:root  700   # opcional, includes
    ├── databases-postgresql.yaml
    ├── databases-mariadb.yaml
    └── databases-sqlite.yaml

/mnt/hd2t/backups/                            root:root  700
├── borg/                                                       # Repo Borg (gestionado por Borgmatic)
├── dumps/                                                      # Dumps generados por hooks
│   ├── postgresql/
│   ├── mariadb/
│   ├── sqlite/
│   ├── authelia/
│   ├── pihole/
│   ├── caddy/
│   ├── unbound/
│   ├── tailscale/
│   ├── grafana/
│   └── prometheus/
├── configs/                                                    # Snapshots de configs versionables
└── system/                                                     # Estado del host

/mnt/hd2t/services/borgmatic/                 root:root  700
├── rclone.conf                               root:root  600   # credenciales B2
└── logs/                                     root:root  700
    └── borgmatic.log                                          # log persistente (logrotate semanal)

/etc/systemd/system/                          root:root  755
├── borgmatic-daily.service
├── borgmatic-daily.timer
├── borgmatic-weekly.service
├── borgmatic-weekly.timer
├── borgmatic-monthly.service
└── borgmatic-monthly.timer

/etc/logrotate.d/borgmatic                    root:root  644   # rotación del log persistente
```

> **Por qué `/etc/borgmatic/` y no `/mnt/hd2t/services/borgmatic/`**: el config y la passphrase deben estar disponibles **antes** de que `/mnt/hd2t` se monte (durante boot temprano). Si `hd2t` no monta y Borgmatic está en hd2t, no se puede ni diagnosticar el problema con `borgmatic info`. Convención Linux: configuración del demonio en `/etc/`, datos en `/var/` o un mount dedicado. `borgmatic.yml` es config; el repo es dato.

> **Por qué `rclone.conf` en `/mnt/hd2t/services/borgmatic/`**: las credenciales B2 son grandes y rotables; mantenerlas separadas del config principal facilita rotación sin tocar `borgmatic.yml`. El path es absoluto en el `after_everything` hook (§10.3).

### 3.1. Crear la estructura

```bash
sudo install -d -o root -g root -m 700 /etc/borgmatic
sudo install -d -o root -g root -m 700 /etc/borgmatic/snippets
sudo install -d -o root -g root -m 700 /mnt/hd2t/services/borgmatic
sudo install -d -o root -g root -m 700 /mnt/hd2t/services/borgmatic/logs

# Las rutas /mnt/hd2t/backups/{borg,dumps,configs,system} ya están creadas
# por ../01-sistema/04-estructura-directorios.md §4.4. Verificar:
sudo ls -ld /mnt/hd2t/backups /mnt/hd2t/backups/{borg,dumps,configs,system}
# Esperado: drwx------ root root para todas.

# Subcarpetas de dumps por servicio.
sudo install -d -o root -g root -m 700 \
  /mnt/hd2t/backups/dumps/{postgresql,mariadb,sqlite,authelia,pihole,caddy,unbound,tailscale,grafana,prometheus}
```

---

## 4. Generación y custodia de la passphrase

### 4.1. Generar la passphrase

**Una sola vez en la vida del repo**. Cambiar la passphrase después es posible (`borg key change-passphrase`) pero costoso.

```bash
# Generar 48 bytes aleatorios → ~64 caracteres base64 → ~384 bits de entropía.
sudo umask 077
openssl rand -base64 48 | tr -d '\n' > /etc/borgmatic/.passphrase

# Verificar tamaño y permisos.
sudo wc -c /etc/borgmatic/.passphrase     # 64 bytes
sudo ls -l /etc/borgmatic/.passphrase     # -rw------- root root

# Mostrar para anotarla en KeePassXC y en papel.
sudo cat /etc/borgmatic/.passphrase ; echo
```

### 4.2. Triple custodia (obligatoria antes de inicializar)

[`./01-estrategia-backup.md`](./01-estrategia-backup.md) §6.2. Antes de inicializar el repo, la passphrase debe estar:

1. **En KeePassXC** del operador (o gestor offline equivalente), entrada "Homelab — Borg passphrase".
2. **En papel impreso** dentro de un sobre cerrado, etiquetado "Homelab Borg passphrase — fecha", guardado físicamente fuera de casa (oficina, casa familiar, caja de seguridad).
3. **(Cuando Vaultwarden esté desplegado)** en Vaultwarden ([`../11-productividad/01-vaultwarden.md`](../11-productividad/01-vaultwarden.md)) como cuarta copia. Importante: Vaultwarden vive en el mismo homelab; su backup es Borg. Vaultwarden **no puede** ser la única custodia (loop circular).

Si el operador no tiene los tres lugares listos, **detenerse aquí**. Inicializar Borg sin custodia es la receta perfecta para descubrir, dentro de seis meses, que no se puede leer el repo cuando hace falta.

> **Si se llega a perder la passphrase**: el repo es ilegible. **No hay recovery**. Borg cifra con AES-CTR + HMAC-SHA-256 (o BLAKE2b) usando una clave maestra cifrada por la passphrase. No hay backdoor, no hay reset.

---

## 5. Inicialización del repo

```bash
# Cargar passphrase en el entorno desde el fichero (para esta sesión).
sudo -i
export BORG_PASSPHRASE=$(cat /etc/borgmatic/.passphrase)
export BORG_REPO=/mnt/hd2t/backups/borg

borg init --encryption=repokey-blake2 "$BORG_REPO"

# Verificar.
borg info "$BORG_REPO"
# Salida: información del repo, "Encryption: Authenticated BLAKE2b". Sin snapshots.

# Listar archivos del repo.
ls -la "$BORG_REPO"
# Esperado: config, data/, index.<id>, integrity.<id>, hints.<id>, nonce, README

exit  # salir del shell de root.
```

> **Importante**: `borg init` se ejecuta una sola vez. Re-ejecutarlo sobre un repo existente no destruye datos (Borg lo detecta y aborta), pero es señal de que algo se ha mezclado. Si por error se generó un repo en una ruta equivocada (p. ej. dentro de `dumps/`), `sudo rm -rf <ruta_errónea>` y volver a empezar.

### 5.1. Exportar la clave maestra (recomendado)

`repokey-blake2` guarda la clave maestra cifrada **dentro** del repo. Si el repo se corrompe a nivel de fichero `config`, la clave puede perderse aunque la passphrase sea correcta. Mitigación:

```bash
sudo -i
export BORG_PASSPHRASE=$(cat /etc/borgmatic/.passphrase)
borg key export /mnt/hd2t/backups/borg /root/borg-key-export.txt

# El fichero contiene la clave en texto (cifrada con la passphrase, pero
# legible si la passphrase está comprometida). Guardar igual que la passphrase:
# - copia en KeePassXC como adjunto.
# - copia impresa en QR en sobre cerrado (cabe holgadamente en QR de error correction H).

# Eliminar del disco temporal.
sudo shred -u /root/borg-key-export.txt
exit
```

Sin la clave exportada y con `config` del repo dañado, ni siquiera con la passphrase correcta se descifra. Con la clave exportada y la passphrase, se reconstruye con `borg key import`.

---

## 6. Configuración: `/etc/borgmatic/config.yaml`

Config canónica. Aplicar con `sudo install -m 600 -o root -g root borgmatic.yaml /etc/borgmatic/config.yaml` o equivalente. Las decisiones por bloque están comentadas in-line.

```yaml
# /etc/borgmatic/config.yaml
# Borgmatic >= 1.7.7. Modo: borg + repo local + offsite via rclone (after_everything).
# Cada bloque está justificado en docs/07-backups/02-borgmatic.md sección correspondiente.

# ─── Fuentes ────────────────────────────────────────────────────────────────
source_directories:
  # Definición del homelab (compose, Caddyfile, configuration.yml).
  - /home/homelab/homelab

  # Configs del sistema.
  - /etc

  # Datos de servicios (todos los stacks).
  - /mnt/hd2t/services

  # Datos de usuario y sync.
  - /mnt/hd2t/sync

  # Dumps generados por before_backup (los hooks declarativos los añaden solos
  # internamente; estos son para los hooks libres que escriben en /mnt/hd2t/backups/dumps/).
  - /mnt/hd2t/backups/dumps
  - /mnt/hd2t/backups/configs
  - /mnt/hd2t/backups/system

  # Home de root (claves SSH del operador root, si las hay).
  - /root/.ssh

# ─── Exclusiones ────────────────────────────────────────────────────────────
exclude_patterns:
  # El propio repo Borg (loop si se incluye).
  - /mnt/hd2t/backups/borg

  # Multimedia voluminosa: no entra al repo principal.
  - /mnt/hd2t/services/jellyfin/cache
  - /mnt/hd2t/services/jellyfin/transcodes
  - /mnt/hd2t/services/jellyfin/metadata/library
  - /mnt/hd2t/services/navidrome/cache
  - /mnt/hd2t/services/audiobookshelf/cache
  - /mnt/hd2t/services/calibre-web/cache
  - /mnt/hd2t/services/transmission/downloads/incomplete

  # Caches y thumbs regenerables.
  - '**/.cache'
  - '**/Cache'
  - '**/cache_*'
  - '**/thumbnails'
  - '**/preview'
  - '**/lost+found'

  # Logs voluminosos (journald ya rota; no respaldamos /var/log).
  - /var/log
  - /var/cache
  - /var/tmp
  - /tmp

  # Swap, lost+found, montajes ajenos.
  - /swapfile
  - /mnt/hd5t        # disco de Stash; NO respaldar la library multimedia desde el repo principal.
  - /proc
  - /sys
  - /dev

  # Repo git de homelab (los blobs ya viven en GitHub; meta como reflog/objects no aporta).
  - /home/homelab/homelab/.git/objects
  - /home/homelab/homelab/.git/logs

  # Syncthing: índices regenerables y .stversions (redundante con Borg).
  - /mnt/hd2t/services/syncthing/config/index-*.db
  - /mnt/hd2t/sync/**/.stversions
  - /mnt/hd2t/sync/**/.stfolder

  # Nextcloud appdata previews (regenerables).
  - /mnt/hd2t/services/nextcloud/data/appdata_*/preview

exclude_caches: true              # respeta CACHEDIR.TAG
exclude_if_present:               # respeta marcadores explícitos
  - .nobackup
  - .backupignore
exclude_nodump: true              # respeta el flag nodump del FS

# ─── Repositorios ───────────────────────────────────────────────────────────
repositories:
  - path: /mnt/hd2t/backups/borg
    label: local

# (Opcional) Si el operador quiere segundo repo Borg directo a un servidor SSH
# remoto (p. ej. otro Pi o rsync.net), añadir aquí:
#   - path: ssh://u123456@u123456.your-storagebox.de:23/./homelab-borg
#     label: storagebox

# ─── Cifrado y compresión ───────────────────────────────────────────────────
encryption_passphrase: '{credential file /etc/borgmatic/.passphrase}'
compression: zstd,3

# ─── Política de retención (GFS) ────────────────────────────────────────────
keep_within: 1d                   # mantiene siempre los snapshots de las últimas 24h aunque haya muchos
keep_daily: 7
keep_weekly: 4
keep_monthly: 6
keep_yearly: 1
prefix: '{hostname}-'             # el prune solo afecta a snapshots con este prefijo (seguridad: si hay mezclados de otro host, no los toca)

# ─── Verificación ───────────────────────────────────────────────────────────
checks:
  - name: repository
    frequency: 1 day             # check --repository-only diaria (rápida)
  - name: archives
    frequency: 7 days            # listado de archivos coherente, semanal
  - name: data
    frequency: 30 days           # --verify-data: re-lee todos los blobs (lento, mensual)

# ─── Comportamiento de Borg ─────────────────────────────────────────────────
files_cache: ctime,size          # más rápido que mtime,size,inode en filesystems con noatime
relocated_repo_access_is_ok: false
unknown_unencrypted_repo_access_is_ok: false
ssh_command: ssh -o StrictHostKeyChecking=accept-new

# ─── Hooks de bases de datos (declarativos) ─────────────────────────────────
# PostgreSQL: Nextcloud (cuando esté desplegado en Fase 6).
postgresql_databases:
  - name: nextcloud
    hostname: postgres-nextcloud   # nombre del contenedor; resuelto por DNS Docker dentro de la red `homelab`
    port: 5432
    username: nextcloud
    password: '{credential file /mnt/hd2t/services/nextcloud/secrets/postgres_password}'
    format: custom                 # pg_dump --format=custom
    options: --no-owner --no-privileges
    # Si el operador prefiere "all databases" del cluster:
    # name: all

# MariaDB: Bookstack, Mealie, otros (Fase 11).
mariadb_databases:
  - name: bookstack
    hostname: mariadb-bookstack
    port: 3306
    username: bookstack
    password: '{credential file /mnt/hd2t/services/bookstack/secrets/db_password}'
    options: --single-transaction --routines --triggers --events

# SQLite: Authelia, Vaultwarden, Uptime Kuma, FreshRSS, Linkding.
sqlite_databases:
  - name: authelia
    path: /mnt/hd2t/services/auth/authelia/config/db.sqlite3
  - name: uptime-kuma
    path: /mnt/hd2t/services/monitoring/uptime-kuma/data/kuma.db
  - name: vaultwarden
    path: /mnt/hd2t/services/vaultwarden/data/db.sqlite3
  - name: linkding
    path: /mnt/hd2t/services/linkding/data/db.sqlite3
  - name: freshrss
    path: /mnt/hd2t/services/freshrss/data/db.sqlite

# ─── Hooks pre/post-backup (libres) ─────────────────────────────────────────
before_everything:
  # Heartbeat de inicio a Uptime Kuma (no falla si Kuma está caído).
  - 'curl -fsS --max-time 10 "https://kuma.lan/api/push/CHANGE_ME?status=up&msg=started&ping=" || true'

before_backup:
  # Authelia: además del db.sqlite3 (cubierto por sqlite_databases), copiamos el
  # storage_encryption junto al dump. Sin storage_encryption, el db.sqlite3 es ilegible.
  - 'cp /mnt/hd2t/services/auth/secrets/storage_encryption /mnt/hd2t/backups/dumps/authelia/storage_encryption-$(date +%F)'
  - 'chmod 600 /mnt/hd2t/backups/dumps/authelia/storage_encryption-$(date +%F)'

  # Pi-hole: teleporter zip.
  - 'docker exec pihole pihole -a -t /tmp/pihole-teleporter.zip 2>/dev/null && docker cp pihole:/tmp/pihole-teleporter.zip /mnt/hd2t/backups/dumps/pihole/teleporter-$(date +%F).zip'

  # Caddy: reificar el Caddyfile (resuelve snippets, imports, variables).
  - 'docker exec caddy caddy adapt --config /etc/caddy/Caddyfile --pretty > /mnt/hd2t/backups/dumps/caddy/caddyfile-$(date +%F).json'

  # Tailscale: snapshot del estado del tailnet visto desde la Pi.
  - 'tailscale status --json > /mnt/hd2t/backups/dumps/tailscale/status-$(date +%F).json 2>/dev/null || true'

  # Unbound: cache dump (no crítico; permite "calentar" el cache tras restart).
  - 'docker exec unbound unbound-control dump_cache > /mnt/hd2t/backups/dumps/unbound/cache-$(date +%F).dump 2>/dev/null || true'

  # Grafana: copia del SQLite (Grafana lo respeta gracias a WAL).
  - 'cp /mnt/hd2t/services/monitoring/grafana/data/grafana.db /mnt/hd2t/backups/dumps/grafana/grafana-$(date +%F).db 2>/dev/null || true'

  # Sistema: lista de paquetes instalados.
  - 'dpkg -l > /mnt/hd2t/backups/system/packages-$(date +%F).txt'
  - 'cp /etc/fstab /mnt/hd2t/backups/system/fstab-$(date +%F)'
  - 'sudo ufw status verbose > /mnt/hd2t/backups/system/ufw-status-$(date +%F).txt 2>/dev/null || true'

  # Snapshot del compose entero del homelab (útil en disaster recovery).
  - 'tar czf /mnt/hd2t/backups/configs/homelab-$(date +%F).tar.gz -C /home/homelab homelab --exclude=".git/objects" --exclude=".git/logs"'

after_backup:
  # Lifecycle de dumps/: borrar lo de >14 días.
  - 'find /mnt/hd2t/backups/dumps -type f -mtime +14 -delete'
  # Lifecycle de configs/: borrar lo de >90 días.
  - 'find /mnt/hd2t/backups/configs -type f -mtime +90 -delete'
  # Lifecycle de system/: borrar lo de >180 días.
  - 'find /mnt/hd2t/backups/system -type f -mtime +180 -delete'

after_everything:
  # Sincronizar el repo Borg al offsite B2.
  - 'rclone --config /mnt/hd2t/services/borgmatic/rclone.conf sync /mnt/hd2t/backups/borg/ b2:homelab-borg/ --transfers=4 --checkers=8 --bwlimit "08:00,2M 22:00,off"'

  # Heartbeat de éxito a Uptime Kuma con duración medida (Borgmatic exporta {borgmatic.archive_size} si está disponible; en 1.7 usamos un timestamp simple).
  - 'curl -fsS --max-time 10 "https://kuma.lan/api/push/CHANGE_ME?status=up&msg=OK&ping=" || true'

on_error:
  # Notificar a Telegram + email vía Apprise.
  - 'apprise -t "❌ BACKUP FAILED" -b "$(journalctl -u borgmatic-daily.service -n 20 --no-pager | tail -c 3500)" --config /etc/borgmatic/apprise.yaml'
  # Push de fallo a Kuma.
  - 'curl -fsS --max-time 10 "https://kuma.lan/api/push/CHANGE_ME?status=down&msg=FAILED" || true'

# ─── Notificaciones (Apprise nativo) ────────────────────────────────────────
# Borgmatic >= 1.7 trae integración nativa con Apprise:
apprise:
  services:
    - url: 'tgram://CHANGE_BOT_TOKEN/CHANGE_CHAT_ID'
      label: 'Telegram operador'
    # SMTP relay (opcional, si se ha configurado msmtp).
    # - url: 'mailto://CHANGE_user:pass@smtp.gmail.com?to=ops@example.com'
    #   label: 'Email ops'
  states:
    - fail
    - finish      # heartbeat de éxito al canal email; el push de Kuma cubre el de Telegram.
  start:
    title: '🟡 Homelab backup started'
    body: 'Borgmatic en {hostname} ha iniciado el backup.'
  finish:
    title: '✅ Homelab backup OK'
    body: 'Backup completo en {hostname}.'
  fail:
    title: '❌ Homelab backup FAILED'
    body: 'Backup ha fallado en {hostname}. Revisar journalctl -u borgmatic-daily.service.'

# ─── Logging ────────────────────────────────────────────────────────────────
# Borgmatic loguea siempre a syslog/journald. Adicionalmente, log persistente:
syslog_verbosity: 0
log_file: /mnt/hd2t/services/borgmatic/logs/borgmatic.log
log_file_verbosity: 1
```

> **Antes de aplicar**: sustituir `CHANGE_ME`, `CHANGE_BOT_TOKEN` y `CHANGE_CHAT_ID` por los valores reales (Kuma push token §11.2, Telegram bot token y chat_id §11.1).

> **Validar**:
> ```bash
> sudo borgmatic config validate -c /etc/borgmatic/config.yaml
> ```
> Sin output = config OK. Con errores = revisar línea reportada.

### 6.1. Por qué `prefix: '{hostname}-'`

`borg prune` con `--prefix homelab-pi5-` solo aplica retención a snapshots cuyo nombre empieza por ese prefix. Si en el futuro el operador comparte el mismo repo entre varios hosts (otro Pi, un VPS, un laptop con sus propios snapshots), el prune del Pi 5 no toca los del laptop. Sin prefix, el prune borraría snapshots ajenos. Borgmatic establece automáticamente el `archive_name_format` con `{hostname}-{now}`, así que el prefix coincide.

### 6.2. Por qué `files_cache: ctime,size`

Borg compara los ficheros del filesystem con los del último snapshot para decidir cuáles re-procesar (chunking + dedup). Las heurísticas:

- `mtime,size`: rápida pero falla si una herramienta modifica el contenido sin tocar mtime (raro pero pasa con `cp -p` y similares).
- `ctime,size`: fiable; ctime cambia con cualquier modificación del inodo.
- `mtime,size,inode`: añade comparación de inode; útil en filesystems donde inodes se reciclan, pero más lenta y `noatime` no afecta.
- `disabled`: re-procesa todo cada vez. Catastrófico para repos grandes en una Pi.

`ctime,size` es el sweet spot para `noatime` ext4 en `hd2t`/`hd5t`.

### 6.3. Por qué `'{credential file ...}'` y no `BORG_PASSPHRASE`

Borgmatic 1.7+ resuelve `'{credential file <path>}'` leyendo el contenido del fichero como secreto, sin imprimirlo nunca en logs. Dos ventajas frente a la variable de entorno `BORG_PASSPHRASE`:

1. La variable de entorno aparece en `ps -ef` y en `/proc/<pid>/environ` para procesos que se ramifican (rare pero posible vector).
2. El fichero `0600 root:root` es auditable: cualquier acceso queda en `auditd` si se monitoriza.

El equivalente para Borgmatic <1.7 sería `encryption_passcommand: 'cat /etc/borgmatic/.passphrase'`. Funciona también.

---

## 7. Hooks por servicio

### 7.1. Hooks declarativos de BD (Borgmatic los gestiona)

Borgmatic se encarga de:

1. **Antes del backup**: levantar el dump de cada BD declarada en un directorio temporal (`/root/.borgmatic/<engine>_databases/<host>/<db>` o equivalente) con los flags correctos.
2. **Durante el backup**: incluir ese directorio temporal como `source_directory` implícito.
3. **Después del backup**: limpiar el directorio temporal.

Los flags por motor coinciden con [`./01-estrategia-backup.md`](./01-estrategia-backup.md) §5.2:

| Motor | Comando que Borgmatic genera | Notas |
|---|---|---|
| **PostgreSQL** | `pg_dump --format=custom --no-owner --no-privileges <db>` (o `pg_dumpall` si `name: all`) | `format: custom` configurado en YAML, `--no-owner --no-privileges` en `options:`. |
| **MariaDB** | `mariadb-dump --single-transaction --routines --triggers --events <db>` | `--single-transaction` en `options:`. Sin lockear InnoDB. |
| **SQLite** | `sqlite3 <path> ".backup '<destino>'"` | API nativa, consistente. |

> **Cuando un servicio no está desplegado todavía**: comentar el bloque correspondiente en `borgmatic.yml`. Borgmatic falla si trata de conectar a un host inexistente.

### 7.2. Hooks libres (`before_backup`)

Para servicios sin BD relacional o con artefactos no-BD que conviene materializar antes del snapshot:

| Servicio | Hook | Por qué |
|---|---|---|
| **Authelia** | `cp .../secrets/storage_encryption .../dumps/authelia/storage_encryption-<fecha>` | El `db.sqlite3` (cubierto por `sqlite_databases:`) es ilegible sin el `storage_encryption`. Deben respaldarse **juntos**, fechados, en el mismo directorio. |
| **Pi-hole** | `pihole -a -t` (genera teleporter zip con todo: gravity, listas, settings) | Formato canónico de Pi-hole para backup/restore portable. Mejor que respaldar `gravity.db` y `pihole.toml` por separado. |
| **Caddy** | `caddy adapt --config /etc/caddy/Caddyfile --pretty > caddyfile-<fecha>.json` | El JSON resuelve `import`s, snippets, variables. Útil para diagnóstico sin necesidad de los snippets originales. |
| **Tailscale** | `tailscale status --json > status-<fecha>.json` | Captura el tailnet desde la Pi. Útil para reconstruir routing si se reflashea sin hacer `tailscale logout`. |
| **Unbound** | `unbound-control dump_cache > cache-<fecha>.dump` | Permite "calentar" el cache tras restart o restore (no crítico, pero rápido). |
| **Grafana** | `cp grafana.db dumps/grafana/grafana-<fecha>.db` | Grafana usa SQLite WAL; un `cp` es seguro. Alternativa más correcta: `sqlite3 .backup`, pero el WAL hace que `cp` baste en >99% de los casos. |
| **Sistema** | `dpkg -l > packages-<fecha>.txt`, `cp /etc/fstab fstab-<fecha>`, `ufw status verbose > ufw-status-<fecha>.txt` | Estado del host fuera de los servicios; lo primero que se mira en disaster recovery (qué paquetes había instalados). |
| **Compose homelab** | `tar czf homelab-<fecha>.tar.gz ...` | Snapshot del repo `~/homelab/` excluyendo `.git/objects` (ya en GitHub). Permite reconstruir el homelab sin red. |

### 7.3. Hooks que **no** se hacen aquí

Algunos servicios tienen formatos de backup propios que conviene usar (en lugar de respaldar el directorio crudo). Se documentan en sus respectivos docs y aquí se enumeran como referencia:

- **Home Assistant** (Fase 8): la propia HA tiene su sistema de "snapshots/backups" vía API. Se documentará en `../08-domotica/01-home-assistant.md`. Borgmatic no lo cubre; HA empuja sus backups a `/mnt/hd2t/backups/dumps/homeassistant/` y Borg los archiva.
- **Stash** (Fase 9): la UI de Stash tiene `Settings > Library > Backup`. Genera un fichero `.sqlite` portátil. Se programa en su propio cron interno y se deja en `/mnt/hd2t/backups/dumps/stash/`.
- **Zigbee2MQTT** (Fase 8): tiene `coordinator_backup.json` (estado del coordinador Zigbee). Sin él, perder la radio Zigbee implica re-pairing manual de cada dispositivo. Se respalda copiando del directorio del servicio (entra como parte de `/mnt/hd2t/services/zigbee2mqtt/`) y adicionalmente con un `before_backup` que llama al endpoint MQTT `zigbee2mqtt/bridge/request/backup` (cuando se documente).

---

## 8. systemd timers

### 8.1. Tres units, tres timers

[`./01-estrategia-backup.md`](./01-estrategia-backup.md) §4.1 fija las cadencias. Cada cadencia tiene su `.service` + `.timer`. El comando que ejecutan difiere ligeramente:

| Timer | Cuándo dispara | Comando | Logs |
|---|---|---|---|
| `borgmatic-daily.timer` | Todos los días 03:00 | `borgmatic --verbosity 1 create prune compact` | `journalctl -u borgmatic-daily.service` |
| `borgmatic-weekly.timer` | Domingos 03:30 | `borgmatic --verbosity 1 --stats create prune compact` | `journalctl -u borgmatic-weekly.service` |
| `borgmatic-monthly.timer` | Día 1 del mes 04:00 | `borgmatic --verbosity 1 check --check repository --check archives --check data` | `journalctl -u borgmatic-monthly.service` |

### 8.2. `/etc/systemd/system/borgmatic-daily.service`

```ini
[Unit]
Description=Borgmatic backup (daily)
Documentation=https://torsion.org/borgmatic/
After=network-online.target docker.service
Wants=network-online.target
RequiresMountsFor=/mnt/hd2t

[Service]
Type=oneshot
User=root
Group=root
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
LockPersonality=true
NoNewPrivileges=true
ProtectClock=true
ProtectHostname=true
ProtectKernelLogs=true
ProtectKernelModules=true
ProtectKernelTunables=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
SystemCallArchitectures=native
# El kill timeout debe permitir al menos un "borg compact" largo en la primera ejecución.
TimeoutStopSec=30min

ExecStartPre=/usr/bin/test -f /etc/borgmatic/config.yaml
ExecStartPre=/usr/bin/test -d /mnt/hd2t/backups/borg
ExecStart=/usr/bin/borgmatic --verbosity 1 --syslog-verbosity 0 create prune compact

[Install]
WantedBy=multi-user.target
```

### 8.3. `/etc/systemd/system/borgmatic-daily.timer`

```ini
[Unit]
Description=Borgmatic backup timer (daily 03:00)
Documentation=https://torsion.org/borgmatic/

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=15min     # evitar que múltiples Pi en la misma red se sincronicen al milisegundo
Persistent=true              # si la Pi estaba apagada a las 03:00, ejecuta al arrancar
Unit=borgmatic-daily.service

[Install]
WantedBy=timers.target
```

### 8.4. Variantes weekly y monthly

`borgmatic-weekly.service` idéntico a `borgmatic-daily.service` cambiando solo el `ExecStart=` por:

```
ExecStart=/usr/bin/borgmatic --verbosity 1 --syslog-verbosity 0 --stats create prune compact
```

`borgmatic-weekly.timer`:

```ini
[Timer]
OnCalendar=Sun *-*-* 03:30:00
RandomizedDelaySec=15min
Persistent=true
Unit=borgmatic-weekly.service
```

`borgmatic-monthly.service` cambia el `ExecStart=` por la verificación lenta:

```
ExecStart=/usr/bin/borgmatic --verbosity 1 --syslog-verbosity 0 check --check repository --check archives --check data
TimeoutStopSec=8h
```

`borgmatic-monthly.timer`:

```ini
[Timer]
OnCalendar=*-*-01 04:00:00
RandomizedDelaySec=30min
Persistent=true
Unit=borgmatic-monthly.service
```

### 8.5. Activación

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now borgmatic-daily.timer
sudo systemctl enable --now borgmatic-weekly.timer
sudo systemctl enable --now borgmatic-monthly.timer

# Verificar.
systemctl list-timers borgmatic-*
# Esperado: tres timers, NEXT correctamente calculado.

systemctl status borgmatic-daily.timer
# Esperado: active (waiting), Trigger: <next 03:00>.
```

### 8.6. Por qué tres timers y no uno solo con flags

Alternativa: un único `borgmatic.service` parametrizable por argumento del cron. Razones para separarlos:

1. **Logs separados**. `journalctl -u borgmatic-monthly` solo trae los `verify-data` mensuales; sin separación, hay que filtrar entre días normales y mensuales.
2. **TimeoutStopSec distinto**. El daily debe abortarse si pasa de 30 min (algo se ha quedado colgado). El monthly puede tardar 4–8 h (lectura de todos los blobs); abortarlo a los 30 min lo hace inútil.
3. **Retries independientes**. Si el daily falla, el operador puede `systemctl restart borgmatic-daily.service` sin volver a ejecutar el `check --verify-data` mensual.
4. **Desactivación selectiva**. Durante una migración pesada de hd2t, el operador desactiva solo el monthly (`systemctl stop borgmatic-monthly.timer`) y mantiene el daily/weekly.

---

## 9. Primer backup manual

### 9.1. Probar el config sin disparar el backup completo

```bash
# Validar sintaxis.
sudo borgmatic config validate

# Listar lo que entraría en el backup, sin ejecutarlo (dry run).
sudo borgmatic --verbosity 2 --dry-run create
# Salida: lista de paths que entran/excluyen.
```

### 9.2. Forzar el primer backup manualmente

**Importante**: el primer backup tarda **horas** (Borg sin chunks previos chunkea todo). Programar fuera de horas en las que la Pi vaya a apagarse.

```bash
# Ejecutar el service unit a mano (mismo path que el timer, pero síncrono).
sudo systemctl start borgmatic-daily.service

# Mientras corre, monitorizar:
sudo journalctl -u borgmatic-daily.service -f
```

> **Esperar pacientemente**. Para un set típico (5–10 GB de datos del homelab inicial) en Pi 5 con `zstd,3`:
> - Primera ejecución: 30 min – 4 h (depende del volumen).
> - Segunda ejecución (mismos datos): 1–3 min (todo deduplicado).

### 9.3. Verificar que el snapshot existe

```bash
sudo borg list /mnt/hd2t/backups/borg
# Salida: una línea con homelab-pi5-YYYY-MM-DDTHH:MM:SS.

sudo borg info /mnt/hd2t/backups/borg
# Salida: Original size, Compressed size, Deduplicated size, ratios.
```

### 9.4. Listar el contenido de un snapshot

```bash
sudo borgmatic list --archive 'homelab-pi5-2026-01-15T03:00:00' --find '/etc/ssh/ssh_host_ed25519_key'
# Esperado: línea del fichero con su tamaño y fecha.
```

---

## 10. Offsite con Backblaze B2

### 10.1. Crear bucket y application key

En la consola de Backblaze:

1. **Bucket**: `homelab-borg`. Tipo: `Private`. Object Lock: `Compliance` (no se puede borrar antes de N días aunque la app key tenga delete). Retención por defecto: 30 días (mismo orden que la retención weekly).
2. **Application Key**:
   - **Nombre**: `homelab-pi5-borg-host`.
   - **Bucket**: solo `homelab-borg`.
   - **Capabilities**: `listFiles`, `readFiles`, `writeFiles`, `listBuckets`. **NO** activar `deleteFiles` ni `deleteKeys`. Sin `deleteFiles`, un atacante en la Pi no puede borrar lo ya subido. La compactación (que sí necesita borrar) se hace desde el laptop con otra app key (§10.4).
   - Anotar `keyID` y `applicationKey`. **No** se vuelven a mostrar.

### 10.2. Configurar `rclone`

```bash
sudo umask 077
sudo install -d -o root -g root -m 700 /mnt/hd2t/services/borgmatic
sudo touch /mnt/hd2t/services/borgmatic/rclone.conf
sudo chmod 600 /mnt/hd2t/services/borgmatic/rclone.conf
sudo chown root:root /mnt/hd2t/services/borgmatic/rclone.conf
```

Contenido (`/mnt/hd2t/services/borgmatic/rclone.conf`):

```ini
[b2]
type = b2
account = CHANGE_KEY_ID
key = CHANGE_APPLICATION_KEY
hard_delete = false
```

> **`hard_delete = false`**: importante. Con `false`, `rclone sync` deja "hidden markers" en lugar de borrar; B2 mantiene las versiones según lifecycle. Con `true`, borraría definitivamente. Combinado con la app key sin `deleteFiles`, en la práctica no se borra nada.

Test:

```bash
sudo rclone --config /mnt/hd2t/services/borgmatic/rclone.conf lsd b2:
# Esperado: listado de buckets, incluyendo homelab-borg.

sudo rclone --config /mnt/hd2t/services/borgmatic/rclone.conf ls b2:homelab-borg/ | head
# Inicialmente vacío; tras el primer rclone sync, lista los blobs del repo Borg.
```

### 10.3. Sincronización inicial (siembra)

La primera réplica al offsite va a ser grande (todo el repo Borg). Hacerla con bandwidth limit nocturno.

```bash
sudo rclone --config /mnt/hd2t/services/borgmatic/rclone.conf sync \
  /mnt/hd2t/backups/borg/ b2:homelab-borg/ \
  --transfers 4 --checkers 8 \
  --bwlimit "08:00,2M 22:00,off" \
  --progress
# Esperado: completa en una o varias noches según volumen y conexión.
```

Tras la siembra inicial, el `after_everything` hook hace `rclone sync` cada noche, subiendo solo blobs nuevos (Borg dedup ⇒ habitualmente decenas de MB).

### 10.4. Compactación desde el laptop del operador (clave full-access)

El host `pi5` empuja con clave write-only. La compactación periódica (`borg compact` que libera espacio liberando blobs huérfanos en el offsite) requiere borrar versiones, lo cual el host **no puede**. Procedimiento mensual:

1. En la consola de B2, generar una segunda application key `homelab-laptop-compact` con permisos `listFiles, readFiles, writeFiles, deleteFiles` sobre `homelab-borg`. La clave **vive solo en el laptop del operador**, en KeePassXC.
2. En el laptop:
   ```bash
   rclone config  # crear remote 'b2-compact' con esa key
   # Sincronizar el repo Borg local desde B2 al laptop (read-only desde B2).
   rclone copy b2-compact:homelab-borg /mnt/external/homelab-borg-mirror --transfers 4
   # Compactar el mirror local.
   borg compact /mnt/external/homelab-borg-mirror
   # Re-subir las diferencias (deletes incluidos).
   rclone sync /mnt/external/homelab-borg-mirror b2-compact:homelab-borg --transfers 4
   ```
3. Anotar fecha y resultado en `~/homelab/operations/borg-compact.log`.

> **Frecuencia recomendada**: trimestral. La compactación libera espacio que el `prune` ha marcado como huérfano. Sin compact, el repo crece linealmente con el número de operaciones hasta que se compacta. Tres meses = una compactación bien aprovechada.

### 10.5. Si el operador no quiere offsite el primer día

Comentar el `rclone sync` en `after_everything` del YAML. Levantar Borgmatic solo con repo local. Añadir B2 cuando el operador esté listo (semanas o meses después). El `borgmatic.yml` está pensado para ese movimiento sin reescribirlo.

---

## 11. Notificaciones

### 11.1. Apprise: Telegram + email

Apprise es un wrapper Python que habla con N servicios de notificación. Se instala con apt:

```bash
sudo apt install -y apprise
apprise --version
```

#### 11.1.1. Crear bot de Telegram

1. En Telegram, hablar con `@BotFather`. Comando `/newbot`. Anotar el `bot_token`.
2. Crear un canal o usar el chat directo con el bot. Para obtener el `chat_id`, mandar un mensaje al bot y luego:
   ```bash
   curl -s "https://api.telegram.org/bot<BOT_TOKEN>/getUpdates" | jq '.result[].message.chat.id'
   ```
3. Probar:
   ```bash
   apprise -t 'Test' -b 'Hola desde Pi 5' "tgram://${BOT_TOKEN}/${CHAT_ID}"
   ```

#### 11.1.2. Conectar al `borgmatic.yml`

El bloque `apprise:` del YAML (§6) ya define el canal Telegram. Sustituir `CHANGE_BOT_TOKEN` y `CHANGE_CHAT_ID`. Borgmatic invoca Apprise internamente.

Para el email opcional, configurar `msmtp` o usar `mailto://` directo de Apprise:

```yaml
apprise:
  services:
    - url: 'mailto://user:apppassword@smtp.gmail.com:587?to=ops@example.com'
      label: 'Email ops'
```

### 11.2. Uptime Kuma push monitor

[`../05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md) §8.3 lista el monitor `borgmatic` previsto. Cambio respecto a lo planeado: tipo **Push** en lugar de **Docker container** (porque Borgmatic es nativo en host, no contenedor).

Pasos:

1. En la UI de Uptime Kuma (`https://uptime.lan`): **+ Add New Monitor → Push**.
2. **Friendly Name**: `borgmatic-daily`.
3. **Heartbeat Interval**: `86400` seg (1 día) + **Heartbeat Retry Interval**: `3600` seg.
4. Guardar. Kuma genera URL: `https://uptime.lan/api/push/<TOKEN>?status=up&msg=OK&ping=`.
5. Anotar `<TOKEN>` y sustituir `CHANGE_ME` en los hooks `before_everything`/`after_everything`/`on_error` del `borgmatic.yml`.

> **Frecuencia del push**: 1 push por ejecución diaria. Si Kuma deja de recibir tras 24h+1h de retry, dispara la notificación (Telegram). Esto cubre el caso "Borgmatic no se ejecutó porque el timer se desactivó".

### 11.3. Heartbeat de éxito vs alerta de fallo

[`./01-estrategia-backup.md`](./01-estrategia-backup.md) §9.2: alertar solo en fallo es insuficiente. Si el cron no se ejecuta, no falla — simplemente no manda nada. Por eso:

| Canal | Cuándo dispara |
|---|---|
| **Apprise → Telegram** | `on_error` (alerta inmediata). |
| **Apprise → email** | `finish` (heartbeat de éxito) + `fail` (alerta). El email diario "OK" es la forma de saber que el cron funciona. |
| **Uptime Kuma push** | `before_everything` (start) + `after_everything` (success). Kuma decide si llegó a tiempo. |

Doble canal protege contra "el SMTP de Gmail está caído justo cuando todo se rompe" — Telegram independiente.

---

## 12. Monitorización con Prometheus (opcional)

### 12.1. Por qué `borgmatic-exporter`

Métricas históricas: tamaño del repo, número de snapshots, ratio de dedup, duración del último backup. Útiles para detectar tendencias (ej. "el repo crece 50 MB/día desde la actualización X" señala que algo nuevo no está siendo deduplicado).

### 12.2. Despliegue del exporter

Imagen sugerida: [`ghcr.io/maxim25/borg-exporter`](https://github.com/maxim25/borg-exporter). Se añade al stack `monitoring` en su `docker-compose.yml`:

```yaml
borgmatic-exporter:
  image: ghcr.io/maxim25/borg-exporter:latest
  container_name: borgmatic-exporter
  restart: unless-stopped
  user: "0:0"
  read_only: true
  tmpfs:
    - /tmp
  environment:
    BORG_REPO: /backups/borg
    BORG_PASSPHRASE_FILE: /run/secrets/borg_passphrase
    BORG_RELOCATED_REPO_ACCESS_IS_OK: "yes"
  volumes:
    - /mnt/hd2t/backups/borg:/backups/borg:ro
    - /etc/borgmatic/.passphrase:/run/secrets/borg_passphrase:ro
  networks:
    - homelab
  mem_limit: 128m
  labels:
    com.centurylinklabs.watchtower.enable: "true"
```

Y se añade un scrape job en `prometheus.yml`:

```yaml
- job_name: borgmatic
  scrape_interval: 60s
  scrape_timeout: 30s
  static_configs:
    - targets: ['borgmatic-exporter:9099']
```

### 12.3. Dashboard Grafana

Importar [Grafana #14489 "BorgBackup"](https://grafana.com/grafana/dashboards/14489-borgbackup/) o crear uno simple con paneles:

- Tamaño del repo (last + delta).
- Número de snapshots (gauge).
- Ratio de dedup (gauge, ideal >5×).
- Duración del último backup (gauge).
- Tiempo desde el último backup OK (alerta si > 25h).

---

## 13. Verificación periódica

### 13.1. L1 — diaria (post-backup)

Ya cubierta por el `borgmatic-daily.service`: el comando incluye `borg check --repository-only` implícito vía la sección `checks:` del YAML (§6). Valida estructura del repo. Rápido (~2 min).

### 13.2. L2 — mensual (`--verify-data`)

Ya cubierta por `borgmatic-monthly.service` (§8.4). El `check --check data` lee y verifica HMAC de **todos** los blobs. Lento (3–8 h en Pi 5 con repo de ~50 GB). Detecta bit-rot del filesystem.

### 13.3. L3 — smoke test mensual (manual o semi-automático)

Procedimiento detallado en [`./03-backup-docker-volumes.md`](./03-backup-docker-volumes.md). Resumen:

1. Elegir un servicio pequeño con datos críticos. Rotación: Vaultwarden (mes 1), Authelia (mes 2), Bookstack (mes 3), Nextcloud-mini (mes 4).
2. Listar snapshots:
   ```bash
   sudo borgmatic list
   ```
3. Extraer:
   ```bash
   sudo install -d -o root -g root -m 700 /mnt/hd2t/backups/restore-test
   sudo borgmatic extract \
     --archive 'homelab-pi5-2026-01-14T03:00:00' \
     --path mnt/hd2t/services/auth \
     --destination /mnt/hd2t/backups/restore-test/authelia-2026-01-15
   ```
4. Inspeccionar manualmente: `db.sqlite3` legible, `storage_encryption` presente, `users_database.yml` íntegro.
5. Si es BD: levantar contenedor temporal apuntando al directorio extraído, verificar login.
6. Limpiar:
   ```bash
   sudo rm -rf /mnt/hd2t/backups/restore-test/authelia-2026-01-15
   ```
7. Anotar en `~/homelab/operations/restore-tests.log`: fecha, servicio, resultado, hallazgos.

### 13.4. Script de soporte (opcional)

`~/homelab/operations/scripts/borg-smoke-test.sh`:

```bash
#!/usr/bin/env bash
# Smoke test mensual de Borgmatic.
# Uso: sudo ./borg-smoke-test.sh <servicio> [<snapshot>]
set -euo pipefail

SERVICE="${1:?Uso: $0 <servicio> [<snapshot>]}"
SNAPSHOT="${2:-$(borgmatic list --json | jq -r '.[0].archives[-1].name')}"
DEST="/mnt/hd2t/backups/restore-test/${SERVICE}-$(date +%F)"

mkdir -p "$DEST"
borgmatic extract --archive "$SNAPSHOT" --path "mnt/hd2t/services/${SERVICE}" --destination "$DEST"
echo "Extraído $SERVICE@$SNAPSHOT en $DEST"
echo "Inspeccionar manualmente; tras OK: rm -rf $DEST"
```

---

## 14. Restauración

### 14.1. Restaurar un fichero suelto

```bash
sudo borgmatic extract \
  --archive 'homelab-pi5-2026-01-14T03:00:00' \
  --path mnt/hd2t/services/nextcloud/data/user1/files/important.pdf \
  --destination /tmp/restore
# El fichero queda en /tmp/restore/mnt/hd2t/services/nextcloud/data/user1/files/important.pdf

sudo cp /tmp/restore/mnt/hd2t/services/nextcloud/data/user1/files/important.pdf \
  /mnt/hd2t/services/nextcloud/data/user1/files/important.pdf
sudo chown nextcloud:nextcloud ...   # ajustar al UID del servicio
```

### 14.2. Restaurar una BD desde dump

Los hooks declarativos de BD generan dumps que Borg archiva automáticamente. Para restaurar:

```bash
# 1. Listar el snapshot deseado.
sudo borgmatic list

# 2. Extraer el dump (path interno: depende del motor; ver /tmp tras el borgmatic restore).
sudo borgmatic restore \
  --archive 'homelab-pi5-2026-01-14T03:00:00' \
  --database authelia
# Borgmatic invoca internamente `sqlite3 .restore` apuntando al servicio destino.
```

> **`borgmatic restore`** es el camino correcto para BD declaradas en `postgresql_databases:`/`mariadb_databases:`/`sqlite_databases:`. Internamente sabe el destino (path o host:port) y los flags. **Nunca** tirar `borg extract` + `psql` a mano si el path original es de un dump declarativo — Borgmatic encapsula el ciclo `dump → snapshot → extract → restore`.

### 14.3. Disaster recovery completo

Ver [`../13-operaciones/02-disaster-recovery.md`](../13-operaciones/02-disaster-recovery.md). Resumen:

1. Recuperar passphrase (KeePassXC / sobre / Vaultwarden).
2. Recuperar repo: si `hd2t` sobrevive, está en `/mnt/hd2t/backups/borg/`. Si no, tirar de B2:
   ```bash
   rclone --config rclone.conf sync b2:homelab-borg/ /mnt/hd2t/backups/borg/
   ```
3. Reflashear microSD, aplicar fases 0-2 (sistema, docker, red).
4. `git clone` de `~/homelab/`.
5. `sudo borgmatic extract --archive <último> --destination /` para restaurar todo. Cuidado con permisos.
6. Levantar stacks fase por fase, verificar.

---

## 15. Lista de Verificación

Antes de dejar Borgmatic en producción:

- [ ] `borg --version` y `borgmatic --version` muestran ≥ 1.2 y ≥ 1.7.7 respectivamente.
- [ ] `/etc/borgmatic/config.yaml` existe, modo `600 root:root`, `borgmatic config validate` pasa sin errores.
- [ ] `/etc/borgmatic/.passphrase` existe, modo `600 root:root`, contenido en KeePassXC + papel + (Vaultwarden si está).
- [ ] `borg key export` ejecutado y resultado custodiado igual que la passphrase.
- [ ] `sudo borg info /mnt/hd2t/backups/borg` muestra repo inicializado con `repokey-blake2`, sin snapshots aún.
- [ ] Primer backup manual exitoso: `sudo borgmatic --verbosity 1 create` completa en X horas. `sudo borgmatic list` muestra al menos un snapshot.
- [ ] `/mnt/hd2t/backups/dumps/<servicio>/` contiene los dumps recién generados (`ls -la`).
- [ ] Los tres timers están activos: `systemctl list-timers borgmatic-*` muestra `daily`, `weekly`, `monthly` con próximos NEXT correctos.
- [ ] `journalctl -u borgmatic-daily.service -n 50` muestra el último run sin errores.
- [ ] `rclone --config /mnt/hd2t/services/borgmatic/rclone.conf ls b2:homelab-borg/` lista blobs (siembra inicial completa).
- [ ] Telegram recibe el mensaje "Backup OK" tras un run manual. Email recibe el heartbeat de éxito.
- [ ] Uptime Kuma muestra el monitor `borgmatic-daily` en verde, con last heartbeat reciente.
- [ ] Smoke test L3 ejecutado al menos una vez con éxito. Anotado en `~/homelab/operations/restore-tests.log`.
- [ ] (Si aplica) Dashboard Grafana "BorgBackup" muestra métricas correctas tras el primer scrape.
- [ ] Calendario del operador tiene recordatorio mensual: smoke test rotando servicio + compact desde laptop.

---

## 16. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `borgmatic config validate` falla con `'<value>' is not of type 'string'` | Tipos cambiados entre versiones (1.7 → 1.8). Por ejemplo `compression` esperaba string, ahora también acepta dict. | Pegar el YAML actual en [el validador online de Borgmatic](https://torsion.org/borgmatic/) o `borgmatic config validate --config <path>` con `--verbosity 2`. Suele ser comilla o tipo. |
| `borg create` falla con `Repository <ruta> already exists.` durante `borg init` | El repo ya estaba inicializado. | Es esperado en re-init. No re-inicializar. Si por error se intentó en un repo nuevo y quedó vacío: `sudo rm -rf /mnt/hd2t/backups/borg/* && borg init ...`. **NO** sobre un repo con datos. |
| `borg create` falla con `Permission denied` leyendo algún path | El path tiene `0700` con propietario que no es root, o `borgmatic` no se ejecuta como root. | Verificar `id` dentro del unit (`User=root`). Si la fuente es de otro UID con `0700`, añadirla a `exclude_patterns` o ajustar permisos. |
| El primer backup tarda >24h | Esperado en runs frescos sin dedup previo. | No abortarlo. Si es realmente excesivo (>48h), revisar I/O wait con `iotop`, descartar fallo de hd2t con `smartctl -a`. |
| `dumps/<servicio>/` se llena de ficheros antiguos | El `after_backup` no se está ejecutando. Posibles causas: el daily falló antes de llegar al hook; el hook tiene un typo. | Ver `journalctl -u borgmatic-daily.service`. Limpieza puntual: `sudo find /mnt/hd2t/backups/dumps -mtime +14 -delete`. |
| `borg check --verify-data` reporta corrupción | Bit-rot en hd2t o write error silencioso. | **Inmediato**: parar timers (`systemctl stop borgmatic-daily.timer borgmatic-weekly.timer borgmatic-monthly.timer`). Restaurar desde offsite (`rclone sync b2:homelab-borg/ /mnt/hd2t/backups/borg-restored/`). Comparar. Investigar `dmesg` y SMART de hd2t. |
| Smoke test L3 falla pero los daily backups pasan "OK" | El L1 (`--repository-only`) no detecta inconsistencias semánticas. Un dump puede estar corrupto pero el repo Borg que lo contiene "estructuralmente íntegro". | Para eso existe el L3. Investigar el servicio concreto, posiblemente añadir un `before_backup` que falte o un check post-dump (`[ -s file ] || exit 1`). |
| Uptime Kuma no recibe el heartbeat tras el backup | `after_everything` falló o `https://kuma.lan` no resuelve desde el host (no está en Pi-hole, o CA interna no confiada por curl). | Probar manualmente: `sudo curl -fsv https://kuma.lan/api/push/<TOKEN>?status=up`. Si falla por TLS, importar CA interna en `/usr/local/share/ca-certificates/` y `update-ca-certificates`. Si falla por DNS, añadir registro en Pi-hole. Detalle en [`../03-red/04-caddy.md`](../03-red/04-caddy.md). |
| `rclone sync` al offsite tarda 6-8h cada noche | El `compact` del repo Borg ha movido blobs ⇒ rclone los reconcilia. | Aceptarlo en runs puntuales tras compact. Si es persistente, programar `compact` solo trimestralmente (no en cada daily). |
| `apprise` falla con `Unsupported Notify Service URL` | El URL tiene typo o la versión de apprise no soporta ese plugin. | `apprise --info <url>` muestra qué entiende. Para Telegram: `tgram://${BOT_TOKEN}/${CHAT_ID}` (no `://bot${TOKEN}`). |
| Telegram no llega aunque `apprise -t test -b test 'tgram://...'` funciona desde shell | Probable: el config `apprise:` del YAML tiene formato distinto al CLI. | Comparar con `borgmatic config schema` y la doc de Borgmatic 1.7+. En 1.8+ es `monitoring_hooks: apprise:`; en 1.7 es `apprise:` top-level. |
| systemd timer "Persistent=true" no dispara al arrancar tras una caída | El timestamp de "última ejecución" se ha perdido en `/var/lib/systemd/timers/`. | `sudo touch /var/lib/systemd/timers/stamp-borgmatic-daily.timer && systemctl restart borgmatic-daily.timer`. |
| El `borgmatic-exporter` reporta `Repository check failed: passphrase incorrect` | El `BORG_PASSPHRASE_FILE` montado tiene un newline final que el binario no tolera. | Regenerar la passphrase sin newline: `openssl rand -base64 48 \| tr -d '\n' > .passphrase`. **Sin** `echo` ni redirección con newline. |
| Olvidé la passphrase de Borg | Sin passphrase, el repo es ilegible. | **Triple custodia obligatoria** (§4.2). Si se ha llegado aquí, el backup local está perdido. Si la passphrase se reconstruye desde otra fuente (Vaultwarden), volver a inyectarla. Si no, replantear: el repo es papel. |
| Cambio el path del repo a otra ruta y los snapshots "se pierden" | Borg identifica el repo por su `id` interno (en `<repo>/config`), no por la ruta. Cambiar la ruta es seguro siempre que se mueva el directorio entero (no se re-inicialice). | Mover con `mv` (no `cp`+`rm`), actualizar `repositories:` en `borgmatic.yml`, hacer `sudo borg info <nueva ruta>` para verificar que el id es el mismo. |
| `borg compact` falla con `Repository is in append-only mode` | Se ha activado `append_only` sobre el repo (configuración avanzada anti-ransomware). El host no puede compactar. | Compactar **manualmente** desde el laptop con clave full-access (§10.4). |

---

## Referencias

- [BorgBackup — documentación oficial](https://borgbackup.readthedocs.io/)
- [Borgmatic — documentación oficial](https://torsion.org/borgmatic/)
- [Borgmatic — referencia de configuración (todas las claves)](https://torsion.org/borgmatic/docs/reference/configuration/)
- [Borg — `borg init` y modos de cifrado](https://borgbackup.readthedocs.io/en/stable/usage/init.html)
- [Borg — `borg create`, `prune`, `compact`](https://borgbackup.readthedocs.io/en/stable/usage/create.html)
- [Borg — `borg check`](https://borgbackup.readthedocs.io/en/stable/usage/check.html)
- [Apprise — notificaciones unificadas](https://github.com/caronc/apprise)
- [Apprise — Telegram service](https://github.com/caronc/apprise/wiki/Notify_telegram)
- [rclone — Backblaze B2 backend](https://rclone.org/b2/)
- [Backblaze B2 — Object Lock](https://www.backblaze.com/cloud-storage/file-lock)
- [systemd.timer — manpage](https://www.freedesktop.org/software/systemd/man/systemd.timer.html)
- [Uptime Kuma — Push monitor](https://github.com/louislam/uptime-kuma/wiki/Monitor)
- [borg-exporter (Prometheus)](https://github.com/maxim25/borg-exporter)
- [BLAKE2 — RFC 7693](https://datatracker.ietf.org/doc/html/rfc7693)
