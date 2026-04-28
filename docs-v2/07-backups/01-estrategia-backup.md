# Estrategia de Backup

## Descripción

Documento marco de la **Fase 7** del homelab. Define **qué se respalda, dónde, con qué frecuencia, durante cuánto tiempo, cómo se cifra, cómo se verifica y cómo se restaura**, antes de entrar en la herramienta concreta ([`./02-borgmatic.md`](./02-borgmatic.md)) y en los procedimientos por servicio ([`./03-backup-docker-volumes.md`](./03-backup-docker-volumes.md)).

La regla guía es la **3-2-1** clásica:

- **3 copias** de cada dato crítico (la original + 2 backups).
- **2 medios distintos** (no las dos copias en el mismo disco/host).
- **1 copia offsite** (físicamente fuera de casa: nube, casa de un familiar, segundo Pi, VPS).

Sobre la Pi 5 con dos discos USB, la traducción es:

| # | Copia | Soporte | Quién la mantiene |
|---|---|---|---|
| 1 | Datos vivos de los servicios | `hd2t` (`/mnt/hd2t/services/`, `/mnt/hd2t/media/`, `/mnt/hd2t/sync/`...) y `hd5t` (`/mnt/hd5t/stash/`) | El propio servicio (Nextcloud, Jellyfin, Stash, ...). |
| 2 | Snapshot deduplicado y cifrado | `hd2t` (`/mnt/hd2t/backups/borg/`) | Borgmatic ([`./02-borgmatic.md`](./02-borgmatic.md)) sobre los **mismos** discos pero en **otra estructura lógica**. Cubre el "1 medio distinto del original" en sentido lógico, no físico. |
| 3 | Réplica offsite cifrada | Nube (Backblaze B2, Storj, Hetzner Storage Box, AWS S3 Glacier, otro Pi remoto...) o disco rotado fuera de casa | `rclone` o `borg sync` empuja desde `hd2t/backups/borg/` al destino remoto. Cubre el "1 offsite" real. |

> **Realismo sobre la copia local**: la copia 2 vive en el **mismo disco** que la 1 cuando el servicio reside en `hd2t` (la mayoría). Eso **no** cumple estrictamente "2 medios distintos" — un fallo total de `hd2t` se llevaría originales y backups. La copia 2 cubre **otros modos de fallo mucho más probables**: borrado accidental por el operador, corrupción de un fichero, ataque ransomware contra los volúmenes Docker, restauración a un punto en el tiempo. La copia 3 (offsite) es la que cubre el incendio/robo/`hd2t` muerto. **No saltarse la copia 3** por pereza.

Este documento cubre, en este orden:

1. **3-2-1 aplicada al homelab**: por qué cada copia, qué cubre y qué no.
2. **Clasificación de los datos** por criticidad (crítico / importante / regenerable / excluido).
3. **Topología local** del directorio `/mnt/hd2t/backups/` y por qué cada subcarpeta.
4. **Frecuencia y retención**: el patrón GFS (Grandfather-Father-Son) adaptado.
5. **Hooks pre/post-backup**: el patrón "dump primero, snapshot después" para bases de datos y estado en memoria.
6. **Cifrado y secretos**: por qué `repokey-blake2`, dónde vive la passphrase, qué se cifra a nivel de aplicación antes del backup.
7. **Offsite**: opciones reales (B2, Storj, segundo Pi), cómo elegir, ancho de banda casero.
8. **Verificación de la restauración**: por qué un backup que no se prueba no existe, y cómo programar pruebas mensuales.
9. **Notificaciones y monitorización**: integración con Apprise, Uptime Kuma push, email.
10. **Disaster recovery** — *resumen y puntero* a [`../13-operaciones/02-disaster-recovery.md`](../13-operaciones/02-disaster-recovery.md), que cubre el procedimiento end-to-end de reconstrucción del homelab.

> **Alcance**: este documento **no** despliega Borgmatic. La definición de la herramienta, el `borgmatic.yml` completo, los systemd timers y los hooks concretos viven en [`./02-borgmatic.md`](./02-borgmatic.md). Los procedimientos específicos de respaldar/restaurar volúmenes Docker y bases de datos por servicio viven en [`./03-backup-docker-volumes.md`](./03-backup-docker-volumes.md). Aquí solo se fijan las **decisiones de fondo** que esos dos docs implementan.

> **Alcance de red**: el homelab opera en LAN + Tailscale. La copia offsite **sí sale a internet**, pero a través de un túnel cifrado punto a punto contra el proveedor (HTTPS/TLS o WireGuard hacia un Pi remoto). No se abren puertos entrantes en el router; la conexión la inicia siempre la Pi local hacia el destino remoto.

---

## Requisitos Previos

- **Estructura de directorios** ya aplicada según [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md):
  - `/mnt/hd2t/backups/` con propietario `root:root` y modo `700`.
  - Subcarpetas `borg/`, `dumps/postgresql/`, `dumps/mariadb/`, `configs/`, `system/` ya creadas con los mismos permisos.
- **Discos `hd2t` y `hd5t`** montados con `noatime,nofail` y healthchecks SMART operativos según [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md). Un backup que se hace sobre un disco que está fallando es papel mojado.
- **Reloj sincronizado por NTP** según [`../01-sistema/02-configuracion-inicial.md`](../01-sistema/02-configuracion-inicial.md). Las marcas de tiempo de los archivos Borg son críticas para retención y para la auditoría de "¿cuándo perdí los datos?".
- **Espacio libre razonable en `hd2t`** (≥ 200 GB recomendados de partida; el repo Borg crece a ritmo de unos pocos GB/mes con dedup activa, pero los dumps de BD en `dumps/` y los snapshots de configs pueden picar). Monitorizado por Node Exporter + Grafana ([`../05-monitorizacion/02-grafana.md`](../05-monitorizacion/02-grafana.md)).
- **Credenciales offsite** ya creadas (cuenta Backblaze B2 / Storj / etc.) y guardadas en KeePassXC o, una vez desplegado, en Vaultwarden ([`../11-productividad/01-vaultwarden.md`](../11-productividad/01-vaultwarden.md)). En esta fase 7 (que precede a la fase 11) suelen vivir todavía en KeePassXC fuera del homelab.
- **Notificación funcionando**: al menos email saliente vía SMTP (Gmail/Fastmail/lo que use el operador) o Apprise hacia Telegram. Sin canal de notificación, los fallos de backup pasan inadvertidos durante meses. Se documenta el detalle en [`./02-borgmatic.md`](./02-borgmatic.md), pero la **decisión** de tener uno se toma aquí.
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No hay reglas nuevas para Borgmatic — todas las conexiones son **salientes** desde la Pi.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Regla guía | **3-2-1** | Estándar industrial; trade-off razonable entre coste, complejidad y resiliencia. |
| Herramienta de backup principal | **Borg + Borgmatic** | Dedup por bloques, cifrado autenticado, compresión, retención GFS, hooks pre/post, single-binary, ARM64 nativo, repos sobre filesystem normal (ext4). Se documenta en [`./02-borgmatic.md`](./02-borgmatic.md). |
| Repo Borg local | `/mnt/hd2t/backups/borg/` | En el mismo disco que los datos vivos. Cubre borrado accidental y corrupción, **no** desastre físico. |
| Cifrado del repo | **`repokey-blake2`** (passphrase + clave en el propio repo, hash BLAKE2b en lugar de SHA-256) | El repo se cifra con AES-CTR + HMAC. La clave maestra va dentro del repo, cifrada con la passphrase. BLAKE2b es ~2× más rápido que SHA-256 en ARM64, donde la Pi 5 nota la diferencia (sin AES-NI). |
| Dónde vive la passphrase de Borg | **KeePassXC** (offline) **+** copia impresa en sobre cerrado **+** una vez desplegado, también en Vaultwarden | Si se pierde la passphrase, **se pierde el backup**. Triple custodia es el mínimo. **NUNCA** en el repo git del homelab. |
| Offsite | **Backblaze B2** vía `rclone` (recomendado por defecto) | $6/TB/mes, S3-compatible, sin gasto de egreso para volúmenes habituales del homelab, política simple. Alternativas en §7. |
| Frecuencia de los backups | **Diaria** (el grueso) **+** **semanal** (cosas que cambian poco) **+** continua (git para configs) | Patrón cubierto en §4. |
| Retención por defecto | **7 dailies, 4 weeklies, 6 monthlies, 1 yearly** (GFS) | Equilibrio entre granularidad reciente (recuperar el último cambio "pequeño") e histórica (volver a hace medio año). Justificado en §4.4. |
| Patrón para BD vivas | **Dump primero, snapshot después** (`before_backup` hook) | Snapshotear `db/data/` "vivo" produce restores corruptos. Pattern uniforme: hook escribe `*-YYYY-MM-DD.sql.gz` en `dumps/<motor>/`, Borg snapshotea ambos. |
| Patrón para SQLite | **`sqlite3 .backup` en el contenedor** | `cp` directo es seguro solo con `journal_mode=DELETE` y sin escrituras concurrentes; `.backup` es la API canónica. |
| Patrón para Redis | **Sin backup** (estado efímero: locks, sesiones) | Documentado caso por caso. Pérdida = re-login o retry de cliente. |
| Verificación | **`borg check --verify-data` mensual** + **smoke test de restauración** mensual | Un backup que no se restaura no es un backup. Programado en §8. |
| Notificación | **Apprise** (Telegram + email) en `on_error` y `after_everything` | Incluye éxitos, no solo fallos: "ningún email = ¿está fallando o no se está ejecutando?". |
| Borrado accidental por el operador | **Versionado en `media/` y `services/` no se hace en filesystem**; lo cubre Borg | Sin filesystem snapshots (ext4 no los tiene; btrfs/ZFS sería overkill en una Pi); Borg cubre el "ctrl-z" con su retención. |
| Cifrado adicional a nivel de disco (LUKS) | **No** en esta versión | LUKS sobre `hd2t` añade complejidad de boot (passphrase manual o keyfile). Borg ya cifra el repo de backups y los datos vivos no son objetivo realista de robo físico oportunista. Si el operador cambia de criterio, ver §6.4. |
| `0700` y `root:root` en `/mnt/hd2t/backups/` | **Mantener** | Los dumps de BD contienen datos sensibles en claro hasta que Borg los archiva. El operador `homelab` no debe leerlos directamente. |

