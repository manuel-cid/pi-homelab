# Uptime Kuma (monitorización de disponibilidad y notificaciones)

## Descripción

Despliegue de **Uptime Kuma** como **monitor de disponibilidad** del homelab y **hub central de notificaciones**. Donde Prometheus + Grafana (`docs/05-monitorizacion/01-prometheus.md`, `02-grafana.md`) responden a la pregunta "_cómo_ está funcionando un servicio" (CPU, RAM, latencia, _scrape_ activo), Uptime Kuma responde a la pregunta complementaria, mucho más binaria, "_¿está_ funcionando?" — _ping_/HTTP/HTTPS/TCP/DNS desde fuera del propio servicio, _at-a-glance_ verde/rojo, y un _push_ inmediato a Telegram + email cuando algo se cae. Es el _frontend_ humano para los _alerts_ que en este homelab se han delegado fuera de Prometheus (sin Alertmanager, sin Grafana _alerting_ unificado — `docs/05-monitorizacion/01-prometheus.md` y `02-grafana.md` ya lo justifican).

Este documento **se suma al _stack_ `monitor`** ya operativo. No crea nada nuevo en `~/homelab/`: añade el servicio `uptime-kuma` al `docker-compose.yml` del _stack_, monta `/mnt/hd2t/services/uptime-kuma/` como `bind mount` para su SQLite + uploads, lo expone como `https://uptime.lan/` detrás de Caddy con HTTPS interno, lo protege con **Authelia 2FA** vía `forward_auth` y añade `uptime.lan` a la regla `two_factor` del `access_control` de Authelia.

> **Alcance**: este documento despliega Uptime Kuma, lo conecta a la red `homelab` (DNS interno `uptime-kuma:3001`), lo publica vía Caddy + Authelia 2FA, y deja documentada la configuración inicial post-despliegue: usuario admin, _monitors_ recomendados (uno por servicio del homelab), notificaciones Telegram + email. **No** monta una BD externa (SQLite incrustado es lo natural en Uptime Kuma — la propia _upstream_ desaconseja MariaDB para nuevas instalaciones). **No** activa _Playwright_ (la imagen `:debian` con Chromium para _monitors_ tipo "real browser test" añade ~250 MB y CPU; se queda en HTTP/TCP/Ping/DNS, suficiente para el homelab). **No** crea _status pages_ públicas (el homelab es privado, LAN+Tailscale; las _status pages_ son una opción que se añade _ad-hoc_ desde la UI cuando haga falta). **No** integra el endpoint `/metrics` de Uptime Kuma con Prometheus en este doc (requiere generar una _API key_ desde la UI tras el primer arranque); se documenta como **operación opcional** al final.

> **Recordatorio de red**: Uptime Kuma **no se publica al host**. Caddy lo alcanza por DNS interno de Docker (`uptime-kuma:3001`) dentro de la red `homelab`. El operador entra por `https://uptime.lan/`, que Pi-hole resuelve a `192.168.1.3` (_wildcard_ de `02-homelab-local.conf`) y Caddy demultiplexa por SNI. Authelia exige 2FA antes de exponer la UI.

> **Doble capa de autenticación intencional**: Uptime Kuma trae su propio formulario de login con usuario+contraseña (creado en el _setup wizard_ del primer arranque), que **no se desactiva**. Authelia se sienta **delante** como segunda barrera (2FA). El operador legítimo introduce TOTP en Authelia y luego usuario+contraseña de Uptime Kuma; un atacante con acceso LAN tendría que romper ambas. Para una herramienta tan crítica como el "panel de qué se ha caído", la redundancia es deseable.

---

## Requisitos previos

- `docs/05-monitorizacion/01-prometheus.md` completado: el _stack_ `monitor` existe en `~/homelab/monitor/`, Prometheus está `(healthy)`, y `https://prometheus.lan/` responde tras 2FA. Uptime Kuma _no_ depende de Prometheus, pero la convención del _stack_ y los ficheros (`.env`, `.env.example`, `docker-compose.yml`) ya están establecidos por aquel doc.
- `docs/05-monitorizacion/02-grafana.md` completado: Grafana está `(healthy)` en `https://grafana.lan/`. El _alerting_ unificado de Grafana se dejó **deshabilitado** explícitamente (`enabled = false` en `grafana.ini`) precisamente porque las _alerts_ se delegan a este servicio.
- `docs/05-monitorizacion/03-node-exporter.md` y `04-cadvisor.md` completados: ambos en `Up` y `up{job=...}` a `1`. Uptime Kuma **monitorizará el `/healthz` de Caddy y el _heartbeat_ HTTP de cada servicio** del homelab; cuanto más completo esté el _stack_ ya levantado en este punto, más _monitors_ útiles se pueden crear desde el primer arranque.
- `docs/04-seguridad/01-authelia.md` completado: `https://auth.lan/` operativo con TOTP, _snippet_ `(authelia)` activo en `~/homelab/red/caddy/snippets/authelia.caddy`, `access_control` con la regla `two_factor` ya conteniendo `portainer.lan`, `prometheus.lan` y `grafana.lan`. Este doc añade `uptime.lan` a esa lista.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, _snippets_ `security-headers`, `logging` y `authelia` operativos, `import /etc/caddy/snippets/*.caddy` activo en el `Caddyfile`.
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `uptime.lan` — el _wildcard_ ya lo cubre.
- `docs/02-docker/02-estructura-compose.md` completado: red `homelab` (`172.20.10.0/24`, `br-homelab`) creada y _externa_, `~/homelab/.env` con `TZ`, `PUID`, `PGID` y `HOMELAB_DOMAIN=lan` operativos.
- `docs/02-docker/04-watchtower.md` completado: Watchtower está vigilando con `WATCHTOWER_LABEL_ENABLE=true` (modo _opt-in_). Uptime Kuma figura en aquel doc como candidato _opt-in_; este doc activa la _label_.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/uptime-kuma/` ya existe vacío `root:root 0755`. La imagen oficial corre como _root_ dentro del contenedor — el _ownership_ del bind se queda como está.
- Conectividad saliente para descargar la imagen y, durante el primer arranque, los _avatares_ y _favicons_ que Uptime Kuma cachea para los _monitors_:

  ```bash
  docker pull --platform linux/arm64 louislam/uptime-kuma:1.23.13 >/dev/null && echo OK
  ```

- Que el host **no** tenga ya un servicio escuchando en `:3001`:

  ```bash
  sudo ss -tulpn '( sport = :3001 )'
  ```

  Salida esperada: vacía. Uptime Kuma **no** publica `:3001` al host (sólo lo expone a `homelab`), pero conviene confirmar que ningún binario residual lo ocupa antes del primer `up`.

- Una cuenta de **Telegram bot** (token vía `@BotFather`) y/o un buzón **SMTP** con _credentials_ de aplicación (Gmail _app password_, ProtonMail Bridge, _provider_ de transactional email…). Estos se introducen **a mano en la UI** tras el primer login, no en `.env` (Uptime Kuma no soporta provisioning declarativo — ver **Decisiones de diseño**).

---

## Decisiones de diseño

### Por qué Uptime Kuma (y no Statping / Healthchecks.io / Gatus / Cabot)

| Candidato                     | Por qué se descarta                                                                                                                                                                                                                                       |
|-------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Statping(-ng)**             | _Fork_ "moderno" del antiguo Statping. Activo pero con tracción menor, comunidad de _plugins_ pequeña, _release cadence_ irregular. Las _features_ que ofrece (HTTP/TCP/ICMP, _status pages_, notificaciones) están todas en Uptime Kuma con más opciones. |
| **Healthchecks.io self-hosted** | _Pull-only_: cada servicio monitorizado debe enviar un _heartbeat_ a Healthchecks (`curl https://healthchecks.lan/ping/<uuid>` cada N minutos). Modelo perfecto para _cron jobs_ y procesos _batch_, pésimo para "¿responde Jellyfin a HTTP?": habría que escribir un _ping wrapper_ por cada servicio. Uptime Kuma hace lo contrario — sondea _push_ desde fuera, sin tocar el servicio. **Complementarios**: Healthchecks brilla para _cron jobs_ (Borgmatic, Watchtower) y Uptime Kuma para servicios "always-on". Si en algún momento se quiere también _heartbeat-based_, Uptime Kuma trae **monitores tipo `Push`** equivalentes. |
| **Gatus**                     | Configuración 100 % declarativa por YAML (encaja con la estética del homelab), pero la UI es de sólo-lectura — añadir un _monitor_ requiere editar `config.yaml` y reiniciar. Para un _operator_ único que itera, Uptime Kuma + UI gana en agilidad. Si en algún momento la cantidad de _monitors_ explota (>50) y se quiere _gitops_ puro, Gatus es el siguiente paso. |
| **Cabot / Cachet / Kuma 2.0 _beta_** | Cabot/Cachet llevan años con poco mantenimiento. Kuma 2.0 está en _beta_ desde 2024 y reescribe el _backend_ en TypeScript con cambios de esquema en SQLite — esperable adoptar cuando salga `2.x` estable. Por ahora **`1.23.x`** es lo maduro. |
| **Pingdom / UptimeRobot / BetterUptime SaaS** | Servicios externos. Excluidos por dos razones: (1) violan la política "todo en LAN+Tailscale, nada de SaaS de terceros", (2) un _ping_ desde el exterior no entra al homelab (no hay _port forwarding_), así que sólo monitorizarían `pi.<TAILNET>.ts.net` y no podrían comprobar `https://jellyfin.lan/health` desde dentro. |

