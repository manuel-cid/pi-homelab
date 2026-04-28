# Red Docker macvlan para servicios DNS

## Descripción

Cerrada la Fase 2 (`docs/02-docker/04-watchtower.md`), la Pi tiene engine, convenciones de stacks, panel y actualizador. La siguiente capa es la **red**: cómo se nombran y enrutan los servicios del homelab. El primer servicio que abre la Fase 3 es Pi-hole, que escucha **DNS en el puerto 53** y necesita ser visible para todos los dispositivos de la LAN. Justo después llegará Caddy, reverse proxy interno, que necesita los puertos **80 y 443** sobre la misma Pi.

Si tanto Pi-hole como Caddy se publican con `ports:` sobre la **única IP de la Pi** (`192.168.1.10`, por ejemplo), aparecen tres roces:

1. **Colisión cognitiva**. Pi-hole en `:53` y Caddy en `:80/:443` no chocan a nivel TCP/UDP, pero el día que un servicio quiera el `:80` directo (Home Assistant, un dashboard puntual, una redirección HTTP→HTTPS sin pasar por Caddy) la Pi se queda sin puertos privilegiados libres.
2. **DNS desde el host**. Si Pi-hole publica `:53` en la Pi, el propio host no puede usarse como cliente DNS sin trucos (`/etc/resolv.conf` apuntando a `127.0.0.1` está bien, pero entrelaza el ciclo de vida del host con el del contenedor).
3. **Pi-hole quiere ver IPs reales**. Cuando Pi-hole recibe consultas DNS publicadas por `-p 53:53`, todos los clientes le aparecen como la **gateway del bridge** (`172.30.10.1`) por culpa de NAT/SNAT. Eso rompe estadísticas, listas por cliente y excepciones por dispositivo. Existen workarounds (`network_mode: host`, `userland-proxy`, etc.) pero ninguno es limpio.

La solución estándar es darle a Pi-hole (y a Unbound, su upstream recursivo) **una IP propia en la LAN** mediante una red Docker tipo **macvlan**. Cada contenedor en la red macvlan se presenta en la red doméstica con su propia MAC e IP, como si fuese un dispositivo físico más. La IP de la Pi (`eth0`) queda libre para Caddy (Patrón B/C de `02-estructura-compose.md`) y para futuros servicios.

Este documento decide y documenta, **una sola vez**, lo que necesita la red macvlan antes de levantar Pi-hole en `02-pihole.md`:

1. **Qué es macvlan y por qué se elige aquí**, comparado con bridge + port-publishing y con `network_mode: host`.
2. **Plan de IPs**: subred LAN, gateway, rango DHCP del router, IPs estáticas reservadas para los contenedores macvlan, IP del host.
3. **Reserva en el router**: DHCP del router excluye el rango estático y, si lo soporta, ata la IP de la Pi por MAC.
4. **Creación de la red Docker macvlan** con `docker network create`, parametrizada con `--subnet`, `--gateway`, `--ip-range` y `parent=eth0`.
5. **Interfaz `macvlan-shim` en el host**: el agujero clásico de macvlan (host ↔ contenedor macvlan en el **mismo** host no se hablan) y su solución persistente vía `systemd-networkd`/unidad `systemd`.
6. **Cómo se referencia la red desde Compose** (external).

Cuando este documento se haya aplicado, `docker network ls` lista `dns_lan`, `ip -br link show macvlan-shim` reporta una interfaz `UP`, un `ping` desde el host a la IP estática reservada **funciona** (aunque todavía no haya contenedor escuchando, devolverá *destination host unreachable* hasta que Pi-hole levante en su IP), y los stacks `pihole/` y `unbound/` pueden referenciar la red como `external: true`.

> **Recordatorio de alcance**: el homelab sigue siendo solo **LAN + Tailscale**. macvlan **no abre nada hacia internet**: solo cambia cómo se ven los contenedores DNS dentro de la red doméstica. El router del operador, no este documento, es la frontera con el exterior.

---

## Requisitos Previos

