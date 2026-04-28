# MinIO

## Descripción

Despliegue de **MinIO** como **endpoint S3 compatible** del homelab. Donde Nextcloud ([`./01-nextcloud.md`](./01-nextcloud.md)) ofrece una nube de ficheros con UI humana, Samba ([`./02-samba.md`](./02-samba.md)) expone los discos por SMB en LAN y Syncthing ([`./03-syncthing.md`](./03-syncthing.md)) hace sync P2P, MinIO cubre un caso muy distinto y muy concreto: **hablar S3 (HTTP REST) a las apps del homelab que solo entienden S3**, no SMB ni WebDAV ni Syncthing.

Casos de uso reales del operador del homelab:

- **Backend S3 para Restic / Borgmatic con `rclone`** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)). Aunque Borgmatic prefiere repositorios Borg en disco local (`/mnt/hd2t/backups/borg/`), el plan de fase 7 contempla la posibilidad futura de añadir un **segundo Pi o un VPS pequeño** con MinIO offsite. Cuando llegue ese día, todo el tooling del homelab debe saber empujar a S3 sin reescribir nada — de ahí MinIO local *primero*, para sentar el patrón y los scripts.
- **Bucket de "external storage" para Nextcloud** y para Paperless-ngx (export S3 de archivos OCRizados). Estas apps tienen plugins S3 nativos; SMB y WebDAV son alternativas peores (latencia, locking).
- **Almacén "pegajoso" para dumps de DB y volúmenes Docker** ([`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md)). Un script `mariadb-dump | gzip | mc pipe minio/docker-volumes/<host>/<service>/<fecha>.sql.gz` es de una línea. Sin MinIO ese mismo dump exige montar samba, gestionar paths, bloquear ficheros, etc.
- **Endpoint local para experimentos** (apps nuevas, `aws s3`, `s5cmd`, herramientas de data engineering) sin pagar AWS y sin sacar datos de casa.

> **Alcance**: MinIO en este doc es **local** al mismo Pi 5 donde corre el resto del homelab, en el disco `hd2t`. Esto **no es** una solución de backup offsite real: si la Pi se incendia, los buckets se incendian con ella. La fase 7 documentará la regla 3-2-1; MinIO local cubre el "1 copia distinta del original", no el "fuera de sitio". Para offsite real, el operador deberá replicar (`mc mirror`) hacia otro proveedor S3 (AWS, Backblaze B2, Wasabi, OVH OS, otro MinIO en VPS). Esa réplica se documenta en `../07-backups/`.

El stack `minio` ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §1.1) contiene **un único contenedor**:

- **`minio`** — la imagen oficial `quay.io/minio/minio` (multi-arch, mantenida por MinIO Inc.). Corre en la **red bridge `homelab`** para que Caddy alcance la consola y la API por DNS interno (`http://minio:9001` consola, `http://minio:9000` API S3). **No publica puertos al host**: todo entra por Caddy bajo dos hostnames distintos (`minio.lan` y `s3.lan`).

Por qué exactamente esta arquitectura, y no otra:

1. **Imagen oficial `quay.io/minio/minio`, no `bitnami/minio` ni `minio/minio` de Docker Hub.** Las tres existen pero divergen:
   - **`quay.io/minio/minio`** es la ruta canónica que MinIO Inc. publica desde su CI: tags `RELEASE.YYYY-MM-DDTHH-MM-SSZ` que coinciden con cada release del proyecto, multi-arch (`linux/amd64`, `linux/arm64`, `linux/ppc64le`). Es la que recomienda la documentación oficial. Funciona en la Pi 5 sin más.
   - **`minio/minio`** (Docker Hub, mismo proyecto) es un *mirror* del anterior con los mismos tags. Da igual usar uno u otro; se elige `quay.io` por seguir la página oficial al pie de la letra y evitar cualquier rate limit eventual de Docker Hub.
   - **`bitnami/minio`** añade un wrapper de scripts y plantillas Helm que para un homelab con compose son ruido innecesario. Además Bitnami suele ir 1–2 releases por detrás del upstream y mete sus propios cambios (UID 1001 en lugar del default).
2. **Modo Single-Node Single-Drive (SNSD), no distribuido.** MinIO tiene tres topologías:
   - **SNSD** — un solo nodo, un solo disco, sin erasure coding. La que aplica aquí: una Pi, un disco hd2t, sin redundancia interna a MinIO.
   - **SNMD** — un solo nodo, múltiples discos en el mismo host, con erasure coding. Tendría sentido si la Pi tuviera, p. ej., 4×1 TB y se quisiera tolerar el fallo de uno; aquí solo hay 2 discos (`hd2t` para servicios, `hd5t` para multimedia Stash) con propósitos distintos, no es un pool homogéneo.
   - **Multi-node** — varios servidores con erasure coding distribuido. Fuera de scope para una Pi 5.
   El modo SNSD se activa con un único path (no varios) en el comando `server`. **No** trae erasure coding, así que la durabilidad la da el filesystem subyacente (ext4 en hd2t) y los backups de fase 7. Justificado en §0 y aceptado abiertamente en §10.
3. **Datos en `/mnt/hd2t/services/minio/data/`, un solo path lógico.** En SNSD el path apunta a un directorio normal donde MinIO crea internamente:
   - `<bucket>/<objeto>` — los objetos viven directamente como ficheros en disco con su nombre tal cual (no chunked, no rebanado en bloques). Esto significa que `ls /mnt/hd2t/services/minio/data/<bucket>/` lista los objetos como si fueran ficheros.
   - `.minio.sys/` — metadata de buckets, IAM, lifecycle, versionado, etc. Carpeta crítica: respaldarla **siempre** junto a los buckets.
   No se crean varios subdirectorios "drives" porque en SNSD MinIO no los necesita y simular un pool con `data/d1, data/d2, data/d3, data/d4` sobre el mismo filesystem solo aporta overhead sin ganar redundancia (un fallo de hd2t se los lleva todos a la vez).
4. **Red `homelab` (bridge), sin publicar puertos al host.** Igual patrón que Nextcloud y a diferencia de Syncthing/Samba (que sí publican):
   - Caddy llega por DNS Docker a `http://minio:9000` (API S3) y `http://minio:9001` (consola).
   - El host **no** tiene `:9000`/`:9001` en `LISTEN`. Cualquier cliente S3 (interno o externo a la Pi) entra por Caddy en `https://s3.lan` y `https://minio.lan`. Coherencia con el patrón general del homelab y un único punto de entrada con HTTPS, headers de seguridad y logs.
   - **No** se usa `network_mode: host`: ni hace falta para descubrimiento (no aplica a S3) ni es deseable.
5. **Dos hostnames, dos políticas de auth.** Decisión central de este doc:
   - **`minio.lan` → consola web (puerto 9001)** — UI humana. Va detrás de **Authelia 2FA** (snippet `authelia_proxy`). El operador hace login con TOTP y luego dentro de la consola con el `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`.
   - **`s3.lan` → API S3 (puerto 9000)** — endpoint de máquinas. **NO** lleva Authelia. Lleva la auth nativa de S3: `AWS Signature V4` con `AccessKey`/`SecretKey`. Meter Authelia delante rompería de inmediato a `mc`, `aws s3`, `restic`, `rclone`, plugins S3 de Nextcloud y Paperless, y a cualquier futuro cliente que firme requests con SigV4 — esos clientes esperan un challenge HTTP 403 con `WWW-Authenticate` específico y no saben hablar el flujo HTML/cookies de Authelia.
   La auth de S3 es robusta por diseño: cada request lleva una firma HMAC-SHA256 derivada del `SecretKey`, válida solo durante 15 minutos y ligada al método, host, path, query y body. No hay sesión, no hay cookies, no hay CSRF. Authelia delante no añade nada que esa firma no resuelva ya y sí rompe a todos los clientes.
6. **TLS terminado en Caddy con CA interna**, no TLS nativo de MinIO. MinIO puede servir HTTPS por sí mismo (`MINIO_SERVER_URL=https://...` + `MINIO_BROWSER_REDIRECT_URL=...` + montar certs en `/root/.minio/certs/`), pero hacerlo:
   - Duplica la gestión de certs (Caddy ya emite los suyos con la CA interna).
   - Obliga a confiar la CA dentro del contenedor, no solo en los clientes.
   - No aporta nada cuando Caddy ya termina TLS antes.
   La gracia es que MinIO **necesita** saber qué URL pública sirve la API (`MINIO_SERVER_URL=https://s3.lan`) y la consola (`MINIO_BROWSER_REDIRECT_URL=https://minio.lan`) **aunque** él hable HTTP plano por dentro. Sin estas dos variables, las URLs *presigned* (las que la consola y los SDKs generan para descargas temporales) salen como `http://minio:9000/...`, que solo resuelve dentro de la red Docker, y la consola redirige a `http://localhost:9001` tras el login. Documentado paso a paso en §5 y §7.
7. **Auth y secretos.** Tres capas:
   - **Operador root**: `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` en `.env`. Generados con `openssl rand -hex 24`, guardados en KeePassXC/Vaultwarden. Solo se usan para administrar (crear users, policies, buckets vía consola o `mc admin`). **NO** se usan en aplicaciones cliente.
   - **Service accounts** por aplicación cliente (uno para `borgmatic`, uno para `restic`, uno para `nextcloud-external-storage`, etc.). Cada uno con su `AccessKey`/`SecretKey` y una **policy IAM** que limita lo que puede hacer (típicamente acceso a un solo bucket). Generados con `mc admin user svcacct add` (§8.5). Justificado: si se filtra el secret de borgmatic, no puede borrar el bucket de Nextcloud.
   - **Anonymous access**: por defecto, **denegado**. Ningún bucket es público. Si alguno necesita acceso público (raro en homelab — quizás `media-thumbnails` para mostrar imágenes en una web pública vía Tailscale), se cambia con `mc anonymous set` y se documenta explícitamente.
8. **Versionado activado en `backups`, no en `docker-volumes` ni en buckets de uso intensivo.** Versionado en S3 es un *write-amplifier* (cada PUT crea una versión nueva si la key existe; un sobreescribir = dos copias hasta que pase el lifecycle). En `backups` lo queremos: protege contra borrado accidental por el operador o por bug en `borgmatic`. En `docker-volumes` no lo queremos: cada noche se sube `<service>-<fecha>.sql.gz` con clave única por fecha; versionar por encima sería redundante. Justificado en §8.6.
9. **Lifecycle policies** para expirar versiones viejas tras 90 días en `backups` y para eliminar `docker-volumes/*-<fecha>.sql.gz` con fecha > 30 días. Sin lifecycle, hd2t se llena en semanas. Configuración en §8.7.
10. **Watchtower habilitado, con caveat documentado.** MinIO publica releases muy frecuentes (varias por mes). Mayoritariamente son seguros y la imagen oficial mantiene compatibilidad de formato de metadata. Pero **algunos** releases han introducido cambios de formato que requieren no bajar de versión y leer las release notes. Política aquí: `watchtower.enable: "true"` por defecto (los uplifts son la regla, no la excepción) y se documenta la variante §14.1 para desactivarlo cuando el operador prefiera control manual.
11. **`PUID=1000`/`PGID=1000` (`homelab:homelab`).** Coherente con el resto del homelab. Los datos en `/mnt/hd2t/services/minio/data/` son del operador y deben poderse leer/copiar desde el shell del host sin `sudo`. La imagen oficial respeta `MINIO_USERNAME` y `MINIO_GROUPNAME` o, alternativamente, se sobreescribe el `user:` del compose con `1000:1000`. Se usa la segunda forma por consistencia con docs vecinos.
12. **`mc` (MinIO Client) como herramienta de operación**, no como sidecar permanente. `mc` es un binario stateless que se ejecuta on-demand para crear buckets, configurar policies, sincronizar, etc. Hay tres formas de usarlo:
    - **`docker exec minio mc ...`** — `mc` viene **dentro** de la propia imagen del servidor; el cliente y el servidor comparten binario. Útil para scripts internos al host.
    - **`docker run --rm --network=homelab minio/mc ...`** — contenedor efímero que entra en la misma red Docker y habla a `http://minio:9000`. Útil para automatizaciones desde el host sin tocar el contenedor servidor.
    - **`mc` instalado en el host como binario aparte** — overkill para el homelab; no se documenta como vía principal.
    Este doc usa una **función shell `mc()` con docker run** (§8.2) para no contaminar el host con binarios y para que cualquier mantenimiento futuro funcione independiente de la versión del servidor.
13. **Métricas Prometheus expuestas.** MinIO publica `/minio/v2/metrics/cluster` y `/minio/v2/metrics/node` por defecto en el mismo puerto 9000. La autenticación es opcional via `MINIO_PROMETHEUS_AUTH_TYPE=public` (sin token, scrapeable directo). Como Prometheus vive en `homelab` y llega a `http://minio:9000/minio/v2/metrics/cluster`, no hace falta autenticación. Configuración en §11.6.
14. **No exposición a internet.** El homelab no tiene puertos abiertos en el router. La API S3 solo es accesible desde:
    - Clientes en LAN (`https://s3.lan` resuelto por Pi-hole a `192.168.1.10`).
    - Clientes en Tailscale (variante §14.4 con `s3.tailnet.ts.net`).
    Esto es importante: muchos *howtos* de MinIO en internet asumen que el endpoint es público y se preocupan por TLS público, mfa, anti-DDoS, etc. Aquí nada de eso aplica.

> **Alcance de red**: MinIO no publica puertos al host. Acceso via `https://minio.lan` (consola, Authelia 2FA) y `https://s3.lan` (API S3, AWS SigV4). Ambos en la subred LAN `192.168.1.0/24`. Sin DDNS, sin Let's Encrypt, sin port-forward.

---

## Requisitos Previos

- **Docker Engine + Compose v2** instalados según [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md), con la red `homelab` creada según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4 (`172.20.0.0/24`, bridge `br-homelab`, `external: true`).
- **Estructura de directorios** aplicada según [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md):
  - `/mnt/hd2t/services/` ya creado, propietario `homelab:homelab`, modo `750`.
  - Usuario `homelab` (UID 1000) y grupo `homelab` (GID 1000) operativos.
- **Disco `hd2t` con espacio razonable** (≥ 50 GB libres recomendados de partida; los buckets de backup pueden crecer rápido). Monitorizado por Node Exporter + Grafana ([`../05-monitorizacion/`](../05-monitorizacion/)).
- **Caddy desplegado** según [`../03-red/04-caddy.md`](../03-red/04-caddy.md) con los snippets `lan_internal_tls`, `tailscale_tls` y `security_headers` ya disponibles. La CA interna está confiada al menos en un cliente para poder probar la consola.
- **Authelia desplegado** según [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) con el snippet `authelia_proxy` y al menos un usuario con 2FA habilitado. Solo se aplica a `minio.lan`.
- **Pi-hole desplegado** según [`../03-red/02-pihole.md`](../03-red/02-pihole.md), con DNS local activo. Se añadirán **dos** records: `minio.lan → 192.168.1.10` y `s3.lan → 192.168.1.10`.
- **Tailscale operativo** según [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) (opcional, solo para variante §14.4).
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §4. **No** se añaden reglas nuevas: MinIO no publica puertos al host, todo entra por los `:443` que ya gestiona Caddy.
- **Comprobaciones rápidas**:
  ```bash
  # Red Docker compartida ya existe.
  docker network inspect homelab \
    --format '{{(index .IPAM.Config 0).Subnet}}'
  # Esperado: 172.20.0.0/24

  # Caddy y Authelia están sanos.
  docker inspect caddy authelia --format '{{.Name}}: {{.State.Health.Status}}'
  # Esperado: ambos healthy.

  # Pi-hole resuelve los dos hostnames al host (preparar antes en su UI).
  dig +short @192.168.1.241 minio.lan
  dig +short @192.168.1.241 s3.lan
  # Esperado (ambos): 192.168.1.10

  # Puertos 9000 y 9001 libres en el host (no se publican, pero confirmamos
  # que no hay otro MinIO escapado).
  sudo ss -lntu '( sport = :9000 or sport = :9001 )'
  # Esperado: vacío.

  # Espacio libre en hd2t.
  df -h /mnt/hd2t | tail -1
  # Esperado: > 50 GB libres.

  # Reloj sincronizado (S3 SigV4 rechaza requests con clock skew > 15 min).
  timedatectl | grep 'System clock synchronized'
  # Esperado: System clock synchronized: yes
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Imagen Docker | **`quay.io/minio/minio`** (oficial upstream) | Multi-arch (`linux/arm64`), publicada por MinIO Inc. el mismo día que las releases del proyecto. Justificado en §0 punto 1. |
| Tag de imagen | **Pinned a release puntual** (p. ej. `RELEASE.2025-04-22T22-12-26Z`), nunca `latest` ni `edge` | Misma regla de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1. Watchtower bumpea cuando hay nueva release siguiendo el pin del tag (y se desactiva en §14.1 si el operador prefiere upgrades manuales). |
| Topología | **SNSD** (single-node, single-drive, sin erasure coding) | Justificado en §0 punto 2. La durabilidad la da ext4 + Borg backups, no MinIO. |
| Path de datos | **Un solo bind mount** `/mnt/hd2t/services/minio/data/` → `/data` | Justificado en §0 punto 3. No se simulan "drives" lógicos (no aporta nada en SNSD). |
| Path de config | **`/mnt/hd2t/services/minio/config/`** → `/root/.minio/` (vacío al inicio; MinIO escribe certs si TLS nativo se activase) | Persistir el directorio de config aunque no haya certs en TLS-en-Caddy reduce sorpresas si en el futuro se activa TLS nativo. |
| Modo de red | **`networks: [homelab]`** (bridge compartida) | Caddy llega por DNS Docker. No se publica nada al host. |
| Subred Docker | Heredada de la red `homelab` (`172.20.0.0/24`) | El contenedor recibe IP del pool. No relevante (todo se accede por nombre). |
| Puertos publicados al host | **Ninguno** | Todo el tráfico entra por Caddy. La API S3 no necesita un `127.0.0.1:9000` para test rápido — `docker exec` o el contenedor `mc` cubren ese caso. |
| Hostnames públicos | **`minio.lan`** (consola, Authelia 2FA) y **`s3.lan`** (API S3, sin Authelia) | Justificado en §0 punto 5. Dos bloques separados en `Caddyfile`, dos políticas distintas en Authelia. |
| `MINIO_SERVER_URL` | **`https://s3.${LAN_DOMAIN}`** | Necesario para que la consola y los SDKs generen URLs presigned correctas. Sin esto las descargas firmadas apuntan a `http://minio:9000` y fallan fuera de la red Docker. |
| `MINIO_BROWSER_REDIRECT_URL` | **`https://minio.${LAN_DOMAIN}`** | Necesario para que tras el login la consola redirija al hostname público y no a `http://localhost:9001`. |
| Autenticación raíz | **`MINIO_ROOT_USER` + `MINIO_ROOT_PASSWORD`** en `.env` | Generados con `openssl rand -hex 24`. Solo para administración. Las apps cliente usan service accounts (§8.5). |
| Service accounts | **Uno por aplicación cliente** (borgmatic, restic, nextcloud, paperless, ...) con policy IAM scoped a su bucket | Justificado en §0 punto 7. Filtrar uno no compromete los demás. |
| Buckets iniciales | **`backups`** (versionado), **`docker-volumes`** (sin versionado), **`media-thumbnails`** (sin versionado, opt-in) | Justificado en §0 puntos 8–9 y detallado en §8.4. |
| Versioning | **Activo en `backups`**, desactivado en el resto | Trade-off coste/protección, justificado en §0 punto 8. |
| Lifecycle policy | `backups`: expirar versiones no-actuales tras 90 días. `docker-volumes`: expirar objetos tras 30 días. | Justificado en §0 punto 9. Sin lifecycle, hd2t se llena. |
| Encryption-at-rest | **No** (SSE-S3 con KMS desactivado). Sí en variante §14.5 si el operador lo necesita. | El cifrado del filesystem (LUKS sobre hd2t) sería más adecuado y se considerará en `../01-sistema/`. SSE de MinIO requiere KMS adicional (Vault o KES) — overkill para homelab. |
| Política de Watchtower | **`watchtower.enable: "true"`** | Justificado en §0 punto 10. Variante §14.1 para desactivar. |
| Usuario dentro del contenedor | **`user: "1000:1000"`** (`homelab:homelab`) | Justificado en §0 punto 11. Coherencia con todo el homelab. |
| Healthcheck | **`curl -f http://127.0.0.1:9000/minio/health/live`** | Endpoint canónico de MinIO. Devuelve 200 si el demonio está vivo (sin verificar replicas, irrelevante en SNSD). La imagen oficial trae `curl`. |
| `cap_drop: ALL` + `cap_add` | **`cap_add: []`** (vacío) | MinIO corre como UID 1000 y escucha en puertos altos (9000, 9001): no necesita capabilities. |
| `security_opt: no-new-privileges:true` | **Activado** | Plantilla §6 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). |
| `read_only: true` | **`false`** | MinIO escribe metadata en `/data/.minio.sys/` constantemente. Forzar RO obligaría a tmpfs y rompe el modo SNSD. La defensa real es el bind mount con UID/GID `homelab` y `750`. |
| Logs Docker | Heredados del demonio (`json-file` 10 MB × 3) | El log "rico" de MinIO va a stdout en formato estructurado JSON con `MINIO_LOG_QUERY_AUTH_TOKEN` opcional para una API de consulta. Por defecto basta con `docker logs`. |
| Métricas Prometheus | **`/minio/v2/metrics/cluster`** (público) | Justificado en §0 punto 13. Scrape job en `prometheus.yml` se añade en §11.6. |
| Notificaciones de eventos | **No activadas** | MinIO puede enviar `s3:ObjectCreated:*` etc. a webhooks/Kafka/AMQP. Se documenta como variante opt-in en §14.6. |
| Acceso desde Tailscale | **Opt-in** | Variante §14.4 (`s3.tailnet.ts.net` y `minio.tailnet.ts.net`). Por defecto solo LAN. |
| Backup del propio MinIO | **Bind mounts respaldados por Borg** + opción de `mc mirror` a otro endpoint S3 | Detallado en §10. La frase clave: MinIO **local** no es backup offsite; serviría como peer de réplica a otro MinIO/S3 remoto cuando exista. |

---

## 1. Resumen de la arquitectura

```
                ┌──────────────── LAN 192.168.1.0/24 ────────────────┐
                │                                                     │
   Operador  ───┤  HTTPS 443 → minio.lan (consola, Authelia 2FA)     │
   Borgmatic ───┤  HTTPS 443 → s3.lan    (API S3, AWS SigV4)         │
   Restic    ───┤  HTTPS 443 → s3.lan                                │
   Nextcloud ───┤  HTTPS 443 → s3.lan    (external storage S3)       │
                │                                                     │
                │       eth0 192.168.1.10 (Pi 5)                     │
                └──────────────────────┬──────────────────────────────┘
                                       │
                                       ▼
       ┌────────── docker network homelab (172.20.0.0/24) ──────────┐
       │                                                              │
       │  caddy ─── 443 ──┬──→ http://minio:9001  (consola)          │
       │                  │       └─ forward_auth → authelia (2FA)    │
       │                  │                                           │
       │                  └──→ http://minio:9000  (API S3)            │
       │                          └─ AWS SigV4 (sin Authelia)         │
       │                                                              │
       │  prometheus ────→ http://minio:9000/minio/v2/metrics/cluster │
       │                                                              │
       │  minio (PUID=1000)                                           │
       │   ├── :9000  API S3  (no publicado al host)                 │
       │   ├── :9001  consola (no publicado al host)                 │
       │   ├── /data  ← /mnt/hd2t/services/minio/data/                │
       │   │     ├── backups/             (bucket, versioning ON)    │
       │   │     ├── docker-volumes/      (bucket, versioning OFF)   │
       │   │     ├── media-thumbnails/    (opt-in)                   │
       │   │     └── .minio.sys/          (metadata)                  │
       │   └── /root/.minio ← /mnt/hd2t/services/minio/config/        │
       │                                                              │
       └──────────────────────────────────────────────────────────────┘
```

Flujo de una operación S3 (caso "borgmatic sube un fichero a `backups`"):

```
1. borgmatic (en el mismo Pi, dentro de la red homelab, o desde otra Pi
   en LAN) construye una request HTTPS:

     PUT /backups/2025-11-08/host01-mariadb.tar.gz HTTP/1.1
     Host: s3.lan
     Authorization: AWS4-HMAC-SHA256 Credential=AKIA.../20251108/...
     X-Amz-Date: 20251108T032500Z
     ...

2. Caddy (LAN 443) recibe la petición sobre HTTPS (cert de la CA interna).
3. El bloque `s3.lan` del Caddyfile NO importa authelia_proxy: pasa directo
   al backend.
4. `reverse_proxy http://minio:9000` reenvía el body íntegro y los headers
   originales (incluido Authorization con la firma SigV4).
5. MinIO valida la firma contra el SecretKey de la service account
   `borgmatic`, comprueba que la policy IAM le permite `s3:PutObject` sobre
   `backups/*`, y escribe el objeto en
   /data/backups/2025-11-08/host01-mariadb.tar.gz como UID 1000.
6. MinIO devuelve 200 OK con ETag (MD5 del objeto). Caddy reenvía la
   respuesta tal cual al cliente.
7. Si el bucket tiene versioning activo (lo tiene en `backups`), MinIO
   guarda también una version-id en .minio.sys/buckets/backups/...
```

Flujo de la consola (caso "operador entra a inspeccionar buckets"):

```
1. Navegador → https://minio.lan
2. Caddy: forward_auth → Authelia → cookie de sesión Authelia válida?
   - No: redirige a https://auth.lan, login + TOTP, vuelta.
   - Sí: pasa.
3. reverse_proxy http://minio:9001 → consola MinIO sirve la app React.
4. Login de consola: el operador introduce MINIO_ROOT_USER y
   MINIO_ROOT_PASSWORD (anotados en KeePass). MinIO emite token JWT
   propio (cookie).
5. Las llamadas internas de la consola van contra /api/v1/... a través
   del mismo proxy. Authelia las deja pasar todas (la cookie de sesión
   sigue siendo válida durante la duración configurada).
```

---

## 2. Plan de variables y archivos

El stack `minio` es nuevo. Layout que se va a crear:

```
~/homelab/stacks/minio/                          # versionado en git
├── docker-compose.yml
└── .env.example

/mnt/hd2t/services/minio/                        # NO versionado
├── .env                                         # credenciales root, dominios, tag
├── config/                                      # → /root/.minio
│   └── (vacío al inicio; se rellena si TLS nativo se activa)
└── data/                                        # → /data
    ├── backups/                                 # bucket
    ├── docker-volumes/                          # bucket
    ├── media-thumbnails/                        # bucket (opt-in §8.4.4)
    └── .minio.sys/                              # metadata, IAM, lifecycle
        ├── buckets/
        │   ├── backups/
        │   ├── docker-volumes/
        │   └── ...
        ├── config/
        ├── format.json                          # versión del formato del backend
        └── ...
```

> **Por qué `config/` aparte de `data/`**: en SNSD la metadata vive en `data/.minio.sys/`, no en `config/`. El bind mount `config/` está casi vacío en este modo, pero existe por dos razones: (a) si se activa TLS nativo (variante §14.5), MinIO espera certs en `/root/.minio/certs/`, (b) `mc admin config` permite exportar/importar configuración a ese path; tener el bind mount listo evita rehacer el compose el día que se necesite.

### 2.1. `.env.example` (`~/homelab/stacks/minio/.env.example`)

```bash
# ~/homelab/stacks/minio/.env.example
# Copiar a /mnt/hd2t/services/minio/.env y rellenar.

# Usuario y zona horaria.
PUID=1000
PGID=1000
TZ=Europe/Madrid

# Dominios (resueltos por Pi-hole en LAN; tailnet.ts.net opcional).
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Imagen ---
# https://quay.io/repository/minio/minio?tab=tags
# Pin estable; revisar release notes en https://github.com/minio/minio/releases
# antes de bumpear.
MINIO_IMAGE_TAG=RELEASE.2025-04-22T22-12-26Z

# --- Credenciales root ---
# Generar con: openssl rand -hex 24
# El usuario root SOLO se usa para administración (consola y mc admin).
# Las apps cliente usan service accounts creadas en §8.5.
MINIO_ROOT_USER=
MINIO_ROOT_PASSWORD=

# --- URLs públicas (terminadas por Caddy con la CA interna) ---
# La consola redirige tras login a esta URL:
MINIO_BROWSER_REDIRECT_URL=https://minio.lan
# La API S3 emite URLs presigned con este origen:
MINIO_SERVER_URL=https://s3.lan

# --- Métricas Prometheus ---
# 'public' = el endpoint /minio/v2/metrics/cluster es accesible sin token,
# scrapeable directo por Prometheus en la red homelab.
# 'jwt' = requiere token JWT (más seguro pero requiere configurar el token
# en prometheus.yml). 'public' es aceptable porque el endpoint no se expone
# fuera de la red Docker.
MINIO_PROMETHEUS_AUTH_TYPE=public
```

### 2.2. `.env` real (`/mnt/hd2t/services/minio/.env`)

```bash
# Crear el .env con permisos correctos.
sudo install -m 600 -o homelab -g homelab /dev/null /mnt/hd2t/services/minio/.env

# Generar credenciales root y volcarlas al .env.
ROOT_USER="homelab-admin"
ROOT_PASS=$(openssl rand -hex 24)

cat | sudo tee /mnt/hd2t/services/minio/.env >/dev/null <<EOF
PUID=1000
PGID=1000
TZ=Europe/Madrid

LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

MINIO_IMAGE_TAG=RELEASE.2025-04-22T22-12-26Z

MINIO_ROOT_USER=${ROOT_USER}
MINIO_ROOT_PASSWORD=${ROOT_PASS}

MINIO_BROWSER_REDIRECT_URL=https://minio.lan
MINIO_SERVER_URL=https://s3.lan

MINIO_PROMETHEUS_AUTH_TYPE=public
EOF

# Anotar ROOT_USER y ROOT_PASS en KeePassXC / Vaultwarden ANTES de seguir.
echo "MinIO root user:     ${ROOT_USER}"
echo "MinIO root password: ${ROOT_PASS}"

# Limpiar variables del shell.
unset ROOT_USER ROOT_PASS
history -d $((HISTCMD-2)) 2>/dev/null || true

ls -l /mnt/hd2t/services/minio/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

> **`MINIO_ROOT_USER` debe tener al menos 3 caracteres** y solo `[a-zA-Z0-9-]`. **`MINIO_ROOT_PASSWORD`** al menos 8 caracteres; en este doc se usa `openssl rand -hex 24` → 48 caracteres hex. Si MinIO arranca y rechaza las credenciales por longitud insuficiente, devuelve error claro en el log.

### 2.3. Cómo se inyectan los secretos

| Secreto | Fichero en host | Variable / fichero en contenedor |
|---|---|---|
| Root user / password | `/mnt/hd2t/services/minio/.env` (`MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`) | Variables de entorno del proceso `minio server`. Persistidas en `/data/.minio.sys/config/...` tras el primer arranque. |
| Service accounts | (no se almacenan en `.env`) | `/data/.minio.sys/config/iam/users/<accessKey>/identity.json` |
| Policies IAM | (no se almacenan en `.env`) | `/data/.minio.sys/config/iam/policies/<name>/policy.json` |
| Cert TLS (no aplica por defecto) | (no se generan; Caddy hace TLS) | `/root/.minio/certs/public.crt`, `private.key` (solo en variante §14.5) |

> **Diferencia frente a Nextcloud / Authelia**: aquellos usaban `*_FILE` para inyectar passwords desde ficheros montados con `secrets:`. MinIO **no** soporta el patrón `*_FILE` para `MINIO_ROOT_PASSWORD` (sí para algunas otras vars de configuración). La práctica oficial es env var directa. El `.env` con `0600` es la barrera de protección.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack (versionable)

```bash
mkdir -p ~/homelab/stacks/minio
```

### 3.2. Crear el árbol de datos persistentes (no versionable)

```bash
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/minio
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/minio/config
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/minio/data
```

### 3.3. Comprobar permisos heredados

```bash
ls -lda /mnt/hd2t/services/minio /mnt/hd2t/services/minio/{config,data}
# Esperado, todas las líneas:
#   drwxr-x--- 2 homelab homelab ... /mnt/hd2t/services/minio[/...]
```

> **Ojo con `750` y UID 1000 dentro del contenedor**: MinIO arranca con `user: "1000:1000"` (configurado en §5). El UID 1000 del contenedor coincide con `homelab` del host (por la convención de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)). Sin esa coincidencia, MinIO obtendría `EACCES` al intentar crear `.minio.sys/`. La validación se hace en §6.2 inspeccionando los logs.

