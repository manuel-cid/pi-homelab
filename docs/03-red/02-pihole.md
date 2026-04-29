# Pi-hole

## Descripción

Cerrado `01-macvlan.md`, la Pi tiene una **red Docker macvlan** (`dns_lan`, `192.168.1.0/24` con `--ip-range 192.168.1.0/29`), una **interfaz `macvlan-shim`** persistente para que el host hable con sus contenedores macvlan, y una **reserva en el router** que mantiene libres las IPs `192.168.1.2`–`192.168.1.7`. La pista de aterrizaje está pintada; falta el avión.

Este documento despliega **Pi-hole** como **servidor DNS de toda la LAN**, con IP propia (`192.168.1.2`) sobre la red `dns_lan`. Pi-hole hace cuatro trabajos en este homelab:

1. **Resolución DNS para todos los dispositivos de la LAN** (móviles, TV, portátiles, otros contenedores). Sustituye al DNS del operador / router.
2. **Bloqueo de publicidad y telemetría** a nivel de red mediante listas de dominios. Una vez en marcha, cualquier dispositivo que use Pi-hole como DNS hereda el filtrado sin necesidad de ajustes propios.
3. **DNS local para los servicios del homelab**: `jellyfin.lan`, `nextcloud.lan`, `portainer.lan`, etc. resuelven a la IP donde Caddy hará reverse proxy (la IP de la Pi, `192.168.1.10`). Caddy llega en `04-caddy.md`; Pi-hole prepara los nombres ahora.
4. **Punto único de DNS interno**, lo que más adelante permitirá a `tailscale serve`/MagicDNS y a Caddy compartir el mismo espacio de nombres `*.lan` sin reabrir decisiones.

Lo que este documento **no** decide:

- **Resolución recursiva propia** (cómo resuelve Pi-hole los dominios *públicos* que no están en su caché). En esta primera vuelta Pi-hole apunta a un **resolver público** (Cloudflare/Quad9). En `03-unbound.md` se sustituye ese upstream por **Unbound** corriendo en la propia `dns_lan` con IP `192.168.1.3`. La transición se hace cambiando una variable, sin tocar listas ni clientes.
- **Reverse proxy HTTPS** sobre la UI de Pi-hole (`https://pihole.lan/`). Esto lo cubre `04-caddy.md`. Aquí la UI se accede vía `http://192.168.1.2/admin/` (HTTP, en LAN, sin cifrado: aceptable porque es la única forma que tiene la Pi y los demás equipos de configurar Pi-hole **antes** de que exista Caddy, y la LAN ya es la frontera de confianza del homelab).

Cuando este documento se haya aplicado, `docker ps` lista un contenedor `pihole` saludable con MAC e IP propias en la LAN, todos los dispositivos del hogar resuelven contra `192.168.1.2`, los dominios `*.lan` definidos por el operador resuelven a la IP de la Pi, y el host **sigue resolviendo** aunque Pi-hole se caiga (gracias al fallback en `/etc/resolv.conf`). A partir de aquí la Fase 3 se ramifica: `03-unbound.md` añade el resolver recursivo, `04-caddy.md` el reverse proxy.

> **Recordatorio de alcance**: el homelab sigue siendo solo **LAN + Tailscale**. Pi-hole atiende DNS **dentro** de la LAN (puerto 53 en `192.168.1.2`) y a clientes Tailscale (vía MagicDNS, ver `05-tailscale.md`). **No** se publica nada hacia internet, **no** se abre `:53` en el router. El servidor DNS público del operador queda como simple fallback de `eth0`/host, no como servicio expuesto.

---

## Requisitos Previos

- `docs/03-red/01-macvlan.md` aplicado:
  - Red Docker `dns_lan` creada (driver `macvlan`, `parent=eth0`, `--subnet 192.168.1.0/24`, `--ip-range 192.168.1.0/29`, `--aux-address host=192.168.1.9`).
  - Unidad `macvlan-shim.service` activa y habilitada; `ip route show 192.168.1.2` apunta a `dev macvlan-shim`.
  - `.env` global incluye `LAN_SUBNET`, `LAN_GATEWAY`, `LAN_PARENT_IF`, `LAN_MACVLAN_RANGE`, `LAN_MACVLAN_SHIM_IP`, `PIHOLE_IP=192.168.1.2`, `UNBOUND_IP=192.168.1.3`.
  - Reserva en el router doméstico: pool DHCP empieza en `192.168.1.50`, `.2`–`.9` libres para asignación manual.
- Fase 2 completa:
  - Red Docker `homelab` creada (`172.30.10.0/24`).
  - Layout `stacks/<svc>/`, `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN`.
- Árbol de datos en `hd2t` (Fase 1, `04-estructura-directorios.md`):
  - `/mnt/hd2t/apps/pihole/etc/` y `/mnt/hd2t/apps/pihole/dnsmasq.d/` existirán (los crea este documento).
- Nada está escuchando ya en `192.168.1.2:53` ni `192.168.1.2:80` (es la IP virgen reservada).
- Comprobación rápida antes de empezar:

  ```bash
  cd /home/homelab/homelab

  # Red dns_lan creada
  docker network inspect dns_lan --format '{{.Driver}} {{.Options.parent}}'
  # macvlan eth0

  # Shim activa y con ruta /32 a 192.168.1.2
  ip -br -4 addr show macvlan-shim
  # macvlan-shim     UNKNOWN        192.168.1.9/32
  ip route show 192.168.1.2
  # 192.168.1.2 dev macvlan-shim scope link

  # IP libre (nadie responde aún)
  ping -c 2 -W 1 192.168.1.2 || true
  # 100% packet loss (correcto)

  # Variables presentes
  grep -E '^(PIHOLE_IP|UNBOUND_IP|DOMAIN_LAN|LAN_IP|TZ)=' .env
  ```

  Si `192.168.1.2` ya **responde** a `ping`, hay un dispositivo en la LAN ocupando la IP: identificarlo (tabla DHCP del router, `arp -a`, `ip neigh`) y reasignarlo antes de continuar.

