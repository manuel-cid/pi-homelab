# Home Assistant

## Descripción

Despliegue de **Home Assistant Container** ([imagen oficial `ghcr.io/home-assistant/home-assistant`](https://github.com/home-assistant/core/pkgs/container/home-assistant)) como **plataforma de automatización del hogar** del homelab. HA actúa de **hub central** sobre el que orbitan los demás servicios de la Fase 8: recibe eventos MQTT desde [Mosquitto](./02-mosquitto.md), descubre dispositivos Zigbee vía [Zigbee2MQTT](./03-zigbee2mqtt.md) (también por MQTT), y expone webhooks/servicios consumidos por [Node-RED](./04-node-red.md) para flujos visuales.

Este doc cubre, en orden:

1. **Por qué Home Assistant Container** (no Supervised, no Core nativo, no HAOS) y qué se sacrifica al elegir el sabor "Container".
2. **Plan de variables y archivos**: `.env.example` versionable, `.env` real con secretos en `/mnt/hd2t/services/home-assistant/.env`, layout de directorios bajo `/mnt/hd2t/services/home-assistant/`.
3. **`configuration.yaml` inicial mínimo** con `default_config:`, bloque `http:` para que HA confíe en Caddy como reverse proxy (`use_x_forwarded_for` + `trusted_proxies`), e `homeassistant:` con timezone y ubicación.
4. **`docker-compose.yml`** con bind mount del `/config`, montaje de `/etc/localtime`, etiquetas `com.centurylinklabs.watchtower.enable: "false"` (HA está **excluido** de Watchtower por política, [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6).
5. **Despliegue, onboarding inicial** (creación del usuario `Owner` desde la UI, no por API).
6. **Integración con Caddy** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3): bloque `ha.{$LAN_DOMAIN}`, snippet reutilizable, registro DNS local en Pi-hole.
7. **Integración con Authelia** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §9): bypass obligatorio para `/api/*` y `/auth/*` (rompería la app móvil y los webhooks); SSO solo sobre la UI web.
8. **Backup nativo de HA** vía API, exportado a `/mnt/hd2t/backups/dumps/homeassistant/` y archivado por Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6, [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §2.3).
9. **Operaciones cotidianas**: upgrade manual leyendo el "Breaking Changes" de la release, tail de logs, herramientas de diagnóstico (`ha core check` no aplica en Container — alternativas).
10. **Variantes opt-in**: `network_mode: host` para descubrimiento mDNS/Bonjour (HomeKit Bridge, Cast, Sonos), Bluetooth pasado por `/run/dbus`, HACS para integraciones de la comunidad.

> **Alcance de red**: Home Assistant **solo se accede vía Caddy** sobre `https://ha.lan` (LAN) o `https://ha.${TS_DOMAIN}` (Tailscale). El puerto 8123 del contenedor **no se publica al host** (es la regla del homelab para todos los servicios web, [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §0). Las apps móviles oficiales (`Home Assistant Companion` en iOS/Android) se conectan también por la URL pública: en LAN directamente, en remoto vía Tailscale.

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), `/mnt/hd2t/` montado y con permisos correctos ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §2.6).
- **Docker + red `homelab`** según Fase 2: red bridge `homelab` creada, convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5 — bind mounts; §4.3 — red compartida).
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) con la red `homelab` accesible y `lan_internal_tls` operativo. Sin Caddy no hay HTTPS y la app móvil rechaza HTTP sin TLS.
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con la posibilidad de añadir registros A locales (`ha.lan` → IP de la Pi).
- **(Opcional) Authelia desplegado** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)) si se quiere SSO + 2FA delante de la UI web. **No** es bloqueante: HA tiene su propio login + 2FA TOTP nativo y se puede activar Authelia más tarde sin reinstalar.
- **(Opcional) Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Home Assistant lleva la etiqueta `com.centurylinklabs.watchtower.enable: "false"` por política — los upgrades son **siempre manuales** tras leer el blog de release.
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) para que `/mnt/hd2t/backups/dumps/homeassistant/` sea archivado en cada snapshot.
- **Disco hd2t libre**: ≥ 2 GB para `/mnt/hd2t/services/home-assistant/config/` (la BD `home-assistant_v2.db` SQLite suele ocupar 200–500 MB tras un mes; el log mensual otros 50–200 MB; el resto son automatizaciones, blueprints, custom_components).
- **Decisión sobre red `host` vs `homelab`**: el homelab usa por defecto `homelab` (bridge, todos los servicios web pasan por Caddy). Si el operador necesita integraciones mDNS/Bonjour (HomeKit Bridge, Google Cast, Sonos descubrimiento automático), debe activar la variante §13.1 (`network_mode: host`) **antes** del primer arranque para que HA descubra dispositivos en el primer escaneo. Cambiar después implica re-emparejar.

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Sabor de Home Assistant | **Container** (`ghcr.io/home-assistant/home-assistant:<tag>`) | Único soporte oficial con Docker Compose. **HAOS** requiere VM/dedicado; **Supervised** requiere Debian "puro" sin Docker en uso por nadie más; **Core** requiere Python venv en el host. Container es el sabor que encaja con el resto del homelab dockerizado. Coste: no hay add-ons (Mosquitto, Z2M, Node-RED se despliegan **como contenedores aparte** — eso es justamente lo que hacen los docs `02-04` de esta fase). |
| Tag de imagen | **`ghcr.io/home-assistant/home-assistant:2025.10`** (pinned, no `stable`) | HA publica una *minor* nueva el primer miércoles de cada mes, con cambios potencialmente disruptivos. Pinear el tag concreto fuerza al operador a actualizar **conscientemente** tras leer el blog (https://www.home-assistant.io/blog/categories/release-notes/). El tag `stable` rompe servicios silenciosamente. |
| Arquitectura | `linux/arm64` (Pi 5) | El manifest de la imagen oficial incluye `arm64`. Variantes específicas como `home-assistant:2025.10-arm64` ya no se usan (deprecated tras el multi-arch). |
| Red Docker | **`homelab`** (bridge, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.3). **Sin** `ports:` al host. | Caddy llega a HA por nombre (`http://homeassistant:8123`) sobre la red compartida. No publicar 8123 al host elimina el riesgo de que la UI sea accesible **sin** TLS. Coste: **se pierde mDNS/Bonjour automático** (la red bridge no propaga multicast 224.0.0.251 al host). Operador con HomeKit/Cast/Sonos usa §13.1. |
| Modelo de almacenamiento | **Bind mount** `/mnt/hd2t/services/home-assistant/config:/config` | Patrón estándar del homelab ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5). Permite a Borgmatic respaldar `/config` directamente y al operador editar `configuration.yaml` con `nano` desde el host. |
| BD del recorder | **SQLite por defecto**, `/config/home-assistant_v2.db` | El `default_config:` activa el `recorder` apuntando a SQLite. Para un homelab de ≤ 50 dispositivos es suficiente (HA recomienda PostgreSQL/MariaDB a partir de cientos de entidades con eventos por segundo). Migración a PostgreSQL queda como variante futura, no se cubre aquí. |
| Backup | **Snapshot nativo de HA** vía servicio `backup.create`, con `auto_backup` programado a las 03:00 del host | HA serializa configuración + BD + `.storage/` en un único `.tar` que se restaura sobre una instalación virgen. La estrategia 3-2-1 ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §5) cubre estos `.tar` vía Borgmatic. |
| Destino de los backups de HA | **`/mnt/hd2t/backups/dumps/homeassistant/`** (vía bind mount `/backup` dentro del contenedor) | Convención fijada por [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §13.6 y [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §2.3. Borg los archiva con deduplicación. |
| Watchtower | **`com.centurylinklabs.watchtower.enable: "false"`** | Por política ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §6, §52): HA introduce *breaking changes* documentados en su blog cada release; un upgrade automático puede romper integraciones (deprecated YAML keys, schema de la BD del recorder, etc.). El upgrade es **siempre manual** tras leer el blog. |
| Reverse proxy | **Caddy con `forward_auth` opcional a Authelia, bypass para `/api/*` y `/auth/*`** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §9.1) | La app móvil y los webhooks (`/api/webhook/...`) usan tokens long-lived en lugar de sesión cookie; aplicar `forward_auth` a esas rutas las rompería. Solo la UI web pasa por Authelia. |
| `http.use_x_forwarded_for` + `http.trusted_proxies` | **`172.20.0.0/24`** (subred de la red `homelab`, [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.1) | Sin esto, HA bloquea cualquier petición que llegue con `X-Forwarded-For` por seguridad (mitigación de spoofing). El rango fijo del bridge `homelab` es de donde llega Caddy. |
| Acceso a la API admin de HA | **Solo desde el contenedor (puerto 8123)**, sin `ports:` al host | Mismo patrón que Authelia ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §10.2): el host no expone el backend; el único camino es a través de Caddy. |
| Onboarding del primer usuario | **Por la UI web**, sin `auth.providers` exóticos | El primer login crea el usuario `Owner` (admin con todos los privilegios). HA **no** tiene un comando equivalente a `occ user:add` para crear usuarios sin UI; es inherente al diseño. |

