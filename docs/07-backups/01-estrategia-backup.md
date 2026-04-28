# Estrategia de Copias de Seguridad

## Descripción

Las fases 0–6 dejan el homelab funcional: hardware preparado, sistema base, Docker, red, seguridad, monitorización y servicios de almacenamiento (Nextcloud + Postgres + Redis, Samba, Syncthing, MinIO). A partir de aquí los datos del operador empiezan a vivir en `/mnt/hd2t/apps/<servicio>/...`: bases de datos SQLite (Authelia, Uptime Kuma, FreshRSS, Linkding, Mealie, Calibre-Web, Stash en parte), bases de datos relacionales (`nextcloud-db` Postgres 16, futuras MariaDB/Postgres de Bookstack, Paperless-ngx), datos planos (configs, Caddyfile, Pi-hole `pihole-FTL.db`, ficheros Nextcloud, librería Syncthing) y objetos S3 (MinIO).

Sin un plan formal de backups, todo eso depende de un único punto de fallo: el HDD `hd2t`. El primer cable USB defectuoso, un `rm -rf` mal puesto o un fallo silencioso del filesystem se llevan por delante años de configuración y datos. Este documento **no despliega ninguna herramienta**; lo que hace es **fijar las decisiones de fondo** para que `02-borgmatic.md` y `03-backup-docker-volumes.md` se limiten a implementar:

1. **Regla 3-2-1 aterrizada al homelab**: cuáles son las **3** copias, en qué **2** soportes distintos y cuál es la **1** copia offsite. No se trata de citar el principio: se trata de mapear cada bit del homelab a una localización concreta.
2. **Inventario por niveles (tiers) de criticidad**: qué entra en el backup, qué se excluye y por qué. La librería multimedia de Stash en `hd5t` (5 TB) y los `downloads/` no se respaldan; los **metadatos** y configuraciones de servicios sí. La distinción se decide aquí, no en cada documento de servicio.
3. **Destinos físicos**: `/mnt/hd2t/backups/borg/` como repo Borg local primario (ya creado en `04-estructura-directorios.md`), un proveedor S3 compatible (Backblaze B2 por defecto, Cloudflare R2 / Wasabi como alternativas) como destino offsite vía `rclone` (o Borg sobre `rclone serve`), y la opción reabrible de un disco USB externo de "frío" para la copia de seguridad de los secretos críticos.
4. **Programación, retención y RPO/RTO**: cadencia GFS (Grandfather-Father-Son) — 7 diarios, 4 semanales, 12 mensuales, 2+ anuales —, ventana horaria nocturna, objetivos de pérdida máxima de datos (RPO ≤ 24 h) y de tiempo máximo de recuperación (RTO ≤ 4 h para servicios críticos, ≤ 24 h para el resto).
5. **Pre/post hooks**: política de **dumps consistentes** de bases de datos antes de Borg (Postgres `pg_dump --format=custom`, MariaDB/MySQL `mysqldump --single-transaction`, SQLite `.backup` en lugar de copia en caliente del fichero) y limpieza posterior. Aquí se establece el principio; los hooks YAML concretos viven en `02-borgmatic.md` y los procedimientos manuales en `03-backup-docker-volumes.md`.
6. **Cifrado y custodia de claves**: Borg con `repokey-blake2` para el repo local, contraseña fuerte en `secrets/`, y `rclone crypt` (o equivalente) para el bucket offsite. Las passphrase **nunca** viven en el mismo soporte que el repo; se respaldan fuera de banda.
7. **Verificación**: el principio "**un backup no probado no es un backup**" se traduce en cadencias concretas de `borg check`, `borg extract --dry-run`, *restore drill* trimestral a un directorio scratch, y exposición del estado a Prometheus / Uptime Kuma para alertar.

Cuando este documento se aplique, no hay nada nuevo "instalado" — es una **decisión escrita**. Lo que cambia es que los siguientes dos documentos de la fase tienen un marco claro: `02-borgmatic.md` decide *cómo* y `03-backup-docker-volumes.md` decide *qué procedimientos manuales*. Ambos derivan de aquí.

> **Recordatorio de alcance**: el homelab es solo **LAN + Tailscale**. El destino offsite **sí** sale a internet (es su definición), pero como cliente saliente: el host hace pull/push contra el proveedor S3 con credenciales propias, y la Pi sigue sin abrir puertos al exterior. El proveedor offsite no necesita acceso a la LAN; solo necesita aceptar conexiones HTTPS entrantes desde la Pi.

---

## Requisitos Previos

