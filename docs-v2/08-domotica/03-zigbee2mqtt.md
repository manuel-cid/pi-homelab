# Zigbee2MQTT

## Descripción

Despliegue de **[Zigbee2MQTT](https://www.zigbee2mqtt.io/)** (Z2M en lo sucesivo, [imagen oficial `koenkk/zigbee2mqtt`](https://hub.docker.com/r/koenkk/zigbee2mqtt)) como **puente Zigbee ↔ MQTT** del homelab. Z2M habla con un **adaptador USB Zigbee** (en este homelab: **SONOFF Zigbee 3.0 USB Dongle Plus** sobre chip [CC2652P](https://www.ti.com/product/CC2652P), [`../00-hardware/01-material-necesario.md`](../00-hardware/01-material-necesario.md)) y traduce el tráfico Zigbee de los dispositivos (bombillas, sensores, enchufes, etc.) a [MQTT Discovery](https://www.zigbee2mqtt.io/guide/usage/mqtt_topics_and_messages.html) sobre [Mosquitto](./02-mosquitto.md). [Home Assistant](./01-home-assistant.md) consume ese discovery y aparecen las entidades automáticamente.

Z2M es la **alternativa elegida frente a [ZHA](https://www.home-assistant.io/integrations/zha/)** (Zigbee Home Automation, integración nativa de HA): se documenta el porqué en §0. Cualquier dispositivo Zigbee del homelab pasa por este servicio; no hay un segundo coordinador Zigbee en el sistema (un dongle ↔ una red Zigbee).

Este doc cubre, en orden:

1. **Por qué Z2M** (no ZHA, no [deCONZ](https://github.com/dresden-elektronik/deconz-rest-plugin), no Hue Bridge propietario) y qué se gana/pierde.
2. **Adaptador USB**: identificación del dongle, fijación del path persistente vía `/dev/serial/by-id/`, permisos del nodo de carácter, alargador USB obligatorio (la electrónica está en [`../00-hardware/02-esquema-conexiones.md`](../00-hardware/02-esquema-conexiones.md) §4).
3. **Plan de variables y archivos**: `.env.example` versionable (sin secretos), `.env` real en `/mnt/hd2t/services/zigbee2mqtt/.env`, layout `/mnt/hd2t/services/zigbee2mqtt/{data,log}`.
4. **`configuration.yaml`** y **`secrets.yaml`** de Z2M: cliente MQTT (`user: zigbee2mqtt`, password en `secrets.yaml`), `permit_join: false` por defecto, `homeassistant: true` para discovery, channel sano (15, 20 o 25 — alejado de WiFi 2.4 GHz), backup automático del coordinator, frontend interno en `:8080`, OTA opt-in.
5. **`docker-compose.yml`** con USB passthrough vía `devices:`, bind mounts, sin `ports:` por defecto (el frontend se accede vía Caddy reverse proxy).
6. **Caddy reverse proxy** para el frontend de Z2M en `zigbee2mqtt.lan` (TLS interno) + middleware Authelia.
7. **Despliegue + alta del primer dispositivo** (emparejamiento `permit_join` temporal).
8. **Verificación funcional**: contenedor sano, conexión a Mosquitto OK (logs), `bridge/state` = `online`, frontend sirviendo, primer dispositivo recibiendo `availability: online`.
9. **Operaciones**: emparejar/eliminar dispositivos, network map, OTA firmware, renombrar dispositivos, backup y restauración del coordinator (NVRAM del dongle).
10. **Backup**: Borgmatic respalda `/mnt/hd2t/services/zigbee2mqtt/` íntegro — `data/` contiene `database.db` (estado de la red Zigbee, **crítico**) y `coordinator_backup.json` (NVRAM del dongle, permite restaurar la red sin tener que re-emparejar todos los dispositivos).
11. **Variantes opt-in**: Prometheus exporter, jail fail2ban del frontend tras Authelia, mapa de red programado vía Node-RED, soporte multi-coordinador (no recomendado), bridge a un segundo broker MQTT.

> **Alcance de red**: Z2M **solo se accede vía la red Docker `homelab`** (broker Mosquitto, frontend tras Caddy). El frontend `8080` **no se publica al host** por defecto: la única vía pública es `https://zigbee2mqtt.lan` vía Caddy con Authelia delante ([`../03-red/04-caddy.md`](../03-red/04-caddy.md), [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)). El acceso remoto se hace vía Tailscale ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) a la misma URL.

---

## 0. ¿Por qué Zigbee2MQTT y no ZHA / deCONZ / Hue?

| Opción | Pros | Cons | Veredicto homelab |
|---|---|---|---|
| **Zigbee2MQTT** (elegida) | (1) Soporte de **>3000** dispositivos en su [device DB](https://www.zigbee2mqtt.io/supported-devices/), incluido el ecosistema chino genérico (Tuya, Aqara, Sonoff). (2) **Desacoplado** de HA: si HA cae, los flujos vía Node-RED → MQTT siguen funcionando. (3) **MQTT Discovery** nativo: HA descubre los devices sin configuración manual. (4) **OTA firmware** integrado para Aqara/IKEA/Hue/Sengled. (5) Backup del coordinador en JSON, restaurable a otro dongle del mismo chip. | (1) Un servicio extra que mantener (vs ZHA "incluido" en HA). (2) Configuración inicial más manual (channel, secrets, permit_join). (3) Curva de aprendizaje de la UI. | **Ganador**. La cobertura de dispositivos y el desacoplo de HA superan al coste operativo. |
| ZHA (integración nativa HA) | (1) Cero servicios extra. (2) Setup vía wizard de HA. | (1) Cobertura de devices ~50% de la de Z2M; los Tuya genéricos suelen no funcionar. (2) Acoplado a HA: si HA está caído, la red Zigbee deja de funcionar para Node-RED y otros consumidores. (3) Sin OTA propio (delegado en zigpy-ota, menor cobertura). (4) Re-emparejar todo si se migra a Z2M en el futuro. | Descartado: la regla de oro del homelab es **HA cliente, no servidor de la red Zigbee**. |
| deCONZ + ConBee II / RaspBee | (1) Proyecto maduro, [API REST](https://dresden-elektronik.github.io/deconz-rest-doc/) además de MQTT (vía plugin). (2) Phoscon UI minimalista. | (1) Dependiente de hardware de Dresden (no funciona bien con dongles SONOFF/CC2652). (2) Cobertura de dispositivos menor que Z2M. (3) Comunidad más pequeña. | Descartado: el adaptador del homelab es SONOFF (CC2652P) y deCONZ no lo soporta plenamente. |
| Hue Bridge / SmartThings / Tuya cloud | (1) Cero mantenimiento. (2) UX pulida. | (1) Cloud-dependent (privacidad, dependencia de servicio externo). (2) Vendor lock-in: cada bridge solo habla con su ecosistema. (3) Coste recurrente de gateways. | Descartado: incompatible con la filosofía self-hosted del homelab. |

> Resumen: **Z2M = self-hosted + máxima cobertura + desacoplado de HA**. El precio es un servicio Docker más, ya factorizado en la Fase 8.

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), `/mnt/hd2t/` montado, directorio `/mnt/hd2t/services/zigbee2mqtt/` ya creado ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §2.6).
- **Docker + red `homelab`** según Fase 2 ([`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md), [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4). Convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5 — bind mounts; §6 — plantilla mínima).
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Z2M va con `enable: "false"` por política ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.1): el firmware del adaptador y la versión de Z2M deben ser compatibles, y un upgrade silencioso puede dejar la red Zigbee inoperativa hasta que el operador haga downgrade manual.
- **Mosquitto operativo** ([`./02-mosquitto.md`](./02-mosquitto.md)) con el cliente `zigbee2mqtt` ya creado en `passwords` y su bloque ACL en `acl` (RW `zigbee2mqtt/#`, [`./02-mosquitto.md`](./02-mosquitto.md) §4.2-§4.3).
- **Home Assistant operativo** ([`./01-home-assistant.md`](./01-home-assistant.md)) **no** es bloqueante para desplegar Z2M (el broker MQTT es la única dependencia hard), pero sí lo es para **ver** los dispositivos: la integración MQTT de HA descubre las entidades de Z2M en cuanto el broker está activo. Si HA aún no está, los devices se podrán emparejar igualmente y aparecerán cuando HA arranque.
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) **si** se va a publicar el frontend en `zigbee2mqtt.lan` (paso §8.1 — recomendado). Sin Caddy, el frontend solo es accesible mediante port-forward manual, lo cual rompe la regla del homelab "ningún servicio web sin reverse proxy + Authelia".
- **Authelia desplegada** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)) si se publica el frontend (mismo §8.1). El frontend de Z2M **no tiene autenticación nativa propia**; sin Authelia, cualquiera en la LAN podría re-emparejar dispositivos o hacer factory reset.
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con registro DNS local `zigbee2mqtt.lan -> IP de la Pi`.
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) para `/mnt/hd2t/services/zigbee2mqtt/` (incluyendo `database.db` y `coordinator_backup.json`).
- **Adaptador Zigbee USB conectado**: SONOFF Zigbee 3.0 USB Dongle Plus en un puerto **USB 2.0** de la Pi 5, **con alargador de ~0.5 m** ([`../00-hardware/02-esquema-conexiones.md`](../00-hardware/02-esquema-conexiones.md) §4). Sin alargador, las interferencias de RF de los puertos USB 3.0 degradan el alcance Zigbee y multiplican los paquetes perdidos.
- **(Opcional) Firmware del adaptador actualizado**: SONOFF distribuye Z-Stack 3.x precargado, normalmente compatible con Z2M sin tocar nada. Si se decide reflashar (vía [Texas Instruments Flash Programmer 2](https://www.ti.com/tool/FLASH-PROGRAMMER) o el [script `cc2538-bsl.py`](https://github.com/JelmerT/cc2538-bsl)), hacerlo **antes** de levantar Z2M para no contaminar `database.db` con un par de dispositivos en una versión y el resto en otra.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Implementación Zigbee | **Zigbee2MQTT** ([`koenkk/zigbee2mqtt:2.0.0`](https://hub.docker.com/r/koenkk/zigbee2mqtt)) | Ver §0. ZHA acoplaría a HA; deCONZ no soporta SONOFF; Hue Bridge no es self-hosted. |
| Tag de imagen | **`koenkk/zigbee2mqtt:2.0.0`** (pinned, no `latest` ni `2.0`) | Evita upgrades automáticos que requieran migración de `database.db` o cambios en `configuration.yaml`. La 2.x introdujo cambios respecto a la 1.x ([release notes](https://github.com/Koenkk/zigbee2mqtt/releases)) — pinear da tiempo al operador a leer el changelog. |
| Arquitectura | `linux/arm64` (Pi 5) | El manifest de `koenkk/zigbee2mqtt:2.0.0` incluye `arm64`. Imagen total: ~250 MB (Node.js base). |
| Adaptador | **SONOFF Zigbee 3.0 USB Dongle Plus** (chip CC2652P) | Hardware definido en [`../00-hardware/01-material-necesario.md`](../00-hardware/01-material-necesario.md). Soporte de primera clase en Z2M ([`herdsman` adapter `zstack`](https://www.zigbee2mqtt.io/guide/adapters/#texas-instruments)). |
| Path del adaptador | **`/dev/serial/by-id/usb-ITead_SONOFF_Zigbee_3.0_USB_Dongle_Plus_*-if00-port0`** | Path estable. El nodo `/dev/ttyUSB0` cambia si se conecta otro USB serial (ej. UPS, ESP32) — usar `by-id` blinda contra el reordenamiento. |
| Permisos del nodo | **dueño `root:dialout` 0660**, contenedor con grupo suplementario `dialout` (GID 20) | Patrón estándar Linux para acceso serial. La imagen oficial de Z2M corre como **root** dentro del contenedor (sin `USER` en el Dockerfile), lo que evita problemas de cgroups con `--device`. |
| Red Docker | **`homelab`** (bridge externa). **Sin** `ports:` al host. | El broker Mosquitto y Caddy resuelven `zigbee2mqtt:8080` por DNS interno. No exponer el `8080` al host elimina el riesgo de gestión sin Authelia desde la LAN. |
| Auth MQTT | **`user: zigbee2mqtt`** + password en `secrets.yaml` | Coordina con [`./02-mosquitto.md`](./02-mosquitto.md) §4.2.1: ese usuario tiene RW solo en `zigbee2mqtt/#`. |
| `permit_join` | **`false`** salvo durante un emparejamiento manual | Si se deja en `true` por descuido, cualquier dispositivo Zigbee dentro del rango puede unirse a la red sin autorización. La UI (frontend §8) o un mensaje MQTT puntual lo activan ad-hoc. |
| `homeassistant` (discovery) | **`true`** | HA descubre los dispositivos automáticamente en `homeassistant/+/+/+/config`. Sin esto, habría que declarar cada `mqtt_sensor` a mano en HA. |
| Channel Zigbee | **`20`** (de los recomendados: 15, 20, 25) | Lejos del WiFi 2.4 GHz típico (canales WiFi 1, 6, 11 → frecuencias Zigbee solapadas: 11-14, 15-18, 19-22, 23-26 — el 20 cae entre WiFi 6 y WiFi 11). Si en producción se observan paquetes perdidos, mover a 25. **Cambiar el channel después de emparejar dispositivos los desconecta** — decidir antes del primer pair. |
| Pan ID / Network Key | **`pan_id: GENERATE`**, **`network_key: GENERATE`** en el primer arranque, luego **fijos** | Z2M reemplaza `GENERATE` por valores aleatorios la primera vez y los persiste en `configuration.yaml`. Esto es el "secreto" de la red Zigbee: si se pierde y hay que reconstruir, todos los dispositivos se desemparejan. **Backup obligatorio**. |
| Frontend | **Activado en `:8080`**, **sin `auth_token` propio** | La autenticación se delega en Authelia vía Caddy ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)). Z2M tiene un `auth_token` opcional, pero un único punto de auth (Authelia) simplifica la operativa. |
| Modelo de almacenamiento | **Bind mount** en `/mnt/hd2t/services/zigbee2mqtt/{data,log}` | Patrón estándar del homelab. Z2M corre como root en el contenedor, así que los bind mounts pueden ser `homelab:homelab 0750` y Z2M escribe igualmente. Para limpiar el contenido, el operador con `sudo` siempre puede. |
| Watchtower | **`com.centurylinklabs.watchtower.enable: "false"`** | Ver [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.1: la compatibilidad firmware ↔ Z2M obliga a leer release notes antes de cada upgrade. |
| Reverse proxy | **Caddy delante** del frontend (`zigbee2mqtt.lan`) | El frontend HTTP plano sin auth es inseguro fuera del namespace `homelab`. Caddy aporta TLS interno y forward_auth a Authelia. |
| Authelia | **Forward_auth requerido** para el frontend | El frontend permite operaciones destructivas (factory reset, eliminar dispositivo, cambiar canal). Authelia con 2FA es la barrera. |
| Fail2ban | **No aplica** al servicio Z2M directamente | Lo gestionan Authelia y Caddy ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md)). Z2M no tiene logs de "intento fallido de auth" porque no autentica directamente. |

---

## 1. Resumen de la arquitectura

```
                  ┌──────────────── red homelab (172.20.0.0/24) ─────────────────┐
                  │                                                              │
                  │   ┌────────────────────┐    MQTT Discovery                   │
                  │   │  Home Assistant    │ ◄──── homeassistant/sensor/0xABC/... │
                  │   │  (./01-home-...)   │                                    │
                  │   └─────────┬──────────┘                                    │
                  │             │ pub/sub vía homeassistant + zigbee2mqtt        │
                  │             ▼                                                │
                  │   ┌────────────────────┐                                    │
                  │   │     Mosquitto      │ broker MQTT                        │
                  │   │   (./02-...)       │ topics: zigbee2mqtt/#              │
                  │   │   1883 (interno)   │                                    │
                  │   └─────────┬──────────┘                                    │
                  │             ▲                                                │
                  │             │ mqtt://zigbee2mqtt:****@mosquitto:1883        │
                  │   ┌─────────┴──────────────────┐                            │
                  │   │       Zigbee2MQTT (este doc)│                           │
                  │   │   /app/data/                │ ─► /mnt/hd2t/services/    │
                  │   │     configuration.yaml      │      zigbee2mqtt/data/    │
                  │   │     secrets.yaml            │      (homelab:homelab     │
                  │   │     database.db             │       0750)               │
                  │   │     coordinator_backup.json │                           │
                  │   │   /app/data/log/            │ ─► /mnt/hd2t/services/    │
                  │   │     log-YYYY-MM-DD/...      │      zigbee2mqtt/log/     │
                  │   │                             │                           │
                  │   │   :8080 (frontend HTTP)     │ ◄── Caddy reverse proxy   │
                  │   │                             │      zigbee2mqtt.lan      │
                  │   └─────┬───────────────────────┘     + Authelia forward_auth│
                  │         │                                                    │
                  └─────────┼────────────────────────────────────────────────────┘
                            │ devices: /dev/serial/by-id/usb-ITead_SONOFF_*
                            ▼
                  ┌──────────────────────┐        ~~~))) Zigbee 2.4 GHz, channel 20
                  │  SONOFF Zigbee 3.0   │ ─────────────────────────────────────►
                  │  USB Dongle Plus     │
                  │  (CC2652P)           │                ┌─────────┐ ┌─────────┐
                  │  Pi USB 2.0 + cable  │                │ Aqara   │ │ IKEA    │
                  │  alargador 0.5 m     │                │ sensor  │ │ bombilla│
                  └──────────────────────┘                └─────────┘ └─────────┘
                                                          ┌─────────┐ ┌─────────┐
                                                          │ Sonoff  │ │ ...     │
                                                          │ enchufe │ │         │
                                                          └─────────┘ └─────────┘
```

Lo crítico de este diagrama:

1. **Z2M no habla nunca con HA directamente**: todo va vía Mosquitto. Si Mosquitto cae, HA y Z2M dejan de coordinarse, pero Z2M **sigue manteniendo la red Zigbee** (seguirá publicando a un broker que vuelva a estar online — el cliente de Z2M reintenta indefinidamente).
2. **El dongle USB es el "modem" de la red Zigbee**: si se pierde el dongle (rotura física o reset NVRAM), se pierde la red. Por eso `coordinator_backup.json` es **el** fichero crítico de backup (§10).
3. **`database.db` ≠ NVRAM del dongle**: la BD de Z2M guarda metadatos lógicos (alias, friendly_name, last_seen, capacidades). La NVRAM del dongle guarda las claves criptográficas y la lista de devices. Restaurar uno sin el otro deja la red en estado inconsistente — siempre se respaldan los dos juntos.
4. **El frontend es destructivo**: permite factory reset, eliminar dispositivo, cambiar channel. Por eso Authelia delante es obligatorio. Sin Authelia, el frontend no se publica.

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/zigbee2mqtt/.env.example`:

```env
# ~/homelab/stacks/zigbee2mqtt/.env.example
# Versionado en: ~/homelab/stacks/zigbee2mqtt/.env.example
# Valores reales en /mnt/hd2t/services/zigbee2mqtt/.env (chmod 600).
# Este fichero NO contiene secretos: la password MQTT y la network_key
# Zigbee viven en /mnt/hd2t/services/zigbee2mqtt/data/secrets.yaml.

# --- Comunes del homelab ---
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
TZ=Europe/Madrid

# --- Zigbee2MQTT ---
# https://hub.docker.com/r/koenkk/zigbee2mqtt
# Releases: https://github.com/Koenkk/zigbee2mqtt/releases
Z2M_IMAGE_TAG=2.0.0

# Hostname interno (resuelto por DNS Docker en la red `homelab`).
Z2M_HOSTNAME=zigbee2mqtt

# Path del adaptador USB en el host. PRIORIZAR /dev/serial/by-id/.
# Verificar con `ls -l /dev/serial/by-id/` tras enchufar el dongle.
Z2M_USB_DEVICE=/dev/serial/by-id/usb-ITead_SONOFF_Zigbee_3.0_USB_Dongle_Plus_0001-if00-port0

# GID del grupo `dialout` del host. Suele ser 20 en Debian/Ubuntu/Pi OS.
# Verificar: `getent group dialout`.
Z2M_DIALOUT_GID=20

# Dominio LAN del homelab (para el frontend tras Caddy).
LAN_DOMAIN=lan
```

### 2.2. `.env` real (`/mnt/hd2t/services/zigbee2mqtt/.env`)

```bash
# Crear el .env con permisos correctos.
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/zigbee2mqtt
sudo install -o homelab -g homelab -m 600 /dev/null \
  /mnt/hd2t/services/zigbee2mqtt/.env

sudo -u homelab tee /mnt/hd2t/services/zigbee2mqtt/.env > /dev/null <<'EOF'
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
TZ=Europe/Madrid
Z2M_IMAGE_TAG=2.0.0
Z2M_HOSTNAME=zigbee2mqtt
Z2M_USB_DEVICE=/dev/serial/by-id/usb-ITead_SONOFF_Zigbee_3.0_USB_Dongle_Plus_0001-if00-port0
Z2M_DIALOUT_GID=20
LAN_DOMAIN=lan
EOF

# Verificar.
ls -l /mnt/hd2t/services/zigbee2mqtt/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` (§5) declara `env_file: /mnt/hd2t/services/zigbee2mqtt/.env`. Compose carga el fichero a la hora de interpolar `${...}` en el YAML (para `image`, `hostname`, `devices`, `group_add`).

> **Por qué no hay secretos en `.env`**: la password MQTT y la `network_key` Zigbee son secretos sensibles y se aíslan en `secrets.yaml` (un fichero leído por Z2M, no por Compose). Esto evita que aparezcan en `docker compose config` o en el inspect del contenedor (`docker inspect zigbee2mqtt | grep -i password` no debe revelar nada).

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
sudo install -d -o homelab -g homelab -m 750 ~/homelab/stacks/zigbee2mqtt
```

### 3.2. Crear el árbol de datos persistentes

```bash
# Estructura canónica:
#  /mnt/hd2t/services/zigbee2mqtt/
#    ├── .env             (homelab:homelab 0600, ya creado en §2.2)
#    ├── data/            (homelab:homelab 0750)
#    │     ├── configuration.yaml   ← versionable como ejemplo (sin secretos)
#    │     ├── secrets.yaml         ← secretos: password MQTT, network_key
#    │     ├── database.db          ← BD lógica de Z2M (creado al primer pair)
#    │     ├── state.json           ← caché temporal (efímero)
#    │     ├── coordinator_backup.json ← NVRAM del dongle (creado al pair)
#    │     └── log/                 ← logs por día (creados por Z2M)
#    │           └── log-YYYY-MM-DD/log.txt
#    └── log/             (homelab:homelab 0750)  ← redirección opcional, ver §4.1

sudo install -d -o homelab -g homelab -m 0750 \
  /mnt/hd2t/services/zigbee2mqtt/data \
  /mnt/hd2t/services/zigbee2mqtt/log
```

### 3.3. Tabla de permisos

| Ruta host | Modo | Owner | Quién escribe | Por qué |
|---|---|---|---|---|
| `/mnt/hd2t/services/zigbee2mqtt/` | `0750 homelab:homelab` | El operador. | Estructura. | Patrón canónico. |
| `/mnt/hd2t/services/zigbee2mqtt/.env` | `0600 homelab:homelab` | El operador. | El operador. | Sin secretos pero hábito 600 en cualquier `.env`. |
| `/mnt/hd2t/services/zigbee2mqtt/data/` | `0750 homelab:homelab` | El operador inicial; luego Z2M (root en el contenedor). | Z2M materializa `database.db`, `state.json`, `coordinator_backup.json`. | Z2M corre como root dentro del contenedor — escribe en bind mounts sin importar el ownership del host (root tiene `CAP_DAC_OVERRIDE`). El owner host es `homelab` para que el operador pueda manipular sin `sudo`. |
| `/mnt/hd2t/services/zigbee2mqtt/data/secrets.yaml` | `0640 homelab:homelab` | El operador. | El operador. | El fichero contiene la password MQTT en plano y la network_key Zigbee. Lectura solo a `homelab`. Z2M (root) lee igualmente. |
| `/mnt/hd2t/services/zigbee2mqtt/data/configuration.yaml` | `0644 homelab:homelab` | El operador. | El operador (Z2M también la modifica, ej. al rellenar `pan_id` y `network_key` la primera vez si están en `GENERATE`). | Sin secretos directos (los referencia con `!secret`). |
| `/mnt/hd2t/services/zigbee2mqtt/data/database.db` | `0644 root:root` (creado por Z2M) | Z2M. | Z2M. | Estado de la red Zigbee — lo gestiona Z2M sin intervención. |
| `/mnt/hd2t/services/zigbee2mqtt/data/coordinator_backup.json` | `0644 root:root` (creado por Z2M) | Z2M. | Z2M (cada vez que detecta un cambio en NVRAM). | NVRAM del dongle. **Crítico para restore**. |
| `/mnt/hd2t/services/zigbee2mqtt/log/` | `0750 homelab:homelab` | Z2M (si se redirige `advanced.log_directory`). | Z2M. | Log por día (rotación interna de Z2M). |

> **Sobre el bind mount como root**: la imagen oficial `koenkk/zigbee2mqtt` no fija `USER` en su Dockerfile, así que el proceso corre como root dentro del contenedor. Los bind mounts respetan UIDs del host, pero root en el contenedor (UID 0 = root del host) puede escribir cualquier dir gracias a `CAP_DAC_OVERRIDE` (incluido por defecto en Docker). El homelab acepta esto porque Z2M está aislado de internet, en una red Docker interna y sin servicios públicos.

### 3.4. Verificar que el adaptador USB es accesible

```bash
# 1. Confirmar que el dongle está detectado.
ls -l /dev/serial/by-id/
# Esperado: una línea como
#   lrwxrwxrwx 1 root root 13 May 12 10:23 \
#     usb-ITead_SONOFF_Zigbee_3.0_USB_Dongle_Plus_0001-if00-port0 -> ../../ttyUSB0
#
# Si no aparece NADA: comprobar `lsusb`:
lsusb | grep -i 'silicon\|10c4\|sonoff\|cp210'
# El SONOFF Plus (CC2652P) usa un CP2102N de Silicon Labs como puente USB→UART.
# Esperado: "ID 10c4:ea60 Silicon Labs CP210x UART Bridge".

# 2. Comprobar permisos del nodo.
ls -l /dev/ttyUSB0
# Esperado: "crw-rw---- 1 root dialout ... /dev/ttyUSB0".
# Si no es `dialout`: el sistema base aún no carga la regla udev.
# Ver §3.5 para fijar permisos persistentes.

# 3. Verificar que el GID 'dialout' existe en el host.
getent group dialout
# Esperado: "dialout:x:20:".
# Anotar el GID (suele ser 20) y rellenarlo en .env como Z2M_DIALOUT_GID.

# 4. Probar lectura del puerto serie sin Z2M (smoke test).
sudo apt install -y python3-serial
sudo -u homelab python3 - <<'PY'
import serial
with serial.Serial('/dev/ttyUSB0', baudrate=115200, timeout=1) as s:
    print("Open OK:", s.is_open)
PY
# Esperado: "Open OK: True". Si falla con "Permission denied",
# ver §3.5 (añadir homelab a dialout o reglas udev).
```

### 3.5. Permisos persistentes del nodo USB (regla udev)

Pi OS suele crear `/dev/ttyUSB0` con `root:dialout 0660` por defecto. Si el sistema no usa la regla por defecto (o un upgrade la cambia), fijarla explícitamente:

```bash
# Crear regla udev para el SONOFF (vendor 10c4, product ea60).
sudo tee /etc/udev/rules.d/99-zigbee.rules > /dev/null <<'EOF'
# SONOFF Zigbee 3.0 USB Dongle Plus (CC2652P + CP2102N)
SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", \
  GROUP="dialout", MODE="0660", \
  SYMLINK+="zigbee"
EOF

# Recargar reglas y refrescar el dispositivo.
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=tty

# Verificar que aparecen `/dev/zigbee` y permisos.
ls -l /dev/zigbee /dev/ttyUSB0
# Esperado:
#   lrwxrwxrwx 1 root root  ... /dev/zigbee -> ttyUSB0
#   crw-rw---- 1 root dialout ... /dev/ttyUSB0
```

> **`SYMLINK+="zigbee"`**: opcional pero útil — `/dev/zigbee` es un nombre estable adicional. El homelab usa **`/dev/serial/by-id/...`** como path principal (construido por udev de serie sin necesidad de regla custom), pero el symlink alternativo facilita debug manual (`screen /dev/zigbee 115200`).

---

## 4. Configuración de Zigbee2MQTT

### 4.1. `configuration.yaml` (sin secretos)

Fichero **versionable** en `~/homelab/stacks/zigbee2mqtt/configuration.example.yaml` y **copiable** a `/mnt/hd2t/services/zigbee2mqtt/data/configuration.yaml`. La copia activa la editará el propio Z2M para rellenar `pan_id` y `network_key` la primera vez (de ahí que no se versionen los valores reales).

```yaml
# ~/homelab/stacks/zigbee2mqtt/configuration.example.yaml
# Z2M 2.x — https://www.zigbee2mqtt.io/guide/configuration/
#
# Despliegue: este fichero se copia a /mnt/hd2t/services/zigbee2mqtt/data/configuration.yaml
# (../08-domotica/03-zigbee2mqtt.md §4.4). Z2M lo lee al arrancar y lo modifica para
# rellenar pan_id y network_key si vienen como GENERATE (primer arranque).

# ── Versión del schema (Z2M 2.x) ─────────────────────────────────────────────
version: 4

# ── Permitir nuevos joins (false en producción) ──────────────────────────────
# Activar puntualmente desde el frontend o publicando a:
#   zigbee2mqtt/bridge/request/permit_join {"value": true, "time": 254}
permit_join: false

# ── MQTT (broker Mosquitto) ──────────────────────────────────────────────────
mqtt:
  base_topic: zigbee2mqtt
  server: mqtt://mosquitto:1883
  user: zigbee2mqtt
  password: '!secret mqtt_password'
  client_id: zigbee2mqtt
  # MQTT 3.1.1 — el más compatible con Mosquitto 2.x.
  version: 4
  # Reintentar conexión sin parar si Mosquitto cae.
  reject_unauthorized: true
  keepalive: 60
  # No publicar mensajes con `retain: true` por defecto:
  # los retained masivos llenan mosquitto.db (../08-domotica/02-mosquitto.md §11).
  # Z2M ya retiene los mensajes de bridge (state, devices) — no se desactiva.
  include_device_information: true

# ── Adaptador serie (puerto USB) ─────────────────────────────────────────────
serial:
  # Path estable del SONOFF (../00-hardware/01-material-necesario.md).
  port: /dev/serial/by-id/usb-ITead_SONOFF_Zigbee_3.0_USB_Dongle_Plus_0001-if00-port0
  # Adaptador Texas Instruments Z-Stack (familia CC2652).
  adapter: zstack
  # Backup de la NVRAM del coordinator (CRÍTICO para restore tras pérdida de dongle).
  disable_led: false

# ── Home Assistant MQTT Discovery ────────────────────────────────────────────
homeassistant:
  enabled: true
  discovery_topic: homeassistant
  status_topic: homeassistant/status
  # Cada device aparece con su modelo, firmware, fabricante.
  experimental_event_entities: false

# ── Frontend HTTP (puerto interno 8080) ──────────────────────────────────────
# La autenticación se delega en Authelia vía Caddy.
# NO usar `auth_token` para no duplicar capas de auth.
frontend:
  enabled: true
  port: 8080
  host: 0.0.0.0
  # Página URL desde la que sirven los assets (Caddy hará reverse proxy).
  url: 'https://zigbee2mqtt.lan'

# ── Red Zigbee ───────────────────────────────────────────────────────────────
advanced:
  # Channel: 11/15/20/25 son los recomendados.
  # 20 cae en una zona libre entre WiFi 6 (2437 MHz) y WiFi 11 (2462 MHz).
  channel: 20

  # PAN ID (16-bit). 'GENERATE' = aleatorio en primer arranque.
  # Tras el primer arranque, Z2M sustituye 'GENERATE' por un número.
  # NO modificar manualmente: cambiarlo desempareja toda la red.
  pan_id: GENERATE

  # PAN ID extendido (64-bit). Idem.
  ext_pan_id: GENERATE

  # Network key (128-bit, criptográfico). 'GENERATE' = aleatorio.
  # Igual: tras el primer arranque queda fijado. Backup obligatorio.
  network_key: GENERATE

  # Backup automático de la NVRAM del coordinator a JSON.
  # Z2M lo escribe en data/coordinator_backup.json.
  # Sin esto, si el dongle se rompe, hay que re-emparejar todo desde cero.
  # Activado por defecto en Z2M 2.x; se deja explícito.
  network_key_distribute: false

  # Logs por día en /app/data/log/log-YYYY-MM-DD/log.txt.
  log_level: info
  log_output: ['file', 'console']
  log_directory: /app/data/log
  log_file: 'log.txt'
  log_rotation: true
  log_symlink_current: true

  # Timestamps en logs.
  timestamp_format: 'YYYY-MM-DD HH:mm:ss'

  # Mensajes de availability (online/offline) — Z2M los publica
  # en zigbee2mqtt/<device>/availability.
  # Activado globalmente; cada device puede sobrescribirlo en su entry.
  # Define ventanas (active = devices despiertos, passive = sensores que duermen).
  # Sin esto, HA no sabe si un sensor está caído o vivo.

availability:
  enabled: true
  active:
    timeout: 10
  passive:
    timeout: 1500

# ── OTA (firmware Over-The-Air) ──────────────────────────────────────────────
# Activado solo bajo demanda (ver §9.4).
# Cuando está enabled, Z2M comprueba en su DB de manifests si hay update
# para cada device cada N horas y publica notificaciones al broker.
ota:
  update_check_interval: 1440  # minutos = 24 h
  disable_automatic_update_check: true
  # Z2M Discord/GitHub firmware index (cache en /app/data/ota).
  zigbee_ota_override_index_location: null

# ── Lista de dispositivos ────────────────────────────────────────────────────
# Sección autogenerada por Z2M. NO editarla a mano salvo para renombrar
# (`friendly_name`) o asignar a un grupo.
# Ejemplo tras emparejar:
#
# devices:
#   '0x00158d0001abcdef':
#     friendly_name: 'sensor_temperatura_salon'
#     description: 'Aqara WSDCGQ11LM en mesa del salón'

# ── Grupos (opcional) ────────────────────────────────────────────────────────
# Permite enviar comandos a varios devices a la vez.
# Ejemplo:
# groups:
#   '1':
#     friendly_name: 'luces_salon'
#     devices:
#       - 'bombilla_lampara_pie'
#       - 'bombilla_techo_salon'
```

#### 4.1.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `version: 4` | Schema de Z2M 2.x. El primer arranque sin esta clave dispara una migración automática que rellena el campo. Declararlo explícito evita el aviso. |
| `permit_join: false` | Default seguro. Cada vez que se quiera emparejar un device se activa puntualmente desde el frontend (durante 254s, que es lo que dura el comando del coordinator). |
| `mqtt.server: mqtt://mosquitto:1883` | Plain MQTT en la red `homelab` — el broker no expone TLS internamente (decisión de [`./02-mosquitto.md`](./02-mosquitto.md)). |
| `mqtt.user/password: !secret ...` | Z2M soporta `!secret <key>` que resuelve desde `secrets.yaml`. Mantiene los secretos fuera del fichero principal. |
| `mqtt.client_id: zigbee2mqtt` | ID estable para que el broker correlacione sesiones. Sin esto, Z2M generaría un `zigbee2mqtt-<random>` y los logs de Mosquitto serían menos legibles. |
| `mqtt.version: 4` | MQTT 3.1.1. El 5 también funcionaría, pero MQTT 5 introduce features (response topics, message expiry) que Z2M no usa. |
| `mqtt.keepalive: 60` | El cliente envía `PINGREQ` cada 60s. Coincide con el default de Mosquitto. |
| `serial.port: /dev/serial/by-id/...` | Path estable. **No** `/dev/ttyUSB0` (cambia si se conecta otro USB serial). |
| `serial.adapter: zstack` | Z-Stack es el firmware del CC2652P. El otro valor frecuente es `ember` (chips Silabs EFR32MG21). El dongle SONOFF Plus es Z-Stack. |
| `homeassistant.enabled: true` | Discovery: HA ve cada device aparecer como `sensor.salon_temperatura`, `light.bombilla_techo`, etc. sin configuración manual. Sin esto, habría que declarar a mano cada `mqtt:` entity. |
| `homeassistant.status_topic: homeassistant/status` | Z2M se suscribe a este topic; cuando HA publica `online` (al arrancar), Z2M re-emite el discovery completo para que HA reconstruya las entidades. |
| `frontend.enabled: true` + `port: 8080` | Frontend Vue.js de Z2M. Sin frontend no se pueden emparejar devices ni ver el mapa de red sin meter mensajes MQTT a mano. |
| `frontend.url: 'https://zigbee2mqtt.lan'` | URL pública (vía Caddy). Z2M la usa para construir absolute paths en notificaciones y en el OAuth flow opcional (no usado aquí). |
| `advanced.channel: 20` | Lejos de WiFi 1/6/11. Documentado en [`../00-hardware/02-esquema-conexiones.md`](../00-hardware/02-esquema-conexiones.md) §4. **Cambiarlo después de pair = desemparejar todo**. |
| `advanced.pan_id: GENERATE` | Z2M genera un PAN ID aleatorio (16-bit) en el primer arranque. Si dos homelabs próximos usan el mismo PAN ID, las redes se interfieren. Aleatorizar lo evita. |
| `advanced.network_key: GENERATE` | Clave criptográfica de la red Zigbee. Z2M genera 128 bits aleatorios la primera vez. Tras eso queda fija en el fichero — si se cambia, todos los dispositivos quedan fuera de la red. |
| `advanced.log_level: info` | Suficiente para auditar conexiones y errores sin saturar. `debug` solo durante troubleshooting (genera ~10 MB/h con 30 devices). |
| `advanced.log_output: ['file', 'console']` | Doble destino: fichero (rotado por día) para análisis offline; consola para `docker logs` y Dozzle. |
| `availability.enabled: true` | Z2M publica `online`/`offline` por device. HA usa esto para mostrar sensores con icono "Unavailable" cuando un device pierde la red. Sin esto, HA muestra el último valor "para siempre" aunque el sensor esté roto. |
| `availability.active.timeout: 10` | Devices "active" (siempre despiertos: bombillas, enchufes) deben responder en ≤ 10 min — si no, `offline`. |
| `availability.passive.timeout: 1500` | Devices "passive" (sensores que duermen: contactos puerta/ventana, motion) tienen tolerancia de 25 h — son normales que estén "callados" muchas horas. |
| `ota.disable_automatic_update_check: true` | Por defecto Z2M consulta el firmware index cada `update_check_interval` minutos. El homelab desactiva el check automático: el operador comprueba manualmente desde el frontend (§9.4). Esto evita que un dispositivo Aqara haga un upgrade silencioso a un firmware con bug. |

### 4.2. `secrets.yaml`

```bash
# Generar password MQTT (debe coincidir con la del usuario `zigbee2mqtt`
# en /mnt/hd2t/services/mosquitto/config/passwords — la creada en
# ../08-domotica/02-mosquitto.md §4.2.2).
# Si la password de Mosquitto ya existe, reutilizarla aquí.
# Si NO se anotó, regenerarla en Mosquitto Y aquí en paralelo.

# Asumamos que la password ya está anotada en Vaultwarden (o en una nota local
# durante el bootstrap).
Z2M_MQTT_PASS="<copiar la password de Mosquitto de §4.2.2>"

sudo install -o homelab -g homelab -m 0640 /dev/null \
  /mnt/hd2t/services/zigbee2mqtt/data/secrets.yaml

sudo -u homelab tee /mnt/hd2t/services/zigbee2mqtt/data/secrets.yaml > /dev/null <<EOF
# /mnt/hd2t/services/zigbee2mqtt/data/secrets.yaml
# Secretos de Z2M referenciados desde configuration.yaml con !secret <clave>.
# NO versionar este fichero. Backup vía Borgmatic (../07-backups/02-borgmatic.md).

mqtt_password: '${Z2M_MQTT_PASS}'
EOF

# Verificar permisos.
ls -l /mnt/hd2t/services/zigbee2mqtt/data/secrets.yaml
# Esperado: -rw-r----- 1 homelab homelab ... secrets.yaml
```

> **¿Por qué un fichero separado y no `${...}` desde `.env`?**: `configuration.yaml` solo soporta `!secret <key>` para resolver desde `secrets.yaml`. No interpola variables de entorno (limitación upstream de Z2M). Mantener el patrón `!secret` lo deja preparado para otros secretos futuros (ej. `ota.zigbee_ota_url` con un token).

### 4.3. (Tras el primer arranque) Verificar que `pan_id` y `network_key` se materializaron

```bash
# Tras el primer `docker compose up -d` (§6), Z2M sustituye GENERATE por valores reales.
# CONSULTAR (no editar) ese fichero.
sudo cat /mnt/hd2t/services/zigbee2mqtt/data/configuration.yaml | grep -E 'pan_id|network_key'

# Esperado, tras el primer arranque (no antes):
#   pan_id: 4673
#   ext_pan_id: [221,221,221,221,221,221,221,221]
#   network_key: [10,15,30,2,1,3,4,8,...]   # 16 enteros 0-255
```

> **Estos valores son la "huella" de la red Zigbee**. Si se pierden (corrupción de `configuration.yaml` sin backup), todos los dispositivos quedan inoperativos hasta re-emparejarlos uno a uno con factory reset. Por eso `coordinator_backup.json` (§9.6) y el snapshot Borgmatic son la red de seguridad.

### 4.4. Copiar `configuration.yaml` al bind mount

```bash
# Solo si NO existe ya: el primer despliegue copia la plantilla.
if [ ! -f /mnt/hd2t/services/zigbee2mqtt/data/configuration.yaml ]; then
  sudo install -o homelab -g homelab -m 0644 \
    ~/homelab/stacks/zigbee2mqtt/configuration.example.yaml \
    /mnt/hd2t/services/zigbee2mqtt/data/configuration.yaml
fi

# Comprobación final del directorio data/.
sudo ls -l /mnt/hd2t/services/zigbee2mqtt/data/
# Esperado en el primer despliegue:
#   -rw-r--r-- 1 homelab homelab ... configuration.yaml
#   -rw-r----- 1 homelab homelab ... secrets.yaml
```

---

## 5. `docker-compose.yml`

`~/homelab/stacks/zigbee2mqtt/docker-compose.yml`:

```yaml
# ~/homelab/stacks/zigbee2mqtt/docker-compose.yml
# Stack: zigbee2mqtt (../02-docker/02-estructura-compose.md §1.1).
# Datos en /mnt/hd2t/services/zigbee2mqtt/.
# Sin `ports:` — el frontend se publica vía Caddy en zigbee2mqtt.lan.

name: zigbee2mqtt

services:
  zigbee2mqtt:
    image: koenkk/zigbee2mqtt:${Z2M_IMAGE_TAG}
    container_name: zigbee2mqtt
    hostname: ${Z2M_HOSTNAME}
    restart: unless-stopped
    env_file: /mnt/hd2t/services/zigbee2mqtt/.env

    environment:
      TZ: ${TZ}
      # Z2M lee la ruta del fichero de configuración de la variable
      # ZIGBEE2MQTT_DATA. Por defecto /app/data — explícito por claridad.
      ZIGBEE2MQTT_DATA: /app/data

    # USB passthrough: el dongle Zigbee.
    devices:
      - "${Z2M_USB_DEVICE}:/dev/zigbee:rw"

    # GID `dialout` del host (para que el proceso pueda abrir el char device).
    # Z2M corre como root en el contenedor, así que CAP_DAC_OVERRIDE ya da acceso;
    # `group_add` se mantiene como defense-in-depth si una futura imagen pasara
    # a non-root.
    group_add:
      - "${Z2M_DIALOUT_GID}"

    volumes:
      # Datos persistentes (configuration.yaml, secrets.yaml, database.db,
      # coordinator_backup.json, log/).
      - type: bind
        source: /mnt/hd2t/services/zigbee2mqtt/data
        target: /app/data
      # Reloj sincronizado con el host.
      - /etc/localtime:/etc/localtime:ro

    # Sin `ports:` — el frontend (8080) se accede vía Caddy reverse proxy.
    networks:
      - homelab

    depends_on:
      mosquitto:
        condition: service_healthy
        restart: true

    # Recursos: Z2M con ~50 devices consume ~150 MB de RAM.
    # Limitar a 512m capa el blast radius de un memory leak en herdsman.
    mem_limit: 512m
    mem_reservation: 128m

    # Healthcheck: el binario `wget` está en la imagen Alpine.
    # Verifica que el frontend responde y que el bridge está conectado a MQTT.
    healthcheck:
      test:
        - "CMD-SHELL"
        - "wget -qO- http://localhost:8080/ >/dev/null 2>&1 || exit 1"
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

    labels:
      # Watchtower: EXCLUIDO (../02-docker/04-watchtower.md §4.1).
      # El upgrade de Z2M debe ser manual por compatibilidad firmware.
      com.centurylinklabs.watchtower.enable: "false"
      # Dozzle: agrupar con el resto de Fase 8.
      dev.dozzle.group: "homeassistant"

networks:
  homelab:
    external: true
```

> **Nota sobre `depends_on` con `mosquitto`**: el stack `zigbee2mqtt` está definido en su propio `docker-compose.yml` y Mosquitto en otro. La condición `service_healthy` solo aplica si los dos servicios están en el **mismo** Compose project. Aquí el `depends_on` queda como **documentación**: Mosquitto debe estar arriba antes de Z2M. En operación, si Z2M arranca antes que Mosquitto, su cliente MQTT reintenta automáticamente cada 5s y termina conectando — por eso no es estrictamente necesario.
>
> Para forzar el orden a nivel sistema, usar la dependencia de boot del host (`systemctl` units) o desplegar siempre el stack `mosquitto` antes del stack `zigbee2mqtt` con un script `~/homelab/operations/start-all.sh`.

### 5.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `name: zigbee2mqtt` | Nombre del proyecto Compose, igual al nombre del directorio del stack ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.1). |
| `image: koenkk/zigbee2mqtt:${Z2M_IMAGE_TAG}` | Tag pinned vía `.env`. La imagen oficial está en Docker Hub ([`koenkk/zigbee2mqtt`](https://hub.docker.com/r/koenkk/zigbee2mqtt)). |
| `container_name: zigbee2mqtt` / `hostname: ${Z2M_HOSTNAME}` | Nombre estable: Caddy resuelve `zigbee2mqtt:8080` por DNS Docker para el reverse proxy. |
| `env_file: ...` | Patrón estándar. |
| `environment.TZ` | Timestamps en logs en zona local. Sin `TZ`, Z2M loguea en UTC. |
| `environment.ZIGBEE2MQTT_DATA: /app/data` | Default upstream pero explicitado para evitar sorpresas si una versión futura cambia el path. |
| `devices: "${Z2M_USB_DEVICE}:/dev/zigbee:rw"` | El path del host (`/dev/serial/by-id/...`) se mapea a `/dev/zigbee` dentro del contenedor. **Aquí el path interno NO importa** porque Z2M usa `serial.port` de `configuration.yaml` (que apunta al path host). El mapeo `/dev/zigbee` interno se podría usar como path en `configuration.yaml` si se prefiere desacoplar (el doc lo deja al path host por consistencia con `/dev/serial/by-id/`). |
| `group_add: ${Z2M_DIALOUT_GID}` | Z2M corre como root en la imagen oficial — no es estrictamente necesario, pero documentar `group_add` deja preparado para un futuro `USER node` upstream. |
| `volumes: data:/app/data` | Z2M escribe `database.db`, `coordinator_backup.json`, `log/` aquí. Único bind mount de datos. |
| `volumes: /etc/localtime:ro` | Sincroniza zona del host con el contenedor. |
| `networks: [homelab]` | Solo la red compartida. Mosquitto se resuelve como `mosquitto:1883`, Caddy llega a `zigbee2mqtt:8080`. |
| `depends_on: mosquitto: condition: service_healthy` | Documentación + intento de coordinación si los stacks están en el mismo proyecto Compose. |
| `mem_limit: 512m` | Z2M base (~50 devices, sin OTA): ~120 MB de RAM. Con OTA activo durante un download: pico de ~250 MB (manifest + buffer del firmware). 512 MB cubre los picos. |
| `mem_reservation: 128m` | Garantía mínima. |
| `healthcheck` | `wget` al frontend. Si Z2M no levanta el HTTP (ej. crash al cargar `configuration.yaml`), el contenedor se marca unhealthy. |
| `start_period: 60s` | Z2M tarda ~30s en cargar el adaptador, conectar al broker y levantar el frontend. 60s da margen. |
| `com.centurylinklabs.watchtower.enable: "false"` | Política ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.1). El operador hace upgrade manualmente tras leer release notes. |
| `dev.dozzle.group: "homeassistant"` | Agrupa logs de Fase 8 en Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)). |
| `networks.homelab.external: true` | La red se crea en el bootstrap. |

### 5.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/zigbee2mqtt
docker compose --env-file /mnt/hd2t/services/zigbee2mqtt/.env config

# Esperado: salida YAML resuelta sin warnings.
# - El `image` debe estar plenamente cualificado: koenkk/zigbee2mqtt:2.0.0
# - `devices` con el path absoluto del dongle.
# - `group_add` con el GID numérico (20).
# - Sin warning "variable X not set".
```

---

## 6. Despliegue

### 6.1. Levantar el stack

```bash
cd ~/homelab/stacks/zigbee2mqtt
docker compose --env-file /mnt/hd2t/services/zigbee2mqtt/.env up -d
```

El primer `up` tarda **~60 segundos**:

1. Pull de la imagen (~250 MB la primera vez).
2. Z2M arranca, intenta abrir `/dev/serial/by-id/...` (~5s).
3. Verifica firmware del coordinator (logs muestran `Coordinator firmware version 'XX.YY.ZZ'`).
4. Genera `pan_id` y `network_key` la primera vez (~2s, **persistido en `configuration.yaml`**).
5. Conecta a Mosquitto (`mqtt://mosquitto:1883`), publica `zigbee2mqtt/bridge/state` = `online`.
6. Levanta el frontend en `:8080`.
7. Inicializa la BD vacía (`database.db`).

Verificar:

```bash
docker compose --env-file /mnt/hd2t/services/zigbee2mqtt/.env ps

# Esperado:
# NAME          IMAGE                          STATUS                  PORTS
# zigbee2mqtt   koenkk/zigbee2mqtt:2.0.0       Up X (healthy)          8080/tcp
```

### 6.2. Logs del primer arranque

```bash
docker compose --env-file /mnt/hd2t/services/zigbee2mqtt/.env logs --tail=80 zigbee2mqtt

# Esperado, líneas relevantes:
#   [info] Logging to console and file (/app/data/log/log-YYYY-MM-DD/log.txt)
#   [info] Starting Zigbee2MQTT version 2.0.0 (commit #abcdef)
#   [info] Starting zigbee-herdsman (3.x.y)
#   [info] Coordinator firmware version: '20240711'
#   [info] zigbee-herdsman started (resumed)
#   [info] Coordinator revision: '20240711'
#   [info] Currently 0 devices are joined:
#   [info] Zigbee: disabling joining new devices.
#   [info] Connecting to MQTT server at mqtt://mosquitto:1883
#   [info] Connected to MQTT server
#   [info] MQTT publish: topic 'zigbee2mqtt/bridge/state', payload '{"state":"online"}'
#   [info] Started frontend on port 8080
#
# Errores típicos del primer arranque:
#
#   Error: Failed to connect to the adapter (Error: Resource temporarily unavailable)
#     → Otro proceso del host abre el puerto serie. Verificar:
#       sudo lsof /dev/ttyUSB0
#     → Si nada lo abre, prueba con `udevadm trigger`:
#       sudo udevadm trigger --subsystem-match=tty
#
#   Error: Coordinator firmware not supported
#     → Firmware del SONOFF demasiado antiguo o en variante Ember (no Z-Stack).
#       Ver §11 troubleshooting.
#
#   Error: Failed to authorize against MQTT server
#     → Password incorrecta en secrets.yaml o usuario sin ACL en Mosquitto.
#       Ver §11.
```

### 6.3. Verificar generación de pan_id / network_key

```bash
sudo grep -E 'pan_id|network_key' /mnt/hd2t/services/zigbee2mqtt/data/configuration.yaml

# Esperado (valores reales aleatorios):
#   pan_id: 12345
#   ext_pan_id: [11,22,33,44,55,66,77,88]
#   network_key: [10,15,30,2,1,3,4,8,99,...]   # 16 enteros
```

> **Punto clave**: si `pan_id` aún muestra `GENERATE`, el primer arranque no ha terminado. Esperar 60s y reintentar. Si tras 2 minutos sigue como `GENERATE`, hay un problema de inicialización (ver `docker logs`).

---

## 7. Verificación

### 7.1. Contenedor sano

```bash
docker compose --env-file /mnt/hd2t/services/zigbee2mqtt/.env ps
# STATUS de zigbee2mqtt: "Up X (healthy)".
```

### 7.2. Z2M NO escucha en el host

```bash
sudo ss -ltn | grep -E ':8080'
# Esperado: VACÍO (Caddy puede tener su propio :8080 ajeno).
# El frontend de Z2M solo es accesible desde la red `homelab` y vía Caddy.
```

### 7.3. Bridge online

Desde el host, verificar que Z2M ha publicado el estado a Mosquitto:

```bash
# El cliente nodered tiene `read #` en el ACL de Mosquitto, así que sirve
# para suscribirse y leer los topics de Z2M.
NR_PASS="<password de nodered>"

docker exec mosquitto mosquitto_sub \
  -h localhost -p 1883 \
  -u nodered -P "$NR_PASS" \
  -t 'zigbee2mqtt/bridge/state' -C 1 -W 5

# Esperado:
# {"state":"online"}
```

### 7.4. Frontend accesible (vía port-forward temporal)

Antes de configurar Caddy + Authelia (§8.1), verificar que el frontend funciona:

```bash
# Port-forward temporal (NO publicar al host en docker-compose.yml).
docker run --rm \
  --network homelab \
  alpine/curl:latest \
  curl -sf http://zigbee2mqtt:8080/ >/dev/null && echo "Frontend OK"

# Esperado: "Frontend OK".
```

### 7.5. Coordinator backup creado

```bash
sudo ls -l /mnt/hd2t/services/zigbee2mqtt/data/coordinator_backup.json

# Esperado: tras el primer arranque, fichero JSON de ~5-15 KB.
# Si NO existe: el dongle no soporta backup (firmware antiguo) o Z2M no terminó de inicializar.
# Re-revisar logs.
```

### 7.6. Lista de Verificación

- [ ] `docker compose ps` lista `zigbee2mqtt` como `(healthy)`.
- [ ] `sudo ss -ltn | grep 8080` no devuelve nada (frontend no expuesto al host).
- [ ] `docker exec mosquitto mosquitto_sub -t 'zigbee2mqtt/bridge/state' -C 1` devuelve `{"state":"online"}`.
- [ ] `sudo grep network_key /mnt/hd2t/services/zigbee2mqtt/data/configuration.yaml` muestra un array de 16 enteros (no `GENERATE`).
- [ ] `sudo ls -l /mnt/hd2t/services/zigbee2mqtt/data/coordinator_backup.json` muestra fichero existente y > 0 bytes.
- [ ] `docker logs zigbee2mqtt 2>&1 | grep "Coordinator firmware"` muestra una versión válida (ej. `20240711`).
- [ ] `docker logs zigbee2mqtt 2>&1 | grep "Connected to MQTT server"` aparece exactamente una vez tras el último restart.
- [ ] `docker exec zigbee2mqtt ls /dev/zigbee` muestra el char device (smoke test del USB passthrough).
- [ ] El frontend responde a `curl http://zigbee2mqtt:8080/` desde otro contenedor de la red `homelab`.
- [ ] (Tras §8.1) `https://zigbee2mqtt.lan` redirige a Authelia, autentica y carga la UI.

---

## 8. Configuración post-despliegue

### 8.1. Publicar el frontend en Caddy + Authelia

Editar `~/homelab/stacks/proxy/Caddyfile` (o `~/homelab/stacks/proxy/sites/zigbee2mqtt.caddy` según el patrón de [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.1):

```caddy
zigbee2mqtt.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Forward auth a Authelia (../04-seguridad/01-authelia.md §6).
    forward_auth authelia:9091 {
        uri /api/verify?rd=https://auth.{$LAN_DOMAIN}/
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }

    reverse_proxy http://zigbee2mqtt:8080 {
        # WebSocket del frontend (Vue.js → Z2M live updates).
        header_up Host {host}
        header_up X-Real-IP {remote_host}
    }
}
```

Reload de Caddy:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

DNS local en Pi-hole ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)): registro `zigbee2mqtt.lan -> IP de la Pi`.

Probar:

```bash
# Desde un equipo en la LAN.
curl -k https://zigbee2mqtt.lan/
# Esperado: redirección 302 a Authelia (https://auth.lan/?rd=...).
```

### 8.2. Conexión a Mosquitto verificada

Cuando [`./02-mosquitto.md`](./02-mosquitto.md) está operativo y Z2M arrancó correctamente, los siguientes topics deberían existir:

```bash
NR_PASS="<password de nodered>"

# Estado del bridge.
docker exec mosquitto mosquitto_sub \
  -h localhost -p 1883 \
  -u nodered -P "$NR_PASS" \
  -t 'zigbee2mqtt/bridge/info' -C 1 -W 5

# Esperado: JSON con commit, version, coordinator{...}, network{channel,pan_id,...}.

# Lista de devices (vacía al inicio).
docker exec mosquitto mosquitto_sub \
  -h localhost -p 1883 \
  -u nodered -P "$NR_PASS" \
  -t 'zigbee2mqtt/bridge/devices' -C 1 -W 5

# Esperado: "[]" (array vacío) la primera vez.
```

### 8.3. Discovery en Home Assistant

Cuando HA esté operativo y la integración MQTT añadida ([`./01-home-assistant.md`](./01-home-assistant.md) §8.2), Z2M re-publica el discovery en cuanto detecta `homeassistant/status: online`:

1. En HA: **Settings → Devices & Services**. La integración MQTT debería aparecer y, dentro, un dispositivo **Zigbee2MQTT Bridge** con sensores: `coordinator_version`, `network_map`, `permit_join`, `restart`.
2. Sin devices Zigbee aún, no hay nada más que ver.
3. Tras emparejar (§9.1), cada device aparece automáticamente en HA con sus entidades correspondientes (luz, sensor temperatura, etc.).

---

## 9. Operaciones cotidianas

### 9.1. Emparejar un nuevo dispositivo

**Vía frontend (recomendado)**:

1. Abrir `https://zigbee2mqtt.lan` (auth en Authelia).
2. Botón **"Permit join (All)"** en la barra superior. Activarlo durante 254s (el máximo permitido por Zigbee).
3. Poner el dispositivo en modo emparejamiento (varía: Aqara → mantener botón 5s; bombilla IKEA → encender/apagar 6 veces; SONOFF → mantener pulsado al enchufar).
4. El frontend muestra una notificación al detectar el join (~5-30s).
5. **Renombrar el device** desde la UI con un `friendly_name` legible (`sensor_temperatura_salon`, no `0x00158d0001abcdef`). Esto persiste en `configuration.yaml`.
6. Apagar **"Permit join"** explícitamente — incluso antes de los 254s — por seguridad.

**Vía MQTT (sin frontend, útil para automatizar)**:

```bash
NR_PASS="<password de nodered>"
HA_PASS="<password de homeassistant>"

# Activar permit_join 60s.
docker exec mosquitto mosquitto_pub \
  -h localhost -p 1883 \
  -u homeassistant -P "$HA_PASS" \
  -t 'zigbee2mqtt/bridge/request/permit_join' \
  -m '{"value": true, "time": 60}'

# (Poner el device en modo pairing.)

# Verificar joins en directo.
docker exec mosquitto mosquitto_sub \
  -h localhost -p 1883 \
  -u nodered -P "$NR_PASS" \
  -t 'zigbee2mqtt/bridge/event' -W 60
# Esperado: evento "device_joined" con ieee_address.

# Renombrar:
docker exec mosquitto mosquitto_pub \
  -h localhost -p 1883 \
  -u homeassistant -P "$HA_PASS" \
  -t 'zigbee2mqtt/bridge/request/device/rename' \
  -m '{"from": "0x00158d0001abcdef", "to": "sensor_temperatura_salon"}'

# Apagar permit_join.
docker exec mosquitto mosquitto_pub \
  -h localhost -p 1883 \
  -u homeassistant -P "$HA_PASS" \
  -t 'zigbee2mqtt/bridge/request/permit_join' \
  -m '{"value": false}'
```

### 9.2. Eliminar un dispositivo

**Vía frontend**: Devices → seleccionar el device → "Remove device" → confirmar (esto envía un comando `leave` al device; si no responde, se puede forzar con "force remove" que solo borra del lado Z2M).

**Vía MQTT**:

```bash
HA_PASS="<password de homeassistant>"

docker exec mosquitto mosquitto_pub \
  -h localhost -p 1883 \
  -u homeassistant -P "$HA_PASS" \
  -t 'zigbee2mqtt/bridge/request/device/remove' \
  -m '{"id": "sensor_temperatura_salon", "force": false, "block": false}'

# `force: true` borra incluso si el device no responde al leave.
# `block: true` añade el device a la blocklist (no podrá re-pairing sin desbloqueo).
```

### 9.3. Network map (mapa de la red Zigbee)

Útil para diagnosticar mesh: qué routers (devices alimentados con corriente) están repitiendo señal a qué end-devices (sensores con pila).

**Vía frontend**: tab "Map" → "Update map" (tarda ~2 min en redes grandes; los devices passive con pila pueden no aparecer hasta su próximo wake-up).

**Vía MQTT**:

```bash
HA_PASS="<password de homeassistant>"
NR_PASS="<password de nodered>"

# Solicitar regeneración del mapa.
docker exec mosquitto mosquitto_pub \
  -h localhost -p 1883 \
  -u homeassistant -P "$HA_PASS" \
  -t 'zigbee2mqtt/bridge/request/networkmap' \
  -m '{"type": "raw", "routes": true}'

# Recibir el mapa (asíncrono, tarda 30-180s).
docker exec mosquitto mosquitto_sub \
  -h localhost -p 1883 \
  -u nodered -P "$NR_PASS" \
  -t 'zigbee2mqtt/bridge/response/networkmap' -C 1 -W 200
```

### 9.4. OTA firmware update (manual)

```bash
HA_PASS="<password de homeassistant>"
NR_PASS="<password de nodered>"

# 1. Comprobar si hay updates disponibles para un device.
docker exec mosquitto mosquitto_pub \
  -h localhost -p 1883 \
  -u homeassistant -P "$HA_PASS" \
  -t 'zigbee2mqtt/bridge/request/device/ota_update/check' \
  -m '{"id": "bombilla_ikea_salon"}'

docker exec mosquitto mosquitto_sub \
  -h localhost -p 1883 \
  -u nodered -P "$NR_PASS" \
  -t 'zigbee2mqtt/bridge/response/device/ota_update/check' -C 1 -W 30

# 2. Si hay update, lanzar:
docker exec mosquitto mosquitto_pub \
  -h localhost -p 1883 \
  -u homeassistant -P "$HA_PASS" \
  -t 'zigbee2mqtt/bridge/request/device/ota_update/update' \
  -m '{"id": "bombilla_ikea_salon"}'

# El update tarda 5-30 min (depende del device). Z2M publica progreso en
# zigbee2mqtt/bridge/response/device/ota_update/update.
```

> **Cuidado**: un OTA fallido puede dejar el device "bricked" (raro, pero posible). Hacerlo solo en horario controlado y con el device físicamente accesible.

### 9.5. Logs

```bash
# Tail del fichero del día actual.
sudo tail -F /mnt/hd2t/services/zigbee2mqtt/data/log/log-$(date +%F)/log.txt

# Vía Docker.
docker compose --env-file /mnt/hd2t/services/zigbee2mqtt/.env logs --tail=200 -f zigbee2mqtt

# Vía Dozzle (../05-monitorizacion/06-dozzle.md), grupo "homeassistant".

# Filtrar errores recientes:
sudo grep -iE 'error|warn|disconnect|fail' \
  /mnt/hd2t/services/zigbee2mqtt/data/log/log-$(date +%F)/log.txt | tail -30

# Cambiar log_level a 'debug' temporalmente (sin restart):
HA_PASS="<password de homeassistant>"
docker exec mosquitto mosquitto_pub \
  -h localhost -p 1883 \
  -u homeassistant -P "$HA_PASS" \
  -t 'zigbee2mqtt/bridge/request/options' \
  -m '{"options": {"advanced": {"log_level": "debug"}}}'
# (No olvidar revertir a 'info' después.)
```

### 9.6. Backup del coordinator (NVRAM del dongle)

`coordinator_backup.json` se actualiza automáticamente cada vez que Z2M detecta un cambio en la NVRAM (pair, leave, OTA). Forzar un backup manual:

```bash
HA_PASS="<password de homeassistant>"
docker exec mosquitto mosquitto_pub \
  -h localhost -p 1883 \
  -u homeassistant -P "$HA_PASS" \
  -t 'zigbee2mqtt/bridge/request/backup' \
  -m '{}'

# Verificar timestamp:
sudo stat /mnt/hd2t/services/zigbee2mqtt/data/coordinator_backup.json
```

> **Restore**: si el dongle se rompe y se compra otro **del mismo chip** (CC2652P → otro SONOFF Plus), copiar el `coordinator_backup.json` al nuevo Z2M, restaurar el `database.db` y `configuration.yaml`. Z2M flashea la NVRAM del nuevo dongle con los datos del backup en el primer arranque, **manteniendo todos los devices emparejados**. Si el nuevo dongle es de **otra familia** (ej. EFR32), el backup no es portable y hay que re-emparejar todo.

### 9.7. Upgrade de Z2M

Con `enable: "false"` en Watchtower, el upgrade es manual:

```bash
# 1. Leer release notes:
#    https://github.com/Koenkk/zigbee2mqtt/releases
#    Buscar breaking changes, migraciones de configuration.yaml, requisitos
#    de versión mínima del coordinator firmware.

# 2. Backup explícito antes del upgrade.
HA_PASS="<password de homeassistant>"
docker exec mosquitto mosquitto_pub \
  -h localhost -p 1883 \
  -u homeassistant -P "$HA_PASS" \
  -t 'zigbee2mqtt/bridge/request/backup' -m '{}'

sudo cp -a /mnt/hd2t/services/zigbee2mqtt/data \
  /mnt/hd2t/services/zigbee2mqtt/data.bak-$(date +%F)

# 3. Actualizar el tag.
sudo nano /mnt/hd2t/services/zigbee2mqtt/.env
# Z2M_IMAGE_TAG=2.0.0  ->  2.1.0

# 4. Pull + recreate.
cd ~/homelab/stacks/zigbee2mqtt
docker compose --env-file /mnt/hd2t/services/zigbee2mqtt/.env pull
docker compose --env-file /mnt/hd2t/services/zigbee2mqtt/.env up -d

# 5. Verificar logs y bridge state:
docker logs zigbee2mqtt 2>&1 | tail -50
# Buscar: "Starting Zigbee2MQTT version 2.1.0", "Connected to MQTT server",
# "MQTT publish: ... 'zigbee2mqtt/bridge/state' ... 'online'".

# 6. Confirmar que los devices siguen funcionando: probar un sensor (esperar
# un mensaje de availability) o un actuador (encender una luz).

# 7. Si todo OK, limpiar backup:
sudo rm -rf /mnt/hd2t/services/zigbee2mqtt/data.bak-$(date +%F)

# 8. Si NO OK, rollback:
docker compose --env-file /mnt/hd2t/services/zigbee2mqtt/.env down
sudo rm -rf /mnt/hd2t/services/zigbee2mqtt/data
sudo mv /mnt/hd2t/services/zigbee2mqtt/data.bak-$(date +%F) \
        /mnt/hd2t/services/zigbee2mqtt/data
sudo nano /mnt/hd2t/services/zigbee2mqtt/.env  # volver al tag anterior
docker compose --env-file /mnt/hd2t/services/zigbee2mqtt/.env up -d
```

---

## 10. Backup

> **Estrategia**: Borgmatic respalda `/mnt/hd2t/services/zigbee2mqtt/` íntegro. **No hay BD relacional** (la `database.db` de Z2M es un fichero JSON-lines propio, no SQLite). El restore se hace copiando el directorio y levantando el contenedor en otro dongle del mismo chip.

### 10.1. Qué se respalda

| Ruta | Contenido | Crítico |
|---|---|---|
| `/mnt/hd2t/services/zigbee2mqtt/.env` | Tags, paths, GIDs. | Bajo (reconstruible). |
| `/mnt/hd2t/services/zigbee2mqtt/data/configuration.yaml` | Configuración + `pan_id` + `network_key`. | **Crítico**. Sin esto, los devices no pueden re-conectarse a la red. |
| `/mnt/hd2t/services/zigbee2mqtt/data/secrets.yaml` | Password MQTT. | Alto (recuperable rotando en Mosquitto). |
| `/mnt/hd2t/services/zigbee2mqtt/data/database.db` | Estado lógico: friendly_names, last_seen, capabilities, groups. | Alto. Sin esto, los devices vuelven a tener nombres `0xABC...` y se pierden los grupos definidos. |
| `/mnt/hd2t/services/zigbee2mqtt/data/coordinator_backup.json` | NVRAM del dongle (claves criptográficas, lista de devices). | **Crítico**. Permite restaurar la red en otro dongle del mismo chip sin re-emparejar. |
| `/mnt/hd2t/services/zigbee2mqtt/data/log/` | Logs históricos. | Bajo (informativo). |
| `/mnt/hd2t/services/zigbee2mqtt/data/state.json` | Estado runtime cacheado. | Bajo (Z2M lo regenera). |

### 10.2. Borgmatic

[`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) ya incluye `/mnt/hd2t/services/` en sus `source_directories`. Z2M queda cubierto sin cambios.

> **No hay BD relacional que dumpear**. Z2M **no** se declara en la sección `databases:` de Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6).

### 10.3. Restore (resumen)

Procedimiento canónico — la receta extendida vive en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §2.

```bash
# 1. Detener el contenedor (si existe).
cd ~/homelab/stacks/zigbee2mqtt
docker compose --env-file /mnt/hd2t/services/zigbee2mqtt/.env down

# 2. Restaurar desde el último archivo Borg.
sudo borgmatic extract \
  --archive latest \
  --path mnt/hd2t/services/zigbee2mqtt \
  --destination /tmp/restore-z2m

sudo rsync -aHAX --delete \
  /tmp/restore-z2m/mnt/hd2t/services/zigbee2mqtt/ \
  /mnt/hd2t/services/zigbee2mqtt/

# 3. Asegurar permisos.
sudo chown -R homelab:homelab /mnt/hd2t/services/zigbee2mqtt
sudo chmod 0640 /mnt/hd2t/services/zigbee2mqtt/data/secrets.yaml

# 4. Levantar.
docker compose --env-file /mnt/hd2t/services/zigbee2mqtt/.env up -d

# 5. Verificar §7. Especialmente:
#    - El dongle es accesible (mismo path /dev/serial/by-id/ tras recablear).
#    - bridge/state = online.
#    - Los devices vuelven a publicar availability sin re-emparejar.
```

### 10.4. Restore en un dongle nuevo (mismo chip)

Si el dongle se rompió y se cambia por otro SONOFF Plus:

```bash
# 1. Detener Z2M.
cd ~/homelab/stacks/zigbee2mqtt
docker compose --env-file /mnt/hd2t/services/zigbee2mqtt/.env down

# 2. Sustituir físicamente el dongle. Verificar el nuevo path:
ls -l /dev/serial/by-id/
# El serial number del SONOFF nuevo será distinto:
#   usb-ITead_SONOFF_Zigbee_3.0_USB_Dongle_Plus_0002-if00-port0

# 3. Actualizar Z2M_USB_DEVICE en el .env y serial.port en configuration.yaml.
sudo nano /mnt/hd2t/services/zigbee2mqtt/.env
# Z2M_USB_DEVICE=/dev/serial/by-id/usb-ITead_SONOFF_Zigbee_3.0_USB_Dongle_Plus_0002-if00-port0
sudo nano /mnt/hd2t/services/zigbee2mqtt/data/configuration.yaml
# serial.port: /dev/serial/by-id/usb-ITead_SONOFF_Zigbee_3.0_USB_Dongle_Plus_0002-if00-port0

# 4. Levantar. Z2M detecta que el dongle es nuevo y aplica el coordinator_backup.json:
docker compose --env-file /mnt/hd2t/services/zigbee2mqtt/.env up -d

# 5. Verificar logs:
docker logs zigbee2mqtt 2>&1 | tail -30
# Buscar: "Restoring coordinator from backup", "zigbee-herdsman started (resumed)".

# 6. Devices reconectan automáticamente cuando hagan su próxima emisión
#    (sensores con pila pueden tardar horas — es normal).
```

### 10.5. Smoke test (ad-hoc)

Cuando la rotación de smoke tests ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §8.3) toque "Zigbee2MQTT":

1. Levantar contenedor temporal apuntando a `/mnt/hd2t/backups/restore-test/zigbee2mqtt-YYYY-MM-DD/` con un dongle de pruebas (NO el de producción — emparejaría una segunda red Zigbee con la misma `network_key`).
2. Verificar que arranca sin errores y muestra los devices del último snapshot en `bridge/devices`.
3. `sudo rm -rf` el directorio.
4. Anotar resultado en `~/homelab/operations/restore-tests.log`.

> **Importante**: NO conectar el dongle de producción al contenedor de smoke test. Sería una segunda red Zigbee idéntica que confundiría a los dispositivos.

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `Error: Failed to connect to the adapter (Resource temporarily unavailable)` | Otro proceso del host abre `/dev/ttyUSB0` (modemmanager, brltty, etc.). | `sudo lsof /dev/ttyUSB0` para ver qué proceso. Deshabilitar `modemmanager`: `sudo systemctl disable --now ModemManager`. Excluir el adaptador en `brltty` con [esta guía](https://www.zigbee2mqtt.io/guide/installation/01_linux.html#determining-port). |
| `Error: Failed to connect to the adapter (Permission denied)` | El bind de `/dev/ttyUSB0` en el contenedor no le da acceso al proceso. | Como Z2M corre como root, no debería pasar; si pasa, revisar `group_add: ${Z2M_DIALOUT_GID}` en compose y verificar `getent group dialout` en el host. |
| `Coordinator firmware not supported` | Firmware del SONOFF muy antiguo (<20210608) o variante Ember en lugar de Z-Stack. | Reflashar con [Z-Stack 3.x.0 Coordinator firmware](https://github.com/Koenkk/Z-Stack-firmware). El SONOFF Plus se viene con firmware Z-Stack precargado, así que solo aplica si el operador lo reflasheó por error. |
| `Failed to authorize against MQTT server` | Password en `secrets.yaml` distinta de la del usuario `zigbee2mqtt` en el `passwords` de Mosquitto. | Comprobar: en Mosquitto `sudo grep '^zigbee2mqtt:' /mnt/hd2t/services/mosquitto/config/passwords` (existe el user). En Z2M `sudo cat /mnt/hd2t/services/zigbee2mqtt/data/secrets.yaml`. Rotar coordinada (Mosquitto §9.2 + secrets.yaml). |
| Bridge online pero devices no aparecen en HA | Discovery deshabilitado en Z2M, o ACL de Mosquitto bloquea a HA en `homeassistant/#`. | `sudo grep '^homeassistant' /mnt/hd2t/services/zigbee2mqtt/data/configuration.yaml | grep enabled`. ACL en `/mnt/hd2t/services/mosquitto/config/acl` debe tener `user homeassistant` con `topic readwrite homeassistant/#` ([`./02-mosquitto.md`](./02-mosquitto.md) §4.3). |
| Devices con `availability: offline` poco después del pair | `availability.passive.timeout` muy corto para sensores con pila. | Subir `availability.passive.timeout` a 7200 (5 días) en `configuration.yaml`; reload con `docker compose restart zigbee2mqtt`. |
| Frontend en `https://zigbee2mqtt.lan` da 502 Bad Gateway | Z2M está down o Caddy no resuelve el contenedor. | `docker compose ps zigbee2mqtt` debe ser `(healthy)`. `docker exec caddy nslookup zigbee2mqtt` debe resolver a la IP en la red `homelab`. Reiniciar Caddy si fue añadido en caliente: `docker exec caddy caddy reload --config /etc/caddy/Caddyfile`. |
| Pérdidas de paquetes Zigbee (devices "Last seen" >> 1h) | Channel solapado con WiFi del router, o dongle sin alargador (interferencia USB 3.0). | `iwlist wlan0 freq` para ver canal WiFi del router. Mover Z2M a otro channel (ver §0). Confirmar alargador físicamente conectado al dongle. |
| `database.db` crece sin parar | Devices con telemetría agresiva (cada segundo) escriben muchas entradas en la BD lógica. | Z2M no rota la BD por sí sola; tamaño normal: ~50 KB/device. >5 MB indica un device problemático: identificar con `sudo grep '"lastSeen"' /mnt/hd2t/services/zigbee2mqtt/data/database.db | sort | uniq -c`. |
| `coordinator_backup.json` no existe tras el primer arranque | Firmware del coordinator sin soporte de backup (SONOFF muy antiguo). | Aceptar la situación o reflashar. Sin backup, el dongle es no-restaurable: si se rompe, hay que re-emparejar todo. |
| `permit_join` queda pegado en `true` indefinidamente | Frontend cerrado sin desactivar; el timeout de 254s no se aplicó. | Forzar via MQTT: `mosquitto_pub -t 'zigbee2mqtt/bridge/request/permit_join' -m '{"value": false}'`. |
| Z2M no termina de arrancar (loop "Starting...") | Configuration.yaml con `version: 4` en una imagen Z2M 1.x, o viceversa. | Comprobar `docker logs zigbee2mqtt 2>&1 | grep -i 'configuration\|schema\|migration'`. Restaurar la versión correcta del schema. |
| Tras un upgrade, devices con sintaxis vieja desaparecen del frontend | Migración automática de `configuration.yaml` que renombró claves; un device con configuración custom puede quedar huérfano. | Restaurar el `data.bak-<fecha>` (§9.7). Leer release notes para conocer las claves renombradas. |
| Healthcheck `unhealthy` pero el bridge está online | El frontend está apagado en `configuration.yaml` (`frontend.enabled: false`). | Activar el frontend (§4.1) y restart, o cambiar el healthcheck por una probe MQTT (alternativa abajo). |

### 11.1. Healthcheck alternativo (si se desactiva el frontend)

```yaml
healthcheck:
  test:
    - "CMD-SHELL"
    - "test -f /app/data/state.json"
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 60s
```

> Solo verifica que Z2M ha llegado a producir el `state.json` (señal de que el adaptador conectó). Menos preciso que la probe HTTP.

---

## 12. Variantes opt-in

### 12.1. Métricas Prometheus con `zigbee2mqtt-prometheus`

**Cuándo activar**: cuando Fase 5 está completa ([`../05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md)) y se quiere graficar señal Zigbee (LQI), batería de sensores, mensajes/min.

**Estrategia**: Z2M no expone métricas Prometheus nativas. Existe el exporter [`kpine/zigbee2mqtt-prometheus`](https://github.com/kpine/zigbee2mqtt2prometheus) que se suscribe a MQTT y expone `:9221/metrics`.

**Añadir al stack** (`~/homelab/stacks/zigbee2mqtt/docker-compose.yml` — servicio adicional):

```yaml
services:
  zigbee2mqtt:
    # ... existente ...

  zigbee2mqtt-exporter:
    image: ghcr.io/kpine/zigbee2mqtt2prometheus:latest  # pinear tag en producción
    container_name: zigbee2mqtt-exporter
    restart: unless-stopped
    environment:
      MQTT_URL: mqtt://mosquitto:1883
      MQTT_USER: monitoring
      MQTT_PASSWORD: ${MONITORING_PASS}   # añadir a .env y a Mosquitto passwords
      Z2M_TOPIC: zigbee2mqtt
    networks:
      - homelab
    depends_on:
      - zigbee2mqtt
    labels:
      com.centurylinklabs.watchtower.enable: "true"

# Crear el cliente `monitoring` en Mosquitto con ACL solo lectura sobre
# zigbee2mqtt/# y $SYS/# ([`./02-mosquitto.md`](./02-mosquitto.md) §12.4).
```

Añadir target en Prometheus:

```yaml
- job_name: zigbee2mqtt
  static_configs:
    - targets: ['zigbee2mqtt-exporter:9221']
```

### 12.2. Mapa de red programado vía Node-RED

Generar el network map cada 6 h y publicar el resultado a un topic propio (consumido por una dashboard custom):

```text
[ inject every 6h ]
   → [ mqtt-out: zigbee2mqtt/bridge/request/networkmap, payload {"type":"raw","routes":true} ]

[ mqtt-in: zigbee2mqtt/bridge/response/networkmap ]
   → [ function: extraer LQI medio, número de routers, devices offline ]
   → [ mqtt-out: nodered/zigbee/stats ]
```

> Detalles en [`./04-node-red.md`](./04-node-red.md) §X cuando esté escrito.

### 12.3. WebSocket del frontend a través de Tailscale (sin Caddy)

Acceso al frontend desde un dispositivo móvil en Tailscale:

```bash
# Activar Tailscale Funnel/Serve en el host (../03-red/05-tailscale.md):
sudo tailscale serve --bg --https=443 \
  --set-path=/zigbee2mqtt http://localhost:8080
```

> Esto requiere publicar el `8080` al host (`ports: ["127.0.0.1:8080:8080"]` en compose). Estrategia menos preferida que Caddy + Authelia, pero útil para acceso rápido sin pasar por Authelia (riesgo: cualquiera con acceso a tu Tailnet entra). Para uso individual, aceptable.

### 12.4. Cambiar el coordinator a un Slzb-06 (Ethernet Zigbee)

**Cuándo activar**: si el dongle USB sufre interferencias persistentes y se quiere mover el coordinador lejos de la Pi vía Ethernet.

**Cambios**:

1. Hardware: comprar un [SLZB-06](https://smlight.tech/product/slzb-06/) (LAN+USB Zigbee bridge con CC2652P).
2. Conectarlo a la LAN, asignar IP estática en el router.
3. En `configuration.yaml`:

```yaml
serial:
  port: 'tcp://192.168.1.50:6638'
  adapter: zstack
```

4. Eliminar `devices:` y `group_add:` del compose (ya no hay USB).
5. Restaurar el `coordinator_backup.json` en el SLZB-06 vía su panel web o vía el `data/` que se trae al nuevo Z2M.

> El cambio de coordinador es **delicado**: si los dos coordinadores (USB y SLZB) intentan estar online a la vez con la misma `network_key`, los devices se confunden. Apagar SIEMPRE uno antes de levantar el otro.

### 12.5. Bridge MQTT a un segundo broker

Z2M solo soporta **un** broker MQTT primary. Si se quiere replicar a un segundo broker (ej. uno público para visualizar desde fuera), usar el bridge de **Mosquitto** ([`./02-mosquitto.md`](./02-mosquitto.md) §12.6) en lugar de cambiar Z2M.

### 12.6. OTA con repository custom

Para devices Aqara que no aparecen en el index público de OTAs, Z2M permite apuntar a un repository propio:

```yaml
ota:
  zigbee_ota_override_index_location: 'https://raw.githubusercontent.com/Koenkk/zigbee-OTA/master/index.json'
  # O un fork propio con manifests adicionales.
```

> Usar con cuidado: un manifest mal firmado puede brickearle el firmware al dispositivo.

---

## Referencias

- **Imagen oficial Zigbee2MQTT**: https://hub.docker.com/r/koenkk/zigbee2mqtt
- **Documentación Z2M**: https://www.zigbee2mqtt.io/
- **Configuración (`configuration.yaml`)**: https://www.zigbee2mqtt.io/guide/configuration/
- **Adapters soportados**: https://www.zigbee2mqtt.io/guide/adapters/
- **Devices soportados**: https://www.zigbee2mqtt.io/supported-devices/
- **MQTT Topics & Messages**: https://www.zigbee2mqtt.io/guide/usage/mqtt_topics_and_messages.html
- **MQTT Discovery (HA)**: https://www.zigbee2mqtt.io/guide/usage/integrations/home_assistant.html
- **Releases / Changelog**: https://github.com/Koenkk/zigbee2mqtt/releases
- **Z-Stack Coordinator firmware**: https://github.com/Koenkk/Z-Stack-firmware
- **SONOFF Zigbee 3.0 USB Dongle Plus**: https://sonoff.tech/product/gateway-and-sensors/sonoff-zigbee-3-0-usb-dongle-plus/
- **Documentos del homelab relacionados**:
  - Hub central: [`./01-home-assistant.md`](./01-home-assistant.md)
  - Broker MQTT: [`./02-mosquitto.md`](./02-mosquitto.md)
  - Orquestador de flujos: [`./04-node-red.md`](./04-node-red.md)
  - Reverse proxy Caddy: [`../03-red/04-caddy.md`](../03-red/04-caddy.md)
  - SSO Authelia: [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)
  - Política Watchtower (Z2M excluido): [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)
  - Estructura de directorios `/mnt/hd2t/services/`: [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)
  - Convenciones Compose: [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)
  - Hardware (adaptador, USB, alargador): [`../00-hardware/01-material-necesario.md`](../00-hardware/01-material-necesario.md), [`../00-hardware/02-esquema-conexiones.md`](../00-hardware/02-esquema-conexiones.md)
  - Estrategia de backup: [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md)
  - Borgmatic: [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
  - Restore de servicios: [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md)
