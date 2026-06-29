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
  - patrón oficial del proyecto: los upstreams apuntan a `127.0.0.1:<puerto>`
  - cada servicio downstream que se publique detrás de Caddy debe exponer su puerto en loopback con `127.0.0.1:<puerto_host>:<puerto_interno>`

## Docker Compose

Archivo: `/home/<user>/homelab/compose/infra-caddy/docker-compose.yml`

```yaml
name: infra-caddy

services:
  caddy:
    image: caddy:2.10-alpine
    restart: unless-stopped
    network_mode: host
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    volumes:
      - /home/<user>/homelab/config/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - /home/<user>/homelab/data/caddy/data:/data
      - /home/<user>/homelab/data/caddy/config:/config
      - /home/<user>/homelab/data/caddy/certs:/certs:ro
    labels:
      - wud.watch=true
```

Archivo recomendado: `/home/<user>/homelab/compose/infra-caddy/.env`

```dotenv
TZ=Europe/Madrid
TAILSCALE_DOMAIN=pi-homelab.<tailnet>.ts.net
```

Notas sobre este Compose:

- **Caddy** usa `network_mode: host` para compartir la pila de red del host y recibir la IP real de todos los clientes (LAN, Tailscale)
- sin `network_mode: host`, Docker reenvía las conexiones al contenedor mediante `docker-proxy`, que abre una nueva conexión TCP desde la IP del gateway Docker (`172.x.x.1`); la IP real del cliente se pierde irreversiblemente y servicios como [02-fail2ban.md](../04-seguridad/02-fail2ban.md) no pueden funcionar
- como consecuencia, Caddy **no está en ninguna red Docker** y no puede resolver nombres de contenedor como `jellyfin:8096`; los upstreams deben apuntar a `127.0.0.1:<puerto>`
- cada servicio downstream que deba publicarse por Caddy necesita exponer su puerto en `127.0.0.1` mediante `ports:` en su stack
- la red Docker compartida `homelab_proxy` puede seguir existiendo para comunicación entre otros stacks, pero **no** es el mecanismo base para que Caddy llegue a los servicios
- no se necesitan `ports:` en el bloque de Caddy porque el contenedor comparte directamente los puertos del host
- la configuración editable queda fuera del contenedor y puede versionarse en git
- los certificados emitidos con `tailscale cert` se montan en modo lectura desde `/home/<user>/homelab/data/caddy/certs/`

## Configuración

### 1. Preparar directorios del stack

```bash
mkdir -p /home/<user>/homelab/compose/infra-caddy
mkdir -p /home/<user>/homelab/config/caddy
mkdir -p /home/<user>/homelab/data/caddy/data
mkdir -p /home/<user>/homelab/data/caddy/config
mkdir -p /home/<user>/homelab/data/caddy/certs
```

Guarda el `docker-compose.yml` y el `.env` del apartado anterior.

### 2. Crear el `Caddyfile` versionable

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
	reverse_proxy 127.0.0.1:8096
}

http://navidrome.lan {
	import common_proxy
	reverse_proxy 127.0.0.1:4533
}

http://audiobookshelf.lan {
	import common_proxy
	reverse_proxy 127.0.0.1:13378
}

http://vaultwarden.lan {
	import common_proxy
	reverse_proxy 127.0.0.1:16006
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
	# - Jellyfin: conservar `/jellyfin` completo, sin `forward_auth` (usa su propio login)
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
- `Portainer` se publica en subruta `/portainer/` con un patrón `handle` + `route` que combina `forward_auth` y `uri strip_prefix`; la configuración validada se documenta en [../02-docker/03-portainer.md](../02-docker/03-portainer.md)

### 3. Generar el certificado HTTPS de Tailscale

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

### 4. Desplegar el stack

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

### 5. Publicar servicios downstream en `127.0.0.1`

Como Caddy usa `network_mode: host`, no está en ninguna red Docker y no puede resolver nombres de contenedor. Los upstreams del `Caddyfile` apuntan a `127.0.0.1:<puerto>`, por lo que cada servicio debe publicar su puerto en loopback.

Patrón mínimo en el stack del servicio:

```yaml
services:
  jellyfin:
    ports:
      - "127.0.0.1:8096:8096"
```

Con eso, Caddy alcanza el servicio en `127.0.0.1:8096`. El puerto **no** queda expuesto a la LAN porque se publica solo en loopback; el acceso externo sigue entrando únicamente a través de Caddy.

Reglas prácticas:

- usa siempre `127.0.0.1:<puerto>:<puerto_interno>` en los stacks downstream
- no publiques el mismo puerto en `0.0.0.0` si el acceso directo no es necesario
- si un servicio usa `network_mode: host` (como Home Assistant), Caddy ya lo alcanza directamente por su puerto en el host
- no uses `host.docker.internal` como upstream base de Caddy en este proyecto; con `network_mode: host`, el proxy ya alcanza directamente el host mediante `127.0.0.1`
- el acceso por nombre de contenedor a través de `homelab_proxy` no es necesario para Caddy, pero otros servicios pueden seguir usando esa red entre sí si la necesitan para comunicación interna (por ejemplo, Prometheus → Grafana)

### 6. Ajustar DNS local en Pi-hole

Para que el proxy funcione en la LAN, los nombres locales deben resolver a la IP del host Raspberry Pi, por ejemplo `192.168.1.10`.

Registros típicos:

| Nombre | Destino |
|--------|---------|
| `jellyfin.lan` | `192.168.1.10` |
| `navidrome.lan` | `192.168.1.10` |
| `audiobookshelf.lan` | `192.168.1.10` |
| `vaultwarden.lan` | `192.168.1.10` |

Esto encaja con lo definido en [02-pihole.md](02-pihole.md): Pi-hole resuelve los nombres internos y Caddy decide a qué upstream enviarlos.

### 7. Validaciones que conviene dejar hechas

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
- olvidar publicar un servicio en `127.0.0.1:<puerto>` y después no entender por qué Caddy devuelve `502`
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
