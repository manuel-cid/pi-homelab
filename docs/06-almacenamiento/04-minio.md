# MinIO (almacenamiento de objetos compatible con S3)

## Descripción

Despliegue de **MinIO** como **almacenamiento de objetos compatible con la API de Amazon S3** del homelab. Cubre el caso de uso "el servicio X necesita un _bucket_ donde subir / leer ficheros vía S3 (`PUT`, `GET`, `LIST`, `HEAD`, `DELETE`, `COPY`, _multipart_, _presigned URLs_)" sin tener que hablar con AWS, ni con Backblaze B2, ni con un proveedor de nube pública: la propia Pi expone un endpoint S3 local sobre TLS interna en `https://s3.lan/` y una consola web administrativa en `https://minio.lan/`.

En este homelab, MinIO actúa como **destino S3 genérico** para servicios que hablan S3 nativamente (Restic, _logs_ de Loki/Mimir cuando lleguen, dumps de bases de datos vía `aws s3 cp` desde _hooks_ de Borgmatic, _exports_ de Paperless, futuros despliegues de aplicaciones que pidan un _object store_…). Es **complementario** a Borgmatic (`docs/07-backups/02-borgmatic.md`): Borg habla un protocolo binario propio sobre SSH/local, no S3, y por tanto **no** usa MinIO como _backend_ directo. La relación entre los dos se documenta en **Decisiones de diseño → Relación con Borgmatic**: el caso típico es que el repositorio Borg vive en `/mnt/hd2t/backups/borg/`, y un _job_ de `mc mirror` o `rclone sync` copia la rama hacia un _bucket_ de MinIO que más tarde puede replicarse offsite (B2, S3, otra Pi en otra casa).

Este documento **extiende el _stack_ `almacen`** ya estrenado por Nextcloud (`docs/06-almacenamiento/01-nextcloud.md`) y ampliado por Samba (`docs/06-almacenamiento/02-samba.md`) y Syncthing (`docs/06-almacenamiento/03-syncthing.md`): el `~/homelab/almacen/docker-compose.yml` recibe un servicio `minio` adicional, conectado únicamente a la red `homelab` (no necesita `almacen-internal` — no habla con MariaDB ni con Redis), con dos puertos internos (9000 API, 9001 consola) que **nunca** se publican al host: Caddy los alcanza por DNS interno de Docker (`minio:9000`, `minio:9001`).

> **Alcance**: este documento despliega un único MinIO en modo **Single-Node Single-Drive (SNSD)** — un proceso, un volumen, sin _erasure coding_ ni replicación. Es el modo de despliegue **recomendado por MinIO para una sola Pi con un solo disco** (ver **Decisiones de diseño → Single-Node Single-Drive**). **No** despliega un _cluster_ MinIO multi-nodo (irrelevante con un único host). **No** activa _Site Replication_ ni _Bucket Replication_ a un _peer_ remoto (se documenta como sección separada cuando exista una segunda Pi o un endpoint B2/S3 offsite). **No** activa _Server-Side Encryption with Customer-Managed Keys_ (SSE-KMS) — sólo SSE-S3 con clave maestra en `.env` cuando el operador lo decida (sección opcional al final). Sí activa **versioning** en los _buckets_ que reciben backups (protección contra borrado accidental y _ransomware_-style sobre el filesystem expuesto).

> **Recordatorio de red**: ni la API S3 (puerto 9000) ni la consola (9001) se publican al host. Ambas son accesibles **sólo a través de Caddy**:
> - `https://s3.lan/` → API S3 (sin Authelia — los clientes S3 firman cada petición con AWS SigV4 y no entienden cookies de SSO).
> - `https://minio.lan/` → consola web administrativa (con Authelia — sólo la usan humanos desde un navegador).
>
> Pi-hole resuelve `s3.lan → 192.168.1.3` y `minio.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (`docs/03-red/02-pihole.md`). Caddy demultiplexa por SNI y enruta cada nombre al puerto correcto del contenedor. El acceso desde fuera de la LAN se hace por Tailscale (`docs/03-red/05-tailscale.md`): los clientes S3 se configuran con `endpoint=https://s3.lan` y, vía MagicDNS sobre la _tailnet_, alcanzan a la Pi sin abrir puertos.

---

## Requisitos previos

- `docs/00-hardware/03-preparacion-discos.md` completado: `hd2t` montado en `/mnt/hd2t` con ext4. MinIO **exige** un _filesystem_ POSIX con soporte de `xattr` para metadatos (etiquetas, _retention_, _legal hold_); ext4 los soporta de fábrica.
- `docs/01-sistema/04-estructura-directorios.md` completado: existe `/mnt/hd2t/services/minio/data/` vacío con ownership `1000:1000` (regla "imágenes que corren como UID 1000"; la imagen oficial de MinIO arranca con `USER 1000:1000` por defecto en _releases_ recientes — ver **Decisiones de diseño → Imagen**). En este documento se reutiliza el directorio sin más `mkdir`.
- `docs/01-sistema/03-seguridad-base.md` completado: el firewall `nftables` está activo con _input drop_ por defecto. **Este documento no añade reglas nuevas al firewall**: la API S3 y la consola viven detrás de Caddy (`443/tcp`, ya abierto) y MinIO no necesita puertos adicionales en el host.
- `docs/02-docker/02-estructura-compose.md` completado: la red `homelab` (`br-homelab`, `172.20.10.0/24`) externa existe, el `~/homelab/.env` global expone `TZ`, `PUID=1000`, `PGID=1000` y `HOMELAB_DOMAIN=lan`, y el _Makefile_ ofrece `make up STACK=almacen`.
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada. MinIO será **opt-out** explícito (justificación en **Decisiones de diseño → Watchtower opt-out**).
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `s3.lan` ni para `minio.lan` — el _wildcard_ ya los cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy`, `logging.caddy` y `authelia.caddy` existen, y la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile`. La CA local ya firma `*.lan`.
- `docs/03-red/05-tailscale.md` completado: la Pi tiene IP `100.x.y.z` en la _tailnet_ y `tailscale0` está activa. El acceso remoto a S3 / consola se hará por esa IP (vía MagicDNS y Caddy SNI), sin abrir puertos en el router.
- `docs/04-seguridad/01-authelia.md` completado: el _snippet_ `authelia.caddy` ya está rellenado, el portal `https://auth.lan/` funciona y los usuarios del `users_database.yml` pueden autenticarse con TOTP. Este documento añade `minio.lan` al `access_control` de Authelia (política `two_factor`); `s3.lan` queda **fuera** del control de Authelia (política `bypass`).
- `docs/06-almacenamiento/01-nextcloud.md` completado: el _stack_ `almacen` está vivo (`~/homelab/almacen/docker-compose.yml`, `.env`, `.env.example`, `.gitignore`). Este documento **añade** un servicio al mismo `docker-compose.yml`, no crea uno nuevo.
- Conectividad saliente para descargar la imagen (sólo la primera vez):

  ```bash
  docker pull --platform linux/arm64 \
    quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z \
    >/dev/null && echo OK

  docker pull --platform linux/arm64 \
    quay.io/minio/mc:RELEASE.2025-04-16T18-13-26Z \
    >/dev/null && echo OK
  ```

  Los _tags_ exactos se consultan en <https://github.com/minio/minio/releases> y <https://github.com/minio/mc/releases>; la convención del homelab prohíbe `:latest` (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**). Pinear a una _release_ datada concreta para que cualquier _bump_ de MinIO sea una decisión humana documentada.

---

## Decisiones de diseño

### Por qué MinIO (y no Garage / SeaweedFS / acceso S3 nativo del proveedor)

El homelab necesita **una API compatible con S3 dentro de la propia Pi**: que cualquier servicio que sepa hablar S3 pueda escribir/leer en `https://s3.lan/<bucket>/` exactamente igual que hablaría con `s3.amazonaws.com`. Cuatro candidatos descartados y por qué:

