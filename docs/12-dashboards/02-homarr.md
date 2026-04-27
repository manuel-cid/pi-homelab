# Homarr (dashboard editable con UI drag-and-drop)

## Descripción

Despliegue de **Homarr** como **segundo dashboard** del homelab y único habitante restante del _stack_ `dashboards`, conviviendo con Homepage (`docs/12-dashboards/01-homepage.md`) en `~/homelab/dashboards/`. Si Homepage es el dashboard "**configuración como código**" — cinco YAMLs en `git`, _hot-reload_, cero estado interno —, Homarr es su antítesis deliberada: un **dashboard de _drag and drop_** servido en `https://homarr.lan/` cuya **fuente de verdad es una base de datos SQLite interna** (`/appdata/db.sqlite`), donde el operador construye el _layout_ moviendo _tiles_ con el ratón, define _integraciones_ pegando tokens en formularios, asigna iconos eligiéndolos del catálogo embebido y crea **boards** distintos para perfiles distintos (un board para el operador con widgets de Pi-hole/Sonarr/Grafana; un board "familia" sin esos detalles técnicos; un board "móvil" con sólo los enlaces más usados).

Homarr v1 (la rama actual, mantenida por la organización **homarr-labs** tras el _hard fork_ del proyecto original a finales de 2024) trae **autenticación multi-usuario nativa** (NextAuth con _provider_ `credentials`, sesiones en BD, _hashed passwords_), **secretos cifrados en la BD** (vía `SECRET_ENCRYPTION_KEY` AES-256), **integraciones con >40 servicios** (Sonarr, Radarr, Prowlarr, Transmission, Jellyfin, Plex, Pi-hole, Home Assistant, Portainer, Uptime Kuma, Mealie, Audiobookshelf, Stash…) y **widgets dinámicos** alimentados por esas integraciones (queue de Sonarr, % bloqueado de Pi-hole, dispositivos online de Home Assistant, espacio libre del NAS). Todo accesible y editable desde la UI, con **0 ficheros de configuración a editar** una vez puesto en marcha. La complejidad operativa se traslada a la BD: hay que **respaldarla** (es la única copia de la verdad), hay que **restaurarla** tras un desastre, y hay que **versionar las _exports_ JSON** que Homarr permite generar de cada board para tener _diffs_ legibles fuera de la BD.

> **Por qué dos dashboards.** El homelab no necesita dos dashboards; los necesita el **operador** mientras decide cuál de los dos enfoques le encaja mejor a largo plazo. Convivir tres-seis meses con ambos contesta preguntas que de otra manera se resolverían sólo "en teoría":
>
> - ¿Cuánto cuesta editar el _layout_? Con Homepage hay que abrir el editor y entender YAML (alta barrera para invitados/familia, mínima para el operador). Con Homarr hay que arrastrar y soltar (cero barrera para cualquiera con la sesión).
> - ¿Cuánto cuesta versionar cambios? Con Homepage es `git diff`. Con Homarr hay que **exportar a JSON** y commitear el JSON (más fricción, menos automático).
> - ¿Cuánto cuesta restaurar tras un desastre? Con Homepage es `git clone + make up`. Con Homarr es restaurar `db.sqlite` desde Borg y reiniciar el contenedor (más pasos, pero recupera _layouts_ visuales que en Homepage habría que reconstruir leyendo YAMLs).
> - ¿La pareja/los hijos ven la diferencia? Probablemente sí: Homarr tiene un _look & feel_ más "consumer" (animaciones, iconos grandes, modo oscuro pulido), Homepage es minimalista a lo Bootstrap-clásico.
>
> El operador decidirá tras un trimestre de uso. Mientras tanto, Caddy enruta `homepage.lan → homepage:3000` y `homarr.lan → homarr:7575`, cada uno con su propia URL, su propio favicon y su propio bookmark; a un click de distancia desde cualquier punto del homelab. **Si en seis meses queda claro que uno gana**, retirar el otro es trivial: detener su contenedor, eliminar el bloque del `Caddyfile`, dejar los datos en disco para no romper backups históricos. **El _stack_ `dashboards` está diseñado para soportar esa transición sin tocar nada más.**

> **Alcance**: este documento despliega Homarr **sin Authelia delante** (decisión justificada en **Decisiones de diseño** → _forward_auth: NO_, mismo razonamiento que Homepage pero con el matiz de que Homarr **sí tiene login propio nativo**), con **autenticación nativa por _credentials_** (un único usuario `admin` creado en el primer arranque), con la **BD SQLite respaldada por Borgmatic vía `dump_sqlite`** (Categoría B en `docs/07-backups/01-estrategia-backup.md`: regenerable en teoría, pero el _layout_ visual se perdería, así que entra al backup diario), **sin _Docker socket discovery_** (igual que Homepage — los servicios se enumeran a mano vía la UI o via _imports_ JSON), con integraciones activas para los servicios principales del homelab que ya están desplegados (Pi-hole, Portainer, Jellyfin, Sonarr/Radarr/Prowlarr, Transmission, Uptime Kuma, Home Assistant) y con la entrada en Borgmatic correspondiente. **No** se monta `/var/run/docker.sock`. **No** se configura SSO con Authelia (queda como **opcional** al final del documento). **No** se exponen widgets de servicios aún no desplegados.

> **Recordatorio de red**: Homarr **no se publica al host**. Caddy la alcanza por DNS interno de Docker (`homarr:7575` en la red `homelab`). La aplicación **sólo responde** a peticiones que llegan a través de Caddy — no hay puerto 7575 expuesto al exterior. Pi-hole resuelve `homarr.lan → 192.168.1.3` por el _wildcard_ de `02-homelab-local.conf` (ver `docs/03-red/02-pihole.md`). Igual que con Homepage: el _stack_ `dashboards` no abre puertos al host.

---

## Requisitos previos

- `docs/12-dashboards/01-homepage.md` completado: el _stack_ `dashboards` ya existe en `~/homelab/dashboards/`, con `docker-compose.yml`, `.env.example`, `.env`, `.gitignore` y la red Docker `homelab` (`br-homelab`, `172.20.10.0/24`) externa creada. **Este documento añade un servicio al compose existente, no crea uno nuevo.**
- `docs/01-sistema/04-estructura-directorios.md` completado: `/mnt/hd2t/services/homarr/` ya existe vacío (lo creó el `mkdir -p /mnt/hd2t/services/{homepage,homarr}` del paso "Fase 12 — Dashboards"). Este documento crea su contenido (`appdata/`).
- `docs/02-docker/02-estructura-compose.md` completado: la tabla de _stacks_ ya lista a Homarr en el _stack_ `dashboards`, las convenciones de _labels_ (`homelab.stack`, `homelab.backup`) y de _Makefile_ (`make up STACK=<stack>`) están definidas.
- `docs/02-docker/04-watchtower.md` completado: la convención `com.centurylinklabs.watchtower.enable` está documentada y Homarr aparece en la lista de **opt-in** desde el principio (justificación específica más abajo, **Decisiones de diseño** → _Watchtower opt-in_).
- `docs/03-red/02-pihole.md` completado: Pi-hole resuelve `*.lan → 192.168.1.3` por el _wildcard_. **No hay que añadir nada** para `homarr.lan` — el _wildcard_ ya lo cubre (igual que `homepage.lan`).
- `docs/03-red/04-caddy.md` completado: Caddy escucha en `192.168.1.3:443` con `tls internal`, los _snippets_ `security-headers.caddy` y `logging.caddy` existen. La CA local ya firma `*.lan`. Tras desplegar Homepage, este documento añade un segundo bloque (`homarr.lan`) hermano del primero.
- `docs/04-seguridad/01-authelia.md` completado: existe el _snippet_ `import authelia` reutilizable, **opt-in por sitio**. Aquí no se usa por defecto (ver decisiones de diseño), pero queda disponible.
- `docs/04-seguridad/02-fail2ban.md` completado: la maquinaria base de Fail2ban está activa. Este documento añade un _jail_ específico para Homarr (`homarr-auth`) si se decide endurecer la _login page_ — opcional, sección _Configuración tras primer arranque_ → _Jail de fail2ban_.
- `docs/07-backups/01-estrategia-backup.md` completado: las categorías A-F están definidas. Homarr cae en **Categoría B** (regenerable, pero el _layout_ visual y las integraciones tendrían que volver a configurarse "click a click", lo cual es coste suficiente para entrar al backup diario).
- `docs/07-backups/02-borgmatic.md` y `docs/07-backups/03-backup-docker-volumes.md` completados: el conjunto de _hooks_ de Borgmatic (`dump_sqlite`, `dump_postgres`, `dump_mariadb`) está cargado, la `source_directories` global del `config.yaml` ya incluye `~/homelab/` y `/mnt/hd2t/services/`. La nota previa `# Homarr  : /mnt/hd2t/services/homarr/configs/` queda **revisada** y reemplazada por una entrada activa con `dump_sqlite`.
- _Stacks_ previos vivos. Homarr no _depende_ funcionalmente de ninguno (renderiza igual sin nadie detrás), pero las **integraciones** quedarán inactivas para los servicios que no respondan. Lista esperada de servicios al menos parcialmente operativos para que el dashboard tenga sentido el primer día — la misma que Homepage:
  - **Stack `red`**: Pi-hole, Caddy.
  - **Stack `infra`**: Portainer, Watchtower, Dozzle.
  - **Stack `monitor`**: Prometheus, Grafana, Uptime Kuma.
  - **Stack `multimedia`**: Jellyfin (al menos web UI).
  - **Stack `descargas`**: Transmission, Sonarr, Radarr, Prowlarr (al menos web UI).
  - **Stack `domotica`**: Home Assistant.
- Conectividad saliente para descargar la imagen (sólo la primera vez):
  ```bash
  docker pull --platform linux/arm64 ghcr.io/homarr-labs/homarr:v1.0.0 >/dev/null && echo OK
  ```
