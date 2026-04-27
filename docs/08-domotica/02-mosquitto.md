# Mosquitto (broker MQTT del stack `domotica`)

## Descripción

Despliegue de **Eclipse Mosquitto** como **broker MQTT** del homelab: el _bus_ de mensajería _publish/subscribe_ que vertebra la comunicación entre **Home Assistant** (`docs/08-domotica/01-home-assistant.md`), **Zigbee2MQTT** (`docs/08-domotica/03-zigbee2mqtt.md`), **Node-RED** (`docs/08-domotica/04-node-red.md`) y los **dispositivos IoT físicos de la LAN** (sondas ESPHome, enchufes Tasmota, sensores ESP32 caseros, …). Mosquitto es el corazón de la fase 8 de este homelab: sin él, Z2M no tendría a quién publicar los eventos Zigbee, HA no tendría de dónde leerlos, y Node-RED no tendría sobre qué reaccionar.

Este documento **se suma al _stack_ `domotica`** que estrenó `docs/08-domotica/01-home-assistant.md`: añade un servicio `mosquitto` al `~/homelab/domotica/docker-compose.yml` ya existente, **estrena la red privada del _stack_ `domotica-internal`** prometida en aquel doc, y crea el subdirectorio versionado `~/homelab/domotica/mosquitto/` con el `mosquitto.conf` y la ACL del broker. Toda la persistencia (BD de _retained messages_, _passwd_ con _bcrypt_, logs) vive en el disco externo **hd2t** (`/mnt/hd2t/services/mosquitto/`), nunca en la microSD: `mosquitto.db` se reescribe cada `autosave_interval` y mataría el _flash_ a medio plazo.

> **Alcance**: este documento despliega Mosquitto 2.0 con autenticación obligatoria (`allow_anonymous false`), _password file_ generado con `mosquitto_passwd` y **ACL granular** por usuario (`homeassistant`, `zigbee2mqtt`, `nodered`, `iot`, `monitor`). Publica el puerto **1883/tcp** **sólo en la IP de la LAN del host** (`192.168.1.3:1883`) para que dispositivos físicos de la LAN puedan conectarse, y deja al puerto interno accesible además por la red Docker `homelab` (para el _monitor_ de Uptime Kuma) y por la red privada `domotica-internal` (para HA, Z2M y Node-RED). **No** habilita TLS sobre MQTT (puerto 8883) — distribuir la CA local a cada microcontrolador ESP32 es una fricción operativa que se documentará aparte cuando llegue a hacer falta. **No** habilita el _listener_ WebSocket (9001) — sin un cliente web MQTT desplegado (no lo hay), no aporta valor. **No** integra `forward_auth` con Authelia (MQTT no es HTTP; Caddy ni siquiera entra en juego). **No** crea un _jail_ de Fail2ban específico para Mosquitto — los _bans_ se discuten en **Decisiones de diseño** y se difieren a una posible ampliación si la LAN llega a ser hostil.

> **Recordatorio de red**: Mosquitto **se publica al host sólo en `192.168.1.3:1883`** (la IP fija de la Pi en la LAN, ver `docs/03-red/01-macvlan.md`). Esto deja el broker accesible desde cualquier dispositivo de la LAN doméstica (10.0.0.0/8, 192.168.1.0/24, …) pero **invisible** para Tailscale (la VPN escucha en `100.x.y.z` y `tailscale0`, IPs distintas de `192.168.1.3`). Si en el futuro se quiere exponer MQTT por Tailscale (improbable: HA y Z2M ya están en LAN+Tailscale y son los únicos que necesitan MQTT desde fuera), se añade un segundo bind en `ports:`. Por dentro, los contenedores del _stack_ `domotica` alcanzan `mosquitto:1883` por DNS de Docker sobre la red privada `domotica-internal`.

---

## Requisitos previos

- `docs/02-docker/02-estructura-compose.md` completado: la red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) externa está creada, `~/homelab/.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `HOMELAB_DOMAIN=lan` está rellenado, y el _Makefile_ expone `make up STACK=<stack>`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/mosquitto/{config,data,log}/` ya existe vacío y la tabla de UIDs internos anota explícitamente que `mosquitto` corre como UID/GID `1883` y que **el `chown 1883:1883` específico se hace en este documento**. Confirmar:

  ```bash
  ls -la /mnt/hd2t/services/mosquitto/
  # drwxr-xr-x  5 root root ... .
  # drwxr-xr-x  2 root root ... config
  # drwxr-xr-x  2 root root ... data
  # drwxr-xr-x  2 root root ... log
  ```

- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada y Mosquitto figura en la lista nominal de _servicios opt-out_. Aquí se aplica esa etiqueta.
- `docs/08-domotica/01-home-assistant.md` completado: el _stack_ `domotica` (`~/homelab/domotica/`) existe con `docker-compose.yml`, `.env.example`, `.env` y `.gitignore`; Home Assistant está corriendo, `(healthy)` y reachable en `https://home-assistant.lan/`. La nota de aquel doc anuncia que **este** documento añade la red privada `domotica-internal`. La integración _MQTT_ de HA queda **pendiente de configurar** hasta el final de este documento (sección **Integración con Home Assistant**).
- `docs/05-monitorizacion/05-uptime-kuma.md` completado (recomendado pero no bloqueante): Uptime Kuma vive en la red `homelab` y aquel doc menciona explícitamente `tcp://mosquitto:1883` como ejemplo de _monitor_. Tras este documento, ese _monitor_ pasa a tener un servicio real al que apuntar.
- `docs/07-backups/02-borgmatic.md` completado: `source_directories: /mnt/hd2t/services` ya engloba `mosquitto/` por inercia. Este doc **no añade un dump** al _hook_ `dump-databases.sh` (las dos opciones — _filesystem cold copy_ tras `docker stop` o ignorar `mosquitto.db` por reconstruible — se discuten en **Backup**). El bloque comentado que `docs/07-backups/03-backup-docker-volumes.md` dejó preparado se queda **comentado**.
- Conectividad saliente para descargar la imagen (sólo la primera vez):

  ```bash
  docker pull --platform linux/arm64 eclipse-mosquitto:2.0.20 >/dev/null && echo OK
  ```

- Que el host **no** tenga ya un proceso escuchando en `192.168.1.3:1883`:

  ```bash
  sudo ss -tulpn '( sport = :1883 )'
  ```

  Salida esperada: vacía.

- El binario `mosquitto_passwd` disponible en el host para generar el _password file_ (alternativa: ejecutarlo dentro del propio contenedor antes de pinear los secretos; este doc usa esa segunda variante, así que **no hace falta** instalar `mosquitto-clients` en la Pi para el _bootstrap_). En cualquier caso, instalar los _clients_ es útil para diagnóstico:

  ```bash
  sudo apt install -y mosquitto-clients
  mosquitto_pub --help | head -1
  # mosquitto_pub is a simple mqtt client that will publish a message.
  ```

---

## Decisiones de diseño

### Por qué Mosquitto (y no HiveMQ CE / EMQX / RabbitMQ)

El homelab necesita un _broker_ MQTT que cumpla: protocolo MQTT 3.1.1 + 5.0 nativos, ACLs por usuario, _retained messages_ persistentes, _footprint_ minúsculo en una Pi, multi-arquitectura ARM64 mantenida y comunidad estable. Cuatro alternativas y por qué se descartan:

| Candidato                  | Por qué se descarta                                                                                                                                                                                                                                                  |
|----------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **HiveMQ CE**              | _Broker_ Java/JVM. Footprint ~300 MB en idle, JVM con _stop-the-world_ ocasional. ACLs requieren un _plugin_ extra (`hivemq-file-rbac-extension`), no son _first-class_. Excelente en clusters de millones de mensajes/s; sobredimensionado para 5–50 dispositivos IoT en una casa. |
| **EMQX**                   | _Broker_ Erlang con _dashboard_ web pulido, _clustering_, _rule engine_ visual y un sinfín de _extensions_. Rico, sí — pero ~150 MB de RAM en idle, _learning curve_ apreciable y mucha funcionalidad innecesaria para un homelab personal. La _community_ es activa pero muchas funciones interesantes ya viven en _EMQX Enterprise_ (de pago). |
| **RabbitMQ con plugin MQTT** | RabbitMQ es un _broker_ AMQP excelente. El _plugin_ MQTT funciona, pero traduce el protocolo a AMQP por debajo, con limitaciones (QoS 2 mapeado a QoS 1 en algunos casos, _retained_ persistido en _exchanges_ con su propia idiosincrasia). Si el homelab necesitara también AMQP, sería razonable; aquí sólo hace falta MQTT puro. |
| **VerneMQ**                | Erlang, distribuido, multi-tenant. Moribundo en mantenimiento desde 2024 (releases puntuales pero comunidad escasa). Riesgo a medio plazo.                                                                                                                          |

**Mosquitto gana por**:

- **Es la implementación de referencia** del proyecto Eclipse, escrito en C, ~10 MB de imagen, ~5–15 MB de RAM en idle. Cuesta menos que cualquiera de los anteriores en uno o dos órdenes de magnitud.
- **Soporta MQTT 3.1.1 y MQTT 5.0** nativamente desde la línea 2.0.
- **ACLs _per-topic_, _per-user_** integradas en la configuración de fábrica (`acl_file`), sin _plugins_.
- **Imagen oficial multi-arch** (`eclipse-mosquitto`) en Docker Hub, mantenida por el propio equipo de Eclipse, con `linux/arm64` desde la primera _release_ multi-arch.
- **Sintonía cultural con HA y Z2M**: la documentación oficial de ambos asume Mosquitto en sus ejemplos. _Battle-tested_ en miles de homelabs reales.
- **Footprint operativo trivial**: un único proceso, un único fichero de configuración, un fichero `passwd`, un fichero `acl`. Cabe entera en una pestaña del editor.