- Fase 2 completa (`01-instalacion-docker.md` … `04-watchtower.md`):
  - Docker Engine + Compose v2 funcionando, `data-root` en `/mnt/hd2t/docker`, `default-address-pools` = `172.30.0.0/16` con `size: 24`.
  - Red Docker `homelab` creada por `scripts/10-create-docker-network.sh` en `172.30.10.0/24`.
  - Usuario `homelab` en grupo `docker`, layout `stacks/<svc>/` aplicado, `.env` global presente con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN`.
  - Portainer y Watchtower desplegados como primeros stacks bajo las convenciones.
- **Conexión por cable Ethernet**: la Pi 5 está conectada al router con cable y `eth0` tiene IP estable. macvlan **no funciona sobre Wi-Fi** en la mayoría de drivers (la radio rechaza paquetes con MAC distinta a la del cliente asociado). Si la Pi está en Wi-Fi, hay que pasarla a Ethernet antes de seguir.
- **Acceso de admin al router** doméstico: hace falta ajustar el rango DHCP y, opcionalmente, atar la IP de la Pi por MAC.
- Comprobación rápida del entorno antes de empezar:

  ```bash
  ip -br link show eth0
  # eth0  UP   dc:a6:32:xx:xx:xx ...

  ip -br -4 addr show eth0
  # eth0  UP   192.168.1.10/24

  ip route show default
  # default via 192.168.1.1 dev eth0 ...

  ping -c 2 192.168.1.1
  # 0% packet loss

  docker network ls --format '{{.Name}} {{.Driver}}'
  # bridge  bridge
  # homelab bridge
  # host    host
  # none    null
  ```

  Si `eth0` no está `UP` o si la ruta por defecto no sale por `eth0`, se resuelve antes (puede ser que la Wi-Fi esté ganando métrica). Si la Pi tiene IP por DHCP "casual" en lugar de reserva, se ata en el router (siguiente sección) **antes** de seguir, porque el plan se construye sobre direcciones predecibles.

---

## Decisión: macvlan vs alternativas

Para publicar Pi-hole en la LAN hay tres familias de solución. Se comparan y se elige una.

| Opción | Cómo se ve | Pros | Contras | Veredicto |
|---|---|---|---|---|
| **Bridge + `-p 53:53`** | Pi-hole en la red `homelab` (bridge), expuesto con `ports: ["53:53/tcp", "53:53/udp", "80:80"]`. | Simple. Mismo patrón que el resto de stacks. | Ata `:53` y `:80` a la IP de la Pi: choca con Caddy y deja el host sin DNS local. Pi-hole ve a **todos** los clientes como la gateway del bridge, romper estadísticas. Ningún workaround del NAT es limpio. | Descartado |
| **`network_mode: host`** | Pi-hole comparte la pila de red del host. | Resuelve la pérdida de IPs reales (no hay NAT). | Sigue ocupando `:53` y `:80` en la Pi. Rompe el aislamiento Compose↔Compose (los stacks no pueden referirse a Pi-hole por nombre DNS interno). Un fallo del contenedor puede dejar al host con un puerto huérfano hasta el siguiente reboot. | Descartado |
| **macvlan**: red Docker tipo macvlan sobre `eth0` con IP propia para Pi-hole | Pi-hole aparece en la LAN como `192.168.1.2`, MAC propia. La IP de la Pi (`192.168.1.10`) sigue libre para Caddy y otros. Pi-hole ve **IPs reales** de los clientes. | Es la solución estándar y limpia para servicios DNS contenedorizados. No NAT, no userland-proxy. | Requiere planificar IPs (DHCP del router + Docker `--ip-range`). Tiene **una** trampa: el host no puede hablar con sus propios contenedores macvlan sin la interfaz `macvlan-shim`. Documentado y resuelto abajo. | **Aceptado** |

Resultado: **red Docker macvlan dedicada a los servicios DNS** (Pi-hole y Unbound), con IPs estáticas asignadas explícitamente y una interfaz `macvlan-shim` persistente en el host. El resto de stacks del homelab **siguen usando** la red `homelab` bridge: macvlan se reserva exclusivamente para servicios que necesitan IP propia en la LAN. La superficie nueva queda acotada.

> **¿Por qué solo DNS?** Caddy, Jellyfin, Nextcloud, etc. publican vía Caddy (Patrón A: solo red interna `homelab`). No necesitan IP propia en la LAN. Cuanto menos macvlan, menos sorpresas: los contenedores macvlan están un poco más cerca de "VM en la LAN" que de "contenedor con red NAT", y eso conlleva responsabilidades adicionales (cortafuegos delegado al router, trazabilidad MAC↔contenedor, ARP propio).

---

## Plan de direccionamiento

Hace falta un plan de IPs **explícito** antes de tocar `docker network create`. Se asume una LAN doméstica típica con router en `192.168.1.1/24`. Si la red real del operador es distinta (`192.168.0.0/24`, `10.0.0.0/24`…), se sustituye en todo el documento de forma consistente.

| Recurso | Valor (ejemplo) | Notas |
|---|---|---|
| Subred LAN | `192.168.1.0/24` | Coincide con la subred del router. macvlan **no inventa** una subred: comparte la del segmento físico. |
| Gateway LAN | `192.168.1.1` | Es la del router, **no** la del host Pi. |
| Interfaz padre | `eth0` | Fija la NIC física que vehicula los paquetes con MAC virtual. La Pi 5 tiene una sola Ethernet. |
| Rango DHCP del router | `192.168.1.50` – `192.168.1.250` | **Restringido** desde la admin del router. El router **no** asigna fuera de aquí. |
| IPs estáticas (homelab) | `192.168.1.2` – `192.168.1.9` | Bloque reservado por convención para servicios contenedorizados. **Nunca** las da el DHCP. |
| Pi-hole | `192.168.1.2` | Asignada vía `--ip` en su Compose, dentro del `--ip-range` de la red macvlan. |
| Unbound | `192.168.1.3` | Idem. |
| (libre para futuros) | `192.168.1.4` – `192.168.1.7` | Slots para casos como Adguard secundario, Samba dedicado, ESPHome con mDNS. |
| Interfaz `macvlan-shim` (host) | `192.168.1.9/32` | IP del host **dentro** del `--aux-address` de Docker para que el daemon no la asigne a un contenedor. Permite host↔Pi-hole. |
| IP de la Pi (gestión, SSH, Caddy) | `192.168.1.10` | Reservada en DHCP del router por MAC, o IP estática vía `dhcpcd.conf` / `systemd-networkd`. **No** entra en `--ip-range`. |
| Otros dispositivos (móviles, TV, …) | `192.168.1.50+` | Quedan en el pool DHCP estándar. |

### Variables nuevas en `.env` global

Se añaden a `/home/homelab/homelab/.env` (y a `.env.example` versionado), siguiendo lo decidido en `02-estructura-compose.md`:

```bash
# /home/homelab/homelab/.env (fragmento añadido en Fase 3)