---

## Decisión: imagen y versión

Solo hay una imagen oficial mantenida activamente: **`pihole/pihole`** del proyecto Pi-hole (no confundir con forks no oficiales que aparecen en Docker Hub). Es multi-arch (`amd64`, `arm64`, `arm/v7`); para la Pi 5 (aarch64) se usa el manifest `arm64`.

| Tag | Cuándo usar | Decisión aquí |
|---|---|---|
| `latest` | Demos, pruebas. Cambia sin avisar. | Descartado: rompe la convención de "tag fijado en `mayor.menor.parche`". |
| `2024.07.0` (ejemplo) | Estable, fijado a versión concreta. | **Aceptado**. El tag exacto se anota abajo y se actualiza a través de Watchtower (Fase 2.4) o de un commit explícito en este repo. |
| `dev` / `nightly` | Desarrolladores upstream. | Descartado. |

> **Tag exacto en uso**: `pihole/pihole:2024.07.0`. Si en el momento de aplicar este documento existe una versión más reciente *estable*, se actualiza el tag aquí y en el `docker-compose.yml`, y se anota en el commit. **Nunca `latest`**.

---

## Decisión: cómo se expone Pi-hole

Pi-hole publica **dos** servicios:

| Servicio | Puerto | A quién atiende |
|---|---|---|
| DNS | `53/tcp` y `53/udp` | Todos los dispositivos de la LAN, otros contenedores (vía `dns_lan` o `homelab`), clientes Tailscale (vía `05-tailscale.md`). |
| UI de administración | `80/tcp` | Operador del homelab. Acceso esporádico, solo para añadir listas, ver estadísticas, etc. |

La decisión se reduce a **dónde** los publica:

| Opción | Cómo se ve | Discusión |
|---|---|---|
| **Bridge `homelab` + `ports: ["53:53/udp", "53:53/tcp", "80:80"]`** | Todo en la IP de la Pi (`192.168.1.10`). | Choca con Caddy (`:80`) y enmascara las IPs reales de los clientes (NAT de Docker). Argumentado y descartado en `01-macvlan.md`. |
| **Macvlan `dns_lan` con IP dedicada (`192.168.1.2`)** | DNS y UI escuchan directamente en `192.168.1.2:53` y `192.168.1.2:80`. La IP de la Pi sigue libre. Pi-hole ve **IPs reales** de los clientes. | Es la decisión central de Fase 3. **Aceptado.** |
| **Macvlan + bridge `homelab` simultáneamente** | Como la anterior, pero además Pi-hole se conecta a la red `homelab` para que Caddy pueda alcanzarlo internamente (en Fase 3.4) sin pasar por la `macvlan-shim`. | Sin sobrecoste: Compose lo soporta nativamente. Es lo que el patrón ya prefiguraba en `01-macvlan.md`. **Aceptado** como matiz: doble red. |

Resultado:

```text
                         LAN 192.168.1.0/24
   +------------+         (macvlan, eth0)         +-----------------+
   |  Móvil     |  -->  192.168.1.2:53/udp,tcp -->|                 |
   |  TV        |  -->  192.168.1.2:80          |   pihole         |
   |  Portátil  |       (red dns_lan, IP propia)|   (container)    |
   +------------+                                |                 |
                                                 |   homelab net   |
                  Caddy (Fase 3.4) -------------->   172.30.10.x   |
                  (en red homelab, mismo host)   |   pihole.homelab|
                                                 +-----------------+
```

Notas:

- **`network_mode: host`** queda descartado por las razones de `01-macvlan.md` (rompe aislamiento y ocupa puertos del host).
- **`cap_add: NET_ADMIN`** sí se concede a Pi-hole porque su contenedor manipula reglas internas (la de `unbound-anchor`-like en versiones recientes y el lighttpd interno que ata `:80`). Es un permiso clásico para esta imagen y está documentado upstream. El contenedor sigue corriendo como usuario no-root en su mayor parte (`s6-overlay`); `NET_ADMIN` afecta solo a su propio namespace de red, no al del host.
- **MAC fija** (`mac_address:` en Compose). Por defecto Docker genera una MAC aleatoria en cada `up -d --force-recreate`. Si el router lleva tabla por MAC (firewall por dispositivo, o reservas DHCP por trazabilidad), el cambio de MAC en cada recreación rompe esa contabilidad. Se fija una MAC estable en el rango "locally administered" (`02:42:c0:a8:01:02` codifica `192.168.1.2`, mnemotecnia útil sin mayor compromiso).

---

## Decisión: upstream DNS provisional

Pi-hole, al recibir una consulta para un dominio que **no** está en su caché ni en sus listas, la reenvía a un **upstream**. Las opciones:

| Upstream | Pros | Contras |
|---|---|---|
| **Resolver público** (Cloudflare `1.1.1.1`, Quad9 `9.9.9.9`) | Inmediato, sin más infraestructura. Bajo perfil de fallos. | Todas las consultas DNS del hogar acaban viéndose desde un único proveedor externo. Punto único de privacidad. |
| **Unbound local recursivo** | El homelab resuelve **por sí mismo** desde los root servers; nada se filtra a un solo proveedor. | Requiere desplegar Unbound. Un servicio más en `dns_lan`. |
| **Router del operador** (`192.168.1.1`) | Conocido. | Reintroduce dependencia del operador del router (que a su vez delega en el ISP). |

Resultado:

