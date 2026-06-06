# Authelia

## Descripción

**Authelia** aporta una capa centralizada de autenticación y autorización para servicios web del homelab. En esta Raspberry Pi 5 se usa como **middleware de SSO/2FA delante de Caddy**, de forma que ciertos paneles o aplicaciones queden accesibles solo tras autenticación fuerte y, cuando convenga, con segundo factor **TOTP**.

En este proyecto conviene fijar una decisión de diseño clara desde el principio:

- **Authelia se integra sobre la entrada HTTPS de Tailscale en Caddy**, no sobre los hosts HTTP `*.lan`
- el motivo es operativo: la arquitectura actual de [05-caddy.md](../03-red/05-caddy.md) usa **HTTP plano en LAN** y un único punto HTTPS en `https://pi-homelab.<tailnet>.ts.net`
- ese diseño encaja bien con Authelia si el portal y los servicios protegidos comparten **el mismo hostname HTTPS** y se publican por **subrutas**
- intentar hacer SSO limpio entre varios hosts `http://servicio.lan` no es la opción adecuada en esta fase

Traducción práctica de esta decisión:

- publica **Authelia** en `https://pi-homelab.<tailnet>.ts.net/authelia`
- protege con `forward_auth` solo las rutas remotas que realmente tengan sentido detrás de un proxy de autenticación
- deja fuera de Authelia los servicios cuyos clientes nativos puedan romperse con un login intermedio

Ejemplos razonables para proteger con Authelia:

- `Grafana`
- `Uptime Kuma`
- dashboards y paneles administrativos similares

Ejemplos que conviene evaluar con cuidado antes de poner detrás de Authelia:

- `Portainer`, porque en este repositorio hoy se documenta con acceso directo a `:9443` y no queda validado aquí su funcionamiento correcto bajo una subruta como `/portainer/`
- `Vaultwarden`, porque los clientes Bitwarden y extensiones no esperan una pantalla SSO intermedia
- servicios con aplicaciones móviles o clientes nativos que no funcionen bien en subruta o tras `forward_auth`

## Requisitos Previos