# LAN física donde vive la Pi y donde aparecerán los servicios macvlan
LAN_SUBNET=192.168.1.0/24
LAN_GATEWAY=192.168.1.1
LAN_PARENT_IF=eth0

# Rango reservado en Docker para contenedores macvlan (subset de LAN_SUBNET).
# El router NO debe asignar IPs en este rango (ver "Reserva en el router").
LAN_MACVLAN_RANGE=192.168.1.0/29     # 192.168.1.0 - 192.168.1.7

# IP del host en la interfaz macvlan-shim (fuera de LAN_MACVLAN_RANGE,
# dentro de LAN_SUBNET). Permite host <-> contenedor macvlan en la misma Pi.
LAN_MACVLAN_SHIM_IP=192.168.1.9

# IPs fijas de los servicios macvlan
PIHOLE_IP=192.168.1.2
UNBOUND_IP=192.168.1.3
```

> **Por qué `/29` y no asignar individualmente**. Docker exige un `--ip-range` declarable como CIDR. `/29` (8 IPs: `.0`–`.7`) cubre `.2` y `.3` con margen para `.4–.6` futuros, y deja `.0`/`.7` (red y broadcast) intactos. Si en el futuro hace falta más, se elige otro slot (`.16/29` por ejemplo) y se reabre la decisión documentándolo en este fichero.

---

## Reserva en el router

El router doméstico **manda** sobre la asignación de IPs por DHCP. Si reparte una IP del rango macvlan a un móvil cualquiera, hay colisión silenciosa: el móvil y Pi-hole responden ambos a la misma IP, ARP se vuelve loco, intermitencias intratables. Se evita reservando.

Pasos genéricos (aplicables a la mayoría de routers domésticos: ASUS, FRITZ!Box, Mikrotik, OpenWrt, MoviStar, Vodafone…):

1. **Restringir el rango DHCP**. Cambiar el pool de DHCP a `192.168.1.50` – `192.168.1.250` (o equivalente). El bloque `.2`–`.49` queda reservado para asignaciones manuales (`.2`–`.9` para macvlan, `.10`–`.49` libres para el operador).
2. **Atar la IP de la Pi por MAC**. En la sección de "DHCP estático" / "IP reservada por MAC", añadir una entrada que asocie la MAC de `eth0` (`ip link show eth0` la imprime) a `192.168.1.10`. Eso garantiza que la Pi siempre arranca con la misma IP.
3. **(Opcional pero recomendado) Atar también las MAC virtuales** de Pi-hole y Unbound. Las MAC se generan al crear el contenedor; se pueden **fijar** en Compose (`mac_address: 02:42:c0:a8:01:02`). Si el router lo soporta, se añaden como reservas también. No es estrictamente necesario porque Docker asigna la IP estática vía `--ip`, pero ayuda a la trazabilidad si el router muestra dispositivos por MAC.
4. **Comprobar que el router no tiene ya un dispositivo en `192.168.1.2`**. Listar la tabla DHCP, identificar al inquilino y reasignarle otra IP (o esperar al lease para reusarla). En LANs muy nuevas el `.2` suele estar libre.
5. **(Opcional) IP estática del lado de la Pi**, si el router doméstico no permite reservar por MAC: configurar `eth0` con IP estática `192.168.1.10/24`, gateway `192.168.1.1`, DNS provisional `1.1.1.1` (se cambiará a Pi-hole tras la Fase 3.2). Métodos según el OS:

   ```bash
   # Raspberry Pi OS Lite (Bookworm) usa NetworkManager por defecto en imágenes recientes.
   # Si NetworkManager está activo:
   sudo nmcli con mod "Wired connection 1" \
       ipv4.method manual \
       ipv4.addresses 192.168.1.10/24 \
       ipv4.gateway 192.168.1.1 \
       ipv4.dns "1.1.1.1 9.9.9.9"
   sudo nmcli con up "Wired connection 1"

   # Si la Pi usa el clásico dhcpcd (imágenes Bullseye o anteriores):
   echo "interface eth0
   static ip_address=192.168.1.10/24
   static routers=192.168.1.1
   static domain_name_servers=1.1.1.1 9.9.9.9" | sudo tee -a /etc/dhcpcd.conf
   sudo systemctl restart dhcpcd
   ```

   Tras el cambio, comprobar:

   ```bash
   ip -br -4 addr show eth0   # 192.168.1.10/24
   ip route show default      # default via 192.168.1.1 dev eth0
   ping -c 2 1.1.1.1          # 0% packet loss
   ```

> **Mantener documentado el plan**. La reserva del router es estado **fuera** del repo de git. Para que un reflasheo futuro no descuadre el plan, se anota en `docs/00-hardware/` o en `docs/01-sistema/02-configuracion-inicial.md` la entrada correspondiente: "192.168.1.10 → Pi homelab (eth0 MAC dc:a6:32:..)". El operador es responsable de reflejarlo cuando cambie de router.

---

## Creación de la red Docker macvlan

Igual que con la red `homelab`, se crea **una vez**, fuera de Compose, mediante un script idempotente en `scripts/`. Los stacks `pihole/` y `unbound/` la referencian como `external: true`.

### El script

```bash
sudo tee /home/homelab/homelab/scripts/20-create-macvlan-network.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
# Crea (idempotente) la red Docker macvlan para servicios DNS del homelab.
# Lee variables del .env global del repo.
set -euo pipefail

