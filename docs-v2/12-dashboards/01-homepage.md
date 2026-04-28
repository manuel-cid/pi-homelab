# Homepage

## Descripción

Despliegue de **Homepage** (`ghcr.io/gethomepage/homepage`, Next.js + Node.js, GPL-3.0) como **página de inicio del homelab**: una única vista web (`https://home.{$LAN_DOMAIN}`) que agrupa enlaces a todos los servicios, los pinta con su icono y descripción, marca cuáles están **online** consultando el socket Docker y, para los servicios que exponen API, **muestra widgets en vivo** con datos reales (consultas DNS de Pi-hole, monitores caídos en Uptime Kuma, descargas activas en Transmission, espacio libre en Nextcloud, # documentos en Paperless-ngx, # entidades en Home Assistant, etc.). Encima del listado hay widgets **de host** (CPU/RAM/disco/uptime de la Pi 5, leídos del propio socket Docker), un buscador con backends configurables (DuckDuckGo, Google, Searx, Bing), un reloj y un panel de bookmarks. Toda la configuración vive como **YAML versionable** en `/mnt/hd2t/services/homepage/config/` (`services.yaml`, `widgets.yaml`, `settings.yaml`, `bookmarks.yaml`, `docker.yaml`); no hay base de datos, no hay UI de edición — la fuente de verdad es git.

Homepage es el **único** servicio del stack `dashboard` (fila §1.1 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md), línea 80). Este documento crea ese stack desde cero (`~/homelab/stacks/dashboard/docker-compose.yml`) e introduce además un **acompañante**: `tecnativa/docker-socket-proxy` (un microproxy de la API Docker) para que Homepage hable con el socket de Docker **sin** ver `/var/run/docker.sock` directamente. Tras este doc el stack tiene dos servicios (`homepage`, `dockerproxy`), la Fase 12 queda completa, y la siguiente fase ([`../13-operaciones/01-mantenimiento-periodico.md`](../13-operaciones/01-mantenimiento-periodico.md)) cierra el plan del homelab con el manual operativo.

> **Alcance de red**: la UI de Homepage se sirve **únicamente** vía Caddy en `https://home.{$LAN_DOMAIN}`, protegida por **Authelia con `policy: one_factor`** (es la pantalla diaria de aterrizaje; los widgets revelan métricas operativas — # de monitores caídos, % de disco usado, descargas activas — pero no secretos: las API keys de los widgets viven en el `.env` montado, no en la UI). El operador que quiera elevar la postura a `two_factor` lo activa en §12.4. Homepage **no** publica `:3000` al host; **no** se expone a internet. Las únicas conexiones salientes son: (1) el socket Docker, indirectamente vía `dockerproxy` en la red `dashboard_internal`; (2) HTTP(S) hacia los demás servicios del homelab por la red `homelab` (para los widgets que llaman a sus APIs locales: `http://pihole`, `http://uptime-kuma:3001`, `http://nextcloud`, etc.); (3) DNS hacia Pi-hole + Unbound y (4) la URL del buscador externo cuando el operador escribe en el cuadro de búsqueda — esa última conexión la inicia el navegador del cliente, **no** el contenedor.

> **Por qué Homepage y no otra herramienta** (Heimdall, Dashy, Organizr, Flame, Glance, una página HTML estática a mano):
>
> 1. **YAML versionable como única fuente**. La configuración entera son cinco ficheros `.yaml` (servicios, widgets, settings, bookmarks, integración Docker). Eso encaja con la filosofía del homelab (`docker-compose.yml` + `.env.example` en git, secretos fuera) y con la convención que [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) ha estado prefigurando con las labels `homepage.group`/`homepage.name`/`homepage.icon`/`homepage.href`/`homepage.description`. Heimdall y Organizr son configurables por UI con BD propia; al primer reset de microSD se pierde el dashboard si no se respaldó. Homepage no tiene UI de edición — eso es una **virtud** aquí: cada cambio pasa por `git commit`.
> 2. **Auto-descubrimiento por labels Docker**. Las labels `homepage.*` que cada compose del homelab ya pre-rellenó (Pi-hole, Caddy, Authelia, Prometheus, Grafana, Uptime Kuma, Dozzle, Nextcloud, Syncthing, Bookstack, Paperless-ngx, Watchtower, Portainer, MinIO) generan automáticamente las tarjetas en Homepage cuando el flag `docker.<host>.includeStopped` se activa para el descubrimiento. La parte estática (servicios sin labels: Authelia auxiliar, snapshots, etc.) se declara explícitamente en `services.yaml`.
> 3. **Widgets nativos para casi todo el catálogo del homelab**. Homepage trae soporte de primera para: Pi-hole, Portainer, Watchtower, Prometheus, Grafana, Uptime Kuma, Jellyfin, Navidrome, Audiobookshelf, Calibre-Web, Sonarr, Radarr, Prowlarr, Transmission, Nextcloud, Vaultwarden, Paperless-ngx, Mealie, Home Assistant, MQTT (vía Mosquitto). De los 30 servicios del homelab, ~22 tienen widget oficial. Para el resto (FreshRSS, Stash, Linkding, Bookstack, Stirling-PDF, Samba, Syncthing, Borgmatic, MinIO) se pinta sólo la tarjeta con icono + ping de salud. Esto cubre ≥95 % del valor "ver de un vistazo el estado del homelab".
> 4. **Multi-arch oficial desde 0.6**. La imagen `ghcr.io/gethomepage/homepage` se publica para `linux/arm64/v8` (junto a `linux/amd64`) directamente en GitHub Container Registry. Sin ajustes en una Pi 5.
> 5. **Coste mínimo**. Idle 80–120 MB RAM (Next.js compilado, frontend SSR), CPU < 1 % en background. Cuando el operador abre la UI, sube a 150 MB durante el render del SSR; al cerrarse la pestaña, baja. Cabe sin ajustes en la Pi 5 (8 GB).
> 6. **Iconos centralizados**. Homepage usa por defecto el set [`dashboard-icons`](https://github.com/walkxcode/dashboard-icons) (CDN público) con fallback local. Cada label `homepage.icon: <nombre>.png` ya colocada en los composes del homelab apunta al icono en formato `<nombre>.png` o `<nombre>.svg` del set. Para iconos custom (logos privados, marcadores personales) se puede montar un directorio `/app/public/icons/` con PNGs propios — variante §12.5.
> 7. **Sin telemetría**. Homepage no envía analytics, no hace check-update phone-home, no lee variables de tracking. La única conexión saliente del contenedor (más allá de las APIs del homelab) es opcional: el favicon del buscador o el CDN de iconos cuando el navegador del cliente los pide (no el contenedor); con `bookmarks.yaml.icon` apuntando a un archivo local, ni siquiera eso.
>
> Otras alternativas: **Heimdall** está abandonado de facto (último release julio 2023) y obliga a UI; **Dashy** es muy completo pero su build de SSR consume el doble de RAM y tiene historial de breaking changes en los YAML; **Organizr** centra su valor en SSO compartido (cubierto aquí por Authelia); **Glance** y **Flame** son minimalistas pero sin widgets nativos para ARRs ni Pi-hole; una **página HTML a mano** pierde el auto-descubrimiento y los widgets en vivo, que son el 80 % del valor de un dashboard.

---

## Requisitos Previos

- **Caddy desplegado y sano** según [`../03-red/04-caddy.md`](../03-red/04-caddy.md): `docker inspect caddy --format '{{.State.Health.Status}}'` devuelve `healthy`. El `Caddyfile` carga snippets `lan_internal_tls`, `security_headers` y `authelia_proxy`. La CA interna del homelab está confiada en el navegador del operador. El bloque comentado de Homepage ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) líneas 444-449) se descomentará y se completará en §6 de este doc.
- **Authelia desplegado y sano** según [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md): `docker inspect authelia --format '{{.State.Health.Status}}'` devuelve `healthy`. El operador tiene un usuario en `users_database.yml` con `groups: [admin]` y al menos un dispositivo TOTP enrolado. El snippet `authelia_proxy` reenvía cabeceras `Remote-*`.
- **Pi-hole desplegado y sano** según [`../03-red/02-pihole.md`](../03-red/02-pihole.md): la UI permite añadir un registro DNS local `home.lan → 192.168.1.10` en §6.3. La API key admin de Pi-hole se obtendrá en §7.4 para el widget correspondiente.
- **Stack `monitoring` completo** (Prometheus, Grafana, Node Exporter, cAdvisor, Uptime Kuma, Dozzle): `docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml ps` muestra los seis servicios `(healthy)`. Las API keys/tokens de Uptime Kuma y Grafana se obtuvieron y guardaron durante sus respectivos despliegues; aquí se reutilizan para los widgets.
- **Stacks de servicios del homelab desplegados** (los que se quieran mostrar). Homepage no exige un orden estricto: cada tarjeta se pinta cuando su contenedor existe; las tarjetas de servicios todavía no desplegados se omiten (o aparecen "offline" según se prefiera, ver §7.2). En la práctica, este doc se aplica **al final** de las fases anteriores para que el dashboard nazca completo.
- **Red `homelab`** creada según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2 (`172.20.0.0/24`, bridge `br-homelab`, `external: true`).
- **Estructura de directorios**: el bootstrap original ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6.6) ya creó `/mnt/hd2t/services/homepage/` con `homelab:homelab` y modo `750`. En §3.1 se prepara debajo el árbol `config/` y `icons/`.
- **`/var/run/docker.sock` accesible** y **GID `docker` conocido**: `getent group docker | cut -d: -f3` devuelve un entero (998 en RPi OS Bookworm). El proxy `dockerproxy` y, eventualmente, el contenedor Homepage si alguien decidiera dirigirse al socket sin proxy (variante §12.6) lo necesitan. En la configuración por defecto de este doc, **sólo `dockerproxy`** habla al socket, y lo hace vía `group_add: ${DOCKER_GID}`.
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No se añaden reglas: Homepage no publica puertos al host; Caddy ya escucha en 443.
- **Comprobaciones rápidas**:
  ```bash
  # Caddy y Authelia sanos:
  docker inspect caddy authelia --format '{{.Name}} {{.State.Health.Status}}'
  # Esperado: /caddy healthy / /authelia healthy

  # Hay servicios del homelab corriendo (al menos los del stack monitoring):
  docker ps --format '{{.Names}}\t{{.Status}}' | head -20

  # GID del grupo docker (necesario para el .env):
  getent group docker | awk -F: '{print "DOCKER_GID="$3}'
  # Esperado: DOCKER_GID=998 (o similar, depende del host).

  # El bloque comentado de Homepage existe en el Caddyfile:
  grep -A4 '# Homepage' ~/homelab/stacks/proxy/Caddyfile
  # Esperado: las 4 líneas comentadas que se descomentarán en §6.1.

  # /mnt/hd2t/services/homepage/ existe y es del operador:
  stat -c '%U %G %a' /mnt/hd2t/services/homepage/
  # Esperado: homelab homelab 750
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Imagen Docker | **`ghcr.io/gethomepage/homepage:v0.10.9`** | Imagen oficial multi-arch del proyecto upstream (GPL-3.0). La rama 0.10.x es la estable actual con soporte ARM64 estable y el set de widgets más completo (a partir de 0.10.0 los widgets oficiales para Pi-hole v6, Vaultwarden, Authelia v4 y Watchtower 1.7+ están al día). Tag pinneado a release puntual, nunca `latest` (regla [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1). |
| Imagen del socket-proxy | **`ghcr.io/tecnativa/docker-socket-proxy:0.3.0`** | Proyecto upstream Apache-2.0, multi-arch, ampliamente usado y revisado. La 0.3.x es la primera release con soporte estable de las flags `CONTAINERS=1`, `INFO=1`, `EVENTS=1`, `PING=1` que Homepage necesita y nada más. |
| Política de Watchtower (homepage) | **`watchtower.enable: "true"`** | Coherente con [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2. Homepage no tiene esquema de BD ni datos persistentes propios: los YAML viven en disco, sobreviven al recreate, y los upgrades dentro de 0.10.x son seguros. Cuando suba a 0.11.x se revisa el changelog antes; mientras el `.env` apunta a `v0.10.9` Watchtower no hace nada hasta que se suba el tag manualmente. |
| Política de Watchtower (dockerproxy) | **`watchtower.enable: "false"`** | El proxy expone el socket Docker. Cualquier upgrade que cambie sus defaults inseguros (caso poco probable, pero auditable) debe revisarse a mano. Misma postura que con Pi-hole, Caddy y Authelia. |
| Modo de red | **`homelab` + `dashboard_internal`** | Dos redes: (1) `homelab` (external) para que Caddy llame a `http://homepage:3000` y para que Homepage llame a las APIs de los servicios (Pi-hole, Uptime Kuma, Nextcloud, ...). (2) `dashboard_internal` (bridge interno del stack) para Homepage ↔ dockerproxy. dockerproxy **no** se conecta a `homelab`: vive sólo en `dashboard_internal`. Eso aísla la API Docker (puerto 2375 del proxy) de cualquier otro contenedor del homelab. |
| `ports:` publicados al host | **Ninguno** (ni `homepage`, ni `dockerproxy`) | La UI se sirve **únicamente** vía Caddy. dockerproxy escucha 2375/tcp **sólo** en `dashboard_internal`. Publicarlo al host expondría la API Docker al LAN. |
| Acceso a la UI | **Detrás de Authelia** (`forward_auth`, política `one_factor`) | Homepage es la pantalla diaria de aterrizaje; los widgets revelan métricas operativas no triviales (% disco, alertas activas, descargas). `one_factor` (usuario+password con cookie de sesión Authelia) cubre el caso "no quiero que cualquiera con acceso a la LAN abra el dashboard". El operador puede subir a `two_factor` en §12.4 si en algún momento se enrola un dispositivo IoT cuestionable o se da acceso WiFi a invitados. |
| Reverse-proxy en Caddy | **SÍ**, `home.{$LAN_DOMAIN}` | Hostname corto y memorable; convención del homelab (igual que `auth.lan`, `vault.lan`, `uptime.lan`, `logs.lan`). El Caddyfile ya tenía el bloque preparado y comentado ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) líneas 444-449). |
| Persistencia | **Bind mount** `/mnt/hd2t/services/homepage/config` → `/app/config` (rw) y, opcional, `/mnt/hd2t/services/homepage/icons` → `/app/public/icons` (ro) | El primero contiene los YAML de configuración + un fichero `homepage.log` que la app va escribiendo. El segundo, opt-in, contiene PNGs/SVGs custom (logos privados de bookmarks, etc.) que el set público de iconos no tiene. Ambos en hd2t para que Borg los respalde por path predecible. |
| Usuario del contenedor | **`PUID=1000` / `PGID=1000`** (`homelab:homelab`) | La imagen oficial soporta `PUID`/`PGID` por env. Mapearlo al UID del operador alinea la propiedad de los YAML escritos por la app con la propiedad del directorio en el host: `git diff` desde el repo del operador funciona sin `sudo`. |
| Acceso al socket Docker | **Indirecto vía `tecnativa/docker-socket-proxy`** (`CONTAINERS=1`, `INFO=1`, `EVENTS=1`, `PING=1`, todo lo demás `=0`) | Homepage 0.10+ acepta hablar con un proxy HTTP en lugar del socket UNIX, vía `docker.<host>.socket: tcp://dockerproxy:2375` o equivalente en `docker.yaml`. El proxy aplica un firewall a la API Docker: sólo deja pasar las llamadas `GET /containers/json`, `GET /containers/<id>/json`, `GET /events`, `GET /info` y `GET /_ping`. Eso reduce el blast-radius si la imagen de Homepage se viera comprometida (no podría ejecutar `docker exec`, no podría parar contenedores, no podría leer los volúmenes de otros). dockerproxy a su vez monta el socket UNIX en read-only. La superficie es estrictamente menor que la que tiene cAdvisor o Dozzle. |
| `cap_drop`/`cap_add` (homepage) | **`cap_drop: [ALL]`**, sin `cap_add` | El proceso Node de Homepage no necesita capabilities especiales: HTTP server interno + cliente HTTP saliente. |
| `cap_drop`/`cap_add` (dockerproxy) | **`cap_drop: [ALL]`** + `cap_add: [CHOWN, SETUID, SETGID]` | El proxy (basado en haproxy) necesita estos tres caps para arrancar como root y bajarse a `nobody`. Ningún cap de red privilegiada — el bind a 2375/tcp es no privilegiado. |
| `security_opt: no-new-privileges:true` | **Activado** en ambos | Plantilla §6.1 de estructura-compose. Sin coste; refuerza la postura. |
| `read_only: true` (homepage) | **NO** se activa | Homepage escribe a `/app/config/logs/homepage.log` y a `/app/.next/cache` durante el SSR. Forzar root-FS read-only obligaría a montar tmpfs en al menos dos paths y rompería el log persistente entre recreates. La superficie de escritura está acotada por el bind mount (`/app/config` es el único path rw expuesto). |
| `read_only: true` (dockerproxy) | **Activado** + `tmpfs: /var/lib/haproxy` | El proxy es prácticamente stateless: lee la config en el entrypoint y mantiene una cache pequeña en `/var/lib/haproxy`. Read-only + tmpfs es lo más restrictivo posible. |
| Healthcheck (homepage) | **`wget /api/healthcheck`** | Endpoint canónico de Homepage 0.10+ (sin auth, devuelve 200 con JSON `{"status":"ok"}` cuando el SSR está listo y la lectura de los YAML no ha fallado). Si un YAML está roto, el endpoint devuelve 500 y el contenedor entra en `unhealthy`. |
| Healthcheck (dockerproxy) | **`wget /_ping`** | El proxy expone el endpoint `_ping` de la API Docker (siempre permitido por la flag `PING=1`), idempotente, devuelve `OK`. |
| Logs Docker | **`json-file` 10 MB × 3** (heredado del demonio) | Plantilla §6.1 de estructura-compose. Homepage genera unos pocos logs por sesión + un log SSR por render. dockerproxy logea cada llamada a la API; con 1 llamada por servicio cada 30 s y ~30 servicios, son ~3000 líneas/h, ~70k líneas/día — los 30 MB rotativos cubren >2 días. |
| Memoria del contenedor (homepage) | **`mem_limit: 256m`** | Idle ~80–120 MB. Límite duro a 256 MB protege contra leaks y picos de SSR durante render concurrente. La pérdida si Docker mata el contenedor es 0 (los YAML están en disco). |
| Memoria del contenedor (dockerproxy) | **`mem_limit: 64m`** | El binario haproxy con la config de socket-proxy idle <10 MB. 64 MB es holgura. |
| Variable `HOMEPAGE_ALLOWED_HOSTS` | **`home.{$LAN_DOMAIN}, home.{$TS_DOMAIN}`** | Homepage 0.9+ exige una whitelist explícita de hosts a los que responde el SSR (defensa contra Host-header injection). Coincide con los hostnames que Caddy usará. Cuando se active Tailscale ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) `${TS_DOMAIN}` ya estará interpolado y la lista cubre ambos accesos. |
| Variables `HOMEPAGE_VAR_*` | **Todas las API keys y tokens de los widgets**, leídas desde `/mnt/hd2t/services/homepage/.env` | Homepage soporta sustituir `{{HOMEPAGE_VAR_FOO}}` en los YAML por la env var `HOMEPAGE_VAR_FOO`. Eso permite **versionar `services.yaml` y `widgets.yaml` en git** sin filtrar tokens: las claves vivas viven sólo en el `.env`. Mismo patrón que el resto del homelab. |
| Auto-descubrimiento por labels Docker | **Activado** (en `docker.yaml` y vía `homepage.*` labels en cada compose) | El homelab ya rellenó las labels en cada `docker-compose.yml` (§3.6 de estructura-compose). Activarlo ahorra duplicación: cuando un servicio se redespliega con `homepage.href: "https://foo.lan"` distinto, el dashboard lo recoge en el siguiente refresh sin tocar `services.yaml`. |
| Refresco de widgets | **30 s** (default upstream) | Configurable por widget en `widgets.yaml`. 30 s es un compromiso entre frescura y carga sobre las APIs scrapeadas. Para Pi-hole y Uptime Kuma (donde 5 s sería deseable) se puede bajar; para Nextcloud (caro) subir a 60 s. |
| Tema | **Modo automático** (`light/dark` según preferencia del navegador) | Default upstream. Se fija en `settings.yaml`. |

