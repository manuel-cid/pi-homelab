# Puertos y Firewall del Homelab

## Descripción

Este documento define la política de exposición de puertos del homelab y la configuración base de firewall del host Raspberry Pi.

Su objetivo es dejar una regla operativa clara:

- la **IP LAN del host** expone solo lo imprescindible
- **Pi-hole** y **Unbound** usan sus propias IPs en `dns_lan`, según [01-macvlan.md](01-macvlan.md), [02-pihole.md](02-pihole.md) y [03-unbound.md](03-unbound.md)
- los servicios web normales entran por **Caddy**, según [05-caddy.md](05-caddy.md)
- el acceso remoto entra solo por **Tailscale**, según [04-tailscale.md](04-tailscale.md)
- el router no publica nada hacia internet

Este documento es un **registro vivo**. Cada vez que se despliegue un servicio nuevo, hay que revisar y actualizar:

- la tabla de puertos reservados
- las reglas del firewall del host
- cualquier excepción de acceso directo que no pase por Caddy

## Requisitos Previos

- Haber completado [03-seguridad-base.md](../01-sistema/03-seguridad-base.md).
- Haber completado [01-macvlan.md](01-macvlan.md).
- Haber completado [02-pihole.md](02-pihole.md).
- Haber completado [03-unbound.md](03-unbound.md).
- Haber completado [04-tailscale.md](04-tailscale.md).
- Haber completado [05-caddy.md](05-caddy.md).
- Tener fijada o reservada la IP LAN del host, por ejemplo `192.168.1.10`.
- Tener reservado el bloque macvlan y las IPs de `Pi-hole`, `Unbound` y `macvlan-shim`.
- Tener acceso administrativo al router para revisar DHCP, DNS, `UPnP` y reglas NAT.
- Elegir **una sola** tecnología de firewall en el host:
  - `ufw`, recomendada por simplicidad
  - `nftables`, válida si prefieres control más fino
- Sustituir antes de aplicar esta guía todos los placeholders de ejemplo, especialmente `192.168.1.10`, `192.168.1.194`, `192.168.1.195`, `192.168.1.222`, `192.168.1.1` y `<tailnet>`, si en tu red real usas otros valores.
- Puertos necesarios en el estado actual de la fase:
  - host `22/tcp` para SSH
  - host `80/tcp` para Caddy en LAN
  - host `443/tcp` para Caddy vía Tailscale
  - host `41641/udp` para conectividad directa de Tailscale
  - Pi-hole `53/tcp`, `53/udp` y `80/tcp` en su IP macvlan
  - Unbound `5335/tcp` y `5335/udp` en su IP macvlan

## Docker Compose

Este documento no despliega un servicio obligatorio nuevo, pero conviene dejar un Compose mínimo y funcional para validar la política recomendada: **servicios web auxiliares o temporales publicados solo en loopback y nunca en `0.0.0.0`**.

Archivo: `/home/<user>/homelab/compose/infra-port-policy-test/docker-compose.yml`

```yaml
name: infra-port-policy-test

services:
  whoami:
    image: traefik/whoami:v1.11
    restart: unless-stopped
    ports:
      - "127.0.0.1:18080:80"
```

Este Compose sirve para comprobar tres cosas:

- el contenedor escucha en el puerto interno `80`
- el host publica el servicio solo en `127.0.0.1:18080`
- el servicio no queda expuesto a toda la LAN por accidente

Validación rápida:

```bash
mkdir -p /home/<user>/homelab/compose/infra-port-policy-test
cd /home/<user>/homelab/compose/infra-port-policy-test
docker compose config
docker compose up -d
ss -ltnp | grep 18080
curl http://127.0.0.1:18080
```

Si el `ss` muestra `127.0.0.1:18080` y no `0.0.0.0:18080`, la política de publicación está bien aplicada.

## Configuración

### 1. Modelo de exposición que debe seguir el homelab

El diseño de red de este proyecto queda dividido en cuatro superficies distintas:

