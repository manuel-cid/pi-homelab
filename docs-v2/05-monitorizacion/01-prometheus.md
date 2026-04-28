# Prometheus

## Descripción

Despliegue de **Prometheus v2** como **base de datos de series temporales (TSDB)** del homelab: scrapea cada 30 s a sí mismo y al puñado de exporters que las fases siguientes irán añadiendo (Node Exporter en [`./03-node-exporter.md`](./03-node-exporter.md), cAdvisor en [`./04-cadvisor.md`](./04-cadvisor.md), `pihole-exporter` en [`../03-red/02-pihole.md`](../03-red/02-pihole.md), Caddy `/metrics`, Watchtower `/v1/metrics`, etc.) y las almacena en `hd2t` con retención acotada por tiempo y por tamaño.

Prometheus inaugura el stack `monitoring` (fila correspondiente en [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §1.1), que en las fases sucesivas se ampliará con Grafana, Node Exporter, cAdvisor, Uptime Kuma y Dozzle. Cada uno de esos docs **añade** su servicio al `docker-compose.yml` del stack y, si exporta métricas, **añade** un `scrape_config` al `prometheus.yml`. Este documento deja:

- el árbol de datos (`/mnt/hd2t/services/monitoring/prometheus/data/`),
- el `prometheus.yml` versionado con un único job activo (el propio Prometheus) y los demás como **placeholders comentados**, cada uno citando al doc que lo activará,
- el `docker-compose.yml` del stack con un solo servicio (`prometheus`) y todo lo necesario para que los siguientes docs lo extiendan sin tocar lo escrito aquí,
- el reverse-proxy en Caddy (`prometheus.${LAN_DOMAIN}`) protegido por Authelia (`forward_auth`),
- la regla de `access_control` correspondiente en Authelia.

> **Alcance de red**: Prometheus **no** publica puertos al host. Su UI sólo es accesible vía `https://prometheus.${LAN_DOMAIN}` (Caddy + Authelia 2FA) y vía Tailscale cuando esa fase se complete. Su API `/api/v1/*` es el datasource que Grafana ([`./02-grafana.md`](./02-grafana.md)) consulta por DNS Docker (`http://prometheus:9090`) **dentro** de la red `homelab`, sin pasar por Caddy.

> **Por qué Prometheus y no otro TSDB**:
>
> 1. **Pull-based, no push.** El agente que tiene métricas (Node Exporter, cAdvisor, exporters de cada servicio) sólo expone un `/metrics` HTTP estático; Prometheus va a buscarlas. Esto evita que cada exporter tenga que conocer al servidor, manejar credenciales, gestionar re-tries o quedarse colgado cuando Prometheus está parado. Para un homelab pequeño y estático, es la complejidad mínima posible.
> 2. **TSDB local sobre disco, sin clúster.** Prometheus 2.x escribe sus bloques en `/prometheus` (un fichero `chunks_*.wal`, bloques inmutables `01XXXXX/`). El binario es **un solo proceso**, sin Zookeeper, etcd, Cassandra ni nada parecido. El homelab no necesita HA: si la Pi cae, las métricas también, y la única consecuencia es un hueco en los gráficos.
> 3. **PromQL como idioma común.** Tanto Grafana ([`./02-grafana.md`](./02-grafana.md)) como Alertmanager (si se activa en el futuro) hablan PromQL nativamente. Importar dashboards de Grafana.com y reglas de alerta `awesome-prometheus-alerts` requiere cero traducción.
> 4. **Coste mínimo en una Pi 5.** Con scrape cada 30 s y ~6 exporters, el TSDB crece en torno a 30–60 MB/día. La retención por defecto del homelab (30 d / 5 GB, lo que se cumpla antes) cabe holgadamente en `hd2t` y mantiene el WAL pequeño en RAM (~30 MB residentes).
> 5. **No se elige VictoriaMetrics / InfluxDB / Mimir** porque cualquiera de ellos resuelve un problema que este homelab no tiene (cardinalidad alta, replicación, multi-tenancy). Prometheus 2.x simple es exactamente la herramienta adecuada al tamaño del problema.

---

## Requisitos Previos

- **Docker Engine + Compose v2** instalados según [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md).
- **Red `homelab`** creada según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2 (`172.20.0.0/24`, bridge `br-homelab`, `external: true`).
- **Caddy desplegado** según [`../03-red/04-caddy.md`](../03-red/04-caddy.md), conectado a `homelab`, con la CA interna funcionando y el `root.crt` confiado en al menos un cliente (§6.5 de Caddy).
- **Pi-hole desplegado** según [`../03-red/02-pihole.md`](../03-red/02-pihole.md), con la posibilidad de añadir registros DNS locales (Local DNS Records) para `prometheus.${LAN_DOMAIN}` apuntando a `192.168.1.10` (la IP del host donde escucha Caddy).
- **Authelia desplegado** según [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md), con el snippet `authelia_proxy` ya disponible en `~/homelab/stacks/proxy/snippets/authelia_proxy` (§9.1 de Authelia).
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No se añaden reglas nuevas: Prometheus no publica puertos al host; el tráfico entra por Caddy (que ya tiene 80/443 abiertos en §6.4 de su doc).
- **Estructura de directorios** de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) en su sitio. El bootstrap original creó `/mnt/hd2t/services/prometheus/` (esquema antiguo "un dir por servicio"); este doc usa el esquema vigente "un dir por stack" (`/mnt/hd2t/services/monitoring/prometheus/`) y muestra cómo migrar.
- **Comprobaciones rápidas**:
  ```bash
  # La red homelab existe:
  docker network inspect homelab --format '{{(index .IPAM.Config 0).Subnet}}'
  # Esperado: 172.20.0.0/24

  # Caddy está sano:
  docker inspect caddy --format '{{.State.Health.Status}}'
  # Esperado: healthy

  # Authelia está sano (Prometheus se servirá detrás de su forward_auth):
  docker inspect authelia --format '{{.State.Health.Status}}'
  # Esperado: healthy

  # Pi-hole resuelve prometheus.lan al host (preparar antes en su UI):
  dig +short @192.168.1.241 prometheus.lan
  # Esperado: 192.168.1.10  (si no, añadir el registro en Pi-hole y volver)
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Imagen Docker | **`prom/prometheus:v2.55.1`** | Imagen oficial multi-arch (incluye `linux/arm64`). v2.55 es la última rama 2.x estable y conserva el comportamiento clásico de PromQL/TSDB. **Prometheus 3.x** introduce cambios incompatibles (UTF-8 en nombres de métricas, `range` por defecto, etc.) que aún no están reflejados en la mayoría de dashboards de Grafana.com; se documenta el upgrade a 3.x como variante futura en §10.5. |
| Tag de imagen | **Pinned a release puntual**, nunca `latest` | Misma regla de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1. La línea 2.x es muy estable, pero un cambio de minor (2.55 → 2.56) puede modificar flags del binario o el formato de bloques del TSDB; el upgrade se hace leyendo el [Migration Guide](https://prometheus.io/docs/prometheus/latest/migration/). |
| Política de Watchtower | **`watchtower.enable: "true"`** | Coherente con [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 (Prometheus está en la lista de incluidos). Los upgrades de patch (2.55.1 → 2.55.2) son seguros: el formato de bloques del TSDB no cambia entre patches. Si en el futuro se cruza un major (2.x → 3.x), se pondrá `enable: "false"` mientras dure la migración. |
| Modo de red | **Sólo `homelab`** (bridge `external`) | Prometheus tiene que **scrapear** exporters que viven en otros stacks (Pi-hole, Caddy, Authelia, Watchtower, Node Exporter, cAdvisor...). Todos cuelgan de `homelab`; lo más simple es estar también ahí y resolver por DNS Docker. **No** se crea una red `monitoring_internal`: Prometheus no tiene una BD/cache propia con la que aislarse, su único backend es el filesystem. Grafana ([`./02-grafana.md`](./02-grafana.md)) seguirá la misma regla: sólo `homelab`. |
| `ports:` publicados al host | **Ninguno** | La UI se sirve **únicamente** vía Caddy (`reverse_proxy http://prometheus:9090`). Publicar `9090` al host duplicaría la entrada y permitiría saltarse Caddy (y, con él, su HTTPS, sus cabeceras de seguridad y la `forward_auth` con Authelia). El datasource que consume Grafana es `http://prometheus:9090` por DNS Docker, sin pasar por la red del host. |
| Acceso a la UI | **Detrás de Authelia** (`forward_auth`, política `two_factor`) | La UI de Prometheus expone PromQL ad-hoc (consultas contra todas las métricas, incluidas las que delatan topología del homelab) y endpoints `/api/v1/admin/*` (con `--web.enable-admin-api` desactivado por defecto, para asegurarlo). Aunque la red sea privada, no hay razón para que un cliente cualquiera de la LAN pueda consultarla sin login. Política `two_factor` consistente con el resto de servicios admin. |
| `--web.enable-admin-api` | **Desactivado** (default del binario) | El admin API permite borrar series, hacer snapshots y desconectar bloques. En un homelab no se usa nada de eso por la UI; los snapshots se hacen vía CLI dentro del contenedor (§9 backup) y el borrado de series no es operación cotidiana. Mantenerlo OFF reduce superficie. |
| `--web.enable-lifecycle` | **Activado** | Habilita los endpoints `POST /-/reload` y `POST /-/quit`, que permiten **recargar** `prometheus.yml` sin reiniciar el contenedor. Crítico porque cada doc de la Fase 5 va a editar `prometheus.yml` y se quiere aplicar los cambios sin perder el WAL ni aceptar segundos de scrape gap. La superficie añadida es mínima: ambos endpoints sólo aceptan `POST` y, **al estar Prometheus accesible sólo a través de Caddy + Authelia**, requieren login con 2FA. Si alguna vez se expusiera al host, este flag debería ir acompañado de bloqueo en Caddy. |
| `--storage.tsdb.retention.time` | **`30d`** | 30 días de histórico cubren el ciclo "ver qué pasó la semana pasada / hace un mes". Más allá, en un homelab personal, no aporta señal (los patrones son cíclicos diarios/semanales). Al combinarse con el límite de tamaño, lo que se cumpla antes corta. |
| `--storage.tsdb.retention.size` | **`5GB`** | Tope duro para no llenar `hd2t` por error si un día se añade un exporter ruidoso (cardinalidad alta) o si se reduce `scrape_interval`. Con 6 exporters a 30 s, el consumo real estará entre 30 y 60 MB/día; 5 GB son ~3 meses de margen. **El primero que se cumpla (tiempo o tamaño) corta**: estructura clásica de "WAL+blocks". |
| `--storage.tsdb.path` | **`/prometheus`** (default de la imagen) | No se cambia: la imagen oficial fija `WORKDIR /prometheus` y declara el `VOLUME` allí. Cambiarlo obligaría a inventar otro path. |
| `--web.external-url` | **`https://prometheus.${LAN_DOMAIN}/`** | Necesario para que la UI genere correctamente los enlaces internos (paginación, "more results", links a `/graph` desde `/alerts`) cuando se sirve detrás de un reverse-proxy. Sin esto, los enlaces apuntarían a `http://prometheus:9090/...`. |
| `--web.route-prefix` | **`/`** (no se usa subpath) | El reverse-proxy de Caddy mapea `prometheus.lan` a la raíz; no se enruta como `homelab.lan/prometheus`. Mantenerlo en `/` es la opción más simple y la que asume la mayoría de dashboards de Grafana.com. |
| `--log.level` | **`info`** | Suficiente para auditoría (scrape errors, target up/down) sin ruido. `debug` se eleva temporalmente cuando algo no scrapea y se devuelve a `info`. |
| `--log.format` | **`logfmt`** (default) | Legible y consumible por Loki/Promtail si se añaden en el futuro. JSON estructurado es útil cuando se centralizan logs; mientras tanto, `docker logs prometheus` se lee mejor en logfmt. |
| `scrape_interval` global | **`30s`** | Compromiso entre granularidad y volumen. 15 s duplica el espacio en disco y casi nunca aporta señal nueva en un homelab. 60 s pierde picos cortos de CPU y temperatura. 30 s es el valor canónico de los dashboards comunes. |
| `scrape_timeout` global | **`10s`** | Suficiente para `/metrics` de cualquier exporter sano en una LAN local; un exporter que tarda más de 10 s indica problema. Debe ser `<` `scrape_interval`. |
| `evaluation_interval` global | **`30s`** | Igual que `scrape_interval`: las reglas de alerting (cuando se añadan) se evalúan al mismo ritmo que las métricas; evitar mismatchs. |
| `external_labels` | **`{cluster: homelab, host: pi5}`** | Se añaden a cada serie cuando se federa o se envía a remote-write. En este homelab no hay federación, pero dejarlas hace que los dashboards multi-cluster (importados de Grafana.com) funcionen sin sorpresas y que un eventual remote-write a un Mimir/Thanos externo identifique el origen. |
| Usuario del contenedor | **`65534:65534`** (`nobody:nogroup`, default de la imagen) | La imagen oficial `prom/prometheus` se construye con `USER nobody`. **No** se sobreescribe con `${PUID}:${PGID}` para no chocar con la política del propio binario. Consecuencia: el directorio `/mnt/hd2t/services/monitoring/prometheus/data/` debe tener owner `65534:65534` (paso explícito en §3.3). El `/etc/prometheus/prometheus.yml` se monta read-only y `nobody` sólo necesita leerlo. |
| `cap_drop: ALL` + `cap_add` mínimo | `cap_drop: [ALL]`, sin `cap_add` | Prometheus bindea a `9090` (>1024), no toca raw sockets ni filesystem privilegiado. Ningún capability necesario. |
| `security_opt` | **`no-new-privileges:true`** | Plantilla §6 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). |
| `read_only` | **`true`** (con `tmpfs:` para `/tmp`) | Prometheus sólo escribe en `/prometheus` (montado RW). El binario y la config en `/etc/prometheus` son RO. RO del FS root reduce superficie ante un compromiso del proceso. |
| Persistencia | Bind mount `/prometheus/` en `/mnt/hd2t/services/monitoring/prometheus/data/` | Contiene `wal/`, bloques `01XXX/`, `chunks_head/`, `lock`. Backup acotado (§9): los bloques son inmutables y se respaldan tal cual; el WAL se prefiere reconstruir tras el `up`. |
| `prometheus.yml` | Bind mount **read-only** desde `~/homelab/stacks/monitoring/prometheus.yml` | Versionado en git. Cada doc de la Fase 5 lo edita y dispara un `POST /-/reload` para aplicar sin downtime. **No** se monta dentro de `/mnt/hd2t/...`: es configuración, no dato. |
| Healthcheck | **`/-/healthy`** vía `wget` busybox de la imagen | El endpoint `/-/healthy` responde 200 cuando el proceso está vivo (binario y HTTP server). `/-/ready` responde 200 cuando además el TSDB y los scrape configs están cargados; se usa `/-/healthy` por ser el más permisivo (Prometheus puede tardar en estar `ready` si replays de WAL son largos). |
| Logs Docker | **`json-file` 10 MB × 3** (heredado del demonio) | Plantilla §6.1 de estructura-compose. Suficiente para tener ~1 día de logs en disco. |