Uptime Kuma gana por:

- **UI muy directa**: un _monitor_ por servicio, gráfica de respuesta histórica, _heartbeat_ visual, _status_ verde/rojo. Cero ceremonia.
- **~90 tipos de notificación**: Telegram, Discord, Slack, SMTP, Mattermost, Pushover, ntfy, _generic webhook_, Microsoft Teams, _SMS providers_… Prácticamente cualquier _channel_ que pueda querer un homelab.
- **Tipos de _monitor_ generosos**: HTTP(s), HTTP(s) keyword, TCP port, Ping (ICMP), DNS, SQL Server, PostgreSQL, MySQL, Redis, MQTT, NTP, Steam, Docker, Kafka, _Push_ (heartbeat-based), _Group_ (compone otros _monitors_).
- **_Maintenance windows_**: silenciar _alerts_ durante una ventana planificada (un `apt upgrade && reboot` semanal, p. ej.) sin generar ruido.
- **_Status pages_** opcionales para una vista pública sin login (no se usa en este doc, pero está disponible).
- **SQLite incrustado**: cero dependencias externas, footprint mínimo, _backup_ trivial copiando un fichero. La `kuma.db` con WAL aguanta ~50 _monitors_ sin despeinarse en una Pi 5.
- **ARM64 nativo**: imagen multi-arch oficial.

### Stack `monitor` — Uptime Kuma se suma sin red privada

Igual que Prometheus, Grafana, Node Exporter y cAdvisor, Uptime Kuma se conecta a la red compartida `homelab`. Razones:

- **Hace _checks_ contra todos los servicios del homelab por DNS interno** (`http://jellyfin:8096/health`, `tcp://nextcloud:80`, `tcp://mosquitto:1883`, …). Vivir en `homelab` le da resolución directa de los nombres de contenedor sin saltos.
- **Caddy habla con Uptime Kuma por DNS interno** (`uptime-kuma:3001`) y le pasa la cabecera `Remote-User` desde Authelia (no es estrictamente necesaria — Uptime Kuma no la lee — pero el _snippet_ `(authelia)` la copia por defecto y no estorba).
- **No hay ningún componente _interno_ a Uptime Kuma que justifique una `monitor-internal`**: SQLite vive en el _bind mount_ y no es un servicio en red.

### Imagen y _tag_

- **`louislam/uptime-kuma:1.23.13`** — Uptime Kuma `1.23` _stable_, multi-arch con `linux/arm64`, imagen oficial publicada por louislam (autor original) en Docker Hub. Pinneada a versión completa (convención del homelab).
- **Por qué `:1.23.13` y no `:1`, `:1.23` o `:latest`**: la convención del homelab es `MAJOR.MINOR.PATCH` exacto. Permite a Watchtower hacer _opt-in_ a _patch releases_ sin saltar a `1.24.x` ni a `2.0.x` _beta_.
- **Por qué la variante por defecto (Alpine) y no `:1.23.13-debian`**: la imagen `-debian` añade ~250 MB de Chromium/Playwright para soportar _monitors_ de tipo "Real Browser Test". En este homelab no se necesitan: HTTP/TCP/Ping/DNS resuelven el 100 % de los casos. Se puede cambiar a `-debian` en el futuro editando una sola variable del `.env` y recreando el contenedor — los datos en `/mnt/hd2t/services/uptime-kuma/` son compatibles entre ambas variantes.
- **Por qué `1.23.x` y no `2.0.x` _beta_**: la rama `2.x` (ago 2024 _beta_) reescribe el _backend_ y migra el esquema de SQLite. Esperar a `2.x` estable y a un par de _patch releases_ antes de adoptar. Cuando llegue, este doc se actualiza con el _migration path_ documentado por _upstream_ (probablemente automático al primer arranque, con _backup_ previo).
- **Watchtower opt-in** (`com.centurylinklabs.watchtower.enable: "true"`):
  - _Patch releases_ (`1.23.13 → 1.23.14`) son seguros: bugfixes y traducciones, sin cambios de esquema.
  - Como el _tag_ pinneado **no cambia** entre _patch releases_ (`1.23.13` no se mueve a `1.23.14`), Watchtower sólo aplicaría un _bump_ si _upstream_ retagea `1.23.13` con un nuevo _digest_, lo cual es muy raro. En la práctica, los _bumps_ se hacen a mano editando `~/homelab/monitor/.env` (`UPTIME_KUMA_IMAGE_TAG=1.23.14`) y ejecutando `make pull STACK=monitor && make up STACK=monitor`. Watchtower opt-in queda como red de seguridad para _hotfixes retagged_.
  - Entre _minors_ (`1.23 → 1.24`) y entre _majors_ (`1.x → 2.x`), las _release notes_ se leen sí o sí y la actualización es manual.

### Persistencia: SQLite + uploads en `/mnt/hd2t/services/uptime-kuma/`

Uptime Kuma persiste **todo** su estado en `/app/data/`:

- `kuma.db` — SQLite con _monitors_, _heartbeats_ históricos, _users_, _notifications_, _settings_, _status pages_, _maintenance windows_, _api keys_, _docker hosts_, _proxies_…
- `kuma.db-wal`, `kuma.db-shm` — _Write-Ahead Log_ y _shared memory_ de SQLite.
- `upload/` — _avatares_, _favicons_ cacheados, _logos_ de _status pages_.
- `error.log` — _log_ de errores del proceso (rotado por la propia app).

`/mnt/hd2t/services/uptime-kuma/` (definido en `docs/01-sistema/04-estructura-directorios.md`) por las mismas razones que Prometheus y Grafana:

1. **Volumen de escritura**: cada _heartbeat_ escribe una fila en `heartbeat`. Con 30 _monitors_ a 60 s de intervalo eso son 30 _inserts_/min = 43 200/día. Sostenido en microSD acelera el desgaste; en HDD `hd2t` es invisible.
2. **Tamaño**: con la retención por defecto (180 días de _heartbeats_), `kuma.db` crece a ~100-200 MB en un homelab de ~30 servicios. Cabría en microSD pero no es donde quiere estar.
3. **Backup**: `/mnt/hd2t/services/uptime-kuma/` entra en Borgmatic por la _label_ `homelab.backup: "true"`. Restaurar un `kuma.db` recupera **todos** los _monitors_ + histórico + notificaciones configuradas en un solo paso — Uptime Kuma es _stateful_ y este es el único camino fiable de recuperación.

### Owner del directorio: `root:root` (la imagen oficial corre como _root_)

