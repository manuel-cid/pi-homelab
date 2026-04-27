# Red Docker `macvlan` para Pi-hole y Unbound

## Descripción

Creación de una **red Docker `macvlan`** que reparte IPs de la propia LAN doméstica a los contenedores que la usen. La motivación es práctica: **Pi-hole** necesita escuchar en los puertos `53/udp`, `53/tcp` y `80/tcp`, y la Pi tiene que poder usar Caddy (puerto 80/443) sobre su IP "normal". Si Pi-hole se montase en la red `bridge` del host con `network_mode: host` o con `ports: 53:53`, esos puertos se ocuparían en la Pi y no quedarían para Caddy ni se podrían liberar para futuros usos. Con `macvlan`, **Pi-hole obtiene su propia IP en la LAN** (p. ej. `192.168.1.2`), independiente de la del host (`192.168.1.3`), y deja la IP de la Pi limpia para el reverse proxy.

Como contrapartida, el _driver_ `macvlan` aísla a los contenedores del propio host: por diseño el _kernel_ no permite que `eth0` y un `macvlan` _child_ del mismo `eth0` se hablen entre sí. Para que la Pi pueda hacer `ping` o consultas DNS a su propia Pi-hole, hay que crear una **interfaz `macvlan-shim` adicional en el host** que actúe como puente unidireccional Pi → contenedores macvlan. Ese _shim_ se crea aquí, con persistencia vía `systemd`, y se aísla de NetworkManager para que no se borre al reiniciar.

Tras esta fase, el host queda con:

- una red Docker `lan` (driver `macvlan`, _parent_ `eth0`) creada y persistente,
- las IPs `192.168.1.2` (Pi-hole) y `192.168.1.4` (Unbound) reservadas en el DHCP del router para evitar colisiones,
- una interfaz `macvlan-shim` en el host con IP propia (`192.168.1.250`) y una ruta `/29` que la dirige a la subred macvlan, gestionada por una _unit_ `systemd` que sobrevive a reinicios.

`docs/03-red/02-pihole.md` y `docs/03-red/03-unbound.md` se limitarán a referenciar la red `lan` como `external: true` y a fijar `ipv4_address:` por servicio.

> **Alcance**: este documento sólo crea la **infraestructura de red** (red Docker macvlan + _shim_ en el host + reservas DHCP). **No** despliega Pi-hole ni Unbound (eso corresponde a `docs/03-red/02-pihole.md` y `docs/03-red/03-unbound.md`), **no** define el `Caddyfile` (`docs/03-red/04-caddy.md`) y **no** instala Tailscale (`docs/03-red/05-tailscale.md`).

> **Recordatorio de red**: el homelab está expuesto **solo a LAN y Tailscale**. La red `macvlan` añade más superficie en la propia LAN (un dispositivo extra: la IP de Pi-hole), pero **no** abre nada hacia internet. No se hace _port forwarding_ en el router. Pi-hole sólo será DNS/HTTP para clientes locales.

---

## Requisitos previos

- `docs/01-sistema/01-instalacion-os.md` completado: la Pi está en LAN con IP estable por reserva DHCP, NetworkManager gestiona `eth0`.
- `docs/01-sistema/03-seguridad-base.md` completado: `nftables` activo con `input drop` por defecto y la regla de aceptación de tráfico ya establecido (la cadena `ct state established,related accept`). El _shim_ no necesita reglas adicionales si esa regla existe.
- `docs/02-docker/01-instalacion-docker.md` completado: `docker network` operativo, `default-address-pools` fijado en `172.20.0.0/16` (no entra en conflicto con la LAN).
- `docs/02-docker/02-estructura-compose.md` completado: la red Docker `homelab` (bridge interno) ya creada. La red `lan` que se crea aquí es **adicional**, no la sustituye.
- Conocer la configuración de la LAN doméstica:
  - **Subnet**: la del router. Se asume `192.168.1.0/24` en este documento. Si la real es `192.168.0.0/24`, `10.0.0.0/24` u otra, sustituir en todos los comandos.
  - **Gateway**: la IP del router. Se asume `192.168.1.1`.
  - **IP del host (Pi)**: reservada por DHCP en `docs/00-hardware/02-esquema-conexiones.md`. Se asume `192.168.1.3`.
  - **Pool DHCP del router**: rango que el router reparte dinámicamente. Las IPs que se reserven aquí (`.2`, `.4`, `.250`) deben estar **fuera** de ese pool, o reservadas explícitamente por MAC, para que el router no se las dé a otro dispositivo.
