# Red y Puertos

## Descripción

`01-mantenimiento-periodico.md` fija el calendario operativo, `02-disaster-recovery.md` documenta cómo levantar el homelab tras un incidente y `03-rendimiento-pi5.md` cierra el régimen de rendimiento. Este documento cierra Fase 13 con el **mapa completo de red y puertos**: dónde escucha cada cosa, qué publica al host, qué se queda dentro de la red Docker, qué sale a internet, qué reglas tiene el firewall del host y qué hace (y qué **no** hace) el router doméstico.

Es el documento que el operador abre para responder, sin tener que leerse las trece fases anteriores, preguntas como:

- *¿Por qué `:443` lo publica solo Caddy y no Nextcloud directamente?*
- *¿Qué puertos hay realmente expuestos a la LAN, y desde qué IPs?*
- *¿Cuál es la subred de la red Docker `homelab`, y por qué importa para Authelia?*
- *¿Qué tengo que tocar en el router cada vez que un dispositivo nuevo aparece?*
- *¿Por qué Pi-hole tiene IP propia (`192.168.1.2`) y Caddy comparte la del host (`192.168.1.10`)?*
- *Si abro UFW y veo cuatro reglas, ¿es suficiente, o me he olvidado algo?*

La filosofía sigue siendo la del homelab completo: **solo LAN + Tailscale**. No hay puertos abiertos al WAN, ningún DDNS, ninguna redirección en el router doméstico, ningún certificado Let's Encrypt. Toda la superficie pública del homelab cabe en tres puertas, y las tres están **dentro** del perímetro:

1. **`:80/tcp` y `:443/tcp,udp` en `192.168.1.10`** (host de la Pi) — los publica Caddy. Es la única forma de hablar HTTP/HTTPS con cualquier servicio web del homelab. Detrás de Caddy: Authelia + CA interna.
2. **`:53/tcp,udp` en `192.168.1.2`** (Pi-hole, IP propia macvlan) — DNS para los clientes de la LAN. Pi-hole habla con Unbound (`192.168.1.3`, también macvlan) y este sale a los root servers.
3. **Tailscale (`100.x.y.z`, asignada por el coordination server)** — el operador, desde fuera de casa, ve la Pi como un nodo más del tailnet y accede a los mismos hostnames `.lan` por MagicDNS + cert de la CA interna.

Todo lo demás (Mosquitto en `:1883`, Samba en `:445`, Syncthing en `:22000/21027`, SSH en `:22`) son excepciones documentadas con su propia justificación, restringidas por UFW a los rangos `192.168.1.0/24` y `100.64.0.0/10`.

> **Recordatorio de alcance**: este documento **no abre puertos al exterior**. Las únicas conexiones salientes que el operador necesita conocer son las ya autorizadas en fases anteriores (pull de imágenes, parches APT, sync Borg → B2, NTP, Tailscale coordination, notificaciones Telegram/ntfy). UFW está configurado con `default allow outgoing`, lo que cubre todas. No hay nada que añadir; sí hay un inventario explícito (sección "Tráfico saliente") para documentar la superficie que **se confía** hacia internet.

> **Filosofía**: el mapa de puertos es un **artefacto de auditoría**. Un mapa que se desactualiza es peor que no tenerlo: induce confianza falsa. Cada `ports:` añadido o retirado en un compose se refleja aquí en la siguiente sesión de mantenimiento mensual (M5) o trimestral (Q9). La regla cardinal: si una regla UFW no está en este doc, **es ilegítima**.

---

## Requisitos Previos

Para que este mapa sea coherente, todas las fases que tocan red deben estar desplegadas:

- **Fase 0** (`00-hardware/`): Pi 5 conectada por Ethernet (no Wi-Fi) al router doméstico, MAC de `eth0` anotada.
- **Fase 1** (`01-sistema/`):
  - Sistema base con `unattended-upgrades` activo.
  - **UFW** instalado, con políticas por defecto y reglas básicas de Fase 1 (`01-sistema/03-seguridad-base.md`).
  - Hostname `pi` y la IP del host fija (`192.168.1.10`).
- **Fase 2** (`02-docker/`):
  - Docker Engine + Compose v2 con `daemon.json` ya configurado.
  - Red Docker bridge **`homelab`** creada (CIDR `172.30.10.0/24`) por `scripts/10-create-docker-network.sh`.
- **Fase 3** (`03-red/`):
  - **macvlan** `dns_lan` creada con IP-range `192.168.1.0/29` y aux-address `192.168.1.9` (`03-red/01-macvlan.md`).
  - **Pi-hole** en `192.168.1.2` (macvlan) sirviendo `:53/tcp,udp` y UI HTTP `:80/tcp` (`03-red/02-pihole.md`).
  - **Unbound** en `192.168.1.3` (macvlan) como upstream recursivo de Pi-hole (`03-red/03-unbound.md`).
  - **Caddy** en el host bridge `homelab`, publicando `:80/tcp`, `:443/tcp` y `:443/udp` en `0.0.0.0` (`03-red/04-caddy.md`).
  - **Tailscale** instalado como servicio del host (no contenedor) con interfaz `tailscale0` levantada (`03-red/05-tailscale.md`).
- **Fase 4** (`04-seguridad/`):
  - **Authelia** detrás de Caddy en la red `homelab`, sin `ports:`.
  - **CA interna** emitida y certificado wildcard `*.lan` instalado en Caddy.
- **Variables globales en `.env`**:
  - `LAN_SUBNET=192.168.1.0/24`, `LAN_GATEWAY=192.168.1.1`, `LAN_PARENT_IF=eth0`.
  - `LAN_IP=192.168.1.10`, `PIHOLE_IP=192.168.1.2`, `UNBOUND_IP=192.168.1.3`, `LAN_MACVLAN_SHIM_IP=192.168.1.9`.
  - `DOMAIN_LAN=lan`, `TAILNET_DOMAIN=<tailnet>.ts.net`.

---

## Topología de red

El homelab vive simultáneamente en **cuatro capas de red**, cada una con su CIDR, su propósito y su política. Entender el mapa empieza por separarlas mentalmente.

