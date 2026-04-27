# Authelia (SSO + 2FA con `forward_auth` en Caddy)

## Descripción

Despliegue de **Authelia** como **portal de autenticación SSO + 2FA** del homelab. Authelia se sitúa **detrás de Caddy** y **delante de cualquier servicio que se quiera proteger**: Caddy intercepta la petición entrante, hace una sub-consulta interna (`forward_auth`) a Authelia, y sólo pasa al _backend_ si Authelia responde `200`. En caso contrario, el navegador se redirige al portal `https://auth.lan/`, donde el operador completa usuario+contraseña y, en una segunda pantalla, el _factor_ TOTP. Una vez autenticado, una _cookie_ con dominio `lan` permite que el siguiente servicio (Portainer, Nextcloud, Vaultwarden, …) se acceda **sin volver a pedir credenciales**: eso es el _Single Sign-On_.

Este documento **estrena el _stack_ `seguridad`** (`~/homelab/seguridad/`) descrito en `docs/02-docker/02-estructura-compose.md`. Junto a Authelia se despliega un **Redis** (sesiones) que vive en una red Docker privada del propio _stack_ (`seguridad-internal`); Authelia se conecta también a la red compartida `homelab` para que Caddy la alcance por nombre (`authelia:9091`). Se rellena el _snippet_ `caddy/snippets/authelia.caddy` que `docs/03-red/04-caddy.md` dejó vacío como _placeholder_, se añade un bloque `auth.lan` al `Caddyfile` y se documenta cómo proteger un servicio existente (Portainer) con una sola línea.

> **Alcance**: este documento despliega Authelia con _backend_ de autenticación **basado en fichero** (`users_database.yml`), almacenamiento **SQLite** local y _notifier_ **filesystem**. **No** integra con un servidor SMTP (las notificaciones de "reset de contraseña" se escriben a un fichero local; la transición a SMTP se documenta como sección separada al final). **No** integra con LDAP. **No** activa el _OpenID Connect Provider_ de Authelia (la funcionalidad OIDC para clientes como Nextcloud o Grafana se documentará caso por caso cuando llegue su fase). Sí activa **TOTP de fábrica** (Aegis, Google Authenticator, 1Password) y deja el camino preparado para WebAuthn (llaves físicas tipo YubiKey).

> **Recordatorio de red**: Authelia **no se publica al host**. Caddy la alcanza por DNS interno de Docker (`authelia:9091` dentro de la red `homelab`). El operador la usa por `https://auth.lan/`, que Pi-hole ya resuelve a `192.168.1.3` (wildcard de `02-homelab-local.conf`, `docs/03-red/02-pihole.md`) y Caddy demultiplexa por SNI. La _cookie_ de sesión vive en el dominio `lan` para que el SSO funcione contra cualquier `<servicio>.lan` sin más configuración.

---

## Requisitos previos

- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, el _snippet_ `~/homelab/red/caddy/snippets/authelia.caddy` existe **vacío** (placeholder), `import /etc/caddy/snippets/*.caddy` está activo en el `Caddyfile`. La CA local ya está firmando `*.lan`.
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `auth.lan` — el wildcard ya lo cubre.
- `docs/03-red/03-unbound.md` completado: Unbound recursivo en `192.168.1.4#5335`. Authelia no le habla directamente, pero su contenedor depende del DNS interno de Docker y, transitivamente, de que la cadena DNS del host esté sana.
- `docs/02-docker/02-estructura-compose.md` completado: red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) externa creada, `~/homelab/.env` con `TZ`, `PUID`, `PGID` y `HOMELAB_DOMAIN=lan` rellenos, _Makefile_ con `make up STACK=<stack>` operativo. La tabla del documento ya reserva el _slot_ del _stack_ `seguridad` que aquí se materializa.
- `docs/02-docker/03-portainer.md` completado: Portainer accesible vía `https://portainer.lan/` por Caddy (se usará como caso de prueba al final de este documento para validar el flujo SSO).
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada y el _stack_ `infra` la respeta. Authelia será **opt-out** explícito (ver **Decisiones de diseño**).
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/authelia/config/` ya existe vacío `root:root 0750`. En este documento se crean además `/mnt/hd2t/services/authelia/{secrets,data}` con permisos restrictivos.
- Conectividad saliente para descargar las imágenes:
  ```bash
  docker pull --platform linux/arm64 authelia/authelia:4.38.16 >/dev/null && \
  docker pull --platform linux/arm64 redis:7.4.1-alpine            >/dev/null && \
  echo OK
  ```
- Que el host **no** tenga ya un servicio escuchando en `:9091` ni un `redis` previo; este _stack_ no publica puertos (no hay colisión posible), pero conviene confirmar que el primer arranque no choca con nada residual:
  ```bash
  docker ps --format '{{.Names}} {{.Ports}}' | grep -E 'authelia|redis' || echo OK
  ```

---

## Decisiones de diseño

### Por qué Authelia (y no Authentik / Keycloak / Vouch / oauth2-proxy)

El homelab necesita **un solo punto de autenticación** que se sitúe entre el _reverse proxy_ y los servicios, soporte 2FA, sea ligero en una Pi 5 y se configure por fichero versionable. Cuatro candidatos descartados y por qué:

| Candidato         | Por qué se descarta                                                                                                                                                                            |
|-------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Authentik**     | Funcionalidad equivalente o superior, pero la configuración vive en su BD PostgreSQL y se administra **sólo por UI**. Backups, diffs y auditoría de cambios cuestan más. Consume ~600 MB RAM en idle (vs ~100 MB de Authelia) — relevante en una Pi de 8 GB. |
| **Keycloak**      | Solución _enterprise_ de Red Hat, JVM, ~1 GB RAM en idle. Innecesario para un homelab personal con 1–3 usuarios.                                                                                |
| **Vouch-Proxy**   | Sólo proxy de OAuth2 hacia un IdP externo (Google, GitHub…). Requiere depender de un proveedor externo para el _login_; eso choca con el principio "homelab debe poder operar sin internet".    |
| **oauth2-proxy**  | Mismo caso que Vouch: es un _delegado_, no un IdP. Útil si ya tienes un Authentik o Keycloak detrás, pero no como pieza única.                                                                  |

Authelia gana por:

- **Configuración 100 % declarativa por YAML**: `configuration.yml` se versiona en git, los _diffs_ son legibles, los cambios se aplican con `docker exec authelia kill -HUP 1` (recarga sin _downtime_).
- **Backend de autenticación por fichero** (`users_database.yml`): no necesita LDAP. Para 1–3 usuarios del homelab es lo más simple posible.
- **Footprint pequeño**: ~80–120 MB de RAM en idle, binario Go _native_ ARM64.
- **`forward_auth` nativo**: Caddy 2 lo soporta como directiva de primera clase. La integración es **una sola línea por servicio protegido**.
- **TOTP + WebAuthn de fábrica** sin _plugins_, con flujo de _enrollment_ vía web.

### Stack `seguridad` se estrena con este documento

`docs/02-docker/02-estructura-compose.md` reservó el _slot_ `~/homelab/seguridad/` para Authelia y `Fail2ban` (este último cuando se centralice en contenedor, `docs/04-seguridad/02-fail2ban.md`). Aquí se crea el directorio, su `docker-compose.yml`, su `.env`/`.env.example` y se enchufa al _Makefile_ vía la convención existente (`make up STACK=seguridad`, ver `docs/02-docker/02-estructura-compose.md`, sección _Makefile de operación_).

### Imagen y _tag_

- **`authelia/authelia:4.38.16`** — Authelia **4.38**, multi-arch con `linux/arm64`. La imagen oficial publicada por el equipo de Authelia. Pinneada a versión completa (convención del homelab: nada de `:latest`, nada de `:4` o `:4.38`).
- **`redis:7.4.1-alpine`** — Redis 7.4 LTS, multi-arch ARM64, variante Alpine (~30 MB de imagen). _Tag_ completo, igual criterio.
- Ambos en **opt-out** de Watchtower (`com.centurylinklabs.watchtower.enable: "false"`):
  - **Authelia**: la transición entre _minor versions_ (4.37 → 4.38) ha cambiado el _schema_ del `configuration.yml` en el pasado (estructuras renombradas, claves promovidas o trasladadas). Aplicar un _bump_ a ciegas puede dejar el contenedor en _CrashLoopBackOff_ con `failed to validate configuration`. Las actualizaciones se hacen a mano leyendo el _migration guide_ de la _release_.
  - **Redis**: contiene **estado de sesión** (cookies activas). Un upgrade que falle en migrar el formato de _persistence_ deja al operador desconectado de todos los servicios SSO a la vez. Redis **dentro de un _major_** (7.x → 7.x) es estable, pero conviene leer las _release notes_ por si hay un cambio en `redis.conf` o en el formato RDB/AOF.

### Backend de autenticación: file (`users_database.yml`), no LDAP

Autenticación por fichero plano YAML con contraseñas hasheadas (Argon2id). Razones:

- **No hay un directorio LDAP** en el homelab y montar uno (LLDAP, OpenLDAP, Lemonlas, …) sólo para Authelia añade un servicio crítico extra que también necesita estar disponible para que el SSO funcione.
- **Pocos usuarios**: 1 operador + 0–2 invitados ocasionales. La gestión "manual" en YAML es trivial.
- **Migración futura**: si en algún momento se monta LLDAP (`docs/04-seguridad/`, sección "ampliaciones"), Authelia soporta _switch_ del backend cambiando 6 líneas en el `configuration.yml` y migrando los hashes (Argon2id es portable). El usuario y los hashes ya están firmados por el _password reset secret_ (tampoco hay que invalidar cookies activas).

### Almacenamiento: SQLite, no PostgreSQL

Authelia guarda en su _storage backend_ los _registros TOTP_ (semillas), las claves WebAuthn, el historial de _login_ (regulación) y el estado de _password reset_. Soporta SQLite, MySQL/MariaDB y PostgreSQL.

- **SQLite** elegido: `local.path: /config/db.sqlite3`. Un fichero, sin servicio extra, sin _depends_on_, **idéntico** rendimiento para 1–3 usuarios.
- Si en el futuro se quiere migrar a PostgreSQL (compartido con Nextcloud, por ejemplo), el comando `docker exec authelia authelia storage migrate` deja todo el _schema_ en la nueva BD; los hashes y semillas son portables.

### Sesiones: Redis, no in-memory

Authelia 4.x permite guardar las sesiones en memoria del propio proceso. Aquí se descarta:

- **Reinicio del contenedor = todo el mundo deslogueado**. Cualquier `docker compose pull && up -d` (o un `kill -HUP` mal aplicado) implica que todos los _peers_ vuelvan a 2FA. Inaceptable.
- **Redis con persistencia AOF** sobrevive a reinicios del contenedor y a reboots de la Pi. Una sesión activa el viernes sigue activa el lunes.
- **Coste**: ~10 MB de RAM y ~5 MB de disco por la AOF. Despreciable.

Redis **se queda en una red privada del _stack_** (`seguridad-internal`, _bridge_ creada por Compose). Authelia es el único que lo alcanza. **No** se publica al host ni se conecta a `homelab`.

### Notifier: filesystem (transición a SMTP documentada)

Authelia genera notificaciones para tres eventos:

1. **Identidad inicial** — al añadir un usuario al `users_database.yml` con `disabled: true`, Authelia emite un _email_ con un enlace de un solo uso para activar el TOTP la primera vez.
2. **Reset de contraseña** — el flujo "He olvidado mi contraseña" emite un _email_ con un token.
3. **Cambio de método 2FA** — al añadir/eliminar una llave WebAuthn, se notifica al usuario.

En el primer despliegue del homelab **no hay servicio SMTP montado todavía** (Vaultwarden, Mealie y otros servicios podrán necesitarlo en su fase). Se elige el _notifier_ **filesystem**: las notificaciones se escriben a `/config/notifications.txt`, que persiste en `/mnt/hd2t/services/authelia/config/`. El operador las lee con `tail -f`. Para 1 usuario, es suficiente.

> **Transición a SMTP** está documentada al final del doc (sección **Migrar a notifier SMTP**). Cuando se monte un relay SMTP local (Postfix _null client_, MSMTP relay, o un _SMTP-as-a-service_ tipo Migadu/Mailgun), basta sustituir el bloque `notifier.filesystem` por `notifier.smtp` y reiniciar Authelia.

### Cookies con dominio `lan`: SSO transparente entre todos los `*.lan`

La pieza clave del SSO. La _cookie de sesión_ que Authelia entrega al navegador tras un _login_ exitoso lleva:

```
Set-Cookie: authelia_session=<opaque>; Domain=lan; Path=/; Secure; HttpOnly; SameSite=Lax
```

Con `Domain=lan`, **todos** los subdominios del TLD `lan` reciben la cookie automáticamente: `auth.lan` la entrega, `portainer.lan` la lee, `nextcloud.lan` la lee, etc. Authelia, al recibir el `forward_auth` desde Caddy, valida la cookie contra Redis y devuelve `200` (con cabeceras `Remote-User`, `Remote-Groups`…) o `401`/`302` al portal.

Consecuencia: **una vez logueado en cualquier `*.lan`, el operador navega a cualquier otro `*.lan` sin re-autenticarse**. Es el comportamiento esperable de SSO.

> **`Domain=lan` requiere que TODOS los servicios estén bajo `*.lan`** (no `192.168.1.x`). Esto ya es así por convención del homelab — Caddy nunca se accede por IP, sólo por nombre. Si un cliente entra por IP, la cookie no aplica y el SSO no funciona.

> **Por qué `SameSite=Lax` y no `Strict`**: `Strict` rompe el flujo del primer _redirect_ (de `https://portainer.lan/` a `https://auth.lan/?rd=...`): el navegador no envía la cookie en una navegación cross-site iniciada por _redirect_ y Authelia ve al usuario como anónimo en bucle. `Lax` es el _sweet spot_ y es lo que recomienda la propia documentación de Authelia para escenarios de _forward_auth_.

### `forward_auth` (Caddy nativo) frente a `auth_request` OIDC

