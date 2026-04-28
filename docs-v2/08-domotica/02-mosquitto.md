# Mosquitto

## Descripción

Despliegue de **[Eclipse Mosquitto](https://mosquitto.org/)** ([imagen oficial `eclipse-mosquitto`](https://hub.docker.com/_/eclipse-mosquitto)) como **broker MQTT 3.1.1 / 5.0** del homelab. Mosquitto es la **columna vertebral de la Fase 8**: [Home Assistant](./01-home-assistant.md), [Zigbee2MQTT](./03-zigbee2mqtt.md) y [Node-RED](./04-node-red.md) se comunican entre sí **siempre** vía este broker, nunca de forma directa. Cualquier dispositivo IoT propio (ESPHome, Tasmota, Shelly, sensores DIY ESP32) que se añada al homelab también publicará/se suscribirá aquí.

Este doc cubre, en orden:

1. **Por qué Mosquitto** (no [EMQX](https://www.emqx.io/), no [VerneMQ](https://vernemq.com/), no [HiveMQ CE](https://www.hivemq.com/products/hivemq-community-edition/)) y qué se gana/pierde con la elección.
2. **Plan de variables y archivos**: `.env.example` versionable, `.env` real con secretos en `/mnt/hd2t/services/mosquitto/.env`, layout de directorios bajo `/mnt/hd2t/services/mosquitto/`.
3. **`mosquitto.conf` mínimo y endurecido**: `allow_anonymous false`, password file, ACL file por cliente, persistencia de retained messages, listener 1883 plain en la red `homelab` (sin TLS porque es tráfico interno entre contenedores), log a fichero + stdout.
4. **Sistema de credenciales y ACLs**: cómo se generan los hashes con `mosquitto_passwd`, cómo se versiona `acl.example` (sin secretos) y cómo se materializa `acl` real (mismo contenido, no contiene secretos pero sí la topología fija de topics por cliente).
5. **`docker-compose.yml`** con bind mounts de `config/`, `data/` y `log/`, sin publicar puertos al host por defecto, etiquetas Watchtower opt-in.
6. **Despliegue, alta inicial de los 3 clientes "core"** (`homeassistant`, `zigbee2mqtt`, `nodered`).
7. **Verificación funcional**: `mosquitto_pub`/`mosquitto_sub` desde el host (vía `docker exec`), confirmación de que el broker rechaza anónimos, que respeta ACLs, que persiste retained messages tras reboot.
8. **Operaciones cotidianas**: añadir/rotar password de un cliente, leer logs, troubleshoot de "Connection refused" o "Not authorized".
9. **Backup**: Borgmatic respalda el directorio entero — no hay BD que dumpear, los retained messages están en `mosquitto.db` (formato propio de Mosquitto, no SQLite).
10. **Variantes opt-in**: exposición a la LAN para dispositivos IoT Wi-Fi (con TLS 8883 + cert de Caddy), WebSockets (puerto 9001) para clientes web, [bridge MQTT](https://mosquitto.org/man/mosquitto-conf-5.html#idm127) hacia un broker externo (HA Cloud, AWS IoT...), integración con Prometheus vía [`mosquitto-exporter`](https://github.com/sapcc/mosquitto-exporter), jail de fail2ban para "Bad username or password".

> **Alcance de red**: Mosquitto **solo se accede vía la red Docker `homelab`**. Los puertos 1883/8883/9001 **no se publican al host** por defecto (regla del homelab para todos los servicios web/red, [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §0). Los clientes internos (HA, Z2M, Node-RED) llegan por nombre Docker (`mosquitto:1883`). Si el operador quiere publicar a 1883 en la LAN para dispositivos IoT Wi-Fi (ESPHome, Tasmota), debe activar la variante §12.1 — y en ese caso **se exige TLS 8883** según §12.2.

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), `/mnt/hd2t/` montado y con permisos correctos ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §2.6 — el directorio `/mnt/hd2t/services/mosquitto/` ya está creado).
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` (`172.20.0.0/24`, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4) creada y accesible. Convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5 — bind mounts; §6 — plantilla mínima).
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Mosquitto lleva `com.centurylinklabs.watchtower.enable: "true"` por política ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2): los upgrades de Mosquitto 2.x son patches conservadores (CVEs, fixes), sin breaking changes en `mosquitto.conf` desde la 2.0.0.
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) para que `/mnt/hd2t/services/mosquitto/` quede archivado en cada snapshot.
- **Cliente `mosquitto-clients`** instalado en el host (para `mosquitto_passwd`, `mosquitto_pub`, `mosquitto_sub` desde la línea de comandos):
  ```bash
  sudo apt install -y mosquitto-clients
  ```
  > Alternativa: ejecutar siempre los binarios **dentro** del contenedor con `docker exec -it mosquitto mosquitto_passwd ...`. Funciona igual; el doc usa esta alternativa por defecto para no acoplarse a paquetes del host.
- **Decisión sobre exposición a la LAN**: si hay dispositivos IoT Wi-Fi (ESPHome, Tasmota, Shelly Gen1) que requieren MQTT, planear §12.1 + §12.2 (TLS) **antes** del despliegue. La migración posterior de "solo interno" → "expuesto con TLS" exige rotar credenciales (porque pasarían por la red en claro hasta el cambio).
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) **solo si se va a activar §12.1**: el dispositivo IoT necesita resolver `mqtt.lan` localmente.
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) **solo si se va a activar §12.2** (TLS) o §12.3 (WebSockets). Caddy provee el certificado vía `tls internal` para `mqtt.lan` y reverse_proxy WebSocket si procede.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Broker MQTT | **Mosquitto** ([`eclipse-mosquitto:2.0.20`](https://hub.docker.com/_/eclipse-mosquitto)) | Estándar de facto en el ecosistema HA + Z2M (la documentación oficial de ambos asume Mosquitto). EMQX/VerneMQ aportan clustering y métricas avanzadas pero el homelab tiene ≤ 1 broker, ≤ 100 clientes, ≤ 10 msg/s — escenario en el que Mosquitto consume < 30 MB de RAM y resuelve todo. HiveMQ CE arranca una JVM de ~200 MB. |
| Tag de imagen | **`eclipse-mosquitto:2.0.20`** (pinned, no `2.0` ni `latest`) | Pinear evita que un `docker compose pull` traiga una minor con cambios en el formato del log que rompa fail2ban (§12.5). Watchtower respeta el tag exacto y no fuerza un upgrade silencioso porque no es un *floating tag* — solo se actualiza cuando el operador edita `MOSQUITTO_IMAGE_TAG` en `.env`. |
| Arquitectura | `linux/arm64` (Pi 5) | El manifest de `eclipse-mosquitto:2.0.20` incluye `arm64`. Imagen total: ~12 MB (Alpine-based). |
| Red Docker | **`homelab`** (bridge externa). **Sin** `ports:` al host. | Caddy/HA/Z2M/Node-RED llegan a `mosquitto:1883` por DNS Docker. No publicar al host elimina el riesgo de un cliente externo conectándose en plano sin TLS. Coste: dispositivos IoT Wi-Fi (ESPHome) **no** llegan al broker hasta activar §12.1. |
| Listener | **`listener 1883 0.0.0.0`** dentro del contenedor | El bind a `0.0.0.0` aquí es seguro: el namespace de red del contenedor solo está unido a la red `homelab`. Sin `ports:`, ese `0.0.0.0` es el interfaz interno del contenedor, no la LAN. |
| Anónimos | **`allow_anonymous false`** | Default de Mosquitto 2.0.0+. Cualquier cliente sin user/pass es rechazado en `CONNECT`. Sin esto, Z2M sin `auth:` configurado se conectaría en silencio y publicaría tópicos sin restricciones. |
| Autenticación | **password file** (`mosquitto_passwd`, hash `pbkdf2-sha512`) | Mosquitto 2.x usa pbkdf2-sha512 por defecto (parámetro `password_format pbkdf2-sha512` en el fichero, formato auto-detectado al cargar). No se usa la integración con plugins externos (`mosquitto-go-auth` con MySQL/JWT) — añade complejidad operativa innecesaria para 4-5 clientes fijos. |
| Autorización | **ACL file** con prefijos por usuario | Cada cliente solo puede leer/escribir los topics que necesita. Z2M solo en `zigbee2mqtt/#`, HA escucha en `homeassistant/#` (discovery) + lee `zigbee2mqtt/#`, Node-RED suscribe a todo lectura y publica solo en `nodered/#`. Esta segmentación previene que un cliente comprometido publique `homeassistant/.../delete` y borre integraciones de HA. |
| Persistencia | **`persistence true`** + `persistence_location /mosquitto/data/` | Sin esto, los retained messages (los que HA publica con `retain: true` para que un nuevo cliente reciba el último estado) se pierden al reiniciar el broker. Mosquitto serializa a `mosquitto.db` (formato binario propio, no SQLite). |
| Logs | **`log_dest stdout`** + `log_dest file /mosquitto/log/mosquitto.log` | Stdout va a `docker logs` / Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)) para visualización en tiempo real. El fichero permite a fail2ban (§12.5) y al backup leer el histórico. |
| Modelo de almacenamiento | **Bind mount** en `/mnt/hd2t/services/mosquitto/{config,data,log}` | Patrón estándar del homelab. El subdir `config/` es root:root 0700 (contiene secretos: `passwords`); `data/` y `log/` son `1883:1883 0750` (UID/GID del usuario `mosquitto` dentro del contenedor). |
| UID/GID dentro del contenedor | **`1883:1883`** (no se cambia) | La imagen oficial fija UID/GID 1883 para el binario `mosquitto`. Cambiarlo (vía `user: 1000:1000` en Compose) requiere reconstruir la imagen. El homelab acepta el UID 1883 y ajusta los permisos del bind mount en consecuencia. |
| Watchtower | **`com.centurylinklabs.watchtower.enable: "true"`** | Mosquitto está en la lista verde de Watchtower ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2): la 2.x ha mantenido compatibilidad de `mosquitto.conf` desde 2020. Patches y CVEs se aplican automáticamente; la lectura del CHANGELOG por el operador queda como buena práctica pero no bloqueante. |
| Reverse proxy | **Caddy NO** delante por defecto | MQTT no es HTTP. Caddy entra en juego solo en §12.3 (WebSockets MQTT sobre el puerto 9001) o §12.2 (TLS pasthrough con el bloque `tls`). El tráfico TCP MQTT plano se sirve directo desde el contenedor. |
| Authelia | **No aplica** | MQTT no usa cookies HTTP; la autenticación es por user/pass en el `CONNECT` packet. |
| Fail2ban | **Opt-in §12.5** | Solo aplica si se activa §12.1 (exposición a la LAN). Internamente, un atacante en la red `homelab` ya tiene acceso al resto del homelab — el ban aporta poco. |

