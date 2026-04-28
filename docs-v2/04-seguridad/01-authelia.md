# Authelia

## Descripción

Despliegue de **Authelia v4** como **portal de autenticación SSO + 2FA** para todos los servicios web del homelab. Authelia se integra como *middleware* del reverse proxy Caddy (directiva `forward_auth`, [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §10.5) y queda **delante** de cada `reverse_proxy` que el operador decida proteger: Portainer, Pi-hole, Nextcloud, Vaultwarden, Jellyfin (para acceso remoto), Sonarr/Radarr/Prowlarr/Transmission, Home Assistant, Bookstack, Paperless-ngx... cualquiera que sirva por HTTPS y no tenga su propia capa SSO suficiente.

Authelia vive en su propio stack `auth` ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §1.1, fila `auth → Authelia (+ Redis para sesiones)`). El stack contiene **dos contenedores**:

- **`authelia`** — el portal y la API de verificación (`/api/verify`). Se conecta a la red bridge `homelab` para que Caddy pueda llamarle por nombre Docker (`http://authelia:9091`) y no publica puertos al host.
- **`redis`** — backend de sesiones. Aislado en la red interna `auth_internal`. **No** se conecta a `homelab`: ningún otro servicio del homelab debe tocarlo.

Por qué exactamente esta arquitectura, y no otra:

1. **SSO de un solo punto, integrable con cualquier servicio que tenga reverse proxy.** El homelab acumula 25–30 servicios web. Mantener una contraseña por servicio (Nextcloud, Vaultwarden, Jellyfin, Portainer, Sonarr...) escala mal y multiplica el riesgo de reutilización. Authelia añade una capa única de login + 2FA delante del proxy, sin pedirle al servicio que se lo crea: con `forward_auth` en Caddy, **el servicio recibe la petición ya autenticada** (cabecera `Remote-User`) y, si el servicio entiende esa cabecera, ni siquiera muestra su propio login (Nextcloud, Bookstack, Sonarr…). Si no la entiende, Authelia sigue protegiendo el acceso aunque el operador deba autenticarse otra vez en el servicio (peor experiencia, misma seguridad de borde).
2. **Backend `file` (no LDAP, no PostgreSQL).** El homelab tiene **un usuario** (el operador, eventualmente la pareja/familia con 2–3 cuentas más). Levantar OpenLDAP o `lldap` para 3 usuarios es ingeniería innecesaria; Authelia soporta nativamente un YAML con usuarios + hashes Argon2id (`authentication_backend.file`). Misma seguridad de cifrado, una décima parte de complejidad operativa. Si en el futuro hay que federar 10+ usuarios o integrarse con SAML, se migra a `lldap` reescribiendo solo `authentication_backend:`.
3. **TOTP para 2FA, sin WebAuthn por ahora.** Los apps de TOTP (Aegis en Android, Raivo/2FAS en iOS) son universales, offline y no dependen de una `relying party` con dominio resoluble desde fuera de la LAN — clave porque `auth.lan` **no** existe en internet. WebAuthn (FIDO2/Passkeys) sí funciona en LAN-only con la CA interna de Caddy, pero exige más documentación de fallback (perder la llave = pérdida de acceso); se deja como excepción documentada para activarse cuando el operador lo decida.
4. **Sesiones en Redis aislado.** Authelia v4 funciona con `session.cookie` firmada localmente o con `session.redis`. Redis aporta dos cosas: (a) revocación inmediata de sesiones (logout efectivo en todos los dispositivos) y (b) supervivencia de sesiones a un `docker compose restart authelia`. Aislar Redis en `auth_internal` (red bridge sin `external`) y **no** publicar `:6379` al host elimina el principal vector contra Redis (acceso anónimo desde la LAN).
5. **SQLite para almacenamiento, no PostgreSQL.** Authelia v4 guarda en `storage:` los secretos cifrados de TOTP, los rate-limit counters y los códigos de un solo uso. El volumen es minúsculo (kilobytes). SQLite (`storage.local.path: /config/db.sqlite3`) no requiere otro contenedor de BD, no añade upgrade dance entre majors, y se respalda con un simple `cp` del fichero. Para >50 usuarios se migra a PostgreSQL; en este homelab no aplica.
6. **`access_control.default_policy: deny`.** Authelia evalúa políticas por dominio/path en orden; si nada empareja, aplica el default. Configurarlo en `deny` significa que un servicio nuevo **debe** declarar explícitamente su política antes de ser accesible: añade un `forward_auth` en Caddy y un bloque `access_control.rules` aquí. Olvidarse de ese paso = error fail-closed, no fail-open.
7. **Notificador `filesystem`, no SMTP.** Authelia envía emails para reset de password, alta de TOTP y notificaciones de seguridad. La LAN no tiene un MTA configurado (ni se quiere — añadir Postfix/Exim/relay externo es un servicio más con su DNS, sus credenciales y su superficie). El `notifier.filesystem` escribe esos "emails" como ficheros de texto en `/config/notifications.txt`, donde el operador los lee directamente. Para un homelab de un puñado de cuentas humanas es trivial; cuando haga falta SMTP real, se conmuta a `notifier.smtp:` (deja preparado el bloque).
8. **Watchtower excluido.** Authelia ha cambiado el formato de `configuration.yml` entre minors (3.x → 4.x → 4.38 reescribió `identity_validation`, `session.cookies`, `notifier.filesystem`...). Un upgrade automático a las 04:00 puede dejar el contenedor en `crash loop` y, con él, **toda la LAN sin acceso a los servicios protegidos**. Documentado en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6, fila `Authelia` (línea 452).

> **Alcance**: este documento despliega Authelia + Redis, persiste sus datos en `hd2t`, escribe `configuration.yml` y `users_database.yml` versionables (con secretos por `secrets/`), levanta el portal en `https://auth.${LAN_DOMAIN}` por Caddy y deja **preparado** el `forward_auth` para que cada doc de servicio lo enchufe en su Caddy block. **No** modifica el `Caddyfile` de los servicios ya desplegados (Pi-hole, Portainer): solo añade el bloque `auth.lan` y un snippet `authelia_proxy` reutilizable. La activación por servicio queda en el doc de cada servicio (Portainer §X, Nextcloud §X, etc., los docs de cada servicio referenciarán a este). **No** activa WebAuthn ni SMTP: ambos quedan documentados como variantes opt-in.

---

## Requisitos Previos