- En **este** documento, Pi-hole arranca con **Cloudflare 1.1.1.1 + Quad9 9.9.9.9** como upstream provisional (dos resolvers, redundancia, ambos con DNS estándar UDP/TCP en `:53`).
- En `03-unbound.md`, el upstream se cambia a `192.168.1.3#53` (Unbound). La transición se hace **modificando solo la variable `PIHOLE_DNS_`** en el `.env` del stack y reiniciando Pi-hole, sin tocar la configuración de los clientes.
- DNS-over-HTTPS / DNS-over-TLS hacia upstreams externos queda **fuera de alcance**: Unbound recursivo lo hace innecesario para el destino final del homelab.

---

## Decisión: dónde van las definiciones de DNS local (`*.lan`)

Pi-hole ofrece **dos** sitios para fijar `nombre → IP` interno:

1. **UI → "Local DNS Records"**: pares hostname/IP gestionados desde la web. Pi-hole los persiste en `/etc/pihole/custom.list`.
2. **Ficheros de `dnsmasq` montados en `/etc/dnsmasq.d/`**: cada uno es un `host=` o `address=/dominio/IP`. Permite `address=/lan/192.168.1.10` (toda *.lan resuelve a la Pi de un golpe).

Este homelab elige **(2)** como fuente declarativa y, para nombres puntuales que no caen bajo el comodín, complementa con (1):

| Caso | Mecanismo | Por qué |
|---|---|---|
| Comodín `*.${DOMAIN_LAN}` → `${LAN_IP}` (todos los servicios pasan por Caddy en la IP de la Pi) | `address=/${DOMAIN_LAN}/${LAN_IP}` en `/etc/dnsmasq.d/02-homelab-local.conf` | Una línea cubre `jellyfin.lan`, `nextcloud.lan`, `portainer.lan`, etc. Cuando Caddy añade un servicio nuevo, **no hay que tocar Pi-hole**. |
| Excepciones puntuales que **no** pasan por Caddy (ej. la propia Pi-hole en `pihole.${DOMAIN_LAN}` apuntando a `${PIHOLE_IP}` en lugar de a `${LAN_IP}`) | UI → Local DNS Records, persistido en `custom.list` | Casos excepcionales, pocos, fáciles de auditar desde la UI. |
| Resolución inversa (PTR) `192.168.1.x → host.lan` | No se configura aquí | El homelab no tiene actualmente clientes que pidan PTR; si llega Authelia/Logging que dependan de PTR, se reabre. |

`DOMAIN_LAN` se fija como `lan` por defecto (decisión heredada de Fase 2). Si el operador prefiere `home`, `home.arpa`, `internal` u otra terminación, lo cambia en el `.env` global; este documento usa `lan` en los ejemplos.

> **Por qué `lan` y no `home.arpa`**: el RFC 8375 reserva `home.arpa` para uso doméstico interno. Es técnicamente más limpio y se usaría si este homelab pretendiese interoperar con otros que respeten el RFC. Para single-host, sin DNS-SD multi-vendor, `lan` es suficiente y más corto al escribir. Reabrible.

---

## Stack: `stacks/pihole/`

### `stacks/pihole/docker-compose.yml`

```yaml
# Pi-hole — servidor DNS de la LAN del homelab.
# Convenciones: ver docs/02-docker/02-estructura-compose.md y docs/03-red/01-macvlan.md.

name: pihole

services:
  pihole:
    image: pihole/pihole:2024.07.0
    container_name: pihole
    hostname: pihole
    restart: unless-stopped

    # Pi-hole modifica reglas/rutas internas (lighttpd, FTL DNS, etc.).
    # NET_ADMIN afecta solo a su namespace de red.
    cap_add:
      - NET_ADMIN

    environment:
      TZ: ${TZ}

      # Contraseña inicial de la UI. Si está vacía, Pi-hole genera una
      # aleatoria y la imprime en logs (`docker logs pihole`).
      WEBPASSWORD: ${PIHOLE_WEBPASSWORD}

      # IP propia que Pi-hole anuncia en su UI/respuestas DHCP. Coincide con
      # la IP fija de su interfaz en dns_lan.
      FTLCONF_LOCAL_IPV4: ${PIHOLE_IP}

      # Upstream DNS provisional (resolvers públicos). En 03-unbound.md
      # se sustituye por ${UNBOUND_IP}#53.
      PIHOLE_DNS_: "1.1.1.1;9.9.9.9"

      # No se levanta el servidor DHCP de Pi-hole: el router del operador
      # sigue siendo el DHCP del hogar.
      DHCP_ACTIVE: "false"

      # Listas adicionales (más allá de StevenBlack por defecto). Se
      # aplican en primer arranque; cambios posteriores se gestionan
      # desde la UI.
      DNSMASQ_LISTENING: "all"

      # Clientes que se ven con su IP real (no con la del bridge),
      # ya garantizado por estar en macvlan, pero se documenta.
      VIRTUAL_HOST: pihole.${DOMAIN_LAN}

    networks:
      dns_lan:
        ipv4_address: ${PIHOLE_IP}        # 192.168.1.2
      homelab: {}                         # Caddy alcanza pihole por DNS interno (Fase 3.4)

    # MAC estable: facilita el seguimiento del dispositivo en el router
    # y evita re-emisiones ARP innecesarias en cada recreación.
    mac_address: 02:42:c0:a8:01:02

    # No se declaran ports: macvlan publica directamente en LAN.
    # Pi-hole escucha:
    #   - 53/udp y 53/tcp en 192.168.1.2 (DNS)
    #   - 80/tcp en 192.168.1.2 (UI lighttpd)

    volumes:
      - /mnt/hd2t/apps/pihole/etc:/etc/pihole
      - /mnt/hd2t/apps/pihole/dnsmasq.d:/etc/dnsmasq.d

    healthcheck:
      # `dig @127.0.0.1 pi.hole +norecurse +retry=0` es la prueba canónica:
      # contesta solo si FTL (el daemon DNS de Pi-hole) está activo.
      test: ["CMD-SHELL", "dig +norecurse +retry=0 @127.0.0.1 pi.hole >/dev/null"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s

    labels:
      homelab.role: "dns"
      homelab.backup: "true"
      # Watchtower opt-in: Pi-hole se actualiza automáticamente.
      # Cambiar a "false" si se quiere fijar versión manual.
      com.centurylinklabs.watchtower.enable: "true"

networks:
  dns_lan:
    external: true
  homelab:
    external: true
```

