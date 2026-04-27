# Homepage (dashboard estático autohospedado)

## Descripción

Despliegue de **Homepage** como **dashboard de inicio** del homelab: una página única servida en `https://homepage.lan/` que **enumera y agrupa los ~30 servicios desplegados en las once fases anteriores**, muestra **widgets en vivo** con datos extraídos por API (consultas DNS bloqueadas por Pi-hole en las últimas 24 h, ancho de banda actual de Transmission, espacio libre en `hd2t`/`hd5t`, número de _unread_ en FreshRSS, _queue_ activa de Sonarr/Radarr, temperatura de la Pi vía Node Exporter, estado de los _containers_ vía Docker o Portainer, último _check_ de Uptime Kuma) y deja a un click el resto de _UIs_ (Jellyfin, Nextcloud, Home Assistant, Vaultwarden, Bookstack, Grafana, Portainer, Authelia…). Es la **página de inicio** que el operador y la familia abren al teclear `lan` en la barra del navegador — la pantalla que sustituye al "abrir 8 pestañas a mano para ver si todo funciona" tras un reinicio o tras una semana sin tocar el homelab.

Este documento **estrena el _stack_ `dashboards`** (`~/homelab/dashboards/`), reservado en `docs/02-docker/02-estructura-compose.md` como décimo y último _stack_ del homelab. Hasta este punto el repositorio Compose tiene nueve _stacks_ vivos (`infra`, `red`, `seguridad`, `monitor`, `almacen`, `domotica`, `multimedia`, `descargas`, `productividad`). Aquí se materializa el primero (y, por ahora, único) servicio del nuevo _stack_:

- **`homepage`** — aplicación Next.js servida como _Node.js standalone_ por la imagen oficial `ghcr.io/gethomepage/homepage:v0.10.9`. Una sola pieza: el binario sirve la web UI estática + un _backend_ ligero que consulta APIs de los servicios integrados (Pi-hole, Sonarr, Jellyfin, Portainer, Prometheus, etc.) y devuelve el JSON renderizado por los _widgets_. Persistencia **cero** dentro del contenedor: toda la configuración vive en cinco ficheros YAML (`services.yaml`, `settings.yaml`, `widgets.yaml`, `bookmarks.yaml`, `docker.yaml`) bind-mounteados desde `~/homelab/dashboards/homepage/config/` — versionables en git, _diff_-eables, _commit_-eables. Sin BD, sin estado, sin _cache_ persistente: `docker compose down && docker compose up -d` deja la aplicación idéntica.

Caddy (stack `red`, `docs/03-red/04-caddy.md`) expone Homepage en `https://homepage.lan/` con TLS interno (CA local). Para acceso remoto vía Tailscale (`docs/03-red/05-tailscale.md`), `https://pi.<tailnet>.ts.net/` con MagicDNS sirve la misma página al móvil cuando el operador está fuera de la LAN y quiere abrir Jellyfin desde el AVE — Homepage funciona como **único punto de entrada** que centraliza los enlaces; sin él el operador tendría que recordar `jellyfin.lan`, `vaultwarden.lan`, `bookstack.lan`… 30 hostnames.

> **Alcance**: este documento despliega Homepage **sin autenticación delegada a Authelia** (decisión justificada en **Decisiones de diseño** → _forward_auth: NO_), con **configuración 100 % declarativa** (cinco YAMLs versionados en git), **sin _Docker socket discovery_** (los servicios se enumeran a mano por seguridad — ver **Decisiones de diseño** → _Docker socket: NO_), con widgets activos para los servicios principales del homelab que ya están desplegados (Pi-hole, Portainer, Jellyfin, Sonarr/Radarr/Prowlarr, Transmission, Nextcloud, Vaultwarden, FreshRSS, Uptime Kuma, Grafana, Home Assistant, Stash) y con la entrada en Borgmatic correspondiente (Categoría F — sólo configuración, sin BD). **No** se añade Authelia delante (queda como **opcional** al final del documento). **No** se monta `/var/run/docker.sock` (queda como **opcional** sólo para el operador que asuma el riesgo). **No** se configuran widgets de servicios aún no desplegados (los placeholders quedan comentados, listos para activar según se vayan añadiendo nuevos servicios al homelab).

> **Recordatorio de red**: Homepage **no se publica al host**. Caddy la alcanza por DNS interno de Docker (`homepage:3000` en la red `homelab`). La aplicación **sólo responde** a peticiones que llegan a través de Caddy — no hay puerto 3000 expuesto al exterior. Pi-hole resuelve `homepage.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`).

---

## Requisitos previos

- `docs/02-docker/02-estructura-compose.md` completado: la tabla de stacks reserva el _slot_ `dashboards`, la red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) externa está creada, `~/homelab/.env` global con `TZ=Europe/Madrid`, `PUID=1000`, `PGID=1000`, `HOMELAB_DOMAIN=lan` está rellenado, y el _Makefile_ de operación expone `make up STACK=<stack>`.
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/homepage/` ya existe vacío (reservado para futuras necesidades — _icon cache_ persistente, custom logos —, **no se usa** para la configuración principal en este documento).
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada. Homepage aparece en la lista de **opt-in** desde el principio (justificación en **Decisiones de diseño**).
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3`. **No hay que añadir nada** para `homepage.lan` — el _wildcard_ ya lo cubre.
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen, y la directiva `import /etc/caddy/snippets/*.caddy` está activa en el `Caddyfile`. La CA local ya firma `*.lan`.
- `docs/07-backups/03-backup-docker-volumes.md` completado: el conjunto de _hooks_ de Borgmatic está cargado, y la `source_directories` global del `config.yaml` ya incluye `~/homelab/` (donde vive la configuración de este servicio). La nota previa `# Homepage: /mnt/hd2t/services/homepage/config/` se **revisa** en este documento (la configuración real vive en `~/homelab/dashboards/homepage/config/`, ya cubierta por el repo git).
- _Stacks_ previos vivos. Homepage no _depende_ funcionalmente de ninguno (renderiza igual sin nadie detrás), pero los **widgets** quedarán inactivos para los servicios que no respondan. La lista esperada de servicios **al menos parcialmente operativos** para que el dashboard tenga sentido el primer día:
  - **Stack `red`**: Pi-hole, Caddy.
  - **Stack `infra`**: Portainer, Watchtower, Dozzle.
  - **Stack `monitor`**: Prometheus, Grafana, Uptime Kuma.
  - **Stack `almacen`**: Nextcloud (al menos web UI).
  - **Stack `multimedia`**: Jellyfin (al menos web UI).
  - **Stack `descargas`**: Transmission, Sonarr, Radarr, Prowlarr (al menos web UI).
  - **Stack `productividad`**: Vaultwarden, Bookstack, FreshRSS (al menos web UI).
  - **Stack `domotica`**: Home Assistant.
- Conectividad saliente para descargar la imagen (sólo la primera vez):
  ```bash
  docker pull --platform linux/arm64 ghcr.io/gethomepage/homepage:v0.10.9 >/dev/null && echo OK
  ```
- Que el host **no** tenga ya un servicio escuchando en `:3000` por error (`docker ps --format '{{.Names}} {{.Ports}}' | grep ':3000->' || echo OK`). Este _stack_ no publica puertos al host; Caddy es quien recibe el tráfico HTTPS.
- Espacio en `~/homelab/`: Homepage no consume nada relevante (la configuración entera son ~30 KB de YAML; la imagen ocupa ~150 MB en `data-root`, ya en `/mnt/hd2t/system/docker/`). El _stack_ es el más ligero del homelab.
- **API tokens / API keys** ya generados en los servicios que se van a integrar como widgets. Lo recomendable es **generarlos a medida que se rellena `services.yaml`** (sección **Configuración estática**); aquí basta con anticiparlos:
  - **Pi-hole**: `Settings → API → Show API token` (ver `docs/03-red/02-pihole.md`).
  - **Portainer**: `User settings → Access tokens → Add access token` (ver `docs/02-docker/03-portainer.md`).
  - **Jellyfin**: `Dashboard → API Keys → New API key` (ver `docs/09-multimedia/01-jellyfin.md`).
  - **Sonarr / Radarr / Prowlarr**: `Settings → General → API Key` (ver `docs/10-descargas/0[2-4].md`).
  - **Transmission**: usuario/password del _RPC_ (ver `docs/10-descargas/01-transmission.md`).
  - **Nextcloud**: opcional, sólo si se quiere widget de _free space_ (App Password en `Settings → Security`).
  - **Vaultwarden**: no expone API legible para Homepage — sólo se enlaza, sin widget.
  - **FreshRSS**: la **API password** generada en `docs/11-productividad/07-freshrss.md` (la misma que usan Reeder/Newsfold).
  - **Uptime Kuma**: NO tiene API tokens estables; el widget de Homepage usa _scraping_ del JSON público de la _status page_ (ver `docs/05-monitorizacion/05-uptime-kuma.md`, sección de _status pages_).
  - **Grafana**: `Configuration → Service accounts → Add service account → Add token` (ver `docs/05-monitorizacion/02-grafana.md`).
  - **Home Assistant**: _Long-Lived Access Token_ desde el perfil de usuario (ver `docs/08-domotica/01-home-assistant.md`).

---

## Decisiones de diseño

### Por qué Homepage (y no Heimdall / Dashy / Flame / Glance / Organizr)

El homelab necesita **un punto de entrada único** que cumpla a la vez: enumerar 30+ servicios sin que el operador tenga que recordar URLs, mostrar _widgets_ con datos en vivo (no sólo _bookmarks_), tener configuración **versionable en git** (no clicks en una UI), soportar ARM64 maduro, y un _footprint_ pequeño (es la duodécima/decimotercera aplicación del homelab; la Pi 5 ya empieza a notar la presión de RAM tras los 30+ contenedores). Cinco candidatos descartados y por qué:

| Candidato      | Por qué se descarta                                                                                                                                                                                                                          |
|----------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Heimdall**     | Histórico, primer dashboard del ecosistema homelab. Configuración **vive en su BD SQLite interna**, gestionada desde la propia UI con clicks. Imposible versionar el dashboard como código. Mantenimiento upstream lento (releases muy espaciadas). El operador acaba haciendo capturas de pantalla del dashboard como "backup". |
| **Dashy**        | Configuración YAML versionable, buenos temas, pero el _runtime_ está empaquetado como una **SPA estática + Node.js** que recompila el frontend al cambiar la config (re-build interno tras cada `restart`). En ARM64 ese build tarda 30-60 s y consume RAM. Los widgets son menos completos que en Homepage. |
| **Flame**        | Minimalista, ligero (binario Go + frontend React), pero los widgets son **pocos** (clima, Docker, búsqueda) y no cubren las APIs específicas de los _arr_ stack, Pi-hole, Jellyfin, Home Assistant. Para un homelab tan rico, queda corto. |
| **Glance**       | Muy joven (2024), excelente _look & feel_ y configuración YAML, pero los widgets de Glance son más bien **agregadores genéricos** (RSS, Hacker News, GitHub, Reddit, Twitch) — útiles como "page de inicio personal" pero no como **panel de control del homelab**. No tiene widget de Sonarr/Radarr, Pi-hole, Jellyfin, etc. con la profundidad de Homepage. |
| **Organizr**     | Más cercano a Plex que a un dashboard puro: es un _portal_ con _iframes_ de cada servicio embebidos. Pesa mucho (PHP + nginx + BD), la UI es de hace 10 años, el modelo de "iframe-everything" rompe en muchos servicios modernos por X-Frame-Options. Descartado por _footprint_ y por arcaísmo. |

Homepage gana por:

- **Configuración 100 % YAML** versionable. Cinco ficheros (`services.yaml`, `settings.yaml`, `widgets.yaml`, `bookmarks.yaml`, `docker.yaml`) que viven en `~/homelab/dashboards/homepage/config/` y se _commitean_ en git. Cualquier cambio queda registrado por _commit_, _diff_-eable, revertible. **Cero clicks** en la UI para configurar.
- **Widgets nativos** para **>100 servicios** del ecosistema _self-hosted_ — incluyendo todos los del _stack_: Pi-hole, Portainer, Watchtower, Prometheus, Grafana, Uptime Kuma, Nextcloud, Jellyfin, Navidrome, Audiobookshelf, Calibre-Web, Stash, Transmission, Sonarr, Radarr, Prowlarr, Home Assistant, Mealie, FreshRSS. Cada widget conoce el _shape_ de la API del servicio y muestra los datos relevantes (ej. _unread_ en FreshRSS, _queue_ en Sonarr, _temperatura de la CPU_ en Pi-hole/Node-Exporter). No es un agregador genérico sino un _shell_ con conocimiento de cada servicio.
- **Soporte ARM64 oficial** vía `ghcr.io/gethomepage/homepage` (imagen multi-arch publicada por el upstream desde GitHub Container Registry). Sin dependencia de LinuxServer.io.
- **Stack mínimo**: un único contenedor Node.js. ~150 MB de imagen, ~100-150 MB de RAM en idle (Next.js _server_ + _backend_ ligero). Cero sidecar, cero BD, cero Redis.
- **Reload automático en caliente**: al editar un YAML en `~/homelab/dashboards/homepage/config/`, Homepage detecta el cambio (vía `chokidar` interno) y **recarga la configuración sin reiniciar el contenedor**. Los cambios se ven al refrescar el navegador. Esto convierte el ciclo "edit → commit → ver el efecto" en cuestión de segundos.
- **Open source GPL-3.0**, comunidad activa (>5000 estrellas en GitHub, _release cadence_ cada 2-4 semanas), documentación de widgets exhaustiva.
- **Sin _vendor lock-in_**: si en el futuro Homepage muere o se prefiere otro dashboard (Homarr — `docs/12-dashboards/02-homarr.md` — entra en escena precisamente como segundo candidato), basta con leer la lista de servicios del `services.yaml` y traducirla; **no hay BD que migrar**.

### Imagen y _tag_

