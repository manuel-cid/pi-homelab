# Dozzle (visor de _logs_ de contenedores en tiempo real)

## Descripción

Despliegue de **Dozzle** como **visor web de _logs_** de los contenedores Docker del homelab: una UI que abre un _streaming_ persistente del `stdout`/`stderr` de cada contenedor, los pinta en tiempo real con _colorize_, _search_/_highlight_ por _regex_ y `Shift+F` (_fuzzy_), y permite saltar entre contenedores con un teclado tipo _terminal_. Es el complemento _humano_ de la cadena de observabilidad de la fase 5: donde Prometheus + Grafana (`docs/05-monitorizacion/01-prometheus.md`, `02-grafana.md`) responden "_¿cómo_ está rindiendo?", Uptime Kuma (`docs/05-monitorizacion/05-uptime-kuma.md`) responde "_¿está_ arriba?", y Dozzle responde "_¿qué_ está diciendo en sus logs ahora mismo?". Es el sustituto _ergonómico_ de `ssh pi && docker logs -f <contenedor>` para 15-30 contenedores: en lugar de abrir una pestaña SSH por servicio, una sola pestaña en el navegador.

Este documento **se suma al _stack_ `infra`** (Portainer, `docker-socket-proxy`, Watchtower) en lugar de al _stack_ `monitor` (Prometheus, Grafana, Node Exporter, cAdvisor, Uptime Kuma). La razón es que Dozzle, igual que Portainer y Watchtower, **necesita acceso al motor Docker** y por convención del homelab (`docs/02-docker/03-portainer.md`) ese acceso pasa por el `docker-socket-proxy` que vive en `~/homelab/infra/`. La tabla de _stacks_ en `docs/02-docker/02-estructura-compose.md` reserva precisamente este _slot_ para Dozzle. **No se monta `/var/run/docker.sock` directamente en Dozzle**: habla con el motor por TCP a `docker-socket-proxy:2375`, igual que Portainer y Watchtower.

> **Alcance**: este documento añade el servicio `dozzle` al `~/homelab/infra/docker-compose.yml`, lo conecta a las redes `infra-internal` (para hablar con el _proxy_) y `homelab` (para que Caddy lo alcance), añade su variable de _tag_ a `infra/.env`/`.env.example`, lo expone como `https://dozzle.lan/` detrás de Caddy con HTTPS interno, lo protege con **Authelia 2FA** vía `forward_auth` y añade `dozzle.lan` a la regla `two_factor` del `access_control` de Authelia. **No** activa el modo "remote agent" de Dozzle (multi-host con `dozzle agent`): el homelab es un único host (Pi 5), el modo agente es para clústers. **No** activa _container actions_ (`--actions`, que permite reiniciar/parar contenedores desde la UI de Dozzle): la operación de contenedores se hace desde Portainer, que ya tiene `EXEC`/`POST`/`DELETE` habilitados; Dozzle queda como **lector estricto**. **No** integra el endpoint `/metrics` de Dozzle con Prometheus en este doc — está disponible y se documenta como **operación opcional** al final.

> **Recordatorio de red**: Dozzle **no se publica al host**. Caddy lo alcanza por DNS interno de Docker (`dozzle:8080`) dentro de la red `homelab`, y Dozzle alcanza el _proxy_ Docker (`docker-socket-proxy:2375`) dentro de la red `infra-internal`. El operador entra por `https://dozzle.lan/`, que Pi-hole resuelve a `192.168.1.3` (_wildcard_ de `02-homelab-local.conf`) y Caddy demultiplexa por SNI. Authelia exige 2FA antes de exponer la UI.

> **Doble cierre intencional con el _stack_ `infra`**: Portainer (`docs/02-docker/03-portainer.md`) ya muestra _logs_ en su pestaña _Containers → Logs_, pero su UI es densa (gestión completa del motor) y los _logs_ se muestran de a uno, sin _streaming_ persistente entre cambios de contenedor. Dozzle es la herramienta especializada — pestaña permanente del operador, refresco _live_ y navegación por teclado. Coexisten: Portainer para _operar_, Dozzle para _ver_.

---

## Requisitos previos

