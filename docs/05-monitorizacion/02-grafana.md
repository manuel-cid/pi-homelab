# Grafana

## Descripción

Con `01-prometheus.md` desplegado, el homelab ya **recoge y almacena** métricas, pero la única forma de consultarlas es la UI mínima de Prometheus (PromQL en una caja de texto, una gráfica monocroma, sin paneles persistentes ni vista comparativa). Es suficiente para depurar pero inútil como termómetro diario: nadie va a abrir `https://prometheus.lan/graph` cada mañana para teclear `node_load1` y compararlo con la temperatura del SoC.

Este documento despliega **Grafana** como capa de visualización del homelab. Su rol concreto:

1. **Conectar a Prometheus** (`prometheus:9090` en la red Docker `homelab`) como datasource por defecto, **provisionado por código** (sin clicks en la UI; el datasource queda definido en `provisioning/datasources/prometheus.yml`).
2. **Cargar un conjunto fijo de dashboards** mediante *file provisioning*: Node Exporter Full (sistema operativo, temperatura del SoC), cAdvisor (recursos por contenedor), Prometheus 2.0 Stats (salud del propio scrape engine), Caddy y un dashboard "Homelab Overview" propio que reúne lo más relevante en una sola pestaña. Todos los dashboards viven en el repositorio como JSON y se materializan al arrancar.
3. **Delegar autenticación a Authelia** mediante `auth.proxy`: Grafana confía en la cabecera `Remote-User` que inyecta Caddy tras la verificación de Authelia. Sin login local visible (formulario deshabilitado), sin contraseñas duplicadas, sin gestión de usuarios paralela. Hay un *escape hatch* documentado para acceso de emergencia.
4. **Persistir su estado en `hd2t`**: SQLite con dashboards modificados ad-hoc, anotaciones manuales, preferencias de usuario. La SQLite es respaldable, ligera y suficiente para 1–3 usuarios.

Lo que este documento **no** decide:

- **Alerting de Grafana** (Unified Alerting, contact points, notification policies). El homelab cubre availability con `05-uptime-kuma.md` y deja Alertmanager (en Prometheus) como decisión reabrible. Activar Unified Alerting en Grafana significa duplicar contact points y mantener dos motores: se descarta hoy.
- **Renderizado de gráficas** (`grafana-image-renderer`): permite generar PNG de paneles para enviar por email/Telegram. Útil con alerting; sin alerting es ceremonia. Reabrible cuando se decida desplegar notificaciones gráficas.
- **Plugins externos** (Worldmap, AlertManager UI, Loki datasource). Hoy Grafana solo necesita el datasource Prometheus, que viene de serie. Loki entraría con `06-dozzle.md` si se decide añadir agregación de logs (Dozzle no la requiere).
- **Backend en PostgreSQL/MySQL**: SQLite escala perfectamente para 1–3 usuarios y unos 20 dashboards. Migrar a Postgres añade un servicio más sin beneficio operativo.
- **OAuth nativo (GitHub, Google, OIDC)**: redundante con Authelia + `auth.proxy`. Reabrible si en el futuro se quiere acceso desde clientes que no pasan por Caddy (no hay caso de uso hoy).

Cuando este documento se haya aplicado, el operador puede:

- Abrir `https://grafana.${DOMAIN_LAN}/` desde la LAN (con login Authelia 2FA), aterrizar **directamente** en el dashboard "Homelab Overview" sin formulario de Grafana.
- Ver paneles de "Node Exporter Full" funcionando si `03-node-exporter.md` está desplegado, o vacíos (`No data`) si todavía no, lo cual es **el comportamiento esperado** y sirve de checklist visual igual que los targets `down` en Prometheus.
- Crear dashboards ad-hoc desde la UI; quedan en SQLite y respaldados por Borg.
- Ajustar `provisioning/dashboards/*.json` en git, materializar y reiniciar Grafana sin perder personalizaciones (los dashboards provisionados son `editable: true` pero `allowUiUpdates: false` por defecto, ver "Decisión: provisioning vs UI").

> **Recordatorio de alcance**: Grafana escucha **solo** en la red Docker `homelab`; no publica `ports:` al host. Solo se accede a la UI a través de Caddy. La cabecera `Remote-User` que activa `auth.proxy` se acepta **únicamente** desde el rango interno de la red Docker (`172.30.10.0/24`), evitando que un cliente directo pudiera autenticarse falsificando la cabecera.

---

## Requisitos Previos