### Imagen y _tag_

- **`eclipse-mosquitto:2.0.20`** — Mosquitto **2.0.20**, parche estable de la línea 2.0 (publicada a finales de 2024; el _changelog_ de Eclipse documenta los _patch releases_ de 2.0 con frecuencia bimensual). Multi-arch (`linux/arm64` confirmado). Pinneada a _tag_ específico siguiendo la convención del homelab (`docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`, _tag_ explícito). Si en el momento del despliegue hay un `2.0.21` o superior dentro de la misma línea minor, usar el más reciente: la línea 2.0 mantiene compatibilidad de configuración entre _patches_.
- **Por qué no `:2`**: ese _tag_ se mueve a la última 2.x publicada. Aceptable para una imagen tan estable como Mosquitto, pero el patrón del homelab pinea explícitamente para que un `docker compose pull` accidental no introduzca un cambio sin que el operador lo note.
- **Por qué no `:latest`**: lo prohíbe la convención del homelab.
- **Bumps**: Mosquitto 2.0 ha sido estable durante años. Los _patches_ (`2.0.20 → 2.0.21`) suelen ser arreglos de seguridad o pequeños bugs y no requieren cambios de configuración. Un `2.0.x → 2.1` (cuando llegue) sí merece leer el _changelog_ por si introduce _breaking_.

#### Watchtower opt-out

Razones:

- **Migraciones del fichero `mosquitto.db`** ocasionales entre _major_ versions: la línea 1.x → 2.x cambió el formato. Aunque _patches_ dentro de 2.0 son seguros, mantener la actualización **manual** garantiza que el operador lea el _changelog_ antes de tocar producción.
- **Coherencia con la lista nominal** de `docs/02-docker/04-watchtower.md` → _Servicios que se mantienen en opt-out_, donde Mosquitto figura explícitamente.
- **Riesgo de pérdida de mensajes _retained_** si una migración fuese fallida: aunque los _retained_ son por definición rebuildables (los publicadores re-emiten en su próximo ciclo), los topics que mantienen estado de configuración (`zigbee2mqtt/bridge/config`, p. ej.) tardarían en regenerarse y podrían dejar a Z2M sin _state_ correcto durante minutos.

Etiquetar el contenedor con `com.centurylinklabs.watchtower.enable: "false"`.

### Modo de red: dos redes Docker (`homelab` + `domotica-internal`)

Mosquitto se conecta a **dos redes Docker** simultáneamente:

| Red                | Subnet (declarada) | Quién la usa                                                                  | Por qué                                                                                                          |
|--------------------|--------------------|--------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------|
| `homelab`          | `172.20.10.0/24`   | **Uptime Kuma** (cross-stack, ya monitorea `tcp://mosquitto:1883`); HA (que también está en `homelab`) | Permite a servicios de **otros stacks** alcanzar el broker por DNS de Docker (`mosquitto:1883`) sin tener que unirse a la red privada de domótica. |
| `domotica-internal` | `172.20.20.0/24`  | Mosquitto + (futuros) Zigbee2MQTT, Node-RED. HA puede pero no es obligatorio  | Tráfico MQTT _intra-stack_ aislado: Z2M y Node-RED no necesitan acceso a la red `homelab` (no hablan HTTP entre sí), por lo que vivirán **sólo** en `domotica-internal` cuando lleguen. |

#### `domotica-internal` se estrena aquí

La red privada `domotica-internal` la **crea este documento**. El compose la define como `internal: true` (sin acceso a internet desde dentro) y el `02-mosquitto` es su primer ocupante. Los siguientes documentos del fase 8 (Z2M y Node-RED) la usarán como su red única.

Nota explícita: **Home Assistant no se mueve a `domotica-internal`** en este documento. HA está en `homelab` desde `01-home-assistant.md` y desde ahí alcanza a Mosquitto perfectamente (`mosquitto:1883` sobre la red compartida). Reasignar HA a `domotica-internal` complicaría el bloque `home-assistant.lan` del Caddyfile (Caddy también tendría que estar en esa red, contradiciendo el principio de "Caddy sólo en `homelab`"). HA **se mantiene** en `homelab` y se beneficia de que Mosquitto **también** está allí.

> **¿Por qué no poner Mosquitto sólo en `domotica-internal` y exigir a HA y Uptime Kuma que se unan?** Sería más estricto pero rompería la regla "los servicios cross-stack viven en `homelab`" (`docs/02-docker/02-estructura-compose.md`, sección _Redes_). Mosquitto es _cross-stack_ por diseño (lo consume HA del stack `domotica`, Uptime Kuma del stack `monitor`, y dispositivos físicos de fuera de Docker). Negar a Uptime Kuma la resolución `mosquitto:1883` desde `homelab` obligaría a unirla a `domotica-internal`, escalando una decisión local a una decisión de _topología_. La autenticación del broker (sección siguiente) garantiza que estar en `homelab` **no relaja** la seguridad: cualquier cliente, esté donde esté, debe presentar credenciales válidas para publicar o suscribirse.

#### Publicación al host: `192.168.1.3:1883`, no `0.0.0.0:1883`

Los dispositivos físicos de la LAN doméstica (sensores ESP32, enchufes Tasmota, _gateways_ Bluetooth-MQTT, …) **no son contenedores** y no resuelven nombres de Docker. Necesitan llegar al broker por **IP estable de la LAN**, que en este homelab es `192.168.1.3` (la IP fija de la Pi reservada en el DHCP del router, ver `docs/03-red/01-macvlan.md`).

```yaml
ports:
  - "192.168.1.3:1883:1883/tcp"
```

Bind explícito a la IP de la LAN. Razones para **no** dejar `0.0.0.0:1883`:

- Tailscale escucha en `100.x.y.z` (interfaz `tailscale0`). Bindear a `0.0.0.0` expondría Mosquitto a través de Tailscale automáticamente, lo que (a) no se ha pedido, (b) duplicaría la superficie de ataque sin necesidad, (c) podría confundir a un cliente Tailscale que descubriera un MQTT "público" en su _tailnet_.
- `127.0.0.1` (loopback) tampoco vale: los dispositivos físicos no pueden alcanzar el loopback del host.
- `192.168.1.3` deja a Mosquitto accesible **sólo desde la LAN doméstica** (la subnet del router, p. ej. `192.168.1.0/24`). Coherente con el _alcance LAN + Tailscale_ del homelab.

> **Si la IP de la Pi cambia**: la reserva DHCP de `192.168.1.3` debe ser persistente (ver `docs/03-red/01-macvlan.md`, _IP estática_). Si el router pierde su configuración o se sustituye, hay que renovar la reserva **antes** de levantar el _stack_ (un `docker compose up -d` en una IP no asignada falla con `bind: cannot assign requested address`). Documentado también en `docs/13-operaciones/04-red-y-puertos.md` cuando llegue.

### Autenticación: `allow_anonymous false`, _password file_ + ACL granular

Mosquitto 2.0 introdujo un cambio importante: el _default_ pasó a ser **denegar** todo lo que no esté autenticado. La configuración de fábrica de la imagen oficial 2.0.x trae `allow_anonymous false` y un único _listener_ que sólo escucha en localhost (`127.0.0.1:1883`). Para usar el broker en serio hay que configurar:

1. **`password_file`**: fichero con `username:hash_pbkdf2` o `username:bcrypt` por línea. Generado con `mosquitto_passwd`. Los _hashes_ son los que el broker compara con cada `CONNECT`.
2. **`acl_file`**: ACL granular por usuario o patrón. Cada línea define qué _topics_ puede leer/escribir un usuario o un grupo.

El homelab define **cinco usuarios** con propósitos disjuntos:

| Usuario          | Para qué                                                                                          | Permisos en la ACL                                                                      |
|------------------|---------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|
| `homeassistant`  | Integración MQTT de HA. Necesita _publish_ y _subscribe_ a casi cualquier topic para descubrir entidades por _MQTT discovery_, leer estados de dispositivos y enviar comandos. | `readwrite #` con `deny zigbee2mqtt/bridge/#` (Z2M es quien manda en su bridge config). |
| `zigbee2mqtt`    | Z2M (cuando llegue, `docs/08-domotica/03-zigbee2mqtt.md`). Publica eventos de dispositivos Zigbee y configura su bridge. | `readwrite zigbee2mqtt/#`, `readwrite homeassistant/#` (para MQTT discovery hacia HA).   |
| `nodered`        | Node-RED (cuando llegue, `docs/08-domotica/04-node-red.md`). Flujos visuales que reaccionan a eventos. | `readwrite #` (Node-RED actúa como _automatización transversal_; restringir aquí complicaría flujos). |
| `iot`            | Dispositivos físicos de la LAN: ESPHome, Tasmota, sensores caseros. Topics convencionales `tele/#`, `cmnd/#`, `stat/#` (Tasmota), `<device>/state` (ESPHome), `homeassistant/#` (autodiscovery). | `readwrite tele/#`, `readwrite cmnd/#`, `readwrite stat/#`, `readwrite homeassistant/+/+/config`, `readwrite <prefijos del homelab>/#`. |
| `monitor`        | Uptime Kuma, scripts de diagnóstico, posibles _exporters_ Prometheus en el futuro. Sólo necesita confirmar que el broker responde. | `read $SYS/#` (estadísticas internas del broker). Nada de _publish_, nada de topics de aplicación. |

