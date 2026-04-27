# Node-RED (motor de flujos del stack `domotica`)

## Descripción

Despliegue de **Node-RED** como **motor de flujos visuales** del homelab: la pieza que cierra la fase 8 sumándose a Home Assistant (`docs/08-domotica/01-home-assistant.md`), Mosquitto (`docs/08-domotica/02-mosquitto.md`) y Zigbee2MQTT (`docs/08-domotica/03-zigbee2mqtt.md`). Node-RED se sienta encima del bus MQTT y de la API WebSocket de HA para orquestar **automatizaciones transversales** que escapan al modelo declarativo `automations.yaml` de HA: rutinas con _branching_ complejo, integraciones con servicios externos (HTTP a APIs, hooks Telegram, scrapers ad-hoc), reacciones encadenadas que mezclan Zigbee + cámaras + notificaciones + cron, y pequeños micro-servicios HTTP internos (webhooks de la red local) que no merecen su propio contenedor.

Este documento **se suma al _stack_ `domotica`** ya operativo desde `01-home-assistant.md` (servicio `home-assistant`), `02-mosquitto.md` (servicio `mosquitto` + red privada `domotica-internal` + usuario MQTT `nodered` con ACL `readwrite #` ya en su sitio) y `03-zigbee2mqtt.md` (servicio `zigbee2mqtt`). Añade un servicio `nodered` al `~/homelab/domotica/docker-compose.yml`, crea el subdirectorio versionado `~/homelab/domotica/nodered/` con dos ficheros (`settings.js.example` — la _plantilla_ versionable; un `flows.example.json` mínimo de validación) y materializa el árbol persistente en **hd2t** (`/mnt/hd2t/services/nodered/`). Toda la persistencia (`flows.json`, `flows_cred.json`, `settings.js` real con secretos, `node_modules/` de la _palette_, `package.json` con la lista de _custom nodes_ instalados) vive en hd2t. La microSD nunca recibe writes de Node-RED: el `flows.json` se reescribe atómicamente cada vez que el operador pulsa **Deploy** y el `node_modules/` puede crecer a varios cientos de MiB cuando se instalan _palette nodes_ pesados (ej. `node-red-contrib-home-assistant-websocket` arrastra >40 dependencias npm).

> **Alcance**: este documento despliega **Node-RED 4.0** (LTS, ciclo Node.js 20) sobre la imagen oficial `nodered/node-red:4.0.x-debian` (variante con OS Debian para tener `git`/`build-essential` disponibles cuando alguna _palette_ requiera compilación nativa — algunas dependencias como `node-red-node-serialport` la necesitan). Configura el _editor_ web en el puerto interno `1880`, expuesto **sólo** vía Caddy (`https://node-red.lan/`), **detrás de Authelia** (`forward_auth`, segunda capa de SSO+2FA por encima del `adminAuth` nativo de Node-RED — ver **Decisiones de diseño**). Conecta a Mosquitto sobre la red privada `domotica-internal` con el usuario `nodered` (creado en `docs/08-domotica/02-mosquitto.md`) y a la API WebSocket de HA (`ws://home-assistant:8123/api/websocket`) sobre la red `homelab` con un **Long-Lived Access Token** generado desde HA (`docs/08-domotica/01-home-assistant.md`, sección _Generar un Long-Lived Access Token_). Habilita el `projects` feature de Node-RED para versionar el `flows.json` con git nativo del editor (sin acoplar el repo del homelab a los flujos). **No** habilita HTTPS interno en Node-RED (Caddy termina TLS), **no** abre el `1880` al host, **no** instala _palettes_ por compose (la lista nominal queda documentada y el operador las añade desde la UI tras el primer login para tener control sobre cada `npm install`).

> **Recordatorio de red**: Node-RED **no se publica al host**. Caddy lo alcanza por DNS de Docker (`nodered:1880` en la red `homelab`) y dentro del propio _stack_ Node-RED habla con Mosquitto por DNS de Docker en la red privada (`mosquitto:1883` sobre `domotica-internal`) y con HA por DNS de Docker (`home-assistant:8123` sobre `homelab`). Pi-hole resuelve `node-red.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf`. El operador entra siempre por `https://node-red.lan/` (LAN) o por el nombre _MagicDNS_ del nodo Tailscale.

---

## Requisitos previos

- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/nodered/` ya existe vacío con _ownership_ `root:root 0755`. La tabla de UIDs internos de aquel doc no fija el UID interno de Node-RED; **este documento fija `1000:1000`** (PUID/PGID globales del homelab) — la imagen oficial `nodered/node-red` corre por defecto como el usuario interno `node-red` (UID `1000`, GID `1000`) y respeta el _ownership_ del bind mount sin necesidad de `--user` explícito. Confirmar:

  ```bash
  ls -la /mnt/hd2t/services/nodered/
  # drwxr-xr-x  2 root root ... .
  ```

- `docs/02-docker/02-estructura-compose.md` completado: la red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) externa está creada, `~/homelab/.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `HOMELAB_DOMAIN=lan` está rellenado, el _Makefile_ expone `make up STACK=<stack>`.
- `docs/02-docker/04-watchtower.md` completado: este documento añade **Node-RED a la lista nominal de servicios opt-out** (extensión a la tabla del doc de Watchtower; la regla mnemotécnica "¿revertir una migración fallida es trivial?" responde **no** para Node-RED — los _custom nodes_ pueden romperse entre _majors_ y los flujos se quedan _broken_ en el _editor_ con difícil _rollback_). Aquí se aplica la etiqueta `com.centurylinklabs.watchtower.enable: "false"`.
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `node-red.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy`, `logging.caddy` y `authelia.caddy` (importable como `import authelia`) existen y la directiva `import /etc/caddy/snippets/*.caddy` está activa.
- `docs/04-seguridad/01-authelia.md` completado: el _snippet_ `authelia.caddy` con `forward_auth authelia:9091 { uri /api/verify?rd=https://auth.lan ... }` está disponible y la regla de `access_control` en Authelia incluye `node-red.lan` en la lista `two_factor` (este doc descomenta la línea ya prevista por `03-zigbee2mqtt.md` — ver **Configuración de Authelia**).
- `docs/05-monitorizacion/05-uptime-kuma.md` completado (recomendado): Uptime Kuma vive en la red `homelab`. Tras este documento, se le añade un _monitor_ HTTP a `http://nodered:1880/` esperando código `401` (la página la sirve Authelia hasta autenticar) y un _monitor_ HTTP al endpoint de salud nativo `http://nodered:1880/_health` (Node-RED lo expone si se habilita la opción `httpAdminMiddleware`/healthcheck — ver **Health-check del contenedor**).
- `docs/05-monitorizacion/06-dozzle.md` completado: Dozzle ya muestra logs de los contenedores en `homelab`. Node-RED se suma sin acción extra.
- `docs/07-backups/02-borgmatic.md` completado: `source_directories: /mnt/hd2t/services` ya engloba `nodered/` por inercia. Este doc **no añade un dump activo** (Node-RED es Categoría F — _filesystem-only_); todos los datos están en ficheros de texto (JSON), reescritos atómicamente, y el `node_modules/` se puede excluir del backup sin perjuicio (se recrea con `npm install` desde `package.json`).
- `docs/08-domotica/01-home-assistant.md` completado: HA está corriendo, `(healthy)`, accesible en `https://home-assistant.lan/`. El operador ha creado un **usuario dedicado** `nodered` en HA (Settings → People → Users → Add User; permisos administrativos) y ha generado para él un **Long-Lived Access Token** (Settings → Users → nodered → Long-Lived Access Tokens → Create Token) que se guarda en Vaultwarden bajo "homelab — home-assistant — long-lived token (nodered)".
- `docs/08-domotica/02-mosquitto.md` completado: Mosquitto está `(healthy)`, escucha en `mosquitto:1883` (red `homelab` y `domotica-internal`), el usuario `nodered` existe en el `passwd` con su contraseña en Vaultwarden, la ACL define `readwrite #` para ese usuario.
- `docs/08-domotica/03-zigbee2mqtt.md` completado: Z2M está `(healthy)` y publicando eventos en `zigbee2mqtt/#`. Node-RED se suscribirá a estos topics para construir flujos sobre dispositivos Zigbee.
- Conectividad saliente para descargar la imagen y para que el _editor_ instale _palette nodes_ desde npm la primera vez (sólo cuando el operador lo pida desde la UI; el contenedor por defecto tiene salida a internet vía la red `homelab`):

  ```bash
  docker pull --platform linux/arm64 nodered/node-red:4.0.9-debian >/dev/null && echo OK
  ```

---

## Decisiones de diseño

### Por qué Node-RED (y no n8n / Huginn / Zapier-self-hosted)

Cuatro alternativas razonables para "motor de automatizaciones visuales / workflows" y por qué se descartan:

| Candidato                   | Por qué se descarta                                                                                                                                                                                                                                                                                                                       |
|-----------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **n8n**                     | Excelente para workflows _empresariales_ con muchos servicios SaaS conectados (Slack, GitHub, Notion, …). Pero su modelo es _trigger → step → step_ orientado a procesos batch/HTTP, no a streams de mensajes MQTT en tiempo real. La integración nativa con HA es _best-effort_ comunitaria; con MQTT funciona pero sin la fluidez de Node-RED. **Más pesado** (Postgres opcional, gran consumo de RAM). En una Pi 5 con 8 GB compartidos con HA + Mosquitto + Z2M, el coste no compensa.                                                                                                                                                                                  |
| **Huginn**                  | Ruby + MySQL + Sidekiq. Diseñado para "agentes" que se disparan en cron y reaccionan a eventos web. La curva de aprendizaje (modelo de _agents_ y _events_ en Ruby) es alta para algo que se quiere usar en tarde-noche-fin-de-semana. Comunidad pequeña.                                                                                                                                              |
| **Apache NiFi**             | Industrial-grade. _Overkill_ absoluto para automatización doméstica. Pesado en JVM (mínimo 1 GB RAM ocioso), curva de aprendizaje alta.                                                                                                                                                                                                  |
| **Sólo `automations.yaml` de HA** | Ya está y para automatizaciones simples ("si sensor X reporta `motion`, encender luz Y") basta. Pero `automations.yaml` se vuelve verboso y rígido cuando aparecen ramificaciones (`if A and (B or C) then …`), bucles de espera con timeout, llamadas HTTP a APIs externas, agregaciones de varios sensores con ventanas temporales. Mantener todo en `automations.yaml` es viable pero penaliza la _agility_ del operador.                                                                                                                                                                                                                                                                                                                          |

