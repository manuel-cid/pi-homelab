# Uptime Kuma

## Descripción

Cerrados `01-prometheus.md`, `02-grafana.md`, `03-node-exporter.md` y `04-cadvisor.md`, el homelab ya **ve hacia adentro**: la TSDB ingesta métricas del host (`pi5`) y de cada contenedor activo, y Grafana las pinta en dashboards (Node Exporter Full, Cadvisor exporter, Homelab Overview). Esa es la mitad de la observabilidad: la **monitorización pasiva**, basada en métricas que los propios servicios emiten. Lo que Prometheus **no responde bien** son preguntas sintéticas del tipo "¿está Jellyfin sirviendo HTTP 200 desde el punto de vista de un cliente externo?", "¿el dominio `pihole.lan` resuelve y devuelve HTML?", "¿el certificado de Caddy expira en menos de 30 días?", "¿la VPN Tailscale aún ve a la Pi?". Esto es **monitorización activa** (probing): lanzar peticiones reales contra los endpoints, medir latencia/disponibilidad, alertar cuando algo falle.

Este documento despliega **Uptime Kuma**, el sondeador activo y notificador del homelab. Su rol concreto:

1. **Lanzar checks periódicos** (cada 60 s por defecto) contra cada servicio del homelab usando varios *monitor types*: HTTP/HTTPS (con verificación de status, keyword, cabecera), ping (ICMP), TCP, DNS, Docker (estado del contenedor vía socket), Push (heartbeat reverso para tareas cron), Steam/JSON Query/etc. (irrelevantes aquí).
2. **Mantener un histórico de uptime** por monitor (% de disponibilidad a 24 h / 7 d / 30 d, gráfica de latencia, eventos `up`/`down` con timestamp y duración). El histórico vive en una **base de datos SQLite** propia en `hd2t`, con retención configurable (default: indefinido — se ajusta en este documento).
3. **Notificar caídas y recuperaciones** vía proveedores configurables. En este homelab se activan dos: **Telegram** (canal principal para el operador, móvil siempre encima) y **email vía Mailrise** (canal secundario, archivable). Mailrise es un puente SMTP→Apprise que se desplegará en Fase 11; aquí se deja la configuración del notificador como placeholder hasta que ese stack llegue.
4. **Servir una *status page* pública en LAN** (`https://status.${DOMAIN_LAN}/`) con un subconjunto curado de monitores (los servicios "para humanos": Jellyfin, Stash, Pi-hole UI, Grafana, Vaultwarden cuando llegue, etc.), exenta de Authelia. Es la página que el operador (o un familiar de la casa) abre desde el sofá para saber "¿qué tal está la infraestructura?" sin pasar por login.
5. **Cerrar el ciclo de alerting de Fase 5** sin tener que desplegar Alertmanager: Prometheus + Grafana ven *qué* pasa; Uptime Kuma avisa *cuando* algo se cae. Para 5 servicios y 1–3 usuarios, esta combinación cubre el 95 % del caso de uso. Alertmanager queda explícitamente diferido (ver `01-prometheus.md`, "Decisiones que no se toman").

Lo que este documento **no** decide:

- **Métricas de rendimiento internas** (CPU, RAM, disco). Eso ya vive en Prometheus + Node Exporter + cAdvisor. Uptime Kuma sólo dice "el endpoint responde / no responde" y "tarda X ms"; no entra en por qué un servicio va lento si responde 200.
- **Logs de los servicios**. Eso lo cubre Dozzle (`06-dozzle.md`); Uptime Kuma no es un agregador de logs ni un visor.
- **Alertmanager**: reglas Prometheus + ruteo de notificaciones. Diferido (ver razonamiento en `01-prometheus.md`). Uptime Kuma cubre la parte de "avisar cuando algo se cae" con notificaciones por monitor; las reglas complejas (ratios, cuantiles, ventanas) quedarían para Alertmanager.
- **Mailrise**: el contenedor que traduce SMTP a Apprise (Telegram/ntfy/Gotify/etc.) se documenta en Fase 11 (`docs/11-mantenimiento/...`). En este documento se configura el notificador SMTP de Uptime Kuma apuntando a `mailrise:8025` y se anota que el target estará `down` hasta entonces (no rompe nada: las notificaciones email simplemente se acumulan como `pending` y se entregan cuando Mailrise exista).
- **Status page expuesta en internet**: el homelab es LAN+Tailscale, sin puertos abiertos (`SERVICES.md`). La status page es accesible desde la LAN y desde el tailnet del operador, nada más.
- **Páginas de mantenimiento programado**: Uptime Kuma tiene "Maintenance windows" para silenciar checks durante backups, etc. Se mencionan en "Operación diaria" pero no se programa ninguna ventana en este documento (se hace ad-hoc cuando llegue el primer mantenimiento real).
- **Push monitors para cron jobs** (Borgmatic post-hook, etc.). El patrón está documentado aquí, pero los `curl` reales que cierran el lazo viven en los stacks de cada cron (Fase 7 para Borgmatic).
- **Reglas de escalado** ("si Telegram no responde, usar email"). Uptime Kuma no implementa fallback nativo; cada notificador es independiente. Para el homelab basta con configurar los dos en cada monitor crítico.

Cuando este documento se haya aplicado, el operador puede:

- Abrir `https://uptime.${DOMAIN_LAN}/` desde la LAN (con login Authelia 2FA + login propio de Uptime Kuma + 2FA propio) y ver la dashboard con el listado de monitores y su estado en vivo.
- Apagar el contenedor de Pi-hole (`docker stop pihole`) y, en menos de 2 minutos, recibir un mensaje de Telegram: *"❌ Pi-hole UI is down (HTTP request returned status 502)"*. Al volver a levantarlo, recibe el correspondiente *"✅ Pi-hole UI is up"*.
- Abrir `https://status.${DOMAIN_LAN}/` (sin login) y ver una página pública con los monitores marcados como "públicos" (Jellyfin, Stash, Pi-hole, Grafana, etc.) con sus iconitos verdes/rojos.
- Crear un push monitor llamado `borgmatic-nightly`, copiar el token, y añadir al final de su cron de Borgmatic una llamada `curl -fsS https://uptime.${DOMAIN_LAN}/api/push/<token>?status=up&msg=ok` — si una noche el cron falla y no llega el push, Uptime Kuma alerta a las 24 h + 5 min.

> **Recordatorio de alcance**: Uptime Kuma escucha **solo** en la red Docker `homelab` (`expose: 3001`) y **no publica `ports:` al host**. La UI principal vive tras Caddy + Authelia (`uptime.${DOMAIN_LAN}`). La status page pública vive tras Caddy **sin Authelia** (`status.${DOMAIN_LAN}`), pero sigue siendo solo LAN+Tailscale. Ningún cambio en el router doméstico, ninguna exposición pública de internet.

---

## Requisitos Previos