---

## 1. La regla 3-2-1 aplicada al homelab

### 1.1. Las tres copias

```
┌────────────────────────────┐  ┌────────────────────────────┐  ┌──────────────────────────────┐
│  Copia 1 (original, viva)  │  │  Copia 2 (snapshot local)  │  │  Copia 3 (snapshot offsite)  │
│  /mnt/hd2t/services/...    │  │  /mnt/hd2t/backups/borg/   │  │  rclone:b2:homelab-borg/     │
│  /mnt/hd2t/media/...       │──│  (Borg, cifrado, dedup)    │──│  (Borg replicado a B2)       │
│  /mnt/hd5t/stash/...       │  │                            │  │                              │
│                            │  │  Hecho por Borgmatic       │  │  rclone sync (post-backup    │
│  La que usan los servicios │  │  Diario / Semanal          │  │  hook), nightly              │
└────────────────────────────┘  └────────────────────────────┘  └──────────────────────────────┘
       Cubre uso normal              Cubre borrado/corrupción           Cubre desastre físico
```

| Copia | Protege contra | NO protege contra |
|---|---|---|
| 1 (vivos) | — (es el dato operativo) | Cualquier accidente o desastre. |
| 2 (Borg local) | Borrado accidental, corrupción de fichero, ransomware en volumen Docker, restauración a fecha previa, error de configuración, upgrade roto. | Fallo total de `hd2t`, incendio, robo, ransomware *que cifre el repo Borg* (mitigado en §6.3). |
| 3 (offsite) | Todo lo anterior + desastre físico de la Pi (incendio, robo, inundación, rayo). | Compromiso de la passphrase de Borg (necesaria para descifrar). Coste mensual al proveedor. |

### 1.2. Lo que **no** cuenta como copia

Errores frecuentes a evitar:

- **RAID ≠ backup**. La Pi 5 no tiene RAID y aunque lo tuviera, RAID protege contra fallo de un disco, **no** contra borrado accidental: si `rm -rf` se replica a los dos discos al instante.
- **Syncthing ≠ backup**. Syncthing replica al momento; un borrado en un peer se propaga a todos. Versioning interno (`.stversions/`) ayuda pero es local a cada peer. Detallado en [`../06-almacenamiento/03-syncthing.md`](../06-almacenamiento/03-syncthing.md) §10.
- **Nextcloud "papelera" ≠ backup**. Útil para "deshacer" un borrado reciente del usuario, pero la papelera tiene tamaño limitado y se vacía sola. No sustituye al backup.
- **MinIO local ≠ offsite**. Aunque MinIO esté en otro contenedor, los buckets viven en `/mnt/hd2t/services/minio/data/`. Si `hd2t` arde, mueren los datos vivos y los buckets. Documentado en [`../06-almacenamiento/04-minio.md`](../06-almacenamiento/04-minio.md).
- **`docker-compose.yml` versionado en GitHub privado** ≠ backup de los datos. Es backup de la **definición** del homelab (que vale oro: te permite reconstruir). Los datos persistentes (dumps de BD, ficheros de usuario, etc.) van por su lado en Borg.

### 1.3. La copia 2 sobre el mismo disco: por qué es aceptable

Un purista exigirá "2 medios distintos físicos" — dos discos separados. En un homelab Pi 5 con 2 USB la opción sería:

- **A**: original en `hd2t` + copia Borg también en `hd2t` (lo que hace este plan).
- **B**: original en `hd2t` + copia Borg en `hd5t`.

Se elige **A** por dos razones técnicas y una operativa:

1. **`hd5t` está dedicado a Stash** (multimedia voluminosa, lectura secuencial, decisión heredada de [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md)). Mezclar el backup pesado del resto de servicios en `hd5t` introduce contención de I/O exactamente cuando Stash escanea su biblioteca.
2. **Borg dedup necesita un repo cohesivo**. Tener un único repo simplifica retención, verificación y replicación offsite (un solo `rclone sync`). Repartir entre dos discos exige dos repos = dos passphrase = doble verificación = doble offsite.
3. **La copia 3 (offsite) es la que protege contra fallo total de `hd2t`**. Es el plan correcto, no un parche.

Si en el futuro se añade un tercer disco (NVMe sobre USB-C, por ejemplo), la opción cambia: el repo Borg pasa al nuevo disco y `hd2t` queda solo para datos vivos. La estructura del documento aguanta ese movimiento sin reescribir nada (solo cambia la ruta del `source_directories`/`repositories` en `borgmatic.yml`).

---

## 2. Clasificación de los datos

No todo se respalda con la misma frecuencia ni en el mismo sitio. La clasificación que sigue es la que aplican los hooks de Borgmatic en [`./02-borgmatic.md`](./02-borgmatic.md).

### 2.1. Categorías