### 3.4. Confirmar el filesystem subyacente

```bash
mount | grep '/mnt/hd2t '
# Esperado: /dev/sda1 on /mnt/hd2t type ext4 (rw,relatime,...)

stat -f /mnt/hd2t | head -5
# Esperado: "Type: ext2/ext3" (ext4 figura como ext2/ext3 en stat -f).
```

> **MinIO requiere un filesystem POSIX con `xattr` operativo** para metadata extendida (multipart uploads, replicación). ext4 los soporta de serie. **No** se recomienda exFAT, NTFS ni filesystems en red (NFS, CIFS) como backend de MinIO: la metadata extendida o no funciona o bloquea. hd2t es ext4 nativo (USB → ext4), correcto.

---

## 4. Pre-generar credenciales root

Ya hecho en §2.2. Verificar:

```bash
sudo grep -E '^MINIO_ROOT_(USER|PASSWORD)=' /mnt/hd2t/services/minio/.env \
  | sed 's/PASSWORD=.*/PASSWORD=<oculto>/'
# Esperado:
#   MINIO_ROOT_USER=homelab-admin
#   MINIO_ROOT_PASSWORD=<oculto>
```

> **Rotación**: cambiar `MINIO_ROOT_PASSWORD` requiere reiniciar el contenedor. MinIO no acepta hot-reload de credenciales root. Documentado en §11.5.