- **Fase 2** completa (Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN=lan`).
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre automáticamente `uptime.${DOMAIN_LAN}` y `status.${DOMAIN_LAN}` sin tocar Pi-hole).
  - Caddy desplegado y los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` en `Caddyfile`.
- **Fase 4** completa, en particular:
  - Authelia desplegado con el snippet `(authelia_two_factor)` en `stacks/caddy/conf.d/01-authelia.caddy`.
  - `fail2ban` configurado con el jail `authelia` (la status page pública es un nuevo virtual host: si un atacante prueba a fuerza bruta sobre Authelia desde un cliente LAN comprometido, sigue cubierto).
- **Fase 5 docs 01–04** aplicados. No es dependencia técnica (Uptime Kuma sondea endpoints HTTP, no consulta Prometheus directamente para los monitores básicos), pero algunos monitores opcionales (sección "Configuración → 5") usan PromQL contra Prometheus, y la integración como *target* (Prometheus scrape-a `/metrics` de Uptime Kuma) sólo tiene sentido con Prometheus ya activo.
- **Bot de Telegram creado** con `@BotFather`:
  - `/newbot` → nombre `homelab-uptime-bot` (o similar) → handle `pi5_uptime_bot` → BotFather devuelve un token `123456789:AAH...`.
  - El operador escribe **al bot** un mensaje cualquiera (`/start`) — sin esto, `chat_id` no existe.
  - Obtener el `chat_id` con `curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[].message.chat.id'`.
- Disco `hd2t` montado en `/mnt/hd2t` con al menos **500 MiB** libres reservados para Uptime Kuma (la SQLite crece poco: ~50 MB con 50 monitores y 6 meses de histórico; el resto es margen).
- Operador con la **CA interna instalada** en su navegador (`03-red/04-caddy.md` → "Instalar el root CA en los clientes").

Comprobaciones rápidas:

```bash
# La red Docker compartida existe
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Caddy, Authelia y Prometheus están corriendo
docker ps --filter name=caddy --filter name=authelia --filter name=prometheus --format '{{.Names}} {{.Status}}'

# uptime.lan y status.lan resuelven al IP de la Pi (gracias al comodín de Pi-hole)
dig +short uptime.lan @192.168.1.2
# 192.168.1.10
dig +short status.lan @192.168.1.2
# 192.168.1.10

# Espacio en hd2t
df -h /mnt/hd2t | awk 'NR==2 {print $4 " libres"}'

# Token de Telegram válido (sustituir <TOKEN>): debe devolver `ok: true`
curl -s "https://api.telegram.org/bot<TOKEN>/getMe" | jq '.ok'
# true
```

---

## Decisión: imagen y versión

Uptime Kuma se distribuye desde Docker Hub (`louislam/uptime-kuma`) con builds multi-arch (`amd64`, `arm64`, `armv7`). En la Pi 5 (aarch64) se usa el manifest `arm64`.

| Tag | Cuándo usar | Decisión aquí |
|---|---|---|
| `latest` | Demos. | Descartado (convención de Fase 2). |
| `2` | "Última 2.x". | Descartado: la rama 2.x está en *beta* en el momento de redactar y cambia esquemas de DB sin notice clara. |
| `1` | "Última 1.x estable". | Descartado: minors han traído cambios incompatibles en `data/db/kuma.db` que requieren backup previo. |
| `1.23.x` | Última `1.23.x` estable. | Aceptable; rama LTS de facto, soporte upstream activo. |
| `1.23.16` (ejemplo) | Versión exacta `MAYOR.MENOR.PARCHE`. | **Aceptado** como compromiso entre reproducibilidad y mantenimiento. |
| `2.0.0-beta.x` | Probar la rama 2 con la nueva UI y MariaDB. | Diferido: cuando 2.0 se marque como `stable` y haya documento de migración SQLite→MariaDB, se reabre. |

> **Tag exacto en uso**: `louislam/uptime-kuma:1.23.16`. Si en el momento de aplicar este documento existe una `1.23.x` superior con changelog limpio (sin migraciones de schema y sin cambios incompatibles en la API push), se actualiza el tag aquí y en `docker-compose.yml`. **Nunca `latest`**.

> **Por qué Uptime Kuma y no Statping / Gatus / Healthchecks.io / Cabot**. Statping (statping-ng) es comparable pero el proyecto tiene mantenimiento intermitente y la app está en Go con UI server-rendered (más austera). Gatus está bien para monitorización declarativa por YAML — atractivo para GitOps — pero su UI es muy minimalista y no tiene status pages tan pulidas; queda como reabrible si el homelab evoluciona a "todo declarativo". Healthchecks.io es excelente para *push monitors* (heartbeats de cron) pero **no** sondea servicios HTTP — es complementario, no reemplazo. Cabot está prácticamente abandonado. Uptime Kuma cubre los tres casos en una sola caja (HTTP probes + push + status pages), es activamente mantenido, tiene comunidad enorme y la UI es la mejor del segmento — gana legibilidad para uno o tres usuarios.

---

## Decisión: persistencia, base de datos y permisos

Uptime Kuma 1.x guarda **todo** su estado en una sola **base de datos SQLite** dentro del directorio `data/` de la imagen: configuración, lista de monitores, histórico de checks, usuarios, status pages, claves API, tokens push. La app es una sola pieza de Node.js (Express + socket.io + better-sqlite3); no hay Redis, no hay Postgres, no hay broker de mensajes.

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| Volumen Docker nombrado | Docker gestiona permisos. | DB acaba en `/var/lib/docker/volumes/...` (microSD), inaceptable. Backup y troubleshooting menos directos. | Descartado. |
| Bind mount en hd2t con UID interno (`1000:1000`) | DB visible, fácil de hacer `du -sh`, fácil de incluir en Borg. UID `1000` coincide con `node` dentro de la imagen y con `homelab` en el host (Fase 1). | Si la imagen futura cambia el UID, romper. | **Aceptado**. |
| Volumen + sidecar de backup | Snapshots consistentes "de fábrica". | Sobreingeniería para una SQLite < 100 MB; basta con `cp` del fichero para Borg (Uptime Kuma usa `journal_mode=WAL`, las copias son consistentes). | Descartado. |
| MariaDB externa (Kuma 2.x) | Mejor con miles de monitores y multi-instancia. | Kuma 2 aún no es `stable`; añadir MariaDB para 50 monitores es ceremonia gratis. | Diferido. |

Resultado: bind mount en `/mnt/hd2t/apps/uptime-kuma/data` con `chown 1000:1000`, modo `0750`. La SQLite vive en `data/kuma.db` con su WAL (`kuma.db-wal`) y SHM (`kuma.db-shm`).

> **`PUID`/`PGID` no aplica directamente aquí**. Uptime Kuma no expone `PUID`/`PGID` como variables de entorno (a diferencia de imágenes de LinuxServer.io). El proceso corre fijo como UID `1000` (el usuario `node` de la imagen base oficial de Node). Por suerte, el operador del homelab también es UID `1000` (Fase 1 creó `homelab` con `useradd -u 1000`), así que `chown 1000:1000` es coherente con la convención.

---

## Decisión: integración con Authelia y status page pública

Uptime Kuma tiene **autenticación propia** (login + 2FA opcional con TOTP) implementada en su backend Node. Pone delante un Authelia es **defensa en profundidad** (dos factores de autenticación independientes), pero hay una pega: los endpoints **`/api/push/...`** (heartbeat de cron) y **`/status/<slug>`** (status page pública) **no deben pedir login Authelia** o el caso de uso se rompe.

| Ruta | Auth Caddy | Auth Uptime Kuma | Justificación |
|---|---|---|---|
| `/` (raíz, dashboard del operador) | `(authelia_two_factor)` | Login + 2FA propios | Defensa en profundidad: para entrar como admin hay que pasar 4 factores totales (Authelia user/pass, Authelia TOTP, Kuma user/pass, Kuma TOTP). |
| `/dashboard*`, `/settings*`, `/socket.io*` | `(authelia_two_factor)` | Sesión propia | Idem; el `socket.io` es interno entre la SPA y el backend, va en el mismo dominio. |
| `/api/push/<token>` | **Bypass** Authelia | Token único por monitor | El cron de Borgmatic en otra máquina (o en el mismo host fuera de Docker) no tiene cookies de sesión Authelia. El token push **es** la auth. |
| `/api/badge/...` (badges SVG para README/Slack) | **Bypass** Authelia | (público por diseño) | Las badges se incrustan en wikis, Slack, Notion. Si pidieran auth, se romperían. |
| `/status/<slug>` | **Bypass** Authelia | (público por diseño del slug) | Status page pública en LAN. La privacidad la da `slug` no enumerable + LAN-only. |
| `/metrics` | **Bypass** Authelia, **whitelist** por IP de Prometheus | Basic auth con API key generada en Kuma | Prometheus llega por DNS Docker; no tiene cookie Authelia. La auth la hace el `Authorization: Basic ...` con la API key. |

La forma más limpia de implementar esto en Caddy es **dos virtual hosts**:

1. **`uptime.${DOMAIN_LAN}`**: bloque protegido por Authelia salvo `/api/push/*`, `/api/badge/*` y `/metrics`.
2. **`status.${DOMAIN_LAN}`**: bloque público (sin Authelia) que sólo expone `/status/*` y la raíz, hace `reverse_proxy` al mismo backend.

Otras opciones consideradas:

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| Un solo host (`uptime.${DOMAIN_LAN}`) con `(lan_only)` y sin Authelia | Simplicidad. | Cualquier dispositivo de la LAN (incluido el de un invitado) ve el panel admin. | Descartado: viola defensa en profundidad. |
| Un solo host con Authelia y status page con `slug` random | Una URL para todo. | Compartir una status page con la familia exige darles la URL completa con slug; cualquier sondeo HTTP en la LAN la encuentra. | Descartado por ergonomía. |
| Tres hosts (`uptime`, `status`, `push`) | Aislamiento total. | El push vive en un dominio extra sin razón funcional (mismo backend); inflación de hosts. | Descartado. |

Resultado: **dos hosts**, uno protegido (admin) y otro público (status), ambos hablando con el mismo contenedor `uptime-kuma:3001`.

> **Sobre `slug` no enumerable**. La status page pública vive en `https://status.${DOMAIN_LAN}/status/<slug>`; el slug se elige en la creación (ej. `homelab`, `casa`, `prod`). Para evitar enumeración, el slug se trata como secreto **suave**: no es información sensible (las status pages no muestran credenciales), pero tampoco se filtra adrede en públicos no controlados. La raíz `/` de `status.${DOMAIN_LAN}` redirige a la status page por defecto, así que el operador comparte simplemente `https://status.lan/`.

---

## Decisión: notificadores y plantillas

Uptime Kuma soporta ~80 proveedores de notificación nativos (Telegram, Discord, Slack, Webhook, SMTP, ntfy, Gotify, Apprise, Mattermost, etc.). En este homelab se activan **dos**, con roles claros:

| Notificador | Cuándo se usa | Configuración en este documento |
|---|---|---|
| **Telegram** | Canal **principal**; el operador lleva el móvil encima y los mensajes llegan inmediatos. Se usa para todos los monitores con criticidad ≥ media (Pi-hole, Authelia, Caddy, Jellyfin, Stash, Vaultwarden cuando llegue). | Token + chat_id → ver "Configuración → 2". |
| **Email vía Mailrise** | Canal **secundario**; archivable, búscable por threading, útil para incidentes que merecen "registro escrito". Mailrise es un puente SMTP→Apprise (Fase 11); aquí se configura SMTP a `mailrise:8025` y se acepta que las notificaciones queden encoladas hasta que Mailrise exista. | SMTP host `mailrise`, puerto `8025`, sin auth, sin TLS. |

| Opción | Pros | Contras | Veredicto |
|---|---|---|---|
| Sólo Telegram | Simplicidad, instantáneo. | Si Telegram baja (o el bot es bloqueado), no hay backup. | Aceptable como mínimo viable; pero defensa en profundidad pide un segundo canal. |
| Telegram + email vía Mailrise | Dos canales independientes (red Telegram vs SMTP/IMAP propio del proveedor de correo). | Mailrise no existe hasta Fase 11. | **Aceptado**: Mailrise como placeholder; el notificador se configura ahora y queda funcional cuando Mailrise llegue. |
| Telegram + Discord | Dos canales para el operador. | Discord tiene la misma red base que Telegram ante un fallo de internet. | Descartado: ambos dependen de "internet del operador hacia fuera"; no son independientes en la práctica. |
| Webhook genérico a un script propio | Máxima flexibilidad. | Mantener un endpoint extra, más superficie. | Diferido: si el día de mañana hace falta integrar con Home Assistant o algo casero, el webhook es la vía. |
| ntfy / Gotify auto-hospedados | Independencia total de servicios externos. | Otro stack que mantener. Telegram cubre el caso con menor esfuerzo. | Diferido a Fase 12+. |

> **Plantillas de notificación**. Kuma 1.23 permite personalizar el formato del mensaje con `{{name}}`, `{{status}}`, `{{msg}}`, `{{monitorName}}`, `{{heartbeatJSON.time}}`, etc. Para mantener la coherencia, se usa la plantilla por defecto de Kuma (concisa, ya incluye nombre, status y mensaje). Personalizar plantillas en este documento sería ceremonia; reabrible cuando el operador quiera mensajes más ricos.

> **Sobre los monitores que disparan a qué**. Un monitor puede estar enlazado a 0+ notificadores. La política para este homelab es:
> - **Servicios críticos** (Pi-hole, Caddy, Authelia, Tailscale): Telegram **+** email.
> - **Servicios de uso humano** (Jellyfin, Stash, Vaultwarden cuando llegue, Grafana): Telegram.
> - **Exporters internos** (Node Exporter, cAdvisor, Prometheus, Uptime Kuma mismo): Telegram. Si están caídos, todo lo demás también lo notará indirectamente, pero alertar antes ayuda al *post-mortem*.
> - **Push monitors** (Borgmatic, futuros crons): Telegram + email.

---

## Decisión: nivel de monitor (interno vs externo)

Uptime Kuma corre **dentro** de la red Docker `homelab`. Eso le da DNS por nombre de servicio (`pihole:80`, `jellyfin:8096`, `caddy:443`) sin ceremonia, lo cual es la vía natural para sondear servicios. Pero también hay un caso "externo": sondear `https://jellyfin.lan/` resolviendo por DNS del homelab (Pi-hole) y pasando por Caddy + TLS + cabeceras Authelia. Las dos pruebas miden cosas distintas:

| Tipo | Qué prueba | Cuándo usarlo |
|---|---|---|
| **Interno (DNS Docker)** `http://servicio:puerto/health` | Que el contenedor está vivo y atiende su puerto. | Para todo servicio: es la prueba más rápida y barata. Detecta fallos en el contenedor. |
| **Externo (DNS LAN)** `https://servicio.lan/` | Que la cadena completa funciona: DNS Pi-hole + Caddy + cert + (opcionalmente) Authelia + servicio. | Para servicios de cara al humano (Jellyfin, Stash, Pi-hole UI, Grafana). Detecta fallos de Pi-hole, Caddy o cert. |

Política para este homelab: **dos monitores por servicio crítico** (uno interno + uno externo); **un monitor interno** para los exporters/internos (Prometheus, Node Exporter, cAdvisor, Authelia internal API). Es más ruido en la lista, pero diferencia "el contenedor cayó" de "el reverse proxy cayó".

> **Detalle TLS**. Para los monitores externos a `*.lan`, Uptime Kuma necesita confiar en la CA interna del homelab (montada en Caddy, doc `03-red/04-caddy.md`). El bind mount `/mnt/hd2t/apps/caddy/etc/pki/root.crt:/etc/ssl/certs/homelab-ca.pem:ro` introducido en este compose añade el cert a `NODE_EXTRA_CA_CERTS` para que Node valide la cadena. Sin esto, los monitores HTTPS contra `*.lan` reportarían `unable to verify the first certificate` y se llenaría de falsos positivos.

---

## Stack: `stacks/uptime-kuma/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/uptime-kuma/docker-compose.yml` | microSD (git) | Stack (servicio `uptime-kuma`). |
| `stacks/uptime-kuma/.env.example` | microSD (git) | Plantilla con `UPTIME_KUMA_*` (vacío en esta fase). |
| `stacks/caddy/conf.d/05-uptime-kuma.caddy` | microSD (git) | Drop-in del bloque LAN (admin) + status page pública. |
| `/mnt/hd2t/apps/uptime-kuma/data/` | hd2t | Datos persistentes: `kuma.db`, `kuma.db-wal`, `kuma.db-shm`, `error.log`, etc. Owner `1000:1000`. |
| `/mnt/hd2t/apps/uptime-kuma/data/kuma.db` | hd2t | SQLite (monitores, histórico, usuarios, tokens push). |

### `stacks/uptime-kuma/docker-compose.yml`

```yaml
# Uptime Kuma — sondeo activo y notificación de servicios del homelab.
# Documentado en docs/05-monitorizacion/05-uptime-kuma.md.

name: uptime-kuma

services:
  uptime-kuma:
    image: louislam/uptime-kuma:1.23.16
    container_name: uptime-kuma
    hostname: uptime-kuma
    restart: unless-stopped

    # No publica `ports:` al host: solo accesible vía Caddy y vía red `homelab`.
    expose:
      - "3001"

    environment:
      TZ: ${TZ}
      # Confianza explícita en la CA interna del homelab para que los monitores
      # HTTPS contra *.lan validen la cadena emitida por Caddy.
      NODE_EXTRA_CA_CERTS: /etc/ssl/certs/homelab-ca.pem
      # UPTIME_KUMA_PORT por defecto (3001). Documentado para descubribilidad.
      UPTIME_KUMA_PORT: "3001"
      # Desactiva la *llamada externa* a uptime.kuma.pet para "phone home" del
      # auto-update check; el homelab es LAN+Tailscale, no se autoactualiza.
      UPTIME_KUMA_DISABLE_FRAME_SAMEORIGIN: "0"

    volumes:
      - /mnt/hd2t/apps/uptime-kuma/data:/app/data
      # CA interna del homelab (lectura). Materializada por Caddy en su PKI.
      - /mnt/hd2t/apps/caddy/etc/pki/root.crt:/etc/ssl/certs/homelab-ca.pem:ro
      # Acceso al socket de Docker para el monitor type "Docker Container".
      # SOLO lectura: Uptime Kuma necesita "GET /containers/<id>/json" para
      # comprobar el estado, no necesita crear ni borrar contenedores.
      - /var/run/docker.sock:/var/run/docker.sock:ro

    networks:
      - homelab

    healthcheck:
      # Endpoint propio "/api/entry-page" responde 200 cuando el backend
      # ha terminado el bootstrap (DB cargada, socket.io listo).
      test: ["CMD", "extra/healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

    labels:
      homelab.role: "uptime-monitor"
      homelab.backup: "true"   # SQLite en /app/data; respaldar.
      com.centurylinklabs.watchtower.enable: "true"

networks:
  homelab:
    external: true
```

> **Sobre `extra/healthcheck`**. La imagen oficial incluye un script en `/app/extra/healthcheck` que comprueba el endpoint interno y devuelve exit `0`/`1`. Se prefiere a un `wget` artesanal porque cubre casos transitorios (la app está iniciando WebSocket, está en migración de DB) que un simple `curl /` marcaría como `unhealthy` mal.

> **Sobre `start_period: 60s`**. Uptime Kuma en arranque hace migraciones de DB, carga el listado de monitores, reanuda los timers. En un Pi 5 con 50 monitores el bootstrap se va a 30–45 s. `start_period: 60s` deja margen sin que Docker lo declare *unhealthy* prematuramente.

> **Sobre `docker.sock:ro`**. Uptime Kuma soporta un *monitor type* llamado "Docker Container" que verifica el estado de un contenedor consultando `GET /containers/<id>/json` del socket. Para eso necesita acceso al socket en lectura. Un socket de Docker comprometido (incluso `:ro`) **no es inocuo** (se puede listar imágenes, leer secretos en envs, etc.), pero el contenedor de Uptime Kuma es el mismo perímetro de confianza que Prometheus/Caddy y la imagen es oficial bien mantenida. Mitigación: usar este monitor type sólo para contenedores que no exponen `/health` HTTP (raro en este homelab); preferir HTTP para todos los demás.

> **Sobre `NODE_EXTRA_CA_CERTS`**. Inyecta la CA interna en el almacén de Node sin tener que reempaquetar la imagen. Aplica a todas las llamadas HTTPS que haga el proceso `uptime-kuma` con el módulo `https` de Node (que es lo que usa para los monitores HTTP/HTTPS). Sin esto, los monitores externos `https://*.lan/` reportan errores de cadena.

> **Sobre `UPTIME_KUMA_DISABLE_FRAME_SAMEORIGIN`**. Por defecto la app envía `X-Frame-Options: SAMEORIGIN`. Si en el futuro se quiere embed-ear status pages en un panel Grafana iframe, esto se cambia a `1`. Hoy se deja en `0` (default seguro).

### `stacks/uptime-kuma/.env.example`

```bash
# stacks/uptime-kuma/.env.example
# Variables específicas del stack Uptime Kuma. Las generales (TZ, DOMAIN_LAN)
# vienen del .env GLOBAL del homelab.
#
# (Vacío en esta fase: la configuración real — token de Telegram, chat_id,
# slug de la status page, monitores — se hace en la UI de la app y se
# persiste en /mnt/hd2t/apps/uptime-kuma/data/kuma.db. Las claves sensibles
# NO viven en .env: viven en la SQLite, que se respalda en Borg cifrado.)
```

### Drop-in de Caddy: `stacks/caddy/conf.d/05-uptime-kuma.caddy`

```caddy
# /etc/caddy/conf.d/05-uptime-kuma.caddy — bloques LAN para Uptime Kuma.
# Documentado en docs/05-monitorizacion/05-uptime-kuma.md.

# ---------------------------------------------------------------------------
# Host 1: uptime.lan — dashboard admin (Authelia 2FA + auth propia de Kuma).
# ---------------------------------------------------------------------------
uptime.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Bypass de Authelia para los endpoints máquina-a-máquina:
    # - /api/push/*  → tokens únicos por monitor; auth propia.
    # - /api/badge/* → badges SVG públicas por diseño.
    # - /metrics     → scrape de Prometheus con Basic auth (API key).
    @bypass_authelia path /api/push/* /api/badge/* /metrics
    handle @bypass_authelia {
        reverse_proxy http://uptime-kuma:3001 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    # Dashboard admin: Authelia two_factor + auth propia de Kuma.
    handle {
        import authelia_two_factor

        reverse_proxy http://uptime-kuma:3001 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
            # WebSocket (socket.io) para la UI en tiempo real.
            header_up Connection {http.request.header.Connection}
            header_up Upgrade {http.request.header.Upgrade}
        }
    }
}

# ---------------------------------------------------------------------------
# Host 2: status.lan — status page pública (sin Authelia).
# Solo expone /status/*, /assets/*, /icon.svg y la raíz (que redirige a
# /status/homelab por configuración interna de Kuma). El panel admin no es
# accesible por este host.
# ---------------------------------------------------------------------------
status.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Allowlist explícita: solo rutas de status page y assets.
    @public_paths path / /status /status/* /assets/* /icon.svg /favicon.ico /upload/*
    handle @public_paths {
        reverse_proxy http://uptime-kuma:3001 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    # Cualquier otra ruta (intentos de llegar a /dashboard, /settings, /api)
    # se redirige al dashboard real para que pase por Authelia.
    handle {
        redir https://uptime.{$DOMAIN_LAN}{uri} 302
    }
}
```

> **Sobre la separación en dos hosts**. Mantener admin y status page en hosts distintos hace que la *política* viva en Caddy (declarativa, en git) en vez de en una mezcla de matchers complejos. Si en el futuro se decide eliminar la status page pública, basta con borrar el bloque `status.{$DOMAIN_LAN}` y recargar Caddy: el admin sigue intacto.

> **Sobre `@public_paths` allowlist**. La filosofía es "deny por defecto + permit explícito". Cualquier ruta no listada (ej. `/api/push/...`, `/dashboard`) se redirige al host admin, que sí la sabe rutear con Authelia.

> **Y `access_control` en Authelia**. Recordar añadir **`uptime.${DOMAIN_LAN}`** al bloque `two_factor` de `configuration.yml` de Authelia. **No** añadir `status.${DOMAIN_LAN}`: es público por diseño y debe quedar fuera de Authelia (con `default_policy: deny` no listarlo equivale a denegar; en este caso el bypass se hace en Caddy directamente, así que Authelia ni siquiera lo verá).

### Crear los directorios persistentes y desplegar

```bash
# Directorio de datos
sudo install -d -o 1000 -g 1000 -m 0750 /mnt/hd2t/apps/uptime-kuma
sudo install -d -o 1000 -g 1000 -m 0750 /mnt/hd2t/apps/uptime-kuma/data

# Verificar que la CA interna existe (la creó Caddy en docs/03-red/04-caddy.md)
ls -l /mnt/hd2t/apps/caddy/etc/pki/root.crt
# -rw-r--r-- 1 homelab homelab ... /mnt/hd2t/apps/caddy/etc/pki/root.crt

# Drop-in de Caddy
cd /home/homelab/homelab
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/05-uptime-kuma.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/05-uptime-kuma.caddy

# .env del stack (vacío en esta fase)
cp stacks/uptime-kuma/.env.example stacks/uptime-kuma/.env
chmod 0600 stacks/uptime-kuma/.env

# Añadir uptime.${DOMAIN_LAN} a access_control.rules de Authelia (two_factor).
# NO añadir status.${DOMAIN_LAN} (público por diseño).
sudo $EDITOR /mnt/hd2t/apps/authelia/config/configuration.yml
docker logs authelia --tail 20 | grep -i 'reloaded'

# Validar la configuración de Caddy antes de levantar
docker exec caddy caddy validate --config /etc/caddy/Caddyfile

# Levantar Uptime Kuma
docker compose \
    -f stacks/uptime-kuma/docker-compose.yml \
    --env-file .env --env-file stacks/uptime-kuma/.env \
    up -d

# Recargar Caddy para que tome el nuevo drop-in
docker kill --signal=SIGUSR1 caddy
```

Tras `up -d`:

```bash
docker ps --filter name=uptime-kuma
# CONTAINER ID  IMAGE                            STATUS                  PORTS    NAMES
# ...           louislam/uptime-kuma:1.23.16     Up 60 seconds (healthy)          uptime-kuma

docker compose -f stacks/uptime-kuma/docker-compose.yml logs --tail 20 uptime-kuma
# Welcome to Uptime Kuma
# Your Node.js version: 18.x.x
# Your data dir: /app/data
# ...
# Listening on 3001
```

---

## Configuración

### 1) Setup inicial (admin user)

Desde un cliente de la LAN con la CA interna ya instalada:

```text
1. Abrir https://uptime.lan/
2. Caddy redirige a https://auth.lan/?rd=https://uptime.lan/ (no hay sesión).
3. Login con `homelab` + TOTP en Authelia.
4. Authelia escribe la cookie en `.lan` y redirige de vuelta a uptime.lan.
5. Caddy llama a /api/verify -> Authelia responde 200 -> Uptime Kuma responde.
6. Como es la primera ejecución, Uptime Kuma muestra el wizard de creación
   de admin user.
7. Crear `admin` con una contraseña fuerte (≥ 24 caracteres, generada por
   un gestor; misma política que el master de Vaultwarden cuando llegue).
8. NO activar 2FA todavía (se activa después de configurar al menos un
   notificador, así si se pierde el TOTP se puede recuperar por email).
```

### 2) Configurar notificador Telegram

```text
Settings → Notifications → Setup Notification

  Notification Type:   Telegram
  Friendly Name:       telegram-homelab
  Bot Token:           123456789:AAH... (de BotFather)
  Chat ID:             -100123456789 (de getUpdates, ver Requisitos)
  Message Format:      Default
  Send a test message: ON
  Apply on all existing monitors: OFF (se asigna por monitor más tarde)
  Default enabled:     ON (los nuevos monitores lo usan por defecto)

→ Save
```

Inmediatamente debe llegar un mensaje de prueba al chat de Telegram:
*"Test message from Uptime Kuma. If you can see this, your notification configuration is working."*

Si no llega, ver "Errores frecuentes" → "El test de Telegram no llega".

### 3) Configurar notificador email vía Mailrise

> **Mailrise no existe hasta Fase 11**. La configuración se crea ahora **deshabilitada por defecto en monitores nuevos** y se prueba con "Test message" sólo cuando Mailrise esté desplegado. El test fallará hoy con "connection refused"; ese fallo se considera **esperado**.

```text
Settings → Notifications → Setup Notification

  Notification Type:   Email (SMTP)
  Friendly Name:       email-mailrise
  Hostname:            mailrise
  Port:                8025
  Secure:              None (Mailrise es interno, sin TLS)
  Username:            (vacío)
  Password:            (vacío)
  From Email:          uptime-kuma@homelab.lan
  To Email:            operador@<dominio-real>
  Subject (custom):    [{{ status }}] {{ name }} (Uptime Kuma)
  Send a test message: OFF (se prueba cuando Mailrise exista)
  Apply on all existing monitors: OFF
  Default enabled:     OFF (se activa monitor a monitor sólo en críticos)

→ Save
```

> **Nota**: en cuanto se aplique `docs/11-.../mailrise.md`, volver aquí, abrir el notificador `email-mailrise`, hacer "Send test message" y verificar que el mensaje llega al inbox real. Hasta entonces queda como placeholder funcional pero inactivo.

### 4) Activar 2FA propio de Uptime Kuma

```text
Settings → Authentication → Two Factor Authentication
  Enable 2FA: ON
  Scan QR with Authy/Bitwarden/etc.
  Verify with current code.
→ Save
```

A partir de aquí, el flujo de login pasa por **4 factores totales** (Authelia user + Authelia TOTP + Kuma user + Kuma TOTP). Es ceremonia, pero el panel admin de Uptime Kuma puede pausar monitores y desactivar notificadores; un atacante con sesión podría dejar al homelab "ciego" sin que nadie se entere. Defensa en profundidad lo justifica.

### 5) Crear monitores por servicio

Política de creación: **un monitor interno + un monitor externo** para servicios de cara al humano; **un monitor interno** para exporters/internos.

#### 5.1) Monitores **internos** (DNS Docker)

Plantilla común: `Monitor Type: HTTP(s)`, `URL: http://<servicio>:<puerto>/<path>`, `Interval: 60s`, `Retries: 2`, `Resend Notification: 0` (sin spam), `Notifications: telegram-homelab`.

| Monitor | URL interna | Path / Keyword | Notes |
|---|---|---|---|
| `pihole-internal` | `http://pihole:80/admin/api.php?status` | esperar `"enabled"` en body (HTTP keyword) | Status JSON de Pi-hole. |
| `unbound-internal` | (DNS Monitor) `unbound:5335`, query `pi-hole.net A` | servidor responde con A record válido | Tipo "DNS" de Kuma. |
| `caddy-internal` | `http://caddy:2019/config/` | HTTP 200 | Admin API de Caddy (interna, sólo red Docker). |
| `authelia-internal` | `http://authelia:9091/api/health` | HTTP 200 | Endpoint interno de health. |
| `prometheus-internal` | `http://prometheus:9090/-/healthy` | HTTP 200, body `Prometheus Server is Healthy.` | |
| `grafana-internal` | `http://grafana:3000/api/health` | HTTP 200, JSON `"database": "ok"` | |
| `node-exporter-internal` | `http://node-exporter:9100/` | HTTP 200, body `Node Exporter` | Endpoint raíz devuelve HTML simple. |
| `cadvisor-internal` | `http://cadvisor:8080/healthz` | HTTP 200, body `ok` | |
| `uptime-kuma-self` | `http://uptime-kuma:3001/api/entry-page` | HTTP 200 | Self-monitor; útil para confirmar bootstrap tras reinicio. |

> Más monitores se añaden conforme las Fases 8–11 desplieguen Stash, Jellyfin, Vaultwarden, Mosquitto, etc. La plantilla es la misma.

#### 5.2) Monitores **externos** (DNS LAN + Caddy + cert)

Plantilla común: `Monitor Type: HTTP(s)`, `URL: https://<servicio>.lan/<path>`, `Interval: 120s` (más laxo que internos para no martillear Caddy), `Retries: 2`, `Ignore TLS Error: OFF` (la CA está cargada).

| Monitor | URL externa | Path / Keyword | Notes |
|---|---|---|---|
| `pihole-external` | `https://pihole.lan/admin/login` | HTTP 200, keyword `Pi-hole` | Pasa por Caddy + cert + Authelia (con bypass para `/admin/`). |
| `grafana-external` | `https://grafana.lan/login` | HTTP 200 | Pasa por Caddy + Authelia. |
| `prometheus-external` | `https://prometheus.lan/-/healthy` | HTTP 401 esperado (Authelia redirige) **o** monitorear pasando por API de Authelia. | Para los servicios protegidos por Authelia, el monitor externo idealmente debería autenticarse; en su defecto, comprobar que **al menos** llega un 401/302 (no 502) confirma que Caddy + Authelia están vivos. Configurar `Accepted Status Codes: 200,302,401`. |

> **TLS expiry monitor**. Para cada dominio externo, crear adicionalmente un monitor tipo "TLS Expiry" (Kuma soporta nativamente). URL: `https://pihole.lan`, `Interval: 1d`, `Days to alert: 21`. La CA interna del homelab emite certs de 90 días con renovación automática por Caddy; un alert a 21 días de margen detecta cualquier rotura del proceso de renovación con tiempo de sobra.

#### 5.3) Push monitors (placeholders para Fase 7+)

```text
Add New Monitor → Monitor Type: Push
  Friendly Name:   borgmatic-nightly
  Push Interval:   86400s (24h)
  Heartbeat URL:   https://uptime.lan/api/push/<TOKEN>?status=up&msg=ok
  Notifications:   telegram-homelab + email-mailrise
```

`<TOKEN>` se autogenera en la creación; copiarlo y pegarlo en el cron post-hook de Borgmatic (Fase 7). Hasta entonces el monitor estará "down" tras 24h+5min, lo cual es **no deseable** durante la espera; **dejarlo desactivado** (`Active: OFF`) hasta que Borgmatic exista.

### 6) Crear status page pública

```text
Status Pages → Add New Status Page
  Slug:        homelab
  Title:       Homelab
  Description: Estado de los servicios del homelab.
  Theme:       Auto (sigue el dark/light del navegador)
  Published:   ON
  Show Tags:   OFF
  Custom CSS:  (vacío)

→ Edit Status Page → Add a group "Servicios"
  Añadir monitores: pihole-external, grafana-external, jellyfin-external,
  stash-external, vaultwarden-external (cuando lleguen).
  → NO añadir monitores internos ni de exporters: la status page es para
    "humanos del hogar", no para depuración.

→ Save
```

A partir de ahora `https://status.lan/status/homelab` devuelve la página pública. Configurar la **status page por defecto** en `Settings → General → Default Page` para que `https://status.lan/` redirija al slug `homelab` automáticamente.

### 7) Habilitar `/metrics` para Prometheus (opcional, recomendado)

Uptime Kuma 1.20+ expone `/metrics` con métricas tipo Prometheus de cada monitor: `monitor_status`, `monitor_response_time`, `monitor_cert_days_remaining`. La API se protege con **API key** (Basic auth con `metrics` como user y la key como pass).

```text
Settings → API Keys → Generate API Key
  Name:    prometheus-scrape
  Expires: Never
→ copiar la key generada

Añadir job a /mnt/hd2t/apps/prometheus/config/prometheus.yml:

  - job_name: uptime-kuma
    static_configs:
      - targets: ['uptime-kuma:3001']
        labels:
          instance: 'uptime-kuma'
    basic_auth:
      username: ''
      password: '<API_KEY>'
    metrics_path: /metrics
```

Luego materializar y `docker kill --signal=SIGHUP prometheus`. Esto cierra un loop bonito: **Prometheus** scrape-a el sondeador, así que si Uptime Kuma cae, Prometheus se entera (target `down`) y Grafana lo pinta. La gráfica de "monitores down detectados por Uptime Kuma a lo largo del tiempo" en Grafana se vuelve trivial.

> **Por qué esto es opcional**. Sin este job, el homelab ya está cubierto: Uptime Kuma notifica por Telegram y la status page funciona. Activar el scrape sólo aporta dashboards Grafana ricos. Decidir si vale el coste de un par de KB/min más en la TSDB.

### 8) Operación diaria

| Acción | Comando / Ruta |
|---|---|
| Ver dashboard | `https://uptime.lan/` |
| Ver status page pública | `https://status.lan/` |
| Ver salud del contenedor | `docker ps --filter name=uptime-kuma` |
| Tail de logs | `docker logs -f uptime-kuma` |
| Reiniciar | `docker compose -f stacks/uptime-kuma/docker-compose.yml restart uptime-kuma` |
| Tamaño actual de la SQLite | `du -h /mnt/hd2t/apps/uptime-kuma/data/kuma.db` |
| Ventana de mantenimiento (silenciar checks) | UI: `Maintenance → Add new` |
| Pausar monitor concreto | UI: monitor → `Pause` |
| Borrar histórico antiguo | UI: `Settings → General → Keep monitor history for: 180 days` |

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/uptime-kuma/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/uptime-kuma/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla. |
| `/home/homelab/homelab/stacks/caddy/conf.d/05-uptime-kuma.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in de Caddy (admin + status). |
| `/mnt/hd2t/apps/uptime-kuma/data/` | hd2t | `1000:1000` | `0750` | Directorio de datos. |
| `/mnt/hd2t/apps/uptime-kuma/data/kuma.db` | hd2t | `1000:1000` | `0640` | SQLite principal: monitores, histórico, usuarios, tokens push, notificadores (con secretos cifrados con la *encryption key* propia de Kuma). |
| `/mnt/hd2t/apps/uptime-kuma/data/kuma.db-wal` | hd2t | `1000:1000` | `0640` | Write-Ahead Log de SQLite (modo WAL activado por defecto). |
| `/mnt/hd2t/apps/uptime-kuma/data/kuma.db-shm` | hd2t | `1000:1000` | `0640` | Shared memory de SQLite. |
| `/mnt/hd2t/apps/uptime-kuma/data/error.log` | hd2t | `1000:1000` | `0640` | Errores del proceso (stack traces, fallos de notificación). |
| `/mnt/hd2t/apps/uptime-kuma/data/upload/` | hd2t | `1000:1000` | `0750` | Logos custom subidos por el operador para status pages (vacío hoy). |
| `/var/run/docker.sock` | host | `root:docker` | (socket) | Socket de Docker, montado `:ro` para el monitor type "Docker Container". |
| `/mnt/hd2t/apps/caddy/etc/pki/root.crt` | hd2t | `homelab:homelab` | `0644` | CA interna del homelab, montada `:ro` como `/etc/ssl/certs/homelab-ca.pem`. |

> **Tamaño esperado**. Con 30–50 monitores y `Keep monitor history for: 180 days`, la SQLite se estabiliza en torno a **30–80 MiB**. Sin retención (default infinito) puede llegar a 200–400 MiB tras un año, lo cual sigue siendo trivial para `hd2t` pero cuesta tiempo de backup; por eso se recomienda fijar la retención a 180 d en `Settings → General` (paso de "Configuración → 8").

> **Por qué no microSD**. SQLite con WAL hace `fsync` en cada commit; con 50 monitores cada minuto son ~50 escrituras/min sostenidas. La SD-card lo notaría. `hd2t` lo absorbe sin esfuerzo.

> **Cifrado de secretos en `kuma.db`**. Las claves de notificadores (token de Telegram, API keys, passwords SMTP) se almacenan cifradas con una *encryption key* derivada del JWT secret de Uptime Kuma, que se autogenera en el primer arranque y persiste en `kuma.db`. Eso significa que un backup de `kuma.db` contiene las credenciales (cifradas, pero la clave también está dentro): el repo Borg debe estar **cifrado** (es la convención de Fase 7).

---

## Backup

A nivel de repositorio (git):

| Artefacto | Estrategia |
|---|---|
| `stacks/uptime-kuma/docker-compose.yml`, `.env.example` | Versionados. |
| `stacks/caddy/conf.d/05-uptime-kuma.caddy` | Versionado. |
| Decisiones (versión, dos hosts en Caddy, Telegram + Mailrise, allowlist de bypass) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Por qué |
|---|---|---|
| `/mnt/hd2t/apps/uptime-kuma/data/kuma.db` | **Sí** | Configuración de monitores y notificadores. La pérdida implica reconfigurar 30+ monitores y regenerar todos los push tokens (cron jobs a actualizar). Crítico para la continuidad operativa. |
| `/mnt/hd2t/apps/uptime-kuma/data/kuma.db-wal`, `kuma.db-shm` | **Sí** | Necesarios para que SQLite reabra el fichero consistentemente; Borg los respalda junto con el `.db` y al restaurar SQLite decide si hace replay del WAL o no. |
| `/mnt/hd2t/apps/uptime-kuma/data/upload/` | Sí (cuando exista contenido). | Logos subidos por el operador. Hoy vacío. |
| `/mnt/hd2t/apps/uptime-kuma/data/error.log` | No. | Solo logs operativos; regenerable. |

> **Snapshot consistente con SQLite WAL**. La forma "correcta" de respaldar SQLite con WAL es usar `sqlite3 kuma.db ".backup '/tmp/kuma-backup.db'"` antes del `borg create` para garantizar consistencia transaccional. En la práctica, copiar `kuma.db + kuma.db-wal + kuma.db-shm` con el contenedor parado o en caliente con `cp` también funciona el 99 % de las veces (SQLite es robusto contra esto). Para no tener que parar Uptime Kuma cada noche, se confía en `cp` en caliente; si algún backup queda corrupto (raro), siempre hay 6 nightlys recientes.

Procedimiento de restore tras pérdida del contenedor (datos intactos en `hd2t`):

```bash
docker compose -f /home/homelab/homelab/stacks/uptime-kuma/docker-compose.yml up -d --force-recreate
# Uptime Kuma reusa /mnt/hd2t/apps/uptime-kuma/data: replay del WAL,
# carga de monitores, reanudación de los timers. Las notificaciones que
# quedaron pendientes en cola se entregan en el primer ciclo. Cero pérdida.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear Fase 1, 2, 3 y 4.
2. Restaurar `/mnt/hd2t/apps/uptime-kuma/data/` desde Borg.
3. Verificar permisos: `sudo chown -R 1000:1000 /mnt/hd2t/apps/uptime-kuma/data && sudo chmod 0750 /mnt/hd2t/apps/uptime-kuma/data`.
4. `docker compose -f stacks/uptime-kuma/docker-compose.yml up -d`.
5. Login en `https://uptime.lan/` con las credenciales originales (la SQLite los conserva).
6. Verificar que los monitores reaparecen y que las notificaciones siguen funcionando (Telegram debería entregar el primer "✅ ... is up" del primer monitor que se reactiva).

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| `https://uptime.lan/` da error 502 tras Authelia | Uptime Kuma aún no terminó el bootstrap (DB load + WebSocket init). | Esperar 30–60 s; `docker logs uptime-kuma --tail 30` debe mostrar `Listening on 3001`. |
| `https://uptime.lan/` muestra la pantalla de setup inicial pero ya había admin antes | La SQLite no se montó correctamente; Uptime Kuma arrancó con `data/` vacío. | `docker inspect uptime-kuma --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'`; confirmar que `/mnt/hd2t/apps/uptime-kuma/data → /app/data`. Verificar permisos `1000:1000`. |
| Permission denied al escribir en `/app/data` | El bind mount tiene un owner distinto a UID 1000. | `sudo chown -R 1000:1000 /mnt/hd2t/apps/uptime-kuma/data`. |
| El test de Telegram no llega | Token incorrecto, chat_id incorrecto, el operador nunca habló al bot. | `curl -s "https://api.telegram.org/bot<TOKEN>/getMe"` (ok=true) y `curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates"` (debe haber al menos un message del operador). Si `getUpdates` está vacío, abrir Telegram → al bot → enviar `/start` y reintentar. |
| Monitores HTTPS contra `*.lan` reportan `unable to verify the first certificate` | La CA interna del homelab no está cargada en Node. | Verificar `docker exec uptime-kuma env | grep NODE_EXTRA_CA_CERTS` (debe valer `/etc/ssl/certs/homelab-ca.pem`) y `docker exec uptime-kuma cat /etc/ssl/certs/homelab-ca.pem | head` (debe ser un PEM válido de CA). Si no, revisar bind mount de `caddy/etc/pki/root.crt`. |
| Monitores externos a servicios protegidos por Authelia siempre reportan HTTP 401/302 | Authelia redirige al login; el monitor lo interpreta como "down". | Configurar `Accepted Status Codes: 200,302,401` en el monitor; el objetivo del check externo es saber que Caddy + Authelia están vivos, no autenticarse. |
| `/api/push/<token>?status=up` desde un cron del host devuelve 401 / 302 a Authelia | El `@bypass_authelia` matcher en el drop-in de Caddy no se está aplicando, o se hizo `curl` con el host equivocado. | Confirmar el drop-in: `docker exec caddy cat /etc/caddy/conf.d/05-uptime-kuma.caddy`. `curl -ksI https://uptime.lan/api/push/test123` debe devolver 200/404 directos de Kuma, **no** un 302 a `auth.lan`. |
| Status page pública (`/status/...`) pide login Authelia | El bloque `status.{$DOMAIN_LAN}` no se levantó (el drop-in no se montó o el dominio no existe en Pi-hole). | Caddy usa el wildcard de Pi-hole para `*.lan` automáticamente; verificar `dig +short status.lan @192.168.1.2`. Confirmar `docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile && caddy validate`. |
| Logo subido en una status page no se ve | Permisos del bind mount; el proceso (UID 1000) no pudo escribir en `data/upload/`. | `sudo chown -R 1000:1000 /mnt/hd2t/apps/uptime-kuma/data/upload`. |
| El monitor "Docker Container" muestra "Container not found" | El nombre del contenedor en el monitor no coincide con `container_name:`, **o** el socket no está montado. | UI: editar monitor; el campo "Container Name" debe ser exactamente `pihole`, `caddy`, etc. `docker exec uptime-kuma ls -l /var/run/docker.sock` debe existir. |
| `du -sh kuma.db` crece > 200 MiB y el operador quería retención corta | `Keep monitor history for` no está configurado (o vale 0 = infinito). | UI: `Settings → General → Keep monitor history for: 180 days`. La purga se ejecuta en background y reduce el fichero (puede llevar minutos en SQLite con muchos heartbeats). |
| WebSocket se desconecta cada pocos segundos en la UI | Caddy no está pasando los headers `Connection`/`Upgrade`. | Verificar el bloque `reverse_proxy` del drop-in: `header_up Connection {http.request.header.Connection}` y `header_up Upgrade {http.request.header.Upgrade}` deben estar presentes en el handle del admin. |
| Reinicio del Pi: Uptime Kuma arranca pero todos los monitores aparecen como "Pending" durante 1–2 min | Comportamiento esperado: tras el bootstrap, Kuma reanuda los timers escalonadamente para no martillear todo a la vez. | Esperar; el 100% de los monitores volverá a su estado real en ≤ 5 min. |
| Tras subir versión (`docker compose pull`) la app no levanta y los logs muestran `database migration failed` | Cambio de schema en una minor / mayor; backup previo no existe. | Restaurar `kuma.db` desde Borg (Fase 7) y volver a fijar el tag previo. Antes de subir versión, **siempre** `cp /mnt/hd2t/apps/uptime-kuma/data/kuma.db /tmp/kuma-pre-upgrade.db`. |
| Notificaciones llegan duplicadas | Dos contenedores de Kuma corriendo simultáneamente apuntando al mismo `data/`. | `docker ps -a | grep uptime-kuma`; matar el contenedor zombie. SQLite con WAL **no** soporta múltiples writers; mantener una sola instancia. |
| Después de meses de uso, Kuma muestra "Cannot connect to the server" en la UI tras login | Sesión socket.io expirada o backend congestionado. | F5 al navegador; si persiste, `docker compose restart uptime-kuma`. |

---

## Decisiones que **no** se toman en este documento

- **Alertmanager**: se mantiene la decisión tomada en `01-prometheus.md`. Uptime Kuma cubre la necesidad mínima de notificación de "el servicio se cayó"; reglas Prometheus + Alertmanager (umbrales de CPU, latencia P99, etc.) quedan para una Fase futura.
- **Migración a Uptime Kuma 2.x con MariaDB**: cuando 2.x se marque como `stable` y haya guía oficial de migración SQLite→MariaDB, se reabre. Hoy 1.23.x es la rama LTS de facto.
- **Status page expuesta a internet**: incompatible con el alcance del homelab (LAN+Tailscale). Si en el futuro se decide hacer pública (cloudflared tunnel, etc.), se documenta en una nueva fase con su propia firewall e idealmente con un Kuma secundario de solo lectura.
- **Plantillas custom de mensaje**: Telegram tiene Markdown limitado y formatos *MarkdownV2* finos; las plantillas por defecto de Kuma ya entregan información suficiente. Reabrible si el operador empieza a perder mensajes en un canal grupal y necesita branding.
- **Notificadores Discord/Slack/ntfy**: Telegram + Mailrise cubren el caso. Reabrible si el operador migra de mensajería.
- **Monitor type "JSON Query"**: poderoso pero rompible al menor cambio del JSON upstream. Se prefiere "HTTP Keyword" para chequeos de salud; reabrible para monitores muy específicos (ej. "número de torrents activos > 0" cuando llegue Stash).
- **Página de estado por usuario / multi-tenancy**: Kuma 1.x soporta solo admin único + status pages multi-page. Multi-tenant llegaría con 2.x.
- **TLS expiry global**: el monitor TLS Expiry se crea por dominio. Una alternativa "mirar todos los certs en /mnt/hd2t/apps/caddy/data/caddy/certificates" se descartó: es más limpio sondear el TLS de la cadena completa (resolución DNS Pi-hole + Caddy sirviendo el cert) que mirar el fichero en disco.
- **Métricas detalladas push (mensajes a `/api/push/.../?ping=120&msg=...&status=up`)**: el patrón es genérico para cualquier cron; no se documenta caso a caso aquí. Cada documento que añada un cron (Borgmatic, watchtower, jobs cron del host) debe enlazar este patrón en su sección "Configuración".
- **Auto-discovery de monitores** (escanear servicios en la red Docker `homelab` y crearlos automáticamente). Atractivo, pero exigiría leer `docker ps` y mantener estado externo. El homelab es de tamaño manejable; añadir manualmente cada monitor es tolerable y deja decisión humana sobre qué chequear y cómo.
- **Sincronización de estado entre Uptime Kuma y Authelia**: si Authelia cae, Uptime Kuma sigue activo (otro contenedor) y notifica la caída. La status page **pública** sigue accesible aunque Authelia se haya muerto, lo cual es deseable: es la única forma para un humano fuera del operador admin de saber "está pasando algo, no es problema mío".

---

## Verificación Final

Antes de pasar a `06-dozzle.md`:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack desplegado y saludable | `docker compose -f stacks/uptime-kuma/docker-compose.yml ps` | `uptime-kuma ... Up (healthy)` |
| Imagen correcta y fija | `docker inspect uptime-kuma --format '{{.Config.Image}}'` | `louislam/uptime-kuma:1.23.16` |
| Conectado a `homelab` | `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` | incluye `uptime-kuma`, `caddy`, `prometheus` |
| Sin puertos publicados al host | `docker port uptime-kuma` | salida vacía |
| Bind mounts correctos | `docker inspect uptime-kuma --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Mode}}){{"\n"}}{{end}}'` | `data → /app/data (rw)`, `root.crt → /etc/ssl/certs/homelab-ca.pem (ro)`, `docker.sock → /var/run/docker.sock (ro)` |
| `uptime.lan` y `status.lan` resuelven al IP de la Pi | `dig +short uptime.lan @192.168.1.2; dig +short status.lan @192.168.1.2` | `192.168.1.10` (cada uno) |
| Caddy sirve `uptime.lan` con cert de la CA interna | `echo \| openssl s_client -connect uptime.lan:443 -servername uptime.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| Health endpoint responde (interno) | `docker exec uptime-kuma /app/extra/healthcheck && echo ok` | `ok` |
| Acceso a `uptime.lan` vía Authelia | navegador con CA y sesión TOTP | UI carga el dashboard de Kuma; tras login propio, lista de monitores visible |
| Bypass de `/api/push/*` funciona | `curl -ksI https://uptime.lan/api/push/test-no-token` | `HTTP/2 404` (no es un 302 a auth.lan) |
| Bypass de `/metrics` funciona | `curl -ksI https://uptime.lan/metrics` | `HTTP/2 401` (Kuma exige Basic auth, NO es 302 a auth.lan) |
| Status page pública sin Authelia | `curl -ksI https://status.lan/` | `HTTP/2 200` o `HTTP/2 302` a `/status/<slug>`, NUNCA un 302 a `auth.lan` |
| Status page renderiza monitores | navegador → `https://status.lan/` | grupo "Servicios" con al menos 1 monitor en verde |
| Notificador Telegram operativo | UI → Notifications → telegram-homelab → Test | mensaje recibido en el chat |
| 2FA propio activo | UI → Settings → Authentication | `Two Factor Authentication: ON` |
| Monitores internos creados | UI → Dashboard | mínimo `pihole-internal`, `caddy-internal`, `authelia-internal`, `prometheus-internal`, `grafana-internal` en verde |
| TLS expiry monitors creados | UI → Dashboard | mínimo 1 monitor "TLS Expiry" en verde con `Days remaining > 21` |
| CA interna cargada en Node | `docker exec uptime-kuma node -e "console.log(require('fs').readFileSync(process.env.NODE_EXTRA_CA_CERTS,'utf8').slice(0,30))"` | `-----BEGIN CERTIFICATE-----\n...` |
| Owner correcto del data dir | `stat -c '%u:%g' /mnt/hd2t/apps/uptime-kuma/data/` | `1000:1000` |
| SQLite escribiendo en hd2t | `du -h /mnt/hd2t/apps/uptime-kuma/data/kuma.db` | tamaño > 0 (típicamente 1–5 MiB tras el setup inicial) |
| Retención de histórico aplicada | UI → Settings → General | `Keep monitor history for: 180 days` |
| (Opcional) Job Prometheus `uptime-kuma` `up` | `https://prometheus.lan/targets` | `uptime-kuma → up` |

---

## Referencias

- Repositorio Uptime Kuma: https://github.com/louislam/uptime-kuma
- Documentación oficial: https://github.com/louislam/uptime-kuma/wiki
- Imagen oficial multi-arch: https://hub.docker.com/r/louislam/uptime-kuma (pin: `1.23.16`)
- Lista de notificadores soportados: https://github.com/louislam/uptime-kuma/tree/master/server/notification-providers
- Endpoint `/metrics` y autenticación API: https://github.com/louislam/uptime-kuma/wiki/Reverse-Proxy
- Telegram Bot API: https://core.telegram.org/bots/api
- Documentos relacionados:
  - `docs/05-monitorizacion/01-prometheus.md` — Prometheus puede scrape-ar `uptime-kuma:3001/metrics`.
  - `docs/05-monitorizacion/02-grafana.md` — paneles que cruzan métricas de Kuma con dashboards.
  - `docs/03-red/04-caddy.md` — virtual hosts `uptime.lan` y `status.lan`, snippet `(authelia_two_factor)`.
  - `docs/04-seguridad/01-authelia.md` — política `two_factor` para `uptime.lan`; `status.lan` queda fuera.
  - `docs/02-docker/02-estructura-compose.md` — convenciones de stacks.