**Node-RED gana por**:

- **MQTT-first**: el bus MQTT del homelab encaja directamente con los nodos `mqtt in` / `mqtt out` de Node-RED. Cero impedancia entre Mosquitto y Node-RED.
- **HA WebSocket nativo** vía la _palette_ `node-red-contrib-home-assistant-websocket` (mantenida activamente por la comunidad de HA): exposición declarativa de entidades de HA como `entity:` nodes, posibilidad de llamar a servicios de HA desde un flujo (`call service`), trigger de flujos desde eventos de HA.
- **Modelo gráfico** que mapea naturalmente al modelo mental de "evento → transformación → acción" de domótica.
- **Comunidad masiva en domótica casera**: incontables flujos de ejemplo en GitHub, foros de HA y Reddit para casi cualquier escenario doméstico (luces dinámicas, presencia, climatización, alertas, …).
- **Ligero en ARM64**: la imagen oficial multi-arch corre cómoda en Pi 5; ocupa ~120 MB ociosa y consume CPU sólo cuando hay tráfico de mensajes (idle: <1 % de un core).
- **Persistencia en JSON** (no DB): `flows.json` es legible, _diff-friendly_, versionable con git nativo. Sin migrations de schema entre versiones (Node-RED migra _en caliente_ las propiedades de los nodos al cargar).

### Por qué Node-RED **además** de las automatizaciones de HA (no _en lugar de_)

Los dos coexisten con una división de responsabilidades clara que el operador debe respetar para no duplicar lógica:

| Lógica                                                                | Va en …                                                                                              |
|-----------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|
| Trigger simple (1 sensor → 1 acción), _state machines_ pequeñas       | `automations.yaml` de HA                                                                              |
| Lógica con muchas ramas, _temporizadores_ encadenados, espera de varios sensores antes de actuar | Node-RED                                                                                              |
| Llamadas HTTP a APIs externas (Telegram, IFTTT residual, scrape de webs) | Node-RED                                                                                              |
| Webhooks entrantes (un servicio externo POSTea a `https://node-red.lan/webhook/...`) | Node-RED (su `http in` lo gestiona; HA tendría que abrir un endpoint específico, más fricción)        |
| Pipelines de datos (calcular consumo eléctrico medio, persistir en InfluxDB cuando se monte) | Node-RED (mejor expresividad)                                                                         |
| Voz (Alexa, Google Assistant)                                         | HA con sus integraciones nativas                                                                      |
| Dashboards (`Lovelace`)                                               | HA                                                                                                    |

**Regla mnemotécnica**: si la automatización cabe en 5 líneas de YAML, queda en HA. Si requiere ≥20 líneas o lógica compleja, se mueve a Node-RED.

> **Antipatrón**: duplicar la misma automatización en HA y en Node-RED. Cada cambio se haría en dos sitios y los _races_ son inevitables (el botón de la cocina dispara dos llamadas a `light.toggle` y la luz queda igual que estaba). El operador anota en cada flujo de Node-RED el ID del archivo HA correspondiente (si existe) o lo borra de HA cuando lo migra.

### Imagen y _tag_

- **`nodered/node-red:4.0.9-debian`** — Node-RED **4.0.9**, _patch_ estable de la línea 4.0 (LTS, basada en Node.js 20). Multi-arch oficial con `linux/arm64`. Variante `-debian` (no `-alpine`) porque Debian trae `git`, `python3` y `build-essential` ya disponibles, lo que facilita compilar dependencias nativas de algunas _palettes_ (`node-red-node-serialport`, `node-red-contrib-modbus`) sin tener que añadirlas a mano vía `Dockerfile.custom`. La diferencia de tamaño entre `-alpine` (~80 MB) y `-debian` (~280 MB) es asumible en hd2t. Pinneada a _tag_ específico siguiendo la convención del homelab.
- **Por qué no `:latest`**: lo prohíbe la convención.
- **Por qué no `:dev`** o `:next`: las _branches_ de desarrollo de Node-RED introducen ocasionalmente cambios en el formato de `flows.json` que romperían _rollback_.
- **Por qué `:4.0` y no `:3.1`** (la anterior LTS): Node-RED 4 trae compatibilidad con Node.js 20+ (la 3.1 está atascada en Node 18 LTS, que ya entró en _maintenance_) y mejoras de UX en el editor (búsqueda, panel lateral redimensionable). El _flows.json_ es compatible hacia atrás con flujos creados en 3.x.
- **Bumps**: Node-RED tiene un ciclo de _release_ predecible (un _minor_ cada 2–3 meses, _patches_ semanales). Cada bump se hace tras leer el _changelog_ (`https://github.com/node-red/node-red/blob/master/CHANGELOG.md`) buscando **Breaking changes**. Los _patches_ (`4.0.9 → 4.0.10`) son seguros; los _minor_ (`4.0 → 4.1`) requieren atención (ocasionalmente cambian la firma de funciones en `RED.util` que algún _custom node_ usa).

#### Watchtower opt-out

Razones (extiende la lista nominal de `docs/02-docker/04-watchtower.md`, sección _Servicios que se mantienen en opt-out_):

- **Custom nodes con dependencias npm propias**: el `node_modules/` del usuario contiene paquetes que pueden no ser compatibles con un Node-RED actualizado por sorpresa. Si Watchtower bumpa Node-RED de 4.0.9 a 4.1.0 y `node-red-contrib-home-assistant-websocket` aún no soporta esa versión, el editor arranca pero los _HA nodes_ aparecen rojos con error de carga. **Imposible automatizar la decisión**: cada bump requiere comprobar manualmente que las _palettes_ instaladas son compatibles.
- **`flows.json` puede requerir migración manual** si Node-RED introduce cambios en cómo serializa ciertos nodos. Aunque la migración es transparente al cargar, una migración _silenciosa_ no auditada puede dejar flujos en estado raro que sólo se detectan al ejecutarse.
- **Coherencia con Z2M y HA**, también opt-out por la misma razón estructural: en _stack_ `domotica` los servicios con persistencia compleja se actualizan en ventana planificada con _release notes_ delante.

Etiquetar con `com.centurylinklabs.watchtower.enable: "false"`.

### Modo de red: dos redes (`homelab` + `domotica-internal`)

Node-RED se conecta a **dos redes Docker** simultáneamente, igual que Mosquitto y Zigbee2MQTT:

| Red                | Subnet (declarada) | Quién la usa                                                                  | Por qué                                                                                                                  |
|--------------------|--------------------|-------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------|
| `homelab`          | `172.20.10.0/24`   | **Caddy** (cross-stack, alcanza `nodered:1880` para el _editor_); **HA** (Node-RED → HA WebSocket en `home-assistant:8123`); Uptime Kuma (monitor HTTP); npm registry (salida a internet para instalar _palettes_) | Permite el _editor_ accesible vía Caddy, la conexión HA WebSocket entre stacks (HA está en `homelab`), y la salida a internet. |
| `domotica-internal` | `172.20.20.0/24`  | Mosquitto + Z2M + Node-RED (intra-stack, MQTT)                                | Tráfico MQTT _intra-stack_ aislado: Node-RED habla con `mosquitto:1883` por esta red, sin atravesar `homelab`.            |

Razones (idénticas a las de Z2M):

- **`homelab`**: Caddy hace _reverse proxy_ al _editor_ (1880). HA, también en `homelab`, atiende la WebSocket. Node-RED necesita salida a internet para `npm install` desde la UI; `homelab` no es `internal: true`, así que la tiene.
- **`domotica-internal`**: el MQTT no atraviesa la red _cross-stack_; aislado por _hygiene_, no por seguridad estricta.

> **¿Por qué no Node-RED → HA por `mosquitto`?** Funciona — HA puede recibir comandos por MQTT con su integración _MQTT_ activada y los flujos de Node-RED pueden llamar a servicios HA con `homeassistant/<entity>/set` / `mosquitto_pub`. Pero la _palette_ `node-red-contrib-home-assistant-websocket` ofrece **mucha más fidelidad** (estados de entidades en tiempo real, `state_changed` events, llamada a servicios con argumentos complejos, `entity:` nodes que se autocompletan en el editor). El coste extra es una conexión WebSocket persistente entre Node-RED y HA, despreciable.

> **¿Por qué no Node-RED en `domotica-internal` _solo_?** Tendría sentido si no necesitase ni `homelab` ni internet. Pero ambas son obligatorias (_editor_ + HA + npm). Vivirá en las dos.

### Editor (`1880`) detrás de Caddy + Authelia _y_ con `adminAuth` nativo

El _editor_ web de Node-RED **sí tiene autenticación nativa** (`adminAuth` en `settings.js`), a diferencia del _frontend_ de Z2M. Pero igualmente se pone Authelia delante por **defensa en profundidad**:

1. **No publicar `1880` al host**. El compose **no** lleva `ports:` para `1880`. Sólo Caddy llega.
2. **Caddy + `tls internal`** termina TLS con la CA local. El usuario entra siempre por `https://node-red.lan/`, no por `http://192.168.1.3:1880`.
3. **`forward_auth` con Authelia** delante: SSO + 2FA TOTP del homelab antes de tocar Node-RED.
4. **`adminAuth` nativo de Node-RED** detrás: usuario `admin` con contraseña hasheada (bcrypt), aunque Authelia ya autenticó. Es redundante pero **necesaria**: Authelia protege el _editor_, pero la API HTTP `/red/...` la usan también algunos _custom nodes_ (ej. _flow control_ programático), y el `adminAuth` les fuerza a llevar credenciales propias. Además, el `adminAuth` permite definir **roles** dentro de Node-RED (`*` = admin, `read` = sólo lectura) — útil si en el futuro se quiere dar acceso a un segundo usuario sólo-lectura para auditar flujos.

> **¿Doble autenticación no es _user-hostile_?** Sí, en cierto modo. Pero Authelia da **SSO**: una vez autenticado al portal, todos los servicios del homelab heredan la sesión sin re-pedir credenciales. El segundo gate (`adminAuth`) sólo aparece la primera vez que se entra al editor (mensaje "Username/Password" en la propia UI de Node-RED), y a partir de ahí Node-RED guarda una cookie de sesión. Coste UX: 1 password extra, una vez por restart del navegador.