ENV_FILE="/home/homelab/homelab/.env"
if [[ ! -r "$ENV_FILE" ]]; then
    echo "ERROR: no se encuentra $ENV_FILE" >&2
    exit 1
fi
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

NET="dns_lan"

: "${LAN_SUBNET:?LAN_SUBNET no definido en .env}"
: "${LAN_GATEWAY:?LAN_GATEWAY no definido en .env}"
: "${LAN_PARENT_IF:?LAN_PARENT_IF no definido en .env}"
: "${LAN_MACVLAN_RANGE:?LAN_MACVLAN_RANGE no definido en .env}"
: "${LAN_MACVLAN_SHIM_IP:?LAN_MACVLAN_SHIM_IP no definido en .env}"

# Sanidad: la interfaz padre debe existir y estar UP.
if ! ip -br link show "$LAN_PARENT_IF" 2>/dev/null | grep -q ' UP '; then
    echo "ERROR: interfaz '$LAN_PARENT_IF' no existe o no está UP" >&2
    exit 1
fi

if docker network inspect "$NET" >/dev/null 2>&1; then
    echo "Red '$NET' ya existe. OK."
    exit 0
fi

docker network create \
    --driver macvlan \
    --subnet "$LAN_SUBNET" \
    --gateway "$LAN_GATEWAY" \
    --ip-range "$LAN_MACVLAN_RANGE" \
    --aux-address "host=$LAN_MACVLAN_SHIM_IP" \
    -o parent="$LAN_PARENT_IF" \
    "$NET"

echo "Red macvlan '$NET' creada (subnet=$LAN_SUBNET range=$LAN_MACVLAN_RANGE parent=$LAN_PARENT_IF)."
EOF
sudo chown homelab:homelab /home/homelab/homelab/scripts/20-create-macvlan-network.sh
sudo chmod 0750 /home/homelab/homelab/scripts/20-create-macvlan-network.sh

bash /home/homelab/homelab/scripts/20-create-macvlan-network.sh
```

### Decisiones, clave por clave

| Argumento | Valor | Por qué |
|---|---|---|
| Nombre | `dns_lan` | Identifica el rol (DNS expuesto en LAN) y no se confunde con `homelab` (bridge interna). En `docker network ls` queda explícito. |
| `--driver` | `macvlan` | Lo que decide este documento. Otras opciones (`ipvlan`) tienen subcasos válidos pero son menos compatibles con routers domésticos: macvlan presenta MACs distintas y el router las trata como clientes normales. |
| `--subnet` | `${LAN_SUBNET}` (`192.168.1.0/24`) | **La misma** que la LAN física. Macvlan no NAT-ea: la subred es la del segmento de capa 2. |
| `--gateway` | `${LAN_GATEWAY}` (`192.168.1.1`) | La gateway real de la LAN. Los contenedores macvlan salen a internet por aquí. |
| `--ip-range` | `${LAN_MACVLAN_RANGE}` (`192.168.1.0/29`) | Pool del que Docker auto-asigna si un contenedor no fija `--ip`. Pequeño y predecible. Pi-hole y Unbound fijan IP explícita; el rango es solo seguridad-en-profundidad. |
| `--aux-address` | `host=${LAN_MACVLAN_SHIM_IP}` (`192.168.1.9`) | Reserva esa IP **fuera** del pool: Docker no la asignará nunca a un contenedor. Es la IP que la siguiente sección le pone a la `macvlan-shim` del host. |
| `-o parent` | `${LAN_PARENT_IF}` (`eth0`) | Sobre qué NIC física se monta. **Ethernet sí, Wi-Fi no**, ya argumentado. |
| (sin `--internal`) | — | macvlan **no es internal**: los contenedores deben llegar a la WAN para hacer `apt update` o `dig` recursivo (Unbound). |
| (sin `--gateway` extra para IPv6) | — | Este homelab opera solo en IPv4 (Fase 1). IPv6 se reabre en `docs/13-operaciones/` si llega el día. |

### Verificación inmediata

```bash
docker network ls --filter driver=macvlan
# NETWORK ID     NAME      DRIVER    SCOPE
# xxxxxxxxxxxx   dns_lan   macvlan   local

docker network inspect dns_lan --format '{{json .IPAM.Config}}' | python3 -m json.tool
# [
#   {
#     "Subnet": "192.168.1.0/24",
#     "IPRange": "192.168.1.0/29",
#     "Gateway": "192.168.1.1",
#     "AuxiliaryAddresses": { "host": "192.168.1.9" }
#   }
# ]