```
                      ┌──────────────────────────────────────────────┐
                      │  Internet                                    │
                      │   - Docker Hub / GHCR / lscr.io              │
                      │   - APT mirrors (Debian / RPi)               │
                      │   - Backblaze B2                             │
                      │   - NTP, root DNS                            │
                      │   - Tailscale coordination + DERP            │
                      └────────────────────┬─────────────────────────┘
                                           │  (egress only)
                                           │
                       ┌───────────────────┴────────────────────┐
                       │  Router doméstico (192.168.1.1)        │
                       │   NAT, sin port-forwarding             │
                       └───────────────────┬────────────────────┘
                                           │ (LAN cableada)
                                           │
              ┌────────────────────────────┴──────────────────────────────┐
              │  LAN física  192.168.1.0/24                               │
              │   - Pi (host)         192.168.1.10  eth0                  │
              │   - Pi-hole (macvlan) 192.168.1.2                         │
              │   - Unbound (macvlan) 192.168.1.3                         │
              │   - macvlan-shim      192.168.1.9   (host)                │
              │   - Otros dispositivos LAN del operador (DHCP .50–.250)   │
              └─────────────────┬──────────────────┬──────────────────────┘
                                │                  │
                                │                  │
              ┌─────────────────┴─────┐    ┌──────┴───────────────────────┐
              │  Bridge Docker        │    │  Tailscale (mesh VPN)        │
              │  homelab              │    │  100.64.0.0/10 (CGNAT)       │
              │  172.30.10.0/24       │    │   - Pi: tailscale0           │
              │   - Caddy             │    │   - Hostname `pi` MagicDNS   │
              │   - Authelia          │    └──────────────────────────────┘
              │   - Prometheus...     │
              │   - Todos los `expose:`│
              └───────────────────────┘
```

### Capa 1 — LAN física (`192.168.1.0/24`)

| Recurso | IP | Asignación | Notas |
|---|---|---|---|
| Router | `192.168.1.1` | Fija (admin del router) | Gateway. NTP local en algunos modelos. |
| **Pi (host) `eth0`** | `192.168.1.10` | Reserva DHCP por MAC | IP estática vía reserva en el router. La Pi **no** se da una `static` dura en `dhcpcd.conf`; la fuente de verdad es la reserva DHCP. |
| **Pi-hole** | `192.168.1.2` | Estática en compose macvlan | Servicio DNS principal de la LAN. |
| **Unbound** | `192.168.1.3` | Estática en compose macvlan | Upstream recursivo solo accesible desde Pi-hole y desde el host. |
| **`macvlan-shim`** | `192.168.1.9` | `aux-address` de la red `dns_lan` + interfaz virtual del host | Permite al host hablar con sus propios contenedores macvlan (resuelve "la trampa de macvlan", `03-red/01-macvlan.md`). |
| **Bloque IPs reservadas** | `192.168.1.2`–`192.168.1.9` | Documentado, fuera del rango DHCP del router | Espacio para servicios contenedorizados con IP propia. Hoy ocupado solo por Pi-hole y Unbound. |
| **Pool DHCP del router** | `192.168.1.50`–`192.168.1.250` | Restringido en admin del router | Resto de dispositivos del operador. |

> **Decisión "DHCP reserva, no `dhcpcd.conf` estático"**: si la IP estática vive en el router, cualquier reflasheo de la microSD recupera la IP correcta automáticamente al re-DHCP. Con `static ip_address=` en `dhcpcd.conf` el operador depende de que el fichero haya sido restaurado antes de la primera red, lo cual complica DR-2.

### Capa 2 — macvlan `dns_lan` (`192.168.1.0/29` dentro de la LAN)

| Recurso | IP | Notas |
|---|---|---|
| Subnet declarada en Docker | `192.168.1.0/24` | Idéntica a la LAN física (macvlan no NAT-ea). |
| `ip-range` (pool de Docker) | `192.168.1.0/29` | Solo `.0`–`.7`. Docker no toca IPs fuera de este rango. |
| `aux-address` (shim) | `192.168.1.9` | Reservada al host. |
| Parent interface | `eth0` | Macvlan se monta sobre `eth0`. **Wi-Fi no soporta macvlan** — confirma necesidad de Ethernet. |

> **Por qué macvlan**: Pi-hole y Unbound necesitan IP propia en la LAN para que los clientes vean su MAC y su IP reales (no NAT-eada por Docker). Eso evita que **todas** las queries DNS aparezcan como originadas en `192.168.1.10` y rompe la analítica por cliente de Pi-hole. La explicación completa vive en `03-red/01-macvlan.md`.

### Capa 3 — Bridge Docker `homelab` (`172.30.10.0/24`)

| Recurso | Valor | Notas |
|---|---|---|
| Nombre | `homelab` | Red Docker bridge interna. |
| CIDR | `172.30.10.0/24` | Espacio privado, separado de la LAN doméstica. |
| Gateway | `172.30.10.1` | Docker bridge. NAT hacia `eth0` (egress) gestionado por Docker / `iptables`. |
| Resolución interna | DNS de Docker (`127.0.0.11`) | Servicios se ven por nombre del compose (`prometheus`, `grafana`, …). |
| Habitantes | Caddy, Authelia, Prometheus, Grafana, Node Exporter, cAdvisor, Uptime Kuma, Dozzle, Portainer, Borgmatic, Watchtower, Homepage, Mosquitto, Zigbee2MQTT, Nextcloud + Postgres + Redis, Vaultwarden, Paperless, Linkding, Mealie, Bookstack, FreshRSS, Stirling, Audiobookshelf, Calibre-Web, Navidrome, Stash, Jellyfin, Transmission, Sonarr, Radarr, Prowlarr, Bazarr, MinIO, Syncthing | Casi todo. |

> **Decisión "una sola red bridge"**: alternativa sería una red Docker por stack (microsegmentación). Para un homelab doméstico de un solo operador, la complejidad operativa (varias redes, `external: true`, alias DNS) supera el beneficio de seguridad (la atacante necesita ya pivot dentro de un contenedor para que la separación importe). Si en el futuro se incorpora un servicio expuesto al exterior — que **no** es el caso — esa decisión se revisaría.

### Capa 4 — Tailscale (`100.64.0.0/10`)

