# Home Assistant

## Descripción

Cerradas las fases 0–7, el homelab funciona como **plataforma genérica**: hay sistema operativo, Docker, red local resuelta por Pi-hole, reverse proxy con TLS interno (Caddy), VPN mesh (Tailscale), SSO (Authelia), monitorización (Prometheus + Grafana), almacenamiento personal (Nextcloud + Samba + Syncthing + MinIO) y copias de seguridad (Borgmatic). Hasta aquí, sin embargo, el homelab no **hace** nada por sí solo: cada interruptor de la casa sigue siendo manual, cada sensor de temperatura pertenece a una app distinta del fabricante, y "encender la luz cuando llego a casa" requiere abrir tres apps en orden.

La **Fase 8 — Domótica e IoT** introduce el cerebro: Home Assistant, Mosquitto MQTT, Zigbee2MQTT y Node-RED. Este primer documento despliega **Home Assistant** (en adelante, HA), el orquestador. Su rol concreto:

1. **Centralizar el estado de la casa**: cada bombilla, sensor, enchufe, persiana, termostato, frigorífico inteligente o cámara queda representado como una entidad (`light.salon`, `sensor.temperatura_habitacion_ana`, `binary_sensor.puerta_entrada`) sobre la que se puede consultar estado, lanzar servicios y construir automatizaciones.
2. **Hablar todos los protocolos**: HA tiene integraciones nativas para Zigbee (vía Zigbee2MQTT, `03-zigbee2mqtt.md`), MQTT (vía Mosquitto, `02-mosquitto.md`), HomeKit, Chromecast, ESPHome, Z-Wave (futuro), Tasmota, Shelly, IKEA Tradfri, Philips Hue, y unas 2.000 integraciones más mantenidas por la comunidad. Para el homelab basta con MQTT + Zigbee + WiFi + Cast, todo cubierto desde el día uno.
3. **Servir como UI principal de domótica**: dashboards (Lovelace) para el día a día — un panel para cada habitación, un dashboard de "control central" en una tablet, una vista de mapa con personas, etc.
4. **Automatizar**: la lógica de "si pasa X, haz Y" se escribe en YAML o en el editor visual. Para flujos visuales más complejos, `04-node-red.md` añade Node-RED conectado por la API WebSocket de HA — pero las automatizaciones simples (rutinas de mañana, alertas de puerta abierta, escenas) viven en HA directamente.
5. **Exponer eventos al resto del homelab**: HA publica eventos en MQTT y vía API REST/WebSocket. Esto permite, por ejemplo, que un sensor de movimiento dispare la pausa de Jellyfin, que la temperatura de los CPUs (Node Exporter → Prometheus → HA via integración) aparezca en un dashboard de domótica, o que Node-RED orqueste flujos atravesando varios servicios.

Lo que este documento **no** decide:

- **Mosquitto** (broker MQTT) y **Zigbee2MQTT**: son documentos hermanos (`02-mosquitto.md`, `03-zigbee2mqtt.md`). HA arranca *sin* MQTT configurado; cuando Mosquitto entre, se añade la integración MQTT desde la UI. La configuración de HA aquí deja preparado todo lo necesario (carpeta `secrets.yaml`, recorder con un tamaño razonable, hooks de reverse proxy) para que esos documentos solo necesiten **añadir integraciones**, no reescribir el setup base.
- **Node-RED**: documento `04-node-red.md`. HA expone su API WebSocket en `/api/websocket`; Node-RED se conecta como cliente con un token de larga duración. Aquí solo se garantiza que la API WebSocket está disponible y que Caddy no la rompe.
- **Integraciones específicas con dispositivos físicos**: HomeKit Bridge, Chromecast, ESPHome, Shelly, Tasmota… cada operador tiene un parque de dispositivos distinto. Este documento solo deja el contenedor desplegado y la UI accesible; las integraciones se añaden desde `Settings → Devices & Services → Add Integration` cuando los dispositivos físicos existan.
- **Companion App** (Android/iOS): la app oficial de HA es la única vía sostenible para localización y notificaciones móviles. Configurarla es un paso de cliente, no de servidor; se cubre en el bloque de "Configuración" sin entrar en detalle del onboarding del móvil.
- **Add-ons**: el ecosistema de "Add-ons" (Mosquitto add-on, ESPHome add-on, Node-RED add-on, etc.) **solo existe en HAOS y Supervised**, no en Home Assistant Container. Este documento despliega HA Container deliberadamente (ver decisión abajo); cada add-on se reemplaza por un contenedor Docker separado en su propio stack. Esto es **mejor**, no peor, en este homelab: cada componente vive en su `docker-compose.yml`, se respalda por separado y se actualiza con la misma cadencia que el resto.
- **Autenticación con Authelia**: ver decisión específica abajo. **HA usa su propia autenticación con TOTP** y no se mete detrás del `forward_auth` de Authelia.

Cuando este documento se haya aplicado, el operador puede:

- Abrir `https://home.${DOMAIN_LAN}/` desde la LAN (con CA interna instalada) o desde el tailnet (con `tailscale cert`) y completar el onboarding inicial.
- Crear el usuario admin, activar **2FA con TOTP**, y restringir el acceso anónimo.
- Ver la UI de HA cargando sin warnings de "trusted_proxies", "url is not configured" ni problemas de WebSocket.
- Confirmar que los datos persistentes están en `/mnt/hd2t/apps/home-assistant/config` y que un `docker compose down && up -d` no pierde nada.
- Tener la base lista para que `02-mosquitto.md` y `03-zigbee2mqtt.md` añadan integraciones encima sin tocar este stack.

> **Recordatorio de alcance**: HA es **solo LAN + tailnet**. La Companion App se conecta vía Tailscale cuando el móvil está fuera de casa; nada de DDNS, ni Nabu Casa Cloud, ni puertos abiertos en el router. Las notificaciones push **sí** pasan por los servidores de Nabu Casa (es la única vía soportada para FCM/APNs sin pagar), pero el tráfico de control y datos del usuario nunca sale del tailnet.

---

## Requisitos Previos

