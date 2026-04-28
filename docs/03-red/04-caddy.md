# Caddy

## Descripción

Cerrado `03-unbound.md`, la Pi tiene **DNS limpio**: Pi-hole en `192.168.1.2` resuelve para toda la LAN (con bloqueo de listas) y delega a Unbound recursivo en `192.168.1.3`. Pi-hole también provee el espacio de nombres `*.${DOMAIN_LAN}` con un comodín (`address=/lan/192.168.1.10`), de modo que `jellyfin.lan`, `nextcloud.lan`, etc. ya **resuelven** — pero apuntan a una IP, la de la Pi (`192.168.1.10`), donde **todavía no escucha nadie en `:80`/`:443`**. Eso es precisamente lo que abre este documento.

Este documento despliega **Caddy** como **reverse proxy interno** del homelab, con dos misiones:

1. **HTTPS para acceso LAN (`*.${DOMAIN_LAN}`)** mediante una **CA interna** que Caddy genera y administra automáticamente. Cada servicio del homelab obtiene su propio nombre (`pihole.lan`, `jellyfin.lan`, `nextcloud.lan`, …) y se sirve por `https://` con un certificado emitido por esa CA. Los dispositivos del operador instalan **una vez** el root de la CA y dejan de ver advertencias del navegador.
2. **HTTPS para acceso remoto vía Tailscale (`pi.${TAILNET_DOMAIN}`)** usando el comando `tailscale cert`, que emite certificados Let's Encrypt **válidos públicamente** para nombres dentro del tailnet (los `*.ts.net` que asigna MagicDNS). Acceso desde fuera de casa, sin abrir ningún puerto en el router, sin DDNS, sin desplegar `acme-challenge`.

Caddy también es el sitio donde se **centraliza todo el `:80` y `:443`** del host: la IP de la Pi (`192.168.1.10`) responde en esos dos puertos solo a través de Caddy. El resto de servicios web del homelab (Jellyfin, Nextcloud, Portainer, Vaultwarden, …) **no publican `ports:`** en el host: viven en la red Docker interna `homelab` y son alcanzables solo a través de Caddy. Eso reduce la superficie expuesta a la LAN, unifica la política de TLS y mantiene los certificados en un solo lugar.

Lo que este documento **no** decide:

- **Tailscale**: la instalación, el dominio del tailnet, MagicDNS y la activación de HTTPS sobre el tailnet (necesaria para que `tailscale cert` funcione) viven en `05-tailscale.md`. Aquí se prepara el bloque de Caddy correspondiente, las rutas de los certificados y un `systemd` timer que los renueva, pero **se deja desactivado** hasta que `05-tailscale.md` cierre. En este documento se documenta **cómo activarlo** y **dónde**.
- **Authelia / SSO**: Caddy soportará `forward_auth` hacia Authelia, decisión que vive en `04-seguridad/01-authelia.md`. Aquí se prepara la **estructura** del Caddyfile (snippets, drop-in `conf.d/`) para que añadir ese middleware no requiera reabrir el documento.
- **Bloques específicos de cada servicio** (Jellyfin con WebSockets, Nextcloud con `well-known`, Vaultwarden con WebSocket, etc.): cada documento de servicio (Fases 6–11) añade **su propio fichero drop-in** en `conf.d/`. Aquí se establece el patrón con el primer caso real (Pi-hole) y se documentan los snippets reutilizables.

Cuando este documento se haya aplicado, `docker ps` lista un contenedor `caddy` saludable con `:80` y `:443` publicados sobre `192.168.1.10`, `https://pihole.lan/` carga sin advertencia tras instalar el root de la CA en el navegador, el bloque de Tailscale está versionado pero comentado a la espera de `05-tailscale.md`, y el patrón "un servicio = un fichero drop-in" queda fijado para el resto de Fases.

> **Recordatorio de alcance**: Caddy publica `:80`/`:443` solo en la IP de la Pi (`192.168.1.10`) y, una vez instalado Tailscale, en la IP del tailnet (`100.x.y.z`). **No** se abren puertos en el router doméstico, **no** se solicitan certificados Let's Encrypt sobre dominios públicos del operador. Toda la cadena TLS del homelab vive en una **CA interna** (LAN) o en certificados **emitidos para el tailnet** (Tailscale).

---

## Requisitos Previos

- Fase 2 completa:
  - Docker Engine + Compose v2; red Docker `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`.
  - `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN` (=`lan`), `LAN_IP` (=`192.168.1.10`).
- `docs/03-red/01-macvlan.md` … `03-unbound.md` aplicados:
  - Pi-hole resolviendo en `192.168.1.2`; Unbound como upstream en `192.168.1.3`.
  - `address=/${DOMAIN_LAN}/${LAN_IP}` en `/mnt/hd2t/apps/pihole/dnsmasq.d/02-homelab-local.conf` (todos los `*.lan` apuntan a la Pi).
  - Excepción específica `address=/pihole.lan/192.168.1.2` que **se sustituirá** por una entrada hacia Caddy más adelante en este mismo documento (sección "Reescribir `pihole.lan` para que pase por Caddy").
- IP del host fija (`192.168.1.10`) y nada escuchando en `:80` ni `:443`:

  ```bash
  ss -tlnp | awk 'NR==1 || $4 ~ /:(80|443)$/'
  # solo cabecera; ninguna fila de salida (puertos libres)

  ip -br -4 addr show eth0
  # eth0  UP  192.168.1.10/24
  ```

  Si algo escucha en `:80`/`:443` (un `nginx` viejo, un Pi-hole con bridge, un `apache2` heredado), se para o desinstala antes de continuar. Caddy no convive con otro servidor en esos puertos.
- Árbol de datos en `hd2t` (Fase 1, `04-estructura-directorios.md`):
  - Se crearán `/mnt/hd2t/apps/caddy/{etc,etc/conf.d,etc/tailscale,data,config,logs}` (los crea este documento).
- Operador con un dispositivo (laptop, móvil) capaz de **instalar el certificado root de la CA interna** que Caddy generará. Sin este paso, los navegadores marcan los `*.lan` como "no seguros" pese a que la cadena TLS sea correcta.

---

## Decisión: imagen y versión

Caddy mantiene su imagen oficial multi-arch (`amd64`, `arm64`, `arm/v7`) en Docker Hub bajo `caddy`. Para la Pi 5 (aarch64) se usa el manifest `arm64`.

| Tag | Cuándo usar | Decisión aquí |
|---|---|---|
| `latest` | Demos. | Descartado por convención de Fase 2. |
| `2.8.4` (ejemplo) | Estable, fijado a versión `MAYOR.MENOR.PARCHE`. | **Aceptado**. |
| `2.8.4-alpine` | Variante con base `alpine` (~50 MB vs ~120 MB de la Debian). | **Aceptado** como base preferida: la Pi 5 corre Raspberry Pi OS Lite (Debian) en el host pero el contenedor en sí no necesita `glibc`. |
| `*-builder` | Para construir Caddy con plugins (Cloudflare DNS, Tailscale, Authelia, …). | **Descartado por ahora**. Se reabre si en Fase 4/8 se necesita el plugin de Authelia o de Tailscale como módulo de Caddy (alternativa al patrón "Caddy + tailscale cert"). |

