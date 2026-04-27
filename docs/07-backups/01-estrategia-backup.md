# Estrategia de backup del homelab

## Descripción

Define **qué se respalda, dónde, con qué frecuencia, durante cuánto tiempo y cómo se verifica** que la restauración funciona, antes de desplegar la primera herramienta concreta de backup. Es el documento "marco" de la **Fase 7 — Copias de Seguridad**: fija el contrato que después implementan `docs/07-backups/02-borgmatic.md` (motor principal) y `docs/07-backups/03-backup-docker-volumes.md` (procedimientos por servicio), y al que se referirán las secciones **Backup** de cada doc de servicio (Nextcloud, Vaultwarden, Paperless, Home Assistant, …).

Su producto no es un contenedor en marcha sino un **plan escrito** vinculante:

- la regla **3-2-1** aplicada al hardware concreto del homelab (Pi 5 + `hd2t` + `hd5t`);
- una **clasificación de datos** que reparte cada cosa entre _backup completo_ / _backup parcial_ / _no backup_ / _regenerable_;
- un **calendario** (`hourly`/`daily`/`weekly`/`monthly`) con su política de **retención** estilo GFS;
- una **gestión de claves de cifrado** y _passphrase_ que sobreviva a la pérdida de la propia Pi;
- un **régimen de restauraciones de prueba** ("drills"), porque un backup que nunca se ha restaurado no es un backup;
- las **convenciones que cada servicio respetará** en su propia sección **Backup** (qué dumpea, dónde, con qué nombre).

> **Alcance**: este documento **no instala nada**. No despliega Borgmatic, no crea repos, no configura `cron` ni `systemd timers`, no genera claves SSH para el destino offsite, no abre cuentas en proveedores cloud. Todo eso vive en `docs/07-backups/02-borgmatic.md` y `docs/07-backups/03-backup-docker-volumes.md`. Aquí se establecen únicamente las **decisiones** que esos docs aplican.

> **Recordatorio del reparto de discos** (definido en `docs/00-hardware/03-preparacion-discos.md` y formalizado en `docs/01-sistema/04-estructura-directorios.md`):
> - **`hd5t`** (5 TB) → biblioteca multimedia de Stash, montada en `/mnt/hd5t`. **No entra en backup operacional** (ver más abajo).
> - **`hd2t`** (2 TB) → datos de servicios, volúmenes Docker, swap y **rama de backups locales** en `/mnt/hd2t/backups/borg/`, `/mnt/hd2t/backups/dumps/`, `/mnt/hd2t/backups/exports/`.

> **Recordatorio de red**: el homelab es solo LAN + Tailscale (`docs/03-red/05-tailscale.md`). El destino "offsite" será siempre **iniciado desde la Pi** (`push`-style); no hay puertos abiertos hacia internet ni servicios escuchando para recibir backups remotos.

---

## Requisitos previos

- `docs/00-hardware/03-preparacion-discos.md` completado: `hd2t` montado en `/mnt/hd2t` con SMART verificado y entrada persistente en `/etc/fstab`. Sin ese disco con salud confirmada, los backups locales se construyen sobre arena.
- `docs/01-sistema/02-configuracion-inicial.md` completado: hora correcta vía NTP. Las marcas temporales de los _archives_ de Borg (que componen la política de retención) son de poca utilidad si el reloj de la Pi va a la deriva.
- `docs/01-sistema/03-seguridad-base.md` completado: usuario `homelab` con clave SSH, `sudo` sin password para tareas concretas, firewall `nftables` activo. La Pi sólo necesita conectividad **saliente** hacia el destino offsite (TCP/22 a `rsync.net`, TCP/443 a B2, etc.).
- `docs/01-sistema/04-estructura-directorios.md` completado: existen `/mnt/hd2t/backups/borg/`, `/mnt/hd2t/backups/dumps/` y `/mnt/hd2t/backups/exports/` con permisos `0700 root:root` (la rama es legible **solo por root**). Borgmatic se ejecutará como `root` (necesita leer volúmenes con UIDs arbitrarios) y escribirá ahí.
- `docs/02-docker/02-estructura-compose.md` completado: el árbol de configuración versionable vive en `~/homelab/` (git, fuera de `hd2t`), con `.env` por stack en modo `0600`. El propio `~/homelab/` será una de las **fuentes** que respaldemos.
- Conectividad saliente probada (sólo verificación; no se configuran credenciales aquí):

  ```bash
  # SSH saliente al puerto 22 (destino tipo rsync.net / Hetzner / segunda Pi)
  nc -zv rsync.net 22 2>&1 | head -1

  # HTTPS saliente al puerto 443 (destino tipo Backblaze B2 / S3)
  curl -sI https://api.backblazeb2.com | head -1
  ```

  Si el firewall de salida o el ISP bloquean alguno de los dos, decidirlo **ahora** condiciona qué proveedores quedan disponibles (ver **Decisiones de diseño → Destino offsite**).

---

## La regla 3-2-1 aplicada al homelab

La regla clásica de backups exige, **por cada dato crítico**, mantener:

1. **3 copias** de los datos: la original + dos copias.
2. En **2 medios distintos** (no las dos copias en el mismo disco).
3. **1 copia offsite**, fuera del edificio donde están los originales.

Mapeo concreto al hardware del homelab:

| Capa  | Cumplimiento                                                                                                                                                     | Doc/herramienta                                                                          |
|-------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------|
| 1     | **Original**: `/mnt/hd2t/services/<servicio>/...` (volumen Docker bind-mounted en `hd2t`).                                                                       | `docs/01-sistema/04-estructura-directorios.md`                                            |
| 2     | **Copia local**: repo Borg cifrado y deduplicado en `/mnt/hd2t/backups/borg/homelab/` — **mismo disco físico que el original**, ver advertencia abajo.            | `docs/07-backups/02-borgmatic.md`                                                         |
| 2 bis | **Copia local en otro medio**: copia adicional en la microSD del propio Pi **descartada** (capacidad insuficiente: 64 GB vs varios cientos de GB de datos crudos). | —                                                                                        |
| 3     | **Copia offsite**: repo Borg paralelo en proveedor cloud (rsync.net, Hetzner Storage Box, segunda Pi en otra ubicación) o réplica de objetos vía MinIO → B2/S3. | `docs/07-backups/02-borgmatic.md` (Borg directo) y/o `docs/06-almacenamiento/04-minio.md` (mirror) |

> **Aviso sobre la copia local en `hd2t`**: respaldar dentro del **mismo disco** donde están los datos originales **no satisface el "2 medios distintos"** de 3-2-1. Si el HDD físico falla (sector dañado, controladora USB, fallo eléctrico, pérdida de la carcasa), se pierden a la vez el original y la copia local. La copia en `hd2t/backups/borg/` cumple un papel **complementario** y muy útil — restauración rápida tras un borrado accidental dentro de un servicio, retención más larga sin coste de transferencia, _staging_ antes del envío offsite — pero **no** sustituye a la copia offsite. Es la copia offsite la que satisface el 3-2-1, no la local.
>
> Variantes válidas para reforzar la copia local (todas opcionales y diferidas a fases posteriores):
> - **Disco USB rotativo**: un tercer HDD externo `hdb` (≥ 2 TB) que se conecta sólo durante la ventana de backup mensual y se guarda físicamente separado del homelab. Cumple "2 medios distintos" sin internet.
> - **Segundo Pi en otra habitación de la misma vivienda**: cumple "2 medios distintos" pero **no** "1 offsite" si la vivienda entera se ve afectada (incendio, robo).
> - **Segunda Pi en casa de un familiar / amigo accesible por Tailscale**: cumple "2 medios distintos" **y** "1 offsite" sin pagar a un proveedor cloud. Es la opción "premium" si está disponible.

### Reformulación operativa: las dos rutas obligatorias

Para evitar confusión, el homelab implementa el 3-2-1 con **dos rutas independientes** a partir del **mismo conjunto de fuentes**:

```
                   [ Fuentes vivas ]
                          │
                          ▼
                  ┌──────────────────┐
                  │   Borgmatic      │  ──┐
                  │   (cron diario)  │    │
                  └──────────────────┘    │
                          │               │
            ┌─────────────┴───────┐       │
            ▼                     ▼       │
     [ Repo Borg local ]    [ Repo Borg    │
     /mnt/hd2t/backups/      offsite ]     │
     borg/homelab/                         │
            ▲                              │
            │                              │
            │ (opcional, cinta mensual)    │
            │                              │
     [ Disco USB hdb        ]              │
     (rotación off-line)                   │
                                           ▼
                              [ Notificaciones ntfy/email ]
```

Cada ejecución de `borgmatic` escribe **a los dos repos** (local + offsite) en la misma corrida. No se hace primero local y "cuando dé tiempo" offsite: la deduplicación de Borg permite que la subida offsite sea sólo el delta (nuevos chunks), normalmente unas decenas de MB al día. La copia rotacional opcional al disco `hdb` es una **réplica** del repo local, no un backup independiente.

---

## Clasificación de datos

Cada cosa que vive en la Pi entra en una de **cuatro categorías**. Cada doc de servicio (en su sección **Backup**) declarará explícitamente en qué categoría caen sus volúmenes y pondrá la entrada correspondiente en el `borgmatic.yaml`.

### Categoría A — _Crítico, irrecuperable_

Datos que el operador **no puede regenerar de cero** sin pérdida total. Una pérdida en esta categoría es un fracaso del homelab.

| Dato                                                          | Origen                                                   | Tamaño típico  |
|---------------------------------------------------------------|----------------------------------------------------------|----------------|
| Bóveda de **Vaultwarden**                                     | `/mnt/hd2t/services/vaultwarden/data/db.sqlite3`         | < 50 MB        |
| Bases de datos de **Nextcloud**                               | dump de MariaDB/Postgres                                 | 100 MB – 5 GB  |
| **Datos de usuario de Nextcloud**                             | `/mnt/hd2t/services/nextcloud/data/`                     | decenas de GB  |
| Configuración de **Home Assistant** (automatizaciones, devices) | `/mnt/hd2t/services/home-assistant/`                     | 1 – 5 GB       |
| **Paperless-ngx**: BD + originales escaneados                 | dump Postgres + `media/documents/originals/`             | varios GB      |
| **Bookstack**: BD                                             | dump MariaDB                                             | < 1 GB         |
| **Mealie**, **Linkding**, **FreshRSS**: BD                    | SQLite o Postgres dump                                   | < 500 MB c/u   |
| Repositorio **`~/homelab/`** completo                         | `compose`, configs, plantillas (sin `.env`)              | < 100 MB       |
| **`.env`** de cada stack                                      | `~/homelab/*/.env`                                       | < 50 KB total  |
| **Configuración de Pi-hole**                                  | `/mnt/hd2t/services/pihole/etc-pihole/`                  | < 50 MB        |
| **Authelia**: `users_database.yml`, `configuration.yml`, `notifier.smtp.password` | `/mnt/hd2t/services/authelia/config/`                    | < 1 MB         |
| **Caddy**: certificados de la CA local                        | `/mnt/hd2t/services/caddy/data/`                         | < 10 MB        |
| **Repos Git** locales (si los hubiera fuera de `~/homelab/`)  | varios                                                   | variable       |