Caddy 2 implementa `forward_auth` como directiva nativa: en cada petición entrante a un bloque protegido, Caddy hace una sub-petición HTTP a Authelia (`/api/verify`) con las cabeceras originales y, según la respuesta, deja pasar o redirige al portal. Es un patrón **simple**, **rápido** (la sub-petición es local y Authelia responde en <5 ms) y **explícito** (la directiva está en cada bloque del `Caddyfile` que se quiere proteger; no hay magia _per-host_).

El alternativo sería usar el _OpenID Connect Provider_ de Authelia y configurar cada servicio como **cliente OIDC**. Eso es lo correcto cuando un servicio soporta OIDC nativo y se quiere _claims_ específicos (Nextcloud, Grafana, Outline). Para servicios que **no** hablan OIDC (Portainer CE, Pi-hole, Sonarr/Radarr, Stash, Audiobookshelf, …), `forward_auth` es la única vía y es la que se cablea aquí. La activación de OIDC para servicios que sí lo soportan se documenta caso por caso en sus respectivas fases.

### Almacenamiento

| Ruta en el host                                           | Contenido                                                                | Versionable | Backup |
|-----------------------------------------------------------|--------------------------------------------------------------------------|-------------|--------|
| `~/homelab/seguridad/docker-compose.yml`                  | Definición del _stack_                                                   | git         | git    |
| `~/homelab/seguridad/configuration.yml`                   | Configuración principal de Authelia (sin secretos — referencias a `_FILE`) | git       | git    |
| `~/homelab/seguridad/.env`                                | Imágenes pinneadas, variables del _stack_ (sin secretos)                 | **NO** (`.gitignore`) | git aparte (nota local) |
| `~/homelab/seguridad/.env.example`                        | Plantilla con nombres de variables, sin valores                          | git         | git    |
| `/mnt/hd2t/services/authelia/config/users_database.yml`   | Usuarios + hashes Argon2id (sensibles)                                   | **NO** versionable | **Sí** (Borgmatic) |
| `/mnt/hd2t/services/authelia/config/db.sqlite3`           | TOTP secrets, WebAuthn keys, regulación, password resets                 | **NO**      | **Sí** (Borgmatic) |
| `/mnt/hd2t/services/authelia/config/notifications.txt`    | Cola de notificaciones (mientras notifier sea `filesystem`)              | **NO**      | No (transitorio) |
| `/mnt/hd2t/services/authelia/secrets/jwt-secret`          | Secreto para firma de JWT (`identity_validation.reset_password`)         | **NO**      | **Sí** (Borgmatic) |
| `/mnt/hd2t/services/authelia/secrets/session-secret`      | Secreto para firma de cookies de sesión                                  | **NO**      | **Sí** (Borgmatic) |
| `/mnt/hd2t/services/authelia/secrets/storage-encryption`  | Clave AES-256 para cifrar TOTP secrets en SQLite                         | **NO**      | **Sí** (Borgmatic) |
| `/mnt/hd2t/services/redis/data/`                          | AOF de Redis (sesiones activas)                                          | **NO**      | Sí (Borgmatic) — pérdida = re-login global, no es crítico |

> **Nunca _commitear_ `users_database.yml` ni el directorio `secrets/`**. El `.gitignore` del _stack_ los excluye explícitamente.

> **Regenerar los secretos** invalida todas las sesiones activas (cookies firmadas con la _session secret_ vieja) y todos los TOTP enrolados (semillas cifradas con la _storage encryption key_ vieja). Es una operación destructiva — **no se hace** salvo compromiso confirmado.

---

## Estructura del _stack_ `seguridad` tras este documento

```
~/homelab/seguridad/
├── docker-compose.yml        # ← nuevo
├── .env                      # ← nuevo (NO versionado)
├── .env.example              # ← nuevo (versionado)
├── configuration.yml         # ← nuevo (versionado, sin secretos)
└── .gitignore                # ← nuevo (excluye .env)
```

Y en los discos externos:

```
/mnt/hd2t/services/authelia/
├── config/                   # creado en docs/01-sistema/04-estructura-directorios.md
│   ├── users_database.yml    # ← se crea en este doc
│   ├── db.sqlite3            # ← lo crea Authelia al primer arranque
│   └── notifications.txt     # ← lo crea Authelia al primer arranque
├── data/                     # ← se crea en este doc (vacío inicialmente)
└── secrets/                  # ← se crea en este doc
    ├── jwt-secret
    ├── session-secret
    └── storage-encryption

/mnt/hd2t/services/redis/
└── data/                     # ← se crea en este doc (AOF de Redis)
```

Crear los directorios:

```bash
# Estado de Authelia
sudo mkdir -p /mnt/hd2t/services/authelia/{secrets,data}
sudo chmod 0700 /mnt/hd2t/services/authelia/secrets
sudo chmod 0750 /mnt/hd2t/services/authelia/data

# Ownership: Authelia corre como UID/GID 1000:1000 dentro del contenedor
# (no toma PUID/PGID — es imagen oficial, no LinuxServer.io). Damos
# ownership coincidente al usuario 'homelab' (UID 1000) para que tanto
# el operador desde SSH como el contenedor puedan leer.
sudo chown -R 1000:1000 /mnt/hd2t/services/authelia

# Estado de Redis: la imagen oficial corre como UID/GID 999:1000.
# El directorio se crea con ownership 999:1000 explícito.
sudo mkdir -p /mnt/hd2t/services/redis/data
sudo chown -R 999:1000 /mnt/hd2t/services/redis
sudo chmod 0750 /mnt/hd2t/services/redis/data

# Subdirectorio del propio stack en HOME
mkdir -p ~/homelab/seguridad
chmod 0750 ~/homelab/seguridad
```

> **UID 999 de Redis**: la imagen oficial `redis:7-alpine` declara `USER redis` y el `redis` del Alpine es UID 999. Coincide con el `redis` de Debian/Ubuntu, por lo que el _bind mount_ es portable.

---

## Variables de entorno

Crear `~/homelab/seguridad/.env.example` (versionado en git, sin valores reales):

```bash
# --- Imágenes pinneadas -----------------------------------------------------
AUTHELIA_IMAGE_TAG=4.38.16
REDIS_IMAGE_TAG=7.4.1-alpine

# --- Authelia ---------------------------------------------------------------
# URL pública del portal — usado por Authelia para construir redirects
# y por las cookies para fijar el dominio. Coincide con el bloque del
# Caddyfile que se añade en este mismo documento.
AUTHELIA_PORTAL_URL=https://auth.lan

# Dominio en el que vive la cookie de sesión. Debe ser el TLD interno
# que Pi-hole resuelve (HOMELAB_DOMAIN, definido en ~/homelab/.env).
# 'lan' = todas las cookies aplican a *.lan. Coincide con HOMELAB_DOMAIN.
AUTHELIA_SESSION_DOMAIN=lan

# URL a la que Authelia redirige tras un login exitoso si la petición
# no llevaba un 'redirect' explícito. Apunta al dashboard del homelab
# (Homepage cuando exista, docs/12-dashboards/01-homepage.md). Mientras
# tanto, devuelve al usuario al propio portal con un mensaje "logged in".
AUTHELIA_DEFAULT_REDIRECTION_URL=https://auth.lan
```

Copiar a `.env` y ajustar (sin secretos — los secretos van por `_FILE`, no por env directa):

