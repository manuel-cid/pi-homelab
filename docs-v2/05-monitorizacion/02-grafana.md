# Grafana

## Descripción

Despliegue de **Grafana OSS** como **única UI de visualización del homelab**: lee series temporales de Prometheus ([`./01-prometheus.md`](./01-prometheus.md)) por DNS Docker (`http://prometheus:9090`) dentro de la red `homelab` y las pinta en dashboards. En este doc se le añade el **datasource Prometheus** vía provisioning YAML, se carga un dashboard inicial de "salud del propio Prometheus" para tener algo que mirar el día 1, y se deja el árbol de provisioning preparado para que los siguientes docs de la Fase 5 ([`./03-node-exporter.md`](./03-node-exporter.md), [`./04-cadvisor.md`](./04-cadvisor.md), [`./05-uptime-kuma.md`](./05-uptime-kuma.md)) **dejen caer** sus dashboards JSON sin tocar la configuración escrita aquí.

Grafana es el segundo servicio del stack `monitoring` (fila §1.1 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)). Este documento **extiende** el `~/homelab/stacks/monitoring/docker-compose.yml` que dejó Prometheus, **no** crea un compose nuevo. Tras este doc, el stack tiene dos servicios (`prometheus`, `grafana`); los siguientes docs añaden el resto.

> **Alcance de red**: Grafana **no** publica puertos al host. Su UI sólo es accesible vía `https://grafana.${LAN_DOMAIN}` (Caddy + Authelia 2FA) y, cuando esa fase se complete, vía Tailscale. La conexión a Prometheus es HTTP plano por DNS interno (`http://prometheus:9090`), sin TLS ni autenticación, porque ambos comparten la red bridge privada `homelab` y el endpoint del datasource sólo lo consume Grafana.

> **Por qué Grafana y no otra UI** (Chronograf, Perses, dashboards nativos de Prometheus, etc.):
>
> 1. **Estándar de facto para PromQL.** Casi todos los dashboards públicos del ecosistema Prometheus se distribuyen en formato Grafana (Grafana.com, GitHub de cada exporter). Importar `Node Exporter Full` o `cAdvisor` es cuestión de pegar un ID; replicarlo en otra herramienta requeriría reescribir cientos de paneles. Para un homelab pequeño, esto es imbatible.
> 2. **Provisioning declarativo en YAML.** Datasources, dashboard providers y dashboards JSON se pueden montar como ficheros read-only desde git. La UI sigue funcionando para experimentar (crear dashboards "ad-hoc"), pero la **fuente de verdad** es el repo. Cuando se restaura desde Borg, basta con `git clone` + `up -d` para volver al estado conocido.
> 3. **Integración con `forward_auth` + `auth.proxy`.** Authelia pone `Remote-User`/`Remote-Groups`/`Remote-Email`/`Remote-Name` en cada request; Grafana sabe leer esas cabeceras nativamente (`auth.proxy.enabled`) y crea/actualiza el usuario en su BD interna sin que el operador tenga que duplicar credenciales. SSO real con 0 configuración adicional. Esto evita el OIDC client de Grafana (también soportado, pero overkill cuando ya hay forward_auth).
> 4. **OSS, sin enterprise lock-in.** La imagen `grafana/grafana-oss` es Apache 2.0, multi-arch (incluye `linux/arm64`), y no tiene ningún feature que dependa de Grafana Cloud. Las únicas funcionalidades enterprise (data source permissions granulares, reporting PDF, white labeling) no se usan en un homelab personal.
> 5. **Coste mínimo en una Pi 5.** El proceso reposa la mayor parte del tiempo (~40 MB RAM, <1% CPU). Sólo carga al renderizar dashboards complejos (Node Exporter Full carga ~80 paneles a la vez); en esos picos sube a ~150 MB RAM y unos segundos de CPU. Cabe holgado.
> 6. **No se elige Perses / Chronograf / Kibana** porque cualquiera de ellos resuelve un problema que este homelab no tiene (UI más ligera, ecosistema InfluxDB/Elastic, multi-tenancy avanzado). Grafana OSS es exactamente la herramienta adecuada al tamaño del problema.

---

## Requisitos Previos

- **Prometheus desplegado y sano** según [`./01-prometheus.md`](./01-prometheus.md): `docker inspect prometheus --format '{{.State.Health.Status}}'` debe devolver `healthy`. La query `up{job="prometheus"}` debe devolver `1` desde la UI de Prometheus.
- **Stack `monitoring` ya inicializado**: `~/homelab/stacks/monitoring/{docker-compose.yml,prometheus.yml,.env.example}` versionados en git, `/mnt/hd2t/services/monitoring/.env` con las variables comunes (PUID, PGID, TZ, LAN_DOMAIN, TS_DOMAIN, PROMETHEUS_*).
- **Red `homelab`** creada según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2.
- **Caddy desplegado** según [`../03-red/04-caddy.md`](../03-red/04-caddy.md), con la CA interna funcionando y `root.crt` ya confiado en al menos un cliente.
- **Authelia desplegado** según [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md), con el snippet `authelia_proxy` ya disponible en `~/homelab/stacks/proxy/snippets/authelia_proxy` (§9.1 de Authelia). El snippet **debe** estar configurado para reenviar las cabeceras `Remote-User`, `Remote-Groups`, `Remote-Email`, `Remote-Name` (es el comportamiento por defecto del snippet de §9.1; aquí se aprovecha por primera vez).
- **Pi-hole con Local DNS** ([`../03-red/02-pihole.md`](../03-red/02-pihole.md)) para añadir `grafana.${LAN_DOMAIN}` apuntando a `192.168.1.10` (la IP del host donde escucha Caddy).
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No se añaden reglas: Grafana no publica puertos al host; el tráfico entra por Caddy.
- **Estructura de directorios** del stack `monitoring` ya en su sitio (`/mnt/hd2t/services/monitoring/` creado por [`./01-prometheus.md`](./01-prometheus.md) §3.2).
- **Comprobaciones rápidas**:
  ```bash
  # Prometheus está sano y accesible desde la red homelab:
  docker inspect prometheus --format '{{.State.Health.Status}}'
  # Esperado: healthy
  docker exec caddy wget -qO- http://prometheus:9090/-/ready
  # Esperado: Prometheus Server is Ready.

  # Authelia está sano (Grafana se servirá detrás de su forward_auth):
  docker inspect authelia --format '{{.State.Health.Status}}'
  # Esperado: healthy

  # Caddy está sano:
  docker inspect caddy --format '{{.State.Health.Status}}'
  # Esperado: healthy

  # El stack monitoring tiene un solo servicio (prometheus) por ahora:
  docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml ps --services
  # Esperado: prometheus
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Imagen Docker | **`grafana/grafana-oss:11.4.0`** | Imagen oficial OSS multi-arch (incluye `linux/arm64`). La rama 11.x es la actual estable y conserva la API de provisioning v1 que usa este doc. La variante `-oss` excluye los binarios enterprise (~ahorra 40 MB) y deja claro que no se usa Grafana Enterprise. Se evita `grafana/grafana:latest`: es un alias móvil que mezcla OSS y enterprise según versión. |
| Tag de imagen | **Pinned a release puntual**, nunca `latest` | Misma regla de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1. Grafana ha tenido cambios incompatibles entre minors (ej. la migración a Angular eliminado, cambios en el formato de dashboards JSON). Los upgrades se hacen leyendo el [What's New](https://grafana.com/docs/grafana/latest/whatsnew/) de cada minor. |
| Política de Watchtower | **`watchtower.enable: "true"`** | Coherente con [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 (todo lo no listado se actualiza). Los upgrades de patch (11.4.0 → 11.4.1) son seguros: no migran el schema de la BD interna. Si en el futuro se cruza un minor (11.4 → 11.5) se revisa antes de subir el tag. |
| Modo de red | **Sólo `homelab`** (bridge `external`) | Grafana sólo necesita hablar con el datasource (Prometheus, vía `prometheus:9090`) y recibir tráfico de Caddy. No tiene una BD/cache externa con la que aislarse en una red `monitoring_internal`: usa SQLite local. Misma decisión que Prometheus en [`./01-prometheus.md`](./01-prometheus.md). |
| `ports:` publicados al host | **Ninguno** | La UI se sirve **únicamente** vía Caddy (`reverse_proxy http://grafana:3000`). Publicar `3000` al host duplicaría la entrada y permitiría saltarse Caddy (y, con él, su HTTPS, sus cabeceras de seguridad y la `forward_auth` con Authelia). Misma postura que Prometheus. |
| Acceso a la UI | **Detrás de Authelia** (`forward_auth`, política `two_factor`) **+ `auth.proxy` en Grafana** | Doble integración: Caddy bloquea cualquier petición sin sesión Authelia válida (forward_auth → 302 a `auth.lan`); cuando la petición pasa, Caddy reenvía las cabeceras `Remote-User`/`Remote-Groups`/`Remote-Email`/`Remote-Name`; Grafana las consume con `auth.proxy.enabled=true` y crea/actualiza el usuario en su BD interna sin pedir login propio. Resultado: SSO real, sin doble autenticación, sin contraseñas duplicadas. |
| `auth.proxy.whitelist` | **`172.20.0.0/24`** (CIDR de la red `homelab`) | El `auth.proxy` de Grafana exige que la conexión venga de una IP permitida; si no, ignora las cabeceras y exige login local. Caddy se conecta a Grafana desde su IP en `homelab` (asignada por el bridge); restringir al CIDR completo es lo más simple y robusto frente a reasignaciones. **No** se usa `0.0.0.0/0` (eso convertiría las cabeceras en una superficie de spoofing si algún día se publica el puerto). |
| `auth.disable_login_form` | **`true`** | Una vez activado `auth.proxy`, el formulario local de login (`/login`) deja de tener sentido. Mantenerlo abierto sería una segunda puerta (con la BD `admin/admin` por defecto a menos que se rote la contraseña) que sólo confunde. La emergencia (Authelia caído) se resuelve poniendo `auth.disable_login_form=false` temporalmente y entrando con el admin local; documentado en §12.5. |
| `auth.basic.enabled` / `auth.anonymous.enabled` | **`false` / `false`** | Igual razonamiento: el único path de auth normal es `auth.proxy`. La API de Grafana también funciona vía service accounts (`auth.api.enabled` por defecto), suficiente para automatización futura. |
| Usuario de admin local (`admin` / `${GRAFANA_ADMIN_PASSWORD}`) | **Generado aleatorio**, sólo de emergencia | El usuario `admin` lo necesita Grafana para inicializar la BD (creación de organización por defecto, etc.); no hay forma de no tenerlo. Se rota la contraseña en el primer arranque (var `GF_SECURITY_ADMIN_PASSWORD`) a un valor aleatorio guardado en `/mnt/hd2t/services/monitoring/.env` (chmod 600). En operación normal, no se usa. |
| Base de datos | **SQLite** (default) en `/var/lib/grafana/grafana.db` | Para un homelab de un solo usuario y ~10 dashboards, SQLite es suficiente y elimina toda dependencia externa. **No** se despliega MariaDB/PostgreSQL: cada migración añade un punto de fallo y el beneficio (concurrencia, backups en caliente) no aplica aquí. Borgmatic respalda el fichero `.db` igual que cualquier otro (§11). |
| Provisioning de datasources | **YAML versionado** en `~/homelab/stacks/monitoring/grafana/provisioning/datasources/` | Patrón canónico de Grafana 5+. Permite que el datasource Prometheus exista desde el primer arranque, sin pasos manuales por la UI. La UI puede crear datasources "ad-hoc" (no provisioned), pero los importantes están en git. |
| Provisioning de dashboards | **YAML provider + JSONs en `dashboards/`** | El "provider" YAML apunta a una carpeta dentro del contenedor (`/etc/grafana/provisioning/dashboards/json/`); Grafana relee esa carpeta en intervalos cortos (`updateIntervalSeconds: 30`) y carga/recarga cualquier `.json` que aparezca. Los siguientes docs de la Fase 5 (`./03-node-exporter.md`, `./04-cadvisor.md`...) **sólo añaden ficheros JSON** — sin tocar `grafana.ini`, `datasources.yml` ni `docker-compose.yml`. |
| Dashboard inicial | **`prometheus-stats.json`** (Grafana.com #3662, "Prometheus 2.0 Stats") | Único exporter activo el día 1 es el self-scrape de Prometheus. Importar este dashboard ofrece visibilidad inmediata sobre TSDB, scrape duration, WAL, ratio de scrapes fallidos. Cuando se añadan los demás exporters, sus docs traerán sus dashboards (`Node Exporter Full` #1860, `cAdvisor` #14282, etc.). |
| `editors_can_admin` / permisos por defecto | Roles default de Grafana (`Viewer`/`Editor`/`Admin`); el usuario `admin` (sólo emergencia) es `Admin`. Los usuarios creados por `auth.proxy` heredan rol `Editor`. | Para un homelab personal, el operador es siempre el mismo usuario; `Editor` permite crear dashboards "throwaway" en la UI sin tocar el provisioning. Si en el futuro hay segundo usuario "lectura solamente", se ajusta `auth.proxy.auto_sign_up_role=Viewer`. |
| `analytics.reporting_enabled` / `analytics.check_for_updates` | **`false` / `false`** | Telemetría a Grafana Labs y "hay nueva versión" en la home. En un homelab con Watchtower gestionando upgrades, ninguno de los dos aporta. |
| `security.cookie_secure` | **`true`** | La cookie de sesión sólo viaja vía HTTPS. Caddy siempre sirve `grafana.lan` por HTTPS; el header `X-Forwarded-Proto: https` lo confirma. |
| `security.cookie_samesite` | **`lax`** | Default de Grafana. Compatible con redirects desde Authelia. |
| `security.allow_embedding` | **`false`** | Se mantiene por defecto. El homelab no usa Grafana embebido en otra UI; permitir embedding (`true`) habilitaría clickjacking. Si en el futuro se quiere embeder paneles en Homepage, se cambia a `true` y se restringe `Content-Security-Policy` desde Caddy. |
| `server.root_url` | **`https://grafana.${LAN_DOMAIN}/`** | Idéntico razonamiento que `--web.external-url` en Prometheus: necesario para que los enlaces que Grafana genera (export PDF, share panel, links a dashboards) apunten a la URL pública en lugar de `http://grafana:3000/`. |
| `server.serve_from_sub_path` | **`false`** | Caddy mapea `grafana.lan` a la raíz, no como `homelab.lan/grafana`. Más simple; idéntica decisión que Prometheus (`--web.route-prefix=/`). |
| `log.mode` / `log.level` | **`console` / `info`** | `console` envía a stdout/stderr y de ahí a `docker logs grafana` (json-file driver). `info` es suficiente para auditoría (logins, cambios de config) sin ruido. `debug` se sube temporalmente para troubleshooting (§12.4). |
| Plugins | **Ninguno** instalado | Grafana OSS trae los datasources y panels imprescindibles (Prometheus, Loki, table, timeseries, gauge...). Se evita instalar plugins en el primer despliegue para no añadir un paso `grafana-cli plugins install` en el arranque. Si en el futuro se quieren plugins (ej. `marcusolsson-json-datasource`), se documenta en una variante. |
| Usuario del contenedor | **`472:472`** (`grafana:grafana`, default de la imagen) | La imagen oficial se construye con `USER 472`. **No** se sobreescribe con `${PUID}:${PGID}`. Consecuencia: el directorio `/mnt/hd2t/services/monitoring/grafana/data/` debe tener owner `472:472` (paso explícito en §3.3). El árbol de provisioning, montado read-only, sólo necesita ser legible por todos. |
| `cap_drop: ALL` + `cap_add` mínimo | `cap_drop: [ALL]`, sin `cap_add` | Grafana bindea a `3000` (>1024), no toca raw sockets ni filesystem privilegiado. Ningún capability necesario. |
| `security_opt` | **`no-new-privileges:true`** | Plantilla §6 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md). |
| `read_only` | **`true`** (con `tmpfs:` para `/tmp`) | Grafana sólo escribe en `/var/lib/grafana` (montado RW: BD, sesiones, plugins descargados) y `/tmp`. El binario (`/usr/share/grafana/`), la config en `/etc/grafana/` y el provisioning son RO. RO del FS root reduce superficie ante un compromiso del proceso. |
| Persistencia | Bind mount `/var/lib/grafana/` en `/mnt/hd2t/services/monitoring/grafana/data/` | Contiene `grafana.db` (SQLite con dashboards "ad-hoc", usuarios, sesiones, anotaciones, favoritos), `plugins/` (descargados), `png/` (imágenes renderizadas). Backup: el `.db` es el único fichero crítico; el resto se regenera. |
| `grafana.ini` | Bind mount **read-only** desde `~/homelab/stacks/monitoring/grafana/grafana.ini` | Versionado en git. Cualquier cambio se aplica con `up -d --force-recreate grafana` (Grafana **no** soporta `SIGHUP`/reload de `grafana.ini` en caliente; los cambios de provisioning sí, ver §12.1). |
| Healthcheck | **`/api/health`** vía `wget` busybox | El endpoint `/api/health` (sin auth) responde 200 con JSON `{"database":"ok","version":"...","commit":"..."}` cuando el proceso está vivo y la BD es accesible. `start_period` 60s por si el primer arranque tiene que correr migraciones de schema (típico tras upgrade). |
| Logs Docker | **`json-file` 10 MB × 3** (heredado del demonio) | Plantilla §6.1 de estructura-compose. ~1 día de logs en disco. |