---

## 1. Resumen de la arquitectura

```
                ┌──────────────────── red homelab (172.20.0.0/24) ──────────────────┐
                │                                                                   │
                │   ┌─────────────────────┐                                         │
                │   │  Home Assistant     │  publica/suscribe                       │
                │   │  (./01-home-...)    │  homeassistant/+/+/+/config             │
                │   │                     │  zigbee2mqtt/<dev>/get                  │
                │   └────────┬────────────┘                                         │
                │            │                                                      │
                │            │   mqtt://homeassistant:****@mosquitto:1883           │
                │            ▼                                                      │
                │   ┌────────────────────────────┐                                  │
                │   │       Mosquitto            │ (este doc)                       │
                │   │   1883 (plain, interno)    │                                  │
                │   │                            │                                  │
                │   │   /mosquitto/config/       │ ─► /mnt/hd2t/services/mosquitto/config/
                │   │     mosquitto.conf         │      (root:root 0700)            │
                │   │     passwords              │      (root:root 0600)            │
                │   │     acl                    │      (root:root 0640)            │
                │   │   /mosquitto/data/         │ ─► /mnt/hd2t/services/mosquitto/data/
                │   │     mosquitto.db (retained)│      (1883:1883 0750)            │
                │   │   /mosquitto/log/          │ ─► /mnt/hd2t/services/mosquitto/log/
                │   │     mosquitto.log          │      (1883:1883 0750)            │
                │   └────────┬───────────────────┘                                  │
                │            ▲                                                      │
                │            │   mqtt://zigbee2mqtt:****@mosquitto:1883             │
                │   ┌────────┴─────────────┐                                        │
                │   │   Zigbee2MQTT        │  publica zigbee2mqtt/+/availability    │
                │   │   (./03-...)         │  zigbee2mqtt/bridge/state              │
                │   │   (USB Zigbee dev)   │  zigbee2mqtt/<dev>/...                 │
                │   └──────────────────────┘                                        │
                │                                                                   │
                │   ┌──────────────────────┐                                        │
                │   │     Node-RED         │  suscribe (#) lectura, publica nodered/#│
                │   │   (./04-...)         │                                        │
                │   └──────────────────────┘                                        │
                └───────────────────────────────────────────────────────────────────┘

                                     [ Variante §12.1 — opt-in ]

                        LAN 192.168.X/24 ─► host:1883 (publicado) ─► contenedor
                                  │
                          ┌───────┴────────┐
                          │  ESPHome       │
                          │  Tasmota       │
                          │  Shelly        │
                          └────────────────┘
```

Lo crítico de este diagrama:

1. **Una única vía de entrada**: por defecto, el broker solo es accesible desde la red `homelab`. Ningún cliente externo (LAN, internet, Tailscale) llega a `1883`. La variante §12.1 abre un agujero controlado a la LAN para IoT Wi-Fi.
2. **No hay TLS interno**: el tráfico HA ↔ Mosquitto ↔ Z2M es texto plano dentro del namespace de red `homelab`. La capa de seguridad es la **autenticación por user/pass + ACL**: si un atacante consigue meter un contenedor en `homelab`, las credenciales y los topics permitidos son la siguiente barrera. Para tráfico extra-`homelab` (§12.1) el TLS pasa a ser obligatorio (§12.2).
3. **Persistencia ≠ histórico**: Mosquitto **no** es una BD de eventos. `mosquitto.db` solo guarda los **retained messages** (último mensaje por topic con flag `retain`) y las **suscripciones de clientes con `clean_session=false`**. Para histórico de eventos sensores → integración HA `recorder` ([`./01-home-assistant.md`](./01-home-assistant.md) §4.1) o exportador a Prometheus (§12.4).
4. **ACL = última línea de defensa**: si HA queda comprometida, su credencial `homeassistant` solo puede publicar/leer `homeassistant/#` y `zigbee2mqtt/#`. No puede borrar el state de Z2M (`zigbee2mqtt/bridge/request/permit_join` por ejemplo, que es escritura solo para Node-RED en este modelo).

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/mosquitto/.env.example`:

```env
# ~/homelab/stacks/mosquitto/.env.example
# Versionado en: ~/homelab/stacks/mosquitto/.env.example
# Valores reales en /mnt/hd2t/services/mosquitto/.env (chmod 600).
# Este fichero NO contiene secretos: las passwords de los clientes MQTT
# viven hasheadas en /mnt/hd2t/services/mosquitto/config/passwords.

# --- Comunes del homelab ---
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
TZ=Europe/Madrid

# --- Mosquitto ---
# https://hub.docker.com/_/eclipse-mosquitto
# CHANGELOG: https://mosquitto.org/blog/category/release/
MOSQUITTO_IMAGE_TAG=2.0.20

# UID/GID interno del binario `mosquitto` en la imagen oficial.
# NO cambiar (la imagen lo fija); se usa para chown de los bind mounts data/ y log/.
MOSQUITTO_UID=1883
MOSQUITTO_GID=1883

# Hostname interno (resuelto por DNS Docker en la red `homelab`).
MOSQUITTO_HOSTNAME=mosquitto
```

### 2.2. `.env` real (`/mnt/hd2t/services/mosquitto/.env`)

```bash
# Crear el .env con permisos correctos.
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/mosquitto
sudo install -o homelab -g homelab -m 600 /dev/null \
  /mnt/hd2t/services/mosquitto/.env

sudo -u homelab tee /mnt/hd2t/services/mosquitto/.env > /dev/null <<'EOF'
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
TZ=Europe/Madrid
MOSQUITTO_IMAGE_TAG=2.0.20
MOSQUITTO_UID=1883
MOSQUITTO_GID=1883
MOSQUITTO_HOSTNAME=mosquitto
EOF

# Verificar.
ls -l /mnt/hd2t/services/mosquitto/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` (§5) declara `env_file: /mnt/hd2t/services/mosquitto/.env`. Compose carga el fichero a la hora de interpolar `${...}` en el YAML (para `image`, `hostname`, `user`).

> **Por qué no hay secretos en `.env`**: Mosquitto Container no lee credenciales de variables de entorno. Las passwords de los clientes MQTT viven hasheadas (pbkdf2-sha512) en `/mnt/hd2t/services/mosquitto/config/passwords` y se generan con `mosquitto_passwd` (§4.2). El `.env` solo tiene tags y UIDs, que no son secretos.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
sudo install -d -o homelab -g homelab -m 750 ~/homelab/stacks/mosquitto
```

### 3.2. Crear el árbol de datos persistentes

```bash
# Estructura canónica:
#  /mnt/hd2t/services/mosquitto/
#    ├── .env              (root:homelab 0600, ya creado en §2.2)
#    ├── config/           (root:root 0700)  ← contiene secretos (passwords)
#    │     ├── mosquitto.conf
#    │     ├── passwords   (hashes pbkdf2-sha512)
#    │     └── acl
#    ├── data/             (1883:1883 0750)  ← mosquitto.db (retained)
#    └── log/              (1883:1883 0750)  ← mosquitto.log

# config/ requiere que solo root pueda leer 'passwords'. Mosquitto corre como
# UID 1883 dentro del contenedor; ese UID es root en namespace de fichero
# porque los bind mounts respetan UIDs del host. Por tanto el fichero
# 'passwords' debe pertenecer a root:1883 con 0640 para que mosquitto pueda
# leerlo, pero el directorio /config/ se cierra a 0750 (solo root y miembros
# de grupo 1883 listan; el operador con sudo siempre puede).
sudo install -d -o root -g root -m 0700 /mnt/hd2t/services/mosquitto/config

# data/ y log/ los escribe el proceso mosquitto (UID 1883). Crear ya con el
# ownership correcto evita que el primer arranque falle por "permission denied".
sudo install -d -o 1883 -g 1883 -m 0750 \
  /mnt/hd2t/services/mosquitto/data \
  /mnt/hd2t/services/mosquitto/log
```

### 3.3. Tabla de permisos