docker network inspect dns_lan --format '{{.Options.parent}}'
# eth0
```

A esta altura **todavía no hay contenedores** en `dns_lan`: la red existe, es válida, y los stacks `pihole/` y `unbound/` la consumirán como `external: true`.

---

## La trampa de macvlan: host ↔ contenedor en la misma Pi

Hay **un** comportamiento de macvlan que sorprende al primer encuentro y que conviene fijar:

> El **host** Linux **no puede** comunicarse con los **contenedores macvlan** que corren **en ese mismo host**, aunque ambos compartan el segmento `192.168.1.0/24`.

Es una limitación del driver del kernel (`macvlan` con modo `bridge` filtra el tráfico que sube/baja por la NIC física hacia las MAC virtuales que están en la **misma** NIC). Otros hosts de la LAN sí ven a los contenedores; solo la propia Pi no. Eso significa, en la práctica:

| Caso | Funciona | Notas |
|---|---|---|
| Móvil en la LAN → Pi-hole `192.168.1.2:53` | Sí | macvlan opera de capa 2 normalmente. |
| Caddy (en la red `homelab`, dentro de la Pi) → Pi-hole `192.168.1.2:80` | **No** sin shim | Caddy y Pi-hole están en redes Docker distintas y, además, en el mismo host. |
| Pi (host) → Pi-hole `192.168.1.2` (`ping`, `dig`, `curl http://192.168.1.2`) | **No** sin shim | El host **no** ve a sus propios contenedores macvlan. |
| Pi-hole → internet (router → ISP) | Sí | El tráfico baja por `eth0` al router como cualquier otro dispositivo. |
| Pi-hole → Unbound (`192.168.1.3`) | Sí (ambos en `dns_lan`) | Comunicación contenedor↔contenedor en la misma red macvlan no sufre la limitación. |

La solución estándar es crear una **interfaz virtual macvlan en el host** (la "shim") que el host usa exclusivamente para hablar con los contenedores macvlan. El host envía tráfico hacia `192.168.1.2/3` por la shim en lugar de por `eth0`, y la pila de red lo trata como tráfico hacia un peer válido.

Diagrama mental:

```
            +-------------------------------------+
            |              Raspberry Pi           |
            |                                     |
            |  +-------+    +------------------+  |
            |  |  Pi   |    |  Contenedores    |  |
            |  | host  |    |  macvlan (dns_lan)|  |
            |  | eth0  |    |  192.168.1.2/3   |  |
            |  | .10   |    +------------------+  |
            |  +---+---+              ^           |
            |      |                  |           |
            |      |   macvlan-shim   |           |
            |      +---->.9 ----------+           |
            |               (link macvlan, eth0)  |
            +----------------|--------------------+
                             v
                       Router LAN .1
```

El router y otros hosts ven `eth0` (`.10`) y los contenedores (`.2`, `.3`) por L2. La shim es **interna** a la Pi y solo el kernel la usa para la ruta `192.168.1.2/32` y `192.168.1.3/32`.

### Crear la `macvlan-shim` y persistirla

La interfaz se crea con `ip link` y se asigna IP, pero **no es persistente**: tras un reboot desaparece. Hay tres formas de hacerla persistente; este homelab elige una unidad `systemd` *one-shot* porque es la más explícita y rastreable.

```bash
sudo tee /home/homelab/homelab/scripts/21-macvlan-shim.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
# Crea/actualiza (idempotente) la interfaz macvlan-shim en el host
# para que la Pi pueda hablar con sus contenedores en la red dns_lan.
set -euo pipefail

ENV_FILE="/home/homelab/homelab/.env"
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

: "${LAN_PARENT_IF:?}"
: "${LAN_MACVLAN_SHIM_IP:?}"
: "${PIHOLE_IP:?}"
: "${UNBOUND_IP:?}"

SHIM_IF="macvlan-shim"

# 1) Crear la interfaz si no existe.
if ! ip link show "$SHIM_IF" >/dev/null 2>&1; then
    ip link add "$SHIM_IF" link "$LAN_PARENT_IF" type macvlan mode bridge
fi

# 2) Asignar IP (idempotente: borrar primero las que pudieran sobrar).
ip addr flush dev "$SHIM_IF"
ip addr add "${LAN_MACVLAN_SHIM_IP}/32" dev "$SHIM_IF"

# 3) Levantar.
ip link set "$SHIM_IF" up

# 4) Rutas /32 hacia los contenedores macvlan que el host necesita alcanzar.
for ip in "$PIHOLE_IP" "$UNBOUND_IP"; do
    ip route replace "${ip}/32" dev "$SHIM_IF"
done

echo "macvlan-shim activo: ${LAN_MACVLAN_SHIM_IP} -> ${PIHOLE_IP}, ${UNBOUND_IP}"
EOF
sudo chown root:root /home/homelab/homelab/scripts/21-macvlan-shim.sh
sudo chmod 0750 /home/homelab/homelab/scripts/21-macvlan-shim.sh
```

Unidad `systemd` que lo lanza al arranque, **después** de que `eth0` tenga IP:

```bash
sudo tee /etc/systemd/system/macvlan-shim.service >/dev/null <<'EOF'
[Unit]
Description=macvlan-shim para comunicación host <-> contenedores macvlan (dns_lan)
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/home/homelab/homelab/scripts/21-macvlan-shim.sh
ExecStop=/usr/sbin/ip link del macvlan-shim

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now macvlan-shim.service
systemctl status macvlan-shim.service --no-pager
```

Justificación de la unidad:

| Clave | Valor | Por qué |
|---|---|---|
| `After=network-online.target docker.service` | espera a tener IP en `eth0` y al daemon Docker | Crear la shim antes de que `eth0` esté `UP` falla; antes de que Docker exista, las rutas `/32` están bien pero los contenedores aún no están y tampoco molesta. |
| `Type=oneshot` + `RemainAfterExit=yes` | El script no es un daemon, ejecuta y sale | Pero `systemd` lo ve como "activo" hasta el `ExecStop`, lo que permite consultar el estado coherentemente. |
| `ExecStop=ip link del macvlan-shim` | borra la interfaz al apagar | Limpieza simétrica. Sin ella, un `systemctl restart` deja una shim huérfana hasta el siguiente reboot. |
| `Requires=docker.service` | si Docker se cae, la shim también baja | Coherencia: la shim solo tiene sentido con Docker arriba. |

### Verificación

```bash
ip -br link show macvlan-shim
# macvlan-shim     UNKNOWN        ee:ee:ee:xx:xx:xx ...

ip -br -4 addr show macvlan-shim
# macvlan-shim     UNKNOWN        192.168.1.9/32

ip route show 192.168.1.2
# 192.168.1.2 dev macvlan-shim scope link

ip route show 192.168.1.3
# 192.168.1.3 dev macvlan-shim scope link
```

Tras desplegar Pi-hole en `02-pihole.md`, el host podrá:

```bash
ping -c 2 192.168.1.2          # responde
curl -fsS http://192.168.1.2/admin/  # 200
```

Sin la shim, esos comandos darían `Destination Host Unreachable` aun con Pi-hole funcionando perfectamente para el resto de la LAN.

---

## Cómo lo consumen los stacks (referencia para Fase 3.2 y 3.3)

Pi-hole (`stacks/pihole/docker-compose.yml`) y Unbound (`stacks/unbound/docker-compose.yml`) referencian la red **como externa**, sin re-crearla, exactamente igual que `homelab`:

```yaml
# Fragmento de referencia. El compose completo se materializa en 02-pihole.md.

services:
  pihole:
    image: pihole/pihole:2024.x
    container_name: pihole
    hostname: pihole
    networks:
      dns_lan:
        ipv4_address: ${PIHOLE_IP}    # 192.168.1.2
      homelab: {}                     # también en homelab para que Caddy haga proxy del :80
    cap_add: ["NET_ADMIN"]            # Pi-hole modifica iptables internas para DNS
    # ... (resto: env, volumes, healthcheck, etc.)

networks:
  dns_lan:
    external: true
  homelab:
    external: true
```

Decisiones que esta plantilla ya prefigura, **sin cerrarlas aquí** (lo hará `02-pihole.md`):

- Pi-hole se conecta a **dos** redes: `dns_lan` (para escuchar `:53` con IP propia en la LAN) y `homelab` (para que Caddy lo alcance internamente sin tener que pasar por la shim). Es el patrón estándar para servicios "mitad expuestos a LAN, mitad detrás de Caddy".
- `ipv4_address: ${PIHOLE_IP}` fija la IP exacta dentro de `dns_lan`, dentro del `--ip-range`.
- **No** se declara `ports:` para `:53`: el contenedor escucha directamente en su IP macvlan, sin NAT. Eso es exactamente lo que arregla las "IPs reales por cliente" de Pi-hole.
- `homelab` se declara sin `ipv4_address` porque a esa red el direccionamiento lo lleva el pool de Docker (`172.30.10.x`); solo importa el nombre DNS interno (`pihole.homelab`) que ven los demás contenedores.

Unbound es análogo pero **solo** en `dns_lan` (no necesita ser proxy-ado por Caddy): IP `${UNBOUND_IP}`, escucha `:53` para que Pi-hole le delegue.

---

## Almacenamiento

