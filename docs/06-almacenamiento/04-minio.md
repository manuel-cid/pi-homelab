# MinIO

## Descripción

Cerrados `01-nextcloud.md`, `02-samba.md` y `03-syncthing.md`, el homelab cubre los tres modos clásicos de manipular ficheros:

- **Nube personal con UI propia y clientes** (Nextcloud, vía WebDAV).
- **Disco de red para abrir ficheros remotos** (Samba, vía SMB).
- **Sincronización P2P entre dispositivos del operador** (Syncthing, vía BEP).

Todos comparten un denominador: hablan **protocolos de fichero** (WebDAV, SMB, BEP) y exponen un *árbol de directorios* a humanos. Hay una cuarta forma de almacenar datos que **ninguno** de los anteriores cubre y que el siguiente bloque de servicios necesita: **almacenamiento de objetos S3-compatible**.

Este documento despliega **MinIO** como servicio S3 del homelab. Su rol concreto:

1. **Destino S3 para tareas de backup que no escriben a filesystem**: tools como `restic`, `rclone`, `velero`, `litestream`, `pgbackrest` y los hooks de aplicaciones modernas (Forgejo `dump`, Vaultwarden export, Grafana snapshots) hablan S3 nativo. La Fase 7 (`07-backups/02-borgmatic.md`) seguirá usando **Borg sobre filesystem en `/mnt/hd2t/backups/`** como destino primario; MinIO complementa ese flujo siendo **destino S3 de aquellas aplicaciones cuyo backup nativo es a S3 y forzarlas a un dump en filesystem es regresión**.
2. **Backend de almacenamiento de objetos para servicios futuros**: Nextcloud puede mover su almacén de ficheros a S3 (`OBJECTSTORE_S3_*`, decisión documentada como *no aplicada hoy* en `01-nextcloud.md`); Stash puede mantener `previews`/`generated` en un bucket; Loki guarda *chunks* en S3 si en el futuro se cierra Fase 5b. **No se conecta nada todavía**; MinIO queda **listo y vacío**.
3. **Área de *staging* para offsite replication**: la estrategia 3-2-1 documentada en `07-backups/01-estrategia-backup.md` necesita una copia *offsite*. La pieza recomendada por defecto es `rclone` apuntando a un proveedor S3-compatible barato (Backblaze B2, Cloudflare R2, Wasabi). MinIO en la Pi sirve como **buffer local**: las apps escriben a MinIO, un job nocturno (`mc mirror` o `rclone sync`) replica los buckets contra el proveedor offsite. Si el proveedor cae o se rota, la integridad local se mantiene.
4. **Mock S3 para desarrollo**: aplicaciones que el operador prueba localmente y necesitan un endpoint S3 real (ETags, multipart, ACLs) sin firmar contrato con AWS.

Estará compuesto por **un único contenedor**:

- `minio` — imagen oficial `quay.io/minio/minio` con un tag de release fechado (no `latest` ni `edge`). MinIO no usa semver: cada release es `RELEASE.YYYY-MM-DDTHH-MM-SSZ`.

Lo que este documento **no** decide:

- **Despliegue distribuido** (`MNMD` o `SNMD` con `erasure coding`). MinIO en producción se despliega en clusters de 4+ nodos o 4+ drives para garantizar redundancia con códigos de borrado. Aquí hay **un nodo** y **un drive** (`hd2t`); MinIO arranca en *single-node single-drive* (también llamado *FS mode* en versiones antiguas, *Standalone* en las nuevas). Pierde redundancia interna a cambio de simplicidad. La redundancia "de los datos del homelab" la dan: Borg sobre los buckets críticos + offsite replication.
- **MinIO como destino primario de Borgmatic**. Borg habla a un *repositorio* (filesystem local, SSH remoto, o vía `rclone serve restic`); no habla S3 directamente. Forzar Borg→MinIO requeriría un puente extra (`rclone mount` con `vfs-cache`) que añade fragilidad sin valor: si el destino es **otro disco de la misma Pi**, escribir directo al filesystem es estrictamente mejor. Por eso Borgmatic sigue en `/mnt/hd2t/backups/` y MinIO **no** es su destino. Reabrible si el día de mañana se monta un segundo nodo MinIO en otra máquina y conviene unificar el plano de backup ahí.
- **Replicación bucket-a-bucket entre dos MinIO** (`MinIO Site Replication`). Sin segundo nodo.
- **KES (Key Encryption Service) y Server-Side Encryption con claves externas**. SSE-S3 con clave gestionada por el propio MinIO se documenta como *opción habilitable*, pero KES/Vault es sobreingeniería para el alcance.
- **MinIO Operator** (Kubernetes). Aquí se usa Docker Compose puro.
- **Identity Provider externo** (LDAP, OIDC contra Authelia). La Console de MinIO se protege con Authelia 2FA delante (`forward_auth`), pero la auth nativa de MinIO sigue siendo `root user` + Access Keys generadas por el operador. Reabrible cuando Authelia exponga OIDC.
- **MinIO Console reemplazada por la SubNet UI / Operator UI**. Se usa la Console embebida estándar.
- **Versionado obligatorio en TODOS los buckets**. Algunos buckets (logs efímeros, scratch) no se versionan para no inflar el espacio. La política se decide bucket a bucket.
- **Cuotas (`mc admin bucket quota`) y políticas IAM granulares**. Se documenta el modelo y se aplican defaults conservadores; el ajuste fino se reabre cuando aparezcan consumidores reales con tasas de crecimiento medibles.

Cuando este documento se haya aplicado, el operador puede:

- Abrir `https://minio.${DOMAIN_LAN}/` desde la LAN (con la CA interna instalada), pasar Authelia 2FA, autenticarse en la Console con el `MINIO_ROOT_USER` y ver el panel de buckets, métricas, IAM.
- Hablar S3 contra `https://s3.${DOMAIN_LAN}/` desde clientes (`mc`, `aws s3`, `restic`, `rclone`, `s3cmd`) con Access Keys creadas para cada consumidor.
- Crear los primeros buckets del homelab (`app-snapshots`, `mc-mirror-staging`) con versionado y *lifecycle policies* aplicadas.
- Verificar que el endpoint S3 emite certificados de la CA interna y que las llamadas pasan por Caddy en HTTPS.
- Disponer de un buffer S3 al que apuntarán futuros servicios (Nextcloud `OBJECTSTORE_S3`, Forgejo `dump`, Vaultwarden export, Stash previews) sin tocar nada hoy.

> **Recordatorio de alcance**: MinIO escucha en `:9000` (S3 API) y `:9001` (Console) **solo dentro de la red Docker `homelab`**. Ningún `ports:` se publica al host. El acceso humano (Console) sale **únicamente** vía Caddy + Authelia 2FA. El acceso de clientes S3 sale vía Caddy con TLS de la CA interna y autenticación por Access Keys (sin Authelia, mismo principio que WebDAV en Nextcloud: los clientes S3 no siguen redirects HTML). Acceso remoto, vía Tailscale (`https://s3.${DOMAIN_TS}/` y `https://minio.${DOMAIN_TS}/`). Sin DDNS, sin Let's Encrypt, sin redirección de puertos en el router.

---

## Requisitos Previos

- **Fase 1** completa: usuario `homelab` con `uid=1000, gid=1000`; estructura de directorios creada por `00-create-homelab-tree.sh` (incluye `/mnt/hd2t/apps/minio` y `/mnt/hd2t/apps/minio/data`).
- **Fase 2** completa: Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID=1000`, `PGID=1000`, `DOMAIN_LAN=lan`, `DOMAIN_TS` opcional.
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre automáticamente `minio.${DOMAIN_LAN}` y `s3.${DOMAIN_LAN}` sin tocar Pi-hole).
  - Caddy desplegado y los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)`, `(authelia_two_factor)` en `Caddyfile`.
