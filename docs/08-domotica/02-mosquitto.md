# Mosquitto

## Descripción
**Mosquitto** será el broker MQTT del bloque de domótica del homelab. Su función es actuar como punto central de mensajería entre **Home Assistant**, **Zigbee2MQTT**, **Node-RED** y cualquier otro sensor o cliente MQTT que se añada más adelante.

En este diseño se desplegará como un stack Docker independiente, con estas decisiones:

- autenticación obligatoria por usuario y contraseña
- control de acceso por **ACLs** en fichero
- persistencia en el **SSD NVMe**
- acceso solo por **LAN + Tailscale**
- sin exposición pública a internet
- sin TLS en esta fase, porque el alcance del homelab queda limitado a red local y VPN mesh

Esto deja una topología clara:

```text
dispositivos / clientes MQTT
          |
          v
      Mosquitto
      /   |   \
     v    v    v
Home Assistant
 Zigbee2MQTT
   Node-RED
```

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber desplegado `docs/08-domotica/01-home-assistant.md` si vas a integrar MQTT desde el primer momento.
- Tener creada la estructura base del proyecto, al menos:
  - `/home/<usuario>/homelab/compose`
  - `/home/<usuario>/homelab/data`
- Tener decidido qué clientes van a conectarse al broker para poder crear usuarios separados.
- Puertos implicados:
  - `1883/tcp` publicado en el host para clientes MQTT de LAN, Tailscale y otros contenedores
  - no se usará `9001/tcp` para WebSockets en esta fase
  - no se abrirán puertos en el router

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/mosquitto/
├── compose.yaml
└── .env
```

Fichero `.env` recomendado:

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000
MOSQUITTO_BASE_DIR=/home/<usuario>/homelab/data/mosquitto
```

Fichero `compose.yaml`:

```yaml
name: mosquitto

services:
  mosquitto:
    image: eclipse-mosquitto:2
    restart: unless-stopped
    user: "${PUID}:${PGID}"
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    ports:
      - "1883:1883"
    volumes:
      - ${MOSQUITTO_BASE_DIR}/config:/mosquitto/config
      - ${MOSQUITTO_BASE_DIR}/data:/mosquitto/data
    labels:
      com.centurylinklabs.watchtower.enable: "true"
```

Estructura esperada de datos:

```text
/home/<usuario>/homelab/data/mosquitto/
├── config/
│   ├── mosquitto.conf
│   ├── passwd
│   └── acl
└── data/
```

Despliegue inicial:

```bash
mkdir -p /home/<usuario>/homelab/compose/mosquitto
mkdir -p /home/<usuario>/homelab/data/mosquitto/config
mkdir -p /home/<usuario>/homelab/data/mosquitto/data
touch /home/<usuario>/homelab/data/mosquitto/config/passwd
touch /home/<usuario>/homelab/data/mosquitto/config/acl
```

En este punto todavía faltan `mosquitto.conf`, los usuarios y las ACLs. El arranque real del broker se hará al final de la sección **Configuración**, cuando los ficheros estén completos.

Verificaciones previas recomendadas:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/mosquitto
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/mosquitto

cd /home/<usuario>/homelab/compose/mosquitto
docker compose config
docker compose pull
```

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| Broker MQTT | Mosquitto en Docker |
| Puerto publicado | `1883/tcp` |
| Autenticación | obligatoria por `password_file` |
| Autorización | ACLs en fichero |
| Persistencia | `/home/<usuario>/homelab/data/mosquitto/data/` |
| Configuración | `/home/<usuario>/homelab/data/mosquitto/config/` |
| Acceso remoto | IP Tailscale de la Pi, sin exposición pública |

### 1. Preparar directorios y permisos

Crear la estructura:

```bash
mkdir -p /home/<usuario>/homelab/compose/mosquitto
mkdir -p /home/<usuario>/homelab/data/mosquitto/config
mkdir -p /home/<usuario>/homelab/data/mosquitto/data
touch /home/<usuario>/homelab/data/mosquitto/config/passwd
touch /home/<usuario>/homelab/data/mosquitto/config/acl
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/mosquitto
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/mosquitto

