# Homepage

## Descripción

Cerradas las Fases 0 a 11, el homelab ya levanta **del orden de 30 contenedores** distribuidos en una docena de stacks: red (Pi-hole, Unbound, Caddy, Tailscale), seguridad (Authelia, Fail2ban a nivel host), observabilidad (Prometheus, Grafana, Node Exporter, cAdvisor, Uptime Kuma, Dozzle), almacenamiento (Nextcloud, Samba, Syncthing, MinIO), backups (Borgmatic), domótica (Home Assistant, Mosquitto, Zigbee2MQTT, Node-RED), multimedia (Jellyfin, Navidrome, Audiobookshelf, Calibre-Web, Stash), descargas (Transmission, Prowlarr, Sonarr, Radarr) y productividad (Vaultwarden, Bookstack, Linkding, Paperless, Mealie, Stirling PDF, FreshRSS). Cada uno vive bajo su propio subdominio (`jellyfin.lan`, `vaultwarden.lan`, `paperless.lan`, …) y el operador, su pareja y el resto de miembros de la familia se han aprendido **algunos** subdominios de memoria, pero no todos. El bookmark del navegador no es el sitio donde uno mira la salud del homelab.

Este documento despliega **Homepage** — el dashboard escrito en Next.js que **agrega**, en una única página, links a todos los servicios del homelab, su estado de salud (vía Docker socket o vía health checks), widgets con datos vivos (espacio libre en `hd5t`/`hd2t`, descargas en curso de Sonarr/Radarr, episodios pendientes de ver en Jellyfin, peticiones DNS bloqueadas en Pi-hole, temperatura de la Pi 5, ítems pendientes en Mealie/Paperless, feeds sin leer en FreshRSS, alertas activas en Uptime Kuma, métricas de Prometheus, etc.) y bookmarks del operador (documentación oficial de cada herramienta, repos de GitHub, "panel admin del router") en un sólo URL: `https://home.${DOMAIN_LAN}/` (subdominio reservado, ver `03-red/02-pihole.md`). Su rol concreto:

1. **Servir el dashboard** en `https://home.${DOMAIN_LAN}/` con TLS terminado en Caddy (CA interna). Detrás de Caddy, sin `ports:` al host. Auth con `forward_auth` **`one_factor`** contra Authelia (justificación en "Decisión: autenticación").
2. **Agregar el estado de los contenedores** vía Docker (socket proxy de Tecnativa, no el socket raw — la sección "Decisión: Docker integration" explica por qué). Cada servicio en `services.yaml` lleva un campo `container:` y Homepage marca verde / naranja / rojo según `running` / `unhealthy` / `down`, sin necesidad de health endpoints HTTP.
3. **Pintar widgets con datos vivos** llamando a la API de cada servicio. Los tokens y URLs van en variables de entorno `HOMEPAGE_VAR_*` (de `.env`, no en YAML versionado), referenciadas en YAML como `{{HOMEPAGE_VAR_SONARR_KEY}}`. Mecanismo nativo de Homepage que evita comprometer secretos en git.
4. **Servir como índice canónico para invitados de Tailscale** (familia que conecta esporádicamente vía VPN). Una sola URL, todo navegable. Reduce la fricción de "¿cuál era el subdominio del Audiobookshelf?".
5. **No persistir nada**. Igual que Stirling PDF (`11-productividad/06-stirling-pdf.md`), Homepage es **stateless por diseño**: la totalidad de su configuración vive como YAML en `stacks/homepage/config/` versionado en git, bind-montada **read-only** dentro del contenedor. El contenedor es desechable: `down -v && up -d` reproduce el dashboard idéntico desde la microSD. Nada que respaldar en Borg más allá del propio repo.
6. **No participar en backups Borg**. La política de `homelab.backup=true` no se aplica a este stack.
7. **Soportar hot-reload de la configuración**. Homepage observa `/app/config/` y recarga al detectar cambios — el operador edita `services.yaml`, hace `git diff`, `git commit`, `git push` (al remoto), y al volver a la Pi tira `git pull` y los cambios aparecen sin `up -d`.

Lo que este documento **no** decide:

- **Multi-dashboard / multi-página por usuario**. Homepage soporta vistas distintas para diferentes audiencias (operador con todo lo "raw", invitados con sólo Jellyfin/Audiobookshelf/Mealie). Hoy se mantiene **un único dashboard** filtrado por **grupos** (servicios "públicos" arriba, "infraestructura" plegada al fondo) — más simple. Reabrible cuando llegue la primera petición concreta de la pareja del operador ("quiero una pestaña sólo con Mealie y Calibre-Web").
- **Themes custom**. Homepage soporta CSS custom inyectado vía `/app/config/custom.css`. Hoy se usa el tema `dark` por defecto y se acepta su estética. Reabrible si el operador quiere cambiar colores.
- **Internacionalización extensiva**. Homepage trae traducciones para >40 idiomas. Se fija en `es` para el operador y, si la pareja prefiere otro, se documenta cambiar la variable `HOMEPAGE_VAR_LANG`.
- **Métricas Prometheus de Homepage**. Homepage no expone `/metrics` propio. No se valora un sidecar exporter — el dashboard está cubierto por Uptime Kuma (HTTP check) y, si es necesario, por cAdvisor (RAM/CPU del contenedor).
- **Quick Look / iframes** (Homepage permite previsualizar dashboards de Grafana, mapas de Home Assistant, etc. embebidos). En `forward_auth two_factor` los iframes a Grafana fallan por *cookie partitioning* y CORS si no se relaja `same-origin`. Hoy se prefiere link "abrir en nueva pestaña" (sin iframes), que funciona transparentemente con la sesión SSO ya iniciada.
- **OAuth/OIDC propio**. Homepage no tiene cuentas ni OAuth — la auth es perimetral en Caddy + Authelia. Reabrible si en algún momento Homepage añade vistas por usuario que requieran identificar al cliente, pero no es el caso hoy.
- **Notificaciones push** (un widget "alertas activas" sí existe vía Uptime Kuma; pero Homepage **no** envía alertas). Las notificaciones siguen siendo responsabilidad de Uptime Kuma (`05-monitorizacion/05-uptime-kuma.md`).
- **Versionado del archivo `services.yaml` por persona**. El YAML se versiona en git y los cambios pasan revisión informal (se firma el commit del operador). No hay flujo PR ni protección de rama — sobreingeniería para el caso de uso.

Cuando este documento se haya aplicado:

- `https://home.${DOMAIN_LAN}/` carga tras login + 1FA en Authelia (la sesión SSO ya iniciada en otro servicio cubre Homepage sin re-login en la misma ventana de validez).
- El dashboard muestra **grupos** (`Infraestructura`, `Multimedia`, `Productividad`, `Domótica`, `Backups`, `Bookmarks`) con cada servicio como tarjeta clicable, indicador verde de `running`, y los widgets de los servicios con API (Pi-hole, Sonarr, Radarr, Prowlarr, Transmission, Jellyfin, Navidrome, Calibre-Web, Audiobookshelf, Uptime Kuma, Prometheus, Mealie, Paperless, Linkding, FreshRSS, Home Assistant, Nextcloud, MinIO, Portainer) renderizando datos vivos.
- Widgets de sistema (CPU/RAM/disco/temperatura) vivos en una columna lateral.
- `git diff stacks/homepage/config/services.yaml` aceptado por Homepage en menos de 5 s sin tocar Docker.
- Uptime Kuma tiene un monitor HTTPS sobre `https://home.lan/api/healthcheck` con alerta Telegram + email.
- Borgmatic **no** toca este stack: la fuente de verdad es git, y git ya está respaldado vía remoto + Borg sobre `/home/homelab/homelab/`.

> **Recordatorio de alcance**: Homepage es **solo LAN + Tailscale**. **No publica `ports:` al host**, **no se expone a Internet**, **no usa Let's Encrypt**. Vía Tailscale, MagicDNS resuelve `home.lan` desde fuera de casa siempre que el cliente tenga la CA interna instalada.

---

## Requisitos Previos

- **Fase 2** completa: Docker Engine + Compose v2; red `homelab` en `172.30.10.0/24`; convenciones `stacks/<svc>/`; `.env` global con `TZ`, `PUID`, `PGID`, `DOMAIN_LAN=lan`, `LAN_IP=192.168.1.10`.
- **Fase 3** completa, en particular:
  - Pi-hole con el comodín `address=/lan/192.168.1.10` (cubre `home.${DOMAIN_LAN}` sin tocar Pi-hole).
  - Caddy con los snippets `(lan_tls)`, `(security_headers)`, `(healthcheck)` y, opcionalmente, `(authelia_one_factor)`.
- **Fase 4** completa, en particular:
  - Authelia desplegado y los snippets `(authelia_one_factor)` y `(authelia_two_factor)` registrados en `stacks/caddy/conf.d/01-authelia.caddy` (decisión vivida en `04-seguridad/01-authelia.md`).
  - El operador y la pareja existen en el backend de Authelia (file backend) con TOTP enrollado.
- **Las Fases 5 a 11 desplegadas y funcionales** — Homepage agrega lo que ya existe; si un servicio aún no está, el bloque correspondiente en `services.yaml` se deja comentado y se rehabilita cuando aparezca. El despliegue mínimo "viable" sólo necesita Caddy + Authelia + un par de servicios; pero el dashboard se vuelve útil con todo el ecosistema arriba.
- **Tokens de API** disponibles para los servicios cuyos widgets se quieren activar (ver tabla en "Configuración → 3"). El operador ya los generó en cada documento de servicio:
  - `JELLYFIN_API_KEY`: dashboard de Jellyfin → API Keys.
  - `SONARR_API_KEY`, `RADARR_API_KEY`, `PROWLARR_API_KEY`: settings → general → API key en cada uno.
  - `PIHOLE_API_KEY`: Pi-hole → settings → API.
  - `UPTIMEKUMA_USER` / `UPTIMEKUMA_PASS`: cuenta del operador en Uptime Kuma (Homepage usa Basic Auth contra `/metrics` o el endpoint público).
  - Más detalle por servicio en "Configuración → 3".
- **Operador** con la **CA interna instalada** en navegador (PC + móvil). Sin esto, la primera petición a `home.lan` falla con `NET::ERR_CERT_AUTHORITY_INVALID`.
- **RAM disponible**: ~150 MiB de cabeza para el contenedor (Node.js + Next.js en idle, cero estado, polling cada 5–60 s a las APIs).
- **No requiere espacio en hd2t** más allá del propio del repo del homelab. Sin BBDD, sin assets persistentes, sin uploads.

Comprobaciones rápidas:

```bash
# La red Docker compartida existe
docker network inspect homelab --format '{{.Name}}' | grep -q '^homelab$' && echo ok

# Caddy y Authelia corriendo
docker ps --filter name=caddy --filter name=authelia --format '{{.Names}} {{.Status}}'

# home.lan resuelve al IP de la Pi (gracias al comodín de Pi-hole)
dig +short home.lan @192.168.1.2
# 192.168.1.10

# Snippets forward_auth registrados en Caddy
docker exec caddy grep -E '^\(authelia_(one|two)_factor\)' /etc/caddy/conf.d/01-authelia.caddy
# (authelia_one_factor) {
# (authelia_two_factor) {

# Listado de contenedores que el dashboard va a referenciar
docker ps --format '{{.Names}}' | sort
```

---

## Decisión: imagen y versión

Homepage se distribuye desde GHCR (`ghcr.io/gethomepage/homepage`) con builds multi-arch (`linux/amd64`, `linux/arm64`, `linux/arm/v7`). En la Pi 5 (aarch64) se usa el manifest `arm64`.

| Tag | Cuándo usar | Decisión aquí |
|---|---|---|
| `latest` | Demos. | Descartado (convención de Fase 2). |
| `v0.10.x` (rama actual) | Última estable de la rama 0.10. | Aceptable. |
| `v0.10.9` (ejemplo) | Versión exacta `MAYOR.MENOR.PARCHE`. | **Aceptado** como compromiso entre reproducibilidad y mantenimiento. |
| `dev` / `nightly` | Builds del trunk. | Descartado: rompe sin previo aviso. |