| Candidato       | Por qué se descarta                                                                                                                                                                                                                                |
|-----------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Garage**      | Diseño moderno (Rust, _erasure coding_ activable, replicación geo-distribuida), pero el caso de uso explícito de Garage es **multi-sitio con varias máquinas** (3 nodos como mínimo recomendado). Para un único host con un único disco, Garage añade complejidad operacional sin ventaja: el operador acaba aprendiendo concepto de _zone_, _replication factor_, _bootstrap peer_, etc., sólo para ejecutar un proceso solo. |
| **SeaweedFS**   | Object store + _filer_ + _master_ + _volume server_ = al menos 3 contenedores incluso para SNSD. Su API S3 es una capa superpuesta (no es el _core_), con pequeñas diferencias respecto a la spec de S3 que rompen algunos clientes (`mc`, `s3cmd` viejos). Excelente proyecto, pero exagera el _stack_ para este caso. |
| **API S3 directa de un proveedor (B2, R2, Wasabi)** | Saca _data_ de casa: cada `PUT` paga ancho de banda salida + almacenamiento por GB-mes. Para backups _offsite_ está perfecto (y se documenta en `docs/07-backups/01-estrategia-backup.md` como destino "remoto"). Para el _object store_ que viven todos los días los servicios del propio homelab, no tiene sentido — la Pi y el cliente están en la misma LAN. |
| **Filesystem nativo** (los servicios escriben directamente en `/mnt/hd2t/...`) | Funciona si **todos** los servicios soportan filesystem nativo. Pero muchos esperan S3 _de fábrica_ (Restic, Loki, Tempo, _backup operators_ de K8s, scripts que llaman `aws s3 cp` directamente), y reescribirlos para que usen filesystem es trabajo manual por servicio que se evita exponiendo S3 una vez. |

MinIO gana por:

- **API S3 _completa_ y _conformante_**: pasa los _tests_ oficiales de Amazon (`s3-tester`, `mc admin update`). Los clientes S3 (`aws s3`, `mc`, `s3cmd`, `rclone`, _SDKs_ de Python/Go/Rust/JS, Restic, Velero, …) hablan con MinIO sin distinguirlo de AWS.
- **Multi-arch ARM64** desde hace años, _release cycle_ rapidísimo (_release_ datada cada 1–3 semanas), binario Go estático, sin dependencias externas.
- **Single-Node Single-Drive (SNSD)** soportado oficialmente: un único proceso, un único volumen, sin sobrecargar la Pi. Modo _simple_ recomendado por MinIO para hosts individuales (ver siguiente sección).
- **Consola web administrativa** integrada (puerto 9001): gestión de _buckets_, políticas, usuarios, _service accounts_, _replication_, métricas. Cubre el 80 % de operaciones comunes; el otro 20 % se hace con `mc` (_command-line client_).
- **`mc` como CLI**: cliente oficial Go, sintaxis tipo `cp/mv/ls/rm/mirror/sync` familiar, lleva dentro toda la administración avanzada (`mc admin user`, `mc admin policy`, `mc replicate`, …).
- **Versioning de _buckets_**: protección contra borrado accidental al estilo S3 estándar (`X-Versioning: Enabled`). Cada `DELETE` deja un _delete marker_ en lugar de borrar el objeto; restaurar es un `mc cp --version-id <id>` o un click en consola.
- **Encryption at rest** opcional con SSE-S3 y clave maestra en `.env` (sección **Encryption at rest opcional** al final). Útil para cumplir "los datos en hd2t no son legibles si alguien roba el disco" sin tocar LUKS.
- **Compatibilidad con `aws s3`** _vainilla_ usando `--endpoint-url=https://s3.lan` y `--no-verify-ssl` (mientras la CA local no esté en el _trust store_ del cliente; ver `docs/03-red/04-caddy.md`).

### Imagen: `quay.io/minio/minio` y `quay.io/minio/mc`

| Imagen                         | Uso                                                                                                                                                | Convenciones                                                                                                                                                                                                                |
|--------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `quay.io/minio/minio` ✅       | Servidor (la imagen "principal"). Ejecuta el _daemon_ MinIO. Multi-arch ARM64 OK. _Releases_ datadas (`RELEASE.YYYY-MM-DDTHH-MM-SSZ`).             | Corre por defecto como `USER 1000:1000` en _releases_ recientes (ver Dockerfile upstream). Volumen `/data`. Puertos `:9000` (API S3) y `:9001` (consola web administrativa). _Entrypoint_ ya endurecido.                  |
| `quay.io/minio/mc` ✅          | Cliente CLI. Se usa para crear _buckets_, políticas, _service accounts_ y como ayudante de _scripts_ (`mc mirror`, `mc cp`).                       | Imagen mucho más pequeña (~80 MB). Ideal lanzarla _on-demand_ con `docker run --rm -it ... mc <comando>` o como _sidecar_ con un volumen para sus _aliases_. **No** se despliega como contenedor de larga duración — sólo se invoca cuando hace falta. |
| `docker.io/minio/minio`        | _Mirror_ en Docker Hub.                                                                                                                            | Funcionalmente idéntico a la imagen de quay.io. Se prefiere `quay.io/minio/minio` porque es el repo **canónico** del proyecto y no está sometido a los _rate limits_ de Docker Hub para usuarios anónimos.                                                                                |

_Tag_ pinneado a una _release_ exacta (ej. `quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z`). MinIO **no** publica _tags_ tipo `:latest` estables — sólo _releases_ datadas y `:edge` (no recomendado en producción).

> **Por qué `quay.io` y no `docker.io`**: el repo "oficial-oficial" del proyecto es `quay.io/minio/minio`. Es el primero que se actualiza tras un _release_ (el de Docker Hub es _mirror_ posterior). Para evitar la ventana de inconsistencia y los _rate limits_ de Docker Hub, se usa `quay.io` en todo el homelab cuando el proyecto upstream lo ofrezca.

### Watchtower opt-out

Razones:

- MinIO publica _releases_ con cadencia rapidísima (a veces varias por semana). Aplicarlas automáticamente cada noche es **un cambio mayor diario** sobre un servicio que aloja datos críticos (los _buckets_ de backup pueden ser la única copia _offsite_ de la base de datos de Vaultwarden y de Nextcloud).
- Aunque MinIO mantiene **compatibilidad de formato en disco hacia atrás** dentro de una serie de _releases_, históricamente **se han eliminado funcionalidades enteras entre _releases_** sin _deprecación_ larga: el _gateway mode_ (proxy a S3, GCS, Azure) se eliminó en 2022; el _backend FS_ legacy se marcó como _deprecated_ en 2024; la consola fue reescrita en varios _major_ rewrites del propio _frontend_. Un `pull` automático un domingo a las 4 AM puede llegar con sorpresas que el operador descubra el lunes.
- El _downgrade_ a una _release_ anterior **no está soportado oficialmente**: MinIO escribe metadatos (`xl.meta`, `format.json`) en formatos que pueden evolucionar. El _rollback_ funciona en muchos casos pero no es contractual.
- El servicio responde a peticiones S3 _en vuelo_; un `docker compose up -d minio` durante un `mc mirror` masivo aborta la subida y deja _multipart uploads_ huérfanos (`mc admin trace` los limpia, pero es ruido).