- **`ghcr.io/gethomepage/homepage:v0.10.9`** — Homepage 0.10.x empaquetado por el upstream (Node.js 20-alpine + Next.js _standalone_ build), multi-arch (`linux/arm64`). Pinneada a _tag_ "vmajor.minor.patch" semver siguiendo la convención del homelab (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`). Homepage publica releases cada 2-4 semanas; los _bumps_ de **patch** (0.10.8 → 0.10.9) traen bug fixes y son seguros (los gestiona Watchtower, ver más abajo). Los _bumps_ de **minor** (0.10.x → 0.11.0) traen widgets nuevos o cambios de _schema_ en YAML; se gestionan a mano leyendo el _changelog_. Los _bumps_ de **major** (0.x → 1.x) son raros y exigen leer las _release notes_ con calma.
- **No se usa el _tag_ `:latest`** — al ser Homepage una aplicación con _schema_ propio en YAML que evoluciona con cada minor, un `pull` de `:latest` que cruzase un _bump minor_ podría romper el dashboard si la sintaxis de un widget cambió. El _tag_ pinneado da control del cuándo migrar.

#### Watchtower opt-in en este contenedor

Razones, mismo patrón que FreshRSS / Linkding / Mealie:

- El proyecto sigue **semver semi-estricto**: los _bumps_ de **patch** (0.10.x patches) son retrocompatibles y nunca cambian el _schema_ YAML rompedor. Watchtower puede aplicarlos sin riesgo. _docs/02-docker/04-watchtower.md_ → tabla de servicios _opt-in_ ya lista a Homepage.
- La superficie de criticidad es baja: si Homepage cae 30-60 segundos durante un `restart` post-pull de Watchtower, el operador no pierde nada (los servicios siguen accesibles por sus URLs directas; el dashboard sólo es un _convenience layer_).
- No hay BD, no hay migraciones de _schema_ en SQL, no hay riesgo de corrupción al actualizar — Homepage relee los YAML al arrancar, valida la sintaxis y, si falla, sirve un mensaje de error legible en la propia UI. Recuperación trivial.
- La configuración vive **fuera** del contenedor (en el bind mount git-tracked); el `restart` no toca nada del operador.

Etiquetar con `com.centurylinklabs.watchtower.enable: "true"`. Para _bumps minor_ (0.10 → 0.11), Watchtower **respeta el _tag_** del compose: no cruza de `:v0.10.9` a `:v0.11.0` solo porque exista un `:latest` distinto. Lo único que hace es _re-pull_ del mismo _tag_ por si hubo un _rebuild_ con un _digest_ nuevo. Para _bumps minor_ habrá que editar `HOMEPAGE_IMAGE_TAG` a mano.

> **Coherencia con `docs/02-docker/04-watchtower.md`**: ese documento ya lista a "Homepage" en la lista explícita de servicios **opt-in** desde el principio. No hace falta justificar nada extra aquí; sólo aplicar la etiqueta.

### Configuración como código: YAML en git, no UI

Homepage es uno de los pocos servicios del homelab cuya **configuración entera es declarativa** y manejable como código. Otros servicios (Bookstack, Nextcloud, Jellyfin, Home Assistant) tienen UIs de administración donde se gestionan usuarios, integraciones, _plugins_ — y el estado vive en una BD que no se versiona en git. Homepage es la excepción: cinco YAMLs cortos y suficientemente expresivos para describir el dashboard completo.

Implicaciones operativas:

- **Cada cambio del dashboard** = un _commit_ en `~/homelab/`. `git log -- dashboards/homepage/` muestra la historia entera ("añadí widget de Sonarr el 3 de mayo, removí el de Stash el 12 de junio, cambié el grupo de orden el 1 de julio").
- **Diff-eable**: revisar antes de aplicar un cambio es trivial (`git diff dashboards/homepage/config/services.yaml`). Saber qué se ha añadido en una semana de toqueteo es inmediato.
- **Revertible**: un `git revert` deshace cualquier cambio. Si un YAML mal formado rompe el render, basta con `git checkout HEAD~1 -- dashboards/homepage/config/` y refrescar.
- **Reproducible**: si la Pi se reinstala desde cero (escenario `docs/13-operaciones/02-disaster-recovery.md`), restaurar Homepage es: `git clone` el repo, `make up STACK=dashboards`, ya está. **Cero estado adicional que rescatar.** El _hook_ de Borgmatic ni siquiera necesita un `dump_*` específico — todo está en el repo git, replicado en `git push` al remoto privado.
- **El bind mount es de sólo lectura desde el contenedor**: Homepage no necesita escribir en `/app/config` (es un _watcher_ que sólo lee). Esto significa que el operador puede declarar el bind mount como `ro` en el compose, evitando que un bug futuro en Homepage modifique los ficheros sin querer.

Esta filosofía contrasta directamente con la del próximo documento (`docs/12-dashboards/02-homarr.md`), donde Homarr persiste el estado en una BD interna gestionada por _drag and drop_ desde la UI. La comparación es deliberada: el homelab **prueba ambos enfoques** (Homepage y Homarr conviven en el mismo _stack_) y el operador decide en función de su preferencia.

### `forward_auth` con Authelia: **NO** para Homepage (por defecto)

Misma decisión que en Vaultwarden, Bookstack, Linkding, Paperless, Mealie y FreshRSS, pero con una matización propia. Razones específicas para Homepage:

- **Homepage no protege secretos**. Los datos sensibles (la queue de Sonarr, el porcentaje de bloqueo de Pi-hole, el _free space_ del NAS) son **agregados de servicios que ya están protegidos por sus propias UIs**. Si el operador hace click en "Jellyfin" desde Homepage, Jellyfin pide su login. Si hace click en "Vaultwarden", Vaultwarden pide su master password. Homepage es un **menú visual**, no un panel de control.
- **El homelab vive en LAN + Tailscale**. Cualquiera con acceso a la red doméstica WiFi (ya autenticado por WPA2/WPA3 en el router) o al tailnet (autenticado por la cuenta de Tailscale, MFA opcional) puede ver el dashboard. **No hay acceso desde internet**. El _attack surface_ de mostrar "Pi-hole bloqueó 12 % de queries hoy" desde un dispositivo ya autorizado en la red es _negligible_.
- **La pareja del operador, los hijos, un invitado puntual** abren `homepage.lan` y ven el catálogo del homelab. La fricción de un Authelia delante (typing user/pass al cargar la home) es desproporcionada. La esposa del operador **no debería** tener que recordar una password sólo para abrir Homepage en el sofá.
- **Homepage no tiene login propio**. Si Authelia está delante, todo está protegido o todo está abierto. No es un servicio "con auth nativa que se complementa con Authelia".
- **Para los widgets, Homepage hace requests _server-side_ a las APIs de cada servicio** usando los _tokens_ inyectados vía variables de entorno o vía `services.yaml`. Estos _tokens_ **no se exponen al cliente** (no son visibles en el HTML que llega al navegador). Aunque alguien viese la página sin auth, no puede extraer el token.

Contraindicaciones:

- Si el homelab algún día se expone a internet (no es el caso ahora pero podría ser objetivo futuro), Homepage sería el primer servicio que requeriría Authelia delante. La sección **Migrar a Authelia con `forward_auth` (opcional)** al final de este documento describe el procedimiento exacto.
- Si en el hogar hay invitados frecuentes a los que **no** se les quiere mostrar el dashboard (por _UX_ o por privacidad), entonces Authelia sí merece la pena. Es una decisión personal — para el operador de este homelab, el caso por defecto es **abierto en LAN/Tailscale**.

> **Coherencia con `docs/04-seguridad/01-authelia.md`**: ese documento documenta `forward_auth` como _middleware_ opcional. La política de "qué se protege" del homelab es **ad hoc por servicio**, no global. Bookstack, Linkding, Paperless, Mealie, FreshRSS van **sin** Authelia (auth nativa); Vaultwarden va **sin** (su propia auth es ya equivalente); Authelia mismo es el endpoint de login (no se autoenvuelve); Homepage va **sin** por las razones de arriba; servicios con UI de admin que **sí podrían** justificar Authelia (Portainer, Grafana, Home Assistant) lo hacen vía sus propias auth nativas también — el patrón es "cada servicio gestiona su acceso", no "Authelia es la puerta única". Si alguna vez se decide unificar SSO, Homepage es el caso más fácil.

### Docker socket: **NO** se monta `/var/run/docker.sock`

Homepage soporta dos modos para mostrar el estado de los _containers_:

1. **Static mode** (este documento): cada servicio se enumera a mano en `services.yaml`, con su URL, su descripción, su categoría, y los datos del widget si aplica. **Sin acceso al socket Docker.**
2. **Discovery mode** (alternativa): se monta `/var/run/docker.sock:/var/run/docker.sock:ro` en el contenedor de Homepage. Homepage detecta automáticamente los _containers_ corriendo y los expone en un grupo "Docker" (con su _status_ verde/rojo).

Se elige el **modo estático** por dos razones:

- **Seguridad**: montar `docker.sock` (incluso `:ro`) en un contenedor expuesto a HTTP es una **escalada potencial de privilegios al host completo** (cualquier RCE en Homepage permitiría al atacante levantar contenedores con `--privileged --pid=host` y rootear la Pi en segundos). El `:ro` no protege: el _socket_ permite escrituras (`POST /containers/create`) si el _client_ las hace. Para un homelab donde Homepage corre sin auth y es accesible en LAN, el coste/beneficio no compensa.
- **Claridad declarativa**: el `services.yaml` _editado a mano_ es la **fuente de verdad** del homelab. Listar Sonarr y Radarr explícitamente, agruparlos en "Descargas", documentar la URL pública (`https://sonarr.lan`) y la URL interna del widget (`http://sonarr:8989`), describir la prioridad… todo eso queda escrito y revisable. La discovery automática mete _containers_ con nombres crípticos (`paperless-redis`, `bookstack-db`) que **no son servicios desde el punto de vista del operador** — confunden más que ayudan.

> **Si en el futuro se quiere _discovery_ parcial** (sólo para verificar el _status_ verde/rojo de cada contenedor, sin auto-listar), la solución limpia es **proxiar el socket Docker** vía `linuxserver/docker-socket-proxy` con permisos mínimos (`CONTAINERS=1`, todo lo demás `=0`) y conectar Homepage a ese proxy en lugar de al socket directo. Documentado al final en **Docker socket proxy (opcional)**.

### Bind mount mínimo: `config/` en el repo git

A diferencia de FreshRSS, Mealie o Linkding (cuyos bind mounts viven en `/mnt/hd2t/services/<svc>/`), la configuración de Homepage **vive directamente en el repo git** del homelab (`~/homelab/dashboards/homepage/config/`). Razones:

- **La configuración entera son cinco YAMLs de ~30 KB total**. Diluirla en `/mnt/hd2t/` (que está pensado para _datos_ generados/persistentes) es ruido.
- **El git ya cubre el backup**: `git push` a un remoto privado (Codeberg/GitHub privado, ver `docs/13-operaciones/02-disaster-recovery.md`) replica la config a un destino offsite **sin necesidad de Borgmatic**. Borgmatic seguirá respaldando todo `/mnt/hd2t/` y el propio `~/homelab/`, así que la cobertura es triple (git remoto + Borg local en `/mnt/hd2t/backups/` + Borg offsite en MinIO).
- **El _watcher_ de Homepage** (basado en `chokidar`) detecta cambios en `/app/config/*.yaml` y recarga sin reiniciar. Esto significa que el ciclo `vim services.yaml → git diff → recarga del navegador → git commit` es de segundos y no requiere `docker compose restart`.
- **Bind mount _read-only_**: el contenedor de Homepage no escribe en `/app/config`. Declararlo `:ro` evita que un bug futuro corrompa los YAMLs sin querer.

El directorio `/mnt/hd2t/services/homepage/` queda **reservado pero vacío** tras este documento. Se documenta su uso futuro (custom icons, asset persistente) en la sección **Custom icons (opcional)**, pero no se materializa de inicio.

### `PUID`/`PGID` y permisos del bind mount

La imagen `ghcr.io/gethomepage/homepage:v0.10.9` corre como **`node` (UID 1000, GID 1000)** dentro del contenedor por defecto — coincidencia bienvenida con el `PUID=1000`/`PGID=1000` del usuario `homelab` en el host. Esto significa que:

- El contenedor lee los YAMLs sin problemas si el bind mount tiene ownership `1000:1000` (el usuario `homelab`, propietario natural del repo).
- **No hay que `chown`-ear** nada: cuando se hace `git clone` o se editan los YAMLs como usuario `homelab`, el ownership ya es correcto.
- El operador edita los YAMLs como usuario normal — sin `sudo` —, lo cual es lo deseable.

Verificación tras el primer arranque: `stat -c '%U:%G' ~/homelab/dashboards/homepage/config` debe reportar `homelab:homelab` (UID/GID `1000:1000`).

### Almacenamiento

Resumen de paths (siguiendo el inventario unificado de la documentación):

| Path en el host                                    | Path en el contenedor       | Tipo               | Backup                               |
|----------------------------------------------------|-----------------------------|--------------------|--------------------------------------|
| `~/homelab/dashboards/homepage/config/`            | `/app/config` (`:ro`)       | configuración YAML | git (push remoto) + Borg (`source_directories: ~/homelab/`) |
| `/mnt/hd2t/services/homepage/`                     | (no montado)                | placeholder vacío  | n/a                                  |
| `/mnt/hd2t/services/homepage/icons/` (opcional)    | `/app/public/icons` (`:ro`) | iconos custom      | Borg (`source_directories: /mnt/hd2t/services/homepage/`) |

> **Por qué nada bajo `/mnt/hd2t/services/homepage/` por defecto**: justificado en **Decisiones de diseño** → _Bind mount mínimo_. El árbol existe (lo creó `04-estructura-directorios.md`) pero queda vacío hasta que el operador decida usar el _slot_ para custom icons.

---

## Estructura del _stack_ `dashboards` tras este documento

Antes de este documento (tras `docs/11-productividad/07-freshrss.md`):

```
~/homelab/
├── infra/
├── red/
├── seguridad/
├── monitor/
├── almacen/
├── domotica/
├── multimedia/
├── descargas/
├── productividad/         # 12 servicios (vaultwarden ... freshrss)
├── dashboards/            # ← NO existe aún
├── backups/
└── .env
```

Tras este documento:

```
~/homelab/
├── ...                            # los nueve stacks anteriores sin cambios
├── dashboards/                    # ← NUEVO
│   ├── docker-compose.yml         # ← NUEVO (servicio: homepage)
│   ├── .env                       # ← NUEVO (NO versionado)
│   ├── .env.example               # ← NUEVO (versionado)
│   ├── .gitignore                 # ← NUEVO (excluye .env)
│   └── homepage/                  # ← NUEVO
│       └── config/                # ← NUEVO (5 YAMLs, todos versionados)
│           ├── services.yaml
│           ├── settings.yaml
│           ├── widgets.yaml
│           ├── bookmarks.yaml
│           └── docker.yaml
├── backups/                       # sin cambios
└── .env
```

Y en el disco externo, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/homepage/         # creado por 04-estructura-directorios.md, queda vacío
```

Crear el subdirectorio del _stack_ y el _stub_ de gitignore:

```bash
mkdir -p ~/homelab/dashboards/homepage/config
chmod 0750 ~/homelab/dashboards

cat > ~/homelab/dashboards/.gitignore <<'EOF'
# Secretos del stack — NUNCA commitear
.env
EOF

# Verificar ownership (debe ser homelab:homelab):
ls -la ~/homelab/dashboards/
# drwxr-x--- 3 homelab homelab 4096 ... .
# drwxr-xr-x 8 homelab homelab 4096 ... ..
# -rw-r--r-- 1 homelab homelab    XX ... .gitignore
# drwxr-xr-x 3 homelab homelab 4096 ... homepage/
```

> **Permisos del directorio del stack**: `0750` (lo mismo que el resto de _stacks_), evita que otros usuarios del host (si los hubiera) lean el contenido. El `.env` interno se chmod-ea a `0600` cuando se cree.

> **Ownership del bind mount `config/`**: `homelab:homelab` (UID/GID `1000:1000`) — coincide con `node:node` del contenedor. **No** hace falta pre-chown-ear nada.

---

## Variables de entorno

### `~/homelab/dashboards/.env.example`

Crear (versionado en git, sin valores reales):

```bash
cat > ~/homelab/dashboards/.env.example <<'EOF'
# ============================================================================
# Stack: dashboards — variables de entorno
# Documentación: docs/12-dashboards/01-homepage.md
# ============================================================================

# --- Imagen pinneada --------------------------------------------------------
HOMEPAGE_IMAGE_TAG=v0.10.9

# --- Homepage — host header allow-list -------------------------------------
# Lista CSV de hostnames a los que Homepage responde. Cualquier otro Host
# header devuelve 400. Imprescindible para que la app no responda a IPs
# directas o a Host: localhost.
# Incluye: dominio LAN + dominio Tailscale + (opcional) IP directa para
# diagnósticos curl.
HOMEPAGE_ALLOWED_HOSTS=homepage.lan,pi.<TAILNET>.ts.net

# --- Homepage — variables de inyección en YAMLs ----------------------------
# Homepage soporta {{HOMEPAGE_VAR_*}} en los YAMLs y las sustituye por el
# valor de la env var correspondiente (sin el prefijo HOMEPAGE_VAR_). Esto
# permite mantener TODOS los API tokens fuera del repo git, pegados sólo
# aquí en el .env (que NO se commitea).

# Pi-hole API token (Settings → API → Show API token)
HOMEPAGE_VAR_PIHOLE_API_TOKEN=__PEGAR_API_TOKEN_DE_PIHOLE__

# Portainer API access token (User settings → Access tokens)
HOMEPAGE_VAR_PORTAINER_API_TOKEN=__PEGAR_API_TOKEN_DE_PORTAINER__

# Jellyfin API key (Dashboard → API Keys)
HOMEPAGE_VAR_JELLYFIN_API_KEY=__PEGAR_API_KEY_DE_JELLYFIN__

# Sonarr / Radarr / Prowlarr API keys (Settings → General → API Key)
HOMEPAGE_VAR_SONARR_API_KEY=__PEGAR_API_KEY_DE_SONARR__
HOMEPAGE_VAR_RADARR_API_KEY=__PEGAR_API_KEY_DE_RADARR__
HOMEPAGE_VAR_PROWLARR_API_KEY=__PEGAR_API_KEY_DE_PROWLARR__

# Transmission RPC (usuario:password — el RPC usa basic auth)
HOMEPAGE_VAR_TRANSMISSION_USERNAME=transmission
HOMEPAGE_VAR_TRANSMISSION_PASSWORD=__PEGAR_PASSWORD_DE_TRANSMISSION__

# Nextcloud — usuario y App Password (Security → Devices & sessions)
HOMEPAGE_VAR_NEXTCLOUD_USER=operador
HOMEPAGE_VAR_NEXTCLOUD_PASSWORD=__PEGAR_APP_PASSWORD_DE_NEXTCLOUD__

# FreshRSS — usuario y API password (la del .env de productividad)
HOMEPAGE_VAR_FRESHRSS_USER=_default
HOMEPAGE_VAR_FRESHRSS_API_PASSWORD=__PEGAR_API_PASSWORD_DE_FRESHRSS__

# Grafana — service account token (Service accounts → Add token)
HOMEPAGE_VAR_GRAFANA_TOKEN=__PEGAR_SERVICE_ACCOUNT_TOKEN_DE_GRAFANA__

# Home Assistant — Long-Lived Access Token (Profile → Long-Lived Access Tokens)
HOMEPAGE_VAR_HOMEASSISTANT_TOKEN=__PEGAR_LONG_LIVED_TOKEN_DE_HA__

# Uptime Kuma — slug de la status page pública (NO requiere token)
# Se crea en Uptime Kuma: Settings → Status Pages → Add new status page
# Ej: 'homelab-status'. El widget hace scraping de /api/status-page/<slug>.
HOMEPAGE_VAR_UPTIMEKUMA_SLUG=homelab-status

# Stash — API key (Settings → Configuration → Authentication → API key)
HOMEPAGE_VAR_STASH_API_KEY=__PEGAR_API_KEY_DE_STASH__

# Mealie — API token (Profile → API tokens)
HOMEPAGE_VAR_MEALIE_API_TOKEN=__PEGAR_API_TOKEN_DE_MEALIE__
EOF
chmod 0644 ~/homelab/dashboards/.env.example
```

### `~/homelab/dashboards/.env`

Copiar la plantilla y rellenar los valores reales con los _tokens_ generados en cada servicio:

```bash
cp ~/homelab/dashboards/.env.example ~/homelab/dashboards/.env
chmod 0600 ~/homelab/dashboards/.env

$EDITOR ~/homelab/dashboards/.env
# Sustituir cada __PEGAR_..._SERVICIO__ por el token real.
# Los tokens se obtienen entrando a la UI de cada servicio (ver Requisitos previos).

# Permisos restrictivos del .env:
chmod 0600 ~/homelab/dashboards/.env
ls -la ~/homelab/dashboards/.env
# -rw------- 1 homelab homelab ... .env
```

> **Custodia en Vaultwarden**: crear en el _vault_ del operador una entrada llamada `Homepage — Homelab API tokens` con un campo por cada `HOMEPAGE_VAR_*_TOKEN` o `HOMEPAGE_VAR_*_API_KEY`. Si en algún momento se restaura el homelab, se reconstruye el `.env` desde Vaultwarden + git.

> **No commitear `.env` jamás**. El `.gitignore` del _stack_ ya lo excluye explícitamente.

> **Tokens vacíos están bien**: si un token aún no está disponible (porque el servicio no se ha configurado todavía), dejar la variable vacía (`HOMEPAGE_VAR_PIHOLE_API_TOKEN=`). Homepage simplemente no renderizará ese widget; el resto del dashboard sigue funcionando. Los _placeholders_ `__PEGAR_..._SERVICIO__` **sí** producen errores de auth en los logs (el token literal `__PEGAR_..._SERVICIO__` se envía como _bearer_ y el servicio responde 401). Antes del primer `up -d`, **o se rellenan los tokens, o se vacían las variables**.

---

## Configuración estática

Homepage lee cinco YAMLs al arrancar y al detectar cambios en caliente:

- **`services.yaml`** — la lista de servicios del homelab agrupados por categorías. **El fichero más importante.**
- **`settings.yaml`** — apariencia global, idioma, layout, theme.
- **`widgets.yaml`** — widgets de la barra superior (clima, search, _info_ del sistema).
- **`bookmarks.yaml`** — enlaces externos (no servicios del homelab — webs externas que el operador quiere a un click).
- **`docker.yaml`** — definición de cómo Homepage habla con Docker. **En este homelab, vacío** (no hay socket montado).

### `~/homelab/dashboards/homepage/config/settings.yaml`

```bash
cat > ~/homelab/dashboards/homepage/config/settings.yaml <<'EOF'
---
# Homepage — apariencia global. Documentación: docs/12-dashboards/01-homepage.md
# Schema oficial: https://gethomepage.dev/configs/settings/

title: Homelab
favicon: https://gethomepage.dev/img/favicon.svg

# Idioma de la UI. Aplica a textos del propio Homepage; los nombres de los
# servicios y descripciones siguen siendo los del services.yaml.
language: es

# Layout: orden de las categorías y configuración por categoría.
# El operador puede reordenar y plegar/desplegar cada grupo en la UI; el
# orden inicial se define aquí.
layout:
  Red:
    style: row
    columns: 4
    icon: mdi-router-wireless-#0ea5e9
  Infra:
    style: row
    columns: 4
    icon: mdi-server-#22c55e
  Monitorización:
    style: row
    columns: 4
    icon: mdi-chart-line-#f59e0b
  Almacenamiento:
    style: row
    columns: 4
    icon: mdi-harddisk-#a855f7
  Multimedia:
    style: row
    columns: 4
    icon: mdi-multimedia-#ef4444
  Descargas:
    style: row
    columns: 4
    icon: mdi-download-#06b6d4
  Productividad:
    style: row
    columns: 4
    icon: mdi-briefcase-#84cc16
  Domótica:
    style: row
    columns: 4
    icon: mdi-home-automation-#f97316
  Seguridad:
    style: row
    columns: 4
    icon: mdi-shield-lock-#dc2626

# Theme: 'dark' | 'light' | 'slate' | etc. (ver docs upstream)
theme: dark
color: slate

# Header style: 'underlined' | 'boxed' | 'clean' | 'boxedWidgets'
headerStyle: clean

# Comportamiento de los enlaces:
# 'sametab'  = abrir en la misma pestaña
# 'newtab'   = abrir en pestaña nueva (default)
# 'topwindow' = forzar top window (útil si Homepage va dentro de iframe)
target: newtab

# Mostrar/ocultar version en el footer (útil para diagnóstico).
hideVersion: false

# Provider del background (opcional). Por defecto, fondo plano según theme.
# background:
#   image: /images/wallpaper.jpg
#   blur: sm
#   saturate: 50
#   brightness: 80
#   opacity: 50

# Quick search: barra de búsqueda en el centro de la página.
quicklaunch:
  searchDescriptions: true
  hideInternetSearch: false
  showSearchSuggestions: false
  hideVisitURL: false
EOF
```

> **Por qué `style: row` con `columns: 4`**: en una pantalla de portátil 1920x1080, una rejilla 4-columnas por categoría hace que cada servicio ocupe un cuadrado legible con espacio para el _icono_, _nombre_, _descripción_ y _widget_ (1-3 líneas de datos). En móvil, Homepage colapsa automáticamente a 1 columna.

> **Por qué `language: es`**: la UI muestra strings tipo "Servicios", "Buscar", "Cargando…" en castellano. Los nombres de los servicios y sus descripciones siguen siendo los que escriba el operador en `services.yaml` (en castellano por convención del homelab).

### `~/homelab/dashboards/homepage/config/services.yaml`

El fichero más extenso. Define cada servicio con su URL pública (Caddy), opcionalmente su URL interna (para los widgets), su descripción humana y el bloque `widget` específico del tipo de servicio (cuando aplica).

```bash
cat > ~/homelab/dashboards/homepage/config/services.yaml <<'EOF'
---
# Homepage — servicios del homelab. Documentación: docs/12-dashboards/01-homepage.md
# Schema oficial: https://gethomepage.dev/configs/services/
# Lista de widgets soportados: https://gethomepage.dev/widgets/

# ============================================================================
# Cada bloque '- <Categoría>:' contiene los servicios de ese grupo (orden
# definido en settings.yaml).
# 'href' = URL a la que llega el navegador cuando se hace click — siempre
# pasa por Caddy (https://*.lan o https://pi.<tailnet>.ts.net).
# 'widget.url' = URL desde la que el BACKEND de Homepage consulta la API —
# resolución INTERNA por DNS de Docker (http://<servicio>:<puerto>); más
# rápido y no necesita que el cliente confíe en la CA local.
# 'widget.key' / 'widget.username' / 'widget.password' = credenciales,
# substituidas desde .env vía {{HOMEPAGE_VAR_*}}.
# ============================================================================

- Red:
    - Pi-hole:
        href: https://pihole.lan/admin/
        description: DNS local + bloqueo de tracking/ads
        icon: pi-hole.svg
        widget:
          type: pihole
          url: http://pihole       # macvlan: alcanzable por nombre desde la red 'homelab' (alias en docker-compose de docs/03-red/02-pihole.md)
          key: "{{HOMEPAGE_VAR_PIHOLE_API_TOKEN}}"

    - Caddy:
        href: https://homepage.lan/   # Caddy mismo no tiene UI propia; placeholder
        description: Reverse proxy + HTTPS interno (CA local)
        icon: caddy.svg
        # Sin widget: Caddy sirve métricas Prometheus pero no tiene endpoint
        # JSON simple; las stats las muestra Grafana (panel Caddy) y el log
        # streaming lo cubre Dozzle.

    - Tailscale:
        href: https://login.tailscale.com/admin/machines
        description: VPN mesh para acceso remoto
        icon: tailscale.svg

    - Authelia:
        href: https://auth.lan/
        description: SSO + 2FA (middleware de Caddy)
        icon: authelia.svg

- Infra:
    - Portainer:
        href: https://portainer.lan/
        description: Gestión web de Docker
        icon: portainer.svg
        widget:
          type: portainer
          url: http://portainer:9000   # API interna del propio Portainer
          env: 1                        # endpointId de Portainer (1 = local Docker)
          key: "{{HOMEPAGE_VAR_PORTAINER_API_TOKEN}}"

    - Watchtower:
        href: https://homepage.lan/   # Watchtower no tiene UI; placeholder
        description: Auto-update de containers (opt-in)
        icon: watchtower.svg
        # Sin widget: Watchtower expone métricas a Prometheus (Grafana las
        # visualiza). Aquí sólo el enlace por completitud.

    - Dozzle:
        href: https://dozzle.lan/
        description: Visor de logs en tiempo real
        icon: dozzle.svg

- Monitorización:
    - Grafana:
        href: https://grafana.lan/
        description: Dashboards de métricas
        icon: grafana.svg
        widget:
          type: grafana
          url: http://grafana:3000
          username: ""                  # token-based, dejar vacío
          password: "{{HOMEPAGE_VAR_GRAFANA_TOKEN}}"

    - Prometheus:
        href: https://prometheus.lan/
        description: TSDB + scraper de métricas
        icon: prometheus.svg
        widget:
          type: prometheus
          url: http://prometheus:9090

    - Uptime Kuma:
        href: https://uptime.lan/
        description: Estado de los servicios + alertas
        icon: uptime-kuma.svg
        widget:
          type: uptimekuma
          url: http://uptime-kuma:3001
          slug: "{{HOMEPAGE_VAR_UPTIMEKUMA_SLUG}}"

- Almacenamiento:
    - Nextcloud:
        href: https://nextcloud.lan/
        description: Cloud privado (ficheros, calendario, contactos)
        icon: nextcloud.svg
        widget:
          type: nextcloud
          url: http://nextcloud:80
          username: "{{HOMEPAGE_VAR_NEXTCLOUD_USER}}"
          password: "{{HOMEPAGE_VAR_NEXTCLOUD_PASSWORD}}"

    - Samba:
        href: smb://192.168.1.3/                 # smb:// no es web, abre el explorador del SO
        description: Recursos compartidos SMB (Windows/Mac/Linux)
        icon: samba.svg

    - Syncthing:
        href: https://syncthing.lan/
        description: Sincronización P2P entre dispositivos
        icon: syncthing.svg

    - MinIO:
        href: https://minio.lan/
        description: S3-compatible para destinos de backup
        icon: minio.svg

- Multimedia:
    - Jellyfin:
        href: https://jellyfin.lan/
        description: Media server (películas, series)
        icon: jellyfin.svg
        widget:
          type: jellyfin
          url: http://jellyfin:8096
          key: "{{HOMEPAGE_VAR_JELLYFIN_API_KEY}}"

    - Navidrome:
        href: https://navidrome.lan/
        description: Servidor de música (Subsonic-compatible)
        icon: navidrome.svg
        widget:
          type: navidrome
          url: http://navidrome:4533
          user: ""           # username del operador (opcional)
          token: ""          # password salted (opcional, no crítico)

    - Audiobookshelf:
        href: https://audiobookshelf.lan/
        description: Audiolibros y podcasts
        icon: audiobookshelf.svg

    - Calibre-Web:
        href: https://calibre.lan/
        description: Biblioteca de ebooks
        icon: calibre-web.svg

    - Stash:
        href: https://stash.lan/
        description: Biblioteca multimedia adulta (hd5t)
        icon: stash.svg
        widget:
          type: stash
          url: http://stash:9999
          key: "{{HOMEPAGE_VAR_STASH_API_KEY}}"

- Descargas:
    - Transmission:
        href: https://transmission.lan/
        description: Cliente BitTorrent
        icon: transmission.svg
        widget:
          type: transmission
          url: http://transmission:9091
          username: "{{HOMEPAGE_VAR_TRANSMISSION_USERNAME}}"
          password: "{{HOMEPAGE_VAR_TRANSMISSION_PASSWORD}}"
          rpcUrl: /transmission/

    - Sonarr:
        href: https://sonarr.lan/
        description: Gestor de series
        icon: sonarr.svg
        widget:
          type: sonarr
          url: http://sonarr:8989
          key: "{{HOMEPAGE_VAR_SONARR_API_KEY}}"

    - Radarr:
        href: https://radarr.lan/
        description: Gestor de películas
        icon: radarr.svg
        widget:
          type: radarr
          url: http://radarr:7878
          key: "{{HOMEPAGE_VAR_RADARR_API_KEY}}"

    - Prowlarr:
        href: https://prowlarr.lan/
        description: Indexer manager (alimenta a Sonarr/Radarr)
        icon: prowlarr.svg
        widget:
          type: prowlarr
          url: http://prowlarr:9696
          key: "{{HOMEPAGE_VAR_PROWLARR_API_KEY}}"

- Productividad:
    - Vaultwarden:
        href: https://vaultwarden.lan/
        description: Gestor de contraseñas (Bitwarden-compatible)
        icon: vaultwarden.svg
        # Sin widget: Vaultwarden no expone métricas legibles para dashboards
        # (la API es para clientes Bitwarden, no para inspección externa).

    - Bookstack:
        href: https://bookstack.lan/
        description: Wiki / documentación interna del homelab
        icon: bookstack.svg

    - Linkding:
        href: https://linkding.lan/
        description: Gestor de marcadores
        icon: linkding.svg

    - Paperless-ngx:
        href: https://paperless.lan/
        description: Gestión documental con OCR
        icon: paperless.svg

    - Mealie:
        href: https://mealie.lan/
        description: Recetario y planificador de comidas
        icon: mealie.svg
        widget:
          type: mealie
          url: http://mealie:9000
          key: "{{HOMEPAGE_VAR_MEALIE_API_TOKEN}}"

    - Stirling-PDF:
        href: https://pdf.lan/
        description: Caja de herramientas para PDF
        icon: stirling-pdf.svg

    - FreshRSS:
        href: https://freshrss.lan/
        description: Lector de feeds RSS/Atom
        icon: freshrss.svg
        widget:
          type: freshrss
          url: http://freshrss:80
          username: "{{HOMEPAGE_VAR_FRESHRSS_USER}}"
          password: "{{HOMEPAGE_VAR_FRESHRSS_API_PASSWORD}}"

- Domótica:
    - Home Assistant:
        href: https://hass.lan/
        description: Hub de domótica (Zigbee, MQTT, integraciones)
        icon: home-assistant.svg
        widget:
          type: homeassistant
          url: http://homeassistant:8123
          key: "{{HOMEPAGE_VAR_HOMEASSISTANT_TOKEN}}"

    - Mosquitto:
        href: https://homepage.lan/   # Mosquitto no tiene UI; placeholder
        description: Broker MQTT (puerto 1883)
        icon: mosquitto.svg

    - Zigbee2MQTT:
        href: https://zigbee2mqtt.lan/
        description: Bridge Zigbee → MQTT
        icon: zigbee2mqtt.svg

    - Node-RED:
        href: https://nodered.lan/
        description: Flujos de automatización
        icon: node-red.svg

- Seguridad:
    - Fail2ban:
        href: https://homepage.lan/   # Fail2ban no tiene UI; placeholder
        description: Banear IPs tras fallos de auth
        icon: fail2ban.svg
EOF
```

> **Iconos**: Homepage trae miles de iconos vendor-included en `/app/public/icons/` (búsqueda en https://github.com/walkxcode/dashboard-icons). Usar el nombre del SVG sin path (ej. `pi-hole.svg`). Para iconos no incluidos, usar el formato `mdi-<nombre>` (Material Design Icons) o cargar custom desde `/app/public/icons/` (ver **Custom icons opcional**).

> **`href` con `https://homepage.lan/` como placeholder** para servicios sin UI (Caddy, Watchtower, Mosquitto, Fail2ban): es preferible que el click vuelva al propio dashboard antes de dar un 404 confuso. Alternativa: omitir el `href` y dejarlos sin link (`href:` vacío). Decisión personal del operador.

> **Servicios aún no desplegados**: si en el momento de aplicar este documento hay servicios faltantes (ej. el _stack_ `monitor` aún no se ha completado), **comentar** los bloques correspondientes con `#`. El YAML sigue siendo válido y el dashboard renderiza el resto. Activar a medida que los _stacks_ se vayan terminando.

> **`url` interna del widget**: usa el _alias_ DNS de la red `homelab` (`http://pihole`, `http://sonarr:8989`). Estos _aliases_ existen porque cada `docker-compose.yml` de stack engancha sus servicios a la red `homelab` con un alias. Para Pi-hole (que vive en la red `lan` macvlan + un alias en `homelab`), el documento `docs/03-red/02-pihole.md` lo deja accesible como `pihole` en la red Docker. Verificable con `docker exec homepage nslookup pihole`.

### `~/homelab/dashboards/homepage/config/widgets.yaml`

Widgets globales de la barra superior — independientes de los servicios.

```bash
cat > ~/homelab/dashboards/homepage/config/widgets.yaml <<'EOF'
---
# Homepage — widgets globales (barra superior).
# Schema oficial: https://gethomepage.dev/widgets/info/

# Widget de buscador en el centro
- search:
    provider: duckduckgo       # 'google' | 'duckduckgo' | 'bing' | 'brave' | etc.
    target: _blank
    focus: false               # auto-focus al cargar la página

# Widget de tiempo (clima del operador) — opcional
# Requiere coordenadas (no API key — usa Open-Meteo, gratis).
- openmeteo:
    label: Madrid
    timezone: Europe/Madrid
    latitude: 40.4168
    longitude: -3.7038
    units: metric              # 'metric' | 'imperial'
    cache: 5                   # minutos de cache

# Widget de info del sistema host (sólo si Homepage tiene acceso a /proc del
# host vía bind mount — por defecto NO; muestra info del CONTENEDOR si está
# activo). Comentado por defecto para evitar confusión.
# - resources:
#     cpu: true
#     memory: true
#     disk: /

# Datetime: hora local
- datetime:
    text_size: xl
    format:
      timeStyle: short
      dateStyle: short
      hourCycle: h23
EOF
```

> **`openmeteo`** funciona sin API key (servicio gratuito, _rate limit_ generoso). Si el operador prefiere `OpenWeatherMap`, requiere API key y se configura distinto (ver docs upstream del widget).

> **Widget de `resources` (CPU/RAM/disco)**: por defecto, Homepage muestra los recursos del **contenedor** (no del host). Para que muestre los del host, se necesita bind-mount `/proc` y `/sys` `:ro` (con riesgo de _info disclosure_). El operador prefiere ver las métricas del host en **Grafana** (que sí tiene acceso completo vía Node Exporter) y no duplicarlas aquí.

### `~/homelab/dashboards/homepage/config/bookmarks.yaml`

Enlaces externos: webs que el operador quiere a un click desde el dashboard del homelab. **No es un servicio del homelab**, es la lista de "favoritos" del navegador.

```bash
cat > ~/homelab/dashboards/homepage/config/bookmarks.yaml <<'EOF'
---
# Homepage — bookmarks (enlaces externos).
# Schema oficial: https://gethomepage.dev/configs/bookmarks/

- Documentación:
    - Docs del homelab:
        - abbr: HL
          href: https://bookstack.lan/books/homelab
          description: Wiki interno con runbooks

    - Releases upstream:
        - abbr: GH
          href: https://github.com/gethomepage/homepage/releases
          description: Changelog de Homepage

- Servicios externos:
    - Tailscale admin:
        - abbr: TS
          href: https://login.tailscale.com/admin/machines
          description: Panel del tailnet

    - Codeberg / GitHub:
        - abbr: CB
          href: https://codeberg.org/<usuario>
          description: Repos privados (mirror del homelab)
EOF
```

> **Personalización**: el operador edita la lista a su gusto. Cada categoría es un grupo libre, cada entry tiene `abbr` (2-3 letras que se muestran como icono), `href` y `description`.

### `~/homelab/dashboards/homepage/config/docker.yaml`

Vacío en este homelab (no se usa _socket discovery_ — ver **Decisiones de diseño**).

```bash
cat > ~/homelab/dashboards/homepage/config/docker.yaml <<'EOF'
---
# Homepage — integración con Docker. VACÍO POR DISEÑO.
# Documentación: docs/12-dashboards/01-homepage.md, sección "Docker socket: NO".
# Si en el futuro se decide activar el socket proxy, se rellena aquí
# (ver "Docker socket proxy (opcional)" al final del documento).
EOF
```

### Listo el árbol de configuración

Verificar:

```bash
ls -la ~/homelab/dashboards/homepage/config/
# -rw-r--r-- 1 homelab homelab   ... bookmarks.yaml
# -rw-r--r-- 1 homelab homelab   ... docker.yaml
# -rw-r--r-- 1 homelab homelab   ... services.yaml
# -rw-r--r-- 1 homelab homelab   ... settings.yaml
# -rw-r--r-- 1 homelab homelab   ... widgets.yaml

# Validar la sintaxis YAML de los cinco ficheros (catch errores de copy-paste antes del primer arranque):
for f in ~/homelab/dashboards/homepage/config/*.yaml; do
  python3 -c "import yaml,sys; yaml.safe_load(open('$f'))" && echo "OK $f" || echo "FAIL $f"
done
# OK ~/homelab/dashboards/homepage/config/bookmarks.yaml
# OK ~/homelab/dashboards/homepage/config/docker.yaml
# OK ~/homelab/dashboards/homepage/config/services.yaml
# OK ~/homelab/dashboards/homepage/config/settings.yaml
# OK ~/homelab/dashboards/homepage/config/widgets.yaml
```

> **Si Python no está disponible** (raro en Pi OS), usar `docker run --rm -v ~/homelab/dashboards/homepage/config:/c:ro alpine sh -c 'apk add -q yq && for f in /c/*.yaml; do yq . "$f" >/dev/null && echo OK $f || echo FAIL $f; done'` — instala `yq` efímeramente y valida.

---

## `~/homelab/dashboards/docker-compose.yml`

```yaml
---
# Stack: dashboards — Homepage (dashboard estático)
# Documentación: docs/12-dashboards/01-homepage.md

services:

  # ===========================================================================
  # Homepage — dashboard de inicio.
  # Configuración 100 % declarativa (cinco YAMLs en bind mount :ro git-tracked).
  # NO se monta /var/run/docker.sock (ver decisiones de diseño).
  # NO se engancha a 'productividad-internal' u otra red privada — sólo a 'homelab'.
  # NO entra en Borgmatic con dump propio (Categoría F — config en git remoto).
  # ===========================================================================
  homepage:
    image: ghcr.io/gethomepage/homepage:${HOMEPAGE_IMAGE_TAG}
    container_name: homepage
    hostname: homepage
    restart: unless-stopped
    mem_limit: 384m
    environment:
      TZ: ${TZ}
      # Allow-list de Host headers — la app rechaza otros con 400.
      HOMEPAGE_ALLOWED_HOSTS: ${HOMEPAGE_ALLOWED_HOSTS}

      # --- Variables HOMEPAGE_VAR_* (sustituidas en YAMLs como {{...}}) ---
      HOMEPAGE_VAR_PIHOLE_API_TOKEN:        ${HOMEPAGE_VAR_PIHOLE_API_TOKEN:-}
      HOMEPAGE_VAR_PORTAINER_API_TOKEN:     ${HOMEPAGE_VAR_PORTAINER_API_TOKEN:-}
      HOMEPAGE_VAR_JELLYFIN_API_KEY:        ${HOMEPAGE_VAR_JELLYFIN_API_KEY:-}
      HOMEPAGE_VAR_SONARR_API_KEY:          ${HOMEPAGE_VAR_SONARR_API_KEY:-}
      HOMEPAGE_VAR_RADARR_API_KEY:          ${HOMEPAGE_VAR_RADARR_API_KEY:-}
      HOMEPAGE_VAR_PROWLARR_API_KEY:        ${HOMEPAGE_VAR_PROWLARR_API_KEY:-}
      HOMEPAGE_VAR_TRANSMISSION_USERNAME:   ${HOMEPAGE_VAR_TRANSMISSION_USERNAME:-}
      HOMEPAGE_VAR_TRANSMISSION_PASSWORD:   ${HOMEPAGE_VAR_TRANSMISSION_PASSWORD:-}
      HOMEPAGE_VAR_NEXTCLOUD_USER:          ${HOMEPAGE_VAR_NEXTCLOUD_USER:-}
      HOMEPAGE_VAR_NEXTCLOUD_PASSWORD:      ${HOMEPAGE_VAR_NEXTCLOUD_PASSWORD:-}
      HOMEPAGE_VAR_FRESHRSS_USER:           ${HOMEPAGE_VAR_FRESHRSS_USER:-}
      HOMEPAGE_VAR_FRESHRSS_API_PASSWORD:   ${HOMEPAGE_VAR_FRESHRSS_API_PASSWORD:-}
      HOMEPAGE_VAR_GRAFANA_TOKEN:           ${HOMEPAGE_VAR_GRAFANA_TOKEN:-}
      HOMEPAGE_VAR_HOMEASSISTANT_TOKEN:     ${HOMEPAGE_VAR_HOMEASSISTANT_TOKEN:-}
      HOMEPAGE_VAR_UPTIMEKUMA_SLUG:         ${HOMEPAGE_VAR_UPTIMEKUMA_SLUG:-}
      HOMEPAGE_VAR_STASH_API_KEY:           ${HOMEPAGE_VAR_STASH_API_KEY:-}
      HOMEPAGE_VAR_MEALIE_API_TOKEN:        ${HOMEPAGE_VAR_MEALIE_API_TOKEN:-}
    volumes:
      # Configuración: bind mount versionado en git, READ-ONLY para el contenedor.
      - ./homepage/config:/app/config:ro
      # Custom icons (opcional; vacío por defecto).
      # - /mnt/hd2t/services/homepage/icons:/app/public/icons:ro
      # NO montar /var/run/docker.sock — ver decisiones de diseño.
    networks:
      homelab:
        aliases:
          - homepage     # Caddy resuelve 'homepage:3000' por este alias
    labels:
      homelab.stack: "dashboards"
      homelab.backup: "false"     # Categoría F — la config va por git
      # Opt-in: semver patch retrocompatible, downtime aceptable.
      com.centurylinklabs.watchtower.enable: "true"
    healthcheck:
      # Homepage expone /api/healthcheck (200 OK). Backup: GET / (200 OK con HTML).
      test:
        - CMD-SHELL
        - "wget -qO- http://localhost:3000/api/healthcheck >/dev/null || wget -qO- http://localhost:3000/ >/dev/null"
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s

# ---------------------------------------------------------------------------
# Redes
# ---------------------------------------------------------------------------
networks:
  homelab:
    external: true               # creada en docs/02-docker/02-estructura-compose.md
```

Notas de diseño:

- **Sin red privada del stack**. El _stack_ `dashboards` tendrá dos contenedores cuando se añada Homarr (`docs/12-dashboards/02-homarr.md`); ninguno de los dos se comunica entre sí. Cada uno se engancha sólo a `homelab`.
- **Sin `ports:`**. Caddy alcanza `homepage:3000` por DNS interno. Si el operador necesita acceder sin pasar por Caddy: `docker exec homepage wget -qO- http://localhost:3000/`.
- **`mem_limit: 384m`**: límite generoso para un Node.js + Next.js. Homepage idle se queda en torno a **100-150 MB de RSS reales**; los _polls_ de widgets (especialmente Sonarr/Radarr con queues largas) puntualmente suben a ~250 MB. `384m` deja margen sin penalizar a los demás stacks.
- **`start_period: 30s`**: el primer arranque carga Next.js, lee y valida los YAMLs (~5 s en una Pi 5), arranca el _watcher_. Total ~10-15 s. `30s` da margen.
- **Bind mount `:ro`**: el contenedor no escribe en `/app/config`. _Read-only_ es el _default seguro_.
- **`HOMEPAGE_VAR_*:-` con default vacío**: si una variable no está en el `.env`, Compose la pasa como cadena vacía en lugar de fallar. Homepage trata el _token vacío_ como "widget desactivado" (no hace la petición, no aparece el spinner perpetuo). Esto permite desplegar Homepage **antes** de que todos los _tokens_ estén disponibles.
- **Sin `depends_on`**: Homepage no depende de ningún otro contenedor para arrancar. Si Pi-hole está caído, simplemente el widget de Pi-hole muestra "error" en la UI; el resto del dashboard funciona.
- **`wget` en el _healthcheck_**: la imagen `gethomepage/homepage` es Alpine y trae `wget` por defecto (no `curl`). El _healthcheck_ usa `wget -qO-` para máxima compatibilidad.
- **`homelab.backup: "false"`**: etiqueta informativa coherente con que NO entra en Borgmatic con dump propio. La configuración entra en Borgmatic como parte de `~/homelab/` (genérico) — ningún _hook_ específico necesario.

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/dashboards

# Validar la sintaxis del compose sin levantar nada.
docker compose --env-file ../.env --env-file .env config | grep -E '^\s+(homepage):'
# homepage:

# Levantar el servicio:
docker compose --env-file ../.env --env-file .env up -d
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=dashboards
```

Vigilar el primer arranque (~10-15 s):

```bash
docker compose -f ~/homelab/dashboards/docker-compose.yml logs -f homepage
# homepage | Loading services.yaml ...
# homepage | Loading settings.yaml ...
# homepage | Loading widgets.yaml ...
# homepage | Loading bookmarks.yaml ...
# homepage | Loading docker.yaml ...
# homepage | Found 0 docker connections
# homepage | All YAML configurations loaded successfully
# homepage | ▲ Next.js 14.x.x
# homepage | - Local:        http://localhost:3000
# homepage | - Network:      http://0.0.0.0:3000
# homepage | ✓ Ready in 800ms
```

> **Si tarda más de 1 minuto** sin llegar a "Ready": revisar los logs por errores de YAML — Homepage es estricto y un YAML mal formado o un widget con campos faltantes lo bloquea. El _stack trace_ se imprime y suele incluir el fichero y la línea (`Error in services.yaml:42 — Unknown widget type 'pi-hole' (did you mean 'pihole'?)`).

Verificar que el contenedor está `(healthy)`:

```bash
docker compose -f ~/homelab/dashboards/docker-compose.yml ps
# NAME       STATUS                   PORTS
# homepage   Up X seconds (healthy)
```

> El `(healthy)` lo otorga el _healthcheck_ que comprueba `/api/healthcheck` o `/` devolviendo `200`. Si tras 1 minuto sigue `starting`/`unhealthy`, ir a **Troubleshooting** → primer arranque.

Confirmar que los YAMLs se montaron correctamente desde el contenedor:

```bash
docker exec homepage ls -la /app/config/
# -rw-r--r-- 1 1000 1000 ... bookmarks.yaml
# -rw-r--r-- 1 1000 1000 ... docker.yaml
# -rw-r--r-- 1 1000 1000 ... services.yaml
# -rw-r--r-- 1 1000 1000 ... settings.yaml
# -rw-r--r-- 1 1000 1000 ... widgets.yaml

# Y que son read-only desde dentro:
docker exec homepage sh -c 'echo test > /app/config/test.txt' || echo "OK: read-only"
# OK: read-only
```

### Caddy: bloque `homepage.lan` (sin `import authelia`)

Editar `~/homelab/red/Caddyfile` y añadir el bloque:

```caddy
homepage.lan {
    tls internal
    import security-headers
    import logging

    # Homepage funciona sin auth en el homelab por diseño (ver
    # docs/12-dashboards/01-homepage.md, sección "forward_auth: NO").
    # Si en algún futuro se decide poner Authelia delante:
    #   1. descomentar 'import authelia' aquí
    #   2. ajustar HOMEPAGE_ALLOWED_HOSTS en el .env
    # import authelia

    reverse_proxy homepage:3000 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}
    }
}
```

Validar y recargar Caddy:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Probar (la CA local debe estar importada en el navegador, ver `docs/03-red/04-caddy.md`):

```bash
# Healthcheck endpoint:
curl -k --resolve homepage.lan:443:192.168.1.3 -I https://homepage.lan/api/healthcheck
# HTTP/2 200