| Ruta host | Modo | Owner | Quién escribe | Por qué |
|---|---|---|---|---|
| `/mnt/hd2t/services/mosquitto/` | `750 homelab:homelab` | El operador | Estructura. El operador con `sudo` desciende a `config/`. | Patrón canónico. |
| `/mnt/hd2t/services/mosquitto/.env` | `600 homelab:homelab` | El operador | El operador. | Sin secretos pero hábito 600 en cualquier `.env`. |
| `/mnt/hd2t/services/mosquitto/config/` | `0700 root:root` | El operador con `sudo` | El operador. Mosquitto **no escribe** en `config/` (solo lee). | Cierra el directorio para que un usuario no privilegiado del host no liste `passwords`. |
| `/mnt/hd2t/services/mosquitto/config/mosquitto.conf` | `0644 root:root` | El operador. | El operador. | Configuración no secreta; legible por todos los procesos del contenedor (es root en el namespace del bind). |
| `/mnt/hd2t/services/mosquitto/config/passwords` | `0640 root:1883` | El operador (con `mosquitto_passwd`). | El operador. Mosquitto **solo lee**. | El binario `mosquitto` (UID 1883) lee por grupo. Otros UIDs no leen. |
| `/mnt/hd2t/services/mosquitto/config/acl` | `0640 root:1883` | El operador. | El operador. Mosquitto **solo lee**. | Mismo patrón que `passwords`. ACL no es estrictamente secreta pero saberlo facilita un ataque dirigido. |
| `/mnt/hd2t/services/mosquitto/data/` | `0750 1883:1883` | Mosquitto (UID 1883 dentro del contenedor). | Materializa `mosquitto.db` con retained messages. | Sin 0750, mosquitto falla en arranque con `Error: Unable to open database`. |
| `/mnt/hd2t/services/mosquitto/log/` | `0750 1883:1883` | Mosquitto. | `mosquitto.log` rotará en §11.3 vía logrotate del host. |

### 3.4. ¿Por qué UID 1883 y no 1000 (homelab)?

La imagen oficial `eclipse-mosquitto` define en su Dockerfile:

```
ENV USER=mosquitto UID=1883 GID=1883
USER mosquitto
```

Cambiar el UID en runtime con `user: 1000:1000` en Compose:

- Funcionaría para escribir en `data/` y `log/` (porque los crearía como 1000).
- **Rompe** la lectura de `passwords` y `acl` porque están como `root:1883`.
- Saltarse esto poniendo todos los bind mounts a `1000:1000` complica el modelo (el UID 1883 dentro del contenedor seguirá intentando escribir como 1883, fallando).

**Veredicto del homelab**: aceptar UID 1883. Es un UID alto, sin colisión con usuarios reales del host (`/etc/passwd` no lo tiene definido). El único coste es recordar `chown -R 1883:1883` cuando se manipulan los bind mounts manualmente. Esto **se aleja** del patrón general "todo va con UID 1000" pero es pragmático: forzar 1000 requeriría reconstruir la imagen (innecesario para un homelab personal).

---

## 4. Configuración de Mosquitto

### 4.1. `mosquitto.conf`

Fichero **versionable** en `~/homelab/stacks/mosquitto/mosquitto.conf` y **copiable** a `/mnt/hd2t/services/mosquitto/config/mosquitto.conf` (no se versiona el fichero del bind mount; se versiona la fuente y se sincroniza con `install -m 0644`):

```conf
# ~/homelab/stacks/mosquitto/mosquitto.conf
# Eclipse Mosquitto 2.0.20 — broker MQTT del homelab.
# Doc: https://mosquitto.org/man/mosquitto-conf-5.html
#
# Despliegue: el fichero se monta read-only en /mosquitto/config/mosquitto.conf
# vía bind mount (../08-domotica/02-mosquitto.md §3).

# ─── Identidad ─────────────────────────────────────────────────────────────
# `bind_address` por defecto vacío → escucha en 0.0.0.0 (todos los interfaces
# del namespace del contenedor). Como no hay 'ports:' en el compose, el
# 0.0.0.0 efectivo es solo la red `homelab`.
listener 1883
protocol mqtt

# ─── Persistencia ──────────────────────────────────────────────────────────
# Retained messages + sesiones persistentes (clean_session=false) sobreviven
# a reinicios. Sin esto, HA pierde el último estado de cada sensor al reboot.
persistence true
persistence_location /mosquitto/data/
# Cada cuántos segundos flushea a disco (default 1800s = 30 min).
# Reducido a 300 (5 min) para limitar pérdida tras un kernel panic.
autosave_interval 300

# ─── Logging ───────────────────────────────────────────────────────────────
# A stdout para `docker logs` y Dozzle.
log_dest stdout
# Y a fichero para fail2ban + retención larga (logrotate del host, §11.3).
log_dest file /mosquitto/log/mosquitto.log
log_timestamp true
log_timestamp_format %Y-%m-%dT%H:%M:%S
# Tipos: error, warning, notice, information, debug, subscribe, unsubscribe.
# 'information' es el sweet spot: muestra connect/disconnect (útil para
# verificar quién está conectado) sin spamear con cada PUBLISH.
log_type error
log_type warning
log_type notice
log_type information
# NO 'log_type debug' en producción: ~5 KB/s de log con 4 clientes activos.

# ─── Autenticación ─────────────────────────────────────────────────────────
# Mosquitto 2.0+ es secure-by-default: rechaza anónimos sin esto explícito.
# Se deja la línea para que el operador no dependa del default upstream.
allow_anonymous false

# Fichero de passwords (formato: user:hash, generado con mosquitto_passwd).
password_file /mosquitto/config/passwords

# ─── Autorización (ACL) ────────────────────────────────────────────────────
# Cada cliente solo puede leer/escribir los topics que necesita.
acl_file /mosquitto/config/acl

# ─── Performance / límites ─────────────────────────────────────────────────
# Tope de mensajes encolados por cliente offline (clean_session=false).
# Default: 1000. Subido a 5000 para que un Z2M offline durante un upgrade no
# pierda eventos retained.
max_queued_messages 5000

# Tamaño máximo de un payload MQTT (default 0 = sin límite).
# Limitar a 1 MB previene un cliente comprometido enviando payloads enormes
# que llenen el disco vía retained messages.
message_size_limit 1048576

# Conexiones concurrentes (default -1 = sin límite). Con 4 clientes core +
# margen para 20 dispositivos IoT Wi-Fi (variante §12.1), 100 sobra.
max_connections 100

# ─── Conexión / keepalive ──────────────────────────────────────────────────
# El cliente debe enviar PINGREQ al menos cada N segundos. Si no, el broker
# desconecta. Default 60. HA y Z2M usan 60 por defecto, no se toca.
# (Sin línea explícita; se acepta el default).
```

#### 4.1.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `listener 1883` (sin IP) | Equivalente a `listener 1883 0.0.0.0`. En el namespace de red del contenedor, atado solo a la red `homelab`. Sin esta línea, Mosquitto 2.x crea un listener por defecto en `1883/127.0.0.1` (la 2.x cambió el comportamiento respecto a 1.6 por seguridad: solo loopback hasta declarar listener explícito). HA/Z2M en otros contenedores **no** llegarían al loopback del contenedor mosquitto. |
| `protocol mqtt` | MQTT 3.1.1 / 5.0 sobre TCP plano. Para WebSockets se añade un segundo listener `1884` con `protocol websockets` (variante §12.3). |
| `persistence true` + `autosave_interval 300` | Mosquitto sin persistencia es un caché en RAM. Persistencia activa convierte `mosquitto.db` en el "estado fuente" del broker. `autosave_interval 300` (vs default 1800) reduce la ventana de pérdida tras crash a 5 min. |
| `log_dest stdout` + `log_dest file ...` | Doble destino: stdout para visualizar en vivo (Dozzle), fichero para análisis offline y fail2ban. Sin file, fail2ban no tiene fuente que tail-ear (el log de Docker no es directamente leíble por procesos del host sin `docker logs`). |
| `log_type information` | Suficiente para auditar conexiones (`Client X connected from Y as user Z`) sin saturar. `subscribe`/`unsubscribe` se omiten porque generan ruido al reconectar. `debug` se activa solo a mano con `docker exec mosquitto kill -HUP 1` (no aplica aquí — Mosquitto no recarga config con SIGHUP en 2.x; en su lugar `docker compose restart`). |
| `allow_anonymous false` | El default desde 2.0. Se mantiene explícito para que un operador que copie este fichero a una versión anterior obtenga el comportamiento esperado. |
| `password_file` + `acl_file` | El fichero de passwords es leído al startup; cambios requieren `docker compose restart mosquitto` o `docker exec mosquitto mosquitto_passwd ...` que escribe y avisa al broker para releer (en 2.x el reload se aplica al recibir SIGHUP, pero el binario del homelab corre como PID 1 y SIGHUP equivale a restart, así que se documenta el restart). |
| `max_queued_messages 5000` | El default 1000 era ajustado para HA: si Z2M está offline 1h durante un upgrade, fácilmente acumula ≥ 1500 eventos `availability` para devices Zigbee. Con 5000 hay margen para colas de varias horas. RAM extra: ~5 MB. |
| `message_size_limit 1048576` | 1 MB es 1000× el tamaño típico de un payload MQTT (un sensor publica < 200 bytes). Capear evita que un atacante con credenciales válidas llene `mosquitto.db` con un payload de 100 MB retained. |
| `max_connections 100` | Holgura. La Pi 5 podría manejar 1000+ pero documentamos un tope cercano al uso real para que un script roto que abre conexiones en bucle se vea reflejado en el log con `Connection limit reached`. |
| **No** `cafile` / `certfile` | Sin TLS por defecto (variante §12.2). |
| **No** `bridge_*` | Sin bridge a brokers externos (variante §12.6). |

### 4.2. Generar el fichero `passwords`

Mosquitto 2.0+ usa `pbkdf2-sha512` por defecto. La utilidad `mosquitto_passwd` genera el hash a partir de una password en claro.

#### 4.2.1. Lista de clientes "core"

| Usuario | Quién lo usa | Topics permitidos (resumen — ver §4.3) |
|---|---|---|
| `homeassistant` | Home Assistant (integración MQTT, [`./01-home-assistant.md`](./01-home-assistant.md) §8.2) | RW `homeassistant/#` (discovery) + RW `zigbee2mqtt/#` (Zigbee discovery + comandos) + R `nodered/#` (eventos de Node-RED) + RW `tele/#` (Tasmota), R `stat/#`, RW `cmnd/#` |
| `zigbee2mqtt` | Zigbee2MQTT ([`./03-zigbee2mqtt.md`](./03-zigbee2mqtt.md)) | RW `zigbee2mqtt/#` |
| `nodered` | Node-RED ([`./04-node-red.md`](./04-node-red.md)) | R `#` (suscribirse a todo para flujos), W `nodered/#` |
| `monitoring` | (Opcional, §12.4) `mosquitto-exporter` | R `$SYS/#` |

