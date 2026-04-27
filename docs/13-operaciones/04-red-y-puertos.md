# Red y puertos del homelab

## Descripción

Cierre cartográfico de la **superficie de red** del homelab: qué escucha, dónde, sobre qué interfaz, con qué firewall delante y por qué. Este doc no introduce servicios nuevos — todos los servicios que aparecen aquí ya están desplegados por sus respectivos documentos de fases anteriores. Lo que añade es una **vista única y consolidada** del mapa de puertos, las reglas de `nftables` que materializan la política "LAN + Tailscale, nada más" y las dos o tres líneas de configuración del router que la sostienen.

A diferencia de `docs/13-operaciones/01-mantenimiento-periodico.md` (calendario), `docs/13-operaciones/02-disaster-recovery.md` (recuperación) y `docs/13-operaciones/03-rendimiento-pi5.md` (operación bajo carga), este documento responde a una pregunta operativa concreta y recurrente: **"¿qué hay escuchando dónde, y por qué está abierto?"**. Es el sitio al que delegan todos los demás cuando hace falta justificar un puerto, depurar una colisión o explicarle al operador del futuro por qué `:53` lo sirve `192.168.1.2` y no `192.168.1.3`.

> **Filosofía**: la política por defecto es `input drop` (`docs/01-sistema/03-seguridad-base.md`). Cada puerto que aparece en este mapa está **abierto explícitamente** porque hay un cliente legítimo que lo necesita; los puertos no listados están cerrados. La superficie expuesta a internet es **cero**: no hay _port forwarding_ en el router, no hay DDNS, no hay _Tailscale Funnel_. Tailscale es _outgoing_ (UDP `41641` saliente, _fallback_ TCP `443` contra DERP); ningún puerto del homelab se publica más allá del segmento `192.168.1.0/24` y del rango _tailnet_ `100.64.0.0/10`.

> **Alcance**: este doc cubre **lo que se ve desde fuera del contenedor** — puertos publicados al host (`ports:`), interfaces a las que bindean (`192.168.1.3`, `192.168.1.2`, `100.x.y.z`, `tailscale0`), reglas `nftables` del host y configuración del router. **No** entra en la red interna de Docker (`homelab` `172.20.10.0/24`, _embedded DNS_, descubrimiento por nombre de servicio): eso vive en `docs/02-docker/02-estructura-compose.md`. **No** entra en MagicDNS ni en _split DNS_ de Tailscale: eso vive en `docs/03-red/05-tailscale.md`.

> **Alcance de red**: el operador inspecciona y modifica este mapa **desde la LAN o vía Tailscale**. La consola del router se administra desde la LAN cableada (no por WiFi de invitado). Las verificaciones (`nmap`, `ss`, `tailscale status`) se ejecutan en la propia Pi por SSH (`docs/01-sistema/03-seguridad-base.md`).

---

## Requisitos previos

Para que este mapa sea coherente con la realidad, todo lo que cita debe estar ya desplegado:

- `docs/00-hardware/02-esquema-conexiones.md` completado: la Pi conectada por **Ethernet** (no WiFi) al router, con IP **fija** reservada en el DHCP del router como `192.168.1.3` (`HOMELAB_PI_IPV4`).
- `docs/01-sistema/03-seguridad-base.md` completado: `nftables` con política `input drop`/`forward drop`/`output accept`, regla de `tcp dport 22 accept` ya activa, persistencia vía `/etc/nftables.conf` y `nftables.service`.
- `docs/02-docker/01-instalacion-docker.md` completado: `dockerd` arranca **después** de `nftables.service`; `default-address-pools` fijado en `172.20.0.0/16` para que las redes Docker no choquen con la LAN.
- `docs/03-red/01-macvlan.md` completado: red Docker `macvlan` operativa con IPs reservadas para Pi-hole (`192.168.1.2`), Unbound (`192.168.1.4`) y el `macvlan-shim` del host (`192.168.1.250`).
- `docs/03-red/02-pihole.md`, `docs/03-red/03-unbound.md`, `docs/03-red/04-caddy.md` y `docs/03-red/05-tailscale.md` desplegados: las cuatro piezas de la fase 3 dan forma al mapa que este doc consolida.
- Caddy bindea `:80`, `:443/tcp`, `:443/udp` a **dos** IPs del host: `${HOMELAB_PI_IPV4}` (LAN) y `${TAILSCALE_IPV4}` (`100.x.y.z`, _tailnet_).
- `tailscaled` corriendo en el host con la regla saliente UDP `41641` permitida (la cadena `output` del firewall es `accept`, no hace falta tocar nada).
- Paquetes auxiliares en el host:
  ```bash
  sudo apt update
  sudo apt install -y nmap iproute2 net-tools tcpdump
  ```
  - `nmap`: barrido de puertos para auditorías periódicas.
  - `iproute2` (`ss`): inspección de _sockets_ activos. Ya viene en Debian Bookworm.
  - `tcpdump`: captura selectiva cuando un puerto "no responde" y hace falta confirmar si el paquete llega.

---

## Decisiones de diseño

### Una única IP "humana": `192.168.1.3`

Toda la LAN doméstica accede al homelab por **una sola IP**: la del host (`192.168.1.3`). El operador no aprende IPs de servicios — todo se resuelve por nombre (`jellyfin.lan`, `portainer.lan`, `nextcloud.lan`, `pi.<TAILNET>.ts.net`) gracias a Pi-hole + Caddy. Las dos IPs adicionales en la LAN (`192.168.1.2` Pi-hole, `192.168.1.4` Unbound) son **infraestructura** y sólo se usan en _bootstrap_ (configurar el router para apuntar el DNS a `192.168.1.2`) o _troubleshooting_ (`dig @192.168.1.4 ...`). El usuario familiar nunca las teclea.

