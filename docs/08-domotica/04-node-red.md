# Node-RED

## Descripción
**Node-RED** será la capa de automatización visual del bloque de domótica del homelab. Su función es construir flujos basados en eventos para conectar **MQTT**, **Home Assistant**, peticiones HTTP, transformaciones de datos y lógica personalizada sin depender únicamente de las automatizaciones YAML de Home Assistant.

En este diseño se desplegará como un stack Docker independiente, con estas decisiones:

- interfaz web publicada solo en **LAN + Tailscale**
- persistencia completa en el **SSD NVMe**
- integración con **Mosquitto** como broker MQTT
- integración con **Home Assistant** mediante nodos dedicados
- sin exposición pública a internet
- flujos, credenciales y nodos extra guardados fuera del contenedor

La topología queda así:

```text
dispositivos / eventos / APIs
            |
            v
         Node-RED
        /        \
       v          v
   Mosquitto   Home Assistant
       ^
       |
 Zigbee2MQTT
```

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber desplegado `docs/08-domotica/02-mosquitto.md`, ya que la mayoría de flujos domóticos de esta fase se apoyan en MQTT.
- Haber desplegado `docs/08-domotica/01-home-assistant.md` si quieres integrar entidades, eventos y servicios desde el primer momento.
- Haber desplegado `docs/08-domotica/03-zigbee2mqtt.md` si vas a usar Node-RED como capa de automatización sobre dispositivos Zigbee.
- Tener creada la estructura base del proyecto, al menos:
  - `/home/<usuario>/homelab/compose`
  - `/home/<usuario>/homelab/data`
- Tener preparado un secreto largo para proteger las credenciales de Node-RED con `credentialSecret`.
- Puertos implicados:
  - `1880/tcp` publicado en el host para la interfaz web de Node-RED
  - salida hacia `1883/tcp` para conectar con Mosquitto
  - salida hacia `8123/tcp` para conectar con Home Assistant

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/node-red/
├── compose.yaml
└── .env
```

Directorio de datos recomendado:

```text
/home/<usuario>/homelab/data/node-red/
└── data/
```

Fichero `.env` recomendado:

```dotenv
TZ=Europe/Madrid
PUID=1000
PGID=1000
NODE_RED_BASE_DIR=/home/<usuario>/homelab/data/node-red
NODE_RED_CREDENTIAL_SECRET=<secreto-largo-y-unico>
```

Notas sobre estas variables:

- `NODE_RED_BASE_DIR` apunta al directorio persistente donde Node-RED guardará flujos, credenciales, `settings.js`, módulos instalados y contexto local.
- `NODE_RED_CREDENTIAL_SECRET` debe ser una cadena larga, única y guardada en tu gestor de secretos.
- `PUID` y `PGID` deben coincidir con el usuario que gestiona los ficheros del homelab si no usas `1000:1000`.

Fichero `compose.yaml`:

```yaml
name: node-red

services:
  node-red:
    image: nodered/node-red:latest
    restart: unless-stopped
    user: "${PUID}:${PGID}"
    env_file:
      - .env
    environment:
      TZ: ${TZ}
      NODE_RED_CREDENTIAL_SECRET: ${NODE_RED_CREDENTIAL_SECRET}
    ports:
      - "1880:1880"
    volumes:
      - ${NODE_RED_BASE_DIR}/data:/data
    labels:
      com.centurylinklabs.watchtower.enable: "true"
```

Despliegue inicial:

```bash
mkdir -p /home/<usuario>/homelab/compose/node-red
mkdir -p /home/<usuario>/homelab/data/node-red/data

sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/node-red
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/node-red

cd /home/<usuario>/homelab/compose/node-red
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f node-red
```

Resultado esperado:

- el contenedor `node-red-node-red-1` queda levantado
- la interfaz queda accesible en `http://<IP-del-host>:1880`
- el directorio `/home/<usuario>/homelab/data/node-red/data/` pasa a contener `flows.json`, `flows_cred.json`, `settings.js` y el resto del estado persistente
- Node-RED queda listo para conectar con Mosquitto y Home Assistant

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| Servicio | Node-RED en Docker |
| UI web | `http://<IP-del-host>:1880` |
| Broker MQTT | Mosquitto en `1883/tcp` |
| Integración Home Assistant | por nodos `node-red-contrib-home-assistant-websocket` |
| Persistencia | `/home/<usuario>/homelab/data/node-red/data/` |
| Credenciales | protegidas con `credentialSecret` |
| Acceso remoto | IP Tailscale de la Pi, sin exposición pública |

### 1. Preparar directorios y permisos

Crear la estructura:

```bash
mkdir -p /home/<usuario>/homelab/compose/node-red
mkdir -p /home/<usuario>/homelab/data/node-red/data
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/node-red
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/node-red

chmod 755 /home/<usuario>/homelab/data/node-red
chmod 750 /home/<usuario>/homelab/data/node-red/data
```