---

## 1. Resumen de la arquitectura

```
                ┌─────────────────────── LAN 192.168.1.0/24 ──────────────────────────┐
                │                                                                     │
   navegador ───┤ https://grafana.lan ──► Caddy :443                                   │
   operador     │   (Pi-hole resuelve a 192.168.1.10)                                  │
                │                                                                     │
                └───────────────────────────────────────┬─────────────────────────────┘
                                                        │  TLS interno
                ┌───────────────────────────────────────▼──────────────────────────────┐
                │  Pi 5 — docker network: homelab (172.20.0.0/24)                       │
                │                                                                       │
                │   ┌──────── caddy ────────┐                                            │
                │   │ grafana.lan           │                                            │
                │   │  ├─ forward_auth ────►│──► http://authelia:9091 /api/authz/...    │
                │   │  └─ reverse_proxy ───►│──► http://grafana:3000                     │
                │   │     + headers:        │                                            │
                │   │       Remote-User     │                                            │
                │   │       Remote-Groups   │                                            │
                │   │       Remote-Email    │                                            │
                │   │       Remote-Name     │                                            │
                │   └───────────────────────┘                                            │
                │                                                                       │
                │   ┌────── stack: monitoring ────────────────────────────────────────┐ │
                │   │                                                                  │ │
                │   │   ┌──────────────── grafana ─────────────────────────┐          │ │
                │   │   │ image: grafana/grafana-oss:11.4.0                │          │ │
                │   │   │ user: 472:472 (grafana)                          │          │ │
                │   │   │ networks: [homelab]                              │          │ │
                │   │   │ ports: -                                         │          │ │
                │   │   │ /etc/grafana/grafana.ini (RO bind ◄── git)        │          │ │
                │   │   │ /etc/grafana/provisioning/ (RO bind ◄── git)      │          │ │
                │   │   │   ├── datasources/prometheus.yml                  │          │ │
                │   │   │   ├── dashboards/default.yml                      │          │ │
                │   │   │   └── dashboards/json/                            │          │ │
                │   │   │       └── prometheus-stats.json                   │          │ │
                │   │   │ /var/lib/grafana/ (RW bind ◄── /mnt/hd2t/.../data)│          │ │
                │   │   │   └── grafana.db (SQLite)                          │          │ │
                │   │   │ env: GF_AUTH_PROXY_ENABLED=true                    │          │ │
                │   │   │      GF_AUTH_PROXY_HEADER_NAME=Remote-User         │          │ │
                │   │   │      GF_SERVER_ROOT_URL=https://grafana.lan/       │          │ │
                │   │   └──────┬───────────────────────────────────────────┘          │ │
                │   │          │ HTTP GET /api/v1/query_range                          │ │
                │   │          │           /api/v1/query                                │ │
                │   │          ▼                                                       │ │
                │   │   ┌──────────────── prometheus ───────────────┐                 │ │
                │   │   │ ./01-prometheus.md (already deployed)     │                 │ │
                │   │   │ http://prometheus:9090                     │                 │ │
                │   │   └────────────────────────────────────────────┘                 │ │
                │   └─────────────────────────────────────────────────────────────────┘ │
                └───────────────────────────────────────────────────────────────────────┘
```

Tres invariantes:

- **Grafana sólo es accesible vía Caddy + Authelia.** No hay `ports:` al host. La UI exige login con 2FA. Las cabeceras `Remote-*` que reenvía Authelia/Caddy son la única fuente de identidad: Grafana no consulta Authelia ni LDAP por su cuenta.
- **El datasource Prometheus es interno y sin TLS.** `http://prometheus:9090`, DNS Docker, dentro de `homelab`. Nadie fuera del bridge puede pinchar ese endpoint, así que añadir TLS o auth ahí sólo añade complejidad sin ganar superficie.
- **Provisioning es la fuente de verdad.** `datasources/*.yml`, `dashboards/*.yml` y `dashboards/json/*.json` viven en git. La UI sigue funcionando para experimentar (los dashboards "ad-hoc" se guardan en SQLite, dentro del bind mount), pero el estado reproducible es el del repo.

Flujo de una petición:

```
1. navegador  → GET https://grafana.lan/  (con cookie de Authelia)
2. Caddy      → forward_auth a http://authelia:9091/api/authz/forward-auth
3. Authelia   → 200 OK + headers Remote-User, Remote-Groups, Remote-Email, Remote-Name
4. Caddy      → reverse_proxy http://grafana:3000  (con esas cabeceras añadidas)
5. Grafana    → auth.proxy: si la IP origen está en whitelist (172.20.0.0/24), confía en Remote-User
6. Grafana    → busca/crea el usuario en grafana.db, asigna sesión, devuelve la home
7. cuando el panel pinta:
   Grafana    → POST http://prometheus:9090/api/v1/query_range  (DNS interno)
   Prometheus → JSON con las series temporales
   Grafana    → render del panel
```

---

## 2. Plan de variables y archivos

El stack `monitoring` ya existe (lo creó [`./01-prometheus.md`](./01-prometheus.md)). Este doc **añade** ficheros, no crea árbol nuevo:

```
~/homelab/stacks/monitoring/             # versionable en git
├── docker-compose.yml                   # SE EXTIENDE (añade servicio grafana)
├── .env.example                         # SE EXTIENDE (añade GRAFANA_*)
├── prometheus.yml                       # sin cambios (Grafana no scrapea)
└── grafana/                             # NUEVO
    ├── grafana.ini                      # config principal (RO en el contenedor)
    └── provisioning/
        ├── datasources/
        │   └── prometheus.yml           # datasource Prometheus
        └── dashboards/
            ├── default.yml              # provider que apunta a json/
            └── json/
                └── prometheus-stats.json   # dashboard inicial (Prometheus 2.0 Stats)

/mnt/hd2t/services/monitoring/           # datos persistentes, NO en git
├── .env                                  # ya existe; SE EXTIENDE con GRAFANA_*
└── grafana/                              # NUEVO
    └── data/                             # /var/lib/grafana del contenedor
        ├── grafana.db                    # SQLite (usuarios, dashboards ad-hoc, sesiones)
        ├── plugins/                      # vacío inicialmente
        └── png/                          # screenshots de paneles
```

> **Nota sobre la convención**: el `grafana/` del repo (provisioning) y el `grafana/data/` del disco son dos árboles distintos, ninguno depende del otro. El primero es **configuración versionable**, el segundo es **estado del runtime**. La separación es intencional para que un `git pull` no pueda corromper la BD y un wipe del disco de datos no borre el provisioning.

### 2.1. Extender `.env.example` versionable

Editar `~/homelab/stacks/monitoring/.env.example` (creado por [`./01-prometheus.md`](./01-prometheus.md) §2.1) y **descomentar/rellenar** la sección Grafana:

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

# --- Prometheus (./01-prometheus.md) ---
# https://hub.docker.com/r/prom/prometheus/tags
PROMETHEUS_IMAGE_TAG=v2.55.1
PROMETHEUS_HOSTNAME=prometheus.lan
PROMETHEUS_RETENTION_TIME=30d
PROMETHEUS_RETENTION_SIZE=5GB

# --- Grafana (./02-grafana.md) ---
# https://hub.docker.com/r/grafana/grafana-oss/tags
# ¡Leer https://grafana.com/docs/grafana/latest/whatsnew/ antes de cambiar de minor!
GRAFANA_IMAGE_TAG=11.4.0

# Hostname público de la UI (sin esquema). El reverse-proxy de Caddy lo termina.
GRAFANA_HOSTNAME=grafana.lan

# Contraseña del admin local (sólo para emergencia: Authelia caído).
# Generar con: openssl rand -base64 24
# El valor aquí es un placeholder; en /mnt/hd2t/services/monitoring/.env va el real.
GRAFANA_ADMIN_PASSWORD=changeme-ver-el-env-real

# CIDR de la red Docker `homelab`. auth.proxy de Grafana sólo confía en
# cabeceras Remote-* si la conexión viene de aquí (es Caddy, en la práctica).
# Coincidir con `../02-docker/02-estructura-compose.md` §4.2.
GRAFANA_AUTH_PROXY_WHITELIST=172.20.0.0/24

# (Reservado para los siguientes docs de Fase 5; se rellenarán cuando toquen)
# NODE_EXPORTER_IMAGE_TAG=
# CADVISOR_IMAGE_TAG=
# UPTIME_KUMA_IMAGE_TAG=
# DOZZLE_IMAGE_TAG=
```

### 2.2. Extender el `.env` real (`/mnt/hd2t/services/monitoring/.env`)

```bash
# Generar una contraseña aleatoria de admin local:
GRAFANA_ADMIN_PWD=$(openssl rand -base64 24)
echo "Guarda esta contraseña en tu password manager (Vaultwarden):"
echo "  GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PWD}"

# Añadir las nuevas líneas al .env (sin tocar las existentes de Prometheus):
sudo tee -a /mnt/hd2t/services/monitoring/.env >/dev/null <<EOF

# --- Grafana (./02-grafana.md) ---
GRAFANA_IMAGE_TAG=11.4.0
GRAFANA_HOSTNAME=grafana.lan
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PWD}
GRAFANA_AUTH_PROXY_WHITELIST=172.20.0.0/24
EOF

# Comprobar permisos (deben seguir siendo 600):
ls -l /mnt/hd2t/services/monitoring/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

> **No** se anota `GRAFANA_ADMIN_PASSWORD` en el `.env.example` versionado: es un secreto. El placeholder visible en el ejemplo es deliberadamente inválido para que un copy-paste accidental falle ruidosamente.

---

## 3. Preparar el árbol de datos

### 3.1. Crear el árbol de provisioning en el repo

```bash
mkdir -p ~/homelab/stacks/monitoring/grafana/provisioning/datasources
mkdir -p ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json
```

### 3.2. Crear el árbol de datos persistentes

```bash
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/monitoring/grafana
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/monitoring/grafana/data
```

> **Migración desde `/mnt/hd2t/services/grafana/`** (esquema antiguo "un dir por servicio" creado por el bootstrap de [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) si existió):
> ```bash
> sudo rmdir /mnt/hd2t/services/grafana 2>/dev/null || true
> ```
> En un homelab nuevo no hay datos previos. Si los hubiese (un Grafana instalado a mano antes de seguir el plan), mover los contenidos a la ruta nueva (`/mnt/hd2t/services/monitoring/grafana/data/`) **antes** de recrear el contenedor; el `.db` SQLite es portable mientras la versión de Grafana sea ≥ a la que lo escribió.

### 3.3. Permisos para el proceso del contenedor

La imagen oficial `grafana/grafana-oss` se construye con `USER 472` (UID `472`, GID `472`). Al primer arranque, el binario crea/migra `grafana.db` y los subdirectorios `plugins/`, `png/`. Si el directorio del host no es escribible por `472:472`, Grafana entra en bucle de crash:

```
GF_PATHS_DATA='/var/lib/grafana' is not writable.
```

```bash
# Ajustar la propiedad del directorio de datos al UID/GID que la imagen usa.
sudo chown -R 472:472 /mnt/hd2t/services/monitoring/grafana/data
sudo chmod 750        /mnt/hd2t/services/monitoring/grafana/data
```

> Tras este paso, `ls -l /mnt/hd2t/services/monitoring/grafana/` mostrará el subdirectorio `data/` con propietario `472:472`. Es lo esperado. Borgmatic, que corre como `root`, lo respaldará igual; el operador, si necesita inspeccionarlo desde el host, usa `sudo`. **No** se añade el usuario `homelab` al grupo `472`: el GID `472` está reservado por la imagen y no debería filtrarse a otros procesos del host.

> Compatibilidad con Borgmatic: Borg respeta UID/GID en el archivo, así que la restauración recreará los ficheros como `472:472` y Grafana los podrá leer al arrancar.

---

## 4. `grafana.ini`

`~/homelab/stacks/monitoring/grafana/grafana.ini` — **versionado en git**:

```ini
# ~/homelab/stacks/monitoring/grafana/grafana.ini
# Versionado en git. Cambios se aplican con:
#   docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate grafana
# (grafana.ini NO soporta reload en caliente; sí lo soporta el provisioning, ver §12.1).
#
# Documentación: https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/
# Cualquier opción aquí puede sobreescribirse vía env var GF_<SECTION>_<KEY> (mayúsculas, _).

# ============================================================================
# [server] — URL pública y subpath
# ============================================================================
[server]
# protocolo interno entre Caddy y Grafana: HTTP plano (red privada homelab).
protocol = http
http_port = 3000

# Hostname público (lo termina Caddy en HTTPS). Necesario para que los enlaces
# que Grafana genera (share panel, export, links a otros dashboards) usen la
# URL pública en vez de http://grafana:3000/.
domain = ${GF_SERVER_DOMAIN}
root_url = ${GF_SERVER_ROOT_URL}
serve_from_sub_path = false

# Cookie de sesión sólo por HTTPS. Caddy reescribe X-Forwarded-Proto: https.
[security]
cookie_secure = true
cookie_samesite = lax
allow_embedding = false
# La contraseña del admin local se inyecta vía env (GF_SECURITY_ADMIN_PASSWORD).
# disable_initial_admin_creation = false  # se necesita el admin para inicializar la BD.

# ============================================================================
# [auth] — login y métodos de autenticación
# ============================================================================
[auth]
# Quitar el formulario de login local: con auth.proxy activado, no hace falta.
disable_login_form = true
# Quitar el botón "Sign out" (que cierra la sesión en Grafana pero no en
# Authelia). En su lugar, el operador hace logout en https://auth.lan.
# Mantener `false` (default) está bien: aunque el botón existe, al volver a la
# UI Authelia re-emite las cabeceras Remote-* y la sesión se rehidrata.
disable_signout_menu = false
# No registrar a usuarios anónimos.
[auth.anonymous]
enabled = false

[auth.basic]
# Basic auth (HTTP) deshabilitada: la única ruta de auth normal es proxy.
enabled = false

[auth.proxy]
enabled = true
# Caddy/Authelia inyectan Remote-User como nombre de usuario.
header_name = Remote-User
header_property = username
# auto_sign_up: si llega un usuario nuevo (Remote-User no existe en grafana.db),
# crearlo automáticamente con rol Editor. Cambiar a Viewer si se quiere read-only.
auto_sign_up = true
# Cabeceras adicionales que se mapean a propiedades del usuario en grafana.db.
# Authelia las pone gratis con su forward_auth.
headers = Email:Remote-Email Name:Remote-Name Groups:Remote-Groups
# whitelist: la conexión TCP debe venir de una IP de esta lista para que
# Grafana CONFIE en Remote-User. Si no, ignora la cabecera y exige login local.
# El CIDR se inyecta vía env (GF_AUTH_PROXY_WHITELIST) desde el .env.
whitelist = ${GF_AUTH_PROXY_WHITELIST}
# enable_login_token = false (default): no usar tokens emitidos por proxy.

# ============================================================================
# [users] — defaults para usuarios creados por auth.proxy
# ============================================================================
[users]
# Rol por defecto cuando auth.proxy.auto_sign_up crea un usuario nuevo.
# Editor: puede crear y editar dashboards "ad-hoc" en la UI sin tocar git.
# Viewer: read-only.
auto_assign_org_role = Editor
# La organización por defecto se llama "Main Org." (default). No se renombra:
# muchos exports/imports asumen ese nombre.

# ============================================================================
# [analytics] — telemetría a Grafana Labs (off en homelab)
# ============================================================================
[analytics]
reporting_enabled = false
check_for_updates = false
check_for_plugin_updates = false

# ============================================================================
# [log] — logging
# ============================================================================
[log]
# console: stdout/stderr → docker logs grafana → driver json-file.
mode = console
level = info

# ============================================================================
# [dashboards] — versionado interno y refresco mínimo
# ============================================================================
[dashboards]
# Cuántas versiones por dashboard guardar en grafana.db (para "Restore previous").
versions_to_keep = 20
# Mínimo de refresco aceptado en los paneles. 5s es de sobra para 30s de scrape.
min_refresh_interval = 5s

# ============================================================================
# [alerting] — Grafana Alerting (off por ahora)
# ============================================================================
# El homelab inicial no usa Grafana Alerting (las alertas las hará Uptime Kuma
# en ./05-uptime-kuma.md). Se documentan aquí los flags por completitud.
[alerting]
enabled = false
[unified_alerting]
enabled = false

# ============================================================================
# [smtp] — envío de email (off, no hay SMTP saliente en el homelab)
# ============================================================================
[smtp]
enabled = false
```