- `docs/02-docker/03-portainer.md` completado: el _stack_ `infra` existe en `~/homelab/infra/`, `docker-socket-proxy` está en marcha en la red `infra-internal` con sus _endpoints_ actuales (`CONTAINERS=1`, `EVENTS=1`, `INFO=1`, `VERSION=1`, `PING=1`, `POST=1`, `SYSTEM=1` — todos los que Dozzle va a necesitar ya están enabled), Portainer es operativo, y `infra/.env` lleva `PORTAINER_IMAGE_TAG`, `SOCKET_PROXY_IMAGE_TAG`, `PORTAINER_ADMIN_PASSWORD_HASH`.
- `docs/02-docker/04-watchtower.md` completado: Watchtower está vigilando con `WATCHTOWER_LABEL_ENABLE=true` (modo _opt-in_), `DELETE=1` ya activo en el _proxy_ (Dozzle no lo necesita pero ya está). Dozzle figura en aquel doc como candidato _opt-in_; este doc activa la _label_.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, _snippets_ `security-headers`, `logging` y `authelia` operativos, `import /etc/caddy/snippets/*.caddy` activo en el `Caddyfile`. Caddy ya escribe sus _logs_ JSON a `stdout` (cita explícita en `docs/03-red/04-caddy.md`: "Logs estructurados a stdout (los recoge Dozzle, docs/05-monitorizacion/06-dozzle.md)") — Dozzle podrá leer **también** los _logs_ del _reverse proxy_ que lo expone, lo cual es deliciosamente recursivo.
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `dozzle.lan` — el _wildcard_ ya lo cubre.
- `docs/04-seguridad/01-authelia.md` completado: `https://auth.lan/` operativo con TOTP, _snippet_ `(authelia)` activo en `~/homelab/red/caddy/snippets/authelia.caddy`, `access_control` con la regla `two_factor` ya conteniendo `portainer.lan`, `prometheus.lan`, `grafana.lan` y `uptime.lan`. Este doc añade `dozzle.lan` a esa lista.
- `docs/04-seguridad/02-fail2ban.md` completado: la convención `keep_stdout: true` está aplicada en Authelia (y en cualquier futuro servicio que escriba a fichero), de modo que `docker logs <contenedor>` siempre ve también lo que va al fichero. Dozzle se basa enteramente en este `stdout`/`stderr` — los _logs_ que sólo van a fichero **no aparecen** en Dozzle.
- `docs/05-monitorizacion/05-uptime-kuma.md` completado: cuando levantemos Dozzle, añadiremos un _monitor_ HTTP a Uptime Kuma para vigilar que el propio Dozzle responde (regla "todo servicio nuevo se monitoriza"). Es la pauta de aquel doc.
- `docs/02-docker/02-estructura-compose.md` completado: red `homelab` (`172.20.10.0/24`, `br-homelab`) creada y _externa_, `~/homelab/.env` con `TZ`, `PUID`, `PGID` y `HOMELAB_DOMAIN=lan` operativos. La red `infra-internal` (creada por `03-portainer.md`) sigue marcada como `internal: true` y Dozzle se sumará a ella.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/dozzle/` ya existe vacío `root:root 0755`. **No se monta** en este doc (Dozzle es _stateless_ por diseño — ver _Decisiones de diseño_); el directorio se reserva por si en el futuro se activa el _persisted reading positions_ opcional de la rama `8.x`.
- Conectividad saliente para descargar la imagen:

  ```bash
  docker pull --platform linux/arm64 amir20/dozzle:v8.13.5 >/dev/null && echo OK
  ```

- Que el host **no** tenga ya un servicio escuchando en `:8080`:

  ```bash
  sudo ss -tulpn '( sport = :8080 )'
  ```

  Salida esperada: vacía. Dozzle **no** publica `:8080` al host (sólo lo expone a la red `homelab`), pero conviene confirmar que ningún binario residual lo ocupa antes del primer `up`. cAdvisor (`docs/05-monitorizacion/04-cadvisor.md`) también escucha en `:8080` _dentro_ de su contenedor, pero al estar en la red `homelab` con `aliases: [cadvisor]` y al no publicar al host, no hay colisión: ambos coexisten porque cada uno tiene su propia IP de contenedor.

---

## Decisiones de diseño

### Por qué Dozzle (y no Logspout / Loki+Promtail / journald-forwarder / Portainer logs)

| Candidato                                | Por qué se descarta                                                                                                                                                                                                                                                                                                                                                |
|------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **`docker logs -f`** vía SSH             | Funciona pero no escala más allá de un contenedor a la vez. Para el _operator_ del homelab que quiere "una pestaña con todo", la fricción de cambiar de SSH+contenedor por cada inspección termina siendo "no se mira nunca". Dozzle reduce esa fricción a cero.                                                                                                  |
| **Portainer → Containers → Logs**        | Funciona, pero la UI mezcla _logs_ con configuración del contenedor; el _streaming_ se rompe al cambiar de pestaña; sin _search_ ni _filter_ útil. Para "ver _logs_ a velocidad humana", Portainer es el camino lento. Coexisten — Portainer para _operar_, Dozzle para _ver_.                                                                                  |
| **Logspout + syslog/papertrail**         | _Push_ a un agregador externo. Modelo válido pero requiere agregador (papertrail SaaS — descartado por política, o un servidor syslog propio — escala más). Para el homelab actual, _streaming_ en el navegador sin almacenamiento intermedio es suficiente.                                                                                                       |
| **Loki + Promtail + Grafana**            | El _stack_ canónico de _logs aggregation_ para Grafana. Es lo correcto **a partir de cierto tamaño** (~50 contenedores, retención multi-mes, búsqueda full-text histórica). En una Pi 5 con 8 GB y ~20 contenedores, montar Loki con retención de 7 días añade ~1-2 GB de RAM, ~5 GB de disco/semana y un _stack_ entero a mantener. Dozzle hace el 80 % del valor con el 5 % del coste. **Si en el futuro el homelab crece** (>30 contenedores, _logs_ a `/dev/stderr` muy verbosos, necesidad de búsqueda full-text histórica), se documenta el _bump_ a Loki en un doc posterior, en paralelo a Dozzle (no sustituyéndolo — son cosas diferentes). |
| **journald-forwarder + `journalctl -fu`** | Pi OS Bookworm tiene `journald` activo y los _logs_ de Docker (con `--log-driver=journald`) acabarían ahí. Visualización con `journalctl` es buena por servicio _systemd_ pero **mala** para contenedores (se pierde el nombre del contenedor a menos que se reescriba el `tag`). Y exigiría cambiar `daemon.json` a `"log-driver": "journald"` (`docs/02-docker/01-instalacion-docker.md` lo dejó en `json-file` con rotación). Dozzle vive sobre el _driver_ por defecto sin tocar nada. |
| **Filebeat → Elasticsearch**             | Sobredimensionado para una Pi 5. Elasticsearch con un solo nodo en ARM64 es viable pero consume ~2 GB de RAM y obliga a operar otro _stack_ (Kibana, índices, retención). Alternativa para empresas, no para homelabs.                                                                                                                                                |
| **`docker stats` + Grafana via cAdvisor** | Eso son **métricas** (CPU/RAM/red), no _logs_. Las cubre `docs/05-monitorizacion/04-cadvisor.md`. Complementario, no sustituto.                                                                                                                                                                                                                                       |

Dozzle gana por:

- **UI muy directa**: panel de la izquierda con la lista de contenedores (filtrable por _stack_, por _name_, por _status_), panel central con el _stream_ del seleccionado, _search_ con `Ctrl+F` y _stash_ con `Shift+F` (busca en el _buffer_ con _fuzzy match_).
- **_Streaming_ HTTP/SSE eficiente**: usa _Server-Sent Events_, no _polling_. La conexión se mantiene abierta y los _logs_ llegan al navegador con latencia < 1 s desde el `stdout` del contenedor.
- **Sin estado persistente**: ningún SQLite, ningún _index_. Todo se hace al vuelo leyendo del socket Docker. Si Dozzle muere y se recrea, no se pierde nada (los _logs_ siguen en los contenedores).
- **Multi-arch ARM64 nativo**: imagen `amir20/dozzle` se publica para `linux/arm64` desde `v3.x` (2021).
- **Footprint mínimo**: ~20 MB de imagen, ~30-50 MB de RAM en _idle_, < 1 % CPU en _streaming_ activo. Cabe sin ruido en una Pi 5.
- **Configuración por entorno**: cero ficheros en disco, todo vía _env vars_ — encaja con la estética del homelab.
- **Healthcheck `built-in`**: la imagen oficial define un `HEALTHCHECK` propio (`/usr/local/bin/dozzle healthcheck`) que tira `(healthy)` cuando el _proxy_ Docker responde. Un _smoke test_ de la cadena entera de un solo vistazo.
- **Mantenedor único activo y _release cadence_ regular**: amir20 publica versiones casi semanales con bugfixes y mejoras incrementales. Riesgo de _bus factor_ asumido — la app es lo bastante simple como para hacerle _fork_ si fuera necesario.

### Stack `infra` (no `monitor`) — decisión vinculante

Aunque `docs/05-monitorizacion/01-prometheus.md` cita "Grafana, Node Exporter, cAdvisor, Uptime Kuma, Dozzle" como compañeros del _stack_ `monitor`, la convención **autoritaria** está en `docs/02-docker/02-estructura-compose.md`:

| Stack          | Servicios                                                 |
|----------------|-----------------------------------------------------------|
| `infra`        | Portainer, Watchtower, **Dozzle**                         |
| `monitor`      | Prometheus, Grafana, Node Exporter, cAdvisor, Uptime Kuma |

Y `docs/02-docker/03-portainer.md` lo refuerza: "este documento estrena además el _stack_ `infra` … junto a Portainer se despliega un `docker-socket-proxy` por el que pasarán **todos** los servicios que necesiten hablar con el _socket_ de Docker (Portainer ahora; Watchtower, Dozzle… en fases siguientes)". Y Watchtower (`docs/02-docker/04-watchtower.md`) ya lo cumplió.

Razones por las que Dozzle pertenece a `infra` y no a `monitor`:

- **Necesita acceso al socket Docker**, igual que Portainer y Watchtower. La convención del homelab es que ese acceso pasa por **un único** `docker-socket-proxy`, no por N _proxies_ duplicados (uno por _stack_). El _proxy_ vive en `infra-internal` (red `internal: true`), así que Dozzle también tiene que estar conectado a esa red.
- **Conceptualmente** es una herramienta de _operación_/_inspección_ del motor (lo que ve son contenedores, no métricas), análoga a Portainer. Las métricas son métricas; los _logs_ son _logs_; ambas son "observabilidad" en el sentido amplio, pero la cadena `Prometheus → cAdvisor → Grafana → Uptime Kuma` es internamente coherente sin Dozzle, y Dozzle es internamente coherente con `Portainer → docker-socket-proxy → Watchtower` sin Prometheus.
- La cita del `docs/05-monitorizacion/01-prometheus.md` es una imprecisión menor escrita antes de fijar la tabla canónica de _stacks_; este doc la **corrige** de _facto_ poniendo a Dozzle en `infra` y deja la nota.

> **Si en algún momento alguien edita `docs/05-monitorizacion/01-prometheus.md`** para retirar la mención a Dozzle de la lista del _stack_ `monitor`, este doc no se ve afectado. La autoridad es `02-estructura-compose.md`.

### Acceso al motor: `docker-socket-proxy`, **no** `/var/run/docker.sock` directo

Igual que Portainer (`docs/02-docker/03-portainer.md`) y Watchtower (`docs/02-docker/04-watchtower.md`), Dozzle habla con el motor a través del _proxy_ Tecnativa que ya está en marcha. Razones:

1. **Política del homelab**: a partir de `docs/02-docker/03-portainer.md`, el _socket_ Docker no se vuelve a montar directamente en ningún contenedor. Cada nuevo consumidor pide los _endpoints_ que necesita y se conecta al _proxy_ por TCP.
2. **Mínimo privilegio**: si Dozzle se compromete (CVE en `amir20/dozzle`), un atacante con `/var/run/docker.sock` montado tiene acceso _full_ al motor (root en el host). Con el _proxy_, sólo tiene los _endpoints_ que el `environment:` le concede al _proxy_, **leyendo**.
3. **Auditoría**: el `environment:` del _proxy_ es la fuente de verdad sobre qué tiene permiso para qué. Inequívoco.

### _Endpoints_ del _proxy_ que Dozzle necesita — todos ya habilitados

Dozzle hace estas llamadas al _socket_ Docker:

| Llamada Docker API                  | Para qué                                                                  | Endpoint del _proxy_ |
|-------------------------------------|---------------------------------------------------------------------------|----------------------|
| `GET /containers/json`              | Listar contenedores en marcha (panel izquierdo)                           | `CONTAINERS`         |
| `GET /containers/<id>/json`         | Inspeccionar un contenedor (nombre, _labels_, imagen, _network_)          | `CONTAINERS`         |
| `GET /containers/<id>/logs?follow`  | _Streaming_ del `stdout`/`stderr` (uso principal)                         | `CONTAINERS`         |
| `GET /containers/<id>/stats?stream` | Mini-gráfica de CPU/RAM por contenedor (panel lateral, opcional)          | `CONTAINERS`         |
| `GET /events?since=...`             | Detectar contenedores nuevos/eliminados sin _polling_ (refresca el panel) | `EVENTS`             |
| `GET /info`                         | Versión del _daemon_, número de contenedores (footer)                     | `INFO`               |
| `GET /version`, `GET /_ping`        | Sanidad de conexión inicial                                               | `VERSION`, `PING`    |
| `GET /system/df`                    | Espacio usado por imágenes/volúmenes (footer, opcional)                   | `SYSTEM`             |

Estado actual del `environment:` del `docker-socket-proxy` tras `docs/02-docker/04-watchtower.md`:

```
CONTAINERS: 1   ← Dozzle lo necesita
EVENTS: 1       ← Dozzle lo necesita
INFO: 1         ← Dozzle lo necesita
VERSION: 1      ← Dozzle lo necesita
PING: 1         ← Dozzle lo necesita
SYSTEM: 1       ← Dozzle lo aprovecha (footer)
POST: 1         ← Dozzle NO lo necesita (modo lectura), pero está enabled por Portainer/Watchtower
DELETE: 1       ← Dozzle NO lo necesita; enabled por Watchtower
EXEC: 1         ← Dozzle NO lo necesita; enabled por Portainer
```

**Conclusión**: este documento **no añade ningún _endpoint_ nuevo** al _proxy_. Todo lo que Dozzle necesita ya está habilitado por Portainer y Watchtower. La cita del `docs/02-docker/03-portainer.md` ("Las fases `04-watchtower.md` y `05-monitorizacion/06-dozzle.md` añadirán los _endpoints_ que les falten editando el `environment:` del _proxy_ y reiniciándolo") era anticipatoria; la realidad es que `04-watchtower.md` ya cerró la lista que Dozzle hereda gratis.

> **¿Y si activamos `--actions` (restart/stop desde la UI de Dozzle)?**: requeriría `POST=1` (ya está) y, según la acción, `RESTARTS=1` (no presente — se habilitaría con `RESTARTS: 1`). **No se activa** en este doc porque la operación de contenedores se hace desde Portainer (`docs/02-docker/03-portainer.md`), que ya tiene SSO + 2FA. Dozzle queda como **lector estricto**. Si en el futuro se decide concentrar también las _actions_ en Dozzle (UI más directa), basta con añadir `RESTARTS: 1` al `environment:` del _proxy_ y `DOZZLE_ENABLE_ACTIONS: "true"` al servicio Dozzle. Documentado abajo en _Operaciones habituales_.

### Imagen y _tag_

- **`amir20/dozzle:v8.13.5`** — Dozzle `8.13` _stable_, multi-arch con `linux/arm64`, imagen oficial publicada por amir20 (autor original) en Docker Hub. Pinneada a versión completa (convención del homelab).
- **Por qué `:v8.13.5` y no `:v8`, `:v8.13` o `:latest`**: la convención del homelab es `vMAJOR.MINOR.PATCH` exacto. Permite a Watchtower hacer _opt-in_ a _patch releases_ sin saltar a `v9.x` ni a `v8.14.x` con cambios menores de UI.
- **Por qué `amir20/dozzle` (Docker Hub) y no `ghcr.io/amir20/dozzle` (GitHub Container Registry)**: ambas son oficiales, mantenidas en paralelo por el mismo `actions/release` workflow. Docker Hub es el _registry_ por defecto en este homelab; GHCR no añade nada y suma latencia de DNS/auth en el _pull_. Si en algún momento Docker Hub introdujera _rate limits_ que afectasen, se cambia a GHCR editando una sola variable del `.env`.
- **Por qué la rama `8.x` y no `7.x`/`9.x`**:
  - `7.x` (jul 2024) introdujo el modo "agente" (multi-host con `dozzle agent`), que en este homelab no se usa pero llegó con cambios menores en la UI que no afectan negativamente.
  - `8.x` (oct 2024) reescribió el _backend_ de _streaming_ usando _SSE_ correctamente sobre HTTP/2 y consolidó el modo "swarm" como `agent`. Estable.
  - `9.x` no existe a fecha del despliegue inicial de este homelab (2026-04). Si llega durante la vida del homelab, leer las _release notes_ y aplicar a mano (`v8 → v9` es un _major bump_; Watchtower nunca cruza _major_ por sí solo aunque se habilite `--label-take-effect-on-restart` — el _tag_ pinneado evita el cruce).
  - Para un primer despliegue en 2026, `v8.13.x` es el _baseline_ esperado.
- **Watchtower opt-in** (`com.centurylinklabs.watchtower.enable: "true"`):
  - _Patch releases_ (`v8.13.5 → v8.13.6`) son seguros: bugfixes y mejora de _UI strings_, sin renombrar _env vars_ ni cambiar _endpoints_.
  - Como el _tag_ pinneado **no cambia** entre _patch releases_, Watchtower sólo aplicaría un _bump_ si _upstream_ retagea `v8.13.5` con un nuevo _digest_ (raro). En la práctica, los _bumps_ se hacen a mano editando `~/homelab/infra/.env` (`DOZZLE_IMAGE_TAG=v8.13.6`) y ejecutando `make pull STACK=infra && make up STACK=infra`. Watchtower opt-in queda como red de seguridad para _hotfixes retagged_.
  - Entre _minors_ (`v8.13 → v8.14`) se leen las _release notes_ aunque suele ser estable.
  - Entre _majors_ (`v8.x → v9.x`), las _release notes_ se leen sí o sí y la actualización es manual.

### Sin `volumes:` — Dozzle es _stateless_ por diseño

Dozzle **no persiste nada en disco**. Toda su "memoria" es:

- _In-memory ring buffer_ por contenedor con los últimos N bytes/líneas (configurable con `DOZZLE_TAILSIZE`, default 300 líneas).
- _Configuración de filtros_ que el operador toquetea desde la UI (queda en `localStorage` del navegador, no en el servidor).

Consecuencias:

- **`/mnt/hd2t/services/dozzle/` queda vacío**. El directorio se reservó en `docs/01-sistema/04-estructura-directorios.md` por si en el futuro se activa el _persisted reading positions_ (rama `8.x` opcional, requiere montar `/data` y guarda los offsets de lectura por contenedor para no re-leer _logs_ ya vistos al recargar la pestaña). En el despliegue inicial **no se monta**: el coste mental ("¿qué pasa si la BD se corrompe?") supera el beneficio ("la pestaña vuelve a empezar desde el final del buffer al recargar, igual que en la mayoría de _terminals_").
- **`labels.homelab.backup: "false"`**: Borgmatic no tiene nada que respaldar. El _label_ es informativo.
- **Recreación instantánea**: `docker compose up -d --force-recreate dozzle` toma 2-3 s. La pestaña del navegador reconecta SSE sola.

### Acceso vía Caddy + Authelia 2FA — `dozzle.lan`

Mismo patrón que Portainer, Prometheus, Grafana y Uptime Kuma. Como Dozzle **revela el contenido de los _logs_ de TODOS los contenedores** (incluyendo posibles _credentials_ que algún servicio mal-configurado escupa accidentalmente, _tokens_ de _OAuth_ de Authelia en _debug_, _IPs_ de origen, _query parameters_ de _URLs_…) y **muestra el inventario completo** de servicios (lateral con sus _stacks_), la política se eleva a **`two_factor`**: usuario+contraseña + TOTP/WebAuthn.

Este doc añade `dozzle.lan` a la lista `two_factor` que `docs/05-monitorizacion/05-uptime-kuma.md` ya tenía con `portainer.lan`, `prometheus.lan`, `grafana.lan` y `uptime.lan`.

> **Sin login nativo de Dozzle**: la rama `8.x` introdujo autenticación nativa opcional vía `DOZZLE_AUTH_PROVIDER=simple` con un fichero `users.yml`. **No se activa**: Authelia ya provee la capa de auth, y duplicar (login + login) sin valor real ensucia el flujo. Se documenta abajo en _Operaciones habituales_ para quien quiera doble capa explícita (al estilo Uptime Kuma — pero a diferencia de aquél, Dozzle sí permite desactivarla sin más, así que no hay redundancia "automática").

> **`DOZZLE_AUTH_PROVIDER=none`**: explícito. Sin esta variable, Dozzle 8.x asume `none` por defecto (compatibilidad hacia atrás), pero declararlo evita ambigüedad y es lo que la _upstream_ recomienda cuando hay un _auth proxy_ delante.

### _Server-Sent Events_ (SSE): Caddy lo maneja transparente

Dozzle empuja _logs_ al navegador vía **SSE** (`Content-Type: text/event-stream`, _streaming_ HTTP unidireccional sobre HTTP/1.1 o HTTP/2). Caddy maneja SSE _out-of-the-box_ con `reverse_proxy` — no requiere _flags_ adicionales. La única precaución es **no aplicar _buffering_** en el _proxy_, lo cual Caddy ya hace por defecto (`flush_interval -1` se aplica automáticamente al detectar `text/event-stream`).

> **Si la UI muestra los _logs_ "a saltos" de varios segundos** en vez de fluidos: probable _buffering_ intermedio. Validar con `curl -N` desde el host (sección _Troubleshooting_).

> **`security-headers` no estorba SSE**: el _snippet_ `(security-headers)` añade `Cache-Control: no-store` para HTML y otras cabeceras genéricas, pero Dozzle ya añade `Cache-Control: no-cache` y `X-Accel-Buffering: no` a las respuestas SSE, lo cual Caddy reenvía intacto. Validado en _Verificación final_.

### Healthcheck: el _built-in_ de la imagen oficial

A diferencia de cAdvisor (`distroless` sin _shell_), `amir20/dozzle` viene con un binario `dozzle` que acepta el subcomando `healthcheck`. El `Dockerfile` _upstream_ lo activa por defecto:

```dockerfile
# Extracto del Dockerfile upstream (informativo):
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
    CMD ["/dozzle", "healthcheck"]