---

## 1. Resumen de la arquitectura

```
                ┌─────────────────────── LAN 192.168.1.0/24 ──────────────────────────┐
                │                                                                     │
   navegador ───┤ https://prometheus.lan ──► Caddy :443                                │
   operador     │   (Pi-hole resuelve a 192.168.1.10)                                  │
                │                                                                     │
                └───────────────────────────────────────┬─────────────────────────────┘
                                                        │  TLS interno
                ┌───────────────────────────────────────▼──────────────────────────────┐
                │  Pi 5 — docker network: homelab (172.20.0.0/24)                       │
                │                                                                       │
                │   ┌──────── caddy ────────┐                                            │
                │   │ prometheus.lan        │                                            │
                │   │  ├─ forward_auth ────►│──► http://authelia:9091 /api/authz/...    │
                │   │  └─ reverse_proxy ───►│──► http://prometheus:9090                  │
                │   └───────────────────────┘                                            │
                │                                                                       │
                │   ┌────── stack: monitoring ────────────────────────────────────────┐ │
                │   │                                                                  │ │
                │   │   ┌─────────────────── prometheus ───────────────────┐          │ │
                │   │   │ image: prom/prometheus:v2.55.1                   │          │ │
                │   │   │ user: 65534:65534 (nobody)                       │          │ │
                │   │   │ networks: [homelab]                              │          │ │
                │   │   │ ports: -                                         │          │ │
                │   │   │ /etc/prometheus/prometheus.yml (RO bind ◄── git) │          │ │
                │   │   │ /prometheus/ (RW bind ◄── /mnt/hd2t/.../data)    │          │ │
                │   │   │ flags: --web.enable-lifecycle                    │          │ │
                │   │   │        --storage.tsdb.retention.time=30d         │          │ │
                │   │   │        --storage.tsdb.retention.size=5GB         │          │ │
                │   │   │        --web.external-url=https://prom.lan/      │          │ │
                │   │   └──────┬───────────────────────────────────────────┘          │ │
                │   │          │ HTTP GET /metrics cada 30s                           │ │
                │   └──────────┼──────────────────────────────────────────────────────┘ │
                │              │                                                        │
                │   ┌──────────▼──────────────────────────────────────────────────────┐ │
                │   │  Targets a scrapear (cada uno se activa en su propio doc):      │ │
                │   │   - prometheus:9090   (self)              [activo aquí]         │ │
                │   │   - node-exporter:9100                    [./03-node-exporter]  │ │
                │   │   - cadvisor:8080                         [./04-cadvisor]       │ │
                │   │   - pihole-exporter:9617                  [../03-red/02-pihole] │ │
                │   │   - caddy:2019/metrics                    [../03-red/04-caddy]  │ │
                │   │   - watchtower:8080/v1/metrics            [../02-docker/04-w]   │ │
                │   └─────────────────────────────────────────────────────────────────┘ │
                └───────────────────────────────────────────────────────────────────────┘
```

