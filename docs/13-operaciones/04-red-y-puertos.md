# Red y puertos

## Descripción
Este documento fija el **contrato operativo de red** del homelab y deja en un solo sitio el mapa de puertos que realmente se usan en la Raspberry Pi 5.

La idea no es listar puertos sin contexto, sino responder a cuatro preguntas prácticas:

- qué puertos escucha la **IP principal del host**
- qué puertos viven en **IPs dedicadas** dentro de `homelab_macvlan`
- qué puertos quedan **solo dentro de Docker** y no deben publicarse en el host
- qué reglas deben cumplirse en **firewall** y **router** para mantener el diseño de acceso solo **LAN + Tailscale**

Este documento asume la arquitectura ya definida en la fase de red:

- IP LAN principal de la Raspberry Pi: `192.168.1.10`
- Pi-hole en macvlan: `192.168.1.241`
- Unbound en macvlan: `192.168.1.242`
- IP `macvlan-shim` del host: `192.168.1.248`
- router/gateway: `192.168.1.1`

Sustituye esos valores por los reales de tu red si usas otra numeración.

## Requisitos Previos
- Haber completado `docs/01-sistema/03-seguridad-base.md`.
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/03-red/01-macvlan.md`.
- Haber completado `docs/03-red/02-pihole.md`.
- Haber completado `docs/03-red/03-unbound.md`.
- Haber completado `docs/03-red/04-caddy.md`.
- Haber completado `docs/03-red/05-tailscale.md`.
- Haber completado `docs/04-seguridad/02-fail2ban.md` si quieres aplicar baneo en `DOCKER-USER`.
- Tener claro qué servicios del catálogo realmente vas a desplegar; este documento recoge el **mapa completo posible** según `SERVICES.md`, pero no todos tienen por qué estar activos a la vez.
- Poder ejecutar `ss`, `docker`, `docker compose`, `sudo`, `ufw`, `iptables`, `dig` y `nslookup`.
- Puertos implicados a nivel global:
  - `22/tcp` para administración SSH del host
  - `80/tcp` y `443/tcp` en la IP principal del host para Caddy
  - `53/tcp` y `53/udp` en la IP dedicada de Pi-hole
  - `5335/tcp` y `5335/udp` en la IP dedicada de Unbound
  - puertos adicionales solo para los servicios que realmente decidas publicar en host o en `network_mode: host`
  - **ningún puerto entrante en el router**

## Docker Compose
No aplica como despliegue independiente.

Este documento no introduce un stack nuevo. Define cómo deben convivir los stacks ya desplegados para que:

- no compitan por los mismos puertos
- no se publiquen puertos por accidente
- quede claro qué servicios deben entrar por **Caddy**, cuáles requieren **host networking** y cuáles solo necesitan conectividad interna de Docker

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| Punto de entrada web principal | Caddy en `80/tcp` y `443/tcp` sobre la IP LAN del host |
| DNS de la LAN | Pi-hole en IP dedicada |
| Resolver recursivo | Unbound en IP dedicada, solo para Pi-hole y el host |
| Acceso remoto | solo Tailscale, sin port forwarding |
| Firewall del host | activo, con política explícita y revisión de `DOCKER-USER` |
| Router | reserva DHCP para la Pi, sin DMZ, sin reglas WAN, sin UPnP si es posible |
| Publicación de puertos | mínima y documentada |

### 1. Contrato de red del homelab

La topología operativa objetivo es esta:

```text
clientes LAN
   |
   +--> Pi-hole (192.168.1.241:53)
   |        |
   |        +--> Unbound (192.168.1.242:5335)
   |
   +--> Raspberry Pi 5 (192.168.1.10)
            |
            +--> SSH (22)
            +--> Caddy (80/443)
            +--> puertos publicados concretos y justificados
            +--> Tailscale en el host