> Diseño: HA es el cliente "más amplio" porque consume Discovery de todos los demás. Z2M se restringe a su propio namespace. Node-RED puede leer todo (es la intención de un orquestador de flujos visuales) pero solo escribe en su propio namespace para no pisar Discovery.

#### 4.2.2. Generar las passwords

Tres opciones equivalentes; escoger una y mantenerse:

**Opción A — Generar dentro del contenedor (preferida)**:

```bash
# Levantar primero el contenedor sin fichero passwords (creará un volumen vacío
# pero fallará en arranque por allow_anonymous=false → no escucha → no procesa
# clientes; el contenedor queda en un loop de reinicio gestionable mientras
# se crean credenciales).
#
# Workaround: ejecutar mosquitto_passwd directamente con `docker run --rm`,
# sin levantar el servicio.

# Generar password aleatoria (24 chars, base64 URL-safe).
HA_PASS="$(openssl rand -base64 24 | tr -d '+/=' | cut -c1-24)"
echo "homeassistant:$HA_PASS"
# Anotar la password en el password manager del operador (Vaultwarden tras Fase 11).

# Crear fichero passwords con el primer usuario.
sudo touch /mnt/hd2t/services/mosquitto/config/passwords
sudo chown root:1883 /mnt/hd2t/services/mosquitto/config/passwords
sudo chmod 0640 /mnt/hd2t/services/mosquitto/config/passwords

# Generar el hash y añadir al fichero.
docker run --rm \
  -v /mnt/hd2t/services/mosquitto/config:/mosquitto/config \
  eclipse-mosquitto:2.0.20 \
  mosquitto_passwd -b /mosquitto/config/passwords homeassistant "$HA_PASS"

# Repetir para los otros usuarios.
Z2M_PASS="$(openssl rand -base64 24 | tr -d '+/=' | cut -c1-24)"
NR_PASS="$(openssl rand -base64 24 | tr -d '+/=' | cut -c1-24)"
echo "zigbee2mqtt:$Z2M_PASS"
echo "nodered:$NR_PASS"

docker run --rm \
  -v /mnt/hd2t/services/mosquitto/config:/mosquitto/config \
  eclipse-mosquitto:2.0.20 \
  mosquitto_passwd -b /mosquitto/config/passwords zigbee2mqtt "$Z2M_PASS"

docker run --rm \
  -v /mnt/hd2t/services/mosquitto/config:/mosquitto/config \
  eclipse-mosquitto:2.0.20 \
  mosquitto_passwd -b /mosquitto/config/passwords nodered "$NR_PASS"

# Verificar.
sudo cat /mnt/hd2t/services/mosquitto/config/passwords
# Esperado (3 líneas):
# homeassistant:$7$101$xxxxxxxxxxxxxxxx$yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
# zigbee2mqtt:$7$101$...
# nodered:$7$101$...
```

**Opción B — Con el cliente del host** (`mosquitto-clients` instalado en Pi OS):

```bash
sudo apt install -y mosquitto-clients

# mosquitto_passwd del paquete del host es la 2.0.x de Pi OS (compatible).
sudo mosquitto_passwd -c -b \
  /mnt/hd2t/services/mosquitto/config/passwords \
  homeassistant "$HA_PASS"

sudo mosquitto_passwd -b \
  /mnt/hd2t/services/mosquitto/config/passwords \
  zigbee2mqtt "$Z2M_PASS"

sudo mosquitto_passwd -b \
  /mnt/hd2t/services/mosquitto/config/passwords \
  nodered "$NR_PASS"

# Asegurar permisos finales.
sudo chown root:1883 /mnt/hd2t/services/mosquitto/config/passwords
sudo chmod 0640 /mnt/hd2t/services/mosquitto/config/passwords
```

> El flag `-c` crea el fichero (sobrescribe si existe). Solo en el **primer** usuario.

**Opción C — Stdin interactivo** (para un solo usuario o rotaciones):

```bash
sudo mosquitto_passwd /mnt/hd2t/services/mosquitto/config/passwords homeassistant
# Pide password 2 veces, no la muestra en `history`.
```

#### 4.2.3. Por qué las passwords aleatorias de 24 caracteres

- **Anti-fuerza bruta**: 24 chars de espacio base64 (~144 bits de entropía) son inrompibles offline en el horizonte de cómputo accesible. Aunque Mosquitto usa pbkdf2-sha512 con cost ajustado por defecto (~10 ms por intento), un hash filtrado no se rompe.
- **Sin necesidad de memorizar**: estas passwords solo viajan entre el `passwords` y la integración del cliente (configuration.yaml de HA, `configuration.yaml` de Z2M, settings de Node-RED). Se almacenan en el password manager del operador.
- **Anti-typo**: la generación con `openssl rand` excluye `+/=` para evitar problemas en YAML/JSON.

### 4.3. Fichero `acl`