Rutas que toca este documento, todas en la microSD (versionables) salvo el estado runtime de la red:

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/.env` | microSD | `homelab:homelab` | `0600` | Añade `LAN_SUBNET`, `LAN_GATEWAY`, `LAN_PARENT_IF`, `LAN_MACVLAN_RANGE`, `LAN_MACVLAN_SHIM_IP`, `PIHOLE_IP`, `UNBOUND_IP`. **No** versionado. |
| `/home/homelab/homelab/.env.example` | microSD | `homelab:homelab` | `0644` | Mismas claves con valores de ejemplo. **Sí** versionado. |
| `/home/homelab/homelab/scripts/20-create-macvlan-network.sh` | microSD | `homelab:homelab` | `0750` | Crea la red Docker macvlan `dns_lan`. Versionado. |
| `/home/homelab/homelab/scripts/21-macvlan-shim.sh` | microSD | `root:root` | `0750` | Crea/actualiza la `macvlan-shim`. Llamado por `systemd`. Versionado. |
| `/etc/systemd/system/macvlan-shim.service` | microSD | `root:root` | `0644` | Unidad `systemd` que persiste la shim. **No** se versiona como fichero del sistema; **sí** se documenta en este doc para reproducibilidad. |
| Red Docker `dns_lan` | runtime | (daemon) | — | Estado del daemon en `/mnt/hd2t/docker/network/`. Reproducible desde `20-create-macvlan-network.sh`. |
| Interfaz `macvlan-shim` | runtime | (kernel) | — | Estado del kernel. Reproducible desde la unidad `systemd`. |

Reserva de IP en el router doméstico: estado **fuera** de la Pi (vive en la NVRAM del router). Se anota en `docs/00-hardware/` o en una nota de operaciones cuando aparezca la Fase 13.

---

## Backup

| Artefacto | Estrategia |
|---|---|
| `scripts/20-create-macvlan-network.sh` y `scripts/21-macvlan-shim.sh` | Versionados en git. Reproducibles tras un reflasheo. |
| Unidad `macvlan-shim.service` | Reproducible desde **este documento** (el contenido literal del `tee`). No se respalda. |
| `.env` con las IPs y rangos | Respaldado por Borg (Fase 7) como parte de `/home/homelab/homelab/`. Cifrado en el repo Borg. |
| Red Docker `dns_lan` y interfaz `macvlan-shim` | No se respaldan: son estado runtime, se reconstruyen ejecutando los scripts. |
| Reservas DHCP del router | Operación manual en la admin del router. **No respaldable** desde la Pi. Documentar fuera de este fichero (notas de hardware/operaciones). |

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `Error response from daemon: Pool overlaps with other one on this address space` | El `--subnet` solapa con otra red Docker (la propia `homelab` no, porque está en `172.30.10.0/24`, pero podría haber bridges autogenerados que cogieron `192.168.x.0/24`). | Borrar la red conflictiva o reubicar la otra red Docker. Inspeccionar con `docker network ls` + `docker network inspect`. |
| `Error response from daemon: network with name dns_lan already exists` | Ya creada por una ejecución previa. | El script es idempotente: si aparece este error es porque alguien la creó **a mano** sin usar el script. Comparar `docker network inspect dns_lan` con los valores esperados; si no coinciden, `docker network rm dns_lan` y re-ejecutar el script. |
| Otros hosts de la LAN ven a Pi-hole en `192.168.1.2`, pero la Pi (host) no le hace `ping` | La `macvlan-shim` no está activa o no tiene rutas `/32`. | `systemctl status macvlan-shim`; revisar `ip -br link show macvlan-shim` y `ip route show 192.168.1.2`. Re-ejecutar `scripts/21-macvlan-shim.sh`. |
| Tras un reboot, `macvlan-shim` no aparece | Unidad `systemd` no habilitada o falló por orden de arranque. | `sudo systemctl enable --now macvlan-shim`; `journalctl -u macvlan-shim --no-pager`. Si `eth0` aún no tenía IP al lanzarse, añadir `After=network-online.target` (ya está) y verificar `systemctl is-enabled systemd-networkd-wait-online` o el equivalente con NetworkManager (`NetworkManager-wait-online`). |
| Pi-hole arranca pero no responde en `192.168.1.2:53` desde otros equipos | Compose en Wi-Fi (no Ethernet) o `parent` distinto a `eth0`. | macvlan no funciona sobre Wi-Fi. Verificar: `docker network inspect dns_lan --format '{{.Options.parent}}'`. Si no es `eth0`, recrear la red con el script. |
| Algunos clientes resuelven y otros no, intermitentemente | El router está asignando alguna IP del rango macvlan a otro dispositivo. | Restringir el pool DHCP del router como se indica en "Reserva en el router". Reiniciar leases. |
| El host pierde DNS al levantar Pi-hole | `/etc/resolv.conf` apuntaba a un upstream que ya no responde, o se cambió a `192.168.1.2` antes de que la shim funcione. | Mantener un DNS de fallback en `/etc/resolv.conf` (p. ej. `1.1.1.1`) hasta que `02-pihole.md` complete la transición. Esa transición se hace con red de seguridad. |
| `docker network rm dns_lan` falla con "has active endpoints" | Pi-hole o Unbound siguen conectados. | Bajar antes los stacks: `docker compose -f stacks/pihole/docker-compose.yml down` y equivalente para Unbound, luego `docker network rm dns_lan`. |
| Después de re-crear `dns_lan`, los stacks no levantan: "network not found" | Los contenedores tienen una referencia stale a la red anterior. | `docker compose ... up -d --force-recreate`. La red `external` se resuelve por **nombre** y el nombre no cambió, pero el ID de red sí; `--force-recreate` la reasocia. |
| `iptables` en el host bloquea la shim | UFW o reglas heredadas tirando todo lo que viene/va por `macvlan-shim`. | Por defecto UFW no la toca (no está en el set de interfaces gestionadas). Si se ve tráfico bloqueado en `journalctl -k`, añadir reglas explícitas: `sudo ufw allow in on macvlan-shim` y `sudo ufw allow out on macvlan-shim`. |

---

## Decisiones que **no** se toman en este documento

- **Despliegue de Pi-hole**: imagen, `.env`, listas de bloqueo, DNS local de servicios (`*.lan`), upstream a Unbound. Todo eso vive en `docs/03-red/02-pihole.md`.
- **Despliegue de Unbound**: configuración del recursor, hints, `dnssec-validation`, integración con Pi-hole. Vive en `docs/03-red/03-unbound.md`.
- **Caddy y exposición HTTPS interna**: la red macvlan **no** es por donde Caddy publica :80/:443. Caddy seguirá en la red `homelab` y bindeará puertos sobre la IP de la Pi. Documentado en `docs/03-red/04-caddy.md`.
- **Tailscale**: las IPs `100.64/10` no chocan con macvlan. Si en el futuro hace falta que un cliente Tailscale alcance directamente `192.168.1.2`, se evaluará en `docs/03-red/05-tailscale.md` (subnet router, advertise routes). Aquí no se anticipa.
- **IPv6**: no se habilita en macvlan. Si la LAN del operador tiene IPv6 activa, los contenedores macvlan caerán de vuelta a IPv4 only, lo cual es aceptable para DNS. Reabrible en `docs/13-operaciones/`.
- **Cortafuegos en macvlan**: los contenedores macvlan están en la LAN como un dispositivo más. UFW del host no los protege (es exactamente lo que se quiere para Pi-hole, que **debe** atender consultas de la LAN). Si algún servicio macvlan futuro necesita filtrado, se trata en su documento o en `docs/04-seguridad/`.
- **Múltiples redes macvlan**: en este homelab, una basta. Si surgiese una segunda (p. ej. una `iot_lan` para servicios de domótica), se añade aquí como sección pero sin reabrir las decisiones generales.

---

## Verificación Final

Antes de pasar a `02-pihole.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| `eth0` con IP estática y gateway | `ip -br -4 addr show eth0; ip route show default` | `192.168.1.10/24` y `default via 192.168.1.1 dev eth0` |
| Variables nuevas en `.env` | `grep -E '^(LAN_|PIHOLE_IP|UNBOUND_IP)' /home/homelab/homelab/.env` | las 7 claves presentes y rellenas |
| Plantilla `.env.example` actualizada y versionada | `git status .env.example` | aparece como modificada/tracked |
| Script de creación versionado | `ls -l /home/homelab/homelab/scripts/20-create-macvlan-network.sh` | `0750 homelab:homelab` |
| Script de shim versionado | `ls -l /home/homelab/homelab/scripts/21-macvlan-shim.sh` | `0750 root:root` |
| Red Docker `dns_lan` creada | `docker network inspect dns_lan --format '{{.Driver}} {{.Options.parent}}'` | `macvlan eth0` |
| `--subnet`, `--gateway`, `--ip-range`, `--aux-address` correctos | `docker network inspect dns_lan --format '{{json .IPAM.Config}}'` | refleja `LAN_SUBNET`, `LAN_GATEWAY`, `LAN_MACVLAN_RANGE`, `host=LAN_MACVLAN_SHIM_IP` |
| Idempotencia del script de red | `bash scripts/20-create-macvlan-network.sh` (segunda vez) | `Red 'dns_lan' ya existe. OK.` |
| Unidad `systemd` activa y habilitada | `systemctl is-active macvlan-shim; systemctl is-enabled macvlan-shim` | `active`, `enabled` |
| Interfaz `macvlan-shim` con IP correcta | `ip -br -4 addr show macvlan-shim` | `192.168.1.9/32` |
| Rutas `/32` hacia los contenedores DNS | `ip route show 192.168.1.2; ip route show 192.168.1.3` | `... dev macvlan-shim scope link` |
| Idempotencia del script de shim | `sudo bash scripts/21-macvlan-shim.sh` (segunda vez) | termina con `macvlan-shim activo: ...` sin errores |
| Ningún dispositivo de la LAN responde en `.2` ni `.3` aún | `ping -c 2 192.168.1.2; ping -c 2 192.168.1.3` desde **otro** host | `100% packet loss` o `Destination Host Unreachable` (correcto: aún no hay contenedor) |
| Persistencia tras reboot | `sudo reboot` y reconectar; reverificar las dos comprobaciones de shim | `macvlan-shim` reaparece automáticamente; rutas presentes |
| El router **no** asigna por DHCP en `LAN_MACVLAN_RANGE` | Comprobar la admin del router: pool DHCP empieza en `192.168.1.50` | Sí |
| Pi sigue resolviendo DNS hacia el exterior (con upstream provisional) | `dig @1.1.1.1 example.com +short` | una IP. El homelab aún no usa Pi-hole; eso lo cambia `02-pihole.md`. |