- Haber completado [03-seguridad-base.md](../01-sistema/03-seguridad-base.md).
- Haber completado [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber completado [04-tailscale.md](../03-red/04-tailscale.md).
- Haber completado [05-caddy.md](../03-red/05-caddy.md).
- Tener creada la red Docker externa `homelab_proxy`.
- Tener operativo el hostname MagicDNS del nodo, por ejemplo `pi-homelab.<tailnet>.ts.net`.
- Tener ya funcional el certificado de Tailscale usado por Caddy según [05-caddy.md](../03-red/05-caddy.md).
- Poder crear directorios persistentes en `/home/<user>/homelab/config/` y `/home/<user>/homelab/data/`.
- Tener decidido al menos un usuario inicial de Authelia y su grupo lógico, por ejemplo `admins`.
- Puertos necesarios en esta fase:
  - **ninguno publicado en el host** para Authelia
  - **`9091/tcp` solo interno entre Caddy y Authelia** dentro de Docker

## Docker Compose

Archivo: `/home/<user>/homelab/compose/auth-authelia/docker-compose.yml`

```yaml
name: auth-authelia

services:
  authelia:
    image: authelia/authelia:latest
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    volumes:
      - /home/<user>/homelab/config/authelia:/config
      - /home/<user>/homelab/data/authelia:/data
    networks:
      - homelab_proxy
    labels:
      - wud.watch=false

networks:
  homelab_proxy:
    external: true
    name: homelab_proxy
```

Archivo recomendado: `/home/<user>/homelab/compose/auth-authelia/.env`

```dotenv
TZ=Europe/Madrid
TAILSCALE_DOMAIN=pi-homelab.<tailnet>.ts.net
```

Notas sobre este Compose:

- **Authelia** no publica puertos en la IP del host
- **Caddy** lo alcanza por nombre de servicio interno `authelia:9091` a través de `homelab_proxy`
- la configuración editable queda fuera del contenedor en `/config`
- el estado persistente queda en `/data`
- se recomienda **no** configurar triggers de actualización automática de WUD para Authelia
- el valor de `TAILSCALE_DOMAIN` debe coincidir exactamente con el que uses en el stack de Caddy; aquí solo se usa como referencia documental, no como interpolación automática dentro de `configuration.yml`

## Configuración

### 1. Preparar directorios del stack

```bash
mkdir -p /home/<user>/homelab/compose/auth-authelia
mkdir -p /home/<user>/homelab/config/authelia
mkdir -p /home/<user>/homelab/data/authelia
chmod 700 /home/<user>/homelab/config/authelia
chmod 700 /home/<user>/homelab/data/authelia
```

Guarda en el primer directorio el `docker-compose.yml` y el `.env` del apartado anterior.

### 2. Generar secretos y hash de contraseña

Authelia necesita varios secretos persistentes. Genera los valores una sola vez y consérvalos en tu gestor de secretos:

```bash
openssl rand -hex 32
openssl rand -hex 32
openssl rand -hex 32
```

Usa esos tres valores para:

- `session.secret`
- `storage.encryption_key`
- `identity_validation.reset_password.jwt_secret`

Para generar el hash **Argon2id** del usuario inicial:

```bash
docker run --rm authelia/authelia:latest \
  authelia crypto hash generate argon2 \
  --password 'cambia-esta-contraseña'
```

Guarda la salida completa, por ejemplo una cadena que empieza por `argon2id$...` o `$argon2id$...`, y úsala en el fichero de usuarios.

### 3. Crear `users.yml`

Archivo: `/home/<user>/homelab/config/authelia/users.yml`

```yaml
users:
  admin:
    disabled: false
    displayname: "Administrador Homelab"
    password: "$argon2id$..."
    email: "admin@homelab.local"
    groups:
      - admins
```

Notas:

- define aquí solo los usuarios que vayas a administrar localmente con backend de fichero
- para un homelab pequeño, el backend `file` es suficiente y evita añadir LDAP u otro IdP
- usa contraseñas largas incluso aunque luego actives TOTP

### 4. Crear `configuration.yml`

Archivo: `/home/<user>/homelab/config/authelia/configuration.yml`

```yaml
theme: auto

server:
  address: 'tcp://:9091/authelia'
  endpoints:
    authz:
      forward-auth:
        implementation: 'ForwardAuth'

log:
  level: info
  format: text
  file_path: /data/authelia.log
  keep_stdout: true

totp:
  issuer: homelab-rpi5

authentication_backend:
  file:
    path: /config/users.yml

access_control:
  default_policy: deny
  rules:
    - domain: 'pi-homelab.<tailnet>.ts.net'
      resources:
        - '^/authelia(/.*)?$'
      policy: bypass
    - domain: 'pi-homelab.<tailnet>.ts.net'
      resources:
        - '^/$'
        - '^/homepage(/.*)?$'
      policy: one_factor

session:
  name: authelia_session
  secret: 'REEMPLAZAR_CON_SESSION_SECRET'
  same_site: lax
  inactivity: 30m
  expiration: 8h
  remember_me: 30d
  cookies:
    - domain: 'pi-homelab.<tailnet>.ts.net'
      authelia_url: 'https://pi-homelab.<tailnet>.ts.net/authelia'
      default_redirection_url: 'https://pi-homelab.<tailnet>.ts.net/'

regulation:
  max_retries: 5
  find_time: 10m
  ban_time: 1h

storage:
  encryption_key: 'REEMPLAZAR_CON_STORAGE_ENCRYPTION_KEY'
  local:
    path: /data/db.sqlite3

notifier:
  filesystem:
    filename: /data/notification.txt

identity_validation:
  reset_password:
    jwt_secret: 'REEMPLAZAR_CON_IDENTITY_VALIDATION_JWT_SECRET'
```

<!-- TODO: verificar en la documentación de cada servicio qué rutas HTTPS remotas están realmente adaptadas a subruta antes de añadir reglas `two_factor` adicionales como `/grafana` o `/uptime`. -->
<!-- TODO: verificar el hostname final del tailnet y sustituir de forma idéntica las tres apariciones de `pi-homelab.<tailnet>.ts.net` en `access_control` y `session.cookies`; si no coinciden exactamente con Caddy, el flujo de login fallará. -->

Qué fija esta configuración:

- el portal de Authelia se sirve bajo la subruta `/authelia`
- el backend de usuarios es local por fichero
- la política por defecto es `deny`
- `Homepage` queda con ejemplo de `one_factor`
- las rutas `two_factor` adicionales deben añadirse solo cuando su documento confirme compatibilidad real con subruta y con `forward_auth`
- las notificaciones se guardan en fichero local, útil para bootstrap y pruebas sin depender todavía de SMTP
- se genera además un log persistente en `/home/<user>/homelab/data/authelia/authelia.log`, necesario para la integración posterior con [02-fail2ban.md](02-fail2ban.md)
- la base de datos SQLite y el fichero de notificaciones viven en el **SSD NVMe**

Ajusta las `rules` a los servicios reales que publiques detrás del bloque HTTPS de Caddy. Si un servicio no está en una regla válida y llega a pasar por `forward_auth`, el resultado será denegación.

### 5. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/auth-authelia
docker compose config
docker compose run --rm authelia authelia config validate --config /config/configuration.yml
docker compose up -d
docker compose ps
```

Validaciones iniciales:

```bash
docker compose logs --tail 100 authelia
docker inspect "$(docker compose ps -q authelia)" --format '{{json .NetworkSettings.Networks}}'
ls -lh /home/<user>/homelab/data/authelia
```

El resultado esperado es este:

- el contenedor queda en estado `Up`
- aparece unido a la red `homelab_proxy`
- se crea `db.sqlite3` en `/home/<user>/homelab/data/authelia/`
- se crea o rota `authelia.log` en `/home/<user>/homelab/data/authelia/`
- no aparecen errores de parseo en `configuration.yml`

### 6. Integrar Authelia en Caddy con `forward_auth`

La base de Caddy ya se definió en [05-caddy.md](../03-red/05-caddy.md). Para integrar Authelia, actualiza el `Caddyfile` de ese documento con este patrón.

Añade un bloque reutilizable:

```caddyfile
(authelia_forward_auth) {
	forward_auth authelia:9091 {
		uri /api/authz/forward-auth?authelia_url=https://{$TAILSCALE_DOMAIN}/authelia
		copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
	}
}
```

Después, dentro del bloque HTTPS de `https://{$TAILSCALE_DOMAIN}`, publica primero el portal de Authelia y luego protege solo las rutas que lo necesiten:

```caddyfile
https://{$TAILSCALE_DOMAIN} {
	import common_proxy
	tls /certs/{$TAILSCALE_DOMAIN}.crt /certs/{$TAILSCALE_DOMAIN}.key

	@health path /healthz
	handle @health {
		respond "ok" 200
	}

	@authelia path /authelia /authelia/*
	handle @authelia {
		reverse_proxy authelia:9091
	}

	handle_path /homepage/* {
		import authelia_forward_auth
		reverse_proxy homepage:3000
	}

	handle {
		respond "Caddy activo." 200
	}
}
```

Notas importantes sobre este patrón:

- el portal de Authelia debe quedar accesible **antes** de aplicar `forward_auth` a otras rutas
- esta guía protege la entrada **HTTPS de Tailscale**, no los bloques `http://servicio.lan`
- los servicios protegidos deben funcionar correctamente en **subruta** o estar configurados para ello
- el ejemplo se limita a `Homepage` porque su publicación remota por subruta ya queda alineada con la documentación del repositorio; añade otros servicios solo cuando su documento confirme ese patrón
- `Portainer` no se incluye en este ejemplo porque su documento actual lo deja publicado en `:9443` y aquí no queda demostrada una adaptación correcta a `/portainer/`
- si un servicio no soporta bien subrutas, no lo metas aquí sin revisar primero su configuración

Tras modificar el `Caddyfile`:

```bash
cd /home/<user>/homelab/compose/infra-caddy
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
docker compose logs --tail 100 caddy
```

### 7. Primer acceso y alta del segundo factor

Abre en un navegador:

- `https://pi-homelab.<tailnet>.ts.net/authelia`

Inicia sesión con el usuario definido en `users.yml`.

En el primer acceso deja completado al menos esto:

- confirmar que la autenticación básica funciona
- registrar una aplicación TOTP en tu móvil o gestor compatible
- guardar los códigos o secretos de recuperación que decidas conservar
- comprobar que una ruta marcada como `two_factor` exige realmente el segundo factor

Como el `notifier` está en modo `filesystem`, las notificaciones de bootstrap o recuperación quedan en:

- `/home/<user>/homelab/data/authelia/notification.txt`

Eso es suficiente para una fase inicial. Cuando más adelante dispongas de SMTP o notificaciones externas, podrás sustituir este backend sin mover el resto del stack.

### 8. Política recomendada de uso

Para este homelab, la política más sensata es esta:

- usar **Authelia** para paneles administrativos y webs internas de bajo volumen
- exigir `two_factor` en consolas de infraestructura o servicios sensibles
- dejar fuera los servicios con clientes nativos que no toleren bien un proxy de autenticación
- evitar proteger todo "porque sí" si no se ha validado antes el flujo real de cada aplicación

Regla práctica:

- si el servicio se usa principalmente desde navegador y funciona bien en subruta, es buen candidato
- si el servicio tiene apps móviles, extensiones o clientes de escritorio dedicados, pruébalo antes de decidir

### 9. Verificaciones finales

Comprobaciones mínimas recomendadas:

```bash
docker compose -f /home/<user>/homelab/compose/auth-authelia/docker-compose.yml logs --tail 100 authelia
docker compose -f /home/<user>/homelab/compose/infra-caddy/docker-compose.yml logs --tail 100 caddy
curl -I https://pi-homelab.<tailnet>.ts.net/healthz
```

Y operativamente:

- `/authelia` carga el portal de login
- una ruta con política `one_factor` pide login pero no TOTP
- una ruta con política `two_factor` pide login y TOTP
- una ruta fuera de las reglas no queda accidentalmente abierta
- el fichero `notification.txt` se actualiza cuando Authelia emite un aviso

## Almacenamiento

Authelia usa solo almacenamiento en el **SSD NVMe**:

- Compose: `/home/<user>/homelab/compose/auth-authelia/docker-compose.yml`
- variables del stack: `/home/<user>/homelab/compose/auth-authelia/.env`
- configuración principal: `/home/<user>/homelab/config/authelia/configuration.yml`
- base de usuarios local: `/home/<user>/homelab/config/authelia/users.yml`
- datos persistentes: `/home/<user>/homelab/data/authelia/`
- base de datos SQLite: `/home/<user>/homelab/data/authelia/db.sqlite3`
- log persistente: `/home/<user>/homelab/data/authelia/authelia.log`
- notificaciones por fichero: `/home/<user>/homelab/data/authelia/notification.txt`

Notas operativas:

- `configuration.yml` y `users.yml` conviene versionarlos con mucho cuidado o excluirlos si contienen secretos reales
- si los versionas, separa las credenciales y secretos del contenido público
- ni la base de datos ni el fichero de notificaciones deben moverse a `hd2t` o `hd5t`

## Backup

Para poder reconstruir Authelia sin perder configuración ni estado, respalda como mínimo:

- `/home/<user>/homelab/compose/auth-authelia/docker-compose.yml`
- `/home/<user>/homelab/compose/auth-authelia/.env`
- `/home/<user>/homelab/config/authelia/configuration.yml`
- `/home/<user>/homelab/config/authelia/users.yml`
- `/home/<user>/homelab/data/authelia/authelia.log`
- `/home/<user>/homelab/data/authelia/db.sqlite3`
- `/home/<user>/homelab/data/authelia/notification.txt`

Además, conserva fuera del host:

- los tres secretos persistentes usados por Authelia
- el secreto o semilla TOTP del administrador si decides custodiarlo
- una nota clara de qué rutas del `Caddyfile` están protegidas por `forward_auth`

Orden de restauración recomendado:

- restaurar primero el `Caddyfile` y la red `homelab_proxy`
- restaurar después `configuration.yml`, `users.yml`, `.env` y `db.sqlite3`
- levantar `auth-authelia`
- validar `/authelia`
- por último, volver a activar o verificar las rutas protegidas en Caddy

## Referencias

- [02-estructura-compose.md](../02-docker/02-estructura-compose.md)
- [04-tailscale.md](../03-red/04-tailscale.md)
- [05-caddy.md](../03-red/05-caddy.md)
- [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md)
- [02-fail2ban.md](02-fail2ban.md)
- [01-vaultwarden.md](../11-productividad/01-vaultwarden.md)
- [Authelia Docs: Configuration](https://www.authelia.com/configuration/)
- [Authelia Docs: File Authentication Backend](https://www.authelia.com/configuration/first-factor/file/)
- [Authelia Docs: Session](https://www.authelia.com/configuration/session/introduction/)
- [Authelia Docs: Regulation](https://www.authelia.com/configuration/security/regulation/)
- [Authelia Docs: Caddy Integration](https://www.authelia.com/integration/proxies/caddy/)
- [Authelia Docs: Docker Image](https://www.authelia.com/integration/deployment/docker/)
- [Caddy Docs: `forward_auth`](https://caddyserver.com/docs/caddyfile/directives/forward_auth)
- [Docker Hub: `authelia/authelia`](https://hub.docker.com/r/authelia/authelia)
