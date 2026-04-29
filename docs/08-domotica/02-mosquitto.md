# Mosquitto MQTT

## Descripción

Con Home Assistant ya desplegado (`01-home-assistant.md`), el homelab tiene **cerebro** pero todavía le faltan los **nervios**: el mecanismo común por el que dispositivos heterogéneos (Zigbee, ESPHome, Tasmota, Shelly, sensores caseros, scripts en Node-RED) publican estados y reciben órdenes sin acoplarse entre sí.

**MQTT** (Message Queuing Telemetry Transport) es ese mecanismo: un protocolo *publish/subscribe* binario, mínimo, diseñado para redes de baja latencia y dispositivos con poca RAM. El componente central es un **broker** que enruta mensajes entre **publishers** (un sensor que dice "soy 21.4 °C") y **subscribers** (HA, que escucha `zigbee2mqtt/sensor_salon/temperature` y actualiza la entidad). Eclipse **Mosquitto** es el broker de referencia: un único binario en C, ~5 MiB de imagen, sin BBDD, con autenticación, ACLs y persistencia opcional.

Este documento despliega Mosquitto y lo deja listo como **bus de mensajería del homelab**. Su rol concreto:

1. **Receptor central de Zigbee2MQTT** (`03-zigbee2mqtt.md`): cada bombilla, sensor o enchufe Zigbee genera mensajes en `zigbee2mqtt/<dispositivo>/...` que Mosquitto reparte. Si Zigbee2MQTT cae, los mensajes quedan en el broker (con `retain`) hasta que vuelva.
2. **Bus de eventos para HA**: HA publica el cambio de estado de cualquier entidad como `homeassistant/...` mediante MQTT Discovery, y *suscribe* tópicos para integrar dispositivos no nativos. Es el patrón estándar de la integración MQTT.
3. **Vehículo para Node-RED** (`04-node-red.md`): los flujos visuales de Node-RED leen y escriben en tópicos MQTT en lugar de hablar directamente con cada dispositivo. Esto desacopla: si un día Tasmota se reemplaza por ESPHome, los flujos siguen funcionando porque el contrato es el tópico, no el firmware.
4. **Punto de entrada para dispositivos LAN no-Zigbee**: cualquier ESP32/ESP8266 con ESPHome, cualquier enchufe Tasmota o Shelly con MQTT habilitado, publica directamente en Mosquitto sin pasar por HA. HA luego lo descubre vía MQTT Discovery o se configura manualmente.
5. **Fuente de telemetría para monitorización** (`05-monitorizacion/01-prometheus.md`): un *exporter* de MQTT (`mqtt2prometheus` o `mqtt-exporter`) puede traducir tópicos a métricas para Grafana, separado del Recorder de HA.

Lo que este documento **no** decide:

- **Las integraciones concretas** que HA hace contra MQTT (configuración de la integración MQTT en HA, descubrimiento automático). Eso ya quedó preparado en `01-home-assistant.md` (paso "6) Preparar la integración MQTT") y se completa al final aquí.
- **El emparejamiento de dispositivos Zigbee**: pertenece a `03-zigbee2mqtt.md`. Aquí solo se crea el usuario `zigbee2mqtt` con sus ACLs para que el siguiente documento solo necesite arrancar el contenedor.
- **Los flujos de Node-RED**: pertenecen a `04-node-red.md`. Aquí solo se crea el usuario `nodered`.
- **MQTT sobre TLS (8883)**: ver decisión específica abajo. **No** se habilita en este homelab (LAN cerrada + Tailscale; el coste operativo de TLS bridge-to-bridge supera el beneficio).
- **Mosquitto en cluster/HA**: el broker es un único contenedor. Si cae, MQTT no fluye. Mitigado por `restart: unless-stopped` y `retain` en mensajes críticos. Reabrible (clúster con bridges) si en algún momento el operador despliega un segundo nodo.

Cuando este documento se haya aplicado, el operador puede:

- Ver Mosquitto **`Up (healthy)`** en `docker ps`, escuchando en `:1883/tcp` (MQTT plano) y `:9001/tcp` (WebSockets).
- Ejecutar `mosquitto_pub` y `mosquitto_sub` desde la Pi y desde la LAN, autenticándose con usuario/password.
- Confirmar que los anonymous publishers/subscribers están **rechazados** (`allow_anonymous false`).
- Ver en HA la integración MQTT **conectada y verde** (`Settings → Devices & Services → MQTT`), con HA capaz de publicar/leer en tópicos del homelab.
- Disponer de los usuarios `zigbee2mqtt` y `nodered` ya creados, con ACLs sandbox-eadas a sus subdominios de tópicos, listos para que `03-zigbee2mqtt.md` y `04-node-red.md` solo conecten.

> **Recordatorio de alcance**: Mosquitto es **solo LAN + tailnet**. El puerto `1883/tcp` se publica en la Pi y queda accesible desde `192.168.1.0/24` y `100.64.0.0/10` (tailscale). **No** se abre al WAN. La autenticación con usuario+password es **obligatoria**: con LAN comprometida (un dispositivo IoT chino con malware), un broker abierto sería una puerta trasera.

---

## Requisitos Previos

- **Fase 1** completa (sistema base, hostname `pi5`, zona horaria, locale).
- **Fase 2** completa (Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; `.env` global con `TZ`, `PUID=1000`, `PGID=1000`, `DOMAIN_LAN=lan`).
- **Fase 3** completa: Pi-hole (no es estrictamente necesario para MQTT, pero los logs de HA y los dashboards de Grafana resuelven `mqtt.${DOMAIN_LAN}` por su comodín). Caddy desplegado por si se quiere publicar el dashboard de Mosquitto WebSockets en algún momento (no se hace por defecto).
- **Fase 4** completa: Authelia existe pero **no** se usa con Mosquitto (MQTT no es HTTP; tiene su propio plano de auth nativo en el protocolo).
- **Fase 5** completa: Prometheus disponible, por si más adelante se añade un MQTT exporter.
- **Documento `01-home-assistant.md` aplicado**: HA escuchando en `:8123` del host con la línea `mqtt_username: homeassistant` ya en `secrets.yaml` (placeholder `mqtt_password` aún por rellenar en este documento).
- Disco `hd2t` montado en `/mnt/hd2t` con al menos **500 MiB** libres reservados para Mosquitto (`config`, `data` con persistencia ON, `log` rotado).
- Cliente MQTT instalado en la Pi para pruebas: `sudo apt install -y mosquitto-clients` (provee `mosquitto_pub` y `mosquitto_sub`; **no** instala el broker porque ya va en contenedor).

Comprobaciones rápidas:

```bash
# La red Docker compartida existe
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Home Assistant en marcha (acceso a HA por host.docker.internal:8123)
docker ps --filter name=homeassistant --format '{{.Names}} {{.Status}}'
# homeassistant   Up 2 hours (healthy)

# El placeholder en secrets.yaml de HA está vacío (se rellenará aquí)
sudo grep mqtt_password /mnt/hd2t/apps/home-assistant/config/secrets.yaml
# # mqtt_password: <generar con openssl rand -base64 24>     <-- comentado / vacío

# Espacio en hd2t
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'
# 1.5T libres

# Cliente MQTT instalado (para tests del paso "Configuración")
which mosquitto_pub mosquitto_sub
# /usr/bin/mosquitto_pub
# /usr/bin/mosquitto_sub
```