> **Tag exacto en uso**: `ghcr.io/gethomepage/homepage:v0.10.9`. Si en el momento de aplicar este documento existe una versión más reciente con changelog limpio (sin breaking changes en la sintaxis de YAML — Homepage los anuncia explícitamente con cabecera "Breaking" en el release), se actualiza el tag aquí y en el `docker-compose.yml`, y se anota en el commit. **Nunca `latest`**, **nunca `dev`**.

> **Por qué Homepage y no Heimdall / Dashy / Flame / Glance / Organizr / Homarr**.
> - **Heimdall**: el primer dashboard popular del *self-hosted*. Buena UX pero **sin widgets nativos** (sólo links y un puñado de "enhanced apps" que requieren API keys editadas en la UI, no versionables en git). Configuración por SQLite, opaca al operador. Descartado.
> - **Dashy**: muy completo, configuración YAML versionable, con widgets. Más pesado (Vue 2 con build steps) y la comunidad ha frenado su desarrollo en el último año. Aceptable, pero perdió tracción frente a Homepage.
> - **Flame**: minimalista, sin widgets. Bonito pero limitado.
> - **Glance**: muy nuevo, prometedor, también YAML, pero ecosistema de integraciones aún pequeño en 2025. Reabrible en 12+ meses si Homepage decae.
> - **Organizr**: PHP, se concentra en multi-user con SSO propio (que aquí no aporta — Authelia ya es SSO). Heredado, mantenimiento limitado.
> - **Homarr**: Node.js con UI editable en runtime (drag-and-drop). **Eliminado** explícitamente del plan del homelab: el commit `a3eb29a Eliminar Homarr del plan y de la lista de servicios` lo retiró por una vulnerabilidad de configuración (la UI escribe ficheros de configuración que escapan del control de versiones — antipatrón opuesto a "configuración como código"; además, Homarr tuvo varias issues de seguridad en 2024 con la API de gestión de tokens). **Descartado** por decisión documentada.
> - **Homepage**: sweet spot. **Configuración como código** en YAML versionable, **+50 widgets nativos** para los servicios self-hosted más comunes (Pi-hole, *arr suite, Jellyfin, Plex, Nextcloud, Uptime Kuma, Prometheus, Home Assistant, Mealie, Paperless, Linkding, FreshRSS, etc.), Docker integration nativa, hot-reload de configuración, ~80 MB de imagen, multi-arch arm64 estable, comunidad activa (>20k stars), licencia GPL-3.0. **Decidido**.

> **Por qué tag exacto y no `v0.10`**. Homepage 0.x ha movido la sintaxis de YAML entre menores en al menos dos ocasiones (la 0.8 → 0.9 cambió `widgets` a estar dentro de cada servicio en `services.yaml`, y la 0.9 → 0.10 introdujo `kubernetes.yaml` y reorganizó algunos namespaces). Con tag flotante un `up -d` rutinario podría romper el dashboard tras un parsing fallido del YAML existente (Homepage queda sirviendo una página de error en su sitio). Con tag exacto las actualizaciones son **deliberadas**: el operador lee el changelog, edita el tag, valida con `docker compose config`, hace `git commit` con el dashboard funcionando, `up -d`. Watchtower **deshabilitado** para este stack.

---

## Decisión: cómo se expone Homepage

Homepage es Next.js corriendo en Node.js 20, escuchando en `:3000` dentro del contenedor (HTTP plano; el TLS lo termina Caddy delante).

| Opción | Cómo se ve | Discusión |
|---|---|---|
| `network_mode: host` | Homepage ata `:3000` al host. | Choca con cualquier servicio que use `:3000` (Grafana, etc.). Descartado. |
| Bridge `homelab` con `ports: ["3000:3000"]` | Acceso directo desde la LAN sin pasar por Caddy. | HTTP plano sin TLS y, peor, **sin Authelia**: cualquiera en la LAN abre `http://192.168.1.10:3000/` y descubre URLs de todos los servicios + algunos datos de los widgets. Descartado. |
| Bridge `homelab` con `expose: 3000`, **sin `ports:`** | Homepage alcanzable solo dentro de la red Docker. Caddy hace `reverse_proxy http://homepage:3000`. | Termina TLS en Caddy con la CA interna y **fuerza el paso por `forward_auth`**. Patrón establecido. **Aceptado**. |

Resultado: `expose: 3000` en el compose (no `ports:`), un drop-in `stacks/caddy/conf.d/50-homepage.caddy` que hace `reverse_proxy http://homepage:3000` y que importa `authelia_one_factor`, y todo el tráfico externo pasa por `https://home.${DOMAIN_LAN}/` con cert de la CA interna y sesión Authelia validada.

> **Sobre WebSockets / SSE**. Homepage usa **Server-Sent Events** (SSE) para empujar las actualizaciones de los widgets al navegador del cliente sin polling adicional. `reverse_proxy` de Caddy proxea SSE sin configuración extra; basta con asegurarse de que **no** se hace `flush_interval 0` (que cortaría los eventos). El drop-in respeta el comportamiento por defecto.

> **Sobre el tamaño de respuesta**. El bundle inicial de Next.js + las imágenes de los servicios son ~2 MiB. Caddy con `gzip` (habilitado por defecto en `(security_headers)` o como handler global) baja el ancho de banda; tampoco es relevante en LAN. No se tocan timeouts ni límites.

---

## Decisión: autenticación — `forward_auth one_factor` vía Authelia

Homepage no tiene auth interna en absoluto. La única protección es perimetral. La elección es entre `one_factor` (email + password) y `two_factor` (email + password + TOTP).

| Capa | Patrón | Justificación |
|---|---|---|
| Caddy → Homepage | `forward_auth authelia:9091` con snippet `authelia_one_factor` | Homepage es **un índice de links + datos agregados ya públicos** (status de contenedores, espacio libre, peticiones DNS bloqueadas). No expone datos sensibles del usuario (no tiene fotos, no tiene contraseñas, no tiene documentos). Cada link clicable lleva a un servicio que **a su vez** aplica su propia política de auth (Vaultwarden con TOTP, Paperless con TOTP, Bookstack con TOTP, etc.). |
| Homepage | Sin auth interna | Stateless: cero usuarios. Si Authelia deja pasar, Homepage sirve. |

> **Por qué `one_factor` y no `two_factor`**. Política coherente con el `04-seguridad/01-authelia.md`:
> - **Servicios que `tocan documentación personal o credenciales`** → `two_factor` (Vaultwarden, Bookstack, Paperless, Stirling, Nextcloud, Linkding, Mealie [recetas con valor sentimental], FreshRSS).
> - **Servicios que muestran agregados sin datos íntimos** → `one_factor` (Homepage, Uptime Kuma público, Dozzle, status pages).
> - **Servicios "públicos en LAN" sin Authelia** → multimedia consumido por la familia (Jellyfin, Audiobookshelf, Calibre-Web), donde la fricción de TOTP en el televisor o en el reproductor de audio es una pesadilla.
>
> Homepage encaja en el segundo grupo. Subir a `two_factor` añadiría fricción innecesaria — el operador entra en Homepage **muchas veces al día**, mientras que entra a Vaultwarden o Paperless rara vez. Si el operador discrepa, sustituir `import authelia_one_factor` por `import authelia_two_factor` en el drop-in 50 y `caddy reload` (decisión reabrible en una línea).

> **Sobre el riesgo de `one_factor`**. Un atacante con acceso a las credenciales (sin TOTP) ve **únicamente el dashboard**. No accede a ningún servicio destino sin pasar el `two_factor` correspondiente del servicio sensible. El "blast radius" de un compromiso de Homepage es informacional (qué servicios existen) — y esa información ya estaría disponible al hacer port scanning de la LAN. Aceptable.

> **Sobre `forward_auth` y la sesión SSO compartida**. Idéntico a Stirling y al resto: una vez el operador entra a Authelia desde **cualquier** servicio que comparta el mismo backend, la cookie `authelia_session` cubre Homepage en la misma ventana de `expiration: 1h`.

---

## Decisión: sin persistencia (stateless por diseño)

Homepage es **configuración como código**. No tiene BBDD. La fuente de verdad es el directorio `stacks/homepage/config/`, versionado en git. Las tres rutas potenciales:

| Fuente | Decisión | Por qué |
|---|---|---|
| **YAML de configuración** (`services.yaml`, `settings.yaml`, `widgets.yaml`, `bookmarks.yaml`, `docker.yaml`, `kubernetes.yaml`, `custom.css`) | Bind mount **read-only** desde el repo | Idempotencia + auditoría: cualquier cambio queda en el log de git. |
| **Iconos / logos custom** | Subdirectorio `stacks/homepage/config/icons/` versionado | Cada SVG ocupa < 10 KiB; versionable sin coste. |
| **Logs de aplicación** | `STDOUT/STDERR` del contenedor | Captura `journald` vía `docker logs`. No persistente. |

| Aspecto | Decisión | Por qué |
|---|---|---|
| BBDD | **Ninguna** | Homepage es stateless. |
| Configuración persistente | **Solo `.env` del compose y YAML versionado** | Reproducible desde git. |
| Volúmenes Docker named | **Ninguno** | Nada que persistir. |
| Bind mounts a hd2t | **Ninguno** | Sin estado. |
| Bind mounts read-only | YAML del repo + socket proxy de Tecnativa (no el socket raw) | Configuración inmutable + integración Docker controlada. |
| `tmpfs` para `/tmp` | **Sí**, `size=64m` | Next.js volcará caché ligera ahí. |
| `read_only: true` para el rootfs | **Sí**, con `tmpfs` para `/tmp` y `/app/.next/cache` | Defensa en profundidad. |
| Backup Borg | **Excluido** (no `homelab.backup=true`) | El YAML está en git; git está en remoto + Borg sobre `/home/homelab/homelab/`. |

> **Por qué bind mount read-only del config**. Si en algún momento el contenedor de Homepage fuera comprometido (CVE en Next.js, dependency confusion en npm, etc.), un atacante con código en ejecución dentro **no podría** modificar la configuración versionada. Cualquier cambio requeriría tocar la microSD de la Pi (acceso físico o SSH). Defensa en profundidad real con coste cero.

> **Por qué `read_only: true` para el rootfs**. Homepage carga su build de Next.js (estático en `/app/.next/`) al arrancar y escribe sólo en `/tmp` y `/app/.next/cache` (cache HMR si se ejecutara en dev — en producción no se usa, pero Next.js intenta crearlo igualmente). Marcando el rootfs read-only con tmpfs en esos directorios, el contenedor arranca sin queja. **Aceptado**.

---

## Decisión: Docker integration — socket proxy de Tecnativa, no `/var/run/docker.sock` raw

Homepage puede consultar el estado de los contenedores (running / stopped / unhealthy / restarting) y mostrarlo como indicador de color en cada tarjeta. Para hacerlo necesita acceso al socket de Docker. Las dos opciones:

| Opción | Cómo se ve | Discusión |
|---|---|---|
| Bind mount `-v /var/run/docker.sock:/var/run/docker.sock:ro` | Acceso lectura al socket raw. | El socket de Docker es **equivalente a root en el host**: aunque el bind mount sea `:ro`, dentro del contenedor el daemon escucha el socket completo y un atacante con código en ejecución (CVE de Next.js, dependency confusion) podría escalar a root del host vía `docker run --privileged` o montando `/` de la Pi en otro contenedor que sí tenga `:rw`. **Documentado como antipatrón en `02-docker/02-estructura-compose.md`**. Descartado. |
| **Socket proxy de Tecnativa** (`tecnativa/docker-socket-proxy:0.2`) | Sidecar que expone vía HTTP **solo** los endpoints `GET /containers/*`, `GET /info`, `GET /version` — los necesarios para Homepage. POST y endpoints peligrosos (`/build`, `/exec`, `/auth`, `/swarm`) bloqueados a nivel del proxy. Homepage habla con `tcp://docker-socket-proxy:2375`. | Surface de ataque drásticamente reducida. **Aceptado**. |