> **Tag exacto en uso**: `caddy:2.8.4-alpine`. Si en el momento de aplicar este documento existe una versión más reciente *estable*, se actualiza el tag aquí y en el `docker-compose.yml`, y se anota en el commit. **Nunca `latest`**.

> **Por qué `caddy` y no `nginx`/`traefik`**. Caddy resuelve los dos casos de este homelab (CA interna automática + bind-mount de cert.pem/key.pem para Tailscale) con un `Caddyfile` de pocas líneas, sin renovaciones manuales ni DSLs adicionales. nginx requiere `certbot`/`acme.sh` aparte; Traefik resuelve el caso pero su configuración por etiquetas en cada servicio fragmenta la fuente de verdad y complica `git diff`. Caddy mantiene **un único Caddyfile versionable**.

---

## Decisión: cómo se expone Caddy

Caddy publica **dos** servicios:

| Servicio | Puerto | A quién atiende |
|---|---|---|
| HTTP (redirección a HTTPS y `acme-challenge` interno de Caddy) | `80/tcp` | Clientes de la LAN y del tailnet. |
| HTTPS (todos los servicios reverse-proxy-eados) | `443/tcp` (y `443/udp` para HTTP/3 opcional) | Idem. |

| Opción | Cómo se ve | Discusión |
|---|---|---|
| **`network_mode: host`** | Caddy comparte la pila de red de la Pi: ata `:80` y `:443` directamente. | Resuelve sin Docker NAT, pero rompe el aislamiento Compose↔Compose: Caddy **no puede** alcanzar a otros stacks por nombre DNS de Docker (`http://pihole`, `http://jellyfin`). Habría que volver a IPs y a `127.0.0.1:PORT`. Descartado. |
| **Bridge `homelab` con `ports: ["80:80","443:443"]`** | Caddy en `homelab` (red interna `172.30.10.0/24`); Docker mapea `:80`/`:443` del host hacia el contenedor con NAT/userland-proxy. | Caddy resuelve el resto de servicios por **nombre de contenedor** (`http://pihole:80`, `http://jellyfin:8096`). El binding por defecto (`0.0.0.0:80`) cubre todas las interfaces del host: `eth0` (LAN, `192.168.1.10`) y, en el futuro, `tailscale0` (tailnet, `100.x.y.z`). **Aceptado.** |
| **Bridge `homelab` + macvlan `dns_lan` con IP propia** | Caddy con su IP en la LAN (`192.168.1.4`, p. ej.). | Sobreingeniería: la IP de la Pi (`192.168.1.10`) es el "punto único conocido" donde la LAN espera al homelab; añadir una IP más solo confunde el plan de DNS local. Macvlan se reservó en `01-macvlan.md` para servicios DNS. Descartado. |

Resultado:

```text
              LAN 192.168.1.0/24
+------------+
|  Móvil     |  ---HTTPS--->  192.168.1.10:443  -->  Caddy (bridge homelab)
|  Portátil  |                                          |
+------------+                                          v
                              http://pihole:80   (red homelab, container DNS)
                              http://jellyfin:8096
                              http://nextcloud:80
                              ...

              Tailnet 100.64.0.0/10  (Fase 3.5)
+------------+
|  Móvil     |  ---HTTPS--->  100.x.y.z:443    -->  Caddy (mismo contenedor)
|  Cliente   |                                          (cert tailscale)
+------------+
```

Notas:

- **Binding explícito a `${LAN_IP}`** (`ports: ["192.168.1.10:80:80", "192.168.1.10:443:443"]`) **se descarta**: hasta `05-tailscale.md`, `tailscale0` no existe; pero al activarlo, Caddy debe seguir respondiendo en la IP del tailnet **sin** tener que editar el compose. Con `0.0.0.0:80` y `0.0.0.0:443` (sin prefijo de IP), Caddy escucha en cualquier interfaz **presente en el host**: `eth0` ahora, `eth0`+`tailscale0` después. La frontera externa la marcan el firewall del host (UFW, Fase 1.3) y el router doméstico (sin port-forward), no el binding de Docker.
- **HTTP/3 (UDP/443)**: Caddy lo soporta por defecto. Para activarlo basta con publicar `443:443/udp`; aporta latencia mejor en móviles. Lo dejamos abierto en el compose desde el día 1.
- **`:80` no se desactiva**: Caddy lo usa para el reto HTTP-01 cuando es necesario y para redirigir HTTP→HTTPS automáticamente. Apagarlo rompe el flujo de los clientes que escriben "pihole.lan" sin esquema.

---

## Decisión: TLS por escenario

Caddy gestiona **dos cadenas TLS distintas** simultáneamente, cada una con su issuer:

| Hostname pattern | Issuer | Quién valida | Cuándo renueva |
|---|---|---|---|
| `*.${DOMAIN_LAN}` (p. ej. `pihole.lan`, `jellyfin.lan`) | **CA interna** (Caddy `internal` issuer) | Solo dispositivos que hayan instalado el root CA | Caddy lo gestiona internamente; cada cert dura ~12 horas, se renueva automáticamente en background. |
| `pi.${TAILNET_DOMAIN}` (p. ej. `pi.tailnet.ts.net`) | **Let's Encrypt sobre tailnet**, vía `tailscale cert` | Cualquier cliente con CAs públicas (todos los navegadores modernos) | Renovado por el host con un `systemd` timer; Caddy recarga automáticamente cuando el fichero cambia. |

### CA interna (`tls internal`)

Caddy implementa su propia PKI: en el primer arranque genera un par root + intermediate y persiste ambos en `/data/caddy/pki/authorities/local/`. A partir de ahí, cada vez que un sitio del Caddyfile lleva la directiva `tls internal`, Caddy emite el cert hoja firmado por ese intermediate. Ventajas para un homelab solo-LAN:

- **Sin tráfico externo**. Nada de ACME contra Let's Encrypt; nada de DNS-01; nada de DDNS. Funciona aunque la Pi esté offline.
- **Renovación automática y transparente**. Los certs hoja de `tls internal` viven 12 horas: si Caddy se cae varias horas, los nuevos se emiten al volver. Ningún cron del operador.
- **Sin `*.lan` como TLD reservado**: el navegador no se queja del TLD si la cadena TLS es válida. `lan` no está en la PSL pública pero, al firmar la hoja con una CA en la que el cliente confía, el navegador acepta la conexión.

Trade-off: cada dispositivo que quiera ver `*.lan` sin advertencia tiene que **instalar el root CA**. Se hace una vez por dispositivo y se documenta en la sección "Configuración → Instalar el root CA en los clientes".

### Cert para tailnet (`tailscale cert`)

Tailscale, una vez activada la opción "HTTPS Certificates" en el panel del tailnet (`https://login.tailscale.com/admin/dns/https`), permite a cada nodo emitir certificados Let's Encrypt válidos públicamente para su nombre `${nodo}.${TAILNET_DOMAIN}`. La validación la hace Tailscale internamente (vía DNS-01 contra los nameservers del tailnet); el operador solo invoca:

```bash
tailscale cert --cert-file <cert.pem> --key-file <key.pem> pi.tailnet.ts.net
```

Y obtiene un cert + key estándar PEM. Caddy lo consume con `tls /path/cert.pem /path/key.pem` exactamente como cualquier otro cert manual.

Ventajas:

- **Cualquier navegador** (incluso ajeno al operador, en una sesión esporádica con un familiar conectado al tailnet) acepta el cert sin instalar nada.
- **Renovación**: se hace re-ejecutando `tailscale cert` (idempotente; reemite si quedan menos de 14 días). Un `systemd` timer mensual basta.
- **No expone nada al exterior**: el reto se valida en la infraestructura de Tailscale, no en el router del operador.

Trade-offs:

- Requiere Tailscale en el host (se activa en `05-tailscale.md`).
- Un único nombre por nodo. El homelab usa `pi.${TAILNET_DOMAIN}` como hostname raíz; los servicios bajo este nombre se distinguen por **path** (`https://pi.ts.net/pihole/`, `https://pi.ts.net/jellyfin/`) o por **subdominio** si Tailscale soporta wildcards (depende de la suscripción y la configuración del tailnet). Decisión aquí: **path-based** por defecto, como solución más simple y que funciona en cualquier plan. Reabrible.

### Resumen de qué se sirve dónde

```text
Cliente en LAN                       Cliente en tailnet (móvil fuera de casa)
       |                                          |
       |  https://pihole.lan/                     |  https://pi.tailnet.ts.net/pihole/
       v                                          v
  Caddy (192.168.1.10:443)              Caddy (100.x.y.z:443)
       |     tls internal                         |    tls cert.pem key.pem
       v                                          v
  reverse_proxy http://pihole:80   <-- mismo upstream en ambos casos -->
```

---

## Stack: `stacks/caddy/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/caddy/docker-compose.yml` | microSD (git) | Stack. |
| `stacks/caddy/.env.example` | microSD (git) | Plantilla con `TAILNET_DOMAIN`. |
| `stacks/caddy/Caddyfile` | microSD (git) | Caddyfile principal (snippets globales, redirección HTTP→HTTPS). |
| `stacks/caddy/conf.d/00-pihole.caddy` | microSD (git) | Drop-in del primer servicio (Pi-hole). |
| `stacks/caddy/scripts/refresh-tailscale-cert.sh` | microSD (git) | Script que ejecuta `tailscale cert` y notifica a Caddy. |
| `/mnt/hd2t/apps/caddy/etc/Caddyfile` | hd2t | Caddyfile materializado desde la plantilla (bind mount). |
| `/mnt/hd2t/apps/caddy/etc/conf.d/` | hd2t | Drop-ins materializados; un fichero por servicio. |
| `/mnt/hd2t/apps/caddy/etc/tailscale/{cert.pem,key.pem}` | hd2t | Certificado del tailnet, refrescado por `systemd` timer. |
| `/mnt/hd2t/apps/caddy/data/` | hd2t | Estado de Caddy: PKI interna (root + intermediate), ACME nonces, key store. |
| `/mnt/hd2t/apps/caddy/config/` | hd2t | Config en JSON autoguardada por Caddy (ignorable, recreable). |
| `/mnt/hd2t/apps/caddy/logs/` | hd2t | Access logs y errors si se activan. |

### `stacks/caddy/docker-compose.yml`

```yaml
# Caddy — reverse proxy interno del homelab.
# Convenciones: ver docs/02-docker/02-estructura-compose.md y docs/03-red/04-caddy.md.

name: caddy

services:
  caddy:
    image: caddy:2.8.4-alpine
    container_name: caddy
    hostname: caddy
    restart: unless-stopped

    environment:
      TZ: ${TZ}

      # Dominio del tailnet, p. ej. "tailnet.ts.net". Se usa en el Caddyfile
      # para construir el bloque pi.${TAILNET_DOMAIN}. Hasta que 05-tailscale.md
      # active Tailscale, vale "EJEMPLO.ts.net" y el bloque está comentado.
      TAILNET_DOMAIN: ${TAILNET_DOMAIN:-EJEMPLO.ts.net}

      # Dominio LAN (heredado del .env global).
      DOMAIN_LAN: ${DOMAIN_LAN}

    networks:
      - homelab

    # Caddy ata :80 y :443 (TCP+UDP para HTTP/3) en TODAS las interfaces del
    # host. Hoy es eth0 (192.168.1.10); tras 05-tailscale.md también
    # tailscale0 (100.x.y.z). El firewall del host (UFW) y la ausencia de
    # port-forward en el router son la frontera con el exterior.
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"

    volumes:
      # Caddyfile principal y drop-ins (bind mount: editable + versionable).
      - /mnt/hd2t/apps/caddy/etc/Caddyfile:/etc/caddy/Caddyfile:ro
      - /mnt/hd2t/apps/caddy/etc/conf.d:/etc/caddy/conf.d:ro

      # Certificados del tailnet, generados por `tailscale cert` en el host.
      - /mnt/hd2t/apps/caddy/etc/tailscale:/etc/caddy/tailscale:ro

      # Estado: PKI interna, certs autoemitidos, autosave config.
      - /mnt/hd2t/apps/caddy/data:/data
      - /mnt/hd2t/apps/caddy/config:/config

      # Logs (opcional; si se activan en el Caddyfile se materializan aquí).
      - /mnt/hd2t/apps/caddy/logs:/var/log/caddy

    healthcheck:
      # `caddy validate` parsea el Caddyfile y sale 0 si es correcto.
      # No prueba conectividad real, pero detecta corrupciones de la
      # configuración tras un reload fallido.
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:80/_caddy_healthz || exit 0"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

    labels:
      homelab.role: "reverse-proxy"
      homelab.backup: "true"
      # Watchtower opt-in: Caddy se actualiza automáticamente.
      com.centurylinklabs.watchtower.enable: "true"

networks:
  homelab:
    external: true
```

> **Sobre el healthcheck**: Caddy no expone un endpoint `/healthz` por defecto; el `|| exit 0` evita falsos negativos durante el `start_period` y el primer arranque. Una mejora futura es declarar en el Caddyfile un `handle /_caddy_healthz` que devuelva `200`. Se documenta en "Configuración → Healthcheck explícito (opcional)".

### `stacks/caddy/.env.example`

```bash
# stacks/caddy/.env.example
# Variables específicas del stack Caddy.
# Las generales (TZ, DOMAIN_LAN, LAN_IP) viven en el .env GLOBAL del homelab.

# Dominio del tailnet (lo asigna Tailscale al activar la cuenta).
# Hasta que 05-tailscale.md cierre, dejar el valor de ejemplo: el bloque
# del Caddyfile correspondiente está comentado y no se evalúa.
TAILNET_DOMAIN=EJEMPLO.ts.net
```

### `stacks/caddy/Caddyfile`