| Recurso | Valor | Notas |
|---|---|---|
| Interfaz | `tailscale0` | Levantada por `tailscaled` como servicio del host (no contenedor). |
| Rango asignado | dentro de `100.64.0.0/10` | CGNAT del coordination server. |
| IP de la Pi | `100.x.y.z` (variable, anotar en `~/.notes` y en `MAINTENANCE_LOG.md`) | Fija dentro del tailnet. |
| Hostname | `pi` | MagicDNS resuelve `pi.<tailnet>.ts.net`. |
| Subnet routes / exit node | **No activos** (solo acceso al propio nodo) | Queda para una futura ampliación si el operador quiere salir a internet por la VPN o llegar a otros equipos de la LAN remota. |

> **Decisión "host service, no contenedor"**: Tailscale podría correr como contenedor (`tailscale/tailscale`). Se descarta por dos razones:
> 1. El operador quiere `tailscale0` visible en `ip a` del host para que UFW (en el host) pueda usar `allow in on tailscale0`.
> 2. La actualización del cliente Tailscale se gestiona vía APT (`unattended-upgrades`); contenedorizarlo añadiría una segunda vía de actualización con menos integración con el SO.

---

## Mapa de puertos publicados al host

Esta es la **superficie expuesta a la LAN y al tailnet**. Cualquier puerto fuera de esta tabla **no debería estar publicado**: si aparece, es un drift y se corrige.

### TCP — escucha en `0.0.0.0` (LAN + Tailscale)

| Puerto | Servicio | Contenedor / Host | Restricción adicional | Origen |
|---|---|---|---|---|
| **22/tcp** | SSH | Host (`sshd`) | UFW: `allow from 192.168.1.0/24 to any port 22 proto tcp`; tailscale0: confiada (`allow in on tailscale0`) | `01-sistema/03-seguridad-base.md` |
| **80/tcp** | HTTP (Caddy) | `caddy` (bridge `homelab`) | Solo redirige a `:443`. Sin restricción adicional. | `03-red/04-caddy.md` |
| **443/tcp** | HTTPS (Caddy) | `caddy` (bridge `homelab`) | TLS con CA interna. Authelia delante de la mayoría de hostnames. | `03-red/04-caddy.md` |
| **445/tcp** | SMB (Samba) | `samba` (bridge `homelab` + `ports:`) | UFW: `allow from 192.168.1.0/24 to any port 445 proto tcp` y desde tailnet. **Sin acceso de invitado**. | `06-almacenamiento/02-samba.md` |
| **1883/tcp** | MQTT (Mosquitto) | `mosquitto` (bridge `homelab` + `ports:`) | UFW: limitado a LAN + tailnet. Auth por usuario/contraseña. | `08-domotica/02-mosquitto.md` |
| **9001/tcp** | MQTT WebSockets | `mosquitto` | UFW: idem. Solo si algún cliente web MQTT lo necesita; revisar Q9 si no se usa. | `08-domotica/02-mosquitto.md` |
| **22000/tcp** | Syncthing BEP | `syncthing` | UFW: limitado a LAN + tailnet. | `06-almacenamiento/03-syncthing.md` |

### UDP — escucha en `0.0.0.0`

| Puerto | Servicio | Contenedor / Host | Restricción adicional | Origen |
|---|---|---|---|---|
| **443/udp** | HTTP/3 (Caddy) | `caddy` | Idéntica a TCP/443. | `03-red/04-caddy.md` |
| **22000/udp** | Syncthing QUIC | `syncthing` | Idem TCP/22000. | `06-almacenamiento/03-syncthing.md` |
| **21027/udp** | Syncthing local discovery (mDNS) | `syncthing` | Solo LAN local; en tailnet la sincronización va por TCP/UDP 22000. | `06-almacenamiento/03-syncthing.md` |
| **41641/udp** | Tailscale | Host (`tailscaled`) | Negociado dinámicamente; el cliente cae a DERP (HTTPS 443) si UDP está bloqueado. | `03-red/05-tailscale.md` |

### Capa macvlan — IPs propias en la LAN

| IP : Puerto | Servicio | Quién accede | Notas |
|---|---|---|---|
| `192.168.1.2:53/tcp,udp` | Pi-hole DNS | Todos los clientes LAN (DHCP del router los apunta aquí) | DNS primario de la LAN. UDP es el grueso, TCP para AXFR/respuestas grandes. |
| `192.168.1.2:80/tcp` | Pi-hole UI (admin) | Operador desde LAN/tailnet | **Excepción temporal**: hasta que `03-red/04-caddy.md` lo enrute por `https://pihole.lan/` se accede por HTTP plano. La excepción se cierra al desplegar Caddy con su drop-in `pihole.caddy`. |
| `192.168.1.3:53/tcp,udp` | Unbound | Solo Pi-hole y `macvlan-shim` (debug del operador) | No hay ningún dispositivo de la LAN que use Unbound directamente. |

> **Decisión "Caddy publica en `0.0.0.0`, no en `192.168.1.10`"**: el binding sin IP explícita hace que Caddy escuche en cualquier interfaz que el host tenga **en el momento del arranque** (`eth0` siempre, `tailscale0` cuando Tailscale ya está activo). Si Caddy se bindeara a `192.168.1.10:443`, al activar Tailscale habría que reconfigurar el compose para añadir `100.x.y.z:443`. La frontera con el exterior la marcan UFW + el router doméstico, no el binding.

### Suma total de la superficie expuesta

```
LAN 192.168.1.0/24:
  192.168.1.10:    22/tcp (SSH)
                   80/tcp + 443/tcp + 443/udp (Caddy)
                   445/tcp (Samba)
                   1883/tcp + 9001/tcp (Mosquitto)
                   22000/tcp + 22000/udp + 21027/udp (Syncthing)
                   41641/udp (Tailscale)
  192.168.1.2:     53/tcp + 53/udp (Pi-hole)
                   80/tcp (Pi-hole UI temporal)
  192.168.1.3:     53/tcp + 53/udp (Unbound, solo desde Pi-hole y shim)

Tailnet 100.64.0.0/10:
  100.x.y.z:       22/tcp (SSH)
                   80/tcp + 443/tcp + 443/udp (Caddy)
                   445/tcp (Samba) + 1883/tcp (Mosquitto) + 22000 (Syncthing) (LAN-equivalentes)
```

**Trece puertos** distintos en total. Todo lo demás es interno y no se publica.

---