A diferencia de Grafana (UID 472), Prometheus (65534) o las imágenes _LinuxServer.io_ (1000), `louislam/uptime-kuma` corre como **`root` dentro del contenedor**. Esta es una decisión _upstream_ consciente — Uptime Kuma necesita _CAP_NET_RAW_ para _ICMP ping_ (los _monitors_ de tipo `Ping`) y soportar UID arbitrario obliga a complicar la imagen con `setcap`/`setuid` _wrappers_. La _upstream_ responde a este _request_ recurrente con un "no, así está bien".

Consecuencias prácticas:

- El _bind mount_ `/mnt/hd2t/services/uptime-kuma/` se queda con `root:root 0755` (_default_ del paso 6 de `docs/01-sistema/04-estructura-directorios.md`). **No se hace `chown`**.
- Dentro del _user namespace_ del contenedor, el _root_ del contenedor _no_ es _root_ del host (asumiendo `userns-remap` activo, lo cual no está activado en el homelab — ver siguiente punto).
- Aunque `userns-remap` no esté activo (el caso por defecto de Pi OS Bookworm), el _confinement_ de Docker + `cap-drop` razonable sería suficiente para que `root` dentro no escale al host. Como Uptime Kuma `1.23.x` necesita **`CAP_NET_RAW`** (ICMP ping) y **`CAP_NET_BIND_SERVICE`** (en algunos _exporters_ que monitorizan), no se hace `cap_drop: ALL`. Se confía en el _confinement_ por defecto.

> **Trade-off explícito**: una imagen "como root" es menos elegante que una "como UID dedicado", pero el alcance del compromiso queda confinado al `/app/data` (que ya es de Uptime Kuma) y a las _capabilities_ por defecto de Docker. Para una imagen oficial de `louislam` (autor único, _release cadence_ regular, +60k stars), el riesgo es asumible.

### Acceso vía Caddy + Authelia 2FA — `uptime.lan`

Mismo patrón que Prometheus/Grafana. Como Uptime Kuma **revela el inventario completo de servicios** del homelab (qué hay desplegado, qué se cae cuándo, qué _channel_ Telegram avisa) y permite **disparar notificaciones reales** desde la UI (botón "Test"), la política se eleva a **`two_factor`**: usuario+contraseña + TOTP/WebAuthn.

Este doc añade `uptime.lan` a la lista `two_factor` que `02-grafana.md` ya tenía con `portainer.lan`, `prometheus.lan` y `grafana.lan`.

> **Doble login (Authelia + login nativo de Uptime Kuma)**: Uptime Kuma trae su propio _setup wizard_ en el primer arranque que crea un usuario admin. Ese login **no se desactiva** (a diferencia de Grafana, donde sí se desactiva el formulario nativo). Razón: el _auth proxy_ por cabecera (que Grafana sí soporta) **no existe** en Uptime Kuma — la única autenticación nativa es usuario+contraseña local con la opción de 2FA propio. Como Authelia ya provee 2FA en la capa exterior, **dejamos el login nativo como segunda capa** (sin activar el 2FA propio de Kuma — sería triple, redundante) y el operador introduce dos pares de credenciales. La sesión de Uptime Kuma persiste 24 h (cookie _httpOnly_ + _Secure_ + _SameSite=Lax_), así que en la práctica se ve como un único login al día.

### WebSocket: Caddy lo maneja transparente

Uptime Kuma usa **Socket.IO** (WebSocket con _fallback_ a _long polling_) para empujar _heartbeats_ en vivo a la UI. Caddy maneja `Upgrade: websocket` _out-of-the-box_ con `reverse_proxy` (no necesita `header_up Connection {>Connection}` ni `header_up Upgrade {>Upgrade}` — esos eran necesarios en Caddy v1, no en v2). El bloque del `Caddyfile` queda igual de simple que para Grafana o Prometheus.

> **Si la UI muestra "Disconnected" o se queda cargando**: probable bloqueo del _websocket_ en algún _proxy_/`security-headers` agresivo. Validar con `wscat`/`websocat` desde el host (sección **Troubleshooting**).

### Healthcheck: el _built-in_ de la imagen oficial

A diferencia de Prometheus/cAdvisor (que carecen de _shell_ o _curl_), `louislam/uptime-kuma` viene con `node` y un script `extra/healthcheck.js` propio que la imagen activa por defecto vía `HEALTHCHECK` en el `Dockerfile`. **Lo dejamos como está**: el _healthcheck_ del contenedor pinta `(healthy)` en `docker compose ps` y permite a Compose esperar a que esté listo para arrancar dependencias.

```dockerfile
# Extracto del Dockerfile upstream (informativo):
HEALTHCHECK --interval=60s --timeout=30s --start-period=180s --retries=5 \
    CMD extra/healthcheck
```

> **No se sobrescribe** en el `docker-compose.yml`: la _baseline_ es razonable (180 s de _start period_ es generoso pero correcto para una Pi 5 arrancando con la SQLite fría).

### Notificaciones: por la UI, no por _provisioning_

Uptime Kuma **no soporta provisioning declarativo** (no hay `notifications/*.yml` que escanee al arrancar). La _upstream_ está pensada como una herramienta "interactiva" donde el _operator_ teclea su token Telegram y escoge canales con clicks. Los `monitors`, `notifications`, `tags`, `status pages` viven en SQLite y se manipulan desde la UI o vía la API (introducida en `1.21.x`, todavía marcada _experimental_).

Implicaciones:

- **El primer login configura todo a mano**: usuario admin, _monitors_ de los servicios actuales, canales Telegram + SMTP, _maintenance windows_, _tags_ por _stack_.
- **El backup de `/mnt/hd2t/services/uptime-kuma/`** es lo que recupera la configuración completa. **No** existe un equivalente versionable en git como en Grafana (`provisioning/`).
- **La API de _import/export_** (UI → `Settings → Backup`) sí permite descargar un JSON con `monitors` + `notifications` (sin _heartbeats_) y volver a subirlo. Útil como exportación periódica complementaria al _backup_ de Borg, **no sustituye** al _backup_ binario de la SQLite. Documentado en _Operaciones habituales_.

### `/metrics` de Prometheus: opcional, post-install

Desde `1.18.x`, Uptime Kuma expone `/metrics` en formato Prometheus con `monitor_status`, `monitor_response_time`, `monitor_cert_days_remaining`, etc. Desde `1.21.x` el endpoint **requiere _basic auth_ con una _API key_** (usuario `metrics`, contraseña la _api key_ generada en `Settings → API Keys`).

Por **chicken-and-egg** (no se puede pedir API key sin que Uptime Kuma esté ya levantado), este doc **no incluye** un `scrape_config` para `uptime-kuma` en `prometheus.yml`. Se documenta como **operación opcional** al final: tras el primer arranque + creación del admin, se genera una API key, se añade a `~/homelab/monitor/.env` como `UPTIME_KUMA_API_KEY`, y se descomenta el `scrape_config` correspondiente.

### _Status pages_: no en este doc

Uptime Kuma permite publicar una _status page_ pública (`https://uptime.lan/status/<slug>`) que muestra los _monitors_ seleccionados sin pedir login. En un homelab privado:

- **No hay público externo** que necesite ver "está-está-funcionando-Jellyfin".
- **Authelia delante** ya bloquea el acceso a `/status/*` (al ser una _path_ de la misma _vhost_, hereda el `forward_auth`). Para hacer una _status page_ realmente pública habría que **excluir** ese _path_ del `forward_auth` con un `@matcher` adicional en el `Caddyfile` — gesto trivial pero _intencional_, no automático.

Si en algún momento se quiere una _status page_ accesible vía Tailscale para el operador en movilidad sin TOTP (p. ej. en el reloj), se documenta en `docs/03-red/05-tailscale.md` la pauta para exponerla con `bypass` en `access_control` para `uptime.lan/status/*`. Por ahora, **no**.

### Watchtower opt-in + _label_ `homelab.backup: "true"`

```yaml
labels:
  homelab.stack: "monitor"
  homelab.backup: "true"
  com.centurylinklabs.watchtower.enable: "true"
```

- `homelab.backup: "true"` → Borgmatic recoge `/mnt/hd2t/services/uptime-kuma/` (justificación: la `kuma.db` con _monitors_, _notifications_ y 180 días de _heartbeats_ es un activo que NO se versiona en git).
- `watchtower.enable: "true"` → _opt-in_ a _patch releases_ retagged (justificación arriba: el _tag_ pinneado evita _bumps_ ciegos).