- Confirmar el nombre real de la interfaz Ethernet:

  ```bash
  ip -br link show
  ```

  Raspberry Pi OS Lite suele llamarla `eth0`, pero en algunos kernels recientes aparece como `end0` (_predictable network interface names_). Todos los comandos de este documento usan `eth0`; si tu sistema reporta `end0`, sustitúyelo en todos los pasos.

- Acceso `sudo` en el host (creación de _interfaces_ y reglas de _firewall_).

---

## Conceptos: por qué `macvlan` y no `bridge`

### Comparación rápida

| Aspecto                        | Driver `bridge`                              | Driver `macvlan`                                |
|--------------------------------|----------------------------------------------|-------------------------------------------------|
| IP del contenedor              | Privada Docker (172.x.x.x)                   | **De la propia LAN** (192.168.x.x)              |
| Visibilidad en la LAN          | Sólo si se publica `ports: 53:53`            | Aparece como un dispositivo más, MAC propia     |
| Puertos del host               | Se ocupan al hacer `ports`                   | **No se tocan**                                 |
| Comunicación host ↔ contenedor | Directa (a través del bridge)                | **Bloqueada por _kernel_** (necesita _shim_)    |
| Comunicación entre contenedores macvlan | N/A                                  | Directa, en la propia LAN                       |
| Aislamiento del resto de stacks | Comparten bridge si no hay redes separadas  | Total: `macvlan` no se mezcla con `bridge`      |

Para Pi-hole, el `bridge` exigiría `ports: 53:53/udp 53:53/tcp 80:80`, ocupando el puerto 53 del host (chocaría con `systemd-resolved` si estuviese activo) y el 80 (lo necesita Caddy). `macvlan` resuelve los dos problemas con un coste razonable: hay que añadir el _shim_.

### Por qué se aíslan host y contenedor en `macvlan`

El _driver_ `macvlan` crea **interfaces hijas** del mismo dispositivo físico (`eth0`), cada una con su propia MAC. El _kernel_ Linux, por motivos de seguridad y para evitar bucles, **prohíbe el tráfico entre el padre (`eth0`) y sus hijos macvlan dentro del mismo host**. Es comportamiento documentado, no un fallo. Consecuencia práctica: la Pi puede pingear cualquier máquina de la LAN — incluido un router, un portátil, un móvil — **excepto a la Pi-hole que ella misma alberga**.

### El _shim_ de macvlan

La solución estándar es crear **otra interfaz hija de `eth0`** en el _host_, también de tipo `macvlan`, con su propia MAC y su propia IP en la misma LAN. Esa interfaz **sí puede hablar con las demás interfaces macvlan** (incluidas las de los contenedores), porque entre _hijas_ no hay restricción. Una ruta explícita en la tabla de _routing_ del host indica al _kernel_ que para llegar a `192.168.1.0/29` (la subred reservada a contenedores macvlan) use el _shim_ en lugar de `eth0`.

```
                          ┌─────────────────────────────────────┐
                          │ Raspberry Pi 5 (host)               │
                          │                                     │
                          │  eth0 (192.168.1.3)                 │
                          │  └── macvlan-shim (192.168.1.250)   │ ─── ruta a 192.168.1.0/29 ─┐
                          │      └── (mismo cable Ethernet)     │                            │
                          │                                     │                            │
                          │  Docker:                            │                            │
                          │  └── red 'lan' (driver macvlan)     │                            │
                          │      ├── pihole   (192.168.1.2) ◀───┼────────────────────────────┤
                          │      └── unbound  (192.168.1.4) ◀───┼────────────────────────────┘
                          └─────────────────────────────────────┘
                                     │
                                  switch/router (192.168.1.1)
```