- **Fase 0–1** completas. En particular `04-estructura-directorios.md`:
  - `/mnt/hd2t/backups/borg/` (`0700 homelab:homelab`) listo y vacío.
  - `/mnt/hd2t/backups/dumps/` (`0700`) listo para los pre-hooks.
  - `/mnt/hd2t/backups/exports/` (`0750`) para exports manuales (no automáticos).
  - `/home/homelab/homelab/secrets/` (`0700`) preparado para passphrase y claves API offsite.
- **Fase 2** completa: convenciones de stacks, `homelab.backup=true|false` como label de servicio (definida en la plantilla `02-estructura-compose.md`).
- **Fase 5** completa: Prometheus + Uptime Kuma + Dozzle. Los backups exponen métricas y los logs serán observables por el operador.
- **Fase 6** completa: MinIO operativo (la decisión sobre si MinIO se usa como *staging* offsite o no se cierra aquí).
- Servicios desplegados con datos relevantes en `/mnt/hd2t/apps/`:
  - **SQLite single-file**: `authelia/data/db.sqlite3`, `uptime-kuma/data/kuma.db`, *(futuros)* `linkding`, `freshrss`, `mealie`, `calibre-web`, `stash`.
  - **Postgres**: `nextcloud-db` (`postgres:16-alpine`).
  - **MariaDB / Postgres**: *(futuros)* `bookstack-db`, `paperless-db`, etc.
  - **Redis**: `nextcloud-redis`, `authelia-redis` con `appendonly yes`.
  - **TSDB**: `prometheus/data/` (Prometheus). No se respalda como backup convencional (ver más abajo).
  - **Datos sin BBDD**: ficheros Nextcloud (`apps/nextcloud/data/`), Pi-hole (`pihole-FTL.db` SQLite), Caddyfile, configuración de Samba, librerías de Syncthing, buckets MinIO.
- Cuenta activa en al menos un proveedor S3 compatible para offsite (Backblaze B2 recomendado por coste — ~6 USD/TB/mes — y compatibilidad). Las claves API se generan con permiso solo sobre **un** bucket dedicado al homelab (principio de mínimo privilegio).

---

## La regla 3-2-1 aplicada al homelab

La regla 3-2-1 dice: **3** copias de los datos, en **2** soportes distintos, con **1** copia offsite. Se traduce concretamente:

| Copia | Dónde | Soporte | Frecuencia | Quién la mantiene |
|---|---|---|---|---|
| **#1 Datos primarios** | `/mnt/hd2t/apps/<servicio>/...` y `/mnt/hd5t/...` | HDD USB 2 TB y HDD USB 5 TB | Tiempo real (los servicios escriben en vivo) | Cada servicio. **No es backup**, es el dato. |
| **#2 Backup local** | `/mnt/hd2t/backups/borg/` | El **mismo** HDD `hd2t` que `#1` | Diaria, automática | Borgmatic (`02-borgmatic.md`) |
| **#3 Backup offsite** | Bucket S3-compatible cifrado (Backblaze B2 / Cloudflare R2 / Wasabi) | Soporte distinto (CDN del proveedor) y ubicación geográfica distinta | Diaria, automática | `rclone` (o Borg sobre `rclone serve`) tras `borgmatic` |

> **Tensión #2 vs regla**: la regla 3-2-1 estricta exige que las dos copias locales estén en **soportes distintos**. Aquí la copia #2 vive en el mismo `hd2t` que los datos primarios, lo que viola el espíritu si `hd2t` falla por completo. Se acepta conscientemente con dos compensaciones: (a) el offsite #3 cubre el escenario "muere `hd2t`"; (b) se deja **reabierta** la opción de un tercer disco USB externo (USB stick o HDD pequeño) para una copia adicional "fría" rotada manualmente cada mes. Esa copia opcional se documenta como *postergable* y se cierra cuando el operador decida si compra el disco. Hasta entonces, el offsite es la red de seguridad real.

> **Tensión `hd5t`**: la librería multimedia de Stash en `hd5t` **no entra en backup**. Es voluminosa (TB) y reconstituible desde la fuente externa. Lo que sí se respalda son los **metadatos** de Stash (catálogo, miniaturas, tags editados a mano), que `04-estructura-directorios.md` ya aterriza en `/mnt/hd2t/apps/stash/`. Si `hd5t` falla, el catálogo Stash sobrevive y la biblioteca se re-importa desde la fuente. Si lo que falla es `hd2t`, los metadatos los reconstruye el offsite. Si fallan **ambos** discos al mismo tiempo (escenario incendio / robo), el offsite restaura los metadatos y la biblioteca de `hd5t` se asume perdida.

> **Reabierto**: si en algún momento un segundo nodo MinIO se monta en otra máquina física dentro de la LAN, se puede usar como tercer destino reduciendo la presión sobre el offsite. No aplica hoy.