| Categoría | Definición | Trato |
|---|---|---|
| **Crítico** | Si se pierde, no se puede regenerar. Datos personales, secretos, hashes de password, claves criptográficas, tokens. | Backup **diario**, dentro del repo Borg cifrado, retención larga, replicado offsite. |
| **Importante** | Reconstruible con esfuerzo: configuración manual, dashboards, reglas de Sonarr/Radarr, perfiles. | Backup **diario o semanal** según volatilidad, en el repo Borg, replicado offsite. |
| **Regenerable** | Se reconstruye automáticamente: caches, índices, thumbnails, miniaturas, transcodificaciones. | **Excluido** del backup (o backup semanal opcional si es barato). |
| **Excluido permanentemente** | Datos que no deben respaldarse: descargas en curso, swap, sockets, logs rotativos voluminosos, papelera de Nextcloud >30 días, etc. | **Excluido** vía `exclude_patterns` en `borgmatic.yml`. |

### 2.2. Tabla por servicio (resumen)

Las tablas detalladas por servicio viven en cada doc de servicio (sección "Backup"). Esto es el resumen consolidado que usa Borgmatic como `source_directories` y `exclude_patterns`:

| Servicio | Crítico | Importante | Regenerable / Excluido |
|---|---|---|---|
| **Sistema** ([`../01-sistema/`](../01-sistema/)) | `/etc/fstab`, `/etc/passwd`, `/etc/group`, claves SSH del operador (`~/.ssh/`) | `/etc/ufw/`, `/etc/fail2ban/`, `dpkg -l > .../system/packages.txt` | `/var/log/` (excluido), `/var/cache/` (excluido), swapfile (excluido). |
| **Repo `~/homelab/`** | Toda la definición del homelab. Ya en git, pero también dentro del Borg por seguridad. | — | `~/homelab/.git/` (excluido — el origin remoto ya lo tiene). |
| **Caddy** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §10) | `Caddyfile`, certs internos | — | `/data/caddy/` cache (regenerable). |
| **Pi-hole / Unbound** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md), [`../03-red/03-unbound.md`](../03-red/03-unbound.md)) | `pihole.toml`, listas custom, `gravity.db` | — | `pihole-FTL.db` (estadísticas; opcional o semanal). |
| **Tailscale** ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) | `tailscaled.state`, `tailscale status --json` (snapshot) | — | — |
| **Authelia** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §11) | `secrets/{jwt,session,storage_encryption,redis_password}`, `db.sqlite3` (con su `storage_encryption` siempre juntos) | `users_database.yml`, `configuration.yml` | `redis/data/` (sesiones efímeras). |
| **Prometheus** ([`../05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md)) | `prometheus.yml`, reglas de alerta | TSDB (snapshot semanal opcional) | TSDB diaria es excesivo (se pierde 1 día de métricas, no es crítico). |
| **Grafana** ([`../05-monitorizacion/02-grafana.md`](../05-monitorizacion/02-grafana.md)) | `grafana.db` (dashboards, datasources, users) | `provisioning/`, `dashboards/` (versionables en git) | `data/png/` (snapshots de alertas) — opcional. |
| **Uptime Kuma** ([`../05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md)) | `kuma.db` | — | — |
| **Nextcloud** ([`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md) §10) | `secrets/*`, `db/` (vía dump), `nextcloud/data/` | `nextcloud/html/` (sin `data/`) | `appdata_*/preview/` (excluible), papelera >30 días. |
| **Samba** ([`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md)) | `smb.conf`, `smbpasswd` | — | — |
| **Syncthing** ([`../06-almacenamiento/03-syncthing.md`](../06-almacenamiento/03-syncthing.md) §10) | `config.xml`, `cert.pem`, `key.pem`, `/mnt/hd2t/sync/` | — | `index-*.db/` (regenerable, voluminoso), `*/.stversions/` (redundante con Borg). |
| **MinIO** ([`../06-almacenamiento/04-minio.md`](../06-almacenamiento/04-minio.md)) | `data/.minio.sys/` (metadata, IAM, policies), buckets críticos (`backups`, `docker-volumes`) | — | Buckets de cache si los hay. |
| **Home Assistant** (fase 8) | `configuration.yaml`, `secrets.yaml`, `.storage/`, dispositivos emparejados | Snapshots de la propia HA | — |
| **Mosquitto / Zigbee2MQTT** (fase 8) | `configuration.yaml`, `coordinator_backup.json` (Zigbee → re-pairing si se pierde) | — | — |
| **Jellyfin / Navidrome / Audiobookshelf / Calibre-Web / Stash** (fase 9) | Bibliotecas multimedia (`/mnt/hd2t/media/`, `/mnt/hd5t/stash/library/`), DBs de cada servicio | Configs, perfiles | Caches, transcodes, thumbnails (regenerables). |
| **Transmission / Sonarr / Radarr / Prowlarr** (fase 10) | Configs de cada servicio, perfiles de calidad, lista de indexers | DB SQLite de Sonarr/Radarr | `downloads/incomplete/` (excluido), `.torrent` activos (regenerable). |
| **Vaultwarden** (fase 11) | `db.sqlite3`, `attachments/`, `sends/`, `rsa_key.*`, `config.json` | — | `icon_cache/` (regenerable). |
| **Bookstack / Linkding / Paperless-ngx / Mealie / FreshRSS** (fase 11) | DBs (vía dump), ficheros subidos por el usuario | Configs | OCR cache (Paperless), thumbnails (regenerables). |
| **Stirling-PDF** (fase 11) | — (stateless) | — | — |

> **Stash y la biblioteca pesada en `hd5t`**: respaldar 3-5 TB de multimedia offsite es caro y a menudo innecesario (es contenido reemplazable). Política recomendada: respaldar **metadata, scrapers y configuración de Stash** (que tarda meses de trabajo manual rehacer) en el Borg principal; **NO** respaldar `library/` masivamente. Si el operador quiere offsite del library, usar un repo Borg separado dedicado a `hd5t/stash/library/` con replicación offsite a un proveedor de almacenamiento frío (Backblaze B2 a $6/TB/mes para 5 TB ≈ $30/mes — decisión personal).

### 2.3. La regla del "doble lugar" para secretos

Los secretos (passwords, API keys, tokens) viven en **dos lugares** dentro del homelab:

- **Vivos**: en `/mnt/hd2t/services/<stack>/secrets/` o como Docker secrets, leídos por los contenedores.
- **Custodiados**: en KeePassXC offline (fase actual del operador) y/o en Vaultwarden ([`../11-productividad/01-vaultwarden.md`](../11-productividad/01-vaultwarden.md)) cuando se despliegue.

El backup respalda los **vivos** (dentro del repo Borg cifrado). La copia "custodiada" en KeePassXC/Vaultwarden es **independiente** del backup automático: vive en otro fichero, fuera de `/mnt/hd2t/`, y se respalda con su propio mecanismo (export periódico de KeePassXC, backup del propio Vaultwarden — que a su vez entra en Borg).

> **Caso límite**: si la passphrase de Borg se pierde *y* KeePassXC/Vaultwarden se pierden, se pierde todo. Por eso §6.2 exige **triple custodia** de la passphrase de Borg.

---

## 3. Topología local: `/mnt/hd2t/backups/`

