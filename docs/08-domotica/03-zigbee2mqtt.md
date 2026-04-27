# Zigbee2MQTT (puente Zigbee del stack `domotica`)

## Descripción

Despliegue de **Zigbee2MQTT** (Z2M) como **puente Zigbee ↔ MQTT** del homelab: el servicio que habla por radio con la malla Zigbee 3.0 (sensores, enchufes, bombillas, botones, válvulas térmicas, …), traduce sus mensajes propietarios al formato JSON de MQTT y los publica en el _broker_ Mosquitto bajo `zigbee2mqtt/<device>/...`. Junto con Mosquitto y Home Assistant, Z2M cierra el _data plane_ de la fase 8: los dispositivos Zigbee aparecen en HA como entidades nativas vía **MQTT discovery** (`homeassistant/<componente>/<device>/config`) sin que HA hable Zigbee directamente.

Este documento **se suma al _stack_ `domotica`** que estrenaron `docs/08-domotica/01-home-assistant.md` (servicio `home-assistant`) y `docs/08-domotica/02-mosquitto.md` (servicio `mosquitto` + red `domotica-internal`). Añade un servicio `zigbee2mqtt` al `~/homelab/domotica/docker-compose.yml` ya existente, crea el subdirectorio versionado `~/homelab/domotica/zigbee2mqtt/` con un único fichero (`configuration.yaml.example` — la _plantilla_ versionable, sin secretos) y materializa el árbol persistente en **hd2t** (`/mnt/hd2t/services/zigbee2mqtt/{data,log}/`). Toda la persistencia (`database.db`, `state.json`, `coordinator_backup.json`, `configuration.yaml` real con secretos) vive en hd2t, nunca en la microSD: Z2M reescribe `state.json` y `database.db` en cada cambio de estado de cualquier dispositivo (con 50 sensores eso son cientos de _writes_/h) y mataría el _flash_ a medio plazo.

> **Alcance**: este documento despliega Z2M 1.40 con el _adaptador_ **SONOFF Zigbee 3.0 USB Dongle Plus** (chip CC2652P, recomendado por el upstream de Z2M) conectado por **alargador USB de ≥1 m** a un puerto **USB 2.0** de la Pi (separado de los puertos USB 3.0 para evitar interferencias 2,4 GHz, ver `docs/00-hardware/02-esquema-conexiones.md`). Configura el _frontend_ web en el puerto interno `8080`, expuesto **sólo** vía Caddy (`https://zigbee2mqtt.lan/`), **detrás de Authelia** (`forward_auth`, una sola etiqueta y al cobijo del SSO+2FA del homelab — Z2M no tiene autenticación nativa). Conecta a Mosquitto sobre la red privada `domotica-internal` con el usuario `zigbee2mqtt` (creado en `docs/08-domotica/02-mosquitto.md`) y la ACL `readwrite zigbee2mqtt/#` + `readwrite homeassistant/#` ya en su sitio. Habilita **MQTT discovery** hacia HA. **Permit-join** se mantiene **desactivado por defecto** y sólo se abre desde la UI durante emparejamientos. **No** activa el _network map_ pesado por defecto, **no** activa el `availability` por defecto (se discute en **Decisiones de diseño**), **no** crea un _udev rule_ con _symlink_ `/dev/zigbee` (innecesario con un único adaptador en USB 2.0; se difiere). **No** habilita TLS hacia Mosquitto (`docs/08-domotica/02-mosquitto.md` lo defiere por la misma razón: clientes de la LAN sin coste de distribuir el _root_ CA local). Los emparejamientos concretos quedan como **operación de día a día**, no parte del despliegue.

> **Recordatorio de red**: Z2M **no se publica al host**. Caddy lo alcanza por DNS de Docker (`zigbee2mqtt:8080` en la red `homelab`) y, dentro del propio _stack_, Z2M habla con Mosquitto por DNS de Docker en la red privada (`mosquitto:1883` sobre `domotica-internal`). Pi-hole resuelve `zigbee2mqtt.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf`. El operador entra siempre por `https://zigbee2mqtt.lan/` (LAN) o por el nombre _MagicDNS_ del nodo Tailscale.

---

## Requisitos previos

- `docs/00-hardware/01-material-necesario.md` y `docs/00-hardware/02-esquema-conexiones.md` completados: el **adaptador Zigbee USB** (SONOFF Zigbee 3.0 Dongle Plus o equivalente compatible — ConBee II / SkyConnect aceptables) está físicamente conectado a un puerto **USB 2.0** de la Pi mediante un **alargador USB de ≥1 m**, alejado de los discos en USB 3.0. El dongle es visible para el sistema:

  ```bash
  ls -la /dev/serial/by-id/ | grep -iE 'zigbee|cc2652|sonoff|conbee|skyconnect'
  # lrwxrwxrwx 1 root root 13 ... usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_<serial>-if00-port0 -> ../../ttyUSB0
  ```

  Si no aparece, revisar `dmesg | tail -20` justo tras enchufar el dongle: la línea `cp210x converter now attached to ttyUSB0` (Sonoff Plus E con CP2102N) o `usb-serial: ... attached to ttyUSB0` confirma el enlace. **Anotar el ID `usb-...-if00-port0`** completo: ese _symlink_ persistente se usa en el `docker-compose.yml` en lugar de `/dev/ttyUSB0` para sobrevivir a reordenaciones del kernel (si en el futuro se enchufa un segundo dispositivo USB serie — un módem GSM, un UPS USB —, `/dev/ttyUSB0` puede pasar a `/dev/ttyUSB1` sin avisar).
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/zigbee2mqtt/` ya existe vacío con _ownership_ `root:root 0755`. La tabla de UIDs internos de aquel doc no especificaba el UID interno de Z2M; **este documento fija `1000:1000`** (PUID/PGID globales del homelab) porque la imagen oficial `koenkk/zigbee2mqtt` corre como `node` (UID arbitrario) y respeta `--user` para coincidir con el _ownership_ del bind mount. Se confirma:

  ```bash
  ls -la /mnt/hd2t/services/zigbee2mqtt/
  # drwxr-xr-x  2 root root ... .
  ```

- `docs/02-docker/02-estructura-compose.md` completado: la red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) externa está creada, `~/homelab/.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `HOMELAB_DOMAIN=lan` está rellenado, el _Makefile_ expone `make up STACK=<stack>`.
- `docs/02-docker/04-watchtower.md` completado: Z2M figura en la **lista nominal de servicios opt-out** de aquel doc. Aquí se aplica la etiqueta `com.centurylinklabs.watchtower.enable: "false"`.
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `zigbee2mqtt.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy`, `logging.caddy` y `authelia.caddy` (importable como `import authelia`) existen y la directiva `import /etc/caddy/snippets/*.caddy` está activa.
- `docs/04-seguridad/01-authelia.md` completado: el _snippet_ `authelia.caddy` con `forward_auth authelia:9091 { uri /api/verify?rd=https://auth.lan ... }` está disponible y la regla de `access_control` en Authelia incluye `zigbee2mqtt.lan` en la lista `two_factor` (este doc descomenta esa línea, ver **Configuración de Authelia**). Si Authelia aún no está montado, este doc se puede levantar **sin** `import authelia` (modo grace) y añadirlo cuando Authelia llegue; queda anotado.
- `docs/05-monitorizacion/05-uptime-kuma.md` completado (recomendado): Uptime Kuma vive en la red `homelab`. Tras este documento, se le añade un _monitor_ HTTP a `http://zigbee2mqtt:8080/` con código esperado `401` (la página la sirve Authelia hasta que el usuario autentica) o, mejor, un _monitor_ MQTT a `tcp://mosquitto:1883` filtrando por mensajes en `zigbee2mqtt/bridge/state` (el broker mismo se suscribe al estado del bridge — ver **Verificación**).
- `docs/05-monitorizacion/06-dozzle.md` completado: Dozzle ya muestra los logs de los contenedores en `homelab`. Z2M se suma sin acción extra (basta con `restart` para que Dozzle re-detecte el contenedor — depende de la versión de Dozzle, normalmente lo detecta sin _restart_).
- `docs/07-backups/02-borgmatic.md` completado: `source_directories: /mnt/hd2t/services` ya engloba `zigbee2mqtt/` por inercia. Este doc **no añade un dump activo** (Z2M es Categoría F — _filesystem-only_); el bloque comentado de `docs/07-backups/03-backup-docker-volumes.md` se queda comentado y se respalda como sistema de ficheros en frío vivo (la `database.db` es SQLite-like pero pequeña — pocas centenas de KB — y `state.json` es atómicamente reescrito vía `rename(2)`).
- `docs/08-domotica/01-home-assistant.md` completado: HA está corriendo, `(healthy)`, accesible en `https://home-assistant.lan/`. La integración **MQTT** quedó configurada al final de `02-mosquitto.md`. Tras este documento, los dispositivos Zigbee aparecerán en HA por _autodiscovery_ sin acción adicional.
- `docs/08-domotica/02-mosquitto.md` completado: Mosquitto está `(healthy)`, escucha en `mosquitto:1883` (red `homelab` y `domotica-internal`), el usuario `zigbee2mqtt` existe en el `passwd` con su contraseña en Vaultwarden, la ACL define `readwrite zigbee2mqtt/#` y `readwrite homeassistant/#` para ese usuario.
- Conectividad saliente para descargar la imagen (sólo la primera vez):

  ```bash
  docker pull --platform linux/arm64 koenkk/zigbee2mqtt:1.40.1 >/dev/null && echo OK
  ```

- El usuario operador pertenece al grupo `dialout` (necesario para acceder a `/dev/ttyUSB*` desde el host con `mosquitto_pub` / pruebas). Si no:

  ```bash
  sudo usermod -aG dialout "$USER"
  # Cerrar sesión y volver a entrar para que el grupo aplique.
  ```

  > **Importante**: el contenedor de Z2M **no necesita** que el usuario del host esté en `dialout`; necesita acceso al device node por `devices:` en el compose y, dentro del contenedor, corre como `root` por defecto (la imagen `koenkk/zigbee2mqtt` no respeta `--user` cuando `device:` está montado, ver **Decisiones de diseño**). El requisito `dialout` es para que el operador pueda hacer `cat /dev/ttyUSB0` u otras pruebas de cordura desde el host sin `sudo`.