Resultado: stack `stacks/docker-socket-proxy/` (un único contenedor, compartido para Homepage y, en el futuro, otros consumidores de Docker API como Dozzle si se reconfigurara o un exporter Prometheus). Su definición está en este documento por ser Homepage el primer consumidor; si en el futuro aparece un segundo, queda factorizado.

> **Por qué `tecnativa/docker-socket-proxy` y no `linuxserver/socket-proxy`**. Ambas son válidas. La de Tecnativa es la **referencia histórica** (>5 años, >2k stars, mantenida por la consultora ONGAWA/Tecnativa) y su mecanismo es transparente: una variable booleana por endpoint (`CONTAINERS=1`, `IMAGES=0`, `EXEC=0`, `POST=0`). La de LinuxServer.io es más reciente y compatible. **Decidido Tecnativa** por mayor rodaje en producción.

> **Sobre el tag exacto**. `tecnativa/docker-socket-proxy:0.2.0` tiene 4+ años de estabilidad. La imagen apenas evoluciona (es básicamente un `haproxy.cfg` con reglas). Se pin a `0.2.0`.

> **Sobre la red de la sidecar**. El contenedor `docker-socket-proxy` se conecta a la red `homelab` y **no expone puertos al host**. Sólo Homepage (y futuros consumidores en `homelab`) hablan con él en `tcp://docker-socket-proxy:2375`. Coherente con la convención de Fase 2 ("nada se habla por puerto del host si no es estrictamente necesario").

> **Sobre las capabilities de la sidecar**. `docker-socket-proxy` corre como root (necesita acceder al socket). Mitigaciones: `cap_drop: [ALL]`, `cap_add: [DAC_OVERRIDE]` (para leer el socket), `read_only: true`, `security_opt: ["no-new-privileges:true"]`. La sidecar es **microscópica** (~5 MiB) y un objetivo poco interesante para un atacante: si llega ahí, ya tiene acceso a todo lo de delante.

---

## Decisión: secretos y variables de plantilla

Homepage tiene un mecanismo nativo de sustitución: cualquier `{{HOMEPAGE_VAR_*}}` en YAML se reemplaza al cargar por la variable de entorno homónima. Eso permite:

- Escribir `services.yaml` versionable que diga `key: '{{HOMEPAGE_VAR_SONARR_KEY}}'`.
- Mantener el secreto real en `stacks/homepage/.env` (modo `0600`, **no** versionado).
- El operador puede ver la diff de `services.yaml` sin filtrar secretos por accidente.

**Reglas del homelab**:

| Regla | Justificación |
|---|---|
| Cualquier API key, token, password, URL con credenciales embebidas → `HOMEPAGE_VAR_*` en `.env` | Auditoría limpia, secretos fuera de git. |
| URLs internas (sin secretos) → en YAML directamente | Reproducibles, legibles, no son secretos. |
| Variables de personalización del operador (idioma, theme, formato de fecha) → `.env` aunque no sean secretos | Permite cambiar sin tocar YAML para configuraciones personales (la pareja del operador prefiere `de_DE`, p.ej.). |

Listado típico de variables (ver "Configuración → 3" para el detalle):

```bash
# stacks/homepage/.env
HOMEPAGE_VAR_LANG=es
HOMEPAGE_VAR_TITLE="Homelab Pi5"

# Tokens/keys de servicios
HOMEPAGE_VAR_PIHOLE_KEY=<api token Pi-hole>
HOMEPAGE_VAR_SONARR_KEY=<api key Sonarr>
HOMEPAGE_VAR_RADARR_KEY=<api key Radarr>
HOMEPAGE_VAR_PROWLARR_KEY=<api key Prowlarr>
HOMEPAGE_VAR_JELLYFIN_KEY=<api key Jellyfin>
HOMEPAGE_VAR_NAVIDROME_USER=<usuario>
HOMEPAGE_VAR_NAVIDROME_PASS=<password>
HOMEPAGE_VAR_AUDIOBOOKSHELF_TOKEN=<token>
HOMEPAGE_VAR_PAPERLESS_TOKEN=<token>
HOMEPAGE_VAR_MEALIE_TOKEN=<token>
HOMEPAGE_VAR_LINKDING_TOKEN=<token>
HOMEPAGE_VAR_FRESHRSS_USER=<usuario API>
HOMEPAGE_VAR_FRESHRSS_PASS=<password API>
HOMEPAGE_VAR_PROMETHEUS_USER=<basic auth user>
HOMEPAGE_VAR_PROMETHEUS_PASS=<basic auth pass>
HOMEPAGE_VAR_UPTIMEKUMA_USER=<usuario>
HOMEPAGE_VAR_UPTIMEKUMA_PASS=<password>
HOMEPAGE_VAR_PORTAINER_TOKEN=<api key Portainer>
HOMEPAGE_VAR_HOMEASSISTANT_TOKEN=<long-lived access token>
HOMEPAGE_VAR_NEXTCLOUD_USER=<usuario>
HOMEPAGE_VAR_NEXTCLOUD_PASS=<password>
HOMEPAGE_VAR_TRANSMISSION_USER=<usuario>
HOMEPAGE_VAR_TRANSMISSION_PASS=<password>
HOMEPAGE_VAR_MINIO_ACCESS_KEY=<access key>
HOMEPAGE_VAR_MINIO_SECRET_KEY=<secret key>
```

> **Sobre tokens de Vaultwarden**. Vaultwarden no expone una API legible por dashboards (no hay un `/api/v1/info/users` o `/api/v1/info/items`). Homepage se limita a un **link** a `https://vaultwarden.lan/` sin widget — y eso está bien: ver cuántos items tiene el bóveda no aporta nada operativo. La salud del propio Vaultwarden la cubre **Uptime Kuma** (que sí tiene un monitor sobre `https://vaultwarden.lan/alive`).

> **Sobre tokens de Authelia**. Authelia sí expone `/api/state` con autenticación de admin, pero Homepage no tiene un widget canónico. Se omite. La salud de Authelia se monitoriza igualmente vía Uptime Kuma sobre `https://auth.lan/api/health`.

---

## Stack: `stacks/homepage/` y `stacks/docker-socket-proxy/`

### Layout en disco

| Ruta | Soporte | Contenido |
|---|---|---|
| `stacks/homepage/docker-compose.yml` | microSD (git) | Stack de Homepage (un único contenedor). |
| `stacks/homepage/.env.example` | microSD (git) | Plantilla con todas las `HOMEPAGE_VAR_*`. |
| `stacks/homepage/.env` | microSD (NO git) | Versión rellena con tokens reales. Modo `0600`. |
| `stacks/homepage/config/services.yaml` | microSD (git) | Lista de servicios agrupados, con `container:` y `widget:`. |
| `stacks/homepage/config/settings.yaml` | microSD (git) | Layout, theme, idioma, headers, columnas. |
| `stacks/homepage/config/widgets.yaml` | microSD (git) | Widgets superiores (CPU/RAM/disco/temperatura, búsqueda, fecha/hora). |
| `stacks/homepage/config/bookmarks.yaml` | microSD (git) | Bookmarks del operador (docs oficiales, repos, panel router). |
| `stacks/homepage/config/docker.yaml` | microSD (git) | Definición de la(s) instancia(s) Docker (vía socket proxy). |
| `stacks/homepage/config/kubernetes.yaml` | microSD (git) | Vacío (no hay kube). Se mantiene para que Homepage no se queje. |
| `stacks/homepage/config/custom.css` | microSD (git) | CSS custom (vacío por defecto). |
| `stacks/homepage/config/icons/*.svg` | microSD (git) | Iconos custom no incluidos en `selfh.st/icons` o Material Design. |
| `stacks/docker-socket-proxy/docker-compose.yml` | microSD (git) | Sidecar de Tecnativa. |
| `stacks/caddy/conf.d/50-homepage.caddy` | microSD (git) | Drop-in Caddy para `home.${DOMAIN_LAN}`. |

> **Sobre la ausencia de rutas en `/mnt/hd2t/apps/homepage/`**. La Fase 1 (`01-sistema/04-estructura-directorios.md`) reservó `/mnt/hd2t/apps/homepage/data/` por homogeneidad. **No se usa** en este stack. Queda como directorio vacío `0750 homelab:homelab` por si en una iteración futura se activa una feature persistente de Homepage (caché interno, métricas locales) — sin coste mientras no haya ficheros.

### `stacks/docker-socket-proxy/docker-compose.yml`

```yaml
# Tecnativa Docker Socket Proxy — expone selectivamente la API de Docker.
# Convenciones: ver docs/02-docker/02-estructura-compose.md y
# docs/12-dashboards/01-homepage.md.
#
# Consumidores: Homepage (estado de contenedores). Más adelante podrían
# añadirse otros (un exporter Prometheus, p.ej.); su despliegue NO
# requiere reabrir este compose.

name: docker-socket-proxy

services:
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:0.2.0
    container_name: docker-socket-proxy
    hostname: docker-socket-proxy
    restart: unless-stopped

    environment:
      # Endpoints permitidos (GET-only). Cualquier no listado queda denegado
      # por el haproxy interno con 403.
      CONTAINERS: 1
      IMAGES: 1
      NETWORKS: 1
      VOLUMES: 1
      INFO: 1
      VERSION: 1
      # Endpoints DENEGADOS (defensa explícita aunque sean default 0):
      AUTH: 0
      BUILD: 0
      COMMIT: 0
      CONFIGS: 0
      EXEC: 0
      NODES: 0
      PLUGINS: 0
      POST: 0
      SECRETS: 0
      SERVICES: 0
      SESSION: 0
      SWARM: 0
      SYSTEM: 0
      TASKS: 0
      DISTRIBUTION: 0

    networks:
      - homelab

    # NO `ports:`. Solo accesible desde la red Docker `homelab`.
    expose:
      - "2375"

    volumes:
      # Acceso de lectura al socket (la imagen no soporta `:ro` porque haproxy
      # necesita conectarse, pero los endpoints peligrosos están bloqueados).
      - /var/run/docker.sock:/var/run/docker.sock

    read_only: true
    tmpfs:
      - /tmp:size=8m,mode=1777
      - /run:size=8m,mode=0755

    cap_drop:
      - ALL
    cap_add:
      - DAC_OVERRIDE   # leer /var/run/docker.sock (root del host)

    security_opt:
      - "no-new-privileges:true"

    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://127.0.0.1:2375/_ping >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

    labels:
      homelab.role: "docker-api-proxy"
      # NO homelab.backup: nada que respaldar.
      com.centurylinklabs.watchtower.enable: "false"

networks:
  homelab:
    external: true
```

> **Sobre `IMAGES=1`, `NETWORKS=1`, `VOLUMES=1`**. Homepage consulta opcionalmente la lista de imágenes/redes/volúmenes para el widget `Docker Stats`. Aporta valor (ver cuánto disco gasta Docker en imágenes) y son endpoints **GET de sólo lectura**. Aceptados.

> **Sobre `POST=0`**. El bloqueo del método HTTP `POST` es la **última línea de defensa**: aunque alguien lograra que el haproxy aceptara un endpoint malicioso (improbable), no podría disparar `containers/<id>/start`, `containers/create`, `containers/<id>/exec` u otros que requieren POST. Mantener `POST=0` es la defensa de oro.

### `stacks/homepage/docker-compose.yml`

