# Caddy

## Descripción

Despliegue de **Caddy 2** como **único reverse proxy del homelab**. Termina TLS por todos los servicios web internos, los expone bajo nombres limpios `https://<servicio>.lan` para la LAN y `https://<servicio>.${TS_DOMAIN}` para Tailscale (Fase 3.5), y centraliza cabeceras, compresión, redirecciones y, más adelante, autenticación SSO (`forward_auth` a Authelia, [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)).

Caddy vive en su propio stack `proxy` ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §1.1, fila `proxy → Caddy`), conectado **únicamente** a la red bridge `homelab`. **No** entra en la macvlan: el plan de IPs ([`01-macvlan.md`](./01-macvlan.md) §2) reserva la IP del host (`192.168.1.10`) para Caddy, que recibe `80/tcp` y `443/tcp` publicados al host. Pi-hole y Unbound siguen en la macvlan con sus IPs propias (`192.168.1.241` / `192.168.1.242`); cualquier otro servicio HTTP/HTTPS del homelab pasará a estar **detrás** de Caddy y dejará de publicar puertos al host (Portainer migra aquí su exposición, ver [`../02-docker/03-portainer.md`](../02-docker/03-portainer.md) §5).

Por qué exactamente esta arquitectura, y no otra:

1. **Un único punto de terminación TLS.** Cada servicio publicaría su propio TLS auto-firmado (Pi-hole genera uno al arranque, Portainer otro, Vaultwarden otro...) y la LAN acumularía cinco o seis "this site is not secure" distintos. Con Caddy delante, **una sola CA interna** (gestionada por el propio Caddy) firma todos los certificados `*.lan`. El operador instala el `root.crt` una vez en cada navegador/dispositivo y obtiene candado verde en todo el homelab.
2. **Caddyfile declarativo y versionable.** A diferencia de Nginx (sintaxis explícita pero verbose) o Traefik (configuración por labels difusa entre stacks), el `Caddyfile` es **un único fichero versionado en git** que declara TODO el routing del homelab en bloques `host { reverse_proxy backend }` legibles a primera vista. Diff y PR se leen en segundos.
3. **HTTPS automático con CA interna (`tls internal`).** Caddy 2 incluye una CA local que emite certificados de hoja válidos por 12 h, renovados automáticamente, para cualquier nombre. Ningún Let's Encrypt, ningún DNS-01, ningún DDNS — la LAN no tiene acceso desde internet ([`../00-hardware/02-esquema-conexiones.md`](../00-hardware/02-esquema-conexiones.md), [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md)).
4. **Acceso remoto vía Tailscale sin abrir puertos.** Para nombres bajo `${TS_DOMAIN}` (`pi.tailnet.ts.net`, `jellyfin.tailnet.ts.net`...), Tailscale provee certificados *Let's Encrypt-signed* mediante `tailscale cert` ([`05-tailscale.md`](./05-tailscale.md)). Caddy los monta como `tls /path/to/cert.pem /path/to/key.pem` en bloques específicos, sin exponer absolutamente nada a internet. Este doc deja **preparada** la integración (volúmenes, variables, snippet `tailscale_tls`) pero **no la activa**: Tailscale aún no está desplegado.
5. **Una sola red Docker.** Caddy se conecta solo a `homelab` (bridge `external`, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4). Para llegar a cualquier backend, basta con que ese backend también esté en `homelab` y se referencie por nombre Docker (`http://pihole`, `http://nextcloud:11000`, `http://jellyfin:8096`). Sin túneles, sin macvlan, sin `extra_hosts`.
6. **Watchtower excluido.** Caddy v2 ha cambiado sintaxis del `Caddyfile` entre minor releases (`global` options, `acme_dns` providers, `handle_path`...). Un upgrade automático a las 04:00 puede dejar el `Caddyfile` sin parsear y **toda la LAN sin acceso a HTTPS**. Documentado en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6 línea 450.

> **Alcance**: este documento despliega Caddy, persiste sus datos (CA interna, certificados, OCSP) en `hd2t`, escribe un `Caddyfile` versionado que ya cubre Pi-hole, Caddy mismo (página de bienvenida) y deja **placeholders** comentados para los próximos servicios de las Fases 4–11. **No** integra Authelia (`forward_auth`): eso entra en [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md). **No** activa los certificados de Tailscale: eso entra en [`05-tailscale.md`](./05-tailscale.md). **No** cambia la `:443` auto-firmada de Pi-hole: una vez Caddy responda en `https://pihole.lan` con CA interna, el aviso de cert del navegador desaparece sin tocar Pi-hole.

---

## Requisitos Previos

