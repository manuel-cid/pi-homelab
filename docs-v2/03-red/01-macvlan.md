# Red Docker macvlan (`lan_macvlan`)

## Descripción

Creación de la **red Docker `lan_macvlan`** que dará IP propia en la LAN (rango privado del router doméstico) a los contenedores que la necesitan: principalmente **Pi-hole** ([`02-pihole.md`](./02-pihole.md)) y **Unbound** ([`03-unbound.md`](./03-unbound.md)). Hacerlos vivir en la LAN como si fueran dispositivos físicos resuelve dos problemas en bloque:

1. **Pi-hole expone DNS en `:53/udp` y `:53/tcp`**. Si Pi-hole publicara `53` en el host, chocaría con `systemd-resolved` y con cualquier resolver del sistema, y obligaría a abrir `53` por `ufw` con todas las consecuencias documentadas en [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md) (Docker manipula `iptables`/`nftables` por su cuenta).
2. **Caddy expone `:80` y `:443` en el host**. Coexistir con Pi-hole en la misma IP fuerza a Pi-hole a usar puertos no estándar para su UI, lo cual rompe clientes y dificulta firmar el certificado interno de su panel. Con Pi-hole en su propia IP de LAN, **Caddy queda libre** para ocupar la IP de la Pi en `80/443`.

Este documento cubre, en este orden:

1. **Concepto y limitaciones** del driver `macvlan` en modo `bridge`: qué consigue, qué **no** consigue (la conocida incomunicación host ↔ contenedor macvlan) y cómo se solventa con una **interfaz `lan-shim`** en el host.
2. **Plan de IPs** en la LAN: subred, gateway, rango reservado para macvlan, política de DHCP del router.
3. **Reserva en el DHCP del router** del bloque que Docker va a usar y, opcionalmente, asignación estática por MAC de cada contenedor.
4. **Creación idempotente de la red `lan_macvlan`** con `docker network create`, justificando cada flag (`--subnet`, `--gateway`, `--ip-range`, `--aux-address`, `-o parent=eth0`).
5. **Interfaz `lan-shim` en el host** y **ruta** que la prefiere para alcanzar el rango macvlan, con persistencia mediante una unidad **systemd** (independiente de NetworkManager / `dhcpcd` / `systemd-networkd`).
6. **Coexistencia con `ufw`**: por qué las reglas del firewall del host **no afectan** al tráfico que entra a un contenedor macvlan y qué hay que documentar para [`../13-operaciones/04-red-y-puertos.md`](../13-operaciones/04-red-y-puertos.md).
7. **Verificación**, **smoke test** con un contenedor desechable y **solución de problemas**.

> **Alcance**: aquí no se despliega Pi-hole ni Unbound. Solo se prepara la red y la interfaz auxiliar del host. El primer servicio que la consume es Pi-hole en [`02-pihole.md`](./02-pihole.md).

> **Recordatorio**: el homelab opera en **LAN + Tailscale**. La macvlan es una red **interna a la LAN**: las IPs que asigna son privadas (`192.168.x.x` típicamente) y no son alcanzables desde internet. Tailscale, cuando se despliegue ([`05-tailscale.md`](./05-tailscale.md)), ofrecerá acceso remoto al servicio Pi-hole vía la IP del nodo Tailscale, no vía la IP macvlan.

---

## Requisitos Previos

