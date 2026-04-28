# Red y Puertos

## Descripción

Documento operativo de la **Fase 13** del homelab. Es el **mapa canónico** de la red del homelab: qué IP tiene cada cosa, **qué puerto escucha cada servicio**, **dónde lo escucha** (en el host, en la red Docker `homelab`, en la macvlan, en el `tailscale0`), **qué reglas de firewall** lo protegen y **qué configuración del router** sostiene todo.

Este doc no instala nada. Toda la configuración de red real vive en docs anteriores: la macvlan en [`../03-red/01-macvlan.md`](../03-red/01-macvlan.md), Pi-hole/Unbound en [`../03-red/02-pihole.md`](../03-red/02-pihole.md) / [`../03-red/03-unbound.md`](../03-red/03-unbound.md), Caddy en [`../03-red/04-caddy.md`](../03-red/04-caddy.md), Tailscale en [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md), `ufw`/`fail2ban` en [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md), y las decisiones de cada servicio (qué puerto interno usan, si publican o no al host) en sus respectivos docs de Fases 2–12. Aquí se **consolida** y **audita**: si en seis meses el operador se pregunta "¿qué hay escuchando en la Pi?", la respuesta vive en este doc.

Cubre, en este orden:

1. **Filosofía de red**: cuatro principios — *LAN + Tailscale only*, *Caddy es la única entrada HTTPS*, *macvlan solo para DNS*, *un único puerto forwarded en el router (Transmission)*.
2. **Topología consolidada**: diagrama ASCII de la red completa, planos físico (LAN), Docker (`homelab` bridge + `lan_macvlan` + `dns_internal`) y Tailscale.
3. **Plan de direccionamiento**: tabla canónica del rango `192.168.1.0/24`, IPs reservadas, rango DHCP excluido, MACs fijadas en el router, MACs estáticas Docker.
4. **Mapa de puertos**: cuatro tablas — puertos en el **host** (LAN), puertos en la **macvlan** (Pi-hole/Unbound), puertos **internos** de la red Docker `homelab` (no publicados, alcanzables vía Caddy), puertos **salientes** de la Pi a internet.
5. **Configuración del router**: reservación DHCP por MAC para la Pi, exclusión del rango macvlan del pool DHCP, **un único `port forwarding`** (Transmission peer port `51413/tcp+udp`), DNS LAN apuntando a la macvlan de Pi-hole.
6. **Firewall (`ufw` + `nftables`/`fail2ban`)**: política por defecto, reglas explícitas declaradas en docs anteriores, qué tráfico **bypassa** el firewall (macvlan, Tailscale, Docker bridge), comprobaciones.
7. **Tailscale**: cómo encaja en el modelo, qué puertos usa, qué interfaz crea, por qué no exige port forwarding en el router.
8. **Cambios recurrentes**: cómo dar de alta un servicio nuevo (puerto interno, ¿publica al host?, ¿necesita regla `ufw`?, ¿entrada en este mapa?), cómo cambiar la subred LAN.
9. **Verificación**: comandos canónicos (`ss -tnlp`, `nft list ruleset`, `docker network inspect`, `tailscale status`, `vcgencmd`+ `nmap` desde otro equipo) y el smoke test cuadrado del mapa: "lo que dice este doc coincide con la realidad".
10. **Lista de Verificación** y **Solución de Problemas** con los síntomas habituales (puerto colisionado, `ufw` recién activado bloqueando una macvlan, Tailscale sin conectividad, port forwarding del 51413 que se ha caído).

> **Alcance de este doc**: este documento **no abre puertos**. Cada puerto que aparece aquí lo abrió un doc anterior. La función de este doc es **registrar**, **consolidar** y **detectar incoherencias** (un servicio que publica al host en contra de la convención, una regla `ufw` huérfana de su servicio, un port forwarding del router que el operador olvidó retirar tras un experimento).

> **Alcance de red**: el homelab se opera **en LAN + Tailscale**. Lo único que llega del internet abierto es la conexión BitTorrent de Transmission (peer port `51413`). Nada más se publica al exterior. Si el operador necesitara publicar algo a internet (por ejemplo, ser anfitrión de una webhook pública), este doc es el primer sitio donde se registra el cambio.

---

## Requisitos Previos

- **Fases 0–4 desplegadas y operativas**: hardware, OS, Docker, red (macvlan, Pi-hole, Unbound, Caddy, Tailscale) y seguridad base (`ufw`, `fail2ban`). El doc se redacta cuando todo eso está vivo: lo que se mapea aquí ya existe.
- **Acceso SSH al host** con permisos `sudo`. Algunas verificaciones (`ss -tnlp`, `nft list ruleset`, `tailscale status`) requieren root.
- **Otra máquina en la LAN** (un portátil, un móvil con `nmap` instalado) para auditar la Pi desde fuera. La verificación honesta del mapa de puertos no se hace desde la Pi misma — se hace desde un cliente de la LAN escaneando la Pi.
- **Acceso al router doméstico**: el operador conoce la URL de admin del router (típicamente `http://192.168.1.1`), las credenciales y dónde se configuran las reservas DHCP, los pool de direcciones y las reglas de port forwarding. El modelo concreto (Mikrotik, AVM Fritz!Box, ASUS, Linksys, Movistar/Telefónica, etc.) afecta a la UI pero no al fondo.
- **Bitácora abierta**: cualquier cambio en el mapa de puertos (servicio nuevo, port forwarding nuevo o retirado, cambio de subred LAN) debe quedar en `~/homelab/operations/maintenance.log` con cadencia `ad-hoc` y un commit con el mismo mensaje (convención §8 de [`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md)).

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Modelo de exposición a internet | **LAN + Tailscale only** | Sin DDNS, sin certificados Let's Encrypt públicos, sin Cloudflare Tunnel. La VPN mesh de Tailscale resuelve el "acceso desde fuera de casa" sin abrir puertos. Detalle en [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md). |
| Punto único de HTTPS | **Caddy en el host (`:80`/`:443`)** | Toda la UI web del homelab pasa por Caddy. Ningún servicio web publica directamente al host. Las dos únicas excepciones (Samba 445 y Transmission peer 51413) están justificadas y documentadas. |
| Estrategia DNS interna | **Pi-hole + Unbound en `lan_macvlan` con IP propia** | Pi-hole en `192.168.1.241:53` y Unbound en `192.168.1.242:5335`. Así el host conserva los puertos `53` y `80` libres para `systemd-resolved` y para Caddy respectivamente. Detalle en [`../03-red/01-macvlan.md`](../03-red/01-macvlan.md) §1. |
| IP de la Pi en la LAN | **`192.168.1.10`** (reservada por MAC en el router) | La Pi tiene cable Ethernet directo al router; la IP se fija con reserva DHCP por MAC para que ni Caddy, ni Pi-hole (resolviendo `*.lan`), ni Tailscale, ni el operador necesiten reaprenderla tras un reboot del router. |
| Rango macvlan reservado | **`192.168.1.240/28`** (`.240`–`.255`, 16 IPs) | Bloque pequeño y predecible, fuera del pool DHCP. `.240` para `lan-shim` (host), `.241` Pi-hole, `.242` Unbound, `.243`–`.255` libres. |
| Pool DHCP del router | **`192.168.1.100`–`192.168.1.239`** (140 IPs dinámicas) | Suficiente para los dispositivos domésticos típicos (móviles, portátiles, IoT). El operador deja reserva manual en `.2`–`.50` para infraestructura fija (impresora, NAS antiguo, repetidor WiFi…). |
| Política `ufw` por defecto | **`deny incoming`, `allow outgoing`, `disabled routed`** | Lo establece [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §4. Aquí solo se audita que sigue así. |
| Único `port forwarding` en el router | **`51413/tcp+udp` → `192.168.1.10:51413` (Transmission peer port)** | Es la única excepción a la regla "no se abren puertos al exterior". BitTorrent es P2P y necesita conexiones entrantes; sin ello el ratio cae y los trackers privados penalizan. Si el operador rechaza esa exposición, ver §12.1 de [`../10-descargas/01-transmission.md`](../10-descargas/01-transmission.md) (variante con gluetun). |
| Servicios que publican al host (LAN) | **Caddy `80/443`**, **Samba `445`**, **Transmission peer `51413`**, **SSH `22`** | Lista cerrada. Cualquier otro `ports:` en un compose es un error: se detecta en §9.4 (smoke test). |
| Acceso SSH | **Solo desde subred LAN `192.168.1.0/24`**, key-only, rate-limited (`limit`) | Lo establece [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §4.3. Desde fuera de casa, el SSH se alcanza por Tailscale (la IP `100.x.x.x` del nodo). |
| Bitácora de cambios de red | **`~/homelab/operations/maintenance.log`** con cadencia `ad-hoc` | Patrón de los demás docs operativos. Cualquier cambio en este mapa exige una entrada (servicio nuevo, IP nueva, regla `ufw` añadida, port forwarding nuevo). |
| Tareas que NO entran en este doc | Despliegue de servicios, instalación de Caddy/Tailscale/Pi-hole, tuning de la Pi, mantenimiento periódico, disaster recovery | Cubiertas por sus docs respectivos. Aquí solo se **mapea** lo que esos docs han desplegado. |

---

## 1. Filosofía: cuatro principios de red

### 1.1. LAN + Tailscale only

El homelab **no se expone a internet**. Esa frase tiene tres consecuencias operativas que vertebran todas las demás decisiones:

1. **No hay DDNS, ni Cloudflare Tunnel, ni Let's Encrypt público.** El reverse proxy (Caddy) emite certificados con su propia CA interna para los nombres `*.lan`, y obtiene certificados Let's Encrypt **vía Tailscale** (`tailscale cert`) para los nombres `*.${TS_DOMAIN}`. Detalles en [`../03-red/04-caddy.md`](../03-red/04-caddy.md) y [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) §7.
2. **No se abren puertos web al exterior.** Concretamente: el router **no tiene** ningún port forwarding de `80/tcp` o `443/tcp` a la Pi. El acceso desde fuera de casa se hace conectándose a la tailnet (Tailscale activo en el dispositivo del operador) y abriendo `https://jellyfin.${TS_DOMAIN}` igual que se haría con `https://jellyfin.lan` desde la LAN.
3. **El único puerto entrante desde internet es Transmission `51413/tcp+udp`.** P2P es la excepción; si el operador no quiere ni esa, hay un fallback (gluetun) en [`../10-descargas/01-transmission.md`](../10-descargas/01-transmission.md) §12.1.

### 1.2. Caddy es la única entrada HTTPS

Todos los servicios web del homelab (Jellyfin, Nextcloud, Vaultwarden, Bookstack, Pi-hole UI, Grafana, Sonarr/Radarr/Prowlarr, Homepage, etc.) se sirven **a través de Caddy**. Es decir:

- **Ningún servicio web publica su puerto HTTP/HTTPS al host.** Si en un `docker-compose.yml` aparece `ports: - "8989:8989"` en Sonarr, es un error. Caddy llega a Sonarr por nombre (`http://sonarr:8989`) en la red Docker `homelab`. Esto se valida en cada doc de servicio (sección "Solución de Problemas") y se consolida en §9.4.
- **Caddy publica `0.0.0.0:80` y `0.0.0.0:443` en el host.** Son los **únicos** puertos web que se ven desde la LAN.
- **Authelia se interpone como middleware** (`forward_auth`) en Caddy para los servicios que lo requieren ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)). Saltarse Caddy = saltarse Authelia. Por eso "no publicar al host" no es solo higiene, es modelo de seguridad.