Etiquetar el contenedor con `com.centurylinklabs.watchtower.enable: "false"`. Las actualizaciones se hacen leyendo el _changelog_ (<https://github.com/minio/minio/releases>) y, si hay cambios de formato anunciados, ejecutando un backup _on-demand_ de `/mnt/hd2t/services/minio/data/` antes de aplicar.

### Single-Node Single-Drive (SNSD)

MinIO admite cuatro modos de despliegue:

| Modo                                | Nodos | Drives/nodo | _Erasure_                       | Caso de uso                                                                                                                                            |
|-------------------------------------|-------|-------------|---------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Single-Node Single-Drive (SNSD)** ✅ | 1     | 1           | No (un único disco)             | "Una Pi con un único HDD". Recomendación oficial para hosts individuales. **Elección del homelab**.                                                    |
| Single-Node Multi-Drive (SNMD)      | 1     | ≥2 (par)    | Sí (sobre los drives del nodo)  | Servidor con varios discos físicos. Si la Pi tuviera 2 HDDs idénticos, SNMD permitiría sobrevivir a la pérdida de un disco. No es el caso (hd2t y hd5t son discos de **propósitos distintos**, no _peers_ de _erasure_). |
| Multi-Node Multi-Drive (MNMD)       | ≥4    | ≥2          | Sí (entre nodos)                | _Cluster_ tipo "rack". Irrelevante.                                                                                                                    |
| Distributed con 3 nodos             | 3     | ≥1          | Sí (limitado)                   | Versión "mínima distribuida". Irrelevante con una sola Pi.                                                                                             |

El modo SNSD se activa pasando un único path como `MINIO_VOLUMES`:

```env
MINIO_VOLUMES=/data
```

Consecuencias:

- **Tolerancia a fallo del disco**: cero. Si hd2t muere, todos los _buckets_ se pierden. Por eso los _buckets_ críticos van a Borgmatic (`/mnt/hd2t/services/minio/data/` entra en el _set_ "data"), y los datos almacenados deben tratarse como "de un solo disco" hasta que existan _site replication_ a un proveedor offsite.
- **Sin _erasure coding_**: cada objeto se guarda como un fichero plano + un `xl.meta` con sus metadatos. Tamaño total ≈ tamaño de los objetos + ~5 % de overhead.
- **Sin _healing_** (rebuild de objetos perdidos a partir de paridad): no hay paridad. Pero `mc admin heal` igualmente revisa que cada `xl.meta` cuadre con el fichero — útil tras una caída brusca.
- **Sin _site replication_** todavía: cuando exista una segunda Pi (o un B2/S3 _bucket_ remoto), `mc replicate` crea replicación bidireccional o "_one-way_" a nivel _bucket_. El modo SNSD lo soporta como origen.

> **¿Y si en el futuro se añade un segundo HDD?** Pasar de SNSD a SNMD **no es un upgrade _in-place_**: SNMD requiere un re-formateo del _backend_ MinIO (los _drives_ se inicializan como un _erasure set_ atómico). El procedimiento es: `mc mirror` los _buckets_ a un destino temporal (S3 externo o B2), reformatear MinIO con los dos drives, `mc mirror` de vuelta. Documentado como sección "Migración SNSD → SNMD" cuando llegue ese hardware (no en este doc).

### Modo de red: `bridge` en `homelab`, **sin** `almacen-internal` y **sin** `host`

| Modo                 | API S3 vía Caddy                   | Consola vía Caddy             | Comunicación interna             | Veredicto                                                                       |
|----------------------|------------------------------------|-------------------------------|----------------------------------|---------------------------------------------------------------------------------|
| `bridge` + `homelab` ✅ | Sí (`reverse_proxy minio:9000`)    | Sí (`reverse_proxy minio:9001`) | No necesita BD ni Redis          | **Elección del homelab**. Coherente con Nextcloud, Authelia, Pi-hole, Syncthing. |
| `host`               | Necesitaría `host.docker.internal` | Igual                         | Igual                            | Funciona pero rompe la convención "el _front_ se alcanza por nombre en `homelab`". Sin ventaja: MinIO no necesita _multicast_ ni acceder a la pila de red del host.       |
| `macvlan` con IP propia | Sí (vía Caddy)                  | Sí                            | Igual                            | Cumple, pero pide otra IP de la LAN para un servicio que no la necesita. No se justifica.                                                                              |

Y, dentro del _stack_ `almacen`:

- **Sólo `homelab`, no `almacen-internal`**: MinIO **no habla** con MariaDB (Nextcloud) ni con Redis (Nextcloud). Los _buckets_ se acceden vía HTTP S3 desde clientes externos al contenedor — no hay tráfico interno _stack-private_. Mantener MinIO fuera de `almacen-internal` reduce la superficie de ataque (un MinIO comprometido no llega a la BD de Nextcloud) y simplifica el modelo.

Consecuencias prácticas:

- **API S3**: Caddy hace `reverse_proxy minio:9000` por DNS interno de Docker. La API nunca se expone al host directamente (`9000` no aparece en `ports:`).
- **Consola**: Caddy hace `reverse_proxy minio:9001`. Igual que la API, no se expone al host.
- **Acceso desde otros stacks**: cuando un servicio en otro _stack_ (ej. Loki en `monitorizacion`, Restic-runner en `backups`) necesite hablar con MinIO, lo hará por **DNS de Docker** (`minio:9000` desde dentro de la red `homelab`) o por **DNS del homelab** (`s3.lan` vía Caddy, con TLS). La opción "vía Caddy" tiene la ventaja de que las credenciales (AccessKey/SecretKey) ya viajan sobre TLS interno aunque el cliente esté en otro contenedor.

### `forward_auth` con Authelia: consola SÍ, API NO

Asunto crítico. Las dos rutas tienen comportamientos distintos:

| Ruta            | Consumidor                                | Autenticación nativa                                                  | Authelia delante                                                                                                                                                       |
|-----------------|-------------------------------------------|-----------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `s3.lan` (9000) | Clientes S3 (`aws s3`, `mc`, Restic, …)   | **AWS SigV4** (firma HMAC sobre `Authorization: AWS4-HMAC-SHA256 ...`) | **NO**. Authelia espera cookies `authelia_session` o un _redirect_ a `auth.lan`. Los clientes S3 no soportan ni cookies ni redirects HTML. _Romperían todos los clientes._ |
| `minio.lan` (9001) | Humanos en navegador                     | Login propio de la consola (root user / IAM user / OIDC opcional)     | **SÍ**. La consola es HTTP puro y la usan personas. Authelia añade TOTP de fábrica antes de llegar al login propio de MinIO. Defensa en profundidad coherente con Syncthing. |

Configuración:

- En el `Caddyfile`, el bloque `s3.lan` **no** lleva `import authelia`.
- En el `Caddyfile`, el bloque `minio.lan` **sí** lleva `import authelia`.
- En `~/homelab/seguridad/authelia/configuration.yml`, `access_control.rules` añade dos reglas:
  - `domain: s3.lan` → `policy: bypass` (S3 no es para humanos).
  - `domain: minio.lan` → `policy: two_factor` (igual que `portainer.lan`, `vaultwarden.lan`, etc.).

> **Por qué `bypass` y no _omitir_ el bloque entero**: si `s3.lan` no tuviera regla explícita en Authelia, caería en `default_policy: deny` (ver `docs/04-seguridad/01-authelia.md`) y Authelia respondería 403 en cualquier _forward_auth_. Como en `s3.lan` el bloque del `Caddyfile` **no invoca** `forward_auth` siquiera, en la práctica no se llega a Authelia y el `default_policy` es irrelevante para esa ruta. La regla `bypass` está **por explicitud documental** — deja claro a quien lea la config que `s3.lan` queda intencionadamente sin SSO.

### Endpoints separados: `s3.lan` (API) y `minio.lan` (Consola)

En lugar de exponer un único nombre `minio.lan` con la API en `/` y la consola en `/console/` (que MinIO también soporta vía `MINIO_BROWSER_REDIRECT_URL`), se publican **dos nombres distintos** en Caddy. Razones:

- **Authelia**: con dos nombres distintos, la decisión de "consola con SSO, API sin SSO" se hace a nivel de bloque en Caddy, sin _path matchers_ ni `not path` complejos. La regla del `Caddyfile` queda trivial.
- **Independencia**: si en el futuro se quita la consola (`MINIO_BROWSER=off`) o se reemplaza por una alternativa (DirectAdmin, etc.), `s3.lan` no se ve afectado.
- **Logs**: las trazas en Caddy quedan separadas (`s3.lan/access.log` muestra `PUT /borg/...`, `minio.lan/access.log` muestra clicks de la UI). Útil para depurar.
- **Convención S3**: muchos clientes S3 esperan que el _endpoint_ sea sólo el _hostname:port_ y la ruta sea `/<bucket>/<key>`. Exponer la API en `s3.lan/` (raíz) es lo más compatible. Path-style (`s3.lan/<bucket>/`) y virtual-hosted-style (`<bucket>.s3.lan/`) son ambos soportados; el path-style es el _default_ moderno.

Tabla de los dos endpoints:

| Endpoint                | Puerto interno | Caddy bloque | Authelia | Consumidor                                |
|-------------------------|----------------|--------------|----------|-------------------------------------------|
| `https://s3.lan/`       | 9000 (API S3)  | `s3.lan`     | **No**   | Restic, `mc`, `aws s3`, _SDKs_, Borgmatic _hooks_ |
| `https://minio.lan/`    | 9001 (Consola) | `minio.lan`  | **Sí**   | Operador en navegador                     |

### Relación con Borgmatic

- **Borgmatic** (`docs/07-backups/02-borgmatic.md`) es el **motor principal de backups** del homelab. Borg habla un protocolo binario propio (no S3) sobre SSH o sobre _filesystem_ local. El repo Borg vive en `/mnt/hd2t/backups/borg/<repo>/`.
- **MinIO** es un _object store_ S3 genérico que **complementa** a Borgmatic en dos casos:
  1. **Servicios que dumpean directamente a S3**: por ejemplo, un _hook_ `before_backup` de Borgmatic que ejecuta `mariadb-dump | gzip | aws s3 cp - s3://minio-dumps/nextcloud/$(date +%F).sql.gz` deja una copia _adicional_ del dump en MinIO antes de que Borg lo procese. Si el repo Borg se corrompe, los dumps S3 quedan como fallback.
  2. **Replicación offsite**: una vez que Borg ha producido el repo cifrado (que ya es _self-contained_ y _deduplicado_), un _job_ posterior de `rclone sync /mnt/hd2t/backups/borg/ minio:borg-mirror/` deja una copia _bit-a-bit_ del repo en un _bucket_ de MinIO. Ese _bucket_ puede a su vez replicarse por `mc replicate` a un B2/S3 público para cumplir la regla 3-2-1 (`docs/07-backups/01-estrategia-backup.md`).
- **MinIO como _backend_ directo de Borg**: **no** soportado. Borg requiere _filesystem_ POSIX o `borg serve` por SSH. Hay proyectos terceros que exponen S3 como FUSE (`s3fs`, `goofys`) pero introducen latencia y _flakiness_ que Borg no perdona en repos grandes. La estrategia "Borg → filesystem local + sync a MinIO" es la limpia.

### Almacenamiento

| Ruta en el host                                          | Contenido                                              | Versionable | Backup                                  |
|----------------------------------------------------------|--------------------------------------------------------|-------------|-----------------------------------------|
| `~/homelab/almacen/docker-compose.yml`                   | Definición del _stack_ (extendida con `minio`)         | git         | git                                     |
| `~/homelab/almacen/.env`                                 | _Tag_ de la imagen + credenciales root + KMS secret    | **NO** (`.gitignore`) | nota local; replicado en Vaultwarden  |
| `/mnt/hd2t/services/minio/data/`                         | _Buckets_, objetos, `xl.meta`, `format.json`           | **NO**      | **Sí** (Borgmatic — _set_ "data", retención por uso) |

> **Por qué `data/` entra en Borgmatic**: en SNSD no hay redundancia. Si hd2t muere, todos los _buckets_ se pierden. Borg restaura los datos al estado del último _snapshot_, lo que es suficiente para los casos de uso del homelab (los _buckets_ contienen mayoritariamente backups de otros servicios, que también se pueden regenerar — pero el coste de regenerarlos es muy alto: re-correr todos los `mariadb-dump`, etc.).

> **Aviso sobre `format.json`**: el fichero `/mnt/hd2t/services/minio/data/.minio.sys/format.json` identifica al _backend_ MinIO de forma única (UUID generado en el primer arranque). **No** borrarlo nunca. Si se restaura `data/` desde Borg pero el `format.json` no coincide con el del _runtime_, MinIO arranca con error `Drive not formatted`. Lo importante: restaurar **junto** todo el árbol `.minio.sys/` para preservar identidad.

> **Aviso sobre tamaño**: si MinIO se usa como destino de backups grandes (un repo Borg de 100 GB replicado completo), `data/` puede crecer rápido. Antes de habilitar versioning agresivo en _buckets_ con _churn_ alto, leer la sección **Configuración → Activar versioning** y dimensionar la retención.

---

## Estructura del _stack_ `almacen` tras este documento

```
~/homelab/almacen/
├── docker-compose.yml        # ← extendido con servicio 'minio'
├── .env                      # ← extendido con MINIO_*
├── .env.example              # ← extendido (sin valores reales)
├── .gitignore                # ya existía
└── smb/
    └── smb.conf              # creado en 02-samba.md
```

Y en el disco externo, sobre lo ya creado por `04-estructura-directorios.md`:

```
/mnt/hd2t/services/minio/
└── data/                     # ya existe, ownership 1000:1000
```

Verificar que el directorio está correctamente preparado (idempotente, no hace falta ejecutarlo si `04-estructura-directorios.md` se siguió al pie de la letra):

```bash
sudo mkdir -p /mnt/hd2t/services/minio/data
sudo chown -R 1000:1000 /mnt/hd2t/services/minio
sudo chmod 0750 /mnt/hd2t/services/minio/data
```

> **`0750` (no `0755`)**: dentro de `data/` viven credenciales y objetos potencialmente sensibles. Restringir el _world bit_ desde el host añade una pequeña capa de defensa en profundidad. El proceso MinIO corre como UID `1000`, así que el _owner_ tiene rwx; el grupo (también `1000`) tiene rx; otros nada. Suficiente.

---

## Variables de entorno

Añadir al final de `~/homelab/almacen/.env.example` (versionado, sin valores reales):

```bash
# --- MinIO -----------------------------------------------------------------
# Imágenes pinneadas — consultar releases para la más reciente:
# https://github.com/minio/minio/releases
# https://github.com/minio/mc/releases
MINIO_IMAGE_TAG=RELEASE.2025-04-22T22-12-26Z
MC_IMAGE_TAG=RELEASE.2025-04-16T18-13-26Z

# Credenciales del usuario root de MinIO. NO usar para servicios — el root
# se reserva para administración (consola, mc admin). Las credenciales de
# servicios (Restic, Loki, scripts de backup, …) se generan después como
# 'service accounts' (mc admin user svcacct add) con permisos limitados al
# bucket que necesiten.
#
# Generar con:
#   openssl rand -base64 24 | tr -d '/+=' | head -c 24   # access key
#   openssl rand -base64 48 | tr -d '/+=' | head -c 40   # secret key
#
# Mínimos requeridos por MinIO: access >= 3 chars, secret >= 8 chars.
# El homelab usa 24/40 para tener margen de entropía.
MINIO_ROOT_USER=
MINIO_ROOT_PASSWORD=

# URL pública de la consola web. MinIO la usa para construir redirects
# tras login (de localhost:9001 al nombre real). Coincide con el bloque
# del Caddyfile que se añade en este mismo documento.
MINIO_BROWSER_REDIRECT_URL=https://minio.lan

# URL pública de la API S3. MinIO la incluye en respuestas HEAD/PUT que
# llevan 'Location' (multipart, presigned URLs) para que los clientes
# sigan hablando con el endpoint correcto en lugar de localhost:9000.
MINIO_SERVER_URL=https://s3.lan

# Region — se usa al firmar SigV4. 'us-east-1' es el default que asumen
# casi todos los clientes; mantenerlo evita configuración extra en cada
# cliente. No tiene relación con la geografía real.
MINIO_REGION=us-east-1
```

Generar las credenciales root y añadirlas al `.env`:

```bash
cd ~/homelab/almacen

mio_user=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
mio_pass=$(openssl rand -base64 48 | tr -d '/+=' | head -c 40)

{
  echo ""
  echo "# --- MinIO ---"
  echo "MINIO_IMAGE_TAG=RELEASE.2025-04-22T22-12-26Z"
  echo "MC_IMAGE_TAG=RELEASE.2025-04-16T18-13-26Z"
  echo "MINIO_ROOT_USER=$mio_user"
  echo "MINIO_ROOT_PASSWORD=$mio_pass"
  echo "MINIO_BROWSER_REDIRECT_URL=https://minio.lan"
  echo "MINIO_SERVER_URL=https://s3.lan"
  echo "MINIO_REGION=us-east-1"
} >> .env

chmod 0600 .env

echo "MinIO root user: $mio_user"
echo "MinIO root pass: $mio_pass"
unset mio_user mio_pass
```

Anotar las credenciales y guardarlas en Vaultwarden cuando llegue su fase. Hasta entonces, una nota cifrada en el _password manager_ del operador.

> **`tr -d '/+='`**: el secret key viaja en cabeceras `Authorization` y en _query strings_ de _presigned URLs_, donde `/`, `+` y `=` requieren _percent-encoding_ (`%2F`, `%2B`, `%3D`). Algunos clientes S3 viejos no lo hacen bien y rompen al firmar. Eliminar esos caracteres del alfabeto evita el problema sin reducir significativamente la entropía (40 chars Base64 menos 3 chars sobre alfabeto de 61 ≈ 238 bits — sobrado).

---

## `~/homelab/almacen/docker-compose.yml`: añadir `minio`

Editar el `docker-compose.yml` ya creado por `01-nextcloud.md` (extendido por `02-samba.md` y `03-syncthing.md`) y añadir, **bajo la clave `services:`**, el siguiente bloque al final (tras `syncthing`):

```yaml
  # ---------------------------------------------------------------------------
  # MinIO — almacenamiento de objetos compatible con S3.
  # API S3 en :9000, consola web en :9001. Ambas se alcanzan por nombre
  # 'minio:9000' y 'minio:9001' desde Caddy (red 'homelab').
  # No se publica nada al host: todo el tráfico pasa por Caddy en :443.
  # No participa en 'almacen-internal' (no necesita BD ni Redis).
  # ---------------------------------------------------------------------------
  minio:
    image: quay.io/minio/minio:${MINIO_IMAGE_TAG}
    container_name: minio
    hostname: minio
    restart: unless-stopped
    # La imagen oficial corre por defecto como UID:GID 1000:1000. Lo dejamos
    # explícito por claridad y para sobrevivir a un cambio del default upstream.
    user: "1000:1000"
    command:
      - server
      - /data
      - --address
      - ":9000"            # API S3
      - --console-address
      - ":9001"            # Consola web administrativa
    environment:
      TZ: ${TZ}
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
      MINIO_BROWSER_REDIRECT_URL: ${MINIO_BROWSER_REDIRECT_URL}
      MINIO_SERVER_URL: ${MINIO_SERVER_URL}
      MINIO_REGION: ${MINIO_REGION}
      # Único volumen — modo Single-Node Single-Drive (SNSD).
      MINIO_VOLUMES: /data
      # Política de identidad anónima por defecto: sin acceso. Cualquier
      # bucket que se quiera dejar público requerirá 'mc anonymous set'.
      MINIO_BROWSER_LOGIN_ANIMATION: "off"
    volumes:
      - /mnt/hd2t/services/minio/data:/data
    networks:
      homelab:
        aliases:
          - minio              # Caddy resuelve 'minio:9000' y 'minio:9001'
    labels:
      homelab.stack: "almacen"
      homelab.backup: "true"   # /mnt/hd2t/services/minio/data (Borgmatic)
      # Opt-out: bumps cambian formato y/o retiran APIs. Manual.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      # /minio/health/live es el endpoint oficial. Responde 200 si el server
      # está vivo y los drives son accesibles. Cualquier otra cosa = unhealthy.
      test:
        - CMD-SHELL
        - "curl -fsS -o /dev/null -w '%{http_code}' http://localhost:9000/minio/health/live | grep -q '^200$'"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
```

Notas de diseño:

- **Sólo `homelab`, no `almacen-internal`**: ver **Decisiones de diseño**. MinIO no habla con MariaDB ni Redis del propio _stack_.
- **Sin `ports:`**: ni `9000` ni `9001` se publican al host. Todo el acceso pasa por Caddy. Si se quisiera dar acceso "raw" desde la LAN (por ejemplo, para un cliente S3 que no sepa hablar HTTPS interno), hay que abrir explícitamente `9000:9000` y abrir `nftables` en `tcp/9000` desde la LAN. **No recomendado** — se pierde TLS y se rompe la simetría con el resto del _stack_.
- **`user: "1000:1000"`**: la imagen oficial _ya_ corre como `1000:1000`, pero declararlo explícitamente:
  - Sobrevive a cambios del default upstream sin avisar.
  - Hace evidente al lector del compose qué UID escribe en el _bind mount_, sin tener que mirar el Dockerfile.
- **Sin `cap_add` ni `privileged`**: MinIO no necesita capabilities Linux extra. El proceso es un binario Go puro.
- **Sin `depends_on`**: MinIO es independiente del resto del _stack_. Si Nextcloud está parado, MinIO sigue sirviendo objetos.
- **Healthcheck por `/minio/health/live`**: endpoint oficial, ya documentado por upstream. No requiere autenticación (es público por diseño, igual que `/livez` en Kubernetes). Si MinIO está iniciando, devuelve 503; cuando los drives están listos, 200.
- **`MINIO_SERVER_URL` y `MINIO_BROWSER_REDIRECT_URL`**: críticos para que MinIO genere _presigned URLs_ y _redirects_ con el _hostname_ correcto. Sin ellos, los clientes recibirían URLs como `http://localhost:9000/...` o `http://minio:9000/...` que no se pueden alcanzar desde fuera de la red Docker.

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/almacen

# Validar que la sintaxis del compose extendido sigue OK
docker compose --env-file ../.env --env-file .env config minio | head -50

# Levantar el servicio (el resto del stack ya está en marcha; Compose
# reconcilia y crea sólo el contenedor 'minio').
docker compose --env-file ../.env --env-file .env up -d minio
```

O, equivalente, con el _Makefile_:

```bash
cd ~/homelab
make up STACK=almacen
```

Comprobar el primer arranque:

```bash
docker logs minio --tail 30
# MinIO Object Storage Server
# Copyright: ...
# Version: RELEASE.2025-04-22T22-12-26Z (linux/arm64)
#
# API: http://172.20.10.X:9000  http://127.0.0.1:9000
# WebUI: http://172.20.10.X:9001 http://127.0.0.1:9001
#
# Docs: https://docs.min.io
docker compose -f ~/homelab/almacen/docker-compose.yml ps minio
# NAME    STATUS                   PORTS
# minio   Up X seconds (healthy)
```

Verificar que el `format.json` se ha creado:

```bash
ls -la /mnt/hd2t/services/minio/data/.minio.sys/format.json
# -rw------- 1 homelab homelab 234 ... format.json
```

> **Si aparece** `ERROR Unable to initialize backend: drive not found at /data`: comprobar que `/mnt/hd2t/services/minio/data/` existe y es propiedad de `1000:1000`. Reaplicar `chown -R 1000:1000 /mnt/hd2t/services/minio` si hace falta.

> **Si aparece** `chown: changing ownership of '/data': Permission denied` o similar: la imagen actual ejecuta como `1000:1000` pero el _entrypoint_ intenta normalizar permisos en `/data`. Asegurar que el _bind mount_ ya está con la ownership correcta antes de levantarlo.

### Caddy: bloques `s3.lan` y `minio.lan`

Editar `~/homelab/red/Caddyfile` y añadir los **dos** bloques (tras los bloques ya existentes — ver `docs/03-red/04-caddy.md`, `docs/04-seguridad/01-authelia.md` y `docs/06-almacenamiento/03-syncthing.md`):

```caddyfile
# ----------------------------------------------------------------------------
# MinIO — API S3.
# Sin Authelia: los clientes S3 firman cada petición con SigV4 y no soportan
# cookies ni redirects. Cualquier otro chequeo iría dentro de MinIO (IAM).
# Buffering desactivado y request_body sin límite para que multipart uploads
# de varios GB no fallen por timeout o por buffer en Caddy.
# ----------------------------------------------------------------------------
s3.lan {
    tls internal
    import security-headers
    import logging

    # Subidas grandes — sin límite por defecto en Caddy 2 ya, pero explícito
    # por documentación y para que el lector sepa que NO debería tocar esto.
    request_body {
        max_size 0
    }

    reverse_proxy minio:9000 {
        # MinIO valida el Host header al firmar las respuestas. Pasarle el
        # original ('s3.lan') hace que sus presigned URLs incluyan ese host
        # y los clientes resuelvan correctamente.
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # No buffer the response — multipart uploads y respuestas streaming
        # (LIST de buckets enormes, GET de objetos grandes) deben pasar tal
        # cual sin que Caddy los acumule en memoria.
        flush_interval -1

        transport http {
            # Subidas/descargas grandes pueden tardar minutos. Sin esto,
            # Caddy corta el flujo a los 30 s por defecto.
            read_timeout 30m
            write_timeout 30m
        }
    }
}

# ----------------------------------------------------------------------------
# MinIO — Consola web administrativa.
# CON Authelia (TOTP) delante: la consola es HTTP puro y la usan humanos.
# ----------------------------------------------------------------------------
minio.lan {
    tls internal
    import security-headers
    import logging
    import authelia

    reverse_proxy minio:9001 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # La consola usa WebSockets para la pestaña 'Monitoring'. Caddy 2
        # los maneja transparentemente, pero subir el read_timeout evita
        # desconexiones espurias.
        transport http {
            read_timeout 10m
        }
    }
}
```

Validar y recargar Caddy:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

### Authelia: añadir `minio.lan` al `access_control`

Editar `~/homelab/seguridad/authelia/configuration.yml` y añadir, en `access_control.rules`, una entrada para `minio.lan`:

```yaml
access_control:
  default_policy: deny
  rules:
    # ... reglas existentes (auth.lan: bypass, portainer.lan: two_factor, ...) ...
    - domain:
        - 'minio.lan'
      policy: two_factor
    # 's3.lan' NO se lista aquí: su bloque del Caddyfile no invoca Authelia.