```yaml
# Homepage — dashboard del homelab.
# Convenciones: ver docs/02-docker/02-estructura-compose.md y
# docs/12-dashboards/01-homepage.md.

name: homepage

services:
  homepage:
    image: ghcr.io/gethomepage/homepage:v0.10.9
    container_name: homepage
    hostname: homepage
    restart: unless-stopped

    environment:
      TZ: ${TZ}
      # Permitir que el frontend confíe en el host del Caddy de delante.
      # Sin esto, Homepage 0.9+ rechaza peticiones por una validación de origin
      # introducida en el commit 2024-09 (CVE prevención).
      HOMEPAGE_ALLOWED_HOSTS: "home.${DOMAIN_LAN},${LAN_IP},homepage:3000"

    env_file:
      - .env   # variables HOMEPAGE_VAR_* (tokens, idioma, etc.)

    networks:
      - homelab          # Caddy y socket-proxy llegan por aquí

    expose:
      - "3000"
    # NO `ports:`. Acceso solo vía Caddy.

    # Configuración como código: bind mount READ-ONLY del directorio del repo.
    # Cualquier cambio en YAML se hace en git (commit + git pull en la Pi),
    # NO desde dentro del contenedor.
    volumes:
      - /home/homelab/homelab/stacks/homepage/config:/app/config:ro
      # Iconos custom (subdirectorio de config/, redundante por claridad)
      # - /home/homelab/homelab/stacks/homepage/config/icons:/app/public/icons:ro

    tmpfs:
      - /tmp:size=64m,mode=1777
      - /app/.next/cache:size=64m,mode=0755

    read_only: true

    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://127.0.0.1:3000/api/healthcheck >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

    cap_drop:
      - ALL

    security_opt:
      - "no-new-privileges:true"

    depends_on:
      docker-socket-proxy:
        condition: service_healthy
        required: false   # Homepage arranca sin proxy; sin status de containers.

    labels:
      homelab.role: "dashboard"
      # NO homelab.backup: el repo es la fuente, ya respaldado vía git+Borg.
      com.centurylinklabs.watchtower.enable: "false"

networks:
  homelab:
    external: true
```

> **Sobre `HOMEPAGE_ALLOWED_HOSTS`**. Homepage 0.9+ valida el header `Host:` y rechaza con 400 si no coincide con la lista permitida. Sin esta variable, las peticiones que vienen vía Caddy (que reescribe `Host:` con `home.lan`) son rechazadas y el navegador muestra "Bad Request". El listado incluye también `${LAN_IP}` por si alguna vez se accede directamente por IP (no debería, pero no se rompe).

> **Sobre `depends_on: required: false`**. Si `docker-socket-proxy` está caído, Homepage arranca igualmente y simplemente muestra los servicios sin indicador de estado. Es preferible a no levantar el dashboard. La salud del proxy la cubre Uptime Kuma vía un monitor TCP a `docker-socket-proxy:2375` (ver `05-monitorizacion/05-uptime-kuma.md`).

### `stacks/homepage/.env.example`

```bash
# stacks/homepage/.env.example
# Variables HOMEPAGE_VAR_* referenciadas como {{HOMEPAGE_VAR_FOO}} en los YAML.
# Mantener este fichero en sync con services.yaml/widgets.yaml/bookmarks.yaml.

# --- Personalización (no son secretos pero se centralizan aquí) ---
HOMEPAGE_VAR_LANG=es
HOMEPAGE_VAR_TITLE="Homelab Pi5"

# --- Tokens / API keys (RELLENAR en .env real, NO en .example) ---

# Pi-hole (Settings → API → Show API token)
HOMEPAGE_VAR_PIHOLE_KEY=

# *arr suite (Settings → General → API Key)
HOMEPAGE_VAR_SONARR_KEY=
HOMEPAGE_VAR_RADARR_KEY=
HOMEPAGE_VAR_PROWLARR_KEY=

# Jellyfin (Dashboard → API Keys → +)
HOMEPAGE_VAR_JELLYFIN_KEY=

# Navidrome (auth básica con usuario/password ya creado)
HOMEPAGE_VAR_NAVIDROME_USER=
HOMEPAGE_VAR_NAVIDROME_PASS=

# Audiobookshelf (Settings → Users → API Token)
HOMEPAGE_VAR_AUDIOBOOKSHELF_TOKEN=

# Paperless-ngx (Settings → Users → My Profile → API Token)
HOMEPAGE_VAR_PAPERLESS_TOKEN=

# Mealie (Profile → API Tokens → New)
HOMEPAGE_VAR_MEALIE_TOKEN=

# Linkding (Settings → REST API → API Token)
HOMEPAGE_VAR_LINKDING_TOKEN=

# FreshRSS (Configuración → Cuentas API → habilitar Greader)
HOMEPAGE_VAR_FRESHRSS_USER=
HOMEPAGE_VAR_FRESHRSS_PASS=

# Prometheus (basic auth si la tiene; ver 05-monitorizacion/01-prometheus.md)
HOMEPAGE_VAR_PROMETHEUS_USER=
HOMEPAGE_VAR_PROMETHEUS_PASS=

# Uptime Kuma (cuenta del operador; Homepage habla con la API protegida)
HOMEPAGE_VAR_UPTIMEKUMA_USER=
HOMEPAGE_VAR_UPTIMEKUMA_PASS=

# Portainer (User → My account → Access tokens)
HOMEPAGE_VAR_PORTAINER_TOKEN=

# Home Assistant (Profile → Long-Lived Access Tokens)
HOMEPAGE_VAR_HOMEASSISTANT_TOKEN=

# Nextcloud (cuenta de usuario; Homepage hace API básica)
HOMEPAGE_VAR_NEXTCLOUD_USER=
HOMEPAGE_VAR_NEXTCLOUD_PASS=

# Transmission (RPC user/password, configurado en 10-descargas/01-transmission.md)
HOMEPAGE_VAR_TRANSMISSION_USER=
HOMEPAGE_VAR_TRANSMISSION_PASS=

# MinIO (access/secret del usuario "homepage-readonly", creado en 06-almacenamiento/04-minio.md)
HOMEPAGE_VAR_MINIO_ACCESS_KEY=
HOMEPAGE_VAR_MINIO_SECRET_KEY=
```

### `stacks/homepage/config/settings.yaml`

```yaml
# Configuración global del dashboard.
# Sintaxis: https://gethomepage.dev/configs/settings/

title: '{{HOMEPAGE_VAR_TITLE}}'
language: '{{HOMEPAGE_VAR_LANG}}'
theme: dark
color: slate

# Header del navegador
favicon: /icons/homelab.svg
headerStyle: clean

# Layout: 4 columnas en desktop, responsive a 1 en móvil
layout:
  Infraestructura:
    style: row
    columns: 4
    icon: mdi-server-network
  Multimedia:
    style: row
    columns: 4
    icon: mdi-multimedia
  Productividad:
    style: row
    columns: 4
    icon: mdi-briefcase
  Domótica:
    style: row
    columns: 3
    icon: mdi-home-automation
  Backups y Datos:
    style: row
    columns: 3
    icon: mdi-database-cog
  Bookmarks:
    style: row
    columns: 4

# Polling de widgets: balance entre dato fresco y carga sobre los servicios.
# Pi-hole y *arr aceptan polling agresivo (su dashboard nativo polletea cada 5s).
# Jellyfin/Audiobookshelf con cuidado: cada llamada hace una query a la BBDD.
providers:
  longhorn:
    url: ""
# Globales aplicados a todos los widgets si no se sobreescriben en services.yaml
# Homepage 0.10 no soporta `globalRefresh`; el polling se define por widget.

# Búsqueda integrada (barra superior). Provider DuckDuckGo (no manda
# query a Google, no perfila). Reabrible si el operador prefiere.
quicklaunch:
  searchDescriptions: true
  hideInternetSearch: false
  showSearchSuggestions: false
  hideVisitURL: false

# Idioma / formato de fecha
formatLocale: 'es-ES'

# Hide widgets in error state (cuando un servicio está caído, oculta el
# widget en lugar de mostrar "ERR" — la información de "está caído" la da
# el indicador de container y Uptime Kuma).
hideErrors: false

# Estado de Docker en cada tarjeta
statusStyle: 'dot'
```

### `stacks/homepage/config/docker.yaml`

```yaml
# Conexión Docker vía Tecnativa socket proxy (NO el socket raw).
# Sintaxis: https://gethomepage.dev/configs/docker/

my-docker:
  host: docker-socket-proxy
  port: 2375
```

> **Una sola entrada `my-docker`**: el homelab tiene un único host Docker (la Pi 5). Si en el futuro aparece un segundo host (ej. una Pi 4 dedicada a desarrollos), se añade una segunda entrada `pi4-docker:` y los `services.yaml` referencian `server: my-docker` o `server: pi4-docker`.

### `stacks/homepage/config/kubernetes.yaml`

```yaml
# Sin Kubernetes en el homelab. Fichero vacío para que Homepage no se queje.
mode: disabled
```

### `stacks/homepage/config/widgets.yaml`

```yaml
# Widgets de la cabecera (datos de sistema y barra de búsqueda).
# Sintaxis: https://gethomepage.dev/widgets/info/

- resources:
    backend: resources
    expanded: true
    cpu: true
    cputemp: true
    tempmin: 35
    tempmax: 85
    memory: true
    disk:
      - /              # microSD del sistema (ojo: a menudo un dataset reducido)
      - /mnt/hd5t      # multimedia
      - /mnt/hd2t      # datos + backups
    refresh: 30000

- search:
    provider: duckduckgo
    target: _blank

- datetime:
    text_size: xl
    locale: es
    format:
      timeStyle: short
      dateStyle: long
```

> **Sobre `cputemp` y la temperatura de la Pi 5**. Homepage lee `/sys/class/thermal/thermal_zone0/temp` dentro del contenedor. Para que ese fichero esté disponible **dentro** del contenedor, hay que `bind` montar `/sys/class/thermal:/sys/class/thermal:ro` o usar `pid: host`. Por simplicidad, en este compose **no se monta** y el widget queda con `--`. La temperatura se ve **igualmente** en Grafana vía `node_exporter` (`05-monitorizacion/03-node-exporter.md`). Si el operador insiste, añadir el bind mount; pero rompe parte del hardening (`read_only` del rootfs sigue válido, pero se añade un volumen del host).

> **Sobre los discos `/mnt/hd5t` y `/mnt/hd2t`**. Homepage lee `df` dentro del contenedor. Para que esos paths existan dentro del contenedor, **hay que montarlos en read-only**. Esto **no se hace por defecto**: Homepage no necesita ver el contenido, solo el `df`. Como `df` consulta el sistema de archivos del contenedor, y los discos externos no están montados en él, **el widget de disco mostraría sólo `/`**. Para evitarlo, se añaden bind mounts read-only de los puntos de montaje (que dentro del contenedor sirven sólo para que `df` los vea). Ver "Configuración → 5".

### `stacks/homepage/config/services.yaml`