### `*.lan` para LAN, `pi.<TAILNET>.ts.net` para Tailscale

- **Dentro de casa**: el cliente resuelve `jellyfin.lan` por Pi-hole → `192.168.1.3`, abre HTTPS con la **CA local** instalada en sus dispositivos (`docs/03-red/04-caddy.md`).
- **Fuera de casa**: el cliente está en el _tailnet_, resuelve `jellyfin.lan` por _split DNS_ de Tailscale (que delega `*.lan` a `100.100.100.100` → Pi-hole de la Pi), llega a Caddy en `100.x.y.z:443` por la interfaz `tailscale0`, ve el **mismo cert de la CA local**. El operador no aprende dos URLs.
- **Excepción**: `pi.<TAILNET>.ts.net` (cert público emitido por `tailscale cert`) sirve como _entry point_ de emergencia cuando la CA local no está instalada (un cliente prestado, un navegador "tonto"). Sólo el operador lo usa, no la familia.

### Pi-hole en macvlan, Caddy en bridge: la regla "53/80 a uno, 443 a otro"

Pi-hole necesita `:53/udp+tcp` y `:80/tcp` (panel admin _legacy_). Caddy necesita `:80/tcp` y `:443/tcp+udp`. Si los dos compartieran IP, `:80` colisionaría — y el `lighttpd` interno de Pi-hole no se puede mover (`docs/03-red/02-pihole.md`). La solución es **dos IPs distintas en la misma LAN**: Pi-hole en `192.168.1.2` (macvlan), Caddy en `192.168.1.3` (host). El router hace DHCP/DNS desacoplado del reverse proxy, y cada servicio tiene su `:80` libre.

### `network_mode: host` sólo donde el protocolo lo exige

Tres servicios usan `host` en lugar de `bridge`:

- **Samba** (`docs/06-almacenamiento/02-samba.md`): WSDD y mDNS necesitan emitir _multicast_ a `239.255.255.250:3702/UDP` y `224.0.0.251:5353/UDP` para que Windows Explorer y macOS Finder muestren el host en _Network_. El _bridge_ no atraviesa _multicast_ por diseño.
- **Tailscale daemon**: el `tailscaled` del host crea la interfaz `tailscale0` con la IP `100.x.y.z`. Es el _daemon_ del sistema (no un contenedor); por definición vive en `host`.
- **`macvlan-shim`** (`docs/03-red/01-macvlan.md`): no es un contenedor, es una _interfaz_ del host gestionada por `systemd`.

Todo lo demás (Caddy, Nextcloud, Jellyfin, Stash, los _arr_, las dashboards…) vive en la red `bridge` `homelab` (`172.20.10.0/24`) y se publica al host **sólo si lo necesita un cliente externo al stack**. La convención del homelab es **no publicar UI HTTP al host**: Caddy es el único camino para humanos.

### `bind explícito a IP` en lugar de `0.0.0.0`

Cualquier `ports:` que se publique al host bindea **explícitamente a una IP** (`${HOMELAB_PI_IPV4}:1883:1883`, `${HOMELAB_PI_IPV4}:80:80`, …). Razón: la Pi tiene varias interfaces (`eth0`, `lo`, `tailscale0`, `macvlan-shim`, `docker0`, `br-homelab`) y `0.0.0.0` las cubre todas, incluyendo las redes internas de Docker, donde no debe escuchar. El bind explícito documenta la intención y reduce la superficie. La única excepción razonable son los servicios cuyo protocolo **necesita** estar en cualquier interfaz para descubrirse (Syncthing, Transmission peers) — y éstos se discuten más abajo.

### "_Documentar antes de abrir_, _retirar antes de olvidar_"

Cada vez que un compose añade un puerto al host, el _commit_ correspondiente actualiza este doc. Cada vez que se elimina un puerto temporal (caso típico: `127.0.0.1:9000` de Portainer durante el _bootstrap_, retirado al levantar Caddy en `docs/03-red/04-caddy.md`), también se actualiza. La regla es la misma que para `mem_limit` en `docs/13-operaciones/03-rendimiento-pi5.md`: lo que no se documenta, en seis meses nadie sabe por qué está abierto.

---

## Mapa canónico de puertos

La **fuente de verdad** del homelab para "qué se publica dónde". Cada fila se corresponde con un `ports:` en algún `docker-compose.yml` versionado, con un _daemon_ del host (`sshd`, `tailscaled`) o con un servicio expuesto en la red `macvlan`. Las filas de la tabla siguen el orden de **interfaz** (host LAN → host loopback → host Tailscale → macvlan).

### Puertos del host (Pi `192.168.1.3`, interfaz `eth0`)

