# Zigbee2MQTT

## Descripción

**Zigbee2MQTT** conecta el coordinador Zigbee USB del homelab con el resto de servicios mediante **MQTT**. En esta Raspberry Pi 5 actúa como puente entre la red Zigbee física y el bloque lógico formado por **Mosquitto**, **Home Assistant** y, más adelante, **Node-RED**.

Este enfoque evita depender de integraciones propietarias y deja la topología clara:

- el adaptador USB Zigbee se conecta a la Raspberry Pi
- Zigbee2MQTT habla con ese adaptador
- Mosquitto transporta estados y comandos por MQTT
- Home Assistant descubre los dispositivos y los expone como entidades

El servicio se publica solo en la **LAN** y a través de **Tailscale**. No hay exposición directa a Internet.

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](/Users/x441425/workspace2/homelab/docs/01-sistema/04-estructura-directorios.md).
- Haber completado [01-instalacion-docker.md](/Users/x441425/workspace2/homelab/docs/02-docker/01-instalacion-docker.md).
- Haber completado [02-estructura-compose.md](/Users/x441425/workspace2/homelab/docs/02-docker/02-estructura-compose.md).
- Haber desplegado [02-mosquitto.md](/Users/x441425/workspace2/homelab/docs/08-domotica/02-mosquitto.md), porque Zigbee2MQTT necesita un broker MQTT operativo.
- Recomendable haber desplegado [01-home-assistant.md](/Users/x441425/workspace2/homelab/docs/08-domotica/01-home-assistant.md) si quieres discovery automático desde el primer momento.
- Haber revisado [06-puertos-y-firewall.md](/Users/x441425/workspace2/homelab/docs/03-red/06-puertos-y-firewall.md) para registrar el puerto de la interfaz web.
- Tener el coordinador Zigbee conectado por USB a la Raspberry Pi.
- Puertos necesarios en esta fase:
  - **`8080/tcp`** para la interfaz web de Zigbee2MQTT
  - **sin puerto Zigbee expuesto en red**; la comunicación con el coordinador es local por dispositivo USB

## Docker Compose

Archivo: `/home/<user>/homelab/compose/iot-zigbee2mqtt/docker-compose.yml`

```yaml
name: iot-zigbee2mqtt

services:
  zigbee2mqtt:
    image: ghcr.io/koenkk/zigbee2mqtt:latest
    container_name: zigbee2mqtt
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    environment:
      TZ: Europe/Madrid
    ports:
      - "8080:8080"
    volumes:
      - /home/<user>/homelab/data/zigbee2mqtt:/app/data
      - /run/udev:/run/udev:ro
    devices:
      - /dev/serial/by-id/ADAPTADOR_ZIGBEE:/dev/ttyACM0
    labels:
      - com.centurylinklabs.watchtower.enable=false
```

Notas sobre este Compose:

- la ruta en `devices:` debe sustituirse por la ruta real del coordinador en `/dev/serial/by-id/`
- el bind mount de `/run/udev` permite a Zigbee2MQTT detectar correctamente el adaptador
- el puerto `8080` publica la interfaz web local
- se desactiva la actualización automática por Watchtower para evitar cambios inesperados en una pieza crítica de la domótica

## Configuración

### 1. Preparar directorios

```bash
mkdir -p /home/<user>/homelab/compose/iot-zigbee2mqtt
mkdir -p /home/<user>/homelab/data/zigbee2mqtt
```

### 2. Identificar el adaptador USB

Antes de arrancar el contenedor, localiza el coordinador con una ruta estable:

```bash
ls -l /dev/serial/by-id
```

Ejemplo de salida:

```text
usb-ITead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_1234567890abcdef-if00-port0 -> ../../ttyUSB0
```

Usa siempre la ruta de `/dev/serial/by-id/...` tanto en el Compose como en `configuration.yaml`. Evita usar directamente `/dev/ttyUSB0` o `/dev/ttyACM0`, porque puede cambiar entre reinicios.

Si quieres confirmar el destino real:

```bash
readlink -f /dev/serial/by-id/usb-ITead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_1234567890abcdef-if00-port0
```

### 3. Crear `configuration.yaml`

Archivo: `/home/<user>/homelab/data/zigbee2mqtt/configuration.yaml`

