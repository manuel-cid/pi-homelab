# Authelia

## Descripción
**Authelia** será la capa de autenticación centralizada del homelab. En esta arquitectura actúa como **portal SSO** y como **middleware de autorización** delante de Caddy para exigir login y **2FA** antes de permitir el acceso a servicios sensibles como **Nextcloud**, **Vaultwarden** o paneles de administración.

En este proyecto Authelia no se expone directamente con un puerto propio en el host. Se publica **solo detrás de Caddy** y se integra mediante `forward_auth`, de modo que:

- Caddy sigue siendo el único punto de entrada HTTPS del homelab
- Authelia valida la sesión del usuario antes de reenviar la petición al backend
- los servicios pueden recibir cabeceras como `Remote-User` o `Remote-Email` si más adelante quieres aprovechar SSO por cabeceras
- el segundo factor recomendado para esta fase es **TOTP** con una app tipo Aegis, 2FAS, Authy o Google Authenticator

Decisión importante de naming en esta fase:

- para que la cookie de sesión funcione bien entre varios servicios, conviene usar un **dominio padre común**
- en esta guía se usará `homelab.lan` como raíz compartida
- el portal será `auth.homelab.lan`
- los servicios protegidos deben quedar como `nextcloud.homelab.lan`, `vaultwarden.homelab.lan`, `bookstack.homelab.lan`, etc.

Si mantienes nombres aislados como `jellyfin.lan`, `vaultwarden.lan` o `nextcloud.lan`, la experiencia SSO queda peor resuelta y obliga a replantear la política de cookies.

En cuanto al acceso remoto, la recomendación para los servicios protegidos por Authelia es que los clientes Tailscale sigan usando **los mismos FQDN internos** del homelab y no únicamente rutas tipo `https://pi.tailnet.ts.net/<servicio>/`. Así mantienes una única política de cookies y una experiencia de login coherente.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/03-red/04-caddy.md`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres acceder también por VPN mesh.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener resuelto en Pi-hole o en tu DNS local el nuevo esquema de nombres compartidos apuntando a la IP LAN principal del host:
  - `auth.homelab.lan`
  - `homepage.homelab.lan`
  - `nextcloud.homelab.lan`
  - `vaultwarden.homelab.lan`
  - y cualquier otro servicio que vayas a proteger
- Tener sincronización horaria correcta en la Raspberry Pi. TOTP depende de que la hora del sistema sea razonablemente precisa.
- Tener claro qué servicios exigirán `one_factor` y cuáles `two_factor`.
- Si en Caddy configuras `trusted_proxies`, limítalo solo a rangos realmente confiables. En este homelab Caddy suele ser el borde y no conviene ampliar esa confianza sin necesidad.
- Puertos implicados en esta fase:
  - `9091/tcp` solo dentro de Docker entre Caddy y Authelia
  - `80/tcp` y `443/tcp` siguen siendo los únicos puertos publicados en el host, a través de Caddy

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/authelia/
├── compose.yaml
├── .env
├── config/
│   ├── configuration.yml
│   └── users_database.yml
└── secrets/
    ├── session_secret.txt
    ├── storage_encryption_key.txt
    └── identity_validation_reset_password_jwt_secret.txt
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000
AUTHELIA_IMAGE=authelia/authelia:latest
```

Fichero `compose.yaml`:

```yaml
name: authelia

services:
  authelia:
    container_name: authelia
    image: ${AUTHELIA_IMAGE}
    user: "${PUID}:${PGID}"
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      AUTHELIA_SESSION_SECRET_FILE: /secrets/session_secret.txt
      AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE: /secrets/storage_encryption_key.txt
      AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE: /secrets/identity_validation_reset_password_jwt_secret.txt
    expose:
      - "9091"
    volumes:
      - ./config:/config
      - ./secrets:/secrets:ro
    networks:
      - homelab_proxy
    security_opt:
      - no-new-privileges:true

networks:
  homelab_proxy:
    external: true
    name: homelab_proxy
```

Fichero `config/configuration.yml`:

