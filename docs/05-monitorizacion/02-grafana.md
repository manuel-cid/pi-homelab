# Grafana (dashboards y visualización de métricas)

## Descripción

Despliegue de **Grafana OSS** como _frontend_ de visualización del homelab. Grafana lee series de **Prometheus** (`docs/05-monitorizacion/01-prometheus.md`) y las pinta en _dashboards_: estado del propio Prometheus por ahora, y _Node Exporter Full_ / _cAdvisor_ / _Pi-hole_ / temperatura del SoC en cuanto los _exporters_ vayan llegando en los siguientes documentos de esta fase. Grafana se publica como `https://grafana.lan` detrás de Caddy con HTTPS interno y se delega la autenticación a **Authelia (2FA)** mediante _auth proxy_: el usuario entra una sola vez por el portal y Grafana lee su identidad de la cabecera `Remote-User` que Caddy le pasa.

Este documento **se suma al _stack_ `monitor`** ya estrenado en `docs/05-monitorizacion/01-prometheus.md`. No crea un _stack_ nuevo: añade el servicio `grafana` al mismo `docker-compose.yml`, mete su _data_ en `/mnt/hd2t/services/grafana/data/`, deja un árbol de _provisioning_ (`datasources/`, `dashboards/`) versionable en git y enchufa Prometheus como _datasource_ por defecto **sin tocar la UI**. También añade un primer _dashboard_ — **Prometheus 2.0 Stats** (ID `3662`) — ya conectado al _datasource_, de modo que al primer _login_ se ve algo más allá de la página vacía.

> **Alcance**: este documento despliega Grafana, define su _provisioning_ de _datasource_ y _dashboards_, lo expone vía Caddy + Authelia 2FA con _auth proxy_, añade un _scrape_job_ `grafana` a `prometheus.yml` (Grafana expone `/metrics` Prometheus-compatible) y crea el `grafana.lan` en la regla `two_factor` de Authelia. **No** instala _plugins_ (Grafana se queda con los _datasources_ y paneles de fábrica, suficientes para Prometheus). **No** activa SMTP (las _alerts_ de Grafana se delegan a Uptime Kuma — `docs/05-monitorizacion/05-uptime-kuma.md`). **No** activa _alerting_ unificado de Grafana (mismo motivo). **No** monta una BD externa: SQLite incrustado es suficiente para un Grafana de un solo operador.

> **Recordatorio de red**: Grafana **no se publica al host**. Caddy la alcanza por DNS interno de Docker (`grafana:3000`) dentro de la red `homelab`. El operador entra por `https://grafana.lan/`, que Pi-hole resuelve a `192.168.1.3` (_wildcard_ de `02-homelab-local.conf`) y Caddy demultiplexa por SNI. Authelia exige 2FA antes de exponer la UI.

---

## Requisitos previos

- `docs/05-monitorizacion/01-prometheus.md` completado: el _stack_ `monitor` existe en `~/homelab/monitor/`, `docker-compose.yml` ya define `prometheus`, `prometheus.yml` está activo y `https://prometheus.lan/` responde tras 2FA. **Grafana lee de él**: si Prometheus no está vivo, el _datasource_ falla en el _health-check_ y los _dashboards_ salen vacíos.
- `docs/04-seguridad/01-authelia.md` completado: `https://auth.lan/` operativo con TOTP, _snippet_ `(authelia)` activo en `~/homelab/red/caddy/snippets/authelia.caddy`, `access_control` con la regla `two_factor` ya conteniendo `portainer.lan` y `prometheus.lan`. Este doc añade `grafana.lan` a esa lista.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, _snippets_ `security-headers`, `logging` y `authelia` operativos, `import /etc/caddy/snippets/*.caddy` activo en el `Caddyfile`.
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `grafana.lan` — el wildcard ya lo cubre.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/grafana/data/` ya existe vacío `root:root 0755` (la propia tabla de UIDs internos de aquel doc anota que el contenedor corre como `grafana (472)` y deja la reasignación de _ownership_ "para el doc de la fase concreta" — la hace este).
- Conectividad saliente para descargar la imagen:

  ```bash
  docker pull --platform linux/arm64 grafana/grafana-oss:11.5.2 >/dev/null && echo OK
  ```

- Que el host **no** tenga ya un servicio escuchando en `:3000`:

  ```bash
  sudo ss -tulpn '( sport = :3000 )'
  ```

  Salida esperada: vacía. Grafana no publica `:3000` al host, pero conviene confirmar que ningún binario residual (Node-RED en pruebas, etc.) lo ocupa antes del primer `up`.

---

## Decisiones de diseño

### Por qué Grafana OSS (y no Grafana Cloud / Chronograf / Perses)

| Candidato            | Por qué se descarta                                                                                                                                                                                                                                       |
|----------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Grafana Cloud**    | Servicio gestionado: no encaja en un homelab _air-gapped_ (sólo LAN + Tailscale). Además fuerza dependencia de un _SaaS_ externo y aplica límites en el _free tier_ que terminan estorbando.                                                          |
| **Chronograf**       | _Frontend_ histórico del _stack_ TICK (InfluxDB). El homelab usa Prometheus, así que su mejor caja de cristal es Grafana. Chronograf sin InfluxDB es una herramienta de nicho.                                                                            |
| **Perses**           | Reescritura "moderna" de Grafana en Go con dashboards declarativos (YAML/JSON puro). Prometedor, pero en 2026 todavía en _beta_, sin ecosistema de _dashboards_ comparable y con poca tracción ARM64. Buen candidato para revisar dentro de 1–2 años.    |
| **Grafana Enterprise** | El propio binario está en la imagen `grafana/grafana` y ofrece el _nag_ recurrente "estás usando funciones Enterprise" si se activan _data sources_ premium. La imagen **`grafana/grafana-oss`** es idéntica funcionalmente para nuestro uso y elimina ese ruido. |

Grafana OSS gana por:

- **Compatibilidad nativa con Prometheus**: el _datasource_ es de fábrica, los _dashboards_ públicos de Grafana Labs (`Node Exporter Full` 1860, `Docker cAdvisor` 14282, `Prometheus 2.0 Stats` 3662, …) funcionan _out-of-the-box_.
- **_Provisioning_ declarativo**: _datasources_ y _dashboards_ se definen como ficheros YAML / JSON en disco, versionables en git. Cero configuración a mano por la UI; cualquier operador que clone el repo y haga `make up STACK=monitor` levanta una Grafana **idéntica**.
- **_Auth proxy_ nativo**: Grafana sabe leer una cabecera HTTP (`Remote-User`) y crear/reutilizar el usuario interno automáticamente. Es el _hook_ exacto que Authelia + Caddy proveen, sin OIDC ni LDAP.
- **Footprint razonable**: ~120–180 MB RAM en idle con SQLite y 5–10 _dashboards_. ARM64 _native_, _multi-stage build_ pequeño.
- **Migración futura**: si en algún momento se quiere _alerting_ unificado, _datasource_ Loki para logs, o un _stack_ Grafana → VictoriaMetrics, el cambio es incremental y no requiere reescribir el _provisioning_ existente.

### Stack `monitor` — Grafana se suma sin red privada

Igual que Prometheus, Grafana se conecta directamente a la red compartida `homelab`. Razones:

- **Prometheus es accesible por DNS interno (`prometheus:9090`)** desde la misma red, así que el _datasource_ apunta a esa URL sin gimnasia adicional.
- **Caddy habla con Grafana por DNS interno (`grafana:3000`)** y le pasa la cabecera `Remote-User` desde Authelia.
- **No hay ningún componente _interno_ a Grafana que justifique una `monitor-internal`**: SQLite vive en el _bind mount_ (no es un servicio en red) y Grafana no necesita una BD externa por ahora.

Cuando un futuro doc decida montar un Postgres exclusivo del _stack_ (p. ej. para Grafana _alerting_ unificado, o porque SQLite empieza a quedarse corto con muchos _dashboards_), se creará la red privada `monitor-internal` en ese momento.

### Imagen y _tag_

- **`grafana/grafana-oss:11.5.2`** — Grafana OSS **11.5**, multi-arch con `linux/arm64`, imagen oficial publicada por Grafana Labs. Pinneada a versión completa (convención del homelab: nada de `:latest`, nada de `:11`, nada de `:11.5`).
- **Por qué OSS y no `grafana/grafana`**: idéntica para los _data sources_ del homelab (Prometheus). La variante `grafana/grafana` arranca con Enterprise apagado, pero pinta un _banner_ y permite activarlo accidentalmente; la OSS evita el ruido.
- **Por qué 11.x y no 10.x LTS**: Grafana 11 (lanzada en 2024) consolida el motor de _Scenes_ (paneles reactivos), unifica _alerting_ y trae mejoras de rendimiento en ARM. Lo que toca a abril de 2026 es la rama `11.x` mainstream.
- **Watchtower opt-out** (`com.centurylinklabs.watchtower.enable: "false"`):
  - Entre _patches_ (`11.5.2 → 11.5.3`) los upgrades son seguros, pero **entre minors** Grafana corre **migraciones de esquema en la SQLite** al arrancar la nueva versión. Un upgrade ciego que coincida con un cambio de esquema deja la BD inconsistente si el _restart_ se interrumpe (p. ej. por OOM en la Pi). El _rollback_ entre minors **no está soportado**: la BD migrada hacia delante no la lee la versión anterior.
  - Las migraciones son rápidas (segundos) y casi siempre limpias, pero el riesgo > beneficio para un homelab personal. Las _release notes_ de cada minor se leen y la actualización se hace a mano con `make pull STACK=monitor && make up STACK=monitor` en una ventana de mantenimiento.

### Autenticación: _auth proxy_ con cabecera `Remote-User` (no OIDC, no login form)

Grafana soporta **cinco** modos de autenticación: _basic_ (login form), LDAP, OAuth/OIDC, _auth proxy_ y _anonymous_. En este homelab:

- **Login form** (`auth.basic`) **deshabilitado**: no queremos que un atacante con acceso LAN _bypassee_ Authelia metiéndose por la pantalla nativa de Grafana (`https://grafana.lan/login`). Quedan dos vías legítimas: por Authelia o, en emergencia, manualmente desde el host (variable de entorno `GF_SECURITY_ADMIN_PASSWORD` y un acceso temporal directo al puerto 3000 — ver _Troubleshooting_).
- **OIDC (Authelia como _provider_)** **descartado por ahora**: requiere activar el OIDC _provider_ de Authelia (`docs/04-seguridad/01-authelia.md` lo dejó sin habilitar), generar un cliente, registrar redirect URLs, gestionar _claims_ y _scopes_. Es la opción "correcta" cuando el homelab tenga 5+ servicios pidiendo SSO con _claims_ ricos (Nextcloud, Outline, Vaultwarden), pero para Grafana solo, el _auth proxy_ entrega lo mismo (usuario + grupos) con dos líneas de configuración. La transición a OIDC, cuando llegue, no requiere migrar usuarios: Grafana auto-asocia por _login_.
- **_Auth proxy_** **activado**: Grafana lee la cabecera `Remote-User` (que Caddy ya copia desde la respuesta de Authelia gracias al _snippet_ `(authelia)`) y, si el usuario no existe en su BD, lo crea automáticamente (`auto_sign_up = true`). El `Remote-Groups` mapea a un _role_ de Grafana (`Admin` / `Editor` / `Viewer`) según una lista en `grafana.ini`. Resultado: un solo punto de autenticación (Authelia), un solo factor humano (TOTP), y Grafana recibe la identidad ya validada.