Excepciones declaradas y razonadas:

| Servicio | Puerto en host | Por qué se excepciona |
|---|---|---|
| **Samba** | `445/tcp` | SMB no se proxea por Caddy. Se publica al host para que clientes Windows/Mac/Linux lo monten desde la LAN. Ver [`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md). |
| **Transmission peer** | `51413/tcp+udp` (`mode: host`) | BitTorrent es P2P; el `mode: host` preserva la IP real del peer (necesaria para ratio y para el log). Ver [`../10-descargas/01-transmission.md`](../10-descargas/01-transmission.md) §1. |
| **SSH** | `22/tcp` | Es servicio del **host**, no contenedor. La regla `ufw` lo limita a la subred LAN. Ver [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §4.3. |

Cualquier otra excepción tiene que justificarse y entrar en este doc explícitamente. La política de "no publicar al host" se valida en cada despliegue y se vuelve a auditar en mantenimiento mensual ([`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md) §5).

### 1.3. macvlan solo para DNS

Las redes Docker macvlan tienen ventajas reales (IP propia en la LAN, sin NAT) y costes operativos reales (host no puede hablar con sus propios contenedores macvlan sin shim, los macvlan se saltan `ufw` por completo, depuración más complicada). El homelab solo recurre a macvlan para **un caso**: Pi-hole + Unbound, donde el conflicto de puertos `53` y `80` con `systemd-resolved` y Caddy del host fuerza la separación.

El criterio "macvlan solo para DNS" se mantiene incluso si en el futuro se añade otro servicio que "querría" tener IP propia. La regla por defecto: ¿es DNS o un servicio críticamente acoplado al puerto 53? Sí → macvlan. No → red `homelab`. Ver razonamiento completo en [`../03-red/01-macvlan.md`](../03-red/01-macvlan.md) §1.

### 1.4. Un único port forwarding en el router