Tres invariantes:

- **Prometheus sólo es accesible vía Caddy + Authelia.** No hay `ports:` al host. La UI exige login con 2FA; el datasource que usa Grafana es `http://prometheus:9090` **por DNS Docker dentro de `homelab`**, sin TLS ni autenticación, porque ambos están en la misma red bridge privada.
- **Prometheus va a buscar las métricas, no al revés.** Cada exporter sólo expone `/metrics` HTTP plano. Si Prometheus está apagado, el exporter sigue funcionando y el agujero queda en el TSDB; cuando vuelve, las series continúan sin "rellenar" nada.
- **`prometheus.yml` es la fuente de verdad.** Cada doc de Fase 5 edita ese fichero (añadiendo un `scrape_config`) y dispara `POST /-/reload`. No hay configuración derivada en el contenedor; reproducir el estado en otra máquina es `git clone` + restaurar el bind mount de datos (o no, si se prefiere arrancar limpio).

Flujo de un scrape:

```
1. Prometheus consulta su prometheus.yml: job 'pihole-exporter' / target 'pihole-exporter:9617'.
2. cada 30s: HTTP GET http://pihole-exporter:9617/metrics  (DNS interno de homelab).
3. pihole-exporter responde con líneas tipo:
       pihole_dns_queries_today 12345
       pihole_ads_blocked_today  1234
4. Prometheus parsea, etiqueta con (job, instance, scrape_pool), y escribe al TSDB.
5. Cada 2h, Prometheus compacta el WAL en un block inmutable bajo /prometheus/01XXXXX/.
6. Si el bloque más antiguo supera 30d o 5GB, lo borra (retention).
7. Grafana, en el siguiente refresh de su panel, ejecuta PromQL contra http://prometheus:9090/api/v1/query_range.
```

---

## 2. Plan de variables y archivos

El stack `monitoring` es nuevo. Layout que se va a crear en este doc (los siguientes docs de Fase 5 lo extenderán):

```
~/homelab/stacks/monitoring/             # versionable en git
├── docker-compose.yml                   # se EXTIENDE en docs siguientes (grafana, node-exporter, ...)
├── .env.example
└── prometheus.yml                       # se EDITA en docs siguientes (añadir scrape_configs)

/mnt/hd2t/services/monitoring/           # datos persistentes, NO en git
├── .env                                  # variables (chmod 600)
└── prometheus/
    └── data/                             # /prometheus del contenedor (TSDB)
        ├── wal/
        ├── chunks_head/
        ├── 01XXXXX/                      # bloques inmutables
        └── lock
```

> **Nota sobre la convención**: el stack se llama `monitoring`, no `prometheus`. Igual que `auth` agrupa Authelia + Redis ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §2), el stack `monitoring` agrupará Prometheus, Grafana, Node Exporter, cAdvisor, Uptime Kuma y Dozzle. Cada uno tiene su `container_name` propio (`prometheus`, `grafana`, ...) para que el DNS interno y los `target` de scrape sean estables.

### 2.1. Variables del stack (`.env.example` versionable)

`~/homelab/stacks/monitoring/.env.example`:

```dotenv
# ~/homelab/stacks/monitoring/.env.example
# Versión control: ~/homelab/stacks/monitoring/.env.example
# Valores reales en /mnt/hd2t/services/monitoring/.env (chmod 600).

# --- Comunes del homelab ---
PUID=1000
PGID=1000
TZ=Europe/Madrid

# --- Dominios internos (consistentes con dns/.env, proxy/.env, auth/.env) ---
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Prometheus ---
# https://hub.docker.com/r/prom/prometheus/tags
# ¡Leer https://prometheus.io/docs/prometheus/latest/migration/ antes de cambiar de major!
PROMETHEUS_IMAGE_TAG=v2.55.1

# Hostname público de la UI (sin esquema). El reverse-proxy de Caddy lo termina.
PROMETHEUS_HOSTNAME=prometheus.lan

# Retención del TSDB (lo que se cumpla antes corta).
PROMETHEUS_RETENTION_TIME=30d
PROMETHEUS_RETENTION_SIZE=5GB

# (Reservado para los siguientes docs de Fase 5; se rellenarán cuando toquen)
# GRAFANA_IMAGE_TAG=
# NODE_EXPORTER_IMAGE_TAG=
# CADVISOR_IMAGE_TAG=
# UPTIME_KUMA_IMAGE_TAG=
# DOZZLE_IMAGE_TAG=
```

### 2.2. `.env` real (`/mnt/hd2t/services/monitoring/.env`)

```bash
sudo install -m 600 -o homelab -g homelab /dev/null /mnt/hd2t/services/monitoring/.env

cat > /mnt/hd2t/services/monitoring/.env <<'EOF'
PUID=1000
PGID=1000
TZ=Europe/Madrid

LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

PROMETHEUS_IMAGE_TAG=v2.55.1
PROMETHEUS_HOSTNAME=prometheus.lan
PROMETHEUS_RETENTION_TIME=30d
PROMETHEUS_RETENTION_SIZE=5GB
EOF

ls -l /mnt/hd2t/services/monitoring/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

---

## 3. Preparar el árbol de datos

### 3.1. Crear el directorio del stack

```bash
mkdir -p ~/homelab/stacks/monitoring
```

### 3.2. Crear el árbol de datos persistentes

```bash
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/monitoring
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/monitoring/prometheus
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/monitoring/prometheus/data
```

> **Migración desde `/mnt/hd2t/services/prometheus/`** (esquema antiguo "un dir por servicio" creado por el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)):
> ```bash
> sudo rmdir /mnt/hd2t/services/prometheus 2>/dev/null || true
> ```
> En un homelab nuevo no hay datos previos. Si los hubiese (un Prometheus instalado a mano antes de seguir el plan), mover los contenidos a la ruta nueva (`/mnt/hd2t/services/monitoring/prometheus/data/`) **antes** de recrear el contenedor; el TSDB es un directorio plano y el binario lo encuentra mientras el path `--storage.tsdb.path` apunte a él.

### 3.3. Permisos para el proceso del contenedor

La imagen oficial `prom/prometheus` se construye con `USER nobody` (UID `65534`, GID `65534` en la imagen). Al primer arranque, el binario crea ficheros `lock`, `wal/`, `chunks_head/`, etc., en `/prometheus`. Si el directorio del host no es escribible por `65534:65534`, Prometheus aborta con `permission denied`.

```bash
# Ajustar la propiedad del directorio de datos al UID/GID que la imagen usa.
sudo chown -R 65534:65534 /mnt/hd2t/services/monitoring/prometheus/data
sudo chmod 750            /mnt/hd2t/services/monitoring/prometheus/data
```

> Tras este paso, `ls -l /mnt/hd2t/services/monitoring/prometheus/` mostrará el subdirectorio `data/` con propietario `65534:65534`. Es lo esperado. Borgmatic, que corre como `root`, lo respaldará igual; el operador, si necesita inspeccionarlo desde el host, usa `sudo`. **No** se añade el usuario `homelab` al grupo `nogroup` (UID/GID 65534 son convencionales para "nadie" y no deberían heredarlos otros procesos).

> Compatibilidad con Borgmatic: Borg respeta UID/GID en el archivo, así que la restauración recreará los ficheros como `65534:65534` y Prometheus los podrá leer al arrancar.

---

## 4. `prometheus.yml`

`~/homelab/stacks/monitoring/prometheus.yml` — **versionado en git**:

```yaml
# ~/homelab/stacks/monitoring/prometheus.yml
# Versionado en git. Editar este fichero y aplicar con:
#   curl -sf -X POST http://prometheus:9090/-/reload   (desde dentro de homelab)
#   docker exec prometheus killall -HUP prometheus     (alternativa SIGHUP)
#
# Documentación: https://prometheus.io/docs/prometheus/latest/configuration/configuration/

