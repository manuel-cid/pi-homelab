# Node-RED

## Descripción

**Node-RED** aporta la capa visual de automatización del bloque de domótica. En este homelab se usa para construir flujos que conectan **Home Assistant**, **Mosquitto** y, cuando exista, **Zigbee2MQTT**, sin depender solo del editor nativo de automatizaciones de Home Assistant.

Encaja especialmente bien para:

- automatizaciones con varias condiciones y ramas
- transformación de mensajes MQTT
- temporizadores, reintentos y lógica intermedia
- depuración visual de eventos y estados

El servicio se publica solo en la **LAN** y a través de **Tailscale**. No hay exposición directa a Internet.

Cuando en este documento aparezcan `IP_DE_LA_PI`, `NOMBRE_DEL_HOST.<tailnet>.ts.net` o `/home/<user>/...`, sustitúyelos por los valores reales de tu entorno.

## Requisitos Previos

- Haber completado [04-estructura-directorios.md](../01-sistema/04-estructura-directorios.md).
- Haber completado [01-instalacion-docker.md](../02-docker/01-instalacion-docker.md).
- Haber completado [02-estructura-compose.md](../02-docker/02-estructura-compose.md).
- Haber desplegado [01-home-assistant.md](01-home-assistant.md) para integrar Node-RED con Home Assistant.
- Haber desplegado [02-mosquitto.md](02-mosquitto.md) para usar MQTT desde los flujos.
- Recomendable haber desplegado [03-zigbee2mqtt.md](03-zigbee2mqtt.md) si vas a automatizar dispositivos Zigbee desde el primer momento.
- Haber revisado [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md) para registrar el puerto del editor web.
- Si se quiere acceso remoto, tener operativa la VPN de [04-tailscale.md](../03-red/04-tailscale.md).
- Puertos necesarios en esta fase:
  - **`13002/tcp`** en el host para publicar la interfaz web de Node-RED (`1880/tcp` dentro del contenedor)

## Docker Compose

Archivo: `/home/<user>/homelab/compose/iot-node-red/docker-compose.yml`

```yaml
name: iot-node-red

services:
  node-red:
    image: nodered/node-red:4
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    ports:
      - "${NODE_RED_BIND_IP}:${NODE_RED_PORT}:1880"
    volumes:
      - ${DATA_ROOT}/node-red:/data
    networks:
      - default
      - proxy
    labels:
      - wud.watch=false

networks:
  proxy:
    external: true
    name: ${PROXY_NETWORK}
```

Archivo recomendado: `/home/<user>/homelab/compose/iot-node-red/.env`

```dotenv
TZ=Europe/Madrid
DATA_ROOT=/home/<user>/homelab/data
NODE_RED_BIND_IP=0.0.0.0
NODE_RED_PORT=13002
PROXY_NETWORK=homelab_proxy
```

Este stack sigue el mismo patrón que el resto de la fase:

- `docker-compose.yml` dentro de `compose/`
- `.env` junto al Compose para no fijar rutas y puertos en duro
- persistencia en `data/`
- puerto publicado en el host para clientes en LAN y Tailscale
- union adicional a `homelab_proxy` para poder poner Node-RED detras de Caddy sin rehacer el stack
- sin secretos en el Compose
- actualizaciones manuales para evitar romper flujos o nodos contrib en un momento inoportuno

## Configuración

### 1. Preparar directorios

```bash
mkdir -p /home/<user>/homelab/compose/iot-node-red
mkdir -p /home/<user>/homelab/data/node-red
chmod 700 /home/<user>/homelab/data/node-red
sudo chown -R 1000:1000 /home/<user>/homelab/data/node-red
```

La imagen oficial de Node-RED usa por defecto el UID/GID `1000` dentro del contenedor. Si la ruta bind-mounted no pertenece a ese usuario, suelen aparecer errores al guardar flujos, instalar nodos o escribir contexto persistente.

Si la red compartida del proxy aun no existe, creala una sola vez:

```bash
docker network inspect homelab_proxy >/dev/null 2>&1 || docker network create homelab_proxy
```

Guarda tambien el `.env` del apartado Compose y, como contiene parametros operativos del stack, restringe permisos:

```bash
chmod 600 /home/<user>/homelab/compose/iot-node-red/.env
```

### 2. Desplegar el stack por primera vez

```bash
cd /home/<user>/homelab/compose/iot-node-red
docker compose config
docker compose up -d
docker compose ps
docker compose logs -f node-red
```

