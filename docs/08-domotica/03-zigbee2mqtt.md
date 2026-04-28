# Zigbee2MQTT

## Descripción

Con Home Assistant ya desplegado (`01-home-assistant.md`) y Mosquitto operativo como bus de mensajería (`02-mosquitto.md`), el homelab tiene **cerebro** y **nervios**, pero todavía no tiene **sentidos físicos**: una bombilla IKEA Tradfri, un sensor de movimiento Aqara, un enchufe Sonoff o un mando Hue todavía hablan **Zigbee**, no MQTT, y no se entienden con HA. Falta el traductor.

**Zigbee2MQTT** (en adelante, Z2M) es ese traductor. Conceptualmente es un *bridge*: por un lado habla **Zigbee** con un radio coordinador conectado por USB a la Pi; por el otro publica/lee **MQTT** contra Mosquitto. Cada dispositivo Zigbee aparece como un subárbol de tópicos en `zigbee2mqtt/<friendly_name>/...`, y HA lo descubre automáticamente como entidad nativa gracias a MQTT Discovery.

Este documento despliega Z2M y deja un único dispositivo de prueba emparejado para validar la cadena completa Zigbee → coordinador → Z2M → Mosquitto → HA. Su rol concreto:

1. **Hablar Zigbee 3.0** con el coordinador USB (SONOFF Zigbee 3.0 USB Dongle Plus, definido en `SERVICES.md` como hardware del homelab) usando el firmware Z-Stack 3.x. Z2M crea y mantiene la **red Zigbee** (PAN ID, canal, network key); todos los dispositivos emparejados forman parte de esa red.
2. **Traducir cada device** a tópicos MQTT semánticos: `zigbee2mqtt/sensor_salon/temperature → 21.4`, `zigbee2mqtt/luz_cocina/set → {"state":"ON","brightness":180}`. La biblioteca `zigbee-herdsman-converters` cubre ~3.500 dispositivos comerciales y la lista crece con cada release.
3. **Anunciarse a HA vía MQTT Discovery**: el primer dispositivo emparejado aparece en HA en `Settings → Devices & Services → MQTT` sin clic adicional, ya con sus entidades (`light.luz_cocina`, `sensor.sensor_salon_temperature`, etc.).
4. **Exponer su propia UI web** en `:8080` para emparejar, renombrar (`friendly_name`), inspeccionar topología (mesh map), forzar OTA y consultar logs. Esta UI no se usa en operación diaria — todo lo cotidiano vive en HA — pero es imprescindible durante el alta de dispositivos y troubleshooting.
5. **Mantener un backup del coordinador**: el fichero `coordinator_backup.json` permite restaurar la red Zigbee tal cual en otro coordinador idéntico sin re-emparejar dispositivo por dispositivo. Sin ese backup, una rotura del stick implica re-emparejar **todos** los dispositivos físicamente (caminar a cada bombilla, presionar el botón de pairing, esperar).

Lo que este documento **no** decide:

- **El catálogo concreto de dispositivos físicos** del operador. Z2M se despliega sin ningún device emparejado; el bloque "Configuración" cubre el pairing del primer dispositivo a modo de smoke test, no un inventario completo.
- **Las automatizaciones** que los dispositivos disparan: viven en HA (`automations.yaml`) o en Node-RED (`04-node-red.md`).
- **HACS / blueprints específicos por device** (mando IKEA con doble pulsación corta, etc.): cada blueprint se instala en HA cuando se tenga el dispositivo, no aquí.
- **Z-Wave, Matter, Thread, BLE**: protocolos hermanos sin cobertura en Z2M. Reabribles si el operador adquiere un coordinador específico (Z-Wave JS, Matter Server, OpenThread Border Router); cada uno sería su propio documento.
- **MQTT sobre TLS** entre Z2M y Mosquitto: descartado en `02-mosquitto.md` (LAN+tailnet, MQTT plano + auth + ACL). Z2M se conecta en `mosquitto:1883` por DNS interno del bridge.
- **Authelia delante de la UI de Z2M**: ver decisión específica abajo. Se aplica `lan_only` + auth básica nativa de Z2M, **no** se mete en `forward_auth` de Authelia (rompe con WebSockets de la UI de la misma forma que rompería con HA).

Cuando este documento se haya aplicado, el operador puede:

- Ver Z2M **`Up (healthy)`** en `docker ps`, conectado al coordinador (`zigbee2mqtt | Coordinator firmware version: 'Z-Stack 3.x.0'` en logs) y al broker (`Connected to MQTT server`).
- Abrir `https://z2m.${DOMAIN_LAN}/` en la LAN, autenticarse con la contraseña básica configurada y ver la UI de Z2M con la pestaña "Devices" vacía (o con el dispositivo de prueba si se completó el smoke test).
- Confirmar que HA muestra Z2M en `Settings → Devices & Services → MQTT → 1 device` (el bridge), y cada device emparejado aparece como entidad sin pasos manuales.
- Disponer de una topología de red Zigbee viable: `coordinator_backup.json` materializado en `hd2t`, network key persistida, listo para ampliar el parque de dispositivos en operación normal.

> **Recordatorio de alcance**: Z2M es **solo LAN + tailnet**. La UI publica solo en `https://z2m.${DOMAIN_LAN}` (Caddy con `lan_tls`); el puerto `:8080` no se publica al WAN. Zigbee es un protocolo de radio de corto alcance (~10–30 m en interior); por diseño **no sale de la casa**, es la capa más privada del homelab.

---

## Requisitos Previos