```yaml
# Servicios del homelab agrupados.
# Sintaxis: https://gethomepage.dev/configs/services/
#
# Convenciones del homelab:
# - Los `href` apuntan al subdominio LAN (https://<svc>.${DOMAIN_LAN}/).
#   Tailscale resuelve el mismo subdominio por MagicDNS desde fuera de casa.
# - Los `widget.url` apuntan al nombre Docker del contenedor (http://<svc>:<puerto>)
#   para que Homepage no salga por Caddy ni por DNS LAN. Más rápido y desacoplado.
# - Los tokens en {{HOMEPAGE_VAR_*}} vienen de stacks/homepage/.env.

- Infraestructura:
    - Portainer:
        href: https://portainer.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Gestión de stacks Docker
        icon: portainer.svg
        server: my-docker
        container: portainer
        widget:
          type: portainer
          url: https://portainer:9443
          env: 1
          accesstoken: '{{HOMEPAGE_VAR_PORTAINER_TOKEN}}'

    - Pi-hole:
        href: https://pihole.{{HOMEPAGE_VAR_DOMAIN}}/admin/
        description: DNS local + ad-blocking
        icon: pi-hole.svg
        widget:
          type: pihole
          url: http://192.168.1.2  # IP macvlan, ver 03-red/02-pihole.md
          key: '{{HOMEPAGE_VAR_PIHOLE_KEY}}'

    - Caddy:
        href: https://caddy.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Reverse proxy + TLS interno
        icon: caddy.svg
        server: my-docker
        container: caddy

    - Tailscale:
        href: https://login.tailscale.com/admin/machines
        description: VPN mesh (admin externo)
        icon: tailscale.svg
        server: my-docker
        container: tailscale

    - Uptime Kuma:
        href: https://uptime.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Monitorización HTTP/TCP
        icon: uptime-kuma.svg
        server: my-docker
        container: uptime-kuma
        widget:
          type: uptimekuma
          url: http://uptime-kuma:3001
          slug: homelab    # status page pública, ver 05-monitorizacion/05

    - Grafana:
        href: https://grafana.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Dashboards de métricas
        icon: grafana.svg
        server: my-docker
        container: grafana

    - Prometheus:
        href: https://prometheus.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Métricas + alertas
        icon: prometheus.svg
        server: my-docker
        container: prometheus
        widget:
          type: prometheusmetric
          url: http://prometheus:9090
          metrics:
            - label: 'CPU %'
              query: '100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100)'
            - label: 'Mem %'
              query: '(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100'

    - Dozzle:
        href: https://dozzle.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Logs en vivo
        icon: dozzle.svg
        server: my-docker
        container: dozzle

    - Authelia:
        href: https://auth.{{HOMEPAGE_VAR_DOMAIN}}/
        description: SSO + 2FA
        icon: authelia.svg
        server: my-docker
        container: authelia

- Multimedia:
    - Jellyfin:
        href: https://jellyfin.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Películas, series, música
        icon: jellyfin.svg
        server: my-docker
        container: jellyfin
        widget:
          type: jellyfin
          url: http://jellyfin:8096
          key: '{{HOMEPAGE_VAR_JELLYFIN_KEY}}'
          enableBlocks: true
          enableNowPlaying: true

    - Navidrome:
        href: https://navidrome.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Música (Subsonic)
        icon: navidrome.svg
        server: my-docker
        container: navidrome
        widget:
          type: navidrome
          url: http://navidrome:4533
          user: '{{HOMEPAGE_VAR_NAVIDROME_USER}}'
          token: '{{HOMEPAGE_VAR_NAVIDROME_PASS}}'

    - Audiobookshelf:
        href: https://audiobooks.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Audiolibros y podcasts
        icon: audiobookshelf.svg
        server: my-docker
        container: audiobookshelf
        widget:
          type: audiobookshelf
          url: http://audiobookshelf:80
          key: '{{HOMEPAGE_VAR_AUDIOBOOKSHELF_TOKEN}}'

    - Calibre-Web:
        href: https://calibre.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Libros (epub)
        icon: calibre-web.svg
        server: my-docker
        container: calibre-web
        widget:
          type: calibreweb
          url: http://calibre-web:8083
          username: '{{HOMEPAGE_VAR_CALIBREWEB_USER}}'
          password: '{{HOMEPAGE_VAR_CALIBREWEB_PASS}}'

    - Stash:
        href: https://stash.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Catálogo multimedia (hd5t)
        icon: stash.svg
        server: my-docker
        container: stash
        # Stash no tiene widget oficial Homepage. Solo tarjeta + status.

- Productividad:
    - Vaultwarden:
        href: https://vaultwarden.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Gestor de contraseñas
        icon: vaultwarden.svg
        server: my-docker
        container: vaultwarden
        # Sin widget: Vaultwarden no expone API legible por dashboards.

    - Bookstack:
        href: https://bookstack.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Wiki interna del homelab
        icon: bookstack.svg
        server: my-docker
        container: bookstack

    - Linkding:
        href: https://linkding.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Bookmarks
        icon: linkding.svg
        server: my-docker
        container: linkding
        widget:
          type: linkding
          url: http://linkding:9090
          key: '{{HOMEPAGE_VAR_LINKDING_TOKEN}}'

    - Paperless-ngx:
        href: https://paperless.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Gestión documental + OCR
        icon: paperless.svg
        server: my-docker
        container: paperless
        widget:
          type: paperlessngx
          url: http://paperless:8000
          key: '{{HOMEPAGE_VAR_PAPERLESS_TOKEN}}'

    - Mealie:
        href: https://mealie.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Recetas y planificación
        icon: mealie.svg
        server: my-docker
        container: mealie
        widget:
          type: mealie
          url: http://mealie:9000
          key: '{{HOMEPAGE_VAR_MEALIE_TOKEN}}'

    - Stirling PDF:
        href: https://stirling.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Caja de herramientas para PDFs
        icon: stirling-pdf.svg
        server: my-docker
        container: stirling-pdf

    - FreshRSS:
        href: https://rss.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Lector de RSS
        icon: freshrss.svg
        server: my-docker
        container: freshrss
        widget:
          type: freshrss
          url: http://freshrss:80
          username: '{{HOMEPAGE_VAR_FRESHRSS_USER}}'
          password: '{{HOMEPAGE_VAR_FRESHRSS_PASS}}'

- Domótica:
    - Home Assistant:
        href: https://hass.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Centralita IoT
        icon: home-assistant.svg
        server: my-docker
        container: homeassistant
        widget:
          type: homeassistant
          url: http://homeassistant:8123
          key: '{{HOMEPAGE_VAR_HOMEASSISTANT_TOKEN}}'

    - Mosquitto:
        href: ""
        description: Broker MQTT (sin UI)
        icon: mosquitto.svg
        server: my-docker
        container: mosquitto

    - Zigbee2MQTT:
        href: https://zigbee.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Puente Zigbee↔MQTT
        icon: zigbee2mqtt.svg
        server: my-docker
        container: zigbee2mqtt

    - Node-RED:
        href: https://nodered.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Automatizaciones
        icon: node-red.svg
        server: my-docker
        container: node-red

- Backups y Datos:
    - Nextcloud:
        href: https://cloud.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Cloud personal
        icon: nextcloud.svg
        server: my-docker
        container: nextcloud
        widget:
          type: nextcloud
          url: http://nextcloud:80
          username: '{{HOMEPAGE_VAR_NEXTCLOUD_USER}}'
          password: '{{HOMEPAGE_VAR_NEXTCLOUD_PASS}}'

    - Syncthing:
        href: https://syncthing.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Sincronización P2P
        icon: syncthing.svg
        server: my-docker
        container: syncthing

    - MinIO:
        href: https://minio.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Almacenamiento S3-compatible
        icon: minio.svg
        server: my-docker
        container: minio
        widget:
          type: minio
          url: http://minio:9000
          access_key: '{{HOMEPAGE_VAR_MINIO_ACCESS_KEY}}'
          secret_key: '{{HOMEPAGE_VAR_MINIO_SECRET_KEY}}'

    - Transmission:
        href: https://transmission.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Cliente BitTorrent
        icon: transmission.svg
        server: my-docker
        container: transmission
        widget:
          type: transmission
          url: http://transmission:9091
          username: '{{HOMEPAGE_VAR_TRANSMISSION_USER}}'
          password: '{{HOMEPAGE_VAR_TRANSMISSION_PASS}}'

    - Sonarr:
        href: https://sonarr.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Series
        icon: sonarr.svg
        server: my-docker
        container: sonarr
        widget:
          type: sonarr
          url: http://sonarr:8989
          key: '{{HOMEPAGE_VAR_SONARR_KEY}}'

    - Radarr:
        href: https://radarr.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Películas
        icon: radarr.svg
        server: my-docker
        container: radarr
        widget:
          type: radarr
          url: http://radarr:7878
          key: '{{HOMEPAGE_VAR_RADARR_KEY}}'

    - Prowlarr:
        href: https://prowlarr.{{HOMEPAGE_VAR_DOMAIN}}/
        description: Indexers
        icon: prowlarr.svg
        server: my-docker
        container: prowlarr
        widget:
          type: prowlarr
          url: http://prowlarr:9696
          key: '{{HOMEPAGE_VAR_PROWLARR_KEY}}'

    - Borgmatic:
        href: ""
        description: Backups (sin UI; logs vía Dozzle)
        icon: borgbackup.svg
        # Borgmatic corre como systemd timer en el host, no en Docker.
        # Sin container: ni widget (no expone API). Tarjeta informativa.
```

> **Sobre `{{HOMEPAGE_VAR_DOMAIN}}`**. Por consistencia, `DOMAIN_LAN` se reexporta en `.env` como `HOMEPAGE_VAR_DOMAIN=lan`. Permite que el `services.yaml` use `{{HOMEPAGE_VAR_DOMAIN}}` en los `href` y mantener Homepage agnóstico al valor concreto si en el futuro cambia (`lan` → `homelab.local`, p.ej.).

> **Sobre los iconos**. Homepage soporta tres formatos: nombre simple (`portainer.svg`), que resuelve contra el repo público `walkxhub/dashboard-icons` o `selfh.st/icons` (ambos con miles de iconos de servicios self-hosted, mantenidos); URL absoluta; o ruta `/icons/foo.svg` que resuelve contra el directorio bind-montado. Para el dashboard del homelab basta con los nombres simples — Homepage los descarga al primer arranque y los cachea en RAM.

> **Sobre el container `borgmatic`**. Borgmatic en este homelab corre como **systemd timer en el host**, no como contenedor (decisión de `07-backups/02-borgmatic.md`). Por tanto la tarjeta es solo informativa, sin `container:`, sin widget. Documenta su existencia para los miembros de la familia.

### `stacks/homepage/config/bookmarks.yaml`

```yaml
# Bookmarks del operador (links externos, no del homelab).
# Sintaxis: https://gethomepage.dev/configs/bookmarks/

- Documentación:
    - Raspberry Pi:
        - abbr: RPi
          href: https://www.raspberrypi.com/documentation/
          icon: raspberrypi.svg
    - Docker:
        - abbr: DOC
          href: https://docs.docker.com/
          icon: docker.svg
    - Caddy:
        - abbr: CDY
          href: https://caddyserver.com/docs/
          icon: caddy.svg
    - Authelia:
        - abbr: AUT
          href: https://www.authelia.com/integration/proxies/caddy/
          icon: authelia.svg

- Repositorios:
    - Homelab:
        - abbr: HL
          href: https://github.com/<usuario>/homelab
          icon: github.svg
    - Homepage upstream:
        - abbr: HP
          href: https://github.com/gethomepage/homepage
          icon: homepage.svg

- Admin externos:
    - Router:
        - abbr: RT
          href: http://192.168.1.1/
          icon: mdi-router-network
    - Tailscale:
        - abbr: TS
          href: https://login.tailscale.com/admin/
          icon: tailscale.svg
```

### `stacks/homepage/config/custom.css`

```css
/* CSS custom del dashboard. Vacío por defecto. */
/* Si el operador quiere personalizar, ejemplos:                              */
/* .group-name { font-weight: 700; }                                          */
/* .service-status-dot { width: 12px; height: 12px; }                         */
```

### `stacks/caddy/conf.d/50-homepage.caddy`

```caddy
# /etc/caddy/conf.d/50-homepage.caddy — bloque LAN para Homepage.
# UI en http://homepage:3000 dentro de `homelab`.
# Auth: forward_auth one_factor (decisión documentada en
# docs/12-dashboards/01-homepage.md → "Decisión: autenticación").

home.{$DOMAIN_LAN} {
    import lan_tls
    import security_headers
    import healthcheck

    # Forzar 1FA Authelia para TODA la ruta. Cualquier endpoint de Homepage
    # (UI, /api/*, /api/healthcheck, SSE) requiere sesión SSO.
    import authelia_one_factor

    reverse_proxy http://homepage:3000 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}

        # SSE: no buffering ni timeouts agresivos para que los widgets
        # reciban actualizaciones live.
        flush_interval -1
    }
}
```