# ----- Globales -----
global:
  # Cada cuánto se hace pull a cada target. Compromiso entre granularidad y
  # volumen del TSDB; ver tabla de decisiones en docs/05-monitorizacion/01-prometheus.md.
  scrape_interval:     30s
  scrape_timeout:      10s
  # Cada cuánto se evalúan reglas (alerting/recording). Igual al scrape_interval
  # para no introducir mismatches; cuando se activen reglas, esto sigue valiendo.
  evaluation_interval: 30s

  # Etiquetas que se añaden a cada serie cuando se federa o se envía a remote-write.
  # En este homelab no hay federación, pero dejarlas hace que los dashboards
  # importados de grafana.com (Node Exporter Full, etc.) sigan funcionando sin
  # tener que parchearlos.
  external_labels:
    cluster: homelab
    host:    pi5

# ----- Reglas (vacío por ahora; se documentan en una variante futura) -----
# rule_files:
#   - /etc/prometheus/rules/*.yml

# ----- Alertmanager (vacío por ahora) -----
# alerting:
#   alertmanagers:
#     - static_configs:
#         - targets: ['alertmanager:9093']

# ============================================================================
#  scrape_configs
# ============================================================================
#
#  Cada job_name es estable en el tiempo (no se renombra al cambiar el target);
#  es la dimensión `job` que aparece en todas las métricas y a la que se hace
#  match desde Grafana.
#
#  Convenciones del homelab:
#   - Un único `job_name` por exporter, no uno por instancia.
#   - `targets:` con la forma `<container_name>:<puerto>` — DNS interno de la
#     red `homelab`, no IPs ni nombres FQDN.
#   - Etiquetas `service` en `labels:` (legibles, alineadas con el campo
#     `homepage.name`) para que los paneles de Grafana las usen en leyendas.
#
# ============================================================================

scrape_configs:

  # ----- Self-scrape: Prometheus a sí mismo -----------------------------------
  # Activado en este doc. Aporta métricas internas (TSDB, scrape duration, WAL,
  # contadores de series, etc.) que sirven para diagnosticar el propio Prometheus.
  - job_name: 'prometheus'
    static_configs:
      - targets: ['prometheus:9090']
        labels:
          service: prometheus

  # ----- Caddy admin /metrics (../03-red/04-caddy.md) -------------------------
  # Caddy expone /metrics en su admin API (puerto 2019). El admin API está
  # bindeado a localhost del contenedor; Prometheus, al estar en la misma red
  # `homelab`, lo alcanza por DNS interno `caddy:2019`.
  # ACTIVAR cuando el doc de Caddy añada el scrape (sección de monitorización
  # en ../03-red/04-caddy.md, fila "Prometheus").
  #
  # - job_name: 'caddy'
  #   metrics_path: /metrics
  #   static_configs:
  #     - targets: ['caddy:2019']
  #       labels:
  #         service: caddy

  # ----- Pi-hole (pihole-exporter, ../03-red/02-pihole.md) --------------------
  # Pi-hole no expone /metrics nativamente; se despliega `bigmessman/pihole-exporter`
  # en el mismo stack `dns`. ACTIVAR cuando ../03-red/02-pihole.md añada ese
  # contenedor a su docker-compose.
  #
  # - job_name: 'pihole'
  #   static_configs:
  #     - targets: ['pihole-exporter:9617']
  #       labels:
  #         service: pihole

  # ----- Watchtower (../02-docker/04-watchtower.md) ---------------------------
  # Watchtower expone métricas (count de actualizaciones, fallos, scans) en
  # /v1/metrics, requiere un token Bearer fijado por env. ACTIVAR cuando el
  # doc de Watchtower habilite WATCHTOWER_HTTP_API_METRICS=true y se cree el
  # secret `watchtower_http_api_token` en /mnt/hd2t/services/infra/secrets/.
  #
  # - job_name: 'watchtower'
  #   metrics_path: /v1/metrics
  #   bearer_token_file: /etc/prometheus/secrets/watchtower_http_api_token
  #   static_configs:
  #     - targets: ['watchtower:8080']
  #       labels:
  #         service: watchtower

  # ----- Node Exporter (./03-node-exporter.md) --------------------------------
  # Métricas del host (CPU, RAM, disco, red, temperatura). ACTIVAR cuando el
  # doc Node Exporter despliegue el contenedor `node-exporter` en el stack.
  #
  # - job_name: 'node-exporter'
  #   static_configs:
  #     - targets: ['node-exporter:9100']
  #       labels:
  #         service: node-exporter

  # ----- cAdvisor (./04-cadvisor.md) ------------------------------------------
  # Métricas por contenedor Docker (CPU, RAM, IO, network) — complementarias a
  # node-exporter (que ve "el host", no contenedores). ACTIVAR cuando el doc
  # cAdvisor despliegue el contenedor `cadvisor` en el stack.
  #
  # - job_name: 'cadvisor'
  #   metrics_path: /metrics
  #   static_configs:
  #     - targets: ['cadvisor:8080']
  #       labels:
  #         service: cadvisor

  # ----- Uptime Kuma (./05-uptime-kuma.md) ------------------------------------
  # Uptime Kuma 1.23+ expone /metrics protegido por basic_auth con el API key
  # del propio panel. ACTIVAR cuando el doc Uptime Kuma cree la API key y
  # almacene el secret en /etc/prometheus/secrets/uptime_kuma_api_key.
  #
  # - job_name: 'uptime-kuma'
  #   metrics_path: /metrics
  #   basic_auth:
  #     username: ''
  #     password_file: /etc/prometheus/secrets/uptime_kuma_api_key
  #   static_configs:
  #     - targets: ['uptime-kuma:3001']
  #       labels:
  #         service: uptime-kuma
```

### 4.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `global.scrape_interval: 30s` | Justificado en la tabla de decisiones. Los exporters siguientes podrán **bajarlo** en su propio job (ej. `node-exporter` a 15 s para temperatura) usando el campo `scrape_interval:` dentro del `scrape_config`, que sobreescribe al global. |
| `global.scrape_timeout: 10s` | Margen amplio. En un homelab pequeño los exporters responden en milisegundos; un timeout de 10 s sólo se alcanza si el exporter está colgado. |
| `external_labels.cluster: homelab` | Identifica este Prometheus en un eventual remote-write futuro (Mimir, Grafana Cloud) o en federación; mientras tanto, las series llevan la etiqueta y los dashboards multi-cluster siguen funcionando. |
| `external_labels.host: pi5` | El homelab es de un solo host. Si en el futuro se añade otro nodo (NAS, otra Pi), `host` se convierte en discriminante natural. |
| `rule_files:` comentado | Las reglas de alerting/recording se documentan en una variante futura (sección de "Alertas" no incluida en Fase 5 inicial). Dejarlo comentado deja la receta lista para activar cuando se quiera. |
| `alerting.alertmanagers:` comentado | Igual: Alertmanager se desplegará en una sub-fase futura si se quiere notificación push (Telegram, etc.); mientras tanto, las alertas de Uptime Kuma cubren el mínimo. |
| `scrape_configs[0]` (self) | Dotación mínima para que Prometheus tenga métricas que mostrar nada más arrancar. Los siguientes docs activarán los demás. |
| Resto de `scrape_configs` comentados con doc-link | Cada placeholder cita el documento del servicio que lo activará. Mismo patrón que el `Caddyfile` ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.3). |
| `metrics_path` solo cuando ≠ `/metrics` | Por defecto Prometheus consulta `/metrics`; sólo se declara explícitamente cuando el exporter usa otro path (ej. `caddy` lo expone en `/metrics` también, así que técnicamente se podría omitir, pero se deja explícito por claridad). |
| `bearer_token_file` / `password_file` | Patrón "secreto en fichero": Prometheus lee el contenido del fichero en cada scrape. Permite rotar la clave sin reiniciar Prometheus (el fichero se reabre por scrape). |

---

## 5. `docker-compose.yml`

`~/homelab/stacks/monitoring/docker-compose.yml`:

```yaml
# ~/homelab/stacks/monitoring/docker-compose.yml
# Stack: monitoring (../02-docker/02-estructura-compose.md §1.1).
#
# En este doc se introduce SOLO el servicio `prometheus`. Los siguientes docs
# de la Fase 5 (./02-grafana.md, ./03-node-exporter.md, ./04-cadvisor.md,
# ./05-uptime-kuma.md, ./06-dozzle.md) AÑADEN su servicio a este mismo fichero,
# sin tocar el bloque `prometheus:` ni el bloque `networks:`.

