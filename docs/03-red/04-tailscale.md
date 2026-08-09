# Tailscale para Acceso Remoto por VPN Mesh

## Descripción

Este documento cubre el despliegue de **Tailscale** para dar acceso remoto al homelab sin abrir puertos en el router y sin exponer servicios a internet.

En este proyecto, **Tailscale** cumple una función muy concreta:

- dar acceso remoto seguro a la **Raspberry Pi** y a los servicios publicados en ella
- mantener el alcance del homelab en **LAN + Tailscale**, sin port forwarding ni DDNS
- usar **MagicDNS** para acceder al nodo por nombre dentro de la tailnet
- dejar la IP LAN del host y la red Docker macvlan `dns_lan` (definida en [01-macvlan.md](01-macvlan.md)) funcionando como red local, sin mezclarlas con exposición pública

Para este homelab, la opción recomendada es **instalar Tailscale en el host**. Así, el nodo Tailscale coincide con la Raspberry Pi real y el acceso remoto a servicios publicados en el host, especialmente detrás de **Caddy**, resulta más simple.

Aunque `SERVICES.md` resume el catálogo bajo la convención general de servicios en contenedor, en este caso el plan maestro de red admite **host o contenedor** para Tailscale. En esta guía se documentan ambas modalidades y se prioriza **host** como excepción operativa intencionada.

La opción en contenedor también es válida, pero se considera secundaria y solo tiene sentido si quieres evitar instalar paquetes adicionales en el sistema base.

## Requisitos Previos

- Haber completado [01-instalacion-os.md](../01-sistema/01-instalacion-os.md).
- Haber completado [02-configuracion-inicial.md](../01-sistema/02-configuracion-inicial.md).
- Haber completado [03-seguridad-base.md](../01-sistema/03-seguridad-base.md).
- Haber completado [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md) solo si vas a usar el modo contenedor.
- Haber completado [02-estructura-compose.md](../02-docker/02-estructura-compose.md) solo si vas a usar el modo contenedor.
- Tener creada una cuenta de Tailscale y acceso a la consola de administración de la tailnet.
- Tener definido un hostname razonable para la Raspberry Pi, por ejemplo `pi-homelab`.
- Sustituir antes de desplegar todos los placeholders de esta guía: `<user>`, `<tailnet>`, `<puerto>` y cualquier clave o dominio de ejemplo.
- Elegir **una sola modalidad**:
  - instalación en host, recomendada
  - instalación en contenedor, opcional
- Puertos necesarios:
  - ninguno abierto en el router
  - ningún `port forwarding`
  - el tráfico remoto entra por la red de Tailscale, no por la WAN pública

## Docker Compose

La modalidad recomendada para este homelab es **host**, así que este apartado aplica **solo si eliges ejecutar Tailscale en contenedor**.

Archivo: `/home/<user>/homelab/compose/infra-tailscale/docker-compose.yml`

```yaml
name: infra-tailscale

services:
  tailscale:
    image: tailscale/tailscale:stable
    hostname: pi-homelab
    network_mode: host
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - NET_RAW
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      TS_AUTHKEY: ${TS_AUTHKEY}
      TS_STATE_DIR: /var/lib/tailscale
      TS_EXTRA_ARGS: --accept-dns=false
    volumes:
      - /home/<user>/homelab/data/tailscale:/var/lib/tailscale
```

Archivo recomendado: `/home/<user>/homelab/compose/infra-tailscale/.env`

```dotenv
TS_AUTHKEY=tskey-client-<cambia-esta-clave>
```

Notas sobre este Compose:

- `network_mode: host` hace que el nodo Tailscale comparta la pila de red del host
- el estado persistente queda en `/home/<user>/homelab/data/tailscale/`
- `TS_AUTHKEY` sirve para el alta inicial; después del primer enrolado puedes rotarla o eliminarla del `.env` si ya existe estado persistido
- `--accept-dns=false` evita que el nodo reemplace el DNS operativo del host, algo importante en este homelab porque el DNS local se diseña alrededor de **Pi-hole** y **Unbound**
- no instales también Tailscale en el host si eliges este modo; debe existir **un solo nodo Tailscale** por Raspberry Pi