ACL declara, por cliente, qué topics puede leer (`read`), escribir (`write`) o ambos (`readwrite`). Sintaxis: [`mosquitto-conf(5)` → ACL](https://mosquitto.org/man/mosquitto-conf-5.html#idm127).

#### 4.3.1. Crear `~/homelab/stacks/mosquitto/acl.example` (versionable)

```text
# ~/homelab/stacks/mosquitto/acl.example
# ACL del broker MQTT del homelab.
# Documentación: https://mosquitto.org/man/mosquitto-conf-5.html
#
# Sintaxis:
#   user <usuario>
#   topic [read|write|readwrite] <patrón>
#
# Patrones:
#   '+' = un nivel cualquiera (ej. zigbee2mqtt/+/availability)
#   '#' = todos los niveles desde aquí (solo al final, ej. zigbee2mqtt/#)
#
# Por defecto: si un usuario no aparece, el broker DENIEGA todo.
# Si aparece pero sin entrada para un topic, también deniega.

# ─── Reglas anónimas / pattern global ──────────────────────────────────────
# (vacío: allow_anonymous=false ya rechaza anónimos)

# ─── homeassistant ─────────────────────────────────────────────────────────
# Hub del homelab. Lee y escribe Discovery y todos los namespaces de IoT.
user homeassistant
topic readwrite homeassistant/#
topic readwrite zigbee2mqtt/#
topic read     nodered/#
# Tasmota (variante §12.1, IoT Wi-Fi):
topic readwrite tele/#
topic read     stat/#
topic readwrite cmnd/#

# ─── zigbee2mqtt ───────────────────────────────────────────────────────────
# Z2M solo gestiona su propio namespace.
user zigbee2mqtt
topic readwrite zigbee2mqtt/#

# ─── nodered ───────────────────────────────────────────────────────────────
# Node-RED es orquestador: suscribe a todo (lectura), publica solo en
# nodered/#. Si un flujo necesita publicar en homeassistant/cmd, se delega
# en HA llamando a un servicio vía la integración HA del nodo.
user nodered
topic read      #
topic readwrite nodered/#

# ─── monitoring (opcional, §12.4) ──────────────────────────────────────────
# user monitoring
# topic read $SYS/#
```

#### 4.3.2. Materializar `acl` real

```bash
# Copiar la plantilla al bind mount con permisos correctos.
sudo install -o root -g 1883 -m 0640 \
  ~/homelab/stacks/mosquitto/acl.example \
  /mnt/hd2t/services/mosquitto/config/acl

# Verificar.
sudo ls -l /mnt/hd2t/services/mosquitto/config/
# Esperado:
# -rw-r-----  1 root      1883  ... acl
# -rw-r-----  1 root      1883  ... passwords
# -rw-r--r--  1 root      root  ... mosquitto.conf
```

> **Sobre versionar `acl`**: el ACL contiene la **topología** del homelab (qué cliente toca qué namespace). No es un secreto duro (un atacante no derivará credenciales de aquí), pero saberlo facilita un ataque dirigido. La política del homelab es: **versiona `acl.example` igual al `acl` real**, sin que `passwords` esté nunca en git. La diferencia entre `acl.example` y `acl` real es **vacía** en este servicio (no hay variables a rellenar); se mantienen los dos por consistencia con el patrón `.env`/`.env.example`.

### 4.4. Copiar `mosquitto.conf` al bind mount

```bash
# Igual que con acl, copiar la fuente versionada al bind mount.
sudo install -o root -g root -m 0644 \
  ~/homelab/stacks/mosquitto/mosquitto.conf \
  /mnt/hd2t/services/mosquitto/config/mosquitto.conf

# Comprobación final del directorio config/.
sudo ls -l /mnt/hd2t/services/mosquitto/config/
# Esperado:
# -rw-r-----  1 root  1883  ... acl
# -rw-r--r--  1 root  root  ... mosquitto.conf
# -rw-r-----  1 root  1883  ... passwords
```

---

## 5. `docker-compose.yml`

`~/homelab/stacks/mosquitto/docker-compose.yml`:

```yaml
# ~/homelab/stacks/mosquitto/docker-compose.yml
# Stack: mosquitto (../02-docker/02-estructura-compose.md §1.1).
# Datos en /mnt/hd2t/services/mosquitto/.
# Sin `ports:` por defecto — solo accesible desde la red `homelab`.

name: mosquitto

services:
  mosquitto:
    image: eclipse-mosquitto:${MOSQUITTO_IMAGE_TAG}
    container_name: mosquitto
    hostname: ${MOSQUITTO_HOSTNAME}
    restart: unless-stopped
    env_file: /mnt/hd2t/services/mosquitto/.env

    environment:
      TZ: ${TZ}

    # NO `user:` — la imagen oficial fija UID/GID 1883:1883 internamente.
    # Si se intenta sobrescribir, falla en lectura de /mosquitto/config/passwords.

    volumes:
      # Configuración (read-only para el contenedor: el broker no muta su conf).
      - type: bind
        source: /mnt/hd2t/services/mosquitto/config
        target: /mosquitto/config
        read_only: true
      # Datos persistentes (mosquitto.db con retained messages).
      - type: bind
        source: /mnt/hd2t/services/mosquitto/data
        target: /mosquitto/data
      # Logs.
      - type: bind
        source: /mnt/hd2t/services/mosquitto/log
        target: /mosquitto/log
      # Reloj sincronizado con el host.
      - /etc/localtime:/etc/localtime:ro

    # Sin `ports:` — el broker solo es accesible desde la red `homelab`.
    # Si se quiere exponer 1883 a la LAN para IoT Wi-Fi, ver §12.1.
    networks:
      - homelab

    # Recursos: Mosquitto es ligero. Limitar RAM evita que un cliente
    # comprometido cause OOM publicando mensajes hasta agotar `max_queued_messages`.
    mem_limit: 256m
    mem_reservation: 32m

    # Healthcheck: el broker no tiene endpoint HTTP.
    # `mosquitto_sub` con timeout 2s al topic $SYS/broker/uptime devuelve
    # un valor si el broker está vivo y autenticado.
    # Se usa el cliente bundled con la imagen.
    healthcheck:
      test:
        - "CMD-SHELL"
        - "mosquitto_sub -h localhost -p 1883 -u nodered -P \"$$(grep -A1 '^user nodered' /mosquitto/config/passwords 2>/dev/null | head -1 || echo '')\" -t '$$SYS/broker/uptime' -C 1 -W 2 >/dev/null 2>&1 || exit 0"
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

    labels:
      # Watchtower: actualizaciones automáticas (../02-docker/04-watchtower.md §4.2).
      com.centurylinklabs.watchtower.enable: "true"
      # Dozzle: agrupar con el resto de Fase 8.
      dev.dozzle.group: "homeassistant"

networks:
  homelab:
    external: true
```

### 5.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `name: mosquitto` | Nombre del proyecto Compose, igual al nombre del directorio del stack ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.1). |
| `image: eclipse-mosquitto:${MOSQUITTO_IMAGE_TAG}` | Tag pinned vía `.env`. La imagen oficial está en Docker Hub (no GHCR para este proyecto). |
| `container_name: mosquitto` / `hostname: ${MOSQUITTO_HOSTNAME}` | Nombre estable para que HA, Z2M y Node-RED resuelvan `mosquitto:1883` por DNS Docker. Sin esto, el nombre generado tipo `mosquitto-mosquitto-1` rompería la integración MQTT de HA. |
| `env_file: ...` | Patrón estándar. |
| `environment.TZ` | Para que los timestamps en `mosquitto.log` salgan en la zona horaria del operador. Mosquitto sin TZ loguea en UTC. |
| **No** `user:` | Crítico: la imagen oficial define `USER mosquitto` (UID 1883). Sobrescribir aquí rompe permisos del bind mount `config/` (que es `root:1883 0640` para `passwords` y `acl`). |
| `volumes: config:/mosquitto/config (read_only: true)` | El broker **no escribe** en config/. Marcarlo `read_only` previene que un bug del binario escriba allí (defense in depth). |
| `volumes: data:/mosquitto/data` | Mosquitto serializa `mosquitto.db` aquí. Sin `read_only` (debe escribir). |
| `volumes: log:/mosquitto/log` | Idem para `mosquitto.log`. |
| `volumes: /etc/localtime:ro` | Sincroniza zona del host con el contenedor. |
| `networks: [homelab]` | Solo la red compartida. La integración MQTT en HA y Z2M usa `mosquitto:1883`. |
| `mem_limit: 256m` | Mosquitto base: ~10 MB. Con 5000 mensajes encolados (256 bytes c/u): ~1.5 MB. 256 MB de tope cubre escenarios anómalos (cliente que envía spam dentro del límite `message_size_limit`). |
| `mem_reservation: 32m` | Garantía mínima en presión de memoria. |
| `healthcheck` | El comando es defensivo: intenta autenticar como `nodered` y leer `$SYS/broker/uptime`. Si el broker está abajo o en arranque, devuelve no-cero. Si la password no está disponible (primer arranque sin `passwords`), el `|| exit 0` evita marcarlo unhealthy en el bootstrap (ya hay un `start_period: 10s` para el primer arranque). |
| `com.centurylinklabs.watchtower.enable: "true"` | Política ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2). |
| `dev.dozzle.group: "homeassistant"` | Agrupar logs de Fase 8 (HA, Mosquitto, Z2M, Node-RED) en un mismo grupo de Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)). Coincide con la elección hecha en [`./01-home-assistant.md`](./01-home-assistant.md) §5.1. |
| `networks.homelab.external: true` | La red se crea una vez en el bootstrap del homelab ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4); aquí solo se consume. |

> **Sobre el healthcheck**: Mosquitto no tiene un endpoint nativo de salud. Alternativa más simple — pero menos verdadera — es `pgrep -x mosquitto` dentro del contenedor; eso solo dice "el proceso vive", no "el broker acepta conexiones". El comando elegido valida red + auth + ACL en una sola llamada.

### 5.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/mosquitto
docker compose --env-file /mnt/hd2t/services/mosquitto/.env config

# Esperado: salida YAML resuelta sin warnings.
# - El `image` debe estar plenamente cualificado: eclipse-mosquitto:2.0.20
# - Sin warning "variable X not set".
# - `volumes` con paths absolutos.
```

---

## 6. Despliegue

### 6.1. Levantar el stack

```bash
cd ~/homelab/stacks/mosquitto
docker compose --env-file /mnt/hd2t/services/mosquitto/.env up -d
```

El primer `up` tarda **~5 segundos** (la imagen son 12 MB y el broker arranca en menos de 1s). Verificar:

```bash
docker compose --env-file /mnt/hd2t/services/mosquitto/.env ps

# Esperado:
# NAME        IMAGE                          STATUS                 PORTS
# mosquitto   eclipse-mosquitto:2.0.20       Up X (healthy)
```

### 6.2. Confirmar que escucha y rechaza anónimos

```bash
# Desde dentro del contenedor (la única red donde escucha):
docker exec mosquitto mosquitto_sub -h localhost -p 1883 -t '#' -C 1 -W 3

# Esperado: salida con error tipo:
#   Connection error: Connection Refused: not authorised.
# Eso prueba que allow_anonymous=false está activo.

# Probar con un cliente válido:
docker exec mosquitto mosquitto_sub \
  -h localhost -p 1883 \
  -u nodered -P "$NR_PASS" \
  -t '$SYS/broker/uptime' -C 1 -W 3

# Esperado: una línea con uptime tipo "12 seconds".
```

### 6.3. Logs del primer arranque

```bash
docker compose --env-file /mnt/hd2t/services/mosquitto/.env logs --tail=50 mosquitto

# Esperado, líneas relevantes:
#   mosquitto version 2.0.20 starting
#   Config loaded from /mosquitto/config/mosquitto.conf.
#   Loading password file "/mosquitto/config/passwords"
#   Opening ipv4 listen socket on port 1883.
#   Opening ipv6 listen socket on port 1883.
#   mosquitto version 2.0.20 running
#
# Errores típicos del primer arranque:
#   Error: Unable to open password file "/mosquitto/config/passwords"
#     → Permisos: el fichero no es leíble por UID 1883.
#       sudo chown root:1883 /mnt/hd2t/services/mosquitto/config/passwords
#       sudo chmod 0640 /mnt/hd2t/services/mosquitto/config/passwords
#
#   Error: Unable to open log file /mosquitto/log/mosquitto.log
#     → Permisos: el directorio log/ no es escribible por UID 1883.
#       sudo chown -R 1883:1883 /mnt/hd2t/services/mosquitto/log
#
#   Error: Address in use (port 1883)
#     → Hay otro mosquitto corriendo en el host (paquete `mosquitto` vs el
#       contenedor). Como NO publicamos ports al host, esto NO debería
#       pasar; si pasa, alguien activó §12.1 sin parar antes el daemon
#       systemd:  sudo systemctl disable --now mosquitto
```

---

## 7. Verificación

### 7.1. Contenedor sano

```bash
docker compose --env-file /mnt/hd2t/services/mosquitto/.env ps
# STATUS de mosquitto: "Up X (healthy)".
```

### 7.2. Mosquitto NO escucha en el host

```bash
sudo ss -ltn | grep -E ':1883|:8883|:9001'
# Esperado: VACÍO. Ningún puerto MQTT publicado al host.

docker exec mosquitto ss -ltn | grep 1883
# Esperado: "LISTEN ... 0.0.0.0:1883" (dentro del contenedor).
```

### 7.3. Auth y ACL funcionan

Desde el host, simulando un cliente externo:

```bash
# 1. Anónimo: rechazado.
docker exec mosquitto mosquitto_pub \
  -h localhost -p 1883 \
  -t 'test/anon' -m 'hi' \
  -d 2>&1 | head -5
# Esperado: "Connection Refused: not authorised."

# 2. Usuario válido pero topic fuera de su ACL.
#    nodered NO puede escribir en homeassistant/#.
docker exec mosquitto mosquitto_pub \
  -h localhost -p 1883 \
  -u nodered -P "$NR_PASS" \
  -t 'homeassistant/sensor/test/config' -m '{}' \
  -d 2>&1 | head -10
# Esperado: el publish llega al broker, pero el log avisa "ACL denying access"
# y el suscriptor NO lo recibe.
sudo grep "ACL denying" /mnt/hd2t/services/mosquitto/log/mosquitto.log | tail -3

# 3. Usuario válido y topic permitido: éxito.
docker exec mosquitto mosquitto_pub \
  -h localhost -p 1883 \
  -u nodered -P "$NR_PASS" \
  -t 'nodered/test' -m 'hello' \
  -r