| Puerto         | Proto    | Servicio        | Origen permitido            | Doc fuente                                    |
|----------------|----------|-----------------|-----------------------------|-----------------------------------------------|
| 22             | tcp      | OpenSSH (host)  | LAN + Tailscale             | `docs/01-sistema/03-seguridad-base.md`        |
| 80             | tcp      | Caddy           | LAN + Tailscale (redirect → 443) | `docs/03-red/04-caddy.md`                |
| 443            | tcp      | Caddy (HTTP/1.1, HTTP/2) | LAN + Tailscale    | `docs/03-red/04-caddy.md`                     |
| 443            | udp      | Caddy (HTTP/3, QUIC) | LAN + Tailscale        | `docs/03-red/04-caddy.md`                     |
| 445            | tcp      | Samba (SMB3)    | LAN + Tailscale             | `docs/06-almacenamiento/02-samba.md`          |
| 139            | tcp      | Samba (NetBIOS) | LAN (legacy, opt-in)        | `docs/06-almacenamiento/02-samba.md`          |
| 137            | udp      | Samba/NetBIOS-NS| LAN (legacy, opt-in)        | `docs/06-almacenamiento/02-samba.md`          |
| 138            | udp      | Samba/NetBIOS-DG| LAN (legacy, opt-in)        | `docs/06-almacenamiento/02-samba.md`          |
| 3702           | udp      | WSDD multicast (Samba) | LAN (`239.255.255.250`) | `docs/06-almacenamiento/02-samba.md`        |
| 5353           | udp      | mDNS (Avahi/Samba) | LAN (`224.0.0.251`)     | `docs/06-almacenamiento/02-samba.md`          |
| 1883           | tcp      | Mosquitto MQTT  | LAN (bind explícito a `192.168.1.3`) | `docs/08-domotica/02-mosquitto.md`   |
| 22000          | tcp      | Syncthing (sync)| LAN + Tailscale             | `docs/06-almacenamiento/03-syncthing.md`      |
| 22000          | udp      | Syncthing (QUIC sync) | LAN + Tailscale       | `docs/06-almacenamiento/03-syncthing.md`      |
| 21027          | udp      | Syncthing (discovery, multicast `[ff12::8384]`/`239.255.0.1`) | LAN | `docs/06-almacenamiento/03-syncthing.md` |
| 51413          | tcp      | Transmission (BT peers) | LAN + Tailscale     | `docs/10-descargas/01-transmission.md`        |
| 51413          | udp      | Transmission (μTP peers) | LAN + Tailscale    | `docs/10-descargas/01-transmission.md`        |

### Puertos del host (loopback `127.0.0.1`)

| Puerto | Proto | Servicio | Notas |
|--------|-------|----------|-------|
| _ninguno_ | — | — | Tras el _bootstrap_, el homelab no debería tener puertos exclusivamente en `127.0.0.1`. El temporal `127.0.0.1:9000` de Portainer se elimina al levantar Caddy (`docs/03-red/04-caddy.md`, _Eliminar el `ports:` temporal de Portainer_). Si `sudo ss -tulpn | grep 127.0.0.1` muestra algo distinto a `tailscaled` (`100.100.100.100:53`) o resolvers internos, hay deuda técnica que reducir. |

### Puertos del host vía Tailscale (`tailscale0`, IP `100.x.y.z`)

Caddy bindea **explícitamente** a `${TAILSCALE_IPV4}` además de a `${HOMELAB_PI_IPV4}`. La interfaz `tailscale0` es **userspace** del _daemon_ Tailscale; no es alcanzable desde la LAN doméstica salvo por dispositivos que estén autorizados en el _tailnet_ del operador.

| Puerto | Proto | Servicio | Origen permitido | Doc fuente |
|--------|-------|----------|------------------|------------|
| 80     | tcp   | Caddy (redirect → 443) | _tailnet_ (`100.64.0.0/10`) | `docs/03-red/05-tailscale.md` |
| 443    | tcp   | Caddy   | _tailnet_                  | `docs/03-red/05-tailscale.md` |
| 443    | udp   | Caddy (HTTP/3) | _tailnet_           | `docs/03-red/05-tailscale.md` |
| 22     | tcp   | OpenSSH | _tailnet_                  | `docs/01-sistema/03-seguridad-base.md` |

> **Sobre SSH por Tailscale**: `tailscaled` no abre `:22` por sí solo; hereda el _listener_ del `sshd` del host. Como la cadena `input` del firewall ya acepta `tcp dport 22 accept` sin filtrar IP origen, Tailscale "lo ve" automáticamente. Si en el futuro se quiere restringir SSH a sólo Tailscale (cerrar `:22` desde la LAN), se sustituye la regla por `ip saddr 100.64.0.0/10 tcp dport 22 accept`. Este doc no lo aplica por defecto: la LAN doméstica es _trusted_ y dejar SSH accesible cuando Tailscale está caído es parte del DR (`docs/13-operaciones/02-disaster-recovery.md`).

### Puertos en la red `macvlan` (subred `192.168.1.0/29`)

| IP             | Puerto | Proto    | Servicio                | Origen permitido          | Doc fuente                  |
|----------------|--------|----------|-------------------------|---------------------------|-----------------------------|
| 192.168.1.2    | 53     | udp      | Pi-hole (DNS)           | LAN + `macvlan-shim`      | `docs/03-red/02-pihole.md`  |
| 192.168.1.2    | 53     | tcp      | Pi-hole (DNS-over-TCP)  | LAN + `macvlan-shim`      | `docs/03-red/02-pihole.md`  |
| 192.168.1.2    | 80     | tcp      | Pi-hole (UI admin)      | LAN (sólo Caddy via `pihole.lan` → `192.168.1.3` → Pi-hole) | `docs/03-red/02-pihole.md` |
| 192.168.1.4    | 5335   | udp      | Unbound (recursor)      | Pi-hole (`access-control` filtra a `192.168.1.0/24`) | `docs/03-red/03-unbound.md` |
| 192.168.1.4    | 5335   | tcp      | Unbound (DNS-over-TCP)  | Pi-hole                   | `docs/03-red/03-unbound.md` |
| 192.168.1.250  | —      | —        | `macvlan-shim` (host)   | Sólo ruta interna `host → macvlan` | `docs/03-red/01-macvlan.md` |

> **Aislamiento macvlan**: el _kernel_ no permite tráfico directo entre `eth0` del host y los _children_ macvlan. El `macvlan-shim` (`192.168.1.250`) es la única vía por la que la Pi puede consultar a Pi-hole o Unbound. Cualquier dispositivo de la LAN que no sea la propia Pi habla con `192.168.1.2`/`192.168.1.4` por el switch directamente, sin pasar por la Pi.