Si `PUID` o `PGID` no coinciden con tu sistema, ajústalos antes de arrancar el stack:

```bash
id -u <usuario>
id -g <usuario>
```

### 2. Primer arranque y comprobación del puerto

Una vez guardados `compose.yaml` y `.env`:

```bash
cd /home/<usuario>/homelab/compose/node-red
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f node-red
ss -tulpn | grep 1880
```

Abrir en el navegador:

```text
http://<IP-del-host>:1880
```

Después del primer arranque, Node-RED generará automáticamente dentro de `/data` varios ficheros importantes, entre ellos:

- `settings.js`
- `flows.json`
- `flows_cred.json`
- `package.json`

### 3. Asegurar `credentialSecret` y contexto persistente

El primer arranque suele crear un `settings.js` funcional, pero conviene dejar dos ajustes cerrados desde el principio:

- un `credentialSecret` propio para no depender de una clave generada automáticamente
- `contextStorage` en disco para conservar estado entre reinicios

Editar el fichero:

```text
/home/<usuario>/homelab/data/node-red/data/settings.js
```

Buscar el bloque de configuración principal y dejar, como mínimo, algo equivalente a esto:

```javascript
credentialSecret: process.env.NODE_RED_CREDENTIAL_SECRET,

contextStorage: {
    default: {
        module: "localfilesystem"
    }
},
```

Notas importantes:

- si `credentialSecret` aparece comentado, descoméntalo y apunta a la variable de entorno
- `localfilesystem` hará persistente el contexto en `/data/context/`
- si pierdes `credentialSecret`, las credenciales guardadas en `flows_cred.json` dejan de ser reutilizables

Aplicar cambios:

```bash
cd /home/<usuario>/homelab/compose/node-red
docker compose restart node-red
```

### 4. Ajustes iniciales recomendados en la UI

Nada más entrar en la UI conviene revisar:

1. **Menu > Settings** para confirmar idioma, tema y opciones básicas del editor.
2. **Menu > Manage palette** para ver qué nodos adicionales están instalados.
3. **Menu > Import** y **Menu > Export** para familiarizarte con el flujo de importación y exportación JSON.
4. **Sidebar > Debug** para poder validar eventos y payloads durante las primeras pruebas.

Recomendaciones operativas:

- crea flujos pequeños y verificables antes de automatizar lógica compleja
- nombra tabs, grupos y nodos con nombres legibles
- usa nodos `debug` durante el diseño y elimínalos o desactívalos cuando ya no aporten valor
- si una automatización es crítica para la vivienda, documenta también su comportamiento fuera de Node-RED

### 5. Integración con Mosquitto

Node-RED se conectará a Mosquitto como cliente MQTT independiente, por lo que debe usar el usuario `nodered` definido en `docs/08-domotica/02-mosquitto.md`.

Configuración recomendada del broker desde cualquier nodo MQTT:

| Campo | Valor recomendado |
|---|---|
| Server | `<IP-LAN-de-la-Pi>` |
| Port | `1883` |
| Client ID | `nodered-main` |
| Username | `nodered` |
| Password | la contraseña MQTT del usuario `nodered` |
| TLS | desactivado en esta fase |

Notas importantes:

- al estar en un stack Compose independiente, Node-RED no debe usar `127.0.0.1` para alcanzar Mosquitto
- usa la **IP LAN** de la Raspberry Pi o su IP de **Tailscale** si vas a trabajar por VPN mesh
- respeta las ACLs del usuario `nodered` definidas en `docs/08-domotica/02-mosquitto.md`

Prueba mínima recomendada:

1. Crear un nodo `inject`.
2. Conectarlo a un nodo `mqtt out`.
3. Publicar en `nodered/test`.
4. Crear otro nodo `mqtt in` escuchando `nodered/test`.
5. Conectarlo a un nodo `debug`.
6. Pulsar el `inject` y verificar que el mensaje vuelve por el broker.

### 6. Integración con Home Assistant

La forma más práctica de integrar Node-RED con Home Assistant en este homelab es instalar el paquete `node-red-contrib-home-assistant-websocket`.

Instalación desde la UI:

1. Ir a **Menu > Manage palette**.
2. Abrir la pestaña **Install**.
3. Buscar `node-red-contrib-home-assistant-websocket`.
4. Instalar el paquete y esperar a que Node-RED recargue la paleta.

Alternativa por terminal dentro del contenedor:

```bash
cd /home/<usuario>/homelab/compose/node-red
docker compose exec node-red npm install --no-update-notifier --no-fund node-red-contrib-home-assistant-websocket
```

Si instalas por `npm`, reinicia después el contenedor:

```bash
cd /home/<usuario>/homelab/compose/node-red
docker compose restart node-red
```