```yaml
theme: 'auto'

server:
  address: 'tcp://0.0.0.0:9091'

log:
  level: 'info'
  format: 'text'
  file_path: '/config/authelia.log'
  keep_stdout: true

totp:
  issuer: 'homelab.lan'

authentication_backend:
  file:
    path: '/config/users_database.yml'
    watch: false
    password:
      algorithm: 'argon2'
      argon2:
        variant: 'argon2id'
        iterations: 3
        memory: 65536
        parallelism: 4
        key_length: 32
        salt_length: 16

access_control:
  default_policy: 'deny'
  rules:
    - domain: 'auth.homelab.lan'
      policy: 'bypass'
    - domain:
        - 'homepage.homelab.lan'
        - 'grafana.homelab.lan'
        - 'portainer.homelab.lan'
      subject:
        - 'group:admins'
      policy: 'two_factor'
    - domain:
        - 'nextcloud.homelab.lan'
        - 'vaultwarden.homelab.lan'
        - 'bookstack.homelab.lan'
        - 'linkding.homelab.lan'
        - 'mealie.homelab.lan'
      policy: 'two_factor'
    - domain:
        - 'jellyfin.homelab.lan'
        - 'navidrome.homelab.lan'
      policy: 'one_factor'

session:
  name: 'authelia_session'
  same_site: 'lax'
  inactivity: '15m'
  expiration: '1h'
  remember_me: '1M'
  cookies:
    - domain: 'homelab.lan'
      authelia_url: 'https://auth.homelab.lan'
      default_redirection_url: 'https://homepage.homelab.lan'

regulation:
  max_retries: 5
  find_time: '10m'
  ban_time: '1h'

storage:
  local:
    path: '/config/db.sqlite3'

notifier:
  filesystem:
    filename: '/config/notification.txt'

identity_validation:
  reset_password:
    jwt_lifespan: '15 minutes'
    jwt_algorithm: 'HS256'
```

Fichero `config/users_database.yml`:

```yaml
users:
  admin:
    displayname: 'Administrador Homelab'
    email: 'admin@homelab.lan'
    password: '<PEGA_AQUI_HASH_ARGON2ID>'
    groups:
      - 'admins'
      - 'homelab'
```

Preparación inicial del stack:

```bash
mkdir -p /home/<usuario>/homelab/compose/authelia/{config,secrets}
touch /home/<usuario>/homelab/compose/authelia/config/users_database.yml

openssl rand -hex 32 > /home/<usuario>/homelab/compose/authelia/secrets/session_secret.txt
openssl rand -hex 32 > /home/<usuario>/homelab/compose/authelia/secrets/storage_encryption_key.txt
openssl rand -hex 32 > /home/<usuario>/homelab/compose/authelia/secrets/identity_validation_reset_password_jwt_secret.txt

chmod 600 /home/<usuario>/homelab/compose/authelia/secrets/*.txt
chmod 600 /home/<usuario>/homelab/compose/authelia/config/users_database.yml

docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password 'CambiaEstaPassword'
```

Pega el hash resultante en `config/users_database.yml` y después despliega:

```bash
cd /home/<usuario>/homelab/compose/authelia
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f authelia
```

Resultado esperado:

- Authelia queda accesible solo para otros contenedores en `http://authelia:9091`
- se crea `db.sqlite3` en `./config/`
- se crea `notification.txt` en `./config/`
- se crea `authelia.log` en `./config/`, útil para depuración y para la integración posterior con Fail2ban
- el portal todavía no es accesible desde navegador hasta integrarlo en Caddy

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| Portal de autenticación | `https://auth.homelab.lan` |
| Middleware de protección | `forward_auth` de Caddy |
| Política por defecto | `deny` |
| 2FA recomendado | TOTP |
| Persistencia | SQLite + config en NVMe |
| Exposición directa del contenedor | ninguna |

### 1. Ajustar DNS y convención de dominios

Antes de tocar Caddy, fija una política simple:

- `auth.homelab.lan` para Authelia
- `homepage.homelab.lan` como redirección por defecto tras login
- `nextcloud.homelab.lan`, `vaultwarden.homelab.lan`, `bookstack.homelab.lan`, etc. para servicios protegidos

Todos esos nombres deben resolver a la IP LAN principal de la Raspberry Pi, que es donde escucha Caddy.

Si ya tenías servicios con nombres como `nextcloud.lan`, este es un buen momento para migrarlos al esquema `*.homelab.lan` al menos para los que quieras proteger con SSO.