---

## Decisión: imagen y versión

Eclipse publica Mosquitto en Docker Hub bajo `eclipse-mosquitto`. Hay tres ramas mantenidas:

| Tag | Qué es | Veredicto |
|---|---|---|
| `latest` | Apunta a la última estable. | Descartado: política del homelab es pinear. |
| `2.0` (LTS) | Mosquitto 2.0.x, soporte hasta 2025+, multi-arch (incluye `linux/arm64`). Cambios desde 2.0: `allow_anonymous` por defecto **false** desde 2.0.x — el endurecimiento que se quiere. | **Aceptado**. |
| `2` | Alias móvil dentro de la rama 2.x. | Descartado por el mismo motivo que `latest`. |

**Tag exacto en uso**: `eclipse-mosquitto:2.0`. Política: pin a la rama LTS, **no** a `latest` ni a una versión `2.0.X` específica (los parches de seguridad dentro de la rama LTS los aceptamos automáticamente vía Watchtower).

> **Por qué Mosquitto y no EMQX/HiveMQ/RabbitMQ-MQTT**. EMQX y HiveMQ son brokers comerciales/empresariales (clúster, dashboards) que pesan ~500 MiB y consumen ~300 MiB de RAM en idle. RabbitMQ con su plugin MQTT es similar. Para un homelab de 1 nodo con ≤200 dispositivos, Mosquitto consume **~5 MiB de imagen y ~10 MiB de RAM** y cubre el 100% del estándar MQTT 3.1.1 y 5.0. La superioridad de los grandes solo aparece cuando se necesita HA/clúster.

---

## Decisión: networking — `homelab` bridge con puerto publicado

A diferencia de Home Assistant (que necesita `network_mode: host` por mDNS), Mosquitto solo habla TCP unicast en su puerto. Se queda en el bridge `homelab`.

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| **Bridge `homelab`, sin `ports:`** | Limpio, accesible solo desde otros contenedores (Z2M, Node-RED) por DNS interno (`mosquitto:1883`). | HA está en `host` y no puede llegar al bridge por nombre. Tampoco pueden hacerlo dispositivos LAN (Tasmota, ESPHome, móvil con app MQTT). | Insuficiente: HA y dispositivos LAN se quedan fuera. |
| **Bridge `homelab` + `ports: ["1883:1883","9001:9001"]`** (publicar) | HA llega vía `host.docker.internal:1883`. Dispositivos LAN llegan vía `192.168.1.10:1883`. Otros contenedores siguen llegando por `mosquitto:1883`. | Expone el broker en LAN — *correcto* en este caso, es lo que se quiere; el firewall y la auth se encargan. | **Aceptado**. |
| **`network_mode: host`** | Rendimiento marginalmente mejor. | Pierde DNS interno (`mosquitto` deja de resolver desde el bridge); rompe la convención. | Descartado. |

Resultado: **bridge `homelab` con `1883:1883` y `9001:9001` publicados**. Implicaciones:

1. **Bind**: por defecto Docker publica en `0.0.0.0:1883`. Eso es lo que se quiere para que la LAN llegue. El **firewall del host** (`01-sistema/03-seguridad-base.md`) restringe `1883/tcp` a `192.168.1.0/24` + `tailscale0`; **no** se acepta tráfico WAN.
2. **HA llega a Mosquitto** vía `host.docker.internal:1883`. La línea `extra_hosts: ["host.docker.internal:host-gateway"]` que `01-home-assistant.md` añadió a Caddy **no aplica aquí**: HA está en `network_mode: host`, así que `host.docker.internal` resuelve directamente al loopback del host. La integración MQTT de HA usa `127.0.0.1:1883` y funciona.
3. **Otros contenedores en `homelab`** (Z2M, Node-RED, mqtt-exporter futuro) usan `mosquitto:1883` por DNS interno. **Más rápido** que pasar por el host (no hay NAT).
4. **WebSockets `:9001`**: mismo principio. Útil para dashboards web embebidos o el cliente MQTT del navegador (no se usa por defecto pero deja la puerta abierta).
5. **No se publica `8883`**: TLS desactivado (ver siguiente decisión).

---

## Decisión: TLS — **no** habilitado, MQTT plano sobre LAN/tailnet

MQTT soporta TLS en el puerto 8883. Es opcional; la práctica común en homelabs es desactivarlo si la red de control es de confianza.

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| **MQTT plano (`1883`)** | Cero ceremonia. Auth con usuario+password viaja en claro, pero la red ya es privada. | El password **se envía en cleartext** dentro del payload CONNECT. Quien hace MITM en LAN lo ve. | **Aceptado** para LAN+tailnet. |
| **MQTT sobre TLS (`8883`)** con CA interna | Tráfico cifrado y autenticación de servidor. | Mosquitto requiere ficheros de cert montados; cada cliente IoT (ESP8266, Shelly, etc.) tiene que tener instalada la CA del homelab — muchos *no* lo soportan o lo soportan mal. Operativamente caro. | Reabrible si entran dispositivos LAN sensibles. |
| **MQTT sobre TLS con cert de Tailscale** | Igual, pero solo expuesto en tailnet. | Mismas pegas que arriba; Tailscale ya cifra todo lo que pasa por su mesh, no añade. | Descartado: Tailscale ya hace ese trabajo. |

Política: **MQTT plano + autenticación obligatoria + ACLs estrictas + firewall LAN**. La defensa-en-profundidad cubre el riesgo:

- El password no es la única barrera: las ACLs limitan qué tópicos puede tocar cada usuario, así que un password filtrado de `homeassistant` no permite a nadie publicar en `zigbee2mqtt/...` y secuestrar bombillas.
- La LAN está aislada del WAN; un atacante necesita primero comprometer otro dispositivo IoT.
- Tailscale cifra **toda** la comunicación entre nodos del tailnet (incluido MQTT) extremo a extremo.

> **Cuándo cambiarlo**. Si se compra un dispositivo IoT que requiera TLS por homologación (ej. integración con cerradura electrónica con cumplimiento legal). En ese caso, generar cert de servidor con la CA interna (`03-red/04-caddy.md`), montar `cafile`/`certfile`/`keyfile` en `/mosquitto/config/tls/`, exponer `:8883`, y los pocos clientes "duros" hablan TLS mientras el resto sigue en `1883`.

---

## Decisión: persistencia y QoS

Mosquitto puede operar **stateless** (todo en RAM, mensajes se pierden al reiniciar) o **persistente** (mensajes con `retain` y sesiones de clientes con `clean_session false` se guardan en disco).

| Opción | Cuándo conviene | Veredicto |
|---|---|---|
| **`persistence false`** (en RAM) | Brokers efímeros, todo es eventual. | Descartado: HA depende de mensajes `retain` (ej. estado de cada bombilla Zigbee se publica con retain para que HA lo lea al arrancar). Sin persistencia, tras reiniciar Mosquitto cada bombilla queda "unknown" hasta su siguiente cambio. |
| **`persistence true`** + `persistence_location /mosquitto/data/` | Estados `retain` y sesiones offline sobreviven al reinicio. | **Aceptado**. |