### Servicios sin `ports:` publicados (acceso sólo vía Caddy)

Estos servicios escuchan dentro de la red `homelab` `172.20.10.0/24` pero **no tienen `ports:`**. Caddy es el _único_ camino externo. Se listan para que el operador sepa qué resuelve por DNS interno.

| Servicio (DNS interno) | Puerto interno | Hostname Caddy             | Doc fuente |
|------------------------|----------------|----------------------------|------------|
| `caddy:80`/`caddy:443` | 80 / 443 / 443/udp | (bindea al host)         | `docs/03-red/04-caddy.md` |
| `authelia:9091`        | 9091           | `auth.lan`                 | `docs/04-seguridad/01-authelia.md` |
| `portainer:9000`       | 9000           | `portainer.lan`            | `docs/02-docker/03-portainer.md` |
| `prometheus:9090`      | 9090           | `prometheus.lan`           | `docs/05-monitorizacion/01-prometheus.md` |
| `grafana:3000`         | 3000           | `grafana.lan`              | `docs/05-monitorizacion/02-grafana.md` |
| `node-exporter:9100`   | 9100           | _interno (sólo Prometheus)_| `docs/05-monitorizacion/03-node-exporter.md` |
| `cadvisor:8080`        | 8080           | _interno (sólo Prometheus)_| `docs/05-monitorizacion/04-cadvisor.md` |
| `uptime-kuma:3001`     | 3001           | `kuma.lan`                 | `docs/05-monitorizacion/05-uptime-kuma.md` |
| `dozzle:8080`          | 8080           | `logs.lan`                 | `docs/05-monitorizacion/06-dozzle.md` |
| `nextcloud:80`         | 80             | `nextcloud.lan`            | `docs/06-almacenamiento/01-nextcloud.md` |
| `minio:9000`/`minio:9001` | 9000 / 9001 | `s3.lan` / `minio.lan`     | `docs/06-almacenamiento/04-minio.md` |
| `home-assistant:8123`  | 8123           | `ha.lan`                   | `docs/08-domotica/01-home-assistant.md` |
| `zigbee2mqtt:8080`     | 8080           | `z2m.lan`                  | `docs/08-domotica/03-zigbee2mqtt.md` |
| `nodered:1880`         | 1880           | `nodered.lan`              | `docs/08-domotica/04-node-red.md` |
| `jellyfin:8096`        | 8096           | `jellyfin.lan`             | `docs/09-multimedia/01-jellyfin.md` |
| `navidrome:4533`       | 4533           | `navidrome.lan`            | `docs/09-multimedia/02-navidrome.md` |
| `audiobookshelf:80`    | 80             | `abs.lan`                  | `docs/09-multimedia/03-audiobookshelf.md` |
| `calibre-web:8083`     | 8083           | `calibre.lan`              | `docs/09-multimedia/04-calibre-web.md` |
| `stash:9999`           | 9999           | `stash.lan`                | `docs/09-multimedia/05-stash.md` |
| `transmission:9091`    | 9091           | `transmission.lan`         | `docs/10-descargas/01-transmission.md` |
| `prowlarr:9696`        | 9696           | `prowlarr.lan`             | `docs/10-descargas/02-prowlarr.md` |
| `sonarr:8989`          | 8989           | `sonarr.lan`               | `docs/10-descargas/03-sonarr.md` |
| `radarr:7878`          | 7878           | `radarr.lan`               | `docs/10-descargas/04-radarr.md` |
| `vaultwarden:80`       | 80             | `vault.lan`                | `docs/11-productividad/01-vaultwarden.md` |
| `bookstack:80`         | 80             | `wiki.lan`                 | `docs/11-productividad/02-bookstack.md` |
| `linkding:9090`        | 9090           | `links.lan`                | `docs/11-productividad/03-linkding.md` |
| `paperless:8000`       | 8000           | `paperless.lan`            | `docs/11-productividad/04-paperless-ngx.md` |
| `mealie:9000`          | 9000           | `mealie.lan`               | `docs/11-productividad/05-mealie.md` |
| `stirling-pdf:8080`    | 8080           | `pdf.lan`                  | `docs/11-productividad/06-stirling-pdf.md` |
| `freshrss:80`          | 80             | `rss.lan`                  | `docs/11-productividad/07-freshrss.md` |
| `homepage:3000`        | 3000           | `home.lan`                 | `docs/12-dashboards/01-homepage.md` |
| `homarr:7575`          | 7575           | `homarr.lan`               | `docs/12-dashboards/02-homarr.md` |

> **Cómo se mantiene esta tabla**: cuando un servicio nuevo se despliega o se renombra un `hostname`, este doc se actualiza en el mismo _commit_. Si la tabla se desincroniza, el comando de auditoría (más abajo, _Verificación periódica_) lo detecta: `docker ps --format` listará algún contenedor que la tabla no recoge.

### Tráfico saliente del host

Por simetría, el listado mínimo de tráfico saliente que la cadena `output accept` permite y que el homelab necesita para funcionar:

| Destino                              | Puerto / Proto       | Quién lo origina                   | Notas |
|--------------------------------------|----------------------|------------------------------------|-------|
| `*` (resolvers raíz, NS autoritativos) | 53/udp+tcp, 853/tcp | Unbound (`192.168.1.4`)            | Recursión DNS. |
| Pool NTP (`debian.pool.ntp.org`)     | 123/udp              | `chrony`/`systemd-timesyncd` host  | NTP imprescindible para Tailscale, certs y `fail2ban`. |
| Docker Hub / `ghcr.io` / proveedores | 443/tcp              | `dockerd`, Watchtower, paquetes apt| _Pulls_ de imágenes. |
| `controlplane.tailscale.com`, DERP   | 443/tcp + 41641/udp  | `tailscaled`                       | _Hole punching_ y _relay_ de fallback. |
| Repos APT (`deb.debian.org`)         | 443/tcp + 80/tcp     | `unattended-upgrades`              | Actualizaciones de seguridad (`docs/01-sistema/03-seguridad-base.md`). |
| SMTP de notificaciones (opcional)    | 587/tcp (TLS submission) | `unattended-upgrades`, alertas | Sólo si el operador configuró un relay. |