---

## Inventario por niveles de criticidad

No todo se respalda igual. La política se decide en cuatro tiers, y las labels `homelab.backup=true|false` y la separación `data/` vs `cache/` que `04-estructura-directorios.md` introdujo permiten aplicarla con reglas simples en Borgmatic (Fase 7.2).

| Tier | Criterio | Ejemplos | Política |
|---|---|---|---|
| **T1 — Crítico** | Pérdida = imposible de reconstruir o costoso (días-semanas de trabajo). Suele incluir secretos y BBDD. | Vaultwarden (futuro), Authelia `db.sqlite3` + secretos, Nextcloud Postgres + ficheros, Bookstack BBDD (futuro), Paperless-ngx (futuro), Linkding, Mealie, Pi-hole (`pihole-FTL.db` + listas custom), Caddyfile, configuración Samba, secretos del repo (`/home/homelab/homelab/secrets/`), `.env` de cada stack. | **Diaria + offsite.** Retención GFS larga (≥ 12 meses). Verificación de restauración trimestral. |
| **T2 — Importante** | Pérdida = molesta pero reconstruible en horas (configuración recreable, scrapers, datos derivados con valor). | Stash metadatos + scrapers + tags, Calibre-Web BBDD, FreshRSS BBDD + OPML, Sonarr/Radarr/Prowlarr config, Home Assistant `.storage`, Node-RED flows, configuración Grafana (dashboards JSON), Uptime Kuma `kuma.db`. | **Diaria + offsite.** Retención GFS estándar (≥ 6 meses). |
| **T3 — Voluminoso, valor medio** | Mucho espacio, valor moderado, regenerable con esfuerzo. | Buckets MinIO de aplicación (`app-snapshots`, salvo que ya estén respaldados por su origen), datos persistentes Syncthing si no son canónicos en otro nodo, cache de generadores Stash si el operador decidió incluirlos. | **Selectivo.** Solo si el operador opta-in por bucket/carpeta. Excluido por defecto. |
| **T4 — No se respalda** | Voluminoso, regenerable trivialmente, o efímero. | `/mnt/hd2t/media/`, `/mnt/hd2t/downloads/`, todos los `apps/*/cache/`, `apps/*/redis/dump.rdb` y `appendonly.aof` (ya en BBDD primaria), `prometheus/data/` (TSDB; ver nota), `/mnt/hd5t/` completo, `/var/lib/docker/` (los contenedores son re-creables desde compose). | Excluidos en `borgmatic.yaml` con patrones explícitos. **Documentar la exclusión** en cada caso. |

### Notas sobre exclusiones específicas

- **Prometheus TSDB**: ~30 días de métricas son útiles para diagnosticar tendencias, no para ser restaurados tras un desastre. Si `hd2t` muere, las métricas se asumen perdidas y el siguiente Prometheus arranca limpio. Reabrible si en algún momento se quieren métricas históricas a años; en ese caso la solución es Thanos / VictoriaMetrics, no Borg. **Excluido**.
- **Redis (`dump.rdb`, `appendonly.aof`)**: Redis del homelab es **caché o sesiones** (Nextcloud file locking, Authelia sessions). Si Redis pierde su estado, la peor consecuencia es que los usuarios re-loguean. La BBDD primaria de cada servicio (Postgres / SQLite) es la fuente de verdad; el AOF es derivado. **Excluido por defecto**.
- **Docker volumes (named volumes)**: el homelab no usa volúmenes nominales (regla de `02-estructura-compose.md`); todo es bind mount. La política se concentra en `/mnt/hd2t/apps/`. Si en algún momento se introduce un volumen nominal por excepción documentada, `03-backup-docker-volumes.md` cubre el procedimiento manual.
- **Configuración del repo en `/home/homelab/homelab/`**: composes, scripts, Caddyfile, `prometheus.yml`, `_template/` están versionados en git → el offsite "real" de la configuración es **el repositorio remoto de git** (privado). Borg respalda **solo** los `.env` y `secrets/` que `git` ignora.

### Mapping rápido a labels Compose

```yaml
# stacks/<servicio>/docker-compose.yml
services:
  ejemplo:
    labels:
      homelab.role: "media"
      homelab.backup: "true"          # T1/T2 → Borg lo incluye
      homelab.backup.tier: "1"        # informativo, no consumido por Borg
```

Borgmatic en Fase 7.2 consume `homelab.backup` para construir patterns y excluye automáticamente cualquier `apps/<svc>/cache/` y `apps/<svc>/redis/`.

---

## Destinos físicos

### Destino #1 — Repo Borg local en `hd2t`

Ya creado por `04-estructura-directorios.md`:

```
/mnt/hd2t/backups/borg/   homelab:homelab   0700
```

| Decisión | Valor | Por qué |
|---|---|---|
| Modo de cifrado Borg | `repokey-blake2` | La passphrase y la clave de cifrado conviven en el repo; perder el repo no compromete los datos sin la passphrase. `blake2` es más rápido que `sha256` en ARM64. `keyfile` se descarta porque guardar la clave fuera del repo en un homelab single-host añade complejidad sin ganancia (la passphrase ya cumple ese papel). |
| Compresión | `zstd,3` (ajustable a `zstd,9` para repos sobre red) | Mejor ratio que `lz4`, mucho más rápido que `lzma`. Local en SSD/HDD el cuello de botella es el disco, no la CPU. |
| Tamaño de chunks | Defaults Borg (`chunker-params 19,23,21,4095`) | Suficiente para texto + binarios mixtos. Las BBDD se manejan vía dumps que ya son texto comprimible. |
| Lockfile, FUSE | No se usa `borg mount` en producción | Restauración por `borg extract` a un scratch dir (`/mnt/hd2t/backups/exports/restore-scratch/`). |

### Destino #2 — Offsite S3-compatible

| Proveedor | Coste 2026 (orientativo) | Notas |
|---|---|---|
| **Backblaze B2** *(recomendado)* | ~6 USD/TB/mes almacenamiento + 0.01 USD/GB egress | API S3-compatible. Egress gratuito hasta 3× del almacenamiento mensual. Madurez probada con Borg/rclone. |
| **Cloudflare R2** | ~15 USD/TB/mes almacenamiento + **egress gratis** | Bueno si se restaura mucho; peor relación coste/almacenamiento. |
| **Wasabi** | ~7 USD/TB/mes; egress gratis pero política de mínimo de retención (90 días) | Penaliza datasets cambiantes. Adecuado para *cold archive*. |

**Patrón elegido**: `rclone` con `crypt` overlay sobre B2.

```
flujo:
  borgmatic (local) → /mnt/hd2t/backups/borg/        (cifrado por Borg)
                   ↓ (post-hook)
                   rclone sync /mnt/hd2t/backups/borg/  b2crypt:homelab/borg/
                                                        (cifrado adicional rclone-crypt)
```

| Decisión | Valor | Por qué |
|---|---|---|
| Cifrado offsite | `rclone crypt` por encima del repo Borg | Defensa en profundidad. Borg ya cifra; `rclone crypt` cifra **además** los nombres de fichero, así el operador del bucket (Backblaze) no ve la estructura "borg" reconocible. |
| Sync vs copy vs mirror | `rclone sync --backup-dir snapshots/<fecha>/` | El repo Borg es append-mostly; `sync` mantiene paridad. El `--backup-dir` recupera ficheros borrados accidentalmente del lado local antes de propagarse. |
| Bandwidth limit | `--bwlimit 5M:off` (5 MB/s subida en horario nocturno, sin límite de bajada para restauración) | Evita saturar el uplink doméstico. La conexión típica fibra simétrica española (300/300 o 1G/1G) no necesita límite, pero se documenta como ajustable. |
| Versionado en B2 | Activado a nivel de bucket | Defensa anti-ransomware: si la Pi cifra el repo Borg con malware y `rclone sync` propaga el daño, las versiones anteriores en B2 permiten recuperarse. Coste extra mínimo si retención = 30 días. |
| Lifecycle policy | "Mantener al menos las últimas N versiones de cada fichero, borrar versiones >30 días" | Equilibrio coste/protección. |

> **Alternativa Borg sobre `rclone serve restic`**: técnicamente posible (Borg ve un FS via FUSE/SFTP y escribe directo). Se descarta hoy: añade un proceso `rclone serve` perpetuo con su propia complejidad de fallos, y el patrón "Borg local + sync nocturno offsite" es más simple, observable y reanudable. Reabrible si el operador prefiere un único repo Borg directamente offsite.

### Destino #3 — Disco USB externo "frío" *(opcional, postergable)*

Un HDD/SSD USB pequeño (256–500 GB) que el operador conecta una vez al mes, recibe una copia rsync de `/mnt/hd2t/backups/borg/` + `secrets/`, y se guarda físicamente en otra ubicación (caja fuerte, casa de un familiar). Cierra la regla 3-2-1 estricta sin depender del proveedor cloud. Se documenta como **opcional**: cuando el operador decida adquirirlo, se añade un script en `scripts/` y se incluye en `02-borgmatic.md` como receta secundaria.

---

## Programación y retención

### Cadencia GFS (Grandfather-Father-Son)

Borgmatic implementa retención GFS de forma nativa con `keep_*`. Los valores aceptados:

| Nivel | Frecuencia | Retención | Ventana horaria |
|---|---|---|---|
| **Daily** | Cada día | **Últimos 7** | 03:30 — 04:30 local. Pi parada o tranquila; nadie usa Jellyfin a esas horas. |
| **Weekly** | Cada lunes | **Últimas 4** | El run diario del lunes cuenta como semanal (Borg lo etiqueta automáticamente). |
| **Monthly** | Día 1 de cada mes | **Últimos 12** | Idem. |
| **Yearly** | 1 de enero | **2** mínimo (configurable) | Idem. |

**Total típico de archives en el repo en steady state**: 7 + 4 + 12 + 2 = **25 archives**. Borg deduplica: el repo crece muy lentamente tras el primer mes (dataset principalmente estable: configs, BBDD que crecen poco).

### Ventana horaria

```
03:30  Pre-hooks: dumps SQL + flushes (cron / systemd timer)
03:45  Borgmatic create + prune + check (semanal)
04:00  rclone sync hacia offsite
04:30  Notificación de éxito/fallo (Apprise → Telegram + Uptime Kuma push)
```

Duración esperada en steady state (Pi 5 + USB 3.0):

- Borgmatic create incremental: ~3–10 min (la dedup hace el grueso del trabajo).
- `rclone sync` offsite: ~2–15 min según churn diario (típico < 100 MB).
- Total noche promedio: < 30 min.

### Cadencia de operaciones de mantenimiento

| Operación | Cadencia | Comando | Resultado |
|---|---|---|---|
| `borg compact` | Semanal (lunes 04:30) | `borgmatic compact` | Recupera espacio tras prune. |
| `borg check --repository-only` | Semanal | `borgmatic check --only repository` | Detecta corrupción en chunks/manifest. |
| `borg check --archives-only` | Mensual (día 1) | `borgmatic check --only archives` | Verifica integridad de archives. Costoso (rehash). |
| Restore drill (test real) | Trimestral | Procedimiento en `03-backup-docker-volumes.md` | Restaura un servicio T1 a un directorio scratch y compara hashes. |

### RPO / RTO

| Escenario | RPO objetivo | RTO objetivo | Cubierto por |
|---|---|---|---|
| Corrupción de un fichero o BBDD de un servicio (caso típico) | ≤ 24 h | ≤ 30 min | Restore puntual desde Borg local |
| Fallo total del HDD `hd2t` | ≤ 24 h | ≤ 4 h | Restore completo desde offsite tras reemplazar disco |
| Pérdida total del sitio (incendio, robo) | ≤ 24 h | ≤ 24 h | Restore desde offsite + reflasheo de la Pi siguiendo Fases 0–6 |
| Pérdida de un fichero borrado hace > 7 días pero < 1 mes | ≤ 1 mes | ≤ 30 min | Archive *weekly* del repo Borg |
| Pérdida del repo Borg local + offsite (ataque ransomware exitoso) | hasta 1 mes | depende de copia "fría" | Disco USB externo opcional / versionado B2 |

> **Decisión de RPO 24 h**: incremental cada hora se descarta — el coste operativo (cron cada hora, hooks de BBDD que pueden colisionar con uso real, ruido en notificaciones) supera el beneficio. Los servicios del homelab toleran perder 24 h de cambios.

> **Decisión de RTO**: en práctica el cuello de botella es la velocidad de bajada del offsite (~125 Mbps reales en una fibra 1G simétrica) y el `borg extract`. Para datasets de < 50 GB, el RTO de 4 h es holgado.

---

## Pre/post hooks: consistencia de bases de datos

Copiar un fichero `.sqlite3` o `pgdata/` "en caliente" mientras el servicio escribe es **incorrecto**: lo que se respalda es un snapshot inconsistente. Hay tres patrones aceptables; el homelab adopta **dumps lógicos** como primer principio.