- **Docker Engine + Compose v2** instalados según [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md).
- **Red `homelab`** creada según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2 (`172.20.0.0/24`, bridge `br-homelab`).
- **Pi-hole desplegado** según [`02-pihole.md`](./02-pihole.md), conectado a la red `homelab` (puede llegar Caddy a `http://pihole:80`) y resolviendo `pihole.lan → 192.168.1.10` (registro local de Pi-hole, [§6.4 de `02-pihole.md`](./02-pihole.md#64-registros-dns-locales-para-servicios-del-homelab)).
- **Unbound desplegado** según [`03-unbound.md`](./03-unbound.md). No es estrictamente necesario para Caddy, pero el homelab estable presupone DNS recursivo funcional antes de continuar.
- **Plan de IPs** de [`01-macvlan.md`](./01-macvlan.md) §2 respetado: la IP `192.168.1.10` es del host (Pi), no de un contenedor macvlan; los puertos `80/tcp` y `443/tcp` del host están **libres** (no hay otro servicio que los use; Pi-hole los toma en `192.168.1.241`, no en la IP del host).
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). En §6.4 de este doc se añadirán reglas para `80/tcp` y `443/tcp` desde la subred LAN.
- **Estructura de directorios** de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) en su sitio: `/mnt/hd2t/services/` existe con propietario `homelab:homelab`. El bootstrap original creó `/mnt/hd2t/services/caddy/` ("un dir por servicio"); este doc usa el esquema vigente "un dir por stack" (`/mnt/hd2t/services/proxy/`) y muestra cómo migrar.
- **Comprobaciones rápidas**:
  ```bash
  # Puertos 80/443 libres en el host:
  sudo ss -ltn | awk '$4 ~ /:(80|443)$/'
  # No debe imprimir nada.

  # La red homelab existe:
  docker network inspect homelab --format '{{(index .IPAM.Config 0).Subnet}}'
  # Esperado: 172.20.0.0/24

  # Pi-hole alcanzable desde la red homelab por nombre:
  docker run --rm --network homelab alpine sh -c 'apk add -q curl && curl -fsS -o /dev/null -w "%{http_code}\n" http://pihole/admin/'
  # Esperado: 200 (o 302 si Pi-hole redirige).
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Imagen Docker | **`caddy:2.8.4-alpine`** | Imagen oficial multi-arch (incluye `linux/arm64/v8`). La variante `-alpine` pesa ~50 MB (vs ~150 MB de la `-builder`) y es suficiente: no necesitamos compilar plugins externos en este momento. Si más adelante se quisiera `caddy-dns/cloudflare` u otro plugin, se cambia a `caddy:2.8.4-builder` con `xcaddy` o se usa `lucaslorentz/caddy-docker-proxy` (no es el caso del homelab). |
| Tag de imagen | **Pinned a la release**, nunca `latest` | Misma regla de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1: tag fijo, upgrade manual decidido por el operador. Razón específica de Caddy: `Caddyfile` rompe entre minors (ver [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6, línea 450). |
| Política de Watchtower | **`watchtower.enable: "false"`** | Caddy es el ÚNICO punto por el que la LAN llega a casi todos los servicios. Un parser `Caddyfile` roto a las 04:00 = LAN entera sin HTTPS hasta que el operador despierte. Documentado en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6. |
| Modo de red | **Solo `homelab`** (bridge `external`) | Caddy es **la** puerta entre la LAN (vía `ports:`) y el resto de servicios (vía red interna `homelab`). No necesita macvlan: las IPs propias de la macvlan (Pi-hole, Unbound) ya viven a nivel L2 en la LAN; los servicios *normales* viven en `homelab` y se direccionan por nombre Docker. Añadirle más redes solo expandiría su superficie sin ganar nada. |
| `ports:` publicados al host | **`80:80/tcp`** y **`443:443/tcp`** (TCP), publicados a `0.0.0.0` | **Excepción consciente** a la regla "todo detrás de Caddy" (porque Caddy **es** ese "todo"). 80 se necesita para que clientes con HTTP→HTTPS automático lleguen sin manualmente teclear `https://`. 443 es la entrada real. **Sin** `udp/443` (HTTP/3): la LAN no se beneficia y Caddy abre QUIC por defecto si solo se publica TCP, así que se acota explícitamente al protocolo. |
| `ports:` para `:2019` (admin API) | **NO publicado al host** | El endpoint admin de Caddy es **muy potente** (escribe `Caddyfile`, recarga, descarga certs). Mantenerlo en `127.0.0.1:2019` dentro del contenedor (default de Caddy) es suficiente: se accede vía `docker exec caddy curl localhost:2019/...` cuando hace falta diagnóstico. |
| HTTPS para nombres `*.lan` | **`tls internal`** (CA interna de Caddy) | La LAN no resuelve a internet y Let's Encrypt no aplica. La CA interna de Caddy genera leaf certs válidos por 12 h, los renueva sola, y se distribuye **el certificado raíz** (`root.crt`) a los dispositivos del homelab. Equivalente a `mkcert` pero sin pasos manuales. |
| HTTPS para nombres `${TS_DOMAIN}` | **`tls /data/tailscale-certs/<host>.crt /data/tailscale-certs/<host>.key`** (cert provisto por `tailscale cert`) | Tailscale firma certs Let's Encrypt válidos para `*.<tailnet>.ts.net`. La generación se hace en [`05-tailscale.md`](./05-tailscale.md); este doc deja la **estructura** del bind mount (`./tailscale-certs/`), un snippet `tailscale_tls` reutilizable y un bloque comentado a la espera de tener el cert real. |
| Redirección HTTP → HTTPS | **Automática por Caddy** (cualquier `host { ... }` la activa por defecto) | No hace falta declararla. Caddy escucha en `:80`, ve un host conocido, responde `308 Permanent Redirect` a `https://...`. |
| HTTP/3 (QUIC) | **Deshabilitado** | El binding `:443` se hace solo TCP (`tcp/443`). HTTP/3 sobre UDP/443 requeriría reglas `ufw` adicionales y soporte completo del `MTU` en el switch del operador; no aporta a una LAN doméstica con latencias <1 ms. |
| Compresión | **`encode zstd gzip`** (vía snippet) | Estándar moderno (zstd) con fallback a gzip. Caddy maneja `Accept-Encoding` solo. |
| Cabeceras de seguridad por defecto | **HSTS + X-Frame-Options + X-Content-Type-Options + Referrer-Policy** vía snippet `security_headers` | Buen baseline para cualquier servicio web. Si un backend rompe (p. ej. iframes legítimos), se sobreescribe en su bloque. |
| Acceso a Pi-hole por Caddy | **Por la red `homelab`** (`reverse_proxy http://pihole:80`) | Pi-hole ya está en `homelab` por [`02-pihole.md`](./02-pihole.md) §4. Pasar por la macvlan exigiría añadir Caddy a `lan_macvlan`, lo cual contradice §5 de las decisiones. La macvlan se reserva para servicios que la LAN debe tocar **sin** intermediación de Caddy (DNS). |
| Persistencia | Bind mounts de `/data/` (CA interna, certs, OCSP) y `/config/` (autosave, no usado en modo Caddyfile) | El directorio `/data` contiene la CA interna del homelab (`pki/authorities/local/root.{crt,key}`). Perderla obliga a reinstalar el `root.crt` en TODOS los clientes. Backup obligatorio (§9). |
| Logs | **`logs/access.json` por host con rotación local** + defaults de daemon (`json-file 10 MB × 3` desde [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md)) | Caddy genera logs JSON estructurados muy útiles para Loki/Promtail futuros. Aquí se persisten en `/mnt/hd2t/services/proxy/logs/` con rotación de Caddy (`roll_size 10MiB`, `roll_keep 5`). |
| Usuario del contenedor | **`root` (default de la imagen oficial)** | La imagen oficial de Caddy arranca como root para bindar `:80`/`:443` y luego no dropa privilegios (proceso único `caddy run`). Sustituirlo por `${PUID}:${PGID}` exige `cap_add: NET_BIND_SERVICE` y rompe la regeneración inicial de `/data/caddy/pki/`. Excepción documentada respecto a la plantilla §6 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). |
| `cap_drop: ALL` + `cap_add` mínimo | `NET_BIND_SERVICE` | Único capability necesario: bindar puertos privilegiados. Sin `SETUID/SETGID/CHOWN` (no dropa usuario, no hace `chown`). |
| `security_opt` | **`no-new-privileges:true`** | Plantilla §6. Compatible con el `cap_add` enumerado. |
| `read_only` | **`false`** | Caddy escribe en `/data/`, `/config/` y `/var/log/caddy/`. Hacerlo `read_only` exigiría tres `tmpfs` y cuatro volúmenes; sin beneficio relevante para el modelo de amenaza (LAN + Tailscale). |
| Healthcheck | **`wget -qO- http://localhost:2019/config/ | grep -q '"http"'`** (admin API local del contenedor) | Verifica que el demonio responde **y** tiene configuración cargada. Más estricto que `curl http://localhost:80`: este último también responde si Caddy arrancó pero no parseó el `Caddyfile` (devuelve 200 vacío). |

---

## 1. Resumen de la arquitectura

```
                    ┌─────────────────────────────────────┐
                    │  LAN 192.168.1.0/24                 │
                    │                                     │
   navegador ──HTTPS─►  *.lan  ──Pi-hole DNS──► 192.168.1.10:443
                    │                                     │
                    │     iPhone, portátil, smart-TV...   │
                    └─────────────┬───────────────────────┘
                                  │
                          (tcp 80/443)
                                  │
                ┌─────────────────▼─────────────────┐
                │     Pi 5 (eth0 = 192.168.1.10)    │
                │                                   │
                │    docker network: homelab        │
                │    (172.20.0.0/24, br-homelab)    │
                │                                   │
                │   ┌───────── caddy ───────────┐   │
                │   │ image: caddy:2.8.4-alpine │   │
                │   │ ports:                    │   │
                │   │   - 80:80/tcp             │   │
                │   │   - 443:443/tcp           │   │
                │   │ networks:                 │   │
                │   │   - homelab               │   │
                │   │ tls internal (CA local)   │   │
                │   └────────┬──────────────────┘   │
                │            │ http://pihole        │
                │            │ http://portainer:9443│
                │            │ http://nextcloud:11000│
                │            │ ...                  │
                │            ▼                      │
                │     resto de stacks en homelab    │
                └───────────────────────────────────┘

   Tailscale (Fase 3.5):
   pi.tailnet.ts.net:443  ──MagicDNS──► 100.x.y.z (tailscale0 de la Pi)
                                          ──► caddy (tls con cert
                                                tailscale cert ...)
```

Tres invariantes:

- **Toda HTTPS pasa por Caddy.** Ningún servicio web del homelab publica `:443` directamente al host. Pi-hole sigue ofreciendo su `:443` con cert auto-firmado, pero solo en su IP macvlan (`192.168.1.241`), no en la del host.
- **Caddy solo está en `homelab`.** Para llegar a Pi-hole no atraviesa la macvlan; usa la red `homelab` donde Pi-hole **también** está conectado por su tercera red.
- **Sin Watchtower, sin `latest`.** Upgrade manual leyendo el `CHANGELOG.md` de Caddy.

---

## 2. Plan de variables y archivos

El stack `proxy` es nuevo. Layout que se va a crear:

```
~/homelab/stacks/proxy/                # versionable en git
├── docker-compose.yml
├── .env.example
├── Caddyfile
└── snippets/
    ├── lan_internal_tls
    ├── tailscale_tls
    └── security_headers
```