### `stacks/pihole/.env.example`

```bash
# stacks/pihole/.env.example
# Variables específicas del stack Pi-hole.
# Las generales (TZ, DOMAIN_LAN, PIHOLE_IP, UNBOUND_IP, LAN_IP) viven en el
# .env GLOBAL del homelab y este compose las consume desde ahí.

# Contraseña inicial del usuario admin de la UI.
# Generar con: openssl rand -base64 24
# Si se deja vacía, Pi-hole imprime una aleatoria en `docker logs pihole`.
PIHOLE_WEBPASSWORD=cambia-esto-por-una-contrasena-fuerte
```

El `.env` real (`stacks/pihole/.env`, **no** versionado) se crea con permisos `0600`:

```bash
cd /home/homelab/homelab/stacks/pihole
cp .env.example .env
sed -i "s|cambia-esto-.*|$(openssl rand -base64 24)|" .env
chmod 0600 .env
```

> Anotar la contraseña generada en el gestor de contraseñas del operador. Pi-hole también permite resetearla desde el contenedor (`docker exec -it pihole pihole -a -p`).

### Crear los directorios persistentes y desplegar

```bash
# Directorios de datos (idempotente)
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/pihole
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/pihole/etc
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/pihole/dnsmasq.d

# Verificar las dos redes externas
docker network inspect dns_lan  >/dev/null
docker network inspect homelab  >/dev/null

# Cargar variables globales en el shell (ver quirk Compose v2 en 02-estructura-compose.md)
cd /home/homelab/homelab
set -a; source .env; set +a

# Validar el compose con interpolación
docker compose \
    -f stacks/pihole/docker-compose.yml \
    --env-file stacks/pihole/.env \
    config >/dev/null && echo "compose OK"

# Levantar
docker compose \
    -f stacks/pihole/docker-compose.yml \
    --env-file stacks/pihole/.env \
    up -d
```

Tras `up -d`:

```bash
docker ps --filter name=pihole
# CONTAINER ID  IMAGE                       STATUS                  PORTS  NAMES
# ...           pihole/pihole:2024.07.0     Up 60 seconds (healthy)        pihole

docker compose -f stacks/pihole/docker-compose.yml logs --tail 40
# ...
# [✓] DNS service is listening
# [✓] FTL is listening on port 53
# [✓] Pi-hole blocking is enabled
```

`STATUS` debe pasar a `(healthy)` en ~90 s. Si se queda `(starting)` más allá del `start_period`, casi siempre es un permiso en `/mnt/hd2t/apps/pihole/etc`: el contenedor escribe ahí como UID interno (`pihole`, 999). Que el directorio sea `homelab:homelab 0750` no debería molestar (el contenedor escribe como root durante el bootstrap), pero si la imagen se ejecuta sin `cap_add NET_ADMIN`, FTL no levantará.

---

## Configuración

### 1) Primera conexión a la UI

Desde un equipo cualquiera de la LAN:

```
http://192.168.1.2/admin/
```

Login con la contraseña de `PIHOLE_WEBPASSWORD`. La UI **no** ofrece HTTPS por sí misma; en LAN se acepta como temporal hasta que `04-caddy.md` la sirva en `https://pihole.lan/`.

> **Desde la propia Pi**: `curl http://192.168.1.2/admin/` funciona porque la `macvlan-shim` (`192.168.1.9`) tiene la ruta `/32` hacia `192.168.1.2`. Si no respondiese, repasar `01-macvlan.md` (sección "La trampa de macvlan").

### 2) Listas de bloqueo

Pi-hole ya viene con la lista por defecto del proyecto (`StevenBlack`). Para un homelab el siguiente paso suele ser añadir un par de listas conservadoras adicionales. Recomendadas como punto de partida:

| Lista | URL (raw) | Foco |
|---|---|---|
| **StevenBlack — Unified hosts** (ya activa por defecto) | `https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts` | Publicidad y malware. |
| **OISD Big** | `https://big.oisd.nl/` | Anti-publicidad y telemetría, agresiva pero curada. |
| **AdGuard DNS filter** | `https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt` | Telemetría adicional sobre apps móviles. |
| **Hagezi — Pro** (opcional) | `https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/pro.txt` | Equilibrio entre cobertura y falsos positivos. |

Cómo añadirlas:

```
UI → Group Management → Adlists
    Address: https://big.oisd.nl/
    Comment: oisd-big
    Add
    (idem para las demás)

UI → Tools → Update Gravity → Update
```

> **Sobre listas más agresivas** (Energized Ultimate, Hagezi Ultimate, etc.): bloquean tantos dominios que rompen apps comunes (banca, mensajería, IPTV). En este homelab se mantienen **descartadas por defecto** y se reabren caso a caso si el operador las quiere.

#### Whitelisting reactivo

Cuando un servicio legítimo deje de funcionar, la pista está en:

```
UI → Query Log → filtrar por cliente
```

Identificar el dominio bloqueado y añadirlo a la whitelist:

```
UI → Domain Management → Whitelist → exact / regex
```

Documentar las excepciones recurrentes en `docs/13-operaciones/` cuando aparezca esa fase.

### 3) DNS local para servicios del homelab (`*.lan`)

Se crea **un fichero versionado** en `/etc/dnsmasq.d/` (montado vía bind):