```

Recargar Authelia:

```bash
docker compose -f ~/homelab/seguridad/docker-compose.yml restart authelia
```

### Probar los dos endpoints

```bash
# API S3 — debería devolver 403 con un body XML 'AccessDenied' (es la respuesta
# correcta para una petición sin firma SigV4 en una request anónima)
curl -k --resolve s3.lan:443:192.168.1.3 -i https://s3.lan/
# HTTP/2 403
# Content-Type: application/xml
# <Error><Code>AccessDenied</Code>...

# Consola — debería devolver 302 hacia auth.lan (Authelia activo)
curl -k --resolve minio.lan:443:192.168.1.3 -I https://minio.lan/
# HTTP/2 302
# Location: https://auth.lan/?rd=...
```

Y desde el navegador: `https://minio.lan/` → portal Authelia → tras autenticarse, la consola de MinIO pide _login_ (root user / password del `.env`).

---

## Configuración tras primer arranque

### Configurar el alias `mc` para gestionar MinIO

`mc` es el cliente CLI oficial de MinIO. En lugar de instalarlo en el host, se invoca _on-demand_ como contenedor efímero. Para no repetir las credenciales en cada llamada, se usa un **alias** persistido en un volumen Docker:

```bash
# Crear un volumen efímero compartido entre invocaciones de mc
docker volume create mc-config

# Añadir el alias 'local' apuntando a la API interna de MinIO. La invocación
# 'mc' va por la red 'homelab' (DNS interno) — no pasa por Caddy ni TLS.
# El secret se inyecta por env para no quedar en docker logs.
docker run --rm \
  --network homelab \
  -v mc-config:/root/.mc \
  -e MC_HOST_local=http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@minio:9000 \
  --env-file ~/homelab/almacen/.env \
  quay.io/minio/mc:${MC_IMAGE_TAG} \
  alias set local http://minio:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD}

# Verificar
docker run --rm \
  --network homelab \
  -v mc-config:/root/.mc \
  --env-file ~/homelab/almacen/.env \
  quay.io/minio/mc:${MC_IMAGE_TAG} \
  admin info local
# ●  minio:9000
#    Uptime: ...
#    Version: ...
#    Drives: 1/1 OK
```