## Mapa de puertos internos (red `homelab`)

Estos puertos **no se publican al host**. Solo son alcanzables desde otro contenedor de la red `homelab`. La superficie efectiva hacia la LAN es **cero**: el ataque tendría que venir desde dentro (un contenedor comprometido), lo cual cambia la categoría del incidente.

### HTTP detrás de Caddy

Caddy hace `reverse_proxy http://<servicio>:<puerto>` resolviendo por DNS interno del bridge. Cada servicio publica un `expose: <puerto>` en su compose, sin `ports:`:

| Hostname externo | Backend (red `homelab`) | Auth Authelia |
|---|---|---|
| `https://auth.lan/` | `authelia:9091` | (es la propia Authelia, no se autentica a sí misma) |
| `https://pihole.lan/` | `pihole:80` (cuando Caddy enrute la UI) | one_factor |
| `https://prometheus.lan/` | `prometheus:9090` | two_factor |
| `https://grafana.lan/` | `grafana:3000` | two_factor + auth.proxy con `Remote-User` |
| `https://uptime.lan/` | `uptime-kuma:3001` | one_factor |
| `https://status.lan/` | `uptime-kuma:3001` (status page) | **sin Authelia** (página pública dentro de la LAN+tailnet) |
| `https://dozzle.lan/` | `dozzle:8080` | two_factor |
| `https://portainer.lan/` | `portainer:9000` | two_factor |
| `https://home.lan/` | `homepage:3000` | one_factor |
| `https://jellyfin.lan/` | `jellyfin:8096` | (auth interna del propio Jellyfin) |
| `https://stash.lan/` | `stash:9999` | two_factor |
| `https://navidrome.lan/` | `navidrome:4533` | one_factor |
| `https://audiobookshelf.lan/` | `audiobookshelf:80` | one_factor |
| `https://calibre.lan/` | `calibre-web:8083` | one_factor |
| `https://transmission.lan/` | `transmission:9091` | two_factor |
| `https://sonarr.lan/` | `sonarr:8989` | two_factor |
| `https://radarr.lan/` | `radarr:7878` | two_factor |
| `https://prowlarr.lan/` | `prowlarr:9696` | two_factor |
| `https://bazarr.lan/` | `bazarr:6767` | two_factor |
| `https://cloud.lan/` | `nextcloud:80` | (auth interna; WebDAV no sigue redirects, sin Authelia) |
| `https://vaultwarden.lan/` | `vaultwarden:80` | (auth interna; clientes Bitwarden no siguen redirects) |
| `https://paperless.lan/` | `paperless:8000` | one_factor |
| `https://linkding.lan/` | `linkding:9090` | one_factor |
| `https://mealie.lan/` | `mealie:9000` | one_factor |
| `https://bookstack.lan/` | `bookstack:80` | one_factor |
| `https://freshrss.lan/` | `freshrss:80` | one_factor |
| `https://stirling.lan/` | `stirling:8080` | two_factor |
| `https://syncthing.lan/` | `syncthing:8384` | two_factor |
| `https://minio.lan/` | `minio:9001` (Console) | two_factor |
| `https://s3.lan/` | `minio:9000` (S3 API) | (Access Keys; los clientes S3 no siguen redirects) |

### Scrape de Prometheus (solo Prometheus → exporter)

| Origen | Destino | Puerto |
|---|---|---|
| `prometheus` | `node-exporter` | `9100/tcp` |
| `prometheus` | `cadvisor` | `8080/tcp` |
| `prometheus` | `pihole-exporter` (si se usa) | configurable |
| `prometheus` | `caddy` (`/metrics`) | `2019/tcp` (admin de Caddy, no expuesto) |

> Ningún exporter publica `ports:`. La visibilidad humana de las métricas es siempre Grafana — los exporters son endpoints máquina-a-máquina.

### Bases de datos (privadas a su stack)

Cada stack que usa BBDD relacional/cache tiene **su propia red Docker interna además de `homelab`**, pero como simplificación operativa el homelab usa una sola red `homelab` y las BBDD viven sin `ports:` ni `expose:` (solo accesibles por DNS interno desde el mismo contenedor que las consume).

| Servicio interno | Puerto | Consumidor | Stack |
|---|---|---|---|
| `postgres` | `5432/tcp` | Nextcloud, Paperless, Authelia (si aplica), Linkding | Cada stack tiene su propio Postgres pinneado a su versión. |
| `mariadb` | `3306/tcp` | Bookstack, Mealie | Idem, instancias separadas por stack. |
| `redis` | `6379/tcp` | Nextcloud, Authelia, Paperless | Cada stack su Redis. |
| `mosquitto` (interno entre HA y Z2M) | `1883/tcp` | Home Assistant, Zigbee2MQTT, Node-RED | Mosquitto sí publica `1883/tcp` al host por requisitos de clientes IoT externos a la Pi. |

> **Decisión "una BBDD por stack, sin compartición"**: tentación natural sería un único Postgres compartido por todos los servicios. Se descarta por riesgo operativo (un upgrade mayor de Postgres rompería todo el homelab a la vez) y por aislamiento de fallos (corrupción de un esquema no afecta a los demás). El coste en RAM (~150 MB extra por instancia adicional) es asumible en la Pi 5 de 8 GB.

---

## Tráfico saliente

UFW está configurado con `default allow outgoing`, así que el operador **no necesita** abrir puertos uno a uno. Lo que sí necesita tener documentado es **a qué destinos confía la Pi**, para auditoría futura y para detección de tráfico anómalo (un contenedor comprometido conectando a un servidor de C2, por ejemplo).