Configuración aplicada:

- `persistence true`
- `persistence_location /mosquitto/data/`
- `autosave_interval 1800` (volcado a disco cada 30 min; balance entre durabilidad y desgaste).
- `max_inflight_messages 40` (límite por cliente; default 20, subido para Z2M con muchos dispositivos en burst).
- `max_queued_messages 1000` (mensajes pendientes por cliente offline antes de descartar; default 1000, OK).
- **QoS**: el broker soporta QoS 0/1/2; cada *publisher* elige. Política recomendada (no aplicable al broker, sí a clientes):
  - **QoS 0** (fire-and-forget) para datos no críticos: telemetría continua, sensores que envían cada segundo.
  - **QoS 1** (al menos una vez) para comandos: encender una luz, abrir una persiana — interesa que se entregue aunque sea con duplicados.
  - **QoS 2** (exactamente una vez) muy raramente: solo en casos donde un duplicado tiene impacto real (ej. transacción financiera; aquí, ninguno).

Lo aplicará cada cliente (HA, Z2M, dispositivos) en su propia config. Mosquitto solo lo *soporta*.

---

## Decisión: logging

Mosquitto puede loguear a stdout (recoge Docker), a fichero rotado, a syslog o a tópicos MQTT (`$SYS/...`). Recoger por Docker es lo simple y se integra con Promtail si en algún momento se enchufa a Loki.

```text
log_dest stdout
log_type error
log_type warning
log_type notice
log_type information
connection_messages true
log_timestamp true
```

> **Por qué stdout y no fichero**. Un fichero en `/mosquitto/log/` requiere rotación manual (logrotate dentro del contenedor o un script aparte). Con stdout, `docker logs mosquitto` ya está, y el daemon de Docker ya rota por tamaño (`max-size: 10m`, `max-file: 3` configurado en `/etc/docker/daemon.json` por Fase 2). Un solo origen de verdad.

> **Sobre `$SYS/`**. Mosquitto publica métricas internas en tópicos `$SYS/broker/...` (uptime, mensajes/s, clientes conectados). Útiles para monitorización (`mqtt-exporter` los traduce a Prometheus). Aquí simplemente quedan disponibles; el exporter es opcional y futuro.

---

## Decisión: usuarios y ACLs

Mosquitto con `allow_anonymous false` exige usuario+password en cada CONNECT. Las ACLs (`acl_file`) restringen qué tópicos cada usuario puede `read`/`write`/`readwrite`.

Modelo de usuarios para el homelab:

| Usuario | Rol | ACLs |
|---|---|---|
| `homeassistant` | El "maestro" — HA publica/lee en muchos tópicos. | `readwrite #` (acceso total). Justificable: HA es el orquestador. |
| `zigbee2mqtt` | Bridge Zigbee → MQTT. | `readwrite zigbee2mqtt/#` (su propio subárbol). `read homeassistant/status` (necesita saber si HA está vivo para reenviar discovery). |
| `nodered` | Flujos de Node-RED. | `readwrite nodered/#`. `readwrite homeassistant/#` (publica events para HA). `read zigbee2mqtt/#` (lee estados Zigbee, no los modifica directamente — lo hace via HA). |
| `monitor` | Reservado para futuro `mqtt-exporter`. Solo lectura de `$SYS/`. | `read $SYS/#`. |
| `admin` | Para el operador desde `mosquitto_sub`/`mosquitto_pub` puntuales y troubleshooting. | `readwrite #`. |

> **Por qué `homeassistant` tiene `readwrite #` y no algo más restrictivo**. HA usa MQTT Discovery: publica en `homeassistant/<component>/<unique_id>/config` para anunciar entidades, y suscribe `homeassistant/status` y un montón de tópicos heterogéneos según las integraciones que habiliten los usuarios futuros. Ajustar la ACL caso a caso requeriría reiniciar Mosquitto cada vez que se añade una integración. La vía pragmática es: **HA confianza alta, los demás sandboxed**.

> **Por qué un usuario `admin` separado del operador en el host**. El operador interactúa con `mosquitto_pub`/`mosquitto_sub` desde la línea de comandos para troubleshooting (ver `messages` de un dispositivo nuevo, forzar un comando manual). Si reutiliza credenciales de `homeassistant`, un fallo de tipeo (`mosquitto_pub -t 'homeassistant/light/x/set' -m off` cuando quería `'set'`) puede meter mensajes inesperados en el flujo principal. `admin` se usa solo manualmente y queda trazable en logs.

Las contraseñas se generan ahora con `openssl rand -base64 24` (32 caracteres ASCII). Se guardan en el gestor de contraseñas del operador y se replican en `/mnt/hd2t/apps/home-assistant/config/secrets.yaml` (la de `homeassistant`) y en los `.env` de los stacks de Z2M y Node-RED cuando esos documentos se apliquen.

---

## Stack: `stacks/mosquitto/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/mosquitto/docker-compose.yml` | microSD (git) | Stack (servicio `mosquitto`). |
| `stacks/mosquitto/.env.example` | microSD (git) | Plantilla con `MOSQUITTO_*_PASSWORD` (vacíos en repo). |
| `stacks/mosquitto/mosquitto.conf` | microSD (git) | Configuración del broker. |
| `stacks/mosquitto/acl` | microSD (git) | Reglas ACL (sin secretos, versionable). |
| `stacks/mosquitto/passwd.example` | microSD (git) | Plantilla con usuarios sin hash, NO se versiona el real. |
| `/mnt/hd2t/apps/mosquitto/config/mosquitto.conf` | hd2t | Config materializada. |
| `/mnt/hd2t/apps/mosquitto/config/passwd` | hd2t | Fichero de credenciales hasheadas (modo `0640`, owner `1883:1883`). |
| `/mnt/hd2t/apps/mosquitto/config/acl` | hd2t | ACLs activas. |
| `/mnt/hd2t/apps/mosquitto/data/` | hd2t | Persistencia (mensajes retained, sesiones). |
| `/mnt/hd2t/apps/mosquitto/log/` | hd2t | Reservado para `log_dest file` futuro; vacío hoy. |

> **Sobre el UID/GID 1883**. La imagen oficial `eclipse-mosquitto:2.0` corre como **UID 1883, GID 1883** (usuario `mosquitto` interno), **no** como 1000 (PUID del homelab). Esto se debe a que la imagen viene con ese usuario hardcoded en el Dockerfile. Las opciones son: (a) montar los volúmenes con `chown 1883:1883`, (b) sobreescribir con `user: ${PUID}:${PGID}` y arreglar permisos. **Aceptado (a)**: alinearse con la imagen. Es el único stack del homelab que no usa 1000:1000; queda documentado.

### `stacks/mosquitto/docker-compose.yml`