El bloque en el `Caddyfile`:

```caddy
node-red.lan {
    tls internal
    import security-headers
    import logging
    import authelia

    reverse_proxy nodered:1880 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto https
    }
}
```

> **WebSockets**: el editor de Node-RED usa una WebSocket (`/comms`) para _live updates_ de los nodos en _runtime_ (eventos de _debug_, estado de los nodos en color verde/rojo). `reverse_proxy` v2 maneja el _upgrade_ a WS automáticamente; **sin directivas especiales**.

> **Webhooks `http in`**: si un flujo expone un endpoint `http in` en `/webhook/foo`, queda accesible en `https://node-red.lan/webhook/foo` — y por defecto **también** detrás de Authelia, lo que rompe llamadas desde dispositivos sin sesión web (cámaras IP, _bash scripts_ con `curl`). Soluciones: (a) **mover los webhooks a un sub-path bypass** en Caddy o (b) **usar un `httpAdminRoot` distinto del `httpNodeRoot`** y poner Authelia sólo sobre el _admin_. Ver **Decisiones avanzadas** más abajo.

### `httpAdminRoot` y `httpNodeRoot` separados

Node-RED expone **dos espacios de URL** servidos por la misma instancia:

| Path                         | Qué                                                              | ¿Authelia delante?                                          |
|------------------------------|------------------------------------------------------------------|-------------------------------------------------------------|
| `/red` (admin/editor)         | El _editor_ visual donde el operador edita flujos                 | **Sí** (es el panel de control)                              |
| `/api` (HTTP routes definidas en flujos) | Endpoints HTTP creados por nodos `http in` dentro de un flujo    | **No** (otros servicios/dispositivos los llaman sin sesión) |

`settings.js` configura:

```javascript
httpAdminRoot: "/red",      // editor en /red, no en /
httpNodeRoot:  "/api",      // webhooks en /api/<path>, no en /
```

Y el bloque del `Caddyfile` se ramifica:

```caddy
node-red.lan {
    tls internal
    import security-headers
    import logging

    # Admin/editor: bajo /red, con Authelia delante.
    @admin path /red /red/* /comms /comms/*
    handle @admin {
        import authelia
        reverse_proxy nodered:1880
    }

    # HTTP routes (webhooks, http in/out): bajo /api, SIN Authelia.
    handle /api/* {
        reverse_proxy nodered:1880
    }

    # Raíz "/" → redirección al editor (al menos para humanos).
    redir / /red/ permanent
}
```

> **`/comms` y `/comms/*` también con Authelia**: es la WebSocket del editor; sin ella protegida, alguien con acceso a la red podría leer eventos del runtime (mensajes _debug_) sin login. La incluyo en el `@admin` matcher.

> **Decisión sólo si hace falta**: para un homelab que no expone webhooks externos al principio, basta con la versión simple de un único `reverse_proxy` con `import authelia` global. Cuando aparezca el primer `http in` real, se reformatea el bloque del `Caddyfile` para separar admin/api. **El `settings.js` sí lleva `httpAdminRoot` y `httpNodeRoot` separados desde el inicio**, para que no haya que tocar el `flows.json` cuando llegue el día.

### `adminAuth` con bcrypt y _credential secret_

`settings.js` define dos secretos:

1. **`adminAuth.users[].password`**: hash bcrypt de la contraseña del usuario `admin` (rondas: 8). Generado con `node-red admin hash-pw` o equivalente.
2. **`credentialSecret`**: clave simétrica (32+ chars aleatorios) que cifra los _credenciales_ embebidos en `flows.json` (passwords MQTT, tokens HA, claves API). Se almacena en `flows_cred.json` cifrado con esta clave; sin ella, un fork del `flows.json` desde Borg no permite recuperar las contraseñas (las pide al cargar). **Es el secreto más crítico de Node-RED**.

Ambos van como variables de entorno (`NODE_RED_ADMIN_PASSWORD_HASH`, `NODE_RED_CREDENTIAL_SECRET`) en `~/homelab/domotica/.env` y `settings.js` los lee con `process.env.*`. Anotados en Vaultwarden bajo "homelab — node-red".

> **Si se pierde `credentialSecret`**: Node-RED arranca igual, pero todos los _credenciales_ embebidos en flujos quedan _wipeados_ y los flujos que los usan fallan al ejecutarse hasta que el operador los rellena de nuevo desde la UI. **Inconveniencia mayor pero no irreversible**. Por eso se respalda en Vaultwarden y en Borg (vía `.env` que **no** se respalda — _ouch_, ver más abajo).

### Persistencia: `userDir` en hd2t

Node-RED guarda **todo** en su `userDir`:

| Fichero / dir          | Qué                                                                                                                                                                       |
|------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `flows.json`           | Definición de los flujos (nodos, _wires_, propiedades). Texto plano JSON, _diff-friendly_.                                                                                |
| `flows_cred.json`      | Credenciales cifrados con `credentialSecret`.                                                                                                                              |
| `settings.js`          | Configuración del runtime (lo que `~/homelab/domotica/nodered/settings.js.example` plantilla).                                                                             |
| `package.json` y `package-lock.json` | Lista de _palette nodes_ instalados desde la UI.                                                                                                                |
| `node_modules/`        | Las _palette_ resueltas. Puede pesar 200–500 MB. **Excluible del backup** (recreable con `npm install`).                                                                 |
| `lib/`                 | Librerías reutilizables (subflows compartidos, plantillas).                                                                                                                |
| `projects/` (si se habilita) | Si se habilita el _projects_ feature, los flujos viven en repos git aquí dentro.                                                                                      |
| `.config*.json`        | Estado del editor (paneles abiertos, breakpoints de _debug_).                                                                                                              |
| `.flows.json.backup`   | Backup automático del último `flows.json` antes del último `Deploy`. Se rota a un solo nivel.                                                                              |

Todos en `/mnt/hd2t/services/nodered/`, montado como `/data` dentro del contenedor.

### Health-check del contenedor

Node-RED expone un endpoint HTTP de _health_ implícito en la raíz del editor (`/`), pero por defecto no hay un `/_health` desnudo. El _healthcheck_ del compose se basa en el _editor_ HTTP:

```yaml
healthcheck:
  test: ["CMD-SHELL", "wget -qO- --tries=1 --timeout=5 http://localhost:1880/red/ 2>/dev/null | grep -q 'Node-RED' || exit 1"]
  interval: 30s
  timeout: 10s
  retries: 5
  start_period: 90s
```

Detalles:

- `start_period: 90s`: Node-RED tarda 30–90 s en arranque inicial cuando hay muchas _palettes_ instaladas (la primera vez que carga `node-red-contrib-home-assistant-websocket` con sus 40+ deps puede tardar más de 1 min en una Pi 5). Margen generoso.
- `localhost:1880/red/`: el `httpAdminRoot` que se configura más abajo.
- El `grep 'Node-RED'` verifica que la página de login del editor se está sirviendo. **No** verifica que los flujos arranquen sin error: un flujo roto en _runtime_ no deja el contenedor `unhealthy`. Para detectar flujos rotos hay que mirar logs (`docker logs nodered | grep -E 'ERROR|catch'`) o, mejor, suscribir Uptime Kuma a un topic MQTT que Node-RED publique como _heartbeat_ desde un flujo dedicado (ver **Operación → Heartbeat de Node-RED**).

### Logs

Node-RED escribe a `stdout`/`stderr`, capturable por `docker logs` y visible en Dozzle. **No se monta** un fichero de log persistente en `/data/`; el _editor_ tiene una pestaña _Debug_ que muestra mensajes en vivo y se puede redirigir a fichero con `node-red-contrib-msg-speed` u otros, pero no se hace por defecto.

> **Por qué no log a fichero**: el _runtime_ de Node-RED produce mucha más información que la que vale la pena persistir; los _debug_ de los flujos en desarrollo son ruidosos y se quieren ver _en vivo_, no en un fichero. Si en el futuro se quiere persistir, se hace desde dentro de un flujo (un `file out` node) y queda en `/mnt/hd2t/services/nodered/log/` que el operador crea cuando le haga falta.

---

## Almacenamiento

| Ruta en el host                                            | Contenido                                                                            | Versionable                | Backup                                |
|------------------------------------------------------------|--------------------------------------------------------------------------------------|----------------------------|---------------------------------------|
| `~/homelab/domotica/docker-compose.yml`                    | Definición del _stack_ (modificada en este doc)                                      | git                        | git                                   |
| `~/homelab/domotica/.env`                                  | Variables del _stack_ (`NODE_RED_ADMIN_PASSWORD_HASH`, `NODE_RED_CREDENTIAL_SECRET`, `HA_LL_TOKEN_NODERED`) | **NO** (`.gitignore`)      | git aparte (Vaultwarden)               |
| `~/homelab/domotica/.env.example`                          | Plantilla con nombres de variables                                                   | git                        | git                                   |
| `~/homelab/domotica/nodered/settings.js.example`           | Plantilla del `settings.js` (sin secretos)                                           | git                        | git                                   |
| `~/homelab/domotica/nodered/flows.example.json`            | Flow mínimo de validación: heartbeat MQTT + ping HA WebSocket                        | git                        | git                                   |
| `/mnt/hd2t/services/nodered/settings.js`                   | `settings.js` real (lee env vars; no incluye secretos en sí mismo)                   | **NO**                     | **Sí** (Borgmatic)                    |
| `/mnt/hd2t/services/nodered/flows.json`                    | Flujos del operador                                                                  | _Sí_ vía _projects_ feature de Node-RED, repo git interno | **Sí** (Borgmatic)                    |
| `/mnt/hd2t/services/nodered/flows_cred.json`               | Credenciales cifrados (passwords MQTT, tokens, claves API)                           | **NO**                     | **Sí** (Borgmatic — crítico)           |
| `/mnt/hd2t/services/nodered/package.json`                  | Lista de _palette nodes_ instalados                                                  | **NO** (cambia por UI)     | **Sí** (Borgmatic)                    |
| `/mnt/hd2t/services/nodered/package-lock.json`             | Lock de versiones npm                                                                | **NO**                     | **Sí** (Borgmatic)                    |
| `/mnt/hd2t/services/nodered/node_modules/`                 | _Palettes_ resueltas                                                                 | **NO**                     | **NO** — excluido por `*/node_modules/*` |
| `/mnt/hd2t/services/nodered/projects/` (opcional)          | Repos git de proyectos (si se habilita _projects_)                                   | **NO** directamente; los repos git internos sí | **Sí** (Borgmatic — incluye `.git`)   |
| `/mnt/hd2t/services/nodered/.config*.json`                 | Estado del editor                                                                    | **NO**                     | _Opcional_                            |