```bash
cp ~/homelab/seguridad/.env.example ~/homelab/seguridad/.env
chmod 0600 ~/homelab/seguridad/.env
```

Por defecto los valores de la plantilla son los correctos para el homelab. **No hay nada que rellenar a mano** salvo que el operador haya cambiado `HOMELAB_DOMAIN` o el _hostname_ del portal.

`.gitignore` del _stack_:

```bash
cat > ~/homelab/seguridad/.gitignore <<'EOF'
# Secretos y datos locales del operador
.env
EOF
```

---

## Generación de los tres secretos

Authelia necesita tres secretos distintos:

| Secreto                        | Uso                                                                           | Tamaño mínimo |
|--------------------------------|-------------------------------------------------------------------------------|---------------|
| `jwt-secret`                   | Firmar los JWT del flujo "reset de contraseña" e "identity verification"      | 64 chars      |
| `session-secret`               | Firmar las cookies de sesión que entrega el portal                            | 64 chars      |
| `storage-encryption`           | Cifrar las semillas TOTP y las claves WebAuthn dentro de `db.sqlite3`         | 64 chars      |

Generarlos con `openssl` (alfanuméricos URL-safe, sin caracteres especiales que puedan causar problemas con el _parser_ YAML):

```bash
umask 0077
openssl rand -base64 64 | tr -d '\n=+/' | head -c 64 | sudo tee /mnt/hd2t/services/authelia/secrets/jwt-secret > /dev/null
openssl rand -base64 64 | tr -d '\n=+/' | head -c 64 | sudo tee /mnt/hd2t/services/authelia/secrets/session-secret > /dev/null
openssl rand -base64 64 | tr -d '\n=+/' | head -c 64 | sudo tee /mnt/hd2t/services/authelia/secrets/storage-encryption > /dev/null

# Cada fichero, mode 0400, propiedad del UID con el que corre Authelia (1000)
sudo chmod 0400 /mnt/hd2t/services/authelia/secrets/{jwt-secret,session-secret,storage-encryption}
sudo chown 1000:1000 /mnt/hd2t/services/authelia/secrets/{jwt-secret,session-secret,storage-encryption}
```

> **`umask 0077`**: por si `tee` con `sudo` heredase un umask laxo. Defensa en profundidad.

> **No uses `tr -d '\n'` solo**: la salida de `openssl rand -base64` puede contener `+`, `/`, `=` que son válidos en Base64 estándar pero rompen el _parsing_ de Authelia en algunas combinaciones (lo trata como YAML). El `tr` los descarta y `head -c 64` recorta a la longitud exacta.

> **Verificar el tamaño**:
> ```bash
> wc -c /mnt/hd2t/services/authelia/secrets/*
> # 64 jwt-secret
> # 64 session-secret
> # 64 storage-encryption
> ```

---

## `~/homelab/seguridad/configuration.yml`

Configuración principal de Authelia 4.38.x. **No contiene secretos**: los tres secretos los inyecta el _runtime_ vía variables de entorno con sufijo `_FILE` (mecanismo nativo de Authelia, equivalente al `_FILE` de las imágenes oficiales de Postgres/MariaDB).

```yaml
---
# ============================================================================
# Authelia — configuración principal
# Documentación: docs/04-seguridad/01-authelia.md
# Schema: Authelia 4.38.x
# Esta config la consume authelia/authelia:4.38.16 montada read-only.
# ============================================================================

# Tema oscuro por defecto (concuerda con el resto de UIs del homelab).
theme: dark

# ---------------------------------------------------------------------------
# Servidor HTTP — escucha en :9091, sin TLS interno (Caddy hace de terminador)
# ---------------------------------------------------------------------------
server:
  address: 'tcp://0.0.0.0:9091/'
  buffers:
    read: 4096
    write: 4096

# ---------------------------------------------------------------------------
# Logs — JSON estructurado a stdout (Dozzle / Loki en fase posterior)
# ---------------------------------------------------------------------------
log:
  level: info
  format: json

# ---------------------------------------------------------------------------
# TOTP — emisor que aparece en Aegis / Google Authenticator / 1Password.
# 'issuer' es el nombre que se ve en la app del usuario.
# ---------------------------------------------------------------------------
totp:
  disable: false
  issuer: homelab.lan
  algorithm: sha1            # SHA1 = compatibilidad con TODAS las apps TOTP
  digits: 6
  period: 30
  skew: 1                    # ±30 s de tolerancia (estándar)

# ---------------------------------------------------------------------------
# WebAuthn — preparado pero no obligatorio. El usuario puede enrolar una
# YubiKey desde el portal una vez logueado.
# ---------------------------------------------------------------------------
webauthn:
  disable: false
  display_name: 'Homelab'
  attestation_conveyance_preference: indirect
  user_verification: preferred
  timeout: 60s

# ---------------------------------------------------------------------------
# Identity validation — secreto para JWT del flujo de reset de contraseña.
# El secreto se inyecta vía AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE.
# ---------------------------------------------------------------------------
identity_validation:
  reset_password:
    jwt_lifespan: 5m
    jwt_algorithm: HS256
    # jwt_secret: lo aporta el _FILE env var

# ---------------------------------------------------------------------------
# Authentication backend — fichero plano YAML, hashes Argon2id
# ---------------------------------------------------------------------------
authentication_backend:
  password_reset:
    disable: false
  refresh_interval: 5m
  file:
    path: /config/users_database.yml
    watch: true              # recarga el fichero al detectar cambios
    password:
      algorithm: argon2
      argon2:
        variant: argon2id
        iterations: 3
        memory: 65536        # 64 MB — Pi 5 lo encaja sin sudar
        parallelism: 4
        key_length: 32
        salt_length: 16

# ---------------------------------------------------------------------------
# Access control — política por defecto y reglas por dominio
# ---------------------------------------------------------------------------
access_control:
  default_policy: deny
  rules:
    # 1) El propio portal nunca exige autenticación previa (si no, bucle).
    - domain:
        - 'auth.lan'
      policy: bypass

    # 2) Servicios del homelab — exigir 1FA (usuario+contraseña).
    #    Los críticos suben a 2FA a continuación. Esto es el _default_
    #    para cualquier *.lan que aún no tenga regla específica.
    - domain:
        - '*.lan'
      policy: one_factor

    # 3) Servicios críticos — exigir 2FA (TOTP / WebAuthn) además de 1FA.
    #    Lista que crece conforme cada doc de fase confirme que su servicio
    #    debe protegerse con 2FA. Empezamos por Portainer (panel docker)
    #    y dejamos comentados los slots para servicios que llegan en fases
    #    posteriores; descomentar cuando aplique.
    - domain:
        - 'portainer.lan'
        # - 'vaultwarden.lan'      # docs/11-productividad/01-vaultwarden.md
        # - 'nextcloud.lan'        # docs/06-almacenamiento/01-nextcloud.md
        # - 'home-assistant.lan'   # docs/08-domotica/01-home-assistant.md
      policy: two_factor

# ---------------------------------------------------------------------------
# Sesión — Redis como backend, cookie con dominio 'lan' (SSO transparente)
# ---------------------------------------------------------------------------
session:
  # secret: lo aporta el _FILE env var
  cookies:
    - domain: 'lan'
      authelia_url: 'https://auth.lan'
      default_redirection_url: 'https://auth.lan'
      name: authelia_session
      same_site: lax
      expiration: 1h         # cookie de sesión válida 1 h sin actividad
      inactivity: 5m         # 5 min de inactividad => re-prompt
      remember_me: 1M        # 'remember me' opcional => 1 mes
  redis:
    host: redis              # nombre interno de Docker (red seguridad-internal)
    port: 6379
    database_index: 0
    maximum_active_connections: 8
    minimum_idle_connections: 0

# ---------------------------------------------------------------------------
# Regulation — anti-bruteforce: 3 fallos en 2 min => ban de 5 min
# ---------------------------------------------------------------------------
regulation:
  max_retries: 3
  find_time: 2m
  ban_time: 5m

# ---------------------------------------------------------------------------
# Storage — SQLite local. La encryption_key cifra las semillas TOTP en reposo.
# ---------------------------------------------------------------------------
storage:
  # encryption_key: lo aporta el _FILE env var
  local:
    path: /config/db.sqlite3

# ---------------------------------------------------------------------------
# Notifier — filesystem (transitorio; migrar a SMTP cuando exista relay).
# Sección 'Migrar a notifier SMTP' al final del documento.
# ---------------------------------------------------------------------------
notifier:
  filesystem:
    filename: /config/notifications.txt
```