```caddy
# /etc/caddy/Caddyfile — Caddyfile principal del homelab.
# Documentado en docs/03-red/04-caddy.md.

{
    # Email para notificaciones de ACME. Aunque la CA interna no envía
    # emails, Caddy lo exige formalmente; un valor falso pero válido vale.
    email admin@{$DOMAIN_LAN}

    # PKI interna: emite cert hojas firmadas por una intermediate local.
    # El root vive en /data/caddy/pki/authorities/local/root.crt y se
    # exporta para los clientes (ver "Instalar el root CA en los clientes").
    pki {
        ca local {
            name "Homelab Internal CA"
        }
    }

    # Por defecto Caddy redirige automáticamente :80 -> :443 con un 308.
    # No se desactiva: facilita teclear "pihole.lan" sin esquema.

    # Logging global (errores). Por servicio, cada drop-in puede añadir
    # su propio access log si lo necesita.
    log {
        output file /var/log/caddy/error.log {
            roll_size 10mb
            roll_keep 5
        }
        level WARN
    }
}

# -----------------------------------------------------------------------------
# Snippets reutilizables: cada drop-in los importa.
# -----------------------------------------------------------------------------

# TLS con la CA interna del homelab. Sirve para cualquier *.${DOMAIN_LAN}.
(lan_tls) {
    tls internal
}

# TLS con el certificado del tailnet (renovado por systemd timer en el host).
# Activar solo cuando 05-tailscale.md haya generado los ficheros.
(tailnet_tls) {
    tls /etc/caddy/tailscale/cert.pem /etc/caddy/tailscale/key.pem
}

# Cabeceras de seguridad mínimas para servicios web (no rompe nada conocido).
(security_headers) {
    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
        # CSP no se fija aquí: cada servicio web tiene su propia política;
        # si se quiere endurecer, se añade en el drop-in del servicio.
    }
}

# Endpoint trivial de healthcheck para el contenedor.
(healthcheck) {
    handle /_caddy_healthz {
        respond 200
    }
}

# -----------------------------------------------------------------------------
# Bloque del tailnet (Fase 3.5).
# Se mantiene comentado hasta que 05-tailscale.md genere los certificados
# en /etc/caddy/tailscale/cert.pem y /etc/caddy/tailscale/key.pem.
# Para activar: descomentar y `docker compose ... up -d --force-recreate`.
# -----------------------------------------------------------------------------
# pi.{$TAILNET_DOMAIN} {
#     import tailnet_tls
#     import security_headers
#     import healthcheck
#
#     # Path-based routing: cada servicio cuelga de un path.
#     # Cada drop-in en conf.d/ puede añadir handle_path adicionales.
#     handle_path /pihole/* {
#         reverse_proxy http://pihole:80
#     }
#
#     handle {
#         respond "Homelab — selecciona un servicio: /pihole/, /jellyfin/, ..." 200
#     }
# }

# -----------------------------------------------------------------------------
# Drop-ins por servicio. Cada Fase añade su fichero en conf.d/.
# Convención: nombre = "NN-servicio.caddy", se cargan en orden alfabético.
# -----------------------------------------------------------------------------
import /etc/caddy/conf.d/*.caddy
```

### `stacks/caddy/conf.d/00-pihole.caddy`

```caddy
# /etc/caddy/conf.d/00-pihole.caddy — bloque LAN para Pi-hole.
# Pi-hole expone su UI en http://pihole:80 dentro de la red Docker `homelab`.

pihole.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # La UI de Pi-hole carga "/admin/"; redirigir la raíz mejora UX.
    redir / /admin/ permanent

    reverse_proxy http://pihole:80 {
        # Pi-hole espera el Host original para construir enlaces internos.
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

> **Por qué `pihole.{$DOMAIN_LAN}` y no `pihole.lan` literal**: el dominio LAN es una variable global (`DOMAIN_LAN=lan` por defecto). Si el operador prefiere `home.arpa` u otro sufijo en algún momento, **un solo cambio** en `.env` lo propaga al Caddyfile y a Pi-hole. Caddy expande `{$DOMAIN_LAN}` en el momento del parseo a partir de la variable del entorno del contenedor.

### `stacks/caddy/scripts/refresh-tailscale-cert.sh`

Este script lo invoca un `systemd` timer mensual (declarado en `05-tailscale.md`) para renovar el cert. Se versiona aquí porque pertenece al stack de Caddy.

```bash
#!/usr/bin/env bash
# Renueva el cert del tailnet para Caddy. Idempotente: si quedan >14 días
# de validez, `tailscale cert` no reemite.
set -euo pipefail

ENV_FILE="/home/homelab/homelab/.env"
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

: "${TAILNET_DOMAIN:?TAILNET_DOMAIN no definido en .env}"
HOSTNAME_TS="pi.${TAILNET_DOMAIN}"

CERT_DIR="/mnt/hd2t/apps/caddy/etc/tailscale"
CERT="${CERT_DIR}/cert.pem"
KEY="${CERT_DIR}/key.pem"

mkdir -p "$CERT_DIR"
chmod 0750 "$CERT_DIR"

# `tailscale cert` requiere tailscale en el host con HTTPS habilitado.
tailscale cert --cert-file "$CERT" --key-file "$KEY" "$HOSTNAME_TS"

# Permisos: Caddy en el contenedor lee como UID interno (no root tras
# arranque). 0644 sobre el cert (público) y 0640 sobre la key bastan.
chmod 0644 "$CERT"
chmod 0640 "$KEY"
chown root:root "$CERT" "$KEY"

# Notificar a Caddy: SIGUSR1 hace reload sin downtime.
if docker ps --filter name=caddy --format '{{.Names}}' | grep -q '^caddy$'; then
    docker kill --signal=SIGUSR1 caddy
    echo "Cert renovado para ${HOSTNAME_TS}; Caddy recargado."
else
    echo "Cert renovado para ${HOSTNAME_TS}; Caddy no está corriendo (skip reload)."
fi
```

### Crear los directorios persistentes y desplegar

```bash
# Directorios de datos (idempotente)
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/caddy
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/caddy/etc
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/caddy/etc/conf.d
sudo install -d -o root    -g root    -m 0750 /mnt/hd2t/apps/caddy/etc/tailscale
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/caddy/data
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/caddy/config
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/caddy/logs

# Materializar Caddyfile y drop-ins desde la plantilla versionada
cd /home/homelab/homelab
install -o homelab -g homelab -m 0644 \
    stacks/caddy/Caddyfile  /mnt/hd2t/apps/caddy/etc/Caddyfile
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/00-pihole.caddy  /mnt/hd2t/apps/caddy/etc/conf.d/00-pihole.caddy

# El script de renovación del cert tailscale (lo usará 05-tailscale.md):
sudo install -o root -g root -m 0750 \
    stacks/caddy/scripts/refresh-tailscale-cert.sh \
    /home/homelab/homelab/scripts/refresh-tailscale-cert.sh

# .env del stack (sin secretos en esta fase)
cp stacks/caddy/.env.example stacks/caddy/.env
chmod 0600 stacks/caddy/.env

# Validar Caddyfile antes de levantar
docker run --rm \
    -v /mnt/hd2t/apps/caddy/etc/Caddyfile:/etc/caddy/Caddyfile:ro \
    -v /mnt/hd2t/apps/caddy/etc/conf.d:/etc/caddy/conf.d:ro \
    -e DOMAIN_LAN="${DOMAIN_LAN}" -e TAILNET_DOMAIN="EJEMPLO.ts.net" \
    caddy:2.8.4-alpine \
    caddy validate --config /etc/caddy/Caddyfile
# Successful

# Validar el compose con interpolación
docker compose \
    -f stacks/caddy/docker-compose.yml \
    --env-file .env --env-file stacks/caddy/.env \
    config >/dev/null && echo "compose OK"

# Levantar
docker compose \
    -f stacks/caddy/docker-compose.yml \
    --env-file .env --env-file stacks/caddy/.env \
    up -d