```
/mnt/hd2t/services/proxy/              # datos persistentes, NO en git
├── .env                                # secretos (chmod 600)
├── caddy/
│   ├── data/                           # CA interna, OCSP staples, leaf certs
│   └── config/                         # autosave del admin API (no usado)
├── logs/                               # access logs JSON con rotación
└── tailscale-certs/                    # bind mount vacío hasta 05-tailscale.md
```

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/proxy/.env.example`:

```dotenv
# ~/homelab/stacks/proxy/.env.example
# Versión control: ~/homelab/stacks/proxy/.env.example
# Valores reales en /mnt/hd2t/services/proxy/.env (chmod 600).

# --- Comunes del homelab ---
PUID=1000
PGID=1000
TZ=Europe/Madrid

# --- Dominios internos (consistentes con dns/.env) ---
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Caddy ---
# Versión de la imagen Docker. Buscar releases en https://hub.docker.com/_/caddy/tags
# ¡Leer https://github.com/caddyserver/caddy/blob/master/CHANGES.md antes de cambiar!
CADDY_IMAGE_TAG=2.8.4-alpine

# Email para los certificados internos (no se usa para Let's Encrypt en este homelab,
# pero Caddy lo registra en los CSR de la CA interna; útil si en el futuro se cambia).
CADDY_ADMIN_EMAIL=admin@homelab.local

# Hostname FQDN de la Pi en Tailscale (sin "https://"). Se rellena tras [`05-tailscale.md`](./05-tailscale.md).
# Ejemplo: pi.tailnet.ts.net
TS_HOSTNAME=
```

> No hay secretos auténticos en este stack. `CADDY_ADMIN_EMAIL` no es un secreto (si se quisiera registrar Caddy contra Let's Encrypt en el futuro, este sería el contacto). El `.env` se mantiene en `hd2t` igualmente para consistencia con el resto del homelab y porque mañana puede traer credenciales de plugins (Cloudflare DNS-01, p. ej.).

### 2.2. `.env` real (`/mnt/hd2t/services/proxy/.env`)

```bash
# Crear el .env con permisos correctos.
sudo install -m 600 -o homelab -g homelab /dev/null /mnt/hd2t/services/proxy/.env

# Rellenar (ajustar TZ y CADDY_IMAGE_TAG si procede).
cat > /mnt/hd2t/services/proxy/.env <<'EOF'
PUID=1000
PGID=1000
TZ=Europe/Madrid

LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

CADDY_IMAGE_TAG=2.8.4-alpine
CADDY_ADMIN_EMAIL=admin@homelab.local

# Vacío hasta desplegar Tailscale.
TS_HOSTNAME=
EOF

# Validar permisos.
ls -l /mnt/hd2t/services/proxy/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

### 2.3. Cómo se inyectan al contenedor

El `Caddyfile` referencia `{$LAN_DOMAIN}` y `{$TS_DOMAIN}` con la sintaxis de Caddy para variables de entorno. Compose las pasa al contenedor vía `env_file` y `environment:`. La sustitución la hace **Caddy** al cargar el `Caddyfile`, no Compose; esto permite cambiar el dominio (`lan` → `home`) sin tocar el YAML versionable.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
mkdir -p ~/homelab/stacks/proxy/snippets
```

### 3.2. Crear el árbol de datos persistentes

```bash
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/proxy
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/proxy/caddy
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/proxy/caddy/data
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/proxy/caddy/config
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/proxy/logs
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/proxy/tailscale-certs
```

> **Migración desde el esquema antiguo `/mnt/hd2t/services/caddy/`**: si el script de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §5 creó `/mnt/hd2t/services/caddy/` (esquema "un dir por servicio" antes de fijar la convención por stack):
> ```bash
> sudo rmdir /mnt/hd2t/services/caddy 2>/dev/null || true
> ```
> No debería haber datos previos: en un homelab nuevo, Caddy se despliega aquí por primera vez. Si se hubiese hecho un despliegue anterior, mover los contenidos:
> ```bash
> sudo mv /mnt/hd2t/services/caddy/data   /mnt/hd2t/services/proxy/caddy/data
> sudo mv /mnt/hd2t/services/caddy/config /mnt/hd2t/services/proxy/caddy/config
> sudo rmdir /mnt/hd2t/services/caddy
> ```

### 3.3. Permisos para el proceso del contenedor

Caddy oficial corre como `root` (UID 0). El bind mount entra como `homelab:homelab` (UID 1000) y, al primer arranque, Caddy escribirá en `/data` y `/config` como `root:root`. Para que `docker compose down` + lectura desde el host (`ls -l`, backups con Borg como `homelab`) funcione sin sudo, se aplica `chmod 770` para que el grupo `homelab` lea aunque los ficheros sean `root:root`:

```bash
sudo chmod 770 /mnt/hd2t/services/proxy/caddy/data
sudo chmod 770 /mnt/hd2t/services/proxy/caddy/config
sudo chmod 770 /mnt/hd2t/services/proxy/logs
sudo chmod 770 /mnt/hd2t/services/proxy/tailscale-certs
```

> Tras el primer arranque, los ficheros internos (`pki/authorities/local/root.crt`, `caddy/locks/...`) aparecerán con propietario `root:root` al hacer `ls` desde el host. Es esperable: el contenedor corre como root y no se ha solicitado `user:` en Compose. El backup con Borg (que se ejecutará como root o con `cap_dac_read_search`, ver [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) sí los lee sin problema.

---

## 4. `Caddyfile`

### 4.1. Estructura

El `Caddyfile` se divide en tres secciones:

1. **Bloque global** (`{ ... }`): opciones del proceso (admin API, email para certs internos, log por defecto, `auto_https disable_redirects` no — queremos las redirecciones).
2. **Snippets** (`(name) { ... }`): bloques reutilizables (`tls internal` para `*.lan`, headers de seguridad, compresión). Se importan con `import name` desde cada bloque de host.
3. **Bloques de host** (`hostname { ... }`): un bloque por servicio expuesto. Empieza con `caddy.lan` (página de bienvenida del propio Caddy) y `pihole.lan` (primer backend real). El resto se añadirá conforme se desplieguen los servicios.

### 4.2. Snippets reutilizables

`~/homelab/stacks/proxy/snippets/lan_internal_tls`:

```caddy
# snippets/lan_internal_tls
# TLS con la CA interna de Caddy. Usado por todos los hosts *.lan.
(lan_internal_tls) {
    tls internal
}
```

`~/homelab/stacks/proxy/snippets/tailscale_tls`:

```caddy
# snippets/tailscale_tls
# TLS con cert provisto por `tailscale cert`. El cert/key se generan en
# ../03-red/05-tailscale.md y se montan en /data/tailscale-certs/.
# Hasta entonces, importar este snippet falla; sus consumidores están
# comentados en el Caddyfile.
(tailscale_tls) {
    tls /data/tailscale-certs/{args[0]}.crt /data/tailscale-certs/{args[0]}.key
}
```

> **`{args[0]}` es la sintaxis de argumentos de snippet de Caddy v2.** Permite usar `import tailscale_tls pi` y que se expanda a las rutas `pi.crt` / `pi.key`. Documentado en https://caddyserver.com/docs/caddyfile/concepts#snippets.

`~/homelab/stacks/proxy/snippets/security_headers`:

```caddy
# snippets/security_headers
# Cabeceras de seguridad básicas para cualquier servicio web del homelab.
# Si un backend rompe (p. ej. requiere iframes externos), sobreescribir en su bloque.
(security_headers) {
    header {
        # HSTS — la LAN no necesita preload, el navegador recordará 1 año.
        Strict-Transport-Security "max-age=31536000"
        # Negar embedding del servicio en iframes externos.
        X-Frame-Options "SAMEORIGIN"
        # Negar MIME sniffing.
        X-Content-Type-Options "nosniff"
        # No filtrar Referer al hacer click hacia fuera.
        Referrer-Policy "strict-origin-when-cross-origin"
        # Eliminar Server: Caddy/2.x del response.
        -Server
    }
}
```

### 4.3. `Caddyfile` principal

`~/homelab/stacks/proxy/Caddyfile`:

```caddy
# ~/homelab/stacks/proxy/Caddyfile
# Reverse proxy del homelab. Versionado en git.
# Variables de entorno: LAN_DOMAIN, TS_DOMAIN, CADDY_ADMIN_EMAIL, TS_HOSTNAME.