- **Fase 1** completa (sistema base, hostname `pi5`, zona horaria, locale, swap en hd2t).
- **Fase 2** completa (Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID=1000`, `PGID=1000`, `DOMAIN_LAN=lan`).
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre `home.${DOMAIN_LAN}` automáticamente).
  - Caddy desplegado y los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` en `Caddyfile`.
  - Tailscale operativo (para acceso remoto a HA desde el móvil con la Companion App).
- **Fase 4** completa: aunque HA **no** se mete detrás de Authelia, los snippets `(lan_only)` existen y se reutilizan en una variante alternativa documentada al final.
- Disco `hd2t` montado en `/mnt/hd2t` con al menos **5 GiB** libres reservados para HA (`config`, `media` reducido, base de datos `home-assistant_v2.db` de SQLite que crece ~50–500 MiB tras meses según número de entidades).
- Operador con la **CA interna instalada** en su navegador y, si va a usar la Companion App, en su móvil (Android: certificado de usuario; iOS: perfil de configuración).

Comprobaciones rápidas:

```bash
# La red Docker compartida existe y Caddy está sano
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok
docker ps --filter name=caddy --format '{{.Names}} {{.Status}}'
# caddy   Up 5 days (healthy)

# home.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short home.lan @192.168.1.2
# 192.168.1.10

# Espacio en hd2t
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'
# 1.5T libres

# Hora del host (HA es muy sensible a esto: timestamps de sensores, automatizaciones cron, recorder)
timedatectl | grep -E 'Time zone|System clock'
# Time zone: Europe/Madrid (CET, +0100)
# System clock synchronized: yes
```

> **Sobre la hora**: HA registra todos los eventos con timestamp del host. Si `chrony` o `systemd-timesyncd` no está sincronizado, el dashboard muestra "5 minutos sin actualizarse" en sensores que sí están vivos. La Fase 1 ya deja `systemd-timesyncd` activo; este documento da por hecho que la hora es correcta.

---

## Decisión: variante de Home Assistant

Home Assistant se distribuye en **cuatro variantes** oficiales:

| Variante | Qué es | Cuándo se elige | Decisión aquí |
|---|---|---|---|
| **Home Assistant OS (HAOS)** | Sistema operativo dedicado basado en Buildroot. Ejecuta HA Supervisor + HA Core + add-ons como contenedores. Quien instala HAOS *no* tiene un Linux genérico; HAOS se "adueña" del hardware. | Pi dedicada solo a domótica. | **Descartado**: la Pi 5 ya es Raspberry Pi OS Lite con Docker, Pi-hole, Caddy, Jellyfin, etc. Sustituir el OS borraría todo el homelab. |
| **Home Assistant Supervised** | HA Supervisor + Core + add-ons sobre Debian estándar. Requiere Debian *exacto* (no Raspberry Pi OS), ciertos paquetes específicos, NetworkManager (no `dhcpcd`), y el "Supervisor" gestiona el ciclo de vida de Docker en la máquina. | Operador que quiere add-ons sobre un OS general. | **Descartado**: requisitos de OS demasiado rígidos, choca con Pi-hole en macvlan, con Docker Compose convencional, y con `unattended-upgrades`. La política oficial es "no soportada en Raspberry Pi OS". |
| **Home Assistant Container** | Una imagen Docker (`ghcr.io/home-assistant/home-assistant`) sin Supervisor ni add-ons. Multi-arch (amd64, arm64, armv7). | Operadores que ya tienen su Docker Engine con otros servicios y quieren HA como uno más. | **Aceptado**: encaja con la convención `stacks/<svc>/` del homelab. |
| **Home Assistant Core** | HA como paquete Python directamente sobre el host. | Casos extremadamente puntuales (desarrollo, Pi sin Docker). | Descartado: el homelab estandariza Docker. |

Pérdida real de elegir Container sobre HAOS:

- **No hay Add-ons Store**: cada add-on (Mosquitto, ESPHome, Node-RED, Zigbee2MQTT, AppDaemon...) se despliega como contenedor Docker independiente. **Esto es mejor en este homelab**: cada componente tiene su `stacks/<svc>/`, su `.env`, su backup explícito, y se actualiza con la misma cadencia y herramienta (Watchtower) que el resto.
- **No hay Supervisor**: no hay healthcheck transversal "todo va bien" ni snapshots integrales. Lo cubre **Borgmatic** (`07-backups/02-borgmatic.md`) sobre `/mnt/hd2t/apps/home-assistant/config` con hook `pre`/`post` para ejecutar `homeassistant.stop` si se quiere snapshot consistente (ver "Backup").
- **No hay UI de actualización en Settings → Updates**: actualizar HA es `docker compose pull && up -d`. Watchtower lo automatiza si la imagen tiene la etiqueta `homelab.role: "automation-hub"` y `com.centurylinklabs.watchtower.enable: "true"`.

> **Tag exacto en uso**: `ghcr.io/home-assistant/home-assistant:2024.10`. Política: pin a la rama mensual (`YYYY.MM`), no a `stable` ni `latest`. HA publica una versión mensual el primer miércoles del mes; es estable en el sentido de "ya pasó RC", pero `latest` puede saltar de `2024.10` a `2024.11` con cambios disruptivos (deprecación de integraciones, nuevos requisitos en `configuration.yaml`). Subir de minor es **deliberado**: el operador lee los release notes, hace backup de `/mnt/hd2t/apps/home-assistant/config`, cambia el tag aquí, `docker compose up -d` y verifica.

> **Por qué no `stable`**: el tag `stable` se mueve continuamente; equivale a `latest`. La Watchtower se respeta solo dentro del **mismo** tag mensual (parches `2024.10.x`).

---

## Decisión: networking — `host` vs `homelab` bridge vs macvlan

HA es un caso especial de networking en Docker. Los protocolos que necesita para descubrir dispositivos viajan por **multicast/broadcast en la LAN**, no por TCP unicast:

| Protocolo | Para qué | Necesita |
|---|---|---|
| mDNS (`224.0.0.251:5353`) | Descubrir Chromecast, AirPlay, HomeKit, ESPHome, Shelly, Sonos, impresoras… | La pila de red del host (multicast no atraviesa el bridge Docker por defecto). |
| SSDP/UPnP (`239.255.255.250:1900`) | Descubrir Smart TVs, routers UPnP, dispositivos DLNA. | Idem. |
| HomeKit (mDNS + bonjour) | Exponer HA como bridge HomeKit. | Idem. |
| Tradfri/IKEA gateway, Philips Hue (mDNS) | Descubrimiento. | Idem. |

Opciones para el homelab:

| Opción | Cómo se ve | Discusión | Veredicto |
|---|---|---|---|
| **Bridge `homelab` (sin `ports:`)** | HA en `172.30.10.X`, accesible solo dentro del bridge. Caddy hace `reverse_proxy http://homeassistant:8123`. | Limpio; encaja con todo lo anterior. **Pero**: pierde mDNS, SSDP, HomeKit, descubrimiento automático. Hay que añadir cada dispositivo manualmente por IP. Tolerable si el parque de dispositivos es 100% Zigbee + MQTT (que ya pasa por Mosquitto y no necesita mDNS). | Aceptable solo si el operador renuncia explícitamente a integraciones de descubrimiento. |
| **`network_mode: host`** | HA comparte la pila de red de la Pi: `:8123` queda en `192.168.1.10:8123`. mDNS, SSDP, HomeKit funcionan nativamente. | Rompe la convención del bridge: HA *no* puede ser referenciado por nombre `homeassistant` desde otros contenedores; tienen que ir a `http://host.docker.internal:8123` (con `extra_hosts: host-gateway`) o a `192.168.1.10:8123`. Caddy igual: `reverse_proxy http://host.docker.internal:8123`. | **Aceptado**: la pérdida es estilística (un caso especial documentado en una línea), la ganancia es funcional (todo el catálogo de integraciones de HA disponible). |
| **Macvlan dedicada** | HA con su propia IP en la LAN (`192.168.1.5`, p. ej.). | Funciona como `host` para multicast pero suma una IP más al plan de DNS local, complica el `Caddyfile` y exige reservar un rango de IPs en el router. Sobreingeniería para un solo servicio. | Descartado. |

Resultado: **`network_mode: host`**. Implicaciones:

1. **No `ports:`** en el `docker-compose.yml` (sería redundante y daría error: ya está en `:8123` del host).
2. **Caddy** llega a HA con `reverse_proxy http://host.docker.internal:8123` y `extra_hosts: ["host.docker.internal:host-gateway"]`. Esto funciona porque Caddy ejecuta en el bridge `homelab` con NAT contra el host.
3. **Otros contenedores** (Node-RED, Mosquitto, Zigbee2MQTT) que necesiten hablar con la API de HA **también** la encuentran en `host.docker.internal:8123` desde el bridge. Su documento respectivo lo refleja.
4. **Firewall** del host (`ufw`/`nftables` de `01-sistema/03-seguridad-base.md`): `:8123/tcp` queda accesible **solo desde la LAN** (`192.168.1.0/24`) y desde la interfaz `tailscale0` (`100.64.0.0/10`). El acceso externo se hace **por Caddy** (`https://home.lan`), no atacando directamente al `:8123`.
5. **Watchtower**: HA en host networking sigue siendo un contenedor Docker normal; Watchtower lo actualiza igual.

> **Sobre `host.docker.internal`**: en Docker Engine para Linux ≥ 20.10, esta entrada se resuelve añadiendo `extra_hosts: ["host.docker.internal:host-gateway"]` al servicio que la consume. No es un truco macOS-only; está soportado oficialmente. La alternativa "dirígete a `172.17.0.1`" es frágil (cambia entre versiones de Docker y entre redes).

---

## Decisión: base de datos del recorder

HA usa el componente **Recorder** para guardar histórico de estados, eventos y estadísticas. Por defecto: SQLite en `home-assistant_v2.db`. Alternativas:

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| **SQLite (default)** | Cero dependencias, archivo único en `/config`, fácil de respaldar. Para ~100 entidades y 10 días de histórico, la BBDD pesa <500 MiB. | Concurrencia limitada: queries pesadas (estadísticas mensuales) bloquean escrituras puntualmente. Aceptable. | **Aceptado** para Fase 8. |
| **MariaDB externa** | Mejor concurrencia, posibilidad de queries SQL externas (Grafana). | Otro contenedor que mantener, otra BBDD que respaldar, más superficie de fallo. | Reabrible si se pasa a >500 entidades o se quiere correlacionar HA con Prometheus en Grafana de manera intensiva. |
| **PostgreSQL externa** | Igual que MariaDB. | Idem. | Reabrible. |
| **InfluxDB** | Diseñada para time-series; muchos dashboards de Grafana parten de ella. | HA sigue necesitando un Recorder; InfluxDB sería *additional*, no *replacement*. Doble escritura. | Reabrible si en algún momento se tira de Grafana para domótica. Por ahora, los dashboards viven dentro de HA con Lovelace. |

Configuración del Recorder en `configuration.yaml` (decisiones aplicadas):

- `purge_keep_days: 10` — el histórico de HA tiene **el mismo principio** que la TSDB de Prometheus (`05-monitorizacion/01-prometheus.md`): valor decreciente con el tiempo. 10 días cubre patrones semanales sin hinchar la BBDD.
- `auto_purge: true` (default) y `auto_repack: true` — limpia y compacta automáticamente cada noche a las 04:12 UTC.
- `commit_interval: 5` — escribe en disco cada 5 segundos en lote (default: 1 s). Reduce IOPS sobre `hd2t` sin penalizar visiblemente la responsividad de la UI.
- Listas `exclude:` para entidades ruidosas (ver `configuration.yaml` abajo): `sensor.time`, `sensor.date`, `sensor.last_boot`, etc., no aportan histórico útil pero generan miles de filas/día.

---

## Decisión: dónde viven los datos y permisos

HA Container ejecuta como **`root`** dentro del contenedor por diseño (necesita acceso al socket Bluetooth, a `/dev/tty*` para integraciones serie, y a paths que la Pi expone con UID 0). Esto es consistente con HA Container/HAOS oficial. Implicaciones:

- El bind mount `/mnt/hd2t/apps/home-assistant/config` queda con owner `root:root`, modo `0750`. Solo `root` y miembros del grupo `homelab` (vía `setfacl` opcional) pueden leerlo.
- Los **secretos** (`secrets.yaml`) heredan modo `0600` en el contenedor (HA fuerza esto al primer arranque).
- El usuario operador (`homelab`) tiene permiso de lectura vía `sudo` o `setfacl -m u:homelab:rx`. Para edición de YAML manual se usa `sudo -e`.

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| Volumen Docker nombrado | Menos pelea con permisos. | TSDB+config en `/var/lib/docker/volumes/...` (microSD): inaceptable. | Descartado. |
| Bind mount con `--user $(PUID):$(PGID)` (1000:1000) | Owner legible, integra con `homelab`. | Rompe integraciones que asumen root (Bluetooth, USB). | Descartado. |
| **Bind mount, owner `root:root`** | Compatible con todo el ecosistema HA, alineado con la imagen oficial. | Operador necesita `sudo` para editar YAML. | **Aceptado**. |

Resultado: bind mount en `/mnt/hd2t/apps/home-assistant/config`, owner `root:root`, modo `0750`. Edición de YAML con `sudo -e` o desde el File Editor de HA (que se ejecuta en el mismo contenedor con los mismos permisos).

---

## Decisión: autenticación — HA nativa, **no** Authelia

HA tiene su propio sistema de autenticación con soporte para **TOTP (2FA)**, **WebAuthn** (FIDO2) y **trusted networks**. Meterlo detrás del `forward_auth` de Authelia es técnicamente posible **pero contraindicado**:

| Razón | Impacto |
|---|---|
| **Companion App** (Android/iOS) | La app oficial usa long-lived access tokens contra `/auth/token` y `/api/websocket`. Authelia interrumpiría el handshake; aunque se exonere `/api/*` y `/auth/*`, se rompe la lógica de redirect-to-login del navegador. |
| **Webhooks externos** | Cámaras IP, ESPHome, Tasmota llaman a `https://home.lan/api/webhook/<id>`. Authelia bloquea cualquier petición sin cookie. Tendría que exonerarse `/api/webhook/*`, lo que acaba dejando media API abierta. |
| **API WebSocket de Node-RED** | `04-node-red.md` se conecta a `/api/websocket` con un long-lived token. Authelia rompería la conexión si no se exonera ese path. |
| **Discovery de iOS/Android** | Las apps usan mDNS y tocan `/manifest.json`, `/service_worker.js`, `/static/*`. Cada una habría que exonerarla. |

Cada exoneración deja agujeros y hace inestable el sistema. La política sana en este homelab es: **HA gestiona su propia autenticación**, con TOTP obligatorio para todos los usuarios y una política de contraseñas fuerte. El `Caddyfile` para HA importa **solo** `lan_tls`, `security_headers` y `healthcheck`; **no** `authelia_two_factor`.

Compensaciones:

- HA **no** sale de la LAN/tailnet (igual que el resto del homelab). Quien quiera atacar la página de login necesita ya estar dentro.
- El log de accesos (`http: log: true`) deja trazabilidad de quién entra.
- `fail2ban` puede añadir un jail específico para HA si se ven ataques de fuerza bruta sobre el endpoint `/auth/login_flow` (reabrible, no incluido por defecto).

> **Si un día se quiere SSO real**: la integración soportada es **OAuth2/OpenID Connect** vía el [HACS plugin `hass-auth-header`](https://github.com/BeryJu/hass-auth-header) o un OIDC provider externo. Authelia hace de OIDC provider desde 4.38; reabrible cuando se decida invertir el esfuerzo.

---

## Stack: `stacks/home-assistant/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/home-assistant/docker-compose.yml` | microSD (git) | Stack (servicio `homeassistant`). |
| `stacks/home-assistant/.env.example` | microSD (git) | Plantilla con `HA_*` (vacío en esta fase). |
| `stacks/home-assistant/configuration.yaml.skel` | microSD (git) | Esqueleto de `configuration.yaml` con decisiones aplicadas (recorder, http, trusted_proxies). |
| `stacks/home-assistant/secrets.yaml.example` | microSD (git) | Plantilla de `secrets.yaml`. **No** versionar el real. |
| `stacks/caddy/conf.d/08-home-assistant.caddy` | microSD (git) | Drop-in del bloque LAN para `home.${DOMAIN_LAN}`. |
| `/mnt/hd2t/apps/home-assistant/config/` | hd2t | Configuración materializada y BBDD del recorder. Owner `root:root`. |
| `/mnt/hd2t/apps/home-assistant/config/configuration.yaml` | hd2t | Configuración principal. |
| `/mnt/hd2t/apps/home-assistant/config/secrets.yaml` | hd2t | Secretos (`!secret <key>`). Modo `0600`. |
| `/mnt/hd2t/apps/home-assistant/config/.storage/` | hd2t | Estado interno (usuarios, integraciones, dashboards). HA lo gestiona. **No tocar a mano.** |
| `/mnt/hd2t/apps/home-assistant/config/home-assistant_v2.db` | hd2t | SQLite del Recorder. |
| `/mnt/hd2t/apps/home-assistant/config/home-assistant.log` | hd2t | Log activo (rotado por HA). |
| `/mnt/hd2t/apps/home-assistant/media/` | hd2t | Carpeta `media/` opcional para snapshots de cámaras, TTS, descargas. |

### `stacks/home-assistant/docker-compose.yml`

```yaml
# Home Assistant — orquestador de domótica del homelab.
# Documentado en docs/08-domotica/01-home-assistant.md.
#
# Networking: network_mode: host (necesario para mDNS, SSDP, HomeKit).
# Caddy llega vía host.docker.internal:8123.

name: home-assistant

services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:2024.10
    container_name: homeassistant
    hostname: homeassistant
    restart: unless-stopped

    # Imprescindible para descubrimiento mDNS/SSDP/HomeKit.
    # No se usa la red `homelab`: HA está directamente en la pila del host.
    network_mode: host

    privileged: true
    # Justificación de privileged:
    #   - Bluetooth: HA habla con BLE para integraciones (Xiaomi, Govee).
    #     Requiere acceso a /dev/hci* y al stack Bluetooth del host.
    #   - USB serie: Z-Wave (Aeotec, Zooz) y Zigbee de respaldo si Z2M no se usa.
    # Si en el homelab no se usa BLE NI USB, se puede bajar a:
    #   privileged: false
    #   cap_add: [NET_ADMIN, NET_RAW]   # solo para mDNS/SSDP

    environment:
      TZ: ${TZ}
      # PUID/PGID NO se aplican: la imagen oficial de HA corre como root por diseño.

    volumes:
      - /mnt/hd2t/apps/home-assistant/config:/config
      - /mnt/hd2t/apps/home-assistant/media:/media
      # Sincronizar la hora del contenedor con la del host de forma robusta.
      - /etc/localtime:/etc/localtime:ro
      # Acceso a D-Bus del host para integraciones que usan systemd-resolved
      # o avahi (HomeKit Bridge):
      - /run/dbus:/run/dbus:ro

    # Si se usa un stick Zigbee local enchufado a la Pi (raro: lo normal es
    # delegar en Zigbee2MQTT), descomentar y ajustar:
    # devices:
    #   - /dev/ttyUSB0:/dev/ttyUSB0
    #   - /dev/ttyACM0:/dev/ttyACM0

    healthcheck:
      # /api/ devuelve 401 sin token, pero responde y eso ya valida que la app
      # arrancó. El endpoint /manifest.json responde 200 público.
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:8123/manifest.json"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 90s   # primer arranque: HA crea .storage, migrar BBDD, ~60s

    labels:
      homelab.role: "automation-hub"
      homelab.backup: "true"
      # Watchtower SOLO actualiza dentro del mismo tag mensual (2024.10.x).
      # El bump de minor (2024.10 -> 2024.11) es manual: leer release notes.
      com.centurylinklabs.watchtower.enable: "true"
```

> **Sobre `network_mode: host`**: el contenedor *no* aparece en `docker network inspect homelab` (no está en bridge alguno). Se ve con `ss -tlnp | grep 8123` desde el host. Caddy, en `homelab`, llega vía `host.docker.internal`.

> **Sobre `privileged: true`**: es la opción cómoda pero excesiva si no hay BLE ni USB. Para una Pi 5 con Zigbee delegado en Zigbee2MQTT (otro contenedor) y sin BLE, se puede sustituir por `cap_add: [NET_ADMIN, NET_RAW]`. La decisión por defecto es `privileged: true` porque la mayoría de operadores acaban añadiendo BLE en algún momento; restringir capabilities prematuramente cuesta más en troubleshooting que lo que aporta en hardening.

> **Sobre `/etc/localtime`**: HA respeta `TZ`, pero el log usa `localtime` cuando integraciones de terceros leen `time.localtime()`. Montarlo `:ro` evita inconsistencias.

> **Sobre `/run/dbus`**: solo necesario para HomeKit Bridge y otras integraciones que hablan con `systemd-resolved`/`avahi-daemon` del host. Si no se usa HomeKit, se puede omitir.

### `stacks/home-assistant/.env.example`

```bash
# stacks/home-assistant/.env.example
# Variables específicas del stack Home Assistant. Las generales (TZ)
# vienen del .env GLOBAL del homelab.
#
# (Vacío en esta fase: HA se configura desde la UI; los secretos viven
# en /mnt/hd2t/apps/home-assistant/config/secrets.yaml, no aquí.)
```

### `stacks/home-assistant/configuration.yaml.skel`

Esqueleto inicial. HA lo respeta en el primer arranque y no lo sobreescribe; las modificaciones de la UI viven en `.storage/` aparte.

```yaml
# /config/configuration.yaml — Home Assistant.
# Documentado en docs/08-domotica/01-home-assistant.md.

# Frontend y onboarding por defecto. No tocar a no ser que se sepa lo que
# se hace; el orden default_config -> http -> recorder es importante.
default_config:

# ----------------------------------------------------------------------
# HTTP: indica a HA que está detrás de un reverse proxy (Caddy).
# Sin esto, HA detectaría la IP del proxy como IP del cliente y se
# rompería el rate-limit de login y los cookies.
# ----------------------------------------------------------------------
http:
  # use_x_forwarded_for: necesario para que HA respete X-Forwarded-For.
  use_x_forwarded_for: true
  trusted_proxies:
    # Caddy vive en homelab (172.30.10.0/24). Como HA usa network_mode: host,
    # las requests llegan desde el bridge, NAT-eadas al host. La IP origen
    # vista por HA será la del bridge (172.30.10.1) o el rango entero. Se
    # confía el rango completo del bridge homelab.
    - 172.30.10.0/24
    # Loopback local (peticiones desde el propio host, p.ej. healthcheck).
    - 127.0.0.1
    - ::1
  # ip_ban: protege el endpoint /auth/* tras N intentos fallidos.
  ip_ban_enabled: true
  login_attempts_threshold: 5

# ----------------------------------------------------------------------
# Recorder: histórico de estados y eventos.
# ----------------------------------------------------------------------
recorder:
  purge_keep_days: 10
  auto_purge: true
  auto_repack: true
  commit_interval: 5
  exclude:
    domains:
      - automation       # los triggers/condiciones no aportan al histórico
      - updater
      - persistent_notification
    entity_globs:
      - sensor.last_boot
      - sensor.date*
      - sensor.time*
      - sensor.*_uptime
    event_types:
      - call_service     # ruidoso; HA ya guarda el state_changed resultante

# ----------------------------------------------------------------------
# Logger: por defecto INFO. WARNING para componentes ruidosos.
# ----------------------------------------------------------------------
logger:
  default: info
  logs:
    homeassistant.components.zeroconf: warning
    homeassistant.components.ssdp: warning

# ----------------------------------------------------------------------
# Includes: separar archivos por dominio mantiene el YAML manejable.
# ----------------------------------------------------------------------
automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml
```

### `stacks/home-assistant/secrets.yaml.example`

```yaml
# /config/secrets.yaml.example — plantilla.
# El fichero real (`secrets.yaml`) NO se versiona. Modo 0600.
# Se referencia desde otros YAMLs con `!secret <clave>`.

# Ejemplo (rellenar tras desplegar Mosquitto, 02-mosquitto.md):
# mqtt_username: homeassistant
# mqtt_password: <generar con openssl rand -base64 24>

# Ejemplo (rellenar tras crear el long-lived token para Node-RED, 04-node-red.md):
# node_red_token: <token_largo_de_HA>
```

### Drop-in de Caddy: `stacks/caddy/conf.d/08-home-assistant.caddy`

```caddy
# /etc/caddy/conf.d/08-home-assistant.caddy — bloque LAN para Home Assistant.
# Documentado en docs/08-domotica/01-home-assistant.md.
#
# IMPORTANTE: NO se importa authelia_two_factor (decisión documentada en
# "Decisión: autenticación"). HA gestiona su propio login + TOTP.

home.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # HA usa network_mode: host. Caddy (en bridge homelab) lo alcanza en
    # host.docker.internal:8123. Ver extra_hosts en stacks/caddy/.../docker-compose.yml.
    reverse_proxy http://host.docker.internal:8123 {
        # WebSocket: imprescindible para la UI en tiempo real, automatizaciones
        # con disparadores instantáneos y la Companion App.
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # Caddy detecta y proxa WebSockets automáticamente desde v2.0.
        # No hace falta `transport http { versions 1.1 2 }` ni hacks.

        # HA tiene endpoints lentos (estadísticas, recorder al arrancar).
        transport http {
            read_timeout 5m
            write_timeout 5m
        }
    }
}
```

> **Acceso vía Tailscale**: el dominio `home.${DOMAIN_LAN}` resuelve por Pi-hole solo en LAN. Para acceso remoto vía Tailscale, hay dos opciones — (1) HA Companion App apunta directamente a `http://<pi-tailscale-ip>:8123` (con auth nativa, sin Caddy); (2) Caddy publica adicionalmente sobre el dominio `pi.tailnet.ts.net` con `tailscale cert` (`03-red/04-caddy.md`). La opción **(1)** es la idiomática de HA y la que recomienda la propia Companion App; la **(2)** es coherente con el resto del homelab. Elegir una en el bloque "Configuración".

> **Sobre `extra_hosts` en Caddy**: para que `host.docker.internal` resuelva, el servicio `caddy` en `stacks/caddy/docker-compose.yml` debe llevar:
> ```yaml
> extra_hosts:
>   - "host.docker.internal:host-gateway"
> ```
> Si Caddy ya estaba desplegado sin ese flag (Fase 3 lo dejaba opcional), se añade ahora con `docker compose up -d caddy`. **Esto es el único cambio que este documento exige sobre Caddy.**

### Crear los directorios persistentes y desplegar

```bash
# Directorios (HA arranca como root, owner root:root)
sudo install -d -o root -g root -m 0750 /mnt/hd2t/apps/home-assistant
sudo install -d -o root -g root -m 0750 /mnt/hd2t/apps/home-assistant/config
sudo install -d -o root -g root -m 0750 /mnt/hd2t/apps/home-assistant/media

# ACL para que el operador (homelab) pueda leer logs y editar YAML cuando
# haga falta sin sudo (lectura), o con sudo -e para escritura.
sudo setfacl -R -m u:homelab:rx /mnt/hd2t/apps/home-assistant/config
sudo setfacl -d -m u:homelab:rx /mnt/hd2t/apps/home-assistant/config

# Materializar configuración inicial (esqueleto + secrets vacío)
cd /home/homelab/homelab
set -a; source .env; set +a

sudo install -o root -g root -m 0640 \
    stacks/home-assistant/configuration.yaml.skel \
    /mnt/hd2t/apps/home-assistant/config/configuration.yaml
sudo install -o root -g root -m 0600 \
    stacks/home-assistant/secrets.yaml.example \
    /mnt/hd2t/apps/home-assistant/config/secrets.yaml
# Includes vacíos (HA falla si los referencia y no existen)
sudo install -o root -g root -m 0640 /dev/null \
    /mnt/hd2t/apps/home-assistant/config/automations.yaml
sudo install -o root -g root -m 0640 /dev/null \
    /mnt/hd2t/apps/home-assistant/config/scripts.yaml
sudo install -o root -g root -m 0640 /dev/null \
    /mnt/hd2t/apps/home-assistant/config/scenes.yaml

# Drop-in de Caddy
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/08-home-assistant.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/08-home-assistant.caddy

# .env del stack (vacío en esta fase)
cp stacks/home-assistant/.env.example stacks/home-assistant/.env
chmod 0600 stacks/home-assistant/.env

# Asegurar que Caddy tiene extra_hosts: host-gateway (única dependencia
# nueva sobre el stack de Caddy en Fase 3). Si el operador ya lo dejó
# preparado, este bloque es no-op.
grep -q 'host.docker.internal:host-gateway' stacks/caddy/docker-compose.yml || {
    echo "AVISO: añade extra_hosts:[\"host.docker.internal:host-gateway\"] al servicio caddy"
    echo "       en stacks/caddy/docker-compose.yml y haz 'docker compose up -d caddy'."
    exit 1
}

# Levantar Home Assistant
docker compose \
    -f stacks/home-assistant/docker-compose.yml \
    --env-file stacks/home-assistant/.env \
    up -d

# Recargar Caddy para que tome el nuevo drop-in
docker exec caddy caddy validate --config /etc/caddy/Caddyfile && \
    docker kill --signal=SIGUSR1 caddy
```

Tras `up -d`:

```bash
docker ps --filter name=homeassistant
# CONTAINER ID  IMAGE                                            STATUS
# ...           ghcr.io/home-assistant/home-assistant:2024.10    Up 90 seconds (healthy)

# Logs del primer arranque
docker logs homeassistant --tail 30
# ...
# [homeassistant.bootstrap] Setting up zone
# [homeassistant.bootstrap] Setting up sensor
# [homeassistant.core] Starting Home Assistant
# [homeassistant.components.frontend] Adding extra js_url ...
# Home Assistant initialized in 47.92s

# Confirmar que escucha en :8123 del host
ss -tlnp | grep 8123
# LISTEN 0 4096 *:8123 *:* users:(("python3",pid=...))
```

---

## Configuración

### 1) Onboarding inicial

Desde un cliente de la LAN con la CA interna ya instalada:

```text
1. Abrir https://home.lan/
2. HA muestra "Welcome! / Create your first user".
3. Crear el usuario admin:
   - Name: Operador (o el nombre real)
   - Username: homelab
   - Password: usar gestor de contraseñas; mínimo 16 caracteres.
4. Detalles de ubicación:
   - Country: España (o la que aplique)
   - Time zone: Europe/Madrid (debe coincidir con el TZ del host)
   - Currency: EUR
   - Unit system: Metric
5. "Devices found": HA mostrará una lista de dispositivos descubiertos
   por mDNS/SSDP (Chromecast, impresoras, smart TVs, ...). Saltar este
   paso por ahora; las integraciones se añaden deliberadamente después.
6. "Done".
```

> **Si HA no detecta dispositivos en el paso 5**: confirmar que `network_mode: host` está aplicado (`docker inspect homeassistant --format '{{.HostConfig.NetworkMode}}'` debe devolver `host`).

### 2) Activar 2FA (TOTP) — **obligatorio**

```text
1. Click en el avatar (esquina inferior izquierda) → Security
2. "Multi-factor Authentication Modules" → Time-based One-Time Password
3. Escanear el QR con Aegis/Authy/1Password/Bitwarden.
4. Introducir el código de 6 dígitos.
5. Guardar los códigos de recuperación en el gestor de contraseñas.
```

A partir de ahora, login = usuario + contraseña + código TOTP. La Companion App pedirá esto al primer arranque y se quedará con un long-lived token.

### 3) Verificar configuración correcta del reverse proxy

```text
1. Settings → System → General
   - "URL externa" (External URL): vacío (no se expone a internet).
   - "URL interna" (Internal URL): https://home.lan
2. Settings → System → Logs
   - Buscar "trusted_proxies" o "x-forwarded-for". No debe haber warnings.
   - Si aparece "Received X-Forwarded-For header from untrusted proxy",
     revisar configuration.yaml -> http.trusted_proxies.
```

### 4) Acceso desde la Companion App (móvil)

**Requisito previo**: CA interna instalada en el móvil (`03-red/04-caddy.md`) **y** Tailscale conectado en el móvil (para uso fuera de casa).

Opciones (elegir una):

| Opción | Cómo se configura en la app | Cuándo |
|---|---|---|
| **A) Por dominio LAN + Tailscale MagicDNS** | "Home Assistant URL": `https://home.lan` (en LAN), `http://pi.tailnet.ts.net:8123` (en tailnet, *sin* HTTPS porque la app fuera de LAN no tiene cert). | Idiomática de HA; la app gestiona la conmutación. |
| **B) Por dominio LAN + dominio tailnet con cert** | "URL externa" (External URL): `https://pi.tailnet.ts.net`. Caddy publica el bloque en tailnet con `tailscale cert`. | Coherente con el resto del homelab (todo HTTPS). Requiere drop-in extra en `Caddyfile` para tailnet. |