Política: **backup diario completo + retención larga (≥ 12 meses)** + **copia offsite obligatoria**.

### Categoría B — _Importante pero regenerable con esfuerzo_

Datos que se podrían reconstruir descargando otra vez de internet o re-escaneando, pero al coste de horas o días de operador.

| Dato                                                          | Cómo se regeneraría sin backup                          |
|---------------------------------------------------------------|---------------------------------------------------------|
| Configuración de **Sonarr/Radarr/Prowlarr** (perfiles, indexadores, listas) | re-pinear todos los indexadores y reanudar ediciones manuales |
| Configuración de **Jellyfin** (usuarios, vistas, intros)      | re-crear usuarios y rehacer scans                       |
| **Navidrome**, **Audiobookshelf**, **Calibre-Web** (BD de progreso, valoraciones, cuentas) | volver a empezar el progreso de escucha/lectura desde cero |
| Configuración de **Grafana** (dashboards, datasources, alertas) | re-importar JSONs desde la guía de despliegue            |
| **Prometheus** TSDB (métricas históricas)                     | aceptar "el histórico arranca aquí"                     |
| **Dashboards** de Homepage / Homarr                           | re-pegar configuración desde `~/homelab/`               |

Política: **backup diario** (entran en el mismo Borg que la categoría A) + **retención media** (3–6 meses) + **copia offsite**. La diferencia con A es operativa, no técnica: si hay que restaurar después de un desastre y la copia offsite tarda en bajar, B puede esperar; A no.

### Categoría C — _Voluminoso y regenerable_

Datos que se descargaron una vez de internet y pueden volver a descargarse.

| Dato                                                          | Política                                                              |
|---------------------------------------------------------------|-----------------------------------------------------------------------|
| Bibliotecas multimedia secundarias de **Jellyfin / Navidrome / Audiobookshelf / Calibre-Web** en `/mnt/hd2t/services/shared/{media,music,audiobooks,ebooks}/` | **No entra en Borg**. Catálogo + metadata sí (forma parte de la BD del servicio); los binarios no. |
| Descargas de **Transmission** en curso (`/mnt/hd2t/services/transmission/downloads/`) | **No entra en Borg**. Re-descargables.                                |
| Caché de **Jellyfin** (`/mnt/hd2t/services/jellyfin/cache/`, `transcodes/`) | **Excluida explícitamente** (`exclude_patterns` en `borgmatic.yaml`).  |

Política: **no respaldar**. Documentar en el doc del servicio cómo restablecer la biblioteca tras un fallo (re-importación desde el origen). Si en algún momento hace falta una copia "por si acaso" de la biblioteca multimedia, va a su propio Borg con cadencia mensual y retención corta — **no** mezclar con el repo de la categoría A.

### Categoría D — _Stash en `hd5t`_

Caso especial. La biblioteca de Stash en `/mnt/hd5t/stash/data/` es voluminosa (potencialmente terabytes), de adquisición manual y, según la sensibilidad del operador, puede o no querer salir del edificio.

Tres opciones documentadas, todas válidas; la elección final se anota en `docs/09-multimedia/05-stash.md` cuando se despliegue:

| Opción                                              | Coste                                  | Cumple 3-2-1                         |
|-----------------------------------------------------|----------------------------------------|--------------------------------------|
| **No respaldar la biblioteca**, sólo BD/metadata de Stash (`/mnt/hd2t/services/stash/{config,metadata}/`) | 0 €                                    | No para los binarios; sí para la BD |
| **Réplica local periódica** a un disco USB rotativo `hdc` mensual | precio de un HDD usado                | "2 medios distintos" sí, offsite no |
| **Copia offsite cifrada** a un proveedor que acepte volúmenes grandes (rsync.net, Hetzner Storage Box ≥ 5 TB) | 5 – 15 €/mes                          | Sí                                  |

La **BD/metadata de Stash** sí entra siempre en la categoría A: pesa muy poco y su pérdida supondría re-scrapear y re-etiquetar toda la biblioteca.

### Categoría E — _Efímero o sintetizable_

Datos que **nunca** se respaldan porque el contenedor los regenera al arrancar:

- Volúmenes de **Stirling-PDF** (servicio _stateless_).
- **Watchtower**, **Dozzle**, **cAdvisor** (no almacenan estado relevante).
- Caches de Redis, **Mosquitto** _retained messages_ (rebuildables o irrelevantes).
- `/mnt/hd2t/services/jellyfin/transcodes/` (tmpfs en runtime).
- `/var/lib/docker/` completo (las imágenes se vuelven a tirar con `docker compose pull`).

Cada doc de servicio listará en su sección **Backup** sus volúmenes y los marcará explícitamente como categoría E si no se respaldan.

---

## Inventario consolidado de fuentes

A partir de la clasificación, el `source_directories` de Borgmatic queda con esta forma (el _layout_ exacto se completa en `docs/07-backups/02-borgmatic.md`):