---

## 1. Resumen de la arquitectura

```
                ┌────────────────────── HOST: Pi 5 (Raspberry Pi OS) ──────────────────────┐
                │                                                                           │
                │  /var/run/docker.sock                                                     │
                │         ▲                                                                 │
                │         │ ro (sólo dockerproxy lo monta)                                  │
                │         │                                                                 │
                │   ┌─────┼──────────────────── docker network: dashboard_internal ──────┐  │
                │   │     │      (bridge, no expuesta al LAN, no external)              │  │
                │   │  ┌──┴──────────────── dockerproxy ──────────────────────┐         │  │
                │   │  │ image: ghcr.io/tecnativa/docker-socket-proxy:0.3.0    │         │  │
                │   │  │ user:  nobody (cap_add: CHOWN/SETUID/SETGID)          │         │  │
                │   │  │ group_add: ${DOCKER_GID}  (acceso al socket UNIX)     │         │  │
                │   │  │ env:   CONTAINERS=1 INFO=1 EVENTS=1 PING=1            │         │  │
                │   │  │        (todo lo demás =0 → 403/405)                   │         │  │
                │   │  │ ports: -                                              │         │  │
                │   │  │ healthcheck: wget /_ping                              │         │  │
                │   │  │ read_only: true   tmpfs: /var/lib/haproxy             │         │  │
                │   │  └──────────────────────────────────────┬────────────────┘         │  │
                │   │                                          │ tcp:2375 (sólo dentro)   │  │
                │   │                                          │ filtrado por haproxy     │  │
                │   │  ┌───────────────────────────────────────┴─── homepage ──────────┐ │  │
                │   │  │ image: ghcr.io/gethomepage/homepage:v0.10.9                   │ │  │
                │   │  │ user:  PUID=1000 PGID=1000                                    │ │  │
                │   │  │ ports: -                                                       │ │  │
                │   │  │ env:   HOMEPAGE_ALLOWED_HOSTS=home.lan,home.${TS_DOMAIN}       │ │  │
                │   │  │        HOMEPAGE_VAR_PIHOLE_KEY=...                             │ │  │
                │   │  │        HOMEPAGE_VAR_UPTIMEKUMA_TOKEN=...   (etc.)              │ │  │
                │   │  │ volumes:                                                       │ │  │
                │   │  │   /mnt/hd2t/services/homepage/config :/app/config rw           │ │  │
                │   │  │   /mnt/hd2t/services/homepage/icons  :/app/public/icons ro     │ │  │
                │   │  │ healthcheck: wget /api/healthcheck                             │ │  │
                │   │  │ networks: [dashboard_internal, homelab]                        │ │  │
                │   │  └───────────────────────────────────────────────────────────────┘ │  │
                │   └────────────────────────────────────────────────────────────────────┘  │
                │                       │ http://homepage:3000  (red homelab)                │
                │                       │                                                    │
                │   ┌───────────────────┴───── docker network: homelab (external) ────────┐  │
                │   │                                                                     │  │
                │   │   homepage  ◄──────────  caddy (reverse_proxy + forward_auth)       │  │
                │   │      │                       │                                       │  │
                │   │      │    GET /api/...       │ Authelia: 1FA                         │  │
                │   │      │  (widgets activos)    │                                       │  │
                │   │      ▼                       │                                       │  │
                │   │   pihole  uptime-kuma  grafana  nextcloud  paperless  jellyfin       │  │
                │   │   sonarr  radarr  prowlarr  transmission  vaultwarden  homeassistant │  │
                │   │   portainer  watchtower  (etc.)                                      │  │
                │   └────────────────────────────────────────────────────────────────────┘  │
                │                       ▲                                                    │
                │                       │ HTTPS 443                                          │
                │                       │                                                    │
                └───────────────────────┼────────────────────────────────────────────────────┘
                                        │
                                LAN ◄───┴───► Tailscale (Fase 3 §05)
                              cliente con CA interna confiada
                              y sesión Authelia (cookie auth_session)
```

### 1.1. Flujos de tráfico

1. **Render inicial de la UI** (operador abre `https://home.lan/` en el navegador):
   - Navegador → DNS Pi-hole → IP del host → Caddy:443 (TLS con CA interna).
   - Caddy → `forward_auth` a Authelia. Si no hay cookie válida, 302 → `auth.lan` (login + `one_factor`). Tras login, vuelve con `Remote-User` inyectado.
   - Caddy → `reverse_proxy http://homepage:3000` por la red `homelab`.
   - Homepage SSR-renderiza la página: lee `services.yaml`, `widgets.yaml`, `settings.yaml`, `bookmarks.yaml`, y consulta `dockerproxy:2375/containers/json` para marcar online/offline cada tarjeta.
   - Devuelve HTML al navegador, que dispara la hidratación + las llamadas AJAX a `/api/widgets/...` para los widgets en vivo.

2. **Refresh periódico de un widget** (cada 30 s, según refresh por widget):
   - Navegador → `https://home.lan/api/widgets/pihole?...` → Caddy → Authelia (cookie OK) → Homepage:3000.
   - Homepage llama a `http://pihole/admin/api.php?summary&auth=${HOMEPAGE_VAR_PIHOLE_KEY}` por la red `homelab`.
   - Devuelve JSON al frontend, que actualiza el contador "queries today" en la tarjeta.

3. **Auto-discovery de un servicio nuevo** (operador despliega un compose con labels `homepage.*`):
   - Homepage observa el evento `container start` vía `dockerproxy:2375/events?filters=...`.
   - En el siguiente render, lee las labels `homepage.group`, `homepage.name`, `homepage.icon`, `homepage.href`, `homepage.description` y pinta una tarjeta nueva en el grupo correspondiente sin reiniciar.

4. **Búsqueda en el cuadro de la home**:
   - El operador escribe "homelab raspberry pi 5" → enter.
   - El frontend genera una URL hacia el motor configurado (`https://duckduckgo.com/?q=...`) y abre una pestaña nueva.
   - **El contenedor Homepage no participa**; toda la salida es del navegador del cliente.

### 1.2. Por qué este recorrido y no el del socket directo

La tentación de Homepage 0.x es montar `/var/run/docker.sock` directo en `/var/run/docker.sock:ro` y declarar `docker.local.socket: /var/run/docker.sock` en `docker.yaml`. Funciona, pero:

- Cualquier vulnerabilidad en el SSR o en una dependencia npm de Homepage es una **escalada inmediata a control total del demonio Docker** (RCE en cualquier contenedor, lectura de cualquier volumen — incluido `/mnt/hd2t/services/vaultwarden/data/`).
- El bind read-only en el socket UNIX **no protege**: la API Docker `POST /containers/<id>/exec` está disponible con un socket "read-only" desde el punto de vista del kernel (la flag `:ro` aplica al inodo, no al protocolo).
- El proxy haproxy de tecnativa filtra a nivel de **path HTTP**: `POST /containers/.../exec` se rechaza con 403 antes de llegar al demonio. Es una mitigación real, no cosmética.

A cambio, el coste es una imagen más, un puerto interno (`2375` en `dashboard_internal`) y un GID `${DOCKER_GID}` que viaja como variable. Trade que el homelab adopta. La variante "socket directo" se documenta en §12.6 para quien quiera la simplicidad a cambio de la superficie.

---

## 2. Plan de variables y archivos

### 2.1. Variables del stack

`~/homelab/stacks/dashboard/.env.example` (versionable):