---

## Almacenamiento

| Ruta en el host                                                         | Contenido                                                                  | Versionable | Backup |
|-------------------------------------------------------------------------|----------------------------------------------------------------------------|-------------|--------|
| `~/homelab/monitor/docker-compose.yml`                                  | Definición del _stack_ (modificada — servicio `uptime-kuma` añadido)       | git         | git    |
| `~/homelab/monitor/.env.example`                                        | `UPTIME_KUMA_IMAGE_TAG` añadido                                            | git         | git    |
| `~/homelab/monitor/.env`                                                | `UPTIME_KUMA_IMAGE_TAG` (y `UPTIME_KUMA_API_KEY` cuando se active scrape)  | **NO** (`.gitignore`) | git aparte (nota local) |
| `~/homelab/red/Caddyfile`                                               | Bloque `uptime.lan` añadido                                                | git         | git    |
| `~/homelab/seguridad/configuration.yml`                                 | `uptime.lan` añadido a la regla `two_factor`                               | git         | git    |
| `/mnt/hd2t/services/uptime-kuma/`                                       | `kuma.db` (SQLite), `kuma.db-wal`, `upload/`, `error.log`                  | **NO**      | **Sí** (Borgmatic) |

> **`kuma.db` se respalda en caliente**: SQLite con `journal_mode=WAL`, las escrituras son atómicas y los _readers_ (Borg) no bloquean a los _writers_. Para una restauración _bit-perfect_, basta con `docker compose stop uptime-kuma`, restaurar el directorio desde el _archive_ Borg, y `docker compose up -d`.

> **`upload/` también entra en backup**: contiene _avatares_/_favicons_ que la app cacheó al añadir _monitors_; sin él, la primera carga tras restaurar muestra placeholders durante 1-2 min mientras se re-cachea.

---

## Estructura del _stack_ `monitor` tras este documento

```
~/homelab/monitor/
├── docker-compose.yml              # ← modificado (servicio 'uptime-kuma' añadido)
├── .env                            # ← modificado (UPTIME_KUMA_IMAGE_TAG)
├── .env.example                    # ← modificado (UPTIME_KUMA_IMAGE_TAG)
├── .gitignore                      # (sin cambios)
├── prometheus/
│   ├── prometheus.yml              # (sin cambios — scrape de Uptime Kuma queda opcional)
│   └── rules/
│       └── .gitkeep
└── grafana/
    ├── grafana.ini
    ├── provisioning/
    │   ├── datasources/
    │   │   └── prometheus.yml
    │   └── dashboards/
    │       └── default.yml
    └── dashboards/
        ├── prometheus-stats.json
        ├── node-exporter-full.json
        └── cadvisor.json
```

> **Sin subdirectorio `~/homelab/monitor/uptime-kuma/`**: Uptime Kuma no tiene ficheros de configuración propios versionables — su comportamiento se define en la SQLite del bind mount, y los pocos parámetros de arranque viven como variables de entorno en `.env`. No hace falta un subdirectorio.

---

## Variables de entorno

Editar `~/homelab/monitor/.env.example` y añadir, debajo del bloque de cAdvisor:

```bash
# --- Uptime Kuma -----------------------------------------------------------
UPTIME_KUMA_IMAGE_TAG=1.23.13

# Generada DESPUÉS del primer arranque desde Settings → API Keys.
# Se usa para que Prometheus pueda scrapear /metrics. Mientras esté vacía,
# el scrape_config de uptime-kuma queda comentado en prometheus.yml.
UPTIME_KUMA_API_KEY=
```

Reflejar en `~/homelab/monitor/.env` (no versionado):

```bash
cd ~/homelab/monitor
grep -q '^UPTIME_KUMA_IMAGE_TAG=' .env || cat >> .env <<'EOF'

# --- Uptime Kuma ---
UPTIME_KUMA_IMAGE_TAG=1.23.13
UPTIME_KUMA_API_KEY=
EOF
chmod 0600 .env
```

> Sin secretos por ahora. La `UPTIME_KUMA_API_KEY` queda **vacía** y se rellena tras la activación opcional del _scrape_ Prometheus (sección final). El usuario admin de Uptime Kuma se crea **directamente desde la UI** del primer arranque, no vía variable de entorno.

---

## Modificar `~/homelab/monitor/docker-compose.yml`

Añadir el servicio `uptime-kuma` debajo del de `cadvisor` (**no** sustituir: los bloques anteriores se quedan intactos):

```yaml
  # ---------------------------------------------------------------------------
  # Uptime Kuma — monitorización de disponibilidad y hub de notificaciones.
  # Sondea HTTP/TCP/Ping/DNS contra los servicios del homelab por DNS interno
  # y dispara alertas a Telegram + SMTP cuando algo falla. UI tras Authelia 2FA.
  # docs/05-monitorizacion/05-uptime-kuma.md
  # ---------------------------------------------------------------------------
  uptime-kuma:
    image: louislam/uptime-kuma:${UPTIME_KUMA_IMAGE_TAG}
    container_name: uptime-kuma
    hostname: uptime-kuma
    restart: unless-stopped
    environment:
      # TZ: relojes de la UI y timestamps de los heartbeats en hora local.
      TZ: ${TZ}
      # Forzar a que la UI se renderice asumiendo que está detrás de un
      # reverse proxy con TLS terminado fuera. Evita warnings sobre cookies
      # 'Secure' en el primer arranque.
      UPTIME_KUMA_DISABLE_FRAME_SAMEORIGIN: "false"
    volumes:
      # SQLite + uploads. Backup obligatorio (homelab.backup=true).
      - /mnt/hd2t/services/uptime-kuma:/app/data
    networks:
      homelab:
        aliases:
          - uptime-kuma
    # Sin 'ports:' — Caddy es el único punto de entrada. La UI vive en :3001
    # dentro de la red 'homelab'.
    labels:
      homelab.stack: "monitor"
      homelab.backup: "true"     # /mnt/hd2t/services/uptime-kuma
      # Opt-in: patch releases retagged son seguros. La lista del doc
      # 02-docker/04-watchtower.md ya contempla uptime-kuma como opt-in.
      com.centurylinklabs.watchtower.enable: "true"
    # healthcheck: heredado del HEALTHCHECK de la imagen upstream
    # (extra/healthcheck contra :3001). No se sobrescribe.
```

Notas de diseño extra:

- **Sin `ports: "3001:3001"`**: la convención del homelab es **no publicar puertos al host** salvo Caddy/Pi-hole. Cualquier herramienta de _debug_ que necesite alcanzar `:3001` desde el host se hace con `docker exec` o un túnel SSH puntual (ver _Operaciones habituales_).
- **Sin `cap_add: NET_RAW`** explícito: la imagen oficial corre como `root` y ya tiene `CAP_NET_RAW` por defecto del runtime Docker. Los _monitors_ tipo `Ping (ICMP)` funcionan sin más.
- **`UPTIME_KUMA_DISABLE_FRAME_SAMEORIGIN=false`**: deja la cabecera `X-Frame-Options: SAMEORIGIN` activa. El _snippet_ `security-headers` de Caddy ya añade su propia política (`frame-ancestors 'self'`); ambas son compatibles. Se documenta como `false` explícito por claridad.
- **Sin `depends_on:`**: Uptime Kuma _no_ depende de Prometheus/Grafana/cAdvisor para arrancar; arranca en paralelo. Sus _checks_ HTTP fallarán transitoriamente al inicio (los servicios objetivo están aún arrancando), lo cual genera 1-2 _alerts_ inocuas en el primer despliegue completo. Aceptable.

---

## Modificar Authelia: añadir `uptime.lan` a `two_factor`

Editar `~/homelab/seguridad/configuration.yml` y añadir `uptime.lan` a la regla `two_factor` que ya contiene `portainer.lan`, `prometheus.lan` y `grafana.lan`:

```diff
   # 3) Servicios críticos — exigir 2FA (TOTP / WebAuthn) además de 1FA.
   - domain:
       - 'portainer.lan'
       - 'prometheus.lan'
       - 'grafana.lan'
+      - 'uptime.lan'
       # - 'vaultwarden.lan'      # docs/11-productividad/01-vaultwarden.md
       # - 'nextcloud.lan'        # docs/06-almacenamiento/01-nextcloud.md
       # - 'home-assistant.lan'   # docs/08-domotica/01-home-assistant.md
     policy: two_factor
```

Validar y recargar Authelia:

```bash
docker exec authelia authelia validate-config --config /config/configuration.yml
# Configuration parsed successfully without warnings or errors.

docker compose -f ~/homelab/seguridad/docker-compose.yml restart authelia
# (Authelia no soporta SIGHUP — restart es la forma documentada upstream)
```

> **Por qué `restart` y no `kill -HUP`**: Authelia carga `configuration.yml` al arrancar; los cambios sólo se aplican con un _restart_ del proceso. El _downtime_ es ~3-5 s; las sesiones activas (Redis con AOF) sobreviven.

---

## Modificar el `Caddyfile`: bloque `uptime.lan`

Editar `~/homelab/red/Caddyfile` y añadir, junto al de `grafana.lan` (antes del catch-all `*.lan`):

```caddyfile
# ---------------------------------------------------------------------------
# uptime.lan — Uptime Kuma. WebSocket transparente (Caddy v2 lo maneja).
# Authelia exige 2FA delante; Uptime Kuma trae además su propio login (capa 2).
# docs/05-monitorizacion/05-uptime-kuma.md
# ---------------------------------------------------------------------------
uptime.lan {
    tls internal
    import security-headers
    import logging
    import authelia

    # Caddy v2 detecta y hace upgrade del WebSocket (Socket.IO) sin flags
    # adicionales. El reverse_proxy mantiene la conexión persistente.
    reverse_proxy uptime-kuma:3001 {
        # Pasar el host original — Uptime Kuma lo usa para construir URLs
        # absolutas en notificaciones (links de status pages).
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

Validar la sintaxis sin levantar el servicio:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
# Valid configuration
```

Aplicar el cambio en caliente (sin _restart_ del contenedor):

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
# INF reload happened
```

> **Por qué `header_up Host {host}`**: por defecto Caddy reescribe el `Host` al del _upstream_ (`uptime-kuma:3001`). Uptime Kuma usa el `Host` para los links absolutos en los emails/Telegram (`Click here to acknowledge: https://uptime.lan/...`); sin el `header_up`, las notificaciones llegan con `https://uptime-kuma:3001/...`, que sólo resuelve dentro de la red Docker. Pasarle el `Host` original arregla esto.

> **Snippet `(authelia)` y la cookie de sesión de Uptime Kuma conviven sin conflicto**: la cookie de Authelia es `Domain=lan` (`docs/04-seguridad/01-authelia.md`); la cookie de sesión de Uptime Kuma es _path-scoped_ (`/`) y vive en el dominio `uptime.lan`. No se solapan.

---

## Despliegue

Orden seguro:

```bash
# 1) Editar los ficheros versionables ya descritos:
#    - ~/homelab/monitor/.env y .env.example   (UPTIME_KUMA_IMAGE_TAG)
#    - ~/homelab/monitor/docker-compose.yml    (servicio 'uptime-kuma')
#    - ~/homelab/red/Caddyfile                 (bloque 'uptime.lan')
#    - ~/homelab/seguridad/configuration.yml   ('uptime.lan' en two_factor)

# 2) Validar el compose modificado:
docker compose -f ~/homelab/monitor/docker-compose.yml \
    --env-file ~/homelab/.env --env-file ~/homelab/monitor/.env \
    config | grep -A 30 'uptime-kuma:'

# 3) Validar Authelia config:
docker exec authelia authelia validate-config --config /config/configuration.yml
# Configuration parsed successfully without warnings or errors.

# 4) Recargar Authelia (restart porque no soporta SIGHUP):
docker compose -f ~/homelab/seguridad/docker-compose.yml restart authelia

# 5) Validar y recargar Caddy:
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile

# 6) Levantar el nuevo servicio (sólo recreará 'uptime-kuma'; el resto del
#    stack 'monitor' sigue vivo):
cd ~/homelab
make up STACK=monitor
# o, equivalente:
docker compose -f ~/homelab/monitor/docker-compose.yml \
    --env-file ~/homelab/.env --env-file ~/homelab/monitor/.env \
    up -d uptime-kuma
```

Verificar que Uptime Kuma levantó y está `(healthy)`:

```bash
docker compose -f ~/homelab/monitor/docker-compose.yml ps
# NAME            STATUS
# prometheus      Up X minutes (healthy)
# grafana         Up Y minutes (healthy)
# node-exporter   Up Z minutes
# cadvisor        Up W minutes
# uptime-kuma     Up V seconds (health: starting)
# ...esperar a que pase a (healthy) — start_period es 180 s.
```

Comprobar que la UI responde dentro de la red `homelab`:

```bash
docker exec prometheus wget -qO- http://uptime-kuma:3001/ | head -5
# <!DOCTYPE html>
# <html lang="">
#   <head>
#     <meta charset="utf-8">
#     <title>Uptime Kuma</title>
```

Comprobar el `/api/entry-page` (endpoint público de Uptime Kuma sin auth):

```bash
docker exec prometheus wget -qO- http://uptime-kuma:3001/api/entry-page
# {"type":"entryPage","entryPage":"console"}    ← antes del setup wizard
# {"type":"statusPageList","statusPageList":[]} ← tras setup, si no hay status pages
```

Confirmar el _bind_ desde Caddy (con TLS):

```bash
curl -k --resolve uptime.lan:443:192.168.1.3 -I https://uptime.lan/
# Esperado: HTTP/2 302
# location: https://auth.lan/?rd=https%3A%2F%2Fuptime.lan%2F
# (Authelia redirige al portal — el forward_auth está activo)
```

---

## Configuración inicial (post-despliegue)

Para validar **end-to-end** la cadena Caddy + Authelia + Uptime Kuma, abrir el navegador en `https://uptime.lan/`:

1. Caddy redirige a `https://auth.lan/?rd=https%3A%2F%2Fuptime.lan%2F`.
2. Authelia pide usuario+contraseña + TOTP (regla `two_factor`).
3. Tras autenticar, Authelia redirige a `https://uptime.lan/`. Uptime Kuma muestra el **_setup wizard_** (sólo en el primer arranque).

### Crear el usuario admin (1ª vez)

En el _setup wizard_:

- **Language**: `Spanish` (o el preferido).
- **Username**: `homelab` (mismo que el usuario de Authelia, por consistencia mental).
- **Password**: una contraseña **distinta** a la de Authelia, generada con un gestor (Vaultwarden cuando llegue, `openssl rand -base64 24` por ahora). Se guarda en el gestor de contraseñas — **no** se mete en `.env`.

Tras "Create": la UI carga el _dashboard_ vacío. Anotar la contraseña inmediatamente; sin ella, recuperar el acceso requiere bajar el contenedor, ejecutar `node extra/reset-password.mjs` dentro y reasignar.

> **Por qué no autoenrol con Authelia**: Uptime Kuma no soporta _auth proxy_ ni OIDC en `1.23.x`. La rama `2.x` lo mete en _roadmap_ pero no está estable.

### Crear los _monitors_ recomendados

Desde **Add New Monitor** (botón superior izquierdo). Para cada servicio _ya desplegado_ del homelab, crear un _monitor_ con esta plantilla:

| Servicio       | Tipo            | URL / Hostname              | Heartbeat | Retries | Notas |
|----------------|-----------------|-----------------------------|-----------|---------|-------|
| Caddy          | HTTP(s)         | `https://uptime.lan/` (a sí mismo via DNS interno: `https://caddy:443/healthz` con `Ignore TLS Errors=ON`) | 60 s | 3 | El `/healthz` lo añadió `docs/03-red/04-caddy.md`. |
| Pi-hole        | DNS             | `192.168.1.2`, _Resolve type_ `A`, _Resolve_ `pi.hole` | 60 s | 3 | Comprueba que el resolver responde, no sólo que la UI vive. |
| Unbound        | DNS             | `192.168.1.4`, _Port_ `5335`, _Resolve type_ `A`, _Resolve_ `cloudflare.com` | 60 s | 3 | Recursivo de verdad: respuesta variable. |
| Authelia       | HTTP(s) keyword | `https://auth.lan/`, _Keyword_ `Authelia`, _Ignore TLS Errors=OFF` (CA local importada en el contenedor — ver Troubleshooting) | 60 s | 3 | _Keyword check_ porque Authelia siempre redirige (302) al landing. |
| Portainer      | HTTP(s)         | `https://portainer.lan/`, _Ignore TLS Errors=OFF` | 120 s | 2 | |
| Prometheus     | HTTP(s)         | `http://prometheus:9090/-/healthy` (DNS interno; sin TLS) | 60 s | 3 | El endpoint nativo `/-/healthy` devuelve `Prometheus is Healthy.`. |
| Grafana        | HTTP(s)         | `http://grafana:3000/api/health` (DNS interno; sin TLS) | 60 s | 3 | `/api/health` devuelve JSON con `database: ok`. |
| Node Exporter  | HTTP(s)         | `http://node-exporter:9100/metrics` | 120 s | 2 | Si el GET no devuelve métricas, hay problema. |
| cAdvisor       | HTTP(s)         | `http://cadvisor:8080/metrics` | 120 s | 2 | |
| Uptime Kuma    | (no se monitoriza a sí mismo) | — | — | — | Si Uptime Kuma cae, **nadie alerta** — es un riesgo asumido. Se puede mitigar con un _push monitor_ desde un cron externo (Healthchecks.io self-hosted, futuro), pero por ahora se acepta. |

Marcar **Notifications** en cada _monitor_: la lista de _channels_ que se va a configurar a continuación.

> **Tags por _stack_**: en cada _monitor_, asignar la _tag_ correspondiente al _stack_ (`infra`, `red`, `seguridad`, `monitor`, …). Permite filtrar el _dashboard_ por _stack_ y agrupar las _status pages_ futuras.

### Configurar notificaciones — Telegram

Desde **Settings → Notifications → Setup Notification**:

- **Notification Type**: `Telegram`.
- **Friendly Name**: `Telegram homelab`.
- **Bot Token**: el token de `@BotFather` (formato `123456789:ABCdefGHI...`). Se guarda en SQLite **cifrado at rest** desde `1.23.x`.
- **Chat ID**: el `chat_id` del _chat_ destino (lo entrega `@userinfobot` o `https://api.telegram.org/bot<token>/getUpdates`).
- **Apply on all existing monitors**: `ON` para los _monitors_ ya creados.
- **Default**: `ON` (los _monitors_ futuros lo heredan).

Botón **Test** → llega un mensaje "Testing OK!" al chat. Si **no llega**: ver _Troubleshooting_.

### Configurar notificaciones — Email (SMTP)

Desde **Settings → Notifications → Setup Notification**:

- **Notification Type**: `Email (SMTP)`.
- **Friendly Name**: `Email homelab`.
- **Hostname**: el SMTP del proveedor (`smtp.gmail.com`, `smtp.fastmail.com`, `mail.protonmail.ch` con _Bridge_…).
- **Port**: `465` (SMTPS) o `587` (STARTTLS) según el proveedor.
- **Secure**: `ON` para `465`, `OFF` para `587` (Uptime Kuma negocia STARTTLS automáticamente en `587`).
- **Username** / **Password**: las credenciales de _app password_ (ej. _app-specific password_ de Gmail si la cuenta tiene 2FA, lo cual debe ser el caso). **Nunca** la contraseña principal.
- **From email**: la cuenta del propio SMTP (`homelab-alerts@<proveedor>.com`).
- **To email**: el buzón personal donde se recibirán las alertas.
- **Apply on all existing monitors**: `ON`.

Botón **Test** → llega un email "Testing message". Si **no llega**: ver _Troubleshooting_.

### Configurar el _general settings_ recomendado

Desde **Settings → General**:

- **Language**: el preferido.
- **Theme**: `dark` (la Pi en idle ahorra ~0.5 W, anecdótico, pero el modo _dark_ del navegador en una pestaña permanente es agradable).
- **Server Timezone**: el del _host_ (`Europe/Madrid`). Coincide con `TZ` del `.env`.
- **Heartbeat Bar Style**: `bottom`.
- **Notification History (days)**: `90` (default razonable; reduce si la SQLite crece más de lo esperado).
- **Heartbeat Retention (days)**: `180` (default). Subir a `365` si se quiere histórico anual; baja a `60` si la SQLite supera 500 MB en un homelab masivo.

---

## Verificación final

Antes de pasar a `docs/05-monitorizacion/06-dozzle.md`, comprobar:

- [ ] `docker compose -f ~/homelab/monitor/docker-compose.yml ps` muestra `uptime-kuma` en estado `Up` y `(healthy)` tras ~3 minutos del primer arranque.
- [ ] `docker logs uptime-kuma --tail 50` muestra `Listening on 3001` y `Server is running` sin _stack traces_.
- [ ] `stat -c '%a %U:%G' /mnt/hd2t/services/uptime-kuma` devuelve `755 root:root` (la imagen oficial corre como root y no se hace `chown`).
- [ ] `ls /mnt/hd2t/services/uptime-kuma/` lista al menos `kuma.db`, `kuma.db-wal`, `kuma.db-shm` y `upload/` con propietario `root:root`.
- [ ] `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` acepta el bloque `uptime.lan`.
- [ ] `curl -k --resolve uptime.lan:443:192.168.1.3 -I https://uptime.lan/` devuelve `302 Found` con `Location: https://auth.lan/?rd=...`.
- [ ] Login interactivo desde el navegador: usuario+contraseña + TOTP de Authelia → `https://uptime.lan/` carga el _setup wizard_ (1ª vez) o el _dashboard_ (siguientes).
- [ ] _Setup wizard_ ejecutado: usuario admin creado y guardado en gestor de contraseñas.
- [ ] Creados al menos los _monitors_ de Caddy, Pi-hole, Unbound, Authelia, Portainer, Prometheus, Grafana, Node Exporter y cAdvisor; **todos** en verde tras 1-2 _heartbeats_.
- [ ] Notification `Telegram homelab` configurada y _Test_ recibido en el _chat_.
- [ ] Notification `Email homelab` configurada y _Test_ recibido en el buzón.
- [ ] Provocar una caída artificial de un servicio (`docker compose -f ~/homelab/monitor/docker-compose.yml stop node-exporter`): tras `retries × heartbeat ≈ 3 min`, llegan **dos** notificaciones (Telegram + email) con título `[node-exporter] [🔴 Down]`. Volver a levantar (`up -d node-exporter`) y verificar que llegan **dos** notificaciones de recuperación.
- [ ] WebSocket activo: dejar la pestaña `https://uptime.lan/dashboard` abierta y comprobar que los _heartbeats_ aparecen en tiempo real (cada 60 s una nueva barra verde) sin recargar.
- [ ] `docker exec prometheus wget -qO- http://caddy:443/healthz --no-check-certificate 2>&1 | tail -2` devuelve `OK` (sanity check del endpoint que el _monitor_ de Caddy va a usar).
- [ ] Tras `docker compose -f ~/homelab/monitor/docker-compose.yml restart uptime-kuma`, todos los _monitors_ siguen presentes (la `kuma.db` persistió), las notificaciones siguen activas, y los _heartbeats_ tienen un _gap_ de ~30 s (el _restart_) seguido de _heartbeats_ verdes.
- [ ] Tras un `sudo reboot` de la Pi, `uptime-kuma` arranca solo (`restart: unless-stopped`), pasa a `(healthy)` en <3 min y los _monitors_ vuelven a verde sin intervención.
- [ ] `docker logs uptime-kuma 2>&1 | grep -iE 'error|fatal' | head` no muestra errores nuevos (los `EAI_AGAIN` esporádicos durante el primer arranque son tolerables — Uptime Kuma reintenta).
- [ ] `git -C ~/homelab status` muestra como **modificados**: `monitor/docker-compose.yml`, `monitor/.env.example`, `red/Caddyfile`, `seguridad/configuration.yml`. **No** muestra `monitor/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add monitor/docker-compose.yml monitor/.env.example \
          red/Caddyfile seguridad/configuration.yml
  git commit -m "feat(monitor): add Uptime Kuma behind Caddy + Authelia 2FA"
  ```