---

## 5. `docker-compose.yml`

`~/homelab/stacks/minio/docker-compose.yml`:

```yaml
# ~/homelab/stacks/minio/docker-compose.yml
# Stack: minio (../02-docker/02-estructura-compose.md §1.1).
# Datos persistentes en /mnt/hd2t/services/minio/.
# Modo Single-Node Single-Drive (SNSD): 1 proceso, 1 path /data, sin EC.

name: minio

services:
  minio:
    image: quay.io/minio/minio:${MINIO_IMAGE_TAG}
    container_name: minio
    hostname: minio
    restart: unless-stopped

    # Comando explícito para SNSD: server <path> + dirección de la consola.
    # --console-address fija el puerto separado (9001) para la consola web.
    # --address fija el puerto de la API S3 (9000).
    command:
      - server
      - /data
      - --address
      - ":9000"
      - --console-address
      - ":9001"

    # Corre como UID 1000 = homelab del host. Sin esto, MinIO escribe
    # /data/.minio.sys con UID raíz del contenedor y el operador no puede
    # leerlo desde el shell sin sudo.
    user: "1000:1000"

    env_file:
      - /mnt/hd2t/services/minio/.env
    environment:
      # Re-exportadas explícitamente para que docker compose las ponga en el
      # entorno del proceso aunque el .env cambie de formato en el futuro.
      TZ: ${TZ}
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
      # URLs públicas: críticas para que las URLs presigned y los redirects
      # de la consola apunten a los hostnames detrás de Caddy y NO a
      # http://minio:9000 / http://localhost:9001 (ver §0 punto 6).
      MINIO_BROWSER_REDIRECT_URL: ${MINIO_BROWSER_REDIRECT_URL}
      MINIO_SERVER_URL: ${MINIO_SERVER_URL}
      # Métricas Prometheus accesibles sin token (red interna, ver §0 p.13).
      MINIO_PROMETHEUS_AUTH_TYPE: ${MINIO_PROMETHEUS_AUTH_TYPE}
      # Deshabilitar el self-update del binario MinIO: en Docker los
      # upgrades los hace Watchtower vía pull de la imagen.
      MINIO_UPDATE: "off"
      # Endurecer: desactivar el "Update" banner de la consola.
      MINIO_BROWSER_LOGIN_ANIMATION: "off"

    volumes:
      # Datos: buckets + .minio.sys/
      - type: bind
        source: /mnt/hd2t/services/minio/data
        target: /data
        bind:
          create_host_path: false

      # Config (vacío al inicio en SNSD; reservado para certs y exports).
      - type: bind
        source: /mnt/hd2t/services/minio/config
        target: /root/.minio
        bind:
          create_host_path: false

    # NO se publica nada al host: la API S3 y la consola entran por Caddy.
    # ports: []

    networks:
      - homelab               # Caddy y Prometheus llegan por DNS interno.

    cap_drop:
      - ALL

    security_opt:
      - no-new-privileges:true

    # MinIO trae curl en la imagen oficial.
    healthcheck:
      test:
        - CMD
        - curl
        - -fsS
        - http://127.0.0.1:9000/minio/health/live
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

    labels:
      com.centurylinklabs.watchtower.enable: "true"
      homepage.group: "Almacenamiento"
      homepage.name: "MinIO"
      homepage.icon: "minio.png"
      homepage.href: "https://minio.${LAN_DOMAIN}"
      homepage.description: "Endpoint S3 compatible"
      homepage.widget.type: "minio"
      homepage.widget.url: "http://minio:9000"
      homepage.widget.key: "${MINIO_ROOT_USER}"
      homepage.widget.secret: "${MINIO_ROOT_PASSWORD}"

networks:
  homelab:
    external: true
```

