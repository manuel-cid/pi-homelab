# Caddy

## Descripción
Caddy será el **reverse proxy interno** del homelab. En esta fase escucha en la **IP principal de la Raspberry Pi** por `80/tcp` y `443/tcp`, mientras que **Pi-hole** y **Unbound** siguen usando una IP propia dentro de `homelab_macvlan`.

En este proyecto Caddy cumple cuatro funciones:

- terminar TLS para los dominios internos del homelab como `jellyfin.lan`
- enrutar cada hostname al servicio Docker correspondiente
- concentrar en un único punto de entrada la publicación web interna
- reutilizar un certificado emitido con `tailscale cert` para acceso remoto vía Tailscale sin abrir puertos en el router

La topología objetivo queda así:

```text
clientes LAN
   |
   v
Pi-hole resuelve *.lan -> 192.168.1.10
   |
   v
Caddy en la IP principal del host
   |
   v
servicios Docker en la red homelab_proxy
```

Y para acceso remoto:

```text
cliente con Tailscale
   |
   v
https://pi.tailnet.ts.net
   |
   v
Caddy usa un certificado emitido con tailscale cert
   |
   v
servicios internos detrás del proxy
```

Siguiendo el contrato de red definido en esta fase, esta guía usa como ejemplo:

- IP LAN principal de la Raspberry Pi: `192.168.1.10`
- Pi-hole: `192.168.1.241`
- Unbound: `192.168.1.242`
- nombre MagicDNS del nodo Tailscale: `pi.tailnet.ts.net`

Sustituye esos valores por los reales de tu red si usas otra numeración.

## Requisitos Previos
- Haber completado `docs/03-red/01-macvlan.md`.
- Haber completado `docs/03-red/02-pihole.md`.
- Haber completado `docs/03-red/03-unbound.md`.
- Haber leído `docs/03-red/05-tailscale.md` si vas a habilitar acceso remoto con Tailscale.
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Tener operativa en Pi-hole la resolución DNS local para nombres como `homelab.lan`, `jellyfin.lan`, `navidrome.lan`, `audiobookshelf.lan`, `calibre.lan` y `stash.lan`, todos apuntando a la IP LAN principal del host.
- Tener libres en la IP principal del host los puertos `80/tcp` y `443/tcp`.
- Tener claro que en este diseño **Caddy no va en macvlan**. Debe escuchar en la IP principal de la Raspberry Pi para que los nombres locales resueltos por Pi-hole apunten al reverse proxy.
- Tener o planificar una red Docker compartida entre Caddy y los servicios web que quieras publicar.
- Para el acceso remoto por Tailscale:
  - la opción recomendada es instalar Tailscale en el **host**
  - MagicDNS debe estar operativo
  - `tailscale cert` debe poder escribir los ficheros del certificado que montará Caddy
- Puertos implicados:
  - `80/tcp` en la IP principal del host
  - `443/tcp` en la IP principal del host
  - no se abre ningún puerto en el router ni se expone nada a internet

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/caddy/
├── compose.yaml
├── .env
├── Caddyfile
├── config/
└── data/
```

Fichero `.env` de ejemplo:

```dotenv
TZ=Europe/Madrid
TAILNET_FQDN=pi.tailnet.ts.net
TAILSCALE_CERT_DIR=/home/<usuario>/homelab/secrets/tailscale-certs
```

Fichero `compose.yaml`:

```yaml
name: caddy

services:
  caddy:
    container_name: caddy
    image: caddy:2-alpine
    hostname: caddy
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
      - ./config:/config
      - ${TAILSCALE_CERT_DIR}:/certs/tailscale:ro
    networks:
      - homelab_proxy

networks:
  homelab_proxy:
    external: true
    name: homelab_proxy
```

Fichero `Caddyfile`:

```caddyfile
{
  admin off
}