# ----- Opciones globales -----
{
    # Admin API en localhost del contenedor (no se publica al host).
    admin localhost:2019

    # Email para Caddy (CA interna lo registra en sus CSR).
    email {$CADDY_ADMIN_EMAIL}

    # Logs JSON por defecto, todos los hosts heredan a /var/log/caddy/access.log.
    log default {
        output file /var/log/caddy/access.log {
            roll_size 10MiB
            roll_keep 5
            roll_keep_for 168h
        }
        format json
        level INFO
    }

    # Servidor: solo TCP en 80/443. HTTP/3 (QUIC) explícitamente deshabilitado.
    servers {
        protocols h1 h2
    }
}

# ----- Snippets reutilizables -----
import snippets/lan_internal_tls
import snippets/tailscale_tls
import snippets/security_headers

# ============================================================================
#  Bloques de host
# ============================================================================

# ----- Página de bienvenida del propio Caddy (smoke test) -----
caddy.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    respond <<HTML
        <!DOCTYPE html>
        <html lang="es">
        <head><meta charset="utf-8"><title>Caddy — Homelab</title></head>
        <body style="font-family:system-ui;margin:3em auto;max-width:40em">
            <h1>Caddy operativo</h1>
            <p>Reverse proxy del homelab. Si ves esta página con candado verde,
               la CA interna está confiada en tu navegador.</p>
            <p>Servicios bajo <code>*.{$LAN_DOMAIN}</code>:
               <a href="https://pihole.{$LAN_DOMAIN}/admin/">Pi-hole</a></p>
        </body></html>
        HTML 200
}

# ----- Pi-hole (../03-red/02-pihole.md) -----
pihole.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Pi-hole espera todas las URLs bajo /admin/. Redirigir / para no
    # mostrar el "block page" por defecto.
    redir / /admin/

    reverse_proxy http://pihole:80 {
        # Pi-hole comprueba el Host: header para decidir si el cliente es
        # interno; reenviarlo tal cual asegura que la UI no genere enlaces
        # con la IP del contenedor.
        header_up Host {host}
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
    }
}

# ============================================================================
#  Placeholders — se descomentan al desplegar cada servicio
# ============================================================================

# Portainer (../02-docker/03-portainer.md §5)
# portainer.{$LAN_DOMAIN} {
#     import lan_internal_tls
#     import security_headers
#     reverse_proxy https://portainer:9443 {
#         transport http {
#             tls
#             tls_insecure_skip_verify    # cert autogenerado de Portainer
#         }
#     }
# }

# Authelia (../04-seguridad/01-authelia.md)
# auth.{$LAN_DOMAIN} {
#     import lan_internal_tls
#     import security_headers
#     reverse_proxy http://authelia:9091
# }

# Jellyfin (../09-multimedia/01-jellyfin.md) — websockets para chromecast/apps
# jellyfin.{$LAN_DOMAIN} {
#     import lan_internal_tls
#     import security_headers
#     reverse_proxy http://jellyfin:8096
# }

# Nextcloud (../06-almacenamiento/01-nextcloud.md)
# nextcloud.{$LAN_DOMAIN} {
#     import lan_internal_tls
#     import security_headers
#     reverse_proxy http://nextcloud:11000
# }

# Vaultwarden (../11-productividad/01-vaultwarden.md)
# vault.{$LAN_DOMAIN} {
#     import lan_internal_tls
#     import security_headers
#     reverse_proxy http://vaultwarden:80
# }

# Homepage (../12-dashboards/01-homepage.md)
# home.{$LAN_DOMAIN} {
#     import lan_internal_tls
#     import security_headers
#     reverse_proxy http://homepage:3000
# }

# ============================================================================
#  Bloques Tailscale — se descomentan al completar 05-tailscale.md
# ============================================================================

# pi.{$TS_DOMAIN} {
#     import tailscale_tls pi
#     import security_headers
#     # Página de bienvenida igual que caddy.lan, o redir a Homepage.
#     respond "Hola desde Tailscale" 200
# }

# jellyfin.{$TS_DOMAIN} {
#     import tailscale_tls jellyfin
#     import security_headers
#     reverse_proxy http://jellyfin:8096
# }
```

### 4.4. Por qué cada directiva

| Directiva | Por qué |
|---|---|
| `admin localhost:2019` | Limita el endpoint admin a la interfaz loopback del contenedor. No se publica al host (sin `ports:` para 2019). El healthcheck (§5) lo usa por `localhost`. |
| `email {$CADDY_ADMIN_EMAIL}` | Caddy registra el email en los CSR de su CA interna. Si en el futuro se quiere ACME real (Let's Encrypt vía DNS-01), ya está rellenado. |
| `log default { output file ... }` | Todos los hosts heredan este logger (a menos que sobreescriban con `log` en su bloque). El fichero vive en `/var/log/caddy/access.log` con rotación interna de Caddy. |
| `roll_size 10MiB` / `roll_keep 5` / `roll_keep_for 168h` | 50 MB totales × 7 días. Suficiente para diagnóstico inmediato. Para análisis histórico se confía en Loki (Fase 5+). |
| `servers { protocols h1 h2 }` | Excluye `h3` (HTTP/3 / QUIC). Razón en §0, fila "HTTP/3". |
| `import snippets/lan_internal_tls` (al nivel raíz) | Hace los snippets visibles a los bloques de host. La sintaxis `import path` carga **literalmente** el contenido del fichero. |
| `import lan_internal_tls` (dentro de un host) | Aplica `tls internal` a ese host. Caddy generará un leaf cert firmado por la CA local. |
| `import security_headers` | Inyecta las cabeceras del snippet 4.2. |
| `redir / /admin/` (en `pihole`) | Pi-hole sirve "/" como página de bloqueo (el block page de cuando un dominio está en gravity). El homelab quiere que `https://pihole.lan` lleve al admin. Redirección 308 explícita. |
| `reverse_proxy http://pihole:80` | DNS interno de Docker. La red `homelab` resuelve `pihole` al `container_name: pihole` definido en [`02-pihole.md`](./02-pihole.md) §4. |
| `header_up Host {host}` | Reenvía el header `Host` original al backend. Pi-hole lo usa para detectar el dominio del cliente y construir links absolutos consistentes. |
| `header_up X-Forwarded-Proto https` | Le dice al backend que la conexión original era HTTPS (Caddy ya terminó TLS). Crítico para apps que generan URLs de redirect. |
| `header_up X-Real-IP {remote_host}` | IP real del cliente (no la IP de Caddy). Útil para logs del backend. |
| Bloques Tailscale comentados | El cert no existe aún; Caddy abortaría el `up` si el bloque fuese activo. Comentar evita el `up` fallido y deja la receta lista. |
| Placeholders comentados con doc-link | Cada placeholder cita el documento del servicio que lo activará, así el operador sabe qué doc leer cuando llegue. |

### 4.5. Decisión sobre `auto_https`

Caddy v2 activa por defecto:

- Redirección automática `:80 → :443` para cualquier hostname con TLS.
- Generación automática de certs internos cuando se ve `tls internal` o cuando el hostname es local.

**No** se desactiva con `auto_https off`: la redirección 308 es deseable y el coste de la generación es nulo (Caddy genera leaf certs en milisegundos).

> Excepción: si en el futuro se añade un host **HTTP-only** (p. ej. ACME challenge externo), se usa el bloque `http://name.lan { ... }` explícito, que no fuerza HTTPS para ese host concreto.

---

## 5. `docker-compose.yml`

`~/homelab/stacks/proxy/docker-compose.yml`:

```yaml
# ~/homelab/stacks/proxy/docker-compose.yml
# Stack: proxy (../02-docker/02-estructura-compose.md §1.1).
# Datos en /mnt/hd2t/services/proxy/. Secretos en /mnt/hd2t/services/proxy/.env.

name: proxy

services:
  caddy:
    image: caddy:${CADDY_IMAGE_TAG}
    container_name: caddy
    hostname: caddy
    restart: unless-stopped

    env_file:
      - /mnt/hd2t/services/proxy/.env
    environment:
      TZ: ${TZ}
      LAN_DOMAIN: ${LAN_DOMAIN}
      TS_DOMAIN: ${TS_DOMAIN}
      CADDY_ADMIN_EMAIL: ${CADDY_ADMIN_EMAIL}

    ports:
      # Excepción consciente: Caddy es el único servicio "homelab" que se publica
      # a 0.0.0.0. Pi-hole publica en su IP macvlan, no en la del host.
      - "80:80/tcp"
      - "443:443/tcp"

    volumes:
      # Caddyfile principal — read-only.
      - type: bind
        source: ./Caddyfile
        target: /etc/caddy/Caddyfile
        read_only: true
        bind:
          create_host_path: false

      # Snippets reutilizables.
      - type: bind
        source: ./snippets
        target: /etc/caddy/snippets
        read_only: true
        bind:
          create_host_path: false

      # CA interna, certs y OCSP staples — escritura.
      - type: bind
        source: /mnt/hd2t/services/proxy/caddy/data
        target: /data
        bind:
          create_host_path: false

      # Autosave de la admin API — escritura. No usado en modo Caddyfile,
      # pero el binario falla si el directorio no es writable.
      - type: bind
        source: /mnt/hd2t/services/proxy/caddy/config
        target: /config
        bind:
          create_host_path: false

      # Access logs JSON con rotación interna de Caddy.
      - type: bind
        source: /mnt/hd2t/services/proxy/logs
        target: /var/log/caddy
        bind:
          create_host_path: false

      # Certs de Tailscale (vacío hasta 05-tailscale.md). Read-only: Caddy
      # los lee, Tailscale los escribe desde fuera del contenedor.
      - type: bind
        source: /mnt/hd2t/services/proxy/tailscale-certs
        target: /data/tailscale-certs
        read_only: true
        bind:
          create_host_path: false

    networks:
      - homelab

    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE

    security_opt:
      - no-new-privileges:true

    healthcheck:
      test:
        - CMD-SHELL
        - "wget -qO- http://localhost:2019/config/ | grep -q '\"http\"' || exit 1"
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s

    labels:
      com.centurylinklabs.watchtower.enable: "false"
      homepage.group: "Red"
      homepage.name: "Caddy"
      homepage.icon: "caddy.png"
      homepage.href: "https://caddy.${LAN_DOMAIN}"
      homepage.description: "Reverse proxy + HTTPS interno"

networks:
  homelab:
    external: true
```