Tras crear el _shim_ y la ruta, la Pi puede hacer `dig @192.168.1.2 example.com` o `curl http://192.168.1.2/admin/`. Sin _shim_, `dig` da _timeout_ y `curl` falla con `No route to host`.

---

## Diseño concreto

### Reservas de IP en la LAN

| IP            | Asignación              | Reserva DHCP por MAC               |
|---------------|-------------------------|------------------------------------|
| `192.168.1.1` | Router / gateway        | Configuración del router           |
| `192.168.1.2` | Pi-hole (macvlan)       | **Sí** — MAC del contenedor Pi-hole|
| `192.168.1.3` | Raspberry Pi (host)     | Reservada en `docs/00-hardware/02-esquema-conexiones.md` |
| `192.168.1.4` | Unbound (macvlan)       | **Sí** — MAC del contenedor Unbound|
| `192.168.1.250` | _shim_ del host (`macvlan-shim`) | **Sí** — MAC del _shim_ |

> **Las MACs de los contenedores y del _shim_ son fijas** (se definen en este documento y en los compose de Pi-hole/Unbound). Se reservan en el DHCP del router por MAC, no por IP, para que el router nunca asigne esas IPs a otro dispositivo aunque esté caído el contenedor.

MACs propuestas (rango _locally administered_ `02:xx:xx:xx:xx:xx`, distinguibles a simple vista):

| Dispositivo       | MAC                    |
|-------------------|------------------------|
| `macvlan-shim`    | `02:42:c0:a8:01:fa`    |
| Pi-hole           | `02:42:c0:a8:01:02`    |
| Unbound           | `02:42:c0:a8:01:04`    |

> Las MACs siguen el patrón `02:42:` (prefijo que Docker usa por defecto en sus interfaces) seguido de la IP en _hex_: `c0:a8:01:02` = `192.168.1.2`. Es nemotécnico y reduce errores al configurar reservas DHCP.

### Subred macvlan dentro de la LAN

| Concepto             | Valor                |
|----------------------|----------------------|
| Subnet (= LAN)       | `192.168.1.0/24`     |
| Gateway              | `192.168.1.1` (router) |
| _Parent_             | `eth0`               |
| _IP-range_ macvlan   | `192.168.1.0/29`     |
| _aux-addresses_      | `host=192.168.1.3`, `router=192.168.1.1` |

`--ip-range 192.168.1.0/29` cubre `192.168.1.0`–`192.168.1.7`. Docker, dentro de ese rango, evita asignar las _aux-addresses_, así que las IPs efectivamente disponibles para contenedores son `.2`, `.4`, `.5`, `.6` (cuatro). Suficiente para Pi-hole + Unbound y dos huecos de futuro. Si se necesita más, se amplía a `192.168.1.0/28` (`.0`–`.15`) y se reservan los huecos correspondientes en el DHCP del router.

> **El _shim_ (`192.168.1.250`) está fuera del `--ip-range`** a propósito: lo usa el host, no Docker. Docker no tiene visibilidad de él. Pero **sigue dentro del `192.168.1.0/24`** para compartir _broadcast domain_ con las interfaces hijas.

---

## 1. Reservar las IPs en el router

Antes de crear nada en la Pi, abrir la administración del router (típicamente `http://192.168.1.1`) y añadir tres reservas DHCP por MAC:

| MAC                 | IP            | _Hostname_ sugerido |
|---------------------|---------------|---------------------|
| `02:42:c0:a8:01:fa` | `192.168.1.250` | `pi-shim`         |
| `02:42:c0:a8:01:02` | `192.168.1.2` | `pihole`            |
| `02:42:c0:a8:01:04` | `192.168.1.4` | `unbound`           |

El nombre exacto de la opción varía por fabricante: "DHCP Reservation", "Static IP", "Address Reservation"... El objetivo común es: **el router nunca debe asignar estas IPs a otra MAC aunque la MAC reservada no esté presente en ese momento.**

Confirmar después con `arp` desde la Pi (estará vacío hasta que arranquen los contenedores, pero al menos verifica que no hay otro dispositivo respondiendo):