> **`flows_cred.json` es CRÍTICO**: sin él, los flujos quedan _wipeados_ de credenciales. Permisos `0600 1000:1000`. Cuando se restaura desde Borg, se restaura con su `credentialSecret` correspondiente (el del `.env` del momento del backup); si las claves de cifrado no coinciden, los credenciales no se descifran.

> **`node_modules/` excluido**: para excluirlo de Borgmatic, se añade `*/node_modules/*` a `exclude_patterns` (si no está ya). Recreable con `docker compose exec nodered npm install` desde `package.json`.

> **Permisos `0700` para `/mnt/hd2t/services/nodered/`**: contiene secretos descifrables (con `credentialSecret`) y estado de sesiones. Restringido a `1000:1000`.

---

## Estructura del _stack_ `domotica` tras este documento

```
~/homelab/domotica/
├── docker-compose.yml              # ← modificado (se añade el servicio nodered)
├── .env                            # ← modificado (NODE_RED_*, HA_LL_TOKEN_NODERED)
├── .env.example                    # ← modificado (idem, sin valores)
├── .gitignore                      # sin cambios
├── mosquitto/                      # del doc 02
│   ├── mosquitto.conf
│   └── acl
├── zigbee2mqtt/                    # del doc 03
│   └── configuration.yaml.example
└── nodered/                        # ← nuevo
    ├── settings.js.example         # plantilla versionada (sin secretos)
    └── flows.example.json          # flow mínimo de validación
```

Y en hd2t:

```
/mnt/hd2t/services/nodered/
├── settings.js                     # ← creado en este doc (copia de settings.js.example)
├── flows.json                      # creado por Node-RED al primer Deploy
├── flows_cred.json                 # creado por Node-RED al primer Deploy con credenciales
├── package.json                    # creado por Node-RED al instalar la primera palette
├── package-lock.json               # idem
├── node_modules/                   # creado por npm install
├── .config.users.json              # creado por Node-RED para la sesión
└── projects/                       # opcional, si se habilita el feature
```

Aplicar el _ownership_ y modos:

```bash
sudo chown -R 1000:1000 /mnt/hd2t/services/nodered
sudo chmod 0700 /mnt/hd2t/services/nodered
```

Crear el subdirectorio versionado:

```bash
mkdir -p ~/homelab/domotica/nodered
chmod 0750 ~/homelab/domotica/nodered
```

---

## Variables de entorno

Añadir a `~/homelab/domotica/.env.example` (versionado, sin valores reales):

```bash
# --- Imágenes pinneadas (continúa de docs/08-domotica/03-zigbee2mqtt.md) ---
HA_IMAGE_TAG=2026.4
MOSQUITTO_IMAGE_TAG=2.0.20
Z2M_IMAGE_TAG=1.40.1
NODERED_IMAGE_TAG=4.0.9-debian

# --- Node-RED ---------------------------------------------------------------
# Hash bcrypt (rondas: 8) de la contraseña del usuario 'admin' del editor.
# Generar con:
#   docker run --rm -it nodered/node-red:${NODERED_IMAGE_TAG} \
#     node-red admin hash-pw
# Pegar la salida tal cual (empieza por '$2a$08$...'). Comillas obligatorias
# por los caracteres especiales del hash.
NODE_RED_ADMIN_PASSWORD_HASH='$2a$08$REPLACE_ME_WITH_REAL_BCRYPT_HASH'

# Clave simétrica (32+ chars aleatorios) que cifra flows_cred.json.
# Generar con:  openssl rand -hex 32
# CRÍTICA: si se pierde, los credenciales de los flujos quedan ilegibles.
# Anotar también en Vaultwarden bajo 'homelab — node-red — credentialSecret'.
NODE_RED_CREDENTIAL_SECRET=REPLACE_ME_WITH_OPENSSL_RAND_HEX_32

# Credenciales del usuario 'nodered' en Mosquitto (creado en
# docs/08-domotica/02-mosquitto.md). Se inyectan al contenedor para que los
# flujos MQTT las puedan leer desde process.env.
NODERED_MQTT_USERNAME=nodered
NODERED_MQTT_PASSWORD=changeme

# Long-Lived Access Token del usuario 'nodered' en Home Assistant.
# Generar desde HA: Settings → Users → nodered → Long-Lived Access Tokens
# → Create Token. Pegarlo aquí. Anotar también en Vaultwarden.
HA_LL_TOKEN_NODERED=changeme
```

Copiar a `~/homelab/domotica/.env` los valores reales:

```bash
$EDITOR ~/homelab/domotica/.env
chmod 0600 ~/homelab/domotica/.env
```

Generar los secretos:

```bash
# 1. Hash bcrypt para la contraseña del admin del editor.
PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
echo "Contraseña en claro (anotar en Vaultwarden): $PW"
docker run --rm nodered/node-red:4.0.9-debian \
  bash -c "echo -n '$PW' | npx --yes bcrypt-cli 8" 2>/dev/null
# o equivalentemente, dentro de la imagen:
docker run --rm -it nodered/node-red:4.0.9-debian node-red admin hash-pw
# (te pide la contraseña interactivamente y devuelve el hash).

# 2. credentialSecret.
openssl rand -hex 32
# Pegar como NODE_RED_CREDENTIAL_SECRET (sin comillas, es 64 chars hex).
```

> **Sobre bcrypt rondas: 8**: Node-RED documenta `bcrypt.hashSync(password, 8)`. Subir a 10–12 sería más seguro pero ralentiza el _login_ unos segundos en una Pi 5. 8 es el _sweet spot_ que la propia documentación recomienda para hardware modesto.

> **`HA_LL_TOKEN_NODERED`** en `.env` plano sin cifrar: Node-RED necesita leerlo en arranque. La _palette_ HA lo guardará cifrado en `flows_cred.json` cuando el operador configure el _server_ HA en la UI; el `.env` deja de ser estrictamente necesario tras eso, pero se mantiene como respaldo para reconfiguración limpia desde cero.

---

## `~/homelab/domotica/nodered/settings.js.example` (plantilla versionable)

Esta es la **plantilla** que se versiona. Es una copia textual del `settings.js` real **sin secretos** (todos vienen de `process.env.*`):

```javascript
/* =============================================================================
 * Node-RED — settings.js del homelab
 * Documentación: docs/08-domotica/04-node-red.md
 * Schema: https://nodered.org/docs/user-guide/runtime/configuration
 *
 * Esta es la PLANTILLA versionada. La copia real con los enlaces a process.env
 * (que apuntan a NODE_RED_ADMIN_PASSWORD_HASH, NODE_RED_CREDENTIAL_SECRET, …
 *  desde ~/homelab/domotica/.env) vive en /mnt/hd2t/services/nodered/settings.js
 * y NO está en git. Las dos copias deben permanecer sincronizadas tras cada
 * cambio de configuración.
 * ============================================================================= */

module.exports = {
    // -------------------------------------------------------------------------
    // FLOW FILE
    // -------------------------------------------------------------------------
    flowFile: 'flows.json',
    flowFilePretty: true,                    // Pretty-print: facilita los diffs.

    // -------------------------------------------------------------------------
    // CREDENCIALES — cifradas con esta clave
    // -------------------------------------------------------------------------
    credentialSecret: process.env.NODE_RED_CREDENTIAL_SECRET,

    // -------------------------------------------------------------------------
    // SERVIDOR HTTP
    // -------------------------------------------------------------------------
    uiPort: process.env.PORT || 1880,
    uiHost: '0.0.0.0',                       // Sólo accesible vía red Docker.

    // El editor vive en /red, los HTTP routes (webhooks de flujos) en /api.
    // Caddy distingue ambos espacios para aplicar Authelia sólo a /red.
    httpAdminRoot: '/red',
    httpNodeRoot:  '/api',
    httpStatic: false,                       // No servir ficheros estáticos.

    // -------------------------------------------------------------------------
    // ADMIN AUTH (segunda capa, detrás de Authelia)
    // -------------------------------------------------------------------------
    adminAuth: {
        type: 'credentials',
        users: [
            {
                username: 'admin',
                password: process.env.NODE_RED_ADMIN_PASSWORD_HASH,
                permissions: '*',
            },
            // Para añadir un usuario sólo-lectura más adelante:
            // {
            //   username: 'auditor',
            //   password: process.env.NODE_RED_AUDITOR_PASSWORD_HASH,
            //   permissions: 'read',
            // },
        ],
    },

    // -------------------------------------------------------------------------
    // RUNTIME
    // -------------------------------------------------------------------------
    logging: {
        console: {
            level: 'info',                   // 'debug' sólo durante troubleshoot.
            metrics: false,
            audit: false,
        },
    },

    // Memoria: Node-RED 4 ya respeta NODE_OPTIONS=--max-old-space-size si está
    // definido en el entorno. Por defecto se queda en 512 MB de heap, generoso
    // para flujos típicos. Subir si se ejecutan agregaciones grandes.

    // Context store: dónde guarda el contexto persistente de los nodos.
    // Por defecto in-memory; aquí se habilita 'file' para que el contexto
    // sobreviva a reinicios del contenedor.
    contextStorage: {
        default: {
            module: 'localfilesystem',
            config: { dir: '/data/context' },
        },
    },

    // Lista de funciones globales accesibles desde los nodos function.
    // Útil cuando un flujo necesita una utilidad común. Se mantiene vacío
    // por defecto.
    functionGlobalContext: {},

    // Tamaño máximo de los mensajes que Node-RED muestra en la pestaña Debug.
    // Reducirlo evita que mensajes JSON enormes (cargas de cámaras IP, p. ej.)
    // tumben el editor.
    debugMaxLength: 1000,

    // -------------------------------------------------------------------------
    // EDITOR THEME
    // -------------------------------------------------------------------------
    editorTheme: {
        page: { title: 'Node-RED — homelab' },
        header: { title: 'Node-RED' },
        deployButton: { type: 'simple', label: 'Deploy' },
        menu: {
            'menu-item-help': {
                label: 'Documentación del homelab',
                url:   'https://github.com/<owner>/homelab/blob/main/docs/08-domotica/04-node-red.md',
            },
        },
        projects: {
            // Habilitar el feature 'projects': cada flow vive en un repo git
            // local en /data/projects/<name>/. Permite versionar flujos sin
            // mezclarlos con el repo del homelab.
            enabled: true,
            workflow: { mode: 'manual' },     // Pull/push manual, no auto.
        },
    },

    // -------------------------------------------------------------------------
    // EXTERNAL MODULES
    // -------------------------------------------------------------------------
    // Permitir instalar palettes desde la UI (npm install).
    // Restringido a paquetes que empiecen por 'node-red-' por seguridad.
    externalModules: {
        autoInstall: false,                  // Pedir confirmación humana siempre.
        palette: {
            allowInstall: true,
            allowUpload: false,              // Sin .tgz subidos a mano.
            allowList: ['node-red-*', '@node-red-*/*'],
            denyList: [],
        },
        modules: {
            allowInstall: true,
            allowList: [],                   // Function nodes: ninguno por defecto.
            denyList: ['fs', 'child_process'], // Bloquear acceso al fs y exec.
        },
    },

    // -------------------------------------------------------------------------
    // SECURITY HEADERS
    // -------------------------------------------------------------------------
    // Caddy añade los X-Frame-Options/CSP, pero Node-RED puede reforzar.
    httpServerOptions: {
        // Si en el futuro se quisiera HTTP/2 nativo (Caddy ya lo hace), se
        // movería aquí. Hoy se deja a Caddy.
    },
};
```