```

`/dozzle healthcheck` hace una llamada HTTP local a `:8080/healthcheck` y verifica que el proceso responde y, además, que el `docker-socket-proxy` está alcanzable. Si el _proxy_ se cae, Dozzle reportará `(unhealthy)` aunque el binario siga corriendo.

**Lo dejamos como está**: el _healthcheck_ del contenedor pinta `(healthy)` en `docker compose ps` en ~10-15 s, suficiente para una Pi 5.

### Watchtower opt-in + _label_ `homelab.backup: "false"`

```yaml
labels:
  homelab.stack: "infra"
  homelab.backup: "false"
  com.centurylinklabs.watchtower.enable: "true"
```

- `homelab.backup: "false"` → Borgmatic no respalda nada (Dozzle es _stateless_).
- `watchtower.enable: "true"` → _opt-in_ a _patch releases_ retagged. Justificación arriba.

### `DOZZLE_HOSTNAME=pi5`

Por defecto Dozzle muestra como _hostname_ el del contenedor (`<container-id-short>`). Forzando `DOZZLE_HOSTNAME=pi5` (mismo valor que `instance` en Prometheus, ver `docs/05-monitorizacion/03-node-exporter.md`) la UI muestra "pi5" en el header — coherente con el resto de la observabilidad.

### `DOZZLE_LEVEL=info` y `DOZZLE_NO_ANALYTICS=true`

- `DOZZLE_LEVEL=info`: nivel de _logs_ del propio Dozzle (no de los contenedores que muestra). `debug` sería ruidoso para uso normal; `warn` ocultaría _info_ útil al arrancar.
- `DOZZLE_NO_ANALYTICS=true`: deshabilita el _ping_ de telemetría que Dozzle envía a `analytics.dozzle.dev` (_anonymous version+install id_, opt-out documentado por _upstream_). Política del homelab: cero telemetría saliente sin razón.

### `DOZZLE_ENABLE_SHELL=false`

Desde `8.x`, Dozzle ofrece un _embedded shell_ que abre un _websocket_ al `docker exec` de un contenedor seleccionado. Es práctico, pero requiere `EXEC=1` en el _proxy_ (ya está) **y** otorga al operador con TOTP la capacidad de obtener _shell_ en cualquier contenedor sin pasar por SSH/Portainer.

**Lo deshabilitamos** explícitamente por dos razones:

1. **Convención de "tools especializadas"**: la _shell_ es trabajo de Portainer (que ya tiene el flujo, las _quick commands_, el _resize_ de la terminal y un cliente más sólido). Dozzle, _logs_ stream.
2. **Auditoría**: si el _shell_ es operable desde Dozzle y desde Portainer, hay que vigilar dos vías. Cerrarlo en Dozzle simplifica el modelo de amenazas.

Si en algún momento se quiere unificar todo (Dozzle como única UI), se invierte: `DOZZLE_ENABLE_SHELL=true` y se desactiva el correspondiente en Portainer. Por ahora, **no**.

### Sin `pid: host`, sin `privileged: true`, sin `cap_add:`

A diferencia de cAdvisor (que necesita `pid: host` y `privileged: true` para iterar _PIDs_ y leer `/sys/fs/cgroup`), Dozzle **no toca el host**. Toda la información la obtiene del _proxy_ Docker por TCP. El contenedor:

- Corre como `root` dentro (default de la imagen oficial — el binario Go no exige UID elevado, pero la imagen no lo cambia).
- Sin _capabilities_ extra (las que Docker concede por defecto: `CHOWN`, `DAC_OVERRIDE`, etc., todas inocuas en este contexto).
- Sin _bind mounts_ del host (el `/var/run/docker.sock:ro` que verías en _tutorials_ se sustituye aquí por la conexión TCP al _proxy_).

Consecuencia: incluso un compromiso completo del binario Dozzle no escala más allá de los _endpoints_ que el _proxy_ concede (lectura de contenedores), lo que es un perímetro **mucho** más estrecho que el de cAdvisor o Portainer.

### `read_only: true` + `tmpfs: /tmp`

El _filesystem_ del contenedor se monta como _read-only_ (`read_only: true`) porque Dozzle no escribe en disco. La única excepción es `/tmp`, que algunos clientes HTTP de Go usan para _spillover_ de respuestas grandes; lo montamos como `tmpfs` para satisfacer esa necesidad sin que el contenedor pueda persistir nada.

> **Defensa en profundidad**: el _proxy_ ya restringe lo que Dozzle puede hacer con el motor; `read_only: true` cierra la categoría de _post-exploitation_ "escribe un binario al FS y reinicia". No es la barrera principal, sí es defensa en profundidad y sale gratis.

### Sin `depends_on:` _hard_

`docker-socket-proxy` se levanta por `depends_on: { service_started }` cuando Compose ordena el _stack_, pero Dozzle **no** declara `depends_on:` explícito porque:

1. Si el _proxy_ no responde al arranque, Dozzle reintenta cada 1 s sin escalar (el _healthcheck_ tarda en pasar a `healthy` pero el contenedor no muere).
2. En recreaciones del _proxy_ (cuando Watchtower o un humano hacen `up -d` con cambios), Compose no respeta `depends_on` en _restarts_ aislados; sí en `up` desde cero.
3. Mantiene el _stack_ resiliente: el _proxy_ puede reiniciarse y Dozzle se reconecta sin `restart: unless-stopped` haciendo cascadas.

---

## Almacenamiento

| Ruta en el host                                                         | Contenido                                                                  | Versionable | Backup |
|-------------------------------------------------------------------------|----------------------------------------------------------------------------|-------------|--------|
| `~/homelab/infra/docker-compose.yml`                                    | Definición del _stack_ (modificada — servicio `dozzle` añadido)           | git         | git    |
| `~/homelab/infra/.env.example`                                          | `DOZZLE_IMAGE_TAG` añadido                                                 | git         | git    |
| `~/homelab/infra/.env`                                                  | `DOZZLE_IMAGE_TAG` con valor real                                          | **NO** (`.gitignore`) | git aparte (nota local) |
| `~/homelab/red/Caddyfile`                                               | Bloque `dozzle.lan` añadido                                                | git         | git    |
| `~/homelab/seguridad/configuration.yml`                                 | `dozzle.lan` añadido a la regla `two_factor`                               | git         | git    |
| `/mnt/hd2t/services/dozzle/`                                            | (vacío) — reservado por si se activa _persisted reading positions_         | **NO**      | **No** |

> **Sin estado persistente**: Dozzle es _stateless_; toda su _memory_ es el _ring buffer_ de RAM y los _logs_ están en los propios contenedores (gestionados por el _logging driver_ `json-file` con rotación, ver `docs/02-docker/01-instalacion-docker.md`). La pérdida del contenedor `dozzle` se recupera en segundos con `make up STACK=infra`.

---

## Estructura del _stack_ `infra` tras este documento

```
~/homelab/infra/
├── docker-compose.yml              # ← modificado (servicio 'dozzle' añadido)
├── .env                            # ← modificado (DOZZLE_IMAGE_TAG)
└── .env.example                    # ← modificado (DOZZLE_IMAGE_TAG)
```

> **Sin subdirectorio `~/homelab/infra/dozzle/`**: Dozzle no tiene ficheros de configuración propios versionables — su comportamiento se define entero en variables de entorno. No hace falta un subdirectorio para él.

---

## Variables de entorno

Editar `~/homelab/infra/.env.example` y añadir al final:

```bash
# Dozzle (docs/05-monitorizacion/06-dozzle.md)
# Tag pinneado del visor de logs.
DOZZLE_IMAGE_TAG=v8.13.5
```

Reflejar en `~/homelab/infra/.env` (no versionado):

```bash
cd ~/homelab/infra
grep -q '^DOZZLE_IMAGE_TAG=' .env || cat >> .env <<'EOF'