- **Fase 4** completa: Authelia operativa con `default_policy: deny`. Se añadirán dos reglas en `access_control.rules`:
  - `policy: two_factor` para `minio.${DOMAIN_LAN}` (la Console).
  - `policy: bypass` para `s3.${DOMAIN_LAN}` (el endpoint S3 — los clientes no siguen redirects HTML, exactamente igual que `cloud.${DOMAIN_LAN}` en `01-nextcloud.md`).
- Disco `hd2t` montado en `/mnt/hd2t` con al menos **20 GiB** libres reservados inicialmente para MinIO. Crece según los buckets reales; el *cap* operativo lo marca el espacio total de `hd2t` (2 TB) menos lo reservado para Nextcloud, multimedia y backups.
- Operador con la **CA interna instalada** en su navegador y en cualquier máquina que vaya a hablar S3 contra `s3.${DOMAIN_LAN}` (o, alternativamente, los clientes deberán pasar `--insecure` / `--no-verify-ssl`, lo cual se descarta como práctica).

Comprobaciones rápidas:

```bash
# Red Docker compartida
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Caddy y Authelia están healthy
docker ps --filter name=caddy --filter name=authelia --format '{{.Names}} {{.Status}}'

# Los dos hostnames resuelven al IP de la Pi (gracias al comodín de Pi-hole)
dig +short minio.lan s3.lan @192.168.1.2
# 192.168.1.10
# 192.168.1.10

# Espacio en hd2t
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'

# El árbol /mnt/hd2t/apps/minio existe (creado en Fase 1)
ls -ld /mnt/hd2t/apps/minio /mnt/hd2t/apps/minio/data
# drwxr-x--- ... homelab homelab .../minio
# drwxr-x--- ... homelab homelab .../minio/data
```

---

## Decisión: imagen y tag

| Imagen | Pros | Contras |
|---|---|---|
| `quay.io/minio/minio` | Imagen **canónica** publicada por el equipo de MinIO. ARM64 first-class. Tags de release fechados (`RELEASE.2025-04-22T17-06-50Z`). | Quay.io es menos familiar que Docker Hub. |
| `minio/minio` (Docker Hub) | Espejo del anterior, idéntico contenido, mismos tags. | Docker Hub aplica rate-limits a `pull` no autenticado. Quay no. |
| `bitnami/minio` | Empaquetada por Bitnami. | Diverge en variables de entorno y en el ENTRYPOINT respecto al upstream. La documentación oficial **no** aplica directa. |
| `minio/minio:edge` o `:latest` | Siempre la última versión. | Rompe la regla del homelab ("nunca `latest`"). MinIO publica varias releases al mes, algunas con cambios en la API administrativa. |

| Decisión | Justificación |
|---|---|
| **`quay.io/minio/minio:RELEASE.2025-04-22T17-06-50Z`** (o el último estable al desplegar) | Imagen canónica del proyecto, sin rate-limit en pull, ARM64 nativo, tag fechado para reproducibilidad. El operador rota el pin a un release más reciente cuando lee changelog y decide. |
| **No `latest` ni `edge`** | MinIO publica con mucha frecuencia y los upgrades a veces cambian rutas administrativas (`mc admin`) o el formato de configuración. La política aquí es: el operador decide cuándo subir, lo prueba contra `mc admin info`, los buckets existentes y los Access Keys, y solo entonces actualiza este documento. **Excluido de Watchtower** (`com.centurylinklabs.watchtower.enable: "false"`). |

> **Sobre el cliente `mc`**: la imagen `minio/mc` (también en quay) trae el binario de cliente. Aquí **no se despliega como contenedor permanente**; cuando se necesita, se ejecuta como `docker run --rm --network homelab -v ~/.mc:/root/.mc minio/mc <comando>`. Se documenta en "Configuración" cómo aliasear con `mc alias set` para no escribir credenciales cada vez.

---

## Decisión: modo de despliegue (single-node single-drive vs erasure-coded)

MinIO soporta tres topologías:

| Topología | Cómo se invoca | Pros | Contras | Veredicto |
|---|---|---|---|---|
| **Single-Node Single-Drive (SNSD / Standalone)** | `minio server /data` | Cero overhead. Los objetos se escriben tal cual al filesystem subyacente (en realidad MinIO los almacena en el formato `xl.meta` interno desde 2022, pero es un único árbol). | **Sin redundancia** a nivel MinIO: si `hd2t` se corrompe, los buckets se pierden con él. Hay funciones (`Site Replication`, *bucket replication*) que **no se pueden activar**. | **Aceptado**. La Pi tiene un solo `hd2t`; cualquier topología distribuida sería mentirse. |
| Single-Node Multi-Drive (SNMD) | `minio server /data1 /data2 /data3 /data4` (mínimo 2, recomendado ≥4 para EC). | Erasure coding sobre varios drives del mismo host. | Aquí no hay 4 drives en un solo host. | Descartado. |
| Multi-Node Multi-Drive (MNMD) | `minio server http://node{1...N}/data{1...M}` | Producción "real". | Sobreingeniería absoluta. | Descartado. |

Consecuencias de SNSD para el modelo de fiabilidad:

- **MinIO no protege contra bit rot ni corrupción de `hd2t`**.
- La **redundancia se desplaza a Borg + offsite**: los buckets críticos del homelab se respaldan vía Borg desde `/mnt/hd2t/apps/minio/data` en frío (sección "Backup"), y opcionalmente se replican a un proveedor offsite (B2/R2) con `mc mirror` desde fuera del contenedor. Es el mismo modelo que Nextcloud (cuyos datos en `data/` también se respaldan vía Borg, no vía replicación nativa).

> **Sobre `MINIO_VOLUMES`**: en SNSD se pasa una sola ruta. La imagen oficial expone `/data` como volumen por defecto y arranca con `minio server /data --console-address :9001` si no se indica otra cosa. Aquí se mantiene exactamente eso.

---

## Decisión: API S3 vs Console (puertos y dominios)

MinIO escucha por defecto en dos puertos distintos:

| Puerto | Para qué | Quién lo consume |
|---|---|---|
| `9000/tcp` | **API S3** (PUT/GET/DELETE de objetos, multipart, etc.). | Clientes S3: `mc`, `aws s3`, `restic`, `rclone`, `s3cmd`, SDKs (Python `boto3`, Go `aws-sdk-go`). |
| `9001/tcp` | **Console** (UI web de administración: buckets, IAM, métricas). | Navegadores humanos. |

Esto separa elegantemente dos planos:

- **Plano de datos S3** (`:9000`): autenticación con **AWS SigV4** (Access Key + Secret Key), basada en *headers* HTTP firmados. Los clientes **no** siguen redirects HTML — exactamente como WebDAV en Nextcloud. Si Authelia interceptara este endpoint con `forward_auth`, los clientes recibirían `302 → auth.lan/?rd=...` y fallarían.
- **Plano de control / Console** (`:9001`): autenticación con `MINIO_ROOT_USER` o usuarios IAM creados desde la Console. Acceso humano vía navegador; aquí Authelia **sí** funciona y se aplica.

| Mecanismo | Pros | Contras | Veredicto |
|---|---|---|---|
| Un único bloque Caddy (`minio.lan`) que proxea ambos puertos por *path* | Simplifica DNS/registros. | MinIO **rechaza** virtual-hosted-style requests sin un *server URL* coherente. Mezclar `/api/...` y `/`-de-la-Console termina en cabeceras `Host`/`Origin`/`Referer` que la Console valida. | Descartado. |
| **Dos bloques Caddy: `s3.lan` → `:9000`, `minio.lan` → `:9001`** | Cada uno con su política Authelia: `bypass` para `s3.lan`, `two_factor` para `minio.lan`. La Console manda al cliente al endpoint S3 vía `MINIO_SERVER_URL`. Las cabeceras `Host` viajan distintas y MinIO no las confunde. | Dos hostnames y dos drop-ins. Coste menor. | **Aceptado**. |
| Publicar `:9000`/`:9001` directamente al host con `ports:` y saltarse Caddy | Cero indirección. | Sin TLS interno (clientes S3 modernos rechazan HTTP plano), sin Authelia para la Console. Rompe el patrón del homelab. | Descartado. |