```env
# ~/homelab/stacks/dashboard/.env.example
# Plantilla. Las claves reales van en /mnt/hd2t/services/homepage/.env (no
# versionada). Copiar este fichero, rellenar las {{__GENERATE_AND_REPLACE__}}
# y los placeholders ${...} con los valores del homelab.

# === Imágenes (pin SemVer) ===
HOMEPAGE_IMAGE=ghcr.io/gethomepage/homepage:v0.10.9
DOCKERPROXY_IMAGE=ghcr.io/tecnativa/docker-socket-proxy:0.3.0

# === Identidad y zona horaria ===
TZ=Europe/Madrid
PUID=1000
PGID=1000

# === GID del grupo docker en el host (necesario para dockerproxy) ===
# Comprobar: getent group docker | awk -F: '{print $3}'
DOCKER_GID=998

# === Hostnames y dominios (alinear con ../03-red/04-caddy.md y 02-pihole.md) ===
LAN_DOMAIN=lan
# Cuando Tailscale esté desplegado, sustituir el placeholder por el tailnet real
# (ver ../03-red/05-tailscale.md). Mientras tanto, dejar la línea en su
# valor literal: HOMEPAGE_ALLOWED_HOSTS la tolera como "host inalcanzable" sin
# tirar el SSR.
TS_DOMAIN=tail-XXXXX.ts.net

# === Whitelist de hosts del SSR de Homepage (separados por coma, sin espacios) ===
HOMEPAGE_ALLOWED_HOSTS=home.lan,home.tail-XXXXX.ts.net

# === Paths en hd2t (bind mounts) ===
DATA_PATH=/mnt/hd2t/services/homepage/config
ICONS_PATH=/mnt/hd2t/services/homepage/icons

# === Logs y nivel de detalle ===
LOG_LEVEL=info
LOG_TARGETS=stdout

# === Límites de recursos ===
HOMEPAGE_MEMORY_LIMIT=256m
HOMEPAGE_CPU_LIMIT=1.5
DOCKERPROXY_MEMORY_LIMIT=64m
DOCKERPROXY_CPU_LIMIT=0.5

# === API keys / tokens de los widgets ===
# Obtener cada uno en §7.4 desde la UI/API del servicio correspondiente.
# Versionar SOLO el .env.example (este fichero) con __GENERATE_AND_REPLACE__.
# El .env real (con las claves) NO se versiona.

# Pi-hole (Settings → API → Show API token, ../03-red/02-pihole.md §7.6)
HOMEPAGE_VAR_PIHOLE_API_KEY=__GENERATE_AND_REPLACE__

# Uptime Kuma (Settings → API Keys → "homepage-readonly", ../05-monitorizacion/05-uptime-kuma.md §6.X)
HOMEPAGE_VAR_UPTIMEKUMA_TOKEN=__GENERATE_AND_REPLACE__

# Grafana (Service Account "homepage-readonly", ../05-monitorizacion/02-grafana.md §X)
HOMEPAGE_VAR_GRAFANA_TOKEN=__GENERATE_AND_REPLACE__

# Portainer (User → Access Tokens → "homepage-readonly", ../02-docker/03-portainer.md §X)
HOMEPAGE_VAR_PORTAINER_TOKEN=__GENERATE_AND_REPLACE__

# Nextcloud (App password, Settings → Security → "homepage")
HOMEPAGE_VAR_NEXTCLOUD_USER=admin
HOMEPAGE_VAR_NEXTCLOUD_PASSWORD=__GENERATE_AND_REPLACE__

# Paperless-ngx (Settings → My Profile → API Auth Token)
HOMEPAGE_VAR_PAPERLESS_TOKEN=__GENERATE_AND_REPLACE__

# Mealie (User → API Tokens → "homepage")
HOMEPAGE_VAR_MEALIE_TOKEN=__GENERATE_AND_REPLACE__

# Home Assistant (Profile → Long-Lived Access Tokens → "homepage")
HOMEPAGE_VAR_HASS_TOKEN=__GENERATE_AND_REPLACE__

# Sonarr / Radarr / Prowlarr (Settings → General → API Key)
HOMEPAGE_VAR_SONARR_KEY=__GENERATE_AND_REPLACE__
HOMEPAGE_VAR_RADARR_KEY=__GENERATE_AND_REPLACE__
HOMEPAGE_VAR_PROWLARR_KEY=__GENERATE_AND_REPLACE__

# Transmission (basic auth desde el .env del propio Transmission)
HOMEPAGE_VAR_TRANSMISSION_USER=admin
HOMEPAGE_VAR_TRANSMISSION_PASSWORD=__GENERATE_AND_REPLACE__

# Jellyfin (Dashboard → API Keys → "homepage")
HOMEPAGE_VAR_JELLYFIN_KEY=__GENERATE_AND_REPLACE__

# Audiobookshelf (Settings → Users → admin → API Token)
HOMEPAGE_VAR_AUDIOBOOKSHELF_TOKEN=__GENERATE_AND_REPLACE__

# Watchtower (HTTP API token, ../02-docker/04-watchtower.md §X)
HOMEPAGE_VAR_WATCHTOWER_TOKEN=__GENERATE_AND_REPLACE__
```

> **Sobre los placeholders `__GENERATE_AND_REPLACE__`**: si un widget concreto no se va a usar (porque el servicio no está desplegado, o porque su API es muy cara y se prefiere sólo un ping de salud), **dejar la línea con `__GENERATE_AND_REPLACE__`** y **no incluir el widget en `widgets.yaml`/`services.yaml`**. La env var se interpola pero nunca se referencia. Eso evita errores ruidosos en los logs ("invalid API key") y mantiene el `.env.example` como mapa completo de lo que el dashboard puede mostrar.

### 2.2. Generar el `.env` real desde la plantilla

```bash
# 1. Asegurar el dir de configs en el repo:
mkdir -p ~/homelab/stacks/dashboard
cd ~/homelab/stacks/dashboard

# 2. Copiar la plantilla a su sitio definitivo en hd2t:
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/homepage
sudo install -o homelab -g homelab -m 640 \
  ~/homelab/stacks/dashboard/.env.example \
  /mnt/hd2t/services/homepage/.env

# 3. Editar y rellenar (entre otros, DOCKER_GID con el valor real):
sudo $EDITOR /mnt/hd2t/services/homepage/.env

# 4. (Más tarde, en §7.4) sustituir cada __GENERATE_AND_REPLACE__ por la API
# key obtenida del servicio correspondiente.

# 5. Verificar que el .env NO se versiona (debe estar en .gitignore global):
grep -E '^\*\.env$|^.env$' ~/homelab/.gitignore
# Esperado: una de las dos líneas. Si no existe, añadirla.
```

### 2.3. Inventario de archivos que crea/usa este doc

| Archivo | Versionable en git | Contiene secretos | Quién lo escribe |
|---|---|---|---|
| `~/homelab/stacks/dashboard/docker-compose.yml` | **SÍ** | No (referencia variables) | Operador (este doc, §4) |
| `~/homelab/stacks/dashboard/.env.example` | **SÍ** | No (placeholders) | Operador (§2.1) |
| `~/homelab/stacks/dashboard/config/services.yaml` | **SÍ** | No (referencia `{{HOMEPAGE_VAR_*}}`) | Operador (§7.2) |
| `~/homelab/stacks/dashboard/config/widgets.yaml` | **SÍ** | No (idem) | Operador (§7.3) |
| `~/homelab/stacks/dashboard/config/settings.yaml` | **SÍ** | No | Operador (§7.1) |
| `~/homelab/stacks/dashboard/config/bookmarks.yaml` | **SÍ** | No | Operador (§7.5) |
| `~/homelab/stacks/dashboard/config/docker.yaml` | **SÍ** | No | Operador (§7.4) |
| `/mnt/hd2t/services/homepage/.env` | **NO** | **Sí** (todas las API keys) | Operador (§2.2 + §7.4) |
| `/mnt/hd2t/services/homepage/config/{services,widgets,settings,bookmarks,docker}.yaml` | NO (es copia rendered) | No | rsync/sync desde `~/homelab/stacks/dashboard/config/` (§7.6) |
| `/mnt/hd2t/services/homepage/config/logs/homepage.log` | NO | No | Homepage al ejecutarse |
| `/mnt/hd2t/services/homepage/icons/*` (opcional) | NO (binarios grandes) | No | Operador (§12.5 si activa iconos custom) |

> **Sobre versionar los YAML de config**: a diferencia de los `data/` de otros servicios (Linkding, Vaultwarden, etc.), los YAML de Homepage **son la fuente de verdad** y **se versionan**. La copia en `/mnt/hd2t/services/homepage/config/` es un **rendered**: §7.6 establece un proceso `rsync` desde el repo a hd2t para que el contenedor los lea. Esto permite "PR-ear" cambios de dashboard como cambios de código.

---

## 3. Preparar el árbol de datos

### 3.1. Estructura final esperada

```
/mnt/hd2t/services/homepage/                          ← homelab:homelab 0750
├── .env                                              ← homelab:homelab 0640 (secretos)
├── config/                                           ← homelab:homelab 0750
│   ├── services.yaml                                 ← rendered desde el repo
│   ├── widgets.yaml                                  ← rendered desde el repo
│   ├── settings.yaml                                 ← rendered desde el repo
│   ├── bookmarks.yaml                                ← rendered desde el repo
│   ├── docker.yaml                                   ← rendered desde el repo
│   ├── kubernetes.yaml                               ← rendered desde el repo (vacío/disabled)
│   └── logs/
│       └── homepage.log                              ← lo escribe la app
└── icons/                                            ← (opcional, §12.5) homelab:homelab 0750
    └── (PNGs/SVGs custom)
```

```
~/homelab/stacks/dashboard/                           ← repo git del operador
├── docker-compose.yml                                ← versionable
├── .env.example                                      ← versionable
└── config/                                           ← versionable (los YAML "fuente")
    ├── services.yaml
    ├── widgets.yaml
    ├── settings.yaml
    ├── bookmarks.yaml
    ├── docker.yaml
    └── kubernetes.yaml
```

### 3.2. Crear los directorios

```bash
# 1. Repo: el dir del stack y la subcarpeta de configs versionables.
mkdir -p ~/homelab/stacks/dashboard/config

# 2. hd2t: la raíz ya existe (bootstrap §6.6). Crear los subdirectorios.
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/homepage/config
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/homepage/config/logs
# (icons/ es opcional, ver §12.5; no se crea aquí.)

# 3. Verificar:
ls -la /mnt/hd2t/services/homepage/
# Esperado:
#   drwxr-x--- 3 homelab homelab    config/
#   drwxr-x--- 2 homelab homelab    (raíz vacía además del config y el .env)

ls -la ~/homelab/stacks/dashboard/
# Esperado:
#   drwxr-xr-x  config/
#   (docker-compose.yml y .env.example se crean en §4 y §2.2)
```

### 3.3. (Limpieza opcional) Esquema viejo "un dir por servicio"

El bootstrap original ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6.6 línea 246, 336) creó `/mnt/hd2t/services/homepage/` con propietario `homelab:homelab` y modo `750`. **No se elimina ni se mueve**: este doc lo reutiliza tal cual, sólo añade los subdirs `config/` y `config/logs/`.

A diferencia de Uptime Kuma o Dozzle (que sí movieron/eliminaron sus dirs antiguos al cambiar al esquema "un dir por stack"), aquí la estructura `/mnt/hd2t/services/homepage/` sigue siendo "un dir por servicio" porque Homepage **es** el único servicio del stack `dashboard`. El compose en `~/homelab/stacks/dashboard/` (raíz del stack) y los datos en `/mnt/hd2t/services/homepage/` (raíz del servicio) coexisten sin pisarse.

---

## 4. `docker-compose.yml`

`~/homelab/stacks/dashboard/docker-compose.yml`:

```yaml
# ~/homelab/stacks/dashboard/docker-compose.yml
# Stack: dashboard (../02-docker/02-estructura-compose.md §1.1, fila
# 'dashboard' línea 80). Datos en /mnt/hd2t/services/homepage/.
# Dos servicios:
#   - homepage     UI Next.js, expone :3000 sólo dentro de homelab + dashboard_internal
#   - dockerproxy  proxy haproxy de la API Docker (/containers, /info, /events, /_ping)

name: dashboard

services:
  dockerproxy:
    image: ${DOCKERPROXY_IMAGE}
    container_name: dockerproxy
    hostname: dockerproxy
    restart: unless-stopped

    environment:
      # Sólo se permiten lecturas; el resto (POST /containers/.../exec,
      # POST /containers/.../start, etc.) devuelven 403.
      CONTAINERS: 1
      INFO: 1
      EVENTS: 1
      PING: 1
      # Todo lo demás explícitamente prohibido (defensa en profundidad: la
      # imagen 0.3.x ya hace =0 por defecto, pero documentarlo es contrato).
      AUTH: 0
      BUILD: 0
      COMMIT: 0
      CONFIGS: 0
      DISTRIBUTION: 0
      EXEC: 0
      GRPC: 0
      IMAGES: 0
      NETWORKS: 0
      NODES: 0
      PLUGINS: 0
      POST: 0
      SECRETS: 0
      SERVICES: 0
      SESSION: 0
      SWARM: 0
      SYSTEM: 0
      TASKS: 0
      VOLUMES: 0
      LOG_LEVEL: info

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro

    # GID del grupo docker en el host: necesario para que el binario haproxy
    # pueda leer el socket UNIX. Variable definida en el .env (verificar con
    # `getent group docker`).
    group_add:
      - "${DOCKER_GID}"

    networks:
      - dashboard_internal

    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
    security_opt:
      - no-new-privileges:true

    read_only: true
    tmpfs:
      - /var/lib/haproxy:rw,noexec,nosuid,size=16m

    healthcheck:
      test: ["CMD", "wget", "-qO-", "--timeout=3", "http://127.0.0.1:2375/_ping"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

    deploy:
      resources:
        limits:
          memory: ${DOCKERPROXY_MEMORY_LIMIT}
          cpus: '${DOCKERPROXY_CPU_LIMIT}'

    labels:
      # Excluido de Watchtower: el proxy de la API Docker se actualiza a mano.
      com.centurylinklabs.watchtower.enable: "false"
      # Sin labels homepage.*: no tiene UI, no debe aparecer como tarjeta.

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  homepage:
    image: ${HOMEPAGE_IMAGE}
    container_name: homepage
    hostname: homepage
    restart: unless-stopped

    depends_on:
      dockerproxy:
        condition: service_healthy

    env_file:
      - /mnt/hd2t/services/homepage/.env
    environment:
      TZ: ${TZ}
      PUID: ${PUID}
      PGID: ${PGID}
      LOG_LEVEL: ${LOG_LEVEL}
      LOG_TARGETS: ${LOG_TARGETS}
      # Whitelist de Host: que el SSR de Next.js acepta. Cualquier otra cosa
      # devuelve 400. Mismas defensas que Vaultwarden, Authelia, etc.
      HOMEPAGE_ALLOWED_HOSTS: ${HOMEPAGE_ALLOWED_HOSTS}
      # Las HOMEPAGE_VAR_* se cargan desde env_file y se interpolan en los
      # YAML al renderizar. NO se redeclaran aquí (ver §0 punto sobre
      # `environment:` re-declaración explícita: para Homepage no aporta y
      # multiplicaría líneas por cada widget — quedan en env_file).

    volumes:
      - ${DATA_PATH}:/app/config:rw
      # icons/ es opt-in (§12.5). Si la variable ICONS_PATH apunta a un dir
      # vacío, Homepage seguirá usando el set público sin error.
      - ${ICONS_PATH}:/app/public/icons:ro

    networks:
      - dashboard_internal
      - homelab

    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true

    healthcheck:
      test: ["CMD-SHELL", "wget -qO- --timeout=3 http://127.0.0.1:3000/api/healthcheck >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s

    deploy:
      resources:
        limits:
          memory: ${HOMEPAGE_MEMORY_LIMIT}
          cpus: '${HOMEPAGE_CPU_LIMIT}'

    labels:
      com.centurylinklabs.watchtower.enable: "true"
      homepage.group: "Dashboards"
      homepage.name: "Homepage"
      homepage.icon: "homepage.png"
      homepage.href: "https://home.${LAN_DOMAIN}"
      homepage.description: "Página de inicio del homelab"

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  dashboard_internal:
    name: dashboard_internal
    driver: bridge
    # No external: queda local al stack. dockerproxy:2375 nunca sale de aquí.

  homelab:
    external: true
```

### 4.1. Por qué cada bloque