Permisos:

```bash
chmod 0644 ~/homelab/seguridad/configuration.yml
```

> **Validación local antes de subir nada**:
> ```bash
> docker run --rm \
>   -v ~/homelab/seguridad/configuration.yml:/config/configuration.yml:ro \
>   authelia/authelia:4.38.16 \
>   authelia validate-config --config /config/configuration.yml
> ```
> Salida esperada: `Configuration parsed and loaded successfully without errors.` (Avisará de que `users_database.yml` no existe todavía — ignorable, se crea en el siguiente paso. Avisará de los `_FILE` no establecidos — ignorable también, se inyectan en runtime.)

---

## `users_database.yml` — primer usuario

Este fichero **no se versiona en git**: contiene hashes de contraseñas. Vive en `/mnt/hd2t/services/authelia/config/users_database.yml`.

### 1. Hashear la contraseña del operador

Authelia trae el subcomando `crypto hash generate argon2`:

```bash
docker run --rm -it authelia/authelia:4.38.16 \
  authelia crypto hash generate argon2 \
  --variant argon2id \
  --iterations 3 \
  --memory 65536 \
  --parallelism 4 \
  --key-size 32 \
  --salt-size 16
```

Pedirá la contraseña dos veces. Salida:

```
Digest: $argon2id$v=19$m=65536,t=3,p=4$<salt_b64>$<hash_b64>
```

Copiar la línea entera (desde `$argon2id$` hasta el final) — es lo que va dentro del campo `password` del YAML.

> **Mismos parámetros que el `configuration.yml`**: `iterations: 3`, `memory: 65536`, `parallelism: 4`. Si difieren, Authelia verifica igualmente porque Argon2 lleva los parámetros embebidos en el _digest_, pero el _refresh_interval_ no detecta el cambio sin reiniciar.

### 2. Crear `users_database.yml`

```bash
sudo tee /mnt/hd2t/services/authelia/config/users_database.yml > /dev/null <<'EOF'
---
# Usuarios del homelab. Hashes Argon2id generados con
# 'authelia crypto hash generate argon2'. Edita y reinicia o `kill -HUP`
# Authelia para recargar (watch: true en configuration.yml).
users:
  homelab:
    disabled: false
    displayname: "Homelab Operator"
    password: "$argon2id$v=19$m=65536,t=3,p=4$REEMPLAZAR$REEMPLAZAR"
    email: homelab@homelab.lan
    groups:
      - admins
      - users
EOF
```

Reemplazar el `password` con el _digest_ del paso anterior.

Permisos:

```bash
sudo chmod 0640 /mnt/hd2t/services/authelia/config/users_database.yml
sudo chown 1000:1000 /mnt/hd2t/services/authelia/config/users_database.yml
```

> **`email`** se usa internamente por Authelia para los _notifications_ (filesystem o SMTP). Como el _notifier_ es filesystem, la dirección no se entrega; basta con que sea una cadena válida.

> **`groups`**: por ahora `admins` y `users`. Authelia los pasa a Caddy como cabecera `Remote-Groups: admins,users` y cualquier servicio de _backend_ puede usarlos para aplicar autorización fina. Pi-hole, Portainer y similares ignoran esta cabecera; Nextcloud y Grafana podrán mapearla cuando se integren con OIDC.

---

## Activar el _snippet_ `authelia.caddy` y añadir el bloque `auth.lan`

### 1. Reemplazar el placeholder del _snippet_

`docs/03-red/04-caddy.md` dejó `~/homelab/red/caddy/snippets/authelia.caddy` vacío. Sustituirlo por:

```caddyfile
# Forward-auth a Authelia — middleware reutilizable.
# Documentación: docs/04-seguridad/01-authelia.md
#
# Cualquier bloque del Caddyfile que importe 'authelia' protegerá su
# servicio detrás del portal. Authelia decide 1FA / 2FA / bypass por
# las reglas de access_control de su configuration.yml.
#
# Uso desde un bloque de servicio:
#   import authelia
#   reverse_proxy <backend>:<port>
(authelia) {
    forward_auth authelia:9091 {
        uri /api/verify?rd=https://auth.lan/

        # Cabeceras que Authelia entrega al backend para que sepa quién
        # ha entrado. Pi-hole/Portainer las ignoran; Nextcloud/Grafana
        # las mapean a usuario/grupos en OIDC, pero aquí seguimos en
        # forward_auth — la cabecera se queda como X-headers que el
        # servicio puede leer.
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }
}
```

### 2. Añadir el bloque `auth.lan` al `Caddyfile`

Editar `~/homelab/red/Caddyfile` y añadir, antes del catch-all `*.lan` (para que tenga precedencia explícita):

```caddyfile
# ---------------------------------------------------------------------------
# Authelia — portal de autenticación
# El propio portal NO importa 'authelia' (sería bucle infinito).
# ---------------------------------------------------------------------------
auth.lan {
    tls internal
    import security-headers
    import logging

    reverse_proxy authelia:9091 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

### 3. Validar la sintaxis del `Caddyfile`

```bash
docker run --rm \
  -v ~/homelab/red/Caddyfile:/etc/caddy/Caddyfile:ro \
  -v ~/homelab/red/caddy/snippets:/etc/caddy/snippets:ro \
  caddy:2.8.4-alpine \
  caddy validate --config /etc/caddy/Caddyfile
# Valid configuration
```

> **No** recargar Caddy aún — Authelia todavía no está arrancada y el `reverse_proxy authelia:9091` se quejaría con `dial tcp: lookup authelia: no such host` durante 60 s mientras el _embedded DNS_ refresca. Recargar después de levantar el _stack_ `seguridad`.

---

## `~/homelab/seguridad/docker-compose.yml`

```yaml
---
# Stack: seguridad — Authelia (SSO + 2FA) + Redis (sesiones)
# Documentación: docs/04-seguridad/01-authelia.md