```bash
# /mnt/hd2t/apps/pihole/dnsmasq.d/02-homelab-local.conf
# Comodín: todo *.lan apunta a la IP de la Pi (donde Caddy hará reverse proxy).
address=/lan/192.168.1.10

# Excepción: la propia UI de Pi-hole resuelve a la IP de Pi-hole, no a la
# de Caddy (porque hasta Fase 3.4 no existe el reverse proxy).
address=/pihole.lan/192.168.1.2

# Excepción: Unbound (Fase 3.3) tendrá su propia entrada para diagnóstico.
# Se prepara la línea (comentada) para activar en 03-unbound.md.
# address=/unbound.lan/192.168.1.3
```

Crear el fichero como **homelab** y recargar Pi-hole:

```bash
sudo install -o homelab -g homelab -m 0644 /dev/stdin \
    /mnt/hd2t/apps/pihole/dnsmasq.d/02-homelab-local.conf <<'EOF'
address=/lan/192.168.1.10
address=/pihole.lan/192.168.1.2
EOF

docker exec pihole pihole restartdns
# [✓] Restarting DNS server
```

Verificar:

```bash
# Desde otro equipo de la LAN:
dig @192.168.1.2 jellyfin.lan +short
# 192.168.1.10
dig @192.168.1.2 nextcloud.lan +short
# 192.168.1.10
dig @192.168.1.2 pihole.lan +short
# 192.168.1.2
```

> **Por qué un fichero y no la UI**: si se añaden los hosts vía "Local DNS Records", quedan en `/etc/pihole/custom.list` (también respaldado), pero la UI **no** soporta comodines (`*.lan`). El fichero `02-homelab-local.conf` permite el comodín, vive en bind mount, se respalda con el resto, y se versiona como **plantilla** en `stacks/pihole/dnsmasq.d/02-homelab-local.conf.example` para que un reflasheo lo recupere.

### 4) Configurar el router para que reparta `192.168.1.2` como DNS

Hasta ahora todos los dispositivos del hogar siguen recibiendo el DNS del operador vía DHCP del router. Para que **toda la LAN** use Pi-hole sin tocar dispositivo a dispositivo, se cambia **un único campo** en la admin del router:

```
Router → DHCP / LAN settings → Primary DNS:    192.168.1.2
                              → Secondary DNS:  (vaciar) o 192.168.1.1
```

Notas críticas:

- **No** poner como secundario un DNS público (`1.1.1.1`, `8.8.8.8`). Si se pone, los dispositivos lo usarán "a veces" (cuando Pi-hole tarde milisegundos de más) y verán los anuncios sin filtrar de manera intermitente. La regla es **un solo DNS o ninguno**: o Pi-hole, o nada.
- **Sí** se puede poner como secundario `192.168.1.1` (la propia gateway, que a su vez resuelve por upstream del operador) **solo** si el operador acepta el comportamiento "si Pi-hole se cae, salimos sin filtro". En este homelab se prefiere **dejarlo vacío** y aceptar que la caída de Pi-hole se note (es deseable: visibilidad sobre el problema). El "fallback" lo gestiona el host Pi a nivel de `/etc/resolv.conf` (siguiente sección), no la LAN entera.
- Si el router **no permite** vaciar el DNS secundario, el menos malo es repetir `192.168.1.2` en ambos campos.
- Tras el cambio, los dispositivos de la LAN tomarán el nuevo DNS al **renovar el lease DHCP**: minutos a horas. Para forzarlo: desactivar/reactivar Wi-Fi en cada dispositivo, o reiniciar el router.

Verificación desde un equipo cualquiera tras renovar el lease:

```bash
# macOS / Linux
scutil --dns | grep 'nameserver\[0\]' | head -1     # macOS
resolvectl status                                    # Linux con systemd-resolved
# Esperado: 192.168.1.2 como nameserver activo

# Comprobación rápida
dig +short example.com @192.168.1.2
# Una IP. Si falla: Pi-hole no está atendiendo (revisar `docker logs pihole`).

# Comprobación de bloqueo
dig +short doubleclick.net @192.168.1.2
# 0.0.0.0  (o NXDOMAIN, según política)
```

### 5) Configurar el host Pi para usar Pi-hole con fallback

El host (la propia Pi) **debe** seguir resolviendo aunque Pi-hole se caiga. Si no, `apt update`, `docker pull`, `tailscale up`, etc., se rompen en cuanto el contenedor de Pi-hole hace `restart`. La estrategia: **`/etc/resolv.conf` con dos nameservers**, primero Pi-hole y después un público.

#### En Raspberry Pi OS Bookworm con NetworkManager (caso por defecto en imágenes recientes)

```bash
# El conexión de Ethernet se llama típicamente "Wired connection 1".
# Comprobarlo:
nmcli con show

# Forzar DNS estáticos (Pi-hole + fallback público) para esa conexión:
sudo nmcli con mod "Wired connection 1" \
    ipv4.ignore-auto-dns yes \
    ipv4.dns "192.168.1.2 1.1.1.1"

sudo nmcli con up "Wired connection 1"
```

`ipv4.ignore-auto-dns yes` evita que el router (que ahora reparte `192.168.1.2` también para el host) sobrescriba el fallback. La Pi se queda con el orden **fijo**: Pi-hole primero, Cloudflare segundo.

#### En sistemas con `dhcpcd` (Bullseye o anterior)

```bash
echo "interface eth0
static domain_name_servers=192.168.1.2 1.1.1.1" | sudo tee -a /etc/dhcpcd.conf
sudo systemctl restart dhcpcd
```

#### En sistemas con `systemd-resolved`

Si la Pi usa `systemd-resolved` (no es por defecto en Raspberry Pi OS, pero algunas imágenes derivadas sí), la fuente de verdad es `/etc/systemd/resolved.conf`:

```ini
# /etc/systemd/resolved.conf
[Resolve]
DNS=192.168.1.2
FallbackDNS=1.1.1.1 9.9.9.9
DNSStubListener=yes
```