| Tecnología | Estrategia | Por qué |
|---|---|---|
| **PostgreSQL** (`nextcloud-db`, futuras Bookstack/Paperless) | `pg_dump --format=custom --compress=9` por base de datos → `.dump` en `/mnt/hd2t/backups/dumps/<svc>/` antes de Borg. Borg respalda el dump, no `pgdata/`. Post-hook: `find dumps/<svc>/ -type f -delete` tras éxito. | `pg_dump` es transaccional: el dump es consistente sin parar el servicio. `--format=custom` permite restore selectivo de tablas y se restaura con `pg_restore`. Respaldar `pgdata/` directamente requiere `pg_basebackup` + WAL archive y ata la versión menor de Postgres. Los dumps son *agnostic*: un dump de `postgres:16` se restaura en `postgres:16` o se migra a `17` con `pg_dump`/`pg_restore` cruzados. |
| **MariaDB / MySQL** *(futuro)* | `mysqldump --single-transaction --routines --triggers --events` → `.sql.gz`. | `--single-transaction` da consistencia en motores InnoDB sin lock global. Compatible con cualquier 10.x. |
| **SQLite** (Authelia, Uptime Kuma, Pi-hole `pihole-FTL.db`, FreshRSS, Linkding…) | `sqlite3 <db.sqlite3> ".backup '/mnt/hd2t/backups/dumps/<svc>/db-snapshot.sqlite3'"` → Borg respalda el snapshot. **No** se copia el fichero original con `cp`. | El comando `.backup` de SQLite es una copia consistente incluso bajo escritura concurrente; usa el mismo mecanismo interno que VACUUM INTO. Copiar el fichero `.sqlite3` mientras hay un WAL pendiente respalda un estado a medio commit. |
| **Redis** | **No se respalda**. AOF/RDB son derivados; la fuente de verdad está en la BBDD primaria del servicio. | Decisión cerrada arriba. |
| **MinIO** | Buckets críticos (definidos por el operador como T1/T2): `mc mirror minio/<bucket> /mnt/hd2t/backups/dumps/minio/<bucket>/` antes de Borg. | MinIO single-node: respaldo por filesystem es válido; `mc mirror` es la herramienta nativa y mantiene metadata S3. |

### Hook de aplicación: modo mantenimiento

Servicios que escriben caches/índices durante la noche (Stash genera previews, Sonarr indexa) **no** se ponen en mantenimiento; el dump de su BBDD es consistente y los ficheros generados son re-creables. Excepción: Nextcloud admite `occ maintenance:mode --on` antes del dump si el operador quiere garantías extra; **no se activa por defecto** porque interrumpe Syncthing/clientes y el backup pierde la propiedad "transparente".

---

## Cifrado y custodia de claves

| Capa | Mecanismo | Almacenamiento de la clave |
|---|---|---|
| **Borg local** | `repokey-blake2`, passphrase de ≥ 32 caracteres aleatoria | `/home/homelab/homelab/secrets/borg.passphrase` (`0600`, `homelab:homelab`). **No** versionada. **No** vive en el repo. |
| **Borg offsite** | El propio repo Borg ya cifrado se sube tal cual | Misma passphrase. |
| **rclone offsite** | `rclone crypt` overlay con passphrase distinta | `secrets/rclone-crypt.passphrase` (`0600`). Distinta de la de Borg para no comprometer ambas con un único leak. |
| **Credenciales B2 (App Key)** | Access Key ID + Secret en `secrets/rclone.conf` | `0600`, `homelab:homelab`. Permiso solo sobre `bucket=<homelab-borg>`, no sobre la cuenta entera. |

### Custodia fuera de banda

El operador escribe **a mano** la passphrase Borg + la passphrase rclone-crypt en al menos **dos** ubicaciones físicas distintas no digitales o cifradas independientemente:

1. Un papel en una caja fuerte ignífuga.
2. Una nota cifrada en un gestor de contraseñas externo (no Vaultwarden del propio homelab — sería autorreferencial; un Bitwarden cloud, un KeePassXC en nube familiar, etc.).

**Anti-patrón explícitamente prohibido**: dejar la passphrase Borg solo dentro de Vaultwarden del propio homelab. Si la Pi muere y el operador necesita recuperar, no puede acceder al gestor de passwords sin antes recuperar… que requiere la passphrase. Bloqueo circular.

---

## Verificación de restauración

> "Un backup que no se ha probado restaurándolo no es un backup, es una esperanza."

### Verificación automática (continua)

| Frecuencia | Comprobación | Implementación |
|---|---|---|
| Cada noche, post-create | `borg list ::<archive-actual> --short \| wc -l` y comparar con la noche anterior (delta razonable) | Hook post-backup en `02-borgmatic.md`. |
| Semanal | `borgmatic check --only repository` | Cron / Borgmatic `checks` schedule. |
| Mensual | `borgmatic check --only archives` (rehash completo) | Lunes 1 de cada mes. |
| Cada subida offsite | `rclone check` entre origen y destino | Post-sync en el mismo job. |

Métrica expuesta a Prometheus (vía `node_exporter` textfile collector):

```
homelab_backup_last_success_timestamp 1730000000
homelab_backup_last_size_bytes 12345678
homelab_backup_archives_total 25
homelab_backup_offsite_lag_seconds 1800
```

Reglas de alerta básicas (definidas en `02-borgmatic.md` y `05-monitorizacion/01-prometheus.md`):

