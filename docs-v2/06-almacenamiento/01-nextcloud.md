# Nextcloud

## Descripción

Despliegue de **Nextcloud** como **nube privada** del homelab: ficheros, calendario (CalDAV), contactos (CardDAV), notas, tareas y galería personal, todo bajo `https://nextcloud.${LAN_DOMAIN}` (LAN) y, una vez completada la fase Tailscale, `https://nextcloud.${TS_DOMAIN}` (móvil fuera de casa). Inaugura la **Fase 6 — Almacenamiento y Archivos** y es el primer servicio "pesado" del homelab que combina aplicación + base de datos + caché en un único stack acoplado.

El stack `nextcloud` ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §1.1) contiene **tres contenedores**:

- **`nextcloud`** — la app PHP servida por la imagen oficial `nextcloud:30-apache`. Se conecta a la red bridge `homelab` para que Caddy pueda llamarla por nombre Docker (`http://nextcloud:80`) y a `nextcloud_internal` para hablar con la BD y Redis. Sin `ports:` al host.
- **`mariadb`** — `mariadb:11.4`. Aislada en `nextcloud_internal`. **No** se conecta a `homelab`: ningún otro servicio del homelab debe tocarla. Persiste en `/mnt/hd2t/services/nextcloud/db/data/`.
- **`redis`** — `redis:7.4-alpine`. Aislada en `nextcloud_internal`. Cache de PHP-APCu/objetos y, sobre todo, **file locking** transaccional (sin esto, la concurrencia de varios clientes de sync corrompe metadatos).

Por qué exactamente esta arquitectura, y no otra:

1. **Imagen `nextcloud:apache` (no `:fpm`).** Apache + mod_php se autocontiene en un único contenedor con `cron` interno (script `/cron.sh` invocado vía `OC_CRON`), sin necesidad de un nginx adicional. Más sencillo de operar y de respaldar; el coste en RAM (~150 MiB residentes en idle) es asumible en una Pi 5 con 8 GB.
2. **MariaDB, no PostgreSQL ni SQLite.** Nextcloud documenta soporte oficial para los tres, pero MariaDB es la combinación **más probada** en producción (la que usa Nextcloud GmbH para sus benchmarks y la que mejor digiere `oc_filecache` cuando la biblioteca crece). PostgreSQL es válido y algo más eficiente con índices grandes, pero las apps de terceros se prueban antes con MariaDB. SQLite **no** es opción para >5 GB o >2 usuarios concurrentes: bloqueos de fichero matan al rendimiento. Versión `11.4` LTS (soporte hasta 2029).
3. **Redis para file locking + memcache.** Nextcloud sin Redis usa locking en BD (lento, contención de filas) y cache APCu sólo (no compartido entre PHP-FPM workers — irrelevante con Apache mod_php, pero deja todo preparado por si se conmuta a fpm). Redis añade `transactional file locking` real, requisito de facto para que dos clientes (móvil + escritorio) sincronicen la misma carpeta sin perder datos.
4. **Red interna `nextcloud_internal` aislada.** MariaDB y Redis **nunca** se ven desde `homelab`. Si un contenedor de otro stack quedara comprometido, no puede hablar directo con la BD de Nextcloud — debe pasar por la app, que aplica permisos y rate-limiting. Es la misma regla que aplica el doc de Authelia ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §0 punto 4).
5. **Sin Watchtower automático.** `occ upgrade` exige interacción humana en cualquier major (28 → 29 → 30) y secuencialidad estricta (no se salta versiones). Watchtower aplicaría el upgrade pero **no** ejecutaría `occ upgrade`, dejando Nextcloud en `maintenance mode` permanente. Documentado en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6 línea 455. Los upgrades de patch (30.0.x → 30.0.y) son seguros, pero por consistencia se mantienen manuales también, en bloque con MariaDB y Redis.
6. **Detrás de Caddy + Authelia 2FA**, con **bypass para WebDAV/sync clients**. La UI web pasa por Authelia (login + TOTP). Los clientes de sync (Nextcloud Desktop, Android, iOS) hablan WebDAV con HTTP Basic Auth y **no** entienden el flujo de redirecciones de Authelia: por eso, los paths `/remote.php/*`, `/public.php/*` y similar se exceptúan en `access_control` para que reciban directamente el reto de auth de Nextcloud. Compromiso explícito: la borde sigue siendo Caddy (HTTPS), pero la auth para los clientes de sync la lleva el propio Nextcloud (con su rate-limit y `bruteforcesettings`).
7. **Datos en `hd2t`, separación entre código y datos de usuario.** Dos bind mounts:
   - `/mnt/hd2t/services/nextcloud/nextcloud/html/` → `/var/www/html/` (código + config + apps de terceros, cambia en upgrades pero por lo demás casi inmutable),
   - `/mnt/hd2t/services/nextcloud/nextcloud/data/` → `/var/www/html/data/` (ficheros de usuarios, crece sin límite).
   Separarlos permite respaldarlos con políticas distintas (rara vez vs cada noche) y restaurar uno sin tocar el otro.
8. **Datos de usuario `/var/www/html/data/` (default), no fuera del webroot.** Nextcloud soporta `datadirectory` arbitrario, pero ejecutar el `occ` con datadir externo a `/var/www/html/` ha dado problemas históricos con varias apps (LDAP, Antivirus, Files Lock). La imagen oficial coloca el dir DENTRO del webroot **bloqueado** por un `.htaccess` que devuelve 403 para todo el subárbol — la separación lógica es la del bind mount, no la del path.

> **Alcance de red**: Nextcloud no publica puertos al host. Se accede únicamente vía `https://nextcloud.${LAN_DOMAIN}` (Caddy + CA interna) y vía Tailscale (`nextcloud.${TS_DOMAIN}`) cuando esa fase esté lista. El homelab opera en LAN + Tailscale, sin exposición a internet, sin Let's Encrypt, sin port forwarding.

---

## Requisitos Previos