La estructura ya está creada por [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §4.4. Este apartado **explica la intención** detrás de cada subcarpeta:

```
/mnt/hd2t/backups/                root:root  700
├── borg/                         root:root  700   # Repo Borg (lo gestiona Borgmatic).
├── dumps/                        root:root  700   # Dumps generados por hooks before_backup.
│   ├── postgresql/                              #  └─ pg_dump por servicio + fecha.
│   ├── mariadb/                                 #  └─ mariadb-dump por servicio + fecha.
│   ├── sqlite/                                  #  └─ sqlite3 .backup por servicio + fecha.
│   ├── authelia/                                #  └─ db.sqlite3 backup (junto con storage_encryption).
│   ├── pihole/                                  #  └─ pihole -a -t teleporter zip.
│   ├── caddy/                                   #  └─ caddy adapt --pretty (Caddyfile reificado).
│   ├── unbound/                                 #  └─ unbound-control dump_cache.
│   ├── tailscale/                               #  └─ tailscale status --json.
│   ├── grafana/                                 #  └─ grafana.db snapshot.
│   ├── prometheus/                              #  └─ snapshot TSDB (semanal).
│   └── ...                                      # un subdirectorio por servicio que dumpea.
├── configs/                      root:root  700   # Snapshots periódicos de configs no triviales.
│   ├── docker-compose-YYYY-MM-DD.tar.gz         #  └─ snapshot de ~/homelab/stacks/.
│   ├── caddyfile-adapted-YYYY-MM-DD.json        #  └─ Caddyfile resuelto (incluye snippets).
│   └── ...
└── system/                       root:root  700   # Estado del host fuera de los servicios.
    ├── packages-YYYY-MM-DD.txt                  #  └─ dpkg -l > packages.txt (apt installed).
    ├── fstab-YYYY-MM-DD                         #  └─ /etc/fstab snapshot.
    ├── ufw-status-YYYY-MM-DD                    #  └─ ufw status verbose.
    └── ...
```

### 3.1. Por qué esta separación

| Carpeta | Es escrita por | Es leída por | Por qué existe separada |
|---|---|---|---|
| `borg/` | Borgmatic. | Borgmatic, restauradores. | Es **el** repo. Estructura interna (`config`, `data/`, `index.*`) la decide Borg. **No** entra recursivamente como `source_directory` de sí mismo (sería un loop). |
| `dumps/` | Hooks `before_backup` (Borgmatic). | Borgmatic los archiva al snapshotear; restauradores los pueden usar como atajo (restaurar el `.sql.gz` directamente sin pasar por `borg extract`). | Las BD vivas no se pueden snapshotear seguras. Se dumpean a fichero **antes** del snapshot, Borg los guarda igual que cualquier otro fichero. La carpeta sobrevive al ciclo: el último dump siempre está disponible para un restore rápido sin tocar Borg. |
| `configs/` | Hooks `before_backup` o cron. | Operador, restauradores. | Snapshots de cosas versionables que cambian poco pero cuya pérdida cuesta horas (Caddyfile resuelto, dump del compose, listas de Pi-hole). Permite diff entre fechas sin extraer del repo. |
| `system/` | Hooks `before_backup` (Borgmatic) o cron. | Operador en disaster recovery. | Estado del **host**, no de un servicio. La diferencia importa en disaster recovery: tras flashear de cero la SD, lo primero es leer `system/packages-...txt` para reinstalar lo que tenía el host. |

### 3.2. Lo que **no** vive en `/mnt/hd2t/backups/`

- **Snapshots binarios de volúmenes Docker** ad-hoc (un `docker run --rm -v vol:/v alpine tar czf /backup/vol.tgz /v`). Si se hacen, viven en `/mnt/hd2t/backups/dumps/docker-volumes/<servicio>/...` y los gestiona [`./03-backup-docker-volumes.md`](./03-backup-docker-volumes.md), pero la **vía recomendada** es bind mount sobre `/mnt/hd2t/services/<...>` (que ya entra en Borg) y dejar los volúmenes Docker nombrados solo para datos efímeros.
- **Snapshots manuales del operador**: si se hace `cp -a /mnt/hd2t/services/foo /tmp/foo.bak`, eso es un `.bak` temporal, no parte del backup. **No** dejar ahí cosas que se quieran respaldar.

### 3.3. Permisos `0700 root:root`: por qué duro

Los dumps en `dumps/` contienen:

- Hashes Argon2 de Authelia (en `db.sqlite3`).
- Tablas `oc_users`, `oc_share`, `oc_filecache` de Nextcloud.
- Notas en claro de Bookstack, marcadores de Linkding, recetas de Mealie.
- Vault de Vaultwarden (cifrado a su vez con master password del usuario, pero el cifrado es local — un atacante con tiempo lo ataca offline).

Que el usuario `homelab` (UID 1000) pueda leer `dumps/` significa que cualquier proceso comprometido que corra como `homelab` (un contenedor escapado, un script de un proyecto sin relación) accede al material. Mantenerlos `root:root 700` es la línea base. Los hooks de Borgmatic corren como `root` (`systemd` unit), por eso pueden escribir en estas rutas sin más.

---

## 4. Frecuencia y retención

### 4.1. Cadencias

| Nivel | Cuándo | Qué incluye | Quién lo dispara |
|---|---|---|---|
| **Continuo** | Tras cada cambio. | Repo git `~/homelab/`: docker-compose.yml, .env.example, Caddyfile, configuration.yml, dashboards Grafana versionables. | El operador con `git push`. |
| **Diario (03:00)** | Cada noche. | Todo lo crítico+importante: secrets, BDs (vía dump), configs, datos de usuario en Nextcloud/Syncthing, biblioteca de Calibre, vault de Vaultwarden, etc. | systemd timer → Borgmatic. |
| **Semanal (03:00 dom)** | Domingos. | Mismo set + cosas que cambian poco (Prometheus TSDB, `nextcloud/html/`, `gravity.db` completa). Coincide con el snapshot diario de ese día (Borg dedup hace que el coste extra sea bajo). | systemd timer → Borgmatic. |
| **Mensual (día 1, 03:00)** | Primer día de cada mes. | Igual que semanal **+** verificación intensiva (`borg check --verify-data`) y smoke test de restauración (§8). | systemd timer → Borgmatic + script de verificación. |
| **Anual** | Primer día del año. | Marca un snapshot que entra en la retención `yearly`. Util para restaurar "algo de hace 2 años". | Mismo timer mensual; la retención lo conserva. |

> **Ventana 03:00–04:00**: elegida por convención (carga humana mínima, los servicios están idle). Si hubiera servicios con uso 24/7 (no es el caso del homelab personal), se desplazaría. Importante: la ventana **no** debe solaparse con `unattended-upgrades` (que ya se programa en su propia ventana en [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md)) ni con la rotación de logs. La planificación detallada (qué timer arranca a qué hora) vive en [`./02-borgmatic.md`](./02-borgmatic.md).

### 4.2. Política de retención (Grandfather-Father-Son)

```
keep_daily:    7   # último mes (aproximado): 7 últimos días
keep_weekly:   4   # último trimestre: 4 últimas semanas
keep_monthly:  6   # último semestre: 6 últimos meses
keep_yearly:   1   # histórico: 1 año atrás (suficiente para "¿cómo era esto hace mucho?")
```

Resultado: en cualquier momento hay **~18 snapshots** disponibles en el repo Borg (no son 7+4+6+1=18 exactos por solapamiento; Borg promueve un daily a weekly a monthly).

### 4.3. ¿Por qué exactamente esos números?

- **`keep_daily: 7`**: cubre la "ventana del olvido" típica — el operador descubre que algo se rompió hace 3-5 días. Subir a 14 dailies casi nunca aporta y ocupa más metadata Borg (no muchos blobs nuevos por dedup, pero sí índice).
- **`keep_weekly: 4`**: el mes anterior al actual. Suficiente para detectar regresiones que tardan en salir.
- **`keep_monthly: 6`**: medio año hacia atrás. Coincide con la cadencia de upgrades grandes (Nextcloud subido, MariaDB 10→11, etc.); permite restaurar un servicio a "antes del último major".
- **`keep_yearly: 1`**: un punto fijo histórico. Útil para diagnósticos forenses ("¿esto siempre estuvo así o lo introdujimos?") y para casos legales/personales raros (recuperar un fichero que el operador no recordaba haber tenido).

Los números son ajustables en [`./02-borgmatic.md`](./02-borgmatic.md). Si el repo Borg crece más rápido de lo previsto (medido con `borg info` y monitorizado por Grafana), la primera palanca es bajar `keep_daily` o `keep_weekly`. **No** subir todos los números a la vez "por si acaso": Borg dedup ayuda, pero la metadata sí pesa lineal con el número de snapshots.

### 4.4. Lifecycle en `dumps/`, `configs/`, `system/`

Los hooks `before_backup` escriben con fecha en el nombre (`-YYYY-MM-DD.sql.gz`). Sin lifecycle, la carpeta crece sin parar. Reglas:

- **`dumps/`**: borrar dumps de >14 días tras cada backup (el `after_backup` lo limpia). Borg ya tiene los snapshots históricos archivados; lo que vive en `dumps/` es solo "el último estable" para restore rápido.
- **`configs/`**: borrar snapshots de >90 días. Las configs cambian poco; mantener trimestre suelto en disco es barato y permite diff sin tocar Borg.
- **`system/`**: borrar snapshots de >180 días. Estado del host cambia muy poco; medio año es generoso.

Implementado con `find ... -mtime +N -delete` en `after_backup` hooks. Detalle en [`./02-borgmatic.md`](./02-borgmatic.md).

---

## 5. Hooks pre/post-backup

### 5.1. Patrón general

```
┌─────────────────────────────────────────────────────────────────────────┐
│  before_everything                                                      │
│    └─ avisar (Apprise "backup iniciado")                                │
│                                                                         │
│  before_backup  (uno por "fuente" de datos a snapshot consistente)      │
│    ├─ pg_dump   nextcloud  > /mnt/hd2t/backups/dumps/postgresql/...     │
│    ├─ mariadb-dump bookstack > /mnt/hd2t/backups/dumps/mariadb/...      │
│    ├─ sqlite3 .backup vaultwarden > /mnt/hd2t/backups/dumps/sqlite/...  │
│    ├─ pihole -a -t teleporter > /mnt/hd2t/backups/dumps/pihole/...      │
│    ├─ caddy adapt --pretty > /mnt/hd2t/backups/dumps/caddy/...          │
│    ├─ tailscale status --json > /mnt/hd2t/backups/dumps/tailscale/...   │
│    └─ dpkg -l > /mnt/hd2t/backups/system/packages-$(date +%F).txt       │
│                                                                         │
│  ── snapshot ──   (Borg crea un archivo nuevo en el repo)               │
│                                                                         │
│  after_backup                                                           │
│    └─ find /mnt/hd2t/backups/dumps/ -mtime +14 -delete                  │
│                                                                         │
│  after_everything                                                       │
│    ├─ rclone sync /mnt/hd2t/backups/borg/ b2:homelab-borg/              │
│    └─ avisar (Apprise "backup OK", Uptime Kuma push)                    │
│                                                                         │
│  on_error                                                               │
│    └─ avisar (Apprise + email "BACKUP FAILED: <step>")                  │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.2. La regla "dump primero, snapshot después"

Snapshotear el directorio "vivo" de una BD (`mysql/data/`, `pgsql/data/`, `db.sqlite3`) sin coordinación con el motor produce un restore corrupto en proporción al número de páginas en memoria no flusheadas al disco. La operación correcta:

1. **`before_backup`**: el motor exporta un fichero **consistente** (transacción atómica) a `/mnt/hd2t/backups/dumps/<motor>/<servicio>-YYYY-MM-DD.sql.gz` (o `.sqlite3`).
2. Borg snapshotea **tanto** el `data/` vivo como el `dumps/` recién escrito. El restore primario será el `dumps/` (consistente); el `data/` vivo es solo "por si acaso".
3. **`after_backup`**: limpia dumps antiguos (>14 días).

Convenciones del comando dump por motor:

| Motor | Comando canónico | Notas |
|---|---|---|
| **PostgreSQL** | `pg_dump --format=custom --compress=9 --no-owner --no-privileges <db>` | Custom format permite restauraciones parciales con `pg_restore`. `--no-owner/--no-privileges` evita líos de roles entre restauraciones. |
| **MariaDB / MySQL** | `mariadb-dump --single-transaction --routines --triggers --events <db>` | `--single-transaction` da snapshot consistente para InnoDB sin lockear. Patrón ya aplicado en Nextcloud ([`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md) §10.1). |
| **SQLite** | `sqlite3 <db> ".backup '<destino>'"` | API nativa, garantiza consistencia incluso con escrituras en curso. Patrón ya aplicado en Authelia ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §11). |
| **Redis** | (sin dump regular) | Estado efímero. Si en algún caso el servicio lo necesite (raro), `redis-cli BGSAVE` y respaldar el `.rdb`. |