# Home (HTML):
curl -k --resolve homepage.lan:443:192.168.1.3 https://homepage.lan/ | head -5
# <!DOCTYPE html>
# <html lang="es">
# ...
```

Y desde el navegador:

1. Visitar `https://homepage.lan/`.
2. **Sin login** (Homepage no tiene): la home carga directamente con todas las categorías y widgets.
3. Verificar que cada categoría aparece, los servicios están listados, y los widgets configurados muestran datos en vivo (puede tardar unos segundos en hacer el primer poll de cada API).
4. Servicios con _token_ inválido o vacío muestran un placeholder de error en su widget — esto es **esperado** durante el rodaje inicial, mientras se completan los _tokens_.

---

## Configuración tras primer arranque

### 1. Rellenar los API tokens uno a uno

Conforme se vaya verificando que cada widget funciona, rellenar el `HOMEPAGE_VAR_*` correspondiente en el `.env`. **No** hace falta `restart` del contenedor: Homepage **no relee env vars en caliente** (sólo los YAMLs), así que tras editar el `.env`:

```bash
$EDITOR ~/homelab/dashboards/.env
# Sustituir el valor de HOMEPAGE_VAR_PIHOLE_API_TOKEN, por ejemplo.

cd ~/homelab/dashboards
docker compose --env-file ../.env --env-file .env up -d homepage
# Recreate del contenedor — pulls fresh env vars. ~5 s downtime.
```