- **Docker Engine + Compose v2** instalados según [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md).
- **Red `homelab`** creada según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2 (`172.20.0.0/24`, bridge `br-homelab`, `external: true`).
- **Caddy desplegado** según [`../03-red/04-caddy.md`](../03-red/04-caddy.md), conectado a `homelab`, con la CA interna funcionando y `root.crt` confiado en al menos un cliente (§6.5 de Caddy).
- **Pi-hole desplegado** según [`../03-red/02-pihole.md`](../03-red/02-pihole.md), con la posibilidad de añadir un registro DNS local (Local DNS Records) para `nextcloud.${LAN_DOMAIN}` apuntando a `192.168.1.10` (la IP del host donde escucha Caddy).
- **Authelia desplegado** según [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md), con el snippet `authelia_proxy` ya disponible en `~/homelab/stacks/proxy/snippets/authelia_proxy` (§9.1 de Authelia).
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No se añaden reglas nuevas: Nextcloud no publica puertos al host; el tráfico entra por Caddy (que ya tiene 80/443 abiertos en §6.4 de su doc).
- **Estructura de directorios** de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) en su sitio: `/mnt/hd2t/services/nextcloud/` ya existe con propietario `homelab:homelab` (creado por el bootstrap de §4.1).
- **Espacio libre en `hd2t`** ≥ 50 GB recomendados de partida (los ficheros de usuario crecen rápido cuando se conectan dos o tres dispositivos con auto-upload de fotos). El monitoreo de espacio queda cubierto por Node Exporter + Grafana ([`../05-monitorizacion/`](../05-monitorizacion/)).
- **Comprobaciones rápidas**:
  ```bash
  # Red homelab existe:
  docker network inspect homelab --format '{{(index .IPAM.Config 0).Subnet}}'
  # Esperado: 172.20.0.0/24

  # Caddy y Authelia están sanos:
  docker inspect caddy authelia --format '{{.Name}}: {{.State.Health.Status}}'
  # Esperado: ambos healthy.

  # Pi-hole resuelve nextcloud.lan al host (preparar antes en su UI):
  dig +short @192.168.1.241 nextcloud.lan
  # Esperado: 192.168.1.10  (si no, añadir el registro en Pi-hole y volver)

  # Espacio libre en hd2t:
  df -h /mnt/hd2t | tail -1
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Imagen Docker (Nextcloud) | **`nextcloud:30-apache`** | Imagen oficial multi-arch (incluye `linux/arm64`). La etiqueta `30-apache` sigue la rama 30.x estable (soporte oficial hasta junio 2026). La variante `apache` es el SAPI menos exigente en operación: un solo proceso, cron interno, sin nginx aparte. |
| Tag de imagen | **Pinned a release puntual**, nunca `latest` ni `30` "rolling minor" | Misma regla de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1. Cada minor de Nextcloud puede traer migraciones DB; un upgrade silencioso a las 04:00 dejaría la app en modo mantenimiento sin ejecutar `occ upgrade`. Upgrade manual leyendo las release notes y los [Maintenance and Release Schedule](https://github.com/nextcloud/server/wiki/Maintenance-and-Release-Schedule). |
| Política de Watchtower | **`watchtower.enable: "false"`** | Justificado en §0 punto 5 y en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6 línea 455. |
| Imagen Docker (MariaDB) | **`mariadb:11.4`** | LTS oficial (10 años de soporte, hasta 2029). Multi-arch. La rama 10.11 LTS también es válida; 11.4 es la generación más reciente y reduce la próxima migración. **No** se elige Postgres por las razones de §0 punto 2. |
| Política de Watchtower (MariaDB) | **`watchtower.enable: "false"`** | Major upgrades requieren `mariadb-upgrade`; Watchtower no lo orquesta. Patch upgrades son seguros pero por consistencia se hacen en bloque con Nextcloud. |
| Imagen Docker (Redis) | **`redis:7.4-alpine`** | Multi-arch. La variante `-alpine` (~30 MB) es suficiente: Redis aquí hace de cache + lock manager, sin AOF (no se persisten los locks). Línea 7.x estable. |
| Política de Watchtower (Redis) | **`watchtower.enable: "false"`** | Coherente con [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6 línea 454. |
| Modo de red (Nextcloud) | **`homelab`** + **`nextcloud_internal`** | `homelab` para que Caddy llame por `http://nextcloud:80`. `nextcloud_internal` para hablar con MariaDB y Redis sin exponerlos a `homelab`. Misma regla que el stack `auth`. |
| Modo de red (MariaDB, Redis) | **Solo `nextcloud_internal`** (con `internal: true`) | Aislamiento real: ni MariaDB ni Redis pueden ser alcanzados desde otros stacks ni desde la LAN. La cadena de auth a la BD se rompe en la red Docker antes de llegar siquiera al puerto 3306. |
| `ports:` publicados al host | **Ninguno** (los tres) | La UI/API se sirve **únicamente** vía Caddy. Publicar `:80` duplicaría la entrada y permitiría saltarse Caddy (y, con él, HTTPS, las cabeceras de seguridad y la `forward_auth`). MariaDB en `:3306` y Redis en `:6379` jamás deben publicarse: protección en profundidad. |
| Acceso a la UI web | **Detrás de Authelia** (`forward_auth`, política `two_factor`) **excepto** `/remote.php/*`, `/public.php/*`, `/.well-known/*`, `/ocs/v2.php/*`, `/ocm-provider/*`, `/cron.php`, `/status.php` | Justificado en §0 punto 6. La UI humana exige TOTP; los clientes de sync hablan WebDAV con su propia auth. La lista exacta de paths exentos sale de [Nextcloud — Reverse proxy & SSO best practices](https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/reverse_proxy_configuration.html). |
| `OVERWRITEPROTOCOL` | **`https`** | Detrás de un proxy que termina TLS, Apache cree estar en HTTP plano. Sin esta env, todos los enlaces que Nextcloud genera (descargas, compartidos, OCS, oauth) salen como `http://...` y los clientes y la UI fallan en HSTS. |
| `OVERWRITECLIURL` | **`https://nextcloud.${LAN_DOMAIN}`** | Necesario para que las URLs CLI de `occ` y los emails generados sepan el dominio real. Una vez Tailscale esté arriba (`05-tailscale.md`), se mantiene este valor (es el dominio "canónico"); el `tailnet.ts.net` es alias. |
| `TRUSTED_PROXIES` | Subred de `homelab` (`172.20.0.0/24`) | Sin esto, Nextcloud rechaza las cabeceras `X-Forwarded-*` que Caddy inyecta y registra cada login como viniendo de la IP del contenedor Caddy → bruteforce protection se activa contra el propio proxy. Declarar la subred entera evita tener que actualizar cada vez que Caddy cambie de IP dentro del bridge. |
| `TRUSTED_DOMAINS` | `nextcloud.${LAN_DOMAIN}` (luego se añade `nextcloud.${TS_DOMAIN}`) | Lista cerrada de hostnames aceptados. Cualquier petición con `Host:` distinto se rechaza. Mantenerlo corto evita que un Host header injection llegue a Nextcloud. |
| `APACHE_DISABLE_REWRITE_IP` | **`1`** | Necesario en combinación con `TRUSTED_PROXIES`: indica al `mpm_prefork` de Apache que respete el `X-Forwarded-For` que viene de Caddy en lugar de regenerarlo. |
| Cron de tareas en background | **`OC_CRON=true`** (script `/cron.sh` interno cada 5 min) | Alternativa a un contenedor sidecar. La imagen oficial trae el script y lo respeta si esta env está a `true`. Sin cron, Nextcloud avisa cada 24h ("Last background job execution ran X ago") y ciertas tareas (mailing, file scan, app updates) no progresan. |
| Cifrado de BD (`MYSQL_*` env) | **`MARIADB_AUTO_UPGRADE=1`** y password root + password de usuario en ficheros (no en `.env`) | Patrón estándar `*_FILE` de la imagen oficial de MariaDB: `MARIADB_ROOT_PASSWORD_FILE`, `MARIADB_PASSWORD_FILE`. Coincide con el patrón de Authelia ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §0 fila "Secretos"). |
| Charset MariaDB | **`utf8mb4` con `transaction_isolation=READ-COMMITTED` y `binlog_format=ROW`** | Recomendaciones explícitas de Nextcloud para deduplicar locks y soportar emojis 4-byte (4-byte UTF-8). Aplicado vía `command:` en el `docker-compose.yml`. |
| Configuración Apache `mpm_prefork` | Default de la imagen oficial (`StartServers 5`, `MaxRequestWorkers 25`) | Pi 5 + 1–4 usuarios humanos no necesita más. Si en el futuro se añadiesen >10 usuarios, aumentar `MaxRequestWorkers` y vigilar RAM con cAdvisor. |
| Usuario del contenedor (Nextcloud) | **`www-data:www-data`** (UID `33:33` en la imagen oficial) | La imagen `nextcloud:apache` corre Apache como `www-data` (33). **No** se sobreescribe con `${PUID}` para no romper la propiedad de los `apps/` y los hooks de upgrade. Consecuencia: `/mnt/hd2t/services/nextcloud/nextcloud/{html,data}/` debe tener owner `33:33` (paso explícito en §3.3). |
| Usuario del contenedor (MariaDB) | **`mysql:mysql`** (UID 999, default) | La imagen oficial droppea privilegios. **No** se sobreescribe — el directorio `/mnt/hd2t/services/nextcloud/db/data/` se inicializa con UID 999 al primer arranque. |
| Usuario del contenedor (Redis) | **`redis:redis`** (UID 999, default) | Idéntico al patrón del stack `auth`. |
| `cap_drop: ALL` + `cap_add` | Nextcloud: `[CHOWN, SETGID, SETUID, DAC_OVERRIDE, NET_BIND_SERVICE]` (lo mínimo que requiere Apache mod_php para hacer `chown` de uploads y servir en `:80`). MariaDB: `[]`. Redis: `[]`. | Apache necesita `NET_BIND_SERVICE` para `:80` (>1024 dentro del contenedor pero <1024 en algunas configs), `SETUID/SETGID/DAC_OVERRIDE` para hacer fork como `www-data` y leer/escribir uploads. MariaDB y Redis usan puertos altos y no fork-ean privilegios. |
| `security_opt: no-new-privileges:true` | **Activado** (los tres) | Plantilla §6 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). |
| `read_only` | **`false`** para los tres | Apache + PHP-FPM escriben en muchos paths internos (`/tmp`, sesiones, cache OPcache, logs). Forzar RO obligaría a tmpfs masivo y rompe apps de terceros. MariaDB y Redis escriben en `/var/lib/mysql` y `/data`. RO se deja como variante futura si se aceptan los costes. |
| Persistencia (Nextcloud `html/`) | Bind mount `/var/www/html` ← `/mnt/hd2t/services/nextcloud/nextcloud/html/` | Código, `config/`, `apps/`, `themes/`, `custom_apps/`. Cambia en cada upgrade y al instalar apps. Backup obligatorio (§11). |
| Persistencia (Nextcloud `data/`) | Bind mount `/var/www/html/data` ← `/mnt/hd2t/services/nextcloud/nextcloud/data/` | Ficheros de usuario + thumbs + `appdata_<instanceid>/`. Crece sin límite; backup diferencial obligatorio. |
| Persistencia (MariaDB) | Bind mount `/var/lib/mysql` ← `/mnt/hd2t/services/nextcloud/db/data/` | InnoDB + binlogs. Backup vía `mariadb-dump` antes del Borg snapshot (§11). **Nunca** snapshotear el directorio "vivo" sin dump previo. |
| Persistencia (Redis) | Bind mount `/data` ← `/mnt/hd2t/services/nextcloud/redis/data/` | Locks transaccionales. **No** es backup-crítico: pérdida = un puñado de subidas en curso pierden el lock y los clientes hacen retry automáticamente. Mismo patrón que Redis del stack `auth`. |
| Healthcheck (Nextcloud) | **`/status.php`** vía `wget` | El endpoint devuelve JSON con `installed: true, maintenance: false, version: ...`. Se considera healthy si responde 200 con `installed: true`. Captura el caso "maintenance mode" como `unhealthy`, lo que avisa a Watchtower (deshabilitado, pero por consistencia) y a Uptime Kuma. |
| Healthcheck (MariaDB) | **`mariadb-admin ping`** dentro del contenedor | Endpoint canónico, sin abrir nuevas conexiones de cliente. |
| Healthcheck (Redis) | **`redis-cli -a $PASS ping`** | Igual que en el stack `auth`. |
| Logs Docker | **`json-file` 10 MB × 3** (heredado del demonio) | Plantilla §6.1 de estructura-compose. Para retención larga, Loki/Promtail (Fase 5+, opt-in). |
| Notify Push (HTTP/2 server-push para clientes) | **No activado en este doc** | Mejora la latencia de los clientes de sync, pero exige un contenedor adicional (`nextcloud-notify-push`) y una entrada extra en Caddy con `handle /push/*`. Se documenta como opt-in en §13.4. Por defecto los clientes usan polling cada 30 s, suficiente para 1–4 usuarios. |

---

## 1. Resumen de la arquitectura

```
                ┌───────────────────────── LAN 192.168.1.0/24 ────────────────────────┐
                │                                                                     │
   navegador ───┤ https://nextcloud.lan ──► Caddy :443                                │
   sync client  │   (Pi-hole resuelve a 192.168.1.10)                                  │
                │                                                                     │
                └─────────────────────┬───────────────────────────────────────────────┘
                                      │  TLS interno (CA Caddy)
                ┌─────────────────────▼───────────────────────────────────────────────┐
                │  Pi 5 — docker network: homelab (172.20.0.0/24)                      │
                │                                                                      │
                │   ┌──────── caddy ────────────────────────────────────────────┐    │
                │   │ nextcloud.lan                                              │    │
                │   │  ├─ paths /remote.php/*, /public.php/*, /.well-known/*    │    │
                │   │  │      /ocs/*, /cron.php, /status.php  ─► reverse_proxy  │    │
                │   │  │      (sin Authelia, los clientes WebDAV/CalDAV          │    │
                │   │  │       se autentican con Basic/Bearer en Nextcloud)      │    │
                │   │  └─ resto                ─► forward_auth ► authelia       │    │
                │   │                          ─► reverse_proxy http://nextcloud:80   │
                │   └────────────────────────────────────────────────────────────┘    │
                │                                                                      │
                │   ┌────── stack: nextcloud ─────────────────────────────────────┐  │
                │   │                                                              │  │
                │   │   ┌────── nextcloud ───────┐                                  │  │
                │   │   │ image: nextcloud:30-   │                                  │  │
                │   │   │  apache                │                                  │  │
                │   │   │ user: www-data (33)    │                                  │  │
                │   │   │ networks:              │                                  │  │
                │   │   │  - homelab             │  HTTP :80 (sólo intra-Docker)     │  │
                │   │   │  - nextcloud_internal  │                                  │  │
                │   │   │ /var/www/html (RW)     │                                  │  │
                │   │   │ /var/www/html/data (RW)│                                  │  │
                │   │   │ env: OVERWRITEPROTOCOL │                                  │  │
                │   │   │      TRUSTED_PROXIES   │                                  │  │
                │   │   │      OC_CRON           │                                  │  │
                │   │   └────┬────────┬──────────┘                                  │  │
                │   │        │        │                                              │  │
                │   │   tcp 3306  tcp 6379                                            │  │
                │   │        │        │                                              │  │
                │   │   ┌────▼───┐  ┌─▼──────┐                                      │  │
                │   │   │mariadb │  │ redis  │                                      │  │
                │   │   │11.4    │  │7.4-    │                                      │  │
                │   │   │UID 999 │  │alpine  │                                      │  │
                │   │   │/var/lib│  │/data   │                                      │  │
                │   │   │ /mysql │  │        │                                      │  │
                │   │   └────────┘  └────────┘                                      │  │
                │   │                                                              │  │
                │   │   network: nextcloud_internal (bridge, internal: true)       │  │
                │   └──────────────────────────────────────────────────────────────┘  │
                └──────────────────────────────────────────────────────────────────────┘
```