> **Sobre `flush_interval -1`**. Caddy con `flush_interval -1` desactiva el buffering del proxy y manda los chunks de SSE inmediatamente al cliente. Sin esto, los widgets de Homepage parpadean cada 1–2 s en lugar de fluir continuamente. Es un valor seguro para todo HTTP/2 detrás de Caddy con SSE; no perjudica ni a peticiones convencionales (la JSON de los widgets sigue siendo unitaria).

> **Sobre `import authelia_one_factor` único, sin `route` con bypass**. Homepage no tiene endpoints públicos legítimos: incluso `/api/healthcheck` se cierra (Uptime Kuma puede comprobar `/api/healthcheck` con `Authorization: Basic` contra Authelia, ver `05-monitorizacion/05-uptime-kuma.md`). Toda la ruta tras Authelia. **Aceptado**.

### Crear los directorios y desplegar

```bash
# 0) Reservar el subdominio en Pi-hole (si no usa el comodín)
#    El comodín `address=/lan/192.168.1.10` ya cubre `home.lan`. Saltar.

# 1) Crear el directorio /mnt/hd2t/apps/homepage/data/ (vacío, por convención)
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/homepage
sudo install -d -o homelab -g homelab -m 0750 /mnt/hd2t/apps/homepage/data

# 2) Materializar stacks/homepage/.env (RELLENAR los tokens)
cd /home/homelab/homelab
cp stacks/homepage/.env.example stacks/homepage/.env
chmod 0600 stacks/homepage/.env
${EDITOR:-vim} stacks/homepage/.env
# Pegar los tokens reales de cada servicio (ver "Configuración → 3").

# 3) Reexportar DOMAIN_LAN al namespace HOMEPAGE_VAR_*
echo "HOMEPAGE_VAR_DOMAIN=${DOMAIN_LAN:-lan}" >> stacks/homepage/.env

# 4) Drop-in de Caddy
install -o homelab -g homelab -m 0644 \
    stacks/caddy/conf.d/50-homepage.caddy \
    /mnt/hd2t/apps/caddy/etc/conf.d/50-homepage.caddy

# 5) Validar el Caddyfile
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
# Successful

# 6) Levantar primero el socket proxy (Homepage depende de él, soft)
docker compose \
    -f stacks/docker-socket-proxy/docker-compose.yml \
    --env-file .env \
    up -d

# 7) Validar el compose de Homepage
docker compose \
    -f stacks/homepage/docker-compose.yml \
    --env-file .env --env-file stacks/homepage/.env \
    config >/dev/null && echo "compose OK"

# 8) Levantar Homepage
docker compose \
    -f stacks/homepage/docker-compose.yml \
    --env-file .env --env-file stacks/homepage/.env \
    up -d

# 9) Recargar Caddy
docker kill --signal=SIGUSR1 caddy
```

Tras `up -d`:

```bash
docker ps --filter name=homepage --filter name=docker-socket-proxy --format 'table {{.Names}}\t{{.Status}}'
# docker-socket-proxy   Up 30 seconds (healthy)
# homepage              Up 20 seconds (healthy)

# Logs de arranque
docker logs homepage --tail 30
# [INFO] Starting Homepage...
# [INFO] Loaded config from /app/config/
# [INFO] Found 6 groups, 28 services
# [INFO] Server listening on :3000
```

Comprobación de extremo a extremo desde un cliente con la CA instalada:

```bash
# Si no hay sesión Authelia previa, redirige al portal
curl -sI https://home.lan/
# HTTP/2 302
# location: https://auth.lan/?rd=...

# Tras login en navegador (en sesión con cookie authelia_session):
# https://home.lan/
# → carga el dashboard, todos los grupos, los widgets renderizan datos vivos.
```

Si el contenedor `homepage` no llega a `(healthy)` en 1 minuto, lo más probable es:
- **YAML mal formado** en `services.yaml` (un `widget:` sin `type:`, indentación rota). `docker logs homepage` muestra `YAMLException: ...`. Editar el fichero, validar con `docker compose config` (sólo valida el compose, no el YAML interno) o con `yamllint`.
- **Variable `HOMEPAGE_VAR_*` referenciada pero no definida** en `.env`. Homepage no falla — sustituye por la cadena vacía y el widget devuelve 401/500. Visible en el dashboard como widget rojo.
- **`docker-socket-proxy` no responde**. `docker logs docker-socket-proxy` muestra el haproxy activo o, si falla, un error de permisos sobre `/var/run/docker.sock`.

---

## Configuración

### 1) Verificar el dashboard funciona

Abrir desde un navegador con la CA interna y sesión Authelia iniciada:

```
https://home.lan/
```

- Comprobar que se ven los 6 grupos (Infraestructura, Multimedia, Productividad, Domótica, Backups y Datos, Bookmarks).
- Cada tarjeta de servicio que tenga `container:` muestra un punto verde (running), naranja (unhealthy/restarting) o rojo (down).
- Cada widget configurado renderiza datos. Pi-hole muestra "Total queries", "Blocked", "Domains on blocklist". Sonarr muestra "Series", "Wanted", "Queued". Etc.
- En la cabecera, los widgets `resources` muestran CPU%, RAM%, disco /, /mnt/hd5t, /mnt/hd2t.
- La barra de búsqueda DuckDuckGo funciona (escribir y `Enter` abre `duckduckgo.com/?q=...` en una pestaña nueva).

Si una tarjeta de servicio está en rojo aun cuando el contenedor existe, comprobar:
- Que el `container:` del YAML coincide **exactamente** con el `container_name` del compose del servicio (case-sensitive).
- Que `docker-socket-proxy` está saludable: `docker exec docker-socket-proxy wget -qO- http://127.0.0.1:2375/_ping`.
- Que Homepage llega al proxy: `docker exec homepage wget -qO- http://docker-socket-proxy:2375/_ping`.

### 2) Hot-reload de la configuración

Homepage observa `/app/config/` y recarga al detectar `mtime` distinto. Para probar:

```bash
cd /home/homelab/homelab
# Editar settings.yaml: cambiar el title
sed -i 's/Homelab Pi5/Homelab Pi5 ✨/' stacks/homepage/.env

# Forzar la recarga: tocar un YAML del config/ (las HOMEPAGE_VAR_* requieren restart,
# pero el contenido de los YAML SÍ se recarga en caliente)
touch stacks/homepage/config/services.yaml

# Esperar 5 s y refrescar el navegador.
```

> **Importante**: las variables `HOMEPAGE_VAR_*` se leen al **arrancar** el contenedor. Cambiar `.env` requiere `docker compose up -d --force-recreate`. Cambiar el contenido de los YAML no requiere reinicio (Homepage los recarga al vuelo).

### 3) Configurar los widgets uno por uno

Por servicio, generar el token y pegarlo en `stacks/homepage/.env`:

| Servicio | Cómo generar el token | Variable |
|---|---|---|
| Pi-hole | `Settings → API → Show API token` | `HOMEPAGE_VAR_PIHOLE_KEY` |
| Sonarr | `Settings → General → API Key` (autogenerada) | `HOMEPAGE_VAR_SONARR_KEY` |
| Radarr | `Settings → General → API Key` | `HOMEPAGE_VAR_RADARR_KEY` |
| Prowlarr | `Settings → General → API Key` | `HOMEPAGE_VAR_PROWLARR_KEY` |
| Jellyfin | `Dashboard → API Keys → +` con app name `Homepage` | `HOMEPAGE_VAR_JELLYFIN_KEY` |
| Navidrome | Usar usuario/password del operador (Subsonic API usa basic auth) | `HOMEPAGE_VAR_NAVIDROME_USER` / `_PASS` |
| Audiobookshelf | `Settings → Users → <usuario> → API Token` | `HOMEPAGE_VAR_AUDIOBOOKSHELF_TOKEN` |
| Calibre-Web | Usuario/password (no tiene API tokens) | `HOMEPAGE_VAR_CALIBREWEB_USER` / `_PASS` |
| Paperless | `Settings → My Profile → API Token → Generate` | `HOMEPAGE_VAR_PAPERLESS_TOKEN` |
| Mealie | `Profile → API Tokens → New` con nombre `Homepage` | `HOMEPAGE_VAR_MEALIE_TOKEN` |
| Linkding | `Settings → REST API → API Token` | `HOMEPAGE_VAR_LINKDING_TOKEN` |
| FreshRSS | `Configuración → Cuentas API → habilitar Greader` y poner password API | `HOMEPAGE_VAR_FRESHRSS_USER` / `_PASS` |
| Prometheus | Si tiene basic auth, usuario/password | `HOMEPAGE_VAR_PROMETHEUS_USER` / `_PASS` |
| Uptime Kuma | Usuario/password del operador (Homepage habla con `/metrics`) | `HOMEPAGE_VAR_UPTIMEKUMA_USER` / `_PASS` |
| Portainer | `My account → Access tokens → Add` con nombre `Homepage`. Permisos: solo lectura. | `HOMEPAGE_VAR_PORTAINER_TOKEN` |
| Home Assistant | `Profile → Long-Lived Access Tokens → Create Token` con nombre `Homepage` | `HOMEPAGE_VAR_HOMEASSISTANT_TOKEN` |
| Nextcloud | Usuario/password (Homepage usa basic auth contra `/ocs/v1.php/cloud/users/<u>`) | `HOMEPAGE_VAR_NEXTCLOUD_USER` / `_PASS` |
| Transmission | Usuario/password de RPC (definidos en `10-descargas/01-transmission.md`) | `HOMEPAGE_VAR_TRANSMISSION_USER` / `_PASS` |
| MinIO | Crear usuario `homepage-readonly` con policy `readonly` (`mc admin user add ...`) | `HOMEPAGE_VAR_MINIO_ACCESS_KEY` / `_SECRET_KEY` |

Tras rellenar todo, `up -d --force-recreate` y refrescar el dashboard.

> **Sobre tokens "scoped" frente a tokens "full access"**. Para los servicios que lo soportan (Portainer, MinIO, Home Assistant), generar un token con **mínimos permisos posibles** (read-only). Si Homepage es comprometido, el token leakeado no permite acciones destructivas en el servicio destino. Para los que no lo soportan (Sonarr, Radarr, Pi-hole, etc.), el token es full-access del API: aceptable porque el blast radius está acotado al servicio en cuestión y los datos visibles ya están detrás de Authelia en el dashboard.

### 4) Bind mounts adicionales para `cputemp` y discos

Si el operador quiere ver la **temperatura de la Pi 5** en Homepage (no solo en Grafana) y los **% de uso de hd5t / hd2t** (no solo `/`), añadir estos volúmenes al compose de Homepage:

```yaml
volumes:
  - /home/homelab/homelab/stacks/homepage/config:/app/config:ro
  # Para cputemp:
  - /sys/class/thermal/thermal_zone0/temp:/sys/class/thermal/thermal_zone0/temp:ro
  # Para df de los discos externos:
  - /mnt/hd5t:/mnt/hd5t:ro
  - /mnt/hd2t:/mnt/hd2t:ro
```

Y `up -d --force-recreate`. Verificar:

```bash
docker exec homepage cat /sys/class/thermal/thermal_zone0/temp
# 47831  (mili-grados Celsius; en el dashboard sale como 47.8 ºC)

docker exec homepage df -h | grep -E '/mnt/hd(5t|2t)'
# /dev/sda1   4.6T  2.8T  1.6T  64% /mnt/hd5t
# /dev/sdb1   1.9T  1.2T  600G  67% /mnt/hd2t
```

> **Sobre el bind mount de `/mnt/hd5t`**. Aunque sea `:ro`, Homepage **ve el árbol de directorios** de Stash. Es información sensible si el operador no quiere que invitados con sesión Authelia vean nombres de carpetas. Mitigación: este bind mount sirve **solo para `df`**; Homepage no lista contenido. Aun así, decidir caso a caso. Si el operador prefiere no exponerlo y se conforma con ver solo `/`, omitir este bind mount.

### 5) Restringir ciertos servicios a usuarios concretos

Homepage no tiene multi-user (la auth es perimetral). Si el operador quiere mostrar **menos servicios** a la pareja:

- **Opción A**: dos dashboards distintos. Crear `stacks/homepage-family/` con su propio compose y subdominio `family.lan`, con un `services.yaml` filtrado, bajo la misma Authelia. Dos contenedores Homepage. Reabrible cuando aparezca la primera petición concreta.
- **Opción B (preferida hoy)**: un único dashboard, con grupos colapsables. Homepage permite `initiallyCollapsed: true` en el `layout` por grupo — la pareja del operador colapsa "Infraestructura" y "Backups y Datos" y trabaja con "Multimedia" + "Productividad" expandidos. Requiere disciplina pero **no** añade complejidad.

### 6) Monitor en Uptime Kuma

En `https://uptime.${DOMAIN_LAN}/` añadir un **monitor HTTP(s)**:

| Campo | Valor |
|---|---|
| Friendly Name | `Homepage` |
| URL | `https://home.lan/api/healthcheck` |
| HTTP Basic Auth | usuario y password de Authelia (cuenta de monitorización dedicada) |
| Heartbeat Interval | 60 s |
| Retries | 3 |
| Accepted Status Codes | 200 |
| Notification | Telegram + email (Mailrise cuando exista) |
| Public on status page | Sí |

Y un segundo monitor **TCP** sobre `docker-socket-proxy`:

| Campo | Valor |
|---|---|
| Friendly Name | `Docker socket proxy` |
| Type | TCP |
| Host | `docker-socket-proxy` |
| Port | `2375` |
| Heartbeat | 60 s |

> **Sobre el HTTP Basic Auth en Uptime Kuma**. Authelia 4.38+ soporta autenticación básica para clientes que no manejan cookies (status checkers, exporters Prometheus, etc.). El operador crea un usuario dedicado `monitor` con TOTP enrollado pero **no se usa**: Authelia honra `Authorization: Basic <base64(monitor:pass)>` y deja pasar al backend. Documentado en `04-seguridad/01-authelia.md` → "Basic Auth para monitorización".

### 7) Workflow de cambios — git como única fuente de verdad

Cuando el operador quiere añadir un servicio al dashboard, cambiar un widget o reordenar grupos:

```bash
cd /home/homelab/homelab

# 1) Editar el YAML
${EDITOR:-vim} stacks/homepage/config/services.yaml

# 2) Validar la sintaxis YAML (y JSON-schema si yamllint está instalado)
yamllint stacks/homepage/config/services.yaml || echo "WARN: revisar"

# 3) Hot-reload: tocar el fichero (Homepage detecta mtime cambiado)
#    Opcional: si la edición ya cambió mtime, este touch es no-op.
touch stacks/homepage/config/services.yaml

# 4) Verificar en el navegador (refresh de https://home.lan/)

# 5) Commit
git add stacks/homepage/config/services.yaml
git commit -m "homepage: add jellyfin widget"

# 6) Push al remoto
git push
```

Si añadir un widget requirió un nuevo `HOMEPAGE_VAR_*`, el workflow incluye además:

```bash
# Editar .env.example (versionable, sin valores reales)
${EDITOR:-vim} stacks/homepage/.env.example

# Editar .env real (no versionable) y añadir el token
${EDITOR:-vim} stacks/homepage/.env
chmod 0600 stacks/homepage/.env

# Recreate para que la nueva variable se cargue
docker compose -f stacks/homepage/docker-compose.yml \
    --env-file .env --env-file stacks/homepage/.env \
    up -d --force-recreate

# Commit del .env.example actualizado
git add stacks/homepage/.env.example
git commit -m "homepage: add HOMEPAGE_VAR_LINKDING_TOKEN"
```

---

## Almacenamiento