```bash
arping -c 2 -I eth0 192.168.1.2
arping -c 2 -I eth0 192.168.1.4
arping -c 2 -I eth0 192.168.1.250
```

Las tres deben dar `Timeout` o `0 packets received`. Si alguna responde, otro dispositivo tiene la IP — corregir antes de continuar.

---

## 2. Crear la red Docker `lan`

```bash
docker network create \
    --driver macvlan \
    --subnet 192.168.1.0/24 \
    --gateway 192.168.1.1 \
    --ip-range 192.168.1.0/29 \
    --aux-address "host=192.168.1.3" \
    --aux-address "router=192.168.1.1" \
    --opt parent=eth0 \
    lan
```

Detalles:

- **`--driver macvlan`**: distinto del `bridge` que usan `homelab` y las redes internas de cada stack.
- **`--subnet 192.168.1.0/24`**: tiene que coincidir con la subred real de la LAN. Docker usa este dato para no enrutar paquetes con destino externo a través de esta red.
- **`--gateway 192.168.1.1`**: el contenedor usará al router como _default route_, igual que cualquier dispositivo de la LAN.
- **`--ip-range 192.168.1.0/29`**: limita el _pool_ de Docker a la "esquina baja" de la LAN, fuera del DHCP del router. Pi-hole y Unbound recibirán IPs de aquí.
- **`--aux-address`**: marca como reservadas (no asignables por Docker) la del propio host y la del _gateway_. Esto evita un _bug_ molesto: que en una segunda creación Docker te asigne `.3` a Pi-hole y rompa la conectividad con el host.
- **`--opt parent=eth0`**: sobre qué interfaz física se monta el _macvlan_. Si tu sistema reporta `end0`, ajusta aquí.

> **`--ip-range` no es _strict_**. Si en el futuro se añade un cuarto contenedor a `lan` y los huecos `.2/.4/.5/.6` están todos llenos, Docker fallará con `Address pool exhausted`. La señal de que hace falta ampliar a `/28`. **No** usar IPs estáticas fuera del `--ip-range` (Docker no las acepta sobre macvlan en modo `bridge`).

Verificar:

```bash
docker network inspect lan --format '{{.Driver}} parent={{(index .Options "parent")}} subnet={{(index .IPAM.Config 0).Subnet}} gateway={{(index .IPAM.Config 0).Gateway}}'
```

Debe imprimir:

```
macvlan parent=eth0 subnet=192.168.1.0/24 gateway=192.168.1.1
```

---

## 3. Probar la red con un contenedor efímero

Antes de crear el _shim_, comprobar que un contenedor en `lan` arranca, recibe IP y sale a internet:

```bash
docker run --rm --network lan --ip 192.168.1.6 alpine sh -c \
    "ip -4 addr show eth0 && ip route && ping -c 2 192.168.1.1 && ping -c 2 1.1.1.1"
```

- `ip -4 addr` debe mostrar `inet 192.168.1.6/24 ... eth0`.
- `ping 192.168.1.1` (router) debe responder.
- `ping 1.1.1.1` debe responder (el contenedor sale a internet por el _gateway_, igual que el resto de la LAN).
- `ping 192.168.1.3` (la propia Pi) **fallará con `100% packet loss`** — esto es lo esperado, y el siguiente paso lo arregla.

Otros dispositivos de la LAN (un portátil, el móvil) pueden hacer `ping 192.168.1.6` mientras este contenedor de prueba esté corriendo: la red macvlan es transparente.

---

## 4. Crear el _shim_ en el host

### 4.1 Script de creación idempotente

Se centraliza en un único script para que el _service_ de `systemd` lo ejecute al arrancar y lo deshaga al parar. El script es **idempotente**: si la interfaz ya existe, salta a la siguiente línea sin error.