- **Fase 2** completa (Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN=lan`).
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre automáticamente `grafana.${DOMAIN_LAN}`).
  - Caddy con los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` y la disponibilidad de `(authelia_two_factor)` desde `04-seguridad/01-authelia.md`.
- **Fase 4** completa: Authelia desplegado, sesiones cookie en `.lan`, política `default_policy: deny`.
- **`01-prometheus.md` aplicado**: Grafana resuelve `prometheus:9090` por DNS Docker y necesita que el target esté `up` para que los dashboards muestren algo.
- Disco `hd2t` montado en `/mnt/hd2t` con al menos **2 GiB** libres reservados para Grafana (SQLite, plugins, sesiones).
- Operador con la **CA interna instalada** en su navegador (`03-red/04-caddy.md`).

Comprobaciones rápidas:

```bash
# La red Docker compartida existe
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Prometheus está corriendo
docker ps --filter name=prometheus --format '{{.Names}} {{.Status}}'
# prometheus  Up 1 day (healthy)

# grafana.lan resuelve al IP de la Pi
dig +short grafana.lan @192.168.1.2
# 192.168.1.10

# Espacio en hd2t
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'
# 1.6T libres
```

---

## Decisión: imagen y versión

Grafana publica dos imágenes oficiales:

- `grafana/grafana` — Enterprise (incluye módulos de pago bajo licencia comercial; sin licencia, equivalente a OSS pero con la carga del binario Enterprise).
- `grafana/grafana-oss` — exclusivamente Open Source, sin código Enterprise.

Para un homelab sin contrato comercial la diferencia operativa es nula, pero **`grafana-oss`** elimina sorpresas (telemetría Enterprise, banners de "upgrade") y ahorra ~50 MiB de imagen. Es la elección.

| Tag | Cuándo usar | Decisión aquí |
|---|---|---|
| `latest` | Demos. | Descartado (convención de Fase 2). |
| `11` | Última 11.x. | Descartado: las minors han traído cambios en plugins y Unified Alerting. |
| `11.3` | Última 11.3.x. | Aceptable; Grafana es estable bumpeando patch. |
| `11.3.0` (ejemplo) | Versión exacta `MAYOR.MENOR.PARCHE`. | **Aceptado** como compromiso entre reproducibilidad y mantenimiento. |
| `12.x` | Saltar a la rama 12.x cuando estabilice. | Diferido si en el momento de aplicar este documento sigue siendo `release candidate`. |

> **Tag exacto en uso**: `grafana/grafana-oss:11.3.0`. Si en el momento de aplicar el documento existe una `11.3.x` superior con changelog limpio (sin cambios en provisioning ni en `auth.proxy`), se actualiza el tag aquí y en `docker-compose.yml`. **Nunca `latest`**.

> **Por qué Grafana y no Chronograf / Kibana / Perses**. Chronograf está enganchado a InfluxDB y muerto desde 2022. Kibana exige Elasticsearch (un stack pesado). Perses es la nueva apuesta de la CNCF pero todavía joven y sin la biblioteca masiva de dashboards comunitarios que Grafana atesora (los IDs `1860`, `193`, `14282` que se importan abajo *son* la razón principal de elegir Grafana). Para un homelab gana la madurez del ecosistema.

---

## Decisión: autenticación (auth.proxy vs login local vs OAuth)

Grafana ofrece varios mecanismos de autenticación:

| Mecanismo | Pros | Contras | Veredicto |
|---|---|---|---|
| **Login local** (admin / password) | Simple, funciona en aislado. | Duplicación de credenciales con Authelia; el operador acaba con dos usuarios y dos contraseñas en el mismo navegador. | Descartado como flujo principal; **mantenido como escape hatch** para emergencias. |
| **OAuth/OIDC contra Authelia** | Estándar, soporta scopes y groups. | Requiere desplegar el endpoint OIDC de Authelia (no activado en `04-seguridad/01-authelia.md`) y configurar un cliente más; más superficie por mantener. | Reabrible si llegan servicios fuera del reverse proxy. |
| **`auth.proxy` con cabecera `Remote-User`** | Cero duplicación: la sesión Authelia ya verificada en Caddy se traduce en sesión Grafana. Provisioning de usuarios automático. | Requiere confiar **únicamente** en peticiones que entren por Caddy (`whitelist` de IPs Docker); si alguien accede directo al puerto 3000 puede forjar la cabecera. | **Aceptado**: el contenedor no publica `ports:`, solo se llega vía Caddy. |

Resultado: `auth.proxy` con `header_name: Remote-User`, `whitelist: 172.30.10.0/24`, login form **deshabilitado**. Authelia inyecta `Remote-User`, `Remote-Email`, `Remote-Name`, `Remote-Groups` en el `forward_auth` (snippet `(authelia_two_factor)`); Caddy las propaga; Grafana las lee.

> **Escape hatch**. Si un día Authelia está roto y hay que tocar Grafana (cambiar un datasource, mirar un dashboard), el formulario local se reactiva temporalmente con `GF_AUTH_DISABLE_LOGIN_FORM=false` y `docker compose up -d` (15 s). Login con `admin` / contraseña del `.env`. Tras el incidente, restaurar el flag a `true`.

> **Auto sign-up**. `GF_AUTH_PROXY_AUTO_SIGN_UP=true` crea usuarios Grafana al vuelo la primera vez que llegan con `Remote-User`. Para 1–3 personas en casa esto significa que cada quien obtiene su propio espacio (preferencias, dashboards favoritos) sin trabajo administrativo. El primer usuario que acceda con `Remote-Groups: admins` (definido en Authelia) hereda el rol `Admin`.

---

## Decisión: provisioning vs UI

Grafana permite definir datasources y dashboards de tres formas:

| Forma | Pros | Contras | Veredicto |
|---|---|---|---|
| **UI** (clicks, "Save"). | Cómodo para experimentar. | El estado vive en SQLite; tras `docker compose down -v` se pierde. | Aceptado para experimentación, no para configuración base. |
| **API HTTP** (`POST /api/datasources`). | Programable. | Requiere coordinar token + idempotencia; reinventar provisioning. | Descartado. |
| **File provisioning** (`/etc/grafana/provisioning/{datasources,dashboards}/*.{yml,json}`). | Versionado en git, reproducible, auditable. | Los dashboards provisionados muestran un banner "This dashboard is provisioned" si se intentan editar; se documenta cómo "trasladar" un dashboard provisionado a editable manual. | **Aceptado** como fuente de verdad. |

Resultado: **datasource Prometheus + 5 dashboards base** se materializan vía file provisioning. Los dashboards se exportan desde `https://grafana.com/grafana/dashboards/` como JSON y se versionan en `stacks/grafana/provisioning/dashboards/json/`. Los dashboards "ad-hoc" creados desde la UI viven en SQLite y se respaldan con Borg.

```text
allowUiUpdates: false   # cambios en UI sobre dashboards provisionados se descartan al reiniciar.
editable: true          # se pueden modificar para *experimentar* (botón "Save as..." crea una copia editable).
disableDeletion: true   # prohíbe borrar dashboards provisionados desde la UI.
```

Esta combinación protege la línea base sin paralizar la experimentación: el operador puede tocar un panel para probar una query, ver el resultado y hacer "Save as..." para conservarlo en un nuevo dashboard editable.

---

## Decisión: backend (SQLite) y dónde vive

Grafana soporta SQLite, MySQL y PostgreSQL como backend de su base de datos interna (usuarios, dashboards ad-hoc, anotaciones). Para un homelab:

| Backend | Pros | Contras | Veredicto |
|---|---|---|---|
| **SQLite** (default) | Cero dependencias, fichero único respaldable. | Concurrencia limitada (1 escritor a la vez). | **Aceptado**: 1–3 usuarios, escrituras esporádicas. |
| PostgreSQL | Concurrencia, joins, reporting. | Servicio extra, backup separado. | Reabrible cuando llegue Postgres por otro servicio. |
| MySQL | Idem. | Idem. | Descartado. |

La SQLite vive en `/mnt/hd2t/apps/grafana/data/grafana.db`. Owner UID `472` (usuario `grafana` interno de la imagen oficial).

> **Por qué no microSD**. La SQLite hace `fsync()` en cada commit de transacción. En la SD-card del Pi 5 esto es un drama de IOPS y desgaste; en `hd2t` con USB 3.0 es invisible.

---

## Decisión: anonymous, sign-up y org

| Setting | Valor | Razón |
|---|---|---|
| `GF_AUTH_ANONYMOUS_ENABLED` | `false` | El homelab es solo LAN+Tailscale, pero tras Authelia: nadie debe ver Grafana sin `Remote-User`. |
| `GF_USERS_ALLOW_SIGN_UP` | `false` | Sign-up vía `auth.proxy`, no auto-registro libre. |
| `GF_USERS_AUTO_ASSIGN_ORG` | `true` | Todos los usuarios entran a la org `Main Org.`. Con 1–3 usuarios no hace falta multi-org. |
| `GF_USERS_AUTO_ASSIGN_ORG_ROLE` | `Viewer` | Default seguro; `auth.proxy` lo eleva a `Admin` para usuarios con `Remote-Groups: admins`. |
| `GF_USERS_DEFAULT_THEME` | `dark` | Estética de homelab. |
| `GF_NEWS_NEWS_FEED_ENABLED` | `false` | Quita el panel "Latest from the blog" en la home. |
| `GF_ANALYTICS_REPORTING_ENABLED` | `false` | Sin telemetría a Grafana Labs. |
| `GF_ANALYTICS_CHECK_FOR_UPDATES` | `false` | Updates se gestionan via Watchtower / commits, no via UI. |

---

## Stack: `stacks/grafana/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/grafana/docker-compose.yml` | microSD (git) | Stack (servicio `grafana`). |
| `stacks/grafana/.env.example` | microSD (git) | Plantilla con `GF_SECURITY_ADMIN_PASSWORD` (generada al desplegar). |
| `stacks/grafana/provisioning/datasources/prometheus.yml` | microSD (git) | Datasource provisionado. |
| `stacks/grafana/provisioning/dashboards/dashboards.yml` | microSD (git) | Provider que carga JSON desde `dashboards/json/`. |
| `stacks/grafana/provisioning/dashboards/json/*.json` | microSD (git) | Dashboards versionados. |
| `stacks/caddy/conf.d/03-grafana.caddy` | microSD (git) | Drop-in del bloque LAN para `grafana.${DOMAIN_LAN}`. |
| `/mnt/hd2t/apps/grafana/etc/provisioning/` | hd2t | Provisioning materializado (bind mount `:ro`). |
| `/mnt/hd2t/apps/grafana/data/` | hd2t | SQLite (`grafana.db`), plugins instalados, sesiones, png renderizados. Owner `472:472`. |
| `/mnt/hd2t/apps/grafana/logs/` | hd2t | Logs de Grafana (rotación interna). Owner `472:472`. |

### `stacks/grafana/docker-compose.yml`

```yaml
# Grafana — capa de visualización del homelab.
# Documentado en docs/05-monitorizacion/02-grafana.md.

name: grafana

services:
  grafana:
    image: grafana/grafana-oss:11.3.0
    container_name: grafana
    hostname: grafana
    restart: unless-stopped

    # No publica `ports:` al host: solo accesible vía Caddy y vía red `homelab`.
    expose:
      - "3000"

    user: "472:472"   # UID/GID del usuario `grafana` en la imagen oficial.

    environment:
      TZ: ${TZ}

      # --- Servidor / URL pública ---
      GF_SERVER_ROOT_URL: "https://grafana.${DOMAIN_LAN}/"
      GF_SERVER_DOMAIN: "grafana.${DOMAIN_LAN}"
      GF_SERVER_SERVE_FROM_SUB_PATH: "false"
      GF_SERVER_ENFORCE_DOMAIN: "false"   # 'false' porque Caddy reescribe Host.

      # --- Seguridad / cookies ---
      GF_SECURITY_ADMIN_USER: "admin"
      GF_SECURITY_ADMIN_PASSWORD__FILE: "/run/secrets/grafana_admin_password"
      GF_SECURITY_COOKIE_SECURE: "true"
      GF_SECURITY_COOKIE_SAMESITE: "lax"
      GF_SECURITY_DISABLE_GRAVATAR: "true"
      GF_SECURITY_ALLOW_EMBEDDING: "false"

      # --- auth.proxy (Authelia inyecta Remote-User vía Caddy) ---
      GF_AUTH_DISABLE_LOGIN_FORM: "true"
      GF_AUTH_DISABLE_SIGNOUT_MENU: "false"
      GF_AUTH_ANONYMOUS_ENABLED: "false"
      GF_AUTH_PROXY_ENABLED: "true"
      GF_AUTH_PROXY_HEADER_NAME: "Remote-User"
      GF_AUTH_PROXY_HEADER_PROPERTY: "username"
      GF_AUTH_PROXY_AUTO_SIGN_UP: "true"
      GF_AUTH_PROXY_HEADERS: "Email:Remote-Email Name:Remote-Name Groups:Remote-Groups"
      GF_AUTH_PROXY_SYNC_TTL: "60"
      # IMPORTANTE: solo confiar en la cabecera si la petición viene de la red Docker.
      GF_AUTH_PROXY_WHITELIST: "172.30.10.0/24"

      # --- Usuarios / org ---
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_USERS_AUTO_ASSIGN_ORG: "true"
      GF_USERS_AUTO_ASSIGN_ORG_ROLE: "Viewer"
      GF_USERS_DEFAULT_THEME: "dark"

      # --- Analytics / news (off) ---
      GF_NEWS_NEWS_FEED_ENABLED: "false"
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"

      # --- Logging ---
      GF_LOG_MODE: "console file"
      GF_LOG_LEVEL: "info"

    secrets:
      - grafana_admin_password

    volumes:
      - /mnt/hd2t/apps/grafana/etc/provisioning:/etc/grafana/provisioning:ro
      - /mnt/hd2t/apps/grafana/data:/var/lib/grafana
      - /mnt/hd2t/apps/grafana/logs:/var/log/grafana

    networks:
      - homelab

    healthcheck:
      # /api/health responde 200 con JSON cuando Grafana está listo.
      test: ["CMD-SHELL", "wget -q -O - http://127.0.0.1:3000/api/health | grep -q '\"database\": \"ok\"'"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

    depends_on:
      # Grafana arranca aunque Prometheus esté caído; depends_on no usa healthcheck
      # adrede, para no acoplar ciclos de vida (Grafana puede servir dashboards sin
      # datos durante un fallo temporal de Prometheus).
      - {}

    labels:
      homelab.role: "metrics-ui"
      homelab.backup: "true"   # SQLite y provisioning materializado merecen Borg.
      com.centurylinklabs.watchtower.enable: "true"

secrets:
  grafana_admin_password:
    file: ./secrets/admin_password.txt

networks:
  homelab:
    external: true
```

> **Sobre `GF_AUTH_PROXY_WHITELIST`**. Es la pieza clave de la decisión de auth: Grafana solo confía en `Remote-User` si la petición proviene de una IP del rango Docker. Como el contenedor no publica `ports:` al host, la única forma de llegar a `:3000` es desde dentro de la red `homelab` (Caddy hace `reverse_proxy http://grafana:3000`), y desde ahí la IP origen es siempre `172.30.10.x`. Si en el futuro alguien añade un `ports: ["3000:3000"]` por error, Grafana **rechazará** las conexiones directas LAN porque `192.168.1.x` no está en la whitelist; la cabecera `Remote-User` se ignora, no hay login form, y el usuario ve un 401. Defensa en profundidad.

> **Sobre `depends_on: - {}`**: el `depends_on` está intencionadamente neutralizado (Compose lo ignora si está vacío). En versiones de Compose más estrictas, eliminar la clave por completo. La intención es **documentar** que se ha pensado en la dependencia y se ha rechazado; Grafana arrancando antes que Prometheus es perfectamente válido.

> **Sobre `secrets:`**. Compose v2 soporta `file:` para secretos: el contenido del fichero se monta en `/run/secrets/<name>` con permisos `0400`. Grafana lee la contraseña admin con la variante `__FILE` (`GF_SECURITY_ADMIN_PASSWORD__FILE`), evitando que la password aparezca en `docker inspect` o `docker compose config`.

### `stacks/grafana/.env.example`

```bash
# stacks/grafana/.env.example
# Variables específicas del stack Grafana. Las generales (TZ, DOMAIN_LAN, PUID, PGID)
# vienen del .env GLOBAL del homelab.
#
# Este stack no expone variables de entorno propias en .env: la contraseña admin
# se gestiona como secret en stacks/grafana/secrets/admin_password.txt
# (NO versionado; ver .gitignore).
```

### `stacks/grafana/secrets/admin_password.txt` (NO versionado)

```bash
# Generar al desplegar:
openssl rand -base64 32 > stacks/grafana/secrets/admin_password.txt
chmod 0600 stacks/grafana/secrets/admin_password.txt
# Guardar la contraseña en el gestor de secretos del operador (KeePassXC, Bitwarden).
```

Añadir `stacks/grafana/secrets/` al `.gitignore` raíz si no lo está ya (la convención global del homelab ya excluye `secrets/`).

### `stacks/grafana/provisioning/datasources/prometheus.yml`

```yaml
# Datasource Prometheus provisionado para Grafana.
# Documentado en docs/05-monitorizacion/02-grafana.md.

apiVersion: 1

datasources:
  - name: Prometheus
    uid: homelab-prometheus      # UID estable: los dashboards JSON lo referencian.
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false              # cambios desde la UI se descartan al reiniciar.
    jsonData:
      timeInterval: "30s"        # alineado con scrape_interval de prometheus.yml.
      httpMethod: POST           # POST permite queries largas (>2 KB de PromQL).
      manageAlerts: false        # alerting de Grafana deshabilitado (ver "Decisiones").
      prometheusType: Prometheus
      prometheusVersion: 2.55.1
```

> **Sobre `uid`**. Si los dashboards JSON referencian la datasource por nombre (`"datasource": "Prometheus"`) la importación funciona pero es frágil: renombrar la datasource rompe los dashboards. Referenciar por UID estable (`"datasource": {"type": "prometheus", "uid": "homelab-prometheus"}`) sobrevive a renombrados.

### `stacks/grafana/provisioning/dashboards/dashboards.yml`

```yaml
# Provider que carga dashboards JSON desde un directorio.
# Documentado en docs/05-monitorizacion/02-grafana.md.

apiVersion: 1

providers:
  - name: 'homelab'
    orgId: 1
    folder: 'Homelab'
    folderUid: homelab
    type: file
    disableDeletion: true        # prohíbe borrar desde la UI dashboards provisionados.
    allowUiUpdates: false        # cambios en UI no persisten (al reiniciar, se restauran).
    editable: true               # se pueden editar para experimentar; "Save as..." crea copia.
    updateIntervalSeconds: 30    # Grafana revisa la carpeta cada 30s.
    options:
      path: /etc/grafana/provisioning/dashboards/json
      foldersFromFilesStructure: true
```

### `stacks/grafana/provisioning/dashboards/json/`

Esta carpeta contiene los JSON de los dashboards base. **No se incluye su contenido en este documento** (cada uno son varios miles de líneas), pero se documenta exactamente cuáles y de dónde se importan:

| Fichero | Origen | ID | Notas |
|---|---|---|---|
| `01-homelab-overview.json` | propio | — | Panel único con CPU, RAM, disco, temperatura SoC, top 5 contenedores por CPU, contadores Pi-hole. Se construye en la UI ("Save as JSON") al final de Fase 5 cuando los exporters estén operativos. |
| `02-node-exporter-full.json` | grafana.com | **1860** | "Node Exporter Full" — el dashboard de referencia para Linux. Incluye paneles de temperatura via `node_hwmon_temp_celsius`, perfectos para vigilar el SoC del Pi 5. |
| `03-cadvisor-docker.json` | grafana.com | **14282** | "Cadvisor exporter" — recursos por contenedor (CPU, RAM, red, disco). Alternativa: `193`. |
| `04-prometheus-stats.json` | grafana.com | **3662** | "Prometheus 2.0 Stats" — salud del propio scrape engine. |
| `05-caddy.json` | grafana.com | **20802** | "Caddy" — latencias y códigos HTTP por host. Si en el momento de aplicar este documento `04-caddy.md` aún no expone `/metrics`, este dashboard mostrará "No data" hasta que se active. |

> **Cómo importar un dashboard de grafana.com como JSON local**.
>
> 1. Visitar `https://grafana.com/grafana/dashboards/1860`.
> 2. Click en "Download JSON" (o copiar el ID en la sección "Import" de Grafana, hacer "Load", "Save as JSON").
> 3. Editar el JSON: reemplazar el `datasource` (que viene como `"${DS_PROMETHEUS}"`) por el UID estable `homelab-prometheus`. Eliminar el bloque `__inputs` y `__requires` del JSON (artefactos de la importación interactiva).
> 4. Guardar en `stacks/grafana/provisioning/dashboards/json/02-node-exporter-full.json`.
>
> Este flujo se ejecuta una vez al cerrar el documento. Los JSON resultantes quedan versionados en git como cualquier otro código del homelab.

### Drop-in de Caddy: `stacks/caddy/conf.d/03-grafana.caddy`

```caddy
# /etc/caddy/conf.d/03-grafana.caddy — bloque LAN para Grafana.
# Documentado en docs/05-monitorizacion/02-grafana.md.

grafana.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck
    import authelia_two_factor    # Grafana confía en Remote-User vía auth.proxy.

    reverse_proxy http://grafana:3000 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # Las cabeceras Remote-* las inyecta el snippet (authelia_two_factor)
        # tras un /api/verify exitoso. Aquí solo se preservan tal cual.
        # Si por alguna razón el snippet no las propagase, descomentar:
        # header_up Remote-User       {http.request.header.Remote-User}
        # header_up Remote-Email      {http.request.header.Remote-Email}
        # header_up Remote-Name       {http.request.header.Remote-Name}
        # header_up Remote-Groups     {http.request.header.Remote-Groups}
    }
}
```

> **Por qué `two_factor` y no `one_factor`**. Grafana es de solo lectura *visual*, pero su API permite crear/borrar dashboards, ajustar datasources e incluso ejecutar queries arbitrarias contra Prometheus (lo que en la práctica es leer todas las métricas del homelab). TOTP eleva el coste de un compromiso de credenciales y se alinea con la política deny-by-default de Authelia.

> **Y `access_control` en Authelia**. Recordar añadir `grafana.${DOMAIN_LAN}` al bloque `two_factor` de `configuration.yml` de Authelia (`04-seguridad/01-authelia.md`); con `default_policy: deny`, no listarlo equivale a denegar acceso aunque el `forward_auth` se importe. Cambio mínimo, recargable en caliente.

### Crear los directorios persistentes y desplegar

```bash
# Directorios de configuración (provisioning materializado)
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/grafana
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/grafana/etc
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/grafana/etc/provisioning
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/grafana/etc/provisioning/datasources
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/grafana/etc/provisioning/dashboards
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/grafana/etc/provisioning/dashboards/json

# Directorios de datos: UID/GID 472 (usuario `grafana` interno).
sudo install -d -o 472 -g 472 -m 0750 /mnt/hd2t/apps/grafana/data
sudo install -d -o 472 -g 472 -m 0750 /mnt/hd2t/apps/grafana/logs

# Materializar provisioning desde la versión en git
cd /home/homelab/homelab
set -a; source .env; set +a

install -o homelab -g homelab -m 0644 \
    stacks/grafana/provisioning/datasources/prometheus.yml \
    /mnt/hd2t/apps/grafana/etc/provisioning/datasources/prometheus.yml
install -o homelab -g homelab -m 0644 \
    stacks/grafana/provisioning/dashboards/dashboards.yml \
    /mnt/hd2t/apps/grafana/etc/provisioning/dashboards/dashboards.yml
install -o homelab -g homelab -m 0644 \
    stacks/grafana/provisioning/dashboards/json/*.json \
    /mnt/hd2t/apps/grafana/etc/provisioning/dashboards/json/

# Generar contraseña admin (escape hatch)
mkdir -p stacks/grafana/secrets
openssl rand -base64 32 > stacks/grafana/secrets/admin_password.txt
chmod 0600 stacks/grafana/secrets/admin_password.txt

# Drop-in de Caddy
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/03-grafana.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/03-grafana.caddy

# .env del stack (vacío en esta fase)
cp stacks/grafana/.env.example stacks/grafana/.env
chmod 0600 stacks/grafana/.env

# Añadir grafana.${DOMAIN_LAN} a access_control.rules de Authelia
# (si no se hizo ya). Política: two_factor.
sudo $EDITOR /mnt/hd2t/apps/authelia/config/configuration.yml
docker logs authelia --tail 20 | grep -i 'reloaded'

# Levantar Grafana
docker compose \
    -f stacks/grafana/docker-compose.yml \
    --env-file stacks/grafana/.env \
    up -d

# Recargar Caddy para que tome el nuevo drop-in
docker exec caddy caddy validate --config /etc/caddy/Caddyfile && \
    docker kill --signal=SIGUSR1 caddy
```

Tras `up -d`:

```bash
docker ps --filter name=grafana
# CONTAINER ID  IMAGE                          STATUS                  PORTS    NAMES
# ...           grafana/grafana-oss:11.3.0     Up 30 seconds (healthy)          grafana

docker compose -f stacks/grafana/docker-compose.yml logs --tail 30 grafana
# logger=settings ... msg="Starting Grafana" version=11.3.0
# logger=sqlstore ... msg="Connecting to DB" dbtype=sqlite3
# logger=migrator ... msg="Migration successfully executed"
# logger=provisioning.datasources ... msg="inserting datasource from configuration" name=Prometheus
# logger=provisioning.dashboard ... msg="starting to provision dashboards"
# logger=http.server ... msg="HTTP Server Listen" address=[::]:3000 protocol=http
```

---

## Configuración

### 1) Acceso al portal

Desde un cliente de la LAN con la CA interna ya instalada:

```text
1. Abrir https://grafana.lan/
2. Caddy redirige a https://auth.lan/?rd=https://grafana.lan/ (no hay sesión).
3. Login con `homelab` + TOTP.
4. Authelia escribe la cookie en `.lan` y redirige de vuelta.
5. Caddy llama a /api/verify -> Authelia responde 200 con cabeceras Remote-*.
6. Grafana ve `Remote-User: homelab`, crea el usuario (sign-up automático),
   asigna rol Admin (porque `Remote-Groups: admins`) y aterriza en la home.
7. Ir a Dashboards → Browse → carpeta "Homelab".
```

> **Primera vez**: la home de Grafana muestra "Welcome to Grafana". Cambiar la home a un dashboard concreto desde *Preferences* (icono usuario → Profile → Preferences → Home Dashboard → "Homelab Overview"). La preferencia se guarda en SQLite por usuario.

### 2) Verificar la datasource

```text
Connections → Data sources → Prometheus
Click en "Test"
```

Debe mostrar: `Successfully queried the Prometheus API.`. Si falla con `Bad Gateway` o `dial tcp: lookup prometheus`, Grafana no comparte la red `homelab` con Prometheus (revisar `networks: - homelab` en el compose).

### 3) Verificar provisioning

```bash
# La datasource provisionada aparece en SQLite (no se crea desde la UI):
docker exec grafana sqlite3 /var/lib/grafana/grafana.db \
    "SELECT name, type, url FROM data_source;"
# Prometheus|prometheus|http://prometheus:9090

# Los dashboards provisionados aparecen como tales:
docker exec grafana sqlite3 /var/lib/grafana/grafana.db \
    "SELECT title, slug FROM dashboard WHERE is_folder=0 LIMIT 10;"
# Homelab Overview|homelab-overview
# Node Exporter Full|node-exporter-full
# Cadvisor exporter|cadvisor-exporter
# Prometheus 2.0 Stats|prometheus-2-0-stats
# Caddy|caddy
```

### 4) Recargar provisioning sin reiniciar

Tras editar un dashboard JSON o el datasource:

```bash
# Materializar
install -o homelab -g homelab -m 0644 \
    stacks/grafana/provisioning/dashboards/json/02-node-exporter-full.json \
    /mnt/hd2t/apps/grafana/etc/provisioning/dashboards/json/02-node-exporter-full.json

# Grafana revisa la carpeta cada 30s (updateIntervalSeconds en dashboards.yml)
# y recarga automáticamente. Para forzar inmediatamente:
curl -ksu admin:"$(cat stacks/grafana/secrets/admin_password.txt)" \
    -X POST https://grafana.lan/api/admin/provisioning/dashboards/reload
# {"message":"Dashboards config reloaded"}

# Datasource (no auto-reload; se necesita endpoint de admin):
curl -ksu admin:"$(cat stacks/grafana/secrets/admin_password.txt)" \
    -X POST https://grafana.lan/api/admin/provisioning/datasources/reload
# {"message":"Datasources config reloaded"}
```

Estos endpoints requieren **basic auth** del admin local; por eso el escape hatch (contraseña admin) es útil incluso aunque el formulario de login esté deshabilitado.

### 5) Crear un dashboard ad-hoc

```text
1. Dashboards → New → New dashboard
2. + Add visualization → seleccionar Prometheus
3. Query: `node_load1`
4. Save dashboard → carpeta "General" (no provisionada).
```

Estos dashboards viven en SQLite, son editables sin restricción y se respaldan con el `grafana.db` (Borg en Fase 7).

### 6) Promover un dashboard ad-hoc a provisionado

Cuando un dashboard creado en la UI alcanza estabilidad y merece ir al repo:

```text
1. Dashboard → ⚙ Settings → JSON Model → copiar contenido.
2. Pegar en stacks/grafana/provisioning/dashboards/json/06-mi-dashboard.json
3. Sustituir todos los `"datasource": ...` por `{"type": "prometheus", "uid": "homelab-prometheus"}`.
4. Eliminar `id`, `uid` (Grafana asignará uno estable), `version`.
5. git add + commit.
6. Materializar y recargar (sección anterior).
7. Borrar el dashboard original ad-hoc desde la UI (queda la versión provisionada en su carpeta).
```

### 7) Operación diaria

| Acción | Comando |
|---|---|
| Ver dashboards provisionados | `https://grafana.lan/dashboards` |
| Ver datasources | `https://grafana.lan/connections/datasources` |
| Forzar recarga de provisioning | `curl -ksu admin:... -X POST https://grafana.lan/api/admin/provisioning/.../reload` |
| Ver health endpoint | `curl -ks https://grafana.lan/api/health` |
| Ver versión exacta | `docker exec grafana grafana cli --version` |
| Tamaño de la SQLite | `du -h /mnt/hd2t/apps/grafana/data/grafana.db` |
| Logs en vivo | `docker logs -f grafana` |
| Reiniciar Grafana | `docker compose -f stacks/grafana/docker-compose.yml restart grafana` |
| Activar escape hatch (login form) | editar compose: `GF_AUTH_DISABLE_LOGIN_FORM: "false"`, `up -d` |

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/grafana/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/grafana/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/grafana/secrets/admin_password.txt` | microSD | `homelab:homelab` | `0600` | Password admin (NO versionada). |
| `/home/homelab/homelab/stacks/grafana/provisioning/datasources/prometheus.yml` | microSD | `homelab:homelab` | `0644` | Datasource versionado. |
| `/home/homelab/homelab/stacks/grafana/provisioning/dashboards/dashboards.yml` | microSD | `homelab:homelab` | `0644` | Provider de dashboards. |
| `/home/homelab/homelab/stacks/grafana/provisioning/dashboards/json/*.json` | microSD | `homelab:homelab` | `0644` | Dashboards versionados. |
| `/home/homelab/homelab/stacks/caddy/conf.d/03-grafana.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy. |
| `/mnt/hd2t/apps/grafana/etc/provisioning/` | hd2t | `homelab:homelab` | `0750` | Provisioning materializado (`:ro` en el contenedor). |
| `/mnt/hd2t/apps/grafana/data/` | hd2t | `472:472` (`grafana`) | `0750` | SQLite (`grafana.db`), plugins, sessions, png renders. |
| `/mnt/hd2t/apps/grafana/data/grafana.db` | hd2t | `472:472` | `0640` | Base de datos: usuarios, dashboards ad-hoc, anotaciones, prefs. |
| `/mnt/hd2t/apps/grafana/data/png/` | hd2t | `472:472` | `0750` | Caché de png renderizados (vacío sin grafana-image-renderer). |
| `/mnt/hd2t/apps/grafana/data/plugins/` | hd2t | `472:472` | `0750` | Plugins instalados (vacío en esta fase). |
| `/mnt/hd2t/apps/grafana/logs/` | hd2t | `472:472` | `0750` | Logs propios (rotación interna). |

> **Tamaño esperado**. La SQLite arranca en ~1 MiB (esquema vacío + provisioning) y crece hasta 20–50 MiB tras meses de uso (anotaciones, dashboards ad-hoc, sesiones). La carpeta `data/` total raramente supera 200 MiB sin plugins. Si supera 1 GiB, el sospechoso habitual son los png cacheados de un grafana-image-renderer mal configurado, que en este documento no se despliega.

> **Por qué no microSD**. La SQLite hace `fsync()` en cada commit de transacción. Sumado a la actividad de provisioning (`updateIntervalSeconds: 30`) y a los login-redirects de Authelia que tocan la tabla de sesiones, el patrón I/O es agresivo para una microSD. En `hd2t` con USB 3.0 es perfectamente absorbible.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/grafana/docker-compose.yml`, `.env.example`, `provisioning/**/*.yml`, `provisioning/dashboards/json/*.json` | Versionados. |
| `stacks/grafana/secrets/admin_password.txt` | **No versionado** (ignorado por `.gitignore`). Se guarda en KeePassXC/Bitwarden del operador. |
| `stacks/caddy/conf.d/03-grafana.caddy` | Versionado. |
| Decisiones (auth.proxy, SQLite, dashboards base) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Por qué |
|---|---|---|
| `/mnt/hd2t/apps/grafana/etc/provisioning/` | Sí. | Reproducible desde git, pero respaldarlo evita pérdida de cambios que aún no se hayan promovido al repo. |
| `/mnt/hd2t/apps/grafana/data/grafana.db` | Sí (con `sqlite3 .backup`). | Contiene dashboards ad-hoc, anotaciones manuales y preferencias por usuario. **Crítico**. |
| `/mnt/hd2t/apps/grafana/data/plugins/` | Sí. | Reinstalable, pero respaldar es barato (pocos MiB) y ahorra tiempo en restore. |
| `/mnt/hd2t/apps/grafana/data/png/` | No. | Caché regenerable. |
| `/mnt/hd2t/apps/grafana/data/sessions.db` | No. | Sesiones efímeras; tras restore, los usuarios re-logean vía Authelia y se recrea. |
| `/mnt/hd2t/apps/grafana/logs/` | No. | Rotados internamente, sin valor histórico fuera de la ventana corta. |

> **Backup consistente de SQLite**. Copiar `grafana.db` con `cp` mientras Grafana está escribiendo puede capturar un estado inconsistente. La forma correcta:
>
> ```bash
> docker exec grafana sqlite3 /var/lib/grafana/grafana.db \
>     ".backup /var/lib/grafana/grafana.db.bak"
> ```
>
> Esto usa el VFS de SQLite para copiar transaccionalmente. Borgmatic ejecuta este pre-hook antes del snapshot. La ruta `/mnt/hd2t/apps/grafana/data/grafana.db.bak` es la que entra en el archivo Borg.

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/grafana/docker-compose.yml up -d --force-recreate
# Grafana reusa /mnt/hd2t/apps/grafana/data: lee SQLite, aplica provisioning,
# expone la UI. Cero pérdida de dashboards ad-hoc ni preferencias.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear Fase 1, 2, 3, 4 y `01-prometheus.md`.
2. Restaurar `/mnt/hd2t/apps/grafana/etc/provisioning/` y `/mnt/hd2t/apps/grafana/data/` desde Borg (incluyendo `grafana.db.bak` → renombrar a `grafana.db`).
3. `chown -R 472:472 /mnt/hd2t/apps/grafana/data /mnt/hd2t/apps/grafana/logs`.
4. Regenerar `stacks/grafana/secrets/admin_password.txt` desde KeePassXC.
5. `docker compose -f stacks/grafana/docker-compose.yml up -d`.
6. `curl -ks https://grafana.lan/api/health` → `{"database": "ok", "version": "11.3.0"}` (vía Authelia desde el navegador con sesión válida).

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| Grafana no arranca: `permission denied` al escribir en `/var/lib/grafana` | El bind mount tiene un owner distinto al UID 472. | `sudo chown -R 472:472 /mnt/hd2t/apps/grafana/data /mnt/hd2t/apps/grafana/logs`. |
| `level=error msg="failed to load dashboards"` con `unmarshal error` | Un JSON está malformado (probablemente porque venía con `__inputs`/`__requires` de la importación interactiva y no se limpió). | Editar el JSON: borrar bloques `__inputs`, `__requires`, fijar `datasource` al UID estable. |
| Datasource `Prometheus` aparece pero `Test` da `Bad Gateway` | Grafana y Prometheus no comparten la red `homelab`. | Confirmar `networks: - homelab` y `external: true` en ambos compose. `docker network inspect homelab` debe listar ambos. |
| `https://grafana.lan/` da loop de redirecciones a `auth.lan` | `grafana.${DOMAIN_LAN}` no está en `access_control.rules` de Authelia. Con `default_policy: deny`, Authelia siempre lo niega. | Añadir el dominio al bloque `two_factor`; recargar Authelia. |
| Login con Authelia OK pero Grafana muestra formulario propio (no aterriza con `Remote-User`) | `GF_AUTH_PROXY_ENABLED=false` o `GF_AUTH_DISABLE_LOGIN_FORM=false`, o la cabecera `Remote-User` no llega. | Verificar `docker exec grafana env | grep GF_AUTH_PROXY`. Inspeccionar cabeceras: `curl -ksI -H 'Cookie: authelia_session=...' https://grafana.lan/` y mirar el log de Caddy/Authelia. |
| Grafana asigna a todos los usuarios rol `Viewer` aunque el grupo Authelia es `admins` | Mapeo de `Remote-Groups` a roles en Grafana no implementado por `auth.proxy` (solo Enterprise lo soporta nativamente). | Promocionar manualmente desde la UI (Server Admin → Users → Edit → Permissions: Grafana Admin / Org Admin). El sign-up automático sigue funcionando, solo el rol inicial es `Viewer`. Reabrible: implementar promoción via API + script en `bin/grafana-promote-admin.sh`. |
| Acceso directo al puerto 3000 (en una iteración futura con `ports:` añadido por error) acepta `Remote-User` falso | `GF_AUTH_PROXY_WHITELIST` mal configurada o vacía. | Confirmar `GF_AUTH_PROXY_WHITELIST: "172.30.10.0/24"` y eliminar cualquier `ports:` del compose. |
| Tras cambiar `prometheus.yml` el dashboard "Node Exporter Full" sigue mostrando datos viejos | Caché de queries del navegador o del `Browser` panel option. | Refresh forzado (Shift+F5) o Time range → Now. La caché es del lado cliente. |
| `Failed to provision dashboard 02-node-exporter-full` con `dashboard with same uid already exists` | Dos JSON tienen el mismo `uid`. | Borrar `uid` de uno de los dos; Grafana asigna uno estable derivado del slug. |
| SQLite locked: `database is locked` al respaldar con `cp` | `cp` no es transaccional; SQLite tenía un escritor activo. | Usar `sqlite3 .backup` (Borgmatic pre-hook) en vez de `cp`. |
| `provisioning` reload responde `401 Unauthorized` aunque se pasa basic auth | El usuario admin está siendo "duplicado" por `auth.proxy` (Grafana asocia al admin con un perfil sin permisos). | Llamar al endpoint con la cabecera `X-Grafana-Org-Id: 1` y desde la red Docker, o restaurar temporalmente `GF_AUTH_DISABLE_LOGIN_FORM=false`. |
| Dashboards muestran "No data" en todos los paneles | El target Prometheus correspondiente está `down` (Node Exporter, cAdvisor o Caddy aún no desplegados). | Esperado. Cerrar `03-node-exporter.md`, `04-cadvisor.md` y los datos aparecen automáticamente. |
| Tras `docker compose pull`, Grafana arranca con errores de migración | Salto de versión major (11→12) sin leer changelog. | Restaurar el tag exacto, leer el changelog de migración, snapshot de SQLite, repetir. |
| El navegador descarga el JSON en lugar de mostrar la UI | Falta `import security_headers` y/o el snippet quita el `Content-Type` correcto. | Verificar `stacks/caddy/conf.d/03-grafana.caddy`: presencia de `import security_headers`. |

---

## Decisiones que **no** se toman en este documento

- **Unified Alerting de Grafana**: motor de alertas integrado de Grafana 9+. Reabrible si en el futuro el operador prefiere consolidar alerting en Grafana en vez de en Alertmanager + Uptime Kuma. Hoy duplica responsabilidad.
- **`grafana-image-renderer`**: contenedor sidecar que renderiza paneles a PNG (para Slack/Telegram bots, reports por email). Útil con alerting; sin alerting es ceremonia. Reabrible cuando llegue Mailrise (Fase 11).
- **Loki como datasource** (logs): el homelab cubre logs en vivo con Dozzle (`06-dozzle.md`). Loki + Promtail añadirían un stack completo (Loki + Promtail + retención + indexación) por una funcionalidad que no se ha pedido. Reabrible si Dozzle se queda corto.
- **OAuth/OIDC contra Authelia**: redundante con `auth.proxy`. Reabrible cuando aparezca un cliente que no pase por Caddy.
- **Plugins externos** (Worldmap, Discrete, AlertManager UI): el dashboard "Homelab Overview" se construye con paneles core (Time series, Stat, Gauge, Bar gauge). Cualquier plugin extra introduce un paso manual de instalación. Reabrible caso por caso.
- **Multi-organización**: el homelab es una sola org. Reabrible si llega un escenario multi-tenant (lab compartido con familia con dashboards segregados).
- **PostgreSQL como backend**: SQLite escala a 1–3 usuarios sin esfuerzo. Reabrible si llega Postgres por otro servicio y consolidar tiene sentido.
- **Promoción automática de roles vía `Remote-Groups`**: no soportado nativamente en `auth.proxy` OSS. Reabrible con un script que llame a la API de Grafana tras login.
- **Grafana 12.x**: misma decisión que en `01-prometheus.md` con Prometheus 3.x: esperar a que los dashboards comunitarios (`1860`, `14282`, `3662`) hayan migrado.

---

## Verificación Final

Antes de pasar a `03-node-exporter.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/grafana/docker-compose.yml ps` | `grafana ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect grafana --format '{{.Config.Image}}'` | `grafana/grafana-oss:11.3.0` |
| Conectado a `homelab` | `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` | incluye `grafana`, `caddy` y `prometheus` |
| Sin puertos publicados al host | `docker port grafana` | salida vacía |
| `grafana.lan` resuelve al IP de la Pi | `dig +short grafana.lan @192.168.1.2` | `192.168.1.10` |
| Caddy sirve `grafana.lan` con cert de la CA interna | `echo \| openssl s_client -connect grafana.lan:443 -servername grafana.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| Health endpoint responde (interno) | `docker exec grafana wget -qO- http://127.0.0.1:3000/api/health` | JSON con `"database": "ok"` |
| Datasource Prometheus provisionada | `docker exec grafana sqlite3 /var/lib/grafana/grafana.db "SELECT name,type,url FROM data_source;"` | `Prometheus\|prometheus\|http://prometheus:9090` |
| Dashboards provisionados cargados | `docker exec grafana sqlite3 /var/lib/grafana/grafana.db "SELECT count(*) FROM dashboard WHERE is_folder=0;"` | `>= 5` |
| Acceso vía Authelia con TOTP, sin formulario Grafana | navegador con CA instalada y sesión TOTP válida | la UI carga directamente como usuario `homelab` |
| Login form deshabilitado | `curl -ks https://grafana.lan/login \| grep -i 'input.*password' \|\| echo deshabilitado` | `deshabilitado` (tras pasar Authelia) |
| `auth.proxy` activo y con whitelist | `docker exec grafana env \| grep GF_AUTH_PROXY` | `GF_AUTH_PROXY_ENABLED=true`, `GF_AUTH_PROXY_WHITELIST=172.30.10.0/24`, `GF_AUTH_PROXY_HEADER_NAME=Remote-User` |
| Owner correcto del data dir | `stat -c '%u:%g' /mnt/hd2t/apps/grafana/data/` | `472:472` |
| SQLite escrita en hd2t | `du -h /mnt/hd2t/apps/grafana/data/grafana.db` | tamaño > 0 |
| Recarga de provisioning funciona | `curl -ksu admin:... -X POST https://grafana.lan/api/admin/provisioning/dashboards/reload` | `{"message":"Dashboards config reloaded"}` |
| Dashboard "Homelab Overview" accesible | navegador → Dashboards → Homelab → Homelab Overview | el dashboard carga; paneles con `No data` para targets aún no desplegados (Node Exporter, cAdvisor) |

## Referencias

- Documentación oficial de Grafana: https://grafana.com/docs/grafana/latest/
- Imagen Docker oficial OSS: https://hub.docker.com/r/grafana/grafana-oss
- Provisioning (datasources, dashboards): https://grafana.com/docs/grafana/latest/administration/provisioning/
- Auth proxy: https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/auth-proxy/
- Configuration reference (variables `GF_*`): https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/
- Dashboard "Node Exporter Full" (ID 1860): https://grafana.com/grafana/dashboards/1860
- Dashboard "Cadvisor exporter" (ID 14282): https://grafana.com/grafana/dashboards/14282
- Dashboard "Prometheus 2.0 Stats" (ID 3662): https://grafana.com/grafana/dashboards/3662
- Dashboard "Caddy" (ID 20802): https://grafana.com/grafana/dashboards/20802
- Documentación interna relacionada:
  - `docs/03-red/04-caddy.md` — reverse proxy y snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)`.
  - `docs/04-seguridad/01-authelia.md` — `forward_auth`, snippet `(authelia_two_factor)`, cabeceras `Remote-*`.
  - `docs/05-monitorizacion/01-prometheus.md` — datasource consumido por Grafana.
  - `docs/05-monitorizacion/03-node-exporter.md` — fuente de los paneles de Node Exporter Full.
  - `docs/05-monitorizacion/04-cadvisor.md` — fuente de los paneles de cAdvisor.