### 4.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `[server] protocol/http_port` | HTTP plano en `:3000` dentro de `homelab`; el TLS lo termina Caddy. Cambiar a `protocol = https` requeriría montar certificados dentro del contenedor — innecesario y duplica complejidad. |
| `[server] domain / root_url` | Sustituido vía env (`GF_SERVER_DOMAIN`, `GF_SERVER_ROOT_URL`) para que el operador no edite el `.ini` al cambiar de dominio. Sin esto, los enlaces del UI apuntarían a `http://grafana:3000/...`. |
| `[security] cookie_secure / samesite` | Cookie sólo por HTTPS (Caddy siempre HTTPS) y `lax` para no romper el redirect post-login de Authelia (que viene `Same-Site` desde `auth.lan` a `grafana.lan`, ambos `*.lan`, lax los acepta). |
| `[security] allow_embedding=false` | Default seguro. No se usa Grafana embebido; activarlo (`true`) habilitaría clickjacking. |
| `[auth] disable_login_form=true` | Una vez `auth.proxy` activado, el formulario local sólo es ruido. Si `auth.proxy` falla por algún motivo, el flujo de emergencia (§12.5) re-activa `false` temporalmente. |
| `[auth.basic] enabled=false` | Cierra `Authorization: Basic ...` como segunda puerta. La API se usa con service accounts (token Bearer), no con `admin:pwd`. |
| `[auth.anonymous] enabled=false` | No usuarios anónimos. |
| `[auth.proxy] enabled=true` | El núcleo de la integración SSO con Authelia. |
| `[auth.proxy] header_name=Remote-User` | Cabecera estándar que Authelia inyecta vía `forward_auth`. **Hay que asegurarse** de que el snippet `authelia_proxy` de Caddy reenvía esta cabecera al backend (lo hace por defecto en §9.1 de Authelia). |
| `[auth.proxy] auto_sign_up=true` | Cualquier usuario que pase Authelia entra a Grafana sin paso intermedio "el admin tiene que crearte". Para un homelab personal, es lo conveniente; en un entorno multi-tenant se pondría `false` para que el admin apruebe. |
| `[auth.proxy] headers=Email:... Name:... Groups:...` | Mapea las cabeceras de Authelia a campos del usuario en `grafana.db`. **Importante**: el campo `Groups` no se usa para asignar roles automáticamente en Grafana OSS (eso requiere LDAP / OAuth2 con role attribute). El rol viene de `[users] auto_assign_org_role`. Las cabeceras adicionales se guardan como info; útil cuando se filtran dashboards por usuario en el futuro. |
| `[auth.proxy] whitelist=${GF_AUTH_PROXY_WHITELIST}` | Defensa en profundidad: aunque las cabeceras `Remote-*` lleguen, Grafana sólo las acepta si la conexión TCP origen está en este CIDR. Esto evita que un bug futuro (ej. exponer `:3000` por accidente) convierta el `auth.proxy` en una vulnerabilidad de spoofing trivial. El CIDR `172.20.0.0/24` cubre todos los contenedores del bridge `homelab`; en la práctica, sólo Caddy hace forward al `:3000`. |
| `[users] auto_assign_org_role=Editor` | El operador es siempre el mismo usuario en un homelab personal; `Editor` permite crear dashboards "ad-hoc" en la UI sin tocar el provisioning. Si en el futuro hay un usuario "lectura solamente", se cambia a `Viewer`. |
| `[analytics] reporting/checks=false` | Telemetría a Grafana Labs y "hay nueva versión" en la home: ninguno aporta en un homelab con Watchtower. |
| `[log] mode=console / level=info` | `console` envía a stdout, que Docker captura en el driver `json-file`. `info` es el nivel mínimo útil (incluye logins fallidos y cambios de provisioning); `debug` se sube temporalmente para troubleshooting (§12.4). |
| `[dashboards] versions_to_keep=20` | "Restore previous version" funciona hasta 20 ediciones atrás de cada dashboard "ad-hoc". 20 son ~unas semanas de iteración. Más versiones engordan `grafana.db` rápido. |
| `[dashboards] min_refresh_interval=5s` | Cota inferior por seguridad: si alguien guarda un dashboard con `refresh: 1s`, Grafana lo rebaja a 5s. Evita martillear Prometheus desde un dashboard mal configurado. |
| `[alerting] / [unified_alerting] enabled=false` | Las alertas las hará Uptime Kuma ([`./05-uptime-kuma.md`](./05-uptime-kuma.md)) y, opcionalmente, reglas Prometheus + Alertmanager (variante futura). Mantener Grafana Alerting off evita que se queden reglas zombies en `grafana.db`. |
| `[smtp] enabled=false` | El homelab no tiene SMTP saliente (cf. [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §0). Sin SMTP, no hay invitaciones por email, alertas por email ni reset de contraseña por email — coherente con el modelo (Authelia maneja credenciales, no Grafana). |

---

## 5. Provisioning de datasources

`~/homelab/stacks/monitoring/grafana/provisioning/datasources/prometheus.yml` — **versionado en git**:

```yaml
# ~/homelab/stacks/monitoring/grafana/provisioning/datasources/prometheus.yml
# Datasource provisioning v1.
# Documentación: https://grafana.com/docs/grafana/latest/administration/provisioning/#data-sources
#
# Cualquier cambio aquí se aplica automáticamente: Grafana releé este fichero
# al arrancar y al detectar cambios en el archivo (mtime).

apiVersion: 1

datasources:
  - name: Prometheus
    uid: prometheus     # estable: los dashboards JSON refieren a este UID.
    type: prometheus
    access: proxy        # proxy: Grafana hace de proxy hacia Prometheus.
    url: http://prometheus:9090
    isDefault: true
    editable: false      # no editable desde la UI: la fuente de verdad es este YAML.
    jsonData:
      # Versión del datasource (informa cómo Grafana habla con Prometheus).
      # 11.x soporta hasta `2.50.0+`; 2.55 cae aquí.
      prometheusVersion: 2.55.x
      # Tipo de instalación, condiciona qué features Grafana ofrece.
      prometheusType: Prometheus
      # Intervalo mínimo: el step que Grafana solicita a Prometheus no baja
      # de aquí. Coincide con el scrape_interval global de prometheus.yml.
      timeInterval: 30s
      # HTTP method: POST permite queries más largas (URL >2KB).
      httpMethod: POST
      # Habilita "Exemplars" (tracing). Aún sin tracer; cuando se active Tempo,
      # se rellenará exemplarTraceIdDestinations. Por ahora dejarlo vacío.
      # exemplarTraceIdDestinations: []
```

### 5.1. Por qué cada campo

| Campo | Por qué |
|---|---|
| `name: Prometheus` | Nombre visible en la UI ("Configuration → Data sources"). Estable; los dashboards JSON apuntan al UID, no al nombre, así que renombrarlo es seguro. |
| `uid: prometheus` | Identificador estable que los dashboards JSON usan en el campo `datasource.uid`. **No** se deja al default (Grafana genera un UID aleatorio que cambia entre instalaciones), porque eso obligaría a editar cada JSON al restaurar. |
| `type: prometheus` | Tipo de plugin. El plugin viene preinstalado en la imagen `grafana-oss`. |
| `access: proxy` | Grafana actúa de proxy: el navegador habla con Grafana, Grafana habla con Prometheus por DNS interno. La alternativa (`access: direct`) hace que el navegador alcance Prometheus directamente — incompatible con un setup donde Prometheus no está expuesto al exterior. |
| `url: http://prometheus:9090` | DNS Docker dentro de `homelab`. **No** `https://prometheus.lan/` porque eso pasaría por Caddy + Authelia, y Grafana no tiene cookie de sesión Authelia (no es un navegador). |
| `isDefault: true` | Cuando se crea un panel sin especificar datasource, Grafana usa éste. Mientras sea el único, la opción es cosmética; cuando se añadan Loki/InfluxDB/etc. en el futuro, esto se mantiene en el principal. |
| `editable: false` | La UI muestra el datasource en modo read-only (icono de candado). Cualquier cambio se hace editando este YAML y reiniciando Grafana (los datasources, a diferencia de los dashboards, no se recargan en caliente — se requiere `up -d --force-recreate grafana`). Esto evita que un dashboard mal exportado pise el datasource al re-importarlo. |
| `jsonData.prometheusVersion: 2.55.x` | Le dice a Grafana qué features de Prometheus puede usar (ej. `@start()` y `@end()` modifiers). Si se sube Prometheus a 3.x se actualiza también este campo. |
| `jsonData.prometheusType: Prometheus` | Distingue Prometheus puro de Cortex/Mimir/Thanos (que tienen quirks distintos). |
| `jsonData.timeInterval: 30s` | El "min step" del datasource; coincide con `scrape_interval` global. Sin esto, Grafana puede pedir resoluciones más finas que las que Prometheus tiene, generando series interpoladas. |
| `jsonData.httpMethod: POST` | Por defecto `GET`, pero las queries de algunos dashboards (Node Exporter Full) son largas y exceden los límites de URL de algunos proxies. POST es más robusto y Prometheus lo soporta. |

---

## 6. Provisioning de dashboards

### 6.1. Provider YAML

`~/homelab/stacks/monitoring/grafana/provisioning/dashboards/default.yml` — **versionado en git**:

```yaml
# ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/default.yml
# Dashboard provider v1.
# Documentación: https://grafana.com/docs/grafana/latest/administration/provisioning/#dashboards
#
# Este "provider" le dice a Grafana: vigila este directorio y carga cualquier .json
# que aparezca como un dashboard. Los siguientes docs de Fase 5 sólo añaden
# .json a json/ — no tocan ni grafana.ini ni este fichero.

apiVersion: 1

providers:
  - name: 'default'
    # orgId 1 es la "Main Org." que Grafana crea en el primer arranque.
    orgId: 1
    # folder vacío => raíz; cuando se quiera agrupar (ej. "Sistema", "Red"),
    # se añade aquí el nombre. Por simplicidad, todos los dashboards quedan
    # en la raíz; el campo `tags` de cada JSON ya organiza visualmente.
    folder: ''
    # Tipo de almacenamiento. `file` apunta al sistema de ficheros del contenedor.
    type: file
    # Cuántos segundos espera Grafana entre relecturas del directorio.
    # 30s es coherente con el scrape_interval; bajarlo no aporta.
    updateIntervalSeconds: 30
    # Permitir borrar dashboards desde la UI (que no estén en el provisioning).
    # `false` = los dashboards "ad-hoc" persisten en grafana.db; los provisioned
    # no se pueden borrar (se restauran al siguiente refresh del provider).
    allowUiUpdates: false
    # disableDeletion: si un .json desaparece del directorio, Grafana borra el
    # dashboard correspondiente. `false` = sí lo borra; cómodo para "deshacer
    # importaciones" simplemente quitando el .json del repo.
    disableDeletion: false
    options:
      path: /etc/grafana/provisioning/dashboards/json
      foldersFromFilesStructure: false
```

### 6.2. Por qué cada campo

| Campo | Por qué |
|---|---|
| `name: default` | Identificador del provider. Único provider en el homelab; nombre descriptivo. |
| `orgId: 1` | "Main Org.", la única org en un homelab personal. |
| `folder: ''` | Raíz. Agrupar por carpeta con `folder:` no aporta cuando hay <20 dashboards y todos los dashboards públicos importados ya tienen `tags` que los categorizan en la UI. |
| `type: file` | Provider de filesystem; Grafana sólo soporta `file` para dashboards locales. |
| `updateIntervalSeconds: 30` | Cuando un doc futuro deja un nuevo `.json` en el directorio, en ≤30 s aparece en la UI sin reiniciar Grafana. **Esta es la palanca principal** que hace cooperativos los docs de Fase 5: cada uno sólo añade un fichero y refresca. |
| `allowUiUpdates: false` | Los dashboards provisioned no son editables desde la UI (icono de candado en la cabecera del dashboard). Si se quiere experimentar, se "hace una copia" (botón "Save as") y se trabaja sobre la copia; al guardarla, va a `grafana.db` (ad-hoc). El original sigue intacto en git. |
| `disableDeletion: false` | Si se borra un `.json` del repo, Grafana borra el dashboard correspondiente al siguiente refresh (≤30 s). Esto hace que "desinstalar un exporter" sea simétrico a "instalarlo": basta con `git rm` el JSON. |
| `options.path: /etc/grafana/provisioning/dashboards/json` | Ruta dentro del contenedor; corresponde al bind mount de §7. |
| `foldersFromFilesStructure: false` | Si fuera `true`, subdirectorios bajo `json/` se convertirían en carpetas en la UI. Mientras los dashboards estén todos planos, no aporta. |

### 6.3. Dashboard inicial: Prometheus 2.0 Stats

El único exporter activo el día 1 es el self-scrape de Prometheus. Para tener métricas que mirar desde el primer login, se importa el dashboard público "Prometheus 2.0 Stats" ([Grafana.com #3662](https://grafana.com/grafana/dashboards/3662-prometheus-2-0-stats/)).

#### 6.3.1. Descargar el JSON

```bash
mkdir -p ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json
cd ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json

# Descargar la versión más reciente del dashboard #3662 desde grafana.com.
# El query param ?revision=N fija una versión concreta (recomendado para reproducibilidad).
# revision=2 es la última al momento de escribir este doc.
curl -fsSL \
  "https://grafana.com/api/dashboards/3662/revisions/2/download" \
  -o prometheus-stats.json

# Verificar que es un JSON válido y tiene el panel esperado:
python3 -c 'import json; d=json.load(open("prometheus-stats.json")); print("title:", d.get("title")); print("panels:", len(d.get("panels", [])))'
# Esperado:
#   title: Prometheus 2.0 Stats
#   panels: 23  (aprox; varía con la revisión)
```

#### 6.3.2. Apuntar el JSON al UID `prometheus`

Los dashboards descargados de Grafana.com vienen con `${DS_PROMETHEUS}` como placeholder del datasource. Con provisioning, ese placeholder no se resuelve (el "Import dialog" de la UI lo haría) y los paneles quedan en gris ("Datasource not found").

Solución: **post-procesar** el JSON sustituyendo el placeholder por el UID estable que se definió en §5.

```bash
cd ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json

# 1. Sustituir el placeholder por el UID `prometheus` definido en datasources/prometheus.yml:
sed -i 's/"\${DS_PROMETHEUS}"/"prometheus"/g' prometheus-stats.json

# 2. Eliminar la sección __inputs (sólo se usa en el "Import dialog", incompatible con provisioning):
python3 - <<'PY'
import json
p = "prometheus-stats.json"
d = json.load(open(p))
# El bloque __inputs se llama en realidad "__inputs" (raíz del JSON):
for k in ("__inputs", "__elements", "__requires"):
    d.pop(k, None)
json.dump(d, open(p, "w"), indent=2)
print("Cleaned:", p)
PY

# 3. Comprobación: no debe quedar ningún ${DS_*}:
grep -c '${DS_' prometheus-stats.json
# Esperado: 0
```

> **Por qué `sed` y `python` en lugar de un import manual desde la UI**: la UI permite importar el JSON, asignar el datasource y "Save". Pero ese dashboard queda en `grafana.db` como **ad-hoc**, no como provisioned: no se versiona en git y se pierde si el bind mount se borra. La pequeña post-edición es el coste de tenerlo reproducible.

> **Reproducibilidad**: la `revision=2` en la URL fija la versión del dashboard. Si en el futuro se sube a `revision=3`, el `curl` la trae; revisar antes el changelog del dashboard en Grafana.com.

#### 6.3.3. Notas sobre los próximos dashboards

Los siguientes docs de Fase 5 dejarán los suyos en el mismo `json/`:

| Doc que lo activará | Dashboard | Grafana.com ID |
|---|---|---|
| [`./03-node-exporter.md`](./03-node-exporter.md) | Node Exporter Full (CPU, RAM, disco, red, **temperatura Pi**) | 1860 |
| [`./04-cadvisor.md`](./04-cadvisor.md) | Docker / cAdvisor (CPU, RAM, IO por contenedor) | 14282 |
| [`./05-uptime-kuma.md`](./05-uptime-kuma.md) | Uptime Kuma — Service Status | 18667 (revisión específica) |
| [`./06-dozzle.md`](./06-dozzle.md) | (no aplica — Dozzle no exporta métricas) | — |

Cada uno seguirá el mismo patrón: `curl` + `sed` del `${DS_PROMETHEUS}` + `git add` del `.json`. Ningún cambio en este doc será necesario.

> Sobre la "temperatura Pi": Node Exporter expone `node_hwmon_temp_celsius` (lectura del thermal zone del kernel). El dashboard 1860 incluye un panel "Hardware temperature" que la pinta sin configuración extra. Para una vista dedicada se puede importar también [Raspberry Pi Monitoring](https://grafana.com/grafana/dashboards/10578-rpi-monitoring/) (id 10578); se documentará en `./03-node-exporter.md`.

---

## 7. `docker-compose.yml`

Editar `~/homelab/stacks/monitoring/docker-compose.yml` (creado por [`./01-prometheus.md`](./01-prometheus.md) §5) y **añadir** el bloque `grafana:` debajo del bloque `prometheus:`. **No** se toca el bloque `prometheus:` ni el bloque `networks:`.

```yaml
# ~/homelab/stacks/monitoring/docker-compose.yml
# Stack: monitoring (../02-docker/02-estructura-compose.md §1.1).
#
# Estado tras este doc: dos servicios (`prometheus`, `grafana`).
# Los siguientes docs de la Fase 5 (./03-node-exporter.md, ./04-cadvisor.md,
# ./05-uptime-kuma.md, ./06-dozzle.md) añadirán cada uno su servicio sin tocar
# los existentes ni el bloque `networks:`.

name: monitoring

services:
  prometheus:
    # ... bloque sin cambios; ver ./01-prometheus.md §5 ...

  grafana:
    image: grafana/grafana-oss:${GRAFANA_IMAGE_TAG}
    container_name: grafana
    hostname: grafana
    restart: unless-stopped

    # Imagen oficial: USER 472. NO sobreescribir con ${PUID}:${PGID}; en su
    # lugar, el bind mount /mnt/hd2t/services/monitoring/grafana/data se
    # hace propiedad de 472:472 en §3.3.

    # Grafana arranca antes que Prometheus es indiferente: el datasource es
    # tolerante a "datasource caído" (el panel muestra error, el resto del
    # dashboard sigue cargando). depends_on opcional, sólo para que
    # `docker compose up -d` arranque Prometheus primero por estética.
    depends_on:
      prometheus:
        condition: service_healthy

    env_file:
      - /mnt/hd2t/services/monitoring/.env
    environment:
      TZ: ${TZ}

      # ----- [server] -----
      GF_SERVER_DOMAIN: ${GRAFANA_HOSTNAME}
      GF_SERVER_ROOT_URL: "https://${GRAFANA_HOSTNAME}/"
      # GF_SERVER_HTTP_PORT: 3000   # default

      # ----- [security] -----
      # Contraseña del admin local (sólo emergencia; Authelia es el path normal).
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
      # NO exponer GF_SECURITY_ADMIN_USER: el default es `admin`, basta.

      # ----- [auth.proxy] -----
      # whitelist se inyecta vía env para no hardcodear el CIDR en grafana.ini.
      GF_AUTH_PROXY_WHITELIST: ${GRAFANA_AUTH_PROXY_WHITELIST}

      # ----- [analytics] -----
      # Redundante con grafana.ini, pero seguro: si el .ini falla por algún
      # motivo, las env vars siguen aplicándose.
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"
      GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES: "false"

      # ----- [feature_toggles] -----
      # Mantener vacío por ahora. Las feature flags experimentales se documentan
      # caso a caso (ej. `publicDashboards` para compartir un panel en HTTP simple).

    volumes:
      # grafana.ini versionable, read-only.
      - type: bind
        source: ./grafana/grafana.ini
        target: /etc/grafana/grafana.ini
        read_only: true
        bind:
          create_host_path: false

      # Provisioning (datasources + dashboards) versionable, read-only.
      - type: bind
        source: ./grafana/provisioning
        target: /etc/grafana/provisioning
        read_only: true
        bind:
          create_host_path: false

      # Datos persistentes (SQLite con usuarios y dashboards ad-hoc, plugins, png).
      - type: bind
        source: /mnt/hd2t/services/monitoring/grafana/data
        target: /var/lib/grafana
        bind:
          create_host_path: false

    tmpfs:
      - /tmp:size=64m,mode=1700,uid=472,gid=472

    read_only: true

    networks:
      - homelab

    cap_drop:
      - ALL

    security_opt:
      - no-new-privileges:true

    healthcheck:
      # /api/health responde 200 con JSON {"database":"ok",...} cuando el proceso
      # está vivo y la BD es accesible. No requiere auth.
      test: ["CMD-SHELL", "wget -qO- http://localhost:3000/api/health | grep -q '\"database\":\\s*\"ok\"'"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s

    labels:
      com.centurylinklabs.watchtower.enable: "true"
      homepage.group: "Monitorización"
      homepage.name: "Grafana"
      homepage.icon: "grafana.png"
      homepage.href: "https://grafana.${LAN_DOMAIN}"
      homepage.description: "Dashboards de métricas (Prometheus)"

networks:
  homelab:
    external: true
```

### 7.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `image: grafana/grafana-oss:${GRAFANA_IMAGE_TAG}` | Tag fijo desde el `.env`. Variante `-oss` excluye binarios enterprise. Multi-arch (incluye `linux/arm64`). |
| `container_name: grafana` / `hostname: grafana` | Caddy llama a `http://grafana:3000` por nombre Docker; el datasource llama a `http://prometheus:9090` (que ya existe). Sin `container_name` el nombre real sería `monitoring-grafana-1`. |
| (sin `user:`) | La imagen oficial fija `USER 472`. Forzar `user: "1000:1000"` rompe `chown` de la BD durante la migración inicial y deja `grafana.db` con ownership mixto tras restores. |
| `depends_on: prometheus (service_healthy)` | Ordena el arranque (Prometheus primero). No es estrictamente necesario: el datasource Grafana es tolerante a "Prometheus caído", pero resulta más limpio en `docker compose up -d` por primera vez. **No** se usa `condition: service_started` (que sólo espera al exit del entrypoint, no a `healthy`); `service_healthy` aprovecha el healthcheck definido en `./01-prometheus.md`. |
| `env_file` ruta absoluta | Plantilla §6 de estructura-compose. Coherente con Prometheus. |
| `environment: GF_SERVER_DOMAIN/ROOT_URL` | Sustituye `${...}` dentro de `grafana.ini`. Mantener el dominio en el `.env` (no hardcoded en `grafana.ini`) permite cambiar `LAN_DOMAIN` sin tocar el repo. |
| `environment: GF_SECURITY_ADMIN_PASSWORD` | Inyectado desde el `.env` real. **Nunca** hardcoded en el compose ni en `grafana.ini`. Tras el primer arranque, Grafana hashea la contraseña y la guarda en `grafana.db`; cambiarla luego en el `.env` y `up -d --force-recreate` la actualiza. |
| `environment: GF_AUTH_PROXY_WHITELIST` | Sustituye `${GF_AUTH_PROXY_WHITELIST}` en `grafana.ini`. Mantenerlo en `.env` permite cambiar el CIDR si se reasigna `homelab`. |
| `environment: GF_ANALYTICS_*=false` | Redundante con `grafana.ini`. Se duplica para que el "off" sea robusto: si por error alguien despliega Grafana sin `grafana.ini` (ej. olvido del bind mount), las env vars siguen suprimiendo telemetría. |
| `volumes: grafana.ini RO` | Versionable en git; los cambios se aplican con `up -d --force-recreate grafana` (sin reload en caliente). RO impide que un proceso comprometido sobreescriba la config. |
| `volumes: provisioning/ RO` | Idem. Los cambios en `datasources/` requieren recrear (el datasource es estático); los cambios en `dashboards/json/*.json` se aplican en ≤30s sin reiniciar (cf. §6.1). |
| `volumes: /var/lib/grafana RW` (bind) | BD SQLite, plugins descargados, png renderizados. Bind mount para que Borg lo respalde por path predecible. |
| `tmpfs: /tmp` con `uid=472,gid=472` | Necesario porque el FS root es `read_only`. Grafana escribe ficheros temporales (cookies de sesión efímeras, exports parciales, etc.) en `/tmp`; 64 MiB cubre exports razonables. UID/GID coinciden con el proceso. |
| `read_only: true` | El binario no puede escribir fuera de `/var/lib/grafana` (writable bind), `/tmp` (tmpfs). Reduce superficie ante un compromiso del proceso. |
| `networks: [homelab]` | Único networking. Resuelve `prometheus`, `caddy`, etc. por DNS interno. |
| `cap_drop: ALL` (sin `cap_add`) | Grafana no necesita capabilities especiales. |
| `security_opt: no-new-privileges:true` | Plantilla §6. |
| `healthcheck: /api/health + grep "database":"ok"` | El endpoint devuelve JSON tipo `{"database":"ok","version":"11.4.0","commit":"..."}`. Comprobar el campo `database` cubre el caso "el proceso vive pero la BD se corrompió" (que devolvería `"database":"failing"`). 60 s de `start_period` por si tras un upgrade se ejecutan migraciones de schema (típico al subir minor). |
| `labels.watchtower.enable=true` | Justificado en la tabla §0. Patches de Grafana son seguros entre 11.x.y → 11.x.z. Cuando llegue el cruce a 12.x se cambia a `false` mientras dura la migración. |
| `labels.homepage.*` | Auto-descubrimiento por Homepage ([`../12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md)). |

### 7.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env config >/dev/null \
  && echo "Compose OK"

# Validar grafana.ini con el binario oficial sin desplegar:
docker run --rm \
  -v $(pwd)/grafana/grafana.ini:/etc/grafana/grafana.ini:ro \
  -v $(pwd)/grafana/provisioning:/etc/grafana/provisioning:ro \
  -e GF_SERVER_DOMAIN=grafana.lan \
  -e GF_SERVER_ROOT_URL=https://grafana.lan/ \
  -e GF_SECURITY_ADMIN_PASSWORD=test \
  -e GF_AUTH_PROXY_WHITELIST=172.20.0.0/24 \
  grafana/grafana-oss:11.4.0 \
  /usr/share/grafana/bin/grafana cli admin reset-admin-password test 2>&1 | head -10
# El comando falla por falta de BD persistente, pero confirma que la imagen
# arranca y que el .ini es parseable. Errores de sintaxis del .ini saldrían
# como `Failed to read config file` con la línea exacta.

# Validar el JSON del dashboard:
python3 -c 'import json; json.load(open("grafana/provisioning/dashboards/json/prometheus-stats.json")); print("JSON OK")'
```

---

## 8. Despliegue

### 8.1. Levantar el stack

```bash
cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d
```

Salida esperada:

```
[+] Running 2/2
 ✔ Container prometheus  Running
 ✔ Container grafana     Started
```

### 8.2. Estado del contenedor

```bash
docker compose ps
# Esperado:
# NAME         IMAGE                          STATUS                  PORTS
# grafana      grafana/grafana-oss:11.4.0     Up X (healthy)
# prometheus   prom/prometheus:v2.55.1        Up X (healthy)
```

Si tarda en `(healthy)` o entra en `(unhealthy)`:

```bash
docker compose logs grafana | tail -50
```

Eventos esperados en los logs (primer arranque):

```
logger=settings t=... level=info msg="Starting Grafana" version=11.4.0 ...
logger=sqlstore t=... level=info msg="Connecting to DB" dbtype=sqlite3
logger=migrator t=... level=info msg="Starting DB migrations"
logger=migrator t=... level=info msg="migrations completed" performed=NN
logger=provisioning.datasources t=... level=info msg="inserting datasource from configuration" name=Prometheus uid=prometheus
logger=provisioning.dashboard t=... level=info msg="starting to provision dashboards"
logger=provisioning.dashboard.fileReader t=... level=info msg="finished to provision dashboards"
logger=http.server t=... level=info msg="HTTP Server Listen" address=[::]:3000 protocol=http
```

### 8.3. Smoke test desde la red `homelab`

```bash
# Caddy alcanza Grafana por nombre Docker:
docker exec caddy wget -qO- http://grafana:3000/api/health
# Esperado: {"database":"ok","version":"11.4.0",...}

# Verificar que el datasource Prometheus está provisioned y en green:
docker exec caddy wget -qO- \
  --header="Authorization: Bearer DUMMY" \
  http://grafana:3000/api/datasources/uid/prometheus 2>&1 | head -5
# Sin token devolverá 401; sólo confirma que la API responde.
```

### 8.4. Smoke test desde el host

```bash
# Grafana NO debe ser alcanzable desde la IP del host:
curl -sf http://192.168.1.10:3000/api/health -m 2 ; echo "exit=$?"
# Esperado: exit=7 (connection refused) o exit=28 (timeout). Nunca 200.

docker port grafana
# Esperado: vacío (sin port mappings).
```

---

## 9. Integración con Caddy (`reverse_proxy` + `forward_auth`)

### 9.1. Añadir el bloque `grafana.lan` al `Caddyfile`

Editar `~/homelab/stacks/proxy/Caddyfile` y añadir, en la sección de bloques de host, **debajo** de `prometheus.lan`:

```caddy
# Grafana (../05-monitorizacion/02-grafana.md)
grafana.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    import authelia_proxy
    reverse_proxy http://grafana:3000
}
```

Razones:

- **`import authelia_proxy`** aplica el `forward_auth` definido en [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §9.1. El snippet ya reenvía las cabeceras `Remote-User`/`Remote-Groups`/`Remote-Email`/`Remote-Name` al backend; Grafana las consume con `auth.proxy` (§4).
- **No se reescribe `Host`** ni `X-Forwarded-Proto`: Caddy ya las inyecta con el valor correcto (`grafana.lan` y `https`). El `GF_SERVER_ROOT_URL` ya le ha dicho a Grafana cuál es su URL pública.
- **No se añade `transport http { tls }`**: la conexión Caddy → Grafana es HTTP plano dentro de `homelab`.

### 9.2. Recargar Caddy sin downtime

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Si la sintaxis está mal, el comando devuelve no-cero y la config previa sigue activa (Caddy es atómico). Validar manualmente:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
```

### 9.3. Añadir la regla en Authelia (`access_control.rules`)

Editar `~/homelab/stacks/auth/configuration.yml` (sección `access_control.rules`, ya documentada en [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §5) y **añadir** `grafana.lan` a la lista de servicios protegidos por 2FA, junto a `prometheus.lan`:

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
        - "prometheus.{{ env "LAN_DOMAIN" }}"
        - "grafana.{{ env "LAN_DOMAIN" }}"     # <── nuevo
      policy: two_factor
      subject:
        - "group:admin"
```

Recargar Authelia (su `configuration.yml` no soporta `watch:`):

```bash
docker compose -f ~/homelab/stacks/auth/docker-compose.yml restart authelia
```

### 9.4. Añadir el registro DNS local en Pi-hole

Pi-hole UI → **Local DNS** → **DNS Records** → añadir:

```
grafana.lan → 192.168.1.10
```

Reload del DNS interno:

```bash
docker exec pihole pihole reloaddns
```

Verificar:

```bash
dig +short @192.168.1.241 grafana.lan
# Esperado: 192.168.1.10
```

### 9.5. Probar desde el navegador

Desde un cliente con `root.crt` instalado (§6.5 de [`../03-red/04-caddy.md`](../03-red/04-caddy.md)):

```
https://grafana.lan
```

- Primera carga (sin sesión): redirección a `https://auth.lan/?rd=https%3A%2F%2Fgrafana.lan%2F`.
- Login + TOTP en Authelia.
- Redirección de vuelta: la home de Grafana carga, **sin pedir login propio** (auth.proxy ha leído `Remote-User` y creado al usuario).
- Esquina superior derecha: avatar con el nombre de usuario que Authelia ha enviado en `Remote-User` (ej. `homelab-admin`). Al hacer hover, "Signed in as <Remote-Name>".
- En **Configuration → Data sources** debe aparecer `Prometheus` con un candado (provisioned) y el botón **Test** debe devolver "Successfully queried the Prometheus API".
- En **Dashboards → Browse** debe aparecer "Prometheus 2.0 Stats". Al abrirlo, todos los paneles deben renderizar (varios gauges con valores y la tabla "Targets" mostrando 1 fila — el self-scrape).

---

## 10. Verificación

### 10.1. Contenedor sano

```bash
docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml ps
# STATUS: "Up X (healthy)" para grafana y prometheus.
```

### 10.2. Grafana escucha sólo en redes Docker

```bash
sudo ss -ltn | awk '$4 ~ /:3000$/'
# Esperado: vacío (no se publica al host).

docker port grafana
# Esperado: vacío.
```

### 10.3. `/api/health` desde dentro de `homelab`

```bash
docker exec caddy wget -qO- http://grafana:3000/api/health | python3 -m json.tool
# Esperado:
# {
#   "commit": "...",
#   "database": "ok",
#   "version": "11.4.0"
# }
```

### 10.4. Cert hoja firmado por la CA interna

```bash
echo | openssl s_client -connect grafana.lan:443 -servername grafana.lan 2>/dev/null \
  | openssl x509 -noout -issuer -subject
# Esperado:
#   issuer=  CN = Caddy Local Authority - 2024 ECC Intermediate
#   subject= CN = grafana.lan
```

### 10.5. Forward-auth deniega sin sesión

```bash
# Llamar a la UI sin cookie:
curl -isk https://grafana.lan/ | head -3
# Esperado: HTTP/2 302 con Location: https://auth.lan/?rd=...
```

### 10.6. `auth.proxy` rechaza Remote-User si la IP no está en whitelist

Probar que la whitelist funciona (defensa en profundidad):

```bash
# Conectarse al :3000 desde el host (no debería estar publicado, pero usamos
# docker exec en otro contenedor que NO está en homelab para forzar IP origen
# fuera del CIDR; aquí simulamos enviando desde el propio host con docker
# exec sobre un contenedor que sí está en homelab — el caso real "fuera de
# whitelist" no se puede provocar sin publicar el puerto, lo cual no haremos).
#
# Verificación pasiva: revisar los logs de Grafana al primer login real.
docker logs grafana 2>&1 | grep -i 'auth.proxy'
# Esperado al primer login: línea tipo
#   level=info msg="user signed in via auth proxy" username=<Remote-User>
# Si la whitelist hubiese fallado, aparecería:
#   level=warn msg="auth proxy header found but client IP not in whitelist" ...
```

### 10.7. Datasource Prometheus está provisioned y funciona

Tras login, la UI:

```
https://grafana.lan/connections/datasources
```

- Debe aparecer una entrada `Prometheus` con icono de candado (provisioned).
- Click en ella → botón `Test`. Esperado: "Successfully queried the Prometheus API".

Equivalente por API (con un service account token, opcional):

```bash
# Crear un service account temporal con admin via UI o:
# docker exec grafana grafana cli admin ... (no soportado en 11.x; se hace por UI)
# Por simplicidad, verificación visual en la UI es suficiente.
```

### 10.8. Dashboard "Prometheus 2.0 Stats" renderiza

```
https://grafana.lan/dashboards
```

- Debe aparecer "Prometheus 2.0 Stats" en la lista, con icono de provisioned.
- Abrirlo. Esperado: paneles "Uptime", "Local Storage Memory Series", "Scrape Failures", etc., todos con valores (no en error).
- Si algún panel muestra "Datasource not found": revisar §6.3.2 (la sustitución del placeholder `${DS_PROMETHEUS}` no se ejecutó correctamente).

### 10.9. Provisioning recarga al editar un dashboard

Para validar el flujo que usarán los siguientes docs:

```bash
# 1. Tocar el mtime de un dashboard sin cambiar contenido:
touch ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/prometheus-stats.json

# 2. Esperar 30s (updateIntervalSeconds del provider).

# 3. Confirmar en los logs que Grafana lo ha re-provisioned:
docker logs grafana --since 1m 2>&1 | grep -i provisioning
# Esperado: línea con "finished to provision dashboards"
```

### 10.10. Persistencia tras reboot

```bash
sudo reboot
# (esperar a que vuelva)

docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml ps
# Esperado: grafana (healthy), prometheus (healthy).

# El usuario creado por auth.proxy persiste en grafana.db (no se recrea al
# arrancar): hacer login otra vez y revisar el avatar.
```

### 10.11. Lista de Verificación

Antes de pasar a [`./03-node-exporter.md`](./03-node-exporter.md):

- [ ] `docker compose ps` en el stack `monitoring` → `grafana (healthy)` y `prometheus (healthy)`.
- [ ] `sudo ss -ltn | grep -E ':3000'` → vacío en el host.
- [ ] `https://grafana.lan` redirige a `auth.lan` para login + TOTP.
- [ ] Tras login, la home de Grafana carga **sin pedir login propio** (no aparece el formulario `/login`).
- [ ] Avatar arriba a la derecha muestra el `Remote-User` de Authelia.
- [ ] **Configuration → Data sources** muestra `Prometheus` con candado y `Test` devuelve éxito.
- [ ] **Dashboards → Browse** muestra "Prometheus 2.0 Stats" y todos sus paneles renderizan.
- [ ] `~/homelab/stacks/monitoring/grafana/{grafana.ini,provisioning/}` versionados en git; **`/mnt/hd2t/services/monitoring/grafana/data/` NO**.
- [ ] El bloque `grafana.lan` está en `~/homelab/stacks/proxy/Caddyfile` y `grafana.{{ env "LAN_DOMAIN" }}` en `access_control.rules` de Authelia.
- [ ] Pi-hole tiene el registro local `grafana.lan → 192.168.1.10`.
- [ ] Tocar un `.json` en `provisioning/dashboards/json/` aplica en ≤30 s sin reiniciar (§10.9).
- [ ] Tras `sudo reboot`, los contenedores arrancan y la UI sigue funcionando con el mismo usuario.

---

## 11. Backup

Estrategia que se concretará en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md). Lo que **debe respaldarse** del stack `monitoring` (parte Grafana):

| Ruta | Qué contiene | Frecuencia |
|---|---|---|
| `~/homelab/stacks/monitoring/grafana/grafana.ini` | Config principal (server, auth, dashboards, log...). | Versionado en git → `git push`. |
| `~/homelab/stacks/monitoring/grafana/provisioning/datasources/*.yml` | Datasources (Prometheus). | Versionado en git. |
| `~/homelab/stacks/monitoring/grafana/provisioning/dashboards/default.yml` | Provider de dashboards. | Versionado en git. |
| `~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/*.json` | Dashboards provisioned (Prometheus stats; los próximos los irán añadiendo otros docs). | Versionado en git. |
| `/mnt/hd2t/services/monitoring/.env` | Variables del stack, **incluye `GRAFANA_ADMIN_PASSWORD`** (secreto). | Borg con cifrado en repo. |
| `/mnt/hd2t/services/monitoring/grafana/data/grafana.db` | SQLite con usuarios (creados por auth.proxy), sesiones, dashboards "ad-hoc", anotaciones, favoritos, history de versiones. | Borg, **diaria**. |
| `/mnt/hd2t/services/monitoring/grafana/data/plugins/` | Plugins descargados (vacío inicialmente). | Borg, baja prioridad (reproducible vía `grafana-cli`). |
| `/mnt/hd2t/services/monitoring/grafana/data/png/` | Screenshots renderizados (caché). | **Excluir** del backup. |

> **El `.db` SQLite es el único fichero crítico**: contiene los dashboards que el operador haya creado "ad-hoc" en la UI (sin pasar por git), las anotaciones, las preferencias por usuario y el history de versiones. Si se pierde, los dashboards provisioned se reconstruyen solos al arrancar (vienen del git), pero los ad-hoc se pierden.

### 11.1. Snapshot consistente del SQLite (para Borgmatic)

SQLite no soporta backup en caliente con `cp` de forma fiable: si Grafana está escribiendo durante el `cp`, el fichero copiado puede ser inconsistente (aunque WAL minimiza el problema en SQLite moderno).

Procedimiento robusto, **no destructivo** (sin parar Grafana):

```bash
# 1. Snapshot consistente del SQLite mediante sqlite3 .backup (que usa el
#    BACKUP API de SQLite, sí soporta backup en caliente):
docker exec grafana sqlite3 /var/lib/grafana/grafana.db \
  ".backup '/var/lib/grafana/grafana.db.snapshot'"

# 2. El snapshot queda en el bind mount, accesible desde el host:
sudo ls -lh /mnt/hd2t/services/monitoring/grafana/data/grafana.db.snapshot

# 3. Mover/copiar a la ruta donde Borg espera dumps consistentes:
sudo install -d -o root -g root -m 700 /mnt/hd2t/backups/dumps
sudo mv /mnt/hd2t/services/monitoring/grafana/data/grafana.db.snapshot \
        /mnt/hd2t/backups/dumps/grafana-$(date +%F).db
```

> Borgmatic invocará este snapshot vía hook `before_backup` cuando se documente en [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md). Mientras tanto, una ejecución manual antes de upgrades mayores es suficiente.

### 11.2. Restore tras pérdida total

```bash
# 1. Reinstalar OS, Docker y red 'homelab' (Fases 0-2.2).
# 2. Restaurar repo de stacks desde git remote.
git clone <remote> ~/homelab

# 3. Restaurar /mnt/hd2t/services/monitoring/.env (Borg).
borg extract <repo>::<archivo> mnt/hd2t/services/monitoring/.env

# 4. Restaurar el árbol de datos:
borg extract <repo>::<archivo> mnt/hd2t/services/monitoring/grafana
sudo chown -R 472:472 /mnt/hd2t/services/monitoring/grafana/data

# 5. Levantar el stack:
cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d

# 6. Confirmar:
docker compose ps
docker logs grafana | tail -30
# Esperado: "Starting Grafana", "migrations completed" (idempotente),
#           "inserting datasource from configuration", "HTTP Server Listen"
```

> Tras el restore, el primer arranque puede correr migraciones de schema si el `.db` viene de un Grafana ligeramente más antiguo. Es seguro siempre que el upgrade sea dentro del mismo major (11.x → 11.y).

---

## 12. Operaciones cotidianas

### 12.1. Añadir un nuevo dashboard

Cada doc de la Fase 5 que despliegue un exporter dejará su dashboard `.json` en `~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/`. El procedimiento general:

```bash
# 1. Descargar (o crear) el JSON:
curl -fsSL "https://grafana.com/api/dashboards/<ID>/revisions/<REV>/download" \
  -o ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/<nombre>.json

# 2. Apuntar al UID del datasource:
sed -i 's/"\${DS_PROMETHEUS}"/"prometheus"/g' \
  ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/<nombre>.json

# 3. Eliminar __inputs/__elements/__requires (incompatibles con provisioning):
python3 - <<PY
import json
p = "$HOME/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/<nombre>.json"
d = json.load(open(p))
for k in ("__inputs", "__elements", "__requires"):
    d.pop(k, None)
json.dump(d, open(p, "w"), indent=2)
PY

# 4. Validar JSON:
python3 -c 'import json; json.load(open("'"$HOME"'/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/<nombre>.json")); print("OK")'

# 5. Esperar ≤30s al refresh del provider; o forzar con:
docker exec grafana sh -c 'touch /etc/grafana/provisioning/dashboards/default.yml' 2>/dev/null || true
# (si el FS root es read-only, el touch falla; bastará el refresh natural)

# 6. Confirmar en los logs:
docker logs grafana --since 1m 2>&1 | grep -i provisioning

# 7. git add, commit, push.
```

### 12.2. Crear un dashboard "ad-hoc" en la UI

```
https://grafana.lan/dashboards/new
```

Se guarda en `grafana.db` (no en git). Persiste tras reinicios; se respalda con el `.db` (§11). Para promoverlo a provisioned:

```bash
# 1. En la UI, exportar como JSON:
#    Share → Export → Save to file (toggle "Export for sharing externally" OFF
#    para mantener UIDs estables).
# 2. Mover el JSON a:
mv ~/Descargas/<nombre>.json \
   ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/

# 3. Aplicar el patrón de §12.1 (sed del placeholder + limpiar __inputs).
# 4. git add, commit.
```

### 12.3. Cambiar la contraseña del admin local

```bash
# Generar nueva contraseña:
NEW_PWD=$(openssl rand -base64 24)

# Actualizar el .env real:
sudo sed -i "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=${NEW_PWD}|" \
  /mnt/hd2t/services/monitoring/.env

# Recrear el contenedor (Grafana lee la env var, hashea y actualiza grafana.db):
cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate grafana

# Anotar en el password manager (Vaultwarden).
```

### 12.4. Bajar el nivel de log a `debug` para troubleshooting

```bash
# En ~/homelab/stacks/monitoring/grafana/grafana.ini, cambiar:
#   [log]
#   level = info
# por:
#   [log]
#   level = debug

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate grafana

# Tras diagnosticar: revertir y volver a recrear.
```

> `debug` produce mucha salida (cada query a Prometheus, cada provisioning refresh, cada push de métrica interna). Sólo para investigación puntual.

### 12.5. Acceso de emergencia con admin local (Authelia caído)

Si Authelia está caído y el operador necesita entrar a Grafana (típico: revisar dashboards de salud de los demás servicios para diagnosticar el corte):

```bash
# 1. Editar grafana.ini: cambiar
#    [auth]
#    disable_login_form = true
# por
#    disable_login_form = false

# 2. Recrear:
cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate grafana

# 3. Ir a https://grafana.lan/login (Caddy seguirá pidiendo cookie de Authelia,
#    así que Authelia debe estar OPERACIONAL para llegar al formulario).
#    Si Authelia está caído del todo, conectarse a Grafana:3000 vía docker exec
#    desde otro contenedor en homelab, o exponer temporalmente el puerto.

# 4. Login con admin / GRAFANA_ADMIN_PASSWORD del .env.

# 5. Tras resolver el incidente, revertir disable_login_form=true y recrear.
```

> **Caso límite**: si tanto Authelia como Caddy están caídos, el flujo de emergencia consiste en publicar `grafana:3000` al host temporalmente (`docker compose run` con `-p 127.0.0.1:3000:3000`, no en producción) y entrar por SSH tunneling desde un cliente. Documentado para completitud; en la práctica, los servicios Authelia/Caddy se restauran antes que se necesite Grafana.

### 12.6. Cambiar la retención de versiones de dashboards

```bash
# En ~/homelab/stacks/monitoring/grafana/grafana.ini, ajustar:
#   [dashboards]
#   versions_to_keep = 50    # de 20 a 50

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate grafana
```

> Bajar el valor borra versiones antiguas en el siguiente vacuum del SQLite (cron interno de Grafana, ~24 h). Subirlo no afecta a versiones ya purgadas.

### 12.7. Upgrade manual

```bash
# Antes de cambiar el tag, leer:
# https://grafana.com/docs/grafana/latest/whatsnew/

sudo sed -i 's|^GRAFANA_IMAGE_TAG=.*|GRAFANA_IMAGE_TAG=11.4.1|' \
  /mnt/hd2t/services/monitoring/.env

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env pull grafana
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate grafana

# Verificar:
docker exec grafana grafana --version 2>/dev/null || docker exec grafana sh -c 'grafana cli -v'
docker logs grafana | tail -30
# Esperado: "migrations completed performed=N" (puede ser 0 si no hubo cambios de schema).
```

> Watchtower **sí** actualiza Grafana automáticamente a las 04:00 si el tag tiene una nueva digest. Patches (11.4.0 → 11.4.1) son seguros: no hay migraciones de schema entre patches. Para minors (11.4 → 11.5) y majors (11.x → 12.x), el upgrade manual permite leer el changelog antes.

### 12.8. Upgrade a Grafana 12.x (variante futura)

Cuando se decida cruzar a 12.x:

1. Leer la guía oficial: https://grafana.com/docs/grafana/latest/whatsnew/.
2. Cambios incompatibles a vigilar:
   - Eliminación de plugins legacy basados en Angular (la mayoría ya migrados).
   - Cambios en el formato de provisioning v1 → v2 (improbable a corto plazo).
   - Renombrado de feature flags experimentales (`feature_toggles`).
3. Snapshot del SQLite (§11.1).
4. Poner `watchtower.enable=false` mientras dura la migración.
5. Cambiar el tag a `12.x.y`, `up -d --force-recreate grafana`, validar dashboards y datasource.
6. Re-activar Watchtower si todo funciona.

---

## 13. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `docker compose up grafana` falla con `network homelab declared as external, but could not be found` | La red `homelab` no está creada. | Crearla según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2. |
| `grafana` arranca pero entra en `(unhealthy)`; logs muestran `GF_PATHS_DATA='/var/lib/grafana' is not writable` | El bind mount de datos no es escribible por UID 472. | `sudo chown -R 472:472 /mnt/hd2t/services/monitoring/grafana/data && sudo chmod 750 /mnt/hd2t/services/monitoring/grafana/data` (§3.3). |
| `grafana` en bucle de crash; logs muestran `Failed to read config from /etc/grafana/grafana.ini: ...` | Sintaxis del `.ini` inválida o sección desconocida. | Validar manualmente en otro Grafana (§7.2) o quitar la sección sospechosa y volver a probar. |
| `https://grafana.lan` da 502 Bad Gateway desde Caddy | Grafana no está sano o no resuelve por nombre desde Caddy. | `docker exec caddy wget -qO- http://grafana:3000/api/health`; si falla, `docker inspect grafana --format '{{json .NetworkSettings.Networks}}'` debe listar `homelab`. |
| `https://grafana.lan` redirige a `auth.lan`, login OK, vuelve a `grafana.lan` y aparece el **formulario de login local** de Grafana | `auth.proxy` no está activo, **o** Grafana no recibe la cabecera `Remote-User`, **o** la IP origen de Caddy no está en la whitelist. | (1) `docker exec grafana env \| grep AUTH_PROXY`: verificar que `GF_AUTH_PROXY_WHITELIST` está en el CIDR correcto. (2) `docker logs grafana \| grep -i auth.proxy`: buscar `client IP not in whitelist`; si aparece, ampliar el CIDR. (3) Verificar que el snippet `authelia_proxy` en Caddy reenvía `Remote-User` (cf. [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §9.1). |
| Tras login, el avatar muestra el **email** en lugar del nombre, o muestra "Anonymous" | El `auto_sign_up` falló en mapear `Remote-Email` o `Remote-Name`. | Revisar `[auth.proxy] headers = Email:Remote-Email Name:Remote-Name Groups:Remote-Groups` en `grafana.ini`. La sintaxis es estricta: `<grafanaProperty>:<Header-Name>` separados por espacios. |
| El dashboard "Prometheus 2.0 Stats" aparece pero los paneles muestran "Datasource not found" | Los `${DS_PROMETHEUS}` del JSON no se sustituyeron por el UID `prometheus`. | Aplicar §6.3.2 (`sed` y limpieza de `__inputs`). Tras editar el JSON, esperar ≤30s al refresh del provider. |
| El datasource Prometheus aparece pero **Test** falla con "HTTP error: dial tcp: lookup prometheus on ...: no such host" | Grafana no está en la red `homelab`. | `docker inspect grafana --format '{{json .NetworkSettings.Networks}}'` debe listar `homelab`. Si no, el `networks: [homelab]` del compose se está omitiendo; recrear el contenedor. |
| El datasource Prometheus aparece pero **Test** falla con "HTTP error: connection refused" | Prometheus está caído o el container_name es distinto. | `docker compose ps` debe mostrar `prometheus` (no `monitoring-prometheus-1`). Si está mal, revisar `container_name: prometheus` en `./01-prometheus.md` §5. |
| Los dashboards provisioned no se actualizan al editar el JSON en disco | El `updateIntervalSeconds` aún no ha pasado, o el bind mount está montado en otra ruta. | Esperar 30s; si no cambia, `docker exec grafana ls /etc/grafana/provisioning/dashboards/json/` debe listar el JSON editado con el nuevo mtime. |
| `grafana.db` no se respalda con Borg (queda inconsistente al restaurar) | `cp` directo del `.db` mientras Grafana escribe deja el WAL desligado. | Usar el procedimiento §11.1 con `sqlite3 .backup` (BACKUP API). Borgmatic se documentará con un hook `before_backup` que ejecuta este comando. |
| La UI de Grafana es muy lenta al cargar Node Exporter Full (cuando se active en `./03-node-exporter.md`) | Demasiados paneles concurrentes contra Prometheus, scrape interval bajo, o queries pesadas. | Verificar que `timeInterval: 30s` está en el datasource (§5). Si persiste, bajar la "time range" del dashboard a "Last 1 hour". El comportamiento es esperable en una Pi 5 con dashboards de >50 paneles. |
| `auto_assign_org_role=Editor` y aparece un usuario `Viewer` en su lugar | Un grupo en `Remote-Groups` está mapeado a `Viewer` por una regla más específica, o el usuario fue creado antes de cambiar la config. | Revisar el usuario en **Server Admin → Users** y forzar el rol manualmente (en OSS no hay role mapping declarativo desde groups). |
| Tras un upgrade, la BD muestra error `database disk image is malformed` | SQLite corrupto, típico tras un crash sin sync. | Restaurar el último snapshot (§11.1) o, en último recurso, `docker exec grafana sqlite3 /var/lib/grafana/grafana.db .recover > /tmp/recovered.sql && sqlite3 nuevo.db < /tmp/recovered.sql`, luego reemplazar el fichero. |
| El logout en Grafana redirige a `/login` y muestra el formulario | `disable_login_form=true` no está aplicado (recargado), o `disable_signout_menu=false` y el operador hizo logout local. | Cerrar la pestaña y abrir `https://auth.lan/logout` para terminar la sesión Authelia; en la siguiente visita a `grafana.lan`, el flujo de login arranca de cero. |
| Watchtower actualiza Grafana de 11.x a 12.x y los dashboards dejan de funcionar | Cruce de major aplicado por Watchtower sin pasar por la guía de migración. | Bajar el tag a la versión anterior en el `.env` y `up -d --force-recreate grafana`; dejar `watchtower.enable=false` hasta acabar el upgrade manual (§12.8). |

---

## Referencias

- [Grafana — Documentación oficial](https://grafana.com/docs/grafana/latest/)
- [Grafana — `grafana.ini` (todas las opciones)](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/)
- [Grafana — Override de config con env vars (`GF_<SECTION>_<KEY>`)](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/#override-configuration-with-environment-variables)
- [Grafana — Provisioning de datasources](https://grafana.com/docs/grafana/latest/administration/provisioning/#data-sources)
- [Grafana — Provisioning de dashboards](https://grafana.com/docs/grafana/latest/administration/provisioning/#dashboards)
- [Grafana — Auth Proxy authentication](https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/auth-proxy/)
- [Grafana — Imagen Docker oficial OSS](https://hub.docker.com/r/grafana/grafana-oss)
- [Grafana — Source y CHANGELOG (GitHub)](https://github.com/grafana/grafana)
- [Dashboard Prometheus 2.0 Stats (Grafana.com #3662)](https://grafana.com/grafana/dashboards/3662-prometheus-2-0-stats/)
- [Dashboard Node Exporter Full (Grafana.com #1860) — se activará en `./03-node-exporter.md`](https://grafana.com/grafana/dashboards/1860-node-exporter-full/)
- [Dashboard Docker / cAdvisor (Grafana.com #14282) — se activará en `./04-cadvisor.md`](https://grafana.com/grafana/dashboards/14282-cadvisor-exporter/)
- [Caddy — `reverse_proxy` y `forward_auth`](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [Authelia — `forward_auth` y cabeceras Remote-*](https://www.authelia.com/integration/proxies/caddy/)
- [SQLite — BACKUP API](https://www.sqlite.org/backup.html)