- **Docker Engine + Compose v2** instalados según [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md).
- **Red `homelab`** creada según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2 (`172.20.0.0/24`, bridge `br-homelab`, `external: true`).
- **Caddy desplegado** según [`../03-red/04-caddy.md`](../03-red/04-caddy.md), conectado a `homelab`, con la CA interna funcionando y al menos un cliente con `root.crt` confiado (§6.5 de Caddy).
- **Pi-hole desplegado** según [`../03-red/02-pihole.md`](../03-red/02-pihole.md), con la posibilidad de añadir registros DNS locales (Local DNS Records) para `auth.${LAN_DOMAIN}` apuntando a `192.168.1.10` (la IP del host donde escucha Caddy).
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No se añaden reglas nuevas: Authelia no publica puertos al host; el tráfico entra por Caddy (que ya tiene 80/443 abiertos en §6.4 de su doc).
- **Estructura de directorios** de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) en su sitio: `/mnt/hd2t/services/` existe con propietario `homelab:homelab`. El bootstrap original creó `/mnt/hd2t/services/authelia/` (esquema antiguo "un dir por servicio"); este doc usa el esquema vigente "un dir por stack" (`/mnt/hd2t/services/auth/`) y muestra cómo migrar.
- **Una contraseña de operador** generada con `openssl rand -base64 24`, anotada en el gestor de contraseñas del operador (KeePassXC fuera del homelab, hasta que Vaultwarden esté arriba).
- **App de TOTP** instalada en el móvil del operador (Aegis, Raivo, 2FAS, FreeOTP+). Nada de Authy: su nube propietaria no encaja con la postura del homelab.
- **Comprobaciones rápidas**:
  ```bash
  # La red homelab existe:
  docker network inspect homelab --format '{{(index .IPAM.Config 0).Subnet}}'
  # Esperado: 172.20.0.0/24

  # Caddy está sano:
  docker inspect caddy --format '{{.State.Health.Status}}'
  # Esperado: healthy

  # Pi-hole resuelve auth.lan al host (preparar antes en su UI):
  dig +short @192.168.1.241 auth.lan
  # Esperado: 192.168.1.10  (si no, añadir el registro en Pi-hole y volver)
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Imagen Docker (Authelia) | **`authelia/authelia:4.38.17`** | Imagen oficial multi-arch (incluye `linux/arm64`). 4.38.x es la rama estable a fecha de este doc; cambia el formato de `identity_validation` y `session.cookies` respecto a 4.37, así que los ejemplos antiguos del proyecto no aplican. Pinned a release puntual: ver razón general en la siguiente fila. |
| Tag de imagen | **Pinned a la release**, nunca `latest` ni rolling minor | Misma regla de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1 + razón específica de Authelia: cambios incompatibles en `configuration.yml` entre minors han dejado al servicio en `crash loop`. Upgrade manual leyendo el [Migration Guide](https://www.authelia.com/configuration/migration/) y validando con `authelia validate-config` antes de aplicar. |
| Política de Watchtower | **`watchtower.enable: "false"`** | Authelia es ÚNICO punto que da o niega acceso a todos los servicios protegidos. Un upgrade silencioso que rompa el parser deja el portal en bucle de reinicio y, por consiguiente, todos los `forward_auth` de Caddy responden 502 → todos los servicios protegidos inaccesibles. Documentado en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6 línea 452. |
| Imagen Docker (Redis) | **`redis:7.4-alpine`** | Multi-arch oficial. La variante `-alpine` (~30 MB) es suficiente: Redis se usa como key-value de sesiones, sin persistencia AOF. La línea `7.x` es la estable actual; la línea `8.x` introduce cambios de licencia que no afectan al uso, pero se pinea por consistencia. |
| Política de Watchtower (Redis) | **`watchtower.enable: "false"`** | Coherente con [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6 fila `Redis`: cambios de protocolo entre majors aunque raros se prefieren controlados. Pérdida de Redis = pérdida de sesiones; el operador re-loguea. No es catastrófico, pero un crash loop sí inutiliza el portal hasta el siguiente arranque. |
| Modo de red (Authelia) | **`homelab`** (bridge `external`) + **`auth_internal`** (bridge propio del stack) | `homelab` para que Caddy llame por `http://authelia:9091`. `auth_internal` para hablar con Redis sin que Redis esté expuesto a `homelab`. La regla §4.3 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) ("una BD/cache nunca se conecta a `homelab` salvo que la consuma un servicio fuera de su stack") se aplica literalmente. |
| Modo de red (Redis) | **Solo `auth_internal`** | Redis no debe ser alcanzable por nadie excepto Authelia. Cualquier servicio que pidiera Redis en el homelab tendría su propio Redis en su stack (Nextcloud lo hace, [`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md)). |
| `ports:` publicados al host | **Ninguno** (ni Authelia ni Redis) | El portal se sirve **únicamente** vía Caddy (`reverse_proxy http://authelia:9091`). Publicar `9091` al host duplicaría la entrada y permitiría saltarse Caddy (y, con él, su HTTPS y sus cabeceras). Redis nunca debe publicarse — su autenticación con `requirepass` es defensa en profundidad, pero el aislamiento de red es la principal capa. |
| Backend de autenticación | **`authentication_backend.file`** con `users_database.yml` y hashes **Argon2id** | Justificado en §0 punto 2. Argon2id es el algoritmo recomendado por OWASP/IETF; los hashes los genera el propio binario de Authelia (`authelia crypto hash generate argon2`). Nada de bcrypt: aún válido, pero Argon2id es la recomendación primaria del proyecto. |
| Política de acceso por defecto | **`deny`** (`access_control.default_policy: deny`) | Fail-closed. Cualquier servicio sin regla explícita queda inaccesible. Justificado en §0 punto 6. |
| Método 2FA | **TOTP** (RFC 6238, 6 dígitos, periodo 30 s, algoritmo SHA-1 por compatibilidad con Aegis/Raivo) | Estándar universal, offline, soportado por todos los apps de TOTP. WebAuthn se documenta como opt-in en §10.6. |
| Almacenamiento | **SQLite** (`storage.local.path: /config/db.sqlite3`) | Justificado en §0 punto 5. Fichero único, dump trivial. |
| Notificador | **`notifier.filesystem`** (`filename: /config/notifications.txt`) | Justificado en §0 punto 7. SMTP queda como variante en §10.7. |
| Cookie de sesión | **`session.cookies[0].domain = ${LAN_DOMAIN}`** | Una cookie raíz para `*.lan` permite SSO entre subdominios (`https://nextcloud.lan` y `https://vaultwarden.lan` comparten sesión). Si en el futuro se añade Tailscale (`*.tailnet.ts.net`), se declara una segunda entrada en el array `session.cookies[]` para ese dominio. |
| `session.expiration` / `inactivity` / `remember_me` | `1h` / `15m` / `1mo` | Equilibrio razonable: 1 hora máxima de sesión, 15 minutos de inactividad, "Recuérdame" extiende a 1 mes. El reset de password requiere TOTP de nuevo (`require_two_factor: true` en `password_reset` y `password_change`). |
| Nivel de log | **`info`** (`log.level`) | Suficiente para auditoría sin ruido excesivo. Se eleva a `debug` solo para troubleshooting puntual y se devuelve a `info` después. `trace` filtra hashes y sería peligroso. |
| Formato de log | **`text`** | Authelia 4.38 emite por defecto `text` legible. JSON estructurado se documenta como variante para Loki en Fase 5+. |
| Healthcheck | **`/api/health`** vía wget interno del contenedor (la imagen `authelia/authelia` lleva un binario `healthcheck.sh` con esto) | El endpoint `/api/health` responde 200 cuando Authelia ha cargado config, abierto BD y conectado con Redis. Si Redis falla, marca `unhealthy` y `docker compose ps` lo muestra. |
| Usuario del contenedor (Authelia) | **`${PUID}:${PGID}`** (`1000:1000`) | La imagen de Authelia respeta el `user:` de Compose. Plantilla §6 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). |
| Usuario del contenedor (Redis) | **`redis:redis`** (UID 999 dentro de la imagen, default) | La imagen oficial de Redis ya droppea privilegios. No se sobreescribe con `${PUID}` para no romper la propiedad de `/data` que Redis crea al primer arranque. |
| `cap_drop: ALL` + `cap_add` mínimo | `[]` para Authelia, `[]` para Redis | Ningún capability necesario: Authelia bindea a un puerto >1024 (9091) y no toca red baja; Redis hace lo mismo (6379). |
| `security_opt` | **`no-new-privileges:true`** (ambos) | Plantilla §6. |
| `read_only` | **`true`** para Authelia (con `tmpfs:` para `/tmp`); **`false`** para Redis (escribe en `/data`) | Authelia solo lee `/config/configuration.yml` y `/config/users_database.yml` (montados RO) y escribe en `/config/{db.sqlite3,notifications.txt}` (montado RW). El RO del FS root reduce superficie. Redis escribe en `/data`; hacerlo RO obligaría tmpfs para todo el AOF/RDB y, por simplicidad, se deja RW. |
| Persistencia (Authelia) | Bind mount `/config/` en `/mnt/hd2t/services/auth/authelia/config/` | Contiene `configuration.yml`, `users_database.yml`, `db.sqlite3` y `notifications.txt`. Backup obligatorio (§11). |
| Persistencia (Redis) | Bind mount `/data/` en `/mnt/hd2t/services/auth/redis/data/` | Sesiones efímeras: pérdida = re-login en todos los clientes. **No** es backup-crítico; se documenta como opcional en §11. |
| Secretos | En **`/mnt/hd2t/services/auth/secrets/`** (chmod 600), **no** en `.env` ni en `configuration.yml` | Authelia 4.38 lee secretos vía `*_FILE` env vars (`AUTHELIA_JWT_SECRET_FILE=/secrets/jwt`), patrón estándar Docker. Mantener los secretos en archivos separados permite rotarlos sin tocar `configuration.yml` y excluirlos de git con un solo `.gitignore`. |
| Secretos requeridos | `jwt`, `session`, `storage_encryption`, `redis_password`, `oidc_hmac` (este último opcional, no se usa hasta activar OIDC) | Authelia 4.38 exige los 4 primeros. Generados con `openssl rand -hex 64` (mínimo 64 caracteres recomendado por la doc oficial). |

---

## 1. Resumen de la arquitectura

```
                    ┌─────────────────────────────────────┐
                    │  LAN 192.168.1.0/24                 │
                    │                                     │
  navegador ──HTTPS─►  *.lan  ──Pi-hole DNS──► 192.168.1.10:443  (Caddy)
                    │                                     │
                    └─────────────┬───────────────────────┘
                                  │
                          (tcp 443)
                                  │
                ┌─────────────────▼───────────────────────────────────────┐
                │  Pi 5 — docker network: homelab (172.20.0.0/24)         │
                │                                                         │
                │   ┌──────── caddy ────────┐                              │
                │   │  reverse_proxy ───────┼──► http://authelia:9091     │
                │   │     (auth.lan)        │                              │
                │   │                       │                              │
                │   │  forward_auth ───────►├──► http://authelia:9091     │
                │   │     (nextcloud.lan,   │      /api/verify?rd=...     │
                │   │      vault.lan, ...)  │                              │
                │   └───────────────────────┘                              │
                │                                                         │
                │   ┌────── stack: auth ──────────────────────────────┐   │
                │   │                                                 │   │
                │   │   ┌──── authelia ────┐    ┌──── redis ────┐   │   │
                │   │   │ image:           │    │ image:         │   │   │
                │   │   │  authelia/       │    │  redis:        │   │   │
                │   │   │  authelia:4.38   │    │  7.4-alpine    │   │   │
                │   │   │ networks:        │    │ networks:      │   │   │
                │   │   │  - homelab       │    │  - auth_       │   │   │
                │   │   │  - auth_internal │◄──►│    internal    │   │   │
                │   │   │ ports: -         │    │ ports: -       │   │   │
                │   │   │ user: 1000:1000  │    │ user: redis    │   │   │
                │   │   │ read_only: true  │    │ password:      │   │   │
                │   │   │ /config (RW)     │    │  ${REDIS_PWD}  │   │   │
                │   │   │ /secrets (RO)    │    │ /data (RW)     │   │   │
                │   │   └──────────────────┘    └────────────────┘   │   │
                │   │                                                 │   │
                │   │   network: auth_internal (bridge, NO external) │   │
                │   └─────────────────────────────────────────────────┘   │
                └─────────────────────────────────────────────────────────┘
```

Tres invariantes:

- **Authelia solo es accesible vía Caddy.** No hay `ports:` al host. La única vía de entrada es `https://auth.lan` o (en otros servicios) la cabecera `Remote-User` que Caddy inyecta tras un `forward_auth` exitoso.
- **Redis no se conecta a `homelab`.** Solo Authelia, dentro del mismo stack, lo alcanza por `redis:6379` en `auth_internal`. Si `homelab` se viera comprometida (un contenedor compromiso), Redis sigue inalcanzable.
- **Sin Watchtower, sin `latest`.** Upgrade manual leyendo el [Migration Guide](https://www.authelia.com/configuration/migration/) de Authelia.

Flujo de autenticación (caso "primer acceso a Nextcloud"):

```
1. Operador → https://nextcloud.lan
2. Caddy → forward_auth → http://authelia:9091/api/verify?rd=https://auth.lan/
3. Authelia → no hay cookie de sesión válida → 401 → Caddy redirige a auth.lan/?rd=...
4. Operador en auth.lan: usuario + password → Authelia verifica Argon2id contra users_database.yml
5. Authelia: si pasa, pide TOTP. El primer login fuerza enrolar 2FA (escanear QR con Aegis).
6. Operador introduce TOTP → Authelia crea sesión en Redis y setea cookie *.lan
7. Authelia redirige al rd= original → https://nextcloud.lan
8. Caddy → forward_auth → 200 con cabeceras Remote-User=homelab, Remote-Email=...
9. Caddy → reverse_proxy http://nextcloud:11000 con esas cabeceras añadidas
10. Nextcloud lee Remote-User (si está configurado para SSO HTTP) y entra sin login propio.
```

---

## 2. Plan de variables y archivos

El stack `auth` es nuevo. Layout que se va a crear:

```
~/homelab/stacks/auth/                # versionable en git
├── docker-compose.yml
├── .env.example
├── configuration.yml                 # config de Authelia (sin secretos)
├── users_database.yml                # usuarios + hashes (sin secretos en claro)
└── snippets-caddy/
    └── authelia_proxy                # snippet a copiar a stacks/proxy/snippets/

/mnt/hd2t/services/auth/              # datos persistentes, NO en git
├── .env                               # variables (chmod 600), sin secretos crudos
├── secrets/                           # chmod 700, ficheros chmod 600
│   ├── jwt
│   ├── session
│   ├── storage_encryption
│   └── redis_password
├── authelia/
│   └── config/                        # /config del contenedor: db.sqlite3, notifications.txt
└── redis/
    └── data/                          # AOF/RDB de Redis
```

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/auth/.env.example`:

```dotenv
# ~/homelab/stacks/auth/.env.example
# Versión control: ~/homelab/stacks/auth/.env.example
# Valores reales en /mnt/hd2t/services/auth/.env (chmod 600).
# Los SECRETOS NO van aquí — están en /mnt/hd2t/services/auth/secrets/.

# --- Comunes del homelab ---
PUID=1000
PGID=1000
TZ=Europe/Madrid

# --- Dominios internos (consistentes con dns/.env y proxy/.env) ---
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Authelia ---
# https://hub.docker.com/r/authelia/authelia/tags
# ¡Leer https://www.authelia.com/configuration/migration/ antes de cambiar!
AUTHELIA_IMAGE_TAG=4.38.17

# Hostname público del portal (sin esquema).
AUTHELIA_HOSTNAME=auth.lan

# --- Redis ---
# https://hub.docker.com/_/redis/tags
REDIS_IMAGE_TAG=7.4-alpine
```

### 2.2. `.env` real (`/mnt/hd2t/services/auth/.env`)

```bash
# Crear el .env con permisos correctos.
sudo install -m 600 -o homelab -g homelab /dev/null /mnt/hd2t/services/auth/.env

cat > /mnt/hd2t/services/auth/.env <<'EOF'
PUID=1000
PGID=1000
TZ=Europe/Madrid

LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

AUTHELIA_IMAGE_TAG=4.38.17
AUTHELIA_HOSTNAME=auth.lan

REDIS_IMAGE_TAG=7.4-alpine
EOF

ls -l /mnt/hd2t/services/auth/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

### 2.3. Cómo se inyectan los secretos

Authelia 4.38 entiende variables con sufijo `_FILE`: por cada secreto declarado en `configuration.yml`, define la variable de entorno `AUTHELIA_<RUTA>_FILE` apuntando a un fichero dentro del contenedor (montado RO desde `/mnt/hd2t/services/auth/secrets/`). El contenedor lee el contenido y lo aplica al runtime; el fichero **nunca** entra al `configuration.yml`. Lo veremos en §5 (`docker-compose.yml`).

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
mkdir -p ~/homelab/stacks/auth/snippets-caddy
```

### 3.2. Crear el árbol de datos persistentes

```bash
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/auth
sudo install -d -o homelab -g homelab -m 700 /mnt/hd2t/services/auth/secrets
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/auth/authelia
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/auth/authelia/config
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/auth/redis
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/auth/redis/data
```

> **Migración desde `/mnt/hd2t/services/authelia/`** (esquema antiguo "un dir por servicio" creado por el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)):
> ```bash
> sudo rmdir /mnt/hd2t/services/authelia 2>/dev/null || true
> ```
> En un homelab nuevo no hay datos previos. Si los hubiese, mover los contenidos a la ruta nueva (`/mnt/hd2t/services/auth/authelia/config/`) y borrar el directorio antiguo.

### 3.3. Permisos para el proceso del contenedor

Authelia corre como `${PUID}:${PGID}` (`1000:1000` = `homelab:homelab`), así que el bind mount entra con propietario correcto y no hace falta `chown`. Redis corre como `redis:redis` (UID 999) dentro del contenedor; al primer arranque escribirá en `/data` como UID 999. Para que `homelab` desde el host pueda leer (backups con Borg) sin sudo:

```bash
# Asegurar que /data de Redis es escribible por UID 999 dentro del contenedor.
# Ajustar al UID/GID que la imagen oficial de Redis usa internamente:
sudo chown 999:999 /mnt/hd2t/services/auth/redis/data
sudo chmod 770    /mnt/hd2t/services/auth/redis/data
# Añadir el grupo 999 al usuario homelab para poder leer desde el host:
# Solo si se quiere acceso directo desde el host. En general, los backups con
# Borg corren como root y no necesitan este paso.
```

> Si más adelante un `ls -l /mnt/hd2t/services/auth/redis/data` muestra ficheros `999:999`, es el comportamiento esperado. Borg los respaldará igual; el operador, si necesita inspeccionarlos, usa `sudo`.

---

## 4. Generar secretos

```bash
# Crear los 4 secretos requeridos. Cada fichero, una línea sin saltos.
umask 077
mkdir -p /tmp/authelia-secrets
for s in jwt session storage_encryption redis_password; do
  openssl rand -hex 64 > /tmp/authelia-secrets/$s
done

# Mover a su sitio definitivo con permisos correctos.
sudo install -m 600 -o homelab -g homelab /tmp/authelia-secrets/jwt                /mnt/hd2t/services/auth/secrets/jwt
sudo install -m 600 -o homelab -g homelab /tmp/authelia-secrets/session            /mnt/hd2t/services/auth/secrets/session
sudo install -m 600 -o homelab -g homelab /tmp/authelia-secrets/storage_encryption /mnt/hd2t/services/auth/secrets/storage_encryption
sudo install -m 600 -o homelab -g homelab /tmp/authelia-secrets/redis_password     /mnt/hd2t/services/auth/secrets/redis_password

# Verificar.
ls -l /mnt/hd2t/services/auth/secrets/
# Esperado: 4 ficheros -rw------- homelab:homelab, cada uno ~128 bytes (hex de 64 bytes).

# Limpiar el tmp.
shred -u /tmp/authelia-secrets/* 2>/dev/null || rm -f /tmp/authelia-secrets/*
rmdir /tmp/authelia-secrets
```

> **Por qué `openssl rand -hex 64`** (no `-base64`): Authelia exige 64 caracteres mínimo en los secretos críticos. `-hex 64` produce 128 caracteres hex; sobra y son seguros copiar/pegar (sin caracteres especiales). El `umask 077` previene que el fichero temporal se cree con permisos abiertos antes del `install`.

> **Rotar secretos en el futuro**: ver §10.4. Brevemente: cambiar el fichero, `docker compose restart authelia`, los usuarios pierden sus sesiones (cookie inválida) y deben re-loguear. El `storage_encryption` es **especial**: rotarlo invalida los TOTP secrets de la BD, así que requiere paso intermedio (`authelia storage encryption change-key`).

---

## 5. `configuration.yml` de Authelia

`~/homelab/stacks/auth/configuration.yml` — **versionado en git**, sin ningún secreto en claro:

```yaml
# ~/homelab/stacks/auth/configuration.yml
# Versionado en git. Los secretos se inyectan vía variables AUTHELIA_*_FILE
# que apuntan a /secrets/* dentro del contenedor (bind RO desde
# /mnt/hd2t/services/auth/secrets/).
#
# Documentación: https://www.authelia.com/configuration/

server:
  address: "tcp://0.0.0.0:9091/"
  buffers:
    read: 4096
    write: 4096
  endpoints:
    authz:
      forward-auth:
        implementation: ForwardAuth

log:
  level: info
  format: text

theme: dark

identity_validation:
  reset_password:
    # secret leído por env: AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE
    expiration: 5m

totp:
  issuer: homelab.lan
  algorithm: sha1
  digits: 6
  period: 30
  skew: 1

# WebAuthn deshabilitado — opt-in en §10.6.
# webauthn:
#   timeout: 60s
#   display_name: Homelab
#   attestation_conveyance_preference: indirect
#   user_verification: preferred

authentication_backend:
  password_reset:
    disable: false
  refresh_interval: 5m
  file:
    path: /config/users_database.yml
    watch: true
    search:
      email: true
      case_insensitive: false
    password:
      algorithm: argon2
      argon2:
        variant: argon2id
        iterations: 3
        memory: 65536       # 64 MiB
        parallelism: 4
        key_length: 32
        salt_length: 16

password_policy:
  standard:
    enabled: true
    min_length: 12
    max_length: 128
    require_uppercase: true
    require_lowercase: true
    require_number: true
    require_special: true

access_control:
  default_policy: deny
  rules:
    # 1. El propio portal debe ser accesible sin auth (login page).
    - domain: "auth.{{ env "LAN_DOMAIN" }}"
      policy: bypass

    # 2. Endpoints de health/metrics (si en futuro se exponen) — ejemplo.
    # - domain: "auth.{{ env "LAN_DOMAIN" }}"
    #   resources:
    #     - "^/api/health$"
    #   policy: bypass

    # 3. Servicios públicos del homelab (sin auth) — vacío por ahora.

    # 4. Servicios protegidos por 1FA (password sin TOTP) — vacío. Subir solo
    #    bajo decisión consciente del operador.

    # 5. Servicios protegidos por 2FA (password + TOTP). Esta es la categoría
    #    por defecto del homelab. Cada doc de servicio añadirá su entrada aquí.
    - domain:
        - "portainer.{{ env "LAN_DOMAIN" }}"
        - "vault.{{ env "LAN_DOMAIN" }}"
        - "nextcloud.{{ env "LAN_DOMAIN" }}"
        - "sonarr.{{ env "LAN_DOMAIN" }}"
        - "radarr.{{ env "LAN_DOMAIN" }}"
        - "prowlarr.{{ env "LAN_DOMAIN" }}"
        - "transmission.{{ env "LAN_DOMAIN" }}"
        - "bookstack.{{ env "LAN_DOMAIN" }}"
        - "paperless.{{ env "LAN_DOMAIN" }}"
        - "homepage.{{ env "LAN_DOMAIN" }}"
        - "ha.{{ env "LAN_DOMAIN" }}"
      policy: two_factor
      subject:
        - "group:admin"

session:
  secret: ""   # leído por env AUTHELIA_SESSION_SECRET_FILE
  expiration: 1h
  inactivity: 15m
  remember_me: 1mo
  cookies:
    - domain: "{{ env "LAN_DOMAIN" }}"
      authelia_url: "https://auth.{{ env "LAN_DOMAIN" }}"
      default_redirection_url: "https://auth.{{ env "LAN_DOMAIN" }}"
  redis:
    host: redis
    port: 6379
    database_index: 0
    # password leído por env AUTHELIA_SESSION_REDIS_PASSWORD_FILE
    maximum_active_connections: 8
    minimum_idle_connections: 0

regulation:
  max_retries: 3
  find_time: 2m
  ban_time: 5m

storage:
  # encryption_key leído por env AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE
  local:
    path: /config/db.sqlite3

notifier:
  disable_startup_check: false
  filesystem:
    filename: /config/notifications.txt
  # smtp:  # opt-in en §10.7
  #   address: smtp://smtp.example.com:587
  #   username: ...
  #   password: ...
  #   sender: "Authelia <noreply@homelab.local>"

# OIDC: opt-in. Bloque vacío por ahora; se activará si en el futuro un servicio
# necesita OAuth2/OIDC en lugar de forward_auth (Grafana, Nextcloud OIDC, ...).
# identity_providers:
#   oidc:
#     hmac_secret: ""  # leído por env AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET_FILE
#     ...
```

### 5.1. Por qué cada sección

| Sección | Por qué |
|---|---|
| `server.address: tcp://0.0.0.0:9091/` | Authelia solo escucha dentro del contenedor; `0.0.0.0:9091` se mapea solo a las redes Docker a las que está conectado (`homelab`, `auth_internal`). Nadie en la LAN llega directamente: hay que pasar por Caddy. |
| `server.endpoints.authz.forward-auth` | Activa el endpoint `/api/authz/forward-auth` que Caddy llamará vía `forward_auth`. En 4.38 el path canónico es ese; `/api/verify` queda como compat retroactiva. El snippet de Caddy (§9.2) usa el path moderno. |
| `log.level: info` / `log.format: text` | Justificado en §0. `debug` solo para troubleshooting. |
| `theme: dark` | Operador lo prefiere. Cambiar a `light` o `auto` no afecta a la seguridad. |
| `identity_validation.reset_password.expiration: 5m` | Token de reset en correo del notificador `filesystem`. 5 minutos basta para que el operador lea el `notifications.txt` y pegue el link. |
| `totp.algorithm: sha1` / `digits: 6` / `period: 30` | Compatible con todos los apps de TOTP. SHA-256/SHA-512 lo soportan menos apps; rompe a Aegis viejo y a algunos hardware tokens. SHA-1 en TOTP no es la misma debilidad criptográfica que SHA-1 en firmas. `skew: 1` permite ±30s de deriva del reloj del cliente. |
| `webauthn:` (comentado) | Justificado en §0 punto 3. Activar solo cuando el operador esté listo con un par llaves físicas (USB security keys) o con Passkeys del sistema operativo. |
| `authentication_backend.file.path: /config/users_database.yml` | Justificado en §0 punto 2. `watch: true` permite añadir/editar usuarios sin reiniciar el contenedor. `refresh_interval: 5m` controla cada cuánto Authelia recarga el fichero de configuración general. |
| `password.argon2.{iterations,memory,parallelism}` | Parámetros recomendados por la doc oficial de Authelia para 2024. `memory: 65536` (64 MiB) sigue siendo cómodo en una Pi 5 (8 GB de RAM): un login consume ~64 MiB durante ~100ms. |
| `password_policy.standard` | Política mínima para nuevos passwords: 12+ caracteres, mayúscula/minúscula/número/símbolo. Aplica al reset y al `password_change`, NO a los hashes ya existentes en `users_database.yml` (estos ya están hashed; Authelia no puede revisar la composición del plaintext). |
| `access_control.default_policy: deny` | Justificado en §0 punto 6. |
| `access_control.rules[0]` (`auth.lan: bypass`) | Sin esta regla, el propio portal de login estaría protegido por sí mismo → bucle. |
| `access_control.rules[N]` (services: `two_factor`) | Lista preliminar de servicios planificados. Cada doc de servicio (ej. [`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md)) confirma o ajusta su línea aquí cuando se despliegue. Si un servicio se quiere proteger sin TOTP, se mueve a `policy: one_factor` (no recomendado para servicios que exponen datos personales). |
| `subject: group:admin` | Solo los usuarios del grupo `admin` (definido en `users_database.yml`) ven los servicios protegidos. Cuando se añadan usuarios "familiares" con grupo `family`, se añadirá una regla por servicio que ellos puedan tocar. |
| `session.cookies[0].domain` | Justificado en §0 fila "Cookie de sesión". Permite SSO entre subdominios. **No** se usa `Secure: false`: las cookies se envían siempre sobre HTTPS porque solo Caddy las setea, y Caddy solo expone HTTPS. |
| `session.redis.host: redis` | DNS interno de la red `auth_internal`. Resuelve al `container_name: redis` definido en §6. |
| `session.redis.maximum_active_connections: 8` | Pi 5 + un único operador no necesita más. Default es 10; bajar a 8 reduce algo el footprint. |
| `regulation.max_retries: 3` / `find_time: 2m` / `ban_time: 5m` | 3 fallos en 2 min → ban de 5 min. Suficiente contra fuerza bruta humana. Los logs de Authelia los recoge Fail2ban en [`02-fail2ban.md`](./02-fail2ban.md) §X para ban más agresivo a nivel de red. |
| `storage.local.path: /config/db.sqlite3` | Justificado en §0 punto 5. |
| `notifier.filesystem.filename: /config/notifications.txt` | Justificado en §0 punto 7. |

### 5.2. Templating (`{{ env "LAN_DOMAIN" }}`)

Authelia 4.38 procesa el `configuration.yml` con un motor de templates Go. La función `env "X"` lee la variable de entorno `X` del contenedor. Esto permite que el `configuration.yml` versionable no contenga `lan` hardcoded; cambiar `LAN_DOMAIN=home` en el `.env` y reiniciar Authelia migra todas las cookies y reglas.

> Cuidado: el motor de templates **solo** se aplica a `configuration.yml`, **no** a `users_database.yml`. Por eso allí los emails se escriben literalmente (`admin@homelab.local`, no `admin@{{ env "LAN_DOMAIN" }}`).

---

## 6. `users_database.yml`

`~/homelab/stacks/auth/users_database.yml` — **versionado en git**, los hashes Argon2id no son reversibles a plaintext:

```yaml
# ~/homelab/stacks/auth/users_database.yml
# Hashes generados con:
#   docker run --rm authelia/authelia:4.38.17 \
#     authelia crypto hash generate argon2 --password '<password-fuerte>'
#
# El hash incluye salt y parámetros (no requiere config separada).

users:
  homelab:
    disabled: false
    displayname: "Operador Homelab"
    password: "$argon2id$v=19$m=65536,t=3,p=4$REPLACE_WITH_REAL_HASH"
    email: admin@homelab.local
    groups:
      - admin
```

### 6.1. Generar el hash del operador

```bash
# Genera el hash interactivamente (la imagen lo pedirá por stdin):
docker run --rm -it authelia/authelia:4.38.17 \
  authelia crypto hash generate argon2 \
    --variant argon2id \
    --iterations 3 \
    --memory 65536 \
    --parallelism 4 \
    --key-length 32 \
    --salt-length 16

# Salida esperada:
# Digest: $argon2id$v=19$m=65536,t=3,p=4$base64salt$base64hash
```

> **Comprueba** que los parámetros de `--iterations/--memory/--parallelism` coinciden con los de `configuration.yml` §5 fila `password.argon2`. Si no coinciden, Authelia **igual valida el hash** (los parámetros viven dentro del propio hash, son auto-descriptivos), pero **el rehash al primer login** lo regenera con los parámetros del config — comportamiento normal de Authelia.

Pegar el digest en `users_database.yml` reemplazando `REPLACE_WITH_REAL_HASH`.

### 6.2. Añadir más usuarios

Cada nuevo usuario es otro bloque bajo `users:`. Convención de grupos:

| Grupo | Quién | Qué ve |
|---|---|---|
| `admin` | Operador del homelab. Acceso completo. | Todos los servicios protegidos. |
| `family` | Familiares con login propio. | Subset declarado por servicio en `access_control.rules`. |
| `guest` | Acceso muy limitado (compartir Jellyfin). | Solo servicios de "consumo" sin admin. |

Ejemplo:

```yaml
users:
  homelab:
    disabled: false
    displayname: "Operador Homelab"
    password: "$argon2id$v=19$m=65536,t=3,p=4$..."
    email: admin@homelab.local
    groups: [admin]
  pareja:
    disabled: false
    displayname: "Pareja"
    password: "$argon2id$v=19$m=65536,t=3,p=4$..."
    email: pareja@homelab.local
    groups: [family]
```

Tras editar, no es necesario reiniciar (`watch: true` recarga el fichero al detectar el cambio). Validar en logs: `docker logs authelia | tail -20` debe mostrar `users database loaded with N users`.

---

## 7. `docker-compose.yml`

`~/homelab/stacks/auth/docker-compose.yml`:

```yaml
# ~/homelab/stacks/auth/docker-compose.yml
# Stack: auth (../02-docker/02-estructura-compose.md §1.1).
# Datos en /mnt/hd2t/services/auth/. Secretos en /mnt/hd2t/services/auth/secrets/.

name: auth

services:
  authelia:
    image: authelia/authelia:${AUTHELIA_IMAGE_TAG}
    container_name: authelia
    hostname: authelia
    restart: unless-stopped

    user: "${PUID}:${PGID}"

    env_file:
      - /mnt/hd2t/services/auth/.env
    environment:
      TZ: ${TZ}
      LAN_DOMAIN: ${LAN_DOMAIN}
      TS_DOMAIN: ${TS_DOMAIN}

      # Secretos — Authelia lee el contenido de cada fichero.
      AUTHELIA_JWT_SECRET_FILE: /secrets/jwt
      AUTHELIA_SESSION_SECRET_FILE: /secrets/session
      AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE: /secrets/storage_encryption
      AUTHELIA_SESSION_REDIS_PASSWORD_FILE: /secrets/redis_password
      AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE: /secrets/jwt

    volumes:
      # Configuración versionable, read-only.
      - type: bind
        source: ./configuration.yml
        target: /config/configuration.yml
        read_only: true
        bind:
          create_host_path: false
      - type: bind
        source: ./users_database.yml
        target: /config/users_database.yml
        read_only: true
        bind:
          create_host_path: false

      # Datos persistentes (db.sqlite3, notifications.txt) — escritura.
      - type: bind
        source: /mnt/hd2t/services/auth/authelia/config
        target: /config
        bind:
          create_host_path: false

      # Secretos — read-only.
      - type: bind
        source: /mnt/hd2t/services/auth/secrets
        target: /secrets
        read_only: true
        bind:
          create_host_path: false

    tmpfs:
      - /tmp:size=16m,mode=1700,uid=1000,gid=1000

    read_only: true

    networks:
      - homelab
      - auth_internal

    cap_drop:
      - ALL

    security_opt:
      - no-new-privileges:true

    healthcheck:
      test: ["CMD", "/app/healthcheck.sh"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

    depends_on:
      redis:
        condition: service_healthy

    labels:
      com.centurylinklabs.watchtower.enable: "false"
      homepage.group: "Seguridad"
      homepage.name: "Authelia"
      homepage.icon: "authelia.png"
      homepage.href: "https://auth.${LAN_DOMAIN}"
      homepage.description: "Portal SSO + 2FA"

  redis:
    image: redis:${REDIS_IMAGE_TAG}
    container_name: redis-auth
    hostname: redis
    restart: unless-stopped

    # `redis` user dentro de la imagen oficial (UID 999). No sobreescribir.

    env_file:
      - /mnt/hd2t/services/auth/.env
    environment:
      TZ: ${TZ}

    # Cargar el password desde el fichero al arranque.
    command:
      - "sh"
      - "-c"
      - 'exec redis-server --requirepass "$$(cat /run/secrets/redis_password)" --save "" --appendonly no --maxmemory 64mb --maxmemory-policy allkeys-lru'

    volumes:
      - type: bind
        source: /mnt/hd2t/services/auth/redis/data
        target: /data
        bind:
          create_host_path: false

      # Secreto: solo el redis_password (read-only).
      - type: bind
        source: /mnt/hd2t/services/auth/secrets/redis_password
        target: /run/secrets/redis_password
        read_only: true
        bind:
          create_host_path: false

    networks:
      - auth_internal

    cap_drop:
      - ALL

    security_opt:
      - no-new-privileges:true

    healthcheck:
      # Healthcheck con autenticación: el password viaja por argv solo dentro
      # del contenedor; nadie fuera lo ve.
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
  auth_internal:
    driver: bridge
    internal: true        # SIN ruta al exterior — solo intra-stack.
```

### 7.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `name: auth` | Coincide con el directorio del stack y con la fila §1.1 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). |
| `image: authelia/authelia:${AUTHELIA_IMAGE_TAG}` | Tag fijo desde el `.env`. Multi-arch oficial. |
| `container_name: authelia` / `hostname: authelia` | Caddy llama a `http://authelia:9091` por nombre Docker; sin `container_name` el nombre real sería `auth-authelia-1`. |
| `user: "${PUID}:${PGID}"` | Authelia oficial respeta el `user:` de Compose. Plantilla §6 de estructura-compose. |
| `env_file` ruta absoluta | No depende del CWD; el operador puede ejecutar `docker compose up` desde cualquier directorio si hace falta. |
| `environment.AUTHELIA_*_FILE` | Authelia 4.38 lee el contenido del fichero como valor del secreto. **No** se ponen los secretos crudos en `environment:` ni en `.env` — quedarían visibles a cualquiera con `docker inspect authelia`. |
| `AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE: /secrets/jwt` | Reusa el mismo `jwt_secret` para reset de password. Authelia 4.38 separó conceptualmente ambos jwts; en este homelab compartirlos no aumenta superficie (el reset es solo válido 5 min y va por notificador filesystem). |
| `volumes:` `configuration.yml` y `users_database.yml` RO | Cualquier cambio en el fichero versionable es propagado al contenedor; al ser RO, un proceso comprometido dentro del contenedor no puede sobreescribirlos. |
| `volumes:` `/mnt/hd2t/services/auth/authelia/config → /config` | Aquí escribe Authelia: `db.sqlite3`, `notifications.txt`. Como los ficheros RO se montan **encima** del directorio `/config`, un mismo `target` sirve a los dos casos. |
| `volumes:` `secrets → /secrets` RO | Los 4 secretos. RO defiende contra que un compromise del contenedor los modifique (rotación silenciosa). |
| `tmpfs: /tmp` | Authelia escribe lockfiles en `/tmp`. Necesario porque el FS root es `read_only`. 16 MiB son suficientes y aislados de hd2t. |
| `read_only: true` | Refuerza la postura: el binario no puede escribir fuera de `/config` (writable), `/tmp` (tmpfs) y los puntos de montaje específicos. |
| `networks: [homelab, auth_internal]` | `homelab` para que Caddy alcance `authelia:9091`. `auth_internal` para que Authelia alcance `redis:6379`. |
| `cap_drop: ALL` (sin `cap_add`) | Authelia no necesita capabilities especiales: bindea a `9091` (>1024), no toca raw sockets. |
| `security_opt: no-new-privileges:true` | Plantilla §6. |
| `healthcheck: /app/healthcheck.sh` | Script incluido en la imagen oficial; verifica `/api/health` con la cookie internal. Más robusto que `wget` directo. |
| `depends_on.redis.condition: service_healthy` | Authelia requiere Redis vivo y autenticando para cargar sesiones; sin esto, en un primer arranque Authelia podría intentar conectarse a Redis antes de que esté listo y entrar en bucle de retries. |
| `start_period: 30s` | Authelia tarda ~5 s en arrancar en ARM64 + el `validate-config` del binario; 30 s es holgura. |
| `labels.watchtower.enable=false` | Justificado en §0. |
| `redis:` `command` con `--requirepass "$$(cat ...)"` | Los `$$` escapan a `$` literal en Compose (no sustitución de variable de Compose) y dejan que el shell del contenedor sustituya `$(cat /run/secrets/redis_password)` al arrancar. **No** hay password en `docker inspect`: lo que se ve es el comando con el `cat`, no el contenido. |
| `redis:` `--save "" --appendonly no` | Sin persistencia: las sesiones son efímeras. Si Redis se reinicia, los usuarios re-loguean. **No** habilitar AOF: gastaría I/O en hd2t por sesiones que duran 1h. |
| `redis:` `--maxmemory 64mb --maxmemory-policy allkeys-lru` | 64 MiB sobran para todas las sesiones de un homelab. LRU evita OOM si por error se llena. |
| `redis:` healthcheck `redis-cli -a ... ping` | El password va a `redis-cli` por argv solo dentro del contenedor; el `printenv` desde fuera no lo expone. |
| `networks.auth_internal.internal: true` | **Aislamiento real**: `internal: true` desactiva la ruta NAT del bridge → Redis no tiene salida a internet ni recibe tráfico de fuera de la Pi. Es la versión "no-routable" que se quiere para una BD/cache de un único cliente. |

### 7.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/auth
docker compose --env-file /mnt/hd2t/services/auth/.env config >/dev/null \
  && echo "Compose OK"

# Validar el configuration.yml con Authelia sin desplegar:
docker run --rm \
  -v $(pwd)/configuration.yml:/config/configuration.yml:ro \
  -v $(pwd)/users_database.yml:/config/users_database.yml:ro \
  -e LAN_DOMAIN=lan -e TS_DOMAIN=tailnet.ts.net \
  -e AUTHELIA_JWT_SECRET_FILE=/dev/null \
  -e AUTHELIA_SESSION_SECRET_FILE=/dev/null \
  -e AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE=/dev/null \
  -e AUTHELIA_SESSION_REDIS_PASSWORD_FILE=/dev/null \
  authelia/authelia:${AUTHELIA_IMAGE_TAG:-4.38.17} \
  authelia validate-config --config /config/configuration.yml
# Esperado: "Configuration parsed and loaded successfully without errors."
```

> El validate **no** requiere los secretos reales (basta apuntar a `/dev/null`); valida estructura y referencias cruzadas dentro de `configuration.yml`.

---

## 8. Despliegue

### 8.1. Levantar el stack

```bash
cd ~/homelab/stacks/auth
docker compose --env-file /mnt/hd2t/services/auth/.env up -d
```

Salida esperada:

```
[+] Running 3/3
 ✔ Network auth_auth_internal   Created
 ✔ Container redis-auth         Started
 ✔ Container authelia           Started
```

### 8.2. Estado de los contenedores

```bash
docker compose ps
# Esperado:
# NAME         IMAGE                              STATUS                  PORTS
# authelia     authelia/authelia:4.38.17          Up X (healthy)
# redis-auth   redis:7.4-alpine                   Up X (healthy)
```

Si Authelia tarda en `(healthy)` o entra en `(unhealthy)`:

```bash
docker compose logs authelia | tail -50
docker compose logs redis    | tail -20
```

Eventos esperados en los logs de Authelia:

```
time=... level=info msg="Authelia v4.38.17 is starting"
time=... level=info msg="Loaded configuration from files"
time=... level=info msg="Storage schema is up to date"
time=... level=info msg="Listening for non-TLS connections on '0.0.0.0:9091'"
```

Eventos esperados en los logs de Redis:

```
... # Server initialized
... * Ready to accept connections tcp
```

### 8.3. Smoke test desde Caddy

```bash
# Caddy alcanza Authelia por nombre Docker:
docker exec caddy wget -qO- http://authelia:9091/api/health
# Esperado: {"status":"OK"}

# Authelia alcanza Redis (autenticado):
docker exec authelia sh -c 'echo "Authelia escucha en"; netstat -tln 2>/dev/null | grep 9091 || ss -tln | grep 9091 || true'
```

### 8.4. Smoke test desde el host

```bash
# Authelia NO debe ser alcanzable desde la IP del host:
curl -sf http://192.168.1.10:9091/api/health -m 2 ; echo "exit=$?"
# Esperado: exit=7 (connection refused) o exit=28 (timeout). Nunca 200.

# Caddy reverse_proxy http://authelia:9091 sí responde — pero el bloque
# auth.lan en Caddy aún no existe; lo añadimos en §9.
```

---

## 9. Integración con Caddy (`forward_auth`)

### 9.1. Añadir el snippet `authelia_proxy`

Crear `~/homelab/stacks/proxy/snippets/authelia_proxy` (en el stack `proxy`, no en `auth`):

```caddy
# ~/homelab/stacks/proxy/snippets/authelia_proxy
# Snippet reutilizable: aplica forward_auth a Authelia.
# Uso:
#   miservicio.{$LAN_DOMAIN} {
#       import lan_internal_tls
#       import security_headers
#       import authelia_proxy
#       reverse_proxy http://miservicio:PUERTO
#   }
(authelia_proxy) {
    forward_auth http://authelia:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
    }
}
```

Razones de cada directiva:

- **`uri /api/authz/forward-auth`**: endpoint canónico de Authelia 4.38 para integraciones forward-auth genéricas (declarado en `server.endpoints.authz.forward-auth` del `configuration.yml`). Caddy le pasa la URL original, los métodos y las cookies; Authelia responde 200 (con cabeceras Remote-*) si la sesión es válida, o 30x si hay que redirigir a `auth.lan` para login.
- **`copy_headers Remote-User Remote-Groups Remote-Email Remote-Name`**: estas cabeceras se inyectan al backend para SSO transparente. Servicios que entienden HTTP-auth (Nextcloud con app `user_oidc`/`user_saml` o `auth_basic`, Sonarr con `Authentication=External`, Bookstack con LDAP/SAML, etc.) las usan.

### 9.2. Activar el bloque `auth.lan` en el `Caddyfile`

Editar `~/homelab/stacks/proxy/Caddyfile` y descomentar (o añadir, si no existía) el bloque para `auth.lan`:

```caddy
# Authelia (../04-seguridad/01-authelia.md)
auth.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    reverse_proxy http://authelia:9091
}
```

**Importante**: este bloque **no** importa `authelia_proxy` (el portal mismo no se autoprotege; lo cubre la regla `bypass` de §5).

Asegurarse de que el snippet existe:

```bash
ls -la ~/homelab/stacks/proxy/snippets/authelia_proxy
```

Recargar Caddy sin downtime:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

### 9.3. Añadir el registro DNS local en Pi-hole

Pi-hole UI → **Local DNS** → **DNS Records** → añadir:

```
auth.lan → 192.168.1.10
```

Reload del DNS interno:

```bash
docker exec pihole pihole reloaddns
```

Verificar:

```bash
dig +short @192.168.1.241 auth.lan
# Esperado: 192.168.1.10
```

### 9.4. Probar el portal

Desde un cliente con `root.crt` instalado (§6.5 de [`../03-red/04-caddy.md`](../03-red/04-caddy.md)):

```
https://auth.lan
```

- Primera carga: pantalla de login de Authelia (tema dark).
- Introducir usuario `homelab` y password.
- Authelia pide registrar TOTP — escanear el QR con Aegis/Raivo. **Apuntar también la clave en texto** en el gestor de contraseñas: si se pierde el móvil sin backup, este es el único `recovery`.
- Introducir el primer código TOTP. Authelia confirma "Authentication successful".
- A partir de ahora, la cookie `*.lan` queda almacenada y los sucesivos logins son automáticos.

> **Si no llega el TOTP enrollment**: revisar el notificador. `notifier.filesystem` escribe el código de enrolamiento como un "email" en `/mnt/hd2t/services/auth/authelia/config/notifications.txt`. Pero el TOTP enrollment normalmente se muestra **directamente en pantalla** (QR + clave) — si por algún motivo no aparece, mirar ese fichero:
>
> ```bash
> sudo tail -f /mnt/hd2t/services/auth/authelia/config/notifications.txt
> ```

### 9.5. Proteger un servicio (ejemplo: Portainer)

Cuando se quiera proteger un servicio existente (aquí ejemplo con Portainer; cada doc de servicio dará el suyo), editar el bloque correspondiente del `Caddyfile`:

```caddy
# Antes (sin Authelia):
portainer.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    reverse_proxy https://portainer:9443 {
        transport http {
            tls
            tls_insecure_skip_verify
        }
    }
}

# Después (con Authelia):
portainer.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    import authelia_proxy        # <── nuevo
    reverse_proxy https://portainer:9443 {
        transport http {
            tls
            tls_insecure_skip_verify
        }
    }
}
```

Recargar Caddy:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Confirmar que la regla en `access_control.rules` de Authelia (§5) ya menciona `portainer.{{ env "LAN_DOMAIN" }}` con `policy: two_factor`. Si no, editar `configuration.yml`, recargar Authelia:

```bash
docker compose -f ~/homelab/stacks/auth/docker-compose.yml restart authelia
```

> Authelia tiene `watch: true` para `users_database.yml` pero **no** para `configuration.yml`. Cualquier cambio en el config exige reinicio.

Probar desde un cliente: navegar a `https://portainer.lan`. Resultado esperado: redirección a `https://auth.lan/?rd=https%3A%2F%2Fportainer.lan%2F`. Tras login + TOTP (si la sesión expiró), redirección de vuelta a Portainer.

---

## 10. Verificación

### 10.1. Contenedores sanos

```bash
docker compose -f ~/homelab/stacks/auth/docker-compose.yml ps
# STATUS de ambos: "Up X (healthy)".
```

### 10.2. Authelia escucha solo en redes Docker

```bash
sudo ss -ltn | awk '$4 ~ /:9091$/'
# Esperado: vacío (no se publica al host).

docker port authelia
# Esperado: vacío (sin port mappings).
```

### 10.3. Redis no es alcanzable desde fuera del stack

```bash
# Desde el host:
nc -zv 192.168.1.10 6379
# Esperado: Connection refused.

# Desde otro stack (homelab):
docker run --rm --network homelab alpine sh -c 'apk add -q redis && redis-cli -h redis ping' 2>&1 | head -3
# Esperado: error (no resuelve `redis`, o `Connection refused`).

# Desde Authelia (auth_internal):
docker exec authelia sh -c 'wget -qO- redis:6379 2>&1 | head -1' || true
# Authelia no tiene `redis-cli`, pero el TCP a redis:6379 sí abre. La conexión
# real con autenticación la hace Authelia internamente: lo verifica el log:
docker logs authelia 2>&1 | grep -i 'redis' | head -5
# Esperado: línea(s) confirmando "Redis Sentinel/Standalone" connected.
```

### 10.4. Health endpoint vía Caddy

```bash
docker exec caddy wget -qO- http://authelia:9091/api/health
# Esperado: {"status":"OK"}

# Vía la URL pública (con root.crt instalado en el host):
curl -fsS https://auth.lan/api/health
# Esperado: {"status":"OK"}
```

### 10.5. Cert hoja firmado por la CA interna

```bash
echo | openssl s_client -connect auth.lan:443 -servername auth.lan 2>/dev/null \
  | openssl x509 -noout -issuer -subject
# Esperado:
#   issuer=  CN = Caddy Local Authority - 2024 ECC Intermediate
#   subject= CN = auth.lan
```

### 10.6. Bypass del portal (la regla `bypass` funciona)

```bash
# Llamar al login page sin sesión:
curl -fsS -o /dev/null -w '%{http_code}\n' https://auth.lan
# Esperado: 200
```

### 10.7. Forward-auth deniega sin sesión

```bash
# Llamar al endpoint con un Original-URL apuntando a un host protegido:
curl -is "https://auth.lan/api/authz/forward-auth" \
     -H "X-Forwarded-Method: GET" \
     -H "X-Forwarded-Proto: https" \
     -H "X-Forwarded-Host: portainer.lan" \
     -H "X-Forwarded-Uri: /" | head -5
# Esperado: HTTP/2 401 (sin cookie de sesión válida).
```

### 10.8. Login + TOTP desde el navegador

Manual, con el cliente del operador. Tras completar §9.4:

- Navegar a un servicio protegido (ej. `https://portainer.lan` tras §9.5).
- Confirmar redirección a Authelia, login OK, TOTP OK, redirección de vuelta.
- Cerrar y reabrir el navegador (no clicar logout): la cookie persiste durante `expiration: 1h`.
- Esperar 16 minutos sin tocar el servicio: la cookie expira por `inactivity: 15m` y se redirige a Authelia al siguiente click. Confirmado el comportamiento.

### 10.9. Regulación: ban tras 3 fallos

```bash
# Desde un cliente, hacer 3 logins con password incorrecto a auth.lan.
# El 4º intento, aunque sea con password correcto, devuelve "Account locked".
# Esperar 5 min (`ban_time`) y vuelve a funcionar.

# Confirmar en logs:
docker logs authelia 2>&1 | grep -iE 'regulation|banned' | tail
# Esperado: línea con "user is banned for X minutes".
```

### 10.10. Persistencia tras reboot

```bash
sudo reboot
# (esperar a que vuelva)

docker compose -f ~/homelab/stacks/auth/docker-compose.yml ps
# Esperado: ambos contenedores (healthy).

# La sesión del operador en el navegador puede o no sobrevivir:
# - Si Redis se reinició (lo hace en cada reboot porque no hay AOF), la cookie
#   sigue válida pero la sesión en Redis no existe → next click redirige a auth.lan.
# - El login funciona sin reconfigurar TOTP: el secret está en db.sqlite3
#   cifrado con storage_encryption_key, que sobrevive en hd2t.
```

### 10.11. Lista de Verificación

Antes de pasar a [`02-fail2ban.md`](./02-fail2ban.md):

- [ ] `docker compose ps` en el stack `auth` → ambos `(healthy)`.
- [ ] `sudo ss -ltn | grep -E ':9091|:6379'` → vacío en el host.
- [ ] `https://auth.lan` carga la pantalla de login.
- [ ] `curl -fsS https://auth.lan/api/health` → `{"status":"OK"}`.
- [ ] El operador tiene su TOTP enrolado y puede loguearse end-to-end.
- [ ] El operador ha **anotado fuera del homelab** (gestor de contraseñas) la clave TOTP del setup, **no solo** el QR del móvil.
- [ ] Forward-auth a `auth.lan/api/authz/forward-auth` sin cookie devuelve 401.
- [ ] El bloque `auth.lan` está en `~/homelab/stacks/proxy/Caddyfile` y el snippet `authelia_proxy` está en `~/homelab/stacks/proxy/snippets/`.
- [ ] Pi-hole tiene el registro local `auth.lan → 192.168.1.10`.
- [ ] Tras `sudo reboot`, ambos contenedores arrancan y el portal sigue funcionando.
- [ ] `~/homelab/stacks/auth/{configuration.yml,users_database.yml,docker-compose.yml,.env.example,snippets-caddy/*}` versionados en git; **`.env` y `secrets/*` NO**.
- [ ] `/mnt/hd2t/services/auth/secrets/*` con permisos `600 homelab:homelab` y el directorio padre `700 homelab:homelab`.

---

## 11. Backup

Estrategia que se concretará en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md). Lo que **debe respaldarse** del stack `auth`:

| Ruta | Qué contiene | Frecuencia |
|---|---|---|
| `~/homelab/stacks/auth/configuration.yml` | Configuración íntegra de Authelia. | Versionado en git → `git push`. |
| `~/homelab/stacks/auth/users_database.yml` | Usuarios + hashes Argon2id. **NO contiene plaintext** pero sí información sensible (emails, displaynames). | Versionado en git en repo **privado**. Si el repo es público, mover a `/mnt/hd2t/services/auth/users_database.yml` y bind-mountarlo (perdiendo control de versiones para ese fichero). |
| `~/homelab/stacks/auth/docker-compose.yml`, `.env.example`, `snippets-caddy/` | Definición del stack y snippet de Caddy. | Idem versionado. |
| `/mnt/hd2t/services/auth/secrets/{jwt,session,storage_encryption,redis_password}` | **Críticos**: si se pierden, todos los TOTP se invalidan (storage_encryption es la llave AES-GCM que cifra los TOTP secrets en `db.sqlite3`). | **Diaria**, dentro del backup de Borg con cifrado fuerte. |
| `/mnt/hd2t/services/auth/authelia/config/db.sqlite3` | TOTP secrets cifrados, contadores de regulación, "remember-me" tokens. **Sin la `storage_encryption` no se puede leer**: ambos deben respaldarse juntos. | **Diaria**. |
| `/mnt/hd2t/services/auth/authelia/config/notifications.txt` | Histórico de "emails" del notificador filesystem. **No es backup-crítico** pero ayuda a auditoría. | Opcional. |
| `/mnt/hd2t/services/auth/redis/data/*` | Sesiones efímeras. **No backup**: pérdida = re-login del operador, sin más. | No backup. |
| `/mnt/hd2t/services/auth/.env` | Variables del stack. No contiene secretos. | Reconstruible desde `.env.example`. Opcional. |

Pre-backup hook (Borgmatic), opcional:

```yaml
# Pseudo-config; la real va en 07-backups/02-borgmatic.md.
before_backup:
  # Dump consistente de la SQLite de Authelia (es seguro hacer cp de SQLite con
  # journal_mode=DELETE en Authelia, pero un sqlite3 .dump es más auditable):
  - docker exec authelia sqlite3 /config/db.sqlite3 ".backup '/config/db.backup.sqlite3'"
  - cp /mnt/hd2t/services/auth/authelia/config/db.backup.sqlite3 \
       /mnt/hd2t/backups/dumps/authelia/db-$(date +%F).sqlite3
```

> **Lo crucial**: el par `(secrets/storage_encryption, db.sqlite3)`. Restaurar uno sin el otro = inutilizar el otro. Borgmatic los respalda en el mismo archivo y con la misma frecuencia.

---

## 12. Operaciones cotidianas

### 12.1. Añadir un usuario nuevo

1. Generar el hash:
   ```bash
   docker run --rm -it authelia/authelia:4.38.17 \
     authelia crypto hash generate argon2 --variant argon2id
   # Pega el password al prompt; saca el digest.
   ```
2. Añadir el bloque en `~/homelab/stacks/auth/users_database.yml`:
   ```yaml
   newuser:
     disabled: false
     displayname: "Nuevo Usuario"
     password: "$argon2id$..."
     email: nuevo@homelab.local
     groups: [family]
   ```
3. **No reiniciar**: `watch: true` recarga el fichero en <5 s. Verificar:
   ```bash
   docker logs authelia | tail -5
   # Esperado: "users database loaded with N users".
   ```
4. El nuevo usuario inicia sesión, registra su TOTP en el primer login.

### 12.2. Cambiar el password de un usuario

Misma vía: generar el hash nuevo, sustituir el campo `password` en `users_database.yml`. La sesión activa **no** se invalida; para forzar logout:

```bash
docker exec redis-auth redis-cli -a "$(sudo cat /mnt/hd2t/services/auth/secrets/redis_password)" \
  --scan --pattern 'authelia/*' | xargs -r docker exec -i redis-auth \
  redis-cli -a "$(sudo cat /mnt/hd2t/services/auth/secrets/redis_password)" del
```

> O sencillamente reiniciar Redis: `docker compose restart redis`. Las sesiones (efímeras) se borran y todos los usuarios re-loguean.

### 12.3. Resetear el TOTP de un usuario

```bash
# Vía CLI de Authelia (operador como admin):
docker exec authelia authelia storage user totp delete <username> \
  --config /config/configuration.yml \
  --encryption-key "$(sudo cat /mnt/hd2t/services/auth/secrets/storage_encryption)"
```

El usuario, al siguiente login, vuelve a enrolar TOTP.

### 12.4. Rotar un secreto

Para `jwt` y `session`:
1. Generar el nuevo: `openssl rand -hex 64 | sudo tee /mnt/hd2t/services/auth/secrets/jwt`.
2. Reiniciar Authelia: `docker compose restart authelia`.
3. Todos los usuarios pierden la sesión y deben re-loguearse. El TOTP **sigue funcionando** (no depende de jwt/session).

Para `storage_encryption` (procedimiento delicado):
1. Generar el nuevo en un fichero temporal:
   ```bash
   openssl rand -hex 64 > /tmp/new-storage-key
   ```
2. Re-cifrar la BD:
   ```bash
   docker exec authelia authelia storage encryption change-key \
     --config /config/configuration.yml \
     --encryption-key "$(sudo cat /mnt/hd2t/services/auth/secrets/storage_encryption)" \
     --new-encryption-key "$(cat /tmp/new-storage-key)"
   ```
3. Sustituir el fichero del secreto:
   ```bash
   sudo install -m 600 -o homelab -g homelab /tmp/new-storage-key \
     /mnt/hd2t/services/auth/secrets/storage_encryption
   shred -u /tmp/new-storage-key
   ```
4. Reiniciar Authelia.

Para `redis_password`:
1. Cambiar el fichero: `openssl rand -hex 64 | sudo tee /mnt/hd2t/services/auth/secrets/redis_password`.
2. Reiniciar **ambos** contenedores: `docker compose down && docker compose up -d`.
3. (Reiniciar solo `redis` no basta: `authelia` mantiene una conexión TCP autenticada con la clave anterior y entraría en loop.)

### 12.5. Revisar el "buzón" del notificador filesystem

```bash
sudo tail -F /mnt/hd2t/services/auth/authelia/config/notifications.txt
# Cada email aparece como un bloque separado por delimitadores.
# Útil para password reset, TOTP enrollment, etc.
```

### 12.6. Upgrade manual

```bash
# Antes de cambiar el tag, leer:
# https://www.authelia.com/configuration/migration/

# Editar /mnt/hd2t/services/auth/.env: AUTHELIA_IMAGE_TAG=4.39.x
sudo -u homelab sed -i 's|^AUTHELIA_IMAGE_TAG=.*|AUTHELIA_IMAGE_TAG=4.39.0|' \
  /mnt/hd2t/services/auth/.env

cd ~/homelab/stacks/auth
docker compose --env-file /mnt/hd2t/services/auth/.env pull authelia
docker compose --env-file /mnt/hd2t/services/auth/.env up -d --force-recreate authelia

# Verificar:
docker exec authelia authelia --version
docker logs authelia | tail -30
```

> Watchtower **no** actualiza Authelia automáticamente (`watchtower.enable: "false"`).

### 12.7. Activar WebAuthn (opt-in)

1. Descomentar el bloque `webauthn:` en `configuration.yml` (§5).
2. Reiniciar Authelia.
3. Cada usuario, en su perfil, puede registrar una llave Yubikey/Solokey/Passkey.
4. La política `two_factor` acepta indistintamente TOTP **o** WebAuthn como segundo factor.

> Documentar también en el gestor de contraseñas que **dos** llaves físicas distintas se han enrolado (perder una es OK; perder la única es bloqueo).

### 12.8. Activar SMTP (opt-in)

1. En `configuration.yml`, comentar `notifier.filesystem` y descomentar `notifier.smtp` con los datos del relay.
2. Si se usa un relay con auth, mover `username` y `password` a `/secrets/smtp_password` y crear su `_FILE` en `docker-compose.yml`:
   ```yaml
   AUTHELIA_NOTIFIER_SMTP_PASSWORD_FILE: /secrets/smtp_password
   ```
3. Reiniciar Authelia.

> Recordatorio: el homelab no expone puertos a internet. El SMTP relay tiene que ser un servicio externo (SMTP2GO, SES, Mailgun) accesible desde la Pi vía outbound; o un Postfix interno con relay autenticado al ISP.

---

## 13. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `docker compose up authelia` falla con `network homelab declared as external, but could not be found` | La red `homelab` no está creada. | Crearla según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2. |
| `authelia` arranca pero entra en `(unhealthy)`; logs muestran `failed to read /secrets/jwt: no such file` | Bind mount de `secrets/` mal montado o el fichero no existe. | `ls -la /mnt/hd2t/services/auth/secrets/` (debe haber 4 ficheros). Reaplicar §4. |
| `authelia` falla con `unable to connect to redis: NOAUTH` | Authelia y Redis usan distintos passwords. Comprobar que ambos leen `/run/secrets/redis_password` o `/secrets/redis_password` apuntando al **mismo fichero**. | Confirmar que `secrets/redis_password` es **un único fichero** (sin `\n` extra). `wc -c /mnt/hd2t/services/auth/secrets/redis_password` debe ser 129 (128 hex + `\n`). |
| `authelia` falla con `error decrypting database`: | El fichero `secrets/storage_encryption` se ha cambiado tras crear el `db.sqlite3`. | Restaurar el fichero original del backup, o (si no hay) borrar `db.sqlite3` y dejar que Authelia lo recree (pierde TOTP de todos los usuarios). |
| `https://auth.lan` da 502 Bad Gateway desde Caddy | Authelia no está sano o no resuelve por nombre. | `docker exec caddy wget -qO- http://authelia:9091/api/health`; si falla, revisar que Authelia está en la red `homelab` (`docker inspect authelia --format '{{json .NetworkSettings.Networks}}'`). |
| `https://auth.lan` resuelve pero da `connection refused` | Pi-hole no tiene el registro local o devuelve la IP equivocada. | `dig +short @192.168.1.241 auth.lan` debe ser `192.168.1.10`. Reaplicar §9.3. |
| `forward_auth` redirige al login pero, tras éxito, vuelve a redirigir al login (loop) | Cookie `*.lan` no se está estableciendo: el `domain` del config no coincide con el dominio real. | Verificar `session.cookies[0].domain` en `configuration.yml`. Debe ser **exactamente** `lan` (sin punto inicial, sin `https://`). Comparar con la URL del navegador. |
| El TOTP no se valida (Authelia dice "code invalid") | Skew de reloj entre el móvil y la Pi. | `timedatectl status` en la Pi (debe estar sincronizado con NTP, [`../01-sistema/02-configuracion-inicial.md`](../01-sistema/02-configuracion-inicial.md)). En el móvil, sincronizar la hora automáticamente. `totp.skew: 1` ya tolera ±30 s; un skew >60 s rompe TOTP siempre. |
| `users_database.yml` modificado, pero Authelia no reconoce al nuevo usuario | El reload watcher solo dispara con un cambio de `mtime` del fichero. | Tras editar, `touch ~/homelab/stacks/auth/users_database.yml`. O reiniciar Authelia. |
| `authelia` arranca con `validation: option 'access_control.rules[N]' missing required key 'domain'` | Sintaxis YAML incorrecta tras editar `configuration.yml`. | Validar con `authelia validate-config` (§7.2). El validador imprime el path exacto del error. |
| Caddy llama a `/api/authz/forward-auth` y recibe `405 Method Not Allowed` | Authelia 4.37 o anterior no expone ese endpoint con ese path. | Migrar a 4.38+ o usar `uri /api/verify?rd=https://auth.{$LAN_DOMAIN}/` en el snippet (sintaxis legacy). El snippet de §9.1 asume 4.38+. |
| Sesiones se invalidan tras cada `docker compose restart authelia` | `session.secret` ha cambiado entre arranques (no estable) o Redis no es persistente y se ha reiniciado. | `cat /mnt/hd2t/services/auth/secrets/session` debe devolver el mismo contenido cada vez. Si Redis se reinicia (no hay AOF), las sesiones **se pierden** por diseño (§7.1). El comportamiento esperado es: el operador re-loguea pero **no** vuelve a enrolar TOTP. |
| `notifications.txt` está vacío y el operador no recibe el QR de TOTP en pantalla | El QR del enrolment se muestra **siempre** en pantalla durante el primer login; `notifications.txt` solo registra password resets. | Confirmar que el flujo "primer login → TOTP setup" se completó sin cerrar la página. Si se cerró, en el portal de usuario (https://auth.lan, una vez logueado) hay opción "Set up two-factor authentication". |
| Tras un reboot, `redis-auth` arranca pero Authelia no llega a conectar | Race entre el `start_period` de Redis y el `depends_on.condition: service_healthy`. | Confirmar `docker compose ps`: si Redis tarda >5 s en `(healthy)`, subir `start_period` del healthcheck de Redis a 15 s en `docker-compose.yml`. |
| `docker exec redis-auth redis-cli ping` devuelve `NOAUTH Authentication required` | Comportamiento normal: Redis exige password. Usar `-a "$(cat ...secret)"`. | Ver §10.3. |
| Caddy reload tras añadir el snippet `authelia_proxy` falla con `unknown directive: forward_auth` | Caddy <2.7 no tiene `forward_auth` nativo (solo `reverse_proxy` + `handle_path`). | Confirmar `CADDY_IMAGE_TAG` ≥ 2.7. El doc de Caddy fija `2.8.4-alpine`, así que esto solo aplica si se ha bajado el tag. |
| Operador queda fuera del homelab (perdió el móvil con TOTP) | Sin recovery codes y sin segunda llave WebAuthn, el único acceso es el reset de TOTP por CLI desde la Pi. | `ssh` a la Pi; ejecutar §12.3 (`authelia storage user totp delete homelab`); volver a enrolar TOTP en el siguiente login. **Por eso** la lista de §10.11 exige anotar la clave TOTP en el gestor de contraseñas, no solo el QR. |

---

## Referencias

- [Authelia — Documentación oficial](https://www.authelia.com/)
- [Authelia — Get Started: Docker Compose](https://www.authelia.com/integration/deployment/docker/)
- [Authelia — Configuration reference](https://www.authelia.com/configuration/prologue/introduction/)
- [Authelia — Migration guide entre versiones](https://www.authelia.com/configuration/migration/)
- [Authelia — `access_control` (políticas y reglas)](https://www.authelia.com/configuration/security/access-control/)
- [Authelia — `session` (cookies, Redis)](https://www.authelia.com/configuration/session/introduction/)
- [Authelia — `authentication_backend.file`](https://www.authelia.com/configuration/first-factor/file/)
- [Authelia — `storage` (SQLite, encryption)](https://www.authelia.com/configuration/storage/introduction/)
- [Authelia — `notifier.filesystem`](https://www.authelia.com/configuration/notifications/filesystem/)
- [Authelia — Argon2 hashing y `crypto hash` CLI](https://www.authelia.com/configuration/first-factor/password-hash/)
- [Authelia — TOTP](https://www.authelia.com/configuration/second-factor/time-based-one-time-password/)
- [Authelia — WebAuthn](https://www.authelia.com/configuration/second-factor/webauthn/)
- [Authelia — Forward authentication (`/api/authz/forward-auth`)](https://www.authelia.com/integration/proxies/introduction/)
- [Authelia — Imagen Docker oficial (Docker Hub)](https://hub.docker.com/r/authelia/authelia)
- [Authelia — Source y CHANGES (GitHub)](https://github.com/authelia/authelia)
- [Caddy — `forward_auth` directive](https://caddyserver.com/docs/caddyfile/directives/forward_auth)
- [Redis — Imagen Docker oficial](https://hub.docker.com/_/redis)
- [OWASP — Argon2 password hashing recommendations](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html)
- [RFC 6238 — TOTP: Time-Based One-Time Password](https://datatracker.ietf.org/doc/html/rfc6238)