Para no repetir el _boilerplate_ en cada invocación, definir un _alias_ de shell en el _user_ del operador:

```bash
cat >> ~/.bashrc <<'EOF'
# mc dentro de un contenedor efímero, con alias 'local' ya configurado en el volume
mc() {
  docker run --rm -i \
    --network homelab \
    -v mc-config:/root/.mc \
    quay.io/minio/mc:RELEASE.2025-04-16T18-13-26Z \
    "$@"
}
EOF
source ~/.bashrc

# Probar
mc alias list
# local
#   URL       : http://minio:9000
#   AccessKey : ...
#   SecretKey : ...
#   API       : s3v4
#   Path      : auto
mc admin info local
```

> **Por qué `http://` y no `https://s3.lan` en el alias**: el alias se usa _desde dentro_ de la red Docker `homelab`, donde `minio:9000` es alcanzable directo sin pasar por Caddy. Hablar HTTP plano dentro de la red interna es legítimo (toda la red está en `172.20.10.0/24`, no sale al exterior). Si se quisiera operar `mc` _desde fuera_ de la Pi (portátil del operador), el alias se haría con `https://s3.lan` y la CA local importada en el cliente `mc` (sección **Acceso desde el portátil con `mc`** más abajo).

### Crear el primer _bucket_ y un _service account_ dedicado

