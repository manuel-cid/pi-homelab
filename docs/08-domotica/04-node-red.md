# Node-RED

## Descripción

Con Home Assistant (`01-home-assistant.md`), Mosquitto (`02-mosquitto.md`) y Zigbee2MQTT (`03-zigbee2mqtt.md`) desplegados, el homelab ya tiene **cerebro**, **nervios** y **sentidos físicos**. Lo que falta es un sitio donde escribir **lógica de orquestación compleja** sin enterrar el `configuration.yaml` de HA bajo cientos de YAML, sin perder la legibilidad de un diagrama y sin acoplar la lógica a un único stack.

**Node-RED** es ese sitio. Conceptualmente es un *flow editor* basado en Node.js: el operador conecta bloques (*nodes*) en un canvas web (`/red/`), cada nodo lee mensajes de una entrada, hace algo (un `if`, una llamada HTTP, una transformación de payload, una temporización), y emite un mensaje a su salida. Los flujos viven en JSON (`flows.json`), versionables en git, exportables, importables. Lo importante para este homelab no es que Node-RED *pueda* hacer cualquier cosa — sino que es la herramienta correcta para los **3 casos** que las automatizaciones nativas de HA hacen mal:

1. **Lógica con estado y temporizadores complejos**. "Si la puerta se abre y nadie pulsa el botón en 30 segundos, manda push y enciende todas las luces, salvo si es de día y hay alguien detectado por presencia." En HA YAML eso es un *script* anidado de difícil lectura. En Node-RED son 5 nodos en línea, autoexplicativos.
2. **Integración con sistemas externos sin integración nativa**. Llamar a una API REST de un proveedor cualquiera (compañía eléctrica, AEMET, web del barrio), parsear su JSON, publicar el resultado a MQTT y dejar que HA lo recoja. En HA esto exige escribir un *custom component* en Python; en Node-RED es un nodo `http request` + un `function`.
3. **Pipelines de mensajes MQTT**. Reescribir tópicos, agregar varios sensores en uno virtual, hacer media móvil, deduplicar mensajes, traducir entre formatos (Tasmota → ESPHome → HA). Todo eso es trivial en Node-RED y horrible en YAML.

Su rol concreto en este homelab:

1. **Cliente MQTT** contra Mosquitto en `mosquitto:1883` con el usuario `nodered` ya creado en `02-mosquitto.md` (ACL `readwrite nodered/#` + `readwrite homeassistant/#` + `read zigbee2mqtt/#`).
2. **Cliente WebSocket** de HA mediante la paleta `node-red-contrib-home-assistant-websocket`: lee estados de cualquier entidad, llama a servicios (`light.turn_on`, `notify.mobile_app_*`), suscribe a eventos. Es el sustituto natural de la mitad del catálogo de `automation:` de HA.
3. **Editor web propio** en `:1880/red/` (canvas de flujos) y un *dashboard* opcional `:1880/dashboard` (cuadros de mando ad-hoc; **no se usa** en este homelab — los dashboards viven en HA, ver decisión abajo).
4. **Persistencia de flujos** en `flows.json` + `flows_cred.json` (cifrado con `credentialSecret`) en `hd2t`. Los flujos sobreviven a reinicios; las credenciales (tokens, contraseñas embebidas en nodos) viven cifradas en disco.
5. **Punto de extensión vía paletas (`npm install`)** — Home Assistant, Telegram, Pushover, AEMET, Modbus, OWM, dashboard, etc. Cada paleta es un paquete npm; se instalan desde la UI o por línea de comandos.

Lo que este documento **no** decide:

- **Qué automatizaciones concretas** vivirán en Node-RED y cuáles en HA (`automations.yaml`). Hay un criterio operativo abajo, pero los flujos específicos los crea el operador a medida que vaya identificando casos de uso.
- **Dashboards de cara al usuario final**: no se publica el dashboard de Node-RED. Quienes consumen el homelab a diario (familia) usan **solo HA**, que ya tiene su Lovelace + Companion App. Node-RED es **herramienta del operador**, no UI doméstica.
- **HACS / blueprints / scripts en HA**: pertenecen a `01-home-assistant.md` y a la operación normal de HA.
- **n8n / Huginn / IFTTT-likes externos**: descartados (ver decisión abajo).
- **Editor sin auth**: en LAN cerrada *podría* parecer aceptable, pero no lo es: cualquier dispositivo IoT comprometido en LAN podría modificar flujos y disparar acciones. Editor con `adminAuth` obligatorio.
- **Authelia delante del editor**: descartado por el mismo motivo que con HA y Z2M (rompe el WebSocket interno del editor). Se usa `lan_only` + `adminAuth` nativo. Más detalle abajo.

Cuando este documento se haya aplicado, el operador puede:

- Ver Node-RED **`Up (healthy)`** en `docker ps`, conectado a Mosquitto (log `Connected to broker mqtt://mosquitto:1883`) y a HA (paleta de HA en estado *connected*).
- Abrir `https://nodered.${DOMAIN_LAN}/red/` desde la LAN, autenticarse con usuario+password, ver el editor con un único flujo de ejemplo ("smoke test: ping MQTT cada minuto y log a consola") y poder *deploy*.
- Confirmar en `mosquitto_sub -t 'nodered/#'` que ese smoke test publica.
- Confirmar en HA → Developer Tools → Events que Node-RED puede emitir eventos de tipo `nodered.smoke_test`.
- Tener `flows.json`, `flows_cred.json`, `settings.js` y `package.json` materializados en `hd2t`, listos para Borgmatic en T1.

> **Recordatorio de alcance**: Node-RED es **solo LAN + tailnet**. La UI publica únicamente en `https://nodered.${DOMAIN_LAN}` (Caddy con `lan_tls` + `lan_only`); el puerto `:1880` no se publica al WAN. Los nodos `http in` que el operador pueda crear en el futuro quedan también detrás de Caddy y siguen restringidos a la LAN; cualquier endpoint público debería pasar por una capa explícita (no contemplada en este homelab).

---

## Requisitos Previos

