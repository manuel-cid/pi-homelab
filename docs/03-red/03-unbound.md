# Unbound

## Descripción
Unbound será el **resolver recursivo** del homelab. En esta fase se despliega en la misma red Docker `homelab_macvlan` que Pi-hole, con una **IP propia dentro de la LAN**, para que Pi-hole le reenvíe las consultas DNS como **upstream** sin depender del DNS del router ni de resolvers públicos de terceros.

En este proyecto el flujo DNS objetivo queda así:

```text
clientes LAN/Tailscale
        |
        v
Pi-hole (192.168.1.241)
        |
        v
Unbound (192.168.1.242:5335)
        |
        v
resolución recursiva en internet
```

Siguiendo el contrato de red definido en `docs/03-red/01-macvlan.md`, este documento usa como ejemplo:

- Pi-hole: `192.168.1.241`
- Unbound: `192.168.1.242`
- IP `macvlan-shim` del host: `192.168.1.248`
- IP LAN principal de la Raspberry Pi: `192.168.1.10`
- gateway/router: `192.168.1.1`

Sustituye esos valores por los reales de tu red si usas otra numeración.

## Requisitos Previos
- Haber completado `docs/03-red/01-macvlan.md`.
- Haber completado `docs/03-red/02-pihole.md`.
- Tener creada la red Docker externa `homelab_macvlan`.
- Tener libre y reservada la IP que usará Unbound dentro del bloque macvlan.
- Tener operativa la interfaz `macvlan-shim` en el host para poder probar el servicio desde la Raspberry Pi.
- Tener claro que en este diseño **Pi-hole sigue siendo el DNS que usan los clientes** y **Unbound no se publica como DNS directo de la LAN**.
- Puertos implicados:
  - `5335/tcp` y `5335/udp` en la IP dedicada de Unbound dentro de `homelab_macvlan`
  - no se publica ningún puerto nuevo en la IP principal del host

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/unbound/
├── compose.yaml
├── .env
└── unbound.conf
```

Fichero `.env` de ejemplo:

```dotenv
TZ=Europe/Madrid
UNBOUND_IP=192.168.1.242
```

Fichero `compose.yaml`:

```yaml
name: unbound

services:
  unbound:
    container_name: unbound
    image: mvance/unbound:latest
    hostname: unbound
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    volumes:
      - ./unbound.conf:/opt/unbound/etc/unbound/unbound.conf:ro
    networks:
      homelab_macvlan:
        ipv4_address: ${UNBOUND_IP}

networks:
  homelab_macvlan:
    external: true
    name: homelab_macvlan
```

Fichero `unbound.conf`:

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
  use-caps-for-id: no

  # Solo Pi-hole y el host mediante macvlan-shim deben consultar directamente a Unbound.
  access-control: 127.0.0.0/8 allow
  access-control: 192.168.1.241/32 allow
  access-control: 192.168.1.248/32 allow
  access-control: 0.0.0.0/0 refuse

  hide-identity: yes
  hide-version: yes
  harden-glue: yes
  harden-dnssec-stripped: yes
  qname-minimisation: yes
  prefetch: yes
  edns-buffer-size: 1232
  rrset-roundrobin: yes

  cache-min-ttl: 300
  cache-max-ttl: 14400
  num-threads: 2
  so-rcvbuf: 1m
  so-sndbuf: 1m

  private-address: 192.168.0.0/16
  private-address: 172.16.0.0/12
  private-address: 10.0.0.0/8
  private-address: fd00::/8
  private-address: fe80::/10
```

Notas importantes sobre este stack:

- La imagen `mvance/unbound` necesita una `unbound.conf` propia para comportarse como **resolver recursivo**. No conviene depender de la configuración por defecto del contenedor.
- Unbound escucha en `5335` para encajar con la integración ya preparada en `docs/03-red/02-pihole.md`.
- Las reglas `access-control` del ejemplo deben ajustarse a las IP reales de Pi-hole y de `macvlan-shim` si en tu LAN no usas `192.168.1.241` y `192.168.1.248`.
- `use-caps-for-id: no` evita problemas frecuentes dentro de contenedores Linux cuando el servicio no dispone de ciertas capacidades del kernel.
- No hace falta publicar puertos con `ports:` porque la conectividad ocurre dentro de la IP dedicada de la red macvlan.
- `compose.yaml`, `.env` y `unbound.conf` son ficheros pequeños y versionables; el estado operativo importante está en la propia configuración, no en un volumen de datos grande.