```yaml
source_directories:
  # Configuración versionable + .env
  - /home/homelab/homelab            # repo de compose
  - /etc                             # configs del host (nftables, fstab, crontabs, /etc/ssh)

  # Servicios — datos persistentes (categorías A y B)
  - /mnt/hd2t/services/authelia
  - /mnt/hd2t/services/caddy/data    # CA local
  - /mnt/hd2t/services/pihole
  - /mnt/hd2t/services/nextcloud/data
  - /mnt/hd2t/services/vaultwarden/data
  - /mnt/hd2t/services/home-assistant
  - /mnt/hd2t/services/paperless
  - /mnt/hd2t/services/bookstack
  - /mnt/hd2t/services/mealie
  - /mnt/hd2t/services/linkding
  - /mnt/hd2t/services/freshrss
  - /mnt/hd2t/services/grafana/data
  - /mnt/hd2t/services/uptime-kuma
  - /mnt/hd2t/services/syncthing
  - /mnt/hd2t/services/sonarr
  - /mnt/hd2t/services/radarr
  - /mnt/hd2t/services/prowlarr
  - /mnt/hd2t/services/transmission/config        # solo config, no descargas
  - /mnt/hd2t/services/jellyfin/config            # solo config, no caches
  - /mnt/hd2t/services/navidrome
  - /mnt/hd2t/services/audiobookshelf
  - /mnt/hd2t/services/calibre-web
  - /mnt/hd2t/services/stash/{config,metadata}    # solo BD/metadata, no biblioteca

  # Dumps de BD generados por hooks pre-backup (volátiles)
  - /mnt/hd2t/backups/dumps

exclude_patterns:
  - '*/cache/*'
  - '*/transcodes/*'
  - '*.tmp'
  - '*/lost+found'
  - /mnt/hd2t/services/jellyfin/cache
  - /mnt/hd2t/services/jellyfin/transcodes
  - /mnt/hd2t/services/transmission/downloads
  - /mnt/hd2t/services/shared        # multimedia regenerable
  - /mnt/hd2t/services/prometheus    # opt-out por defecto, ver más abajo
```

> **Sobre Prometheus**: la TSDB en `/mnt/hd2t/services/prometheus/data/` es voluminosa (varios GB), de _churn_ alto (Borg deduplicará poco), y su pérdida es aceptable (la métrica histórica vuelve a llenarse desde el día de la restauración). Por defecto **no se incluye**. Si el operador prefiere conservarla, basta con quitar la línea del `exclude_patterns` y ajustar la retención del repo offsite (Prometheus puede añadir cientos de GB al año).

> **Sobre `/etc`**: incluir todo `/etc` permite que un disaster recovery completo (`docs/13-operaciones/02-disaster-recovery.md`) restaure firewall, fstab, crontabs y SSH host keys sin tener que rederivarlas. Ocupa < 50 MB.

---

## Calendario y retención

### Cadencia operativa

Política de referencia, implementada por un único `systemd timer` que dispara `borgmatic` (los detalles en `docs/07-backups/02-borgmatic.md`):

| Cuándo                                  | Quién dispara                                    | Qué hace                                                                                                              |
|-----------------------------------------|--------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|
| **Diario 03:30 local**                  | `borgmatic.timer` (`OnCalendar=*-*-* 03:30:00`)  | _hooks_ pre-backup (dumps SQL → `/mnt/hd2t/backups/dumps/`), `borg create` en repo local **y** offsite, `borg prune`, `borg check --repository-only` semanal. |
| **Semanal domingo 04:30**               | `borgmatic.timer` (rama "weekly")                | `borg check --verify-data` sobre el repo local (lectura completa de todos los chunks).                                |
| **Mensual día 1 05:00**                 | `borgmatic.timer` (rama "monthly")               | `borg check --verify-data` sobre el repo offsite + restauración de prueba (drill, ver más abajo).                     |
| **Trimestral**                          | tarea manual del operador                        | Drill completo: restaurar Vaultwarden + Nextcloud BD + un servicio aleatorio en una Pi de prueba o en `/tmp/restore/`. |
| **Anual**                               | tarea manual del operador                        | Re-cifrado del repo (rotación de _passphrase_ con `borg key change-passphrase`); revisión del proveedor offsite.       |

> **Por qué 03:30 y no 02:00**: a las 02:00 / 03:00 cambia la hora oficial dos veces al año en Europa (último domingo de marzo y de octubre). Disparar a las 03:30 evita la "hora fantasma" del cambio de horario, que en `systemd` con `Persistent=true` puede producir un disparo doble o ninguno según el modo. 03:30 nunca cae en el salto.

### Retención (estilo Grandfather-Father-Son)

Política base, aplicada **idéntica** al repo local y al offsite:

```yaml
keep_within: 24H        # cualquier archive creado en las últimas 24 h se conserva
keep_hourly: 0          # no hay backup horario
keep_daily: 14          # 2 semanas de daily
keep_weekly: 8          # ~2 meses de weekly
keep_monthly: 12        # 1 año de monthly
keep_yearly: 3          # 3 años de yearly
```

Lo que sobrevive en estado estable:

- Los últimos 14 daily.
- Los últimos 8 weekly (que solapan con los daily; Borg cuenta cada archive una sola vez en el _set_ deduplicado, así que el solape no cuesta espacio).
- Los últimos 12 monthly.
- Los últimos 3 yearly.

Total ≈ **37 archives** distintos, pero el espacio real ocupado depende de la deduplicación: para datos típicos de homelab (BD pequeñas que cambian poco, configuraciones casi estáticas, alguna foto/PDF nuevo al día), un repo en estado estable suele moverse en el **rango 1.5 × – 3 ×** del tamaño del último snapshot, no 37 ×.

> **Por qué `keep_yearly: 3`**: evita que el repo crezca indefinidamente y que un archive de hace cinco años, contaminado por algún error que pasó desapercibido, sobreviva como "fantasma" de retención eterna. Tres años es suficiente para resolver los casos típicos ("borré una factura del año pasado y no me di cuenta hasta hoy") sin convertir el backup en un archivo histórico.

