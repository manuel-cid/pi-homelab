# Caddy (reverse proxy + HTTPS interno)

## Descripción

Despliegue de **Caddy** como **reverse proxy interno** del homelab y terminador TLS. Asume las decisiones tomadas en `docs/03-red/01-macvlan.md`, `docs/03-red/02-pihole.md` y `docs/03-red/03-unbound.md`: Caddy corre en la red Docker `homelab` (bridge `br-homelab`, `172.20.10.0/24`), escucha en `:80` y `:443` sobre la **IP de la propia Pi** (`192.168.1.3`) y expone los servicios internos como `https://<servicio>.lan` con certificados firmados por una **CA interna** que el propio Caddy gestiona en `/data/caddy/pki/authorities/local/`. Pi-hole resuelve `*.lan → 192.168.1.3` (wildcard de `02-homelab-local.conf`, `docs/03-red/02-pihole.md`), Caddy demultiplexa por _Host header_ (SNI) y reenvía a cada _backend_ por nombre interno de Docker (`pihole:80`, `portainer:9000`, …) sin volver a salir a la LAN.

Este documento **se suma al _stack_ `red`** que estrenó `docs/03-red/02-pihole.md` y al que `docs/03-red/03-unbound.md` añadió Unbound. No se crea un compose nuevo: se añade un servicio `caddy` al `~/homelab/red/docker-compose.yml` ya existente, junto a un subdirectorio `red/caddy/` con `Caddyfile` y _snippets_ versionables.

> **Alcance**: este documento despliega Caddy y configura el _reverse proxy_ HTTPS para los **dos** servicios que ya están en pie (Pi-hole y Portainer), define la _CA_ local y documenta cómo distribuir el _root cert_ a los clientes. **No** instala Tailscale (`docs/03-red/05-tailscale.md`) — el bloque para `pi.<TAILNET>.ts.net` queda preparado pero comentado hasta esa fase. **No** integra con Authelia (`docs/04-seguridad/01-authelia.md`) — el _snippet_ `forward_auth` se deja vacío y comentado para que añadir SSO sea una sola línea más adelante.

> **Recordatorio de red**: el homelab vive en LAN + Tailscale. Caddy **no** se publica a internet, no usa Let's Encrypt y no necesita un dominio DNS público. Toda la PKI es interna: la _CA_ vive en `/mnt/hd2t/services/caddy/data/` (persistente) y se confía manualmente en cada cliente. Los `*.lan` resuelven sólo dentro de la LAN doméstica (Pi-hole) y, vía `MagicDNS`, también desde dispositivos remotos por Tailscale.

---

## Requisitos previos