- Raspberry Pi 5 con **Ethernet conectado al router** (`eth0` activo). El Wi-Fi **no soporta** `macvlan` en modo `bridge` con la mayoría de chips (incluido el de la Pi 5): la macvlan **debe** ir sobre `eth0`. Validar que la Pi está cableada antes de continuar.
- IP fija de la Pi en el router (reservación DHCP por MAC, según [`../00-hardware/02-esquema-conexiones.md`](../00-hardware/02-esquema-conexiones.md)). Asume `192.168.1.10` en los ejemplos: ajustar a la propia.
- Docker Engine y Compose v2 instalados según [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md), con `default-address-pools=172.20.0.0/16` (la macvlan vive en la subred de la LAN, no en este pool, pero el pool acota dónde están las redes bridge para que no colisionen).
- Red Docker `homelab` (bridge compartido) creada según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2. Pi-hole estará simultáneamente en `lan_macvlan` (para servir DNS a la LAN) y en `homelab` (para que Caddy y Prometheus puedan alcanzarlo por nombre).
- `ufw` activo con SSH permitido desde la LAN según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md).
- Acceso al **panel de administración del router** (cuenta admin) para reservar el rango macvlan en su DHCP.
- **Una segunda sesión SSH** abierta antes de tocar `eth0` o crear `lan-shim`: si la red se rompe momentáneamente, esa sesión sigue viva y permite revertir.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Driver de la red Docker | **`macvlan`**, modo `bridge` | El modo `bridge` de macvlan permite que **todos** los contenedores macvlan se vean entre sí en L2 sin pasar por el router, y aun así aparezcan como dispositivos independientes en la LAN. Modo `private` no se usa: aislaría Pi-hole de Unbound. Driver `ipvlan` se descarta por mayor complejidad y peor compatibilidad con DHCP del router. |
| Interfaz padre | **`eth0`** | Único enlace cableado de la Pi 5. La WLAN del chip CYW43455 no soporta `macvlan bridge` (no entrega tramas con MAC distinta a la de la radio). |
| Subred macvlan (`--subnet`) | **`192.168.1.0/24`** (= subred de la LAN) | Macvlan debe declarar la subred **real** de la LAN. La gateway y la `--subnet` se usan para que Docker pueda asignar IPs sin colisión y para que el contenedor sepa quién es su default gateway. |
| Gateway macvlan (`--gateway`) | **`192.168.1.1`** (= router doméstico) | El contenedor habla con la LAN como cualquier otro host: su gateway es el router. |
| Rango asignado a Docker (`--ip-range`) | **`192.168.1.240/28`** (16 IPs: `.240`–`.255`) | Bloque pequeño y predecible al final del rango privado, fuera del *pool DHCP* típico (`.100`–`.200`) y de las IPs estáticas habituales (`.2`–`.50`). 16 IPs sobran: este homelab solo planea Pi-hole + Unbound (+ alguna futura) en macvlan. |
| Reserva en el router | **DHCP del router con el rango `.240`–`.255` excluido del pool dinámico** | Garantiza que el router nunca otorga `.241` (Pi-hole) o `.242` (Unbound) a otro dispositivo. Sin esta exclusión, una nueva tablet entrando a la LAN podría recibir una IP que Docker considera suya y aparecer como conflicto. |
| Asignación de IPs a contenedores | **Estática vía `ipv4_address`** en cada `docker-compose.yml` | Pi-hole en `192.168.1.241`, Unbound en `192.168.1.242`. Estabilidad para que el router pueda apuntar a Pi-hole como DNS y para que las reglas DNS internas no se rompan tras un `up -d --force-recreate`. |
| IP de la `lan-shim` del host | **`192.168.1.240`** (primer IP del rango macvlan, declarada `--aux-address`) | La interfaz `lan-shim` necesita una IP de la propia subred macvlan para poder rutar tráfico hacia los contenedores. Reservarla con `--aux-address host=192.168.1.240` evita que Docker la asigne a un futuro contenedor. |
| Nombre de la interfaz auxiliar | **`lan-shim`** | Corto, descriptivo, sin caracteres exóticos. Aparece en `ip link`, `ufw status` y los logs. |
| Persistencia de `lan-shim` | **Unidad `systemd` propia** (`lan-shim.service`), no NetworkManager | Bookworm en la Pi 5 usa NetworkManager por defecto, pero gestionar interfaces macvlan vía NM exige un fichero `nmconnection` con detalles que cambian entre versiones. Un servicio `systemd` con `ip link add ...` es portable, transparente y no depende de qué gestor de red esté activo. |
| Modo de la macvlan | `bridge` (no `passthru`, no `vepa`) | `bridge` es el único modo que permite contenedor↔contenedor en la misma macvlan sin salir al switch físico. |
| Crear `lan_macvlan` como `external` desde Compose | **Sí**: la red se crea **una vez** con `docker network create` y los stacks la usan como `external: true` | Coherente con la regla de la red `homelab` (§4.4 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)): la red macvlan es infraestructura del homelab, no propiedad de un stack concreto. |

---

## 1. Concepto y limitaciones de macvlan

### 1.1. Qué hace `macvlan`