> **Cabecera `Remote-User` y no `X-WEBAUTH-USER`**: Grafana usa por defecto `X-WEBAUTH-USER`, pero el _snippet_ `(authelia)` ya entrega `Remote-User` (y `Remote-Groups`, `Remote-Name`, `Remote-Email`). Es más limpio configurar Grafana para leer `Remote-*` que añadir un `header_up X-WEBAUTH-USER {http.auth.user.id}` ad-hoc en el _Caddyfile_ — esto último mezcla concerns y exige acordarse en cada servicio futuro. La cabecera `Remote-*` es la _lingua franca_ del SSO en el homelab.

> **Whitelist del _auth proxy_**: Grafana exige que el `Remote-User` venga de una IP **autorizada** (parámetro `auth.proxy.whitelist`), porque si no, cualquiera con acceso al puerto 3000 podría inyectar la cabecera y hacerse pasar por _admin_. Se autoriza **únicamente la subred `172.20.10.0/24`** (la red Docker `homelab`, definida en `docs/02-docker/02-estructura-compose.md`), que es por donde llega Caddy. Las peticiones desde el host (`127.0.0.1`) o desde otras redes son rechazadas con `407 Proxy Authentication Required`.

### Provisioning: _datasource_ y _dashboards_ por fichero, no por UI

Grafana arranca leyendo `/etc/grafana/provisioning/{datasources,dashboards,notifiers,plugins,alerting}/*.yml`. Eso permite tener:

- **Un `datasources/prometheus.yml`** con el _datasource_ Prometheus apuntando a `http://prometheus:9090`, marcado como `default` y como `editable: false` (la UI no lo deja modificar — tienes que tocar el fichero y recargar Grafana).
- **Un `dashboards/default.yml`** declarando un _provider_ de _dashboards_ que escanea `/var/lib/grafana/dashboards/*.json` cada 30 s. Cada doc posterior de la fase 5 (Node Exporter, cAdvisor, …) **deja caer su `.json`** en `~/homelab/monitor/grafana/dashboards/` y el _dashboard_ aparece sin reiniciar Grafana.
- **Un `dashboards/prometheus-stats.json`** baseline (ID 3662 de Grafana Labs, exportado y comprometido al repo) que sirve para verificar el _datasource_ y como ejemplo de cómo se versiona un _dashboard_.

Ventajas del _provisioning_:

- **_Diff_ legible en git**: cada cambio de dashboard se ve como un _diff_ de JSON revisable.
- **Recuperación trivial**: borrar `grafana/data/grafana.db` y recrearla con `make up` deja Grafana **exactamente como estaba**. El estado en SQLite (anotaciones, alertas, snapshots, preferencias de UI) **se pierde** — es el coste asumido.
- **Convención**: el doc del _exporter_ que estrene un _dashboard_ es el responsable de aportar su `.json` y de citar la fuente (ID público o autor). No se guardan _dashboards_ tocados por la UI sin volcarlos antes a fichero.

> **Trade-off explícito**: Grafana también soporta editar _dashboards_ por la UI y guardar cambios "en la BD". Aquí los _dashboards_ provisionados se marcan `allowUiUpdates: false` y `disableDeletion: true`, así que la UI permite **editar y exportar JSON** (al portapapeles), pero **no** persiste cambios. El flujo es: editar en UI → exportar JSON → reemplazar el fichero en `~/homelab/monitor/grafana/dashboards/` → `git commit`. Estricto pero predecible.

### SQLite incrustado (no MariaDB / Postgres)

Grafana soporta SQLite, MySQL/MariaDB y Postgres como BD interna (usuarios, _dashboards_ no provisionados, _annotations_, _alerts_, sesiones). En este homelab **SQLite gana**:

- **Single-user, single-instance**: no hay réplica horizontal de Grafana, ni concurrencia significativa. SQLite con WAL + `journal_mode=WAL` da `>1000 req/s` en una Pi 5 — varios órdenes de magnitud por encima de lo que necesitamos.
- **Cero servicios extra**: nada de un Postgres dedicado a Grafana en `monitor-internal`. Cada BD nueva en el homelab es un _backup_ más, una _release_ más a vigilar, RAM permanente que se gasta.
- **Backup trivial**: el fichero `grafana.db` (y su `grafana.db-wal`, `grafana.db-shm`) son _bind mount_ en `/mnt/hd2t/services/grafana/data/`, los recoge Borgmatic con la _label_ `homelab.backup: "true"`. Como Grafana no escribe constantemente (solo cuando hay cambios de UI), el _backup_ es consistente _online_ sin necesidad de _hooks_ pre/post.
- **Migración futura**: si en algún momento Grafana se vuelve crítico (>1 operador, _dashboards_ con _snapshots_ frecuentes), se monta un Postgres en `monitor-internal` y se exporta la `grafana.db` con `grafana-cli admin reset-admin-password` + `sqlite3 → pg_dump`. No hay _vendor lock-in_.