| Decisión | Justificación |
|---|---|
| **Dos bloques Caddy con dos hostnames** | `s3.${DOMAIN_LAN}` → API S3 con `bypass` en Authelia; `minio.${DOMAIN_LAN}` → Console con `two_factor` en Authelia. |
| **No publicar `ports:`** | MinIO solo expone (`expose: 9000, 9001`) en la red `homelab`. Toda llegada al exterior pasa por Caddy. |
| **`MINIO_SERVER_URL=https://s3.${DOMAIN_LAN}`** | Fija la URL pública del API que la Console anuncia y que las pre-signed URLs incluyen en sus firmas. |
| **`MINIO_BROWSER_REDIRECT_URL=https://minio.${DOMAIN_LAN}`** | Fija la URL pública de la Console; sin esto, los redirects post-login envían al host interno (`http://minio:9001`) y rompen. |

> **Sobre las pre-signed URLs**: MinIO firma URLs con TTL (típicamente 7 días) que dan acceso temporal a un objeto sin Access Keys. Esa firma incluye el hostname del endpoint; si `MINIO_SERVER_URL` no coincide con el hostname público real, las URLs firmadas dan `SignatureDoesNotMatch` al consumirse desde fuera. Por eso fijarlo es **obligatorio**, no cosmético.

---

## Decisión: autenticación (Authelia + bypass S3 + IAM nativo)

| Endpoint | Autenticación | Por qué |
|---|---|---|
| `https://minio.${DOMAIN_LAN}/` (Console) | **Authelia `policy: two_factor`** + login nativo MinIO (`root user` o IAM user). | Doble capa: SSO del homelab fuera, IAM de MinIO dentro. La Console permite crear/borrar buckets, manipular policies, *expose* el endpoint S3 entero. Es el plano de control completo. |
| `https://s3.${DOMAIN_LAN}/` (API S3) | **Authelia `policy: bypass`** + AWS SigV4 (Access Key + Secret Key). | Los clientes S3 firman cada petición con HMAC-SHA256 de las cabeceras + body. Authelia delante rompe a los clientes. La auth la hace MinIO contra su backend IAM interno. |

| Decisión | Justificación |
|---|---|
| **`MINIO_ROOT_USER` y `MINIO_ROOT_PASSWORD` desde `.env`** | Bootstrap inicial. La password se genera con `openssl rand -base64 32`. **No se usa para clientes S3** (esa es la regla operacional): los clientes reciben Access Keys propias. |
| **Una Access Key por consumidor, con policy mínima** | `mc-mirror-offsite`, `restic-vaultwarden`, `nextcloud-objectstore` (futuro), etc. Cada uno con una policy IAM que **solo** permite las acciones necesarias (`s3:PutObject`, `s3:GetObject`, `s3:ListBucket`) sobre **un solo bucket**. |
| **Política IAM `readwrite` global EVITADA** | Es la default que sugiere `mc admin user add`; en este homelab se sustituye sistemáticamente por una policy custom por consumidor. |

> **Sobre 2FA en la Console de MinIO**: la auth nativa de MinIO no tiene 2FA. La defensa primaria de la Console es Authelia 2FA por delante; la Console es la segunda capa. En la práctica, el operador ve Authelia (TOTP), luego la pantalla de login de MinIO (`MINIO_ROOT_USER`/password) — exactamente el mismo patrón que Syncthing en `03-syncthing.md`.

---

## Decisión: dónde viven los datos y permisos

La imagen oficial corre por defecto como UID `1000` (`minio-user`) cuando no se especifica `user:`. Aquí se fuerza `user: ${PUID}:${PGID}` (1000:1000), coincidiendo con el `homelab` del host: la base de datos de objetos es propiedad del operador, sin ID huérfano.

| Subsistema | Ruta en hd2t | Owner:Group | Justificación |
|---|---|---|---|
| Datos (buckets, IAM, políticas, KMS) | `/mnt/hd2t/apps/minio/data` | `1000:1000` | MinIO almacena objetos en `<bucket>/<object>` con metadatos `xl.meta` y la metadata IAM bajo `.minio.sys/`. |

> **Sobre `.minio.sys/`**: dentro de `/mnt/hd2t/apps/minio/data` MinIO crea un directorio especial `.minio.sys/` con la configuración interna (usuarios IAM, políticas, server config, buckets metadata). **No tocar a mano** — un `cat`/`ls` es seguro, un `vim` no. Cualquier cambio se hace por API/Console o `mc admin`.

> **Por qué no microSD**. Los objetos S3 son escrituras inmutables de tamaño variable; bucket de backups crece a GiBs en días. La microSD no debe absorber esto. Todo va a `hd2t` con USB 3.0.

> **Por qué no `hd5t`**. `hd5t` está reservado para la biblioteca multimedia de Stash (5 TB de vídeos+imágenes inmutables). Mezclar buckets S3 ahí complica el plan de backup y los volúmenes de Stash. MinIO vive en `hd2t` junto al resto de aplicaciones.

---

## Stack: `stacks/minio/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/minio/docker-compose.yml` | microSD (git) | Stack (servicio `minio`). |
| `stacks/minio/.env.example` | microSD (git) | Plantilla con `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, `MINIO_RELEASE`. |
| `stacks/caddy/conf.d/09-minio.caddy` | microSD (git) | Drop-in del bloque LAN para `minio.${DOMAIN_LAN}` (Console) y `s3.${DOMAIN_LAN}` (API). |
| `/mnt/hd2t/apps/minio/data/` | hd2t | Datos de MinIO (buckets + `.minio.sys/`). Owner `1000:1000`. |

### `stacks/minio/docker-compose.yml`

```yaml
# MinIO — almacenamiento de objetos S3-compatible del homelab.
# Documentado en docs/06-almacenamiento/04-minio.md.

name: minio

services:
  minio:
    image: quay.io/minio/minio:${MINIO_RELEASE}
    container_name: minio
    hostname: minio
    restart: unless-stopped

    # API S3 (9000) y Console (9001) NO se publican al host:
    # solo accesibles vía Caddy y vía red `homelab`.
    expose:
      - "9000"
      - "9001"

    # UID/GID coherente con el operador del host.
    user: "${PUID}:${PGID}"

    environment:
      TZ: ${TZ}

      # --- Bootstrap del root user (válido en todos los arranques) ---
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}

      # --- URLs públicas que MinIO anuncia ---
      # Pre-signed URLs y enlaces "Share" usan MINIO_SERVER_URL.
      # Redirects post-login de la Console usan MINIO_BROWSER_REDIRECT_URL.
      MINIO_SERVER_URL: "https://s3.${DOMAIN_LAN}"
      MINIO_BROWSER_REDIRECT_URL: "https://minio.${DOMAIN_LAN}"

      # --- Region (cualquier S3-client la pide; valor cosmético) ---
      MINIO_REGION_NAME: "homelab"

      # --- Telemetría: deshabilitada ---
      MINIO_PROMETHEUS_AUTH_TYPE: "public"   # /minio/v2/metrics/cluster sin auth
                                             # (lo consume Prometheus en LAN).

      # --- Update check al arrancar: deshabilitado ---
      # MinIO consulta releases nuevas al iniciar; el operador controla los
      # upgrades manualmente.
      MINIO_UPDATE: "off"

      # --- Browser (Console): activo ---
      MINIO_BROWSER: "on"

    command:
      - "server"
      - "/data"
      - "--console-address"
      - ":9001"
      - "--address"
      - ":9000"

    volumes:
      - /mnt/hd2t/apps/minio/data:/data

    networks:
      - homelab

    healthcheck:
      # /minio/health/live responde 200 sin auth cuando MinIO sirve.
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:9000/minio/health/live || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s

    labels:
      homelab.role: "object-storage"
      homelab.backup: "true"
      # MinIO NO se actualiza con Watchtower: los releases pueden cambiar
      # mc admin / API admin entre versiones. Upgrade manual y deliberado.
      com.centurylinklabs.watchtower.enable: "false"