### 5.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `image: quay.io/minio/minio:${MINIO_IMAGE_TAG}` | Imagen oficial upstream (§0 punto 1). Tag fijo `RELEASE.YYYY-MM-DDTHH-MM-SSZ`. Watchtower bumpea cuando hay nueva (revisar release notes). |
| `command: [server, /data, --address, :9000, --console-address, :9001]` | Forma canónica de arrancar MinIO en SNSD. El path `/data` se mapea por bind mount a `/mnt/hd2t/services/minio/data/`. **Crítico**: `--address :9000` separa explícitamente la API S3 del puerto de la consola, requisito para los dos hostnames distintos en Caddy (§7). |
| `user: "1000:1000"` | Justificado en §0 punto 11. Coincide con `homelab` en el host. La imagen oficial corre como root por defecto y droppea privilegios al usuario configurado. |
| `env_file` | Carga `.env` con la ruta absoluta (regla del homelab: `.env` vive en `/mnt/hd2t/services/<stack>/.env`, no junto al `docker-compose.yml`). |
| `MINIO_BROWSER_REDIRECT_URL` | Sin esto, tras el login en la consola, MinIO redirige a `http://localhost:9001/browser` que no resuelve fuera del propio contenedor. Con esto, redirige a `https://minio.lan/browser` y todo funciona detrás de Caddy. |
| `MINIO_SERVER_URL` | Sin esto, las URLs *presigned* (`mc share download`, downloads de la consola con TTL, integraciones tipo Nextcloud "external storage" que usan presigned URLs) apuntan a `http://minio:9000/...` y solo resuelven dentro de la red Docker. Con esto, apuntan a `https://s3.lan/...` y funcionan desde cualquier cliente en LAN. |
| `MINIO_UPDATE: "off"` | MinIO trae un mecanismo de auto-update del binario (`mc admin update`) — útil en bare-metal, irrelevante en Docker, donde el upgrade lo gestiona Watchtower con un pull de imagen. Desactivarlo evita que el contenedor descargue binarios extra al inicio. |
| `MINIO_PROMETHEUS_AUTH_TYPE: public` | Justificado en §0 punto 13. La red Docker `homelab` ya es la frontera de aislamiento; obligar a un JWT extra para que Prometheus scrapee es ceremonia sin valor. |
| `volumes` (bind `/data`) | Datos. **No** named volume: bind explícito para tener `/mnt/hd2t/services/minio/data/` accesible desde el host (backup directo con Borg, inspección, restore granular). |
| `volumes` (bind `/root/.minio`) | Config persistente (vacía hoy, útil mañana — variante §14.5 con TLS nativo). |
| `ports: []` (omitido) | Justificado en §0 punto 4 y §1. Sin `ports:`, Docker no abre nada en `eth0`; solo Caddy alcanza el contenedor por DNS interno. |
| `networks: [homelab]` | Caddy llega por nombre (`http://minio:9000`, `http://minio:9001`). Prometheus también para scrape de métricas. No hay BD ni cache propias del stack → no se crea `minio_internal`. |
| `cap_drop: ALL` (sin `cap_add`) | MinIO corre como UID 1000 y usa puertos altos: no necesita capabilities. |
| `healthcheck: curl -fsS .../minio/health/live` | Endpoint canónico. Devuelve 200 si el demonio acepta requests; ignora el estado de buckets individuales (irrelevante en SNSD). |
| `start_period: 30s` | MinIO tarda ~5–15 s en abrir/validar `.minio.sys` la primera vez (más con buckets grandes y versioning activo). 30 s es holgura. |
| `labels: homepage.widget.minio` | Integración con el dashboard Homepage ([`../12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md)). El widget `minio` muestra número de buckets y uso de disco. **Caveat**: usa el `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` para hablar la API admin; si se rota, actualizar el `.env`. Para mayor higiene, crear una service account `homepage-readonly` y poner sus credenciales aquí (variante §14.7). |

### 5.2. Por qué `MINIO_BROWSER_REDIRECT_URL` y `MINIO_SERVER_URL` son obligatorias (no "nice to have")

Reproducción del fallo si **se omiten**:

```text
Sin MINIO_BROWSER_REDIRECT_URL:
  - Operador entra a https://minio.lan
  - Authelia + login MinIO OK.
  - Tras login MinIO emite Location: http://localhost:9001/browser
  - El navegador del operador NO tiene MinIO en localhost → ERR_CONNECTION_REFUSED.

Sin MINIO_SERVER_URL:
  - mc share download minio/backups/foo.tar.gz
  - Devuelve URL: http://minio:9000/backups/foo.tar.gz?X-Amz-...
  - "minio" solo resuelve en la red docker; copia/pega esa URL en otro
    cliente en LAN → DNS error.
```

Por eso el `docker-compose.yml` las marca explícitamente y el `.env.example` las incluye como obligatorias. La consola de MinIO **detecta** que está detrás de un proxy y, si las variables faltan, muestra un warning en la sección "Settings → Configuration" advirtiendo del problema.

### 5.3. Validar antes de levantar

```bash
cd ~/homelab/stacks/minio
docker compose --env-file /mnt/hd2t/services/minio/.env config >/dev/null \
  && echo "Compose OK"
```

Errores típicos:

- `service "minio" refers to undefined network homelab` → la red compartida no existe. Crear con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2.
- `bind source path does not exist: /mnt/hd2t/services/minio/data` → no se ejecutaron los `install -d` de §3.2.
- `MINIO_ROOT_USER must be at least 3 characters` (en logs al arrancar): `.env` no se rellenó (§2.2).
- `Specified server URL ... is not valid`: `MINIO_SERVER_URL` debe ser HTTPS válido (`https://s3.lan`), no llevar trailing slash, no contener path. Igual con `MINIO_BROWSER_REDIRECT_URL`.

---

## 6. Despliegue

### 6.1. Primer arranque

```bash
cd ~/homelab/stacks/minio
docker compose --env-file /mnt/hd2t/services/minio/.env up -d
```

Salida esperada:

```
[+] Running 1/1
 ✔ Container minio    Started
```

### 6.2. Estado del contenedor

```bash
docker compose --env-file /mnt/hd2t/services/minio/.env ps
# Esperado, tras ~30 s:
# NAME    IMAGE                                            STATUS              PORTS
# minio   quay.io/minio/minio:RELEASE.2025-04-22T22-12...  Up X (healthy)      9000/tcp, 9001/tcp
```

> Los puertos `9000/tcp` y `9001/tcp` aparecen como **expuestos** dentro de la red Docker pero **no publicados** al host (sin el `0.0.0.0:...->...` que sí sale en, p. ej., Syncthing).

Confirmar logs limpios:

```bash
docker logs minio | head -40
```

Eventos esperados al primer arranque:

```
INFO: MinIO Object Storage Server
INFO: Copyright: ...
INFO: License: ...
INFO: Version: RELEASE.2025-04-22T22-12-26Z (...)
INFO: API: http://172.20.0.X:9000  http://127.0.0.1:9000
INFO: WebUI: http://172.20.0.X:9001 http://127.0.0.1:9001
INFO: Docs: https://docs.min.io
```

> **Importante: NO debe aparecer** `WARNING: Detected default credentials 'minioadmin:minioadmin' ...`. Si aparece, las env vars `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` no se leyeron — revisar `.env`.

### 6.3. Confirmar que NO hay puertos en el host

```bash
sudo ss -lntu '( sport = :9000 or sport = :9001 )'
# Esperado: VACÍO. Ningún proceso escuchando en :9000 ni :9001 del host.
```

Si aparece algo: revisar que el `docker-compose.yml` **no** tenga `ports: ["9000:9000", "9001:9001"]`. Si los publica un contenedor MinIO antiguo, `docker compose down` antes de relanzar.

### 6.4. Confirmar accesibilidad interna desde Caddy

```bash
docker exec caddy wget -qO- http://minio:9000/minio/health/live && echo "  API live"
docker exec caddy wget -qO- http://minio:9001/login && echo "  consola alcanzable"
# Esperado:
#   (vacío)   API live
#   (HTML largo de la página de login)   consola alcanzable
```

Si falla con `wget: bad address 'minio'`: ambos contenedores deben estar en `homelab`. Verificar con:

```bash
docker network inspect homelab \
  --format '{{range $k, $v := .Containers}}{{println $v.Name}}{{end}}'
# Esperado: contiene "minio" y "caddy".
```

### 6.5. Confirmar que MinIO escribió la metadata

```bash
sudo ls -la /mnt/hd2t/services/minio/data
# Esperado:
#   drwxr-x---  3 homelab homelab .
#   drwxr-x---  4 homelab homelab ..
#   drwxr-xr-x  N homelab homelab .minio.sys

sudo ls /mnt/hd2t/services/minio/data/.minio.sys
# Esperado: buckets/ config/ format.json (al menos)

sudo stat -c '%U:%G %a' /mnt/hd2t/services/minio/data/.minio.sys/format.json
# Esperado: homelab:homelab 644
```

> Si el dueño es `root:root` o un UID extraño en lugar de `homelab:homelab`, el `user: "1000:1000"` no se aplicó. Revisar el compose (§5).

---

## 7. Integración con Caddy (dual hostname)

Esta es la pieza distintiva de MinIO frente al resto de docs vecinos: **dos bloques** en el `Caddyfile`, uno con Authelia y otro sin.

### 7.1. Bloques en el `Caddyfile`

Editar `~/homelab/stacks/proxy/Caddyfile` y añadir, en la sección de bloques de host:

```caddy
# MinIO consola (UI humana) — Authelia 2FA delante.
# Doc: ../06-almacenamiento/04-minio.md §7
minio.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    import authelia_proxy

    # La consola de MinIO sirve un frontend React + websockets para el
    # streaming de eventos. Caddy maneja websockets transparentemente con
    # `reverse_proxy`; no hace falta declararlos.
    reverse_proxy http://minio:9001 {
        # MinIO comprueba el header Host para emitir redirects coherentes.
        header_up Host {host}
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
    }
}

# MinIO API S3 (clientes máquina) — SIN Authelia. Auth por AWS SigV4.
# Doc: ../06-almacenamiento/04-minio.md §7
s3.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Subidas grandes: por defecto Caddy no limita el body, pero algunas
    # reverse-proxy intermedias suben el límite a 10 MB. MinIO multipart
    # uploads parten en 5 MiB chunks, así que 10 MB sobra para cada chunk.
    # Si se sube un objeto NO multipart > 5 GiB, el cliente debe partirlo
    # él mismo. Aceptable: mc, restic, borgmatic y rclone hacen multipart
    # automático.
    request_body {
        max_size 10GB
    }

    reverse_proxy http://minio:9000 {
        # Críticos: la firma SigV4 v4 incluye el Host original. Si Caddy
        # reescribe el Host a `minio:9000`, la firma no valida y MinIO
        # devuelve 403 SignatureDoesNotMatch para CADA request.
        header_up Host {host}
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}

        # Ajuste de timeouts: subidas de varios GB pueden tardar minutos.
        # Defaults de Caddy (no timeout) son OK, se declaran explícitos
        # por documentación.
        transport http {
            # Sin keepalive entre Caddy y MinIO si el cliente cierra: evita
            # objetos parcialmente subidos por reuses fallidos.
            keepalive 30s
            response_header_timeout 0
            read_timeout 0
            write_timeout 0
        }
    }
}
```

> **Por qué `s3.lan` NO tiene `import authelia_proxy`**: justificado en §0 punto 5. Authelia no entiende AWS SigV4; intercalarla rompería todos los clientes S3.

> **Por qué `header_up Host {host}` es OBLIGATORIO en `s3.lan`**: SigV4 firma el header `Host` original. Caddy por defecto **no** reescribe el Host (lo pasa tal cual), pero declarar `header_up Host {host}` lo blindae si en el futuro se cambian defaults. Sin esto, una mínima discrepancia de Host (p. ej. `s3.lan:443` vs `s3.lan`) hace que MinIO rechace la firma con `SignatureDoesNotMatch`. Es el bug #1 que reporta la gente al poner MinIO detrás de un proxy.

> **`request_body { max_size 10GB }`**: MinIO valida internamente el tamaño máximo según su config (`MINIO_API_REQUESTS_MAX`, default 5 TiB). El límite que cuenta en este endpoint es el de Caddy. 10 GB cubre objetos grandes no multipart. Si se desea elevarlo (p. ej. dump de 200 GB en un solo PUT no multipart, raro), subirlo aquí. Lo normal es multipart, en cuyo caso cada chunk pesa decenas de MB, no GB.

Recargar Caddy sin downtime:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

### 7.2. Confirmar la regla en Authelia

Editar `~/homelab/stacks/auth/configuration.yml` y, en `access_control.rules`, añadir SOLO el dominio `minio.lan` con `policy: two_factor`. **NO** se añade `s3.lan`: ese hostname no pasa por Authelia (no hay `forward_auth` en su bloque del `Caddyfile`).

```yaml
access_control:
  default_policy: deny
  rules:
    # ... reglas previas (auth.lan bypass, nextcloud.lan, syncthing.lan, ...)

    # MinIO consola — UI humana con 2FA.
    - domain: "minio.{{ env "LAN_DOMAIN" }}"
      policy: two_factor

    # NOTA: s3.{{ env "LAN_DOMAIN" }} NO va detrás de Authelia. La auth la
    # cubre AWS SigV4 con AccessKey/SecretKey por service account.
    # Ver ../06-almacenamiento/04-minio.md §0 punto 5.
```

Reiniciar Authelia (no soporta `watch:` para `configuration.yml`):

```bash
docker compose -f ~/homelab/stacks/auth/docker-compose.yml restart authelia
```

### 7.3. Añadir los dos registros DNS en Pi-hole

Pi-hole UI → **Local DNS** → **DNS Records** → añadir **dos** entradas:

```
minio.lan → 192.168.1.10
s3.lan    → 192.168.1.10
```

Recargar:

```bash
docker exec pihole pihole reloaddns
dig +short @192.168.1.241 minio.lan s3.lan
# Esperado:
#   192.168.1.10
#   192.168.1.10
```

### 7.4. Probar la consola

Desde un cliente con `root.crt` de la CA interna instalado:

```bash
# Health-check API S3 sin pasar por Authelia (cualquiera puede pingar).
curl -fsS -k https://s3.lan/minio/health/live && echo OK
# Esperado: OK

# La consola requiere navegador (login Authelia + login MinIO):
#   https://minio.lan
#   1. Authelia pide login (usuario homelab, password, 2FA TOTP).
#   2. MinIO muestra su login propio: introducir MINIO_ROOT_USER y
#      MINIO_ROOT_PASSWORD (anotados en §2.2).
#   3. Dashboard de MinIO con buckets, monitoring, IAM, etc.
```

### 7.5. Probar la API S3 con `mc` (sanity check)

Pre-flight test sin crear nada todavía:

```bash
# Configurar un alias temporal con las credenciales root.
docker run --rm --network=homelab \
  -e MC_HOST_pi='https://homelab-admin:'"$(grep ^MINIO_ROOT_PASSWORD /mnt/hd2t/services/minio/.env | cut -d= -f2)"'@s3.lan' \
  --add-host=s3.lan:172.20.0.X \
  minio/mc:latest \
  ls pi/

# Esperado: vacío (todavía no hay buckets). Si devuelve "Server not initialized",
# revisar logs de MinIO.
```

> En el snippet anterior `172.20.0.X` es la IP interna de **Caddy** en la red `homelab` (la que sirve `s3.lan` con el cert de la CA interna). Para evitar el `--add-host` se usa el método más limpio de §8.2 (alias de `mc()` que entra a la red Docker y habla directo a `http://minio:9000`, sin pasar por Caddy y sin necesidad de cert).

---

## 8. Configuración post-despliegue

### 8.1. Cambiar el password root tras el primer login (opcional pero recomendado)

Si la generación inicial con `openssl rand -hex 24` ya produjo un password robusto guardado en KeePassXC, **este paso es opcional**. Si se quiere cambiar:

```bash
# Generar nueva password.
NEW_PASS=$(openssl rand -hex 24)

# Actualizar .env.
sudo sed -i "s|^MINIO_ROOT_PASSWORD=.*|MINIO_ROOT_PASSWORD=${NEW_PASS}|" \
  /mnt/hd2t/services/minio/.env

# Recrear el contenedor para que MinIO lea la env y la persista.
cd ~/homelab/stacks/minio
docker compose --env-file /mnt/hd2t/services/minio/.env up -d --force-recreate

# Anotar el nuevo password en KeePassXC.
echo "Nuevo MINIO_ROOT_PASSWORD: ${NEW_PASS}"
unset NEW_PASS
```

> MinIO **no** rota credenciales root en hot-reload. Recreate del contenedor obligatorio.

### 8.2. Definir un alias `mc()` cómodo

`mc` se ejecuta como contenedor efímero en la red Docker. Definir un alias shell que abrevie el comando completo y se reuse:

```bash
# Añadir al ~/.bashrc del operador (o al fichero de aliases del homelab).
cat >> ~/.bashrc <<'EOF'

# === MinIO mc client (../homelab/docs/06-almacenamiento/04-minio.md §8.2) ===
mc() {
    docker run --rm -i --network=homelab \
        -e MC_HOST_pi="http://$(grep ^MINIO_ROOT_USER /mnt/hd2t/services/minio/.env | cut -d= -f2):$(grep ^MINIO_ROOT_PASSWORD /mnt/hd2t/services/minio/.env | cut -d= -f2)@minio:9000" \
        quay.io/minio/mc:latest \
        "$@"
}
EOF

# Recargar.
source ~/.bashrc

# Verificar.
mc admin info pi
# Esperado: cuadro con uptime, version, drives.
```

Notas sobre el alias:

- **`MC_HOST_pi=...`** — `mc` lee aliases de variables de entorno con prefijo `MC_HOST_`. Aquí se inyecta dinámicamente el password del `.env` para no almacenarlo en `~/.mc/config.json`.
- **`http://minio:9000`** — el contenedor de `mc` entra a la red `homelab` y habla directo al backend, **sin pasar por Caddy**. Esto evita problemas de cert (no tiene la CA interna confiada) y reduce un salto. Para pruebas que validen el camino a través de Caddy, usar `mc` apuntando a `https://s3.lan` (variante en §11.1).
- **Tag `:latest` para `minio/mc`**: el cliente es retro-compatible con servidores más viejos. Mantenerlo en `:latest` es seguro y evita gestionar dos pins (servidor y cliente). Si se quiere pinear, usar el mismo tag que el servidor.

### 8.3. Verificar conexión y crear los buckets iniciales

```bash
mc admin info pi
# Esperado:
#   ●  minio:9000
#      Uptime: ...
#      Version: ...
#      Network: 1/1 OK
#      Drives: 1/1 OK
#      Pool: 1
#   ...

# Listar buckets actuales (debería estar vacío).
mc ls pi/
# Esperado: (vacío)
```

#### 8.4. Crear los tres buckets iniciales

##### 8.4.1. `backups` (versionado activo, lifecycle 90 días)

Bucket destinado a backups de Borgmatic / Restic. Versionado activo para protegerse de borrados accidentales (un bug de borgmatic, un `rm` mal escrito, etc.).

```bash
mc mb pi/backups
# Esperado: Bucket created successfully `pi/backups`.

mc version enable pi/backups
# Esperado: pi/backups versioning is enabled

# Confirmar.
mc version info pi/backups
# Esperado: pi/backups versioning is enabled
```

##### 8.4.2. `docker-volumes` (sin versionado, lifecycle 30 días)

Bucket destinado a dumps nocturnos de DBs y volúmenes Docker (`mariadb-dump | gzip | mc pipe`). Cada objeto tiene clave por fecha (`2025-11-08T03:00/nextcloud-mariadb.sql.gz`), versionar es redundante.

```bash
mc mb pi/docker-volumes
# Esperado: Bucket created successfully `pi/docker-volumes`.

# Versioning permanece OFF (default).
mc version info pi/docker-volumes
# Esperado: pi/docker-volumes versioning is un-versioned
```

##### 8.4.3. `media-thumbnails` (opt-in, sin versionado)

Solo crear si tiene sentido (p. ej. una app que cachea thumbnails de Stash, Jellyfin o Audiobookshelf en un bucket S3 en lugar de en disco local). Si no, omitir.

```bash
# (Opcional) Solo si alguna app del homelab lo va a consumir.
mc mb pi/media-thumbnails
mc version info pi/media-thumbnails
```

##### 8.4.4. Verificar el árbol de buckets desde el host

```bash
sudo ls /mnt/hd2t/services/minio/data
# Esperado:
#   .minio.sys/
#   backups/
#   docker-volumes/
#   media-thumbnails/   (si se creó en §8.4.3)

sudo stat -c '%U:%G %a' /mnt/hd2t/services/minio/data/backups
# Esperado: homelab:homelab 755
```

### 8.5. Crear policies y service accounts por aplicación

#### 8.5.1. Policy `borgmatic-backups-rw`

Permite full read/write/delete sobre `backups/*`, **nada más**. Crear el JSON de policy:

```bash
cat > /tmp/policy-borgmatic.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:GetBucketVersioning"
      ],
      "Resource": [
        "arn:aws:s3:::backups"
      ]
    },
    {
      "Sid": "ObjectRW",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:DeleteObjectVersion",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::backups/*"
      ]
    }
  ]
}
EOF

# Cargar la policy en MinIO. mc acepta el path host porque docker run -i
# pipea stdin; aquí la pasamos via volumen efímero:
docker run --rm -i --network=homelab \
    -v /tmp/policy-borgmatic.json:/policy.json:ro \
    -e MC_HOST_pi="http://$(grep ^MINIO_ROOT_USER /mnt/hd2t/services/minio/.env | cut -d= -f2):$(grep ^MINIO_ROOT_PASSWORD /mnt/hd2t/services/minio/.env | cut -d= -f2)@minio:9000" \
    quay.io/minio/mc:latest \
    admin policy create pi borgmatic-backups-rw /policy.json

# Verificar.
mc admin policy list pi
# Esperado: incluye "borgmatic-backups-rw" además de las default
# (consoleAdmin, readonly, readwrite, writeonly, diagnostics).

mc admin policy info pi borgmatic-backups-rw
# Esperado: el JSON cargado.

rm /tmp/policy-borgmatic.json
```

#### 8.5.2. Service account `borgmatic`

Service account asociada al usuario root pero con policy específica. La diferencia frente a un "user" tradicional: la service account **no** puede crearse a sí misma más service accounts; es una credencial con scope.

```bash
mc admin user svcacct add pi $(grep ^MINIO_ROOT_USER /mnt/hd2t/services/minio/.env | cut -d= -f2) \
  --name "borgmatic" \
  --description "Backups Borgmatic via rclone S3" \
  --policy /dev/stdin <<< '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetBucketVersioning"],
      "Resource": ["arn:aws:s3:::backups"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:DeleteObject", "s3:DeleteObjectVersion",
        "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"
      ],
      "Resource": ["arn:aws:s3:::backups/*"]
    }
  ]
}'

# Salida: dos líneas con AccessKey y SecretKey. ANOTAR EN VAULTWARDEN.
# Ejemplo:
#   Access Key: 6XYZ123ABC456789DEFG
#   Secret Key: aBcD/eFgH+iJkLmNoPqRsTuVwXyZ012345AbCdEf
```

> **Variante con policy nombrada**: en lugar de pasar la policy inline, usar la creada en §8.5.1:
> ```bash
> mc admin user svcacct add pi <ROOT_USER> --name borgmatic \
>   --description "Backups Borgmatic" \
>   --policy <(echo '{}')   # quitamos la policy inline
> # luego:
> mc admin user svcacct edit pi <ACCESS_KEY> --policy borgmatic-backups-rw
> ```
> En la práctica el método inline (más arriba) es más concreto — la policy queda atada a la sa.

Anotar las credenciales en **Vaultwarden** (entry "MinIO Service Account: borgmatic"):

```
Access Key: 6XYZ...
Secret Key: aBcD/...
Endpoint:   https://s3.lan
Region:     us-east-1   (MinIO acepta cualquier valor; "us-east-1" es el default)
Bucket:     backups
```

#### 8.5.3. Service account `restic` (alternativa a borgmatic)

Si en lugar de Borgmatic se usa Restic, Restic habla S3 nativo, no necesita rclone. Misma policy:

```bash
mc admin user svcacct add pi $(grep ^MINIO_ROOT_USER /mnt/hd2t/services/minio/.env | cut -d= -f2) \
  --name "restic" \
  --description "Backups Restic" \
  --policy /dev/stdin < /dev/null  # Hereda la del root; refinable después.

# Refinar policy a restic:
mc admin user svcacct edit pi <ACCESS_KEY_RESTIC> \
  --policy borgmatic-backups-rw
```

#### 8.5.4. Service account `nextcloud-external-storage` (RW sobre `media-thumbnails` o un bucket dedicado)

```bash
# Crear primero un bucket separado, no compartir con backups.
mc mb pi/nextcloud-external

# Policy específica.
cat > /tmp/policy-nc.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::nextcloud-external"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": ["arn:aws:s3:::nextcloud-external/*"]
    }
  ]
}
EOF

docker run --rm -i --network=homelab \
    -v /tmp/policy-nc.json:/policy.json:ro \
    -e MC_HOST_pi="http://$(grep ^MINIO_ROOT_USER /mnt/hd2t/services/minio/.env | cut -d= -f2):$(grep ^MINIO_ROOT_PASSWORD /mnt/hd2t/services/minio/.env | cut -d= -f2)@minio:9000" \
    quay.io/minio/mc:latest \
    admin policy create pi nextcloud-rw /policy.json

mc admin user svcacct add pi $(grep ^MINIO_ROOT_USER /mnt/hd2t/services/minio/.env | cut -d= -f2) \
    --name nextcloud-external \
    --description "Nextcloud external storage S3 backend"
mc admin user svcacct edit pi <ACCESS_KEY_NC> --policy nextcloud-rw

rm /tmp/policy-nc.json
```

> Anotar credenciales en Vaultwarden y configurar Nextcloud → **Settings** → **External Storage** → **Add storage** → **Amazon S3** con:
>
> - Bucket: `nextcloud-external`
> - Hostname: `s3.lan`
> - Port: `443`
> - SSL: `yes`
> - Path style: `yes` (MinIO requiere path-style; virtual-hosted style usa `<bucket>.s3.lan` que rompe en CA interna).
> - Access Key: el de la sa.
> - Secret Key: el de la sa.

#### 8.5.5. Listar todas las service accounts creadas

```bash
mc admin user svcacct list pi $(grep ^MINIO_ROOT_USER /mnt/hd2t/services/minio/.env | cut -d= -f2)
# Esperado: lista con "borgmatic", "restic", "nextcloud-external", ...
```

### 8.6. Configurar versionado en `backups`

Ya activado en §8.4.1 con `mc version enable pi/backups`. Verificar el estado tras varios PUTs:

```bash
echo "v1" | mc pipe pi/backups/test.txt
echo "v2" | mc pipe pi/backups/test.txt
echo "v3" | mc pipe pi/backups/test.txt

# Listar versiones.
mc ls --versions pi/backups/test.txt
# Esperado: 3 entradas con distinto VersionID:
#   [<fecha>] N B v3-id   test.txt
#   [<fecha>] N B v2-id   test.txt
#   [<fecha>] N B v1-id   test.txt

# Limpiar.
mc rm --versions --recursive --force pi/backups/test.txt
```

### 8.7. Configurar lifecycle policies

#### 8.7.1. `backups`: expirar versiones no-actuales tras 90 días

```bash
mc ilm rule add pi/backups \
    --noncurrent-expire-days 90 \
    --noncurrent-expire-newer 5

# Explicación:
# --noncurrent-expire-days 90: borra versiones no-actuales (sobreescritas)
#                              tras 90 días desde que pasaron a no-actuales.
# --noncurrent-expire-newer 5: además, conserva siempre las 5 versiones
#                              no-actuales más recientes, aunque pasen los
#                              90 días. Protege contra "borrar todo el
#                              histórico por un pico de overwrites".

# Verificar.
mc ilm rule list pi/backups
# Esperado: una regla con NoncurrentVersionExpiration: 90d, MaxNoncurrentVersions: 5.
```

#### 8.7.2. `docker-volumes`: expirar objetos tras 30 días

```bash
mc ilm rule add pi/docker-volumes \
    --expire-days 30

# Verificar.
mc ilm rule list pi/docker-volumes
# Esperado: una regla con Expiration: 30d.
```

#### 8.7.3. Comprobar que el scanner ILM de MinIO está activo

```bash
mc admin info pi --json | jq '.info.scanner'
# Esperado: scanner running con "current_cycle" incrementándose.
```

> **Frecuencia del scanner**: por defecto MinIO recorre el filesystem cada `MINIO_SCANNER_DELAY` (default 0, "tan rápido como permita la I/O"). Las reglas ILM se aplican en ese ciclo. En SNSD con un disco USB la prioridad del scanner es baja para no competir con I/O de operaciones cliente. Las expiraciones pueden tardar horas en materializarse — irrelevante para retenciones de 30/90 días.

### 8.8. Configurar políticas de bucket por defecto (anonymous access)

Por defecto, todos los buckets son **privados**. Confirmar:

```bash
for b in backups docker-volumes; do
  echo "=== $b ===";
  mc anonymous get pi/$b;
done
# Esperado, ambos: "Access permission for 'pi/<b>' is 'none'."
```

> **No** abrir ningún bucket a `download` / `upload` / `public` salvo que haya una razón concreta (p. ej. servir thumbnails sin auth en una web pública vía Tailscale). Para ese caso documentado en §14.8.

---

## 9. Verificación

### 9.1. Contenedor sano

```bash
docker compose -f ~/homelab/stacks/minio/docker-compose.yml \
  --env-file /mnt/hd2t/services/minio/.env ps
# Esperado: STATUS = Up X (healthy)
```

### 9.2. Acceso a la consola vía Caddy con Authelia

Desde un cliente con `root.crt` instalado: `https://minio.lan` → Authelia 2FA → login MinIO root → dashboard "Object Browser" muestra los 2-3 buckets creados en §8.4.

### 9.3. API S3 accesible vía `s3.lan` con SigV4

```bash
# Recuperar credenciales de la service account borgmatic anotadas en
# Vaultwarden (no se reconstruyen desde MinIO; si se perdieron, crear otra).
read -p "Access Key (borgmatic): " AK
read -s -p "Secret Key (borgmatic): " SK; echo
export AWS_ACCESS_KEY_ID="$AK"
export AWS_SECRET_ACCESS_KEY="$SK"
unset AK SK

# Probar con awscli (instalable temporal):
docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
    -v /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro \
    --add-host=s3.lan:192.168.1.10 \
    amazon/aws-cli:latest \
    --endpoint-url https://s3.lan \
    --no-verify-ssl \
    s3 ls s3://backups/
# Esperado: vacío (sin objetos todavía) o el "test.txt" si quedó algo de §8.6.
# --no-verify-ssl porque el cliente no tiene la CA interna confiada;
# en producción del homelab, montar root.crt en /etc/ssl/certs/.

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
```

### 9.4. PUT y GET via SigV4

```bash
# Reusar las credenciales de borgmatic.
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."

echo "hola minio" > /tmp/sanity.txt

docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
    -v /tmp/sanity.txt:/sanity.txt:ro \
    --add-host=s3.lan:192.168.1.10 \
    amazon/aws-cli:latest \
    --endpoint-url https://s3.lan --no-verify-ssl \
    s3 cp /sanity.txt s3://backups/sanity.txt

# Verificar.
docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
    --add-host=s3.lan:192.168.1.10 \
    amazon/aws-cli:latest \
    --endpoint-url https://s3.lan --no-verify-ssl \
    s3 ls s3://backups/

# Esperado:
#   <fecha> 11 sanity.txt

# GET de vuelta.
docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
    --add-host=s3.lan:192.168.1.10 \
    amazon/aws-cli:latest \
    --endpoint-url https://s3.lan --no-verify-ssl \
    s3 cp s3://backups/sanity.txt -

# Esperado: "hola minio"

# Cleanup.
mc rm pi/backups/sanity.txt
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
rm /tmp/sanity.txt
```

### 9.5. La policy de la service account es restrictiva

```bash
# Las credenciales de borgmatic NO deben poder listar buckets distintos a "backups".
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."

docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
    --add-host=s3.lan:192.168.1.10 \
    amazon/aws-cli:latest \
    --endpoint-url https://s3.lan --no-verify-ssl \
    s3 ls s3://docker-volumes/

# Esperado:
#   An error occurred (AccessDenied) when calling the ListObjectsV2 operation:
#   Access Denied.

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
```

### 9.6. Versionado funciona en `backups` y NO en `docker-volumes`

```bash
echo "a" | mc pipe pi/backups/v.txt
echo "b" | mc pipe pi/backups/v.txt
mc ls --versions pi/backups/v.txt | wc -l
# Esperado: 2

echo "c" | mc pipe pi/docker-volumes/v.txt
echo "d" | mc pipe pi/docker-volumes/v.txt
mc ls --versions pi/docker-volumes/v.txt | wc -l
# Esperado: 1   (sin versioning, el segundo PUT sobreescribe).

# Cleanup.
mc rm --versions --recursive --force pi/backups/v.txt
mc rm pi/docker-volumes/v.txt
```

### 9.7. URLs presigned apuntan a `s3.lan` (no a `minio:9000`)

```bash
mc share download --expire 1h pi/backups/sanity.txt 2>/dev/null || \
    echo "(no existe el objeto, esperado tras cleanup; basta ver el share de cualquier objeto)"

# Crear uno temporal:
echo "x" | mc pipe pi/backups/share-test.txt
mc share download --expire 5m pi/backups/share-test.txt | grep '^Share:'

# Esperado:
#   Share: https://s3.lan/backups/share-test.txt?X-Amz-Algorithm=...&...
# CLAVE: el host es "s3.lan", NO "minio:9000". Si sale "minio:9000",
# revisar MINIO_SERVER_URL en .env (§5).

mc rm pi/backups/share-test.txt
```

### 9.8. Métricas Prometheus accesibles desde la red Docker

```bash
docker exec caddy wget -qO- http://minio:9000/minio/v2/metrics/cluster | head -10
# Esperado: líneas formato Prometheus (TYPE/HELP) con métricas tipo
#   minio_cluster_health_status 1
#   minio_cluster_usage_total_bytes 0
#   minio_cluster_objects_count 5
#   ...
```

### 9.9. Persistencia tras reboot

```bash
sudo reboot

# (esperar a que vuelva)

docker compose -f ~/homelab/stacks/minio/docker-compose.yml ps
# Esperado: Up X (healthy)

mc ls pi/
# Esperado: backups/ docker-volumes/ [media-thumbnails/]

mc admin user svcacct list pi homelab-admin
# Esperado: las service accounts creadas en §8.5 siguen ahí.
```

### 9.10. Lista de Verificación

Antes de pasar a [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md):

- [ ] `docker compose ps` en el stack `minio` → `Up (healthy)`.
- [ ] `sudo ss -lntu sport=:9000` y `sport=:9001` están **VACÍOS** (MinIO no publica al host).
- [ ] `dig +short @192.168.1.241 minio.lan` y `s3.lan` resuelven a `192.168.1.10`.
- [ ] `https://minio.lan` exige Authelia 2FA antes de pedir login MinIO root.
- [ ] `https://s3.lan/minio/health/live` responde 200 sin pedir auth (el endpoint /health es público, no SigV4).
- [ ] El operador ha **anotado** en KeePassXC/Vaultwarden: `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, y los `AccessKey/SecretKey` de cada service account creada.
- [ ] Buckets `backups` y `docker-volumes` existen; `backups` tiene `versioning: enabled`.
- [ ] Lifecycle rule en `backups` (90d noncurrent) y en `docker-volumes` (30d expire) están listadas con `mc ilm rule list`.
- [ ] PUT/GET via `aws s3 --endpoint-url https://s3.lan` con las credenciales de una service account funciona.
- [ ] Una service account NO puede acceder a un bucket fuera de su policy (test §9.5).
- [ ] Las URLs presigned (`mc share download`) llevan host `s3.lan`, no `minio:9000`.
- [ ] `~/homelab/stacks/minio/{docker-compose.yml,.env.example}` versionados en git; `.env` **NO**.
- [ ] `/mnt/hd2t/services/minio/data/.minio.sys/format.json` tiene dueño `homelab:homelab`.
- [ ] Tras `sudo reboot`, MinIO arranca solo, los buckets persisten, las service accounts persisten.

---

## 10. Backup

Estrategia detallada en [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) y [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md). Para MinIO hay **dos planos** de backup que no deben confundirse:

### 10.1. Plano A: respaldar al propio MinIO (sus datos en disco)

MinIO en SNSD es, físicamente, un árbol de ficheros en `/mnt/hd2t/services/minio/data/`. Borg lo respalda como cualquier otro servicio.

| Ruta | Qué contiene | Frecuencia | Cómo |
|---|---|---|---|
| `~/homelab/stacks/minio/{docker-compose.yml,.env.example}` | Definición del stack. | Versionado en git → `git push`. | Continuo. |
| `/mnt/hd2t/services/minio/.env` | Credenciales root, dominios, tag. **Crítico**. | Cada cambio. | Snapshot Borg. |
| `/mnt/hd2t/services/minio/data/<bucket>/` | Objetos (los datos reales). **Crítico** según contenido. | Diario diferencial. | Snapshot Borg con dedup. |
| `/mnt/hd2t/services/minio/data/.minio.sys/` | Metadata: IAM, policies, lifecycle, versioning. **Crítico**. Sin este directorio no se puede reconstruir el estado de MinIO. | Diario. | Snapshot Borg. |
| `/mnt/hd2t/services/minio/config/` | Vacío en SNSD sin TLS nativo. | Diario (es trivial). | Snapshot Borg. |

#### 10.1.1. Pre-backup hook (Borgmatic)

Para snapshot consistente, **detener brevemente** el contenedor o, mejor, usar el endpoint `mc admin service stop` que apaga MinIO de forma limpia (flush de buffers, cierre de WAL):

```yaml
# Pseudo-config; la real va en 07-backups/02-borgmatic.md.
exclude_patterns:
  # Nada que excluir: todo es necesario para restaurar.

before_backup:
  # Opción A (preferida): apagar gracefully MinIO durante el snapshot.
  - docker compose -f /home/homelab/homelab/stacks/minio/docker-compose.yml stop minio

after_backup:
  - docker compose -f /home/homelab/homelab/stacks/minio/docker-compose.yml start minio
```

> **Por qué stop, no pause**: MinIO en SNSD escribe metadata (incluido `.minio.sys/buckets/.../versioning.json`) en POST/PUT operations. Pause con SIGSTOP deja descriptores abiertos pero no flushea — un crash en pleno backup podría dejar metadata corrupta. Un `docker compose stop` da SIGTERM, MinIO sincroniza buffers y cierra: backup atómico. Downtime ~5–15 s, aceptable a las 03:00.

> **Alternativa sin stop**: snapshot del filesystem con `lvm` o `btrfs snapshot`. Fuera de scope del homelab actual (hd2t es ext4 sin LVM).

#### 10.1.2. Restore

1. `docker compose down` en el stack `minio`.
2. Restaurar `/mnt/hd2t/services/minio/{data,config,.env}` desde Borg al estado de la noche anterior.
3. Verificar permisos: `sudo chown -R homelab:homelab /mnt/hd2t/services/minio/data/`.
4. `docker compose up -d`.
5. `mc admin info pi` → debería volver a sano con todos los buckets, policies y service accounts.

> **Idempotente**: la restore es bit-perfect. Cada AccessKey/SecretKey emitida sigue válida (vive en `.minio.sys/config/iam/...`). Las apps cliente (Borgmatic, Restic) reconectan sin retoques.

### 10.2. Plano B: replicar MinIO local hacia un MinIO/S3 remoto (offsite real)

Esto **no** se hace en este doc (no hay servidor remoto todavía), pero queda preparado el patrón para fase 7:

```bash
# Hipotético: un VPS/segundo Pi con otro MinIO o un proveedor S3 (Backblaze B2).
mc alias set offsite https://s3.eu-central-003.backblazeb2.com <KEY> <SECRET>

# Espejo continuo (corre como systemd timer cada noche tras los backups locales).
mc mirror --remove --overwrite \
    pi/backups/ offsite/<bucket>/

# Verificar.
mc diff pi/backups/ offsite/<bucket>/
# Esperado: vacío (sin diferencias).
```

> **Por qué `mc mirror` y no replicación nativa**: MinIO soporta `mc replicate` para replicación bidireccional/asíncrona, pero exige que el peer también sea MinIO con misma versión y bucket-versioning activo en ambos lados. `mc mirror` funciona contra **cualquier endpoint S3** (Backblaze, Wasabi, AWS, OVH OS, otro MinIO viejo). Para el homelab "una vez al día empuja todo", `mirror` sobra.

> **Coste estimado**: 1 TB en Backblaze B2 ≈ 6 €/mes. 100 GB en Wasabi ≈ gratis (mínimo 1 TB facturable). Comparar antes de fijar uno.

### 10.3. Lo que MinIO **no** sustituye

- **No** sustituye Borgmatic local. Borgmatic en `/mnt/hd2t/backups/borg/` es la primera línea (rápida, dedup, retención larga). MinIO es el **destino S3** que las apps consumen, y/o el **medio para replicar offsite**.
- **No** sustituye un offsite real. Si la Pi se cae con todo, MinIO local cae con ella. La regla 3-2-1 exige `mc mirror` a un proveedor externo (o a otro Pi en otra casa).

---

## 11. Operaciones cotidianas

### 11.1. Comandos `mc` más usados

```bash
# Listar buckets.
mc ls pi/

# Listar objetos en un bucket (recursivo).
mc ls --recursive pi/backups/

# Subir un fichero.
mc cp /tmp/foo.tar.gz pi/backups/

# Subir directorio recursivo (sync incremental, no re-uploadea iguales).
mc mirror --overwrite /mnt/hd2t/some-dir/ pi/backups/some-dir/

# Descargar un fichero.
mc cp pi/backups/foo.tar.gz /tmp/

# Borrar un fichero (versionado: pasa a non-current; sin versionado: borra).
mc rm pi/backups/foo.tar.gz

# Borrar un fichero en bucket versionado, **incluyendo todas sus versiones**.
mc rm --versions --force pi/backups/foo.tar.gz

# Estado del cluster (en SNSD: del nodo).
mc admin info pi

# Heal (chequeo de integridad sobre los objetos en disco).
mc admin heal -r pi/

# Ver uso de cada bucket.
mc du pi/

# Probar la API a través de Caddy en lugar de la red interna (verifica
# que el camino real funcione).
docker run --rm -i \
    --add-host=s3.lan:192.168.1.10 \
    -e MC_HOST_pi="https://homelab-admin:$(grep ^MINIO_ROOT_PASSWORD /mnt/hd2t/services/minio/.env | cut -d= -f2)@s3.lan" \
    quay.io/minio/mc:latest \
    --insecure \
    ls pi/
# --insecure porque la imagen mc no tiene la CA interna; en producción
# se monta /etc/ssl/certs/root.crt como volumen.
```

### 11.2. Crear un bucket nuevo (proceso completo)

```bash
# 1. Crear el bucket.
mc mb pi/<nuevo-bucket>

# 2. Activar versioning (decisión por bucket).
mc version enable pi/<nuevo-bucket>

# 3. Lifecycle policy.
mc ilm rule add pi/<nuevo-bucket> --expire-days 60

# 4. Policy IAM y service account.
cat > /tmp/policy-<nuevo-bucket>.json <<EOF
{ "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::<nuevo-bucket>"] },
    { "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::<nuevo-bucket>/*"] }
  ] }
EOF

docker run --rm -i --network=homelab \
    -v /tmp/policy-<nuevo-bucket>.json:/p.json:ro \
    -e MC_HOST_pi="..." \
    quay.io/minio/mc:latest \
    admin policy create pi <nuevo-bucket>-rw /p.json

# 5. Service account ligada a esa policy.
mc admin user svcacct add pi homelab-admin --name <nuevo-bucket>-app
# (anotar AK/SK)
mc admin user svcacct edit pi <AK> --policy <nuevo-bucket>-rw

# 6. Anotar credenciales en Vaultwarden y configurar la app cliente.
```

### 11.3. Rotar las credenciales de una service account

```bash
# Crear una sa nueva con la misma policy.
mc admin user svcacct add pi homelab-admin --name borgmatic-v2
mc admin user svcacct edit pi <NEW_AK> --policy borgmatic-backups-rw

# Configurar borgmatic con NEW_AK / NEW_SK. Probar un backup completo.

# Una vez validado, borrar la antigua.
mc admin user svcacct remove pi <OLD_AK>
```

### 11.4. Forzar lifecycle inmediato (no esperar al scanner)

```bash
mc admin scanner status pi
# Muestra el cycle actual.

# Triggerear un escaneo on-demand (MinIO ≥ RELEASE.2024-...).
mc admin trigger pi scanner
```

### 11.5. Cambiar `MINIO_ROOT_PASSWORD`

Igual que §8.1: editar `.env`, `docker compose up -d --force-recreate`. Las service accounts NO se invalidan: viven en `.minio.sys/config/iam/`, son independientes del root.

### 11.6. Añadir scrape job de Prometheus

Editar `~/homelab/stacks/monitoring/prometheus.yml` y añadir (descomentar, según el patrón de [`../05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md) §6):

```yaml
scrape_configs:
  # ... jobs previos ...

  # MinIO — métricas cluster + bucket. Activado por
  # ../06-almacenamiento/04-minio.md §11.6.
  - job_name: 'minio-cluster'
    metrics_path: /minio/v2/metrics/cluster
    static_configs:
      - targets: ['minio:9000']

  - job_name: 'minio-node'
    metrics_path: /minio/v2/metrics/node
    static_configs:
      - targets: ['minio:9000']

  # Métricas por bucket (cardinalidad: pueden ser muchas si hay >100 buckets).
  - job_name: 'minio-bucket'
    metrics_path: /minio/v2/metrics/bucket
    static_configs:
      - targets: ['minio:9000']
```

Validar y recargar:

```bash
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
docker exec prometheus kill -HUP 1
```

Verificar en la UI de Prometheus (`https://prometheus.lan` → **Targets** → `minio-cluster` debería estar `UP`).

Dashboard recomendado en Grafana ([`../05-monitorizacion/02-grafana.md`](../05-monitorizacion/02-grafana.md)): importar el dashboard ID **13502** ("MinIO Dashboard").

### 11.7. Inspeccionar el log de MinIO

```bash
docker logs --tail 100 -f minio

# Filtrar errores recientes.
docker logs minio 2>&1 | grep -iE 'error|fail|deny' | tail -20

# Auditoría de requests (si MINIO_AUDIT_WEBHOOK_* está activo, variante §14.6).
```

> Por defecto MinIO escribe los `INFO` mínimos a stdout. El log de auditoría detallado (`s3.PutObject`, `s3.GetObject`, etc.) se activa con `MINIO_AUDIT_WEBHOOK_ENABLE_<id>=on` y un endpoint receptor (variante §14.6).

### 11.8. Migrar entre tags de imagen (upgrade manual)

Si Watchtower está desactivado (variante §14.1):

```bash
# 1. Leer release notes.
xdg-open https://github.com/minio/minio/releases/tag/<NUEVO_RELEASE>

# 2. Editar .env.
sudo sed -i "s|^MINIO_IMAGE_TAG=.*|MINIO_IMAGE_TAG=<NUEVO_RELEASE>|" \
  /mnt/hd2t/services/minio/.env

# 3. Pull + recreate.
cd ~/homelab/stacks/minio
docker compose --env-file /mnt/hd2t/services/minio/.env pull
docker compose --env-file /mnt/hd2t/services/minio/.env up -d

# 4. Verificar.
docker logs minio | grep '^Version:'
mc admin info pi
```

> **Nunca** *bajar* de tag (downgrade) con un `.minio.sys/format.json` ya escrito por una versión más reciente: MinIO arranca con error `format version not supported`. La única salida es restaurar desde Borg el estado anterior. Documentado en §12.

### 11.9. Snapshot manual ad-hoc (sin Borgmatic)

Para un snapshot puntual antes de un cambio arriesgado:

```bash
# Detener limpio.
docker compose -f ~/homelab/stacks/minio/docker-compose.yml stop minio

# Tar atómico.
sudo tar --acls --xattrs -cpf /mnt/hd2t/backups/minio-$(date +%Y%m%d-%H%M%S).tar \
    -C /mnt/hd2t/services/minio data config .env

# Reanudar.
docker compose -f ~/homelab/stacks/minio/docker-compose.yml start minio
```

---

## 12. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `WARNING: Detected default credentials 'minioadmin:minioadmin'` en logs | `.env` no se carga; `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` vacíos. | Verificar `docker compose --env-file ... config` muestra los valores. Recordar: `env_file:` y `environment:` deben coincidir. |
| Cliente S3 (mc, aws, restic) recibe `403 SignatureDoesNotMatch` | El header `Host` no coincide con el firmado: Caddy lo está reescribiendo, o el cliente apunta a `s3.lan:443` y la firma es para `s3.lan`. | Confirmar `header_up Host {host}` en el bloque `s3.lan` del Caddyfile (§7.1). Confirmar que el cliente NO añade puerto si va por 443 (default). |
| Consola MinIO redirige tras login a `http://localhost:9001/` y falla | `MINIO_BROWSER_REDIRECT_URL` no fijada o mal escrita. | `grep MINIO_BROWSER_REDIRECT_URL /mnt/hd2t/services/minio/.env` → debe ser `https://minio.lan`. Si se cambia, recreate. |
| URLs presigned salen como `http://minio:9000/...` | `MINIO_SERVER_URL` no fijada. | Igual que arriba con `MINIO_SERVER_URL=https://s3.lan`. Recreate. |
| `mc cp` desde el host falla con `x509: certificate signed by unknown authority` | El contenedor `mc` no tiene la CA interna confiada. | Opción A: usar el alias §8.2 que va a `http://minio:9000` por la red Docker (sin TLS). Opción B: montar `/etc/ssl/certs/root.crt:/root/.mc/certs/CAs/root.crt:ro` en el `docker run`. |
| `mc admin info pi` cuelga sin respuesta | El alias `pi` apunta a `s3.lan` pero la red Docker no tiene resolución directa al hostname (`s3.lan` es DNS de Pi-hole, no DNS Docker). | Cambiar el alias a `http://minio:9000` o añadir `--add-host s3.lan:192.168.1.10`. |
| Apps cliente con `--insecure` o `--no-verify-ssl` por la CA interna | La CA interna no está confiada en el cliente. | Distribuir `root.crt` (de [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §6.5) al sistema cliente o al contenedor. |
| Lifecycle no expira objetos | Scanner pausado, ILM tier desactivado, o regla mal definida. | `mc admin scanner status pi`, `mc ilm rule list pi/<bucket>`. Si la regla está bien, esperar al siguiente cycle (puede tardar horas con muchos objetos). |
| MinIO arranca y dice `Drive offline` o `format.json mismatch` | Se hizo `chown` mal o se restauró parcialmente. | `sudo chown -R homelab:homelab /mnt/hd2t/services/minio/data/`. Confirmar que `.minio.sys/format.json` existe y es legible por UID 1000. |
| Container `(unhealthy)` intermitente | El healthcheck `curl /minio/health/live` tarda más de 10s con I/O del disco saturado. | `iotop` durante el scanner. Subir `timeout` a 20s y `start_period` a 60s en el compose. |
| Apps cliente fallan con `RequestTimeTooSkewed` | Reloj del cliente desfasado >15min respecto al servidor. | `timedatectl set-ntp true` en cliente y servidor. SigV4 no admite skew >15min. |
| `mc mirror` muy lento (KB/s) en LAN gigabit | I/O del disco USB (hd2t) saturado por concurrencia o por el scanner. | `iostat -x 1 /dev/sda` durante el mirror. Reducir `--concurrency` (default 1; subirlo a 8 paraleliza, pero cuidado con el bus USB). |
| `s3.lan` accesible desde Tailscale falla con `x509` o `dns lookup` | DNS de Tailscale (MagicDNS) no resuelve `*.lan`. | Variante §14.4 establece `s3.tailnet.ts.net` separado, no `s3.lan` desde Tailscale. |
| Watchtower bumpeó MinIO y la consola muestra "Update available" pero el formato de metadata cambió y no arranca | Algunos releases de MinIO requieren no bajar; si Watchtower bumpea sin revisar, y luego se intenta downgrade, falla. | Restaurar `/mnt/hd2t/services/minio/data` desde Borg al snapshot pre-upgrade. Considerar variante §14.1. |
| Después de un restore desde Borg, las service accounts existen pero los clientes reciben `InvalidAccessKeyId` | El restore restauró `data/` pero NO `data/.minio.sys/config/iam/`. Sin IAM no hay credenciales válidas. | Borg debería respaldar `.minio.sys/` íntegro (§10). Re-restaurar incluyendo este path. |
| Bucket "no se puede borrar" porque tiene versiones | Versionado activo y objetos non-current presentes. | `mc rm --versions --recursive --force pi/<bucket>/` antes de `mc rb pi/<bucket>`. |
| El operador olvidó `MINIO_ROOT_PASSWORD` | No hay recovery: el `.env` es la única fuente. | Si Vaultwarden lo tiene, recuperar. Si no, recrear: parar contenedor, editar `.env`, arrancar — MinIO acepta el nuevo y persiste. Las service accounts existentes siguen válidas. |

---

## 13. Integración con Fail2ban (opcional)

MinIO no se incluye por defecto en [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md). Razones:

- **`s3.lan`** no usa Authelia ni passwords reusables: cada request va con SigV4. Un brute-force a SigV4 implica adivinar un `SecretKey` de 40 caracteres alfanuméricos por request — no factible en horizonte humano. Sin password de bajo entropy, no hay brute-force que bannear.
- **`minio.lan`** sí tiene un login user/password de la consola **detrás** de Authelia 2FA. Authelia ya banea brute-force tras X intentos fallidos ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §0). Solo si Authelia se quita (variante §14.3), tiene sentido un jail.

Si el operador quiere defensa en profundidad para la consola sin Authelia (caso §14.3):

### 13.1. Filtro `filter.d/minio-console.local`

```ini
# ~/homelab/stacks/minio/snippets-fail2ban/minio-console.local
# Detecta fallos de auth en la consola (logs JSON del demonio MinIO).

[Definition]
# MinIO loguea fallos de login con time, user, source-ip:
#   {"level":"INFO","time":"...","message":"login attempt failed","user":"...","source":"<HOST>:..."}
failregex = ^.*"message"\s*:\s*"login attempt failed".*"source"\s*:\s*"<HOST>:.*$

ignoreregex =

datepattern = {^LN-BEG}%%Y-%%m-%%dT%%H:%%M:%%S
```

### 13.2. Jail `jail.d/40-minio-console.conf`

```ini
[minio-console]
enabled  = true
filter   = minio-console
backend  = systemd
journalmatch = CONTAINER_NAME=minio
port     = 80,443
maxretry = 5
findtime = 10m
bantime  = 1h
```

### 13.3. Aplicar al host

```bash
sudo install -m 644 -o root -g root \
  ~/homelab/stacks/minio/snippets-fail2ban/minio-console.local \
  /etc/fail2ban/filter.d/minio-console.local

sudo install -m 644 -o root -g root \
  ~/homelab/stacks/minio/snippets-fail2ban/40-minio-console.conf \
  /etc/fail2ban/jail.d/40-minio-console.conf

sudo fail2ban-client reload
sudo fail2ban-client status minio-console
```

> **No se hace un jail para `s3.lan`** porque, como se explicó, el modelo de auth de S3 lo hace innecesario.

---

## 14. Variantes opt-in

### 14.1. Desactivar Watchtower para MinIO

Si el operador prefiere upgrades manuales (revisar release notes y comportamiento de cada release antes de bumpear):

```yaml
# En docker-compose.yml, en labels del servicio minio:
labels:
  com.centurylinklabs.watchtower.enable: "false"
  # ... resto de labels
```

Procedimiento manual: §11.8.

### 14.2. TLS nativo de MinIO (no recomendado)

Si por algún motivo el operador quiere que MinIO sirva HTTPS por sí mismo (p. ej. expuesto a internet sin Caddy delante — fuera del scope de este homelab pero documentado para completitud):

1. Generar cert válido para `s3.lan` y `minio.lan` (con la CA interna):
   ```bash
   docker exec caddy caddy adapt --config /etc/caddy/Caddyfile  # genera certs internos
   sudo cp /var/lib/docker/volumes/proxy_caddy_data/_data/caddy/pki/authorities/local/intermediate.crt \
       /mnt/hd2t/services/minio/config/certs/CAs/root.crt
   ```
2. Generar cert con SAN `s3.lan,minio.lan`:
   ```bash
   # Con cfssl o openssl, fuera del alcance de este doc.
   ```
3. Montar:
   ```yaml
   volumes:
     - ./certs/public.crt:/root/.minio/certs/public.crt:ro
     - ./certs/private.key:/root/.minio/certs/private.key:ro
   ```
4. MinIO detecta los certs y arranca en HTTPS por sí mismo en :9000/:9001.

> **No tiene sentido** en este homelab porque Caddy ya termina TLS perfectamente. Sólo se documenta como referencia.

### 14.3. Quitar Authelia delante de la consola (no recomendado)

Solo si el operador no usa Authelia y quiere la consola con su propia auth (user/password root):

```caddy
minio.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    reverse_proxy http://minio:9001 {
        header_up Host {host}
        header_up X-Forwarded-Proto https
    }
}
```

Y eliminar la regla `minio.lan` de `access_control.rules` en Authelia.

> Riesgo: la auth root de MinIO es user/password sin 2FA. Imprescindible password largo + considerar el jail Fail2ban (§13).

### 14.4. Acceso desde Tailscale (`s3.tailnet.ts.net`, `minio.tailnet.ts.net`)

Para acceder a los buckets desde fuera de casa (móvil, portátil en otra red, segundo Pi en VPS).

Añadir en el `Caddyfile`:

```caddy
# Consola MinIO desde Tailscale.
minio.{$TS_DOMAIN} {
    import tailscale_tls minio
    import security_headers

    # Sin Authelia delante: Tailscale ya hace transport-auth (solo devices
    # del tailnet llegan). La auth nativa de MinIO sigue activa.
    reverse_proxy http://minio:9001 {
        header_up Host {host}
        header_up X-Forwarded-Proto https
    }
}

# API S3 desde Tailscale.
s3.{$TS_DOMAIN} {
    import tailscale_tls s3
    import security_headers

    request_body { max_size 10GB }

    reverse_proxy http://minio:9000 {
        header_up Host {host}
        header_up X-Forwarded-Proto https
    }
}
```

Y emitir los certs con `tailscale cert s3.tailnet.ts.net minio.tailnet.ts.net` ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)).

> **Importante**: los clientes S3 desde Tailscale necesitan `MINIO_SERVER_URL=https://s3.tailnet.ts.net` cuando hablan desde Tailscale. Con un solo `MINIO_SERVER_URL` no es posible servir dos URLs canónicas a la vez. **Trade-off**: o bien las URLs presigned funcionan en LAN (`s3.lan`) o en Tailscale (`s3.tailnet.ts.net`), pero no en ambas. La práctica común es elegir una y aceptar que la otra requiere clientes que generen sus propias presigned (cosa que `mc share download` permite con `--alias` distinto).

### 14.5. SSE-S3 con KES (encryption-at-rest)

Si los datos son sensibles y la pérdida del disco hd2t (robo, RMA) implicaría leak: MinIO soporta cifrado a nivel de objeto con SSE-S3, pero requiere un KES (Key Encryption Service) externo. Documentación: https://min.io/docs/minio/linux/operations/server-side-encryption.html.

> Alternativa más simple para el homelab: cifrar el filesystem subyacente con LUKS (en `../01-sistema/`). Una vez ext4 está sobre LUKS, cualquier dato escrito por MinIO está cifrado at-rest sin tocar MinIO.

### 14.6. Notificaciones de eventos a webhook (audit/alerts)

Para que MinIO notifique a un webhook cada PUT/DELETE (útil para auditoría o triggers tipo "scan AV al subir"):

```bash
# Configurar un webhook target.
mc admin config set pi notify_webhook:audit \
    endpoint="https://webhook-receiver.lan/minio-events" \
    auth_token="<token-secreto>" \
    queue_limit="100"

# Aplicar.
mc admin service restart pi
# (downtime ~5s)

# Asociar el target a un bucket.
mc event add pi/backups arn:minio:sqs::audit:webhook \
    --event put,delete
```

### 14.7. Service account "homepage-readonly" para el widget

Para que el widget de Homepage no use credenciales root:

```bash
# Policy: solo listar buckets y leer métricas básicas.
cat > /tmp/policy-homepage.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["s3:ListAllMyBuckets", "admin:ServerInfo"],
      "Resource": ["*"] }
  ]
}
EOF

# Cargar y crear sa.
mc admin policy create pi homepage-readonly /tmp/policy-homepage.json
mc admin user svcacct add pi homelab-admin --name homepage
mc admin user svcacct edit pi <AK> --policy homepage-readonly

# Actualizar las labels del compose:
#   homepage.widget.key: "<NEW_AK>"
#   homepage.widget.secret: "<NEW_SK>"
# y recrear el contenedor.

rm /tmp/policy-homepage.json
```

### 14.8. Bucket público anonymous (para servir thumbnails sin auth)

Caso muy específico: una galería de imágenes accesible vía Tailscale a invitados sin entregar credenciales. **No recomendado en LAN normal**.

```bash
mc mb pi/public-thumbnails
mc anonymous set download pi/public-thumbnails

# Verificar.
mc anonymous get pi/public-thumbnails
# Esperado: pi/public-thumbnails: download
```

> Un `GET https://s3.lan/public-thumbnails/<key>` ahora es público sin firma. Cualquiera con DNS a `s3.lan` (o `s3.tailnet.ts.net`) puede listar y descargar. Aplicar selectivo (un solo bucket), nunca al `backups`.

---

## Referencias

- [MinIO — Documentación oficial](https://min.io/docs/minio/linux/index.html)
- [MinIO — Container deployment (SNSD)](https://min.io/docs/minio/container/operations/install-deploy-manage/deploy-minio-single-node-single-drive.html)
- [MinIO — Console behind a reverse proxy](https://min.io/docs/minio/linux/operations/network-encryption.html)
- [MinIO — `MINIO_SERVER_URL` / `MINIO_BROWSER_REDIRECT_URL`](https://min.io/docs/minio/linux/reference/minio-server/settings/browser.html)
- [MinIO — IAM / Policies / Service Accounts](https://min.io/docs/minio/linux/administration/identity-access-management.html)
- [MinIO — Bucket Versioning](https://min.io/docs/minio/linux/administration/object-management/object-versioning.html)
- [MinIO — Object Lifecycle Management (ILM)](https://min.io/docs/minio/linux/administration/object-management/object-lifecycle-management.html)
- [MinIO — Bucket Replication / `mc mirror`](https://min.io/docs/minio/linux/reference/minio-mc/mc-mirror.html)
- [MinIO — Prometheus Metrics](https://min.io/docs/minio/linux/operations/monitoring/collect-minio-metrics-using-prometheus.html)
- [MinIO — Bucket Notifications (webhooks)](https://min.io/docs/minio/linux/administration/monitoring/bucket-notifications.html)
- [MinIO Client (`mc`) reference](https://min.io/docs/minio/linux/reference/minio-mc.html)
- [`quay.io/minio/minio` — Tags](https://quay.io/repository/minio/minio?tab=tags)
- [`quay.io/minio/mc` — Tags](https://quay.io/repository/minio/mc?tab=tags)
- [MinIO — Releases en GitHub](https://github.com/minio/minio/releases)
- [AWS — Signature Version 4 signing process](https://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html)
- [Caddy — `reverse_proxy` y `header_up`](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