name: monitoring

services:
  prometheus:
    image: prom/prometheus:${PROMETHEUS_IMAGE_TAG}
    container_name: prometheus
    hostname: prometheus
    restart: unless-stopped

    # Imagen oficial: USER nobody (UID 65534). NO sobreescribir con ${PUID}:${PGID}
    # para no desviar de la convención del proyecto upstream; en su lugar, el
    # directorio bind-mounteado /mnt/hd2t/services/monitoring/prometheus/data
    # se hace propiedad de 65534:65534 en docs/05-monitorizacion/01-prometheus.md §3.3.

    env_file:
      - /mnt/hd2t/services/monitoring/.env
    environment:
      TZ: ${TZ}
      LAN_DOMAIN: ${LAN_DOMAIN}

    command:
      # Configuración + datos.
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"

      # Retención (lo que se cumpla antes corta).
      - "--storage.tsdb.retention.time=${PROMETHEUS_RETENTION_TIME}"
      - "--storage.tsdb.retention.size=${PROMETHEUS_RETENTION_SIZE}"

      # Servir detrás del reverse-proxy de Caddy:
      - "--web.external-url=https://${PROMETHEUS_HOSTNAME}/"
      - "--web.route-prefix=/"

      # Permitir POST /-/reload y POST /-/quit (cf. tabla de decisiones).
      - "--web.enable-lifecycle"

      # Listening por defecto: 0.0.0.0:9090. No se cambia.
      # --web.enable-admin-api: NO se activa (default off).

      # Logs.
      - "--log.level=info"
      - "--log.format=logfmt"

    volumes:
      # Configuración versionable, read-only.
      - type: bind
        source: ./prometheus.yml
        target: /etc/prometheus/prometheus.yml
        read_only: true
        bind:
          create_host_path: false

      # Directorio de secretos para futuros scrapes con bearer/basic auth.
      # Se crea cuando el primer doc lo necesite (Watchtower /v1/metrics,
      # Uptime Kuma /metrics). Mientras esté vacío, no estorba.
      # - type: bind
      #   source: /mnt/hd2t/services/monitoring/prometheus/secrets
      #   target: /etc/prometheus/secrets
      #   read_only: true
      #   bind:
      #     create_host_path: false

      # TSDB persistente.
      - type: bind
        source: /mnt/hd2t/services/monitoring/prometheus/data
        target: /prometheus
        bind:
          create_host_path: false

    tmpfs:
      - /tmp:size=16m,mode=1700,uid=65534,gid=65534

    read_only: true

    networks:
      - homelab

    cap_drop:
      - ALL

    security_opt:
      - no-new-privileges:true

    healthcheck:
      # /-/healthy responde 200 si el proceso está vivo.
      # /-/ready exige además que el TSDB esté cargado; menos permisivo.
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:9090/-/healthy"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s

    labels:
      com.centurylinklabs.watchtower.enable: "true"
      homepage.group: "Monitorización"
      homepage.name: "Prometheus"
      homepage.icon: "prometheus.png"
      homepage.href: "https://prometheus.${LAN_DOMAIN}"
      homepage.description: "Métricas del homelab (TSDB)"

networks:
  homelab:
    external: true