| Destino | Puerto | Protocolo | Iniciado por | Frecuencia | Notas |
|---|---|---|---|---|---|
| Docker Hub / GHCR / `lscr.io` | `443/tcp` | HTTPS | Watchtower, Docker Engine | Semanal (Watchtower mié 04:00); on-demand al `docker compose up` | Pull de imágenes. Ver `02-docker/04-watchtower.md`. |
| Mirrors APT (Debian / RPi) | `80/tcp`, `443/tcp` | HTTP/HTTPS | `unattended-upgrades` y `apt` manual | Diaria | Parches de seguridad. |
| Backblaze B2 | `443/tcp` | HTTPS | `rclone` (vía Borgmatic) | Diaria 03:30 | Sync offsite cifrado. Ver `07-backups/02-borgmatic.md`. |
| Root / TLD DNS servers | `53/udp,tcp` | DNS | Unbound | Continua (queries de la LAN) | Resolución recursiva. |
| NTP (`pool.ntp.org`, mirrors RPi) | `123/udp` | NTP | Host (`systemd-timesyncd` o `chrony`) | Continua | Hora del sistema. Crítico para TLS y para Borgmatic. |
| Tailscale coordination server | `443/tcp` | HTTPS | `tailscaled` | Continua (keepalive) | Negocia el tunnel mesh. |
| Tailscale DERP relays | `443/tcp` (HTTPS) y `41641/udp` (negociación) | mixto | `tailscaled` | Solo cuando NAT no permite conexión directa | Fallback. |
| Notificaciones (Telegram / ntfy / Gotify) | `443/tcp` | HTTPS | `shoutrrr` (Watchtower, alertmanager) | On-event | Alertas operativas. |

> **Decisión "no whitelist de destinos egress"**: alternativa es UFW + reglas tipo "solo `:443/tcp` saliente, solo a IPs conocidas". Para un homelab doméstico introduce más operativa de la que aporta seguridad — los destinos de Docker Hub y APT cambian, las CDNs tienen miles de IPs, y el operador acabaría desactivando la regla en 6 meses. Se prefiere `default allow outgoing` + monitorización de flujos (cAdvisor + node_exporter + opcional `iftop` ad-hoc) para detectar anomalías.

---

## Configuración del router doméstico

El router es **fuente de verdad fuera del repo de git**. La Pi se reflashea desde el repo, pero el router es un dispositivo físico con su propia configuración accesible solo por su admin web. Lo que hay que dejar fijado allí — y anotado en `00-hardware/` para que el operador lo recuerde tras un reflasheo — es lo siguiente:

| Ajuste del router | Valor | Por qué |
|---|---|---|
| **Reserva DHCP de la Pi** | `192.168.1.10` ← MAC de `eth0` (`dc:a6:32:...`) | Sin esto, una renovación DHCP cualquiera podría darle otra IP y romper la macvlan, los hostnames `.lan`, Pi-hole, Caddy, todo. La MAC se anota en `01-sistema/02-configuracion-inicial.md`. |
| **Reservas DHCP opcionales para Pi-hole y Unbound** | `192.168.1.2` ← MAC virtual macvlan; `192.168.1.3` ← MAC virtual macvlan | No siempre es necesario (las MACs macvlan pueden ser estables si el compose las fija). Útil como cinturón. |
| **Rango DHCP del router** | `192.168.1.50`–`192.168.1.250` | Deja libre el bloque `.2`–`.9` para servicios contenedorizados sin riesgo de colisión. |
| **DNS primario en DHCP** | `192.168.1.2` (Pi-hole) | Todos los clientes LAN reciben Pi-hole como DNS automáticamente. |
| **DNS secundario en DHCP** | **Sin secundario** o `192.168.1.2` repetido | Un secundario `1.1.1.1` saltearía Pi-hole intermitentemente (los clientes no usan secundario solo cuando primario falla; lo usan por carrera). |
| **Port forwarding** | **NINGUNO** | Decisión irrenunciable del homelab. Toda la exposición externa va por Tailscale. |
| **UPnP / NAT-PMP** | **Desactivado** | Evita que un contenedor o un cliente abra puertos al WAN sin saberlo. |
| **DDNS dinámico (NoIP, DynDNS, etc.)** | **Desactivado** | Innecesario: Tailscale resuelve el problema de "llegar desde fuera" sin DDNS. |
| **Wi-Fi Guest** | Activado, **sin acceso a la LAN principal** | Visitas no comparten subred con la Pi. |
| **IPv6** | Configurable según ISP, pero el homelab funciona en IPv4 puro | Si IPv6 se activa, el operador anota la prefix delegation y revisa que UFW también aplique reglas IPv6 (lo hace por defecto). |

```
Estado del router (anotación en 00-hardware/02-esquema-conexiones.md):
  192.168.1.10 → Pi homelab (eth0 MAC dc:a6:32:..)
  192.168.1.2  → Pi-hole macvlan (MAC virtual 02:42:c0:a8:01:02)
  192.168.1.3  → Unbound macvlan (MAC virtual 02:42:c0:a8:01:03)
  Pool DHCP:    192.168.1.50 – 192.168.1.250
  DNS primario: 192.168.1.2
  Port forwards: ninguno
  UPnP / DDNS:   desactivados
```

> **Decisión "router como fuente de verdad fuera del repo"**: replicar esta configuración como código sería posible con OpenWrt + Ansible, pero está fuera del alcance del homelab. La regla operativa es: **si tocas el router, lo anotas en `00-hardware/02-esquema-conexiones.md` y commiteas el cambio el mismo día**. Auditoría humana, no automatización.

---

## Firewall del host (UFW)

UFW (`Uncomplicated Firewall`) corre en el **host** de la Pi, no dentro de Docker. Eso significa que actúa **antes** de que el tráfico entre en el bridge `homelab`: bloquea o permite a nivel de `eth0` y `tailscale0`.