```yaml
# Mosquitto MQTT broker — bus de mensajería del homelab.
# Documentado en docs/08-domotica/02-mosquitto.md.

name: mosquitto

services:
  mosquitto:
    image: eclipse-mosquitto:2.0
    container_name: mosquitto
    hostname: mosquitto
    restart: unless-stopped

    # MQTT plano (1883) y WebSocket (9001) publicados al host.
    # El firewall del host limita ambos a LAN+tailscale0.
    # NO se publica 8883 (TLS): ver "Decisión: TLS" en el doc.
    ports:
      - "1883:1883"
      - "9001:9001"

    networks:
      - homelab

    # La imagen corre como UID/GID 1883 (usuario mosquitto interno),
    # NO como PUID/PGID del homelab (1000). Los bind mounts deben tener
    # owner 1883:1883 para que Mosquitto pueda leer/escribir.
    user: "1883:1883"

    environment:
      TZ: ${TZ}

    volumes:
      - /mnt/hd2t/apps/mosquitto/config:/mosquitto/config
      - /mnt/hd2t/apps/mosquitto/data:/mosquitto/data
      - /mnt/hd2t/apps/mosquitto/log:/mosquitto/log

    healthcheck:
      # mosquitto_sub conecta como 'admin' con timeout corto; si el broker
      # responde con CONNACK 0 (success), el comando termina con exit 0.
      # Se usa $$ para escapar el $ en docker-compose.
      test:
        - "CMD-SHELL"
        - |
          mosquitto_sub -h 127.0.0.1 -p 1883 \
            -u admin -P "$$(cat /run/secrets/admin_pwd 2>/dev/null || echo healthcheck)" \
            -t '$$SYS/broker/uptime' -C 1 -W 5 >/dev/null 2>&1 || \
          mosquitto_pub -h 127.0.0.1 -p 1883 -t healthcheck -m ping -q 0 2>&1 | grep -q "Connection Refused: not authorised" && exit 0 || exit 1
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s

    labels:
      homelab.role: "mqtt-broker"
      homelab.backup: "true"
      com.centurylinklabs.watchtower.enable: "true"

networks:
  homelab:
    external: true
```

> **Sobre el healthcheck**. Es deliberadamente "raro": no hay endpoint HTTP, así que se prueba un CONNECT MQTT real con `mosquitto_sub` (que está en la misma imagen). Si el broker responde — incluso con "not authorised" — significa que está vivo y autenticando, que es lo que nos importa. El primer comando intenta autenticación válida; el segundo es el fallback si el secret no está disponible (caso típico durante bootstrap). Una respuesta "not authorised" es **éxito** desde el punto de vista de "el broker funciona": rechaza credenciales malas, prueba que la pila auth está cargada.

> **Sobre `user: "1883:1883"`**. Documentado arriba. La imagen ya usa ese UID por defecto, así que técnicamente la línea es redundante; se deja explícita para que cualquier `chown` operativo no se desincronice del compose.

### `stacks/mosquitto/.env.example`

```bash
# stacks/mosquitto/.env.example
# Variables específicas del stack Mosquitto. Las generales (TZ) vienen
# del .env GLOBAL del homelab.
#
# Las contraseñas REALES no se almacenan aquí (el fichero passwd hasheado
# vive en /mnt/hd2t/apps/mosquitto/config/passwd, modo 0640).
# Estas variables son SOLO para que un script de bootstrap pueda generar
# el passwd inicial. Después de generarlo, se borran de .env.

# Generar con: openssl rand -base64 24
MOSQUITTO_HOMEASSISTANT_PASSWORD=changeme
MOSQUITTO_ZIGBEE2MQTT_PASSWORD=changeme
MOSQUITTO_NODERED_PASSWORD=changeme
MOSQUITTO_MONITOR_PASSWORD=changeme
MOSQUITTO_ADMIN_PASSWORD=changeme
```

### `stacks/mosquitto/mosquitto.conf`

```conf
# /mosquitto/config/mosquitto.conf — Mosquitto broker.
# Documentado en docs/08-domotica/02-mosquitto.md.

# ----------------------------------------------------------------------
# General
# ----------------------------------------------------------------------
persistence true
persistence_location /mosquitto/data/
autosave_interval 1800

# Limites generosos para Z2M con ~100 dispositivos en burst.
max_inflight_messages 40
max_queued_messages 1000
max_packet_size 268435456   # 256 MiB; default es 0 (sin límite). Por seguridad.

# ----------------------------------------------------------------------
# Logging — a stdout, recogido por Docker.
# ----------------------------------------------------------------------
log_dest stdout
log_type error
log_type warning
log_type notice
log_type information
connection_messages true
log_timestamp true

# ----------------------------------------------------------------------
# Listeners
# ----------------------------------------------------------------------

# MQTT plano sobre TCP — listener principal.
listener 1883 0.0.0.0
protocol mqtt

# MQTT sobre WebSocket — útil para clientes web embebidos.
listener 9001 0.0.0.0
protocol websockets

# ----------------------------------------------------------------------
# Autenticación y autorización
# ----------------------------------------------------------------------

# CRÍTICO: rechazar conexiones anónimas. Default desde Mosquitto 2.0.
allow_anonymous false

# Fichero de usuarios (creado fuera del contenedor con mosquitto_passwd).
password_file /mosquitto/config/passwd

# ACLs por tópico/usuario.
acl_file /mosquitto/config/acl

# ----------------------------------------------------------------------
# Misceláneo
# ----------------------------------------------------------------------

# Limit de conexiones por client_id duplicado (default true: el segundo
# desconecta al primero). Z2M reintenta CONNECT al iniciar; ok.
allow_duplicate_messages false

# No permitir wildcards en will topics (defensa en profundidad).
# (default false; explícito.)
```

### `stacks/mosquitto/acl`

```text
# /mosquitto/config/acl — ACLs de Mosquitto del homelab.
# Documentado en docs/08-domotica/02-mosquitto.md.
#
# Sintaxis:
#   user <username>
#   topic [read|write|readwrite] <patrón>
#   pattern [...] %u (variable: usuario actual)
#
# Por defecto, sin entradas: cada usuario solo puede leer/escribir lo
# que se le dé explícitamente. NO hay default permit.

# ----------------------------------------------------------------------
# homeassistant — el orquestador. Acceso total.
# Justificación: HA usa MQTT Discovery con tópicos heterogéneos.
# ----------------------------------------------------------------------
user homeassistant
topic readwrite #

# ----------------------------------------------------------------------
# zigbee2mqtt — bridge Zigbee. Sandbox a su subárbol.
# ----------------------------------------------------------------------
user zigbee2mqtt
topic readwrite zigbee2mqtt/#
topic read homeassistant/status
# Para que Z2M pueda re-publicar discovery cuando HA se reinicie:
topic write homeassistant/+/+/config
topic write homeassistant/+/+/+/config

# ----------------------------------------------------------------------
# nodered — flujos. Sandbox a su subárbol + acceso a HA Discovery.
# ----------------------------------------------------------------------
user nodered
topic readwrite nodered/#
topic readwrite homeassistant/#
topic read zigbee2mqtt/#

# ----------------------------------------------------------------------
# monitor — futuro mqtt-exporter, solo lee SYS.
# ----------------------------------------------------------------------
user monitor
topic read $SYS/#

# ----------------------------------------------------------------------
# admin — operador en CLI, acceso total.
# Uso: mosquitto_pub/mosquitto_sub desde la Pi para troubleshooting.
# ----------------------------------------------------------------------
user admin
topic readwrite #
```