Tras el primer arranque, la interfaz queda disponible en:

- `http://IP_DE_LA_PI:13002`
- `http://NOMBRE_DEL_HOST.<tailnet>.ts.net:13002` si accedes por Tailscale con MagicDNS

Este primer inicio crea en `/home/<user>/homelab/data/node-red/` los ficheros base del runtime, incluido `settings.js`.

Si prefieres publicar Node-RED solo detras de [05-caddy.md](../03-red/05-caddy.md), cambia `NODE_RED_BIND_IP=127.0.0.1` en el `.env` antes de levantar el stack o elimina directamente el bloque `ports:` si vas a exponerlo solo por la red Docker compartida `homelab_proxy`.

### 3. Ajustar `settings.js`

Archivo: `/home/<user>/homelab/data/node-red/settings.js`

Antes de empezar a crear flujos reales, conviene editar el fichero generado y ajustar al menos estos puntos:

```javascript
module.exports = {
    credentialSecret: "CAMBIAR_POR_UN_SECRETO_LARGO_Y_UNICO",

    contextStorage: {
        default: {
            module: "localfilesystem"
        }
    }
}
```

Qué aporta cada ajuste:

- `credentialSecret` evita que las credenciales de los nodos queden cifradas con una clave generada al vuelo, que se perderia al restaurar o reconstruir el contenedor.
- `contextStorage` en `localfilesystem` hace persistente el contexto de flujos y global, lo que resulta util para temporizadores, contadores y estados que no deben perderse tras reiniciar Node-RED.

No hace falta reemplazar el fichero entero por el fragmento anterior. Lo correcto es localizar esas opciones en el `settings.js` generado y modificarlas alli.

Aplica el cambio reiniciando el contenedor:

```bash
cd /home/<user>/homelab/compose/iot-node-red
docker compose restart node-red
```

### 4. Endurecimiento minimo recomendado

En una LAN domestica de confianza puede bastar con restringir el acceso por red, pero el editor de Node-RED sigue siendo una superficie potente. Al menos una de estas medidas deberia aplicarse si vas a acceder desde varios dispositivos:

- publicar Node-RED detras de [05-caddy.md](../03-red/05-caddy.md) y protegerlo con [01-authelia.md](../04-seguridad/01-authelia.md)
- o bien activar autenticacion propia del editor mediante `adminAuth` en `settings.js`

Si no vas a ponerlo detras de Caddy, la opcion mas simple es mantenerlo accesible solo por IP interna y por Tailscale en `13002/tcp`, que es el puerto reservado para este servicio en [06-puertos-y-firewall.md](../03-red/06-puertos-y-firewall.md).

### 5. Instalar la integracion con Home Assistant

Los nodos MQTT ya vienen en la instalacion base de Node-RED. Para Home Assistant hay que instalar el paquete `node-red-contrib-home-assistant-websocket`.

Metodo recomendado:

1. Abre Node-RED en `http://IP_DE_LA_PI:13002`.
2. Ve a **Menu -> Manage palette -> Install**.
3. Busca `node-red-contrib-home-assistant-websocket`.
4. Instala el paquete y espera a que Node-RED termine de reiniciar internamente.

Alternativa por linea de comandos:

```bash
cd /home/<user>/homelab/compose/iot-node-red
docker compose exec node-red sh -lc 'cd /data && npm install --no-update-notifier --no-fund --omit=dev node-red-contrib-home-assistant-websocket'
docker compose restart node-red
```

### 6. Crear el servidor de Home Assistant

Cuando ya aparezcan los nodos nuevos, crea la conexion con Home Assistant:

1. Arrastra un nodo **events: state** o **action** al lienzo.
2. Pulsa el icono de lapiz en el campo **Server**.
3. En **Base URL** usa `http://IP_DE_LA_PI:8123`.
4. Crea un **Long-Lived Access Token** desde el perfil del usuario en Home Assistant.
5. Pega el token en la configuracion del servidor y guarda.
6. Despliega los cambios.

Recomendaciones practicas:

- crea un usuario dedicado en Home Assistant para Node-RED, por ejemplo `nodered`
- ese usuario deberia pertenecer al grupo administrador para evitar limitaciones con los nodos del paquete
- guarda el token solo en las credenciales de Node-RED, no en nodos `inject` ni en texto plano dentro de un `function`

Si la conexion es correcta, los nodos de Home Assistant mostraran estado **connected**.

### 7. Crear el servidor MQTT

Configura un broker MQTT reutilizable para todos los flujos:

1. Arrastra un nodo **mqtt in** o **mqtt out**.
2. Crea un nuevo **MQTT Config**.
3. Rellena:
   - Host: `IP_DE_LA_PI`
   - Puerto: `1883`
   - Usuario: `mqtt-nodered`
   - Contraseña: la creada en [02-mosquitto.md](02-mosquitto.md)
4. Guarda y despliega.

Pruebas minimas recomendadas:

- suscribirte a `zigbee2mqtt/#`
- publicar manualmente un mensaje en `nodered/test`
- comprobar desde Mosquitto que las ACL del usuario `mqtt-nodered` cubren solo los topics necesarios

### 8. Flujos de ejemplo

#### Ejemplo 1: MQTT -> Home Assistant

Caso tipico: un boton Zigbee publica una accion por MQTT y Node-RED conmuta una luz de Home Assistant.

Flujo logico:

1. Nodo `mqtt in`
   - Topic: `zigbee2mqtt/boton_entrada/action`
2. Nodo `switch`
   - Condicion: `msg.payload == "single"`
3. Nodo `action`
   - Domain: `light`
   - Service: `toggle`
   - Entity ID: `light.salon`
4. Nodo `debug`

Uso:

- desacopla el evento MQTT del modelo interno de Home Assistant
- permite insertar facilmente esperas, condiciones horarias o comprobaciones adicionales

#### Ejemplo 2: Home Assistant -> MQTT

Caso tipico: al activar un helper en Home Assistant se manda un comando MQTT a Zigbee2MQTT.

Flujo logico:

1. Nodo `events: state`
   - Entity: `input_boolean.modo_noche`
2. Nodo `switch`
   - Condicion: nuevo estado `on`
3. Nodo `change`
   - `msg.topic = "zigbee2mqtt/lampara_dormitorio/set"`
   - `msg.payload = {"state":"OFF"}`
4. Nodo `mqtt out`

Uso:

- permite que Home Assistant siga siendo la capa principal de entidades
- delega en Node-RED la logica de orquestacion y transformacion de mensajes

#### Ejemplo 3: prueba minima de conectividad MQTT

Este flujo sirve para validar rapidamente que Node-RED puede publicar y suscribirse al broker.

```json
[
  {
    "id": "flow_test_mqtt",
    "type": "tab",
    "label": "Test MQTT",
    "disabled": false,
    "info": ""
  },
  {
    "id": "inject_test_mqtt",
    "type": "inject",
    "z": "flow_test_mqtt",
    "name": "Publicar prueba",
    "props": [
      {
        "p": "payload"
      }
    ],
    "repeat": "",
    "crontab": "",
    "once": false,
    "onceDelay": 0.1,
    "topic": "",
    "payload": "{\"ping\":\"ok\"}",
    "payloadType": "json",
    "x": 160,
    "y": 80,
    "wires": [
      [
        "mqtt_out_test"
      ]
    ]
  },
  {
    "id": "mqtt_out_test",
    "type": "mqtt out",
    "z": "flow_test_mqtt",
    "name": "Enviar a nodered/test",
    "topic": "nodered/test",
    "qos": "",
    "retain": "",
    "respTopic": "",
    "contentType": "",
    "userProps": "",
    "correl": "",
    "expiry": "",
    "broker": "mqtt_broker_main",
    "x": 430,
    "y": 80,
    "wires": []
  },
  {
    "id": "mqtt_in_test",
    "type": "mqtt in",
    "z": "flow_test_mqtt",
    "name": "Escuchar nodered/test",
    "topic": "nodered/test",
    "qos": "0",
    "datatype": "auto-detect",
    "broker": "mqtt_broker_main",
    "nl": false,
    "rap": true,
    "rh": 0,
    "inputs": 0,
    "x": 180,
    "y": 160,
    "wires": [
      [
        "debug_mqtt_test"
      ]
    ]
  },
  {
    "id": "debug_mqtt_test",
    "type": "debug",
    "z": "flow_test_mqtt",
    "name": "Ver mensaje",
    "active": true,
    "tosidebar": true,
    "console": false,
    "tostatus": false,
    "complete": "true",
    "targetType": "full",
    "x": 430,
    "y": 160,
    "wires": []
  },
  {
    "id": "mqtt_broker_main",
    "type": "mqtt-broker",
    "name": "Mosquitto",
    "broker": "IP_DE_LA_PI",
    "port": "1883",
    "clientid": "",
    "autoConnect": true,
    "usetls": false,
    "protocolVersion": "4",
    "keepalive": "60",
    "cleansession": true,
    "birthTopic": "",
    "birthQos": "0",
    "birthPayload": "",
    "closeTopic": "",
    "closeQos": "0",
    "closePayload": "",
    "willTopic": "",
    "willQos": "0",
    "willPayload": "",
    "userProps": "",
    "sessionExpiry": ""
  }
]
```