```

Tras `up -d`:

```bash
docker ps --filter name=caddy
# CONTAINER ID  IMAGE                STATUS                 PORTS                                          NAMES
# ...           caddy:2.8.4-alpine   Up 30 seconds (healthy) 0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp, ...  caddy

docker compose -f stacks/caddy/docker-compose.yml logs --tail 30
# {"level":"info","msg":"using config from file","config_file":"/etc/caddy/Caddyfile"}
# {"level":"info","msg":"adapted config to JSON","adapter":"caddyfile"}
# {"level":"info","msg":"defining new server"}
# {"level":"info","msg":"PKI: generating intermediate","name":"local"}
# {"level":"info","msg":"certificate obtained","identifier":"pihole.lan"}
# {"level":"info","msg":"serving HTTPS","addresses":["0.0.0.0:443"]}
```

`STATUS=(healthy)` debe llegar en ~30 s. Si se queda `(starting)` o `(unhealthy)`, lo más probable son permisos sobre `/mnt/hd2t/apps/caddy/data` o un Caddyfile inválido (en tal caso `docker logs caddy` lo grita con la línea exacta).

---

## Configuración

### 1) Reescribir `pihole.lan` para que pase por Caddy

En `02-pihole.md` se dejó la entrada **específica** `address=/pihole.lan/192.168.1.2` (Pi-hole UI directa) por encima del comodín `address=/lan/192.168.1.10` (Caddy). Ahora que Caddy está vivo, **se invierte**: `pihole.lan` debe resolver a la IP de la Pi (`192.168.1.10`) para que el navegador llegue a Caddy y este haga reverse proxy hacia el contenedor `pihole`.

```bash
# Editar /mnt/hd2t/apps/pihole/dnsmasq.d/02-homelab-local.conf
# Quitar la línea específica (ahora la cubre el comodín):
sudo sed -i '/^address=\/pihole\.lan\//d' \
    /mnt/hd2t/apps/pihole/dnsmasq.d/02-homelab-local.conf

cat /mnt/hd2t/apps/pihole/dnsmasq.d/02-homelab-local.conf
# address=/lan/192.168.1.10
# address=/unbound.lan/192.168.1.3   (si 03-unbound.md la activó)

docker exec pihole pihole restartdns
# [✓] Restarting DNS server

# Verificar
dig @192.168.1.2 pihole.lan +short
# 192.168.1.10
```

Si el operador prefiere conservar acceso directo a `http://192.168.1.2/admin/` para emergencias (Pi-hole sigue escuchando en su IP macvlan), no hay que hacer nada más: la IP siempre funciona; el cambio solo afecta a **cómo resuelve el nombre `pihole.lan`**.

### 2) Validar el flujo HTTPS hacia Pi-hole

Desde un cliente cualquiera de la LAN (ya con Pi-hole como DNS, según `02-pihole.md`):

```bash
# 1. Resuelve a la Pi
dig +short pihole.lan
# 192.168.1.10

# 2. HTTP (redirección a HTTPS)
curl -sI http://pihole.lan/ | head -1
# HTTP/1.1 308 Permanent Redirect

# 3. HTTPS (todavía con advertencia hasta el paso 4)
curl -sk https://pihole.lan/admin/ -o /dev/null -w '%{http_code}\n'
# 302 (Pi-hole redirige a /admin/index.php) o 200
```

`curl -k` ignora la advertencia de cert (CA no confiada). El navegador la mostrará hasta que se instale el root.

### 3) Instalar el root CA en los clientes

Caddy genera el root **una sola vez** en el primer arranque y lo persiste en `/data/caddy/pki/authorities/local/root.crt`. Para distribuirlo:

```bash
# Extraerlo del bind mount
sudo cp /mnt/hd2t/apps/caddy/data/caddy/pki/authorities/local/root.crt \
        /home/homelab/homelab-internal-ca.crt
sudo chown homelab:homelab /home/homelab/homelab-internal-ca.crt

# Servirlo brevemente para que cada cliente lo descargue (luego se borra
# del fileserver). Alternativas: copiar por scp, USB, o dejarlo en
# Nextcloud cuando exista (Fase 6).
python3 -m http.server --directory /home/homelab 8000 &
SERVER_PID=$!
echo "Disponible en http://192.168.1.10:8000/homelab-internal-ca.crt"
echo "Pulsa Enter cuando todos los clientes hayan instalado la CA."
read
kill $SERVER_PID
sudo rm /home/homelab/homelab-internal-ca.crt
```

Instalación según sistema:

| Sistema | Procedimiento |
|---|---|
| **macOS / iOS** | Doble clic sobre `homelab-internal-ca.crt` → Llaveros → "Sistema". Editar la confianza: "Cuando se utilice este certificado: Confiar siempre". En iOS, `Settings → General → VPN & Device Management → Profile Downloaded → Install`, luego `Settings → General → About → Certificate Trust Settings` y habilitar la confianza. |
| **Linux (Debian/Ubuntu, Raspberry Pi OS)** | `sudo cp homelab-internal-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`. Para Firefox, además: `Preferences → Privacy & Security → View Certificates → Authorities → Import`, marcar "trust to identify websites". |
| **Windows** | Doble clic → Install Certificate → Local Machine → "Trusted Root Certification Authorities". |
| **Android** | `Settings → Security → Encryption & credentials → Install a certificate → CA certificate`. **Importante**: en Android 7+, las apps **no** confían en CAs instaladas por el usuario por defecto; el navegador sí. Apps personalizadas (Jellyfin app, Bitwarden) pueden requerir trabajos adicionales o aceptación explícita. |
| **Pi (host)** | Ya pertenece a la LAN; instalarlo permite a `curl`, `wget`, `apt-cacher` confiar en la cadena: `sudo cp /mnt/hd2t/apps/caddy/data/caddy/pki/authorities/local/root.crt /usr/local/share/ca-certificates/homelab-internal-ca.crt && sudo update-ca-certificates`. |

> **Vida útil del root**: por defecto el root de Caddy dura **10 años**. La intermediate, **7 días** (rotada automáticamente). Si en algún momento se reinstala Caddy y pierde `/data/caddy/pki`, **se genera un root nuevo** y todos los clientes verán advertencia hasta reinstalar el `homelab-internal-ca.crt` actualizado. Es un evento poco frecuente y, como hay backup de `/data/caddy` en Borg (Fase 7), se restaura el root original.

### 4) Bloque de Tailscale (a activar tras `05-tailscale.md`)

El Caddyfile lleva el bloque `pi.{$TAILNET_DOMAIN}` **comentado**. Cuando `05-tailscale.md` haya:

1. Instalado Tailscale en el host y autenticado el nodo.
2. Activado HTTPS en el panel del tailnet.
3. Ejecutado por primera vez `bash /home/homelab/homelab/scripts/refresh-tailscale-cert.sh`.
4. Confirmado que existen `/mnt/hd2t/apps/caddy/etc/tailscale/cert.pem` y `key.pem`.

Entonces se descomenta el bloque y se recarga Caddy:

```bash
# Editar /mnt/hd2t/apps/caddy/etc/Caddyfile y quitar los '#' del bloque pi.*

docker compose -f /home/homelab/homelab/stacks/caddy/docker-compose.yml \
    exec caddy caddy validate --config /etc/caddy/Caddyfile
# Successful

docker kill --signal=SIGUSR1 caddy
# Caddy recarga sin downtime y empieza a servir pi.${TAILNET_DOMAIN}
```