Cada contenedor en una red `macvlan` tiene **su propia dirección MAC**, su propia IP en la subred física y aparece en la LAN como un dispositivo más. El switch reenvía las tramas a esa MAC sin saber que detrás vive un contenedor.

```
LAN 192.168.1.0/24
        │
   ┌────┴────┐
   │ Router  │ 192.168.1.1   (DHCP, gateway, DNS upstream)
   └────┬────┘
        │ (cable)
   ┌────┴──────┐
   │   eth0    │ 192.168.1.10        ← IP del host Pi (NetworkManager / dhcpcd)
   │ (Raspi 5) │
   │           │
   │  lan-shim │ 192.168.1.240       ← interfaz macvlan del host (§5)
   │           │
   │  Docker:  │
   │  ┌──────┐ │
   │  │pihole│ 192.168.1.241        ← contenedor macvlan
   │  └──────┘ │
   │  ┌──────┐ │
   │  │unbnd │ 192.168.1.242        ← contenedor macvlan
   │  └──────┘ │
   └───────────┘
```

### 1.2. Lo que **no** hace: incomunicación host ↔ macvlan

Por diseño del kernel Linux, **un host no puede hablar con sus propios contenedores macvlan a través de `eth0`**: el kernel detecta que la MAC destino es local y rebota el paquete antes de salir al switch. Resultado: desde la Pi, `ping 192.168.1.241` (Pi-hole) **falla**, aunque desde cualquier otro equipo de la LAN funcione perfectamente.

Esto rompe muchas cosas que el homelab necesita:

- El propio host quiere usar Pi-hole como resolver (`/etc/resolv.conf` apuntando a `192.168.1.241`). Sin shim, **no puede**.
- Prometheus (en bridge `homelab`) querrá *scrapear* `pihole-exporter` por la IP macvlan si así se configura.
- Caddy, aunque enrute Pi-hole por `homelab` (no por la macvlan), aún necesita poder hacer healthchecks contra `192.168.1.241` desde el host.

### 1.3. Solución: interfaz `lan-shim` en el host

Se crea **otra macvlan**, esta vez **en el propio host** (no en Docker), con el mismo padre `eth0`. Esa interfaz, llamada `lan-shim` en este homelab, recibe una IP de la subred (`192.168.1.240`) y se enruta hacia ella todo el tráfico que vaya a `192.168.1.240/28`.

A nivel del kernel, `lan-shim` y los contenedores macvlan **son interfaces hermanas** sobre `eth0`, así que el kernel las trata como dispositivos distintos y permite la comunicación. El precio es una IP "extra" para el host, asumido en el plan.