Para autenticar Node-RED contra Home Assistant:

1. Entrar en Home Assistant con un usuario administrador.
2. Ir al perfil de usuario.
3. Crear un **Long-Lived Access Token**.
4. Guardarlo en tu gestor de secretos.
5. En Node-RED, crear la configuración del servidor Home Assistant con:
   - Base URL: `http://<IP-LAN-de-la-Pi>:8123`
   - Access Token: el token recién creado

Si vas a operar a través de Tailscale, también puedes usar:

```text
http://<IP-Tailscale-de-la-Pi>:8123
```

Notas prácticas:

- como Home Assistant está en `network_mode: host`, desde Node-RED debes alcanzarlo por la IP del host, no por `127.0.0.1`
- en este homelab no hace falta HTTPS interno para esta integración porque el alcance es solo **LAN + Tailscale**
- una vez configurado el servidor, podrás usar nodos como `events: state`, `current state` y `action`

### 7. Flujo de ejemplo 1: prueba MQTT extremo a extremo

Este flujo sirve para validar que Node-RED publica y consume correctamente a través de Mosquitto. Se puede importar directamente desde **Menu > Import**:

```json
[
  {
    "id": "tab_mqtt_test",
    "type": "tab",
    "label": "MQTT Test",
    "disabled": false,
    "info": ""
  },
  {
    "id": "inject_mqtt_test",
    "type": "inject",
    "z": "tab_mqtt_test",
    "name": "Enviar prueba",
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
    "payload": "{\"status\":\"ok\",\"source\":\"node-red\"}",
    "payloadType": "json",
    "x": 170,
    "y": 120,
    "wires": [
      [
        "mqtt_out_mqtt_test"
      ]
    ]
  },
  {
    "id": "mqtt_out_mqtt_test",
    "type": "mqtt out",
    "z": "tab_mqtt_test",
    "name": "Publicar nodered/test",
    "topic": "nodered/test",
    "qos": "",
    "retain": "",
    "respTopic": "",
    "contentType": "",
    "userProps": "",
    "correl": "",
    "expiry": "",
    "broker": "mqtt_broker_mqtt_test",
    "x": 430,
    "y": 120,
    "wires": []
  },
  {
    "id": "mqtt_in_mqtt_test",
    "type": "mqtt in",
    "z": "tab_mqtt_test",
    "name": "Leer nodered/test",
    "topic": "nodered/test",
    "qos": "0",
    "datatype": "json",
    "broker": "mqtt_broker_mqtt_test",
    "nl": false,
    "rap": true,
    "rh": 0,
    "inputs": 0,
    "x": 180,
    "y": 200,
    "wires": [
      [
        "debug_mqtt_test"
      ]
    ]
  },
  {
    "id": "debug_mqtt_test",
    "type": "debug",
    "z": "tab_mqtt_test",
    "name": "Debug MQTT",
    "active": true,
    "tosidebar": true,
    "console": false,
    "tostatus": false,
    "complete": "true",
    "targetType": "full",
    "statusVal": "",
    "statusType": "auto",
    "x": 440,
    "y": 200,
    "wires": []
  },
  {
    "id": "mqtt_broker_mqtt_test",
    "type": "mqtt-broker",
    "name": "Mosquitto",
    "broker": "<IP-LAN-de-la-Pi>",
    "port": "1883",
    "clientid": "nodered-main",
    "autoConnect": true,
    "usetls": false,
    "protocolVersion": "4",
    "keepalive": "60",
    "cleansession": true,
    "birthTopic": "",
    "birthQos": "0",
    "birthRetain": "false",
    "birthPayload": "",
    "closeTopic": "",
    "closeQos": "0",
    "closeRetain": "false",
    "closePayload": "",
    "willTopic": "",
    "willQos": "0",
    "willRetain": "false",
    "willPayload": "",
    "userProps": "",
    "sessionExpiry": ""
  }
]
```

Qué debes ajustar tras importarlo:

- la IP del broker MQTT
- el usuario y contraseña del nodo de broker
- el topic si prefieres usar otro namespace

Resultado esperado:

- al pulsar **Enviar prueba**, el payload se publica en `nodered/test`
- el nodo `mqtt in` recibe el mensaje desde Mosquitto
- el `debug` muestra el JSON completo en la barra lateral

### 8. Flujo de ejemplo 2: automatización con MQTT y Home Assistant

Un flujo sencillo y útil para esta fase es:

1. `mqtt in` escuchando `zigbee2mqtt/boton_entrada/action`
2. `switch` filtrando el valor `single`
3. nodo `action` de Home Assistant llamando al servicio `light.toggle`
4. `debug` opcional para registrar la ejecución

Parámetros recomendados:

| Nodo | Configuración |
|---|---|
| `mqtt in` | topic `zigbee2mqtt/boton_entrada/action` |
| `switch` | dejar pasar solo `msg.payload == "single"` |
| `action` | domain `light`, service `toggle`, entity_id `light.recibidor` |

