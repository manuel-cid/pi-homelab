# Authelia

## Descripción

Cerrada la Fase 3, el homelab tiene reverse proxy interno (`03-red/04-caddy.md`) sirviendo `https://*.${DOMAIN_LAN}` con CA interna y, opcionalmente, `https://pi.${TAILNET_DOMAIN}` por Tailscale (`03-red/05-tailscale.md`). Cada servicio (Pi-hole, Portainer, futuro Vaultwarden, futuro Nextcloud…) tiene **su propia** pantalla de login y, en muchos casos, una autenticación débil heredada por defecto: `admin/admin` en Pi-hole, contraseña local en Portainer, sesiones de larga vida en Nextcloud sin segundo factor obligatorio. Cada servicio nuevo añade una credencial más al gestor de contraseñas del operador y otra cuenta sin 2FA forzado.

Este documento despliega **Authelia**, un *companion* del reverse proxy que centraliza:

1. **Inicio de sesión único (SSO)** para los servicios web del homelab. El operador se autentica **una sola vez** en `https://auth.${DOMAIN_LAN}/`; Caddy delega cada petición a Authelia con `forward_auth` y, si la sesión es válida, deja pasar.
2. **Segundo factor (TOTP)** obligatorio para los servicios sensibles (Vaultwarden, Nextcloud admin, Portainer, la propia Authelia). El TOTP se registra en una app del móvil (Aegis, 2FAS, Bitwarden) la primera vez que se accede.
3. **Política de acceso unificada**: `bypass` para servicios que tienen su propia auth fuerte (Jellyfin), `one_factor` para servicios cómodos pero no críticos (Pi-hole), `two_factor` para los críticos. Toda la decisión vive en **un solo fichero versionable** (`configuration.yml`).
4. **Sesión común** entre todos los `*.${DOMAIN_LAN}`. Una cookie `authelia_session` emitida sobre el dominio padre (`.${DOMAIN_LAN}`) habilita todos los subservicios sin volver a teclear nada.

Authelia se compone de:

- Un **contenedor `authelia`** que sirve la portal web y atiende `/api/verify` (el endpoint que Caddy consulta en cada petición protegida).
- Un **contenedor `redis`** *sidecar* para la persistencia de sesiones. Sin Redis, Authelia mantiene sesiones en memoria y se pierden tras `docker compose restart`; con Redis sobreviven a reinicios y la experiencia de uso es la esperada.
- Una **base de datos SQLite** (fichero local) para guardar secretos TOTP, dispositivos WebAuthn, identidades verificadas y registro de intentos. Para 1–3 usuarios del homelab sobra; PostgreSQL se descarta como sobreingeniería.
- Una **base de usuarios en YAML** (`users_database.yml`) con contraseñas hasheadas en `argon2id`. Sin LDAP, sin OIDC contra un IdP externo: el homelab tiene un puñado de cuentas humanas, gestionarlas como YAML versionable es lo más simple.

Lo que este documento **no** decide:

- **`fail2ban` para Authelia**: la jail específica que vigila el log de Authelia y banea IPs con N intentos fallidos vive en `04-seguridad/02-fail2ban.md`. Aquí se prepara el **formato de log** (texto plano, ruta predecible) que esa jail necesitará.
- **Bloques `forward_auth` específicos por servicio**: cada documento de servicio (Vaultwarden, Nextcloud, Portainer…) añadirá la directiva `import authelia_two_factor` (o `authelia_one_factor`) en su drop-in de Caddy. Aquí se versiona el **snippet reutilizable**.
- **OIDC / OAuth2 como Identity Provider**: Authelia 4.38+ soporta actuar como OIDC IdP para servicios que lo entienden (Nextcloud, Grafana, Portainer Business…). Se documenta como reabrible en "Decisiones que no se toman", no se activa hoy: `forward_auth` resuelve el caso del homelab con menos partes móviles.
- **Notificaciones por email** (recuperación de contraseña, registro inicial de TOTP). El homelab no tiene SMTP propio en esta fase. Authelia se configura con notifier `filesystem`: vuelca los mails a `/data/notifications/notification.txt` y el operador los lee desde el host. Cuando llegue Fase 11 (Mailrise/relay SMTP) se reabre.

Cuando este documento se haya aplicado, `https://auth.${DOMAIN_LAN}/` muestra el portal de Authelia con el cert de la CA interna, el operador puede registrar TOTP, los servicios protegidos redirigen al portal cuando la sesión no es válida y vuelven al recurso original tras autenticarse, y el patrón "añadir un servicio = una línea `import authelia_*` en su drop-in de Caddy" queda fijado.

> **Recordatorio de alcance**: Authelia escucha **solo** en la red Docker `homelab`; no publica `ports:` al host. Solo se accede a su portal y a su API a través de Caddy. La superficie expuesta a la LAN sigue siendo `192.168.1.10:443` (Caddy) y, vía Tailscale, `100.x.y.z:443` (Caddy en su otra interfaz). Ningún cambio en el router doméstico, ninguna CA externa.

---

## Requisitos Previos