chmod 755 /home/<usuario>/homelab/data/mosquitto
chmod 755 /home/<usuario>/homelab/data/mosquitto/data
chmod 750 /home/<usuario>/homelab/data/mosquitto/config
chmod 600 /home/<usuario>/homelab/data/mosquitto/config/passwd
chmod 600 /home/<usuario>/homelab/data/mosquitto/config/acl
```

En `.env`, sustituye `PUID` y `PGID` por los valores reales del usuario que ejecutará Docker si no coinciden con `1000:1000`:

```bash
id -u <usuario>
id -g <usuario>
```

### 2. Crear `mosquitto.conf`

Guardar este contenido en:

```text
/home/<usuario>/homelab/data/mosquitto/config/mosquitto.conf
```

Contenido recomendado:

```conf
persistence true
persistence_location /mosquitto/data/
autosave_interval 1800

log_dest stdout
connection_messages true
log_timestamp true

listener 1883 0.0.0.0
protocol mqtt

allow_anonymous false
password_file /mosquitto/config/passwd
acl_file /mosquitto/config/acl
```

Permisos del fichero:

```bash
chmod 600 /home/<usuario>/homelab/data/mosquitto/config/mosquitto.conf
```

Qué hace esta configuración:

- activa persistencia para sesiones, mensajes retenidos y estado interno del broker
- deja los logs en `stdout`, que encaja bien con `docker compose logs`
- expone el listener MQTT estándar en `1883`
- obliga a autenticarse a todos los clientes
- separa autenticación (`passwd`) de autorización (`acl`)

### 3. Crear usuarios MQTT

La recomendación es **un usuario por servicio**. Como mínimo:

- `homeassistant`
- `zigbee2mqtt`
- `nodered`
- `mqttadmin` para pruebas o administración

Comando recomendado para crear el fichero de contraseñas sin instalar herramientas adicionales en el host:

```bash
docker run --rm -it \
  -v /home/<usuario>/homelab/data/mosquitto/config:/mosquitto/config \
  eclipse-mosquitto:2 \
  sh -c '
    mosquitto_passwd -c /mosquitto/config/passwd homeassistant &&
    mosquitto_passwd /mosquitto/config/passwd zigbee2mqtt &&
    mosquitto_passwd /mosquitto/config/passwd nodered &&
    mosquitto_passwd /mosquitto/config/passwd mqttadmin
  '
```

Este flujo es preferible a `-b` porque evita dejar contraseñas en el historial del shell.

Buenas prácticas con usuarios:

- no reutilices el mismo usuario para todos los clientes
- usa contraseñas largas y distintas aunque el acceso sea solo interno
- guarda las credenciales en tu gestor de secretos
- si un servicio deja de usarse, elimina también su usuario del `passwd`

### 4. Definir ACLs

Guardar este contenido en:

```text
/home/<usuario>/homelab/data/mosquitto/config/acl
```

ACL inicial recomendada:

```conf
user mqttadmin
topic readwrite #

user homeassistant
topic readwrite homeassistant/#
topic read zigbee2mqtt/#
topic write zigbee2mqtt/+/set
topic write zigbee2mqtt/bridge/request/#

user zigbee2mqtt
topic readwrite zigbee2mqtt/#
topic write homeassistant/#

user nodered
topic read homeassistant/#
topic read zigbee2mqtt/#
topic write zigbee2mqtt/+/set
topic write nodered/#
topic read nodered/#
```

Lectura rápida de estas ACLs:

- `mqttadmin` tiene acceso total para administración y pruebas
- `homeassistant` puede leer descubrimiento y estado, y publicar comandos hacia Zigbee2MQTT
- `zigbee2mqtt` puede publicar sus estados y los mensajes de auto discovery para Home Assistant
- `nodered` queda limitado a sus propios topics y a los topics necesarios para leer estado o enviar órdenes

Esta ACL es una base razonable para la fase de domótica, pero conviene ajustarla cuando ya conozcas tus topics reales.

### 5. Levantar el broker

Una vez guardados `compose.yaml`, `.env`, `mosquitto.conf`, `passwd` y `acl`:

```bash
cd /home/<usuario>/homelab/compose/mosquitto
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f mosquitto
ss -tulpn | grep 1883
```

Si cambias el fichero `acl` o `passwd`, la forma más simple de aplicar cambios es reiniciar el contenedor:

```bash
cd /home/<usuario>/homelab/compose/mosquitto
docker compose restart mosquitto
```

### 6. Probar autenticación y publicación

Prueba básica de suscripción:

```bash
docker run --rm --network host eclipse-mosquitto:2 \
  mosquitto_sub -h 127.0.0.1 -p 1883 -u mqttadmin -P '<tu-password>' -t 'nodered/test' -C 1 -v
```

En otra terminal, publica un mensaje:

```bash
docker run --rm --network host eclipse-mosquitto:2 \
  mosquitto_pub -h 127.0.0.1 -p 1883 -u mqttadmin -P '<tu-password>' -t 'nodered/test' -m 'ok'
