# Caddy como Reverse Proxy Interno

## Descripción

Este documento cubre el despliegue de **Caddy** como reverse proxy del homelab para centralizar el acceso web a los servicios que corren en la Raspberry Pi.

En esta arquitectura, **Caddy** cumple dos funciones distintas:

- publicar servicios internos en **HTTP plano dentro de la LAN** usando nombres como `jellyfin.lan` o `vaultwarden.lan`
- ofrecer un **punto de entrada HTTPS solo para acceso remoto por Tailscale** usando el nombre MagicDNS del nodo, por ejemplo `pi-homelab.<tailnet>.ts.net`

La decisión operativa es deliberada:

- en la **LAN** se asume una red confiable y no se introduce una CA interna ni certificados locales
- fuera de la LAN, el acceso sigue limitado a **Tailscale** y el cifrado HTTPS se apoya en `tailscale cert`
- **Pi-hole** sigue resolviendo `*.lan` hacia la IP LAN del host
- la IP del host queda libre porque **Pi-hole** y **Unbound** ya viven en `dns_lan` con IP propia, según [01-macvlan.md](01-macvlan.md), [02-pihole.md](02-pihole.md) y [03-unbound.md](03-unbound.md)

## Requisitos Previos

- Haber completado [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber completado [02-pihole.md](02-pihole.md).
- Haber completado [04-tailscale.md](04-tailscale.md).
- Tener resueltos por Pi-hole los nombres LAN que apuntarán a la IP del host, por ejemplo:
  - `jellyfin.lan`
  - `navidrome.lan`
  - `audiobookshelf.lan`
  - `vaultwarden.lan`
- Tener disponible el hostname MagicDNS del nodo Tailscale, por ejemplo `pi-homelab.<tailnet>.ts.net`.
- Tener ya creada o prevista una estrategia de publicación remota por servicio. En este documento se deja preparada la base HTTPS común; las rutas o bloques concretos de cada servicio deben validarse en su documento específico.
- Reservar en el host los puertos que usará Caddy:
  - `80/tcp` para HTTP en LAN
  - `443/tcp` para HTTPS sobre Tailscale
- Confirmar que el router **no** tiene reglas de `port forwarding` hacia la Raspberry Pi.
- Tener claro cómo llegarán los upstreams a Caddy:
  - opción recomendada: los servicios se conectan también a la red Docker externa `homelab_proxy`
  - opción de transición: Caddy proxya a `host.docker.internal:<puerto>` si el servicio publica solo en el host

## Docker Compose

Archivo: `/home/<user>/homelab/compose/infra-caddy/docker-compose.yml`

```yaml
name: infra-caddy

services:
  caddy:
    image: caddy:2.10-alpine
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    ports:
      - "${CADDY_HTTP_PORT}:80"
      - "${CADDY_HTTPS_PORT}:443"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - homelab_proxy
    volumes:
      - /home/<user>/homelab/config/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - /home/<user>/homelab/data/caddy/data:/data
      - /home/<user>/homelab/data/caddy/config:/config
      - /home/<user>/homelab/data/caddy/certs:/certs:ro
    labels:
      - wud.watch=true

networks:
  homelab_proxy:
    external: true
    name: homelab_proxy
```

Archivo recomendado: `/home/<user>/homelab/compose/infra-caddy/.env`

```dotenv
TZ=Europe/Madrid
CADDY_HTTP_PORT=80
CADDY_HTTPS_PORT=443
TAILSCALE_DOMAIN=pi-homelab.<tailnet>.ts.net
```

Notas sobre este Compose:

- **Caddy** publica solo `80` y `443` en la IP del host
- la configuración editable queda fuera del contenedor y puede versionarse en git
- `homelab_proxy` permite que distintos stacks se conecten al proxy sin mezclar todas sus redes
- `host.docker.internal` queda disponible como ruta de compatibilidad para servicios que todavía no se hayan unido a `homelab_proxy`
- los certificados emitidos con `tailscale cert` se montan en modo lectura desde `/home/<user>/homelab/data/caddy/certs/`

## Configuración

### 1. Crear la red Docker compartida del proxy

Si aún no existe, créala una sola vez:

```bash
docker network create homelab_proxy
docker network ls | grep homelab_proxy
```

La política recomendada es esta:

- cada stack mantiene su red `default`
- solo los servicios que deban ser publicados por Caddy se unen además a `homelab_proxy`
- no metas en `homelab_proxy` servicios que no necesiten reverse proxy

### 2. Preparar directorios del stack

```bash
mkdir -p /home/<user>/homelab/compose/infra-caddy
mkdir -p /home/<user>/homelab/config/caddy
mkdir -p /home/<user>/homelab/data/caddy/data
mkdir -p /home/<user>/homelab/data/caddy/config
mkdir -p /home/<user>/homelab/data/caddy/certs
```

Guarda el `docker-compose.yml` y el `.env` del apartado anterior.

### 3. Crear el `Caddyfile` versionable

Archivo: `/home/<user>/homelab/config/caddy/Caddyfile`

```caddyfile
{
	admin off

	servers {
		trusted_proxies static private_ranges
	}
}

(common_proxy) {
	encode zstd gzip

	header {
		-Server
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
	}
}

http://jellyfin.lan {
	import common_proxy
	reverse_proxy jellyfin:8096
}

http://navidrome.lan {
	import common_proxy
	reverse_proxy navidrome:4533
}

http://audiobookshelf.lan {
	import common_proxy
	reverse_proxy audiobookshelf:80
}

http://vaultwarden.lan {
	import common_proxy
	reverse_proxy vaultwarden:80
}

https://{$TAILSCALE_DOMAIN} {
	import common_proxy
	tls /certs/{$TAILSCALE_DOMAIN}.crt /certs/{$TAILSCALE_DOMAIN}.key

	@health path /healthz
	handle @health {
		respond "ok" 200
	}

	# Las rutas o hostnames HTTPS de cada servicio se añaden de forma
	# incremental desde sus documentos específicos.
	#
	# No uses aqui ejemplos genericos con `handle_path` para servicios que
	# necesiten conservar el prefijo completo o una base URL explicita.
	# Ejemplos ya documentados en este repositorio:
	# - Vaultwarden: conservar `/vaultwarden` completo, sin `handle_path`
	# - Audiobookshelf: conservar `/audiobookshelf` completo, sin recortar prefijo
	# - Authelia: publicar antes `/authelia` y aplicar despues `forward_auth`
	# TODO: verificar cada ruta HTTPS remota contra el documento del servicio antes de activarla en produccion.

	handle {
		respond "Caddy activo. Revisa los documentos de cada servicio antes de anadir rutas HTTPS remotas." 200
	}
}
```

Este patrón deja dos rutas de acceso diferenciadas:

- **LAN**: un bloque `http://<servicio>.lan` por servicio
- **Tailscale**: un único hostname HTTPS del nodo como entrada común, sobre el que luego se añaden rutas o bloques concretos por servicio

Notas importantes sobre este diseño:

- los nombres `*.lan` deben resolver a la **IP LAN del host**, no a IPs de contenedores normales
- no todos los servicios toleran igual las **subrutas**; antes de activar una ruta HTTPS remota, valida en el documento del servicio si necesita conservar el prefijo, una `base URL` explícita o incluso un hostname dedicado
- si un servicio no tolera bien subrutas, mantenlo en `.lan` para la LAN hasta documentar un patrón remoto correcto
- `Portainer` queda fuera de este `Caddyfile` base porque su documento actual lo mantiene con acceso directo en `:9443` y no queda validado aquí su comportamiento correcto detrás del proxy

### 4. Generar el certificado HTTPS de Tailscale

Con **Tailscale instalado en el host**, genera el certificado para el nombre MagicDNS del nodo.

Ejemplo con el hostname del `.env`:

```bash
sudo tailscale cert \
  --cert-file /home/<user>/homelab/data/caddy/certs/pi-homelab.<tailnet>.ts.net.crt \
  --key-file /home/<user>/homelab/data/caddy/certs/pi-homelab.<tailnet>.ts.net.key \
  pi-homelab.<tailnet>.ts.net
```

Si prefieres evitar duplicar el nombre, exporta antes la variable:

```bash
export TAILSCALE_DOMAIN=pi-homelab.<tailnet>.ts.net
sudo tailscale cert \
  --cert-file /home/<user>/homelab/data/caddy/certs/${TAILSCALE_DOMAIN}.crt \
  --key-file /home/<user>/homelab/data/caddy/certs/${TAILSCALE_DOMAIN}.key \
  ${TAILSCALE_DOMAIN}
```

Reglas prácticas:

- ejecuta este comando en el **host**, no dentro del contenedor de Caddy
- el nombre debe coincidir exactamente con el MagicDNS del nodo
- si renuevas el certificado, reinicia o recrea Caddy para que recargue los nuevos ficheros

### 5. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/infra-caddy
docker compose config
docker compose up -d
docker compose ps
```

Validaciones iniciales:

```bash
docker compose logs --tail 50 caddy
ss -ltnp | grep -E ':80|:443'
curl -I -H 'Host: jellyfin.lan' http://127.0.0.1
```

El resultado esperado es:

- el contenedor queda en estado `Up`
- el host escucha en `80/tcp` y `443/tcp`
- Caddy carga el `Caddyfile` sin errores

### 6. Conectar servicios downstream a `homelab_proxy`

La forma recomendada de integrarlos es añadir la red externa `homelab_proxy` en cada stack que deba publicarse por Caddy.

Patrón mínimo:

```yaml
services:
  jellyfin:
    networks:
      - default
      - homelab_proxy

networks:
  homelab_proxy:
    external: true
```

Con eso, Caddy podrá alcanzar el servicio por nombre de contenedor o de servicio, por ejemplo `jellyfin:8096`.

Ruta de transición si todavía no quieres tocar el stack del servicio:

- publica el servicio en `127.0.0.1:<puerto>` en el host
- usa `host.docker.internal:<puerto>` como upstream en el `Caddyfile`

La primera opción es más limpia y escala mejor cuando el homelab crezca.

### 7. Ajustar DNS local en Pi-hole

Para que el proxy funcione en la LAN, los nombres locales deben resolver a la IP del host Raspberry Pi, por ejemplo `192.168.1.10`.

Registros típicos:

| Nombre | Destino |
|--------|---------|
| `jellyfin.lan` | `192.168.1.10` |
| `navidrome.lan` | `192.168.1.10` |
| `audiobookshelf.lan` | `192.168.1.10` |
| `vaultwarden.lan` | `192.168.1.10` |

Esto encaja con lo definido en [02-pihole.md](02-pihole.md): Pi-hole resuelve los nombres internos y Caddy decide a qué upstream enviarlos.

### 8. Validaciones que conviene dejar hechas

Desde la Raspberry Pi:

```bash
curl -I http://jellyfin.lan
curl -I http://navidrome.lan
curl -I https://pi-homelab.<tailnet>.ts.net/healthz
```

Desde otro cliente de la LAN:

- abrir `http://jellyfin.lan`
- abrir `http://navidrome.lan`
- comprobar que `vaultwarden.lan` resuelve a la IP del host

Desde otro cliente unido a la tailnet:

- abrir `https://pi-homelab.<tailnet>.ts.net/healthz`
- confirmar que el acceso remoto base funciona sin abrir puertos en el router
- validar después cada ruta o bloque HTTPS añadido siguiendo el documento específico del servicio correspondiente

Errores frecuentes que conviene evitar:

- publicar también `53` o `80` en la IP del host para Pi-hole
- usar `https://<servicio>.lan` sin haber montado una PKI interna para LAN
- asumir que todos los servicios soportan bien subrutas remotas bajo `https://pi-homelab.<tailnet>.ts.net/<servicio>/`
- dejar servicios fuera de `homelab_proxy` y después olvidar por qué Caddy no puede alcanzarlos
- abrir `80` o `443` en la WAN del router "por comodidad"

## Almacenamiento

En este despliegue, **Caddy** usa solo almacenamiento en el **SSD NVMe**:

- Compose: `/home/<user>/homelab/compose/infra-caddy/docker-compose.yml`
- variables del stack: `/home/<user>/homelab/compose/infra-caddy/.env`
- configuración versionable: `/home/<user>/homelab/config/caddy/Caddyfile`
- datos runtime de Caddy: `/home/<user>/homelab/data/caddy/data/`
- estado interno de Caddy: `/home/<user>/homelab/data/caddy/config/`
- certificados Tailscale montados en el contenedor: `/home/<user>/homelab/data/caddy/certs/`

Notas operativas:

- el **`Caddyfile`** sí conviene versionarlo en git
- los directorios `data/` y `config/` contienen estado runtime y no deberían mezclarse con la configuración declarativa
- los certificados emitidos por `tailscale cert` pueden regenerarse, pero guardarlos simplifica reinicios y restauraciones rápidas

## Backup

Para poder reconstruir Caddy sin perder la política de publicación del homelab, respalda como mínimo:

- `/home/<user>/homelab/compose/infra-caddy/docker-compose.yml`
- `/home/<user>/homelab/compose/infra-caddy/.env`
- `/home/<user>/homelab/config/caddy/Caddyfile`
- `/home/<user>/homelab/data/caddy/data/`
- `/home/<user>/homelab/data/caddy/config/`
- `/home/<user>/homelab/data/caddy/certs/`
- cualquier nota operativa sobre el hostname Tailscale real del nodo

Orden de restauración recomendado:

- restaurar primero la resolución local en Pi-hole y confirmar que `*.lan` apuntan a la IP del host
- restaurar después el `Caddyfile`, el Compose y el `.env`
- regenerar o restaurar los certificados `tailscale cert`
- levantar `infra-caddy`
- validar HTTP en LAN y HTTPS sobre Tailscale antes de exponer nuevos servicios detrás del proxy

## Referencias

- [02-estructura-compose.md](../02-docker/02-estructura-compose.md)
- [01-macvlan.md](01-macvlan.md)
- [02-pihole.md](02-pihole.md)
- [03-unbound.md](03-unbound.md)
- [04-tailscale.md](04-tailscale.md)
- [06-puertos-y-firewall.md](06-puertos-y-firewall.md)
- [01-authelia.md](../04-seguridad/01-authelia.md)
- [03-audiobookshelf.md](../09-multimedia/03-audiobookshelf.md)
- [01-vaultwarden.md](../11-productividad/01-vaultwarden.md)
- Caddy Docs: [Getting Started](https://caddyserver.com/docs/getting-started)
- Caddy Docs: [Caddyfile Concepts](https://caddyserver.com/docs/caddyfile/concepts)
- Caddy Docs: [reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- Caddy Docs: [Docker Image](https://hub.docker.com/_/caddy)
- Tailscale Docs: [MagicDNS](https://tailscale.com/docs/features/magicdns)
- Tailscale Docs: [TLS Certificates](https://tailscale.com/kb/1153/enabling-https)