## Configuración

### 1. Elegir la modalidad correcta

Recomendación operativa para este homelab:

- usa **host** si quieres el camino más simple para acceder a servicios locales, a Docker y al futuro reverse proxy en [05-caddy.md](05-caddy.md)
- usa **contenedor** solo si prefieres aislar Tailscale del sistema base y aceptas una capa adicional de complejidad

En la práctica:

- **host** es la opción principal para esta Raspberry Pi
- **contenedor** queda documentado para quien quiera un despliegue completamente versionado con Compose

### 2. Instalar Tailscale en el host

Instalación recomendada en la Raspberry Pi:

```bash
curl -fsSL https://tailscale.com/install.sh | sudo sh
sudo systemctl enable --now tailscaled
sudo systemctl status tailscaled
```

Después, da de alta el nodo en la tailnet:

```bash
sudo tailscale up --accept-dns=false
tailscale status
tailscale ip -4
```

Sustituye el nombre de ejemplo `pi-homelab` por el hostname real del host si ya elegiste otro distinto en la fase de sistema.

Si ya tenías el nodo unido y quieres corregir la política DNS:

```bash
sudo tailscale set --accept-dns=false
```

Si tienes `ufw` activo en el host, deja alineado el firewall con esta fase:

```bash
sudo ufw allow in on eth0 to any port 41641 proto udp comment 'Tailscale direct UDP'
sudo ufw allow in on tailscale0 to any port 22 proto tcp comment 'SSH desde Tailscale'
```

Esto amplía la política base de [03-seguridad-base.md](../01-sistema/03-seguridad-base.md), mantiene el acceso SSH por la tailnet y permite a Tailscale usar su puerto UDP habitual sin abrir nada en el router. La referencia central de puertos debe quedar reflejada después en [06-puertos-y-firewall.md](06-puertos-y-firewall.md).

Qué hace este ajuste:

- evita que este nodo sustituya su DNS local por el DNS anunciado por Tailscale
- reduce el riesgo de interferir con el fallback del host y con la arquitectura **Pi-hole -> Unbound**
- mantiene el control del DNS operativo en la propia Raspberry Pi

Validaciones mínimas:

```bash
tailscale status
tailscale ip -4
tailscale netcheck
```

Si el servicio está arriba y `tailscale ip -4` devuelve una IP del rango de Tailscale, el nodo ya está unido correctamente.

### 3. Alternativa: desplegar Tailscale en contenedor

Si prefieres el modo contenedor:

```bash
mkdir -p /home/<user>/homelab/compose/infra-tailscale
mkdir -p /home/<user>/homelab/data/tailscale
cd /home/<user>/homelab/compose/infra-tailscale
docker compose config
docker compose up -d
docker compose ps
```

Validaciones iniciales:

```bash
docker compose logs tailscale --tail 50
docker compose exec tailscale tailscale status
docker compose exec tailscale tailscale ip -4
```

Regla importante:

- si eliges contenedor, **no instales Tailscale también en el host**
- si eliges host, **no levantes además este Compose**

### 4. Activar MagicDNS

Una vez que la Raspberry Pi ya pertenece a la tailnet, activa **MagicDNS** en la consola de administración de Tailscale.

Objetivo práctico en este homelab:

- acceder al nodo por nombre en vez de depender de la IP Tailscale
- usar un nombre estable para administración remota
- dejar preparado el terreno para el acceso HTTPS del host en [05-caddy.md](05-caddy.md)

Patrón esperado:

- nombre corto del nodo, por ejemplo `pi-homelab`
- nombre completo de la tailnet, por ejemplo `pi-homelab.<tailnet>.ts.net`

Validaciones desde otro equipo que también esté unido a la misma tailnet:

```bash
tailscale ping pi-homelab
ping pi-homelab
```

Si el nombre corto no resuelve en tu cliente, prueba con el nombre completo `pi-homelab.<tailnet>.ts.net`.

