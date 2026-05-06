# Red Docker Macvlan

## Descripción
Este documento define la red Docker `homelab_macvlan` que usarán **Pi-hole** y **Unbound** para tener **IP propia dentro de la LAN** y no ocupar en la IP principal de la Raspberry Pi los puertos `53/tcp`, `53/udp` y `80/tcp`.

La topología buscada en esta fase es esta:

```text
clientes LAN
   |
   v
Pi-hole / Unbound con IP propia en la LAN
   |
   +--> Docker macvlan: homelab_macvlan

Raspberry Pi
   |
   +--> IP principal del host libre para Caddy y otros servicios
   +--> macvlan-shim para comunicación host <-> contenedores macvlan
```

En esta guía se usa como ejemplo:

- interfaz padre `eth0`
- subred `192.168.1.0/24`
- gateway `192.168.1.1`
- IP LAN principal del host `192.168.1.10`
- pool macvlan `192.168.1.240/29`
- IP del host para `macvlan-shim` `192.168.1.248`

Si tu red usa otra numeración, sustituye los valores manteniendo la misma lógica.

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Tener la Raspberry Pi conectada por **Ethernet** y confirmar que la interfaz física de la LAN es `eth0`.
- Tener acceso administrativo al router para ajustar el alcance DHCP o crear exclusiones.
- Poder usar `sudo` en el host.
- Tener identificados los parámetros reales de la red:
  - subred
  - gateway
  - rango DHCP actual
  - IP actual del host
- Tener claro que esta fase prepara una red **solo LAN + Tailscale**, sin puertos abiertos a internet.
- Puertos implicados:
  - no se publica ningún puerto nuevo en la IP principal del host
  - los puertos `53/tcp`, `53/udp` y `80/tcp` quedarán disponibles para contenedores con IP macvlan
  - el stack de validación usa `80/tcp` únicamente en su IP dedicada de la LAN

## Docker Compose
La red macvlan se crea una sola vez con `docker network create` y después se consume desde los stacks como **red externa**. Para verificar el diseño antes de desplegar Pi-hole y Unbound conviene levantar un stack mínimo de prueba.

Directorio recomendado:

```text
/home/<usuario>/homelab/compose/macvlan-test/
├── compose.yaml
└── .env
```

Fichero `.env`:

```dotenv
TZ=Europe/Madrid
WHOAMI_IP=192.168.1.241
```

Fichero `compose.yaml`:

```yaml
name: macvlan-test

services:
  whoami:
    container_name: macvlan-test-whoami
    image: traefik/whoami:latest
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    networks:
      homelab_macvlan:
        ipv4_address: ${WHOAMI_IP}

networks:
  homelab_macvlan:
    external: true
    name: homelab_macvlan
```

Despliegue de prueba:

```bash
mkdir -p /home/<usuario>/homelab/compose/macvlan-test
cd /home/<usuario>/homelab/compose/macvlan-test
docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

Resultado esperado:

- el contenedor obtiene la IP `192.168.1.241` dentro de la LAN
- otro equipo de la red puede abrir `http://192.168.1.241`
- el host solo podrá acceder bien a esa IP cuando exista `macvlan-shim`

## Configuración

### Objetivo final de esta guía

| Elemento | Estado esperado |
|---|---|
| Interfaz padre | `eth0` |
| Red Docker | `homelab_macvlan` |
| Subred LAN | `192.168.1.0/24` |
| Gateway | `192.168.1.1` |
| Pool para contenedores macvlan | `192.168.1.241` a `192.168.1.246` |
| IP reservada para `macvlan-shim` | `192.168.1.248` |
| DHCP del router | sin asignar direcciones dentro del bloque reservado |
| Comunicación host ↔ macvlan | operativa mediante `macvlan-shim` |

### Estrategia recomendada

Aunque el plan maestro usa `192.168.1.2` como ejemplo válido, en esta documentación se recomienda reservar un **bloque alto y pequeño** dentro de la LAN. En una red doméstica eso reduce choques con el DHCP y hace más visible la separación entre:

- IP del router
- IP principal de la Raspberry Pi
- IPs dedicadas a contenedores macvlan

Contrato de red recomendado para esta fase:

| Uso | Valor recomendado |
|---|---|
| Red física | `eth0` |
| Nombre de la red Docker | `homelab_macvlan` |
| Subred LAN | `192.168.1.0/24` |
| Gateway | `192.168.1.1` |
| Pool Docker para macvlan | `192.168.1.240/29` |
| IPs utilizables por contenedores | `192.168.1.241` a `192.168.1.246` |
| IP reservada para `macvlan-shim` | `192.168.1.248/32` |
| Asignación futura sugerida | Pi-hole `192.168.1.241`, Unbound `192.168.1.242` |

Observación importante sobre este ejemplo:

- `192.168.1.240/29` reserva el bloque `192.168.1.240-247`
- dentro de ese bloque, las IPs utilizables para contenedores son `192.168.1.241-246`
- `192.168.1.248` queda fuera de ese `ip-range`, pero sigue dentro de la subred `192.168.1.0/24`, por eso es válida para `macvlan-shim`

### 1. Confirmar los parámetros reales de la LAN

Antes de crear nada en Docker, confirma qué interfaz y qué red está usando realmente el host:

```bash
ip -4 addr show dev eth0
ip route
hostname -I
```

Debes verificar al menos:

- que `eth0` es la interfaz activa hacia el router
- que la Raspberry Pi está en la misma subred donde vivirán Pi-hole y Unbound
- que el gateway real coincide con la IP del router
- que el rango DHCP actual no invade el bloque que vas a reservar

Si `eth0` no es la interfaz correcta, sustituye ese valor por la interfaz física real antes de continuar.

### 2. Reservar el bloque macvlan en el DHCP del router

El router no debe entregar por DHCP ninguna dirección del bloque reservado para macvlan. Si no haces esto, tarde o temprano tendrás una colisión entre un cliente normal y un contenedor Docker.

Reserva o excluye como mínimo:

```text
192.168.1.240 - 192.168.1.248
```

Objetivo práctico del bloque:

- `192.168.1.241` a `192.168.1.246` para contenedores en `homelab_macvlan`
- `192.168.1.248` para la interfaz `macvlan-shim` del host

Formas correctas de hacerlo:

- reducir el rango DHCP para que no alcance ese bloque
- crear una exclusión explícita para ese bloque
- si el router solo soporta reservas por MAC, reducir el alcance DHCP suele ser la opción más segura

No conviene reservar solo una IP suelta. La política debe aplicarse al **bloque completo**.

### 3. Crear la red Docker macvlan

Crear la red externa que consumirán después `docs/03-red/02-pihole.md` y `docs/03-red/03-unbound.md`:

```bash
docker network create -d macvlan \
  --subnet=192.168.1.0/24 \
  --gateway=192.168.1.1 \
  --ip-range=192.168.1.240/29 \
  --aux-address="host=192.168.1.248" \
  -o parent=eth0 \
  homelab_macvlan
```

Significado de los parámetros clave:

- `-d macvlan`: usa el driver macvlan
- `--subnet`: define la subred real de la LAN
- `--gateway`: fija la puerta de enlace del router
- `--ip-range`: limita las IPs que Docker podrá usar dentro de esa subred
- `--aux-address="host=..."`: reserva una IP fuera del reparto a contenedores, en este caso para el host
- `-o parent=eth0`: enlaza la red virtual con la interfaz física Ethernet

Validación inmediata:

```bash
docker network ls
docker network inspect homelab_macvlan
```

Debes comprobar:

- que el driver es `macvlan`
- que el `Parent` es `eth0`
- que la subred y el gateway coinciden con la LAN real
- que el pool de IPs es el esperado

### 4. Crear la interfaz `macvlan-shim` en el host

Con macvlan, el host no puede hablar directamente con sus propios contenedores macvlan si no creas una interfaz macvlan adicional en el sistema. Esa interfaz de apoyo es `macvlan-shim`.

Creación manual:

```bash
sudo ip link add macvlan-shim link eth0 type macvlan mode bridge
sudo ip addr add 192.168.1.248/32 dev macvlan-shim
sudo ip link set macvlan-shim up
sudo ip route add 192.168.1.240/29 dev macvlan-shim
```

Validación:

```bash
ip addr show dev macvlan-shim
ip route show 192.168.1.240/29
```

Comportamiento esperado:

- el host mantiene su IP normal en `eth0`
- `macvlan-shim` usa una IP dedicada solo para hablar con el rango macvlan
- la ruta hace que el tráfico hacia `192.168.1.241-246` salga por esa interfaz

Si omites este paso:

- otros clientes de la LAN sí podrán llegar a Pi-hole y Unbound
- el propio host no podrá hablar con ellos por su IP macvlan

Eso rompe pruebas locales, diagnósticos y cualquier integración que salga desde la Raspberry Pi.

### 5. Hacer persistente `macvlan-shim`

La interfaz creada con `ip link add` se pierde al reiniciar. Una forma simple y explícita de recuperarla es un servicio `systemd`.

Crear `/etc/systemd/system/macvlan-shim.service`:

```ini
[Unit]
Description=Interfaz macvlan-shim para contenedores Docker en macvlan
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'ip link show macvlan-shim >/dev/null 2>&1 || ip link add macvlan-shim link eth0 type macvlan mode bridge'
ExecStart=/bin/sh -c 'ip addr show dev macvlan-shim | grep -q "192.168.1.248/32" || ip addr add 192.168.1.248/32 dev macvlan-shim'
ExecStart=/usr/sbin/ip link set macvlan-shim up
ExecStart=/bin/sh -c 'ip route show 192.168.1.240/29 | grep -q macvlan-shim || ip route add 192.168.1.240/29 dev macvlan-shim'
ExecStop=/bin/sh -c 'ip route del 192.168.1.240/29 dev macvlan-shim || true'
ExecStop=/bin/sh -c 'ip link del macvlan-shim || true'

[Install]
WantedBy=multi-user.target
```