> **Truco**: si se va a tocar varias variables, mejor editarlas todas y hacer **un solo** `up -d` al final.

### 2. Iterar el `services.yaml` sin restart

Para añadir/quitar/reordenar servicios, editar `~/homelab/dashboards/homepage/config/services.yaml` y refrescar el navegador. **No hace falta restart**: el _watcher_ recarga la config en caliente.

```bash
$EDITOR ~/homelab/dashboards/homepage/config/services.yaml
# Añadir un servicio nuevo, p.ej.

# Refrescar el navegador (Ctrl+R o Cmd+R). El cambio aparece de inmediato.

# Si algo va mal, revisar los logs del recarga:
docker logs homepage --tail 20
# homepage | Detected change in services.yaml, reloading...
# homepage | Reloaded successfully
```

> **Si el YAML está mal formado**: Homepage **mantiene la config anterior** en memoria y registra el error en los logs (`Error reloading services.yaml: ...`). El dashboard **NO se rompe** — sigue funcionando con la última config válida hasta que se corrige el YAML.

### 3. Custom icons (opcional)

Para iconos no incluidos en la imagen (p.ej. el logo del propio homelab, una variante de un servicio con su logo nuevo), montar un directorio adicional:

```bash
# Crear el directorio para custom icons:
sudo mkdir -p /mnt/hd2t/services/homepage/icons
sudo chown -R 1000:1000 /mnt/hd2t/services/homepage/icons

# Copiar SVGs / PNGs:
cp ~/Downloads/mi-logo.svg /mnt/hd2t/services/homepage/icons/

# Activar el bind mount en el compose:
$EDITOR ~/homelab/dashboards/docker-compose.yml
# Descomentar la línea:
#   - /mnt/hd2t/services/homepage/icons:/app/public/icons:ro

cd ~/homelab/dashboards && docker compose up -d homepage

# En services.yaml, referenciar el icono SIN extensión y CON prefijo de ruta:
# icon: /icons/mi-logo.svg     # absoluto desde /app/public
```