Tras editarlo: `sudo systemctl restart systemd-resolved`.

#### Verificación del fallback

```bash
# Pi-hole responde
dig @192.168.1.2 example.com +short
# (una IP)

# El host la usa por defecto
dig example.com +short
# (la misma IP que arriba)

# Simular caída de Pi-hole
docker compose -f /home/homelab/homelab/stacks/pihole/docker-compose.yml stop

dig example.com +short
# (una IP, ahora vía 1.1.1.1: el sistema cae al segundo nameserver)
# NetworkManager / glibc resolver tarda unos segundos en marcar el primero
# como no respondiente; aceptable.

docker compose -f /home/homelab/homelab/stacks/pihole/docker-compose.yml up -d
```

> **Por qué fallback solo para el host Pi y no para toda la LAN**: si se pone fallback a nivel de router, los dispositivos del hogar usan el fallback **silenciosamente** y los anuncios se cuelan sin que nadie se entere. Pero si la **Pi** no resuelve, todo el homelab se rompe (Docker no descarga imágenes, Borgmatic no resuelve el repo remoto, etc.). El fallback se aplica donde el coste de no tenerlo es mayor (la propia Pi) y se omite donde el coste de tenerlo es mayor (el resto de la LAN).

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/pihole/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/pihole/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla versionada (sin secretos). |
| `/home/homelab/homelab/stacks/pihole/.env` | microSD | `homelab:homelab` | `0600` | `PIHOLE_WEBPASSWORD`. **No** versionado. |
| `/home/homelab/homelab/stacks/pihole/dnsmasq.d/02-homelab-local.conf.example` | microSD | `homelab:homelab` | `0644` | Plantilla del fichero de DNS local. **Sí** versionada. |
| `/mnt/hd2t/apps/pihole/etc/` | hd2t | UID/GID interno (root del contenedor durante bootstrap, `pihole` UID 999 en runtime) | `0750` (lo gestiona el contenedor) | `pihole-FTL.db` (estadísticas), `gravity.db` (listas compiladas), `setupVars.conf`, `custom.list`, `pihole.toml`. |
| `/mnt/hd2t/apps/pihole/dnsmasq.d/` | hd2t | `homelab:homelab` (la plantilla) y luego mezclado con ficheros del contenedor | `0750` | `01-pihole.conf` (autogenerado por Pi-hole, **no editar a mano**), `02-homelab-local.conf` (gestionado por el operador). |

> **`pihole-FTL.db` puede crecer**: Pi-hole guarda 7 días de logs detallados por defecto. Para una LAN con ~30 dispositivos, esto pesa ~50–200 MB. Ajustable en `UI → Settings → Privacy → DB`.

---

## Backup

A nivel del repositorio del homelab:

| Artefacto | Estrategia |
|---|---|
| `stacks/pihole/docker-compose.yml`, `.env.example`, `dnsmasq.d/02-homelab-local.conf.example` | Versionados en git. Reproducibles tras un reflasheo. |
| `stacks/pihole/.env` | **No** versionado (contiene secreto). Respaldado por Borg como parte de `/home/homelab/homelab/`. |
| Decisiones (upstream provisional, listas, política de DNS local) | Documentadas en este fichero. Reproducibles en el primer arranque tras un reflasheo. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Por qué |
|---|---|---|
| `/mnt/hd2t/apps/pihole/etc/` | **Sí**, `homelab.backup=true`. | Contiene listas personalizadas (`custom.list`), whitelist/blacklist propias, configuración (`setupVars.conf`/`pihole.toml`), `gravity.db` (listas compiladas) e histórico de queries. Recreable, pero respaldarlo evita reconfigurar desde cero. |
| `/mnt/hd2t/apps/pihole/dnsmasq.d/` | **Sí**. | Contiene el fichero `02-homelab-local.conf` editado y los autogenerados por Pi-hole. Pequeño y crítico. |
| `pihole-FTL.db` (parte de `etc/`) | **Sí**, indirectamente. | Histórico de queries. Si se prefiere ahorrar espacio, excluir esta ruta concreta en Borgmatic; se regenera sola. |

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/pihole/docker-compose.yml up -d --force-recreate
# Pi-hole reusa /mnt/hd2t/apps/pihole/etc; UI mantiene admin, listas, etc.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear sistema base (Fase 1), Docker (Fase 2.1), convenciones (Fase 2.2), red `homelab` y red `dns_lan` (`01-macvlan.md`).
2. Restaurar `/mnt/hd2t/apps/pihole/{etc,dnsmasq.d}/` desde Borg.
3. `docker compose -f stacks/pihole/docker-compose.yml up -d`.
4. Verificar `dig @192.168.1.2 example.com +short`.

Si lo que se quiere es **resetear** Pi-hole (olvidar contraseña, listas, etc.):

```bash
docker compose -f stacks/pihole/docker-compose.yml down
sudo rm -rf /mnt/hd2t/apps/pihole/etc/*
docker compose -f stacks/pihole/docker-compose.yml up -d
```