> Esta es la receta canónica documentada por Docker en su [guía de macvlan](https://docs.docker.com/network/drivers/macvlan/) y por la wiki de Linux Foundation. No es un parche: es la única forma estable de tener host ↔ macvlan-container sin renunciar a Ethernet.

---

## 2. Plan de IPs en la LAN

Asumiendo subred `192.168.1.0/24`, gateway/DHCP en `192.168.1.1`. Sustituir por la propia si difiere.

| Rango | Uso | Quién lo controla |
|---|---|---|
| `192.168.1.1` | Router (gateway, DNS upstream temporal) | Router |
| `192.168.1.2` – `192.168.1.99` | Reservas estáticas y dispositivos "infraestructura" | Operador (vía router) |
| `192.168.1.10` | **Pi 5 (host)**: IP cableada en `eth0` | Reserva DHCP por MAC |
| `192.168.1.100` – `192.168.1.239` | Pool DHCP dinámico (móviles, portátiles, IoT...) | Router |
| `192.168.1.240` – `192.168.1.255` | **Reservado para `lan_macvlan`** | Operador + Docker |
| `192.168.1.240` | `lan-shim` (interfaz macvlan en el host) | `aux-address` + systemd |
| `192.168.1.241` | Pi-hole | `ipv4_address` en su Compose |
| `192.168.1.242` | Unbound | `ipv4_address` en su Compose |
| `192.168.1.243` – `192.168.1.255` | Libres para futuros servicios macvlan | Asignación manual |

> Si la LAN del lector usa otra subred (por ejemplo `192.168.0.0/24` o `10.0.0.0/24`), basta con desplazar todos los valores: subred, gateway y rango macvlan al final del bloque privado.

---

## 3. Reserva en el DHCP del router

**Antes** de crear la red Docker, hay que decirle al router que **no entregue** las IPs `192.168.1.240`–`192.168.1.255` por DHCP. Sin este paso, un dispositivo nuevo que entre a la LAN puede recibir una IP que Docker considera suya y provocar un *IP conflict* (dos hosts respondiendo a ARP por la misma IP).

Cómo varía por router (no se puede automatizar, hay que entrar al panel):

| Router | Dónde está | Qué cambiar |
|---|---|---|
| Genérico (DHCP "start" / "end") | LAN → DHCP server | Reducir el `end` del pool de `.254` a `.239`. |
| Mikrotik | IP → DHCP Server → Networks | Cambiar el `pool` para excluir `.240`–`.255` (crear pool `192.168.1.100-192.168.1.239`). |
| OPNsense / pfSense | Services → DHCPv4 | Acotar `Range from/to` a `.100`–`.239`. |
| Routers ISP (Movistar, O2, Orange, Vodafone) | Sección "DHCP" del panel admin | A veces no permite editar el rango: en ese caso, **fijar el pool DHCP a `.100`–`.200`** y asumir que el operador es responsable de no asignar `.240`–`.255` manualmente. |

Adicionalmente, **si el router lo permite**, crear reservas DHCP por MAC para Pi-hole y Unbound:

- MAC de Pi-hole: la genera Docker al crear el contenedor. Para que sea **estable**, se fija a mano en el `docker-compose.yml` (lo hará [`02-pihole.md`](./02-pihole.md) con `mac_address: 02:42:c0:a8:01:f1`).
- MAC de Unbound: análoga, `02:42:c0:a8:01:f2`.

Las MACs `02:42:xx:xx:xx:xx` son el rango "locally administered" que Docker usa por defecto. Fijarlas no es obligatorio pero da estabilidad: si en el futuro se quisiera usar reservas DHCP del router en lugar de IPs estáticas en Compose, las MACs ya estarían bajo control del operador.

> No hay que tocar nada en la página de DHCP del router para Pi-hole/Unbound más allá de excluir el rango: las IPs se asignan **estáticamente por Docker** vía `ipv4_address`, no vía DHCP del router.

---

## 4. Crear la red Docker `lan_macvlan`

### 4.1. Detectar el nombre real del padre

Antes de copiar el comando, verificar que la interfaz cableada se llama `eth0`:

```bash
ip -br link show | grep -E '^(eth|en)'
# Esperado:
# eth0  UP  dc:a6:32:xx:xx:xx <BROADCAST,MULTICAST,UP,LOWER_UP>
```

Si la Pi tiene "predictable interface names" activos (raro en Raspberry Pi OS), puede aparecer como `enxXXX...`. En ese caso, **sustituir** `eth0` por el nombre real en todos los comandos.

### 4.2. Crear la red

```bash
docker network create \
  --driver macvlan \
  --subnet 192.168.1.0/24 \
  --gateway 192.168.1.1 \
  --ip-range 192.168.1.240/28 \
  --aux-address 'host=192.168.1.240' \
  -o parent=eth0 \
  -o macvlan_mode=bridge \
  lan_macvlan
```

| Flag | Por qué |
|---|---|
| `--driver macvlan` | El driver objetivo. |
| `--subnet 192.168.1.0/24` | La subred **completa** de la LAN. Macvlan exige la subred real, no un subconjunto. |
| `--gateway 192.168.1.1` | El router. Los contenedores la usarán como default route. |
| `--ip-range 192.168.1.240/28` | **Solo dentro de este rango** asigna Docker IPs automáticamente. Aunque las IPs concretas (`.241`, `.242`) se fijarán con `ipv4_address`, este flag es la línea de defensa: si alguien crea un contenedor sin IP fija, Docker lo confina al `.240/28` en lugar de robarle `.50` al portátil del operador. |
| `--aux-address 'host=192.168.1.240'` | Reserva `.240` para `lan-shim`: Docker la conoce pero **no** la asignará a ningún contenedor. La etiqueta `host=` es un nombre arbitrario para auditoría. |
| `-o parent=eth0` | Vincula la red al enlace físico `eth0`. |
| `-o macvlan_mode=bridge` | Modo macvlan que permite contenedor↔contenedor. Es el default desde Docker 20.10 pero se declara explícito por trazabilidad. |
| `lan_macvlan` | Nombre acordado en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.4. |

### 4.3. Idempotencia

El comando falla con `network with name lan_macvlan already exists` si se relanza. Para reaplicar tras un cambio de plan, primero **drenar** los contenedores que la usan y borrarla:

```bash
# Listar contenedores conectados a lan_macvlan.
docker network inspect lan_macvlan --format '{{range .Containers}}{{.Name}} {{end}}'

# Pararlos (ejemplo).
cd ~/homelab/stacks/dns && docker compose down

# Eliminar la red.
docker network rm lan_macvlan

# Recrear con el nuevo plan.
# (relanzar el comando de §4.2)
```

> **Nunca** usar `docker network prune` con `lan_macvlan` viva: aunque `prune` ignora las redes con contenedores activos, basta con que Pi-hole esté parado en ese momento para perderla y dejar la `lan-shim` apuntando a una red inexistente.

---

## 5. Interfaz `lan-shim` en el host

Una vez creada la red Docker, la Pi sigue **sin** poder hablar con `192.168.1.241` (Pi-hole). Toca crear la interfaz auxiliar.

### 5.1. Probar la receta a mano (volátil)

```bash
# Crear la interfaz macvlan en el host con el mismo padre eth0.
sudo ip link add lan-shim link eth0 type macvlan mode bridge

# Asignarle la IP reservada.
sudo ip addr add 192.168.1.240/32 dev lan-shim

# Subirla.
sudo ip link set lan-shim up

# Forzar que el tráfico al rango macvlan vaya por lan-shim, no por eth0.
sudo ip route add 192.168.1.240/28 dev lan-shim
```

A partir de aquí, desde el host:

```bash
ping -c 3 192.168.1.240   # la propia lan-shim, debe responder.
# Pi-hole y Unbound aún no existen: cuando se desplieguen, ping responderá.
```

Esta configuración **no sobrevive a un reboot**. Antes de continuar, validar que ha funcionado y luego persistirla.

### 5.2. Persistencia con `systemd`

Crear el servicio:

```bash
sudo tee /etc/systemd/system/lan-shim.service > /dev/null <<'EOF'
[Unit]
Description=macvlan shim for Docker lan_macvlan (host <-> macvlan containers)
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes

# Crear la interfaz si no existe (idempotente).
ExecStart=/bin/sh -c '/sbin/ip link show lan-shim >/dev/null 2>&1 || /sbin/ip link add lan-shim link eth0 type macvlan mode bridge'

# Asignar IP si todavía no la tiene (idempotente).
ExecStart=/bin/sh -c '/sbin/ip -4 addr show dev lan-shim | grep -q "192.168.1.240/32" || /sbin/ip addr add 192.168.1.240/32 dev lan-shim'

# Subir la interfaz.
ExecStart=/sbin/ip link set lan-shim up

# Ruta hacia el rango macvlan (idempotente).
ExecStart=/bin/sh -c '/sbin/ip route show 192.168.1.240/28 dev lan-shim | grep -q . || /sbin/ip route add 192.168.1.240/28 dev lan-shim'

# Bajada limpia (al hacer stop/disable).
ExecStop=/bin/sh -c '/sbin/ip route del 192.168.1.240/28 dev lan-shim 2>/dev/null || true'
ExecStop=/bin/sh -c '/sbin/ip link del lan-shim 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
```

Activar:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now lan-shim.service
sudo systemctl status lan-shim.service --no-pager
```

Estado esperado:

```
● lan-shim.service - macvlan shim for Docker lan_macvlan (host <-> macvlan containers)
     Loaded: loaded (/etc/systemd/system/lan-shim.service; enabled; preset: enabled)
     Active: active (exited) since ...
```

### 5.3. Por qué cada bloque del unit

| Bloque | Por qué |
|---|---|
| `After=network-online.target docker.service` + `Requires=docker.service` | El shim depende de que `eth0` esté arriba **y** de que Docker exista; si Docker se reinicia, `lan-shim` se mantiene (el padre `eth0` sigue ahí), pero al boot conviene esperar al demonio para que la red `lan_macvlan` ya esté creada cuando los stacks se levanten. |
| `Type=oneshot` + `RemainAfterExit=yes` | El servicio configura y termina; `RemainAfterExit=yes` mantiene el unit "active" para que `systemctl status` no diga `inactive (dead)` y para que dependientes (futuros) funcionen. |
| Cuatro `ExecStart` separados con guardas `|| /sbin/ip ...` | Cada paso es idempotente: relanzar el unit (p. ej. `systemctl restart lan-shim`) no duplica direcciones ni rutas. |
| `ExecStop` que borra ruta e interfaz | Permite `systemctl stop lan-shim` limpio y útil para mantenimiento. |
| Sin hardcodear MAC | El kernel asigna una MAC aleatoria a `lan-shim` en cada boot. Como `lan-shim` no recibe DHCP del router (le damos `192.168.1.240/32` estática), la MAC variable no es problema. |

### 5.4. Validar tras reboot

```bash
sudo reboot
# (esperar a que vuelva, reabrir SSH)

ip -br link show lan-shim
# lan-shim  UP  ye:xx:xx:xx:xx:xx <BROADCAST,MULTICAST,UP,LOWER_UP>

ip -br -4 addr show lan-shim
# lan-shim  UP  192.168.1.240/32

ip route show 192.168.1.240/28
# 192.168.1.240/28 dev lan-shim scope link

systemctl is-enabled lan-shim.service
# enabled
```

---

## 6. Coexistencia con `ufw`

`ufw`, configurado en [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md), filtra solo el tráfico que entra a **las interfaces y direcciones del host**. El tráfico que entra a una IP macvlan (por ejemplo, `192.168.1.241` para Pi-hole) **no atraviesa la pila del host**: el switch lo entrega directamente al contenedor, y la decisión de aceptar/rechazar se toma en la red Docker.

Consecuencias:

| Tráfico | ¿Pasa por `ufw`? | Quién lo controla |
|---|---|---|
| LAN → Pi (`192.168.1.10`, `eth0`) | **Sí** | Reglas `ufw` (SSH, futuros HTTP/HTTPS de Caddy). |
| LAN → Pi-hole (`192.168.1.241`, macvlan) | **No** | El propio Pi-hole + el switch/router. |
| Host → Pi-hole | **Sí** (sale por `lan-shim`) | El kernel del host; `ufw` no aplica reglas a tráfico saliente del propio host por defecto. |
| Container `homelab` → Pi-hole | **No directamente**: Pi-hole estará también en la red `homelab` (doble red) y los contenedores le hablan por su nombre DNS interno. La macvlan se reserva para que la **LAN** llegue a Pi-hole. |

Por tanto, este documento **no añade** reglas a `ufw`. La auditoría completa de puertos, incluyendo "Pi-hole `:53` en `192.168.1.241` no controlado por `ufw`", se documenta en [`../13-operaciones/04-red-y-puertos.md`](../13-operaciones/04-red-y-puertos.md).

> **Riesgo aceptado**: cualquier dispositivo de la LAN puede hacer DNS contra Pi-hole. En este homelab es **deseado** (la idea es justo que toda la LAN use Pi-hole como DNS). Si se quisiera limitar, habría que hacerlo en la configuración del propio Pi-hole (`DNSMASQ_LISTENING=local` u otras), no en el host.

---

## 7. Verificación

### 7.1. Comprobar la red Docker

```bash
docker network ls --filter name=lan_macvlan --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}'
# Esperado:
# NAME          DRIVER    SCOPE
# lan_macvlan   macvlan   local