Tres invariantes:

- **Nextcloud sólo es accesible vía Caddy.** No hay `ports:` al host. La única vía de entrada es `https://nextcloud.lan` (HTTPS interno con la CA de Caddy).
- **MariaDB y Redis no se conectan a `homelab`.** Sólo Nextcloud, dentro del mismo stack, los alcanza por DNS interno de `nextcloud_internal`. Si `homelab` se viera comprometida, ambos siguen inalcanzables.
- **La auth se parte en dos.** UI humana → Authelia 2FA. Sync/CalDAV/CardDAV → Basic Auth contra Nextcloud (con bruteforce protection nativa). El compromiso es consciente y se documenta en §8.3.

Flujo de un sync (caso "Nextcloud Desktop sube un fichero"):

```
1. Cliente Desktop → PUT https://nextcloud.lan/remote.php/dav/files/homelab/foto.jpg
                          Authorization: Basic base64(homelab:app_token)
2. Caddy: matcher /remote.php/* → bypass forward_auth (no llama a Authelia).
3. Caddy → reverse_proxy http://nextcloud:80 (red homelab).
4. Nextcloud Apache → mod_php → comprueba el app_token contra oc_authtoken (BD).
5. Nextcloud → adquiere lock en Redis (`SETNX file:foto.jpg PID`).
6. Nextcloud → escribe el blob en /var/www/html/data/homelab/files/foto.jpg.
7. Nextcloud → libera lock en Redis (`DEL file:foto.jpg`).
8. Nextcloud → INSERT en oc_filecache (BD) + responde 201 al cliente.
```

---

## 2. Plan de variables y archivos

El stack `nextcloud` es nuevo. Layout que se va a crear en este doc:

```
~/homelab/stacks/nextcloud/                    # versionado en git
├── docker-compose.yml
├── .env.example
└── snippets-caddy/
    └── nextcloud.caddy                         # bloque para copiar al Caddyfile

/mnt/hd2t/services/nextcloud/                  # NO versionado
├── .env                                        # secretos no críticos (tags, dominios)
├── secrets/                                    # secretos críticos (chmod 600)
│   ├── db_root_password
│   ├── db_password
│   ├── redis_password
│   └── admin_password                          # del usuario "homelab" de Nextcloud
├── nextcloud/
│   ├── html/                                   # → /var/www/html (código, config, apps)
│   └── data/                                   # → /var/www/html/data (ficheros usuarios)
├── db/
│   └── data/                                   # → /var/lib/mysql
└── redis/
    └── data/                                   # → /data
```

### 2.1. `.env.example` (`~/homelab/stacks/nextcloud/.env.example`)

```bash
# ~/homelab/stacks/nextcloud/.env.example
# Copiar a /mnt/hd2t/services/nextcloud/.env y rellenar.
# NO contiene secretos: estos van en /mnt/hd2t/services/nextcloud/secrets/.

# Usuario y zona horaria.
PUID=1000
PGID=1000
TZ=Europe/Madrid

# Dominios.
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Imágenes ---
# https://hub.docker.com/_/nextcloud/tags
# ¡Leer https://docs.nextcloud.com/server/30/admin_manual/maintenance/upgrade.html antes de subir!
NEXTCLOUD_IMAGE_TAG=30-apache

# https://hub.docker.com/_/mariadb/tags
MARIADB_IMAGE_TAG=11.4

# https://hub.docker.com/_/redis/tags
REDIS_IMAGE_TAG=7.4-alpine

# --- BD ---
# Nombres no son secretos; los passwords sí, en /secrets/.
MARIADB_DATABASE=nextcloud
MARIADB_USER=nextcloud

# --- Usuario admin de Nextcloud (sólo se usa en el primer arranque) ---
NEXTCLOUD_ADMIN_USER=homelab
```

### 2.2. `.env` real (`/mnt/hd2t/services/nextcloud/.env`)

```bash
# Crear el .env con permisos correctos.
sudo install -m 600 -o homelab -g homelab /dev/null /mnt/hd2t/services/nextcloud/.env

cat | sudo tee /mnt/hd2t/services/nextcloud/.env >/dev/null <<'EOF'
PUID=1000
PGID=1000
TZ=Europe/Madrid

LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

NEXTCLOUD_IMAGE_TAG=30-apache
MARIADB_IMAGE_TAG=11.4
REDIS_IMAGE_TAG=7.4-alpine

MARIADB_DATABASE=nextcloud
MARIADB_USER=nextcloud

NEXTCLOUD_ADMIN_USER=homelab
EOF

ls -l /mnt/hd2t/services/nextcloud/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

### 2.3. Cómo se inyectan los secretos

La imagen oficial de Nextcloud y la de MariaDB entienden el sufijo `_FILE`: por cada secreto declarado, se define la variable de entorno apuntando a un fichero dentro del contenedor (montado RO desde `/mnt/hd2t/services/nextcloud/secrets/`). Lo veremos en §6 (`docker-compose.yml`).

| Secreto | Env var | Fichero en contenedor |
|---|---|---|
| Password root de MariaDB | `MARIADB_ROOT_PASSWORD_FILE` | `/run/secrets/db_root_password` |
| Password de la BD `nextcloud` | `MARIADB_PASSWORD_FILE` y `NEXTCLOUD_DB_PASSWORD_FILE` | `/run/secrets/db_password` |
| Password de Redis | `REDIS_HOST_PASSWORD_FILE` | `/run/secrets/redis_password` |
| Password del admin inicial de Nextcloud | `NEXTCLOUD_ADMIN_PASSWORD_FILE` | `/run/secrets/admin_password` |

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
mkdir -p ~/homelab/stacks/nextcloud/snippets-caddy
```

### 3.2. Crear el árbol de datos persistentes

```bash
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/nextcloud
sudo install -d -o homelab -g homelab -m 700 /mnt/hd2t/services/nextcloud/secrets
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/nextcloud/nextcloud
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/nextcloud/db
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/nextcloud/redis
```

Las **subcarpetas que serán propiedad de UIDs internos** se crean con un `chown` específico en §3.3 — Compose creará los directorios automáticamente al montar, pero queremos owner correcto antes del primer arranque para que `mariadb-init` no falle por permisos.

### 3.3. Permisos para los procesos de los contenedores

```bash
# Nextcloud corre como www-data (UID 33) dentro del contenedor.
# Los bind mounts de html/ y data/ deben pertenecerle.
sudo install -d -o 33 -g 33 -m 750 /mnt/hd2t/services/nextcloud/nextcloud/html
sudo install -d -o 33 -g 33 -m 750 /mnt/hd2t/services/nextcloud/nextcloud/data

# MariaDB corre como mysql (UID 999).
sudo install -d -o 999 -g 999 -m 750 /mnt/hd2t/services/nextcloud/db/data

# Redis corre como redis (UID 999).
sudo install -d -o 999 -g 999 -m 770 /mnt/hd2t/services/nextcloud/redis/data
```

Notas:

- **`www-data` UID 33** es la convención de Debian/Apache. La imagen `nextcloud:apache` la usa explícitamente. Si en el futuro un upgrade cambia el UID interno (poco probable), `docker logs nextcloud` mostrará `Permission denied` en `/var/www/html` y el `chown` se reajusta.
- **`mysql:mysql` UID 999** es lo que usa la imagen oficial `mariadb`. Verificable con `docker run --rm mariadb:11.4 id mysql`.
- **`redis:redis` UID 999** idem. La coincidencia numérica con MariaDB es un detalle de Alpine vs Debian: redis-alpine usa UID 999 dentro de su namespace; convive bien porque el aislamiento es por contenedor, no por UID a nivel host.
- Si más adelante un `ls -l /mnt/hd2t/services/nextcloud/db/data/` muestra ficheros `999:999`, es el comportamiento esperado. Borg los respaldará igual; el operador, si necesita inspeccionarlos, usa `sudo`.

---

## 4. Generar secretos

```bash
umask 077
mkdir -p /tmp/nextcloud-secrets

# Cuatro secretos, cada uno en una sola línea sin saltos.
openssl rand -base64 36 | tr -d '\n' > /tmp/nextcloud-secrets/db_root_password
openssl rand -base64 36 | tr -d '\n' > /tmp/nextcloud-secrets/db_password
openssl rand -base64 36 | tr -d '\n' > /tmp/nextcloud-secrets/redis_password
# Admin pwd: usar uno del gestor de contraseñas del operador. Este es el que
# usará el operador en el primer login. Cambia luego desde la UI.
openssl rand -base64 24 | tr -d '\n' > /tmp/nextcloud-secrets/admin_password

# Mover a su sitio definitivo con permisos correctos.
for s in db_root_password db_password redis_password admin_password; do
  sudo install -m 600 -o homelab -g homelab \
    /tmp/nextcloud-secrets/${s} \
    /mnt/hd2t/services/nextcloud/secrets/${s}
done

# Verificar.
ls -l /mnt/hd2t/services/nextcloud/secrets/
# Esperado: 4 ficheros -rw------- homelab:homelab.

# Limpiar.
shred -u /tmp/nextcloud-secrets/* 2>/dev/null || rm -f /tmp/nextcloud-secrets/*
rmdir /tmp/nextcloud-secrets
```