El router del operador tiene **una sola** regla de port forwarding hacia la Pi: `51413/tcp+udp` → `192.168.1.10:51413` para Transmission. Cualquier otra regla **es un error o un experimento que se quedó pegado**. La sesión trimestral del playbook periódico ([`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md) §6) revisa explícitamente la lista de port forwarding del router contra la tabla de §5.3 de este doc. Cero coincidencias inesperadas es la única respuesta correcta.

---

## 2. Topología consolidada

### 2.1. Plano físico (LAN)

```
                    Internet (operador no controla)
                              │
                              │ (sin DMZ, sin port forwarding salvo 51413)
                              ▼
              ┌───────────────────────────────┐
              │   Router doméstico            │
              │   192.168.1.1                 │
              │   - DHCP server               │
              │   - DNS upstream → 192.168.1.241 (Pi-hole)
              │   - Port forward: 51413 → 192.168.1.10:51413
              │   - Reservas DHCP por MAC: Pi 5 → 192.168.1.10
              │   - Pool excluye 192.168.1.240–.255
              └─────────────┬─────────────────┘
                            │
                            │ Cable Ethernet gigabit
                            │
                  ┌─────────▼──────────┐
                  │   Raspberry Pi 5   │ 192.168.1.10  ← host (eth0)
                  │   8 GB · BCM2712   │ 192.168.1.240 ← lan-shim (macvlan host)
                  └────────┬───────────┘
                           │
                           ▼
            ─── Servicios escuchando en eth0 (host LAN) ───
            22/tcp   SSH
            80/tcp   Caddy (redirect → 443)
            443/tcp  Caddy (HTTPS)
            445/tcp  Samba
            51413/tcp+udp  Transmission peer (mode: host)
```

Otros equipos de la LAN (móviles, portátiles, TVs con Jellyfin client) viven en el pool DHCP `192.168.1.100`–`192.168.1.239`. Ninguno de ellos sabe nada del homelab más allá de "el router me dice que el DNS es `192.168.1.241`".

### 2.2. Plano Docker

Tres redes Docker conviven en la Pi. Cada contenedor está en una o más de ellas según necesidad:

```
┌────────────────────────────────────────────────────────────────────────┐
│   Pi 5 host                                                            │
│                                                                        │
│   ┌──────────────────────┐   ┌──────────────────────┐                 │
│   │ docker network:      │   │ docker network:      │                 │
│   │ lan_macvlan          │   │ dns_internal         │                 │
│   │ driver: macvlan      │   │ driver: bridge       │                 │
│   │ subnet 192.168.1.0/24│   │ (interno, sin gw)    │                 │
│   │ ip-range .240/28     │   │                      │                 │
│   │ parent eth0          │   │  pihole ↔ unbound    │                 │
│   │                      │   │                      │                 │
│   │  pihole .241         │   └──────────────────────┘                 │
│   │  unbound .242        │                                             │
│   │  (host shim .240)    │                                             │
│   └──────────────────────┘                                             │
│                                                                        │
│   ┌────────────────────────────────────────────────────────────────┐  │
│   │ docker network: homelab                                        │  │
│   │ driver: bridge                                                 │  │
│   │ subnet: 172.20.0.0/16  (gestionada por Docker)                 │  │
│   │                                                                │  │
│   │   caddy   authelia   pihole(*)  jellyfin   sonarr   radarr     │  │
│   │   prowlarr  transmission   nextcloud   bookstack   grafana     │  │
│   │   prometheus  uptime-kuma  homepage  vaultwarden  ...          │  │
│   │                                                                │  │
│   │   (*) pihole también vive aquí para que Caddy lo proxee        │  │
│   │       sin tener que cruzar la macvlan                          │  │
│   └────────────────────────────────────────────────────────────────┘  │
│                                                                        │
│   tailscale0 (interfaz virtual, Tailscale daemon en host)              │
│   100.x.x.x  ← IP de la tailnet (CGNAT)                                │
└────────────────────────────────────────────────────────────────────────┘
```

Reglas de pertenencia que aplican siempre:

- **Caddy** está en `homelab` (para llamar a los servicios) y publica `:80/:443` al host (para recibir tráfico LAN/Tailscale).
- **Pi-hole** está en `lan_macvlan` (para tener IP LAN propia y servir DNS al router), `dns_internal` (para hablar con Unbound) y `homelab` (para que Caddy le proxee la UI por nombre `pihole`). Tres redes — el caso más complejo del homelab. Ver [`../03-red/02-pihole.md`](../03-red/02-pihole.md) §0.
- **Unbound** está en `lan_macvlan` (para que su IP sea estable y los `access-control` funcionen) y `dns_internal` (para que solo Pi-hole y `lan-shim` lo consulten). **No** está en `homelab`: Unbound no necesita ser proxeado por Caddy.
- **Todo lo demás** está solo en `homelab`. Sin `ports:` publicados (salvo las excepciones de §1.2).

### 2.3. Plano Tailscale

Tailscale corre como **servicio del host** (`tailscaled.service`), no como contenedor. Crea la interfaz virtual `tailscale0` con una IP CGNAT (`100.x.y.z`) que pertenece a la tailnet del operador.

```
   Tailscale tailnet (mesh privada)
   ─────────────────────────────────
       laptop              móvil
       100.64.0.5          100.64.0.7
            │                  │
            └──── DERP relay / hole-punching ────┐
                                                  │
                                                  ▼
                                     Pi 5 — tailscale0
                                     100.64.0.10
                                     ╲
                                      ╲  MagicDNS resuelve:
                                       ╲   pi.${TS_DOMAIN} → 100.64.0.10
                                        ╲  jellyfin.${TS_DOMAIN} → 100.64.0.10
                                         ╲ ...
                                          ╲
                                           ▼
                                    Caddy escucha en :443 de
                                    todas las interfaces (eth0 + tailscale0).
                                    Mismo bloque, distinto certificado:
                                       *.lan      → CA interna Caddy
                                       *.${TS_DOMAIN} → Let's Encrypt (tailscale cert)
```

Implicaciones operativas:

1. **No hay port forwarding de Tailscale en el router.** Tailscale resuelve la conectividad NAT con UDP 41641 (saliente) + STUN + DERP relay; el operador no toca nada en el router.
2. **`tailscale0` no se filtra por `ufw`** en Bookworm por defecto. La política `deny incoming` no afecta a tráfico que entra por la tailnet (Tailscale gestiona ACLs en su propio panel). El operador puede endurecer esto desde el admin de Tailscale si quiere, pero no es necesario para el homelab.
3. **Caddy escucha en ambas interfaces** automáticamente (binding `0.0.0.0:443`). No se duplica configuración: el mismo bloque `caddy` sirve a `jellyfin.lan` y a `jellyfin.${TS_DOMAIN}`, eligiendo certificado por SNI.

---

## 3. Plan de direccionamiento

Esta tabla es la **fuente de verdad** del rango LAN del homelab. Cualquier dispositivo nuevo que entre a la red lo hace dentro de uno de estos bloques. Cualquier IP fuera de la tabla — investigar.

| Rango | Asignación | Quién la gestiona | Notas |
|---|---|---|---|
| `192.168.1.1` | Router (gateway, DHCP server, DNS upstream interno hacia Pi-hole) | Operador (admin del router) | Dependiendo de operador puede ser `.254`. Ajustar el resto de la tabla coherentemente. |
| `192.168.1.2` – `192.168.1.9` | Reservas para infraestructura fija futura | Operador (vía router DHCP por MAC) | Vacío por defecto. Hueco para impresora, NAS antiguo, AP WiFi, etc. |
| **`192.168.1.10`** | **Raspberry Pi 5 (host)** — `eth0` | Reserva DHCP por MAC | IP fija crítica: la firman Caddy, Pi-hole (entradas `*.lan`), Tailscale (`tailscale cert`). |
| `192.168.1.11` – `192.168.1.99` | Reservas estáticas variadas | Operador (vía router) | Para dispositivos que el operador prefiere fijar pero no son la Pi. |
| `192.168.1.100` – `192.168.1.239` | **Pool DHCP dinámico** | Router | Móviles, portátiles, IoT, invitados. 140 IPs disponibles. |
| **`192.168.1.240`** | `lan-shim` (interfaz macvlan **del host**) | `aux-address` Docker + systemd unit | Reservada con `--aux-address host=192.168.1.240` al crear `lan_macvlan`. Permite host ↔ contenedores macvlan. Ver [`../03-red/01-macvlan.md`](../03-red/01-macvlan.md) §5. |
| **`192.168.1.241`** | **Pi-hole** (contenedor `lan_macvlan`) | `ipv4_address` en su Compose | DNS de la LAN: el router apunta sus clientes DHCP aquí como DNS primario. |
| **`192.168.1.242`** | **Unbound** (contenedor `lan_macvlan`) | `ipv4_address` en su Compose | Resolver recursivo upstream de Pi-hole. Solo Pi-hole y `lan-shim` lo consultan (`access-control`). |
| `192.168.1.243` – `192.168.1.255` | Libres para futuros servicios macvlan | Operador (manual al crear el contenedor) | 13 IPs libres. Suficientes "para siempre" en este perfil de homelab. |

> **Por qué `.240/28` y no `.250/29`**: con `/28` (16 IPs) caben Pi-hole + Unbound + 13 huecos. Con `/29` (8 IPs) cabrían 5. Más holgura por la misma exclusión del pool DHCP en el router. La diferencia es teórica — en la práctica nunca se llenan.

> **Por qué la Pi en `.10` y no en `.2`**: por convención del operador. La regla real es "una IP fuera del pool DHCP, fácil de recordar, distinta del router". `.10`, `.2`, `.50` cualquiera vale; lo importante es que sea **una sola** y que esté declarada en este doc.

### 3.1. MACs estáticas Docker

Docker, cuando se asigna `ipv4_address` en macvlan, también permite fijar la `mac_address`. Para Pi-hole y Unbound:

| Contenedor | IP | MAC propuesta | Fijado en | Notas |
|---|---|---|---|---|
| Pi-hole | `192.168.1.241` | `02:42:c0:a8:01:f1` | `mac_address:` en `docker-compose.yml` | El prefijo `02:42:` es de Docker; los 4 últimos octetos codifican la IP en hex (`c0:a8:01:f1` = `192.168.1.241`). Patrón opcional pero útil para depurar `tcpdump`. |
| Unbound | `192.168.1.242` | `02:42:c0:a8:01:f2` | `mac_address:` en `docker-compose.yml` | Idem. |
| `lan-shim` (host) | `192.168.1.240` | (aleatoria por boot) | (no se fija) | El host genera una MAC nueva en cada boot para `lan-shim`. No es problema: el host no se anuncia por DHCP en esa IP — la usa solo como salto de routing. |

Esto está documentado en [`../03-red/02-pihole.md`](../03-red/02-pihole.md) y [`../03-red/03-unbound.md`](../03-red/03-unbound.md). Aquí solo se consolida.

---

## 4. Mapa de puertos

Cuatro tablas: **host (LAN)**, **macvlan**, **interno (`homelab` bridge)** y **salientes**. Las cuatro son la fuente de verdad — si la realidad difiere de lo declarado aquí, hay deriva: investigar en §10/§11.

### 4.1. Puertos en el **host** (escuchan en `192.168.1.10` y/o en `tailscale0`)

Estos son los puertos visibles desde la LAN (y, los que también caen sobre `tailscale0`, desde la tailnet). Son la lista cerrada que `ss -tnlp` debe mostrar al hacer `sudo ss -tnlp '( sport = :22 or sport = :80 or sport = :443 or sport = :445 or sport = :51413 )'`.

| Puerto | Proto | Servicio | Quién lo abre | Acceso | Auth | Doc origen |
|---|---|---|---|---|---|---|
| **22** | TCP | SSH (`sshd` host) | `openssh-server` | LAN `192.168.1.0/24` (rate-limited `ufw limit`) + Tailscale | Clave SSH; `fail2ban` jail `sshd`; `nftables-allports` ban | [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §4.3 |
| **80** | TCP | HTTP (Caddy) | Contenedor `caddy` con `ports: 80:80` | LAN + Tailscale | Redirect 301 → `https://...` (no sirve contenido en plano) | [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §0 |
| **443** | TCP | HTTPS (Caddy) | Contenedor `caddy` con `ports: 443:443` | LAN + Tailscale | TLS (CA interna `*.lan` o Let's Encrypt vía Tailscale `*.${TS_DOMAIN}`); Authelia `forward_auth` por bloque | [`../03-red/04-caddy.md`](../03-red/04-caddy.md) |
| **445** | TCP | Samba SMB | Contenedor `samba` con `ports: 445:445` | LAN | Cuentas Samba (usuario+password); sin Authelia (SMB no es HTTP) | [`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md) |
| **51413** | TCP | Transmission peer (BitTorrent) | Contenedor `transmission` con `mode: host` | **Internet** (port forwarding del router) + LAN | Ninguna (es el peer port de BitTorrent) | [`../10-descargas/01-transmission.md`](../10-descargas/01-transmission.md) §1 |
| **51413** | UDP | Transmission peer (uTP / DHT) | Idem | Idem | Idem | Idem |
| **41641** | UDP | Tailscale (`tailscaled`) | Daemon Tailscale en host | Internet (saliente; entrante por hole-punching) | WireGuard pre-shared keys gestionadas por Tailscale | [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) §0 |

> **Verificación honesta**: la lista de arriba es la **única** que `nmap -sS -p1-65535 192.168.1.10` desde otro equipo de la LAN debería mostrar como `open`. Cualquier puerto extra es deriva — empezar por §11 ("puerto inesperado").

> **Observación sobre Tailscale 41641/UDP**: Tailscale lo usa para la conectividad WireGuard directa entre nodos. El daemon **escucha** en ese puerto en el host, pero **no requiere port forwarding en el router** porque Tailscale resuelve NAT con DERP/STUN. Aparece aquí por completitud del mapa: si `nmap` desde otra red privada lo ve, es normal; si `nmap` desde internet lo ve, también es normal (Tailscale lo "perfora" temporalmente para una conexión directa) — no es exposición de un servicio del homelab.

### 4.2. Puertos en la **macvlan** (escuchan en `192.168.1.241` y `192.168.1.242`)

Estos puertos viven en IPs propias de la LAN, no en la del host. Desde otro equipo, `nmap 192.168.1.241` y `nmap 192.168.1.242` devuelven:

| IP | Puerto | Proto | Servicio | Acceso | Auth | Doc origen |
|---|---|---|---|---|---|---|
| `192.168.1.241` | **53** | UDP | Pi-hole DNS | LAN (cualquier cliente) | Ninguna (DNS público en LAN, no se filtra) | [`../03-red/02-pihole.md`](../03-red/02-pihole.md) §0 |
| `192.168.1.241` | **53** | TCP | Pi-hole DNS (TCP fallback para respuestas grandes) | Idem | Idem | Idem |
| `192.168.1.241` | **80** | TCP | Pi-hole UI (HTTP plano, redirige a `https://pihole.lan` vía Caddy) | LAN (acceso plano permitido para que el operador llegue por IP en emergencia DNS) | Password admin Pi-hole; cuando se llega vía Caddy, además Authelia | [`../03-red/02-pihole.md`](../03-red/02-pihole.md) §0 |
| `192.168.1.242` | **5335** | UDP | Unbound (resolver recursivo) | Solo `192.168.1.241` (Pi-hole) y `192.168.1.240` (`lan-shim`) — `access-control` interno | Ninguna (Unbound confía en `access-control` por IP) | [`../03-red/03-unbound.md`](../03-red/03-unbound.md) §0 |
| `192.168.1.242` | **5335** | TCP | Unbound (TCP fallback) | Idem | Idem | Idem |

> **Por qué Pi-hole `:80` plano sigue siendo aceptable**: si Pi-hole se cae y se intenta llegar por `https://pihole.lan`, Caddy no encuentra upstream y devuelve `502 Bad Gateway` — UI inservible cuando más se necesita. El acceso directo `http://192.168.1.241/admin/` permite al operador llegar a Pi-hole "saltándose Caddy" en una emergencia DNS (precisamente cuando el resto del homelab no resuelve nombres). Ese trade-off está documentado en [`../03-red/02-pihole.md`](../03-red/02-pihole.md) §3.

> **Importante sobre `ufw` y macvlan**: el tráfico que llega a `192.168.1.241:53` o `192.168.1.242:5335` **no atraviesa `ufw`** del host. Va directamente al contenedor por la macvlan. La macvlan **bypass-ea** el firewall del host por diseño. Por eso Unbound implementa su propia ACL (`access-control:`) y por eso Pi-hole confía en estar solo en LAN (ver §6.4).

### 4.3. Puertos **internos** de la red Docker `homelab`

Estos puertos **no se publican al host** (con las excepciones de §4.1). Son alcanzables solo desde dentro de la red Docker `homelab` por el nombre del servicio. Caddy es el cliente principal: `http://jellyfin:8096`, `http://sonarr:8989`, etc. Sonarr/Radarr/Prowlarr también se comunican entre sí por nombre (`http://prowlarr:9696`).

Esta tabla **no** la "ve" un `nmap` desde la LAN. Solo se ve desde dentro de la red Docker:

```bash
# Desde el host:
docker exec caddy curl -sf http://jellyfin:8096/health

# Desde dentro de un contenedor en homelab:
docker exec sonarr curl -sf http://prowlarr:9696/ping
```

Mapa por fase (servicio → puerto interno; siempre HTTP plano salvo que se diga):

| Fase | Servicio | Hostname interno | Puerto interno | Notas |
|---|---|---|---|---|
| 02 | Portainer | `portainer` | `9443` (HTTPS interno) | Caddy proxea a HTTPS interno (Portainer no soporta HTTP plano cómodamente). |
| 02 | Watchtower | `watchtower` | (no escucha) | Cliente de la API de Docker, sin servidor HTTP. |
| 03 | Pi-hole | `pihole` | `80` | Caddy proxea aquí para `https://pihole.lan`; Pi-hole también escucha en `:80` de su IP macvlan. |
| 03 | Caddy | `caddy` | `80`, `443` | (Las únicas que también publica al host). |
| 04 | Authelia | `authelia` | `9091` | Caddy lo consume como `forward_auth http://authelia:9091`. |
| 05 | Prometheus | `prometheus` | `9090` | Caddy lo expone con auth en `https://prometheus.lan`. |
| 05 | Grafana | `grafana` | `3000` | Idem. |
| 05 | Node Exporter | `node-exporter` | `9100` | Solo Prometheus lo consume; sin UI. |
| 05 | cAdvisor | `cadvisor` | `8080` | Idem (Prometheus lo scrapea). UI accesible en `https://cadvisor.lan` opcional. |
| 05 | Uptime Kuma | `uptime-kuma` | `3001` | UI por Caddy. |
| 05 | Dozzle | `dozzle` | `8080` | UI por Caddy. |
| 06 | Nextcloud (AIO) | `nextcloud-apache` | `11000` | AIO mete su propio reverse proxy interno; Caddy proxea al `:11000` documentado en su doc. |
| 06 | Samba | `samba` | `445` | (Excepción: también publica al host). |
| 06 | Syncthing | `syncthing` | `8384` (UI), `22000/tcp+udp` (peer), `21027/udp` (descubrimiento local) | UI por Caddy. Peer port queda en la red Docker; Syncthing se anuncia en LAN si el operador habilita el modo "host" en su `network_mode` (no por defecto). |
| 06 | MinIO | `minio` | `9000` (S3 API), `9001` (UI) | Caddy expone solo la UI; la S3 API se consume internamente por Borgmatic vía nombre. |
| 08 | Home Assistant | `home-assistant` | `8123` | UI por Caddy. |
| 08 | Mosquitto | `mosquitto` | `1883` (MQTT plano), `8883` (MQTT/TLS opcional) | Solo clientes internos: Z2M, Node-RED, HA. No expuesto a LAN. |
| 08 | Zigbee2MQTT | `zigbee2mqtt` | `8080` | UI por Caddy; comunica con Mosquitto interno. |
| 08 | Node-RED | `node-red` | `1880` | UI por Caddy. |
| 09 | Jellyfin | `jellyfin` | `8096` (HTTP), `8920` (HTTPS interno, no usado), `7359/udp` (auto-discovery), `1900/udp` (DLNA, opcional) | Caddy proxea `:8096`. UDP de auto-discovery solo si el operador lo habilita; por defecto los clientes Jellyfin se conectan por nombre (`https://jellyfin.lan`) sin discovery. |
| 09 | Navidrome | `navidrome` | `4533` | UI por Caddy. |
| 09 | Audiobookshelf | `audiobookshelf` | `13378` | UI por Caddy. |
| 09 | Calibre-Web | `calibre-web` | `8083` | UI por Caddy. |
| 09 | Stash | `stash` | `9999` | UI por Caddy (con Authelia). |
| 10 | Transmission | `transmission` | `9091` (UI/RPC) | Caddy proxea UI. RPC consumido por Sonarr/Radarr/Prowlarr **directamente** por nombre (sin Caddy). Peer port `51413` aparte (§4.1). |
| 10 | Prowlarr | `prowlarr` | `9696` | UI por Caddy; API consumido por Sonarr/Radarr. |
| 10 | Sonarr | `sonarr` | `8989` | UI por Caddy; API consumido por Prowlarr/Bazarr. |
| 10 | Radarr | `radarr` | `7878` | UI por Caddy; API consumido por Prowlarr/Bazarr. |
| 11 | Vaultwarden | `vaultwarden` | `80` (HTTP), `3012/tcp` (WebSocket, deprecated) | UI por Caddy con Authelia. |
| 11 | Bookstack | `bookstack` | `80` | UI por Caddy. |
| 11 | Linkding | `linkding` | `9090` | UI por Caddy. |
| 11 | Paperless-ngx | `paperless-webserver` | `8000` | UI por Caddy. |
| 11 | Mealie | `mealie` | `9000` | UI por Caddy. |
| 11 | Stirling-PDF | `stirling-pdf` | `8080` | UI por Caddy. |
| 11 | FreshRSS | `freshrss` | `80` | UI por Caddy. |
| 12 | Homepage | `homepage` | `3000` | UI por Caddy con Authelia. |
| 12 | dockerproxy (de Homepage) | `dockerproxy` | `2375` (en la red `dashboard_internal`, **no** en `homelab`) | Solo lo consume Homepage. Aislado. Ver [`../12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md). |

> **Colisiones de números entre servicios distintos**: varios servicios escuchan en el mismo número de puerto (Authelia y Transmission ambos en `9091`; Linkding y Prometheus ambos en `9090`; Bookstack/Dozzle/cAdvisor/Stirling-PDF/Zigbee2MQTT todos en `8080`). **No es problema**: cada uno escucha en *su contenedor*, y Caddy llega por nombre (`http://authelia:9091` ≠ `http://transmission:9091`). Lo único que importa es que **ninguno publique** ese puerto al host.

> **Cómo se consolida la regla "no publicar al host"**: el smoke test del §9.4 verifica que `ss -tnlp` en el host muestra **únicamente** los puertos del §4.1 (más algún `127.0.0.1:xxx` de daemons locales como `cupsd` si está instalado, que no se exponen).

### 4.4. Puertos **salientes** (Pi → internet)

La política `ufw` por defecto es `allow outgoing`, así que el host (y todos los contenedores) puede establecer cualquier conexión saliente. En práctica, el catálogo del homelab abre estos puertos hacia internet:

| Puerto destino | Proto | Quién lo usa | Para qué |
|---|---|---|---|
| **53** | UDP/TCP | Unbound (`192.168.1.242`) | Resolución recursiva: consulta a root servers, TLDs, autoritativos. |
| **80** | TCP | `apt`, paquetes de Docker images, FreshRSS, Mealie scrapers, Calibre-Web | HTTP saliente para mirrors y feeds que aún no son HTTPS (cada vez menos). |
| **443** | TCP | Casi todo: `apt update` (mirrors HTTPS), Docker pulls (registries), Watchtower (Docker Hub), Tailscale control plane (`controlplane.tailscale.com`), Borgmatic offsite (Backblaze B2 / Storz), Authelia OIDC opcional, integraciones de Home Assistant, scrapers de Mealie/Calibre, etc. | El protocolo dominante de salida. |
| **123** | UDP | `systemd-timesyncd` | NTP a `pool.ntp.org` (o similar). Ver [`../01-sistema/02-configuracion-inicial.md`](../01-sistema/02-configuracion-inicial.md). |
| **41641** | UDP | Tailscale (`tailscaled`) | Tráfico WireGuard hacia otros nodos de la tailnet (cuando es directo, no DERP). |
| **3478** | UDP | Tailscale (STUN) | Resolución NAT para hole-punching. |
| **80**, **443** (DERP relays) | TCP | Tailscale (DERP fallback) | Cuando el hole-punching falla, Tailscale relaya tráfico cifrado vía servidores DERP en `derp*.tailscale.com`. |
| **25**, **587**, **465** | TCP | Servicios con notificaciones SMTP (Authelia password reset, opt-in en Borgmatic, opt-in en Uptime Kuma) | Solo si el operador habilita SMTP. La mayoría del homelab usa webhooks (Telegram) en su lugar. |
| **51413** | TCP/UDP | Transmission (peers salientes) | BitTorrent. **Saliente**: la conexión inicial a peers la hace Transmission; **entrante**: el port forward del router del 51413 permite a otros peers conectarse. |
| **6881–6889** | TCP/UDP | Transmission (DHT/PEX) | Distributed Hash Table y Peer Exchange. Por torrent: deshabilitado en privados. |

> **Egresos no esperados**: el operador puede auditar conexiones salientes activas con `sudo ss -tnp state established` o `sudo conntrack -L`. Cualquier conexión saliente a un destino desconocido es señal de revisión (típicamente: una integración de HA llamando a una API externa que el operador olvidó haber añadido). No se filtra el egreso por defecto: el coste operativo de mantener allowlists supera el riesgo en este perfil de homelab.

> **Filtrado de egreso opt-in**: si en el futuro se quisiera endurecer (por ejemplo, prohibir que cualquier contenedor que no sea Borgmatic hable con `*.backblazeb2.com`), la herramienta es `iptables`/`nftables` con cadenas DOCKER-USER y reglas por contenedor — fuera del alcance del homelab base. Ver [Docker — iptables](https://docs.docker.com/network/iptables/) si se llega a ese punto.

---

## 5. Configuración del router

El router doméstico es la pieza que **el homelab no controla con código** — la configura el operador desde la UI del router. Esta sección documenta exactamente qué tiene que hacer y por qué.

### 5.1. Reservación DHCP por MAC para la Pi 5

La Pi 5 obtiene su IP `192.168.1.10` por **reservación DHCP por MAC**, no por IP estática configurada en `/etc/network/interfaces` ni en `dhcpcd.conf`. Razón: si en el futuro el operador mueve la Pi a otra LAN (mudanza, segunda casa, lab improvisado), basta replicar la reserva en el router de destino — no hay nada que cambiar en la Pi.

Pasos en la UI del router (varía por modelo; concepto idéntico):

| Router típico | Ruta UI | Acción |
|---|---|---|
| AVM Fritz!Box | Heimnetz → Netzwerk → click sobre el dispositivo Pi → "Diesem Netzwerkgerät immer die gleiche IPv4-Adresse zuweisen" | Marcar la opción. |
| Mikrotik | IP → DHCP Server → Leases → seleccionar lease activo → "Make Static" | Click. |
| ASUS / Linksys / TP-Link | LAN → DHCP Server → Address Reservation → Add | MAC de la Pi + IP `192.168.1.10`. |
| Movistar / Telefónica HGU | Configuración avanzada → DHCP → Reservas | Idem. |

La MAC de la Pi se lee con:

```bash
ip link show eth0 | awk '/ether/ {print $2}'
```

Una vez fijada la reserva: reboot de la Pi (`sudo reboot`), comprobar `ip a show eth0`: la IP debe ser `192.168.1.10`.

### 5.2. Exclusión del rango macvlan del pool DHCP

El router **no debe** entregar IPs en `192.168.1.240`–`192.168.1.255` por DHCP. Si lo hace, un dispositivo nuevo que entre a la LAN puede recibir `192.168.1.241` (la IP de Pi-hole) y provocar un ARP conflict — Pi-hole responde por ARP, el dispositivo nuevo también, y la LAN queda con DNS roto intermitente y dificilísimo de depurar.

Cómo se hace según router:

| Router | Acción |
|---|---|
| AVM Fritz!Box | Heimnetz → Netzwerk → Netzwerkeinstellungen → IPv4-Einstellungen → cambiar el rango DHCP a `192.168.1.100`–`192.168.1.239`. |
| Mikrotik | IP → Pool → editar `dhcp_pool` → `192.168.1.100-192.168.1.239`. |
| ASUS / Linksys / TP-Link | LAN → DHCP Server → IP Pool Starting/Ending Address → `192.168.1.100` / `192.168.1.239`. |
| Movistar / Telefónica HGU | Configuración avanzada → DHCP → Rango → Inicio `192.168.1.100`, Fin `192.168.1.239`. |

Verificación tras el cambio: en el router, mirar la lista de DHCP leases activos. Ningún lease debe estar en `.240`–`.255`. Si lo hubiera, hacer release+renew en el dispositivo culpable (apagar/encender WiFi en un móvil) para que tome una IP nueva del pool reducido.

### 5.3. DNS del router → Pi-hole

El router se reconfigura para que **el DNS que entrega a sus clientes DHCP** sea Pi-hole (`192.168.1.241`), no el upstream del ISP. Detalles en [`../03-red/02-pihole.md`](../03-red/02-pihole.md) §4.2; aquí solo se consigna que el cambio existe y forma parte del mapa de red.

| Router | Acción |
|---|---|
| AVM Fritz!Box | Heimnetz → Netzwerk → Netzwerkeinstellungen → DHCP → "Lokaler DNS-Server" → `192.168.1.241`. |
| Mikrotik | IP → DHCP Server → Networks → editar `dns-server` → `192.168.1.241`. |
| ASUS / Linksys / TP-Link | LAN → DHCP Server → DNS → primario `192.168.1.241`, secundario vacío (no `1.1.1.1`: si Pi-hole cae, el secundario evita el bloqueo de anuncios y el operador no se entera). |
| Movistar / Telefónica HGU | Configuración avanzada → DHCP → DNS primario → `192.168.1.241`. |

Tras el cambio, `release+renew` en cualquier cliente y verificar:

```bash
# Desde un cliente de la LAN:
nslookup google.com             # debe responder vía 192.168.1.241
nslookup pihole.lan             # debe resolver a 192.168.1.10 (host de Caddy)
```

### 5.4. Port forwarding (única regla)

| # | Puerto externo | Protocolo | Destino interno | Servicio | Justificación |
|---|---|---|---|---|---|
| 1 | `51413` | TCP | `192.168.1.10:51413` | Transmission peer | BitTorrent es P2P; sin port forwarding entrante el ratio cae y muchos trackers privados penalizan al peer como "mal conectado". Ver [`../10-descargas/01-transmission.md`](../10-descargas/01-transmission.md) §0. |
| 2 | `51413` | UDP | `192.168.1.10:51413` | Idem (uTP / DHT) | Idem. |

> **Es la única.** Cualquier otra regla en la lista de port forwarding del router es **deriva**. El playbook trimestral ([`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md) §6) revisa esa lista contra esta tabla. Si aparece, por ejemplo, `8443 → 192.168.1.10:8443` que el operador puso un día "para probar acceder a Caddy desde fuera sin Tailscale", se elimina.

> **Si el operador no quiere ni esa**: la variante "Wireguard out via gluetun" en [`../10-descargas/01-transmission.md`](../10-descargas/01-transmission.md) §12.1 enruta TODO el tráfico de Transmission por una VPN comercial — y el port forwarding del router se elimina por completo.

### 5.5. Sin DDNS, sin DMZ, sin UPnP

| Cosa que NO se configura | Por qué |
|---|---|
| **DDNS** (NoIP, DuckDNS, Cloudflare DNS dinámico) | Sin servicios web expuestos a internet, no hay nombre que registrar. Tailscale tiene su propio MagicDNS. |
| **DMZ** ("apuntar todo el tráfico no asignado a la Pi") | Convertiría la Pi en host expuesto a internet. Lo contrario al modelo del homelab. |
| **UPnP / NAT-PMP** en el router | Permite que clientes en la LAN abran puertos automáticamente. Modelo de seguridad débil; cualquier malware del LAN podría abrir un puerto. **Desactivado** en el router. Transmission tiene también `port-forwarding-enabled: false` en `settings.json` ([`../10-descargas/01-transmission.md`](../10-descargas/01-transmission.md) §6). |
| **IPv6** | El homelab opera en IPv4 puro. IPv6 no se configura ni en el router ni en `/etc/docker/daemon.json` (Docker IPv6 está deshabilitado por defecto). Si en el futuro se habilita, este doc tiene que ampliarse con un §4 análogo para `::/0`. |
| **Firewall del router** abierto a Pi a `0.0.0.0/0` | Solo se abre el `51413` y nada más. Cualquier "permitir todo el tráfico entrante a la Pi" rompe el modelo. |

---

## 6. Firewall (`ufw` + `nftables`/`fail2ban`)

`ufw` es la fachada amigable; `nftables` (con kernel ≥ 4.18) es el motor en Bookworm. `fail2ban` se apoya directamente en `nftables` (no en `ufw`) para los bans, según convención §5.2 de [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md).

### 6.1. Política por defecto

```bash
$ sudo ufw status verbose
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)
New profiles: skip
```

Tres reglas se aplican por defecto:

- **`deny incoming`**: bloquea cualquier conexión entrante que no tenga regla explícita.
- **`allow outgoing`**: permite cualquier conexión saliente (revisar §4.4 si en el futuro se quiere endurecer).
- **`disabled routed`**: el host no enruta tráfico (no es un router); la cadena `FORWARD` queda gestionada por Docker para sus bridges.

### 6.2. Reglas explícitas

Cada regla la añade un doc anterior. Aquí se consolida la lista cerrada:

| # | Regla `ufw` | Origen | Puerto/Proto | Servicio | Doc origen |
|---|---|---|---|---|---|
| 1 | `LIMIT 22/tcp` | `192.168.1.0/24` | 22/tcp | SSH (con rate limit `ufw limit`: 6 intentos / 30s por IP) | [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §4.3 |
| 2 | `ALLOW 80/tcp` | `192.168.1.0/24` | 80/tcp | Caddy HTTP (redirect → HTTPS) | [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §0 |
| 3 | `ALLOW 443/tcp` | `192.168.1.0/24` | 443/tcp | Caddy HTTPS | [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §0 |
| 4 | `ALLOW 445/tcp` | `192.168.1.0/24` | 445/tcp | Samba | [`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md) |
| 5 | `ALLOW 51413` | (cualquiera) | 51413/tcp+udp | Transmission peer | [`../10-descargas/01-transmission.md`](../10-descargas/01-transmission.md) §6 |

> **Regla 5 sin restricción de origen**: el peer port de BitTorrent recibe conexiones de peers en internet (vía port forwarding del router). Restringirla a `192.168.1.0/24` rompe el funcionamiento. El control del acceso lo hace Transmission a nivel de aplicación (peer protocol, `rpc-whitelist` para la API, etc.), no `ufw`.

> **No hay regla para `41641/udp` (Tailscale)**: Tailscale gestiona su propio firewall para `tailscale0`. El daemon escucha en `41641/udp` en el host pero el tráfico Tailscale **bypassa** las cadenas `INPUT` de `ufw` por la interfaz virtual.

Verificar la lista numerada:

```bash
sudo ufw status numbered
```

Y la traducción a `nftables`:

```bash
sudo nft list ruleset | head -50
```

### 6.3. `fail2ban`: jails activos

El homelab tiene **dos** capas de jails de `fail2ban`:

| Capa | Jail | Backend | Banaction | Doc origen |
|---|---|---|---|---|
| Host (Fase 1) | `sshd` | `systemd` (journald) | `nftables-allports` | [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) §5.2 |
| Servicios (Fase 4) | `authelia`, `nextcloud`, `vaultwarden` (según corresponda) | `systemd` o `tail` sobre logs de contenedores | `nftables-allports` | [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) |

`bantime.increment = true` aplica para todos: una IP que vuelve tras un baneo se gana baneos progresivamente más largos (1h → 2h → 4h → 8h → ... hasta `bantime.maxtime = 1w`).

`ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24`: la propia LAN nunca se banea (protección frente a errores del operador).

Verificar:

```bash
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

Salida esperada (extracto):

```
Status for the jail: sshd
|- Filter
|  |- Currently failed: 0
|  |- Total failed:     27
|  `- Journal matches:  _SYSTEMD_UNIT=sshd.service + _COMM=sshd
`- Actions
   |- Currently banned: 0
   |- Total banned:     2
   `- Banned IP list:
```

`Total banned > 0` con `Currently banned: 0` es estado normal: hubo intentos, se baneó, pasó el `bantime`, se desbanéo automáticamente.

### 6.4. Tráfico que NO atraviesa el firewall del host

Esta sección es la causa más frecuente de confusión durante depuración. Los siguientes tipos de tráfico **no se filtran** por `ufw`:

| Tráfico | Por qué no | Implicación |
|---|---|---|
| **macvlan** (Pi-hole en `192.168.1.241`, Unbound en `192.168.1.242`) | Los contenedores macvlan tienen su propia MAC y van directo del switch al contenedor; nunca pasan por el stack del host. | El control de acceso lo hace Pi-hole/Unbound a nivel aplicación (`access-control` de Unbound, password admin de Pi-hole). |
| **Docker bridge `homelab`** | Docker gestiona su propia cadena `DOCKER` antes de las cadenas `FORWARD` del host. `ufw` no ve este tráfico salvo que el operador edite `/etc/default/ufw` con `DEFAULT_FORWARD_POLICY="DROP"` y reinicie (no se hace en el homelab). | El control de acceso entre contenedores lo hacen las propias redes Docker (qué red junta a qué contenedores) y, donde aplica, Authelia. |
| **`tailscale0`** | Tailscale crea esta interfaz como WireGuard userspace (o kernel). El tráfico que entra por `tailscale0` no pasa por las reglas `ufw` de `eth0`. | El control de acceso lo gestiona Tailscale ACLs (en el panel admin) o, dentro del host, el operador puede crear reglas `nftables` específicas para `iif tailscale0` si quisiera filtrar — no se hace por defecto. |
| **`docker0`** y bridges Docker no nombrados (Stash, Z2M, dashboard_internal, ...) | Idem que `homelab`. | Idem. |

> **La regla mental**: `ufw` controla **el tráfico que pasa por `eth0`** y va dirigido al host. Cualquier otra cosa la controla otro mecanismo. Si en el futuro el operador quiere endurecer, hay tres palancas: (1) ACLs de Tailscale en el panel, (2) `access-control:` de Unbound, (3) reglas `nftables` manuales en `DOCKER-USER`. Las tres viven fuera de `ufw`.

---

## 7. Tailscale en el modelo

Cómo encaja Tailscale en este mapa:

### 7.1. Qué hace

- Crea la interfaz virtual `tailscale0` en el host con una IP CGNAT (`100.64.0.10` o similar; depende del nodo).
- Anuncia ese nodo en la tailnet privada del operador (`https://login.tailscale.com`).
- Ofrece **MagicDNS**: cualquier dispositivo de la tailnet resuelve `pi.${TS_DOMAIN}` → `100.64.0.10`. El operador configura registros DNS adicionales (`jellyfin.${TS_DOMAIN}`, etc.) en el panel de Tailscale o vía wildcard CNAME.
- Genera certificados Let's Encrypt para `*.${TS_DOMAIN}` con `tailscale cert` ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) §7). Esos certificados los recoge Caddy.

### 7.2. Qué puertos abre

Solo en el host, no en el router:

| Puerto | Proto | Dirección | Para qué |
|---|---|---|---|
| **41641** | UDP | Saliente + entrante (tras hole-punching) | WireGuard a otros nodos directos. |
| **3478** | UDP | Saliente | STUN para resolución NAT. |
| **443** | TCP | Saliente | DERP relay (cuando hole-punching falla); control plane (`controlplane.tailscale.com`); `tailscale cert` (Let's Encrypt). |

Ninguno requiere port forwarding en el router porque Tailscale resuelve NAT por sí mismo.

### 7.3. Qué NO hace

- **No es subnet router**: la Pi no anuncia su subred LAN (`192.168.1.0/24`) a la tailnet. Si el operador quiere acceder desde fuera al móvil que vive en `192.168.1.105`, tiene que instalar Tailscale en ese móvil. Para los servicios del homelab basta porque viven en la propia Pi (`100.64.0.10`).
- **No es exit node**: el operador no enruta su tráfico de internet a través de la Pi cuando está fuera de casa.
- **No interfiere con `ufw`**: el tráfico Tailscale entrante no se ve afectado por la política `deny incoming` (es otra interfaz).

Si en el futuro se activa "subnet routing" o "exit node", **este doc se actualiza** con la subred anunciada (típicamente `192.168.1.0/24`) y las implicaciones (clientes Tailscale podrían llegar a `192.168.1.241` directamente, salteando la macvlan limitada a la LAN física).

---

## 8. Cambios recurrentes en el mapa

Esta sección documenta los flujos típicos de cambio que el operador encara una vez al año. Cada uno cierra con su entrada en `maintenance.log`.

### 8.1. Añadir un servicio web nuevo

Patrón canónico (igual al de cualquier doc de Fase 5–12):

1. **Definir el `docker-compose.yml`** del servicio en `/mnt/hd2t/services/<servicio>/`:
   - Sin `ports:` publicados (regla §1.2).
   - Conectado a la red `homelab` con `external: true`.
   - Documentar el puerto interno en una tabla coherente con §4.3.
2. **Añadir bloque a Caddy** (`Caddyfile` o snippet en `/etc/caddy/sites/`):
   ```
   <servicio>.lan, <servicio>.${TS_DOMAIN} {
     reverse_proxy <servicio>:<puerto-interno>
     forward_auth authelia:9091 { ... }   # opcional, si lleva Authelia
   }
   ```
3. **Recargar Caddy**: `docker exec caddy caddy reload --config /etc/caddy/Caddyfile`.
4. **Añadir entrada A en Pi-hole** (Local DNS Records): `<servicio>.lan` → `192.168.1.10`.
5. **Añadir registro a la tailnet** (panel Tailscale → DNS) si se quiere `<servicio>.${TS_DOMAIN}` resuelto por MagicDNS.
6. **Actualizar este doc**: añadir línea a la tabla del §4.3.
7. **Bitácora**:
   ```text
   2026-09-04 · ad-hoc · red: alta de servicio <foo> en homelab; puerto interno <X>; Caddy proxy a foo.lan + foo.${TS_DOMAIN}; Pi-hole A foo.lan→192.168.1.10 · OK
   ```
   Commit `ops: maintenance ad-hoc 2026-09-04 alta servicio foo`.

> **Si el servicio nuevo necesita publicar al host**: parar. Reabrir esta discusión: ¿puede ir detrás de Caddy? ¿es UI HTTP/HTTPS? Si la respuesta es sí, reverse proxy es siempre preferible. Solo si el servicio usa un protocolo no-HTTP (SMB, MQTT plano público, etc.) se justifica una excepción — y entra en §4.1 con su justificación.

### 8.2. Retirar un servicio

1. `docker compose down -v` (o `down` sin `-v` si se quieren conservar volúmenes).
2. Eliminar el bloque de Caddy.
3. Recargar Caddy.
4. Eliminar la entrada A de Pi-hole (Local DNS).
5. Eliminar el registro de la tailnet (si aplica).
6. **Actualizar este doc**: borrar la línea de §4.3.
7. **Bitácora**:
   ```text
   2026-10-20 · ad-hoc · red: baja de servicio <foo>; eliminados Caddy block, Pi-hole A, tailnet record · OK
   ```

### 8.3. Cambiar la subred LAN (mudanza, ISP nuevo)

Caso pesado pero documentado:

1. **Apagar la Pi** antes de tocar el router.
2. Reconfigurar el router nuevo:
   - Subred (ej. `192.168.0.0/24` en lugar de `192.168.1.0/24`).
   - Reservar IP equivalente para la Pi (`192.168.0.10`).
   - Excluir el rango macvlan equivalente (`192.168.0.240/28`).
   - DNS DHCP apuntando a la nueva IP de Pi-hole (`192.168.0.241`).
   - Port forwarding `51413` → nueva IP de la Pi.
3. **Editar `docker-compose.yml` de Pi-hole y Unbound**: cambiar `ipv4_address` y la `subnet`/`gateway` de la red `lan_macvlan` (declarada como `external: false` o gestionada con `docker network rm + create`).
4. **Editar `lan-shim.service`**: cambiar la IP del shim (`192.168.0.240/32`).
5. **Editar Caddy**: actualizar referencias a `192.168.1.10` si hay alguna explícita (los nombres `*.lan` no requieren cambio porque Pi-hole los resuelve a la nueva IP).
6. **Editar Pi-hole Local DNS Records**: las entradas A pasan de `192.168.1.10` a `192.168.0.10`.
7. **Editar regla `ufw`** de SSH: `192.168.1.0/24` → `192.168.0.0/24`. Idem regla 80, 443, 445.
8. **Actualizar este doc completo**: tabla de direccionamiento (§3), reglas `ufw` (§6.2), router (§5).
9. **Bitácora extensa**:
   ```text
   2026-12-15 · ad-hoc · red: cambio de subred LAN 192.168.1.0/24 → 192.168.0.0/24 (mudanza). Editados Pi-hole, Unbound, lan-shim, ufw, Caddy, Pi-hole DNS, port forwarding. Verificación OK · 04-red-y-puertos.md actualizado
   ```

### 8.4. Añadir una nueva regla de port forwarding (caso excepcional)

Cualquier intento de añadir una segunda regla de port forwarding **vuelve a este doc primero**. La motivación tiene que ser explícita y por escrito en el commit message. Ejemplos plausibles y su tratamiento:

| Motivación | Tratamiento recomendado |
|---|---|
| "Quiero que mi web pública (un sitio personal) la sirva la Pi" | **Mejor opción**: Tailscale Funnel (Tailscale ofrece exposición pública opt-in vía sus relays). Cero port forwarding. |
| "Quiero que un amigo se conecte a mi Vaultwarden sin Tailscale" | **Mejor opción**: instalar Tailscale en el dispositivo del amigo (3 minutos). Sigue el modelo del homelab. |
| "Quiero un servicio Game/Chat con port entrante" | Caso a caso. Se documenta en este doc con su justificación, y se acepta el aumento de superficie de ataque. |

Si finalmente se añade: nueva fila en §5.4, nueva fila en §4.1 (puertos host), entrada en `maintenance.log`, commit dedicado.

---

## 9. Verificación

El mapa de §4 es solo un papel hasta que se confirma contra la realidad. Esta sección define los comandos canónicos.

### 9.1. Desde la Pi: qué escucha

```bash
# Sockets TCP escuchando, con proceso:
sudo ss -tnlp

# Sockets UDP escuchando, con proceso:
sudo ss -unlp

# Solo los del host (excluyendo localhost-only):
sudo ss -tnlp '! ( src 127.0.0.1 or src ::1 )'
```

Salida esperada (extracto, en estado nominal):

```
LISTEN 0  128  0.0.0.0:22       0.0.0.0:*  users:(("sshd",pid=...))
LISTEN 0  128  0.0.0.0:80       0.0.0.0:*  users:(("docker-proxy",pid=...))
LISTEN 0  128  0.0.0.0:443      0.0.0.0:*  users:(("docker-proxy",pid=...))
LISTEN 0  128  0.0.0.0:445      0.0.0.0:*  users:(("smbd",pid=...)) | docker-proxy
LISTEN 0  128  0.0.0.0:51413    0.0.0.0:*  users:(("transmission",pid=...))
LISTEN 0  128  0.0.0.0:41641    0.0.0.0:*  users:(("tailscaled",pid=...))
```

Cualquier puerto extra (ej. `0.0.0.0:8989` aparecerá si alguien añadió `ports: - "8989:8989"` a Sonarr) → §11 ("puerto inesperado").

### 9.2. Desde otro equipo en la LAN: qué se ve

```bash
# Escaneo TCP completo de la Pi:
sudo nmap -sS -p 1-65535 192.168.1.10

# Escaneo UDP de los puertos relevantes (más lento):
sudo nmap -sU -p 53,123,445,51413,41641 192.168.1.10

# Las macvlan:
sudo nmap -sS -p 1-1024 192.168.1.241
sudo nmap -sS -p 1-1024 192.168.1.242
```

Esperable:

```
192.168.1.10
  22/tcp    open  ssh
  80/tcp    open  http
  443/tcp   open  https
  445/tcp   open  microsoft-ds
  51413/tcp open  unknown
  (UDP 53 cerrado: el host no escucha allí; lo hace Pi-hole en .241)
  (UDP 41641: Tailscale; puede aparecer "open|filtered")

192.168.1.241  (Pi-hole)
  53/tcp    open  domain
  53/udp    open  domain
  80/tcp    open  http     (Pi-hole UI plano)

192.168.1.242  (Unbound)
  (5335 cerrado externamente: access-control de Unbound rechaza si no es 192.168.1.241 o 192.168.1.240)
```

> **Importante**: `nmap` desde la propia Pi a `192.168.1.241` falla por el problema kernel/macvlan (§4 de [`../03-red/01-macvlan.md`](../03-red/01-macvlan.md)). El escaneo honesto se hace **siempre desde otro equipo**.

### 9.3. Redes Docker

```bash
# Inventario de redes:
docker network ls

# Detalle de cada una:
docker network inspect homelab
docker network inspect lan_macvlan
docker network inspect dns_internal
```

Esperable: `homelab` con todos los servicios listados, `lan_macvlan` con `pihole` y `unbound` (más sus IPs `.241`/`.242`), `dns_internal` con solo `pihole` y `unbound`.

### 9.4. Smoke test: "el mapa coincide con la realidad"

Script idempotente que se puede ejecutar en sesión semanal o tras un cambio:

```bash
#!/usr/bin/env bash
# ~/homelab/operations/scripts/red-puertos-check.sh
# Comprueba que los puertos publicados al host coinciden con la lista cerrada
# del documento docs/13-operaciones/04-red-y-puertos.md §4.1.

set -u
EXPECTED_TCP="22 80 443 445 51413"
EXPECTED_UDP="51413 41641"

actual_tcp=$(sudo ss -tnlp 'sport > :0' \
  | awk 'NR>1 {split($4,a,":"); print a[length(a)]}' \
  | sort -u | grep -E '^[0-9]+$' \
  | grep -v '^127' \
  | xargs)

actual_udp=$(sudo ss -unlp \
  | awk 'NR>1 {split($4,a,":"); print a[length(a)]}' \
  | sort -u | grep -E '^[0-9]+$' \
  | xargs)

extra_tcp=$(comm -23 <(echo "$actual_tcp" | tr ' ' '\n' | sort -u) \
                      <(echo "$EXPECTED_TCP" | tr ' ' '\n' | sort -u))
extra_udp=$(comm -23 <(echo "$actual_udp" | tr ' ' '\n' | sort -u) \
                      <(echo "$EXPECTED_UDP" | tr ' ' '\n' | sort -u))

if [ -n "$extra_tcp" ] || [ -n "$extra_udp" ]; then
  echo "DRIFT detected:"
  [ -n "$extra_tcp" ] && echo "  Puertos TCP no esperados en el host: $extra_tcp"
  [ -n "$extra_udp" ] && echo "  Puertos UDP no esperados en el host: $extra_udp"
  exit 1
fi
echo "OK: puertos del host coinciden con el mapa."
```

Anotar `0` o `1` del exit code en el `maintenance.log` semanal:

```text
2026-09-13 · weekly · red: red-puertos-check.sh OK · sin deriva
```

### 9.5. Verificar router

Cuatro verificaciones manuales en la UI del router, una vez al trimestre:

1. **Pool DHCP**: rango `192.168.1.100`–`192.168.1.239`, no incluye `.240`–`.255`.
2. **Reservas**: `192.168.1.10` reservada por MAC para la Pi 5 (la del operador).
3. **DNS DHCP**: primario `192.168.1.241`. Secundario vacío (o también Pi-hole si el router obliga a dos).
4. **Port forwarding**: una sola regla, `51413/tcp+udp` → `192.168.1.10:51413`. No hay otras.

Anotar en `maintenance.log` con cadencia `quarterly`:

```text
2026-10-05 · quarterly · red: auditoría router OK (pool .100-.239, reserva Pi .10, DNS Pi-hole, port forward solo 51413)
```

---

## 10. Lista de Verificación

### 10.1. Tras desplegar el homelab por primera vez

- [ ] `sudo ufw status verbose` muestra `active`, política `deny incoming` / `allow outgoing`, las 5 reglas del §6.2 presentes.
- [ ] `sudo fail2ban-client status` lista al menos `sshd`. Si Fase 4 está desplegada, también `authelia` y otros.
- [ ] `sudo ss -tnlp` muestra **solo** los puertos del §4.1 escuchando en `0.0.0.0` o equivalente.
- [ ] `nmap -sS -p1-65535 192.168.1.10` desde otro equipo confirma la lista.
- [ ] `nmap -sS -p1-1024 192.168.1.241` muestra `:53` y `:80` abiertos.
- [ ] `nmap -sS -p1-1024 192.168.1.242` muestra **todo cerrado** (Unbound rechaza al equipo que escanea, no a Pi-hole).
- [ ] `tailscale status` muestra el nodo Pi como conectado y con MagicDNS activo.
- [ ] El router tiene exactamente: pool DHCP `.100-.239`, reserva Pi en `.10`, DNS DHCP = `192.168.1.241`, un único port forward (`51413`).
- [ ] Pi-hole Local DNS tiene entradas A para todos los `*.lan` documentados.
- [ ] Tailscale panel tiene los CNAME / DNS records para `*.${TS_DOMAIN}` si se usan.
- [ ] Smoke test §9.4 retorna `OK`.

### 10.2. Mensual

- [ ] Smoke test §9.4 ejecutado, anotado en `maintenance.log`.
- [ ] `nmap` desde otro equipo de la LAN, comparado con §4.1. Anotar.
- [ ] Auditoría visual del Caddyfile vs §4.3: ¿hay algún bloque para un servicio que ya no existe? ¿falta alguno?
- [ ] Auditoría visual de `~/homelab/operations/maintenance.log` filtrando `red:` para ver el flujo de cambios del mes.

### 10.3. Trimestral

- [ ] Auditoría manual del router (§9.5).
- [ ] Revisar lista de port forwarding del router. Cualquier regla distinta de `51413` se elimina.
- [ ] Revisar lista de DHCP leases activos: ningún cliente está en `.240-.255`.
- [ ] Verificar que Pi-hole sigue siendo el DNS primario en al menos 2 dispositivos LAN reales (móvil + portátil).

### 10.4. Antes de retirar un servicio

- [ ] Bloque de Caddy retirado y Caddy recargado.
- [ ] Entrada A en Pi-hole eliminada.
- [ ] Registro tailnet eliminado.
- [ ] Tabla §4.3 actualizada.
- [ ] `maintenance.log` con `ad-hoc · red: baja servicio ...`.

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| Aparece un puerto **inesperado** en `ss -tnlp` (p.ej. `0.0.0.0:8989`) | Alguien añadió `ports: - "8989:8989"` a Sonarr (o equivalente en otro servicio) | Identificar contenedor con `docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep ':8989'`. Editar su `docker-compose.yml` quitando la línea `ports:`. `docker compose up -d`. Confirmar con `ss -tnlp` que el puerto ya no aparece. Anotar en `maintenance.log`. |
| `nmap 192.168.1.241` desde un cliente LAN muestra **cerrado en `:53`** | Pi-hole caído, o el contenedor está en `homelab` pero perdió la red `lan_macvlan` | `docker compose ps` en stack pi-hole. `docker compose logs pihole | tail -50`. Si "no route to host" tras un reinicio, revisar [`../03-red/01-macvlan.md`](../03-red/01-macvlan.md) §6 (lan-shim). |
| Cliente LAN no resuelve `*.lan` | DHCP del router no está entregando Pi-hole como DNS, o Pi-hole no tiene la entrada A creada | `nslookup pihole.lan 192.168.1.241` desde el cliente: si responde, el problema es el router (revisar §5.3); si no, el problema es Pi-hole (revisar Local DNS Records). |
| `nmap 192.168.1.10` muestra puertos esperados pero `nmap` desde la Pi misma a `192.168.1.241` falla | No es bug — kernel/macvlan limitation | El `lan-shim` debería estar activo: `ip a show lan-shim`. Si no existe, `sudo systemctl start lan-shim.service` y revisar [`../03-red/01-macvlan.md`](../03-red/01-macvlan.md) §5. |
| Tailscale conectado pero `https://jellyfin.${TS_DOMAIN}` no abre | Cert no renovado, o registro DNS de la tailnet inexistente | `tailscale status` (debe mostrar el nodo). `ls /mnt/hd2t/services/proxy/tailscale-certs/` (debe haber `${TS_DOMAIN}.crt`). Si vacío: `tailscale cert` manual ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) §7). Si falta DNS, ir al panel Tailscale → DNS y añadir CNAME wildcard o el registro específico. |
| Router muestra **dos** reglas de port forwarding (51413 + otra) | Deriva: alguien añadió una regla "para probar" y la dejó | Eliminar la regla extra. Si era legítima, documentarla en §5.4 antes de volver a añadirla. Anotar en `maintenance.log`. |
| `ufw` aparece `inactive` tras un reboot | El servicio `ufw` no se habilitó en `systemd` | `sudo systemctl enable ufw`; `sudo ufw enable`. |
| Pi-hole UI **no se abre vía Caddy** (`https://pihole.lan` da 502) pero **sí** se abre vía IP (`http://192.168.1.241/admin/`) | Pi-hole vive (su macvlan responde) pero está fuera de la red `homelab`, o Caddy perdió la red | `docker network inspect homelab | grep pihole`: debe aparecer Pi-hole. Si no, revisar [`../03-red/02-pihole.md`](../03-red/02-pihole.md) §0 (debe estar en las TRES redes). |
| Unbound responde a `nmap` desde un cliente LAN cualquiera | `access-control` mal configurado | Revisar [`../03-red/03-unbound.md`](../03-red/03-unbound.md) §0: debe haber `access-control: 0.0.0.0/0 refuse` y solo `192.168.1.241/32` y `192.168.1.240/32` con `allow`. `docker compose restart unbound`. |
| Transmission no recibe peers entrantes ("Status: Closed" en transmission-remote) | Port forward del router caído o IP de la Pi cambió | `transmission-remote -l` debe listar torrents. `transmission-remote -pt` desde fuera de la LAN (p.ej. desde el portátil con datos móviles): debe responder "Port is open". Si no, revisar la regla del router (§5.4). Si la IP de la Pi ha cambiado, revisar reserva DHCP por MAC. |
| `sudo nft list ruleset` muestra muchísimas reglas inesperadas | Es Docker, no problema | Docker mantiene sus propias cadenas (`DOCKER`, `DOCKER-USER`, `DOCKER-ISOLATION-*`) y `fail2ban` mantiene `f2b-*`. Es normal. Lo único que el operador audita son las cadenas `INPUT`/`FORWARD` de `ufw`. |
| Smoke test §9.4 reporta "DRIFT": puerto `0.0.0.0:9091` activo | Authelia o Transmission publicó al host | Buscar el `ports:` extraviado. La causa más común: alguien probó un cambio en `docker-compose.yml` y olvidó revertir. Quitar la línea, `docker compose up -d`. |
| Cliente con Tailscale activo pero no puede abrir `https://jellyfin.${TS_DOMAIN}` desde fuera de casa | MagicDNS desactivado en el panel Tailscale, o el dispositivo tiene DNS propio overrideando | Panel Tailscale → DNS → MagicDNS habilitado. En el cliente, `tailscale status` debe mostrar la pi como conectada. Probar `curl https://pi.${TS_DOMAIN}` (la página de Caddy que cae a `pi.${TS_DOMAIN}` sin host header específico). |
| `nmap -sU -p 41641 192.168.1.10` muestra `open|filtered` desde fuera del LAN | Es Tailscale; depende de si hay un peer activo justo en ese momento | Es comportamiento normal. Tailscale "perfora" el NAT solo cuando hay tráfico activo. No es un servicio expuesto. |
| Después de un cambio de router (mudanza), Pi-hole no resuelve | DNS upstream apuntando al router viejo, o Unbound no tiene salida | `docker compose logs pihole | tail -100` y `unbound | tail -100`. Confirmar que `192.168.1.1` (gateway nuevo) responde a `ping`. Si Unbound no llega a root servers, problema de DNS recursivo: revisar [`../03-red/03-unbound.md`](../03-red/03-unbound.md). |
| Aparece tráfico saliente a IPs desconocidas en `iftop`/`vnstat` | Una integración de HA, scrapers de Mealie, FreshRSS feeds, … | Identificar contenedor con `sudo conntrack -L | grep <ip>` o `docker stats --format '...{{.Name}} {{.NetIO}}'`. Si es legítimo, documentar; si no (raro), `docker compose down` el sospechoso, mirar logs, decidir si seguir teniéndolo. |

---

## Referencias

- [`../03-red/01-macvlan.md`](../03-red/01-macvlan.md) — Diseño y operación de la red macvlan.
- [`../03-red/02-pihole.md`](../03-red/02-pihole.md) — Pi-hole en macvlan + red `homelab`.
- [`../03-red/03-unbound.md`](../03-red/03-unbound.md) — Unbound resolver recursivo, `access-control`.
- [`../03-red/04-caddy.md`](../03-red/04-caddy.md) — Caddy reverse proxy, certificados, bloques por servicio.
- [`../03-red/05-tailscale.md`](../03-red/05-tailscale.md) — Tailscale, MagicDNS, `tailscale cert`.
- [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md) — `ufw`, `fail2ban` jail SSH.
- [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) — Authelia como `forward_auth`.
- [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) — Jails de aplicación (Authelia, Nextcloud, Vaultwarden).
- [`../06-almacenamiento/02-samba.md`](../06-almacenamiento/02-samba.md) — Samba `:445` al host.
- [`../10-descargas/01-transmission.md`](../10-descargas/01-transmission.md) — Transmission peer port y la única regla de port forwarding.
- [`./01-mantenimiento-periodico.md`](./01-mantenimiento-periodico.md) — Cadencias y bitácora.
- [`./02-disaster-recovery.md`](./02-disaster-recovery.md) — Reconstrucción del mapa tras pérdida total.
- [`./03-rendimiento-pi5.md`](./03-rendimiento-pi5.md) — Tuning, observabilidad, presupuestos.
- [Ubuntu — `ufw` reference](https://help.ubuntu.com/community/UFW)
- [`nftables` Wiki](https://wiki.nftables.org/wiki-nftables/index.php/Main_Page)
- [Docker — Networking overview](https://docs.docker.com/network/)
- [Docker — `macvlan` driver](https://docs.docker.com/network/drivers/macvlan/)
- [Tailscale — How NAT traversal works](https://tailscale.com/blog/how-nat-traversal-works)
- [Tailscale — MagicDNS](https://tailscale.com/kb/1081/magicdns)
- [Tailscale — `tailscale cert` (HTTPS for nodes)](https://tailscale.com/kb/1153/enabling-https)
- [`fail2ban` — `nftables` action](https://github.com/fail2ban/fail2ban/blob/master/config/action.d/nftables-allports.conf)
- [Pi-hole — Documentation](https://docs.pi-hole.net/)
- [Unbound — `access-control`](https://nlnetlabs.nl/documentation/unbound/unbound.conf/)