```

Reglas operativas de este diseño:

1. la **IP principal del host** se reserva para administración, proxy web y servicios que realmente deban escuchar fuera de Docker
2. **Pi-hole** y **Unbound** usan IP propia en `homelab_macvlan` para no competir con `80`, `53` ni `5335` en la IP principal
3. los servicios web normales deben entrar por **Caddy**, no por puertos directos publicados en el host
4. los puertos directos solo se aceptan cuando el servicio los necesita de verdad:
   - protocolos no HTTP
   - UI temporal o administrativa fuera de Caddy
   - servicios con `network_mode: host`
5. el acceso remoto ocurre por **Tailscale**, no por reglas WAN del router

### 2. Mapa de puertos publicados en la IP principal del host

Puertos que pueden escuchar en `192.168.1.10` según los documentos del proyecto:

| Puerto | Protocolo | Servicio | Uso | Exposición recomendada |
|---|---|---|---|---|
| `22` | TCP | host | administración SSH | LAN + Tailscale |
| `80` | TCP | Caddy | entrada HTTP interna y redirecciones | LAN + Tailscale |
| `443` | TCP | Caddy | entrada HTTPS interna | LAN + Tailscale |
| `9443` | TCP | Portainer | UI de administración Docker | LAN + Tailscale |
| `9090` | TCP | Prometheus | UI y consultas Prometheus | LAN + Tailscale |
| `3000` | TCP | Grafana | dashboards | LAN + Tailscale |
| `3001` | TCP | Uptime Kuma | monitorización web | LAN + Tailscale |
| `8088` | TCP | Dozzle | visor de logs | LAN + Tailscale |
| `8123` | TCP | Home Assistant | UI y API principal | LAN + Tailscale |
| `1883` | TCP | Mosquitto | broker MQTT | LAN + Tailscale |
| `1880` | TCP | Node-RED | editor y UI | LAN + Tailscale |
| `8384` | TCP | Syncthing | UI web | LAN + Tailscale |
| `22000` | TCP | Syncthing | sincronización entre nodos | LAN + Tailscale |
| `22000` | UDP | Syncthing | QUIC | LAN + Tailscale |
| `21027` | UDP | Syncthing | descubrimiento local | LAN |
| `445` | TCP | Samba | SMB moderno | LAN + Tailscale si realmente lo necesitas |
| `139` | TCP | Samba | compatibilidad SMB antigua | LAN solo si hace falta |
| `137` | UDP | Samba | NetBIOS name service | LAN solo |
| `138` | UDP | Samba | NetBIOS datagram | LAN solo |
| `9000` | TCP | MinIO | endpoint S3 | LAN + Tailscale |
| `9001` | TCP | MinIO | consola web | LAN + Tailscale |
| `51413` | TCP | Transmission | peers BitTorrent | LAN; sin redirección WAN |
| `51413` | UDP | Transmission | DHT y peers UDP | LAN; sin redirección WAN |

Notas importantes de esta tabla:

- `80/tcp` y `443/tcp` deben quedar **reservados para Caddy**.
- `9091/tcp` de Transmission **no** se publica en el host en el diseño recomendado; la UI entra por Caddy.
- `7359/udp` de Jellyfin solo tendría sentido si decides exponer autodiscovery en LAN de forma explícita; por defecto no se recomienda.
- `8000/tcp` y `9000/tcp` de Portainer no se usan en este homelab; se prioriza `9443/tcp`.
- `9001/tcp` de Mosquitto para WebSockets no se usa en esta fase.

### 3. Puertos en IPs dedicadas de macvlan

Estos puertos no escuchan en `192.168.1.10`, sino en IPs propias de la LAN:

| IP | Puerto | Protocolo | Servicio | Uso |
|---|---|---|---|---|
| `192.168.1.241` | `53` | TCP | Pi-hole | DNS |
| `192.168.1.241` | `53` | UDP | Pi-hole | DNS |
| `192.168.1.241` | `80` | TCP | Pi-hole | interfaz web |
| `192.168.1.242` | `5335` | TCP | Unbound | resolver recursivo |
| `192.168.1.242` | `5335` | UDP | Unbound | resolver recursivo |

Contrato de uso:

- los clientes de la red consultan **Pi-hole**, no Unbound
- **Unbound** debe aceptar consultas directas solo desde Pi-hole y desde el host por `macvlan-shim`
- en el router conviene **reservar o excluir** estas IPs del pool DHCP para evitar colisiones

### 4. Puertos publicados solo en loopback del host

Algunos servicios se dejan deliberadamente limitados a `127.0.0.1` para pruebas o scraping local:

| Binding | Servicio | Uso |
|---|---|---|
| `127.0.0.1:9100` | Node Exporter | pruebas locales; Prometheus usa `node-exporter:9100` dentro de Docker |
| `127.0.0.1:8080` | cAdvisor | pruebas locales; Prometheus usa `cadvisor:8080` dentro de Docker |

Política práctica:

- si un servicio no necesita acceso directo desde otros clientes, publícalo en `127.0.0.1` o no lo publiques
- para exporters y servicios auxiliares, prefiere consumo interno entre contenedores antes que sockets expuestos en la LAN

### 5. Puertos usados solo dentro de Docker

Estos puertos forman parte del diseño, pero **no deben aparecer publicados en el host** salvo una necesidad muy justificada:

| Puerto | Protocolo | Servicio o backend | Uso previsto |
|---|---|---|---|
| `9091` | TCP | Authelia | backend detrás de Caddy |
| `80` | TCP | Nextcloud | backend detrás de Caddy |
| `6379` | TCP | Redis | apoyo a Nextcloud o Paperless-ngx |
| `3306` | TCP | MariaDB | backend interno de Nextcloud o BookStack |
| `80` | TCP | Vaultwarden | backend detrás de Caddy |
| `80` | TCP | BookStack | backend detrás de Caddy |
| `9090` | TCP | Linkding | backend detrás de Caddy |
| `8000` | TCP | Paperless-ngx web | backend detrás de Caddy |
| `5432` | TCP | PostgreSQL | backend interno de Paperless-ngx |
| `3000` | TCP | Gotenberg | backend interno de Paperless-ngx |
| `9998` | TCP | Tika | backend interno de Paperless-ngx |
| `9000` | TCP | Mealie | backend detrás de Caddy |
| `8080` | TCP | Stirling PDF | backend detrás de Caddy |
| `80` | TCP | FreshRSS | backend detrás de Caddy |
| `8096` | TCP | Jellyfin | backend detrás de Caddy |
| `4533` | TCP | Navidrome | backend detrás de Caddy |
| `80` | TCP | Audiobookshelf | backend detrás de Caddy |
| `8083` | TCP | Calibre-Web | backend detrás de Caddy |
| `9999` | TCP | Stash | backend detrás de Caddy |
| `9696` | TCP | Prowlarr | backend detrás de Caddy |
| `8989` | TCP | Sonarr | backend detrás de Caddy |
| `7878` | TCP | Radarr | backend detrás de Caddy |
| `9091` | TCP | Transmission | RPC/UI interna usada por Sonarr y Radarr |
| `3000` | TCP | Homepage | backend detrás de Caddy |

La regla aquí es sencilla:

- si la URL final del usuario es `https://servicio.lan` o `https://servicio.homelab.lan`, el backend no necesita publicar su puerto en el host
- publicar el puerto solo para “probar rápido” suele acabar dejando exposición innecesaria y conflictos de puertos más adelante

