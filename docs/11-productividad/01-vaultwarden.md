# Vaultwarden

## Descripción

**Vaultwarden** es el gestor de contraseñas autoalojado compatible con clientes **Bitwarden** para este homelab. En esta Raspberry Pi 5 se despliega como stack Docker propio, con toda su persistencia en el **SSD NVMe** y publicado **solo a través de Caddy**.

En este servicio conviene fijar dos decisiones de diseño desde el principio:

- la URL canónica del vault debe ser **HTTPS**, porque el web vault y varios flujos de cliente funcionan mejor en un contexto seguro
- en este proyecto la forma más limpia de conseguirlo sin exponer nada a internet es usar **Caddy + certificado de Tailscale** sobre `https://pi-homelab.<tailnet>.ts.net/vaultwarden/`
- **Vaultwarden no debe ponerse detrás de Authelia**; los clientes Bitwarden, las extensiones de navegador y algunas apps móviles esperan hablar directamente con el servidor del vault
- los datos persistentes, la base SQLite, adjuntos, `send` y logs viven en `/home/<user>/homelab/data/vaultwarden/` sobre el **SSD NVMe**
- el servicio no necesita publicar puertos en la IP del host; **Caddy** lo alcanza por red Docker interna

Esta guía asume precisamente esa topología: **LAN + Tailscale**, sin puertos abiertos en el router, sin exposición pública a internet y sin depender de Let's Encrypt.

## Requisitos Previos

- Haber completado [02-estructura-compose.md](/Users/x441425/workspace2/homelab/docs/02-docker/02-estructura-compose.md).
- Haber completado [04-tailscale.md](/Users/x441425/workspace2/homelab/docs/03-red/04-tailscale.md).
- Haber completado [05-caddy.md](/Users/x441425/workspace2/homelab/docs/03-red/05-caddy.md).
- Revisar [06-puertos-y-firewall.md](/Users/x441425/workspace2/homelab/docs/03-red/06-puertos-y-firewall.md) para mantener documentado el puerto lógico del servicio aunque aquí no se publique directamente.
- Tener creada la red Docker externa `homelab_proxy`.
- Tener operativo el hostname MagicDNS del nodo, por ejemplo `pi-homelab.<tailnet>.ts.net`.
- Tener ya emitido en Caddy el certificado de Tailscale para ese hostname.
- Haber revisado [02-fail2ban.md](/Users/x441425/workspace2/homelab/docs/04-seguridad/02-fail2ban.md) si quieres endurecer protección frente a fuerza bruta.
- Haber revisado [02-borgmatic.md](/Users/x441425/workspace2/homelab/docs/07-backups/02-borgmatic.md) si vas a incluir la base SQLite en copias automáticas.
- Puertos necesarios en esta fase:
  - **ninguno publicado en el host** para el contenedor de Vaultwarden
  - **`80/tcp` solo interno entre Caddy y Vaultwarden** dentro de Docker
  - **`443/tcp` en el host** lo publica Caddy, no Vaultwarden

## Docker Compose

Archivo: `/home/<user>/homelab/compose/productivity-vaultwarden/docker-compose.yml`

```yaml
name: productivity-vaultwarden

services:
  vaultwarden:
    image: vaultwarden/server:latest
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      DOMAIN: ${VAULTWARDEN_DOMAIN}
      SIGNUPS_ALLOWED: ${VAULTWARDEN_SIGNUPS_ALLOWED}
      INVITATIONS_ALLOWED: ${VAULTWARDEN_INVITATIONS_ALLOWED}
      ADMIN_TOKEN: ${VAULTWARDEN_ADMIN_TOKEN}
      LOG_FILE: /data/vaultwarden.log
      LOG_LEVEL: warn
      EXTENDED_LOGGING: "true"
      SHOW_PASSWORD_HINT: "false"
    volumes:
      - /home/<user>/homelab/data/vaultwarden:/data
    networks:
      - homelab_proxy
    labels:
      - com.centurylinklabs.watchtower.enable=false

networks:
  homelab_proxy:
    external: true
    name: homelab_proxy
```

Archivo recomendado: `/home/<user>/homelab/compose/productivity-vaultwarden/.env`

```dotenv
TZ=Europe/Madrid
VAULTWARDEN_DOMAIN=https://pi-homelab.<tailnet>.ts.net/vaultwarden/
VAULTWARDEN_SIGNUPS_ALLOWED=false
VAULTWARDEN_INVITATIONS_ALLOWED=false
VAULTWARDEN_ADMIN_TOKEN=REEMPLAZAR_CON_HASH_ARGON2_O_DEJAR_VACIO
```

Notas sobre este Compose:

- **Vaultwarden** no publica puertos en el host
- **Caddy** resuelve el acceso web y TLS mediante la red `homelab_proxy`
- `DOMAIN` debe coincidir con la URL real que usarán los clientes
- el `ADMIN_TOKEN` puede guardarse en texto plano, pero es preferible almacenarlo como **hash Argon2**
- el log persistente en `/data/vaultwarden.log` deja preparado el servicio para [02-fail2ban.md](/Users/x441425/workspace2/homelab/docs/04-seguridad/02-fail2ban.md)
- se recomienda **no** autoactualizar a ciegas un gestor de contraseñas con Watchtower

## Configuración

### 1. Preparar directorios del stack

```bash
mkdir -p /home/<user>/homelab/compose/productivity-vaultwarden
mkdir -p /home/<user>/homelab/data/vaultwarden
chmod 700 /home/<user>/homelab/data/vaultwarden
```

Guarda en el primer directorio el `docker-compose.yml` y el `.env` del apartado anterior.

### 2. Generar un `ADMIN_TOKEN` con hash

Si vas a habilitar el panel administrativo, genera un token fuerte y conviértelo a hash antes de ponerlo en `.env`:

```bash
docker run --rm vaultwarden/server:latest \
  /vaultwarden hash --password 'cambia-este-admin-token'
```

Puntos prácticos:

- guarda el valor generado completo en `VAULTWARDEN_ADMIN_TOKEN`
- si el hash contiene caracteres `$`, duplícalos en `.env` para que Docker Compose no intente expandir variables; por ejemplo `$$argon2id$$...`
- si no quieres usar el panel administrativo, deja `VAULTWARDEN_ADMIN_TOKEN` vacío y elimina la variable del Compose

### 3. Bootstrap inicial del primer usuario

En un despliegue nuevo tienes dos opciones razonables:

1. dejar temporalmente `VAULTWARDEN_SIGNUPS_ALLOWED=true`, crear tu cuenta principal y volverlo a `false`
2. mantener `SIGNUPS_ALLOWED=false` y crear o invitar usuarios desde `/vaultwarden/admin`

Para un homelab personal, la primera opción suele ser la más simple.

Flujo recomendado:

1. Cambia temporalmente `VAULTWARDEN_SIGNUPS_ALLOWED=true` en `.env`.
2. Arranca el stack.
3. Crea tu cuenta principal desde la web.
4. Vuelve a dejar `VAULTWARDEN_SIGNUPS_ALLOWED=false`.
5. Recrea el contenedor para que el cambio quede aplicado.