---

## 1. Resumen de la arquitectura

```
                    ┌────────────────── LAN ──────────────────┐
                    │                                         │
   App móvil (LAN)  │   Navegador del operador                │
        │           │           │                             │
        └─────────► https://ha.lan (TLS de Caddy)             │
                    │           │                             │
                    │           ▼                             │
                    │   ┌───────────────┐                     │
                    │   │     Caddy     │  (../03-red/04-caddy.md)
                    │   │  ha.lan:443   │                     │
                    │   └───────┬───────┘                     │
                    │           │ reverse_proxy (red homelab) │
                    │           │ http://homeassistant:8123   │
                    │           ▼                             │
                    │   ┌────────────────────┐                │
                    │   │  Home Assistant    │                │
                    │   │  (este doc)        │                │
                    │   │                    │                │
                    │   │  /config (bind)    │ ─► /mnt/hd2t/services/home-assistant/config/
                    │   │  /backup (bind)    │ ─► /mnt/hd2t/backups/dumps/homeassistant/
                    │   └─────────┬──────────┘                │
                    │             │                           │
                    │             │ MQTT                      │
                    │             ▼                           │
                    │   ┌────────────────────┐                │
                    │   │     Mosquitto      │  (./02-mosquitto.md)
                    │   │  mqtt://...:1883   │                │
                    │   └─────────┬──────────┘                │
                    │             │                           │
                    │             │ MQTT (publish)            │
                    │             ▼                           │
                    │   ┌────────────────────┐                │
                    │   │    Zigbee2MQTT     │  (./03-zigbee2mqtt.md)
                    │   │  (USB Zigbee dev)  │                │
                    │   └────────────────────┘                │
                    └─────────────────────────────────────────┘
```

Lo crítico de este diagrama:

1. **Una única vía de entrada**: la UI y la app móvil entran siempre por Caddy. El puerto 8123 no existe para clientes externos al stack.
2. **HA es cliente MQTT, no broker**: HA se conecta a Mosquitto en `mqtt://mosquitto:1883` por la red `homelab`. Z2M también es cliente MQTT del mismo broker. La comunicación HA ↔ Z2M es **siempre indirecta vía Mosquitto**, no hay socket directo entre ellos. Esto se documenta en [`./02-mosquitto.md`](./02-mosquitto.md) y [`./03-zigbee2mqtt.md`](./03-zigbee2mqtt.md).
3. **Sin acceso directo desde el host a hardware**: Bluetooth, Zigbee USB y Z-Wave USB **no** se pasan a este contenedor. Z2M tiene su propio USB passthrough. Si en el futuro se quiere Bluetooth en HA (BLE proxies, esphome), §13.2 explica cómo añadir `/run/dbus`.
4. **Backups por separado del bind mount**: `/config` se respalda como ficheros, **pero también** se ejecuta `backup.create` (snapshot nativo) que mete todo en un `.tar` autodescriptivo. Doble cobertura: el `.tar` permite restaurar sobre HA virgen (sigue su procedimiento de "Restore from backup" del onboarding); el bind mount permite editar/diagnosticar sin un HA arriba.

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/homeassistant/.env.example`:

```env
# ~/homelab/stacks/homeassistant/.env.example
# Versión control: ~/homelab/stacks/homeassistant/.env.example
# Valores reales en /mnt/hd2t/services/home-assistant/.env (chmod 600).
# Este fichero NO contiene secretos; los hay pocos en HA Container.
# Las credenciales (admin, MQTT, integraciones) viven dentro de /config.

# --- Comunes del homelab ---
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
TZ=Europe/Madrid

# --- Dominios internos (consistentes con dns/.env y proxy/.env) ---
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Home Assistant ---
# https://github.com/home-assistant/core/pkgs/container/home-assistant
# ¡Leer https://www.home-assistant.io/blog/categories/release-notes/ antes de cambiar!
HA_IMAGE_TAG=2025.10

# Hostname público (sin esquema). Usado en Caddyfile y opcionalmente en
# configuration.yaml (external_url, internal_url).
HA_HOSTNAME=ha
HA_LAN_HOST=ha.lan
HA_TS_HOST=ha.tailnet.ts.net

# Subred de la red `homelab` (../02-docker/02-estructura-compose.md §4).
# Se usa en configuration.yaml → http.trusted_proxies.
HOMELAB_SUBNET=172.20.0.0/24
```

### 2.2. `.env` real (`/mnt/hd2t/services/home-assistant/.env`)

```bash
# Crear el .env con permisos correctos.
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/home-assistant
sudo install -o homelab -g homelab -m 600 /dev/null \
  /mnt/hd2t/services/home-assistant/.env

# Volcar contenido (editar valores reales).
sudo -u homelab tee /mnt/hd2t/services/home-assistant/.env > /dev/null <<'EOF'
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
TZ=Europe/Madrid
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net
HA_IMAGE_TAG=2025.10
HA_HOSTNAME=ha
HA_LAN_HOST=ha.lan
HA_TS_HOST=ha.tailnet.ts.net
HOMELAB_SUBNET=172.20.0.0/24
EOF

# Verificar.
ls -l /mnt/hd2t/services/home-assistant/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

### 2.3. Cómo se inyectan al contenedor

El `docker-compose.yml` (§5) declara `env_file: /mnt/hd2t/services/home-assistant/.env`. Compose carga el fichero **a la hora de interpolar `${...}` en el YAML** (para tags, hostnames…) y **además** lo expone al proceso del contenedor (HA solo lee `TZ` directamente; el resto solo se usa fuera del contenedor — en Caddyfile y este `docker-compose.yml`).

> **Por qué no hay secretos en `.env`**: HA Container no lee credenciales de variables de entorno. La password del usuario admin se establece desde la UI en el primer arranque y vive cifrada en `/config/.storage/auth_provider.homeassistant`. Las credenciales de integraciones (MQTT, Spotify, Tuya…) se introducen por la UI y viven en `/config/.storage/core.config_entries`. Esos ficheros se respaldan **siempre** vía el `.tar` de `backup.create` (cifrado opcional con password) y vía el bind mount completo a través de Borgmatic.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
sudo install -d -o homelab -g homelab -m 750 ~/homelab/stacks/homeassistant
```

### 3.2. Crear el árbol de datos persistentes

```bash
# Datos vivos del contenedor (montados como /config).
sudo install -d -o homelab -g homelab -m 750 \
  /mnt/hd2t/services/home-assistant \
  /mnt/hd2t/services/home-assistant/config

# Destino de los backups nativos (montado como /backup).
# Compartido con Borgmatic (../07-backups/02-borgmatic.md §13.6).
sudo install -d -o root      -g root      -m 0700 \
  /mnt/hd2t/backups/dumps/homeassistant