Qué resuelve este patrón:

- Zigbee2MQTT publica el evento del pulsador en MQTT
- Node-RED interpreta ese evento
- Home Assistant ejecuta el servicio sobre la entidad final

Ventajas de hacerlo así:

- la lógica queda visible en un flujo
- puedes añadir condiciones horarias, presencia o prioridades sin tocar Zigbee2MQTT
- Home Assistant sigue siendo la fuente de verdad de entidades y servicios

### 9. Exportación, versionado y cambios de nodos

Cuando un flujo ya funcione, conviene exportarlo desde la UI y guardarlo también fuera de la interfaz visual.

Opciones útiles:

1. **Menu > Export** para copiar el JSON del flujo actual.
2. Guardar exportaciones documentadas si vas a revisar o versionar automatizaciones complejas.
3. Usar nombres consistentes para tabs y grupos para que `flows.json` sea más legible.

Si instalas o actualizas nodos adicionales:

```bash
cd /home/<usuario>/homelab/data/node-red/data
npm outdated
npm install <nombre-del-paquete>@latest

cd /home/<usuario>/homelab/compose/node-red
docker compose restart node-red
```

Antes de actualizar nodos en producción:

- exporta o respalda los flujos
- revisa compatibilidades con tu versión actual de Node-RED
- evita actualizar varios nodos críticos a la vez sin una prueba rápida posterior

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose | `/home/<usuario>/homelab/compose/node-red/` | SSD NVMe |
| Variables del stack | `/home/<usuario>/homelab/compose/node-red/.env` | SSD NVMe |
| Directorio persistente principal | `/home/<usuario>/homelab/data/node-red/data/` | SSD NVMe |
| Flujos | `/home/<usuario>/homelab/data/node-red/data/flows.json` | SSD NVMe |
| Credenciales cifradas | `/home/<usuario>/homelab/data/node-red/data/flows_cred.json` | SSD NVMe |
| Configuración global | `/home/<usuario>/homelab/data/node-red/data/settings.js` | SSD NVMe |
| Dependencias extra | `/home/<usuario>/homelab/data/node-red/data/node_modules/` | SSD NVMe |
| Contexto persistente | `/home/<usuario>/homelab/data/node-red/data/context/` | SSD NVMe |
| Backups exportados | `/mnt/hd2t/backups/node-red/` | `hd2t` |

Notas de almacenamiento:

- todo el estado operativo debe vivir en el **SSD NVMe**
- `hd2t` se usa como destino de backup, no como almacenamiento activo
- el directorio `/data` es el activo principal del servicio
- perder `flows_cred.json`, `settings.js` o `context/` puede impedir restaurar automatizaciones tal como estaban

## Backup
Conviene respaldar como mínimo:

- `/home/<usuario>/homelab/compose/node-red/compose.yaml`
- `/home/<usuario>/homelab/compose/node-red/.env`
- `/home/<usuario>/homelab/data/node-red/data/flows.json`
- `/home/<usuario>/homelab/data/node-red/data/flows_cred.json`
- `/home/<usuario>/homelab/data/node-red/data/settings.js`
- `/home/<usuario>/homelab/data/node-red/data/package.json`
- `/home/<usuario>/homelab/data/node-red/data/package-lock.json` si existe
- `/home/<usuario>/homelab/data/node-red/data/context/`
- el resto del directorio `/home/<usuario>/homelab/data/node-red/data/`

Procedimiento recomendado:

```bash
mkdir -p /mnt/hd2t/backups/node-red

cd /home/<usuario>/homelab/compose/node-red
docker compose stop node-red

rsync -a /home/<usuario>/homelab/compose/node-red/ /mnt/hd2t/backups/node-red/compose/
rsync -a /home/<usuario>/homelab/data/node-red/ /mnt/hd2t/backups/node-red/data/

docker compose up -d
```

Para un backup coherente del directorio `context/` y de los ficheros de flujos, es preferible detener el contenedor unos minutos antes del `rsync`.

## Referencias
- Documentación oficial de Node-RED en Docker: <https://nodered.org/docs/getting-started/docker>
- Guía oficial para añadir nodos a la paleta: <https://nodered.org/docs/user-guide/runtime/adding-nodes>
- Guía oficial para importar y exportar flujos: <https://nodered.org/docs/user-guide/editor/workspace/import-export>
- Paquete `node-red-contrib-home-assistant-websocket`: <https://flows.nodered.org/node/node-red-contrib-home-assistant-websocket>
- Autenticación de Home Assistant y tokens de larga duración: <https://www.home-assistant.io/docs/authentication/>
- Imagen oficial Docker `nodered/node-red`: <https://hub.docker.com/r/nodered/node-red>