| Línea | Por qué |
|---|---|
| `name: dashboard` | Hace el `compose project name` explícito en lugar de inferirlo del directorio. Aparece en `docker compose ls` con ese nombre. Coherente con el resto del homelab. |
| `dockerproxy.image: ghcr.io/tecnativa/docker-socket-proxy:0.3.0` | Imagen tag-pinned, ver §0. El `ghcr.io` (no Docker Hub) es la primary registry del proyecto desde 0.2; sirve la misma imagen sin diferencias. |
| `dockerproxy.environment: CONTAINERS=1, INFO=1, EVENTS=1, PING=1` | Mínimo viable para Homepage 0.10+: `containers` y `info` para descubrir contenedores y pintar tarjetas; `events` para el auto-refresh sin polling; `_ping` para el healthcheck. |
| `dockerproxy.environment: AUTH=0, ..., VOLUMES=0` | Bloqueo explícito de las endpoints peligrosas. Aunque la default 0.3.0 ya las marca `=0`, declararlas en el compose convierte el contrato en revisable por `git diff` y resistente a un upgrade que cambie defaults. |
| `dockerproxy.volumes: /var/run/docker.sock:ro` | El socket UNIX, montado read-only. En Linux el `:ro` aplica a operaciones del filesystem (open con `O_WRONLY`); el demonio Docker, una vez conectado, ofrece lecturas y escrituras vía protocolo. La mitigación real la hace haproxy filtrando paths HTTP. |
| `dockerproxy.group_add: ${DOCKER_GID}` | El binario haproxy corre como `nobody` y necesita pertenecer al grupo `docker` del host (GID típico 998 en RPi OS Bookworm) para tener `r--` sobre el socket. Variable definida en `.env`. |
| `dockerproxy.networks: [dashboard_internal]` | Sólo en la red interna del stack. **No** se conecta a `homelab`: nadie excepto Homepage debe llegar al puerto 2375 del proxy. |
| `dockerproxy.cap_add: [CHOWN, SETUID, SETGID]` | Necesarios para el `entrypoint` que arranca como root, hace `chown` del directorio temporal de haproxy y baja a `nobody`. Sin ellos el contenedor falla en el arranque (`Permission denied` en `setuid`). |
| `dockerproxy.read_only: true` + `tmpfs: /var/lib/haproxy` | El binario sólo escribe a `/var/lib/haproxy` (cache de health, sockets temporales). Read-only + tmpfs es máxima restricción aceptable. |
| `dockerproxy.healthcheck: wget /_ping` | El endpoint `_ping` está siempre permitido (flag `PING=1`). Idempotente, devuelve `OK`. Si el socket UNIX cae o haproxy se cae, falla. |
| `dockerproxy.labels: watchtower.enable: false` | Justificado en §0. Sin `homepage.*` para no aparecer en el dashboard como tarjeta. |
| `homepage.depends_on: dockerproxy condition: service_healthy` | Garantiza que Homepage no arranca su SSR antes de que el proxy responda `/_ping`. Si arranca antes, los renders iniciales devolverían `connection refused` en `docker.local.host: dockerproxy:2375` y el dashboard saldría con todas las tarjetas en "down" hasta el primer refresh. |
| `homepage.image: ghcr.io/gethomepage/homepage:v0.10.9` | Tag pinneado, ver §0. |
| `homepage.env_file: /mnt/hd2t/services/homepage/.env` | Path absoluto, fuera del repo. Mismo patrón que el resto del homelab ([`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §5.1). |
| `homepage.environment: HOMEPAGE_ALLOWED_HOSTS` | Defensa contra Host-header injection del SSR. Sin esto, el primer arranque de 0.9+ rechaza cualquier petición con un 400 "Untrusted Host". |
| `homepage.volumes: ${DATA_PATH}:/app/config:rw` | Único path rw del contenedor: contiene los YAML, los logs y los thumbnails generados. |
| `homepage.volumes: ${ICONS_PATH}:/app/public/icons:ro` | Path opt-in para iconos custom. Si está vacío, Homepage cae al CDN público sin error. **Read-only** porque la app no necesita escribir ahí. |
| `homepage.networks: [dashboard_internal, homelab]` | `dashboard_internal` para hablar a `dockerproxy:2375`; `homelab` para hablar a Pi-hole, Uptime Kuma, Nextcloud, etc. y para que Caddy lo proxy-e. |
| `homepage.cap_drop: ALL` | El proceso Node de Homepage no necesita capabilities. |
| `homepage.security_opt: no-new-privileges:true` | Refuerza la postura. |
| `homepage.healthcheck: wget /api/healthcheck` | Endpoint canónico 0.10+. Devuelve 200 con `{"status":"ok"}` cuando el SSR está listo y los YAML parsean. Si `services.yaml` rompe el parser, devuelve 500 → `unhealthy`. |
| `homepage.start_period: 60s` | Next.js + Node tardan 15–30 s en arrancar en una Pi 5; `start_period` largo evita falsos `unhealthy` durante el bootstrap. |
| `homepage.deploy.resources.limits` | 256 MB RAM, 1.5 CPUs. Idle ~80 MB, picos al render concurrente ~150 MB. |
| `homepage.labels: watchtower.enable: true` + `homepage.*` | Auto-update para los patches de 0.10.x; auto-discover de la propia tarjeta "Homepage" en el grupo "Dashboards". |
| `networks.dashboard_internal` (no `external: true`) | Convención §4.3 de estructura-compose: **redes locales** al stack (no compartidas con otros stacks) se declaran inline. Externa sólo `homelab`. |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/dashboard
docker compose --env-file /mnt/hd2t/services/homepage/.env config
```

La salida debe mostrar:

- `image: ghcr.io/gethomepage/homepage:v0.10.9` y `image: ghcr.io/tecnativa/docker-socket-proxy:0.3.0` (sin `${...}` literales),
- `group_add: ['998']` (o el GID que corresponda),
- `volumes: ['/var/run/docker.sock:/var/run/docker.sock:ro']` para `dockerproxy`,
- `volumes: ['/mnt/hd2t/services/homepage/config:/app/config:rw', '/mnt/hd2t/services/homepage/icons:/app/public/icons:ro']` para `homepage`,
- `networks` con `dashboard_internal` y `homelab` (este último con `external: true`),
- ningún `ports:` publicado en ningún servicio,
- `HOMEPAGE_ALLOWED_HOSTS: home.lan,home.tail-XXXXX.ts.net` (sin `${...}` literales).

Si `HOMEPAGE_ALLOWED_HOSTS` aparece como `${HOMEPAGE_ALLOWED_HOSTS}` literal, falta `--env-file`. Si `DOCKER_GID` aparece como `${DOCKER_GID}`, no se editó el `.env` con el valor real.

---

## 5. Despliegue

### 5.1. Bootstrap de los YAML mínimos

Antes de levantar el contenedor, hay que dejar **al menos** un `settings.yaml` mínimo en el dir de config para que Homepage no falle al parsear. El resto de YAML (services, widgets, bookmarks, docker, kubernetes) se construyen iterativamente en §7.

```bash
# 1. Bootstrap mínimo en el repo:
cat > ~/homelab/stacks/dashboard/config/settings.yaml <<'EOF'
---
title: Homelab Pi 5
language: es
theme: dark
color: slate
target: _blank
headerStyle: clean
layout:
  Infraestructura:
    style: row
    columns: 4
  Red:
    style: row
    columns: 4
  Seguridad:
    style: row
    columns: 4
  Monitorización:
    style: row
    columns: 3
  Almacenamiento:
    style: row
    columns: 4
  Domótica:
    style: row
    columns: 4
  Multimedia:
    style: row
    columns: 5
  Descargas:
    style: row
    columns: 4
  Productividad:
    style: row
    columns: 4
  Dashboards:
    style: row
    columns: 4
  Backups:
    style: row
    columns: 3
EOF

# 2. Crear placeholders vacíos para que la app no avise:
for f in services.yaml widgets.yaml bookmarks.yaml docker.yaml kubernetes.yaml; do
  echo "---" > ~/homelab/stacks/dashboard/config/${f}
done

# 3. (Excepción) docker.yaml mínimo: dejarlo vacío en este paso. Se completa en §7.4.
# (Excepción) kubernetes.yaml: queda vacío para siempre (no se usa k8s en el homelab).

# 4. Sync hacia el bind mount:
sudo rsync -av --delete \
  --chown=homelab:homelab \
  ~/homelab/stacks/dashboard/config/ \
  /mnt/hd2t/services/homepage/config/
sudo chmod -R u=rwX,g=rX,o= /mnt/hd2t/services/homepage/config/
```

### 5.2. Levantar el stack

```bash
cd ~/homelab/stacks/dashboard
docker compose --env-file /mnt/hd2t/services/homepage/.env up -d
```

Esperar ~60 s y verificar:

```bash
docker compose --env-file /mnt/hd2t/services/homepage/.env ps
# Esperado:
#   NAME          IMAGE                                                STATUS
#   dockerproxy   ghcr.io/tecnativa/docker-socket-proxy:0.3.0          Up X seconds (healthy)
#   homepage      ghcr.io/gethomepage/homepage:v0.10.9                 Up X seconds (health: starting → healthy)
```

### 5.3. Estado de los contenedores

```bash
# Tras ~60 s, ambos healthy:
docker inspect dockerproxy homepage \
  --format '{{.Name}} {{.State.Health.Status}}'
# Esperado:
#   /dockerproxy healthy
#   /homepage    healthy

# Logs del primer arranque de homepage:
docker logs homepage 2>&1 | head -40
```

Líneas de interés en los logs (varían entre versiones):

```
[2025-XX-XX] [info] starting homepage v0.10.9
[2025-XX-XX] [info] loading configuration from /app/config
[2025-XX-XX] [info] services: 0 groups loaded
[2025-XX-XX] [info] widgets: no widgets configured
[2025-XX-XX] [info] docker: no providers configured
[2025-XX-XX] [info] listening on 0.0.0.0:3000
```

> **Si aparece `Error: HOMEPAGE_ALLOWED_HOSTS is required`** y el contenedor entra en CrashLoop: el `.env` no se cargó. Volver a §2.2 paso 3 y verificar que el path del `env_file:` en el compose es correcto (`/mnt/hd2t/services/homepage/.env`, **no** `~/homelab/stacks/dashboard/.env`).

> **Si aparece `Error: cannot read /app/config/settings.yaml: ENOENT`**: el rsync de §5.1 paso 4 no llegó a destino. Re-ejecutar y verificar `ls /mnt/hd2t/services/homepage/config/` antes de `docker compose up`.

### 5.4. Verificar la conexión homepage ↔ dockerproxy

```bash
# Desde dentro del contenedor de homepage, hacer una llamada a la API
# Docker filtrada por el proxy:
docker exec homepage wget -qO- --timeout=5 http://dockerproxy:2375/_ping
# Esperado: OK

docker exec homepage wget -qO- --timeout=5 http://dockerproxy:2375/info \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Containers'])"
# Esperado: un entero > 0 (número de contenedores actualmente corriendo).

# Y verificar que las endpoints peligrosas devuelven 403:
docker exec homepage wget -qSO- --timeout=5 http://dockerproxy:2375/images/json 2>&1 | head -3
# Esperado: HTTP/1.1 403 Forbidden  (porque IMAGES=0 en el compose).
```

### 5.5. Smoke check antes de publicar por Caddy

```bash
# Health endpoint accesible desde la red Docker:
docker exec caddy wget -qO- --timeout=3 http://homepage:3000/api/healthcheck
# Esperado: {"status":"ok",...}

# Página principal HTML accesible (sin Authelia delante todavía):
docker exec caddy wget -qO- --timeout=3 http://homepage:3000/ | grep -ic '<title'
# Esperado: ≥ 1
```

---

## 6. Integración con Caddy

### 6.1. Activar el bloque `home.{$LAN_DOMAIN}` en el `Caddyfile`

El bloque ya está en el `Caddyfile` como bloque comentado ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) líneas 444-449). Editar `~/homelab/stacks/proxy/Caddyfile` y descomentarlo + añadir `import authelia_proxy`:

```caddy
# Homepage (../12-dashboards/01-homepage.md)
home.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    import authelia_proxy one_factor
    reverse_proxy http://homepage:3000 {
        # Homepage usa SSE/long-poll en /api/widgets/* (refresh sin recargar
        # la página). Caddy v2 lo proxy-a sin configuración especial; el
        # flush_interval -1 lo hace explícito y desactiva el buffer.
        flush_interval -1
    }
}
```