### Storage en `hd2t` (no en microSD)

`/mnt/hd2t/services/grafana/data/` por las mismas razones que Prometheus:

1. **Volumen de escritura**: aunque Grafana escribe poco, las migraciones de esquema (en _bumps_ de minor) reescriben tablas enteras. Hacerlo en microSD acelera el desgaste sin necesidad.
2. **Backup**: `/mnt/hd2t/services/grafana/data/` entra en Borgmatic. Recuperar todos los _dashboards_ provisionados se hace desde git, pero el `grafana.db` lleva preferencias del _user_, _snapshots_ y _alerts_ que conviene no perder.

### Owner del directorio: `grafana (472)`

La imagen oficial corre como `grafana:grafana` (UID 472, GID 472) y aborta si no puede escribir el _bind mount_. La tabla de UIDs de `docs/01-sistema/04-estructura-directorios.md` ya anota esto. Aquí se aplica el `chown`:

```bash
sudo chown -R 472:472 /mnt/hd2t/services/grafana/data
sudo chmod 0750 /mnt/hd2t/services/grafana/data
```

> **No usar `:Z` ni `:U` en el _bind mount_**: SELinux no está activado en Raspberry Pi OS.

### Acceso vía Caddy + Authelia 2FA — `grafana.lan`

Mismo patrón que Prometheus. Como Grafana **revela toda la telemetría** del homelab (CPU, RAM, _hostnames_, patrones de acceso de Pi-hole, contadores de Authelia…), la política se eleva a **`two_factor`**: usuario+contraseña + TOTP/WebAuthn.

Este doc añade `grafana.lan` a la lista `two_factor` que `01-prometheus.md` ya dejó preparada con `prometheus.lan`.

> **Auto sign-up**: la primera vez que un usuario válido en Authelia visita `https://grafana.lan/`, el _auth proxy_ crea su cuenta en Grafana automáticamente con _role_ `Viewer` por defecto (configurable). Si quieres que sea `Admin`, se mapea por la cabecera `Remote-Groups` (sección **`grafana.ini`**) — el grupo `admins` de `users_database.yml` se asigna a `Admin` y el resto a `Viewer`.

### Watchtower opt-out + _label_ `homelab.backup: "true"`

```yaml
labels:
  homelab.stack: "monitor"
  homelab.backup: "true"
  com.centurylinklabs.watchtower.enable: "false"
```

- `homelab.backup: "true"` → Borgmatic recoge `/mnt/hd2t/services/grafana/data/` (justificación: la `grafana.db` con _users_ y _snapshots_).
- `watchtower.enable: "false"` → no se actualiza solo (justificación arriba: migraciones de esquema entre _minors_).

---

## Almacenamiento

| Ruta en el host                                                       | Contenido                                                                  | Versionable | Backup |
|-----------------------------------------------------------------------|----------------------------------------------------------------------------|-------------|--------|
| `~/homelab/monitor/docker-compose.yml`                                | Definición del _stack_ (modificada)                                         | git         | git    |
| `~/homelab/monitor/grafana/grafana.ini`                               | Configuración principal de Grafana (sin secretos)                          | git         | git    |
| `~/homelab/monitor/grafana/provisioning/datasources/prometheus.yml`   | _Datasource_ Prometheus auto-provisionado                                  | git         | git    |
| `~/homelab/monitor/grafana/provisioning/dashboards/default.yml`       | _Provider_ de _dashboards_ que escanea `/var/lib/grafana/dashboards/`     | git         | git    |
| `~/homelab/monitor/grafana/dashboards/prometheus-stats.json`          | Dashboard baseline (ID 3662 de Grafana Labs)                                | git         | git    |
| `~/homelab/monitor/.env`                                              | `GRAFANA_IMAGE_TAG`, `GF_SECURITY_ADMIN_PASSWORD` (secreto)                 | **NO** (`.gitignore`) | git aparte (nota local) |
| `~/homelab/monitor/.env.example`                                      | Plantilla con nombres de variables                                          | git         | git    |
| `/mnt/hd2t/services/grafana/data/`                                    | `grafana.db` (SQLite), `grafana.db-wal`, `plugins/`, `png/`, `csv/`         | **NO**      | **Sí** (Borgmatic) |

> **`grafana.db` se respalda en caliente**: Grafana usa SQLite con `journal_mode=WAL`, las escrituras son atómicas y los _readers_ (Borg) no bloquean a los _writers_. Para una restauración _bit-perfect_, basta con `docker compose stop grafana`, restaurar el directorio desde el _archive_ Borg, y `docker compose up -d`.

---

## Estructura del _stack_ `monitor` tras este documento

```
~/homelab/monitor/
├── docker-compose.yml              # ← modificado (servicio 'grafana' añadido)
├── .env                            # ← modificado (GRAFANA_*)
├── .env.example                    # ← modificado (GRAFANA_*)
├── .gitignore                      # (sin cambios)
├── prometheus/
│   ├── prometheus.yml              # ← modificado (job_name 'grafana' añadido)
│   └── rules/
│       └── .gitkeep
└── grafana/                        # ← nuevo
    ├── grafana.ini                 # ← nuevo
    ├── provisioning/               # ← nuevo
    │   ├── datasources/
    │   │   └── prometheus.yml      # ← nuevo
    │   └── dashboards/
    │       └── default.yml         # ← nuevo
    └── dashboards/                 # ← nuevo
        └── prometheus-stats.json   # ← nuevo (ID 3662, descargado)
```

Y en los discos externos:

```
/mnt/hd2t/services/grafana/
└── data/                           # creado en docs/01-sistema/04-estructura-directorios.md
                                    #   - chown 472:472 en este doc
                                    #   - Grafana crea grafana.db, plugins/, png/, csv/ al primer arranque
```

Crear los directorios y fijar permisos:

```bash
# Subdirectorio del propio servicio
mkdir -p ~/homelab/monitor/grafana/{provisioning/datasources,provisioning/dashboards,dashboards}
chmod 0750 ~/homelab/monitor/grafana
chmod -R 0750 ~/homelab/monitor/grafana/provisioning
chmod 0750 ~/homelab/monitor/grafana/dashboards

# Estado de Grafana: la imagen oficial corre como UID 472 (grafana).
# El directorio existe ya (creado en docs/01-sistema/04-estructura-directorios.md),
# pero estaba en root:root 0755. Ajustar:
sudo chown -R 472:472 /mnt/hd2t/services/grafana/data
sudo chmod 0750 /mnt/hd2t/services/grafana/data
```

---

## Variables de entorno

Editar `~/homelab/monitor/.env.example` y añadir, debajo del bloque de Prometheus:

```bash
# --- Grafana ----------------------------------------------------------------
GRAFANA_IMAGE_TAG=11.5.2

# Usuario/clave admin de fallback. SOLO se usa si se reactiva el login form
# nativo (ver Troubleshooting > Recuperación de admin). Con auth.proxy
# activo no es necesario para el día a día.
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=cambiame

# Clave secreta interna de Grafana — firma cookies, tokens de invite, etc.
# Generar con: openssl rand -base64 32
GRAFANA_SECRET_KEY=cambiame

# URL pública del servicio. Se inyecta como GF_SERVER_ROOT_URL para que
# Grafana construya enlaces absolutos correctos (snapshots, share-links).
GRAFANA_ROOT_URL=https://grafana.lan
```

Reflejar en `~/homelab/monitor/.env` (no versionado) **con valores reales**:

```bash
cd ~/homelab/monitor
# Actualizar .env desde la plantilla (sin pisar valores ya rellenos):
# Si no existe la sección, añadirla:
grep -q '^GRAFANA_IMAGE_TAG=' .env || cat >> .env <<EOF

# --- Grafana ---
GRAFANA_IMAGE_TAG=11.5.2
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 24)
GRAFANA_SECRET_KEY=$(openssl rand -base64 32)
GRAFANA_ROOT_URL=https://grafana.lan
EOF
chmod 0600 .env
```

> Anotar `GRAFANA_ADMIN_PASSWORD` en el gestor de credenciales personal **antes** de continuar. Con _auth proxy_ activo y _login form_ deshabilitado, no se va a pedir nunca por la UI, pero hace falta para la recuperación de emergencia documentada al final.

---

## `~/homelab/monitor/grafana/grafana.ini`

Configuración principal de Grafana, montada read-only en `/etc/grafana/grafana.ini`. **Sin secretos** — los _admin password_ y _secret key_ van por _env_ (`GF_SECURITY_*`) inyectados desde `.env`.

```ini
# =============================================================================
# Grafana — configuración principal
# Documentación: docs/05-monitorizacion/02-grafana.md
# Las variables marcadas como ${...} se interpolan vía env vars del contenedor
# (Grafana respeta GF_<SECTION>_<KEY> y override del .ini).
# =============================================================================

[server]
protocol = http
http_port = 3000
domain = grafana.lan
# El root_url se inyecta también vía GF_SERVER_ROOT_URL en el compose, pero lo
# dejamos aquí por claridad y para que un 'grafana-cli' local funcione.
root_url = %(protocol)s://%(domain)s/
serve_from_sub_path = false
enforce_domain = false
# Detrás de Caddy: Caddy ya pone X-Forwarded-Proto y Grafana lo respeta para
# generar URLs https en redirecciones internas (snapshots, etc).
enable_gzip = true

[database]
type = sqlite3
path = grafana.db
# WAL: lectores no bloquean a escritores; backup en caliente sin parar.
wal = true

[security]
# Cookies de sesión solo sobre HTTPS.
cookie_secure = true
cookie_samesite = lax
disable_initial_admin_creation = false
# Endurecimiento básico de embedding/CSP — Grafana detrás de Caddy no se
# debería embeber en otro origen. El snippet 'security-headers' del Caddyfile
# refuerza esto a nivel de proxy.
allow_embedding = false
strict_transport_security = false   # lo pone Caddy en (security-headers)
content_security_policy = false     # idem; evitamos doble cabecera

[users]
# auth.proxy crea usuarios automáticamente cuando los autoriza Authelia.
auto_assign_org = true
auto_assign_org_id = 1
# Rol por defecto al auto-crear. Se sobreescribe por grupo (sección abajo).
auto_assign_org_role = Viewer
# El usuario nunca podrá cambiar su clave por la UI (no hace falta — viene
# de Authelia) y la opción 'invitar' queda desactivada (todo va por SSO).
allow_sign_up = false
allow_org_create = false
viewers_can_edit = true
editors_can_admin = false

[auth]
# IMPORTANTE: con auth.proxy ON queremos que NO haya forma de saltarse
# Authelia. Login form, signup, password reset y oauth: todo OFF.
disable_login_form = true
disable_signout_menu = false
oauth_auto_login = false
# El "anónimo" se queda en false explícito; nadie ve nada sin autenticarse.

[auth.anonymous]
enabled = false

[auth.basic]
enabled = false

[auth.proxy]
enabled = true
# Caddy entrega 'Remote-User' desde Authelia (snippet (authelia)).
header_name = Remote-User
header_property = username
# 'true' = si la cabecera trae un usuario inexistente, Grafana lo crea.
# Cobertura: el primer login de cualquier usuario LDAP/Authelia funciona
# sin pasos manuales.
auto_sign_up = true
# Cabeceras adicionales que Grafana mapea a campos del perfil.
# Authelia + Caddy ya copian Remote-Email, Remote-Name, Remote-Groups.
headers = Email:Remote-Email Name:Remote-Name Groups:Remote-Groups
# Sólo se confía en Remote-User si la petición viene de Caddy en homelab.
# Sin esto, cualquiera con acceso al puerto 3000 (en una hipotética
# brecha del docker-network) podría suplantar al admin con curl -H
# 'Remote-User: admin'.
whitelist = 172.20.10.0/24
# Cache del lookup de usuario para no martillear la BD en cada request.
sync_ttl = 60
# El 'enable_login_token' debe quedar en false: en su lugar Caddy/Authelia
# gestionan la sesión.
enable_login_token = false

[auth.proxy.headers]
# Mapeo de Remote-Groups -> rol de Grafana. Authelia entrega los grupos
# como 'admins,users' separados por coma. Grafana 11+ permite mapear con
# org_role_attribute en JMESPath; lo dejamos vía el [users] auto_assign_org_role
# por simplicidad. Para promocionar a un Admin, se hace UNA vez vía CLI:
#   docker exec grafana grafana-cli admin reset-admin-password ...
# o vía la propia UI siendo otro Admin.
# (no hay 'mapping' nativo simple en grafana.ini sin OIDC, así que
#  documentamos el camino manual.)

[snapshots]
# Snapshots globales (compartibles en internet) deshabilitados — el homelab
# no expone nada al público.
external_enabled = false

[analytics]
reporting_enabled = false
check_for_updates = false
# Telemetría OFF — homelab privado.

[log]
mode = console
level = info

[alerting]
# Alerting unificado: deshabilitado en este homelab. Se delega a Uptime Kuma.
enabled = false
execute_alerts = false

[unified_alerting]
enabled = false

[metrics]
# /metrics interno de Grafana (Prometheus-compatible). Sin auth — el
# endpoint sólo es alcanzable desde la red 'homelab' (no published port).
enabled = true
# basic_auth_username/password no se rellenan: Prometheus lo scrapea sin auth.

[plugins]
# No instalar plugins automáticamente. Si en algún futuro doc se necesita
# uno, se rellena 'GF_PLUGINS_PREINSTALL' en el .env. La política por
# defecto es: minimal install.
allow_loading_unsigned_plugins =
plugin_admin_enabled = false
public_key_retrieval_disabled = true

[smtp]
enabled = false
```

Permisos:

```bash
chmod 0644 ~/homelab/monitor/grafana/grafana.ini
```

---

## `~/homelab/monitor/grafana/provisioning/datasources/prometheus.yml`

Auto-provisión del _datasource_ Prometheus. Versión `1` del _schema_ de _provisioning_ (compatible con Grafana 8+).

```yaml
---
# Datasource Prometheus auto-provisionado.
# Documentación: docs/05-monitorizacion/02-grafana.md
# La UI mostrará 'Prometheus' como datasource, marcado read-only.
# Para cambiar la URL o las opciones, EDITAR ESTE FICHERO y recargar Grafana
# (no se acepta edición vía UI: 'editable: false').

apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy            # Grafana hace el query lado servidor (no el navegador)
    url: http://prometheus:9090
    isDefault: true
    editable: false
    jsonData:
      # Coincide con el scrape_interval de Prometheus (.env del stack monitor).
      timeInterval: "15s"
      # Timeout de query — bajo, no queremos paneles colgados si Prometheus
      # tose. La UI muestra 'context deadline exceeded' si supera.
      queryTimeout: "30s"
      httpMethod: POST
      # Versión del backend Prometheus (no afecta features para v3.x; lo
      # explícita por claridad).
      prometheusType: Prometheus
      prometheusVersion: 3.1.0
      # Habilitar 'Manage alerts via Alerting UI' = false (no hay alerting).
      manageAlerts: false
```

---

## `~/homelab/monitor/grafana/provisioning/dashboards/default.yml`

_Provider_ de _dashboards_ — escanea `/var/lib/grafana/dashboards/*.json` cada 30 s.