docker network inspect lan_macvlan \
  --format 'subnet={{(index .IPAM.Config 0).Subnet}} | gateway={{(index .IPAM.Config 0).Gateway}} | range={{(index .IPAM.Config 0).IPRange}} | parent={{index .Options "parent"}} | mode={{index .Options "macvlan_mode"}}'
# Esperado:
# subnet=192.168.1.0/24 | gateway=192.168.1.1 | range=192.168.1.240/28 | parent=eth0 | mode=bridge

docker network inspect lan_macvlan \
  --format '{{range .IPAM.Config}}{{range .AuxiliaryAddresses}}{{.}}{{end}}{{end}}'
# Esperado: 192.168.1.240   (reserva de la lan-shim)
```

### 7.2. Comprobar la `lan-shim`

```bash
ip -br link show lan-shim          # UP, MAC distinta a la de eth0
ip -br -4 addr show lan-shim       # 192.168.1.240/32
ip route show 192.168.1.240/28     # dev lan-shim scope link
systemctl is-active lan-shim.service   # active
systemctl is-enabled lan-shim.service  # enabled
```

### 7.3. Smoke test con un contenedor desechable

Crear un contenedor temporal en `lan_macvlan`, comprobar que tiene IP de la LAN, que ve al gateway, que el host ve al contenedor (vía `lan-shim`) y que otro equipo de la LAN también lo ve.

```bash
# Lanzar el contenedor con IP estática del rango libre.
docker run -d --rm \
  --name macvlan-test \
  --network lan_macvlan \
  --ip 192.168.1.243 \
  alpine:3.20 \
  sh -c 'apk add --no-cache iputils >/dev/null && sleep 600'