Despliegue:

```bash
mkdir -p /home/<usuario>/homelab/compose/unbound
cd /home/<usuario>/homelab/compose/unbound
docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

Resultado esperado:

- el contenedor arranca en `192.168.1.242`
- Unbound responde en `192.168.1.242:5335` por TCP y UDP
- Pi-hole puede usarlo como upstream sin ocupar puertos en la IP principal del host

## Configuración

### Objetivo final de esta guía

| Elemento | Estado esperado |
|---|---|
| IP de Unbound | `192.168.1.242` |
| Puerto de escucha | `5335/tcp` y `5335/udp` |
| Red Docker | `homelab_macvlan` |
| Cliente autorizado principal | Pi-hole `192.168.1.241` |
| Cliente autorizado de soporte | host vía `macvlan-shim` `192.168.1.248` |
| Integración en Pi-hole | upstream `192.168.1.242#5335` |
| DNS anunciado a clientes | Pi-hole, no Unbound |

### 1. Verificar que Unbound responde en la red macvlan

Desde la Raspberry Pi, si ya tienes operativa la interfaz `macvlan-shim`:

```bash
dig @192.168.1.242 -p 5335 cloudflare.com
dig @192.168.1.242 -p 5335 github.com
```

Validación mínima:

- debe haber respuesta válida
- el flag `ra` debe aparecer en la respuesta
- no debe haber timeout

Si falla:

- revisa que la IP `192.168.1.242` no esté ocupada
- comprueba que `homelab_macvlan` exista
- confirma que `macvlan-shim` siga activa en el host
- revisa el log del contenedor:

```bash
cd /home/<usuario>/homelab/compose/unbound
docker compose logs --tail=100 unbound
```

### 2. Confirmar que Unbound no queda abierto a toda la LAN

Este documento recomienda que Unbound acepte consultas directas solo desde:

- Pi-hole
- el propio host mediante `macvlan-shim`

Así se evita que otros clientes de la red salten Pi-hole y pierdan filtrado, resolución local o estadísticas centralizadas.

Prueba esperada:

- desde la Raspberry Pi: `dig @192.168.1.242 -p 5335 cloudflare.com` debe responder
- desde otro cliente cualquiera de la LAN: debería rechazar o no responder según las reglas de acceso

Si prefieres permitir pruebas temporales desde otro equipo de la LAN, añade su IP o subred concreta en `access-control`, valida y después retira ese permiso.

### 3. Integrar Unbound como upstream en Pi-hole

Una vez confirmado que Unbound resuelve correctamente, cambia el upstream de Pi-hole para que deje de depender del router o de un DNS temporal.

En `/home/<usuario>/homelab/compose/pihole/.env`:

```dotenv
PIHOLE_UPSTREAM_DNS=192.168.1.242#5335
```

Aplicar el cambio:

```bash
cd /home/<usuario>/homelab/compose/pihole
docker compose up -d
```

Validación:

```bash
docker exec pihole pihole-FTL --config dns.upstreams
```

El valor esperado debe apuntar a `192.168.1.242#5335`.

Si prefieres verificarlo desde la interfaz web de Pi-hole, revisa que el upstream personalizado apunte a la IP de Unbound y al puerto `5335`, sin dejar activo el DNS temporal anterior.

### 4. Probar la cadena completa Pi-hole -> Unbound

Con Pi-hole ya apuntando a Unbound, prueba contra Pi-hole, no contra Unbound:

```bash
dig @192.168.1.241 github.com
dig @192.168.1.241 jellyfin.lan
```

Qué debe ocurrir:

- `github.com` debe resolverse a través de Pi-hole usando Unbound como upstream
- `jellyfin.lan` debe seguir resolviéndose localmente en Pi-hole hacia la IP LAN del host
- los clientes continúan consultando solo a Pi-hole

