# Dozzle

## Descripción

Cerrados `01-prometheus.md`, `02-grafana.md`, `03-node-exporter.md`, `04-cadvisor.md` y `05-uptime-kuma.md`, el homelab tiene tres patas de observabilidad bien diferenciadas: **métricas** (Prometheus + exporters → Grafana), **disponibilidad** (Uptime Kuma sondeando endpoints + notificando por Telegram/email) y **alerting de "se cayó algo"**. Falta la cuarta pata clásica del trío *metrics, traces, logs*: **logs**. Cuando un servicio responde 502, Grafana dice "CPU 70 %, mem 1.2 GiB, restart hace 3 min" y Uptime Kuma dice "❌ down". Lo que no dicen ni uno ni otro es **por qué** el contenedor reinició hace 3 min — esa información vive en `docker logs <contenedor>` y, sin un visor cómodo, exige un SSH a la Pi y un `tail -f` a ciegas.

Este documento despliega **Dozzle**, el visor de logs de contenedores Docker en tiempo real. Su rol concreto en el homelab:

1. **Mostrar logs en vivo** (streaming SSE/WebSocket desde el socket de Docker) de **todos los contenedores** del host, agrupados por stack si las labels de Compose lo permiten. Filtros por contenedor, palabra clave, nivel (`error`/`warn`/`info`/`debug`) detectado heurísticamente, marcado de líneas con timestamps relativos.
2. **Buscar en logs históricos del runtime de Docker**: Docker conserva los logs por contenedor en `/var/lib/docker/containers/<id>/<id>-json.log` (driver `json-file`, default). Dozzle lee ese histórico además del stream actual, así que si un contenedor murió hace 10 minutos se puede ver lo último que escribió antes de morir, **sin** necesidad de un agregador externo.
3. **Permitir compartir un fragmento de log** mediante una URL temporal (anclar líneas, filtros aplicados, rango temporal) — útil para abrir un issue o pegar contexto en un canal sin tener que copiar y pegar 200 líneas en texto plano.
4. **Cubrir el caso de "necesito mirar logs ya"** sin desplegar el stack pesado de logging centralizado (Loki + Promtail + Grafana datasource), que para 8–12 contenedores es desproporcionado y traería su propia carga de mantenimiento, sus propias retenciones, sus propios labels, su propio chunk store. Dozzle es la elección consciente de **sin agregador, solo visor**.
5. **Exponer un perfil de usuario "lectura"** además del `admin`, con cuenta sin permisos de acción (sin botón de restart contenedor, sin shell embebido), de manera que un usuario invitado al panel no pueda dañar nada y solo vea lo que está pasando.

Lo que este documento **no** decide:

- **Agregación / persistencia centralizada de logs**: Loki, Elasticsearch, OpenObserve, Promtail, Vector — todos descartados aquí. La retención efectiva de Dozzle es la del driver de logs de Docker (rotación `json-file` a 10 MiB × 3 ficheros por contenedor por defecto en este homelab, ver `docs/02-base/01-docker.md`). Si el día de mañana hace falta correlar logs entre contenedores semanas atrás, se reabre con Loki en una Fase futura.
- **Búsqueda full-text avanzada**: Dozzle hace búsqueda *grep-like* en el stream actual y el histórico cargado en memoria. No tiene índice invertido. Para "encontrar todas las veces que Authelia logueó `Invalid credentials` en el último mes" hace falta algo más serio (Loki, journalctl persistente). Diferido.
- **Logs del host (systemd, kernel)**: Dozzle es **solo Docker**. Logs de sshd, fail2ban, kernel, etc. salen de `journalctl` por SSH (Fase 11 documenta el patrón). Reabrible si llega `journalctl-as-a-service` (poco probable).
- **Alertas basadas en patrones de log** ("avisar si aparecen 5× `panic:` en 1 minuto"). Eso pertenece a Loki + alerting o a un sidecar tipo `mtail`/`fluentbit`. Diferido.
- **Acciones desde la UI** (botones de restart, stop, start contenedor, shell interactivo `docker exec`). Dozzle **soporta** estas acciones a través del flag `DOZZLE_ENABLE_ACTIONS=true`, pero **se deja desactivado a propósito** en este homelab: el objetivo es ver, no operar. Operar pasa por SSH + Compose, registrado en histórico de shell. Reabrible si el operador decide que la ergonomía gana al rastro de auditoría.
- **Modo agente / multi-host**: Dozzle 8.x permite encadenar varios hosts mediante un **agente** que expone el socket de Docker remoto sobre TLS. El homelab es **un solo host** (Pi 5); el modo agente queda como diseño desbloqueable pero sin uso. Reabrible si en el futuro hay un segundo Pi o un NAS Docker.
- **Integración con Caddy logs estructurados de fuera-de-Docker**: Caddy ya emite a stdout/stderr y Docker los captura; Dozzle los ve. No se hacen ajustes adicionales aquí.

Cuando este documento se haya aplicado, el operador puede:

- Abrir `https://dozzle.${DOMAIN_LAN}/` desde la LAN (con login Authelia 2FA + login propio de Dozzle), ver una columna izquierda con todos los contenedores, hacer click en `pihole` y leer en vivo lo que está saliendo por stdout. Si el contenedor reinicia, Dozzle vuelve a engancharse al nuevo PID sin intervención.
- Filtrar por palabra clave (`grep`-like) directamente en la URL: `https://dozzle.${DOMAIN_LAN}/container/<id>?filter=ERROR` y compartir el enlace para colaborar en un debugging.
- Iniciar sesión como un usuario `viewer` (sin permisos de acción) y dejar la sesión abierta en una pestaña de su tablet sin riesgo de tocar nada. (Dado que `DOZZLE_ENABLE_ACTIONS=false`, el rol viewer y admin ven lo mismo en términos de capacidad — el rol existe para futuros activos cuando la auth se vuelva más compleja.)
- Recibir alertas de **caída del propio Dozzle** desde Uptime Kuma (monitor `dozzle-internal` apuntando a `http://dozzle:8080/healthz`).

> **Recordatorio de alcance**: Dozzle escucha **solo** en la red Docker `homelab` (`expose: 8080`) y **no publica `ports:` al host**. La UI vive tras Caddy + Authelia (`dozzle.${DOMAIN_LAN}`). Sin exposición de internet, sin DDNS, sin Let's Encrypt. Y, crítico: el contenedor monta `/var/run/docker.sock` en **modo lectura** (`:ro`), nunca escritura.