Verificación desde un dispositivo conectado al tailnet:

```bash
curl -sI https://pi.${TAILNET_DOMAIN}/pihole/ | head -1
# HTTP/2 308   (redirección a /pihole/admin/)
```

### 5) Patrón para añadir un servicio nuevo

Cada Fase posterior (6 a 12) sigue el mismo patrón al desplegar un servicio web:

1. El `docker-compose.yml` del servicio se conecta a la red **`homelab`** (igual que Caddy).
2. El servicio **no** publica `ports:` hacia el host (a menos que tenga otro flujo no-HTTP, p. ej. Samba `:445`, MQTT `:1883`).
3. Se versiona un drop-in `stacks/caddy/conf.d/NN-servicio.caddy` con:

   ```caddy
   servicio.{$DOMAIN_LAN} {
       import lan_tls
       import security_headers
       import healthcheck

       reverse_proxy http://servicio:PUERTO_INTERNO {
           header_up Host {host}
           header_up X-Real-IP {remote_host}
           header_up X-Forwarded-For {remote_host}
           header_up X-Forwarded-Proto {scheme}
       }
   }
   ```

   Sustituyendo `servicio` y `PUERTO_INTERNO` (el puerto donde el contenedor escucha **dentro** de la red Docker, no en el host).

4. Materializar y recargar:

   ```bash
   install -o homelab -g homelab -m 0644 \
       stacks/caddy/conf.d/NN-servicio.caddy \
       /mnt/hd2t/apps/caddy/etc/conf.d/NN-servicio.caddy

   docker exec caddy caddy validate --config /etc/caddy/Caddyfile && \
       docker kill --signal=SIGUSR1 caddy
   ```

5. Si el servicio se publica también en el tailnet, añadir un `handle_path /servicio/* { reverse_proxy http://servicio:PUERTO }` dentro del bloque `pi.{$TAILNET_DOMAIN}`. Atención: muchas apps web no aceptan ser servidas bajo un `path` (asumen rutas absolutas en su HTML/JS); si rompen, se evalúa una solución dedicada (subdominio en tailnet, `tailscale serve` propio del servicio, o reescritura de URLs en Caddy con `handle_response`). Reabrible caso a caso.

### 6) Healthcheck explícito (opcional)

Para que el `healthcheck` del compose deje de depender del `|| exit 0`, añadir el snippet `(healthcheck)` que ya está en el Caddyfile a un bloque genérico que escuche en `:80`:

```caddy
# /etc/caddy/conf.d/zz-healthz.caddy — último por orden alfabético.
:80 {
    import healthcheck
    # No respond fallback: cualquier otro path se gestiona arriba (redirect a HTTPS).
}
```

Y cambiar el healthcheck del compose a:

```yaml
test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:80/_caddy_healthz | grep -q ''"]
```

> Para esta versión inicial se prefiere mantener el healthcheck laxo (`|| exit 0`) y dejar este endurecimiento como nota.

### 7) Cabeceras y ajustes específicos por servicio (notas)

Cada documento de servicio (Fases 6–11) incluirá notas sobre los ajustes que requiere su drop-in:

- **Jellyfin**: WebSockets para el cliente web (Caddy los pasa por defecto, no requiere directiva extra) y `client_max_body_size`/`request_body { max_size 10g }` para subidas grandes.
- **Nextcloud**: redirecciones de `.well-known/{caldav,carddav}` y headers `Strict-Transport-Security` con `preload`.
- **Vaultwarden**: WebSockets en `/notifications/hub` (igual que Jellyfin, lo gestiona Caddy automáticamente).
- **Authelia**: `forward_auth` en sitios protegidos; el Caddyfile ya tiene la estructura para introducirlo (Fase 4.1).

Todo eso vive **en el drop-in de cada servicio**, no en este documento.

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/caddy/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/caddy/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla versionada. |
| `/home/homelab/homelab/stacks/caddy/.env` | microSD | `homelab:homelab` | `0600` | Sin secretos en esta versión; convención. **No** versionado. |
| `/home/homelab/homelab/stacks/caddy/Caddyfile` | microSD | `homelab:homelab` | `0644` | Plantilla del Caddyfile principal. **Versionada.** |
| `/home/homelab/homelab/stacks/caddy/conf.d/*.caddy` | microSD | `homelab:homelab` | `0644` | Drop-ins por servicio. **Versionados** (un fichero por servicio del homelab). |
| `/home/homelab/homelab/scripts/refresh-tailscale-cert.sh` | microSD | `root:root` | `0750` | Renueva el cert del tailnet; lo invoca un `systemd` timer (`05-tailscale.md`). **Versionado.** |
| `/mnt/hd2t/apps/caddy/etc/Caddyfile` | hd2t | `homelab:homelab` | `0644` | Caddyfile materializado (bind mount, reload por SIGUSR1). |
| `/mnt/hd2t/apps/caddy/etc/conf.d/*.caddy` | hd2t | `homelab:homelab` | `0644` | Drop-ins materializados. |
| `/mnt/hd2t/apps/caddy/etc/tailscale/{cert.pem,key.pem}` | hd2t | `root:root` | `0644` / `0640` | Cert + key del tailnet. Renovados por el script. |
| `/mnt/hd2t/apps/caddy/data/` | hd2t | UID/GID interno del contenedor | `0750` | PKI interna (`pki/authorities/local/{root.crt,root.key,intermediate.crt,intermediate.key}`), key store de certs hoja. **Crítico**: si se pierde, todos los clientes ven CA distinta tras restaurar. |
| `/mnt/hd2t/apps/caddy/config/` | hd2t | UID/GID interno | `0750` | Config en JSON autoguardada (recreable: deriva del Caddyfile). |
| `/mnt/hd2t/apps/caddy/logs/` | hd2t | UID/GID interno | `0750` | `error.log` con rotación interna (`roll_size 10mb`, `roll_keep 5`). |

> **Tamaño**: `/data` crece poco (decenas de KB para la PKI + KB por cada cert hoja activo). Los logs con `roll_keep 5 + 10 MB` se quedan en ~50 MB máximo.

---

## Backup

A nivel del repositorio del homelab:

| Artefacto | Estrategia |
|---|---|
| `stacks/caddy/docker-compose.yml`, `Caddyfile`, `conf.d/*.caddy`, `.env.example`, `scripts/refresh-tailscale-cert.sh` | Versionados en git. Reproducibles tras un reflasheo. |
| `stacks/caddy/.env` | **No** versionado. Sin secretos en esta versión, pero respaldado por Borg como parte de `/home/homelab/homelab/`. |
| Decisiones (TLS por escenario, snippets, path-routing en tailnet, instalación del root) | Documentadas en este fichero. Reproducibles en el primer arranque tras un reflasheo. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Por qué |
|---|---|---|
| `/mnt/hd2t/apps/caddy/etc/` | **Sí**, `homelab.backup=true`. | Caddyfile y drop-ins materializados; reproducibles desde la plantilla, pero el respaldo permite recuperar drop-ins añadidos en operación normal. |
| `/mnt/hd2t/apps/caddy/etc/tailscale/` | **Sí**. | Cert/key del tailnet. Si se pierden, el script los regenera (siempre que Tailscale esté autenticado), pero respaldarlos evita un reauth+regeneración tras restore. |
| `/mnt/hd2t/apps/caddy/data/` | **Sí**, **crítico**. | Contiene la **CA interna** (root + intermediate). Sin ella, todos los clientes que tengan instalado el `homelab-internal-ca.crt` actual dejan de confiar en los nuevos certs hoja, y hay que redistribuir un root nuevo a todos los dispositivos. Se respalda con prioridad alta. |
| `/mnt/hd2t/apps/caddy/config/` | **No** (excluido en Borgmatic). | Recreable a partir del Caddyfile. |
| `/mnt/hd2t/apps/caddy/logs/` | **No** (excluido). | Logs operativos; se rota localmente, no aporta a un disaster recovery. |

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/caddy/docker-compose.yml up -d --force-recreate
# Caddy reusa /mnt/hd2t/apps/caddy/data: PKI interna idéntica, certs hoja
# se vuelven a emitir en segundos. Los clientes no notan nada.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear sistema base (Fase 1), Docker (Fase 2.1), red `homelab` (Fase 2.2), Pi-hole (`02-pihole.md`), Unbound (`03-unbound.md`).
2. Restaurar `/mnt/hd2t/apps/caddy/{etc,data,config,logs}` desde Borg.
3. `docker compose -f stacks/caddy/docker-compose.yml up -d`.
4. Verificar `curl -ksI https://pihole.lan/ -o /dev/null -w '%{ssl_verify_result}\n'` (debería ser `0` desde un cliente con el root instalado).
5. Si el restore es **sin** `data` (root CA perdida): se acepta una distribución nueva del `homelab-internal-ca.crt` a todos los clientes (paso 3 de "Configuración"). Es operativamente costoso pero no irreversible.

Si lo que se quiere es **regenerar** la CA interna (paranoia, sospecha de filtración del root):