Importa el JSON desde **Menu -> Import -> Clipboard**, ajusta la IP del broker y anade las credenciales del usuario `mqtt-nodered` en el nodo de broker.

### 9. Buenas practicas operativas

- usa nombres de flujo claros por dominio, por ejemplo `iluminacion`, `presencia` o `clima`
- evita poner credenciales en nodos `function` o en `change`
- reutiliza un solo servidor MQTT y un solo servidor Home Assistant por entorno
- documenta topics, entidades y helpers antes de escalar el numero de flujos
- despliega con `Modified Flows` o `Modified Nodes` cuando sea posible para reducir interrupciones
- si un flujo empieza a crecer demasiado, separalo en subflows o pestañas independientes

### 10. Problemas habituales

#### Node-RED arranca pero no guarda cambios

Suele deberse a permisos incorrectos sobre `/home/<user>/homelab/data/node-red`.

Comprueba:

```bash
ls -ld /home/<user>/homelab/data/node-red
docker compose logs --tail=100 node-red
```

#### Los nodos de Home Assistant quedan en `connecting`

Revisa:

- URL base correcta, normalmente `http://IP_DE_LA_PI:8123`
- token valido y copiado completo
- conectividad real entre contenedores y host
- que Home Assistant no este detras de un proxy mal configurado

#### MQTT conecta pero no llegan mensajes

Revisa:

- host y puerto del broker
- usuario `mqtt-nodered` y su contraseña
- ACLs en [02-mosquitto.md](02-mosquitto.md)
- topic exacto y formato de payload esperado

## Almacenamiento

Todo el estado de Node-RED debe residir en el **SSD NVMe** bajo `/home/<user>/homelab/data/node-red/`.

Contenido habitual de esta ruta:

- `settings.js`
- `flows.json`
- `flows_cred.json`
- `.config.runtime.json`
- `package.json` y `package-lock.json` si instalas nodos adicionales
- `node_modules/` para nodos contrib instalados
- `context/` si activas `localfilesystem`
- `lib/` si guardas funciones o recursos auxiliares

No uses `hd2t` ni `hd5t` para este servicio. Node-RED forma parte del plano operativo del homelab y debe mantenerse junto al resto de configuraciones en el SSD.

### Permisos

- la ruta bind-mounted debe ser escribible por el UID `1000`
- `flows_cred.json` contiene credenciales cifradas y debe tratarse como material sensible
- si restauras desde backup, revisa propietario y permisos antes de arrancar el contenedor

## Backup

Respaldar:

- `/home/<user>/homelab/compose/iot-node-red/docker-compose.yml`
- `/home/<user>/homelab/compose/iot-node-red/.env`
- `/home/<user>/homelab/data/node-red/`

Especialmente importantes:

- `settings.js`
- `flows.json`
- `flows_cred.json`
- `context/`
- `package.json` y `package-lock.json` si existen

Recomendaciones:

- para una copia conservadora, detén brevemente el contenedor antes del backup si acabas de desplegar cambios o instalar nodos
- conserva el `credentialSecret` usado en `settings.js`; sin el, `flows_cred.json` no sera reutilizable
- integra esta ruta mas adelante en [02-borgmatic.md](../07-backups/02-borgmatic.md)

Ejemplo de parada breve:

```bash
cd /home/<user>/homelab/compose/iot-node-red
docker compose stop node-red
# ejecutar backup
docker compose start node-red
```

## Referencias

- Documentacion oficial de Node-RED en Docker: https://nodered.org/docs/getting-started/docker
- Documentacion oficial de contexto persistente: https://nodered.org/docs/user-guide/context
- Cookbook oficial de MQTT en Node-RED: https://cookbook.nodered.org/mqtt/
- Documentacion oficial de `node-red-contrib-home-assistant-websocket`: https://zachowj.github.io/node-red-contrib-home-assistant-websocket/guide/
- Documentacion oficial de autenticacion de Home Assistant: https://developers.home-assistant.io/docs/auth_api/
- Imagen oficial Docker de Node-RED: https://hub.docker.com/r/nodered/node-red