> La política `output accept` no filtra destinos. Si en el futuro se quisiera segmentar (p. ej. impedir que un contenedor comprometido contacte _command & control_ por internet), el lugar es la cadena `DOCKER-USER` de `nftables`, no `output` del host (`docs/01-sistema/03-seguridad-base.md`, _Convivencia con Docker_).

---

## `nftables` consolidado del host

Ruleset de referencia que materializa el mapa anterior. Es la **suma** de los fragmentos que cada doc de fase añadió a `/etc/nftables.conf`. Útil como **artefacto de auditoría**: comparar con `sudo nft list ruleset` y diferencia visible.

```nft
#!/usr/sbin/nft -f
# /etc/nftables.conf — ruleset consolidado del homelab.
# Política: input drop / forward drop / output accept.
# Origen permitido: LAN doméstica + Tailscale tailnet + loopback.
# Las cadenas DOCKER, DOCKER-USER, DOCKER-ISOLATION-* las gestiona dockerd
# en otras tablas (nat, filter) y NO se tocan desde aquí.

flush ruleset

# --- conjuntos de redes "trusted" -------------------------------------------
# Se centralizan los rangos para que añadir/quitar uno sea una sola línea.
table inet filter {
    set lan_ipv4 {
        type ipv4_addr
        flags interval
        elements = { 192.168.1.0/24 }
    }

    set tailscale_ipv4 {
        type ipv4_addr
        flags interval
        elements = { 100.64.0.0/10 }
    }

    set lan_multicast {
        type ipv4_addr
        elements = { 224.0.0.251, 239.255.255.250, 239.255.0.1 }
    }

    # --- INPUT --------------------------------------------------------------
    chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        ct state invalid drop
        iif "lo" accept

        # ICMP / ICMPv6 (limitado para no amplificar floods desde un IoT comprometido)
        ip protocol icmp limit rate 10/second accept
        ip6 nexthdr icmpv6 limit rate 10/second accept

        # SSH desde LAN o Tailscale.
        tcp dport 22 ip saddr @lan_ipv4 accept
        tcp dport 22 ip saddr @tailscale_ipv4 accept

        # Caddy (LAN). El bind explícito a 192.168.1.3 ya filtra interfaz;
        # estas reglas filtran origen para coherencia con la política.
        tcp dport { 80, 443 } ip saddr @lan_ipv4 accept
        udp dport 443         ip saddr @lan_ipv4 accept

        # Caddy (Tailscale). tailscaled inyecta sus reglas en cadenas propias,
        # pero estas explícitas hacen el ruleset legible.
        tcp dport { 80, 443 } ip saddr @tailscale_ipv4 accept
        udp dport 443         ip saddr @tailscale_ipv4 accept

        # Samba (SMB3). NetBIOS y WSDD quedan a discreción del operador
        # (descomentar si Windows Explorer no descubre el host).
        tcp dport 445 ip saddr @lan_ipv4 accept
        # tcp dport 139 ip saddr @lan_ipv4 accept
        # udp dport { 137, 138 } ip saddr @lan_ipv4 accept
        udp dport 3702 ip daddr @lan_multicast accept   # WSDD multicast
        udp dport 5353 ip daddr @lan_multicast accept   # mDNS / Avahi

        # Mosquitto MQTT (sólo LAN; el bind del compose ya limita a 192.168.1.3).
        tcp dport 1883 ip saddr @lan_ipv4 accept

        # Syncthing.
        tcp dport 22000 ip saddr @lan_ipv4 accept
        udp dport 22000 ip saddr @lan_ipv4 accept
        tcp dport 22000 ip saddr @tailscale_ipv4 accept
        udp dport 22000 ip saddr @tailscale_ipv4 accept
        udp dport 21027 ip saddr @lan_ipv4 accept       # discovery (multicast LAN)

        # Transmission (peers BitTorrent).
        tcp dport 51413 ip saddr @lan_ipv4 accept
        udp dport 51413 ip saddr @lan_ipv4 accept
        tcp dport 51413 ip saddr @tailscale_ipv4 accept
        udp dport 51413 ip saddr @tailscale_ipv4 accept

        # Todo lo demás: drop silencioso.
    }

    # --- FORWARD ------------------------------------------------------------
    chain forward {
        type filter hook forward priority filter; policy drop;
        # Docker añade reglas de FORWARD en sus propias cadenas:
        #   DOCKER, DOCKER-USER, DOCKER-ISOLATION-STAGE-1/2.
        # No se tocan desde aquí.
    }

    # --- OUTPUT -------------------------------------------------------------
    chain output {
        type filter hook output priority filter; policy accept;
        # Política abierta. Si en el futuro se segmenta, los filtros van en
        # DOCKER-USER (no aquí), para no afectar al tráfico del propio host.
    }
}
```

> **Aplicación incremental**: el operador no sustituye `/etc/nftables.conf` de golpe; añade los fragmentos cuando el doc de cada fase los introduce y, **después** de levantar la fase 13, _diff_-ea con este bloque para detectar olvidos. La validación es siempre `sudo nft -c -f /etc/nftables.conf` antes de `sudo systemctl reload nftables` (`docs/01-sistema/03-seguridad-base.md`).