- Que el host **no** tenga ya un servicio escuchando en `:7575` por error (`docker ps --format '{{.Names}} {{.Ports}}' | grep ':7575->' || echo OK`). Este servicio no publica puertos al host; Caddy es quien recibe el tráfico HTTPS.
- Espacio en `/mnt/hd2t/services/homarr/`: la BD SQLite de Homarr crece a ritmo de **~1-5 MB** (sesiones + boards + integraciones + iconos cacheados). En idle se estabiliza por debajo de 50 MB. El _stack_ `dashboards` sigue siendo el más ligero del homelab.
- **API tokens / API keys** ya generados en los servicios que se van a integrar — los mismos que Homepage requiere. Homarr y Homepage **comparten los tokens**: si ya están en Vaultwarden tras el deploy de Homepage, sirven aquí (entrarán manualmente en la UI de Homarr en _Settings → Integrations_). No es preciso generarlos a priori para todos: las integraciones se añaden de a una.
- Una **secreta de cifrado de 32 bytes (64 caracteres hex)** generada con `openssl rand -hex 32`, guardada en Vaultwarden como `Homarr — SECRET_ENCRYPTION_KEY`. **Sin esta clave no se pueden descifrar los tokens** que Homarr guarde en su BD: si se pierde, hay que reintroducir todas las integraciones a mano.

---

## Decisiones de diseño

### Por qué Homarr (y no Heimdall / Dashy / Flame / Glance / Organizr)

La **comparativa general** de candidatos ya está hecha en `docs/12-dashboards/01-homepage.md` → _Por qué Homepage…_. Aquí sólo se justifica **por qué se elige Homarr como segundo dashboard**, asumiendo que Homepage ya cubre el flanco "configuración como código":

- **Eje editorial complementario al de Homepage**. Homepage =  YAML versionable. Homarr = UI editable por _drag and drop_ con persistencia en BD. Tener ambos permite al operador comprobar en el día a día qué le encaja mejor sin tener que apostar por uno desde el inicio. La inversión (~150 MB de imagen + ~50 MB de BD) es marginal en una Pi 5 con 8 GB.
- **Autenticación nativa multi-usuario**. Homarr v1 incluye un proveedor `credentials` de NextAuth con _hashed passwords_ (bcrypt) y sesiones en BD. Permite tener un usuario "operador" con todas las integraciones visibles y un usuario "familia" con un board reducido (sin Pi-hole, sin Sonarr, sin Grafana — sólo Jellyfin, Nextcloud, Vaultwarden, Mealie). Homepage **no** tiene login propio: o todo abierto, o todo bajo Authelia. Homarr cubre el _gap_ de "auth ligera por dashboard, sin tocar el resto del homelab".
- **Integraciones con secretos cifrados en BD**. Homarr cifra los tokens de integración con AES-256 usando `SECRET_ENCRYPTION_KEY`. La BD respaldada conserva los secretos cifrados; el atacante que obtenga la BD sin la clave **no puede leer los tokens**. Homepage no tiene este problema porque no almacena tokens (los lee de _env vars_), pero también significa que Homepage requiere reiniciar el contenedor cada vez que cambia un token. En Homarr basta editar el formulario.
- **Multi-board**. Homarr soporta varios _boards_ por instancia: el operador puede tener un `default` con todo, un `mobile` con sólo enlaces grandes, un `family` para el resto del hogar. URL distinta por board (`https://homarr.lan/boards/family`). Homepage tiene un único dashboard con grupos plegables — más sobrio, menos versátil.
- **Ecosistema activo (homarr-labs)**. Tras el _hard fork_ de finales de 2024, la organización **homarr-labs** mantiene el proyecto con _release cadence_ semanal/quincenal, _changelog_ detallado, soporte multi-arquitectura (`linux/amd64`, `linux/arm64`, `linux/arm/v7`) en GitHub Container Registry. Documentación oficial en <https://homarr.dev/>. Open source MIT.
- **Soporte ARM64 oficial** vía `ghcr.io/homarr-labs/homarr`. Imagen multi-arch.
- **No es Organizr/Heimdall**: heredan dos décadas de _legacy_ (Organizr es PHP+nginx, Heimdall es Laravel sin actualizaciones recientes). Homarr v1 es un **rewrite** Next.js + tRPC + SQLite, ligero y mantenido.

Lo que se renuncia con Homarr (y motiva tener Homepage en paralelo):

- **Configuración no versionable como código** _per se_. La fuente de verdad es `db.sqlite`. Existe un mecanismo de _import/export_ JSON por board (vía UI), pero requiere acción manual. No hay _hot-reload_ desde un repo git.
- **Más superficie de auth que mantener**. Hay una contraseña que el operador podría olvidar; un mecanismo de reset (a través de la CLI de Homarr o reseteando el `db.sqlite`); _bruteforce protection_ que toca configurar (jail Fail2ban, opcional).
- **BD que respaldar**: si se pierde, se pierde el _layout_ y las integraciones. Solución: dump diario por Borgmatic + export JSON de cada board commit-eado al repo cada vez que se hace un cambio mayor (procedimiento documentado más abajo).
- **Footprint algo mayor**: ~150-200 MB de RAM en idle (vs. 100-150 MB de Homepage), por la pila Next.js + SQLite + _NextAuth_ + workers internos para refrescar widgets.

### Imagen y _tag_