(common) {
  encode zstd gzip

  header {
    X-Content-Type-Options "nosniff"
    X-Frame-Options "SAMEORIGIN"
    Referrer-Policy "strict-origin-when-cross-origin"
  }

  log {
    output file /data/access.log {
      roll_size 10MiB
      roll_keep 5
      roll_keep_for 168h
    }
    format console
  }
}

homelab.lan {
  import common
  tls internal
  respond "Caddy operativo en la LAN" 200
}

jellyfin.lan {
  import common
  tls internal
  reverse_proxy jellyfin:8096
}

navidrome.lan {
  import common
  tls internal
  reverse_proxy navidrome:4533
}

audiobookshelf.lan {
  import common
  tls internal
  reverse_proxy audiobookshelf:80
}

calibre.lan {
  import common
  tls internal
  reverse_proxy calibre-web:8083
}

stash.lan {
  import common
  tls internal
  reverse_proxy stash:9999
}

# Bloque opcional para acceso remoto por Tailscale.
# Requiere haber emitido previamente el certificado en el host con tailscale cert.
{$TAILNET_FQDN} {
  import common
  tls /certs/tailscale/{$TAILNET_FQDN}.crt /certs/tailscale/{$TAILNET_FQDN}.key

  redir /jellyfin /jellyfin/ 308
  redir /navidrome /navidrome/ 308
  redir /audiobookshelf /audiobookshelf/ 308
  redir /calibre /calibre/ 308
  redir /stash /stash/ 308

  handle_path /jellyfin/* {
    reverse_proxy jellyfin:8096
  }

  handle_path /navidrome/* {
    reverse_proxy navidrome:4533
  }

  handle_path /audiobookshelf/* {
    reverse_proxy audiobookshelf:80
  }

  handle_path /calibre/* {
    reverse_proxy calibre-web:8083
  }

  handle_path /stash/* {
    reverse_proxy stash:9999
  }

  handle {
    respond "Rutas disponibles: /jellyfin /navidrome /audiobookshelf /calibre /stash" 200
  }
}
```

Despliegue:

```bash
docker network create homelab_proxy
mkdir -p /home/<usuario>/homelab/compose/caddy/{config,data}
mkdir -p /home/<usuario>/homelab/secrets/tailscale-certs
cd /home/<usuario>/homelab/compose/caddy
docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

Resultado esperado:

- Caddy escucha en la IP principal del host por `80/tcp` y `443/tcp`
- `https://homelab.lan` responde dentro de la LAN
- los nombres `*.lan` terminan TLS en Caddy y se enrutan al contenedor correspondiente
- la IP principal de la Raspberry Pi queda como punto único de entrada para los servicios web internos

## Configuración

### Objetivo final de esta guía

| Elemento | Estado esperado |
|---|---|
| DNS local de servicios | `*.lan` resuelto por Pi-hole hacia la IP LAN del host |
| Reverse proxy | Caddy en la IP principal del host |
| Red Docker compartida | `homelab_proxy` |
| TLS LAN | `tls internal` con CA local de Caddy |
| TLS Tailscale | certificado emitido con `tailscale cert` |
| Puertos publicados en host | `80/tcp` y `443/tcp` |
| Exposición a internet | ninguna |

### 1. Crear la red compartida del proxy

Caddy debe poder resolver por nombre a los contenedores backend. La forma más limpia es usar una red Docker dedicada y externa.

Crear la red una sola vez:

```bash
docker network create homelab_proxy
```

Validación:

```bash
docker network inspect homelab_proxy
```

Esta red se reutilizará después en los stacks de los servicios web.

### 2. Adjuntar los servicios que quieras publicar

Cada servicio publicado detrás de Caddy debe unirse también a `homelab_proxy`.

Patrón mínimo en otro stack:

```yaml
services:
  jellyfin:
    networks:
      - default
      - homelab_proxy

networks:
  homelab_proxy:
    external: true
    name: homelab_proxy
```

Con eso, Caddy podrá resolver `jellyfin`, `navidrome`, `audiobookshelf`, `calibre-web` o `stash` por nombre Docker y enviarles tráfico sin publicar sus puertos directamente en el host.

Para el estado final de este homelab conviene dejar **Caddy como punto único de entrada** para los servicios web. Si un servicio sigue publicando puertos en la Raspberry Pi durante una migración, documenta ese estado temporal y elimínalo cuando valides el proxy.

### 3. Validar y arrancar Caddy

Antes de dar por bueno el stack, valida la configuración renderizada:

```bash
cd /home/<usuario>/homelab/compose/caddy
docker compose config
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
```

Comprobar logs:

```bash
cd /home/<usuario>/homelab/compose/caddy
docker compose logs --tail=100 caddy
```

Si aparece un error de resolución del backend, normalmente significa una de estas dos cosas:

- el servicio todavía no está unido a `homelab_proxy`
- el nombre usado en `reverse_proxy` no coincide con el nombre real del servicio en Docker

### 4. Activar HTTPS interno en la LAN

Con `tls internal`, Caddy genera su propia CA local y emite certificados para los dominios `.lan`.

Ruta importante en el host tras el primer arranque:

```text
/home/<usuario>/homelab/compose/caddy/data/caddy/pki/authorities/local/root.crt
```

Ese certificado raíz debe importarse en los dispositivos cliente desde los que quieras evitar advertencias del navegador.

Recomendaciones prácticas:

- importarlo en tu portátil principal
- importarlo en el móvil si vas a abrir servicios internos desde la LAN
- documentar qué equipos confían en esa CA privada

Si no importas esa CA:

- la conexión seguirá cifrada
- el navegador mostrará advertencias porque la CA es privada y no pública

### 5. Generar el certificado remoto con `tailscale cert`

Para esta guía se recomienda instalar Tailscale en el **host** y dejar que Caddy monte solo los ficheros ya emitidos.

Ejemplo de generación inicial del certificado:

```bash
sudo mkdir -p /home/<usuario>/homelab/secrets/tailscale-certs
sudo tailscale cert \
  --cert-file /home/<usuario>/homelab/secrets/tailscale-certs/pi.tailnet.ts.net.crt \
  --key-file /home/<usuario>/homelab/secrets/tailscale-certs/pi.tailnet.ts.net.key \
  pi.tailnet.ts.net
```

Después:

- confirma que `TAILNET_FQDN` en `.env` coincide exactamente con el nombre emitido
- recrea el stack de Caddy si aún no estaba montando ese directorio
- prueba `https://pi.tailnet.ts.net` desde un cliente conectado a Tailscale

Comando útil tras renovar el certificado:

```bash
cd /home/<usuario>/homelab/compose/caddy
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Recomendación operativa:

- genera y renueva el certificado desde el host
- deja los ficheros en una ruta persistente fuera del repositorio
- monta esa ruta en modo solo lectura dentro del contenedor

### 6. Entender la diferencia entre LAN y Tailscale

En esta arquitectura conviven dos patrones distintos:

- **LAN**: nombres por servicio, por ejemplo `https://jellyfin.lan`
- **Tailscale**: nombre MagicDNS del nodo, por ejemplo `https://pi.tailnet.ts.net`

Para la LAN, el modelo ideal es por **hostnames** porque Pi-hole controla la resolución local.

Para Tailscale, el ejemplo de esta guía usa **rutas** bajo el host del nodo:

- `https://pi.tailnet.ts.net/jellyfin/`
- `https://pi.tailnet.ts.net/navidrome/`
- `https://pi.tailnet.ts.net/audiobookshelf/`
- `https://pi.tailnet.ts.net/calibre/`
- `https://pi.tailnet.ts.net/stash/`

Esto evita depender de DNS extra dentro de la tailnet, pero obliga a revisar si cada aplicación tolera una base de ruta.

Ajustes habituales si usas subpaths remotos:

- Jellyfin: revisar el valor publicado hacia clientes y probar reproducción fuera de la LAN
- Navidrome: definir `ND_BASEURL=/navidrome`
- cualquier aplicación que no soporte subpath de forma limpia: publicarla por hostname propio o dejar su acceso remoto fuera de este patrón

Si más adelante prefieres acceso remoto por hostnames también en Tailscale, documenta esa decisión en `docs/03-red/05-tailscale.md` y ajusta el `Caddyfile` en consecuencia.

### 7. Troubleshooting básico

Comprobar conectividad LAN contra Caddy:

```bash
curl -kI https://homelab.lan
curl -kI https://jellyfin.lan
```

Comprobar resolución DNS local:

```bash
dig @192.168.1.241 homelab.lan
dig @192.168.1.241 jellyfin.lan
```

Comprobar que Caddy y el backend comparten la red esperada:

```bash
docker network inspect homelab_proxy
docker inspect caddy
```

Síntomas comunes:

- `502 Bad Gateway`: el backend no escucha en el puerto esperado o todavía no está listo
- `dial tcp: lookup jellyfin: no such host`: el backend no comparte la red `homelab_proxy`
- el navegador avisa sobre el certificado en `.lan`: falta instalar la CA local de Caddy en el dispositivo cliente
- `https://pi.tailnet.ts.net` falla pero `https://jellyfin.lan` funciona: suele indicar problema con Tailscale o con la emisión o renovación de `tailscale cert`, no con el proxy LAN

## Almacenamiento
Volúmenes usados por este stack:

- `./Caddyfile:/etc/caddy/Caddyfile:ro`
- `./data:/data`
- `./config:/config`
- `${TAILSCALE_CERT_DIR}:/certs/tailscale:ro`

Rutas recomendadas reales en el NVMe:

```text
/home/<usuario>/homelab/compose/caddy/compose.yaml
/home/<usuario>/homelab/compose/caddy/.env
/home/<usuario>/homelab/compose/caddy/Caddyfile
/home/<usuario>/homelab/compose/caddy/config/
/home/<usuario>/homelab/compose/caddy/data/
```

Ruta persistente recomendada para los certificados Tailscale:

```text
/home/<usuario>/homelab/secrets/tailscale-certs/
```

Qué queda guardado ahí:

- definición del stack Compose
- configuración declarativa del proxy
- CA local y certificados internos generados por Caddy
- estado interno y logs de acceso
- certificados y clave privada emitidos por `tailscale cert`

En este proyecto Caddy debe vivir en el **SSD NVMe**, no en los discos USB:

- forma parte de la infraestructura base de entrada web
- necesita acceso rápido y estable a su configuración y a su CA local
- no depende del contenido multimedia almacenado en `hd2t` o `hd5t`

## Backup
Respaldar como mínimo:

- el directorio `/home/<usuario>/homelab/compose/caddy/`
- el fichero `.env`
- el fichero `Caddyfile`
- los directorios `data/` y `config/`
- la ruta `/home/<usuario>/homelab/secrets/tailscale-certs/`

Elementos críticos del backup:

- definición de hostnames internos y backends
- CA local de Caddy y certificados internos ya emitidos
- configuración del proxy y de sus logs
- certificados de Tailscale y su clave privada

Antes de una copia importante o de una restauración conviene:

```bash
cd /home/<usuario>/homelab/compose/caddy
docker compose stop
```

Después del backup o restauración:

```bash
cd /home/<usuario>/homelab/compose/caddy
docker compose up -d
```

Si restauras desde cero, el orden lógico es:

1. restaurar `compose.yaml`, `.env`, `Caddyfile`, `config/`, `data/` y la ruta de certificados Tailscale
2. levantar Caddy
3. validar `docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile`
4. probar `https://homelab.lan`
5. probar `https://pi.tailnet.ts.net` si ya tienes Tailscale operativo

## Referencias
- https://caddyserver.com/docs/caddyfile/concepts
- https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
- https://caddyserver.com/docs/caddyfile/directives/tls
- https://hub.docker.com/_/caddy
- https://tailscale.com/kb/1081/magicdns
- https://tailscale.com/kb/1153/enabling-https