# --- Dozzle ---
DOZZLE_IMAGE_TAG=v8.13.5
EOF
chmod 0600 .env
```

> Sin secretos. Dozzle no maneja credenciales propias (la auth la provee Authelia) y la conexión al _proxy_ Docker es por TCP en una red `internal: true` sin TLS — basta con que ambos extremos vivan en `infra-internal`.

---

## Modificar `~/homelab/infra/docker-compose.yml`

Añadir el servicio `dozzle` debajo del de `watchtower` (**no** sustituir: los bloques anteriores se quedan intactos):

```yaml
  # ---------------------------------------------------------------------------
  # Dozzle — visor web de logs en tiempo real (SSE).
  # Habla con el motor a través de docker-socket-proxy (TCP), nunca monta
  # /var/run/docker.sock directamente. Modo lectura: sin actions, sin shell.
  # UI tras Authelia 2FA en https://dozzle.lan/.
  # docs/05-monitorizacion/06-dozzle.md
  # ---------------------------------------------------------------------------
  dozzle:
    image: amir20/dozzle:${DOZZLE_IMAGE_TAG}
    container_name: dozzle
    hostname: dozzle
    restart: unless-stopped
    # Filesystem read-only — Dozzle no escribe nada persistente.
    # tmpfs en /tmp para spillover puntual de clientes HTTP de Go.
    read_only: true
    tmpfs:
      - /tmp:size=64M
    environment:
      # TZ: timestamps de los logs en hora local.
      TZ: ${TZ}
      # Conexión al motor a través del proxy (mismo patrón que Watchtower).
      DOCKER_HOST: tcp://docker-socket-proxy:2375
      # Hostname mostrado en la UI (coherente con instance=pi5 en Prometheus).
      DOZZLE_HOSTNAME: pi5
      # Auth nativa OFF — la provee Authelia en la capa exterior.
      DOZZLE_AUTH_PROVIDER: none
      # Sin 'embedded shell' — operación se hace desde Portainer.
      DOZZLE_ENABLE_SHELL: "false"
      # Sin 'container actions' (restart/stop) — operación desde Portainer.
      # (Si se activase, requeriría también RESTARTS=1 en el proxy).
      DOZZLE_ENABLE_ACTIONS: "false"
      # Tamaño del buffer en memoria por contenedor (líneas).
      DOZZLE_TAILSIZE: "300"
      # Nivel de logs del propio Dozzle.
      DOZZLE_LEVEL: info
      # Sin telemetría hacia analytics.dozzle.dev.
      DOZZLE_NO_ANALYTICS: "true"
      # Filtrar contenedores que se muestran. Por defecto: todos los del host.
      # Ejemplo si se quisiera ocultar Watchtower de la lista:
      #   DOZZLE_FILTER: "label!=com.centurylinklabs.watchtower.enable=false"
      # Por ahora, todos visibles (incluido Watchtower).
    networks:
      # 'homelab' para que Caddy lo alcance por DNS interno (dozzle:8080).
      homelab:
        aliases:
          - dozzle
      # 'infra-internal' para hablar con docker-socket-proxy:2375.
      # Esta red es 'internal: true' (sin gateway al exterior); Dozzle no
      # necesita salida a internet — sólo al proxy.
      infra-internal:
        aliases:
          - dozzle
    # Sin 'ports:' — Caddy es el único punto de entrada. La UI vive en :8080
    # dentro de la red 'homelab'.
    labels:
      homelab.stack: "infra"
      homelab.backup: "false"          # sin estado persistente
      # Patch releases seguros; opt-in. Lista del doc 02-docker/04-watchtower.md.
      com.centurylinklabs.watchtower.enable: "true"
    # healthcheck: heredado del HEALTHCHECK de la imagen upstream
    # ('/dozzle healthcheck' contra :8080/healthcheck). No se sobrescribe.