> **Por qué no un único `homelab` user con todos los permisos**: en cuanto Z2M, Node-RED y dispositivos IoT comparten credenciales, un dispositivo comprometido (un ESP32 robado de la cocina) puede _publish_ en `zigbee2mqtt/bridge/config` y reconfigurar la red Zigbee entera. La separación por usuario es **profundidad operativa**: el _blast radius_ de cada credencial filtrada se reduce al subconjunto de _topics_ de su rol.

> **Por qué no usar Authelia para autenticación de Mosquitto**: Authelia es OIDC/SAML/`forward_auth` HTTP. MQTT no es HTTP. No hay puente trivial. Mosquitto soporta _auth plugins_ (`mosquitto-auth-plug`, JWT…) pero ninguno se integra con OIDC sin construir un servicio puente extra. El _password file_ + ACL es la solución idiomática y suficiente para un homelab.

#### `bcrypt` vs `pbkdf2`

`mosquitto_passwd` ofrece dos algoritmos: el _legacy_ basado en SHA-512 + sal (`-H sha512`) y el moderno `pbkdf2` (default desde 2.0.x). **Se usa el default `pbkdf2`** — es seguro, multi-iteración por defecto, recomendado por el upstream. No hay valor en pinear el algoritmo en el comando.

### Persistencia y _retained messages_

Mosquitto serializa el estado del broker (suscripciones, _retained messages_, _in-flight messages_) a `mosquitto.db` cada `autosave_interval` (default: 1800 s = 30 min) y, por supuesto, en cada `SIGTERM` limpio (parada con `docker stop`).

```conf
persistence true
persistence_location /mosquitto/data/
persistence_file mosquitto.db
autosave_interval 1800
```

`autosave_interval` se mantiene en el default. Reducirlo a 60 s aumenta IOPS al USB sin beneficio sensible (los _retained_ son rebuildables al siguiente ciclo de publicación de cada cliente). Subirlo a 7200 s reduce IOPS pero arriesga perder _retained_ generados entre el último autosave y un corte de luz; como hd2t está en USB y el corte de luz no es escenario de operación normal, el default es razonable.

#### Tamaño esperado del `mosquitto.db`

Para un homelab con ~50 dispositivos Zigbee + ~10 dispositivos ESPHome + un puñado de _retained_ de configuración: 1–10 MB. Mosquitto compacta el `mosquitto.db` en cada autosave, no crece monotónicamente. Si llegase a >100 MB, casi seguro hay un cliente publicando _retained_ a un _topic_ con _payload_ enorme (p.ej. una imagen Base64); auditarlo con `mosquitto_sub -t '#' -v -R` (sólo retained, ver **Troubleshooting**).

### Logs

`mosquitto.conf` configura dos destinos de log:

```conf
log_dest stdout
log_dest file /mosquitto/log/mosquitto.log
log_type error
log_type warning
log_type notice
log_type information
```

- **`stdout`** asegura que `docker logs mosquitto` y Dozzle (`docs/05-monitorizacion/06-dozzle.md`) ven las trazas. Coherente con la nota explícita de aquel doc: _"Mosquitto sin `log_dest stdout` escribe sólo a fichero"_, que es un anti-patrón en este homelab.
- **`file /mosquitto/log/mosquitto.log`** se mantiene además, por si en el futuro un _jail_ de Fail2ban (deferido — ver más abajo) necesita un fichero estable que rotar.
- `log_type connection` (verbose, una línea por _connect/disconnect_) está intencionadamente **fuera**: en una casa con dispositivos IoT _flaky_ que se reconectan cada minuto, generaría centenas de líneas/h sin valor diagnóstico. Si en alguna sesión de _troubleshooting_ se necesita, se descomenta puntualmente.

### Listener WebSocket (`9001`) — **deshabilitado**

`mosquitto.conf` deja el bloque del _listener_ WebSocket **comentado**:

```conf
# Listener WebSocket — descomentar si en el futuro se despliega un cliente
# MQTT browser-based (p. ej. un dashboard MQTT.fx Web, hivemq-mqtt-client en
# una página estática). Hoy no hace falta: HA, Z2M y Node-RED hablan TCP MQTT.
# listener 9001 0.0.0.0
# protocol websockets
```

Razones:

- **No hay cliente que lo use**. La UI de Z2M, la UI de Node-RED y la UI de HA hablan a sus respectivos contenedores por HTTP, no a Mosquitto por WS. La integración MQTT de HA usa TCP plano `:1883`.
- **Cada _listener_ extra es superficie de ataque adicional**. Mantener uno solo (`:1883`) simplifica la auditoría y el diagnóstico.
- **Si alguna vez se necesita** (un dashboard MQTT browser-based, un visualizador en tiempo real con _retained_), se descomenta el bloque y se publica `:9001` también en `192.168.1.3` con el mismo _password file_ y ACL.

### TLS sobre MQTT (puerto `8883`) — **diferido**

No se habilita TLS en este documento. La razón es operativa:

- Activar `8883` con `cafile`, `certfile`, `keyfile` requiere distribuir el _root cert_ de la CA local (`/mnt/hd2t/services/caddy/data/caddy/pki/authorities/local/root.crt`) a **cada microcontrolador**. ESP32/ESP8266 con _Tasmota_ admiten certs de servidor pinneados pero el flasheo y la rotación se vuelven costosos.
- En la LAN doméstica (no internet), el _trade-off_ entre confidencialidad y operabilidad se inclina razonablemente al lado de operabilidad. Las contraseñas viajan en plano por la LAN — un atacante en la LAN ya está en una posición demasiado privilegiada como para que MQTT en plano sea su mayor problema.
- Si en el futuro se decide cifrar MQTT, se documenta en una ampliación (`docs/08-domotica/05-mosquitto-tls.md` u homólogo) con: emisión de cert servidor por la CA local, distribución del root a clientes, segundo _listener_ `8883` y `require_certificate false` (auth sigue por usuario/password, TLS sólo cifra).

### Fail2ban para Mosquitto — **diferido**

Mosquitto sí escribe a `/mosquitto/log/mosquitto.log` líneas tipo `Bad username or password from 192.168.1.42` cuando un cliente falla la autenticación. Sería técnicamente posible añadir un _jail_ al `fail2ban` contenerizado del _stack_ `seguridad` (`docs/04-seguridad/02-fail2ban.md`) que vigilara ese fichero y baneara IPs.

**No se hace en este documento**, por ahora:

- En una LAN doméstica, las IPs problemáticas son las **propias** del operador (un ESP32 mal configurado que reintenta con la contraseña vieja en bucle). _Banear_ esa IP arrastra al dispositivo legítimo a un `nft drop` y crea más confusión que valor.
- El propio Mosquitto introduce un _back-off_ creciente (`reconnect_delay`) con clientes que fallan repetidamente — el _DoS_ por _credential stuffing_ desde la LAN es prácticamente inexistente.
- Si en el futuro se demuestra necesidad (varios dispositivos comprometidos en la LAN intentando _credential stuffing_), añadir el _jail_ es trivial: un `[mosquitto]` en `~/homelab/seguridad/fail2ban/jail.local` con `failregex = .*Bad username or password from <HOST>` y un `enabled = true`. Queda anotado aquí.

---

## Almacenamiento

| Ruta en el host                                               | Contenido                                                              | Versionable          | Backup                              |
|---------------------------------------------------------------|-------------------------------------------------------------------------|----------------------|-------------------------------------|
| `~/homelab/domotica/docker-compose.yml`                       | Definición del _stack_ (modificada en este doc)                        | git                  | git                                 |
| `~/homelab/domotica/.env`                                     | Variables del _stack_                                                  | **NO** (`.gitignore`) | git aparte (nota local)             |
| `~/homelab/domotica/.env.example`                             | Plantilla con nombres de variables                                     | git                  | git                                 |
| `~/homelab/domotica/mosquitto/mosquitto.conf`                 | Configuración principal del broker                                     | git                  | git                                 |
| `~/homelab/domotica/mosquitto/acl`                            | ACL por usuario (no contiene hashes)                                   | git                  | git                                 |
| `/mnt/hd2t/services/mosquitto/config/passwd`                  | _Password file_ con _hashes_ pbkdf2 (sensible, **no** versionar)        | **NO**               | **Sí** (Borgmatic — fichero crítico) |
| `/mnt/hd2t/services/mosquitto/data/mosquitto.db`              | BD de _retained messages_, suscripciones persistentes                   | **NO**               | _Opcional_ (rebuildable; ver **Backup**) |
| `/mnt/hd2t/services/mosquitto/log/mosquitto.log`              | Log activo del broker                                                   | **NO**               | **NO** — excluido por `exclude_patterns` |

> **`passwd` con permisos `0640` y _ownership_ `1883:1883`**: contiene los _hashes_ de los cinco usuarios. Si un atacante consigue el fichero, puede intentar _offline cracking_; pbkdf2 con muchas iteraciones lo hace caro pero no imposible. Tras el primer arranque:
>
> ```bash
> sudo chown 1883:1883 /mnt/hd2t/services/mosquitto/config/passwd
> sudo chmod 0640 /mnt/hd2t/services/mosquitto/config/passwd
> ```

> **`acl` con permisos `0644`**: no contiene secretos (sólo nombres de usuarios y _topics_); puede ir en git sin problemas. El _hardening_ "es público pero sólo el operador lo edita" se cubre con `0644`.

> **`mosquitto.log` excluido**: ya está cubierto por `exclude_patterns: '*/log/*'` global de Borgmatic (ver `docs/07-backups/02-borgmatic.md`). Si no estuviera, añadir aquí `**/mosquitto.log*`.

---

## Estructura del _stack_ `domotica` tras este documento

```
~/homelab/domotica/
├── docker-compose.yml          # ← modificado (se añade el servicio mosquitto y la red domotica-internal)
├── .env                        # ← modificado (se añade MOSQUITTO_IMAGE_TAG y subnet)
├── .env.example                # ← modificado (idem)
├── .gitignore                  # sin cambios
└── mosquitto/                  # ← nuevo
    ├── mosquitto.conf          # versionado
    └── acl                     # versionado
```