```bash
docker compose -f stacks/caddy/docker-compose.yml down
sudo rm -rf /mnt/hd2t/apps/caddy/data/caddy/pki/authorities/local
docker compose -f stacks/caddy/docker-compose.yml up -d
# Caddy genera root + intermediate nuevos. Redistribuir root.crt a todos
# los clientes (paso 3 de "Configuración").
```

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| Caddy entra en `restarting` con `bind: address already in use` en `:80` o `:443` | Otro servicio del host (un `nginx` heredado, un Pi-hole con bridge anterior, `apache2`) ya escucha. | `sudo ss -tlnp | grep -E ':(80\|443)\b'` identifica al ocupante. Parar/eliminar antes de levantar Caddy. |
| Navegador muestra `NET::ERR_CERT_AUTHORITY_INVALID` en `https://pihole.lan` | El root de la CA interna no está instalado en ese cliente. | Distribuir e instalar `homelab-internal-ca.crt` (paso 3). |
| Tras restaurar de backup, los clientes ven `NET::ERR_CERT_AUTHORITY_INVALID` aunque tienen el root instalado | El restore se hizo **sin** `/mnt/hd2t/apps/caddy/data` y Caddy regeneró root nuevo. | Restaurar `/data` desde un backup que la incluya, o redistribuir el root nuevo. |
| `caddy validate` falla: `getting environment variable: DOMAIN_LAN` | El `.env` del compose no se está pasando, o la variable no está exportada al `caddy validate` ad-hoc. | Pasar `-e DOMAIN_LAN=...` al `docker run` de validación, o usar `docker compose exec caddy caddy validate ...` desde el contenedor ya levantado. |
| Caddy responde 502 a `https://pihole.lan` | El upstream `http://pihole:80` no está alcanzable: Caddy y Pi-hole no comparten la red `homelab`, o Pi-hole solo está en `dns_lan`. | `docker network inspect homelab` debe listar `caddy` y `pihole`. En `02-pihole.md` Pi-hole se conecta a ambas redes; verificar `networks: [dns_lan, homelab]` en su compose. |
| Caddy responde 502 a un servicio nuevo, pero Pi-hole funciona | El servicio nuevo no se conectó a la red `homelab`. | Añadir `networks: [homelab]` en su compose y `up -d --force-recreate`. |
| `tailscale cert` falla con `HTTPS not enabled on tailnet` | El panel de admin del tailnet no tiene HTTPS activado. | Activarlo en `https://login.tailscale.com/admin/dns/https`. (Lo cubre `05-tailscale.md`.) |
| Tras descomentar el bloque `pi.{$TAILNET_DOMAIN}`, Caddy arranca pero el bloque no responde | `cert.pem` o `key.pem` ausente en `/etc/caddy/tailscale/`. Caddy loguea `error opening certificate file`. | Ejecutar `bash /home/homelab/homelab/scripts/refresh-tailscale-cert.sh` desde el host (con Tailscale autenticado). Reload con `docker kill --signal=SIGUSR1 caddy`. |
| Todos los clientes de la LAN reciben `connection refused` en `:443` | Caddy está corriendo pero `0.0.0.0:443` no se publicó. `docker ps` lo confirma: la columna `PORTS` no incluye `0.0.0.0:443->443/tcp`. | Comprobar el bloque `ports:` del compose. UFW del host (Fase 1.3) tiene que permitir entrada en `:80` y `:443`: `sudo ufw allow 80,443/tcp`. |
| HTTPS funciona pero HTTP/3 (UDP/443) no (móviles) | UFW no permite UDP/443, o el router doméstico filtra UDP en algún rango. | `sudo ufw allow 443/udp`. Si el router intermedia, no aplica al ser tráfico LAN puro. |
| El navegador queda colgado en `https://pihole.lan/` | DNS del cliente no es Pi-hole, o `pihole.lan` no resuelve a `192.168.1.10` por algún caché. | `dig +short pihole.lan` desde el cliente; debe responder `192.168.1.10`. Si no, repasar `02-pihole.md` y la sección "Reescribir `pihole.lan`". |
| Caddy reinicia en bucle con `error: timed out waiting for tlsalpn challenge` | Caddy intentó ACME real (Let's Encrypt) en lugar de `internal`. Suele ser olvido del `tls internal` en un drop-in. | `grep -L 'tls internal' /mnt/hd2t/apps/caddy/etc/conf.d/*.caddy` lista los que faltan. Añadir `import lan_tls` o `tls internal`. |
| `caddy reload` (manual) no toma cambios; los antiguos siguen | Bind mount cacheado; `caddy reload` lee de la config en memoria. | `docker kill --signal=SIGUSR1 caddy` (oficial) o `docker compose restart caddy` como atajo. |
| Logs del contenedor crecen sin parar y llenan `/mnt/hd2t/apps/caddy/logs/` | Un servicio web genera muchísimo `WARN`. | El bloque `log` global ya rota a 10 MB × 5 ficheros (50 MB tope). Si se quiere reducir más: bajar a `roll_keep 2` o subir el `level` a `ERROR`. |
| El cert del tailnet caduca tras 90 días y el script no lo renovó | El `systemd` timer no está habilitado (la unidad la declara `05-tailscale.md`; si todavía no se ha aplicado, hay que renovar manualmente). | `sudo bash /home/homelab/homelab/scripts/refresh-tailscale-cert.sh`. Activar el timer cuanto antes. |
| Servicios protegidos por Authelia (Fase 4.1) muestran 401 en lugar de redirección | El `forward_auth` no se ha añadido al drop-in del servicio. | Editar el drop-in y añadir el bloque `forward_auth authelia:9091 { ... }`. Documentado en `04-seguridad/01-authelia.md`. |
| Tras añadir un drop-in nuevo, `caddy validate` lo aprueba pero el bloque no responde | El nombre del fichero no acaba en `.caddy` (la directiva `import /etc/caddy/conf.d/*.caddy` solo carga ese sufijo). | Renombrar a `NN-servicio.caddy`. |

---

## Decisiones que **no** se toman en este documento

- **Plugins de Caddy** (Cloudflare DNS, Tailscale como módulo nativo, Authelia plugin): se evalúan caso a caso. Hoy se prefiere `caddy:2.8.4-alpine` puro y composición externa (`tailscale cert` + `systemd` timer + `forward_auth` para Authelia). Reabrible si la composición externa se vuelve onerosa.
- **HTTP/3 obligatorio**: se publica `443/udp` y Caddy lo activa, pero si en algún cliente da problemas (ciertos firewalls corporativos), se desactiva añadiendo `servers { protocols h1 h2 }` en el bloque global. Documentado pero no decidido.
- **HTTPS interno entre Caddy y los upstreams** (`reverse_proxy https://...`): la mayoría de servicios del homelab solo escuchan HTTP en su red Docker. Re-cifrar dentro del bridge `homelab` es ruido sin beneficio (el tráfico no sale del host). Si en algún momento un servicio solo expone HTTPS, se documenta la directiva `tls_insecure_skip_verify` con justificación caso a caso.
- **Wildcard cert para el tailnet** (`*.pi.tailnet.ts.net`): Tailscale en algunas configuraciones permite wildcards; depende del plan y de la configuración del tailnet. La decisión por defecto es `pi.tailnet.ts.net` con path-routing. Se reabre en `05-tailscale.md`.
- **Acceso público vía cualquier dominio del operador con DNS-01 a Cloudflare**: explícitamente fuera del alcance del homelab (se reitera el "solo LAN + Tailscale" del PLAN). El Caddyfile, eso sí, está estructurado para que añadirlo más adelante (un bloque adicional con `tls { dns cloudflare ... }` y un plugin) no rompa nada de lo decidido aquí.
- **Compresión, cache, rate-limit a nivel Caddy**: se evalúa por servicio. El homelab típico no necesita rate-limit interno (LAN + tailnet), y la compresión por defecto de Caddy ya está activa para los Content-Type comunes.
- **Métricas Prometheus**: Caddy expone `/metrics` cuando se activa el servidor `admin`. Se integra en Fase 6 (monitorización).
- **Logs en JSON enviados a Loki**: se decide en Fase 6 al desplegar la stack de observabilidad. El bloque `log` actual escribe a fichero plano, suficiente para operación.

---

## Verificación Final

Antes de pasar a `05-tailscale.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/caddy/docker-compose.yml ps` | `caddy ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect caddy --format '{{.Config.Image}}'` | `caddy:2.8.4-alpine` |
| Conectado a `homelab` | `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` | incluye `caddy` y `pihole` |
| Puertos publicados | `docker port caddy` | `80/tcp -> 0.0.0.0:80`, `443/tcp -> 0.0.0.0:443`, `443/udp -> 0.0.0.0:443` |
| Caddyfile válido | `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` | `Valid configuration` |
| PKI interna creada | `ls /mnt/hd2t/apps/caddy/data/caddy/pki/authorities/local/` | `root.crt`, `root.key`, `intermediate.crt`, `intermediate.key` |
| `pihole.lan` resuelve a la Pi (no a Pi-hole macvlan) | desde un cliente: `dig +short pihole.lan` | `192.168.1.10` |
| HTTP redirige a HTTPS | `curl -sI http://pihole.lan/ \| head -1` | `HTTP/1.1 308 Permanent Redirect` |
| HTTPS responde con cert de la CA interna | `curl -ksI https://pihole.lan/ \| head -1` | `HTTP/2 200` o `HTTP/2 302` |
| Cert hoja firmado por la CA local | `echo \| openssl s_client -connect pihole.lan:443 -servername pihole.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| Tras instalar el root en un cliente, sin advertencia | navegador `https://pihole.lan/admin/` | candado verde, UI carga |
| Drop-in del servicio versionado | `git ls-files stacks/caddy/conf.d/00-pihole.caddy` | aparece tracked |
| Bloque tailnet **comentado** (no se evalúa todavía) | `grep -E '^# pi\.' /mnt/hd2t/apps/caddy/etc/Caddyfile` | una línea coincidente |
| Script de refresh de cert tailnet versionado | `ls -l scripts/refresh-tailscale-cert.sh` | `-rwxr-x---` |
| Logs sin errores fatales | `docker compose -f stacks/caddy/docker-compose.yml logs --tail 50 \| grep -E 'level":"error\|FATAL'` | sin coincidencias (o solo lo esperable: la primera emisión de `pihole.lan`) |
| Persistencia tras reboot | `sudo reboot`; tras reconectar: `docker ps --filter name=caddy` | `Up ... (healthy)` sin acción manual |
| Datos persistidos en hd2t | `du -sh /mnt/hd2t/apps/caddy/data` | `> 0` (decenas de KB) |
| `/data/caddy/pki/authorities/local/root.crt` exportable | `sudo cat /mnt/hd2t/apps/caddy/data/caddy/pki/authorities/local/root.crt \| openssl x509 -noout -subject` | `subject=CN=Homelab Internal CA` |
| Stack en git (sin secretos) | `git status; git diff --cached --stat` | `stacks/caddy/{docker-compose.yml,.env.example,Caddyfile,conf.d/00-pihole.caddy,scripts/refresh-tailscale-cert.sh}` tracked; `stacks/caddy/.env` ignorado |

Cumplido el último punto, el homelab tiene reverse proxy interno con HTTPS válido (vía CA interna) para todos los `*.${DOMAIN_LAN}`, un patrón claro para añadir servicios nuevos y la estructura preparada para que `05-tailscale.md` active el bloque del tailnet en cuestión de minutos. La siguiente puerta es **el acceso remoto sin abrir puertos**: Tailscale en `05-tailscale.md`.

---

## Referencias

- [Documento anterior: `docs/03-red/03-unbound.md`](./03-unbound.md)
- [Documento siguiente: `docs/03-red/05-tailscale.md`](./05-tailscale.md)
- [Documento relacionado: `docs/03-red/02-pihole.md`](./02-pihole.md)
- [Documento relacionado: `docs/02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)
- [Documento relacionado: `docs/01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md)
- [Caddy — Documentación oficial](https://caddyserver.com/docs/)
- [Caddy — Caddyfile concepts](https://caddyserver.com/docs/caddyfile/concepts)
- [Caddy — `tls` directive y PKI interna](https://caddyserver.com/docs/caddyfile/directives/tls)
- [Caddy — `reverse_proxy` directive](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [Caddy — Imagen Docker oficial (`caddy`) en Docker Hub](https://hub.docker.com/_/caddy)
- [Tailscale — `tailscale cert` reference](https://tailscale.com/kb/1153/enabling-https)
- [Tailscale — HTTPS Certificates en el panel](https://login.tailscale.com/admin/dns/https)