> **Por qué `keep_hourly: 0`**: en este homelab no hay datos con _churn_ horario crítico. Vaultwarden y Nextcloud cambian cada minuto pero el coste de perder hasta 24 h de cambios es operativamente aceptable (los clientes Bitwarden / Nextcloud Desktop sincronizan localmente y reaplican). Activar `keep_hourly: 24` añade ruido y carga al disco a cambio de un beneficio marginal. Si en el futuro algún servicio justifica un RPO < 24 h, se documentará en su doc concreto y se añadirá una segunda configuración Borgmatic con cadencia distinta — **no** se inflará la global.

---

## Cifrado y gestión de claves

### Algoritmo y modo de Borg

Todos los repos (local y offsite) se inicializan con cifrado **`repokey-blake2`**:

| Atributo                              | Valor / política                                                                       |
|---------------------------------------|----------------------------------------------------------------------------------------|
| Modo de cifrado                       | `repokey-blake2` (clave AES-256-CTR derivada vía PBKDF2; HMAC con BLAKE2b)             |
| Dónde vive la clave de cifrado        | **Dentro del repo** (cifrada con la passphrase). No depende de la Pi de origen.        |
| Passphrase                            | ≥ 30 caracteres, aleatoria, generada con `pwgen -s 30 1`.                              |
| Variable                              | `BORG_PASSPHRASE` exportada en el `borgmatic.yaml` vía un fichero `0600 root:root`.    |
| Algoritmo de compresión               | `auto,zstd,3` (Borg detecta ficheros incompresibles y los salta).                      |

> **Por qué `repokey` y no `keyfile`**: con `keyfile`, la clave vive en `~/.config/borg/keys/<repo>` **fuera** del repo. Si se pierde la microSD entera (y ese fichero), el repo se vuelve un ladrillo cifrado aunque se conozca la passphrase. Con `repokey`, la clave viaja **dentro** del repo, y basta con la passphrase para abrirlo desde cualquier máquina. El _trade-off_ — un atacante con acceso al repo necesita la passphrase pero no necesita la Pi — es aceptable porque la passphrase es lo bastante larga.

### Custodia de la passphrase

La passphrase del repo **no puede vivir solamente en la propia Pi**: si la Pi se carboniza, restaurar exige conocerla. Política de custodia:

1. **Copia primaria — Vaultwarden** (`docs/11-productividad/01-vaultwarden.md`). Una vez Vaultwarden esté operativo, la passphrase entra en una nota "Homelab — Borg passphrase". Esto cubre el día a día.
2. **Copia secundaria — gestor de contraseñas externo del operador** (Bitwarden cloud, 1Password, KeePassXC en una segunda máquina). Cubre el caso "Vaultwarden está caído precisamente porque hay que restaurarlo".
3. **Copia terciaria — papel impreso** (estilo "paper backup") en una caja fuerte o sobre cerrado. Cubre el caso "todos los gestores digitales se han perdido a la vez".

La passphrase **solo** se rota anualmente (o tras una sospecha de compromiso). La rotación se ejecuta con `borg key change-passphrase <repo>`, **no** se reinicializa el repo. La nueva passphrase se actualiza en los tres lugares de custodia el mismo día.

> **Aviso**: nunca commit-ear la passphrase a `~/homelab/` aunque parezca tentador para tener un único Compose autocontenido. La Política Recurrente de Secretos del homelab (`docs/01-sistema/04-estructura-directorios.md` y `docs/02-docker/02-estructura-compose.md`) prohíbe commitear secretos: viven en `.env` con `0600` y se ignoran por `.gitignore`.

### Cifrado del transporte offsite

- **SSH** (rsync.net, Hetzner Storage Box, segunda Pi): la conexión va sobre SSH, autenticación con clave Ed25519 dedicada a backups (sin _passphrase_ en la clave, porque corre desde un timer no interactivo, pero permisos `0600` y dueño `root:root`). El _known_hosts_ pinea la huella del servidor para evitar MITM tras un cambio de IP.
- **HTTPS** (B2, S3, R2): credenciales con _scope_ mínimo (acceso a un único bucket, _read+write+list_, sin `delete bucket`). Variables `B2_ACCOUNT_ID` / `B2_ACCOUNT_KEY` o `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` en el mismo fichero `0600` que `BORG_PASSPHRASE`.

---

## Verificación de integridad y restauración

Un backup que no se ha probado **no es** un backup. Tres niveles de verificación:

### Nivel 1 — Comprobaciones automatizadas en cada corrida (gratis)

Las ejecuta `borgmatic` después de cada `create`:

- `borg check --repository-only`: revisa la integridad estructural del repo (no lee chunks). Rápido (segundos a minutos).
- _Hash_ HMAC implícito: cada chunk se valida al ser leído.
- _Exit code_ del propio `create`: cualquier error fatal (NotEnoughSpace, IO error, hook que falla) deja `borgmatic` con `rc != 0` y dispara la notificación.

### Nivel 2 — Verificación profunda periódica (lectura completa)

- **Semanal sobre el repo local**: `borg check --verify-data` lee y verifica el HMAC de **todos** los chunks. Detecta _bit rot_ silencioso. Tarda más (minutos a una hora según tamaño).
- **Mensual sobre el repo offsite**: misma comprobación, pero limitada a una vez al mes para no agotar la cuota de transferencia del proveedor (B2 cobra por GB descargado; rsync.net no).

### Nivel 3 — Restauraciones de prueba (drills)

Ningún chequeo automático sustituye a una restauración real. Calendario:

| Cadencia    | Drill                                                                                                                                                                       | Cómo                                                                                                                                       |
|-------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------|
| **Mensual** | Restaurar la BD de Vaultwarden y verificar que `bw login` funciona contra una instancia de prueba.                                                                          | `borg extract --target /tmp/restore <repo>::<archive> mnt/hd2t/services/vaultwarden`, levantar un Vaultwarden con ese volumen en otro puerto. |
| **Mensual** | Restaurar el dump de Nextcloud y montarlo en un MariaDB temporal; comprobar que las tablas `oc_users` y `oc_share` están íntegras.                                          | mismo patrón: extraer el `.sql.gz`, importarlo, `SELECT COUNT(*) FROM oc_users`.                                                          |
| **Trimestral** | Restaurar **Home Assistant** completo en una Pi auxiliar (o en un container temporal en la misma Pi), y verificar que el _frontend_ carga las automatizaciones.            | replicar la config y el `secrets.yaml`; arrancar `homeassistant/home-assistant` apuntando al volumen restaurado.                          |
| **Trimestral** | Restaurar **Paperless-ngx** y abrir un documento aleatorio; comprobar que el OCR sigue siendo legible.                                                                      | dump Postgres + extracción de `media/documents/`.                                                                                          |
| **Anual**    | **Disaster recovery completo**: con la Pi apagada y `hd2t` desconectado, restaurar el homelab en una Pi de repuesto desde sólo el repo offsite y la passphrase.            | siguiendo `docs/13-operaciones/02-disaster-recovery.md`.                                                                                   |

Cada drill se cierra con un **registro escrito** en `~/homelab/docs/journal/YYYY-MM-DD-drill-<servicio>.md` (o donde el operador prefiera) que anote: archive restaurado, tiempo total, problemas encontrados y fix aplicado. Sin registro no hay aprendizaje; las dos primeras restauraciones siempre revelan algo (un campo del `.env` no respaldado, un servicio que no documentó su _hook_ pre-backup, un permiso que no se restaura).

---

## Notificaciones y monitorización

El backup es **silencioso por diseño**: `borgmatic` no produce salida a menos que algo falle. Por tanto los avisos los gestiona el subsistema de notificación del homelab.

### Canal primario — `ntfy` self-hosted o externo

Borgmatic soporta hooks `on_error`, `before_backup`, `after_backup`. La política mínima:

| Hook            | Mensaje                                                                                       |
|-----------------|-----------------------------------------------------------------------------------------------|
| `on_error`      | Notificación con prioridad **alta** y _tag_ "warning" — incluye el repo afectado y el _stage_. |
| `after_backup`  | Notificación con prioridad **baja** y _tag_ "white_check_mark" — incluye archive name y duración. |

> **Por qué notificar también el éxito**: Uptime Kuma (`docs/05-monitorizacion/05-uptime-kuma.md`) puede vigilar la **ausencia** de la notificación de éxito. Configurar un monitor _push_ con TTL de 26 h: si no llega la notificación diaria de Borgmatic en 26 h, Uptime Kuma lo marca como caído. Esto detecta el modo "timer no se ha disparado en absoluto", que un hook `on_error` no puede detectar.

### Canal secundario — email

Para `keep_yearly` y eventos críticos (drill mensual fallido, repo `--verify-data` con errores), un email con detalles. El propio Borgmatic tiene hook `mail_to`, pero queda relegado al canal "lo leo cuando me siento": el _push_ a ntfy es la fuente primaria.

### Métricas a Prometheus

Borgmatic puede exportar métricas a un _push gateway_ de Prometheus o escribir un _textfile_ que `node_exporter` recoja (`docs/05-monitorizacion/03-node-exporter.md`). Métricas mínimas:

- `borg_last_run_timestamp_seconds` (gauge): epoch de la última corrida exitosa.
- `borg_last_run_status` (gauge): 0 = OK, 1 = error.
- `borg_repo_size_bytes{repo="local|offsite"}`.
- `borg_archive_count{repo="local|offsite"}`.

Con esas cuatro, un _alerting rule_ en Prometheus dispara si `time() - borg_last_run_timestamp_seconds > 26h` o si `borg_last_run_status != 0`.

---

## Reparto de responsabilidades

A modo de mapa rápido, qué doc se encarga de qué pieza del backup:

| Pieza                                                          | Doc responsable                                              |
|----------------------------------------------------------------|--------------------------------------------------------------|
| Estrategia, política, retención, drills (este doc)             | `docs/07-backups/01-estrategia-backup.md`                    |
| Despliegue de Borgmatic, `borgmatic.yaml`, timers, hooks       | `docs/07-backups/02-borgmatic.md`                            |
| Procedimiento por servicio: dump SQL, _quiesce_, restauración  | `docs/07-backups/03-backup-docker-volumes.md`                |
| Sección **Backup** de cada servicio (qué dumpea, dónde)        | `docs/<fase>/<servicio>.md` (ej. `01-nextcloud.md` → su Backup) |
| Replicación a MinIO (S3 mirror del repo local)                 | `docs/06-almacenamiento/04-minio.md`                         |
| Notificaciones de backup vía ntfy / Telegram / email           | doc del propio canal de notificación (a definir, fase 5)     |
| Monitorización y alertas Prometheus para Borg                  | `docs/05-monitorizacion/01-prometheus.md`                    |
| Disaster recovery completo (restaurar la Pi entera de cero)    | `docs/13-operaciones/02-disaster-recovery.md`                |

---

## Decisiones de diseño

### Por qué Borg/Borgmatic (y no Restic, Duplicati, rsnapshot, rsync)