### Política por defecto

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw default deny forward      # Docker lo destrabará automáticamente para sus chains
```

### Reglas activas

| # | Regla UFW | Propósito | Origen |
|---|---|---|---|
| 1 | `ufw allow from 192.168.1.0/24 to any port 22 proto tcp` | SSH desde la LAN | `01-sistema/03-seguridad-base.md` |
| 2 | `ufw allow in on tailscale0` | Confianza completa al tailnet (todo lo que llegue por la VPN) | `03-red/05-tailscale.md` |
| 3 | `ufw allow from 192.168.1.0/24 to any port 80 proto tcp` (implícita por `0.0.0.0` + `allow forward` de Docker) | HTTP→HTTPS redirect de Caddy | `03-red/04-caddy.md` |
| 4 | `ufw allow from 192.168.1.0/24 to any port 443 proto tcp` (idem) | HTTPS de Caddy | `03-red/04-caddy.md` |
| 5 | `ufw allow from 192.168.1.0/24 to any port 443 proto udp` | HTTP/3 de Caddy | `03-red/04-caddy.md` |
| 6 | `ufw allow from 192.168.1.0/24 to any port 445 proto tcp` | SMB desde LAN | `06-almacenamiento/02-samba.md` |
| 7 | `ufw allow from 192.168.1.0/24 to any port 1883 proto tcp` | MQTT desde LAN | `08-domotica/02-mosquitto.md` |
| 8 | `ufw allow from 192.168.1.0/24 to any port 22000` y `22000/udp`, `21027/udp` | Syncthing | `06-almacenamiento/03-syncthing.md` |
| 9 | `ufw logging low` | Loguea denegaciones (no aceptaciones; bajo ruido) | `01-sistema/03-seguridad-base.md` |

> **Decisión "Docker bypassa UFW para los `ports:` que publica"**: por arquitectura de Docker en Linux, `iptables` añade reglas en `DOCKER-USER` que hacen el `DNAT` antes de que UFW lo vea. Las reglas `ufw allow from 192.168.1.0/24 to any port 80` no son técnicamente las que dejan pasar HTTP — Docker ya lo hace. Se mantienen escritas igualmente porque (a) auditoría humana: el operador ve la lista y entiende qué está permitido; (b) si en el futuro un servicio se mueve fuera de Docker (poco probable), las reglas siguen valiendo. Para Mosquitto, Samba y Syncthing **sí** se quiere restringir el origen LAN, lo cual requiere una regla `iptables -I DOCKER-USER` adicional (ver doc del servicio) — UFW por sí solo no basta.

### Reglas que **no** existen

| Caso | Regla esperada | Decisión |
|---|---|---|
| Bloqueo de tráfico inter-contenedor | `iptables` en chain `FORWARD` | Innecesario: la red `homelab` es una sola; los contenedores se hablan entre sí por diseño. |
| Bloqueo egress por destino | `ufw deny out to <ip>` | No se aplica (`default allow outgoing`). Justificado en sección anterior. |
| Bloqueo de IPv6 | `ufw default deny incoming` aplica también a IPv6 | UFW gestiona ambos. Si el ISP activa IPv6, las reglas IPv4 se replican automáticamente para IPv6 vía `IPV6=yes` en `/etc/default/ufw`. |
| Rate limiting de SSH | `ufw limit ssh` | Innecesario: SSH solo escucha desde la LAN privada y desde `tailscale0`; no hay ataques de fuerza bruta de internet. |

### Comandos de auditoría

```bash
# Ver reglas activas
sudo ufw status verbose

# Ver iptables tal como lo ve el kernel (incluye reglas de Docker)
sudo iptables -L -n -v
sudo iptables -L DOCKER-USER -n -v

# Ver puertos efectivamente escuchando en el host
sudo ss -tulpn | grep LISTEN

# Ver puertos publicados por Docker
docker ps --format 'table {{.Names}}\t{{.Ports}}' | sort

# Ver conexiones activas (snapshot)
sudo ss -tnp state established
```

> **Patrón mensual M14**: el día 1 de cada mes el operador ejecuta `sudo ss -tulpn | grep LISTEN` y compara contra la tabla "Mapa de puertos publicados al host". Cualquier puerto extra es un drift; cualquier puerto faltante es un servicio caído. La diferencia se anota en `MAINTENANCE_LOG.md`.

---

## Resolución DNS y hostnames

### Cadena de resolución

```
Cliente LAN
   │
   │  query: "jellyfin.lan"
   ▼
Pi-hole (192.168.1.2)         ← DHCP del router los apunta aquí
   │
   │  ¿está bloqueado por blocklist? → NXDOMAIN
   │  ¿coincide con dnsmasq.d/02-homelab-local.conf?
   │     address=/lan/192.168.1.10  → 192.168.1.10
   │  si no, query upstream:
   ▼
Unbound (192.168.1.3)         ← solo accesible desde Pi-hole y shim
   │
   │  resolución recursiva desde root servers
   ▼
Internet (root → TLD → autoritativo)
```

### Hostnames `.lan` documentados

| Hostname | IP que devuelve Pi-hole | Servicio detrás |
|---|---|---|
| `pihole.lan` | `192.168.1.2` | Pi-hole UI (excepción temporal hasta que pase por Caddy) |
| `unbound.lan` | (no se publica) | Unbound interno |
| **comodín `*.lan`** | `192.168.1.10` | Caddy (todo lo demás) |
| `auth.lan` | `192.168.1.10` | Authelia |
| `home.lan` | `192.168.1.10` | Homepage (dashboard) |
| `prometheus.lan`, `grafana.lan`, `uptime.lan`, `status.lan`, `dozzle.lan`, `portainer.lan` | `192.168.1.10` | Observabilidad |
| `cloud.lan`, `vaultwarden.lan`, `paperless.lan`, `linkding.lan`, `mealie.lan`, `bookstack.lan`, `freshrss.lan`, `stirling.lan` | `192.168.1.10` | Productividad |
| `jellyfin.lan`, `stash.lan`, `navidrome.lan`, `audiobookshelf.lan`, `calibre.lan` | `192.168.1.10` | Multimedia |
| `transmission.lan`, `sonarr.lan`, `radarr.lan`, `prowlarr.lan`, `bazarr.lan` | `192.168.1.10` | Descargas |
| `nas.lan` | `192.168.1.10` | Samba (`smb://nas.lan/`) |
| `syncthing.lan`, `minio.lan`, `s3.lan` | `192.168.1.10` | Almacenamiento |

### Resolución desde el tailnet

Tailscale **MagicDNS** resuelve `pi.<tailnet>.ts.net` a la IP CGNAT de la Pi. Para que `jellyfin.lan` funcione **desde fuera** (sentado en una cafetería con Tailscale activo), el cliente debe tener configurado Pi-hole también como upstream DNS:

| Configuración recomendada en cliente Tailscale | Valor |
|---|---|
| **Override local DNS** (en admin Tailscale) | Activado |
| **Nameservers globales** del tailnet | `192.168.1.2` (Pi-hole) |
| **Search domains** | (opcional) `lan`, `<tailnet>.ts.net` |