```yaml
---
# Provider de dashboards auto-provisionados.
# Documentación: docs/05-monitorizacion/02-grafana.md
# Cada doc de la fase 5 (y exporters de otras fases) DEJA CAER su .json en
# ~/homelab/monitor/grafana/dashboards/ y este provider lo recoge solo.

apiVersion: 1

providers:
  - name: 'homelab'
    orgId: 1
    folder: 'Homelab'
    folderUid: homelab
    type: file
    disableDeletion: true        # un git rm NO dispara borrado en BD
    allowUiUpdates: false        # editar en UI sí, persistir cambios no
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
```

---

## `~/homelab/monitor/grafana/dashboards/prometheus-stats.json`

Dashboard baseline para verificar el _datasource_ Prometheus. **No lo redactamos a mano**: se descarga el JSON oficial de Grafana Labs (ID `3662`) y se commiteamos verbatim.

```bash
mkdir -p ~/homelab/monitor/grafana/dashboards
curl -fsSL \
    'https://grafana.com/api/dashboards/3662/revisions/latest/download' \
    -o ~/homelab/monitor/grafana/dashboards/prometheus-stats.json

# El JSON descargado trae '${DS_PROMETHEUS}' como placeholder del datasource.
# Lo sustituimos por el nombre real ('Prometheus') que provisionamos arriba.
sed -i 's/\${DS_PROMETHEUS}/Prometheus/g' \
    ~/homelab/monitor/grafana/dashboards/prometheus-stats.json

# Permisos (read-only para todo el mundo; la imagen leerá como UID 472).
chmod 0644 ~/homelab/monitor/grafana/dashboards/prometheus-stats.json
```

> **Por qué `3662` y no `1860` (Node Exporter Full)**: cuando se despliega Grafana en este doc, **todavía no existe Node Exporter** — eso llega en `docs/05-monitorizacion/03-node-exporter.md`. El `1860` arrancaría en blanco con "no data". El `3662` mide al propio Prometheus (cardinalidad, _scrape duration_, WAL, GC, …) y funciona desde el primer minuto. El `1860` se sumará en el doc del Node Exporter.

> **Verificación rápida**:
>
> ```bash
> # Confirmar que es JSON válido (Grafana lo aborta con un error si no).
> python3 -m json.tool ~/homelab/monitor/grafana/dashboards/prometheus-stats.json > /dev/null && echo OK
>
> # Confirmar que el placeholder se sustituyó.
> grep -c 'DS_PROMETHEUS' ~/homelab/monitor/grafana/dashboards/prometheus-stats.json
> # 0
> ```

---

## Modificar `~/homelab/monitor/docker-compose.yml`

Añadir el servicio `grafana` debajo de `prometheus` (**no** sustituir: el bloque de Prometheus se queda intacto). El fichero queda así:

```yaml
---
# Stack: monitor — Prometheus (TSDB + scraper) + Grafana (dashboards).
# Próximos servicios: Node Exporter, cAdvisor, Uptime Kuma, Dozzle.
# Documentación: docs/05-monitorizacion/{01-prometheus,02-grafana}.md

services:

  prometheus:
    # ... (sin cambios, ver docs/05-monitorizacion/01-prometheus.md)

  # ---------------------------------------------------------------------------
  # Grafana — dashboards y visualización. Lee de Prometheus por DNS interno.
  # No publica :3000 al host. Caddy la alcanza por DNS interno (grafana:3000)
  # en la red 'homelab'.
  # ---------------------------------------------------------------------------
  grafana:
    image: grafana/grafana-oss:${GRAFANA_IMAGE_TAG}
    container_name: grafana
    hostname: grafana
    restart: unless-stopped
    # Imagen oficial; corre como UID 472:472 (grafana). Documentado en la
    # tabla de UIDs de docs/01-sistema/04-estructura-directorios.md.
    user: "472:472"
    depends_on:
      prometheus:
        # Espera a que /-/ready de Prometheus devuelva 200. Evita que el
        # health-check del datasource falle el primer minuto tras el up.
        condition: service_healthy
    environment:
      TZ: ${TZ}
      # --- Inyección de secretos (no en grafana.ini, que es versionable) ---
      GF_SECURITY_ADMIN_USER: ${GRAFANA_ADMIN_USER}
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
      GF_SECURITY_SECRET_KEY: ${GRAFANA_SECRET_KEY}
      # --- Override de root_url ---
      GF_SERVER_ROOT_URL: ${GRAFANA_ROOT_URL}
      # --- Logging level ---
      GF_LOG_LEVEL: info
      # --- Plugins: ninguno por defecto (se rellena cuando un doc lo pida) ---
      GF_INSTALL_PLUGINS: ""
    volumes:
      # Configuración versionable, read-only.
      - ./grafana/grafana.ini:/etc/grafana/grafana.ini:ro
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
      # Estado persistente: SQLite, plugins, png/csv exports, anotaciones, etc.
      - /mnt/hd2t/services/grafana/data:/var/lib/grafana
    networks:
      homelab:
        aliases:
          - grafana
    labels:
      homelab.stack: "monitor"
      homelab.backup: "true"      # /mnt/hd2t/services/grafana/data
      # Opt-out: migraciones de esquema entre minor versions. Manual.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      # /api/health responde {"database":"ok","version":"...","commit":"..."}
      # cuando Grafana ha cargado la config y abierto la BD. wget viene
      # incluido en la imagen (alpine-based).
      test:
        - CMD-SHELL
        - "wget -qO- http://localhost:3000/api/health | grep -q '\"database\":\"ok\"'"
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s

# ---------------------------------------------------------------------------
# Redes
# ---------------------------------------------------------------------------
networks:
  homelab:
    external: true               # creada en docs/02-docker/02-estructura-compose.md
```

> **Mantener el bloque de `prometheus`** intacto — sólo se **añade** `grafana`. Si se editara el bloque de Prometheus por accidente y un `docker compose up -d` lo recreara, el TSDB sigue intacto en el _bind mount_, pero el `start_period: 60s` del _healthcheck_ retrasaría el arranque de Grafana ~60 s tras el primer `up`.

Notas de diseño:

- **`depends_on: prometheus: condition: service_healthy`**: Grafana espera al `(healthy)` de Prometheus antes de arrancar. Sin esto, en el primer `up -d` Grafana intenta provisionar el _datasource_ y validar la URL `http://prometheus:9090/api/v1/status/buildinfo` antes de que Prometheus haya cargado el WAL → log `Datasource health check failed: connection refused` durante 30–60 s. El `depends_on` lo evita.
- **`GF_SECURITY_ADMIN_PASSWORD` por env**: con `disable_login_form = true` no se va a pedir nunca, pero la imagen requiere que esté para arrancar (si no, genera una _random_ y la imprime al log al primer arranque, que es desagradable porque queda en `docker logs`).
- **`GF_INSTALL_PLUGINS=""`**: explícito a vacío para evitar que la imagen base instale algo si en algún momento la _release notes_ cambia el _default_.
- **Sin `mem_limit` / `cpus`**: Grafana en idle consume <150 MB en la Pi 5. Cuando lleguen los _exporters_ y haya 5–10 _dashboards_ activos, se monitoriza desde el propio Grafana (`go_memstats_alloc_bytes{job="grafana"}`).
- **Volúmenes `:ro`** en `grafana.ini`, `provisioning/` y `dashboards/`: el contenedor no debe poder modificar la configuración versionable. Si alguna versión futura de Grafana exigiese escribir en `provisioning/`, se documentará esa excepción aquí.

---

## Modificar `~/homelab/monitor/prometheus/prometheus.yml`

Grafana expone `/metrics` Prometheus-compatible en `:3000/metrics`. Lo añadimos como `scrape_job` para tener visibilidad sobre la propia Grafana (uso de RAM, latencia HTTP, errores 5xx, _datasource health_).

Editar la sección `scrape_configs:` y añadir el bloque, **debajo** del de Prometheus:

```diff
 scrape_configs:

   - job_name: 'prometheus'
     metrics_path: /metrics
     static_configs:
       - targets:
           - 'prometheus:9090'
         labels:
           service: prometheus
           stack:   monitor

+  # -------------------------------------------------------------------------
+  # 2) Grafana — métricas internas (HTTP latency, datasource health, build).
+  #     /metrics es público dentro de la red 'homelab'.
+  # -------------------------------------------------------------------------
+  - job_name: 'grafana'
+    metrics_path: /metrics
+    static_configs:
+      - targets:
+          - 'grafana:3000'
+        labels:
+          service: grafana
+          stack:   monitor
```

Validar y recargar Prometheus sin _restart_:

```bash
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
# Checking 2 scrape configs: SUCCESS

docker exec prometheus kill -HUP 1
# level=info ... msg="Loading configuration file"
# level=info ... msg="Completed loading of configuration file"
```

> **Por qué `grafana:3000` y no un endpoint dedicado**: Grafana sirve `/metrics` en el mismo puerto que la UI. Como el _scrape_ ocurre **dentro** de la red `homelab` (Prometheus → Grafana), no pasa por Caddy ni Authelia. La única protección posible sería `auth.basic` con `username/password` en `[metrics]` del `grafana.ini` y `basic_auth` en el `scrape_config`, pero para un homelab personal el _exposure_ dentro de `homelab` es aceptable.

---

## Modificar Authelia: añadir `grafana.lan` a `two_factor`

Editar `~/homelab/seguridad/configuration.yml` y añadir `grafana.lan` a la regla `two_factor` que ya contiene `portainer.lan` y `prometheus.lan`:

```diff
   # 3) Servicios críticos — exigir 2FA (TOTP / WebAuthn) además de 1FA.
   - domain:
       - 'portainer.lan'
       - 'prometheus.lan'
+      - 'grafana.lan'
       # - 'vaultwarden.lan'      # docs/11-productividad/01-vaultwarden.md
       # - 'nextcloud.lan'        # docs/06-almacenamiento/01-nextcloud.md
       # - 'home-assistant.lan'   # docs/08-domotica/01-home-assistant.md
     policy: two_factor
```

Validar y recargar Authelia:

```bash
docker exec authelia authelia validate-config --config /config/configuration.yml
docker exec authelia kill -HUP 1
```

---

## Modificar el `Caddyfile`: bloque `grafana.lan`

Editar `~/homelab/red/Caddyfile` y añadir, junto al de `prometheus.lan` (antes del catch-all `*.lan`):

```caddyfile
# ---------------------------------------------------------------------------
# Grafana — dashboards. Acceso 2FA vía Authelia, Grafana hace auth.proxy
# leyendo Remote-User de la respuesta de Authelia (vía Caddy copy_headers).
# docs/05-monitorizacion/02-grafana.md
# ---------------------------------------------------------------------------
grafana.lan {
    tls internal
    import security-headers
    import logging
    import authelia

    reverse_proxy grafana:3000 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # Caddy reenvía WebSockets sin configuración extra: la directiva
        # reverse_proxy auto-detecta Upgrade: websocket. Grafana usa WS para
        # 'Live' (logs streaming, alerting view, etc.).
    }
}
```

