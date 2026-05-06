# Zigbee2MQTT

## Descripción
**Zigbee2MQTT** será la pieza que conecte la red Zigbee física del homelab con el resto de la automatización por **MQTT**. Su función es controlar el coordinador Zigbee USB, incorporar sensores, interruptores, enchufes o bombillas, y publicar su estado en el broker para que **Home Assistant** y **Node-RED** puedan consumirlo.

En este diseño se desplegará como un stack Docker independiente, con estas decisiones:

- un único coordinador Zigbee USB dedicado al servicio
- integración con **Mosquitto** como broker MQTT
- descubrimiento automático en **Home Assistant** vía MQTT
- persistencia completa en el **SSD NVMe**
- acceso a la UI solo por **LAN + Tailscale**
- sin exposición pública a internet

La topología queda así:

```text
dispositivos Zigbee
        |
        v
coordinador Zigbee USB
        |
        v
   Zigbee2MQTT
        |
        v
    Mosquitto
      /    \
     v      v
Home Assistant
Node-RED
```

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber desplegado `docs/08-domotica/02-mosquitto.md`, ya que Zigbee2MQTT depende de un broker MQTT operativo.
- Haber desplegado `docs/08-domotica/01-home-assistant.md` si quieres discovery automático desde el primer momento.
- Tener un coordinador Zigbee compatible conectado por USB y funcionando en modo coordinador.
- Tener claro qué familia usa tu adaptador para ajustar `serial.adapter`:
  - `zstack` para coordinadores basados en Texas Instruments CC2652/CC1352
  - `ember` para coordinadores basados en Silicon Labs EFR32
- Conectar el dongle con un alargador USB corto y separarlo físicamente de la Raspberry Pi, del SSD NVMe y de puertos USB 3.0 para reducir interferencias en 2,4 GHz.
- Confirmar que **ningún otro servicio** está usando el mismo coordinador:
  - no activar ZHA en Home Assistant
  - no conectar el dongle a otra VM, contenedor o software en paralelo
- Puertos y recursos implicados:
  - `8080/tcp` publicado en el host para la UI web de Zigbee2MQTT
  - acceso saliente al broker MQTT por `1883/tcp`
  - acceso al dispositivo serie USB del coordinador (`/dev/ttyUSB*`, `/dev/ttyACM*` o ruta estable `/dev/serial/by-id/...`)

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/zigbee2mqtt/
├── compose.yaml
└── .env
```

Directorio de datos recomendado:

```text
/home/<usuario>/homelab/data/zigbee2mqtt/
└── data/
    └── configuration.yaml
```

Fichero `.env` recomendado:

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000
DIALOUT_GID=20
Z2M_BASE_DIR=/home/<usuario>/homelab/data/zigbee2mqtt
Z2M_DEVICE=/dev/serial/by-id/<id-del-adaptador-zigbee>
```

Notas sobre estas variables:

- `Z2M_DEVICE` debe apuntar a la ruta estable del coordinador en `/dev/serial/by-id/`.
- `DIALOUT_GID` suele ser `20` en Raspberry Pi OS, pero conviene comprobarlo con `getent group dialout` y validar el grupo real del dispositivo serie.
- el contenedor montará el coordinador como `/dev/zigbee`, de modo que el `configuration.yaml` no dependa del nombre real `ttyUSB0` o `ttyACM0`.

Fichero `compose.yaml`:

```yaml
name: zigbee2mqtt

services:
  zigbee2mqtt:
    image: ghcr.io/koenkk/zigbee2mqtt:latest
    restart: unless-stopped
    user: "${PUID}:${PGID}"
    group_add:
      - "${DIALOUT_GID}"
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    ports:
      - "8080:8080"
    volumes:
      - ${Z2M_BASE_DIR}/data:/app/data
      - /run/udev:/run/udev:ro
    devices:
      - "${Z2M_DEVICE}:/dev/zigbee"
    labels:
      com.centurylinklabs.watchtower.enable: "true"
```

Despliegue inicial:

```bash
mkdir -p /home/<usuario>/homelab/compose/zigbee2mqtt
mkdir -p /home/<usuario>/homelab/data/zigbee2mqtt/data

sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/zigbee2mqtt
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/zigbee2mqtt

cd /home/<usuario>/homelab/compose/zigbee2mqtt
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f zigbee2mqtt
```

Resultado esperado:

- el contenedor `zigbee2mqtt-zigbee2mqtt-1` queda levantado
- la UI queda accesible en `http://<IP-del-host>:8080`
- la configuración y la base de dispositivos quedan persistidas en `/home/<usuario>/homelab/data/zigbee2mqtt/data/`
- los dispositivos Zigbee se integrarán en Home Assistant a través de Mosquitto, no por acceso directo al dongle

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| Servicio | Zigbee2MQTT en Docker |
| UI web | `http://<IP-del-host>:8080` |
| Broker MQTT | Mosquitto en `1883/tcp` |
| Discovery de Home Assistant | activado |
| Puerto serie dentro del contenedor | `/dev/zigbee` |
| Persistencia | `/home/<usuario>/homelab/data/zigbee2mqtt/data/` |
| Ventana de emparejamiento | cerrada por defecto |

### 1. Identificar el adaptador USB

Antes de escribir la configuración, localiza la ruta estable del coordinador:

```bash
ls -l /dev/serial/by-id/
```

Salida esperada, similar a esta:

```text
/dev/serial/by-id/usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_1234567890-if00-port0 -> ../../ttyUSB0
```

Comprobaciones útiles:

```bash
readlink -f /dev/serial/by-id/<id-del-adaptador-zigbee>
ls -l "$(readlink -f /dev/serial/by-id/<id-del-adaptador-zigbee>)"
getent group dialout
id -u <usuario>
id -g <usuario>
```

Qué debes decidir aquí:

- la ruta exacta que pondrás en `Z2M_DEVICE`
- el valor de `serial.adapter`
- si el usuario y grupos del contenedor tienen permisos sobre el dispositivo

Guía rápida para `serial.adapter`:

- usa `zstack` si tu coordinador está basado en chips TI CC2652 o CC1352
- usa `ember` si tu coordinador está basado en Silicon Labs EFR32
- si tu hardware es distinto, revisa su familia antes de arrancar el contenedor

### 2. Preparar directorios y permisos

Crear la estructura:

```bash
mkdir -p /home/<usuario>/homelab/compose/zigbee2mqtt
mkdir -p /home/<usuario>/homelab/data/zigbee2mqtt/data
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/zigbee2mqtt
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/zigbee2mqtt

chmod 755 /home/<usuario>/homelab/data/zigbee2mqtt
chmod 750 /home/<usuario>/homelab/data/zigbee2mqtt/data
```

Si `PUID`, `PGID` o `DIALOUT_GID` no coinciden con tu sistema, ajústalos antes de levantar el stack.

### 3. Crear `configuration.yaml`

Guardar este contenido en:

```text
/home/<usuario>/homelab/data/zigbee2mqtt/data/configuration.yaml
```

Contenido recomendado:

```yaml
version: 5

mqtt:
  base_topic: zigbee2mqtt
  server: mqtt://<IP-LAN-de-la-Pi>:1883
  user: zigbee2mqtt
  password: <password-zigbee2mqtt>

serial:
  port: /dev/zigbee
  adapter: zstack

frontend:
  enabled: true
  port: 8080

homeassistant:
  enabled: true

advanced:
  channel: 11
  network_key: GENERATE
  pan_id: GENERATE
  ext_pan_id: GENERATE
  log_level: info

permit_join: false
```

Ajustes importantes:

- cambia `mqtt.server` para apuntar a la IP LAN o Tailscale del host donde corre Mosquitto
- sustituye usuario y contraseña por las credenciales reales definidas en `docs/08-domotica/02-mosquitto.md`
- cambia `serial.adapter: zstack` por `ember` si tu coordinador pertenece a esa familia
- deja `network_key`, `pan_id` y `ext_pan_id` en `GENERATE` solo en el arranque inicial; Zigbee2MQTT los sustituirá por valores reales persistentes
- deja `permit_join: false` para no dejar la red abierta permanentemente