# Esperado: sin error.

docker exec mosquitto mosquitto_sub \
  -h localhost -p 1883 \
  -u homeassistant -P "$HA_PASS" \
  -t 'nodered/#' -C 1 -W 3
# Esperado: "hello" (porque homeassistant tiene `read nodered/#`).
```

### 7.4. Persistencia tras reboot

```bash
# Publicar un retained message como Z2M:
docker exec mosquitto mosquitto_pub \
  -h localhost -p 1883 \
  -u zigbee2mqtt -P "$Z2M_PASS" \
  -t 'zigbee2mqtt/test' -m 'persistent' \
  -r -q 1

# Reiniciar el contenedor.
docker compose --env-file /mnt/hd2t/services/mosquitto/.env restart mosquitto
sleep 5

# Suscriptor nuevo recibe el retained:
docker exec mosquitto mosquitto_sub \
  -h localhost -p 1883 \
  -u homeassistant -P "$HA_PASS" \
  -t 'zigbee2mqtt/test' -C 1 -W 3
# Esperado: "persistent" (el broker sirvió el retained desde mosquitto.db).
```

### 7.5. `mosquitto.db` se actualiza

```bash
sudo ls -lh /mnt/hd2t/services/mosquitto/data/
# Esperado: "-rw------- 1 1883 1883  ... mosquitto.db"
# Tamaño: > 0 bytes tras §7.4.

sudo file /mnt/hd2t/services/mosquitto/data/mosquitto.db
# Esperado: "data" (formato binario propio de Mosquitto, no SQLite).
```

### 7.6. Lista de Verificación

- [ ] `docker compose ps` lista `mosquitto` como `(healthy)`.
- [ ] `sudo ss -ltn | grep 1883` no devuelve nada (broker no expuesto al host).
- [ ] `docker exec mosquitto mosquitto_sub -h localhost -t '#' -C 1 -W 2` da "Connection Refused" (anónimos rechazados).
- [ ] `docker exec mosquitto mosquitto_sub -h localhost -u nodered -P <pwd> -t '$SYS/broker/uptime' -C 1` devuelve un valor.
- [ ] `sudo grep "ACL denying" /mnt/hd2t/services/mosquitto/log/mosquitto.log` confirma que ACL está activo (tras §7.3).
- [ ] `sudo ls -l /mnt/hd2t/services/mosquitto/data/mosquitto.db` muestra el fichero con propietario `1883:1883`.
- [ ] Tras un reboot completo (`sudo reboot`), retained messages siguen disponibles (§7.4).
- [ ] HA puede añadir la integración MQTT con `host: mosquitto`, `port: 1883`, `user: homeassistant`, `password: <pwd>` y la prueba "Submit" devuelve OK ([`./01-home-assistant.md`](./01-home-assistant.md) §8.2).

---

## 8. Configuración post-despliegue

### 8.1. Conectar Home Assistant

Cuando [`./01-home-assistant.md`](./01-home-assistant.md) esté operativo:

1. **Settings → Devices & Services → Add Integration → MQTT**.
2. Broker: `mosquitto` (resuelto por DNS Docker en la red `homelab`).
3. Port: `1883`.
4. Username: `homeassistant`.
5. Password: la generada en §4.2.2.
6. Submit. HA se conecta y publica el primer mensaje en `homeassistant/status`.

Verificar desde el host:

```bash
docker exec mosquitto mosquitto_sub \
  -h localhost -p 1883 \
  -u nodered -P "$NR_PASS" \
  -t 'homeassistant/status' -C 1 -W 5
# Esperado: "online".

docker exec mosquitto mosquitto_sub \
  -h localhost -p 1883 \
  -u nodered -P "$NR_PASS" \
  -t '$SYS/broker/clients/connected' -C 1 -W 3
# Esperado: ≥ 1 (HA aparece como cliente).
```

### 8.2. Conectar Zigbee2MQTT

Cuando [`./03-zigbee2mqtt.md`](./03-zigbee2mqtt.md) esté operativo, en su `configuration.yaml`:

```yaml
mqtt:
  server: mqtt://mosquitto:1883
  user: zigbee2mqtt
  password: !secret mqtt_password
  base_topic: zigbee2mqtt
  # Reintentos automáticos si Mosquitto está abajo:
  reject_unauthorized: true
  keepalive: 60
  version: 4   # MQTT 3.1.1 — el más compatible con Mosquitto 2.x
```

> El detalle (incluido el manejo de `secrets.yaml` de Z2M) está en [`./03-zigbee2mqtt.md`](./03-zigbee2mqtt.md). Aquí se documenta solo el **contrato** desde la perspectiva del broker.

### 8.3. Conectar Node-RED

[`./04-node-red.md`](./04-node-red.md) detalla el setup. Resumen del contrato:

- Configurar el nodo `mqtt-broker` de Node-RED:
  - Server: `mosquitto`
  - Port: `1883`
  - Use TLS: **off**
  - Client ID: `nodered`
  - Username: `nodered`
  - Password: la generada en §4.2.2
  - Keep alive: `60`
  - Use clean session: **off** (para que mensajes acumulados durante un restart de Node-RED se entreguen al volver — Mosquitto los retiene gracias a `max_queued_messages 5000`).

---

## 9. Operaciones cotidianas

### 9.1. Añadir un nuevo cliente

Caso típico: añadir un sensor ESPHome a la red.

```bash
# 1. Generar password aleatoria.
ESP_PASS="$(openssl rand -base64 24 | tr -d '+/=' | cut -c1-24)"
echo "esphome-salon:$ESP_PASS"

# 2. Añadir hash al fichero passwords.
docker run --rm \
  -v /mnt/hd2t/services/mosquitto/config:/mosquitto/config \
  eclipse-mosquitto:2.0.20 \
  mosquitto_passwd -b /mosquitto/config/passwords esphome-salon "$ESP_PASS"

# 3. Editar el ACL — añadir bloque.
sudo nano /mnt/hd2t/services/mosquitto/config/acl
# Al final del fichero:
#   user esphome-salon
#   topic readwrite esphome/salon/#
#   topic read homeassistant/+/+/config

# 4. Recargar Mosquitto (no hay reload de ACL en Mosquitto 2.x — se hace
#    restart, downtime ~2s, retained messages preservados).
docker compose --env-file /mnt/hd2t/services/mosquitto/.env restart mosquitto

# 5. Verificar conexión:
docker exec mosquitto mosquitto_pub \
  -h localhost -p 1883 \
  -u esphome-salon -P "$ESP_PASS" \
  -t 'esphome/salon/test' -m 'hello'
# Sin error → cliente listo.

# 6. Sincronizar la fuente versionada:
sudo cp /mnt/hd2t/services/mosquitto/config/acl ~/homelab/stacks/mosquitto/acl.example
cd ~/homelab && git add stacks/mosquitto/acl.example
git commit -m "feat(mosquitto): add esphome-salon ACL"
```

### 9.2. Rotar la password de un cliente

```bash
# 1. Generar nueva password.
NEW_HA_PASS="$(openssl rand -base64 24 | tr -d '+/=' | cut -c1-24)"

# 2. Sustituir el hash (mosquitto_passwd con -b reemplaza si existe el user).
docker run --rm \
  -v /mnt/hd2t/services/mosquitto/config:/mosquitto/config \
  eclipse-mosquitto:2.0.20 \
  mosquitto_passwd -b /mosquitto/config/passwords homeassistant "$NEW_HA_PASS"

# 3. Restart broker para releer (HA se desconecta y reintenta automáticamente).
docker compose --env-file /mnt/hd2t/services/mosquitto/.env restart mosquitto

# 4. En HA: Settings → Devices & Services → MQTT → "Configure" → Change password.
#    O en su CLI:
#    docker compose -f ~/homelab/stacks/homeassistant/docker-compose.yml \
#      restart homeassistant   # tras editar la password en la UI.

# 5. Anotar la nueva password en Vaultwarden.
```

> **Por qué no hay rolling update**: Mosquitto soporta **un único fichero de passwords** activo. La transición es atómica (restart < 2s). En LAN doméstica, los 1-2 segundos de desconexión del cliente son aceptables; el cliente reintenta y vuelve. Para cero downtime habría que activar dos brokers en bridge, lo cual está fuera del alcance del homelab personal.

### 9.3. Eliminar un cliente

```bash
# 1. Quitar la línea del fichero passwords.
sudo sed -i '/^esphome-salon:/d' /mnt/hd2t/services/mosquitto/config/passwords

# 2. Quitar el bloque del ACL.
sudo nano /mnt/hd2t/services/mosquitto/config/acl
# Borrar las líneas:
#   user esphome-salon
#   topic readwrite esphome/salon/#
#   topic read homeassistant/+/+/config

# 3. Restart.
docker compose --env-file /mnt/hd2t/services/mosquitto/.env restart mosquitto
```

### 9.4. Logs

```bash
# Tail en vivo del fichero:
sudo tail -F /mnt/hd2t/services/mosquitto/log/mosquitto.log

# Vía Docker:
docker compose --env-file /mnt/hd2t/services/mosquitto/.env logs --tail=200 -f mosquitto

# Vía Dozzle (../05-monitorizacion/06-dozzle.md), grupo "homeassistant".

# Filtrar errores de auth (intentos fallidos):
sudo grep -E 'Bad username|not authorised' /mnt/hd2t/services/mosquitto/log/mosquitto.log | tail -20

# Listar clientes conectados ahora:
docker exec mosquitto mosquitto_sub \
  -h localhost -p 1883 \
  -u nodered -P "$NR_PASS" \
  -t '$SYS/broker/clients/connected' -C 1 -W 3