- `time() - homelab_backup_last_success_timestamp > 36*3600` → **CRÍTICO** (más de 36 h sin backup exitoso).
- `homelab_backup_offsite_lag_seconds > 48*3600` → **WARNING** (offsite desincronizado).
- `homelab_backup_archives_total < 5` → **WARNING** (retención sospechosa).

### Verificación manual (restore drill)

Cada **trimestre** el operador ejecuta el drill completo y deja constancia en `BACKUPS_LOG.md` (versionado en el repo, sin secretos).

```
1. Elegir un servicio T1 al azar (Authelia, Nextcloud-DB, Pi-hole).
2. mkdir -p /mnt/hd2t/backups/exports/restore-drill-YYYYMMDD/
3. borgmatic extract --archive latest --path mnt/hd2t/apps/<svc>/data \
        --destination /mnt/hd2t/backups/exports/restore-drill-YYYYMMDD/
4. Comparar hashes / counts con el live (sabiendo que pueden divergir si el servicio escribió en las últimas horas).
5. Para una BBDD: levantar un contenedor scratch (postgres:16-alpine en un compose temporal),
   pg_restore al contenedor, ejecutar SELECT count(*) básicos y validar.
6. Documentar: tamaño restaurado, tiempo total, problemas encontrados.
7. rm -rf /mnt/hd2t/backups/exports/restore-drill-YYYYMMDD/ tras éxito.
```

El procedimiento detallado por tipo de servicio vive en `03-backup-docker-volumes.md`.

> **Restore drill desde offsite**: una vez al año, el drill se hace forzando descarga desde el bucket B2 (no desde el repo local). Esto valida que las claves rclone funcionan, que el `crypt` se descifra y que el ancho de banda permite RTO razonable.

---

## Notificaciones

| Evento | Canal | Severidad |
|---|---|---|
| Backup completo OK | Uptime Kuma push monitor (heartbeat) | Info — solo se nota si **deja** de llegar |
| Backup falla en cualquier hook | Apprise → Telegram | **CRIT** |
| `borg check` reporta inconsistencia | Apprise → Telegram + email opcional | **CRIT** |
| `rclone sync` falla > 2 noches consecutivas | Apprise → Telegram | **WARN** |
| Restore drill ejecutado con éxito | `BACKUPS_LOG.md` (commit manual) | Auditoría |

El detalle de cada hook de notificación se cierra en `02-borgmatic.md`. Aquí solo se establece **qué** se notifica y **dónde**.

---

## Almacenamiento