Por defecto en este documento se asume **A**: simple, oficial, no requiere bloques de Caddy adicionales para la app móvil.

```text
1. Instalar "Home Assistant" desde Play Store / App Store.
2. "Continue with Home Assistant".
3. URL: https://home.lan (escribir manualmente).
4. Aceptar el certificado (la CA interna ya está instalada en el móvil).
5. Login: homelab + password + TOTP.
6. "Allow location" / "Allow notifications" — opt-in del operador.
```

### 5) Configurar el Recorder con base de datos en orden

```text
1. Confirmar que el archivo home-assistant_v2.db existe:
     ls -la /mnt/hd2t/apps/home-assistant/config/home-assistant_v2.db
2. Ver tamaño tras unos minutos de uso (debería empezar ~10 MiB y crecer
   en función del número de entidades).
3. Settings → System → Storage:
   - "Database": SQLite (esperado).
   - "Database size": valor coherente con el archivo.
```

### 6) Preparar la integración MQTT (sin desplegarla aún)

`02-mosquitto.md` desplegará Mosquitto. Para minimizar el trabajo en ese documento, dejar listo:

```yaml
# Añadir a /mnt/hd2t/apps/home-assistant/config/secrets.yaml:
mqtt_username: homeassistant
mqtt_password: !secret mqtt_password   # se rellena en 02-mosquitto.md
```

