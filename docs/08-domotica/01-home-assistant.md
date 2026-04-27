# Home Assistant Container (plataforma de domótica)

## Descripción

Despliegue de **Home Assistant** (HA) en su variante **Container** (imagen oficial `homeassistant/home-assistant`, sin Supervisor ni HAOS) como **plataforma central de domótica** del homelab: motor de _state machine_ para entidades, cuadro de mandos (Lovelace), sistema de automatizaciones, escenas y _scripts_, integraciones con dispositivos locales y _cloud_, y _backend_ de la app móvil oficial. Toda la configuración persistente (`/config`) vive en el disco externo **hd2t** (`/mnt/hd2t/services/home-assistant/`), nunca en la microSD: la BD del _recorder_ (SQLite) escribe miles de filas/min y mataría el _flash_ en pocos meses.

Este documento **estrena el _stack_ `domotica`** (`~/homelab/domotica/`) descrito en `docs/02-docker/02-estructura-compose.md` (tabla de stacks, fila `domotica`, fase `docs/08-domotica/`). El _stack_ alojará en fases siguientes a Mosquitto (`02-mosquitto.md`), Zigbee2MQTT (`03-zigbee2mqtt.md`) y Node-RED (`04-node-red.md`); aquí se materializa **únicamente** el contenedor `home-assistant` y las _piezas_ que necesita para arrancar limpio (`configuration.yaml` inicial, _bind mount_, bloque del `Caddyfile`).

Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone HA en `https://home-assistant.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), MagicDNS resuelve `pi.<tailnet>.ts.net` y desde ahí se llega al mismo backend; HA aprende la IP de origen real porque `http.use_x_forwarded_for` y `http.trusted_proxies` están configurados (sección **Decisiones de diseño**).

> **Alcance**: este documento despliega Home Assistant Container con su autenticación nativa (usuarios + 2FA TOTP), configura el `recorder` SQLite con retención conservadora, aplica el endurecimiento HTTP propio de HA detrás de un _reverse proxy_, y deja una lista corta de **integraciones básicas** (Sun, Met.no como _weather_, _Workday_, System Monitor) instaladas desde la UI o vía YAML. **No** instala Mosquitto (`docs/08-domotica/02-mosquitto.md`), **no** instala Zigbee2MQTT (`docs/08-domotica/03-zigbee2mqtt.md`), **no** instala Node-RED (`docs/08-domotica/04-node-red.md`). **No** delega autenticación a Authelia vía `forward_auth` (rompería la app móvil y los _webhooks_; ver **Decisiones de diseño**). **No** activa la integración de _backups_ propia de HA (que sólo existe en HAOS/Supervised) — los respaldos los hace Borgmatic (`docs/07-backups/02-borgmatic.md`) en frío sobre el _bind mount_ + dump SQLite vía hook (`docs/07-backups/03-backup-docker-volumes.md`). **No** configura HACS (Home Assistant Community Store): es un _addon_ no oficial que se sale del flujo "imagen oficial pinneada"; si más adelante hace falta una integración del _community store_, se documenta aparte.

> **Recordatorio de red**: HA **no se publica al host**. Caddy lo alcanza por DNS interno de Docker (`home-assistant:8123` en la red `homelab`). Pi-hole resuelve `home-assistant.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`). El operador entra siempre por `https://home-assistant.lan/` (LAN) o por el nombre _MagicDNS_ del nodo Tailscale.

---

## Requisitos previos

- `docs/02-docker/02-estructura-compose.md` completado: la tabla de _stacks_ reserva el _slot_ `domotica` que aquí se estrena, la red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) externa está creada, `~/homelab/.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `HOMELAB_DOMAIN=lan` está rellenado, y el _Makefile_ de operación expone `make up STACK=<stack>`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/home-assistant/` ya existe vacío con ownership `root:root 0755` (la tabla de UIDs internos de aquel doc anota explícitamente que `home-assistant` corre como `root` y deja la inicialización del árbol al propio contenedor).
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada y por defecto desactivada. HA será **opt-out** explícito (ver **Decisiones de diseño**).
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `home-assistant.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile` y la CA local firma `*.lan`.
- `docs/04-seguridad/01-authelia.md` completado **opcionalmente**: si Authelia ya está montado, en este documento se decide explícitamente **no** poner HA detrás de `forward_auth`. Si Authelia aún no está montado, no pasa nada — HA trae su propia autenticación. La línea `# - 'home-assistant.lan'` que el doc de Authelia dejó comentada en la lista de `two_factor` **se mantiene comentada para siempre**: HA no entra ahí.
- `docs/07-backups/02-borgmatic.md` y `docs/07-backups/03-backup-docker-volumes.md` completados (recomendado): el `source_directories: /mnt/hd2t/services` ya engloba `home-assistant/` y el _hook_ `dump-databases.sh` tiene el bloque comentado para SQLite del `recorder`. Este doc termina **descomentando** ese bloque.
- Conectividad saliente para descargar la imagen (sólo la primera vez):

  ```bash
  docker pull --platform linux/arm64 homeassistant/home-assistant:2026.4 >/dev/null && echo OK
  ```

- Que el host **no** tenga ya un servicio escuchando en `:8123`:

  ```bash
  sudo ss -tulpn '( sport = :8123 )'
  ```

  Salida esperada: vacía. HA Container no publica `:8123` al host (Caddy lo alcanza por DNS interno), pero conviene confirmar que ningún binario residual lo ocupa por si más adelante el operador, durante un _troubleshoot_, añadiese un `ports: ["8123:8123"]` improvisado.

- Espacio en `/mnt/hd2t`: como mínimo **2 GB libres** para que HA arranque cómodo. La cuota real la dictan el `recorder` (SQLite crece con el número de entidades × frecuencia de cambio) y los _snapshots_ que el operador genere; en estado estable, `/mnt/hd2t/services/home-assistant/` se mantiene típicamente entre **1 y 5 GB** (ver `docs/07-backups/01-estrategia-backup.md`, tabla de tamaños esperados).

  ```bash
  df -h /mnt/hd2t
  ```

---

## Decisiones de diseño

### Por qué Home Assistant Container (y no HAOS / Supervised / openHAB / Domoticz)

El homelab necesita una **plataforma de domótica** que cubra al menos: motor de automatización con _state machine_, integraciones para Zigbee/MQTT (delegadas a Z2M en su propio doc), app móvil oficial con _push notifications_ y _location tracking_, soporte para sensores meteorológicos / horarios / calendarios, y posibilidad futura de extenderse con _scripts_ Python o flujos visuales (Node-RED). Cuatro alternativas descartadas y por qué:

| Candidato                        | Por qué se descarta                                                                                                                                                                                                                                                                                                                                |
|----------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Home Assistant OS (HAOS)**     | Sistema operativo dedicado: la Pi sólo ejecutaría HA, perdiendo todo el resto del homelab. Filosofía contraria al proyecto.                                                                                                                                                                                                                       |
| **Home Assistant Supervised**    | Modo intermedio que monta HA en una Debian _propia_ con _Supervisor_, _addons_ y la integración de _backups_ nativa, pero **exige** una distribución muy concreta (Debian 12 vainilla con paquetería específica) y `docker-ce` gestionado por el _Supervisor_. Conflicto directo con el `docker-ce` instalado por `docs/02-docker/01-instalacion-docker.md`, que sirve a otros 25 contenedores. **Inadecuado** para un homelab _multi-servicio_. |
| **openHAB**                      | Alternativa veterana, escrita en Java/OSGi. Ecosistema sólido pero comunidad notablemente más pequeña, _store_ de _bindings_ menos cuidado y app móvil menos pulida. Footprint Java pesa ~600 MB vs ~250 MB de HA Container.                                                                                                                       |
| **Domoticz**                     | Ligero (~80 MB) y veterano, pero ecosistema de plugins muy reducido en 2026; pocos sensores nuevos llegan con plantilla _out-of-the-box_. La UI es notablemente más austera y la app móvil es de comunidad.                                                                                                                                       |