| Superficie | Ejemplo | Regla |
|-----------|---------|-------|
| IP LAN del host | `192.168.1.10` | Permitir por firewall solo `22/tcp` y `80/tcp`; `443/tcp` se publica en el host pero debe quedar accesible solo por `tailscale0` |
| IPs macvlan | `192.168.1.194`, `192.168.1.195` | Reservadas a DNS e infraestructura que necesita IP propia |
| Redes Docker internas | `bridge`, `homelab_proxy` | Sin acceso directo desde la LAN salvo publicación explícita |
| Red Tailscale | `tailscale0`, `*.ts.net` | Acceso remoto autenticado, sin abrir puertos WAN |

Reglas operativas:

- si un servicio web puede ir detrás de **Caddy**, lo correcto es **no publicar puertos** o publicarlos solo en `127.0.0.1`
- si un servicio necesita un puerto directo en la LAN por diseño del protocolo, se documenta aquí como excepción
- si un servicio necesita IP propia en la LAN, se estudia primero si realmente merece entrar en `macvlan`
- no se publica nada en `0.0.0.0` por comodidad

Punto crítico con Docker:

- `ports: - "8080:80"` expone en todas las interfaces del host
- `ports: - "127.0.0.1:18080:80"` expone solo en loopback
- para servicios HTTP del homelab, la segunda opción es la correcta durante bootstrap o diagnóstico

Punto crítico con `macvlan`:

- el firewall del host protege la **IP del host**
- **Pi-hole** y **Unbound** viven en IPs separadas dentro de la LAN
- esas IPs no deben tratarse como si fueran puertos publicados por Docker en el host

### 2. Convención de rangos de puertos

La política recomendada es reservar rangos por categoría para los **puertos publicados en la IP del host** cuando haga falta acceso directo o bootstrap antes de pasar por Caddy.

| Rango | Uso recomendado |
|------|------------------|
| `22` | SSH del host |
| `53`, `80`, `443`, `5335` | Infraestructura fija del proyecto |
| `10000-10999` | Infraestructura y orquestación |
| `11000-11999` | Monitorización y observabilidad |
| `12000-12999` | Archivos, sincronización y backups |
| `13000-13999` | Domótica e IoT |
| `14000-14999` | Multimedia |
| `15000-15999` | Descargas |
| `16000-16999` | Productividad y herramientas personales |
| `17000-17999` | Dashboards y seguridad web |
| `18000-18999` | Bootstrap, pruebas temporales y migraciones |

Cómo usar esta convención:

- asigna un puerto del rango correcto **antes** de desplegar el servicio
- si el servicio luego queda detrás de Caddy, mantén ese puerto en `127.0.0.1` o elimínalo si ya no hace falta
- si el servicio usa un protocolo con puerto estándar obligatorio, ese puerto estándar prevalece y se documenta como excepción

### 3. Registro actual de puertos del proyecto

Infraestructura base ya fijada en esta fase:

| Ámbito | IP / interfaz | Puerto | Servicio | Uso | Exposición |
|-------|----------------|--------|----------|-----|------------|
| Host | `192.168.1.10` | `22/tcp` | SSH | administración del host | LAN + Tailscale |
| Host | `192.168.1.10` | `80/tcp` | Caddy | acceso HTTP en LAN a `*.lan` | solo LAN |
| Host | `192.168.1.10` + `tailscale0` | `443/tcp` | Caddy | acceso HTTPS remoto a `pi-homelab.<tailnet>.ts.net` | solo Tailscale por firewall |
| Host | `eth0` | `41641/udp` | Tailscale | conectividad directa WireGuard-like | entrante al host cuando Tailscale logra camino directo, sin `port forwarding` dedicado |
| Macvlan | `192.168.1.194` | `53/tcp` | Pi-hole | DNS TCP | LAN |
| Macvlan | `192.168.1.194` | `53/udp` | Pi-hole | DNS UDP | LAN |
| Macvlan | `192.168.1.194` | `80/tcp` | Pi-hole | panel web | LAN |
| Macvlan | `192.168.1.195` | `5335/tcp` | Unbound | upstream DNS TCP | interno DNS |
| Macvlan | `192.168.1.195` | `5335/udp` | Unbound | upstream DNS UDP | interno DNS |

Registro vivo de puertos ya fijados por otros documentos existentes del repositorio:

| Servicio | Puerto recomendado | Nota |
|---------|--------------------|------|
| Portainer | `9443/tcp` | publicado en host según [03-portainer.md](../02-docker/03-portainer.md); si lo pasas por Caddy, mejor moverlo a `127.0.0.1` |

Regla de interpretación para esta tabla:

- si un documento de servicio ya fija un puerto concreto, ese valor pasa a ser la referencia operativa de este registro vivo
- la convención por rangos sigue siendo útil para servicios futuros, pero no debe pisar puertos estándar o ya documentados
- esta tabla solo debe crecer cuando exista el documento del servicio correspondiente y el puerto haya quedado fijado allí
- cuando un servicio pase a `127.0.0.1` o quede solo detrás de Caddy, actualiza aquí su nota de exposición

<!-- TODO: verificar y añadir aquí los puertos de fases posteriores cuando existan sus documentos en el repositorio. -->

Puertos estándar que conviene documentar como excepción cuando esos servicios se desplieguen:

| Servicio | Puerto(s) | Motivo |
|---------|-----------|--------|
| Samba | `137/udp`, `138/udp`, `139/tcp`, `445/tcp` | clientes SMB esperan puertos estándar |
| Syncthing | `22000/tcp`, `22000/udp`, `21027/udp` | protocolo propio de sincronización y descubrimiento |
| Mosquitto | `1883/tcp` | MQTT sin TLS en LAN |
| Mosquitto TLS | `8883/tcp` | solo si se habilita más adelante |
| Transmission peers | `51413/tcp`, `51413/udp` | tráfico BitTorrent |

### 4. Reglas base recomendadas con `ufw`

Para este homelab, `ufw` es la opción más simple y suficiente en el host.

Regla importante:

- usa **`ufw` o `nftables`**, pero no ambos a la vez

Base mínima recomendada:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow in on eth0 proto tcp from 192.168.1.0/24 to any port 22 comment 'SSH desde LAN'
sudo ufw allow in on tailscale0 to any port 22 proto tcp comment 'SSH desde Tailscale'

sudo ufw allow in on eth0 proto tcp from 192.168.1.0/24 to any port 80 comment 'Caddy HTTP LAN'
sudo ufw allow in on tailscale0 to any port 443 proto tcp comment 'Caddy HTTPS Tailscale'
sudo ufw allow in on eth0 to any port 41641 proto udp comment 'Tailscale direct UDP'