Cuando `02-mosquitto.md` se aplique, basta con ir a `Settings → Devices & Services → Add Integration → MQTT`, host `host.docker.internal`, puerto `1883`, usuario `homeassistant`, password de `secrets.yaml`.

### 7) Operación diaria

| Acción | Comando |
|---|---|
| Ver el log activo | `https://home.lan/config/logs` o `docker logs homeassistant -f` |
| Validar `configuration.yaml` antes de reiniciar | `docker exec homeassistant python -m homeassistant --script check_config -c /config` |
| Recargar partes sin reiniciar | UI: Developer Tools → YAML → "Quick reload" / "All YAML configuration" |
| Reiniciar HA | UI: Developer Tools → Restart, o `docker compose -f stacks/home-assistant/docker-compose.yml restart homeassistant` |
| Backup manual del config (snapshot rápido) | `sudo tar czf /mnt/hd2t/backups/ha-snapshot-$(date +%F).tgz -C /mnt/hd2t/apps/home-assistant config` |
| Tamaño actual del recorder | `du -sh /mnt/hd2t/apps/home-assistant/config/home-assistant_v2.db` |
| Forzar purge del recorder | UI: Developer Tools → Services → `recorder.purge` con `keep_days: 10` |

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/home-assistant/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/home-assistant/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/home-assistant/configuration.yaml.skel` | microSD | `homelab:homelab` | `0644` | Esqueleto. |
| `/home/homelab/homelab/stacks/home-assistant/secrets.yaml.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/caddy/conf.d/08-home-assistant.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy. |
| `/mnt/hd2t/apps/home-assistant/config/` | hd2t | `root:root` | `0750` | Configuración + estado interno. |
| `/mnt/hd2t/apps/home-assistant/config/configuration.yaml` | hd2t | `root:root` | `0640` | Configuración principal (editable a mano). |
| `/mnt/hd2t/apps/home-assistant/config/secrets.yaml` | hd2t | `root:root` | `0600` | Secretos (referenciados con `!secret`). |
| `/mnt/hd2t/apps/home-assistant/config/automations.yaml` | hd2t | `root:root` | `0640` | Automatizaciones (UI o YAML). |
| `/mnt/hd2t/apps/home-assistant/config/scripts.yaml` | hd2t | `root:root` | `0640` | Scripts. |
| `/mnt/hd2t/apps/home-assistant/config/scenes.yaml` | hd2t | `root:root` | `0640` | Escenas. |
| `/mnt/hd2t/apps/home-assistant/config/.storage/` | hd2t | `root:root` | `0750` | **Estado interno**: usuarios, integraciones, dashboards Lovelace, lista de zonas, panel de personas. **Crítico**, no editable a mano. |
| `/mnt/hd2t/apps/home-assistant/config/home-assistant_v2.db` | hd2t | `root:root` | `0640` | SQLite del Recorder (histórico de estados/eventos). |
| `/mnt/hd2t/apps/home-assistant/config/home-assistant.log` | hd2t | `root:root` | `0640` | Log activo. Rotado por HA. |
| `/mnt/hd2t/apps/home-assistant/config/blueprints/` | hd2t | `root:root` | `0750` | Blueprints (plantillas de automatizaciones de la comunidad). |
| `/mnt/hd2t/apps/home-assistant/media/` | hd2t | `root:root` | `0750` | Carpeta media opcional (snapshots de cámara, TTS, etc.). |