`/etc/dnsmasq.d/02-homelab-local.conf` se conserva (vive en otro bind). El nuevo Pi-hole vuelve a generar `01-pihole.conf` y aplica el comodín `*.lan` desde el primer arranque.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `Error response from daemon: Address already in use` o el contenedor entra en `restarting` con `bind: address already in use` | Otro contenedor o un proceso del host ya escucha en `:53` o `:80` (típicamente un `systemd-resolved` activo en el host con `DNSStubListener=yes`, que **sí** ata `:53` aunque sea en `127.0.0.53`). | Como Pi-hole vive en macvlan con IP propia, **no** debería colisionar con `127.0.0.53`. Si aun así da el error, comprobar `docker network inspect dns_lan` (interfaz padre correcta) y `ss -tnlp` en el host. Si hay otro pi-hole/dnsmasq antiguo, parar antes. |
| Otros dispositivos resuelven contra Pi-hole, pero la **propia Pi** falla con `connection timed out; no servers could be reached` | La `macvlan-shim` no está activa o no tiene la ruta `/32` a `192.168.1.2`. | `systemctl status macvlan-shim`; `ip route show 192.168.1.2`. Re-ejecutar `scripts/21-macvlan-shim.sh`. Detallado en `01-macvlan.md`. |
| Pi-hole responde, pero **siempre** ve a todos los clientes como `192.168.1.10` (la IP de la Pi) | Pi-hole se levantó en la red `homelab` (bridge) en vez de `dns_lan` (macvlan), o lo está alcanzando solo por la shim del host. | `docker network inspect dns_lan --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'` debe listar `pihole 192.168.1.2/24`. Si no, recrear con `up -d --force-recreate`. |
| `STATUS=unhealthy` y los logs dicen `Could not bind socket: Address not available` | El contenedor intenta atar `${PIHOLE_IP}` pero `dns_lan` está mal configurada o la IP no entra en el `--ip-range`. | Revisar `01-macvlan.md`: `--ip-range` debe contener `${PIHOLE_IP}` (`192.168.1.2 ∈ 192.168.1.0/29`). |
| La UI carga en blanco o pide la contraseña tras cada acción | El navegador no acepta cookies del dominio IP (algunos móviles), o el secreto `WEBPASSWORD` ha cambiado entre arranques. | Acceder vía `http://pihole.lan/admin/` (resuelve si la LAN ya usa Pi-hole). Resetear con `docker exec -it pihole pihole -a -p`. |
| Las listas no actualizan: `Update Gravity → Failed` | Pi-hole no consigue resolver los dominios de las listas. Suele ser un bucle: `1.1.1.1` está en `PIHOLE_DNS_` pero no es alcanzable desde el contenedor. | `docker exec pihole nslookup 1.1.1.1` y `curl -sS https://big.oisd.nl/ -o /dev/null -w '%{http_code}\n'`. Si `curl` falla, problema de red de salida (ver `dns_lan` con gateway correcta). |
| Tras cambiar el DNS del router, varios dispositivos siguen sin filtrar publicidad | No han renovado el lease DHCP. | Reiniciar Wi-Fi en cada dispositivo o reiniciar el router. Confirmar con `scutil --dns` (mac) o `resolvectl` (Linux). |
| Algunas apps móviles rompen tras instalar Pi-hole (mensajería, banca) | Lista demasiado agresiva. | Identificar el dominio en `Query Log`, añadirlo a la whitelist de Pi-hole, o desactivar la lista que lo bloqueaba. |
| El host Pi pierde DNS al hacer `restart` de Pi-hole | `/etc/resolv.conf` apunta solo a `192.168.1.2`, sin fallback. | Aplicar el paso 5 ("Configurar el host Pi para usar Pi-hole con fallback"). |
| `dig @192.168.1.2 jellyfin.lan` resuelve, pero el navegador de un cliente de la LAN dice "host not found" | El cliente está usando otro DNS (típicamente DoH en el navegador: Firefox usa Cloudflare DoH por defecto). | Desactivar DoH en el navegador (`Settings → Privacy & Security → DNS over HTTPS → Off`) o configurar DoH para que use el resolver del sistema. Reabrible: `04-caddy.md` puede servir DoH propio si interesa. |
| Estadísticas vacías o `total queries: 0` al cabo de horas | Los clientes no están apuntando a Pi-hole (siguen con el DNS antiguo). | `Query Log` vacío confirma. Repasar el cambio en el router y la renovación de DHCP. |
| `pihole-FTL.db` corrupta tras un apagado abrupto | El SQLite no cerró limpio. | `docker exec pihole pihole flush; docker compose restart`. Si persiste, mover el fichero a un lado y dejar que Pi-hole lo regenere (se pierde el histórico, **no** la configuración). |
| Tras un reboot, Pi-hole arranca pero `dns_lan` no aparece | La red Docker macvlan se perdió (raro: vive en `data-root`, persistente). | Re-ejecutar `bash scripts/20-create-macvlan-network.sh`; `docker compose up -d --force-recreate`. |
| `pihole.lan` resuelve a la IP de Caddy/Pi (`192.168.1.10`) en vez de `192.168.1.2` | El comodín `address=/lan/192.168.1.10` matchea **antes** que la entrada específica. dnsmasq aplica la regla más específica si está bien escrita: `address=/pihole.lan/192.168.1.2` debe ir **después** del comodín en el mismo o distinto fichero, dnsmasq ya prioriza la coincidencia exacta del FQDN. | Verificar el fichero `02-homelab-local.conf` y `docker exec pihole pihole restartdns`. Si persiste, mover la línea específica a un fichero `01-` que se cargue antes. |

---

## Decisiones que **no** se toman en este documento

- **Resolver recursivo (Unbound)**: vive en `03-unbound.md`. Aquí Pi-hole apunta a `1.1.1.1;9.9.9.9` como upstream provisional.
- **Reverse proxy de Pi-hole con HTTPS** (`https://pihole.lan/`): vive en `04-caddy.md`. Aquí la UI se accede vía HTTP en `192.168.1.2`. Cuando Caddy esté listo, este documento se revisa para mover `pihole.lan` del comodín a una entrada específica que apunte a Caddy y para ocultar el `:80` directo si el operador quiere.
- **Acceso a Pi-hole desde Tailscale**: vive en `05-tailscale.md`. MagicDNS puede declarar `192.168.1.2` como DNS del tailnet (sólo para los nodos del operador), o no, según la decisión que se tome allí.
- **DHCP de la LAN**: lo sigue gestionando el router del operador. `DHCP_ACTIVE=false` en este compose. Si en algún momento se quiere mover el DHCP a Pi-hole (por ejemplo para que los hostnames aparezcan automáticamente en el `Query Log`), se reabre.
- **DNS-over-HTTPS / DNS-over-TLS hacia upstreams**: irrelevante mientras Pi-hole apunte a Unbound (`03-unbound.md`). Si en algún momento se vuelve a un upstream público sin Unbound, se evalúa configurar `cloudflared` como proxy DoH local.
- **IPv6**: la red `dns_lan` es IPv4 only (decisión de `01-macvlan.md`). Pi-hole soporta IPv6 nativo, pero no se habilita. Reabrible.
- **Listas regex avanzadas y categorías por cliente** (Group Management): el homelab arranca con un único grupo "default" y listas globales. Si se quiere "TV de los niños sin Twitter, móvil del operador sin filtros", se hace en operación normal, no aquí.
- **Métricas Prometheus de Pi-hole**: Pi-hole expone `/admin/api.php?summaryRaw` y existe `pihole-exporter` para Prometheus. Se integra en Fase 6 (monitorización), no aquí.