> **Convención de iconos del ecosistema**: el repo `walkxcode/dashboard-icons` (mantenido por la comunidad) ofrece >2000 iconos de servicios _self-hosted_ ya empaquetados con la imagen de Homepage. Casi nunca hace falta crear iconos custom.

### 4. Commitear la configuración

Toda la config (excepto `.env`) va a git. Tras el primer arranque correcto:

```bash
cd ~/homelab
git status
# Modificados:
#   dashboards/.gitignore            (nuevo)
#   dashboards/.env.example          (nuevo)
#   dashboards/docker-compose.yml    (nuevo)
#   dashboards/homepage/config/bookmarks.yaml   (nuevo)
#   dashboards/homepage/config/docker.yaml      (nuevo)
#   dashboards/homepage/config/services.yaml    (nuevo)
#   dashboards/homepage/config/settings.yaml    (nuevo)
#   dashboards/homepage/config/widgets.yaml     (nuevo)
#   red/Caddyfile                    (modificado: añadido bloque homepage.lan)
# (sin trackear: dashboards/.env)

git add dashboards/ red/Caddyfile
git commit -m "feat(dashboards): add Homepage (static dashboard, YAML-as-code)"
```

> **A partir de aquí**, cada cambio en los YAMLs queda como _commit_ aparte: `git diff dashboards/homepage/config/services.yaml` antes de cada cambio mayor, _commit_ con mensaje descriptivo (`feat(dashboards): add widget for Stash`, `chore(dashboards): reorder Multimedia group`).