```bash
sudo install -d -m 0755 /usr/local/sbin
sudo tee /usr/local/sbin/macvlan-shim-up >/dev/null <<'EOF'
#!/bin/bash
# Crea la interfaz macvlan-shim sobre eth0 y enruta la subred macvlan a través de ella.
# Idempotente: pensado para ejecutarse desde systemd en cada arranque.

set -euo pipefail

PARENT="${PARENT:-eth0}"
SHIM="${SHIM:-macvlan-shim}"
SHIM_IP="${SHIM_IP:-192.168.1.250/32}"
SHIM_MAC="${SHIM_MAC:-02:42:c0:a8:01:fa}"
ROUTE="${ROUTE:-192.168.1.0/29}"

if ! ip link show "$PARENT" >/dev/null 2>&1; then
    echo "macvlan-shim: $PARENT no existe — abortando" >&2
    exit 1
fi

if ! ip link show "$SHIM" >/dev/null 2>&1; then
    ip link add "$SHIM" link "$PARENT" address "$SHIM_MAC" type macvlan mode bridge
fi

ip link set "$SHIM" up
ip addr replace "$SHIM_IP" dev "$SHIM"
ip route replace "$ROUTE" dev "$SHIM"

echo "macvlan-shim: $SHIM ($SHIM_IP) → $ROUTE OK"
EOF
sudo chmod 0755 /usr/local/sbin/macvlan-shim-up
```

Y el script de _down_ (lo invoca `systemd` al parar el servicio):

```bash
sudo tee /usr/local/sbin/macvlan-shim-down >/dev/null <<'EOF'
#!/bin/bash
# Deshace la interfaz creada por macvlan-shim-up. Idempotente.

set -euo pipefail

SHIM="${SHIM:-macvlan-shim}"
ROUTE="${ROUTE:-192.168.1.0/29}"

ip route del "$ROUTE" dev "$SHIM" 2>/dev/null || true
if ip link show "$SHIM" >/dev/null 2>&1; then
    ip link del "$SHIM"
fi
EOF
sudo chmod 0755 /usr/local/sbin/macvlan-shim-down
```

### 4.2 Aislar el _shim_ de NetworkManager

Raspberry Pi OS Lite gestiona `eth0` con NetworkManager (`docs/01-sistema/01-instalacion-os.md`). Por defecto, NM intenta gestionar **toda** interfaz nueva que aparezca, incluida la `macvlan-shim`: pediría DHCP por ella, generaría una ruta duplicada y entraría en conflicto con la ruta `/29` que se acaba de añadir. Marcarla como _no gestionada_:

```bash
sudo install -d -m 0755 /etc/NetworkManager/conf.d
sudo tee /etc/NetworkManager/conf.d/99-macvlan-shim.conf >/dev/null <<'EOF'
[keyfile]
unmanaged-devices=interface-name:macvlan-shim
EOF
sudo systemctl reload NetworkManager
```

Verificar:

```bash
nmcli device status | grep -E 'eth0|macvlan-shim'
```

`eth0` debe seguir como `connected`. Tras crear el _shim_ (siguiente paso), `macvlan-shim` debe aparecer como `unmanaged` (no como `connecting` o `disconnected`).

### 4.3 _Service_ de `systemd` para persistencia

```bash
sudo tee /etc/systemd/system/macvlan-shim.service >/dev/null <<'EOF'
[Unit]
Description=macvlan shim for Docker macvlan network 'lan'
Documentation=file:///home/homelab/homelab/docs/03-red/01-macvlan.md
After=network-online.target NetworkManager.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/macvlan-shim-up
ExecStop=/usr/local/sbin/macvlan-shim-down

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now macvlan-shim.service
```

Detalles:

- **`Type=oneshot` + `RemainAfterExit=yes`**: el script termina (no es un proceso de larga vida), pero `systemd` considera el servicio "activo" mientras la interfaz exista, lo que permite usar `systemctl status` y encadenar `After=` desde otros servicios si hace falta.
- **`After=network-online.target`**: garantiza que `eth0` ya tiene IP cuando se añade el _shim_. Sin esto, en _boot_ frío el _shim_ a veces se crea contra un `eth0` aún sin _link_, y la ruta no funciona hasta el primer `systemctl restart` manual.
- **`After=NetworkManager.service`**: para que NM ya haya leído el `99-macvlan-shim.conf` antes de que aparezca el _shim_; si no, NM puede cogerla durante una fracción de segundo.
- **`Documentation=`**: enlace a este propio documento dentro del repositorio del homelab. Útil al hacer `systemctl status macvlan-shim`.