```

Notas de diseño extra:

- **Sin `ports: "8080:8080"`**: la convención del homelab es **no publicar puertos al host** salvo Caddy/Pi-hole. Cualquier herramienta de _debug_ que necesite alcanzar `:8080` desde el host se hace con `docker exec` o con un contenedor `curl` puntual en la red `homelab` (ver _Operaciones habituales_).
- **Doble red (`homelab` + `infra-internal`)**: igual patrón que Portainer. `homelab` es la red de "_servicios accesibles desde el reverse proxy_"; `infra-internal` es la red privada para hablar con el _proxy_ Docker.
- **`read_only: true` + `tmpfs: /tmp:size=64M`**: cierra el FS y deja un _scratch_ acotado para clientes HTTP de Go. 64 MB es ampliamente suficiente.
- **`hostname: dozzle`**: coherente con el alias en `networks`. Dozzle muestra su propio _hostname_ en algunos _tooltips_ de la UI; con esto, sale "dozzle" en lugar de un _container ID_ aleatorio.
- **`DOZZLE_HOSTNAME=pi5`** (distinto del `hostname:` del contenedor): este es el _display name_ que aparece en el header de la UI. Coincide con `instance=pi5` de Prometheus para que el operador asocie inmediatamente.
- **Sin `cap_drop: [ALL]`**: las _capabilities_ por defecto del runtime Docker son razonablemente acotadas para un proceso Go sin _privileged_; añadir `cap_drop: [ALL]` rompe `setpriority` y similares que Go usa internamente sin avisar. Defensa en profundidad insuficiente para el coste — se queda con las _defaults_.

---

## Modificar Authelia: añadir `dozzle.lan` a `two_factor`

Editar `~/homelab/seguridad/configuration.yml` y añadir `dozzle.lan` a la regla `two_factor` que ya contiene `portainer.lan`, `prometheus.lan`, `grafana.lan` y `uptime.lan`:

```diff
   # 3) Servicios críticos — exigir 2FA (TOTP / WebAuthn) además de 1FA.
   - domain:
       - 'portainer.lan'
       - 'prometheus.lan'
       - 'grafana.lan'
       - 'uptime.lan'
+      - 'dozzle.lan'
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

## Modificar el `Caddyfile`: bloque `dozzle.lan`

Editar `~/homelab/red/Caddyfile` y añadir, junto al de `uptime.lan` (antes del catch-all `*.lan`):

```caddyfile
# ---------------------------------------------------------------------------
# dozzle.lan — Dozzle, visor de logs en tiempo real.
# Caddy maneja SSE (Server-Sent Events) sin flags adicionales: detecta el
# Content-Type 'text/event-stream' y desactiva el buffer.
# Authelia exige 2FA delante; Dozzle no tiene auth nativa (DOZZLE_AUTH_PROVIDER=none).
# docs/05-monitorizacion/06-dozzle.md
# ---------------------------------------------------------------------------
dozzle.lan {
    tls internal
    import security-headers
    import logging
    import authelia

    reverse_proxy dozzle:8080 {
        # Pasar el host original — útil si en el futuro Dozzle construye URLs
        # absolutas (ej. enlaces a 'shared logs' que se introducen en 8.x).
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # Timeout generoso para el streaming SSE: por defecto Caddy aplica
        # 'flush_interval -1' al detectar text/event-stream, pero forzamos
        # un read_timeout largo para que la conexión persistente no se corte
        # en silencio (los logs pueden estar quietos varios minutos).
        transport http {
            read_timeout 0
        }
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

> **Por qué `read_timeout 0`** (en lugar del _default_ de Caddy): el _default_ es 0 ya (sin timeout), pero declararlo explícito documenta la intención y previene regresiones si algún _snippet_ futuro fija un valor distinto. Dozzle mantiene la conexión SSE abierta indefinidamente; un _timeout_ a 60 s la cortaría cada minuto y el navegador re-conectaría con un _glitch_ visible.

> **Snippet `(authelia)` y SSE conviven sin conflicto**: la cookie de Authelia se valida en el _handshake_ HTTP inicial (un GET a `/`), no en cada _event_ SSE. Una vez establecida la conexión, los _events_ fluyen sin nuevas validaciones. Lo único que hay que vigilar es que la sesión Authelia no expire mientras la pestaña está abierta (default 1 h de inactividad o 1 d con `remember_me`); cuando expira, el siguiente reconnect del navegador ve un 401 y Dozzle muestra "_Disconnected_" hasta re-loguear. Aceptable.

---

## Despliegue

Orden seguro:

```bash
# 1) Editar los ficheros versionables ya descritos:
#    - ~/homelab/infra/.env y .env.example   (DOZZLE_IMAGE_TAG)
#    - ~/homelab/infra/docker-compose.yml    (servicio 'dozzle')
#    - ~/homelab/red/Caddyfile               (bloque 'dozzle.lan')
#    - ~/homelab/seguridad/configuration.yml ('dozzle.lan' en two_factor)

