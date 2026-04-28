# Uptime Kuma

## Descripción

Despliegue de **Uptime Kuma** (`louislam/uptime-kuma`, Node.js + SQLite, single-binary, Apache 2.0) como **monitor de disponibilidad ("status checker") del homelab**: ejecuta probes periódicos (HTTP/HTTPS, DNS, TCP, ping, Docker container, Steam, push, etc.) contra cada servicio desplegado, mantiene un historial en SQLite con uptime / downtime / latencia, dispara **notificaciones** (Telegram, email SMTP, Discord, ntfy, webhook genérico, ...) cuando un monitor cambia de estado, y publica una **status page** opcional con el estado agregado para humanos. Prometheus ([`./01-prometheus.md`](./01-prometheus.md)) lo scrapea cada 30 s en el endpoint `/metrics` (basic_auth con API key del propio Kuma) y Grafana ([`./02-grafana.md`](./02-grafana.md)) lo pinta con el dashboard "Uptime Kuma — Service Status" (Grafana.com #18667) que este doc provisiona.

Uptime Kuma es el **quinto** servicio del stack `monitoring` (fila §1.1 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)). Este documento **extiende** el `~/homelab/stacks/monitoring/docker-compose.yml` que dejaron Prometheus, Grafana, Node Exporter y cAdvisor, **no** crea un compose nuevo. Tras este doc, el stack tiene cinco servicios (`prometheus`, `grafana`, `node-exporter`, `cadvisor`, `uptime-kuma`); el siguiente doc ([`./06-dozzle.md`](./06-dozzle.md)) añadirá Dozzle.

> **Alcance de red**: la UI de Uptime Kuma se sirve **únicamente** vía Caddy en `https://uptime.{$LAN_DOMAIN}`, protegida por **Authelia con `policy: two_factor`** (es la consola de operaciones desde la que se silencian alertas, se editan monitores y se rotan tokens de notificación). El endpoint `/metrics` queda accesible **sólo** desde la red bridge `homelab`, scrapeado por Prometheus con basic_auth contra una API key generada en la UI. **No** se publica `:3001` al host; **no** se expone a internet; las notificaciones salientes (Telegram Bot API, SMTP, ntfy, ...) atraviesan la red `homelab` → bridge default → DNS de Pi-hole → Unbound → upstream (Cloudflare/Quad9).