> **`tr -d '\n'`** es importante: la imagen de MariaDB lee el fichero entero como password; un `\n` final hace que el password real sea `<random>\n` y los siguientes intentos de login (sin `\n`) fallen con `Access denied`. Bug clásico, lo cubre [maridb/maridb-docker#178](https://github.com/MariaDB/mariadb-docker/issues/178).

> **Anotar el `admin_password`** en el gestor de contraseñas del operador (KeePassXC fuera del homelab, hasta que Vaultwarden esté arriba) **antes** de seguir. Después del primer login se cambiará desde la UI por uno gestionado.

---

## 5. `docker-compose.yml`

`~/homelab/stacks/nextcloud/docker-compose.yml`:

```yaml
# ~/homelab/stacks/nextcloud/docker-compose.yml
# Stack: nextcloud (../02-docker/02-estructura-compose.md §1.1).
# Datos en /mnt/hd2t/services/nextcloud/. Secretos en /mnt/hd2t/services/nextcloud/secrets/.

name: nextcloud

services:
  # ---------------------------------------------------------------------------
  # Nextcloud (Apache + mod_php + cron interno)
  # ---------------------------------------------------------------------------
  nextcloud:
    image: nextcloud:${NEXTCLOUD_IMAGE_TAG}
    container_name: nextcloud
    hostname: nextcloud
    restart: unless-stopped

    env_file:
      - /mnt/hd2t/services/nextcloud/.env
    environment:
      TZ: ${TZ}

      # --- BD ---
      MYSQL_HOST: mariadb
      MYSQL_DATABASE: ${MARIADB_DATABASE}
      MYSQL_USER: ${MARIADB_USER}
      MYSQL_PASSWORD_FILE: /run/secrets/db_password   # legacy var, aún usada por el image entrypoint

      # --- Redis ---
      REDIS_HOST: redis
      REDIS_HOST_PORT: "6379"
      REDIS_HOST_PASSWORD_FILE: /run/secrets/redis_password

      # --- Admin inicial (solo aplica al primer arranque, cuando NC se autoinstala) ---
      NEXTCLOUD_ADMIN_USER: ${NEXTCLOUD_ADMIN_USER}
      NEXTCLOUD_ADMIN_PASSWORD_FILE: /run/secrets/admin_password

      # --- Reverse proxy (Caddy) ---
      OVERWRITEPROTOCOL: https
      OVERWRITEHOST: nextcloud.${LAN_DOMAIN}
      OVERWRITECLIURL: https://nextcloud.${LAN_DOMAIN}
      TRUSTED_PROXIES: "172.20.0.0/24"
      APACHE_DISABLE_REWRITE_IP: "1"

      # --- Dominios de confianza (nextcloud.lan + 'localhost' para healthcheck interno) ---
      NEXTCLOUD_TRUSTED_DOMAINS: >-
        nextcloud.${LAN_DOMAIN}
        nextcloud.${TS_DOMAIN}

      # --- Tareas en background ---
      OC_CRON: "true"

      # --- Tamaño máximo de upload (PHP) ---
      PHP_UPLOAD_LIMIT: "10G"
      PHP_MEMORY_LIMIT: "512M"

    volumes:
      - type: bind
        source: /mnt/hd2t/services/nextcloud/nextcloud/html
        target: /var/www/html
        bind:
          create_host_path: false
      - type: bind
        source: /mnt/hd2t/services/nextcloud/nextcloud/data
        target: /var/www/html/data
        bind:
          create_host_path: false

      # Secretos: read-only.
      - type: bind
        source: /mnt/hd2t/services/nextcloud/secrets/db_password
        target: /run/secrets/db_password
        read_only: true
        bind:
          create_host_path: false
      - type: bind
        source: /mnt/hd2t/services/nextcloud/secrets/redis_password
        target: /run/secrets/redis_password
        read_only: true
        bind:
          create_host_path: false
      - type: bind
        source: /mnt/hd2t/services/nextcloud/secrets/admin_password
        target: /run/secrets/admin_password
        read_only: true
        bind:
          create_host_path: false

    networks:
      - homelab
      - nextcloud_internal

    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
      - DAC_OVERRIDE
      - NET_BIND_SERVICE

    security_opt:
      - no-new-privileges:true

    healthcheck:
      test:
        - CMD-SHELL
        - 'wget -qO- http://localhost/status.php | grep -q ''"installed":true'''
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s

    depends_on:
      mariadb:
        condition: service_healthy
      redis:
        condition: service_healthy

    labels:
      com.centurylinklabs.watchtower.enable: "false"
      homepage.group: "Almacenamiento"
      homepage.name: "Nextcloud"
      homepage.icon: "nextcloud.png"
      homepage.href: "https://nextcloud.${LAN_DOMAIN}"
      homepage.description: "Nube privada"

  # ---------------------------------------------------------------------------
  # MariaDB (LTS 11.4)
  # ---------------------------------------------------------------------------
  mariadb:
    image: mariadb:${MARIADB_IMAGE_TAG}
    container_name: mariadb-nextcloud
    hostname: mariadb
    restart: unless-stopped

    # Recomendaciones explícitas de Nextcloud para concurrencia + emoji 4-byte.
    command:
      - "--transaction-isolation=READ-COMMITTED"
      - "--binlog-format=ROW"
      - "--character-set-server=utf8mb4"
      - "--collation-server=utf8mb4_unicode_ci"
      - "--skip-innodb-read-only-compressed"
      - "--max-connections=100"

    env_file:
      - /mnt/hd2t/services/nextcloud/.env
    environment:
      TZ: ${TZ}
      MARIADB_DATABASE: ${MARIADB_DATABASE}
      MARIADB_USER: ${MARIADB_USER}
      MARIADB_PASSWORD_FILE: /run/secrets/db_password
      MARIADB_ROOT_PASSWORD_FILE: /run/secrets/db_root_password
      MARIADB_AUTO_UPGRADE: "1"

    volumes:
      - type: bind
        source: /mnt/hd2t/services/nextcloud/db/data
        target: /var/lib/mysql
        bind:
          create_host_path: false

      - type: bind
        source: /mnt/hd2t/services/nextcloud/secrets/db_root_password
        target: /run/secrets/db_root_password
        read_only: true
        bind:
          create_host_path: false
      - type: bind
        source: /mnt/hd2t/services/nextcloud/secrets/db_password
        target: /run/secrets/db_password
        read_only: true
        bind:
          create_host_path: false

    networks:
      - nextcloud_internal

    cap_drop:
      - ALL

    security_opt:
      - no-new-privileges:true

    healthcheck:
      test:
        - CMD-SHELL
        - 'mariadb-admin ping -uroot -p"$$(cat /run/secrets/db_root_password)" --silent'
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 30s

    labels:
      com.centurylinklabs.watchtower.enable: "false"

  # ---------------------------------------------------------------------------
  # Redis (cache + file locking)
  # ---------------------------------------------------------------------------
  redis:
    image: redis:${REDIS_IMAGE_TAG}
    container_name: redis-nextcloud
    hostname: redis
    restart: unless-stopped

    env_file:
      - /mnt/hd2t/services/nextcloud/.env
    environment:
      TZ: ${TZ}

    command:
      - "sh"
      - "-c"
      - 'exec redis-server --requirepass "$$(cat /run/secrets/redis_password)" --save "" --appendonly no --maxmemory 128mb --maxmemory-policy allkeys-lru'

    volumes:
      - type: bind
        source: /mnt/hd2t/services/nextcloud/redis/data
        target: /data
        bind:
          create_host_path: false
      - type: bind
        source: /mnt/hd2t/services/nextcloud/secrets/redis_password
        target: /run/secrets/redis_password
        read_only: true
        bind:
          create_host_path: false

    networks:
      - nextcloud_internal

    cap_drop:
      - ALL

    security_opt:
      - no-new-privileges:true

    healthcheck:
      test:
        - CMD-SHELL
        - 'redis-cli -a "$$(cat /run/secrets/redis_password)" ping | grep -q PONG'
      interval: 15s
      timeout: 3s
      retries: 5
      start_period: 5s

    labels:
      com.centurylinklabs.watchtower.enable: "false"

networks:
  homelab:
    external: true
  nextcloud_internal:
    driver: bridge
    internal: true        # SIN ruta al exterior — sólo intra-stack.
```

### 5.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `name: nextcloud` | Coincide con el directorio del stack y con la fila §1.1 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). |
| `nextcloud.image` | Tag fijo desde `.env`. La línea 30.x es estable, soporte hasta junio 2026. |
| `MYSQL_HOST: mariadb` | DNS interno de `nextcloud_internal`. Resuelve al `hostname: mariadb`. |
| `REDIS_HOST: redis` / `_PORT: "6379"` | Idem. La imagen oficial de Nextcloud lee estas dos vars y autoconfigura `config.php` (`memcache.locking`, `memcache.distributed`, `redis.host`). |
| `NEXTCLOUD_ADMIN_USER` / `_PASSWORD_FILE` | Sólo se aplican en el **primer arranque**, cuando Nextcloud detecta que no hay `config.php` y se autoinstala. En arranques posteriores se ignoran (lo lógico). |
| `OVERWRITEPROTOCOL: https` | §0 fila correspondiente. Imprescindible. |
| `TRUSTED_PROXIES: "172.20.0.0/24"` | La subred completa del bridge `homelab`. Si Caddy cambia de IP, no hay que reconfigurar Nextcloud. |
| `NEXTCLOUD_TRUSTED_DOMAINS: ...` | Multi-line con `>-` (folded scalar): los hostnames se separan por espacio. Los procesa el entrypoint y los inyecta en `config.php` como `trusted_domains[]`. |
| `OC_CRON: "true"` | El entrypoint añade un crontab que ejecuta `/cron.sh` cada 5 min como `www-data`. Sin esto, hay que añadir un sidecar (más complejidad). |
| `PHP_UPLOAD_LIMIT: 10G` | Para subir vídeos de móvil sin trocear. Apache + mod_php gestionan bien archivos grandes con chunking del cliente. |
| `bind … create_host_path: false` | Si el directorio del host no existe, falla en lugar de crearlo silenciosamente con permisos malos. Plantilla §6 de estructura-compose. |
| `cap_add: [CHOWN, SETGID, SETUID, DAC_OVERRIDE, NET_BIND_SERVICE]` | El mínimo set para Apache + entrypoint que hace `chown -R 33:33 /var/www/html` al primer arranque. |
| `healthcheck nextcloud` | Marca `unhealthy` si la app no responde, está en `maintenance: true`, o si MariaDB cae y `status.php` empieza a devolver errores. |
| `start_period: 120s` (Nextcloud) | El primer arranque autoinstala todas las tablas; en una Pi 5 puede tardar 60–90 s. 120 s es holgura. |
| `depends_on.{mariadb,redis}.condition: service_healthy` | Sin esto, Nextcloud arranca antes de que MariaDB acepte conexiones, falla la autoinstalación y queda "instalado a medias" (estado feo de recuperar). |
| `mariadb.command --transaction-isolation=READ-COMMITTED --binlog-format=ROW` | Recomendaciones explícitas de [Nextcloud — Database configuration](https://docs.nextcloud.com/server/latest/admin_manual/configuration_database/linux_database_configuration.html). Sin esto, `oc_filecache` sufre lock waits con varios clientes simultáneos. |
| `mariadb --skip-innodb-read-only-compressed` | Suprime warnings al arrancar con tablas comprimidas heredadas; no afecta funcionalidad. |
| `mariadb-admin ping` healthcheck | Endpoint canónico de la imagen oficial. Usa el `db_root_password` del fichero (no aparece en argv inspeccionable desde fuera). |
| `redis --requirepass "$(cat ...)"` | Patrón idéntico al stack `auth` ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §7). Los `$$` escapan a `$` literal en Compose; el shell del contenedor sustituye `$(cat ...)` al arrancar. |
| `redis --save "" --appendonly no --maxmemory 128mb --maxmemory-policy allkeys-lru` | Sin persistencia: locks son efímeros, cache reconstructible. 128 MiB cubre cómodamente los locks de 1–4 usuarios. LRU evita OOM. |
| `networks.nextcloud_internal.internal: true` | **Aislamiento real**: desactiva la ruta NAT del bridge → MariaDB y Redis no tienen salida a internet ni reciben tráfico de fuera de la Pi. La misma postura que el `auth_internal` del stack `auth`. |

### 5.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/nextcloud
docker compose --env-file /mnt/hd2t/services/nextcloud/.env config >/dev/null \
  && echo "Compose OK"
```

Errores típicos en este punto:

- `service "nextcloud" depends on service "mariadb" which has no healthcheck` → ya está añadido, revisar mismatch de indentación.
- `network homelab declared as external, but could not be found` → la red `homelab` no existe; crearla según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2.

---

## 6. Despliegue

### 6.1. Primer arranque

```bash
cd ~/homelab/stacks/nextcloud
docker compose --env-file /mnt/hd2t/services/nextcloud/.env up -d
```

Salida esperada:

```
[+] Running 4/4
 ✔ Network nextcloud_nextcloud_internal   Created
 ✔ Container redis-nextcloud              Started
 ✔ Container mariadb-nextcloud            Started
 ✔ Container nextcloud                    Started
```

El primer arranque ejecuta:

1. `mariadb-init` crea la BD `nextcloud` y el usuario `nextcloud` con `db_password`.
2. `redis-server` arranca y queda listo en ~2 s.
3. Nextcloud detecta `config.php` ausente → ejecuta el `occ maintenance:install` automático con las env vars (admin user, BD, Redis). Tarda ~60–90 s en una Pi 5: crea ~150 tablas, descarga el árbol `apps/`, escribe el `config/config.php` inicial.

### 6.2. Estado de los contenedores

```bash
docker compose ps
# Esperado, tras ~2 minutos:
# NAME                IMAGE                              STATUS                  PORTS
# nextcloud           nextcloud:30-apache                Up X (healthy)
# mariadb-nextcloud   mariadb:11.4                       Up X (healthy)
# redis-nextcloud     redis:7.4-alpine                   Up X (healthy)
```

Si algún contenedor entra en `(unhealthy)`:

```bash
docker compose logs nextcloud | tail -50
docker compose logs mariadb   | tail -30
docker compose logs redis     | tail -10
```

Eventos esperados en los logs de Nextcloud al primer arranque:

```
Initializing nextcloud 30.x.x ...
Installing with mysql database
starting nextcloud installation
Nextcloud was successfully installed
Initializing finished
[Tue ... INFO  apache2 (pid X) configured -- resuming normal operations]
```

Tras la instalación, la imagen ejecuta cada arranque un check de versión (`occ upgrade` automático sólo si la versión del contenedor > la de la BD; en el mismo tag, no hace nada).

### 6.3. Smoke test desde Caddy

```bash
# Caddy alcanza Nextcloud por nombre Docker:
docker exec caddy wget -qO- http://nextcloud:80/status.php
# Esperado: JSON con "installed":true, "maintenance":false, "version":"30.x.x".
```

### 6.4. Smoke test desde el host

```bash
# Nextcloud NO debe ser alcanzable desde la IP del host:
curl -sf http://192.168.1.10:80 -m 2 ; echo "exit=$?"
# Esperado: exit=7 (connection refused) — Caddy responde 404 si llega allí
# (puerto 80 es de Caddy), pero el contenedor de Nextcloud NO escucha en 80
# del host. Lo importante: nada de Nextcloud :80 en `sudo ss -ltn`.

sudo ss -ltn '( sport = :3306 or sport = :6379 )'
# Esperado: vacío.
```

---

## 7. Integración con Caddy

### 7.1. Snippet con bypass para clientes WebDAV

Crear `~/homelab/stacks/proxy/snippets/nextcloud_well_known` (en el stack `proxy`):

```caddy
# ~/homelab/stacks/proxy/snippets/nextcloud_well_known
# Atajos para los .well-known/* que Nextcloud espera responder bajo dominios
# sin sub-path. Recomendado por Nextcloud "Setup warnings".
(nextcloud_well_known) {
    @well_known {
        path /.well-known/carddav
        path /.well-known/caldav
        path /.well-known/webfinger
        path /.well-known/nodeinfo
    }
    redir @well_known /remote.php{uri} 301
}
```

### 7.2. Bloque `nextcloud.lan` en el `Caddyfile`

Editar `~/homelab/stacks/proxy/Caddyfile` y reemplazar el bloque comentado `# Nextcloud` (creado en [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §X) por este:

```caddy
# Nextcloud (../06-almacenamiento/01-nextcloud.md)
nextcloud.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    import nextcloud_well_known

    # Tamaño máximo de body: alineado con PHP_UPLOAD_LIMIT (10G).
    request_body {
        max_size 10GB
    }

    # Cabeceras adicionales recomendadas por Nextcloud.
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        Referrer-Policy "no-referrer"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        X-Permitted-Cross-Domain-Policies "none"
        X-Robots-Tag "noindex, nofollow"
    }

    # ----- Paths que NO deben pasar por Authelia (clientes de sync) -----
    # Cualquiera con prefijo /remote.php, /public.php, /ocs, /ocm-provider,
    # /.well-known, /cron.php, /status.php — auth la lleva el propio Nextcloud.
    @sync_paths {
        path /remote.php* /public.php* /ocs/* /ocm-provider/* /.well-known/* /cron.php /status.php
    }
    handle @sync_paths {
        reverse_proxy http://nextcloud:80
    }

    # ----- Resto: UI humana, protegida por Authelia 2FA -----
    handle {
        import authelia_proxy
        reverse_proxy http://nextcloud:80
    }
}
```

> **Por qué `handle` y no varios `reverse_proxy`**: Caddy evalúa todos los matchers cuando se mezclan en el mismo bloque, lo que daba duplicados. `handle` es un "switch" excluyente: la primera condición que matchea es la única que se ejecuta. Patrón documentado en [Caddy — Common Caddyfile Patterns](https://caddyserver.com/docs/caddyfile/patterns).

Asegurarse de que el snippet `authelia_proxy` ya existe (lo creó [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §9.1):

```bash
ls ~/homelab/stacks/proxy/snippets/authelia_proxy
```

Recargar Caddy sin downtime:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

### 7.3. Confirmar la regla en Authelia

Editar `~/homelab/stacks/auth/configuration.yml` y, en `access_control.rules`, refinar la entrada para Nextcloud. La regla creada en [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §5 ya menciona `nextcloud.lan` con `policy: two_factor`; ahora se le añade un **bypass explícito** para los paths de sync (defensa en profundidad: aunque Caddy ya los excluya, si alguien activa Authelia en otro proxy, los clientes seguirán funcionando):

```yaml
access_control:
  default_policy: deny
  rules:
    # ... reglas previas (auth.lan bypass, etc.)

    # Nextcloud — bypass para paths de sync (Caddy ya los aplica con handle).
    - domain: "nextcloud.{{ env "LAN_DOMAIN" }}"
      resources:
        - "^/remote\\.php(/.*)?$"
        - "^/public\\.php(/.*)?$"
        - "^/ocs(/.*)?$"
        - "^/ocm-provider(/.*)?$"
        - "^/\\.well-known(/.*)?$"
        - "^/cron\\.php$"
        - "^/status\\.php$"
      policy: bypass

    # ... reglas por defecto two_factor ya existentes (nextcloud.lan en la lista)
```

Y reiniciar Authelia (no soporta `watch:` para `configuration.yml`):

```bash
docker compose -f ~/homelab/stacks/auth/docker-compose.yml restart authelia
```

### 7.4. Añadir el registro DNS local en Pi-hole

Pi-hole UI → **Local DNS** → **DNS Records** → añadir:

```
nextcloud.lan → 192.168.1.10
```

```bash
docker exec pihole pihole reloaddns
dig +short @192.168.1.241 nextcloud.lan
# Esperado: 192.168.1.10
```

### 7.5. Probar el portal

Desde un cliente con `root.crt` instalado:

```
https://nextcloud.lan
```

- Primera carga: Authelia pide login + TOTP.
- Tras éxito: Nextcloud muestra su pantalla de login.
- Introducir `homelab` y el `admin_password` generado en §4.
- Nextcloud guía por el setup inicial: tour, recomendar apps. Cancelar el tour (se vuelve a él más tarde) y entrar al dashboard.

> **Nota sobre la doble auth**: la primera vez es desconcertante (login Authelia → login Nextcloud). Es el compromiso de §0 punto 6. Para evitarlo y tener SSO real, ver §13.5 "Activar OIDC con Authelia". En la práctica diaria, la cookie de Authelia (1h de inactividad) y la sesión de Nextcloud (PHP) se sincronizan: el operador sólo ve la primera al inicio del día.

---

## 8. Configuración post-despliegue

### 8.1. Cambiar el password del admin

Inmediatamente, desde la UI:

- Avatar (esquina superior derecha) → **Configuración personal** → **Seguridad** → **Cambiar contraseña**.
- Anotar la nueva en el gestor de contraseñas (KeePassXC; Vaultwarden cuando esté arriba).
- El `admin_password` de `/run/secrets/admin_password` ya no se usa (sólo aplicaba al primer arranque). Por higiene, regenerarlo en §4 y dejarlo de tamaño máximo, sin importar.

### 8.2. Confirmar `trusted_domains` y `trusted_proxies` vía `occ`

```bash
# Listar config actual:
docker exec -u www-data nextcloud php occ config:system:get trusted_domains
# Esperado: ["nextcloud.lan", "nextcloud.tailnet.ts.net"]

docker exec -u www-data nextcloud php occ config:system:get trusted_proxies
# Esperado: ["172.20.0.0/24"]

docker exec -u www-data nextcloud php occ config:system:get overwriteprotocol
# Esperado: "https"
```

Si algún valor falta (porque se editó `.env` después del primer arranque, no se aplica retroactivamente), añadirlo manualmente:

```bash
docker exec -u www-data nextcloud php occ config:system:set trusted_domains 1 \
  --value="nextcloud.tailnet.ts.net"
docker exec -u www-data nextcloud php occ config:system:set trusted_proxies 0 \
  --value="172.20.0.0/24"
```

### 8.3. Comprobar memcache/locking

```bash
docker exec -u www-data nextcloud php occ config:system:get memcache.local
# Esperado: "\\OC\\Memcache\\APCu"

docker exec -u www-data nextcloud php occ config:system:get memcache.distributed
# Esperado: "\\OC\\Memcache\\Redis"

docker exec -u www-data nextcloud php occ config:system:get memcache.locking
# Esperado: "\\OC\\Memcache\\Redis"

docker exec -u www-data nextcloud php occ config:system:get redis
# Esperado: array con "host":"redis", "port":6379, "password":"<32 chars>".
```

Si alguno falta (no debería: la imagen oficial los pone solo si `REDIS_HOST` está set), añadirlos:

```bash
docker exec -u www-data nextcloud php occ config:system:set memcache.local --value='\OC\Memcache\APCu'
docker exec -u www-data nextcloud php occ config:system:set memcache.distributed --value='\OC\Memcache\Redis'
docker exec -u www-data nextcloud php occ config:system:set memcache.locking --value='\OC\Memcache\Redis'
```

### 8.4. Configurar el cron como background job

Por defecto, Nextcloud usa "AJAX" (cada vez que un usuario navega, ejecuta tareas pendientes). Eso es lento. Como `OC_CRON=true` ya añadió un crontab dentro del contenedor, sólo hay que decírselo a Nextcloud:

```bash
docker exec -u www-data nextcloud php occ background:cron
# Esperado: "Set mode for background jobs to 'cron'"
```

Verificar en la UI: **Configuración → Configuración básica → Tareas en segundo plano** debe mostrar **Cron** (no AJAX).

### 8.5. Apps recomendadas

Activar desde **Configuración → Aplicaciones** o vía CLI:

```bash
# Calendar (CalDAV)
docker exec -u www-data nextcloud php occ app:install calendar

# Contacts (CardDAV)
docker exec -u www-data nextcloud php occ app:install contacts

# Notes
docker exec -u www-data nextcloud php occ app:install notes

# Tasks
docker exec -u www-data nextcloud php occ app:install tasks

# Photos (galería con detección de localización)
docker exec -u www-data nextcloud php occ app:install photos

# Brute Force Settings (UI para gestionar IPs baneadas)
docker exec -u www-data nextcloud php occ app:install bruteforcesettings
```

Apps **no recomendadas** en este homelab (se cubren con servicios dedicados):

- **News** → ya hay FreshRSS planeado en [`../11-productividad/07-freshrss.md`](../11-productividad/07-freshrss.md).
- **Talk** → consume mucha CPU en una Pi 5 (TURN/STUN), mejor evaluar tras reposo del resto.
- **Mail** → configurar un cliente IMAP fuera del homelab es más sencillo; si se quiere webmail, evaluar Stalwart o Roundcube en su propio stack.
- **Office (Collabora)** → contenedor pesado (>1 GB RAM), evaluar en tono de Fase 11+.

### 8.6. Comprobar el "Health check" de Nextcloud

UI → **Configuración → Información de administración**. Después del primer arranque suelen aparecer warnings; los relevantes son:

| Warning | Acción |
|---|---|
| `The reverse proxy header configuration is incorrect, or you are accessing Nextcloud from a trusted proxy` | Confirmar `TRUSTED_PROXIES` en §8.2. Falso positivo si el origen del request es la propia red Caddy. |
| `Some indices are missing` (oc_filecache, oc_authtoken, etc.) | `docker exec -u www-data nextcloud php occ db:add-missing-indices` |
| `MariaDB version 10.x detected, 10.6+ is recommended` | No aparece (usamos 11.4). |
| `The database is missing some primary keys` | `docker exec -u www-data nextcloud php occ db:add-missing-primary-keys` |
| `Strict cookie not set` | Añadir `'overwriteCondAddr' => '^172\\.20\\.'` al `config.php` (sólo si las cookies de Authelia llegan sin Strict). Generalmente no aparece tras §8.2. |
| `Last cron job execution: hace X minutos` (>15 min) | Confirmar `OC_CRON=true` y §8.4. |

### 8.7. Crear un app password para los clientes de sync

UI → avatar → **Configuración personal → Seguridad → Devices & sessions**:

1. Introducir un nombre ("Nextcloud Desktop", "Móvil OnePlus", "iPad Pro").
2. **Create new app password** → guarda el token de 64 chars.
3. Pegar el token en el cliente (Nextcloud Desktop / DAVx5 / Nextcloud Android).
4. Repetir por dispositivo. Cada dispositivo se puede revocar por separado desde la misma UI.

> **Importante**: el cliente conecta a `https://nextcloud.lan` con usuario `homelab` + el app password. NO el password humano. Si el dispositivo se pierde, sólo se revoca su token. Esto es independiente del TOTP del operador en Authelia (los clientes hacen bypass de Authelia por §7).

---

## 9. Verificación

### 9.1. Contenedores sanos

```bash
docker compose -f ~/homelab/stacks/nextcloud/docker-compose.yml ps
# STATUS de los tres: "Up X (healthy)".
```

### 9.2. No hay puertos publicados

```bash
docker port nextcloud
docker port mariadb-nextcloud
docker port redis-nextcloud
# Esperado: vacío en los tres.

sudo ss -ltn | awk '$4 ~ /:(80|443|3306|6379)$/'
# Sólo deben aparecer 80/443 (Caddy). Nada de 3306 ni 6379.
```

### 9.3. Acceso DAV desde la LAN (cliente sync)

```bash
# PROPFIND a la raíz DAV con app password (sustituir TOKEN):
curl -sS -u "homelab:TOKEN" -X PROPFIND -H "Depth: 1" \
  https://nextcloud.lan/remote.php/dav/files/homelab/ \
  | head -20
# Esperado: XML con <d:multistatus> y la lista de carpetas root.
# Si responde HTML de Authelia, Caddy NO está aplicando el bypass de §7.2.
```

### 9.4. CalDAV funciona

```bash
curl -sS -u "homelab:TOKEN" -X PROPFIND -H "Depth: 1" \
  https://nextcloud.lan/remote.php/dav/calendars/homelab/ \
  | head -20
# Esperado: XML con los calendarios del usuario.
```

### 9.5. Cert hoja firmado por la CA interna

```bash
echo | openssl s_client -connect nextcloud.lan:443 -servername nextcloud.lan 2>/dev/null \
  | openssl x509 -noout -issuer -subject
# Esperado:
#   issuer=  CN = Caddy Local Authority - 2024 ECC Intermediate
#   subject= CN = nextcloud.lan
```

### 9.6. Trusted proxies funciona (logs muestran IP cliente real)

Hacer un login fallido desde la LAN y revisar:

```bash
docker exec nextcloud tail -20 /var/www/html/data/nextcloud.log | grep -i 'login'
```

Esperado: la IP que aparece como `remoteAddress` debe ser la del cliente real (`192.168.1.5`, p. ej.), **no** la del contenedor Caddy (`172.20.0.X`).

### 9.7. Persistencia tras reboot

```bash
sudo reboot
# (esperar a que vuelva)

docker compose -f ~/homelab/stacks/nextcloud/docker-compose.yml ps
# Esperado: los tres (healthy).

# Login web sigue funcionando.
# Cliente desktop reconecta automáticamente; pequeñas subidas en curso reanudan.
```

### 9.8. Lista de Verificación

Antes de pasar a [`02-samba.md`](./02-samba.md):

- [ ] `docker compose ps` en el stack `nextcloud` → tres `(healthy)`.
- [ ] `sudo ss -ltn | grep -E ':(3306|6379)'` → vacío en el host.
- [ ] `https://nextcloud.lan` carga la pantalla de Authelia, tras login carga la de Nextcloud.
- [ ] Login con `homelab` + nuevo password → dashboard accesible.
- [ ] El operador ha **anotado fuera del homelab** el nuevo password admin de Nextcloud.
- [ ] `docker exec -u www-data nextcloud php occ status` → `installed: true`, sin `maintenance: true`.
- [ ] Setup warnings en `Información de administración` → 0 críticos (algunos informativos son OK).
- [ ] Cron en modo `cron` (no AJAX), última ejecución <10 min.
- [ ] Apps `calendar`, `contacts`, `notes`, `tasks`, `photos`, `bruteforcesettings` instaladas y enabled.
- [ ] Cliente de sync (Desktop/Android/iOS) conectado con app password, primera sincronización OK.
- [ ] Cliente CalDAV (DAVx5/Apple Calendar/Thunderbird) conectado, calendarios y contactos visibles.
- [ ] Tras `sudo reboot`, los tres contenedores arrancan y la UI sigue funcionando.
- [ ] `~/homelab/stacks/nextcloud/{docker-compose.yml,.env.example,snippets-caddy/*}` versionados en git; **`.env` y `secrets/*` NO**.
- [ ] `/mnt/hd2t/services/nextcloud/secrets/*` con permisos `600 homelab:homelab` y el directorio padre `700 homelab:homelab`.

---

## 10. Backup

Estrategia que se concretará en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md). Lo que **debe respaldarse** del stack `nextcloud`:

| Ruta | Qué contiene | Frecuencia | Cómo |
|---|---|---|---|
| `~/homelab/stacks/nextcloud/{docker-compose.yml,.env.example,snippets-caddy/*}` | Definición del stack y snippets de Caddy. | Versionado en git → `git push`. | Continuo. |
| `/mnt/hd2t/services/nextcloud/.env` | Variables del stack (no contiene secretos críticos pero sí el dominio y los tags). | Reconstruible desde `.env.example`. Opcional. | Snapshot Borg. |
| `/mnt/hd2t/services/nextcloud/secrets/{db_root_password,db_password,redis_password,admin_password}` | **Críticos**. La pérdida de `db_password` impide arrancar Nextcloud sin reset manual; la pérdida de `db_root_password` rompe `MARIADB_AUTO_UPGRADE`. | **Diaria**, dentro del backup de Borg con cifrado fuerte. | Snapshot Borg. |
| `/mnt/hd2t/services/nextcloud/db/data/` | Tablas InnoDB. **Nunca** snapshotear el directorio "vivo": MariaDB puede tener páginas no flusheadas y el restore quedaría corrupto. | **Diaria**, vía dump previo. | `before_backup` hook → `mariadb-dump` → archivo en `/mnt/hd2t/backups/dumps/mariadb/nextcloud-YYYY-MM-DD.sql.gz`. |
| `/mnt/hd2t/services/nextcloud/nextcloud/html/` (excluyendo `data/` que está montado dentro) | Código + `config/` + `apps/` + `themes/`. | **Semanal** (cambia poco entre upgrades). | Snapshot Borg con exclusión `data/`. |
| `/mnt/hd2t/services/nextcloud/nextcloud/data/` | Ficheros de usuario + `appdata_<instanceid>/` (caches Photos, Preview Generator). | **Diaria** diferencial. | Snapshot Borg. Borg deduplica los blobs binarios; `appdata_*/preview/*` se puede excluir si el backup pesa demasiado (se regenera). |
| `/mnt/hd2t/services/nextcloud/redis/data/` | Locks efímeros. **No backup**: pérdida = clientes hacen retry. | No backup. | — |

### 10.1. Pre-backup hook (ejemplo Borgmatic)

```yaml
# Pseudo-config; la real va en 07-backups/02-borgmatic.md.
before_backup:
  # 1. Modo mantenimiento OFF para no perder uploads en curso (snapshot online).
  #    Alternativa más segura: maintenance:mode --on, dump, --off. Aquí se opta
  #    por dump online: MariaDB con --single-transaction es consistente.

  # 2. Dump de la BD a /mnt/hd2t/backups/dumps/mariadb/.
  - >
    docker exec mariadb-nextcloud sh -c
    'mariadb-dump --single-transaction --routines --triggers --events
       -uroot -p"$$(cat /run/secrets/db_root_password)" nextcloud
     | gzip -c'
    > /mnt/hd2t/backups/dumps/mariadb/nextcloud-$(date +%F).sql.gz

  # 3. (Opcional) snapshot rápido de config.php para diffing entre backups.
  - cp /mnt/hd2t/services/nextcloud/nextcloud/html/config/config.php \
       /mnt/hd2t/backups/configs/nextcloud-config-$(date +%F).php

after_backup:
  # 4. Limpiar dumps de >14 días (Borg ya los tiene archivados).
  - find /mnt/hd2t/backups/dumps/mariadb/ -name 'nextcloud-*.sql.gz' -mtime +14 -delete
```

### 10.2. Restore (resumen)

Procedimiento completo en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md). Resumen:

1. `docker compose down`.
2. Restaurar `db/data/` desde Borg (o, si se prefiere clean restore, vaciar `db/data/` y reaplicar el dump tras arrancar MariaDB con BD vacía).
3. Restaurar `nextcloud/html/` y `nextcloud/data/`.
4. Restaurar `secrets/`.
5. `docker compose up -d`.
6. `docker exec -u www-data nextcloud php occ maintenance:repair`.

> **Punto crítico**: el dump de MariaDB y el `nextcloud/data/` deben corresponder al **mismo momento**. Si se mezclan (dump del día N + data del día N+1), `oc_filecache` apunta a ficheros que no existen y la UI muestra "no se puede descargar". Por eso `before_backup` los snapshote en el mismo run.

---

## 11. Operaciones cotidianas

### 11.1. Upgrade a un nuevo patch (30.0.x → 30.0.y)

```bash
# 1. Leer las release notes:
# https://github.com/nextcloud/server/releases

# 2. Backup previo (forzar Borgmatic una vez):
sudo borgmatic create --verbosity 1   # cuando esté instalado.

# 3. Actualizar el tag en /mnt/hd2t/services/nextcloud/.env:
sudo -u homelab sed -i 's|^NEXTCLOUD_IMAGE_TAG=.*|NEXTCLOUD_IMAGE_TAG=30.0.5-apache|' \
  /mnt/hd2t/services/nextcloud/.env

# 4. Pull + recreate sólo el contenedor de Nextcloud:
cd ~/homelab/stacks/nextcloud
docker compose --env-file /mnt/hd2t/services/nextcloud/.env pull nextcloud
docker compose --env-file /mnt/hd2t/services/nextcloud/.env up -d --force-recreate nextcloud

# 5. La imagen detecta diferencia de versión y ejecuta `occ upgrade` automático.
#    Verificar:
docker logs -f nextcloud
# Esperado: "Initializing nextcloud 30.0.5 ..." → "Update successful" → "Apache started".

# 6. Confirmar:
docker exec -u www-data nextcloud php occ status
# version: 30.0.5.x, installed: true, maintenance: false.
```

### 11.2. Upgrade a un nuevo major (30 → 31)

**Prerequisito**: leer [Maintenance and Release Schedule](https://github.com/nextcloud/server/wiki/Maintenance-and-Release-Schedule) y la release announcement del nuevo major. NO saltar majors.

```bash
# 1. Backup completo (Borg + dump explícito).
# 2. Modo mantenimiento ON:
docker exec -u www-data nextcloud php occ maintenance:mode --on
# 3. Dump explícito:
docker exec mariadb-nextcloud sh -c \
  'mariadb-dump --single-transaction -uroot -p"$(cat /run/secrets/db_root_password)" nextcloud' \
  | gzip > /mnt/hd2t/backups/dumps/mariadb/nextcloud-pre-upgrade-$(date +%F).sql.gz
# 4. Cambiar tag a 31-apache, pull, recreate.
# 5. La imagen autoejecuta `occ upgrade`. Si falla:
docker exec -u www-data nextcloud php occ upgrade
# 6. Maintenance:mode OFF:
docker exec -u www-data nextcloud php occ maintenance:mode --off
# 7. Reactivar apps deshabilitadas por incompatibilidad:
docker exec -u www-data nextcloud php occ app:list | head -50
docker exec -u www-data nextcloud php occ app:enable <app>   # caso por caso
```

### 11.3. Comandos `occ` frecuentes

```bash
# Lista de usuarios:
docker exec -u www-data nextcloud php occ user:list

# Crear un usuario (interactivo, pide password):
docker exec -it -u www-data nextcloud php occ user:add nuevo

# Resetear password de un usuario:
docker exec -it -u www-data nextcloud php occ user:resetpassword homelab

# Forzar escaneo de ficheros (tras cambios fuera de la UI):
docker exec -u www-data nextcloud php occ files:scan --all
docker exec -u www-data nextcloud php occ files:scan homelab

# Mantenimiento general:
docker exec -u www-data nextcloud php occ maintenance:repair
docker exec -u www-data nextcloud php occ db:add-missing-indices
docker exec -u www-data nextcloud php occ db:add-missing-primary-keys
docker exec -u www-data nextcloud php occ db:convert-filecache-bigint
```

### 11.4. Modo mantenimiento (para tareas largas)

```bash
docker exec -u www-data nextcloud php occ maintenance:mode --on
# UI muestra "Service unavailable", clientes de sync hacen exponential backoff.
# ... operaciones invasivas ...
docker exec -u www-data nextcloud php occ maintenance:mode --off
```

### 11.5. Rotar secretos

**`db_password`**:

1. Cambiar el password en MariaDB:
   ```bash
   docker exec mariadb-nextcloud sh -c \
     'mariadb -uroot -p"$(cat /run/secrets/db_root_password)" \
        -e "ALTER USER '\''nextcloud'\''@'\''%'\'' IDENTIFIED BY '\''NEW_PWD'\''; FLUSH PRIVILEGES;"'
   ```
2. Sustituir el fichero del secreto en el host:
   ```bash
   echo -n "NEW_PWD" | sudo tee /mnt/hd2t/services/nextcloud/secrets/db_password
   ```
3. Cambiar `dbpassword` en `config/config.php` (lo lee Nextcloud al arranque, NO la env):
   ```bash
   docker exec -u www-data nextcloud php occ config:system:set dbpassword --value="NEW_PWD"
   ```
4. `docker compose restart nextcloud`.

**`redis_password`**:

1. Sustituir el fichero: `echo -n "NEW_PWD" | sudo tee .../redis_password`.
2. `docker compose restart redis nextcloud` (en este orden — Nextcloud depende de Redis).

**`db_root_password`**:

1. Cambiar en MariaDB:
   ```bash
   docker exec mariadb-nextcloud sh -c \
     'mariadb -uroot -p"$(cat /run/secrets/db_root_password)" \
        -e "ALTER USER '\''root'\''@'\''localhost'\'' IDENTIFIED BY '\''NEW_ROOT'\''; FLUSH PRIVILEGES;"'
   ```
2. Sustituir el fichero del secreto.
3. `docker compose restart mariadb` (no es estrictamente necesario, pero confirma).

### 11.6. Espacio ocupado, top usuarios, top ficheros

```bash
# Por usuario:
docker exec -u www-data nextcloud php occ files:scan --quiet --all
docker exec mariadb-nextcloud sh -c \
  'mariadb -uroot -p"$(cat /run/secrets/db_root_password)" nextcloud \
     -e "SELECT user_id, ROUND(SUM(size)/1024/1024, 2) AS MB
         FROM oc_filecache
         WHERE storage IN (SELECT numeric_id FROM oc_storages WHERE id LIKE '\''home::%'\'')
         GROUP BY user_id;"'

# Espacio total del bind mount data/:
sudo du -sh /mnt/hd2t/services/nextcloud/nextcloud/data/
```

---

## 12. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| Primer arranque: `nextcloud` queda en `(unhealthy)` y los logs muestran `MySQL server has gone away` o `Lost connection to MySQL server` | MariaDB tarda más de 30 s en responder en una Pi 5 con I/O lento. | Subir `start_period: 30s` a `60s` en el healthcheck de MariaDB y `start_period: 120s` a `180s` en el de Nextcloud. |
| Login da "Access through untrusted domain" | El dominio del request no está en `trusted_domains`. | Confirmar `NEXTCLOUD_TRUSTED_DOMAINS` en `.env` y, vía `occ`, `config:system:get trusted_domains`. Añadir si falta. |
| Login da "Trusted proxies header value invalid" o todos los logins se registran como viniendo de `172.20.x.y` | `TRUSTED_PROXIES` vacío o no incluye la subred de `homelab`. | Confirmar `TRUSTED_PROXIES=172.20.0.0/24` y reiniciar. Verificar con `occ config:system:get trusted_proxies`. |
| Cliente Desktop no conecta: "Server replied HTTP 401" | Authelia está interceptando WebDAV. | Confirmar el snippet `nextcloud_well_known` y el `handle @sync_paths` en el Caddyfile (§7.2). `curl -u user:token -X PROPFIND ...` debe responder XML, no HTML de Authelia. |
| `https://nextcloud.lan/.well-known/caldav` da 404 | El snippet `nextcloud_well_known` no está importado o el orden de los `handle` es incorrecto. | Confirmar `import nextcloud_well_known` antes de `handle`. Recargar Caddy. |
| UI muestra `The reverse proxy header configuration is incorrect` | El request llega con `X-Forwarded-For` pero `trusted_proxies` no incluye al emisor. | Igual que arriba. |
| Sync queda colgado, "Connection timed out" desde el cliente | `request_body max_size` bajo en Caddy (default 10MB) corta uploads grandes. | Confirmar `request_body { max_size 10GB }` en el bloque `nextcloud.lan`. |
| `occ upgrade` falla con "Mismatch between database tables and code" | Upgrade interrumpido a la mitad. | Restaurar el dump previo (§10), o `occ maintenance:repair --include-expensive`. |
| MariaDB falla al arrancar con `mysql_native_password is deprecated` (warning) o `caching_sha2_password not supported` | MariaDB 11.x usa `caching_sha2_password` por defecto y algunas combinaciones de imagen Nextcloud no lo soportan. | Resetear el usuario con `ALTER USER 'nextcloud'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('...');` |
| `redis-cli ping` desde dentro de Nextcloud funciona, pero `occ` reporta "Redis is not configured" | Caso raro: `config.php` se quedó sin la sección `redis`. | Reaplicar §8.3. |
| Background jobs siguen en "AJAX" tras §8.4 | El comando `occ background:cron` no tiene efecto si `OC_CRON=true` no está realmente arrancando el cron interno. | `docker exec nextcloud crontab -u www-data -l` debe listar `*/5 * * * * /cron.sh`. Si vacío, recrear el contenedor. |
| Cliente da "Invalid app password" tras 5 intentos rápidos | Bruteforce protection nativo de Nextcloud (delay creciente). | Esperar 1 min o `docker exec -u www-data nextcloud php occ security:bruteforce:reset 192.168.1.X`. |
| Subir ficheros >2 GB falla aunque `PHP_UPLOAD_LIMIT=10G` | Apache `LimitRequestBody` también lo limita; o Caddy `max_size` es el cuello. | Confirmar §7.2 (`max_size 10GB` en Caddy). El `PHP_UPLOAD_LIMIT` ya configura Apache vía la imagen oficial. |
| Notificaciones del cliente Desktop tardan 30 s | Comportamiento normal sin `notify-push` (polling). | Aceptarlo o desplegar `notify-push` (§13.4). |
| `data/` crece sin parar y `du` muestra mucho espacio en `appdata_*/preview/` | Generación masiva de previews tras importar fotos. | Aceptable; o `occ preview:repair --batch`. Excluir `appdata_*/preview/` del backup si pesa demasiado. |
| Tras un upgrade major, alguna app queda deshabilitada con "incompatible" | Comportamiento esperado: la app aún no soporta el nuevo major. | Esperar a que el desarrollador la actualice o buscar alternativa. La data del usuario en esa app no se pierde — vuelve cuando la app se reactiva. |
| `forward_auth` redirige al portal de Authelia y, tras login, vuelve a redirigir al login (loop) sólo en `nextcloud.lan` | Cookie `*.lan` no se está compartiendo entre dominios; `session.cookies[0].domain` en Authelia mal configurado. | Confirmar `session.cookies[0].domain: lan` en `~/homelab/stacks/auth/configuration.yml` y reiniciar Authelia. |
| `docker compose down` deja contenedores zombie en `Restarting` | Healthcheck timeouts mal alineados. | `docker compose kill && docker compose down -v` (sólo si se acepta perder Redis). Para parar limpio sin perder nada: `docker exec -u www-data nextcloud php occ maintenance:mode --on` antes del `down`. |

---

## 13. Variantes opt-in

### 13.1. Notify Push (server-push para clientes)

Mejora la latencia de notificaciones de cambios de fichero a los clientes Desktop/Mobile (de 30 s polling a <1 s push). Requiere un contenedor adicional `nextcloud-notify-push` que se conecta a Redis (lectura) y a la BD (lectura).

Esquema (no implementado en este doc, queda para una futura iteración):

1. Añadir servicio `notify-push` al `docker-compose.yml`.
2. Conectarlo a `nextcloud_internal` (necesita Redis y BD) y a `homelab` (Caddy debe alcanzarlo).
3. Añadir `handle /push/*` en el bloque de Caddy haciendo `reverse_proxy http://notify-push:7867`.
4. `occ config:system:set trusted_proxies 1 --value="caddy"`.

### 13.2. OIDC (SSO real con Authelia)

Suprime la "doble auth" descrita en §7.5. Requiere:

1. Activar el bloque `identity_providers.oidc` en `~/homelab/stacks/auth/configuration.yml` (comentado por defecto, ver [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §5).
2. Generar un cliente OIDC en Authelia con `client_id=nextcloud`, secreto correspondiente, `redirect_uris=[https://nextcloud.lan/index.php/apps/user_oidc/code]`.
3. Instalar la app `user_oidc` en Nextcloud:
   ```bash
   docker exec -u www-data nextcloud php occ app:install user_oidc
   ```
4. Configurar el provider desde la UI de Nextcloud (o vía `occ user_oidc:provider`).
5. Activar `force_oidc_login` para que Nextcloud rechace login local.

Tras eso, los clientes Desktop hablan OIDC con Authelia (los más nuevos lo soportan; los antiguos siguen necesitando app password).

### 13.3. Antivirus (clamav)

App `files_antivirus` + un sidecar de ClamAV. La Pi 5 procesa bien escaneos puntuales pero ClamAV residente consume ~600 MiB; se documenta como opt-in para entornos con varios usuarios. Saltar en homelab personal.

### 13.4. Encriptación server-side

App `encryption`. Cifra los ficheros en disco con claves por usuario. **NO** se recomienda en este homelab: añade overhead significativo y, sobre todo, complica el backup (los ficheros respaldados están cifrados, restaurarlos sin las claves master es imposible). El cifrado en reposo lo cubre Borg en el lado del backup ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) `encryption: repokey-blake2`).

### 13.5. PostgreSQL en lugar de MariaDB

Migrar es laborioso (`occ db:convert-type`). No recomendado salvo que se aproveche otro PostgreSQL ya desplegado para otros servicios (Paperless-ngx, Mealie). Si llega ese caso, reescribir este doc cambiando el bloque `mariadb` por `postgres:16-alpine` y adaptando las env vars (`POSTGRES_*`) y `command` (sin `transaction-isolation`, en Postgres es `default_transaction_isolation`).

---

## Referencias

- [Nextcloud — Documentación oficial (admin manual)](https://docs.nextcloud.com/server/latest/admin_manual/)
- [Nextcloud — Imagen Docker oficial](https://hub.docker.com/_/nextcloud)
- [Nextcloud — Reverse proxy configuration](https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/reverse_proxy_configuration.html)
- [Nextcloud — Database configuration (MariaDB)](https://docs.nextcloud.com/server/latest/admin_manual/configuration_database/linux_database_configuration.html)
- [Nextcloud — Memory caching (Redis, APCu)](https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/caching_configuration.html)
- [Nextcloud — Background jobs](https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/background_jobs_configuration.html)
- [Nextcloud — `occ` command reference](https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/occ_command.html)
- [Nextcloud — Upgrade procedure](https://docs.nextcloud.com/server/latest/admin_manual/maintenance/upgrade.html)
- [Nextcloud — Maintenance and Release Schedule](https://github.com/nextcloud/server/wiki/Maintenance-and-Release-Schedule)
- [Nextcloud — Hardening and security guidance](https://docs.nextcloud.com/server/latest/admin_manual/installation/harden_server.html)
- [Nextcloud — Source y CHANGELOG (GitHub)](https://github.com/nextcloud/server)
- [Nextcloud — `notify_push` (server-push para clientes)](https://github.com/nextcloud/notify_push)
- [Nextcloud — `user_oidc` (OIDC client)](https://github.com/nextcloud/user_oidc)
- [MariaDB — Imagen Docker oficial](https://hub.docker.com/_/mariadb)
- [MariaDB — `mariadb-dump`](https://mariadb.com/kb/en/mariadb-dump/)
- [Redis — Imagen Docker oficial](https://hub.docker.com/_/redis)
- [Caddy — `forward_auth` y `handle`](https://caddyserver.com/docs/caddyfile/directives/forward_auth)