- **Fase 1** completa (sistema base, hostname `pi5`, zona horaria, locale).
- **Fase 2** completa (Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID=1000`, `PGID=1000`, `DOMAIN_LAN=lan`).
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre `nodered.${DOMAIN_LAN}` automáticamente).
  - Caddy desplegado y los snippets `(lan_tls)`, `(lan_only)`, `(security_headers)`, `(healthcheck)` en `Caddyfile`.
- **Fase 4** completa: Authelia existe pero **no** se usa con Node-RED (decisión documentada abajo).
- **Documento `01-home-assistant.md` aplicado**: HA escuchando en `:8123` del host con la integración MQTT operativa.
- **Documento `02-mosquitto.md` aplicado**: Mosquitto en `:1883` accesible por `mosquitto:1883` desde el bridge `homelab`. Usuario `nodered` ya creado con ACL `readwrite nodered/#` + `readwrite homeassistant/#` + `read zigbee2mqtt/#`. Password generada y disponible en el gestor de contraseñas del operador (`NR_PWD`).
- **Documento `03-zigbee2mqtt.md` aplicado** (no estrictamente necesario para *arrancar* Node-RED, sí necesario para que sus flujos tengan algo que escuchar/disparar).
- **Token de larga duración (LLT) de HA** para la paleta `home-assistant-websocket`. Se genera tras el primer arranque (paso documentado en "Configuración"). Se guarda en el gestor de contraseñas del operador.
- Disco `hd2t` montado en `/mnt/hd2t` con al menos **1 GiB** libre reservado para Node-RED (`flows*.json`, `node_modules` de paletas instaladas, logs).
- Operador con la **CA interna instalada** en el navegador (igual que para HA y Z2M).

Comprobaciones rápidas:

```bash
# Red Docker compartida y dependencias sanas
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok
docker ps --filter name=mosquitto --format '{{.Names}} {{.Status}}'
# mosquitto   Up 1 day (healthy)
docker ps --filter name=homeassistant --format '{{.Names}} {{.Status}}'
# homeassistant   Up 1 day (healthy)

# nodered.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short nodered.lan @192.168.1.2
# 192.168.1.10

# El usuario 'nodered' existe en Mosquitto (smoke desde el host)
mosquitto_pub -h 127.0.0.1 -p 1883 -u nodered -P "$NR_PWD" -t nodered/precheck -m ok
echo "exit=$?"
# exit=0

# El usuario 'nodered' NO puede publicar fuera de su sandbox
mosquitto_pub -h 127.0.0.1 -p 1883 -u nodered -P "$NR_PWD" -t fuera/del/scope -m x
docker logs mosquitto --tail 5 | grep -i denied
# 1234567890: Denied PUBLISH from nodered ...

# Espacio libre en hd2t
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'
# 1.4T libres
```

> **Sobre el LLT de HA**. Node-RED se autentica contra la API/WebSocket de HA con un *Long-Lived Access Token*. Se genera **una vez**, no caduca, y se almacena cifrado en `flows_cred.json` (con `credentialSecret`). Si se compromete, se revoca desde el perfil del usuario en HA y se genera otro nuevo. Política: **un LLT exclusivo para Node-RED**, no reutilizable por otros clientes. Lo crearemos durante "Configuración".

> **Sobre los `node_modules` y la microSD**. La instalación de paletas (`npm install`) escribe a `node_modules` dentro del data dir. Mantenerlo en `hd2t` (no en microSD) es importante: una paleta compleja como `node-red-contrib-home-assistant-websocket` arrastra ~50 MiB de dependencias, y `npm install` hace muchas operaciones de IO de archivos pequeños — exactamente lo que daña una microSD. Coherente con la política del resto del homelab.

---

## Decisión: motor de automatización — Node-RED vs alternativas

Hay tres lugares donde escribir lógica de orquestación en este stack:

| Opción | Qué es | Pros | Contras | Veredicto |
|---|---|---|---|---|
| **Solo HA `automations.yaml` + `scripts.yaml`** | Definición declarativa nativa, editable desde la UI de HA. | (1) Cero stack extra. (2) Misma BBDD para historial. (3) Familiar para cualquiera que conozca HA. | (1) YAML anidado se vuelve ilegible para flujos con estado. (2) Difícil debugar — no hay step-through. (3) Sin acceso fácil a scripting general (HTTP request, transformaciones JSON, etc., requieren custom components o `shell_command`). | Suficiente para automatizaciones simples; insuficiente como única herramienta. |
| **Node-RED** | Editor visual de flujos, basado en Node.js. Una paleta para casi todo. | (1) Lógica compleja autoexplicativa. (2) Debug por step (botón derecho en cualquier nodo: "see message"). (3) Catálogo enorme de paletas (4.000+). (4) JSON exportable y versionable. (5) Ya usado masivamente en homelabs HA — comunidad enorme. | (1) Un contenedor más, una UI más, una capa más que mantener. (2) Las paletas son `npm`; cada una es código que corre — auditar antes de instalar. | **Aceptado** como complemento de HA. |
| **n8n** | "Zapier self-hosted". Editor visual, pero orientado a *integraciones SaaS*. | UI más moderna. Ejecuciones registradas en BBDD propia. | (1) Atado a workflows con triggers HTTP/cron, no a streams MQTT en vivo. (2) Sin paleta nativa de HA equivalente. (3) Más pesado (BBDD postgres separada). | Descartado: la fortaleza de n8n son APIs SaaS, que no son el caso de uso del homelab. |
| **Huginn / Apache NiFi / Benthos** | Frameworks de stream processing. | Potencia bruta. | Curva de aprendizaje brutal para el caso de uso. | Descartado por sobreingeniería. |

Resultado: **Node-RED como complemento de HA**, con criterio operativo de "qué va dónde":

| Caso | Sitio |
|---|---|
| Toggle simple ("si abre puerta → enciende luz") | HA `automations.yaml`. |
| Cualquier *script* en HA (`scripts.yaml`) | HA. |
| Cadena de condiciones complejas con `if/elif/else` y estado | Node-RED. |
| Integración con API externa que no tiene custom component | Node-RED. |
| Transformación / agregación / reescritura de tópicos MQTT | Node-RED. |
| Notificaciones con plantilla rica (markdown, fotos, deep-links) | Node-RED. |
| Lógica que dispara *otra* automatización de HA | indistinto; preferir HA si no añade lógica. |

Implicaciones:

- Stack independiente en `stacks/nodered/`.
- Comunicación con HA por **WebSocket** (paleta `home-assistant-websocket`), no por REST polling — más eficiente y bidireccional.
- Comunicación con dispositivos por **MQTT** vía Mosquitto, no por sus APIs específicas.
- Node-RED **no** habla directamente con Z2M ni con dispositivos Zigbee — pasa siempre por Mosquitto (y, cuando aplica, por HA). Esto desacopla.

> **Por qué no usar Node-RED *en lugar* de HA `automations.yaml`**. Hay homelabs donde toda la automatización vive en Node-RED y HA queda solo como "estado + UI". Es una opción viable, pero pierde el catálogo de blueprints de HA y obliga a recrear ruedas (timers de presencia, condiciones de "casa vacía", etc.) que en HA son una línea. Política aquí: **HA primero, Node-RED cuando HA queda corto**. Que ambos coexistan no duplica trabajo si se respeta el criterio.

> **Sobre el dashboard de Node-RED (`node-red-dashboard`)**. Es una paleta que añade una UI de cuadros de mando (`/dashboard`) similar a Lovelace pero más limitada. **Descartado para este homelab**: HA Lovelace cubre el caso, y mantener dos UIs domésticas (la de HA y la de NR) es ruido para los usuarios finales. Reabrible si el operador quiere dashboards técnicos solo para sí mismo (no para la familia); en ese caso, la paleta se instala y el endpoint `/ui/` queda detrás del mismo `lan_only`.

---

## Decisión: imagen y versión

Node-RED publica imágenes oficiales en Docker Hub bajo `nodered/node-red`. Hay etiquetas:

| Tag | Qué es | Veredicto |
|---|---|---|
| `latest` | Última stable. | Descartado: política del homelab es pinear. |
| `4.0.5` (semver fija) | Versión exacta. Multi-arch (`linux/arm64`, `linux/amd64`, `linux/arm/v7`). | Aceptable para pin estricto. |
| `4.0` (rama menor móvil) | Recibe parches `4.0.x`. | **Aceptado**: paralelismo con la política del resto del homelab. |
| `4.0-debian` | Variante con base Debian (en lugar de Alpine). | Reabrible si alguna paleta exige glibc; por defecto Alpine. |
| `latest-minimal` | Sin paletas extra, base mínima. | Descartado: queremos las paletas básicas precargadas. |

**Tag exacto en uso**: `nodered/node-red:4.0`. Política: pin a la rama menor; los bumps de minor (`4.0 → 4.1`) son **manuales**, leyendo release notes (los cambios de minor de NR ocasionalmente cambian el formato de `flows.json` o el contrato de algunos nodos core).

> **Por qué Alpine y no Debian**. Alpine es ~150 MiB más pequeña, suficiente para el 99% de las paletas. Las únicas paletas que históricamente exigen Debian son binarios nativos exóticos (alguna integración Modbus pre-2022). Si aparece el caso, se cambia a `4.0-debian` y se documenta la razón en el commit.

> **Política de actualización**:
> 1. Leer release notes en https://nodered.org/blog/.
> 2. Backup de `flows.json`, `flows_cred.json`, `settings.js`, `package.json`: `sudo tar czf /mnt/hd2t/backups/nodered-pre-bump-$(date +%F).tgz -C /mnt/hd2t/apps nodered`.
> 3. Cambiar el tag en `docker-compose.yml`.
> 4. `docker compose -f stacks/nodered/docker-compose.yml pull && up -d`.
> 5. Verificar editor accesible + flujo de smoke test ejecutando + paletas en estado *loaded*.

---

## Decisión: networking — bridge `homelab`, sin `host`, UI publicada via Caddy

Node-RED no necesita multicast: solo TCP unicast contra Mosquitto y HA (este último por WebSocket en `:8123`), y HTTP entrante para su editor. Vive limpio en el bridge.

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| **Bridge `homelab` sin `ports:`, UI vía Caddy** | UI publicada en `https://nodered.${DOMAIN_LAN}`, no hay `:1880` directamente expuesto en LAN. NR habla con Mosquitto por DNS interno (`mosquitto:1883`) y con HA por `host.docker.internal:8123`. | Operador no puede saltarse Caddy en LAN. | **Aceptado**. |
| **Bridge `homelab` + `ports: ["1880:1880"]`** | UI directa en `192.168.1.10:1880` *además* de via Caddy. | Doble entrada confunde — uno con TLS y otro sin. | Descartado. |
| **`network_mode: host`** | Sin sentido aquí (no hay multicast). | Pierde DNS interno, rompe la convención. | Descartado. |

Resultado: **bridge `homelab`, sin `ports:`, UI vía Caddy con `lan_tls`**. Implicaciones:

1. **MQTT**: Node-RED conecta a `mqtt://nodered:<password>@mosquitto:1883`. Bridge → bridge, sin pasar por host.
2. **HA**: Node-RED conecta a `http://host.docker.internal:8123`. HA está en `network_mode: host` (decisión de `01-home-assistant.md` para que mDNS funcione), por lo tanto **no resuelve por DNS de bridge**. Se llega a él vía la entrada `extra_hosts: ["host.docker.internal:host-gateway"]` en el compose de Node-RED — el mismo patrón que Caddy usa para llegar a HA.
3. **Editor**: Caddy proxa `https://nodered.${DOMAIN_LAN}` → `http://nodered:1880`. WebSocket del editor (`/comms`) atravesado automáticamente por Caddy v2.
4. **Firewall del host**: no es necesario abrir `:1880` en `nftables`; Caddy es la única vía pública al editor, en `:443`.

> **Sobre `host.docker.internal:host-gateway`**. Compose v2 traduce `host-gateway` a la IP del bridge Docker desde el contenedor (típicamente `172.30.10.1`). Es la vía limpia para que un contenedor en bridge llegue al host sin asumir IP fija. Se usa idénticamente en Caddy para llegar a HA.

---

## Decisión: persistencia y permisos

Node-RED escribe en su data dir constantemente: `flows.json` (en cada *deploy*), `flows_cred.json` (cuando se cambia una credencial), `package.json` (al instalar paleta), `node_modules/` (idem), `.config.runtime.json` (estado runtime). Todo eso debe vivir en `hd2t`.

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| **Bind mount `/mnt/hd2t/apps/nodered:/data`** | Persistencia explícita en disco con backup directo por Borgmatic; permisos visibles desde host. | Hay que crear el directorio con el owner correcto antes del primer arranque. | **Aceptado**. |
| **Volumen Docker nombrado** | Docker maneja permisos y path. | Path opaco, peor para Borgmatic, peor para ls/du desde host. | Descartado. |

Resultado: **bind mount a `/mnt/hd2t/apps/nodered/data`**. El proceso de Node-RED dentro del contenedor corre como **`node-red`** (UID `1000`, GID `1000` en la imagen oficial). Coincidencia útil: nuestra convención del homelab (`PUID=1000`, `PGID=1000`) calza directamente, así que el directorio se crea con `chown 1000:1000`.

> **Sobre `userns_remap` y permisos**. Algunas guías recomiendan `userns_remap` para que el contenedor corra con un UID alto en el host. **No** se usa aquí — ya tenemos `1000:1000` que es el operador (`homelab`), por tanto el operador puede leer y editar `flows.json` desde el host sin sudo. Coherente con HA y con el resto del homelab.

> **Sobre logs**. Node-RED escribe a stdout por defecto (Docker captura). **No** se activa el log a fichero (`logging.file`). Un solo origen de verdad: `docker logs nodered`. Si en troubleshooting hace falta retención, se sube `logging.console.level` a `debug` temporalmente.

---

## Decisión: seguridad del editor — `adminAuth` nativo, **no** Authelia

Node-RED expone:

- `/red/`: el editor (canvas de flujos, paletas).
- `/`: redirección al editor en versiones recientes.
- `/comms`: WebSocket interno entre el editor y el runtime (sincroniza el estado del canvas).
- (opcional) `/dashboard` o `/ui/` si se instala `node-red-dashboard`.
- (opcional) endpoints HTTP que el operador defina con nodos `http in`.

Sin auth, **cualquiera con acceso a `:1880` puede modificar flujos y disparar acciones**. Inaceptable, incluso en LAN.

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| **Sin auth + Caddy con `(authelia_two_factor)`** | SSO con el resto del homelab. | El editor usa **WebSocket** intensivo (`/comms`); Authelia rompe la conexión inicial igual que con HA y Z2M. Se podría exonerar `/comms`, pero entonces la auth es cosmética. | Descartado. |
| **`adminAuth` nativo + Caddy con `(lan_only)` + `(lan_tls)`** | Doble barrera: solo accesible desde LAN/tailnet, y aun así pide usuario+contraseña. WebSockets funcionan sin tocarlos. Multiusuario nativo (admin / read-only). | El operador maneja credenciales propias del editor (no SSO). Aceptable: una credencial más en el gestor. | **Aceptado**. |
| **Sin auth + Caddy con `basic_auth`** | Caddy maneja la auth. | Caddy `basic_auth` no entiende los endpoints de paletas (algunas APIs internas piden tokens propios). Lía. | Descartado. |
| **Sin auth + acceso restringido por firewall a IPs específicas** | Sin contraseña que recordar. | Cualquiera en LAN entra. Dispositivo IoT comprometido = control total. | Descartado. |

Resultado: **`adminAuth` con bcrypt + `lan_only` en Caddy**. El bcrypt se genera con la utilidad oficial:

```bash
docker run --rm nodered/node-red:4.0 npx node-red-admin@latest hash-pw
# Password:
# $2a$08$Xr7Hb0S6WJX...   <- copiar al settings.js
```

La password en claro **no** se guarda en `.env` ni en compose: solo el hash en `settings.js`. La password se guarda en el gestor de contraseñas del operador.

> **Sobre `adminAuth` con dos roles**. Node-RED soporta `users: [{username, password, permissions}]` con permisos `*` (admin: edita flujos) o `read` (solo ve). Para este homelab se define **un solo usuario admin** (`admin`). Reabrible si en algún momento un familiar técnico necesita ver flujos sin poder editarlos.

> **Sobre `httpNodeAuth` y `httpStaticAuth`**. Son auths separadas para los endpoints `http in` y los recursos estáticos servidos por NR. **No se configuran ahora**: si en el futuro el operador define un `http in` que se quiera proteger con auth diferente al editor, se añade entonces. La capa `lan_only` ya cubre el caso por defecto.

---

## Decisión: integración con HA — paleta `home-assistant-websocket`

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| **REST polling: nodos `http request` contra `:8123/api/states/*`** | Sin paleta extra. | (1) Polling: latencia alta, carga innecesaria. (2) Tokens manualmente. (3) No hay eventos en vivo. | Descartado. |
| **Paleta `node-red-contrib-home-assistant-websocket`** | (1) WebSocket: streaming bidireccional, eventos en vivo. (2) Nodos específicos de HA (`call service`, `wait until`, `events: state`, `current state`). (3) Trigger automation desde NR usando el catálogo nativo de servicios de HA. | Una paleta más; código de comunidad activo (~5k stars en GitHub). | **Aceptado**. |
| **Paleta `node-red-contrib-home-assistant`** (legacy, sin "websocket") | Existe. | Sin mantenimiento desde 2018; usa REST. | Descartado por obsolescencia. |

Resultado: **`node-red-contrib-home-assistant-websocket`** preinstalada en el primer arranque vía `extraNodes` (ver `settings.js` abajo). Configuración:

- URL: `http://host.docker.internal:8123` (HA está en `host`).
- Token: el LLT generado en HA (paso documentado en "Configuración").
- Reconexión automática (built-in en la paleta).

> **Por qué no `https://home.lan` en lugar de `host.docker.internal:8123`**. La paleta llamaría a Caddy → HA, lo que duplica salto y exige que el contenedor de NR confíe en la CA interna. Llamar directo al puerto interno de HA es más limpio y evita el TLS innecesario internal-to-internal.

> **Sobre el versionado de la paleta**. La paleta sigue su propio semver. Política: versión fijada en `package.json` (no `latest`), bumps manuales tras leer changelog. La instalación inicial fija `^0.62` (la actual a fecha de redacción).

---

## Decisión: paletas adicionales — política conservadora

Node-RED tiene un catálogo enorme de paletas. Política aplicada:

| Paleta | Para qué | Política |
|---|---|---|
| `node-red-contrib-home-assistant-websocket` | Cliente de HA. | **Preinstalada** en `package.json` desde el bootstrap. |
| `node-red-contrib-influxdb` | Escribir métricas a InfluxDB. | **No** se preinstala. Reabrible cuando F05 monitorización lo requiera. |
| `node-red-dashboard` | UI dashboard. | **No** se preinstala (decisión arriba). |
| `node-red-contrib-telegrambot` | Notificaciones por Telegram. | **No** se preinstala. Reabrible si el operador la quiere. Token vía `credentialSecret`. |
| `node-red-contrib-pushover` | Notificaciones Pushover. | Idem. |
| `node-red-contrib-aemet` / scrapers de proveedor | APIs externas. | Caso a caso por el operador. |
| `node-red-contrib-modbus`, `-bacnet`, `-knx` | Protocolos industriales. | Idem; no aplican a este homelab por defecto. |

Política general: **una paleta nueva = un commit** en el repo del homelab modificando `stacks/nodered/package.json` (no instalar desde la UI sin documentar). Esto evita que el `package.json` de `hd2t` y el del repo se desincronicen, y deja trazabilidad de "por qué está esto aquí".

> **Sobre `npm audit` y supply chain**. Cada paleta es un paquete npm que descarga sus dependencias. Cualquiera de ellas podría tener vulnerabilidades o ser maliciosa. Política mínima:
> 1. Antes de añadir una paleta, leer las stars / issues / último commit en GitHub. Una paleta sin actividad >1 año es sospechosa.
> 2. Tras instalar, ejecutar `docker exec nodered npm audit --production` y revisar.
> 3. Pin a versión exacta o caret de minor (`^X.Y`) — no `*`.

---

## Stack: `stacks/nodered/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/nodered/docker-compose.yml` | microSD (git) | Stack (servicio `nodered`). |
| `stacks/nodered/.env.example` | microSD (git) | Plantilla con `NR_*`. |
| `stacks/nodered/settings.js.skel` | microSD (git) | Esqueleto de `settings.js` (con `adminAuth`, `credentialSecret` placeholders). |
| `stacks/nodered/package.json.skel` | microSD (git) | `package.json` inicial con la paleta de HA. |
| `stacks/caddy/conf.d/08-nodered.caddy` | microSD (git) | Drop-in del bloque LAN para `nodered.${DOMAIN_LAN}`. |
| `/mnt/hd2t/apps/nodered/data/` | hd2t | Data dir de NR (settings, flows, paletas). Owner `1000:1000`. |
| `/mnt/hd2t/apps/nodered/data/settings.js` | hd2t | Configuración runtime (incluye hash de la password). |
| `/mnt/hd2t/apps/nodered/data/flows.json` | hd2t | Flujos (JSON). |
| `/mnt/hd2t/apps/nodered/data/flows_cred.json` | hd2t | Credenciales cifradas con `credentialSecret`. **CRÍTICO**. |
| `/mnt/hd2t/apps/nodered/data/package.json` | hd2t | Paletas declaradas. |
| `/mnt/hd2t/apps/nodered/data/package-lock.json` | hd2t | Lockfile generado por `npm install`. |
| `/mnt/hd2t/apps/nodered/data/node_modules/` | hd2t | Dependencias instaladas. **No** se respalda (regenerable). |
| `/mnt/hd2t/apps/nodered/data/.config.*.json` | hd2t | Estado runtime (sesiones, último deploy, etc.). |

### `stacks/nodered/docker-compose.yml`

```yaml
# Node-RED — motor de flujos visuales del homelab.
# Documentado en docs/08-domotica/04-node-red.md.

name: nodered

services:
  nodered:
    image: nodered/node-red:4.0
    container_name: nodered
    hostname: nodered
    restart: unless-stopped

    # Bridge homelab — habla con mosquitto:1883 por DNS interno y con
    # HA via host.docker.internal:8123 (HA está en network_mode: host).
    networks:
      - homelab

    # Necesario para llegar a HA (que vive en host).
    extra_hosts:
      - "host.docker.internal:host-gateway"

    # Misma convención de UID/GID que el resto del homelab; coincide
    # con el usuario 'node-red' (1000:1000) interno de la imagen.
    user: "1000:1000"

    environment:
      TZ: ${TZ}
      # Locale dentro del contenedor (afecta logs y nodos de fechas).
      LANG: en_US.UTF-8
      # Limitar heap de Node a ~512 MiB en una Pi 5 8 GiB. Suficiente
      # para 100s de flujos; protege frente a fugas de paletas raras.
      NODE_OPTIONS: "--max_old_space_size=512"
      # Carpeta donde NR busca settings.js, flows.json, package.json.
      NODE_RED_USER_DIR: /data
      # Flujos por defecto.
      FLOWS: flows.json

    volumes:
      - /mnt/hd2t/apps/nodered/data:/data
      # Hora consistente con el host (logs y schedulers).
      - /etc/localtime:/etc/localtime:ro

    # No se publican puertos: la UI sale via Caddy en nodered.${DOMAIN_LAN}.
    # ports: []

    healthcheck:
      # Endpoint público (no requiere auth) que devuelve un JSON con
      # version + state. Si NR está sano, responde 200.
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:1880/red/about >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 90s   # primer arranque con npm install: lento

    depends_on:
      mosquitto:
        condition: service_healthy
        required: false
      # required:false: si Mosquitto NO está, NR arranca igual y sus
      # nodos MQTT entran en modo "reconnect" hasta que aparezca el
      # broker. Misma política que Z2M.

    labels:
      homelab.role: "automation-engine"
      homelab.backup: "true"
      # Watchtower respeta el pin a 4.0.x (parches), no salta a 4.1.
      com.centurylinklabs.watchtower.enable: "true"

networks:
  homelab:
    external: true
```

> **Sobre `user: "1000:1000"`**. La imagen oficial de Node-RED corre por defecto como UID `1000` (usuario `node-red`). Forzarlo explícito (a) protege frente a un cambio futuro de la imagen (b) hace explícita la coincidencia con `PUID/PGID` global del homelab.

> **Sobre `NODE_OPTIONS=--max_old_space_size=512`**. Sin esto, Node.js puede escalar el heap hasta consumir RAM de la Pi si una paleta tiene una fuga. 512 MiB es ampliamente suficiente para Node-RED solo (incluso con 100+ flujos activos consume ~150 MiB). Si el operador instala una paleta especialmente pesada (Modbus a gran escala, scraping continuo) y NR muere con `JavaScript heap out of memory`, subirlo a 1024.

> **Sobre `start_period: 90s`**. El **primer** arranque del contenedor ejecuta `npm install` para resolver `package.json`. En la Pi 5 con 8 GiB y disco USB 3, son ~60–80s. Sin un `start_period` generoso, el healthcheck marca *unhealthy* falsamente. Tras el primer arranque, los siguientes son <10s (las dependencias ya están en `node_modules`).

### `stacks/nodered/.env.example`

```bash
# stacks/nodered/.env.example
# Variables específicas del stack Node-RED. Las generales (TZ)
# vienen del .env GLOBAL del homelab.
#
# Las contraseñas/secretos REALES (mqtt password, HA token, hash
# del adminAuth, credentialSecret) NO viven aquí: están en
# /mnt/hd2t/apps/nodered/data/settings.js (modo 0600) y en los
# nodos cifrados de flows_cred.json.
#
# (Vacío hoy: este stack no usa variables de entorno propias.)
```

### `stacks/nodered/settings.js.skel`

Esqueleto del primer arranque. La imagen oficial trae un `settings.js` por defecto que **no** se sobreescribe automáticamente: hay que copiar este skel en su sitio antes del primer `up -d`.

```javascript
// /data/settings.js — Node-RED.
// Documentado en docs/08-domotica/04-node-red.md.
//
// Sustituir los <PLACEHOLDERS> antes del primer arranque:
//   <ADMIN_BCRYPT_HASH>   — generar con:
//                           docker run --rm nodered/node-red:4.0 \
//                               npx node-red-admin@latest hash-pw
//   <CREDENTIAL_SECRET>   — generar con: openssl rand -base64 32
//
// Este fichero se materializa en hd2t con permisos 0600 (contiene secretos).

module.exports = {
    // -----------------------------------------------------------------
    // Bind y UI
    // -----------------------------------------------------------------
    uiPort: process.env.PORT || 1880,
    uiHost: "0.0.0.0",
    httpAdminRoot: "/red",          // editor en /red, no en /
    httpNodeRoot: "/api",           // endpoints http in del operador en /api
    // httpStatic: "/data/static",  // si se sirviese estático custom

    // -----------------------------------------------------------------
    // Auth de admin (editor)
    // -----------------------------------------------------------------
    adminAuth: {
        type: "credentials",
        users: [{
            username: "admin",
            password: "<ADMIN_BCRYPT_HASH>",
            permissions: "*"
        }],
        // Sesión de 12 horas; el operador entra y sale durante el día.
        sessionExpiryTime: 43200
    },

    // -----------------------------------------------------------------
    // Cifrado de credenciales (flows_cred.json)
    // -----------------------------------------------------------------
    // CRÍTICO: si se pierde, todas las credenciales (token de HA,
    // password de paletas) quedan ilegibles.
    credentialSecret: "<CREDENTIAL_SECRET>",

    // -----------------------------------------------------------------
    // Runtime
    // -----------------------------------------------------------------
    flowFile: "flows.json",
    flowFilePretty: true,            // legible en git diffs
    userDir: "/data/",

    // -----------------------------------------------------------------
    // Paletas instaladas vía package.json en bootstrap
    // -----------------------------------------------------------------
    // Permitir instalar paletas adicionales desde la UI.
    editorTheme: {
        palette: {
            // Permite instalar paletas desde "Manage palette" en el editor.
            // Se mantiene activado para iteración del operador; cualquier
            // paleta instalada ASÍ debe luego replicarse en package.json
            // (política: paletas declarativas en git).
            editable: true
        },
        projects: {
            // Modo "projects" deshabilitado — se versiona la carpeta /data
            // entera con backup, no con feature interna de NR.
            enabled: false
        }
    },

    // -----------------------------------------------------------------
    // Logging
    // -----------------------------------------------------------------
    logging: {
        console: {
            level: "info",          // info|warn|debug|trace
            metrics: false,
            audit: false
        }
    },

    // -----------------------------------------------------------------
    // Function nodes — librerías globales accesibles desde Function
    // -----------------------------------------------------------------
    functionGlobalContext: {
        // Disponible como context.global.os en cualquier Function node.
        // os: require('os'),
    },

    // -----------------------------------------------------------------
    // Export — sin opciones especiales; los flujos se exportan en JSON.
    // -----------------------------------------------------------------

    // -----------------------------------------------------------------
    // Trusted proxies — el editor está detrás de Caddy.
    // -----------------------------------------------------------------
    // Caddy reescribe X-Forwarded-* y NR debe aceptarlo para que las
    // sesiones funcionen correctamente al estar tras el proxy.
    httpServerOptions: {
        trustProxy: true
    },

    // -----------------------------------------------------------------
    // Diagnostics
    // -----------------------------------------------------------------
    diagnostics: {
        enabled: true,               // expone /red/diagnostics tras login
        ui: true
    },

    runtimeState: {
        enabled: false,              // API runtime/state requiere auth extra
        ui: false
    }
};
```

### `stacks/nodered/package.json.skel`

Define las paletas que se instalan al primer arranque del contenedor. Node-RED en su entrypoint detecta `package.json` modificado y lanza `npm install` antes de arrancar el runtime.

```json
{
  "name": "nodered-homelab",
  "description": "Node-RED data dir del homelab — paletas declarativas.",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "node-red-contrib-home-assistant-websocket": "^0.62.0"
  }
}
```

### Drop-in de Caddy: `stacks/caddy/conf.d/08-nodered.caddy`

```caddy
# /etc/caddy/conf.d/08-nodered.caddy — bloque LAN para Node-RED.
# Documentado en docs/08-domotica/04-node-red.md.
#
# IMPORTANTE: NO se importa authelia_two_factor (decisión documentada
# en "Decisión: seguridad del editor"). NR usa adminAuth nativo + lan_only.

nodered.{$DOMAIN_LAN} {
    import lan_tls
    import lan_only          # restringe a 192.168.1.0/24 + tailscale CGNAT
    import security_headers
    import healthcheck

    # Node-RED está en el bridge homelab; se referencia por nombre de servicio.
    # Caddy v2 detecta el WebSocket /comms y lo proxa automáticamente.
    reverse_proxy http://nodered:1880 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # El editor sube/baja flows JSON grandes y mantiene WS abierto.
        transport http {
            read_timeout 5m
            write_timeout 5m
        }
    }
}
```

### Crear los directorios persistentes y desplegar

```bash
# Directorios — owner 1000:1000 (coincide con el usuario interno de NR
# y con el operador del host). 0750 para limitar lectura mundial.
sudo install -d -o 1000 -g 1000 -m 0750 /mnt/hd2t/apps/nodered
sudo install -d -o 1000 -g 1000 -m 0750 /mnt/hd2t/apps/nodered/data

# Materializar settings.js y package.json iniciales.
cd /home/homelab/homelab
set -a; source .env; set +a

sudo install -o 1000 -g 1000 -m 0600 \
    stacks/nodered/settings.js.skel \
    /mnt/hd2t/apps/nodered/data/settings.js
sudo install -o 1000 -g 1000 -m 0644 \
    stacks/nodered/package.json.skel \
    /mnt/hd2t/apps/nodered/data/package.json

# Generar el bcrypt del usuario admin del editor.
docker run --rm -it nodered/node-red:4.0 npx node-red-admin@latest hash-pw
# Password: <introducir password generada con `openssl rand -base64 24`>
# $2a$08$...
# Copiar la password al gestor de contraseñas; copiar el hash a settings.js.

# Generar credentialSecret.
CRED_SECRET=$(openssl rand -base64 32)
echo "credentialSecret: $CRED_SECRET"
echo "---> Copiar al gestor de contraseñas AHORA. Sin él, los nodos cifrados son ilegibles."
read -p "Pulsa Enter cuando esté guardado..." _

# Editar settings.js para sustituir los placeholders <ADMIN_BCRYPT_HASH>
# y <CREDENTIAL_SECRET>.
sudo -e /mnt/hd2t/apps/nodered/data/settings.js
sudo chmod 0600 /mnt/hd2t/apps/nodered/data/settings.js

# Drop-in de Caddy.
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/08-nodered.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/08-nodered.caddy

# .env del stack (vacío en esta fase).
cp stacks/nodered/.env.example stacks/nodered/.env
chmod 0600 stacks/nodered/.env

# Levantar Node-RED. El primer arranque ejecuta `npm install` y tarda
# ~60–80s en la Pi 5; ver logs en vivo para confirmar.
docker compose \
    -f stacks/nodered/docker-compose.yml \
    --env-file stacks/nodered/.env \
    up -d

docker logs nodered -f
# > npm install ...
# > node-red-contrib-home-assistant-websocket@0.62.x ...
# > Started flows
# > Server now running at http://0.0.0.0:1880/red/

# Recargar Caddy para que tome el nuevo drop-in.
docker exec caddy caddy validate --config /etc/caddy/Caddyfile && \
    docker kill --signal=SIGUSR1 caddy
```

Tras `up -d`:

```bash
docker ps --filter name=nodered
# CONTAINER ID  IMAGE                         STATUS
# ...           nodered/node-red:4.0          Up 90 seconds (healthy)

# Logs del primer arranque — debe verse:
docker logs nodered --tail 30
# Welcome to Node-RED
# 22 Jan 13:45:00 - [info] Node-RED version: v4.0.x
# 22 Jan 13:45:00 - [info] Node.js  version: v20.x.x
# 22 Jan 13:45:00 - [info] Linux 6.x.x arm64 LE
# 22 Jan 13:45:00 - [info] Loading palette nodes
# 22 Jan 13:45:01 - [info] Settings file  : /data/settings.js
# 22 Jan 13:45:01 - [info] Context store  : 'default' [module=memory]
# 22 Jan 13:45:01 - [info] User directory : /data
# 22 Jan 13:45:01 - [info] Projects directory: /data/projects
# 22 Jan 13:45:01 - [info] Admin authenticated using credentials
# 22 Jan 13:45:02 - [info] Server now running at http://0.0.0.0:1880/red/
# 22 Jan 13:45:02 - [info] Starting flows
# 22 Jan 13:45:02 - [info] Started flows
```

> **Síntomas de éxito en el primer arranque**: `Settings file: /data/settings.js`, `Admin authenticated using credentials`, `Server now running`, `Started flows`. Si **cualquiera** de estos falta, ir a la sección "Errores frecuentes".

> **Si `npm install` falla en el primer arranque**: causa habitual es DNS dentro del contenedor. Verificar `docker exec nodered nslookup registry.npmjs.org` y, si falla, revisar Pi-hole (`192.168.1.10` debe estar como upstream del bridge Docker, o el contenedor debe poder hablar a `1.1.1.1`). Reabrible: añadir `dns: [192.168.1.10, 1.1.1.1]` al servicio en el compose si Docker no resuelve por defecto.

---

## Configuración

### 1) Verificar editor accesible y autenticación

Desde un cliente de la LAN con la CA interna instalada:

```text
1. Abrir https://nodered.lan/  → redirige a /red/.
2. La UI muestra "Username / Password".
3. Introducir: admin / <password en claro guardada en gestor>.
4. La UI carga: canvas vacío, sidebar derecho con paletas.
5. Sidebar → "info": versión 4.0.x, Node 20.x, paletas cargadas
   (ver "node-red-contrib-home-assistant-websocket").
```

> **Si la UI da "Connecting…" perpetuo**: WebSocket bloqueado. Verificar Caddy con `docker logs caddy | tail -20` buscando errores de upgrade. Lo más común: alguien añadió `forward_auth` al bloque ignorando la decisión documentada. Quitarlo, recargar Caddy.

### 2) Generar el LLT (Long-Lived Access Token) de HA

```text
1. https://home.lan/  → click avatar (esquina inferior izquierda).
2. Pestaña "Security".
3. Sección "Long-Lived Access Tokens" → "Create Token".
4. Nombre: "node-red".
5. Copiar el token mostrado (cadena larga base64).
6. Pegar inmediatamente al gestor de contraseñas — HA NO lo vuelve a mostrar.
```

> **Si el token se pierde**: revocar desde la misma UI ("Revoke") y crear otro. Sustituir en el nodo `server` de la paleta de HA en NR (paso 3 abajo).

### 3) Configurar la conexión a HA en Node-RED

```text
1. En el editor de NR, arrastrar al canvas un nodo "events: state"
   (paleta home-assistant-websocket, sidebar derecho).
2. Doble-click → "Server" → click el lápiz para "Add new server".
3. Rellenar:
   - Name: HomeAssistant
   - Base URL: http://host.docker.internal:8123
   - Access Token: <pegar el LLT generado en paso 2>
   - Use Legacy API Password: NO
   - Accept Unauthorized SSL: NO  (no aplica: HTTP plano interno)
4. "Add" → "Done". Cerrar nodo.
5. Botón rojo "Deploy" (esquina superior derecha) → "Full deploy".
6. El badge del nodo "events: state" debe mostrar "connected" (verde).
```

> **Si queda "disconnected"**: causas habituales:
> - Token incorrecto: re-copiar.
> - URL incorrecta: confirmar que `host.docker.internal` resuelve dentro del contenedor: `docker exec nodered getent hosts host.docker.internal` debe devolver una IP.
> - HA caído: `docker ps homeassistant`.

### 4) Configurar la conexión a Mosquitto en Node-RED

```text
1. Arrastrar al canvas un nodo "mqtt in" (paleta core, "network").
2. Doble-click → "Server" → "Add new mqtt-broker".
3. Rellenar:
   - Name: HomelabMosquitto
   - Server: mosquitto:1883     (DNS interno del bridge)
   - Protocol: MQTT V3.1.1
   - Client ID: nodered          (debe ser único en el broker)
   - Keep Alive: 60
4. Pestaña "Security":
   - Username: nodered
   - Password: <NR_PWD del paso 02-mosquitto.md>
5. Pestaña "Messages": dejar defaults.
6. "Add" → "Done".
7. En el nodo "mqtt in", Topic: zigbee2mqtt/+/availability  → "Done".
8. Conectarlo a un nodo "debug" (paleta core, "common").
9. "Deploy".
10. En el sidebar derecho, pestaña "debug", deberían aparecer mensajes
    `online`/`offline` cada vez que un device Zigbee cambia disponibilidad
    (si hay devices emparejados en Z2M).
```

> **Si no llegan mensajes**: revisar que el nodo "mqtt in" muestra "connected"; si dice "rejected", la password es incorrecta o la ACL bloquea el suscribe (verificar `02-mosquitto.md`: el usuario `nodered` tiene `read zigbee2mqtt/#`).

### 5) Smoke test: flujo "ping cada minuto"

Importar este flujo desde el menú (esquina superior derecha) → Import → Clipboard:

```json
[
  {
    "id": "smoke-tab",
    "type": "tab",
    "label": "smoke",
    "disabled": false,
    "info": ""
  },
  {
    "id": "smoke-inject",
    "type": "inject",
    "z": "smoke-tab",
    "name": "every 1 min",
    "props": [{"p": "payload"}],
    "repeat": "60",
    "crontab": "",
    "once": true,
    "onceDelay": 0.1,
    "topic": "nodered/smoke",
    "payload": "{\"ts\":\"$now()\"}",
    "payloadType": "jsonata",
    "x": 130,
    "y": 100,
    "wires": [["smoke-mqtt", "smoke-debug"]]
  },
  {
    "id": "smoke-mqtt",
    "type": "mqtt out",
    "z": "smoke-tab",
    "name": "publish nodered/smoke",
    "topic": "nodered/smoke",
    "qos": "0",
    "retain": "false",
    "broker": "<broker-id-from-step-4>",
    "x": 380,
    "y": 80,
    "wires": []
  },
  {
    "id": "smoke-debug",
    "type": "debug",
    "z": "smoke-tab",
    "name": "console",
    "active": true,
    "tosidebar": true,
    "console": false,
    "complete": "true",
    "x": 360,
    "y": 140,
    "wires": []
  }
]
```

Antes de hacer "Deploy", editar el nodo `smoke-mqtt` y elegir el broker `HomelabMosquitto` configurado en el paso 4 (sustituye el `<broker-id-from-step-4>`).

Verificación cruzada desde el host:

```bash
mosquitto_sub -h 127.0.0.1 -p 1883 -u admin -P "$ADM_PWD" -t 'nodered/smoke' -v
# nodered/smoke {"ts":"2026-04-28T13:46:00.000Z"}
# nodered/smoke {"ts":"2026-04-28T13:47:00.000Z"}
```

> **Si tras "Deploy" no se publica**: revisar el nodo MQTT (badge debe ser "connected"); revisar en `docker logs mosquitto --tail 5` mensajes de auth denegada.

### 6) Operación diaria

| Acción | Comando / lugar |
|---|---|
| Abrir editor | `https://nodered.lan/red/` |
| Ver logs activos | `docker logs nodered -f` |
| Hacer deploy | botón rojo "Deploy" en la esquina superior derecha del editor |
| Importar / exportar flujos | Menú (≡) → Import / Export → Clipboard / Local |
| Instalar paleta nueva | Menú (≡) → Manage palette → Install. **Después** replicar en `stacks/nodered/package.json` y commit. |
| Desinstalar paleta | Menú (≡) → Manage palette → Nodes → Remove. **Después** quitar de `package.json`. |
| Reiniciar runtime sin tocar editor | Menú (≡) → Restart Flows |
| Reiniciar contenedor | `docker compose -f stacks/nodered/docker-compose.yml restart` |
| Backup manual de flujos | `sudo tar czf /mnt/hd2t/backups/nodered-$(date +%F).tgz -C /mnt/hd2t/apps nodered/data/flows.json nodered/data/flows_cred.json nodered/data/settings.js nodered/data/package.json` |
| Actualizar NR (manual) | leer release notes → bump tag en compose → `docker compose pull && up -d` |
| Tamaño del data dir | `sudo du -sh /mnt/hd2t/apps/nodered/data` |

### 7) Convenciones de naming de flujos

Política sugerida (no enforzada por código; sí por costumbre):

```text
<dominio>:<descripción-corta>
```

| Tab name | Descripción |
|---|---|
| `lighting:presence` | Lógica de luces basada en presencia |
| `notifications:critical` | Alertas críticas (puerta abierta, alarma) → Telegram |
| `weather:aemet` | Sondeo de AEMET y publicación a MQTT |
| `energy:tariff-tracking` | Telemetría eléctrica |
| `system:heartbeat` | Smoke tests internos del homelab |

Reglas:

1. Un flujo (tab) por dominio funcional. Si una pestaña tiene >20 nodos, plantear partirla.
2. Subflows (paleta core) para lógica reutilizable. Versionar el JSON del subflow en git.
3. Nodos `comment` generosamente — los flujos se leen meses después y los nombres genéricos no bastan.
4. Variables de entorno y secretos: **nunca** literales en nodos `function`. Usar `env.X` (variable de entorno del contenedor) o credenciales cifradas del propio nodo (`flows_cred.json`).

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/nodered/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/nodered/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/nodered/settings.js.skel` | microSD | `homelab:homelab` | `0644` | Esqueleto de `settings.js`. |
| `/home/homelab/homelab/stacks/nodered/package.json.skel` | microSD | `homelab:homelab` | `0644` | Paletas declarativas. |
| `/home/homelab/homelab/stacks/caddy/conf.d/08-nodered.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy. |
| `/mnt/hd2t/apps/nodered/data/` | hd2t | `1000:1000` | `0750` | Data dir runtime. |
| `/mnt/hd2t/apps/nodered/data/settings.js` | hd2t | `1000:1000` | `0600` | `adminAuth` hash + `credentialSecret`. **Crítico**. |
| `/mnt/hd2t/apps/nodered/data/flows.json` | hd2t | `1000:1000` | `0640` | Flujos en JSON (lógica). |
| `/mnt/hd2t/apps/nodered/data/flows_cred.json` | hd2t | `1000:1000` | `0600` | Credenciales cifradas (LLT de HA, password MQTT, tokens de paletas). **Crítico**. |
| `/mnt/hd2t/apps/nodered/data/package.json` | hd2t | `1000:1000` | `0644` | Paletas instaladas. |
| `/mnt/hd2t/apps/nodered/data/package-lock.json` | hd2t | `1000:1000` | `0644` | Lockfile npm. |
| `/mnt/hd2t/apps/nodered/data/node_modules/` | hd2t | `1000:1000` | `0755` | Dependencias instaladas. **No se respalda**: regenerable con `npm install`. |
| `/mnt/hd2t/apps/nodered/data/.config.runtime.json` | hd2t | `1000:1000` | `0600` | Estado runtime. |
| `/mnt/hd2t/apps/nodered/data/.config.users.json` | hd2t | `1000:1000` | `0600` | Sesiones activas (regenerable). |
| `/mnt/hd2t/apps/nodered/data/.flows.json.backup` | hd2t | `1000:1000` | `0640` | Backup automático del último deploy (NR lo escribe solo). |
| `/mnt/hd2t/apps/nodered/data/lib/` | hd2t | `1000:1000` | `0750` | Snippets/subflows guardados desde el editor. |

> **Tamaño esperado**. `data/` sin paletas adicionales se estabiliza en torno a **100–200 MiB** (la mayor parte es `node_modules`). Con paletas adicionales (Telegram, Pushover, Modbus, ...) crece a **300–500 MiB**. Si crece a >2 GiB, hay un log a fichero activo (revisar `logging` en `settings.js`) o un context store en disco con datos absurdos.

> **Por qué no microSD**. NR escribe `flows.json` en cada deploy y `flows_cred.json` cuando cambian credenciales. Frecuencia baja, pero `npm install` (al añadir paletas) escribe miles de archivos pequeños — exactamente lo que daña una microSD. hd2t es la única opción razonable.

> **Sobre `node_modules/`**. Es regenerable a partir de `package.json` + `package-lock.json` con un simple `docker compose up -d --force-recreate` (NR detecta que `node_modules` está vacío y reinstala). Por eso **se excluye del backup**: ahorra ~150 MiB en cada archivo Borg, sin pérdida real.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/nodered/docker-compose.yml`, `.env.example`, `settings.js.skel`, `package.json.skel` | Versionados. |
| `stacks/caddy/conf.d/08-nodered.caddy` | Versionado. |
| Decisiones (NR sobre alternativas, nodered:4.0, bridge-only, adminAuth sin Authelia, paleta WS de HA, política de paletas) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Tier (`07-backups/01-estrategia-backup.md`) | Por qué |
|---|---|---|---|
| `/mnt/hd2t/apps/nodered/data/settings.js` | Sí. | T1 (secretos). | Hash de admin + `credentialSecret`. Sin `credentialSecret` no se descifra `flows_cred.json`. **Crítico**. |
| `/mnt/hd2t/apps/nodered/data/flows.json` | Sí. | T1 (lógica). | Es el "código" del operador. **Crítico**. |
| `/mnt/hd2t/apps/nodered/data/flows_cred.json` | Sí. | T1 (secretos). | LLT de HA, password MQTT, tokens de paletas. **Crítico**. |
| `/mnt/hd2t/apps/nodered/data/package.json` | Sí. | T1 (lógica). | Lista de paletas. Sin esto, restore = reinstalar manualmente las paletas. |
| `/mnt/hd2t/apps/nodered/data/package-lock.json` | Sí. | T2 | Reproduce versiones exactas de paletas. Reabrible (puede regenerarse). |
| `/mnt/hd2t/apps/nodered/data/lib/` | Sí. | T2 | Subflows/snippets guardados. |
| `/mnt/hd2t/apps/nodered/data/.flows.json.backup` | Sí. | T2 | Snapshot del deploy anterior. Útil si el último deploy rompió algo. |
| `/mnt/hd2t/apps/nodered/data/.config.*.json` | Sí. | T3 | Estado runtime menor (sesiones, último estado de algunos nodos). |
| `/mnt/hd2t/apps/nodered/data/node_modules/` | **No.** | T4 | Regenerable con `npm install`. Excluir explícitamente. |
| Logs (stdout) | **No.** | T4 | Captura Docker; no se escriben a disco. |

Entrada en `borgmatic.yaml` (parche relativo al patrón de `07-backups/02-borgmatic.md`):

```yaml
source_directories:
  # ...
  - /mnt/hd2t/apps/nodered/data

# Excluir node_modules (regenerable con npm install) y backup
# automático de NR (suficiente con flows.json en T1).
patterns:
  # ...
  - '!/mnt/hd2t/apps/nodered/data/node_modules'

# No hace falta hook before_backup: NR no usa SQLite ni nada que
# necesite quiesce. flows.json es JSON atómico (NR lo escribe con
# rename atómico), copiar en caliente da, en peor caso, la versión
# justo anterior al deploy más reciente.
```

> **Política sobre `credentialSecret`**. La cadena vive en `settings.js`. Borgmatic la respalda en T1. **Adicionalmente**, el día 1 (tras el primer arranque) se copia al gestor de contraseñas del operador: si Borg falla y nunca completa su primer ciclo, `credentialSecret` solo basta para descifrar un `flows_cred.json` recuperado de cualquier otra parte (snapshot manual, backup *out-of-band*).

> **Política sobre el LLT de HA**. El token aparece dos veces:
> 1. En HA, en la pestaña Security del usuario.
> 2. En NR, dentro de `flows_cred.json` cifrado.
>
> Si se compromete (push accidental a git, captura de pantalla en chat), revocarlo en HA (instantáneo) y generar otro nuevo. Sustituirlo en el nodo `server` de NR. Sin necesidad de reset global.

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/nodered/docker-compose.yml up -d --force-recreate
# NR reusa /mnt/hd2t/apps/nodered/data: detecta package.json, hace
# `npm install` para reconstruir node_modules (~60–80s), y arranca.
# Todos los flujos, credenciales y paletas siguen ahí.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear Fases 1 → 7, `01-home-assistant.md`, `02-mosquitto.md` y `03-zigbee2mqtt.md`.
2. `borgmatic extract --archive latest --path mnt/hd2t/apps/nodered`.
3. Verificar permisos: `sudo chown -R 1000:1000 /mnt/hd2t/apps/nodered && sudo chmod 0750 /mnt/hd2t/apps/nodered/data && sudo chmod 0600 /mnt/hd2t/apps/nodered/data/settings.js /mnt/hd2t/apps/nodered/data/flows_cred.json`.
4. Confirmar que `node_modules` **no** existe (lo regenerará el primer arranque): `sudo ls /mnt/hd2t/apps/nodered/data/node_modules` → "No such file or directory".
5. `docker compose -f stacks/nodered/docker-compose.yml up -d`.
6. Esperar `npm install` (~80s); confirmar healthcheck `(healthy)`.
7. Abrir el editor; verificar que los flujos importados aparecen y que los nodos `server` (HA y MQTT) están "connected".
8. Si HA fue reinstalado desde cero, el LLT viejo no funciona: revocar en HA (si aún está) y generar uno nuevo, sustituir en el nodo `server` de NR, redeployar.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| Primer arranque tarda >3 min y healthcheck falla | `npm install` lento (red, espejo npm) o caído. | `docker logs nodered -f` para ver progreso de npm. Si está descargando, esperar; si está en `getaddrinfo ENOTFOUND registry.npmjs.org`, problema DNS — añadir `dns: [192.168.1.10, 1.1.1.1]` al servicio. |
| Editor responde 401/403 sin pedir login | `adminAuth` mal formado en `settings.js` (sintaxis JS, faltan comas). | `docker logs nodered --tail 20` mostrará el SyntaxError. Re-editar con cuidado. |
| Editor muestra "Lost connection to server" repetidamente | WebSocket `/comms` bloqueado por proxy / firewall intermedio. | Confirmar que el cliente accede vía Caddy (`https://nodered.lan`), no por túnel adicional. Si está en tailnet, el túnel atraviesa WS sin problema; verificar que `lan_only` no excluye el rango de Tailscale (ver `03-red/04-caddy.md`). |
| Paleta `home-assistant-websocket` queda "disconnected" | LLT incorrecto, expirado, o HA caído. | (1) `docker exec nodered curl -fs -H "Authorization: Bearer $LLT" http://host.docker.internal:8123/api/` debe devolver `{"message":"API running."}`. (2) Si 401, regenerar LLT. (3) Si DNS falla, `host.docker.internal:host-gateway` no se aplicó — comprobar `extra_hosts` en compose. |
| Nodo `mqtt in/out` queda "rejected" | Password incorrecta o ACL bloqueando el `client_id`. | Re-introducir password (¡cuidado con espacios al copy-paste!); verificar `client_id` único; `docker logs mosquitto | grep nodered`. |
| Tras "Deploy" los cambios no se aplican | Deploy parcial ("modified flows" en lugar de "Full") sobre un cambio que toca configuración global. | Menú botón Deploy → "Full deploy". |
| Editor permite instalar paleta pero al hacer deploy el flujo no aparece | La paleta se instaló pero el `package.json` interno no se actualizó (rara vez). | `docker exec nodered cat /data/package.json` y comparar con la realidad. Si falta, añadir manualmente y `docker compose restart nodered`. |
| `flows.json` corrupto tras un crash de NR | NR escribe atómicamente, pero un crash kernel durante el rename puede dejar `flows.json` truncado. | NR carga `.flows.json.backup` automáticamente al arrancar si detecta corrupción. Confirmar que se cargó: `docker logs nodered | grep -i backup`. |
| Memoria del contenedor sube indefinidamente | Fuga en una paleta o en un `function` que acumula en `context.global` sin nunca limpiar. | Editor → menú → "Status" → memoria por flujo. Reiniciar el contenedor mientras se identifica el flujo culpable; aislar el flujo y revisar `function`. |
| `https://nodered.lan` da 502 Bad Gateway | (a) NR caído. (b) Caddy no resuelve `nodered` por DNS. | `docker ps nodered`; `docker exec caddy getent hosts nodered` (debe devolver `172.30.10.X`). Si no: ambos contenedores deben estar en la red `homelab`. |
| El healthcheck del contenedor falla pero el editor carga | El test usa `wget` interno; en raras versiones falla por proxy interno o por `httpAdminRoot` cambiado. | Si se ha cambiado `httpAdminRoot` de `/red` a otra cosa, ajustar el test del compose. En general el endpoint `/red/about` es estable. |
| Permisos: NR no puede escribir `flows.json` | Owner del data dir no es `1000:1000`. | `sudo chown -R 1000:1000 /mnt/hd2t/apps/nodered/data && docker compose restart nodered`. |
| Tras `pull` y bump de minor, paletas dejan de cargar | La paleta no es compatible con la nueva versión. | Bajar la imagen de NR al tag previo; en paralelo, actualizar la paleta a la versión que sí soporta el nuevo NR; reintentar. |
| Conflicto de `client_id` en MQTT (NR desconecta a Z2M o viceversa) | Ambos clientes usaron `nodered` o ambos `zigbee2mqtt` por accidente. | Confirmar `Client ID: nodered` en el broker config de NR; `Client ID: zigbee2mqtt` en `03-zigbee2mqtt.md`. Únicos por convención. |
| Logs de HA llenos de `unauthorized` justo cuando arranca NR | LLT revocado en HA pero NR sigue intentando con el viejo. | Generar nuevo LLT en HA, sustituir en NR, redeployar. |
| Nodos `events: state` no disparan tras reiniciar HA | La paleta espera ~10s antes de re-suscribir. Si HA tarda más, queda colgada. | Ya hay un *retry* automático; si pasa, `Restart Flows` en NR (menú → Restart Flows) basta sin reiniciar el contenedor. |

---

## Decisiones que **no** se toman en este documento

- **Authelia delante del editor**: descartado por incompatibilidad con WS de NR (igual que con HA y Z2M). Reabrible si NR soporta nativamente OIDC en el futuro.
- **`node-red-dashboard`**: no se preinstala. La UI doméstica vive en HA. Reabrible para dashboards técnicos solo del operador.
- **Modo `projects`** (integración git nativa de NR): descartado. Versionar el data dir entero con backup es más simple y no exige que el operador entienda la integración interna de NR con git.
- **Externalizar el context store** (Redis/Postgres en lugar de memoria/disco): innecesario para un homelab personal. Reabrible si el volumen de mensajes lo justifica (>1000/s).
- **Cluster de Node-RED** o "flujos federados" entre dos instancias: fuera de alcance.
- **`httpNodeAuth`** independiente del `adminAuth`: no se configura ahora. Si en el futuro hay endpoints `http in` con auth distinta, se añade entonces.
- **Sondas Prometheus de NR** (`node-red-contrib-prometheus`): pertenecen a Fase 5 monitorización; cuando esa fase aplique, se decide si NR exporta métricas.
- **Custom themes / branding** del editor: cosmético, no añade valor.
- **Scripts de migración de flujos entre versiones major** (NR 4 → 5 cuando salga): se aplica el procedimiento estándar de actualización con backup previo. Una guía ad-hoc se escribirá si se observan breaking changes graves.
- **Notificaciones específicas (Telegram, Pushover, email)**: pertenecen al inventario concreto del operador, no al despliegue base. Cada paleta de notificación se añade caso a caso, documentando el `chat_id`/`token`/etc. en su propio commit.

---

## Verificación Final

Antes de pasar a Fase 9 (Multimedia y Entretenimiento):

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/nodered/docker-compose.yml ps` | `nodered ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect nodered --format '{{.Config.Image}}'` | `nodered/node-red:4.0` |
| NR en bridge `homelab` | `docker inspect nodered --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}'` | `homelab` |
| `host.docker.internal` resuelve | `docker exec nodered getent hosts host.docker.internal` | una IP `172.30.10.X` (gateway del bridge) |
| Endpoint interno responde | `docker exec nodered wget -qO- http://127.0.0.1:1880/red/about \| head -c 60` | JSON con `"version":"4.0..."` |
| Editor carga y pide login | navegador con CA instalada → `https://nodered.lan/red/` | login form con campos username/password |
| Caddy sirve con cert de la CA interna | `echo \| openssl s_client -connect nodered.lan:443 -servername nodered.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| `nodered.lan` resuelve | `dig +short nodered.lan @192.168.1.2` | `192.168.1.10` |
| WebSocket activo tras login | DevTools → Network → ws | conexión `nodered.lan/red/comms` en estado `101 Switching Protocols` |
| Conectado a HA | sidebar derecho → "info" del nodo `server` (paleta HA) | "connected" en verde |
| Conectado a Mosquitto | sidebar derecho → "info" del nodo broker MQTT | "connected" en verde |
| Smoke test publica a MQTT | `mosquitto_sub -h 127.0.0.1 -p 1883 -u admin -P "$ADM_PWD" -t 'nodered/smoke' -C 1` | mensaje JSON con `ts` ISO-8601 |
| `settings.js` con permisos restrictivos | `sudo stat -c '%a' /mnt/hd2t/apps/nodered/data/settings.js` | `600` |
| `flows_cred.json` con permisos restrictivos | `sudo stat -c '%a' /mnt/hd2t/apps/nodered/data/flows_cred.json` | `600` |
| Owner correcto del data dir | `sudo stat -c '%u:%g %a' /mnt/hd2t/apps/nodered/data` | `1000:1000 750` |
| `node_modules` poblado tras primer arranque | `sudo ls /mnt/hd2t/apps/nodered/data/node_modules \| wc -l` | número > 100 |
| Paleta de HA cargada | `docker exec nodered ls /data/node_modules/node-red-contrib-home-assistant-websocket` | listado con `package.json`, `nodes/`, etc. |
| Watchtower etiqueta presente | `docker inspect nodered --format '{{index .Config.Labels "com.centurylinklabs.watchtower.enable"}}'` | `true` |

---

## Referencias

- Documentación oficial Node-RED — https://nodered.org/docs/
- `settings.js` reference — https://nodered.org/docs/user-guide/runtime/settings-file
- Securing Node-RED (`adminAuth`, `credentialSecret`) — https://nodered.org/docs/user-guide/runtime/securing-node-red
- Running under Docker — https://nodered.org/docs/getting-started/docker
- Imagen Docker oficial — https://hub.docker.com/r/nodered/node-red
- Releases y changelog — https://nodered.org/blog/
- Working with messages / Function node — https://nodered.org/docs/user-guide/messages
- Paleta `node-red-contrib-home-assistant-websocket` — https://github.com/zachowj/node-red-contrib-home-assistant-websocket
- Catálogo de paletas — https://flows.nodered.org/
- Long-Lived Access Tokens en HA — https://www.home-assistant.io/docs/authentication/#your-account-profile
- Documentos hermanos: `01-home-assistant.md`, `02-mosquitto.md`, `03-zigbee2mqtt.md`.
- Documentos referenciados: `03-red/04-caddy.md`, `04-seguridad/01-authelia.md`, `07-backups/01-estrategia-backup.md`, `07-backups/02-borgmatic.md`.