### 5.3. Otros tipos de "dump" no-BD

Algunos servicios no tienen BD pero sí estado en memoria o configuración derivada que conviene materializar antes del snapshot:

| Servicio | Hook | Por qué |
|---|---|---|
| **Caddy** | `caddy adapt --config /etc/caddy/Caddyfile --pretty > .../caddy/caddyfile.json` | El JSON resuelve snippets, `import`s y variables. Útil para diagnósticos sin necesidad de los snippets originales. |
| **Pi-hole** | `pihole -a -t` (genera teleporter zip con todo) | Formato canónico de Pi-hole para backup/restore portable. |
| **Unbound** | `unbound-control dump_cache > .../unbound/cache.dump` | Permite "calentar" el cache tras un restart o restore (no crítico, pero rápido). |
| **Tailscale** | `tailscale status --json > .../tailscale/status.json` | Captura el tailnet visto desde la Pi en ese momento (peers, IPs). |
| **Stash** | (export desde la propia UI de Stash o `stashctl`) | Detalle en `../09-multimedia/05-stash.md` cuando se documente. |
| **Home Assistant** | snapshot con la propia API de HA | Detalle en `../08-domotica/01-home-assistant.md` cuando se documente. |

> **Patrón uniforme**: cada servicio que necesita un hook lo documenta en su sección "Backup" propia (§N de su doc); aquí se enumeran los **principios**, no los YAML. La unión de todos los hooks vive en `borgmatic.yml` ([`./02-borgmatic.md`](./02-borgmatic.md) §N).

---

## 6. Cifrado y secretos

### 6.1. Cifrado del repo Borg

Modo **`repokey-blake2`**:

- **`repokey`**: la clave maestra (256-bit AES-CTR + 256-bit HMAC) se guarda **dentro del repo**, cifrada por la passphrase del operador. Alternativa: `keyfile` (la clave vive fuera del repo, p. ej. en `~/.config/borg/keys/`). `repokey` simplifica el offsite (basta con replicar el repo, la clave viaja con él) a cambio de que un atacante con el repo y *fuerza bruta sobre la passphrase* tenga el material; con passphrase fuerte (≥ 24 caracteres aleatorios) eso es computacionalmente inviable.
- **`-blake2`**: hashing del contenido con BLAKE2b en lugar del SHA-256 por defecto. ARM64 sin AES-NI nota la diferencia (~2× más rápido en chunking + dedup). En la Pi 5 esto pasa de "el backup tarda 35 min" a "el backup tarda 18 min" en runs frescos.

### 6.2. Custodia de la passphrase de Borg

**Triple custodia** (mínimo):

1. **Vault local** del operador: KeePassXC en su máquina personal. Sincronizado a Syncthing (que a su vez no entra en el repo Borg propio... creando un loop si no se piensa) o a un USB cifrado.
2. **Backup físico**: passphrase impresa en papel, sobre cerrado en cajón fuera de casa (oficina, casa familiar, caja de seguridad).
3. **Vaultwarden** ([`../11-productividad/01-vaultwarden.md`](../11-productividad/01-vaultwarden.md)) una vez desplegado, **con un caveat circular**: Vaultwarden vive en el homelab; su backup necesita la passphrase de Borg. Por tanto Vaultwarden **no puede** ser la única custodia. Sirve como cuarta copia "de comodidad" para el operador desde el día a día.