### 6. Política de firewall del host

El firewall recomendado por el proyecto sigue siendo **UFW** con política base restrictiva:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.1.0/24 to any port 22 proto tcp
sudo ufw allow in on tailscale0
sudo ufw enable
sudo ufw status verbose
```

A partir de esta fase, añade estas reglas operativas:

1. no publiques puertos con Docker por costumbre
2. si un servicio puede ir detrás de Caddy, **no** publiques su puerto propio
3. si un puerto solo es para pruebas, enlázalo a `127.0.0.1`
4. revisa después de cada despliegue:

```bash
ss -lntup
docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

Limitación importante ya documentada en la fase Docker:

- Docker puede insertar reglas de iptables propias y el tráfico de `ports:` no siempre se comporta como un servicio nativo protegido solo por UFW

Por eso, para servicios sensibles publicados por Docker conviene usar además la cadena `DOCKER-USER`.

Ejemplo de endurecimiento para puertos publicados que solo quieres aceptar desde LAN y Tailscale:

```bash
sudo iptables -I DOCKER-USER 1 -i tailscale0 -j RETURN
sudo iptables -I DOCKER-USER 2 -s 192.168.1.0/24 -j RETURN
sudo iptables -A DOCKER-USER -p tcp -m multiport --dports 3000,3001,8123,8384,9000,9001,9443 -j DROP
sudo iptables -A DOCKER-USER -p udp -m multiport --dports 21027,22000,51413 -j DROP
sudo iptables -A DOCKER-USER -j RETURN
```

Notas sobre este ejemplo:

- ajusta la subred `192.168.1.0/24` a tu LAN real
- ajusta la lista de puertos a los que **de verdad** tengas publicados
- `DOCKER-USER` no sustituye a UFW; es una capa adicional útil cuando Docker publica puertos
- Fail2ban también se apoya en `DOCKER-USER`, así que documenta bien cualquier regla manual que añadas

### 7. Política del router

La configuración correcta del router es tan importante como el firewall del host.

Estado objetivo:

| Ajuste | Valor recomendado |
|---|---|
| Reserva DHCP de la Raspberry Pi | `192.168.1.10` |
| Exclusión o reserva para Pi-hole | `192.168.1.241` |
| Exclusión o reserva para Unbound | `192.168.1.242` |
| Exclusión para `macvlan-shim` | `192.168.1.248` |
| DNS anunciado por DHCP | `192.168.1.241` |
| DNS secundario | vacío o segundo Pi-hole, no DNS público |
| Port forwarding | ninguno |
| DMZ | desactivada |
| UPnP / NAT-PMP | desactivado si el router lo permite |

Motivos de esta política:

- la Pi debe conservar una IP estable para que Caddy, Tailscale, bookmarks y monitorización no cambien
- Pi-hole debe ser el DNS que anuncie el router a la LAN
- si el router entrega un DNS público como secundario, parte del tráfico saltará Pi-hole
- el homelab no necesita reglas WAN porque el acceso remoto lo resuelve Tailscale
- desactivar UPnP evita aperturas automáticas de puertos por aplicaciones o dispositivos de la red