| Línea | Por qué |
|---|---|
| `import lan_internal_tls` | TLS con CA interna ([`../03-red/04-caddy.md`](../03-red/04-caddy.md) §4.2). |
| `import security_headers` | HSTS + X-Frame-Options DENY + X-Content-Type-Options nosniff + Referrer-Policy strict-origin-when-cross-origin. Homepage sirve sus propias páginas en HTML; ningún iframe externo legítimo. |
| `import authelia_proxy one_factor` | Sigue el patrón del snippet del Caddyfile que admite la política como argumento. `one_factor` cubre la postura por defecto; `two_factor` es la variante §12.4. |
| `reverse_proxy http://homepage:3000` | Caddy llega por la red `homelab` al contenedor `homepage`. HTTP plano dentro de Docker (Caddy ya hace TLS terminator hacia el navegador). |
| `flush_interval -1` | Para los widgets en vivo, Homepage usa long-poll/SSE en `/api/widgets/*`. Sin `flush_interval -1`, Caddy buferiza la respuesta y el contador de Pi-hole no actualiza hasta que el conector cierra. Mismo patrón que Dozzle ([`./05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md) §6.5). |

### 6.2. Recargar Caddy

```bash
cd ~/homelab/stacks/proxy
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
# Esperado: "Valid configuration".

docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
# Esperado: sin output (éxito).
```

Verificación en logs de Caddy:

```bash
docker logs --tail 50 caddy 2>&1 | grep -E 'home\.lan|reload'
# Esperado: la nueva ruta aparece y un log "reloaded successfully" o
# "certificate obtained successfully" para home.lan.
```

### 6.3. Registro DNS local en Pi-hole

En la UI de Pi-hole (`https://pihole.${LAN_DOMAIN}/admin`):

- **Local DNS Records** → **Add a new domain/IP combination**.
- Domain: `home.lan`
- IP: la IP del host donde escucha Caddy (`192.168.1.10` por convención del homelab; ver [`../03-red/02-pihole.md`](../03-red/02-pihole.md)).
- **Add**.

Validación:

```bash
dig +short @192.168.1.241 home.lan
# Esperado: 192.168.1.10  (la IP de Caddy/Pi).
```

### 6.4. Probar el acceso desde el navegador

```bash
# Desde un cliente con la CA de Caddy ya instalada (§6.5 de Caddy):
curl -v --resolve home.lan:443:192.168.1.10 https://home.lan/ 2>&1 | head -20
# Esperado: HTTP/2 302  → Location: https://auth.lan/?...
# Si ya hay cookie de Authelia válida en el cliente, HTTP/2 200 con HTML.

# Verificar que /api/healthcheck también pasa por Authelia:
curl -v --resolve home.lan:443:192.168.1.10 https://home.lan/api/healthcheck 2>&1 | head -20
# Esperado: HTTP/2 302 → auth.lan (a menos que se quiera bypass para
# uptime checks externos; ver §12.7 si Uptime Kuma necesita probar
# /api/healthcheck sin sesión).
```

Desde el navegador: `https://home.lan` → debería redirigir a `https://auth.lan/` y mostrar el formulario de login Authelia. Tras login con `one_factor` (usuario+password), redirige de vuelta a `https://home.lan/` y aparece el dashboard de Homepage con el header "Homelab Pi 5" (definido en `settings.yaml`) y todos los grupos vacíos (porque `services.yaml` aún no tiene servicios — se completa en §7).

Si aparece un warning de cert, el `root.crt` de Caddy no está instalado en el navegador — volver a [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §6.5.

### 6.5. Acceso vía Tailscale (preparado, no activo)

Mismo patrón que el resto del homelab: cuando Tailscale esté desplegado ([`../03-red/05-tailscale.md`](../03-red/05-tailscale.md)) se añade un segundo bloque en el `Caddyfile`:

```caddy
# Homepage vía Tailscale (descomentar tras 03-red/05-tailscale.md).
# home.{$TS_DOMAIN} {
#     import tailscale_tls
#     import security_headers
#     import authelia_proxy one_factor
#     reverse_proxy http://homepage:3000 {
#         flush_interval -1
#     }
# }
```

Y se actualiza `HOMEPAGE_ALLOWED_HOSTS` en el `.env` con el host Tailscale real (`home.tail-XXXXX.ts.net`).

---

## 7. Configuración post-despliegue

Aquí se puebla el dashboard. Cinco YAML, uno por concepto. La regla operativa: **editar siempre en `~/homelab/stacks/dashboard/config/`** (versionable), sincronizar con `rsync` a `/mnt/hd2t/services/homepage/config/`, y ver el cambio en vivo (Homepage 0.10+ recarga los YAML al detectar mtime nuevo, sin reiniciar).

### 7.1. `settings.yaml` definitivo

Reemplazar el bootstrap mínimo de §5.1 con la versión definitiva. `~/homelab/stacks/dashboard/config/settings.yaml`:

```yaml
---
title: Homelab Pi 5
description: Servicios autoalojados sobre Raspberry Pi 5 (8 GB)
language: es

theme: dark
color: slate

target: _blank          # los enlaces abren en nueva pestaña
headerStyle: clean      # cabecera minimalista (sin logo gigante)
fullWidth: false        # contenido centrado, no edge-to-edge

# Buscador en la cabecera
quicklaunch:
  searchDescriptions: true
  hideInternetSearch: false
  showSearchSuggestions: true

# Motor de búsqueda externa (sólo lo lanza el navegador del cliente, no el contenedor)
providers:
  searchProvider: duckduckgo

# Iconos: sí al CDN público con cache local (los del propio repo dashboard-icons).
# Si se montan iconos custom (§12.5), Homepage los prefiere sobre el CDN.
hideVersion: false      # mostrar la versión 0.10.9 en el footer (útil para auditoría)

# Layout de los grupos en la página
layout:
  Infraestructura:
    style: row
    columns: 4
    icon: mdi-server-network
  Red:
    style: row
    columns: 4
    icon: mdi-dns
  Seguridad:
    style: row
    columns: 4
    icon: mdi-shield-lock
  Monitorización:
    style: row
    columns: 3
    icon: mdi-chart-line
  Almacenamiento:
    style: row
    columns: 4
    icon: mdi-harddisk
  Backups:
    style: row
    columns: 3
    icon: mdi-content-save-cog
  Domótica:
    style: row
    columns: 4
    icon: mdi-home-automation
  Multimedia:
    style: row
    columns: 5
    icon: mdi-multimedia
  Descargas:
    style: row
    columns: 4
    icon: mdi-download
  Productividad:
    style: row
    columns: 4
    icon: mdi-briefcase
  Dashboards:
    style: row
    columns: 4
    icon: mdi-view-dashboard
```

> **Sobre `theme: dark`**: el modo automático (light/dark según el navegador) es el default si se omite la línea. Aquí se fija `dark` porque es el preferido del operador y porque algunos widgets (Grafana embed) sólo tienen iconos legibles en oscuro.

> **Sobre el orden y los `columns:`**: ajustables a gusto. La regla orientativa: 5 columnas para "Multimedia" (más servicios), 3 para "Monitorización" y "Backups" (pocos pero anchos por widget). En móvil, Homepage colapsa a una sola columna automáticamente (responsive, no configurable).

### 7.2. `services.yaml` — catálogo de servicios

`~/homelab/stacks/dashboard/config/services.yaml`. Orden alineado con [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §1.1.

```yaml
---
- Infraestructura:
    - Portainer:
        icon: portainer.png
        href: https://portainer.lan
        description: Gestión de contenedores Docker
        siteMonitor: http://portainer:9000
        widget:
          type: portainer
          url: http://portainer:9000
          env: 1                          # endpoint id en Portainer (ver §7.4)
          key: "{{HOMEPAGE_VAR_PORTAINER_TOKEN}}"

    - Watchtower:
        icon: watchtower.png
        description: Auto-update de contenedores
        siteMonitor: docker:watchtower    # ping de salud por socket Docker (no hay UI)
        widget:
          type: watchtower
          url: http://watchtower:8080
          key: "{{HOMEPAGE_VAR_WATCHTOWER_TOKEN}}"

- Red:
    - Pi-hole:
        icon: pi-hole.png
        href: https://pihole.lan
        description: DNS con bloqueo de publicidad
        siteMonitor: http://pihole/admin/
        widget:
          type: pihole
          url: http://pihole
          version: 6                      # Pi-hole v6 API (ajustar a 5 si aplica)
          key: "{{HOMEPAGE_VAR_PIHOLE_API_KEY}}"

    - Caddy:
        icon: caddy.png
        href: https://caddy.lan
        description: Reverse proxy + HTTPS interno
        siteMonitor: http://caddy:2019/config/   # admin API local
        # Sin widget oficial: sólo ping de salud.

    - Unbound:
        icon: unbound.png
        description: Resolver DNS recursivo
        siteMonitor: docker:unbound       # ping de salud por socket Docker
        # Sin UI ni widget.

    - Tailscale:
        icon: tailscale.png
        href: https://login.tailscale.com/admin/machines
        description: VPN mesh
        # No siteMonitor: el agente vive fuera del bridge homelab.

- Seguridad:
    - Authelia:
        icon: authelia.png
        href: https://auth.lan
        description: Portal SSO + 2FA
        siteMonitor: http://authelia:9091/api/health
        # Widget Authelia oficial (Homepage 0.10.5+):
        widget:
          type: authelia
          url: http://authelia:9091

    - Fail2ban:
        icon: fail2ban.png
        description: Banear IPs por brute-force
        siteMonitor: docker:fail2ban
        # Sin widget oficial; el contador de jails se vería en Grafana.

- Monitorización:
    - Grafana:
        icon: grafana.png
        href: https://grafana.lan
        description: Dashboards de métricas
        siteMonitor: http://grafana:3000/api/health
        widget:
          type: grafana
          url: http://grafana:3000
          username: admin
          password: "{{HOMEPAGE_VAR_GRAFANA_TOKEN}}"   # Service Account token
          # Alternativa: si se usa API key (deprecada en Grafana 11+), poner
          # `key:` en lugar de username/password.

    - Prometheus:
        icon: prometheus.png
        href: https://prometheus.lan
        description: TSDB de métricas
        siteMonitor: http://prometheus:9090/-/healthy
        widget:
          type: prometheus
          url: http://prometheus:9090

    - Uptime Kuma:
        icon: uptime-kuma.png
        href: https://uptime.lan
        description: Monitor de disponibilidad
        siteMonitor: http://uptime-kuma:3001
        widget:
          type: uptimekuma
          url: http://uptime-kuma:3001
          slug: home                       # status page slug (configurar en §7.X de Uptime Kuma)

    - Dozzle:
        icon: dozzle.png
        href: https://logs.lan
        description: Visor de logs
        siteMonitor: http://dozzle:8080/healthz

    - Node Exporter:
        icon: prometheus.png
        description: Métricas del sistema (host)
        siteMonitor: http://node-exporter:9100/metrics

    - cAdvisor:
        icon: cadvisor.png
        description: Métricas de contenedores
        siteMonitor: http://cadvisor:8080/healthz

- Almacenamiento:
    - Nextcloud:
        icon: nextcloud.png
        href: https://nextcloud.lan
        description: Nube privada
        siteMonitor: http://nextcloud/status.php
        widget:
          type: nextcloud
          url: http://nextcloud
          username: "{{HOMEPAGE_VAR_NEXTCLOUD_USER}}"
          password: "{{HOMEPAGE_VAR_NEXTCLOUD_PASSWORD}}"
          fields: ["freespace", "numfiles", "numusers", "memoryusage"]

    - Samba:
        icon: samba.png
        description: Compartición SMB en LAN
        siteMonitor: docker:samba

    - Syncthing:
        icon: syncthing.png
        href: https://syncthing.lan
        description: Sync P2P de carpetas
        siteMonitor: http://syncthing:8384

    - MinIO:
        icon: minio.png
        href: https://minio.lan
        description: Endpoint S3 compatible
        siteMonitor: http://minio:9001/minio/health/live

- Backups:
    - Borgmatic:
        icon: borgbackup.png
        description: Backups cifrados (Borg)
        siteMonitor: docker:borgmatic
        # Sin widget oficial; el estado del último run se ve en Uptime Kuma.

- Domótica:
    - Home Assistant:
        icon: home-assistant.png
        href: https://hass.lan
        description: Plataforma de domótica
        siteMonitor: http://home-assistant:8123
        widget:
          type: homeassistant
          url: http://home-assistant:8123
          key: "{{HOMEPAGE_VAR_HASS_TOKEN}}"

    - Mosquitto:
        icon: mosquitto.png
        description: Broker MQTT
        siteMonitor: docker:mosquitto      # MQTT no es HTTP; ping de salud por socket Docker

    - Zigbee2MQTT:
        icon: zigbee2mqtt.png
        href: https://z2m.lan
        description: Puente Zigbee ↔ MQTT
        siteMonitor: http://zigbee2mqtt:8080

    - Node-RED:
        icon: node-red.png
        href: https://nodered.lan
        description: Flujos de automatización
        siteMonitor: http://node-red:1880

- Multimedia:
    - Jellyfin:
        icon: jellyfin.png
        href: https://jellyfin.lan
        description: Servidor multimedia
        siteMonitor: http://jellyfin:8096/health
        widget:
          type: jellyfin
          url: http://jellyfin:8096
          key: "{{HOMEPAGE_VAR_JELLYFIN_KEY}}"
          enableNowPlaying: true
          enableUser: true
          enableBlocks: true
          fields: ["movies", "series", "episodes", "songs"]

    - Navidrome:
        icon: navidrome.png
        href: https://navidrome.lan
        description: Servidor de música (Subsonic)
        siteMonitor: http://navidrome:4533/ping

    - Audiobookshelf:
        icon: audiobookshelf.png
        href: https://audiobookshelf.lan
        description: Audiolibros y podcasts
        siteMonitor: http://audiobookshelf:80/healthcheck
        widget:
          type: audiobookshelf
          url: http://audiobookshelf:80
          key: "{{HOMEPAGE_VAR_AUDIOBOOKSHELF_TOKEN}}"

    - Calibre-Web:
        icon: calibre-web.png
        href: https://books.lan
        description: Biblioteca de ebooks
        siteMonitor: http://calibre-web:8083/

    - Stash:
        icon: stash.png
        href: https://stash.lan
        description: Multimedia con metadatos
        siteMonitor: http://stash:9999/healthz

- Descargas:
    - Transmission:
        icon: transmission.png
        href: https://transmission.lan
        description: Cliente BitTorrent
        siteMonitor: http://transmission:9091/transmission/web/
        widget:
          type: transmission
          url: http://transmission:9091
          username: "{{HOMEPAGE_VAR_TRANSMISSION_USER}}"
          password: "{{HOMEPAGE_VAR_TRANSMISSION_PASSWORD}}"
          rpcUrl: /transmission/

    - Prowlarr:
        icon: prowlarr.png
        href: https://prowlarr.lan
        description: Gestor de indexadores
        siteMonitor: http://prowlarr:9696/ping
        widget:
          type: prowlarr
          url: http://prowlarr:9696
          key: "{{HOMEPAGE_VAR_PROWLARR_KEY}}"

    - Sonarr:
        icon: sonarr.png
        href: https://sonarr.lan
        description: Series de TV
        siteMonitor: http://sonarr:8989/ping
        widget:
          type: sonarr
          url: http://sonarr:8989
          key: "{{HOMEPAGE_VAR_SONARR_KEY}}"

    - Radarr:
        icon: radarr.png
        href: https://radarr.lan
        description: Películas
        siteMonitor: http://radarr:7878/ping
        widget:
          type: radarr
          url: http://radarr:7878
          key: "{{HOMEPAGE_VAR_RADARR_KEY}}"

- Productividad:
    - Vaultwarden:
        icon: vaultwarden.png
        href: https://vault.lan
        description: Gestor de contraseñas
        siteMonitor: http://vaultwarden:80/alive
        # Widget oficial Homepage 0.10.7+ (sólo lectura: usuarios, items totales)
        # Requiere admin token. Opt-in: dejar comentado por defecto, activar
        # en §12.8 si se quiere ver el contador.
        # widget:
        #   type: vaultwarden
        #   url: http://vaultwarden:80
        #   key: "{{HOMEPAGE_VAR_VAULTWARDEN_ADMIN_TOKEN}}"

    - Bookstack:
        icon: bookstack.png
        href: https://bookstack.lan
        description: Wiki interna
        siteMonitor: http://bookstack/

    - Linkding:
        icon: linkding.png
        href: https://linkding.lan
        description: Marcadores web
        siteMonitor: http://linkding:9090/health

    - Paperless-ngx:
        icon: paperless-ngx.png
        href: https://paperless.lan
        description: Gestor documental con OCR
        siteMonitor: http://paperless:8000/api/
        widget:
          type: paperlessngx
          url: http://paperless:8000
          key: "{{HOMEPAGE_VAR_PAPERLESS_TOKEN}}"
          fields: ["total", "inbox"]

    - Mealie:
        icon: mealie.png
        href: https://mealie.lan
        description: Recetas
        siteMonitor: http://mealie:9000/api/app/about
        widget:
          type: mealie
          url: http://mealie:9000
          key: "{{HOMEPAGE_VAR_MEALIE_TOKEN}}"
          fields: ["recipes", "users", "categories", "tags"]

    - Stirling PDF:
        icon: stirling-pdf.png
        href: https://pdf.lan
        description: Manipulación de PDFs
        siteMonitor: http://stirling-pdf:8080/

    - FreshRSS:
        icon: freshrss.png
        href: https://rss.lan
        description: Lector RSS
        siteMonitor: http://freshrss/i/?c=feed&a=actualize
        widget:
          type: freshrss
          url: http://freshrss
          username: admin
          password: "{{HOMEPAGE_VAR_FRESHRSS_PASSWORD}}"   # opcional, sólo si se quiere unread count

- Dashboards:
    - Homepage:
        icon: homepage.png
        href: https://home.lan
        description: Esta página
        siteMonitor: http://homepage:3000/api/healthcheck
```

> **Sobre `siteMonitor:`**: marca cada tarjeta con un punto verde/rojo según el último ping. Acepta tres formas: (a) URL HTTP/HTTPS, (b) `docker:<container_name>` (ping de salud por la API Docker, vía dockerproxy), (c) omitirlo (la tarjeta no muestra status). Para servicios sin endpoint HTTP (Mosquitto, Samba, Borgmatic) la opción `docker:` es la única realista.

> **Sobre los servicios sin widget oficial** (Caddy, Unbound, Fail2ban, Samba, Borgmatic, Bookstack, Linkding, Stirling-PDF, Stash, Calibre-Web, Navidrome, Mosquitto, Zigbee2MQTT, Node-RED, MinIO, Syncthing): la tarjeta sólo muestra icono + descripción + ping. La métrica detallada se ve en Grafana o en la propia UI del servicio. Si se quiere un widget custom para alguno (Stash tiene una `getMediaStats` API), se puede hacer con el widget genérico `customapi` — variante §12.9.

> **Sobre `version: 6` de Pi-hole**: Pi-hole v6 (junio 2024+) cambió el formato de la API. Si el homelab corre Pi-hole v5, poner `version: 5`. Verificar con `docker exec pihole pihole -v`.

### 7.3. `widgets.yaml` — widgets de cabecera

`~/homelab/stacks/dashboard/config/widgets.yaml`. Estos son los **widgets globales** que aparecen en la fila superior, no las tarjetas de servicios.

```yaml
---
# Resumen del host (CPU, RAM, disco, uptime). Se alimenta del socket Docker
# vía dockerproxy. La etiqueta debe coincidir con el nombre que el bloque
# `docker:` en docker.yaml (§7.4) le da al provider del host.
- resources:
    backend: resources
    expanded: true
    cpu: true
    memory: true
    cputemp: true       # temperatura del SoC (Homepage 0.10+ vía /sys/class/thermal)
    uptime: true
    units: metric
    refresh: 3000

- resources:
    label: hd2t
    disk: /mnt/hd2t
    refresh: 30000

- resources:
    label: hd5t
    disk: /mnt/hd5t
    refresh: 30000

# Cuadro de búsqueda con sugerencias (DuckDuckGo via JS, no sale del navegador)
- search:
    provider: duckduckgo
    focus: false        # no robar el foco al cargar
    showSearchSuggestions: true
    target: _blank

# Reloj con la zona horaria del sistema
- datetime:
    text_size: xl
    format:
      timeStyle: short
      dateStyle: short
      hourCycle: h23

# Calendario integrado con Sonarr/Radarr (próximos estrenos):
- calendar:
    integrations:
      - type: sonarr
        service_group: Descargas
        service_name: Sonarr
      - type: radarr
        service_group: Descargas
        service_name: Radarr
    firstDayInWeek: monday
    view: monthly
    maxEvents: 10
    showTime: false

# (Opt-in §12.10) Widget de noticias o RSS feed personalizado:
# - rss:
#     feed: https://blog.example.com/rss
#     limit: 5
```

> **Sobre `cputemp: true`**: Homepage 0.10+ lee `/sys/class/thermal/thermal_zone0/temp` directamente del host vía bind o, en este compose, **no lee nada** porque el contenedor no tiene `/sys/class/thermal` montado. Si el operador quiere temperatura real en el widget, añadir al compose:
>
> ```yaml
>     volumes:
>       - /sys/class/thermal:/sys/class/thermal:ro
> ```
>
> Mientras no esté, `cputemp: true` es no-op (no rompe, simplemente no muestra).

> **Sobre `disk: /mnt/hd2t`**: Homepage usa `statvfs` sobre el path **dentro del contenedor**. El bind mount del compose actual sólo expone `/app/config` y `/app/public/icons`, no los discos de datos. Para que los widgets `disk:` funcionen, añadir:
>
> ```yaml
>     volumes:
>       - /mnt/hd2t:/mnt/hd2t:ro
>       - /mnt/hd5t:/mnt/hd5t:ro
> ```
>
> Coste: el contenedor ve los datos de los servicios en read-only. Es **el mismo socket-de-confianza** que cAdvisor ya tiene; añadir el bind aquí es defendible. La alternativa, no leer disco desde Homepage y dejarlo sólo en Grafana, también es válida — variante §12.11.

### 7.4. `docker.yaml` y obtención de las API keys de los widgets

`~/homelab/stacks/dashboard/config/docker.yaml`:

```yaml
---
# Único provider: el host local accedido vía dockerproxy. Si en el futuro
# se enrola un nodo remoto (NAS, otro Pi), se añadiría aquí como segundo
# bloque (`remote-pi:` con `host:` apuntando a una segunda instancia de
# socket-proxy expuesta vía Tailscale; variante §12.12).

local:
  host: dockerproxy
  port: 2375
  # NO hay `socket: /var/run/docker.sock` (no se monta) — usamos el proxy.
  # NO hay `tls:` (la conexión es plana dentro de dashboard_internal).
```

#### 7.4.1. Procedimiento por servicio para obtener cada `HOMEPAGE_VAR_*`

| Variable | Servicio | Cómo obtenerla |
|---|---|---|
| `HOMEPAGE_VAR_PIHOLE_API_KEY` | Pi-hole | UI Pi-hole → **Settings → API/Web interface → "Show API token"** (Pi-hole v5) o **Settings → Web interface → API → API password** (v6). Copiar; pegar en el `.env`. |
| `HOMEPAGE_VAR_UPTIMEKUMA_TOKEN` | Uptime Kuma | UI Uptime Kuma → **Settings → API Keys → Add API Key** → nombre `homepage-readonly`. Pegar al `.env`. **Slug** del status page (`slug: home` en `services.yaml`): UI → **Status Pages → New Status Page** → slug `home`, monitores marcados como públicos. |
| `HOMEPAGE_VAR_GRAFANA_TOKEN` | Grafana | UI Grafana → **Administration → Service Accounts → Add new** → nombre `homepage-readonly`, role Viewer. **Add service account token**, expiry sin caducidad. Pegar al `.env`. |
| `HOMEPAGE_VAR_PORTAINER_TOKEN` | Portainer | UI Portainer → **My account (icono superior derecha) → Access Tokens → Add access token** → nombre `homepage-readonly`. Pegar al `.env`. **Endpoint id** (`env: 1` en `services.yaml`): UI → **Environments**, anotar el id numérico (típicamente `1` para el local). |
| `HOMEPAGE_VAR_NEXTCLOUD_USER` y `HOMEPAGE_VAR_NEXTCLOUD_PASSWORD` | Nextcloud | UI Nextcloud → **Settings → Personal → Security → Devices & sessions → Create new app password** → nombre `homepage`. Pegar el password generado. **Usuario**: el nombre del usuario admin (no el email). |
| `HOMEPAGE_VAR_PAPERLESS_TOKEN` | Paperless-ngx | UI Paperless → **My Profile (avatar) → Edit Profile → API Auth Token → Generate**. Pegar al `.env`. |
| `HOMEPAGE_VAR_MEALIE_TOKEN` | Mealie | UI Mealie → **Profile → API Tokens → New Token** → nombre `homepage`. Pegar. |
| `HOMEPAGE_VAR_HASS_TOKEN` | Home Assistant | UI HASS → **Profile (esquina inferior izquierda) → Long-Lived Access Tokens → Create token** → nombre `homepage`. Pegar. |
| `HOMEPAGE_VAR_SONARR_KEY` | Sonarr | UI Sonarr → **Settings → General → Security → API Key**. Copiar tal cual (la API key del propio user). |
| `HOMEPAGE_VAR_RADARR_KEY` | Radarr | UI Radarr → mismo path que Sonarr. |
| `HOMEPAGE_VAR_PROWLARR_KEY` | Prowlarr | UI Prowlarr → mismo path. |
| `HOMEPAGE_VAR_TRANSMISSION_USER` y `HOMEPAGE_VAR_TRANSMISSION_PASSWORD` | Transmission | Los del `.env` del propio Transmission ([`../10-descargas/01-transmission.md`](../10-descargas/01-transmission.md)). Reusar valores. |
| `HOMEPAGE_VAR_JELLYFIN_KEY` | Jellyfin | UI Jellyfin → **Dashboard → API Keys → "+"** → nombre `homepage`. Pegar. |
| `HOMEPAGE_VAR_AUDIOBOOKSHELF_TOKEN` | Audiobookshelf | UI ABS → **Settings → Users → admin → API Token (regenerate si es la primera vez)**. Pegar. |
| `HOMEPAGE_VAR_WATCHTOWER_TOKEN` | Watchtower | El que se configuró en [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4 (env `WATCHTOWER_HTTP_API_TOKEN`). Reusar. |

> **Convención**: cada API key generada para Homepage se nombra **`homepage-readonly`** (o `homepage` cuando el servicio no permita prefijo) en la UI del servicio que la emite. Eso facilita su revocación en bloque ("rotar todas las keys de homepage") sin tocar las del operador.

> **Tras editar el `.env`** (sustituir cada `__GENERATE_AND_REPLACE__` por el valor real):
>
> ```bash
> sudo $EDITOR /mnt/hd2t/services/homepage/.env
> # Recargar sólo Homepage para que coja las nuevas envs:
> cd ~/homelab/stacks/dashboard
> docker compose --env-file /mnt/hd2t/services/homepage/.env up -d homepage
> # NO usar `restart`: no relee env_file. `up -d` recrea con env_file actualizado.
> ```

### 7.5. `bookmarks.yaml` — bookmarks de la página

`~/homelab/stacks/dashboard/config/bookmarks.yaml`:

```yaml
---
- Documentación:
    - Homelab docs:
        - abbr: HL
          href: https://github.com/<usuario>/homelab
          description: Repositorio del homelab
    - Raspberry Pi 5:
        - abbr: PI
          href: https://www.raspberrypi.com/documentation/
    - Docker docs:
        - abbr: DK
          href: https://docs.docker.com/
    - Caddy docs:
        - abbr: CD
          href: https://caddyserver.com/docs/

- Operación:
    - Pi-hole admin:
        - abbr: PH
          href: https://pihole.lan/admin
    - Portainer:
        - abbr: PT
          href: https://portainer.lan
    - Grafana:
        - abbr: GR
          href: https://grafana.lan

- Externos:
    - GitHub:
        - abbr: GH
          href: https://github.com/
    - Tailscale admin:
        - abbr: TS
          href: https://login.tailscale.com/admin/machines
```

`abbr` (2-3 letras) es lo que se pinta en el "icono" cuadrado cuando no hay imagen. Si se prefieren iconos reales, sustituir por `icon: <nombre>.png` (busca primero en `/app/public/icons/`, luego en el set público dashboard-icons).

### 7.6. Sincronizar el repo con el bind mount

```bash
# Script reusable: ~/homelab/stacks/dashboard/sync-config.sh
cat > ~/homelab/stacks/dashboard/sync-config.sh <<'EOF'
#!/usr/bin/env bash
# Sincroniza ~/homelab/stacks/dashboard/config/ → /mnt/hd2t/services/homepage/config/
# y dispara un reload SIGHUP a Homepage (que recarga YAML sin reiniciar).
set -euo pipefail

REPO_DIR="$HOME/homelab/stacks/dashboard/config"
DEST_DIR="/mnt/hd2t/services/homepage/config"

sudo rsync -av --delete \
  --exclude='logs/' \
  --chown=homelab:homelab \
  --chmod=Du=rwx,Dg=rx,Do=,Fu=rw,Fg=r,Fo= \
  "${REPO_DIR}/" "${DEST_DIR}/"

# Homepage 0.10+ recarga al detectar mtime nuevo en los YAML; un cambio de
# rsync ya basta. Si por alguna razón no recarga, forzar:
docker kill --signal SIGHUP homepage 2>/dev/null || true

echo "Sync OK. Homepage recargará en <30 s."
EOF
chmod +x ~/homelab/stacks/dashboard/sync-config.sh

# Primer sync con los YAML completos:
~/homelab/stacks/dashboard/sync-config.sh
```

> **No se incluyen los logs en el sync**: `--exclude='logs/'` evita que `homepage.log` (escrito por la app) se mande de vuelta al repo y arme un loop.

> **Permisos**: la app corre como UID 1000 (`PUID`) y necesita escribir en `/app/config/logs/`. El `--chmod=Du=rwx,Dg=rx,Do=,Fu=rw,Fg=r,Fo=` asegura `0750` en dirs y `0640` en ficheros, propietario `homelab:homelab` (= UID 1000 en el host = PUID dentro del contenedor).

---

## 8. Verificación

### 8.1. Healthcheck Docker de los dos contenedores

```bash
docker inspect dockerproxy homepage \
  --format '{{.Name}} {{.State.Health.Status}}'
# Esperado:
#   /dockerproxy healthy
#   /homepage    healthy
```

### 8.2. UI accesible vía Caddy con Authelia delante

```bash
# Sin cookie de Authelia: 302 a auth.lan
curl -ksI -H 'Host: home.lan' --resolve home.lan:443:192.168.1.10 \
  https://home.lan/ | head -3
# Esperado:
#   HTTP/2 302
#   location: https://auth.lan/?...
```

Desde el navegador (con cookie Authelia válida):

- `https://home.lan/` → carga la UI de Homepage.
- En la cabecera: cuadro de búsqueda + reloj + 3 widgets `resources` (CPU/RAM/temp del host, uso de hd2t, uso de hd5t) **si** los binds opcionales se aplicaron (§7.3).
- Bajo la cabecera: 11 grupos (`Infraestructura`, `Red`, ..., `Dashboards`) con las tarjetas de cada servicio. Cada tarjeta tiene icono + nombre + descripción + punto de estado (verde si `siteMonitor` responde 200, rojo si timeout).
- Bajo los servicios: bookmarks (3 grupos).

### 8.3. Verificar widgets en vivo

Cargar `https://home.lan/` y abrir DevTools (Network):

- En el panel "Network", filtrar por `/api/widgets/`. Tras el render inicial, deben aparecer requests cada 30 s a:
  - `/api/widgets/pihole/...` → 200 con JSON `{"queries_today":...,"ads_blocked_today":...}`.
  - `/api/widgets/uptimekuma/...` → 200 con `{"up":N,"down":M,"pause":K}`.
  - `/api/widgets/sonarr/...`, `radarr`, `prowlarr` → 200 con queue/wanted counts.
  - `/api/widgets/jellyfin/...` → 200 con totales.
  - `/api/widgets/nextcloud/...` → 200 con `{"freespace_human":"...GB"}`.
  - `/api/widgets/paperlessngx/...` → 200 con totales.

Si alguno devuelve 401 o 500: la API key de ese servicio no fue aceptada. Volver a §7.4 para regenerarla. Logs:

```bash
docker logs homepage 2>&1 | grep -iE 'error|warn' | tail -30
# Buscar líneas como:
#   [warn] widget pihole: 401 Unauthorized — check HOMEPAGE_VAR_PIHOLE_API_KEY
#   [warn] widget jellyfin: ECONNREFUSED — service not reachable on http://jellyfin:8096
```

### 8.4. Verificar el auto-discovery por labels

```bash
# Listar contenedores y sus labels homepage.*:
docker ps --format '{{.Names}}' | while read c; do
  docker inspect "$c" --format '{{.Name}} group={{ index .Config.Labels "homepage.group" }} name={{ index .Config.Labels "homepage.name" }}' 2>/dev/null
done | grep -v 'group= name=' | sort
# Esperado: una línea por servicio que tiene labels homepage.*, p.ej.
#   /caddy        group=Red             name=Caddy
#   /pihole       group=Red             name=Pi-hole
#   /grafana      group=Monitorización  name=Grafana
#   ...
```

Aunque `services.yaml` ya declara explícitamente cada servicio, Homepage **completa** la información leyendo las labels (descripción, icono, href) cuando el campo no está fijado en el YAML. La consecuencia práctica: si en el futuro se renombra un servicio en su `docker-compose.yml` (e.g. cambiar `homepage.description: "Wiki"` a `homepage.description: "Wiki + KB"`), el dashboard refleja el cambio sin tocar `services.yaml`. La descripción explícita en `services.yaml` la sobrescribe (es la fuente prioritaria).

### 8.5. Verificar el log de Homepage

```bash
sudo tail -50 /mnt/hd2t/services/homepage/config/logs/homepage.log
```

Debe verse algo como:

```
[2025-XX-XX 10:00:00] [info] config: services.yaml loaded — 11 groups, 35 services
[2025-XX-XX 10:00:00] [info] config: widgets.yaml loaded — 8 widgets
[2025-XX-XX 10:00:00] [info] config: bookmarks.yaml loaded — 3 groups, 9 bookmarks
[2025-XX-XX 10:00:00] [info] docker: connected to dockerproxy:2375 — 30 containers visible
[2025-XX-XX 10:00:01] [info] widget pihole: ok (queries_today=14523)
[2025-XX-XX 10:00:01] [info] widget uptimekuma: ok (up=29, down=1)
...
[2025-XX-XX 10:00:30] [info] config: detected mtime change on services.yaml, reloading
```

> **Si aparece `[error] docker: connection refused dockerproxy:2375`**: el `depends_on: condition: service_healthy` no está funcionando o dockerproxy se ha caído. Comprobar `docker logs dockerproxy` y volver a §5.4.

### 8.6. Verificar la postura de seguridad de dockerproxy

```bash
# Endpoint permitido (devuelve 200):
docker exec homepage wget -qSO- --timeout=3 \
  http://dockerproxy:2375/info 2>&1 | head -1
# Esperado: HTTP/1.1 200 OK

# Endpoints prohibidos (devuelven 403):
for endpoint in /images/json /networks /volumes /swarm '/containers/abc/exec'; do
  echo -n "$endpoint => "
  docker exec homepage wget -qSO- --timeout=3 \
    "http://dockerproxy:2375${endpoint}" 2>&1 | head -1
done
# Esperado: cada uno devuelve "HTTP/1.1 403 Forbidden".
```

### 8.7. Smoke test desde el host con `curl`

```bash
# La home pública (con sesión Authelia simulada con un token válido):
# 1. Login en Authelia y guardar la cookie:
curl -ksc /tmp/authcookie -d 'username=admin&password=<pass>' \
  https://auth.lan/api/firstfactor

# 2. Pedir Homepage con la cookie:
curl -ksb /tmp/authcookie --resolve home.lan:443:192.168.1.10 \
  https://home.lan/ | grep -c 'Homelab Pi 5'
# Esperado: ≥ 1

# 3. Limpiar:
rm /tmp/authcookie
```

---

## 9. Backup

### 9.1. Qué se respalda y qué no

| Categoría | Path | ¿Se respalda? | Cómo |
|---|---|---|---|
| YAML de configuración | `/mnt/hd2t/services/homepage/config/{services,widgets,settings,bookmarks,docker,kubernetes}.yaml` | **Sí** vía Borgmatic + **además** versionados en git | Borg los respalda nightly como ficheros normales. La fuente de verdad es el repo git de `~/homelab/stacks/dashboard/config/`. Doble red de seguridad: si Borg falla, `git pull && rsync` recompone el dashboard en 1 minuto. |
| `.env` (secretos) | `/mnt/hd2t/services/homepage/.env` | **Sí** vía Borgmatic, **no** vía git | Path explícito en el `source_directories` de Borgmatic ([`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md)). Cifrado por Borg. Las API keys son revocables desde la UI del servicio que las emite, así que el peor caso (pérdida del archivo Borg) es soluble regenerando todas las claves — el `.env.example` versionado da el mapa completo de qué regenerar. |
| Iconos custom (opcional) | `/mnt/hd2t/services/homepage/icons/` | **Sí** si existe | Borg los respalda como ficheros normales. Si no se montan, el dir no existe y Borg lo salta. |
| Logs propios | `/mnt/hd2t/services/homepage/config/logs/homepage.log` | **No** (regenerable) | Excluir del Borgmatic con `exclude_patterns: ['*/logs/*']`. La info histórica relevante ya está en stdout de Docker (capturada por el demonio) y en Loki/Promtail si se desplegara. |
| BD / volúmenes | (no hay) | N/A | Homepage es stateless. |
| Cache `.next/` | (interna del contenedor, no expuesta como bind) | **No** (regenerable) | Se reconstruye en cada arranque. |

### 9.2. Patrón Borgmatic — respaldo de YAML simples

Sin hooks especiales (no hay BD). Añadir al `borgmatic/config.yaml`:

```yaml
source_directories:
  # ... (lo que ya hubiera) ...
  - /mnt/hd2t/services/homepage          # incluye config/, .env, e iconos custom

exclude_patterns:
  # ... (lo que ya hubiera) ...
  - /mnt/hd2t/services/homepage/config/logs
```

Verificación tras el siguiente run de Borgmatic:

```bash
sudo systemctl start borgmatic.service
sudo journalctl -u borgmatic.service --since '5 min ago' | grep -i homepage
# Esperado: ninguna línea de error.

LATEST=$(sudo borg list /mnt/hd2t/backups/borg --last 1 --short)
sudo borg list "/mnt/hd2t/backups/borg::$LATEST" \
  | grep '/services/homepage/' | head -10
# Esperado: services.yaml, widgets.yaml, ..., .env (cifrados, no se ve el contenido).
```

### 9.3. Restore (resumen)

Procedimiento detallado en [`../07-backups/03-backup-docker-volumes.md`](../07-backups/03-backup-docker-volumes.md). Resumen para Homepage:

```bash
# 1. Parar el stack:
cd ~/homelab/stacks/dashboard
docker compose --env-file /mnt/hd2t/services/homepage/.env down

# 2. Identificar el archivo Borg deseado:
sudo borg list /mnt/hd2t/backups/borg --short | tail -10

# 3. Extraer el árbol homepage del archivo:
LATEST=homelab-2025-XX-XX_XX-XX-XX
sudo mkdir -p /tmp/restore-homepage
cd /tmp/restore-homepage
sudo borg extract \
  "/mnt/hd2t/backups/borg::$LATEST" \
  mnt/hd2t/services/homepage

# 4. Sustituir (con backup defensivo):
sudo mv /mnt/hd2t/services/homepage \
        /mnt/hd2t/services/homepage.bak-$(date +%s)
sudo cp -a /tmp/restore-homepage/mnt/hd2t/services/homepage \
        /mnt/hd2t/services/
sudo chown -R homelab:homelab /mnt/hd2t/services/homepage

# 5. Levantar el stack:
cd ~/homelab/stacks/dashboard
docker compose --env-file /mnt/hd2t/services/homepage/.env up -d
sleep 60
docker inspect homepage dockerproxy --format '{{.Name}} {{.State.Health.Status}}'
# Esperado: ambos healthy

# 6. Limpiar el restore temporal y el backup defensivo (tras verificar):
sudo rm -rf /tmp/restore-homepage
sudo rm -rf /mnt/hd2t/services/homepage.bak-*
```

### 9.4. Recreate desde cero (sin backup)

Si por algún motivo Borg también está perdido (escenario disaster + 3-2-1 fallido):

```bash
# 1. Clonar el repo del homelab (versionable):
git clone <url> ~/homelab
cd ~/homelab/stacks/dashboard

# 2. Crear los dirs en hd2t:
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/homepage
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/homepage/config
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/homepage/config/logs

# 3. Reconstruir el .env desde .env.example:
sudo install -o homelab -g homelab -m 640 \
  ~/homelab/stacks/dashboard/.env.example \
  /mnt/hd2t/services/homepage/.env
sudo $EDITOR /mnt/hd2t/services/homepage/.env
# Regenerar TODAS las API keys siguiendo §7.4.

# 4. Sync de los YAML (que sí están en git):
~/homelab/stacks/dashboard/sync-config.sh

# 5. Levantar:
docker compose --env-file /mnt/hd2t/services/homepage/.env up -d
```

Costo: regenerar las ~14 API keys de los widgets, ~30 minutos. El dashboard queda idéntico al anterior porque los YAML son idénticos (vienen de git).

---

## 10. Operaciones cotidianas

### 10.1. Cambiar un servicio en el dashboard

```bash
# 1. Editar el YAML correspondiente en el repo:
$EDITOR ~/homelab/stacks/dashboard/config/services.yaml

# 2. Sync al bind mount:
~/homelab/stacks/dashboard/sync-config.sh

# 3. (Opcional) verificar que Homepage recargó:
sudo tail -5 /mnt/hd2t/services/homepage/config/logs/homepage.log
# Esperado: línea "[info] config: detected mtime change on services.yaml, reloading"

# 4. Refrescar el navegador (F5).

# 5. Commit en git:
cd ~/homelab/stacks/dashboard
git add config/services.yaml
git commit -m "homepage: ajustar tarjeta XXX (motivo)"
```

### 10.2. Añadir un servicio nuevo

Cuando se despliegue un servicio nuevo no contemplado en el catálogo inicial:

1. **En el `docker-compose.yml` del nuevo servicio**, añadir las labels `homepage.*` (convención §3.6 de estructura-compose). El servicio aparecerá automáticamente en el grupo correspondiente vía auto-discover.
2. **Si el servicio tiene widget oficial** en Homepage (lista: <https://gethomepage.dev/latest/widgets/>), añadir el bloque `widget:` en `services.yaml` y la API key en `.env.example`.
3. **`sync-config.sh`** y refresh del navegador.

### 10.3. Upgrade (Watchtower habilitado)

Homepage está en el grupo de auto-update de Watchtower ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2). Watchtower hace `docker pull` cada noche a las 04:00 y, si hay imagen nueva dentro del minor pinneado, hace `down` + `up -d` automáticamente.

Para subir de minor (ejemplo `0.10.x → 0.11.x`):

```bash
# 1. Leer release notes:
# https://github.com/gethomepage/homepage/releases

# 2. Backup defensivo:
sudo systemctl start borgmatic.service

# 3. Actualizar tag en .env.example y .env:
sed -i 's|HOMEPAGE_IMAGE=.*|HOMEPAGE_IMAGE=ghcr.io/gethomepage/homepage:v0.11.0|' \
  ~/homelab/stacks/dashboard/.env.example
sudo sed -i 's|HOMEPAGE_IMAGE=.*|HOMEPAGE_IMAGE=ghcr.io/gethomepage/homepage:v0.11.0|' \
  /mnt/hd2t/services/homepage/.env

# 4. Pull + up:
cd ~/homelab/stacks/dashboard
docker compose --env-file /mnt/hd2t/services/homepage/.env pull
docker compose --env-file /mnt/hd2t/services/homepage/.env up -d homepage

# 5. Verificar:
docker logs --tail 50 homepage
docker inspect homepage --format '{{.State.Health.Status}}'

# 6. Commit:
cd ~/homelab/stacks/dashboard
git add .env.example
git commit -m "homepage: bump to v0.11.0"
```

> **Rollback** (si el upgrade rompe los YAML por breaking changes): volver el tag al anterior en el `.env`, `docker compose pull && up -d`. Los YAML siguen siendo los mismos; si la nueva versión los rechaza, el rollback es instantáneo. Si la nueva versión escribe ficheros incompatibles en `/app/config`, restore desde Borg pre-upgrade (§9.3).

### 10.4. Rotar todas las `HOMEPAGE_VAR_*`

Operación rara, pero documentada por completitud:

```bash
# Para cada API key, ir a la UI del servicio emisor:
# - Pi-hole UI → Settings → API → Reset.
# - Uptime Kuma UI → Settings → API Keys → "homepage-readonly" → Delete + recreate.
# - Grafana UI → Service Accounts → "homepage-readonly" → tokens → Revoke + new.
# - Nextcloud → Settings → Security → app password → "homepage" → Revoke + new.
# - ... (idem para los demás)

# Pegar todos los nuevos valores en /mnt/hd2t/services/homepage/.env.

# Recrear el contenedor para que cargue las nuevas envs:
cd ~/homelab/stacks/dashboard
docker compose --env-file /mnt/hd2t/services/homepage/.env up -d homepage
```

### 10.5. Auditar qué tarjetas están "down"

```bash
# Listar contenedores no-running y mapear con el dashboard:
docker ps --filter status=exited --format '{{.Names}}'

# Cruzar con services.yaml — los `siteMonitor:` que apuntan a estos
# contenedores aparecerán en rojo en la UI.
```

Para auditar fuera de la UI:

```bash
docker exec homepage wget -qO- http://homepage:3000/api/services \
  | python3 -m json.tool | head -100
# Devuelve el árbol de servicios con su estado actual (online/offline).
```

### 10.6. Cambiar el motor de búsqueda

`settings.yaml` → `providers.searchProvider:` admite `duckduckgo`, `google`, `bing`, `baidu`, `brave`, `searxng` (con `searxngUrl: https://search.example/`). Tras editar, `sync-config.sh` y refresh.

### 10.7. Logs y observabilidad

```bash
# Logs del contenedor (Docker):
docker logs -f homepage
docker logs -f dockerproxy

# Log persistente de la app (en el bind mount):
sudo tail -F /mnt/hd2t/services/homepage/config/logs/homepage.log

# Grep errores de widgets:
docker logs homepage 2>&1 | grep -iE 'widget.*error|widget.*401|widget.*timeout'

# Log del proxy haproxy (qué endpoints se han pedido):
docker logs dockerproxy 2>&1 | tail -50
```

---

## 11. Solución de Problemas

| Síntoma | Causa probable | Solución |
|---|---|---|
| `home.lan` devuelve 400 "Untrusted Host" | `HOMEPAGE_ALLOWED_HOSTS` no incluye `home.lan`. | Editar `.env`, añadir el host, `docker compose up -d homepage`. |
| Cada tarjeta aparece en gris (sin punto verde) | `dockerproxy` no se levantó correctamente o el `siteMonitor:` apunta a un host inalcanzable desde Homepage. | `docker logs dockerproxy` y `docker exec homepage wget -qO- http://dockerproxy:2375/_ping`. Si el ping falla, `docker compose up -d dockerproxy`. Si el ping pasa pero la tarjeta sigue gris, verificar que `siteMonitor` resuelve por DNS interno: `docker exec homepage getent hosts <hostname>`. |
| Una tarjeta concreta en rojo cuando el servicio está vivo | El path del `siteMonitor` no devuelve 2xx. Algunos servicios redirigen a `/login` con 302. | Cambiar el `siteMonitor:` a un endpoint de salud (e.g. `/api/healthcheck`, `/health`, `/ping`). Si no hay endpoint público, usar `docker:<container>` (vía dockerproxy). |
| Widget de Pi-hole en blanco / 401 | `HOMEPAGE_VAR_PIHOLE_API_KEY` incorrecto o cambió la API entre Pi-hole v5 y v6. | Verificar versión: `docker exec pihole pihole -v`. Ajustar `version: 5` o `version: 6` en `services.yaml`. Regenerar la API token desde la UI y actualizar el `.env`. |
| Widget de Grafana 401 | El token es de tipo "API key" (deprecado en Grafana 11) o el role del Service Account es Admin (debe ser Viewer). | Recrear el Service Account con role Viewer y nuevo token. |
| Widget de Sonarr/Radarr/Prowlarr 401 | API key copiada con espacio extra al final (las UIs de los ARRs lo permiten). | Re-copiar la API key sin espacios y guardar el `.env`. |
| Tras un `docker compose up -d` el dashboard pierde la sesión Authelia | Es por diseño: la cookie es del dominio `auth.lan`, no del subdominio `home.lan`. El reverse proxy `forward_auth` valida la cookie en cada request, no la guarda Homepage. | Hacer login otra vez. Si pasa muy seguido, ajustar `session.expiration` en Authelia ([`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)). |
| `docker logs homepage` repite `failed to load services.yaml: yaml: line N: ...` | Indentación rota o tab dentro del YAML. | `python3 -c "import yaml; yaml.safe_load(open('config/services.yaml'))"` revela el error con línea exacta. Corregir y `sync-config.sh`. |
| `dockerproxy` en CrashLoop con `bind: address already in use` | Otro contenedor en `dashboard_internal` ya escucha en 2375. | Imposible en la config de este doc (sólo dockerproxy). Verificar que no se duplicó por error: `docker ps --filter network=dashboard_internal`. |
| Recargar Caddy provoca 502 en `home.lan` | `import authelia_proxy one_factor` aún no está exportado por el snippet de [`../03-red/04-caddy.md`](../03-red/04-caddy.md). | Verificar el snippet `(authelia_proxy)` admite el argumento `{args[0]}`. Si no, usar `import authelia_proxy` (sin arg) y la política se queda en la default. |
| Widget de Home Assistant: "Long-Lived Token expired" | El token tiene caducidad de 10 años pero a veces se invalida si HASS recrea el JWT secret. | Generar un token nuevo en HASS → Profile → Long-Lived Access Tokens. Pegar al `.env`. |
| Widget de Transmission devuelve siempre 0 KB/s con descargas activas | `rpcUrl` mal escrito (el path por defecto es `/transmission/rpc`, no `/`). | Verificar `rpcUrl: /transmission/` en `services.yaml`. Mismo path que la UI principal. |
| `homepage.log` crece sin parar | `LOG_LEVEL=debug` activado por error. | Volver a `info` en el `.env`, recrear contenedor. Truncar el log con `sudo truncate -s0 /mnt/hd2t/services/homepage/config/logs/homepage.log`. |
| Tarjetas visibles para servicios cuyo contenedor está parado | Default: las tarjetas se mantienen gris/down. Si se quieren ocultar, ajustar `docker.local.includeStopped: false` en `docker.yaml` (ya por defecto). | Si a pesar de eso siguen visibles, es porque están declaradas en `services.yaml` (catálogo estático, no dependen del estado del contenedor). Quitar la entrada del YAML para que desaparezca. |

---

## 12. Variantes opt-in

### 12.1. Bind de discos para los widgets `resources` con `disk:`

Por defecto, los widgets `disk: /mnt/hd2t` y `disk: /mnt/hd5t` no muestran datos porque el contenedor no ve esos paths. Para activarlos, editar el `homepage.volumes:` del compose:

```yaml
    volumes:
      - ${DATA_PATH}:/app/config:rw
      - ${ICONS_PATH}:/app/public/icons:ro
      - /mnt/hd2t:/mnt/hd2t:ro
      - /mnt/hd5t:/mnt/hd5t:ro
```

`docker compose up -d homepage`. Refresh: ahora los widgets muestran "Used X.X TB / 1.8 TB" y "Used Y.Y TB / 4.5 TB".

> **Postura de seguridad**: con esto el contenedor lee los datos de **todos** los servicios. Mismo nivel de exposición que cAdvisor (que ya monta `/`). Aceptable si se confía en la imagen de Homepage tanto como en la de cAdvisor; si no, dejar el widget sin datos.

### 12.2. Bind de `/sys/class/thermal` para el widget de temperatura

Análogo a 12.1, pero para el `cputemp: true`:

```yaml
    volumes:
      - ${DATA_PATH}:/app/config:rw
      - ${ICONS_PATH}:/app/public/icons:ro
      - /sys/class/thermal:/sys/class/thermal:ro
```

Coste: el contenedor ve la temperatura del SoC. No hay riesgo realista — es info pública del kernel.

### 12.3. Filtrar contenedores visibles a Homepage

Por defecto Homepage ve todos los contenedores que `dockerproxy` deja pasar (= todos). Si se quiere ocultar `mariadb`, `redis`, `postgres` (servicios internos sin UI), añadir en `docker.yaml`:

```yaml
local:
  host: dockerproxy
  port: 2375
  includeStopped: false
  # Filtrar por label: sólo contenedores con homepage.group= aparecen en
  # auto-discover. Servicios sin label seguirán visibles si se declaran
  # explícitamente en services.yaml.
```

Y, en el `docker-compose.yml` del servicio interno (mariadb, redis, ...), **no añadir** labels `homepage.*` (ya es la convención del homelab — sólo se añaden a servicios con UI).

### 12.4. Subir Authelia a `two_factor`

Editar el `Caddyfile`:

```caddy
home.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    import authelia_proxy two_factor       # << cambia aquí
    reverse_proxy http://homepage:3000 {
        flush_interval -1
    }
}
```

`docker compose exec caddy caddy reload`. La próxima visita a `home.lan` exigirá TOTP además de password.

### 12.5. Iconos custom

Para usar logos privados (servicios internos de la familia, marcadores corporativos):

```bash
sudo install -d -o homelab -g homelab -m 750 /mnt/hd2t/services/homepage/icons
sudo cp ~/icons/*.{png,svg} /mnt/hd2t/services/homepage/icons/
sudo chown -R homelab:homelab /mnt/hd2t/services/homepage/icons
```

En `services.yaml` o `bookmarks.yaml`, referenciar el icono por nombre de archivo (sin path):

```yaml
- Mi servicio:
    icon: mi-logo.png      # busca /app/public/icons/mi-logo.png primero, luego CDN
```

### 12.6. Socket Docker directo (sin proxy)

Variante NO recomendada por defecto, justificada para entornos donde se quiere reducir la imagen `dockerproxy`. Editar el `docker-compose.yml`:

```yaml
  homepage:
    # ... (resto igual) ...
    volumes:
      - ${DATA_PATH}:/app/config:rw
      - ${ICONS_PATH}:/app/public/icons:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    group_add:
      - "${DOCKER_GID}"
    networks:
      - homelab     # ya no necesita dashboard_internal
    # depends_on: dockerproxy → quitar
```

Y `docker.yaml`:

```yaml
local:
  socket: /var/run/docker.sock
```

Borrar el servicio `dockerproxy` del compose. Coste: el contenedor Homepage tiene `/var/run/docker.sock` directo; cualquier RCE en él da control total del demonio. Beneficio: una imagen menos, una red menos, ~50 MB de RAM menos.

### 12.7. Bypass Authelia para `/api/healthcheck`

Si Uptime Kuma o un sistema externo necesita probar `https://home.lan/api/healthcheck` sin sesión:

```caddy
home.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers

    # Bypass del forward_auth para el healthcheck:
    @healthcheck path /api/healthcheck
    handle @healthcheck {
        reverse_proxy http://homepage:3000
    }

    # El resto pasa por Authelia:
    handle {
        import authelia_proxy one_factor
        reverse_proxy http://homepage:3000 {
            flush_interval -1
        }
    }
}
```

### 12.8. Activar el widget de Vaultwarden

Vaultwarden no expone un endpoint público para "número de items"; el widget de Homepage usa el `/admin/api/...` que requiere `admin_token`. Procedimiento:

1. En `~/homelab/stacks/security/.env` (o donde viva Vaultwarden) verificar que `ADMIN_TOKEN` está fijado y se conoce su valor.
2. Añadir al `.env` de Homepage: `HOMEPAGE_VAR_VAULTWARDEN_ADMIN_TOKEN=<el valor>`.
3. Descomentar el bloque `widget:` de Vaultwarden en `services.yaml`.
4. `sync-config.sh` y `docker compose up -d homepage`.

### 12.9. Widget genérico `customapi` para servicios sin widget oficial

Para Stash, Linkding o cualquier servicio con un endpoint REST que devuelva JSON:

```yaml
- Stash:
    icon: stash.png
    href: https://stash.lan
    description: Multimedia con metadatos
    siteMonitor: http://stash:9999/healthz
    widget:
      type: customapi
      url: http://stash:9999/graphql
      method: POST
      headers:
        ApiKey: "{{HOMEPAGE_VAR_STASH_KEY}}"
      requestBody: '{"query":"{ stats { sceneCount imageCount } }"}'
      mappings:
        - field:
            data:
              stats:
                sceneCount
          label: Scenes
        - field:
            data:
              stats:
                imageCount
          label: Images
```

Coste: cada widget custom es código frágil; cambios en la API del servicio rompen el widget silenciosamente. Sólo añadir si aporta.

### 12.10. RSS feed en la cabecera

Añadir a `widgets.yaml`:

```yaml
- rss:
    feed: https://www.raspberrypi.com/feed/
    limit: 5
    refresh: 3600000      # 1 h en ms; los feeds no cambian rápido
```

### 12.11. Ocultar los widgets `resources` y dejar todo en Grafana

Comentar los tres bloques `resources:` en `widgets.yaml`. La cabecera queda con sólo el reloj y la búsqueda. El uso de disco/CPU/RAM se mira en Grafana, donde está mejor pintado y con histórico.

### 12.12. Multi-host (NAS u otro Pi vía Tailscale)

El día que haya un segundo nodo (NAS, otro Pi de respaldo) corriendo otro `docker-socket-proxy` accesible vía Tailscale:

```yaml
# docker.yaml
local:
  host: dockerproxy
  port: 2375

remote-nas:
  host: nas.tail-XXXXX.ts.net
  port: 2375
  # Si el proxy remoto exige TLS:
  # tls:
  #   skipVerify: true   # confianza en la red Tailscale
```

Cada servicio en `services.yaml` puede etiquetarse con `server: remote-nas` para que su `siteMonitor: docker:<container>` apunte al socket remoto en lugar del local.

### 12.13. Acceso sólo Tailscale (sin LAN)

Mismo patrón que el resto: borrar el bloque `home.{$LAN_DOMAIN}` del `Caddyfile` y dejar sólo `home.{$TS_DOMAIN}` + actualizar `HOMEPAGE_ALLOWED_HOSTS=home.tail-XXXXX.ts.net`. Útil cuando el operador no quiere que ni siquiera el dashboard sea accesible desde la LAN sin VPN.

---

## 13. Referencias

- **Homepage** — proyecto upstream: <https://gethomepage.dev/>.
  - Documentación: <https://gethomepage.dev/latest/>.
  - Catálogo de widgets: <https://gethomepage.dev/latest/widgets/>.
  - Releases: <https://github.com/gethomepage/homepage/releases>.
  - Imagen Docker: `ghcr.io/gethomepage/homepage` — <https://github.com/gethomepage/homepage/pkgs/container/homepage>.
- **tecnativa/docker-socket-proxy** — proxy haproxy de la API Docker:
  - Repo: <https://github.com/Tecnativa/docker-socket-proxy>.
  - Imagen Docker: `ghcr.io/tecnativa/docker-socket-proxy` — <https://hub.docker.com/r/tecnativa/docker-socket-proxy>.
- **dashboard-icons** — set de iconos consumido por defecto: <https://github.com/walkxcode/dashboard-icons>.
- Documentos del homelab que este doc consume y extiende:
  - [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) — convenciones de stack, redes y labels (incluida la familia `homepage.*`).
  - [`../03-red/04-caddy.md`](../03-red/04-caddy.md) — bloque preparado y comentado para `home.{$LAN_DOMAIN}` y los snippets `lan_internal_tls`, `security_headers`, `authelia_proxy`.
  - [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) — `forward_auth` y políticas `one_factor`/`two_factor`.
  - [`../05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md), [`../05-monitorizacion/02-grafana.md`](../05-monitorizacion/02-grafana.md), [`../03-red/02-pihole.md`](../03-red/02-pihole.md) — fuentes de las API keys de los widgets principales.
  - [`../07-backups/02-borgmatic.md`](../07-backups/02-borgmatic.md) — patrón de respaldo de YAMLs y `.env`.
  - [`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) — bootstrap de `/mnt/hd2t/services/homepage/`.