```

Resultado esperado:

- la suscripción recibe el mensaje `ok`
- no aparecen errores de autenticación en los logs
- si pruebas con un topic no permitido para un usuario concreto, la operación falla y queda registrada

### 7. Clientes e integración con el resto de la fase

Endpoints recomendados según el cliente:

| Cliente | Host del broker | Puerto |
|---|---|---|
| Home Assistant Container con `network_mode: host` | `127.0.0.1` | `1883` |
| Zigbee2MQTT en stack independiente | `<IP-LAN-de-la-Pi>` | `1883` |
| Node-RED en stack independiente | `<IP-LAN-de-la-Pi>` | `1883` |
| Cliente remoto por Tailscale | `<IP-Tailscale-de-la-Pi>` | `1883` |

Notas importantes:

- `127.0.0.1` solo sirve para procesos que comparten la red del host
- un contenedor en otro stack Compose no debe usar `127.0.0.1` para alcanzar Mosquitto
- si no compartes una red Docker externa entre stacks, usa la IP LAN o la IP Tailscale del host

Integración mínima con Home Assistant:

1. Ir a **Settings > Devices & services**.
2. Pulsar **Add Integration**.
3. Buscar **MQTT**.
4. Introducir `127.0.0.1` como broker si Home Assistant usa `network_mode: host`.
5. Introducir el usuario `homeassistant` y su contraseña.
6. Guardar y comprobar que la integración queda conectada.

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose | `/home/<usuario>/homelab/compose/mosquitto/` | SSD NVMe |
| Variables del stack | `/home/<usuario>/homelab/compose/mosquitto/.env` | SSD NVMe |
| Configuración del broker | `/home/<usuario>/homelab/data/mosquitto/config/mosquitto.conf` | SSD NVMe |
| Fichero de contraseñas | `/home/<usuario>/homelab/data/mosquitto/config/passwd` | SSD NVMe |
| ACLs | `/home/<usuario>/homelab/data/mosquitto/config/acl` | SSD NVMe |
| Persistencia MQTT | `/home/<usuario>/homelab/data/mosquitto/data/` | SSD NVMe |
| Backups exportados | `/mnt/hd2t/backups/mosquitto/` | `hd2t` |

Notas de almacenamiento:

- todo el estado operativo de Mosquitto debe vivir en el **NVMe**
- `hd2t` se usa como destino de backup, no como almacenamiento activo del broker
- el directorio `data/` puede contener mensajes retenidos, sesiones persistentes y base interna del broker
- `passwd` y `acl` forman parte del estado crítico del servicio
- el fichero `passwd` contiene hashes de contraseñas, así que debe tratarse como secreto operativo aunque no guarde las claves en texto plano

## Backup
Conviene respaldar como mínimo:

- `/home/<usuario>/homelab/compose/mosquitto/compose.yaml`
- `/home/<usuario>/homelab/compose/mosquitto/.env`
- `/home/<usuario>/homelab/data/mosquitto/config/mosquitto.conf`
- `/home/<usuario>/homelab/data/mosquitto/config/passwd`
- `/home/<usuario>/homelab/data/mosquitto/config/acl`
- `/home/<usuario>/homelab/data/mosquitto/data/`

Procedimiento recomendado:

```bash
mkdir -p /mnt/hd2t/backups/mosquitto

cd /home/<usuario>/homelab/compose/mosquitto
docker compose stop mosquitto

rsync -a /home/<usuario>/homelab/compose/mosquitto/ /mnt/hd2t/backups/mosquitto/compose/
rsync -a /home/<usuario>/homelab/data/mosquitto/ /mnt/hd2t/backups/mosquitto/data/

docker compose up -d
```

Si el broker solo maneja poca carga, el tiempo de parada será mínimo. Para un backup coherente del directorio `data/`, es preferible detener el contenedor unos minutos.

## Referencias
- Documentación oficial de Mosquitto: <https://mosquitto.org/documentation/>
- Manual de `mosquitto.conf`: <https://mosquitto.org/man/mosquitto-conf-5.html>
- Manual de `mosquitto_passwd`: <https://mosquitto.org/man/mosquitto_passwd-1.html>
- Imagen oficial Docker `eclipse-mosquitto`: <https://hub.docker.com/_/eclipse-mosquitto>
- Integración MQTT de Home Assistant: <https://www.home-assistant.io/integrations/mqtt/>