### 2. Integrar el portal de Authelia en Caddy

Partiendo del `Caddyfile` documentado en `docs/03-red/04-caddy.md`, añade un bloque específico para el portal y un snippet reutilizable para `forward_auth`.

La integración preferida en Caddy es la básica con `forward_auth`. Si ya defines `authelia_url` y `default_redirection_url` en `session.cookies`, no necesitas añadir `authelia_url` como query string en cada `uri`.

Ejemplo:

```caddyfile
(authelia_forward_auth) {
  forward_auth authelia:9091 {
    uri /api/authz/forward-auth
    copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
  }
}

auth.homelab.lan {
  import common
  tls internal
  reverse_proxy authelia:9091
}

vaultwarden.homelab.lan {
  import common
  tls internal
  import authelia_forward_auth
  reverse_proxy vaultwarden:80
}

nextcloud.homelab.lan {
  import common
  tls internal
  import authelia_forward_auth
  reverse_proxy nextcloud:80
}

bookstack.homelab.lan {
  import common
  tls internal
  import authelia_forward_auth
  reverse_proxy bookstack:80
}
```

Puntos operativos:

- `auth.homelab.lan` debe quedar **sin** `forward_auth`
- Caddy y Authelia deben compartir la red `homelab_proxy`
- los servicios protegidos también deben estar conectados a esa red
- el backend no necesita exponer su puerto al host solo para hablar con Caddy
- si más adelante activas `trusted_proxies` en Caddy, no uses rangos amplios por comodidad; una configuración demasiado permisiva puede romper la confianza en la IP real del cliente

### 3. Caso especial de Nextcloud

En algunos despliegues conviene impedir que la cookie de sesión de Authelia llegue a Nextcloud. Si observas comportamiento extraño con cookies, usa esta variante:

```caddyfile
nextcloud.homelab.lan {
  import common
  tls internal

  forward_auth authelia:9091 {
    uri /api/authz/forward-auth
    copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
  }

  reverse_proxy nextcloud:80 {
    header_up Cookie "authelia_session=[^;]+" "authelia_session=_"
  }
}
```

Si Nextcloud funciona bien sin este ajuste, mantén la configuración simple.

### 4. Primera puesta en marcha del portal

Una vez reiniciado Caddy con la integración anterior, abre:

```text
https://auth.homelab.lan
```

Comprobaciones iniciales:

- el portal responde con la interfaz de Authelia
- el certificado es el emitido por la CA interna de Caddy
- `https://vaultwarden.homelab.lan` redirige al portal cuando no hay sesión
- tras autenticarte, vuelves al servicio solicitado

Logs útiles:

```bash
cd /home/<usuario>/homelab/compose/authelia
docker compose logs -f authelia

cd /home/<usuario>/homelab/compose/caddy
docker compose logs -f caddy
```

### 5. Alta del segundo factor TOTP

El flujo recomendado para esta fase es:

1. Entrar por primera vez con el usuario del fichero `users_database.yml`.
2. Abrir la sección de configuración del perfil en Authelia.
3. Registrar un dispositivo TOTP escaneando el QR con tu app de autenticación.
4. Verificar el código de seis dígitos.
5. Confirmar que un servicio marcado como `two_factor` exige el segundo factor.

Recomendaciones prácticas:

- registra al menos dos dispositivos o conserva un mecanismo de recuperación seguro
- usa 2FA obligatorio para todo lo que tenga credenciales, documentos o administración
- reserva `one_factor` solo para servicios con menor riesgo operativo o mejor UX multimedia

### 6. Política recomendada de acceso

Una política razonable para este homelab sería:

| Tipo de servicio | Política recomendada |
|---|---|
| Portal de Authelia | `bypass` |
| Paneles de administración | `two_factor` |
| Bóveda y nube personal | `two_factor` |
| Wikis y herramientas personales | `two_factor` |
| Multimedia de bajo riesgo | `one_factor` o incluso sin Authelia según preferencias |
| Todo lo no definido | `deny` |

Esta combinación evita dejar servicios expuestos por error y encaja bien con una futura capa adicional de baneo en `docs/04-seguridad/02-fail2ban.md`.

### 7. Consideraciones para acceso remoto por Tailscale

Con Authelia, lo más simple es que el cliente remoto siga usando los mismos dominios internos protegidos:

- `https://vaultwarden.homelab.lan`
- `https://nextcloud.homelab.lan`
- `https://bookstack.homelab.lan`

Eso implica que los clientes Tailscale deben poder resolver `homelab.lan` hacia el homelab, normalmente mediante:

- DNS de Pi-hole accesible desde Tailscale
- o una política de split DNS equivalente

Si prefieres mantener el acceso remoto únicamente por `https://pi.tailnet.ts.net/<ruta>/`, no mezcles esa topología con esta primera implantación de Authelia. En ese caso tendrías que diseñar también la política de cookies y de redirección para el dominio `pi.tailnet.ts.net`, lo cual complica innecesariamente esta fase.

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose | `/home/<usuario>/homelab/compose/authelia/` | SSD NVMe |
| Configuración principal | `/home/<usuario>/homelab/compose/authelia/config/configuration.yml` | SSD NVMe |
| Base de usuarios local | `/home/<usuario>/homelab/compose/authelia/config/users_database.yml` | SSD NVMe |
| Base SQLite | `/home/<usuario>/homelab/compose/authelia/config/db.sqlite3` | SSD NVMe |
| Log persistente | `/home/<usuario>/homelab/compose/authelia/config/authelia.log` | SSD NVMe |
| Notificaciones por fichero | `/home/<usuario>/homelab/compose/authelia/config/notification.txt` | SSD NVMe |
| Secretos | `/home/<usuario>/homelab/compose/authelia/secrets/*.txt` | SSD NVMe |

Notas de almacenamiento:

- todo el estado persistente de Authelia debe quedarse en el **NVMe**
- no hay ninguna razón para guardar datos de Authelia en `hd2t` o `hd5t`
- la base SQLite y los secretos son críticos para no perder sesiones, configuración y capacidad de recuperación
- si más adelante migras a SMTP, `notification.txt` dejará de ser relevante, pero durante el arranque inicial es útil para verificar el flujo de notificaciones

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/authelia
chmod 700 /home/<usuario>/homelab/compose/authelia/secrets
chmod 600 /home/<usuario>/homelab/compose/authelia/secrets/*.txt
```

## Backup
Conviene respaldar como mínimo:

- `/home/<usuario>/homelab/compose/authelia/compose.yaml`
- `/home/<usuario>/homelab/compose/authelia/.env`
- `/home/<usuario>/homelab/compose/authelia/config/configuration.yml`
- `/home/<usuario>/homelab/compose/authelia/config/users_database.yml`
- `/home/<usuario>/homelab/compose/authelia/config/db.sqlite3`
- `/home/<usuario>/homelab/compose/authelia/config/notification.txt`
- `/home/<usuario>/homelab/compose/authelia/secrets/`

No es necesario respaldar:

- la imagen `authelia/authelia`
- el contenedor recreable
- datos efímeros de memoria o sesiones activas en tiempo real

Estrategia práctica de restauración:

1. Restaurar el directorio completo del stack en el NVMe.
2. Verificar permisos de `config/` y `secrets/`.
3. Levantar Authelia con `docker compose up -d`.
4. Verificar después la integración desde Caddy y el acceso a `https://auth.homelab.lan`.

## Referencias
- Authelia Docs: Docker deployment  
  https://www.authelia.com/integration/deployment/docker/
- Authelia Docs: Caddy integration  
  https://www.authelia.com/integration/proxies/caddy/
- Authelia Docs: File authentication backend  
  https://www.authelia.com/configuration/first-factor/file/
- Authelia Docs: Session configuration  
  https://www.authelia.com/configuration/session/introduction/
- Authelia Docs: Reset password identity validation  
  https://www.authelia.com/configuration/identity-validation/reset-password/
- Authelia Docs: SQLite storage  
  https://www.authelia.com/configuration/storage/sqlite/
- Authelia Docs: File system notifier  
  https://www.authelia.com/configuration/notifications/file/
- Authelia Docs: File-based secrets  
  https://www.authelia.com/configuration/methods/secrets/
- Caddy Docs: `forward_auth`  
  https://caddyserver.com/docs/caddyfile/directives/forward_auth
- Docker Hub: `authelia/authelia`  
  https://hub.docker.com/r/authelia/authelia