# 2) Validar el compose modificado:
docker compose -f ~/homelab/infra/docker-compose.yml \
    --env-file ~/homelab/.env --env-file ~/homelab/infra/.env \
    config | grep -A 30 'dozzle:'

# 3) Validar Authelia config:
docker exec authelia authelia validate-config --config /config/configuration.yml
# Configuration parsed successfully without warnings or errors.

# 4) Recargar Authelia (restart porque no soporta SIGHUP):
docker compose -f ~/homelab/seguridad/docker-compose.yml restart authelia

# 5) Validar y recargar Caddy:
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile

# 6) Levantar el nuevo servicio (sólo crea 'dozzle'; el resto del
#    stack 'infra' sigue vivo):
cd ~/homelab
make up STACK=infra
# o, equivalente:
docker compose -f ~/homelab/infra/docker-compose.yml \
    --env-file ~/homelab/.env --env-file ~/homelab/infra/.env \
    up -d dozzle
```

Verificar que Dozzle levantó y está `(healthy)`:

```bash
docker compose -f ~/homelab/infra/docker-compose.yml ps
# NAME                  STATUS                   PORTS
# docker-socket-proxy   Up X minutes             2375/tcp
# portainer             Up Y minutes (healthy)   ...
# watchtower            Up Z minutes
# dozzle                Up V seconds (health: starting)
# ...esperar a que pase a (healthy) — start_period es 10 s.
```

Comprobar que la UI responde dentro de la red `homelab`:

```bash
docker run --rm --network homelab curlimages/curl:8.10.1 \
    -fsS http://dozzle:8080/ | head -5
# <!doctype html>
# <html lang="en">
#   <head>
#     <meta charset="utf-8">
#     <title>Dozzle</title>
```

Comprobar el endpoint `/healthcheck` (interno, sin auth):

```bash
docker run --rm --network homelab curlimages/curl:8.10.1 \
    -fsS http://dozzle:8080/healthcheck
# OK
```

Comprobar que Dozzle alcanza el _proxy_ (la respuesta incluye la versión del motor):

```bash
docker exec dozzle wget -qO- http://docker-socket-proxy:2375/version
# {"Platform":{"Name":"Docker Engine - Community"},"Components":[...],...}
# Si esto falla, revisar networks: dozzle DEBE estar en infra-internal.
```

Confirmar el _bind_ desde Caddy (con TLS):

```bash
curl -k --resolve dozzle.lan:443:192.168.1.3 -I https://dozzle.lan/
# Esperado: HTTP/2 302
# location: https://auth.lan/?rd=https%3A%2F%2Fdozzle.lan%2F
# (Authelia redirige al portal — el forward_auth está activo)
```

---

## Configuración inicial (post-despliegue)

A diferencia de Uptime Kuma o Grafana, Dozzle **no tiene _setup wizard_**: la UI carga directamente la lista de contenedores y empieza a hacer _streaming_ del primero. La configuración se reduce a:

1. Abrir `https://dozzle.lan/` en el navegador.
2. Caddy redirige a `https://auth.lan/?rd=https%3A%2F%2Fdozzle.lan%2F`.
3. Authelia pide usuario+contraseña + TOTP (regla `two_factor`).
4. Tras autenticar, la UI de Dozzle aparece. Panel izquierdo con la lista de contenedores; panel derecho con los _logs_ del primero alfabéticamente.

### Pautas de uso (no es "configuración" pero sí "primer flujo")

- **Filtrar el panel izquierdo**: caja de búsqueda en la parte superior. Acepta substring (`auth` muestra `authelia`) y _glob_ (`*-exporter` muestra `node-exporter`).
- **Buscar en el _stream_ activo**: `Ctrl+F`. Filtra _live_ — las líneas que no coincidan se atenúan, no desaparecen.
- **Búsqueda _fuzzy_ en el _buffer_**: `Shift+F`. Útil cuando recuerdas "algo parecido a `connection refused`" y no quieres escribir el regex completo.
- **Pausar el _stream_**: `Space`. Útil para leer una porción concreta sin que el _autoscroll_ te lleve abajo.
- **Cambiar entre contenedores con teclado**: `j`/`k` (estilo Vim) en el panel izquierdo.
- **Ver varios contenedores simultáneamente**: arrastrar el contenedor del panel izquierdo al área central; Dozzle abre un _split view_ con _streams_ paralelos. Útil para correlacionar (Caddy + Authelia, p. ej., para depurar un flujo de _forward_auth_).
- **Compartir un fragmento de _log_** (en `8.x`+): seleccionar líneas → "Share" → genera una URL temporal. **No se usa en este homelab**: la URL es relativa al servidor Dozzle y, al estar tras Authelia, no es realmente _shareable_ con quien no tenga login. Función ignorada.

### Configurar Uptime Kuma para vigilar Dozzle

Como dicta `docs/05-monitorizacion/05-uptime-kuma.md` (sección _Operaciones habituales — Añadir un monitor para un servicio nuevo_), tras levantar un servicio HTTP nuevo se añade su _monitor_ a Uptime Kuma. Para Dozzle:

- UI Uptime Kuma → **Add New Monitor**.
- _Monitor Type_: `HTTP(s)`.
- _URL_: `http://dozzle:8080/healthcheck` (DNS interno; sin TLS — el _monitor_ vive en la red `homelab` y alcanza Dozzle sin pasar por Caddy).
- _Heartbeat Interval_: `60` s. _Retries_: `3`.
- _Tags_: `infra`.
- _Notifications_: ambos canales (Telegram + email) configurados en `docs/05-monitorizacion/05-uptime-kuma.md`.
- Save → en 1-2 _heartbeats_ debe estar verde.

---

## Verificación final

- [ ] `docker compose -f ~/homelab/infra/docker-compose.yml ps` muestra `dozzle` en estado `Up` y `(healthy)` tras ~15 s del primer arranque.
- [ ] `docker logs dozzle --tail 50` muestra el _banner_ inicial y `Listening on :8080` sin _stack traces_. Líneas relevantes esperadas:

  ```
  level=info msg="Connected to Docker host (proxy version)"
  level=info msg="Dozzle vX.Y.Z is running on http://localhost:8080"
  ```

- [ ] `docker run --rm --network homelab curlimages/curl:8.10.1 -fsS http://dozzle:8080/healthcheck` devuelve `OK`.
- [ ] `docker exec dozzle wget -qO- http://docker-socket-proxy:2375/version | head -c 50` devuelve un JSON con `"Platform":{"Name":"Docker Engine` — confirma que el _proxy_ es alcanzable desde Dozzle.
- [ ] `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` acepta el bloque `dozzle.lan`.
- [ ] `curl -k --resolve dozzle.lan:443:192.168.1.3 -I https://dozzle.lan/` devuelve `302 Found` con `Location: https://auth.lan/?rd=...`.
- [ ] Login interactivo desde el navegador: usuario+contraseña + TOTP de Authelia → `https://dozzle.lan/` carga la UI de Dozzle con la lista completa de contenedores en el panel izquierdo.
- [ ] El panel izquierdo lista **todos** los contenedores en marcha (`docker ps --format '{{.Names}}' | wc -l` y comparar con la cuenta de la UI). Si hay diferencia, revisar `DOZZLE_FILTER` (no debería estar setado).
- [ ] Seleccionar un contenedor que esté escupiendo _logs_ (p. ej. `caddy` haciéndole `curl` desde otra terminal a `https://prometheus.lan/`) y comprobar que las líneas aparecen en la UI con latencia < 1 s.
- [ ] _Streaming_ SSE activo: en DevTools del navegador → Network → filtrar por "logs" → debe aparecer un request `text/event-stream` que **no termina** mientras la pestaña está abierta. _Status_ `200 OK` con `Content-Type: text/event-stream`.
- [ ] **`Ctrl+F`** abre la caja de búsqueda. Buscar una palabra que aparezca en el _stream_ (`200`, p. ej., en los _logs_ JSON de Caddy) y comprobar que las líneas que matchean se realzan.
- [ ] **`Space`** pausa el _autoscroll_, una segunda pulsación lo retoma.
- [ ] Arrastrar un segundo contenedor al área central abre un _split view_ con dos _streams_ paralelos.
- [ ] Provocar un _restart_ de un contenedor cualquiera (`docker restart authelia` desde otra terminal) y comprobar que Dozzle:
    - Marca el contenedor como "_stopping_" momentáneamente en el panel izquierdo.
    - Re-conecta el _stream_ automáticamente cuando el contenedor vuelve a `Up`.