Copiar a hd2t como punto de partida:

```bash
sudo cp ~/homelab/domotica/nodered/settings.js.example \
        /mnt/hd2t/services/nodered/settings.js
sudo chown 1000:1000 /mnt/hd2t/services/nodered/settings.js
sudo chmod 0640 /mnt/hd2t/services/nodered/settings.js
```

> **Sincronización plantilla ↔ real**: cuando se cambia algo en `settings.js.example` (p. ej. añadir una _option_ del editor), aplicar el mismo cambio en `/mnt/hd2t/services/nodered/settings.js` y _commitear_ la plantilla. Tras un upgrade de _minor_ de Node-RED que añada nuevas _options_ al `settings.js` por defecto, comparar con `docker run --rm nodered/node-red:<tag> cat /usr/src/node-red/settings.js` y mergear cambios relevantes.

---

## `~/homelab/domotica/nodered/flows.example.json` (flow mínimo de validación)

Un flujo de bootstrap que se importa al primer login para verificar end-to-end que la conexión MQTT y la conexión HA WebSocket funcionan. Se borra (o se mantiene) tras la primera validación a discreción del operador.

```json
[
  {
    "id": "tab-bootstrap",
    "type": "tab",
    "label": "Bootstrap homelab",
    "info": "Flow de validación inicial. Documentado en docs/08-domotica/04-node-red.md."
  },
  {
    "id": "inject-heartbeat",
    "type": "inject",
    "z": "tab-bootstrap",
    "name": "cada 60 s",
    "props": [{"p": "payload"}, {"p": "topic", "vt": "str"}],
    "repeat": "60",
    "topic": "nodered/heartbeat",
    "payload": "online",
    "payloadType": "str",
    "x": 130,
    "y": 80
  },
  {
    "id": "mqtt-out-heartbeat",
    "type": "mqtt out",
    "z": "tab-bootstrap",
    "name": "→ mosquitto",
    "topic": "nodered/heartbeat",
    "qos": "0",
    "retain": "true",
    "broker": "mqtt-broker",
    "x": 350,
    "y": 80
  },
  {
    "id": "mqtt-broker",
    "type": "mqtt-broker",
    "name": "mosquitto (domotica-internal)",
    "broker": "mosquitto",
    "port": "1883",
    "clientid": "nodered-homelab",
    "autoConnect": true,
    "credentials": {}
  }
]
```

Notas:

- El _broker_ MQTT en `mqtt-broker` apunta a `mosquitto:1883` (DNS de Docker en `domotica-internal`). Las credenciales se rellenan a mano la primera vez en el _editor_ y Node-RED las cifra en `flows_cred.json`.
- El topic `nodered/heartbeat` con `retain: true` permite que cualquier suscriptor (Uptime Kuma con monitor MQTT, HA, cualquier _debug_) sepa instantáneamente si Node-RED está vivo. Recibirá `online` cada 60 s; si llevan más de 90 s sin verlo, hay problema.
- **Sin** _palette_ HA en este flow mínimo. El operador la instala desde la UI (`Manage palette → Install → node-red-contrib-home-assistant-websocket`) y configura el _server_ HA con la URL `http://home-assistant:8123` y el `HA_LL_TOKEN_NODERED` del `.env`.

---

## `~/homelab/domotica/docker-compose.yml` — modificación

El _stack_ ya tiene `home-assistant`, `mosquitto`, `zigbee2mqtt`. Este documento añade `nodered`. El bloque a sumar:

```yaml
  # ---------------------------------------------------------------------------
  # Node-RED — motor de flujos visuales del homelab.
  #  - En 'homelab' (Caddy hace reverse_proxy a nodered:1880; HA WS reachable).
  #  - En 'domotica-internal' (habla con mosquitto:1883 sin cruzar 'homelab').
  #  - userDir = /data, montado a /mnt/hd2t/services/nodered.
  # ---------------------------------------------------------------------------
  nodered:
    image: nodered/node-red:${NODERED_IMAGE_TAG}
    container_name: nodered
    hostname: nodered
    restart: unless-stopped
    user: "1000:1000"
    environment:
      TZ: ${TZ}
      # Variables que el settings.js lee desde process.env.
      NODE_RED_ADMIN_PASSWORD_HASH: ${NODE_RED_ADMIN_PASSWORD_HASH}
      NODE_RED_CREDENTIAL_SECRET:   ${NODE_RED_CREDENTIAL_SECRET}
      NODERED_MQTT_USERNAME:        ${NODERED_MQTT_USERNAME}
      NODERED_MQTT_PASSWORD:        ${NODERED_MQTT_PASSWORD}
      HA_LL_TOKEN_NODERED:          ${HA_LL_TOKEN_NODERED}
      # Heap ample para flujos con agregaciones; ajustar si la Pi se ve apretada.
      NODE_OPTIONS: "--max-old-space-size=512"
    volumes:
      - /mnt/hd2t/services/nodered:/data
      - /etc/localtime:/etc/localtime:ro
    networks:
      homelab:
        aliases:
          - nodered
      domotica-internal:
        aliases:
          - nodered
    labels:
      homelab.stack: "domotica"
      homelab.backup: "true"
      # Opt-out: bumps manuales con changelog (extiende docs/02-docker/04-watchtower.md).
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- --tries=1 --timeout=5 http://localhost:1880/red/ 2>/dev/null | grep -q 'Node-RED' || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s
    depends_on:
      mosquitto:
        condition: service_healthy
      home-assistant:
        condition: service_healthy
```

Notas de diseño:

- **`user: "1000:1000"`** explícito: el _entrypoint_ de la imagen `nodered/node-red:4.0.x-debian` ya corre como `node-red` (UID 1000, GID 1000) por defecto. La declaración explícita en el compose sirve como _invariante_ documentado: si en el futuro la imagen cambia su UID interno por sorpresa, el `chown` del bind mount lo seguirá garantizando.
- **`depends_on` con `service_healthy`**: Node-RED arranca después de Mosquitto (para que las primeras conexiones MQTT no fallen ruidosamente) y de HA (para que la _palette_ HA encuentre `home-assistant:8123` listo al primer `Deploy`). En arranques calientes (`docker compose restart nodered`) es _no-op_.
- **Sin `ports:`**: el _editor_ no se publica al host. Caddy es el único camino vía DNS Docker (`nodered:1880`).
- **Sin `devices:`**: Node-RED no necesita acceso a hardware especial (Z2M ya cubre Zigbee, Mosquitto ya cubre IoT). Si en el futuro se conecta un USB serial directamente a Node-RED (ej. lector RFID), se añade `devices:` análogo al de Z2M.
- **`NODE_OPTIONS: --max-old-space-size=512`**: techo de heap V8 en 512 MB. Suficiente para 50–100 flujos con tráfico moderado. Subir a 768 MB si la Pi tiene RAM disponible y los flujos manipulan mucho buffer (transformaciones de imágenes de cámaras IP, ETLs).
- **Logs a `stdout`**: por defecto. Visible en Dozzle y `docker logs`.

El `services:` block del `docker-compose.yml` queda con cuatro servicios (`home-assistant`, `mosquitto`, `zigbee2mqtt`, `nodered`); el `networks:` no cambia.

---

## Configuración de Caddy

Añadir el bloque al `Caddyfile` (versión simple, una sola `reverse_proxy` con Authelia delante; la versión separada `/red` vs `/api` se introduce cuando aparezca el primer webhook):

```caddy
node-red.lan {
    tls internal
    import security-headers
    import logging
    import authelia

    reverse_proxy nodered:1880 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto https
    }

    # Cuando aparezca el primer webhook (un flujo con http in en /api/<path>),
    # reemplazar el bloque por la versión @admin/handle /api/* descrita en
    # docs/08-domotica/04-node-red.md → Decisiones de diseño → httpAdminRoot.
}
```

> **`/red` vs `/`**: con la `httpAdminRoot: '/red'` del `settings.js`, el editor vive en `https://node-red.lan/red/`. Una visita a `https://node-red.lan/` raíz devuelve 404 de Node-RED. Para que el operador no tenga que escribir `/red/` cada vez, se añade un redirect:
>
> ```caddy
> redir / /red/ permanent
> ```
>
> dentro del bloque, justo después del `reverse_proxy`. Tras un cambio de `httpAdminRoot` (raro), actualizar también este redirect.

Validar y recargar Caddy:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

---

## Configuración de Authelia

Editar `~/homelab/seguridad/authelia/access_control.yml` y descomentar la línea `# - 'node-red.lan'` que `docs/08-domotica/03-zigbee2mqtt.md` dejó preparada en la lista `two_factor`:

```yaml
access_control:
  default_policy: deny
  rules:
    - domain:
        - 'auth.lan'
      policy: bypass
    - domain:
        - 'zigbee2mqtt.lan'
        - 'node-red.lan'      # ← descomentar
        - 'portainer.lan'
        - 'grafana.lan'
        - 'prometheus.lan'
        - 'dozzle.lan'
        - 'uptime-kuma.lan'
      policy: two_factor
    # ... resto de reglas
```

Recargar Authelia:

```bash
docker compose -f ~/homelab/seguridad/docker-compose.yml restart authelia
docker logs authelia --tail 20 | grep -i 'configuration loaded'
```

---

## Despliegue

### Validar la sintaxis del compose

```bash
cd ~/homelab/domotica
docker compose --env-file ../.env --env-file .env config | grep -E 'nodered|/data' -A 1 -B 1
```

Salida esperada incluye:

```
    image: nodered/node-red:4.0.9-debian
    user: 1000:1000
    - /mnt/hd2t/services/nodered:/data
      domotica-internal:
      homelab:
```

### Levantar el servicio

```bash
cd ~/homelab
make up STACK=domotica
```

O equivalente:

```bash
cd ~/homelab/domotica
docker compose --env-file ../.env --env-file .env up -d nodered
```

Esperar al `(healthy)`:

```bash
docker compose -f ~/homelab/domotica/docker-compose.yml ps
# NAME            IMAGE                              STATUS
# home-assistant  homeassistant/home-assistant:...   Up X minutes (healthy)
# mosquitto       eclipse-mosquitto:2.0.20           Up X minutes (healthy)
# zigbee2mqtt     koenkk/zigbee2mqtt:1.40.1          Up X minutes (healthy)
# nodered         nodered/node-red:4.0.9-debian      Up Y seconds (healthy)
```

### Logs del primer arranque

```bash
docker logs nodered --tail 60
```

Salida esperada (líneas relevantes):

```
Welcome to Node-RED
===================
4 Apr ... [info] Node-RED version: v4.0.9
4 Apr ... [info] Node.js  version: v20.x.x
4 Apr ... [info] Linux 6.x.x arm64 LE
4 Apr ... [info] Loading palette nodes
4 Apr ... [info] Settings file  : /data/settings.js
4 Apr ... [info] Context store  : 'default' [module=localfilesystem]
4 Apr ... [info] User directory : /data
4 Apr ... [info] Projects directory: /data/projects
4 Apr ... [info] Flows file     : /data/flows.json
4 Apr ... [info] Server now running at http://127.0.0.1:1880/red/
4 Apr ... [info] Starting flows
4 Apr ... [info] Started flows
```

Lo que **no** debe aparecer:

- `Error loading credentials file` → `flows_cred.json` corrupto o `credentialSecret` cambió. Ver **Troubleshooting**.
- `Failed to start flows` → un flow tiene un nodo con error. Ver Troubleshooting.
- `Module not found: ...` → una _palette_ instalada por la UI quedó referenciada en `package.json` pero el `npm install` falló. Ejecutar `docker compose exec nodered npm install` manualmente.

---

## Verificación funcional

### Editor accesible vía Caddy + Authelia

Desde un navegador:

1. Ir a `https://node-red.lan/`.
2. Caddy redirige a `/red/`.
3. Authelia intercepta y redirige a `https://auth.lan/?rd=https://node-red.lan/red/`.
4. Introducir usuario + contraseña + 2FA TOTP.
5. Tras Authelia, Node-RED muestra **su propia pantalla de login** (`adminAuth`).
6. Usuario `admin`, contraseña la que se hasheó en `NODE_RED_ADMIN_PASSWORD_HASH`.
7. El editor carga: paleta a la izquierda, _workspace_ vacío, panel de info/debug a la derecha.

> **Si la pantalla de login propia no aparece** y el editor entra directo: revisar el `settings.js` real en hd2t — la sección `adminAuth` puede haber quedado mal copiada y Node-RED arrancó **sin autenticación interna**. Anular y restaurar.

### Conexión MQTT

Importar el `flows.example.json` desde el menú **Hamburger → Import → Clipboard**, pegar el contenido, **Deploy**. Configurar las credenciales del nodo `mqtt-broker` (usuario `nodered`, password de Vaultwarden), **Deploy** otra vez.

Tras 60 s, suscribirse al topic `nodered/heartbeat` desde el host:

```bash
mosquitto_sub -h 192.168.1.3 -p 1883 \
  -u monitor -P "<password de monitor>" \
  -t 'nodered/heartbeat' -v -C 1
# nodered/heartbeat online
```

Y desde la UI de Node-RED, en el panel _Debug_, ver mensajes recurrentes confirmando los _publish_.

### Conexión a HA WebSocket

1. **Manage palette → Install → `node-red-contrib-home-assistant-websocket`** → esperar al `npm install` (1–3 min en Pi 5).
2. Tras la instalación, los `home-assistant` nodes aparecen en la paleta.
3. Arrastrar un nodo `events: state` al workspace.
4. Configurar el _server_ HA: **URL** `http://home-assistant:8123`, **Access Token** = el `HA_LL_TOKEN_NODERED` del `.env`. **Save**.
5. **Deploy**. El nodo cambia a verde con el texto `connected` debajo.
6. En la UI de HA, ir a **Settings → Devices & services → Helpers** y crear un _input_boolean_ `test_node_red`. Tooglearlo desde la UI de HA.
7. Volver a Node-RED: el nodo `events: state` debería disparar mensajes en _Debug_ con `entity_id: input_boolean.test_node_red` cada vez que se toggle.

> **Si el nodo HA queda en rojo "disconnected"**: comprobar (a) que `home-assistant` resuelve desde dentro del contenedor: `docker exec nodered nslookup home-assistant`; (b) que el token es válido (no caducado): `curl -H "Authorization: Bearer $HA_LL_TOKEN_NODERED" http://home-assistant:8123/api/` devuelve `{"message":"API running."}`; (c) que HA está corriendo y `(healthy)`.

### Flujo de prueba: Zigbee → Node-RED → HA → notificación

Para validar la integración _end-to-end_:

1. Arrastrar un `mqtt in` con topic `zigbee2mqtt/<un-sensor-emparejado>` (broker `mosquitto`, suscrito al broker ya configurado).
2. Conectar a un nodo `function` que extraiga el `payload.battery`.
3. Conectar a un `switch` que sólo deje pasar si `battery < 20`.
4. Conectar a un `home-assistant` → `call service` → `notify.mobile_app_<dispositivo>` con mensaje "Sensor de cocina con batería baja".
5. **Deploy**.

El flujo se dispara cuando un sensor reporta batería <20 %. Útil ya en su propio derecho.

### Heartbeat permanente

Mantener un flow dedicado `nodered/heartbeat → online` cada 60 s con `retain: true` para que:

- Uptime Kuma pueda monitorizarlo: monitor MQTT a `tcp://mosquitto:1883`, topic `nodered/heartbeat`, esperar mensaje `online` cada 90 s. Alerta si no llega.
- HA puede crear un `binary_sensor` MQTT que refleje el estado de Node-RED (online/offline) y mostrar un badge en el dashboard.

---

## Backup

Node-RED cae en la **Categoría F** (filesystem-only): la fuente respaldable es `/mnt/hd2t/services/nodered/`, ya cubierta por `source_directories: /mnt/hd2t/services` de Borgmatic. **No hace falta acción nueva** para que `flows.json`, `flows_cred.json`, `settings.js`, `package.json` y `package-lock.json` entren en el siguiente _archive_.

### Excluir `node_modules/`

Añadir (si no está ya) a `~/homelab/backups/borgmatic/config.yaml` en `exclude_patterns`:

```yaml
exclude_patterns:
  - '*/log/*'
  - '*/cache/*'
  - '*/node_modules/*'    # ← Node-RED, FreshRSS si llega, otros futuros con npm
```

Razón: el `node_modules/` de Node-RED puede pesar 200–500 MB y se recrea en segundos con `npm install` desde `package.json`/`package-lock.json` ya respaldados. Backup más ligero, restauración más rápida.

### Decisión: **no** hacer dump activo

El bloque comentado que `docs/07-backups/03-backup-docker-volumes.md` dejó preparado en `dump-databases.sh` se mantiene comentado (no se añade nada). Razones:

- `flows.json`, `flows_cred.json`, `settings.js`, `package.json` se reescriben atómicamente (`rename(2)` tras `.tmp`).
- Node-RED no tiene base de datos en sentido tradicional; el _context store_ por fichero (`/data/context/`) también es atómico.
- Detener Node-RED durante el dump dejaría flujos sin ejecutar durante decenas de segundos. Para un homelab que reacciona a sensores en tiempo real, aceptable durante un mantenimiento programado pero no en cada ciclo de Borg (cada hora).

### Confirmar cobertura por Borgmatic

```bash
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL::$(borg list --short "$BORG_REPO_LOCAL" | tail -1)" \
    | grep nodered | head -10
'
# -rw-r----- 1000 1000 ... mnt/hd2t/services/nodered/settings.js
# -rw------- 1000 1000 ... mnt/hd2t/services/nodered/flows_cred.json
# -rw-r--r-- 1000 1000 ... mnt/hd2t/services/nodered/flows.json
# -rw-r--r-- 1000 1000 ... mnt/hd2t/services/nodered/package.json
# -rw-r--r-- 1000 1000 ... mnt/hd2t/services/nodered/package-lock.json
```

(El `node_modules/` debe **no** aparecer.)

### Restauración

Procedimiento estándar:

1. `docker compose -f ~/homelab/domotica/docker-compose.yml stop nodered`.
2. Mover `/mnt/hd2t/services/nodered/` a `nodered.broken-<ts>`.
3. `borg extract` del archive elegido a `/tmp/restore-$$/` y mover en sitio.
4. `sudo chown -R 1000:1000 /mnt/hd2t/services/nodered`.
5. `sudo chmod 0700 /mnt/hd2t/services/nodered`.
6. `sudo chmod 0600 /mnt/hd2t/services/nodered/flows_cred.json`.
7. **Reinstalar `node_modules/`**: `docker compose -f ~/homelab/domotica/docker-compose.yml run --rm --entrypoint sh nodered -c 'cd /data && npm ci'` (usa `package-lock.json` para resolver versiones exactas). Tarda 1–5 min según número de _palettes_.
8. `docker compose -f ~/homelab/domotica/docker-compose.yml up -d nodered`.
9. Esperar al `(healthy)`. Comprobar logs por `Started flows`.