---

## Operaciones habituales

### Añadir un _monitor_ para un servicio nuevo

Cada vez que un doc posterior estrene un servicio que escuche HTTP/TCP, **añadir su _monitor_** a Uptime Kuma como parte del _checklist_ "Verificación final" del propio doc:

1. UI → **Add New Monitor**.
2. Tipo `HTTP(s)` con la URL interna (`http://<servicio>:<puerto>/health` cuando exista, `/` si no).
3. Tag = nombre del _stack_.
4. Notifications = ambos canales (Telegram + email).
5. Save.

Por convención, cada doc de fase posterior incluye la línea **"añadir _monitor_ a Uptime Kuma"** en su _checklist_ de verificación final.

### Exportar la configuración (dump JSON)

Uptime Kuma soporta export/import desde la UI (sin _heartbeats_, sólo `monitors` + `notifications` + `tags` + `status pages`):

```text
Settings → Backup → Export
```

Resultado: descarga un `kuma-backup-YYYY-MM-DD.json`. Útil como **complemento** al _backup_ binario de la SQLite (no sustituto). Guardar en un sitio seguro (no se versiona en git porque contiene tokens cifrados con la _master key_ de la instalación). Una vez al mes manual o como parte del proceso de recuperación documentado en `docs/13-operaciones/02-disaster-recovery.md`.

### Ver `kuma.db` con `sqlite3` (debug)

```bash
docker exec uptime-kuma sqlite3 /app/data/kuma.db "SELECT id, name, type, url, active FROM monitor;"
# 1|Caddy|http|https://caddy:443/healthz|1
# 2|Pi-hole|dns|192.168.1.2|1
# ...
```

> **No editar la BD a mano** salvo que se sepa exactamente lo que se hace — Uptime Kuma cachea estado en memoria y la edición concurrente provoca _drift_.

### Resetear la contraseña del admin

Si se pierde la contraseña del admin (y antes de restaurar desde backup):

```bash
docker exec -it uptime-kuma node extra/reset-password.mjs
# Sigue las instrucciones interactivas — cambia la password del usuario indicado.
```

### Forzar re-creación del contenedor preservando datos

Útil al cambiar `UPTIME_KUMA_IMAGE_TAG` (por ej. de `1.23.13` a `1.23.14`):

```bash
cd ~/homelab/monitor
sed -i 's/^UPTIME_KUMA_IMAGE_TAG=.*/UPTIME_KUMA_IMAGE_TAG=1.23.14/' .env
docker compose pull uptime-kuma
docker compose up -d uptime-kuma
# El bind mount /mnt/hd2t/services/uptime-kuma/ se conserva: kuma.db sigue intacta.
```

### (Opcional) Activar el _scrape_ Prometheus de Uptime Kuma

Tras el primer arranque y creación del usuario admin, si se quiere consumir las métricas de Uptime Kuma desde Prometheus (status de cada monitor como serie temporal):

1. UI → **Settings → API Keys → Generate API Key**. _Name_: `prometheus-scrape`. _Expires_: vacío. _Active_: ON. Copiar la key (sólo se muestra una vez — `uk1_<base64>`).

2. Pegar en `~/homelab/monitor/.env`:

   ```bash
   UPTIME_KUMA_API_KEY=uk1_<base64-from-ui>
   ```

3. Editar `~/homelab/monitor/prometheus/prometheus.yml` y añadir:

   ```yaml
     - job_name: 'uptime-kuma'
       metrics_path: /metrics
       scheme: http
       basic_auth:
         username: ''
         password_file: /etc/prometheus/secrets/uptime_kuma_api_key
       static_configs:
         - targets:
             - 'uptime-kuma:3001'
           labels:
             service: uptime-kuma
             stack:   monitor
       relabel_configs:
         - target_label: instance
           replacement: pi5
   ```

4. Crear el secreto montado en el contenedor de Prometheus:

   ```bash
   mkdir -p ~/homelab/monitor/prometheus/secrets
   chmod 0700 ~/homelab/monitor/prometheus/secrets
   echo -n "$UPTIME_KUMA_API_KEY" > ~/homelab/monitor/prometheus/secrets/uptime_kuma_api_key
   chmod 0600 ~/homelab/monitor/prometheus/secrets/uptime_kuma_api_key
   ```

   Y añadir al servicio `prometheus` del compose un nuevo `volume`:

   ```yaml
       volumes:
         - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
         - ./prometheus/rules:/etc/prometheus/rules:ro
         - ./prometheus/secrets:/etc/prometheus/secrets:ro
         - /mnt/hd2t/services/prometheus/data:/prometheus
   ```

   `~/homelab/monitor/prometheus/secrets/` queda en el `.gitignore` del _stack_.

5. `make up STACK=monitor && docker exec prometheus kill -HUP 1`.

6. `https://prometheus.lan/targets` muestra el _target_ `uptime-kuma` en `UP`. Las métricas `monitor_status`, `monitor_response_time`, `monitor_cert_days_remaining` quedan disponibles para queries en Grafana.

> **Por qué `password_file:` y no `password:` directo**: la API key es un secreto y `prometheus.yml` se versiona en git. `password_file` mantiene el secreto fuera del fichero versionable.

---

## Backup

| Qué                                            | Dónde                                                       | Cómo                                            |
|------------------------------------------------|-------------------------------------------------------------|-------------------------------------------------|
| `docker-compose.yml`                           | `~/homelab/monitor/`                                        | git                                             |
| `Caddyfile` (bloque `uptime.lan`)              | `~/homelab/red/`                                            | git                                             |
| `configuration.yml` (regla `two_factor`)       | `~/homelab/seguridad/`                                      | git                                             |
| `kuma.db` + `upload/` + `error.log`            | `/mnt/hd2t/services/uptime-kuma/`                           | Borgmatic (`docs/07-backups/02-borgmatic.md`)   |
| Export JSON de Uptime Kuma (opcional)          | `Settings → Backup → Export`                                | Manual mensual; guardar en gestor de contraseñas (contiene tokens cifrados con master key) |

> **Restauración**: clonar el repo, restaurar `/mnt/hd2t/services/uptime-kuma/` desde Borgmatic (con el contenedor parado para evitar conflictos del _lock_ de SQLite), `make up STACK=monitor`. En segundos vuelven todos los _monitors_, _notifications_ y _heartbeats_ históricos.

> **Restauración parcial** (sólo recuperar configuración tras corromper la BD): exportar el JSON antes de la corrupción si es posible; tras un arranque limpio, hacer **Import** desde la UI con ese JSON. Se recuperan `monitors` + `notifications` + `tags` + `status pages`. Los _heartbeats_ históricos **se pierden** en este camino — sólo el _backup_ binario los conserva.

---

## Troubleshooting

### `uptime-kuma` arranca y queda `(unhealthy)` con `extra/healthcheck` fallando

Causa típica: en una Pi 5 fría con la SQLite vacía, la primera generación del esquema tarda más que el `start_period=180s` por defecto. Esperar al segundo intento del _healthcheck_ (60 s después) suele resolverlo.

Si persiste:

```bash
docker logs uptime-kuma --tail 100 | grep -iE 'error|migration'
```

Errores típicos:

- `database is locked` durante 5-10 s al arrancar: **normal** mientras se aplican migraciones de esquema. No actuar.
- `SQLITE_CANTOPEN` con permisos: el _bind mount_ no es escribible. `stat /mnt/hd2t/services/uptime-kuma` debe devolver `root:root` con permisos `0755`. Si está como `root:root 0755` y aún falla, comprobar que el _filesystem_ no está montado `noexec,ro` (debería ser `defaults` según `docs/00-hardware/03-preparacion-discos.md`).

### El navegador entra en bucle de redirección entre `uptime.lan` y `auth.lan`

Mismas causas que con Portainer (ver `docs/04-seguridad/01-authelia.md` _Troubleshooting_):