---

## Requisitos Previos

- **Fase 2** completa (Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN=lan`; driver de logs `json-file` con `max-size: 10m` y `max-file: 3` ya configurado en `/etc/docker/daemon.json` — ver `docs/02-base/01-docker.md`).
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre automáticamente `dozzle.${DOMAIN_LAN}` sin tocar Pi-hole).
  - Caddy desplegado y los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` en `Caddyfile`.
- **Fase 4** completa, en particular:
  - Authelia desplegado con el snippet `(authelia_two_factor)` en `stacks/caddy/conf.d/01-authelia.caddy`.
  - El usuario `homelab` existe en la base de usuarios de Authelia.
- **Fase 5 docs 01–05** aplicados. No hay dependencia técnica fuerte (Dozzle solo necesita Docker), pero se asume que Uptime Kuma ya está activo para crear el monitor `dozzle-internal` al final de este documento.
- Disco `hd2t` montado en `/mnt/hd2t` con al menos **50 MiB** libres reservados para Dozzle (la persistencia es ridícula: solo `users.yml` y, opcionalmente, `data/` con preferencias). Margen sobrado.
- Operador con la **CA interna instalada** en su navegador (`03-red/04-caddy.md` → "Instalar el root CA en los clientes").

Comprobaciones rápidas:

```bash
# La red Docker compartida existe
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Caddy y Authelia están corriendo
docker ps --filter name=caddy --filter name=authelia --format '{{.Names}} {{.Status}}'

# Driver de logs es json-file con rotación (default del homelab; ver Fase 2)
docker info --format '{{.LoggingDriver}}'
# json-file
sudo cat /etc/docker/daemon.json | jq '.["log-opts"]'
# {"max-size": "10m", "max-file": "3"}

# dozzle.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short dozzle.lan @192.168.1.2
# 192.168.1.10

# Uptime Kuma vivo (para crear el monitor al final)
curl -ksI https://uptime.lan/ | head -1
# HTTP/2 302  (redirige a auth.lan, normal)

# El socket de Docker es accesible y es del grupo `docker`
ls -l /var/run/docker.sock
# srw-rw---- 1 root docker 0 ... /var/run/docker.sock
```

---

## Decisión: imagen y versión

Dozzle se distribuye desde Docker Hub y GHCR (`amir20/dozzle`, `ghcr.io/amir20/dozzle`) con builds multi-arch (`amd64`, `arm64`, `armv7`). En la Pi 5 (aarch64) se usa el manifest `arm64`.

| Tag | Cuándo usar | Decisión aquí |
|---|---|---|
| `latest` | Demos. | Descartado (convención de Fase 2). |
| `master` | Builds desde `main`. | Descartado: rolling, romperá un día sin avisar. |
| `v8` | "Última 8.x". | Descartado: `v8` flota; un patch upstream con un bug nuevo aparecería en el próximo `docker compose pull` sin aviso. |
| `v8.13` | Última `v8.13.x`. | Aceptable; rama estable con auth multi-usuario. |
| `v8.13.7` (ejemplo) | Versión exacta `MAYOR.MENOR.PARCHE`. | **Aceptado** como compromiso entre reproducibilidad y mantenimiento. |
| `v7.x` | Rama anterior, sin auth multi-usuario nativa. | Descartado: la auth nativa es la razón principal por la que se elige Dozzle 8 sobre 7. |

> **Tag exacto en uso**: `amir20/dozzle:v8.13.7`. Si en el momento de aplicar este documento existe una `v8.13.x` superior con changelog limpio (sin migraciones de `users.yml` y sin cambios incompatibles en la API HTTP), se actualiza el tag aquí y en `docker-compose.yml`. **Nunca `latest`** ni `master`.

> **Por qué Dozzle y no `lazydocker` / `ctop` / `Portainer` / Loki + Grafana**. `lazydocker` y `ctop` son TUI (terminal): excelentes para operar SSH, malos para "abrir en una pestaña del navegador y dejar". Portainer es mucho más amplio (gestión completa de Docker Swarm/K8s) — buena herramienta, pero exige aceptar una superficie enorme de gestión de contenedores cuando el caso de uso es **solo logs**; además gestiona desde la UI, lo cual choca con el principio "operar es por SSH + Compose" del homelab. Loki + Promtail + Grafana es la elección "industrial" pero la complejidad operacional (índice de chunks, retención, query language LogQL, dashboards) está fuera de proporción para 8–12 contenedores. Dozzle ocupa exactamente el hueco "visor de logs en vivo, sin agregador, con auth, listo en 5 minutos".

---

## Decisión: acceso al socket de Docker

Dozzle lee logs llamando a la API HTTP de Docker (`GET /containers/<id>/logs?follow=1&stdout=1&stderr=1`). Hay tres formas de darle acceso:

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| Bind mount `/var/run/docker.sock` (rw) | Más simple, default en docs upstream. | Capacidad de **cualquier** llamada al socket: crear contenedores privilegiados, montar `/` del host, leer secretos. Un compromiso del proceso Dozzle = root del host. | Descartado. |
| Bind mount `/var/run/docker.sock` con `:ro` | Limita a verbos GET (Docker honra el flag de read-only en el bind mount, aunque no en la API → ver nota). El proceso solo puede listar/inspect/logs, no crear contenedores. | Si la imagen Dozzle se compromete, sigue habiendo lectura de envs (con secretos en claro), lectura de configuración de todos los contenedores, etc. | **Aceptado** con `DOZZLE_ENABLE_ACTIONS=false` y supervisión de cambios de imagen. |
| Proxy `docker-socket-proxy` (Tecnativa) | Whitelist de endpoints (`CONTAINERS=1`, `INFO=1`, `EVENTS=1`, todo lo demás `0`). Limita la superficie a exactamente lo que Dozzle necesita. | Un contenedor más; complejidad operacional adicional. | **Considerado y diferido**. Reabrible si en el futuro se añade Watchtower o Portainer (que también necesitan socket): un único proxy sirve a todos. |

Resultado: bind mount `:ro`, **sin** `docker-socket-proxy` por ahora, **con** la mitigación clave de fijar la imagen a tag exacto y deshabilitar acciones de mutación (`DOZZLE_ENABLE_ACTIONS=false`).

> **Nota técnica sobre `:ro` en el socket**. El flag `:ro` del bind mount evita escrituras al *fichero* socket (renombrarlo, borrarlo), pero **no** filtra las llamadas que se hacen *a través* del socket — eso es responsabilidad del daemon de Docker, que ofrece todos los verbos a quien pueda hablar con el socket. Para verdadero filtrado por verbo se necesita `docker-socket-proxy`. La diferencia entre `rw` y `ro` aquí es marginal en términos de seguridad, pero `:ro` es la convención y deja constancia explícita de la intención. La mitigación real es **no habilitar acciones mutantes** en Dozzle (siguiente decisión).

---

## Decisión: autenticación y autorización

Dozzle 8.x soporta varios proveedores de auth nativos:

| `DOZZLE_AUTH_PROVIDER` | Qué hace | Veredicto |
|---|---|---|
| `none` (default) | Sin auth: cualquiera con red puede ver todos los logs. | Descartado: aunque Dozzle viva tras Authelia, la *defensa en profundidad* exige una capa propia. Si Authelia cae o se omite por error, no quedar al desnudo. |
| `simple` | Lista de usuarios en `data/users.yml` con bcrypt. Soporta roles `admin` / `read-only` y MFA (TOTP). | **Aceptado**. Es la opción que mejor encaja con el patrón Authelia + Auth interna del propio servicio (igual que Uptime Kuma). |
| `forward-proxy` | Confía en cabeceras `Remote-User` puestas por un proxy upstream. | Considerado: Authelia ya inyecta `Remote-User`. Descartado por dos motivos: (a) elimina la auth interna como segunda barrera; (b) los roles de Dozzle (`read-only` vs `admin`) seguirían sin existir si no hay store de usuarios. Reabrible si el día de mañana Authelia gana grupos y se quiere SSO sin doble login. |

> **Decisión**: `DOZZLE_AUTH_PROVIDER=simple` con dos cuentas iniciales:
> - `admin` (rol `admin`): el operador.
> - `viewer` (rol `read-only`): cuenta de invitado (futura).

Las contraseñas se almacenan **bcrypt** en `users.yml`. La generación se hace con `htpasswd` o el comando integrado de Dozzle (`docker run --rm -ti amir20/dozzle:v8.13.7 generate <user> --password <pwd>` produce la línea YAML lista para pegar). Las contraseñas en sí **no** entran en `.env` ni en git: viven en `users.yml` que está fuera del repo.

| Política | Valor en este homelab |
|---|---|
| Mínimo de longitud de password | 16 chars (estándar del homelab; gestor obligatorio). |
| TOTP (MFA propio de Dozzle) | **Activado** para `admin` tras el primer login. |
| Caduca sesión | 24 h (default Dozzle). |
| `read-only` puede ver todos los contenedores | Sí (el filtrado por contenedor por usuario se descarta: cualquiera con acceso a Dozzle ya pasó Authelia 2FA). |

> **Sobre el doble login (Authelia + Dozzle)**. Es exactamente la misma decisión que en `05-uptime-kuma.md`: defensa en profundidad. Para entrar como admin hay que pasar 4 factores (Authelia user/pass + Authelia TOTP + Dozzle user/pass + Dozzle TOTP). Es ceremonia, pero los logs pueden contener información sensible (tokens leakeados en stack traces, queries con datos PII, headers de Authorization en Caddy con `log_level DEBUG`); cerrar la puerta al doble es coherente.

---

## Decisión: acciones (start/stop/restart, shell)

Dozzle 8.x trae un panel de **acciones** que aparece en la UI cuando se activa con `DOZZLE_ENABLE_ACTIONS=true`. Cada contenedor gana botones para `start`, `stop`, `restart` y un `Web shell` que abre un `docker exec -ti` embebido (xterm.js → backend Dozzle → docker exec).

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| `DOZZLE_ENABLE_ACTIONS=true` | Operar desde el navegador, sin SSH. | Pierde rastro: no queda en el `~/.bash_history` del operador, no se ve en `journalctl` quién reinició qué. Además exige que el socket sea verdaderamente RW (incluso con `:ro` el daemon acepta verbos POST). | Descartado. |
| `DOZZLE_ENABLE_ACTIONS=false` | El bind mount `:ro` cobra sentido: aunque la API lo permita, la UI no expone botones y un atacante con sesión Dozzle no puede mutar. La operación sigue siendo SSH → Compose, registrada y revisable. | "Reiniciar Pi-hole" cuesta un SSH. | **Aceptado**. |

Resultado: `DOZZLE_ENABLE_ACTIONS=false`. La columna izquierda muestra el contenedor, su estado (running / exited / unhealthy), pero no permite cambiarlo. La operación sigue siendo, por convención del homelab, vía SSH.

---

## Decisión: persistencia y permisos

Dozzle es **stateless** en lo esencial: lee logs del socket, no los almacena. Lo único persistente es la configuración:

- `users.yml` — usuarios + bcrypt + secrets TOTP.
- `data/sessions.json` (o equivalente, según versión) — tokens de sesión activos. Si se borra, todos los usuarios deben relogearse. Tolerable.
- Preferencias de UI por usuario (color theme, "containers favoritos") — guardadas en `data/`.

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| Volumen Docker nombrado | Docker gestiona permisos. | Se acaba en microSD, menos directo para `cat users.yml`. | Descartado. |
| Bind mount en hd2t (1000:1000) | `users.yml` editable a mano si es necesario; backup trivial. | Si la imagen futura cambia el UID, romper. | **Aceptado**. |
| Sin persistencia (`tmpfs`) | Mínimo. | Perder `users.yml` exige reconfigurar usuarios y TOTP en cada reinicio. | Descartado. |

Resultado: bind mount `/mnt/hd2t/apps/dozzle/data/` con `chown 1000:1000`, modo `0750`. `users.yml` vive bajo `/mnt/hd2t/apps/dozzle/data/users.yml` con `0600` (lo lee solo el proceso).

> **`PUID`/`PGID` no aplica directamente**. Como Uptime Kuma, Dozzle no expone `PUID`/`PGID`; el proceso corre como el UID definido en la imagen (UID `1000`). Coincide con el usuario `homelab` del host (Fase 1). Si en algún momento la imagen cambia esto, la línea `user: "1000:1000"` en el compose lo deja explícito.

> **Acceso al grupo `docker`**. Dado que se monta `/var/run/docker.sock`, el proceso necesita formar parte de un grupo con permisos de lectura sobre el socket. El socket es del grupo `docker` (GID variable según distro; en Raspberry Pi OS típicamente `998` o `999`). Se pasa explícitamente con `group_add: ["${DOCKER_GID}"]` en el compose, donde `DOCKER_GID` se exporta en el `.env` con el GID real del host. Sin esto, dependiendo de la imagen, el proceso podría no tener permiso para hablar con el socket aunque esté montado.

---

## Decisión: logs propios de Dozzle

Dozzle también es un contenedor; también tiene logs. Recurso bonito: **Dozzle ve sus propios logs**. Eso significa que si Dozzle empieza a comportarse raro, se puede mirar desde la propia UI (siempre que aún arranque). Si no arranca, queda el clásico `docker logs dozzle` por SSH.

No se hace ninguna configuración especial; el driver `json-file` con rotación (Fase 2) cubre el caso. Verbosidad por defecto de Dozzle es razonable; si en algún momento se necesita más, `DOZZLE_LEVEL=debug` lo sube.

---

## Stack: `stacks/dozzle/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/dozzle/docker-compose.yml` | microSD (git) | Stack (servicio `dozzle`). |
| `stacks/dozzle/.env.example` | microSD (git) | Plantilla con `DOCKER_GID`. |
| `stacks/caddy/conf.d/06-dozzle.caddy` | microSD (git) | Drop-in del bloque LAN (Authelia 2FA). |
| `/mnt/hd2t/apps/dozzle/data/` | hd2t | Datos persistentes: `users.yml`, `data/sessions.json`. Owner `1000:1000`. |
| `/mnt/hd2t/apps/dozzle/data/users.yml` | hd2t | Cuentas locales (bcrypt + TOTP secrets). Modo `0600`. |

### `stacks/dozzle/docker-compose.yml`

```yaml
# Dozzle — visor de logs Docker en tiempo real para el homelab.
# Documentado en docs/05-monitorizacion/06-dozzle.md.

name: dozzle

services:
  dozzle:
    image: amir20/dozzle:v8.13.7
    container_name: dozzle
    hostname: dozzle
    restart: unless-stopped

    # Corre como el UID del operador del homelab (homelab=1000) y se añade
    # explícitamente al grupo `docker` del host para poder leer el socket.
    user: "1000:1000"
    group_add:
      - "${DOCKER_GID}"

    # No publica `ports:` al host: solo accesible vía Caddy y vía red `homelab`.
    expose:
      - "8080"

    environment:
      TZ: ${TZ}
      # Auth nativa basada en data/users.yml (bcrypt + TOTP).
      DOZZLE_AUTH_PROVIDER: simple
      # Acciones mutantes (start/stop/restart, web shell) DESHABILITADAS.
      # La operación se hace por SSH + Compose (auditable).
      DOZZLE_ENABLE_ACTIONS: "false"
      # Igual: shell embebido apagado.
      DOZZLE_ENABLE_SHELL: "false"
      # Nivel de logs propios.
      DOZZLE_LEVEL: info
      # Endpoint de health (default /healthz, explícito para descubribilidad).
      DOZZLE_HEALTHCHECK_PATH: /healthz
      # Modo de descubrimiento de contenedores: solo el host local (sin agentes).
      DOZZLE_MODE: server
      # Hostname mostrado en la UI (útil si en el futuro hay agentes).
      DOZZLE_HOSTNAME: pi5
      # Ruta donde Dozzle persiste users.yml + sesiones.
      DOZZLE_BASE: /

    volumes:
      # Socket de Docker en SOLO LECTURA. La UI no expone acciones de mutación
      # (DOZZLE_ENABLE_ACTIONS=false), así que aunque la API podría aceptar
      # verbos POST, no hay forma de invocarlos.
      - /var/run/docker.sock:/var/run/docker.sock:ro
      # Datos persistentes (users.yml + sesiones).
      - /mnt/hd2t/apps/dozzle/data:/data

    networks:
      - homelab

    healthcheck:
      # Dozzle expone /healthz nativo.
      test: ["CMD", "/dozzle", "healthcheck"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s

    labels:
      homelab.role: "log-viewer"
      homelab.backup: "true"   # users.yml; respaldar.
      com.centurylinklabs.watchtower.enable: "true"

networks:
  homelab:
    external: true
```

> **Sobre `DOZZLE_HEALTHCHECK_PATH` y `/dozzle healthcheck`**. La imagen incluye un binario `dozzle` con un subcomando `healthcheck` que hace una petición HTTP local a `/healthz` y devuelve exit code apropiado. Es la forma idiomática y se prefiere a un `wget` artesanal (no hay `wget` ni `curl` en la imagen scratch-like de Dozzle).

> **Sobre `user: "1000:1000"` y `group_add: ["${DOCKER_GID}"]`**. Es la pareja clave para que esto funcione sin privilegios escalados. El UID `1000` no tiene de por sí permiso sobre el socket; ganarlo añadiéndose al grupo `docker` con `group_add` y declarándolo en `.env` evita escribir el GID en git (puede variar entre máquinas). El GID se obtiene con `getent group docker | cut -d: -f3` y se pone en `stacks/dozzle/.env`.

> **Sobre `DOZZLE_MODE: server`**. Dozzle 8 puede correr en modo `server` (lee el socket local + acepta agentes remotos opcionales) o `agent` (expone el socket sobre TLS para que un server remoto se conecte). El homelab es single-host: `server` es la única opción razonable. La alternativa `agent` queda como diseño desbloqueable si llega un segundo Pi.

> **Sobre `DOZZLE_HOSTNAME: pi5`**. Cosmético hoy (sin agentes, hay un solo nodo); si en el futuro hay un segundo host, este string aparecerá como tag de filtro en la UI.

### `stacks/dozzle/.env.example`

```bash
# stacks/dozzle/.env.example
# Variables específicas del stack Dozzle. Las generales (TZ, DOMAIN_LAN)
# vienen del .env GLOBAL del homelab.

# GID del grupo `docker` en el host. Se obtiene con:
#   getent group docker | cut -d: -f3
# Típicamente 998 o 999 en Raspberry Pi OS / Debian. Es el GID que tiene
# permiso de lectura/escritura sobre /var/run/docker.sock; el contenedor se
# añade a este grupo (group_add) para poder leer el socket sin privilegios.
DOCKER_GID=998

# Nada más vive aquí. Las contraseñas de admin/viewer y los secrets TOTP
# están en /mnt/hd2t/apps/dozzle/data/users.yml (bcrypt + TOTP, fuera de git).
```

### Drop-in de Caddy: `stacks/caddy/conf.d/06-dozzle.caddy`

```caddy
# /etc/caddy/conf.d/06-dozzle.caddy — bloque LAN para Dozzle.
# Documentado en docs/05-monitorizacion/06-dozzle.md.

dozzle.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Toda la app pasa por Authelia two_factor. No hay endpoints de bypass:
    # Dozzle no tiene API máquina-a-máquina ni status page pública. Si en
    # el futuro se quiere scrape /metrics desde Prometheus (Dozzle 8 lo
    # expone en /metrics), añadir un @bypass aquí con whitelist por IP de
    # Prometheus + Basic auth interna.
    handle {
        import authelia_two_factor

        reverse_proxy http://dozzle:8080 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
            # SSE / WebSocket: el streaming de logs de Dozzle usa
            # Server-Sent Events sobre HTTP/2; los headers Connection/Upgrade
            # se preservan por si en el futuro Dozzle migra a WebSocket.
            header_up Connection {http.request.header.Connection}
            header_up Upgrade {http.request.header.Upgrade}
            # Desactivar buffering: el streaming de logs debe llegar línea
            # a línea, no acumularse en un buffer reverse_proxy.
            flush_interval -1
        }
    }
}
```

> **Sobre `flush_interval -1`**. Caddy por defecto buferea respuestas pequeñas para mejor rendimiento. Para SSE eso se traduce en *"los logs aparecen en bloques"* (el navegador ve la primera línea 30 s tarde). `flush_interval -1` deshabilita el buffer y los bytes salen en cuanto los emite el upstream. Es el equivalente a `proxy_buffering off` de Nginx.

> **Sobre la ausencia de bypass**. A diferencia de `uptime.${DOMAIN_LAN}` (que tiene `/api/push/*`, `/api/badge/*`, `/metrics` fuera de Authelia), Dozzle es 100 % UI: no hay endpoint que un cron o un scrapper externo necesite consumir. Toda la superficie pasa por la cookie de Authelia. Esto simplifica el drop-in.

> **`access_control` en Authelia**. Recordar añadir **`dozzle.${DOMAIN_LAN}`** al bloque `two_factor` de `configuration.yml` de Authelia.

### Generar `users.yml` y desplegar

```bash
# Directorio de datos
sudo install -d -o 1000 -g 1000 -m 0750 /mnt/hd2t/apps/dozzle
sudo install -d -o 1000 -g 1000 -m 0750 /mnt/hd2t/apps/dozzle/data

# Generar la entrada YAML para el usuario `admin` con bcrypt:
docker run --rm -ti amir20/dozzle:v8.13.7 generate \
    admin \
    --password 'PASTE_LONG_PASSWORD_HERE' \
    --email 'admin@homelab.lan' \
    --name 'Admin' > /tmp/users-admin.yml

# Generar la entrada YAML para `viewer` (read-only):
docker run --rm -ti amir20/dozzle:v8.13.7 generate \
    viewer \
    --password 'PASTE_OTHER_LONG_PASSWORD' \
    --email 'viewer@homelab.lan' \
    --name 'Viewer' > /tmp/users-viewer.yml

# Construir users.yml combinando ambos. La estructura exacta depende del
# salida de `dozzle generate`; típicamente algo así:
#
# users:
#   admin:
#     email: admin@homelab.lan
#     name: Admin
#     password: $2a$11$...
#   viewer:
#     email: viewer@homelab.lan
#     name: Viewer
#     password: $2a$11$...
#     filter: ""           # filtros opcionales de containers visibles
#
sudo install -o 1000 -g 1000 -m 0600 /dev/null \
    /mnt/hd2t/apps/dozzle/data/users.yml
sudoedit /mnt/hd2t/apps/dozzle/data/users.yml
# Pegar contenido de /tmp/users-*.yml combinado bajo la clave `users:`.

# Limpiar los temporales (contienen los hashes ya en disco final)
rm -f /tmp/users-admin.yml /tmp/users-viewer.yml

# Drop-in de Caddy
cd /home/homelab/homelab
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/06-dozzle.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/06-dozzle.caddy

# .env del stack: rellenar DOCKER_GID con el real del host
echo "DOCKER_GID=$(getent group docker | cut -d: -f3)" \
    > stacks/dozzle/.env
chmod 0600 stacks/dozzle/.env

# Añadir dozzle.${DOMAIN_LAN} a access_control.rules de Authelia (two_factor).
sudo $EDITOR /mnt/hd2t/apps/authelia/config/configuration.yml
docker logs authelia --tail 20 | grep -i 'reloaded'

# Validar Caddy antes de levantar
docker exec caddy caddy validate --config /etc/caddy/Caddyfile

# Levantar Dozzle
docker compose \
    -f stacks/dozzle/docker-compose.yml \
    --env-file .env --env-file stacks/dozzle/.env \
    up -d

# Recargar Caddy
docker kill --signal=SIGUSR1 caddy
```

Tras `up -d`:

```bash
docker ps --filter name=dozzle
# CONTAINER ID  IMAGE                    STATUS                 PORTS    NAMES
# ...           amir20/dozzle:v8.13.7    Up 30 seconds (healthy)         dozzle

docker compose -f stacks/dozzle/docker-compose.yml logs --tail 20 dozzle
# level=info ts=... msg="Dozzle version v8.13.7"
# level=info ts=... msg="Listening on :8080"
# level=info ts=... msg="Auth provider: simple, users loaded: 2"
```

---

## Configuración

### 1) Setup inicial (login + TOTP)

Desde un cliente de la LAN con la CA interna ya instalada:

```text
1. Abrir https://dozzle.lan/
2. Caddy redirige a https://auth.lan/?rd=https://dozzle.lan/ (sin sesión).
3. Login en Authelia con `homelab` + TOTP.
4. Authelia escribe la cookie en `.lan` y redirige de vuelta.
5. Dozzle muestra su propia pantalla de login (auth interna `simple`).
6. Login con `admin` + contraseña fuerte (≥ 16 chars, gestor).
7. Settings → Security → Enable Two Factor Authentication
   → Scan QR con Authy/Bitwarden → introducir TOTP de 6 dígitos.
8. A partir de ahora, login admin pide 4 factores totales.
```

### 2) Verificar que ve los contenedores

En la columna izquierda deben aparecer **todos** los contenedores del host (`caddy`, `pihole`, `unbound`, `authelia`, `prometheus`, `grafana`, `node-exporter`, `cadvisor`, `uptime-kuma`, `dozzle` mismo). Hacer click en `caddy` debe mostrar el stream de logs en vivo. Si `caddy` está sirviendo peticiones, las líneas de access log aparecen en cuanto se generan.

> **Si la lista está vacía**: el contenedor no tiene permisos sobre `/var/run/docker.sock`. Ver "Errores frecuentes" → "La lista de contenedores está vacía".

### 3) Filtros y atajos

Dozzle expone shortcuts y URL params útiles para incluir en bookmarks:

| Acción | Forma |
|---|---|
| Buscar texto en el stream actual | `/` (atajo de teclado en la UI) |
| Filtrar por palabra clave (URL) | `https://dozzle.lan/container/<id>?filter=ERROR` |
| Pausar / continuar el stream | tecla `Espacio` |
| Saltar al final | tecla `End` |
| Anclar línea (compartir) | click en el timestamp → URL fragmento `#<lineid>` |

### 4) Crear monitor `dozzle-internal` en Uptime Kuma

Cerrar el bucle de observabilidad: si Dozzle se cae, queremos enterarnos. Idealmente desde Uptime Kuma (no desde Dozzle viéndose a sí mismo, que es circular).

```text
Uptime Kuma → Add New Monitor
  Monitor Type:    HTTP(s)
  Friendly Name:   dozzle-internal
  URL:             http://dozzle:8080/healthz
  Interval:        60s
  Retries:         2
  Notifications:   telegram-homelab
  Tags:            monitorización, internos
→ Save
```

Opcionalmente, monitor externo:

```text
  Friendly Name:   dozzle-external
  URL:             https://dozzle.lan/healthz
  Interval:        120s
  Accepted Status Codes: 200,302,401
  (302/401 esperado si Authelia cubre /healthz; preferible que no — ver nota.)
```

> **Nota sobre `dozzle-external`**. Si la regla `(authelia_two_factor)` en el drop-in cubre **toda** `dozzle.lan`, también cubre `/healthz` y un check externo sin sesión recibe 302 hacia `auth.lan`. Para que el monitor externo dé 200 limpio, se podría añadir un `@bypass_authelia path /healthz` al drop-in, pero eso significa que `/healthz` queda público en LAN — aceptable (no expone información sensible). Si se hace, añadirlo análogo al patrón de `uptime.lan`. Si no se hace, el monitor externo solo confirma "Caddy + Authelia están vivos", no "Dozzle está vivo": para "Dozzle está vivo", basta el monitor `dozzle-internal`.

### 5) (Opcional) Activar `/metrics` para Prometheus

Dozzle 8 expone métricas Prometheus en `/metrics` (counts de containers monitorizados, bytes leídos del socket, errores de stream). Para scrape-arlas hay que abrir un bypass de Authelia equivalente al patrón de Uptime Kuma. **Diferido** salvo demanda real: el dashboard "cuántos bytes de log por minuto" no aporta a un homelab pequeño.

### 6) Operación diaria

| Acción | Comando / Ruta |
|---|---|
| Ver dashboard | `https://dozzle.lan/` |
| Ver salud del contenedor | `docker ps --filter name=dozzle` |
| Tail de logs propios (cuando la UI no levanta) | `docker logs -f dozzle` |
| Reiniciar | `docker compose -f stacks/dozzle/docker-compose.yml restart dozzle` |
| Añadir un usuario | editar `/mnt/hd2t/apps/dozzle/data/users.yml`, regenerar bcrypt con `dozzle generate ...`, `docker compose restart dozzle` |
| Cambiar contraseña | misma línea: regenerar bcrypt y sustituir en `users.yml` |
| Resetear TOTP de un usuario (perdió el authenticator) | borrar el campo `totpSecret` (o equivalente) de `users.yml`, restart |
| Verificar GID del socket coincide | `getent group docker; docker inspect dozzle --format '{{.HostConfig.GroupAdd}}'` |

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/dozzle/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/dozzle/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/dozzle/.env` | microSD | `homelab:homelab` | `0600` | `DOCKER_GID` real del host (no en git). |
| `/home/homelab/homelab/stacks/caddy/conf.d/06-dozzle.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy. |
| `/mnt/hd2t/apps/dozzle/data/` | hd2t | `1000:1000` | `0750` | Directorio de datos. |
| `/mnt/hd2t/apps/dozzle/data/users.yml` | hd2t | `1000:1000` | `0600` | Cuentas locales (bcrypt + TOTP). **Sensible**. |
| `/mnt/hd2t/apps/dozzle/data/sessions.json` (o equivalente) | hd2t | `1000:1000` | `0600` | Sesiones activas. Regenerable. |
| `/var/run/docker.sock` | host | `root:docker` | (socket) | Socket de Docker, montado `:ro`. |

> **Tamaño esperado**. `users.yml` con 2 cuentas pesa < 1 KiB. El total del bind mount, incluyendo sesiones y preferencias, no debería pasar de **unos pocos KiB**. Es ridículo; vive en hd2t por convención (todos los datos de servicios en hd2t), no por necesidad de espacio.

> **Logs históricos accesibles desde Dozzle**: viven en `/var/lib/docker/containers/<id>/<id>-json.log` (microSD), gestionados por Docker, **no** por Dozzle. La rotación está fijada a `max-size: 10m`, `max-file: 3` (Fase 2): 30 MiB por contenedor, ~300 MiB total con 10 contenedores. Si el operador necesita logs más antiguos, debe activar Loki o aumentar `max-file` (a coste de microSD).

> **Sensibilidad de `users.yml`**. Contiene hashes bcrypt de contraseñas y secretos TOTP en plano (los secretos TOTP no son hash; son la semilla con la que el authenticator deriva los códigos). Quien tenga este fichero puede generar TOTPs válidos. Por eso `0600` y por eso entra en backup cifrado.

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/dozzle/docker-compose.yml`, `.env.example` | Versionados. |
| `stacks/caddy/conf.d/06-dozzle.caddy` | Versionado. |
| Decisiones (versión, socket `:ro`, auth `simple`, acciones off) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Por qué |
|---|---|---|
| `/mnt/hd2t/apps/dozzle/data/users.yml` | **Sí** | Recuperar exige rehacer cuentas + reescanear TOTP en cada authenticator. Pequeño pero costoso de regenerar. |
| `/mnt/hd2t/apps/dozzle/data/sessions.json` | No estrictamente. | Si se restaura, todos los usuarios se relogean — molestia menor. Se respalda *de oficio* (todo `data/` entra al snapshot Borg). |

> **Restore tras pérdida del contenedor (datos intactos en `hd2t`)**:
>
> ```bash
> docker compose -f /home/homelab/homelab/stacks/dozzle/docker-compose.yml up -d --force-recreate
> # Dozzle reusa /mnt/hd2t/apps/dozzle/data: users.yml está, las cuentas
> # siguen activas. Cero pérdida.
> ```

> **Restore tras pérdida total**:
>
> 1. Recrear Fase 1, 2, 3 y 4.
> 2. Restaurar `/mnt/hd2t/apps/dozzle/data/` desde Borg.
> 3. Verificar permisos: `sudo chown -R 1000:1000 /mnt/hd2t/apps/dozzle/data && sudo chmod 0600 /mnt/hd2t/apps/dozzle/data/users.yml`.
> 4. Rellenar `stacks/dozzle/.env` con `DOCKER_GID` del nuevo host.
> 5. `docker compose -f stacks/dozzle/docker-compose.yml up -d`.
> 6. Login en `https://dozzle.lan/` con las credenciales originales.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `https://dozzle.lan/` da 502 tras Authelia | El contenedor está en `start_period`, todavía levantándose. | Esperar 15 s. `docker logs dozzle --tail 20` debe mostrar `Listening on :8080`. |
| La lista de contenedores está vacía / "Cannot connect to Docker" en la UI | El contenedor no puede leer `/var/run/docker.sock`: GID mal o bind mount ausente. | `docker exec dozzle id` (debe listar el GID del grupo `docker` del host). Si no, revisar `DOCKER_GID` en `stacks/dozzle/.env` y hacer `getent group docker | cut -d: -f3` para obtener el real. Recrear con `docker compose up -d --force-recreate`. |
| Login propio de Dozzle rechaza la contraseña correcta | El bcrypt en `users.yml` se generó con un coste / formato distinto al esperado. | Regenerar con `docker run --rm -ti amir20/dozzle:v8.13.7 generate ...` (versión exacta de la imagen) y sustituir la línea. |
| TOTP de Dozzle dice "Invalid code" siempre | Reloj del host desfasado (TOTP es time-based). | `timedatectl` debe mostrar `System clock synchronized: yes`. Si no, revisar Fase 1 (`chrony`/`systemd-timesyncd`). |
| Logs aparecen "a tirones" / con retraso de 30 s | Caddy está bufferando la respuesta SSE. | Verificar `flush_interval -1` en el bloque `reverse_proxy` del drop-in. Sin él, Caddy acumula varios KiB antes de enviar. |
| Logs históricos de un contenedor muerto no aparecen | Docker pudo haber eliminado el contenedor con `docker rm` (el `json-file` se borra con él). Dozzle solo ve contenedores vivos o con histórico aún en disco. | Comportamiento esperado: si se elimina un contenedor (no solo se para), su histórico de logs se pierde. Para no perderlo, no usar `docker rm` salvo limpieza explícita; con `restart: unless-stopped` y `docker compose down/up`, el histórico persiste. |
| Tras `docker compose pull` la app no levanta y los logs muestran error de schema en `users.yml` | Cambio de formato del fichero entre minors. | Restaurar `users.yml` desde Borg, reanclar tag al previo, leer changelog antes de subir. Como con Uptime Kuma: **siempre** `cp users.yml /tmp/users-pre-upgrade.yml` antes de `pull`. |
| Permission denied sobre `/data/users.yml` en el log de arranque | El bind mount tiene un owner distinto a UID 1000 o el fichero `0644` cuando se esperaba `0600`. | `sudo chown 1000:1000 /mnt/hd2t/apps/dozzle/data/users.yml && sudo chmod 0600 /mnt/hd2t/apps/dozzle/data/users.yml`. |
| Cualquier usuario que pase Authelia ve logs sensibles | Defensa de un solo factor (Authelia); la auth de Dozzle no se activó o `DOZZLE_AUTH_PROVIDER=none` por error. | Verificar `docker exec dozzle env | grep DOZZLE_AUTH_PROVIDER` (debe ser `simple`). Si no, revisar `docker-compose.yml` y recrear. |
| Dozzle expone `/healthz` sin auth y un curl externo a `dozzle.lan/healthz` da 401/302 | Comportamiento esperado: el bloque Caddy fuerza Authelia para todo. | Si se quiere `/healthz` sin auth, añadir un bypass en el drop-in (ver "Configuración → 4"). Tener en cuenta que `/healthz` no expone información sensible. |
| Logs propios de Dozzle muestran "permission denied: /var/run/docker.sock" | El daemon del host no permite al GID configurado. | `ls -l /var/run/docker.sock` debe ser `srw-rw---- root docker`. Confirmar `getent group docker | cut -d: -f3` coincide con `DOCKER_GID`. En algunos hosts (Snap-installed Docker, rootless Docker) la ruta del socket es distinta — ajustar el bind mount. |
| Recién entró un contenedor nuevo al sistema (`docker compose up -d` de otro stack) y no aparece en Dozzle | Dozzle escucha eventos del socket; debería aparecer instantáneo. Si no, F5. | Si tras F5 sigue sin aparecer, `docker exec dozzle ls -l /var/run/docker.sock` (debe existir y ser legible). Reiniciar Dozzle como último recurso. |

---

## Decisiones que **no** se toman en este documento

- **Loki + Promtail / agregador centralizado**: se mantiene la decisión de "sin agregador" para esta Fase. Reabrible si en una Fase futura el operador pide búsqueda full-text histórica de meses. El stack mínimo serían Loki single-binary en `hd2t` + Promtail leyendo `/var/lib/docker/containers/*/*-json.log` + datasource Loki en Grafana — no es trivial pero está bien documentado upstream.
- **`docker-socket-proxy` (Tecnativa)**: diferido. Se reabre cuando llegue el segundo consumidor del socket (Watchtower si se decide automatizar updates de imagen, Portainer si se decide GUI completa). Un proxy compartido vale para todos.
- **`DOZZLE_ENABLE_ACTIONS=true` / shell embebido**: descartado por la ergonomía-vs-auditoría discutida arriba. Reabrible si el operador decide que la pérdida de rastro vale la conveniencia.
- **Modo agente / multi-host**: el homelab es single-host. Reabrible cuando llegue un segundo nodo (segunda Pi, NAS Docker, máquina virtual). Diseño desbloqueable: `dozzle-agent` corre en el nuevo host con su propio cert TLS, el `dozzle` server actual lo añade a su lista de agentes con `DOZZLE_REMOTE_AGENT=tls://newhost:7007` (sintaxis exacta a confirmar contra docs upstream del momento).
- **Forward-auth con Authelia inyectando `Remote-User`**: descartado por mantener defensa en profundidad. Reabrible si Authelia gana grupos y se quiere SSO unificado sin doble login a través de toda la suite del homelab.
- **Branding / customización de UI** (logo del homelab, colores): Dozzle 8 lo permite vía `data/`, pero es ceremonia. Reabrible para "casa con varios usuarios".
- **Filtros de containers visibles por usuario** (`viewer` solo ve `caddy` y `pihole`): Dozzle 8 soporta `users.yml` con `filter` por usuario. Innecesario hoy (un solo operador real). Reabrible cuando llegue un usuario "técnico amigo" con acceso parcial.
- **Aletras basadas en patrones de log** (regex que dispare Telegram cuando aparezca `panic:`): Dozzle no lo hace. Para eso harían falta `mtail`, `fluentbit` con outputs custom, o Loki + alerting. Diferido.
- **Auto-rotación / archivado a hd2t** de logs viejos: la rotación la hace Docker (`max-size`, `max-file` en `daemon.json`). Si en el futuro se quieren conservar, el camino es Loki, no Dozzle.
- **Exposición pública de la status de containers**: incompatible con LAN+Tailscale del homelab. No aplica.

---

## Verificación Final

Antes de pasar a la siguiente Fase:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/dozzle/docker-compose.yml ps` | `dozzle ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect dozzle --format '{{.Config.Image}}'` | `amir20/dozzle:v8.13.7` |
| Conectado a `homelab` | `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` | incluye `dozzle`, `caddy`, `authelia` |
| Sin puertos publicados al host | `docker port dozzle` | salida vacía |
| Bind mounts correctos | `docker inspect dozzle --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Mode}}){{"\n"}}{{end}}'` | `data → /data (rw)`, `docker.sock → /var/run/docker.sock (ro)` |
| Acciones DESHABILITADAS | `docker exec dozzle env \| grep DOZZLE_ENABLE_ACTIONS` | `DOZZLE_ENABLE_ACTIONS=false` |
| Auth provider `simple` | `docker exec dozzle env \| grep DOZZLE_AUTH_PROVIDER` | `DOZZLE_AUTH_PROVIDER=simple` |
| GID del grupo docker añadido | `docker inspect dozzle --format '{{.HostConfig.GroupAdd}}'` | `[<DOCKER_GID>]` (no vacío) |
| Permisos de `users.yml` | `sudo stat -c '%a %u:%g' /mnt/hd2t/apps/dozzle/data/users.yml` | `600 1000:1000` |
| `dozzle.lan` resuelve al IP de la Pi | `dig +short dozzle.lan @192.168.1.2` | `192.168.1.10` |
| Caddy sirve `dozzle.lan` con cert de la CA interna | `echo \| openssl s_client -connect dozzle.lan:443 -servername dozzle.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| Health endpoint responde (interno) | `docker exec dozzle /dozzle healthcheck && echo ok` | `ok` |
| Acceso a `dozzle.lan` vía Authelia | navegador con CA y sesión TOTP | Authelia + Dozzle login → dashboard con la lista de contenedores |
| 2FA propio activo | UI → Settings → Security | `Two Factor Authentication: Enabled` |
| Streaming en vivo funciona | UI → click en `caddy` → generar tráfico (`curl -k https://pihole.lan/`) | Líneas de access log aparecen en menos de 1 s |
| `flush_interval -1` aplicado | `curl -ksN https://dozzle.lan/api/events/stream -b "<cookie>"` (durante un stream) | Bytes llegan línea a línea, no en bloques |
| Monitor `dozzle-internal` en Uptime Kuma | UI Uptime Kuma → Dashboard | `dozzle-internal` en verde |
| Logs propios visibles desde la propia UI | UI → click en `dozzle` | Aparecen sus líneas de arranque (`Listening on :8080`, `Auth provider: simple`) |

---

## Referencias

- Repositorio Dozzle: https://github.com/amir20/dozzle
- Documentación oficial: https://dozzle.dev/
- Imagen oficial multi-arch: https://hub.docker.com/r/amir20/dozzle (pin: `v8.13.7`)
- Guía de auth `simple` y `users.yml`: https://dozzle.dev/guide/authentication
- Guía de modo agente / multi-host: https://dozzle.dev/guide/agent
- Variables de entorno y flags: https://dozzle.dev/guide/environment-variables
- Documentos relacionados:
  - `docs/02-base/01-docker.md` — driver de logs `json-file` con rotación.
  - `docs/03-red/04-caddy.md` — virtual host `dozzle.lan`, snippet `(authelia_two_factor)`, `flush_interval -1` para SSE.
  - `docs/04-seguridad/01-authelia.md` — política `two_factor` para `dozzle.lan`.
  - `docs/05-monitorizacion/05-uptime-kuma.md` — monitor `dozzle-internal` que cierra el bucle de observabilidad.
