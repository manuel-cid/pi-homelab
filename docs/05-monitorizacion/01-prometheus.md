# Prometheus

## Descripción

Cerrada la Fase 4, el homelab está operativamente "completo" como plataforma: la red doméstica resuelve por Pi-hole + Unbound (`03-red/02-pihole.md`, `03-red/03-unbound.md`), Caddy sirve los servicios por TLS interno con la CA del homelab (`03-red/04-caddy.md`), el tailnet permite acceso remoto (`03-red/05-tailscale.md`), Authelia centraliza login y 2FA (`04-seguridad/01-authelia.md`) y `fail2ban` banea los intentos hostiles a SSH y al portal de auth (`04-seguridad/02-fail2ban.md`). Lo que falta es **saber lo que pasa dentro**: qué contenedor consume RAM, cuándo la temperatura del SoC se va de paseo, si el AOF de Redis crece más de la cuenta, si la SD-card empieza a tirar errores, cuántos paquetes está bloqueando Pi-hole por hora. Hasta ahora la respuesta a "¿qué tal está la Pi?" es `htop` por SSH.

Este documento despliega **Prometheus**, la base de datos de series temporales que vertebra la observabilidad del homelab. Su rol concreto:

1. **Recolectar métricas (scrape)** desde un conjunto fijo de *exporters* HTTP (`/metrics` en formato OpenMetrics): el propio Prometheus, Node Exporter (sistema operativo: CPU/RAM/disco/red/temperatura), cAdvisor (recursos por contenedor), Caddy (latencias y códigos HTTP) y, según se vayan desplegando, Pi-hole exporter, MQTT exporter, etc. Los siguientes documentos de la Fase 5 los van añadiendo.
2. **Almacenarlas en una TSDB local** con un horizonte de **30 días** y un tope duro de **10 GiB** en `hd2t`. El homelab no necesita historial de años: con 30 días basta para detectar regresiones, correlacionar fallos del fin de semana pasado y ver tendencias estacionales (uso de Jellyfin los sábados, picos de Pi-hole tras un cumpleaños lleno de móviles invitados).
3. **Servir como datasource** para `02-grafana.md` (que dibujará dashboards) y como motor de queries para `05-uptime-kuma.md` cuando éste pregunte por el estado de los servicios.
4. **Sentar las bases para alerting**: aunque Alertmanager **no** se despliega en este documento (decisión documentada abajo), `prometheus.yml` deja preparada la sección `alerting:` y `rule_files:` para activarse en una iteración futura sin reescribir la configuración.

Lo que este documento **no** decide:

- **Alertmanager**: enviar notificaciones por Telegram/email cuando la temperatura supera 75 °C, cuando un contenedor lleva 5 minutos en `CrashLoopBackOff` casero o cuando la SD-card se queda sin espacio. Se documenta como reabrible al final; hoy se considera suficiente con que `05-uptime-kuma.md` cubra notificaciones de availability simples y que las queries vivan en Grafana.
- **Grafana**: dashboards y visualización viven en `02-grafana.md`. Aquí Prometheus es invisible (sin UI bonita); su único cliente humano "rico" es Grafana.
- **Node Exporter, cAdvisor, exporters específicos**: cada exporter tiene su propio documento (`03-node-exporter.md`, `04-cadvisor.md`). En `prometheus.yml` aparecen sus *jobs* preconfigurados; mientras esos contenedores no estén levantados, Prometheus marcará los targets como `down` y seguirá funcionando con normalidad.
- **Recording rules y SLOs**: pre-cálculo de métricas agregadas (`job:cpu_seconds:rate5m` y compañía) y cálculo de SLOs/error budgets. Sobreingeniería para 1–3 usuarios; reabrible si en el futuro hay decenas de servicios y dashboards lentos.
- **Remote write a un Mimir/VictoriaMetrics externo**, federación entre dos Prometheus, alta disponibilidad. Una sola instancia local cubre el caso de uso; respaldo de la TSDB se discute en "Backup" (resumen: no se respalda, se acepta perderla).

Cuando este documento se haya aplicado, el operador puede:

- Abrir `https://prometheus.${DOMAIN_LAN}/` desde la LAN (con login Authelia 2FA) y lanzar una query ad-hoc (`up`, `node_load1`, `rate(container_cpu_usage_seconds_total[1m])`).
- Ver en `Status → Targets` la lista de scrape jobs (algunos en `up`, otros aún `down` hasta que los siguientes documentos los desplieguen).
- Confirmar que la TSDB está creciendo en `/mnt/hd2t/apps/prometheus/data/` con el formato típico (`wal/`, `chunks_head/`, bloques `01HXY.../`).
- Recargar la configuración en caliente (`docker kill --signal=SIGHUP prometheus`) sin perder el WAL ni cortar el scrape.

> **Recordatorio de alcance**: Prometheus escucha **solo** en la red Docker `homelab`; no publica `ports:` al host. Solo se accede a su UI a través de Caddy, y la API HTTP está accesible para Grafana **solo** desde dentro de la red Docker (Grafana resuelve `prometheus:9090` por nombre). Ningún cambio en el router doméstico, ninguna exposición pública.

---

## Requisitos Previos