### 4.4 Verificar el _shim_

```bash
ip -br addr show macvlan-shim
ip route show 192.168.1.0/29
nmcli device status | grep macvlan-shim
sudo systemctl status macvlan-shim --no-pager
```

Resultado esperado:

```
macvlan-shim     UP             192.168.1.250/32
192.168.1.0/29 dev macvlan-shim scope link
macvlan-shim   macvlan      unmanaged   --
● macvlan-shim.service - macvlan shim for Docker macvlan network 'lan'
     Loaded: loaded (/etc/systemd/system/macvlan-shim.service; enabled; ...)
     Active: active (exited) since ...
```

---

## 5. Probar la conectividad host ↔ macvlan

Repetir la prueba del paso 3, esta vez confirmando que **la Pi puede hablar con el contenedor**:

```bash
# En una terminal: levantar un alpine en macvlan
docker run --rm --network lan --ip 192.168.1.6 alpine sh -c \
    "ip -4 addr show eth0 && sleep 300"
```

```bash
# En otra terminal de la misma Pi:
ping -c 3 192.168.1.6                # debe responder ahora
ip route get 192.168.1.6              # debe decir 'dev macvlan-shim src 192.168.1.250'
```

`ip route get` confirma que el _kernel_ usa el _shim_ (no `eth0`) para llegar al contenedor. Si imprime `dev eth0`, la ruta `/29` no se aplicó: revisar `ip route show` y `systemctl status macvlan-shim`.

Cerrar el alpine de prueba con `Ctrl+C`.

---

## 6. Convivencia con `nftables`

El _firewall_ del host (`docs/01-sistema/03-seguridad-base.md`) está con política `input drop` por defecto y permite tráfico ya establecido. Con esa configuración:

- **Pi → contenedor macvlan**: la Pi inicia la conexión, _conntrack_ marca la sesión como _new_ y luego _established_; el contenedor responde y la respuesta entra al host como _established_, que la regla `ct state established,related accept` permite. **Funciona sin tocar nada.**
- **Contenedor macvlan → Pi**: si Pi-hole quisiera abrir conexiones contra un servicio del propio host (no es el caso esperado), entrarían como _new_ desde la IP `192.168.1.2` por el _shim_, y se _droppean_ por la política por defecto. Es **el comportamiento que queremos**: el host no expone servicios al contenedor macvlan.
- **Otros dispositivos de la LAN → contenedor macvlan**: el tráfico **no atraviesa el host**. Va directamente del switch al contenedor a nivel de capa 2. `nftables` del host no lo ve y no lo filtra. Las protecciones de Pi-hole (firewall propio del contenedor, _DNSSEC_, listas) son las únicas que aplican aquí.

> **Resumen**: no hace falta añadir reglas `nftables` específicas para macvlan. Las que ya hay en `/etc/nftables.conf` siguen siendo correctas.

Si en algún momento se quiere **bloquear** explícitamente el tráfico desde la subred macvlan hacia el host (por defensa en profundidad), añadir en la cadena `input` de la tabla `inet filter`:

```nft
ip saddr 192.168.1.0/29 iifname "macvlan-shim" drop
```

(No se aplica por defecto: la política `input drop` y la ausencia de servicios escuchando en el host ya cumplen ese rol.)

---

## 7. Cómo lo usan los compose siguientes

`docs/03-red/02-pihole.md` y `docs/03-red/03-unbound.md` referenciarán la red `lan` como **externa**, fijando IP y MAC por servicio. Patrón:

```yaml
services:
  pihole:
    image: pihole/pihole:2024.07
    mac_address: "02:42:c0:a8:01:02"
    networks:
      lan:
        ipv4_address: 192.168.1.2
    # ...

  unbound:
    image: mvance/unbound:latest
    mac_address: "02:42:c0:a8:01:04"
    networks:
      lan:
        ipv4_address: 192.168.1.4
    # ...

networks:
  lan:
    external: true        # creada en docs/03-red/01-macvlan.md, no recrear aquí
```