### `stacks/mosquitto/passwd.example`

```text
# /mosquitto/config/passwd.example — plantilla de usuarios.
#
# El fichero real (passwd) NO se versiona. Se genera con:
#
#   docker run --rm -v /mnt/hd2t/apps/mosquitto/config:/mosquitto/config \
#     eclipse-mosquitto:2.0 \
#     mosquitto_passwd -b -c /mosquitto/config/passwd <user> <password>
#
# Para añadir más usuarios al fichero existente, omitir el flag -c:
#
#   docker run --rm -v /mnt/hd2t/apps/mosquitto/config:/mosquitto/config \
#     eclipse-mosquitto:2.0 \
#     mosquitto_passwd -b /mosquitto/config/passwd <user> <password>
#
# Resultado: cada línea queda en formato "<user>:<hash>".

# Usuarios esperados:
#   homeassistant
#   zigbee2mqtt
#   nodered
#   monitor
#   admin
```

### Crear los directorios persistentes y desplegar

```bash
# Directorios — owner 1883:1883 (NO 1000:1000 como otros stacks).
sudo install -d -o 1883 -g 1883 -m 0750 /mnt/hd2t/apps/mosquitto
sudo install -d -o 1883 -g 1883 -m 0750 /mnt/hd2t/apps/mosquitto/config
sudo install -d -o 1883 -g 1883 -m 0750 /mnt/hd2t/apps/mosquitto/data
sudo install -d -o 1883 -g 1883 -m 0750 /mnt/hd2t/apps/mosquitto/log

# ACL para que el operador (homelab, UID 1000) pueda leer logs y
# editar config con sudo.
sudo setfacl -R -m u:homelab:rx /mnt/hd2t/apps/mosquitto
sudo setfacl -d -m u:homelab:rx /mnt/hd2t/apps/mosquitto

# Materializar config y ACL desde el repo.
cd /home/homelab/homelab
set -a; source .env; set +a

sudo install -o 1883 -g 1883 -m 0644 \
    stacks/mosquitto/mosquitto.conf \
    /mnt/hd2t/apps/mosquitto/config/mosquitto.conf
sudo install -o 1883 -g 1883 -m 0644 \
    stacks/mosquitto/acl \
    /mnt/hd2t/apps/mosquitto/config/acl

# Generar las contraseñas (se mostrarán una sola vez; copiarlas al
# gestor de contraseñas inmediatamente).
HA_PWD=$(openssl rand -base64 24)
Z2M_PWD=$(openssl rand -base64 24)
NR_PWD=$(openssl rand -base64 24)
MON_PWD=$(openssl rand -base64 24)
ADM_PWD=$(openssl rand -base64 24)

echo "homeassistant: $HA_PWD"
echo "zigbee2mqtt:   $Z2M_PWD"
echo "nodered:       $NR_PWD"
echo "monitor:       $MON_PWD"
echo "admin:         $ADM_PWD"
echo "---> Copiar al gestor de contraseñas AHORA. No se mostrarán de nuevo."
read -p "Pulsa Enter cuando estén guardadas..." _

# Crear el fichero passwd con todos los usuarios.
# Nota: la primera invocación usa -c (crea/trunca el fichero).
docker run --rm \
    -v /mnt/hd2t/apps/mosquitto/config:/mosquitto/config \
    eclipse-mosquitto:2.0 \
    mosquitto_passwd -b -c /mosquitto/config/passwd homeassistant "$HA_PWD"

for user_pwd in "zigbee2mqtt:$Z2M_PWD" "nodered:$NR_PWD" "monitor:$MON_PWD" "admin:$ADM_PWD"; do
    user="${user_pwd%%:*}"
    pwd="${user_pwd#*:}"
    docker run --rm \
        -v /mnt/hd2t/apps/mosquitto/config:/mosquitto/config \
        eclipse-mosquitto:2.0 \
        mosquitto_passwd -b /mosquitto/config/passwd "$user" "$pwd"
done

# Permisos finales del passwd (mosquitto_passwd lo deja 0700 por defecto;
# necesita ser legible por el UID 1883 del contenedor).
sudo chmod 0640 /mnt/hd2t/apps/mosquitto/config/passwd
sudo chown 1883:1883 /mnt/hd2t/apps/mosquitto/config/passwd

# Verificar que los 5 usuarios están.
sudo wc -l /mnt/hd2t/apps/mosquitto/config/passwd
# 5 /mnt/hd2t/apps/mosquitto/config/passwd

# .env del stack (se borra después de bootstrap; las contraseñas viven
# en el gestor + secrets.yaml de HA).
cp stacks/mosquitto/.env.example stacks/mosquitto/.env
chmod 0600 stacks/mosquitto/.env

# Levantar Mosquitto.
docker compose \
    -f stacks/mosquitto/docker-compose.yml \
    --env-file stacks/mosquitto/.env \
    up -d
```

Tras `up -d`:

```bash
docker ps --filter name=mosquitto
# CONTAINER ID  IMAGE                       STATUS
# ...           eclipse-mosquitto:2.0       Up 20 seconds (healthy)

# Logs del primer arranque (aceptable: anuncia listener, carga acl/passwd).
docker logs mosquitto --tail 20
# 1730212345: mosquitto version 2.0.18 starting
# 1730212345: Config loaded from /mosquitto/config/mosquitto.conf.
# 1730212345: Loading plugin: ...
# 1730212345: Opening ipv4 listen socket on port 1883.
# 1730212345: Opening ipv4 listen socket on port 9001.
# 1730212345: mosquitto version 2.0.18 running

# Confirmar que escucha en :1883 y :9001 del host.
ss -tlnp | grep -E ':(1883|9001) '
# LISTEN 0 4096 *:1883 *:* users:(("docker-proxy",pid=...))
# LISTEN 0 4096 *:9001 *:* users:(("docker-proxy",pid=...))
```

---

## Configuración

### 1) Probar autenticación y ACLs desde la línea de comandos

Desde la Pi (o cualquier host de la LAN con `mosquitto-clients`):

```bash
# Anonymous: debe FALLAR (allow_anonymous false).
mosquitto_pub -h 127.0.0.1 -p 1883 -t test -m hello
# Connection error: Connection Refused: not authorised.

# Con admin: debe FUNCIONAR (acceso total).
mosquitto_pub -h 127.0.0.1 -p 1883 -u admin -P "$ADM_PWD" -t test -m hello
# (sale sin error)

# En otra terminal: subscribirse y ver el mensaje.
mosquitto_sub -h 127.0.0.1 -p 1883 -u admin -P "$ADM_PWD" -t test -v
# test hello

# zigbee2mqtt intentando publicar fuera de su sandbox: debe FALLAR.
mosquitto_pub -h 127.0.0.1 -p 1883 -u zigbee2mqtt -P "$Z2M_PWD" \
    -t fuera_de_alcance -m forbidden
# (publica OK al broker, pero el ACL drop es silencioso lado servidor;
#  el log de mosquitto lo registra:)
docker logs mosquitto --tail 5 | grep -i denied
# 1730212412: Denied PUBLISH from zigbee2mqtt (..., topic='fuera_de_alcance').
```