- Fase 2 completa (Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN=lan`).
- Fase 3 completa, en particular:
  - Pi-hole resolviendo `*.${DOMAIN_LAN}` al IP de la Pi (`192.168.1.10`) gracias al comodín `address=/lan/192.168.1.10` en `dnsmasq.d/02-homelab-local.conf`. Esto cubre automáticamente `auth.${DOMAIN_LAN}` sin tocar Pi-hole.
  - Caddy (`03-red/04-caddy.md`) desplegado con la CA interna funcional, snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` definidos, y el patrón "un servicio = un fichero `conf.d/NN-servicio.caddy`" en uso.
- Operador con la **CA interna instalada** en su navegador (sección "Instalar el root CA en los clientes" de `04-caddy.md`). Sin esa CA confiada, el flujo de redirección Authelia ↔ servicio rompe en cualquier *fetch* de fondo (la sesión no se establece si el navegador rechaza el cert TLS de `auth.lan`).
- Una **app TOTP** instalada en el móvil del operador (Aegis Authenticator en Android, 2FAS, Bitwarden Authenticator, Authy, Google Authenticator… cualquiera que respete el estándar RFC 6238). El TOTP se registra una vez por usuario.
- Comprobaciones:

  ```bash
  # La red Docker compartida existe
  docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

  # Caddy está corriendo y saludable
  docker ps --filter name=caddy --format '{{.Names}} {{.Status}}'
  # caddy   Up 2 hours (healthy)

  # auth.lan resuelve al IP de la Pi (gracias al comodín)
  dig +short auth.lan @192.168.1.2
  # 192.168.1.10
  ```

  Si `auth.lan` no resuelve a `192.168.1.10`, falta el comodín de Pi-hole o el cliente no usa Pi-hole como DNS; revisar `03-red/02-pihole.md` antes de seguir.

---

## Decisión: imagen y versión

Authelia publica imágenes oficiales multi-arch (`amd64`, `arm64`, `arm/v7`) en Docker Hub bajo `authelia/authelia` y mirror en GitHub Container Registry (`ghcr.io/authelia/authelia`). Para la Pi 5 (aarch64) se usa el manifest `arm64`.

| Tag | Cuándo usar | Decisión aquí |
|---|---|---|
| `latest` | Demos. | Descartado (convención de Fase 2). |
| `4` | Última `4.x.x`. Útil para entornos donde se quiere "última estable de la mayor 4". | Descartado: Authelia ha tenido cambios de breaking entre minors menores; mejor fijar minor. |
| `4.38` | Última de la `4.38.x`. | **Aceptado** como compromiso entre estabilidad y parches. |
| `4.38.17` (ejemplo) | Versión exacta `MAYOR.MENOR.PARCHE`. | Aceptable, pero requiere bumpear cada parche. Se prefiere `4.38` con Watchtower opt-in. |
| `*-coverage`, `*-test` | Builds internos. | Descartado. |

> **Tag exacto en uso**: `authelia/authelia:4.38`. Si en el momento de aplicar este documento existe una rama estable más reciente (`4.39`, `4.40`, …) con notas de release sin breaking changes para `forward_auth` + file backend + Redis, se actualiza el tag aquí y en `docker-compose.yml`, y se anota en el commit. **Nunca `latest`**.

> **Por qué Authelia y no Authentik / Keycloak**. Keycloak es un IdP completo en Java, exige mucha RAM (>1 GB en idle) y orientado a OIDC/SAML para empresa: matar moscas a cañonazos en un homelab Pi. Authentik es un competidor directo de Authelia con UI más rica pero stack más pesado (Postgres + Redis + worker + server + outpost). Authelia se queda en ~150 MB de RAM con Redis, soporta `forward_auth` nativo, su configuración cabe en un YAML versionable y no exige una base de datos relacional dedicada. Para 1–5 usuarios humanos es la opción que mejor encaja en una Pi 5.

---

## Decisión: backend de almacenamiento

Authelia separa dos almacenamientos:

1. **Storage**: identidades verificadas, secretos TOTP por usuario, claves WebAuthn, log de intentos de autenticación. Es la base de datos *de la aplicación*. Soporta `local` (SQLite), `mysql`, `postgres`.
2. **Session**: las sesiones HTTP activas. Soporta `local` (memoria de proceso) o `redis`.

| Storage | Pros | Contras | Veredicto |
|---|---|---|---|
| `local` (SQLite, fichero `db.sqlite3`) | Sin sidecar, fácil backup (un solo fichero), suficiente para <100 usuarios. | No soporta múltiples instancias de Authelia en HA. | **Aceptado**: el homelab no necesita HA. |
| `postgres` | HA, mejor rendimiento con miles de usuarios. | Requiere stack adicional (Postgres + backup propio); sobreingeniería. | Descartado. |
| `mysql` | Idem `postgres`. | Idem. | Descartado. |

| Session | Pros | Contras | Veredicto |
|---|---|---|---|
| `local` (memoria) | Sin sidecar. | Sesiones se pierden al reiniciar el contenedor (cualquier `docker compose up -d` recrea Authelia y cierra a todos los usuarios). | Descartado: degrada UX en operación normal. |
| `redis` | Sesiones sobreviven a reinicios; rendimiento óptimo. | Un sidecar más, ~5 MB de RAM. | **Aceptado**. |

Resultado: **SQLite para storage + Redis para session**. Un solo fichero que respaldar (`db.sqlite3`) y un sidecar Redis con `appendonly` activado para que sus datos persistan también.

---

## Decisión: base de usuarios

| Backend | Cómo se ve | Veredicto |
|---|---|---|
| `file` (YAML con hashes argon2id) | `users_database.yml` versionable; cuentas humanas escritas a mano. | **Aceptado**: el homelab tiene 1–3 cuentas. |
| `ldap` (servidor LDAP externo) | Authelia consulta un LDAP/AD para validar credenciales. | Descartado: no hay LDAP en el homelab; montar uno solo para Authelia es gratuito en complejidad y oneroso en mantenimiento. |

Las contraseñas se hashean **fuera** de Authelia y se pegan en `users_database.yml`. Authelia trae un comando para ello:

```bash
docker run --rm authelia/authelia:4.38 \
    authelia crypto hash generate argon2 --password 'la-contraseña-en-claro'
# $argon2id$v=19$m=65536,t=3,p=4$...$...
```

> **Importante**: la contraseña en claro **no se versiona**. Solo el hash entra a `users_database.yml`. El gestor de contraseñas (Vaultwarden, KeePassXC, Bitwarden) guarda la contraseña original.

Argon2id es la opción por defecto recomendada por Authelia y por OWASP; los parámetros (`m=65536, t=3, p=4`) tardan ~0.5 s en una Pi 5, suficiente para frenar fuerza bruta offline si alguien se hace con el `users_database.yml`.

---

## Decisión: dominio y cookie

Authelia comparte sesión entre subdominios mediante una cookie emitida en el dominio padre. Para que esto funcione:

- El portal vive en `auth.${DOMAIN_LAN}` (p. ej. `auth.lan`).
- La cookie se emite con `domain: ${DOMAIN_LAN}` (no `auth.${DOMAIN_LAN}`), de modo que el navegador la envía en cualquier subdominio del mismo padre (`pihole.lan`, `vaultwarden.lan`, …).
- Todos los servicios protegidos **deben** colgar del mismo padre (`*.lan`).

Este modelo es **incompatible** con servir Authelia bajo un *path* (`https://pi.lan/auth/`), por eso el portal va en su **propio subdominio**. Para Tailscale (donde el bloque del Caddyfile usa path-routing por defecto, ver `04-caddy.md`) se documenta como nota al final: o se reabre a un subdominio dentro del tailnet, o se acepta que el SSO funcione solo desde LAN. Decisión por defecto: **SSO solo en LAN**, en tailnet cada servicio mantiene su auth nativa. Reabrible.

---

## Stack: `stacks/authelia/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/authelia/docker-compose.yml` | microSD (git) | Stack (servicios `authelia` + `redis`). |
| `stacks/authelia/.env.example` | microSD (git) | Plantilla con `AUTHELIA_*` y referencias a secrets. |
| `stacks/authelia/configuration.yml` | microSD (git) | Plantilla de la configuración (sin secretos). |
| `stacks/authelia/users_database.yml.example` | microSD (git) | Plantilla con un usuario de ejemplo y hash bogus. |
| `stacks/caddy/conf.d/01-authelia.caddy` | microSD (git) | Drop-in del bloque LAN para `auth.${DOMAIN_LAN}` y snippets `forward_auth`. |
| `/mnt/hd2t/apps/authelia/config/configuration.yml` | hd2t | Configuración materializada (bind mount, sin secretos en claro: usa rutas a `secrets/`). |
| `/mnt/hd2t/apps/authelia/config/users_database.yml` | hd2t | Usuarios con hashes argon2id. **Sensible**: contiene el material para fuerza bruta offline. |
| `/mnt/hd2t/apps/authelia/secrets/jwt_secret` | hd2t | Secreto para firmar tokens JWT (reset password). |
| `/mnt/hd2t/apps/authelia/secrets/session_secret` | hd2t | Secreto para firmar la cookie de sesión. |
| `/mnt/hd2t/apps/authelia/secrets/storage_encryption_key` | hd2t | Cifra los TOTP secrets en la SQLite (≥64 caracteres). |
| `/mnt/hd2t/apps/authelia/secrets/redis_password` | hd2t | Contraseña Redis. |
| `/mnt/hd2t/apps/authelia/data/db.sqlite3` | hd2t | Storage de Authelia (TOTP, identidades, log de intentos). |
| `/mnt/hd2t/apps/authelia/data/notifications/notification.txt` | hd2t | Notifier `filesystem`: mails simulados (reset password, primer registro). |
| `/mnt/hd2t/apps/authelia/redis/` | hd2t | AOF de Redis (sesiones persistentes). |
| `/mnt/hd2t/apps/authelia/logs/authelia.log` | hd2t | Log estructurado en texto plano (lo consume `fail2ban` en `02-fail2ban.md`). |

### `stacks/authelia/docker-compose.yml`

```yaml
# Authelia — SSO/2FA central del homelab.
# Documentado en docs/04-seguridad/01-authelia.md.

name: authelia

services:
  authelia:
    image: authelia/authelia:4.38
    container_name: authelia
    hostname: authelia
    restart: unless-stopped
    depends_on:
      redis:
        condition: service_healthy

    environment:
      TZ: ${TZ}
      # Authelia lee secretos desde ficheros (más seguro que envvars en `inspect`).
      # El sufijo _FILE es la convención oficial de Authelia.
      AUTHELIA_JWT_SECRET_FILE: /secrets/jwt_secret
      AUTHELIA_SESSION_SECRET_FILE: /secrets/session_secret
      AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE: /secrets/storage_encryption_key
      AUTHELIA_SESSION_REDIS_PASSWORD_FILE: /secrets/redis_password

      # Variables interpoladas en configuration.yml.
      DOMAIN_LAN: ${DOMAIN_LAN}

    volumes:
      - /mnt/hd2t/apps/authelia/config:/config:ro
      - /mnt/hd2t/apps/authelia/data:/data
      - /mnt/hd2t/apps/authelia/secrets:/secrets:ro
      - /mnt/hd2t/apps/authelia/logs:/var/log/authelia

    networks:
      - homelab

    # No publica ports: solo accesible vía Caddy (red `homelab`).

    healthcheck:
      # Authelia expone /api/health (200 si todo OK). El binario `wget`
      # está en la imagen base (alpine).
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:9091/api/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

    labels:
      homelab.role: "auth"
      homelab.backup: "true"
      com.centurylinklabs.watchtower.enable: "true"

  redis:
    image: redis:7-alpine
    container_name: authelia-redis
    hostname: authelia-redis
    restart: unless-stopped

    # Lee la password desde un fichero secret y arranca con AOF.
    command:
      - sh
      - -c
      - 'redis-server --requirepass "$$(cat /run/secrets/redis_password)" --appendonly yes --appendfsync everysec'

    secrets:
      - redis_password

    volumes:
      - /mnt/hd2t/apps/authelia/redis:/data

    networks:
      - homelab

    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"$$(cat /run/secrets/redis_password)\" ping | grep -q PONG"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

    labels:
      homelab.role: "auth-cache"
      homelab.backup: "false"  # AOF se regenera; sesiones no son críticas
      com.centurylinklabs.watchtower.enable: "true"

secrets:
  redis_password:
    file: /mnt/hd2t/apps/authelia/secrets/redis_password

networks:
  homelab:
    external: true
```

> **Sobre `:ro` en `/config` y `/secrets`**: Authelia solo necesita leer; el modo solo-lectura previene corrupciones accidentales y reduce la blast radius de un eventual RCE en el contenedor. `/data` sí debe ser read-write (la SQLite escribe en cada login).

> **Sobre la red**: Authelia y Redis comparten la red `homelab`. Authelia resuelve `redis` por nombre de contenedor (`session.redis.host: authelia-redis` en `configuration.yml`). No se publica `:9091` ni `:6379` al host: ambos son accesibles solo desde dentro de `homelab` (Caddy llega a Authelia, y Authelia llega a Redis).

### `stacks/authelia/.env.example`

```bash
# stacks/authelia/.env.example
# Variables específicas del stack Authelia. Las generales (TZ, DOMAIN_LAN)
# vienen del .env GLOBAL del homelab.
#
# Ningún secreto vive aquí: los hashes y claves se materializan como
# ficheros bajo /mnt/hd2t/apps/authelia/secrets/, leídos vía *_FILE.

# (Vacío en esta fase.)
```

### `stacks/authelia/configuration.yml`

Plantilla canónica. Las decisiones más opinables están comentadas inline para que un cambio futuro encuentre el porqué.

```yaml
# /config/configuration.yml — Authelia.
# Documentado en docs/04-seguridad/01-authelia.md.

# Se usa el formato 4.38+ (`identity_validation`, etc.). Si en futuro se sube
# a 4.39 o superior y aparecen breaking changes, releer notas de release.

server:
  address: 'tcp://0.0.0.0:9091'
  buffers:
    read: 4096
    write: 4096

log:
  level: info
  format: text       # `fail2ban` parsea texto más fácil que JSON
  file_path: /var/log/authelia/authelia.log
  keep_stdout: true  # logs también a stdout para `docker logs`

theme: dark

# -----------------------------------------------------------------------------
# TOTP: el segundo factor de elección.
# WebAuthn (yubikey, FIDO2) se deja como opcional para el futuro; TOTP basta.
# -----------------------------------------------------------------------------
totp:
  disable: false
  issuer: 'Homelab'
  algorithm: SHA1     # estándar para apps TOTP (Aegis, Authy, ...)
  digits: 6
  period: 30
  skew: 1

webauthn:
  disable: true       # se reabre cuando el operador tenga una llave física

# -----------------------------------------------------------------------------
# Backend de usuarios: YAML versionable.
# -----------------------------------------------------------------------------
authentication_backend:
  password_reset:
    disable: false
  refresh_interval: 5m
  file:
    path: /config/users_database.yml
    watch: true       # recarga el fichero en caliente al editarlo
    password:
      algorithm: argon2
      argon2:
        variant: argon2id
        iterations: 3
        memory: 65536
        parallelism: 4
        key_length: 32
        salt_length: 16

# -----------------------------------------------------------------------------
# Storage: SQLite local.
# -----------------------------------------------------------------------------
storage:
  local:
    path: /data/db.sqlite3
  # encryption_key se lee desde AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE.

# -----------------------------------------------------------------------------
# Sesión: cookie común al dominio padre, almacenada en Redis.
# -----------------------------------------------------------------------------
session:
  name: authelia_session
  same_site: lax
  inactivity: 1h
  expiration: 12h
  remember_me: 1M
  cookies:
    - domain: '${DOMAIN_LAN}'
      authelia_url: 'https://auth.${DOMAIN_LAN}/'
      default_redirection_url: 'https://auth.${DOMAIN_LAN}/'
  redis:
    host: authelia-redis
    port: 6379
    # password se lee desde AUTHELIA_SESSION_REDIS_PASSWORD_FILE.

# -----------------------------------------------------------------------------
# Notifier: filesystem (no hay SMTP en el homelab en esta fase).
# Authelia escribe los "emails" como texto plano en notification.txt.
# -----------------------------------------------------------------------------
notifier:
  disable_startup_check: false
  filesystem:
    filename: /data/notifications/notification.txt

# -----------------------------------------------------------------------------
# Identity validation: secretos para flujos de password reset / element bind.
# -----------------------------------------------------------------------------
identity_validation:
  reset_password:
    jwt_lifespan: 5m
    # jwt_secret se lee desde AUTHELIA_JWT_SECRET_FILE.

# -----------------------------------------------------------------------------
# Anti fuerza bruta: además del fail2ban del host, Authelia regula.
# -----------------------------------------------------------------------------
regulation:
  max_retries: 3
  find_time: 2m
  ban_time: 5m

# -----------------------------------------------------------------------------
# Access Control: política por dominio.
# -----------------------------------------------------------------------------
access_control:
  default_policy: deny
  rules:
    # Servicios con auth fuerte propia: Authelia no se interpone.
    - domain: 'jellyfin.${DOMAIN_LAN}'
      policy: bypass
    - domain: 'stash.${DOMAIN_LAN}'
      policy: bypass

    # Servicios cómodos pero no críticos: solo contraseña + sesión.
    - domain: 'pihole.${DOMAIN_LAN}'
      policy: one_factor
    - domain: 'grafana.${DOMAIN_LAN}'
      policy: one_factor

    # Servicios sensibles: TOTP obligatorio.
    - domain:
        - 'auth.${DOMAIN_LAN}'
        - 'portainer.${DOMAIN_LAN}'
        - 'vaultwarden.${DOMAIN_LAN}'
        - 'nextcloud.${DOMAIN_LAN}'
        - 'paperless.${DOMAIN_LAN}'
      policy: two_factor

    # Cualquier otro *.${DOMAIN_LAN} no listado: por defecto deny
    # (forzando una decisión explícita en cada nuevo servicio).
```

### `stacks/authelia/users_database.yml.example`

```yaml
# /config/users_database.yml — usuarios del homelab.
# El hash se genera con:
#   docker run --rm authelia/authelia:4.38 \
#       authelia crypto hash generate argon2 --password 'CONTRASEÑA'
#
# Reglas:
#   - El hash entero, incluyendo $argon2id$v=19$..., va entre comillas simples.
#   - `displayname` es lo que se muestra en el portal.
#   - `email` se usa como destinatario de los notifier; con notifier filesystem
#     no se manda nada, pero Authelia exige el campo.
#   - `groups` se usa más adelante si se diferencia política por rol; hoy
#     basta con `admins` para el operador único.

users:
  homelab:
    disabled: false
    displayname: 'Homelab Operator'
    password: '$argon2id$v=19$m=65536,t=3,p=4$EJEMPLO_BOGUS_REPLACE_ME$EJEMPLO_BOGUS_REPLACE_ME'
    email: 'admin@${DOMAIN_LAN}'
    groups:
      - admins
```

### Drop-in de Caddy: `stacks/caddy/conf.d/01-authelia.caddy`

Este fichero hace **dos** cosas:

1. Sirve `auth.${DOMAIN_LAN}` por reverse proxy hacia el contenedor `authelia:9091`.
2. Define los snippets reutilizables `(authelia_one_factor)` y `(authelia_two_factor)` que cada drop-in de servicio importará.

```caddy
# /etc/caddy/conf.d/01-authelia.caddy — portal de Authelia + snippets forward_auth.
# Documentado en docs/04-seguridad/01-authelia.md.

# -----------------------------------------------------------------------------
# Snippets forward_auth: cada servicio protegido los importa una vez.
# -----------------------------------------------------------------------------

# Pide al menos sesión válida con contraseña (one_factor en Authelia).
(authelia_one_factor) {
    forward_auth authelia:9091 {
        uri /api/verify?rd=https://auth.{$DOMAIN_LAN}/
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }
}

# Pide sesión válida con segundo factor (TOTP) según la política definida en
# access_control. Para servicios con `policy: two_factor` apuntando a su
# dominio, este snippet es idéntico al one_factor: la decisión la toma
# Authelia en /api/verify, no Caddy. Se mantienen dos snippets por si en
# el futuro se quieren forzar parámetros distintos por nivel.
(authelia_two_factor) {
    forward_auth authelia:9091 {
        uri /api/verify?rd=https://auth.{$DOMAIN_LAN}/
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }
}

# -----------------------------------------------------------------------------
# Portal de Authelia: auth.${DOMAIN_LAN}
# -----------------------------------------------------------------------------
auth.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    reverse_proxy http://authelia:9091 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Method {method}
        header_up X-Forwarded-Host {host}
        header_up X-Forwarded-URI {uri}
    }
}
```

> **Sobre `copy_headers`**: tras una validación exitosa, Authelia devuelve cabeceras `Remote-User`, `Remote-Groups`, `Remote-Name`, `Remote-Email`. Los servicios que soportan **trusted proxy authentication** (Nextcloud, Grafana, Paperless-ngx) las consumen para hacer login automático sin volver a pedir credenciales. Los que no las soportan simplemente las ignoran.

### Crear los directorios persistentes y desplegar

```bash
# Directorios de datos
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/authelia
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/authelia/config
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/authelia/data
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/authelia/data/notifications
sudo install -d -o homelab -g homelab -m 0700 /mnt/hd2t/apps/authelia/secrets
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/authelia/redis
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/authelia/logs

# Generar los secretos (64 caracteres aleatorios cada uno)
for f in jwt_secret session_secret storage_encryption_key redis_password; do
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64 \
        | sudo -u homelab tee /mnt/hd2t/apps/authelia/secrets/$f >/dev/null
    sudo chmod 0600 /mnt/hd2t/apps/authelia/secrets/$f
    sudo chown homelab:homelab /mnt/hd2t/apps/authelia/secrets/$f
done

# Generar el hash argon2 para el usuario `homelab`
docker run --rm authelia/authelia:4.38 \
    authelia crypto hash generate argon2 --password 'CONTRASEÑA-EN-CLARO'
# Copiar el hash $argon2id$... entero al users_database.yml

# Materializar configuración y users_database desde las plantillas versionadas
cd /home/homelab/homelab
install -o homelab -g homelab -m 0640 \
    stacks/authelia/configuration.yml \
    /mnt/hd2t/apps/authelia/config/configuration.yml

# users_database.yml: NO se versiona el real (contiene hashes); solo el .example
cp stacks/authelia/users_database.yml.example /tmp/users_database.yml
$EDITOR /tmp/users_database.yml   # pegar el hash generado arriba
sudo install -o homelab -g homelab -m 0640 \
    /tmp/users_database.yml \
    /mnt/hd2t/apps/authelia/config/users_database.yml
shred -u /tmp/users_database.yml

# Drop-in de Caddy
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/01-authelia.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/01-authelia.caddy

# .env del stack (vacío de secretos en esta fase)
cp stacks/authelia/.env.example stacks/authelia/.env
chmod 0600 stacks/authelia/.env

# Validar configuración antes de levantar
docker run --rm \
    -v /mnt/hd2t/apps/authelia/config:/config:ro \
    -v /mnt/hd2t/apps/authelia/secrets:/secrets:ro \
    -e AUTHELIA_JWT_SECRET_FILE=/secrets/jwt_secret \
    -e AUTHELIA_SESSION_SECRET_FILE=/secrets/session_secret \
    -e AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE=/secrets/storage_encryption_key \
    -e AUTHELIA_SESSION_REDIS_PASSWORD_FILE=/secrets/redis_password \
    -e DOMAIN_LAN=lan \
    authelia/authelia:4.38 \
    authelia validate-config --config /config/configuration.yml
# Configuration parsed and loaded successfully without errors.

# Levantar Authelia
docker compose \
    -f stacks/authelia/docker-compose.yml \
    --env-file .env --env-file stacks/authelia/.env \
    up -d

# Recargar Caddy para que tome el drop-in nuevo
docker exec caddy caddy validate --config /etc/caddy/Caddyfile && \
    docker kill --signal=SIGUSR1 caddy
```

Tras `up -d`:

```bash
docker ps --filter name=authelia
# CONTAINER ID  IMAGE                    STATUS                 PORTS    NAMES
# ...           authelia/authelia:4.38   Up 30 seconds (healthy)          authelia
# ...           redis:7-alpine           Up 35 seconds (healthy)          authelia-redis

docker compose -f stacks/authelia/docker-compose.yml logs --tail 30 authelia
# {"level":"info","msg":"Authelia v4.38.x is starting"}
# {"level":"info","msg":"Storage schema is being checked for updates"}
# {"level":"info","msg":"Listening for non-TLS connections on '0.0.0.0:9091'"}
```

---

## Configuración

### 1) Acceder al portal y registrar TOTP

Desde un cliente de la LAN con la CA interna ya instalada:

```text
1. Abrir https://auth.lan/
2. El navegador muestra el portal de Authelia con candado verde.
3. Login con `homelab` / la contraseña en claro.
4. La primera vez, Authelia redirige a "Register your second factor".
5. Authelia escribe un "email" simulado en
       /mnt/hd2t/apps/authelia/data/notifications/notification.txt
   con el enlace de registro de TOTP (válido 5 minutos).
```

Desde la Pi:

```bash
sudo tail -f /mnt/hd2t/apps/authelia/data/notifications/notification.txt
# Subject: Register your mobile authenticator
# Title: Confirm your identity
# Link: https://auth.lan/api/one-time-code?token=...
```

Pegar el enlace en el navegador (sigue siendo la misma sesión), Authelia muestra un QR; escanearlo con la app TOTP del móvil; introducir el código de 6 dígitos. A partir de ese momento, cualquier servicio con `policy: two_factor` redirige al portal y exige TOTP además de la contraseña.

### 2) Proteger Pi-hole con Authelia (primer servicio real)

En el drop-in de Pi-hole (`stacks/caddy/conf.d/00-pihole.caddy`, creado en `04-caddy.md`) se añade el `import authelia_one_factor` (la `policy` para `pihole.${DOMAIN_LAN}` es `one_factor` en `configuration.yml`):

```caddy
# /etc/caddy/conf.d/00-pihole.caddy — bloque LAN para Pi-hole, ahora detrás de Authelia.

pihole.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck
    import authelia_one_factor       # <-- añadido

    redir / /admin/ permanent

    reverse_proxy http://pihole:80 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

Materializar y recargar:

```bash
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/00-pihole.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/00-pihole.caddy

docker exec caddy caddy validate --config /etc/caddy/Caddyfile && \
    docker kill --signal=SIGUSR1 caddy
```

Verificar (desde un navegador con sesión cerrada):

```text
1. Visitar https://pihole.lan/
2. Caddy llama a /api/verify de Authelia.
3. Authelia ve "no hay cookie authelia_session" -> 302 a https://auth.lan/?rd=https://pihole.lan/
4. Login con `homelab` -> Authelia escribe la cookie en `.lan` -> 302 de vuelta.
5. Caddy llama de nuevo a /api/verify -> Authelia responde 200 -> Pi-hole responde.
6. La UI de Pi-hole carga, **además** la cookie de admin de Pi-hole **sigue** pidiéndose
   (Pi-hole tiene su propia auth además de la de Authelia; con Authelia delante,
   Pi-hole se vuelve "doble auth": SSO + admin password de Pi-hole).
```

> **Decisión sobre el doble auth**: Pi-hole admite `WEBPASSWORD=` para deshabilitar su login interno cuando ya hay un proxy autenticador delante. Se documenta en `docs/03-red/02-pihole.md` como nota; aquí se deja **activado** el doble auth: una capa más nunca sobra para un panel que tira la red entera de la casa si se cae.

### 3) Patrón para añadir un servicio nuevo

A partir de aquí, cada servicio de las Fases 6–11 sigue una pauta de tres pasos:

1. **Decidir política** y añadirla a `access_control.rules` en `configuration.yml`. Recargar Authelia con `docker compose restart authelia` (o el contenedor recarga en caliente con `watch: true`).
2. **Añadir `import authelia_one_factor`** o `import authelia_two_factor` en su drop-in de Caddy.
3. **Recargar Caddy**: `docker kill --signal=SIGUSR1 caddy`.

Servicios con auth fuerte propia (Jellyfin) van en `bypass`: tienen sus propios mecanismos (PIN, claves de dispositivo) y no se benefician del SSO. Forzarlos a pasar por Authelia rompe los clientes nativos (Jellyfin app de Android TV, etc., que no entienden cookies de tercero).

### 4) Editar usuarios sin reiniciar

`authentication_backend.file.watch: true` recarga `users_database.yml` en caliente. Para añadir un usuario:

```bash
# 1. Generar hash
docker run --rm authelia/authelia:4.38 \
    authelia crypto hash generate argon2 --password 'OTRA-CONTRASEÑA'

# 2. Editar y añadir el bloque de usuario nuevo
sudo $EDITOR /mnt/hd2t/apps/authelia/config/users_database.yml

# 3. Authelia detecta el cambio y recarga; verificar
docker logs authelia --tail 20 | grep -i 'reloaded'
# {"level":"info","msg":"Authentication backend file '/config/users_database.yml' reloaded"}
```

No se necesita `docker compose restart authelia`.

### 5) Reset de la contraseña olvidada

Sin SMTP, el flujo "olvidé mi contraseña" del portal **no funciona** (Authelia escribe el "email" con el enlace de reset al notifier filesystem, que el operador no ve si está fuera de casa). Procedimiento manual desde la Pi:

```bash
# Generar un hash nuevo y editar users_database.yml.
# Authelia recarga el fichero automáticamente; el siguiente login usa la nueva.
```

Cuando llegue Fase 11 (relay SMTP) se sustituye `notifier.filesystem` por `notifier.smtp` y el flujo del portal pasa a funcionar.

### 6) Reset de TOTP perdido

Si el operador pierde el móvil con la app TOTP (y no exportó la semilla), se borra el secreto TOTP del usuario en la base de datos para forzar un re-registro en el siguiente login:

```bash
docker exec -it authelia authelia storage user totp delete homelab \
    --config /config/configuration.yml
# OK

# Próximo login -> Authelia pide registrar un TOTP nuevo y manda email al notifier.
```

> **Recomendación operativa**: al registrar el TOTP por primera vez, exportar la semilla a un sitio offline (papel, gestor de contraseñas con la URI `otpauth://...`) para evitar este flujo si se pierde el móvil.

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/authelia/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/authelia/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/authelia/configuration.yml` | microSD | `homelab:homelab` | `0644` | Configuración versionada (sin secretos). |
| `/home/homelab/homelab/stacks/authelia/users_database.yml.example` | microSD | `homelab:homelab` | `0644` | Plantilla con hash bogus. |
| `/home/homelab/homelab/stacks/caddy/conf.d/01-authelia.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy. **Versionado.** |
| `/mnt/hd2t/apps/authelia/config/configuration.yml` | hd2t | `homelab:homelab` | `0640` | Configuración materializada. |
| `/mnt/hd2t/apps/authelia/config/users_database.yml` | hd2t | `homelab:homelab` | `0640` | Usuarios + hashes argon2id. **No** versionado. |
| `/mnt/hd2t/apps/authelia/secrets/{jwt_secret,session_secret,storage_encryption_key,redis_password}` | hd2t | `homelab:homelab` | `0600` | Cada uno 64 caracteres aleatorios. **No** versionado. |
| `/mnt/hd2t/apps/authelia/data/db.sqlite3` | hd2t | UID/GID interno | `0640` | Storage: TOTP secrets cifrados, identidades, intentos. |
| `/mnt/hd2t/apps/authelia/data/notifications/notification.txt` | hd2t | UID/GID interno | `0640` | Notifier filesystem. Texto plano, append-only. |
| `/mnt/hd2t/apps/authelia/redis/appendonly.aof` | hd2t | UID/GID interno (redis) | `0640` | AOF de Redis: sesiones activas. |
| `/mnt/hd2t/apps/authelia/logs/authelia.log` | hd2t | UID/GID interno | `0640` | Log estructurado en texto plano. Lo consume `fail2ban` (`02-fail2ban.md`). |

> **Tamaño**: la SQLite crece linealmente con número de usuarios × dispositivos TOTP/WebAuthn (KB por entrada). Para un homelab típico se queda en <1 MB. El AOF de Redis es proporcional a la actividad de sesión: con `appendfsync everysec` y ~10 logins/día, <100 KB. El log puede crecer si hay mucho intento fallido; rota con logrotate del host (Fase 1.3) si fuera necesario.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/authelia/docker-compose.yml`, `configuration.yml`, `users_database.yml.example`, `.env.example` | Versionados. |
| `stacks/caddy/conf.d/01-authelia.caddy` | Versionado. |
| `stacks/authelia/.env` | No versionado (sin secretos en esta fase, pero respaldado en Borg como parte de `/home/homelab/homelab/`). |
| Decisiones (SQLite vs Postgres, file vs LDAP, dominio cookie, política deny-by-default) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Por qué |
|---|---|---|
| `/mnt/hd2t/apps/authelia/config/configuration.yml` | Sí. | Reproducible desde la plantilla, pero respaldarlo evita pérdida de cambios que no se hayan promovido al git. |
| `/mnt/hd2t/apps/authelia/config/users_database.yml` | **Sí, crítico**. | Los hashes de contraseñas no se regeneran; perderlos obliga a reset manual de todos los usuarios. |
| `/mnt/hd2t/apps/authelia/secrets/` | **Sí, crítico**. | Si se pierden estas claves, las cookies de sesión existentes quedan inválidas, los TOTP guardados en la SQLite no se pueden descifrar (la `storage_encryption_key` los cifra) y hay que volver a registrar todos los TOTP. |
| `/mnt/hd2t/apps/authelia/data/db.sqlite3` | **Sí, crítico**. | Contiene los TOTP secrets (cifrados) y el log de intentos. Sin ella, todos los usuarios deben re-registrar TOTP. |
| `/mnt/hd2t/apps/authelia/data/notifications/notification.txt` | No. | Mails simulados, irrelevantes pasada la primera lectura. |
| `/mnt/hd2t/apps/authelia/redis/` | No. | Sesiones activas; recuperables con re-login. |
| `/mnt/hd2t/apps/authelia/logs/` | No. | Operativo. |

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/authelia/docker-compose.yml up -d --force-recreate
# Authelia reusa /mnt/hd2t/apps/authelia/data y /secrets: SQLite intacta,
# secretos intactos, cookies vigentes siguen siendo válidas. Cero impacto.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear Fase 1, 2 y 3 (`Caddy` desplegado y CA interna distribuida o restaurada).
2. Restaurar `/mnt/hd2t/apps/authelia/{config,data,secrets}` desde Borg.
3. `docker compose -f stacks/authelia/docker-compose.yml up -d`.
4. `curl -ksI https://auth.lan/api/health -o /dev/null -w '%{http_code}\n'` → `200`.
5. Probar login + TOTP con un usuario.

Si lo que se quiere es **rotar** los secretos (sospecha de filtración):

```bash
# Regenerar todos los secretos (los TOTP almacenados se invalidan al cambiar
# storage_encryption_key; obliga a re-registrar a todos los usuarios).
for f in jwt_secret session_secret redis_password; do
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64 | \
        sudo tee /mnt/hd2t/apps/authelia/secrets/$f >/dev/null
done

# Si se rota también storage_encryption_key, exportar e importar los TOTP
# antes y después con `authelia storage user totp export/import`.
docker compose -f stacks/authelia/docker-compose.yml restart
```

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `auth.lan` da `NET::ERR_CERT_AUTHORITY_INVALID` | El cliente no tiene la CA interna instalada. | `04-red/04-caddy.md` → "Instalar el root CA en los clientes". |
| Login en el portal funciona pero `pihole.lan` sigue redirigiendo a `auth.lan` infinitamente | `session.cookies[0].domain` no coincide con el padre del servicio (p. ej. `auth.lan` con domain `lan` y `pihole.local`). | Confirmar que **todos** los servicios cuelgan de `${DOMAIN_LAN}`. La cookie se emite en el dominio padre y sin ese padre común no hay SSO. |
| Tras login válido, Caddy responde 401 en el servicio | El bloque del drop-in tiene `import authelia_two_factor` pero el `access_control.rules` no asocia ese subdominio a una política. | Authelia con `default_policy: deny` rechaza dominios no listados; añadir el subdominio a `access_control.rules`. |
| Authelia no arranca: `panic: open /secrets/jwt_secret: permission denied` | Permisos de los ficheros de secrets demasiado restrictivos para el UID interno del contenedor. | `sudo chmod 0640 /mnt/hd2t/apps/authelia/secrets/*` y `chown homelab:homelab`. El UID interno de Authelia (`authelia`, 1000 por defecto en la imagen) coincide con el del operador. |
| Authelia loguea `couldn't decrypt totp secret`: usuarios sin TOTP funcional | La `storage_encryption_key` actual no coincide con la usada para cifrar los TOTP guardados. | Si fue rotación intencionada, re-registrar TOTP. Si fue accidental (restore parcial), restaurar el secret original desde Borg. |
| Redis no arranca: `WRONGPASS invalid username-password pair or user is disabled` | Cambió `redis_password` pero el AOF antiguo tiene comandos `AUTH` con la vieja, o Authelia lee la nueva password de `_FILE` y Redis tiene otra. | Asegurar que `secrets/redis_password` y `command: redis-server --requirepass ...` leen el **mismo** fichero. Tras rotación: `docker compose down && docker compose up -d`. |
| TOTP rechazado siempre tras corte eléctrico | Reloj del host desincronizado: TOTP exige reloj con < 30 s de deriva. | `sudo systemctl status systemd-timesyncd` (o `chronyd`). Resincronizar; reintentar. |
| `forward_auth` falla con 502 desde Caddy | Authelia o Redis caídos, o Caddy no comparte la red `homelab` (raro tras 04-caddy.md). | `docker network inspect homelab` debe listar `caddy`, `authelia`, `authelia-redis`. `docker logs authelia` muestra si arranca correctamente. |
| Tras editar `users_database.yml`, Authelia no toma el cambio | `watch: true` solo detecta cambios al fichero **mismo**, no al directorio. Al editar in-place con algunos editores (vim con `:set backupcopy=no`) el inode cambia. | `docker compose restart authelia` como red de seguridad; o configurar el editor para sobreescribir en lugar de renombrar. |
| Logs llenos de `authentication failed, user does not exist` | Bot/IoT escaneando el portal con usernames aleatorios. | Verificar que `regulation` está activa (3 intentos / 2 min → ban 5 min); `02-fail2ban.md` añadirá una jail al log de Authelia con bans más largos a nivel de host. |
| El portal carga en blanco / se cuelga en el spinner | Bloqueador de scripts en el navegador (uBlock Origin con regla agresiva, Brave Shield) bloqueando scripts de un dominio "no público". | Whitelist `auth.lan` en el bloqueador. |
| Servicios con `policy: bypass` (Jellyfin) muestran loop de redirecciones | El drop-in del servicio incluyó `import authelia_*` por error. | Quitar el `import` en el drop-in del servicio en `bypass`; recargar Caddy. |

---

## Decisiones que **no** se toman en este documento

- **OIDC / OAuth2 como Identity Provider**: Authelia 4.38+ soporta el rol IdP para servicios OIDC-aware (Nextcloud, Grafana, Portainer Business, Paperless-ngx). En este homelab la mayoría de servicios entienden `forward_auth` o trusted headers, así que OIDC es una capa que no resuelve un problema actual; es reabrible si en algún momento se quiere "Login con homelab" en un servicio externo que solo acepte OIDC.
- **WebAuthn / FIDO2 (llaves físicas Yubikey)**: `webauthn.disable: true` por defecto. Se reabre cuando el operador tenga una llave física dedicada y un plan de respaldo (segunda llave en otra ubicación).
- **Notifier SMTP** (envío de emails reales para reset de password): a la espera de Fase 11 (`mailrise` o relay externo). Hoy `notifier.filesystem` cubre lo justo.
- **LDAP backend**: no hay LDAP interno; montar uno solo para Authelia es coste sin valor para 1–3 cuentas humanas.
- **Postgres / MariaDB para storage**: el homelab no necesita HA de Authelia; SQLite local con backup Borg es la combinación más simple y robusta.
- **Política RBAC con `groups`**: hoy todos los usuarios reales están en `admins` y la `access_control` se decide por dominio, no por grupo. Si llegan usuarios con menos privilegios (familiares con acceso solo a Jellyfin/Nextcloud), se reabren las reglas por `subject: 'group:guests'` y se separa.
- **SSO en el tailnet**: el bloque `pi.${TAILNET_DOMAIN}` de Caddy usa path-routing, incompatible con la cookie por dominio padre que requiere el SSO. En tailnet cada servicio mantiene su auth nativa. Reabrible si en el futuro se cambia tailnet a subdominio-routing (`*.pi.tailnet.ts.net`), donde el SSO funcionaría idéntico al modelo LAN.
- **Rate-limit a nivel Caddy** delante del portal (además del `regulation` interno de Authelia y del `fail2ban` futuro): se evalúa solo si aparece tráfico patológico real. Se documenta como nota.
- **Métricas Prometheus** del Authelia: la imagen oficial expone `/api/health` pero no `/metrics` salvo build con `pkg/metrics`; cuando Fase 6 (monitorización) cierre se decide si se despliega un exporter sidecar.

---

## Verificación Final

Antes de pasar a `02-fail2ban.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/authelia/docker-compose.yml ps` | `authelia ... Up (healthy)`, `authelia-redis ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect authelia --format '{{.Config.Image}}'` | `authelia/authelia:4.38` |
| Conectado a `homelab` | `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` | incluye `authelia`, `authelia-redis`, `caddy` |
| Sin puertos publicados al host | `docker port authelia` | salida vacía |
| `auth.lan` resuelve al IP de la Pi | `dig +short auth.lan @192.168.1.2` | `192.168.1.10` |
| Caddy sirve `auth.lan` con cert de la CA interna | `echo \| openssl s_client -connect auth.lan:443 -servername auth.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| Health endpoint responde | `curl -ksI https://auth.lan/api/health -o /dev/null -w '%{http_code}\n'` | `200` |
| Configuración válida | `docker exec authelia authelia validate-config --config /config/configuration.yml` | `Configuration parsed and loaded successfully without errors.` |
| Storage SQLite creada | `ls /mnt/hd2t/apps/authelia/data/db.sqlite3` | fichero presente |
| Secretos con permisos correctos | `ls -l /mnt/hd2t/apps/authelia/secrets/` | cuatro ficheros `0600`, `homelab:homelab` |
| Login interactivo en `https://auth.lan/` | navegador con CA instalada | portal carga, login con TOTP funcional |
| Pi-hole protegido por SSO | navegador en sesión cerrada → `https://pihole.lan/` | redirige a `auth.lan`, tras login vuelve a Pi-hole |
| `users_database.yml` recargable en caliente | editar y verificar `docker logs authelia \| grep reloaded` | mensaje `reloaded` en logs |
| Notifier filesystem operativo | tras un reset de password de prueba: `tail -1 /mnt/hd2t/apps/authelia/data/notifications/notification.txt` | última línea con `Subject: ...` |
| Regulation activa | 4 logins fallidos seguidos | el 4º responde "user is banned" durante 5 min |
| Persistencia tras reboot | `sudo reboot`; tras reconectar: `docker ps --filter name=authelia` | `Up ... (healthy)` sin acción manual |
| Stack en git (sin secretos) | `git status; git ls-files stacks/authelia` | `docker-compose.yml`, `configuration.yml`, `users_database.yml.example`, `.env.example`, `01-authelia.caddy` (en `stacks/caddy/conf.d/`) tracked; `users_database.yml` y `secrets/*` ignorados |

Cumplido el último punto, el homelab tiene SSO + 2FA opt-in para servicios LAN, política deny-by-default que **obliga** a una decisión explícita por servicio, y el patrón "una línea de `import authelia_*` en el drop-in de Caddy" listo para Fases 6–11. La siguiente puerta es **endurecer la respuesta a fuerza bruta**: `fail2ban` en `02-fail2ban.md` añadirá jails específicas que vigilan el log de Authelia, además del log de SSH y de los logs futuros de Nextcloud y Vaultwarden.

---

## Referencias

- [Documento siguiente: `docs/04-seguridad/02-fail2ban.md`](./02-fail2ban.md)
- [Documento relacionado: `docs/03-red/04-caddy.md`](../03-red/04-caddy.md)
- [Documento relacionado: `docs/03-red/02-pihole.md`](../03-red/02-pihole.md)
- [Documento relacionado: `docs/01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md)
- [Documento relacionado: `docs/02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)
- [Authelia — Documentación oficial](https://www.authelia.com/)
- [Authelia — Configuration reference](https://www.authelia.com/configuration/prologue/introduction/)
- [Authelia — Forward authentication (Caddy)](https://www.authelia.com/integration/proxies/caddy/)
- [Authelia — Access Control](https://www.authelia.com/configuration/security/access-control/)
- [Authelia — Argon2 password hashing](https://www.authelia.com/reference/guides/passwords/)
- [Authelia — Imagen Docker oficial](https://hub.docker.com/r/authelia/authelia)
- [Caddy — `forward_auth` directive](https://caddyserver.com/docs/caddyfile/directives/forward_auth)
- [Redis — Imagen Docker oficial](https://hub.docker.com/_/redis)
- [RFC 6238 — TOTP: Time-Based One-Time Password Algorithm](https://datatracker.ietf.org/doc/html/rfc6238)