Caso de uso: un servicio (ej. el _runner_ futuro de Restic) necesita un _bucket_ propio donde subir snapshots, con permisos sólo a ese _bucket_. **No** se le da la credencial root.

1. Crear el _bucket_:

   ```bash
   mc mb local/restic-snapshots
   # Bucket created successfully `local/restic-snapshots`.
   ```

2. Activar **versioning** (recomendado para _buckets_ que reciben datos críticos: cualquier `DELETE` queda como _delete marker_, recuperable):

   ```bash
   mc version enable local/restic-snapshots
   # local/restic-snapshots versioning is enabled
   ```

3. Crear una **policy** que limite el acceso al _bucket_:

   ```bash
   cat > /tmp/policy-restic-snapshots.json <<'EOF'
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "s3:GetBucketLocation",
           "s3:ListBucket",
           "s3:GetObject",
           "s3:PutObject",
           "s3:DeleteObject",
           "s3:AbortMultipartUpload",
           "s3:ListMultipartUploadParts",
           "s3:GetBucketVersioning",
           "s3:ListBucketVersions"
         ],
         "Resource": [
           "arn:aws:s3:::restic-snapshots",
           "arn:aws:s3:::restic-snapshots/*"
         ]
       }
     ]
   }
   EOF

   docker cp /tmp/policy-restic-snapshots.json $(docker run -d --rm \
     --network homelab \
     -v mc-config:/root/.mc \
     quay.io/minio/mc:${MC_IMAGE_TAG} sleep 3600):/tmp/

   mc admin policy create local restic-snapshots-rw /tmp/policy-restic-snapshots.json
   ```

   _(En la práctica el `docker cp` se reemplaza por `mc admin policy create local <name> -` con stdin, ver troubleshooting; aquí el ejemplo es explícito.)_

4. Crear un **service account** ligado a esa policy. _Service accounts_ son pares (AccessKey, SecretKey) que no son usuarios IAM completos — sólo se usan para autenticar peticiones S3 desde un servicio:

   ```bash
   svc_access=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
   svc_secret=$(openssl rand -base64 48 | tr -d '/+=' | head -c 40)

   mc admin user svcacct add local ${MINIO_ROOT_USER} \
     --access-key "$svc_access" \
     --secret-key "$svc_secret" \
     --policy restic-snapshots-rw \
     --description "Restic snapshots writer"

   echo "Restic access key: $svc_access"
   echo "Restic secret key: $svc_secret"
   unset svc_access svc_secret
   ```

5. Verificar:

   ```bash
   mc admin user svcacct list local ${MINIO_ROOT_USER}
   # ACCESS KEY              EXPIRATION                    NAME
   # AAAAAAAAAAAAAAAA         no-expiration                 Restic snapshots writer
   ```

6. Probar el service account desde un _peer_ con `mc`:

   ```bash
   mc alias set test-restic http://minio:9000 "$svc_access" "$svc_secret"
   mc ls test-restic/
   # [DATE]    0B restic-snapshots/      ← visible
   mc ls test-restic/otro-bucket/
   # mc: <ERROR> Unable to list folder. Access Denied.   ← correcto
   ```

> Anotar las credenciales del _service account_ en el `.env` del _stack_ que las consume (cuando llegue su fase). **Nunca** compartir el `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` con un servicio.

### Sembrar _buckets_ del homelab

Crear los _buckets_ que ya se sabe que harán falta. Esto **no** los pone en uso — sólo los reserva con la política correcta:

```bash
# Bucket para mirror del repo Borg (replicación offsite local)
mc mb local/borg-mirror
mc version enable local/borg-mirror

# Bucket para dumps de bases de datos (hooks de Borgmatic)
mc mb local/db-dumps
mc version enable local/db-dumps
mc ilm rule add local/db-dumps \
  --expire-days 90 \
  --noncurrent-expire-days 30
# Lifecycle: dumps actuales caducan a 90 días, versiones obsoletas a 30.
# Evita que el bucket crezca indefinidamente con dumps diarios.

# Bucket genérico para servicios que pidan S3 más adelante
mc mb local/services-misc
```

> **Lifecycle policies (`mc ilm rule`)**: equivalente a "S3 Lifecycle". Útil para caducar objetos y versiones automáticamente. Evita backups diarios sin límite. Documentar en cada caso de uso (Restic, Borgmatic _hooks_, etc.) la política aplicada.

### Activar el _Object Lock_ en _buckets_ críticos (opcional)

_Object Lock_ es la versión "WORM" de S3: durante un periodo definido, ningún objeto puede borrarse — ni siquiera por el root. **Sólo se puede activar al crear el _bucket_**, no a posteriori.

```bash
# Crear un bucket WORM con lock activado por defecto y retención de 30 días
mc mb --with-lock local/db-dumps-immutable
mc retention set --default GOVERNANCE 30d local/db-dumps-immutable
```

`GOVERNANCE` permite eliminar el lock con permiso `s3:BypassGovernanceRetention` (sólo el root o policy explícita). `COMPLIANCE` es más estricto: ni el root puede borrar antes del plazo. Usar `COMPLIANCE` con cuidado: si se _typoea_ una retención de 10 años, son 10 años inamovibles.