- `docs/03-red/01-macvlan.md` completado: red Docker `lan` (macvlan), _shim_ `macvlan-shim` activo, IP del host `192.168.1.3` reservada en el DHCP del router. La IP **debe ser estable**: los certs internos firman _SAN_ por nombre, pero el `Caddyfile` los emite asumiendo que `*.lan` apunta a `192.168.1.3`.
- `docs/03-red/02-pihole.md` completado: Pi-hole en `192.168.1.2`, _stack_ `red` (`~/homelab/red/`) creado, Pi-hole con doble interfaz (`lan` macvlan + `homelab` bridge con alias `pihole`), `02-homelab-local.conf` aplicado con `address=/lan/192.168.1.3`.
- `docs/03-red/03-unbound.md` completado: Unbound en `192.168.1.4#5335`, Pi-hole apuntando a Unbound como _upstream_ exclusivo, record `unbound.lan → 192.168.1.4` en vigor.
- `docs/02-docker/02-estructura-compose.md` completado: red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) creada y _externa_, `~/homelab/.env` con `TZ`, `HOMELAB_DOMAIN=lan` y `TAILSCALE_HOSTNAME` ya rellenos.
- `docs/02-docker/03-portainer.md` completado: Portainer accesible en `homelab` por nombre (`portainer:9000`) — Caddy lo cogerá por DNS interno, **no** por `127.0.0.1:9000`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/caddy/config/` y `/mnt/hd2t/services/caddy/data/` ya existen como directorios vacíos `root:root 0755` (Caddy corre como root dentro del contenedor — ver `docs/01-sistema/04-estructura-directorios.md`, tabla de UIDs — y el `entrypoint` ajusta lo necesario).
- `docs/01-sistema/03-seguridad-base.md` completado: `nftables` con `input drop` por defecto y _allow_ explícito para `tcp dport {80, 443}` desde la LAN (`192.168.1.0/24`) y desde el rango Tailscale (`100.64.0.0/10`). Si esas reglas no existen aún, **añadirlas antes de exponer Caddy**:

  ```bash
  sudo nft add rule inet filter input ip saddr 192.168.1.0/24 tcp dport {80, 443} accept
  sudo nft add rule inet filter input ip saddr 100.64.0.0/10  tcp dport {80, 443} accept
  ```

  Y persistirlas en `/etc/nftables.conf` (ver `docs/01-sistema/03-seguridad-base.md`).

- Que el host **no** tenga ya un servicio escuchando en `:80` ni `:443`:

  ```bash
  sudo ss -tulpn '( sport = :80 or sport = :443 )'
  ```

  Salida esperada: vacía. Si aparece un `lighttpd`, `nginx` o el `:80` accidental de Portainer, resolverlo antes de continuar (Portainer ya quedó atado a `127.0.0.1:9000` en `docs/02-docker/03-portainer.md`; sólo Caddy debe ocupar `:80` y `:443` en la IP del host).

- Conectividad saliente para descargar la imagen: `docker pull --platform linux/arm64 caddy:2.8.4-alpine >/dev/null && echo OK` debe funcionar.

---

## Decisiones de diseño

### Por qué Caddy y no Nginx Proxy Manager / Traefik

El homelab necesita un _reverse proxy_ HTTPS para **una LAN privada**: nada de DNS challenges contra Let's Encrypt, nada de exposición a internet, nada de _service discovery_ contra una _registry_. Tres candidatos descartados y por qué:

| Candidato                  | Por qué se descarta                                                                                                                                                                  |
|----------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Nginx Proxy Manager**    | UI estable, pero la configuración **vive en la BD SQLite del propio NPM** y no se versiona en git de forma natural. Cada cambio es un _click_ que hay que documentar a mano.       |
| **Traefik**                | Excelente para Docker Swarm/Kubernetes con _service discovery_ por _labels_. En un homelab con ~25 contenedores estáticos ese poder añade complejidad innecesaria; el `Caddyfile` declarativo es más legible y diff-eable.|
| **HAProxy / nginx puro**   | Necesitan una _toolchain_ aparte para gestionar certs (Certbot, mkcert, …). Caddy trae **CA interna** y emisión TLS automática de fábrica.                                          |

Caddy gana por:

- **`tls internal`** — una directiva, una CA local autogenerada en `/data/caddy/pki/authorities/local/`, certs firmados al vuelo para cada bloque del `Caddyfile`. Cero ceremonia.
- **`Caddyfile` declarativo** — toda la configuración en un fichero versionable, con _snippets_ (`import`) para no repetir bloques.
- **HTTP/3 y HTTPS auto-redirect** habilitados por defecto.
- **Reload sin _downtime_**: `caddy reload` recarga la configuración con _hot reload_ en milisegundos; perfecto para añadir un servicio nuevo sin _restart_.

### Imagen y _tag_

- **`caddy:2.8.4-alpine`** (Caddy **2.8.4**, multi-arch con `linux/arm64`).
- Se pinnea explícitamente; **no** se usa `:latest` ni `:2`/`:2-alpine` (convención del homelab: _tags_ con versión completa, `docs/02-docker/04-watchtower.md`).
- Variante `-alpine` (no la `:2.8.4` _scratch_) porque trae `apk` y un _shell_ mínimo, útil para `docker exec caddy caddy validate /etc/caddy/Caddyfile` y para diagnóstico (`wget`, `nslookup`).
- **Imagen oficial** (`docker.io/library/caddy`) — no se usa el _build_ con _plugins_ (`caddy:2.8.4-builder`) porque no necesitamos `caddy-dns/cloudflare` ni similares: la PKI es interna y no hace _DNS-01_ con un proveedor.
- Caddy entra en _opt-in_ de Watchtower (`docs/02-docker/04-watchtower.md`): es _stateless_ desde el punto de vista de la lógica (toda la config viene del `Caddyfile` montado _read-only_), y la única "BD" persistente es el directorio `/data` con la CA local — que **no** cambia entre _patch versions_. Las regresiones se detectan en segundos por Uptime Kuma (los healthchecks de los servicios detrás de Caddy fallarán al unísono).

### CA interna en lugar de Let's Encrypt

Caddy emite certs `*.lan` y `<servicio>.lan` con su propia _Certificate Authority_ raíz, que se autogenera la primera vez que arranca y vive en:

```
/mnt/hd2t/services/caddy/data/caddy/pki/authorities/local/
├── root.crt          ← este es el cert que se distribuye a los clientes
├── root.key
├── intermediate.crt
└── intermediate.key
```

Ventajas:

- **Sin dependencia de internet**: Let's Encrypt requiere DNS público o `:80` accesible desde fuera. El homelab no tiene ninguna de las dos cosas (LAN privada, `*.lan` no existe en DNS público).
- **Sin _rate limits_**: ACME tiene límites por dominio/semana. Una CA local emite todo lo que quieras.
- **Sin _renovaciones_ automáticas que fallen** en silencio cuando el ISP cambia la IP pública o el router decide bloquear puertos.

Coste:

- **Hay que confiar el _root cert_ manualmente** en cada cliente (portátiles, móviles, navegadores, sistemas operativos). Es una operación puntual por dispositivo; documentada más abajo en la sección **Confianza en la CA local**.
- Si se pierde `/mnt/hd2t/services/caddy/data/`, la CA se regenera distinta y **todos los clientes vuelven a desconfiar** hasta que se importe el nuevo _root_. Por eso el directorio entra en Borgmatic (`homelab.backup: "true"`).

> **Tailscale como vía complementaria para el remoto**: cuando llegue `docs/03-red/05-tailscale.md`, Tailscale obtendrá certs **públicamente válidos** vía `tailscale cert` para `pi.<TAILNET>.ts.net` (Let's Encrypt firma esos dominios sin _challenge_ porque Tailscale es la _autoridad_ del subdominio). Esos certs **sí** los confían los navegadores sin tocar nada. Caddy los servirá en paralelo a los `*.lan` con CA interna: bloque dedicado y `tls /path/cert /path/key`. Lo deja perfilado este doc, lo cablea el siguiente.

### Caddy en `homelab` (bridge), no en `lan` (macvlan)

A diferencia de Pi-hole y Unbound, **Caddy no necesita IP propia en la LAN**. Bindea sus puertos `:80` y `:443` al host de la Pi (`192.168.1.3`) por `ports:`, lo que basta para:

- Ser alcanzable desde toda la LAN doméstica como `192.168.1.3:443` (y por `*.lan` gracias al wildcard de Pi-hole).
- Ser alcanzable vía Tailscale (cuando llegue) por `<TAILSCALE_HOSTNAME>.<TAILNET>.ts.net:443` (Tailscale escucha en `100.x.y.z` _en el host_, y Docker bindea por defecto a `0.0.0.0` dentro de `ports:` sin filtrar IP — los `ports:` de este servicio bindeen explícitamente a `192.168.1.3` y, cuando llegue Tailscale, se añade un segundo bind).

Razones para **no** ponerlo en `macvlan`:

- Las IPs `192.168.1.0/29` del rango macvlan están reservadas para servicios DNS (Pi-hole, Unbound) y dejarían sin IP el _shim_/host.
- Caddy alcanza Pi-hole **por nombre** (`pihole`) gracias a la red `homelab` y a los _aliases_ de la doble interfaz de Pi-hole (`docs/03-red/02-pihole.md`, sección **Pi-hole en dos redes a la vez**). Lo mismo para Portainer (`portainer:9000`) y para todo lo que llegue después.

### Almacenamiento

| Ruta en el host                                  | Contenido                                                                | Backup |
|--------------------------------------------------|--------------------------------------------------------------------------|--------|
| `~/homelab/red/Caddyfile`                        | Configuración principal (versionada en git)                              | Sí (vía git) |
| `~/homelab/red/caddy/snippets/`                  | _Snippets_ reutilizables (`security-headers.caddy`, `authelia.caddy`, …) | Sí (vía git) |
| `/mnt/hd2t/services/caddy/data/`                 | `caddy/pki/authorities/local/` (CA local) + `caddy/locks/` + `caddy/certificates/` | **Sí** (Borgmatic) |
| `/mnt/hd2t/services/caddy/config/`               | Estado interno de Caddy (`caddy.json` _autosaved_)                       | No (regenerable) |

`/mnt/hd2t/services/caddy/data/` es lo único que **debe persistir y respaldarse**: si se pierde la CA local, hay que reinstalar el _root_ en todos los clientes. La configuración está en git (no en `/mnt/hd2t/`); restaurar Caddy = clonar el repo + restaurar `data/` desde Borgmatic + `make up STACK=red`.

---

## Estructura del _stack_ `red` tras este documento

`~/homelab/red/` ya existe (`docs/03-red/02-pihole.md` y `03-unbound.md`). Se le añade el `Caddyfile`, un subdirectorio `caddy/snippets/` y se modifican algunos ficheros existentes:

```
~/homelab/red/
├── docker-compose.yml             # ← se modifica (añade servicio 'caddy')
├── .env                           # ← se modifica (añade vars CADDY_*, HOMELAB_PI_IPV4)
├── .env.example                   # ← se modifica (idem, sin valores reales)
├── Caddyfile                      # ← nuevo
├── caddy/
│   └── snippets/                  # ← nuevo
│       ├── security-headers.caddy
│       ├── logging.caddy
│       └── authelia.caddy         # vacío hasta docs/04-seguridad/01-authelia.md
├── etc-dnsmasq.d/
│   └── 02-homelab-local.conf      # sin cambios — el wildcard *.lan ya lo cubre
└── unbound/
    ├── unbound.conf
    ├── a-records.conf
    └── forward-records.conf