- **`ghcr.io/homarr-labs/homarr:v1.0.0`** — Homarr v1 empaquetado por la organización mantenedora actual, multi-arch (`linux/arm64` incluida). Pinneada a _tag_ "vmajor.minor.patch" semver siguiendo la convención del homelab (ver `docs/02-docker/02-estructura-compose.md`, sección **Imágenes**: nada de `:latest`). El _tag_ `v1.0.0` se usa como ejemplo y baseline; el operador eleva el _patch_ leyendo el _changelog_ ([releases](https://github.com/homarr-labs/homarr/releases)). Los _bumps_ de **patch** (`v1.0.0 → v1.0.1`) son retrocompatibles y los gestiona Watchtower (ver más abajo). Los _bumps_ de **minor** (`v1.0 → v1.1`) pueden traer migraciones automáticas de la BD (Drizzle ORM aplica los SQL de `migrations/` al arrancar) — siempre se hace dump de `db.sqlite` antes. Los _bumps_ de **major** (`v1.x → v2.x`) requieren leer las _release notes_ con calma y muy probablemente exportar todos los boards a JSON antes para tener una salida de emergencia.
- **No se usa `:latest`** — la BD lleva un _schema_ versionado por Drizzle; cruzar de un minor a otro sin saberlo puede aplicar migraciones que no se quieren todavía o, peor, dejar la BD en estado intermedio si el _pull_ falla a medias. El _tag_ pinneado da control del cuándo y el cómo.

#### Watchtower opt-in en este contenedor

Razones, mismo patrón que Homepage / FreshRSS / Linkding / Mealie:

- El proyecto sigue **semver semi-estricto**: los _bumps_ de **patch** (`v1.0.x` patches) son retrocompatibles, no introducen migraciones de BD destructivas y **no cambian** el _schema_ de NextAuth. Watchtower puede aplicarlos sin riesgo. _docs/02-docker/04-watchtower.md_ → tabla de servicios _opt-in_ ya lista a Homarr.
- La superficie de criticidad es baja: si Homarr cae 30-60 segundos durante un `restart` post-pull de Watchtower, el operador no pierde nada (Homepage sigue accesible en paralelo, los servicios siguen accesibles por sus URLs directas; el dashboard sólo es un _convenience layer_).
- Las migraciones automáticas de Drizzle son **idempotentes**: si Drizzle detecta que la BD ya está al nivel del _schema_ esperado, no hace nada. Si detecta una migración pendiente y falla a medias, el contenedor no arranca y el _healthcheck_ lo deja en `unhealthy` (recuperable restaurando el dump de Borg o haciendo `docker compose down && pull` con el tag anterior).
- La configuración de _layouts_ y de auth vive **dentro** de la BD; el `restart` no toca nada del operador.

Etiquetar con `com.centurylinklabs.watchtower.enable: "true"`. Para _bumps minor_ (`v1.0 → v1.1`), Watchtower **respeta el _tag_** del compose: no cruza de `:v1.0.0` a `:v1.1.0` solo porque exista un `:latest` distinto. Lo único que hace es _re-pull_ del mismo _tag_ por si hubo un _rebuild_ con un _digest_ nuevo. Para _bumps minor_ habrá que editar `HOMARR_IMAGE_TAG` a mano tras dump previo.

> **Coherencia con `docs/02-docker/04-watchtower.md`**: ese documento ya lista a "Homarr" en la lista explícita de servicios **opt-in** desde el principio. No hace falta justificar nada extra aquí; sólo aplicar la etiqueta.

### Estado en BD: drag-and-drop, no YAML-as-code

Homarr es uno de los pocos servicios del homelab cuya **fuente de verdad es interna y mutable por la UI**. La BD SQLite (`/appdata/db.sqlite`) contiene:

- Usuarios, _hashed passwords_, sesiones de NextAuth (`User`, `Session`, `Account`, `VerificationToken`).
- Boards, _items_ (apps), _widgets_, _layouts_, _categories_ (`Board`, `Item`, `Section`, `Layout`).
- Integraciones, con sus URLs y **tokens cifrados** en columnas `Integration.secrets` (cifrado por `SECRET_ENCRYPTION_KEY`).
- Iconos custom subidos por la UI (`/appdata/medias/`).

Implicaciones operativas — **opuestas a las de Homepage**:

- **Cada cambio del dashboard** = una mutación en la BD. **No** queda registro de cambios en `git log`. Si el operador quiere historial fino, debe hacer _exports JSON_ regulares (procedimiento más abajo) y commitear esos JSON al repo.
- **No-diffeable** sin esfuerzo: no hay un `git diff` que muestre "ayer eliminé el widget de Pi-hole". Sólo se nota tras restaurar un dump y comparar.
- **No-revertible** automáticamente: si el operador rompe el board borrando un widget, hay que **restaurar `db.sqlite` desde el último dump** (`docs/07-backups/03-backup-docker-volumes.md`).
- **No-reproducible** sin la BD: si la Pi se reinstala desde cero (`docs/13-operaciones/02-disaster-recovery.md`), restaurar Homarr requiere recuperar `db.sqlite` y `medias/` desde Borg. **No basta con `git clone`**; sin la BD, el dashboard arranca vacío y hay que reconfigurar el _layout_, las integraciones (con todos sus tokens), las preferencias de cada widget…
- **El bind mount es _read-write_**: la BD se escribe, los iconos se suben, las sesiones se persisten. No es seguro declararlo `:ro` ni siquiera con un volumen sólo para `medias/`.

Esta filosofía contrasta directamente con la del documento anterior (`docs/12-dashboards/01-homepage.md`), donde Homepage es 100 % declarativo en cinco YAMLs versionados en git. La comparación es **deliberada**: el homelab convive con ambos enfoques y el operador decide en función de su experiencia real.

> **Mitigación recomendada**: tras cada cambio significativo del dashboard (añadir un board, reorganizar widgets, configurar una nueva integración), **exportar el board afectado a JSON** desde la UI (_Settings → Boards → Export_) y commitear el JSON resultante en `~/homelab/dashboards/homarr/exports/`. Esto da un _history log_ legible (cada export es un JSON revisable con `git diff`), una salida rápida en caso de migración a otro dashboard (importable a Homepage manualmente o a un Homarr v2 futuro), y una segunda copia fuera de la BD (replicada por `git push` al remoto).

### `forward_auth` con Authelia: **NO** para Homarr (por defecto)

Misma decisión que Homepage, pero con dos matices:

- **Homarr SÍ tiene login propio**, a diferencia de Homepage. El proveedor _credentials_ de NextAuth es _ad-hoc_ del homelab y **suficiente** para el _threat model_ (LAN + Tailscale, sin internet expuesto): un atacante en la red doméstica que ya pasó WPA2/WPA3 + un atacante en el tailnet que ya pasó Tailscale auth + un atacante que descifra `bcrypt` en local de un `db.sqlite` sustraído… todos esos escenarios están **muy por encima** del nivel de _attack surface_ que el dashboard pretende defender.
- **Las _integraciones_ no pueden pasar por Authelia**: Homarr llama a Sonarr/Radarr/Pi-hole **server-side** desde el contenedor `homarr` por DNS interno (`http://sonarr:8989`, `http://pihole:80`), saltándose Caddy. Authelia no podría protegerlas aunque se quisiera (las llamadas no pasan por el _reverse proxy_).
- **Familia/invitados** abren `homarr.lan` y ven el board "family" en la pantalla de login. Tras meter user/pass del usuario `family` (definido por el operador), el board carga. Es **la misma barrera** que Homepage tendría con Authelia, pero **gestionada en la propia app**, sin SSO externo. El coste de mantenimiento del operador es mucho menor (una contraseña por usuario, gestionable desde la UI).
- **El homelab vive en LAN + Tailscale**. No hay acceso desde internet. El SSO global no aporta ventaja relevante; aporta complejidad (un punto extra de fallo, otra capa de redirecciones que confunde a familia/invitados que sólo querían ver "está Jellyfin online").

> **Si en el futuro** se decide que **todos los servicios del homelab** pasen por Authelia (escenario "homelab abierto a internet con dominio público"), poner Homarr detrás de `forward_auth` es trivial y queda documentado al final, en **Migrar a Authelia con `forward_auth` (opcional)**. Por defecto, **no se aplica**.

### Docker socket: **NO** se monta `/var/run/docker.sock`

Misma decisión y justificación que Homepage (ver `docs/12-dashboards/01-homepage.md` → _Docker socket: NO_):

1. **Static mode** (este documento): cada servicio se enumera a mano en la UI de Homarr (o vía import JSON). **Sin acceso al socket Docker.**
2. **Discovery mode** (alternativa): Homarr soporta una integración "Docker" si se monta `/var/run/docker.sock:/var/run/docker.sock:ro`. Detecta los _containers_ corriendo y muestra estado verde/rojo automático.

Se elige el **modo estático** por las dos razones idénticas a las de Homepage:

- **Seguridad**: montar `docker.sock` (incluso `:ro`) en un contenedor expuesto a HTTP es una **escalada potencial de privilegios al host completo**. El `:ro` no protege: el _socket_ permite escrituras (`POST /containers/create`) si el _client_ las hace. Para Homarr, donde la BD almacena tokens de servicios y el contenedor maneja sesiones de usuario, el coste/beneficio no compensa.
- **Claridad declarativa**: la enumeración manual de _items_ en cada board es **más legible** que la _discovery_ automática que mete _containers_ con nombres crípticos (`paperless-redis`, `bookstack-db`).

> **Si en el futuro se quiere _discovery_ parcial**, se aplica el mismo _docker-socket-proxy_ que se documenta en `docs/12-dashboards/01-homepage.md` → _Docker socket proxy (opcional)_. **Un único proxy** sirve a Homepage y a Homarr a la vez si se decide habilitarlo en el _stack_. Documentado al final, **Docker socket proxy compartido (opcional)**.

### Bind mount: `appdata/` en disco externo

A diferencia de Homepage (cuya configuración vive en el repo git), el _state_ de Homarr **no se commitea**: la BD es un binario, los iconos son blobs, las sesiones son efímeras. Va a `/mnt/hd2t/services/homarr/appdata/`, en línea con el resto de servicios del homelab que persisten en `/mnt/hd2t/services/<svc>/`. Razones:

- **Volumen y mutabilidad**: una BD SQLite que crece y se reescribe constantemente no encaja en un repo git (haría `git status` inestable, los _diffs_ serían ilegibles, el remoto se llenaría de blobs binarios). Va al disco "datos" (`hd2t`).
- **Borgmatic ya lo cubre**: la `source_directory` global del `config.yaml` incluye `/mnt/hd2t/services/`. El _hook_ de `dump_sqlite homarr homarr /appdata/db.sqlite` exporta una copia consistente de la BD antes del backup (sin `BEGIN IMMEDIATE` colgado).
- **Bind mount _read-write_**: imprescindible. La BD se escribe constantemente, los iconos se suben, las sesiones se persisten.
- **Permisos**: el contenedor de Homarr corre como `node` (UID 1000, GID 1000) — el mismo que el host (`PUID/PGID=1000`). Coincidencia útil para el resto del homelab. Verificación tras el _bind mount_: `stat -c '%U:%G' /mnt/hd2t/services/homarr/appdata` debe reportar `homelab:homelab`.

Adicionalmente, una carpeta separada `~/homelab/dashboards/homarr/exports/` versionada en git para los **exports JSON manuales** del operador (procedimiento _Configuración tras primer arranque_ → _Exportar boards a JSON_). Esa carpeta sí se commitea — es la única parte git-trackeable del estado de Homarr.

### `PUID`/`PGID` y permisos del bind mount

La imagen `ghcr.io/homarr-labs/homarr:v1.0.0` corre como **`node` (UID 1000, GID 1000)** dentro del contenedor por defecto — coincidencia bienvenida con el `PUID=1000`/`PGID=1000` del usuario `homelab` en el host. Esto significa que:

- El contenedor lee y escribe `/appdata/` sin problemas si el bind mount tiene ownership `1000:1000` (el usuario `homelab`, propietario natural del directorio).
- **Hay que pre-`chown`-earlo** una vez antes del primer arranque: `sudo chown -R 1000:1000 /mnt/hd2t/services/homarr` (_root_ creó el directorio en `04-estructura-directorios.md`, ahora hay que cambiar el ownership al usuario que ejecutará Homarr).
- El operador edita los _exports_ JSON (en `~/homelab/dashboards/homarr/exports/`) como usuario normal — sin `sudo` —, lo cual es lo deseable. Esos no requieren `chown` (ya son del operador desde el `git clone`).

Verificación tras el primer arranque:

```bash
stat -c '%U:%G %a' /mnt/hd2t/services/homarr/appdata
# homelab:homelab 750
```

### Almacenamiento

Resumen de paths (siguiendo el inventario unificado de la documentación):

| Path en el host                                       | Path en el contenedor       | Tipo                          | Backup                                           |
|-------------------------------------------------------|-----------------------------|-------------------------------|--------------------------------------------------|
| `/mnt/hd2t/services/homarr/appdata/`                  | `/appdata`                  | BD SQLite + iconos custom     | Borg (`source_directories: /mnt/hd2t/services/`) |
| `/mnt/hd2t/services/homarr/appdata/db.sqlite`         | `/appdata/db.sqlite`        | BD principal (estado entero)  | Borg (`dump_sqlite` consistente, **diario**)     |
| `/mnt/hd2t/services/homarr/appdata/medias/`           | `/appdata/medias`           | iconos custom subidos por UI  | Borg (`source_directories`)                      |
| `~/homelab/dashboards/homarr/exports/`                | (no montado)                | exports JSON manuales         | git (push remoto) + Borg (`source_directories: ~/homelab/`) |
| `~/homelab/dashboards/.env`                           | (variables de entorno)      | secretos (`SECRET_ENCRYPTION_KEY`, …) | **Vaultwarden** (no en git, no en Borg)  |

> **Por qué `appdata/` y no `configs/`**: la nota previa en `dump-databases.sh` decía `# Homarr  : /mnt/hd2t/services/homarr/configs/`. Ese path se basaba en la antigua estructura de Homarr 0.x (un archivo JSON por board en `/data/configs/`). En Homarr v1 la estructura es una BD SQLite + carpeta `medias/`, ambas bajo `/appdata/`. Este documento **actualiza** la línea de `dump-databases.sh` para reflejar la realidad (sección _Configuración tras primer arranque_ → _Hook de Borgmatic_).

---

## Estructura del _stack_ `dashboards` tras este documento

Antes de este documento (tras `docs/12-dashboards/01-homepage.md`):

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
├── productividad/
├── dashboards/
│   ├── docker-compose.yml         # 1 servicio: homepage
│   ├── .env
│   ├── .env.example
│   ├── .gitignore
│   └── homepage/
│       └── config/                # 5 YAMLs versionados
├── backups/
└── .env
```

Tras este documento:

```
~/homelab/
├── ...                            # los nueve stacks anteriores sin cambios
├── dashboards/
│   ├── docker-compose.yml         # ← MODIFICADO (2 servicios: homepage + homarr)
│   ├── .env                       # ← MODIFICADO (nuevas HOMARR_*)
│   ├── .env.example               # ← MODIFICADO (nuevas HOMARR_*)
│   ├── .gitignore                 # sin cambios
│   ├── homepage/
│   │   └── config/                # sin cambios
│   └── homarr/                    # ← NUEVO
│       └── exports/               # ← NUEVO (JSON exports versionados)
│           └── .gitkeep
├── backups/                       # sin cambios
└── .env
```

Y en el disco externo, sobre lo que ya creó `docs/01-sistema/04-estructura-directorios.md`:

```
/mnt/hd2t/services/homarr/         # creado vacío por 04-estructura-directorios.md
└── appdata/                       # ← NUEVO (creado al levantar el contenedor)
    ├── db.sqlite                  # BD principal
    ├── db.sqlite-wal              # write-ahead log
    ├── db.sqlite-shm              # shared memory
    └── medias/                    # iconos custom
```

Crear el subdirectorio del repo y el _stub_ del directorio de exports:

```bash
mkdir -p ~/homelab/dashboards/homarr/exports
touch ~/homelab/dashboards/homarr/exports/.gitkeep

# Verificar ownership (debe ser homelab:homelab):
ls -la ~/homelab/dashboards/homarr/
# drwxr-x--- 3 homelab homelab 4096 ... .
# drwxr-x--- 4 homelab homelab 4096 ... ..
# drwxr-xr-x 2 homelab homelab 4096 ... exports/
```

Crear y preparar el bind mount en el disco externo:

```bash
sudo mkdir -p /mnt/hd2t/services/homarr/appdata
sudo chown -R 1000:1000 /mnt/hd2t/services/homarr
sudo chmod 0750 /mnt/hd2t/services/homarr
sudo chmod 0750 /mnt/hd2t/services/homarr/appdata

# Verificar ownership (debe ser 1000:1000 = node = homelab):
stat -c '%U:%G %a' /mnt/hd2t/services/homarr/appdata
# homelab:homelab 750
```

> **Permisos**: `0750` para que el grupo `homelab` (y otros _contenedores_ del homelab que pudieran necesitarlo en el futuro) pueda leer, pero ningún otro usuario del host tenga acceso. La BD SQLite con tokens cifrados queda blindada a nivel de FS.

> **Ownership del bind mount `appdata/`**: `homelab:homelab` (UID/GID `1000:1000`) — coincide con `node:node` del contenedor. **Hay** que pre-chown-earlo (a diferencia de Homepage, donde el directorio venía del `git clone` y ya era del operador). Si se olvida, el contenedor falla con `EACCES: permission denied, open '/appdata/db.sqlite'` (ver _Troubleshooting_).

---

## Variables de entorno

Este documento **añade** variables al `.env` y al `.env.example` existentes del _stack_ `dashboards` (no los reemplaza).

### `~/homelab/dashboards/.env.example` — bloque añadido

Editar el `.env.example` ya creado en `docs/12-dashboards/01-homepage.md` y añadir el bloque Homarr **al final** del fichero, antes del cierre `EOF`:

```bash
$EDITOR ~/homelab/dashboards/.env.example
```

Añadir:

```bash
# ============================================================================
# Homarr — segundo dashboard. Documentación: docs/12-dashboards/02-homarr.md
# ============================================================================

# --- Imagen pinneada --------------------------------------------------------
HOMARR_IMAGE_TAG=v1.0.0

# --- Cifrado de secretos en BD ----------------------------------------------
# 64 caracteres hex (32 bytes). Generar con:  openssl rand -hex 32
# Esta clave cifra los tokens de integraciones que el operador pega en la UI
# (Sonarr, Radarr, Pi-hole, etc.) antes de persistirlos en /appdata/db.sqlite.
# Sin esta clave, no se pueden descifrar al restaurar la BD desde un backup.
# CUSTODIAR EN VAULTWARDEN, entrada "Homarr — SECRET_ENCRYPTION_KEY".
HOMARR_ENCRYPTION_KEY=__GENERAR_CON_OPENSSL_RAND_HEX_32__

# --- Auth (NextAuth) --------------------------------------------------------
# URL pública desde la que el navegador alcanza Homarr. Se usa para construir
# los callbacks de OAuth (no aplican aquí — se usa credentials provider) y
# para validar el origen de las cookies de sesión.
HOMARR_BASE_URL=https://homarr.lan

# Lista CSV de proveedores de auth a habilitar. Para este homelab, sólo
# 'credentials' (usuario+password local). Si el operador integra Authelia
# como OIDC en el futuro, añadir 'oidc' aquí.
HOMARR_AUTH_PROVIDERS=credentials
```

Listo. El bloque sigue el mismo patrón que el de Homepage: variables prefijadas (`HOMARR_*`), comentadas en español, con _hint_ del path en Vaultwarden donde se custodian los secretos.

### `~/homelab/dashboards/.env` — bloque añadido

Pegar el mismo bloque en el `.env` real, sustituyendo los `__PEGAR…__` por valores reales:

```bash
# Generar la clave de cifrado:
openssl rand -hex 32
# 7e3a...

# Editar el .env y pegar el bloque Homarr al final:
$EDITOR ~/homelab/dashboards/.env

# Tras la edición, comprobar permisos restrictivos:
chmod 0600 ~/homelab/dashboards/.env
ls -la ~/homelab/dashboards/.env
# -rw------- 1 homelab homelab ... .env
```

> **Custodia en Vaultwarden**: en la entrada `Homarr — SECRET_ENCRYPTION_KEY` guardar la cadena hex completa. Crear también una entrada `Homarr — admin user` con el usuario y password creados en el primer arranque (sección _Configuración tras primer arranque_).

> **No commitear `.env` jamás**. El `.gitignore` del _stack_ creado en Homepage ya excluye `.env` explícitamente.

> **Si la `HOMARR_ENCRYPTION_KEY` se cambia tras tener integraciones configuradas**: todas dejan de funcionar (los tokens cifrados con la clave anterior son ilegibles con la nueva). Hay que **borrar las integraciones desde la UI y volver a crearlas**. Por eso se genera UNA vez, se custodia, y no se rota salvo necesidad de seguridad.

---

## `~/homelab/dashboards/docker-compose.yml` — añadir servicio `homarr`

El compose ya existe (lo creó `docs/12-dashboards/01-homepage.md`). Añadir el servicio `homarr` **junto a** `homepage`, manteniendo intacto todo lo anterior. Resultado completo del fichero tras la edición (la sección Homepage no cambia; sólo se añade un segundo servicio):

```yaml
---
# Stack: dashboards — Homepage (estático) + Homarr (editable con UI)
# Documentación: docs/12-dashboards/01-homepage.md
#                docs/12-dashboards/02-homarr.md

services:

  # ===========================================================================
  # Homepage — dashboard de inicio (configuración 100 % declarativa).
  # Sin cambios respecto a docs/12-dashboards/01-homepage.md.
  # ===========================================================================
  homepage:
    image: ghcr.io/gethomepage/homepage:${HOMEPAGE_IMAGE_TAG}
    container_name: homepage
    hostname: homepage
    restart: unless-stopped
    mem_limit: 384m
    environment:
      TZ: ${TZ}
      HOMEPAGE_ALLOWED_HOSTS: ${HOMEPAGE_ALLOWED_HOSTS}
      # ... el resto de HOMEPAGE_VAR_* ya documentadas en 01-homepage.md
    volumes:
      - ./homepage/config:/app/config:ro
    networks:
      homelab:
        aliases:
          - homepage
    labels:
      homelab.stack: "dashboards"
      homelab.backup: "false"
      com.centurylinklabs.watchtower.enable: "true"
    healthcheck:
      test:
        - CMD-SHELL
        - "wget -qO- http://localhost:3000/api/healthcheck >/dev/null || wget -qO- http://localhost:3000/ >/dev/null"
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s

  # ===========================================================================
  # Homarr — segundo dashboard (UI editable, drag-and-drop, BD SQLite).
  # Login propio (NextAuth credentials), secretos cifrados en BD via
  # SECRET_ENCRYPTION_KEY. NO se monta /var/run/docker.sock (mismo criterio
  # que Homepage). Bind mount RW al disco hd2t (BD SQLite + medias).
  # ===========================================================================
  homarr:
    image: ghcr.io/homarr-labs/homarr:${HOMARR_IMAGE_TAG}
    container_name: homarr
    hostname: homarr
    restart: unless-stopped
    mem_limit: 384m
    environment:
      TZ: ${TZ}
      # Auth y URL pública
      AUTH_PROVIDERS: ${HOMARR_AUTH_PROVIDERS}
      AUTH_TRUST_HOST: "true"          # Caddy termina TLS, propaga X-Forwarded-*
      BASE_URL: ${HOMARR_BASE_URL}
      # Cifrado de secretos en BD (tokens de integraciones)
      SECRET_ENCRYPTION_KEY: ${HOMARR_ENCRYPTION_KEY}
      # Identidad de filesystem
      PUID: ${PUID}
      PGID: ${PGID}
    volumes:
      # Bind mount RW: BD SQLite + iconos custom + sesiones
      - /mnt/hd2t/services/homarr/appdata:/appdata
      # NO montar /var/run/docker.sock — ver decisiones de diseño.
    networks:
      homelab:
        aliases:
          - homarr     # Caddy resuelve 'homarr:7575' por este alias
    labels:
      homelab.stack: "dashboards"
      homelab.backup: "true"           # SI entra en Borgmatic con dump_sqlite
      # Opt-in: semver patch retrocompatible, downtime aceptable.
      com.centurylinklabs.watchtower.enable: "true"
    healthcheck:
      # Homarr expone /api/health (200 OK con JSON {"status":"ok"}).
      test:
        - CMD-SHELL
        - "wget -qO- http://localhost:7575/api/health >/dev/null || exit 1"
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 60s                 # Drizzle migrate + Next.js cold start

# ---------------------------------------------------------------------------
# Redes
# ---------------------------------------------------------------------------
networks:
  homelab:
    external: true                       # creada en docs/02-docker/02-estructura-compose.md
```

Notas de diseño del bloque añadido:

- **Sin red privada del stack**. Como ya anticipaba el comentario del compose tras Homepage: el _stack_ `dashboards` tiene dos contenedores y ninguno de los dos se comunica con el otro. Cada uno se engancha sólo a `homelab`.
- **Sin `ports:`**. Caddy alcanza `homarr:7575` por DNS interno. Si el operador necesita acceder sin pasar por Caddy: `docker exec homarr wget -qO- http://localhost:7575/api/health`.
- **`mem_limit: 384m`**: límite generoso para un Next.js + SQLite. Homarr idle se queda en torno a **150-200 MB de RSS reales**; los _refresh_ periódicos de widgets (cada minuto de media) puntualmente suben a ~280 MB. `384m` deja margen sin penalizar a otros stacks.
- **`start_period: 60s`** (más que Homepage): Drizzle aplica migraciones de _schema_ al arrancar (sólo en el primer arranque o tras un _bump_ minor) — puede tardar varios segundos. A esto se suma el _cold start_ de Next.js (~10 s) y el primer _seed_ de NextAuth. Total **típico ~20-40 s**, pico **<60 s**. El _healthcheck_ tolera el inicio.
- **Bind mount sin `:ro`**: la BD se escribe constantemente; **read-write obligatorio**.
- **Sin `${HOMARR_*:-}` con default vacío**: a diferencia de Homepage (donde tokens vacíos son aceptables), aquí `HOMARR_ENCRYPTION_KEY` **debe** estar presente — sin clave de cifrado, Homarr **no arranca** (falla con `Cannot read properties of undefined (reading 'length')` o similar en el _bootstrap_ del _crypto module_). Por eso se pasa _sin_ default vacío: si falta, Compose **falla en la fase de validación** (`KeyError: HOMARR_ENCRYPTION_KEY`), antes de intentar levantar el contenedor — ese _fail-fast_ es deseado.
- **`AUTH_TRUST_HOST: "true"`**: imprescindible cuando NextAuth está detrás de un _reverse proxy_ que termina TLS (Caddy). Sin esto, las cookies de sesión llevarían `secure: false` y el navegador las rechazaría tras el redirect HTTPS. Caddy ya propaga `X-Forwarded-Proto: https` (configurado en su bloque, ver _Despliegue_).
- **Sin `depends_on`**: Homarr no depende de ningún otro contenedor para arrancar. Si Pi-hole está caído, simplemente la integración con Pi-hole muestra "error" en la UI; el resto del dashboard funciona.
- **`wget` en el _healthcheck_**: la imagen `ghcr.io/homarr-labs/homarr` se basa en Alpine y trae `wget` por defecto.
- **`homelab.backup: "true"`**: a diferencia de Homepage (Categoría F = "false"), Homarr SÍ entra en Borgmatic con _hook_ propio (`dump_sqlite homarr homarr /appdata/db.sqlite`). La etiqueta es informativa y la utiliza el script `dump-databases.sh` (ver _Configuración tras primer arranque_).

---

## Despliegue

### Primer arranque

```bash
cd ~/homelab/dashboards

# Validar la sintaxis del compose sin levantar nada.
docker compose --env-file ../.env --env-file .env config | grep -E '^\s+(homepage|homarr):'
# homepage:
# homarr:

# Levantar AMBOS servicios (homepage ya está; el up -d no lo recrea si no hubo cambios):
docker compose --env-file ../.env --env-file .env up -d
```

O, equivalente, con el _Makefile_ (ver `docs/02-docker/02-estructura-compose.md`):

```bash
cd ~/homelab
make up STACK=dashboards
```

Vigilar el primer arranque (~30-60 s):

```bash
docker compose -f ~/homelab/dashboards/docker-compose.yml logs -f homarr
# homarr | [start] Migrating database schema (drizzle-kit)...
# homarr | [start] Migration applied: 0001_initial.sql
# homarr | [start] Migration applied: 0002_auth_tables.sql
# homarr | [start] Migration applied: ...
# homarr | [start] Database ready.
# homarr | [start] Starting Next.js production server on port 7575...
# homarr | ▲ Next.js 14.x.x
# homarr | - Local:        http://localhost:7575
# homarr | ✓ Ready in 2.3s
```

> **Si tarda más de 2 minutos** sin llegar a "Ready": revisar los logs por errores de migración o de _crypto_:
> - `Error: Cannot read properties of undefined (reading 'length')` → `HOMARR_ENCRYPTION_KEY` no está definida o está vacía.
> - `Error: SQLITE_CANTOPEN: unable to open database file` → permisos del bind mount; aplicar el `chown -R 1000:1000 /mnt/hd2t/services/homarr`.
> - `Error: ENOENT, mkdir '/appdata/medias'` → permisos del bind mount o el directorio no existe.

Verificar que el contenedor está `(healthy)`:

```bash
docker compose -f ~/homelab/dashboards/docker-compose.yml ps
# NAME       STATUS                       PORTS
# homepage   Up X minutes (healthy)
# homarr     Up X seconds (healthy)
```

> El `(healthy)` lo otorga el _healthcheck_ que comprueba `/api/health` devolviendo `200`. Si tras 2 minutos sigue `starting`/`unhealthy`, ir a **Troubleshooting** → primer arranque.

Confirmar que la BD se ha creado y el bind mount es escribible:

```bash
ls -la /mnt/hd2t/services/homarr/appdata/
# -rw-r--r-- 1 homelab homelab 491520 ... db.sqlite
# -rw-r--r-- 1 homelab homelab  32768 ... db.sqlite-shm
# -rw-r--r-- 1 homelab homelab      0 ... db.sqlite-wal
# drwxr-xr-x 2 homelab homelab   4096 ... medias

# Comprobación somera de que la BD tiene el schema esperado:
sudo -u homelab sqlite3 /mnt/hd2t/services/homarr/appdata/db.sqlite '.tables' \
  | tr ' ' '\n' | sort | head
# Account
# Board
# Integration
# Item
# Section
# Session
# User
# VerificationToken
# ...
```

### Caddy: bloque `homarr.lan`

Editar `~/homelab/red/Caddyfile` y añadir el bloque, **junto** al de `homepage.lan`:

```caddy
homarr.lan {
    tls internal
    import security-headers
    import logging

    # Homarr funciona con su login NATIVO en el homelab por diseño (ver
    # docs/12-dashboards/02-homarr.md, sección "forward_auth: NO").
    # Si en algún futuro se decide poner Authelia delante:
    #   1. descomentar 'import authelia' aquí
    #   2. configurar AUTH_PROVIDERS=oidc en el .env y reiniciar homarr
    # import authelia

    reverse_proxy homarr:7575 {
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
curl -k --resolve homarr.lan:443:192.168.1.3 -I https://homarr.lan/api/health
# HTTP/2 200

# Home (HTML del login si aún no hay sesión):
curl -k --resolve homarr.lan:443:192.168.1.3 https://homarr.lan/ | head -5
# <!DOCTYPE html>
# <html lang="en">
# ...
```

Y desde el navegador:

1. Visitar `https://homarr.lan/`.
2. Homarr **redirige a `/auth/sign-in`** (no hay usuarios todavía → muestra una pantalla de _setup_ inicial pidiendo crear el primer usuario admin).
3. Crear el usuario `admin` con un password fuerte. **Custodiar en Vaultwarden** como entrada `Homarr — admin user`.
4. Tras el login, la UI carga el _onboarding_ (preguntas básicas: idioma, tema, primer board).

---

## Configuración tras primer arranque

### 1. Crear el usuario admin y el primer board

En el _onboarding_:

- **Idioma**: español. (Cambiable desde _Settings → Preferences → Language_.)
- **Tema**: oscuro o claro a elección. La preferencia se guarda por usuario en BD.
- **Crear primer board**: nombre `default`. Marcar como _public board_ NO (debe requerir login). _Custom path_: `/`.
- **Background image**: dejar la default por ahora; se puede subir una imagen personalizada en _Settings → Customization → Background_ más tarde.

Apuntar el usuario admin (login + password) en Vaultwarden inmediatamente. **Sin esa entrada custodiada, perder la password supone resetear `db.sqlite`** (procedimiento de recuperación documentado en _Troubleshooting_).

### 2. Configurar las integraciones de servicios

Ir a _Settings → Integrations → Add integration_. Añadir, en este orden, los servicios del homelab que ya están desplegados:

| Servicio del homelab | Tipo de integración en Homarr | URL interna (DNS Docker)        | Token / credencial necesarios                      |
|----------------------|-------------------------------|---------------------------------|----------------------------------------------------|
| Pi-hole              | `Pi-hole`                     | `http://pihole`                 | API token (Settings → API → Show API token)        |
| Portainer            | `Portainer`                   | `http://portainer:9000`         | Access token (User settings → Access tokens)        |
| Jellyfin             | `Jellyfin`                    | `http://jellyfin:8096`          | API key (Dashboard → API Keys)                     |
| Sonarr               | `Sonarr v3`                   | `http://sonarr:8989`            | API key (Settings → General → API Key)             |
| Radarr               | `Radarr v3`                   | `http://radarr:7878`            | API key                                            |
| Prowlarr             | `Prowlarr`                    | `http://prowlarr:9696`          | API key                                            |
| Transmission         | `Transmission`                | `http://transmission:9091`      | usuario + password del RPC                         |
| Uptime Kuma          | `Uptime Kuma`                 | `http://uptime-kuma:3001`       | (sin token; lee la status page pública)            |
| Home Assistant       | `Home Assistant`              | `http://home-assistant:8123`    | Long-Lived Access Token                            |
| Grafana              | (n/a — no hay integración nativa) | — (sólo enlace)             | —                                                  |

> **Cada token entra en BD cifrado** con `HOMARR_ENCRYPTION_KEY`. Tras pulsar _Save_ en el formulario, la columna `Integration.secrets` queda como blob AES-256. Si la clave de cifrado desaparece del `.env`, los blobs son irrecuperables (Homarr arrancará y mostrará "Cannot decrypt secrets, please reconfigure integrations").

> **URLs internas vs URLs públicas**: Homarr llama a las APIs **server-side desde el contenedor `homarr`**, así que las URLs deben ser las del DNS interno de Docker (`http://sonarr:8989`, no `https://sonarr.lan`). Esto es **idéntico** a Homepage. La URL pública sólo se usa para el _href_ del _tile_ (cuando el usuario hace click, abrir la web del servicio en una pestaña nueva).

### 3. Construir el board principal con _drag and drop_

Desde la UI:

- **Editar board** (icono lápiz arriba a la derecha).
- **Añadir _categorías_** (separadores horizontales): `Red`, `Infra`, `Multimedia`, `Descargas`, `Productividad`, `Domótica`, `Monitorización`. Igual que las categorías de Homepage para coherencia visual entre los dos dashboards.
- **Añadir _apps_** (cada servicio del homelab como un _tile_): _Add app → Select integration → Pi-hole → tile properties → Save_. Repetir para cada servicio. Asignar icono (Homarr trae un catálogo embebido + permite subir SVG/PNG custom a `/appdata/medias/`).
- **Añadir _widgets_** (visualización de datos en vivo, no sólo enlaces):
  - Widget `Pi-hole stats` → integración Pi-hole → mostrar "queries hoy" + "% bloqueado".
  - Widget `Sonarr — Calendar` → integración Sonarr → mostrar próximos episodios.
  - Widget `Radarr — Calendar` → integración Radarr → mostrar próximos estrenos.
  - Widget `Transmission — Active downloads` → integración Transmission.
  - Widget `Uptime Kuma — Status` → integración Uptime Kuma → ver status de monitores.
  - Widget `Home Assistant — Devices` → integración Home Assistant.
  - Widget `Weather` (sin integración, vía API pública gratuita).
  - Widget `Date and time`.
  - Widget `System info` (RAM/CPU/disk del propio host — opcional, requiere bind mount adicional o socket Docker, **no aplicable** en la configuración por defecto).
- **Reordenar** los _tiles_ con drag-and-drop hasta dejar el _layout_ a gusto. Guardar.

### 4. (Opcional) Crear un board "family" para invitados

- _Settings → Boards → Create new board_ → nombre `family` → _Custom path_: `/family` → marcar _Default for new users_.
- Construir un _layout_ reducido: sólo _tiles_ de Jellyfin, Nextcloud, Vaultwarden, Mealie, FreshRSS. **Sin** widgets técnicos (Pi-hole, Sonarr, Grafana).
- _Settings → Users → Invite user → username `family`, password aleatorio_ — custodiar en Vaultwarden como `Homarr — family user`.
- Asignar el board `family` como _default board_ del usuario `family`.

> **URL diferenciada**: el usuario `family` entra en `https://homarr.lan/auth/sign-in`, autentica con `family / <password>` y aterriza directamente en `/family`. **No** ve el board `default` del operador.

### 5. Exportar boards a JSON (versionado fuera de la BD)

Tras cada cambio significativo, exportar el board afectado y commitear el JSON:

```bash
# Desde la UI: Settings → Boards → <board name> → Export → descargar JSON

# Mover el JSON descargado al repo:
mv ~/Downloads/default.json ~/homelab/dashboards/homarr/exports/default.json
mv ~/Downloads/family.json  ~/homelab/dashboards/homarr/exports/family.json

# Revisar el diff:
cd ~/homelab
git diff dashboards/homarr/exports/

# Commitear:
git add dashboards/homarr/exports/
git commit -m "chore(dashboards): export Homarr boards (default + family)"
```

> **Por qué versionar exports JSON aparte**: a falta de un `git log` de la BD SQLite, los exports JSON sirven como **historial textual** de cómo evolucionó cada board. Útil para:
>
> - **Diffs legibles** (`git diff` sobre el JSON muestra qué tile cambió de posición, qué widget se añadió).
> - **Restauración rápida** (en caso de corrupción de la BD: importar el JSON desde la UI tras restaurar la BD a un estado limpio).
> - **Migración a otro dashboard** (si en el futuro se prefiere Homepage o un dashboard nuevo, los JSON dan la lista de servicios + posiciones para reconstruir el _layout_ por traducción manual).
>
> No es estrictamente necesario hacer un export por cada cambio menor — basta con uno semanal o tras cada modificación de fondo (añadir un nuevo servicio, eliminar un widget grande, reorganizar las categorías).

### 6. Hook de Borgmatic — `dump_sqlite homarr`

Editar el script de _hooks_ de Borgmatic y reemplazar la línea pendiente sobre Homarr:

```bash
$EDITOR ~/homelab/backups/borgmatic/hooks/dump-databases.sh
```

Reemplazar:

```bash
# --- Dashboards (config files — Categoría F)
# Homepage: configuración versionada en git (~/homelab/dashboards/homepage/config/),
#           cubierta por la source_directory global. Sin dump específico.
# Homarr  : /mnt/hd2t/services/homarr/configs/   (pendiente de docs/12-dashboards/02-homarr.md)
```

Por:

```bash
# --- Dashboards
# Homepage: configuración versionada en git (~/homelab/dashboards/homepage/config/),
#           cubierta por la source_directory global. Sin dump específico (Categoría F).
# Homarr  : BD SQLite con boards, integraciones (tokens cifrados) y users (Cat. B).
#           Volumen /mnt/hd2t/services/homarr/appdata/ entra como source_directory.
dump_sqlite homarr homarr /appdata/db.sqlite
```

Reaplicar y verificar:

```bash
chmod 0755 ~/homelab/backups/borgmatic/hooks/dump-databases.sh
~/homelab/backups/borgmatic/install.sh

# Probar el dump puntual sin lanzar todo el ciclo de Borg:
~/homelab/backups/borgmatic/hooks/dump-databases.sh
ls -la ~/homelab/backups/borgmatic/dumps/ | grep homarr
# -rw------- 1 homelab homelab ... homarr-YYYYMMDD-HHMMSS.sqlite.gz
```

Commitear:

```bash
git -C ~/homelab add backups/borgmatic/hooks/dump-databases.sh
git -C ~/homelab commit -m "chore(backups): activate dump_sqlite for Homarr (Cat. B)"
```

> **El dump usa `.backup` en caliente** (`docs/07-backups/03-backup-docker-volumes.md`, helper `dump_sqlite`): SQLite copia la BD en _online backup mode_ sin parar el contenedor. Homarr puede seguir sirviendo el dashboard mientras el dump corre. La copia resultante es **consistente**.

> **Tokens cifrados en el dump**: el dump preserva la columna `Integration.secrets` cifrada. Para descifrar tras restaurar, hace falta `HOMARR_ENCRYPTION_KEY` (custodiada en Vaultwarden). **Si se pierde la clave**, los tokens son irrecuperables: el operador tendría que recrear las integraciones a mano tras restaurar.

### 7. (Opcional) Jail de Fail2ban para `homarr-auth`

Homarr **sí** tiene login propio, así que tiene sentido protegerlo de _bruteforce_. NextAuth registra cada intento fallido en los logs del contenedor con un patrón regular:

```
homarr | [auth] Sign-in failed for user 'admin' from IP X.X.X.X
```

Crear un _jail_ específico siguiendo el patrón ya documentado en `docs/04-seguridad/02-fail2ban.md`. Sólo si el operador anticipa exposición a redes menos confiables (más allá de la LAN doméstica + Tailscale del operador). Por defecto, **no es prioritario** dado el modelo de red del homelab.

```bash
# Filtro:
sudo tee /etc/fail2ban/filter.d/homarr-auth.conf >/dev/null <<'EOF'
[Definition]
failregex = ^.*\[auth\] Sign-in failed for user '\S+' from IP <HOST>
ignoreregex =
EOF

# Jail:
sudo tee /etc/fail2ban/jail.d/homarr.conf >/dev/null <<'EOF'
[homarr-auth]
enabled  = true
filter   = homarr-auth
backend  = auto
logpath  = /var/lib/docker/containers/*/*-json.log
findtime = 10m
maxretry = 5
bantime  = 1h
action   = iptables-multiport[name=homarr, port="443"]
EOF

sudo systemctl restart fail2ban
sudo fail2ban-client status homarr-auth
```

> **Cuándo aplicarlo**: si el operador comparte la sesión Tailscale con personas menos confiables, o si en el futuro abre Homarr a internet vía Caddy + dominio público, este _jail_ pasa a ser **necesario**. En el _baseline_ del homelab (LAN sólo, Tailscale del propio operador), es **opcional**.

### 8. Commitear la configuración

Toda la config (excepto `.env`, los exports y el `.gitkeep`) va a git. Tras el primer arranque correcto:

```bash
cd ~/homelab
git status
# Modificados:
#   dashboards/.env.example          (bloque Homarr añadido)
#   dashboards/docker-compose.yml    (servicio homarr añadido)
#   dashboards/homarr/exports/.gitkeep  (nuevo)
#   dashboards/homarr/exports/default.json  (si se exportó)
#   dashboards/homarr/exports/family.json   (si se exportó)
#   red/Caddyfile                    (bloque homarr.lan)
#   backups/borgmatic/hooks/dump-databases.sh  (bloque dump_sqlite homarr)
# (sin trackear: dashboards/.env)

git add dashboards/ red/Caddyfile backups/borgmatic/hooks/dump-databases.sh
git commit -m "feat(dashboards): add Homarr (UI-driven dashboard, SQLite-backed)"
```

> **A partir de aquí**, los exports JSON de cada board cambian conforme el operador edita el dashboard desde la UI. Política recomendada: un export semanal de cada board + un export _ad-hoc_ tras cualquier reorganización mayor. Cada export es un _commit_ aparte: `chore(dashboards): refresh Homarr default board export`.

---

## Verificación final

Antes de pasar a `docs/13-operaciones/01-mantenimiento-periodico.md`, comprobar:

- [ ] `docker compose -f ~/homelab/dashboards/docker-compose.yml ps` muestra `homarr` en `(healthy)` (junto a `homepage` que ya estaba).
- [ ] `docker exec homarr wget -qO- http://localhost:7575/api/health` devuelve `{"status":"ok"}` (o JSON equivalente).
- [ ] `https://homarr.lan/` redirige a la pantalla de login (`/auth/sign-in`); tras autenticar con el usuario `admin`, carga el board `default`.
- [ ] El board `default` muestra los _tiles_ y widgets configurados; los widgets con integración funcional muestran datos en vivo (Pi-hole queries del día, queue de Sonarr, status de Uptime Kuma).
- [ ] **Test del usuario `family`** (si se creó): autenticar con `family / <password>` y comprobar que:
  - Aterriza directamente en `/family`.
  - **No** puede acceder a `/` ni a `/auth/admin` (devuelve 403 o redirige a `/family`).
- [ ] **Test de cifrado de secretos**:
  ```bash
  sudo -u homelab sqlite3 /mnt/hd2t/services/homarr/appdata/db.sqlite \
      "SELECT name, length(secrets) FROM Integration LIMIT 3;"
  # nombre   length
  # pihole   <num>     ← columna NO vacía y NO legible en plano
  # sonarr   <num>
  # ...
  # Las cadenas no deben contener tokens en claro.
  ```
- [ ] **Test del dump SQLite**:
  ```bash
  ~/homelab/backups/borgmatic/hooks/dump-databases.sh
  ls -la ~/homelab/backups/borgmatic/dumps/ | grep homarr | tail -1
  # -rw------- ... homarr-YYYYMMDD-HHMMSS.sqlite.gz
  zcat ~/homelab/backups/borgmatic/dumps/homarr-*.sqlite.gz \
      | sqlite3 :memory: '.tables' | head
  # Account Board Integration ...   ← schema preservado
  ```
- [ ] **Test del export JSON**: exportar el board `default` desde la UI, descargar, abrir el JSON y verificar que tiene la estructura esperada (`{"name":"default","items":[...],"widgets":[...]}`).
- [ ] **Sin Docker socket montado** (verificación de seguridad):
  ```bash
  docker exec homarr ls /var/run/docker.sock 2>&1 || echo "OK: socket NOT mounted"
  # ls: /var/run/docker.sock: No such file or directory
  # OK: socket NOT mounted
  ```
- [ ] **Bind mount escribible**:
  ```bash
  docker exec homarr sh -c 'echo test > /appdata/test.txt && rm /appdata/test.txt && echo OK'
  # OK
  ```
- [ ] `docker network inspect homelab --format '{{range .Containers}}{{.Name}} {{end}}'` lista a `homarr` (junto a `homepage` y los demás).
- [ ] **Memoria controlada**: `docker stats homarr --no-stream --format '{{.MemUsage}}'` reporta uso de RAM <300 MiB en idle (típico ~150-200 MiB).
- [ ] **Permisos del bind mount**:
  ```bash
  stat -c '%U:%G' /mnt/hd2t/services/homarr/appdata
  # homelab:homelab    (UID/GID 1000:1000)
  ```
- [ ] Tras un `docker compose -f ~/homelab/dashboards/docker-compose.yml restart homarr`, el contenedor vuelve a `(healthy)` en <60 s y la sesión del operador en el navegador **sigue activa** (las cookies de NextAuth viven en BD; persisten al restart).
- [ ] Tras un `sudo reboot` de la Pi, el contenedor vuelve a estar `(healthy)` sin intervención manual y `https://homarr.lan/` responde con la pantalla de login. Tras autenticar, el board carga con la misma configuración (la BD se preserva en disco).
- [ ] `git -C ~/homelab status` está limpio (todo commit-eado). El `.env` **NO** aparece como _untracked_ (lo excluye `.gitignore`).
- [ ] **Test de regresión de Caddy**: `docker exec caddy caddy reload --config /etc/caddy/Caddyfile` no afecta a Homarr; el dashboard sigue accesible. Las sesiones siguen vivas.
- [ ] **Test de Watchtower** (post-deploy, opcional): `docker exec watchtower /watchtower --run-once homarr` (en _dry mode_ si está disponible). Verificar que Watchtower **encuentra** Homarr (etiqueta `com.centurylinklabs.watchtower.enable=true`) y respeta el _tag_ pinneado.
- [ ] **Test de coexistencia con Homepage**: `https://homepage.lan/` y `https://homarr.lan/` cargan de manera independiente, sin compartir cookies de sesión. Cerrar sesión en uno **no** afecta al otro (no comparten dominio).

---

## Backup

| Qué                                          | Dónde                                                              | Cómo                                                                  |
|----------------------------------------------|--------------------------------------------------------------------|-----------------------------------------------------------------------|
| `docker-compose.yml`, `.env.example`         | `~/homelab/dashboards/`                                            | git                                                                   |
| Bloque del `Caddyfile`                       | `~/homelab/red/Caddyfile`                                          | git                                                                   |
| Hook del `dump-databases.sh`                 | `~/homelab/backups/borgmatic/hooks/dump-databases.sh`              | git                                                                   |
| Exports JSON de boards                       | `~/homelab/dashboards/homarr/exports/`                             | git (push remoto)                                                     |
| `.env` con `HOMARR_ENCRYPTION_KEY`           | `~/homelab/dashboards/.env`                                        | **Vaultwarden** (entrada "Homarr — SECRET_ENCRYPTION_KEY")            |
| Credenciales del usuario `admin` (y `family`)| (sólo viven en BD cifrada como bcrypt)                             | **Vaultwarden** (entrada "Homarr — admin user" / "Homarr — family user") |
| BD SQLite (`db.sqlite`) — fuente de verdad   | `/mnt/hd2t/services/homarr/appdata/db.sqlite`                      | **Borgmatic** (`dump_sqlite homarr` — Cat. B, **diario**)             |
| Iconos custom subidos por la UI              | `/mnt/hd2t/services/homarr/appdata/medias/`                        | **Borgmatic** (`source_directories: /mnt/hd2t/services/`)             |
| Logs de Homarr                               | stdout del contenedor (Dozzle, Loki si está)                       | n/a — efímero                                                         |

> **Restauración tras desastre**:
>
> 1. Restaurar el repo `~/homelab/` desde git remoto (Codeberg/GitHub privado). Esto trae `docker-compose.yml`, `.env.example`, el bloque del `Caddyfile`, el `dump-databases.sh` actualizado y los _exports_ JSON.
> 2. Reconstruir `~/homelab/dashboards/.env` desde Vaultwarden, **incluyendo `HOMARR_ENCRYPTION_KEY` con la misma clave que cifró los tokens**. Sin esta clave, los tokens en BD son ilegibles.
> 3. Restaurar `/mnt/hd2t/services/homarr/appdata/` desde el repo Borg (BD + medias). Verificar permisos: `sudo chown -R 1000:1000 /mnt/hd2t/services/homarr`.
> 4. `make up STACK=dashboards` — Homarr arranca, Drizzle verifica el _schema_ (no migra si la BD ya está al nivel del _tag_), las sesiones existentes son válidas, las integraciones siguen activas.
> 5. **Si la `HOMARR_ENCRYPTION_KEY` se perdió**: borrar todas las integraciones desde la UI y volver a crearlas. La estructura de boards se preserva (no estaba cifrada).
> 6. **Si la BD se perdió o quedó corrupta**: arrancar Homarr con `db.sqlite` vacío, autenticar como nuevo admin, importar los exports JSON desde la UI (_Settings → Boards → Import_). Las integraciones hay que recrearlas — los tokens **no van** en los exports JSON (están sólo en BD).
>
> Estado completo recuperado en <10 minutos en el camino feliz; ~30 minutos si hay que recrear integraciones a mano.

> **Antes de cualquier upgrade _minor_ de Homarr** (`v1.0.x → v1.1.0`):
>
> 1. Leer el [_changelog upstream_](https://github.com/homarr-labs/homarr/releases): los _bumps_ de minor pueden traer migraciones de _schema_ Drizzle automáticas, ocasionalmente romper la API de algún widget, o cambiar el formato de export JSON.
> 2. **Hacer un dump manual antes**: `~/homelab/backups/borgmatic/hooks/dump-databases.sh` (o lanzar Borgmatic puntualmente). Comprobar que el dump existe y es legible (`zcat ... | sqlite3 :memory: '.tables'`).
> 3. **Exportar todos los boards a JSON** desde la UI y commitear. Salida de emergencia si algo va mal.
> 4. Editar `.env`: `HOMARR_IMAGE_TAG=v1.1.0`.
> 5. `docker compose -f ~/homelab/dashboards/docker-compose.yml pull homarr`.
> 6. `docker compose -f ~/homelab/dashboards/docker-compose.yml up -d homarr`.
> 7. Vigilar los logs: las migraciones aparecen como `[start] Migration applied: NNNN_xxx.sql`. Si fallan, el contenedor queda `unhealthy`.
> 8. Si tras el upgrade falla algo: `git revert` del commit que cambió el tag, restore de la BD desde el dump del paso 2, `up -d homarr` con el tag anterior.
>
> Los _bumps_ de **patch** (`v1.0.0 → v1.0.1`) los gestiona Watchtower automáticamente; el operador no necesita intervenir, pero **debería revisar el `docker logs homarr` el día siguiente al pull** para confirmar que arrancó bien y los widgets siguen activos.

---

## Troubleshooting

### `homarr` arranca y queda en `unhealthy`

El `start_period: 60s` da margen para Drizzle migrate + Next.js cold start. Si tras 2 minutos sigue `starting`/`unhealthy`, mirar los logs:

```bash
docker logs homarr --tail 100
```

Causas frecuentes:

1. **`HOMARR_ENCRYPTION_KEY` ausente o mal**: `Error: Cannot read properties of undefined (reading 'length')` o `Error: Invalid key length`. La clave debe ser **exactamente** 64 caracteres hex (32 bytes). Generar nueva con `openssl rand -hex 32` y custodiar en Vaultwarden. Si ya había tokens cifrados con otra clave, esos se perderán (las integraciones tendrán que reconfigurarse).
2. **Permisos del bind mount**: `Error: SQLITE_CANTOPEN: unable to open database file` o `EACCES: permission denied, open '/appdata/db.sqlite'`. Solución: `sudo chown -R 1000:1000 /mnt/hd2t/services/homarr && sudo chmod -R u+rwX,g+rX,o-rwx /mnt/hd2t/services/homarr`.
3. **Migración Drizzle fallida**: `Error: SQLITE_ERROR: table xyz already exists` u otro error de _schema_. Suele ocurrir tras un upgrade _minor_ con BD que ya estaba en un estado intermedio. Solución: restaurar la BD desde el dump previo al upgrade y volver a intentar.
4. **`AUTH_TRUST_HOST` no marcado**: NextAuth bloquea peticiones que llegan con `X-Forwarded-Proto: https` sin trust del proxy. Solución: confirmar `AUTH_TRUST_HOST=true` en el `.env` o directamente en el `docker-compose.yml`.
5. **Disco lleno**: `ENOSPC: no space left on device, open '/appdata/db.sqlite-wal'`. Verificar `df -h /mnt/hd2t`. SQLite es muy sensible al espacio para WAL.
6. **Imagen incorrecta** (cambio de organización): asegurarse de que la imagen es `ghcr.io/homarr-labs/homarr:vX.Y.Z` y NO `ghcr.io/ajnart/homarr:*` (la antigua, abandonada). Si Watchtower tira de la antigua por inercia de algún _tag_ flotante: borrar la imagen vieja con `docker image rm ghcr.io/ajnart/homarr` y recrear.

### `502 Bad Gateway` desde Caddy hacia `homarr`

Caddy responde 502 si no puede alcanzar `homarr:7575` desde la red `homelab`. Probar:

```bash
docker exec caddy curl -fsS -o /dev/null -w '%{http_code}' http://homarr:7575/api/health
# 200  — si devuelve esto, Caddy está bien y el problema es otro.
# "Connection refused": Homarr no está sirviendo. Pasar al caso anterior.

docker exec caddy nslookup homarr
# Debe resolver a una IP del 172.20.10.0/24.
```

Causas:

1. Homarr en `unhealthy` — ver caso anterior.
2. `homarr` no está enganchado a `homelab` (mira con `docker network inspect homelab`). Si no está, revisar la sección `networks:` del compose y `up -d homarr` de nuevo.
3. `homarr` está en `homelab` pero el alias DNS no está propagado (raro). Reinicio del contenedor lo arregla.

### Login imposible: usuario admin con password olvidado

Reseteo del usuario admin (último recurso):

**Opción 1 — desde la UI con un segundo admin**: si hay otro usuario con rol admin, ese puede resetear el password de `admin` desde _Settings → Users → admin → Reset password_.

**Opción 2 — vía SQL directo a la BD** (parar Homarr antes para evitar locks):

```bash
docker compose -f ~/homelab/dashboards/docker-compose.yml stop homarr

# Generar nuevo hash bcrypt:
NEW_PASS='nueva_password_segura_aqui'
NEW_HASH=$(docker run --rm node:20-alpine sh -c \
    "npm install bcryptjs --silent >/dev/null 2>&1 && \
     node -e \"console.log(require('bcryptjs').hashSync('$NEW_PASS', 12))\"")
echo "$NEW_HASH"
# $2a$12$XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

# Actualizar la BD:
sudo -u homelab sqlite3 /mnt/hd2t/services/homarr/appdata/db.sqlite \
    "UPDATE User SET password = '$NEW_HASH' WHERE name = 'admin';"

docker compose -f ~/homelab/dashboards/docker-compose.yml start homarr
# Login con admin / nueva_password_segura_aqui — funciona.
```

Custodiar la nueva password en Vaultwarden inmediatamente.

**Opción 3 — reset total**: parar Homarr, mover `db.sqlite` a un backup (`mv db.sqlite db.sqlite.broken`), arrancar Homarr (creará una BD nueva y pedirá _setup_ del primer usuario). Tras crear el nuevo admin, importar los _exports JSON_ de los boards desde la UI. **Las integraciones se pierden** (los tokens cifrados estaban en la BD vieja); hay que reconfigurarlas.

### Una integración muestra "Connection error" en la UI

Diagnóstico:

```bash
docker logs homarr --tail 50 | grep -iE 'integration|error|401|403|fetch'
```

Causas frecuentes:

1. **URL interna mal escrita**: `http://piholee` (con doble e) → DNS no resuelve. Solución: editar la integración en _Settings → Integrations_ y corregir la URL.
2. **Token inválido o expirado**: la integración hace 401. Volver a generar el token en la UI del servicio (Pi-hole, Sonarr, …) y pegarlo de nuevo en la integración de Homarr.
3. **El servicio destino está caído**: confirmar con `docker ps | grep <servicio>`.
4. **Versión incompatible**: si Homarr espera "Sonarr v3" pero el contenedor corre v4 (o viceversa), el endpoint cambia. En _Settings → Integrations → Edit → Type_ asegurarse de que el _type_ coincide con la versión real del servicio destino.
5. **`HOMARR_ENCRYPTION_KEY` cambió**: tras un cambio de clave, los tokens guardados son ilegibles. La UI muestra "Cannot decrypt secrets". Volver a editar cada integración y pegar el token (Homarr lo cifrará con la clave nueva).

### El usuario `family` ve el board del operador

Causa: el board `family` no tiene marcado _Default for new users_, o el usuario `family` tiene asignado el board `default` por error.

Solución:

- _Settings → Boards → family → Edit → Default for new users: ON_.
- _Settings → Users → family → Default board: family_.
- Pedirle al usuario que cierre sesión y vuelva a entrar.

### Drizzle aplica una migración y la BD queda inconsistente

Síntoma: tras un upgrade _minor_, los logs muestran `Migration applied: ...` seguido de errores `SQLITE_ERROR` y el contenedor queda `unhealthy`.

Recuperación:

1. Parar el contenedor: `docker compose -f ~/homelab/dashboards/docker-compose.yml stop homarr`.
2. Restaurar la BD desde el dump previo al upgrade:
   ```bash
   ls -la ~/homelab/backups/borgmatic/dumps/ | grep homarr | tail -3
   # Encontrar el dump previo al upgrade
   sudo -u homelab gunzip -c ~/homelab/backups/borgmatic/dumps/homarr-YYYYMMDD-HHMMSS.sqlite.gz \
       > /mnt/hd2t/services/homarr/appdata/db.sqlite
   sudo chown 1000:1000 /mnt/hd2t/services/homarr/appdata/db.sqlite
   ```
3. Volver al _tag_ anterior en `.env`: `HOMARR_IMAGE_TAG=v1.0.0`.
4. `docker compose -f ~/homelab/dashboards/docker-compose.yml up -d homarr`. Esperar a `healthy`.
5. Reportar el bug en [Issues de homarr-labs/homarr](https://github.com/homarr-labs/homarr/issues) con los logs de la migración fallida.

### Cookies de sesión se invalidan tras `docker compose up -d`

Síntoma: tras un _recreate_ del contenedor, todos los usuarios deben volver a loguearse.

Causa probable: la _secret_ de NextAuth (interna a Homarr v1) se regenera si la BD se borra accidentalmente o si la `HOMARR_ENCRYPTION_KEY` cambia (NextAuth deriva claves de firma de cookies a partir de ella).

Solución: confirmar que `HOMARR_ENCRYPTION_KEY` está estable entre _recreates_ y que `db.sqlite` no se borra (ni por `docker compose down -v` — que sí borra los _named volumes_, pero no los _bind mounts_; este servicio usa bind mount, así que está a salvo). Si el operador se asusta porque "todos cierran sesión", **el comportamiento esperado** tras un cambio de `HOMARR_ENCRYPTION_KEY` es ése.

---

## Migrar a Authelia con `forward_auth` (opcional)

Si en algún momento se decide poner Homarr detrás de SSO global (escenario "homelab abierto a internet con dominio público + Authelia obligatorio para todos los servicios"), el procedimiento es:

1. **Actualizar el bloque del `Caddyfile`**:
   ```caddy
   homarr.lan {
       tls internal
       import security-headers
       import logging
       import authelia       # ← descomentar / añadir

       reverse_proxy homarr:7575 {
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
3. **Probar**: `https://homarr.lan/` debe redirigir a `https://auth.lan/?rd=https://homarr.lan/` (login de Authelia). Tras login válido, Homarr **muestra de nuevo su propia pantalla de login** (Homarr no detecta automáticamente al usuario autenticado por Authelia; son dos capas de auth).
4. **Quitar la doble auth** (recomendado si se aplica esto): configurar Homarr en modo OIDC contra Authelia. En el `.env` de `dashboards`:
   ```bash
   HOMARR_AUTH_PROVIDERS=oidc
   HOMARR_OIDC_ISSUER=https://auth.lan
   HOMARR_OIDC_CLIENT_ID=homarr
   HOMARR_OIDC_CLIENT_SECRET=<secret_generado_en_authelia_yaml>
   HOMARR_OIDC_CLIENT_NAME=Homelab\ SSO
   ```
   y, en Authelia (`docs/04-seguridad/01-authelia.md`), declarar el cliente OIDC `homarr` con `redirect_uris: ['https://homarr.lan/api/auth/callback/oidc']`. Recrear el contenedor de Homarr.
5. **Coste/beneficio**: aplicable sólo si los _trade-offs_ descritos en **Decisiones de diseño** → _forward_auth: NO_ ya no aplican (típicamente, en un homelab que pasa a estar en internet). Por defecto, **no se hace**.

> **Las integraciones siguen funcionando**: las llamadas que hace Homarr a las APIs de los servicios son **server-side desde el contenedor `homarr`**, sin pasar por Caddy ni por Authelia. Los tokens cifrados en BD se usan tal cual.

---

## Docker socket proxy compartido (opcional)

Si el operador decide montar un docker-socket-proxy para que **ambos** Homepage y Homarr puedan mostrar status verde/rojo de _containers_, la aproximación es **un único proxy** servido a los dos dashboards. La configuración es la misma que se documenta en `docs/12-dashboards/01-homepage.md` → _Docker socket proxy (opcional)_, con dos consumidores en lugar de uno.

Esquema (resumen):

1. Añadir el contenedor `docker-socket-proxy` al _stack_ `dashboards` con `CONTAINERS=1, POST=0` (sólo lectura).
2. En Homepage: `docker.yaml` → `host: docker-socket-proxy, port: 2375`.
3. En Homarr: añadir una integración tipo `Docker` con URL `http://docker-socket-proxy:2375`.
4. **Restart de ambos dashboards**: `docker compose -f ~/homelab/dashboards/docker-compose.yml up -d homepage homarr`.

> **Coste**: añade un tercer contenedor al _stack_ (Homepage + Homarr + docker-socket-proxy). El proxy es ligero (~3 MB de RAM). Documentación específica: si el operador decide aplicarlo, conviene crear un `docs/12-dashboards/03-docker-socket-proxy.md` aparte (mismo principio que se anticipa en Homepage). **No** es objetivo de este documento.

---

## Custom icons (opcional)

Homarr trae un catálogo embebido de iconos de servicios _self-hosted_ (mismo origen que Homepage: `walkxcode/dashboard-icons`). Para iconos personalizados (logo del propio homelab, una variante propia), subirlos desde la UI:

1. _Settings → Customization → Icons → Upload_ → seleccionar SVG/PNG.
2. Homarr los persiste en `/appdata/medias/` (que entra como `source_directory` en Borgmatic, así que **no hace falta** acción manual de backup).
3. En cada _tile_ que use el icono custom, _Edit → Icon → Custom → seleccionar el icono subido_.

> **Convención**: preferir SVG sobre PNG (escala perfecta, ~5-10× menos peso). El catálogo embebido cubre >2000 iconos; rara vez hace falta subir uno custom.

---

## Referencias

- Documentación oficial: <https://homarr.dev/>
- Repositorio: <https://github.com/homarr-labs/homarr>
- Imagen Docker: <https://github.com/homarr-labs/homarr/pkgs/container/homarr>
- Releases (changelog): <https://github.com/homarr-labs/homarr/releases>
- Lista de integraciones soportadas: <https://homarr.dev/docs/integrations/>
- NextAuth.js (motor de auth interno): <https://next-auth.js.org/>
- Drizzle ORM (motor de BD interno): <https://orm.drizzle.team/>
- Iconos:
  - Catálogo embebido (`walkxcode/dashboard-icons`): <https://github.com/walkxcode/dashboard-icons>
- Dependencias en este homelab:
  - `docs/01-sistema/04-estructura-directorios.md` — directorio `/mnt/hd2t/services/homarr/`
  - `docs/02-docker/02-estructura-compose.md` — _stack_ `dashboards`, convenciones de _labels_
  - `docs/02-docker/04-watchtower.md` — Homarr en _opt-in_
  - `docs/03-red/02-pihole.md` — DNS interno (`*.lan → 192.168.1.3`)
  - `docs/03-red/04-caddy.md` — bloque `homarr.lan` (TLS interno)
  - `docs/04-seguridad/01-authelia.md` — `forward_auth` opcional
  - `docs/04-seguridad/02-fail2ban.md` — _jail_ `homarr-auth` opcional
  - `docs/07-backups/01-estrategia-backup.md` — categorías A-F (Homarr = B)
  - `docs/07-backups/03-backup-docker-volumes.md` — _hook_ `dump_sqlite homarr`
  - `docs/12-dashboards/01-homepage.md` — primer dashboard del _stack_, alternativa con configuración como código
