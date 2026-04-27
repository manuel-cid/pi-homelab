# Prometheus (TSDB de métricas + _scraper_)

## Descripción

Despliegue de **Prometheus** como **base de datos de series temporales** (TSDB) y _scraper_ central de métricas del homelab. Prometheus se sienta detrás de Caddy (HTTPS interno), publicado como `https://prometheus.lan` y protegido con **Authelia en 2FA**, y consume métricas de los _exporters_ del homelab (Node Exporter, cAdvisor, Pi-hole exporter, Caddy `metrics`, Authelia `telemetry`, …) que se irán añadiendo en los documentos siguientes de esta fase. Las series se persisten en `/mnt/hd2t/services/prometheus/data/` con **retención de 30 días** y un tope de 50 GB.

Este documento **estrena el _stack_ `monitor`** (`~/homelab/monitor/`) descrito en `docs/02-docker/02-estructura-compose.md`. Prometheus es el primero en pisarlo; el resto de servicios de la fase 5 (Grafana, Node Exporter, cAdvisor, Uptime Kuma, Dozzle) se sumarán al mismo `docker-compose.yml`. Este doc deja un `prometheus.yml` **mínimo** con un único _scrape_job_ apuntando al propio Prometheus; cada doc posterior **añadirá su `scrape_config`** al fichero, ya operativo y validable con `promtool`.

> **Alcance**: este documento despliega Prometheus, define su `prometheus.yml` con _scrape_ exclusivamente del propio Prometheus, configura su almacenamiento en `hd2t`, lo expone vía Caddy + Authelia 2FA y crea el subdirectorio del _stack_ `monitor`. **No** despliega Grafana (`docs/05-monitorizacion/02-grafana.md`), **no** despliega ningún _exporter_ (eso llega en `03`/`04`), **no** define reglas de _alerting_ (Alertmanager queda fuera del homelab por simplicidad — las alertas se delegan a Uptime Kuma, `docs/05-monitorizacion/05-uptime-kuma.md`), **no** integra _remote_write_ a un backend long-term (VictoriaMetrics, Mimir…). Todo eso son ampliaciones puntuales que no requieren rediseño.

> **Recordatorio de red**: Prometheus **no se publica al host**. Caddy lo alcanza por DNS interno de Docker (`prometheus:9090`) dentro de la red `homelab`. El operador entra por `https://prometheus.lan/`, que Pi-hole resuelve a `192.168.1.3` (wildcard de `02-homelab-local.conf`) y Caddy demultiplexa por SNI. Authelia exige 2FA antes de exponer la UI/API (`docs/04-seguridad/01-authelia.md`).

---

## Requisitos previos

