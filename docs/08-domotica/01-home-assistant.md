# Home Assistant

## Descripción
**Home Assistant** será el panel central de domótica del homelab. Su función es unificar entidades, estados, automatizaciones, dashboards y presencia para que el resto de piezas de IoT queden integradas en una única interfaz.

En este proyecto se desplegará como **Home Assistant Container** sobre Docker Engine, manteniendo la configuración persistente en el **SSD NVMe** y dejando los componentes auxiliares como servicios separados:

- **Mosquitto** como broker MQTT
- **Zigbee2MQTT** como puente Zigbee
- **Node-RED** para flujos de automatización visual

Esta separación encaja bien con la arquitectura general del homelab:

- Home Assistant mantiene su propio ciclo de vida y su propia persistencia
- no dependemos de Supervisor ni de apps/add-ons
- cada servicio conserva su stack Compose independiente
- el acceso sigue siendo solo **LAN + Tailscale**

## Requisitos Previos
- Haber completado `docs/02-docker/01-instalacion-docker.md`.
- Haber completado `docs/02-docker/02-estructura-compose.md`.
- Haber completado `docs/01-sistema/04-estructura-directorios.md`.
- Haber completado `docs/03-red/05-tailscale.md` si quieres acceder también por VPN mesh.
- Estar usando **Docker Engine** en la Raspberry Pi; este modo de instalación no está pensado para Docker Desktop.
- Tener creada la estructura base del proyecto, al menos:
  - `/home/<usuario>/homelab/compose`
  - `/home/<usuario>/homelab/data`
- Tener claro que en este homelab **no** se usará Home Assistant OS ni Home Assistant Supervised.
- Tener claro que el coordinador Zigbee **no** debe conectarse todavía a Home Assistant si vas a seguir la guía posterior de `docs/08-domotica/03-zigbee2mqtt.md`, para evitar que dos servicios intenten usar el mismo adaptador USB.
- Puertos implicados en esta fase:
  - `8123/tcp` publicado en el host para la interfaz web de Home Assistant
  - tráfico multicast y broadcast en LAN para autodetección local, por eso se usa `network_mode: host`
  - tráfico saliente HTTPS para descargar componentes e integraciones desde internet
  - tráfico saliente hacia el broker MQTT cuando se configure Mosquitto

## Docker Compose
Directorio recomendado:

```text
/home/<usuario>/homelab/compose/home-assistant/
├── compose.yaml
└── .env
```

Fichero `.env` recomendado:

```dotenv
TZ=Europe/Madrid
HA_CONFIG_DIR=/home/<usuario>/homelab/data/home-assistant/config
```

Fichero `compose.yaml`:

```yaml
name: home-assistant

services:
  home-assistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    restart: unless-stopped
    privileged: true
    env_file:
      - .env
    environment:
      TZ: ${TZ}
    network_mode: host
    volumes:
      - ${HA_CONFIG_DIR}:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
    labels:
      com.centurylinklabs.watchtower.enable: "true"
```

Notas operativas sobre este stack:

- `network_mode: host` es la opción más práctica para Home Assistant porque facilita descubrimiento local por mDNS, SSDP y otros protocolos domésticos.
- `privileged: true` simplifica el acceso a hardware e integraciones del host en el modelo recomendado por la documentación oficial.
- `/run/dbus` se monta en solo lectura para dejar abierta la puerta a integraciones que usen D-Bus, por ejemplo Bluetooth del host.
- En esta fase **no** se monta ningún `/dev/ttyUSB*` en Home Assistant para reservar el adaptador Zigbee al stack de Zigbee2MQTT.

Despliegue inicial:

```bash
mkdir -p /home/<usuario>/homelab/compose/home-assistant
mkdir -p /home/<usuario>/homelab/data/home-assistant/config

sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/home-assistant
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/home-assistant

cd /home/<usuario>/homelab/compose/home-assistant
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f home-assistant
```

Resultado esperado:

- el contenedor `home-assistant-home-assistant-1` queda levantado
- la interfaz queda accesible en `http://<IP-del-host>:8123`
- el estado persistente se guarda en `/home/<usuario>/homelab/data/home-assistant/config/`
- Home Assistant queda listo para completar el asistente inicial y añadir integraciones desde la UI

## Configuración

### Objetivo de esta fase

| Elemento | Estado esperado |
|---|---|
| UI local | `http://<IP-del-host>:8123` |
| Persistencia | `/home/<usuario>/homelab/data/home-assistant/config/` |
| Tipo de instalación | Home Assistant Container |
| Acceso remoto | por IP de Tailscale o MagicDNS, sin exposición pública |
| Broker domótico recomendado | Mosquitto en un stack separado |
| Integración Zigbee recomendada | Zigbee2MQTT, no ZHA en este diseño |