```

Crear los subdirectorios:

```bash
mkdir -p ~/homelab/red/caddy/snippets
chmod 0750 ~/homelab/red/caddy
```

> Permisos `0750`: igual criterio que `red/etc-dnsmasq.d/` y `red/unbound/` — sólo el usuario `homelab` necesita leer/editar.

---

## Variables de entorno

Añadir al final de `~/homelab/red/.env.example` (versionado en git, sin valores reales):

```bash
# --- Caddy (docs/03-red/04-caddy.md) --------------------------------------
CADDY_IMAGE_TAG=2.8.4-alpine

# IP del propio host en la LAN — en la que Caddy bindea :80 y :443.
# Coincide con la IP reservada de la Pi en el router (docs/03-red/01-macvlan.md).
HOMELAB_PI_IPV4=192.168.1.3

# Email opcional para los logs de Caddy (no se usa para Let's Encrypt; toda
# la PKI es interna). Dejar vacío para silenciar el aviso de boot.
CADDY_ADMIN_EMAIL=
```

Y replicar los cambios en `~/homelab/red/.env` (que **no** se _commitea_), añadiendo los valores reales:

```bash
cd ~/homelab/red
$EDITOR .env       # añadir CADDY_IMAGE_TAG, HOMELAB_PI_IPV4 y, opcional, CADDY_ADMIN_EMAIL
chmod 0600 .env
```

> **`HOMELAB_PI_IPV4` puede vivir también en `~/homelab/.env`** (es global; lo necesita cualquier servicio que bindee al host). Convención del homelab (`docs/02-docker/02-estructura-compose.md`): si una variable la usan **dos o más** _stacks_, sube a `~/homelab/.env`. Por ahora sólo Caddy la usa; se promueve cuando un segundo _stack_ la necesite.

---

## Configuración: `Caddyfile` y _snippets_

### `~/homelab/red/Caddyfile`

```caddyfile
# Caddy — reverse proxy y HTTPS interno del homelab.
# Documentación: docs/03-red/04-caddy.md
# Esta configuración la consume caddy:2.8.4-alpine montada read-only.
#
# Convención de bloques:
#   - Cada servicio del homelab tiene su propio bloque <servicio>.lan.
#   - Los bloques importan snippets/security-headers.caddy y snippets/logging.caddy.
#   - El reverse_proxy apunta al backend por NOMBRE de Docker (red 'homelab'),
#     nunca por IP.
#   - 'tls internal' = certs firmados por la CA local de Caddy.

# ---------------------------------------------------------------------------
# Opciones globales
# ---------------------------------------------------------------------------
{
    # Sin email de ACME — toda la PKI es interna. El campo se mantiene por
    # si en el futuro se quisiera mezclar Let's Encrypt para algún subdominio
    # público (no es el caso del homelab).
    email {$CADDY_ADMIN_EMAIL}

    # CA interna — autogenerada la primera vez en /data/caddy/pki/authorities/local/.
    # NO se toca: dejamos que Caddy la mantenga.
    # Validez de los certs hijos: 90 días por defecto, renovación automática.
    pki {
        ca local {
            name "Homelab Local CA"
            root_cn "Homelab Local Root CA"
            intermediate_cn "Homelab Local Intermediate CA"
        }
    }

    # Admin API — sólo escucha en localhost del propio contenedor (no se
    # expone al host). 'caddy reload' lo usa internamente.
    admin localhost:2019

    # Logs estructurados a stdout (los recoge Dozzle, docs/05-monitorizacion/06-dozzle.md).
    log default {
        output stdout
        format json
        level INFO
    }

    # Servidor HTTP/3 (QUIC) sobre :443/udp, además del HTTP/2 sobre :443/tcp.
    servers {
        protocols h1 h2 h3
    }
}