Home Assistant Container gana por:

- **Ecosistema de integraciones** más grande de la categoría (>3000 _core integrations_ + _community_), con la mayoría manteniéndose con _release notes_ por el equipo de Nabu Casa.
- **App móvil oficial** (Android + iOS) con `device_tracker`, sensores del propio teléfono (batería, conectividad, pasos…) y _push notifications_ vía el _backend_ de Nabu Casa o un _webhook_ propio.
- **Comunidad activa** con _blueprints_ (plantillas de automatización), foros, Discord y _release notes_ mensuales en blog.
- **Imagen Docker oficial multi-arch ARM64** publicada por el equipo de HA en Docker Hub (`homeassistant/home-assistant`), sin recurrir a forks de comunidad ni _builds_ de terceros.
- **Modo Container es soportado de primera clase**: la documentación cubre explícitamente el caso "HA detrás de un _reverse proxy_ con `use_x_forwarded_for` y `trusted_proxies`", incluyendo limitaciones y _workarounds_.

### Imagen y _tag_

- **`homeassistant/home-assistant:2026.4`** — HA versión **2026.4** (release de abril 2026), la línea _mainstream_ activa. Multi-arch (`linux/arm64`). Pinneada a _tag_ "año.mes" siguiendo la convención del homelab (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`, "Tag mayor o LTS"). HA no publica una línea LTS formal — la cadencia de releases es **mensual**, los _bumps_ del año (`2026.5`, `2026.6`, …) llegan cada último jueves de mes.
- **Por qué no `:stable`**: ese _tag_ se mueve cada mes a la última versión publicada; un `docker compose pull` accidental podría introducir cambios de _breaking_ sin que el operador haya leído las _release notes_. El _tag_ explícito `2026.4` lo evita.
- **Por qué no `:beta`**: la línea _beta_ se publica una semana antes que la _stable_; instalarla en un homelab que da servicio a personas reales no aporta valor y multiplica el riesgo de bugs.
- **Bumps mensuales — política**: cada mes se lee el _release blog_ oficial (<https://www.home-assistant.io/blog/>), la sección **Backward-incompatible changes** y, si no hay nada que afecte a las integraciones activas, se actualiza el `.env` (`HA_IMAGE_TAG=2026.5`) y se hace `make pull STACK=domotica && make up STACK=domotica`. Ver **Actualización** más abajo para el _checklist_.

#### Watchtower opt-out

Razones:

- **Bumps mensuales con _breaking changes_ ocasionales**: HA suele anunciar 1–3 _breaking changes_ por _release_. Un `pull` automático a `2026.5` sin haber leído las _release notes_ deja entidades huérfanas, automatizaciones rotas o el `recorder` migrado a un _schema_ que la versión vieja no entiende (downgrades casi nunca son posibles). **Las actualizaciones se hacen a mano**, leyendo el blog y haciendo backup completo del `/config` previo.
- **Migraciones del _recorder_**: muchos _bumps_ ejecutan `ALTER TABLE` sobre la SQLite del `recorder` en el primer arranque. Si la BD es grande (varios GB), la migración tarda minutos durante los cuales HA sigue _starting_ y el `healthcheck` puede dar falsos positivos de fallo.
- **Custom integrations / custom cards**: si en el futuro se añade alguna integración _custom_ vía YAML (no HACS, pero descargada manualmente a `custom_components/`), un _bump_ rompe esas integraciones cuando el desarrollador no las ha actualizado a la nueva _core API_.

Etiquetar el contenedor con `com.centurylinklabs.watchtower.enable: "false"`. Coherente con la lista global de `docs/02-docker/04-watchtower.md` (sección _Servicios que se mantienen en opt-out_, donde Home Assistant aparece nominalmente).

### Modo de red: `bridge` (red `homelab`), no `host`

Decisión opinada y la más debatida de este documento. Las dos opciones razonables:

| Opción                              | Ventajas                                                                                                                       | Inconvenientes                                                                                                                                                                                                                                                                |
|-------------------------------------|---------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **`network_mode: host`**            | Auto-discovery por _multicast DNS_ (mDNS) y SSDP funciona _out-of-the-box_ (Sonos, Apple TV, Chromecast, HomeKit Bridge, Plex, …). Algunos protocolos de descubrimiento dependen de paquetes _broadcast_ que no atraviesan el _bridge_ Docker. | Rompe el patrón "Caddy delante de cada servicio" — HA escucharía en `192.168.1.3:8123` directamente. Caddy puede _reverse-proxy_ a esa IP, pero hay que mantener la IP estática y abrir un agujero en `nftables` para el `:8123`. Además, expone HA al host: cualquier proceso local (otro contenedor con `--network host`, un script `cron`) puede pinchar la API sin Caddy. |
| **`bridge` en red `homelab`** ✅    | Coherente con todos los demás servicios (Nextcloud, Authelia, Caddy, …): HA se alcanza por DNS interno (`home-assistant:8123`), no expone puertos al host, Caddy es el _único_ camino al servicio. Aislamiento limpio.                          | Auto-discovery mDNS/SSDP **no** atraviesa el `bridge`. Las integraciones que dependen de descubrimiento por _multicast_ deben configurarse **manualmente** introduciendo la IP del dispositivo. Para Bluetooth se necesita `--device /dev/...` aparte (no se usa aquí).     |

Se elige `bridge`. La pérdida del auto-discovery se compensa con configuración manual: la mayoría de integraciones aceptan `host: 192.168.1.50` además del descubrimiento. Para los casos donde `host` networking sea estrictamente necesario (HomeKit Bridge actuando como _accessory_ con paquetes broadcast, _AirPlay_ receiver), la solución _idiomática_ es montar un **segundo contenedor** con `network_mode: host` para esa integración concreta (un _add-on_ específico, no HA entero). Eso queda **fuera de alcance** y se documentaría en un `docs/08-domotica/05-discovery-avanzado.md` futuro si llega a hacer falta.

> **Cuándo NO basta el bridge**: HomeKit Bridge `homekit` (HA expuesto como _accessory_ a la app Casa de iOS), AirPlay, _Bonjour_/Zeroconf agresivo. Si esas son requisitos del primer día, releer esta sección y considerar la opción `host`. Para automatización doméstica básica con dispositivos Zigbee (vía Z2M) y MQTT (vía Mosquitto), el _bridge_ es perfectamente suficiente.

### `http.use_x_forwarded_for` + `http.trusted_proxies`

HA, al estar detrás de Caddy, ve el tráfico interno como **HTTP plano** desde la red Docker (`172.20.10.x`). Si no se le dice lo contrario:

- Logueará "todo el mundo viene de la IP del contenedor de Caddy", inutilizando el log de auditoría.
- Las _cookies_ y _CSRF tokens_ se asocian a la IP equivocada, lo que puede romper la sesión cuando el operador cambia de WiFi a 4G en el móvil.
- El _rate-limiter_ interno y el _ban_ por _failed login_ aplican _por contenedor de Caddy_, lo que en la práctica desactiva el _ban_ (todas las peticiones vienen de la misma IP).

Tres claves en `configuration.yaml` cierran el caso:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.20.10.0/24       # subnet de la red Docker 'homelab'
    - 127.0.0.1            # llamadas internas (entrypoint, healthcheck)
  ip_ban_enabled: true
  login_attempts_threshold: 5
```

`trusted_proxies` es **crítico**: HA ignora `X-Forwarded-For` por defecto a menos que la fuente esté en esta lista. Sin la entrada `172.20.10.0/24`, todas las peticiones de Caddy (que cambia de IP en cada `up -d`) se loguean como "Caddy" y la cabecera real se descarta. Con la subnet entera se confía en cualquier proxy que pertenezca a la red `homelab`, sin tener que pinear la IP exacta de Caddy.

> **Por qué la subnet entera y no sólo la IP del contenedor Caddy**: misma argumentación que en `docs/06-almacenamiento/01-nextcloud.md` — Docker no garantiza IPs estáticas en un `bridge` por defecto, pinearlas requiere `ipv4_address` con coste operativo desproporcionado para un beneficio marginal (el "ataque" sería que otro contenedor de la red `homelab` se autodeclare Caddy, ya descartado por el modelo de confianza intra-_stack_).

### `forward_auth` con Authelia: **NO** para Home Assistant

Tentación natural una vez Authelia está montada: añadir `import authelia` al bloque `home-assistant.lan` del `Caddyfile`. **No se hace**, exactamente por las mismas razones que Nextcloud:

- **La app móvil oficial de Home Assistant** habla con HA por **WebSocket** (canal persistente para _real-time state updates_) usando un **Long-Lived Access Token** (Bearer) que se genera dentro de HA. La app **no** sabe redirigirse a un portal _web_, no resuelve un challenge OIDC, no rellena un formulario HTML. Si Caddy intercepta el _upgrade_ a WebSocket y devuelve `302 Location: https://auth.lan/?rd=...`, la app falla en bucle y el operador pierde el control de su casa desde el móvil.
- **Los _webhooks_ entrantes** (HA recibe `POST /api/webhook/<id>` desde dispositivos externos: cámaras IP, sensores _push_, integraciones tipo IFTTT) usan el _id_ del webhook como autenticación. Tampoco siguen redirects HTML.
- **La integración con asistentes externos** (Google Assistant, Alexa) — si llega a configurarse vía Nabu Casa Cloud — abre _channels_ específicos que tampoco entienden de OIDC delante.
- **La integración Companion App** de iOS/Android usa _Bearer tokens_ exclusivamente.

Solución correcta: **HA autentica con su sistema nativo** (usuario + contraseña + 2FA TOTP de la integración `mfa_module: totp`). Los _Long-Lived Access Tokens_ que la app móvil utiliza se generan desde **Mi Perfil → Tokens de Acceso de Larga Duración** y son independientes de la sesión web (sobreviven a logout / cambio de password). Para SSO con Authelia más adelante, HA tiene la integración `auth_oidc` en HACS o `oidc-auth-for-home-assistant`; esa migración se documentará aparte si se valora necesaria, pero **los tokens de la app móvil seguirán siendo nativos** (mismo patrón que Nextcloud y sus _app passwords_).

> **Resumen operativo**: el bloque `home-assistant.lan` del `Caddyfile` lleva `import security-headers` y `import logging`, pero **no** `import authelia`. Caddy actúa como _reverse proxy_ "tonto" que termina TLS y propaga `X-Forwarded-*`; HA autentica.

### Recorder: SQLite (no MariaDB/PostgreSQL) con retención conservadora

HA soporta tres _backends_ de `recorder`: SQLite (default), MariaDB/MySQL, PostgreSQL. Elección: **SQLite**. Razones:

- **Es el default y la documentación oficial está pensada para él**. Las migraciones de _schema_ que HA dispara en cada _release_ están testadas en SQLite por todo el ecosistema; en MariaDB/Postgres a veces aparecen sutilezas (índices que no se generan, `bigint` vs `integer` en columnas de timestamps).
- **Footprint mínimo**: SQLite vive _in-process_, sin contenedor extra. Para 1–2 personas y 50–200 entidades, una BD SQLite se mantiene en 100–500 MB con `purge_keep_days: 14`. Sin sentido provisionar un MariaDB para esto.
- **Backups triviales**: el Patrón S de `docs/07-backups/03-backup-docker-volumes.md` (`sqlite3 .backup`) hace una copia consistente _online_ sin parar HA.
- **Cuando crece demasiado**: si el operador empieza a tener miles de entidades (raro en una casa), la migración a MariaDB/Postgres es cambiar `recorder.db_url` y dejar que HA inicialice el _schema_ nuevo. **No bloqueante hoy.**

Configuración del `recorder` en `configuration.yaml` (sección **`configuration.yaml` inicial**):

```yaml
recorder:
  purge_keep_days: 14         # mantener 2 semanas de histórico
  commit_interval: 30         # agrupa escrituras en lotes de 30 s (menos IOPS al disco)
  exclude:
    domains:
      - automation
      - updater
      - persistent_notification
    entity_globs:
      - sensor.uptime_*
      - sensor.last_boot
```

> **Por qué `purge_keep_days: 14`**: balance entre "ver qué pasó la semana pasada en el panel de la caldera" y "no llenar el disco". Si el operador descubre que necesita _logbook_ más largo, puede subirlo a 30; si descubre que no usa el histórico, puede bajarlo a 7. La cifra se expone como variable `.env` para no tener que editar el YAML.

> **Por qué `commit_interval: 30`**: por defecto HA hace `INSERT` + `COMMIT` por cada cambio de estado, lo que en un sistema con 100 entidades activas se traduce en cientos de _fsyncs_ por minuto al disco USB (y a la SQLite). Agruparlos cada 30 s reduce los IOPS por un factor 10× sin pérdida funcional (una pérdida de luz que no llega a registrarse durante esos 30 s es un _trade-off_ aceptable; los 30 s anteriores **sí** están persistidos).

### Watchtower opt-out, ya cubierto arriba

(Ver _Imagen y tag_.)

### Almacenamiento

| Ruta en el host                                  | Contenido                                                            | Versionable           | Backup                              |
|--------------------------------------------------|----------------------------------------------------------------------|-----------------------|-------------------------------------|
| `~/homelab/domotica/docker-compose.yml`          | Definición del _stack_                                               | git                   | git                                 |
| `~/homelab/domotica/.env`                        | Imágenes pinneadas + variables del _stack_                           | **NO** (`.gitignore`) | git aparte (nota local)             |
| `~/homelab/domotica/.env.example`                | Plantilla con nombres de variables, sin valores                      | git                   | git                                 |
| `/mnt/hd2t/services/home-assistant/configuration.yaml` | Configuración principal de HA (gestionada por la UI + edición manual) | **NO** versionable    | **Sí** (Borgmatic)                  |
| `/mnt/hd2t/services/home-assistant/secrets.yaml` | Tokens, passwords y _api keys_ (referenciados como `!secret xxx`)    | **NO** versionable    | **Sí** (Borgmatic — fichero crítico) |
| `/mnt/hd2t/services/home-assistant/.storage/`    | Estado serializado: usuarios, dispositivos emparejados, integraciones configuradas vía UI | **NO**                | **Sí** (Borgmatic, con _exclude_ para `auth_provider.homeassistant` rotado, ver `03-backup-docker-volumes.md`) |
| `/mnt/hd2t/services/home-assistant/home-assistant_v2.db` | BD SQLite del _recorder_ (estados, eventos, estadísticas)            | **NO**                | **Sí** (Borgmatic vía dump)         |
| `/mnt/hd2t/services/home-assistant/home-assistant.log*` | Logs rotados                                                         | **NO**                | **NO** — excluidos por `exclude_patterns` |

> **`secrets.yaml` con permisos `0600`**: contendrá tokens de la API de Met.no/AEMET, passwords de routers/cámaras, _long-lived tokens_ generados por HA para integraciones internas. Tras el primer arranque, ajustar permisos:
>
> ```bash
> sudo chmod 0600 /mnt/hd2t/services/home-assistant/secrets.yaml
> sudo chown root:root /mnt/hd2t/services/home-assistant/secrets.yaml
> ```
>
> El contenedor corre como root (ver `docs/01-sistema/04-estructura-directorios.md`, tabla _UIDs internos_), así que sigue pudiendo leerlo.

> **`home-assistant.log*` excluidos**: ya están en el `exclude_patterns: '*/cache/*'` global de Borgmatic más la entrada explícita `**/home-assistant.log*` que añade este doc al `config.yaml` del propio Borgmatic (ver sección **Backup**).

---

## Estructura del _stack_ `domotica` tras este documento

```
~/homelab/domotica/
├── docker-compose.yml        # ← nuevo
├── .env                      # ← nuevo (NO versionado)
├── .env.example              # ← nuevo (versionado)
└── .gitignore                # ← nuevo (excluye .env)
```

Y en los discos externos, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/home-assistant/
├── (vacío al empezar; el primer arranque puebla
│   configuration.yaml, .storage/, home-assistant_v2.db, …)
```

Crear el subdirectorio del _stack_ y los _stubs_ de gitignore:

```bash
mkdir -p ~/homelab/domotica
chmod 0750 ~/homelab/domotica

cat > ~/homelab/domotica/.gitignore <<'EOF'
# Secretos del stack — NUNCA commitear
.env
EOF
```

> **Ownership de `/mnt/hd2t/services/home-assistant/`**: la imagen oficial de HA corre como `root` y hace `chown root:root` recursivo de su propio subárbol en el primer arranque. **No** hay que pre-`chown`-ear desde el host. Lo que sí hay que verificar es que `root:root 0755` del raíz `/mnt/hd2t/services/home-assistant/` permita al contenedor entrar — `0755` lo cumple.

---

## Variables de entorno

Crear `~/homelab/domotica/.env.example` (versionado en git, sin valores reales ni secretos):

```bash
# --- Imágenes pinneadas -----------------------------------------------------
# Bumps mensuales: leer https://www.home-assistant.io/blog/ antes de cambiar.
HA_IMAGE_TAG=2026.4

# --- Home Assistant ---------------------------------------------------------
# URL pública canónica del servicio. Coincide con el bloque del Caddyfile y
# con el wildcard *.lan que Pi-hole resuelve a 192.168.1.3.
HA_BASE_URL=https://home-assistant.lan
HA_INTERNAL_URL=https://home-assistant.lan

# Subnet de la red Docker 'homelab' (creada en docs/02-docker/02-estructura-compose.md).
# Fijada ahí en 172.20.10.0/24. Va al `http.trusted_proxies` de configuration.yaml.
HA_TRUSTED_PROXY_SUBNET=172.20.10.0/24

# Retención del recorder en días. 14 = compromiso histórico/disco. Subir si se
# necesita logbook más largo, bajar si el disco se acerca al tope.
HA_RECORDER_KEEP_DAYS=14
```

Copiar a `.env` y mantener los valores reales:

```bash
cp ~/homelab/domotica/.env.example ~/homelab/domotica/.env
chmod 0600 ~/homelab/domotica/.env
```

> **`.env` aquí no contiene secretos** (HA gestiona los suyos en `secrets.yaml`, no en variables de entorno). Aun así, se mantiene `0600` y fuera de git por consistencia con el resto de _stacks_ y por si futuros servicios del propio _stack_ (Mosquitto con _password_) lo necesitan.

> **No commitear `.env` jamás**. El `.gitignore` del _stack_ ya lo excluye explícitamente.

---

## `~/homelab/domotica/docker-compose.yml`

```yaml
---
# Stack: domotica — Home Assistant Container
# Documentación: docs/08-domotica/01-home-assistant.md
# (Mosquitto, Zigbee2MQTT y Node-RED se añaden en docs siguientes.)

services:

  # ---------------------------------------------------------------------------
  # Home Assistant Container — plataforma de domótica.
  # En 'homelab' (Caddy la alcanza por nombre); sin red privada de stack porque
  # de momento HA es el único servicio. Se añadirá 'domotica-internal' cuando
  # llegue Mosquitto.
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
      # Hora del host (HA registra eventos con timestamp; clave la coincidencia).
      - /etc/localtime:/etc/localtime:ro
    networks:
      homelab:
        aliases:
          - home-assistant     # Caddy resuelve 'home-assistant:8123' por este alias
    labels:
      homelab.stack: "domotica"
      homelab.backup: "true"   # /mnt/hd2t/services/home-assistant entra en Borgmatic
      # Opt-out: bumps mensuales pueden romper integraciones; manual con release notes.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      # /api/ devuelve {"message":"API running."} con un GET autenticado, pero
      # devuelve 401 sin token. /manifest.json es público y sirve igual de bien
      # como _liveness probe_ (llega 200 desde el momento en que el frontend
      # web está sirviendo).
      test:
        - CMD-SHELL
        - "wget -qO- --tries=1 --timeout=5 http://localhost:8123/manifest.json | grep -q 'Home Assistant' || exit 1"
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s   # primer arranque: instala dependencias Python, ~90 s
    # Dispositivos: ninguno aquí. El dongle Zigbee se mapea en zigbee2mqtt
    # (docs/08-domotica/03-zigbee2mqtt.md), no en HA. La Bluetooth on-board de
    # la Pi 5 se podrá exponer cuando una integración la necesite, vía
    # /var/run/dbus + privileged: true; queda fuera de alcance.

# ---------------------------------------------------------------------------
# Redes
# ---------------------------------------------------------------------------
networks:
  homelab:
    external: true               # creada en docs/02-docker/02-estructura-compose.md
  # NOTA: no se crea 'domotica-internal' por ahora. Cuando Mosquitto llegue
  # (docs/08-domotica/02-mosquitto.md) y necesite exponer un puerto MQTT
  # interno consumido sólo por HA / Z2M / Node-RED, se añadirá esa red privada
  # del stack.
```

Notas de diseño:

- **HA es el único servicio del _stack_ por ahora**. No hace falta `depends_on`. Cuando Mosquitto entre, HA tendrá `depends_on: mosquitto: condition: service_healthy` para que el broker esté listo antes de que la integración MQTT del propio HA intente conectarse.
- **Sin `ports:`**. Caddy alcanza HA por DNS interno (`home-assistant:8123`). Si el operador necesita acceder sin pasar por Caddy durante un _troubleshooting_, puede `docker exec -it home-assistant wget -qO- http://localhost:8123/manifest.json` desde dentro del propio contenedor.
- **`/etc/localtime:/etc/localtime:ro`**: además de `TZ`, montar `/etc/localtime` cubre algunas integraciones que leen la _zoneinfo_ por _glibc_ en lugar de por la variable de entorno. Ambas a la vez es la receta segura.
- **`start_period: 120s`** en `home-assistant`: la **primera** arrancada tarda ~90 s (HA detecta `/config` vacío, copia los _defaults_, baja un par de wheels Python). Con un `start_period` corto, el _healthcheck_ daría `unhealthy` espuriamente y Compose intentaría reiniciar el contenedor en plena instalación.
- **Watchtower opt-out**: razones explicadas en **Decisiones de diseño** → _Imagen y tag_.
- **No `mem_limit`**: en idle (sin Z2M, sin MQTT, con 5–10 entidades) HA consume ~250 MB. Tras añadir las integraciones de uso real, sube a ~400–600 MB. La política por defecto (sin límite) está bien para el _bootstrap_; cuando se sumen Mosquitto/Z2M/NodeRED y el _stack_ entero compita con Jellyfin/Nextcloud, se ajustarán los límites desde `docs/13-operaciones/03-rendimiento-pi5.md`.

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/domotica
docker compose --env-file ../.env --env-file .env config | head -40   # validar sintaxis
docker compose --env-file ../.env --env-file .env up -d
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=domotica
```

Vigilar el primer arranque (tarda ~90 s):

```bash
docker compose -f ~/homelab/domotica/docker-compose.yml logs -f home-assistant
# ...
# home-assistant  | Setting up with auto detected configuration
# home-assistant  | s6-rc: info: service legacy-services successfully started
# home-assistant  | [homeassistant.bootstrap] Home Assistant initialized in 89.24s
# home-assistant  | [homeassistant.core] Starting Home Assistant
```

Verificar que el contenedor está `(healthy)`:

```bash
docker compose -f ~/homelab/domotica/docker-compose.yml ps
# NAME              STATUS                   PORTS
# home-assistant    Up X seconds (healthy)
```

> El `(healthy)` lo otorga el _healthcheck_ que confirma que `/manifest.json` devuelve un fichero JSON con la cadena `"Home Assistant"`. Si tras 3 minutos sigue `starting`, ir a **Troubleshooting** → primer arranque.

### Caddy: bloque `home-assistant.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque:

```caddy
home-assistant.lan {
    tls internal
    import security-headers
    import logging

    # WebSocket — el frontend de HA (ws://.../api/websocket) y la app móvil usan
    # WebSocket sobre HTTPS. reverse_proxy de Caddy v2 soporta WS de forma
    # transparente (no requiere directiva especial). Documentado aquí para que
    # quien lea el Caddyfile sepa que este bloque _depende_ de WS.

    reverse_proxy home-assistant:8123 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # Subidas de adjuntos (snapshots de cámara, attachments en notificaciones)
        # — el default 8 KB de Caddy no aplica a reverse_proxy con WS. OK.
    }
}
```

Validar y recargar Caddy:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Probar (la CA local debe estar importada en el navegador, ver `docs/03-red/04-caddy.md`):

```bash
curl -k --resolve home-assistant.lan:443:192.168.1.3 \
     https://home-assistant.lan/manifest.json | head -c 200
# {"background_color":"#fafafa","description":"Home Assistant ...
```

Y desde el navegador: `https://home-assistant.lan/` → pantalla del **wizard de onboarding** de HA (no del _setup wizard_ inicial: la imagen ya pasó por ahí en el primer arranque del contenedor; aquí HA pide crear el primer usuario humano).

---

## Configuración tras primer arranque

### Onboarding

Login interactivo en `https://home-assistant.lan/`. La primera vez HA presenta:

1. **Crear cuenta de propietario** — usuario, _full name_, password robusta. Esta cuenta tendrá rol `owner` y permisos para crear más usuarios. Usar un username distinto de `admin` (HA lo recomienda; `admin` es objetivo trivial de _credential stuffing_).
2. **Establecer ubicación** — el _wizard_ pide ciudad y autodetecta lat/lon vía OpenStreetMap. Aceptar o ajustar manualmente.
3. **Unidades de medida** — métrico para España: temperatura `°C`, distancia `km`, presión `hPa`, _wind speed_ `m/s`. HA lo decide razonablemente por la ubicación.
4. **Privacy / analytics** — `analytics: false` por defecto. **No** activar; la opción envía estadísticas anónimas a Nabu Casa.
5. **Skip dispositivos descubiertos** — el wizard ofrece añadir lo que vea por SSDP/mDNS. Como estamos en `bridge`, no detectará nada interesante. **Skip** y configurar integraciones a mano más abajo.

Al terminar, HA aterriza en el dashboard por defecto con la entidad `sun.sun` y `weather.home` (Met.no autoinstalado) ya activas.

### Activar 2FA TOTP en el usuario _owner_

Imprescindible: HA accede desde fuera del LAN vía Tailscale, y la cuenta `owner` puede borrar usuarios y leer todos los _secrets_. Activar TOTP:

1. Click en el avatar (esquina inferior izquierda) → **Mi Perfil**.
2. Bajar hasta **Multi-factor authentication** → **Add module** → **Authenticator app**.
3. Escanear el QR con la app TOTP de confianza (la misma usada para Authelia o el gestor de contraseñas).
4. Introducir el código de 6 dígitos para confirmar.
5. **Guardar** los códigos de recuperación en Vaultwarden cuando esté disponible (de momento: papel + caja fuerte).

> **Por qué TOTP nativo y no FIDO2**: HA no soporta WebAuthn/FIDO2 nativamente en 2026 (aún se discute en el _issue tracker_). TOTP es la mejor opción de fábrica.

### Editar `configuration.yaml`

`/mnt/hd2t/services/home-assistant/configuration.yaml` se autogenera vacío en el primer arranque (el `default_config:` de HA carga ~30 integraciones esenciales). **Añadir** los bloques siguientes desde el host con un editor:

```bash
sudoedit /mnt/hd2t/services/home-assistant/configuration.yaml
```

```yaml
# Loads default set of integrations. Do not remove.
default_config:

# Load frontend themes from the themes folder
frontend:
  themes: !include_dir_merge_named themes

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml

# ---------------------------------------------------------------------------
# HTTP — Caddy delante, IPs reales en el log
# ---------------------------------------------------------------------------
http:
  server_host:
    - 0.0.0.0
  server_port: 8123
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.20.10.0/24
    - 127.0.0.1
  ip_ban_enabled: true
  login_attempts_threshold: 5

# ---------------------------------------------------------------------------
# Recorder — SQLite por defecto, retención y commits agrupados
# ---------------------------------------------------------------------------
recorder:
  purge_keep_days: 14
  commit_interval: 30
  exclude:
    domains:
      - automation
      - updater
      - persistent_notification
    entity_globs:
      - sensor.uptime_*
      - sensor.last_boot

# ---------------------------------------------------------------------------
# Logger — INFO por defecto, WARNING para integraciones ruidosas
# ---------------------------------------------------------------------------
logger:
  default: info
  logs:
    homeassistant.components.recorder: warning
    homeassistant.components.http: warning
    aiohttp.access: warning

# ---------------------------------------------------------------------------
# System Monitor — métricas de la propia Pi (CPU, memoria, disco, red).
# Las entidades aparecerán en sensor.* tras un restart.
# ---------------------------------------------------------------------------
sensor:
  - platform: systemmonitor
    resources:
      - type: disk_use_percent
        arg: /
      - type: memory_use_percent
      - type: processor_use
      - type: last_boot
      - type: ipv4_address
        arg: eth0

# ---------------------------------------------------------------------------
# Workday — sensor binario "es día laborable hoy". Útil para automatizaciones
# tipo "subir persianas a las 7:30 sólo si es laborable".
# ---------------------------------------------------------------------------
binary_sensor:
  - platform: workday
    country: ES
    province: MD            # ajustar a la provincia/comunidad autónoma real
    workdays: [mon, tue, wed, thu, fri]
    excludes: [sat, sun, holiday]
```

Validar la sintaxis sin reiniciar HA:

```bash
docker exec home-assistant python -m homeassistant --config /config --script check_config
# Configuration is valid.
```

Aplicar cambios:

- **Sin reiniciar el contenedor**: `Developer Tools → YAML → Reload all YAML configuration` (o `service: homeassistant.reload_all`). Esto recarga `automation:`, `script:`, `scene:`, `recorder:` y la mayoría de plataformas, pero **no** los cambios en `http:` ni en `default_config:` que requieren _restart_.
- **Reiniciar el contenedor**: `Developer Tools → Server controls → Restart Home Assistant` o, desde la CLI:
  ```bash
  docker compose -f ~/homelab/domotica/docker-compose.yml restart home-assistant
  ```
  El _restart_ tarda ~30 s en estado estable.

### Establecer `external_url` e `internal_url`

Con HA detrás de Caddy, hay que decirle a HA cómo se llama "desde fuera" y "desde dentro" para que las URLs absolutas que genera (en _push notifications_, en _share links_) sean correctas:

1. **Settings → System → General**.
2. **External URL**: `https://home-assistant.lan` (mismo nombre — el acceso vía Tailscale entra por `home-assistant.lan` resuelto por MagicDNS hacia la IP `tailscale0` de la Pi, que también lleva a Caddy).
3. **Internal URL**: `https://home-assistant.lan` igual; Caddy es el único camino. Si en el futuro se quiere distinguir (ej. para integraciones que llamen a HA desde otro contenedor por DNS interno), se podría usar `http://home-assistant:8123` como _internal_, pero el frontend prefiere HTTPS para no _mixed-content_ los webhooks generados.

> **Por qué no diferenciar internal/external**: la diferencia tiene sentido cuando el `external` es un dominio público (`home.casa.dev`) y el `internal` es una IP/local. Aquí ambos son `home-assistant.lan` resuelto por Pi-hole (LAN) o MagicDNS (Tailscale), sirviendo a Caddy. Una sola URL canónica simplifica.

### Generar un Long-Lived Access Token para la app móvil

La app oficial de HA (Android/iOS) puede _onboarding_ con login + TOTP, pero es más práctico generar un token específico:

1. Click en el avatar → **Mi Perfil** → bajar a **Tokens de Acceso de Larga Duración**.
2. **Create Token** → nombre "móvil pixel-7" (o similar).
3. **Copiar el token** (sólo se muestra una vez).
4. En la app: **Server URL → `https://home-assistant.lan`** (con la _CA local importada_ en el _trust store_ del móvil; sin eso, falla con `unable to verify the certificate`).
5. Pegar el token cuando la app pregunte.

Repetir por cada dispositivo.

> **CA local en el móvil**: Android desde 11+ no acepta CAs de usuario para tráfico _en una app cualquiera_, sólo si la app declara confiarlas en su `network_security_config.xml`. La app de HA lo hace cuando el _server URL_ es `https://*.lan` o similar; ver `docs/03-red/04-caddy.md` sección _Acceso desde móvil_ para el procedimiento de importación del certificado raíz al `Trust store` del móvil.

> **Tailscale**: si se accede vía Tailscale en el móvil, la IP de origen (`100.64.x.x`) no está en `172.20.10.0/24`, así que `trusted_proxies` no la añade. Caddy sigue siendo el _proxy_ y _sí_ está en la subnet — HA registra al móvil como "viene de la Pi vía VPN", lo cual no es estrictamente "la IP del móvil" pero sí es coherente y aceptable para el _logging_. No hay nada que hacer aquí: HA y Tailscale conviven sin ajuste extra.

---

## Integraciones básicas

Lista corta y opinada de integraciones que el _wizard_ habilitó automáticamente y las que se añaden a mano en este documento. Sólo cosas que no requieren hardware adicional ni servicios externos a configurar:

| Integración        | Cómo se activa                                            | Para qué                                                                 |
|--------------------|-----------------------------------------------------------|--------------------------------------------------------------------------|
| `default_config`   | Auto, vía `default_config:` en `configuration.yaml`        | Carga ~30 integraciones esenciales (sun, frontend, mobile_app, ...)      |
| **Sun**            | Auto                                                       | Entidad `sun.sun` con _next_dawn/dusk_, base de automatizaciones horarias |
| **Met.no Weather** | Auto, configurada con la lat/lon del onboarding            | Entidad `weather.forecast_home`, sin API key, datos del Instituto Meteorológico Noruego (cubre España bien) |
| **Mobile App**     | Tras instalar la app oficial y pegar el token              | Sensores del móvil, push notifications, _device_tracker_                 |
| **System Monitor** | YAML, en `configuration.yaml` arriba                       | `sensor.disk_use_percent_root`, `sensor.processor_use`, …                 |
| **Workday**        | YAML, en `configuration.yaml` arriba                       | `binary_sensor.workday_sensor`, base de "rutina laborable vs fin de semana" |

Lo que **se deja para después** y por qué:

- **MQTT (Mosquitto)** — `docs/08-domotica/02-mosquitto.md`. Sin Mosquitto desplegado no tiene sentido configurar la integración MQTT de HA todavía; ese doc se encarga de añadir la integración con `host: mosquitto`.
- **Zigbee2MQTT** — `docs/08-domotica/03-zigbee2mqtt.md`. Z2M es un servicio independiente (no una integración de HA "directa"); se conecta vía MQTT, así que requiere el paso anterior.
- **Node-RED** — `docs/08-domotica/04-node-red.md`. Flujos visuales como complemento o alternativa parcial a las automatizaciones YAML.
- **AEMET** (alternativa española a Met.no) — requiere _API key_ gratuita pero con registro. Útil si Met.no falla en alguna localización; se documentaría en una posible ampliación.
- **HACS** — comunidad-store, no oficial. Fuera de alcance del homelab _hardened_ de fase 1.

Comprobar las integraciones activas:

```bash
# Desde el navegador en https://home-assistant.lan/
# Settings → Devices & services → Integrations
# Debería listar al menos: 'Sun', 'Met.no', 'Mobile app' (si se instaló la app),
# y 'Default Config' (silently — agrupa las internas).

# Desde la API (con un long-lived token):
TOKEN=<long-lived token>
curl -s -H "Authorization: Bearer $TOKEN" \
  -k --resolve home-assistant.lan:443:192.168.1.3 \
  https://home-assistant.lan/api/config_entries 2>/dev/null \
  | python3 -m json.tool | head -40
```

---

## Almacenamiento

Tras el primer arranque, el árbol `/mnt/hd2t/services/home-assistant/` queda con los siguientes ficheros relevantes:

```
/mnt/hd2t/services/home-assistant/
├── configuration.yaml             # editado a mano arriba
├── automations.yaml               # vacío inicialmente; se rellena desde la UI
├── scripts.yaml                   # idem
├── scenes.yaml                    # idem
├── secrets.yaml                   # tokens, passwords (referenciar como !secret)
├── home-assistant_v2.db           # BD SQLite del recorder (irá creciendo)
├── home-assistant_v2.db-wal       # WAL de SQLite (presente mientras HA escribe)
├── home-assistant_v2.db-shm       # shared memory de SQLite
├── home-assistant.log             # log activo del proceso
├── home-assistant.log.1           # log rotado (rotación interna de HA)
├── .storage/                      # estado serializado por el core
│   ├── auth                       # usuarios + tokens activos (CRÍTICO)
│   ├── auth_provider.homeassistant# hashes bcrypt de las passwords
│   ├── core.config_entries        # integraciones configuradas
│   ├── core.device_registry       # dispositivos emparejados
│   ├── core.entity_registry       # entidades con su unique_id
│   └── ...                        # ~30 ficheros JSON más
├── .HA_VERSION                    # versión de HA con la que se inicializó
├── blueprints/                    # blueprints de automatización (vacío)
├── custom_components/             # integraciones de comunidad (vacío)
├── themes/                        # themes Lovelace (vacío)
└── tts/                           # cache de text-to-speech (efímero)
```

| Ruta                                                          | Permisos        | Contenido                                                       |
|---------------------------------------------------------------|-----------------|------------------------------------------------------------------|
| `/mnt/hd2t/services/home-assistant/`                          | `root:root 0755` | Raíz del bind mount                                              |
| `/mnt/hd2t/services/home-assistant/secrets.yaml`              | `root:root 0600` | Secrets (después del primer login, ajustar a 0600 si HA lo dejó 0644) |
| `/mnt/hd2t/services/home-assistant/.storage/`                 | `root:root 0700` | Estado serializado; HA lo crea con 0700 — verificar              |
| `/mnt/hd2t/services/home-assistant/home-assistant_v2.db`      | `root:root 0644` | BD SQLite (HA la crea 0644)                                       |
| `/mnt/hd2t/services/home-assistant/home-assistant.log*`       | `root:root 0644` | Logs                                                             |

> **Sobre `tts/` y otras cachés**: HA genera _cache_ efímero ahí; los dumps de Borgmatic los ignoran via `exclude_patterns` global (`*/cache/*` ya cubre).

> **Snapshots / Backups internos**: el menú **Settings → System → Backups** permite a HA generar `.tar` con todo el `/config`. **No usar como mecanismo principal** — son cómodos para "exportar antes de un upgrade major" (ver **Actualización**), pero la fuente de verdad de los respaldos del homelab es Borgmatic. Los `.tar` que HA genere se guardan en `/mnt/hd2t/services/home-assistant/backups/` y, al estar dentro del bind mount, ya entran en Borgmatic; no requieren acción extra.

---

## Backup

Patrón S (online, vía `sqlite3 .backup`) sobre la BD del _recorder_, más Patrón F (filesystem-only) sobre el resto del árbol. Resultado: respaldo coherente de todo `/config` sin parar HA.

### 1. Descomentar el bloque de Home Assistant en `dump-databases.sh`

Editar `~/homelab/backups/borgmatic/hooks/dump-databases.sh` y descomentar las dos líneas que `docs/07-backups/03-backup-docker-volumes.md` dejó preparadas:

```diff
 # --- Home Assistant (SQLite — recorder) — docs/08-domotica/01-home-assistant.md
-# dump_sqlite home-assistant home-assistant /config/home-assistant_v2.db
-# El árbol /mnt/hd2t/services/home-assistant/ entra como source_directory aparte.
+dump_sqlite home-assistant home-assistant /config/home-assistant_v2.db
+# El árbol /mnt/hd2t/services/home-assistant/ entra como source_directory aparte.
```

Re-instalar:

```bash
~/homelab/backups/borgmatic/install.sh
sudo /usr/bin/borgmatic --dry-run --verbosity 2 | grep -A2 home-assistant
# debe listar el dump previsto
```

Smoke-test del hook ejecutándolo a mano:

```bash
sudo /etc/borgmatic.d/hooks/dump-databases.sh
ls -la /mnt/hd2t/backups/dumps/home-assistant-*.sqlite.gz
# home-assistant-2026-04-26.sqlite.gz   1.2M
```

Confirmar que el dump abre como SQLite válido:

```bash
sudo zcat /mnt/hd2t/backups/dumps/home-assistant-*.sqlite.gz \
  | file -
# /dev/stdin: SQLite 3.x database, ...
```

### 2. Añadir el _exclude_ específico al `config.yaml` de Borgmatic

Editar `~/homelab/backups/borgmatic/config.yaml` (la fuente de verdad versionada en git) y añadir las exclusiones específicas de HA al bloque `exclude_patterns:`:

```yaml
exclude_patterns:
  # ... entradas existentes ...

  # Home Assistant — logs rotados (los activos los cubre el snapshot SQLite)
  - '**/home-assistant.log'
  - '**/home-assistant.log.*'

  # Home Assistant — cache de text-to-speech (regenerable)
  - /mnt/hd2t/services/home-assistant/tts
```

Aplicar:

```bash
~/homelab/backups/borgmatic/install.sh
sudo /usr/bin/borgmatic --dry-run --verbosity 2 \
  | grep -E 'home-assistant|exclude' | head -20
```

### 3. Confirmar que HA está cubierto por `source_directories`

`source_directories: /mnt/hd2t/services` ya incluye `home-assistant/` por inercia (ver `docs/07-backups/02-borgmatic.md`, sección _Por qué incluir el directorio padre y filtrar_). Tras el siguiente _run_ programado (madrugada), HA aparece en la lista de archives:

```bash
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list --short "$BORG_REPO_LOCAL" | tail -1
'
# pi-2026-04-26T03:30:30

sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list "$BORG_REPO_LOCAL::pi-2026-04-26T03:30:30" \
    | grep home-assistant | head -10
'
# -rw-r--r-- root   root   1234 Apr 26 02:00 mnt/hd2t/services/home-assistant/configuration.yaml
# -rw-r----- root   root   8192 Apr 26 03:30 mnt/hd2t/backups/dumps/home-assistant-2026-04-26.sqlite.gz
# ...
```

### Restauración

El procedimiento es idéntico al **Patrón de restauración común** documentado en `docs/07-backups/03-backup-docker-volumes.md` (sección _Procedimientos de restauración_), seguido del runbook **Home Assistant — restauración** del mismo doc. En resumen:

1. `docker compose -f ~/homelab/domotica/docker-compose.yml stop home-assistant`.
2. Mover `/mnt/hd2t/services/home-assistant/` a `home-assistant.broken-<ts>` (no borrar — preservar 24-48 h por si la restauración tampoco arranca).
3. `borg extract` del archive elegido a `/tmp/restore-$$/`, mover en sitio.
4. Restaurar la SQLite desde el dump del Patrón S si la del archive estuviera dañada (raro):
   ```bash
   sudo gunzip -c /mnt/hd2t/backups/dumps/home-assistant-YYYY-MM-DD.sqlite.gz \
     > /mnt/hd2t/services/home-assistant/home-assistant_v2.db
   ```
5. **Verificar `secrets.yaml`** sigue presente con permisos `0600` (anota explícitamente el doc `03-backup-docker-volumes.md` → _Home Assistant — restauración_).
6. `docker compose -f ~/homelab/domotica/docker-compose.yml up -d home-assistant`.
7. Esperar al `(healthy)` (puede tardar hasta 5 min si la SQLite es grande y arranca con `db_repair`).
8. Comprobar dashboard: las entidades deben recuperar su última `state` y las automatizaciones aparecer en _Settings → Automations_.

---

## Verificación

Antes de dar por cerrado este documento:

- [ ] `~/homelab/domotica/docker-compose.yml` y `~/homelab/domotica/.env.example` versionados en git; `~/homelab/domotica/.env` **no** versionado (`.gitignore` activo).
- [ ] `docker compose -f ~/homelab/domotica/docker-compose.yml ps` muestra `home-assistant` como `(healthy)`.
- [ ] `docker exec home-assistant wget -qO- http://localhost:8123/manifest.json | head -c 60` devuelve un JSON con la cadena `Home Assistant`.
- [ ] `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` acepta el bloque `home-assistant.lan` añadido.
- [ ] `curl -k --resolve home-assistant.lan:443:192.168.1.3 -I https://home-assistant.lan/` devuelve `200` directo (HA carga la pantalla de login; sin Authelia delante, no hay redirect a `auth.lan`).
- [ ] Login interactivo desde el navegador con la cuenta `owner` + TOTP funciona; tras login se ve el dashboard con las entidades `sun.sun`, `weather.forecast_home`, `binary_sensor.workday_sensor` y los `sensor.disk_use_percent_root` etc.
- [ ] `docker exec home-assistant python -m homeassistant --config /config --script check_config` reporta `Configuration is valid`.
- [ ] `Settings → System → Logs` no reporta errores de `aiohttp` ni warnings recurrentes de `recorder`.
- [ ] El log de HA (`docker logs home-assistant 2>&1 | grep -i 'forwarded'`) muestra que la cabecera `X-Forwarded-For` se procesa: una petición desde el navegador del PC LAN aparece logueada con la IP del PC, no con `172.20.10.x`.
- [ ] App móvil oficial conectada: `Settings → Devices & services → Mobile App` muestra al menos un dispositivo con _last seen_ reciente.
- [ ] Dump SQLite generado por `dump-databases.sh`: `sudo ls -la /mnt/hd2t/backups/dumps/home-assistant-$(date +%F).sqlite.gz` existe y `file -` lo identifica como `gzip compressed data` con SQLite dentro.
- [ ] La línea `# - 'home-assistant.lan'` del `access_control.rules` de Authelia sigue **comentada** (HA no entra en `two_factor` porque no se le pone `forward_auth`).
- [ ] El `Caddyfile` para `home-assistant.lan` lleva `import security-headers` y `import logging`, **no** `import authelia`.
- [ ] Watchtower no marca el contenedor: `docker logs watchtower --tail 50 | grep home-assistant` no muestra "Found new image" para HA (label `enable: "false"` activo).

---

## Troubleshooting

### Primer arranque: el contenedor se queda en `starting` indefinidamente

```bash
docker logs home-assistant --tail 50
```

Causas comunes:

- **Permisos del bind mount**: si por error se ha hecho un `chown -R 1000:1000 /mnt/hd2t/services/home-assistant` (siguiendo guías de la familia LinuxServer.io), HA falla porque corre como `root` y no entiende ese ownership. Restaurar:
  ```bash
  sudo chown -R root:root /mnt/hd2t/services/home-assistant
  docker compose -f ~/homelab/domotica/docker-compose.yml restart home-assistant
  ```
- **`/etc/localtime` ausente**: en algunos hosts minimalistas no existe; HA se queja con `RuntimeError: Could not determine timezone`. Solucionar con la variable `TZ` (ya está en el compose) o crear el symlink:
  ```bash
  sudo ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
  ```

### "Login attempt or request with invalid authentication from 172.20.10.x"

HA loguea esto repetidamente cuando `trusted_proxies` no está bien configurado: la IP que ve es la del contenedor de Caddy (172.20.10.x), no la del cliente. Comprobar:

```bash
sudo grep -A3 'trusted_proxies' /mnt/hd2t/services/home-assistant/configuration.yaml
# Debe contener:
# trusted_proxies:
#   - 172.20.10.0/24
#   - 127.0.0.1
```

Si está bien y siguen los warnings, comprobar que la subnet sigue siendo `172.20.10.0/24` (no se cambió en `docs/02-docker/02-estructura-compose.md`):

```bash
docker network inspect homelab --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

Si difiere, actualizar `HA_TRUSTED_PROXY_SUBNET` en `.env` y `trusted_proxies` en `configuration.yaml`, reiniciar HA.

### La app móvil dice "Unable to verify the certificate"

La CA local no está importada en el _trust store_ del móvil. Procedimiento en `docs/03-red/04-caddy.md`, sección _Acceso desde móvil_. **No** desactivar la verificación del certificado en la app — eso permite cualquier MITM dentro de la WiFi.

### WebSocket se desconecta cada minuto

Síntomas: el dashboard parpadea entre "Connected" y "Reconnecting" repetidamente. Causas:

1. **Caddy con un `header_up Connection` mal escrito**: el bloque del Caddyfile de este doc **no** sobreescribe `Connection`, así que `reverse_proxy` de Caddy v2 maneja el _upgrade_ a WebSocket automáticamente. Si alguien añadió un `header_up Connection close` por error, eliminarlo.
2. **Timeout muy corto en el reverse proxy**: por defecto Caddy mantiene la conexión _keep-alive_ indefinidamente. Si en algún _snippet_ se ha puesto un `transport http { dial_timeout 5s }`, eliminarlo o aumentar el timeout.
3. **Pi-hole con `block_log_queries: true`**: irrelevante para WS, pero a veces el problema es que el dispositivo móvil resuelve `home-assistant.lan` por DNS público (no por Pi-hole) y va a una IP equivocada. Comprobar con:
   ```bash
   # Desde el móvil, o el PC, en la misma WiFi:
   nslookup home-assistant.lan
   # Server: 192.168.1.2  (IP de Pi-hole)
   # Address: 192.168.1.3 (IP de la Pi)
   ```

### El `recorder` crece a 5 GB / mes

Síntomas: `df -h /mnt/hd2t` reporta uso creciente atribuible a `home-assistant_v2.db`. Causas:

- **Demasiadas entidades con cambios frecuentes** loguean cada actualización. Identificar la peor:
  ```bash
  docker exec home-assistant python -c '
  import sqlite3
  conn = sqlite3.connect("/config/home-assistant_v2.db")
  for row in conn.execute("""
    SELECT em.entity_id, COUNT(*) AS c FROM states s
    JOIN states_meta em ON s.metadata_id = em.metadata_id
    GROUP BY em.entity_id ORDER BY c DESC LIMIT 10
  """):
      print(row)
  '
  ```
  Las entidades con millones de filas (típicamente sensores eléctricos cada segundo) son candidatas a `recorder.exclude` en `configuration.yaml`.
- **`purge_keep_days` muy alto**: si está en 30 o 60, bajarlo a 14 reduce el tamaño cuando el siguiente _purge_ corra (default: 4:12 AM diariamente).
- **Forzar un _purge_ inmediato**: `Developer Tools → Services → recorder.purge` con `keep_days: 14, repack: true`. El `repack: true` libera el espacio físico (sin él, SQLite marca las páginas como reusables pero no encoge el fichero).

### Tras un _bump_ de versión, integraciones marcadas como "deprecated"

Es normal y esperado. Cada release de HA marca 1–3 integraciones como _deprecated_ con avisos en _Settings → Repairs_. Plan de acción:

1. Leer las _release notes_ de la versión a la que se subió.
2. Para cada _deprecated_, seguir el _migration guide_ del blog (suele ser cambiar `platform: x` por `platform: y` en YAML, o reconfigurar la integración desde la UI).
3. **No diferir indefinidamente**: las _deprecated_ se eliminan típicamente 6 meses después; si se ignora el aviso, el siguiente _bump_ lo elimina y la integración deja de funcionar sin _fallback_.

---

## Actualización

Bumps mensuales (`2026.4 → 2026.5`):

```bash
# 1. Leer las release notes
xdg-open https://www.home-assistant.io/blog/2026/05/  # o equivalente
# Buscar "Backward-incompatible changes" — si toca alguna integración activa,
# planificar el cambio antes del bump.

# 2. Backup completo previo
sudo /usr/bin/borgmatic --verbosity 1
# Verificar que el último archive tiene fecha de hoy:
sudo bash -c '
  set -a; . /etc/borgmatic.d/secrets.env; set +a
  borg list --short "$BORG_REPO_LOCAL" | tail -1
'

# 3. Snapshot interno de HA (rápido, queda en backups/ del bind mount)
TOKEN=<long-lived token>
curl -k --resolve home-assistant.lan:443:192.168.1.3 \
  -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"pre-2026.5"}' \
  https://home-assistant.lan/api/services/backup/create