> **Sobre `tailscaled` y nftables**: el _daemon_ inserta sus propias reglas en cadenas `ts-input`, `ts-forward` y similares (lo hace al arrancar). No se tocan ni se duplican; el ruleset de arriba complementa, no sustituye, lo que `tailscaled` instala. Comprobar con `sudo nft list ruleset | grep -i tailscale`.

---

## Configuración del router doméstico

El homelab depende de **tres** ajustes en el router. Ningún _port forwarding_, ningún DDNS.

### 1. Reservas DHCP por MAC

Reservas obligatorias para que las IPs del homelab no cambien al reiniciar el router (`docs/03-red/01-macvlan.md`):

| IP            | Dispositivo               | MAC reservada                  | Notas |
|---------------|---------------------------|--------------------------------|-------|
| 192.168.1.1   | Router (gateway)          | _del propio router_            | Sin tocar. |
| 192.168.1.2   | Pi-hole (contenedor macvlan) | `02:42:c0:a8:01:02`         | Asignada por Docker al contenedor. |
| 192.168.1.3   | Raspberry Pi 5 (`eth0` host) | _MAC física de la Pi_       | Reserva crítica: el host. |
| 192.168.1.4   | Unbound (contenedor macvlan) | `02:42:c0:a8:01:04`         | Asignada por Docker al contenedor. |
| 192.168.1.250 | `macvlan-shim` (host)     | `02:42:c0:a8:01:fa`            | Asignada por la _unit_ `systemd` que crea el _shim_. |

> Las MACs `02:42:` siguen el patrón Docker: prefijo `02:42:` + IP en hex. Es el patrón documentado en `docs/03-red/01-macvlan.md`. Mantenerlo evita _drift_ entre el router y la realidad del contenedor.

### 2. DNS primario y secundario del router

Apuntar a Pi-hole con un _fallback_ que **no** sea internet directo (porque entonces los anuncios del bloqueo no se cumplirían) pero que evite quedarse sin DNS si Pi-hole cae:

```text
DNS primario:    192.168.1.2     (Pi-hole)
DNS secundario:  192.168.1.4     (Unbound — recursor directo, sin filtrado)
                                   o vacío, dependiendo del firmware del router.
```

> **Nota sobre el _fallback_**: algunos routers domésticos (FRITZ!Box, ASUS) consultan los dos DNS en paralelo y se quedan con la primera respuesta — eso convierte el "fallback" en un _bypass_ permanente del bloqueo. Si el router lo hace, dejar **sólo** `192.168.1.2` como DNS y aceptar que un fallo de Pi-hole rompe la resolución (`docs/03-red/02-pihole.md` documenta el `dnsmasq` de host como _last resort_ en `/etc/resolv.conf` de la Pi).

### 3. Ningún _port forwarding_

La pantalla _Port Forwarding_ / _NAT_ / _Virtual Server_ del router debe quedar **vacía**. Tailscale no necesita que se abran puertos: inicia conexiones salientes UDP `41641` (NAT _hole punching_) y, si la NAT del operador es estricta, _relay_ TCP `443` contra los DERP de Tailscale. UPnP también desactivado: ningún contenedor del homelab pide puertos al router automáticamente, y dejarlo apagado evita que un IoT del salón abra `:8123` "por descubrimiento".

### 4. Bloque WiFi de invitados (recomendado, no obligatorio)

Si el router soporta una **red WiFi de invitados aislada**, activarla y ponerla **fuera** de `192.168.1.0/24` (ej. `192.168.42.0/24`) o con _Client Isolation_. Las visitas usan internet, no entran al homelab. La regla `nftables ip saddr @lan_ipv4 accept` de arriba **no** las cubre, así que aunque alguien se conectara y supiese la IP de la Pi, el firewall las dropearía.

---

## Verificación periódica

### `nmap` desde un cliente de la LAN (no la propia Pi)

```bash
# Desde el portátil del operador, en la misma LAN:
nmap -sS -sU --top-ports 50 192.168.1.3
nmap -sS         -p 1-65535 192.168.1.3   # exhaustivo TCP
nmap -sU         -p 1-1024  192.168.1.3   # UDP top
nmap -p 53,80    192.168.1.2              # Pi-hole
nmap -p 5335     192.168.1.4              # Unbound (debería verse "filtered" si access-control filtra fuera de Pi-hole)
```

**Esperado** sobre `192.168.1.3` (host): `22/tcp` (SSH), `80/tcp` + `443/tcp` (Caddy), `445/tcp` (Samba), `1883/tcp` (MQTT), `22000/tcp` (Syncthing), `51413/tcp` (Transmission). UDP: `137/138` (si NetBIOS está activo), `5353` (mDNS), `21027` (Syncthing), `22000` (Syncthing QUIC), `51413` (Transmission peers). **Cualquier otro puerto _open_** es deuda técnica: cruzar con la tabla canónica e investigar.

### `ss` desde la propia Pi

```bash
sudo ss -tulpn | sort -k5
```

Lista cada socket activo con su proceso. Es la fuente de verdad complementaria a `nmap`: a veces un puerto abierto en `127.0.0.1` no aparece en el barrido externo pero sí en `ss`, y al revés (un puerto bloqueado por `nftables` aparece en `ss` pero `nmap` lo ve _filtered_).

### `tailscale status` y `tailscale netcheck`

```bash
tailscale status
tailscale netcheck
```

`status` enumera los _peers_ del _tailnet_ y su última actividad. `netcheck` reporta si la NAT permite _hole punching_ directo (`UDP punch`) o si el tráfico está pasando por DERP _relay_ (peor latencia, pero sigue funcionando).