> **`mac_address` explícito** en el compose: imprescindible. Si se omite, Docker genera una MAC aleatoria distinta en cada `up`, las reservas DHCP del router dejan de aplicar y se acaba con dos clientes pidiendo la misma IP. Las reservas del paso 1 sólo funcionan si la MAC se mantiene fija.

---

## Verificación final

Antes de pasar a `docs/03-red/02-pihole.md`, comprobar:

- [ ] `docker network ls --filter driver=macvlan --format '{{.Name}} {{.Driver}}'` lista exactamente `lan macvlan`.
- [ ] `docker network inspect lan --format '{{(index .Options "parent")}} {{(index .IPAM.Config 0).Subnet}}'` devuelve `eth0 192.168.1.0/24`.
- [ ] `ip -br addr show macvlan-shim` muestra la interfaz `UP` con `192.168.1.250/32`.
- [ ] `ip route show 192.168.1.0/29` muestra `192.168.1.0/29 dev macvlan-shim scope link`.
- [ ] `systemctl is-enabled macvlan-shim.service` devuelve `enabled`.
- [ ] `systemctl is-active macvlan-shim.service` devuelve `active`.
- [ ] `nmcli device status | grep macvlan-shim` muestra `unmanaged`.
- [ ] Reinicio de la Pi (`sudo reboot`); tras el reinicio, los _checks_ anteriores siguen pasando sin intervención manual.
- [ ] `arping -c 2 -I eth0 192.168.1.2`, `arping ... 192.168.1.4` y `arping ... 192.168.1.250` no responden todavía (Pi-hole y Unbound aún no desplegados; el _shim_ tiene MAC pero `arping` por su propia interfaz se filtra y no contesta a sí mismo). Sí responden tras desplegar Pi-hole/Unbound.
- [ ] Prueba viva con un alpine efímero:

  ```bash
  docker run --rm --network lan --ip 192.168.1.6 alpine ping -c 2 192.168.1.1 \
    && ping -c 2 192.168.1.6
  ```

  La primera línea (`alpine`) debe responder al router; la segunda (desde el host) debe responder al contenedor.

---

## Troubleshooting

### `docker network create` falla con `network with name lan already exists`

Ya existe (probablemente de un intento anterior). Inspeccionar y, si la configuración es correcta, no recrear:

```bash
docker network inspect lan
```

Si la subnet, gateway, parent o ip-range no coinciden con los esperados, borrarla y volver a crearla:

```bash
docker network rm lan && docker network create --driver macvlan ... lan
```

`docker network rm` falla si hay algún contenedor enganchado. Listar y desconectar primero:

```bash
docker network inspect lan --format '{{range .Containers}}{{.Name}} {{end}}'
```

### `docker network create` falla con `Pool overlaps with other one on this address space`

Otra red Docker (probablemente un `bridge` por defecto) está usando un rango que solapa con `192.168.1.0/24`. Listar:

```bash
docker network ls
docker network inspect $(docker network ls -q --filter driver=bridge) --format '{{.Name}} {{(index .IPAM.Config 0).Subnet}}'
```

Si hay alguna red con subnet `192.168.x.x`, suele ser un `default-address-pools` mal configurado. Verificar `/etc/docker/daemon.json` (`docs/02-docker/01-instalacion-docker.md`) y comprobar que el _pool_ es `172.20.0.0/16`. Borrar las redes solapadas y reintentar.

### El contenedor en `lan` no obtiene IP / no llega al router

Síntomas: `ip addr show eth0` dentro del contenedor muestra IP, pero `ping 192.168.1.1` da _timeout_.

Causas habituales:

1. **`parent` incorrecto**: `eth0` es el nombre asumido. En kernels recientes la interfaz puede llamarse `end0`. Confirmar:

   ```bash
   ip -br link show
   ```

   Si la interfaz Ethernet es `end0`, recrear la red con `--opt parent=end0`.

2. **Modo promiscuo no soportado**: `macvlan` requiere que el _parent_ acepte tramas con MACs distintas. Algunos _switches_ gestionables o el propio _hypervisor_ (si la Pi corriese virtualizada) lo bloquean. La Pi 5 sobre Ethernet doméstica no es el caso, pero conviene confirmar con `ip link show eth0 | grep -i promisc`.