Activar y probar:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now macvlan-shim.service
systemctl status macvlan-shim.service
```

Si prefieres tener una copia versionable, guarda primero el contenido en `/home/<usuario>/homelab/scripts/` y después instálalo en `/etc/systemd/system/`.

### 6. Validar la red con el stack Compose de prueba

Con la red y el shim ya creados, levanta el stack de prueba definido en la sección anterior.

Comprobaciones útiles desde la Raspberry Pi:

```bash
cd /home/<usuario>/homelab/compose/macvlan-test
docker compose ps
docker inspect macvlan-test-whoami
curl http://192.168.1.241
ping -c 3 192.168.1.241
```

Haz también una prueba desde otro equipo de la LAN:

```bash
curl http://192.168.1.241
```

Resultado esperado:

- desde otro equipo de la LAN responde el contenedor en `192.168.1.241`
- desde la Raspberry Pi responde también gracias a `macvlan-shim`
- `docker inspect` muestra el contenedor unido a `homelab_macvlan`

Si esta prueba funciona, la base de red para `docs/03-red/02-pihole.md` y `docs/03-red/03-unbound.md` queda lista.

### 7. Troubleshooting básico

Comprobaciones útiles si algo no cuadra:

```bash
docker network inspect homelab_macvlan
ip addr show dev macvlan-shim
ip route show 192.168.1.240/29
docker compose -f /home/<usuario>/homelab/compose/macvlan-test/compose.yaml ps
docker compose -f /home/<usuario>/homelab/compose/macvlan-test/compose.yaml logs --tail=50
```

Síntomas comunes:

- otro equipo de la LAN no llega a `192.168.1.241`:
  - revisa que la IP no esté ocupada por otro dispositivo y que el router no la entregue por DHCP
- el host no llega al contenedor, pero otros equipos sí:
  - normalmente falta `macvlan-shim` o la ruta `192.168.1.240/29`
- `docker network inspect` muestra un `Parent` incorrecto:
  - la red se creó contra otra interfaz distinta de `eth0` y conviene recrearla con el parámetro correcto
- el contenedor arranca pero no responde en la IP esperada:
  - comprueba que el stack use `homelab_macvlan` como red externa y que la IP fijada esté dentro del rango previsto

### 8. Limpieza opcional del stack de prueba

Cuando termines de validar, puedes dejar el stack como herramienta de troubleshooting o retirarlo:

```bash
cd /home/<usuario>/homelab/compose/macvlan-test
docker compose down
```

No elimines `homelab_macvlan` ni `macvlan-shim.service` si vas a continuar con Pi-hole y Unbound.

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose de prueba | `/home/<usuario>/homelab/compose/macvlan-test/` | SSD NVMe |
| Variables del stack de prueba | `/home/<usuario>/homelab/compose/macvlan-test/.env` | SSD NVMe |
| Servicio `systemd` del shim | `/etc/systemd/system/macvlan-shim.service` | SSD NVMe |
| Datos persistentes de la red macvlan | no aplica | no aplica |

Notas de almacenamiento:

- la red Docker `homelab_macvlan` no guarda datos persistentes por sí misma
- esta fase prepara conectividad, no almacenamiento de aplicaciones
- lo importante de conservar es el stack de prueba y la definición persistente de `macvlan-shim`

## Backup
Conviene respaldar como mínimo:

- `/home/<usuario>/homelab/compose/macvlan-test/compose.yaml`
- `/home/<usuario>/homelab/compose/macvlan-test/.env`
- `/etc/systemd/system/macvlan-shim.service`
- una nota con los parámetros reales de red:
  - subred
  - gateway
  - pool macvlan
  - IP del shim
  - interfaz padre

No es necesario respaldar:

- la red Docker en sí, porque puede recrearse con el comando documentado
- el contenedor de prueba, porque es completamente recreable

Restauración práctica:

1. restaurar el fichero `macvlan-shim.service`
2. recrear la red `homelab_macvlan`
3. habilitar `macvlan-shim.service`
4. volver a levantar el stack de prueba o directamente los stacks de Pi-hole y Unbound

## Referencias
- [Docker Docs: Macvlan network driver](https://docs.docker.com/engine/network/drivers/macvlan/)
- [Docker Docs: `docker network create`](https://docs.docker.com/reference/cli/docker/network/create/)
- [Docker Docs: Compose file reference, networks](https://docs.docker.com/reference/compose-file/networks/)
- [Docker Docs: `docker network inspect`](https://docs.docker.com/reference/cli/docker/network/inspect/)
- [Docker Hub: `traefik/whoami`](https://hub.docker.com/r/traefik/whoami)