```

### 5.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `name: monitoring` | Coincide con el directorio del stack y con la fila §1.1 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). |
| `image: prom/prometheus:${PROMETHEUS_IMAGE_TAG}` | Tag fijo desde el `.env`. Multi-arch oficial (incluye `linux/arm64`). |
| `container_name: prometheus` / `hostname: prometheus` | Caddy llama a `http://prometheus:9090` por nombre Docker; los siguientes exporters apuntarán también por este nombre. Sin `container_name` el nombre real sería `monitoring-prometheus-1`. |
| (sin `user:`) | La imagen oficial fija `USER nobody` (UID 65534) y el binario no respeta una sobreescritura limpia: si se fuerza `user: "1000:1000"` el contenedor arranca pero los ficheros `wal/` quedan con propiedad mixta tras restores. La convención upstream es respetar `nobody` y ajustar la propiedad del bind mount al UID 65534, hecho en §3.3. |
| `env_file` ruta absoluta | Plantilla §6 de estructura-compose. No depende del CWD. |
| `command` con flags explícitos | Cada flag tiene una decisión justificada en la tabla §0 y comentarios inline en el bloque `command:`. **No** se delega al `entrypoint` de la imagen los defaults: dejar los flags visibles documenta el contrato del servicio. |
| `volumes:` `prometheus.yml` RO | Versionable en git; cualquier cambio en el fichero se aplica con un `POST /-/reload` (§9). RO impide que un proceso comprometido dentro del contenedor sobreescriba la config. |
| `volumes:` `/prometheus` RW (bind) | TSDB. Bind mount (no named volume) para que Borg lo respalde por path predecible. |
| `volumes:` `secrets/` RO comentado | Reservado para los siguientes docs (Watchtower bearer token, Uptime Kuma API key). Dejarlo comentado evita un fallo `bind: source ... no such file` si el directorio aún no existe. Cada doc futuro descomentará el bloque y creará el subdirectorio en `/mnt/hd2t/services/monitoring/prometheus/secrets/`. |
| `tmpfs: /tmp` con `uid=65534,gid=65534` | Necesario porque el FS root es `read_only`. Prometheus escribe lock temporales en `/tmp` durante scrape; 16 MiB sobran. UID/GID coinciden con el proceso para que pueda escribir. |
| `read_only: true` | Refuerza la postura: el binario no puede escribir fuera de `/prometheus` (writable bind), `/tmp` (tmpfs) y, en el futuro, `/etc/prometheus/secrets` (RO). |
| `networks: [homelab]` | Único networking necesario. Para resolver `prometheus`, `caddy`, `pihole-exporter`, etc., todos en el mismo bridge. |
| `cap_drop: ALL` (sin `cap_add`) | Prometheus no necesita capabilities especiales. |
| `security_opt: no-new-privileges:true` | Plantilla §6. |
| `healthcheck: /-/healthy` | El binario en la imagen oficial ya incluye `wget` busybox (la imagen es scratch + binarios estáticos en realidad — lleva `wget`). 60 s de `start_period` por si el WAL es grande tras un crash y el replay tarda. |
| `labels.watchtower.enable=true` | Justificado en la tabla §0. Los upgrades de patch son seguros entre 2.x.y → 2.x.z; cuando llegue el cruce a 3.x se cambia a `false` mientras dure la migración. |
| `labels.homepage.*` | Auto-descubrimiento por Homepage ([`../12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md)). El `href` apunta al portal HTTPS, no al puerto interno. |

### 5.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env config >/dev/null \
  && echo "Compose OK"

# Validar prometheus.yml con el binario oficial sin desplegar:
docker run --rm \
  -v $(pwd)/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
  prom/prometheus:v2.55.1 \
  promtool check config /etc/prometheus/prometheus.yml
# Esperado:
#   Checking /etc/prometheus/prometheus.yml
#     SUCCESS: 1 rule files found
#   ... (no warnings)
```

> `promtool check config` verifica sintaxis, regex de relabeling, formato de `external_labels` y referencias cruzadas (`rule_files`). Si pasa, el `up -d` no fallará por la config.

---

## 6. Despliegue

### 6.1. Levantar el stack

```bash
cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d
```

Salida esperada:

```
[+] Running 1/1
 ✔ Container prometheus  Started
```

> **No se crea ninguna red interna**: el stack `monitoring` sólo usa `homelab` (external). Los siguientes docs que añadan servicios al mismo `docker-compose.yml` heredarán esta decisión.

### 6.2. Estado del contenedor

```bash
docker compose ps
# Esperado:
# NAME         IMAGE                       STATUS                  PORTS
# prometheus   prom/prometheus:v2.55.1     Up X (healthy)
```

Si tarda en `(healthy)` o entra en `(unhealthy)`:

```bash
docker compose logs prometheus | tail -50
```

Eventos esperados en los logs:

```
ts=... caller=main.go:... level=info msg="Starting Prometheus Server" version="(version=2.55.1, ...)"
ts=... caller=main.go:... level=info msg="Server is ready to receive web requests."
ts=... caller=manager.go:... level=info component="rule manager" msg="Starting rule manager..."
ts=... caller=head.go:... level=info component=tsdb msg="Replaying WAL, this may take a while"
ts=... caller=head.go:... level=info component=tsdb msg="WAL replay completed" duration=5.123ms
```

### 6.3. Smoke test desde la red `homelab`

```bash
# Caddy alcanza Prometheus por nombre Docker:
docker exec caddy wget -qO- http://prometheus:9090/-/healthy
# Esperado: Prometheus Server is Healthy.

docker exec caddy wget -qO- http://prometheus:9090/-/ready
# Esperado: Prometheus Server is Ready.

# El self-scrape ya funciona:
docker exec caddy wget -qO- 'http://prometheus:9090/api/v1/query?query=up' \
  | python3 -m json.tool | head -20
# Esperado: respuesta JSON con un único resultado, value=1, labels job="prometheus"
```

### 6.4. Smoke test desde el host

```bash
# Prometheus NO debe ser alcanzable desde la IP del host:
curl -sf http://192.168.1.10:9090/-/healthy -m 2 ; echo "exit=$?"
# Esperado: exit=7 (connection refused) o exit=28 (timeout). Nunca 200.

docker port prometheus
# Esperado: vacío (sin port mappings).
```

---

## 7. Integración con Caddy (`reverse_proxy` + `forward_auth`)

### 7.1. Añadir el bloque `prometheus.lan` al `Caddyfile`

Editar `~/homelab/stacks/proxy/Caddyfile` y añadir, en la sección de bloques de host, **debajo** de los placeholders existentes:

```caddy
# Prometheus (../05-monitorizacion/01-prometheus.md)
prometheus.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    import authelia_proxy
    reverse_proxy http://prometheus:9090
}
```

Razones:

- **`import authelia_proxy`** aplica el `forward_auth` definido en [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §9.1: cualquier petición sin sesión válida se redirige a `https://auth.lan/?rd=...` con login + 2FA, y la respuesta se reenvía a Prometheus con cabeceras `Remote-User`/`Remote-Groups`/`Remote-Email`/`Remote-Name` (Prometheus las ignora; eso está bien).
- **No se reescribe `Host`** ni `X-Forwarded-Proto`: Prometheus no genera URLs absolutas dependientes de esos headers en el flujo normal de la UI; el `--web.external-url` ya le ha dicho cuál es su URL pública.
- **No se añade `transport http { tls }`**: la conexión Caddy → Prometheus es HTTP plano dentro de `homelab` (red bridge privada).

### 7.2. Recargar Caddy sin downtime

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Si la sintaxis del `Caddyfile` está mal, el comando devuelve no-cero y la config previa sigue activa (Caddy es atómico). En ese caso:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
# Imprime exactamente qué línea/regla está mal.
```

### 7.3. Añadir la regla en Authelia (`access_control.rules`)

Editar `~/homelab/stacks/auth/configuration.yml` (sección `access_control.rules`, ya documentada en [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §5) y **añadir** `prometheus.lan` a la lista de servicios protegidos por 2FA:

```yaml
access_control:
  default_policy: deny
  rules:
    # ... reglas existentes ...

    # Servicios protegidos por 2FA (ampliado).
    - domain:
        - "portainer.{{ env "LAN_DOMAIN" }}"
        - "vault.{{ env "LAN_DOMAIN" }}"
        - "nextcloud.{{ env "LAN_DOMAIN" }}"
        - "sonarr.{{ env "LAN_DOMAIN" }}"
        - "radarr.{{ env "LAN_DOMAIN" }}"
        - "prowlarr.{{ env "LAN_DOMAIN" }}"
        - "transmission.{{ env "LAN_DOMAIN" }}"
        - "bookstack.{{ env "LAN_DOMAIN" }}"
        - "paperless.{{ env "LAN_DOMAIN" }}"
        - "homepage.{{ env "LAN_DOMAIN" }}"
        - "ha.{{ env "LAN_DOMAIN" }}"
        - "prometheus.{{ env "LAN_DOMAIN" }}"   # <── nuevo
      policy: two_factor
      subject:
        - "group:admin"
```

Recargar Authelia (su `configuration.yml` no soporta `watch:`):

```bash
docker compose -f ~/homelab/stacks/auth/docker-compose.yml restart authelia
```

### 7.4. Añadir el registro DNS local en Pi-hole

Pi-hole UI → **Local DNS** → **DNS Records** → añadir:

```
prometheus.lan → 192.168.1.10
```

Reload del DNS interno:

```bash
docker exec pihole pihole reloaddns
```

Verificar:

```bash
dig +short @192.168.1.241 prometheus.lan
# Esperado: 192.168.1.10
```

### 7.5. Probar desde el navegador

Desde un cliente con `root.crt` instalado (§6.5 de [`../03-red/04-caddy.md`](../03-red/04-caddy.md)):

```
https://prometheus.lan
```

- Primera carga (sin sesión): redirección a `https://auth.lan/?rd=https%3A%2F%2Fprometheus.lan%2F`.
- Login + TOTP en Authelia.
- Redirección de vuelta: la UI de Prometheus carga (esquema gris/naranja, menú "Status / Graph / Alerts").
- El gráfico `up` debe devolver un único resultado (la propia instancia `prometheus:9090`) con valor `1`.

---

## 8. Verificación

### 8.1. Contenedor sano

```bash
docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml ps
# STATUS: "Up X (healthy)".
```

### 8.2. Prometheus escucha sólo en redes Docker

```bash
sudo ss -ltn | awk '$4 ~ /:9090$/'
# Esperado: vacío (no se publica al host).

docker port prometheus
# Esperado: vacío.
```

### 8.3. Endpoints `/-/healthy` y `/-/ready` vía Caddy

```bash
docker exec caddy wget -qO- http://prometheus:9090/-/healthy
# Esperado: Prometheus Server is Healthy.

docker exec caddy wget -qO- http://prometheus:9090/-/ready
# Esperado: Prometheus Server is Ready.
```

### 8.4. Cert hoja firmado por la CA interna

```bash
echo | openssl s_client -connect prometheus.lan:443 -servername prometheus.lan 2>/dev/null \
  | openssl x509 -noout -issuer -subject
# Esperado:
#   issuer=  CN = Caddy Local Authority - 2024 ECC Intermediate
#   subject= CN = prometheus.lan
```

### 8.5. Forward-auth deniega sin sesión

```bash
# Llamar a la UI sin cookie (con --insecure para no validar la CA local desde curl):
curl -isk https://prometheus.lan/ | head -3
# Esperado: HTTP/2 302 con Location: https://auth.lan/?rd=...
```

### 8.6. El self-scrape funciona

Tras login en la UI:

```
https://prometheus.lan/targets
```

Esperado: una única fila para el job `prometheus`, target `prometheus:9090`, estado **UP** (verde), `Last Scrape` reciente, `Scrape Duration` < 50 ms.

```
https://prometheus.lan/graph
```

Probar la query `up`:

```
up
```

Esperado: una única serie con valor `1` y etiquetas:

```
up{cluster="homelab", host="pi5", instance="prometheus:9090", job="prometheus", service="prometheus"} = 1
```

### 8.7. La retención está aplicada

Tras al menos 1 hora de funcionamiento:

```bash
docker exec prometheus du -sh /prometheus
# Esperado: del orden de pocos MB (sólo TSDB de la propia instancia).

docker exec prometheus ls -la /prometheus/wal | head
# Esperado: ficheros 00000000.tmp y similares; el WAL está activo.
```

```bash
# Confirmar los flags de retención en el proceso:
docker exec prometheus sh -c 'cat /proc/1/cmdline | tr "\0" "\n" | grep -E "retention|external-url"'
# Esperado:
#   --storage.tsdb.retention.time=30d
#   --storage.tsdb.retention.size=5GB
#   --web.external-url=https://prometheus.lan/
```

### 8.8. Persistencia tras reboot

```bash
sudo reboot
# (esperar a que vuelva)

docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml ps
# Esperado: prometheus (healthy).

# La serie temporal del self-scrape no tiene gap (más allá del propio reboot):
# en la UI, query `up{job="prometheus"}[1h]` debe mostrar continuidad antes y
# después del reboot, con un hueco del tamaño del downtime.
```

### 8.9. `POST /-/reload` aplica cambios sin downtime

Para validar el flujo que usarán los siguientes docs:

```bash
# 1. Hacer un cambio inocuo en prometheus.yml (subir scrape_timeout a 11s):
sed -i 's/scrape_timeout: .*/scrape_timeout:      11s/' ~/homelab/stacks/monitoring/prometheus.yml

# 2. Reload:
docker exec caddy wget -q --post-data='' -O- http://prometheus:9090/-/reload
# Esperado: salida vacía y exit code 0.

# 3. Confirmar el cambio:
docker exec caddy wget -qO- http://prometheus:9090/api/v1/status/config \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["yaml"])' \
  | grep scrape_timeout
# Esperado: scrape_timeout: 11s

# 4. Revertir el cambio y volver a recargar:
sed -i 's/scrape_timeout: .*/scrape_timeout:      10s/' ~/homelab/stacks/monitoring/prometheus.yml
docker exec caddy wget -q --post-data='' -O- http://prometheus:9090/-/reload
```

### 8.10. Lista de Verificación

Antes de pasar a [`./02-grafana.md`](./02-grafana.md):

- [ ] `docker compose ps` en el stack `monitoring` → `prometheus (healthy)`.
- [ ] `sudo ss -ltn | grep -E ':9090'` → vacío en el host.
- [ ] `https://prometheus.lan` redirige a `auth.lan` para login + TOTP.
- [ ] Tras login, la UI carga y `https://prometheus.lan/targets` muestra el job `prometheus` en estado **UP**.
- [ ] `up{job="prometheus"}` devuelve `1` con las etiquetas `cluster=homelab, host=pi5, service=prometheus`.
- [ ] `docker exec prometheus sh -c 'cat /proc/1/cmdline | tr "\0" "\n" | grep retention'` muestra las dos retenciones (`time=30d`, `size=5GB`).
- [ ] `~/homelab/stacks/monitoring/{prometheus.yml,docker-compose.yml,.env.example}` versionados en git; **`.env` NO**.
- [ ] El bloque `prometheus.lan` está en `~/homelab/stacks/proxy/Caddyfile` y `prometheus.{{ env "LAN_DOMAIN" }}` en `access_control.rules` de Authelia.
- [ ] Pi-hole tiene el registro local `prometheus.lan → 192.168.1.10`.
- [ ] `POST /-/reload` aplica un cambio en `prometheus.yml` sin reiniciar el contenedor (§8.9).
- [ ] Tras `sudo reboot`, el contenedor arranca y la UI sigue funcionando.

---

## 9. Backup

Estrategia que se concretará en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md). Lo que **debe respaldarse** del stack `monitoring` (parte Prometheus):

| Ruta | Qué contiene | Frecuencia |
|---|---|---|
| `~/homelab/stacks/monitoring/prometheus.yml` | Configuración de scrape jobs, reglas, etc. | Versionado en git → `git push`. |
| `~/homelab/stacks/monitoring/docker-compose.yml` y `.env.example` | Definición del stack. | Idem versionado. |
| `/mnt/hd2t/services/monitoring/.env` | Variables del stack. No contiene secretos. | Reconstruible desde `.env.example`. Opcional. |
| `/mnt/hd2t/services/monitoring/prometheus/data/` | TSDB completo (bloques `01XXX/`, WAL, `chunks_head/`). | **Opcional**, no crítico. |

> **Por qué el TSDB es opcional**: las métricas no son datos de usuario (no hay nada irrecuperable en ellas). Si se pierden, la única consecuencia es que los gráficos arrancan vacíos y "engordan" durante los siguientes 30 días hasta llenar la retención. La compresión de Prometheus es alta (ratio típico 1–2 bytes/sample), así que respaldarlo es barato (5 GB max), pero no se prioriza.

### 9.1. Snapshot consistente del TSDB (opcional, recomendado antes de upgrades)

Prometheus expone el endpoint `POST /api/v1/admin/tsdb/snapshot`, **pero** requiere `--web.enable-admin-api` (deshabilitado por defecto en este homelab). Alternativa segura sin reactivar el admin API: aprovechar la atomicidad del `compaction` de Prometheus 2.x — los bloques bajo `/prometheus/01XXX/` son **inmutables** una vez escritos. Un `cp -a` durante el funcionamiento normal es seguro **excepto** para el WAL (que sí se está escribiendo). Procedimiento:

```bash
# 1. Hacer un dump del WAL al disco (forzar compaction):
docker exec prometheus sh -c 'kill -USR1 1' || true
# (señal SIGUSR1 — Prometheus no la documenta como "force compact" en 2.x; 
#  alternativa simple: parar el contenedor 30s).

# 2. Parar el contenedor 30s (forma más sencilla):
docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml stop prometheus

# 3. Snapshot:
sudo cp -a /mnt/hd2t/services/monitoring/prometheus/data \
           /mnt/hd2t/backups/dumps/prometheus-$(date +%F)
sudo chown -R root:root /mnt/hd2t/backups/dumps/prometheus-$(date +%F)

# 4. Reiniciar:
docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml start prometheus
```

> Para Borgmatic, lo más simple es **respaldar el directorio en caliente**: la asimetría de WAL implica que el último ~2 h de datos puede quedar inconsistente en el archivo, pero al restaurar Prometheus repara el WAL automáticamente al arrancar (pierde lo posterior al último `chunks_head` consistente). En la práctica, esos 2 h de gap son irrelevantes.

### 9.2. Restore tras pérdida total

```bash
# 1. Reinstalar OS, Docker y red 'homelab' (Fases 0-2.2).
# 2. Restaurar repo de stacks desde git remote.
git clone <remote> ~/homelab

# 3. Restaurar /mnt/hd2t/services/monitoring/.env desde Borg (o reconstruir
#    desde .env.example). NO contiene secretos críticos.
borg extract <repo>::<archivo> mnt/hd2t/services/monitoring/.env

# 4. (Opcional) Restaurar el TSDB:
borg extract <repo>::<archivo> mnt/hd2t/services/monitoring/prometheus/data
sudo chown -R 65534:65534 /mnt/hd2t/services/monitoring/prometheus/data

# 5. Levantar el stack:
cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d

# 6. Confirmar:
docker compose ps
docker logs prometheus | tail
# Esperado: "WAL replay completed" y "Server is ready..." en los primeros 10s.
```

---

## 10. Operaciones cotidianas

### 10.1. Añadir un nuevo `scrape_config`

Cada doc de la Fase 5 que añada un exporter debe:

1. **Editar** `~/homelab/stacks/monitoring/prometheus.yml`: descomentar (o añadir) su bloque `- job_name:`.
2. **Validar** la sintaxis:
   ```bash
   docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
   ```
3. **Aplicar** sin downtime:
   ```bash
   docker exec caddy wget -q --post-data='' -O- http://prometheus:9090/-/reload
   # Alternativa fuera de la red homelab (desde el host, vía Caddy + Authelia,
   # con un cliente autenticado): curl -X POST https://prometheus.lan/-/reload
   ```
4. **Comprobar** en `https://prometheus.lan/targets`: el nuevo target aparece y, en pocos segundos, pasa a **UP**.

> Si el nuevo target no aparece tras `/-/reload`, mirar los logs:
> ```bash
> docker logs prometheus | tail -30
> ```
> Errores comunes: indentación YAML errónea, regex de relabel inválida, target con FQDN no resoluble.

### 10.2. Borrar series por error (o por ruido)

El admin API está **desactivado** en este homelab (cf. tabla §0), pero PromQL por sí solo no borra: simplemente no muestra. Para limpiar series antiguas tras un cambio de exporter (típico: una métrica renombrada, su nombre antiguo persiste hasta que pase la retención):

- **Esperar a la retención**: la opción de menos esfuerzo. Con 30d de `retention.time`, en 30 días desaparece.
- **Reactivar admin API temporalmente**: añadir `--web.enable-admin-api` al `command:`, recrear el contenedor con `up -d --force-recreate prometheus`, ejecutar `POST /api/v1/admin/tsdb/delete_series?match[]=...`, quitar el flag, recrear de nuevo. Documentado por completitud; rara vez hace falta.

### 10.3. Bajar el nivel de log a `debug` para troubleshooting

```bash
# En ~/homelab/stacks/monitoring/docker-compose.yml, cambiar:
#   - "--log.level=info"
# por:
#   - "--log.level=debug"

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate prometheus

# Tras diagnosticar:
# Volver a "--log.level=info" y --force-recreate prometheus.
```

> `debug` produce mucha salida (cada scrape, cada evaluación de regla); usarlo sólo para una investigación puntual y volver a `info`.

### 10.4. Cambiar la retención

Subir tiempo o tamaño:

```bash
# Editar /mnt/hd2t/services/monitoring/.env:
sudo -u homelab sed -i 's|^PROMETHEUS_RETENTION_TIME=.*|PROMETHEUS_RETENTION_TIME=60d|' \
  /mnt/hd2t/services/monitoring/.env
sudo -u homelab sed -i 's|^PROMETHEUS_RETENTION_SIZE=.*|PROMETHEUS_RETENTION_SIZE=10GB|' \
  /mnt/hd2t/services/monitoring/.env

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate prometheus
```

> Bajar la retención borra bloques antiguos al siguiente compactor pass (~2 h). Subirla **no** rellena bloques borrados; sólo aplica a partir del momento del cambio.

### 10.5. Upgrade manual (rama 2.x)

```bash
# Antes de cambiar el tag, leer:
# https://prometheus.io/docs/prometheus/latest/migration/

sudo -u homelab sed -i 's|^PROMETHEUS_IMAGE_TAG=.*|PROMETHEUS_IMAGE_TAG=v2.55.2|' \
  /mnt/hd2t/services/monitoring/.env

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env pull prometheus
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate prometheus

# Verificar:
docker exec prometheus prometheus --version
docker logs prometheus | tail -30
```

> Watchtower **sí** actualiza Prometheus automáticamente a las 04:00 si el `tag` lleva una nueva digest publicada (los upgrades de patch 2.x.y → 2.x.z son seguros). El upgrade **manual** sólo hace falta para cambios de minor (2.55 → 2.56) o major (2.x → 3.x).

### 10.6. Upgrade a Prometheus 3.x (variante futura)

Cuando se decida cruzar a 3.x:

1. Leer la guía oficial: https://prometheus.io/docs/prometheus/latest/migration/.
2. Cambios incompatibles principales:
   - `range` por defecto en algunas funciones PromQL (puede romper queries antiguas).
   - UTF-8 en nombres de métricas (no aplica al homelab si los exporters siguen usando ASCII).
   - Cambios en flags de la línea de comandos (revisar `--enable-feature=...` legacy).
3. Hacer snapshot del TSDB (§9.1).
4. Poner `watchtower.enable=false` mientras dura la migración.
5. Cambiar el tag a `v3.x.y`, `up -d --force-recreate prometheus`, validar dashboards de Grafana, ajustar PromQL roto.
6. Re-activar Watchtower si todo funciona.

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `docker compose up prometheus` falla con `network homelab declared as external, but could not be found` | La red `homelab` no está creada. | Crearla según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2. |
| `prometheus` arranca pero entra en `(unhealthy)`; logs muestran `opening storage failed: ... permission denied: /prometheus` | El bind mount de datos no es escribible por UID 65534. | `sudo chown -R 65534:65534 /mnt/hd2t/services/monitoring/prometheus/data && sudo chmod 750 /mnt/hd2t/services/monitoring/prometheus/data` (§3.3). |
| `prometheus` falla con `FAILED, parse error: ... line N` al arrancar | `prometheus.yml` tiene YAML inválido o un campo desconocido. | Validar con `docker run --rm -v $PWD/prometheus.yml:/cfg.yml prom/prometheus:v2.55.1 promtool check config /cfg.yml` (§5.2). |
| `https://prometheus.lan` da 502 Bad Gateway desde Caddy | Prometheus no está sano o no resuelve por nombre desde Caddy. | `docker exec caddy wget -qO- http://prometheus:9090/-/healthy`; si falla, `docker inspect prometheus --format '{{json .NetworkSettings.Networks}}'` debe listar `homelab`. |
| `https://prometheus.lan` resuelve pero da `connection refused` | Pi-hole no tiene el registro local o devuelve la IP equivocada. | `dig +short @192.168.1.241 prometheus.lan` debe ser `192.168.1.10`. Reaplicar §7.4. |
| `https://prometheus.lan` redirige a `auth.lan` y, tras login, vuelve a redirigir | Authelia no tiene `prometheus.lan` en `access_control.rules` con política `two_factor` (queda en `default_policy: deny`) **o** la cookie `*.lan` no se está estableciendo. | Confirmar §7.3; revisar `docker logs authelia | grep prometheus` para ver el path evaluado y la regla aplicada. |
| `/targets` muestra el self-scrape como **DOWN** con `connection refused` | Prometheus está intentando alcanzarse a sí mismo por una IP equivocada (típico tras renombrar el contenedor). | Confirmar `container_name: prometheus` y que el target sea `prometheus:9090` (no `localhost:9090`, que dentro del contenedor es 127.0.0.1 y no expone HTTP en sí). |
| `/targets` muestra "context deadline exceeded" | El exporter scrapeado tarda más que `scrape_timeout`. | Subir el `scrape_timeout` del job concreto, o investigar por qué el exporter es lento (cardinalidad, IO bloqueante). |
| `du -sh /mnt/hd2t/services/monitoring/prometheus/data` crece sin parar pasados los 30 días | La retención no se está aplicando. | `docker exec prometheus sh -c 'cat /proc/1/cmdline | tr "\0" "\n" | grep retention'` debe mostrar los dos flags. Si no, revisar el `command:` del Compose y `--force-recreate` el contenedor. |
| `POST /-/reload` devuelve `Lifecycle API is not enabled` | Falta el flag `--web.enable-lifecycle`. | Añadirlo en el `command:` del `docker-compose.yml` y recrear (§5.1). |
| El bloque `prometheus` aparece en `docker compose ps` pero el contenedor reinicia en bucle, los logs muestran `level=error msg="opening storage failed" err="lock acquired by another process"` | Otro contenedor `prometheus` (de un experimento anterior) sigue corriendo y tiene el lock del directorio. | `docker ps -a | grep prometheus`, parar/borrar el sobrante, recrear. |
| Tras restaurar desde Borg, el primer arranque tarda minutos en `(healthy)` | Replay del WAL es largo cuando el TSDB está fragmentado o el `chunks_head/` quedó grande. | Esperar; en los logs aparecerá `WAL replay completed`. Subir `start_period` del healthcheck a `300s` si pasa de 5 min. |
| Caddy `reverse_proxy http://prometheus:9090` funciona pero la UI muestra los enlaces internos como `http://prometheus:9090/...` (rotos) | `--web.external-url` no está aplicado. | `docker exec prometheus sh -c 'cat /proc/1/cmdline | tr "\0" "\n" | grep external-url'` debe devolver `https://prometheus.lan/`. Si está vacío, falta el flag o `${PROMETHEUS_HOSTNAME}` no se interpoló (revisar `.env`). |
| `up{job="prometheus"}` devuelve `0` (target DOWN) tras un upgrade | El healthcheck del nuevo binario rechaza el path (cambio de minor que mueve `/-/healthy`). | Comprobar la versión: `docker exec prometheus prometheus --version`. Las rutas `/-/healthy` y `/-/ready` son estables desde 2.0; si fallan, revisar `--web.route-prefix` (debe ser `/`). |
| El TSDB ocupa más de 5 GB | La retención por tamaño aún no ha pasado por su próximo compaction (son periódicos, no continuos), o el flag `--storage.tsdb.retention.size` está mal escrito (sin unidad). | `docker exec prometheus sh -c 'cat /proc/1/cmdline | tr "\0" "\n" | grep retention.size'` debe terminar en una unidad (`MB`/`GB`). Esperar 2 h al siguiente compaction, o forzar uno reiniciando el contenedor (no recomendado: el WAL se trunca). |

---

## Referencias

- [Prometheus — Documentación oficial](https://prometheus.io/docs/introduction/overview/)
- [Prometheus — Guía de configuración (`prometheus.yml`)](https://prometheus.io/docs/prometheus/latest/configuration/configuration/)
- [Prometheus — Almacenamiento (TSDB, retención, WAL, bloques)](https://prometheus.io/docs/prometheus/latest/storage/)
- [Prometheus — `promtool` (validate, check, query, debug)](https://prometheus.io/docs/prometheus/latest/command-line/promtool/)
- [Prometheus — Endpoints HTTP (`/-/healthy`, `/-/ready`, `/-/reload`)](https://prometheus.io/docs/prometheus/latest/management_api/)
- [Prometheus — Retención (`--storage.tsdb.retention.time`, `--storage.tsdb.retention.size`)](https://prometheus.io/docs/prometheus/latest/storage/#operational-aspects)
- [Prometheus — Migration guide entre versiones](https://prometheus.io/docs/prometheus/latest/migration/)
- [Prometheus — Querying básics (PromQL)](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Prometheus — Imagen Docker oficial (Docker Hub)](https://hub.docker.com/r/prom/prometheus)
- [Prometheus — Source y CHANGES (GitHub)](https://github.com/prometheus/prometheus)
- [Caddy — `reverse_proxy` y `forward_auth`](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [Awesome Prometheus alerts (catálogo de reglas)](https://samber.github.io/awesome-prometheus-alerts/)