- `docs/02-docker/02-estructura-compose.md` completado: red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) creada y _externa_, `~/homelab/.env` con `TZ`, `PUID`, `PGID` y `HOMELAB_DOMAIN=lan` rellenos, _Makefile_ con `make up STACK=<stack>` operativo. La tabla de _stacks_ ya reserva el _slot_ `monitor` que aquí se materializa.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/prometheus/data/` ya existe vacío `root:root 0755` (la propia tabla de UIDs internos de aquel doc anota que el contenedor corre como `nobody (65534)` y deja la reasignación de ownership "para el doc de la fase concreta" — la hace este).
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, _snippets_ `security-headers` y `logging` operativos, `import /etc/caddy/snippets/*.caddy` activo en el `Caddyfile`, CA local firmando `*.lan`.
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `prometheus.lan` — el wildcard ya lo cubre.
- `docs/04-seguridad/01-authelia.md` completado: Authelia con _backend_ de fichero, Redis para sesiones, _snippet_ `(authelia)` operativo en `~/homelab/red/caddy/snippets/authelia.caddy`, regla `*.lan → one_factor` por defecto y lista de `two_factor` con `portainer.lan` ya activa. Este doc añade `prometheus.lan` a esa lista.
- Conectividad saliente para descargar la imagen:

  ```bash
  docker pull --platform linux/arm64 prom/prometheus:v3.1.0 >/dev/null && echo OK
  ```

- Que el host **no** tenga ya un servicio escuchando en `:9090`:

  ```bash
  sudo ss -tulpn '( sport = :9090 )'
  ```

  Salida esperada: vacía. Prometheus no publica `:9090` al host (sólo lo expone a `homelab` por DNS interno), pero conviene confirmar que ningún binario residual lo ocupa antes del primer `up`.

---

## Decisiones de diseño

### Por qué Prometheus (y no VictoriaMetrics / InfluxDB / Netdata)

El homelab necesita un TSDB **pull-based**, ligero en una Pi 5, con _query language_ idiomático para los _exporters_ del ecosistema y compatible de fábrica con Grafana. Tres candidatos descartados y por qué:

| Candidato            | Por qué se descarta                                                                                                                                                                          |
|----------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **VictoriaMetrics**  | TSDB drop-in compatible con Prometheus, **más eficiente en RAM y disco** (10×–20× según _benchmarks_). Pero requiere su propio `vmagent` para el _scraping_ si se quiere _remote write_, y la documentación ARM64 es menos abundante. Sobreingeniería para un homelab con 8–12 _targets_. **Migración futura**: trivial — se monta `victoriametrics` con `-remoteWrite` desde Prometheus, o se sustituye Prometheus por `vmagent + vmstorage` reusando los mismos _exporters_. |
| **InfluxDB**         | Modelo _push_ (`telegraf` → `influxdb`), ergonomía distinta (_FluxQL_ en v2 / _InfluxQL_ en v1), peor integración con _exporters_ del ecosistema CNCF. Más pesado en RAM. Útil si la mayoría de las fuentes ya hablan `line protocol`, no es el caso aquí.    |
| **Netdata**          | Excelente para "instalar y ya": agente todo-en-uno con UI propia, _alerting_ y descubrimiento automático. Pero la persistencia _long-term_ requiere Netdata Cloud (servicio externo) o un _exporter_ a Prometheus. Si vamos a _scrapear_ de Netdata con Prometheus, mejor usar Prometheus directo y los _exporters_ canónicos. |

Prometheus gana por:

- **Modelo `pull`**: cada _exporter_ del homelab expone `/metrics` en HTTP plano dentro de la red `homelab`; Prometheus va a buscarlas. Sin _agent_ adicional, sin colas, sin _push gateway_.
- **PromQL**: lenguaje de consulta idiomático que Grafana entiende sin mediación. Cualquier dashboard de Grafana Labs (`Node Exporter Full` 1860, `Docker cAdvisor` 14282, …) funciona _out-of-the-box_.
- **Footprint razonable**: ~150–250 MB RAM en idle con 10–15 _targets_ y retención 30 días en una Pi 5. Aceptable.
- **Watchtower-friendly por _patches_**: minor versions (`v3.1.x → v3.1.y`) son seguras; major (`v2 → v3`, `v3 → v4`) cambian el formato de TSDB y se hacen a mano leyendo el _migration guide_.
- **Escalabilidad incremental**: cuando 30 días de retención se quede corto, se monta VictoriaMetrics o un Mimir como _remote write_ sin tocar `prometheus.yml` ni los _exporters_.

### Stack `monitor` se estrena con este documento

`docs/02-docker/02-estructura-compose.md` reservó el _slot_ `~/homelab/monitor/` para Prometheus, Grafana y los _exporters_. Aquí se crea el directorio, su `docker-compose.yml`, su `.env`/`.env.example`, su `prometheus.yml` versionable y se enchufa al _Makefile_ vía la convención existente (`make up STACK=monitor`).

A diferencia del _stack_ `seguridad`, **no** se crea una red privada `monitor-internal`: Prometheus necesita _scrapear_ a contenedores que viven en **otros** _stacks_ (cAdvisor del propio _stack_, pero también `pihole-exporter` del _stack_ `red`, `caddy:metrics` que se expondrá ahí, `authelia` con `telemetry.metrics`, futuros _exporters_ de Nextcloud, Home Assistant…). La forma idiomática de hacerlo es engancharlo a la red compartida `homelab` y _scrapear_ a cada _target_ por su nombre interno de Docker. Cualquier servicio del homelab que quiera ser _scrapeado_ se suma a `homelab` (la mayoría ya están) y expone `/metrics` por HTTP en su puerto interno.

### Imagen y _tag_

- **`prom/prometheus:v3.1.0`** — Prometheus **3.1**, multi-arch con `linux/arm64`, imagen oficial publicada por el equipo de Prometheus. Pinneada a versión completa (convención del homelab: nada de `:latest`, nada de `:v3` o `:v3.1`).
- **Por qué v3 y no v2.55 LTS**: v3.0 (Nov 2024) estabiliza el motor de _native histograms_, optimiza el WAL y elimina código heredado. Para un primer despliegue en 2026, `v3.x` es la línea mainstream. Si por algún _exporter_ legacy hubiera que volver a `v2.55.x` LTS, basta cambiar el `_TAG` y volver a hacer `up -d` — la base TSDB es _forward-compatible_ entre `v2.55` y `v3.x` (el _migration guide_ oficial lo confirma).
- **Watchtower opt-out** (`com.centurylinklabs.watchtower.enable: "false"`):
  - Aunque entre _patches_ (`v3.1.0 → v3.1.1`) los upgrades son seguros, **entre minors** (`v3.1 → v3.2`) Prometheus puede cambiar formato del WAL (lo hizo en `v2.7`, `v2.32`, `v3.0`); un upgrade ciego deja el contenedor en _CrashLoopBackOff_ con `corrupted WAL` y **sin retroceso fácil** (los datos del WAL nuevo no son legibles por la versión vieja). Las actualizaciones se hacen a mano leyendo las _release notes_ y, si procede, parando el _scraping_ unos minutos para que el WAL se vacíe antes del _bump_.
  - Riesgo bajo en absoluto, alto en relación al beneficio. Watchtower aporta poco aquí: las _release notes_ se publican en GitHub y un `make pull STACK=monitor && make up STACK=monitor` mensual es trivial.

### Retención: 30 días + tope de 50 GB

```
--storage.tsdb.retention.time=30d
--storage.tsdb.retention.size=50GB
```

Prometheus borra _chunks_ por el límite que **antes** se cumpla (tiempo o tamaño). Razones:

- **30 días** cubre cómodamente la ventana operativa del homelab: ver tendencias semanales, comparar lunes contra el lunes anterior, detectar derivas tras un _bump_ de imagen. Más allá, Grafana es lo que se mira; series _long-term_ de un homelab personal son lujo.
- **50 GB de tope duro** es un seguro contra el caso patológico (un _exporter_ defectuoso que dispara la cardinalidad). En operación normal, ~10–15 _targets_ a 15 s de _scrape_ con `~500` series cada uno consumen ~3–6 GB/30 días. El tope da `~7×` de margen sin forzar a ampliar el disco.
- **Por qué no `--storage.tsdb.retention.time=0`** (sin retención): el _default_ histórico (`15d`) era demasiado corto para tendencias mensuales; `0d` deshabilita la retención por tiempo y deja sólo el tamaño, lo cual confunde el _alerting_ y los _dashboards_ ("últimos 30 días" deja de tener sentido si el TSDB se autollena hasta el tope). Mejor un par tiempo+tamaño explícito.

Las dos flags se exponen como variables `.env` (`PROMETHEUS_RETENTION_TIME`, `PROMETHEUS_RETENTION_SIZE`) para poder ajustarlas sin tocar el `docker-compose.yml`.

### Storage en `hd2t` (no en microSD ni en `/var/lib/docker`)

`/mnt/hd2t/services/prometheus/data/` (definido en `docs/01-sistema/04-estructura-directorios.md`) por tres razones:

1. **Volumen de escritura**: Prometheus escribe el WAL de forma continua. Hacerlo sobre la microSD del Pi quema la tarjeta en meses. `hd2t` es un disco USB 3.0 mecánico, sin contadores de _wear_ relevantes a este ritmo.
2. **Tamaño**: 30 días + tope de 50 GB no caben en una microSD de 64 GB del sistema. `hd2t` tiene 2 TB libres.
3. **Backup**: `/mnt/hd2t/services/prometheus/data/` entra en Borgmatic (`docs/07-backups/02-borgmatic.md`) por la etiqueta `homelab.backup: "true"`. La pérdida de los datos no es crítica (las series se vuelven a generar), pero conviene poder restaurar tras un fallo del disco para no perder el histórico mensual.

### Owner del directorio: `nobody (65534)`

La imagen oficial `prom/prometheus` corre como `nobody:nobody` (UID 65534, GID 65534) y **comprueba que el volumen `/prometheus` sea suyo**: si no, aborta con `opening storage failed: lock DB directory: open /prometheus/lock: permission denied`. La tabla de UIDs de `docs/01-sistema/04-estructura-directorios.md` ya anota esto y delega el `chown` al doc de la fase concreta. Aquí se hace:

```bash
sudo chown -R 65534:65534 /mnt/hd2t/services/prometheus/data
sudo chmod 0750 /mnt/hd2t/services/prometheus/data
```

> **No usar `:Z` ni `:U` en el bind mount**: SELinux no está activado en Raspberry Pi OS (a diferencia de RHEL/Fedora). Esos modificadores son no-op aquí.

### Acceso vía Caddy + Authelia 2FA (no por puerto del host)

Como con el resto de servicios del homelab, Prometheus **no publica `:9090` al host**. Se expone únicamente a través de Caddy como `https://prometheus.lan`, protegido con `forward_auth` a Authelia. Como Prometheus es una herramienta de administración con visibilidad sobre **toda** la telemetría del homelab (incluyendo posibles _labels_ con _hostnames_, IPs y patrones de uso), se eleva la política a **`two_factor`**: usuario+contraseña + TOTP/WebAuthn antes de cualquier _query_.

Concretamente, este documento añade `prometheus.lan` a la regla `two_factor` del `~/homelab/seguridad/configuration.yml` (sección _Modificar Authelia_). El _snippet_ `(authelia)` ya está operativo desde `docs/04-seguridad/01-authelia.md`.

> **API y `tsdb` admin**: la API de Prometheus (incluido `/-/quit`, `/api/v1/admin/tsdb/delete_series`, `/api/v1/admin/tsdb/clean_tombstones`) **también** queda detrás de Authelia. Como `forward_auth` es a nivel de _request_, ningún cliente HTTP puede llamar a esos _endpoints_ sin pasar por el portal. La flag `--web.enable-admin-api` se queda **deshabilitada** por defecto (este doc no la activa); si se quisiera permitir borrado de series, se añade y se reinicia.

### Service discovery: `static_configs` (por ahora)

Prometheus soporta varios mecanismos de _service discovery_: `dns_sd_configs`, `docker_sd_configs`, `file_sd_configs`, `consul_sd_configs`, etc. Para un homelab con 10–15 _targets_ estáticos, el más simple y legible es **`static_configs` directo en `prometheus.yml`**:

- **`static_configs`** — _targets_ listados explícitamente. Cada doc posterior de la fase 5 (y de fases siguientes con _exporters_) **edita `prometheus.yml`** añadiendo su bloque. Diff legible en git, sin estado oculto.
- **No `docker_sd_configs`** — requeriría montar `/var/run/docker.sock` en Prometheus o pasar por `docker-socket-proxy`. Discovery automático brilla cuando hay decenas de contenedores efímeros; aquí los servicios son estables y declarativos.
- **No `file_sd_configs`** — la abstracción "un fichero por _target_" es útil con _autodiscovery_ externo (Ansible, Terraform); en este homelab cada _target_ se declara una sola vez, y el doc de su fase es donde tiene sentido escribirlo. Si en algún momento se quiere migrar a `file_sd_configs/`, el cambio es mecánico y _backwards-compatible_ con el `prometheus.yml` actual (Prometheus acepta ambos).

> **Convención**: cuando un futuro doc añada un _exporter_ (ej. `docs/05-monitorizacion/03-node-exporter.md`), su sección "Modificar `prometheus.yml`" inserta un bloque `- job_name: 'node'` con su `static_configs`, y termina con `docker exec prometheus kill -HUP 1` (o `curl -X POST http://prometheus:9090/-/reload` desde dentro de la red `homelab`) para recargar sin _restart_. La flag `--web.enable-lifecycle` activa esto.

### Sin Alertmanager

Prometheus puede enviar alertas a un **Alertmanager** que las dispatcha a Slack/Telegram/email. En este homelab se decide **no montarlo**:

- **Uptime Kuma** (`docs/05-monitorizacion/05-uptime-kuma.md`) cubre el caso "el servicio no responde" con notificaciones a Telegram/email/_webhook_. Es lo que el operador necesita el 95% del tiempo.
- **Reglas de alerta sobre métricas** (CPU/RAM/disk/temperature) son útiles pero, en una sola Pi, los falsos positivos son frecuentes (un _backup_ de Borg que dispara la CPU al 100% durante 30 minutos no es una emergencia). Si en algún momento se quiere, se monta Alertmanager como un servicio adicional del _stack_ `monitor` y se añaden las reglas a `~/homelab/monitor/prometheus/rules/*.yml` (subdirectorio dejado preparado en este doc).

Esta decisión se revisa cuando el homelab tenga >2 nodos físicos o servicios críticos (ej. uno que tenga SLA real, lo cual no aplica a un homelab personal).

---

## Almacenamiento

| Ruta en el host                                          | Contenido                                                                | Versionable | Backup |
|----------------------------------------------------------|--------------------------------------------------------------------------|-------------|--------|
| `~/homelab/monitor/docker-compose.yml`                   | Definición del _stack_                                                   | git         | git    |
| `~/homelab/monitor/prometheus/prometheus.yml`            | Configuración principal de Prometheus (sin secretos)                     | git         | git    |
| `~/homelab/monitor/prometheus/rules/`                    | Directorio para reglas de _alerting_/_recording_ (vacío por ahora)       | git         | git    |
| `~/homelab/monitor/.env`                                 | Imágenes pinneadas, retención, variables del _stack_ (sin secretos)      | **NO** (`.gitignore`) | git aparte (nota local) |
| `~/homelab/monitor/.env.example`                         | Plantilla con nombres de variables, sin valores                          | git         | git    |
| `~/homelab/monitor/.gitignore`                           | Excluye `.env`                                                           | git         | git    |
| `/mnt/hd2t/services/prometheus/data/`                    | TSDB (chunks + WAL + tombstones), bloqueo, queries.active                | **NO**      | **Sí** (Borgmatic) |

> El TSDB de Prometheus se respalda **en caliente**: los _chunks_ son ficheros immutables una vez sellados (cada 2 h por defecto) y el WAL es secuencial. Borg, con el _hook_ pre-backup vacío y _post-backup_ vacío, captura un _snapshot_ consistente sin necesidad de parar el contenedor. Para una restauración _bit-perfect_, basta con `docker compose stop prometheus`, restaurar el directorio y `docker compose up -d`.

---

## Estructura del _stack_ `monitor` tras este documento

```
~/homelab/monitor/
├── docker-compose.yml              # ← nuevo
├── .env                            # ← nuevo (NO versionado)
├── .env.example                    # ← nuevo (versionado)
├── .gitignore                      # ← nuevo (excluye .env)
└── prometheus/
    ├── prometheus.yml              # ← nuevo (versionado, sin secretos)
    └── rules/                      # ← nuevo (vacío; placeholder para futuras reglas)
        └── .gitkeep
```

Y en los discos externos:

```
/mnt/hd2t/services/prometheus/
└── data/                           # creado en docs/01-sistema/04-estructura-directorios.md
                                    #   - chown 65534:65534 en este doc
                                    #   - Prometheus crea wal/, chunks_head/, queries.active al primer arranque
```

Crear los directorios y fijar permisos:

```bash
# Subdirectorio del propio stack en HOME
mkdir -p ~/homelab/monitor/prometheus/rules
chmod 0750 ~/homelab/monitor
chmod 0750 ~/homelab/monitor/prometheus
chmod 0750 ~/homelab/monitor/prometheus/rules
touch ~/homelab/monitor/prometheus/rules/.gitkeep

# Estado de Prometheus: la imagen oficial corre como UID 65534 (nobody).
# El directorio ya existe (creado en docs/01-sistema/04-estructura-directorios.md),
# pero estaba en root:root 0755. Ajustar:
sudo chown -R 65534:65534 /mnt/hd2t/services/prometheus/data
sudo chmod 0750 /mnt/hd2t/services/prometheus/data
```

> **`.gitkeep`** mantiene el directorio `rules/` versionado aunque esté vacío. Cuando un futuro doc decida añadir reglas, se borra el `.gitkeep` y se añaden los `*.yml`.

---

## Variables de entorno

Crear `~/homelab/monitor/.env.example` (versionado en git, sin valores reales):

```bash
# --- Imágenes pinneadas -----------------------------------------------------
PROMETHEUS_IMAGE_TAG=v3.1.0

# --- Prometheus -------------------------------------------------------------
# Retención por tiempo y por tamaño. Prometheus borra los chunks por el
# límite que antes se cumpla. Ver Decisiones de diseño.
PROMETHEUS_RETENTION_TIME=30d
PROMETHEUS_RETENTION_SIZE=50GB

# URL pública del servicio — usada por Prometheus para construir links
# absolutos en su UI (alerta enlazando a la query, p. ej.) y por Authelia
# como rd= tras el login. Coincide con el bloque del Caddyfile.
PROMETHEUS_EXTERNAL_URL=https://prometheus.lan

# Intervalo global de scraping. 15 s es el default y suficiente para un
# homelab; se puede afinar por job en prometheus.yml si algún exporter
# es caro de scrapear (p. ej. blackbox-exporter con HTTPS).
PROMETHEUS_SCRAPE_INTERVAL=15s

# Intervalo global de evaluación de reglas. Coincide con el de scrape
# para evitar gaps; sin reglas activas, este parámetro es irrelevante.
PROMETHEUS_EVALUATION_INTERVAL=15s
```

Copiar a `.env` y ajustar (sin secretos — Prometheus en este despliegue **no** maneja credenciales):

```bash
cp ~/homelab/monitor/.env.example ~/homelab/monitor/.env
chmod 0600 ~/homelab/monitor/.env
```

Por defecto los valores de la plantilla son los correctos para el homelab. **No hay nada que rellenar a mano** salvo que el operador quiera otra retención o un _scrape_interval_ distinto.

`.gitignore` del _stack_:

```bash
cat > ~/homelab/monitor/.gitignore <<'EOF'
# Secretos y datos locales del operador
.env
EOF
```

---

## `~/homelab/monitor/prometheus/prometheus.yml`

Configuración principal de Prometheus. **Mínima**: un único _scrape_job_ apuntando al propio Prometheus. Cada doc posterior añade su bloque `- job_name:` aquí.

```yaml
---
# ============================================================================
# Prometheus — configuración principal
# Documentación: docs/05-monitorizacion/01-prometheus.md
# Esta config la consume prom/prometheus:v3.1.0 montada read-only.
#
# Convención para añadir un nuevo target:
#   1) En la sección 'scrape_configs:' de este fichero, añadir un bloque
#      '- job_name: <nombre>' con su 'static_configs.targets'.
#   2) Asegurarse de que el target está en la red Docker 'homelab' y que
#      su nombre interno (DNS) coincide con el del 'targets:'.
#   3) Recargar Prometheus sin restart:
#        docker exec prometheus kill -HUP 1
#      o, equivalente:
#        curl -fsS -X POST http://prometheus:9090/-/reload      # desde 'homelab'
#   4) Verificar en https://prometheus.lan/targets que el job sale UP.
# ============================================================================

global:
  scrape_interval:     15s          # default por job; se puede sobreescribir por job
  evaluation_interval: 15s          # frecuencia de evaluación de reglas
  scrape_timeout:      10s          # < scrape_interval; evita scrapes solapados

  # Etiquetas globales que se añaden a TODA serie. 'env=homelab' es útil
  # cuando se federa con un Prometheus externo o se hace remote_write a
  # un VictoriaMetrics central; no estorba mientras tanto.
  external_labels:
    env: homelab
    instance_role: pi5

# ---------------------------------------------------------------------------
# Reglas de alerting / recording — directorio versionado, vacío por ahora.
# Se montará en /etc/prometheus/rules dentro del contenedor.
# ---------------------------------------------------------------------------
rule_files:
  - /etc/prometheus/rules/*.yml

# ---------------------------------------------------------------------------
# Alertmanager — NO se monta (ver Decisiones de diseño).
# Si en el futuro se añade, descomentar y declarar el servicio en el compose.
# ---------------------------------------------------------------------------
# alerting:
#   alertmanagers:
#     - static_configs:
#         - targets:
#             - alertmanager:9093

# ---------------------------------------------------------------------------
# Scrape configs — UN job por servicio. Cada doc de fase posterior añade
# su bloque debajo de éste.
# ---------------------------------------------------------------------------
scrape_configs:

  # -------------------------------------------------------------------------
  # 1) El propio Prometheus — autocheck. /metrics expone series internas
  #    (cardinalidad del TSDB, latencia de queries, WAL, GC, ...).
  # -------------------------------------------------------------------------
  - job_name: 'prometheus'
    metrics_path: /metrics
    static_configs:
      - targets:
          - 'prometheus:9090'
        labels:
          service: prometheus
          stack:   monitor

  # -------------------------------------------------------------------------
  # PLACEHOLDER — futuros jobs. Cada doc de la fase 5 (y exporters de
  # otras fases) inserta su bloque aquí. Convención del nombre:
  #   - job_name: '<servicio>'    (minúsculas, sin sufijo '-exporter')
  #   - labels:
  #       service: <servicio>
  #       stack:   <stack>
  #
  # Pendientes anticipados (no descomentar hasta que el doc correspondiente
  # haya desplegado el target):
  #
  # - job_name: 'node'              # docs/05-monitorizacion/03-node-exporter.md
  # - job_name: 'cadvisor'          # docs/05-monitorizacion/04-cadvisor.md
  # - job_name: 'caddy'             # docs/03-red/04-caddy.md  (sección 'metrics' a añadir)
  # - job_name: 'authelia'          # docs/04-seguridad/01-authelia.md  (telemetry.metrics a habilitar)
  # - job_name: 'pihole'            # docs/03-red/02-pihole.md (vía pihole-exporter, doc futuro)
  # - job_name: 'blackbox'          # probes HTTP/ICMP, doc futuro
  # -------------------------------------------------------------------------
```

Permisos:

```bash
chmod 0644 ~/homelab/monitor/prometheus/prometheus.yml
```

> **Validación local antes de subir nada**:
>
> ```bash
> docker run --rm \
>   -v ~/homelab/monitor/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
>   -v ~/homelab/monitor/prometheus/rules:/etc/prometheus/rules:ro \
>   --entrypoint promtool \
>   prom/prometheus:v3.1.0 \
>   check config /etc/prometheus/prometheus.yml
> ```
>
> Salida esperada:
>
> ```
> Checking /etc/prometheus/prometheus.yml
>   SUCCESS: 0 rule files found
>
> Checking 1 scrape configs:
>   SUCCESS: prometheus
> ```

---

## `~/homelab/monitor/docker-compose.yml`

```yaml
---
# Stack: monitor — Prometheus (TSDB + scraper).
# Próximos servicios de este mismo compose: Grafana, Node Exporter, cAdvisor,
# Uptime Kuma, Dozzle (docs/05-monitorizacion/{02..06}.md).
# Documentación: docs/05-monitorizacion/01-prometheus.md

services:

  # ---------------------------------------------------------------------------
  # Prometheus — TSDB + scraper.
  # No publica :9090 al host. Caddy lo alcanza por DNS interno (prometheus:9090)
  # en la red 'homelab'.
  # ---------------------------------------------------------------------------
  prometheus:
    image: prom/prometheus:${PROMETHEUS_IMAGE_TAG}
    container_name: prometheus
    hostname: prometheus
    restart: unless-stopped
    # Imagen oficial; corre como UID 65534:65534 (nobody) — ya documentado
    # en docs/01-sistema/04-estructura-directorios.md (tabla de UIDs).
    user: "65534:65534"
    # Argumentos del binario. Las flags que se quieran ajustar en caliente
    # se exponen como env vars del compose (.env) y se interpolan aquí.
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=${PROMETHEUS_RETENTION_TIME}
      - --storage.tsdb.retention.size=${PROMETHEUS_RETENTION_SIZE}
      - --storage.tsdb.wal-compression                         # WAL ~50% más pequeño
      - --web.console.libraries=/usr/share/prometheus/console_libraries
      - --web.console.templates=/usr/share/prometheus/consoles
      - --web.external-url=${PROMETHEUS_EXTERNAL_URL}
      - --web.route-prefix=/                                   # paths relativos a la raíz
      - --web.enable-lifecycle                                 # POST /-/reload, /-/quit
      # --web.enable-admin-api  ← NO activado: ver Decisiones de diseño.
    environment:
      TZ: ${TZ}
    volumes:
      # Configuración versionable, read-only.
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/rules:/etc/prometheus/rules:ro
      # TSDB persistente (chunks + WAL). Backup obligatorio (homelab.backup=true).
      - /mnt/hd2t/services/prometheus/data:/prometheus
    networks:
      homelab:
        # Alias 'prometheus' por defecto; lo añadimos explícito para que
        # otros contenedores (Caddy reverse_proxy, Grafana datasource)
        # puedan referirse a él por nombre estable.
        aliases:
          - prometheus
    labels:
      homelab.stack: "monitor"
      homelab.backup: "true"      # /mnt/hd2t/services/prometheus/data
      # Opt-out: cambios de formato del WAL entre minor versions. Manual.
      com.centurylinklabs.watchtower.enable: "false"
    healthcheck:
      # /-/healthy responde 200 cuando Prometheus está vivo. /-/ready
      # responde 200 sólo cuando el WAL ha terminado de cargar (importante
      # tras un reinicio con TSDB grande: la carga puede tardar 10–30 s).
      # Usamos /-/ready para que 'depends_on: service_healthy' de Grafana
      # no arranque hasta que las queries devuelvan datos válidos.
      test:
        - CMD
        - wget
        - --quiet
        - --tries=1
        - --spider
        - http://localhost:9090/-/ready
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 60s    # margen para cargar WAL en arranques con TSDB pobladas

# ---------------------------------------------------------------------------
# Redes
# ---------------------------------------------------------------------------
networks:
  homelab:
    external: true               # creada en docs/02-docker/02-estructura-compose.md
  # NOTA: no se crea 'monitor-internal' por ahora. Cuando Grafana llegue
  # (docs/05-monitorizacion/02-grafana.md) y necesite hablar con un Postgres
  # exclusivo del stack, se añadirá esa red privada aquí.
```

Notas de diseño:

- **`user: "65534:65534"`** explícito: redundante con el _USER_ de la imagen, pero hace evidente al lector el UID del proceso y evita sorpresas si en el futuro se cambia la imagen base.
- **No hay `ports:`**. Prometheus se alcanza por DNS interno desde Caddy (`prometheus:9090`), nunca desde el host. La _admin API_ (cuando se active) tampoco se expone — siempre vía Caddy + Authelia.
- **`--web.enable-lifecycle`** habilita `POST /-/reload` (recarga `prometheus.yml` sin _restart_) y `POST /-/quit` (apagado limpio que vacía el WAL antes de salir, útil antes de un upgrade major).
- **`--storage.tsdb.wal-compression`**: comprime el WAL en disco. Coste CPU despreciable, ahorro ~50% en `wal/`. Se activa por defecto en `v3.x` pero se explicita por si la imagen base cambiase.
- **`healthcheck` con `/-/ready`** (no `/-/healthy`): `/-/ready` espera al fin de carga del WAL. Cuando Grafana llegue (`docs/05-monitorizacion/02-grafana.md`), su `depends_on: prometheus: condition: service_healthy` evita que Grafana arranque y haga _queries_ contra un Prometheus a medio cargar (lo que devolvería errores 503 y ensuciaría los _logs_).
- **Watchtower opt-out** explícito en el _label_, razón documentada en **Decisiones de diseño**.
- **Sin `mem_limit` / `cpus`**: en idle (con sólo el _self-scrape_) Prometheus consume <100 MB. Cuando lleguen Node Exporter y cAdvisor, se monitoriza el uso real desde el propio Prometheus (`process_resident_memory_bytes{job="prometheus"}`) y se decide si añadir un `mem_limit: 1g`. La política por defecto (sin límite) está bien para el _bootstrap_.

---

## Modificar Authelia: añadir `prometheus.lan` a `two_factor`

Editar `~/homelab/seguridad/configuration.yml` y añadir `prometheus.lan` a la regla `two_factor` que `docs/04-seguridad/01-authelia.md` dejó preparada con `portainer.lan`:

```diff
   # 3) Servicios críticos — exigir 2FA (TOTP / WebAuthn) además de 1FA.
   - domain:
       - 'portainer.lan'
+      - 'prometheus.lan'
       # - 'vaultwarden.lan'      # docs/11-productividad/01-vaultwarden.md
       # - 'nextcloud.lan'        # docs/06-almacenamiento/01-nextcloud.md
       # - 'home-assistant.lan'   # docs/08-domotica/01-home-assistant.md
     policy: two_factor
```

Validar y recargar Authelia (sin _restart_, gracias a `watch: true` del _backend_ de fichero):

```bash
docker exec authelia authelia validate-config --config /config/configuration.yml
docker exec authelia kill -HUP 1
```

> **Por qué 2FA y no la regla _default_ `*.lan = one_factor`**: razonado en **Decisiones de diseño**, sección _Acceso vía Caddy + Authelia 2FA_.

---

## Modificar el `Caddyfile`: bloque `prometheus.lan`

Editar `~/homelab/red/Caddyfile` y añadir, junto a los demás bloques de servicio (después de `portainer.lan` y antes del catch-all `*.lan`):

```caddyfile
# ---------------------------------------------------------------------------
# Prometheus — TSDB + UI. Acceso 2FA vía Authelia.
# docs/05-monitorizacion/01-prometheus.md
# ---------------------------------------------------------------------------
prometheus.lan {
    tls internal
    import security-headers
    import logging
    import authelia

    reverse_proxy prometheus:9090 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

Validar y recargar Caddy:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
# 'INF reload happened' en logs.
```

> **No** recargar Caddy **antes** de levantar el _stack_ `monitor`: el `reverse_proxy prometheus:9090` no podría resolver `prometheus` por DNS interno y los primeros 60 s mostrarían `dial tcp: lookup prometheus: no such host`. El orden es:
>
> 1. Modificar `prometheus.yml` y `docker-compose.yml` (este doc).
> 2. `make up STACK=monitor` — levanta Prometheus en `homelab`.
> 3. Modificar Authelia (sección anterior) y recargar.
> 4. Modificar el `Caddyfile` (esta sección) y recargar Caddy.

---

## Despliegue

```bash
cd ~/homelab/monitor
docker compose --env-file ../.env --env-file .env config | head -60    # validar sintaxis
docker compose --env-file ../.env --env-file .env up -d
```

O, equivalente, con el _Makefile_:

```bash
cd ~/homelab
make up STACK=monitor
```

Verificar:

```bash
docker compose -f ~/homelab/monitor/docker-compose.yml ps
# NAME         STATUS                   PORTS
# prometheus   Up X seconds (healthy)
```

> El `(healthy)` de Prometheus tarda ~30–60 s desde el arranque. La primera vez carga un WAL vacío y arranca rápido; en arranques posteriores con TSDB pobladas, el `start_period: 60s` da margen para que `/-/ready` devuelva 200.

Inspeccionar el TSDB recién inicializado:

```bash
ls -la /mnt/hd2t/services/prometheus/data/
# total 24
# drwxr-x---. 4  65534  65534  4096 ...  ./
# drwxr-xr-x. 3  root   root   4096 ...  ../
# -rw-r--r--. 1  65534  65534     0 ...  lock
# drwxr-x---. 2  65534  65534  4096 ...  chunks_head/
# -rw-r--r--. 1  65534  65534    20 ...  queries.active
# drwxr-x---. 3  65534  65534  4096 ...  wal/
```

Y desde el contenedor:

```bash
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
# SUCCESS: ...
docker exec prometheus wget -qO- http://localhost:9090/-/ready && echo
# Prometheus is Ready.
docker exec prometheus wget -qO- http://localhost:9090/api/v1/query?query=up | head -c 200
# {"status":"success","data":{"resultType":"vector","result":[{"metric":{...},"value":[...,"1"]}]}}
```

Verificar que el _self-scrape_ funciona (debe haber **un** target en estado `UP`):

```bash
curl -k --resolve prometheus.lan:443:192.168.1.3 \
     -H 'X-Forwarded-User: homelab' \
     "https://prometheus.lan/api/v1/targets" 2>/dev/null | head -c 500
# (la cabecera X-Forwarded-User no engaña a Authelia; este curl mostrará
#  el redirect a auth.lan a menos que se haya hecho login en navegador)
```

Para validar **end-to-end** la cadena Caddy + Authelia + Prometheus, abrir el navegador en `https://prometheus.lan/`:

1. Caddy redirige a `https://auth.lan/?rd=https%3A%2F%2Fprometheus.lan%2F`.
2. Authelia pide usuario+contraseña + TOTP (regla `two_factor`).
3. Tras autenticar, Authelia redirige a `https://prometheus.lan/`. Aparece la UI de Prometheus (página `/graph`).
4. Navegar a `/targets` (o `Status → Targets`): debe haber un único _target_ `prometheus` (job `prometheus`) en estado **UP**.
5. Navegar a `/config`: muestra el `prometheus.yml` _resolved_, con las `external_labels` (`env=homelab`, `instance_role=pi5`).

---

## Verificación final

Antes de pasar a `docs/05-monitorizacion/02-grafana.md`, comprobar:

- [ ] `docker compose -f ~/homelab/monitor/docker-compose.yml ps` muestra `prometheus` en estado `Up` y `(healthy)` tras ~60 s.
- [ ] `stat -c '%a %U:%G' /mnt/hd2t/services/prometheus/data` devuelve `750 65534:65534` (la imagen oficial corre como `nobody`).
- [ ] `ls /mnt/hd2t/services/prometheus/data/` lista al menos `lock`, `wal/`, `chunks_head/` y `queries.active` con propietario `65534:65534`.
- [ ] `docker exec prometheus promtool check config /etc/prometheus/prometheus.yml` devuelve `SUCCESS: prometheus`.
- [ ] `docker exec prometheus wget -qO- http://localhost:9090/-/healthy` devuelve `Prometheus Server is Healthy.`.
- [ ] `docker exec prometheus wget -qO- http://localhost:9090/-/ready` devuelve `Prometheus Server is Ready.`.
- [ ] `docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=up' | grep -o '"value":\[[^]]*\]'` muestra `[<timestamp>,"1"]` (el _self-scrape_ devuelve `up=1`).
- [ ] `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` acepta el bloque `prometheus.lan` añadido.
- [ ] `curl -k --resolve prometheus.lan:443:192.168.1.3 -I https://prometheus.lan/` devuelve `302 Found` con `Location: https://auth.lan/?rd=...` (Authelia interceptando, _no_ pasando directo a Prometheus).
- [ ] Login interactivo desde el navegador: usuario+contraseña + TOTP de Authelia → redirige a `https://prometheus.lan/` → la UI carga, `/targets` muestra `prometheus (1/1 up)`, `/config` muestra el `prometheus.yml` resolved con `env=homelab`.
- [ ] Recarga _en caliente_ funciona: añadir un comentario al final de `prometheus.yml` (cambio inocuo), `docker exec prometheus kill -HUP 1`, y comprobar `docker logs prometheus --tail 5` muestra `Loading configuration file ... level=info` con `filename=/etc/prometheus/prometheus.yml`.
- [ ] Tras un `docker compose -f ~/homelab/monitor/docker-compose.yml restart prometheus`, el WAL se carga y `/-/ready` vuelve a `200` en <30 s (con TSDB casi vacía; con TSDB poblada será más, hasta los 60 s del `start_period`).
- [ ] Tras un `sudo reboot` de la Pi, el _stack_ vuelve a estar `(healthy)` sin intervención manual y `https://prometheus.lan/` (tras login Authelia) responde con la UI.
- [ ] `git -C ~/homelab status` muestra como **modificados**: `red/Caddyfile`, `seguridad/configuration.yml`. Y como **nuevos**: `monitor/docker-compose.yml`, `monitor/.env.example`, `monitor/.gitignore`, `monitor/prometheus/prometheus.yml`, `monitor/prometheus/rules/.gitkeep`. **No** muestra `monitor/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add monitor/docker-compose.yml monitor/.env.example monitor/.gitignore \
          monitor/prometheus/prometheus.yml monitor/prometheus/rules/.gitkeep \
          red/Caddyfile seguridad/configuration.yml
  git commit -m "feat(monitor): add Prometheus TSDB + scraper with 30d/50GB retention on hd2t"
  ```

---

## Operaciones habituales

### Recargar la configuración sin _restart_

```bash
docker exec prometheus kill -HUP 1
# o, equivalente, desde dentro de la red 'homelab':
docker run --rm --network homelab curlimages/curl:8.10.1 \
    -fsS -X POST http://prometheus:9090/-/reload
```

Confirmar en _logs_:

```bash
docker logs prometheus --tail 5
# level=info ts=... msg="Loading configuration file" filename=/etc/prometheus/prometheus.yml
# level=info ts=... msg="Completed loading of configuration file" ...
```

> **Si la recarga falla**, Prometheus **mantiene la configuración anterior** (no aplica el cambio). El error sale en _logs_; el contenedor no se cae. Es seguro experimentar.

### Apagar de forma limpia (vaciar WAL antes de upgrade major)

```bash
docker exec prometheus wget -qO- --post-data='' http://localhost:9090/-/quit
# Espera a que el proceso salga (5–30 s según tamaño del WAL).
docker compose -f ~/homelab/monitor/docker-compose.yml stop prometheus
```

Tras esto, el directorio `data/wal/` queda casi vacío (sólo el _checkpoint_) y los _chunks_ están todos sellados. Es el estado correcto para hacer un upgrade entre _minors_ o un _backup_ en frío.

### _Queries_ rápidas desde la línea de comandos

```bash
# Carga del scraper (escrapeos por segundo, últimos 5 min)
docker exec prometheus wget -qO- \
    'http://localhost:9090/api/v1/query?query=rate(prometheus_tsdb_head_samples_appended_total[5m])' \
    | python3 -m json.tool

# Tamaño actual del TSDB en bytes
docker exec prometheus wget -qO- \
    'http://localhost:9090/api/v1/query?query=prometheus_tsdb_storage_blocks_bytes' \
    | python3 -m json.tool

# Cardinalidad: número de series activas
docker exec prometheus wget -qO- \
    'http://localhost:9090/api/v1/query?query=prometheus_tsdb_head_series'
```

### Añadir un nuevo _target_ (convención para docs siguientes)

1. Editar `~/homelab/monitor/prometheus/prometheus.yml` y añadir el bloque `- job_name:` con su `static_configs`.
2. Validar:

   ```bash
   docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
   ```

3. Recargar:

   ```bash
   docker exec prometheus kill -HUP 1
   ```

4. Verificar en `https://prometheus.lan/targets` que el nuevo job sale **UP**.
5. _Commit_ del `prometheus.yml` modificado.

---

## Backup

| Qué                                            | Dónde                                                       | Cómo                                            |
|------------------------------------------------|-------------------------------------------------------------|-------------------------------------------------|
| `docker-compose.yml`, `prometheus.yml`         | `~/homelab/monitor/`                                        | git                                             |
| `rules/*.yml` (cuando existan)                 | `~/homelab/monitor/prometheus/rules/`                       | git                                             |
| TSDB completa (chunks + WAL + tombstones)      | `/mnt/hd2t/services/prometheus/data/`                       | Borgmatic (`docs/07-backups/02-borgmatic.md`)   |

> **Restauración**: clonar el repo, restaurar `/mnt/hd2t/services/prometheus/data/` desde Borgmatic (con el contenedor parado para evitar conflictos del _lock file_), `make up STACK=monitor`, recargar Caddy. Las series se ven en la UI inmediatamente.

> **Restauración parcial** (sólo recuperar últimos 7 días tras una corrupción): Prometheus es tolerante a la pérdida de _chunks_ antiguos. Borrar selectivamente `/mnt/hd2t/services/prometheus/data/01<XXXX>/` (los _block IDs_ más viejos) deja los recientes intactos. **Nunca** borrar `wal/` o `chunks_head/` con el contenedor en marcha — son los _writeahead_ activos.

> **Sobre el tamaño del backup**: 30 días × ~10 _targets_ ≈ 3–6 GB. Borg deduplica entre _snapshots_ casi todo (los _chunks_ son immutables tras sellarse), así que el coste incremental por _backup_ diario tras el primero es de ~50–200 MB.

---

## Troubleshooting

### `prometheus` arranca y muerto en bucle: `opening storage failed: lock DB directory: open /prometheus/lock: permission denied`

El UID con el que corre el contenedor (65534) no puede escribir en el _bind mount_. Causa: el `chown` de la sección **Almacenamiento** no se aplicó. Confirmar:

```bash
stat -c '%a %U:%G' /mnt/hd2t/services/prometheus/data
# Esperado: '750 65534:65534'
```

Si no es así:

```bash
sudo chown -R 65534:65534 /mnt/hd2t/services/prometheus/data
sudo chmod 0750 /mnt/hd2t/services/prometheus/data
docker compose -f ~/homelab/monitor/docker-compose.yml up -d prometheus
```

### `level=error msg="Opening storage failed" err="block ... has unsupported version: ..."`

Probablemente se ha intentado downgrade entre _minors_ (de `v3.x` a `v2.55.x` con TSDB ya escrita por `v3`) o un upgrade entre _majors_ sin migrar. Recuperación:

1. **Si los datos no son críticos**: parar Prometheus, vaciar `/mnt/hd2t/services/prometheus/data/`, volver a la versión correcta. El TSDB se regenera vacía.
2. **Si los datos son críticos**: leer el _migration guide_ de la versión que escribió la TSDB, parar el contenedor, ejecutar el `promtool tsdb upgrade` (o equivalente) que la _release_ documente, y volver a arrancar.

### `level=warn msg="Error scraping target" target="..." err="server returned HTTP status 401 Unauthorized"`

El _target_ está protegido y Prometheus no envía credenciales. Soluciones:

1. **Quitar la protección del `/metrics`** del _target_ (lo correcto en una red interna): muchos _exporters_ ofrecen un puerto secundario sin auth para métricas. Es el caso de `caddy:metrics` (puerto 2019 lado admin) y de Authelia con `telemetry.metrics.address`.
2. **Configurar `basic_auth` en el job** del `prometheus.yml`:

   ```yaml
   - job_name: 'foo'
     basic_auth:
       username: prometheus
       password_file: /etc/prometheus/foo-password   # secreto vía bind mount
     static_configs:
       - targets: ['foo:8080']
   ```

3. **Authelia bypass** vía `forward_auth` con un _matcher_ específico (`/metrics`) — sólo si el _target_ va detrás de Caddy y no se quiere exponer un puerto secundario.

### `level=warn msg="Skipping resolution for ..."` o el target sale `DOWN` con `getsockopt: connection refused`

El nombre DNS no resuelve dentro de la red `homelab` o el puerto del _target_ no escucha. Diagnóstico:

```bash
docker exec prometheus wget -qO- http://<target-name>:<port>/metrics
# Si "Bad address ...": el target no está en homelab. Confirmar con:
docker network inspect homelab --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}'
# Si "Connection refused": el target está en homelab pero no escucha en ese puerto.
```

Solución: enchufar el _target_ a la red `homelab` (sección `networks:` del compose del _stack_ correspondiente) o ajustar el puerto en `prometheus.yml`.

### El TSDB crece más rápido de lo esperado

Causa típica: un _exporter_ con cardinalidad explosiva (etiquetas con _request paths_, IPs de cliente, IDs de sesión…). Diagnosticar:

```bash
# Top 10 metric names por cardinalidad
docker exec prometheus wget -qO- \
    'http://localhost:9090/api/v1/status/tsdb' \
    | python3 -c "import json,sys;d=json.load(sys.stdin)['data']['seriesCountByMetricName'];[print(f'{x[\"value\"]:>8}  {x[\"name\"]}') for x in d[:20]]"
```

Mitigaciones:

- **Reducir `scrape_interval`** del job problemático (de 15s a 60s) → 4× menos _samples_.
- **Filtrar etiquetas** con `metric_relabel_configs` antes de almacenar (ej. _drop_ de _label_ `path` si el _exporter_ explota el _cardinality_).
- **Bajar `retention.time`** a `15d`. Cambia la variable en `.env`, `docker compose up -d prometheus`.

### `wget: bad address 'prometheus'` desde otro contenedor

El otro contenedor no está en la red `homelab`. Confirmar:

```bash
docker inspect <otro-contenedor> --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}'
```

Si `homelab` no sale en la lista, añadirlo en su `docker-compose.yml` (sección `networks:` del servicio) y `docker compose up -d <servicio>`.

### Tras un `docker compose down`, los datos siguen ahí pero el contenedor no arranca

`docker compose down` **no** borra _bind mounts_; los datos están a salvo. Si el contenedor no arranca tras un `up -d`, casi siempre es uno de los tres errores de arriba (permisos, formato, network). Revisar `docker logs prometheus --tail 50`.

### Prometheus consume mucha CPU y la Pi se calienta

Diagnóstico rápido:

```bash
docker stats prometheus --no-stream
# CPU sostenido >50% en una Pi 5 con <15 targets es anómalo.
```

Causas habituales:

1. **Cardinalidad muy alta** (mismo síntoma que "TSDB crece rápido", arriba). Aplicar las mismas mitigaciones.
2. **Reglas de _recording_ pesadas** en `rules/`. Mirar `prometheus_rule_evaluation_duration_seconds`.
3. **WAL replay tras un kill no limpio**: tras un `kill -9` del contenedor o un _power loss_, el siguiente arranque reproduce todo el WAL para recomponer `chunks_head`. CPU al 100% durante 30–120 s es normal en ese caso. Verificar:

   ```bash
   docker logs prometheus 2>&1 | grep -i 'wal'
   # ... msg="Replaying WAL, this may take a while"
   # ... msg="WAL replay completed" duration=...
   ```

   Esperar a que termine; si tarda > 5 min, es un WAL corrupto: parar, vaciar `wal/` (perdiendo los últimos minutos de datos) y reiniciar.

---

## Referencias

- Prometheus — Documentación oficial: <https://prometheus.io/docs/introduction/overview/>
- Prometheus — `prometheus.yml` schema: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/>
- Prometheus — Storage: <https://prometheus.io/docs/prometheus/latest/storage/>
- Prometheus — Operational features (lifecycle, admin API): <https://prometheus.io/docs/prometheus/latest/management_api/>
- Prometheus — `promtool` reference: <https://prometheus.io/docs/prometheus/latest/command-line/promtool/>
- Prometheus — Migration guide v2 → v3: <https://prometheus.io/docs/prometheus/latest/migration/>
- Prometheus — Imagen Docker oficial: <https://hub.docker.com/r/prom/prometheus>
- Prometheus — Best practices on instrumentation and labeling: <https://prometheus.io/docs/practices/naming/>
- PromQL — Basics: <https://prometheus.io/docs/prometheus/latest/querying/basics/>
- Grafana Labs — Dashboards de Prometheus: <https://grafana.com/grafana/dashboards/?dataSource=prometheus>