> **Por qué Uptime Kuma y no otra herramienta** (Healthchecks.io self-hosted, Statping, Gatus, monit + alertmanager + ...):
>
> 1. **Operativa centrada en humanos.** El homelab es de un solo operador: la mayor parte de las alertas las consume una persona en su móvil. Uptime Kuma se diseñó alrededor de esa UX: dashboard de un vistazo, notificaciones por chat (Telegram, ntfy) directas y una status page pública opcional para la familia. Healthchecks.io es excelente para "dead man's switch" de cron, Gatus es declarativo en YAML — Uptime Kuma es la herramienta más cómoda para "ver el estado de 30 servicios en una pantalla" y silenciar alertas con un click.
> 2. **Probes nativos heterogéneos.** Soporta sin plugins HTTP(S), HTTP keyword/JSON, DNS (A/AAAA/CNAME/MX/TXT/CAA), TCP port, ping, Docker container (vía socket), Steam Game, Push (heartbeat de un proceso externo) y MQTT. Cubre todo lo que el homelab necesita: salud HTTP de cada UI (Caddy + el backend detrás), salud DNS de Pi-hole y Unbound (probe DNS interno), salud TCP de Mosquitto / Samba / Transmission, salud "el contenedor existe y está corriendo" vía Docker socket cuando el servicio no expone HTTP/TCP (Watchtower, Borgmatic, Zigbee2MQTT en modo MQTT puro).
> 3. **Compatible con Prometheus** desde 1.18+. La métrica `monitor_status{monitor_name=...}` (1=up, 0=down, 2=pending, 3=maintenance) y `monitor_response_time{...}` se pueden federar en el TSDB del homelab (ya respaldado, retención 30 d) y graficar en Grafana junto al resto de KPIs. Esto da continuidad histórica más allá de los 90 días por defecto del propio SQLite de Kuma.
> 4. **Notificaciones gratis y sin lock-in.** Telegram Bot API, ntfy, Discord, Gotify, Pushover, SMTP genérico, webhook arbitrario. Para el homelab personal se elige Telegram (un bot privado, gratis, móvil), con SMTP saliente como fallback opcional cuando se configure un relay (no incluido en Fase 5 — ver Fase 11+).
> 5. **SQLite + WAL = mínima latencia, mínima dependencia.** No requiere PostgreSQL/MariaDB externo. La BD pesa ≤100 MB con 30 monitores y 6 meses de historial; cabe en hd2t holgadamente y se respalda como un fichero más con Borgmatic (Fase 7). Si en el futuro se cruza el millón de filas de heartbeat, Uptime Kuma 2.x permite migrar a MariaDB — opcional, no requerido por este homelab.
> 6. **Multi-arch oficial desde 1.10**. La imagen `louislam/uptime-kuma` se publica para `linux/arm64/v8` (y `arm/v7`) directamente en Docker Hub. La variante `-debian` (vs `-alpine`) se elige aquí: el agente DNS de Kuma usa `dns-packet`/`tldts`, que en alpine + musl ha tenido tropiezos con resolvers IPv6 (issues [#3654](https://github.com/louislam/uptime-kuma/issues/3654) y similares); en glibc/debian es estable.
> 7. **Coste mínimo en una Pi 5.** Idle 50–80 MB RAM, <1% CPU. En picos (probes simultáneos cada 60 s × 30 monitores) sube a ~150 MB y un puñado de % CPU. Cabe sin ajustes.

---

## Requisitos Previos

- **Prometheus desplegado y sano** según [`./01-prometheus.md`](./01-prometheus.md): `docker inspect prometheus --format '{{.State.Health.Status}}'` debe devolver `healthy`. La query `up{job="prometheus"}` devuelve `1`. El `prometheus.yml` ya tiene el placeholder comentado del `job_name: 'uptime-kuma'` (§4 de Prometheus, líneas marcadas como `ACTIVAR cuando ./05-uptime-kuma.md ...`), incluido el path al fichero de secret `password_file: /etc/prometheus/secrets/uptime_kuma_api_key` que este doc crea.
- **Grafana desplegado y sano** según [`./02-grafana.md`](./02-grafana.md): `docker inspect grafana --format '{{.State.Health.Status}}'` devuelve `healthy`. El árbol `~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/` existe y está configurado para auto-recargar cualquier `.json` que aparezca (§6.1 de Grafana, `updateIntervalSeconds: 30`).
- **Node Exporter desplegado y sano** según [`./03-node-exporter.md`](./03-node-exporter.md). No es dependencia técnica, pero la Fase 5 se redacta en orden y este doc asume que las filas anteriores están completas.
- **cAdvisor desplegado y sano** según [`./04-cadvisor.md`](./04-cadvisor.md). Tampoco es dependencia, mismo motivo.
- **Caddy desplegado y sano** según [`../03-red/04-caddy.md`](../03-red/04-caddy.md): `docker inspect caddy --format '{{.State.Health.Status}}'` devuelve `healthy`. El `Caddyfile` carga snippets `lan_internal_tls`, `security_headers` y `authelia_proxy`. La CA interna del homelab está confiada en el navegador del operador.
- **Authelia desplegado y sano** según [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md): `docker inspect authelia --format '{{.State.Health.Status}}'` devuelve `healthy`. El operador tiene un usuario en `users_database.yml` con `groups: [admin]` y al menos un dispositivo TOTP enrolado. El snippet `authelia_proxy` de Caddy reenvía cabeceras `Remote-*`.
- **Pi-hole desplegado y sano** según [`../03-red/02-pihole.md`](../03-red/02-pihole.md): la UI permite añadir un registro DNS local `uptime.lan → 192.168.1.10` en §9.4 de este doc.
- **Stack `monitoring` ya inicializado** con los servicios anteriores: `~/homelab/stacks/monitoring/{docker-compose.yml,prometheus.yml,grafana/...,.env.example}` versionados en git, `/mnt/hd2t/services/monitoring/.env` con las variables comunes y las de Prometheus + Grafana + Node Exporter + cAdvisor.
- **Red `homelab`** creada según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2 (`172.20.0.0/24`, bridge `br-homelab`, `external: true`).
- **Estructura de directorios** del stack `monitoring` ya en su sitio (creada por [`./01-prometheus.md`](./01-prometheus.md) §3.2 y ampliada por los docs intermedios). El bootstrap original ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6.6) creó un `/mnt/hd2t/services/uptime-kuma/` vacío del esquema antiguo "un dir por servicio" que se **mueve** al esquema "un dir por stack" en §3.1.
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No se añaden reglas: Uptime Kuma no publica puertos al host; Caddy ya escucha en 443.
- **Conectividad saliente desde la red `homelab` hacia internet**: las notificaciones de Telegram requieren alcanzar `api.telegram.org:443`. La red bridge `homelab` con default gateway = host es la configuración por defecto, así que el tráfico sale por la interfaz `eth0` de la Pi sin más; verificable con `docker exec prometheus wget -qO- -T 5 https://api.telegram.org/ | head` (debe devolver el HTML de "method not specified", no un error de DNS o `connection refused`).
- **(Opcional) Bot de Telegram creado**. Si se va a usar Telegram como canal de notificación (recomendado), crearlo **antes** de §6.4 hablando con [@BotFather](https://t.me/BotFather) en Telegram: `/newbot`, dar un nombre (ej. `pi5-homelab-bot`), guardar el `bot_token` que devuelve. El `chat_id` propio se obtiene enviándole un mensaje cualquiera al bot y consultando `https://api.telegram.org/bot<TOKEN>/getUpdates`. Ambos valores se introducen en la UI de Kuma en §6.4, **no** se versionan en el `.env`.
- **Comprobaciones rápidas**:
  ```bash
  # Stack monitoring tiene los cuatro servicios anteriores (healthy):
  docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml ps
  # Esperado: prometheus, grafana, node-exporter, cadvisor, todos (healthy).

  # Caddy y Authelia sanos:
  docker inspect caddy authelia --format '{{.Name}} {{.State.Health.Status}}'
  # Esperado: /caddy healthy / /authelia healthy

  # El placeholder del job en prometheus.yml está como bloque comentado:
  grep -A6 "job_name: 'uptime-kuma'" ~/homelab/stacks/monitoring/prometheus.yml | head
  # Esperado: las 6 líneas comentadas (#) que se descomentarán en §4.

  # El árbol de provisioning de dashboards existe:
  ls ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/
  # Esperado: prometheus-stats.json, node-exporter-full.json, rpi-monitoring.json, docker-cadvisor.json.

  # Conectividad saliente a Telegram desde la red homelab:
  docker exec prometheus wget -qO- -T 5 https://api.telegram.org/ | head -1
  # Esperado: una línea HTML (no "Bad address" ni timeout).

  # /var/run/docker.sock existe (necesario si se usa el monitor "Docker container"):
  test -S /var/run/docker.sock && echo "docker.sock OK"
  # Esperado: docker.sock OK
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Imagen Docker | **`louislam/uptime-kuma:1.23.16-debian`** | Imagen oficial multi-arch del proyecto upstream (Apache 2.0). 1.23.x es la rama estable actual; 2.0.x está en beta y migra de SQLite a MariaDB obligatoriamente — no se adopta hasta que la guía de migración upstream sea estable. Variante `-debian` (no `-alpine`): el agente DNS de Kuma ha tenido issues recurrentes con musl/IPv6 en Alpine; glibc/debian evita ese set de fallos al precio de ~30 MB extra de imagen. |
| Tag de imagen | **Pinned a release puntual**, nunca `latest` | Misma regla de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1. Uptime Kuma migra el schema de SQLite entre minors (1.21 → 1.22 añadió tablas `monitor_tls_info`, `proxy`, `tag`); pinear el tag y subirlo manualmente tras leer las release notes evita downtime nocturno por una migración inesperada. |
| Política de Watchtower | **`watchtower.enable: "true"`** | Coherente con [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 (Uptime Kuma está en la lista de incluidos). Los upgrades de patch dentro de 1.23.x son seguros (sólo bugfixes, sin migración de schema). Para minor (1.23 → 1.24) se revisa el changelog antes; mientras Watchtower no detecte un nuevo minor con el tag `1.23.16-debian` pinneado, no toca nada. Cuando el operador suba el tag a `1.24.x-debian` en el `.env`, Watchtower hará el `pull` + `recreate`. |
| Modo de red | **Sólo `homelab`** (bridge `external`) | Caddy llama a `http://uptime-kuma:3001` por DNS interno desde `homelab`. Prometheus llama a `http://uptime-kuma:3001/metrics` por el mismo bridge. El propio Kuma sale a internet para notificar (Telegram) y para hacer probes HTTP a los servicios — todos resolubles desde el bridge default. **No** se usa `network_mode: host` (alternativa común): rompería la resolución DNS Docker (`uptime-kuma` deja de existir como nombre), expondría `:3001` al LAN sin Caddy delante y mezclaría los probes con la pila de red del host. |
| `ports:` publicados al host | **Ninguno** | La UI se sirve **únicamente** vía Caddy (`reverse_proxy http://uptime-kuma:3001`). Publicar `:3001` al host duplicaría la entrada y permitiría saltarse Caddy (con él, su HTTPS, sus cabeceras de seguridad y la `forward_auth` con Authelia). Mismo razonamiento que Prometheus, Grafana, Authelia. |
| Acceso a la UI | **Detrás de Authelia** (`forward_auth`, política `two_factor`) | La UI de Kuma permite editar monitores, ver tokens de notificación en plano, silenciar alertas, eliminar historial completo. Es una **consola de operaciones**: requiere doble factor, igual que Portainer, Grafana o Vaultwarden. La status page pública (opcional, si se activa por monitor con `Public: yes`) **no** está en este alcance — si se publicase en el futuro, se haría como un host adicional `status.lan` con `policy: bypass`. |
| Acceso a `/metrics` | **Sólo desde `homelab`, basic_auth con API key** | Uptime Kuma 1.23+ protege `/metrics` por defecto con un esquema basic_auth-like: el username puede ser cualquier cosa (vacío incluido) y la password es una **API key** generada en la UI (Settings → API Keys). Sin API key válida, `/metrics` devuelve 401. Es **el mismo patrón** que Watchtower (`Authorization: Bearer ...`) y, dentro del homelab, queda doblemente protegido: red bridge interna + token. La key se almacena en `/mnt/hd2t/services/monitoring/prometheus/secrets/uptime_kuma_api_key` (chmod 600) y se monta read-only en el contenedor de Prometheus. |
| Reverse-proxy en Caddy | **SÍ**, `uptime.{$LAN_DOMAIN}` | Hostname corto y memorable; la status page pública (si se activa) usaría `status.{$LAN_DOMAIN}` por separado. La elección `uptime.lan` (en lugar de `kuma.lan` o `uptime-kuma.lan`) imita la convención del resto del homelab (`auth.lan`, `vault.lan`, `home.lan`): nombre breve descriptivo del servicio, no del producto. |
| Persistencia | **Bind mount** `/mnt/hd2t/services/monitoring/uptime-kuma/data` → `/app/data` | Toda la BD del servicio (SQLite con WAL: `kuma.db`, `kuma.db-shm`, `kuma.db-wal`), el `server.cert/key` autogenerado (no se usa: TLS lo hace Caddy), las cargas (logos custom de monitores), y los uploads. Bind (no named volume) para que Borg respalde por path predecible. |
| Usuario del contenedor | **`root` (default de la imagen)** | La imagen oficial corre como root y `npm` instala bajo `/app` con permisos root. La opción de "non-root" requiere reconstruir la imagen (no soportada nativamente). El daño potencial está acotado: el contenedor no tiene `cap_add`, no monta el FS root del host, sólo monta `/app/data` (rw, propiedad raíz del contenedor) y opcionalmente `/var/run/docker.sock` (ro, para los monitores Docker). |
| Acceso al socket Docker | **`/var/run/docker.sock:/var/run/docker.sock:ro`** | Permite que la UI use el tipo de monitor "Docker container" (ver §6.3, monitores `watchtower-docker`, `borgmatic-docker`). Es ro: Kuma sólo llama a `/containers/json` y `/containers/<id>/json` (read-only de la API Docker), no a `start`/`stop`. La superficie es la misma que Portainer ([`../02-docker/03-portainer.md`](../02-docker/03-portainer.md)) y cAdvisor ([`./04-cadvisor.md`](./04-cadvisor.md)) ya tienen. **Si** se quiere reducir aún más esa exposición, se puede sustituir el socket directo por `tecnativa/docker-socket-proxy` (variante futura, §10.7). |
| `cap_drop`/`cap_add` | **`cap_drop: [ALL]`**, sin `cap_add` | El proceso Node.js de Kuma no necesita capabilities especiales: HTTP/HTTPS, DNS UDP/TCP, ICMP (ping nativo), Docker socket UNIX. ICMP en Linux 4.11+ no requiere `CAP_NET_RAW` si `net.ipv4.ping_group_range` lo permite (default en RPi OS Bookworm: `0 2147483647`, todos los GIDs); por tanto el monitor "Ping" funciona sin capabilities extra. Si por alguna razón un kernel restringe ICMP, se añadiría `cap_add: [NET_RAW]`; documentado en §11. |
| `security_opt: no-new-privileges:true` | **Activado** | Plantilla §6.1 de estructura-compose. Sin coste para Kuma (no usa setuid/setgid). Refuerza la postura. |
| `read_only: true` | **NO** se activa | Kuma escribe a `/app/data/` (BD), `/app/logs/` y a `/tmp` durante operación normal. Forzar root FS read-only obligaría a montar tmpfs en al menos 3 paths y romperia el upload de logos custom. La superficie de escritura está acotada por el bind mount del host (`/app/data` es el único path rw expuesto). |
| Persistencia de los datos | Bind a `/mnt/hd2t/services/monitoring/uptime-kuma/data` | hd2t es el disco "datos del homelab" (cf. [`../00-hardware/03-preparacion-discos.md`](../00-hardware/03-preparacion-discos.md)). Borgmatic respalda este path con cifrado, retención 7d/4w/12m. |
| Healthcheck | **`extra/healthcheck.js` que trae la imagen** | El proyecto upstream incluye `/app/extra/healthcheck.js`: hace `GET http://localhost:3001` y exit-code 0 si el servidor responde. Más fiable que `wget /` (que devolvería 200 incluso con el frontend roto si Caddy se equivocase). `start_period: 60s`: el primer arranque corre `migrate` sobre SQLite y, en una Pi 5 con la BD vacía, tarda 5–15 s; si la BD trae 6 meses de heartbeat, hasta 60 s. |
| Logs Docker | **`json-file` 10 MB × 3** (heredado del demonio) | Plantilla §6.1 de estructura-compose. Kuma genera logs moderados (un puñado de líneas por probe + notificación). 10 MB cubren días. |
| Memoria del contenedor (`mem_limit`) | **`256m`** | Idle ~50–80 MB. El límite duro a 256 MB protege a la Pi de un leak (han aparecido en versiones afectadas, e.g. issue [#1929](https://github.com/louislam/uptime-kuma/issues/1929)) o de un pico al cargar 6 meses de heartbeat en un dashboard. Si se alcanza el límite, Docker mata el contenedor y `restart: unless-stopped` lo levanta de nuevo. La pérdida de datos en SQLite con WAL es 0 (los heartbeats se commitean transaction-by-transaction). |
| Variable `UPTIME_KUMA_PORT` | **`3001`** (default) | El puerto por defecto de Kuma. Cualquier cambio implica también editar el job de Prometheus, el `reverse_proxy` de Caddy y el healthcheck. Mantener el default reduce la divergencia con la documentación upstream y con todos los dashboards. |
| Dashboard Grafana | **`Uptime Kuma — Service Status` (#18667, rev 1)** | Dashboard "todo en uno" para Kuma 1.18+ via Prometheus: tabla de monitores con estado, response time histórico, top SLOs, alertas activas. Viene de Grafana.com con `${DS_PROMETHEUS}` y se post-procesa con la receta de [`./02-grafana.md`](./02-grafana.md) §6.3.2 antes de meterlo en `provisioning/dashboards/json/`. |
| Notificación principal | **Telegram bot privado** | El operador recibe push en el móvil sin coste, sin cuenta SMTP, sin registrarse en un SaaS. Configurado en §6.4 desde la UI de Kuma; el `bot_token` no se versiona en git (vive en `kuma.db`, respaldado por Borgmatic con cifrado). |
| Notificación secundaria | **(opcional) ntfy.sh propio o público**, **(opcional) email SMTP** | Si en el futuro se despliega ntfy.sh self-hosted (no incluido en el plan), se añade como segundo canal. Email SMTP queda como TODO de Fase 11+. Mientras tanto, Telegram + status page interna cubren el caso. |
| API Keys (auth `/metrics`) | **Una API key dedicada para Prometheus** | Se crea en la UI (Settings → API Keys → "prometheus-scrape"), se copia al fichero `/mnt/hd2t/services/monitoring/prometheus/secrets/uptime_kuma_api_key` (chmod 600), se monta en Prometheus como volumen secrets RO. **No** se usa la "default API key" del usuario admin para esto: las API keys son revocables sin tocar la sesión del operador. |
| `INIT_ADMIN_USERNAME` / `INIT_ADMIN_PASSWORD` | **NO** se usan (auto-bootstrap) | Kuma 1.23 soporta crear el admin desde variables de entorno en el primer arranque. Se descarta porque (1) el password quedaría en el `.env` de hd2t en plano, (2) es más seguro crear el admin por la UI con un password generado en el momento y guardado en Vaultwarden cuando llegue Fase 11. Mientras tanto, el password se anota en el gestor de contraseñas del operador. |
| Migración a 2.x (MariaDB) | **NO** se planifica en este doc | Uptime Kuma 2.x abandona SQLite por MariaDB y la migración upstream aún tiene rough edges. Cuando 2.x sea stable, se documenta el upgrade en una variante separada (probablemente reescribiendo este doc). Mientras tanto, 1.23.x cubre el homelab sin queja. |
| Status page pública | **NO** se activa | La status page de Kuma se puede activar por monitor (`Public: yes`) o globalmente (Settings → Status Pages). Para el homelab personal no es necesaria — el operador es el único consumidor. Si en el futuro se quiere ofrecer "estado de la nube familiar" a otros, se documenta como variante opcional (host `status.lan` con `policy: bypass` en Authelia). |

---

## 1. Resumen de la arquitectura

```
                ┌────────────────────── HOST: Pi 5 (Raspberry Pi OS) ──────────────────────┐
                │                                                                           │
                │  /var/run/docker.sock        /mnt/hd2t/services/monitoring/                │
                │         ▲                       └─ uptime-kuma/data/  (kuma.db + WAL)     │
                │         │ ro                          ▲                                    │
                │         │                             │ rw bind                            │
                │   ┌─────┼─────────────────────── docker network: homelab ──────────────┐  │
                │   │     │                                                                │  │
                │   │  /var/run/docker.sock         /app/data                              │  │
                │   │     ▲                            ▲                                   │  │
                │   │     │                            │                                   │  │
                │   │  ┌──┴────────────────── uptime-kuma ─────────────────────────┐      │  │
                │   │  │ image: louislam/uptime-kuma:1.23.16-debian                │      │  │
                │   │  │ user:  root                                               │      │  │
                │   │  │ ports: -                                                  │      │  │
                │   │  │ networks: [homelab]                                       │      │  │
                │   │  │ probes: HTTP, DNS, TCP, ping, Docker container, push, ... │      │  │
                │   │  │ /metrics  (HTTP, basic_auth con API key, :3001)           │      │  │
                │   │  │ /          (UI Vue+Socket.IO, :3001)                      │      │  │
                │   │  └──▲────────────▲────────────────────────────▲──────────────┘      │  │
                │   │     │            │                            │                      │  │
                │   │     │            │ probes salientes           │ scrape /metrics      │  │
                │   │     │            │ (HTTP/DNS/TCP/ping)         │ basic_auth API key   │  │
                │   │     │            ▼                            │                      │  │
                │   │     │        ┌──────────────┐                 │                      │  │
                │   │     │        │ otros conts. │                 │                      │  │
                │   │     │        │ (caddy,      │                 │                      │  │
                │   │     │        │  pihole,     │                 │                      │  │
                │   │     │        │  nextcloud,  │                 │                      │  │
                │   │     │        │  jellyfin…)  │                 │                      │  │
                │   │     │        └──────────────┘                 │                      │  │
                │   │     │                                         │                      │  │
                │   │     │    ┌──────────── prometheus ─────────┐  │                      │  │
                │   │     │    │ job: 'uptime-kuma'              │◄─┘                      │  │
                │   │     │    │ basic_auth.password_file        │                         │  │
                │   │     │    │   = /etc/prometheus/secrets/    │                         │  │
                │   │     │    │     uptime_kuma_api_key         │                         │  │
                │   │     │    │ targets: [uptime-kuma:3001]     │                         │  │
                │   │     │    └──┬─────────────────────────────┘                          │  │
                │   │     │       │                                                         │  │
                │   │     │       ▼                                                         │  │
                │   │     │   ┌─────── grafana ────────┐                                    │  │
                │   │     │   │ dashboard #18667       │                                    │  │
                │   │     │   │ (Uptime Kuma —         │                                    │  │
                │   │     │   │   Service Status)      │                                    │  │
                │   │     │   └────────────────────────┘                                    │  │
                │   │     │                                                                 │  │
                │   │     │   ┌─────── caddy ──────────────────────────────────────┐        │  │
                │   │     │◄──┤ uptime.{LAN_DOMAIN}                                │        │  │
                │   │         │   ├─ tls internal (CA homelab)                     │        │  │
                │   │         │   ├─ forward_auth → http://authelia:9091           │        │  │
                │   │         │   └─ reverse_proxy → http://uptime-kuma:3001       │        │  │
                │   │         └────────────────────────────────────────────────────┘        │  │
                │   └───────────────────────────────────────────────────────────────────────┘  │
                │                                                                              │
                │   Salida a internet (default gateway):                                        │
                │     uptime-kuma → eth0 → router → Telegram Bot API                            │
                │                                  ntfy.sh / SMTP relay (opcional)              │
                └──────────────────────────────────────────────────────────────────────────────┘
```

Cuatro invariantes:

- **Uptime Kuma sólo es accesible desde la red `homelab`.** No hay `ports:` al host. La UI llega vía Caddy + Authelia (forward_auth, 2FA). El `/metrics` lo scrapea Prometheus por DNS interno con basic_auth.
- **Las notificaciones salen pero nada entra**. Kuma abre conexiones HTTPS hacia `api.telegram.org`, ntfy.sh, SMTP relay; ningún tercero recibe webhooks entrantes. No hay puertos publicados al router.
- **El estado vive en una sola SQLite**. `kuma.db` (+ WAL/SHM) en `/mnt/hd2t/services/monitoring/uptime-kuma/data/`. Borg lo respalda con quiesce (§9). Reinstalar Kuma = `git clone` + `up -d` + restaurar el `.db`.
- **Las API keys se gestionan desde la UI**. La keys no viven en el repo. La de Prometheus se copia a `/mnt/hd2t/.../secrets/uptime_kuma_api_key` (chmod 600) y se monta RO en el contenedor de Prometheus.

Flujo de un probe:

```
1. Kuma despierta el job 'pihole-ui' (HTTP, interval=60s).
2. GET https://pihole.lan/admin/  (resolución DNS por Pi-hole = bucle, ver §11).
   → en realidad: GET http://pihole:80/admin/  (DNS interno Docker; sin TLS).
3. status_code 200 + body contiene "Pi-hole" → up.
4. Kuma escribe heartbeat (timestamp, status=1, ping=12ms) a kuma.db.
5. (si cambió de down→up o up→down) lanza notification:
   - Telegram: POST https://api.telegram.org/bot<TOKEN>/sendMessage
   - …
6. Prometheus scrapea cada 30s:
   GET http://uptime-kuma:3001/metrics  (Authorization: Basic <base64(":<API_KEY>")>)
   → monitor_status{monitor_name="pihole-ui"} 1
     monitor_response_time{monitor_name="pihole-ui"} 0.012
7. Grafana refresca dashboard 18667 con la última muestra.
```

---

## 2. Plan de variables y archivos

El stack `monitoring` ya existe; este doc **extiende** los ficheros que dejaron Prometheus, Grafana, Node Exporter y cAdvisor. Estado del repo después de este doc:

```
~/homelab/stacks/monitoring/             # versionable en git
├── docker-compose.yml                   # +bloque `uptime-kuma:`
├── .env.example                         # +sección Uptime Kuma
├── prometheus.yml                       # job 'uptime-kuma' DESCOMENTADO
└── grafana/
    ├── grafana.ini                       # sin cambios
    └── provisioning/
        ├── datasources/prometheus.yml    # sin cambios
        └── dashboards/
            ├── default.yml               # sin cambios
            └── json/
                ├── prometheus-stats.json
                ├── node-exporter-full.json
                ├── rpi-monitoring.json
                ├── docker-cadvisor.json
                └── uptime-kuma.json       # NUEVO (Grafana.com #18667)

~/homelab/stacks/proxy/                  # versionable en git
└── Caddyfile                             # +bloque `uptime.{$LAN_DOMAIN}`

~/homelab/stacks/auth/                   # versionable en git
└── configuration.yml                     # +entrada `uptime.{LAN_DOMAIN}` en access_control.rules

/mnt/hd2t/services/monitoring/           # datos persistentes, NO en git
├── .env                                  # +sección Uptime Kuma
├── prometheus/
│   ├── data/
│   └── secrets/
│       └── uptime_kuma_api_key           # NUEVO (chmod 600, contenido = API key)
├── grafana/data/                         # sin cambios
└── uptime-kuma/
    └── data/                             # NUEVO (kuma.db + WAL + uploads)
```

### 2.1. Variables del stack — extender `.env.example`

Editar `~/homelab/stacks/monitoring/.env.example` (creado por [`./01-prometheus.md`](./01-prometheus.md) §2.1, ampliado por los docs intermedios) y **descomentar/rellenar** la sección Uptime Kuma:

```dotenv
# ~/homelab/stacks/monitoring/.env.example
# Versión control: ~/homelab/stacks/monitoring/.env.example
# Valores reales en /mnt/hd2t/services/monitoring/.env (chmod 600).

# --- Comunes del homelab ---
PUID=1000
PGID=1000
TZ=Europe/Madrid

# --- Dominios internos ---
LAN_DOMAIN=lan
TS_DOMAIN=tailnet.ts.net

# --- Prometheus (./01-prometheus.md) ---
PROMETHEUS_IMAGE_TAG=v2.55.1
PROMETHEUS_HOSTNAME=prometheus.lan
PROMETHEUS_RETENTION_TIME=30d
PROMETHEUS_RETENTION_SIZE=5GB

# --- Grafana (./02-grafana.md) ---
GRAFANA_IMAGE_TAG=11.4.0
GRAFANA_HOSTNAME=grafana.lan
GRAFANA_ADMIN_PASSWORD=changeme-ver-el-env-real
GRAFANA_AUTH_PROXY_WHITELIST=172.20.0.0/24

# --- Node Exporter (./03-node-exporter.md) ---
NODE_EXPORTER_IMAGE_TAG=v1.8.2

# --- cAdvisor (./04-cadvisor.md) ---
CADVISOR_IMAGE_TAG=v0.49.1

# --- Uptime Kuma (./05-uptime-kuma.md) ---
# https://github.com/louislam/uptime-kuma/releases
# CHANGELOG por minor: revisar release notes en GitHub al subir tag.
# Variante -debian (vs -alpine) para evitar issues de musl/IPv6 con DNS.
UPTIME_KUMA_IMAGE_TAG=1.23.16-debian
UPTIME_KUMA_HOSTNAME=uptime.lan

# (Reservado para los siguientes docs de Fase 5; se rellenarán cuando toquen)
# DOZZLE_IMAGE_TAG=
```

### 2.2. Extender el `.env` real (`/mnt/hd2t/services/monitoring/.env`)

```bash
# Añadir las nuevas líneas al .env (sin tocar las existentes de los servicios
# anteriores):
sudo tee -a /mnt/hd2t/services/monitoring/.env >/dev/null <<'EOF'

# --- Uptime Kuma (./05-uptime-kuma.md) ---
UPTIME_KUMA_IMAGE_TAG=1.23.16-debian
UPTIME_KUMA_HOSTNAME=uptime.lan
EOF

# Comprobar permisos (deben seguir siendo 600):
ls -l /mnt/hd2t/services/monitoring/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

> **No hay secretos** en la sección Uptime Kuma del `.env`: ni passwords, ni tokens, ni TLS configurada. Todos los secretos (admin password, bot_token de Telegram, chat_id, API key de Prometheus) viven dentro de `kuma.db` y/o en `/mnt/hd2t/services/monitoring/prometheus/secrets/`. Borgmatic los respalda cifrados (§9).

---

## 3. Preparar el host

### 3.1. Migrar el directorio del esquema antiguo

El bootstrap original ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6.6) creó `/mnt/hd2t/services/uptime-kuma/` siguiendo el esquema "un dir por servicio" que el plan ha sustituido por "un dir por stack". Se mueve a `/mnt/hd2t/services/monitoring/uptime-kuma/`:

```bash
# Confirmar que está vacío (no debería haber datos previos: nadie ha levantado
# Kuma todavía):
ls -la /mnt/hd2t/services/uptime-kuma/ 2>/dev/null
# Esperado: . y .. solamente; cualquier otra cosa indicaría un experimento
# previo que conviene revisar antes de borrar.

sudo rmdir /mnt/hd2t/services/uptime-kuma 2>/dev/null || true
# El rmdir falla silenciosamente si el directorio no existe; ambos casos OK.

# Crear el dir nuevo en el lugar correcto:
sudo install -d -o root -g root -m 755 /mnt/hd2t/services/monitoring/uptime-kuma
sudo install -d -o root -g root -m 755 /mnt/hd2t/services/monitoring/uptime-kuma/data
```

> **Por qué `root:root` y no `homelab:homelab`**: el contenedor corre como root (decisión de §0); el bind mount `/app/data` será propiedad de root dentro y fuera del contenedor. Si en el futuro se reconstruye la imagen como non-root (variante futura), se reasigna la propiedad antes del primer arranque.

### 3.2. Crear el directorio de secretos para Prometheus

`prometheus.yml` referencia `/etc/prometheus/secrets/uptime_kuma_api_key` (placeholder ya en el fichero, ver [`./01-prometheus.md`](./01-prometheus.md) §4). Ese path corresponde, en el host, a `/mnt/hd2t/services/monitoring/prometheus/secrets/`. El bind mount asociado está comentado en el `docker-compose.yml` de Prometheus:

```bash
# Crear el directorio de secretos en el host (si no existe ya):
sudo install -d -o nobody -g nogroup -m 750 \
  /mnt/hd2t/services/monitoring/prometheus/secrets

# Crear un fichero placeholder vacío. La API key real se genera en §6.5 desde
# la UI de Kuma; mientras tanto, el fichero existe para que el bind mount
# de Prometheus no falle al arrancar.
sudo install -m 600 -o nobody -g nogroup /dev/null \
  /mnt/hd2t/services/monitoring/prometheus/secrets/uptime_kuma_api_key

ls -la /mnt/hd2t/services/monitoring/prometheus/secrets/
# Esperado:
#   -rw------- 1 nobody nogroup 0 ... uptime_kuma_api_key
```

> **`nobody:nogroup`** porque la imagen oficial de Prometheus corre como UID 65534 (`nobody`); con cualquier otro owner, el mount del fichero daría `permission denied` al leerlo dentro del contenedor.

### 3.3. Descomentar el bind mount de secretos en el compose de Prometheus

El bloque `secrets/` está comentado en el `docker-compose.yml` de Prometheus (placeholder dejado en [`./01-prometheus.md`](./01-prometheus.md) §5, líneas marcadas `# Reservado para los siguientes docs ... mientras esté vacío, no estorba`). Editar `~/homelab/stacks/monitoring/docker-compose.yml` y **descomentar** las líneas que añaden el bind mount:

```yaml
  prometheus:
    # ... resto del bloque sin cambios ...
    volumes:
      - type: bind
        source: ~/homelab/stacks/monitoring/prometheus.yml
        target: /etc/prometheus/prometheus.yml
        read_only: true
        bind:
          create_host_path: false
      - type: bind
        source: /mnt/hd2t/services/monitoring/prometheus/data
        target: /prometheus
        bind:
          create_host_path: false

      # NUEVO — descomentado por ./05-uptime-kuma.md §3.3
      - type: bind
        source: /mnt/hd2t/services/monitoring/prometheus/secrets
        target: /etc/prometheus/secrets
        read_only: true
        bind:
          create_host_path: false
```

> **No** se aplica todavía con `up -d --force-recreate prometheus`: hacerlo ahora con un fichero vacío en `uptime_kuma_api_key` haría fallar el `basic_auth` (Prometheus loguearía 401 en cada scrape). El recreate se hace después de §6.5 (cuando la API key real ya está en el fichero) en §6.6.

### 3.4. Verificar conectividad saliente

```bash
# El probe de DNS de Kuma usará el resolver del propio Docker, que apunta al
# DNS del host. Verificar resolución y conectividad de Telegram:
docker exec prometheus wget -qO- -T 5 https://api.telegram.org/ | head -1
# Esperado: una línea HTML (no "Bad address" ni timeout).

# El probe de DNS interno (los monitores DNS apuntarán a Pi-hole para verificar
# que está respondiendo). Resolver pihole por su nombre Docker desde la red
# homelab:
docker exec prometheus getent hosts pihole
# Esperado: 172.20.0.X pihole
```

---

## 4. Activar el `scrape_config` en `prometheus.yml`

`~/homelab/stacks/monitoring/prometheus.yml` (creado por [`./01-prometheus.md`](./01-prometheus.md) §4) ya contiene el placeholder del job de Uptime Kuma, comentado y con un puntero a este doc:

```yaml
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

### 4.1. Descomentar el bloque

Editar `~/homelab/stacks/monitoring/prometheus.yml` y sustituir el bloque de placeholder por:

```yaml
  # ----- Uptime Kuma (./05-uptime-kuma.md) ------------------------------------
  # Uptime Kuma 1.23+ expone /metrics protegido por basic_auth con el API key
  # del propio panel. ACTIVO desde el despliegue del contenedor en
  # docs/05-monitorizacion/05-uptime-kuma.md §5; el secret se crea en §6.5.
  - job_name: 'uptime-kuma'
    metrics_path: /metrics
    basic_auth:
      username: ''
      password_file: /etc/prometheus/secrets/uptime_kuma_api_key
    static_configs:
      - targets: ['uptime-kuma:3001']
        labels:
          service: uptime-kuma
```

> **Username vacío** es lo correcto: Uptime Kuma 1.23+ ignora el username y valida sólo la password (la API key) contra su tabla de tokens. Otras configuraciones (`username: 'metrics'`) también funcionan, pero quedan inconsistentes con la documentación upstream.

> **No se aplica todavía** (`POST /-/reload`): el target estará DOWN hasta que el contenedor `uptime-kuma` exista (§5) Y la API key esté en el fichero secret (§6.5). El reload se hace en §6.6.

### 4.2. Validar la sintaxis

```bash
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
# Esperado:
#   Checking /etc/prometheus/prometheus.yml
#     SUCCESS: 1 rule files found
#   ... (sin warnings; el target uptime-kuma:3001 aparecerá UNRESOLVABLE
#   porque el contenedor aún no existe — eso es OK en validación de sintaxis).
```

---

## 5. `docker-compose.yml`

Editar `~/homelab/stacks/monitoring/docker-compose.yml` (extendido por todos los docs anteriores de Fase 5) y **añadir** el bloque `uptime-kuma:` debajo del bloque `cadvisor:`. **No** se tocan los bloques `prometheus:`, `grafana:`, `node-exporter:`, `cadvisor:`, ni el bloque `networks:` — más allá del descomento del bind mount `secrets/` en `prometheus:` que se hizo en §3.3.

```yaml
# ~/homelab/stacks/monitoring/docker-compose.yml
# Stack: monitoring (../02-docker/02-estructura-compose.md §1.1).
#
# Estado tras este doc: cinco servicios (`prometheus`, `grafana`,
# `node-exporter`, `cadvisor`, `uptime-kuma`).
# El siguiente doc de Fase 5 (./06-dozzle.md) añadirá Dozzle sin tocar
# los existentes ni el bloque `networks:`.

name: monitoring

services:
  prometheus:
    # ... bloque sin cambios excepto el descomento del bind 'secrets/' en §3.3 ...

  grafana:
    # ... bloque sin cambios; ver ./02-grafana.md §7 ...

  node-exporter:
    # ... bloque sin cambios; ver ./03-node-exporter.md §5 ...

  cadvisor:
    # ... bloque sin cambios; ver ./04-cadvisor.md §5 ...

  uptime-kuma:
    image: louislam/uptime-kuma:${UPTIME_KUMA_IMAGE_TAG}
    container_name: uptime-kuma
    hostname: uptime-kuma
    restart: unless-stopped

    # No se especifica `user:`: la imagen oficial corre como root y npm instala
    # bajo /app con perms root. Reconstruir como non-root requiere customizar
    # la imagen — fuera del alcance de este doc.

    # No depende de ningún otro contenedor para arrancar. Si Caddy o Authelia
    # están caídos, Kuma sigue probando y notificando — incluso es el primero
    # en avisar de que están caídos.
    # No depends_on.

    env_file:
      - /mnt/hd2t/services/monitoring/.env
    environment:
      TZ: ${TZ}
      # Puerto interno; coincide con --port default. Hacerlo explícito documenta
      # que la app escucha 3001, no 80 / 8080.
      UPTIME_KUMA_PORT: "3001"
      # Bind a 0.0.0.0 dentro del contenedor (default). No tiene efecto fuera
      # porque no hay `ports:` publicados.
      UPTIME_KUMA_HOST: "0.0.0.0"
      # Activar el endpoint /metrics (default true en 1.23+).
      # Documentado upstream: https://github.com/louislam/uptime-kuma/wiki/Reverse-Proxy

    volumes:
      # BD SQLite (kuma.db + WAL + SHM), config interna, uploads.
      - type: bind
        source: /mnt/hd2t/services/monitoring/uptime-kuma/data
        target: /app/data
        bind:
          create_host_path: false

      # Socket Docker para los monitores tipo "Docker container".
      # Read-only: Kuma sólo llama a /containers/json y /containers/<id>/json.
      # Si se quiere reducir esta exposición, sustituir por
      # tecnativa/docker-socket-proxy (variante futura, §10.7).
      - type: bind
        source: /var/run/docker.sock
        target: /var/run/docker.sock
        read_only: true
        bind:
          create_host_path: false

    networks:
      - homelab

    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    # Sin cap_add: ICMP en kernels modernos no requiere CAP_NET_RAW gracias a
    # net.ipv4.ping_group_range (RPi OS Bookswan: '0 2147483647'). Si en algún
    # kernel el monitor "Ping" empieza a fallar con EACCES, ver §11.

    mem_limit: 256m
    memswap_limit: 256m
    # Sin cpu_quota: Kuma consume <1% en idle; un quota artificial podría
    # frenar los probes simultáneos cuando hay 30+ monitores con el mismo
    # interval.

    healthcheck:
      # Script que trae la imagen; valida que el HTTP server responde y que
      # el frontend (build de Vue) está cargado.
      test: ["CMD-SHELL", "/usr/bin/node /app/extra/healthcheck.js || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      # 60 s para cubrir el primer arranque (migrate de SQLite + carga del
      # frontend en una Pi 5).
      start_period: 60s

    labels:
      com.centurylinklabs.watchtower.enable: "true"
      homepage.group: "Monitorización"
      homepage.name: "Uptime Kuma"
      homepage.icon: "uptime-kuma.png"
      homepage.href: "https://uptime.${LAN_DOMAIN}"
      homepage.description: "Monitor de disponibilidad y notificaciones"

networks:
  homelab:
    external: true
```

### 5.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `image: louislam/uptime-kuma:${UPTIME_KUMA_IMAGE_TAG}` | Tag fijo desde el `.env`. Imagen oficial multi-arch (incluye `linux/arm64/v8`). Variante `-debian` para evitar issues musl/IPv6 (justificación §0). |
| `container_name: uptime-kuma` / `hostname: uptime-kuma` | Caddy llama a `http://uptime-kuma:3001` y Prometheus llama a `http://uptime-kuma:3001/metrics` por nombre Docker. Sin `container_name`, el nombre real sería `monitoring-uptime-kuma-1`. |
| (sin `user:`) | La imagen oficial corre como root; reconstruir como non-root requiere `npm rebuild` con UID/GID específicos. La superficie está acotada por `cap_drop: [ALL]`, `no-new-privileges:true` y la red bridge sin `ports:` publicados. |
| (sin `depends_on:`) | Kuma debe arrancar incluso si Caddy/Authelia/Prometheus están caídos: precisamente es quien avisa de que lo están. La UI no será accesible sin Caddy, pero las notificaciones (Telegram) sí seguirán saliendo y los heartbeats se seguirán escribiendo a SQLite. |
| `env_file` ruta absoluta | Plantilla §6 de estructura-compose. Coherente con el resto del stack. |
| `environment.TZ` | Zonas horarias correctas en los logs y en la UI (las gráficas de uptime usan la TZ del servidor). |
| `environment.UPTIME_KUMA_PORT: "3001"` | Default; explícito por documentación. Si se quisiera cambiar (por ejemplo, para evitar colisión con un servicio que tomara `:3001` en `network_mode: host` ajeno a este compose), bastaría con cambiar la variable y el `target` en el job de Prometheus + el `reverse_proxy` de Caddy. |
| `environment.UPTIME_KUMA_HOST: "0.0.0.0"` | Default. Hacerlo explícito documenta que el bind es a todas las IPs del contenedor (no `127.0.0.1`, lo cual rompería el reverse proxy desde Caddy). |
| `volumes: /app/data` (rw) | Único path persistente: BD SQLite + WAL + uploads. Bind para que Borg lo respalde. |
| `volumes: /var/run/docker.sock` (ro) | Necesario para los monitores tipo "Docker container" (§6.3). Read-only acota a list/inspect. La superficie es la misma que ya exponen Portainer y cAdvisor. |
| `networks: [homelab]` | Único networking. Resuelve por DNS interno todos los demás servicios del homelab para los probes (HTTP/TCP/DNS). El tráfico saliente a internet (Telegram) usa el default gateway del bridge (NAT por la Pi). |
| `security_opt: no-new-privileges:true` | Plantilla §6.1 de estructura-compose. |
| `cap_drop: [ALL]` | Sin capabilities. Justificado en §0. |
| (sin `cap_add`) | Ver razonamiento de ICMP en §0. |
| `mem_limit: 256m` / `memswap_limit: 256m` | Idle 50–80 MB. Límite duro a 256 MB protege a la Pi de leaks históricos. Si se alcanza, restart automático y los heartbeats no se pierden (SQLite WAL). |
| `healthcheck: /app/extra/healthcheck.js` | Script oficial del proyecto. `start_period: 60s` cubre el `migrate` de SQLite. |
| `labels.watchtower.enable=true` | Justificado en la tabla §0. |
| `labels.homepage.*` | Auto-descubrimiento por Homepage ([`../12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md)). |

### 5.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/monitoring

# Validar sintaxis del compose:
docker compose --env-file /mnt/hd2t/services/monitoring/.env config >/dev/null \
  && echo "Compose OK"

# Inspeccionar el bloque de uptime-kuma:
docker compose --env-file /mnt/hd2t/services/monitoring/.env config \
  | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
uk = d["services"]["uptime-kuma"]
print("IMAGE:", uk.get("image"))
print("NETWORKS:", list(uk.get("networks", {}).keys()) if isinstance(uk.get("networks"), dict) else uk.get("networks"))
print("MEM_LIMIT:", uk.get("mem_limit"))
print("VOLUMES:")
for v in uk.get("volumes", []):
    print(" -", v)
print("PORTS:", uk.get("ports"))
print("CAP_DROP:", uk.get("cap_drop"))
print("LABELS:", uk.get("labels"))
'
# Esperado:
#   IMAGE: louislam/uptime-kuma:1.23.16-debian
#   NETWORKS: ['homelab']
#   MEM_LIMIT: 268435456
#   VOLUMES: 2 entradas (data rw, docker.sock ro)
#   PORTS: None
#   CAP_DROP: ['ALL']
```

> Si `compose config` emite "warning: variable not set", revisar el `.env`: `UPTIME_KUMA_IMAGE_TAG` y `UPTIME_KUMA_HOSTNAME` deben existir en `/mnt/hd2t/services/monitoring/.env`.

---

## 6. Despliegue

### 6.1. Levantar el contenedor

```bash
cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d uptime-kuma
```

Salida esperada:

```
[+] Running 1/1
 ✔ Container uptime-kuma  Started
```

> **Sólo se levanta `uptime-kuma`** (`up -d uptime-kuma`): los otros cuatro servicios ya están corriendo y no necesitan recreate (la modificación de §3.3 al bloque `prometheus:` se aplicará en §6.6, cuando ya exista la API key real).

### 6.2. Estado del contenedor

```bash
docker compose ps uptime-kuma
# Esperado tras ~60s:
# NAME          IMAGE                                STATUS                  PORTS
# uptime-kuma   louislam/uptime-kuma:1.23.16-debian  Up X (healthy)
```

Si tarda en `(healthy)` o entra en `(unhealthy)`:

```bash
docker compose logs uptime-kuma | tail -50
```

Eventos esperados en los logs del primer arranque:

```
==> Performing startup jobs and maintenance tasks
==> Starting application with user 0 group 0
DB Type: sqlite
Database file at /app/data/kuma.db
Loading Database
SQLite config: PRAGMA journal_mode = WAL  ...
[Backup] Skipping backup
Database Patch 2.0 process
Initializing settings ...
Adding default monitor groups
Listening on 3001
```

### 6.3. Smoke test desde la red `homelab`

```bash
# Desde cualquier contenedor de homelab (caddy o prometheus):
docker exec caddy wget -qO- -S http://uptime-kuma:3001/ 2>&1 | head -20
# Esperado: HTTP/1.1 200 OK + cabeceras + HTML del SPA (Vue + Socket.IO).

# El endpoint /metrics SIN basic_auth devuelve 401 (lo deseado):
docker exec caddy wget -qO- -S http://uptime-kuma:3001/metrics 2>&1 | head
# Esperado: HTTP/1.1 401 Unauthorized.
```

### 6.4. Smoke test desde el host

```bash
# Uptime Kuma NO debe ser alcanzable desde la IP del host:
curl -sf http://192.168.1.10:3001/ -m 2 ; echo "exit=$?"
# Esperado: exit=7 (connection refused). Nunca 200.

docker port uptime-kuma
# Esperado: vacío (sin port mappings).
```

### 6.5. Acceso inicial vía Caddy + crear admin + crear API key

Antes de añadir el `reverse_proxy` en Caddy ya existe acceso desde el contenedor de Caddy a Kuma por DNS interno (`http://uptime-kuma:3001`), pero la UI necesita HTTPS para que las cookies de sesión y la `forward_auth` funcionen sin warnings. Por eso el flujo es:

1. **Añadir el bloque `uptime.lan` al `Caddyfile` SIN `forward_auth`** (sólo `tls internal` + `reverse_proxy`).  Esto da acceso por HTTPS para crear el admin de Kuma. Es una ventana **muy corta** durante la cual la UI está accesible sólo por LAN — Caddy bloquea cualquier conexión externa porque el homelab no expone 443 a internet.
2. **Crear admin de Kuma** y la API key para Prometheus.
3. **Activar `forward_auth`** y añadir la regla en Authelia (§7).

#### 6.5.1. Bloque temporal en Caddy (sin `forward_auth`)

Editar `~/homelab/stacks/proxy/Caddyfile` y añadir, **debajo** del bloque `grafana.lan`:

```caddy
# Uptime Kuma (../05-monitorizacion/05-uptime-kuma.md)
# Bloque temporal SIN forward_auth — para crear admin + API key inicial.
# En §7 se añade `import authelia_proxy` y este comentario se elimina.
uptime.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    reverse_proxy http://uptime-kuma:3001 {
        # Uptime Kuma usa Socket.IO (WebSockets). Caddy reverse_proxy lo
        # detecta automáticamente; estas cabeceras explícitas no son
        # necesarias pero documentan el contrato:
        header_up Host {host}
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
    }
}
```

#### 6.5.2. Registro DNS local en Pi-hole

Pi-hole UI → **Local DNS** → **DNS Records** → añadir:

```
uptime.lan → 192.168.1.10
```

Reload del DNS interno:

```bash
docker exec pihole pihole reloaddns
```

Verificar:

```bash
dig +short @192.168.1.241 uptime.lan
# Esperado: 192.168.1.10
```

#### 6.5.3. Recargar Caddy

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
# Esperado: salida vacía y exit code 0.
```

#### 6.5.4. Crear admin de Uptime Kuma

Abrir `https://uptime.lan/` en el navegador (con la CA interna del homelab confiada). Aparece la pantalla de **"Create your admin account"**:

- Username: `admin` (o `homelab`).
- Password: generar con `openssl rand -base64 24`, **anotar en el gestor de contraseñas** del operador antes de continuar.
- Confirm Password: idem.
- Click **Create**.

Tras el submit, Kuma redirige a la dashboard vacía (0 monitores). Verificar:

- Esquina superior izquierda: el username elegido.
- **Settings → General**: cambiar lo que apetezca (zona horaria está heredada de `TZ=Europe/Madrid`).

#### 6.5.5. Crear la API key para Prometheus

En la UI: **Settings → API Keys → Add API Key**:

- Name: `prometheus-scrape`.
- Expires: vacío (no expira; se rota manualmente cuando convenga).
- Active: `yes`.
- Click **Generate**. Aparece la key **una sola vez** con formato `uk1_...` (40+ caracteres).

**Antes de cerrar el modal**, copiar la key. En la Pi:

```bash
# Pegar la key (sustituir <PASTE_KEY_HERE> por la que dió Kuma):
sudo tee /mnt/hd2t/services/monitoring/prometheus/secrets/uptime_kuma_api_key >/dev/null <<EOF
<PASTE_KEY_HERE>
EOF

# Asegurar perms:
sudo chown nobody:nogroup /mnt/hd2t/services/monitoring/prometheus/secrets/uptime_kuma_api_key
sudo chmod 600 /mnt/hd2t/services/monitoring/prometheus/secrets/uptime_kuma_api_key

# Verificar:
sudo ls -l /mnt/hd2t/services/monitoring/prometheus/secrets/uptime_kuma_api_key
# Esperado: -rw------- 1 nobody nogroup 41 ... uptime_kuma_api_key
sudo wc -c /mnt/hd2t/services/monitoring/prometheus/secrets/uptime_kuma_api_key
# Esperado: 41 o 42 bytes (incluye \n final).
```

> **Importante**: el fichero debe terminar en `\n` (lo añade el `tee` automáticamente). Si se pega con un editor que añade BOM o CRLF, Prometheus enviará la key con un byte extra y Kuma devolverá 401. Si hay duda, `xxd /mnt/hd2t/services/monitoring/prometheus/secrets/uptime_kuma_api_key` debe mostrar sólo `uk1_` + caracteres ASCII + `0a` final.

> **No se versiona en git** la key (el directorio `/mnt/hd2t/services/monitoring/prometheus/secrets/` está fuera del repo `~/homelab/stacks/`).

### 6.6. Aplicar el bind mount de secretos en Prometheus + recargar

Ahora que el fichero existe con la key real:

```bash
# 1. Recrear Prometheus para que monte el directorio secrets/ (descomentado en §3.3):
cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate prometheus

# 2. Verificar el bind mount:
docker exec prometheus ls -l /etc/prometheus/secrets/
# Esperado: -rw------- 1 nobody nogroup 41 ... uptime_kuma_api_key

# 3. Confirmar que Prometheus puede leer la key:
docker exec prometheus cat /etc/prometheus/secrets/uptime_kuma_api_key | head -c 8 ; echo
# Esperado: uk1_XXXX (los primeros 8 bytes de la key).

# 4. Reload de la config (el job 'uptime-kuma' del prometheus.yml ya está
# descomentado desde §4.1):
docker exec caddy wget -q --post-data='' -O- http://prometheus:9090/-/reload
# Esperado: salida vacía y exit code 0.
```

> **Por qué `up -d --force-recreate prometheus` y no `restart`**: añadir un volumen al servicio requiere recrear el contenedor. `restart` arranca el mismo contenedor con la misma config — el `volume:` nuevo no se aplicaría.

### 6.7. El target `uptime-kuma` aparece UP en Prometheus

```
https://prometheus.lan/targets
```

Esperado: una nueva fila para el job `uptime-kuma`, target `uptime-kuma:3001`, estado **UP** (verde), `Last Scrape` reciente, `Scrape Duration` < 200 ms.

Por API:

```bash
docker exec caddy wget -qO- 'http://prometheus:9090/api/v1/query?query=up{job="uptime-kuma"}' \
  | python3 -m json.tool
# Esperado: una serie con value=1 y labels { job="uptime-kuma", instance="uptime-kuma:3001", service="uptime-kuma", ... }.
```

> Si el target aparece **DOWN** con `401 Unauthorized`, la key del fichero `/etc/prometheus/secrets/uptime_kuma_api_key` no coincide con la registrada en Kuma. Revisar §6.5.5 (caracteres invisibles, `\r` extra). En la UI de Kuma → **Settings → API Keys**, la key `prometheus-scrape` debe aparecer en estado **Active**; si no, regenerarla y repetir el paso.

---

## 7. Integración con Caddy + Authelia (`forward_auth`)

Una vez Kuma está corriendo y la API key cargada, sustituir el bloque temporal del Caddyfile (§6.5.1) por el bloque definitivo con `forward_auth`.

### 7.1. Sustituir el bloque en el `Caddyfile`

Editar `~/homelab/stacks/proxy/Caddyfile`. **Eliminar** el comentario `# Bloque temporal SIN forward_auth ...` y **añadir** `import authelia_proxy`:

```caddy
# Uptime Kuma (../05-monitorizacion/05-uptime-kuma.md)
uptime.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    import authelia_proxy

    reverse_proxy http://uptime-kuma:3001 {
        header_up Host {host}
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}
    }
}
```

Razones:

- **`import authelia_proxy`** aplica el `forward_auth` definido en [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §9.1. Cualquier petición sin sesión Authelia válida será redirigida a `https://auth.lan` (302).
- **WebSockets / Socket.IO**: Caddy v2 reenvía `Upgrade` y `Connection` automáticamente cuando detecta que el backend espera una conexión WebSocket. La UI de Kuma usa Socket.IO desde el primer load; sin `import authelia_proxy` (paso §6.5.1) ya funcionaba; con `import authelia_proxy` la cookie de sesión Authelia se establece en el primer 200, y los Socket.IO subsiguientes la llevan automáticamente.
- **No se reescribe** `Host` con un valor distinto a `{host}`: Kuma usa `Host` para construir URLs absolutas en notificaciones (ej. enlaces a la UI desde un mensaje de Telegram). Mantener `{host}={uptime.lan}` asegura que esos enlaces son `https://uptime.lan/...`, no `http://uptime-kuma:3001/...`.

### 7.2. Recargar Caddy

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
# Esperado: Valid configuration.

docker exec caddy caddy reload --config /etc/caddy/Caddyfile
# Esperado: salida vacía, exit 0.
```

### 7.3. Añadir la regla en Authelia (`access_control.rules`)

Editar `~/homelab/stacks/auth/configuration.yml` (sección `access_control.rules`, ya documentada en [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §5) y **añadir** `uptime.lan` a la lista de servicios protegidos por 2FA:

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
        - "grafana.{{ env "LAN_DOMAIN" }}"
        - "uptime.{{ env "LAN_DOMAIN" }}"     # <── nuevo
      policy: two_factor
      subject:
        - "group:admin"
```

Validar y recargar Authelia:

```bash
docker exec authelia authelia validate-config --config /config/configuration.yml
# Esperado: Configuration parsed and loaded successfully without errors.

docker compose -f ~/homelab/stacks/auth/docker-compose.yml restart authelia
```

### 7.4. Verificar el SSO end-to-end

1. **Cerrar sesión** en `https://auth.lan/logout` (si la había).
2. Abrir `https://uptime.lan/`. Esperado: redirección a `https://auth.lan/` con un cuadro de login.
3. Autenticar con usuario + TOTP. Tras el segundo factor, redirección a `https://uptime.lan/`.
4. Aparece el dashboard de Kuma (no la pantalla de "Create admin account": eso ya se hizo en §6.5.4).
5. **Importante**: Kuma tiene **su propio sistema de usuarios** (el admin creado en §6.5.4). La integración aquí es de **portal**, no de SSO en el sentido de "Authelia inyecta el usuario en Kuma". El operador, una vez pasada la `forward_auth`, **también** ve el formulario de login de Kuma si no ha entrado antes. La cookie de Kuma persiste durante el `Remember me` configurado en su UI.

> **Por qué Kuma NO se integra con `auth.proxy` como Grafana**: Kuma 1.x **no soporta** auth.proxy ni headers de identidad externos (issue [#3544](https://github.com/louislam/uptime-kuma/issues/3544); pendiente para 2.x). El flujo "doble login" (Authelia → login Kuma) es un coste asumido. Mitigación práctica: en Kuma → **Settings → Security**, marcar `Two-factor authentication` para el admin local (TOTP redundante con el de Authelia, pero acota el blast-radius si la cookie de Authelia se filtra). Marcar `Remember me` con duración 30 d para que la doble autenticación sea esporádica.

---

## 8. Configurar monitores y notificaciones

> Esta sección **no** es scriptable: la UI de Kuma no expone la creación de monitores por API en 1.x ([issue #2511](https://github.com/louislam/uptime-kuma/issues/2511) — la API REST está en 2.x). Lo que sigue es la guía manual a aplicar la **primera vez**; los datos quedan en `kuma.db` y se respaldan con Borgmatic.

### 8.1. Crear el canal de notificación Telegram

UI: **Settings → Notifications → Setup Notification**:

- Notification Type: `Telegram`.
- Friendly Name: `telegram-operador`.
- Bot Token: el `bot_token` obtenido de @BotFather (de los Requisitos Previos).
- Chat ID: el `chat_id` del operador (obtenido vía `getUpdates`).
- **Test** → debe llegar un mensaje al móvil ("Testing Notification ... It is working").
- **Save**. Marcar **`Default enabled`** (para que cada nuevo monitor lo herede).

> **No** se versiona el `bot_token` ni el `chat_id` en el repo. Viven en `kuma.db` (cifrado en reposo si Borg cifra, que es lo que hace).

### 8.2. (Opcional) Crear el canal SMTP

Si se dispone de un relay SMTP (Gmail con app password, mailjet, ...), se añade un segundo canal `email-operador`. Marcar `Default enabled` también si se quiere recibir alertas por dos canales simultáneos. Para el homelab inicial, sólo Telegram suele bastar.

### 8.3. Crear los monitores iniciales

UI: **+ Add New Monitor**. Cada monitor con `Notifications: telegram-operador` y, salvo que se diga otro, `Heartbeat Interval: 60s`, `Retries: 2`, `Heartbeat Retry Interval: 60s`.

Lista mínima recomendada (orden por importancia):

| Monitor | Tipo | Configuración | Por qué |
|---|---|---|---|
| `pihole-dns` | DNS | Hostname: `pi-hole.net`, DNS Server: `pihole`, Port: `53`, Resolve Type: `A` | Detecta caída del DNS interno. Si Pi-hole no resuelve, todo el LAN se queda sin internet aparente. |
| `unbound-dns` | DNS | Hostname: `cloudflare.com`, DNS Server: `unbound`, Port: `5335`, Resolve Type: `A` | El upstream recursivo del homelab. Si cae, Pi-hole pierde su upstream. |
| `pihole-ui` | HTTP(s) | URL: `http://pihole:80/admin/`, Method: `GET` | Confirma que Pi-hole está sirviendo HTTP, no sólo DNS. |
| `caddy-tls` | HTTP(s) - Keyword | URL: `https://caddy.lan/`, Keyword: `Caddy operativo`, Ignore TLS Error: `no` | Confirma que la CA interna y los certs leaf siguen vivos (Caddy renueva cada 7 días — si renueva mal, este monitor lo coge). |
| `authelia` | HTTP(s) | URL: `http://authelia:9091/api/health`, Status Code: `200` | El IDP. Si cae, todos los servicios protegidos quedan inaccesibles. |
| `prometheus-self` | HTTP(s) | URL: `http://prometheus:9090/-/healthy`, Status Code: `200` | Confirma TSDB sano. |
| `grafana` | HTTP(s) | URL: `http://grafana:3000/api/health`, Status Code: `200` | UI de visualización. |
| `node-exporter` | HTTP(s) | URL: `http://node-exporter:9100/metrics`, Status Code: `200` | Telemetría del host. |
| `cadvisor` | HTTP(s) | URL: `http://cadvisor:8080/healthz`, Status Code: `200` | Telemetría de contenedores. |
| `portainer` | HTTP(s) | URL: `https://portainer:9443/`, Ignore TLS Error: `yes` | UI de gestión de contenedores. |
| `watchtower-docker` | Docker container | Container: `watchtower`, Docker Host: `Local Docker socket` | No expone HTTP; se monitorea por la API Docker (state=running). |
| `borgmatic-docker` *(futuro)* | Docker container | Container: `borgmatic`, Docker Host: `Local Docker socket` | Cuando se despliegue en Fase 7. |
| `nextcloud` *(futuro)* | HTTP(s) | URL: `http://nextcloud:11000/status.php`, Keyword: `installed` | Cuando se despliegue en Fase 6. |
| `jellyfin` *(futuro)* | HTTP(s) | URL: `http://jellyfin:8096/health`, Status Code: `200` | Cuando se despliegue en Fase 9. |

> **Tags**: en la UI cada monitor admite `Tags`. Convención del homelab: `infra` (DNS, proxy, auth), `monitoring` (pro/graf/exp/cad), `media`, `productividad`, `domotica`. Esto permite agrupar paneles en el dashboard de Grafana #18667.

> **Heartbeat Interval = 60s**: balance entre "detección rápida" y "carga sobre el servicio probado". 60 s × 30 monitores = una probe cada 2 s en media. Bajar a 20 s sólo si un servicio crítico necesita SLO sub-minuto.

### 8.4. Notificaciones de prueba

Para forzar una alerta y validar que llega: parar manualmente un monitor crítico **no productivo** (ej. uno de los `*-docker` apuntando a un contenedor que se pueda parar sin daño):

```bash
# Parar momentáneamente un contenedor sin impacto:
docker stop watchtower
sleep 90  # esperar 1.5 × heartbeat para que el monitor lo detecte.
docker start watchtower
```

Esperado:

- En Telegram: dos mensajes consecutivos. Primero "[🔴 Down] watchtower-docker" tras ~60 s; luego "[✅ Up] watchtower-docker" tras ~60 s del `start`.
- En la UI de Kuma → `watchtower-docker`: aparece la barra horaria con un hueco rojo y el evento marcado.
- En el dashboard #18667 de Grafana: el panel "Down monitors (last 24h)" suma 1 evento.

---

## 9. Provisioning del dashboard en Grafana

### 9.1. Uptime Kuma — Service Status (Grafana.com #18667)

#### 9.1.1. Descargar el JSON

```bash
cd ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json

# revision=1 es la disponible al momento de escribir este doc.
# Revisar: https://grafana.com/grafana/dashboards/18667-uptime-kuma/
curl -fsSL \
  "https://grafana.com/api/dashboards/18667/revisions/1/download" \
  -o uptime-kuma.json

# Verificar que es un JSON válido:
python3 -c 'import json; d=json.load(open("uptime-kuma.json")); print("title:", d.get("title")); print("panels:", len(d.get("panels", [])))'
# Esperado:
#   title: Uptime Kuma
#   panels: ~10
```

#### 9.1.2. Apuntar el JSON al UID `prometheus`

Igual que en [`./02-grafana.md`](./02-grafana.md) §6.3.2 y [`./04-cadvisor.md`](./04-cadvisor.md) §7.1.2: sustituir `${DS_PROMETHEUS}` por el UID estable del datasource (`prometheus`) y limpiar las claves `__inputs/__elements/__requires`:

```bash
cd ~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json

# 1. Sustituir el placeholder:
sed -i 's/"\${DS_PROMETHEUS}"/"prometheus"/g' uptime-kuma.json

# 2. Eliminar __inputs/__elements/__requires:
python3 - <<'PY'
import json
p = "uptime-kuma.json"
d = json.load(open(p))
for k in ("__inputs", "__elements", "__requires"):
    d.pop(k, None)
json.dump(d, open(p, "w"), indent=2)
print("Cleaned:", p)
PY

# 3. Comprobación: no debe quedar ningún ${DS_*}:
grep -c '${DS_' uptime-kuma.json
# Esperado: 0
```

### 9.2. Verificar que Grafana lo ha cargado

Grafana releé el directorio `provisioning/dashboards/json/` cada 30 s. Tras esperar ~30 s desde que se dejó el JSON:

```bash
docker logs grafana --since 1m 2>&1 | grep -iE 'provisioning|dashboard' | tail
# Esperado: una línea
#   logger=provisioning.dashboard.fileReader t=... level=info msg="finished to provision dashboards"
```

En la UI:

```
https://grafana.lan/dashboards
```

- Debe aparecer **Uptime Kuma** en la lista, con icono de candado provisioned.
- Abrirlo: paneles principales muestran:
  - `Up monitors`: número total de monitores en estado `up`.
  - `Down monitors (last 24h)`: cuántos eventos de bajada en las últimas 24 h.
  - `Response time per monitor`: serie temporal por monitor.
  - `Status table`: tabla por monitor con uptime % y last check.

> Si el dashboard muestra "No data" en todos los paneles, lo más probable es que el datasource no resuelva métricas — revisar `https://prometheus.lan/graph` y ejecutar la query `monitor_status` manualmente. Si **sí** aparecen métricas en Prometheus pero no en Grafana, es el caso §11 (placeholder no sustituido).

---

## 10. Verificación

### 10.1. Contenedor sano

```bash
docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml ps uptime-kuma
# STATUS: "Up X (healthy)".
```

### 10.2. Uptime Kuma no escucha en el host

```bash
sudo ss -ltn | awk '$4 ~ /:3001$/'
# Esperado: vacío (no se publica al host).

docker port uptime-kuma
# Esperado: vacío.
```

### 10.3. `/metrics` responde con basic_auth y devuelve métricas

```bash
# Sin auth → 401:
docker exec caddy wget -qO- -S http://uptime-kuma:3001/metrics 2>&1 | head -1
# Esperado: HTTP/1.1 401 Unauthorized.

# Con la API key (la misma que tiene Prometheus):
KEY=$(sudo cat /mnt/hd2t/services/monitoring/prometheus/secrets/uptime_kuma_api_key)
docker exec caddy wget -qO- --user='' --password="${KEY}" \
  http://uptime-kuma:3001/metrics | grep -E '^# HELP monitor_' | head
# Esperado:
#   # HELP monitor_status Uptime Kuma monitor status (1=UP, 0=DOWN, 2=PENDING, 3=MAINTENANCE)
#   # HELP monitor_response_time Uptime Kuma monitor response time (in milliseconds)
#   ...
```

### 10.4. Las métricas reflejan los monitores creados

```bash
KEY=$(sudo cat /mnt/hd2t/services/monitoring/prometheus/secrets/uptime_kuma_api_key)
docker exec caddy wget -qO- --user='' --password="${KEY}" \
  http://uptime-kuma:3001/metrics \
  | grep -E '^monitor_status\{' | head
# Esperado: una línea por cada monitor creado en §8.3 con status=1 (up) o 0 (down).
#   monitor_status{monitor_name="pihole-dns",monitor_type="dns",monitor_url="...",monitor_hostname="pi-hole.net",monitor_port="53"} 1
#   monitor_status{monitor_name="caddy-tls",...} 1
#   ...
```

### 10.5. El job aparece UP en Prometheus

```bash
docker exec caddy wget -qO- 'http://prometheus:9090/api/v1/query?query=up{job="uptime-kuma"}' \
  | python3 -m json.tool
# Esperado: { "status":"success", "data": {"result": [{"metric":{"job":"uptime-kuma","instance":"uptime-kuma:3001","service":"uptime-kuma",...}, "value":[..., "1"]}]} }

# Series por monitor visible desde Prometheus:
docker exec caddy wget -qO- 'http://prometheus:9090/api/v1/query?query=count(monitor_status)' \
  | python3 -m json.tool
# Esperado: value igual al número de monitores creados (10–14).
```

### 10.6. La UI responde detrás de Authelia

- `https://uptime.lan/` (sin sesión Authelia) → redirect a `https://auth.lan/`.
- Tras autenticación 2FA → `https://uptime.lan/dashboard`.
- En la URL `https://uptime.lan/api/status-page/heartbeat/<slug>` (status pages) responde 401/404 según se haya creado o no.

### 10.7. El dashboard renderiza en Grafana

En `https://grafana.lan/dashboards`, abrir **Uptime Kuma**:

- `Up monitors` ≈ número de monitores en §8.3 (todos `1` salvo los `*-future`).
- `Response time per monitor`: cada monitor con su latencia (DNS ~5 ms, HTTP local ~10–50 ms, Telegram API n/a — Kuma no monitorea su propio canal).
- `Status table`: filas por monitor con uptime últimas 24h.

### 10.8. Notificación de prueba llega

Test pasado en §8.4: parar un contenedor inocuo, esperar 90 s, ver alerta en Telegram, levantarlo, ver alerta de recuperación.

### 10.9. Persistencia tras reboot

```bash
sudo reboot
# (esperar a que vuelva)

docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml ps uptime-kuma
# Esperado: uptime-kuma (healthy).

# Los monitores siguen existiendo:
docker exec uptime-kuma ls -la /app/data/
# Esperado: kuma.db, kuma.db-shm, kuma.db-wal con timestamps recientes.

# Las métricas tienen continuidad:
# https://prometheus.lan/graph → monitor_status[1h]
# debe mostrar el hueco esperado del downtime y reanudar tras el boot.
```

### 10.10. Lista de Verificación

Antes de pasar a [`./06-dozzle.md`](./06-dozzle.md):

- [ ] `docker compose ps uptime-kuma` → `Up X (healthy)`.
- [ ] `sudo ss -ltn | grep -E ':3001'` → vacío en el host.
- [ ] `docker exec caddy wget -qO- http://uptime-kuma:3001/` devuelve HTML del SPA.
- [ ] `https://prometheus.lan/targets` → fila `uptime-kuma` en estado **UP**.
- [ ] PromQL `up{job="uptime-kuma"}` devuelve `1`.
- [ ] PromQL `count(monitor_status)` devuelve un valor coherente con el número de monitores creados.
- [ ] El bloque `uptime-kuma:` está en `~/homelab/stacks/monitoring/docker-compose.yml`; el `scrape_config` `uptime-kuma` está descomentado en `~/homelab/stacks/monitoring/prometheus.yml`; el bind mount `secrets/` está descomentado en `prometheus:`; ambos versionados en git.
- [ ] `~/homelab/stacks/proxy/Caddyfile` contiene el bloque `uptime.{$LAN_DOMAIN}` con `import authelia_proxy`; versionado en git.
- [ ] `~/homelab/stacks/auth/configuration.yml` lista `uptime.{LAN_DOMAIN}` en `access_control.rules` con `policy: two_factor`; versionado en git.
- [ ] `~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/uptime-kuma.json` versionado en git.
- [ ] `/mnt/hd2t/services/monitoring/prometheus/secrets/uptime_kuma_api_key` existe con perms `600 nobody:nogroup` y contenido (la API key real). **NO** versionado.
- [ ] `https://uptime.lan` accesible tras autenticar en Authelia (2FA).
- [ ] En `https://grafana.lan/dashboards` aparece "Uptime Kuma" con paneles renderizando.
- [ ] Notificación de prueba (§8.4) llega al móvil del operador vía Telegram.
- [ ] Tras `sudo reboot`, los monitores persisten y las métricas tienen continuidad.

---

## 11. Backup

| Ruta | Qué contiene | Frecuencia |
|---|---|---|
| `~/homelab/stacks/monitoring/docker-compose.yml` (bloque `uptime-kuma:`) | Definición del servicio. | Versionado en git → `git push`. |
| `~/homelab/stacks/monitoring/prometheus.yml` (job `uptime-kuma`) | Scrape config con `password_file`. | Versionado en git. |
| `~/homelab/stacks/monitoring/grafana/provisioning/dashboards/json/uptime-kuma.json` | Dashboard provisioned. | Versionado en git. |
| `~/homelab/stacks/proxy/Caddyfile` (bloque `uptime.lan`) | Reverse proxy + forward_auth. | Versionado en git. |
| `~/homelab/stacks/auth/configuration.yml` (entrada `uptime.lan`) | Regla Authelia. | Versionado en git. |
| `/mnt/hd2t/services/monitoring/.env` (`UPTIME_KUMA_*`) | Tag de imagen + hostname. | Borg con cifrado en repo (junto al resto de variables del stack, [`./01-prometheus.md`](./01-prometheus.md) §9). |
| `/mnt/hd2t/services/monitoring/uptime-kuma/data/kuma.db*` | **BD SQLite** con monitores, heartbeats, notificaciones, API keys, status pages, password hashes. | Borg con cifrado **diario**. Crítico: sin esta BD se pierden todos los monitores y hay que recrearlos a mano. |
| `/mnt/hd2t/services/monitoring/prometheus/secrets/uptime_kuma_api_key` | API key del scrape de Prometheus. | Borg con cifrado. **No** versionado en git. |

### 11.1. Quiesce del SQLite antes del backup

SQLite con WAL admite lectura concurrente sin lock, pero un backup por copia bruta (`cp kuma.db`) puede capturar un estado intermedio si el WAL no se ha checkpointado. La forma robusta es usar `sqlite3 .backup`:

```bash
# Ejecutar como root (la BD pertenece a root):
sudo sqlite3 /mnt/hd2t/services/monitoring/uptime-kuma/data/kuma.db \
  ".backup /mnt/hd2t/services/monitoring/uptime-kuma/data/kuma.db.backup"

# El fichero .backup queda con las páginas consistentes. Borg lo respalda
# como un blob normal.
```

> Esta llamada se documenta como **hook pre-backup** en la receta de Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)). Mientras llega esa fase, basta con respaldar el `kuma.db` directo: en una Pi sin tráfico apreciable a `kuma.db`, la probabilidad de capturar estado inconsistente es muy baja.

### 11.2. Restore

```bash
# Tras pérdida total (o nuevo nodo):
docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml stop uptime-kuma

# Restaurar el .db:
sudo cp /borg/restore/.../kuma.db.backup \
  /mnt/hd2t/services/monitoring/uptime-kuma/data/kuma.db
sudo chown root:root /mnt/hd2t/services/monitoring/uptime-kuma/data/kuma.db
sudo chmod 644 /mnt/hd2t/services/monitoring/uptime-kuma/data/kuma.db

# Levantar:
docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml up -d uptime-kuma

# Verificar:
docker logs uptime-kuma --tail 20
# Esperado: "Listening on 3001" sin errores de migración.
```

> El `kuma.db` restaurado trae las API keys y los `bot_token` de Telegram cifrados con la clave maestra de Kuma (que está en el propio `.db`). Por eso no se requiere paso adicional para reactivar las notificaciones tras el restore.

---

## 12. Operaciones cotidianas

### 12.1. Añadir un monitor nuevo

UI manual, ya cubierto en §8.3. Para mantener el "estado declarativo" del homelab, anotar la lista de monitores en `~/homelab/stacks/monitoring/MONITORS.md` (markdown libre, versionado en git) cada vez que se añada uno; sirve de runbook para reconstruir los monitores tras un desastre que pierda `kuma.db`.

### 12.2. Rotar la API key de Prometheus

```bash
# 1. UI Kuma → Settings → API Keys → click en `prometheus-scrape` → "Disable" (o eliminarla y crear otra "prometheus-scrape-2"). Generar la nueva.
# 2. Copiar la nueva key al fichero secret:
sudo tee /mnt/hd2t/services/monitoring/prometheus/secrets/uptime_kuma_api_key >/dev/null <<EOF
<NUEVA_KEY>
EOF
sudo chmod 600 /mnt/hd2t/services/monitoring/prometheus/secrets/uptime_kuma_api_key
sudo chown nobody:nogroup /mnt/hd2t/services/monitoring/prometheus/secrets/uptime_kuma_api_key

# 3. Reload de Prometheus (suficiente: lee password_file en cada request,
# salvo cache TTL):
docker exec caddy wget -q --post-data='' -O- http://prometheus:9090/-/reload

# 4. Verificar que el target sigue UP en /targets.
```

### 12.3. Cambiar el password del admin local de Kuma

UI: arriba a la derecha → click en el avatar → **Profile → Change Password**. Anotar el nuevo password en el gestor de contraseñas. **No** se versiona el `kuma.db`, pero el cambio queda dentro de él, que sí se respalda.

### 12.4. Subir el nivel de log para troubleshooting

Kuma 1.23 no expone `--verbose` por flag; el nivel se controla con la variable `UPTIME_KUMA_LOG_LEVEL` (valores: `trace`, `debug`, `info`, `warn`, `error`):

```bash
# En docker-compose.yml, añadir TEMPORALMENTE en el bloque environment:
#   environment:
#     UPTIME_KUMA_LOG_LEVEL: debug

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate uptime-kuma

# Tras diagnosticar:
docker compose logs uptime-kuma | tail -200

# Revertir (eliminar la variable o ponerla a `info`) y volver a recrear.
```

### 12.5. Pausar todos los monitores durante mantenimiento

UI: **Settings → Maintenance → New Maintenance**:
- Title: `Mantenimiento ventana semanal`.
- Strategy: `Manual`.
- Affected Monitors: seleccionar todos los relevantes.
- Click `Pause` cuando empiece la ventana, `Resume` al terminar.

Durante el `Maintenance` los monitores no envían notificaciones aunque cambien de estado (status=3 en `monitor_status`). El dashboard de Grafana muestra esos huecos en color distinto.

### 12.6. Upgrade manual

```bash
# Antes de cambiar el tag, leer:
# https://github.com/louislam/uptime-kuma/releases
# (busca "DB schema migration" en cada release).

# Backup obligatorio antes de subir minor:
sudo sqlite3 /mnt/hd2t/services/monitoring/uptime-kuma/data/kuma.db \
  ".backup /mnt/hd2t/services/monitoring/uptime-kuma/data/kuma.db.preupgrade"

sudo sed -i 's|^UPTIME_KUMA_IMAGE_TAG=.*|UPTIME_KUMA_IMAGE_TAG=1.23.17-debian|' \
  /mnt/hd2t/services/monitoring/.env

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env pull uptime-kuma
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate uptime-kuma

# Verificar:
docker compose ps uptime-kuma
docker logs uptime-kuma --tail 30
# Esperado: "Database Patch X.Y process" + "Listening on 3001".
```

> Watchtower **sí** actualiza Kuma automáticamente a las 04:00 si el tag pinneado tiene una nueva digest (caso típico: parche de seguridad dentro del mismo `1.23.16-debian`). Para minors (1.23 → 1.24) y majors el upgrade manual permite ver el changelog y validar el backup antes de migrar el schema.

### 12.7. (Variante futura) Sustituir el bind del socket Docker por `docker-socket-proxy`

Si una auditoría exige no exponer `/var/run/docker.sock` directamente al contenedor, se intercala un proxy lectura-only:

```yaml
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:0.3
    container_name: docker-socket-proxy
    restart: unless-stopped
    environment:
      CONTAINERS: "1"
      INFO: "1"
      VERSION: "1"
      EVENTS: "1"
      PING: "1"
      # Todo lo demás a 0 (POST, DELETE, etc.).
    volumes:
      - type: bind
        source: /var/run/docker.sock
        target: /var/run/docker.sock
        read_only: true
    networks:
      - homelab
    cap_drop: [ALL]
    security_opt:
      - no-new-privileges:true
    mem_limit: 32m

  uptime-kuma:
    # ... resto sin cambios ...
    environment:
      # ... existentes ...
      DOCKER_HOST: "tcp://docker-socket-proxy:2375"
    volumes:
      # Eliminar el bind directo de docker.sock; ya no se monta.
      - type: bind
        source: /mnt/hd2t/services/monitoring/uptime-kuma/data
        target: /app/data
        bind:
          create_host_path: false
```

En la UI de Kuma → **Settings → Docker Hosts → Add**: `Docker Type: TCP`, `Docker Daemon: tcp://docker-socket-proxy:2375`. Recrear los monitores tipo "Docker container" para que apunten a este nuevo host. **Estado actual**: documentado por completitud; el homelab inicial usa el bind directo por simplicidad.

---

## 13. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `docker compose up uptime-kuma` falla con `network homelab declared as external, but could not be found` | La red `homelab` no está creada. | Crearla según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2. |
| `docker compose up uptime-kuma` falla con `Mounts denied: ... /var/run/docker.sock` | El path no existe (Docker Desktop, modo rootless, ...). | Comprobar `ls -l /var/run/docker.sock`. Si no existe, eliminar el bind del `docker.sock` del compose: los monitores tipo "Docker container" dejarán de funcionar, pero el resto sigue. |
| `uptime-kuma` arranca pero la UI devuelve `502 Bad Gateway` desde Caddy | Healthcheck aún no ha pasado y Caddy tiene la ruta upstream marcada como down (caso raro: Caddy no usa healthchecks por defecto, pero algunos plugins sí). | Esperar 60–90 s al `start_period`. Si persiste, `docker logs uptime-kuma` para ver si la migración SQLite está bloqueada. |
| El target `uptime-kuma` aparece **DOWN** con `401 Unauthorized` en `/targets` | La API key del fichero `/etc/prometheus/secrets/uptime_kuma_api_key` no coincide con la registrada en Kuma. | Regenerar la key en Kuma (§6.5.5), copiarla al fichero, `chown nobody:nogroup`, `chmod 600`, `docker exec caddy wget -q --post-data='' -O- http://prometheus:9090/-/reload`. Verificar que no hay caracteres `\r` o BOM con `xxd`. |
| El target `uptime-kuma` aparece **DOWN** con `connection refused` | El contenedor no resuelve por DNS interno o no está sano. | `docker inspect uptime-kuma --format '{{.State.Health.Status}}'`. Si `unhealthy`, revisar los logs y el `start_period`. |
| `docker exec uptime-kuma /usr/bin/node /app/extra/healthcheck.js` falla con `connect ECONNREFUSED 127.0.0.1:3001` | El servidor de Kuma aún no está escuchando o ha crashed. | `docker logs uptime-kuma | tail -50`. Causas comunes: BD corrupta tras reboot brusco (recuperar con backup, §11.2), `mem_limit` demasiado bajo (subir a 512m), permiso roto en `/app/data` (`docker exec uptime-kuma ls -la /app/data` debe ser writable por root). |
| Las notificaciones de Telegram no llegan | Bot token o chat_id incorrectos; o salida HTTPS bloqueada. | UI Kuma → Settings → Notifications → seleccionar el canal → **Test**. Si falla con "Telegram error: Forbidden: bot was blocked by the user", el usuario tiene que escribirle un `/start` al bot primero. Si el test pasa pero las alertas reales no, verificar que el monitor tiene marcado el canal en su lista de notificaciones. |
| Los monitores DNS apuntan a `pihole:53` pero fallan con `getaddrinfo ENOTFOUND` | El resolver Docker no resuelve el nombre `pihole`. | `docker exec uptime-kuma getent hosts pihole`. Si no resuelve, el contenedor está en una red sin Pi-hole; verificar `docker inspect uptime-kuma --format '{{json .NetworkSettings.Networks}}'`: debe listar `homelab`. |
| El monitor "Ping" devuelve `ping: socket: Permission denied` | Kernel no permite ICMP unprivileged para el GID actual. | Verificar `cat /proc/sys/net/ipv4/ping_group_range` en el host: debe ser algo como `0 2147483647`. Si está restringido, añadir `cap_add: [NET_RAW]` al servicio en el compose y recrear. |
| Los monitores HTTP a `https://*.lan` fallan con "Cannot verify TLS" | La CA interna del homelab no está en el truststore del contenedor de Kuma. | Opción A (recomendada): probar `http://<container_name>:<port>` interno en lugar de `https://*.lan` (más rápido y sin TLS). Opción B: montar `/mnt/hd2t/services/proxy/caddy/data/caddy/pki/authorities/local/root.crt` en `/usr/local/share/ca-certificates/homelab.crt` del contenedor Kuma + `update-ca-certificates`; complica el compose. La opción A es lo que recomienda este doc en §8.3. |
| El dashboard #18667 está casi todo vacío | El placeholder `${DS_PROMETHEUS}` no se sustituyó en el JSON. | Aplicar §9.1.2 (sed + limpieza de `__inputs`). Tras editar el JSON, esperar ≤30 s al refresh del provider de Grafana. |
| `uptime-kuma` se reinicia en bucle por OOM (`exit 137`) | `mem_limit: 256m` se queda corto al cargar 6 meses de heartbeat con 30+ monitores. | Subir `mem_limit: 512m` y `memswap_limit: 512m`. Si persiste, reducir el historial: UI → Settings → Heartbeats → "Keep monitor history" a 90 días. |
| La UI carga pero los gráficos quedan vacíos / spinner infinito | Socket.IO falla por mismatch de versión Caddy↔Kuma o por una cabecera bloqueada. | Probar acceso DIRECTO desde el bridge (`docker exec caddy curl -k http://uptime-kuma:3001/socket.io/?EIO=4&transport=polling`). Si responde, el problema está en Caddy: revisar que `import authelia_proxy` no sobreescribe `header_up Connection` ni `Upgrade`. |
| `uptime-kuma` arranca con `Error: SQLITE_NOTADB: file is not a database` tras un `kill -9` | WAL corrupto. | Recuperar desde el `.backup` más reciente (§11.2). Si no hay backup, intentar `sqlite3 kuma.db ".recover" > recovered.sql` + `sqlite3 new.db < recovered.sql` (lossy). Activar Borgmatic ASAP cuando llegue Fase 7. |
| Watchtower actualiza la imagen a `1.24.0-debian` y rompe la migración | Cambio de minor con DB schema migration que falla. | Pin del tag en `.env` (ya hecho) **+** restaurar `kuma.db.backup` previo + revertir el tag a `1.23.16-debian` + `up -d --force-recreate uptime-kuma`. Documentar el incidente y planificar el upgrade manual con backup obligatorio. |
| El monitor "Docker container" devuelve "container not found" para uno que existe | El socket de Docker no está montado o Kuma usa el `Default` Docker host (que no se ha configurado). | UI → Settings → Docker Hosts → confirmar que existe un host `Local Docker socket` con `Connection Type: Socket` y `Docker Daemon: /var/run/docker.sock`. Si no, añadirlo. |

---

## Referencias

- [Uptime Kuma — Repo y CHANGELOG (GitHub)](https://github.com/louislam/uptime-kuma)
- [Uptime Kuma — Imagen Docker oficial (Docker Hub)](https://hub.docker.com/r/louislam/uptime-kuma)
- [Uptime Kuma — Wiki "Reverse Proxy" (cabeceras requeridas para Caddy/Nginx/Traefik)](https://github.com/louislam/uptime-kuma/wiki/Reverse-Proxy)
- [Uptime Kuma — Wiki "Prometheus Metrics" (lista completa de monitor_*)](https://github.com/louislam/uptime-kuma/wiki/Prometheus-metrics)
- [Uptime Kuma — Wiki "Docker container monitoring"](https://github.com/louislam/uptime-kuma/wiki/Docker-container-monitor)
- [Prometheus — `basic_auth` con `password_file`](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config)
- [Telegram — Bot API (`getUpdates`, `sendMessage`)](https://core.telegram.org/bots/api)
- [Caddy — `reverse_proxy` con WebSockets / Socket.IO](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#websockets)
- [Authelia — `forward_auth` con Caddy](https://www.authelia.com/integration/proxies/caddy/)
- [Grafana.com — Dashboard "Uptime Kuma — Service Status" (#18667)](https://grafana.com/grafana/dashboards/18667-uptime-kuma/)
- [SQLite — BACKUP API (uso en `.backup` desde shell)](https://www.sqlite.org/backup.html)
- [tecnativa/docker-socket-proxy — Read-only proxy del socket Docker (variante futura §12.7)](https://github.com/Tecnativa/docker-socket-proxy)