networks:
  homelab:
    external: true
```

> **Sobre `user: "${PUID}:${PGID}"`**: la imagen oficial soporta correr como UID arbitrario siempre que el directorio `/data` sea propiedad de ese UID (lo es, lo creó la Fase 1 con `homelab:homelab`). Sin esta línea, MinIO arranca como UID `1000` (`minio-user` interno), que en este homelab coincide casualmente con `homelab` — pero forzar la línea evita la sorpresa el día que la imagen cambie su UID por defecto.

> **Sobre `MINIO_PROMETHEUS_AUTH_TYPE: "public"`**: MinIO expone métricas Prometheus en `/minio/v2/metrics/cluster`. Por defecto requiere un JWT. Como Prometheus vive en la red `homelab` (LAN-only) y el endpoint solo expone métricas operativas (no datos de buckets), `public` simplifica la integración con `01-prometheus.md` sin abrir un flanco real. La integración concreta (`scrape_config` apuntando a `http://minio:9000/minio/v2/metrics/cluster`) se documenta como nota en *Configuración*.

> **Sobre `MINIO_UPDATE: "off"`**: idéntica regla que `STNOUPGRADE` en Syncthing. MinIO trae un mecanismo de auto-update *in-place* del binario; combinado con un tag fijo, el binario en el contenedor diferiría del declarado. Se desactiva.

> **Sobre `--console-address :9001`**: si se omite, MinIO elige un puerto aleatorio para la Console al arrancar y los reverse_proxy de Caddy fallan al siguiente reinicio. Fijarlo es obligatorio para que el `expose:` 9001 sea estable.

> **Sobre `restart: unless-stopped`**: idéntico al resto del homelab. MinIO arranca rápido (<5 s en una Pi 5 sin buckets); el `start_period: 30s` cubre el peor caso.

### `stacks/minio/.env.example`

```bash
# stacks/minio/.env.example
# Plantilla para el stack MinIO. Copiar a `.env` y rellenar.
# Las generales (TZ, PUID, PGID, DOMAIN_LAN, DOMAIN_TS) vienen del .env GLOBAL.

# --- Release (tag fechado de quay.io/minio/minio) ---
# Consultar https://github.com/minio/minio/releases y elegir el último estable.
# NO usar `latest` ni `edge`.
MINIO_RELEASE=RELEASE.2025-04-22T17-06-50Z

# --- Root user (admin global) ---
# Usuario reservado para administración desde la Console y `mc admin`.
# NO usar como Access Key de clientes S3: para eso se crean Access Keys
# nominales por consumidor (sección "Configuración").
MINIO_ROOT_USER=adminhomelab

# Generar con: openssl rand -base64 32
MINIO_ROOT_PASSWORD=CAMBIAR_PASSWORD_FUERTE
```

> **`.env` real, no `.env.example`**: idéntica regla que en el resto del homelab. `stacks/minio/.env` no se versiona; `stacks/minio/.env.example` sí. `MINIO_ROOT_PASSWORD` **nunca** entra en git.

> **Sobre `MINIO_ROOT_USER`**: evitar `admin` literal (objetivo trivial de fuerza bruta si alguna vez la Console se expusiera mal). Cualquier nombre razonable sirve.

### Drop-in de Caddy: `stacks/caddy/conf.d/09-minio.caddy`

```caddy
# /etc/caddy/conf.d/09-minio.caddy — bloques LAN para MinIO.
# Documentado en docs/06-almacenamiento/04-minio.md.
#
# Dos hostnames distintos para el plano de control y el de datos:
#   minio.${DOMAIN_LAN}  -> Console (9001), tras Authelia 2FA.
#   s3.${DOMAIN_LAN}     -> API S3 (9000), Authelia bypass; SigV4 nativo.
#
# IMPORTANTE: s3.${DOMAIN_LAN} debe tener `policy: bypass` en Authelia.
# Los clientes S3 no siguen redirects HTML de login (igual que WebDAV).

# -------------------------------------------------------------------------
# Console (UI de administración)
# -------------------------------------------------------------------------
minio.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Authelia 2FA: defensa primaria del plano de control.
    import authelia_two_factor

    reverse_proxy http://minio:9001 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}

# -------------------------------------------------------------------------
# API S3 (plano de datos)
# -------------------------------------------------------------------------
s3.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Subidas multipart pueden alcanzar GiBs por petición.
    request_body {
        max_size 5GB
    }

    # Sin import authelia_*: los clientes S3 no siguen redirects HTML.
    # Auth nativa de MinIO (AWS SigV4) hace el control.

    reverse_proxy http://minio:9000 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # MinIO valida la firma SigV4 contra el Host original.
        # Sin Host {host} la firma falla con SignatureDoesNotMatch.
        # (header_up Host {host} ya lo cubre arriba; explícito por claridad.)
    }
}
```

> **Sobre `request_body max_size 5GB`**: las subidas a S3 se hacen por *multipart upload*, donde cada *part* es ≤5 GiB y el ETag global del objeto compone los ETags parciales. Caddy debe permitir cada *part* completo. 5 GiB cubre el límite duro de un *part* S3-protocolo. Para objetos más grandes, los clientes ya troceán y el límite no se alcanza.

> **Sobre `header_up Host {host}`**: la firma SigV4 incluye el header `Host`. Si Caddy reescribe `Host: minio` (el upstream interno) la firma generada por el cliente contra `Host: s3.lan` no coincide y MinIO devuelve `SignatureDoesNotMatch`. **Imprescindible** mantener el `Host` original.

> **Sobre `import healthcheck`**: el snippet (`03-red/04-caddy.md`) responde directamente desde Caddy a `/healthz`, sin tocar MinIO. Para *liveness check* del bloque Caddy, no para MinIO (que tiene su propio `/minio/health/live`).

### Crear los directorios persistentes y desplegar

```bash
# 1) Directorio de datos. Owner correcto desde la creación.
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/minio
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/minio/data

# 2) Drop-in de Caddy.
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/09-minio.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/09-minio.caddy

# 3) .env del stack.
cd /home/homelab/homelab
set -a; source .env; set +a

cp stacks/minio/.env.example stacks/minio/.env
chmod 0600 stacks/minio/.env
$EDITOR stacks/minio/.env   # rellenar MINIO_ROOT_PASSWORD con `openssl rand -base64 32`
                            # y elegir MINIO_RELEASE estable.

# 4) Editar Authelia: añadir minio.${DOMAIN_LAN} (two_factor) y
#    s3.${DOMAIN_LAN} (bypass) en access_control.rules.
sudo $EDITOR /mnt/hd2t/apps/authelia/config/configuration.yml
docker logs authelia --tail 20 | grep -i 'reloaded'

# 5) Validar el Caddyfile antes de recargarlo.
docker exec caddy caddy validate --config /etc/caddy/Caddyfile

# 6) Levantar el stack.
docker compose \
    -f stacks/minio/docker-compose.yml \
    --env-file stacks/minio/.env \
    up -d

# 7) Recargar Caddy para tomar el nuevo drop-in.
docker kill --signal=SIGUSR1 caddy

# 8) Esperar a que el contenedor esté healthy.
docker compose -f stacks/minio/docker-compose.yml ps
# minio   Up 30s (healthy)
```

Logs esperables del primer arranque:

```bash
docker compose -f stacks/minio/docker-compose.yml logs --tail 30 minio
# ...
# MinIO Object Storage Server
# Copyright: 2015-... MinIO, Inc.
# License: GNU AGPLv3
# Version: RELEASE.2025-04-22T17-06-50Z (...)
#
# API: http://...:9000
# WebUI: http://...:9001
#
# Docs: https://docs.min.io
```

Cambios mínimos esperados en `configuration.yml` de Authelia (sección `access_control.rules`):

```yaml
access_control:
  default_policy: deny
  rules:
    # ... reglas existentes ...

    # MinIO Console: panel administrativo del homelab.
    - domain: "minio.${DOMAIN_LAN}"
      policy: two_factor
      subject:
        - "group:admins"

    # MinIO S3 API: clientes (mc, restic, rclone) firman SigV4.
    # No interceptar con forward_auth: rompería todos los clientes.
    - domain: "s3.${DOMAIN_LAN}"
      policy: bypass
```

---

## Configuración

### 1) Acceso a la Console e inicio de sesión

Desde un cliente de la LAN con la CA interna ya instalada:

```text
1. Abrir https://minio.lan/
2. Authelia intercepta: form login → 2FA TOTP. Tras OK, redirige a minio.lan.
3. Console de MinIO pide credenciales:
     Access Key:  <MINIO_ROOT_USER>
     Secret Key:  <MINIO_ROOT_PASSWORD>
4. Aterriza en el dashboard (Buckets, Identity, Access, Settings, Monitoring).
```

### 2) Configurar `mc` (cliente CLI) en la Pi

`mc` es la navaja suiza administrativa. Se ejecuta con `docker run --rm` para no añadir un servicio permanente:

```bash
# Crear un alias persistente en ~/.mc/config.json del operador.
# (Hay que apuntar a la red `homelab` para hablar al hostname `minio`.)
mkdir -p ~/.mc
docker run --rm --network homelab \
    -v ~/.mc:/root/.mc \
    quay.io/minio/mc:latest \
    alias set local http://minio:9000 \
        "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"

# Verificar.
docker run --rm --network homelab -v ~/.mc:/root/.mc quay.io/minio/mc:latest \
    admin info local
# ●  minio:9000
#    Uptime: 5 minutes
#    Version: 2025-04-22T17:06:50Z
#    Network: 1/1 OK
#    Drives: 1/1 OK
#    Pool: 1
```

Para hablar al endpoint público (`s3.lan`) desde otro PC con la CA interna:

```bash
# Desde un host externo en la LAN (con la CA interna ya importada):
mc alias set homelab https://s3.lan "$ACCESS_KEY" "$SECRET_KEY"
mc ls homelab
```

> **Sobre el alias `local` vs `homelab`**: el alias `local` apunta a `http://minio:9000` directo dentro de la red Docker — útil para administración hecha *desde la Pi*. El alias `homelab` apunta a `https://s3.lan` — el endpoint público. Para crear/borrar buckets y aplicar policies, ambos sirven; para emitir pre-signed URLs (que viajan al exterior), usar `homelab`.

### 3) Crear los buckets iniciales del homelab

| Bucket | Propósito | Versionado | Lifecycle |
|---|---|---|---|
| `app-snapshots` | Volcados puntuales de aplicaciones (Forgejo dump, Vaultwarden export, Grafana snapshot, etc.) cuando se incorporen. | Habilitado, *MFA Delete* off. | Mover versiones >30 días a `STANDARD` (no aplica en SNSD) y purgar versiones >90 días. |
| `mc-mirror-staging` | Buffer para offsite replication (`mc mirror` o `rclone sync` a B2/R2). | Deshabilitado. | Purgar objetos >7 días que no se hayan replicado (señal de fallo). |
| `restic-vaultwarden` | Repositorio restic para Vaultwarden (cuando se documente en Fase 7). | Deshabilitado (restic ya versiona internamente). | Sin lifecycle: lo gestiona restic con `forget --keep-*`. |
| `nextcloud-objectstore` | **Reservado** (vacío) por si en el futuro Nextcloud activa `OBJECTSTORE_S3`. | Habilitado obligatoriamente. | Sin lifecycle. |

Crear los buckets desde `mc`:

```bash
MC="docker run --rm --network homelab -v $HOME/.mc:/root/.mc quay.io/minio/mc:latest"

$MC mb local/app-snapshots
$MC mb local/mc-mirror-staging
$MC mb local/restic-vaultwarden
$MC mb local/nextcloud-objectstore

# Versionado donde aplique.
$MC version enable local/app-snapshots
$MC version enable local/nextcloud-objectstore

# Lifecycle: borrar versiones non-current >90 días en app-snapshots.
cat > /tmp/lifecycle-app-snapshots.json <<'EOF'
{
  "Rules": [
    {
      "ID": "expire-noncurrent-90d",
      "Status": "Enabled",
      "NoncurrentVersionExpiration": { "NoncurrentDays": 90 }
    }
  ]
}
EOF
$MC ilm import local/app-snapshots < /tmp/lifecycle-app-snapshots.json
```

### 4) Crear Access Keys y políticas IAM por consumidor

La política operacional: **una Access Key por aplicación, scope mínimo a su bucket**. El `MINIO_ROOT_USER` **no se usa nunca** desde aplicaciones; queda reservado para administración humana.

Ejemplo concreto: una Access Key para que un futuro `mc mirror` cron job replique `mc-mirror-staging` a un proveedor offsite.

Definir la policy:

```bash
cat > /tmp/policy-mirror-staging-rw.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": ["arn:aws:s3:::mc-mirror-staging"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": ["arn:aws:s3:::mc-mirror-staging/*"]
    }
  ]
}
EOF

$MC admin policy create local mirror-staging-rw /tmp/policy-mirror-staging-rw.json

# Crear un service account (Access Key + Secret) atado a esa policy.
$MC admin user svcacct add local "$MINIO_ROOT_USER" \
    --policy mirror-staging-rw
# Generated:
#   Access Key: AKIAIOSF...HOMELAB1
#   Secret Key: wJalrXUtnFEMI/...EXAMPLEKEY1
# (anotarlos: la Secret Key NO se vuelve a mostrar nunca)
```

Mismo patrón para cualquier otro consumidor: `restic-vaultwarden-rw`, `nextcloud-objectstore-rw`, etc. Se documenta en cada doc consumidor (Fase 7+) cómo crear su par.

> **Sobre service accounts vs IAM users**: MinIO soporta ambos. Un *user IAM* es una identidad humana con su propio Access Key. Un *service account* es un par Access Key/Secret derivado de un user existente, con un *subset* de su policy. La práctica del homelab: el operador es el *user* (`MINIO_ROOT_USER`), las aplicaciones reciben *service accounts* derivados con policies estrechas. Los Secrets de los service accounts se almacenan en el `.env` del stack que los consume (`stacks/<consumidor>/.env`).

### 5) Habilitar SSE-S3 (cifrado en reposo, opcional)

MinIO soporta cifrado en reposo gestionando la clave él mismo (no KES). Útil si los buckets contienen datos sensibles y se quiere defensa adicional contra acceso al disco directo:

```bash
# Activar SSE-S3 por bucket. La clave maestra la gestiona MinIO en .minio.sys/.
$MC encrypt set sse-s3 local/app-snapshots
$MC encrypt set sse-s3 local/restic-vaultwarden
$MC encrypt info local/app-snapshots
# Auto encryption 'sse-s3' is enabled
```

> **Decisión**: **deshabilitado por defecto** en este documento. La superficie real de ataque es "alguien con acceso físico al `hd2t`"; ese vector ya está mitigado por el control físico de la Pi en casa. Habilitar SSE-S3 añade una capa, pero también un punto de fallo: pérdida de la master key → buckets ilegibles. Reabrible si los buckets contienen datos personales sensibles (export Vaultwarden, dumps de BD).