| Ruta | Soporte | Owner:Group | Modo | Contenido |
|---|---|---|---|---|
| `/home/homelab/homelab/stacks/homepage/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack versionado en git. |
| `/home/homelab/homelab/stacks/homepage/.env.example` | microSD | `homelab:homelab` | `0644` | Plantilla versionada. |
| `/home/homelab/homelab/stacks/homepage/.env` | microSD | `homelab:homelab` | `0600` | Tokens API reales. **No** versionado. |
| `/home/homelab/homelab/stacks/homepage/config/*.yaml` | microSD | `homelab:homelab` | `0644` | Configuración del dashboard. **Versionado**. Bind-montado **read-only** dentro del contenedor. |
| `/home/homelab/homelab/stacks/homepage/config/icons/` | microSD | `homelab:homelab` | `0755` | Iconos custom (vacío por defecto; `selfh.st/icons` resuelve los típicos). |
| `/home/homelab/homelab/stacks/homepage/config/custom.css` | microSD | `homelab:homelab` | `0644` | CSS custom (vacío por defecto). **Versionado**. |
| `/home/homelab/homelab/stacks/docker-socket-proxy/docker-compose.yml` | microSD | `homelab:homelab` | `0640` | Stack del proxy. **Versionado**. |
| `/home/homelab/homelab/stacks/caddy/conf.d/50-homepage.caddy` | microSD | `homelab:homelab` | `0644` | Drop-in Caddy. **Versionado**. |
| `/mnt/hd2t/apps/caddy/etc/conf.d/50-homepage.caddy` | hd2t | `homelab:homelab` | `0644` | Drop-in materializado (bind mount, reload por SIGUSR1). |
| `/mnt/hd2t/apps/homepage/data/` | hd2t | `homelab:homelab` | `0750` | **Vacío**. Reservado por convención de Fase 1; sin uso. |
| `/var/run/docker.sock` (host) | microSD | `root:docker` | `0660` | Socket Docker, accedido **solo** por el sidecar `docker-socket-proxy`. |

> **Sobre la ausencia de bind mounts en `/mnt/hd2t/apps/homepage/data/`**. Reservada por homogeneidad en `01-sistema/04-estructura-directorios.md`. Si en una iteración futura Homepage se vuelve stateful (cache local, métricas internas), se montaría aquí — sin coste mientras el directorio quede vacío.

> **Sobre los permisos del socket de Docker**. El sidecar `docker-socket-proxy` corre como root con `cap_add: [DAC_OVERRIDE]` para abrir el socket. Es la **única** vía por la que el daemon Docker se expone a otros contenedores en la red `homelab`. Cualquier otro consumidor que se añada (Dozzle ya tiene el suyo propio en `05-monitorizacion/06-dozzle.md`, un exporter Prometheus, etc.) debería usar este proxy en lugar del socket raw.

---

## Backup

A nivel del repositorio del homelab:

| Artefacto | Estrategia |
|---|---|
| `stacks/homepage/docker-compose.yml`, `.env.example`, `config/*.yaml`, `config/custom.css`, `config/icons/*` | Versionados en git. Reproducibles tras un reflasheo. |
| `stacks/docker-socket-proxy/docker-compose.yml` | Versionado en git. |
| `stacks/caddy/conf.d/50-homepage.caddy` | Versionado en git (se materializa en `/mnt/hd2t/apps/caddy/etc/conf.d/`). |
| `stacks/homepage/.env` (con tokens API reales) | **No** versionado. Respaldado por Borg como parte de `/home/homelab/homelab/`. Cada token es regenerable desde la UI del servicio destino. |
| Decisiones (auth one_factor, socket proxy, configuración como código, hot-reload) | Documentadas en este fichero. |

A nivel de datos (Borgmatic, Fase 7):

| Ruta | ¿Se respalda? | Por qué |
|---|---|---|
| `/home/homelab/homelab/stacks/homepage/` | **Sí**, como parte de `/home/homelab/homelab/` (T1 — el repo es **la** fuente de verdad del homelab). | `.env` con los tokens reales, `config/*.yaml` con la lista de servicios. |
| `/mnt/hd2t/apps/homepage/data/` | Excluido (vacío). | Reservado por convención, sin contenido. |
| `/mnt/hd2t/apps/caddy/etc/conf.d/50-homepage.caddy` | **Sí**, como parte de `/mnt/hd2t/apps/caddy/` (T1). | Materialización del drop-in. |
| Imagen del contenedor (`ghcr.io/gethomepage/homepage:v0.10.9`) | Excluido. Re-descargable. | Tag exacto fijado, los registros públicos no se borran. Si el registro estuviera caído tras un disaster, se rebuilda local con `docker save` previo a la pérdida (procedimiento en `13-operaciones/02-disaster-recovery.md`). |

Patrón de exclusión en `borgmatic.yaml` (sección `exclude_patterns`):

```yaml
exclude_patterns:
  # Homepage no necesita exclusiones específicas: el directorio
  # /mnt/hd2t/apps/homepage/data/ está vacío y no aporta ruido.
  # Por consistencia con otros stacks "stateless" (Stirling), no se añade nada.
```

Procedimiento de restore tras pérdida del contenedor (datos intactos en repo):

```bash
docker compose \
    -f /home/homelab/homelab/stacks/docker-socket-proxy/docker-compose.yml \
    --env-file /home/homelab/homelab/.env \
    up -d
docker compose \
    -f /home/homelab/homelab/stacks/homepage/docker-compose.yml \
    --env-file /home/homelab/homelab/.env \
    --env-file /home/homelab/homelab/stacks/homepage/.env \
    up -d --force-recreate
# Sin estado que recuperar: el dashboard arranca idéntico al instante.
```

Procedimiento de restore tras pérdida total (reflasheo + restauración Borg):

1. Recrear sistema base (Fase 1), Docker (Fase 2.1), red `homelab` (Fase 2.2), Pi-hole (`02-pihole.md`), Caddy (`04-caddy.md`), Authelia (`01-authelia.md`).
2. Restaurar el repo `/home/homelab/homelab/` desde Borg (incluye `stacks/homepage/.env` con los tokens).
3. `cd /home/homelab/homelab && docker compose -f stacks/docker-socket-proxy/docker-compose.yml up -d`.
4. `docker compose -f stacks/homepage/docker-compose.yml --env-file .env --env-file stacks/homepage/.env up -d`.
5. Verificar `https://home.lan/` → dashboard idéntico al que existía antes de la pérdida.

> **Punto de no retorno**: si los **tokens de los servicios** son inválidos tras restore (porque el operador, durante el desastre, regeneró tokens), Homepage muestra widgets en error pero el resto del dashboard funciona. Procedimiento: regenerar token en el servicio, actualizar `.env`, `up -d --force-recreate`. El dashboard no es crítico; un widget caído no compromete ningún servicio destino.

---

## Errores frecuentes y troubleshooting

| Síntoma | Causa probable | Resolución |
|---|---|---|
| El dashboard muestra `Bad Request` desde Caddy | `HOMEPAGE_ALLOWED_HOSTS` no incluye el host del navegador (`home.lan`). | Editar el compose y añadir el host. `up -d --force-recreate`. |
| Todas las tarjetas en gris (sin estado) | `docker-socket-proxy` no responde o Homepage no lo encuentra. | `docker exec homepage wget -qO- http://docker-socket-proxy:2375/_ping`. Si falla, comprobar la red `homelab` en ambos compose y los logs del proxy (`docker logs docker-socket-proxy`). |
| Tarjeta de un servicio en rojo aunque el contenedor está `Up (healthy)` | El nombre `container:` del YAML no coincide con `container_name` (case-sensitive, espacios o guiones invertidos). | Editar `services.yaml` y poner el nombre exacto que muestra `docker ps --format '{{.Names}}'`. Hot-reload. |
| Widget de Pi-hole muestra "Error" o todo a `0` | API token mal copiado, o Pi-hole en macvlan inalcanzable desde `homelab`. | Comprobar conectividad: `docker exec homepage wget -qO- http://192.168.1.2/admin/api.php?summary&auth=<token>`. Si falla, revisar la macvlan-shim en el host (ver `03-red/01-macvlan.md`). |
| Widget de Sonarr/Radarr muestra "Unauthorized" | API key incorrecta en `.env`, o Sonarr/Radarr con baseurl distinto del default. | Verificar la API key en `Settings → General`. Si Sonarr usa baseurl (`/sonarr`), añadir `path: /sonarr` al widget en `services.yaml`. |
| Widget de Jellyfin muestra "ECONNREFUSED" | Jellyfin escucha en `:8096` pero el `widget.url` apunta a `:8920` (HTTPS interno) o viceversa. | El homelab usa `:8096` HTTP plano (TLS lo hace Caddy). Verificar `expose: 8096` en el compose de Jellyfin. |
| Hot-reload no detecta el cambio en `services.yaml` | El bind mount es `:ro` pero **el ínodo cambia** cuando algunos editores (vim con `set backup`) escriben a un fichero temporal y lo renombran. Homepage observa el inode original. | Editar in-place (`vim -n` o `nano`) o forzar `touch` después del save. |
| El operador edita `.env` y nada cambia tras refrescar | Las variables `HOMEPAGE_VAR_*` se leen al **arrancar** el contenedor, no en hot-reload. | `docker compose -f stacks/homepage/docker-compose.yml up -d --force-recreate`. |
| `docker logs homepage` muestra `YAMLException: bad indentation` y el contenedor reinicia en loop | Editor con indentación tab/spaces inconsistente, o un `:` en un valor sin comillas (URLs con `:`). | Validar con `yamllint stacks/homepage/config/services.yaml` o pegar en un linter online. Encerrar URLs entre comillas simples. |
| Iconos de servicios aparecen como "?" o el icono por defecto | Homepage no resolvió el nombre contra `selfh.st/icons` o `walkxhub/dashboard-icons`. Probable falta de DNS o ad-block agresivo en Pi-hole. | Comprobar `docker exec homepage wget -qO- https://cdn.jsdelivr.net/gh/selfhst/icons/svg/jellyfin.svg` (debe responder 200). Si falla, revisar que Pi-hole no esté bloqueando `cdn.jsdelivr.net`. Alternativa: descargar los SVG localmente a `config/icons/` y referenciar `/icons/<nombre>.svg`. |
| Widgets parpadean o se "cortan" cada 1-2 s | Caddy buffea SSE. | Asegurarse de `flush_interval -1` en el `reverse_proxy` del drop-in `50-homepage.caddy`. `caddy reload`. |
| El widget `resources` muestra `--` en `cputemp` | El bind mount `/sys/class/thermal/thermal_zone0/temp:ro` no está, o el contenedor corre con `read_only: true` sin tmpfs adecuado. | Añadir el bind mount (sección "Configuración → 4") o aceptar que la temperatura se ve solo en Grafana. |
| Tras un upgrade de Homepage (`v0.10.9` → `v0.11.0`), la página devuelve 500 con "Cannot read properties of undefined" | Breaking change en la sintaxis de `widgets.yaml` o `services.yaml`. | Hacer rollback al tag exacto anterior (`docker compose down && tag = v0.10.9 && up -d`), leer el changelog upstream y migrar el YAML. |
| Authelia redirige al portal incluso tras login válido | Cookie `authelia_session` con `Domain=auth.lan` no compartida con `home.lan` (entre subdominios la cookie tiene que tener `Domain=lan`). | Verificar `session.cookies[].domain` en `configuration.yml` de Authelia. Debe ser `lan` (genérico), no `auth.lan` (específico). |
| `docker-socket-proxy` reporta `503 Service Unavailable` para `/containers/json` | El haproxy interno está bloqueando un endpoint que el cliente (Homepage) sí intenta llamar. | Revisar `CONTAINERS=1` en el `.env` del proxy. Si el endpoint llamado es `/exec` u otro, está bien que se bloquee — ese **no** es un endpoint que Homepage debería llamar (CVE? bug?). Investigar antes de relajar. |

---

## Decisiones que **no** se toman en este documento

- **Vista pública sin Authelia para invitados de Tailscale**. Homepage queda detrás de Authelia (`one_factor`). Si la pareja del operador entra desde su móvil con Tailscale, debe loguearse igual. Es la **decisión consciente**: aunque el dashboard sea poco sensible, exponerlo sin auth en la red Tailscale añadiría un camino "fácil" para alguien que se conecte como invitado de la tailnet (improbable, pero el coste de un login es 5 segundos). Reabrible si la fricción se vuelve un problema real.
- **Multi-dashboard por persona** (Opción A de "Configuración → 5"). Diferido hasta que aparezca la primera petición concreta.
- **Homepage como página de inicio del navegador del operador**. Es preferencia personal: poner `https://home.lan/` como `homepage` del Firefox/Chrome del operador y de cada miembro de la familia. No requiere configuración del homelab.
- **Mostrar logs en el dashboard**. Homepage no tiene un widget canónico para logs. La función la cubre **Dozzle** (`05-monitorizacion/06-dozzle.md`) con su propia UI. Reabrible si Homepage añade widget para Dozzle.
- **Embedding de iframes** (Grafana, Hass map). Diferido por complejidad de cookies cross-domain con Authelia. Hoy se prefiere el link "abrir en nueva pestaña".
- **Search providers múltiples** (Brave, Kagi, etc.). DuckDuckGo es el default; reabrible.
- **Rate limit propio en Caddy para `home.lan`**. Innecesario: la auth por Authelia ya descarta peticiones anónimas; las peticiones autenticadas son las del propio operador. Sin abuso esperable.
- **Métricas Prometheus de Homepage**. No expone `/metrics`. Reabrible si aparece un `homepage-exporter` que parse el log y publique métricas — hoy basta con cAdvisor.
- **Failover si la Pi cae**. Homepage no es crítico (el operador navega los servicios por bookmark si Homepage falla). Cero coste mantener el dashboard sin alta disponibilidad.

---

## Verificación Final

Antes de pasar a la Fase 13:

| Comprobación | Comando | Resultado esperado |
|---|---|---|
| Stack `docker-socket-proxy` desplegado y saludable | `docker compose -f stacks/docker-socket-proxy/docker-compose.yml ps` | `docker-socket-proxy ... Up (healthy)` |
| Stack `homepage` desplegado y saludable | `docker compose -f stacks/homepage/docker-compose.yml ps` | `homepage ... Up (healthy)` |
| Imágenes correctas y fijas | `docker inspect homepage docker-socket-proxy --format '{{.Config.Image}}'` | `ghcr.io/gethomepage/homepage:v0.10.9` y `tecnativa/docker-socket-proxy:0.2.0` |
| Conectados a `homelab`, sin `ports:` | `docker port homepage; docker port docker-socket-proxy` | (vacío en ambos) |
| Caddy alcanza Homepage por DNS Docker | `docker exec caddy wget -qO- http://homepage:3000/api/healthcheck \| head -1` | `{"status":"healthy"}` |
| Homepage alcanza el socket proxy | `docker exec homepage wget -qO- http://docker-socket-proxy:2375/_ping` | `OK` |
| `/api/healthcheck` responde tras Authelia | `curl -sI -u monitor:<pass> https://home.lan/api/healthcheck` (con Authelia Basic Auth habilitada) | `HTTP/2 200` |
| Sin auth, redirige a Authelia | `curl -sI https://home.lan/` | `HTTP/2 302` con `location: https://auth.lan/?rd=...` |
| Cert hoja firmado por la CA local | `echo \| openssl s_client -connect home.lan:443 -servername home.lan 2>/dev/null \| openssl x509 -noout -issuer` | `issuer=CN=Homelab Internal CA` |
| Hardening activo en Homepage | `docker inspect homepage --format '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.SecurityOpt}}'` | `true [no-new-privileges:true]` |
| Capabilities mínimas | `docker inspect homepage --format '{{.HostConfig.CapDrop}} {{.HostConfig.CapAdd}}'` | `[ALL] []` |
| Hardening activo en socket proxy | `docker inspect docker-socket-proxy --format '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapAdd}}'` | `true [DAC_OVERRIDE]` |
| Bind mount RO del config | `docker inspect homepage --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Mode}}){{"\n"}}{{end}}' \| grep config` | `.../stacks/homepage/config -> /app/config (ro)` |
| Configuración carga sin errores | `docker logs homepage 2>&1 \| grep -E 'YAMLException\|Loaded config'` | `Loaded config from /app/config/` y ninguna `YAMLException` |
| Dashboard renderiza los grupos | navegar a `https://home.lan/` con sesión Authelia | 6 grupos visibles, tarjetas con punto verde, widgets cargan datos |
| Hot-reload funciona | `touch stacks/homepage/config/services.yaml; sleep 5; docker logs homepage --tail 5` | `Reloaded config` o equivalente |
| Variables `HOMEPAGE_VAR_*` aplicadas | `docker exec homepage env \| grep HOMEPAGE_VAR \| wc -l` | número ≥ 20 (todas las del `.env`) |
| Monitor Uptime Kuma activo | UI Uptime Kuma, monitor `Homepage` | verde con latencia < 200 ms |
| Monitor TCP del socket proxy activo | UI Uptime Kuma, monitor `Docker socket proxy` | verde |
| Stack en git (sin secretos) | `git status; git ls-files stacks/homepage stacks/docker-socket-proxy stacks/caddy/conf.d/50-homepage.caddy` | `docker-compose.yml`, `.env.example`, `config/*.yaml`, `config/custom.css`, `50-homepage.caddy` tracked; `stacks/homepage/.env` ignorado |
| Datos persisten tras reboot | `sudo reboot`; tras reconectar: `docker ps --filter name=homepage --filter name=docker-socket-proxy` | ambos `Up ... (healthy)` sin acción manual; el dashboard sigue idéntico |

Cumplido el último punto, el homelab tiene un dashboard único en `https://home.lan/` con TLS interno, auth `one_factor` Authelia, **configuración como código** versionada en git, integración Docker vía socket proxy de Tecnativa (sin exponer `/var/run/docker.sock`), widgets vivos para todos los servicios con API legible, hot-reload sin reinicios, monitor Uptime Kuma con alerta en Telegram + email, y cero estado persistente. La siguiente puerta es **operaciones y mantenimiento periódico**, en `13-operaciones/01-mantenimiento-periodico.md`.

---

## Referencias

- [Documento siguiente: `docs/13-operaciones/01-mantenimiento-periodico.md`](../13-operaciones/01-mantenimiento-periodico.md)
- [Documento relacionado: `docs/02-docker/02-estructura-compose.md`](../02-docker/02-estructura-compose.md)
- [Documento relacionado: `docs/03-red/04-caddy.md`](../03-red/04-caddy.md)
- [Documento relacionado: `docs/04-seguridad/01-authelia.md`](../04-seguridad/01-authelia.md)
- [Documento relacionado: `docs/05-monitorizacion/05-uptime-kuma.md`](../05-monitorizacion/05-uptime-kuma.md)
- [Documento relacionado: `docs/05-monitorizacion/06-dozzle.md`](../05-monitorizacion/06-dozzle.md)
- [Documento relacionado: `docs/01-sistema/04-estructura-directorios.md`](../01-sistema/04-estructura-directorios.md)
- [Homepage — Documentación oficial](https://gethomepage.dev/)
- [Homepage — Configuración (`services.yaml`, `widgets.yaml`, `settings.yaml`, `bookmarks.yaml`)](https://gethomepage.dev/configs/)
- [Homepage — Widgets disponibles](https://gethomepage.dev/widgets/)
- [Homepage — Imagen Docker oficial (GHCR)](https://github.com/gethomepage/homepage/pkgs/container/homepage)
- [Homepage — Repositorio GitHub](https://github.com/gethomepage/homepage)
- [Tecnativa Docker Socket Proxy — Repositorio GitHub](https://github.com/Tecnativa/docker-socket-proxy)
- [Tecnativa Docker Socket Proxy — Imagen Docker Hub](https://hub.docker.com/r/tecnativa/docker-socket-proxy)
- [selfh.st/icons — Iconos de servicios self-hosted](https://selfh.st/icons/)
- [walkxhub/dashboard-icons — Iconos alternativos](https://github.com/walkxcode/dashboard-icons)