### 5.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `name: proxy` | Coincide con el directorio del stack y con la fila §1.1 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). |
| `image: caddy:${CADDY_IMAGE_TAG}` | Tag del `.env`, sustituible sin tocar el YAML. Multi-arch oficial. |
| `container_name: caddy` / `hostname: caddy` | Permite que otros stacks (Authelia, Homepage) referencien `caddy` por nombre cuando lo necesiten (p. ej. `caddy:80` para healthchecks). |
| `restart: unless-stopped` | Plantilla §6 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). |
| `env_file` ruta absoluta + `environment:` explícito | Plantilla §5.1: ruta absoluta para no depender del CWD. `environment:` re-declara las variables que se quieren ver claramente en `docker compose config`. |
| `ports: 80/tcp, 443/tcp` | Excepción documentada en §0. **Sin** `udp/443` (HTTP/3 deshabilitado). |
| `volumes` (5 bind mounts) | Caddyfile + snippets read-only desde el repo (cualquier `up` con drift en disco se detecta); `data/` y `config/` writable; `logs/` writable; `tailscale-certs/` read-only (lo escribe Tailscale, lo lee Caddy). |
| `bind.create_host_path: false` (en todos) | Si la ruta no existe, Compose **falla** en `up` en lugar de crear silenciosamente directorios `root:root`. Detecta typos antes de tiempo. |
| `read_only: true` en `Caddyfile` y `snippets/` | Caddy abre el `Caddyfile` solo para leer; protege contra cambios accidentales en runtime. |
| `networks: [homelab]` | Sola red. Razón en §0. |
| `cap_drop: ALL` + `cap_add: NET_BIND_SERVICE` | Único capability necesario: bindar `:80` y `:443` (puertos privilegiados). El proceso corre como root pero **solo** retiene esa capability. |
| `security_opt: no-new-privileges:true` | Plantilla §6. |
| `healthcheck: wget admin API` | Verifica que el daemon arranca **y** parseó el `Caddyfile`. Sin parseo, el endpoint `/config/` devuelve `null`, el `grep` falla y el healthcheck marca `unhealthy`. |
| `start_period: 15s` | Caddy arranca en <2 s en ARM64. 15 s es holgura para que el primer `wget` no chasquee con un daemon a medio cargar. |
| `labels: watchtower.enable=false` | Excluido. Razonado en §0 y en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md). |
| `labels: homepage.*` | Pre-rellenados para [`../12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md). |
| `networks: { homelab: { external: true } }` | La red se creó una vez en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2. |

### 5.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/proxy
docker compose --env-file /mnt/hd2t/services/proxy/.env config >/dev/null \
  && echo "Compose OK"

# Validar el Caddyfile con la imagen oficial sin desplegar:
docker run --rm \
  -v $(pwd)/Caddyfile:/etc/caddy/Caddyfile:ro \
  -v $(pwd)/snippets:/etc/caddy/snippets:ro \
  -e LAN_DOMAIN=lan -e TS_DOMAIN=tailnet.ts.net -e CADDY_ADMIN_EMAIL=admin@homelab.local \
  caddy:${CADDY_IMAGE_TAG:-2.8.4-alpine} \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
# Esperado: "Valid configuration"
```

> Si imprime `Error: ... unknown directive 'tailscale_tls'`, asegurarse de haber **comentado** los bloques Tailscale (§4.3 al final). Esos bloques se descomentan tras [`05-tailscale.md`](./05-tailscale.md).

---

## 6. Despliegue

### 6.1. Levantar Caddy

```bash
cd ~/homelab/stacks/proxy
docker compose --env-file /mnt/hd2t/services/proxy/.env up -d
```

Salida esperada:

```
[+] Running 1/1
 ✔ Container caddy  Started
```

### 6.2. Estado del contenedor

```bash
docker compose ps
# Esperado:
# NAME    IMAGE                 STATUS                  PORTS
# caddy   caddy:2.8.4-alpine    Up 30 seconds (healthy) 0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp
```

Si tarda más de 60 s en `(healthy)`, mirar logs:

```bash
docker compose logs caddy | tail -50
```

Eventos esperados en los logs (formato JSON):

```json
{"level":"info","ts":...,"msg":"using provided configuration"}
{"level":"info","ts":...,"msg":"adapted config to JSON","adapter":"caddyfile"}
{"level":"info","ts":...,"msg":"serving initial configuration"}
{"level":"info","ts":...,"msg":"server running","name":"srv0","protocols":["h1","h2"]}
{"level":"info","ts":...,"logger":"tls.cache.maintenance","msg":"started background certificate maintenance"}
```

### 6.3. Smoke test desde el host

```bash
# HTTP debe redirigir a HTTPS:
curl -I http://caddy.lan
# Esperado: HTTP/1.1 308 Permanent Redirect, Location: https://caddy.lan/

# HTTPS — primer hit, ignorando el cert hasta §6.5:
curl -kI https://caddy.lan
# Esperado: HTTP/2 200, server: omitido (header -Server del snippet).

# El admin API solo escucha en localhost del contenedor:
curl -fsS http://localhost:2019/config/ 2>&1 | head -1
# Esperado: error (puerto cerrado en la Pi).
docker exec caddy wget -qO- http://localhost:2019/config/ | head -c 80
# Esperado: {"admin":{"listen":"localhost:2019"}, ...
```

### 6.4. Abrir el firewall del host

`ufw` ya tiene política `allow outgoing` y `deny incoming` ([`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §4.4). Añadir las dos reglas de Caddy, restringidas a la subred LAN:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 80  proto tcp comment 'HTTP redir Caddy'
sudo ufw allow from 192.168.1.0/24 to any port 443 proto tcp comment 'HTTPS Caddy'
sudo ufw status numbered | grep -E '(80|443)/tcp'
```

> **Tailscale**: no hace falta abrir nada en `ufw`. La interfaz `tailscale0` que crea Tailscale ([`05-tailscale.md`](./05-tailscale.md)) es ajena a `ufw` por defecto en Bookworm; el tráfico de la VPN llega a Caddy directamente sin atravesar las reglas del firewall del host.

> **Nota**: `ufw` no aplica al tráfico macvlan ([`01-macvlan.md`](./01-macvlan.md) §6), así que estas reglas solo controlan el acceso a la **IP del host**, donde escucha Caddy.

### 6.5. Confiar en la CA interna desde los clientes

Caddy generó la CA al primer arranque en `/data/caddy/pki/authorities/local/root.crt` dentro del contenedor (= `/mnt/hd2t/services/proxy/caddy/data/caddy/pki/authorities/local/root.crt` en el host). Para que los clientes vean candado verde:

```bash
# Sacar el root.crt del contenedor:
docker exec caddy cat /data/caddy/pki/authorities/local/root.crt > /tmp/caddy-homelab-root.crt

# Verificar que es un cert válido:
openssl x509 -in /tmp/caddy-homelab-root.crt -noout -subject -issuer -dates
# Esperado:
#   subject= CN = Caddy Local Authority - <id>
#   issuer=  CN = Caddy Local Authority - <id>  (autofirmado)
```

Distribución (un dispositivo cada uno):

| Cliente | Cómo confiar |
|---|---|
| **Linux (Pi misma, otros Debian)** | `sudo cp /tmp/caddy-homelab-root.crt /usr/local/share/ca-certificates/caddy-homelab.crt && sudo update-ca-certificates` |
| **macOS** | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain caddy-homelab-root.crt` (o vía Keychain Access → drag & drop). |
| **Windows** | `certmgr.msc` → *Trusted Root Certification Authorities* → Importar. O por GPO si hay AD. |
| **iOS** | Email/AirDrop el `.crt` al iPhone → Settings → Profile Downloaded → Install. Después: Settings → General → About → Certificate Trust Settings → activar el cert. |
| **Android** | Settings → Security → Encryption & credentials → Install a certificate → CA certificate. |
| **Firefox** | Tiene su propio almacén: about:preferences#privacy → View Certificates → Authorities → Import. Activar "Trust this CA to identify websites". |

> Tras instalar el `root.crt`, abrir `https://caddy.lan` debe mostrar **candado verde sin advertencia**. El cert hoja del navegador será `caddy.lan` firmado por `Caddy Local Authority - <id>`.

### 6.6. Smoke test desde otro equipo de la LAN

```bash
# Desde un portátil con el root.crt instalado:
curl -fsS https://caddy.lan | head -5
# Esperado: <!DOCTYPE html> ... <h1>Caddy operativo</h1>

curl -fsS https://pihole.lan/admin/ -o /dev/null -w '%{http_code}\n'
# Esperado: 200
```

Si **no** se ha instalado el `root.crt`, `curl` falla con:

```
curl: (60) SSL certificate problem: unable to get local issuer certificate
```

Es **el comportamiento esperado**: la CA interna NO está confiada por nadie hasta que se instale.

---

## 7. Integración con Tailscale (preparado, no funcional)

Tailscale se despliega en [`05-tailscale.md`](./05-tailscale.md). Cuando esté en marcha, el flujo será:

1. Tailscale provee `tailscale cert <hostname>.${TS_DOMAIN}` que descarga un cert Let's Encrypt válido.
2. El cert/key se copian a `/mnt/hd2t/services/proxy/tailscale-certs/<hostname>.{crt,key}` (script en [`05-tailscale.md`](./05-tailscale.md)).
3. Se rellena `TS_HOSTNAME` en `/mnt/hd2t/services/proxy/.env` con el FQDN obtenido (`pi.tailnet.ts.net`).
4. Se descomentan los bloques `pi.{$TS_DOMAIN}`, `jellyfin.{$TS_DOMAIN}`... del `Caddyfile`.
5. Se recarga Caddy:
   ```bash
   docker exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```

Por qué no se hace todo en este doc:

- **Dependencia de orden**: el cert solo existe si Tailscale ya está autenticado en el tailnet. Forzarlo aquí cruzaría documentos.
- **`tailscale cert` requiere acceso al socket** `/var/run/tailscale/tailscaled.sock`, que es propiedad de Tailscale. El doc 05 documenta la manera segura de exponerlo.
- **Renovación**: los certs de Tailscale duran ~90 días y se renuevan vía un cron. Ese cron pertenece al doc 05.

> El bind mount `/mnt/hd2t/services/proxy/tailscale-certs/` ya existe (§3.2), está vacío, y Caddy no lo lee porque ningún bloque del `Caddyfile` activo lo referencia. Es un placeholder limpio.

---

## 8. Verificación

### 8.1. Contenedor sano

```bash
docker compose -f ~/homelab/stacks/proxy/docker-compose.yml ps caddy
# STATUS debe ser "Up X minutes (healthy)".
docker inspect caddy --format '{{.State.Health.Status}}'
# Esperado: healthy
```

### 8.2. Caddy escucha en 80 y 443 del host

```bash
sudo ss -ltn | awk '$4 ~ /:(80|443)$/'
# Esperado: dos líneas, ambas LISTEN, ambas con :::80 y :::443 (Docker proxy).
```

### 8.3. Redirección HTTP → HTTPS

```bash
curl -sIo /dev/null -w '%{http_code} %{redirect_url}\n' http://caddy.lan
# Esperado: 308 https://caddy.lan/
```

### 8.4. Cert hoja firmado por la CA interna

```bash
echo | openssl s_client -connect caddy.lan:443 -servername caddy.lan 2>/dev/null \
  | openssl x509 -noout -issuer -subject
# Esperado:
#   issuer=  CN = Caddy Local Authority - 2024 ECC Intermediate
#   subject= CN = caddy.lan
```

### 8.5. Pi-hole accesible vía Caddy

```bash
# Desde la Pi, sin -k (con root.crt instalado en el sistema, §6.5):
curl -fsS https://pihole.lan/admin/ -o /dev/null -w 'http=%{http_code} cert_subject=%{ssl_subject}\n'
# Esperado: http=200 cert_subject=CN = pihole.lan

# Las cabeceras forwarded llegan a Pi-hole:
curl -fsS https://pihole.lan/admin/ -I | grep -E 'HTTP|server|x-frame'
# Esperado: HTTP/2 200; X-Frame-Options: SAMEORIGIN; Server: omitido.
```

### 8.6. Logs de acceso JSON

```bash
sudo tail -1 /mnt/hd2t/services/proxy/logs/access.log | python3 -m json.tool
# Esperado: objeto JSON con campos request, response, duration, etc.
```

### 8.7. Admin API NO está expuesta al host

```bash
curl -sf http://192.168.1.10:2019/config/ -m 2 ; echo "exit=$?"
# Esperado: exit=7 (connection refused) o exit=28 (timeout). Nunca 200.

docker exec caddy wget -qO- http://localhost:2019/config/ | head -c 50
# Esperado: '{"admin":{"listen":"localhost:2019"} ...'
```

### 8.8. Snippets se aplican (cabeceras de seguridad)

```bash
curl -sI https://caddy.lan | grep -iE 'strict-transport|x-frame|x-content|referrer'
# Esperado: 4 líneas con los valores del snippet security_headers.
```

### 8.9. Firewall del host permite 80/443 desde la LAN

```bash
sudo ufw status verbose | grep -E '(80|443)/tcp'
# Esperado: dos reglas ALLOW IN desde 192.168.1.0/24 con comentario.

# Desde otra máquina de la LAN:
nc -zv 192.168.1.10 443
# Esperado: succeeded.
```

### 8.10. Persistencia tras reboot

```bash
sudo reboot
# (esperar a que vuelva)

docker compose -f ~/homelab/stacks/proxy/docker-compose.yml ps caddy
# Esperado: Up (healthy).

# La CA interna debe sobrevivir al reboot:
sudo ls -la /mnt/hd2t/services/proxy/caddy/data/caddy/pki/authorities/local/
# Esperado: root.crt y root.key con la fecha del primer despliegue.

# Nuevo curl a https://caddy.lan: el cert hoja debe seguir firmado por
# la MISMA CA (mismo serial); no se ha regenerado el root tras el reboot.
echo | openssl s_client -connect caddy.lan:443 -servername caddy.lan 2>/dev/null \
  | openssl x509 -noout -issuer
```

### 8.11. Lista de Verificación

Antes de pasar a [`05-tailscale.md`](./05-tailscale.md):

- [ ] `docker compose -f ~/homelab/stacks/proxy/docker-compose.yml ps caddy` → `(healthy)`.
- [ ] `sudo ss -ltn | grep -E ':(80|443)\b'` → ambas líneas LISTEN.
- [ ] `curl -sI http://caddy.lan` → `308 Permanent Redirect`.
- [ ] `curl -fsS https://caddy.lan` (con root.crt instalado) → 200 + HTML del smoke test.
- [ ] `curl -fsS https://pihole.lan/admin/` → 200 (Pi-hole UI).
- [ ] El cert hoja de `caddy.lan` está firmado por `Caddy Local Authority` (no por una CA pública).
- [ ] `curl http://192.168.1.10:2019/config/` → conexión rechazada (admin solo en loopback del contenedor).
- [ ] `sudo ufw status` muestra reglas `ALLOW IN 192.168.1.0/24` para `80/tcp` y `443/tcp`.
- [ ] `~/homelab/stacks/proxy/{Caddyfile,snippets/*,docker-compose.yml,.env.example}` versionados en git; **`.env` no**.
- [ ] `/mnt/hd2t/services/proxy/caddy/data/caddy/pki/authorities/local/root.crt` existe y es legible por `homelab` (vía `chmod 770` + grupo).
- [ ] El `root.crt` está instalado en al menos el navegador del operador (smoke test en §6.5).
- [ ] Tras `sudo reboot`, Caddy vuelve `(healthy)` y el cert hoja sigue firmado por la **misma** CA local (sin regeneración).

---

## 9. Backup

Estrategia que se concretará en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md). Lo que **debe respaldarse** de Caddy:

| Ruta | Qué contiene | Frecuencia |
|---|---|---|
| `~/homelab/stacks/proxy/Caddyfile` | Configuración íntegra del proxy. | Versionado en git → `git push`. |
| `~/homelab/stacks/proxy/snippets/*` | Snippets reutilizables. | Idem. |
| `~/homelab/stacks/proxy/docker-compose.yml` | Definición del stack. | Idem. |
| `~/homelab/stacks/proxy/.env.example` | Plantilla de variables. | Idem. |
| `/mnt/hd2t/services/proxy/caddy/data/caddy/pki/authorities/local/root.{crt,key}` | **CA interna del homelab**. **Crítico**: si se pierde, hay que regenerar TODOS los certs y reinstalar el `root.crt` en TODOS los clientes. | **Semanal**, dentro del backup de Borg. |
| `/mnt/hd2t/services/proxy/caddy/data/caddy/certificates/` | Leaf certs en caché. **Reconstruibles**: Caddy los regenera al primer hit tras restaurar la CA. | Opcional. |
| `/mnt/hd2t/services/proxy/logs/access.log*` | Logs de acceso. **Reemplazables**. | No backup; si se quieren históricos, ir a Loki (Fase 5+). |
| `/mnt/hd2t/services/proxy/tailscale-certs/*.{crt,key}` | Certs Let's Encrypt provistos por Tailscale. **Reconstruibles** con `tailscale cert <host>` en cualquier momento. | Opcional. |

Pre-backup hook (Borgmatic), opcional:

```yaml
# Pseudo-config; la real va en 07-backups/02-borgmatic.md.
before_backup:
  - docker exec caddy caddy adapt --config /etc/caddy/Caddyfile --pretty > /mnt/hd2t/backups/dumps/caddy/caddyfile.json
```

> `caddy adapt` produce el JSON equivalente al `Caddyfile` que Caddy realmente está sirviendo. Útil para auditoría tras un upgrade y para detectar drift entre git y runtime.

> **Lo crucial es la CA interna.** Pérdida del `Caddyfile` → 5 min de reescritura desde memoria/git. Pérdida de `pki/authorities/local/root.{crt,key}` → 30 min de reinstalación en cada cliente del homelab. Por eso Borg respalda explícitamente ese subdirectorio.

---

## 10. Operaciones cotidianas

### 10.1. Recargar el `Caddyfile` sin downtime

Tras editar `~/homelab/stacks/proxy/Caddyfile` o un snippet:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
# Espera <1 s; si hay error de sintaxis, lo imprime y NO aplica el cambio.
```

> `caddy reload` aplica cambios **sin perder conexiones activas** ni la CA interna en memoria. Es la operación rutinaria al añadir un nuevo backend. `docker compose restart caddy` también funciona pero corta brevemente las conexiones.

### 10.2. Validar un `Caddyfile` antes de aplicar

```bash
# Validar sintaxis sin aplicar:
docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

# O desde el host con la imagen efímera (útil si Caddy está caído):
cd ~/homelab/stacks/proxy
docker run --rm \
  -v $(pwd)/Caddyfile:/etc/caddy/Caddyfile:ro \
  -v $(pwd)/snippets:/etc/caddy/snippets:ro \
  -e LAN_DOMAIN=lan -e TS_DOMAIN=tailnet.ts.net -e CADDY_ADMIN_EMAIL=admin@homelab.local \
  caddy:2.8.4-alpine \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

### 10.3. Ver el estado interno del proxy

```bash
# Configuración actual (JSON):
docker exec caddy curl -s http://localhost:2019/config/ | head -c 400

# Certificados gestionados:
docker exec caddy ls -la /data/caddy/certificates/
```

### 10.4. Ver logs en vivo

```bash
# Logs del proceso (stdout/stderr del contenedor):
docker compose -f ~/homelab/stacks/proxy/docker-compose.yml logs -f caddy

# Access logs JSON (formato estructurado):
sudo tail -F /mnt/hd2t/services/proxy/logs/access.log | python3 -c '
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        print(f"{e.get(\"request\",{}).get(\"host\",\"?\")} {e.get(\"request\",{}).get(\"method\",\"?\")} {e.get(\"request\",{}).get(\"uri\",\"?\")} -> {e.get(\"status\",\"?\")} ({e.get(\"duration\",0)*1000:.0f}ms)")
    except Exception:
        print(line.rstrip())
'
```

### 10.5. Añadir un nuevo backend

1. El servicio destino debe estar conectado a la red `homelab`.
2. Añadir un bloque al `Caddyfile`:
   ```caddy
   miservicio.{$LAN_DOMAIN} {
       import lan_internal_tls
       import security_headers
       reverse_proxy http://miservicio:PUERTO
   }
   ```
3. Asegurarse de que Pi-hole tiene el registro `miservicio.lan → 192.168.1.10` (UI Pi-hole → Local DNS → DNS Records, [`02-pihole.md`](./02-pihole.md) §6.4).
4. `docker exec caddy caddy reload --config /etc/caddy/Caddyfile`.
5. Verificar: `curl -fsS https://miservicio.lan -o /dev/null -w '%{http_code}\n'`.

### 10.6. Upgrade manual

```bash
# Editar CADDY_IMAGE_TAG en /mnt/hd2t/services/proxy/.env:
sudo -u homelab sed -i 's|^CADDY_IMAGE_TAG=.*|CADDY_IMAGE_TAG=2.9.0-alpine|' \
  /mnt/hd2t/services/proxy/.env

# LEER el changelog antes de aplicar:
# https://github.com/caddyserver/caddy/blob/master/CHANGES.md

cd ~/homelab/stacks/proxy
docker compose --env-file /mnt/hd2t/services/proxy/.env pull caddy
docker compose --env-file /mnt/hd2t/services/proxy/.env up -d --force-recreate caddy

# Verificar:
docker exec caddy caddy version
```

> Watchtower **no** hace este upgrade automáticamente (`watchtower.enable: "false"`). Es decisión consciente del operador, justificada por la posible ruptura del `Caddyfile`.

### 10.7. Regenerar la CA interna (último recurso)

Si la `root.crt` se compromete o se quiere rotarla intencionadamente:

```bash
# 1. Parar Caddy:
docker compose -f ~/homelab/stacks/proxy/docker-compose.yml stop caddy

# 2. Borrar la CA actual:
sudo rm -rf /mnt/hd2t/services/proxy/caddy/data/caddy/pki/authorities/local/

# 3. Levantar de nuevo: Caddy genera una CA nueva al arrancar.
docker compose -f ~/homelab/stacks/proxy/docker-compose.yml up -d caddy

# 4. Sacar la nueva root.crt y reinstalarla en TODOS los clientes (§6.5).
```

> **Coste**: cada dispositivo del homelab tiene que volver a confiar en la nueva CA. En un homelab con 5–10 clientes, son 30–60 min de trabajo manual. Por eso esta operación es "último recurso".

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `docker compose up caddy` falla con `network homelab declared as external, but could not be found` | La red `homelab` no está creada. | Crearla según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2. |
| `docker compose up caddy` falla con `bind: address already in use 0.0.0.0:80` o `:443` | Otro servicio del host (Apache, nginx, plex) ya escucha en 80/443. | `sudo ss -ltnp | awk '$4 ~ /:(80|443)$/'` para identificar; pararlo o reasignar. |
| Contenedor arranca pero `(unhealthy)`; `docker logs caddy` muestra `parse error: unrecognized directive: tailscale_tls` | Bloques Tailscale del `Caddyfile` están **descomentados** sin haber completado [`05-tailscale.md`](./05-tailscale.md). | Comentar los bloques `*.{$TS_DOMAIN}` hasta tener los certs en `/mnt/hd2t/services/proxy/tailscale-certs/`. |
| `curl https://caddy.lan` desde el host falla con `unable to get local issuer certificate` | El `root.crt` no está en el almacén de CAs del sistema. | Repetir §6.5: `sudo update-ca-certificates` tras copiar a `/usr/local/share/ca-certificates/`. |
| `curl https://caddy.lan` desde la LAN falla con `Could not resolve host` | Pi-hole no tiene el registro DNS para `caddy.lan`. | UI de Pi-hole → Local DNS → DNS Records → `caddy.lan` → `192.168.1.10`. Reload Pi-hole DNS: `docker exec pihole pihole reloaddns`. |
| `curl https://caddy.lan` resuelve pero responde con cert auto-firmado de **Pi-hole** (CN=`pi.hole`), no de Caddy | Pi-hole DNS resolvió `caddy.lan → 192.168.1.241` por error (en lugar de `192.168.1.10`). | Corregir el registro local en Pi-hole. Verificar con `dig +short @192.168.1.241 caddy.lan`. |
| `https://pihole.lan` responde 502/504 | Caddy no llega a `pihole:80` por la red `homelab`. | `docker exec caddy wget -qO- http://pihole/admin/`. Si falla, comprobar que Pi-hole está conectado a `homelab`: `docker inspect pihole --format '{{json .NetworkSettings.Networks}}'`. |
| `https://pihole.lan` responde 200 pero con HTML mal formado o redirecciones rotas | Pi-hole no recibe correctamente `Host:` o `X-Forwarded-Proto`. | Verificar el bloque `pihole.lan` del `Caddyfile`: debe tener `header_up Host {host}` y `header_up X-Forwarded-Proto https`. |
| Tras un `caddy reload`, las cabeceras antiguas siguen apareciendo | El navegador cacheó la respuesta. | `Ctrl+Shift+R` (force reload). Curl no cachea, así que `curl -sI` muestra el estado real. |
| Caddy genera un cert nuevo en cada arranque (subject CN diferente) | El bind mount de `/data` no es persistente. | Verificar `docker inspect caddy --format '{{range .Mounts}}{{.Source}} → {{.Destination}}{{println}}{{end}}'`. La línea `/mnt/hd2t/services/proxy/caddy/data → /data` debe existir y `bind.create_host_path: false` debe estar respetado. |
| `caddy reload` falla con `loading config: invalid config` tras editar | Sintaxis incorrecta en el `Caddyfile`. | `docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile` para ver el error con línea/columna. |
| El admin API responde `405 Method Not Allowed` desde `wget` o `curl` | La API solo responde a métodos válidos para cada ruta. `GET /config/` siempre funciona; `POST` requiere body. | Usar `GET /config/` para healthchecks/diagnóstico. |
| `ufw` muestra el tráfico a 443 como `BLOCKED` aunque la regla existe | Otra regla más arriba en la cadena bloquea (p. ej. `deny IN` global antes que el `allow`). | `sudo ufw status numbered` y revisar el orden. Mover la `allow` arriba con `sudo ufw insert 1 ...`. |
| Tras un upgrade de Caddy (`2.x → 2.y`), el contenedor no arranca | El `Caddyfile` usa una directiva removida o renombrada. | Leer el [CHANGES.md](https://github.com/caddyserver/caddy/blob/master/CHANGES.md). Rollback temporal cambiando `CADDY_IMAGE_TAG` a la versión previa, fix `Caddyfile`, re-upgrade. |
| Cliente de la LAN ve `NET::ERR_CERT_AUTHORITY_INVALID` aunque el `root.crt` está instalado | El cliente cachea la cadena anterior, o el cert fue regenerado y la CA es nueva. | Limpiar caché HSTS del navegador (Chrome: `chrome://net-internals/#hsts`); reinstalar el `root.crt` actual desde §6.5. |
| `https://caddy.lan` da `ERR_TOO_MANY_REDIRECTS` | El backend responde con 30x a un esquema o host distinto, generando bucle. En este doc no aplica al host `caddy.lan` (`respond` directo); sí puede ocurrir al añadir backends. | Ver `tail -f /var/log/caddy/access.log`; ajustar `header_up X-Forwarded-Proto` o configurar el backend para no redirigir si recibe `https`. |

---

## Referencias

- [Caddy — Documentación oficial](https://caddyserver.com/docs/)
- [Caddy — `Caddyfile` concepts](https://caddyserver.com/docs/caddyfile/concepts)
- [Caddy — Directives reference](https://caddyserver.com/docs/caddyfile/directives)
- [Caddy — `tls` directive (incluido `tls internal`)](https://caddyserver.com/docs/caddyfile/directives/tls)
- [Caddy — Automatic HTTPS](https://caddyserver.com/docs/automatic-https)
- [Caddy — Local HTTPS / CA interna](https://caddyserver.com/docs/automatic-https#local-https)
- [Caddy — Admin API](https://caddyserver.com/docs/api)
- [Caddy — Imagen Docker oficial](https://hub.docker.com/_/caddy)
- [Caddy — Source code y CHANGES.md (GitHub)](https://github.com/caddyserver/caddy)
- [Caddy — `reverse_proxy` directive](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [Caddy — `import` y snippets](https://caddyserver.com/docs/caddyfile/concepts#snippets)
- [Pi-hole — Reverse proxy con Caddy](https://docs.pi-hole.net/guides/dns/reverse-proxy/)
- [Tailscale — `tailscale cert` (HTTPS para máquinas del tailnet)](https://tailscale.com/kb/1153/enabling-https/)
- [DigitalOcean — How to host a website with Caddy 2 and a self-signed CA](https://www.digitalocean.com/community/tutorials/how-to-host-a-website-with-caddy-on-ubuntu-22-04)
- [RFC 6797 — HTTP Strict Transport Security (HSTS)](https://datatracker.ietf.org/doc/html/rfc6797)