### 6) Conectar Prometheus a las métricas de MinIO

`MINIO_PROMETHEUS_AUTH_TYPE: "public"` ya expone `/minio/v2/metrics/cluster` sin auth. Añadir al `prometheus.yml` (`05-monitorizacion/01-prometheus.md`):

```yaml
scrape_configs:
  - job_name: minio
    metrics_path: /minio/v2/metrics/cluster
    scheme: http
    static_configs:
      - targets: ["minio:9000"]
        labels:
          homelab_role: object-storage
```

Recargar Prometheus (`docker kill --signal=SIGHUP prometheus`). Las métricas básicas (`minio_cluster_capacity_*`, `minio_s3_requests_*`, `minio_disk_storage_used_bytes`) aparecen en el discovery. La integración Grafana se cubre en `05-monitorizacion/02-grafana.md` con el dashboard oficial de MinIO (ID 13502).

### 7) Operación diaria

| Acción | Comando |
|---|---|
| Estado del cluster | `$MC admin info local` |
| Listar buckets | `$MC ls local` |
| Tamaño por bucket | `$MC du local/<bucket>` |
| Listar policies | `$MC admin policy list local` |
| Listar usuarios + service accounts | `$MC admin user list local`, `$MC admin user svcacct list local <user>` |
| Rotar la Secret Key del root user | `docker exec minio printenv MINIO_ROOT_PASSWORD` (consulta) → editar `.env` → `docker compose ... up -d --force-recreate` |
| Backup puntual de un bucket a otro local | `$MC mirror local/app-snapshots local/app-snapshots-bak` |
| Tail de logs del servidor | `docker logs -f minio` |
| Restart limpio | `docker compose -f stacks/minio/docker-compose.yml restart` |
| Health desde fuera | `curl -ks https://s3.lan/minio/health/live` |

### 8) Pruebas funcionales

```bash
# Subir un objeto de test, listar, descargar, borrar.
echo "hello homelab" > /tmp/hello.txt
$MC cp /tmp/hello.txt local/app-snapshots/hello.txt
$MC ls local/app-snapshots/
$MC cat local/app-snapshots/hello.txt
# hello homelab
$MC rm local/app-snapshots/hello.txt

# Idéntico contra el endpoint público (con la CA interna instalada en el cliente).
mc alias set homelab https://s3.lan "$ACCESS_KEY" "$SECRET_KEY"
mc ls homelab
mc cp /tmp/hello.txt homelab/app-snapshots/hello.txt
mc cat homelab/app-snapshots/hello.txt
```

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/minio/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack en git. |
| `/home/homelab/homelab/stacks/minio/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/minio/.env` | microSD | `homelab:homelab` | `0600` | Secretos (`MINIO_ROOT_PASSWORD`). **No** en git. |
| `/home/homelab/homelab/stacks/caddy/conf.d/09-minio.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy (dos hostnames). |
| `/mnt/hd2t/apps/minio/data/` | hd2t | `homelab:homelab` | `0750` | Raíz de datos de MinIO. Contiene un subdirectorio por bucket más `.minio.sys/`. |
| `/mnt/hd2t/apps/minio/data/.minio.sys/` | hd2t | `homelab:homelab` | `0750` | **Configuración interna**: usuarios IAM, políticas, server config, buckets metadata, KMS keys. **NO tocar a mano**. |
| `/mnt/hd2t/apps/minio/data/<bucket>/` | hd2t | `homelab:homelab` | `0750` | Objetos almacenados en el bucket (formato MinIO `xl.meta` desde 2022). |

> **`.minio.sys/` es el corazón del nodo**. Si se pierde, los buckets visibles en disco siguen estando pero MinIO no sabe a quién pertenecen, qué políticas tienen, ni quién puede leerlos. **Respaldarlo es prioridad 1** en el plan de backup, junto con `.env` (el `MINIO_ROOT_PASSWORD` es lo único que recupera el control si se rota la clave).

> **`<bucket>/` por bucket**. MinIO almacena cada objeto en `<bucket>/<object-key>/xl.meta` (o partes si está cifrado/erasure-coded). Un `ls` muestra estructura amigable, un `cat` no muestra el contenido legible: el formato es interno. La forma correcta de leer/escribir es **siempre** vía API S3 o `mc`.

> **Tamaño esperado**. Tras instalación: `data/` ≈ 5–10 MiB (`.minio.sys/` con server config, IAM vacío). El crecimiento real depende del uso. Estimación inicial conservadora: ≤50 GiB en el primer año (snapshots + restic-vaultwarden + buffer offsite); revisable.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/minio/docker-compose.yml`, `.env.example` | Versionados. |
| `stacks/minio/.env` | **NO** versionado (`MINIO_ROOT_PASSWORD`); en `.gitignore`. |
| `stacks/caddy/conf.d/09-minio.caddy` | Versionado. |
| Decisiones (SNSD, dos hostnames, bypass S3, IAM por consumidor) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

> **Caso especial**: MinIO **es** un destino de backup. Algunos de sus buckets (`restic-vaultwarden`, `app-snapshots`) son ya copias de otros servicios. Respaldarlos otra vez con Borg duplica historia y consumo. La política se decide bucket a bucket.

| Ruta / Bucket | ¿Se respalda con Borg? | Estrategia | Por qué |
|---|---|---|---|
| `/mnt/hd2t/apps/minio/data/.minio.sys/` | **Sí**. | Diaria, prioridad alta. | IAM, políticas, server config. Sin esto, los buckets son metadata-huérfana. Pequeño en tamaño, crítico en valor. |
| `/mnt/hd2t/apps/minio/data/nextcloud-objectstore/` | **Solo si activo**. | Diaria. | Si Nextcloud se mueve a S3 backend, este bucket es la fuente primaria de los ficheros de los usuarios; se respalda igual que `data/` de Nextcloud hoy. |
| `/mnt/hd2t/apps/minio/data/app-snapshots/` | **Opcional**. | Semanal. | Es ya un *snapshot* de las apps; respaldar con Borg duplica historia. La protección efectiva: versionado MinIO + lifecycle. Borg como red de seguridad ante corrupción del propio MinIO. |
| `/mnt/hd2t/apps/minio/data/restic-vaultwarden/` | **No**. | Excluido. | restic versiona y deduplica internamente. Replicarlo con Borg multiplica el tamaño sin valor. La protección: que el bucket esté presente; si se corrompe, restic detecta los pack rotos y avisa. |
| `/mnt/hd2t/apps/minio/data/mc-mirror-staging/` | **No**. | Excluido. | Buffer transitorio; los datos viven en su origen y en el destino offsite. |

> **Procedimiento de dump consistente**:
>
> MinIO en SNSD admite ser respaldado en caliente con caveat: una operación PUT en curso puede dejar `xl.meta` parcial. La práctica recomendada:
>
> ```bash
> # Hook pre-backup (opcional para mayor consistencia).
> docker compose -f stacks/minio/docker-compose.yml stop minio
>
> # Borg corre y respalda /mnt/hd2t/apps/minio/data/{.minio.sys,<bucket>...}
>
> # Hook post-backup
> docker compose -f stacks/minio/docker-compose.yml start minio
> ```
>
> Downtime: <30 s. **Si se decide respaldar en caliente** (default recomendado, sin hook stop/start), el riesgo es perder el último PUT en vuelo en el momento del snapshot — aceptable para los usos del homelab. Para mayor garantía, programar Borgmatic en una franja horaria de tráfico nulo (madrugada).

> **Política de retención**: la decisión vive en `07-backups/01-estrategia-backup.md`. Recomendación de partida para MinIO: 7 daily, 4 weekly, 6 monthly sobre `.minio.sys/` y los buckets que se decidan respaldar.

