# Dozzle

## Descripción

Despliegue de **Dozzle** (`amir20/dozzle`, Go + frontend Vue, MIT) como **visor de logs de contenedores Docker en tiempo real** del homelab. Dozzle se conecta al socket Docker (`/var/run/docker.sock`, montado read-only), descubre la lista de contenedores y, para cada uno, sirve en un navegador moderno el flujo `docker logs --follow` con coloreado, filtros por texto, búsqueda por regex, marcado de keywords (`error`, `warn`, ...), agrupación por stack Compose, descarga del backlog y vista "single page" multi-contenedor para correlacionar eventos. **No** persiste nada en disco (es un proxy stateless de la API Docker), **no** expone `/metrics` para Prometheus y **no** envía notificaciones — es deliberadamente complementario a Uptime Kuma ([`./05-uptime-kuma.md`](./05-uptime-kuma.md)) y a Grafana Loki (no incluido en este homelab): cuando una alerta de Kuma o un dashboard de Grafana cAdvisor ([`./04-cadvisor.md`](./04-cadvisor.md)) marca un contenedor en rojo, Dozzle es la herramienta para abrir su log y entender por qué.

Dozzle es el **sexto y último** servicio del stack `monitoring` (fila §1.1 de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)). Este documento **extiende** el `~/homelab/stacks/monitoring/docker-compose.yml` que dejaron Prometheus, Grafana, Node Exporter, cAdvisor y Uptime Kuma, **no** crea un compose nuevo. Tras este doc el stack tiene seis servicios (`prometheus`, `grafana`, `node-exporter`, `cadvisor`, `uptime-kuma`, `dozzle`) y la Fase 5 queda completa; la siguiente fase ([`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md)) inaugura un stack distinto.

> **Alcance de red**: la UI de Dozzle se sirve **únicamente** vía Caddy en `https://logs.{$LAN_DOMAIN}`, protegida por **Authelia con `policy: two_factor`** (es una vista cruda de logs internos, donde aparecen credenciales en error trazas, tokens en warnings de OAuth, IPs internas, paths absolutos, ... — exige el mismo nivel de protección que Portainer o Grafana). Dozzle **no** publica `:8080` al host; **no** se expone a internet; **no** abre conexiones salientes (no telemetría, no analytics — desactivadas explícitamente en §5). El único tráfico saliente del contenedor es el bind UNIX al socket Docker en `/var/run/docker.sock`.

> **Por qué Dozzle y no otra herramienta** (Loki + Grafana, ELK / Elastic, Graylog, Logspout + journald, `docker logs` puro, ctop):
>
> 1. **Cero infraestructura para "ver el log de un contenedor ahora"**. El operador del homelab abre `https://logs.lan/`, hace click en el contenedor sospechoso y ve el flujo `--follow` en directo. Ni Loki ni ELK ofrecen esa UX out-of-the-box: requieren un agente (Promtail/Filebeat), un broker, un índice, parsing de timestamp, y una query LogQL/KQL para "los últimos 200 mensajes de jellyfin". Para un homelab de un solo nodo y un solo operador, ese coste no se amortiza.
> 2. **No duplica el almacenamiento de logs**. Los logs ya viven en `/var/lib/docker/containers/<id>/<id>-json.log` con la rotación configurada en el `daemon.json` (10 MB × 3, [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md) §4). Dozzle los lee en streaming sin copiarlos a otro almacén; cuando se rotan, el log antiguo desaparece igual que con `docker logs`. Si en el futuro se necesita histórico (>30 d) y queries estructuradas (ALL ERRORS in last 24h), se añadirá Loki en paralelo: Dozzle no estorba.
> 3. **Acceso directo y autocontenido al socket Docker**. La misma "puerta" (`/var/run/docker.sock`, ro) que ya usan cAdvisor ([`./04-cadvisor.md`](./04-cadvisor.md)), Uptime Kuma ([`./05-uptime-kuma.md`](./05-uptime-kuma.md), monitor "Docker container") y Watchtower ([`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md)). No introduce un nuevo agente que recolectar.
> 4. **Compatible con `forward-proxy` de Authelia**. A partir de v6, Dozzle soporta `DOZZLE_AUTH_PROVIDER=forward-proxy`: lee la cabecera `Remote-User` que inyecta el `forward_auth` de Caddy + Authelia y la usa como identidad. Resultado: **un solo login** Authelia (a diferencia de Uptime Kuma, que mantiene su login propio). Para un homelab personal, eso elimina una fricción notable.
> 5. **Multi-arch oficial**. La imagen `amir20/dozzle` se publica para `linux/arm64` (junto a `amd64` y `arm/v7`) directamente en Docker Hub. Sin ajustes en una Pi 5.
> 6. **Coste mínimo en una Pi 5**. Idle <30 MB RAM, <0,5 % CPU; en activo (5 streams `--follow` simultáneos abiertos en pestañas distintas), 60–90 MB y CPU breve por reflujo. Más barato que cualquier alternativa con almacén propio.
> 7. **Acciones explícitamente deshabilitadas**. Las versiones 8.x de Dozzle exponen, opcionalmente, **acciones sobre los contenedores** (`start` / `stop` / `restart`) y **shell embebido** (`/exec`). Ambas se desactivan aquí (`DOZZLE_ENABLE_ACTIONS=false`, `DOZZLE_ENABLE_SHELL=false`): para eso ya está Portainer ([`../02-docker/03-portainer.md`](../02-docker/03-portainer.md)). Dozzle queda como herramienta **read-only de logs**, lo que reduce drásticamente la superficie aunque se filtre la cookie Authelia.
>
> Otras alternativas (`ctop`, `lazydocker`) viven en la TTY del operador y no escalan al móvil. `Logspout → Papertrail` requiere SaaS externo (descartado por el alcance solo-LAN del homelab). Loki + Promtail + Grafana queda como evolución futura cuando haya necesidad real de queries históricas.

---

## Requisitos Previos

- **Prometheus desplegado y sano** según [`./01-prometheus.md`](./01-prometheus.md): no es dependencia técnica de Dozzle (Dozzle no exporta métricas), pero la Fase 5 se redacta en orden y este doc asume que las filas anteriores están completas y verificadas.
- **Grafana desplegado y sano** según [`./02-grafana.md`](./02-grafana.md). Tampoco es dependencia técnica; mismo motivo.
- **Node Exporter desplegado y sano** según [`./03-node-exporter.md`](./03-node-exporter.md). Idem.
- **cAdvisor desplegado y sano** según [`./04-cadvisor.md`](./04-cadvisor.md). Idem; además, comparte la decisión "bind socket Docker ro" que aquí se reutiliza.
- **Uptime Kuma desplegado y sano** según [`./05-uptime-kuma.md`](./05-uptime-kuma.md): `docker inspect uptime-kuma --format '{{.State.Health.Status}}'` devuelve `healthy`. El stack `monitoring` tiene cinco servicios corriendo y todos los placeholders de variables y compose están aplicados.
- **Caddy desplegado y sano** según [`../03-red/04-caddy.md`](../03-red/04-caddy.md): `docker inspect caddy --format '{{.State.Health.Status}}'` devuelve `healthy`. El `Caddyfile` carga snippets `lan_internal_tls`, `security_headers` y `authelia_proxy`. La CA interna del homelab está confiada en el navegador del operador.
- **Authelia desplegado y sano** según [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md): `docker inspect authelia --format '{{.State.Health.Status}}'` devuelve `healthy`. El operador tiene un usuario en `users_database.yml` con `groups: [admin]` y al menos un dispositivo TOTP enrolado. El snippet `authelia_proxy` reenvía `Remote-User`, `Remote-Groups`, `Remote-Name` y `Remote-Email` al backend (es lo que Dozzle lee).
- **Pi-hole desplegado y sano** según [`../03-red/02-pihole.md`](../03-red/02-pihole.md): la UI permite añadir un registro DNS local `logs.lan → 192.168.1.10` en §6.2 de este doc.
- **Stack `monitoring` ya inicializado** con los cinco servicios anteriores: `~/homelab/stacks/monitoring/{docker-compose.yml,prometheus.yml,grafana/...,.env.example}` versionados en git, `/mnt/hd2t/services/monitoring/.env` con todas las variables del stack hasta Uptime Kuma incluidas.
- **Red `homelab`** creada según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2 (`172.20.0.0/24`, bridge `br-homelab`, `external: true`).
- **Estructura de directorios** del stack `monitoring` ya en su sitio. El bootstrap original ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6.6) creó un `/mnt/hd2t/services/dozzle/` vacío del esquema antiguo "un dir por servicio" que aquí se **elimina** sin reemplazo: Dozzle no persiste datos en disco (§3.1).
- **`/var/run/docker.sock` accesible**: `test -S /var/run/docker.sock && echo "OK"`. Sin esto el contenedor arranca pero la lista de contenedores queda vacía.
- **`ufw` activo** según [`../01-sistema/03-seguridad-base.md`](../01-sistema/03-seguridad-base.md). No se añaden reglas: Dozzle no publica puertos al host; Caddy ya escucha en 443.
- **Comprobaciones rápidas**:
  ```bash
  # Stack monitoring tiene los cinco servicios anteriores (healthy):
  docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml ps
  # Esperado: prometheus, grafana, node-exporter, cadvisor, uptime-kuma — todos (healthy).

  # Caddy y Authelia sanos:
  docker inspect caddy authelia --format '{{.Name}} {{.State.Health.Status}}'
  # Esperado: /caddy healthy / /authelia healthy

  # El socket Docker existe y es UNIX socket:
  test -S /var/run/docker.sock && echo "docker.sock OK"
  # Esperado: docker.sock OK

  # Authelia ya inyecta Remote-User en el forward_auth (verificable contra
  # otro host ya protegido como portainer.lan):
  curl -ksI https://portainer.lan | head -1
  # Esperado: HTTP/2 302 (redirección a auth.lan), no 200 directo.
  ```

### Decisiones de diseño asumidas

| Decisión | Valor por defecto | Justificación |
|---|---|---|
| Imagen Docker | **`amir20/dozzle:v8.13.6`** | Imagen oficial multi-arch del proyecto upstream (MIT). La rama 8.x es la estable actual; introduce `forward-proxy` auth, modo agente para multi-host (no usado aquí, ver §9.4) y un selector de log levels más rico que la 7.x. La 8.x mantiene compatibilidad con el bind directo al socket Docker. |
| Tag de imagen | **Pinned a release puntual**, nunca `latest` | Misma regla de [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §6.1. Aunque Dozzle es stateless, los breaking changes de UI (cambio de URL de las acciones, cambio de cabeceras de auth, cambio de `DOZZLE_BASE`) llegan entre minors. Pinear el tag y subirlo manualmente tras leer las release notes evita que el operador encuentre la UI distinta una mañana. |
| Política de Watchtower | **`watchtower.enable: "true"`** | Coherente con [`../02-docker/04-watchtower.md`](../02-docker/04-watchtower.md) §4.2 (Dozzle está en la lista de incluidos). Los upgrades de patch dentro de 8.x son seguros (sin esquema, sin BD); para minor (8.13 → 8.14) Watchtower hará el pull cuando el operador suba el tag en el `.env`. |
| Modo de red | **Sólo `homelab`** (bridge `external`) | Caddy llama a `http://dozzle:8080` por DNS interno desde `homelab`. No hay scrape de Prometheus. **No** se usa `network_mode: host`: rompería la resolución DNS Docker, expondría `:8080` al LAN sin Caddy delante y obligaría a abrir `8080/tcp` en `ufw`. |
| `ports:` publicados al host | **Ninguno** | La UI se sirve **únicamente** vía Caddy (`reverse_proxy http://dozzle:8080`). Publicar `:8080` al host duplicaría la entrada y permitiría saltarse Caddy + Authelia. Mismo razonamiento que Prometheus, Grafana, Uptime Kuma. |
| Acceso a la UI | **Detrás de Authelia** (`forward_auth`, política `two_factor`) | Los logs en bruto contienen rutinariamente datos sensibles: stack traces con paths, errores de OAuth con tokens parciales, IPs internas, nombres de usuario de servicios. Es **consola de operaciones**: requiere doble factor, igual que Portainer, Grafana, Uptime Kuma o Vaultwarden. |
| Auth provider de Dozzle | **`forward-proxy`** | Dozzle 6+ soporta delegar la autenticación al reverse proxy: con `DOZZLE_AUTH_PROVIDER=forward-proxy` lee `Remote-User` del header inyectado por Authelia y la usa como identidad sin pedir un segundo login. Eso elimina la fricción "doble login" que sí tiene Kuma. La alternativa `simple` (users-file local) duplicaría la gestión de credenciales y se descarta. La alternativa `none` rompe la trazabilidad (todos los logs ven "anónimo"). |
| `DOZZLE_AUTH_HEADER_USER` | **`Remote-User`** (default upstream) | Default: el header que reenvía `import authelia_proxy` de Caddy con la identidad. Coincide con el contrato Authelia. Hacerlo explícito documenta la dependencia. |
| `DOZZLE_AUTH_HEADER_NAME` | **`Remote-Name`** (default upstream) | Display name del usuario, también enviado por Authelia. Aparece en la esquina superior derecha de la UI de Dozzle. |
| `DOZZLE_AUTH_HEADER_FILTER` | **(no se usa)** | Permite filtrar contenedores visibles según un header (ej. group → containers). El homelab tiene un solo operador admin: filtrar no aporta. Si en el futuro se enrolara un usuario "lectura sólo logs Jellyfin", se reactivaría aquí. |
| `DOZZLE_NO_ANALYTICS` | **`true`** | Dozzle envía por defecto un ping anónimo de telemetría (`https://stats.dozzle.dev`) al arrancar. Se desactiva por coherencia con la postura "no fuga de información" del homelab. La UI lo permite también; aquí se fija por env para que sobreviva a recreates. |
| `DOZZLE_LEVEL` | **`info`** | Default. Los logs propios de Dozzle ("started", "client connected to /api/logs/..."). `debug` se usa puntualmente en troubleshooting (§9.2). |
| `DOZZLE_HOSTNAME` | **`pi5-homelab`** (display) | Aparece en la esquina inferior izquierda de la UI como nombre del nodo. En modo single-host es estético; cuando se enrole un agente remoto (§9.4), distingue qué nodo está sirviendo cada log. |
| `DOZZLE_ENABLE_ACTIONS` | **`false`** | Dozzle 8.x permite, opcionalmente, exponer botones `start` / `stop` / `restart` por contenedor. Se desactiva: para gestionar el ciclo de vida ya está Portainer ([`../02-docker/03-portainer.md`](../02-docker/03-portainer.md)). Mantener Dozzle como **lectura pura** reduce el blast-radius si la cookie Authelia se filtra. |
| `DOZZLE_ENABLE_SHELL` | **`false`** | Dozzle 8.x ofrece, opcionalmente, una shell `/exec` embebida (equivalente a `docker exec -it ... sh`). Se desactiva: shell de contenedores se gestiona desde el SSH del operador o desde Portainer. Activar `/exec` desde el navegador convierte un robo de cookie en RCE en cualquier contenedor del homelab. |
| `DOZZLE_FILTER` | **(vacío, todos los contenedores visibles)** | Por defecto Dozzle muestra cualquier contenedor que el socket exponga. Para el homelab es lo deseado (el operador es admin). Si se quisiera ocultar `mariadb` o `redis` de la lista, se usaría `DOZZLE_FILTER=label=dozzle.show=true` y se etiquetarían los relevantes; queda como variante en §9.1. |
| `DOZZLE_BASE` | **(no se usa)** | Default `/`. Dozzle se sirve en el root de `logs.lan`, sin subpath. Si en el futuro se quisiera publicar como `https://homepage.lan/logs/`, se cambiaría a `DOZZLE_BASE=/logs` + ajuste del `Caddyfile`. |
| Acceso al socket Docker | **`/var/run/docker.sock:/var/run/docker.sock:ro`** | Imprescindible: la lista de contenedores y los streams de logs vienen de la API Docker. Read-only acota a `GET /containers/...` y `GET /containers/<id>/logs?follow=1`. La superficie es la misma que Portainer (rw, justificado por gestión), cAdvisor (ro) y Uptime Kuma (ro) ya tienen. **Si** se quiere reducir aún más esa exposición, se puede sustituir el socket directo por `tecnativa/docker-socket-proxy` con sólo `CONTAINERS=1`, `INFO=1`, `EVENTS=1`, `PING=1` (variante futura, §9.5). |
| Usuario del contenedor | **`user: "${PUID}:${PGID}"` (1000:1000)** + `group_add: ${DOCKER_GID}` | La imagen oficial soporta correr como non-root. El acceso al socket requiere pertenecer al grupo `docker` del host (GID típico 998 en Bookworm); se añade vía `group_add` con la variable `${DOCKER_GID}`. Si la imagen alpine usa `nobody:nogroup` ya con GID alineado, `group_add` sigue siendo necesario para acceder al socket. |
| `cap_drop`/`cap_add` | **`cap_drop: [ALL]`**, sin `cap_add` | El binario Go de Dozzle no necesita capabilities especiales: HTTP server interno + lectura del socket UNIX. Sin `cap_add` no puede abrir sockets raw, no puede modificar firewall, no puede mountar nada. |
| `security_opt: no-new-privileges:true` | **Activado** | Plantilla §6.1 de estructura-compose. Sin coste para Dozzle (no usa setuid/setgid). Refuerza la postura. |
| `read_only: true` | **Activado** + `tmpfs: /tmp` | El binario Dozzle no escribe a disco salvo `/tmp` para uploads efímeros (descarga de logs). `read_only: true` con tmpfs en `/tmp` es lo más restrictivo posible y cabe en el modelo del servicio. |
| Persistencia | **NO** (sin volumes de datos) | Dozzle es stateless: la UI guarda preferencias (tema oscuro, contenedores fijados, búsquedas guardadas) **en `localStorage` del navegador**, no en el servidor. Así, ningún path bajo `/mnt/hd2t/services/monitoring/dozzle/` es necesario. Se elimina el directorio del bootstrap (§3.1). |
| Healthcheck | **`/healthz`** (endpoint upstream) | Dozzle 8 expone `/healthz` que responde 200 con `OK` cuando el HTTP server está listo y la conexión al socket Docker es viable. La imagen oficial es `scratch`-based: trae sólo el binario `dozzle` y `wget` no está disponible. Se usa `dozzle healthcheck` (subcomando del propio binario) que hace exactamente la misma comprobación interna sin depender de utilidades externas. |
| Logs Docker | **`json-file` 10 MB × 3** (heredado del demonio) | Plantilla §6.1 de estructura-compose. Dozzle genera logs muy moderados (uno por sesión de cliente abierta). 30 MB cubren meses. |
| Memoria del contenedor (`mem_limit`) | **`128m`** | Idle <30 MB. Límite duro a 128 MB protege a la Pi de un leak en streams largos (han aparecido en versiones afectadas) y de un pico al cargar el log completo de un contenedor verboso (e.g. `pihole-FTL` con muchas consultas). Si se alcanza, Docker mata el contenedor; al ser stateless, recreate es transparente. |
| `read_only: true` impide `/var/cache` | **No aplica** | Dozzle no usa `/var/cache`. Único path con escritura es `/tmp` (tmpfs). |
| Reverse-proxy en Caddy | **SÍ**, `logs.{$LAN_DOMAIN}` | Hostname corto y memorable. La elección `logs.lan` (en lugar de `dozzle.lan`) imita la convención del resto del homelab (`auth.lan`, `vault.lan`, `uptime.lan`): nombre breve descriptivo del servicio, no del producto. |
| SSE (Server-Sent Events) | **Soportado nativamente por Caddy** | Dozzle usa SSE para enviar el flujo `--follow` al navegador (no WebSockets). Caddy v2 reverse_proxy lo proxy-a sin configuración especial: no buffer-iza por defecto, mantiene la conexión abierta, y reenvía `Cache-Control: no-cache` correctamente. El timeout largo se garantiza explícitamente con `flush_interval -1` (§6.5). |

---

## 1. Resumen de la arquitectura

```
                ┌────────────────────── HOST: Pi 5 (Raspberry Pi OS) ──────────────────────┐
                │                                                                           │
                │  /var/run/docker.sock                                                     │
                │         ▲                                                                 │
                │         │ ro                                                              │
                │         │                                                                 │
                │   ┌─────┼──────────────────── docker network: homelab ─────────────────┐  │
                │   │     │                                                                │  │
                │   │  /var/run/docker.sock  (ro)                                          │  │
                │   │     ▲                                                                │  │
                │   │     │                                                                │  │
                │   │  ┌──┴────────────────── dozzle ──────────────────────────────┐      │  │
                │   │  │ image: amir20/dozzle:v8.13.6                              │      │  │
                │   │  │ user:  1000:1000  +  group_add: ${DOCKER_GID}             │      │  │
                │   │  │ ports: -                                                  │      │  │
                │   │  │ networks: [homelab]                                       │      │  │
                │   │  │ DOZZLE_AUTH_PROVIDER=forward-proxy                        │      │  │
                │   │  │ DOZZLE_AUTH_HEADER_USER=Remote-User                       │      │  │
                │   │  │ DOZZLE_NO_ANALYTICS=true                                  │      │  │
                │   │  │ DOZZLE_ENABLE_ACTIONS=false                               │      │  │
                │   │  │ DOZZLE_ENABLE_SHELL=false                                 │      │  │
                │   │  │ /        — UI (Vue + SSE, :8080)                          │      │  │
                │   │  │ /api/logs/<id> — stream SSE de logs                       │      │  │
                │   │  │ /healthz  — liveness                                      │      │  │
                │   │  │ read_only: true + tmpfs:/tmp                              │      │  │
                │   │  └────────────────────────────▲──────────────────────────────┘      │  │
                │   │                                │                                     │  │
                │   │   ┌───────── caddy ────────────┴──────────────────────────────┐     │  │
                │   │◄──┤ logs.{LAN_DOMAIN}                                         │     │  │
                │   │   │   ├─ tls internal (CA homelab)                            │     │  │
                │   │   │   ├─ forward_auth → http://authelia:9091                  │     │  │
                │   │   │   │     └─ inyecta Remote-User al backend                 │     │  │
                │   │   │   └─ reverse_proxy → http://dozzle:8080                   │     │  │
                │   │   │       (SSE: flush_interval -1, sin buffering)             │     │  │
                │   │   └───────────────────────────────────────────────────────────┘     │  │
                │   │                                                                     │  │
                │   │   ┌─── otros contenedores (logs leídos por Dozzle) ────────┐         │  │
                │   │   │  jellyfin, nextcloud, pihole, sonarr, ...              │         │  │
                │   │   └─────────────────────────────────────────────────────────┘         │  │
                │   │                                                                       │  │
                │   └───────────────────────────────────────────────────────────────────────┘  │
                │                                                                              │
                │   Sin tráfico saliente desde dozzle (DOZZLE_NO_ANALYTICS=true).               │
                │   Los streams de logs viajan: kernel → docker.sock → dozzle → Caddy → cliente │
                └──────────────────────────────────────────────────────────────────────────────┘
```

Cuatro invariantes:

- **Dozzle sólo es accesible desde la red `homelab`**. No hay `ports:` al host. La UI llega vía Caddy + Authelia (`forward_auth`, 2FA + `forward-proxy` auth en Dozzle: una sola sesión, sin doble login).
- **Dozzle no abre conexiones salientes**. `DOZZLE_NO_ANALYTICS=true` desactiva el ping de telemetría. El contenedor sólo lee del socket UNIX local; nada va al router.
- **Dozzle es stateless**. No hay BD, no hay volume de datos, no hay backup específico. Reinstalar Dozzle = `git pull` del repo + `up -d`.
- **Acciones y shell deshabilitadas**. `DOZZLE_ENABLE_ACTIONS=false` y `DOZZLE_ENABLE_SHELL=false`: la UI es **read-only de logs**. Robar la cookie Authelia da acceso a leer logs (sensible) pero no a parar contenedores ni a obtener una shell dentro de ellos.

Flujo de un stream:

```
1. Operador abre https://logs.lan/ en el navegador.
   → Caddy: 302 a https://auth.lan/?rd=https://logs.lan
2. Authelia: TOTP + cookie de sesión.
   → 302 de vuelta a https://logs.lan/.
3. Caddy: forward_auth a authelia:9091/api/verify → 200 con
   Remote-User: homelab, Remote-Groups: admin.
   reverse_proxy a http://dozzle:8080/, inyectando esos headers.
4. Dozzle (DOZZLE_AUTH_PROVIDER=forward-proxy): lee Remote-User=homelab, considera al usuario autenticado.
5. UI lista los contenedores (GET /containers/json del socket Docker).
6. Click en "jellyfin" → frontend abre EventSource en
   GET /api/logs/jellyfin?stdout=1&stderr=1&follow=1.
   Dozzle hace docker logs --follow contra el socket y reenvía cada
   línea como un evento SSE.
7. Caddy proxy-a el SSE con flush_interval -1: cada chunk del backend
   llega al navegador instantáneamente.
8. Cierre de pestaña → EventSource cancelado → docker logs --follow
   cancelado → libera la goroutine en Dozzle.
```

---

## 2. Plan de variables y archivos

El stack `monitoring` ya existe; este doc **extiende** los ficheros que dejaron Prometheus, Grafana, Node Exporter, cAdvisor y Uptime Kuma. Estado del repo después de este doc:

```
~/homelab/stacks/monitoring/             # versionable en git
├── docker-compose.yml                   # +bloque `dozzle:`
├── .env.example                         # +sección Dozzle (última de Fase 5)
├── prometheus.yml                       # SIN cambios
└── grafana/
    ├── grafana.ini                       # SIN cambios
    └── provisioning/
        ├── datasources/prometheus.yml    # SIN cambios
        └── dashboards/
            ├── default.yml               # SIN cambios
            └── json/                      # SIN cambios (Dozzle no exporta métricas)

~/homelab/stacks/proxy/                  # versionable en git
└── Caddyfile                             # +bloque `logs.{$LAN_DOMAIN}`

~/homelab/stacks/auth/                   # versionable en git
└── configuration.yml                     # +entrada `logs.{LAN_DOMAIN}` en access_control.rules

/mnt/hd2t/services/monitoring/           # datos persistentes, NO en git
├── .env                                  # +sección Dozzle
├── prometheus/                           # SIN cambios
├── grafana/data/                         # SIN cambios
├── uptime-kuma/data/                     # SIN cambios
└── dozzle/                               # NO se crea — Dozzle es stateless
```

> Dozzle no tiene carpeta de datos en `/mnt/hd2t/services/monitoring/`: §3.1 elimina el `/mnt/hd2t/services/dozzle/` heredado del bootstrap antiguo y NO crea reemplazo.

### 2.1. Variables del stack — extender `.env.example`

Editar `~/homelab/stacks/monitoring/.env.example` (creado por [`./01-prometheus.md`](./01-prometheus.md) §2.1, ampliado por los docs intermedios) y **descomentar/rellenar** la sección Dozzle. El placeholder `# DOZZLE_IMAGE_TAG=` que dejaron los docs anteriores pasa a ser real:

```dotenv
# ~/homelab/stacks/monitoring/.env.example
# Versión control: ~/homelab/stacks/monitoring/.env.example
# Valores reales en /mnt/hd2t/services/monitoring/.env (chmod 600).

# --- Comunes del homelab ---
PUID=1000
PGID=1000
TZ=Europe/Madrid

# GID del grupo `docker` del host (cat /etc/group | grep docker — típico 998
# en RPi OS Bookworm). Necesario para que el contenedor non-root de Dozzle
# pueda leer /var/run/docker.sock.
DOCKER_GID=998

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
UPTIME_KUMA_IMAGE_TAG=1.23.16-debian
UPTIME_KUMA_HOSTNAME=uptime.lan

# --- Dozzle (./06-dozzle.md) ---
# https://github.com/amir20/dozzle/releases
# Imagen multi-arch (linux/arm64). Pinear el tag; la 8.x mantiene contrato,
# revisar release notes al subir minor por si cambian env vars o
# cabeceras de auth.
DOZZLE_IMAGE_TAG=v8.13.6
DOZZLE_HOSTNAME=logs.lan
# Display name del nodo en la esquina inferior izquierda de la UI.
DOZZLE_NODE_NAME=pi5-homelab
```

> **Nuevo: `DOCKER_GID`**. Se introduce aquí — Dozzle es el primer servicio del stack `monitoring` que necesita acceder al socket Docker como **non-root**. Otros consumidores del socket en este stack: cAdvisor (`privileged: true`) y Uptime Kuma (`user: root`) corren con privilegios elevados y no requieren la variable. Se añade al `.env.example` de `monitoring`; otros stacks (e.g. `proxy` con Watchtower) la consumirán en sus respectivos `.env.example` cuando un servicio non-root del stack lo necesite.

### 2.2. Extender el `.env` real (`/mnt/hd2t/services/monitoring/.env`)

```bash
# Determinar el GID real del grupo docker en este host:
DOCKER_GID="$(getent group docker | cut -d: -f3)"
echo "DOCKER_GID detectado = $DOCKER_GID"
# Esperado en RPi OS Bookworm: 998 (puede variar; el comando lo lee en vivo).

# Añadir las nuevas líneas al .env (sin tocar las existentes de los servicios
# anteriores):
sudo tee -a /mnt/hd2t/services/monitoring/.env >/dev/null <<EOF

# --- Dozzle (./06-dozzle.md) ---
DOCKER_GID=${DOCKER_GID}
DOZZLE_IMAGE_TAG=v8.13.6
DOZZLE_HOSTNAME=logs.lan
DOZZLE_NODE_NAME=pi5-homelab
EOF

# Comprobar permisos (deben seguir siendo 600):
ls -l /mnt/hd2t/services/monitoring/.env
# Esperado: -rw------- 1 homelab homelab ... .env
```

> **No hay secretos** en la sección Dozzle del `.env`: ni passwords, ni tokens. La autenticación se delega completamente a Authelia (sesión gestionada por Caddy + cookie). Por tanto, este `.env` no contiene material sensible nuevo respecto a los docs anteriores.

---

## 3. Preparar el host

### 3.1. Eliminar el directorio del esquema antiguo

El bootstrap original ([`../01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md) §6.6) creó `/mnt/hd2t/services/dozzle/` siguiendo el esquema "un dir por servicio" que el plan ha sustituido por "un dir por stack". A diferencia de Uptime Kuma, **aquí no se migra a un dir nuevo**: Dozzle es stateless, no hay datos que mover. El directorio queda huérfano y se elimina:

```bash
# Confirmar que está vacío (no debería haber datos previos: nadie ha levantado
# Dozzle todavía):
ls -la /mnt/hd2t/services/dozzle/ 2>/dev/null
# Esperado: . y .. solamente; cualquier otra cosa indicaría un experimento
# previo que conviene revisar antes de borrar.

sudo rmdir /mnt/hd2t/services/dozzle 2>/dev/null || true
# El rmdir falla silenciosamente si el directorio no existe; ambos casos OK.

# Verificar que NO existe `/mnt/hd2t/services/monitoring/dozzle/`:
ls -la /mnt/hd2t/services/monitoring/dozzle/ 2>/dev/null ; echo "exit=$?"
# Esperado: 'No such file or directory' + exit=2. Dozzle no necesita
# directorio bajo el stack porque es stateless.
```

> Si el `rmdir` falla con "Directory not empty", revisar el contenido y borrarlo manualmente sólo tras confirmar que no es información que haya que preservar. En un primer despliegue limpio el directorio está vacío.

### 3.2. Verificar el GID del grupo docker

El contenedor de Dozzle correrá como `1000:1000` con `group_add: ${DOCKER_GID}`. Si la variable está mal, el contenedor arranca pero da `permission denied` al leer el socket:

```bash
# Verificar el GID del grupo docker en el host:
getent group docker
# Esperado: docker:x:998:homelab
# El número (998 aquí) debe coincidir con DOCKER_GID en /mnt/hd2t/services/monitoring/.env.

grep ^DOCKER_GID /mnt/hd2t/services/monitoring/.env
# Esperado: DOCKER_GID=998 (o lo que sea el GID real).

# Comprobar que el socket es accesible por ese grupo:
ls -l /var/run/docker.sock
# Esperado: srw-rw---- 1 root docker 0 ... /var/run/docker.sock
# Crítico: el group owner debe ser `docker` y debe permitir lectura/escritura
# por el grupo (rw-).
```

> Si el usuario del homelab no estuviera en el grupo `docker`, `getent group docker` mostraría sólo `docker:x:998:` (sin el usuario). Eso ya se corrigió en [`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md) §4.5 — si por algún motivo se ha revertido, repararlo con `sudo usermod -aG docker homelab && newgrp docker` antes de continuar.

### 3.3. Verificar conectividad interna desde la red homelab

```bash
# DNS interno: el contenedor 'caddy' debe poder resolver 'dozzle' por nombre
# una vez levantado. Hasta entonces, validar que la red homelab existe:
docker network inspect homelab --format '{{.Driver}} {{.IPAM.Config}}'
# Esperado: bridge [{172.20.0.0/24 ...}]

# Verificar que Caddy está sano y puede llegar al stack monitoring:
docker exec caddy getent hosts uptime-kuma
# Esperado: 172.20.0.X uptime-kuma  (resolución correcta del bridge homelab).
# Si esto falla, hay un problema previo de red — resolver antes de continuar.
```

---

## 4. `docker-compose.yml`

Editar `~/homelab/stacks/monitoring/docker-compose.yml` (extendido por todos los docs anteriores de Fase 5) y **añadir** el bloque `dozzle:` debajo del bloque `uptime-kuma:`. **No** se tocan los bloques `prometheus:`, `grafana:`, `node-exporter:`, `cadvisor:`, `uptime-kuma:`, ni el bloque `networks:`.

```yaml
# ~/homelab/stacks/monitoring/docker-compose.yml
# Stack: monitoring (../02-docker/02-estructura-compose.md §1.1).
#
# Estado tras este doc: SEIS servicios (`prometheus`, `grafana`,
# `node-exporter`, `cadvisor`, `uptime-kuma`, `dozzle`).
# Fase 5 COMPLETA. La siguiente fase abre un stack distinto
# (`nextcloud`, ../06-almacenamiento/01-nextcloud.md).

name: monitoring

services:
  prometheus:
    # ... bloque sin cambios; ver ./01-prometheus.md §5 ...

  grafana:
    # ... bloque sin cambios; ver ./02-grafana.md §7 ...

  node-exporter:
    # ... bloque sin cambios; ver ./03-node-exporter.md §5 ...

  cadvisor:
    # ... bloque sin cambios; ver ./04-cadvisor.md §5 ...

  uptime-kuma:
    # ... bloque sin cambios; ver ./05-uptime-kuma.md §5 ...

  dozzle:
    image: amir20/dozzle:${DOZZLE_IMAGE_TAG}
    container_name: dozzle
    hostname: dozzle
    restart: unless-stopped

    # Non-root: la imagen oficial de Dozzle 8.x corre como UID 1000 por defecto.
    # Forzarlo explícito documenta el contrato.
    user: "${PUID}:${PGID}"

    # Para acceder a /var/run/docker.sock (group owner: docker, GID variable
    # según host) el proceso necesita pertenecer a ese GID. group_add lo añade
    # al runtime sin cambiar el UID/GID base.
    group_add:
      - "${DOCKER_GID}"

    # No depende de ningún otro contenedor para arrancar. Si Caddy o Authelia
    # están caídos, Dozzle sigue arrancando; la UI no será accesible vía LAN
    # pero es esperable (sin Caddy no hay HTTPS interno).
    # No depends_on.

    env_file:
      - /mnt/hd2t/services/monitoring/.env
    environment:
      TZ: ${TZ}

      # Display name del nodo en la UI (esquina inferior izquierda).
      DOZZLE_HOSTNAME: ${DOZZLE_NODE_NAME}

      # Nivel de log del propio Dozzle.
      DOZZLE_LEVEL: info

      # Desactivar la telemetría por completo (postura "no fuga" del homelab).
      DOZZLE_NO_ANALYTICS: "true"

      # ─── Auth: delegar al reverse proxy (Authelia + Caddy) ─────────────
      # forward-proxy: Dozzle confía en Caddy para autenticar y lee Remote-User
      # del header inyectado por `import authelia_proxy`. UN SOLO LOGIN.
      DOZZLE_AUTH_PROVIDER: forward-proxy
      DOZZLE_AUTH_HEADER_USER: Remote-User
      DOZZLE_AUTH_HEADER_NAME: Remote-Name

      # ─── Capacidades deshabilitadas (lectura pura) ─────────────────────
      # Nada de start/stop/restart desde la UI: para eso está Portainer.
      DOZZLE_ENABLE_ACTIONS: "false"
      # Nada de shell embebida: shell de contenedores se hace por SSH/Portainer.
      DOZZLE_ENABLE_SHELL: "false"

      # ─── Filtro de contenedores visibles ───────────────────────────────
      # Vacío: todos los contenedores del host son visibles. Variante con
      # filtro por label en §9.1.
      # DOZZLE_FILTER: ""

    volumes:
      # Único bind mount: socket Docker en read-only.
      # Dozzle sólo llama a GET /containers/... y GET /containers/<id>/logs;
      # ro impide que un compromiso de Dozzle haga start/stop/exec.
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
    # Sin cap_add: Dozzle no necesita capabilities; sólo HTTP server interno
    # + lectura de socket UNIX.

    read_only: true
    tmpfs:
      # /tmp es el único path con escritura: Dozzle lo usa para descargas
      # efímeras (botón "Download log" → genera un fichero temporal y lo sirve).
      - /tmp:rw,noexec,nosuid,size=64m

    mem_limit: 128m
    memswap_limit: 128m
    # Sin cpu_quota: Dozzle consume <0,5% en idle; un quota artificial
    # podría frenar el primer load de un contenedor con un backlog grande.

    healthcheck:
      # `dozzle healthcheck` es un subcomando del propio binario que hace una
      # llamada HEAD a localhost:8080/healthz y verifica la conexión al socket.
      # No depende de wget/curl (la imagen es scratch-based).
      test: ["CMD", "/dozzle", "healthcheck"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s

    labels:
      com.centurylinklabs.watchtower.enable: "true"
      homepage.group: "Monitorización"
      homepage.name: "Dozzle"
      homepage.icon: "dozzle.png"
      homepage.href: "https://logs.${LAN_DOMAIN}"
      homepage.description: "Visor de logs en tiempo real"

networks:
  homelab:
    external: true
```

### 4.1. Por qué cada bloque

| Bloque | Por qué |
|---|---|
| `image: amir20/dozzle:${DOZZLE_IMAGE_TAG}` | Tag fijo desde el `.env`. Imagen oficial multi-arch (incluye `linux/arm64`). |
| `container_name: dozzle` / `hostname: dozzle` | Caddy llama a `http://dozzle:8080` por nombre Docker. Sin `container_name` el nombre real sería `monitoring-dozzle-1`. |
| `user: "${PUID}:${PGID}"` | Imagen oficial corre como non-root sin reconstruir. Coherente con la convención `1000:1000` del homelab. |
| `group_add: [${DOCKER_GID}]` | Imprescindible para que un proceso non-root pueda leer el socket Docker (group owner = docker, GID variable según host). Es la pieza que hace posible el "non-root con socket". |
| (sin `depends_on:`) | Dozzle es de operaciones: debe arrancar incluso si el resto del stack está caído. Sin Caddy la UI no es accesible vía `logs.lan`, pero el contenedor está sano y el operador puede levantar Caddy y refrescar. |
| `env_file` ruta absoluta | Plantilla §6 de estructura-compose. Coherente con el resto del stack. |
| `environment.TZ` | Timestamps correctos en los logs propios de Dozzle. Los timestamps de los **contenedores observados** vienen del log original del contenedor, no se reescriben. |
| `environment.DOZZLE_HOSTNAME` | Display name del nodo en la UI. Útil ahora (un solo nodo) y crítico cuando se enrolen agentes remotos (§9.4). |
| `environment.DOZZLE_LEVEL: info` | Default. Se sube a `debug` puntualmente para diagnosticar problemas de SSE o de auth (§9.2). |
| `environment.DOZZLE_NO_ANALYTICS: "true"` | Desactiva el ping de telemetría a `stats.dozzle.dev`. Postura "no fuga" del homelab. |
| `environment.DOZZLE_AUTH_PROVIDER: forward-proxy` | La pieza clave del modelo single-sign-on con Authelia. Sin esto, Dozzle querría su propio login (`simple` / `none`) y se rompería la cohesión del homelab. |
| `environment.DOZZLE_AUTH_HEADER_USER: Remote-User` | Header que Authelia + Caddy inyectan con la identidad del usuario autenticado. Coincide con el contrato de [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §9.1. |
| `environment.DOZZLE_AUTH_HEADER_NAME: Remote-Name` | Display name del usuario, también enviado por Authelia. Aparece en la esquina superior derecha de la UI. |
| `environment.DOZZLE_ENABLE_ACTIONS: "false"` | Mantiene Dozzle como **read-only de logs**. Reduce el blast-radius si la cookie Authelia se filtra. |
| `environment.DOZZLE_ENABLE_SHELL: "false"` | Misma razón: nada de RCE en contenedores desde un navegador. |
| `volumes: /var/run/docker.sock:ro` | Imprescindible y único bind mount. Read-only acota a `GET /containers/...` y `GET /containers/<id>/logs?follow=1` — la API Docker rechaza POST/DELETE sobre socket ro. |
| `networks: [homelab]` | Único networking. Resuelve por DNS interno del bridge. No se usa `network_mode: host`: rompería DNS interno y expondría `:8080` al LAN. |
| `security_opt: no-new-privileges:true` | Plantilla §6.1 de estructura-compose. |
| `cap_drop: [ALL]` | Sin capabilities. Justificado en §0. |
| `read_only: true` + `tmpfs:/tmp` | El binario Dozzle no necesita escribir al FS root. `/tmp` para uploads efímeros (descargas de logs) en tmpfs (RAM, no disco). Postura más restrictiva posible. |
| `mem_limit: 128m` / `memswap_limit: 128m` | Idle <30 MB. Límite duro a 128 MB protege a la Pi de un leak en streams largos; al ser stateless, recreate es transparente. |
| `healthcheck: /dozzle healthcheck` | Subcomando del propio binario. La imagen oficial es scratch (sin wget/curl). `start_period: 15s` cubre el arranque + primer query a `/containers/json`. |
| `labels.watchtower.enable=true` | Justificado en la tabla §0. |
| `labels.homepage.*` | Auto-descubrimiento por Homepage ([`../12-dashboards/01-homepage.md`](../12-dashboards/01-homepage.md)). |

### 4.2. Validar antes de levantar

```bash
cd ~/homelab/stacks/monitoring

# Validar sintaxis del compose (debe expandir todas las variables del .env):
docker compose --env-file /mnt/hd2t/services/monitoring/.env config >/dev/null \
  && echo "Compose OK"

# Inspeccionar el bloque de dozzle:
docker compose --env-file /mnt/hd2t/services/monitoring/.env config \
  | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
dz = d["services"]["dozzle"]
print("IMAGE:", dz.get("image"))
print("USER:", dz.get("user"))
print("GROUP_ADD:", dz.get("group_add"))
print("NETWORKS:", list(dz.get("networks", {}).keys()) if isinstance(dz.get("networks"), dict) else dz.get("networks"))
print("MEM_LIMIT:", dz.get("mem_limit"))
print("READ_ONLY:", dz.get("read_only"))
print("TMPFS:", dz.get("tmpfs"))
print("PORTS:", dz.get("ports"))
print("CAP_DROP:", dz.get("cap_drop"))
print("ENV (auth):")
for k in ("DOZZLE_AUTH_PROVIDER", "DOZZLE_AUTH_HEADER_USER", "DOZZLE_ENABLE_ACTIONS", "DOZZLE_ENABLE_SHELL", "DOZZLE_NO_ANALYTICS"):
    print(" ", k, "=", dz.get("environment", {}).get(k))
print("VOLUMES:")
for v in dz.get("volumes", []):
    print(" -", v)
print("LABELS:", dz.get("labels"))
'
# Esperado:
#   IMAGE: amir20/dozzle:v8.13.6
#   USER: 1000:1000
#   GROUP_ADD: ['998']
#   NETWORKS: ['homelab']
#   MEM_LIMIT: 134217728
#   READ_ONLY: True
#   TMPFS: ['/tmp:rw,noexec,nosuid,size=64m']
#   PORTS: None
#   CAP_DROP: ['ALL']
#   ENV (auth):
#     DOZZLE_AUTH_PROVIDER = forward-proxy
#     DOZZLE_AUTH_HEADER_USER = Remote-User
#     DOZZLE_ENABLE_ACTIONS = false
#     DOZZLE_ENABLE_SHELL = false
#     DOZZLE_NO_ANALYTICS = true
#   VOLUMES: 1 entrada (docker.sock ro)
```

> Si `compose config` emite "warning: variable DOCKER_GID not set", el `.env` no tiene la variable. Repetir §2.2 con `getent group docker`.

---

## 5. Despliegue

### 5.1. Levantar el contenedor

```bash
cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d dozzle
```

Salida esperada:

```
[+] Running 1/1
 ✔ Container dozzle  Started
```

> **Sólo se levanta `dozzle`** (`up -d dozzle`): los otros cinco servicios ya están corriendo y no necesitan recreate. La adición del bloque `dozzle:` no toca los servicios anteriores ni la red `homelab` (que es `external`, definida en estructura-compose).

### 5.2. Estado del contenedor

```bash
docker compose ps dozzle
# Esperado tras ~15s:
# NAME    IMAGE                    STATUS                  PORTS
# dozzle  amir20/dozzle:v8.13.6    Up X (healthy)
```

Si tarda en `(healthy)` o entra en `(unhealthy)`:

```bash
docker compose logs dozzle | tail -50
```

Eventos esperados en los logs del primer arranque:

```
INF Dozzle version v8.13.6
INF Reading configuration from environment
INF Authentication: forward-proxy enabled
INF Listening on :8080
INF Connected to Docker daemon, found N containers
```

> "found N containers": confirma que el bind ro del socket funciona. Si en su lugar aparece `permission denied` accediendo al socket, el `group_add` no está aplicado correctamente — verificar §3.2.

### 5.3. Smoke test desde la red `homelab`

```bash
# Desde otro contenedor del bridge homelab (caddy es la mejor herramienta):
docker exec caddy wget -qO- -S http://dozzle:8080/ 2>&1 | head -10
# Esperado: HTTP/1.1 200 OK + cabeceras + HTML del SPA Dozzle.
# El HTML incluirá un meta-refresh / un script que arranca Vue.

# Healthcheck endpoint:
docker exec caddy wget -qO- -S http://dozzle:8080/healthz 2>&1 | head -5
# Esperado: HTTP/1.1 200 OK + 'OK' (texto plano).

# Comprobar que la API ve los contenedores:
docker exec caddy wget -qO- 'http://dozzle:8080/api/containers' 2>&1 | python3 -c 'import sys, json; d=json.load(sys.stdin); print(f"containers visibles: {len(d)}")'
# Esperado: containers visibles: 6+ (los del stack monitoring + caddy/authelia/pihole/...).
# Si es 0, el socket no es accesible (revisar group_add) o el token de auth
# no se está pasando — ver §10.
```

> **Importante**: las llamadas HTTP a `/api/containers` desde dentro del bridge **sin pasar por Caddy** **no llevan headers Authelia**. Con `DOZZLE_AUTH_PROVIDER=forward-proxy`, Dozzle por defecto **rechaza** peticiones sin `Remote-User`. Si la llamada anterior devuelve 401, eso es **correcto** — la autorización funciona; la verificación se hace luego desde el navegador con Authelia delante (§6).
>
> Para diagnosticar el contenedor sin pasar por Caddy, simular el header:
> ```bash
> docker exec caddy wget -qO- --header="Remote-User: homelab" \
>   --header="Remote-Name: homelab" \
>   --header="Remote-Groups: admin" \
>   'http://dozzle:8080/api/containers' | head -c 500
> # Esperado: JSON con la lista de contenedores.
> ```

### 5.4. Smoke test desde el host

```bash
# Dozzle NO debe ser alcanzable desde la IP del host:
curl -sf http://192.168.1.10:8080/ -m 2 ; echo "exit=$?"
# Esperado: exit=7 (connection refused). Nunca 200.

docker port dozzle
# Esperado: vacío (sin port mappings).

# Confirmar también que el host no escucha en :8080:
sudo ss -ltn '( sport = :8080 )' | tail -n +2
# Esperado: línea vacía. Si aparece *:8080 LISTEN, hay un `ports:` mal puesto
# o un servicio del host (cAdvisor publicado por error, etc.).
```

---

## 6. Integración con Caddy + Authelia (`forward_auth`)

Dozzle requiere `forward_auth` desde el primer momento porque su `DOZZLE_AUTH_PROVIDER=forward-proxy` rechaza peticiones sin `Remote-User`. A diferencia del flujo de Uptime Kuma (donde se hace una "ventana corta sin forward_auth" para crear el admin local), aquí no hay admin que crear — todo el control de acceso vive en Authelia. El bloque `Caddyfile` se añade ya con `import authelia_proxy` desde el principio.

### 6.1. Bloque en el `Caddyfile`

Editar `~/homelab/stacks/proxy/Caddyfile` y añadir, **debajo** del bloque `uptime.{$LAN_DOMAIN}`:

```caddy
# Dozzle (../05-monitorizacion/06-dozzle.md)
logs.{$LAN_DOMAIN} {
    import lan_internal_tls
    import security_headers
    import authelia_proxy

    reverse_proxy http://dozzle:8080 {
        header_up Host {host}
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {remote_host}

        # SSE: streams largos sin bufferizar (cada chunk del backend se
        # entrega al cliente al instante). flush_interval -1 desactiva
        # el buffer y mantiene Caddy en modo "proxy transparente".
        flush_interval -1

        # Sin transport_timeout: el flujo de logs puede mantenerse abierto
        # horas. Caddy por defecto NO cierra streams idle.
    }
}
```

Razones:

- **`import authelia_proxy`** aplica el `forward_auth` definido en [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §9.1. Cualquier petición sin sesión Authelia válida será redirigida a `https://auth.lan` (302). Tras login, los headers `Remote-User`, `Remote-Name`, `Remote-Groups`, `Remote-Email` se inyectan al backend, y Dozzle (`forward-proxy`) los acepta.
- **`flush_interval -1`** es la pieza crítica para SSE. Sin ella, Caddy bufferiza la respuesta y el navegador tarda decenas de segundos en ver la primera línea de log. Documentado en [Caddy reverse_proxy → flush_interval](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#flush_interval).
- **`Host {host}`** preserva `logs.lan` como Host visto por Dozzle. Dozzle 8 no genera URLs absolutas dependientes del Host, pero hacerlo explícito mantiene la coherencia con el resto de hosts y evita sorpresas si una versión futura sí las generara.
- **`X-Real-IP {remote_host}`** y **`X-Forwarded-Proto https`** son los headers estándar de proxy. Dozzle los registra en sus propios logs (cuando `DOZZLE_LEVEL=debug`).

### 6.2. Registro DNS local en Pi-hole

Pi-hole UI → **Local DNS** → **DNS Records** → añadir:

```
logs.lan → 192.168.1.10
```

Reload del DNS interno:

```bash
docker exec pihole pihole reloaddns
```

Verificar:

```bash
dig +short @192.168.1.241 logs.lan
# Esperado: 192.168.1.10
```

### 6.3. Recargar Caddy

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
# Esperado: Valid configuration.

docker exec caddy caddy reload --config /etc/caddy/Caddyfile
# Esperado: salida vacía y exit code 0.
```

### 6.4. Añadir la regla en Authelia (`access_control.rules`)

Editar `~/homelab/stacks/auth/configuration.yml` (sección `access_control.rules`, ya documentada en [`../04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md) §5) y **añadir** `logs.lan` a la lista de servicios protegidos por 2FA:

```yaml
access_control:
  default_policy: deny
  rules:
    # ... reglas existentes ...

    # Servicios protegidos por 2FA (ampliado con logs.lan).
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
        - "uptime.{{ env "LAN_DOMAIN" }}"
        - "logs.{{ env "LAN_DOMAIN" }}"        # <── nuevo
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

### 6.5. Verificar el SSO end-to-end

1. **Cerrar sesión** en `https://auth.lan/logout` (si la había).
2. Abrir `https://logs.lan/`. Esperado: redirección a `https://auth.lan/?rd=https%3A%2F%2Flogs.lan%2F` con un cuadro de login.
3. Autenticar con usuario + TOTP. Tras el segundo factor, redirección a `https://logs.lan/`.
4. Aparece la UI de Dozzle directamente en la lista de contenedores — **sin** segundo login propio (a diferencia de Uptime Kuma). En la esquina superior derecha aparece el nombre `homelab` (lo inyectado por `Remote-Name`).
5. Click en cualquier contenedor: aparece el flujo de logs en tiempo real. Si hay un proceso emitiendo (Pi-hole, Caddy con tráfico), las líneas nuevas aparecen al instante (~100 ms).

> **Por qué Dozzle SÍ tiene SSO real con Authelia (a diferencia de Uptime Kuma)**: Dozzle 6+ implementó el provider `forward-proxy` específicamente para integraciones tipo Authelia/Authentik/oauth2-proxy. Acepta el `Remote-User` como identidad final sin pedir nada más. Uptime Kuma 1.x mantiene su propio sistema de usuarios y no admite headers externos (issue [#3544](https://github.com/louislam/uptime-kuma/issues/3544); pendiente para 2.x). Dozzle se beneficia del modelo más moderno.

### 6.6. Comportamiento esperado tras cerrar pestaña / 2FA grace

Una vez autenticado, la cookie de sesión Authelia (default 1h, con `Remember me` 30d) es lo único que mantiene el acceso. Si el operador cierra todas las pestañas y vuelve dentro del periodo, abre `logs.lan` y entra directo (sin pedir TOTP). Caducada la cookie, vuelve el flujo del paso 2.

> **No hay "logout de Dozzle"**: la UI no expone un botón de cerrar sesión porque la sesión es de Authelia. Para cerrar la sesión, ir a `https://auth.lan/logout`.

---

## 7. Verificación

### 7.1. Contenedor sano

```bash
docker inspect dozzle --format '{{.State.Status}} / {{.State.Health.Status}}'
# Esperado: running / healthy
```

### 7.2. Dozzle no escucha en el host

```bash
sudo ss -ltn | grep -E ':8080' || echo "OK: nada en :8080 del host"
docker port dozzle
# Esperado: ambos vacíos.
```

### 7.3. Dozzle ve los contenedores del host

Desde la UI: la lista lateral debe mostrar todos los contenedores del homelab agrupados por `com.docker.compose.project` (stack). Por API (con header simulado):

```bash
docker exec caddy wget -qO- --header="Remote-User: homelab" \
  --header="Remote-Name: homelab" \
  --header="Remote-Groups: admin" \
  'http://dozzle:8080/api/containers' \
  | python3 -c 'import sys, json; cs=json.load(sys.stdin); print(f"total={len(cs)}"); print("muestra:", [c.get("name") for c in cs[:5]])'
# Esperado: total=N (≥6, los del monitoring + caddy/authelia/pihole/portainer/...);
# muestra con nombres de contenedores reales.
```

### 7.4. SSE funciona detrás de Caddy

Desde el navegador: abrir un contenedor activo (e.g. `caddy`) y comprobar que aparecen líneas nuevas a medida que se hacen peticiones a otros hosts del homelab. La latencia entre que ocurre el evento y aparece en pantalla debe ser <500 ms.

Verificación por línea de comandos:

```bash
# Suscribirse al stream SSE de logs de pihole, vía Caddy, con sesión Authelia.
# (Necesita una sesión válida; ejecutar tras login en el navegador).
# Una manera simple: mirar headers de respuesta para confirmar SSE:
curl -ks https://logs.lan/api/logs/pihole?stdout=1\&stderr=1 \
  -H "Accept: text/event-stream" \
  -H "Cookie: authelia_session=<COPIAR_DE_DEVTOOLS>" \
  -m 5 | head -20
# Esperado: cabecera 'Content-Type: text/event-stream' + líneas
# `data: ...` con eventos SSE en JSON. Si la sesión es válida, llegan logs;
# si no, 302 a /auth.lan.
```

> En la práctica el operador no usará curl: la verificación normal es abrir la UI y ver líneas llegando. Esta sección es para diagnóstico cuando "la UI muestra el contenedor pero no llegan logs".

### 7.5. Acciones y shell deshabilitadas

En la UI de Dozzle, al abrir un contenedor:

- **No** debe aparecer botón "Restart container" / "Stop container" en la esquina superior derecha del panel de logs.
- **No** debe aparecer pestaña "Shell" / "Exec".

Si aparecen, el `DOZZLE_ENABLE_ACTIONS` o `DOZZLE_ENABLE_SHELL` están a `true`. Revisar §4.

### 7.6. Persistencia tras reboot

Como Dozzle es stateless, "persistencia" aquí significa: la UI sigue siendo accesible y muestra los contenedores tras un reboot. El contenedor levanta automáticamente con `restart: unless-stopped`.

```bash
sudo systemctl reboot
# Esperar a que la Pi vuelva, hacer SSH, y:
docker ps --filter name=dozzle --format '{{.Names}} {{.Status}}'
# Esperado: dozzle Up X (healthy).

# La UI ya debe estar accesible:
curl -ks https://logs.lan/healthz | head -3
# Esperado: 'OK' (con la cookie Authelia, redirige a auth.lan; sin cookie, 302).
```

### 7.7. Headers Authelia llegan al backend

Diagnóstico: capturar lo que ve Dozzle. Subir log level temporalmente a `debug` (§9.2) y abrir la UI. En los logs de Dozzle deben aparecer líneas como:

```
DBG Authenticated user="homelab" name="homelab" groups="admin"
```

> Sin esa línea, Authelia no está enviando `Remote-User` o el `Caddyfile` no usa `import authelia_proxy`. Revisar [`../03-red/04-caddy.md`](../03-red/04-caddy.md) §6 (definición del snippet) y la regla `access_control` de §6.4.

### 7.8. Lista de Verificación

Antes de considerar la Fase 5 cerrada:

- [ ] `docker compose ps dozzle` → `Up X (healthy)`.
- [ ] `sudo ss -ltn | grep -E ':8080'` → vacío en el host.
- [ ] `dig +short @192.168.1.241 logs.lan` → `192.168.1.10`.
- [ ] `https://logs.lan/` → redirige a Authelia.
- [ ] Tras autenticar, la UI muestra ≥6 contenedores.
- [ ] Click en un contenedor activo (caddy, pihole) → aparecen líneas en tiempo real.
- [ ] La UI **no** muestra botones "Restart" ni pestaña "Shell".
- [ ] Tras reboot, `dozzle` arranca solo y la UI vuelve a estar accesible.
- [ ] `docker compose -f ~/homelab/stacks/monitoring/docker-compose.yml ps` → seis servicios `(healthy)`: prometheus, grafana, node-exporter, cadvisor, uptime-kuma, dozzle.
- [ ] `~/homelab` está commiteado y pushed: `cd ~/homelab && git status` → "nothing to commit, working tree clean".

Con esto **Fase 5 (Monitorización y Observabilidad)** queda completa. La siguiente fase es [`../06-almacenamiento/01-nextcloud.md`](../06-almacenamiento/01-nextcloud.md).

---

## 8. Backup

| Ruta | Qué contiene | Frecuencia |
|---|---|---|
| `~/homelab/stacks/monitoring/docker-compose.yml` (bloque `dozzle:`) | Definición del servicio. | Versionado en git → `git push`. |
| `~/homelab/stacks/monitoring/.env.example` (sección Dozzle) | Plantilla de variables. | Versionado en git. |
| `~/homelab/stacks/proxy/Caddyfile` (bloque `logs.lan`) | Reverse proxy + forward_auth + SSE. | Versionado en git. |
| `~/homelab/stacks/auth/configuration.yml` (entrada `logs.lan`) | Regla Authelia. | Versionado en git. |
| `/mnt/hd2t/services/monitoring/.env` (`DOZZLE_*`, `DOCKER_GID`) | Tag de imagen + hostname + GID docker. Sin secretos. | Borg con cifrado en repo (junto al resto de variables del stack, [`./01-prometheus.md`](./01-prometheus.md) §9). |

**Sin estado persistente**. Dozzle no almacena nada: no hay BD, no hay configuración runtime, no hay sesiones. La única "configuración del usuario" (tema oscuro, contenedores fijados, búsquedas guardadas) vive en `localStorage` del navegador del operador y se sincroniza por dispositivo, **no se respalda**. Si se pierde el navegador, basta con re-fijar contenedores favoritos.

**Restore tras pérdida total**: clonar `~/homelab` desde git → `docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d dozzle` → `https://logs.lan/` ya está. No hay paso "restaurar BD".

---

## 9. Operaciones cotidianas

### 9.1. (Variante) Filtrar contenedores con `DOZZLE_FILTER`

Si en algún momento se quiere ocultar contenedores ruidosos (e.g. `mariadb` con queries verbosas) o restringir la vista por stack, descomentar `DOZZLE_FILTER` en el bloque `environment:`:

```yaml
    environment:
      # ...
      # Mostrar SOLO contenedores con label dozzle.show=true
      DOZZLE_FILTER: "label=dozzle.show=true"
```

Y etiquetar los relevantes en sus respectivos compose:

```yaml
  jellyfin:
    # ...
    labels:
      dozzle.show: "true"
```

Recrear Dozzle (`up -d --force-recreate dozzle`) y refrescar la UI: la lista lateral sólo mostrará los contenedores etiquetados.

> Para el homelab inicial **NO** se aplica el filtro: el operador es admin y quiere ver todo. Documentado por completitud para cuando se enrole un usuario "lectura sólo logs Jellyfin" (rol futuro).

### 9.2. Subir el nivel de log para troubleshooting

Para diagnosticar problemas de auth (los headers Authelia no llegan), de SSE (los streams se quedan vacíos) o de socket (lista de containers vacía):

```bash
# Editar /mnt/hd2t/services/monitoring/.env (cambio temporal):
sudo sed -i 's|^DOZZLE_LEVEL=.*|DOZZLE_LEVEL=debug|' \
  /mnt/hd2t/services/monitoring/.env
# (Si la variable no existe, añadirla:
#   echo 'DOZZLE_LEVEL=debug' | sudo tee -a /mnt/hd2t/services/monitoring/.env)

# Y añadir DOZZLE_LEVEL: ${DOZZLE_LEVEL:-info} al bloque environment del
# compose si no estaba (en este doc se introdujo como literal "info"; para
# hacerlo configurable se sustituye por la variable).

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate dozzle

# Reproducir el problema desde la UI, capturar logs:
docker compose logs dozzle --tail 200

# Volver a info al terminar:
sudo sed -i 's|^DOZZLE_LEVEL=.*|DOZZLE_LEVEL=info|' \
  /mnt/hd2t/services/monitoring/.env
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate dozzle
```

Eventos típicos en `debug`:

```
DBG Request method=GET path=/api/containers user=homelab
DBG Authenticated user="homelab" groups="admin"
DBG Streaming logs container=jellyfin since=0 until=0
DBG Connection closed for /api/logs/jellyfin
```

### 9.3. Upgrade manual

```bash
# Antes de cambiar el tag, leer:
# https://github.com/amir20/dozzle/releases
# (busca breaking changes en cada minor: env vars renombradas,
# cambio de cabeceras de auth, cambio de DOZZLE_BASE behavior).

sudo sed -i 's|^DOZZLE_IMAGE_TAG=.*|DOZZLE_IMAGE_TAG=v8.14.0|' \
  /mnt/hd2t/services/monitoring/.env

cd ~/homelab/stacks/monitoring
docker compose --env-file /mnt/hd2t/services/monitoring/.env pull dozzle
docker compose --env-file /mnt/hd2t/services/monitoring/.env up -d --force-recreate dozzle

# Verificar:
docker compose ps dozzle
docker compose logs dozzle --tail 30
# Esperado: 'Dozzle version v8.14.0' + 'Listening on :8080' + 'forward-proxy enabled'.
```

> Watchtower **sí** actualiza Dozzle automáticamente a las 04:00 si el tag pinneado tiene una nueva digest (caso típico: parche de seguridad dentro del mismo `v8.13.6`). Para minors (8.13 → 8.14) y majors el upgrade manual permite ver el changelog. Como Dozzle es stateless, un downgrade tras upgrade fallido es trivial: cambiar el tag al anterior y `up -d --force-recreate dozzle`.

### 9.4. (Variante futura) Modo agente para multi-host

Dozzle 8.x introduce un modo "agente" que permite enrolar nodos remotos. El nodo central (en este homelab, la Pi 5) muestra los logs de todos en una sola UI. El homelab actual es **single-node** y no necesita este modo, pero queda documentado para cuando se enrole un segundo nodo (e.g. una Pi Zero 2W como bastión Tailscale, o un NAS aparte):

1. **En el nodo remoto** (e.g. `nas.lan`): desplegar `dozzle-agent`:
   ```yaml
     dozzle-agent:
       image: amir20/dozzle:${DOZZLE_IMAGE_TAG}
       command: agent
       container_name: dozzle-agent
       restart: unless-stopped
       volumes:
         - /var/run/docker.sock:/var/run/docker.sock:ro
       ports:
         - "7007:7007"   # Puerto del agent (mTLS)
       environment:
         DOZZLE_HOSTNAME: nas
       # ... cap_drop, security_opt, etc. iguales al servicio normal ...
   ```
2. **En la Pi 5**: añadir al bloque `dozzle:` el remote endpoint:
   ```yaml
       environment:
         # ... existentes ...
         DOZZLE_REMOTE_AGENT: "nas.lan:7007"
   ```
3. Recrear `dozzle` y refrescar la UI: la lista lateral ahora tiene un selector de host arriba (`pi5-homelab` / `nas`).

> El protocolo del agente usa mTLS (certs autogenerados al primer arranque del agente, distribuidos al servidor). Para un homelab con dos nodos en LAN privada, el modelo es razonable. **Estado actual del homelab**: single-node — no se enrola ningún agente.

### 9.5. (Variante futura) Sustituir el bind del socket Docker por `docker-socket-proxy`

Si una auditoría exige no exponer `/var/run/docker.sock` directamente al contenedor (mismo análisis que para Uptime Kuma, [`./05-uptime-kuma.md`](./05-uptime-kuma.md) §12.7), se intercala un proxy lectura-only que sólo expone los endpoints que Dozzle necesita:

```yaml
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:0.3
    container_name: docker-socket-proxy
    restart: unless-stopped
    environment:
      CONTAINERS: "1"   # /containers/json y /containers/<id>/json
      INFO: "1"         # /info (system info)
      VERSION: "1"      # /version
      EVENTS: "1"       # /events (notificación de start/stop de containers)
      PING: "1"         # /_ping (healthcheck)
      # /containers/<id>/logs requiere CONTAINERS=1 (parte del scope).
      # Resto a 0 (POST/DELETE quedan negados).
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

  dozzle:
    # ... resto sin cambios excepto:
    environment:
      # ... existentes ...
      DOCKER_HOST: "tcp://docker-socket-proxy:2375"
    volumes:
      # Eliminar el bind directo de docker.sock; ya no se monta.
      # Dozzle hablará TCP con docker-socket-proxy.
      []
    user: "${PUID}:${PGID}"
    # group_add ya NO es necesario (no hay socket UNIX de por medio).
```

Recrear ambos contenedores. La UI debe seguir mostrando logs en directo: el proxy reenvía `/containers/<id>/logs?follow=1` igual que el socket directo.

> **Estado actual**: el homelab inicial usa el bind directo (igual que Uptime Kuma y cAdvisor). El docker-socket-proxy se introducirá si en el futuro se decide unificarlo en una pasada de hardening — coordinado entre los tres consumidores del socket en el stack `monitoring`.

---

## 10. Solución de Problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `docker compose up dozzle` falla con `network homelab declared as external, but could not be found` | La red `homelab` no está creada. | Crearla según [`../02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md) §4.2. |
| `docker compose up dozzle` falla con `unknown flag: --group_add` | Compose v1 instalado en lugar de v2. | Verificar `docker compose version` (no `docker-compose`). Reinstalar plugin v2 ([`../02-docker/01-instalacion-docker.md`](../02-docker/01-instalacion-docker.md) §4.2). |
| `dozzle` arranca pero queda `(unhealthy)` | El healthcheck `/dozzle healthcheck` falla porque `start_period` es muy corto en una Pi 5 saturada. | `docker logs dozzle --tail 30` para confirmar que el server escucha. Si sí, subir `start_period: 30s` y recrear. |
| Logs de Dozzle muestran `permission denied: /var/run/docker.sock` | El UID 1000 no está en el GID `docker`; o `DOCKER_GID` está mal en el `.env`. | `getent group docker` para conocer el GID real, ajustar `DOCKER_GID` en `/mnt/hd2t/services/monitoring/.env` y recrear. Verificar que el socket es `srw-rw---- root docker` (`ls -l /var/run/docker.sock`). |
| Logs de Dozzle muestran `dial unix /var/run/docker.sock: connect: no such file or directory` | El bind mount no se hizo (Compose error) o el socket no existe (Docker Desktop, modo rootless). | `docker exec dozzle ls -la /var/run/docker.sock` debe mostrar `srw-rw----`. Si no, revisar el bloque `volumes:` del compose. |
| `https://logs.lan/` devuelve `502 Bad Gateway` | Caddy no resuelve `dozzle` por DNS interno (red distinta) o el contenedor está en `(unhealthy)`. | `docker exec caddy getent hosts dozzle` debe responder con una IP `172.20.0.X`. Si no, verificar que Dozzle está en la red `homelab` (`docker inspect dozzle --format '{{json .NetworkSettings.Networks}}'`). |
| `https://logs.lan/` redirige a `auth.lan` y tras login devuelve `401 Unauthorized` | Authelia no está enviando `Remote-User` o el `Caddyfile` no usa `import authelia_proxy` para `logs.lan`. | Subir `DOZZLE_LEVEL=debug` (§9.2) y mirar logs: si no aparece "Authenticated user=...", el header no llega. Revisar el snippet `authelia_proxy` en `~/homelab/stacks/proxy/Caddyfile` y la regla en `~/homelab/stacks/auth/configuration.yml`. |
| La UI de Dozzle muestra "no containers found" | El socket es accesible pero la API devuelve 0 (raro: implicaría que no hay contenedores corriendo). | Verificar desde el host: `docker ps`. Verificar desde dentro: `docker exec dozzle wget -qO- --header="Remote-User: homelab" http://localhost:8080/api/containers`. Si la primera lista contenedores y la segunda no, el socket no es accesible (volver a §3.2). |
| La UI muestra contenedores pero al abrir uno los logs no llegan (spinner infinito) | SSE bufferizado por Caddy o por un proxy intermedio. | Verificar `flush_interval -1` en el `Caddyfile` (§6.1). En la consola del navegador (F12 → Network → tipo "EventStream"), la conexión a `/api/logs/<id>` debe quedar abierta con `Content-Type: text/event-stream`. Si en vez de eso aparece `text/html`, el `forward_auth` está rechazando la petición. |
| La UI muestra el botón "Restart container" cuando no debería | `DOZZLE_ENABLE_ACTIONS` está a `true` por error (variable de entorno residual de un experimento). | `docker exec dozzle env | grep DOZZLE_ENABLE_ACTIONS` debe mostrar `false`. Si está `true`, corregir el compose y `up -d --force-recreate dozzle`. |
| La UI muestra una pestaña "Shell" / "Exec" | `DOZZLE_ENABLE_SHELL=true`. | Idem: verificar y corregir. **Crítico**: una shell embebida + cookie Authelia robada = RCE en cualquier contenedor. |
| Tras reboot, la UI carga pero "no containers found" durante varios minutos | Dozzle arranca antes de que el demonio Docker termine de listar contenedores tras el reboot. | Esperar 30–60 s y refrescar. Si persiste, revisar dependencias del compose (no se usa `depends_on` adrede; el restart automático eventualmente hace su trabajo). |
| `docker logs dozzle` muestra `analytics.dozzle.dev: dial tcp: lookup ... no such host` | `DOZZLE_NO_ANALYTICS` no se aplicó (variable mal escrita). | Verificar que es `DOZZLE_NO_ANALYTICS=true` (no `DOZZLE_ANALYTICS=false`, que no existe) y recrear. |
| El nodo aparece como "default" en lugar de `pi5-homelab` | `DOZZLE_HOSTNAME` no se está pasando (la variable del entorno no se expande). | `docker exec dozzle env | grep DOZZLE_HOSTNAME`. Si vacío, revisar que `${DOZZLE_NODE_NAME}` está definido en `/mnt/hd2t/services/monitoring/.env`. |
| Los timestamps de los logs aparecen en UTC en lugar de Europe/Madrid | El **contenedor observado** tiene su propia TZ (no la de Dozzle). Dozzle no reescribe timestamps. | Asegurar que cada contenedor del homelab tiene `TZ: ${TZ}` en su `environment:` (convención del homelab). Dozzle muestra los timestamps tal como vienen en el log original. |

---

## Referencias

- [Dozzle — Repo y CHANGELOG (GitHub)](https://github.com/amir20/dozzle)
- [Dozzle — Imagen Docker oficial (Docker Hub)](https://hub.docker.com/r/amir20/dozzle)
- [Dozzle — Documentación oficial](https://dozzle.dev/)
- [Dozzle — Auth Provider `forward-proxy`](https://dozzle.dev/guide/forward-proxy)
- [Dozzle — Variables de entorno](https://dozzle.dev/guide/environment-variables)
- [Dozzle — Modo agente multi-host](https://dozzle.dev/guide/agent)
- [Caddy — `reverse_proxy` con SSE / `flush_interval`](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#flush_interval)
- [Authelia — `forward_auth` con Caddy y headers `Remote-*`](https://www.authelia.com/integration/proxies/caddy/)
- [Docker — API: `GET /containers/{id}/logs?follow=1`](https://docs.docker.com/engine/api/v1.43/#tag/Container/operation/ContainerLogs)
- [tecnativa/docker-socket-proxy — Read-only proxy del socket Docker (variante futura §9.5)](https://github.com/Tecnativa/docker-socket-proxy)