Y en los discos externos, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/mosquitto/
├── config/
│   └── passwd                  # generado en este doc, NO versionado
├── data/
│   └── mosquitto.db            # creado por el broker en runtime
└── log/
    └── mosquitto.log           # creado por el broker en runtime
```

Aplicar el _ownership_ que faltaba:

```bash
sudo chown -R 1883:1883 /mnt/hd2t/services/mosquitto
sudo chmod 0750 /mnt/hd2t/services/mosquitto
sudo chmod 0750 /mnt/hd2t/services/mosquitto/{config,data,log}
```

> **Por qué `1883:1883`**: la imagen oficial `eclipse-mosquitto:2.0.x` corre el proceso `mosquitto` como UID/GID `1883`. Si el árbol está como `root:root`, el broker arranca pero falla al escribir `mosquitto.db` (`Error: Unable to open data file ... Permission denied`). La tabla de UIDs internos de `docs/01-sistema/04-estructura-directorios.md` ya lo anotaba.

Crear el subdirectorio versionado del _stack_:

```bash
mkdir -p ~/homelab/domotica/mosquitto
chmod 0750 ~/homelab/domotica/mosquitto
```

---

## Variables de entorno

Añadir a `~/homelab/domotica/.env.example` (versionado, sin valores reales):

```bash
# --- Imágenes pinneadas (continúa de docs/08-domotica/01-home-assistant.md) ---
HA_IMAGE_TAG=2026.4
MOSQUITTO_IMAGE_TAG=2.0.20

# --- Mosquitto -------------------------------------------------------------
# IP del propio host en la LAN — donde Mosquitto bindea su :1883.
# Coincide con HOMELAB_PI_IPV4 del .env global; redeclarada aquí para que
# 'docker compose config' no falle si el .env global no se importa.
HOMELAB_PI_IPV4=192.168.1.3

# --- Red privada del stack ---------------------------------------------------
# Subnet de 'domotica-internal' (creada en este documento, primera ocupación
# por mosquitto; siguiente fase la rellenan z2m y node-red).
DOMOTICA_INTERNAL_SUBNET=172.20.20.0/24
```

Copiar a `~/homelab/domotica/.env` el bloque correspondiente y mantener los valores reales (en este caso no hay secretos en `.env` — los del broker viven en el `passwd` aparte):

```bash
# Editar el .env existente y añadir las nuevas variables
$EDITOR ~/homelab/domotica/.env
chmod 0600 ~/homelab/domotica/.env
```

> **`.env` aquí sigue sin secretos**: la convención del homelab pide guardar contraseñas en `.env` cuando los servicios las lean por env var, pero Mosquitto **no** lee credenciales por env (las lee del `password_file`). El `.env` queda limpio.

---

## `~/homelab/domotica/mosquitto/mosquitto.conf`

```conf
# =============================================================================
# Mosquitto — broker MQTT del homelab
# Documentación: docs/08-domotica/02-mosquitto.md
#
# Sintaxis: https://mosquitto.org/man/mosquitto-conf-5.html
# =============================================================================

# -----------------------------------------------------------------------------
# Persistencia — mosquitto.db con retained messages y suscripciones offline
# -----------------------------------------------------------------------------
persistence true
persistence_location /mosquitto/data/
persistence_file mosquitto.db
autosave_interval 1800

# -----------------------------------------------------------------------------
# Logging — duplicado a stdout (Dozzle) y a fichero (rotable, fail2ban-ready)
# -----------------------------------------------------------------------------
log_dest stdout
log_dest file /mosquitto/log/mosquitto.log
log_type error
log_type warning
log_type notice
log_type information
# log_type connection   # descomentar puntualmente para troubleshooting verbose
log_timestamp true
log_timestamp_format %Y-%m-%dT%H:%M:%S

# -----------------------------------------------------------------------------
# Autenticación — todo cliente debe presentar credenciales válidas
# -----------------------------------------------------------------------------
allow_anonymous false
password_file /mosquitto/config/passwd
acl_file /mosquitto/config/acl

# -----------------------------------------------------------------------------
# Listener principal — TCP MQTT 3.1.1 / 5.0
# El bind '0.0.0.0' es _dentro del contenedor_; la exposición al host la
# limita el bloque ports: del docker-compose.yml a 192.168.1.3:1883.
# -----------------------------------------------------------------------------
listener 1883 0.0.0.0
protocol mqtt

# -----------------------------------------------------------------------------
# Listener WebSocket — deshabilitado por defecto (ningún cliente lo usa hoy)
# -----------------------------------------------------------------------------
# listener 9001 0.0.0.0
# protocol websockets

# -----------------------------------------------------------------------------
# Listener TLS — deferido (ver docs/08-domotica/02-mosquitto.md, sección TLS)
# -----------------------------------------------------------------------------
# listener 8883 0.0.0.0
# protocol mqtt
# cafile   /mosquitto/config/certs/ca.crt
# certfile /mosquitto/config/certs/server.crt
# keyfile  /mosquitto/config/certs/server.key

# -----------------------------------------------------------------------------
# Limites — defensivos sin estrangular el uso normal
# -----------------------------------------------------------------------------
# Tamaño máximo de payload por mensaje. El default de mosquitto es 0 (ilimitado).
# 1 MiB es generoso para sensores y comandos típicos; si alguien necesita más,
# que lo justifique editando este valor.
message_size_limit 1048576

# Mensajes encolados máximos por cliente desconectado (QoS > 0).
# 1000 es el default; bajado a 500 para evitar acumulación si un cliente
# offline pasa días desconectado y otro publica en bucle.
max_queued_messages 500