```yaml
homeassistant:
  enabled: true

frontend:
  enabled: true
  port: 8080

mqtt:
  server: mqtt://IP_DE_LA_PI:1883
  user: mqtt-zigbee2mqtt
  password: CAMBIAR_PASSWORD
  base_topic: zigbee2mqtt

serial:
  port: /dev/serial/by-id/usb-REEMPLAZAR_POR_TU_ADAPTADOR
  adapter: zstack

advanced:
  log_level: info
```

Puntos importantes:

- `mqtt.server` debe apuntar al broker de [02-mosquitto.md](/Users/x441425/workspace2/homelab/docs/08-domotica/02-mosquitto.md)
- `mqtt.user` y `mqtt.password` deben corresponder al usuario `mqtt-zigbee2mqtt` creado en Mosquitto
- `homeassistant.enabled: true` activa MQTT Discovery para que Home Assistant detecte los dispositivos
- `serial.port` debe ser la misma ruta estable encontrada en `/dev/serial/by-id/`
- `serial.adapter` depende del coordinador concreto; confirma el valor correcto en la documentación oficial del adaptador si `zstack` no corresponde a tu modelo

Si prefieres no dejar credenciales en el fichero principal, puedes guardar usuario y contraseña en un fichero separado y montar la configuración siguiendo el patrón de secretos de Zigbee2MQTT.

### 4. Ajustar el `docker-compose.yml`

Sustituye `ADAPTADOR_ZIGBEE` por el nombre real del coordinador detectado antes. Ejemplo:

```yaml
devices:
  - /dev/serial/by-id/usb-ITead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_1234567890abcdef-if00-port0:/dev/ttyACM0
```

El nombre interno `/dev/ttyACM0` dentro del contenedor puede mantenerse así; lo importante es que el lado izquierdo del mapeo sea correcto.

### 5. Desplegar el stack

```bash
cd /home/<user>/homelab/compose/iot-zigbee2mqtt
docker compose config
docker compose up -d
docker compose ps
docker compose logs -f zigbee2mqtt
```

Resultado esperado:

- el contenedor queda en estado `Up`
- la interfaz web responde en `http://IP_DE_LA_PI:8080`
- los logs muestran conexión correcta al broker MQTT
- no aparecen errores de apertura del puerto serie

### 6. Integración con Home Assistant

Si en `configuration.yaml` has dejado `homeassistant.enabled: true` y Home Assistant ya está conectado al broker MQTT:

1. Abre Home Assistant.
2. Ve a **Settings → Devices & services**.
3. Verifica que la integración **MQTT** ya está operativa.
4. Espera a que los dispositivos emparejados en Zigbee2MQTT aparezcan automáticamente.

En este diseño, **Home Assistant no habla por USB con el coordinador**. Toda la integración pasa por MQTT, que es la forma correcta de mantener los componentes desacoplados.

### 7. Emparejamiento de dispositivos

#### Método recomendado desde la interfaz web

1. Abre `http://IP_DE_LA_PI:8080`.
2. Pulsa **Permit join (All)** en la esquina superior derecha.
3. Pon el dispositivo Zigbee en modo emparejamiento siguiendo las instrucciones del fabricante. Si no las tienes, normalmente el equivalente práctico es hacer un reset de fábrica del dispositivo.
4. Espera a que Zigbee2MQTT complete la entrevista del dispositivo.
5. Renombra el dispositivo con un nombre claro y estable.
6. Asigna el dispositivo al área correcta en Home Assistant cuando aparezca por discovery.

La apertura de la red para emparejamiento debe ser temporal. Cuando termines, cierra manualmente el modo join o deja que expire el temporizador.

#### Emparejamiento dirigido

Si más adelante tienes routers Zigbee repartidos por la casa, Zigbee2MQTT permite abrir el emparejamiento desde un router concreto en lugar de hacerlo siempre desde el coordinador. Eso puede ayudar con dispositivos problemáticos o con altas distancias.

#### Vía MQTT

También puedes permitir emparejamiento por MQTT, lo que resulta útil para automatizaciones o flujos de Node-RED. El topic es:

```text
zigbee2mqtt/bridge/request/permit_join
```

### 8. Validaciones básicas tras el primer emparejamiento

