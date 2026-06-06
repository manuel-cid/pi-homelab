# Unbound como Resolver Recursivo

## Descripción

Este documento cubre el despliegue de **Unbound** como resolvedor DNS recursivo para el homelab, ejecutándose en la misma red **`dns_lan`** que **Pi-hole** y con **IP propia en la LAN**.

El objetivo de esta capa es separar responsabilidades:

- los clientes de la red siguen consultando solo a **Pi-hole**
- **Pi-hole** mantiene el filtrado, las estadísticas y el DNS local del homelab
- **Unbound** resuelve de forma recursiva, sin depender de resolutores públicos del ISP o de terceros
- ambos servicios usan IP fija en la macvlan definida en [01-macvlan.md](01-macvlan.md)

En este diseño, la ruta DNS final queda así:

- clientes LAN -> `192.168.1.194` -> **Pi-hole**
- **Pi-hole** -> `192.168.1.195#5335` -> **Unbound**
- **Unbound** -> servidores autoritativos de internet

Esto mantiene la IP LAN del host libre para **Caddy** y otros servicios, evita publicar `53` en la Raspberry Pi y encaja con el alcance del proyecto: **solo LAN + Tailscale**, sin abrir puertos al exterior.

## Requisitos Previos

- Haber completado [01-macvlan.md](01-macvlan.md).
- Haber completado [02-pihole.md](02-pihole.md).
- Haber completado [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber completado [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Tener creada la red Docker externa `dns_lan`.
- Tener reservada la IP `192.168.1.194` para Pi-hole, la IP `192.168.1.195` para Unbound y la IP `192.168.1.222` para `macvlan-shim`.
- Mantener la Raspberry Pi conectada por `eth0` y con el `macvlan-shim` operativo para validar desde el host.
- Tener disponibles `dig` y `curl` para las validaciones (`sudo apt install -y dnsutils curl` si todavía no están instalados).
- Puertos necesarios para Unbound en su IP macvlan:
  - `5335/tcp`
  - `5335/udp`
- Puertos no publicados en la IP del host:
  - `53/tcp`
  - `53/udp`
  - `5335/tcp`
  - `5335/udp`

## Docker Compose

Este documento asume que **Pi-hole** y **Unbound** comparten el stack `infra-pihole-unbound`. Si ya desplegaste Pi-hole con el Compose del documento anterior, sustituye ese archivo por este para dejar el upstream apuntando a Unbound.

Archivo: `/home/<user>/homelab/compose/infra-pihole-unbound/docker-compose.yml`

```yaml
name: infra-pihole-unbound

services:
  pihole:
    image: pihole/pihole:latest
    hostname: pihole
    restart: unless-stopped
    env_file:
      - .env
    depends_on:
      - unbound
    networks:
      dns_lan:
        ipv4_address: 192.168.1.194
    environment:
      TZ: ${TZ}
      FTLCONF_webserver_api_password: ${PIHOLE_WEBPASSWORD}
      FTLCONF_dns_listeningMode: 'LOCAL'
      FTLCONF_dns_upstreams: '192.168.1.195#5335'
      FTLCONF_dns_domain_name: 'lan'
      FTLCONF_dns_domain_local: 'true'
      FTLCONF_dns_revServers: |-
        true,192.168.1.0/24,192.168.1.1,lan
    volumes:
      - /home/<user>/homelab/data/pihole:/etc/pihole

  unbound:
    image: klutchell/unbound:latest
    hostname: unbound
    restart: unless-stopped
    env_file:
      - .env
    networks:
      dns_lan:
        ipv4_address: 192.168.1.195
    volumes:
      - /home/<user>/homelab/data/unbound:/etc/unbound

networks:
  dns_lan:
    external: true
    name: dns_lan
```

Archivo recomendado: `/home/<user>/homelab/compose/infra-pihole-unbound/.env`

```dotenv
TZ=Europe/Madrid
PIHOLE_WEBPASSWORD=<cambia-esta-contraseña>
```

Notas sobre este Compose:

- **Pi-hole** sigue siendo el único DNS anunciado a la LAN por DHCP
- **Unbound** no publica `ports:` porque ya tiene IP propia dentro de `dns_lan`
- el upstream de Pi-hole queda fijado en `192.168.1.195#5335`
- el fichero `unbound.conf` se versiona y se respalda junto al resto del stack

## Configuración

### 1. Preparar directorios y ficheros del stack

```bash
mkdir -p /home/<user>/homelab/compose/infra-pihole-unbound
mkdir -p /home/<user>/homelab/data/pihole
mkdir -p /home/<user>/homelab/data/unbound
sudo apt install -y dnsutils curl
curl -fsSL https://www.internic.net/domain/named.root \
  -o /home/<user>/homelab/data/unbound/root.hints
docker run --rm --entrypoint unbound-anchor \
  -v /home/<user>/homelab/data/unbound:/etc/unbound \
  klutchell/unbound:latest \
  -a /etc/unbound/root.key
```

Si ya existe el stack de Pi-hole, conserva su `.env` actual y reemplaza únicamente el `docker-compose.yml` por el bloque mostrado arriba.

### 2. Crear la configuración de Unbound

Archivo: `/home/<user>/homelab/data/unbound/unbound.conf`

```conf
server:
  verbosity: 0
  interface: 0.0.0.0
  port: 5335

  do-ip4: yes
  do-udp: yes
  do-tcp: yes
  do-ip6: no
  prefer-ip6: no

  root-hints: "/etc/unbound/root.hints"
  auto-trust-anchor-file: "/etc/unbound/root.key"

  harden-glue: yes
  harden-dnssec-stripped: yes
  qname-minimisation: yes
  aggressive-nsec: yes
  minimal-responses: yes
  hide-identity: yes
  hide-version: yes
  prefetch: yes
  prefetch-key: yes
  edns-buffer-size: 1232
  so-rcvbuf: 1m

  cache-min-ttl: 300
  cache-max-ttl: 86400
  msg-cache-size: 64m
  rrset-cache-size: 128m

  access-control: 127.0.0.0/8 allow
  access-control: 192.168.1.194/32 allow
  access-control: 192.168.1.222/32 allow

  private-address: 10.0.0.0/8
  private-address: 172.16.0.0/12
  private-address: 192.168.0.0/16
  private-address: 169.254.0.0/16
  private-address: fd00::/8
  private-address: fe80::/10
```

Puntos importantes de esta configuración:

- Unbound escucha en el puerto `5335`, no en `53`, para dejar clara su función interna como upstream de Pi-hole
- se desactiva IPv6 para simplificar el escenario inicial del homelab y evitar rutas inesperadas
- `root.hints` permite recursión completa sin depender de DNS públicos
- `root.key` activa la validación DNSSEC del resolvedor
- `access-control` limita las consultas al propio contenedor, a **Pi-hole** (`192.168.1.194`) y al `macvlan-shim` del host (`192.168.1.222`) para validaciones
- el cache se guarda en memoria del contenedor; el único fichero persistente aquí es la configuración

### 3. Levantar o recrear el stack

```bash
cd /home/<user>/homelab/compose/infra-pihole-unbound
docker compose config
docker compose up -d
docker compose ps
```

Si Pi-hole ya estaba desplegado antes de editar el Compose, el `up -d` recreará solo lo necesario para aplicar el nuevo upstream.

Validación inicial:

```bash
docker logs $(docker compose ps -q unbound) --tail 50
docker logs $(docker compose ps -q pihole) --tail 50
```

### 4. Validar Unbound directamente

Desde la Raspberry Pi:

```bash
dig @192.168.1.195 -p 5335 cloudflare.com
dig @192.168.1.195 -p 5335 github.com
dig @192.168.1.195 -p 5335 dnssec-failed.org
```

Qué debes esperar:

- las consultas normales deben responder correctamente desde `192.168.1.195#5335`
- `dnssec-failed.org` debe devolver **`SERVFAIL`**, señal de que la validación DNSSEC está funcionando

Si el host no alcanza `192.168.1.195`, vuelve a revisar el `macvlan-shim` descrito en [01-macvlan.md](01-macvlan.md).

### 5. Confirmar la integración con Pi-hole

Aunque el Compose ya deja el upstream configurado, conviene comprobarlo en la interfaz web de Pi-hole:

- entra en `http://192.168.1.194/admin/`
- revisa que el upstream efectivo sea `192.168.1.195#5335`
- confirma que no quedan resolutores públicos activos como fallback

Después valida desde el host:

```bash
dig @192.168.1.194 cloudflare.com
dig @192.168.1.194 jellyfin.lan
```

Interpretación:

- las consultas públicas deben salir de Pi-hole hacia Unbound
- los nombres internos como `jellyfin.lan` deben seguir resolviéndose en Pi-hole, no en Unbound

Regla operativa importante:

- el router debe anunciar **solo `192.168.1.194`**
- no anuncies `192.168.1.195` por DHCP
- los clientes nunca deben consultar Unbound directamente

### 6. Mantenimiento básico recomendado

Este stack no requiere ajustes frecuentes, pero sí conviene mantener dos rutinas simples:

- actualizar el fichero `root.hints` de vez en cuando, por ejemplo en revisiones trimestrales o cuando actualices el stack DNS
- revisar el Query Log de Pi-hole antes de tocar Unbound si una app deja de resolver; la mayoría de incidencias estarán en filtrado o DNS local, no en la capa recursiva

Para refrescar `root.hints` manualmente:

```bash
curl -fsSL https://www.internic.net/domain/named.root \
  -o /home/<user>/homelab/data/unbound/root.hints
cd /home/<user>/homelab/compose/infra-pihole-unbound
docker compose restart unbound
```

### 7. Errores frecuentes que conviene evitar

- anunciar `192.168.1.195` como DNS a los clientes en vez de `192.168.1.194`
- dejar en Pi-hole un DNS público como secundario, saltándose así la resolución recursiva local
- montar Unbound en una red Docker normal en vez de `dns_lan`
- publicar `5335` en la IP del host cuando no hace falta
- asumir que Unbound gestiona el DNS local del homelab; eso sigue siendo responsabilidad de Pi-hole

## Almacenamiento

En este despliegue, todo el estado persistente relevante vive en el **SSD NVMe**:

- Compose: `/home/<user>/homelab/compose/infra-pihole-unbound/docker-compose.yml`
- variables del stack: `/home/<user>/homelab/compose/infra-pihole-unbound/.env`
- datos de Pi-hole: `/home/<user>/homelab/data/pihole/`
- configuración de Unbound: `/home/<user>/homelab/data/unbound/unbound.conf`
- root hints de Unbound: `/home/<user>/homelab/data/unbound/root.hints`
- trust anchor DNSSEC: `/home/<user>/homelab/data/unbound/root.key`

Notas operativas:

- **Unbound** no necesita bases de datos ni volúmenes pesados; su estado real es la configuración
- el cache DNS de Unbound es efímero y se reconstruye tras reinicio
- mantener Pi-hole y Unbound en el SSD simplifica restauración, latencia y backup

## Backup

Para poder reconstruir la capa DNS recursiva sin perder configuración ni integración, respalda como mínimo:

- `/home/<user>/homelab/compose/infra-pihole-unbound/docker-compose.yml`
- `/home/<user>/homelab/compose/infra-pihole-unbound/.env`
- `/home/<user>/homelab/data/pihole/`
- `/home/<user>/homelab/data/unbound/unbound.conf`
- `/home/<user>/homelab/data/unbound/root.hints`
- `/home/<user>/homelab/data/unbound/root.key`
- cualquier nota operativa sobre la IP fija `192.168.1.195` y la configuración DHCP del router

Orden de restauración recomendado:

- recuperar `dns_lan` y `macvlan-shim` según [01-macvlan.md](01-macvlan.md)
- restaurar `unbound.conf`, `root.hints`, el Compose y el `.env`
- levantar el stack `infra-pihole-unbound`
- validar primero `dig @192.168.1.195 -p 5335 cloudflare.com`
- validar después `dig @192.168.1.194 cloudflare.com`
- solo al final revisar que el router sigue anunciando `192.168.1.194` como DNS

## Referencias

- [01-macvlan.md](01-macvlan.md)
- [02-pihole.md](02-pihole.md)
- [06-puertos-y-firewall.md](06-puertos-y-firewall.md)
- Pi-hole Docs: [Recursive DNS Server / Unbound](https://docs.pi-hole.net/guides/dns/unbound/)
- Pi-hole Docs: [Docker](https://docs.pi-hole.net/docker/)
- NLnet Labs: [Unbound Documentation](https://unbound.docs.nlnetlabs.nl/)
- Docker Hub: [klutchell/unbound](https://hub.docker.com/r/klutchell/unbound)
- InterNIC: [named.root](https://www.internic.net/domain/named.root)