> **Caso de uso**: protección contra _ransomware_-style sobre el filesystem (si alguien gana acceso al MinIO root y borra los _buckets_, _Object Lock_ + _GOVERNANCE_ retiene los objetos. Sólo se pierde el acceso al root, no los datos). Se recomienda al menos para `db-dumps` con un plazo corto (7–30 días).

---

## Verificación final

Antes de considerar este documento cerrado, comprobar:

- [ ] `docker compose -f ~/homelab/almacen/docker-compose.yml ps minio` muestra `minio` en `(healthy)`.
- [ ] `docker logs minio --tail 30` muestra `Status: 1 Online, 0 Offline.` (1/1 drive online en SNSD).
- [ ] `ls -la /mnt/hd2t/services/minio/data/.minio.sys/format.json` existe con ownership `1000:1000`.
- [ ] `curl -k --resolve s3.lan:443:192.168.1.3 -I https://s3.lan/` devuelve `HTTP/2 403` con _body_ XML `<Error><Code>AccessDenied`.
- [ ] `curl -k --resolve minio.lan:443:192.168.1.3 -I https://minio.lan/` devuelve `HTTP/2 302` con `Location: https://auth.lan/?rd=...` (Authelia activo).
- [ ] Login interactivo desde el navegador funciona: `https://minio.lan/` → portal Authelia → autenticarse → consola MinIO pide `MINIO_ROOT_USER` + `MINIO_ROOT_PASSWORD` → dashboard visible.
- [ ] `mc admin info local` reporta `Drives: 1/1 OK` y `Status: Online`.
- [ ] `mc mb local/test-bucket && mc cp /etc/hostname local/test-bucket/ && mc ls local/test-bucket/ && mc rm local/test-bucket/hostname && mc rb local/test-bucket` ciclo completo sin errores.
- [ ] `mc admin user svcacct list local ${MINIO_ROOT_USER}` muestra los _service accounts_ creados.
- [ ] `mc version info local/borg-mirror` reporta `Versioning is enabled`.
- [ ] Tras un `sudo reboot` de la Pi, el _stack_ vuelve y `minio` queda `(healthy)` sin intervención. Los _buckets_ y _service accounts_ están todos presentes (persistidos en `format.json` + `xl.meta`).
- [ ] `git -C ~/homelab status` muestra como **modificados**: `almacen/docker-compose.yml`, `almacen/.env.example`, `red/Caddyfile`, `seguridad/authelia/configuration.yml`. **No** muestra `almacen/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add almacen/docker-compose.yml almacen/.env.example red/Caddyfile seguridad/authelia/configuration.yml
  git commit -m "feat(almacen): add MinIO with split S3/console endpoints"
  ```

---

## Backup

| Qué                                          | Dónde                                                  | Cómo                                            |
|----------------------------------------------|--------------------------------------------------------|-------------------------------------------------|
| `docker-compose.yml`                         | `~/homelab/almacen/`                                   | git                                             |
| `.env` (con `MINIO_ROOT_*`)                  | `~/homelab/almacen/.env`                               | nota local; credenciales replicadas en Vaultwarden |
| `Caddyfile`                                  | `~/homelab/red/`                                       | git                                             |
| `configuration.yml` de Authelia              | `~/homelab/seguridad/authelia/`                        | git                                             |
| `data/` (objetos + metadatos + format.json)  | `/mnt/hd2t/services/minio/data/`                       | Borgmatic — _set_ "data", retención por uso. **Crítico** (en SNSD no hay redundancia interna). |

> **Restauración del MinIO**: tras restaurar `/mnt/hd2t/services/minio/data/` desde Borg, un `docker compose up -d minio` arranca con el **mismo `format.json`** (= mismo UUID de _backend_) y todos los _buckets_, políticas y _service accounts_ están como en el _snapshot_. Las credenciales del root vienen del `.env` (que vive en git **sin valores reales** y en Vaultwarden); recuperarlas y dejarlas en `.env` antes del `up`.

> **Antes de un upgrade de MinIO** (cualquier _release_, dado el ritmo y las eliminaciones puntuales de funcionalidades):
> 1. Backup _on-demand_ del _set_ "data" con Borgmatic.
> 2. Leer el _changelog_ de la _release_ destino y buscar "deprecated", "removed", "format change", "breaking".
> 3. `docker compose stop minio`.
> 4. Editar `.env`: `MINIO_IMAGE_TAG=<nuevo tag>`.
> 5. `docker compose up -d minio`.
> 6. `mc admin info local` para confirmar que el _backend_ se reconoce en la nueva _release_.
> 7. Smoke test: `mc cp` y `mc rm` sobre un _bucket_ de prueba; revisar `docker logs -f minio` durante 5 minutos.

> **Nunca** restaurar **sólo parte** de `data/`: el _backend_ MinIO mantiene índices (`xl.meta`) que tienen que ser coherentes con los ficheros del disco. Restaurar sólo objetos sin sus `xl.meta` deja el _bucket_ en estado "drive corrupted". `mc admin heal local` puede recuperar parcialmente, pero la restauración limpia es **todo el árbol** de `data/`.

---

## Troubleshooting

### `Drive not formatted` o `format.json mismatch`

Síntoma: tras un reinicio brusco o tras restaurar `data/` parcialmente, MinIO no arranca. Logs:

```
ERROR Unable to initialize backend: Drive not formatted
ERROR Unable to use the drive at /data: format.json: invalid format
```

Causa típica: o bien el `format.json` no existe (primera arrancada con `data/` vacío — esperable, MinIO lo crea), o bien el `format.json` existe pero apunta a otra instalación.

Soluciones:

- **Primera arrancada**: ignorar el _warning_, MinIO termina creando el _format_ y arranca. Si tras 30 s sigue en `unhealthy`, mirar permisos de `/mnt/hd2t/services/minio/data/` (debe ser `1000:1000`).
- **Tras restauración parcial**: restaurar **todo** `.minio.sys/` desde Borg, no sólo los objetos.
- **Tras cambiar el path del bind mount**: si se cambia `MINIO_VOLUMES=/data` (irrelevante en SNSD pero por completitud): MinIO no soporta migrar paths sin re-formatear. Recurrir a `mc mirror` a un _bucket_ temporal y restaurar.

### El cliente S3 firma con `s3.lan` pero MinIO rechaza con `SignatureDoesNotMatch`

Síntoma: `aws s3 ls --endpoint-url https://s3.lan` o equivalente devuelve:

```
An error occurred (SignatureDoesNotMatch) when calling the ListBuckets operation:
The request signature we calculated does not match the signature you provided.
```

Causa típica: el `Host` header que llega a MinIO no es el que el cliente firmó. Los clientes S3 incluyen el `Host` en la firma SigV4. Si Caddy no pasa el `Host` original (`s3.lan`), MinIO ve `Host: localhost:9000` y la firma no cuadra.

Solución: confirmar que el bloque `s3.lan` del `Caddyfile` tiene `header_up Host {host}` (ya está en el ejemplo). Si está y el problema persiste:

```bash
# Verificar lo que llega a MinIO
docker logs minio | grep -E '(Host|SignatureDoesNotMatch)' | tail -20

# Si el cliente se queja del puerto (firma con :443 pero llega como :80 internal):
# Forzar al cliente a usar 'AddressingStyle=path' y Host limpio. Para boto3:
# config = Config(signature_version='s3v4', s3={'addressing_style': 'path'})
```

### `mc` reporta `Server uses HTTPS, but client is using HTTP`

Síntoma: tras configurar el alias con `https://s3.lan` en lugar de `http://minio:9000`, `mc` falla.

Causa: la CA local del homelab (Caddy) no está en el _trust store_ del contenedor `mc`.

Soluciones:

1. **Más sencilla** — usar el alias HTTP interno (`http://minio:9000`) cuando se opera desde la propia Pi. Es lo que hace este documento por defecto.
2. **Si hay que operar desde fuera de la Pi** con TLS — montar la CA local en el contenedor `mc`:
   ```bash
   docker run --rm \
     -v mc-config:/root/.mc \
     -v ~/homelab/red/caddy/data/caddy/pki/authorities/local/root.crt:/usr/local/share/ca-certificates/homelab.crt:ro \
     quay.io/minio/mc:${MC_IMAGE_TAG} \
     sh -c "update-ca-certificates && mc alias set s3 https://s3.lan ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD}"
   ```
3. **`--insecure`** — descartado: equivale a desactivar el chequeo de cert, sólo aceptable para depurar puntualmente.