Después de añadir el primer dispositivo, comprueba lo siguiente:

- en Zigbee2MQTT aparece con nombre amigable, modelo y estado
- en Home Assistant se crean las entidades esperadas
- el dispositivo publica estados en `zigbee2mqtt/<friendly_name>`
- los comandos enviados desde Home Assistant llegan y se reflejan en el dispositivo real

Si el dispositivo aparece en Zigbee2MQTT pero no en Home Assistant, revisa primero:

- que la integración MQTT de Home Assistant está conectada
- que `homeassistant.enabled: true` sigue activo
- que el usuario `mqtt-zigbee2mqtt` puede escribir en `homeassistant/#` según la ACL definida en [02-mosquitto.md](/Users/x441425/workspace2/homelab/docs/08-domotica/02-mosquitto.md)

### 9. Problemas habituales

#### El contenedor arranca pero no encuentra el adaptador

Suele deberse a uno de estos motivos:

- ruta incorrecta en `devices:`
- ruta incorrecta en `serial.port`
- tipo de adaptador equivocado en `serial.adapter`
- el coordinador no está realmente expuesto por USB en ese modo

Empieza comprobando otra vez:

```bash
ls -l /dev/serial/by-id
docker compose logs --tail=100 zigbee2mqtt
```

#### El dispositivo no empareja

- verifica si el modelo tiene instrucciones específicas en la base oficial de dispositivos soportados
- acerca temporalmente el dispositivo al coordinador
- repite el reset de fábrica antes de un nuevo intento
- cierra y vuelve a abrir el modo join

#### Home Assistant no descubre nada

- revisa las credenciales MQTT
- confirma que Mosquitto está escuchando en `1883`
- confirma que Zigbee2MQTT está publicando en `zigbee2mqtt/#`
- revisa la ACL del usuario `mqtt-zigbee2mqtt`

## Almacenamiento

Todo el estado de Zigbee2MQTT debe residir en el **SSD NVMe** bajo `/home/<user>/homelab/data/zigbee2mqtt/`.

Contenido típico de esta ruta:

- `configuration.yaml`
- `database.db`
- `state.json`
- ficheros de backup del coordinador si la aplicación los genera

No guardes este estado en `hd2t` ni en `hd5t`. Aunque no ocupe mucho, es un servicio operativo y debe permanecer en el SSD junto al resto de configuraciones del homelab.

### Permisos

- la ruta bind-mounted debe ser escribible por el contenedor
- si restauras desde backup, revisa permisos antes de arrancar
- evita editar estos ficheros desde varios sitios a la vez mientras el contenedor está levantado

## Backup

Respaldar:

- `/home/<user>/homelab/compose/iot-zigbee2mqtt/docker-compose.yml`
- `/home/<user>/homelab/data/zigbee2mqtt/`

Especialmente importantes:

- `configuration.yaml`
- `database.db`
- `state.json`
- cualquier backup del coordinador generado por Zigbee2MQTT

Este punto es crítico: si pierdes el estado interno de Zigbee2MQTT, puedes perder el mapeo lógico de la red Zigbee y verte obligado a reemparejar dispositivos.

Recomendaciones:

- para un backup conservador, detén brevemente el contenedor antes de copiar `database.db` y `state.json`
- integra esta ruta más adelante en [02-borgmatic.md](/Users/x441425/workspace2/homelab/docs/07-backups/02-borgmatic.md)
- conserva al menos una copia adicional fuera del SSD NVMe

## Referencias

- Documentación oficial de instalación con Docker: https://www.zigbee2mqtt.io/guide/installation/02_docker.html
- Documentación oficial de configuración del adaptador: https://www.zigbee2mqtt.io/guide/configuration/adapter-settings.html
- Documentación oficial de configuración MQTT: https://www.zigbee2mqtt.io/guide/configuration/mqtt.html
- Documentación oficial de integración con Home Assistant: https://www.zigbee2mqtt.io/guide/configuration/homeassistant.html
- Documentación oficial de emparejamiento: https://www.zigbee2mqtt.io/guide/usage/pairing_devices.html
- Imagen oficial del contenedor: https://github.com/Koenkk/zigbee2mqtt/pkgs/container/zigbee2mqtt