Rutas implicadas en la estrategia (no se crea nada nuevo aquí; solo se documenta):

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/mnt/hd2t/backups/borg/` | hd2t | `homelab:homelab` | `0700` | Repo Borg local. Cifrado. |
| `/mnt/hd2t/backups/dumps/` | hd2t | `homelab:homelab` | `0700` | Dumps SQL/SQLite efímeros (existen segundos antes de entrar al repo). |
| `/mnt/hd2t/backups/exports/` | hd2t | `homelab:homelab` | `0750` | Exports manuales y restore drills. No se backupea. |
| `/home/homelab/homelab/secrets/borg.passphrase` | microSD | `homelab:homelab` | `0600` | Passphrase Borg. **No** versionado. |
| `/home/homelab/homelab/secrets/rclone-crypt.passphrase` | microSD | `homelab:homelab` | `0600` | Passphrase rclone-crypt. **No** versionado. |
| `/home/homelab/homelab/secrets/rclone.conf` | microSD | `homelab:homelab` | `0600` | Credenciales B2 + perfil crypt. **No** versionado. |
| `/home/homelab/homelab/BACKUPS_LOG.md` | microSD | `homelab:homelab` | `0644` | Bitácora de restore drills y eventos. **Versionado en git.** |
| `/mnt/hd5t/` | hd5t | varía | varía | **Excluido** del backup por política. |

Espacio reservado en `hd2t` para los backups: presupuesto inicial **300 GiB**. La curva real depende del churn de Nextcloud; se revisa tras 3 meses con `borgmatic info` (campos `Original size / Compressed size / Deduplicated size`).

---

## Backup

Este documento es **una decisión versionada** del homelab. Su backup, en consecuencia:

| Artefacto | Estrategia |
|---|---|
| `docs/07-backups/01-estrategia-backup.md` (este fichero) | Versionado en git. Cualquier cambio queda trazado. |
| `BACKUPS_LOG.md` | Versionado en git. Auditoría de drills y excepciones. |
| `secrets/*.passphrase`, `secrets/rclone.conf` | **No** versionado. Respaldado por **el propio Borg** como parte de `/home/homelab/homelab/secrets/`. Bootstrap problem mitigado por la custodia fuera de banda descrita arriba. |

> **Bootstrap problem**: los secretos Borg viven dentro de Borg. Para el primer arranque tras reflasheo, el operador necesita la passphrase **fuera** del repo (caja fuerte / gestor cloud). Una vez tecleada, descifra el repo, restaura `secrets/`, y a partir de ahí los secretos se autosostienen.

---

## Decisiones que **no** se toman en este documento

- **Implementación concreta de Borgmatic**: `borgmatic.yaml`, hooks YAML, integración con systemd timers, scripts de notificación → `02-borgmatic.md`.
- **Procedimientos manuales de backup/restore por servicio**: cómo se respalda Nextcloud paso a paso, cómo se restaura Authelia tras un desastre, qué hacer con buckets MinIO específicos → `03-backup-docker-volumes.md`.
- **Cifrado de filesystem (LUKS) en `hd2t`**: descartado en `04-estructura-directorios.md` y no se reabre aquí.
- **Snapshots a nivel de filesystem (Btrfs / ZFS)**: el filesystem es ext4 (decisión de Fase 0). Snapshots COW no aplican. Reabrible si en algún momento se reformatea `hd2t` a Btrfs/ZFS.
- **Backup en caliente con `pg_basebackup` + WAL archive**: descartado a favor de `pg_dump`. Reabrible si Nextcloud crece a un tamaño donde el dump nocturno no termine en la ventana (improbable a corto plazo).
- **Borg sobre `rclone serve restic`** como destino directo offsite: reabierto en `02-borgmatic.md` si surge la necesidad.
- **Autoupdate de Borgmatic**: gestionado por Watchtower con label dedicada en su stack. Se cierra en `02-borgmatic.md`.
- **Retención por proveedor offsite (lifecycle B2)**: las reglas concretas del bucket B2 viven en `02-borgmatic.md` (donde se configura `rclone`).

---

## Verificación Final

Antes de pasar a `02-borgmatic.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Estructura de backups creada | `ls -la /mnt/hd2t/backups/` | `borg/`, `dumps/`, `exports/` con permisos correctos |
| Permisos `0700` en `borg/` y `dumps/` | `stat -c '%a %U:%G %n' /mnt/hd2t/backups/borg /mnt/hd2t/backups/dumps` | `700 homelab:homelab ...` (×2) |
| Espacio libre suficiente | `df -h /mnt/hd2t` | ≥ 300 GiB libres |
| Cuenta offsite lista | (manualmente) bucket creado en B2/R2/Wasabi, App Key generada con scope al bucket | OK |
| Custodia fuera de banda preparada | (manualmente) caja fuerte / gestor externo listo para recibir las passphrase | OK |
| `BACKUPS_LOG.md` inicializado en el repo | `ls /home/homelab/homelab/BACKUPS_LOG.md` | fichero presente con entrada inicial fecha + plan |
| Inventario T1/T2 anotado por stack | `grep -r "homelab.backup" /home/homelab/homelab/stacks/` | cada stack relevante tiene `homelab.backup: "true"` |
| Decisiones revisadas con el operador | (manualmente) revisión cruzada de RPO/RTO, retención GFS, proveedor offsite | acordado y firmado |

Cumplido el último punto, la Fase 7 puede continuar: el siguiente paso es desplegar **Borgmatic** materializando estas decisiones (`02-borgmatic.md`).

---

## Referencias

- [Documento siguiente: `docs/07-backups/02-borgmatic.md`](./02-borgmatic.md)
- [Documento siguiente: `docs/07-backups/03-backup-docker-volumes.md`](./03-backup-docker-volumes.md)
- [Documento relacionado: `docs/01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)
- [Documento relacionado: `docs/02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)
- [Documento relacionado: `docs/06-almacenamiento/04-minio.md`](../06-almacenamiento/04-minio.md)
- [BorgBackup — Documentación](https://borgbackup.readthedocs.io/)
- [BorgBackup — Modos de cifrado y `repokey-blake2`](https://borgbackup.readthedocs.io/en/stable/usage/init.html#encryption-modes)
- [Borgmatic — Documentación](https://torsion.org/borgmatic/)
- [rclone — `crypt` overlay](https://rclone.org/crypt/)
- [rclone — Backblaze B2 backend](https://rclone.org/b2/)
- [PostgreSQL — `pg_dump` formats](https://www.postgresql.org/docs/16/app-pgdump.html)
- [SQLite — `.backup` command y consistencia](https://www.sqlite.org/lang_vacuum.html#vacuuminto)
- [The 3-2-1 backup rule (US-CERT)](https://www.cisa.gov/sites/default/files/publications/data_backup_options.pdf)
- [Backblaze — B2 pricing y App Keys](https://www.backblaze.com/cloud-storage/pricing)