> **Offsite**: el bucket `mc-mirror-staging` es la pieza que el operador puede usar para un sync periódico hacia un proveedor S3-compatible:
>
> ```cron
> # Cron del usuario homelab — replicar staging a B2 cada noche.
> 30 3 * * * /usr/local/bin/mc mirror --remove --overwrite local/mc-mirror-staging b2/homelab-offsite/
> ```
>
> El detalle del proveedor offsite, las credenciales B2/R2 y la rotación se cierran en `07-backups/01-estrategia-backup.md`.

Procedimiento de restore (pérdida del contenedor, datos intactos en `hd2t`):

```bash
docker compose -f stacks/minio/docker-compose.yml up -d --force-recreate
# MinIO reusa /mnt/hd2t/apps/minio/data; root user, IAM, buckets, policies
# vuelven exactamente como estaban (todo vive bajo .minio.sys/).
# Tras ~30 s de healthcheck, los clientes se reconectan automáticamente.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear Fases 1, 2, 3 y 4.
2. Restaurar `/mnt/hd2t/apps/minio/data/` desde Borg (`.minio.sys/` imprescindible; los buckets que se hubieran respaldado).
3. Verificar permisos: `chown -R 1000:1000 /mnt/hd2t/apps/minio`.
4. Restaurar el `.env` del stack (con `MINIO_ROOT_USER` y `MINIO_ROOT_PASSWORD` originales) o cambiarlos: si se cambian, los Access Keys creados como service accounts del root **siguen funcionando** (no dependen del password del root, solo de la policy asociada).
5. Levantar el stack: `docker compose -f stacks/minio/docker-compose.yml up -d`.
6. Verificar con `mc admin info local` que el cluster reporta el mismo número de buckets, usuarios y policies que antes del incidente.

Si por error se pierde solo `.minio.sys/`:

```text
1. Los buckets siguen en disco como subdirectorios pero MinIO los muestra
   "huérfanos" sin policies ni Access Keys.
2. Restaurar `.minio.sys/` desde Borg.
3. Reiniciar el contenedor.
4. Si Borg no tenía `.minio.sys/`: recrear desde cero (root user del .env,
   crear policies/users de nuevo manualmente). Los datos de los buckets son
   accesibles tras `mc admin trace local` y readd manual.
```

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| Console no carga (502 desde Caddy) | MinIO arrancando, o `--console-address :9001` omitido y la Console eligió otro puerto. | `docker logs minio` → buscar `WebUI: http://...:XXXX`; comprobar `command:` en compose; reiniciar. |
| Console carga pero pide login básico antes de Authelia | Authelia no tiene la regla `policy: two_factor` para `minio.lan`. | Editar `configuration.yml`, recargar Authelia, reintentar. |
| Tras Authelia, la Console redirige loop sobre `/login` | `MINIO_BROWSER_REDIRECT_URL` no apunta al hostname público (https). | Asegurar `MINIO_BROWSER_REDIRECT_URL=https://minio.${DOMAIN_LAN}` y recrear contenedor. |
| Cliente S3 (`mc`, `aws`, `restic`) recibe `SignatureDoesNotMatch` | Caddy reescribe el header `Host` al upstream interno (`minio:9000`) en vez de mantener `s3.lan`. | Verificar `header_up Host {host}` en el bloque `s3.${DOMAIN_LAN}`. |
| Cliente S3 recibe `302` y bucle al subir un objeto | Authelia está interceptando `s3.lan` (la regla `bypass` no se aplicó). | Editar `configuration.yml` de Authelia, añadir entrada `policy: bypass` para `domain: s3.${DOMAIN_LAN}`, esperar reload (~5 s) y reintentar. |
| `restic` o `rclone` rechazan el certificado | Falta CA interna en el cliente. | Importar la CA interna del homelab; o (mal) `--cacert /path/to/ca.pem`; nunca `--insecure`. |
| `mc admin info local` da `error: connection refused` | El alias apunta a un host inalcanzable. Si se ejecuta `docker run` SIN `--network homelab`, el contenedor de `mc` no resuelve `minio`. | Añadir `--network homelab` al `docker run` o usar el alias `homelab` (`https://s3.lan`). |
| Pre-signed URL emitida desde la Console no se puede descargar fuera de la red | `MINIO_SERVER_URL` no apunta al hostname público y la URL contiene el hostname interno (`minio:9000`). | Asegurar `MINIO_SERVER_URL=https://s3.${DOMAIN_LAN}` y recrear contenedor; las nuevas URLs ya contendrán el hostname público. Las antiguas hay que regenerarlas. |
| Subida multipart de un objeto >5 GiB falla con `EntityTooLarge` | `request_body max_size` de Caddy por debajo del tamaño del *part*. | Subir `request_body max_size 5GB` (o más) en el bloque `s3.lan`; `docker kill --signal=SIGUSR1 caddy`. |
| `MINIO_ROOT_PASSWORD` cambiado pero los Access Keys de service accounts dejan de funcionar | Los service accounts dependen del *user padre* (`MINIO_ROOT_USER`) pero **no** de su password. Si dejaron de funcionar, fue por otra causa: revisar `mc admin user svcacct list local <user>` y la policy asociada. | Recrear si la policy fue borrada. Las Secret Keys no se recuperan; si se perdieron, recrear el service account. |
| `/minio/v2/metrics/cluster` devuelve 401 al consultar desde Prometheus | Falta `MINIO_PROMETHEUS_AUTH_TYPE: "public"` o se cambió a otro modo. | Asegurar la variable y recrear el contenedor. |
| Espacio del bucket `app-snapshots` crece sin parar | Versionado activo + lifecycle no configurado o sin efecto. | `mc ilm list local/app-snapshots`; si no hay reglas, importar el JSON de `Configuración`. |
| `data/` reportado en `df -h` no coincide con `mc du` | Cuotas de filesystem (`du -sh`) vs *logical size* reportado por MinIO; multipart partes incompletas también ocupan disco. | `mc admin trace local` para ver multipart en curso; `mc rb --abort-multipart-upload` para limpiar abortadas. |
| `502 bad gateway` puntual al hacer un `mc cp` muy grande | Timeout del reverse_proxy de Caddy en una conexión larga. | Caddy por defecto tolera transferencias largas; si aparece, revisar `flush_interval` y `transport http { read_timeout, write_timeout }` en el bloque `s3.lan`. |
| `MinIO is in `safe-mode`` en logs | Filesystem subyacente reportó error de I/O; MinIO entró en read-only para proteger los datos. | `dmesg | tail` — buscar errores del bus USB / disco; `smartctl -a /dev/disk/by-label/hd2t`. Restaurar el FS antes de reiniciar MinIO. |
| Versión nueva tras `docker compose pull` rechaza arrancar con `inconsistent metadata` | Upgrade saltó múltiples releases con cambio de formato de `.minio.sys/`. | Volver al tag anterior, leer changelog, hacer el upgrade en pasos intermedios o desde un snapshot. **Confirma por qué Watchtower está deshabilitado**. |

---

## Decisiones que **no** se toman en este documento