Si no compartes una red Docker externa entre stacks, **no** uses `127.0.0.1` como broker desde Zigbee2MQTT. Al estar en otro stack, debe conectar contra la IP del host.

### 4. Levantar el stack y validar el arranque

Una vez guardados `compose.yaml`, `.env` y `configuration.yaml`:

```bash
cd /home/<usuario>/homelab/compose/zigbee2mqtt
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f zigbee2mqtt
ss -tulpn | grep 8080
```

Abrir en el navegador:

```text
http://<IP-del-host>:8080
```

Si el arranque falla por el coordinador, revisa en este orden:

1. que la ruta `Z2M_DEVICE` existe realmente
2. que `serial.adapter` coincide con el tipo de hardware
3. que ningún otro software está usando el dongle
4. que el usuario del contenedor tiene acceso al grupo del dispositivo

Errores típicos a descartar:

- ruta a `/dev/serial/by-id/...` incorrecta
- usar `zstack` con hardware `ember`, o al revés
- dejar ZHA activo en Home Assistant
- mapear `ttyUSB0` o `ttyACM0` directamente y que cambie tras un reinicio

### 5. Integración con Mosquitto y Home Assistant

Cuando Zigbee2MQTT consiga conectar con Mosquitto:

- publicará sus topics bajo `zigbee2mqtt/#`
- enviará mensajes de discovery para Home Assistant
- Home Assistant empezará a crear entidades cuando vayas emparejando dispositivos

Comprobaciones mínimas:

1. Verificar que la integración MQTT de Home Assistant está conectada.
2. Entrar en la UI de Zigbee2MQTT y confirmar que el estado del broker es correcto.
3. Revisar en Home Assistant si aparecen nuevos dispositivos MQTT cuando se empareja el primer nodo.

Topología recomendada de conexión:

| Cliente | Host MQTT | Puerto |
|---|---|---|
| Zigbee2MQTT | `<IP-LAN-de-la-Pi>` | `1883` |
| Home Assistant con `network_mode: host` | `127.0.0.1` | `1883` |
| Node-RED en stack independiente | `<IP-LAN-de-la-Pi>` | `1883` |

### 6. Emparejamiento de dispositivos

Flujo recomendado para emparejar:

1. Abrir la UI de Zigbee2MQTT en `http://<IP-del-host>:8080`.
2. Pulsar **Permit join (All)**.
3. Poner el dispositivo en modo pairing siguiendo el procedimiento del fabricante.
4. Esperar a que termine la entrevista inicial.
5. Cambiar el nombre amigable del dispositivo en Zigbee2MQTT.
6. Comprobar que aparece en Home Assistant por discovery MQTT.
7. Cerrar la ventana de emparejamiento si no se ha cerrado sola.

Buenas prácticas durante el pairing:

- empareja cerca del coordinador la primera vez y después mueve el dispositivo a su ubicación final
- no dejes `permit_join` abierto fuera de ventanas controladas
- si el dispositivo venía de otra red Zigbee, haz reset de fábrica antes de intentar unirlo
- los dispositivos alimentados a red pueden actuar como routers y mejorar la malla

También puedes abrir la red por MQTT durante un tiempo concreto:

```bash
docker run --rm --network host eclipse-mosquitto:2 \
  mosquitto_pub -h 127.0.0.1 -p 1883 -u mqttadmin -P '<tu-password>' \
  -t 'zigbee2mqtt/bridge/request/permit_join' \
  -m '{"time": 120}'
```

Resultado esperado tras el primer emparejamiento:

- el dispositivo aparece en la UI de Zigbee2MQTT con su nombre o IEEE address
- se crean entidades en Home Assistant
- empiezan a publicarse estados en `zigbee2mqtt/<friendly_name>`

### 7. Cambios de configuración y reinicios

Si modificas `configuration.yaml` manualmente:

```bash
cd /home/<usuario>/homelab/compose/zigbee2mqtt
docker compose restart zigbee2mqtt
```

Para revisar errores recientes:

```bash
cd /home/<usuario>/homelab/compose/zigbee2mqtt
docker compose logs --tail=100 zigbee2mqtt
```

Evita cambiar estos parámetros una vez tengas muchos dispositivos emparejados:

- `advanced.channel`
- `advanced.network_key`
- `advanced.pan_id`
- `advanced.ext_pan_id`

Cambiar esos valores puede obligarte a reemparejar parte o toda la red Zigbee.

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose | `/home/<usuario>/homelab/compose/zigbee2mqtt/` | SSD NVMe |
| Variables del stack | `/home/<usuario>/homelab/compose/zigbee2mqtt/.env` | SSD NVMe |
| Configuración principal | `/home/<usuario>/homelab/data/zigbee2mqtt/data/configuration.yaml` | SSD NVMe |
| Base de dispositivos y red | `/home/<usuario>/homelab/data/zigbee2mqtt/data/database.db` | SSD NVMe |
| Estado persistente | `/home/<usuario>/homelab/data/zigbee2mqtt/data/state.json` | SSD NVMe |
| Backup del coordinador | `/home/<usuario>/homelab/data/zigbee2mqtt/data/coordinator_backup.json` | SSD NVMe |
| Logs y ficheros auxiliares | `/home/<usuario>/homelab/data/zigbee2mqtt/data/` | SSD NVMe |
| Backups exportados | `/mnt/hd2t/backups/zigbee2mqtt/` | `hd2t` |

Notas de almacenamiento:

- todo el estado operativo debe quedarse en el **SSD NVMe**
- `hd2t` se reserva como destino de backup, no como almacenamiento activo
- el directorio `data/` es el activo principal del servicio
- perder `database.db`, `state.json` o `coordinator_backup.json` complica mucho una recuperación limpia de la red

## Backup
Conviene respaldar como mínimo:

- `/home/<usuario>/homelab/compose/zigbee2mqtt/compose.yaml`
- `/home/<usuario>/homelab/compose/zigbee2mqtt/.env`
- `/home/<usuario>/homelab/data/zigbee2mqtt/data/configuration.yaml`
- `/home/<usuario>/homelab/data/zigbee2mqtt/data/database.db`
- `/home/<usuario>/homelab/data/zigbee2mqtt/data/state.json`
- `/home/<usuario>/homelab/data/zigbee2mqtt/data/coordinator_backup.json`
- el resto del directorio `/home/<usuario>/homelab/data/zigbee2mqtt/data/`

Procedimiento recomendado:

```bash
mkdir -p /mnt/hd2t/backups/zigbee2mqtt

cd /home/<usuario>/homelab/compose/zigbee2mqtt
docker compose stop zigbee2mqtt

rsync -a /home/<usuario>/homelab/compose/zigbee2mqtt/ /mnt/hd2t/backups/zigbee2mqtt/compose/
rsync -a /home/<usuario>/homelab/data/zigbee2mqtt/ /mnt/hd2t/backups/zigbee2mqtt/data/

docker compose up -d
```

Notas importantes para recuperación:

- si restauras Zigbee2MQTT en otra Raspberry Pi o tras sustituir el coordinador, conserva también el backup del coordinador
- si cambias de familia de adaptador, puede haber dispositivos que necesiten reemparejarse
- una restauración parcial del directorio `data/` suele dar peores resultados que restaurar el conjunto completo

## Referencias
- Documentación oficial de Zigbee2MQTT: <https://www.zigbee2mqtt.io/>
- Guía oficial de instalación con Docker: <https://www.zigbee2mqtt.io/guide/installation/02_docker.html>
- Configuración oficial: <https://www.zigbee2mqtt.io/guide/configuration/>
- Adaptadores soportados y familias: <https://www.zigbee2mqtt.io/guide/adapters/>
- Emparejamiento y `permit_join`: <https://www.zigbee2mqtt.io/guide/usage/pairing_devices.html>
- Integración MQTT de Home Assistant: <https://www.home-assistant.io/integrations/mqtt/>
- Imagen oficial del contenedor: <https://github.com/Koenkk/zigbee2mqtt/pkgs/container/zigbee2mqtt>