### 1. Preparar directorios y permisos

Crear las rutas necesarias:

```bash
mkdir -p /home/<usuario>/homelab/compose/home-assistant
mkdir -p /home/<usuario>/homelab/data/home-assistant/config
```

Permisos recomendados:

```bash
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/compose/home-assistant
sudo chown -R <usuario>:<usuario> /home/<usuario>/homelab/data/home-assistant
chmod 755 /home/<usuario>/homelab/data/home-assistant
chmod 700 /home/<usuario>/homelab/data/home-assistant/config
```

No hace falta precrear `configuration.yaml` ni otros ficheros. Si `/config` está vacío, Home Assistant generará la estructura inicial en el primer arranque.

### 2. Levantar el contenedor y comprobar el puerto

Una vez guardados `compose.yaml` y `.env`:

```bash
cd /home/<usuario>/homelab/compose/home-assistant
docker compose up -d
```

Comprobaciones útiles:

```bash
docker compose ps
docker compose logs -f home-assistant
ss -tulpn | grep 8123
```

Abrir en el navegador:

```text
http://<IP-del-host>:8123
```

Si tu red resuelve mDNS correctamente, también suele funcionar:

```text
http://homeassistant.local:8123
```

### 3. Completar el asistente inicial

En el primer acceso Home Assistant mostrará la pantalla de preparación y luego el asistente de onboarding.

Pasos mínimos recomendados:

1. Crear la cuenta propietaria de Home Assistant.
2. Guardar usuario y contraseña en tu gestor de secretos.
3. Definir la ubicación de la vivienda para ajustar zona horaria, unidades y zona `home`.
4. Revisar las preferencias de telemetría opcional.
5. Entrar al dashboard inicial.

Recomendaciones operativas:

- usa un usuario administrador distinto del resto de herramientas del homelab
- no dependas de una sola persona si varias van a administrar la vivienda
- documenta la IP o el nombre Tailscale con el que accederás de forma remota

### 4. Ajustes iniciales recomendados en la UI

Nada más entrar en la UI conviene revisar:

1. **Settings > System > Network** para confirmar que el acceso principal será `8123` en LAN o Tailscale.
2. **Settings > People** para crear personas separadas si habrá varios usuarios.
3. **Settings > Areas & Floors** para definir habitaciones y asignar dispositivos desde el principio.
4. **Settings > Devices & services** para revisar descubrimientos automáticos.
5. **Settings > System > Logs** para detectar integraciones mal configuradas o intentos de autodetección que no te interesen.

Como esta instalación es **Container**, debes asumir estas reglas:

- no hay Supervisor
- no hay panel de apps/add-ons
- Mosquitto, Zigbee2MQTT y Node-RED se desplegarán como stacks independientes
- la edición avanzada de archivos se hará directamente sobre `/home/<usuario>/homelab/data/home-assistant/config/`

### 5. Ficheros importantes de configuración

Después del primer arranque aparecerán, entre otros, estos ficheros y directorios:

| Elemento | Ruta |
|---|---|
| Configuración principal | `/home/<usuario>/homelab/data/home-assistant/config/configuration.yaml` |
| Automatizaciones | `/home/<usuario>/homelab/data/home-assistant/config/automations.yaml` |
| Scripts | `/home/<usuario>/homelab/data/home-assistant/config/scripts.yaml` |
| Escenas | `/home/<usuario>/homelab/data/home-assistant/config/scenes.yaml` |
| Secretos | `/home/<usuario>/homelab/data/home-assistant/config/secrets.yaml` |
| Registro interno | `/home/<usuario>/homelab/data/home-assistant/config/.storage/` |

Buenas prácticas con estos ficheros:

- no edites `.storage/` manualmente salvo en escenarios muy concretos
- usa `secrets.yaml` para credenciales o tokens que vayan en YAML
- si modificas YAML manualmente, reinicia Home Assistant desde la UI o con `docker compose restart`

### 6. Integración básica con MQTT

La integración básica más importante para esta fase es **MQTT**, porque será la base para Zigbee2MQTT, muchos sensores DIY y parte de los flujos de Node-RED.

Cuando tengas desplegado `docs/08-domotica/02-mosquitto.md`, añade MQTT así:

1. Ir a **Settings > Devices & services**.
2. Pulsar **Add Integration**.
3. Buscar **MQTT**.
4. Introducir como broker `127.0.0.1` si Mosquitto publica `1883` en el host, o la IP LAN del host si prefieres ser explícito.
5. Introducir el usuario y contraseña definidos en Mosquitto.
6. Dejar activado **MQTT discovery** salvo que tengas una razón clara para deshabilitarlo.

Resultado esperado:

- Home Assistant verá automáticamente entidades publicadas por Zigbee2MQTT y otros dispositivos compatibles
- el topic de descubrimiento `homeassistant/...` quedará disponible para alta automática de entidades

### 7. Integración básica con la app móvil

La otra integración básica recomendable desde el principio es la **companion app** del móvil.

Ventajas prácticas:

- presencia en casa y fuera de casa
- sensores del teléfono
- notificaciones push
- base para automatizaciones personales

Flujo recomendado:

1. Instalar la app oficial de Home Assistant en Android o iOS.
2. Conectar primero por la URL local `http://<IP-del-host>:8123`.
3. Si ya usas Tailscale en el móvil, añadir también el acceso remoto por IP Tailscale o por MagicDNS.
4. Aceptar solo los permisos del móvil que realmente vayas a usar.

### 8. Decisión recomendada sobre Zigbee

Para este homelab la recomendación es:

- **usar Zigbee2MQTT**
- **no** activar ZHA en Home Assistant
- **no** pasar el dongle Zigbee a Home Assistant

La razón es simple:

- el coordinador USB solo puede estar controlado por un servicio al mismo tiempo
- Zigbee2MQTT separa mejor la capa radio de la capa de automatización
- Home Assistant consumirá los dispositivos Zigbee por MQTT discovery

Eso deja una topología limpia:

```text
dispositivos Zigbee
        |
        v
adaptador USB Zigbee
        |
        v
Zigbee2MQTT
        |
        v
Mosquitto
        |
        v
Home Assistant
```

### 9. Reinicios y cambios de configuración

Si cambias archivos YAML o credenciales montadas en `/config`, puedes reiniciar Home Assistant con:

```bash
cd /home/<usuario>/homelab/compose/home-assistant
docker compose restart home-assistant
```

Para revisar errores después de cambios:

```bash
cd /home/<usuario>/homelab/compose/home-assistant
docker compose logs --tail=100 home-assistant
```

## Almacenamiento

| Elemento | Ruta recomendada | Disco |
|---|---|---|
| Stack Compose | `/home/<usuario>/homelab/compose/home-assistant/` | SSD NVMe |
| Variables del stack | `/home/<usuario>/homelab/compose/home-assistant/.env` | SSD NVMe |
| Configuración persistente | `/home/<usuario>/homelab/data/home-assistant/config/` | SSD NVMe |
| Registro interno `.storage` | `/home/<usuario>/homelab/data/home-assistant/config/.storage/` | SSD NVMe |
| Exportaciones o backups manuales | `/mnt/hd2t/backups/home-assistant/` | `hd2t` |

Notas de almacenamiento:

- Home Assistant no necesita `hd2t` ni `hd5t` para funcionar en tiempo de ejecución
- toda la persistencia crítica debe quedarse en el **NVMe**
- el directorio `/config` es el activo principal del servicio
- si más adelante adjuntas medios, snapshots o exportaciones, conviene mandarlos a `hd2t` como destino de backup, no como ruta activa del contenedor

## Backup
Conviene respaldar como mínimo:

- `/home/<usuario>/homelab/compose/home-assistant/compose.yaml`
- `/home/<usuario>/homelab/compose/home-assistant/.env`
- `/home/<usuario>/homelab/data/home-assistant/config/`

Especial atención a estos elementos:

- `configuration.yaml`
- `automations.yaml`
- `scripts.yaml`
- `scenes.yaml`
- `secrets.yaml`
- todo el directorio `.storage/`

Procedimiento recomendado para un backup consistente:

```bash
mkdir -p /mnt/hd2t/backups/home-assistant

cd /home/<usuario>/homelab/compose/home-assistant
docker compose stop home-assistant

rsync -a /home/<usuario>/homelab/compose/home-assistant/ /mnt/hd2t/backups/home-assistant/compose/
rsync -a /home/<usuario>/homelab/data/home-assistant/config/ /mnt/hd2t/backups/home-assistant/config/

docker compose up -d
```

Si prefieres minimizar la parada, puedes hacer el `rsync` en caliente, pero el método más limpio para bases de datos ligeras y ficheros de estado internos sigue siendo detener el servicio unos minutos.

## Referencias
- Documentación oficial de instalación en Linux: <https://www.home-assistant.io/installation/linux/>
- Onboarding oficial: <https://www.home-assistant.io/getting-started/onboarding/>
- Configuración e integraciones: <https://www.home-assistant.io/integrations/>
- Integración MQTT: <https://www.home-assistant.io/integrations/mqtt/>
- Companion apps oficiales: <https://companion.home-assistant.io/>
- Imagen oficial del contenedor: <https://github.com/home-assistant/core/pkgs/container/home-assistant>