> **Por qué los ACL drops son silenciosos para el cliente**. MQTT no tiene un código de retorno por publicación rechazada (publish es fire-and-forget en QoS 0). El cliente "publica" y el broker lo descarta; solo se ve en los logs del broker. Para confirmar que la ACL funciona, mirar `docker logs mosquitto | grep -i denied`.

### 2) Inyectar la contraseña de `homeassistant` en `secrets.yaml`

El placeholder en `01-home-assistant.md` queda completado:

```bash
# Editar secrets.yaml de HA con sudo (es root:root 0600).
sudo -e /mnt/hd2t/apps/home-assistant/config/secrets.yaml
```

Contenido final (reemplaza el comentario):

```yaml
# /config/secrets.yaml — Home Assistant.

mqtt_username: homeassistant
mqtt_password: <pegar aquí HA_PWD generado>

# Otros secretos: añadir según se desplieguen integraciones.
```

### 3) Configurar la integración MQTT en HA

Desde la UI:

```text
1. https://home.lan/  → Settings → Devices & Services → Add Integration.
2. Buscar "MQTT" → seleccionar.
3. Datos:
   - Broker:    127.0.0.1
     (HA está en network_mode: host; Mosquitto publica :1883 en el host.
      También vale "host.docker.internal", pero con HA en host networking
      eso resuelve al loopback; usar "127.0.0.1" es más explícito.)
   - Port:      1883
   - Username:  homeassistant
   - Password:  <HA_PWD>
   - Advanced settings:
     - Enable discovery: ON
     - Discovery prefix: homeassistant
     - Birth and last will: dejar defaults (HA publica/escucha
       homeassistant/status para LWT).
4. "Submit" → "MQTT" debería quedar como tarjeta verde "Connected".
```

> **Sobre `127.0.0.1` vs `mosquitto`**. HA *no* puede usar el nombre `mosquitto` porque está en `network_mode: host`, fuera del bridge. La opción canónica es `127.0.0.1:1883`. Si en el futuro HA pasa a vivir en `homelab` (decisión a revisar si se descartan integraciones por mDNS), entonces sí se cambiaría a `mosquitto:1883`.

Verificar la conexión:

```bash
# Forzar a HA a publicar y leer un mensaje.
mosquitto_sub -h 127.0.0.1 -p 1883 -u admin -P "$ADM_PWD" \
    -t 'homeassistant/status' -v &

# En la UI de HA: Developer Tools → Services → mqtt.publish con:
#   topic: test/echo
#   payload: hola desde HA

# Volver al terminal: el mensaje "hola desde HA" debería verse.
```

Y al revés, publicar desde fuera y verlo en HA:

```bash
mosquitto_pub -h 127.0.0.1 -p 1883 -u admin -P "$ADM_PWD" \
    -t 'sensor/temperatura_test' -m '21.5'

# En HA: Developer Tools → MQTT → Listen to a topic: sensor/temperatura_test
# Debería aparecer "21.5" inmediatamente.
```

### 4) Operación diaria

| Acción | Comando |
|---|---|
| Ver logs activos | `docker logs mosquitto -f` |
| Ver clientes conectados | `mosquitto_sub -h 127.0.0.1 -p 1883 -u admin -P "$ADM_PWD" -t '$SYS/broker/clients/connected' -C 1` |
| Mensajes/segundo (load) | `mosquitto_sub -h 127.0.0.1 -p 1883 -u admin -P "$ADM_PWD" -t '$SYS/broker/load/messages/received/1min' -C 1` |
| Subscribir a TODO (debug) | `mosquitto_sub -h 127.0.0.1 -p 1883 -u admin -P "$ADM_PWD" -t '#' -v` |
| Añadir un usuario | `docker exec mosquitto mosquitto_passwd -b /mosquitto/config/passwd <user> <password>` y editar `/mnt/hd2t/apps/mosquitto/config/acl` con sus reglas |
| Borrar un usuario | `docker exec mosquitto mosquitto_passwd -D /mosquitto/config/passwd <user>` |
| Recargar ACL/passwd sin reiniciar | `docker exec mosquitto kill -HUP 1` (Mosquitto recarga `password_file` y `acl_file` con SIGHUP) |
| Reiniciar broker | `docker compose -f stacks/mosquitto/docker-compose.yml restart mosquitto` |
| Tamaño de la BBDD persistente | `du -sh /mnt/hd2t/apps/mosquitto/data` |

### 5) Limpiar el `.env` post-bootstrap

Las contraseñas en `stacks/mosquitto/.env` ya no se necesitan (están en el `passwd` hasheado y en el gestor del operador). Para evitar que queden en el repo si por accidente se versiona:

```bash
shred -u stacks/mosquitto/.env
# Recrear vacío (compose lo busca, pero las variables no se usan).
cp stacks/mosquitto/.env.example stacks/mosquitto/.env
chmod 0600 stacks/mosquitto/.env
```

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/mosquitto/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/mosquitto/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/mosquitto/.env` | microSD | `homelab:homelab` | `0600` | **Vacío post-bootstrap.** No versionar. |
| `/home/homelab/homelab/stacks/mosquitto/mosquitto.conf` | microSD | `homelab:homelab` | `0644` | Configuración del broker. |
| `/home/homelab/homelab/stacks/mosquitto/acl` | microSD | `homelab:homelab` | `0644` | ACLs (sin secretos). |
| `/home/homelab/homelab/stacks/mosquitto/passwd.example` | microSD | `homelab:homelab` | `0644` | Plantilla de comentarios. **No** se versiona el real. |
| `/mnt/hd2t/apps/mosquitto/config/mosquitto.conf` | hd2t | `1883:1883` | `0644` | Config materializada. |
| `/mnt/hd2t/apps/mosquitto/config/passwd` | hd2t | `1883:1883` | `0640` | **Hashes de contraseñas**. Lectura solo para mosquitto. |
| `/mnt/hd2t/apps/mosquitto/config/acl` | hd2t | `1883:1883` | `0644` | ACLs activas. |
| `/mnt/hd2t/apps/mosquitto/data/` | hd2t | `1883:1883` | `0750` | Persistencia: mensajes `retain`, sesiones offline. |
| `/mnt/hd2t/apps/mosquitto/data/mosquitto.db` | hd2t | `1883:1883` | `0640` | BBDD de persistencia (formato propio binario). |
| `/mnt/hd2t/apps/mosquitto/log/` | hd2t | `1883:1883` | `0750` | Reservado (`log_dest stdout` activo, no se usa). |

> **Tamaño esperado**. Para una casa con ~50 dispositivos Zigbee + ~10 Tasmota/ESPHome + flujos de Node-RED, `mosquitto.db` se estabiliza en **5–20 MiB**. Es solo el estado *retained* por tópico (último mensaje conservado para cada uno) más sesiones de clientes con `clean_session=false`. Si crece a >100 MiB, hay un cliente publicando con `retain` en miles de tópicos: investigar con `mosquitto_sub -t '#' --retained-only`.

> **Por qué no microSD**. La persistencia hace flush cada 30 min (`autosave_interval`). En microSD es desgaste muy bajo, pero sigue siendo un argumento a favor de unificar todo en hd2t. Adicionalmente, perder la microSD no debería implicar perder estados retained — Borgmatic sobre hd2t cubre el caso.

> **Sobre `1883:1883`**. Único stack del homelab que no usa el UID/GID `1000:1000` (operador `homelab`). Razón: la imagen oficial define ese usuario hardcoded. El operador accede vía `setfacl` (lectura) o `sudo` (escritura), igual que con HA.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/mosquitto/docker-compose.yml`, `mosquitto.conf`, `acl`, `.env.example`, `passwd.example` | Versionados. |
| `stacks/mosquitto/.env` (real) | **Excluido** vía `.gitignore`. Vacío post-bootstrap, pero la plantilla recuerda formato. |
| Decisiones (eclipse-mosquitto:2.0, bridge + ports, sin TLS, ACLs por usuario) | Documentadas aquí. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Tier (`07-backups/01-estrategia-backup.md`) | Por qué |
|---|---|---|---|
| `/mnt/hd2t/apps/mosquitto/config/mosquitto.conf` | Sí. | T2 | Reproducible desde el repo, pero respaldarlo evita perder ediciones manuales (límites ajustados, listeners). |
| `/mnt/hd2t/apps/mosquitto/config/acl` | Sí. | T2 | Mismas razones que arriba; aún más, las ACLs son la **frontera de seguridad** del bus. |
| `/mnt/hd2t/apps/mosquitto/config/passwd` | Sí. | T1 (secretos). | **Crítico**: contiene los hashes de todas las contraseñas. Pérdida = regenerar todas las claves y reconfigurar HA, Z2M y Node-RED. |
| `/mnt/hd2t/apps/mosquitto/data/mosquitto.db` | Sí. | T2 | Estados `retain` y sesiones offline. **Sin esto** tras restore, las bombillas Zigbee aparecen "unknown" hasta su siguiente cambio (minutos a horas). Recuperable pero molesto. |
| `/mnt/hd2t/apps/mosquitto/log/*` | **No.** | T4 | Vacío hoy (logs van a stdout/Docker). |