> **Tamaño esperado**. Para una casa con ~30 entidades activas (luces, sensores de temperatura, presencia), `home-assistant_v2.db` se estabiliza en torno a **100–300 MiB** con `purge_keep_days: 10`. Para 100+ entidades, puede llegar a **500 MiB–1 GiB**. Las **5 GiB** reservadas en hd2t son holgadas; si se acerca al límite es señal de cardinalidad alta (un sensor con valor numérico cambiando cada segundo) — investigar antes de subir el cap.

> **Por qué no microSD**. El recorder hace escrituras frecuentes (default 1 s, aquí cada 5 s en lote). En microSD es desgaste medible a meses; en hd2t (USB 3.0) la durabilidad y el throughput sobran.

> **Sobre `.storage/`**. Es el equivalente al "registry" de HA: usuarios, dispositivos asociados a integraciones, capa Lovelace generada por la UI. **Editar a mano corrompe el estado**. La única vía soportada de modificarlo es a través de la UI o de la API REST. Borg lo respalda en bloque.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/home-assistant/docker-compose.yml`, `configuration.yaml.skel`, `.env.example`, `secrets.yaml.example` | Versionados. |
| `stacks/caddy/conf.d/08-home-assistant.caddy` | Versionado. |
| Decisiones (HA Container, network host, no Authelia, recorder 10d) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Tier (`07-backups/01-estrategia-backup.md`) | Por qué |
|---|---|---|---|
| `/mnt/hd2t/apps/home-assistant/config/configuration.yaml` | Sí. | T2 | Reproducible desde la plantilla, pero respaldarlo evita perder ediciones manuales. |
| `/mnt/hd2t/apps/home-assistant/config/secrets.yaml` | Sí. | T1 (secretos). | **Crítico**: contiene credenciales de MQTT, tokens de integraciones, claves API. |
| `/mnt/hd2t/apps/home-assistant/config/automations.yaml`, `scripts.yaml`, `scenes.yaml` | Sí. | T2 | Lógica casera que el operador escribió; pérdida = horas/días de re-escribir. |
| `/mnt/hd2t/apps/home-assistant/config/.storage/` | Sí. | T2 | Usuarios, integraciones, dashboards. **Sin esto el HA arranca virgen** tras un restore. |
| `/mnt/hd2t/apps/home-assistant/config/blueprints/` | Sí. | T2 | Plantillas reutilizables; pequeñas. |
| `/mnt/hd2t/apps/home-assistant/config/home-assistant_v2.db` | **Sí, pero…** | T2 / T3 frontera | El histórico tiene valor decreciente. Respaldar la BBDD activa puede dar ficheros parcialmente corruptos (SQLite escribe en lote). Estrategia: hook `before_backup` en Borgmatic → `docker exec homeassistant sqlite3 /config/home-assistant_v2.db ".backup '/config/home-assistant_v2.db.bak'"`, copiar el `.bak`, borrarlo `after_backup`. |
| `/mnt/hd2t/apps/home-assistant/config/home-assistant.log` | **No.** | T4 | Rotado, regenerable, voluminoso en pico. |
| `/mnt/hd2t/apps/home-assistant/config/home-assistant.log.*` | **No.** | T4 | Idem (rotaciones). |
| `/mnt/hd2t/apps/home-assistant/media/` | Selectivo. | T3 | Si contiene snapshots de cámara con valor sentimental, sí; si solo tiene TTS regenerable, no. Decisión del operador. |

Entrada en `borgmatic.yaml` (parche relativo al patrón de `07-backups/02-borgmatic.md`):

```yaml
source_directories:
  # ...
  - /mnt/hd2t/apps/home-assistant/config