- **Distribuir MinIO** sobre múltiples drives o nodos. La Pi tiene un solo `hd2t`; reabrible si en el futuro se monta un segundo disco (4 drives idénticos minimum para EC), o un segundo nodo en otra máquina.
- **MinIO como destino primario de Borgmatic**. Borg habla a un *repositorio* de filesystem; el destino directo es `/mnt/hd2t/backups/`. Reabrible si se introduce un segundo nodo MinIO en otra máquina y conviene unificar el plano de backup.
- **Site Replication / Bucket Replication**. Solo viable con ≥2 nodos.
- **KES + Vault** para gestión de claves SSE. Reabrible si se decide cifrar buckets sensibles con claves externas.
- **OIDC contra Authelia para la Console**. Reabrible cuando Authelia exponga OIDC y se valide en MinIO (la Console acepta OIDC con `MINIO_IDENTITY_OPENID_*`).
- **MinIO Operator (Kubernetes)**. Fuera del alcance.
- **Cuotas globales** (`mc admin bucket quota`). Útil cuando hay múltiples consumidores compitiendo; hoy uno o dos. Reabrible.
- **Notificaciones de eventos** (`mc event add` → webhook a Uptime Kuma o Home Assistant). Reabrible cuando aparezca el caso de uso (p. ej. notificar al operador cuando el offsite mirror sube un volumen anómalo).
- **Audit log a otro destino** (`MINIO_AUDIT_*`). Los logs del contenedor (vía Dozzle, `05-monitorizacion/06-dozzle.md`) cubren la observabilidad de auditoría inicial.
- **Auto-actualización vía Watchtower**. Excluido explícitamente: los upgrades de release pueden cambiar `mc admin` o el formato interno; se aplican deliberadamente.
- **`fail2ban` para la Console**. Authelia ya rate-limitea logins; el plano S3 valida SigV4 (no es vulnerable a *brute force* clásico — fallar la firma no da pistas). Reabrible si en el futuro aparece tráfico patológico.
- **Bucket público / anonymous read**. Sin caso de uso; **todos** los buckets son privados por default y permanecen así.
- **MinIO Console expuesta vía Tailscale Funnel a internet**. Fuera del alcance del homelab (no exposición a internet).

---

## Verificación Final

Antes de dar por cerrada la Fase 6:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/minio/docker-compose.yml ps` | `minio Up (healthy)` |
| Imagen correcta y pinneada | `docker inspect minio --format '{{.Config.Image}}'` | `quay.io/minio/minio:RELEASE.2025-...` (no `latest`) |
| Conectado a `homelab` | `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` | incluye `minio` y `caddy` |
| Sin puertos publicados al host | `docker port minio` | salida vacía |
| `minio.lan` y `s3.lan` resuelven al IP de la Pi | `dig +short minio.lan s3.lan @192.168.1.2` | dos líneas con `192.168.1.10` |
| Caddy sirve `s3.lan` con cert de la CA interna | `echo \| openssl s_client -connect s3.lan:443 -servername s3.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| Authelia exige 2FA en `minio.lan` | `curl -ksI https://minio.lan/` | `HTTP/2 302` con `Location: https://auth.lan/?rd=...` |
| Authelia hace `bypass` para `s3.lan` | `curl -ksI https://s3.lan/minio/health/live` | `HTTP/2 200` directo de MinIO (no `302` a `auth.lan`) |
| `/minio/health/live` responde OK desde el contenedor | `docker exec minio curl -fsS http://127.0.0.1:9000/minio/health/live` | (sin error, exit 0) |
| `MINIO_SERVER_URL` y `MINIO_BROWSER_REDIRECT_URL` correctos | `docker exec minio env \| grep -E 'MINIO_SERVER_URL\|MINIO_BROWSER_REDIRECT_URL'` | apuntan a `https://s3.lan` y `https://minio.lan` |
| Owner correcto del directorio de datos | `stat -c '%u:%g' /mnt/hd2t/apps/minio/data` | `1000:1000` |
| `.minio.sys/` creado tras primer arranque | `ls /mnt/hd2t/apps/minio/data/.minio.sys/` | listado con `config/`, `buckets/`, `tmp/` |
| Login en la Console con root user | navegador con CA → `https://minio.lan/` → Authelia 2FA → `MINIO_ROOT_USER` + password | dashboard de MinIO carga |
| Buckets iniciales creados | `mc ls local` (vía `docker run --network homelab`) | `app-snapshots`, `mc-mirror-staging`, `restic-vaultwarden`, `nextcloud-objectstore` |
| Versionado en `app-snapshots` | `mc version info local/app-snapshots` | `Enabled` |
| Lifecycle activo en `app-snapshots` | `mc ilm list local/app-snapshots` | regla `expire-noncurrent-90d` |
| Al menos un service account creado | `mc admin user svcacct list local "$MINIO_ROOT_USER"` | una o más Access Keys listadas |
| Subida y descarga funcional | `echo hi > /tmp/h.txt && mc cp /tmp/h.txt local/app-snapshots/h.txt && mc cat local/app-snapshots/h.txt` | imprime `hi` |
| Métricas Prometheus accesibles | `docker exec minio curl -fsS http://127.0.0.1:9000/minio/v2/metrics/cluster \| head -5` | líneas tipo `# HELP minio_cluster_capacity_raw_total_bytes ...` |
| `MINIO_UPDATE=off` activo | `docker exec minio env \| grep MINIO_UPDATE` | `MINIO_UPDATE=off` |
| Persistencia tras reboot | `sudo reboot`; al reconectar: `docker ps --filter name=minio` | `minio Up (healthy)` sin acción manual |
| Stack en git | `git ls-files stacks/minio` | `docker-compose.yml`, `.env.example` tracked; `.env` **no** tracked |

Cumplido el último punto, la Fase 6 queda cerrada: el homelab tiene **cuatro vías** para mover ficheros — Nextcloud (UI nube + WebDAV), Samba (disco de red), Syncthing (sincronización P2P) y MinIO (objetos S3) — cada una con un caso de uso claro y un perímetro de seguridad acotado. Los datos viven en `hd2t`, accesibles desde la LAN y vía Tailscale, con autenticación apropiada por plano (humanos detrás de Authelia, máquinas con tokens nativos del protocolo). La Fase 7 (`07-backups/01-estrategia-backup.md`) toma el relevo: definir cómo se respaldan estos cuatro servicios con Borgmatic, qué hooks pre/post-backup hacen falta (dumps de PostgreSQL de Nextcloud, stop/start de MinIO si aplica, modo mantenimiento de Nextcloud), y cómo se cierra el bucle 3-2-1 con el offsite mirror al que `mc-mirror-staging` apunta.

---

## Referencias

- [Documento previo: `docs/06-almacenamiento/03-syncthing.md`](./03-syncthing.md)
- [Documento relacionado: `docs/06-almacenamiento/01-nextcloud.md`](./01-nextcloud.md)
- [Documento relacionado: `docs/06-almacenamiento/02-samba.md`](./02-samba.md)
- [Documento relacionado: `docs/03-red/04-caddy.md`](../03-red/04-caddy.md)
- [Documento relacionado: `docs/04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)
- [Documento relacionado: `docs/05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md)
- [Documento relacionado: `docs/05-monitorizacion/02-grafana.md`](../05-monitorizacion/02-grafana.md)
- [Documento relacionado: `docs/02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)
- [Documento siguiente: `docs/07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md)
- [Documento siguiente: `docs/07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
- [MinIO — Documentación oficial](https://min.io/docs/minio/linux/index.html)
- [MinIO — Imagen Docker oficial (quay.io)](https://quay.io/repository/minio/minio)
- [MinIO — Releases en GitHub](https://github.com/minio/minio/releases)
- [MinIO — `mc` (cliente CLI) Documentación](https://min.io/docs/minio/linux/reference/minio-mc.html)
- [MinIO — Single-Node Single-Drive deployment](https://min.io/docs/minio/linux/operations/install-deploy-manage/deploy-minio-single-node-single-drive.html)
- [MinIO — IAM y políticas](https://min.io/docs/minio/linux/administration/identity-access-management.html)
- [MinIO — Bucket lifecycle management](https://min.io/docs/minio/linux/administration/object-management/object-lifecycle-management.html)
- [MinIO — Versioning](https://min.io/docs/minio/linux/administration/object-management/object-versioning.html)
- [MinIO — Server-Side Encryption (SSE-S3)](https://min.io/docs/minio/linux/administration/server-side-encryption.html)
- [MinIO — Métricas Prometheus](https://min.io/docs/minio/linux/operations/monitoring/collect-minio-metrics-using-prometheus.html)
- [AWS — Signature Version 4 signing process](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_aws-signing.html)
- [Caddy — `reverse_proxy` directive](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