```

| Ruta | Modo | Owner | Quién escribe | Por qué |
|---|---|---|---|---|
| `/mnt/hd2t/services/home-assistant/` | `750 homelab:homelab` | homelab (Compose), root (HA dentro escribe como root pero el bind mount mantiene los UIDs según los crea) | El operador desde el host (lee/edita YAML); HA dentro (escribe BD, logs, `.storage/`) | Patrón canónico. HA Container corre como `root` dentro pero los bind mounts respetan los UIDs del host; los ficheros aparecen propiedad de `root:root` cuando los crea HA, lo cual es esperado. El operador con `sudo` puede leerlos y diagnosticar. |
| `/mnt/hd2t/services/home-assistant/config/` | `750 homelab:homelab` (preexiste, lo rellena HA) | HA dentro del contenedor | HA materializa `home-assistant.log`, `home-assistant_v2.db`, `.storage/`, `automations.yaml`, `scripts.yaml`, `scenes.yaml`, `blueprints/`, etc. en el primer arranque. |
| `/mnt/hd2t/backups/dumps/homeassistant/` | `0700 root:root` | HA escribe ficheros aquí (vía servicio `backup.create` apuntado a `/backup`). | Modo `0700` para que solo `root` (y por tanto el daemon de Docker que monta los bind) lea. Borgmatic corre como `root` y por eso puede archivar. El usuario `homelab` no debe leer dumps por convención del homelab ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §3). |

### 3.3. Permisos para el proceso del contenedor

HA Container corre como `root` dentro del contenedor por **diseño** del proyecto upstream (es la única forma de que las integraciones que requieren acceso a `/dev/serial/by-id/*` o a `/run/dbus` funcionen sin reflexión sobre user namespaces). Esto se traduce en:

- Los ficheros bajo `/mnt/hd2t/services/home-assistant/config/` aparecen propiedad de `root:root` cuando los crea el contenedor.
- El operador desde el host **siempre** usa `sudo` para editar `configuration.yaml`, leer logs, etc.
- **No** se intenta hacer `chown` masivo a `homelab:homelab` después: rompería el primer `up` siguiente, porque HA reescribiría como root y volvería a `root:root`.

> **¿Y si esto te molesta?** Existe la variante `home-assistant:<tag>-rootless` (no oficial). El homelab **no** la usa: sacrifica integraciones que necesitan `CAP_NET_RAW` (mDNS, Wake-on-LAN) sin ganancia material en seguridad real (el contenedor sigue aislado del host por namespaces). Si se quisiera ir por ahí, bind mount completo en directorio dedicado al UID 1000 + recreado a partir de `.tar` de backup.

---

## 4. `configuration.yaml` inicial

### 4.1. Layout del fichero

`/mnt/hd2t/services/home-assistant/config/configuration.yaml` se crea **automáticamente** por HA en el primer arranque, pero con un mínimo (solo `default_config:`). El homelab fija un punto de partida más completo. Crear **antes** del primer `up`:

```yaml
# /mnt/hd2t/services/home-assistant/config/configuration.yaml
# Versionado en git si el operador lo decide (fuera de ~/homelab/, ya que los
# secretos viven en secrets.yaml junto a este fichero — no se sube ese).
# Documentación: https://www.home-assistant.io/docs/configuration/

# Activa el set sensato por defecto: frontend, recorder con SQLite, sun,
# sensores meta del propio HA, system_health, mobile_app, energy, etc.
default_config:

# Identidad de la instalación.
homeassistant:
  name: Homelab
  # Coordenadas — usadas por sun, sensores meteo, automatizaciones de presencia.
  # Los valores literales aquí no son secretos (un mapa con +/- 10 km basta).
  latitude: !secret home_latitude
  longitude: !secret home_longitude
  elevation: 700
  unit_system: metric
  currency: EUR
  country: ES
  time_zone: Europe/Madrid
  # URLs externas e internas para que la mobile app construya links correctos
  # cuando se accede en LAN vs vía Tailscale.
  external_url: "https://ha.tailnet.ts.net"
  internal_url: "https://ha.lan"

# HTTP: HA detrás de Caddy (TLS-terminator). HA habla HTTP plano en :8123.
http:
  # No bind a la IP del host (no hay 'ports:' en el compose de todas formas).
  server_host: 0.0.0.0
  server_port: 8123
  # Aceptar headers X-Forwarded-* solo desde Caddy (red `homelab`).
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.20.0.0/24    # Red Docker `homelab` (../02-docker/02-estructura-compose.md §4)
  # NO activar `ip_ban_enabled` aquí: Caddy reescribe el `X-Forwarded-For` con
  # la IP real del cliente y HA lo bannearía a nivel del propio HA, dejando al
  # operador fuera. El ban lo hace fail2ban (../04-seguridad/02-fail2ban.md).

# Loguear a fichero (lo lee el operador con `sudo tail -f`) y warning por defecto.
logger:
  default: warning
  logs:
    homeassistant.components.http: info
    homeassistant.components.api: info

# El recorder está en SQLite por defecto (default_config:); ajustes finos:
recorder:
  # Limitar el histórico a 14 días para no inflar la BD.
  purge_keep_days: 14
  # Ejecutar purga en madrugada.
  auto_purge: true
  # Excluir entidades muy ruidosas (ajustar a la realidad del operador).
  exclude:
    domains:
      - automation
      - updater

# Backup automático cada noche, exportado a /backup (bind a /mnt/hd2t/backups/dumps/homeassistant/).
# El servicio `backup.create` se invoca desde una automation (../docs/...) en lugar de aquí.
# Aquí solo se asegura que la integración `backup` esté activa: viene en default_config:.

# Frontend, themes, lovelace, customización: se gestionan desde la UI tras el onboarding.
# Para arrancar minimal y dejar que la UI lo escriba:
frontend:
  themes: !include_dir_merge_named themes/

# Includes para automations/scripts/scenes — la UI los escribe aquí.
automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml
```

Y los includes vacíos (HA los exige existentes para no romper):

```bash
sudo -u root install -d -m 0755 /mnt/hd2t/services/home-assistant/config/themes
sudo -u root touch \
  /mnt/hd2t/services/home-assistant/config/automations.yaml \
  /mnt/hd2t/services/home-assistant/config/scripts.yaml \
  /mnt/hd2t/services/home-assistant/config/scenes.yaml
```

Y `secrets.yaml` (no versionable):

```yaml
# /mnt/hd2t/services/home-assistant/config/secrets.yaml
# Cualquier valor sensible o personal va aquí, referenciado con !secret <key>
# desde configuration.yaml.
home_latitude: 40.4168
home_longitude: -3.7038
```

```bash
sudo install -o root -g root -m 0600 /dev/null \
  /mnt/hd2t/services/home-assistant/config/secrets.yaml
# Editar con: sudo nano /mnt/hd2t/services/home-assistant/config/secrets.yaml
```

### 4.2. Por qué cada sección

| Sección | Por qué |
|---|---|
| `default_config:` | Activa de un plumazo: `frontend`, `config` (UI de configuración), `mobile_app`, `sun`, `system_health`, `tag`, `person`, `zone`, `automation`, `script`, `scene`, `cloud` (HA Cloud, no se usa pero es inocuo), `media_source`, `stream`, `ssdp`, `usb`, `zeroconf`, `recorder`, `dhcp`, `bluetooth`, `network`, `webhook`, `repairs`, `analytics` y `backup`. Es el comportamiento por defecto que el doc oficial recomienda; sin esto el YAML mínimo es insuficiente y la UI no carga. |
| `homeassistant.latitude/longitude` | Necesarios para la integración `sun` (amaneceres/atardeceres → automatizaciones tipo "encender porche al ponerse el sol"), `weather`, `presence detection` por zonas. Las coordenadas no son un secreto duro pero conviene ponerlas en `secrets.yaml`. |
| `homeassistant.time_zone` | HA respeta `TZ` del entorno, pero **además** quiere la zona explícita en YAML para que sea reproducible al restaurar de un backup en otra máquina. |
| `homeassistant.external_url` / `internal_url` | La mobile app y los enlaces de notificación construyen URLs absolutas. Si solo se conoce una y se accede por la otra, los links rompen (mailto/click → 404 en LAN). HA dispone los dos campos justo por esto. |
| `http.use_x_forwarded_for` + `trusted_proxies` | Sin esto, `X-Forwarded-For` se ignora y HA loguea como IP de origen `172.20.0.X` (la de Caddy) para todo cliente. Bloquea fail2ban (no detecta logins fallidos por IP real) y rompe `mobile_app` que usa rate-limit por IP. La lista `trusted_proxies` es **estricta**: solo la subred bridge de Docker. NUNCA poner `0.0.0.0/0` aquí (HA aceptaría cualquier `X-Forwarded-For` falso). |
| `logger.default: warning` | Reduce el volumen del log a warnings/errors. `info` solo para http/api durante el bootstrap; cuando todo va estable, bajar a `warning` también esos. Sin override, HA loguea ~100 MB/día de "info" prácticamente vacío. |
| `recorder.purge_keep_days: 14` | Mantiene 2 semanas de histórico en la BD. Suficiente para gráficos en Lovelace; menos peso que el default (10 días, pero con eventos/estados sin filtrar). Para retención larga, se exporta a Prometheus (Fase 5) con la integración `prometheus`, que lo cubre [`../05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md). |
| `recorder.exclude.domains` | `automation` y `updater` generan eventos por segundo si hay automations activas. Excluirlos del recorder reduce la BD a ~50–100 MB sostenidos. |
| `automation: !include automations.yaml` | La UI de HA escribe automations en este fichero por GUI. Si no existe el include, la UI muestra "you haven't configured automations via YAML, edit them via the UI" — que **es lo que se quiere**, pero exige el fichero existente o falla el `check_config`. |
| `frontend.themes:` | Misma lógica: si hay temas custom, viven en `themes/`. La UI los descubre por este `include_dir`. |
| **No** `ip_ban_enabled` | Razón: ver tabla de §4.1. Banear por `X-Forwarded-For` reescrito por Caddy = autobloqueo del operador. Fail2ban actúa antes (a nivel de red, leyendo logs de Caddy) y mantiene a HA fuera del bucle. |
| **No** se declara `mqtt:` aquí | La integración `mqtt` se configura por la UI (Settings → Devices & Services → Add → MQTT) tras el primer login. Esto evita escribir credenciales del broker en YAML; van en `.storage/core.config_entries` cifradas con la KeystoreSecret de HA. Detalle en §8.2. |

---

## 5. `docker-compose.yml`

`~/homelab/stacks/homeassistant/docker-compose.yml`:

```yaml
# ~/homelab/stacks/homeassistant/docker-compose.yml
# Stack: homeassistant (../02-docker/02-estructura-compose.md §1.1).
# Datos en /mnt/hd2t/services/home-assistant/.
# Backups nativos en /mnt/hd2t/backups/dumps/homeassistant/ (compartido con Borgmatic).

name: homeassistant

services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:${HA_IMAGE_TAG}
    container_name: homeassistant
    hostname: homeassistant
    restart: unless-stopped
    env_file: /mnt/hd2t/services/home-assistant/.env

    environment:
      TZ: ${TZ}

    volumes:
      # Configuración + BD + .storage/ + custom_components/.
      - /mnt/hd2t/services/home-assistant/config:/config
      # Backups nativos: HA escribe aquí cuando se invoca backup.create.
      - /mnt/hd2t/backups/dumps/homeassistant:/backup
      # TZ y reloj sincronizados con el host (no escribible).
      - /etc/localtime:/etc/localtime:ro

    # Sin `ports:` — HA solo es accesible vía Caddy por la red `homelab`.
    # Si el operador necesita mDNS/Bonjour, usar la variante §13.1
    # (network_mode: host) que SUSTITUYE a esta sección de networks.
    networks:
      - homelab

    # Recursos: HA puede consumir mucha RAM con muchas integraciones (>1 GB
    # con HACS + 50 entidades). Limitar evita OOM en el host.
    mem_limit: 2g
    mem_reservation: 512m

    # Healthcheck: GET / devuelve 200 si HA está completamente arrancado.
    # Algunas integraciones tardan ~60s en estar disponibles tras el up.
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:8123/ -o /dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s

    labels:
      # Watchtower: NO actualizar automáticamente — política, ../02-docker/04-watchtower.md §6.
      com.centurylinklabs.watchtower.enable: "false"
      # Para Dozzle: agrupar logs.
      dev.dozzle.group: "homeassistant"

networks:
  homelab:
    external: true
```

### 5.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `name: homeassistant` | Nombre del proyecto Compose. Coincide con el nombre del stack y con el `name:` declarado en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §1.1 para Fase 8. |
| `image: ghcr.io/home-assistant/home-assistant:${HA_IMAGE_TAG}` | Tag pinned vía `.env`. La imagen oficial vive en GHCR, no en Docker Hub (Docker Hub `homeassistant/home-assistant` es un mirror del proyecto antiguo, **no** se mantiene). |
| `container_name: homeassistant` / `hostname: homeassistant` | Nombre estable para que Caddy llegue por DNS (`reverse_proxy http://homeassistant:8123`). Sin esto, Compose le pone un nombre tipo `homeassistant_homeassistant_1` y rompe el DNS interno. |
| `env_file: /mnt/hd2t/services/home-assistant/.env` | Carga de variables — patrón estándar del homelab. |
| `environment.TZ` | HA lee `TZ` para los logs (timestamps en zona local). El YAML `time_zone` ya cubre la lógica de automation, pero los logs salen en UTC sin esto. |
| `volumes: /mnt/hd2t/services/home-assistant/config:/config` | Bind mount canónico. Sin `:Z`/`:z` (no SELinux en Pi OS). |
| `volumes: /mnt/hd2t/backups/dumps/homeassistant:/backup` | El servicio `backup.create` de HA escribe en `/backup` por defecto. El bind compartido permite que Borgmatic los archive **sin** acoplarse a la API de HA. |
| `volumes: /etc/localtime:ro` | Sincroniza la zona del host con el contenedor. Backup ante un usuario que olvide poner `TZ` en `.env`. |
| `networks: [homelab]` | Solo la red compartida. Caddy ya está ahí; otros contenedores Z2M/Mosquitto/Node-RED también se enchufarán a `homelab` y se ven entre sí por DNS Docker. |
| `mem_limit: 2g` | HA con HACS + 50 entidades puede tocar 1.5 GB. 2 GB de tope deja margen y evita que un leak baje toda la Pi (que tiene 8 GB compartidos con todos los servicios). |
| `mem_reservation: 512m` | Garantía mínima en presión de memoria. HA arranca con ~400 MB; reservar 512 MB asegura un arranque limpio incluso con el host saturado. |
| `healthcheck` | Permite a Watchtower/Compose saber si el contenedor está sano. `start_period: 120s` cubre el primer arranque cuando HA construye la BD inicial. `curl` está en la imagen oficial (es necesaria para sus propias integraciones que descargan HACS, etc.). |
| `com.centurylinklabs.watchtower.enable: "false"` | Watchtower por opt-in en el homelab ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §0). HA está explícitamente excluido. |
| `dev.dozzle.group: "homeassistant"` | Cuando Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)) levante, agrupa todos los contenedores de Fase 8 (HA, Mosquitto, Z2M, Node-RED) bajo el mismo grupo. |
| `networks.homelab.external: true` | Patrón de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.4: la red se crea **una vez** durante el bootstrap; aquí solo se consume. |

### 5.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/homeassistant
docker compose --env-file /mnt/hd2t/services/home-assistant/.env config

# Esperado: salida YAML resuelta sin warnings.
# - El `image` debe estar plenamente cualificado: ghcr.io/.../home-assistant:2025.10
# - Sin warning "variable X not set".
# - `volumes` con paths absolutos.
```

---

## 6. Despliegue

### 6.1. Levantar el stack

```bash
cd ~/homelab/stacks/homeassistant
docker compose --env-file /mnt/hd2t/services/home-assistant/.env up -d
```

El primer `up` tarda **~2–3 minutos** porque HA:

1. Descarga la imagen (~1.5 GB en arm64).
2. Ejecuta `homeassistant.bootstrap` que materializa `home-assistant_v2.db` (SQLite) y `.storage/`.
3. Carga `default_config:`, lo cual descubre integraciones zeroconf (en red bridge no descubre nada — esperado), USB (no hay), etc.
4. Levanta el frontend en `:8123`.

### 6.2. Estado de los contenedores

```bash
docker compose --env-file /mnt/hd2t/services/home-assistant/.env ps

# Esperado, tras ~3 minutos:
# NAME            IMAGE                                                   STATUS                  PORTS
# homeassistant   ghcr.io/home-assistant/home-assistant:2025.10           Up X (healthy)
```

Si tras 5 minutos el estado sigue siendo `(starting)`:

```bash
docker compose --env-file /mnt/hd2t/services/home-assistant/.env logs --tail=200 homeassistant

# Buscar líneas tipo:
# - "Setup of domain X took Y seconds": carga normal.
# - "Setup failed for X: ...": un componente falla; revisar configuration.yaml.
# - "Unable to find a free port": colisión (no debería pasar sin `ports:`).
```

### 6.3. Onboarding inicial

HA expone su UI en `http://homeassistant:8123` (red `homelab`). Caddy aún no lo enruta hasta §7. Para el primer onboarding, dos opciones:

**Opción A — Via Caddy (preferida)**: completar §7 antes de hacer el onboarding. La UI de bienvenida aparece en `https://ha.lan`.

**Opción B — Tunnel SSH temporal**: si la persona quiere validar HA antes de tocar Caddy:

```bash
# Desde el laptop del operador, redirigir 8123 local al contenedor.
# (requiere acceso SSH al host con clave).
ssh -L 8123:127.0.0.1:8123 homelab@pi.lan -- \
  socat TCP-LISTEN:8123,reuseaddr,fork TCP:homeassistant:8123
# (o más simple: usar `docker exec -it homeassistant curl localhost:8123` para validar 200).
```

> En la práctica el flujo recomendado es **Opción A**: completar §7, abrir `https://ha.lan`, cumplir el wizard de "Crear cuenta". La cuenta `Owner` se crea entonces.

El wizard pide:

1. Nombre, usuario, contraseña del `Owner`.
2. Detección de la zona (HA usa el `latitude`/`longitude` del YAML como sugerencia).
3. Selección de unidades (HA respeta `unit_system: metric` del YAML).
4. "Detectar dispositivos en mi red": **clic en "Skip"** porque la red `homelab` (bridge) no propaga zeroconf. Las integraciones se añaden manualmente en §8.

---

## 7. Integración con Caddy

### 7.1. Añadir el bloque `ha.{$LAN_DOMAIN}` al `Caddyfile`

Editar `~/homelab/stacks/proxy/Caddyfile`. En la sección "Placeholders" del Caddyfile ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3) descomentar/añadir:

```caddy
# Home Assistant (../08-domotica/01-home-assistant.md)
ha.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # WebSockets son críticos: Lovelace los usa para refrescar estado en vivo.
    # Caddy los reenvía transparentemente con `reverse_proxy`; aquí no hace
    # falta directiva especial. Mantener `header_up` por consistencia con Pi-hole.
    reverse_proxy http://homeassistant:8123 {
        header_up Host {host}
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
    }
}
```

Y el bloque Tailscale gemelo (comentado hasta tener cert vía `tailscale cert`):

```caddy
# ha.{$TS_DOMAIN} {
#     import tailscale_tls ha
#     import security_headers
#     reverse_proxy http://homeassistant:8123 {
#         header_up Host {host}
#         header_up X-Forwarded-Proto https
#         header_up X-Real-IP {remote_host}
#     }
# }
```

Recargar Caddy:

```bash
cd ~/homelab/stacks/proxy
docker compose --env-file /mnt/hd2t/services/proxy/.env exec caddy \
  caddy reload --config /etc/caddy/Caddyfile

# Esperado: "successfully reloaded".
# Si falla: la salida indica la línea problemática del Caddyfile.
```

### 7.2. Trusted proxies en HA

El bloque `http.trusted_proxies` del `configuration.yaml` (§4.1) **ya cubre** la red `homelab` (`172.20.0.0/24`). Verificar que el contenedor lo lee:

```bash
docker exec homeassistant python3 -c "
import yaml
with open('/config/configuration.yaml') as f:
    cfg = yaml.safe_load(f)
print(cfg.get('http', {}))
"
# Esperado: {'server_host': '0.0.0.0', 'server_port': 8123, 'use_x_forwarded_for': True, 'trusted_proxies': ['172.20.0.0/24']}
```

Si HA fue instalado **antes** de añadir esta sección, los headers no se respetarán hasta el siguiente reinicio:

```bash
docker compose --env-file /mnt/hd2t/services/home-assistant/.env restart homeassistant
```

### 7.3. Registro DNS local en Pi-hole

Pi-hole debe resolver `ha.lan → IP de la Pi`. Vía UI Pi-hole (Local DNS → DNS Records) o vía CLI:

```bash
# IP de la Pi en la LAN (consistente con el resto de servicios).
PI_IP=192.168.1.10   # ajustar a la IP real

docker exec pihole bash -c "
  echo '${PI_IP} ha.lan' >> /etc/pihole/custom.list
  pihole restartdns
"

# Verificar desde el host:
dig +short ha.lan @127.0.0.1
# Esperado: ${PI_IP}
```

### 7.4. Probar el acceso

```bash
# Desde el host (curl debe seguir cert vía CA interna de Caddy):
curl --cacert /etc/ssl/certs/caddy-root.crt -sS https://ha.lan/ | head -20
# Esperado: HTML con <title>Home Assistant</title>.

# Sin --cacert (un cliente que aún no haya importado el CA local):
curl -k -sS https://ha.lan/ | head -20
# Esperado: igual al anterior; si responde 502/504 → revisar §12.
```

Y desde un navegador con la CA interna importada:

1. Abrir `https://ha.lan`.
2. Aparece el wizard de onboarding de §6.3.
3. Crear el usuario `Owner` y completar el wizard.

### 7.5. (Opcional) Proteger con Authelia

> **Cuándo activar**: Authelia delante de HA es opt-in. Las apps móviles oficiales (`Home Assistant Companion`) usan `Bearer <long_lived_token>` y **rompen** si Authelia las redirige al portal. La activación es segura **solo** si se documenta el bypass de §7.5.2.

#### 7.5.1. Activar `forward_auth` para la UI

Editar el bloque `ha.{$LAN_DOMAIN}` del Caddyfile añadiendo el snippet `authelia_proxy` ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §9.1):

```caddy
ha.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # ⚠️ Bypass crítico: la app móvil y los webhooks usan tokens long-lived.
    # Cualquier Authelia delante rompe HA Companion silenciosamente.
    @ha_api {
        path /api/* /auth/token /auth/* /local/* /static/* /service_worker.js /manifest.json
    }
    reverse_proxy @ha_api http://homeassistant:8123 {
        header_up Host {host}
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
    }

    # Resto de rutas (UI web): protegidas por Authelia.
    import authelia_proxy
    reverse_proxy http://homeassistant:8123 {
        header_up Host {host}
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
        header_up Remote-User {http.auth.user.preferred_username}
        header_up Remote-Groups {http.auth.user.groups}
    }
}
```

#### 7.5.2. Lista de rutas que **no** deben pasar por Authelia

| Ruta | Por qué bypass |
|---|---|
| `/api/*` | Endpoint REST/WebSocket. Los `Bearer` tokens de mobile_app/Node-RED viajan por aquí. Authelia rechaza por no haber sesión. |
| `/auth/token`, `/auth/*` | Flujo OAuth interno de HA. Si lo intercepta Authelia, el primer login de la mobile app falla con `oauth_error`. |
| `/local/*` | Ficheros estáticos custom (imágenes para Lovelace cards). Sin sesión web → 401. |
| `/static/*` | Assets del frontend. La página de login de Authelia los pide sin cookie HA → bucle. |
| `/service_worker.js`, `/manifest.json` | PWA: el navegador los pide en background sin cookie. |

#### 7.5.3. Regla en `configuration.yml` de Authelia

Si se quiere que ciertos usuarios accedan **solo** con 2FA (admins) y otros con un solo factor (lectura), declarar en `configuration.yml`:

```yaml
# fragmento — el resto del fichero está en ../04-seguridad/01-authelia.md §5
access_control:
  default_policy: deny
  rules:
    # ... reglas del resto de servicios ...
    - domain: "ha.{{ env \"LAN_DOMAIN\" }}"
      policy: two_factor
      subject: ["group:admins"]
    - domain: "ha.{{ env \"LAN_DOMAIN\" }}"
      policy: one_factor
      subject: ["group:family"]
```

Y dentro de HA, añadir el provider **trusted_networks** (opcional) para que cuando se acceda desde IP de Authelia con cabecera `Remote-User` correcta, HA cree sesión sin login adicional:

```yaml
# /config/configuration.yaml — extender homeassistant:
homeassistant:
  # ... bloque existente ...
  auth_providers:
    - type: homeassistant
    - type: trusted_networks
      trusted_networks:
        - 172.20.0.0/24   # Caddy + Authelia están en homelab
      trusted_users:
        172.20.0.0/24:
          - <user-id-de-HA>   # rellenar tras crear el usuario en Settings → People
      allow_bypass_login: false
```

> **Cuidado**: `trusted_networks` con red Docker amplia significa que **cualquier** contenedor en `homelab` que llame a `/auth/login_flow` se autenticaría. La mitigación es Authelia: solo Caddy llega a `/auth/login_flow` con la cabecera `Remote-User`. Si el operador no tiene Authelia, **no** activar `trusted_networks` (riesgo > beneficio).

---

## 8. Configuración post-despliegue

### 8.1. Crear el usuario `Owner` y usuarios secundarios

El primer login del wizard crea el `Owner` (admin total). Para usuarios adicionales (familia, invitados):

1. Settings → People → "Add Person".
2. Marcar "Allow person to log in".
3. Generar password (HA fuerza ≥ 8 chars).
4. Asignar a grupos: `admins` (acceso total), o sin grupo (lectura + control de entidades autorizadas).

### 8.2. Integración MQTT (Mosquitto)

Cuando [`./02-mosquitto.md`](./02-mosquitto.md) esté desplegado:

1. Settings → Devices & Services → Add Integration → buscar "MQTT".
2. Broker: `mosquitto` (nombre Docker en red `homelab`).
3. Port: `1883`.
4. Username/Password: los que `02-mosquitto.md` haya creado para el cliente `homeassistant`.
5. Submit. HA verifica conexión y publica el "MQTT Discovery" en `homeassistant/+/+/+/config`.

Verificación:

```bash
docker exec mosquitto mosquitto_sub -t '$SYS/broker/clients/connected' -C 1
# Esperado: número de clientes activos (≥ 1, HA ya cuenta).

docker exec mosquitto mosquitto_sub -t 'homeassistant/#' -v -C 5
# Esperado: discovery messages tipo "homeassistant/sensor/.../config".
```

### 8.3. Integración Zigbee2MQTT

Z2M se descubre **automáticamente** vía MQTT Discovery cuando `./03-zigbee2mqtt.md` esté operativo. No requiere configuración manual desde HA. Las entidades aparecen en Settings → Devices & Services → Devices con marca "Discovered via MQTT".

### 8.4. Sincronización con Prometheus (opcional)

Si la Fase 5 está completa ([`../05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md)), HA puede exponer métricas:

```yaml
# /config/configuration.yaml — añadir
prometheus:
  namespace: homeassistant
  filter:
    include_domains:
      - sensor
      - binary_sensor
      - climate
      - light
```

Y añadir el target a Prometheus:

```yaml
# ~/homelab/stacks/monitoring/prometheus/prometheus.yml — bajo scrape_configs:
  - job_name: home_assistant
    metrics_path: /api/prometheus
    bearer_token_file: /etc/prometheus/ha_token
    static_configs:
      - targets: ['homeassistant:8123']
```

Y crear `/mnt/hd2t/services/monitoring/prometheus/ha_token` con un Long-Lived Access Token de HA (Profile → "Long-Lived Access Tokens" → Create Token).

---

## 9. Verificación

### 9.1. Contenedor sano

```bash
docker compose --env-file /mnt/hd2t/services/home-assistant/.env ps

# STATUS de homeassistant: "Up X (healthy)".
```

### 9.2. HA escucha solo dentro de la red `homelab`

```bash
sudo ss -ltn | grep 8123
# Esperado: VACÍO. El puerto 8123 no se publica al host.

docker exec homeassistant ss -ltn | grep 8123
# Esperado: "LISTEN ... 0.0.0.0:8123".
```

### 9.3. Log sin errores graves

```bash
sudo tail -100 /mnt/hd2t/services/home-assistant/config/home-assistant.log

# Aceptable:
# - WARNING [homeassistant.config_entries] Setup of <integration> ...
# - INFO [homeassistant.bootstrap] Waiting on integrations to complete setup
# Inaceptable:
# - ERROR [homeassistant.bootstrap] Error during setup of component X
# - CRITICAL [...] Stopping
```

### 9.4. Trusted proxies activo

```bash
# Acceder a /api/ con un cliente externo (debería rechazar sin token):
curl -sS -H "X-Forwarded-For: 1.2.3.4" -H "Host: ha.lan" \
  http://172.20.0.X:8123/api/   # IP del contenedor en `homelab`

# Esperado: "401: Unauthorized" — HA acepta el header (X-Forwarded-For tiene
# IP "1.2.3.4" en logs) PERO el endpoint requiere token. Eso prueba que:
#  - HA escucha,
#  - acepta proxies,
#  - el resto del control de acceso funciona.
```

### 9.5. Smoke test desde el navegador

1. Abrir `https://ha.lan` con la CA interna importada.
2. Login con el usuario `Owner` (creado en §6.3).
3. Verificar:
   - Sidebar muestra Overview, Map, History, Logbook, Developer Tools, Configuration.
   - Settings → System → System Health → "All checks passed" (o solo warnings de Cloud).
   - Settings → System → Hardware → CPU usage < 30%, Memory < 600 MB.

### 9.6. Persistencia tras reboot

```bash
sudo reboot
# Esperar ~90 segundos.

ssh homelab@pi.lan -- 'docker compose --env-file /mnt/hd2t/services/home-assistant/.env -f ~/homelab/stacks/homeassistant/docker-compose.yml ps'
# Esperado: homeassistant Up X (healthy).

# La sesión del navegador sobrevive si la cookie HA no expiró.
# Login flow funciona idéntico tras restart.
```

### 9.7. Lista de Verificación

- [ ] `/mnt/hd2t/services/home-assistant/config/configuration.yaml` existe y se valida con `docker exec homeassistant python3 -m homeassistant --script check_config -c /config`.
- [ ] `docker compose ps` lista `homeassistant` como `(healthy)`.
- [ ] `sudo ss -ltn | grep 8123` no devuelve nada (HA no expuesto al host).
- [ ] `dig +short ha.lan @<pi-ip>` resuelve a la IP de la Pi.
- [ ] `curl -k https://ha.lan/` devuelve HTML con `<title>Home Assistant</title>`.
- [ ] El operador hace login con `Owner` y ve la UI sin errores.
- [ ] `Settings → System → System Health` muestra todos los checks en verde (excepto HA Cloud, opt-in).
- [ ] `tail home-assistant.log` no muestra `ERROR` repetidos.
- [ ] (Si Authelia activo) la URL `https://ha.lan/api/` devuelve `401 Unauthorized` desde curl, NO la página de login de Authelia.
- [ ] (Si Authelia activo) la URL `https://ha.lan/lovelace` redirige a `auth.lan` para usuarios sin sesión.
- [ ] El backup automático nocturno (§10) materializa un `.tar` en `/mnt/hd2t/backups/dumps/homeassistant/`.

---

## 10. Backup

> **Estrategia general**: HA tiene su propio sistema de "snapshots" (renombrado a "Backups" en 2024) que serializa configuración + BD + `.storage/` en un único `.tar`. El homelab fuerza este `.tar` a `/mnt/hd2t/backups/dumps/homeassistant/` (vía bind mount `/backup`); Borgmatic lo archiva con deduplicación. **Doble cobertura** ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §5.1):
>
> - **Backup nativo (`.tar`)**: rápido de restaurar sobre HA virgen ("Restore from backup" en el wizard de onboarding).
> - **Bind mount completo**: Borgmatic ya respalda `/mnt/hd2t/services/home-assistant/config/` como ficheros sueltos. Permite cherry-picking de un único `automations.yaml` sin restaurar el `.tar` completo.

### 10.1. Backup automático diario (servicio `backup.create`)

Crear una automation desde la UI (Settings → Automations → "Create new"):

```yaml
# UI exporta esto a /config/automations.yaml.
- alias: "Backup nocturno"
  description: "Snapshot de HA cada noche a las 03:00, escrito en /backup."
  trigger:
    - platform: time
      at: "03:00:00"
  action:
    - service: backup.create
      data:
        # Nombre con timestamp para que Borgmatic deduplique entre días.
        name: "homelab-{{ now().strftime('%Y%m%d-%H%M') }}"
  mode: single
```

> **Por qué desde automation y no desde un cron del host**: el `backup.create` por API requiere token long-lived, lo cual es viable pero **añade un secreto** que rota. Usar la automation interna no expone tokens a fail2ban/logs.

Verificar que se está ejecutando:

```bash
ls -lh /mnt/hd2t/backups/dumps/homeassistant/
# Esperado, tras una noche:
# -rw-r--r-- 1 root root 250M ... homelab-20260127-0300.tar

# Logs de la automation:
sudo grep "backup.create" /mnt/hd2t/services/home-assistant/config/home-assistant.log | tail -5
# Esperado: "Backup created: homelab-..." sin "Backup failed".
```

### 10.2. Borgmatic

[`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) ya incluye `/mnt/hd2t/backups/dumps/homeassistant/` y `/mnt/hd2t/services/home-assistant/config/` en sus `source_directories`. No requiere cambios específicos.

> **No** declarar la BD SQLite de HA como `databases:` en Borgmatic. El `.backup` de SQLite es **redundante** con el `.tar` de HA (que ya incluye `home-assistant_v2.db` con consistencia transaccional vía la API interna de HA). Declarar lo dos duplica el coste sin ganancia.

### 10.3. Restore (resumen)

Procedimiento canónico — la receta extendida vive en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md) §2.3 + §4.

**Caso A — Restore desde `.tar` nativo (Disaster Recovery)**:

1. Reinstalar HA Container con `docker compose up -d` (recrea `/config` virgen).
2. Abrir `https://ha.lan` → wizard pregunta "¿Restaurar desde backup?".
3. Subir el `.tar` desde el laptop (o copiarlo a `/config/backups/<name>.tar` y la UI lo detecta).
4. HA aplica el `.tar`, reinicia, y vuelve al estado previo.

**Caso B — Restore de un fichero suelto (p. ej. `automations.yaml`)**:

```bash
sudo borgmatic extract \
  --archive latest \
  --path mnt/hd2t/services/home-assistant/config/automations.yaml \
  --destination /tmp/restore-ha

sudo cp /tmp/restore-ha/mnt/hd2t/services/home-assistant/config/automations.yaml \
  /mnt/hd2t/services/home-assistant/config/automations.yaml

# Recargar automations sin reiniciar HA:
docker exec homeassistant python3 -c "
import requests, os
url = 'http://localhost:8123/api/services/automation/reload'
token = os.environ.get('HA_LL_TOKEN', '')
print(requests.post(url, headers={'Authorization': f'Bearer {token}'}).status_code)
"
# (alternativa: Settings → Developer Tools → YAML → "Reload Automations").
```

### 10.4. Smoke test L3 (mensual)

Cuando la rotación de smoke tests ([`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md) §8.3) toque "Home Assistant":

1. Levantar contenedor HA temporal apuntando a `/mnt/hd2t/backups/restore-test/ha-YYYY-MM-DD/`.
2. Cargar el último `.tar` desde la UI.
3. Verificar que aparecen al menos 3 entidades del set principal del operador.
4. `sudo rm -rf` el directorio.
5. Anotar resultado en `~/homelab/operations/restore-tests.log`.

---

## 11. Operaciones cotidianas

### 11.1. Upgrade manual (mensual o tras release)

```bash
# 1. Leer las release notes:
# https://www.home-assistant.io/blog/categories/release-notes/
# Buscar la sección "Backward-incompatible changes" — si afecta a algo del
# homelab (mqtt, recorder, http, alguna integración usada), planear el upgrade.

# 2. Forzar un backup previo manualmente (UI: Settings → System → Backups → Create).
#    O por CLI:
docker exec homeassistant python3 -c "
import requests, os
token = os.environ['HA_LL_TOKEN']
r = requests.post('http://localhost:8123/api/services/backup/create',
  headers={'Authorization': f'Bearer {token}'},
  json={'name': 'pre-upgrade-' + __import__('datetime').datetime.now().strftime('%Y%m%d')})
print(r.status_code, r.text)
"
# (alt: solo desde la UI).

# 3. Actualizar el tag en /mnt/hd2t/services/home-assistant/.env:
sudo nano /mnt/hd2t/services/home-assistant/.env
# Cambiar HA_IMAGE_TAG=2025.10 → HA_IMAGE_TAG=2025.11

# 4. Pull + recreate.
cd ~/homelab/stacks/homeassistant
docker compose --env-file /mnt/hd2t/services/home-assistant/.env pull
docker compose --env-file /mnt/hd2t/services/home-assistant/.env up -d

# 5. HA detecta diferencia de versión y migra automáticamente la BD.
#    Verificar:
docker compose --env-file /mnt/hd2t/services/home-assistant/.env logs --tail=200 homeassistant | grep -E '(version|migration|error)'
# Esperado: "Setting up homeassistant" → "Started Home Assistant".
# Si aparece error de migración, ROLLBACK: cambiar el tag al anterior y up -d.

# 6. Confirmar estado:
curl -k -sS https://ha.lan/api/ | head -3
# Esperado: HTML con la versión nueva.

# 7. Settings → System → System Health → todos los checks verdes.
```

### 11.2. Logs

```bash
# Tail en vivo:
sudo tail -F /mnt/hd2t/services/home-assistant/config/home-assistant.log

# Filtrar errores:
sudo grep -E 'ERROR|CRITICAL' /mnt/hd2t/services/home-assistant/config/home-assistant.log | tail -30

# Vía Docker (todo el contenedor, no solo el log de HA):
docker compose --env-file /mnt/hd2t/services/home-assistant/.env logs --tail=200 -f homeassistant

# Vía Dozzle (../05-monitorizacion/06-dozzle.md), navegador → grupo "homeassistant".
```

### 11.3. CLI operativa (sin add-on Terminal de HAOS)

HA Container **no tiene** `ha` CLI. Equivalentes:

| Necesidad | Comando |
|---|---|
| Validar `configuration.yaml` | `docker exec homeassistant python3 -m homeassistant --script check_config -c /config` |
| Recargar automations sin reiniciar | UI: Developer Tools → YAML → "Automations" / API: `POST /api/services/automation/reload` |
| Restart full | `docker compose restart homeassistant` o UI: Developer Tools → YAML → "Home Assistant Core" → Restart |
| Lista de entidades | UI: Developer Tools → States |
| Llamar un servicio manual | UI: Developer Tools → Services |
| Importar usuario nuevo | UI: Settings → People → Add (no hay CLI) |
| Resetear password de usuario | UI: Settings → People → seleccionar → ⋯ → "Change password" (Owner reseteable solo desde la propia UI tras login; si se pierde, restore desde `.tar`) |

### 11.4. Comportamiento durante mantenimiento

```bash
# Pausar HA brevemente:
docker compose --env-file /mnt/hd2t/services/home-assistant/.env stop homeassistant
# La UI muestra error de conexión, las apps móviles entran en modo offline,
# los webhooks de Sonarr/Radarr/etc. apuntando a HA acumulan retry.

# ... operación de mantenimiento ...

docker compose --env-file /mnt/hd2t/services/home-assistant/.env start homeassistant
# Esperar ~90 segundos hasta (healthy).
# La sesión del navegador sobrevive (cookie sigue válida); las apps reconectan automáticamente.
```

---

## 12. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `502 Bad Gateway` de Caddy en `https://ha.lan` | HA aún arrancando (`(starting)`) o ha crasheado. | `docker compose ps` → confirmar `(healthy)`; `docker compose logs --tail=200 homeassistant` para ver el último error. Si está en `start_period`, esperar 90s. |
| HA logea `Loaded config from /config/configuration.yaml` y luego un `ERROR Setup failed for X: ...` | Una integración con sintaxis YAML rota o incompatible con la versión nueva. | `docker exec homeassistant python3 -m homeassistant --script check_config -c /config`. Comentar la sección rota y reiniciar. |
| Mobile app en LAN funciona, vía Tailscale aparece `Connection lost` | `external_url` no está configurada (HA construye links a `localhost`) o falta el bloque `ha.{$TS_DOMAIN}` en Caddy. | Editar `homeassistant.external_url: "https://ha.tailnet.ts.net"`, restart. Activar el bloque Tailscale en Caddyfile (§7.1). |
| Authelia delante de HA y la app móvil queda en bucle de "Sign in" | El bypass de §7.5.2 está incompleto: alguna ruta `/api/*` o `/auth/token` está siendo enrutada por `forward_auth`. | Confirmar el orden en el Caddyfile: el matcher `@ha_api` debe estar **antes** de `import authelia_proxy`. |
| `recorder` reporta `disk full` o la BD crece > 2 GB | `purge_keep_days` demasiado alto, o entidades muy ruidosas no excluidas. | Ajustar `recorder.purge_keep_days: 7` y `recorder.exclude.entities: [...]`. Forzar purga: Developer Tools → Services → `recorder.purge_entities`. |
| `mobile_app` no se registra (HTTP 401 al añadir un dispositivo) | El usuario que está añadiendo no tiene permiso, o hay un proxy intermedio sin `X-Forwarded-Proto: https`. | Confirmar `header_up X-Forwarded-Proto https` en el Caddyfile; confirmar que el usuario en HA puede crear long-lived tokens (Profile → check). |
| Logs spam con `Updating <X> takes more than 10 seconds` | Una integración es lenta (típico: `tuya`, `xiaomi_miio` con cloud caída). | Aceptable si es esporádico. Si es continuo, considerar `scan_interval` mayor en la integración o desactivarla. |
| `Setup failed for mqtt: cannot connect to broker` | Mosquitto down o credenciales incorrectas. | `docker compose ps mosquitto`; `docker compose logs mosquitto`. Reconfigurar la integración MQTT en HA con el password actual. |
| `network_mode: host` activo y otros contenedores no llegan a HA | En `host` mode, HA escucha en `<host_ip>:8123`, no en la red `homelab`. Caddy `reverse_proxy http://homeassistant:8123` falla. | Usar `host.docker.internal:8123` o la IP del host (`172.17.0.1:8123` típicamente). Detalle en §13.1. |
| `Restart` desde la UI nunca termina (spinner infinito) | HA está reiniciando el proceso interno, no el contenedor; si la BD del recorder está bloqueada, el proceso no termina. | `docker compose restart homeassistant` desde el host. Si es recurrente, mover el recorder a otra BD (PostgreSQL). |
| El `.tar` de backup pesa < 5 KB | El servicio `backup.create` falló silenciosamente; HA dejó solo el header. | `sudo grep -E 'Backup (created|failed)' /mnt/hd2t/services/home-assistant/config/home-assistant.log`. Comprobar permisos de `/backup` (debe ser escribible por root). |

---

## 13. Variantes opt-in

### 13.1. `network_mode: host` para mDNS / Bonjour

**Cuándo activar**: si el operador necesita integraciones que dependen de descubrimiento multicast nativo (HomeKit Bridge, Google Cast, Sonos, Apple TV, esphome con `dashboard_import`).

**Cambio en `docker-compose.yml`**:

```yaml
services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:${HA_IMAGE_TAG}
    container_name: homeassistant
    hostname: homeassistant
    restart: unless-stopped
    env_file: /mnt/hd2t/services/home-assistant/.env
    environment:
      TZ: ${TZ}
    volumes:
      - /mnt/hd2t/services/home-assistant/config:/config
      - /mnt/hd2t/backups/dumps/homeassistant:/backup
      - /etc/localtime:/etc/localtime:ro

    # SUSTITUYE 'networks: [homelab]' por host mode.
    network_mode: host

    # ... resto idéntico ...
```

**Coste de activarlo**:

- Caddy ya no llega a `homeassistant:8123` por DNS Docker. Hay que cambiar el bloque del Caddyfile a `reverse_proxy http://host.docker.internal:8123` (Compose define `host.docker.internal` como alias del host en arm64 a partir de Docker 24+; verificar con `docker exec caddy getent hosts host.docker.internal`).
- HA queda accesible en `http://<ip-de-la-pi>:8123` desde la LAN, **bypass-eando Caddy** (sin TLS). El operador debe **confiar en fail2ban** y `ufw` para que solo Tailscale/LAN local lleguen al puerto.
- `trusted_proxies` debe ampliarse a la subred LAN real (p. ej. `192.168.1.0/24`).

### 13.2. Bluetooth (`/run/dbus`)

**Cuándo activar**: para BLE proxies (botones Shelly BLU, sensores Xiaomi BT, presence tracking por RSSI).

**Cambio en `docker-compose.yml`**:

```yaml
services:
  homeassistant:
    # ... resto ...
    volumes:
      # ... volumes existentes ...
      - /run/dbus:/run/dbus:ro
    privileged: false
    cap_add:
      - NET_ADMIN
      - NET_RAW
```

**Verificar** desde la UI: Settings → Devices & Services → Add → "Bluetooth" debe descubrir el adaptador on-board de la Pi 5.

> Para Bluetooth, si se hace coexistencia con Z2M USB Zigbee, el adaptador BT on-board de la Pi 5 sirve para BLE — no se requiere dongle adicional.

### 13.3. HACS (Home Assistant Community Store)

**Cuándo activar**: para integraciones/themes/cards de la comunidad (no oficiales).

**Procedimiento** (todo desde dentro del contenedor):

```bash
docker exec homeassistant bash -c '
  wget -O - https://get.hacs.xyz | bash -
'
# Esto descarga HACS a /config/custom_components/hacs/.

docker compose --env-file /mnt/hd2t/services/home-assistant/.env restart homeassistant
```

Tras el restart:

1. Settings → Devices & Services → Add Integration → buscar "HACS".
2. Seguir wizard que pide un GitHub Personal Access Token (HACS clona repos vía API GH).
3. Aceptar términos.

**Coste**:

- **Riesgo de seguridad**: HACS instala código Python arbitrario de GitHub. Solo instalar repos con muchas estrellas, mantenidos, y leyendo el código.
- **Watchtower**: HACS gestiona sus propios updates desde la UI; no afecta al contenedor.
- **Backup**: el `.tar` nativo de HA incluye `custom_components/`, así que HACS y todo lo instalado está cubierto.

### 13.4. PostgreSQL en lugar de SQLite para `recorder`

**Cuándo activar**: si la BD SQLite supera 2 GB (≥ 100 entidades muy activas) o el operador quiere histórico ≥ 6 meses sin penalización.

Patrón del homelab para BD compartida: añadir un `postgres-homeassistant` al stack como servicio gemelo (similar a `mariadb-nextcloud` en [`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md) §5).

```yaml
# Adicional al docker-compose.yml — fragmento:
services:
  postgres-homeassistant:
    image: postgres:16-alpine
    container_name: postgres-homeassistant
    restart: unless-stopped
    environment:
      POSTGRES_DB: homeassistant
      POSTGRES_USER: homeassistant
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    volumes:
      - /mnt/hd2t/services/home-assistant/postgres:/var/lib/postgresql/data
    secrets:
      - db_password
    networks:
      - homeassistant_internal

  homeassistant:
    # ... añadir red interna ...
    networks:
      - homelab
      - homeassistant_internal
    depends_on:
      - postgres-homeassistant

secrets:
  db_password:
    file: /mnt/hd2t/services/home-assistant/secrets/db_password

networks:
  homelab:
    external: true
  homeassistant_internal:
    driver: bridge
```

Y en `configuration.yaml`:

```yaml
recorder:
  db_url: "postgresql://homeassistant:!secret postgres_password@postgres-homeassistant:5432/homeassistant"
  purge_keep_days: 90   # ahora es viable mantener 3 meses
  auto_purge: true
```

> **Migración**: HA **no** migra automáticamente datos de SQLite a PostgreSQL. Al cambiar `db_url` se empieza con BD vacía. Para conservar histórico, exportar a CSV desde la UI antes de cambiar.

> **Backup**: con PostgreSQL, **sí** procede declarar la BD en Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §6) con `pg_dump --format=custom`. La regla "no duplicar el `.tar` de HA con SQLite" deja de aplicar — son dos motores distintos.

---

## Referencias

- **Imagen oficial**: https://github.com/home-assistant/core/pkgs/container/home-assistant
- **Docs Home Assistant Container**: https://www.home-assistant.io/installation/raspberrypi#docker-compose
- **Release notes (leer antes de cada upgrade)**: https://www.home-assistant.io/blog/categories/release-notes/
- **Configuración `http`**: https://www.home-assistant.io/integrations/http/
- **Configuración `recorder`**: https://www.home-assistant.io/integrations/recorder/
- **Backup (servicio `backup.create`)**: https://www.home-assistant.io/integrations/backup/
- **MQTT**: https://www.home-assistant.io/integrations/mqtt/
- **Trusted Networks auth provider**: https://www.home-assistant.io/docs/authentication/providers/#trusted-networks
- **Documentos del homelab relacionados**:
  - Despliegue del broker MQTT: [`./02-mosquitto.md`](./02-mosquitto.md)
  - Despliegue de Zigbee2MQTT: [`./03-zigbee2mqtt.md`](./03-zigbee2mqtt.md)
  - Despliegue de Node-RED: [`./04-node-red.md`](./04-node-red.md)
  - Reverse proxy Caddy: [`../03-red/04-caddy.md`](../03-red/04-caddy.md)
  - SSO/2FA Authelia: [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)
  - Política de Watchtower: [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)
  - Estrategia de backup: [`../07-backups/01-estrategia-backup.md`](../07-backups/01-estrategia-backup.md)
  - Borgmatic: [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
  - Restore de servicios: [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md)