- [ ] Tras `docker compose -f ~/homelab/infra/docker-compose.yml restart dozzle`, la UI vuelve a cargar (la pestaña abierta muestra "_Disconnected_" durante ~5-10 s y luego se reconecta sola sin perder los _filtros_ del panel izquierdo — están en `localStorage`).
- [ ] Tras un `sudo reboot` de la Pi, `dozzle` arranca solo (`restart: unless-stopped`), pasa a `(healthy)` en <30 s y la UI carga sin intervención.
- [ ] `docker logs dozzle 2>&1 | grep -iE 'error|fatal' | head` no muestra errores nuevos. Los `connection refused` esporádicos durante un _restart_ del _proxy_ son tolerables (Dozzle reintenta).
- [ ] Uptime Kuma muestra el _monitor_ `Dozzle` en verde con _response time_ < 100 ms.
- [ ] `git -C ~/homelab status` muestra como **modificados**: `infra/docker-compose.yml`, `infra/.env.example`, `red/Caddyfile`, `seguridad/configuration.yml`. **No** muestra `infra/.env` ni nada bajo `/mnt/hd2t/`. _Commit_:

  ```bash
  cd ~/homelab
  git add infra/docker-compose.yml infra/.env.example \
          red/Caddyfile seguridad/configuration.yml
  git commit -m "feat(infra): add Dozzle behind Caddy + Authelia 2FA"
  ```

---

## Operaciones habituales

### Forzar re-creación del contenedor (cambio de _tag_, p. ej. `v8.13.5 → v8.13.6`)

```bash
cd ~/homelab/infra
sed -i 's/^DOZZLE_IMAGE_TAG=.*/DOZZLE_IMAGE_TAG=v8.13.6/' .env
docker compose pull dozzle
docker compose up -d dozzle
# Sin volúmenes que migrar — Dozzle es stateless. Las pestañas abiertas se
# reconectan en 5-10 s.
```

### Diagnosticar "Dozzle muestra contenedores parados pero ningún log"

Síntoma: el panel izquierdo lista los contenedores correctamente pero el panel central queda vacío al seleccionar uno.

Causas:

1. **El contenedor _no escribe_ a `stdout`/`stderr`**. Algunas imágenes (p. ej. Mosquitto sin `log_dest stdout`) escriben sólo a fichero. **Solución**: configurar el servicio para que duplique a `stdout` (la convención del homelab — ver `docs/04-seguridad/02-fail2ban.md` con `keep_stdout: true` en Authelia). Alternativa: `docker logs <contenedor>` desde el host también debería estar vacío en este caso, lo cual confirma el diagnóstico.
2. **El _logging driver_ del contenedor no es `json-file` ni `journald`**. Si en algún momento se cambia el `log-driver` a `local` o `syslog`, Dozzle pierde la capacidad de leer los _logs_ vía Docker API. **Solución**: dejar `log-driver: json-file` en `daemon.json` (ya es el default en `docs/02-docker/01-instalacion-docker.md`).

### Ocultar Watchtower (o cualquier otro contenedor) de la UI

Editar el servicio `dozzle` en `docker-compose.yml` y añadir:

```yaml
environment:
  DOZZLE_FILTER: "label!=com.docker.compose.service=watchtower"
```

Sintaxis: `<key>{=,!=}<value>` con _key_ entre `name`, `id`, `image`, `label=<key>`, `health`, `status`. Múltiples filtros separados por coma.

> **Cuándo hacerlo**: si el ruido de un contenedor _spammy_ (p. ej. un servicio de _debug_ temporal) se cuela en la UI y distrae. Por defecto, **no se filtra nada** — ver todo es lo que se quiere.

### Activar el _embedded shell_ (si en algún momento se decide)

Editar el servicio `dozzle` en `docker-compose.yml` y cambiar:

```yaml
environment:
  DOZZLE_ENABLE_SHELL: "true"
```

`EXEC=1` ya está habilitado en el _proxy_ (`docs/02-docker/03-portainer.md`); no hay que tocar nada más en `infra-internal`. Aplicar:

```bash
cd ~/homelab
make up STACK=infra
```

A partir de ahí, en la UI de Dozzle aparece un icono de "_terminal_" junto a cada contenedor; al pulsarlo, Dozzle abre un _websocket_ a `docker exec <id> /bin/sh` (o `/bin/bash` si la imagen lo tiene).

> **Riesgo**: cualquier operador con TOTP puede obtener _shell_ en cualquier contenedor sin pasar por SSH/Portainer. Es deseable o no según el modelo operativo. **Por defecto, deshabilitado**.

### Activar las _container actions_ (restart/stop desde la UI)

Editar el _proxy_ y Dozzle simultáneamente:

```yaml
# En docker-socket-proxy.environment:
RESTARTS: 1   # añadido (default 0)

# En dozzle.environment:
DOZZLE_ENABLE_ACTIONS: "true"
```

Aplicar:

```bash
cd ~/homelab
make up STACK=infra
```

A partir de ahí, en la UI de Dozzle aparecen botones "_Restart_" / "_Stop_" / "_Start_" sobre cada contenedor.

> **Por defecto, deshabilitado** por la misma razón que el _shell_: la operación se concentra en Portainer. Activarlo dispersa la responsabilidad.

### (Opcional) Activar `DOZZLE_AUTH_PROVIDER=simple` para doble capa

Si por algún motivo se quiere una segunda barrera de auth dentro de Dozzle (estilo Uptime Kuma con Authelia + login propio):

```yaml
environment:
  DOZZLE_AUTH_PROVIDER: simple
volumes:
  - /mnt/hd2t/services/dozzle/users.yml:/data/users.yml:ro
```

Y crear `/mnt/hd2t/services/dozzle/users.yml` con:

```yaml
users:
  homelab:
    name: "Homelab admin"
    email: "homelab@lan"
    password: "<bcrypt-hash>"
```

Generar el _hash_ con `docker run --rm httpd:2.4-alpine htpasswd -nbB admin 'CONTRASEÑA' | cut -d ':' -f2 | tr -d '\n'`.

> **Por defecto, no se activa**. Authelia ya provee 2FA y el doble login es fricción sin añadir seguridad real (las dos capas son contra "atacante con acceso a la LAN" — la primera ya cubre el caso). Documentado por completitud.

### (Opcional) _Scrape_ Prometheus de las métricas de Dozzle

Desde `8.x`, Dozzle expone `/metrics` en formato Prometheus con métricas internas (HTTP request rate, SSE connections active, container watch latency). Activarlo es trivial — Dozzle lo expone por defecto sin auth en `:8080/metrics`. Para que Prometheus lo _scrape_:

1. Editar `~/homelab/monitor/prometheus/prometheus.yml` y añadir:

   ```yaml
     - job_name: 'dozzle'
       metrics_path: /metrics
       scheme: http
       static_configs:
         - targets:
             - 'dozzle:8080'
           labels:
             service: dozzle
             stack:   infra
       relabel_configs:
         - target_label: instance
           replacement: pi5
   ```

2. Recargar Prometheus:

   ```bash
   docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
   docker exec prometheus kill -HUP 1
   ```

3. `https://prometheus.lan/targets` muestra el _target_ `dozzle` en `UP`.

> **Por qué es opcional y no _baseline_**: las métricas de Dozzle son útiles para "_¿Dozzle está sirviendo SSE?_", lo cual ya cubre Uptime Kuma con su _monitor_ HTTP. La cardinalidad añadida (~10 series) es trivial pero ofrece poco valor. Activar si se quiere _alertar_ específicamente sobre _SSE connections drop_ o _scrape latency_.

### Exportar la lista de contenedores visible

Para una auditoría puntual ("¿qué contenedores ve Dozzle?"):

```bash
docker exec dozzle wget -qO- http://docker-socket-proxy:2375/containers/json \
    | python3 -c "import sys,json;[print(c['Names'][0].lstrip('/')) for c in json.load(sys.stdin)]"
# Lista los nombres tal como Dozzle los ve.
```

Útil para confirmar que el conjunto de contenedores _visible vía proxy_ coincide con el de _running en el host_ (ambos deberían tener la misma cuenta).

---

## Backup