# Excluir lo regenerable
patterns:
  # ...
  - '!/mnt/hd2t/apps/home-assistant/config/home-assistant.log'
  - '!/mnt/hd2t/apps/home-assistant/config/home-assistant.log.*'
  - '!/mnt/hd2t/apps/home-assistant/config/*.bak'   # se incluye solo el snapshot consistente

# Hooks: snapshot consistente de SQLite antes del backup
before_backup:
  - 'docker exec homeassistant sqlite3 /config/home-assistant_v2.db ".backup ''/config/home-assistant_v2.db.borg''"'
after_backup:
  - 'docker exec homeassistant rm -f /config/home-assistant_v2.db.borg'
```

> **Política sobre el recorder**. La BBDD se respalda **vía snapshot consistente**, no copiando el fichero activo. Restaurar de un fichero copiado en caliente puede dar `database disk image is malformed`. El truco con `.backup` de SQLite es atómico y rápido (~5 s para 500 MiB). Si el operador acepta perder hasta 10 días de histórico tras desastre, puede excluir totalmente la BBDD del backup; en ese caso, marcar `purge_keep_days` con valor pequeño y ahorrar espacio en Borg.

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/home-assistant/docker-compose.yml up -d --force-recreate
# HA reusa /mnt/hd2t/apps/home-assistant/config: arranque normal en ~60s,
# todas las entidades, integraciones y usuarios siguen ahí.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear Fases 1 → 7.
2. `borgmatic extract --archive latest --path mnt/hd2t/apps/home-assistant`.
3. Verificar permisos: `sudo chown -R root:root /mnt/hd2t/apps/home-assistant && sudo chmod 0750 /mnt/hd2t/apps/home-assistant/config && sudo chmod 0600 /mnt/hd2t/apps/home-assistant/config/secrets.yaml`.
4. `docker compose -f stacks/home-assistant/docker-compose.yml up -d`.
5. Login en `https://home.lan` con credenciales pre-existentes — TOTP sigue funcionando porque la semilla está en `.storage`.
6. Reactivar la Companion App: el long-lived token sigue válido si `.storage` se restauró completo.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `https://home.lan/` da `502 Bad Gateway` | Caddy no resuelve `host.docker.internal`. Falta `extra_hosts` en `stacks/caddy/docker-compose.yml`. | Añadir `extra_hosts: ["host.docker.internal:host-gateway"]` al servicio `caddy`, `docker compose up -d caddy`. |
| `https://home.lan/` carga la UI pero el icono "Connecting…" persiste | El reverse proxy bloquea WebSockets. | Caddy v2 los pasa por defecto; verificar que **no** se ha añadido `header_up Connection` ni `Upgrade` manuales (Caddy los maneja). Probar `curl -ksI https://home.lan/api/websocket` → `400` (esperado: pide upgrade). Si da `502`, es Caddy/HA caídos. |
| Logs de HA: `Received X-Forwarded-For header from untrusted proxy 172.30.10.X` | Falta el bloque `http.trusted_proxies` en `configuration.yaml` o el rango no incluye al bridge. | Añadir `172.30.10.0/24` (el bridge `homelab`) a `http.trusted_proxies` y reiniciar HA. |
| Logs de HA: `Address already in use: ('0.0.0.0', 8123)` | Otro proceso ocupa el `:8123` del host (segunda instancia, `python` ejecutándose suelto). | `sudo ss -tlnp \| grep 8123` para identificar; `kill` o `docker rm -f`. Tras eso, `docker compose up -d`. |
| HA detecta dispositivos pero no los puede emparejar (Chromecast queda "unavailable") | `network_mode: host` está activo pero el firewall del host bloquea multicast. | `sudo ufw allow in on eth0 to any port 5353 proto udp comment 'mDNS'`. Igual para `1900/udp` (SSDP). |
| `homeassistant.config_entries` en log: "Unable to find component" tras update | El bump de minor (`2024.10` → `2024.11`) deprecó/renombró una integración. | Leer release notes; la guía manual está en `https://www.home-assistant.io/blog/`. Si urge: revertir el tag a la versión anterior, `docker compose up -d`. |
| `docker logs homeassistant` muestra `[homeassistant] Error doing job: Future exception was never retrieved` constantemente | Integración mal configurada (usualmente API key revocada). | Settings → Devices & Services: la integración mostrará "Reconfigure". Si no, eliminar y volver a añadir. |
| El recorder crece a >2 GiB en una semana | Cardinalidad alta: un sensor numérico cambia cada segundo (potencia eléctrica, ping monitor). | Developer Tools → Statistics → ordenar por "States/hour"; identificar la entidad culpable y añadirla a `recorder.exclude`. |
| Companion App no recibe notificaciones | La app necesita salir a internet (FCM/APNs vía servidores de HA Cloud). El homelab no expone HA, pero la app se conecta a Nabu Casa para *recibir* push, no para que entre tráfico. | Confirmar que el móvil tiene internet. Si el operador rechaza Nabu Casa: usar Telegram/ntfy/Pushover como notificación alternativa. |
| `https://home.lan` no resuelve | Pi-hole no aplica el comodín `address=/lan/192.168.1.10`, o el cliente usa otro DNS. | `dig +short home.lan @192.168.1.2`; si vacío, revisar Pi-hole. Si el cliente usa DNS distinto (CGNAT del móvil), añadir `home.lan` al `/etc/hosts` del cliente. |
| Permisos: el operador no puede `cat configuration.yaml` | El bind mount es `root:root 0750`. | `sudo cat`, o aplicar `setfacl -m u:homelab:rx` (ya documentado). |
| Tras `docker compose up -d`, HA arranca pero los integraciones ESPHome/Shelly no aparecen | Algunos plugins requieren TCP a puertos altos en la LAN. Sin `network_mode: host`, no funcionarían; con `host` sí, pero el firewall del host puede estar bloqueando. | `sudo nft list ruleset \| grep 8123` y vecinos. Comprobar la regla `LAN → host`. |
| Apple HomeKit Bridge no aparece en la app Casa | Falta `/run/dbus` o el host no tiene `avahi-daemon`. | `sudo apt install -y avahi-daemon` y montar `/run/dbus:/run/dbus:ro`. Reiniciar HA. |
| Tailscale: la Companion App va lenta sobre tailnet | Por defecto, los nodos de Tailscale negocian DERP (relay) si NAT traversal falla. | `sudo tailscale netcheck` para diagnosticar. Si sale "DERP", hay NAT del proveedor: tolerar (sigue funcionando, solo es ~150 ms más lento). |

