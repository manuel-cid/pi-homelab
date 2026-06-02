# Tailscale para Acceso Remoto por VPN Mesh

## Descripción

Este documento cubre el despliegue de **Tailscale** para dar acceso remoto al homelab sin abrir puertos en el router y sin exponer servicios a internet.

En este proyecto, **Tailscale** cumple una función muy concreta:

- dar acceso remoto seguro a la **Raspberry Pi** y a los servicios publicados en ella
- mantener el alcance del homelab en **LAN + Tailscale**, sin port forwarding ni DDNS
- usar **MagicDNS** para acceder al nodo por nombre dentro de la tailnet
- dejar la IP LAN del host y la red `dns_lan` funcionando como red local, sin mezclarlas con exposición pública

Para este homelab, la opción recomendada es **instalar Tailscale en el host**. Así, el nodo Tailscale coincide con la Raspberry Pi real y el acceso remoto a servicios publicados en el host, especialmente detrás de **Caddy**, resulta más simple.

La opción en contenedor también es válida, pero se considera secundaria y solo tiene sentido si quieres evitar instalar paquetes adicionales en el sistema base.

## Requisitos Previos

- Haber completado [01-instalacion-os.md](/Users/x441425/workspace2/homelab/docs/01-sistema/01-instalacion-os.md).
- Haber completado [02-configuracion-inicial.md](/Users/x441425/workspace2/homelab/docs/01-sistema/02-configuracion-inicial.md).
- Haber completado [03-seguridad-base.md](/Users/x441425/workspace2/homelab/docs/01-sistema/03-seguridad-base.md).
- Haber completado [01-instalacion-docker.md](/Users/x441425/workspace2/homelab/docs/02-docker/01-instalacion-docker.md) solo si vas a usar el modo contenedor.
- Haber completado [02-estructura-compose.md](/Users/x441425/workspace2/homelab/docs/02-docker/02-estructura-compose.md) solo si vas a usar el modo contenedor.
- Tener creada una cuenta de Tailscale y acceso a la consola de administración de la tailnet.
- Tener definido un hostname razonable para la Raspberry Pi, por ejemplo `pi-homelab`.
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
- no instales también Tailscale en el host si eliges este modo; deben existir **un solo nodo Tailscale** por Raspberry Pi

## Configuración

### 1. Elegir la modalidad correcta

Recomendación operativa para este homelab:

- usa **host** si quieres el camino más simple para acceder a servicios locales, a Docker y al futuro reverse proxy en [05-caddy.md](/Users/x441425/workspace2/homelab/docs/03-red/05-caddy.md)
- usa **contenedor** solo si prefieres aislar Tailscale del sistema base y aceptas una capa adicional de complejidad

En la práctica:

- **host** es la opción principal para esta Raspberry Pi
- **contenedor** queda documentado para quien quiera un despliegue completamente versionado con Compose

### 2. Instalar Tailscale en el host

Instalación recomendada en la Raspberry Pi:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo systemctl status tailscaled
```

Después, da de alta el nodo en la tailnet:

```bash
sudo tailscale up --accept-dns=false
tailscale status
tailscale ip -4
```

Si ya tenías el nodo unido y quieres corregir la política DNS:

```bash
sudo tailscale set --accept-dns=false
```

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
- dejar preparado el terreno para el acceso HTTPS del host en [05-caddy.md](/Users/x441425/workspace2/homelab/docs/03-red/05-caddy.md)

Patrón esperado:

- nombre corto del nodo, por ejemplo `pi-homelab`
- nombre completo de la tailnet, por ejemplo `pi-homelab.<tailnet>.ts.net`

Validaciones desde otro equipo que también esté unido a la misma tailnet:

```bash
tailscale ping pi-homelab
ping pi-homelab
```

Si el nombre corto no resuelve en tu cliente, prueba con el nombre completo `pi-homelab.<tailnet>.ts.net`.

### 5. Cómo encaja Tailscale con el DNS local del homelab

Este punto conviene dejarlo claro para evitar confusión:

- **Pi-hole** sigue siendo el DNS de la **LAN**
- **Unbound** sigue siendo el resolvedor recursivo detrás de Pi-hole
- **MagicDNS** resuelve nombres dentro de la **tailnet**
- Tailscale no sustituye el diseño LAN de [01-macvlan.md](/Users/x441425/workspace2/homelab/docs/03-red/01-macvlan.md), [02-pihole.md](/Users/x441425/workspace2/homelab/docs/03-red/02-pihole.md) y [03-unbound.md](/Users/x441425/workspace2/homelab/docs/03-red/03-unbound.md)

Separación recomendada de nombres:

| Uso | Ejemplo |
|-----|---------|
| Nombres LAN gestionados por Pi-hole | `jellyfin.lan` |
| Nombre del nodo remoto por Tailscale | `pi-homelab.<tailnet>.ts.net` |

Regla operativa:

- usa `*.lan` dentro de casa para servicios internos
- usa el nombre MagicDNS del nodo cuando estés fuera de la LAN y conectado por Tailscale

### 6. Acceso remoto a servicios sin abrir puertos

Con Tailscale activo, el acceso remoto no pasa por la IP pública del router ni requiere NAT manual.

Antes de desplegar **Caddy**, puedes acceder a servicios publicados en la Raspberry Pi usando el nombre MagicDNS del nodo y el puerto correspondiente, por ejemplo:

```text
http://pi-homelab.<tailnet>.ts.net:<puerto>
```

Cuando completes [05-caddy.md](/Users/x441425/workspace2/homelab/docs/03-red/05-caddy.md), el patrón recomendado cambiará a un único punto de entrada remoto sobre el hostname Tailscale del host, con HTTPS automático sobre `*.ts.net`.

Ventajas operativas de este enfoque:

- no se abren puertos en el router
- no hace falta DDNS
- no hace falta exponer paneles de administración a internet
- el acceso remoto queda limitado a dispositivos autenticados dentro de la tailnet

### 7. Validaciones que conviene dejar hechas

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

Orden de restauración recomendado:

- restaurar el estado de Tailscale
- levantar o arrancar `tailscaled`
- verificar que el nodo reaparece en la tailnet
- comprobar acceso por MagicDNS desde otro cliente
- validar después el acceso a servicios del homelab

## Referencias

- [01-macvlan.md](/Users/x441425/workspace2/homelab/docs/03-red/01-macvlan.md)
- [02-pihole.md](/Users/x441425/workspace2/homelab/docs/03-red/02-pihole.md)
- [03-unbound.md](/Users/x441425/workspace2/homelab/docs/03-red/03-unbound.md)
- [05-caddy.md](/Users/x441425/workspace2/homelab/docs/03-red/05-caddy.md)
- [06-puertos-y-firewall.md](/Users/x441425/workspace2/homelab/docs/03-red/06-puertos-y-firewall.md)
- [02-estructura-compose.md](/Users/x441425/workspace2/homelab/docs/02-docker/02-estructura-compose.md)
- Tailscale Docs: [Install Tailscale on Linux](https://tailscale.com/download/linux)
- Tailscale Docs: [MagicDNS](https://tailscale.com/docs/features/magicdns)
- Tailscale Docs: [Docker deployment](https://tailscale.com/kb/1282/docker)
- Docker Hub: [tailscale/tailscale](https://hub.docker.com/r/tailscale/tailscale)