| Qué                                            | Dónde                                                       | Cómo                                            |
|------------------------------------------------|-------------------------------------------------------------|-------------------------------------------------|
| `docker-compose.yml`                           | `~/homelab/infra/`                                          | git                                             |
| `Caddyfile` (bloque `dozzle.lan`)              | `~/homelab/red/`                                            | git                                             |
| `configuration.yml` (regla `two_factor`)       | `~/homelab/seguridad/`                                      | git                                             |
| (sin volúmenes — Dozzle es _stateless_)        | —                                                           | —                                               |

> **Restauración**: clonar el repo, `make up STACK=infra`. En segundos vuelve la UI con la lista completa de contenedores. No hay nada más que recuperar — los _logs_ históricos viven en cada contenedor (gestionados por el _logging driver_ del motor) y no son responsabilidad de Dozzle.

> **Si en algún futuro doc se activa el _persisted reading positions_** (montando `/mnt/hd2t/services/dozzle/` en `/data` y usando `DOZZLE_PERSIST_FILE=/data/positions.db`), añadir `homelab.backup: "true"` y revisar este apartado. Por ahora, no aplica.

---

## Troubleshooting

### `dozzle` arranca y queda `(unhealthy)`

El _healthcheck_ de Dozzle prueba `:8080/healthcheck`, que internamente comprueba la conexión al _proxy_ Docker. Si falla:

```bash
docker logs dozzle --tail 50 | grep -iE 'error|cannot|refused'
```

Causas típicas:

- **`docker-socket-proxy` no está `Up`**:

  ```bash
  docker compose -f ~/homelab/infra/docker-compose.yml ps docker-socket-proxy
  ```

  Si está parado, levantarlo con `docker compose -f ~/homelab/infra/docker-compose.yml up -d docker-socket-proxy`.

- **`dozzle` no está en la red `infra-internal`**:

  ```bash
  docker inspect dozzle -f '{{json .NetworkSettings.Networks}}' | python3 -m json.tool
  # Debe listar 'homelab' Y 'infra-internal'.
  ```

  Si falta `infra-internal`, recrear con `docker compose up -d --force-recreate dozzle`.

- **El _proxy_ no concede los _endpoints_ que Dozzle necesita**: `CONTAINERS=1`, `EVENTS=1`, `INFO=1`, `VERSION=1`, `PING=1` deben estar a `1`. Confirmar con:

  ```bash
  docker inspect docker-socket-proxy -f '{{json .Config.Env}}' | tr ',' '\n' | grep -E 'CONTAINERS|EVENTS|INFO|VERSION|PING'
  ```

### El navegador entra en bucle de redirección entre `dozzle.lan` y `auth.lan`

Mismas causas que con Portainer/Uptime Kuma (ver `docs/04-seguridad/01-authelia.md` _Troubleshooting_):

1. Cliente entra por IP en lugar de por nombre — la cookie `Domain=lan` no aplica. Solución: usar siempre `https://dozzle.lan/`.
2. Navegador rechaza la cookie por cert no confiado. Solución: importar la CA local (`docs/03-red/04-caddy.md`).
3. `same_site: strict` por error en Authelia. Confirmar `same_site: lax` en `configuration.yml`.

### La UI carga pero los _logs_ no aparecen (o aparecen "a saltos")

Causa típica: el _streaming_ SSE no llega al navegador correctamente.

Comprobar desde la consola del navegador (DevTools → Network → filtrar por "logs"):

- Debe aparecer una conexión a `https://dozzle.lan/api/logs/<container-id>?stdout=1&stderr=1` con _status_ `200 OK`, _Content-Type_ `text/event-stream` y _Time_ creciente (no termina).
- Si _Content-Type_ es `application/octet-stream` o similar, algún _proxy_ intermedio está reescribiendo cabeceras. Validar el `Caddyfile` (no debería pasar — Caddy preserva las cabeceras del _upstream_).

Probar el _stream_ desde el host:

```bash
docker exec dozzle wget -qO- --timeout=5 \
    "http://docker-socket-proxy:2375/containers/$(docker ps -q --filter name=caddy | head -1)/logs?stdout=1&stderr=1&follow=1&tail=10" \
    2>&1 | head -20
# Si esto produce líneas con timestamps, la cadena dozzle → proxy → motor funciona.
```

Si la UI tiene _saltos_ pero el `wget` directo es fluido: probable _buffering_ en Caddy. **No debería pasar** con la configuración actual (Caddy aplica `flush_interval -1` automático para SSE), pero por completitud:

```bash
curl -kN --resolve dozzle.lan:443:192.168.1.3 \
    "https://dozzle.lan/api/logs/<id>?stdout=1&stderr=1&follow=1&tail=5" \
    -H "Cookie: authelia_session=<session-cookie>" \
    | head -20
```

(Necesita la cookie de sesión Authelia en formato `Cookie:`. Sacar de DevTools.) Si por curl también es fluido, el problema es del navegador (extensiones, _ad blocker_ que reescribe SSE).

### Faltan contenedores en la UI (Dozzle muestra menos de los que están `Up`)

Causas:

1. **`DOZZLE_FILTER`** está siendo aplicado. Confirmar:

   ```bash
   docker inspect dozzle -f '{{range .Config.Env}}{{println .}}{{end}}' | grep DOZZLE_FILTER
   ```

   Si aparece, ver _Operaciones habituales — Ocultar contenedores_ y revisar la sintaxis.

2. **El _proxy_ filtra contenedores por _label_**: el `docker-socket-proxy` Tecnativa permite restringir qué contenedores son visibles vía la variable `ALLOW`/`DENY` de _path matching_. En este homelab **no** se usa, así que no debería pasar. Confirmar:

   ```bash
   docker inspect docker-socket-proxy -f '{{json .Config.Env}}' | tr ',' '\n' | grep -E '^"ALLOW|^"DENY'
   ```

   Si aparece, revisar `~/homelab/infra/docker-compose.yml`.

3. **Contenedores fuera de la red `infra-internal`** sí que son visibles vía _proxy_ (el _proxy_ ve **todo** el motor del host, no sólo los contenedores conectados a su red). Esto **no** debería ser causa de pérdida.

### Tras `docker compose pull` con _bump_ a `v9.x`, la UI no carga (pantalla blanca)

Posible cambio _breaking_ en una _major release_. Revertir:

```bash
cd ~/homelab/infra
sed -i 's/^DOZZLE_IMAGE_TAG=.*/DOZZLE_IMAGE_TAG=v8.13.5/' .env
docker compose up -d dozzle
```

Y leer las _release notes_ de `v9.0.0` antes de reintentar — históricamente Dozzle ha cambiado nombres de _env vars_ entre _majors_ (`DOZZLE_USERNAME`/`DOZZLE_PASSWORD` removidas en favor de `DOZZLE_AUTH_PROVIDER` en `8.0`, p. ej.).

### El _split view_ con dos contenedores se rompe (uno se queda parado)

Causa típica: una de las dos conexiones SSE se cortó (timeout del servidor, _idle_ > N minutos en una _CDN_ intermedia — aquí no aplica, todo es LAN). Acción:

```bash
# Recargar la pestaña del navegador resuelve casi siempre.
```

Si recurrente, mirar `docker logs dozzle` durante el evento — debería haber un `level=warn msg="SSE connection closed"` con la razón.

### `docker logs dozzle` muestra spam de `connection refused` cada pocos segundos

Síntoma de que el _proxy_ está siendo recreado/reiniciado en bucle (probablemente Watchtower haciendo _bumps_ retagged a la vez). Confirmar:

```bash
docker events --filter container=docker-socket-proxy --since 10m
```

Si hay _restarts_ frecuentes, investigar el _proxy_ (`docker logs docker-socket-proxy`); Dozzle es la víctima, no la causa.

---

## Referencias

- Dozzle — Repo y _release notes_: <https://github.com/amir20/dozzle>
- Dozzle — Documentación oficial: <https://dozzle.dev/>
- Dozzle — Imagen Docker oficial: <https://hub.docker.com/r/amir20/dozzle>
- Dozzle — Variables de entorno y opciones: <https://dozzle.dev/guide/environment-variables>
- Dozzle — Modo agente (multi-host, no usado aquí): <https://dozzle.dev/guide/agent>
- Dozzle — Métricas Prometheus (`/metrics`): <https://dozzle.dev/guide/prometheus>
- Tecnativa `docker-socket-proxy` — Endpoints habilitados/bloqueados: <https://github.com/Tecnativa/docker-socket-proxy>
- Caddy — `reverse_proxy` y manejo nativo de SSE / _streaming_: <https://caddyserver.com/docs/caddyfile/directives/reverse_proxy>
- MDN — _Server-Sent Events_: <https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events>