Genéracion:

```bash
# Una sola vez en la vida del repo. NO regenerar por gusto: cambiar passphrase
# implica re-encriptar todo el material clave (operación soportada por
# `borg key change-passphrase`, pero costosa y delicada).
openssl rand -base64 48 | tr -d '\n' | head -c 64
```

48 bytes (~64 chars base64) son ~384 bits de entropía. Sobra para resistir cualquier ataque offline durante décadas.

### 6.3. Defensa contra ransomware: append-only y prune controlado

Si el host se compromete y un atacante con acceso a `root` ejecuta `borg delete <repo>` o re-encripta los ficheros del repo, no hay nada que hacer en el repo local. Mitigaciones:

- **Repo offsite append-only**: Backblaze B2 con bucket en modo "Object Lock" o "Application Key con permisos solo `writeFiles`, no `deleteFiles`". El atacante puede subir basura, no borrar lo que ya hay.
- **`prune`/`compact` lo ejecuta solo el operador desde un cliente con credenciales distintas**, no el host. Es decir: el host empuja con clave write-only; la limpieza periódica la hace el operador desde su laptop con clave full-access.
- **Versionado de B2**: Backblaze permite mantener versiones anteriores de objetos durante N días. Aunque el atacante consiga borrar, las versiones aún están.

Detalle del `rclone` con bucket append-only y de la operación de prune en [`./02-borgmatic.md`](./02-borgmatic.md) §N (offsite).

### 6.4. ¿Cifrar también el filesystem de `hd2t`?

Decisión por defecto: **no** en esta versión del homelab. Razones:

- LUKS sobre `hd2t` exige que el operador introduzca la passphrase **en cada arranque** (la Pi se reinicia con `unattended-upgrades` ocasionalmente). Esto rompe el "homelab desatendido". Hay alternativas con keyfile en la microSD, pero entonces el atacante con la microSD tiene la llave y el cifrado no aporta.
- Borg **ya cifra** los backups en el repo. Eso protege contra robo del **disco con backups** (sí cifrados).
- Los **datos vivos** (no respaldados): Nextcloud sí cifra at-rest opcionalmente (no recomendado: rompe la deduplicación de Borg, [`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md)). Los demás servicios viven en claro.
- El modelo de amenaza realista del homelab es: un atacante remoto a través de la red. LUKS no protege contra eso.

Si el operador cambia el modelo (Pi en oficina compartida, escenario "robo físico oportunista"), LUKS sobre `hd2t` se convierte en deseable. Se documentaría como variante en `../01-sistema/05-cifrado-disco.md` (no planificado actualmente; añadirlo al plan si se requiere).

---

## 7. Offsite

### 7.1. ¿Por qué offsite es no-negociable?

Sin offsite, los modos de fallo que **no** cubre la copia local (incendio, robo, inundación, rayo que fríe ambos discos USB) destruyen todo el homelab a la vez. La copia 3 es la diferencia entre "molestia" y "pérdida total".

### 7.2. Opciones para un homelab pequeño

| Opción | Coste mensual aproximado (≤ 500 GB) | Ventajas | Inconvenientes |
|---|---|---|---|
| **Backblaze B2** | ~$3 (a $6/TB/mes; egress gratis para volúmenes razonables) | S3-compatible (rclone + Borg con remote helper). Object Lock. UI simple. Retención por versión. | Coste lineal con tamaño; sin tier "frío" más barato. |
| **Storj DCS** | ~$2 (a $4/TB/mes; egress $7/TB) | S3-compatible, descentralizado, sin egress mínimo barato. | Cliente más nuevo; un poco menos maduro que rclone+B2. |
| **AWS S3 Glacier Instant** | ~$2 (a $4/TB/mes) | Familiar; integrable con `restic`/`rclone`. | Egress no trivial; UI más compleja. |
| **Hetzner Storage Box** | ~€3.50 / 1TB | Coste fijo bajo si caben los datos. SFTP / Borg directo. | No S3 nativo. Ancho de banda compartido. |
| **rsync.net** | ~$24 / TB/año (~$2/mes a 1TB) | Borg directo soportado (servidor con Borg ya instalado). Append-only nativo. | Algo más caro por TB que B2. |
| **Segundo Pi en otra casa** | ~€30 una vez (Pi 4 + disco) + electricidad ~€2/mes en casa de un familiar | Sin coste recurrente si ya hay un Pi. Control total. | Requiere coordinación humana, túnel WireGuard/Tailscale, mantenimiento del segundo nodo. |
| **Disco USB rotado físicamente** (el clásico "abuelo") | Coste del disco + tiempo del operador | Air-gap real, inmune a ransomware online. | Manual: hay que rotar (mensual/trimestral). Si se olvida, no protege. |

**Recomendación por defecto del homelab**: **Backblaze B2** vía `rclone sync` empujado desde un `after_everything` hook de Borgmatic. Justificación:

- Coste predecible (~3-5 €/mes para el volumen del homelab típico).
- API S3-compatible: el mismo `rclone` sirve para B2 hoy y para Storz/AWS mañana sin reescribir nada.
- Object Lock (append-only) protege contra ransomware en el host.
- Sin compromiso largo (mes a mes).
- Cumple holgadamente "1 offsite" sin gestionar un segundo Pi físico.

Configuración detallada del cliente (`rclone config`, credenciales B2 en `/mnt/hd2t/services/borgmatic/rclone.conf` con permisos `600 root:root`) en [`./02-borgmatic.md`](./02-borgmatic.md).

### 7.3. Qué se replica offsite y qué no

No todo lo que está en el repo Borg local **debe** ir offsite. Trade-off coste/criticidad:

- **Sí va offsite**: el repo Borg principal entero. Ya es deduplicado y comprimido; el coste real de transferir/almacenar es bajo.
- **Decisión por servicio**: si se decide respaldar la biblioteca de Stash (multi-TB) o `nextcloud/data/` (potencialmente decenas de GB), entran en el cálculo de coste offsite. Política recomendada:
  - **Sí** offsite: `services/`, `secrets/`, `dumps/`, `configs/`, `system/`, `~/homelab/`, sync personal de Syncthing (`obsidian/`, `phone-photos/` parcial).
  - **Opcional offsite**: `nextcloud/data/` (depende de cuánto pese y de cuán crítico sea para el operador).
  - **Probablemente no** offsite (default): `media/movies/`, `media/tv/`, `stash/library/` (reemplazables).

Esto se traduce en **dos repos Borg** en variantes avanzadas: `borg-core` (todo lo crítico, va offsite) y `borg-media` (multimedia pesada, solo local). En la versión por defecto del homelab basta un repo único con `exclude_patterns` y un `rclone sync` que filtra al subir. Decisión y diseño en [`./02-borgmatic.md`](./02-borgmatic.md) §N.

### 7.4. Ancho de banda casero

Una conexión típica casera de 100/300 Mbps (subida 30-50 Mbps) tarda en empujar:

- 1 GB nuevo → ~3-5 min.
- 10 GB nuevos → ~30-60 min.
- 100 GB iniciales (primera réplica completa) → 6-12 h. Programar fuera de horas de uso de la casa o sembrar el repo offsite con `rclone copy --bwlimit 10M` durante una semana de noches.

Tras la primera siembra, los `rclone sync` nocturnos empujan solo los blobs nuevos (Borg dedup ⇒ habitualmente decenas de MB por noche). El uso de ancho de banda en régimen permanente es despreciable.

---

## 8. Verificación de la restauración

### 8.1. La regla

> **Un backup que nunca se ha restaurado no es un backup, es una esperanza.**

Operacionalmente: cualquier procedimiento de backup que no incluya **verificación periódica** acaba descubriendo el día del incidente que el repo está corrupto, que falta una variable, que el dump está vacío o que el operador olvidó el secret crítico.

### 8.2. Tres niveles de verificación

| Nivel | Frecuencia | Qué hace | Quién |
|---|---|---|---|
| **L1 — Health check del repo** | Diaria, post-backup | `borg check --repository-only`: verifica integridad estructural del repo (no lee blobs). Rápido (~minutos). | Hook `after_backup` de Borgmatic. |
| **L2 — Verify-data del repo** | Mensual | `borg check --verify-data`: lee y verifica HMAC de **todos** los blobs. Lento (horas) pero detecta corrupción silenciosa de disco. | Timer mensual. Detectaría bit-rot de `hd2t`. |
| **L3 — Smoke test de restauración** | Mensual | Restaurar un servicio "pequeño" (Vaultwarden o Authelia) en un directorio temporal, arrancarlo en un compose paralelo, verificar login. | Manual o script semi-automatizado. |

### 8.3. Smoke test mensual: procedimiento

Resumen del flujo (procedimiento detallado en [`./03-backup-docker-volumes.md`](./03-backup-docker-volumes.md)):

1. Elegir un servicio pequeño con datos críticos. Rotación sugerida: Vaultwarden (mes 1), Authelia (mes 2), Bookstack (mes 3), Nextcloud-mini (mes 4, solo metadata + algunos ficheros), volver a Vaultwarden.
2. `borg list <repo>` → tomar el snapshot del día anterior.
3. `borg extract --target /mnt/hd2t/backups/restore-test/<servicio>-YYYY-MM-DD/ <repo>::<snapshot> path/al/servicio`.
4. Inspeccionar: ficheros esperados presentes, tamaños razonables.
5. Para BD: levantar un MariaDB/PostgreSQL/SQLite contenedor temporal apuntando al directorio restaurado, hacer `SELECT count(*)` en una tabla canónica.
6. Para servicio entero: arrancar un compose paralelo con `name: <servicio>-restore` en una red Docker separada, verificar que **arranca** (no necesariamente que sea idéntico al de producción — lo que se verifica es que el backup contiene "todo lo necesario para arrancar").
7. Limpiar: `docker compose -p <servicio>-restore down -v && rm -rf /mnt/hd2t/backups/restore-test/<servicio>-YYYY-MM-DD/`.
8. Anotar en `~/homelab/operations/restore-tests.log` (versionado en git): fecha, servicio probado, resultado, problemas encontrados.

### 8.4. Lo que se aprende del smoke test

Cada smoke test típicamente revela **un** problema pequeño (especialmente en los primeros meses):

- "El compose monta `secrets/` pero nadie respaldaba el directorio padre con sus permisos." → ajustar `source_directories` o `chmod` en restore.
- "El dump de la BD se generó vacío (0 B) por un error en el hook que pasó silencioso." → revisar `before_backup` de ese servicio, añadir validación `[ -s file ]` post-dump.
- "Restauración funciona pero con avisos `default_storage_engine=InnoDB` no compatible con la nueva imagen MariaDB." → documentar el match de versión imagen↔dump.

Esos hallazgos se convierten en mejoras del propio backup. Sin smoke test, se acumulan invisibles.

### 8.5. Reporte de verificación

Cada nivel emite señal a:

- **Uptime Kuma** ([`../05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md)) vía monitor "Push" (heartbeat). Si Borgmatic deja de empujar, Uptime Kuma alerta tras N minutos.
- **Apprise** → Telegram/email en `on_error` y opcionalmente en `after_everything` (heartbeat de éxito).
- Anotación en log persistente (`/mnt/hd2t/services/borgmatic/logs/borgmatic.log` y `~/homelab/operations/restore-tests.log`).