Si `github.com` falla pero `jellyfin.lan` responde, el problema suele estar en la conectividad o configuración de Unbound, no en Pi-hole.

### 5. Ajustes operativos recomendados

Buenas prácticas para este homelab:

- mantener Unbound como servicio **interno de infraestructura**, no como DNS anunciado por DHCP
- no usar un DNS público secundario en el router si quieres que todo el tráfico pase por Pi-hole
- mantener la configuración versionada en git:
  - `compose.yaml`
  - `.env`
  - `unbound.conf`

Cuándo tocar `unbound.conf`:

- si cambias la IP de Pi-hole
- si cambias la IP `macvlan-shim`
- si habilitas IPv6 de forma real en tu LAN
- si quieres abrir temporalmente acceso a otra subred o cliente de administración

Después de modificar `unbound.conf`:

```bash
cd /home/<usuario>/homelab/compose/unbound
docker compose up -d
```

### 6. Troubleshooting básico

Comprobar la configuración efectiva del stack:

```bash
cd /home/<usuario>/homelab/compose/unbound
docker compose config
docker compose ps
docker inspect unbound
```

Comprobar resolución DNS desde el host contra la IP macvlan de Unbound:

```bash
dig @192.168.1.242 -p 5335 cloudflare.com
```

Síntomas comunes:

- timeout desde el host:
  - suele indicar problema con `macvlan-shim` o con la IP macvlan
- Pi-hole responde nombres locales pero no externos:
  - suele indicar que Pi-hole ya no llega a Unbound o que `PIHOLE_UPSTREAM_DNS` es incorrecto
- otros equipos de la LAN consultan directamente a Unbound:
  - revisa `access-control` y evita anunciar `192.168.1.242` por DHCP
- el contenedor arranca pero no resuelve:
  - revisa la sintaxis de `unbound.conf` y vuelve a levantar el stack tras corregirla

## Almacenamiento
Volúmenes usados por este stack:

- `./unbound.conf:/opt/unbound/etc/unbound/unbound.conf:ro`

Rutas recomendadas reales en el NVMe:

```text
/home/<usuario>/homelab/compose/unbound/compose.yaml
/home/<usuario>/homelab/compose/unbound/.env
/home/<usuario>/homelab/compose/unbound/unbound.conf
```

Qué queda guardado ahí:

- definición del stack Compose
- variables de despliegue
- configuración persistente y versionable del resolver

En este proyecto Unbound debe vivir en el **SSD NVMe**, no en los discos USB:

- forma parte de la infraestructura base de red
- no necesita gran capacidad de almacenamiento
- conviene minimizar dependencias externas para el servicio DNS

## Backup
Respaldar como mínimo:

- el directorio `/home/<usuario>/homelab/compose/unbound/`
- el fichero `.env`
- el fichero `unbound.conf`

Elementos críticos del backup:

- IP asignada a Unbound
- reglas `access-control`
- puerto configurado `5335`
- cualquier ajuste de caché, endurecimiento o red local

Antes de una copia importante o de una restauración conviene:

```bash
cd /home/<usuario>/homelab/compose/unbound
docker compose stop
```

Después del backup o restauración:

```bash
cd /home/<usuario>/homelab/compose/unbound
docker compose up -d
```

Si restauras desde cero, el orden lógico es:

1. restaurar `compose.yaml`, `.env` y `unbound.conf`
2. levantar Unbound
3. validar `dig @192.168.1.242 -p 5335 cloudflare.com`
4. confirmar en Pi-hole que el upstream sigue siendo `192.168.1.242#5335`

## Referencias
- Documentación oficial de Unbound: `https://unbound.docs.nlnetlabs.nl/`
- Manual de configuración de `unbound.conf`: `https://unbound.docs.nlnetlabs.nl/en/latest/manpages/unbound.conf.html`
- Guía oficial de Pi-hole para usar Unbound: `https://docs.pi-hole.net/guides/dns/unbound/`
- Imagen Docker `mvance/unbound`: `https://hub.docker.com/r/mvance/unbound`
- Repositorio `MatthewVance/unbound-docker`: `https://github.com/MatthewVance/unbound-docker`