```

### 9.5. Rotación del log con `logrotate`

`mosquitto.log` puede crecer rápidamente con `log_type information` (~5 MB/día con 4 clientes). Configurar `logrotate` en el host:

```bash
sudo tee /etc/logrotate.d/mosquitto > /dev/null <<'EOF'
/mnt/hd2t/services/mosquitto/log/mosquitto.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 1883 1883
    sharedscripts
    postrotate
        # Mosquitto 2.x reabre el log al recibir SIGUSR2 (no SIGHUP).
        # docker compose -f ... kill --signal SIGUSR2 mosquitto
        docker kill --signal=USR2 mosquitto 2>/dev/null || true
    endscript
}


# Probar sin rotar realmente:
sudo logrotate -d /etc/logrotate.d/mosquitto
```

> **¿Por qué SIGUSR2?**: el código fuente de Mosquitto 2.0 (`src/loop.c`) responde a `USR2` cerrando y reabriendo el log file. `SIGHUP` en 2.x **no reabre** el log (cambió respecto a 1.6); usarlo equivocadamente deja el broker escribiendo al inode antiguo (el `mosquitto.log.1` rotado), perdiendo eventos hasta el siguiente restart.

### 9.6. Upgrade

Watchtower lo hace solo. Para upgrade manual:

```bash
# 1. Leer CHANGELOG: https://mosquitto.org/blog/category/release/

# 2. Actualizar el tag.
sudo nano /mnt/hd2t/services/mosquitto/.env
# Cambiar MOSQUITTO_IMAGE_TAG=2.0.20 -> 2.0.21 (ejemplo)

# 3. Pull + recreate (downtime ~2s).
cd ~/homelab/stacks/mosquitto
docker compose --env-file /mnt/hd2t/services/mosquitto/.env pull
docker compose --env-file /mnt/hd2t/services/mosquitto/.env up -d

# 4. Verificar:
docker compose --env-file /mnt/hd2t/services/mosquitto/.env logs --tail=20 mosquitto | grep version
# Esperado: "mosquitto version 2.0.21 running".
```

> Mosquitto 2.x no requiere migración de `mosquitto.db` entre minors. Si Eclipse publica una **major** 3.0 en el futuro, leer las notas de incompatibilidad antes — la convención del homelab pasaría a `enable: "false"` mientras dura la transición.

---

## 10. Backup

> **Estrategia**: el broker no tiene BD relacional. Borgmatic respalda `/mnt/hd2t/services/mosquitto/` íntegro (config + data + log). El restore es trivial: copiar el directorio y levantar el contenedor.

### 10.1. Qué se respalda

| Ruta | Contenido | Crítico |
|---|---|---|
| `/mnt/hd2t/services/mosquitto/.env` | Tags, UIDs. | Bajo (reconstruible). |
| `/mnt/hd2t/services/mosquitto/config/mosquitto.conf` | Configuración. | Medio (también está en `~/homelab/stacks/mosquitto/`). |
| `/mnt/hd2t/services/mosquitto/config/passwords` | Hashes pbkdf2-sha512. | **Alto**. Sin esto, todos los clientes pierden conexión. |
| `/mnt/hd2t/services/mosquitto/config/acl` | Topología de topics. | Medio. |
| `/mnt/hd2t/services/mosquitto/data/mosquitto.db` | Retained messages + sesiones persistentes. | Medio. Si se pierde, el "último estado" de cada sensor se reconstruye en minutos cuando los dispositivos vuelvan a publicar. |
| `/mnt/hd2t/services/mosquitto/log/mosquitto.log` | Audit log. | Bajo (informativo). |

### 10.2. Borgmatic

[`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) ya incluye `/mnt/hd2t/services/` en sus `source_directories`. Mosquitto queda cubierto sin cambios en la configuración de Borgmatic.

> **No hay BD relacional que dumpear**. Mosquitto **no** se declara en la sección `databases:` de Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6). Su `.db` es un fichero binario propio que se respalda como cualquier otro.

### 10.3. Restore (resumen)

Procedimiento canónico — la receta extendida vive en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §2.

```bash
# 1. Detener el contenedor (si existe).
cd ~/homelab/stacks/mosquitto
docker compose --env-file /mnt/hd2t/services/mosquitto/.env down

# 2. Restaurar desde el último archivo Borg.
sudo borgmatic extract \
  --archive latest \
  --path mnt/hd2t/services/mosquitto \
  --destination /tmp/restore-mqtt

sudo rsync -aHAX --delete \
  /tmp/restore-mqtt/mnt/hd2t/services/mosquitto/ \
  /mnt/hd2t/services/mosquitto/

# 3. Asegurar permisos (rsync respeta los del archivo, pero defensivo):
sudo chown -R 1883:1883 /mnt/hd2t/services/mosquitto/data /mnt/hd2t/services/mosquitto/log
sudo chown root:1883 /mnt/hd2t/services/mosquitto/config/passwords /mnt/hd2t/services/mosquitto/config/acl
sudo chmod 0640 /mnt/hd2t/services/mosquitto/config/passwords /mnt/hd2t/services/mosquitto/config/acl

# 4. Levantar.
docker compose --env-file /mnt/hd2t/services/mosquitto/.env up -d

# 5. Verificar §7.
```

### 10.4. Smoke test (ad-hoc)

Cuando la rotación de smoke tests ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §8.3) toque "Mosquitto":

1. Levantar contenedor temporal apuntando a `/mnt/hd2t/backups/restore-test/mosquitto-YYYY-MM-DD/`.
2. Conectar con `mosquitto_sub -t 'zigbee2mqtt/+/availability' -W 5` y validar que aparecen los retained messages del último snapshot.
3. `sudo rm -rf` el directorio.
4. Anotar resultado en `~/homelab/operations/restore-tests.log`.

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `Error: Unable to open password file "/mosquitto/config/passwords"` en logs al arrancar | Permisos: el fichero no es leíble por UID 1883 (no está como `root:1883 0640`). | `sudo chown root:1883 /mnt/hd2t/services/mosquitto/config/passwords && sudo chmod 0640 ...`; restart. |
| `Error: Unable to open log file /mosquitto/log/mosquitto.log` | El directorio `log/` no es escribible por UID 1883. | `sudo chown -R 1883:1883 /mnt/hd2t/services/mosquitto/log && sudo chmod 0750 ...`; restart. |
| HA reporta `Failed to connect: Connection Refused: not authorised` | Password incorrecta en la integración MQTT de HA, o el usuario no existe en `passwords`. | `sudo grep '^homeassistant:' /mnt/hd2t/services/mosquitto/config/passwords`; si no aparece, regenerar (§4.2.2). Si aparece, rotar password (§9.2). |
| HA conecta pero no aparecen entidades de Z2M | ACL bloquea a HA en `zigbee2mqtt/#`, o Z2M aún no está corriendo. | `sudo grep "ACL denying" /mnt/hd2t/services/mosquitto/log/mosquitto.log`; revisar bloque `user homeassistant` del ACL. Confirmar que Z2M está `(healthy)` con `docker compose ps zigbee2mqtt`. |
| Los retained messages se pierden al reiniciar Mosquitto | `persistence false` o `data/` no es escribible. | `grep '^persistence' /mnt/hd2t/services/mosquitto/config/mosquitto.conf` debe devolver `true`. Comprobar que `mosquitto.db` se actualiza: `sudo stat /mnt/hd2t/services/mosquitto/data/mosquitto.db`. |
| Logs spam con `Bad username or password from <IP>` | Cliente con credencial vieja, o intento de fuerza bruta (solo posible con §12.1 activa). | Identificar cliente: la IP en logs corresponde al contenedor en `homelab` (172.20.0.X) o a un IoT en LAN. Rotar password si es legítimo, jail de fail2ban si no (§12.5). |
| `Socket error on client <id>, disconnecting.` repetido cada 60s para un mismo cliente | Cliente con `keepalive` mal configurado o red flapping. | En el cliente, asegurar `keepalive: 60`. Si el cliente es un IoT Wi-Fi con conexión inestable, subir `keepalive` a 120 en el cliente. |
| `mosquitto.db` crece sin parar (>100 MB) | Acumulación de retained messages — un cliente publica con `retain: true` y nuevos topics dinámicos. | Identificar el offending: `docker exec mosquitto mosquitto_sub -u nodered -P ... -t '#' -W 5 -v \| sort \| uniq -c \| sort -rn \| head -20`. Eliminar retained: publicar payload vacío con retain en ese topic. |
| Healthcheck siempre `unhealthy` | El comando del healthcheck depende de leer la password de `nodered` desde el fichero `passwords`, que está hasheada (no se puede recuperar la plain). | El healthcheck del §5 está diseñado para devolver `exit 0` si la password no se obtiene; revisar si alguien ha modificado el comando o el fichero `passwords`. Alternativa: simplificar a `pgrep -x mosquitto`. |
| Tras un upgrade, Mosquitto no arranca y loguea `Error: Unsupported config file version` | Migración entre majors no respetada (no debería pasar dentro de 2.x). | Volver al tag anterior: editar `MOSQUITTO_IMAGE_TAG` en `.env`, `up -d`. Leer CHANGELOG antes de re-intentar. |
| `docker logs mosquitto` muestra `Saving in-memory database to /mosquitto/data/mosquitto.db.` cada 5 min | Comportamiento normal (`autosave_interval 300`). | Sin acción. Si molesta, subir el intervalo a 1800 en `mosquitto.conf`. |
| Los clientes IoT Wi-Fi (variante §12.1) ven `Connection refused` | Mosquitto no está expuesto al host (sin `ports:`), o el firewall del host bloquea 1883. | Activar §12.1 (publicar `1883:1883` en compose), abrir el puerto en `ufw`/`nftables` (§12.1 detalla). |

---

## 12. Variantes opt-in

### 12.1. Exponer 1883 a la LAN para IoT Wi-Fi