---

## 9. Notificaciones y monitorización

### 9.1. Canales

| Canal | Para qué | Configurado en |
|---|---|---|
| **Apprise → Telegram** | Alertas inmediatas: backup fallado, smoke test fallado, repo corrupto. | `borgmatic.yml` → `apprise:` con tokens en `secrets/`. Tokens generados con `@BotFather` en Telegram. |
| **Apprise → Email** | Heartbeat diario "OK / X archivos / Y MB nuevos / Z dedup ratio". Útil porque "ningún email = ¿está fallando o no se está ejecutando?" es la pregunta correcta. | Igual; SMTP de Gmail/Fastmail. |
| **Uptime Kuma push** | "Watchdog inverso": Borgmatic empuja `curl` cada noche; si Uptime Kuma deja de recibir 2 noches seguidas, alerta. | Detalle en [`../05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md) §9. |
| **Métricas Prometheus** | Tendencia: tamaño del repo, tiempo de backup, ratio de dedup, blobs nuevos por noche. | Borgmatic exporta `borgmatic-exporter` para Prometheus. Dashboards en Grafana. Detalle en [`../05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md) cuando se configure. |

### 9.2. Heartbeat de éxito, no solo alerta de fallo

Una pieza crítica que la gente olvida: alertar **solo** en fallo es insuficiente. Si el cron no está activo, no falla — simplemente no se ejecuta, y nadie se entera. Por eso se programa:

- **Cada noche tras éxito**: Borgmatic hace `curl https://kuma.lan/api/push/<token>?status=up&msg=OK&ping=<minutos>` (Uptime Kuma push monitor).
- **Si pasan N=48 horas sin push**: Uptime Kuma marca el monitor como "Down" y dispara su propia notificación (Telegram/email con otro canal del que lo dispara Borgmatic). Doble canal protege contra "el SMTP de Gmail está caído justo cuando todo se rompe".

---

## 10. Disaster recovery (overview)

Procedimiento end-to-end documentado en [`../13-operaciones/02-disaster-recovery.md`](../13-operaciones/02-disaster-recovery.md). Resumen del flujo desde "la Pi se ha incendiado / robado" hasta "el homelab vuelve a funcionar":

1. **Pi nueva**: pedirla (Pi 5 + accesorios). Mientras llega, levantar un backup mínimo en otro host (laptop con Docker) si hay servicios que el operador necesite con urgencia (Vaultwarden, Bookstack).
2. **Recuperar la passphrase de Borg** (KeePassXC en laptop / sobre cerrado / Vaultwarden si está accesible desde otro lado).
3. **Recuperar los discos**: si solo se ha quemado la Pi y los discos sobreviven, conectarlos a otra máquina, recuperar `/mnt/hd2t/backups/borg/` y/o tirar directamente del offsite.
4. **Reflashear microSD**: `Raspberry Pi OS Lite 64-bit`, reaplicar [`../01-sistema/`](../01-sistema/).
5. **Reaplicar [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md)** y [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) (ambos idempotentes).
6. **Reinstalar Docker + red `homelab`** ([`../02-docker/`](../02-docker/)).
7. **Restaurar `~/homelab/`** con `git clone <origin>`. Esto trae todos los `docker-compose.yml`, `Caddyfile`, `configuration.yml`, `.env.example`.
8. **Restaurar el repo Borg** (si los discos sobreviven, ya está; si no, `rclone sync b2:homelab-borg/ /mnt/hd2t/backups/borg/`).
9. **Restaurar fase por fase**: red → seguridad → almacenamiento → resto. Cada doc de servicio tiene su sección "Restore" detallada.
10. **Verificar**: Uptime Kuma vuelve a tener todos los monitores en verde; smoke tests `borg extract` aleatorios.

> **Tiempo estimado de recovery completo**: 6-12 h de trabajo distribuidas en 2-3 días (mientras llega hardware, mientras se siembra el offsite de vuelta, etc.). El operador debe asumir esa ventana en su planning. Si necesita RPO/RTO menores (homelab usado para servicios que no admiten 1-2 días de caída), pasar al patrón "dos Pi calientes" — fuera del scope de este homelab personal.