### Subida _multipart_ falla a partir de un cierto tamaño

Síntoma: `mc cp fichero.iso local/test/` o un cliente S3 cualquiera fallan con _timeout_ o _connection reset_ tras unos minutos en archivos grandes (> 5 GB).

Causa típica: el `read_timeout` del bloque `s3.lan` en Caddy no es suficiente para que el _upload completo_ (todas las partes + la llamada `CompleteMultipartUpload`) termine.

Solución: revisar que el bloque tiene `read_timeout 30m` y `write_timeout 30m` (ya en el ejemplo). Para subidas más grandes, aumentar a `60m`. Si el cliente sigue fallando, partir el upload manualmente con `aws s3 cp --expected-size` o usar `mc cp` (ya hace _multipart_ con _resume_).

Diagnóstico:

```bash
docker exec caddy tail -f /var/log/caddy/access.log | grep s3.lan
# Buscar request_duration anormales o status 502/504.
```

### La consola muestra `redirect_uri mismatch` o vuelve al login en bucle

Síntoma: tras autenticarse en Authelia, la consola de MinIO redirige a `https://minio.lan/login` que a su vez devuelve a Authelia, en bucle.

Causa típica: `MINIO_BROWSER_REDIRECT_URL` no coincide con el nombre por el que el operador accede.

Solución: confirmar que `.env` tiene exactamente:

```env
MINIO_BROWSER_REDIRECT_URL=https://minio.lan
```

Sin _trailing slash_, sin `:443`, exactamente el _scheme + host_. Tras editar:

```bash
docker compose -f ~/homelab/almacen/docker-compose.yml up -d minio
```

### `mc admin policy create` falla con `policy must be a valid IAM policy`

Síntoma: al intentar crear una policy con `mc admin policy create local <name> /tmp/file.json`, MinIO rechaza con error.

Causa típica: el JSON tiene un error de sintaxis (coma extra, comillas curvas en lugar de rectas, etc.) o usa un _action_ no soportado.

Diagnóstico:

```bash
# Validar el JSON
jq . /tmp/policy.json
# Si hay error, jq lo muestra con línea y columna.

# Validar las actions soportadas — referencia oficial:
# https://min.io/docs/minio/linux/administration/identity-access-management/policy-based-access-control.html
```

Lista de _actions_ S3 que MinIO soporta (subset de AWS S3): `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket`, `s3:GetBucketLocation`, `s3:GetBucketVersioning`, `s3:ListBucketVersions`, `s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts`, `s3:GetObjectRetention`, `s3:PutObjectRetention`. Cualquier otra _action_ "AWS-only" será rechazada.

### `Watchtower` del _stack_ `infra` _logueó_ un intento de actualización de `minio`

Síntoma: en `docker logs watchtower` aparece `Found new minio image (sha256:...)`, pero el contenedor no se actualizó.

Comportamiento correcto: el _label_ `com.centurylinklabs.watchtower.enable: "false"` excluye explícitamente el contenedor. Verificar:

```bash
docker inspect minio --format '{{ index .Config.Labels "com.centurylinklabs.watchtower.enable" }}'
# Debe devolver: false
```

Si devuelve `true`, alguien lo cambió por error: corregir en el compose y `docker compose up -d minio`.

### Disk full — `data/` consume más de lo esperado

Síntoma: `df -h /mnt/hd2t` muestra hd2t casi lleno; `du -sh /mnt/hd2t/services/minio/data/` reporta cientos de GB.

Causas posibles y diagnóstico:

```bash
# 1) Versionado activo + churn alto = muchas versiones obsoletas
mc ilm rule list local/<bucket>
# Si no hay regla de expiración, las versiones obsoletas crecen sin techo.
# Solución: añadir regla de expiración por versión obsoleta:
mc ilm rule add local/<bucket> --noncurrent-expire-days 30

# 2) Multipart uploads incompletos (cliente abandonado a la mitad)
mc admin trace local | grep -i multipart
mc rm --incomplete --recursive --older-than 7d local/<bucket>
# Limpia subidas multipart sin completar > 7 días.

# 3) Object Lock con plazos largos: nada que hacer hasta que venza.

# 4) 'Trash' / delete markers acumulados:
mc ls --versions local/<bucket> | grep DELMARKER | wc -l
# Si son muchos, una regla ilm de noncurrent-expire-days los limpia.
```

### El _service account_ funciona desde dentro de Docker pero no desde un cliente externo

Síntoma: `mc cp` desde un contenedor de la red `homelab` funciona; el mismo cliente desde el portátil del operador con `https://s3.lan` falla.

Causas posibles:

1. **CA local no importada** en el portátil — ver `docs/03-red/04-caddy.md`, sección "Confianza en la CA local".
2. **Pi-hole no resuelve `s3.lan` desde el portátil** — confirmar que el portátil tiene a Pi-hole como DNS (vía DHCP del router o configuración manual). `dig @192.168.1.2 s3.lan` debe responder con la IP de la Pi.
3. **Tailscale activo y MagicDNS resolviendo a otra IP** — si el portátil está conectado a la _tailnet_, `s3.lan` puede estar resolviéndose a la IP `100.x.y.z` de la Pi en Tailscale. Eso es **correcto** (vía Tailscale + Caddy + SNI), pero requiere que el certificado interno cubra ese flujo. Si el portátil tiene la CA local, funciona.

---

## Encryption at rest opcional (SSE-S3 con KMS local)

> **Nota**: sección opcional. Activar **antes** de poner datos en producción — habilitarla a posteriori sólo cifra _objetos nuevos_, no los existentes.

MinIO soporta cifrado de objetos en disco con SSE-S3 (clave maestra gestionada por el server) y SSE-KMS (clave externa, requiere KES o Vault). El homelab usa la versión _embedded_ con clave maestra en `.env`:

1. Generar la clave maestra (32 bytes, base64):

   ```bash
   minio_kms_key=$(openssl rand -hex 32)
   echo "MINIO_KMS_SECRET_KEY=homelab-key:$minio_kms_key" >> ~/homelab/almacen/.env
   unset minio_kms_key
   ```

2. Añadir al `environment:` del servicio `minio` en el compose:

   ```yaml
       MINIO_KMS_SECRET_KEY: ${MINIO_KMS_SECRET_KEY}
   ```

3. `docker compose up -d minio` para recargar.

4. Activar el cifrado por defecto en un _bucket_:

   ```bash
   mc encrypt set sse-s3 homelab-key local/<bucket>
   ```

A partir de ese momento, todos los objetos que se suban a ese _bucket_ se cifran transparentemente. La clave maestra **no** debe perderse: si se pierde, los objetos cifrados quedan irrecuperables. Backup de `.env` y de Vaultwarden, **ambos**, son obligatorios.

> **Limitación**: `MINIO_KMS_SECRET_KEY` _embedded_ es suficiente para el homelab pero no rota claves automáticamente. Para un escenario más serio se documentaría KES (`docs/04-seguridad/`) cuando llegue su fase.

---

## Referencias

- MinIO — Documentación oficial: <https://min.io/docs/minio/linux/index.html>
- MinIO — Single-Node Single-Drive deployment: <https://min.io/docs/minio/linux/operations/install-deploy-manage/deploy-minio-single-node-single-drive.html>
- MinIO — Variables de entorno (`MINIO_*`): <https://min.io/docs/minio/linux/reference/minio-server/settings.html>
- MinIO — Endpoint S3 API: <https://min.io/docs/minio/linux/developers/s3-compatibility.html>
- MinIO — IAM (policies, users, service accounts): <https://min.io/docs/minio/linux/administration/identity-access-management.html>
- MinIO — Object versioning y lifecycle: <https://min.io/docs/minio/linux/administration/object-management.html>
- MinIO — Object Lock (WORM): <https://min.io/docs/minio/linux/administration/object-management/object-retention.html>
- MinIO — Server-Side Encryption (SSE-S3): <https://min.io/docs/minio/linux/administration/server-side-encryption.html>
- MinIO — Releases (servidor): <https://github.com/minio/minio/releases>
- MinIO — `mc` (CLI): <https://min.io/docs/minio/linux/reference/minio-mc.html>
- MinIO — `mc` releases: <https://github.com/minio/mc/releases>
- AWS — SigV4 signature spec (referencia para depurar firmas): <https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticating-requests.html>
- Caddy — `reverse_proxy` (timeouts y buffering): <https://caddyserver.com/docs/caddyfile/directives/reverse_proxy>