> **Importante**: el `credentialSecret` debe ser el **mismo** del momento del backup. Si se restaura un backup viejo y entretanto el `.env` cambió `NODE_RED_CREDENTIAL_SECRET`, los `flows_cred.json` no se descifran y los flujos arrancan con credenciales vacías. Anotar siempre el `credentialSecret` con la fecha de cambio en Vaultwarden ("homelab — node-red — credentialSecret 2026-04-26 →") para poder revertirlo si hace falta.

> **Restauración limpia desde cero (catástrofe total)**: si los discos hd2t están perdidos y no hay backup local, queda el _archive_ de Borg en _offsite_. Los pasos son los mismos; la pérdida es ≤ 1 hora de operaciones (frecuencia de Borgmatic).

---

## Verificación

Antes de cerrar este documento:

- [ ] `~/homelab/domotica/docker-compose.yml`, `~/homelab/domotica/.env.example`, `~/homelab/domotica/nodered/settings.js.example` y `~/homelab/domotica/nodered/flows.example.json` versionados en git. `~/homelab/domotica/.env` **no** versionado. `/mnt/hd2t/services/nodered/settings.js` con `0640 1000:1000` y `/mnt/hd2t/services/nodered/flows_cred.json` con `0600 1000:1000`.
- [ ] `docker compose -f ~/homelab/domotica/docker-compose.yml ps` muestra `home-assistant`, `mosquitto`, `zigbee2mqtt`, `nodered` los cuatro `(healthy)`.
- [ ] `docker logs nodered --tail 30` muestra `Started flows` y `Server now running at http://127.0.0.1:1880/red/`. **No** muestra `Error loading credentials file` ni `Failed to start flows`.
- [ ] `https://node-red.lan/` redirige a `/red/`, pasa por Authelia (TOTP), luego por el `adminAuth` nativo de Node-RED, y carga el editor.
- [ ] `import authelia` está presente en el bloque `node-red.lan` del `Caddyfile`.
- [ ] `access_control.yml` de Authelia tiene `'node-red.lan'` en la lista `two_factor` (descomentada).
- [ ] El flow de bootstrap (`flows.example.json`) está desplegado y publica `nodered/heartbeat → online` cada 60 s con `retain: true`. Verificable con `mosquitto_sub` desde el host.
- [ ] La _palette_ `node-red-contrib-home-assistant-websocket` está instalada y el _server_ HA aparece como `connected` en al menos un nodo del flow.
- [ ] Un cambio de estado en HA (toggle de un `input_boolean`) dispara un mensaje visible en _Debug_ del editor.
- [ ] La red `domotica-internal` sigue intacta: `docker network inspect domotica-internal` muestra `mosquitto`, `zigbee2mqtt`, `nodered` (y opcionalmente HA) como _containers_ conectados.
- [ ] Watchtower no toca el contenedor: `docker logs watchtower --tail 100 | grep nodered` no muestra "Found new image" para Node-RED.
- [ ] Borgmatic _dry-run_ incluye `flows.json`, `flows_cred.json`, `settings.js`, `package.json`, `package-lock.json` y **excluye** `node_modules/`: `sudo /usr/bin/borgmatic --dry-run --verbosity 2 | grep nodered`.
- [ ] El `credentialSecret` y la contraseña en claro del `admin` están anotados en Vaultwarden bajo "homelab — node-red".

---

## Operación día a día

### Crear un flow nuevo

1. Editor → tab nuevo (`+` arriba) → arrastrar nodos desde la paleta.
2. **Deploy** (botón rojo arriba a la derecha) → Node-RED reescribe `flows.json` y reinicia los flujos modificados (no todo el runtime — el _Modified Flows_ default sólo recarga lo que cambió).
3. Verificar en _Debug_ que los mensajes circulan como se espera.

### Instalar una _palette node_ nueva

1. **Hamburger menu → Manage palette → Install**.
2. Buscar el paquete (ej. `node-red-dashboard` para añadir un dashboard interactivo).
3. **Install** → confirma → `npm install` se ejecuta dentro del contenedor.
4. La _palette_ aparece en la lista lateral. Reiniciar el editor (no hace falta reiniciar Node-RED entero).
5. **Commit del cambio**: `package.json` y `package-lock.json` se actualizaron en hd2t. Como **no** están versionados en git directamente (cambian con la UI), Borg los respalda en el siguiente ciclo. Nada que hacer.

> **Anotar nombres de las _palettes_ instaladas** en `docs/08-domotica/04-node-red.md` → sección _Palettes nominales_ (no creada en este doc, se añade cuando se instalen). Útil para reproducir el entorno en una recuperación.

### Heartbeat de Node-RED

El flow del `flows.example.json` ya publica `nodered/heartbeat: online` con retain. Para integrarlo con HA como `binary_sensor`, añadir a `~/homelab/domotica/home-assistant/configuration.yaml` (el `mqtt:` block que ya configuró `01-home-assistant.md`):

```yaml
mqtt:
  binary_sensor:
    - name: "Node-RED status"
      state_topic: "nodered/heartbeat"
      payload_on:  "online"
      payload_off: "offline"
      device_class: connectivity
      expire_after: 120     # si no llega heartbeat en 120s, marcar OFF
```

Y para Uptime Kuma, monitor MQTT con `Match payload: online`. Ambos son _opcionales_ pero útiles.

### Versionar los flujos con _projects_

Con `editorTheme.projects.enabled: true` en `settings.js`, Node-RED ofrece un wizard de _Project_ al primer login:

1. **Create new project** → nombre `homelab-flows` → autor `<nombre>` → email.
2. Seleccionar **Initialise as new git repo**.
3. Cada **Deploy** crea un commit local en `/data/projects/homelab-flows/.git/`.
4. Para empujar a un remoto (GitHub privado, Gitea local), configurar las credenciales SSH del usuario `node-red` dentro del contenedor (volumen `~/.ssh` o variable `SSH_AUTH_SOCK`) — requiere ajustes adicionales no cubiertos en este doc.

> **Por qué un repo separado del repo del homelab**: los flujos de Node-RED se editan con frecuencia (varios commits/día durante desarrollo) y mezclarlos con el repo principal del homelab generaría ruido. Un sub-repo dedicado mantiene la historia limpia.

### Logs

Por contenedor (Dozzle o `docker logs`):

```bash
docker logs nodered --since 1h --tail 200 | grep -iE 'error|warn|fail'
```

Errores típicos del runtime:

- `[error] [function:<id>] ReferenceError: foo is not defined`: un nodo `function` con código JavaScript erróneo. El editor lo marca con un triángulo rojo.
- `[warn] [mqtt-broker:mosquitto] Disconnected from broker`: pérdida momentánea de conexión MQTT. Z2M, HA y Node-RED se reconectan automáticamente; un parpadeo es normal tras un `restart` de Mosquitto.
- `[error] [home-assistant:<id>] WebSocket error: 1006`: HA inalcanzable. Verificar `home-assistant` (`docker ps`).

---

## Troubleshooting

### Primer arranque: `nodered` se queda en `starting` y luego `unhealthy`

```bash
docker logs nodered --tail 100
```

Causas comunes:

- **`Error: Cannot find module '<palette>'`**: una _palette_ está en `package.json` pero `node_modules/` no la tiene (típico tras restauración de Borg sin `npm install`). Ejecutar:

  ```bash
  docker compose -f ~/homelab/domotica/docker-compose.yml run --rm \
    --entrypoint sh nodered -c 'cd /data && npm ci'
  docker compose -f ~/homelab/domotica/docker-compose.yml up -d nodered
  ```

- **`Error loading credentials file: ... credentialSecret has changed`**: el `NODE_RED_CREDENTIAL_SECRET` del `.env` no coincide con el que cifró `flows_cred.json`. Recuperar el secret correcto desde Vaultwarden (anotado por fecha) y ponerlo en `.env`. Reiniciar.

- **`Error: EACCES permission denied, open '/data/flows.json'`**: el bind mount tiene _ownership_ incorrecto. Aplicar:

  ```bash
  sudo chown -R 1000:1000 /mnt/hd2t/services/nodered
  sudo chmod 0700 /mnt/hd2t/services/nodered
  ```

- **`Failed to start flows: SyntaxError: Unexpected token`**: `flows.json` corrupto (raro, pero puede pasar tras un `kill -9` durante un Deploy). Restaurar desde el backup automático:

  ```bash
  sudo mv /mnt/hd2t/services/nodered/flows.json /mnt/hd2t/services/nodered/flows.json.broken
  sudo cp /mnt/hd2t/services/nodered/.flows.json.backup /mnt/hd2t/services/nodered/flows.json
  sudo chown 1000:1000 /mnt/hd2t/services/nodered/flows.json
  docker compose restart nodered
  ```

### El editor no carga (timeout en el navegador)

- **Authelia bloquea**: `docker logs authelia --tail 30 | grep node-red.lan`. Si hay errores de configuración, revisar `access_control.yml`.
- **Caddy no resuelve `nodered:1880`**: `docker network inspect homelab | grep nodered` debe mostrar el contenedor. Si no, recrearlo: `docker compose up -d --force-recreate nodered`.
- **Node-RED tarda en cargar**: con muchas _palettes_, el primer arranque puede tardar 90+ s. Esperar hasta `start_period: 90s` y un par de ciclos del healthcheck.
- **Login de Node-RED rechaza la contraseña correcta**: el hash bcrypt está mal copiado en `.env` (caracteres especiales sin escapar). Regenerar con `node-red admin hash-pw`, comprobar que las **comillas simples** rodean el hash en `.env`.

### Conexión MQTT falla (`Disconnected from broker` en bucle)

- **Credenciales mal**: el usuario/password configurado en el nodo `mqtt-broker` no coincide con el `passwd` de Mosquitto. Comprobar:

  ```bash
  mosquitto_sub -h 192.168.1.3 -u nodered -P "<password de .env>" \
    -t '$SYS/broker/version' -C 1
  # mosquitto version 2.0.20
  ```

- **Broker inalcanzable**: comprobar que `nodered` está en la red `domotica-internal` y que `mosquitto` también: `docker network inspect domotica-internal`.