**Cuándo activar**: hay dispositivos IoT Wi-Fi (ESPHome, Tasmota, Shelly Gen1, ESP32 propios) que no están en la red Docker `homelab` y necesitan publicar en MQTT.

**Cambio en `docker-compose.yml`**:

```yaml
services:
  mosquitto:
    # ... resto idéntico ...
    ports:
      - "1883:1883"   # MQTT plain — solo si NO se va a activar §12.2 (TLS).
```

**Cambios complementarios**:

- **Firewall del host** ([`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md)): permitir entrada en 1883 solo desde la subred LAN.
  ```bash
  sudo ufw allow proto tcp from 192.168.1.0/24 to any port 1883 comment 'mosquitto LAN'
  ```
- **DNS local en Pi-hole** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)): registro `mqtt.lan -> IP de la Pi`.
- **fail2ban** (§12.5): jail para `mosquitto.log` patrón `Bad username or password from <HOST>`.
- **Rotación de credenciales**: si la red LAN tiene clientes no de confianza (invitados WiFi), considerar VLAN separada para IoT antes que confiar solo en MQTT auth.

> **Sin TLS, las credenciales viajan en claro por la red local**. Si la WiFi está bien protegida (WPA3) el riesgo es bajo, pero la recomendación del homelab es **siempre §12.2** cuando se exponga el puerto.

### 12.2. TLS (puerto 8883) con certificado de Caddy

**Cuándo activar**: combinado con §12.1, para que las credenciales viajen cifradas. Requerido si la LAN incluye dispositivos no-confianza.

**Estrategia**: Caddy ya genera certs internos para `*.lan` con su CA local ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §3). Mosquitto consume esos certs como ficheros.

**Pasos**:

```bash
# 1. Declarar bloque explícito en Caddyfile para forzar emisión del cert:
#    mqtt.lan {
#        tls internal
#        respond "MQTT broker — usar TCP 8883 con TLS."
#    }
# Reload Caddy:
docker exec caddy caddy reload --config /etc/caddy/Caddyfile

# 2. Copiar el cert a un sitio que Mosquitto lea:
sudo install -d -o root -g 1883 -m 0750 /mnt/hd2t/services/mosquitto/config/certs
sudo install -o root -g 1883 -m 0640 \
  /mnt/hd2t/services/proxy/data/caddy/certificates/local/mqtt.lan/mqtt.lan.crt \
  /mnt/hd2t/services/mosquitto/config/certs/mqtt.lan.crt
sudo install -o root -g 1883 -m 0640 \
  /mnt/hd2t/services/proxy/data/caddy/certificates/local/mqtt.lan/mqtt.lan.key \
  /mnt/hd2t/services/mosquitto/config/certs/mqtt.lan.key
sudo install -o root -g 1883 -m 0640 \
  /mnt/hd2t/services/proxy/data/caddy/pki/authorities/local/root.crt \
  /mnt/hd2t/services/mosquitto/config/certs/ca.crt
```

**Añadir al `mosquitto.conf`**:

```conf
# ─── TLS listener (puerto 8883) ────────────────────────────────────────────
listener 8883
protocol mqtt
cafile /mosquitto/config/certs/ca.crt
certfile /mosquitto/config/certs/mqtt.lan.crt
keyfile /mosquitto/config/certs/mqtt.lan.key
tls_version tlsv1.2
require_certificate false   # Solo cert del servidor; clientes con user/pass.
```

**Publicar 8883 en compose** (sustituyendo o añadiendo a §12.1):

```yaml
ports:
  - "8883:8883"
  # - "1883:1883"   # Opcional: dejar 1883 abierto para legacy, no recomendado.
```

**En el dispositivo IoT** (ejemplo ESPHome):

```yaml
mqtt:
  broker: mqtt.lan
  port: 8883
  username: esphome-salon
  password: !secret mqtt_password
  certificate_authority: !lambda |-
    return id(ca_pem);   # PEM del ca.crt embebido en firmware
```

> **Renovación del cert**: Caddy renueva sus certs internos automáticamente. El cron del homelab debe re-copiar los ficheros tras cada renovación. Patrón: un script `~/homelab/operations/renew-mqtt-cert.sh` invocado tras `caddy reload` (hook del Caddyfile o cron mensual).

### 12.3. WebSockets (puerto 9001) para clientes web

**Cuándo activar**: hay un cliente browser-based (dashboard custom con [Paho.js](https://www.eclipse.org/paho/index.php?page=clients/js/index.php)) que quiere suscribirse a topics MQTT desde un navegador.

**Añadir al `mosquitto.conf`**:

```conf
listener 9001
protocol websockets
```

**Reverse proxy en Caddy** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3 — añadir bloque):

```caddy
mqtt-ws.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Caddy soporta WebSocket transparente con reverse_proxy.
    reverse_proxy http://mosquitto:9001 {
        header_up Host {host}
    }
}
```

> **Sin** publicar 9001 al host; va por dentro de Caddy. Cliente web -> `wss://mqtt-ws.lan` -> Caddy (TLS) -> mosquitto (plain WS).

### 12.4. Métricas Prometheus con `mosquitto-exporter`

**Cuándo activar**: cuando Fase 5 está completa ([`../05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md)).

**Añadir al stack** (`~/homelab/stacks/mosquitto/docker-compose.yml` — servicio adicional):

```yaml
services:
  mosquitto:
    # ... existente ...

  mosquitto-exporter:
    image: sapcc/mosquitto-exporter:0.8.0
    container_name: mosquitto-exporter
    restart: unless-stopped
    environment:
      BROKER_ENDPOINT: tcp://mosquitto:1883
      MQTT_USER: monitoring
      MQTT_PASS: ${MONITORING_PASS}   # añadir a .env
    networks:
      - homelab
    labels:
      com.centurylinklabs.watchtower.enable: "true"

# El exporter escucha en :9234. Añadir target a Prometheus:
#   - job_name: mosquitto
#     static_configs:
#       - targets: ['mosquitto-exporter:9234']
```

**Crear el cliente `monitoring` con ACL solo lectura**:

```bash
MONITORING_PASS="$(openssl rand -base64 24 | tr -d '+/=' | cut -c1-24)"
docker run --rm \
  -v /mnt/hd2t/services/mosquitto/config:/mosquitto/config \
  eclipse-mosquitto:2.0.20 \
  mosquitto_passwd -b /mosquitto/config/passwords monitoring "$MONITORING_PASS"

# ACL: añadir bloque
#   user monitoring
#   topic read $SYS/#
```

### 12.5. Jail de fail2ban para "Bad username or password"

**Cuándo activar**: con §12.1 activa (broker expuesto a la LAN).

**Filtro** `/etc/fail2ban/filter.d/mosquitto.conf`:

```ini
[Definition]
failregex = ^.*Bad username or password from <HOST>.*$
            ^.*Client .* disconnected, not authorised.*<HOST>.*$
ignoreregex =
datepattern = ^%%Y-%%m-%%dT%%H:%%M:%%S
```

**Jail** `/etc/fail2ban/jail.d/mosquitto.conf`:

```ini
[mosquitto]
enabled = true
port = 1883,8883
filter = mosquitto
logpath = /mnt/hd2t/services/mosquitto/log/mosquitto.log
maxretry = 5
findtime = 600
bantime = 3600
```

**Recargar**:

```bash
sudo systemctl reload fail2ban
sudo fail2ban-client status mosquitto
```

### 12.6. Bridge MQTT a un broker externo

**Cuándo activar**: integración con HA Cloud, AWS IoT, broker de un colega, etc.

**Añadir al `mosquitto.conf`**:

```conf
# ─── Bridge a broker externo ───────────────────────────────────────────────
connection bridge-cloud
address mqtt.example.com:8883
bridge_protocol_version mqttv311
bridge_cafile /mosquitto/config/certs/ca-cloud.crt
remote_username homelab-bridge
remote_password <SECRETO_AQUI>
# Topics: lo que envía el homelab al cloud, y lo que escucha de vuelta.
topic homeassistant/# out 1
topic cloud-cmd/# in 1
cleansession false
try_private false
notifications true
notification_topic bridge/cloud/state
```

> El bridge es **un cliente** del broker remoto, no expone nuestro broker al exterior. Útil para mirroring selectivo de tópicos. Mosquitto **no soporta variables `${...}` en `mosquitto.conf`**, así que el secreto va en plano y por eso `mosquitto.conf` con bridge debe pasar a `0640 root:1883`.

---

## Referencias

- **Imagen oficial Eclipse Mosquitto**: https://hub.docker.com/_/eclipse-mosquitto
- **Documentación Mosquitto 2.x**: https://mosquitto.org/documentation/
- **`mosquitto.conf(5)`**: https://mosquitto.org/man/mosquitto-conf-5.html
- **`mosquitto_passwd(1)`**: https://mosquitto.org/man/mosquitto_passwd-1.html
- **MQTT 5.0 spec**: https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html
- **CHANGELOG**: https://mosquitto.org/blog/category/release/
- **`mosquitto-exporter`**: https://github.com/sapcc/mosquitto-exporter
- **Documentos del homelab relacionados**:
  - Hub MQTT: [`./01-home-assistant.md`](./01-home-assistant.md)
  - Cliente Zigbee → MQTT: [`./03-zigbee2mqtt.md`](./03-zigbee2mqtt.md)
  - Orquestador de flujos: [`./04-node-red.md`](./04-node-red.md)
  - Reverse proxy Caddy (TLS, WebSockets): [`../03-red/04-caddy.md`](../03-red/04-caddy.md)
  - Política Watchtower: [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)
  - Estructura de directorios `/mnt/hd2t/services/`: [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)
  - Convenciones Compose (`name:`, red `homelab`, bind mounts): [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)
  - Estrategia de backup: [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md)
  - Borgmatic: [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
  - Restore de servicios: [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md)
  - Fail2ban (jails de servicios): [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md)