services:

  # ---------------------------------------------------------------------------
  # Redis — backend de sesiones de Authelia.
  # Sólo en la red privada del stack; no se expone al host ni a 'homelab'.
  # ---------------------------------------------------------------------------
  redis:
    image: redis:${REDIS_IMAGE_TAG}
    container_name: redis
    hostname: redis
    restart: unless-stopped
    # AOF activo (everysec) — sesiones sobreviven a reinicios. RDB desactivado
    # (no necesitamos snapshots: el AOF es suficiente y la pérdida de los
    # últimos 1 s de actividad es aceptable).
    command:
      - redis-server
      - --appendonly
      - "yes"
      - --appendfsync
      - everysec
      - --save
      - ""
      - --maxmemory
      - 64mb
      - --maxmemory-policy
      - allkeys-lru
    environment:
      TZ: ${TZ}
    volumes:
      - /mnt/hd2t/services/redis/data:/data
    networks:
      - seguridad-internal
    labels:
      homelab.stack: "seguridad"
      homelab.backup: "true"      # AOF en /mnt/hd2t/services/redis/data
      # Opt-out: el upgrade entre minor de Redis (7.4 -> 7.5) puede cambiar
      # el formato AOF y forzar un BGREWRITEAOF tras el reinicio. Manual.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      test: ["CMD", "redis-cli", "PING"]
      interval: 10s
      timeout: 3s
      retries: 5
      start_period: 5s

  # ---------------------------------------------------------------------------
  # Authelia — portal SSO + 2FA.
  # En 'homelab' (Caddy la alcanza por nombre) Y en 'seguridad-internal'
  # (alcanza a Redis).
  # ---------------------------------------------------------------------------
  authelia:
    image: authelia/authelia:${AUTHELIA_IMAGE_TAG}
    container_name: authelia
    hostname: authelia
    restart: unless-stopped
    # Imagen oficial; corre como UID 1000:1000 internamente.
    user: "1000:1000"
    environment:
      TZ: ${TZ}
      # Inyección de secretos por fichero (mecanismo nativo de Authelia).
      AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE: /run/secrets/jwt-secret
      AUTHELIA_SESSION_SECRET_FILE: /run/secrets/session-secret
      AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE: /run/secrets/storage-encryption
    volumes:
      # Configuración versionable, read-only. La ruta interna sigue la
      # convención de Authelia: /config/configuration.yml.
      - ./configuration.yml:/config/configuration.yml:ro
      # Estado persistente: users_database.yml + db.sqlite3 + notifications.txt
      - /mnt/hd2t/services/authelia/config:/config
      # Secretos como ficheros, read-only. El path /run/secrets es convención
      # ya usada por las imágenes oficiales que soportan _FILE env vars.
      - /mnt/hd2t/services/authelia/secrets:/run/secrets:ro
    networks:
      homelab:
        aliases:
          - authelia          # Caddy resuelve 'authelia:9091' por este alias
      seguridad-internal:
        # alcanza a 'redis' por nombre dentro de esta red
    labels:
      homelab.stack: "seguridad"
      homelab.backup: "true"      # /mnt/hd2t/services/authelia/{config,secrets}
      # Opt-out: cambios de schema en YAML entre minor versions. Manual.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      # Authelia expone /api/health (no protegido). Devuelve 200 si la
      # config está cargada, los secretos parseados y Redis alcanzable.
      test:
        - CMD
        - authelia
        - healthcheck
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      redis:
        condition: service_healthy

# ---------------------------------------------------------------------------
# Redes
# ---------------------------------------------------------------------------
networks:
  homelab:
    external: true               # creada en docs/02-docker/02-estructura-compose.md
  seguridad-internal:
    driver: bridge               # privada de este stack; Compose la gestiona
    # Sin 'name:' explícito => Compose la nombrará 'seguridad_seguridad-internal',
    # lo que es perfectamente OK porque sólo Authelia y Redis la usan.
```

Notas de diseño:

- **`user: "1000:1000"`**: sobreescribe el _USER_ por defecto de la imagen para que coincida con el ownership de `/mnt/hd2t/services/authelia/`. Sin esto, el primer arranque podría fallar al escribir `db.sqlite3`.
- **No hay `ports:`** en ninguno de los dos servicios. Authelia se alcanza por DNS interno desde Caddy (`authelia:9091`), nunca desde el host. Redis se alcanza sólo desde Authelia. Ningún puerto se publica.
- **`AUTHELIA_*_FILE`**: convención nativa de Authelia (no _Docker secrets_). Authelia lee `AUTHELIA_<KEY_PATH>_FILE` como "leer el secreto del path apuntado". El _path_ se resuelve dentro del contenedor; el _bind mount_ a `/run/secrets/` lo trae desde `/mnt/hd2t/services/authelia/secrets/`.
- **`depends_on: redis: condition: service_healthy`**: Authelia no arranca hasta que Redis responde a `PING`. Sin esto, Authelia logueaba `dial tcp redis:6379: connect: connection refused` durante los primeros 5 s y entraba en _bucle de retry_ del propio gestor de Redis (no es fatal, pero contamina logs).
- **Redis con `appendonly yes` y `save ""`**: AOF a 1 s, sin RDB. La AOF se reescribe en _background_ cuando alcanza el doble de su tamaño previo (`auto-aof-rewrite-percentage` es 100 por defecto), lo que mantiene `/mnt/hd2t/services/redis/data/appendonly.aof` por debajo de unos pocos MB en uso normal.
- **Watchtower opt-out** en ambos: razones explicadas en **Decisiones de diseño**.

---

## Despliegue

```bash
cd ~/homelab/seguridad
docker compose --env-file ../.env --env-file .env config | head -50    # validar sintaxis
docker compose --env-file ../.env --env-file .env up -d
```

O, equivalente, con el _Makefile_:

```bash
cd ~/homelab
make up STACK=seguridad
```

Verificar:

```bash
docker compose -f ~/homelab/seguridad/docker-compose.yml ps
# NAME       STATUS                   PORTS
# redis      Up X seconds (healthy)
# authelia   Up X seconds (healthy)
```

> El `(healthy)` de Authelia tarda ~30 s desde el arranque (el `start_period: 30s` da margen para que cargue config, valide secretos, abra SQLite y conecte con Redis).

Recargar Caddy ahora que `authelia` resuelve por DNS interno:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
# 'INF reload happened' en logs.
```

Verificar que el portal responde (sin login, sólo HTTP status):

```bash
curl -k --resolve auth.lan:443:192.168.1.3 https://auth.lan/ -I
# HTTP/2 200 (la SPA de Authelia)
```

Y que `forward_auth` redirige correctamente (Portainer aún no está protegido — eso es el siguiente paso):

```bash
curl -k --resolve portainer.lan:443:192.168.1.3 https://portainer.lan/ -I
# HTTP/2 200 — todavía pasa directo, sin SSO. Lo cambiamos en el siguiente paso.
```

---

## Proteger el primer servicio: Portainer

Editar `~/homelab/red/Caddyfile` y añadir `import authelia` al bloque `portainer.lan`:

```diff
 portainer.lan {
     tls internal
     import security-headers
     import logging
+    import authelia

     reverse_proxy portainer:9000 {
         header_up Host {host}
         header_up X-Real-IP {remote_host}
         header_up X-Forwarded-For {remote_host}
         header_up X-Forwarded-Proto {scheme}
         header_up Connection {>Connection}
         header_up Upgrade {>Upgrade}
     }
 }
```

Validar y recargar Caddy:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Probar desde un navegador (con la CA local importada, ver `docs/03-red/04-caddy.md`):

1. Visitar `https://portainer.lan/`. El navegador se redirige a `https://auth.lan/?rd=https%3A%2F%2Fportainer.lan%2F`.
2. Login con `homelab` + la contraseña fijada en `users_database.yml`.
3. Authelia pide enrolar TOTP (porque la regla 3 de `access_control` exige 2FA para `portainer.lan`):
   - Aparece un código QR. Escanearlo con Aegis / Google Authenticator / 1Password.
   - Introducir el código de 6 dígitos.
4. Authelia redirige al destino original (`https://portainer.lan/`) con la sesión activa. Portainer carga.

A partir de aquí, navegar a `https://pihole.lan/admin/` no pide login (la regla 2 de `access_control` permite `*.lan` con 1FA, y la sesión actual ya cumple 1FA). Eso **es el SSO funcionando**.

> **Si la regla por defecto fuera más laxa** y Pi-hole quedase como `bypass`, no se pediría nada en absoluto. Aquí se mantiene `one_factor` para *.lan como _default_ "razonablemente paranoico": en una LAN doméstica con dispositivos IoT mezclados, no exponer ni la UI de Pi-hole sin login es prudente. Los servicios públicos del homelab que no necesiten autenticación (un dashboard estático, por ejemplo) se pueden mover a `bypass` añadiéndolos a la regla 1.

---

## Verificación final

Antes de pasar a `docs/04-seguridad/02-fail2ban.md`, comprobar:

- [ ] `docker compose -f ~/homelab/seguridad/docker-compose.yml ps` muestra `authelia` y `redis` en estado `Up` y `(healthy)`.
- [ ] `ls -la /mnt/hd2t/services/authelia/secrets/` lista `jwt-secret`, `session-secret`, `storage-encryption`, los tres con permisos `-r--------` (0400) y propietario `1000:1000`.
- [ ] `wc -c /mnt/hd2t/services/authelia/secrets/*` da `64` para cada uno.
- [ ] `docker exec authelia authelia validate-config --config /config/configuration.yml` devuelve `Configuration parsed and loaded successfully without errors.`.
- [ ] `docker exec redis redis-cli PING` devuelve `PONG`.
- [ ] `docker exec authelia authelia healthcheck` exit-code `0`.
- [ ] `curl -k --resolve auth.lan:443:192.168.1.3 https://auth.lan/api/health` devuelve `{"status":"OK"}`.
- [ ] El _snippet_ `~/homelab/red/caddy/snippets/authelia.caddy` ya **no** está vacío y `caddy validate` lo acepta sin errores.
- [ ] El bloque `auth.lan` está en el `Caddyfile` y `curl -k --resolve auth.lan:443:192.168.1.3 https://auth.lan/ -I` responde `HTTP/2 200`.
- [ ] El bloque `portainer.lan` lleva `import authelia` y `curl -k --resolve portainer.lan:443:192.168.1.3 -I https://portainer.lan/` ya **no** devuelve `200` directo, sino `302` con `Location: https://auth.lan/?rd=...`.
- [ ] Login interactivo desde el navegador funciona: usuario+contraseña del `users_database.yml`, enrollment TOTP exitoso, redirección a Portainer con sesión válida.
- [ ] Tras el login en Portainer, visitar `https://pihole.lan/admin/` **no vuelve a pedir login** (SSO transparente; regla `*.lan = one_factor` se cumple con la sesión activa).
- [ ] Cerrar sesión desde `https://auth.lan/` invalida la cookie y un nuevo intento contra `portainer.lan` vuelve a redirigir al portal.
- [ ] Tras un `docker compose -f ~/homelab/seguridad/docker-compose.yml restart`, las sesiones activas **siguen activas** (Redis persistente con AOF).
- [ ] Tras un `sudo reboot` de la Pi, el _stack_ vuelve a estar `(healthy)` sin intervención manual y `https://auth.lan/` responde.
- [ ] `git -C ~/homelab status` muestra como **modificados**: `red/Caddyfile`, `red/caddy/snippets/authelia.caddy`. Y como **nuevos**: `seguridad/docker-compose.yml`, `seguridad/.env.example`, `seguridad/configuration.yml`, `seguridad/.gitignore`. **No** muestra `seguridad/.env`, `users_database.yml`, ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add seguridad/docker-compose.yml seguridad/.env.example \
          seguridad/configuration.yml seguridad/.gitignore \
          red/Caddyfile red/caddy/snippets/authelia.caddy
  git commit -m "feat(seguridad): add Authelia SSO+2FA with forward_auth in Caddy"
  ```

---

## Backup

| Qué                                            | Dónde                                                       | Cómo                                            |
|------------------------------------------------|-------------------------------------------------------------|-------------------------------------------------|
| `docker-compose.yml` y `configuration.yml`     | `~/homelab/seguridad/`                                      | git                                             |
| `users_database.yml`                           | `/mnt/hd2t/services/authelia/config/users_database.yml`     | Borgmatic (`docs/07-backups/02-borgmatic.md`)   |
| Secretos (jwt, session, storage-encryption)    | `/mnt/hd2t/services/authelia/secrets/`                      | Borgmatic                                       |
| Estado SQLite (TOTP, WebAuthn, regulación)     | `/mnt/hd2t/services/authelia/config/db.sqlite3`             | Borgmatic                                       |
| Cola de notificaciones (filesystem notifier)   | `/mnt/hd2t/services/authelia/config/notifications.txt`      | No (transitorio; se sustituye por SMTP)         |
| AOF de Redis (sesiones activas)                | `/mnt/hd2t/services/redis/data/`                            | Borgmatic, pero no crítico (re-login global = aceptable) |

> **Restauración**: clonar el repo, restaurar `/mnt/hd2t/services/authelia/{config,secrets}` desde Borgmatic, restaurar `/mnt/hd2t/services/redis/data/` (opcional), `make up STACK=seguridad`, recargar Caddy. Las sesiones activas restauradas siguen siendo válidas.

> **Rotación de los tres secretos**: regenerar uno cualquiera invalida _algo_:
> - `jwt-secret` → invalida los tokens de _password reset_ pendientes (raro tener alguno); seguro de rotar.
> - `session-secret` → **invalida todas las sesiones activas** (todos vuelven a hacer login). Intencional cuando se sospeche compromiso.
> - `storage-encryption` → **invalida todos los TOTP enrolados**. El operador debe re-enrolar TOTP. Sólo rotar tras compromiso confirmado de la BD.

---

## Troubleshooting

### `authelia` arranca y muerto en bucle: `the option 'session.secret' was not provided`

Authelia no encontró el _file_ del secreto. Causas:

1. El _bind mount_ `/mnt/hd2t/services/authelia/secrets:/run/secrets:ro` no se aplicó (typo en `docker-compose.yml`).
2. El UID 1000 dentro del contenedor no puede leer los ficheros (permisos restrictivos `0400` con _otro_ owner). Confirmar:
   ```bash
   docker exec --user 1000 authelia ls -la /run/secrets/
   docker exec --user 1000 authelia head -c 16 /run/secrets/session-secret && echo
   ```
   Si falla con `Permission denied`, ajustar el ownership en el host:
   ```bash
   sudo chown 1000:1000 /mnt/hd2t/services/authelia/secrets/*
   ```

### El portal carga pero el _login_ devuelve `Authentication failed.`

La contraseña hasheada no coincide. Revisar:

1. `users_database.yml` — el campo `password:` debe ser **el digest completo** (`$argon2id$v=19$m=...$<salt>$<hash>`), entre comillas dobles para que YAML no se confunda con los `$`.
2. Los parámetros del hash (`memory`, `iterations`, `parallelism`) deben coincidir con los de `configuration.yml` — aunque Argon2 verifica con los del propio digest, el _refresh_ del fichero requiere consistencia.
3. Generar el hash de nuevo y reemplazar:
   ```bash
   docker run --rm -it authelia/authelia:4.38.16 \
     authelia crypto hash generate argon2 --variant argon2id
   ```
4. `authelia` con `watch: true` recarga el fichero en cuanto cambia (5 s); si no, `docker compose restart authelia`.

### `redis: NOAUTH Authentication required.`

Redis no requiere autenticación en este compose (no se ha definido `requirepass`). Si el log dice `NOAUTH`, es porque algún `redis-server` previo en el mismo volumen sí la tenía. Limpiar:

```bash
docker compose -f ~/homelab/seguridad/docker-compose.yml down redis
sudo rm /mnt/hd2t/services/redis/data/appendonly.aof.* 2>/dev/null
sudo rm /mnt/hd2t/services/redis/data/dump.rdb 2>/dev/null
docker compose -f ~/homelab/seguridad/docker-compose.yml up -d redis
```

> **Si prefieres** activar `requirepass` (defensa en profundidad): añadir `--requirepass <password>` al `command:` de Redis y `password: <password>` bajo `session.redis:` en `configuration.yml`. No es estrictamente necesario en una red privada del _stack_.

### Caddy muestra `502 Bad Gateway` al ir a `auth.lan`

Authelia no está alcanzable desde Caddy. Diagnóstico:

```bash
docker network inspect homelab --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}'
# Debe listar 'authelia', 'caddy', 'pihole', 'portainer'.
```

Si `authelia` no aparece, verificar `networks:` en `~/homelab/seguridad/docker-compose.yml`: tiene que llevar `homelab` con `aliases: [authelia]`.

### El navegador entra en bucle de redirección entre `portainer.lan` y `auth.lan`

Causa típica: la cookie de sesión no se está fijando con `Domain=lan`. Causas:

1. El cliente está accediendo por IP (`https://192.168.1.3/`) en lugar de por nombre — la cookie no aplica a IPs literales. Solución: usar siempre `https://portainer.lan/`.
2. El navegador rechaza la cookie por el certificado no confiado. La cookie es `Secure` y algunos navegadores no la guardan en orígenes con cert "no confiable". Solución: importar la CA local (`docs/03-red/04-caddy.md`, sección **Confianza en la CA local**).
3. `same_site: strict` por error. Confirmar que `configuration.yml` tiene `same_site: lax`.

### Authelia muestra `Your session has expired.` cada pocos minutos

El `inactivity: 5m` de la cookie es demasiado corto para el flujo del operador. Subir a `15m` o `30m` en `configuration.yml`:

```yaml
session:
  cookies:
    - inactivity: 15m
```

Y `kill -HUP 1` o `docker compose restart authelia`.

### `docker exec authelia kill -HUP 1` no recarga `users_database.yml`

`watch: true` debería bastar. Si no, comprobar:

```bash
docker exec authelia stat /config/users_database.yml
# Cambia 'Modify' al editar; si no, el bind mount está roto.
```

Y, como _fallback_, `docker compose restart authelia`. La recarga "en caliente" es una optimización; el reinicio es siempre seguro (las sesiones de Redis sobreviven).

### Tras importar la CA local, el navegador sigue mostrando "no seguro" en `auth.lan`

Caché de cert obsoleto en el navegador. Cerrar el navegador completamente, abrir, retry. En Firefox, además, importar la CA local también dentro del propio Firefox (`about:preferences#privacy` → Certificados → Autoridades) — Firefox no usa el _trust store_ del sistema.

---

## Migrar a notifier SMTP

Cuando exista un relay SMTP local (Postfix _null client_, MSMTP relay, o un proveedor externo tipo Migadu), sustituir en `configuration.yml`:

```yaml
notifier:
  filesystem:
    filename: /config/notifications.txt
```

por:

```yaml
notifier:
  smtp:
    address: smtp://smtp-relay:25
    sender: 'homelab@homelab.lan'
    identifier: 'homelab.lan'
    subject: '[Homelab Authelia] {title}'
    startup_check_address: 'homelab@homelab.lan'
    timeout: 5s
    disable_require_tls: true       # SMTP del homelab interno, sin TLS
```

Si el relay externo requiere autenticación, añadir un cuarto secreto `smtp-password`:

```bash
echo -n '<password>' | sudo tee /mnt/hd2t/services/authelia/secrets/smtp-password > /dev/null
sudo chmod 0400 /mnt/hd2t/services/authelia/secrets/smtp-password
sudo chown 1000:1000 /mnt/hd2t/services/authelia/secrets/smtp-password
```

Y en `docker-compose.yml`:

```yaml
environment:
  AUTHELIA_NOTIFIER_SMTP_PASSWORD_FILE: /run/secrets/smtp-password
```

Y en `configuration.yml`:

```yaml
notifier:
  smtp:
    username: 'homelab@homelab.lan'
    # password: lo aporta el _FILE env var
```

`docker compose up -d authelia` y un `authelia healthcheck` en verde.

---

## Referencias

- Authelia — Documentación oficial: <https://www.authelia.com/>
- Authelia — Schema 4.38.x: <https://www.authelia.com/configuration/prologue/introduction/>
- Authelia — `forward_auth` con Caddy: <https://www.authelia.com/integration/proxies/caddy/>
- Authelia — Backend de autenticación por fichero: <https://www.authelia.com/configuration/first-factor/file/>
- Authelia — Almacenamiento SQLite: <https://www.authelia.com/configuration/storage/sqlite/>
- Authelia — Sesiones con Redis: <https://www.authelia.com/configuration/session/redis/>
- Authelia — Reglas de `access_control`: <https://www.authelia.com/configuration/security/access-control/>
- Authelia — `crypto hash generate`: <https://www.authelia.com/reference/cli/authelia/authelia_crypto_hash_generate/>
- Authelia — Imagen Docker oficial: <https://hub.docker.com/r/authelia/authelia>
- Caddy — `forward_auth` directive: <https://caddyserver.com/docs/caddyfile/directives/forward_auth>
- Redis — Persistencia (RDB + AOF): <https://redis.io/docs/management/persistence/>
- Redis — Imagen Docker oficial: <https://hub.docker.com/_/redis>