Eso hace que el cliente, **vía Tailscale**, mande las queries DNS a Pi-hole, que resuelve `jellyfin.lan` → `192.168.1.10`, **pero** la conexión no va a la LAN de casa: va por el tunnel Tailscale a `pi.<tailnet>.ts.net` (`100.x.y.z`) y allí Caddy responde porque escucha en `0.0.0.0`. El cert lo emite la **CA interna** del homelab, así que el cliente debe tenerla instalada en su almacén de confianza.

> **Decisión "Pi-hole también es DNS del tailnet"**: alternativa es darle a cada cliente Tailscale un DNS público (1.1.1.1) y dejar que `*.lan` no resuelva. Eso obliga al operador a recordar IPs cuando viaja, lo cual rompe la abstracción de hostnames. Mejor: Pi-hole como DNS global del tailnet, vía la opción "Override local DNS" del admin web de Tailscale.

---

## Almacenamiento

Este documento operativo no despliega artefactos persistentes nuevos. Los ficheros que **sí** importa que estén versionados (o anotados manualmente) para que el mapa siga vigente son:

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/.env` (variables `LAN_*`, `PIHOLE_IP`, `UNBOUND_IP`, `DOMAIN_LAN`, `TAILNET_DOMAIN`) | microSD | `homelab:homelab` | `0600` | Fuente de verdad de las IPs y subredes. **No versionado** (está en `.gitignore`); su backup va por Borg. |
| `/etc/ufw/user.rules` | microSD | `root:root` | `0640` | Reglas UFW efectivas. Cubierto por el include `/etc/` en Borgmatic (Fase 7). |
| `/etc/network/interfaces.d/*` y/o `/etc/dhcpcd.conf` | microSD | `root:root` | `0644` | Configuración de `eth0` y de la interfaz `macvlan-shim`. |
| `/home/homelab/homelab/scripts/20-create-macvlan-network.sh` | microSD | `homelab:homelab` | `0750` | Script idempotente que crea `dns_lan`. Versionado en git. |
| `/home/homelab/homelab/scripts/21-macvlan-shim.sh` | microSD | `homelab:homelab` | `0750` | Script + unit systemd que crea `macvlan-shim`. Versionado en git. |
| `/home/homelab/homelab/scripts/10-create-docker-network.sh` | microSD | `homelab:homelab` | `0750` | Idem para `homelab` bridge. Versionado en git. |
| `/mnt/hd2t/apps/pihole/dnsmasq.d/02-homelab-local.conf` | hd2t | `homelab:homelab` | `0644` | Comodín `address=/lan/192.168.1.10` y excepciones. Cubierto por Borg. |
| `/home/homelab/homelab/stacks/caddy/Caddyfile` y `conf.d/*.caddy` | microSD | `homelab:homelab` | `0644` | Drop-ins de cada hostname `.lan`. Versionado en git. |
| `/home/homelab/homelab/docs/00-hardware/02-esquema-conexiones.md` (anotación de MACs y reservas DHCP) | microSD | `homelab:homelab` | `0644` | Espejo manual del estado del router. Versionado en git. |

No se crean directorios nuevos en `/mnt/hd2t/` ni en `/mnt/hd5t/`. Todo el "estado" de red del homelab se reproduce desde:

1. La reserva DHCP del router (manual, anotada).
2. El `.env` global (recuperable desde Borg).
3. Los scripts y composes (en git).
4. Las reglas UFW (en `/etc/ufw/`, cubiertas por Borg).

---

## Backup

| Artefacto | Estrategia |
|---|---|
| `docs/13-operaciones/04-red-y-puertos.md` | Versionado en git. |
| Scripts `10-create-docker-network.sh`, `20-create-macvlan-network.sh`, `21-macvlan-shim.sh` | Versionados en git. |
| `Caddyfile` + `conf.d/*.caddy` | Versionados en git (`stacks/caddy/`). |
| `.env` global (con IPs y dominios) | **Solo en Borg**, no en git. Se restaura tras un DR-2 con el procedimiento de `02-disaster-recovery.md` § "Restaurar `secrets/` desde Borg". |
| `/etc/ufw/`, `/etc/dhcpcd.conf`, `/etc/network/interfaces.d/` | Cubiertos por el include `/etc/` en Borgmatic (Fase 7). |
| Configuración del router doméstico (reservas DHCP, DNS apuntando a Pi-hole, UPnP off, etc.) | **Fuera de cualquier backup digital**. Se anota en `docs/00-hardware/02-esquema-conexiones.md` y se exporta manualmente desde el admin web del router (si el modelo lo permite) cada año (Y6). El export queda en `/mnt/hd2t/apps/router/` cifrado con `age` o equivalente. |
| Estado del tailnet (nodos registrados, ACLs) | Visible solo en admin web Tailscale; no se versiona localmente. Auditoría trimestral (Q5) y anotación en `MAINTENANCE_LOG.md`. |

> **Decisión "router fuera del backup digital"**: el router es hardware físico con una vida útil ~5–7 años. Forzar un backup automático de su configuración añadiría una integración frágil (cada modelo con su API). Más sostenible: anotación manual en docs + export manual anual.

---

## Verificación Final

Tras cualquier despliegue o cambio que toque red, esta batería de comprobaciones confirma que el mapa de este documento sigue vigente.

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| **IP de la Pi correcta y estable** | `ip -4 addr show eth0` | `192.168.1.10/24` |
| **Reserva DHCP en el router** | (admin web) | Entrada `192.168.1.10` ↔ MAC de `eth0` |
| **`tailscale0` levantada** | `ip -4 addr show tailscale0` | IP `100.x.y.z/32`, estado UP |
| **Bridge `homelab` creado** | `docker network inspect homelab \| jq '.[0].IPAM.Config'` | `Subnet: 172.30.10.0/24` |
| **Macvlan `dns_lan` creada** | `docker network inspect dns_lan \| jq '.[0].IPAM.Config'` | `Subnet: 192.168.1.0/24`, `IPRange: 192.168.1.0/29`, `AuxiliaryAddresses` con `192.168.1.9` |
| **Pi-hole en `192.168.1.2`** | `dig +short @192.168.1.2 jellyfin.lan` | `192.168.1.10` |
| **Comodín `*.lan` activo** | `dig +short @192.168.1.2 cualquier-cosa-rara.lan` | `192.168.1.10` |
| **Unbound responde a Pi-hole** | `dig +short @192.168.1.3 google.com` (desde el host) | IP pública de Google |
| **Caddy escuchando en `0.0.0.0`** | `sudo ss -tlnp \| grep -E ':(80\|443)\s'` | Tres líneas: `:80 LISTEN`, `:443 LISTEN` (TCP), y `:443` UDP por HTTP/3 |
| **TLS de la CA interna funcional** | `curl -I https://home.lan/` (con CA interna en el truststore del cliente) | `HTTP/2 302` (redirect a Authelia) o `200` |
| **UFW activa con default deny incoming** | `sudo ufw status verbose` | `Status: active`, `Default: deny (incoming), allow (outgoing)` |
| **SSH solo desde LAN + tailscale** | `sudo ufw status \| grep -E '22/tcp'` | Línea con `192.168.1.0/24` y/o `tailscale0` |
| **Mosquitto restringido a LAN+tailnet** | `sudo iptables -L DOCKER-USER -n \| grep 1883` | Reglas con `-s 192.168.1.0/24` y `-s 100.64.0.0/10` |
| **Ningún `ports:` inesperado** | `docker ps --format '{{.Names}}\t{{.Ports}}' \| grep -E '0.0.0.0:'` | Solo Caddy (80/443), Mosquitto (1883/9001), Samba (445), Syncthing (22000/21027) |
| **Sin port-forwarding en el router** | (admin web) | Tabla de port forwards vacía |
| **Sin UPnP / NAT-PMP** | (admin web) | Desactivado |
| **DNS primario del DHCP = `192.168.1.2`** | (admin web) | Sí |
| **Tailnet override DNS = Pi-hole** | (admin Tailscale) | Override DNS activo, nameserver `192.168.1.2` |
| **Anotación del router en docs** | `git log -p docs/00-hardware/02-esquema-conexiones.md \| head -40` | Última línea con `192.168.1.10 → Pi homelab (... MAC ...)` actualizada |

Cumplido todo lo anterior, el homelab tiene un **mapa de red y puertos coherente y auditado**. Con este documento cierra la Fase 13 y, con ella, la documentación operativa del homelab.

---

## Decisiones que **no** se toman en este documento

- **Microsegmentación con varias redes Docker** (una por stack): descartada por complejidad operativa. Si en el futuro entra un servicio expuesto al exterior — fuera del alcance actual del homelab — se reabriría.
- **Whitelist egress** (UFW deny outgoing por defecto + allow específicos): descartada por mantenimiento desproporcionado vs riesgo (homelab doméstico, no producción multi-tenant).
- **VLANs en el switch / router**: el router doméstico típico no las soporta de forma usable. La separación red invitados ↔ red principal vive en la propia Wi-Fi guest del router.
- **Subnet routing de Tailscale** (Pi como puerta a la LAN para nodos remotos): no se activa por defecto. El operador llega a su Pi vía Tailscale, no a otros equipos de su LAN. Si un día se necesita, vive en `03-red/05-tailscale.md`.
- **Exit node de Tailscale** (la Pi como salida a internet para clientes remotos): idem.
- **IPv6 nativo de la LAN**: depende del ISP; el homelab funciona en IPv4 puro. Si IPv6 se activa, UFW ya cubre v4+v6 con sus reglas.
- **Política de actualización del firmware del router**: vive con el operador, no aquí.
- **Reglas Authelia** (qué hostnames piden one_factor vs two_factor): viven en `04-seguridad/01-authelia.md`. Aquí solo se reflejan como información derivada en la tabla de hostnames.
- **Configuración de Caddyfile** (TLS internal, headers, compresión): vive en `03-red/04-caddy.md`.
- **Política DNS de Pi-hole** (blocklists, grupos, regex): vive en `03-red/02-pihole.md`. Aquí solo se confirma que Pi-hole es el DNS primario del homelab.
- **Diagnóstico de incidentes de red** (Pi-hole caído, Caddy en bucle, macvlan que no monta): vive en `02-disaster-recovery.md` y en cada doc de servicio. Aquí solo se enumeran los comandos de verificación.

---

## Referencias

- [Documento previo: `docs/13-operaciones/01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md)
- [Documento previo: `docs/13-operaciones/02-disaster-recovery.md`](./02-disaster-recovery.md)
- [Documento previo: `docs/13-operaciones/03-rendimiento-pi5.md`](./03-rendimiento-pi5.md)
- [Documento relacionado: `docs/00-hardware/02-esquema-conexiones.md`](../00-hardware/02-esquema-conexiones.md)
- [Documento relacionado: `docs/01-sistema/02-configuracion-inicial.md`](../01-sistema/02-configuracion-inicial.md)
- [Documento relacionado: `docs/01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md)
- [Documento relacionado: `docs/02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md)
- [Documento relacionado: `docs/03-red/01-macvlan.md`](../03-red/01-macvlan.md)
- [Documento relacionado: `docs/03-red/02-pihole.md`](../03-red/02-pihole.md)
- [Documento relacionado: `docs/03-red/03-unbound.md`](../03-red/03-unbound.md)
- [Documento relacionado: `docs/03-red/04-caddy.md`](../03-red/04-caddy.md)
- [Documento relacionado: `docs/03-red/05-tailscale.md`](../03-red/05-tailscale.md)
- [Documento relacionado: `docs/04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)
- [Documento relacionado: `docs/06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md)
- [Documento relacionado: `docs/06-almacenamiento/03-syncthing.md`](../06-almacenamiento/03-syncthing.md)
- [Documento relacionado: `docs/08-domotica/02-mosquitto.md`](../08-domotica/02-mosquitto.md)
- [Documento relacionado: `docs/07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
- [UFW — `Uncomplicated Firewall`](https://help.ubuntu.com/community/UFW)
- [Docker — `iptables and Docker`](https://docs.docker.com/network/packet-filtering-firewalls/)
- [Tailscale — Subnet routers and DNS](https://tailscale.com/kb/1019/subnets/)
- [Tailscale — MagicDNS](https://tailscale.com/kb/1081/magicdns/)
- [Pi-hole — Conditional forwarding y DNS local](https://docs.pi-hole.net/guides/dns/conditional-forwarding/)
- [Caddy — Automatic HTTPS y TLS internal](https://caddyserver.com/docs/automatic-https)
- [IANA — Service Name and Transport Protocol Port Number Registry](https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml)