3. **WiFi como _parent_**: el _driver_ `macvlan` **no funciona sobre WiFi** (la mayoría de _drivers_ wireless no soportan MAC adicional). Si `eth0` está caído y el sistema está en _fallback_ por WiFi, `macvlan` falla en silencio. Confirmar que `eth0` es la interfaz activa.

### `ping` desde el host al contenedor `lan` falla aunque el _shim_ existe

```bash
ip route get 192.168.1.2
```

Si el resultado es `dev eth0` (no `dev macvlan-shim`), la ruta `/29` no está activa o tiene métrica peor. Forzarla:

```bash
sudo systemctl restart macvlan-shim
ip route show 192.168.1.0/29
```

Si la ruta no aparece, revisar `journalctl -u macvlan-shim --no-pager` para ver el error del script.

### Tras un reinicio, el _shim_ aparece pero NetworkManager le ha asignado una IP DHCP extra

```bash
ip -br addr show macvlan-shim
```

Si muestra dos IPs (la `192.168.1.250/32` y otra `/24` con _gateway_), NM se la ha cogido pese al `unmanaged-devices`. Revisar:

```bash
cat /etc/NetworkManager/conf.d/99-macvlan-shim.conf
sudo nmcli connection show
```

A veces NM mantiene una conexión _autoconnect_ persistente para la interfaz. Borrarla:

```bash
sudo nmcli connection delete macvlan-shim   # o el nombre que aparezca
sudo systemctl reload NetworkManager
sudo systemctl restart macvlan-shim
```

### Otros dispositivos de la LAN no ven al contenedor

Los _switches_ aprenden MACs por puerto. Si justo antes había otro dispositivo con la misma MAC en otro puerto, la tabla CAM tarda en refrescarse (típicamente 30 s – 5 min). Forzar tráfico saliente desde el contenedor:

```bash
docker exec pihole ping -c 5 192.168.1.1
```

Y comprobar desde otro equipo de la LAN:

```bash
arp -a | grep 192.168.1.2
```

### `docker compose up` de Pi-hole falla con `network lan declared as external, but could not be found`

El sistema arrancó pero la red `lan` se borró (un `docker network prune` quizá). Recrearla con el comando del paso 2. **No** dejar que Compose la cree implícitamente: el _driver_ `macvlan` requiere parámetros que Compose no infiere.

### `arping -I eth0 192.168.1.250` no responde aunque el _shim_ está arriba

El _kernel_ filtra `arping` enviado a la propia interfaz por la que escucha; es comportamiento conocido. Para confirmar que el _shim_ está funcional, hacer la prueba desde **otro dispositivo** de la LAN (móvil, portátil) o usar `ip neigh show` en la propia Pi.

### Tras un `docker network rm lan && docker network create ... lan`, los contenedores con `mac_address` siguen sin IP

`docker network rm` no purga las reservas internas de Docker en `/var/lib/docker/network/files/`. Si la nueva red conserva el mismo nombre pero distinta MAC mapping, los contenedores cacheados pueden fallar. Recrear los contenedores afectados (`docker compose down && docker compose up -d` desde su _stack_).

---

## Referencias

- Docker — _Macvlan network driver_: <https://docs.docker.com/network/drivers/macvlan/>
- Docker — `docker network create`: <https://docs.docker.com/reference/cli/docker/network/create/>
- Docker — Compose `mac_address` y `networks.<name>.ipv4_address`: <https://docs.docker.com/reference/compose-file/services/#mac_address>
- Linux kernel — _macvlan_ driver: <https://www.kernel.org/doc/html/latest/networking/device_drivers/ethernet/index.html>
- NetworkManager — `unmanaged-devices`: <https://networkmanager.dev/docs/api/latest/NetworkManager.conf.html#device-spec>
- `systemd.service` — `Type=oneshot`, `RemainAfterExit`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html>
- Pi-hole — Despliegue en Docker con macvlan (referencia oficial): <https://docs.pi-hole.net/docker/>
- _Locally administered MAC addresses_ (rango `02:xx:...`): <https://en.wikipedia.org/wiki/MAC_address#Universal_vs._local_(U/L_bit)>