# (1) El contenedor llega al gateway.
docker exec macvlan-test ping -c 2 192.168.1.1
# Esperado: 0% packet loss

# (2) El host llega al contenedor (esto es lo que arregla la lan-shim).
ping -c 2 192.168.1.243
# Esperado: 0% packet loss. Si falla, revisar §8.

# (3) Otro equipo de la LAN llega al contenedor.
#     Desde el portátil del operador:
#     ping -c 2 192.168.1.243   → 0% packet loss

# (4) ARP del contenedor anuncia la MAC esperada.
ip neigh show 192.168.1.243
# Esperado: 192.168.1.243 dev lan-shim lladdr 02:42:... REACHABLE

# Limpieza.
docker rm -f macvlan-test
```

### 7.4. Lista de Verificación

Antes de pasar a [`02-pihole.md`](./02-pihole.md):

- [ ] El router tiene **excluido el rango `192.168.1.240`–`192.168.1.255`** de su pool DHCP (verificable lanzando un dispositivo nuevo y comprobando que recibe una IP `< .240`).
- [ ] `eth0` está cableado y `UP` en `ip -br link show`.
- [ ] `docker network inspect lan_macvlan` muestra `subnet=192.168.1.0/24`, `gateway=192.168.1.1`, `range=192.168.1.240/28`, `parent=eth0`, `mode=bridge` y la `aux-address` `192.168.1.240`.
- [ ] `lan-shim` aparece en `ip -br link show` con estado `UP` y MAC distinta a la de `eth0`.
- [ ] `ip -br -4 addr show lan-shim` lee `192.168.1.240/32`.
- [ ] `ip route show 192.168.1.240/28` lee `dev lan-shim scope link`.
- [ ] `systemctl is-enabled lan-shim.service` devuelve `enabled` y `is-active` devuelve `active`.
- [ ] El smoke test §7.3 pasa los cuatro pings (host→gateway, contenedor→gateway, host→contenedor, LAN→contenedor) y se limpia el contenedor.
- [ ] Tras un `sudo reboot`, todo lo anterior sigue cierto **sin intervención manual**.
- [ ] Las reglas de `ufw` siguen siendo las mismas que tras [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md): este documento **no las modifica**.

---

## 8. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `docker network create` falla con `network dm-XXXX is already using parent host interface eth0` | Existe otra red macvlan con el mismo padre. Solo puede haber **una macvlan por padre** sin sub-interfaces VLAN. | `docker network ls --filter driver=macvlan` y eliminar la sobrante (o reutilizarla si encaja). |
| `docker network create` falla con `Pool overlaps with other one on this address space` | Otra red Docker (bridge) reclama `192.168.1.0/24`. Algún operador anterior creó un bridge con esa subred. | Localizarla: `docker network inspect $(docker network ls -q) \| grep -B5 192.168.1`. Si es vieja y no se usa, borrarla; si es legítima, replantear el rango macvlan. |
| Desde el host `ping 192.168.1.241` no responde y Pi-hole **sí** responde desde otro equipo de la LAN | La `lan-shim` no existe, no está `UP`, o falta la ruta. Es el síntoma más típico. | `systemctl status lan-shim.service`, `ip addr show lan-shim`, `ip route show 192.168.1.240/28`. Si la unidad falló: `journalctl -u lan-shim.service -b`. |
| Tras un reboot, `lan-shim` no aparece | El servicio no estaba `enabled`, o `eth0` no estaba `UP` cuando se ejecutó el `ExecStart`. | `systemctl enable lan-shim.service`, y en el unit confirmar `After=network-online.target` + `Wants=network-online.target` (no solo `network.target`). |
| Pi-hole y Unbound se ven entre sí pero **no** ven a la LAN | El `--gateway` de la macvlan no es la IP real del router. Compose ignoró `gateway` o la red existe con `gateway` antiguo. | `docker network inspect lan_macvlan` y comparar con `ip route show default` del host. Recrear la red si difiere. |
| Cualquier contenedor macvlan ve un `IP conflict` en logs | Otro dispositivo de la LAN ha tomado la misma IP (DHCP del router no está excluyendo `.240`–`.255`). | Verificar el panel del router (§3); reducir el pool DHCP si es necesario. |
| `lan-shim` aparece duplicada (`lan-shim`, `lan-shim2`) | El unit corrió dos veces sin guardas idempotentes (no debería con la versión de §5.2). | `sudo ip link del lan-shim2 2>/dev/null`; revisar el unit. |
| `ufw status` no muestra reglas para Pi-hole y se accede a `:53` desde la LAN | **Es lo esperado**: el tráfico macvlan no pasa por `ufw` (§6). | No actuar; documentado en [`../13-operaciones/04-red-y-puertos.md`](../13-operaciones/04-red-y-puertos.md). |
| Wifi era el único enlace y la macvlan no se levanta | El chip Wi-Fi de la Pi 5 no acepta MAC distinta de la radio: macvlan no funciona sobre `wlan0`. | Conectar la Pi al router por **cable Ethernet** (`eth0`). No hay alternativa razonable. |
| `docker exec macvlan-test ping 192.168.1.1` falla con `Destination Host Unreachable` | El switch o router del operador filtra MACs desconocidas (port security). Algunos routers ISP lo hacen. | Desactivar port security/MAC filtering en el panel del router; o reasignar las MACs para que pertenezcan al rango "aceptado". |
| Tras Docker upgrade, `docker compose up` (Pi-hole) falla con `network lan_macvlan declared as external, but could not be found` | Algún `prune` o reset de Docker borró la red. | Recrear con el comando de §4.2; reiniciar `lan-shim.service` por seguridad. |
| `journalctl -u lan-shim.service` lee `RTNETLINK answers: File exists` | La interfaz ya estaba creada cuando arrancó el unit (p. ej. tras un `daemon-reload` con `restart`). | Inocuo gracias a las guardas idempotentes; si molesta, reescribir la guarda con `ip link show lan-shim 2>/dev/null` previo. |
| `lan-shim` aparece pero la MAC cambia tras cada reboot y eso rompe alguna integración futura | El kernel asigna MAC aleatoria por defecto. | Fijarla en el unit añadiendo `ExecStart=/sbin/ip link set lan-shim address 02:42:c0:a8:01:f0` antes del `set up`. No es necesario en este homelab. |

---

## Referencias

- [Docker — Macvlan network driver](https://docs.docker.com/network/drivers/macvlan/)
- [Docker — `docker network create` (`-o parent`, `--ip-range`, `--aux-address`)](https://docs.docker.com/reference/cli/docker/network/create/)
- [Docker — Use IPv4 with `ipv4_address` in Compose](https://docs.docker.com/reference/compose-file/services/#ipv4_address)
- [Linux kernel — `ip link add ... type macvlan mode bridge`](https://man7.org/linux/man-pages/man8/ip-link.8.html)
- [systemd.service — `Type=oneshot`, `RemainAfterExit=`, `After=network-online.target`](https://www.freedesktop.org/software/systemd/man/systemd.service.html)
- [Raspberry Pi — Networking on Bookworm (NetworkManager defaults)](https://www.raspberrypi.com/documentation/computers/configuration.html#network-configuration)
- [Pi-hole — Why a Docker macvlan setup is recommended](https://docs.pi-hole.net/docker/) (referencia para [`02-pihole.md`](./02-pihole.md))