# 4. Cambiar el tag y aplicar
$EDITOR ~/homelab/domotica/.env
# HA_IMAGE_TAG=2026.5
cd ~/homelab
make pull STACK=domotica
make up STACK=domotica

# 5. Vigilar el log durante la migración del recorder
docker compose -f ~/homelab/domotica/docker-compose.yml logs -f home-assistant
# Buscar:
#   recorder] Database is about to upgrade. Schema version: 42
#   recorder] Upgrading recorder db schema from 42 to 43
#   recorder] Database upgrade completed
# Si el log muestra ERROR o el contenedor entra en restart loop, ir a Troubleshooting.

# 6. Validar el dashboard, las automatizaciones y la app móvil
```

Bumps de major (cambio de año, `2025.12 → 2026.1`):

- Suelen incluir 5–10 _breaking changes_; planificar la actualización en una ventana de mantenimiento.
- Considerar saltar a `2026.1.4` o similar (la versión `.0` a menudo tiene bugs que se arreglan en el primer _patch_).
- Tras el upgrade, ejecutar `Settings → System → Repairs` para resolver avisos heredados.

---

## Referencias

- Documentación oficial — Home Assistant Container: <https://www.home-assistant.io/installation/linux>
- Documentación oficial — `homeassistant/home-assistant` Docker image: <https://hub.docker.com/r/homeassistant/home-assistant>
- Reverse proxy con HA — `use_x_forwarded_for` y `trusted_proxies`: <https://www.home-assistant.io/integrations/http/#use_x_forwarded_for>
- Recorder — exclusiones, retención, repack: <https://www.home-assistant.io/integrations/recorder/>
- Workday — sensor binario: <https://www.home-assistant.io/integrations/workday/>
- System Monitor — sensores del propio host: <https://www.home-assistant.io/integrations/systemmonitor/>
- Met.no — proveedor de tiempo: <https://www.home-assistant.io/integrations/met/>
- Mobile App + Long-Lived Access Tokens: <https://companion.home-assistant.io/>
- Release notes mensuales (blog oficial): <https://www.home-assistant.io/blog/>
- Caddy v2 — reverse_proxy con WebSocket: <https://caddyserver.com/docs/caddyfile/directives/reverse_proxy>
- Documentos relacionados del homelab:
  - `docs/02-docker/02-estructura-compose.md` — convenciones de stacks y red `homelab`.
  - `docs/03-red/04-caddy.md` — Caddy y CA local.
  - `docs/03-red/02-pihole.md` — DNS local `*.lan`.
  - `docs/04-seguridad/01-authelia.md` — por qué HA **no** entra en `two_factor` de Authelia.
  - `docs/07-backups/02-borgmatic.md` — `source_directories`, retention.
  - `docs/07-backups/03-backup-docker-volumes.md` — Patrón S, runbook _Home Assistant — restauración_.
  - `docs/08-domotica/02-mosquitto.md` (siguiente fase) — broker MQTT consumido por HA.
  - `docs/08-domotica/03-zigbee2mqtt.md` (siguiente fase) — puente Zigbee → MQTT.
  - `docs/08-domotica/04-node-red.md` (siguiente fase) — flujos visuales.