---

## Verificación Final

Antes de pasar a `03-unbound.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/pihole/docker-compose.yml ps` | `pihole  ...  Up (healthy)` |
| Imagen correcta y fija | `docker inspect pihole --format '{{.Config.Image}}'` | `pihole/pihole:2024.07.0` |
| Conectado a `dns_lan` con IP correcta | `docker network inspect dns_lan --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'` | `pihole 192.168.1.2/24` |
| Conectado también a `homelab` | `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` | incluye `pihole` |
| MAC fija | `docker inspect pihole --format '{{range .NetworkSettings.Networks}}{{.MacAddress}} {{end}}'` | incluye `02:42:c0:a8:01:02` |
| DNS responde a otros equipos de la LAN | desde otro host: `dig @192.168.1.2 example.com +short` | una IP |
| DNS responde a la propia Pi (vía shim) | en la Pi: `dig @192.168.1.2 example.com +short` | una IP |
| Bloqueo activo | `dig @192.168.1.2 doubleclick.net +short` | `0.0.0.0` o vacío con `NXDOMAIN` |
| DNS local `*.lan` vía comodín | `dig @192.168.1.2 jellyfin.lan +short; dig @192.168.1.2 nextcloud.lan +short` | `192.168.1.10` (en ambos) |
| Excepción `pihole.lan` específica | `dig @192.168.1.2 pihole.lan +short` | `192.168.1.2` |
| Pi-hole ve **IP real** del cliente, no la del bridge | UI → Query Log → filtrar por una consulta hecha desde un móvil | la fila muestra la IP del móvil (p.ej. `192.168.1.123`), **no** `172.30.10.1` |
| UI accesible | `curl -fsS http://192.168.1.2/admin/ -o /dev/null -w '%{http_code}\n'` | `200` o `302` |
| El router reparte `192.168.1.2` como DNS | en otro equipo tras renovar DHCP: `resolvectl status` (Linux) o `scutil --dns` (mac) | nameserver activo `192.168.1.2` |
| El host Pi tiene fallback configurado | `cat /etc/resolv.conf` o `nmcli dev show eth0 \| grep IP4.DNS` | dos entradas: `192.168.1.2` y un público |
| Resolución del host sigue tras parar Pi-hole | `docker compose -f stacks/pihole/docker-compose.yml stop && dig example.com +short && docker compose -f stacks/pihole/docker-compose.yml up -d` | la `dig` intermedia devuelve una IP (vía fallback) |
| Persistencia tras reboot | `sudo reboot`; tras reconectar: `docker ps --filter name=pihole` | `Up ... (healthy)` sin acción manual |
| Datos persistidos en hd2t, no en microSD | `du -sh /var/lib/docker/containers/$(docker inspect -f '{{.Id}}' pihole) 2>/dev/null` | reportado bajo `/mnt/hd2t/docker/...` |
| Stack en git (sin secretos) | `git status; git diff --cached --stat` | `stacks/pihole/docker-compose.yml`, `.env.example`, `dnsmasq.d/02-homelab-local.conf.example` tracked; `stacks/pihole/.env` ignorado |

Cumplido el último punto, la Pi resuelve toda la LAN, bloquea publicidad, y pinta el espacio de nombres `*.lan` que Caddy empezará a poblar en `04-caddy.md`. La siguiente puerta es **dejar de depender de resolvers públicos como upstream**: `03-unbound.md` añade un recursor local en `dns_lan` con IP `192.168.1.3` y reescribe `PIHOLE_DNS_` en una sola línea.

---

## Referencias

- [Documento anterior: `docs/03-red/01-macvlan.md`](./01-macvlan.md)
- [Documento siguiente: `docs/03-red/03-unbound.md`](./03-unbound.md)
- [Documento relacionado: `docs/02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)
- [Documento relacionado: `docs/02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)
- [Pi-hole — Documentación oficial](https://docs.pi-hole.net/)
- [Pi-hole — Imagen Docker (`pihole/pihole`) en Docker Hub](https://hub.docker.com/r/pihole/pihole)
- [Pi-hole — Repositorio Docker upstream (variables de entorno)](https://github.com/pi-hole/docker-pi-hole#environment-variables)
- [Pi-hole — `dnsmasq` configuration files](https://docs.pi-hole.net/ftldns/dhcp-static-leases/)
- [`dnsmasq(8)` — `address=` syntax](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html)
- [StevenBlack — Unified hosts](https://github.com/StevenBlack/hosts)
- [OISD — DNS blocklists](https://oisd.nl/)
- [Hagezi — DNS blocklists](https://github.com/hagezi/dns-blocklists)
- [Cloudflare DNS (`1.1.1.1`)](https://1.1.1.1/) · [Quad9 (`9.9.9.9`)](https://quad9.net/)
- [RFC 8375 — Special-Use Domain `home.arpa`](https://www.rfc-editor.org/rfc/rfc8375)