Entrada en `borgmatic.yaml` (parche relativo al patrón de `07-backups/02-borgmatic.md`):

```yaml
source_directories:
  # ...
  - /mnt/hd2t/apps/mosquitto/config
  - /mnt/hd2t/apps/mosquitto/data

# Excluir log vacío
patterns:
  # ...
  - '!/mnt/hd2t/apps/mosquitto/log'
```

> **Política sobre `mosquitto.db`**. A diferencia de SQLite, Mosquitto **no** ofrece un `.backup` atómico desde CLI. La BBDD se actualiza en bloque cada `autosave_interval` (30 min) o al recibir SIGUSR1, con `fsync` antes y después. Copiar el fichero en caliente es *casi* seguro: el peor caso es restaurar al estado de hace 30 min, no corrupción. **Si se quiere consistencia perfecta**, hook `before_backup` en Borgmatic: `docker exec mosquitto kill -USR1 1` (fuerza autosave inmediato). El `kill -USR1` se queda como ejercicio, no se incluye por defecto porque la pérdida tolerable es bajísima.

> **Sobre el secreto en el backup**. `passwd` contiene **hashes**, no contraseñas. El hash es PBKDF2-SHA512 (algoritmo de Mosquitto 2.x), que tarda ~100 ms por intento en hardware moderno; con contraseñas de 32 caracteres, el coste de fuerza bruta es astronómico. Aun así, `passwd` cae en T1 con el resto de secretos cifrados de Borg.

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/mosquitto/docker-compose.yml up -d --force-recreate
# Mosquitto reusa /mnt/hd2t/apps/mosquitto/{config,data}: arranque normal en ~5s,
# todos los retains, ACLs y passwords siguen ahí.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear Fases 1 → 7 y `01-home-assistant.md`.
2. `borgmatic extract --archive latest --path mnt/hd2t/apps/mosquitto`.
3. Verificar permisos: `sudo chown -R 1883:1883 /mnt/hd2t/apps/mosquitto && sudo chmod 0640 /mnt/hd2t/apps/mosquitto/config/passwd`.
4. `docker compose -f stacks/mosquitto/docker-compose.yml up -d`.
5. Verificar conectividad de HA con `mosquitto_sub -t homeassistant/status -C 1`. Debería ver `online`.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| Cliente conecta y recibe `Connection Refused: not authorised` | (a) Usuario no existe en `passwd`. (b) Password incorrecto. (c) `allow_anonymous false` y el cliente no manda credenciales. | `docker logs mosquitto \| grep -i 'auth\|denied'`; verificar entrada en `/mnt/hd2t/apps/mosquitto/config/passwd`; regenerar password si hay duda. |
| HA muestra MQTT integration "Disconnected" en bucle | (a) Mosquitto caído. (b) Password de HA en `secrets.yaml` distinto al hasheado. (c) Firewall bloqueando `127.0.0.1:1883`. | `docker ps mosquitto` (debe ser healthy); `mosquitto_pub -u homeassistant -P <HA_PWD> -t test -m x` desde la Pi (debe publicar sin error); revisar logs de HA `Settings → System → Logs` filtrando "mqtt". |
| `docker logs mosquitto` repite `Client disconnected: send: Connection reset` | Cliente con `client_id` duplicado: dos instancias compitiendo, o un cliente que se reinicia antes de cerrar limpio. | Identificar `client_id` en logs; ajustar `client_id` único en cada cliente (en HA: `Settings → Devices & Services → MQTT → Configure → Advanced → Client ID`). |
| Z2M arranca pero todos los dispositivos quedan "unavailable" | Z2M conectó pero la ACL no le permite publicar `homeassistant/.../config` (Discovery). | Revisar `acl` — debe incluir `topic write homeassistant/+/+/config` y `homeassistant/+/+/+/config` para `zigbee2mqtt`. `docker exec mosquitto kill -HUP 1` para recargar. |
| Cambios en `acl` o `passwd` no surten efecto | Mosquitto carga estos ficheros al arrancar; SIGHUP los recarga. | `docker exec mosquitto kill -HUP 1`. Verificar en logs: `Reloading config`. Si no, `docker compose restart mosquitto`. |
| Logs muestran `Saving in-memory database to /mosquitto/data/mosquitto.db` y luego `Permission denied` | Owner del bind mount no es 1883:1883. Suele pasar si se ha hecho `chown homelab:homelab` por error. | `sudo chown -R 1883:1883 /mnt/hd2t/apps/mosquitto`. Reiniciar. |
| Cliente externo (móvil con MQTT Dash, ESPHome) recibe `Connection refused: 5 (not authorized)` aunque las credenciales son correctas | (a) ACL bloquea su `client_id` o tópico inicial. (b) IP del cliente no encaja con regla `pattern` (no se usa aquí, pero comprobar). | Probar primero como `admin` (ACL `#`); si funciona, restringir el ACL del usuario real correctamente. |
| El healthcheck del contenedor falla pero los clientes conectan | `mosquitto_sub` interno usa `admin` con un secret que el script no encuentra. | Aceptable: el fallback del healthcheck devuelve OK al ver "not authorised" del broker. Si persiste, revisar la línea `test:` del compose. |
| `docker logs mosquitto` muestra `Unable to load CA certificates` | Ha aparecido tras intentar habilitar TLS sin haber generado certs. | TLS está fuera del alcance de este doc. Eliminar el `listener 8883` y los `cafile`/`certfile`/`keyfile` de `mosquitto.conf`, reiniciar. |
| WebSocket en `:9001` no responde | Cliente JS espera `wss://` (TLS) pero el listener es `ws://`. | Verificar la URL del cliente: debe ser `ws://192.168.1.10:9001`. Para `wss://` haría falta TLS (no contemplado). |
| Llegan mensajes desde un IP de la WAN | Misconfig en el firewall: `1883/tcp` no debería ser alcanzable desde fuera de LAN+tailnet. | Revisar `01-sistema/03-seguridad-base.md`: `nft list ruleset \| grep 1883`. La regla debe limitar source. |
| Tras `docker compose pull` (Watchtower), Mosquitto sube de minor (2.0 → 2.1) | Watchtower está respetando un tag móvil; el pin debería evitarlo. | Confirmar `image: eclipse-mosquitto:2.0` (no `:latest` ni `:2`); Watchtower solo actualiza dentro de la rama 2.0.x. Si saltó de 2.0 a 2.1, fue acción manual o config errónea. |