- **Fase 2** completa (Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN=lan`).
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre automáticamente `prometheus.${DOMAIN_LAN}` sin tocar Pi-hole).
  - Caddy desplegado y los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` en `Caddyfile`.
- **Fase 4** completa, en particular:
  - Authelia desplegado, snippet `(authelia_two_factor)` definido en `stacks/caddy/conf.d/01-authelia.caddy`. Si Authelia no estuviera, Prometheus se podría servir con `(lan_only)` (allowlist por IP) y se documentaría aquí, pero el orden de fases ya lo da por hecho.
- Disco `hd2t` montado en `/mnt/hd2t` con al menos **15 GiB** libres reservados para Prometheus (10 GiB de TSDB + margen para WAL + bloques en compactación).
- Operador con la **CA interna instalada** en su navegador (`03-red/04-caddy.md` → "Instalar el root CA en los clientes").

Comprobaciones rápidas:

```bash
# La red Docker compartida existe
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Caddy y Authelia están corriendo
docker ps --filter name=caddy --filter name=authelia --format '{{.Names}} {{.Status}}'
# caddy      Up 2 days (healthy)
# authelia   Up 2 days (healthy)

# prometheus.lan resuelve al IP de la Pi (gracias al comodín)
dig +short prometheus.lan @192.168.1.2
# 192.168.1.10

# Espacio en hd2t
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'
# 1.6T libres
```

---

## Decisión: imagen y versión

Prometheus publica imágenes oficiales multi-arch (`amd64`, `arm64`, `armv7`) en Docker Hub bajo `prom/prometheus` y mirror en Quay (`quay.io/prometheus/prometheus`). Para la Pi 5 (aarch64) se usa el manifest `arm64` automáticamente.

| Tag | Cuándo usar | Decisión aquí |
|---|---|---|
| `latest` | Demos. | Descartado (convención de Fase 2). |
| `v2` | "Última 2.x". | Descartado: minors han traído cambios en flags y formatos (`--enable-feature`, semantics de TSDB). |
| `v2.55` | Última `v2.55.x`. | Aceptable; Prometheus es estable y bumpear de patch es raro que rompa nada. |
| `v2.55.1` (ejemplo) | Versión exacta `MAYOR.MENOR.PARCHE`. | **Aceptado** como compromiso entre reproducibilidad y mantenimiento. |
| `v3.x` | Saltar a la rama 3.x cuando haya estabilizado. | Diferido: Prometheus 3.0 cambió defaults (UTF-8 en labels, etc.); se documenta como reabrible. |

> **Tag exacto en uso**: `prom/prometheus:v2.55.1`. Si en el momento de aplicar este documento existe una `v2.55.x` superior con changelog limpio (sin cambios de flag y sin migraciones de TSDB), se actualiza el tag aquí y en `docker-compose.yml`. **Nunca `latest`**.

> **Por qué Prometheus y no VictoriaMetrics / InfluxDB**. VictoriaMetrics es más eficiente en disco/CPU y se considera *drop-in* para Prometheus, pero introduce un binario distinto y tiene comportamientos sutilmente diferentes en queries (`absent_over_time`, `rate` con muestras irregulares). Prometheus es la referencia: Grafana lo trata como ciudadano de primera, los exporters lo asumen y todos los dashboards de "Node Exporter Full" están escritos para él. InfluxDB cambió de TSM a IOx, requiere Flux/SQL y rompe la pauta de PromQL en todo el ecosistema. Para 5 hosts y ~50 series activas la diferencia de rendimiento es invisible; gana legibilidad y comunidad.

---

## Decisión: retención de datos

Prometheus 2.x admite dos límites simultáneos (se aplica el más restrictivo):

- `--storage.tsdb.retention.time`: tiempo máximo. Default `15d`.
- `--storage.tsdb.retention.size`: tamaño máximo de la TSDB (excluye el WAL).

| Política | Pros | Contras | Veredicto |
|---|---|---|---|
| **30 días + 10 GiB** | 30 días cubre ciclos semanales y eventos puntuales (cumpleaños, viajes), 10 GiB es el 0.5% de `hd2t` y no asfixia. | Si llegan 50+ exporters habrá que subir el cap. | **Aceptado** para Fase 5. |
| 90 días + 30 GiB | Permite ver tendencias estacionales (verano vs invierno). | Mayor consumo IOPS en compactación. | Reabrible cuando termine Fase 12. |
| 1 año + sin tope de tamaño | Histórico completo. | TSDB acaba dominando el disco si un exporter genera cardinalidad alta. | Descartado: contradice el principio de "el homelab no es un sistema histórico". |
| 7 días + 2 GiB | Mínimo viable para depurar incidentes recientes. | Pierde patrones semanales, hace inútil un dashboard de "uso de Jellyfin por día de la semana". | Descartado. |

Resultado: **`--storage.tsdb.retention.time=30d --storage.tsdb.retention.size=10GB`**. Si en algún momento la TSDB se acerca al cap, Prometheus borra los bloques más antiguos automáticamente sin romper nada.

> **Cardinalidad y el riesgo real**. La TSDB no crece tanto por *muchas series* como por *series con labels altamente variables* (request_id, ruta exacta, IP de cliente). El homelab tiene exporters bien domesticados: Node Exporter genera ~500 series por host, cAdvisor ~200 series por contenedor con labels finitos. En un sistema con 30 contenedores estables, el total se queda en ~10–20 k series activas. Para esa carga 10 GiB equivalen a **meses** de retención, no a 30 días. El cap está puesto como red de seguridad, no como horizonte real.

---

## Decisión: scrape interval, evaluation y timeout

| Parámetro | Default Prometheus | Valor en el homelab | Razonamiento |
|---|---|---|---|
| `scrape_interval` | `1m` | `30s` | Las series son baratas; 30 s da resolución suficiente para ver picos de un servicio sin saturar la TSDB. |
| `evaluation_interval` | `1m` | `30s` | Igual al scrape; sin recording rules hoy, pero queda alineado para el día que se activen. |
| `scrape_timeout` | `10s` | `10s` | Default conservador. Exporters lentos como cAdvisor pueden tardar varios segundos en hosts cargados; 10 s deja margen. |

> **No bajar a 15 s o 10 s**. Cada bajada multiplica el WAL y los IOPS. La SD-card del Pi 5 sufre con escrituras intensivas y, aunque la TSDB vive en `hd2t`, los efectos son perceptibles si se generan series a 5 s. 30 s es el dulce de Prometheus en homelab.

---

## Decisión: dónde vive la TSDB y permisos

Prometheus corre como UID `nobody` (`65534`) en la imagen oficial. Los bind mounts deben ser propiedad de ese UID o ajustarse con `--user`. Opciones:

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| Volumen Docker nombrado | Docker gestiona permisos solo. | Backup y troubleshooting menos directos; TSDB acaba en `/var/lib/docker/volumes/...` (microSD), inaceptable. | Descartado. |
| Bind mount con `chown 65534:65534` en hd2t | TSDB visible, fácil de hacer `du -sh`, fácil de excluir de Borg. | El UID `65534` es genérico (`nobody`); compartirlo con otros stacks puede dar líos. | **Aceptado**: directorio dedicado, owner único. |
| Bind mount con `--user $(PUID):$(PGID)` (1000:1000) | Misma identidad que el operador; `ls` legible. | Requiere flag `--user` consistente; si la imagen futura cambia, romper. | Descartado: añadir un flag opinable por estética no compensa. |

Resultado: bind mount en `/mnt/hd2t/apps/prometheus/data` con `chown 65534:65534`. La configuración (`prometheus.yml`) vive en `/mnt/hd2t/apps/prometheus/config` con `homelab:homelab` y modo `0644` (montada `:ro` en el contenedor).

---

## Stack: `stacks/prometheus/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/prometheus/docker-compose.yml` | microSD (git) | Stack (servicio `prometheus`). |
| `stacks/prometheus/.env.example` | microSD (git) | Plantilla con `PROMETHEUS_*` (vacío en esta fase). |
| `stacks/prometheus/prometheus.yml` | microSD (git) | Configuración versionada de scrape jobs. |
| `stacks/prometheus/rules/` | microSD (git) | Carpeta para futuras *recording* y *alerting rules* (vacía hoy). |
| `stacks/caddy/conf.d/02-prometheus.caddy` | microSD (git) | Drop-in del bloque LAN para `prometheus.${DOMAIN_LAN}`. |
| `/mnt/hd2t/apps/prometheus/config/prometheus.yml` | hd2t | Configuración materializada (bind mount). |
| `/mnt/hd2t/apps/prometheus/config/rules/` | hd2t | Reglas materializadas. |
| `/mnt/hd2t/apps/prometheus/data/` | hd2t | TSDB (bloques + WAL). Owner `65534:65534`. |

### `stacks/prometheus/docker-compose.yml`

```yaml
# Prometheus — TSDB y scrape engine del homelab.
# Documentado en docs/05-monitorizacion/01-prometheus.md.

name: prometheus

services:
  prometheus:
    image: prom/prometheus:v2.55.1
    container_name: prometheus
    hostname: prometheus
    restart: unless-stopped

    # No publica `ports:` al host: solo accesible vía Caddy y vía red `homelab`.
    expose:
      - "9090"

    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
      - '--storage.tsdb.retention.size=10GB'
      - '--storage.tsdb.wal-compression'
      - '--web.enable-lifecycle'                       # permite SIGHUP / POST /-/reload
      - '--web.external-url=https://prometheus.${DOMAIN_LAN}/'
      - '--web.route-prefix=/'
      - '--web.listen-address=0.0.0.0:9090'
      - '--log.level=info'

    environment:
      TZ: ${TZ}

    volumes:
      - /mnt/hd2t/apps/prometheus/config/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - /mnt/hd2t/apps/prometheus/config/rules:/etc/prometheus/rules:ro
      - /mnt/hd2t/apps/prometheus/data:/prometheus

    networks:
      - homelab

    healthcheck:
      # /-/healthy responde 200 cuando Prometheus arrancó y la TSDB está OK.
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:9090/-/healthy"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

    labels:
      homelab.role: "metrics-tsdb"
      homelab.backup: "false"   # la TSDB es regenerable; ver "Backup".
      com.centurylinklabs.watchtower.enable: "true"

networks:
  homelab:
    external: true
```

> **Sobre `--web.enable-lifecycle`**: habilita los endpoints `POST /-/reload` (recarga `prometheus.yml`) y `POST /-/quit` (apaga el proceso). Sin esto, recargar configuración exige `docker restart prometheus`, que descarta el WAL en memoria (Prometheus lo replay-ea al arranque, pero añade ~10 s de gap en las series). Con la flag activa, `docker kill --signal=SIGHUP prometheus` recarga sin gap. La superficie expuesta es interna (red `homelab`), no se publica.

> **Sobre `--web.external-url`**: necesario para que los redirects internos de Prometheus (botones de "Graph", "Targets") apunten al dominio público vía Caddy y no a `http://localhost:9090/`. Sin esto, hacer click en "Targets → endpoint" generaba URLs `http://prometheus:9090/...` que un cliente en el navegador no resuelve.

> **Sobre `--storage.tsdb.wal-compression`**: comprime el WAL en disco con snappy. CPU prácticamente nulo en arm64; reducción de ~50% en escrituras y tamaño de WAL. Default desde 2.20+ pero se deja explícito para que el commit que lo introduce sea descubrible.

### `stacks/prometheus/.env.example`

```bash
# stacks/prometheus/.env.example
# Variables específicas del stack Prometheus. Las generales (TZ, DOMAIN_LAN)
# vienen del .env GLOBAL del homelab.
#
# (Vacío en esta fase: Prometheus no necesita credenciales para sus exporters
# locales — autenticación HTTP queda para la entrada por Caddy.)
```

### `stacks/prometheus/prometheus.yml`

Configuración inicial. Cada job apunta a un servicio que será desplegado durante la Fase 5; mientras no lo esté, el target aparece como `down` en `Status → Targets`, lo cual es **el comportamiento esperado y deseable** (acta como checklist visual de la Fase).

```yaml
# /etc/prometheus/prometheus.yml — Prometheus.
# Documentado en docs/05-monitorizacion/01-prometheus.md.

global:
  scrape_interval: 30s
  scrape_timeout: 10s
  evaluation_interval: 30s
  external_labels:
    homelab: pi5
    env: prod   # solo hay un entorno; etiqueta semántica para futuro multi-host.

# Reglas (recording + alerting). Carpeta vacía hoy; preparada para Fase 5+.
rule_files:
  - /etc/prometheus/rules/*.yml

# Alertmanager: comentado a propósito. Reabrible cuando se decida desplegarlo
# (ver "Decisiones que no se toman"). Dejar el bloque presente y comentado
# es señal explícita de "esto es opcional pero conocido".
# alerting:
#   alertmanagers:
#     - static_configs:
#         - targets: ["alertmanager:9093"]

scrape_configs:
  # ---------------------------------------------------------------------------
  # 1) Prometheus se monitoriza a sí mismo. No es vanidad: detectar si el
  # propio scrape engine empieza a saltarse intervalos (CPU saturada,
  # disco lento) es lo primero que se mira al investigar un fallo.
  # ---------------------------------------------------------------------------
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
        labels:
          instance: 'prometheus'

  # ---------------------------------------------------------------------------
  # 2) Node Exporter — métricas del sistema operativo (CPU, RAM, disco, red,
  # temperatura del SoC). Despliegue: docs/05-monitorizacion/03-node-exporter.md.
  # Mientras no esté: target aparece como down (esperado).
  # ---------------------------------------------------------------------------
  - job_name: node
    static_configs:
      - targets: ['node-exporter:9100']
        labels:
          instance: 'pi5'

  # ---------------------------------------------------------------------------
  # 3) cAdvisor — métricas por contenedor Docker.
  # Despliegue: docs/05-monitorizacion/04-cadvisor.md.
  # ---------------------------------------------------------------------------
  - job_name: cadvisor
    static_configs:
      - targets: ['cadvisor:8080']
        labels:
          instance: 'pi5'

  # ---------------------------------------------------------------------------
  # 4) Caddy — métricas de reverse proxy (latencias por host, códigos HTTP,
  # bytes servidos). Caddy v2 expone /metrics en su admin API (puerto 2019)
  # cuando se activa con `servers.metrics` en el Caddyfile. La activación
  # vive en docs/03-red/04-caddy.md (sección "Métricas para Prometheus");
  # si aún no está, este target aparece como down.
  # ---------------------------------------------------------------------------
  - job_name: caddy
    static_configs:
      - targets: ['caddy:2019']
        labels:
          instance: 'caddy'

  # ---------------------------------------------------------------------------
  # Más jobs (pi-hole-exporter, mosquitto-exporter, jellyfin-exporter, etc.)
  # se añaden durante Fases 8–9 a medida que sus servicios entren en juego.
  # ---------------------------------------------------------------------------
```

> **Sobre `external_labels`**: Prometheus añade estos labels a cada métrica **al federarse** o al enviarla por `remote_write`. Hoy no hay ni federación ni remote_write, pero las etiquetas son baratas y dan contexto cuando se investiga una serie en bruto. `homelab: pi5` permite distinguir esta instancia si en el futuro se monta un Prometheus en otra máquina.

### Drop-in de Caddy: `stacks/caddy/conf.d/02-prometheus.caddy`

```caddy
# /etc/caddy/conf.d/02-prometheus.caddy — bloque LAN para Prometheus.
# Documentado en docs/05-monitorizacion/01-prometheus.md.

prometheus.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck
    import authelia_two_factor    # Prometheus no tiene auth propia; SSO + TOTP obligatorios.

    reverse_proxy http://prometheus:9090 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

> **Por qué `two_factor` y no `one_factor`**. La UI de Prometheus es de solo lectura, pero la API expone endpoints destructivos cuando `--web.enable-lifecycle` está activa: `POST /-/reload` (recarga config) y `POST /-/quit` (apaga el proceso). Cualquiera con sesión válida podría apagar la TSDB. Forzar TOTP eleva el coste de un compromiso de credenciales y se alinea con la política deny-by-default de Authelia.

> **Y `access_control` en Authelia**. Recordar añadir `prometheus.${DOMAIN_LAN}` al bloque `two_factor` de `configuration.yml` de Authelia (`04-seguridad/01-authelia.md`); con `default_policy: deny`, no listarlo equivale a denegar acceso aunque el `forward_auth` se importe. Cambio mínimo, recargable en caliente.

### Crear los directorios persistentes y desplegar

```bash
# Directorios de datos
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/prometheus
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/prometheus/config
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/prometheus/config/rules

# La TSDB la escribe el UID 65534 (nobody) interno de la imagen oficial.
sudo install -d -o 65534 -g 65534 -m 0750 /mnt/hd2t/apps/prometheus/data

# Materializar configuración desde la versión en git
cd /home/homelab/homelab
set -a; source .env; set +a

install -o homelab -g homelab -m 0644 \
    stacks/prometheus/prometheus.yml \
    /mnt/hd2t/apps/prometheus/config/prometheus.yml

# Drop-in de Caddy
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/02-prometheus.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/02-prometheus.caddy

# .env del stack (vacío en esta fase)
cp stacks/prometheus/.env.example stacks/prometheus/.env
chmod 0600 stacks/prometheus/.env

# Validar la configuración antes de levantar (usa el binario promtool de la imagen)
docker run --rm \
    -v /mnt/hd2t/apps/prometheus/config:/etc/prometheus:ro \
    --entrypoint promtool \
    prom/prometheus:v2.55.1 \
    check config /etc/prometheus/prometheus.yml
# Checking /etc/prometheus/prometheus.yml
#  SUCCESS: 0 rule files found

# Añadir prometheus.${DOMAIN_LAN} a access_control.rules de Authelia
# (si no se hizo ya). Política: two_factor.
sudo $EDITOR /mnt/hd2t/apps/authelia/config/configuration.yml
# Authelia detecta el cambio (watch: true) y recarga; verificar:
docker logs authelia --tail 20 | grep -i 'reloaded'

# Levantar Prometheus
docker compose \
    -f stacks/prometheus/docker-compose.yml \
    --env-file stacks/prometheus/.env \
    up -d

# Recargar Caddy para que tome el nuevo drop-in
docker exec caddy caddy validate --config /etc/caddy/Caddyfile && \
    docker kill --signal=SIGUSR1 caddy
```

Tras `up -d`:

```bash
docker ps --filter name=prometheus
# CONTAINER ID  IMAGE                       STATUS                  PORTS    NAMES
# ...           prom/prometheus:v2.55.1     Up 30 seconds (healthy)          prometheus

docker compose -f stacks/prometheus/docker-compose.yml logs --tail 20 prometheus
# level=info ts=... caller=main.go:... msg="Starting Prometheus" version="(version=2.55.1, ...)"
# level=info ts=... msg="Starting TSDB ..."
# level=info ts=... msg="Server is ready to receive web requests."
```

---

## Configuración

### 1) Acceso al portal

Desde un cliente de la LAN con la CA interna ya instalada:

```text
1. Abrir https://prometheus.lan/
2. Caddy redirige a https://auth.lan/?rd=https://prometheus.lan/ (no hay sesión).
3. Login con `homelab` + TOTP.
4. Authelia escribe la cookie en `.lan` y redirige de vuelta.
5. Caddy llama a /api/verify -> Authelia responde 200 -> Prometheus responde.
6. La UI de Prometheus carga en `/`. Probar con la query `up`.
```

### 2) Verificar targets

```text
Status → Targets
```

Debe mostrar al menos `prometheus → up`. Los demás (`node`, `cadvisor`, `caddy`) aparecen como `down` con `connection refused` o `dial tcp: lookup ... no such host`. Es lo esperado hasta que sus documentos respectivos se apliquen. Cada vez que se cierre uno de esos documentos se vuelve aquí, se confirma que el target ha pasado a `up`, y se cierra la fase.

### 3) Recargar configuración sin reiniciar

Tras editar `prometheus.yml` (añadir un nuevo job, ajustar `scrape_interval`...):

```bash
# Materializar
install -o homelab -g homelab -m 0644 \
    stacks/prometheus/prometheus.yml \
    /mnt/hd2t/apps/prometheus/config/prometheus.yml

# Validar
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
# SUCCESS

# Recargar (NO reiniciar)
docker kill --signal=SIGHUP prometheus
# o equivalentemente:
# docker exec prometheus wget -qO- --post-data='' http://127.0.0.1:9090/-/reload

# Verificar
docker logs prometheus --tail 5 | grep -E 'reload|Loading'
# level=info ... msg="Loading configuration file" filename=/etc/prometheus/prometheus.yml
# level=info ... msg="Completed loading of configuration file" filename=/etc/prometheus/prometheus.yml
```

Si la configuración tiene un error sintáctico, Prometheus rechaza la recarga y **mantiene** la anterior funcionando. Es el flujo seguro: el binario nunca se queda sin config válida.

### 4) Queries útiles para verificar la instalación

Desde la pestaña `Graph` del portal:

```promql
# 1) Prometheus está vivo y se scrape-a a sí mismo
up{job="prometheus"} == 1

# 2) Cuántos samples se ingestan por segundo en total (debe ser > 0)
rate(prometheus_tsdb_head_samples_appended_total[1m])

# 3) Tamaño actual de la TSDB en bytes (excluye WAL)
prometheus_tsdb_storage_blocks_bytes

# 4) Series activas en el head block (las "vivas")
prometheus_tsdb_head_series

# 5) Targets totales y cuántos están UP por job
count by (job) (up)
sum by (job) (up == 1)
```

### 5) Forzar un scrape manual desde el contenedor

Útil para depurar latencia o problemas de DNS antes de mirar la UI:

```bash
docker exec prometheus wget -qO- http://node-exporter:9100/metrics | head
# # HELP go_gc_duration_seconds A summary of the pause duration of garbage collection cycles.
# # TYPE go_gc_duration_seconds summary
# go_gc_duration_seconds{quantile="0"} 0.0001234
# ...
```

Si la query falla con `bad address`, es un problema de DNS Docker (el target no existe aún o no está en la red `homelab`); si responde pero la UI muestra `down`, es problema de timeout o de path (`/metrics` vs otro).

### 6) Operación diaria

| Acción | Comando |
|---|---|
| Ver targets up/down | `https://prometheus.lan/targets` |
| Ver la configuración cargada | `https://prometheus.lan/config` (texto plano del YAML efectivo) |
| Ver flags activas | `https://prometheus.lan/flags` |
| Ver runtime info (samples/s, head series, ...) | `https://prometheus.lan/runtimeinfo` |
| Recargar config | `docker kill --signal=SIGHUP prometheus` |
| Reiniciar Prometheus | `docker compose -f stacks/prometheus/docker-compose.yml restart prometheus` |
| Tamaño actual de la TSDB | `du -sh /mnt/hd2t/apps/prometheus/data/` |

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/prometheus/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/prometheus/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/prometheus/prometheus.yml` | microSD | `homelab:homelab` | `0644` | Configuración versionada. |
| `/home/homelab/homelab/stacks/prometheus/rules/` | microSD | `homelab:homelab` | `0755` | Carpeta de reglas (vacía hoy). |
| `/home/homelab/homelab/stacks/caddy/conf.d/02-prometheus.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy. |
| `/mnt/hd2t/apps/prometheus/config/prometheus.yml` | hd2t | `homelab:homelab` | `0644` | Configuración materializada (`:ro` en el contenedor). |
| `/mnt/hd2t/apps/prometheus/config/rules/` | hd2t | `homelab:homelab` | `0755` | Reglas materializadas. |
| `/mnt/hd2t/apps/prometheus/data/` | hd2t | `65534:65534` (`nobody`) | `0750` | TSDB: `wal/`, `chunks_head/`, bloques `01HXY.../`. |
| `/mnt/hd2t/apps/prometheus/data/wal/` | hd2t | `65534:65534` | `0750` | Write-Ahead Log. Comprimido con snappy. |
| `/mnt/hd2t/apps/prometheus/data/queries.active` | hd2t | `65534:65534` | `0640` | Estado de queries en curso (heredado de Prometheus). |

> **Tamaño esperado**. Con los exporters de Fase 5 (Node Exporter + cAdvisor) y ~30 contenedores, la TSDB se estabiliza en torno a **2–4 GiB** después de 30 días. El cap de `--storage.tsdb.retention.size=10GB` queda holgado. Si tras desplegar Fases 6–11 la TSDB se acerca al cap, primero se sospecha de cardinalidad alta (un exporter mal configurado), no del cap; se mira `prometheus_tsdb_head_series` y se identifica el job culpable antes de subir el límite.

> **Por qué no microSD**. La TSDB hace escrituras intensivas (cada 30 s, decenas de KB de WAL) que desgastarían la SD-card. Mantenerla en `hd2t` aprovecha que es un disco con USB 3.0 capaz de absorber ese throughput sin degradación significativa.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/prometheus/docker-compose.yml`, `prometheus.yml`, `.env.example`, `rules/` | Versionados. |
| `stacks/caddy/conf.d/02-prometheus.caddy` | Versionado. |
| Decisiones (retención 30d/10GB, scrape 30s, two_factor en Caddy) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Por qué |
|---|---|---|
| `/mnt/hd2t/apps/prometheus/config/prometheus.yml` | Sí. | Reproducible desde la plantilla, pero respaldarlo evita pérdida de cambios que no se hayan promovido al git (jobs añadidos en una sesión rápida). |
| `/mnt/hd2t/apps/prometheus/config/rules/` | Sí. | Igual: las reglas, cuando existan, son código tan crítico como la propia config. |
| `/mnt/hd2t/apps/prometheus/data/` | **No.** | La TSDB es **regenerable**: tras restore, Prometheus vuelve a hacer scrape y el primer dashboard útil aparece tras unas horas. Respaldar 4 GiB que cambian cada minuto saturaría el repo Borg sin valor real (no hay obligación de auditar 30 días atrás cuando el cluster vuelve de un desastre). |
| `/mnt/hd2t/apps/prometheus/data/wal/` | **No.** | Idem; el WAL es efímero por diseño. |

> **Política explícita: la TSDB no se respalda**. Esta es la decisión más controvertida del documento. Razonamiento:
>
> 1. El histórico de métricas tiene **valor decreciente** con el tiempo: tener métricas de hace 25 días es mucho menos valioso que tener métricas en *tiempo real*.
> 2. El coste de respaldar es alto: snapshot consistente requiere usar `POST /api/v1/admin/tsdb/snapshot` antes de copiar, lo que duplica el espacio durante el snapshot.
> 3. Tras un desastre, el primer instinto operativo es resucitar los servicios; las métricas históricas son útiles para *post-mortem*, no para recuperación. Aceptar perder hasta 30 días de histórico es razonable.
>
> Si en el futuro este criterio cambia (regulación, SLA con un familiar exigente), se reabre con `prometheus_tsdb_snapshot` + Borg.

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/prometheus/docker-compose.yml up -d --force-recreate
# Prometheus reusa /mnt/hd2t/apps/prometheus/data: replay del WAL (~10 s),
# carga de bloques previos y vuelta a la normalidad. Cero pérdida.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear Fase 1, 2, 3 y 4.
2. Restaurar `/mnt/hd2t/apps/prometheus/config/` desde Borg.
3. Recrear el directorio `/mnt/hd2t/apps/prometheus/data/` con `chown 65534:65534`.
4. `docker compose -f stacks/prometheus/docker-compose.yml up -d`.
5. `curl -ksI https://prometheus.lan/-/healthy -o /dev/null -w '%{http_code}\n'` → `200` (tras login Authelia, manualmente desde el navegador, el endpoint sí pide auth).

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| Prometheus no arranca: `permission denied` al escribir en `/prometheus` | El bind mount tiene un owner distinto al UID 65534 que usa la imagen. | `sudo chown -R 65534:65534 /mnt/hd2t/apps/prometheus/data`. |
| `level=error msg="error opening WAL segment"` al arrancar | El proceso anterior se mató abruptamente y el WAL quedó corrupto (raro pero posible tras un OOM). | Mover `/mnt/hd2t/apps/prometheus/data/wal/00000NNN` corrupto fuera y reiniciar; Prometheus recrea el WAL y pierde los últimos minutos de muestras (aceptable). |
| Targets `down` con `dial tcp: lookup XYZ on 127.0.0.11:53: no such host` | El servicio target no existe aún o está en otra red Docker. | Confirmar que el target comparte la red `homelab`: `docker network inspect homelab`. Si aún no se ha desplegado el documento correspondiente (e.g. Node Exporter), el comportamiento es **esperado** hasta que se cierre. |
| Targets `down` con `connection refused` | El servicio existe pero no escucha en el puerto esperado. | `docker exec prometheus wget -qO- http://<target>:<puerto>/metrics`. Si responde, el problema es el path; si no, el target tiene un puerto distinto o no expone `/metrics`. |
| `https://prometheus.lan/` da loop de redirecciones a `auth.lan` | `prometheus.${DOMAIN_LAN}` no está en `access_control.rules` de Authelia. Con `default_policy: deny`, Authelia siempre lo niega. | Añadir el dominio al bloque `two_factor`; recargar Authelia. |
| `https://prometheus.lan/` carga la UI pero los botones (Graph, Targets) generan URLs `http://prometheus:9090/...` que no resuelven | Falta `--web.external-url=https://prometheus.${DOMAIN_LAN}/` en el `command:`. | Añadir la flag, `docker compose up -d`. |
| `du -sh /mnt/hd2t/apps/prometheus/data/` da 12 GiB pese al cap de 10 | El cap aplica solo a bloques persistidos; el head block (en memoria) y el WAL se suman aparte. Habitual durante períodos de alta ingesta. | Comportamiento esperado; Prometheus compacta cada ~2 h y libera espacio. Si crece sin parar, mirar cardinalidad: `topk(10, count by (__name__)({__name__=~".+"}))`. |
| `promtool check config` falla con `parsing YAML: unknown field` | Versión del binario `promtool` distinta a la de la imagen, o flag eliminada en una mayor. | Usar siempre `promtool` desde el mismo tag (`docker run --rm --entrypoint promtool prom/prometheus:v2.55.1 ...`). |
| Tras `SIGHUP`, los logs no muestran "Loading configuration file" | El proceso recibió la señal pero no hubo cambios; Prometheus no logue nada cuando la config es idéntica. | Forzar un cambio trivial (un comentario nuevo, e.g.) y reintentar. |
| Grafana no puede consultar Prometheus (`Bad Gateway` en datasource test) | Grafana intenta `http://prometheus:9090` pero no comparte la red `homelab`. | Confirmar que el stack de Grafana (`02-grafana.md`) referencia `homelab: external: true` y que el contenedor está unido a esa red. |
| TSDB crece muy rápido (>1 GiB/día) | Un exporter genera labels con cardinalidad alta (UUIDs de request, paths exactos con IDs). | `topk(20, count by (job) ({__name__=~".+"}))` para identificar el job; `topk(20, count by (__name__) ({__name__=~".+"}))` para identificar la métrica. Filtrar con `metric_relabel_configs` en el job ofensor. |
| `level=warn msg="Error sending alerts"` en logs | Bloque `alerting:` activo pero Alertmanager no desplegado. | Comentar el bloque (es la decisión por defecto en este documento) o desplegar Alertmanager (reabrible). |
| Reinicio del host: Prometheus arranca pero el WAL replay tarda > 1 min | Normal en homelab cargado: el WAL puede acumular varios MB y la Pi 5 hace replay secuencial. | Esperar; la métrica `prometheus_tsdb_wal_corruptions_total` debe quedarse en 0. Si aumenta, abrir el síntoma del WAL corrupto. |

---

## Decisiones que **no** se toman en este documento

- **Alertmanager**: el bloque `alerting:` está comentado en `prometheus.yml`. Reabrible cuando exista una ruta clara de notificaciones (Telegram bot, email vía Mailrise en Fase 11). Hoy `05-uptime-kuma.md` cubre la necesidad mínima de "avisar si un servicio cae".
- **Recording rules**: agregaciones precalculadas (`job:cpu_seconds:rate5m`, etc.). Sobreingeniería para 5 hosts y unas decenas de series; las queries de Grafana se calculan ad-hoc. Reabrible cuando un dashboard tarde > 5 s en cargar.
- **Alerting rules**: estrechamente ligadas a Alertmanager. Misma decisión.
- **Remote write a un Mimir/VictoriaMetrics/Thanos**: federación o long-term storage externo. El homelab vive en una caja; nada que federar. Reabrible si llega un segundo nodo.
- **Service discovery (Docker SD, DNS SD, file SD)**: Prometheus puede auto-descubrir contenedores Docker leyendo el socket. Más mágico, pero introduce dependencias (acceso a `/var/run/docker.sock` desde el contenedor de Prometheus, lo cual es una brecha enorme). El homelab tiene una decena de exporters fijos: `static_configs` es legible y auditable. Reabrible si llegan a ser cientos.
- **mTLS hacia los exporters**: para 1 host con red Docker compartida, exigir mTLS entre Prometheus y exporters es ceremonia. Reabrible si en el futuro hay scrape entre hosts (multi-Pi).
- **Compactación a S3/MinIO** (Thanos sidecar, Cortex): el homelab no necesita TSDB inmutable a años vista.
- **Prometheus 3.x**: la rama 3 cambió defaults y trajo cardinalidad UTF-8 en labels. Esperar a que Grafana, los exporters principales y los dashboards "Node Exporter Full" hayan migrado. Reabrible cuando Fase 12 cierre.
- **Alertmanager + Slack/Discord/Telegram bot**: subdocumento entero cuando se decida. Hoy el operador es uno y vive en la misma casa que la Pi.
- **Multi-tenant via `external_labels` y selectores en Grafana**: irrelevante con un solo entorno.

---

## Verificación Final

Antes de pasar a `02-grafana.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/prometheus/docker-compose.yml ps` | `prometheus ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect prometheus --format '{{.Config.Image}}'` | `prom/prometheus:v2.55.1` |
| Conectado a `homelab` | `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` | incluye `prometheus` y `caddy` |
| Sin puertos publicados al host | `docker port prometheus` | salida vacía |
| `prometheus.lan` resuelve al IP de la Pi | `dig +short prometheus.lan @192.168.1.2` | `192.168.1.10` |
| Caddy sirve `prometheus.lan` con cert de la CA interna | `echo \| openssl s_client -connect prometheus.lan:443 -servername prometheus.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| Health endpoint responde (interno) | `docker exec prometheus wget -qO- http://127.0.0.1:9090/-/healthy` | `Prometheus Server is Healthy.` |
| Configuración válida | `docker exec prometheus promtool check config /etc/prometheus/prometheus.yml` | `SUCCESS: 0 rule files found` |
| Acceso vía Authelia con TOTP | navegador con CA instalada y sesión TOTP válida | UI carga, query `up` devuelve 1 fila para `prometheus` |
| Targets configurados | `https://prometheus.lan/targets` | `prometheus → up`; los demás `down` (esperado hasta sus docs) |
| TSDB escribiendo en hd2t | `du -sh /mnt/hd2t/apps/prometheus/data/` | tamaño > 0, crece con el tiempo |
| Owner correcto del data dir | `stat -c '%u:%g' /mnt/hd2t/apps/prometheus/data/` | `65534:65534` |
| Recarga en caliente funciona | tras editar y materializar, `docker kill --signal=SIGHUP prometheus`; `docker logs prometheus --tail 5` | `Loading configuration file` + `Completed loading` sin errores |
| Retención aplicada | `https://prometheus.lan/flags` | aparecen `storage.tsdb.retention.time=30d` y `storage.tsdb.retention.size=10GB` |
| Persistencia tras reboot | `sudo reboot`; tras reconectar: `docker ps --filter name=prometheus` | `Up ... (healthy)` sin acción manual |
| Stack en git | `git ls-files stacks/prometheus` | `docker-compose.yml`, `prometheus.yml`, `.env.example`, `rules/` tracked |

Cumplido el último punto, el homelab tiene una base de métricas operativa: un único endpoint en `https://prometheus.lan/` para consultas ad-hoc, una TSDB con horizonte de 30 días viviendo en disco externo y una `prometheus.yml` versionada que actúa como **inventario de qué medir** para el resto de la Fase 5. La siguiente puerta es **darle a esas métricas una cara legible**: `02-grafana.md` añadirá Grafana con Prometheus como datasource y los dashboards canónicos (Node Exporter Full, Docker, temperatura del Pi).

---

## Referencias

- [Documento siguiente: `docs/05-monitorizacion/02-grafana.md`](./02-grafana.md)
- [Documento relacionado: `docs/05-monitorizacion/03-node-exporter.md`](./03-node-exporter.md)
- [Documento relacionado: `docs/05-monitorizacion/04-cadvisor.md`](./04-cadvisor.md)
- [Documento relacionado: `docs/03-red/04-caddy.md`](../03-red/04-caddy.md)
- [Documento relacionado: `docs/04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)
- [Documento relacionado: `docs/02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)
- [Prometheus — Documentación oficial](https://prometheus.io/docs/introduction/overview/)
- [Prometheus — Configuration reference](https://prometheus.io/docs/prometheus/latest/configuration/configuration/)
- [Prometheus — Storage (TSDB, retention)](https://prometheus.io/docs/prometheus/latest/storage/)
- [Prometheus — Command-line flags](https://prometheus.io/docs/prometheus/latest/command-line/prometheus/)
- [Prometheus — Imagen Docker oficial](https://hub.docker.com/r/prom/prometheus)
- [Prometheus — `promtool` (validación de config y reglas)](https://prometheus.io/docs/prometheus/latest/command-line/promtool/)
- [PromQL — Funciones y operadores](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Caddy — Métricas Prometheus (`/metrics` en admin API)](https://caddyserver.com/docs/metrics)