Validar y recargar Caddy:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
# 'INF reload happened' en logs.
```

> **Orden estricto del despliegue** (importante para no provocar `dial tcp: lookup grafana: no such host` en Caddy durante 60 s):
>
> 1. Crear ficheros nuevos (`grafana.ini`, `provisioning/*`, `dashboards/*.json`) y modificar `prometheus.yml` y `docker-compose.yml`.
> 2. `make up STACK=monitor` — levanta Grafana en `homelab`.
> 3. Modificar Authelia y recargar.
> 4. Modificar el `Caddyfile` y recargar Caddy.

---

## Despliegue

```bash
cd ~/homelab/monitor
docker compose --env-file ../.env --env-file .env config | head -80    # validar sintaxis
docker compose --env-file ../.env --env-file .env up -d
```

O con el _Makefile_:

```bash
cd ~/homelab
make up STACK=monitor
```

Verificar:

```bash
docker compose -f ~/homelab/monitor/docker-compose.yml ps
# NAME         STATUS                   PORTS
# prometheus   Up X minutes (healthy)
# grafana      Up Y seconds (healthy)
```

> El `(healthy)` de Grafana suele ser <30 s en una Pi 5 con SQLite vacía. En arranques posteriores con la BD poblada y _provisioning_ extenso puede subir a ~45 s — el `start_period: 30s` da margen.

Inspeccionar el primer arranque:

```bash
docker logs grafana 2>&1 | grep -E '(provisioning|datasource|dashboard|listening)'
# logger=settings t=...      starting Grafana ...
# logger=provisioning.datasources t=...  msg="inserting datasource from configuration"  name=Prometheus uid=...
# logger=provisioning.dashboard t=...    msg="starting to provision dashboards"
# logger=provisioning.dashboard t=...    msg="finished to provision dashboards"
# logger=http.server t=...   msg="HTTP Server Listen"  address=[::]:3000
```

Confirmar que el _datasource_ Prometheus está sano:

```bash
docker exec grafana wget -qO- \
    --header='Remote-User: admin' \
    'http://localhost:3000/api/datasources/uid/prometheus' \
    | python3 -m json.tool | head -20
# (o con el datasource UID real, que se ve en /api/datasources)
```

Y desde `grafana` la propia _query_ a Prometheus:

```bash
docker exec grafana wget -qO- \
    'http://prometheus:9090/api/v1/query?query=up' \
    | python3 -c "import json,sys;d=json.load(sys.stdin);[print(r['metric']['job'],'=',r['value'][1]) for r in d['data']['result']]"
# prometheus = 1
# grafana = 1
```

Verificar el _scrape_ de Grafana en Prometheus (debe haber **dos** _targets_ en `UP`):

```bash
docker exec prometheus wget -qO- \
    'http://localhost:9090/api/v1/targets?state=active' \
    | python3 -c "import json,sys;d=json.load(sys.stdin);[print(t['labels']['job'],t['health']) for t in d['data']['activeTargets']]"
# prometheus up
# grafana up
```

Para validar **end-to-end** la cadena Caddy + Authelia + Grafana, abrir el navegador en `https://grafana.lan/`:

1. Caddy redirige a `https://auth.lan/?rd=https%3A%2F%2Fgrafana.lan%2F`.
2. Authelia pide usuario+contraseña + TOTP (regla `two_factor`).
3. Tras autenticar, Authelia redirige a `https://grafana.lan/`. Grafana lee `Remote-User: homelab`, crea el usuario interno (auto sign-up) con _role_ `Viewer` y carga la _home dashboard_.
4. Navegar a `Dashboards → Homelab` (carpeta provisionada): aparece **Prometheus 2.0 Stats** con datos reales (_scrape duration_, WAL, etc.).
5. Navegar a `Connections → Data sources`: aparece `Prometheus` como `default`, marcado **read-only** (icono de candado).

> **Auto sign-up del primer usuario crea un Viewer**: para promocionarte a `Admin` en este primer despliegue, basta con resetear la clave del admin nativo y entrar **una vez** por la UI nativa (ver _Recuperación de admin_ abajo) o, más rápido, ejecutar:
>
> ```bash
> docker exec grafana grafana-cli --homepath=/usr/share/grafana \
>     admin reset-admin-password "$GRAFANA_ADMIN_PASSWORD"
> # Y luego, desde la UI ya autenticada como tu user normal, otro Admin
> # puede promocionarte. Alternativa más limpia: vía sqlite3:
> docker exec grafana sqlite3 /var/lib/grafana/grafana.db \
>     "UPDATE org_user SET role='Admin' WHERE user_id=(SELECT id FROM \"user\" WHERE login='homelab');"
> docker exec grafana grafana-cli --homepath=/usr/share/grafana admin data-migrations clean-up
> ```
>
> Tras esto, el siguiente login vía Authelia te entrega ya como `Admin`.

---

## Verificación final

Antes de pasar a `docs/05-monitorizacion/03-node-exporter.md`, comprobar:

- [ ] `docker compose -f ~/homelab/monitor/docker-compose.yml ps` muestra `prometheus` **y** `grafana` en `Up` y `(healthy)`.
- [ ] `stat -c '%a %U:%G' /mnt/hd2t/services/grafana/data` devuelve `750 472:472`.
- [ ] `ls /mnt/hd2t/services/grafana/data/` lista al menos `grafana.db`, `plugins/`, `png/`, `csv/` con propietario `472:472`.
- [ ] `docker exec grafana wget -qO- http://localhost:3000/api/health` devuelve `{"commit":"...","database":"ok","version":"11.5.2"}`.
- [ ] `docker logs grafana 2>&1 | grep -i 'finished to provision dashboards'` muestra al menos una línea (provisioning ejecutado).
- [ ] `docker logs grafana 2>&1 | grep -i 'inserting datasource' | grep -i prometheus` muestra que el _datasource_ se insertó en BD.
- [ ] `docker exec prometheus promtool check config /etc/prometheus/prometheus.yml` devuelve `Checking 2 scrape configs: SUCCESS`.
- [ ] `https://prometheus.lan/targets` (tras login 2FA) muestra **dos** _targets_, ambos `UP`: `prometheus (1/1 up)` y `grafana (1/1 up)`.
- [ ] `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` acepta el bloque `grafana.lan`.
- [ ] `curl -k --resolve grafana.lan:443:192.168.1.3 -I https://grafana.lan/` devuelve `302 Found` con `Location: https://auth.lan/?rd=...`.
- [ ] Login interactivo desde el navegador: usuario+contraseña + TOTP de Authelia → `https://grafana.lan/` carga; el usuario aparece auto-creado en `Administration → Users`; el _dashboard_ `Prometheus 2.0 Stats` (carpeta `Homelab`) muestra datos reales.
- [ ] Editar `provisioning/datasources/prometheus.yml` (cambio inocuo, p. ej. añadir comentario), `docker exec grafana kill -HUP 1` y comprobar `docker logs grafana --tail 20` que recarga sin errores.

  > **Nota**: Grafana **no recarga** _datasources_ provisionados con `kill -HUP` como Prometheus — el _provisioning_ sólo se reaplica al arrancar. El comando equivalente real es `docker compose restart grafana` (3–5 s de _downtime_) o llamar al endpoint `/api/admin/provisioning/datasources/reload` con auth admin. Documento como _sharp edge_ y dejo un placeholder para testar reload por API.
- [ ] Tras un `docker compose -f ~/homelab/monitor/docker-compose.yml restart grafana`, `/api/health` vuelve a `200` en <30 s y el _dashboard_ `Prometheus 2.0 Stats` sigue ahí (provisionado, no se borra).
- [ ] Tras un `sudo reboot` de la Pi, el _stack_ vuelve a estar `(healthy)` sin intervención manual y `https://grafana.lan/` (tras login Authelia) responde con la UI.
- [ ] `git -C ~/homelab status` muestra como **modificados**: `red/Caddyfile`, `seguridad/configuration.yml`, `monitor/docker-compose.yml`, `monitor/.env.example`, `monitor/prometheus/prometheus.yml`. Y como **nuevos**: `monitor/grafana/grafana.ini`, `monitor/grafana/provisioning/datasources/prometheus.yml`, `monitor/grafana/provisioning/dashboards/default.yml`, `monitor/grafana/dashboards/prometheus-stats.json`. **No** muestra `monitor/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add monitor/docker-compose.yml monitor/.env.example \
          monitor/prometheus/prometheus.yml \
          monitor/grafana/grafana.ini \
          monitor/grafana/provisioning/datasources/prometheus.yml \
          monitor/grafana/provisioning/dashboards/default.yml \
          monitor/grafana/dashboards/prometheus-stats.json \
          red/Caddyfile seguridad/configuration.yml
  git commit -m "feat(monitor): add Grafana with Prometheus datasource and SSO via Authelia auth.proxy"
  ```

---

## Operaciones habituales

### Añadir un nuevo _dashboard_ provisionado

Convención que adoptarán los siguientes docs de la fase 5 (Node Exporter, cAdvisor) y de fases con _exporters_:

1. Descargar (o exportar a JSON desde la UI) el _dashboard_ que se quiere fijar:

   ```bash
   curl -fsSL 'https://grafana.com/api/dashboards/<ID>/revisions/latest/download' \
       -o ~/homelab/monitor/grafana/dashboards/<nombre>.json
   ```

2. Sustituir el placeholder del _datasource_ si lo trae:

   ```bash
   sed -i 's/\${DS_PROMETHEUS}/Prometheus/g' \
       ~/homelab/monitor/grafana/dashboards/<nombre>.json
   ```

3. Validar JSON:

   ```bash
   python3 -m json.tool ~/homelab/monitor/grafana/dashboards/<nombre>.json > /dev/null
   ```

4. El _provider_ de _dashboards_ lo recoge en <30 s automáticamente. Verificar en `Dashboards → Homelab`.

5. _Commit_ del JSON.

### Añadir un nuevo _datasource_ provisionado

Por ahora sólo tenemos Prometheus. Si en el futuro se añade Loki (logs) o un Postgres (datos directos):

1. Crear `~/homelab/monitor/grafana/provisioning/datasources/<nombre>.yml` siguiendo el _schema_ apiVersion 1.
2. `docker compose -f ~/homelab/monitor/docker-compose.yml restart grafana`.
3. Verificar en `Connections → Data sources`.
4. _Commit_.

### Editar la configuración (`grafana.ini`)

Cambios a `grafana.ini` requieren `restart` (no se recargan en caliente):

```bash
docker compose -f ~/homelab/monitor/docker-compose.yml restart grafana
# (~5–10 s de downtime; las sesiones activas en navegador siguen tras el reload)
```

### Reset del usuario admin (recuperación de emergencia)

Si Authelia está caída y necesitas entrar:

1. Editar temporalmente `~/homelab/monitor/grafana/grafana.ini`:

   ```ini
   [auth]
   disable_login_form = false
   [auth.basic]
   enabled = true
   ```

2. `docker compose -f ~/homelab/monitor/docker-compose.yml restart grafana`.
3. Acceder al puerto 3000 directamente desde el host:

   ```bash
   ssh -L 3000:127.0.0.1:3000 homelab@<pi-ip>
   # Pero primero hay que publicar :3000 al host añadiendo 'ports: [127.0.0.1:3000:3000]'
   # al servicio grafana en docker-compose.yml. Para no contaminar el repo, hacerlo
   # en una rama 'recovery' y revertir tras la reparación.
   ```

   O, más simple:

   ```bash
   docker exec grafana grafana-cli --homepath=/usr/share/grafana \
       admin reset-admin-password "<nueva-clave-temporal>"
   ```

4. Login con `${GRAFANA_ADMIN_USER}` + nueva clave en `https://grafana.lan/login` (vía un `curl` con _Host_ resuelto manual).
5. Hacer la operación (recuperar usuario, etc.).
6. **Revertir el cambio** en `grafana.ini`, `restart`. _Commit_ de la _branch_ recovery a `main` no — se descarta.

### Backup ad-hoc del estado (sin Borgmatic)

Para una copia rápida fuera de la rotación de Borg:

```bash
docker compose -f ~/homelab/monitor/docker-compose.yml stop grafana
sudo tar czf ~/grafana-backup-$(date +%Y%m%d).tgz \
    -C /mnt/hd2t/services/grafana data/
docker compose -f ~/homelab/monitor/docker-compose.yml up -d grafana
```

> **Mientras Grafana está parada**, `https://grafana.lan/` devuelve `502 Bad Gateway` (Caddy no resuelve el _backend_). Hacerlo en horario sin uso.

---

## Backup

| Qué                                            | Dónde                                                       | Cómo                                            |
|------------------------------------------------|-------------------------------------------------------------|-------------------------------------------------|
| `docker-compose.yml`, `grafana.ini`, _provisioning_, _dashboards_ | `~/homelab/monitor/`                                | git                                             |
| BD interna (`grafana.db` SQLite + WAL), `plugins/`, `png/`, `csv/` | `/mnt/hd2t/services/grafana/data/`               | Borgmatic (`docs/07-backups/02-borgmatic.md`)   |

> **Restauración**: clonar el repo, restaurar `/mnt/hd2t/services/grafana/data/` desde Borgmatic (con el contenedor parado para evitar `database is locked`), `make up STACK=monitor`, recargar Caddy. Los _dashboards_ provisionados aparecen siempre (vienen de git); los _dashboards_ creados en UI (que no haya — `allowUiUpdates: false`), las _annotations_ y los _users_ vuelven del _archive_.

> **Alternativa _git-only_**: si la BD se corrompe sin _backup_ Borg disponible, basta con borrar `grafana.db*` y arrancar; Grafana recrea el _schema_ y reaplica el _provisioning_. Se pierden _users_ no provisionados (los crea Authelia auto sign-up al siguiente login) y _annotations_ ad-hoc.

---

## Troubleshooting

### Grafana arranca pero `/api/health` devuelve `{"database":"failed"}`

Permisos del _bind mount_. Confirmar:

```bash
stat -c '%a %U:%G' /mnt/hd2t/services/grafana/data
# Esperado: '750 472:472'
```

Si no:

```bash
sudo chown -R 472:472 /mnt/hd2t/services/grafana/data
sudo chmod 0750 /mnt/hd2t/services/grafana/data
docker compose -f ~/homelab/monitor/docker-compose.yml up -d grafana
```

### `https://grafana.lan/` da bucle: redirige a `auth.lan` aun después de loguear

Causa típica: `Remote-User` no llega al servicio. Probable que el _snippet_ `(authelia)` se haya editado sin el `copy_headers Remote-User Remote-Groups Remote-Name Remote-Email`.

Diagnóstico:

```bash
# Desde el host, simular Caddy y ver qué cabeceras llegan a Grafana.
docker exec grafana wget -qO- \
    --header='Remote-User: testuser' \
    'http://localhost:3000/api/user' \
    | python3 -m json.tool
# Esperado: {"login": "testuser", ...}
```

Si Grafana devuelve `{"message":"Unauthorized"}` con la cabecera puesta, la _whitelist_ no incluye al cliente:

```bash
# Confirmar la subnet desde la que entra Grafana ve la petición:
docker inspect grafana --format '{{.NetworkSettings.Networks.homelab.IPAddress}}'
docker inspect caddy   --format '{{.NetworkSettings.Networks.homelab.IPAddress}}'
# Ambos deben caer en 172.20.10.0/24 (o el rango que se haya elegido en
# docs/02-docker/02-estructura-compose.md). Ajustar 'whitelist' en grafana.ini.
```

### `Datasource health check failed: dial tcp: lookup prometheus on 127.0.0.11: no such host`

Grafana no encuentra `prometheus` por DNS interno. Causas:

1. `prometheus` no está en la red `homelab`: `docker network inspect homelab` debe listarlo.
2. Grafana arrancó **antes** que Prometheus (sin `depends_on`). Confirmar `depends_on: prometheus: condition: service_healthy` en el compose.
3. El alias `prometheus` no está activo. Confirmar en el compose `aliases: [prometheus]` en el bloque `networks: homelab:`.

### El _dashboard_ `Prometheus 2.0 Stats` aparece en blanco con "No data"

El JSON descargado no se filtró por el _datasource_ provisionado. Causas:

1. El placeholder `${DS_PROMETHEUS}` no se sustituyó por `Prometheus`. Confirmar:

   ```bash
   grep DS_PROMETHEUS ~/homelab/monitor/grafana/dashboards/prometheus-stats.json | head -3
   # (vacío esperado)
   ```

   Si sale algo, repetir el `sed -i 's/\${DS_PROMETHEUS}/Prometheus/g' ...` y esperar 30 s al re-provisionado.

2. El _datasource_ provisionado tiene un `uid` distinto al que el _dashboard_ JSON espera. La fórmula segura es referenciar por `name` (`Prometheus`); si tu JSON usa `${DS_PROMETHEUS}` como _uid_, sustitúyelo por el `name`.

### `docker logs grafana` lleno de `level=eror logger=context error="user not found"`

Auto sign-up no está creando al usuario. Confirmar en `grafana.ini`:

```ini
[auth.proxy]
auto_sign_up = true
```

Y reiniciar.

### Subida de versión: tras `make pull && make up`, Grafana muere con `error during migration`

El _bump_ de minor (p. ej. 11.5 → 11.6) introdujo una migración de esquema que falló. Recuperación:

1. Parar Grafana: `docker compose stop grafana`.
2. Restaurar el `grafana.db` desde un _archive_ Borg anterior al _bump_:

   ```bash
   borg extract /mnt/hd2t/backups/borg/repo::homelab-<YYYYMMDD> \
       mnt/hd2t/services/grafana/data/grafana.db
   ```

3. Volver al _tag_ anterior (`GRAFANA_IMAGE_TAG=11.5.2`) en `.env`.
4. `docker compose up -d grafana` y `docker logs grafana --tail 50` para confirmar que arranca.
5. Leer las _release notes_ del _bump_ que falló y, si la migración requiere un paso manual (raro), aplicarlo antes de reintentar.

### `Failed to load plugin grafana-something-app: signature invalid`

Algún _plugin_ se ha colado en `~/homelab/monitor/grafana/data/plugins/` (por instalación manual previa). Limpiarlo:

```bash
docker compose stop grafana
sudo rm -rf /mnt/hd2t/services/grafana/data/plugins/<plugin-name>
docker compose up -d grafana
```

Y mantener `GF_INSTALL_PLUGINS=""` en el compose.

### Las cabeceras de seguridad están duplicadas (`Strict-Transport-Security` x2)

Causa: tanto el _snippet_ `(security-headers)` de Caddy como Grafana (`grafana.ini` con `strict_transport_security = true`) las añaden. En este doc Grafana las desactiva (`strict_transport_security = false`, `content_security_policy = false`) precisamente para que Caddy sea el único origen. Si reapareciera el duplicado, revisar el `grafana.ini` y confirmar la desactivación.

### `database is locked` ocasional en logs

SQLite en WAL es resistente, pero un _restart_ con backup en marcha (Borg leyendo `grafana.db-wal`) puede generar bloqueos transitorios. Si es esporádico, es ignorable (Grafana reintenta). Si es persistente, mover el _backup_ Borg a una ventana sin actividad de Grafana o, como último recurso, hacer `docker compose stop grafana` antes del Borg y `up -d` después (ver `docs/07-backups/02-borgmatic.md` para el _hook_ `before_backup`).

---

## Referencias

- Grafana — Documentación oficial: <https://grafana.com/docs/grafana/latest/>
- Grafana — _Provisioning_ de _datasources_ y _dashboards_: <https://grafana.com/docs/grafana/latest/administration/provisioning/>
- Grafana — _Auth proxy_: <https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/auth-proxy/>
- Grafana — Configuración (`grafana.ini`): <https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/>
- Grafana — Imagen Docker oficial: <https://hub.docker.com/r/grafana/grafana-oss>
- Grafana — _Image renderer_ y plugins ARM64: <https://grafana.com/docs/grafana/latest/setup-grafana/installation/docker/>
- Grafana Labs — Catálogo de _dashboards_ públicos: <https://grafana.com/grafana/dashboards/?dataSource=prometheus>
- Grafana — Dashboard `Prometheus 2.0 Stats` (ID 3662): <https://grafana.com/grafana/dashboards/3662-prometheus-2-0-stats/>
- Grafana — Dashboard `Node Exporter Full` (ID 1860, futuro `03-node-exporter.md`): <https://grafana.com/grafana/dashboards/1860-node-exporter-full/>
- Grafana — Dashboard `Docker / cAdvisor` (ID 14282, futuro `04-cadvisor.md`): <https://grafana.com/grafana/dashboards/14282-cadvisor-exporter/>