---

## Decisiones de diseño

### Por qué Zigbee2MQTT (y no ZHA / deCONZ / Tasmota Zigbee Bridge)

Cuatro alternativas razonables para integrar Zigbee con HA y por qué se descartan:

| Candidato                       | Por qué se descarta                                                                                                                                                                                                                                                                                                                              |
|---------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **ZHA** (integración nativa de HA, basada en `zigpy`) | Funciona, _zero-configuración_ (HA habla Zigbee directamente sin _broker_). Pero acopla la _coordinator network_ al ciclo de vida de HA: cada `restart` del contenedor de HA reinicia la red Zigbee → flap de dispositivos. La cobertura de _quirks_ (perfiles raros de fabricante) en `zigpy` va detrás de la de Z2M. La compatibilidad con dongles modernos (Sonoff Plus E, SkyConnect) llegó a Z2M **antes**. Migrar de ZHA a Z2M (o viceversa) es traumático: hay que re-emparejar todo. Si en el futuro se eligiera ZHA, sería necesario rehacer el dispositivo a dispositivo. |
| **deCONZ** (`Phoscon` UI + `dresden-elektronik/deconz-rest-plugin`) | Excelente con dongles **ConBee II** (mismo fabricante). Fuera de eso, soporte irregular. UI `Phoscon` cerrada y poco hackeable, no integra MQTT _discovery_ hacia HA tan bien como Z2M (hay un puente comunitario `deconz-mqtt`, _best-effort_). Adapta peor a otros dongles que no sean ConBee.                                            |
| **Tasmota Zigbee Bridge** (CC2652 con firmware Tasmota) | Existe y funciona — convierte el dongle en un _device_ MQTT autosuficiente (como un enchufe Tasmota). Pero la administración es manual: emparejamientos por comandos MQTT, sin UI web visual. Para un homelab de >10 dispositivos Zigbee, la UI de Z2M es una victoria operativa muy clara.                                                |
| **Z2M con dongle barato sin chip CC2652P** | El _hardware_ chino con CC2531 es barato pero limitado (~20 dispositivos directos, sin _routing_ propio). Sonoff Plus / Plus E con CC2652P/CC2652RB soporta cientos de dispositivos y actúa como _coordinator_ con _firmware_ moderno. Diferencia de precio (~5–10 €) que vale la pena.                                                       |

**Z2M gana por**:

- **Cobertura de dispositivos masiva**: el `zigbee-herdsman-converters` que Z2M usa por debajo tiene >3000 dispositivos en la base, mantenida por una comunidad muy activa. Es el _de facto standard_ del Zigbee abierto.
- **Desacoplamiento de HA**: HA puede reiniciarse, actualizar, _crashear_ — la red Zigbee sigue intacta porque Z2M es un proceso separado que mantiene la _coordinator network_. _Resilience_ por diseño.
- **MQTT como bus**: encaja perfectamente en el _stack_ ya existente con Mosquitto. Otros consumidores (Node-RED, scripts, dashboards externos) pueden suscribirse a los mismos eventos sin tener que pasar por HA.
- **UI pulida** (`zigbee2mqtt-frontend`): mapa de la red, listas de dispositivos, OTA, exposición de _attributes_ avanzados, herramientas de _diagnóstico_ (LQI, contadores). Sin ella, gestionar 50 dispositivos es un dolor.
- **OTA upstream activo**: Z2M propaga _firmware_ OTA del fabricante (Philips Hue, IKEA Tradfri, …) cuando está disponible, desde la propia UI.

### Imagen y _tag_

- **`koenkk/zigbee2mqtt:1.40.1`** — Z2M **1.40.1**, _patch_ estable de la línea 1.40 publicada a finales de 2025. Multi-arch oficial con `linux/arm64`. Pinneada a _tag_ específico siguiendo la convención del homelab (`docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`, _tag_ explícito). Si en el momento del despliegue hay un `1.40.2` u otro _patch_ dentro de la misma línea minor, usar el más reciente: la línea 1.40 mantiene compatibilidad de configuración entre _patches_.
- **Por qué no `:latest`**: lo prohíbe la convención del homelab.
- **Por qué no `:dev`**: la _branch_ de desarrollo de Z2M se mueve con frecuencia y suele introducir cambios de _config schema_ que romperían el `configuration.yaml` sin aviso.
- **Bumps**: Z2M tiene un ciclo de _release_ relativamente rápido (uno menor cada 1–2 meses, _patches_ semanales). Cada bump se hace tras leer el _changelog_ (`https://github.com/Koenkk/zigbee2mqtt/releases`) buscando **Breaking changes**. Los _patches_ (`1.40.1 → 1.40.2`) son normalmente seguros; los _minor_ (`1.40 → 1.41`) requieren atención (ocasionalmente cambian la forma de declarar `availability` o `homeassistant.legacy_*`).

#### Watchtower opt-out

Razones:

- **Migraciones del `database.db`** entre _minor_ versions: ocurre rara vez pero ha pasado (1.32 → 1.33 introdujo cambios en cómo se serializan ciertos _quirks_). Mantener la actualización **manual** garantiza que el operador lea el _changelog_ antes de tocar producción.
- **Coherencia con la lista nominal** de `docs/02-docker/04-watchtower.md` → _Servicios que se mantienen en opt-out_, donde Zigbee2MQTT figura explícitamente.
- **Riesgo de des-emparejamientos masivos** si una migración fuese fallida: aunque Z2M conserva el `coordinator_backup.json` para restaurar la red, una mala actualización podría requerir intervención manual sobre dispositivos físicos (botones de reset Zigbee, escaleras, …). Caro.

Etiquetar el contenedor con `com.centurylinklabs.watchtower.enable: "false"`.

### Modo de red: dos redes (`homelab` + `domotica-internal`)

Z2M se conecta a **dos redes Docker** simultáneamente, igual que Mosquitto:

| Red                | Subnet (declarada) | Quién la usa                                                              | Por qué                                                                                                                  |
|--------------------|--------------------|---------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------|
| `homelab`          | `172.20.10.0/24`   | **Caddy** (cross-stack, alcanza `zigbee2mqtt:8080` para el _frontend_); Uptime Kuma (monitor HTTP)                | Permite a servicios de **otros stacks** alcanzar el _frontend_ web por DNS de Docker (`zigbee2mqtt:8080`).                |
| `domotica-internal` | `172.20.20.0/24`  | Mosquitto + Z2M (intra-stack)                                              | Tráfico MQTT _intra-stack_ aislado: Z2M habla con `mosquitto:1883` por esta red, sin atravesar `homelab`.                |

Mosquitto vive en ambas. Z2M también vive en ambas. Razones:

- **`homelab`**: Caddy (en `homelab`) hace _reverse proxy_ al _frontend_ web de Z2M. Si Z2M sólo viviera en `domotica-internal`, Caddy tendría que unirse a `domotica-internal`, contradiciendo el principio "Caddy sólo en `homelab`".
- **`domotica-internal`**: el tráfico MQTT (Z2M → Mosquitto, miles de mensajes/h) no debe atravesar la red _cross-stack_. Mantenerlo en la red privada del _stack_ es un detalle de _hygiene_, no estrictamente necesario para seguridad (el broker autentica de todas formas), pero ayuda al diagnóstico (`docker network inspect domotica-internal` muestra exactamente quién habla MQTT en este homelab).

> **¿Por qué no hacer que Z2M viva sólo en `domotica-internal`?** Tendría sentido si el _frontend_ web no se quisiera exponer; pero se quiere — es la principal interfaz de operación. Y como Caddy está en `homelab`, Z2M debe acompañarle ahí. Igual que Mosquitto.

> **¿Por qué no que el `mqtt.server` de Z2M apunte a `mosquitto:1883` sobre `homelab`?** Funcionaría idénticamente. Pero la red privada del _stack_ existe precisamente para esto: aislar el tráfico interno del _stack_ del tráfico _cross-stack_. Z2M usa la entrada que tiene en `domotica-internal` por convención, sin coste y con beneficio operativo.

### Acceso al device USB (`/dev/ttyUSB0`) y por qué `devices:` (no `privileged: true`)

El contenedor necesita acceder al dongle USB. Tres aproximaciones posibles:

| Opción                                | Cómo                                                                                | Por qué se descarta                                                                                            |
|---------------------------------------|-------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| **`privileged: true`**                | Da al contenedor acceso a **todos** los devices del host                            | Excesivo. Z2M necesita un único `/dev/ttyUSB0`; conceder acceso a `/dev/sda*` (los discos) y `/dev/mem` es _overkill_ y un riesgo de seguridad innecesario. |
| **`device_cgroup_rules` + bind mount manual** | Permitir el _major_/_minor_ del device por reglas de cgroup y bind-mountear el nodo | Funciona pero es verboso. Cinco líneas en lugar de una.                                                        |
| **`devices: [...]` con _symlink_ persistente** ✅ | `devices: ["/dev/serial/by-id/usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_<serial>-if00-port0:/dev/ttyACM0"]` | Limpio. El _symlink_ `by-id` sobrevive a reordenaciones del kernel; el contenedor ve siempre `/dev/ttyACM0` mapeado al dongle correcto, independientemente de si el host lo expuso como `/dev/ttyUSB0` o `/dev/ttyUSB1`. |

Se elige `devices:` con el _symlink_ `by-id`. **Importante**: dentro del contenedor el device aparece como `/dev/ttyACM0` (el lado derecho del mapping); la `configuration.yaml` de Z2M apunta a `/dev/ttyACM0` y NO a `/dev/ttyUSB0`. La elección de nombre interno es arbitraria; se usa `/dev/ttyACM0` para evidenciar (durante el _troubleshoot_) que el path está virtualizado por Docker — si en el log aparece `/dev/ttyUSB0` en lugar de `/dev/ttyACM0`, el operador sabe que algo se ha desviado del compose.