---

## 11. Lista de Verificación

Antes de pasar a [`./02-borgmatic.md`](./02-borgmatic.md):

- [ ] `ls -ld /mnt/hd2t/backups` muestra `drwx------ ... root root` (modo `700`).
- [ ] `sudo ls /mnt/hd2t/backups` lista `borg`, `dumps`, `configs`, `system`.
- [ ] `sudo ls /mnt/hd2t/backups/dumps` lista (al menos) `mariadb`, `postgresql`, `sqlite` (las subcarpetas por servicio se crean en cada hook). Si no, `sudo install -d -o root -g root -m 700 /mnt/hd2t/backups/dumps/{mariadb,postgresql,sqlite}`.
- [ ] El operador tiene **decidida** y **escrita** (KeePassXC + sobre físico) la passphrase de Borg que se generará en [`./02-borgmatic.md`](./02-borgmatic.md). NO improvisar la passphrase la primera vez que se inicialice el repo.
- [ ] El operador tiene **cuenta creada** y **credenciales guardadas** del proveedor offsite elegido (B2 / Storj / etc.), o ha decidido qué hardware usará (segundo Pi remoto).
- [ ] **`hd2t` con ≥ 200 GB libres** (`df -h /mnt/hd2t | tail -1`).
- [ ] **Reloj sincronizado** (`timedatectl | grep 'System clock synchronized'` → `yes`).
- [ ] **Email/Telegram funcionando** desde la Pi: enviar un email de prueba con `msmtp` o un mensaje a Telegram con `curl` al bot, verificar recepción.
- [ ] **Uptime Kuma desplegado** (fase 5) y se ha creado un monitor "Push" reservado para Borgmatic (ver [`../05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md) §9).
- [ ] **`~/homelab/` versionado en remoto** (GitHub privado o Gitea propio). Verificación: `git -C ~/homelab status` y `git remote -v`. Sin esto, la **definición** del homelab no entra en la copia 3.
- [ ] **Cada doc de servicio ya desplegado** (fases 0-6) tiene su sección "Backup" leída, y sus dumps en `dumps/<servicio>/` están listos para alimentar a Borgmatic.
- [ ] **Plan de smoke test mensual** anotado en el calendario del operador (ej. "Día 1 de cada mes: smoke test rotando servicio").

---

## 12. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `Permission denied` al `cd /mnt/hd2t/backups` con usuario `homelab` | Comportamiento esperado: `0700 root:root`. | Usar `sudo`. Cualquier acceso al backup es de root. |
| Tras el primer `borgmatic init`, el repo en `/mnt/hd2t/backups/borg/` queda con propietario raro | Borgmatic se ejecutó como otro usuario (no `root`). | Re-ejecutar como `root` (es el único modo soportado por systemd unit en [`./02-borgmatic.md`](./02-borgmatic.md)). Si el repo quedó vacío, `rm -rf /mnt/hd2t/backups/borg/* && borgmatic init`. |
| El primer backup tarda > 24 h | **Esperado** en la primera ejecución (sin dedup previo, todo es blob nuevo). Subsiguientes son incrementales. | Programar la primera ejecución manual en un fin de semana o dejar 48 h de margen antes de armar timer. |
| `dumps/<servicio>/` se llena de ficheros antiguos (>14 días) | El hook `after_backup` no se está ejecutando, o el servicio no tiene `after_backup` definido. | Revisar `borgmatic config validate` y los `after_backup` de cada servicio. Limpieza manual puntual con `find /mnt/hd2t/backups/dumps -mtime +14 -delete` (`sudo`). |
| `borg check --verify-data` reporta corrupción en blobs | Bit-rot en `hd2t` o write error silencioso. | Inmediato: dejar de escribir en el repo (parar timer Borgmatic), restaurar desde offsite (`rclone copy b2:homelab-borg/ /mnt/hd2t/backups/borg-restored/`), comparar. Investigar `dmesg` y SMART de `hd2t`. |
| Smoke test del mes falla pero el daily backup pasa "OK" | El `borg check --repository-only` no detecta inconsistencias semánticas (tablas con FK rotas, secrets desincronizados con DB). | Esto es exactamente para lo que sirve el smoke test. Investigar el servicio concreto, posiblemente añadir un `before_backup` que faltaba. |
| Uptime Kuma no recibe el heartbeat tras el backup | Hook `after_everything` falló o el contenedor `kuma` no es accesible desde el contexto de Borgmatic (que corre en host, no en Docker). | Probar manualmente `curl https://kuma.lan/api/push/<token>` desde el host como root. Resolver hostname (Pi-hole) y certs (CA interna importada). Detalle en [`../05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md). |
| `rclone sync` al offsite tarda 8 h cada noche | El primer sync tras un cambio grande (snapshot semanal, compactación) sube muchos blobs. | Aceptarlo en runs puntuales. Si es persistente, revisar si Borg `compact` está corriendo demasiado a menudo (cada compact reescribe blobs ⇒ hay que resubir). |
| `borg compact` falla con `Repository is in append-only mode` desde el host | Configuración correcta para defensa anti-ransomware: el host **no** puede compactar. | Compactar **manualmente** desde el cliente del operador (laptop) con la clave full-access, no desde el host. |
| Olvidé la passphrase de Borg | Sin passphrase, **el repo es ilegible**. No hay recovery posible. | **Triple custodia obligatoria** (§6.2). Si se llega aquí, el backup está perdido. Aprender la lección: revisar §6.2 antes de inicializar el repo. |
| El offsite (B2/Storj) factura más de lo esperado | Almacenamiento creciendo más rápido de lo previsto: probablemente algún servicio escribe mucho material no excluible o `nextcloud/data/` ha crecido. | `borg info` y `du -sh /mnt/hd2t/services/*/`. Decidir: comprar más almacenamiento offsite o excluir más cosas. Revisar §2.2. |
| Cron / timer no dispara nunca | Configuración de systemd timer mal instalada. | `systemctl list-timers borgmatic*`. Si vacío, revisar [`./02-borgmatic.md`](./02-borgmatic.md) §N. |
| El operador renombra `~/homelab` o cambia su path y los `source_directories` apuntan a la ruta antigua | Los siguientes backups guardan vacío. | Mantener la ruta del repo del homelab estable. Si se cambia, actualizar `borgmatic.yml` y verificar con un smoke test inmediato. |

---

## Referencias

- [BorgBackup — documentación oficial](https://borgbackup.readthedocs.io/)
- [Borgmatic — documentación oficial](https://torsion.org/borgmatic/)
- [Borg — `borg init` y modos de cifrado (`repokey-blake2`, `keyfile`, ...)](https://borgbackup.readthedocs.io/en/stable/usage/init.html)
- [Borg — `borg check`](https://borgbackup.readthedocs.io/en/stable/usage/check.html)
- [Backblaze B2 — Object Lock](https://www.backblaze.com/cloud-storage/file-lock)
- [Storj DCS — S3-compatible gateway](https://docs.storj.io/dcs/api-reference/s3-compatible-gateway)
- [rclone — sync con B2](https://rclone.org/b2/)
- [Apprise — notificaciones unificadas](https://github.com/caronc/apprise)
- [Uptime Kuma — Push monitor](https://github.com/louislam/uptime-kuma/wiki/Monitor)
- [BLAKE2 — RFC 7693](https://datatracker.ietf.org/doc/html/rfc7693)
- [Veeam — "3-2-1 backup rule"](https://www.veeam.com/blog/321-backup-rule.html) (referencia general; el principio data de los años 70 — Peter Krogh, *The DAM Book*)