Cumplido el último punto, la Fase 3 puede continuar: ya hay **dirección y carril** para los servicios DNS. La siguiente puerta es desplegar Pi-hole sobre `dns_lan` con su IP propia (`02-pihole.md`).

---

## Referencias

- [Documento anterior: `docs/02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)
- [Documento siguiente: `docs/03-red/02-pihole.md`](./02-pihole.md)
- [Documento relacionado: `docs/02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)
- [Documento relacionado: `docs/01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md)
- [Docker — `macvlan` network driver](https://docs.docker.com/network/drivers/macvlan/)
- [Docker — `docker network create` reference](https://docs.docker.com/reference/cli/docker/network/create/)
- [Linux Foundation — `ip-link(8)` (`type macvlan`)](https://man7.org/linux/man-pages/man8/ip-link.8.html)
- [Pi-hole — Running on Docker](https://github.com/pi-hole/docker-pi-hole)
- [systemd — `systemd.service(5)` (Type=oneshot, RemainAfterExit)](https://www.freedesktop.org/software/systemd/man/systemd.service.html)
- [systemd — `systemd.unit(5)` (After/Requires/Wants)](https://www.freedesktop.org/software/systemd/man/systemd.unit.html)
- [Lawrence Systems — Docker macvlan host shim explained](https://github.com/moby/moby/issues/30093)