sudo ufw enable
sudo ufw status verbose
```

Qué deja abierto esta política:

- `22/tcp` en la IP del host para administración desde la LAN y desde Tailscale
- `80/tcp` en la IP del host solo para la red local
- `443/tcp` solo en la interfaz `tailscale0`
- `41641/udp` en `eth0` para que Tailscale pueda establecer conectividad directa cuando sea posible

Qué deja cerrado:

- cualquier otro puerto entrante en la IP del host
- cualquier intento de abrir servicios web directamente en `0.0.0.0` sin revisión previa
- cualquier exposición WAN, porque el router tampoco hace `port forwarding`

Notas importantes con Docker:

- `ufw` no debe ser tu única línea de defensa para contenedores
- si publicas un puerto Docker en el host, hazlo explícitamente en `127.0.0.1` o en una IP concreta
- la política correcta para webs internas sigue siendo **Caddy + redes Docker internas**, no docenas de publicaciones `ports:`

Notas importantes con `macvlan`:

- no abras `53` ni `5335` en la IP del host
- **Pi-hole** y **Unbound** ya tienen sus propias IPs LAN
- las restricciones de esas IPs se controlan por arquitectura, por el alcance LAN del proyecto y por la propia configuración de cada servicio

### 5. Alternativa equivalente con `nftables`

Si prefieres `nftables`, una base mínima coherente con este proyecto sería esta.

Archivo: `/etc/nftables.conf`

```nft
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0;
    policy drop;

    ct state established,related accept
    iifname "lo" accept

    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept

    iifname "eth0" ip saddr 192.168.1.0/24 tcp dport 22 accept
    iifname "eth0" ip saddr 192.168.1.0/24 tcp dport 80 accept

    iifname "tailscale0" tcp dport 22 accept
    iifname "tailscale0" tcp dport 443 accept
    iifname "eth0" udp dport 41641 accept
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
  }
}
```

Activación:

```bash
sudo systemctl enable --now nftables
sudo nft -f /etc/nftables.conf
sudo nft list ruleset
```

La idea es exactamente la misma que con `ufw`:

- host mínimo
- nada de exposición WAN
- LAN y Tailscale como únicos orígenes de administración

### 6. Configuración del router

El router debe reforzar la misma política, no contradecirla.

Checklist recomendado:

- reservar la IP del host Raspberry Pi, por ejemplo `192.168.1.10`
- excluir del DHCP dinámico el bloque macvlan, por ejemplo `192.168.1.192/27`
- anunciar **Pi-hole** como DNS para la LAN, por ejemplo `192.168.1.194`
- confirmar que no existe ninguna regla de `port forwarding`
- confirmar que la Raspberry Pi no está en `DMZ`
- desactivar `UPnP` y `NAT-PMP` si no los necesitas

Regla de proyecto:

- no se abre nada en el router "por comodidad"
- el acceso remoto legítimo entra por **Tailscale**

### 7. Auditoría y mantenimiento del documento vivo

Cada vez que despliegues un servicio nuevo, ejecuta al menos esta revisión:

```bash
ss -ltnup
docker ps --format 'table {{.Names}}\t{{.Ports}}'
sudo ufw status numbered
sudo nft list ruleset
```

Preguntas que debes resolver antes de dar por bueno el despliegue:

- ¿el servicio debía ir detrás de Caddy y, sin embargo, ha quedado expuesto en `0.0.0.0`?
- ¿el puerto asignado está documentado en la tabla de este archivo?
- ¿es realmente necesario publicar el puerto o bastaría con una red Docker compartida?
- ¿el servicio usa un puerto estándar que exige una excepción explícita?
- ¿el cambio obliga a abrir algo nuevo en el firewall del host?

Buenas prácticas de operación:

- anota cada reserva de puerto en este documento antes o durante el despliegue, no después
- elimina puertos de bootstrap cuando el servicio ya quede estable detrás de Caddy
- revisa especialmente contenedores que publiquen puertos UDP o puertos altos no previstos
- si un servicio trae `UPnP` o descubrimiento automático, desactívalo salvo necesidad real

## Almacenamiento

La política de puertos y firewall no consume apenas espacio, pero su configuración sí debe persistir en el **SSD NVMe**.

Rutas relevantes:

- documentación viva: [06-puertos-y-firewall.md](06-puertos-y-firewall.md)
- Compose de prueba: `/home/<user>/homelab/compose/infra-port-policy-test/docker-compose.yml`
- si usas `ufw`: `/etc/ufw/` y `/etc/default/ufw`
- si usas `nftables`: `/etc/nftables.conf`

Notas operativas:

- el dato importante aquí no es el tamaño, sino la capacidad de reconstruir el perímetro del host
- la política efectiva debe poder revisarse tanto en git como en los ficheros del sistema

## Backup

Respalda como mínimo:

- este documento
- `/etc/ufw/` y `/etc/default/ufw` si usas `ufw`
- `/etc/nftables.conf` si usas `nftables`
- cualquier export o nota del router donde consten la IP reservada, el DHCP y la ausencia de `port forwarding`

Cuando cambies reglas:

- guarda el cambio en el repositorio
- valida después con `ss`, `docker ps` y el firewall activo
- si la modificación afecta a acceso remoto, prueba también desde un cliente unido a Tailscale

## Referencias

- Docker Docs: [Publishing and exposing ports](https://docs.docker.com/engine/network/port-publishing/)
- Docker Docs: [Macvlan network driver](https://docs.docker.com/engine/network/drivers/macvlan/)
- Ubuntu Community Help Wiki: [UFW](https://help.ubuntu.com/community/UFW)
- nftables Wiki: [Main page](https://wiki.nftables.org/)
- Tailscale Docs: [Knowledge Base](https://tailscale.com/kb/)
- Pi-hole Docs: [Documentation portal](https://docs.pi-hole.net/)