> **`udev rule` para nombre estable tipo `/dev/zigbee`**: una alternativa popular es escribir `/etc/udev/rules.d/99-zigbee.rules` con `SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", SYMLINK+="zigbee"`. **No se hace en este documento**: el _symlink_ de `/dev/serial/by-id/` ya es persistente y autodocumentado (incluye marca + modelo + serial); añadir un `udev rule` extra para llegar al mismo resultado sería duplicación. Si en el futuro se conectan dos dongles iguales (módulo de _routing_ Zigbee dedicado, p. ej.), entonces sí hace falta `udev` para distinguirlos por número de serie y se documenta aparte.

### Frontend web (`8080`) detrás de Caddy + Authelia

El _frontend_ de Z2M es una SPA (React) sin **autenticación nativa**: cualquiera con acceso al puerto 8080 ve y opera la red Zigbee entera (puede emparejar, des-emparejar, leer estados, mandar comandos a enchufes y bombillas). Hay tres _layers_ defensivos:

1. **No publicar `8080` al host**. El compose **no** lleva `ports:` para `8080`. Sólo Caddy puede llegar (y eso a través de la red `homelab`).
2. **Caddy + `tls internal`** termina TLS con la CA local. El usuario entra siempre por `https://zigbee2mqtt.lan/`, no por `http://192.168.1.3:8080`.
3. **`forward_auth` con Authelia** delante: el usuario debe haber pasado por Authelia (usuario + contraseña + 2FA TOTP) **antes** de que Caddy le deje pasar al _frontend_.

El bloque en el `Caddyfile`:

```caddy
zigbee2mqtt.lan {
    tls internal
    import security-headers
    import logging
    import authelia

    reverse_proxy zigbee2mqtt:8080 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto https
    }
}
```

> **¿Por qué Z2M sí va detrás de Authelia y HA no?** Diferencias:
> - HA tiene **autenticación nativa** robusta (usuarios, 2FA TOTP) y una app móvil que habla por _Long-Lived Tokens_ que un `forward_auth` HTTP rompería. Z2M **no tiene autenticación**: cualquier capa adelante es bienvenida.
> - HA es de **uso diario** (UI principal del homelab); su LAN URL la introduce el operador y/o personas no técnicas con frecuencia. Z2M es de **uso esporádico** (emparejar un sensor nuevo, mirar un valor de LQI cuando algo va raro): el coste de UX de un _gate_ Authelia adicional es bajo.
> - El _blast radius_ de un acceso no autorizado a Z2M es alto (compromete toda la red Zigbee); el _gate_ extra es proporcional.
>
> Por eso: HA sin `import authelia`, Z2M con `import authelia`. El _snippet_ es el mismo; sólo cambia su presencia en cada bloque.

### `permit_join: false` por defecto

Z2M arranca con la opción `permit_join` en `false` (en `configuration.yaml`). Esta opción gobierna si el _coordinator_ Zigbee acepta nuevos dispositivos en la red. En `true`, **cualquier dispositivo Zigbee al alcance** (desde una bombilla del vecino que se reinicia hasta un sensor reseteado) puede unirse; en `false`, sólo se acepta cuando el operador lo abre manualmente desde la UI por una ventana de tiempo limitada (default 254 s, configurable).

**Decisión**: `permit_join: false` siempre en `configuration.yaml`. Para emparejar:

1. UI de Z2M → **Permit join (All)** → ventana de 254 s (o por dispositivo concreto si se prefiere). 
2. Resetear el dispositivo Zigbee (botón físico, secuencia de _power-cycle_, …) durante esa ventana.
3. Z2M lo descubre, lo añade y se cierra automáticamente cuando expira la ventana.

Razones:

- **Seguridad**: Zigbee 3.0 usa _link keys_ globales y _per-device_, pero el _join_ inicial es la fase más vulnerable. Mantenerlo cerrado por defecto evita _join attacks_ casuales.
- **Higiene**: dispositivos vecinos en _factory reset_ podrían unirse accidentalmente y aparecer en la UI con nombres genéricos como `Unknown 0x0000`. Limpiarlos es trivial pero ruidoso.
- **Coherencia con Z2M upstream**: el propio Z2M recomienda mantener `permit_join: false` y abrir desde UI; la opción en `configuration.yaml` está pensada para _bootstrap_ inicial cuando no hay UI todavía.

> **Para el primer arranque** (cuando aún no hay ningún dispositivo emparejado): se entra a la UI a los 30 s de levantar el contenedor y se abre `Permit join` desde ahí. No se necesita el flag global.

### `availability: false` (por ahora)

Z2M tiene un módulo `availability` que monitoriza si los dispositivos siguen "vivos" (envían _heartbeats_) y publica `zigbee2mqtt/<device>/availability: online|offline` para que HA sepa si el sensor ha desaparecido. Es **muy útil** para automatizaciones sensibles a presencia (notificaciones del tipo "sensor de cocina sin reportar desde hace 6 h"), pero tiene coste:

- **Tráfico extra**: Z2M envía un _ping_ a cada router/end-device en su intervalo configurado (default 1 h para _routers_, 25 h para _end-devices_ con _battery_). En una red grande, son miles de pings/día.
- **Falsos positivos**: dispositivos a batería con _sleep cycles_ largos (válvulas térmicas Aqara, sensores de puerta) pueden reportarse como `offline` durante ventanas legítimas.

**Decisión por defecto**: `availability: false`. Habilitar **selectivamente** desde la UI si una automatización concreta lo requiere (`Settings → External converters` en la UI permite habilitar `availability` por dispositivo en lugar de globalmente). Anotado en **Operación**.

### Health-check del contenedor

Z2M no expone un endpoint HTTP `/health` propio. La imagen oficial trae un script `wait-for-it`-style que comprueba la conexión a MQTT, pero no se usa como _healthcheck_ del compose por verbosidad. El _healthcheck_ del compose se basa en el _frontend_ HTTP:

```yaml
healthcheck:
  test: ["CMD-SHELL", "wget -qO- --tries=1 --timeout=5 http://localhost:8080/ | grep -q '<title>Zigbee2MQTT</title>' || exit 1"]
  interval: 30s
  timeout: 10s
  retries: 5
  start_period: 60s
```

Detalles:

- `start_period: 60s`: Z2M tarda 30–45 s en arranque inicial (carga del _coordinator_, sincronización de la red Zigbee, conexión a MQTT). 60 s da margen sin marcar `unhealthy` falsos.
- El `grep '<title>Zigbee2MQTT</title>'` evita _false positives_ si el _frontend_ devuelve una página de error genérica.
- **Falsa sensación de salud**: el _frontend_ puede estar `(healthy)` aunque la conexión MQTT esté caída (se ve en la UI un banner rojo "Disconnected from MQTT"). Mosquitto debería estar saludable como condición previa, y el _depends_on_ con `service_healthy` lo asegura.

### Monitorización de la red Zigbee — `network_map` deshabilitado por defecto

El `network_map` de Z2M es una herramienta valiosa de diagnóstico (LQI, _routes_, _children_/_parent_ de cada nodo) pero es **muy intrusivo**: para construirlo, Z2M emite un `lqi`/`routing_table` request a **cada router** de la red, lo que congestiona temporalmente las comunicaciones y puede provocar des-emparejamientos en redes saturadas.

El `configuration.yaml` deja `experimental.new_api: true` (nuevo API que ya no es experimental, pero la flag persiste por compatibilidad) y **no fija** un intervalo de `network_map` periódico. Se construye **bajo demanda** desde la UI cuando hace falta (Settings → Network map → Generate). Anotado en **Operación**.

---

## Almacenamiento

| Ruta en el host                                                  | Contenido                                                                                | Versionable                | Backup                                |
|------------------------------------------------------------------|------------------------------------------------------------------------------------------|----------------------------|---------------------------------------|
| `~/homelab/domotica/docker-compose.yml`                          | Definición del _stack_ (modificada en este doc)                                          | git                        | git                                   |
| `~/homelab/domotica/.env`                                        | Variables del _stack_ (incluye `Z2M_MQTT_PASSWORD`)                                      | **NO** (`.gitignore`)      | git aparte (nota local)               |
| `~/homelab/domotica/.env.example`                                | Plantilla con nombres de variables                                                       | git                        | git                                   |
| `~/homelab/domotica/zigbee2mqtt/configuration.yaml.example`      | Plantilla del `configuration.yaml` (sin secretos, sin `pan_id`/`network_key` definitivos) | git                        | git                                   |
| `/mnt/hd2t/services/zigbee2mqtt/configuration.yaml`              | Configuración real (incluye `pan_id`, `network_key` aleatorios — **CRÍTICOS**)            | **NO**                     | **Sí** (Borgmatic — fichero crítico)   |
| `/mnt/hd2t/services/zigbee2mqtt/database.db`                     | Base de datos de dispositivos emparejados (mapping de `IEEE address` → `friendly name`)  | **NO**                     | **Sí** (Borgmatic — recreable pero costoso de re-emparejar) |
| `/mnt/hd2t/services/zigbee2mqtt/state.json`                      | Último estado conocido de cada dispositivo (luminosidad, temperatura, …)                 | **NO**                     | _Opcional_ (rebuildable en minutos)   |
| `/mnt/hd2t/services/zigbee2mqtt/coordinator_backup.json`         | Backup automático de la red Zigbee (claves, _trust center_, …)                            | **NO**                     | **Sí** (Borgmatic — crítico para _disaster recovery_) |
| `/mnt/hd2t/services/zigbee2mqtt/log/`                            | Logs por día (`zigbee2mqtt-YYYY-MM-DD.log`)                                              | **NO**                     | **NO** — excluido por `*/log/*`        |