| Candidato        | Veredicto                                                                                                                                                                                                                                                                              |
|------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **BorgBackup + Borgmatic** ✅ | Deduplicación por chunks de tamaño variable (rolling hash) extremadamente eficaz para configs y BD; cifrado autenticado de fábrica; _append-only mode_ posible para resistir ransomware; herramienta madura desde 2015 y con _release_ frecuente. Borgmatic añade encima un YAML único, hooks pre/post, retención GFS, integraciones de notificación. **Elección del homelab**.                                                                                                                                                                                                                       |
| **Restic**       | También deduplica con rolling hash, también cifra. Diferencias clave: backend nativo S3/B2 (atractivo si el offsite es S3), pero **rendimiento sensiblemente inferior a Borg en datasets grandes con muchos ficheros pequeños** (caso típico del homelab: `~/homelab/`, configs, BD), y _prune_ históricamente costoso (mejorado con `restic forget --keep-* --prune`, pero sigue siendo más lento). Sin Borgmatic-equivalente que centralice todo en YAML; hay `restic-runner`, `autorestic`, pero menos pulidos. Quedaría como opción si el offsite fuera **exclusivamente** S3 sin SSH disponible — no es el caso aquí. |
| **Duplicati**    | _Frontend_ web bonito, pero el _backend_ (.NET) ha tenido históricamente bugs en restauración silenciosos (issues conocidos en grandes datasets). No es la apuesta segura para datos irrecuperables.                                                                                  |
| **rsnapshot**    | Snapshots por hardlinks. Sin cifrado nativo; sin deduplicación a nivel de chunk; no comprime. Funciona, pero es de los 2000.                                                                                                                                                          |
| **rsync directo**| Copia incremental sin deduplicación, sin cifrado, sin compresión, sin retención automática. Es la herramienta de bajo nivel; útil para mover bytes pero no es una solución de backup en el sentido de este doc.                                                                       |
| **Snapshots de filesystem (btrfs/zfs)** | Espectaculares en NAS dedicados, pero `hd2t` es ext4 (decisión en `docs/00-hardware/03-preparacion-discos.md`: ext4 es el filesystem de menor riesgo en Pi USB-attached). Migrar a btrfs/zfs sólo para snapshots no compensa.                                                                       |

### Destino offsite

Sin compromiso firme aquí — la elección concreta del proveedor offsite se documenta en `docs/07-backups/02-borgmatic.md` cuando se vaya a desplegar. Sí se fija el **shortlist** de opciones aceptables:

| Proveedor                          | Protocolo            | Ventajas                                                                                                | Inconvenientes                                                                       |
|------------------------------------|----------------------|---------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------|
| **rsync.net (Borg account)**       | SSH + `borg serve`   | Soporte nativo de Borg en el lado servidor; _append-only_ trivial; sin egreso de pago.                  | Más caro por TB que B2 (≈ 1.5 €/GB/año vs 0.5 €/GB/año).                              |
| **Hetzner Storage Box**            | SSH/SFTP             | Muy barato (≈ 0.30 €/GB/año en planes ≥ 1 TB); UE; soporta `borg` por SSH.                              | Sin Borg-mode nativo (Borg corre client-side; el servidor sólo expone filesystem).    |
| **Backblaze B2 (vía rclone+rclone serve sftp o vía MinIO mirror)** | HTTPS S3 / SFTP front | Más barato del shortlist (0.05 €/GB/mes ≈ 0.6 €/GB/año); egreso gratuito a través de Cloudflare Bandwidth Alliance. | Borg no habla S3 directamente; necesita capa intermedia (rclone serve, MinIO).       |
| **Segunda Pi en otro hogar**       | SSH (vía Tailscale)  | Coste 0 € recurrentes; ancho de banda ilimitado; sin terceros.                                          | Requiere relación de confianza, ubicación física distinta, y un dispositivo que mantener. |

La regla operativa: el homelab **necesita** una copia offsite real desde el día en que despliega Borgmatic. Si el operador aún no ha decidido entre las opciones, la opción de partida por defecto es **rsync.net Borg account** durante 1 mes (el _free trial_ + los primeros 50 GB son baratísimos), tiempo suficiente para evaluar coste real y migrar después.

### Por qué dump SQL "lógico" en vez de copiar el datadir

Los volúmenes de Postgres y MariaDB **no se respaldan en caliente** copiando ficheros: una copia "fría" (el contenedor parado) dejaría los servicios caídos varios minutos al día, y una copia "caliente" sin _quiesce_ produce repos corrompidos (el `pg_xlog` no es coherente con los _data files_). La estrategia uniforme es:

1. _hook_ pre-backup de Borgmatic ejecuta `pg_dump` / `mariadb-dump` contra la BD viva, redirige a `/mnt/hd2t/backups/dumps/<servicio>-$(date +%F).sql.gz`.
2. Borg incluye en el snapshot el árbol `dumps/` y los volúmenes que **no** son BD (uploads, configuración).
3. _hook_ post-backup borra los dumps mayores a N días para no acumular.

Detalles por servicio (qué comando exacto, con qué privilegios) → `docs/07-backups/03-backup-docker-volumes.md`.

---

## Verificación final del marco estratégico

Antes de marcar como completado este documento y proceder con `docs/07-backups/02-borgmatic.md`, comprobar:

- [ ] La rama `/mnt/hd2t/backups/{borg,dumps,exports}/` existe y es `0700 root:root` (heredado de `docs/01-sistema/04-estructura-directorios.md`).
- [ ] El operador ha elegido (al menos provisionalmente) un destino offsite del shortlist.
- [ ] El operador ha generado mentalmente o sobre papel el plan de **custodia de la passphrase** (Vaultwarden + gestor externo + papel) y entiende que sin la passphrase no se restaura nada.
- [ ] La clasificación A/B/C/D/E es comprensible y refleja la sensibilidad real del operador (ej. si la biblioteca de Stash es categoría D opción "no respaldar", se anota en `docs/09-multimedia/05-stash.md` antes de poblar el disco).
- [ ] El calendario propuesto (daily 03:30, weekly domingo, monthly día 1, drills trimestrales) cabe en el ritmo de mantenimiento que el operador piensa sostener (ver `docs/13-operaciones/01-mantenimiento-periodico.md`).
- [ ] La regla 3-2-1 aplicada al hardware concreto está entendida: **respaldar dentro de `hd2t` no es offsite**, la copia offsite es la que cuenta.
- [ ] Cualquier doc de servicio ya escrito (Nextcloud, Vaultwarden, etc.) tiene una sección **Backup** coherente con la categoría que le corresponde aquí. Si no, se ajusta antes de seguir.