- **ACL niega**: el usuario `nodered` debe tener `readwrite #` (o más restrictivo si se decidió ajustar). Ver `docs/08-domotica/02-mosquitto.md` → sección **`acl`**.

### Conexión HA falla (`WebSocket error 401 Unauthorized`)

- **Token inválido o caducado**: regenerar desde HA → Settings → Users → nodered → Long-Lived Access Tokens → revoke el anterior, create new. Actualizar `HA_LL_TOKEN_NODERED` en `.env`. **Recrear** el contenedor (no basta `restart` porque el token se cachea en memoria de los _HA nodes_):

  ```bash
  docker compose -f ~/homelab/domotica/docker-compose.yml up -d --force-recreate nodered
  ```

  Y en el editor, abrir el _HA server config_ y reescribir el token en el campo (la _palette_ guarda el token cifrado en `flows_cred.json`; si el `.env` cambia pero el `flows_cred.json` mantiene el viejo, el viejo se usa).

- **HA no acepta WebSocket** (`502 Bad Gateway` o similar): comprobar que la integración HTTP de HA tiene `use_x_forwarded_for: true` y `trusted_proxies` configurado para que reconozca a Node-RED como proxy interno. Pero como Node-RED **no atraviesa Caddy** para llegar a HA (va directo por DNS Docker), esto no debería ser problema. Si lo es, es síntoma de algo raro en la red Docker.

### `Deploy` no aplica cambios

- Verificar **modo de Deploy** (icono al lado del botón rojo): _Full Deploy_ vs _Modified Flows_ vs _Modified Nodes_. Si está en _Modified Nodes_ y se cambió un nodo `subflow`, el cambio no propaga; subir a _Modified Flows_ o _Full_.
- Comprobar `flows.json` en hd2t: tras un Deploy, su `mtime` debe ser reciente (`stat /mnt/hd2t/services/nodered/flows.json`).

### El contenedor consume mucha CPU continua

Síntomas: `top` muestra `node` al 50–80 % de un core durante minutos sin tráfico aparente.

Causas frecuentes:

- **Un flujo en bucle**: un `function` que reenvía a sí mismo, o un `link out → link in` que conecta un mismo flujo en bucle. Revisar pestaña _Performance_ (si la _palette_ `node-red-contrib-msg-speed` está instalada) para ver tasas de mensajes por nodo.
- **Una _palette_ defectuosa**: algún _custom node_ haciendo polling agresivo. Revisar logs `docker logs nodered | grep <palette>`.
- **Mucho tráfico MQTT**: si hay 50+ sensores Zigbee y el flujo procesa cada `zigbee2mqtt/#`, son centenas de mensajes/segundo. Usar `mqtt in` con topics más restrictivos (`zigbee2mqtt/<sensor-concreto>` en lugar de `#`).

### `npm install` desde la UI falla con `EACCES`

La UI muestra: `Error: EACCES: permission denied, mkdir '/data/node_modules/<paquete>'`.

Causa: `node_modules/` tiene _ownership_ incorrecto tras una restauración. Aplicar:

```bash
sudo chown -R 1000:1000 /mnt/hd2t/services/nodered/node_modules
docker compose -f ~/homelab/domotica/docker-compose.yml restart nodered
```

### Pérdida del `credentialSecret`

Si el `.env` se borró sin backup y Vaultwarden no tiene el secret:

1. **Aceptar la pérdida**: borrar `flows_cred.json` para que Node-RED arranque con credenciales vacías:

   ```bash
   sudo mv /mnt/hd2t/services/nodered/flows_cred.json \
           /mnt/hd2t/services/nodered/flows_cred.json.lost
   ```

2. Generar un `credentialSecret` nuevo (`openssl rand -hex 32`), ponerlo en `.env`, **anotarlo en Vaultwarden** esta vez.
3. Reiniciar. Node-RED arranca con `flows_cred.json` vacío. El editor marca todos los nodos con credenciales como _missing config_.
4. Re-introducir las credenciales (passwords MQTT, token HA) desde la UI. Node-RED las cifra con el nuevo secret.
5. Deploy. **Lección operativa**: el `credentialSecret` SIEMPRE en Vaultwarden, no sólo en `.env`.

---

## Actualización

### Bumps de _patch_ (`4.0.9 → 4.0.10`)

```bash
# 1. Leer el changelog upstream
xdg-open https://github.com/node-red/node-red/blob/master/CHANGELOG.md

# 2. Actualizar el .env
$EDITOR ~/homelab/domotica/.env
# NODERED_IMAGE_TAG=4.0.10-debian

# 3. Pull y recreate
cd ~/homelab
make pull STACK=domotica
make up STACK=domotica

# 4. Verificar
docker logs nodered --tail 30
docker compose -f ~/homelab/domotica/docker-compose.yml ps nodered
```

El recreate dura 10–30 s. Mosquitto y HA siguen intactos. Los flujos se reanudan al levantar; clientes MQTT se reconectan en milisegundos.

### Bumps de _minor_ (`4.0.x → 4.1.y`)

- **Backup explícito previo**:

  ```bash
  sudo /usr/bin/borgmatic --verbosity 1
  ```

- Leer el _changelog_ buscando **Breaking changes** en `flows.json` schema y en API de _custom nodes_.
- Comprobar que las _palettes_ instaladas son compatibles con el nuevo Node-RED:

  ```bash
  docker compose -f ~/homelab/domotica/docker-compose.yml exec nodered \
    npm outdated --depth=0 | head -20
  ```

  Y ver _GitHub issues_ de cada _palette_ buscando "node-red 4.1 compatibility".

- `docker compose pull && docker compose up -d nodered`.
- Tras el upgrade, abrir el editor y comprobar que **ningún nodo aparece rojo**. Si alguno lo hace, su _palette_ no es compatible: hacer `npm update <palette>` desde dentro del contenedor o esperar a una versión compatible y revertir.

### Bumps de _major_ (`4.x → 5.x`)

- Backup, leer Migration Guide upstream completo (`https://nodered.org/docs/getting-started/upgrading`).
- Probar en un entorno aislado primero (`docker run --rm -v /tmp/nodered-test:/data nodered/node-red:5.x.x`) con una **copia** de `flows.json` y comprobar que migra sin errores.
- Aplicar en producción sólo cuando la prueba pase. Tener el `flows.json.backup` automático y el archive de Borg listos para revertir.

### Cambio de imagen base (debian → alpine, p. ej.)

No recomendado salvo razón técnica fuerte (espacio en disco crítico). Algunas _palettes_ con compilación nativa fallan en Alpine por ausencia de `glibc`/headers. Si se hace, probar primero en una rama del repo y validar que todos los flujos arrancan.

---

## Decisiones avanzadas (deferidas)

Anotadas como referencia para futuras revisiones; no se aplican en este documento:

- **`httpAdminRoot` y `httpNodeRoot` separados con Caddy `@admin / handle /api/*`**: cuando aparezca el primer webhook en un flujo `http in`, reescribir el bloque del `Caddyfile` (sección **Decisiones de diseño → `httpAdminRoot`**) para que `/api` quede sin Authelia y los dispositivos LAN puedan llamar webhooks sin sesión.
- **Auditoría con `logging.audit: true`**: deja registro de cada llamada a `/red/*`. Útil cuando el homelab tenga >1 usuario humano. Se valora cuando llegue.
- **Almacenamiento de _context_ en Redis**: si crece la persistencia de contexto y `localfilesystem` se queda corto, migrar a `node-red-context-redis`. Hoy: innecesario.
- **Métricas Prometheus**: `node-red-contrib-prometheus-exporter` expone métricas `/metrics`. Cuando Prometheus llegue a este homelab y se quiera observabilidad de tasas de mensajes por flujo, instalarlo. Hoy: deferido.
- **Migración de automatizaciones de HA a Node-RED**: el `automations.yaml` de HA puede crecer a 200+ líneas con automatizaciones complejas. Cuando una automatización requiere debugger visual o ramificación >3 niveles, **migrarla** a Node-RED y borrarla de HA (no duplicar).

---

## Referencias

- Documentación oficial — Node-RED: <https://nodered.org/docs/>
- `settings.js`: <https://nodered.org/docs/user-guide/runtime/configuration>
- _Projects_ feature: <https://nodered.org/docs/user-guide/projects/>
- _Securing Node-RED_ (admin auth, credentialSecret, https): <https://nodered.org/docs/user-guide/runtime/securing-node-red>
- Imagen oficial — `nodered/node-red`: <https://hub.docker.com/r/nodered/node-red>
- Releases (changelogs): <https://github.com/node-red/node-red/releases>
- _Palette_ HA (recomendada): <https://flows.nodered.org/node/node-red-contrib-home-assistant-websocket>
- Catálogo público de _palettes_: <https://flows.nodered.org/>
- Documentos relacionados del homelab:
  - `docs/01-sistema/04-estructura-directorios.md` — árbol `/mnt/hd2t/services/nodered/`.
  - `docs/02-docker/02-estructura-compose.md` — convenciones del _stack_ `domotica`, redes Docker.
  - `docs/02-docker/04-watchtower.md` — Node-RED se añade a la lista nominal de _opt-out_.
  - `docs/03-red/04-caddy.md` — bloque `node-red.lan`, _snippets_.
  - `docs/04-seguridad/01-authelia.md` — `forward_auth` (`import authelia`), regla `two_factor` para `node-red.lan`.
  - `docs/05-monitorizacion/05-uptime-kuma.md` — _monitor_ HTTP a `http://nodered:1880/red/` y MQTT a `nodered/heartbeat`.
  - `docs/05-monitorizacion/06-dozzle.md` — logs del contenedor visibles en tiempo real.
  - `docs/07-backups/02-borgmatic.md` — `source_directories: /mnt/hd2t/services` cubre Node-RED; `*/node_modules/*` excluido.
  - `docs/07-backups/03-backup-docker-volumes.md` — Categoría F (filesystem-only); sin dump activo.
  - `docs/08-domotica/01-home-assistant.md` — HA con WebSocket API, usuario `nodered`, Long-Lived Access Token.
  - `docs/08-domotica/02-mosquitto.md` — broker MQTT, usuario `nodered` con ACL `readwrite #`, red `domotica-internal`.
  - `docs/08-domotica/03-zigbee2mqtt.md` — eventos `zigbee2mqtt/#` que Node-RED puede consumir para automatizaciones avanzadas.