> **`configuration.yaml` con `network_key` y `pan_id` reales**: contiene los **secretos de la red Zigbee**. Si un atacante obtiene la `network_key`, puede _join_ silencioso de cualquier dispositivo Zigbee 3.0 a la red. Por eso **NO** se versiona en git, sólo el `configuration.yaml.example` (que tiene placeholders). Permisos en hd2t:
>
> ```bash
> sudo chown 1000:1000 /mnt/hd2t/services/zigbee2mqtt/configuration.yaml
> sudo chmod 0640 /mnt/hd2t/services/zigbee2mqtt/configuration.yaml
> ```

> **`coordinator_backup.json`**: lo genera Z2M automáticamente cada vez que la red Zigbee cambia (nuevo dispositivo, cambio de canal, …). Es **el** fichero más crítico para _disaster recovery_: con él, ante un cambio de dongle Zigbee se puede restaurar la red sin re-emparejar todos los dispositivos. Permisos `0600 1000:1000`.

> **`database.db`**: a pesar del nombre, es un fichero de texto plano con un objeto JSON por línea (NDJSON). NO es SQLite. Es _atomically rewritten_ por Z2M (`rename(2)` tras escribir un `.db.tmp`), así que un Borg en frío vivo lo captura íntegro.

> **`log/` excluido**: cubierto por `exclude_patterns: '*/log/*'` global de Borgmatic (ver `docs/07-backups/02-borgmatic.md`).

---

## Estructura del _stack_ `domotica` tras este documento

```
~/homelab/domotica/
├── docker-compose.yml             # ← modificado (se añade el servicio zigbee2mqtt)
├── .env                           # ← modificado (se añade Z2M_IMAGE_TAG, Z2M_MQTT_PASSWORD, Z2M_USB_DEVICE)
├── .env.example                   # ← modificado (idem, sin valores)
├── .gitignore                     # sin cambios
├── mosquitto/                     # del doc anterior
│   ├── mosquitto.conf
│   └── acl
└── zigbee2mqtt/                   # ← nuevo
    └── configuration.yaml.example  # plantilla versionada (sin secretos)
```

Y en los discos externos, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/zigbee2mqtt/
├── configuration.yaml             # ← creado en este doc (con secretos reales, NO versionado)
├── database.db                    # creado por Z2M en runtime
├── state.json                     # creado por Z2M en runtime
├── coordinator_backup.json        # creado por Z2M tras el primer pairing
└── log/
    └── zigbee2mqtt-YYYY-MM-DD.log  # creado por Z2M en runtime
```

Aplicar el _ownership_ que faltaba:

```bash
sudo chown -R 1000:1000 /mnt/hd2t/services/zigbee2mqtt
sudo chmod 0750 /mnt/hd2t/services/zigbee2mqtt
mkdir -p /mnt/hd2t/services/zigbee2mqtt/log
sudo chown 1000:1000 /mnt/hd2t/services/zigbee2mqtt/log
sudo chmod 0750 /mnt/hd2t/services/zigbee2mqtt/log
```

> **Por qué `1000:1000`**: PUID/PGID globales del homelab, mismo usuario que opera por SSH la Pi. Z2M corre como `root` dentro del contenedor (la imagen oficial no respeta `--user` con `devices:` y termina escalando privilegios para abrir el device serial), pero los ficheros que escribe en el bind mount aparecen como `1000:1000` por la opción `:Z` (cuando aplica) o el `chown` que el _entrypoint_ realiza en _bootstrap_. Si tras el primer arranque los ficheros aparecen como `root:root`, aplicar `sudo chown -R 1000:1000 /mnt/hd2t/services/zigbee2mqtt`.

Crear el subdirectorio versionado del _stack_:

```bash
mkdir -p ~/homelab/domotica/zigbee2mqtt
chmod 0750 ~/homelab/domotica/zigbee2mqtt
```

---

## Variables de entorno

Añadir a `~/homelab/domotica/.env.example` (versionado, sin valores reales):

```bash
# --- Imágenes pinneadas (continúa de docs/08-domotica/02-mosquitto.md) ---
HA_IMAGE_TAG=2026.4
MOSQUITTO_IMAGE_TAG=2.0.20
Z2M_IMAGE_TAG=1.40.1

# --- Zigbee2MQTT -----------------------------------------------------------
# Symlink persistente del adaptador USB (verificar con
# 'ls -la /dev/serial/by-id/ | grep -iE "zigbee|sonoff|conbee|skyconnect"').
# El symlink incluye el SERIAL del dongle; rellenar en .env, no aquí.
Z2M_USB_DEVICE=/dev/serial/by-id/usb-XXXXX-if00-port0

# Credenciales del usuario 'zigbee2mqtt' creado en docs/08-domotica/02-mosquitto.md.
# La contraseña real va en .env (NO versionada); aquí sólo el placeholder.
Z2M_MQTT_USERNAME=zigbee2mqtt
Z2M_MQTT_PASSWORD=changeme
```

Copiar a `~/homelab/domotica/.env` los valores reales:

```bash
$EDITOR ~/homelab/domotica/.env
chmod 0600 ~/homelab/domotica/.env
```

Concretamente:

- **`Z2M_USB_DEVICE`**: el _symlink_ exacto que apareció en `ls -la /dev/serial/by-id/`. Ejemplo:

  ```bash
  Z2M_USB_DEVICE=/dev/serial/by-id/usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_2024XYZ-if00-port0
  ```

- **`Z2M_MQTT_PASSWORD`**: la contraseña del usuario `zigbee2mqtt` que se generó y se guardó en Vaultwarden / KeePassXC en `docs/08-domotica/02-mosquitto.md` (sección **Generación del `password_file`**).

> **`Z2M_MQTT_PASSWORD` en `.env`**: es la primera vez en este _stack_ que `.env` lleva un secreto real (HA usa `secrets.yaml` y Mosquitto sus _hashes_ aparte). Z2M sí lee la contraseña por _env var_ (`mqtt.password: !env_var Z2M_MQTT_PASSWORD` en `configuration.yaml`), así que el `.env` es el sitio adecuado. Permisos `0600` (operador-only).

---

## `~/homelab/domotica/zigbee2mqtt/configuration.yaml.example` (plantilla versionable)

Esta es la **plantilla** que se versiona. Es una copia textual de la `configuration.yaml` real **sin secretos**:

```yaml
# =============================================================================
# Zigbee2MQTT — configuración base del homelab
# Documentación: docs/08-domotica/03-zigbee2mqtt.md
# Schema: https://www.zigbee2mqtt.io/guide/configuration/
#
# Esta es la PLANTILLA versionada. La copia real con secretos (network_key,
# pan_id) vive en /mnt/hd2t/services/zigbee2mqtt/configuration.yaml y NO está
# en git.
# =============================================================================

homeassistant:
  enabled: true
  # Discovery prefix (debe coincidir con el de la integración MQTT de HA).
  discovery_topic: homeassistant
  # Status topic publicado cuando Z2M conecta/desconecta del broker.
  status_topic: homeassistant/status
  # Object id legacy: false → usa el friendly_name como ID. true → entity_id legacy.
  legacy_entity_attributes: false
  legacy_triggers: false

# Frontend web embebido. Sólo accesible desde la red Docker; Caddy hace TLS.
frontend:
  enabled: true
  port: 8080
  # host: 0.0.0.0 # default; deshabilitar IPv6 si el contenedor no tiene v6.

# Conexión al broker.
mqtt:
  base_topic: zigbee2mqtt
  server: mqtt://mosquitto:1883
  user: !env_var Z2M_MQTT_USERNAME
  password: !env_var Z2M_MQTT_PASSWORD
  client_id: zigbee2mqtt-homelab
  keepalive: 60
  reject_unauthorized: true
  version: 4   # MQTT 3.1.1; Mosquitto 2.0 soporta 5 también pero 4 es el sweet spot.

# Adaptador serie. /dev/ttyACM0 es el lado interno del mapping del compose.
serial:
  port: /dev/ttyACM0
  # adapter: zstack # auto-detectado para CC2652P. Descomentar si Z2M no lo detecta.
  # baudrate: 115200 # default; descomentar para forzar.
  # rtscts: false # default.

# Permitir join queda desactivado por defecto. Abrir desde la UI cuando se quiera
# emparejar.
permit_join: false

# Channel del coordinator. 11, 15, 20, 25 son los recomendados por Z2M
# (mínima superposición con WiFi 2,4 GHz). 25 es el último canal libre del
# espectro WiFi 2,4 — buena opción si la casa tiene router en canal 1 ó 6.
advanced:
  channel: 25
  # network_key y pan_id son SECRETOS — autogenerados al primer arranque y
  # rellenados por Z2M en la copia REAL de /mnt/hd2t/services/zigbee2mqtt/.
  # En esta plantilla quedan como `GENERATE` para que el operador SEPA que
  # se autogeneran al arrancar la primera vez.
  network_key: GENERATE
  pan_id: GENERATE
  ext_pan_id: GENERATE
  # Logging.
  log_level: info
  log_output: ['console', 'file']
  log_directory: /app/data/log
  log_file: zigbee2mqtt-%TIMESTAMP%.log
  # Rotación: 5 ficheros de 10 MiB cada uno, comprimidos. Coherente con el
  # tamaño del USB de hd2t y con la duración típica de un ciclo de troubleshoot.
  log_rotation: true
  log_symlink_current: true
  # Habilitar metrics si en algún momento llega Prometheus para Z2M (el doc de
  # docs/05-monitorizacion/01-prometheus.md no lo cubre todavía; queda preparado).
  homeassistant_legacy_entity_attributes: false
  legacy_api: false

# Disponibilidad: deshabilitada globalmente. Habilitar selectivamente con
# `device.<friendly_name>.availability: true` cuando se necesite.
availability:
  enabled: false

# OTA upstream desde IKEA, Ledvance, Innr, etc.
ota:
  update_check_interval: 1440  # minutos (24 h).
  disable_automatic_update_check: false
  # zigbee_ota_override_index_location: # personalizar para mirrors si hace falta.

# Opciones de devices (vacío al principio; Z2M las añade conforme se emparejan).
devices: {}
groups: {}