### 8. Reserva de puertos y resolución de conflictos

Antes de desplegar un stack nuevo, compara su puerto con este mapa y revisa si el puerto ya está reservado por diseño.

Puertos que conviene considerar **reservados**:

| Puerto | Reserva principal |
|---|---|
| `22` | SSH del host |
| `53` | Pi-hole en IP dedicada |
| `80` | Caddy en host o Pi-hole en IP dedicada |
| `443` | Caddy en host |
| `5335` | Unbound en IP dedicada |
| `1883` | Mosquitto |
| `3000` | Grafana en host |
| `3001` | Uptime Kuma |
| `8123` | Home Assistant |
| `8384` | Syncthing UI |
| `9000` | MinIO API |
| `9001` | MinIO console |
| `9090` | Prometheus |
| `9443` | Portainer |
| `51413` | Transmission peers |

Buenas prácticas para evitar colisiones:

- no uses el mismo puerto del host para dos servicios distintos aunque sus contenedores escuchen en puertos diferentes
- si una aplicación puede vivir solo detrás de Caddy, deja su puerto interno sin publicar
- si un stack necesita `network_mode: host`, valida antes que no pisa un puerto ya usado por otro servicio o por el propio sistema

### 9. Comprobaciones periódicas

Revisión rápida del estado de red:

```bash
hostnamectl
ip -brief address
ss -lntup
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
sudo ufw status verbose
sudo iptables -L DOCKER-USER -n --line-numbers
```

Comprobaciones DNS:

```bash
dig @192.168.1.241 jellyfin.lan
dig @192.168.1.242 -p 5335 jellyfin.lan
nslookup homelab.lan 192.168.1.241
```

Comprobaciones desde otro cliente de la LAN:

- `https://homelab.lan` o el FQDN base que uses debe responder por Caddy
- `http://192.168.1.241/admin/` debe abrir la UI de Pi-hole
- `https://<IP-del-host>:9443` debe abrir Portainer si está desplegado
- ningún servicio debería requerir una regla de port forwarding en el router

## Almacenamiento

| Elemento | Ruta o ubicación | Disco |
|---|---|---|
| Reglas UFW | `/etc/ufw/` | SSD NVMe |
| Reglas `nftables` si se usa la alternativa | `/etc/nftables.conf` | SSD NVMe |
| Reglas de `iptables` en memoria | host | no persistente por sí sola |
| Configuración de Caddy | `/home/<usuario>/homelab/compose/caddy/` | SSD NVMe |
| Stack de Pi-hole | `/home/<usuario>/homelab/compose/pihole/` | SSD NVMe |
| Stack de Unbound | `/home/<usuario>/homelab/compose/unbound/` | SSD NVMe |
| Stacks con puertos publicados | `/home/<usuario>/homelab/compose/<servicio>/` | SSD NVMe |
| Reserva DHCP y política WAN | router | fuera del host |

Notas de almacenamiento:

- la configuración del router no queda versionada automáticamente; conviene documentarla aparte o exportarla si tu firmware lo permite
- si añades reglas manuales de `iptables`, decide cómo vas a persistirlas tras reinicio antes de dar la fase por cerrada
- la fuente de verdad de la topología de puertos debe seguir siendo la documentación y los `compose.yaml`, no Portainer

## Backup
Respaldar como mínimo:

- `/etc/ufw/` o `/etc/nftables.conf`, según la opción elegida
- `/home/<usuario>/homelab/compose/caddy/`
- `/home/<usuario>/homelab/compose/pihole/`
- `/home/<usuario>/homelab/compose/unbound/`
- los `compose.yaml` y `.env` de cualquier servicio que publique puertos en el host
- una nota operativa con:
  - IP LAN fija del host
  - IPs reservadas para Pi-hole y Unbound
  - DNS configurado en el router
  - confirmación explícita de que no existe port forwarding

Conviene además guardar:

- export o captura de la configuración DHCP/DNS del router si tu firmware permite exportación
- cualquier script usado para reaplicar reglas de `iptables` o `DOCKER-USER`

No es necesario respaldar:

- sockets abiertos o tablas de escucha como estado vivo
- reglas WAN inexistentes; lo importante es documentar que **no** deben crearse

## Referencias
- `SERVICES.md`
- `docs/01-sistema/03-seguridad-base.md`
- `docs/02-docker/01-instalacion-docker.md`
- `docs/03-red/01-macvlan.md`
- `docs/03-red/02-pihole.md`
- `docs/03-red/03-unbound.md`
- `docs/03-red/04-caddy.md`
- `docs/03-red/05-tailscale.md`
- `docs/04-seguridad/02-fail2ban.md`
