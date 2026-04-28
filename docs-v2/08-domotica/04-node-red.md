# Node-RED

## Descripción

Despliegue de **[Node-RED](https://nodered.org/)** ([imagen oficial `nodered/node-red`](https://hub.docker.com/r/nodered/node-red)) como **orquestador de flujos visuales** del homelab. Node-RED es la pieza que **conecta cosas** sin escribir scripts: arrastra "nodos" en una UI web, los conecta con cables, y cada cable es un mensaje (objeto JSON `{ topic, payload, ... }`) que va de un endpoint a otro. Es el complemento natural de [Home Assistant](./01-home-assistant.md): mientras HA es el **estado** y la **superficie de UI** del hogar, Node-RED es la **lógica imperativa** ("cuando X, entonces Y, salvo si Z y se ha hecho Q en los últimos 5 min").

En este homelab Node-RED actúa como tercer cliente de [Mosquitto](./02-mosquitto.md), junto con HA y [Zigbee2MQTT](./03-zigbee2mqtt.md), y se integra con HA por WebSocket (vía la paleta [`node-red-contrib-home-assistant-websocket`](https://flows.nodered.org/node/node-red-contrib-home-assistant-websocket)) para llamar servicios y leer entidades sin pasar por MQTT cuando no compensa. Su uso típico:

- **Automatizaciones complejas que serían un coñazo en YAML de HA** (loops temporales, máquinas de estado con varios timeouts, deduplicación de eventos).
- **Pegamento entre servicios externos**: un webhook de [Telegram](https://core.telegram.org/bots/api), un cron, un GET a una API meteorológica, un POST al webhook de [Uptime Kuma](../05-monitorizacion/05-uptime-kuma.md).
- **Pre-procesado de eventos MQTT** antes de publicarlos a HA (p.ej. filtrar el ruido de un sensor de movimiento Aqara con histeresis).

Este doc cubre, en orden:

1. **Por qué Node-RED** (no automations YAML de HA, no n8n, no Huginn) y qué se gana/pierde.
2. **Plan de variables y archivos**: `.env.example` versionable, `.env` real en `/mnt/hd2t/services/node-red/.env`, `data/` como bind mount único.
3. **`settings.js`** versionable: `credentialSecret` desde env, `adminAuth` con un usuario bcrypt como defense-in-depth tras Authelia, `editorTheme.projects.enabled: false` (Projects desactivado), logging por defecto.
4. **`docker-compose.yml`** con bind mount de `/data`, sin `ports:` (frontend vía Caddy), `depends_on` documental sobre Mosquitto.
5. **Caddy reverse proxy** para `nodered.lan` (TLS interno con CA local) + middleware Authelia para la UI del editor.
6. **Despliegue + alta de las paletas core** (`node-red-contrib-home-assistant-websocket`).
7. **Verificación funcional**: contenedor sano, conexión a Mosquitto con el usuario `nodered` (ACL `R #` + `RW nodered/#`), conexión a HA por WebSocket, primer flow "hello world".
8. **Operaciones cotidianas**: instalar/eliminar paletas, exportar/importar flows, rotar `credentialSecret` (con re-creación de credenciales), upgrade.
9. **Backup**: Borgmatic respalda `/mnt/hd2t/services/node-red/` íntegro — `data/flows.json` (lógica), `data/flows_cred.json` (credenciales cifradas con `credentialSecret`), `data/settings.js`, `data/lib/` (snippets reutilizables), `data/node_modules/` (paletas instaladas; opcional, se pueden reconstruir vía `package.json`).
10. **Variantes opt-in**: dashboard interactivo (`node-red-dashboard`), métricas Prometheus (`node-red-contrib-metrics`), feature `Projects` con git, exposición vía Tailscale, jail fail2ban del editor tras Authelia.

> **Alcance de red**: Node-RED **solo se accede vía la red Docker `homelab`**. El puerto `1880` **no se publica al host** por defecto: la única vía pública es `https://nodered.lan` vía Caddy con Authelia delante ([`../03-red/04-caddy.md`](../03-red/04-caddy.md), [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)). El acceso remoto se hace vía Tailscale ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) a la misma URL. Los flujos llaman a `http://homeassistant:8123`, `mqtt://mosquitto:1883`, etc., siempre por DNS Docker dentro de `homelab`.

---

## 0. ¿Por qué Node-RED y no automations YAML / n8n / Huginn?

| Opción | Pros | Cons | Veredicto homelab |
|---|---|---|---|
| **Node-RED** (elegida) | (1) **UI visual** trazable: cada flujo es un grafo navegable, fácil de auditar incluso meses después. (2) **Ecosistema de paletas** con >5000 nodos en [Flows Library](https://flows.nodered.org/) — desde Telegram a Modbus a InfluxDB. (3) **Desacoplado de HA**: si HA cae, los flujos vía MQTT siguen procesándose; HA es uno más entre los clientes. (4) **HA WebSocket nativo** vía `node-red-contrib-home-assistant-websocket`: ver eventos de HA en tiempo real, llamar servicios, leer estados sin polling. (5) **Stateless en disco**: la totalidad del estado vive en `/data` (flows.json + credentials + node_modules), backup trivial. (6) **Edita en caliente**: deploy parcial sin reiniciar el resto de flujos. | (1) Un servicio extra que mantener (vs automations YAML "incluido" en HA). (2) Las paletas las gestiona npm dentro del contenedor — pueden romperse en upgrades de Node-RED (`packageDependencies` en `package.json` del paquete). (3) Curva inicial: pensar en mensajes y flujos en vez de en triggers/conditions. | **Ganador**. Para automatizaciones con más de 2-3 condiciones temporales o deduplicación, YAML de HA explota; n8n no tiene la integración HA nativa; Huginn está en mantenimiento. |
| **HA Automations YAML / UI** | (1) Cero servicios extra. (2) Triggers/conditions/actions ya documentados. | (1) **Acoplamiento total a HA**: si HA cae, no hay flujos. (2) YAML rígido para flujos con timeouts (`wait_template` se anida y se vuelve ilegible). (3) UI de automatizaciones de HA da problemas con flujos > 10 acciones (la UI desempaqueta y reempaqueta, perdiendo orden/comentarios). (4) Sin "trazabilidad visual" — solo logs de la última ejecución. | Coexisten: HA Automations para reglas triviales (toggle de luz por sensor), Node-RED para todo lo demás. |
| **n8n** | (1) UI visual moderna. (2) Integraciones SaaS (Slack, Notion, Google) "premium". (3) Sub-flows y versioning. | (1) **Sin integración HA nativa** (solo HTTP a la API REST con polling). (2) Licencia [`fair-code`](https://faircode.io/) (no Open Source en sentido estricto) — limita variantes opt-in. (3) Pesa más (RAM): ~400 MB vs ~80 MB de Node-RED ARM. | Descartado: el caso de uso del homelab es domótica + glue interno, no orquestación SaaS. |
| **Huginn** (Ruby) | (1) Modelo de "agentes" con RSS/email/HTTP. (2) Comunidad nicho con plantillas de bots. | (1) En **modo mantenimiento** ([repositorio](https://github.com/huginn/huginn) con releases esporádicos). (2) Stack Ruby + MySQL pesa más en una Pi 5 que Node.js + flat-file. (3) Sin ecosistema MQTT/HA. | Descartado por estancamiento. |
| **Apache Airflow / Prefect** | (1) Programación de DAGs robusta. (2) Reintentos, retries, DAG runs como entidades. | (1) Sobreingeniería para domótica (DAGs son para data engineering, no para "sensor de puerta → luz"). (2) Stack Python + scheduler + webserver + DB. | Descartado por scope. |

> Resumen: **Node-RED = UI visual + paletas + integración HA + desacoplado**. El precio es un servicio Docker más, ya factorizado en la Fase 8.

---

## Requisitos Previos

- **Sistema base operativo** según Fase 1: usuario `homelab` (UID 1000), `/mnt/hd2t/` montado, directorio `/mnt/hd2t/services/node-red/` ya creado ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §2.6 — el bucle de la Fase 8 lo provisiona junto con HA, Mosquitto y Z2M).
- **Docker + red `homelab`** según Fase 2 ([`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md), [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4). Convenciones de Compose ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.5 — bind mounts; §6 — plantilla mínima).
- **Watchtower desplegado** ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). Node-RED va con `enable: "true"` por política ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2): es un servicio web stateless cuya BD persistente (`flows.json`) no muta de esquema entre minor releases dentro de la misma `4.x`. Pinneamos un tag concreto para que solo se actualice cuando el operador edite `NODERED_IMAGE_TAG` en `.env` — Watchtower respeta el tag exacto y no fuerza upgrade silencioso.
- **Mosquitto operativo** ([`./02-mosquitto.md`](./02-mosquitto.md)) con el cliente `nodered` ya creado en `passwords` y su bloque ACL en `acl` (R `#` + RW `nodered/#`, [`./02-mosquitto.md`](./02-mosquitto.md) §4.2-§4.3). Sin esto, el primer despliegue arranca pero el nodo `mqtt-broker` se queda en "Connecting..." indefinido.
- **Home Assistant operativo** ([`./01-home-assistant.md`](./01-home-assistant.md)) **no** es bloqueante para desplegar Node-RED (Mosquitto es la única dependencia hard), pero sí lo es para usar la paleta HA: la conexión WebSocket exige un **Long-Lived Access Token** (LLAT) que se genera desde el perfil del usuario en HA. Si HA aún no está, los flujos puramente MQTT funcionan; los flujos que llamen a `services.call` de HA quedan en error hasta que HA arranca y se inserta el token.
- **Caddy desplegado** ([`../03-red/04-caddy.md`](../03-red/04-caddy.md)) **si** se va a publicar el editor en `nodered.lan` (paso §8.1 — recomendado). Sin Caddy, el editor solo es accesible mediante port-forward manual, lo cual rompe la regla del homelab "ningún servicio web sin reverse proxy + Authelia".
- **Authelia desplegada** ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)) si se publica el editor (mismo §8.1). Node-RED tiene `adminAuth` propio (defense-in-depth, §4.2.2 abajo), pero **se exige Authelia delante** porque el editor permite ejecución arbitraria de JavaScript en nodos `function` y `exec` — sin SSO/2FA, una credencial filtrada de `adminAuth` da RCE dentro del contenedor.
- **Pi-hole desplegado** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) con registro DNS local `nodered.lan -> IP de la Pi`.
- **Borgmatic operativo** ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)) para `/mnt/hd2t/services/node-red/` (incluyendo `flows_cred.json` cifrado con `credentialSecret` — el secreto se respalda en el password manager **además** del backup).

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Implementación | **Node-RED** ([`nodered/node-red:4.0.5`](https://hub.docker.com/r/nodered/node-red)) | Ver §0. Coincide con el estándar de facto en domótica self-hosted (la integración HA-NR está mantenida por la comunidad de HA). |
| Tag de imagen | **`nodered/node-red:4.0.5`** (pinned, no `latest` ni `4`) | Evita upgrades automáticos de minor que requieran rebuilding de paletas. La 4.x consolidó cambios de la 3.x ([release notes](https://github.com/node-red/node-red/releases)) — pinear da tiempo al operador a leer el changelog. Watchtower respeta el tag exacto. |
| Arquitectura | `linux/arm64` (Pi 5) | El manifest de `nodered/node-red:4.0.5` incluye `arm64`. Imagen total: ~400 MB (Node.js 18 base + Node-RED + paletas builtin). |
| Red Docker | **`homelab`** (bridge externa). **Sin** `ports:` al host. | Caddy llega a `nodered:1880` por DNS Docker; los flujos llaman a `homeassistant:8123` y `mosquitto:1883` por nombre. No publicar al host elimina el riesgo de un editor accesible sin Authelia desde la LAN. |
| Usuario del proceso | **`node-red:node-red` (UID 1000:1000)** — default de la imagen | Coincide con el usuario `homelab` del host. Los bind mounts pueden ser `homelab:homelab 0750` y Node-RED escribe sin problemas. |
| `credentialSecret` | **Variable de entorno `NODE_RED_CREDENTIAL_SECRET`**, valor en `/mnt/hd2t/services/node-red/.env` | Sin un secreto fijo, Node-RED genera uno aleatorio y lo escribe en `/data/.config.runtime.json`. Si ese fichero se pierde entre backup/restore, **todas** las credenciales cifradas en `flows_cred.json` (passwords MQTT, tokens HA, API keys) son irrecuperables. Fijarlo en `.env` y respaldarlo en el password manager rompe ese acoplamiento. |
| `adminAuth` | **Activado** con un usuario `admin` y password bcrypt en `settings.js` | Aunque Authelia esté delante, `adminAuth` cubre el escenario "alguien dentro de `homelab` (otro contenedor comprometido) intenta llegar al editor". Es defense-in-depth. |
| `flowFile` | **`flows.json`** (default) | Único fichero de definición de flujos. Versionable manualmente exportando vía UI; los Projects (variante §12.3) automatizan el versionado pero no los activamos por defecto. |
| `editorTheme.projects.enabled` | **`false`** | El feature [Projects](https://nodered.org/docs/user-guide/projects/) versiona flujos en git dentro del contenedor. Útil a gran escala, sobreingeniería para un homelab donde el backup de `/data` ya cubre el caso. |
| Logging | **`console.level: "info"`** en `settings.js`, salida a stdout (Docker) | `info` es el equilibrio: muestra deploys, errores, conexiones MQTT/HA. `debug` inunda los logs con cada mensaje. |
| Modelo de almacenamiento | **Bind mount** en `/mnt/hd2t/services/node-red/data` | Patrón estándar del homelab. NR escribe `flows.json`, `flows_cred.json`, `settings.js`, `lib/`, `node_modules/`, `.config.*.json`. |
| Watchtower | **`com.centurylinklabs.watchtower.enable: "true"`** | Ver [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2: NR es candidato a updates automáticos dentro del tag pinned. Si se cambia a `4.x` floating se debe revisar la política. |
| Reverse proxy | **Caddy delante** del editor (`nodered.lan`) | El editor HTTP plano es inseguro fuera del namespace `homelab`. Caddy aporta TLS interno y forward_auth a Authelia. |
| Authelia | **Forward_auth requerido** para el editor | El editor permite RCE vía nodos `function`/`exec`. Authelia con 2FA es la barrera externa; `adminAuth` (§4) es la barrera interna. |
| Fail2ban | **Opt-in** (§12.4) | Mientras Authelia esté delante, los intentos de fuerza bruta los frena Authelia ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) §6 — jail Authelia). El jail directo del editor solo aplica si se desactiva Authelia (no recomendado). |

---

## 1. Resumen de la arquitectura

```
                  ┌──────────────── red homelab (172.20.0.0/24) ─────────────────┐
                  │                                                              │
                  │   ┌────────────────────┐   HTTP/WebSocket                    │
                  │   │  Home Assistant    │ ◄────── http://homeassistant:8123   │
                  │   │  (./01-home-...)   │         (paleta HA WebSocket)       │
                  │   └────────────────────┘   Authorization: Bearer <LLAT>      │
                  │                                                              │
                  │   ┌────────────────────┐                                     │
                  │   │     Mosquitto      │ ◄────── mqtt://nodered:****@        │
                  │   │   (./02-...)       │         mosquitto:1883              │
                  │   │   1883 (interno)   │                                     │
                  │   └────────────────────┘   topics: R #, RW nodered/#         │
                  │                                                              │
                  │   ┌──────────────────────────────────────────┐               │
                  │   │              Node-RED (este doc)         │               │
                  │   │                                          │               │
                  │   │   /data/flows.json       ─►  ┐           │               │
                  │   │   /data/flows_cred.json  ─►  │           │               │
                  │   │   /data/settings.js      ─►  │ /mnt/hd2t/│               │
                  │   │   /data/lib/             ─►  │ services/ │               │
                  │   │   /data/node_modules/    ─►  │ node-red/ │               │
                  │   │   /data/.config.*.json   ─►  │ data/     │               │
                  │   │                              │ (homelab: │               │
                  │   │                              │  homelab  │               │
                  │   │                              │  0750)    │               │
                  │   │                              └           │               │
                  │   │   :1880 (editor + runtime)               │               │
                  │   │                                          │ ◄── Caddy     │
                  │   └──────────────────────────────────────────┘     reverse   │
                  │                                                    proxy     │
                  │                                                    nodered.  │
                  │                                                    lan       │
                  │                                              + Authelia      │
                  │                                                forward_auth  │
                  │                                                              │
                  └──────────────────────────────────────────────────────────────┘
```

Lo crítico de este diagrama:

1. **Node-RED no habla nunca con Z2M directamente**: todo va vía Mosquitto. El nodo `mqtt-in` se suscribe a `zigbee2mqtt/#` (gracias a la ACL `R #`) y procesa los eventos. Para enviar comandos a un device Zigbee, publica en `zigbee2mqtt/<device>/set` — pero **no puede** porque su ACL es `R #` + `RW nodered/#`. La opción canónica es **delegar en HA**: el flow llama a `homeassistant.service.call` (vía paleta WebSocket) y HA traduce la llamada a un publish en MQTT con su credencial `homeassistant` (que sí tiene `RW zigbee2mqtt/#`).

2. **Dos canales hacia HA**: (a) MQTT vía Mosquitto (eventos publicados por HA en `homeassistant/#`) y (b) WebSocket vía `homeassistant:8123/api/websocket` con LLAT. La paleta WebSocket se usa para **leer estado en tiempo real** (`events:state_changed`) y **llamar servicios** (`light.turn_on`, `notify.telegram`); MQTT se usa para los devices que ya tienen retained messages.

3. **`flows_cred.json` es crítico y cifrado**: contiene la password MQTT del usuario `nodered`, el LLAT de HA, y cualquier API key (Telegram bot, OpenWeather...) que se introduzca en nodos. Está cifrado AES-256 con la clave derivada de `credentialSecret`. **Backup sin el secreto = inservible.**

4. **El editor es destructivo**: instala paletas, ejecuta `function` con código arbitrario, hace requests HTTP. Por eso Authelia delante es obligatorio. Sin Authelia, el editor no se publica.

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/node-red/.env.example`:

```env
# ~/homelab/stacks/node-red/.env.example
# Versionado en: ~/homelab/stacks/node-red/.env.example
# Valores reales en /mnt/hd2t/services/node-red/.env (chmod 600).
# Este fichero NO contiene secretos: el credentialSecret y la password
# bcrypt del adminAuth viven solo en el .env real y en el password manager.

# --- Comunes del homelab ---
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
TZ=Europe/Madrid

# --- Node-RED ---
# https://hub.docker.com/r/nodered/node-red
# Releases: https://github.com/node-red/node-red/releases
NODERED_IMAGE_TAG=4.0.5

# Hostname interno (resuelto por DNS Docker en la red `homelab`).
NODERED_HOSTNAME=nodered

# Dominio LAN del homelab (para el editor tras Caddy).
LAN_DOMAIN=lan

# --- Secretos (rellenar en el .env real, NUNCA aquí) ---
# Clave para cifrar /data/flows_cred.json (passwords MQTT, tokens HA, API keys).
# Generar con: openssl rand -hex 32
# Pérdida = irrecuperable.
NODE_RED_CREDENTIAL_SECRET=__rellenar_en_env_real__

# Hash bcrypt de la password del usuario `admin` del adminAuth.
# Generar con: docker run --rm nodered/node-red:4.0.5 \
#   node -e "console.log(require('bcryptjs').hashSync(process.argv[1], 8))" '<plain>'
# Importante: usar bcryptjs (Node-RED lo bundlea), NO htpasswd.
NODE_RED_ADMIN_BCRYPT=__rellenar_en_env_real__
```

### 2.2. `.env` real (`/mnt/hd2t/services/node-red/.env`)

```bash
# Crear el .env con permisos correctos.
sudo install -o homelab -g homelab -m 600 /dev/null /mnt/hd2t/services/node-red/.env

# Editar (ejemplo con valores reales):
sudo -u homelab tee /mnt/hd2t/services/node-red/.env >/dev/null <<'EOF'
HOMELAB_USER=homelab
HOMELAB_UID=1000
HOMELAB_GID=1000
TZ=Europe/Madrid
NODERED_IMAGE_TAG=4.0.5
NODERED_HOSTNAME=nodered
LAN_DOMAIN=lan
NODE_RED_CREDENTIAL_SECRET=<64 hex chars de openssl rand -hex 32>
NODE_RED_ADMIN_BCRYPT=$2a$08$xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
EOF

# Verificar permisos:
ls -l /mnt/hd2t/services/node-red/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

> **Importante sobre el bcrypt**: el hash empieza por `$2a$` o `$2b$`. Compose interpreta `$$` como un escape de `$`, así que **dentro del `.env`** no hace falta duplicarlo. Pero **si se inserta el hash en un YAML directamente** (sin `.env`), hay que escribir `$$2a$$08$$...` para que Compose no lo trate como variable.

### 2.3. `package.json` semilla (versionable)

`~/homelab/stacks/node-red/package.json.example`:

```json
{
  "name": "node-red-project-homelab",
  "description": "Paletas baseline del homelab. Documentado en docs/08-domotica/04-node-red.md.",
  "version": "0.0.1",
  "private": true,
  "dependencies": {
    "node-red-contrib-home-assistant-websocket": "0.74.0"
  }
}
```

> **Por qué un `package.json` semilla**: cuando Node-RED arranca por primera vez con un `/data` vacío, copia un `package.json` baseline desde la imagen. Si el operador instala paletas vía la UI, NR las añade a `/data/package.json` y las baja vía `npm install`. Versionar este `package.json.example` permite reconstruir las paletas sin restaurar `node_modules/` — útil tras un disaster recovery donde `/data/node_modules/` se pierde y se quiere reinstalar todo desde cero (§10.3).

### 2.4. Cómo se inyectan al contenedor

- `env_file: /mnt/hd2t/services/node-red/.env` carga **todas** las variables (incluido `NODE_RED_CREDENTIAL_SECRET` y `NODE_RED_ADMIN_BCRYPT`) en el entorno del contenedor.
- `settings.js` (§4) lee `process.env.NODE_RED_CREDENTIAL_SECRET` y `process.env.NODE_RED_ADMIN_BCRYPT` para configurar el cifrado de credenciales y el `adminAuth`.
- El `package.json.example` se copia a `/mnt/hd2t/services/node-red/data/package.json` solo en el primer despliegue (§3.2.3); después el operador (o la UI) lo edita.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
mkdir -p ~/homelab/stacks/node-red
cd ~/homelab/stacks/node-red
```

### 3.2. Crear el árbol de datos persistentes

#### 3.2.1. Directorio raíz y `data/`

```bash
# El directorio /mnt/hd2t/services/node-red/ ya existe del bootstrap de Fase 1
# (ver ../01-sistema/04-estructura-directorios.md §2.6).

# Crear data/ con propietario homelab:homelab y permisos 0750.
sudo install -d -o homelab -g homelab -m 0750 \
  /mnt/hd2t/services/node-red/data

# Verificar:
ls -ld /mnt/hd2t/services/node-red/data
# Esperado: drwxr-x--- 2 homelab homelab ... data
```

#### 3.2.2. `settings.js` versionable

El fichero canónico se redacta en §4 de este doc y se copia al bind mount:

```bash
# Crear directorio del settings.js en el stack (si aún no existe).
mkdir -p ~/homelab/stacks/node-red

# El settings.js definitivo se redacta en §4. Por ahora crear placeholder:
touch ~/homelab/stacks/node-red/settings.js
```

#### 3.2.3. Semilla del `package.json`

```bash
# Copiar el package.json semilla desde el stack (versionable) al bind mount.
sudo install -o homelab -g homelab -m 0640 \
  ~/homelab/stacks/node-red/package.json.example \
  /mnt/hd2t/services/node-red/data/package.json

# Verificar:
ls -l /mnt/hd2t/services/node-red/data/package.json
# Esperado: -rw-r----- 1 homelab homelab ... package.json
```

### 3.3. Tabla de permisos

| Ruta | Owner | Mode | Por qué |
|---|---|---|---|
| `/mnt/hd2t/services/node-red/` | `homelab:homelab` | `0750` | Raíz del servicio. Solo el operador y el grupo `homelab` lo listan. |
| `/mnt/hd2t/services/node-red/.env` | `homelab:homelab` | `0600` | Contiene secretos (`NODE_RED_CREDENTIAL_SECRET`, `NODE_RED_ADMIN_BCRYPT`). Ningún otro usuario lo lee. |
| `/mnt/hd2t/services/node-red/data/` | `homelab:homelab` | `0750` | Bind mount principal. NR escribe como UID 1000 (= homelab), así que escribe sin permisos extra. |
| `/mnt/hd2t/services/node-red/data/package.json` | `homelab:homelab` | `0640` | Mutado por NR cuando instala paletas. |
| `/mnt/hd2t/services/node-red/data/flows.json` | `homelab:homelab` | `0644` (lo escribe NR) | Lógica de los flujos. **Sin secretos** (se mueven a `flows_cred.json`). |
| `/mnt/hd2t/services/node-red/data/flows_cred.json` | `homelab:homelab` | `0644` (lo escribe NR) | Credenciales **cifradas** con `credentialSecret`. Aún así, conviene no compartir el fichero. |
| `/mnt/hd2t/services/node-red/data/settings.js` | `homelab:homelab` | `0640` | Versionado en `~/homelab/stacks/node-red/settings.js`; se copia al bind mount en cada deploy. |

> **Sobre los `0644` que escribe NR**: la imagen oficial corre con `umask 022`. Eso da `0644` para ficheros y `0755` para directorios. No vamos a cambiarlo porque romper el umask del proceso obliga a reconstruir la imagen — y los ficheros viven dentro de un directorio `0750` que ya restringe acceso a otros usuarios.

---

## 4. Configuración de Node-RED

### 4.1. `settings.js` (sin secretos)

`~/homelab/stacks/node-red/settings.js` (versionable):

```javascript
// ~/homelab/stacks/node-red/settings.js
//
// Configuración de Node-RED para el homelab.
// Documentado en: docs/08-domotica/04-node-red.md §4.
//
// Esta es una versión RECORTADA del settings.js que distribuye Node-RED.
// Se han eliminado los bloques no usados (HTTPS, projects, externalModules
// con allowlists vacías) para mantenerlo legible. Para la referencia
// completa del fichero, ver:
//   https://github.com/node-red/node-red/blob/master/packages/node_modules/node-red/settings.js

module.exports = {

    // ─── Almacenamiento ──────────────────────────────────────────────────────
    // Fichero único de flujos. Sin Projects (§12.3 lo activa opt-in).
    flowFile: 'flows.json',

    // Permitir que NR genere `.backup` antes de escribir flows.json (sí; útil
    // para revertir un deploy mal hecho desde el editor).
    flowFilePretty: true,

    // ─── Credenciales cifradas ───────────────────────────────────────────────
    // CRITICO: la clave para cifrar /data/flows_cred.json se inyecta vía env.
    // Si esta variable cambia entre arranques, las credenciales existentes
    // se invalidan y NR las muestra como "vacías" en el editor (sin throw).
    // Backup: la clave en NODE_RED_CREDENTIAL_SECRET se respalda en el
    // password manager del operador (NO solo en el .env del homelab).
    credentialSecret: process.env.NODE_RED_CREDENTIAL_SECRET,

    // ─── Editor: autenticación de admin ──────────────────────────────────────
    // Defense-in-depth tras Authelia (../04-seguridad/01-authelia.md):
    // si un contenedor en `homelab` pivota e intenta llegar a NR sin pasar
    // por Caddy/Authelia, sigue habiendo una barrera bcrypt.
    adminAuth: {
        type: "credentials",
        users: [
            {
                username: "admin",
                password: process.env.NODE_RED_ADMIN_BCRYPT,
                permissions: "*"
            }
        ]
    },

    // ─── Editor: aspecto y features ──────────────────────────────────────────
    editorTheme: {
        // Projects (git-per-flow) desactivado por defecto. Backup vía Borgmatic
        // del directorio /data/ es suficiente para el caso del homelab.
        projects: {
            enabled: false,
            workflow: {
                mode: "manual"
            }
        },
        // Tour de bienvenida desactivado tras la primera vez (ruido).
        tours: false,
        // Mostrar el dashboard de paletas en la UI (instalación manual de
        // paletas desde el editor).
        palette: {
            editable: true
        }
    },

    // ─── Logging ─────────────────────────────────────────────────────────────
    // Salida a stdout (Docker la captura → docker logs / Dozzle).
    // `info` cubre deploys, errores, conexión MQTT/HA, sin saturar.
    logging: {
        console: {
            level: "info",
            metrics: false,
            audit: false
        }
    },

    // ─── HTTP del runtime ────────────────────────────────────────────────────
    // El editor y el runtime escuchan en 1880. Sin TLS aquí — Caddy termina
    // TLS en nodered.lan y reverse-proxea HTTP plano (red interna `homelab`).
    uiHost: "0.0.0.0",
    uiPort: 1880,

    // Endpoints HTTP que expone el runtime para los flujos (nodos `http in`).
    httpAdminRoot: "/",   // editor
    httpNodeRoot: "/api", // endpoints de los nodos http-in (rutas /api/...)

    // Trust proxies: Caddy es el único frontal. Los logs de NR muestran
    // X-Real-IP en vez de la IP del contenedor de Caddy.
    httpAdminMiddleware: function(req, res, next) {
        // Cabeceras de seguridad mínimas. Caddy también añade las suyas
        // (../03-red/04-caddy.md §6 — security_headers), pero por defense-
        // in-depth las repetimos aquí por si alguna se desactiva en el snippet.
        res.setHeader('X-Frame-Options', 'SAMEORIGIN');
        res.setHeader('X-Content-Type-Options', 'nosniff');
        next();
    },

    // ─── Runtime de los flujos ───────────────────────────────────────────────
    // Function nodes: timeout para evitar que un loop infinito en un nodo
    // function tire abajo la pila.
    functionTimeout: 0,                  // 0 = sin timeout. Subir a 30 si
                                         // un flujo se cuelga sin error.
    functionGlobalContext: {
        // Bibliotecas accesibles desde los nodos `function` como globals:
        //   const moment = global.get('moment');
        // Para añadir, instalar la paleta y referenciarla aquí.
        // moment: require('moment')
    },

    // Almacenamiento de contexto: in-memory por defecto.
    // El contexto persistente (`context.flow.set('x', 1, "store")`)
    // requiere declararlo aquí. Para el homelab no es necesario por defecto;
    // si un flow lo pide, ver §12.5.
    contextStorage: {
        default: { module: "memory" }
    },

    // ─── Diagnóstico runtime ─────────────────────────────────────────────────
    // Diagnostics endpoint en /diagnostics: útil para troubleshooting,
    // pero expone versiones, paths, paletas. Restringido a admin auth.
    diagnostics: {
        enabled: true,
        ui: true
    },

    // Catálogo de paletas (qué muestra el editor cuando "Manage Palette"):
    // dejar el catálogo público (https://catalogue.nodered.org/catalogue.json).
    // Si se quiere bloquear instalaciones online, vaciar el array.
    paletteCategories: ['subflows', 'common', 'function', 'network', 'sequence', 'parser', 'storage'],

    externalModules: {
        // Permitir que los nodos `function` hagan `require('lodash')` etc.
        // SOLO de paletas instaladas (no `npm install` arbitrario).
        autoInstall: false,
        autoInstallRetry: 30,
        palette: {
            allowInstall: true,
            allowUpload: false,    // No subir tarballs npm — usar el catálogo.
            allowList: ['*'],
            denyList: []
        },
        modules: {
            allowInstall: false,
            allowList: [],
            denyList: []
        }
    }
};
```

#### 4.1.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `flowFile: 'flows.json'` + `flowFilePretty: true` | Default que mantiene el fichero legible (un objeto por línea). Permite `git diff` significativos si en el futuro se activa Projects. |
| `credentialSecret: process.env.NODE_RED_CREDENTIAL_SECRET` | Sin esta línea, NR genera un secreto aleatorio en `/data/.config.runtime.json`. Si ese fichero se pierde en un restore parcial, todas las credenciales (passwords MQTT, tokens HA) se invalidan silenciosamente — `flows_cred.json` queda como bloque cifrado ilegible. |
| `adminAuth.users` con bcrypt vía env | Defense-in-depth: si Authelia falla o se desactiva temporalmente, la UI sigue requiriendo login. El bcrypt va en `.env` (no en este fichero versionable). |
| `editorTheme.projects.enabled: false` | El backup de `/data/` cubre versionado. Activar Projects exige un repo git por proyecto (overhead operativo). |
| `editorTheme.palette.editable: true` | El operador puede instalar paletas desde la UI. Si se quiere prohibir (lockdown post-bootstrap), poner `false` y editar `package.json` manualmente + reiniciar. |
| `logging.console.level: "info"` | Equilibrio info/ruido. Los deploys, errores y conexiones MQTT/HA salen; el tráfico de mensajes individuales no. |
| `uiHost: "0.0.0.0", uiPort: 1880` | Bind a `0.0.0.0` dentro del contenedor (NS de red aislada). Externamente solo Caddy llega a `nodered:1880` (DNS Docker). |
| `httpAdminRoot: "/"`, `httpNodeRoot: "/api"` | Default. Cambiarlos rompe la integración con HA y los snippets de Caddy. |
| `httpAdminMiddleware` con headers de seguridad | Defense-in-depth respecto al `security_headers` de Caddy. |
| `functionTimeout: 0` | Sin timeout por defecto. Si un flow productivo tiene un loop, monitorizar y subir a 30s si se identifica el patrón. |
| `contextStorage.default: memory` | Sin persistencia de contexto. Si un flow necesita persistir (`flow.set('x', 1, "store")`), declarar un `localfilesystem` aquí (§12.5). |
| `diagnostics.enabled: true` | Útil para troubleshooting (ver versiones de paletas, runtime, vars). Solo admin auth llega. |
| `externalModules.palette.allowInstall: true` | El operador instala paletas desde la UI; sin esto, "Manage Palette" tira un 403. |
| `externalModules.modules.allowInstall: false` | Los nodos `function` **no** pueden hacer `npm install` arbitrarios al vuelo. Reduce la superficie de ataque del editor. |

### 4.2. `settings.js`: generar el bcrypt para `adminAuth`

#### 4.2.1. Comando

```bash
# 1) Generar plain password (recomendado: 24 chars aleatorios).
ADMIN_PWD="$(openssl rand -base64 24 | tr -d '+/=' | cut -c1-24)"
echo "admin password (guardar en password manager): $ADMIN_PWD"

# 2) Generar el hash bcrypt vía la imagen Node-RED (que bundlea bcryptjs).
docker run --rm nodered/node-red:4.0.5 \
  node -e "console.log(require('bcryptjs').hashSync(process.argv[1], 8))" \
  "$ADMIN_PWD"
# Esperado, salida ejemplo:
#   $2a$08$ABcDeFgHiJkLmNoPqRsTuVwXyZ0123456789abcdef0123456789abcdef
```

#### 4.2.2. Por qué la cadena empieza por `$2a$` y por qué `8` rounds

- **`$2a$`**: variante de bcrypt soportada por todas las versiones del módulo `bcryptjs`. NR la acepta sin glitches.
- **`08$`**: cost factor `2^8 = 256` iteraciones internas. Valor medio: hash en ~70 ms en una Pi 5. Subir a `10` (1024 iter) eleva a ~250 ms — molesto en cada login del editor. `08` es un equilibrio razonable para una password de 24 chars (entropía suficiente para que no compense fuerza bruta offline aunque el hash se filtre).

#### 4.2.3. Persistir el hash en `.env`

Volcar el hash en `NODE_RED_ADMIN_BCRYPT` del `.env` real (§2.2). Cuidado al copiar: incluir las `$` literales **sin** duplicarlas (Compose las trata como variable solo dentro de YAML, no dentro de `.env`).

### 4.3. Generar el `credentialSecret`

```bash
# Cualquier valor de alta entropía. La práctica estándar son 32 bytes hex.
CRED_SECRET="$(openssl rand -hex 32)"
echo "credentialSecret (guardar en password manager Y en .env): $CRED_SECRET"
```

Persistir en `NODE_RED_CREDENTIAL_SECRET` del `.env` real (§2.2). **Y en el password manager**: el `.env` está en hd2t (cubierto por Borgmatic), pero un escenario "Pi rota + restore parcial sin el .env del momento del backup" requiere el secreto desde fuera para descifrar `flows_cred.json`.

### 4.4. Copiar `settings.js` al bind mount

```bash
sudo install -o homelab -g homelab -m 0640 \
  ~/homelab/stacks/node-red/settings.js \
  /mnt/hd2t/services/node-red/data/settings.js

# Verificar:
ls -l /mnt/hd2t/services/node-red/data/settings.js
# Esperado: -rw-r----- 1 homelab homelab ... settings.js
```

Tras cada cambio en `~/homelab/stacks/node-red/settings.js`, repetir el `install` y reiniciar:

```bash
docker compose --env-file /mnt/hd2t/services/node-red/.env restart nodered
```

> NR **no** recarga `settings.js` en caliente (a diferencia de los flujos). Cualquier cambio exige restart.

---

## 5. `docker-compose.yml`

`~/homelab/stacks/node-red/docker-compose.yml`:

```yaml
# ~/homelab/stacks/node-red/docker-compose.yml
# Stack: node-red (../02-docker/02-estructura-compose.md §1.1).
# Datos en /mnt/hd2t/services/node-red/.
# Sin `ports:` por defecto — el editor se accede vía Caddy en nodered.lan.

name: node-red

services:
  nodered:
    image: nodered/node-red:${NODERED_IMAGE_TAG}
    container_name: nodered
    hostname: ${NODERED_HOSTNAME}
    restart: unless-stopped
    env_file: /mnt/hd2t/services/node-red/.env

    environment:
      TZ: ${TZ}
      # NR lee credentialSecret y adminAuth desde process.env en settings.js.
      # `env_file` ya las inyecta, esto es solo para dejar evidencia en
      # `docker inspect` y de paso documentar las variables esperadas.
      NODE_RED_CREDENTIAL_SECRET: ${NODE_RED_CREDENTIAL_SECRET}
      NODE_RED_ADMIN_BCRYPT: ${NODE_RED_ADMIN_BCRYPT}
      # Forzar que NR use el directorio /data como userdir (default upstream
      # pero explicitado por claridad).
      NODE_RED_USER_DIR: /data
      # Memoria máxima para el runtime de Node.js. Sin esto, NR puede pedir
      # más de mem_limit y morir por OOM antes de devolver un error útil.
      NODE_OPTIONS: "--max-old-space-size=384"

    volumes:
      # Datos persistentes (flows.json, flows_cred.json, settings.js, lib/,
      # node_modules/, .config.*.json).
      - type: bind
        source: /mnt/hd2t/services/node-red/data
        target: /data
      # Reloj sincronizado con el host.
      - /etc/localtime:/etc/localtime:ro

    # Sin `ports:` — el editor (1880) se accede vía Caddy reverse proxy.
    networks:
      - homelab

    depends_on:
      mosquitto:
        condition: service_healthy
        restart: true

    # Recursos: NR baseline (sin paletas pesadas) ~80 MB de RAM.
    # Con HA WebSocket + 50 entidades observadas: ~150 MB.
    # 512m de tope cubre picos durante npm install de paletas.
    mem_limit: 512m
    mem_reservation: 96m

    # Healthcheck: el editor responde 200 en GET / (incluso sin auth, sirve
    # el HTML del login, lo que confirma que el runtime está vivo).
    # `wget` viene en la imagen base de Node-RED (Alpine).
    healthcheck:
      test:
        - "CMD-SHELL"
        - "wget -qO- http://localhost:1880/ >/dev/null 2>&1 || exit 1"
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

    labels:
      # Watchtower: actualizaciones automáticas del tag pinned
      # (../02-docker/04-watchtower.md §4.2).
      com.centurylinklabs.watchtower.enable: "true"
      # Dozzle: agrupar logs de Fase 8 (HA, Mosquitto, Z2M, Node-RED).
      dev.dozzle.group: "homeassistant"

networks:
  homelab:
    external: true
```

> **Nota sobre `depends_on` con `mosquitto`**: el stack `node-red` está en su propio `docker-compose.yml` y Mosquitto en otro. La condición `service_healthy` solo aplica si los dos servicios están en el **mismo** Compose project. Aquí el `depends_on` queda como **documentación**: Mosquitto debe estar arriba antes de Node-RED. En operación, si NR arranca antes que Mosquitto, los nodos `mqtt-in/out` quedan en estado "Connecting..." y NR los reintenta automáticamente cada 5s — por eso no es estrictamente necesario.

### 5.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `name: node-red` | Nombre del proyecto Compose, igual al nombre del directorio del stack ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §3.1). |
| `image: nodered/node-red:${NODERED_IMAGE_TAG}` | Tag pinned vía `.env`. La imagen oficial está en Docker Hub ([`nodered/node-red`](https://hub.docker.com/r/nodered/node-red)). |
| `container_name: nodered` / `hostname: ${NODERED_HOSTNAME}` | Nombre estable: Caddy resuelve `nodered:1880` por DNS Docker. Sin esto, el nombre generado tipo `node-red-nodered-1` rompería el reverse proxy. |
| `env_file: ...` | Patrón estándar. Carga `NODE_RED_CREDENTIAL_SECRET` y `NODE_RED_ADMIN_BCRYPT` que `settings.js` lee desde `process.env`. |
| `environment.TZ` | Timestamps en logs de NR en zona local. Sin `TZ`, NR loguea en UTC. |
| `environment.NODE_RED_CREDENTIAL_SECRET` y `NODE_RED_ADMIN_BCRYPT` redundantes con `env_file` | Defense-in-depth de visibilidad: `docker inspect nodered` muestra estas variables como presentes (con sus valores — cuidado al compartir output). Al menos confirma que están seteadas. |
| `environment.NODE_RED_USER_DIR: /data` | Default, pero explicitado para evitar sorpresas si una versión futura cambia el path. |
| `environment.NODE_OPTIONS: "--max-old-space-size=384"` | Limita el heap de V8 a 384 MB. Con `mem_limit: 512m`, deja margen para el resto del proceso (libs nativas, buffers de red). Sin este flag, V8 puede pedir hasta el límite del cgroup de golpe y disparar OOM en escenarios de paletas que cargan datasets en memoria. |
| `volumes: data:/data` | NR escribe **todo** su estado aquí. Único bind mount de datos. |
| `volumes: /etc/localtime:ro` | Sincroniza zona del host con el contenedor. |
| `networks: [homelab]` | Solo la red compartida. Mosquitto se resuelve como `mosquitto:1883`, HA como `homeassistant:8123`, Caddy llega a `nodered:1880`. |
| `depends_on: mosquitto: condition: service_healthy` | Documentación + intento de coordinación si los stacks están en el mismo proyecto Compose. |
| `mem_limit: 512m` | NR baseline ~80 MB; con HA WebSocket + paletas comunes ~150 MB. 512m cubre picos durante `npm install` (que descarga + parsea árboles grandes). |
| `mem_reservation: 96m` | Garantía mínima para un arranque limpio. |
| `healthcheck` | `wget` al editor. Si NR no levanta el HTTP (ej. crash al cargar `flows.json`), el contenedor se marca unhealthy y Watchtower no lo reemplaza con la nueva imagen. |
| `start_period: 60s` | NR tarda ~30s en cargar paletas + flows. 60s da margen, especialmente tras un upgrade que descarga deps en `npm rebuild`. |
| `com.centurylinklabs.watchtower.enable: "true"` | Política ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2). |
| `dev.dozzle.group: "homeassistant"` | Agrupa logs de Fase 8 en Dozzle ([`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)). Coincide con HA, Mosquitto y Z2M. |
| `networks.homelab.external: true` | La red se crea en el bootstrap. |

### 5.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/node-red
docker compose --env-file /mnt/hd2t/services/node-red/.env config

# Esperado: salida YAML resuelta sin warnings.
# - El `image` debe estar plenamente cualificado: nodered/node-red:4.0.5
# - `env_file` con path absoluto.
# - `volumes` con paths absolutos.
# - Sin warning "variable X not set".
# - NODE_RED_CREDENTIAL_SECRET y NODE_RED_ADMIN_BCRYPT presentes (la salida
#   los muestra en plaintext — esperado, sin riesgo: solo se imprime en local).
```

---

## 6. Despliegue

### 6.1. Levantar el stack

```bash
cd ~/homelab/stacks/node-red
docker compose --env-file /mnt/hd2t/services/node-red/.env up -d
```

El primer `up` tarda **~90 segundos**:

1. Pull de la imagen (~400 MB la primera vez).
2. NR arranca, ve `/data/package.json` con `node-red-contrib-home-assistant-websocket: 0.74.0` y lanza `npm install` en `/data/node_modules/` (~60s en una Pi 5 con conexión decente).
3. NR carga `settings.js`, lee `credentialSecret` y `adminAuth` del entorno.
4. NR crea `flows.json` vacío si no existe.
5. NR levanta el editor en `:1880`.

Verificar:

```bash
docker compose --env-file /mnt/hd2t/services/node-red/.env ps

# Esperado:
# NAME        IMAGE                       STATUS                  PORTS
# nodered     nodered/node-red:4.0.5      Up X (healthy)          1880/tcp
```

### 6.2. Logs del primer arranque

```bash
docker compose --env-file /mnt/hd2t/services/node-red/.env logs --tail=80 nodered

# Esperado, líneas relevantes:
#   > node-red docker-entrypoint.sh
#   Welcome to Node-RED
#   ===================
#   X Mar HH:MM:SS - [info] Node-RED version: v4.0.5
#   X Mar HH:MM:SS - [info] Node.js  version: v18.X.Y
#   X Mar HH:MM:SS - [info] Linux 6.X.Y arm64 LE
#   X Mar HH:MM:SS - [info] Loading palette nodes
#   X Mar HH:MM:SS - [info] Settings file  : /data/settings.js
#   X Mar HH:MM:SS - [info] Context store  : 'default' [module=memory]
#   X Mar HH:MM:SS - [info] User directory : /data
#   X Mar HH:MM:SS - [info] Projects directory: /data/projects   <-- aunque projects esté off
#   X Mar HH:MM:SS - [info] Server now running at http://127.0.0.1:1880/
#   X Mar HH:MM:SS - [info] Starting flows
#   X Mar HH:MM:SS - [info] Started flows
```

Si aparecen líneas como:

- `[error] Failed to start flow ...` → revisar `flows.json` (puede haber JSON corrupto si fue editado a mano).
- `[warn] No active project: using default flows file` → esperado con `projects: enabled: false`.
- `[error] Error loading credentials: bad decrypt` → `credentialSecret` cambió entre arranques. Restaurar el secreto correcto o (si se ha perdido) borrar `flows_cred.json` y reintroducir las credenciales en cada nodo.

### 6.3. Verificar que `flows.json` y `flows_cred.json` se materializaron

```bash
ls -l /mnt/hd2t/services/node-red/data/

# Esperado, mínimo:
# -rw-r----- 1 homelab homelab    XXX package.json
# drwxr-xr-x N homelab homelab   XXXX node_modules
# -rw-r----- 1 homelab homelab   XXXX settings.js
# -rw-r--r-- 1 homelab homelab     XX flows.json         <-- creado en primer arranque
# -rw-r--r-- 1 homelab homelab     XX flows_cred.json    <-- creado al guardar el primer flow con credencial
# -rw-r--r-- 1 homelab homelab     XX .config.runtime.json
# drwxr-xr-x N homelab homelab     XX lib
```

> **`flows_cred.json`** puede no existir aún tras el primer arranque (no hay credenciales). Aparece en cuanto se guarda un flow con un nodo que tenga password (p.ej. `mqtt-broker`).

---

## 7. Verificación

### 7.1. Contenedor sano

```bash
docker compose --env-file /mnt/hd2t/services/node-red/.env ps

# STATUS columna: Up X (healthy)
```

### 7.2. Node-RED NO escucha en el host

```bash
sudo ss -ltn | grep 1880
# Esperado: SIN OUTPUT.
# (1880 escucha solo dentro del namespace de red `homelab`.)
```

### 7.3. Editor accesible (vía port-forward temporal)

```bash
# Solo para validar antes de Caddy. Mata el túnel después.
docker run --rm -it --network homelab \
  alpine/curl -sS -o /dev/null -w "%{http_code}\n" \
  http://nodered:1880/
# Esperado: 401 (porque adminAuth está activo y no se mandó Authorization).
# Para validar el contenido HTML:
docker run --rm -it --network homelab \
  alpine/curl -sSI http://nodered:1880/ | head -10
# Esperado: HTTP/1.1 401 Unauthorized + WWW-Authenticate: Bearer realm="Node-RED"
```

> Una respuesta `401` confirma dos cosas: (1) el editor está vivo y (2) `adminAuth` está activo. Sin `adminAuth`, devolvería un `200` con HTML.

### 7.4. `credentialSecret` en uso

Comprobar que NR cargó el secreto correcto y no generó uno aleatorio:

```bash
sudo cat /mnt/hd2t/services/node-red/data/.config.runtime.json | jq

# Esperado:
# {
#   "_credentialSecret": "<NO presente>"
# }
# Si `_credentialSecret` aparece aquí, NR generó uno aleatorio
# (porque `credentialSecret` en settings.js no se evaluó). En ese caso,
# revisar que NODE_RED_CREDENTIAL_SECRET está en el .env y que
# settings.js lee process.env.NODE_RED_CREDENTIAL_SECRET sin typos.
```

### 7.5. Lista de Verificación

- [ ] `docker compose ps` muestra `nodered` como `Up X (healthy)`.
- [ ] `sudo ss -ltn | grep 1880` no devuelve nada (editor no expuesto al host).
- [ ] El editor responde `401` (adminAuth activo) tras curl interno desde otro contenedor en `homelab`.
- [ ] `/mnt/hd2t/services/node-red/data/flows.json` existe y es válido JSON (`jq . flows.json`).
- [ ] `/mnt/hd2t/services/node-red/data/.config.runtime.json` **no** contiene `_credentialSecret` (señal de que el de `.env` se cargó).
- [ ] `docker logs nodered` muestra `Started flows` y ningún `[error]` posterior.

---

## 8. Configuración post-despliegue

### 8.1. Publicar el editor en Caddy + Authelia

#### 8.1.1. Bloque del Caddyfile

Editar `~/homelab/stacks/proxy/Caddyfile`. Añadir el bloque LAN:

```caddy
# Node-RED (../08-domotica/04-node-red.md)
nodered.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Authelia: SSO/2FA externa. Bypass NO necesario aquí (NR no tiene
    # endpoints "long-lived token" como HA — toda la UI pasa por
    # navegador con sesión).
    import authelia_proxy

    # WebSockets son críticos: el editor mantiene una conexión WS para
    # actualizaciones en vivo (deploys, debug nodes). Caddy los reenvía
    # transparentemente con `reverse_proxy`.
    reverse_proxy http://nodered:1880 {
        header_up Host {host}
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
        header_up Remote-User {http.auth.user.preferred_username}
        header_up Remote-Groups {http.auth.user.groups}
    }
}
```

Y el bloque Tailscale gemelo (comentado hasta tener cert vía `tailscale cert`):

```caddy
# nodered.{$TS_DOMAIN} {
#     import tailscale_tls nodered
#     import security_headers
#     import authelia_proxy
#     reverse_proxy http://nodered:1880 {
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
```

#### 8.1.2. Registro DNS local en Pi-hole

```bash
PI_IP=192.168.1.10   # ajustar a la IP real de la Pi en la LAN

docker exec pihole bash -c "
  echo '${PI_IP} nodered.lan' >> /etc/pihole/custom.list
  pihole restartdns
"

dig +short nodered.lan @127.0.0.1
# Esperado: ${PI_IP}
```

#### 8.1.3. Regla en Authelia

`/mnt/hd2t/services/authelia/configuration.yml` (extender `access_control`):

```yaml
# fragmento — el resto del fichero está en ../04-seguridad/01-authelia.md §5
access_control:
  default_policy: deny
  rules:
    # ... reglas existentes ...
    - domain: "nodered.{{ env \"LAN_DOMAIN\" }}"
      policy: two_factor
      subject: ["group:admins"]
```

> **Política `two_factor`**: el editor permite RCE (nodos `function`/`exec`). 2FA no es opcional — es la barrera externa antes de `adminAuth`.

#### 8.1.4. Probar el acceso

```bash
# Desde el host (curl debe seguir cert vía CA interna de Caddy):
curl --cacert /etc/ssl/certs/caddy-root.crt -sSI https://nodered.lan/ | head -10
# Esperado: redirect 302 a Authelia (auth.lan/?rd=https://nodered.lan/).

# Desde el navegador con la CA interna importada:
# 1. Abrir https://nodered.lan
# 2. Authelia pide login + 2FA.
# 3. Tras Authelia, NR pide login (admin / password de §4.2.1).
# 4. Aparece el editor.
```

### 8.2. Conectar Node-RED a Mosquitto

#### 8.2.1. Crear el `mqtt-broker` config node

En el editor:

1. Arrastrar un nodo `mqtt in` al lienzo.
2. Doble click → "Add new mqtt-broker".
3. Pestaña **Connection**:
   - Server: `mosquitto`
   - Port: `1883`
   - Use TLS: **off**
   - Client ID: `nodered`
   - Keep alive: `60`
   - Use clean session: **off** (Mosquitto encola hasta `max_queued_messages: 5000`, [`./02-mosquitto.md`](./02-mosquitto.md) §4.1).
   - Use legacy MQTT 3.1 support: **off** (3.1.1 default).
4. Pestaña **Security**:
   - Username: `nodered`
   - Password: la generada en [`./02-mosquitto.md`](./02-mosquitto.md) §4.2.2.
5. Save → Done.

NR persiste la password cifrada en `flows_cred.json` (con `credentialSecret`). En el editor, el campo se muestra como vacío tras guardar — no es bug, NR oculta valores cifrados.

#### 8.2.2. Smoke test MQTT

Configurar un flow mínimo:

```
[mqtt in: $SYS/broker/uptime] ──► [debug]
```

Click en Deploy. Abrir el panel "Debug" (icono bug a la derecha): el broker publica el uptime cada minuto, debe aparecer.

### 8.3. Conectar Node-RED a Home Assistant

#### 8.3.1. Generar el Long-Lived Access Token (LLAT)

En HA:

1. Login como el usuario que se usará desde NR (recomendado: un usuario `node-red` dedicado, **no** el `Owner`).
2. Click en el avatar (esquina inferior izquierda) → "Long-Lived Access Tokens".
3. "Create Token" → nombre: `node-red`.
4. Copiar el token (solo se muestra una vez).

> **Por qué un usuario dedicado**: HA registra cada llamada a servicio en su log con el usuario que la dispara. Si NR usa el `Owner`, los logs no permiten distinguir "lo hizo el operador desde la UI" de "lo hizo Node-RED". Un usuario `node-red` separa los logs.

#### 8.3.2. Crear el `server` config node de la paleta HA

En el editor de NR (la paleta `node-red-contrib-home-assistant-websocket` ya está instalada vía `package.json` semilla §2.3):

1. Arrastrar un nodo `events: state` al lienzo (categoría "home assistant").
2. Doble click → "Add new home-assistant-server".
3. **Connection**:
   - Name: `homeassistant`
   - Base URL: `http://homeassistant:8123`
   - Access Token: pegar el LLAT generado en §8.3.1.
4. Save → Done.

> **Por qué `http://` y no `https://`**: NR llama dentro de `homelab` (red Docker bridge). Caddy no está en el camino — Caddy publica HA hacia LAN/Tailscale. Para llamadas internas, HTTP plano + segregación de red es suficiente.

#### 8.3.3. Smoke test HA

Configurar un flow:

```
[events: state - sun.sun] ──► [debug]
```

Click en Deploy. El panel Debug muestra eventos `state_changed` cada vez que `sun.sun` cambia (~ una vez por hora durante el día). Para forzar un evento ahora, en HA: "Developer Tools" → "States" → `sun.sun` → Set State.

### 8.4. Bypass HA en Caddy: confirmar que NR no se rompe

El bloque `ha.{$LAN_DOMAIN}` del Caddyfile ([`./01-home-assistant.md`](./01-home-assistant.md) §7.5.1) bypassea Authelia para `/api/*`. Eso es relevante **si** NR llama a HA vía `https://ha.lan/api/...` en vez de `http://homeassistant:8123/api/...`. En este homelab NR usa siempre el path interno (Docker DNS), así que el bypass no es estrictamente necesario para NR — pero **sí** lo es para la mobile app, que viaja por LAN/Tailscale → Caddy.

> **Anti-patrón a evitar**: configurar el `Base URL` del NR HA server con `https://ha.lan` y un LLAT. Funciona, pero introduce latencia (TLS + reverse proxy) y rompe si Caddy cae. Mantener `http://homeassistant:8123` interno es la opción correcta.

---

## 9. Operaciones cotidianas

### 9.1. Instalar una paleta nueva (recomendado: vía UI)

1. Editor → Menú (esquina superior derecha) → "Manage palette".
2. Pestaña "Install".
3. Buscar (ej. `node-red-contrib-telegrambot`) → "Install".
4. NR ejecuta `npm install` en `/data/node_modules/` (~30s para una paleta media).
5. La paleta aparece en la columna izquierda y `package.json` se actualiza con el nuevo `dependencies`.

Cada paleta instalada se persiste en `/data/package.json`. Para versionar la lista:

```bash
# Tras instalar paletas, sincronizar el package.json del bind mount al stack.
sudo cp /mnt/hd2t/services/node-red/data/package.json \
  ~/homelab/stacks/node-red/package.json.example

# Editar la version a un placeholder y commitear.
```

### 9.2. Eliminar una paleta

1. "Manage palette" → "Nodes" → buscar la paleta → "Remove".
2. NR ejecuta `npm uninstall`.
3. Si algún flujo usa nodos de esa paleta, NR los marca rojos (no se pueden eliminar paletas en uso). Eliminar primero los nodos del flow, deploy, y luego desinstalar.

### 9.3. Exportar e importar flows

#### 9.3.1. Exportar (backup manual de un flow concreto)

1. Editor → Menú → "Export" → "all flows" o "current tab".
2. Formato: "Compact" (para versionar en git fuera del homelab) o "Pretty" (para revisar a ojo).
3. "Download" para guardar como JSON local.

#### 9.3.2. Importar

1. Editor → Menú → "Import" → pegar JSON o subir fichero.
2. Decidir si los nodos sobrescriben los actuales (`new IDs`) o mantienen los IDs (`existing IDs`).
3. Deploy.

> **Cuidado con las credenciales al importar**: el JSON exportado **no contiene** los valores cifrados de `flows_cred.json` (NR no exporta secretos). Tras importar, hay que volver a meter passwords/tokens.

### 9.4. Logs

```bash
# Live tail.
docker compose --env-file /mnt/hd2t/services/node-red/.env logs -f --tail=100 nodered

# Filtrar errores.
docker compose --env-file /mnt/hd2t/services/node-red/.env logs nodered 2>&1 | \
  grep -E '\[error\]|\[warn\]'

# Logs no se rotan en disco — están en docker journald (rotación
# configurada en /etc/docker/daemon.json en Fase 2).
```

> NR no escribe a fichero por defecto (solo stdout). Si se quiere fichero (p.ej. para fail2ban §12.4), añadir un `file` adicional al `logging` de `settings.js` y un bind mount `/data/log:/data/log`.

### 9.5. Reiniciar NR sin tirar `docker compose down`

```bash
# Restart contenedor (preserva /data, ~30s).
docker compose --env-file /mnt/hd2t/services/node-red/.env restart nodered

# O desde la UI (Menú → "Restart Flows" reinicia los flows sin tocar el runtime).
```

> "Restart Flows" desde la UI **no** recarga `settings.js`. Para cambios en `settings.js`, el `docker compose restart` es obligatorio.

### 9.6. Rotar el `credentialSecret`

Procedimiento delicado: cambiar el secreto invalida `flows_cred.json` existente. Recomendado solo si se sospecha compromiso del secreto antiguo.

```bash
# 1) Generar nuevo secreto.
NEW_SECRET="$(openssl rand -hex 32)"

# 2) Editar settings.js: añadir TEMPORALMENTE una línea para que NR re-cifre
#    flows_cred.json con la nueva clave.
sudo nano /mnt/hd2t/services/node-red/data/settings.js
# Sustituir el bloque credentialSecret por:
#   credentialSecret: process.env.NODE_RED_CREDENTIAL_SECRET_NEW,
# Y dejar la antigua como comentario para auditoría.

# 3) Editar el .env: añadir las dos variables.
sudo -u homelab nano /mnt/hd2t/services/node-red/.env
# Añadir:
#   NODE_RED_CREDENTIAL_SECRET=<NEW_SECRET>
# (NR re-cifra al primer guardado, leyendo la nueva clave.)

# 4) Reiniciar NR.
docker compose --env-file /mnt/hd2t/services/node-red/.env restart nodered

# 5) Abrir cada nodo con credencial (mqtt-broker, home-assistant-server,
#    bots Telegram, etc.) y volver a meter el secreto en plain. Deploy.
#    Esto fuerza re-escribir flows_cred.json con NEW_SECRET.

# 6) Verificar que flows_cred.json se actualizó:
ls -l /mnt/hd2t/services/node-red/data/flows_cred.json
# (mtime debería ser de hace segundos.)

# 7) Borrar el viejo secreto del password manager y del histórico.
```

### 9.7. Upgrade de Node-RED

Watchtower lo hace automáticamente cuando el operador edita `NODERED_IMAGE_TAG` en `.env`. Procedimiento manual:

```bash
# 1) Leer release notes.
xdg-open https://github.com/node-red/node-red/releases

# 2) Backup pre-upgrade (ad-hoc, complementa Borgmatic).
sudo tar -czf /mnt/hd2t/backups/manual/node-red-$(date +%F).tar.gz \
  -C /mnt/hd2t/services/node-red data

# 3) Editar el .env real con el nuevo tag.
sudo -u homelab nano /mnt/hd2t/services/node-red/.env
# NODERED_IMAGE_TAG=4.0.6   # ejemplo

# 4) Pull + recreate.
cd ~/homelab/stacks/node-red
docker compose --env-file /mnt/hd2t/services/node-red/.env pull
docker compose --env-file /mnt/hd2t/services/node-red/.env up -d

# 5) Verificar logs.
docker compose --env-file /mnt/hd2t/services/node-red/.env logs --tail=50 nodered
# Si NR detecta breaking changes en paletas, las muestra como [error]
# en el primer arranque y los flows correspondientes quedan en rojo.
# Solución: actualizar la paleta (Manage Palette → Update) y deploy.
```

> **Las paletas se preservan**: viven en `/data/node_modules`, no en la imagen. Tras un upgrade, NR ejecuta `npm rebuild` solo si las versiones de Node.js cambian (raro dentro de la misma minor).

---

## 10. Backup

### 10.1. Qué se respalda

| Fichero / directorio | Crítico | Por qué |
|---|---|---|
| `/mnt/hd2t/services/node-red/data/flows.json` | **SÍ** | Lógica de TODOS los flujos. Sin esto, hay que reconstruir desde cero. |
| `/mnt/hd2t/services/node-red/data/flows_cred.json` | **SÍ** | Credenciales cifradas (passwords MQTT, tokens HA, API keys). Inservible sin `credentialSecret`. |
| `/mnt/hd2t/services/node-red/data/settings.js` | Sí | Reproducible desde el stack (`~/homelab/stacks/node-red/settings.js`), pero respaldarlo evita ese paso en disaster recovery. |
| `/mnt/hd2t/services/node-red/data/package.json` | Sí | Lista de paletas instaladas. Permite `npm install` reconstructivo. |
| `/mnt/hd2t/services/node-red/data/lib/` | Sí | Snippets/funciones reutilizables (raros pero aparecen). |
| `/mnt/hd2t/services/node-red/data/.config.*.json` | No (auto-regenerable) | Estado del editor (último flow abierto, sesiones de auth). NR los regenera al arrancar. Respaldarlos por completitud no daña. |
| `/mnt/hd2t/services/node-red/data/node_modules/` | **NO** (opcional) | Paletas npm. Reconstruibles desde `package.json`. Excluir reduce el backup ~300 MB. |
| `/mnt/hd2t/services/node-red/.env` | **SÍ** | Contiene `NODE_RED_CREDENTIAL_SECRET` y `NODE_RED_ADMIN_BCRYPT`. **Además del backup**, ambos secretos viven en el password manager (defense-in-depth: si el backup se corrompe, el secreto sigue accesible). |

### 10.2. Borgmatic

Configuración en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) §3 (sección "Domótica"):

```yaml
# Fragmento de /etc/borgmatic/config.yaml
source_directories:
  # ... otros servicios ...
  - /mnt/hd2t/services/node-red

exclude_patterns:
  # ... otros patterns ...
  # node_modules es reconstruible desde package.json — excluir reduce
  # ~300 MB y acelera backups incrementales.
  - '/mnt/hd2t/services/node-red/data/node_modules'
```

Borgmatic respalda el resto del directorio íntegro, incluido `flows.json`, `flows_cred.json`, `settings.js`, `package.json`, `lib/`, `.config.*.json`, y el `.env`.

### 10.3. Restore (resumen)

```bash
# 1) Parar NR.
cd ~/homelab/stacks/node-red
docker compose --env-file /mnt/hd2t/services/node-red/.env down

# 2) Restaurar /mnt/hd2t/services/node-red/ desde el último archive.
borgmatic extract --archive latest --path mnt/hd2t/services/node-red \
  --destination /tmp/restore-nr

sudo rsync -aAX --delete \
  /tmp/restore-nr/mnt/hd2t/services/node-red/ \
  /mnt/hd2t/services/node-red/

# 3) Asegurar permisos.
sudo chown -R homelab:homelab /mnt/hd2t/services/node-red

# 4) Reinstalar paletas (node_modules NO está en el backup).
docker run --rm --network none \
  -v /mnt/hd2t/services/node-red/data:/data \
  -w /data \
  -u 1000:1000 \
  nodered/node-red:4.0.5 \
  npm install --omit=dev

# 5) Verificar credentialSecret en .env. Si se ha rotado entre el backup
#    y ahora, restaurar el secreto del momento del backup desde el password
#    manager (porque flows_cred.json está cifrado con ESE secreto).

# 6) Levantar.
docker compose --env-file /mnt/hd2t/services/node-red/.env up -d

# 7) Verificar:
docker compose --env-file /mnt/hd2t/services/node-red/.env logs --tail=50 nodered
# Esperado: "Started flows" y todos los nodos con credenciales operativos
# (si el credentialSecret coincide con el que cifró flows_cred.json).
```

### 10.4. Smoke test (ad-hoc)

Mensual:

```bash
# Disparar un flow conocido vía MQTT y verificar respuesta esperada.
# Ejemplo: si hay un flow "ping → log" suscrito a homelab/test/ping:
docker exec mosquitto mosquitto_pub \
  -h localhost -p 1883 \
  -u nodered -P "$NR_PASS" \
  -t 'nodered/test/ping' -m 'hello'

# Verificar en logs de NR que el flow recibió el mensaje:
docker logs nodered --tail=20 | grep 'test/ping'
```

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `[error] Error loading credentials: bad decrypt` en logs al arrancar | `credentialSecret` cambió entre arranques (variable env vacía, settings.js no la lee, o se rotó sin re-cifrar). | Verificar `NODE_RED_CREDENTIAL_SECRET` en `.env`. Si se ha perdido el secreto antiguo, borrar `flows_cred.json` y reintroducir credenciales en cada nodo (§9.6). |
| Nodos `mqtt-in/out` en gris (Connecting...) sin pasar a verde | (a) Mosquitto abajo. (b) Password incorrecta. (c) ACL deniega CONNECT (raro: la ACL deniega a nivel topic, no auth). | `docker logs mosquitto --tail=50` para ver el motivo del rechazo. La línea `Bad username or password from <ip>` confirma (b); reintroducir password en el `mqtt-broker` config node. |
| Nodos `home-assistant-*` en rojo "Token revoked" | LLAT eliminado en HA (Profile → Long-Lived Access Tokens). | Generar nuevo LLAT (§8.3.1) y actualizar el `home-assistant-server` config node. |
| `Error: ENOSPC: no space left on device` durante `npm install` de paleta | hd2t lleno. | `df -h /mnt/hd2t` para confirmar. Limpiar logs antiguos / dumps obsoletos antes de reintentar. |
| Editor accesible desde la LAN sin Authelia (sólo pide login admin de NR) | Caddy no está delante o el bloque del Caddyfile no incluye `import authelia_proxy`. | Revisar `~/homelab/stacks/proxy/Caddyfile` y reload Caddy. |
| Flows.json corrupto tras un crash brusco | Pi rebooteada bruscamente durante un Deploy (raro pero posible). | NR mantiene `/data/flows.json.backup` con la versión anterior. Restaurar: `cp data/flows.json.backup data/flows.json` y reiniciar. |
| Healthcheck `unhealthy` después de un upgrade | NR tarda > 60s en arrancar tras un `npm rebuild` masivo. | Subir `start_period` a 120s en el compose si se observa el patrón repetidamente. |
| Logs spam con `[warn] [function] ... heap out of memory` | Un nodo `function` acumula objetos sin liberar. | Identificar el flow y revisar el código del `function`. Subir temporalmente `--max-old-space-size=768` en `NODE_OPTIONS` mientras se arregla. |
| Tras un upgrade, paleta X no carga: `[error] Module not found: 'XYZ'` | El `npm rebuild` falló silenciosamente (raro pero ocurre con paletas que usan binarios nativos). | Forzar reinstalación: `docker exec -u 1000 nodered bash -c "cd /data && npm rebuild XYZ"` y reiniciar NR. |

### 11.1. Healthcheck alternativo (para paletas sin frontend HTTP)

Si por alguna razón el editor se desactiva (`disableEditor: true` en `settings.js`), el healthcheck de §5 deja de funcionar. Alternativa:

```yaml
# Reemplazar el `healthcheck` en docker-compose.yml por:
healthcheck:
  test:
    - "CMD-SHELL"
    - "pgrep -x node || exit 1"
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 60s
```

Verifica que el proceso `node` está vivo, sin tocar HTTP. Es menos verdadero (un crash silencioso del runtime que deja `node` colgado pero sin servir flujos pasaría desapercibido), pero es la única opción cuando el editor no responde.

---

## 12. Variantes opt-in

### 12.1. Dashboard interactivo (`@flowfuse/node-red-dashboard`)

Instalar:

1. Manage Palette → Install → `@flowfuse/node-red-dashboard` (sucesor de `node-red-dashboard` clásico).
2. NR añade nodos `ui-*` para grids, charts, switches.
3. La UI del dashboard se sirve en `http://nodered:1880/dashboard` (en el contenedor) → `https://nodered.lan/dashboard` vía Caddy.

> **Nota**: el dashboard hereda la auth de NR (`adminAuth`) y de Authelia. Si se quiere un dashboard "público" para invitados (p.ej. una pantalla de pared en el pasillo), exponerlo en un subdominio aparte con bypass específico — fuera del scope del homelab por defecto.

### 12.2. Métricas Prometheus (`node-red-contrib-metrics`)

Instalar:

1. Manage Palette → Install → `node-red-contrib-metrics`.
2. Añadir un flow:
   ```
   [metrics-endpoint http://0.0.0.0:9091/metrics] ──► (auto)
   ```
3. NR expone `/metrics` con métricas estilo prom-client.
4. Editar el `prometheus.yml` de [`../05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md) §4 para añadir el target:
   ```yaml
   scrape_configs:
     - job_name: 'node-red'
       static_configs:
         - targets: ['nodered:9091']
   ```
5. Reload Prometheus.

> Métricas útiles: rate de mensajes por nodo, tiempo de procesamiento de `function`, conexiones MQTT activas. Dashboards de Grafana con [esta plantilla](https://grafana.com/grafana/dashboards/?query=node-red).

### 12.3. Activar Projects (versionado git)

En `settings.js`, cambiar:

```javascript
editorTheme: {
    projects: {
        enabled: true,                        // ← antes false
        workflow: {
            mode: "manual"                    // o "auto" (commit en cada deploy)
        }
    }
}
```

Reiniciar NR. La primera vez, el editor pide configurar un proyecto: nombre, descripción, autor, email, y un repo git destino (puede ser un bare repo en `/mnt/hd2t/services/node-red/data/projects/<nombre>.git`, o un remoto en GitHub/Gitea).

> **Caveat**: Projects requiere SSH key dentro del contenedor para `git push`. Más complejo de operar que el flow normal. Recomendado solo si se gestionan **múltiples proyectos** de NR (p.ej. uno por planta).

### 12.4. Jail fail2ban del editor (sin Authelia)

Si por alguna razón se desactiva Authelia delante (p.ej. acceso solo Tailscale), el `adminAuth` de NR queda como única barrera. Para frenar fuerza bruta:

1. Activar logging a fichero en `settings.js`:
   ```javascript
   logging: {
       console: { level: "info" },
       file: {
           level: "warn",
           filename: "/data/log/node-red.log",
           maxFiles: 5,
           maxSize: 10485760
       }
   }
   ```
2. Crear bind mount adicional `data/log` en docker-compose.yml.
3. Configurar jail en fail2ban ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md)):
   ```ini
   [node-red]
   enabled  = true
   port     = http,https
   filter   = node-red
   logpath  = /mnt/hd2t/services/node-red/data/log/node-red.log
   maxretry = 5
   findtime = 600
   bantime  = 3600
   ```
4. Filter `/etc/fail2ban/filter.d/node-red.conf`:
   ```ini
   [Definition]
   failregex = ^.*\[warn\] login attempt failed.*from <HOST>.*$
   ```

> Mientras Authelia esté delante, este jail es redundante: Authelia ya tiene su propio jail ([`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md) §6).

### 12.5. Persistir el contexto a disco (`localfilesystem`)

Por defecto el contexto (`flow.set('x', 1, "store")`) es in-memory: se pierde al reiniciar NR. Para persistirlo:

```javascript
// En settings.js, sustituir el bloque contextStorage:
contextStorage: {
    default: { module: "memory" },
    file: {
        module: "localfilesystem",
        config: {
            dir: "/data/context",
            flushInterval: 30   // segundos entre fsync
        }
    }
}
```

Y en el flow: `context.flow.set('x', 1, 'file')`. Útil para contadores, máquinas de estado que sobreviven a un restart de NR.

### 12.6. Acceso vía Tailscale sin Caddy

Para uso temporal (debug remoto sin esperar a que `tailscale cert` se complete):

```bash
# Establecer un túnel ad-hoc desde la máquina del operador (vía Tailscale)
# al puerto 1880 del contenedor:
ssh -L 1880:nodered:1880 homelab@<pi-tailscale-name>

# Abrir http://localhost:1880 en el navegador local.
# Autenticación: solo adminAuth (sin Authelia).
```

> **No recomendado en operación**: el adminAuth solo cubre login (sin 2FA). Solo para troubleshooting puntual.

### 12.7. Subflows reutilizables

NR permite encapsular un grafo en un "Subflow" reutilizable:

1. Editor → Menú → "Subflows" → "Create subflow".
2. Arrastrar nodos al lienzo del subflow.
3. Definir entradas/salidas/properties.
4. Volver al flow principal: el subflow aparece en la paleta como nodo único.

Útil para encapsular patrones repetidos (p.ej. "deduplicar evento de movimiento durante N segundos").

### 12.8. Exponer un endpoint HTTP al exterior (webhook)

Para recibir webhooks externos (p.ej. Telegram bot vía Tailscale, GitHub webhooks):

1. Flow:
   ```
   [http in: POST /webhook/foo] ──► [function: validar] ──► [http response: 200]
   ```
2. La URL externa: `https://nodered.lan/api/webhook/foo` (vía Caddy, **con** Authelia delante — esto rompe webhooks anónimos).
3. Para webhooks de servicios externos que **no** pueden hacer SSO: añadir un bloque Caddy específico que bypassee Authelia para `/api/webhook/*` y valide el secret en el `function`:
   ```caddy
   nodered.{$LAN_DOMAIN} {
       import lan_internal_tls
       import security_headers

       # Webhooks externos: bypass Authelia, validación en NR.
       @webhook path /api/webhook/*
       reverse_proxy @webhook http://nodered:1880

       import authelia_proxy
       reverse_proxy http://nodered:1880 {
           # ... headers ...
       }
   }
   ```

> **Riesgo**: cualquiera con la URL puede llamar al webhook. Mitigación: validar un `X-Webhook-Secret` en el `function` y rechazar 401 si no coincide.

---

## Referencias

- **Documentación oficial**:
  - Node-RED: [https://nodered.org/docs/](https://nodered.org/docs/)
  - User guide: [https://nodered.org/docs/user-guide/](https://nodered.org/docs/user-guide/)
  - `settings.js` reference: [https://nodered.org/docs/user-guide/runtime/settings-file](https://nodered.org/docs/user-guide/runtime/settings-file)
  - Security: [https://nodered.org/docs/user-guide/runtime/securing-node-red](https://nodered.org/docs/user-guide/runtime/securing-node-red)
  - Projects: [https://nodered.org/docs/user-guide/projects/](https://nodered.org/docs/user-guide/projects/)
  - Imagen Docker: [https://hub.docker.com/r/nodered/node-red](https://hub.docker.com/r/nodered/node-red)
- **Paletas usadas**:
  - HA WebSocket: [https://flows.nodered.org/node/node-red-contrib-home-assistant-websocket](https://flows.nodered.org/node/node-red-contrib-home-assistant-websocket)
  - Catálogo de paletas: [https://flows.nodered.org/](https://flows.nodered.org/)
- **Documentos del homelab relacionados**:
  - Hub MQTT: [`./02-mosquitto.md`](./02-mosquitto.md)
  - Plataforma de automatización: [`./01-home-assistant.md`](./01-home-assistant.md)
  - Cliente Zigbee → MQTT: [`./03-zigbee2mqtt.md`](./03-zigbee2mqtt.md)
  - Reverse proxy Caddy: [`../03-red/04-caddy.md`](../03-red/04-caddy.md)
  - SSO/2FA Authelia: [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)
  - Política de Watchtower: [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)
  - Estructura de directorios en hd2t: [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)
  - Backup con Borgmatic: [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)
  - Métricas con Prometheus: [`../05-monitorizacion/01-prometheus.md`](../05-monitorizacion/01-prometheus.md)
  - Logs con Dozzle: [`../05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)
  - Fail2ban: [`../04-seguridad/02-fail2ban.md`](../04-seguridad/02-fail2ban.md)