---

## Decisiones que **no** se toman en este documento

- **Authelia delante de HA**: ver decisión arriba; reabrible si en el futuro Authelia se promueve a OIDC provider y se reemplaza el login nativo de HA por OAuth2.
- **Add-ons del modelo HAOS** (ESPHome, AppDaemon, Mariadb, NodeRed): cada uno es un stack Docker independiente. ESPHome se documenta solo si el operador adquiere dispositivos ESP32. AppDaemon hoy es redundante con Node-RED (`04-node-red.md`).
- **Grabación de cámaras (Frigate, Scrypted)**: subdominio entero (NVR + IA) que merece una Fase aparte. Reabrible si se compran cámaras IP.
- **Z-Wave**: requiere hardware específico (USB stick) y un broker `zwave-js-server`. Reabrible si se compran dispositivos Z-Wave; hoy el plan asume Zigbee.
- **HACS** (Home Assistant Community Store): repositorio comunitario de integraciones y componentes Lovelace. Útil pero introduce dependencias no auditadas. Reabrible cuando el operador identifique una integración concreta no nativa que la justifique.
- **InfluxDB + Grafana para domótica**: doblar el stack de observabilidad para ver gráficas de temperatura/luminosidad. Lovelace cubre el caso para 1–3 usuarios.
- **AppDaemon, pyscript**: motores alternativos de automatización en Python. Para flujos visuales se usa Node-RED; para flujos simples se usan automatizaciones YAML/UI nativas.
- **Multiusuario con roles (admin/lectura/local)**: HA lo soporta nativamente desde la UI; no requiere documento, basta con crear los usuarios bajo demanda.
- **Mobile App vía Nabu Casa Cloud**: subscripción anual de pago que añade DDNS, HTTPS y push notifications "tipo SaaS". Innecesario con Tailscale + push nativo.
- **Variante alternativa con `(lan_only)` en lugar de auth nativa**: si el operador quiere reforzar con allowlist de IPs LAN además de TOTP, sustituir `import healthcheck` por `import lan_only` en el drop-in de Caddy. **No es la decisión por defecto** porque rompe la Companion App desde tailnet (no es LAN).