### 5. (No aplica) _hook_ específico de Borgmatic

A diferencia de FreshRSS o Vaultwarden, Homepage **no tiene BD propia**. Categoría F en `docs/07-backups/01-estrategia-backup.md`: configuración pura, regenerable desde el repo git. La cobertura de backup es:

- **Git remoto** (Codeberg/GitHub privado): replicación inmediata tras cada `git push`.
- **Borgmatic**, vía la `source_directory` global del `config.yaml` que ya incluye `~/homelab/`. Toda la config queda dentro del repo Borg sin _hook_ adicional.
- **Borgmatic offsite** (MinIO): copia adicional al destino remoto.

**No hay que tocar `dump-databases.sh`**. El comentario `# Homepage: /mnt/hd2t/services/homepage/config/` que dejó preparado `docs/07-backups/03-backup-docker-volumes.md` se puede **eliminar** o, mejor, sustituir por una nota actualizada que refleje la decisión real:

```bash
$EDITOR ~/homelab/backups/borgmatic/hooks/dump-databases.sh
```

Reemplazar:

```bash
# --- Dashboards (config files — Categoría F)
# Homepage: /mnt/hd2t/services/homepage/config/
# Homarr  : /mnt/hd2t/services/homarr/configs/
```

Por (sólo la línea de Homepage; la de Homarr la actualizará `docs/12-dashboards/02-homarr.md`):

```bash
# --- Dashboards (config files — Categoría F)
# Homepage: configuración versionada en git (~/homelab/dashboards/homepage/config/),
#           cubierta por la source_directory global. Sin dump específico.
# Homarr  : /mnt/hd2t/services/homarr/configs/   (pendiente de docs/12-dashboards/02-homarr.md)
```

Commitear:

```bash
git -C ~/homelab add backups/borgmatic/hooks/dump-databases.sh
git -C ~/homelab commit -m "chore(backups): document Homepage as git-only (Cat. F)"
```

### 6. (No aplica) _jail_ de fail2ban

Homepage no tiene login, no tiene endpoints de auth, no produce logs de "intento fallido". **No hace falta** un _jail_ específico en `docs/04-seguridad/02-fail2ban.md`.

Si se decide más adelante poner Authelia delante (sección **Migrar a Authelia con `forward_auth` (opcional)**), la auth la gestionará Authelia y el _jail_ aplicable sería el genérico de Authelia (ya documentado en su _doc_).

---

## Verificación final

Antes de pasar a `docs/12-dashboards/02-homarr.md`, comprobar:

- [ ] `docker compose -f ~/homelab/dashboards/docker-compose.yml ps` muestra `homepage` en `(healthy)`.
- [ ] `docker exec homepage wget -qO- http://localhost:3000/api/healthcheck` devuelve respuesta JSON o 200 vacío.
- [ ] `https://homepage.lan/` carga la home con las categorías definidas y todos los servicios listados.
- [ ] **Test de widget**: el widget de Pi-hole muestra "queries totales" y "% bloqueado" en datos reales (no "—" ni "Error"); cualquier otro widget configurado con _token_ correcto muestra datos en vivo.
- [ ] **Test de hot-reload**: editar `~/homelab/dashboards/homepage/config/services.yaml` (cambiar la descripción de un servicio), refrescar el navegador → el cambio aparece **sin** `restart` del contenedor.
- [ ] **Test de YAML inválido**: introducir un error de sintaxis a propósito en `services.yaml` (un guion mal puesto), refrescar el navegador → la home **sigue funcionando** con la config anterior. `docker logs homepage --tail 5` muestra el error de parsing. Restaurar el fichero y refrescar → todo vuelve a la normalidad.
- [ ] **Bind mount read-only**:
  ```bash
  docker exec homepage sh -c 'echo x > /app/config/x' || echo "OK: read-only"
  # OK: read-only
  ```
- [ ] **Sin Docker socket montado** (verificación de seguridad):
  ```bash
  docker exec homepage ls /var/run/docker.sock 2>&1 || echo "OK: socket NOT mounted"
  # ls: /var/run/docker.sock: No such file or directory
  # OK: socket NOT mounted
  ```
- [ ] **`HOMEPAGE_ALLOWED_HOSTS` activo**:
  ```bash
  # Petición con Host correcto: 200
  curl -k --resolve homepage.lan:443:192.168.1.3 -o /dev/null -s -w "%{http_code}\n" \
      https://homepage.lan/
  # 200

  # Petición con Host inválido: 400 o 403 (depende de la versión)
  curl -k --resolve evil.lan:443:192.168.1.3 -H "Host: evil.lan" -o /dev/null -s -w "%{http_code}\n" \
      https://evil.lan/
  # 400 / 403 / 421
  ```
- [ ] `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` lista a `homepage`.
- [ ] **Memoria controlada**: `docker stats homepage --no-stream --format '{{.MemUsage}}'` reporta uso de RAM <250 MiB en idle (típico ~100-150 MiB).
- [ ] **Permisos del bind mount**:
  ```bash
  stat -c '%U:%G' ~/homelab/dashboards/homepage/config
  # homelab:homelab    (UID/GID 1000:1000)
  ```
- [ ] Tras un `docker compose -f ~/homelab/dashboards/docker-compose.yml restart homepage`, el contenedor vuelve a `(healthy)` en <30 s y los widgets refrescan los datos.
- [ ] Tras un `sudo reboot` de la Pi, el contenedor vuelve a estar `(healthy)` sin intervención manual y `https://homepage.lan/` responde con la misma config (es _stateless_; no hay sesión que perder).
- [ ] `git -C ~/homelab status` está limpio (todo commit-eado). El `.env` **NO** aparece como _untracked_ (lo excluye `.gitignore`).
- [ ] **Test del watcher tras reload de Caddy** (regression check): `docker exec caddy caddy reload --config /etc/caddy/Caddyfile` no afecta a Homepage; el dashboard sigue accesible.
- [ ] (Opcional) Lanzar `docker compose -f ~/homelab/dashboards/docker-compose.yml down && docker compose -f ~/homelab/dashboards/docker-compose.yml up -d` y comprobar que la config se recarga _idem_ — confirmando que la fuente de verdad son los YAMLs en git, no estado interno.

---

## Backup

| Qué                                         | Dónde                                                              | Cómo                                                       |
|---------------------------------------------|--------------------------------------------------------------------|------------------------------------------------------------|
| `docker-compose.yml`, `.env.example`        | `~/homelab/dashboards/`                                            | git                                                        |
| `services.yaml`, `settings.yaml`, `widgets.yaml`, `bookmarks.yaml`, `docker.yaml` | `~/homelab/dashboards/homepage/config/` | git (fuente de verdad)                                     |
| Bloque del `Caddyfile`                      | `~/homelab/red/Caddyfile`                                          | git                                                        |
| `.env` con `HOMEPAGE_VAR_*` (API tokens)    | `~/homelab/dashboards/.env`                                        | **Vaultwarden** (entrada "Homepage — Homelab API tokens") |
| Custom icons (si se usan)                   | `/mnt/hd2t/services/homepage/icons/`                               | **Borgmatic** (Categoría F): cubre `/mnt/hd2t/services/homepage/` |
| Logs de Homepage                            | stdout del contenedor (Dozzle, Loki si está)                       | n/a — efímero                                              |

> **Restauración tras desastre**:
>
> 1. Restaurar el repo `~/homelab/` desde git remoto (Codeberg/GitHub privado). Esto trae `docker-compose.yml`, `.env.example` y los cinco YAMLs de configuración íntegros.
> 2. Reconstruir `~/homelab/dashboards/.env` desde Vaultwarden (entrada "Homepage — Homelab API tokens").
> 3. (Si se usaban custom icons) Restaurar `/mnt/hd2t/services/homepage/icons/` desde el repo Borg.
> 4. `make up STACK=dashboards` — Homepage arranca, lee los YAMLs, hace el primer poll de cada widget. Estado completo recuperado en <1 minuto.
> 5. **No hay BD que restaurar**, no hay sesiones de usuario, no hay configuración de UI hecha por clicks. Esta es la **principal ventaja** del enfoque YAML-as-code.

