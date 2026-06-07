# Red Docker Macvlan para DNS en LAN

## Descripción

Este documento define la **red Docker macvlan** que usará la capa DNS del homelab para que **Pi-hole** y **Unbound** tengan **IP propia dentro de la LAN** y no compitan por puertos del host como `53/tcp`, `53/udp` o `80/tcp`.

La idea operativa es simple:

- la **Raspberry Pi** mantiene su propia IP LAN para el host y para servicios como **Caddy**
- **Pi-hole** y **Unbound** viven en una **macvlan** sobre `eth0`
- cada contenedor se comporta como un equipo más de la red local
- el host recupera conectividad hacia esa macvlan mediante una interfaz auxiliar `macvlan-shim`

Este diseño encaja bien con el alcance del proyecto: **solo LAN + Tailscale**, sin exposición pública a internet y sin abrir puertos en el router.

<!-- TODO: verificar el rango IP definitivo reservado para `dns_lan` en el router antes de reutilizar los valores de ejemplo de este documento. -->

## Requisitos Previos

- Haber completado [01-instalacion-os.md](../01-sistema/01-instalacion-os.md).
- Haber completado [02-configuracion-inicial.md](../01-sistema/02-configuracion-inicial.md).
- Haber completado [03-seguridad-base.md](../01-sistema/03-seguridad-base.md).
- Haber completado [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber completado [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Tener la Raspberry Pi conectada por **Ethernet** y confirmar que la interfaz LAN real es **`eth0`**.
- Tener acceso administrativo al router para:
  - fijar o reservar la IP LAN del host
  - excluir del DHCP el rango que usará la macvlan, o reservar esas IPs manualmente
- Puertos necesarios en esta fase:
  - ninguno publicado todavía en el host
  - la red se prepara para servicios que usarán `53/tcp`, `53/udp` y `80/tcp` con IP propia

## Objetivo de esta Fase

Al terminar este documento, el estado esperado es este:

- existe una red Docker macvlan persistente llamada **`dns_lan`**
- el rango reservado para contenedores DNS queda **fuera del pool DHCP dinámico**
- queda definida una asignación clara de IPs para **Pi-hole**, **Unbound** y el **host shim**
- el host puede hablar con los contenedores macvlan gracias a `macvlan-shim`
- el diseño queda listo para ser reutilizado en [02-pihole.md](02-pihole.md) y [03-unbound.md](03-unbound.md)
- el host sigue usando temporalmente un DNS funcional ajeno a Pi-hole hasta completar la configuración de fallback descrita en [02-pihole.md](02-pihole.md)

## Docker Compose

En esta fase no se despliega todavía el stack definitivo de DNS, pero sí conviene validar la red con un Compose mínimo y funcional.

Archivo: `/home/<user>/homelab/compose/infra-macvlan-test/docker-compose.yml`

<!-- TODO: verificar el usuario real que sustituye a <user> en las rutas del homelab antes de aplicar los comandos tal cual. -->

```yaml
name: infra-macvlan-test

services:
  whoami:
    image: traefik/whoami:v1.11
    restart: unless-stopped
    networks:
      dns_lan:
        ipv4_address: 192.168.1.196

networks:
  dns_lan:
    external: true
    name: dns_lan
```

Este stack temporal sirve para comprobar tres cosas antes de desplegar Pi-hole:

- Docker acepta la red `dns_lan`
- un contenedor recibe una IP fija dentro del rango reservado
- la LAN y el host, mediante el `macvlan-shim`, pueden alcanzar ese contenedor

Después de validar la red, este stack puede eliminarse.

## Configuración

### 1. Confirmar parámetros reales de la LAN

Antes de crear la macvlan, identifica la topología real del host:

```bash
ip -br addr show eth0
ip route
```

En este documento se usa un ejemplo coherente y fácil de adaptar:

| Elemento | Valor de ejemplo |
|----------|------------------|
| Red LAN principal | `192.168.1.0/24` |
| Gateway del router | `192.168.1.1` |
| IP LAN del host Raspberry Pi | `192.168.1.10` |
| Rango reservado para macvlan | `192.168.1.192/27` |
| IP de Pi-hole | `192.168.1.194` |
| IP de Unbound | `192.168.1.195` |
| IP del `macvlan-shim` del host | `192.168.1.222` |
| Interfaz padre | `eth0` |
| Nombre de la red Docker | `dns_lan` |

Notas importantes:

- `192.168.1.192/27` ofrece IPs utilizables de `192.168.1.193` a `192.168.1.222`.
- La IP `192.168.1.222` se reserva para el host y **no** debe asignarse a contenedores.
- Si tu red no es `192.168.1.0/24`, cambia `subnet`, `gateway`, `ip-range` e IPs fijas en bloque; no mezcles valores de ejemplo con valores reales.
- Antes de ejecutar ningún comando de este documento, sustituye también la IP de prueba `192.168.1.196` y cualquier otra IP fija de ejemplo por valores válidos dentro de tu rango reservado.
- No configures todavía el host para usar **Pi-hole** como DNS único; primero completa [02-pihole.md](02-pihole.md) y deja resuelto el fallback del sistema para no perder resolución durante reinicios o caídas del stack DNS.

### 2. Reservar direcciones en el router y ajustar DHCP

Antes de tocar Docker, deja el router alineado con este diseño:

- reserva una IP fija para la Raspberry Pi, por ejemplo `192.168.1.10`
- excluye del DHCP dinámico el bloque `192.168.1.192/27`
- si tu router no permite excluir rangos, reduce el pool DHCP para que no alcance ese bloque
- como alternativa de último recurso, crea reservas individuales para las IPs que usarán `Pi-hole`, `Unbound` y `macvlan-shim`

Regla crítica:

- ninguna IP de la macvlan debe poder ser entregada por DHCP a otro equipo de la LAN

Si no haces esto, tarde o temprano tendrás una colisión de IP difícil de diagnosticar.

### 3. Crear la red Docker macvlan

La red `dns_lan` se crea una sola vez en el host:

```bash
docker network create -d macvlan \
  --subnet=192.168.1.0/24 \
  --gateway=192.168.1.1 \
  --ip-range=192.168.1.192/27 \
  --aux-address="host=192.168.1.222" \
  -o parent=eth0 \
  dns_lan
```

Explicación de los parámetros:

- `--subnet`: subred LAN completa en la que vivirán los contenedores
- `--gateway`: puerta de enlace real del router
- `--ip-range`: bloque concreto que Docker podrá usar para asignar IPs
- `--aux-address="host=..."`: reserva una IP del rango para el host
- `-o parent=eth0`: obliga a que la macvlan salga por la interfaz física correcta

Validación básica:

```bash
docker network ls | grep dns_lan
docker network inspect dns_lan
```

### 4. Entender la limitación nativa de macvlan

Por diseño, el host **no puede hablar directamente** con los contenedores conectados a su propia macvlan. Eso significa que, si no haces nada más:

- otros equipos de la LAN sí podrán acceder a `Pi-hole` o `Unbound`
- la Raspberry Pi no podrá resolver o consultar esos contenedores por su IP macvlan

Para este proyecto eso no es aceptable, porque el host debe poder:

- consultar el panel de Pi-hole
- usar Pi-hole como resolvedor local si se desea
- comprobar salud y conectividad desde la propia Raspberry Pi

La solución es crear una interfaz adicional en el host: **`macvlan-shim`**.

### 5. Crear el `macvlan-shim` en el host

Creación manual inicial:

```bash
sudo ip link add macvlan-shim link eth0 type macvlan mode bridge
sudo ip addr add 192.168.1.222/32 dev macvlan-shim
sudo ip link set macvlan-shim up
sudo ip route add 192.168.1.192/27 dev macvlan-shim
```

Qué hace cada comando:

- crea una interfaz macvlan extra en el host sobre `eth0`
- asigna al host la IP reservada `192.168.1.222`
- levanta la interfaz
- enruta el bloque de contenedores hacia esa interfaz

Validación:

```bash
ip -br addr show macvlan-shim
ip route | grep 192.168.1.192/27
```

En este punto el host ya debería poder llegar a cualquier contenedor que use una IP dentro de `192.168.1.192/27`.

### 6. Hacer persistente el `macvlan-shim`

La red Docker `dns_lan` persiste por sí sola, pero la interfaz `macvlan-shim` creada con `ip link` **no**. Para recuperarla tras reinicios, usa un servicio `systemd`.

Archivo: `/etc/systemd/system/macvlan-shim.service`

Este servicio presupone que la ruta del binario `ip` es `/usr/sbin/ip`, que es la habitual en Raspberry Pi OS Lite 64-bit. Si en tu sistema `command -v ip` devuelve otra ruta, sustituye las líneas `ExecStart*` y `ExecStop` antes de habilitarlo.

```ini
[Unit]
Description=Host macvlan shim for Docker dns_lan
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/sbin/ip link delete macvlan-shim
ExecStart=/usr/sbin/ip link add macvlan-shim link eth0 type macvlan mode bridge
ExecStart=/usr/sbin/ip addr add 192.168.1.222/32 dev macvlan-shim
ExecStart=/usr/sbin/ip link set macvlan-shim up
ExecStart=/usr/sbin/ip route replace 192.168.1.192/27 dev macvlan-shim
ExecStop=-/usr/sbin/ip link delete macvlan-shim

[Install]
WantedBy=multi-user.target
```

Activación:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now macvlan-shim.service
sudo systemctl status macvlan-shim.service
```

Si más adelante cambias de subred o de interfaz padre, recuerda actualizar tanto la red Docker como este servicio.

### 7. Validar la macvlan con un contenedor temporal

Prepara el directorio del stack temporal:

```bash
mkdir -p /home/<user>/homelab/compose/infra-macvlan-test
```

Si tu usuario no coincide con `<user>`, sustituye la ruta completa antes de continuar.

Crea el `docker-compose.yml` del apartado anterior y despliega:

```bash
cd /home/<user>/homelab/compose/infra-macvlan-test
docker compose config
docker compose up -d
docker compose ps
```

Valida desde el host:

```bash
curl http://192.168.1.196
ping -c 3 192.168.1.196
```

Usa aquí la IP real que hayas asignado al contenedor temporal, no `192.168.1.196` si elegiste otra.

Valida desde otro equipo de la LAN:

- abre `http://192.168.1.196`
- confirma que responde la página de `whoami`

Si ambas pruebas funcionan, la red está lista para usar IPs fijas en los próximos documentos:

- `192.168.1.194` para **Pi-hole**
- `192.168.1.195` para **Unbound**

Cuando termines la prueba, desmonta el stack temporal para no dejar un contenedor ocupando una IP del rango reservado:

```bash
cd /home/<user>/homelab/compose/infra-macvlan-test
docker compose down
```

### 8. Criterios operativos para los siguientes documentos

A partir de aquí, mantén estas reglas:

- **Pi-hole** y **Unbound** se conectan a `dns_lan` con **IP fija**
- no publiques en el host los puertos `53`, `80` o `443` de esos contenedores
- la IP LAN del host queda libre para **Caddy** y para otros servicios no ligados a macvlan
- cualquier cambio en el rango `192.168.1.192/27` debe reflejarse en el router, en Docker y en `macvlan-shim.service`

### 9. Errores frecuentes que conviene evitar

- usar una interfaz padre incorrecta como `wlan0` en vez de `eth0`
- dejar el rango macvlan dentro del pool DHCP automático del router
- intentar acceder desde el host a la macvlan sin crear `macvlan-shim`
- reutilizar la IP reservada para el host en un contenedor
- asumir que una red macvlan sustituye a todas las redes Docker del proyecto

La macvlan debe reservarse para los casos que realmente necesitan presencia propia en la LAN. El resto de servicios del homelab seguirán funcionando mejor en redes Docker normales o detrás del proxy interno.

## Almacenamiento

Esta fase apenas necesita almacenamiento persistente, pero sí deja varios artefactos operativos que conviene ubicar de forma ordenada:

- `docker-compose.yml` de prueba: `/home/<user>/homelab/compose/infra-macvlan-test/docker-compose.yml`
- documentación del proyecto: [01-macvlan.md](01-macvlan.md)
- servicio `systemd` del host: `/etc/systemd/system/macvlan-shim.service`

Notas importantes:

- la red Docker `dns_lan` no ocupa almacenamiento relevante, pero forma parte del estado operativo del host
- el stack de prueba `infra-macvlan-test` no necesita volúmenes persistentes
- los datos reales de **Pi-hole** y **Unbound** se documentarán en sus respectivos archivos y vivirán en el **SSD NVMe**

## Backup

En esta fase, lo que debe respaldarse no es tanto dato de aplicación como **la definición de red y su persistencia**:

- [01-macvlan.md](01-macvlan.md)
- `/home/<user>/homelab/compose/infra-macvlan-test/docker-compose.yml` si decides conservar el stack de prueba
- `/etc/systemd/system/macvlan-shim.service`
- cualquier export o captura de la configuración DHCP del router donde quede excluido el rango macvlan

Lo importante es poder reconstruir rápidamente:

- qué bloque IP estaba reservado
- qué IPs fijas se habían asignado
- cómo recuperaba el host la conectividad hacia la macvlan tras reiniciar

## Referencias

- [02-pihole.md](02-pihole.md)
- [03-unbound.md](03-unbound.md)
- [05-caddy.md](05-caddy.md)
- [06-puertos-y-firewall.md](06-puertos-y-firewall.md)
- Docker Docs: [Networking using a macvlan network driver](https://docs.docker.com/engine/network/drivers/macvlan/)
- Docker Docs: [docker network create](https://docs.docker.com/reference/cli/docker/network/create/)
- `ip-link(8)`
- `ip-address(8)`
- `ip-route(8)`
- `systemd.service(5)`