### Ronda mensual de auditoría

Forma parte del calendario de `docs/13-operaciones/01-mantenimiento-periodico.md`. La lista corta:

- [ ] `sudo ss -tulpn | sort -k5 > /tmp/ss.now`; `diff /tmp/ss.previous /tmp/ss.now`. Cualquier _diff_ se justifica o se cierra.
- [ ] `sudo nft list ruleset > /tmp/nft.now`; `diff /tmp/nft.previous /tmp/nft.now`. Idem (`tailscaled` y `fail2ban` mueven sus cadenas; concentrarse en `inet filter`).
- [ ] `nmap` desde un cliente externo (portátil): el set de puertos coincide con la **tabla canónica** de este doc.
- [ ] `tailscale status` desde un nodo remoto: la Pi aparece como `online` y la última conexión efectiva es < 24 h.
- [ ] El router sigue **sin entradas** en _Port Forwarding_; la lista de reservas DHCP coincide con la tabla de la sección 1 de _Configuración del router_.

---

## Troubleshooting

### `nmap` desde la LAN reporta un puerto que no está en el mapa

Tres causas, en orden de probabilidad:

1. Un servicio nuevo se desplegó **sin actualizar este doc**. `docker ps --format 'table {{.Names}}\t{{.Ports}}'` listará el contenedor — actualizar la tabla canónica y commitear el cambio.
2. Un binario residual del host (Apache, Nginx, `lighttpd`) escucha sobre `192.168.1.3`. `sudo ss -tulpn | grep <puerto>` identifica el proceso. Si no debería estar, `sudo systemctl disable --now <unit>` y `sudo apt purge` (`docs/01-sistema/03-seguridad-base.md`, _Tras un `apt full-upgrade` desaparece...`_).
3. Un contenedor se levantó con `network_mode: host` o con un `ports: 0.0.0.0:<x>:<y>` improvisado durante un _troubleshoot_ y se olvidó retirar (`docs/02-docker/03-portainer.md`, caso del `127.0.0.1:9000` de Portainer).

### Un servicio dice "no responde" desde otro contenedor del mismo `homelab`

La red Docker `homelab` (`172.20.10.0/24`) tiene _embedded DNS_: el hostname `<servicio>` resuelve a la IP del contenedor. Si Sonarr no llega a `prowlarr:9696`:

```bash
docker exec sonarr getent hosts prowlarr   # ¿Resolución DNS interna OK?
docker exec sonarr wget -qO- http://prowlarr:9696/  # ¿Llega TCP?
docker network inspect homelab | grep -E 'Name|IPv4Address'   # ¿Ambos en la misma red?
```

Causas habituales: `networks:` mal declarado en uno de los dos compose, _stack_ levantado con `make up STACK=otro` que no incluye el servicio buscado, o `restart_policy` que dejó al servicio en `restarting`.

### Pi-hole responde DNS desde la LAN pero no desde la Pi

La Pi y los contenedores macvlan **no se ven entre sí** sin `macvlan-shim` (`docs/03-red/01-macvlan.md`). Verificar:

```bash
ip link show macvlan-shim         # debe existir
ip addr show macvlan-shim         # debe tener 192.168.1.250/29
ip route get 192.168.1.2          # debe usar dev macvlan-shim
dig @192.168.1.2 example.com +short
```

Si `ip link show macvlan-shim` falla: la _unit_ `systemd` que crea el _shim_ no arrancó. `systemctl status macvlan-shim.service` y reactivar.

### Un cliente Tailscale no llega a `https://jellyfin.lan`

Tres comprobaciones encadenadas:

1. **¿Resuelve?** Desde el cliente: `dig @100.100.100.100 jellyfin.lan +short` — debería devolver `192.168.1.3`. Si devuelve `NXDOMAIN`, el _split DNS_ está mal configurado (`docs/03-red/05-tailscale.md`, MagicDNS y _split DNS_).
2. **¿Llega TCP?** `nc -vz 100.x.y.z 443` desde el cliente. Si falla, `nftables` en la Pi no tiene la regla `tcp dport 443 ip saddr @tailscale_ipv4 accept` o `tailscaled` no levantó la interfaz `tailscale0` antes que Caddy.
3. **¿Cert válido?** `curl -kv https://jellyfin.lan/` — si el cert es de la CA local, instalar en el cliente. Si el operador prefiere cert público, usar `https://pi.<TAILNET>.ts.net/` que sirve el cert emitido por `tailscale cert` (`docs/03-red/05-tailscale.md`).

### `:80` ocupado al levantar Caddy

```bash
sudo ss -tlnp | grep ':80\s'
```

Posibles culpables, en orden de probabilidad:

- Un `lighttpd` o `nginx` instalado por un paquete `apt` (Pi-hole nativo, panel del router replicado en la Pi…). `sudo systemctl disable --now lighttpd nginx apache2`.
- Un contenedor con `network_mode: host` que se desplegó "para probar" y nadie retiró. `docker ps | grep host`. Si no hace falta, eliminarlo.
- Un `ports: 80:80` en un compose que no es el de Caddy. `cd ~/homelab && grep -nR '"80:80"' */docker-compose.yml`.

### Watchtower o un compose levanta con `Bind for 0.0.0.0:<x> failed: port is already allocated`

Conflicto de _bind_. Identificar quién lo tiene reservado:

```bash
sudo ss -tlnp | grep ':<x>\s'
docker ps --format '{{.Names}}: {{.Ports}}' | grep '<x>'
```

Si dos compose declararon el mismo puerto, **uno de los dos no debería**: la convención del homelab es _no publicar UI HTTP al host_. Eliminar el `ports:` redundante y forzar el acceso por Caddy (`docs/03-red/04-caddy.md`).

### El router no acepta la reserva DHCP por MAC del contenedor macvlan

Algunos firmwares (TP-Link, Mercusys) detectan que la MAC `02:42:c0:a8:01:02` no es una "interfaz física" y se niegan. Workaround: configurar el contenedor con `mac_address:` explícito en `docker-compose.yml` (ya documentado en `docs/03-red/02-pihole.md`/`docs/03-red/03-unbound.md`) y, en el router, marcar las MACs como _trusted_/_static_ aunque no estén "vistas" todavía. Si el router se niega a guardar reservas para MACs no presentes, levantar primero el contenedor (Docker la registrará en la tabla ARP del switch) y entonces guardar la reserva.

### `nft list ruleset` muestra reglas que no aparecen en `/etc/nftables.conf`

Es normal: `tailscaled` y `fail2ban` instalan sus propias cadenas (`ts-input`, `ts-forward`, `f2b-sshd`, etc.) en _runtime_, no por el fichero. **No** se editan a mano. Para depurar:

```bash
sudo nft list table inet filter        # ruleset propio del homelab
sudo nft list table ip filter          # cadenas iptables-nft (Docker, fail2ban)
sudo nft list table ip nat             # NAT de Docker
```

Lo que se persiste vía `/etc/nftables.conf` es **sólo** `inet filter`. Lo demás lo regeneran sus _daemons_ al arrancar.

### Tailscale dice `relay derp-xx` (no _direct_) y la latencia es alta

`tailscale netcheck` listará la causa. Si es _Hairpinning_ negativo del router (ej. `Hairpinning: false`), no se puede hacer mucho desde la Pi: depende del firmware. Mitigaciones:

- Desactivar UPnP del router y volverlo a activar (a veces destrabe).
- Reiniciar el router (sí, esa).
- En el peor caso, dejar el _relay_ DERP: la latencia sube ~50 ms pero todo funciona. Es Internet residencial, no SLA.

---

## Cierre de la fase 13

Con este documento, la fase 13 (`Operaciones y Mantenimiento`) queda completa: calendario (`01`), recuperación (`02`), rendimiento (`03`) y mapa de red (`04`). El homelab pasa a **operación pura** — los siguientes _commits_ ya no añaden documentación de _bootstrap_, sino entradas de bitácora (`docs/journal/`) cuando algo cambia en el plano operativo.

- [ ] La **tabla canónica de puertos** se ha cotejado con `sudo ss -tulpn` y con `nmap` desde un cliente externo: cero divergencias o cada divergencia tiene un _commit_ de actualización.
- [ ] El bloque consolidado de `nftables` coincide con `sudo nft list table inet filter` salvo por las cadenas de `fail2ban` y `tailscaled` (que son inyectadas en _runtime_).
- [ ] El router muestra exactamente las reservas DHCP de la sección _Configuración del router_ y la lista de _port forwarding_ está vacía.
- [ ] Un cliente Tailscale remoto resuelve `jellyfin.lan`, `portainer.lan` y `pi.<TAILNET>.ts.net` sin intervención y abre HTTPS sin avisos (CA local instalada o cert público de Tailscale, según corresponda).
- [ ] La fase 13 se cierra con commit:
  ```bash
  cd ~/homelab
  git add docs/13-operaciones/04-red-y-puertos.md
  git commit -m "feat(ops): mapa consolidado de red y puertos del homelab"
  git push
  ```

---

## Referencias

- nftables — Wiki oficial: <https://wiki.nftables.org/wiki-nftables/index.php/Main_Page>
- nftables — _Sets and maps_ (sintaxis usada en el ruleset): <https://wiki.nftables.org/wiki-nftables/index.php/Sets>
- Debian Wiki — `nftables`: <https://wiki.debian.org/nftables>
- Linux kernel — _macvlan_ driver: <https://docs.kernel.org/networking/macvlan.html>
- Docker — _Networking overview_: <https://docs.docker.com/network/>
- Docker — _macvlan_ networks: <https://docs.docker.com/network/drivers/macvlan/>
- Tailscale — _How NAT traversal works_ (UDP 41641, DERP fallback): <https://tailscale.com/blog/how-nat-traversal-works>
- Tailscale — _MagicDNS_ y _split DNS_: <https://tailscale.com/kb/1054/dns>
- Tailscale — _Subnet routers and exit nodes_ (referencia, no se usa en este homelab): <https://tailscale.com/kb/1019/subnets>
- IANA — _Service Name and Transport Protocol Port Number Registry_: <https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml>
- Microsoft — _WS-Discovery / WSDD_ (puerto 3702/UDP): <https://learn.microsoft.com/en-us/windows/win32/wsdapi/ws-discovery-protocol>
- Avahi (mDNS / Bonjour) — Manual: <https://avahi.org/>
- Pi-hole — _Networking documentation_: <https://docs.pi-hole.net/main/post-install/>
- Unbound — _access-control_ statement: <https://unbound.docs.nlnetlabs.nl/en/latest/manpages/unbound.conf.html>
- Caddy — _bind_ directive (bind explícito a IP): <https://caddyserver.com/docs/caddyfile/options#bind>
- Syncthing — _Firewall setup_ (22000/tcp+udp, 21027/udp): <https://docs.syncthing.net/users/firewall.html>
- Transmission — _Configuration files_ (peer-port): <https://github.com/transmission/transmission/blob/main/docs/Configuration-Files.md>
- Samba — _smb.conf_ (puertos `:445`, `:139`): <https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html>
- `nmap` — Manual: <https://nmap.org/book/man.html>
- `ss` (`iproute2`) — Manual: <https://man7.org/linux/man-pages/man8/ss.8.html>