### 4. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/productivity-vaultwarden
docker compose config
docker compose up -d
docker compose ps
docker compose logs --tail=50 vaultwarden
```

Validaciones útiles:

```bash
docker network inspect homelab_proxy | grep vaultwarden
ls -lh /home/<user>/homelab/data/vaultwarden
ls -lh /home/<user>/homelab/data/vaultwarden/vaultwarden.log
```

En este punto **todavía no habrá acceso externo** hasta completar el bloque de Caddy del siguiente apartado.

### 5. Publicar Vaultwarden con Caddy

Edita `/home/<user>/homelab/config/caddy/Caddyfile` y añade el manejo específico de Vaultwarden dentro del bloque HTTPS del hostname Tailscale.

Patrón recomendado:

```caddyfile
https://{$TAILSCALE_DOMAIN} {
	import common_proxy
	tls /certs/{$TAILSCALE_DOMAIN}.crt /certs/{$TAILSCALE_DOMAIN}.key

	redir /vaultwarden /vaultwarden/ 308

	@vaultwarden_path path /vaultwarden/*
	handle @vaultwarden_path {
		reverse_proxy vaultwarden:80 {
			header_up X-Real-IP {remote_host}
		}
	}

	handle {
		respond "Caddy activo." 200
	}
}
```

Notas importantes para este servicio:

- usa una **subruta HTTPS** y deja esa URL como **canónica**
- no uses `http://vaultwarden.lan` como URL principal del vault; para Vaultwarden interesa priorizar el contexto seguro
- `header_up X-Real-IP {remote_host}` ayuda a que [02-fail2ban.md](/Users/x441425/workspace2/homelab/docs/04-seguridad/02-fail2ban.md) vea la IP real del cliente en el log
- si ya tienes otros `handle` en el bloque HTTPS, integra el matcher de Vaultwarden sin romper el orden existente

Aplica cambios:

```bash
cd /home/<user>/homelab/compose/infra-caddy
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose up -d
```

La URL operativa quedará así:

- web vault y API: `https://pi-homelab.<tailnet>.ts.net/vaultwarden/`
- panel admin: `https://pi-homelab.<tailnet>.ts.net/vaultwarden/admin`

### 6. Configuración inicial en la UI

Después del primer arranque:

1. Abre `https://pi-homelab.<tailnet>.ts.net/vaultwarden/`.
2. Crea la primera cuenta o entra con la ya creada.
3. Desactiva altas abiertas si las activaste solo para bootstrap.
4. Entra en `/vaultwarden/admin` si has configurado `ADMIN_TOKEN`.
5. Revisa que no haya avisos de URL base incorrecta ni errores de websockets en el navegador.

Ajustes recomendados en el panel admin:

- desactivar nuevas cuentas públicas de forma permanente
- revisar políticas de invitación si vas a crear más de un usuario
- no habilitar características experimentales salvo necesidad clara

### 7. Configurar clientes Bitwarden

Usa siempre la **misma URL base** en todos los clientes:

`https://pi-homelab.<tailnet>.ts.net/vaultwarden/`

Recomendación operativa:

- usa esa URL en la extensión de navegador
- usa esa URL en cliente móvil y de escritorio
- si un cliente concreto no tolera bien el cambio de servidor, cierra sesión y vuelve a añadir la cuenta desde cero
- no mezcles distintas URLs del mismo vault; evita combinar `http`, `https`, hostname LAN y hostname Tailscale para un mismo perfil

### 8. Endurecimiento con Fail2ban

Si vas a activar la protección contra fuerza bruta:

- conserva `LOG_FILE`, `LOG_LEVEL=warn` y `EXTENDED_LOGGING=true` como aparecen en este documento
- verifica que `/home/<user>/homelab/data/vaultwarden/vaultwarden.log` registra la IP real del cliente
- después sigue [02-fail2ban.md](/Users/x441425/workspace2/homelab/docs/04-seguridad/02-fail2ban.md) para crear filtros y activar el jail `vaultwarden`

Comprobación mínima recomendada:

```bash
grep -i "incorrect" /home/<user>/homelab/data/vaultwarden/vaultwarden.log | tail
```

## Almacenamiento

Rutas persistentes de este servicio:

- `/home/<user>/homelab/data/vaultwarden/` en el **SSD NVMe**

Contenido esperado dentro de esa ruta:

- `db.sqlite3` como base de datos principal
- `attachments/` para adjuntos de ítems
- `sends/` para Vaultwarden Send
- `icon_cache/` si activas cache de iconos
- `rsa_key*` y otros ficheros criptográficos generados por el servicio
- `vaultwarden.log` para logging persistente y Fail2ban

Política recomendada:

- todo el estado del servicio vive en el **SSD NVMe**
- no almacenes datos de Vaultwarden en `hd2t` ni `hd5t`
- mantén permisos restrictivos sobre el directorio porque contiene base de datos y material sensible

## Backup

Qué respaldar como mínimo:

- todo `/home/<user>/homelab/data/vaultwarden/`
- en particular `db.sqlite3`, `attachments/`, `sends/`, `rsa_key*` y `vaultwarden.log` si quieres conservar trazas de auditoría

Estrategia recomendada en este homelab:

- incluir el directorio completo en el backup de filesystem
- añadir además un bloque `sqlite_databases` para `db.sqlite3` siguiendo [02-borgmatic.md](/Users/x441425/workspace2/homelab/docs/07-backups/02-borgmatic.md)

Ejemplo de entrada útil en Borgmatic:

```yaml
sqlite_databases:
  - name: vaultwarden
    path: /source/homelab/data/vaultwarden/db.sqlite3
```

Antes de una restauración o copia manual consistente:

```bash
cd /home/<user>/homelab/compose/productivity-vaultwarden
docker compose stop vaultwarden
rsync -a /home/<user>/homelab/data/vaultwarden/ /ruta/de/backup/vaultwarden/
docker compose start vaultwarden
```

Buenas prácticas de restore:

- restaura siempre **base de datos y adjuntos juntos**
- si restauras `db.sqlite3`, restaura también `rsa_key*` y el resto del directorio salvo que tengas un motivo técnico para separar piezas
- prueba una restauración periódica en un directorio temporal o en una copia del stack antes de dar por válida la estrategia

## Referencias

- [Vaultwarden - Repositorio oficial](https://github.com/dani-garcia/vaultwarden)
- [Vaultwarden Wiki - Using Docker Compose](https://github.com/dani-garcia/vaultwarden/wiki/Using-Docker-Compose)
- [Vaultwarden Wiki - Proxy examples](https://github.com/dani-garcia/vaultwarden/wiki/Proxy-examples)
- [Vaultwarden Wiki - Enabling admin page](https://github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page)
- [Vaultwarden Wiki - Backing up your vault](https://github.com/dani-garcia/vaultwarden/wiki/Backing-up-your-vault)
- [Vaultwarden Wiki - Fail2Ban setup](https://github.com/dani-garcia/vaultwarden/wiki/Fail2Ban-Setup)
- [Imagen Docker `vaultwarden/server`](https://hub.docker.com/r/vaultwarden/server)
- [05-caddy.md](/Users/x441425/workspace2/homelab/docs/03-red/05-caddy.md)
- [02-fail2ban.md](/Users/x441425/workspace2/homelab/docs/04-seguridad/02-fail2ban.md)
- [02-borgmatic.md](/Users/x441425/workspace2/homelab/docs/07-backups/02-borgmatic.md)