---

## Troubleshooting (a nivel estratégico)

### "He desplegado Borgmatic pero no sé si está respaldando lo correcto"

Antes de tocar `borgmatic.yaml`, releer la sección **Inventario consolidado de fuentes** y comparar línea por línea con el `source_directories:` real. Cualquier servicio en `/mnt/hd2t/services/` que **no** aparezca ni en la lista de fuentes ni en `exclude_patterns` es un agujero: o entra a respaldar o se documenta como categoría C/E.

### "El repo local crece sin parar"

- Comprobar que la retención (`keep_*`) está configurada en `borgmatic.yaml` y que `borg prune` se ejecuta tras cada `create` (Borgmatic lo hace por defecto). Sin `prune` los archives se acumulan eternamente.
- Verificar que el `exclude_patterns` cubre `cache`, `transcodes`, `downloads`, `prometheus/data` (si no se quiere) y `services/shared`.
- Inspeccionar qué archive ha disparado el crecimiento: `borg list <repo>` y `borg info <repo>::<archive>`. A veces es un único servicio nuevo que no se documentó en su sección **Backup** y entró por inercia.

### "El offsite va lentísimo y consume el ancho de banda doméstico"

- Limitar el ancho con `upload_rate_limit: 1024` (KB/s) en `borgmatic.yaml` o en la SSH (`-o RateLimit`), o programar el offsite en una rama distinta del timer (ej. 03:30 local, 04:30 offsite con `--remote-ratelimit`).
- Confirmar que la deduplicación funciona: la primera corrida sube todo el dataset (eso es esperado, una sola vez), las siguientes sólo el delta. Si el delta diario es > 1 GB de forma sostenida, hay un servicio escribiendo mucho más de lo que parece — investigar con `borg diff <archive_ayer> <archive_hoy>`.

### "He perdido la passphrase"

- Si está en Vaultwarden y Vaultwarden está vivo: recuperarla y rotar.
- Si está en el gestor externo (Bitwarden cloud, KeePassXC en otra máquina): recuperarla y rotar.
- Si está sólo en papel: ir a buscarlo.
- Si **ninguna** de las tres copias está disponible: el repo es irrecuperable. No hay puerta trasera; el cifrado AES-256 con HMAC-BLAKE2 no se rompe. Aceptar la pérdida y documentar el aprendizaje en el journal del homelab.

### "He restaurado un servicio y no funciona"

- Comprobar que el `.env` se restauró junto al `docker-compose.yml`. Es el error más común: el `.env` está fuera del repositorio git y, si no está en el inventario de `source_directories`, se pierde.
- Comprobar permisos del volumen restaurado. Borg conserva UID/GID, pero el `extract` debe ejecutarse como root para preservarlos (Borgmatic lo hace; un `borg extract` manual desde otro usuario los aplasta a su UID).
- Comprobar que la BD se restauró desde el dump SQL, no desde el datadir crudo (ver **Decisiones de diseño → Por qué dump SQL lógico**).

### "El repo `--verify-data` semanal ha fallado"

Es exactamente el caso que esta verificación está diseñada para detectar. Pasos:

1. **No purgar nada todavía** (no `borg prune`, no `borg delete`).
2. Ejecutar `borg check --verify-data --repair` (con cuidado: `--repair` puede eliminar chunks corruptos).
3. Si el repo local está dañado pero el offsite no, marcar el local como "perdido", reinicializarlo y rellenarlo desde cero en la siguiente corrida (los datos vivos siguen ahí; lo perdido es el histórico, recuperable parcialmente del offsite).
4. Si el offsite también está dañado: caso grave, requiere restauración inmediata de los datos vivos al menos (quizá desde drill reciente) y reconstrucción del régimen de backups desde cero.
5. Documentar el incidente en el journal: causa probable (bit rot del HDD, error del proveedor offsite, bug de Borg), acciones tomadas, cambios de política derivados.

---

## Referencias

- BorgBackup — _security model_ y modos de cifrado: <https://borgbackup.readthedocs.io/en/stable/internals/security.html>
- BorgBackup — `borg check`, `--verify-data` y _repair_: <https://borgbackup.readthedocs.io/en/stable/usage/check.html>
- Borgmatic — configuración YAML, hooks y retención: <https://torsion.org/borgmatic/>
- Borgmatic — integraciones de monitorización: <https://torsion.org/borgmatic/docs/how-to/monitor-your-backups/>
- US-CERT — la regla 3-2-1 (origen): <https://www.cisa.gov/news-events/news/data-backup-options>
- rsync.net — Borg/Attic accounts: <https://www.rsync.net/products/borg.html>
- Hetzner Storage Box — uso con SSH/SFTP: <https://docs.hetzner.com/robot/storage-box/>
- Backblaze B2 — pricing y _egress_ vía Cloudflare: <https://www.backblaze.com/cloud-storage/pricing>
- ntfy — _push notifications_ self-hosted: <https://ntfy.sh/>
- Postgres — `pg_dump` y backups lógicos: <https://www.postgresql.org/docs/current/backup-dump.html>
- MariaDB — `mariadb-dump`: <https://mariadb.com/kb/en/mariadb-dump/>