1. Cliente entra por IP en lugar de por nombre — la cookie `Domain=lan` no aplica. Solución: usar siempre `https://uptime.lan/`.
2. Navegador rechaza la cookie por cert no confiado. Solución: importar la CA local (`docs/03-red/04-caddy.md`).
3. `same_site: strict` por error en Authelia. Confirmar `same_site: lax` en `configuration.yml`.

### La UI de Uptime Kuma carga pero los _heartbeats_ no aparecen en vivo (WebSocket no conecta)

Causa típica: el _websocket_ no hace _upgrade_ correctamente a través de Caddy.

Comprobar desde la consola del navegador (DevTools → Network → WS):

- Debe aparecer una conexión a `wss://uptime.lan/socket.io/?EIO=4&transport=websocket` con _status_ `101 Switching Protocols`.
- Si aparece como `400 Bad Request` o no aparece (sólo _polling_): revisar el `Caddyfile` — el `reverse_proxy uptime-kuma:3001` con Caddy v2 debería bastar. Si se ha añadido un _matcher_ que filtra cabeceras (`@x not ...`), reordenar.

```bash
# Probar el upgrade WebSocket desde el host:
docker run --rm --network homelab \
    -e WS_URL=ws://uptime-kuma:3001/socket.io/?EIO=4\&transport=websocket \
    nicolaka/netshoot \
    wscat -c "$WS_URL"
# Debe imprimir un frame Socket.IO; Ctrl+C para salir.
```

### Notification `Telegram homelab`: el _test_ no llega

Causas en orden de probabilidad:

1. **Token incorrecto**: copiar/pegar dejó un espacio o un salto de línea. Borrar el _channel_ y crearlo de nuevo. El _Test_ devuelve un error explícito en la UI (`Error: 401 Unauthorized` para token inválido).
2. **Chat ID incorrecto**: el bot **no está en el _chat_**. Para chats privados: enviar un `/start` al bot al menos una vez. Para grupos: añadir el bot al grupo y enviar al menos un mensaje. Confirmar con:

   ```bash
   curl -fsS "https://api.telegram.org/bot<TOKEN>/getUpdates" | python3 -m json.tool
   # Debe listar al menos un 'message' con 'chat.id' = el que se introdujo en la UI.
   ```

3. **Salida bloqueada**: si Pi-hole o un _firewall_ bloquean `api.telegram.org`. Confirmar con:

   ```bash
   docker exec uptime-kuma wget -qO- https://api.telegram.org/bot<TOKEN>/getMe
   # {"ok":true,"result":{...}}
   ```

   Si `wget` no resuelve: `docker exec uptime-kuma cat /etc/resolv.conf` debe apuntar al _embedded DNS_ de Docker (`127.0.0.11`); más allá, Pi-hole debe estar resolviendo `api.telegram.org` (no debería estar en una _blocklist_; ningún _block_ default lo incluye).

### Notification `Email homelab`: el _test_ no llega

Causas en orden de probabilidad:

1. **App password mal escrita**: los _app passwords_ de Gmail van **sin espacios** (la UI de Google los muestra con espacios cosméticos cada 4 chars).
2. **Puerto / `Secure` discordantes**: `465` requiere `Secure=ON`; `587` requiere `Secure=OFF` (Uptime Kuma negocia STARTTLS por su cuenta).
3. **From email ≠ Username**: algunos proveedores (Gmail, ProtonMail) **rechazan** _Mail-From_ que no coincida con el _login_; ponerlos iguales.
4. **El proveedor exige verificación adicional**: algunos SMTPs (SES, SendGrid) requieren _verified senders_ — completar ese flujo en su dashboard.

Para depurar, mirar `docker logs uptime-kuma --tail 50 -f` y disparar el _Test_ — el error real (`535 5.7.0 Authentication failed`, `421 4.7.0 Try again later`) aparece en los _logs_.

### Un _monitor_ HTTP(s) hacia un `*.lan` falla con `unable to verify the first certificate`

El contenedor Uptime Kuma **no confía** en la CA local del homelab — la imagen oficial trae sólo los CAs públicos. Dos opciones:

1. **Marcar `Ignore TLS Errors=ON`** en el _monitor_: simple y aceptable para servicios internos. La CA local ya garantiza confidencialidad; lo que se pierde es la garantía de "el cert no ha cambiado". Para un homelab en LAN+Tailscale es asumible.

2. **Inyectar la CA local en el contenedor**: montar `~/homelab/red/caddy/data/caddy/pki/authorities/local/root.crt` como `/etc/ssl/certs/homelab-ca.crt` y configurar `NODE_EXTRA_CA_CERTS=/etc/ssl/certs/homelab-ca.crt` como variable de entorno. Más limpio. Si se hace, añadir al `docker-compose.yml`:

   ```yaml
       environment:
         TZ: ${TZ}
         NODE_EXTRA_CA_CERTS: /etc/ssl/certs/homelab-ca.crt
       volumes:
         - /mnt/hd2t/services/uptime-kuma:/app/data
         - /mnt/hd2t/services/caddy/data/caddy/pki/authorities/local/root.crt:/etc/ssl/certs/homelab-ca.crt:ro
   ```

   La _path_ exacta de la CA local depende de cómo `docs/03-red/04-caddy.md` la materializó. Comprobar con `docker exec caddy ls /data/caddy/pki/authorities/local/` antes de montarla.

### Un _monitor_ DNS hacia Pi-hole devuelve "DNS query timeout"

Causas:

- **Puerto incorrecto**: Pi-hole responde en `:53/udp` (UDP). Si en la UI se puso `:5335`, ese es Unbound, **no** Pi-hole. Revisar `docs/03-red/02-pihole.md`.
- **Pi-hole en macvlan, no en `homelab`**: Pi-hole está en su propia red macvlan con IP propia (`192.168.1.2`). Uptime Kuma debe contactarla por **IP**, no por DNS interno (no hay alias). El _monitor_ DNS debe usar `192.168.1.2`.

### Tras `docker compose pull` con _bump_ a `1.24.x`, la UI no carga (pantalla blanca)

Posible cambio de esquema entre _minors_ que requirió migración no automática. Revertir:

```bash
cd ~/homelab/monitor
sed -i 's/^UPTIME_KUMA_IMAGE_TAG=.*/UPTIME_KUMA_IMAGE_TAG=1.23.13/' .env
docker compose up -d uptime-kuma
```

Y abrir un _issue_ aguas arriba; o restaurar `/mnt/hd2t/services/uptime-kuma/` desde el Borg justo previo al _bump_ y reintentar tras leer las _release notes_ del _minor_ destino.

### `error.log` crece sin parar

Si `/mnt/hd2t/services/uptime-kuma/error.log` crece más de 100 MB, es síntoma de algún _monitor_ defectuoso (URL que devuelve siempre 500, certificado que rota cada minuto, …). Identificar el monitor culpable:

```bash
docker exec uptime-kuma tail -200 /app/data/error.log | sed 's/.*Monitor: //;s/ -.*//' | sort | uniq -c | sort -rn | head
```

Y o bien arreglar el _target_, o bien borrar/desactivar el monitor desde la UI.

---

## Referencias

- Uptime Kuma — Repo y _release notes_: <https://github.com/louislam/uptime-kuma>
- Uptime Kuma — Wiki (configuración avanzada): <https://github.com/louislam/uptime-kuma/wiki>
- Uptime Kuma — Imagen Docker oficial: <https://hub.docker.com/r/louislam/uptime-kuma>
- Uptime Kuma — Integración Prometheus (`/metrics` + API key): <https://github.com/louislam/uptime-kuma/wiki/Prometheus-Integration>
- Uptime Kuma — Lista de notificaciones soportadas: <https://github.com/louislam/uptime-kuma/tree/master/server/notification-providers>
- Telegram — Crear un bot vía `@BotFather`: <https://core.telegram.org/bots/tutorial>
- SMTP — `nodemailer` (subyacente a las _SMTP notifications_ de Uptime Kuma): <https://nodemailer.com/smtp/>
- Caddy — `reverse_proxy` y manejo nativo de WebSocket: <https://caddyserver.com/docs/caddyfile/directives/reverse_proxy>