- **Fase 1** completa (sistema base, hostname `pi5`, zona horaria, locale, swap en hd2t).
- **Fase 2** completa (Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID=1000`, `PGID=1000`, `DOMAIN_LAN=lan`).
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre `z2m.${DOMAIN_LAN}` automáticamente).
  - Caddy desplegado y los snippets `(lan_tls)`, `(lan_only)`, `(security_headers)`, `(healthcheck)` en `Caddyfile`.
- **Fase 4** completa: Authelia existe pero **no** se usa con Z2M (decisión documentada abajo).
- **Documento `01-home-assistant.md` aplicado**: HA escuchando en `:8123` del host con la integración MQTT preparada (placeholder `mqtt_password` en `secrets.yaml` ya rellenado tras `02-mosquitto.md`).
- **Documento `02-mosquitto.md` aplicado**: Mosquitto en `:1883` accesible por `mosquitto:1883` desde el bridge `homelab`. Usuario `zigbee2mqtt` creado con ACL `readwrite zigbee2mqtt/#` + `read homeassistant/status` + `write homeassistant/+/+/config`.
- **Hardware**: SONOFF Zigbee 3.0 USB Dongle Plus (modelo `ITEAD ZBDongle-P`, chip CC2652P) enchufado a un puerto USB **3.0** **A** de la Pi 5. Recomendable: cable alargador USB 2.0 de 30–50 cm para alejar el stick de la fuente de WiFi/USB de la Pi (interferencia 2.4 GHz documentada).
- Disco `hd2t` montado en `/mnt/hd2t` con al menos **500 MiB** libres reservados para Z2M (`data` con `database.db`, logs, OTA cache).
- Operador con la **CA interna instalada** en el navegador (igual que para HA).

Comprobaciones rápidas:

```bash
# La red Docker compartida existe y Mosquitto está sano
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok
docker ps --filter name=mosquitto --format '{{.Names}} {{.Status}}'
# mosquitto   Up 1 hour (healthy)

# z2m.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short z2m.lan @192.168.1.2
# 192.168.1.10

# El stick está enchufado y reconocido por el kernel
lsusb | grep -i ITEAD
# Bus 003 Device 005: ID 1a86:55d4 QinHeng Electronics SONOFF Zigbee 3.0 USB Dongle Plus V2
# (o:    Bus 003 Device 005: ID 10c4:ea60 Silicon Labs CP210x UART Bridge   <- variante V1)

# Existe un path estable por by-id (CRÍTICO: no usar /dev/ttyUSB0 directamente)
ls -l /dev/serial/by-id/
# usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_<serial>-if00-port0 -> ../../ttyUSB0
# (o:    usb-1a86_USB_Single_Serial_<serial>-if00 -> ../../ttyACM0   <- variante V2)

# Espacio en hd2t
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'
# 1.5T libres
```

> **Sobre la variante del dongle**. SONOFF vende dos versiones físicamente similares con chips distintos:
> - **V1 / Plus** (`ZBDongle-P`): chip Texas Instruments **CC2652P**, USB-Serial CP210x. `adapter: zstack`. Recomendado: firmware Z-Stack 3.x.
> - **V2 / Plus-E** (`ZBDongle-E`): chip Silicon Labs **EFR32MG21**. `adapter: ember`. Firmware EmberZNet.
>
> Ambas funcionan con Z2M, pero los `adapter` y los procedimientos de actualización de firmware son distintos. **Este documento asume V1 / `ZBDongle-P`** (la variante recomendada en `SERVICES.md`). Si el operador tiene V2, sustituir `adapter: zstack` por `adapter: ember` en `configuration.yaml` y consultar [Z2M docs / Ember adapter](https://www.zigbee2mqtt.io/guide/adapters/emberznet.html); el resto del documento aplica idéntico.

> **Sobre la interferencia 2.4 GHz**. El stick va en USB 3.0; los puertos USB 3 de la Pi 5 emiten ruido en 2.4 GHz que degrada Zigbee si el coordinador está pegado al puerto. Usar **cable alargador USB 2.0** y separar el stick ≥ 20 cm de la Pi y de cualquier router/AP. Síntoma típico de interferencia: dispositivos al otro lado de la casa pierden mensajes (`Last seen` en Z2M va creciendo aunque el device esté presente).

---

## Decisión: integración Zigbee — Z2M vs ZHA vs deCONZ

Hay tres alternativas viables para hablar Zigbee desde el homelab:

| Opción | Qué es | Pros | Contras | Veredicto |
|---|---|---|---|---|
| **Z2M (Zigbee2MQTT)** | Servicio independiente que habla Zigbee con el coordinador y publica/lee en MQTT. UI propia. | (1) Catálogo enorme y activo (~3.500 devices). (2) Desacoplado de HA: si HA cae, Z2M sigue manteniendo la red Zigbee. (3) Backup del coordinador estandarizado. (4) Migrar HA a otro nodo no obliga a re-emparejar. (5) Ya tenemos Mosquitto desplegado: bus reutilizable. | Un contenedor más, una UI más. | **Aceptado**. |
| **ZHA (Zigbee Home Automation)** | Integración nativa dentro de Home Assistant. Habla Zigbee directamente desde el container de HA. | Cero stack extra. Configuración por UI. | (1) Catálogo más pequeño y dispositivos exóticos sin soporte. (2) Acopla la red Zigbee al ciclo de vida de HA: actualizar HA exige reiniciar la red. (3) Backup/restore más manual; cambio de coordinador implica re-pairing. | Descartado. |
| **deCONZ / ConBee II** | Stack de Phoscon (Dresden Elektronik) con su propio gateway y coordinador (ConBee II). Expone API REST + websocket; HA tiene integración. | Hardware específico bien soportado. UI propia. | (1) Atado al hardware ConBee II/RaspBee II (no al SONOFF que ya está comprado). (2) Catálogo menor que Z2M. (3) Ecosistema menos abierto. | Descartado por hardware. |

Resultado: **Z2M**. Implicaciones:

- Stack independiente en `stacks/zigbee2mqtt/`.
- Si HA se reinicia, la red Zigbee no se inmuta — los dispositivos siguen routing entre ellos y Z2M sigue capturando mensajes en MQTT (con `retain` para HA cuando vuelva).
- El backup de la red vive en `hd2t`, no en HA — sobrevive a un re-instalar HA desde cero.

> **Por qué no usar HA con ZHA y reservar Z2M para "casos especiales"**. Mantener dos stacks Zigbee compartiendo coordinador no es posible (un solo radio coordinador por red). Mantenerlos con dos radios sí, pero duplica hardware, complica troubleshooting y no aporta nada real.

---

## Decisión: imagen y versión

Z2M se distribuye por Koen Kanters (mantenedor principal) en Docker Hub bajo `koenkk/zigbee2mqtt`. Hay etiquetas:

| Tag | Qué es | Veredicto |
|---|---|---|
| `latest` | Última stable. | Descartado: política del homelab es pinear. |
| `1.41.0` (semver fija) | Versión exacta. Multi-arch (`linux/arm64`, `linux/amd64`, `linux/arm/v7`). | Aceptable para pin estricto. |
| `1.41` (rama menor móvil) | Recibe parches `1.41.x`. | **Aceptado**: paralelismo con la política de Mosquitto (`2.0`) y HA (`2024.10`). |
| `latest-dev` | Builds nightly desde master. | Descartado: rompe con frecuencia. |

**Tag exacto en uso**: `koenkk/zigbee2mqtt:1.41`. Política: pin a la rama menor; los bumps de minor (`1.41 → 1.42`) son **manuales** previa lectura de release notes (Z2M ocasionalmente cambia el formato de `database.db` o de tópicos MQTT, y un upgrade ciego puede romper integraciones).

> **Por qué no `latest`**. Z2M publica una release cada ~3 semanas. Un Watchtower que persiga `latest` puede dejar la red Zigbee sin convertir un día cualquiera porque cambió un campo en el JSON de un dispositivo concreto. Pin a la rama estable + actualización deliberada.

> **Política de actualización**:
> 1. Leer release notes en https://www.zigbee2mqtt.io/guide/installation/00_releases.html.
> 2. Backup del config: `sudo tar czf /mnt/hd2t/backups/z2m-pre-bump-$(date +%F).tgz -C /mnt/hd2t/apps zigbee2mqtt`.
> 3. Cambiar el tag en `docker-compose.yml`.
> 4. `docker compose -f stacks/zigbee2mqtt/docker-compose.yml pull && up -d`.
> 5. Verificar UI + dispositivos respondiendo + logs sin errores nuevos.

---

## Decisión: networking — bridge `homelab`, sin `host`, con UI publicada via Caddy

Z2M no necesita multicast (no hace mDNS): solo TCP unicast contra Mosquitto y HTTP para su UI. Puede vivir limpio en el bridge.

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| **Bridge `homelab` sin `ports:`, UI vía Caddy** | UI publicada en `https://z2m.${DOMAIN_LAN}`, no hay `:8080` directamente expuesto en LAN. Z2M habla con Mosquitto por DNS interno (`mosquitto:1883`). | Operador no puede saltarse Caddy en LAN. | **Aceptado**. |
| **Bridge `homelab` + `ports: ["8080:8080"]`** | UI directa en `192.168.1.10:8080` *además* de via Caddy. | Doble entrada confunde — uno con TLS y otro sin. | Descartado. |
| **`network_mode: host`** | Sin sentido aquí (no hay multicast). | Pierde DNS interno, rompe la convención. | Descartado. |

Resultado: **bridge `homelab`, sin `ports:`, UI vía Caddy con `lan_tls`**. Implicaciones:

1. **MQTT**: Z2M conecta a `mosquitto://zigbee2mqtt:<password>@mosquitto:1883`. Bridge → bridge, sin pasar por host: rendimiento y simplicidad.
2. **UI**: Caddy proxa `https://z2m.${DOMAIN_LAN}` → `http://zigbee2mqtt:8080`. WebSocket de la UI atravesado automáticamente por Caddy v2.
3. **Coordinador USB**: el dispositivo `/dev/serial/by-id/...` se monta directamente en el contenedor con `devices:`. La red bridge no afecta — USB es independiente del networking IP.
4. **Firewall del host**: no es necesario abrir `:8080` en `nftables`/`ufw`; Caddy es la única vía pública a la UI, en `:443`.

---

## Decisión: passthrough del adaptador USB con path estable

El kernel Linux asigna `/dev/ttyUSB0`, `/dev/ttyACM0`… **dinámicamente** por orden de enumeración. Si la Pi se reinicia con otro stick USB enchufado (un cargador, un periférico de teclado), el coordinador puede aparecer como `/dev/ttyUSB1` y Z2M no encontrarlo.

Opciones:

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| **Montar `/dev/ttyUSB0`** | Simple. | Rompe si el orden de enumeración cambia. | Descartado. |
| **Montar `/dev/serial/by-id/usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_<serial>-if00-port0`** | Estable, único por dispositivo (incluye número de serie del CP210x). El kernel mantiene este symlink siempre que el stick esté presente. | Path largo. | **Aceptado**. |
| **Crear regla udev `/etc/udev/rules.d/99-zigbee.rules` con `SYMLINK="zigbee0"`** | Path corto y bonito (`/dev/zigbee0`). | Otra capa que entender; el `by-id` ya es estable. | Reabrible (no necesario). |
| **Pasar `--privileged`** | Funciona "todo". | Excesivo, no se necesita. | Descartado. |

Resultado: **bind directo del path `by-id` + `cgroup_rules` para `tty`**. La línea exacta queda:

```yaml
devices:
  - /dev/serial/by-id/usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_<SERIAL>-if00-port0:/dev/ttyACM0
```

Dentro del contenedor el dispositivo aparece como `/dev/ttyACM0` (path simple); en el host queda inmutable por `by-id`. Si el operador tiene otro coordinador o cambia el stick, sustituye el `<SERIAL>`; el resto del compose no se toca.

> **Sobre permisos del device**. El stick aparece en host con `crw-rw---- root:dialout`. El proceso de Z2M dentro del contenedor corre como **root** por defecto (la imagen oficial lo hace así para evitar pelearse con `dialout` entre distros). Esto es consistente con HA Container — la imagen de Z2M no se ejecuta con `PUID/PGID` por la misma razón (acceso a `/dev/tty*` y, opcionalmente, a `bluetooth`). Veredicto: **no aplicar `user:`** en el compose; el contenedor se queda como root. Los datos en `hd2t` quedan owner `root:root` igual que con HA.

---

## Decisión: cómo hablar MQTT (URL, usuario, retención)

Z2M usa el usuario `zigbee2mqtt` (creado en `02-mosquitto.md` con su ACL). En `configuration.yaml`:

```yaml
mqtt:
  base_topic: zigbee2mqtt
  server: mqtt://mosquitto:1883
  user: zigbee2mqtt
  password: !secret mqtt_password
  client_id: zigbee2mqtt
  keepalive: 60
  reject_unauthorized: true
  version: 4   # MQTT 3.1.1 (default; cambiar a 5 si se quiere MQTT 5.0)
  include_device_information: true
```

Decisiones aplicadas:

- **`base_topic: zigbee2mqtt`** — coincide con la ACL del broker (`readwrite zigbee2mqtt/#`). No tocar a no ser que se cambie también la ACL.
- **`server: mqtt://mosquitto:1883`** — DNS interno del bridge `homelab`. **No** se usa `host.docker.internal` (Z2M está en bridge, no en host).
- **`user`/`password`**: el password vive en `secrets.yaml` de Z2M (`/app/data/secret.yaml`), nunca en el compose ni en `.env`. Esto sigue el patrón de HA.
- **`client_id: zigbee2mqtt`**: fijo. Si dos instancias compartiesen ID, el broker desconectaría a una. Único por convención.
- **`include_device_information: true`**: añade `manufacturer`, `model`, `ieee` a cada mensaje. Útil para debugging y para que HA muestre device info ricas en `Settings → Devices`.

> **Mensajes `retain`**. Z2M publica los estados de cada dispositivo con `retain: true` por defecto. Esto es lo que permite que HA, al arrancar, vea `light.luz_cocina = ON` antes de que la bombilla cambie de estado. Política coherente con Mosquitto (`persistence true`) — los retain sobreviven al reinicio del broker.

---

## Decisión: interfaz, canal y network key de Zigbee

Cuando Z2M arranca por primera vez **sin** `network_key` ni `pan_id` definidos, **genera ambos aleatoriamente** y los persiste en `data/configuration.yaml` y en la NVRAM del coordinador. **Esto es importante**:

| Parámetro | Qué es | Política |
|---|---|---|
| `pan_id` | ID de la red Zigbee, 16 bits. Distingue redes vecinas. | **Generado por Z2M al primer arranque**. Una vez fijado, **no se cambia** (cambiarlo expulsa a todos los devices). |
| `network_key` | Clave de cifrado AES-128 de la red. 16 bytes. | **Generada al primer arranque**. **Inmutable** salvo apocalipsis. |
| `extended_pan_id` | ID extendido de 64 bits. | **Generado**. Inmutable. |
| `channel` | Canal RF Zigbee (11–26 en banda 2.4 GHz). | **Default 11**, cambiable. Se discute abajo. |

Sobre el canal:

- **Canal 11** (default): solapa con WiFi 1. Mala idea si el WiFi de casa va por canal 1.
- **Canal 15**: solapa con WiFi 6. Mala idea si el WiFi va por canal 6.
- **Canal 20**: gap entre WiFi 6 y 11. Buena opción si WiFi va por 6.
- **Canal 25**: gap encima de WiFi 11. Buena opción si WiFi va por 11.
- **Canal 26**: el más alto, con menos competencia, pero algunos dispositivos antiguos no lo soportan bien.

Política: **dejar canal en 11 al primer arranque** (el default de Z2M), y solo cambiarlo si tras unas semanas se ven pérdidas notables. Cambiar el canal **rompe** la red — todos los dispositivos quedan offline hasta que cada uno descubra el nuevo (algunos dispositivos End Device, como sensores, **no** lo descubren y hay que re-emparejar). Es decisión de "cuando hay un problema medible", no preventiva.

> **CRÍTICO: backup del network_key**. `data/configuration.yaml` contiene la `network_key` en claro. Pérdida del fichero = red Zigbee inaccesible (un nuevo coordinador con el mismo PAN ID **no** puede unirse a los dispositivos sin la key). Borgmatic lo respalda en T1 (secretos). Adicionalmente, **al primer arranque** el operador exporta la key y la guarda en su gestor de contraseñas (paso documentado en "Configuración").

---

## Decisión: UI — autenticación básica nativa de Z2M, **no** Authelia

Z2M expone un dashboard web en `:8080` con la pestaña "Devices", "Map", "Logs", "Settings". Tiene **autenticación nativa por token** (un solo token compartido, contraseña simple).

Opciones:

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| **Z2M sin auth + Caddy con `(authelia_two_factor)`** | SSO con el resto del homelab. | El frontend de Z2M usa **WebSocket** intensivamente (`/api/`); Authelia rompe la conexión inicial y el operador ve "Connecting…" perpetuo. Se podría exonerar `/api/*`, pero entonces la auth se vuelve cosmética. | Descartado. |
| **Z2M con `auth_token` + Caddy con `(lan_only)` + `(lan_tls)`** | Doble barrera: solo accesible desde LAN (o tailnet), y aun así pide token. WebSockets funcionan sin más. | El token es único — no hay multiusuario. Adecuado para un homelab personal/familiar. | **Aceptado**. |
| **Z2M sin auth + acceso restringido por firewall a IPs específicas** | Sin contraseña que recordar. | Cualquiera en LAN entra. Dispositivo IoT comprometido = control total de la red Zigbee. | Descartado. |

Resultado: **`auth_token` en `configuration.yaml` + bloque Caddy con `lan_only` + `lan_tls`**. El token se genera con `openssl rand -base64 24` y se guarda en el gestor de contraseñas del operador. La UI pedirá el token al primer acceso desde cada navegador y lo guardará en `localStorage`.

> **Sobre WebSockets de Z2M y Caddy**. Z2M la API REST + WebSocket en `/api/`. Caddy v2 detecta y proxa WS automáticamente desde 2.0; no hace falta `header_up Connection` ni `Upgrade`. Lo que sí hace falta es que Caddy resuelva `zigbee2mqtt` por DNS interno del bridge — automático ya que ambos están en `homelab`.

---

## Decisión: Frontend, OTA, Mesh map y advanced

Bloques opcionales de `configuration.yaml`:

| Opción | Default | Política |
|---|---|---|
| `frontend.host: 0.0.0.0` + `frontend.port: 8080` | OFF | **ON**. Sin frontend, no hay UI; sin UI, no se empareja. |
| `frontend.auth_token` | OFF | **ON**, con token generado con `openssl rand -base64 24`. |
| `homeassistant: true` (MQTT Discovery) | OFF | **ON**. Sin esto, hay que añadir cada dispositivo manualmente en HA. Es **el** motivo de usar Z2M con HA. |
| `permit_join` | `false` (Z2M ≥ 1.30) | **false**. Solo se activa por la UI cuando el operador empareja un device. **No** dejar permanentemente en `true` (cualquiera con un dispositivo Zigbee a 30m podría unirse y formar parte de la red). |
| `availability` | OFF en 1.x; el frontend muestra "Last seen". | **ON con default** (`active: 10 min`, `passive: 25 h`): publica `zigbee2mqtt/<device>/availability` con `online`/`offline` para que HA tenga sensores binarios `binary_sensor.<device>_availability`. |
| `advanced.log_level` | `info` | **`info`**. Subir a `debug` solo durante troubleshooting (logs crecen ~10×). |
| `advanced.log_output: ["console"]` | console+file | **console-only**: Docker captura stdout. Igual que con Mosquitto, un solo origen de verdad. |
| `advanced.network_key: GENERATE` | GENERATE en primer arranque | Dejar `GENERATE` la primera vez. Z2M lo sustituirá en disco por la key real. |
| `advanced.pan_id: GENERATE` | GENERATE | Idem. |
| `advanced.channel` | 11 | Dejar 11. Cambiar solo si hay interferencia medible. |
| `advanced.transmit_power` | 5 (dBm) | **dejar default** para CC2652P (`5`). Subirlo aumenta consumo y no siempre mejora alcance. |
| `advanced.last_seen: ISO_8601` | `disable` | **`ISO_8601`**: añade un campo `last_seen` ISO-8601 a cada mensaje publicado. Útil para "este sensor lleva muerto 3 días" sin instrumentación extra. |
| `ota.update_check_interval` | 1440 (min, = 24h) | **1440**. Z2M chequea OTAs disponibles para cada device una vez al día. La actualización en sí es manual desde la UI. |
| `serial.adapter: zstack` | autodetect | **`zstack`** explícito (variante V1/Plus, chip CC2652P). |
| `serial.port: /dev/ttyACM0` | autodetect | **explícito**. El device dentro del contenedor (montado desde `by-id` del host). |

---

## Stack: `stacks/zigbee2mqtt/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/zigbee2mqtt/docker-compose.yml` | microSD (git) | Stack (servicio `zigbee2mqtt`). |
| `stacks/zigbee2mqtt/.env.example` | microSD (git) | Plantilla con `Z2M_*`. |
| `stacks/zigbee2mqtt/configuration.yaml.skel` | microSD (git) | Esqueleto de `configuration.yaml`. **No** contiene secretos. |
| `stacks/zigbee2mqtt/secret.yaml.example` | microSD (git) | Plantilla de `secret.yaml`. **No** versionar el real. |
| `stacks/caddy/conf.d/08-zigbee2mqtt.caddy` | microSD (git) | Drop-in del bloque LAN para `z2m.${DOMAIN_LAN}`. |
| `/mnt/hd2t/apps/zigbee2mqtt/data/` | hd2t | Configuración materializada + estado interno. Owner `root:root`. |
| `/mnt/hd2t/apps/zigbee2mqtt/data/configuration.yaml` | hd2t | Configuración principal (incluye `network_key` real tras primer arranque). |
| `/mnt/hd2t/apps/zigbee2mqtt/data/secret.yaml` | hd2t | Secretos (`mqtt_password`, `frontend_auth_token`). Modo `0600`. |
| `/mnt/hd2t/apps/zigbee2mqtt/data/database.db` | hd2t | BBDD interna (devices, bindings, groups). Texto plano JSON-líneas. |
| `/mnt/hd2t/apps/zigbee2mqtt/data/coordinator_backup.json` | hd2t | Backup de la red Zigbee (PAN ID, key, frame counter). **CRÍTICO**. |
| `/mnt/hd2t/apps/zigbee2mqtt/data/state.json` | hd2t | Estado runtime (último estado conocido por device). |
| `/mnt/hd2t/apps/zigbee2mqtt/data/log/` | hd2t | Logs (en disco) — vacío con `log_output: ["console"]`. |

### `stacks/zigbee2mqtt/docker-compose.yml`

```yaml
# Zigbee2MQTT — bridge Zigbee <-> MQTT del homelab.
# Documentado en docs/08-domotica/03-zigbee2mqtt.md.

name: zigbee2mqtt

services:
  zigbee2mqtt:
    image: koenkk/zigbee2mqtt:1.41
    container_name: zigbee2mqtt
    hostname: zigbee2mqtt
    restart: unless-stopped

    # Bridge homelab — habla con mosquitto:1883 por DNS interno.
    # No se publican puertos: la UI (8080) sale via Caddy en z2m.${DOMAIN_LAN}.
    networks:
      - homelab

    # Coordinador USB SONOFF Zigbee 3.0 USB Dongle Plus.
    # SUSTITUIR <SERIAL> por el ID real:
    #   ls /dev/serial/by-id/
    # Path estable; resiste reordenamiento de /dev/ttyUSBN.
    devices:
      - /dev/serial/by-id/usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_<SERIAL>-if00-port0:/dev/ttyACM0

    # group_add con el GID de 'dialout' del host (suele ser 20 en Debian).
    # Permite al proceso interno acceder a /dev/ttyACM0 sin --privileged.
    # Verificar con `getent group dialout` en el host:
    #   dialout:x:20:homelab
    group_add:
      - "20"

    environment:
      TZ: ${TZ}
      # Z2M lee este path para localizar configuration.yaml.
      ZIGBEE2MQTT_DATA: /app/data
      # Habilita resolución de !secret en configuration.yaml (default).
      # ZIGBEE2MQTT_CONFIG_MQTT_PASSWORD: '!secret mqtt_password'   # alternativa por env

    volumes:
      - /mnt/hd2t/apps/zigbee2mqtt/data:/app/data
      # Sincronizar la hora con el host (logs y last_seen consistentes).
      - /etc/localtime:/etc/localtime:ro
      # Necesario para zigbee-herdsman: detectar tiempo del kernel.
      - /run/udev:/run/udev:ro

    healthcheck:
      # /api/info responde 200 con JSON. Es la ruta que la UI consume al cargar.
      # No requiere auth.
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8080/ >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 60s   # primer arranque: forma red, lee NVRAM del coordinador (~30s)

    depends_on:
      mosquitto:
        condition: service_healthy
        required: false
      # required:false: si Mosquitto NO está, Z2M arranca igual y reintenta cada 10s.
      # Es deliberado: Z2M debe poder arrancar antes que Mosquitto en bootstrap, y
      # tolerar cortes momentáneos del broker sin caerse.

    labels:
      homelab.role: "zigbee-bridge"
      homelab.backup: "true"
      # Watchtower respeta el pin a 1.41.x (parches), no salta a 1.42.
      com.centurylinklabs.watchtower.enable: "true"

networks:
  homelab:
    external: true
```

> **Sobre `group_add: ["20"]`**. El GID `20` corresponde a `dialout` en Raspberry Pi OS / Debian. Si en otra distro `dialout` tuviese otro GID, ajustar. La razón de necesitarlo: el proceso interno de Z2M corre como root pero algunos kernels modernos exigen pertenencia explícita al grupo del device para `tty`. Es defensa en profundidad — incluso si en algún update Z2M dejase de correr como root, seguiría leyendo el dongle.

> **Sobre `depends_on` con `required: false`**. Compose v2 lo soporta desde 2.20. El efecto es: si Mosquitto no está corriendo en el momento de `up`, Z2M arranca igual y la conexión MQTT entra en modo "reconnect" hasta que el broker aparezca. Esto es lo que se quiere — la red Zigbee no debe estar atada al ciclo de vida del broker.

> **Sobre `/run/udev:/run/udev:ro`**. Algunas versiones de `zigbee-herdsman` (la librería que habla con el stick) leen `udevadm` para identificar el adaptador. Sin `/run/udev` el primer arranque a veces falla con `Adapter is not responding`. Montarlo `:ro` es inocuo.

### `stacks/zigbee2mqtt/.env.example`

```bash
# stacks/zigbee2mqtt/.env.example
# Variables específicas del stack Zigbee2MQTT. Las generales (TZ)
# vienen del .env GLOBAL del homelab.
#
# Las contraseñas REALES (mqtt_password, frontend_auth_token) NO viven
# aquí: están en /mnt/hd2t/apps/zigbee2mqtt/data/secret.yaml (modo 0600,
# referenciado desde configuration.yaml con !secret).
#
# (Vacío hoy: este stack no usa variables de entorno propias.)
```

### `stacks/zigbee2mqtt/configuration.yaml.skel`

Esqueleto del primer arranque. Z2M lo respeta y va escribiendo en él (devices emparejados, network_key generada).

```yaml
# /app/data/configuration.yaml — Zigbee2MQTT.
# Documentado en docs/08-domotica/03-zigbee2mqtt.md.
#
# Z2M EDITA este fichero al emparejar dispositivos y al primer arranque
# (sustituye GENERATE por valores reales de network_key/pan_id).
# El fichero ES tanto config como estado parcial; Borgmatic lo respalda T1.

# ---------------------------------------------------------------------------
# Versionado del schema. Mantenido por Z2M. No tocar a mano.
# ---------------------------------------------------------------------------
version: 4

# ---------------------------------------------------------------------------
# MQTT — bus de comunicación con el resto del homelab.
# ---------------------------------------------------------------------------
mqtt:
  base_topic: zigbee2mqtt
  server: mqtt://mosquitto:1883
  user: zigbee2mqtt
  password: !secret mqtt_password
  client_id: zigbee2mqtt
  keepalive: 60
  reject_unauthorized: true
  version: 4
  include_device_information: true

# ---------------------------------------------------------------------------
# Adaptador serie — coordinador USB.
# ---------------------------------------------------------------------------
serial:
  port: /dev/ttyACM0
  adapter: zstack
  # disable_led: true   # apaga LED del stick (cosmético; si molesta de noche).

# ---------------------------------------------------------------------------
# Frontend (UI web). Caddy proxa z2m.${DOMAIN_LAN} -> http://zigbee2mqtt:8080.
# ---------------------------------------------------------------------------
frontend:
  host: 0.0.0.0
  port: 8080
  auth_token: !secret frontend_auth_token

# ---------------------------------------------------------------------------
# Discovery automático en Home Assistant.
# Tras esto, cada device emparejado aparece en HA en segundos.
# ---------------------------------------------------------------------------
homeassistant:
  enabled: true
  discovery_topic: homeassistant
  status_topic: homeassistant/status
  legacy_entity_attributes: false
  legacy_triggers: false

# ---------------------------------------------------------------------------
# Permit join — DESACTIVADO por defecto. Solo se enciende manualmente
# desde la UI cuando se va a emparejar un device, y se desactiva tras 254s.
# ---------------------------------------------------------------------------
permit_join: false

# ---------------------------------------------------------------------------
# Availability — publica online/offline de cada device en MQTT.
# ---------------------------------------------------------------------------
availability:
  active:
    timeout: 10        # min — devices con poll activo
  passive:
    timeout: 1500      # min (25 h) — sensores de batería, no se les molesta

# ---------------------------------------------------------------------------
# OTA — chequeo diario, ejecución manual desde la UI.
# ---------------------------------------------------------------------------
ota:
  update_check_interval: 1440
  disable_automatic_update_check: false

# ---------------------------------------------------------------------------
# Avanzado.
# ---------------------------------------------------------------------------
advanced:
  log_level: info
  log_output:
    - console
  log_directory: /app/data/log/%TIMESTAMP%   # vacío en práctica con console-only

  last_seen: ISO_8601                        # timestamp ISO en cada mensaje

  # Network key, PAN ID y extended PAN ID se autogeneran al primer arranque.
  # Tras ese primer up, Z2M sustituye GENERATE por valores reales y los persiste
  # aquí. Esos valores son INMUTABLES en operación normal.
  network_key: GENERATE
  pan_id: GENERATE
  ext_pan_id: GENERATE

  channel: 11
  transmit_power: 5

  # Concurrent: cuántos comandos en paralelo a la red. Default ok para Pi 5.
  # adapter_concurrent: null

# ---------------------------------------------------------------------------
# Devices — Z2M lo escribe automáticamente al emparejar.
# Vacío al inicio.
# ---------------------------------------------------------------------------
devices: {}
groups: {}
```

### `stacks/zigbee2mqtt/secret.yaml.example`

```yaml
# /app/data/secret.yaml.example — plantilla.
# El fichero real (`secret.yaml`) NO se versiona. Modo 0600.
# Se referencia desde configuration.yaml con `!secret <clave>`.

# Password del usuario zigbee2mqtt en Mosquitto (creado en 02-mosquitto.md).
# Generar con: openssl rand -base64 24  (o reusar el ya existente del paso
# de bootstrap de Mosquitto).
# mqtt_password: <Z2M_PWD generado en 02-mosquitto.md>

# Token para la UI web. Generar con: openssl rand -base64 24
# frontend_auth_token: <token>
```

### Drop-in de Caddy: `stacks/caddy/conf.d/08-zigbee2mqtt.caddy`

```caddy
# /etc/caddy/conf.d/08-zigbee2mqtt.caddy — bloque LAN para Zigbee2MQTT.
# Documentado en docs/08-domotica/03-zigbee2mqtt.md.
#
# IMPORTANTE: NO se importa authelia_two_factor (decisión documentada
# en "Decisión: UI"). Z2M usa su propio auth_token + lan_only.

z2m.{$DOMAIN_LAN} {
    import lan_tls
    import lan_only          # restringe a 192.168.1.0/24 + tailscale CGNAT
    import security_headers
    import healthcheck

    # Z2M está en el bridge homelab; se referencia por nombre de servicio.
    # Caddy v2 detecta WebSockets en /api/ y los proxa automáticamente.
    reverse_proxy http://zigbee2mqtt:8080 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        transport http {
            read_timeout 5m
            write_timeout 5m
        }
    }
}
```

### Crear los directorios persistentes y desplegar

```bash
# Directorios — owner root:root (la imagen de Z2M corre como root,
# igual que HA). 0750 para limitar lectura al operador via setfacl.
sudo install -d -o root -g root -m 0750 /mnt/hd2t/apps/zigbee2mqtt
sudo install -d -o root -g root -m 0750 /mnt/hd2t/apps/zigbee2mqtt/data
sudo install -d -o root -g root -m 0750 /mnt/hd2t/apps/zigbee2mqtt/data/log

# ACL para que el operador (homelab) pueda leer la config sin sudo.
sudo setfacl -R -m u:homelab:rx /mnt/hd2t/apps/zigbee2mqtt/data
sudo setfacl -d -m u:homelab:rx /mnt/hd2t/apps/zigbee2mqtt/data

# Materializar configuración inicial (skel) y secret vacío.
cd /home/homelab/homelab
sudo install -o root -g root -m 0640 \
    stacks/zigbee2mqtt/configuration.yaml.skel \
    /mnt/hd2t/apps/zigbee2mqtt/data/configuration.yaml
sudo install -o root -g root -m 0600 \
    stacks/zigbee2mqtt/secret.yaml.example \
    /mnt/hd2t/apps/zigbee2mqtt/data/secret.yaml

# Generar el frontend_auth_token y rellenar secret.yaml.
# El mqtt_password ya se generó y guardó en 02-mosquitto.md (Z2M_PWD).
FRONTEND_TOKEN=$(openssl rand -base64 24)
echo "frontend_auth_token: $FRONTEND_TOKEN"
echo "---> Copiar al gestor de contraseñas AHORA. Se usa al primer login en z2m.lan."
read -p "Pulsa Enter cuando esté guardado..." _

sudo tee /mnt/hd2t/apps/zigbee2mqtt/data/secret.yaml >/dev/null <<EOF
mqtt_password: <Z2M_PWD del paso 02-mosquitto.md>
frontend_auth_token: $FRONTEND_TOKEN
EOF
sudo chmod 0600 /mnt/hd2t/apps/zigbee2mqtt/data/secret.yaml

# Editar manualmente para sustituir <Z2M_PWD>:
sudo -e /mnt/hd2t/apps/zigbee2mqtt/data/secret.yaml

# Identificar el path estable del coordinador USB.
ls /dev/serial/by-id/
# usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_20240118115232-if00-port0
SERIAL_PATH=$(ls /dev/serial/by-id/ | grep -i 'ITEAD\|SONOFF' | head -1)
echo "Coordinator path: /dev/serial/by-id/$SERIAL_PATH"
# Sustituir <SERIAL> en stacks/zigbee2mqtt/docker-compose.yml por el valor real.

# Drop-in de Caddy.
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/08-zigbee2mqtt.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/08-zigbee2mqtt.caddy

# .env del stack (vacío en esta fase).
cp stacks/zigbee2mqtt/.env.example stacks/zigbee2mqtt/.env
chmod 0600 stacks/zigbee2mqtt/.env

# Levantar Zigbee2MQTT.
docker compose \
    -f stacks/zigbee2mqtt/docker-compose.yml \
    --env-file .env --env-file stacks/zigbee2mqtt/.env \
    up -d

# Recargar Caddy para que tome el nuevo drop-in.
docker exec caddy caddy validate --config /etc/caddy/Caddyfile && \
    docker kill --signal=SIGUSR1 caddy
```

Tras `up -d`:

```bash
docker ps --filter name=zigbee2mqtt
# CONTAINER ID  IMAGE                       STATUS
# ...           koenkk/zigbee2mqtt:1.41     Up 60 seconds (healthy)

# Logs del primer arranque — debe verse:
docker logs zigbee2mqtt --tail 40
# [...] Logging to console
# [...] Starting Zigbee2MQTT version 1.41.0 (commit #...)
# [...] Starting zigbee-herdsman (0.x.x)
# [...] zigbee-herdsman started (resumed)
# [...] Coordinator firmware version: 'Z-Stack 3.x.0'
# [...] Currently 0 devices are joined:
# [...] Zigbee: disabling joining new devices.
# [...] Connecting to MQTT server at mqtt://mosquitto:1883
# [...] Connected to MQTT server
# [...] MQTT publish: topic 'zigbee2mqtt/bridge/state', payload '{"state":"online"}'
# [...] Started frontend on port 8080
```

> **Síntomas de éxito en el primer arranque**: `Coordinator firmware version`, `0 devices are joined`, `Connected to MQTT server`, `Started frontend`. Si **cualquiera** de estos falta, ir a la sección "Errores frecuentes".

> **Network key generada**. Tras este primer arranque, `data/configuration.yaml` ha sido reescrito por Z2M: `network_key: [123, 45, ...]` (16 bytes), `pan_id: 0xABCD`, `ext_pan_id: [...]`. **Hacer backup AHORA**:
> ```bash
> sudo tar czf /mnt/hd2t/backups/z2m-genesis-$(date +%F).tgz \
>     -C /mnt/hd2t/apps zigbee2mqtt/data/configuration.yaml \
>                       zigbee2mqtt/data/coordinator_backup.json
> ```
> Y guardar el contenido de `network_key` en el gestor de contraseñas. Borgmatic seguirá respaldándolo en T1, pero un backup *out-of-band* el día 1 cubre el "y si Borg cae antes del primer ciclo".

---

## Configuración

### 1) Verificar UI accesible y autenticación

Desde un cliente de la LAN con la CA interna instalada:

```text
1. Abrir https://z2m.lan/
2. La UI pide "Authentication required" (auth_token).
3. Pegar el FRONTEND_TOKEN guardado.
4. La UI carga: "Devices" (vacía), "Map" (vacío), "Logs" (live tail), "Settings".
5. La pestaña "Bridge info" muestra:
   - Coordinator firmware: Z-Stack 3.x.0
   - Permit join: false
   - Network key: <hex>   (¡no compartir!)
   - PAN ID:    0xABCD
   - Channel:   11
```

> **Si la UI da "Connecting…" perpetuo**: WebSocket bloqueado. Verificar Caddy con `docker logs caddy | tail -20` buscando errores de upgrade. Lo más común: alguien añadió `forward_auth` al bloque de Caddy ignorando la decisión documentada. Quitarlo, recargar Caddy.

### 2) Verificar la integración MQTT con HA

```bash
# Subscribirse al estado del bridge desde la Pi.
mosquitto_sub -h 127.0.0.1 -p 1883 -u admin -P "$ADM_PWD" \
    -t 'zigbee2mqtt/bridge/state' -C 1
# {"state":"online"}

# Y al estado de discovery del bridge.
mosquitto_sub -h 127.0.0.1 -p 1883 -u admin -P "$ADM_PWD" \
    -t 'zigbee2mqtt/bridge/info' -C 1
# {"version":"1.41.0","commit":...,"coordinator":{"type":"zStack3x0",...}, ...}
```

En HA:

```text
1. https://home.lan/  → Settings → Devices & Services → MQTT.
2. Click en MQTT → "1 device" o más:
   - "Zigbee2MQTT Bridge" (manufacturer: Zigbee2MQTT, model: Bridge).
3. Entrar en "Zigbee2MQTT Bridge": entidades de control (permit_join,
   restart, log_level, etc.) y diagnósticos (version, network channel).
```

> **Si HA no muestra el bridge**: verificar `homeassistant.enabled: true` en `configuration.yaml` y que la integración MQTT en HA tiene `Discovery: ON` con prefix `homeassistant`. Reiniciar Z2M tras cualquier cambio: `docker compose -f stacks/zigbee2mqtt/docker-compose.yml restart zigbee2mqtt`.

### 3) Emparejar el primer dispositivo (smoke test)

Tener a mano un dispositivo Zigbee 3.0 — sirve un sensor de temperatura barato (Aqara WSDCGQ11LM, Sonoff SNZB-02), un enchufe (Sonoff S26R2ZB), o cualquier bombilla IKEA Tradfri.

```text
1. UI de Z2M (https://z2m.lan/) → "Devices" → botón "Permit join (All)".
2. La UI muestra "Joining is permitted for ALL devices for 254s".
3. Poner el dispositivo en modo pairing (factory reset):
   - Aqara: pulsar el botón pequeño durante 5s hasta que parpadee 3 veces.
   - Sonoff sensor: pulsar el botón durante 5s.
   - IKEA Tradfri bulb: 6 ciclos de power on/off rápidos.
   - Tradfri remote: pulsar el botón de pairing 4 veces.
4. La UI muestra "Interview started for 0x00158d0001234567".
5. Tras 5–30 s: "Interview successful". El device aparece en la lista
   con su modelo identificado.
6. Click en el device → "Settings (specific)":
   - Friendly name: "sensor_salon" (sin espacios, snake_case).
   - Confirmar guardado.
7. Volver a "Devices" y desactivar "Permit join".
```

Verificación cruzada en HA:

```text
1. https://home.lan/ → Settings → Devices & Services → MQTT.
2. "X devices" debe haber subido en 1.
3. Click → "Sensor Salon" (HA hace title case del friendly_name).
4. Las entidades aparecen automáticamente:
   - sensor.sensor_salon_temperature
   - sensor.sensor_salon_humidity
   - sensor.sensor_salon_battery
   - sensor.sensor_salon_linkquality
   - binary_sensor.sensor_salon_availability
5. Developer Tools → States → buscar "sensor_salon": valores reales,
   no "unknown".
```

> **Si tras "Interview successful" las entidades no aparecen en HA**: revisar la ACL del usuario `zigbee2mqtt` en Mosquitto (debe tener `topic write homeassistant/+/+/config` y `homeassistant/+/+/+/config`). `docker exec mosquitto kill -HUP 1` para recargar; reiniciar Z2M para forzar republicación de discovery.

### 4) Operación diaria

| Acción | Comando / lugar |
|---|---|
| Ver UI | `https://z2m.lan/` |
| Ver logs activos | `docker logs zigbee2mqtt -f` o pestaña "Logs" en UI |
| Permit join temporal | UI → botón "Permit join (All)" — se desactiva auto a los 254s |
| Renombrar device | UI → device → Settings → "Friendly name" |
| Eliminar device | UI → device → "Delete" (con `force: false` si está vivo, `force: true` si está muerto) |
| Forzar OTA de un device | UI → device → tab "OTA" → "Update available" → "Update" |
| Mesh map (topología) | UI → "Map" → click "Refresh" (tarda ~30 s) |
| Backup manual del coordinador | UI → Settings → tab "Bridge" → "Coordinator backup" → descargar JSON |
| Reiniciar bridge sin restart de container | UI → Settings → tab "Bridge" → "Restart Zigbee2MQTT" |
| Actualizar Z2M (manual) | leer release notes → bump tag en compose → `docker compose pull && up -d` |
| Tamaño de la BBDD | `du -sh /mnt/hd2t/apps/zigbee2mqtt/data/` |

### 5) Convenciones de naming de devices

Política sugerida (no enforzada por código; sí por costumbre):

```text
<tipo>_<ubicación>[_<descriptor>]
```

| Friendly name | Descripción |
|---|---|
| `sensor_salon` | Sensor genérico (temp+hum) en el salón |
| `sensor_dormitorio_ana` | Sensor en el dormitorio de Ana |
| `luz_cocina_techo` | Bombilla de techo en la cocina |
| `enchufe_lavadora` | Enchufe de la lavadora |
| `puerta_entrada` | Sensor de apertura de la puerta |
| `mando_salon` | Mando IKEA en el salón |
| `motion_pasillo` | Sensor de movimiento del pasillo |

Reglas:

1. **`snake_case`** estricto, sin espacios, sin acentos (los acentos rompen alguna integración antigua de HA).
2. **`tipo`** primero — facilita autocompletar en HA (`sensor_*`, `luz_*`, `enchufe_*`).
3. **Si hay dos del mismo tipo en la misma ubicación**, añadir descriptor (`luz_cocina_techo`, `luz_cocina_isla`).

Renombrar después es seguro pero no gratis: HA conserva el `unique_id` del device, así que las automatizaciones rotas se reescriben con el nuevo nombre. Hacerlo *durante* el pairing (paso 6 del smoke test) es la vía limpia.

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/zigbee2mqtt/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/zigbee2mqtt/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/zigbee2mqtt/configuration.yaml.skel` | microSD | `homelab:homelab` | `0644` | Esqueleto. |
| `/home/homelab/homelab/stacks/zigbee2mqtt/secret.yaml.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/caddy/conf.d/08-zigbee2mqtt.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy. |
| `/mnt/hd2t/apps/zigbee2mqtt/data/` | hd2t | `root:root` | `0750` | Configuración + estado. |
| `/mnt/hd2t/apps/zigbee2mqtt/data/configuration.yaml` | hd2t | `root:root` | `0640` | Config principal **y** network_key/pan_id reales. |
| `/mnt/hd2t/apps/zigbee2mqtt/data/secret.yaml` | hd2t | `root:root` | `0600` | `mqtt_password`, `frontend_auth_token`. |
| `/mnt/hd2t/apps/zigbee2mqtt/data/database.db` | hd2t | `root:root` | `0640` | BBDD de devices/groups (JSON-líneas, no SQLite). |
| `/mnt/hd2t/apps/zigbee2mqtt/data/coordinator_backup.json` | hd2t | `root:root` | `0640` | **Backup CRÍTICO** del estado del coordinador (frame counter, key, ...). |
| `/mnt/hd2t/apps/zigbee2mqtt/data/state.json` | hd2t | `root:root` | `0640` | Último estado conocido por device. Regenerable. |
| `/mnt/hd2t/apps/zigbee2mqtt/data/log/` | hd2t | `root:root` | `0750` | Vacío (`log_output: console`). |

> **Tamaño esperado**. Para una casa con ~30 dispositivos Zigbee, `data/` se estabiliza en torno a **5–15 MiB**. La BBDD `database.db` crece pocos KiB por device emparejado. Si crece a >100 MiB, hay logs en disco activos (revisar `log_output`) o un device generando MQTT en bucle.

> **Por qué no microSD**. Z2M escribe en `database.db` cada vez que un device hace algo persistente (cambio de OTA, re-binding). Frecuencia baja, pero igualmente prefiere hd2t por consistencia. Adicionalmente, perder la microSD no debe implicar perder la network key — y un backup en `hd2t` cubre eso.

> **Sobre `coordinator_backup.json`**. Z2M lo regenera automáticamente al menos una vez al día. Es el fichero **más crítico** del stack: con él + un coordinador idéntico (otro SONOFF Plus) + la mismaNetwork key, se puede *resucitar* la red Zigbee sin re-emparejar nada (los dispositivos no notarán el cambio). Sin él, cambiar el coordinador implica fábrica → permit join → emparejar 30 dispositivos a mano. La diferencia: 5 minutos vs. una tarde entera.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/zigbee2mqtt/docker-compose.yml`, `configuration.yaml.skel`, `.env.example`, `secret.yaml.example` | Versionados. |
| `stacks/caddy/conf.d/08-zigbee2mqtt.caddy` | Versionado. |
| Decisiones (Z2M sobre ZHA, koenkk:1.41, bridge-only, by-id passthrough, auth_token sin Authelia) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Tier (`07-backups/01-estrategia-backup.md`) | Por qué |
|---|---|---|---|
| `/mnt/hd2t/apps/zigbee2mqtt/data/configuration.yaml` | Sí. | T1 (secretos). | Contiene `network_key` en claro y la asignación `friendly_name → ieee`. **Crítico**. |
| `/mnt/hd2t/apps/zigbee2mqtt/data/secret.yaml` | Sí. | T1 (secretos). | `mqtt_password` y `frontend_auth_token`. |
| `/mnt/hd2t/apps/zigbee2mqtt/data/database.db` | Sí. | T1 (secretos). | Devices, bindings, groups. **Sin esto** Z2M arranca virgen tras un restore. |
| `/mnt/hd2t/apps/zigbee2mqtt/data/coordinator_backup.json` | Sí. | T1 (secretos). | El "Plan B" frente a stick muerto. **Imprescindible**. |
| `/mnt/hd2t/apps/zigbee2mqtt/data/state.json` | Sí. | T2 | Conveniencia: tras restore, los devices no tienen que esperar a su próximo report para mostrar valor; ya viene del backup. |
| `/mnt/hd2t/apps/zigbee2mqtt/data/log/*` | **No.** | T4 | Vacío con `log_output: console`. |

Entrada en `borgmatic.yaml` (parche relativo al patrón de `07-backups/02-borgmatic.md`):

```yaml
source_directories:
  # ...
  - /mnt/hd2t/apps/zigbee2mqtt/data

# Excluir log directory regenerable (vacío en práctica)
patterns:
  # ...
  - '!/mnt/hd2t/apps/zigbee2mqtt/data/log'

# No hace falta hook before_backup: la BBDD de Z2M es JSON-líneas,
# no SQLite; copiar en caliente da, en peor caso, un fichero al que
# le falta la última línea. Z2M lo trunca al arrancar y reconstruye
# desde MQTT discovery + estado del coordinador.
```

> **Política sobre `coordinator_backup.json`**. Borgmatic lo respalda con el resto. **Adicionalmente**, el día 1 (tras el primer arranque) se hace un backup *out-of-band*: copiar el fichero a un USB, a la nube personal cifrada, o pegarlo en una nota en el gestor de contraseñas. La razón es operacional: si Borg falla y nunca completa su primer ciclo, este fichero único basta para reconstruir.

> **Política sobre la network key**. La key real está en `configuration.yaml`. **No** debe pegarse en chats ni capturas. Si se compromete, el remedio es re-emparejar todos los dispositivos en una red nueva — coste alto. Tratarlo como una contraseña root.

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/zigbee2mqtt/docker-compose.yml up -d --force-recreate
# Z2M reusa /mnt/hd2t/apps/zigbee2mqtt/data: arranque normal en ~30s.
# Todos los devices, network_key, friendly_names siguen ahí.
# El coordinador conserva en su NVRAM el mismo PAN ID y se "resume" la red.
```

Procedimiento de restore tras pérdida total del coordinador (stick muerto, Pi viva):

```bash
# 1. Comprar SONOFF Zigbee 3.0 USB Dongle Plus IDÉNTICO (V1, mismo chip).
# 2. Enchufarlo. Verificar nuevo path:
ls /dev/serial/by-id/

# 3. PARAR Z2M.
docker compose -f /home/homelab/homelab/stacks/zigbee2mqtt/docker-compose.yml down

# 4. Restaurar la NVRAM del coordinador con el backup.
#    El paquete zigpy-cli (Python) o el script restore-coordinator-backup.py
#    (incluido en zigbee-herdsman) hacen la flash inversa. Pasos resumidos:
docker run --rm -it \
    --device "/dev/serial/by-id/usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_<NEW_SERIAL>-if00-port0:/dev/ttyACM0" \
    -v /mnt/hd2t/apps/zigbee2mqtt/data:/data \
    koenkk/zigbee2mqtt:1.41 \
    node /app/dist/util/restoreBackup.js \
        --backup /data/coordinator_backup.json \
        --port /dev/ttyACM0 \
        --adapter zstack

# 5. Actualizar el path en docker-compose.yml con el NEW_SERIAL.
sudo -e /home/homelab/homelab/stacks/zigbee2mqtt/docker-compose.yml

# 6. Levantar Z2M.
docker compose -f /home/homelab/homelab/stacks/zigbee2mqtt/docker-compose.yml up -d

# 7. Verificar que los devices siguen "online" en la UI tras 1-2 minutos.
#    No requiere re-pairing.
```

> **Si el coordinador nuevo no es idéntico** (p.ej. cambiar de V1/zstack a V2/ember): el `coordinator_backup.json` de zstack **no** es portable a ember. En ese caso, la única vía es re-emparejar todos los dispositivos. Por eso `SERVICES.md` fija una variante concreta y se queda con ella.

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear Fases 1 → 7, `01-home-assistant.md` y `02-mosquitto.md`.
2. `borgmatic extract --archive latest --path mnt/hd2t/apps/zigbee2mqtt`.
3. Verificar permisos: `sudo chown -R root:root /mnt/hd2t/apps/zigbee2mqtt && sudo chmod 0750 /mnt/hd2t/apps/zigbee2mqtt/data && sudo chmod 0600 /mnt/hd2t/apps/zigbee2mqtt/data/secret.yaml`.
4. Sustituir `<SERIAL>` en `docker-compose.yml` por el path del coordinador actual.
5. `docker compose -f stacks/zigbee2mqtt/docker-compose.yml up -d`.
6. Verificar que los devices reaparecen "online" en la UI.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| Z2M arranca y al cabo de 10s muere con `Error: Adapter is not responding` | (a) Path del device incorrecto en compose. (b) Otro proceso del host (modemmanager) tiene el `/dev/ttyACM0` ocupado. (c) Permisos. | Verificar `ls /dev/serial/by-id/`; `sudo apt purge -y modemmanager` (notorio por ocupar todos los TTY al inicio); `sudo systemctl mask modemmanager`. Reiniciar Z2M. |
| Logs: `Failed to connect to MQTT server` reintentando | (a) Mosquitto caído. (b) Password incorrecto. (c) ACL no permite el client_id. | `docker ps mosquitto`; `docker logs mosquitto` filtrando "auth"; verificar que `secret.yaml` tiene la password correcta y `configuration.yaml` referencia `!secret mqtt_password`. |
| Z2M conecta a MQTT pero los devices nuevos no aparecen en HA | (a) `homeassistant.enabled: false` en `configuration.yaml`. (b) ACL de Mosquitto bloquea publicación de discovery. (c) HA tiene MQTT Discovery desactivado. | Revisar los tres puntos. Tras cambiar ACL: `docker exec mosquitto kill -HUP 1`. Tras cambiar config de Z2M: restart container. |
| Permit join se desactiva solo a los 254s | Comportamiento normal y deseado (Zigbee 3.0 estándar de seguridad). | No es un bug. Si se necesita más tiempo, click "Permit join" otra vez. |
| Un device aparece como "unsupported" en la UI | El modelo no está en `zigbee-herdsman-converters`. | Buscar el modelo en https://www.zigbee2mqtt.io/supported-devices/. Si está pero la versión instalada de Z2M es vieja: actualizar Z2M (1.41 → 1.42). Si no está: añadir un `external_converter` (avanzado, fuera de alcance aquí). |
| Devices funcionan pero "Last seen" crece (~30+ min sin reportar) | (a) Interferencia 2.4 GHz (USB 3 cerca del stick). (b) Distancia > router Zigbee intermedio. (c) Pila baja. | Mover el stick con cable extensor a 30 cm de la Pi; añadir un router Zigbee (un enchufe a corriente actúa de repeater); revisar `sensor.<device>_battery`. |
| Tras `docker compose pull`, Z2M arranca pero `version mismatch in database` | El bump de minor (1.41 → 1.42) trajo migración de schema. | Z2M migra solo en arranque normalmente; si no, leer release notes y aplicar el procedimiento manual indicado. |
| UI carga pero "Connecting…" perpetuo | WebSocket roto en Caddy (Authelia mal configurada o `header_up Connection`/`Upgrade` manuales). | Revisar `08-zigbee2mqtt.caddy`: solo `lan_tls`, `lan_only`, `security_headers`, `healthcheck` y un `reverse_proxy` limpio. **Sin** `forward_auth`. |
| `https://z2m.lan` da 502 Bad Gateway | (a) Z2M caído. (b) Caddy no resuelve `zigbee2mqtt` por DNS. | `docker ps zigbee2mqtt`; `docker exec caddy getent hosts zigbee2mqtt` (debe devolver una IP `172.30.10.X`). Si no: ambos contenedores deben estar en la red `homelab`. |
| `permit_join: true` se queda *pegado* en `true` tras un restart | Bug histórico de Z2M < 1.30. En 1.41 está corregido. | Ignorar si la versión es ≥ 1.30. Si pasa: editar `configuration.yaml`, poner `permit_join: false`, restart. |
| Mesh map no se renderiza | Mesh map es **caro**: pinga toda la red. Bloquea Z2M durante ~30s. | Esperar; si tras 60s no aparece, ver logs (`docker logs zigbee2mqtt --tail 50`); puede haber un device colgado. Reintentar pasados 5 min. |
| Re-pairing de un device emparejado: error `device already in network` | Z2M tiene el device en `database.db`; el coordinador no, o viceversa (estados desincronizados). | UI → device → "Delete" con `force: true`. Después poner en pairing y re-emparejar. |
| El healthcheck del contenedor falla pero la UI carga bien | El test usa `wget` interno; en raras versiones el binario falta. | Sustituir el `test` por `["CMD-SHELL", "curl -fs http://127.0.0.1:8080/ || exit 1"]`. Z2M trae `curl` siempre. |
| Logs de HA: `mqtt: failed to publish: client disconnected` justo cuando Z2M arranca | Z2M reclama `client_id: zigbee2mqtt`; si HA lo había usado por error, el broker desconecta a uno. | Confirmar que ningún cliente comparte `client_id` con `zigbee2mqtt`. HA debería usar `home-assistant-<random>` por defecto. |

---

## Decisiones que **no** se toman en este documento

- **Authelia delante de la UI de Z2M**: ver decisión arriba; reabrible si en el futuro Z2M soporta SSO OIDC nativo.
- **Z-Wave, Matter, Thread**: pertenecen a fases / documentos específicos cuando se compre el coordinador correspondiente.
- **External converters** (módulos Node.js custom para devices no soportados): se añaden en `data/external_converters/*.js` cuando aparezca un dispositivo concreto que lo justifique. Cada uno **es código que se ejecuta dentro del contenedor**: auditar antes.
- **HACS frontend cards específicas para Z2M** (`z2m-device-card`, `mushroom-cards`): viven en HA, no aquí. Reabrible por el operador a gusto.
- **Mosquitto bridge a un broker remoto** para "puentear" la red Zigbee a otro lugar: esquema avanzado, fuera de alcance del homelab personal.
- **Cambio de `channel`** preventivo: solo si hay interferencia medible.
- **Cambio del `network_key`**: equivale a re-emparejar toda la red. Solo bajo sospecha de compromiso.
- **Frigate / detección de presencia con ESP32 BLE en HA via MQTT** y similares hibridaciones: pertenecen al subdominio del operador concreto, no al despliegue base.
- **Múltiples coordinadores Zigbee** (más alcance, segmentación): cada uno necesita su propia instancia de Z2M, puerto MQTT distinto y `base_topic` distinto. Reabrible si la casa supera ~150 dispositivos o tiene zonas físicamente desconectadas (jardín lejano).
- **Plugin `mqtt-explorer` o "MQTT Inspector"** dentro de Z2M: hay otros clientes mejores. El operador puede usar **MQTT Explorer** desde su laptop apuntando a `192.168.1.10:1883` (igual que se documenta en `02-mosquitto.md`).

---

## Verificación Final

Antes de pasar a `04-node-red.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/zigbee2mqtt/docker-compose.yml ps` | `zigbee2mqtt ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect zigbee2mqtt --format '{{.Config.Image}}'` | `koenkk/zigbee2mqtt:1.41` |
| Z2M en bridge `homelab` | `docker inspect zigbee2mqtt --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}'` | `homelab` |
| Coordinator USB visible dentro del container | `docker exec zigbee2mqtt ls -l /dev/ttyACM0` | `crw-rw---- 1 root dialout ...` |
| Coordinator firmware identificado | `docker logs zigbee2mqtt 2>&1 \| grep -i 'coordinator firmware'` | `Coordinator firmware version: 'Z-Stack 3.x.0'` |
| Conectado a MQTT | `mosquitto_sub -h 127.0.0.1 -p 1883 -u admin -P "$ADM_PWD" -t 'zigbee2mqtt/bridge/state' -C 1` | `{"state":"online"}` |
| `z2m.lan` resuelve | `dig +short z2m.lan @192.168.1.2` | `192.168.1.10` |
| Caddy sirve con cert de la CA interna | `echo \| openssl s_client -connect z2m.lan:443 -servername z2m.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| UI accesible y pide token | navegador con CA instalada → `https://z2m.lan/` | input "Authentication required" |
| WebSocket activo tras login | DevTools → Network → ws | conexión `z2m.lan/api` en estado `101 Switching Protocols` |
| HA muestra el bridge en MQTT integration | UI: `Settings → Devices & Services → MQTT` | "Zigbee2MQTT Bridge" listado |
| `permit_join` está OFF | UI Z2M / o `mosquitto_sub -t 'zigbee2mqtt/bridge/info' -C 1 \| jq .permit_join` | `false` |
| Network key persistida en disco | `sudo grep -E '^\s*network_key' /mnt/hd2t/apps/zigbee2mqtt/data/configuration.yaml` | línea con array de 16 enteros (no `GENERATE`) |
| `coordinator_backup.json` existe y no está vacío | `sudo ls -l /mnt/hd2t/apps/zigbee2mqtt/data/coordinator_backup.json` | tamaño > 1 KiB |
| Owner correcto del data | `sudo stat -c '%u:%g %a' /mnt/hd2t/apps/zigbee2mqtt/data` | `0:0 750` |
| `secret.yaml` con permisos restrictivos | `sudo stat -c '%a' /mnt/hd2t/apps/zigbee2mqtt/data/secret.yaml` | `600` |
| (Opcional smoke test) device emparejado y entidades en HA | Pairing del paso 3 + Developer Tools → States | `sensor.<friendly_name>_*` con valores reales |
| Watchtower etiqueta presente | `docker inspect zigbee2mqtt --format '{{index .Config.Labels "com.centurylinklabs.watchtower.enable"}}'` | `true` |

---

## Referencias

- Documentación oficial Zigbee2MQTT — https://www.zigbee2mqtt.io/
- Adapter / coordinator (Z-Stack 3) — https://www.zigbee2mqtt.io/guide/adapters/zstack.html
- Configuración (`configuration.yaml`) — https://www.zigbee2mqtt.io/guide/configuration/
- MQTT topics y mensajes — https://www.zigbee2mqtt.io/guide/usage/mqtt_topics_and_messages.html
- Frontend (auth_token) — https://www.zigbee2mqtt.io/guide/configuration/frontend.html
- Catálogo de dispositivos soportados — https://www.zigbee2mqtt.io/supported-devices/
- Backup / restore del coordinador — https://www.zigbee2mqtt.io/guide/installation/06_migrate.html#backup-restore
- Imagen Docker oficial — https://hub.docker.com/r/koenkk/zigbee2mqtt
- Releases y notas de versión — https://www.zigbee2mqtt.io/guide/installation/00_releases.html
- SONOFF Zigbee 3.0 USB Dongle Plus (V1, ZBDongle-P) — https://sonoff.tech/product/gateway-and-sensors/sonoff-zigbee-3-0-usb-dongle-plus/
- Home Assistant — MQTT integration — https://www.home-assistant.io/integrations/mqtt/
- Documentos hermanos: `01-home-assistant.md`, `02-mosquitto.md`, `04-node-red.md`.
- Documentos referenciados: `03-red/04-caddy.md`, `04-seguridad/01-authelia.md`, `07-backups/01-estrategia-backup.md`, `07-backups/02-borgmatic.md`.