---

## Decisiones que **no** se toman en este documento

- **TLS sobre 8883**: ver decisión arriba. Reabrible si se compran dispositivos LAN con requerimiento de cifrado.
- **Bridges entre brokers**: `connection` directives para federar dos Mosquittos (clúster activo-pasivo, o pasarela hacia otro broker en un tercer sitio). El homelab tiene un solo nodo; nada que federar.
- **Plugins externos** (`mosquitto-go-auth` para integrar Authelia, mosquitto-jwt-auth para tokens): cada uno añade superficie de ataque y dependencias. La auth nativa de Mosquitto (passwd + ACL) es **suficiente** y bien probada.
- **MQTT 5.0 features avanzadas** (request/response, shared subscriptions, properties): Mosquitto 2.0 las soporta, pero el resto del homelab (HA, Z2M, ESPHome, Tasmota) usa MQTT 3.1.1 mayoritariamente. No se desactivan; simplemente no se confía en ellas en la lógica del homelab.
- **Topic redaction en logs** (no loguear payloads de tópicos sensibles): Mosquitto no loguea payloads, solo metadatos (CONNECT, SUB, PUB-event), así que no aplica. Si se activase logging de payloads (no recomendado), habría que filtrar.
- **`mqtt-exporter` para Prometheus**: el usuario `monitor` queda creado; el contenedor `mqtt-exporter` se desplegará en una iteración futura de `05-monitorizacion/`. No se incluye en Fase 8.
- **Admin UI gráfica para MQTT** (MQTT Explorer, mqttx, EMQX dashboard): son clientes de escritorio o aplicaciones web independientes. El operador puede usar **MQTT Explorer** desde su laptop apuntando a `192.168.1.10:1883` con `admin`. Es una herramienta local, no un servicio del homelab.
- **Authelia delante de Mosquitto**: MQTT no es HTTP. Authelia no aplica.
- **Caddy reverse-proxy de Mosquitto**: MQTT en `:1883` es TCP plano; Caddy podría proxar TCP (`layer4` plugin), pero no aporta nada (no hay TLS termination útil sin certs cliente, y el firewall ya hace el aislamiento). Descartado.

---

## Verificación Final

Antes de pasar a `03-zigbee2mqtt.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/mosquitto/docker-compose.yml ps` | `mosquitto ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect mosquitto --format '{{.Config.Image}}'` | `eclipse-mosquitto:2.0` |
| Mosquitto en bridge `homelab` | `docker inspect mosquitto --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}'` | `homelab` |
| Puertos publicados | `ss -tlnp \| grep -E ':(1883\|9001) '` | dos líneas, una por puerto |
| Anonymous rechazado | `mosquitto_pub -h 127.0.0.1 -p 1883 -t test -m x; echo "exit=$?"` | `Connection error: Connection Refused: not authorised.` y `exit=14` |
| Auth válida funciona | `mosquitto_pub -h 127.0.0.1 -p 1883 -u admin -P "$ADM_PWD" -t test -m x; echo "exit=$?"` | `exit=0`, sin error en stderr |
| ACL para zigbee2mqtt aplica | `mosquitto_pub -u zigbee2mqtt -P "$Z2M_PWD" -t fuera -m x` luego `docker logs mosquitto --tail 5 \| grep -i denied` | una línea `Denied PUBLISH from zigbee2mqtt` |
| Recarga de config con SIGHUP | `docker exec mosquitto kill -HUP 1; docker logs mosquitto --tail 3` | línea con `Reloading config` |
| Persistencia escribe a disco | `sudo ls -l /mnt/hd2t/apps/mosquitto/data/` | `mosquitto.db` con tamaño > 0 (tras autosave o reinicio) |
| Owner correcto del bind mount | `sudo stat -c '%u:%g' /mnt/hd2t/apps/mosquitto/config` | `1883:1883` |
| `passwd` con permisos restrictivos | `sudo stat -c '%a' /mnt/hd2t/apps/mosquitto/config/passwd` | `640` |
| 5 usuarios en `passwd` | `sudo wc -l /mnt/hd2t/apps/mosquitto/config/passwd` | `5 ...` |
| HA conectado (integración MQTT en verde) | UI: `Settings → Devices & Services → MQTT` | "Connected" / 1 device (el broker) |
| HA puede publicar | UI: Developer Tools → Services → `mqtt.publish` (topic `test/echo`, payload `hi`) y `mosquitto_sub -u admin ...` desde la Pi | mensaje `hi` recibido |
| `secrets.yaml` de HA tiene `mqtt_password` real | `sudo grep '^mqtt_password' /mnt/hd2t/apps/home-assistant/config/secrets.yaml` | línea con valor (no comentada, no `<...>`) |
| `.env` de Mosquitto vaciado post-bootstrap | `cat stacks/mosquitto/.env` | sin contraseñas en claro (placeholders `changeme`) |
| Watchtower etiqueta presente | `docker inspect mosquitto --format '{{index .Config.Labels "com.centurylinklabs.watchtower.enable"}}'` | `true` |

---

## Referencias

- Documentación oficial Eclipse Mosquitto — https://mosquitto.org/documentation/
- `mosquitto.conf(5)` — https://mosquitto.org/man/mosquitto-conf-5.html
- `mosquitto_passwd(1)` — https://mosquitto.org/man/mosquitto_passwd-1.html
- ACL files reference — https://mosquitto.org/documentation/dynamic-security/ (sección "Access Control")
- Imagen Docker oficial — https://hub.docker.com/_/eclipse-mosquitto
- MQTT 3.1.1 / 5.0 protocol spec — https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html
- Home Assistant — MQTT integration — https://www.home-assistant.io/integrations/mqtt/
- Home Assistant — MQTT Discovery — https://www.home-assistant.io/integrations/mqtt/#mqtt-discovery
- `$SYS/` topics — https://github.com/mqtt/mqtt.org/wiki/SYS-Topics
- Documentos hermanos: `01-home-assistant.md`, `03-zigbee2mqtt.md`, `04-node-red.md`.