# ---------------------------------------------------------------------------
# Snippets — definidos en caddy/snippets/, importados aquí
# ---------------------------------------------------------------------------
import /etc/caddy/snippets/*.caddy

# ---------------------------------------------------------------------------
# Default catch-all — cualquier *.lan no listada explícitamente devuelve 404
# en lugar de pintar el "Welcome to Caddy" o caer al primer bloque por azar.
# ---------------------------------------------------------------------------
*.lan {
    tls internal
    respond "Servicio no configurado en Caddy. Revisa Caddyfile." 404 {
        close
    }
    log
}

# ---------------------------------------------------------------------------
# Pi-hole — UI de administración del DNS interno
# ---------------------------------------------------------------------------
pihole.lan {
    tls internal
    import security-headers
    import logging

    # Pi-hole en la red 'homelab' como 'pihole:80' (alias declarado en
    # docs/03-red/02-pihole.md). NO usar 192.168.1.2 — eso saldría por la LAN.
    reverse_proxy pihole:80 {
        # Pi-hole pone <a href="/admin/..."> sin Host header lookup; pasamos
        # el original para que los redirects funcionen.
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }

    # Redirigir / a /admin (Pi-hole no tiene landing page propia)
    redir / /admin/ 302
}

# ---------------------------------------------------------------------------
# Portainer — UI de gestión de Docker
# Tras este doc, el bloque 'ports: 127.0.0.1:9000:9000' del stack 'infra'
# se elimina (ver docs/02-docker/03-portainer.md, sección 'Cuando Caddy
# esté operativo'). El acceso pasa a ser exclusivamente vía portainer.lan.
# ---------------------------------------------------------------------------
portainer.lan {
    tls internal
    import security-headers
    import logging

    # Portainer expone HTTP en :9000 (HTTPS autofirmado en :9443 lo dejamos).
    # Caddy termina TLS y reenvía HTTP plano dentro de 'homelab'.
    reverse_proxy portainer:9000 {
        # Portainer usa WebSockets para los logs en vivo y para 'exec'
        # interactivo. Caddy 2 los hace transparentes por defecto, pero
        # explicitar Connection/Upgrade evita bugs sutiles tras un reload.
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up Connection {>Connection}
        header_up Upgrade {>Upgrade}
    }
}

# ---------------------------------------------------------------------------
# Bloque preparado para Tailscale — se activa en docs/03-red/05-tailscale.md.
# Cuando se monte Tailscale, este bloque se descomenta y se sustituye
# 'TAILSCALE_HOSTNAME' y 'TAILNET' por los reales (también disponible
# como var de entorno; ver docs/03-red/05-tailscale.md).
# ---------------------------------------------------------------------------
# {$TAILSCALE_HOSTNAME}.{$TAILNET}.ts.net {
#     # Tailscale obtiene certs públicamente válidos vía 'tailscale cert'.
#     # El daemon los renueva y los deja en /var/lib/tailscale/certs/.
#     # En docs/03-red/05-tailscale.md se monta ese path como volume read-only.
#     tls /etc/caddy/tailscale-cert.crt /etc/caddy/tailscale-cert.key
#
#     import security-headers
#     import logging
#
#     # Mismo router de hosts que para *.lan: usar @host matchers.
#     @pihole host pihole.{$TAILSCALE_HOSTNAME}.{$TAILNET}.ts.net
#     handle @pihole {
#         reverse_proxy pihole:80
#     }
#     # ... un handle por servicio
# }
```

> **Por qué `import /etc/caddy/snippets/*.caddy` y no inlinear todo**: cada _snippet_ es reutilizable en muchos bloques (`security-headers` lo usan **todos** los servicios). Manteniéndolos aparte, un cambio (p. ej. añadir `Strict-Transport-Security`) toca un solo fichero.

> **Por qué `tls internal` por bloque y no `default_sni` global**: cada bloque es un servicio distinto y conviene aislar su PKI. Si en el futuro Vaultwarden necesita ECDSA P-256 y el resto sigue con RSA 4096, se cambia sólo en su bloque sin tocar al resto.

### `~/homelab/red/caddy/snippets/security-headers.caddy`

```caddyfile
# Cabeceras de seguridad mínimas para cualquier servicio HTTPS del homelab.
# Importar en cada bloque con: 'import security-headers'.
(security-headers) {
    header {
        # HTTPS estricto — sólo HTTPS, 1 año, todos los subdominios.
        # max-age en segundos; preload no aplica (no estamos en internet).
        Strict-Transport-Security "max-age=31536000; includeSubDomains"

        # Anti-clickjacking — denegar embebido en <iframe>.
        X-Frame-Options "DENY"

        # Anti-MIME-sniffing
        X-Content-Type-Options "nosniff"

        # Privacidad — sin Referer cross-origin.
        Referrer-Policy "strict-origin-when-cross-origin"

        # Permisos — denegar cámara/micro/geo por defecto. Servicios que
        # los necesiten (Jellyfin con 'remote-control', Home Assistant con
        # micrófono) los reactivan en su propio bloque sobreescribiendo
        # esta cabecera.
        Permissions-Policy "camera=(), microphone=(), geolocation=()"

        # No exponer la versión de Caddy
        -Server
    }
}
```

### `~/homelab/red/caddy/snippets/logging.caddy`

```caddyfile
# Log por servicio — fichero JSON aparte para que Promtail/Loki lo recoja
# (docs/05-monitorizacion/, fase posterior). Por ahora el log también va
# a stdout vía la opción global, pero conviene tener un fichero por host.
(logging) {
    log {
        output file /var/log/caddy/{host}.log {
            roll_size     50mb
            roll_keep      5
            roll_keep_for 168h
        }
        format json
        level  INFO
    }
}
```

### `~/homelab/red/caddy/snippets/authelia.caddy`

```caddyfile
# Forward-auth a Authelia — VACÍO POR DISEÑO.
# Se rellena en docs/04-seguridad/01-authelia.md. Cuando Authelia esté
# operativa, este snippet exporta la directiva 'authelia' que se importa
# desde cualquier bloque que requiera SSO/2FA:
#
# (authelia) {
#     forward_auth authelia:9091 {
#         uri /api/verify?rd=https://auth.lan/
#         copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
#     }
# }
#
# Por ahora sólo se versiona el placeholder para que el Caddyfile sea
# parseable con 'import snippets/*.caddy' aunque Authelia no exista.
```

Permisos:

```bash
chmod 0644 ~/homelab/red/Caddyfile
chmod 0644 ~/homelab/red/caddy/snippets/*.caddy
```

> **Validación local antes de subir nada**: Caddy trae `caddy validate`. Una vez creado el `Caddyfile`, **antes** de `up -d`:
>
> ```bash
> docker run --rm -v ~/homelab/red/Caddyfile:/etc/caddy/Caddyfile:ro \
>            -v ~/homelab/red/caddy/snippets:/etc/caddy/snippets:ro \
>            caddy:2.8.4-alpine caddy validate --config /etc/caddy/Caddyfile
> ```
>
> Salida esperada: `Valid configuration`. Cualquier _typo_ se ve aquí.

---

## Modificar `docker-compose.yml` del _stack_ `red`

Añadir el bloque `caddy:` dentro de `services:`, después del bloque `unbound:` que dejó `docs/03-red/03-unbound.md`:

```yaml
  # ---------------------------------------------------------------------------
  # Caddy — reverse proxy HTTPS interno + CA local.
  # Bindea :80 y :443 a la IP del propio host (192.168.1.3). El wildcard
  # *.lan -> 192.168.1.3 lo resuelve Pi-hole; Caddy demultiplexa por SNI/Host.
  # ---------------------------------------------------------------------------
  caddy:
    image: caddy:${CADDY_IMAGE_TAG}
    container_name: caddy
    hostname: caddy
    restart: unless-stopped
    cap_add:
      - NET_BIND_SERVICE          # bindear a :80 y :443 sin ser root del host
    environment:
      TZ: ${TZ}
      CADDY_ADMIN_EMAIL: ${CADDY_ADMIN_EMAIL}
      # TAILSCALE_HOSTNAME y TAILNET las consume el bloque comentado del
      # Caddyfile; se exportan desde ya para no tener que tocar el compose
      # en docs/03-red/05-tailscale.md.
      TAILSCALE_HOSTNAME: ${TAILSCALE_HOSTNAME}
      TAILNET: ${TAILNET:-}        # se rellenará en docs/03-red/05-tailscale.md
    volumes:
      # Configuración versionable, read-only.
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy/snippets:/etc/caddy/snippets:ro
      # Estado persistente — CA local, certs emitidos. Backup obligatorio.
      - /mnt/hd2t/services/caddy/data:/data
      - /mnt/hd2t/services/caddy/config:/config
      # Logs por host (snippets/logging.caddy escribe aquí).
      - /mnt/hd2t/services/caddy/log:/var/log/caddy
    ports:
      # Bind explícito a la IP de la Pi para evitar exponer en interfaces
      # que no son la LAN. Cuando Tailscale levante (docs/03-red/05-tailscale.md)
      # se añade aquí un segundo bind a la IP del tailnet (100.x.y.z).
      - "${HOMELAB_PI_IPV4}:80:80"
      - "${HOMELAB_PI_IPV4}:443:443"
      - "${HOMELAB_PI_IPV4}:443:443/udp"   # HTTP/3 (QUIC)
    networks:
      homelab:
        # Alias 'caddy' por defecto; lo añadimos explícito para que otros
        # contenedores puedan referirse a él si alguna vez lo necesitan
        # (p. ej. Authelia con check de salud cruzado).
        aliases:
          - caddy
      # NO se conecta a 'lan' macvlan: no necesita IP propia en la LAN.
    labels:
      homelab.stack: "red"
      homelab.backup: "true"      # /mnt/hd2t/services/caddy/data
      # Stateless desde el punto de vista de la lógica; la PKI persiste pero
      # los upgrades de patch entre 2.8.x son seguros — opt-in a Watchtower.
      com.centurylinklabs.watchtower.enable: "true"
    healthcheck:
      # /admin no responde sobre :80 ni :443 directamente; un GET a la raíz
      # con Host: pihole.lan debe devolver 200 o 302 una vez Pi-hole esté
      # detrás del proxy. Un test más simple es comprobar que Caddy
      # responde algo (404, 200, redirect — cualquier cosa que no sea
      # 'connection refused') al puerto 443 con TLS skip-verify.
      test: ["CMD", "wget", "--no-check-certificate", "--quiet", "--spider",
             "--header=Host: pihole.lan", "https://127.0.0.1/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      # No es estricto, pero arrancar Caddy antes de que Pi-hole y Unbound
      # estén operativos genera healthchecks rojos los primeros 60s. Con
      # depends_on de tipo 'service_healthy' encadenamos limpio.
      pihole:
        condition: service_healthy
      unbound:
        condition: service_healthy
```

Notas de diseño:

- **Sin `mac_address`**: Caddy no está en `lan` macvlan; no necesita reserva DHCP.
- **`cap_add: NET_BIND_SERVICE`**: la imagen oficial corre como `root` interno y no lo necesitaría, pero declararlo permite cambiar en el futuro a un usuario _non-root_ sin perder los puertos privilegiados.
- **`/var/log/caddy`**: directorio nuevo en `/mnt/hd2t/services/caddy/`. Crearlo antes del primer `up`:

  ```bash
  sudo mkdir -p /mnt/hd2t/services/caddy/log
  sudo chmod 0755 /mnt/hd2t/services/caddy/log
  ```

  El _entrypoint_ de Caddy hace `chown` al UID con el que corre.

- **`depends_on: service_healthy`**: Compose v2 lo soporta de fábrica. El `restart: unless-stopped` se encarga del reboot del host (Compose recrea el orden a partir de los _healthchecks_).
- **`com.centurylinklabs.watchtower.enable: "true"`**: opt-in. Caddy 2.x es muy estable entre _patch_; entre _minor_ (2.8 → 2.9) Watchtower también lo cubre, pero conviene leer las _release notes_ del cambio mayor (Caddy hace de las suyas con la _admin API_ de vez en cuando).
- **`healthcheck` con `wget --no-check-certificate`**: el cert es local, `wget` por defecto no lo confía aunque venga de una CA propia montada en el contenedor — para el _healthcheck_, lo que importa es que Caddy responde, no que el cert sea válido. Para validación de PKI usar la sección **Verificación final**.

---

## Despliegue

```bash
cd ~/homelab/red
docker compose --env-file ../.env --env-file .env config | grep -A40 'caddy:' | head -60   # validar sintaxis
docker compose --env-file ../.env --env-file .env up -d caddy
```

O, equivalente, con el _Makefile_:

```bash
cd ~/homelab
make up STACK=red
```

> `make up STACK=red` levantará Pi-hole y Unbound (ya en marcha, _no-op_) y Caddy (nuevo). El `up -d` de Compose es idempotente sobre servicios que no han cambiado.

Verificar:

```bash
docker compose -f ~/homelab/red/docker-compose.yml ps
# NAME      STATUS                   PORTS
# pihole    Up X minutes (healthy)   53/tcp, 53/udp, 67/udp, 80/tcp
# unbound   Up X minutes (healthy)   5335/tcp, 5335/udp
# caddy     Up X seconds (healthy)   80/tcp, 443/tcp, 443/udp
```

> El `(healthy)` de Caddy tarda ~30 s desde el arranque (el `start_period: 30s` da margen para que genere la CA local la primera vez — operación que tarda 5-10 s en una Pi 5).

Inspeccionar la CA recién creada:

```bash
ls -la /mnt/hd2t/services/caddy/data/caddy/pki/authorities/local/
# root.crt, root.key, intermediate.crt, intermediate.key — 4 ficheros, 0600
```

Y desde el contenedor:

```bash
docker exec caddy caddy list-modules | head
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
```

---

## Eliminar el `ports:` temporal de Portainer

`docs/02-docker/03-portainer.md` advirtió: "Cuando Caddy esté operativo, eliminar el bloque `ports:` del servicio `portainer`". Ahora es el momento.

Editar `~/homelab/infra/docker-compose.yml`:

```diff
   portainer:
     image: portainer/portainer-ce:${PORTAINER_IMAGE_TAG}
     container_name: portainer
     restart: unless-stopped
-    ports:
-      # Acceso temporal vía túnel SSH hasta que Caddy proxye por HTTPS.
-      # Eliminar este bloque cuando Caddy proxye por HTTPS.
-      - "127.0.0.1:9000:9000"
     volumes:
       - /var/run/docker.sock:/var/run/docker.sock:ro
```

Y aplicar:

```bash
cd ~/homelab
make up STACK=infra        # recreará portainer sin ports:
```

Confirmar que `:9000` ya no escucha en `127.0.0.1`:

```bash
sudo ss -tulpn | grep :9000     # debe estar vacío
```

Y que Portainer responde sólo vía Caddy:

```bash
curl -k --resolve portainer.lan:443:192.168.1.3 https://portainer.lan/ -I
# HTTP/2 200 (o 302 al login)
```

---

## Confianza en la CA local

Hasta que cada cliente confíe en `Homelab Local Root CA`, los navegadores/sistemas verán los `*.lan` como **certificados no confiables** (`NET::ERR_CERT_AUTHORITY_INVALID` en Chrome, "Not secure" en Safari, _toast_ rojo en Firefox). El _root cert_ está en:

```
/mnt/hd2t/services/caddy/data/caddy/pki/authorities/local/root.crt
```

Copiarlo al equipo del operador (sólo lectura, es un cert público; se le distribuye a cualquier dispositivo del hogar):

```bash
# Desde el portátil:
scp homelab:/mnt/hd2t/services/caddy/data/caddy/pki/authorities/local/root.crt \
    ~/Downloads/homelab-root.crt
```

### Linux (Debian/Ubuntu)

```bash
sudo cp ~/Downloads/homelab-root.crt /usr/local/share/ca-certificates/homelab-root.crt
sudo update-ca-certificates
# 1 added, 0 removed; done.
```

### macOS

```bash
sudo security add-trusted-cert -d -r trustRoot \
     -k /Library/Keychains/System.keychain \
     ~/Downloads/homelab-root.crt
```

O, vía UI: **Acceso a llaveros** → **Sistema** → arrastrar el `.crt` → doble clic → **Confianza** → "Al usar este certificado: Confiar siempre".

### Windows

Doble clic en `homelab-root.crt` → **Instalar certificado** → **Equipo local** → **Colocar todos los certificados en el siguiente almacén** → **Entidades de certificación raíz de confianza**.

### Android / iOS

- **Android**: Ajustes → Seguridad → Cifrado y credenciales → Instalar un certificado → Certificado de CA → seleccionar el `.crt`.
- **iOS**: AirDrop/Mail del `.crt` → Ajustes → Perfil descargado → Instalar. Después: Ajustes → General → Información → Ajustes de confianza de certificados → activar.

### Firefox (todos los SO)

Firefox **no** usa el _trust store_ del sistema por defecto. Importarlo en cada perfil:

- `about:preferences#privacy` → Certificados → Ver certificados → Autoridades → Importar → `.crt` → marcar "Confiar en esta CA para identificar sitios web".

> **Coste real**: ~5 minutos por dispositivo, una sola vez. Si `data/` se pierde y se regenera la CA, hay que repetirlo en todos. Por eso `data/` está en Borgmatic.

Verificar en cada cliente:

```bash
curl https://pihole.lan/admin/    # sin -k; debe responder 200
```

(Sin `-k` = `--insecure`. Si falla con `unable to get local issuer certificate`, el cert no está confiado en ese cliente.)

---

## Verificación final

Antes de pasar a `docs/03-red/05-tailscale.md`, comprobar:

- [ ] `docker compose -f ~/homelab/red/docker-compose.yml ps` muestra `caddy` en estado `Up` y `(healthy)` tras ~60 s.
- [ ] `ls /mnt/hd2t/services/caddy/data/caddy/pki/authorities/local/` lista `root.crt`, `root.key`, `intermediate.crt`, `intermediate.key`.
- [ ] `openssl x509 -in /mnt/hd2t/services/caddy/data/caddy/pki/authorities/local/root.crt -noout -subject -issuer -dates` muestra `subject = CN=Homelab Local Root CA` y un período de validez de ~10 años.
- [ ] `curl -k --resolve pihole.lan:443:192.168.1.3 https://pihole.lan/admin/ -I` responde `HTTP/2 200` (o `302` al login si Pi-hole tiene contraseña).
- [ ] `curl -k --resolve portainer.lan:443:192.168.1.3 https://portainer.lan/ -I` responde `HTTP/2 200` o `302`.
- [ ] `curl -k --resolve foo.lan:443:192.168.1.3 https://foo.lan/ -I` responde `HTTP/2 404` con cuerpo "Servicio no configurado en Caddy" (catch-all `*.lan`).
- [ ] `curl -k -I https://192.168.1.3/` responde `HTTP/2 308` o `404` (Caddy responde, aunque el SNI no haga match).
- [ ] `curl -I http://pihole.lan/` (sin TLS) **redirige** con `301` a `https://pihole.lan/` (Caddy auto-HTTPS).
- [ ] Tras instalar el _root cert_ en el cliente, `curl https://pihole.lan/admin/ -I` (**sin** `-k`) responde `200` y `openssl s_client -connect pihole.lan:443 -servername pihole.lan -CAfile /usr/local/share/ca-certificates/homelab-root.crt < /dev/null 2>&1 | grep 'Verify return code'` devuelve `Verify return code: 0 (ok)`.
- [ ] El navegador (con la CA importada) muestra el candado verde en `https://pihole.lan/admin/`.
- [ ] `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` devuelve `Valid configuration`.
- [ ] `docker exec caddy caddy list-certificates` lista los certs internos emitidos para `pihole.lan` y `portainer.lan`.
- [ ] El `ports: 127.0.0.1:9000:9000` ha desaparecido de `~/homelab/infra/docker-compose.yml` y `sudo ss -tulpn | grep :9000` no muestra nada.
- [ ] El contenedor sobrevive un `sudo reboot` de la Pi: tras el reinicio, `https://pihole.lan/admin/` y `https://portainer.lan/` responden sin intervención manual.
- [ ] Reload sin _downtime_:

  ```bash
  # Editar Caddyfile (añadir un bloque, p. ej.) y aplicar:
  docker exec caddy caddy reload --config /etc/caddy/Caddyfile
  # 'INF reload happened' en logs, sin reiniciar el contenedor.
  ```

  La conexión HTTPS abierta en el navegador no se interrumpe.

- [ ] `git -C ~/homelab status` muestra como **modificados**: `red/docker-compose.yml`, `red/.env.example`, `infra/docker-compose.yml`. Y como **nuevos**: `red/Caddyfile`, `red/caddy/snippets/`. **No** muestra `red/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add red/docker-compose.yml red/.env.example \
          red/Caddyfile red/caddy/ \
          infra/docker-compose.yml
  git commit -m "feat(red): add Caddy reverse proxy with internal CA"
  ```

---

## Backup

| Qué                                              | Dónde                                              | Cómo        |
|--------------------------------------------------|----------------------------------------------------|-------------|
| `Caddyfile` y _snippets_                         | `~/homelab/red/Caddyfile`, `~/homelab/red/caddy/`  | git         |
| CA local (`root.crt`, `root.key`, intermedios)   | `/mnt/hd2t/services/caddy/data/caddy/pki/`         | Borgmatic (`docs/07-backups/02-borgmatic.md`) |
| Certs emitidos (cache; regenerables)             | `/mnt/hd2t/services/caddy/data/caddy/certificates/`| Borgmatic, pero no crítico |
| Logs                                             | `/mnt/hd2t/services/caddy/log/`                    | No (rotación interna) |

> **Restauración**: clonar el repo, restaurar `/mnt/hd2t/services/caddy/data/` desde Borgmatic, `make up STACK=red`. Si `data/` no se puede restaurar, Caddy regenera una CA distinta y hay que reinstalar el `root.crt` nuevo en todos los clientes (el procedimiento de **Confianza en la CA local**, repetido).

> **Nunca _commitear_ `root.key`** al repo, ni siquiera al privado. La _root key_ vive sólo en `/mnt/hd2t/services/caddy/data/` y en los snapshots de Borgmatic (que sí están cifrados con _passphrase_).

---

## Troubleshooting

### `docker compose up caddy` falla con `bind: address already in use` para `:80` o `:443`

Algún otro servicio ocupa los puertos. Diagnóstico:

```bash
sudo ss -tulpn '( sport = :80 or sport = :443 )'
```

Causas habituales:

1. El `ports: 127.0.0.1:9000:9000` de Portainer, no eliminado, no chocaría con `:80` — pero un `lighttpd` del propio Pi-hole sí escucha en `:80` sobre `192.168.1.2`, **no** sobre `192.168.1.3`. Si aparece sobre `192.168.1.3`, es otro servicio.
2. Un `nginx` o `apache2` instalado en el host por error: `sudo systemctl disable --now nginx apache2` y revisar `/etc/`.

### `curl https://pihole.lan/` devuelve `unable to get local issuer certificate`

El _root cert_ no está confiado en ese cliente. Aplicar el procedimiento de la sección **Confianza en la CA local** y re-probar.

### El navegador muestra `NET::ERR_CERT_COMMON_NAME_INVALID`

Caddy emitió el cert para un CN distinto al que se está pidiendo. Causas:

1. **El cliente no resuelve `pihole.lan` por Pi-hole**: comprueba con `dig @192.168.1.2 pihole.lan +short` que devuelve `192.168.1.3`. Si el cliente tiene otro DNS, puede estar resolviendo `pihole.lan` a `192.168.1.2` (Pi-hole macvlan, donde escucha _lighttpd_ con un cert distinto). Configurar el cliente para usar `192.168.1.2` como DNS o añadir el record manualmente al `/etc/hosts` del cliente para validar.

2. **Caché de cert obsoleta**: si el `Caddyfile` cambió un nombre, Caddy renovó el cert pero el navegador mantiene una sesión TLS en caché. Cerrar el navegador, re-abrir, retry.

### `docker logs caddy` muestra `permission denied` al escribir certs

Permisos incorrectos sobre `/mnt/hd2t/services/caddy/data/`:

```bash
sudo chown -R root:root /mnt/hd2t/services/caddy/{data,config,log}
sudo chmod -R u=rwX,go=rX /mnt/hd2t/services/caddy/{data,config,log}
docker compose -f ~/homelab/red/docker-compose.yml restart caddy
```

### Caddy arranca pero no llega a Pi-hole — `dial tcp: lookup pihole on 127.0.0.11: no such host`

Caddy resuelve los _backends_ por el DNS embedded de Docker (`127.0.0.11`), que sólo conoce nombres de la **misma red** Docker. Si Pi-hole no tiene `homelab` declarada con _alias_ `pihole`, Caddy no la encuentra. Verificar `~/homelab/red/docker-compose.yml`:

```yaml
  pihole:
    networks:
      lan:
        ipv4_address: ${PIHOLE_LAN_IPV4}
      homelab:
        aliases:
          - pihole          # ← este alias es lo que resuelve Caddy
```

Si el _alias_ existe y aún así falla, comprobar que ambos contenedores están en la misma red:

```bash
docker network inspect homelab --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}'
# debe listar al menos 'pihole', 'caddy', 'portainer'
```

### `caddy reload` falla con `loading config from file: adapting config using caddyfile: ...`

_Typo_ en el `Caddyfile`. Validar antes de reload:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
```

El error trae línea y columna; corregir y reintentar. **Nunca** hacer `restart` para "arreglar" un syntax error: si el `Caddyfile` es inválido, el contenedor se reinicia en bucle (Caddy entra en _CrashLoopBackOff_ silencioso porque el _start_ falla).

### El cert intermedio caduca (90 días) y los clientes empiezan a desconfiar

No debería pasar: Caddy renueva el _intermediate_ automáticamente cuando le quedan ~30 días. Si por alguna razón la renovación falló, forzarla:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
docker exec caddy caddy list-certificates
```

Y revisar `docker logs caddy` por errores tipo `cannot reach <something>`. La _root_ es válida 10 años; sólo los _intermediates_ y certs hijos rotan.

### `curl --http3 https://pihole.lan/` falla, pero `curl https://pihole.lan/` funciona

QUIC (UDP/443) requiere que `nftables` permita `udp dport 443` desde la LAN (y desde Tailscale si aplica). Verificar:

```bash
sudo nft list ruleset | grep -E 'dport (443|80)'
```

Si no aparece la regla con `udp dport 443`, añadirla:

```bash
sudo nft add rule inet filter input ip saddr 192.168.1.0/24 udp dport 443 accept
```

### El `:80` redirige a `:443` pero el navegador queda en bucle

Caddy hace auto-redirect HTTP → HTTPS. Si un servicio _backend_ devuelve también un redirect (p. ej. Pi-hole con `Location: http://pihole.lan/admin/`), Caddy reescribe el _scheme_ por `X-Forwarded-Proto`. Si el redirect llega como HTTP en lugar de HTTPS al navegador, falta el header. Confirmar en el bloque del servicio:

```caddyfile
header_up X-Forwarded-Proto {scheme}
```

está presente. Algunos servicios (Vaultwarden, Nextcloud) requieren además variables de entorno explícitas `TRUST_PROXY=true`/`OVERWRITEPROTOCOL=https` — se documenta en cada uno.

### Cómo añadir un servicio nuevo

Patrón base, replicable para cualquier servicio futuro:

1. Asegurarse de que el contenedor del servicio está en la red `homelab` con un _alias_ (p. ej. `jellyfin`).
2. Añadir un bloque al `Caddyfile`:

   ```caddyfile
   jellyfin.lan {
       tls internal
       import security-headers
       import logging
       reverse_proxy jellyfin:8096
   }
   ```

3. Validar:

   ```bash
   docker exec caddy caddy validate --config /etc/caddy/Caddyfile
   ```

4. Reload:

   ```bash
   docker exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```

5. _Commit_ del `Caddyfile`.

   El cert se emite en milisegundos al primer request entrante.

> **No hace falta tocar Pi-hole**: el wildcard `*.lan → 192.168.1.3` ya cubre el nombre nuevo.

---

## Referencias

- Caddy — Documentación oficial: <https://caddyserver.com/docs/>
- Caddy — `Caddyfile` reference: <https://caddyserver.com/docs/caddyfile>
- Caddy — `pki` y CA local: <https://caddyserver.com/docs/caddyfile/options#pki>
- Caddy — `tls internal` y certs locales: <https://caddyserver.com/docs/automatic-https#local-https>
- Caddy — Imagen Docker oficial: <https://hub.docker.com/_/caddy>
- Caddy — Repo y _release notes_: <https://github.com/caddyserver/caddy>
- Mozilla — Adding a Root CA on Linux/macOS/Windows: <https://wiki.mozilla.org/CA/AddRootToFirefox>