---

## Verificación Final

Antes de pasar a `02-mosquitto.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/home-assistant/docker-compose.yml ps` | `homeassistant ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect homeassistant --format '{{.Config.Image}}'` | `ghcr.io/home-assistant/home-assistant:2024.10` |
| Network mode es host | `docker inspect homeassistant --format '{{.HostConfig.NetworkMode}}'` | `host` |
| HA escucha en `:8123` del host | `ss -tlnp \| grep ':8123 '` | una línea, owner `python3` |
| `home.lan` resuelve al IP de la Pi | `dig +short home.lan @192.168.1.2` | `192.168.1.10` |
| Caddy tiene `host.docker.internal` resuelto | `docker exec caddy getent hosts host.docker.internal` | `<gateway>  host.docker.internal` |
| Caddy sirve `home.lan` con cert de la CA interna | `echo \| openssl s_client -connect home.lan:443 -servername home.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| Health endpoint responde (interno) | `wget -qO- http://127.0.0.1:8123/manifest.json \| head -c 60` | `{"background_color":"#FFFFFF","theme_color":...` |
| Configuración válida | `docker exec homeassistant python -m homeassistant --script check_config -c /config` | `Configuration valid!` |
| Sin warnings de trusted_proxies | `docker logs homeassistant 2>&1 \| grep -i trusted_proxies` | salida vacía |
| Login funciona desde navegador con TOTP | navegador con CA instalada | UI carga, dashboard "Overview" visible |
| WebSocket activo | `https://home.lan` → DevTools → Network → ws | conexión `home.lan/api/websocket` en estado `101 Switching Protocols` |
| Recorder escribiendo | `du -sh /mnt/hd2t/apps/home-assistant/config/home-assistant_v2.db` | tamaño > 0, crece con el tiempo |
| Owner correcto del config | `sudo stat -c '%u:%g %a' /mnt/hd2t/apps/home-assistant/config` | `0:0 750` |
| `secrets.yaml` con permisos restrictivos | `sudo stat -c '%a' /mnt/hd2t/apps/home-assistant/config/secrets.yaml` | `600` |
| 2FA activo para el usuario admin | UI: avatar → Security → MFA Modules | TOTP listado |
| Companion App conectada (si aplica) | UI: Settings → Devices & Services → Mobile App | dispositivo del operador presente |
| Descubrimiento mDNS funcional (si hay dispositivos en LAN) | UI: Settings → Devices & Services → Discovered | al menos un dispositivo de la LAN listado |

---

## Referencias

- Documentación oficial Home Assistant — https://www.home-assistant.io/docs/
- Home Assistant Container — https://www.home-assistant.io/installation/raspberrypi#install-home-assistant-container
- Imagen Docker oficial — https://github.com/home-assistant/docker / `ghcr.io/home-assistant/home-assistant`
- `configuration.yaml` reference — https://www.home-assistant.io/docs/configuration/
- HTTP integration (trusted_proxies) — https://www.home-assistant.io/integrations/http/
- Recorder integration — https://www.home-assistant.io/integrations/recorder/
- Authentication — https://www.home-assistant.io/docs/authentication/
- Multi-factor authentication (TOTP) — https://www.home-assistant.io/docs/authentication/multi-factor-auth/
- Companion App — https://companion.home-assistant.io/
- Release notes mensuales — https://www.home-assistant.io/blog/categories/release-notes/
- Caddy reverse proxy con HA (oficial) — https://www.home-assistant.io/integrations/http/#reverse-proxy
- Documentos hermanos: `02-mosquitto.md`, `03-zigbee2mqtt.md`, `04-node-red.md`.
- Documentos referenciados: `03-red/04-caddy.md`, `04-seguridad/01-authelia.md`, `07-backups/01-estrategia-backup.md`, `07-backups/02-borgmatic.md`, `05-monitorizacion/01-prometheus.md`.