> **Antes de cualquier upgrade _minor_ de Homepage** (`v0.10.x → v0.11.0`):
>
> 1. Leer el [_changelog upstream_](https://github.com/gethomepage/homepage/releases): los _bumps_ de minor a veces cambian la sintaxis de algún widget (renombran un campo, deprecan un widget).
> 2. Editar `.env`: `HOMEPAGE_IMAGE_TAG=v0.11.0`.
> 3. **No hay snapshot que hacer** — la config en git es ya el snapshot. Si tras el upgrade falla algo, `git revert` + ajustar `HOMEPAGE_IMAGE_TAG=v0.10.9` y `up -d homepage`.
> 4. `docker compose -f ~/homelab/dashboards/docker-compose.yml pull homepage`.
> 5. `docker compose -f ~/homelab/dashboards/docker-compose.yml up -d homepage`.
> 6. Verificar que la home carga, que los widgets siguen activos, que los logs no muestran `Unknown widget type` o `Deprecated field`.
>
> Los _bumps_ de **patch** (`v0.10.9 → v0.10.10`) los gestiona Watchtower automáticamente; el operador no necesita intervenir, pero **debería revisar el `docker logs homepage` el día siguiente al pull** para confirmar que arrancó bien.

---

## Troubleshooting

### `homepage` arranca y queda en `unhealthy`

El `start_period: 30s` da margen para Next.js + leer YAMLs. Si tras 1 minuto sigue `starting`/`unhealthy`, mirar los logs:

```bash
docker logs homepage --tail 100
```

Causas frecuentes:

1. **YAML mal formado**: `Error in services.yaml:42 — bad indentation of a mapping entry`. Solución: corregir el YAML (validador online o `python3 -c "import yaml; yaml.safe_load(open('...'))"`).
2. **Widget con `type:` desconocido**: `Error in services.yaml:60 — unknown widget type 'pi-hole'` (la sintaxis correcta es `pihole` sin guion). Buscar en https://gethomepage.dev/widgets/ el _type_ correcto.
3. **`HOMEPAGE_ALLOWED_HOSTS` mal**: si la app no responde a `homepage.lan` (sólo a `localhost`), confirmar que la variable incluye exactamente el dominio que aparece en el `Caddyfile`. Sensible a mayúsculas y a espacios. CSV sin espacios extra: `HOMEPAGE_ALLOWED_HOSTS=homepage.lan,pi.<TAILNET>.ts.net`.
4. **Bind mount apuntando a un directorio que no existe**: `Cannot read directory /app/config — ENOENT`. Solución: confirmar que `~/homelab/dashboards/homepage/config/` existe y contiene los cinco YAMLs.
5. **Permisos del bind mount**: `EACCES: permission denied, open '/app/config/services.yaml'`. Solución: `sudo chown -R 1000:1000 ~/homelab/dashboards/homepage/config && chmod 0644 ~/homelab/dashboards/homepage/config/*.yaml`.

### `502 Bad Gateway` desde Caddy hacia `homepage`

Caddy responde 502 si no puede alcanzar `homepage:3000` desde la red `homelab`. Probar:

```bash
docker exec caddy curl -fsS -o /dev/null -w '%{http_code}' http://homepage:3000/
# 200 o 404  — si devuelve esto, Caddy está bien y el problema es otro.
# "Connection refused": Homepage no está sirviendo. Pasar al caso anterior.

docker exec caddy nslookup homepage
# Debe resolver a una IP del 172.20.10.0/24.
```

Causas:

1. Homepage en `unhealthy` — ver caso anterior.
2. `homepage` no está enganchado a `homelab` (mira con `docker network inspect homelab`). Si no está, revisar la sección `networks:` del compose y `up -d homepage` de nuevo.
3. `homepage` está en `homelab` pero el alias DNS no está propagado (raro). Reinicio del contenedor lo arregla.

### Un widget muestra "Error" o spinner perpetuo

Diagnóstico:

```bash
# Logs del backend de Homepage. Cada llamada fallida queda registrada.
docker logs homepage --tail 50 | grep -iE 'error|warn|401|403|500'
```

Causas frecuentes:

1. **Token vacío o inválido**: el widget hace 401 (Unauthorized). Verificar el `.env`:
   ```bash
   grep '^HOMEPAGE_VAR_PIHOLE_API_TOKEN' ~/homelab/dashboards/.env
   # HOMEPAGE_VAR_PIHOLE_API_TOKEN=<token largo>
   ```
   Y volver a entrar en la UI del servicio (Pi-hole, Sonarr, etc.) a verificar que el token es el que está activo.
2. **URL interna mal escrita**: `widget.url: http://piholee` (con doble e) → DNS no resuelve. Solución: corregir en `services.yaml`.
3. **El servicio está caído**: el widget de Sonarr falla porque Sonarr está parado. Confirmar con `docker ps | grep sonarr` y arreglar el servicio antes de seguir buscando bugs en Homepage.
4. **Widget incompatible con la versión del servicio**: por ejemplo, un widget de "Sonarr v4" cuando el contenedor corre Sonarr v3. Solución: actualizar el servicio o usar el widget correspondiente a su mayor (Homepage suele soportar varias versiones; ver docs upstream del widget concreto).
5. **Network policy / firewall**: si el contenedor del servicio destino tiene políticas que rechazan tráfico desde la red `homelab`, el widget verá `Connection refused`. Para los servicios del homelab esto **no debería ocurrir** (todos están en `homelab` o tienen alias). Si ocurre, revisar la sección `networks:` del compose del servicio destino.

### Cambios en YAML no se aplican (hot-reload no dispara)

Síntomas: edito `services.yaml`, refresco el navegador, no veo el cambio.

Diagnóstico:

```bash
docker logs homepage --tail 20 | grep -i 'reload\|change'
# Esperado: 'Detected change in services.yaml, reloading...' o similar.
# Si no aparece, el watcher no detectó el cambio.
```

Causas:

1. **Editor que reescribe el fichero con un nombre temporal**: algunos editores (vim por defecto, Helix) hacen `write to .swap, rename to original`. El _inotify_ de chokidar suele detectarlo, pero hay fallos puntuales. Solución: `:set nowritebackup` en vim, o forzar el reload con `docker exec homepage kill -HUP 1` (señal estándar de "recarga config" — Homepage lo respeta).
2. **El bind mount está montado sin `:rw` requerido por inotify**: chokidar detecta cambios fine en bind mounts `:ro` (porque inotify trabaja a nivel de filesystem, no del modo de montaje), así que esto **no debería ser el problema**. Pero en kernels antiguos puede dar issues. Solución: cambiar el mount a `:rw` y aceptar que el contenedor podría escribir (fiable para Homepage, que no escribe).
3. **Bug genuino del watcher**: `docker compose restart homepage` lo arregla. Es un workaround, no una solución permanente; reportar en GitHub de Homepage si se reproduce.

### `HOMEPAGE_ALLOWED_HOSTS` rechaza peticiones legítimas

Síntomas: `https://homepage.lan/` responde 400 / 421 / 403.

Diagnóstico:

```bash
# Confirmar el valor de la env var DENTRO del contenedor:
docker exec homepage env | grep HOMEPAGE_ALLOWED_HOSTS
# HOMEPAGE_ALLOWED_HOSTS=homepage.lan,pi.<TAILNET>.ts.net
```

Causas:

1. **Variable no expandida**: si el `.env` no se carga bien (`docker compose --env-file ...` mal pasado), `HOMEPAGE_ALLOWED_HOSTS=` queda vacío y la app sólo responde a `localhost`. Solución: verificar que el _Makefile_ pasa `--env-file` correctamente (ver `docs/02-docker/02-estructura-compose.md`, sección _Makefile_).
2. **Hostname con puerto**: si el navegador llega con `Host: homepage.lan:443`, la coincidencia falla. Caddy debería normalizar a `homepage.lan`, pero si el operador prueba con `curl -H "Host: homepage.lan:443"` el rechazo es esperado.
3. **Tailscale MagicDNS hostname distinto**: `pi.<TAILNET>.ts.net` debe coincidir EXACTAMENTE con el hostname asignado en Tailscale (lowercase, con el sufijo `.ts.net` correcto). Verificable con `tailscale status`.

### El widget de Pi-hole muestra "Forbidden" / 403

Causa específica de Pi-hole: la API de Pi-hole **requiere** el token vía query param (`?auth=<token>`) o header `X-Pi-hole-Authenticate`. Homepage usa el header. Si la versión de Pi-hole es <5.18, el header puede no ser respetado y devuelve 403.

Soluciones:

1. **Actualizar Pi-hole** a la última 5.x o 6.x.
2. **Verificar que el token es el de la Web UI**, no un token autogenerado de otro tipo. Pi-hole tiene **un único** API token que coincide con el password de admin (hashed) o con el token mostrado en `Settings → API → Show API token`.

---

## Migrar a Authelia con `forward_auth` (opcional)

Si en algún momento se decide poner Homepage detrás de SSO (por ejemplo, si el homelab pasa a estar accesible desde internet, o si en el hogar hay invitados de los que se quiere ocultar el dashboard), el procedimiento es:

1. **Actualizar el bloque del `Caddyfile`**:
   ```caddy
   homepage.lan {
       tls internal
       import security-headers
       import logging
       import authelia       # ← descomentar / añadir

       reverse_proxy homepage:3000 {
           header_up Host {host}
           header_up X-Real-IP {remote_host}
           header_up X-Forwarded-For {remote_host}
           header_up X-Forwarded-Proto {scheme}
           header_up X-Forwarded-Host {host}
       }
   }
   ```
2. **Validar y recargar Caddy**:
   ```bash
   docker exec caddy caddy validate --config /etc/caddy/Caddyfile
   docker exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```
3. **Probar**: `https://homepage.lan/` debe redirigir a `https://auth.lan/?rd=https://homepage.lan/` (login de Authelia). Tras login válido, el dashboard carga.
4. **Coste/beneficio**: aplicable sólo si los _trade-offs_ descritos en **Decisiones de diseño** → _forward_auth: NO_ ya no aplican. Por defecto, **no se hace**.

> **No afecta a los widgets**: los widgets siguen funcionando porque las peticiones que hace Homepage al backend de cada servicio son **server-side desde el contenedor `homepage`**, sin pasar por Caddy ni por Authelia. Los _tokens_ se siguen inyectando vía `.env` igual que antes.

---

## Docker socket proxy (opcional)

Si en algún momento se quiere mostrar el _status_ verde/rojo de cada contenedor en Homepage (sin auto-listarlos — sólo verificación), la aproximación segura es **proxiar el socket Docker** con permisos mínimos. **No** se monta `/var/run/docker.sock` directamente.

Esquema:

1. Añadir `tecnativa/docker-socket-proxy` (o `linuxserver/docker-socket-proxy`) al _stack_ `dashboards`:
   ```yaml
   docker-socket-proxy:
     image: tecnativa/docker-socket-proxy:0.1
     container_name: docker-socket-proxy
     restart: unless-stopped
     environment:
       CONTAINERS: "1"        # GET /containers/* permitido
       IMAGES: "0"
       NETWORKS: "0"
       VOLUMES: "0"
       EXEC: "0"
       POST: "0"              # ← critical: NO escrituras
       INFO: "1"
       VERSION: "1"
     volumes:
       - /var/run/docker.sock:/var/run/docker.sock:ro
     networks:
       - homelab
     security_opt:
       - no-new-privileges:true
   ```
2. Actualizar `~/homelab/dashboards/homepage/config/docker.yaml`:
   ```yaml
   my-docker:
     host: docker-socket-proxy
     port: 2375
   ```
3. Referenciar en cada servicio del `services.yaml` que tenga un contenedor en el mismo host:
   ```yaml
   - Sonarr:
       href: https://sonarr.lan/
       icon: sonarr.svg
       container: sonarr        # ← muestra status del container 'sonarr'
       server: my-docker
       widget: ...
   ```
4. **Restart Homepage**: `docker compose -f ~/homelab/dashboards/docker-compose.yml up -d homepage`.

> **Coste**: añade un cuarto contenedor al _stack_ (Homepage + docker-socket-proxy + Homarr cuando llegue + … ). El proxy es ligero (~3 MB de RAM). El _trade-off_ de seguridad es **mucho más asumible** que montar el socket directo.

> **Documentación específica**: si el operador decide aplicarlo, conviene crear un `docs/12-dashboards/03-docker-socket-proxy.md` aparte. **No** es objetivo de este documento.

---

## Custom icons (opcional)

Aunque la imagen oficial trae miles de iconos, eventualmente se quiere uno personalizado (logo del propio homelab, una variante de Pi-hole con el logo nuevo de 2026, un icono para un servicio interno casero).

Procedimiento (resumen del paso 3 de **Configuración tras primer arranque**):

```bash
sudo mkdir -p /mnt/hd2t/services/homepage/icons
sudo chown -R 1000:1000 /mnt/hd2t/services/homepage/icons

# Copiar SVG / PNG (preferiblemente SVG para escalado perfecto):
cp ~/Downloads/mi-servicio.svg /mnt/hd2t/services/homepage/icons/

# Activar el bind mount en docker-compose.yml:
$EDITOR ~/homelab/dashboards/docker-compose.yml
# Descomentar:
#   - /mnt/hd2t/services/homepage/icons:/app/public/icons:ro

cd ~/homelab/dashboards && docker compose up -d homepage

# Referenciar en services.yaml con ruta absoluta:
# icon: /icons/mi-servicio.svg
```

> **Mantener un repo separado de assets binarios**: si se acumulan muchos custom icons, conviene gestionarlos como un repo aparte (Codeberg/GitHub privado) y `git submodule` desde `~/homelab/dashboards/homepage/`. **Out of scope** para este documento.

---

## Referencias

- Homepage — proyecto upstream: <https://github.com/gethomepage/homepage>
- Homepage — documentación oficial: <https://gethomepage.dev/>
- Homepage — listado de widgets soportados: <https://gethomepage.dev/widgets/>
- Homepage — schema de `services.yaml`: <https://gethomepage.dev/configs/services/>
- Homepage — schema de `settings.yaml`: <https://gethomepage.dev/configs/settings/>
- Homepage — schema de `widgets.yaml` (info widgets): <https://gethomepage.dev/widgets/info/>
- Imagen Docker (multi-arch incluyendo ARM64): <https://github.com/gethomepage/homepage/pkgs/container/homepage>
- `walkxcode/dashboard-icons` — repositorio comunitario de iconos: <https://github.com/walkxcode/dashboard-icons>
- `tecnativa/docker-socket-proxy` — proxy seguro del socket Docker: <https://github.com/Tecnativa/docker-socket-proxy>
- Documentos relacionados del homelab:
  - `docs/02-docker/02-estructura-compose.md` — convenciones del repo Compose, red `homelab`, Makefile
  - `docs/02-docker/04-watchtower.md` — política _opt-in_/_opt-out_ de Watchtower
  - `docs/03-red/02-pihole.md` — DNS local (`*.lan` wildcard)
  - `docs/03-red/04-caddy.md` — _reverse proxy_ + TLS interno + _snippets_
  - `docs/04-seguridad/01-authelia.md` — `forward_auth` opcional
  - `docs/07-backups/01-estrategia-backup.md` — categorías A-F (Homepage = F)
  - `docs/07-backups/03-backup-docker-volumes.md` — _hooks_ por servicio (no aplica a Homepage)
  - `docs/12-dashboards/02-homarr.md` — segundo dashboard del _stack_, alternativa con UI editable