En esta guía, `<tailnet>` es un placeholder: sustitúyelo por el nombre real de tu tailnet dentro del dominio `ts.net`, por ejemplo `midominio` si el FQDN final del nodo queda como `pi-homelab.midominio.ts.net`.

### 5. Cómo encaja Tailscale con el DNS local del homelab

Este punto conviene dejarlo claro para evitar confusión:

- **Pi-hole** sigue siendo el DNS de la **LAN**
- **Unbound** sigue siendo el resolvedor recursivo detrás de Pi-hole
- **MagicDNS** resuelve nombres dentro de la **tailnet**
- Tailscale no sustituye el diseño LAN de [01-macvlan.md](01-macvlan.md), [02-pihole.md](02-pihole.md) y [03-unbound.md](03-unbound.md)

Separación recomendada de nombres:

| Uso | Ejemplo |
|-----|---------|
| Nombres LAN gestionados por Pi-hole | `jellyfin.lan` |
| Nombre del nodo remoto por Tailscale | `pi-homelab.<tailnet>.ts.net` |

Regla operativa:

- usa `*.lan` dentro de casa para servicios internos
- usa el nombre MagicDNS del nodo cuando estés fuera de la LAN y conectado por Tailscale

Si además quieres que **todos** los equipos de la tailnet usen Pi-hole como DNS con filtrado estés donde estés, sigue el apartado [6. Usar Pi-hole como DNS de toda la tailnet](#6-usar-pi-hole-como-dns-de-toda-la-tailnet). MagicDNS y Pi-hole conviven mediante Split DNS: MagicDNS resuelve `*.ts.net` y Pi-hole resuelve el resto.

### 6. Usar Pi-hole como DNS de toda la tailnet

Objetivo: que cualquier equipo unido a la tailnet (portátil, móvil, otro servidor) use **Pi-hole** (`192.168.1.194`) como DNS, con filtrado de anuncios, esté dentro o fuera de la LAN.

Reto técnico de este homelab:

- Pi-hole vive en la macvlan `dns_lan` con IP `192.168.1.194`, **no** en el host
- un cliente remoto de Tailscale no puede alcanzar esa IP LAN salvo que el nodo `pi-homelab` actúe como **subnet router** y anuncie la ruta de la LAN

Requisitos que **ya cumple** la configuración actual:

- Pi-hole escucha en `192.168.1.194` (ver [02-pihole.md](02-pihole.md))
- el host alcanza esa IP macvlan gracias a `macvlan-shim` (ver [01-macvlan.md](01-macvlan.md))
- `FTLCONF_dns_listeningMode: 'LOCAL'` acepta consultas de la subred local

Lo que hay que añadir:

Paso 1. Habilitar el reenvío de paquetes en el host, necesario para el subnet router:

```bash
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
```

Paso 2. Anunciar la ruta hacia Pi-hole desde el nodo `pi-homelab`.

Opción recomendada, exponer **solo** la IP de Pi-hole:

```bash
sudo tailscale up --accept-dns=false --advertise-routes=192.168.1.194/32
```

Con `/32` la tailnet solo alcanza Pi-hole, no el resto de la LAN. Es la opción más segura si tu único objetivo es el DNS filtrado.

Opción ampliada, exponer toda la subred (solo si además quieres alcanzar otros servicios LAN por Tailscale):

```bash
sudo tailscale up --accept-dns=false --advertise-routes=192.168.1.0/24
```

Advertencia: con `/24` cualquier dispositivo de la tailnet que acepte rutas puede alcanzar **toda** tu red doméstica, no solo Pi-hole. Si un nodo de la tailnet se ve comprometido, tendría una ruta hacia la LAN completa. Prefiere `/32` salvo que necesites explícitamente el resto de la subred.

Paso 3. Aprobar la ruta en la consola de Tailscale:

- Machines -> `pi-homelab` -> Subnets -> aprobar la ruta anunciada

Paso 4. Fijar el DNS global de la tailnet en la consola:

- DNS -> Nameservers -> Add nameserver -> Custom -> `192.168.1.194`
- activar **Override local DNS** para forzar que todos los clientes usen Pi-hole

Paso 5. En cada cliente remoto, aceptar las rutas del subnet router:

```bash
sudo tailscale up --accept-routes
```

En clientes móviles, activa la opción equivalente **Use Tailscale subnet routes**.

Si tienes `ufw` activo, permite el reenvío del tráfico enrutado por la tailnet:

```bash
sudo ufw route allow in on tailscale0 out on macvlan-shim to 192.168.1.194 port 53 comment 'DNS tailnet -> Pi-hole'
```

Tailscale suele gestionar sus propias reglas de reenvío, pero esta regla deja explícito el camino hacia Pi-hole si el firewall bloquea el `FORWARD`.

Por qué funciona con `listeningMode: LOCAL`:

- Tailscale aplica **SNAT** al tráfico enrutado por defecto (`--snat-subnet-routes=true`)
- por eso Pi-hole ve la consulta con origen `192.168.1.222` (el `macvlan-shim`), una IP de la subred local
- así no hace falta relajar el modo de escucha de Pi-hole ni exponer nada más

Convivencia con MagicDNS (Split DNS):

- MagicDNS sigue resolviendo `*.ts.net`, es decir, los nombres de los nodos
- `192.168.1.194` resuelve el resto, incluidos los `*.lan` y el filtrado de anuncios
- ambos coexisten; **no desactives MagicDNS** para conseguir esto

Nota sobre el propio nodo `pi-homelab`:

- el host mantiene `--accept-dns=false`; no necesita el DNS de la tailnet porque ya usa su fallback local (ver [02-pihole.md](02-pihole.md))
- solo los **clientes remotos** deben aceptar el DNS de la tailnet

Consideraciones de seguridad:

- **anuncia lo mínimo**: usa `/32` para exponer solo Pi-hole y evita convertir la Raspberry Pi en un puente hacia toda la LAN
- **restringe con ACLs de Tailscale**: por defecto cualquier nodo de la tailnet puede usar la ruta anunciada; limita con ACLs qué usuarios o dispositivos pueden alcanzarla
- **cuida las claves de enrolado**: prefiere claves de un solo uso o efímeras y con caducidad; no dejes `TS_AUTHKEY` reutilizables sin expiración
- **disponibilidad del DNS**: con `Override local DNS`, si Pi-hole cae los clientes se quedan sin resolución mientras estén en la tailnet; si te preocupa, valora usar **Split DNS** (dominios concretos hacia `192.168.1.194`) en lugar de forzar todo el tráfico
- **sin exposición WAN**: este diseño no abre puertos en el router; todo el tráfico va cifrado por WireGuard entre nodos autenticados

Validación desde un cliente remoto conectado por Tailscale (fuera de la LAN):

```bash
tailscale status
dig @192.168.1.194 pi-hole.net
dig @192.168.1.194 jellyfin.lan
```

Si ambas consultas resuelven y aparecen en el Query Log de Pi-hole, el filtrado ya se aplica a toda la tailnet.

### 7. Acceso remoto a servicios sin abrir puertos

Con Tailscale activo, el acceso remoto no pasa por la IP pública del router ni requiere NAT manual.

Antes de desplegar **Caddy**, puedes acceder por Tailscale a los servicios que estén publicados directamente en la red del host o en `0.0.0.0`, usando el nombre MagicDNS del nodo y el puerto correspondiente, por ejemplo:

```text
http://pi-homelab.<tailnet>.ts.net:<puerto>
```

Sustituye `<puerto>` por el puerto real publicado por cada servicio según el mapa central de [06-puertos-y-firewall.md](06-puertos-y-firewall.md).

No asumas que esto sirve para servicios publicados solo en `127.0.0.1`: esos quedan accesibles únicamente desde la propia Raspberry Pi o a través del reverse proxy documentado en [05-caddy.md](05-caddy.md).

Cuando completes [05-caddy.md](05-caddy.md), el patrón recomendado cambiará a un único punto de entrada remoto sobre el hostname Tailscale del host, con HTTPS automático sobre el FQDN concreto del nodo en `ts.net`, por ejemplo `pi-homelab.<tailnet>.ts.net`.

Ventajas operativas de este enfoque:

- no se abren puertos en el router
- no hace falta DDNS
- no hace falta exponer paneles de administración a internet
- el acceso remoto queda limitado a dispositivos autenticados dentro de la tailnet

### 8. Validaciones que conviene dejar hechas

Desde la Raspberry Pi:

```bash
tailscale status
tailscale ip -4
tailscale netcheck
```

Desde un portátil o móvil unido a la misma tailnet:

- abrir el nodo por su nombre MagicDNS
- comprobar que responde por Tailscale incluso fuera de la LAN
- acceder a un servicio del homelab usando `http://pi-homelab.<tailnet>.ts.net:<puerto>`
- confirmar que el router sigue sin tener puertos abiertos hacia la Raspberry Pi

Errores frecuentes que conviene evitar:

- instalar Tailscale a la vez en host y contenedor
- dejar `accept-dns` activado sin revisar el impacto sobre el DNS local del host
- asumir que MagicDNS sustituye a Pi-hole para los nombres `*.lan`
- intentar acceder desde internet por la IP pública del router en vez de unir primero el cliente a la tailnet
- usar Tailscale como excusa para publicar también puertos WAN "por si acaso"

## Almacenamiento

En esta fase, el estado persistente de Tailscale es pequeño y debe vivir en el **SSD NVMe**.

Si usas **instalación en host**:

- estado del nodo: `/var/lib/tailscale/`
- servicio del sistema: `tailscaled`

Si usas **instalación en contenedor**:

- Compose: `/home/<user>/homelab/compose/infra-tailscale/docker-compose.yml`
- variables del stack: `/home/<user>/homelab/compose/infra-tailscale/.env`
- estado persistente: `/home/<user>/homelab/data/tailscale/`

Notas operativas:

- Tailscale no almacena multimedia ni datos pesados
- el dato realmente crítico es el estado del nodo y su relación con la tailnet
- mantener ese estado en el SSD simplifica reinicios, recreación del contenedor y restauración

## Backup

Respalda según la modalidad elegida.

Si usas **host**:

- `/var/lib/tailscale/`
- cualquier nota operativa sobre el nombre del nodo y las políticas aplicadas en la consola de Tailscale

Si usas **contenedor**:

- `/home/<user>/homelab/compose/infra-tailscale/docker-compose.yml`
- `/home/<user>/homelab/compose/infra-tailscale/.env`
- `/home/<user>/homelab/data/tailscale/`

En ambos casos, también conviene documentar:

- el nombre final del nodo en la tailnet
- si `MagicDNS` está activo
- si el nodo acepta o no DNS anunciado por Tailscale
- las rutas anunciadas como subnet router, por ejemplo `192.168.1.0/24` o `192.168.1.194/32`
- si la tailnet usa Pi-hole (`192.168.1.194`) como nameserver global y si está activo `Override local DNS`
- cualquier excepción de firewall añadida para `tailscale0` o `udp/41641`

Orden de restauración recomendado:

- restaurar el estado de Tailscale
- levantar o arrancar `tailscaled`
- verificar que el nodo reaparece en la tailnet
- comprobar acceso por MagicDNS desde otro cliente
- validar después el acceso a servicios del homelab

## Referencias

- [01-macvlan.md](01-macvlan.md)
- [02-pihole.md](02-pihole.md)
- [03-unbound.md](03-unbound.md)
- [05-caddy.md](05-caddy.md)
- [06-puertos-y-firewall.md](06-puertos-y-firewall.md)
- [02-estructura-compose.md](../02-docker/02-estructura-compose.md)
- Tailscale Docs: [Install Tailscale on Linux](https://tailscale.com/download/linux)
- Tailscale Docs: [MagicDNS](https://tailscale.com/docs/features/magicdns)
- Tailscale Docs: [Docker deployment](https://tailscale.com/kb/1282/docker)
- Docker Hub: [tailscale/tailscale](https://hub.docker.com/r/tailscale/tailscale)