# Versión del schema de configuración. NO tocar manualmente; Z2M lo migra solo.
version: 4
```

---

## Crear el `configuration.yaml` real (con secretos)

Z2M genera `network_key`, `pan_id` y `ext_pan_id` automáticamente la primera vez que arranca con esos valores como `GENERATE` (string especial). El operador no los introduce a mano.

Copiar la plantilla a hd2t como punto de partida:

```bash
sudo cp ~/homelab/domotica/zigbee2mqtt/configuration.yaml.example \
        /mnt/hd2t/services/zigbee2mqtt/configuration.yaml
sudo chown 1000:1000 /mnt/hd2t/services/zigbee2mqtt/configuration.yaml
sudo chmod 0640 /mnt/hd2t/services/zigbee2mqtt/configuration.yaml
```

Tras el primer arranque del contenedor, Z2M reescribe el fichero con los _secretos_ reales. **A partir de ese momento**, el fichero es **CRÍTICO**: contiene la `network_key` que define la red Zigbee. Cambiarla tras el primer pairing implica re-emparejar todos los dispositivos.

> **Tras el primer arranque, comprobar**:
>
> ```bash
> sudo grep -E 'network_key|pan_id|ext_pan_id' /mnt/hd2t/services/zigbee2mqtt/configuration.yaml
> # advanced:
> #   network_key: [0xCA, 0xFE, ...]  ← 16 bytes hexa
> #   pan_id: 0x1234
> #   ext_pan_id: [0xDD, 0xDD, ...]  ← 8 bytes hexa
> ```
>
> Apuntar `network_key` y `pan_id` en Vaultwarden bajo "homelab — zigbee2mqtt — network secrets" como respaldo de emergencia (si el `coordinator_backup.json` se corrompe y Borg no llega a rescatar — escenario muy improbable pero el coste de copiar 24 bytes a Vaultwarden es trivial).

---

## `~/homelab/domotica/docker-compose.yml` — modificación

El _stack_ ya existe con `home-assistant` y `mosquitto`. Este documento añade el servicio `zigbee2mqtt`. El bloque a sumar:

```yaml
  # ---------------------------------------------------------------------------
  # Zigbee2MQTT — bridge Zigbee ↔ MQTT.
  #  - En 'homelab' (Caddy hace reverse_proxy a zigbee2mqtt:8080).
  #  - En 'domotica-internal' (habla con mosquitto:1883 sin cruzar 'homelab').
  #  - Acceso al dongle USB vía symlink persistente /dev/serial/by-id/.
  # ---------------------------------------------------------------------------
  zigbee2mqtt:
    image: koenkk/zigbee2mqtt:${Z2M_IMAGE_TAG}
    container_name: zigbee2mqtt
    hostname: zigbee2mqtt
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      Z2M_MQTT_USERNAME: ${Z2M_MQTT_USERNAME}
      Z2M_MQTT_PASSWORD: ${Z2M_MQTT_PASSWORD}
    volumes:
      # Configuración real (con secretos). El bind a /app/data lo define la imagen.
      - /mnt/hd2t/services/zigbee2mqtt:/app/data
      - /etc/localtime:/etc/localtime:ro
    devices:
      # Symlink persistente del dongle Zigbee. Ver 'Z2M_USB_DEVICE' en .env.
      - "${Z2M_USB_DEVICE}:/dev/ttyACM0"
    networks:
      homelab:
        aliases:
          - zigbee2mqtt
      domotica-internal:
        aliases:
          - zigbee2mqtt
    labels:
      homelab.stack: "domotica"
      homelab.backup: "true"
      # Opt-out: bumps manuales con changelog (ver docs/02-docker/04-watchtower.md).
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- --tries=1 --timeout=5 http://localhost:8080/ | grep -q '<title>Zigbee2MQTT</title>' || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    depends_on:
      mosquitto:
        condition: service_healthy
```

Notas de diseño:

- **`zigbee2mqtt.depends_on.mosquitto: service_healthy`**: Z2M arranca después de que Mosquitto esté `(healthy)`. Sin esto, Z2M reintentaría conexión MQTT durante decenas de segundos en el primer arranque y dejaría _warnings_ ruidosos. En arranques en caliente (`docker compose restart zigbee2mqtt`) el `depends_on` no aporta nada.
- **`devices: ["${Z2M_USB_DEVICE}:/dev/ttyACM0"]`**: el _symlink_ persistente del lado izquierdo se resuelve en el momento de levantar el contenedor (una vez); si el dongle se desenchufa y se vuelve a enchufar mientras Z2M está corriendo, **el contenedor pierde el device** (Docker no re-resuelve _symlinks_ en caliente). Síntoma: `Failed to connect to /dev/ttyACM0` en logs. Solución: `docker compose restart zigbee2mqtt`. Ver **Troubleshooting**.
- **No se monta `/dev/bus/usb`**: algunos tutoriales online sugieren montar el bus USB completo. **No** se necesita y abre privilegios innecesarios. El `devices:` simple es suficiente.
- **`environment: Z2M_MQTT_USERNAME, Z2M_MQTT_PASSWORD`**: se inyectan al contenedor para que el `!env_var Z2M_MQTT_PASSWORD` del `configuration.yaml` los expanda. El TZ se hereda del `.env` global del homelab.
- **Sin `user:`**: la imagen `koenkk/zigbee2mqtt` corre como `root` por defecto y necesita serlo para abrir el `/dev/ttyACM0` (a menos que se montase el grupo `dialout` con `group_add`, lo que añade complejidad sin valor para un homelab personal). El _ownership_ de los ficheros que Z2M escribe en hd2t lo gestiona el operador con `chown 1000:1000` la primera vez (ver **Estructura**).
- **Sin `ports:`**: el _frontend_ HTTP **NO** se publica al host. Caddy es el único camino. Si en algún troubleshoot se necesita acceso directo, `docker exec -it zigbee2mqtt sh` y desde dentro `wget http://localhost:8080/`, o publicación temporal con `docker run -p 8080:8080 ...` en otro contenedor.

El `services:` block del `docker-compose.yml` queda con tres servicios (`home-assistant`, `mosquitto`, `zigbee2mqtt`); el bloque `networks:` no cambia (sigue con `homelab` external + `domotica-internal` interna, definidas en `02-mosquitto.md`).

---

## Configuración de Caddy

Editar `~/homelab/red/Caddyfile` y añadir el bloque (junto al de `home-assistant.lan` que ya existe del doc de HA):

```caddy
zigbee2mqtt.lan {
    tls internal
    import security-headers
    import logging
    import authelia

    reverse_proxy zigbee2mqtt:8080 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto https
    }
}
```

> **`import authelia`**: única diferencia destacable respecto al bloque de HA. Z2M no autentica nada; Authelia actúa como su _gate_ de SSO + 2FA.

> **`reverse_proxy` con WebSocket**: el _frontend_ de Z2M usa una WebSocket para el _live update_ de la UI (logs, eventos de dispositivos, mensajes MQTT en tiempo real). `reverse_proxy` de Caddy v2 maneja el _upgrade_ a WS automáticamente; **no se añaden directivas especiales**.

Validar el `Caddyfile`:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
# OK
```

Recargar sin downtime:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
# {"level":"info","msg":"reloading"} ...
```

---

## Configuración de Authelia

Editar `~/homelab/seguridad/authelia/access_control.yml` (ver `docs/04-seguridad/01-authelia.md`) y descomentar / añadir la línea para `zigbee2mqtt.lan` en la lista `two_factor`:

```yaml
access_control:
  default_policy: deny
  rules:
    - domain:
        - 'auth.lan'
      policy: bypass
    - domain:
        - 'zigbee2mqtt.lan'   # ← descomentar / añadir
        # - 'node-red.lan'    # se descomenta cuando llegue 04-node-red.md
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

> **Si Authelia aún no está montado**: el `import authelia` del `Caddyfile` falla con un error claro al `caddy validate` ("no snippet authelia"). En ese caso, **omitir el `import authelia`** del bloque `zigbee2mqtt.lan` por ahora y añadirlo cuando Authelia se despliegue. Z2M quedará accesible sin _gate_, lo que es **aceptable transitoriamente** dado que el homelab está en LAN y el SSO se monta en la siguiente fase del plan (Fase 4 ya completada en este contexto, así que en la práctica este caso es muy raro). Anotado.

---

## Despliegue

### Validar la sintaxis del compose

```bash
cd ~/homelab/domotica
docker compose --env-file ../.env --env-file .env config | grep -E 'zigbee2mqtt|/dev/ttyACM0|/dev/serial' -A 1 -B 1
```

Salida esperada incluye:

```
    image: koenkk/zigbee2mqtt:1.40.1
    devices:
    - /dev/serial/by-id/usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_...:/dev/ttyACM0:rwm
      domotica-internal:
      homelab:
```

### Levantar el _stack_

```bash
cd ~/homelab
make up STACK=domotica
```

O equivalente:

```bash
cd ~/homelab/domotica
docker compose --env-file ../.env --env-file .env up -d zigbee2mqtt
```

Esperar al `(healthy)`:

```bash
docker compose -f ~/homelab/domotica/docker-compose.yml ps
# NAME            IMAGE                              STATUS
# home-assistant  homeassistant/home-assistant:...   Up X minutes (healthy)
# mosquitto       eclipse-mosquitto:2.0.20           Up X minutes (healthy)
# zigbee2mqtt     koenkk/zigbee2mqtt:1.40.1          Up X seconds (healthy)
```

Si `zigbee2mqtt` se queda en `starting` >60 s o pasa a `unhealthy`, ir a **Troubleshooting** → primer arranque.

### Logs del primer arranque

```bash
docker logs zigbee2mqtt --tail 60
```

Salida esperada (líneas relevantes, abreviadas):

```
zigbee2mqtt:info  ... Logging to console and ...
zigbee2mqtt:info  ... Starting Zigbee2MQTT version 1.40.1 (commit #...)
zigbee2mqtt:info  ... Starting zigbee-herdsman (1.x.x)
zigbee2mqtt:info  ... zigbee-herdsman started (resumed)         ← o (started) en el primer pairing
zigbee2mqtt:info  ... Coordinator firmware version: ...
zigbee2mqtt:info  ... Currently 0 devices are joined
zigbee2mqtt:info  ... Connecting to MQTT server at mqtt://mosquitto:1883
zigbee2mqtt:info  ... Connected to MQTT server
zigbee2mqtt:info  ... MQTT publish: topic 'zigbee2mqtt/bridge/state', payload '{"state":"online"}'
zigbee2mqtt:info  ... Started frontend on port 8080
```

Lo que **no** debe aparecer:

- `Error: cannot open /dev/ttyACM0` → el `devices:` del compose no resolvió correctamente; ver **Troubleshooting**.
- `MQTT error: Connection refused: Not authorized` → la contraseña de `Z2M_MQTT_PASSWORD` no coincide con el `passwd` de Mosquitto; ver `docs/08-domotica/02-mosquitto.md`.
- `zigbee-herdsman did not start, error: ...` → problema con el firmware del coordinator; ver **Troubleshooting**.

---

## Verificación funcional

### Frontend accesible vía Caddy + Authelia

Desde un navegador:

1. Ir a `https://zigbee2mqtt.lan/`.
2. Authelia intercepta y redirige a `https://auth.lan/?rd=https://zigbee2mqtt.lan/`.
3. Introducir usuario + contraseña + 2FA TOTP.
4. Tras el login, Authelia redirige de vuelta a Z2M.
5. La UI de Zigbee2MQTT carga: panel principal con `Devices: 0`, `Groups: 0`, banner verde "Connected to MQTT".

### Conexión a MQTT desde el broker

Desde el host:

```bash
mosquitto_sub -h 192.168.1.3 -p 1883 \
  -u homeassistant -P "<password de homeassistant>" \
  -t 'zigbee2mqtt/bridge/state' -v -C 1
# zigbee2mqtt/bridge/state {"state":"online"}
```

```bash
mosquitto_sub -h 192.168.1.3 -p 1883 \
  -u homeassistant -P "<password de homeassistant>" \
  -t 'zigbee2mqtt/bridge/info' -v -C 1
# zigbee2mqtt/bridge/info {"version":"1.40.1","commit":"...", ...}
```

### Permitir join temporal y emparejar un dispositivo de prueba

En la UI de Z2M:

1. **Pestaña _Devices_** → botón **Permit join (All)** → seleccionar duración (default 254 s) → confirmar.
2. **Resetear** un dispositivo Zigbee (mantener el botón principal de un sensor durante 5 s, _power-cycle_ rápido en bombillas IKEA, …).
3. Z2M lo descubre. En la pestaña _Devices_ aparece una línea nueva con `IEEE address` y `Friendly name = 0x0017xxx...`.
4. Renombrar a un nombre descriptivo (`sensor_cocina`, `bombilla_salon`, …) desde la UI: el `database.db` se actualiza automáticamente.
5. La UI cierra el `Permit join` automáticamente al expirar la ventana.

Confirmar que MQTT publica el estado:

```bash
mosquitto_sub -h 192.168.1.3 -p 1883 \
  -u homeassistant -P "<password de homeassistant>" \
  -t 'zigbee2mqtt/sensor_cocina/#' -v -C 5
# zigbee2mqtt/sensor_cocina {"battery":100,"linkquality":95,"temperature":21.3, ...}
```

### MQTT discovery hacia HA

Tras emparejar un dispositivo y publicar su estado, Z2M genera automáticamente mensajes _retained_ en `homeassistant/<componente>/<device>/config`. HA los ingiere por su integración MQTT y crea entidades **sin acción manual del operador**.

Verificar desde HA:

1. **Settings → Devices & services → MQTT → Devices** → debe aparecer el `sensor_cocina` con sus entidades (`temperature`, `battery`, `linkquality`).
2. **Developer tools → States** → buscar `sensor.sensor_cocina_temperature`. Debe mostrar el valor leído.

Y desde MQTT:

```bash
mosquitto_sub -h 192.168.1.3 -p 1883 \
  -u monitor -P "<password de monitor>" \
  -t '$SYS/broker/clients/connected' -v -C 1
# $SYS/broker/clients/connected 5  (HA, Z2M, Uptime Kuma, monitor sub, posibles ESP32)
```

> **Si una entidad concreta no aparece en HA**: comprobar que Z2M la describió correctamente. Pestaña _Devices → <device> → Exposes_ en la UI muestra qué propiedades publica el dispositivo. Si Z2M no soporta el dispositivo nativamente, los _exposes_ vienen vacíos y HA no crea entidades — el dispositivo necesita un _external converter_ (avanzado, fuera de alcance de este doc).

### Comprobar `coordinator_backup.json`

Tras el primer pairing, Z2M genera el backup automático:

```bash
sudo ls -la /mnt/hd2t/services/zigbee2mqtt/coordinator_backup.json
# -rw-r--r-- 1 1000 1000 ... coordinator_backup.json
sudo head -c 200 /mnt/hd2t/services/zigbee2mqtt/coordinator_backup.json
# {"metadata":{"format":"zigbee-herdsman","version":2,...},"network_key": ...}
```

Aplicar permisos `0600` al fichero por contener la `network_key`:

```bash
sudo chmod 0600 /mnt/hd2t/services/zigbee2mqtt/coordinator_backup.json
```

---

## Backup

Z2M cae en la **Categoría F** (filesystem-only) de `docs/07-backups/03-backup-docker-volumes.md`: la fuente de verdad respaldable es el árbol `/mnt/hd2t/services/zigbee2mqtt/`, ya cubierto por `source_directories: /mnt/hd2t/services` de Borgmatic. **No hace falta acción nueva** para que `configuration.yaml`, `database.db`, `state.json` y `coordinator_backup.json` entren en el siguiente _archive_.

### Decisión: **no** hacer dump activo

El bloque comentado que `docs/07-backups/03-backup-docker-volumes.md` dejó preparado en `dump-databases.sh`:

```bash
# --- Zigbee2MQTT (YAML + state.json — Categoría F) — docs/08-domotica/03-zigbee2mqtt.md
# /mnt/hd2t/services/zigbee2mqtt/ entra como source_directory.
```

**Se mantiene comentado** (no se añade nada nuevo). Razones:

- Z2M reescribe `database.db` y `state.json` de forma **atómica** (`rename(2)` tras escribir el `.tmp`), así que un Borg en frío vivo captura siempre una versión consistente.
- `configuration.yaml` lo escribe Z2M con la misma técnica atómica cuando la UI o un cambio de _config schema_ lo requieren (raro).
- `coordinator_backup.json` se escribe atómicamente cada vez que la red Zigbee cambia (nuevo pairing, cambio de canal, _restart_).
- Detener Z2M (`docker stop`) durante un dump sería innecesariamente disruptivo: la red Zigbee sigue activa físicamente, pero ningún sensor reporta a MQTT durante la ventana de stop. Inaceptable para un sistema que monitoriza la casa 24/7.

### Confirmar cobertura por Borgmatic

```bash
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL::$(borg list --short "$BORG_REPO_LOCAL" | tail -1)" \
    | grep zigbee2mqtt | head -10
'
# -rw-r----- 1000 1000 ... mnt/hd2t/services/zigbee2mqtt/configuration.yaml
# -rw------- 1000 1000 ... mnt/hd2t/services/zigbee2mqtt/coordinator_backup.json
# -rw-r--r-- 1000 1000 ... mnt/hd2t/services/zigbee2mqtt/database.db
# -rw-r--r-- 1000 1000 ... mnt/hd2t/services/zigbee2mqtt/state.json
```

(Los ficheros de `log/` aparecen sólo si no se han excluido por `*/log/*` global; verificar con un `dry-run`.)

### Restauración

Procedimiento estándar (`docs/07-backups/03-backup-docker-volumes.md`, sección _Procedimientos de restauración_, variante _filesystem-only_):

1. `docker compose -f ~/homelab/domotica/docker-compose.yml stop zigbee2mqtt`.
2. Mover `/mnt/hd2t/services/zigbee2mqtt/` a `zigbee2mqtt.broken-<ts>` (preservar 24-48 h por si el problema era distinto al asumido).
3. `borg extract` del archive elegido a `/tmp/restore-$$/` y mover en sitio.
4. `sudo chown -R 1000:1000 /mnt/hd2t/services/zigbee2mqtt`.
5. `sudo chmod 0640 /mnt/hd2t/services/zigbee2mqtt/configuration.yaml`.
6. `sudo chmod 0600 /mnt/hd2t/services/zigbee2mqtt/coordinator_backup.json`.
7. `docker compose -f ~/homelab/domotica/docker-compose.yml up -d zigbee2mqtt`.
8. Esperar al `(healthy)`. Z2M reanuda la red Zigbee desde el `coordinator_backup.json`. Los dispositivos siguen emparejados; sólo se pierden los estados publicados desde el último _archive_ (que se reemiten en el siguiente ciclo de cada sensor).

> **Cambio de dongle Zigbee** (caso de _disaster_ más probable): el `coordinator_backup.json` permite migrar la red Zigbee a un dongle nuevo sin re-emparejar todos los dispositivos. Procedimiento:
>
> 1. Stop del contenedor: `docker compose stop zigbee2mqtt`.
> 2. Cambiar físicamente el dongle.
> 3. Actualizar `Z2M_USB_DEVICE` en `.env` con el nuevo _serial_.
> 4. **No tocar** `configuration.yaml` ni `coordinator_backup.json` — Z2M los reusará.
> 5. `docker compose up -d zigbee2mqtt`.
> 6. En el primer arranque, Z2M detecta dongle nuevo, lee `coordinator_backup.json` y restaura la red. Los dispositivos siguen funcionando.
>
> **Importante**: el dongle nuevo debe ser **del mismo tipo de chip** (CC2652P → CC2652P). Migrar entre familias (CC2531 → CC2652P, ConBee II → SkyConnect) **requiere re-pairing** porque la _network key_ está vinculada al firmware del coordinator.

---

## Verificación

Antes de cerrar este documento:

- [ ] `~/homelab/domotica/docker-compose.yml`, `~/homelab/domotica/.env.example` y `~/homelab/domotica/zigbee2mqtt/configuration.yaml.example` versionados en git. `~/homelab/domotica/.env` **no** versionado (`.gitignore` activo). `/mnt/hd2t/services/zigbee2mqtt/configuration.yaml` con `0640 1000:1000`. `/mnt/hd2t/services/zigbee2mqtt/coordinator_backup.json` con `0600 1000:1000`.
- [ ] `docker compose -f ~/homelab/domotica/docker-compose.yml ps` muestra `zigbee2mqtt`, `mosquitto`, `home-assistant` los tres `(healthy)`.
- [ ] `docker logs zigbee2mqtt --tail 30` muestra `Connected to MQTT server`, `Coordinator firmware version: ...` y `Started frontend on port 8080`. **No** muestra `Error: cannot open /dev/ttyACM0` ni `MQTT error: not authorized`.
- [ ] `mosquitto_sub -h 192.168.1.3 -u homeassistant -P <password> -t 'zigbee2mqtt/bridge/state' -C 1` devuelve `{"state":"online"}`.
- [ ] `https://zigbee2mqtt.lan/` redirige a Authelia, autentica con TOTP, y carga la UI de Z2M con el banner "Connected to MQTT".
- [ ] `import authelia` está presente en el bloque `zigbee2mqtt.lan` del `Caddyfile`. **No** está en el bloque `home-assistant.lan`.
- [ ] `access_control.yml` de Authelia tiene `'zigbee2mqtt.lan'` en la lista `two_factor`.
- [ ] El _symlink_ `/dev/serial/by-id/usb-...` referenciado en `.env` apunta a un `ttyUSB*` real (`ls -la /dev/serial/by-id/`). El contenedor ve `/dev/ttyACM0` mapeado correctamente: `docker exec zigbee2mqtt ls -la /dev/ttyACM0` muestra `crw-rw---- 1 root dialout ...`.
- [ ] La red `domotica-internal` sigue intacta: `docker network inspect domotica-internal` muestra `mosquitto` y `zigbee2mqtt` como _containers_ conectados.
- [ ] `coordinator_backup.json` se ha generado tras el primer pairing y permisos son `0600 1000:1000`.
- [ ] Watchtower no toca el contenedor: `docker logs watchtower --tail 100 | grep zigbee2mqtt` no muestra "Found new image" para Z2M.
- [ ] Tras emparejar un dispositivo de prueba, HA crea entidades automáticamente (verificable en _Settings → Devices & services → MQTT_).
- [ ] Borgmatic _dry-run_ incluye `/mnt/hd2t/services/zigbee2mqtt/configuration.yaml`, `database.db` y `coordinator_backup.json`: `sudo /usr/bin/borgmatic --dry-run --verbosity 2 | grep zigbee2mqtt`.

---

## Operación día a día

### Emparejar un dispositivo nuevo

1. UI de Z2M → **Permit join (All)** → 254 s.
2. Reset físico del dispositivo Zigbee (consultar manual del fabricante; mayoría requiere mantener un botón 5–10 s o un _power-cycle_ específico).
3. Espera 10–60 s. El dispositivo aparece en la UI de Z2M con _IEEE address_.
4. Renombrar a un _friendly_name_ descriptivo (`sensor_<área>_<tipo>`, p. ej. `sensor_salon_temperatura`).
5. Si el dispositivo expone capacidades adicionales (LED, configuración de _reporting interval_, …), ajustar desde la pestaña _Exposes_ del propio dispositivo en la UI.
6. Confirmar que HA crea las entidades automáticamente (Settings → Devices & services → MQTT → Devices → buscar el nuevo).

### Des-emparejar un dispositivo

1. UI de Z2M → _Devices_ → seleccionar el dispositivo → **Remove**.
2. Z2M envía un comando _leave_ al dispositivo. Si el dispositivo está alimentado y dentro del rango, se va limpiamente. Si no responde (típico en sensores a batería que durmieron justo antes), Z2M lo elimina de su `database.db` igualmente y el dispositivo quedará "huérfano" hasta que se resetee y se re-empareje a otra red.
3. HA elimina las entidades automáticamente cuando MQTT publica el _retained delete_ en `homeassistant/<componente>/<device>/config` con _payload_ vacío.

### Generar el _network map_ (sólo bajo demanda)

UI → **Settings** → **Network map** → **Refresh**. Tarda 30 s a 5 min según el tamaño de la red. Útil para diagnosticar dispositivos con LQI bajo (links < 50 son problemáticos), ver la topología (qué dispositivos actúan como _routers_, qué hojas dependen de qué padre).

> **No** programarlo periódico. Es agresivo con la red y puede causar des-emparejamientos en redes saturadas.

### Cambiar de canal del coordinator

Si el WiFi 2,4 GHz del router cambia de canal o un nuevo router en la zona introduce ruido, puede convenir mover Z2M a otro canal:

1. UI → _Settings → Network → Change channel_ → seleccionar nuevo canal (11, 15, 20, 25 son los recomendados).
2. Z2M emite un _channel switch announcement_ a todos los routers de la red. **End-devices** (sensores, batería) no reciben este anuncio si están dormidos; tras despertar, descubrirán el nuevo canal por el _trust center_.
3. Esperar 24–48 h para que todos los _end-devices_ migren. Algunos sensores Aqara con _sleep_ muy largos pueden no migrar nunca y requieren reset manual.

### Logs

Por contenedor (Dozzle o `docker logs`):

```bash
docker logs zigbee2mqtt --since 1h --tail 200 | grep -iE 'error|warn|fail'
```

Por fichero (rotados en hd2t):

```bash
ls -la /mnt/hd2t/services/zigbee2mqtt/log/
# zigbee2mqtt-2026-04-26.18-30-00.log
# zigbee2mqtt-current.log -> zigbee2mqtt-2026-04-26.18-30-00.log
```

`zigbee2mqtt-current.log` es el _symlink_ al activo. Con `log_rotation: true`, Z2M conserva los últimos 5 ficheros de 10 MiB.

---

## Troubleshooting

### Primer arranque: `zigbee2mqtt` se queda en `starting` y luego `unhealthy`

```bash
docker logs zigbee2mqtt --tail 80
```

Causas comunes:

- **`Error: cannot open /dev/ttyACM0`** o **`Error: Resource not accessible`**:
  - El _symlink_ `Z2M_USB_DEVICE` no resuelve a un device real. Comprobar:
    ```bash
    ls -la /dev/serial/by-id/
    readlink -f "$(grep ^Z2M_USB_DEVICE ~/homelab/domotica/.env | cut -d= -f2)"
    # /dev/ttyUSB0
    ls -la /dev/ttyUSB0
    # crw-rw---- 1 root dialout ... /dev/ttyUSB0
    ```
  - Si el `ls` falla, el dongle no está enchufado o el kernel no lo detectó. `dmesg | tail -20` y reconectar.
  - Si el _symlink_ resuelve pero el contenedor sigue fallando, recrear el contenedor (`docker compose up -d --force-recreate zigbee2mqtt`); Docker no re-resuelve _symlinks_ en contenedores ya creados.

- **`zigbee-herdsman did not start, error: Failed to write or read after 3 retries`**:
  - El firmware del coordinator está dañado o es incompatible. Reflashear el dongle (procedimiento avanzado, ver <https://www.zigbee2mqtt.io/guide/adapters/>).
  - Si el dongle es un Sonoff Plus y el firmware Z-Stack es muy antiguo, actualizarlo a la última `coordinator/...` desde <https://github.com/Koenkk/Z-Stack-firmware/>.

- **`MQTT error: Connection refused: Not authorized`**:
  - La contraseña `Z2M_MQTT_PASSWORD` en `.env` no coincide con el `passwd` de Mosquitto. Comparar:
    ```bash
    grep ^Z2M_MQTT_PASSWORD ~/homelab/domotica/.env
    # contrastar con la entry del Vaultwarden bajo "homelab — mosquitto — zigbee2mqtt"
    ```
  - Si las contraseñas coinciden pero la conexión sigue fallando, probar manualmente:
    ```bash
    mosquitto_sub -h 192.168.1.3 -u zigbee2mqtt -P "<password>" -t '$SYS/broker/version' -C 1
    ```
    Si esto falla con `not authorised`, regenerar el _hash_ del usuario `zigbee2mqtt` en el `passwd` de Mosquitto (ver `docs/08-domotica/02-mosquitto.md`, sección **Generación del `password_file`**).

- **`Error: Configuration is not valid: ...`**:
  - YAML mal formado en `configuration.yaml`. Validar con `yq` o `python -c 'import yaml; yaml.safe_load(open("/mnt/hd2t/services/zigbee2mqtt/configuration.yaml"))'`.
  - Tras una migración fallida del schema, Z2M deja un comentario `# auto-migrated` con el cambio. Si el comentario está mal colocado, restaurar desde Borg.

### Dispositivos en LQI bajo o desconectándose

- **LQI < 50**: enlace débil. Soluciones: acercar el dispositivo al coordinator/router más cercano, añadir un dispositivo Zigbee siempre alimentado (un enchufe Zigbee) entre medio para que actúe como _router_, mover el dongle por USB extender a una posición central de la casa.
- **Interferencia con WiFi 2,4 GHz**: los canales Zigbee 11, 15, 20, 25 corresponden a "huecos" del espectro WiFi. Si el router WiFi está en canal 1, 6 u 11 del WiFi (los habituales), Z2M en canal 25 minimiza interferencias. Cambiar el canal Z2M (ver **Operación**) si el router está en un canal raro.
- **Mover físicamente el dongle**: Z2M trabaja muy mal pegado a la Pi (el USB 3.0 emite ruido en 2,4 GHz). El alargador USB 2.0 ≥1 m del `docs/00-hardware/02-esquema-conexiones.md` es **obligatorio**, no recomendación opcional.

### El dongle desaparece tras un _power-cycle_ o _suspend_

Síntomas: `docker logs zigbee2mqtt` muestra `Failed to communicate with adapter` después de horas funcionando bien.

- **El _symlink_ `by-id` cambió** porque el kernel renumeró los puertos USB. Improbable si sólo hay un dongle, pero ocurre si el operador desconectó/conectó otros dispositivos USB. Comprobar:
  ```bash
  readlink -f "$(grep ^Z2M_USB_DEVICE ~/homelab/domotica/.env | cut -d= -f2)"
  # debería seguir resolviendo a un /dev/ttyUSB* real
  ```
  Si el _symlink_ ya no existe, el dongle se ha desenchufado físicamente. Reconectar y `docker compose restart zigbee2mqtt`.

- **El device dentro del contenedor está "stale"**: Docker no re-mountea el device si el _symlink_ se rompe y se vuelve a crear. Recrear el contenedor:
  ```bash
  docker compose -f ~/homelab/domotica/docker-compose.yml up -d --force-recreate zigbee2mqtt
  ```

### El _frontend_ vía `https://zigbee2mqtt.lan/` no responde

- **Authelia bloquea**: comprobar `docker logs authelia --tail 30` por errores de configuración.
- **Caddy no resuelve `zigbee2mqtt:8080`**: comprobar que Z2M está en la red `homelab`. `docker network inspect homelab | grep zigbee2mqtt` debe mostrar el contenedor.
- **El _frontend_ no está habilitado en `configuration.yaml`**: confirmar `frontend.enabled: true`.
- **WebSocket bloqueado**: `docker logs caddy | grep -i websocket` busca rechazos. Si hay alguno, comprobar que ningún `header_up Connection close` se coló en el bloque (el Caddy `reverse_proxy` v2 maneja WS automáticamente).

### MQTT _autodiscovery_ no llega a HA

- **Z2M no publica los `homeassistant/...`**: comprobar que `homeassistant.enabled: true` en `configuration.yaml` y que el usuario `zigbee2mqtt` tiene `readwrite homeassistant/#` en la ACL de Mosquitto (ver `docs/08-domotica/02-mosquitto.md`, sección **`acl`**).
- **HA no escucha**: comprobar que la integración MQTT está activa (Settings → Devices & services → MQTT) y que `discovery: true` está habilitado.
- **Topics _retained_ obsoletos**: si tras des-emparejar un dispositivo, HA sigue mostrando entidades fantasma, los _retained_ del autodiscovery no se han borrado. Limpiar manualmente:
  ```bash
  mosquitto_pub -h 192.168.1.3 -u homeassistant -P <password> \
    -t 'homeassistant/sensor/<device_id>/temperature/config' -m '' -r -n
  ```
  HA elimina la entidad fantasma. Repetir para cada componente.

### `coordinator_backup.json` no se genera

- Z2M genera el backup automáticamente cada vez que la red Zigbee cambia. Si nunca se ha emparejado nada, el fichero **no existe**, y eso es esperado.
- Tras el primer pairing, debería aparecer en <30 s. Si no, comprobar que `/mnt/hd2t/services/zigbee2mqtt/` es escribible por `1000:1000` (ver **Estructura**).

### Z2M monopoliza CPU al arranque

Síntomas: `top` muestra `node` (Z2M) al 80–100 % de un core durante 30–60 s tras `docker start`.

Es **normal**: Z2M está cargando el `database.db` (con todos los _quirks_ de los dispositivos), validando el `configuration.yaml`, conectando con el coordinator y publicando el `bridge/state online`. Pasados los 60 s, debería caer a <5 % en idle. Si persiste alto, comprobar la profundidad de la red Zigbee (>50 dispositivos requiere más CPU continua) o un dispositivo concreto _spammeando_ (ver _Devices → <device> → Last seen_; si publica cada segundo, tiene un _reporting interval_ mal configurado).

---

## Actualización

### Bumps de _patch_ (`1.40.1 → 1.40.2`)

```bash
# 1. Leer el changelog upstream
xdg-open https://github.com/Koenkk/zigbee2mqtt/releases

# 2. Actualizar el .env
$EDITOR ~/homelab/domotica/.env
# Z2M_IMAGE_TAG=1.40.2

# 3. Pull y recreate
cd ~/homelab
make pull STACK=domotica
make up STACK=domotica

# 4. Verificar
docker logs zigbee2mqtt --tail 30
docker compose -f ~/homelab/domotica/docker-compose.yml ps zigbee2mqtt
```

El recreate dura 10–20 s. Mosquitto sigue intacto (no se reinicia). HA detecta la breve desconexión MQTT de Z2M y reconecta cuando el `bridge/state online` vuelve. Los dispositivos Zigbee no notan nada.

### Bumps de _minor_ (`1.40.x → 1.41.y`)

- **Backup explícito previo** — crítico, porque migraciones de _schema_ ocurren en _minor_:
  ```bash
  sudo /usr/bin/borgmatic --verbosity 1
  ```
- Leer el _changelog_ buscando **Breaking changes**.
- `docker compose pull && docker compose up -d zigbee2mqtt`.
- Tras el upgrade, verificar el `database.db`:
  ```bash
  sudo head /mnt/hd2t/services/zigbee2mqtt/database.db
  # cada línea es un objeto JSON; debe parsear con `jq -e .` cada una.
  ```
- Si Z2M se queja al arrancar (`Database corrupted`), restaurar el _archive_ Borg anterior y reportar el problema al upstream.

### Cambio de adaptador (CC2531 → CC2652P, p. ej.)

Migrar entre familias de _coordinator_ requiere re-emparejamiento total. Procedimiento:

1. Anotar todos los dispositivos actuales (`Settings → Devices` → exportar lista).
2. Stop Z2M: `docker compose stop zigbee2mqtt`.
3. Mover `/mnt/hd2t/services/zigbee2mqtt/{database.db,state.json,coordinator_backup.json}` a `*.old`.
4. Cambiar el dongle físicamente.
5. Actualizar `Z2M_USB_DEVICE` en `.env`.
6. Levantar Z2M: `docker compose up -d zigbee2mqtt`. Empezará con red vacía y `coordinator_backup.json` nuevo.
7. Re-emparejar cada dispositivo (factory reset físico de cada uno, _Permit join_ desde la UI). Usar los _friendly names_ originales para que las entidades en HA se reusen.

> **Migración entre dongles del mismo chip** (p. ej. Sonoff Plus → Sonoff Plus E): el `coordinator_backup.json` permite mover la red sin re-emparejar (ver **Backup → Cambio de dongle Zigbee**). La pérdida es 0 dispositivos.

---

## Referencias

- Documentación oficial — Zigbee2MQTT: <https://www.zigbee2mqtt.io/>
- Configuración (`configuration.yaml`): <https://www.zigbee2mqtt.io/guide/configuration/>
- Adaptadores soportados: <https://www.zigbee2mqtt.io/guide/adapters/>
- Imagen oficial — `koenkk/zigbee2mqtt`: <https://hub.docker.com/r/koenkk/zigbee2mqtt>
- Releases (changelogs): <https://github.com/Koenkk/zigbee2mqtt/releases>
- `zigbee-herdsman` (capa Zigbee subyacente): <https://github.com/Koenkk/zigbee-herdsman>
- `zigbee-herdsman-converters` (catálogo de dispositivos): <https://github.com/Koenkk/zigbee-herdsman-converters>
- Z-Stack firmware (para Sonoff Plus / TI CC2652): <https://github.com/Koenkk/Z-Stack-firmware/>
- MQTT autodiscovery de Home Assistant: <https://www.home-assistant.io/integrations/mqtt/#mqtt-discovery>
- SONOFF Zigbee 3.0 USB Dongle Plus (chip CC2652P): <https://itead.cc/product/zigbee-3-0-usb-dongle/>
- Documentos relacionados del homelab:
  - `docs/00-hardware/01-material-necesario.md` — adaptador Zigbee USB recomendado.
  - `docs/00-hardware/02-esquema-conexiones.md` — alargador USB ≥1 m a USB 2.0, separación de USB 3.0 por interferencias 2,4 GHz.
  - `docs/01-sistema/04-estructura-directorios.md` — árbol `/mnt/hd2t/services/zigbee2mqtt/`.
  - `docs/02-docker/02-estructura-compose.md` — convenciones del _stack_ `domotica`, redes Docker.
  - `docs/02-docker/04-watchtower.md` — Z2M en la lista nominal de _opt-out_.
  - `docs/03-red/04-caddy.md` — bloque `zigbee2mqtt.lan`, _snippets_.
  - `docs/04-seguridad/01-authelia.md` — `forward_auth` (`import authelia`), regla `two_factor` para `zigbee2mqtt.lan`.
  - `docs/05-monitorizacion/05-uptime-kuma.md` — _monitor_ HTTP a `http://zigbee2mqtt:8080/` o MQTT a `zigbee2mqtt/bridge/state`.
  - `docs/05-monitorizacion/06-dozzle.md` — logs del contenedor visibles en tiempo real.
  - `docs/07-backups/02-borgmatic.md` — `source_directories: /mnt/hd2t/services` cubre Z2M.
  - `docs/07-backups/03-backup-docker-volumes.md` — Categoría F (filesystem-only); bloque comentado en `dump-databases.sh`.
  - `docs/08-domotica/01-home-assistant.md` — HA con integración MQTT activa, recibe entidades de Z2M por autodiscovery.
  - `docs/08-domotica/02-mosquitto.md` — broker MQTT, usuario `zigbee2mqtt` con ACL `readwrite zigbee2mqtt/#` y `readwrite homeassistant/#`, red `domotica-internal`.
  - `docs/08-domotica/04-node-red.md` (siguiente fase) — flujos visuales que pueden suscribirse a `zigbee2mqtt/#` para automatizaciones avanzadas.
