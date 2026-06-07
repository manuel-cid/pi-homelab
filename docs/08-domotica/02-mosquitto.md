# Mosquitto

## Descripción

**Mosquitto** es el broker MQTT del bloque de domótica del homelab. Su función es servir como bus de mensajería ligero entre **Home Assistant**, **Zigbee2MQTT**, **Node-RED** y cualquier otro cliente IoT que publique estados, eventos o comandos.

En este proyecto se despliega en Docker sobre la **Raspberry Pi 5**, con persistencia en el **SSD NVMe** y acceso restringido a la **LAN** y a **Tailscale**. El despliegue base evita complejidad innecesaria:

- listener MQTT clásico en `1883/tcp`
- sin acceso anónimo
- usuarios separados por servicio
- ACLs para limitar qué topics puede usar cada cliente
- sin WebSockets ni TLS en la base inicial, porque no hay exposición pública a Internet

Cuando en este documento aparezca `IP_DE_LA_PI`, sustitúyelo por la IP LAN real del host. Si accedes por la VPN, usa la IP o el nombre MagicDNS de Tailscale del host, pero sin abrir puertos en el router.

Este documento asume que el broker escucha en el host en `1883/tcp` para simplificar la integración con contenedores y clientes externos a Docker. La restricción real del alcance se hace con el firewall del host, no con port forwarding ni exposición pública.

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Haber completado [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber completado [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber revisado [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) para registrar el puerto del broker.
- Recomendable haber completado [01-home-assistant.md](01-home-assistant.md) si Mosquitto se va a integrar inmediatamente con Home Assistant.
- Si se quiere acceso remoto, tener operativa la VPN de [04-tailscale.md](../03-red/04-tailscale.md).
- Puertos necesarios en esta fase:
  - **`1883/tcp`** para MQTT
  - no publicar **WebSockets** (`9001`) salvo que exista un caso real de uso

Si expones `1883/tcp` en el host, registra el puerto en [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) y limita el acceso a la **LAN** y, solo si realmente hace falta, a **Tailscale**.

## Docker Compose

Archivo: `/home/<user>/homelab/compose/iot-mosquitto/docker-compose.yml`

```yaml
name: iot-mosquitto

services:
  mosquitto:
    image: eclipse-mosquitto:2
    container_name: mosquitto
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    environment:
      TZ: Europe/Madrid
    ports:
      - "1883:1883"
    volumes:
      - /home/<user>/homelab/config/mosquitto:/mosquitto/config
      - /home/<user>/homelab/data/mosquitto/data:/mosquitto/data
      - /home/<user>/homelab/data/mosquitto/log:/mosquitto/log
    labels:
      - wud.watch=false
```

Este stack sigue la convención general del proyecto:

- `docker-compose.yml` dentro de `compose/`
- persistencia en `data/`
- sin secretos embebidos en el Compose
- servicio accesible por el puerto del host para que clientes dentro y fuera de Docker puedan conectarse igual

Si usas `ufw`, una base razonable para este puerto es permitir únicamente la subred LAN y, si procede, la interfaz Tailscale:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 1883 proto tcp
sudo ufw allow in on tailscale0 to any port 1883 proto tcp
```

Sustituye `192.168.1.0/24` por la subred real de tu red local. Si no necesitas clientes MQTT a través de Tailscale, omite la segunda regla.

## Configuración

### 1. Preparar directorios

```bash
mkdir -p /home/<user>/homelab/compose/iot-mosquitto
mkdir -p /home/<user>/homelab/config/mosquitto
mkdir -p /home/<user>/homelab/data/mosquitto/{data,log}
sudo chown -R 1883:1883 /home/<user>/homelab/config/mosquitto
sudo chown -R 1883:1883 /home/<user>/homelab/data/mosquitto
chmod 750 /home/<user>/homelab/config/mosquitto
```

La imagen oficial de **Eclipse Mosquitto** suele ejecutarse con el UID/GID `1883`. Si dejas `config/` como `700` y propiedad de `root`, el contenedor no podrá leer `mosquitto.conf`, `passwd` o `acl`.

### 2. Crear la configuración principal

Archivo: `/home/<user>/homelab/config/mosquitto/mosquitto.conf`

```conf
persistence true
persistence_location /mosquitto/data/
autosave_interval 180

log_dest stdout
log_dest file /mosquitto/log/mosquitto.log
log_timestamp true

listener 1883
allow_anonymous false
password_file /mosquitto/config/passwd
acl_file /mosquitto/config/acl
```

Esta configuración establece un despliegue base simple y suficiente para el homelab:

- persistencia de sesiones y estado en disco
- logs visibles por `docker compose logs` y además en fichero
- autenticación obligatoria
- control de acceso por topics mediante ACLs

### 3. Crear los usuarios MQTT

Archivo de credenciales: `/home/<user>/homelab/config/mosquitto/passwd`

La recomendación es usar **un usuario distinto por servicio**. Un conjunto razonable para esta fase es:

- `mqtt-homeassistant`
- `mqtt-zigbee2mqtt`
- `mqtt-nodered`

Crea el fichero y añade usuarios usando la propia imagen oficial:

```bash
touch /home/<user>/homelab/config/mosquitto/passwd
chmod 600 /home/<user>/homelab/config/mosquitto/passwd

docker run --rm \
  -v /home/<user>/homelab/config/mosquitto:/mosquitto/config \
  eclipse-mosquitto:2 \
  mosquitto_passwd -c /mosquitto/config/passwd mqtt-homeassistant

docker run --rm \
  -v /home/<user>/homelab/config/mosquitto:/mosquitto/config \
  eclipse-mosquitto:2 \
  mosquitto_passwd /mosquitto/config/passwd mqtt-zigbee2mqtt

docker run --rm \
  -v /home/<user>/homelab/config/mosquitto:/mosquitto/config \
  eclipse-mosquitto:2 \
  mosquitto_passwd /mosquitto/config/passwd mqtt-nodered
```

Notas:

- usa `-c` solo en la primera creación del fichero
- no reutilices la misma cuenta para varios servicios
- evita pasar contraseñas por línea de comandos para no dejarlas en el historial del shell
- si alguno de estos comandos deja el fichero como `root:root`, corrige después con `sudo chown 1883:1883 /home/<user>/homelab/config/mosquitto/passwd`
- mantén `passwd` en `600` para que el fichero de credenciales no quede legible por otros usuarios del host

### 4. Definir ACLs

Archivo: `/home/<user>/homelab/config/mosquitto/acl`

```conf
user mqtt-homeassistant
topic readwrite homeassistant/#
topic readwrite zigbee2mqtt/#
topic read $SYS/#

user mqtt-zigbee2mqtt
topic readwrite zigbee2mqtt/#
topic write homeassistant/#
topic read $SYS/#

user mqtt-nodered
topic readwrite nodered/#
topic readwrite homeassistant/#
topic readwrite zigbee2mqtt/#
topic read $SYS/#
```

Después de guardar `acl`, deja también ese fichero accesible para el contenedor:

```bash
sudo chown 1883:1883 /home/<user>/homelab/config/mosquitto/acl
chmod 640 /home/<user>/homelab/config/mosquitto/acl
sudo chown 1883:1883 /home/<user>/homelab/config/mosquitto/mosquitto.conf
chmod 644 /home/<user>/homelab/config/mosquitto/mosquitto.conf
```

Este punto es importante:

- **Home Assistant** necesita al menos acceso a `homeassistant/#` y, en la práctica, conviene permitirle también `zigbee2mqtt/#`
- **Zigbee2MQTT** debe poder publicar su propio árbol `zigbee2mqtt/#` y escribir en `homeassistant/#` si vas a usar MQTT Discovery
- **Node-RED** suele necesitar más flexibilidad para sus flujos, pero aun así conviene no darle `topic readwrite #` salvo necesidad real

Si más adelante añades sensores, ESPHome alternativo, scripts o clientes externos, crea **usuarios nuevos** y dales solo los topics que realmente necesiten.

### 5. Desplegar el stack

Guarda el `docker-compose.yml` del apartado anterior y despliega:

```bash
cd /home/<user>/homelab/compose/iot-mosquitto
docker compose config
docker compose up -d
docker compose ps
```

Validaciones básicas tras el arranque:

```bash
docker compose logs --tail=100 mosquitto
ss -ltnp | grep 1883
```

El resultado esperado es este:

- el contenedor queda en estado `Up`
- Mosquitto escucha en `0.0.0.0:1883`
- no aparecen errores de lectura sobre `mosquitto.conf`, `passwd` o `acl`
- no aparecen errores de escritura en `/mosquitto/data` o `/mosquitto/log`

### 6. Integración básica con Home Assistant

En [01-home-assistant.md](01-home-assistant.md) ya quedó preparada la referencia a MQTT. Ahora completa la integración desde **Settings → Devices & services → Add integration → MQTT**.

Valores típicos:

- Broker: `IP_DE_LA_PI`
- Puerto: `1883`
- Usuario: `mqtt-homeassistant`
- Contraseña: la definida en el paso anterior

Si Home Assistant accede por la misma red Docker y no por el host, puedes usar el nombre del servicio o alias de red correspondiente. En este repositorio se documenta `IP_DE_LA_PI` para mantener un punto de conexión único también válido para clientes fuera de Docker.

Si todo va bien, Home Assistant detectará el broker y podrás usarlo como base para discovery y automatizaciones posteriores.

### 7. Integración prevista con Zigbee2MQTT

Cuando despliegues [03-zigbee2mqtt.md](03-zigbee2mqtt.md), configura su acceso a MQTT con:

- servidor: `mqtt://IP_DE_LA_PI:1883`
- usuario: `mqtt-zigbee2mqtt`
- contraseña: la correspondiente

Si activas `homeassistant: true` en Zigbee2MQTT, este publicará mensajes de discovery en `homeassistant/#`, por eso la ACL propuesta le permite escribir en ese prefijo.

### 8. Integración prevista con Node-RED

Cuando despliegues [04-node-red.md](04-node-red.md), crea el servidor MQTT en Node-RED usando:

- host: `IP_DE_LA_PI`
- puerto: `1883`
- usuario: `mqtt-nodered`
- contraseña: la definida en Mosquitto

Antes de empezar a crear flujos complejos, prueba primero:

- una suscripción a `zigbee2mqtt/#`
- una publicación de prueba en `nodered/test`
- una automatización simple que reaccione a un mensaje MQTT

## Almacenamiento

Todo el estado de Mosquitto debe quedar en el **SSD NVMe**, separando configuración editable y datos persistentes según la convención del proyecto.

Rutas principales:

- `/home/<user>/homelab/config/mosquitto/`
- `/home/<user>/homelab/data/mosquitto/data/`
- `/home/<user>/homelab/data/mosquitto/log/`

Contenido esperado:

- `config/mosquitto/mosquitto.conf`
- `config/mosquitto/passwd`
- `config/mosquitto/acl`
- `data/mosquitto/data/mosquitto.db`
- `data/mosquitto/log/mosquitto.log`

No uses `hd2t` ni `hd5t` para estos datos. Esos discos quedan reservados para multimedia y copias de seguridad.

### Permisos

- `config/mosquitto/passwd` debe quedar con permisos restrictivos, por ejemplo `600`
- `config/mosquitto/` conviene mantenerlo en `750` o similar, con propietario `1883:1883`
- `data/` y `log/` deben ser escribibles por el contenedor

Si ves errores de permisos al arrancar, revisa el propietario real de las rutas bind-mounted y ajústalo según el UID/GID que use la imagen dentro del contenedor.

## Backup

Respaldar:

- `/home/<user>/homelab/compose/iot-mosquitto/docker-compose.yml`
- `/home/<user>/homelab/config/mosquitto/`
- `/home/<user>/homelab/data/mosquitto/data/`
- `/home/<user>/homelab/data/mosquitto/log/` si quieres conservar histórico de eventos

Especialmente importantes:

- `mosquitto.conf`
- `passwd`
- `acl`
- `mosquitto.db`

Para una copia consistente del estado persistente, lo más prudente es detener brevemente el broker:

```bash
cd /home/<user>/homelab/compose/iot-mosquitto
docker compose stop mosquitto
# ejecutar backup
docker compose start mosquitto
```

Este servicio debe integrarse más adelante con la estrategia de [02-borgmatic.md](../07-backups/02-borgmatic.md).

## Referencias

- Documentación oficial de Mosquitto: https://mosquitto.org/
- Manual oficial de `mosquitto.conf`: https://mosquitto.org/man/mosquitto-conf-5.html
- Manual oficial de `mosquitto_passwd`: https://mosquitto.org/man/mosquitto_passwd-1.html
- Documentación oficial de ACLs y seguridad: https://mosquitto.org/documentation/authentication-methods/
- Imagen oficial Docker: https://hub.docker.com/_/eclipse-mosquitto