# -----------------------------------------------------------------------------
# Comportamiento de reconexión / sesiones persistentes
# -----------------------------------------------------------------------------
# Mantener sesiones persistentes (clean_session=false) en disco durante
# 14 días tras desconexión. Pasado ese plazo, descartar suscripciones.
persistent_client_expiration 14d
```

> **Por qué no usar el _include_ `include_dir`**: para Mosquitto, el `mosquitto.conf` cabe entero en una pestaña. Particionar en `conf.d/*.conf` añadiría ceremonia sin valor. Si el día de mañana se introducen _bridges_ MQTT (federación con otro broker), un fichero aparte podría tener sentido — se reevalúa entonces.

---

## `~/homelab/domotica/mosquitto/acl`

```conf
# =============================================================================
# Mosquitto ACL — permisos por usuario
# Sintaxis: https://mosquitto.org/man/mosquitto-conf-5.html
#  - Cada bloque comienza con 'user <nombre>' y aplica hasta el siguiente 'user'
#    o final de fichero.
#  - 'topic [read|write|readwrite] <pattern>' permite o restringe topics.
#  - Patrones: '+' = un nivel, '#' = todos los niveles desde aquí.
# =============================================================================

# -----------------------------------------------------------------------------
# homeassistant — la integración MQTT de HA. Acceso amplio para autodiscovery,
# leer estados y mandar comandos. Excluye explícitamente la rama de
# configuración de Z2M (zigbee2mqtt es quien manda allí).
# -----------------------------------------------------------------------------
user homeassistant
topic readwrite #
topic deny zigbee2mqtt/bridge/#

# -----------------------------------------------------------------------------
# zigbee2mqtt — el bridge Zigbee->MQTT publica eventos de dispositivos a
# zigbee2mqtt/<device>/... y publica autodescubrimiento a homeassistant/...
# -----------------------------------------------------------------------------
user zigbee2mqtt
topic readwrite zigbee2mqtt/#
topic readwrite homeassistant/#

# -----------------------------------------------------------------------------
# nodered — Node-RED corre flujos transversales que típicamente leen y
# publican en muchos topics. No se restringe agresivamente para no romper
# flujos legítimos; el principio de menor privilegio cede a pragmatismo.
# Si un flujo concreto necesita aislamiento, se le da su propio usuario.
# -----------------------------------------------------------------------------
user nodered
topic readwrite #

# -----------------------------------------------------------------------------
# iot — dispositivos físicos de la LAN (ESPHome, Tasmota, sensores caseros).
# Topics convencionales:
#  - tele/<device>/...   (Tasmota: telemetría periódica)
#  - cmnd/<device>/...   (Tasmota: comandos)
#  - stat/<device>/...   (Tasmota: estado tras comando)
#  - homeassistant/<componente>/<device>/config  (autodiscovery)
#  - homelab/<area>/<sensor>/...  (convención propia para sensores caseros)
# -----------------------------------------------------------------------------
user iot
topic readwrite tele/#
topic readwrite cmnd/#
topic readwrite stat/#
topic readwrite homeassistant/+/+/config
topic readwrite homeassistant/+/+/+/config
topic readwrite homelab/#

# -----------------------------------------------------------------------------
# monitor — Uptime Kuma, exporters, scripts de diagnóstico. Sólo lectura, y
# sólo de la rama interna del propio broker.
# -----------------------------------------------------------------------------
user monitor
topic read $SYS/#
```

> **Sobre `homeassistant/+/+/config` y `homeassistant/+/+/+/config`** en `iot`: el _autodiscovery_ de HA aceptan _topics_ con 3 o 4 niveles bajo `homeassistant/` según el componente (`sensor`, `switch`, `light`, …). Las dos líneas cubren los casos comunes sin abrir todo `homeassistant/#` (que daría a un dispositivo IoT permiso para registrar sensores fantasma o borrarlos).

> **Sobre la prelación `readwrite` antes que `deny`**: `mosquitto` aplica las reglas en orden y `deny` _se impone_ sobre un `readwrite` previo dentro del mismo bloque `user`. Así, en el bloque `homeassistant`, el `topic deny zigbee2mqtt/bridge/#` _excluye_ específicamente esa rama del `topic readwrite #` general.

---

## Generación del `password_file`

El _bootstrap_ se hace **dentro del propio contenedor Mosquitto**, ejecutándolo con un comando _one-shot_ en lugar del _entrypoint_ por defecto. Esto evita instalar `mosquitto-passwd` en el host.

### 1. Decidir y guardar las contraseñas

Generar cinco contraseñas robustas (mínimo 24 caracteres, alfanuméricos + símbolos seguros para shell) y **guardarlas inmediatamente en un gestor de contraseñas** (Vaultwarden si ya está desplegado en `docs/11-productividad/01-vaultwarden.md`; si no, en KeePassXC local hasta que llegue Vaultwarden):

```bash
for u in homeassistant zigbee2mqtt nodered iot monitor; do
  pw=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
  echo "$u:$pw"
done
```

Salida (ejemplo, **no copiar**):

```
homeassistant:Kj9...
zigbee2mqtt:8wQ...
nodered:Hb3...
iot:Lp7...
monitor:Vr5...
```

Cada par `usuario:contraseña` va a Vaultwarden / KeePassXC con el _vault entry_ "homelab — mosquitto — <usuario>".

> **No persistir las contraseñas en plano en ningún fichero del repo**. Las que llegan al `passwd` del broker están **hasheadas** (pbkdf2). Las que reusan los clientes (HA, Z2M, ESP32) viven en el _vault_ y, en cada caso, en la configuración del propio cliente: el `secrets.yaml` de HA, el `configuration.yaml` de Z2M, el `secrets.yaml` de ESPHome.

### 2. Crear el fichero `passwd`

Tocar el fichero vacío y aplicar permisos antes de poblarlo:

```bash
sudo touch /mnt/hd2t/services/mosquitto/config/passwd
sudo chown 1883:1883 /mnt/hd2t/services/mosquitto/config/passwd
sudo chmod 0640 /mnt/hd2t/services/mosquitto/config/passwd
```

Para **cada** usuario, ejecutar `mosquitto_passwd` dentro de un contenedor _ad-hoc_:

```bash
# Repetir por cada usuario, sustituyendo USUARIO y PASSWORD.
# La contraseña se pasa por -p (peor) o se introduce interactiva (mejor).
# Aquí se usa -b (batch) por scriptability — cuidar el historial de la shell.
sudo docker run --rm -i \
  -v /mnt/hd2t/services/mosquitto/config:/mosquitto/config \
  --user 1883:1883 \
  eclipse-mosquitto:2.0.20 \
  mosquitto_passwd -b /mosquitto/config/passwd USUARIO PASSWORD
```

> **`--user 1883:1883`** garantiza que el fichero `passwd` queda con _ownership_ correcto desde la primera escritura. Sin esa flag, Docker corre el _exec_ como `root` por defecto y deja el fichero `root:root`, lo que el broker en producción no podría escribir si quisiera (no necesita; pero coherente).

> **El historial de la shell**: `history` registra el comando con la contraseña. Mitigar:
>
> ```bash
> HISTCONTROL=ignorespace
> # nota el espacio inicial — bash no registra esa línea:
>   sudo docker run --rm -i ...  mosquitto_passwd -b /mosquitto/config/passwd USUARIO PASSWORD
> ```
>
> O, mejor, usar `-c` (crear) la primera vez sin `-b`, sin la contraseña en el _command line_ — `mosquitto_passwd` la pide por TTY interactivamente:
>
> ```bash
> sudo docker run --rm -it \
>   -v /mnt/hd2t/services/mosquitto/config:/mosquitto/config \
>   --user 1883:1883 \
>   eclipse-mosquitto:2.0.20 \
>   mosquitto_passwd -c /mosquitto/config/passwd homeassistant
> Password: ********
> Reenter password: ********
> ```
>
> El primer usuario usa `-c` (create — sobreescribe el fichero con un único usuario). Los siguientes usan **sin `-c`** (append):
>
> ```bash
> sudo docker run --rm -it \
>   -v /mnt/hd2t/services/mosquitto/config:/mosquitto/config \
>   --user 1883:1883 \
>   eclipse-mosquitto:2.0.20 \
>   mosquitto_passwd /mosquitto/config/passwd zigbee2mqtt
> ```
>
> Repetir para `nodered`, `iot`, `monitor`.

### 3. Verificar el fichero

```bash
sudo cat /mnt/hd2t/services/mosquitto/config/passwd
# homeassistant:$7$101$...$...
# zigbee2mqtt:$7$101$...$...
# nodered:$7$101$...$...
# iot:$7$101$...$...
# monitor:$7$101$...$...
```

Cinco líneas, cada una con `usuario:$7$...` (el `$7$` es el prefijo PBKDF2 que `mosquitto_passwd` usa por defecto en 2.0.x).

```bash
sudo ls -la /mnt/hd2t/services/mosquitto/config/passwd
# -rw-r----- 1 1883 1883 ... passwd
```

Permisos `0640`, _ownership_ `1883:1883`. Listo para que el broker lo lea en su próximo arranque.

---

## `~/homelab/domotica/docker-compose.yml` — modificación

El _stack_ ya existe con el servicio `home-assistant` (`docs/08-domotica/01-home-assistant.md`). Este documento añade:

1. La red `domotica-internal` en el bloque `networks:` global.
2. El servicio `mosquitto` en `services:`.
3. La adhesión de `home-assistant` a `domotica-internal` (no estrictamente necesaria — HA puede llegar a Mosquitto vía `homelab` — pero **se omite intencionadamente** para no añadir red al servicio HA y mantener la decisión "HA en `homelab` solamente"; ver **Decisiones de diseño**).

El fichero queda:

```yaml
---
# Stack: domotica — Home Assistant + Mosquitto
# Documentación: docs/08-domotica/01-home-assistant.md (HA)
#                docs/08-domotica/02-mosquitto.md (Mosquitto)
# (Zigbee2MQTT y Node-RED se añaden en docs siguientes.)

services:

  # ---------------------------------------------------------------------------
  # Home Assistant — sin cambios respecto a docs/08-domotica/01-home-assistant.md
  # ---------------------------------------------------------------------------
  home-assistant:
    image: homeassistant/home-assistant:${HA_IMAGE_TAG}
    container_name: home-assistant
    hostname: home-assistant
    restart: unless-stopped
    environment:
      TZ: ${TZ}
    volumes:
      - /mnt/hd2t/services/home-assistant:/config
      - /etc/localtime:/etc/localtime:ro
    networks:
      homelab:
        aliases:
          - home-assistant
    labels:
      homelab.stack: "domotica"
      homelab.backup: "true"
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      test:
        - CMD-SHELL
        - "wget -qO- --tries=1 --timeout=5 http://localhost:8123/manifest.json | grep -q 'Home Assistant' || exit 1"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s
    depends_on:
      mosquitto:
        condition: service_healthy

  # ---------------------------------------------------------------------------
  # Mosquitto — broker MQTT.
  #  - En 'homelab' (cross-stack: Uptime Kuma alcanza 'mosquitto:1883').
  #  - En 'domotica-internal' (stack-internal: Z2M y Node-RED hablarán aquí).
  #  - Publica :1883 SOLO en 192.168.1.3 (LAN doméstica), no en 0.0.0.0.
  # ---------------------------------------------------------------------------
  mosquitto:
    image: eclipse-mosquitto:${MOSQUITTO_IMAGE_TAG}
    container_name: mosquitto
    hostname: mosquitto
    restart: unless-stopped
    user: "1883:1883"
    environment:
      TZ: ${TZ}
    volumes:
      # Configuración versionada — read-only.
      - ./mosquitto/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro
      - ./mosquitto/acl:/mosquitto/config/acl:ro
      # Password file — sensible, vive en hd2t, read-only para el contenedor.
      - /mnt/hd2t/services/mosquitto/config/passwd:/mosquitto/config/passwd:ro
      # Persistencia (mosquitto.db) y logs — read-write.
      - /mnt/hd2t/services/mosquitto/data:/mosquitto/data
      - /mnt/hd2t/services/mosquitto/log:/mosquitto/log
    networks:
      homelab:
        aliases:
          - mosquitto
      domotica-internal:
        aliases:
          - mosquitto
    ports:
      # Publicado SOLO en la IP de la LAN — Tailscale (100.x) NO lo verá.
      - "${HOMELAB_PI_IPV4}:1883:1883/tcp"
    labels:
      homelab.stack: "domotica"
      homelab.backup: "true"
      # Opt-out: bumps manuales con changelog (ver docs/02-docker/04-watchtower.md).
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      # nc -z probe del listener TCP. Si Mosquitto está arrancando, el puerto
      # tarda <1 s en abrir; el healthcheck pasa cuando el broker está listo
      # para aceptar CONNECT.
      test: ["CMD-SHELL", "nc -z 127.0.0.1 1883 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

# ---------------------------------------------------------------------------
# Redes
# ---------------------------------------------------------------------------
networks:
  homelab:
    external: true              # creada en docs/02-docker/02-estructura-compose.md
  domotica-internal:
    name: domotica-internal
    driver: bridge
    internal: true              # sin acceso a internet desde dentro
    ipam:
      config:
        - subnet: ${DOMOTICA_INTERNAL_SUBNET}
```

Notas de diseño:

- **`home-assistant.depends_on.mosquitto: service_healthy`**: HA arranca **después** de que Mosquitto esté `(healthy)`. Sin este `depends_on`, la integración MQTT de HA reintentaría conexión durante decenas de segundos al primer arranque del _stack_ y dejaría _warnings_ ruidosos en el log. El `depends_on` no aporta nada en arranques calientes (donde ambos contenedores están corriendo).
- **`internal: true`** en `domotica-internal`: la red **no enruta** al exterior, ni a internet ni a otras redes Docker que no estén explícitamente conectadas a contenedores en ella. Mosquitto está además en `homelab`, así que sí tiene salida — pero los servicios que vivan **sólo** en `domotica-internal` (Z2M, Node-RED en sus docs futuros) no podrán hacer `apt update` ni descargar plugins desde dentro. El _bootstrap_ y los _bumps_ los hace el host por `docker compose pull`. _Hardening_ por defecto.
- **`ipam.config[0].subnet`**: subnet privada explícita `172.20.20.0/24`. Distinta de la `172.20.10.0/24` de `homelab`. Por convención del homelab, las subnets privadas de _stack_ se asignan en `172.20.<10*N>.0/24` con `N=1` para `homelab`, `N=2` para `domotica-internal`, etc. Si Docker asignase una subnet automáticamente, sería en el rango `172.17.0.0/16+`, perfectamente válido pero menos previsible para troubleshooting (`docker network inspect`).
- **`user: "1883:1883"`**: redundante con la imagen oficial (que ya pone el _entrypoint_ con ese usuario), pero explícito en el compose para que un futuro fork de la imagen no rompa el invariante de _ownership_.
- **`ports: "${HOMELAB_PI_IPV4}:1883:1883/tcp"`**: bind explícito a la IP de la Pi (no `0.0.0.0`). Si la variable no está definida, el `docker compose config` falla — el operador lo nota antes de levantar.

---

## Despliegue

### Validar la sintaxis

```bash
cd ~/homelab/domotica
docker compose --env-file ../.env --env-file .env config | head -80
```

Buscar específicamente:

```bash
docker compose --env-file ../.env --env-file .env config | grep -E 'mosquitto|domotica-internal|192\.168\.1\.3:1883'
```

Salida esperada incluye:

```
    image: eclipse-mosquitto:2.0.20
      domotica-internal:
      - "192.168.1.3:1883:1883/tcp"
    name: domotica-internal
    internal: true
```

### Levantar el _stack_

```bash
cd ~/homelab
make up STACK=domotica
```

O equivalente:

```bash
cd ~/homelab/domotica
docker compose --env-file ../.env --env-file .env up -d
```

Esperar al `(healthy)`:

```bash
docker compose -f ~/homelab/domotica/docker-compose.yml ps
# NAME              IMAGE                              STATUS
# home-assistant    homeassistant/home-assistant:...   Up X seconds (healthy)
# mosquitto         eclipse-mosquitto:2.0.20           Up X seconds (healthy)
```

Si `mosquitto` se queda en `starting` más de 30 s, ir a **Troubleshooting** → primer arranque.

### Verificar logs del primer arranque

```bash
docker logs mosquitto --tail 30
```

Salida esperada:

```
... mosquitto version 2.0.20 starting
... Config loaded from /mosquitto/config/mosquitto.conf.
... Loading plugin: file://...
... Opening ipv4 listen socket on port 1883.
... Opening ipv6 listen socket on port 1883.
... mosquitto version 2.0.20 running
```

Lo que **no** debe aparecer:

- `Error: Unable to open password file` → permisos del `passwd` mal o ruta dentro del contenedor incorrecta.
- `Error: Unable to open acl file` → idem `acl`.
- `Warning: Mosquitto should not be run as root` → falta `user: "1883:1883"` en el compose.
- `Warning: Listener on port 1883 is configured with allow_anonymous and no authentication.` → falta `password_file` o `allow_anonymous true` colado por error.

---

## Verificación funcional desde la LAN

Con `mosquitto-clients` instalado en el host (`sudo apt install mosquitto-clients`):

### Suscribirse a `$SYS/#` con el usuario `monitor`

En una terminal:

```bash
mosquitto_sub -h 192.168.1.3 -p 1883 \
  -u monitor -P "<password de monitor>" \
  -t '$SYS/#' -v
```

A los pocos segundos empiezan a llegar mensajes:

```
$SYS/broker/version mosquitto version 2.0.20
$SYS/broker/uptime 14 seconds
$SYS/broker/clients/connected 1
$SYS/broker/messages/sent 17
...
```

`Ctrl+C` para terminar.

### Publicar y suscribir con `homeassistant`

En una terminal, suscriptor:

```bash
mosquitto_sub -h 192.168.1.3 -p 1883 \
  -u homeassistant -P "<password de homeassistant>" \
  -t 'homelab/test/#' -v
```

En otra terminal, publicador:

```bash
mosquitto_pub -h 192.168.1.3 -p 1883 \
  -u homeassistant -P "<password de homeassistant>" \
  -t 'homelab/test/hello' -m 'world'
```

El suscriptor imprime:

```
homelab/test/hello world
```

### Verificar que las ACL **deniegan** correctamente

`monitor` no debe poder publicar. Probar:

```bash
mosquitto_pub -h 192.168.1.3 -p 1883 \
  -u monitor -P "<password de monitor>" \
  -t 'homelab/test/should-fail' -m 'nope' -d
# ...
# Client ... received PUBACK (Mid: 1)   <-- error: Mosquitto NO devuelve un error visible al cliente publisher
```

Mosquitto **no notifica al publicador** que la ACL ha denegado el _publish_ (es una limitación de MQTT 3.1.1; en 5.0 el `PUBACK` puede llevar reason codes pero los clientes simples no los exhiben). La denegación se ve **en el log del broker**:

```bash
docker logs mosquitto --tail 5 | grep -i 'denied'
# ... ACL denying access to topic 'homelab/test/should-fail' for client 'monitor'
```

`monitor` **sí** puede leer `$SYS/#`:

```bash
mosquitto_sub -h 192.168.1.3 -p 1883 \
  -u monitor -P "<password de monitor>" \
  -t '$SYS/broker/version' -C 1
# mosquitto version 2.0.20
```

`monitor` **no** puede leer otros topics:

```bash
mosquitto_sub -h 192.168.1.3 -p 1883 \
  -u monitor -P "<password de monitor>" \
  -t 'homelab/#' -v -C 1 -W 5
# (cuelga 5 s y termina sin recibir nada — la ACL niega la suscripción)
```

Y el log del broker confirma:

```
... Sending CONNACK to monitor (0, 0)
... Denied SUBSCRIBE from monitor on topic 'homelab/#'
```

### Verificar credenciales inválidas

```bash
mosquitto_sub -h 192.168.1.3 -p 1883 \
  -u monitor -P 'wrong-password' \
  -t '$SYS/#' -v -W 5
# Connection error: Connection Refused: not authorised.
```

Y el log:

```bash
docker logs mosquitto --tail 5
# ... Client <unknown> disconnected, not authorised.
# ... Bad username or password from 192.168.1.42 (CONNECT from monitor)
```

> **El log incluye la IP origen** (`192.168.1.42` en el ejemplo). Si en el futuro se decide añadir un _jail_ de Fail2ban, este es el patrón a buscar (`failregex = .*Bad username or password from <HOST>$`).

### Suscripción cross-stack desde Uptime Kuma

Desde dentro de la red `homelab` (otro contenedor) — simulación con `mosquitto_sub` en un contenedor _ad-hoc_:

```bash
docker run --rm -it --network homelab \
  eclipse-mosquitto:2.0.20 \
  mosquitto_sub -h mosquitto -p 1883 \
  -u monitor -P "<password de monitor>" \
  -t '$SYS/broker/version' -C 1
# mosquitto version 2.0.20
```

Resolución por DNS de Docker (`mosquitto`) confirmada. Cuando Uptime Kuma cree el _monitor_ MQTT, usará exactamente esa configuración: host `mosquitto`, puerto `1883`, usuario `monitor`, _topic_ `$SYS/broker/version`.

---

## Integración con Home Assistant

HA está corriendo desde `docs/08-domotica/01-home-assistant.md` pero sin la integración MQTT activa. Configurarla ahora:

### Opción A — desde la UI (recomendada)

1. **Settings → Devices & services → Add Integration → MQTT**.
2. **Broker**: `mosquitto`. (Resolución por DNS de Docker; HA está en `homelab` y el _alias_ `mosquitto` apunta al broker.)
3. **Port**: `1883`.
4. **Username**: `homeassistant`.
5. **Password**: la del _vault_, copiada para esta única introducción.
6. **Advanced options** → **Enable discovery**: marcado (el _autodiscovery_ MQTT de HA escucha `homeassistant/+/+/config` y se autoinscribe entidades que llegan ahí).
7. **Submit**.

HA prueba la conexión. Si todo va bien:

```
✓ Successfully connected to MQTT broker.
```

Y aparece la integración _MQTT_ en _Settings → Devices & services_, con un dispositivo virtual `MQTT` con sensores `Connected`, `Last reconnection time`, etc.

### Opción B — vía YAML

Añadir el secreto al `secrets.yaml`:

```bash
sudoedit /mnt/hd2t/services/home-assistant/secrets.yaml
```

```yaml
mqtt_password: "<password de homeassistant>"
```

Y en `configuration.yaml`:

```yaml
mqtt:
  broker: mosquitto
  port: 1883
  username: homeassistant
  password: !secret mqtt_password
  discovery: true
  discovery_prefix: homeassistant
```

Recargar HA:

```bash
docker compose -f ~/homelab/domotica/docker-compose.yml restart home-assistant
```

> **La opción A queda anclada en `.storage/`** (gestión por la UI), la opción B en YAML. **No mezclar las dos**: si se intenta configurar MQTT desde la UI cuando ya hay un bloque YAML, HA emite un warning y la entrada de la UI no se guarda. Elegir una. La UI es más cómoda; el YAML es más reproducible para _disaster recovery_.

### Verificar la integración

Desde la UI: **Settings → Devices & services → MQTT → Configure → Listen to a topic** → escribir `$SYS/broker/version` → **Start listening**. A los pocos segundos aparece un mensaje con `mosquitto version 2.0.20`.

Desde la API:

```bash
TOKEN=<long-lived token>
curl -k --resolve home-assistant.lan:443:192.168.1.3 \
  -H "Authorization: Bearer $TOKEN" \
  https://home-assistant.lan/api/services/mqtt/publish \
  -X POST -H "Content-Type: application/json" \
  -d '{"topic":"homelab/test/from_ha","payload":"hello from ha"}'
# 200
```

Y en una terminal del host:

```bash
mosquitto_sub -h 192.168.1.3 -p 1883 \
  -u homeassistant -P "<password>" \
  -t 'homelab/test/from_ha' -C 1
# hello from ha
```

---

## Backup

Mosquitto cae principalmente en la **categoría F** (filesystem-only) de `docs/07-backups/03-backup-docker-volumes.md`: la fuente de verdad respaldable es el árbol `/mnt/hd2t/services/mosquitto/`, ya cubierto por el `source_directories: /mnt/hd2t/services` de Borgmatic. **No hace falta acción nueva** para que el `passwd`, el `acl` (en el bind-mount versionable, no en `services/`, pero sí en git) y el `mosquitto.db` entren en el siguiente _archive_.

### Decisión: **no** hacer dump activo de `mosquitto.db`

El bloque comentado que `docs/07-backups/03-backup-docker-volumes.md` dejó preparado en `dump-databases.sh`:

```bash
# --- Mosquitto (filesystem; opcional) — docs/08-domotica/02-mosquitto.md
# /mnt/hd2t/services/mosquitto/{config,data}/ entra como source_directory.
# ...
# docker stop mosquitto && \
#   gzip -c /mnt/hd2t/services/mosquitto/data/mosquitto.db \
#     > "$DUMPS/mosquitto-${DATE}.db.gz" && \
#   chmod 0600 "$DUMPS/mosquitto-${DATE}.db.gz" && \
#   docker start mosquitto
```

**Se mantiene comentado**. Razones:

- **Los _retained messages_ son rebuildables**. El nombre del juego en MQTT: cualquier publicador honesto vuelve a publicar su _retained_ en el siguiente ciclo (Z2M republicará el estado de los dispositivos al reconectar; HA republicará el _autodiscovery_; los dispositivos IoT republicarán su `tele/.../STATE` en el siguiente _heartbeat_). Restaurar `mosquitto.db` desde Borgmatic deja un broker con _retained_ desactualizados que se sobrescriben en minutos.
- **El _cold copy_ requiere `docker stop`**, lo que durante esos segundos de _downtime_ desconecta a HA, Z2M y dispositivos IoT. Para "respaldar" un fichero que se reconstruye automáticamente en minutos, no compensa.
- **Filesystem-only Borgmatic ya copia `mosquitto.db`** en su _archive_ nocturno con el broker corriendo. Si en ese instante el broker está escribiendo (ventana de `autosave_interval`), Borg podría capturar un _snapshot_ ligeramente inconsistente. Restaurarlo es _best-effort_; si Mosquitto se queja al arrancar (`Error reading persistent file`), borrarlo y dejar que se regenere vacío:

  ```bash
  sudo rm /mnt/hd2t/services/mosquitto/data/mosquitto.db
  docker compose -f ~/homelab/domotica/docker-compose.yml restart mosquitto
  ```

  Pérdida: los _retained_ del último _autosave_ (max 30 min). Aceptable.

> **Por qué `passwd` SÍ es crítico** y debe estar en el _archive_: si se pierde, todos los clientes (HA, Z2M, ESP32) se quedan sin poder autenticar y hay que regenerar credenciales _para todos_. El `passwd` está en `/mnt/hd2t/services/mosquitto/config/`, dentro del `source_directories: /mnt/hd2t/services` por inercia. **No** está duplicado en git por seguridad. Si Borgmatic se cae y el `passwd` original se corrompe simultáneamente, el operador regenera el fichero con los pasos de **Generación del `password_file`** (las contraseñas en plano siguen en Vaultwarden / KeePassXC).

### Confirmar que Mosquitto está cubierto por `source_directories`

```bash
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL::$(borg list --short "$BORG_REPO_LOCAL" | tail -1)" \
    | grep mosquitto | head -10
'
# -rw-r-----   1883 1883   ... mnt/hd2t/services/mosquitto/config/passwd
# -rw-------   1883 1883   ... mnt/hd2t/services/mosquitto/data/mosquitto.db
# -rw-r--r--   1883 1883   ... mnt/hd2t/services/mosquitto/log/mosquitto.log
```

(El `mosquitto.log` aparece sólo si no se ha excluido por `*/log/*` global; verificar con el `dry-run` que el _exclude_ está activo.)

### Restauración

Procedimiento estándar (`docs/07-backups/03-backup-docker-volumes.md`, sección _Procedimientos de restauración_), variante _filesystem-only_:

1. `docker compose -f ~/homelab/domotica/docker-compose.yml stop mosquitto`.
2. Mover `/mnt/hd2t/services/mosquitto/` a `mosquitto.broken-<ts>` (preservar 24-48 h).
3. `borg extract` del archive elegido a `/tmp/restore-$$/`, mover en sitio.
4. `sudo chown -R 1883:1883 /mnt/hd2t/services/mosquitto`.
5. `sudo chmod 0640 /mnt/hd2t/services/mosquitto/config/passwd`.
6. `docker compose -f ~/homelab/domotica/docker-compose.yml up -d mosquitto`.
7. Esperar al `(healthy)`. HA y Z2M (cuando exista) reconectan automáticamente y republican sus _retained_.

---

## Verificación

Antes de cerrar este documento:

- [ ] `~/homelab/domotica/docker-compose.yml`, `~/homelab/domotica/.env.example`, `~/homelab/domotica/mosquitto/mosquitto.conf` y `~/homelab/domotica/mosquitto/acl` versionados en git. `~/homelab/domotica/.env` **no** versionado (`.gitignore` activo). El `passwd` **no** versionado y vive en `/mnt/hd2t/services/mosquitto/config/passwd` con `0640 1883:1883`.
- [ ] `docker compose -f ~/homelab/domotica/docker-compose.yml ps` muestra `mosquitto` y `home-assistant` ambos `(healthy)`.
- [ ] `docker logs mosquitto --tail 20` muestra `mosquitto version 2.0.20 running` y **no** muestra `Warning: ... allow_anonymous` ni `Error: ...`.
- [ ] Desde el host: `mosquitto_pub -h 192.168.1.3 -p 1883 -u homeassistant -P <password> -t homelab/verification -m ok` y `mosquitto_sub ... -t homelab/verification -C 1` confirman _publish/subscribe_ end-to-end.
- [ ] Credenciales inválidas son rechazadas: `mosquitto_sub -h 192.168.1.3 -u monitor -P wrong -t '$SYS/#'` falla con `not authorised` y el log del broker registra `Bad username or password`.
- [ ] La ACL deniega correctamente: `mosquitto_pub` con usuario `monitor` a `homelab/test/x` no produce error visible al cliente, pero el log de Mosquitto muestra `ACL denying access ...`.
- [ ] Resolución cross-stack: `docker run --rm --network homelab eclipse-mosquitto:2.0.20 mosquitto_sub -h mosquitto -u monitor -P <password> -t '$SYS/broker/version' -C 1` devuelve `mosquitto version 2.0.20`.
- [ ] Resolución intra-stack: `docker run --rm --network domotica-internal eclipse-mosquitto:2.0.20 mosquitto_sub -h mosquitto -u monitor -P <password> -t '$SYS/broker/version' -C 1` también devuelve la versión.
- [ ] `192.168.1.3:1883` accesible desde la LAN, `0.0.0.0:1883` **no**: `sudo ss -tulpn '( sport = :1883 )'` muestra una sola entrada con `192.168.1.3:1883`.
- [ ] La red `domotica-internal` existe: `docker network inspect domotica-internal --format '{{.Driver}} {{(index .IPAM.Config 0).Subnet}}'` devuelve `bridge 172.20.20.0/24` y la flag `internal: true` está en el JSON completo.
- [ ] La integración MQTT de Home Assistant aparece en _Settings → Devices & services → MQTT_ y el _test_ "Listen to topic `$SYS/broker/version`" recibe `mosquitto version 2.0.20`.
- [ ] Watchtower no toca el contenedor: `docker logs watchtower --tail 100 | grep mosquitto` no muestra "Found new image" para Mosquitto.
- [ ] Tras un `docker compose restart mosquitto`, el broker arranca limpio en <10 s y los clientes (HA al menos) reconectan sin intervención.
- [ ] Borgmatic _dry-run_ incluye `/mnt/hd2t/services/mosquitto/config/passwd` y `/mnt/hd2t/services/mosquitto/data/mosquitto.db` en su lista de ficheros previstos: `sudo /usr/bin/borgmatic --dry-run --verbosity 2 | grep mosquitto`.

---

## Troubleshooting

### Primer arranque: `mosquitto` se queda en `starting` y luego `unhealthy`

```bash
docker logs mosquitto --tail 50
```

Causas comunes:

- **`Error: Unable to open password file '/mosquitto/config/passwd'`** — el bind-mount `/mnt/hd2t/services/mosquitto/config/passwd:/mosquitto/config/passwd:ro` falla porque el fichero **no existe en el host** o tiene permisos que el UID `1883` del contenedor no puede leer. Verificar:

  ```bash
  sudo ls -la /mnt/hd2t/services/mosquitto/config/passwd
  # -rw-r----- 1 1883 1883 ... passwd
  ```

  Si está como `root:root` o con `0600`, cambiar a `1883:1883 0640`.

- **`Error: Unable to open acl file '/mosquitto/config/acl'`** — el bind `~/homelab/domotica/mosquitto/acl:/mosquitto/config/acl:ro` no encuentra el fichero. Comprobar `~/homelab/domotica/mosquitto/acl` existe.

- **`Error: Unable to open log file ... Permission denied`** — `/mnt/hd2t/services/mosquitto/log/` no es escribible por UID `1883`. Aplicar:

  ```bash
  sudo chown -R 1883:1883 /mnt/hd2t/services/mosquitto
  ```

- **`Error: Address already in use`** — algún otro proceso del host (¿un Mosquitto _systemd_ instalado por accidente con `apt install mosquitto`?) está en `:1883`. Comprobar:

  ```bash
  sudo ss -tulpn '( sport = :1883 )'
  systemctl status mosquitto 2>/dev/null
  ```

  Si hay un `mosquitto.service` activo en el host, pararlo: `sudo systemctl disable --now mosquitto`. **No** desinstalar el paquete entero — `mosquitto-clients` (que sí queremos para diagnóstico) es un paquete distinto.

### Cliente recibe `Connection Refused: not authorised`

- **Contraseña incorrecta**: comprobar tipeando exactamente, sin espacios, sin shell-escape (las comillas simples preservan literalidad mejor que las dobles).
- **Usuario no existe en `passwd`**: re-listar con `sudo cat /mnt/hd2t/services/mosquitto/config/passwd | cut -d: -f1`. Si falta uno, regenerarlo con `mosquitto_passwd` (ver **Generación del `password_file`** → 2).
- **`allow_anonymous` mal configurado**: si está en `true` por error, Mosquitto admite a todos sin password — pero entonces los clientes con password fallan en algunas combinaciones. Confirmar que `mosquitto.conf` dice `allow_anonymous false`.

### Mensajes _retained_ no llegan al reconectar un cliente

- **El cliente se conecta con `clean_session=true`** (default en muchos clientes nuevos): MQTT entrega _retained_ sólo si la suscripción es nueva en esta sesión, no si reanuda una sesión limpia. Para HA y Z2M es lo deseable; para algunos clientes ESP, conviene `clean_session=false` para que las suscripciones persistan entre reinicios.
- **El _retained_ no se publicó con `-r`**: re-publicar:

  ```bash
  mosquitto_pub -h 192.168.1.3 -u homeassistant -P <password> \
    -t 'homelab/some/state' -m 'value' -r
  ```

  El flag `-r` es lo que marca el mensaje como _retained_; sin él, sólo lo reciben los suscriptores en línea **en ese momento**.

- **El `mosquitto.db` se borró**: si en algún momento se ejecutó `rm /mnt/hd2t/services/mosquitto/data/mosquitto.db` (por ejemplo en un _troubleshoot_), todos los _retained_ se perdieron. Esperar a que los publicadores los reemitan en su próximo ciclo.

### `mosquitto.db` crece a >100 MB

Identificar topics con _retained_ enormes:

```bash
mosquitto_sub -h 192.168.1.3 -p 1883 \
  -u homeassistant -P <password> \
  -t '#' -v -R -W 5 \
  | awk '{print length($0), $1}' | sort -rn | head -20
```

(`-R` filtra a sólo _retained_, `-W 5` corta tras 5 s de inactividad.) Las primeras líneas son los _topics_ con _payload_ más largo. Si alguno publica imágenes o JSON-blobs gigantes, considerar:

- Pedir al publicador que reduzca el _payload_ (deduplicar, enviar URLs en vez de blobs).
- Borrar el _retained_ con un _publish_ vacío al mismo topic con `-r`:
  ```bash
  mosquitto_pub -h 192.168.1.3 -u homeassistant -P <password> \
    -t 'topic/with/big/retained' -m '' -r -n
  ```

### Uptime Kuma marca el _monitor_ MQTT como _down_ pero `mosquitto_sub` desde el host funciona

- **Uptime Kuma vive en `homelab`, no en `domotica-internal`**. El _monitor_ debe usar `host: mosquitto` (resolución por DNS interno de `homelab`), no `192.168.1.3`. La IP de la LAN del host **no es alcanzable** desde dentro de un contenedor de la red `homelab` en muchos setups (depende del `userland-proxy` de Docker).
- **Credenciales mal copiadas a Uptime Kuma**: re-copiar la contraseña del usuario `monitor` desde Vaultwarden, sin espacios.
- **Topic mal escrito**: `$SYS/broker/version` (con `$SYS` literal), no `\$SYS/broker/version` ni `SYS/broker/version`. Algunas UI escapan el `$` y rompen el topic.

### Z2M / Node-RED no llega a Mosquitto cuando se desplieguen

(Pertinente cuando lleguen sus docs.) Razones probables:

- Los servicios futuros vivirán en `domotica-internal` (no en `homelab`). Asegurar que Mosquitto **sigue** en `domotica-internal` (este doc lo añade y los siguientes no deberían quitarlo).
- ACL: comprobar el log de Mosquitto en busca de `ACL denying access`. Si Z2M intenta publicar a `zigbee2mqtt/...` y el log lo deniega, el `acl` no contiene el bloque correcto para `zigbee2mqtt` (revisar la sección **`~/homelab/domotica/mosquitto/acl`** de este documento).

---

## Actualización

Bumps de _patch_ (`2.0.20 → 2.0.21`):

```bash
# 1. Leer el changelog upstream — entrada del año.mes correspondiente
xdg-open https://mosquitto.org/blog/  # o https://github.com/eclipse/mosquitto/blob/master/ChangeLog.txt

# 2. Actualizar el .env
$EDITOR ~/homelab/domotica/.env
# MOSQUITTO_IMAGE_TAG=2.0.21

# 3. Pull y recreate sin downtime largo
cd ~/homelab
make pull STACK=domotica
make up STACK=domotica
# o, equivalente:
docker compose -f ~/homelab/domotica/docker-compose.yml up -d mosquitto

# 4. Verificar
docker logs mosquitto --tail 10
docker compose -f ~/homelab/domotica/docker-compose.yml ps mosquitto
mosquitto_sub -h 192.168.1.3 -u monitor -P <password> -t '$SYS/broker/version' -C 1
# mosquitto version 2.0.21
```

El recreate dura <5 s. HA y otros clientes reconectan automáticamente (el reintento de la integración MQTT de HA es razonable, ~10 s).

Bumps de _minor_ (`2.0.x → 2.1.y`, cuando exista):

- Leer el _changelog_ buscando _Backward-incompatible changes_.
- Backup explícito previo:
  ```bash
  sudo /usr/bin/borgmatic --verbosity 1
  ```
- Probar primero con `docker compose pull` y `docker compose up -d --no-recreate` para validar que la imagen baja correctamente, y sólo después recrear.
- Tras el upgrade, verificar el `mosquitto.db` — si la versión nueva cambió el formato y la imagen no migra _in-place_, el broker arranca con `Error reading persistent file`; **borrar** y aceptar la pérdida de _retained_ (rebuildables) o restaurar un dump anterior si se hizo.

---

## Referencias

- Documentación oficial — Mosquitto: <https://mosquitto.org/documentation/>
- `mosquitto.conf(5)`: <https://mosquitto.org/man/mosquitto-conf-5.html>
- `mosquitto_passwd(1)`: <https://mosquitto.org/man/mosquitto_passwd-1.html>
- `mosquitto_pub(1)` / `mosquitto_sub(1)`: <https://mosquitto.org/man/mosquitto_pub-1.html>, <https://mosquitto.org/man/mosquitto_sub-1.html>
- Imagen oficial — `eclipse-mosquitto`: <https://hub.docker.com/_/eclipse-mosquitto>
- Migración 1.x → 2.x — _Authentication changes_: <https://mosquitto.org/documentation/migrating-to-2-0/>
- ACL — sintaxis y ejemplos: <https://mosquitto.org/man/mosquitto-conf-5.html#idm155> (sección _Access Control_)
- Especificación MQTT 5.0 (referencia): <https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html>
- Documentos relacionados del homelab:
  - `docs/01-sistema/04-estructura-directorios.md` — UID/GID `1883`, árbol `/mnt/hd2t/services/mosquitto/`.
  - `docs/02-docker/02-estructura-compose.md` — convenciones del _stack_ `domotica`, redes Docker.
  - `docs/02-docker/04-watchtower.md` — Mosquitto en la lista nominal de _opt-out_.
  - `docs/04-seguridad/02-fail2ban.md` — _jail_ Mosquitto deferido (anotado en este doc).
  - `docs/05-monitorizacion/05-uptime-kuma.md` — _monitor_ `tcp://mosquitto:1883`.
  - `docs/05-monitorizacion/06-dozzle.md` — `log_dest stdout` requerido para que Dozzle vea el log.
  - `docs/07-backups/02-borgmatic.md` — `source_directories: /mnt/hd2t/services` cubre Mosquitto.
  - `docs/07-backups/03-backup-docker-volumes.md` — Categoría F + bloque comentado en `dump-databases.sh` (este doc lo deja comentado).
  - `docs/08-domotica/01-home-assistant.md` — _stack_ `domotica` ya creado, integración MQTT en HA pendiente hasta este doc.
  - `docs/08-domotica/03-zigbee2mqtt.md` (siguiente fase) — primer cliente "pesado" del broker.
  - `docs/08-domotica/04-node-red.md` (siguiente fase) — flujos visuales sobre MQTT.
